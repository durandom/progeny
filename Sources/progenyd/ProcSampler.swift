import Darwin
import Foundation

// One process, one sample tick. Forensic-first: pid + ppid + ancestry are
// the reason this daemon exists — "which process ran away, and who spawned it".
// Counters are per-interval deltas (rate), not cumulative, so a query doesn't
// have to diff rows itself.
struct ProcSample: Codable {
    let pid: Int32
    let ppid: Int32
    let comm: String
    let ancestry: String        // "1/572/933" — launchd → … → parent. Reparented-to-launchd swarms pop out visually.
    let orphaned: Bool          // ppid == 1: the doc's runaway signature

    let cpuPercent: Double      // over the sample interval
    let rssBytes: UInt64        // ri_phys_footprint — the "zombie vs working" discriminator
    let energyDeltaNJ: UInt64   // ri_energy_nj delta — literal energy, the thing we minimize globally
    let wakeupsDelta: UInt64    // interrupt + idle wakeups delta — energy proxy on Apple Silicon
    let cyclesDelta: UInt64
    let instructionsDelta: UInt64
    let diskReadDelta: UInt64
    let diskWriteDelta: UInt64
    let startTimeSec: UInt64

    // Enriched lazily (only for emitted rows) — argv resolution is a per-PID
    // syscall + big buffer, too costly to run for all ~920 procs every tick.
    var path: String?      // full executable path (proc_pidpath)
    var command: String?   // full argv (KERN_PROCARGS2) — the forensic detail `comm` truncates away
}

// Full executable path. Works for most PIDs owned by the current user.
func executablePath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
    let rc = proc_pidpath(pid, &buf, UInt32(buf.count))
    return rc > 0 ? String(cString: buf) : nil
}

// Full argv via KERN_PROCARGS2. Returns nil for processes we can't read
// (other users without root) — caller falls back to path/comm.
func commandLine(_ pid: Int32) -> String? {
    var argmax: Int32 = 0
    var sz = MemoryLayout<Int32>.size
    var mibMax = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&mibMax, 2, &argmax, &sz, nil, 0) == 0, argmax > 0 else { return nil }

    var buf = [CChar](repeating: 0, count: Int(argmax))
    var bufSize = Int(argmax)
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buf, &bufSize, nil, 0) == 0, bufSize > 4 else { return nil }

    // Layout: [int32 argc][exec_path\0…padding\0][argv0\0 argv1\0 …][env…]
    var argc: Int32 = 0
    withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf.prefix(4).map(UInt8.init(bitPattern:))) }

    return buf.withUnsafeBufferPointer { ptr -> String? in
        guard let base = ptr.baseAddress else { return nil }
        let end = base + bufSize
        var p = base + 4
        while p < end, p.pointee != 0 { p += 1 }   // skip exec_path
        while p < end, p.pointee == 0 { p += 1 }    // skip null padding
        var args: [String] = []
        var n = 0
        while p < end, n < Int(argc) {
            let s = String(cString: p)
            args.append(s)
            p += s.utf8.count + 1
            n += 1
        }
        let joined = args.joined(separator: " ")
        return joined.count > 512 ? String(joined.prefix(512)) + "…" : joined
    }
}

// libproc flavor constants. Defined locally rather than relying on macro import,
// which is brittle across SDKs. Values are from <sys/proc_info.h> / <libproc.h>.
private let kPROC_ALL_PIDS: UInt32 = 1
private let kPROC_PIDTBSDINFO: Int32 = 3
private let kRUSAGE_INFO_V6: Int32 = 6

// rusage cpu times are in *mach absolute time units*, not nanoseconds (verified
// empirically: reported CPU% was low by exactly numer/denom ≈ 41.7 on M-series).
// Convert ticks → ns via the timebase. No-op on Intel (numer == denom == 1).
private let machTimebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

private func machTicksToNS(_ ticks: UInt64) -> UInt64 {
    ticks &* UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
}

// Holds previous-sample counters in memory — this is the whole justification for
// being a *resident* daemon rather than a launchd one-shot: rates need the prior tick.
final class ProcSampler {
    private struct Prev {
        let cpuTimeNS: UInt64
        let energyNJ: UInt64
        let wakeups: UInt64
        let cycles: UInt64
        let instructions: UInt64
        let diskRead: UInt64
        let diskWrite: UInt64
        let wallNS: UInt64
    }
    private var previous: [Int32: Prev] = [:]

    // Enumerate all PIDs in a single syscall pass (one sysctl read), then pull
    // bsdinfo (ppid/name) + rusage_v6 (energy/cpu/io) per pid. This is the cheap
    // path — no kernel tracing armed, taxes no other process.
    //
    // `enrichTopN` rows (by energy) additionally get full argv (path + command).
    // argv is a per-PID syscall + big buffer, so we pay it only for the likeliest
    // runaways — but here, not in the emitter, so BOTH the durable WAL and OTLP
    // carry the command line (matters when the network sink is down mid-incident).
    func sample(enrichTopN: Int = 0) -> [ProcSample] {
        let wallNS = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let pids = listAllPIDs()

        // Build the pid→ppid map first so we can resolve ancestry chains.
        var bsd: [Int32: proc_bsdinfo] = [:]
        for pid in pids where pid > 0 {
            if let info = bsdInfo(pid) { bsd[pid] = info }
        }

        var out: [ProcSample] = []
        out.reserveCapacity(bsd.count)
        var nextPrev: [Int32: Prev] = [:]
        nextPrev.reserveCapacity(bsd.count)

        for (pid, info) in bsd {
            guard let ru = rusageV6(pid) else { continue }

            let cpuTimeNS = machTicksToNS(ru.ri_user_time &+ ru.ri_system_time)
            let cur = Prev(
                cpuTimeNS: cpuTimeNS,
                energyNJ: ru.ri_energy_nj,
                wakeups: ru.ri_interrupt_wkups &+ ru.ri_pkg_idle_wkups,
                cycles: ru.ri_cycles,
                instructions: ru.ri_instructions,
                diskRead: ru.ri_diskio_bytesread,
                diskWrite: ru.ri_diskio_byteswritten,
                wallNS: wallNS
            )
            nextPrev[pid] = cur

            // Deltas against the previous tick (0 for freshly-seen processes).
            let p = previous[pid]
            let dWall = p.map { wallNS &- $0.wallNS } ?? 0
            let dCPU = p.map { cur.cpuTimeNS &- $0.cpuTimeNS } ?? 0
            let cpuPercent = dWall > 0 ? (Double(dCPU) / Double(dWall)) * 100.0 : 0.0

            out.append(ProcSample(
                pid: pid,
                ppid: info.pbi_ppid.int32,
                comm: name(from: info),
                ancestry: ancestry(of: pid, in: bsd),
                orphaned: info.pbi_ppid == 1,
                cpuPercent: (cpuPercent * 10).rounded() / 10,
                rssBytes: ru.ri_phys_footprint,
                energyDeltaNJ: delta(cur.energyNJ, p?.energyNJ),
                wakeupsDelta: delta(cur.wakeups, p?.wakeups),
                cyclesDelta: delta(cur.cycles, p?.cycles),
                instructionsDelta: delta(cur.instructions, p?.instructions),
                diskReadDelta: delta(cur.diskRead, p?.diskRead),
                diskWriteDelta: delta(cur.diskWrite, p?.diskWrite),
                startTimeSec: info.pbi_start_tvsec
            ))
        }

        // Enrich the top-N by energy with full argv — bounded cost, both sinks benefit.
        if enrichTopN > 0 {
            let hot = out.enumerated()
                .sorted { $0.element.energyDeltaNJ > $1.element.energyDeltaNJ }
                .prefix(enrichTopN)
            for (idx, row) in hot {
                out[idx].command = commandLine(row.pid)
                out[idx].path = executablePath(row.pid)
            }
        }

        previous = nextPrev
        return out
    }

    private func delta(_ cur: UInt64, _ prev: UInt64?) -> UInt64 {
        guard let prev, cur >= prev else { return 0 }  // reset/wrap → report 0, not garbage
        return cur &- prev
    }

    // Walk parent links up to the root (pid 1). Cycle-guarded. Produces a
    // root→parent path so "who triggered this" is a string, not a query join.
    private func ancestry(of pid: Int32, in map: [Int32: proc_bsdinfo]) -> String {
        var chain: [Int32] = []
        var seen = Set<Int32>()
        var cur = map[pid]?.pbi_ppid.int32 ?? 0
        while cur > 0, !seen.contains(cur) {
            seen.insert(cur)
            chain.append(cur)
            cur = map[cur]?.pbi_ppid.int32 ?? 0
        }
        return chain.reversed().map(String.init).joined(separator: "/")
    }

    private func listAllPIDs() -> [Int32] {
        let bytes = proc_listpids(kPROC_ALL_PIDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<Int32>.stride
        var pids = [Int32](repeating: 0, count: count)
        let filled = pids.withUnsafeMutableBytes {
            proc_listpids(kPROC_ALL_PIDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled) / MemoryLayout<Int32>.stride))
    }

    private func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = proc_pidinfo(pid, kPROC_PIDTBSDINFO, 0, &info, size)
        return rc == size ? info : nil
    }

    // rusage_info_t is `void *`; the accepted idiom is to rebind our struct's
    // storage to the opaque pointer type the C API expects.
    private func rusageV6(_ pid: Int32) -> rusage_info_v6? {
        var usage = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, kRUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? usage : nil
    }

    private func name(from info: proc_bsdinfo) -> String {
        let full = fixedCString(info.pbi_name)         // long name if registered
        return full.isEmpty ? fixedCString(info.pbi_comm) : full
    }
}

// An orphan swarm: many same-`comm` processes reparented to launchd (ppid==1) —
// the signature of a crashed agent harness that didn't reap its pool. Detected
// from the in-memory snapshot each tick (zero syscalls, zero disk), so it closes
// the top-N coverage gap for *parked/idle* swarms that never show up as high energy.
struct OrphanSwarm: Codable {
    let comm: String
    let count: Int
    let totalRssBytes: UInt64
    let sumEnergyNJ: UInt64
    let samplePids: [Int32]      // a handful, enough to `kill`/inspect
    let exampleAncestry: String
}

// Same-comm ppid==1 clusters of size >= threshold. ppid==1 is the discriminator:
// legit multi-process apps (Chrome helpers) are parented to their app, not launchd,
// so they don't trigger; a leaked agent pool does.
func detectOrphanSwarms(_ procs: [ProcSample], threshold: Int) -> [OrphanSwarm] {
    var byComm: [String: [ProcSample]] = [:]
    for p in procs where p.orphaned { byComm[p.comm, default: []].append(p) }
    return byComm.compactMap { comm, group in
        guard group.count >= threshold else { return nil }
        return OrphanSwarm(
            comm: comm,
            count: group.count,
            totalRssBytes: group.reduce(0) { $0 + $1.rssBytes },
            sumEnergyNJ: group.reduce(0) { $0 + $1.energyDeltaNJ },
            samplePids: group.prefix(8).map(\.pid),
            exampleAncestry: group.first?.ancestry ?? ""
        )
    }.sorted { $0.count > $1.count }
}

// Largest same-comm ppid==1 cluster (even below threshold) — a low-cardinality
// scalar for a metric gauge, so a forming swarm is visible as a trend/alert even
// when no per-swarm log record is emitted yet.
func maxOrphanCommCount(_ procs: [ProcSample]) -> Int {
    var counts: [String: Int] = [:]
    for p in procs where p.orphaned { counts[p.comm, default: 0] += 1 }
    return counts.values.max() ?? 0
}

// Convert a fixed C char array (imported as a Swift tuple) to a String.
private func fixedCString<T>(_ tuple: T) -> String {
    var value = tuple
    return withUnsafePointer(to: &value) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}

private extension UInt32 {
    var int32: Int32 { Int32(bitPattern: self) }
}

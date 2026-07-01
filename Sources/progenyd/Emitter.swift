import Foundation

// The seam between "collect" and "ship". Slice 1 has StdoutEmitter; Slice 2
// adds OTelEmitter (metrics for aggregates, logs for per-PID) behind this same
// protocol — the samplers never change.
protocol Emitter {
    func emit(procs: [ProcSample], host: HostSample, at date: Date)
}

// Fan out one snapshot to several sinks (e.g. durable WAL + best-effort OTLP).
struct MultiEmitter: Emitter {
    let emitters: [any Emitter]
    func emit(procs: [ProcSample], host: HostSample, at date: Date) {
        for e in emitters { e.emit(procs: procs, host: host, at: date) }
    }
}

// Low-cardinality rollup (system-level metrics candidate) vs high-cardinality
// per-PID rows (log candidate). Slice 1 prints both to stdout as NDJSON so you
// can eyeball correctness against `top` / the doc's diagnostic playbook.
struct StdoutEmitter: Emitter {
    let topN: Int
    var swarmThreshold: Int = 10
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    func emit(procs: [ProcSample], host: HostSample, at date: Date) {
        let ts = ISO8601DateFormatter().string(from: date)

        // Aggregate + host (these become OTLP *metrics* — cheap, no PID cardinality).
        let totalCPU = procs.reduce(0.0) { $0 + $1.cpuPercent }
        let totalEnergy = procs.reduce(0) { $0 + $1.energyDeltaNJ }
        let orphans = procs.filter(\.orphaned).count
        let summary: [String: String] = [
            "ts": ts,
            "kind": "summary",
            "procs": String(procs.count),
            "orphans": String(orphans),
            "total_cpu_pct": String(format: "%.1f", totalCPU),
            "total_energy_nj": String(totalEnergy),
            "host_cpu_user_pct": String(host.cpuUserPct),
            "host_cpu_sys_pct": String(host.cpuSystemPct),
            "host_mem_wired_mb": String(host.memWiredBytes / 1_048_576),
            "host_mem_free_mb": String(host.memFreeBytes / 1_048_576),
            "host_load1": String(host.load1),
            "host_thermal": host.thermalState,
        ]
        printJSON(summary)

        // Orphan swarms detected over ALL procs (closes the top-N coverage gap).
        for s in detectOrphanSwarms(procs, threshold: swarmThreshold) {
            printJSON([
                "ts": ts, "kind": "orphan_swarm", "comm": s.comm,
                "count": String(s.count),
                "total_rss_mb": String(s.totalRssBytes / 1_048_576),
                "sample_pids": s.samplePids.map(String.init).joined(separator: ","),
            ])
        }

        // Per-PID rows (become OTLP *logs*). Top energy consumers first —
        // the runaway is what we care about, not the idle majority.
        let hot = procs.sorted { $0.energyDeltaNJ > $1.energyDeltaNJ }.prefix(topN)
        for var row in hot { printSample(&row, ts: ts) }   // argv already enriched by the sampler
    }

    private func printSample(_ s: inout ProcSample, ts: String) {
        guard let data = try? encoder.encode(s), var obj = String(data: data, encoding: .utf8) else { return }
        // Prepend ts/kind without a second encode pass.
        obj.removeFirst()  // drop leading '{'
        FileHandle.standardOutput.write(Data("{\"ts\":\"\(ts)\",\"kind\":\"proc\",\(obj)\n".utf8))
    }

    private func printJSON(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

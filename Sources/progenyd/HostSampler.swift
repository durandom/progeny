import Darwin
import Foundation

// System-wide metrics (low cardinality → OTLP metrics, not logs). Sourced from
// Mach host stats, not libproc. CPU is a delta of cumulative tick counters, so
// like ProcSampler this needs resident state (prior ticks).
struct HostSample: Codable {
    let cpuUserPct: Double
    let cpuSystemPct: Double
    let cpuIdlePct: Double
    let memWiredBytes: UInt64
    let memActiveBytes: UInt64
    let memCompressedBytes: UInt64
    let memFreeBytes: UInt64
    let memTotalBytes: UInt64
    let load1: Double
    let load5: Double
    let load15: Double
    let thermalState: String   // nominal | fair | serious | critical
    let thermalLevel: Int      // 0…3, numeric form for a metric gauge
}

final class HostSampler {
    private var prevTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private let pageSize = UInt64(getpagesize())
    private let totalMem: UInt64 = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }()

    func sample() -> HostSample {
        let (u, s, i, n) = cpuTicks()
        var uPct = 0.0, sPct = 0.0, iPct = 0.0
        if let p = prevTicks {
            let du = u &- p.user, ds = s &- p.system, di = i &- p.idle, dn = n &- p.nice
            let total = Double(du &+ ds &+ di &+ dn)
            if total > 0 {
                uPct = Double(du &+ dn) / total * 100
                sPct = Double(ds) / total * 100
                iPct = Double(di) / total * 100
            }
        }
        prevTicks = (u, s, i, n)

        let vm = vmStats()
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let (tState, tLevel) = thermal()

        return HostSample(
            cpuUserPct: round1(uPct),
            cpuSystemPct: round1(sPct),
            cpuIdlePct: round1(iPct),
            memWiredBytes: vm.wire &* pageSize,
            memActiveBytes: vm.active &* pageSize,
            memCompressedBytes: vm.compressed &* pageSize,
            memFreeBytes: (vm.free &+ vm.inactive &+ vm.speculative) &* pageSize,
            memTotalBytes: totalMem,
            load1: loads[0], load5: loads[1], load15: loads[2],
            thermalState: tState, thermalLevel: tLevel
        )
    }

    private func cpuTicks() -> (UInt64, UInt64, UInt64, UInt64) {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return (0, 0, 0, 0) }
        let t = info.cpu_ticks   // (user, system, idle, nice) — CPU_STATE_* order
        return (UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3))
    }

    private func vmStats() -> (free: UInt64, active: UInt64, inactive: UInt64,
                               wire: UInt64, compressed: UInt64, speculative: UInt64) {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var vm = vm_statistics64_data_t()
        let rc = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return (0, 0, 0, 0, 0, 0) }
        return (UInt64(vm.free_count), UInt64(vm.active_count), UInt64(vm.inactive_count),
                UInt64(vm.wire_count), UInt64(vm.compressor_page_count), UInt64(vm.speculative_count))
    }

    private func thermal() -> (String, Int) {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return ("nominal", 0)
        case .fair: return ("fair", 1)
        case .serious: return ("serious", 2)
        case .critical: return ("critical", 3)
        @unknown default: return ("unknown", -1)
        }
    }

    private func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}

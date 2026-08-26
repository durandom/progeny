import Darwin
import Foundation
import IOKit
import SQLite3

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
    let externalPowerConnected: Bool?
    let batteryPercent: Double?
    let batteryPowerWatts: Double?  // negative = discharging, positive = charging
    let fanRPMs: [Double]           // empty when unavailable
    let cpuPowerWatts: Double?      // reserved for privileged/IOReport source
    let gpuPowerWatts: Double?      // reserved for privileged/IOReport source
}

final class HostSampler {
    private var prevTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private let smc = SMCReader()
    private let iStat = IStatFanHistoryReader()
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
        let power = batteryPower()

        let fanRPMs = smc.fanRPMs()

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
            thermalState: tState, thermalLevel: tLevel,
            externalPowerConnected: power.externalConnected,
            batteryPercent: power.percent,
            batteryPowerWatts: power.watts,
            fanRPMs: fanRPMs.isEmpty ? iStat.fanRPMs() : fanRPMs,
            cpuPowerWatts: nil,
            gpuPowerWatts: nil
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

    private func batteryPower() -> (externalConnected: Bool?, percent: Double?, watts: Double?) {
        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            return (nil, nil, nil)
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }

        var rawProps: Unmanaged<CFMutableDictionary>?
        let rc = IORegistryEntryCreateCFProperties(service, &rawProps, kCFAllocatorDefault, 0)
        guard rc == KERN_SUCCESS, let props = rawProps?.takeRetainedValue() as? [String: Any] else {
            return (nil, nil, nil)
        }

        let external = props["ExternalConnected"] as? Bool
        let percent = double(props["CurrentCapacity"])
        let voltageMV = double(props["Voltage"] ?? props["AppleRawBatteryVoltage"])
        let amperageMA = signedDouble(props["Amperage"] ?? props["InstantAmperage"])
        let watts: Double?
        if let voltageMV, let amperageMA {
            watts = round2((voltageMV * amperageMA) / 1_000_000.0)
        } else {
            watts = nil
        }
        return (external, percent, watts)
    }

    private func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let i as Int: return Double(i)
        case let u as UInt64: return Double(u)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private func signedDouble(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            let u = n.uint64Value
            return u > UInt64(Int64.max) ? Double(Int64(bitPattern: u)) : n.doubleValue
        case let u as UInt64:
            return Double(Int64(bitPattern: u))
        case let i as Int:
            return Double(i)
        case let s as String:
            return Double(s)
        default:
            return nil
        }
    }

    private func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    private func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

private final class SMCReader {
    private var conn: io_connect_t = 0
    private var attemptedOpen = false

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    func fanRPMs() -> [Double] {
        guard openIfNeeded() else { return [] }
        let count = fanCount()
        let maxFans = count > 0 ? count : 8
        var values: [Double] = []
        for idx in 0..<maxFans {
            let keys = ["F\(idx)Ac", "F\(idx)fA"]
            guard let rpm = keys.compactMap(readNumber).first(where: { $0 >= 0 && $0 < 20_000 }) else {
                if count > 0 { values.append(0) }
                continue
            }
            values.append(round1(rpm))
        }
        return values
    }

    private func fanCount() -> Int {
        guard let value = readNumber("FNum"), value > 0, value < 16 else { return 0 }
        return Int(value.rounded())
    }

    private func openIfNeeded() -> Bool {
        if conn != 0 { return true }
        if attemptedOpen { return false }
        attemptedOpen = true

        for serviceName in ["AppleSMC", "AppleSMCKeysEndpoint"] {
            guard let matching = IOServiceMatching(serviceName) else { continue }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }

            var opened: io_connect_t = 0
            guard IOServiceOpen(service, mach_task_self_, 0, &opened) == KERN_SUCCESS else { continue }
            conn = opened
            return true
        }
        return false
    }

    private func readNumber(_ key: String) -> Double? {
        guard let result = readKey(key) else { return nil }
        let dataType = string(fromFourCC: result.info.dataType)
        let size = min(Int(result.info.dataSize), 32)
        let bytes = byteArray(result.bytes).prefix(size)

        switch dataType {
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4.0
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            var bits = UInt32(bytes[0]) << 24
            bits |= UInt32(bytes[1]) << 16
            bits |= UInt32(bytes[2]) << 8
            bits |= UInt32(bytes[3])
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            var value = UInt32(bytes[0]) << 24
            value |= UInt32(bytes[1]) << 16
            value |= UInt32(bytes[2]) << 8
            value |= UInt32(bytes[3])
            return Double(value)
        default:
            return nil
        }
    }

    private func readKey(_ key: String) -> SMCParamStruct? {
        guard conn != 0 else { return nil }
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        guard call(&input) == KERN_SUCCESS else { return nil }

        var read = SMCParamStruct()
        read.key = input.key
        read.info = input.info
        read.data8 = SMCCommand.readBytes.rawValue
        guard call(&read) == KERN_SUCCESS else { return nil }
        return read.result == 0 ? read : nil
    }

    private func call(_ params: inout SMCParamStruct) -> kern_return_t {
        var out = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let rc = withUnsafePointer(to: &params) { inputPtr in
            withUnsafeMutablePointer(to: &out) { outPtr in
                IOConnectCallStructMethod(
                    conn,
                    UInt32(SMCSelector.kernelIndex.rawValue),
                    inputPtr,
                    MemoryLayout<SMCParamStruct>.stride,
                    outPtr,
                    &outSize
                )
            }
        }
        if rc == KERN_SUCCESS { params = out }
        return rc
    }

    private func fourCC(_ key: String) -> UInt32 {
        var out: UInt32 = 0
        for b in key.utf8.prefix(4) { out = (out << 8) | UInt32(b) }
        return out
    }

    private func string(fromFourCC value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    private func byteArray(_ tuple: SMCBytes) -> [UInt8] {
        var value = tuple
        return withUnsafeBytes(of: &value) { Array($0) }
    }

    private func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}

private enum SMCSelector: UInt8 {
    case kernelIndex = 2
}

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case readKeyInfo = 9
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var info = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

private final class IStatFanHistoryReader {
    private lazy var dbPath: String? = {
        guard let home = consoleUserHome() else { return nil }
        return "\(home)/Library/Application Support/iStat Menus 7/history/history.db"
    }()

    func fanRPMs() -> [Double] {
        guard let dbPath, FileManager.default.fileExists(atPath: dbPath) else { return [] }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let sql = """
        WITH latest AS (
          SELECT max(time) AS t FROM sensors
        ),
        current AS (
          SELECT key, avg(value) AS value, max(time) AS time
          FROM sensors
          WHERE time = (SELECT t FROM latest)
            AND value BETWEEN 800 AND 8000
          GROUP BY key
        ),
        stats AS (
          SELECT key, min(value) AS min_value, max(value) AS max_value, avg(value) AS avg_value
          FROM sensors
          GROUP BY key
        )
        SELECT current.value, current.time
        FROM current
        JOIN stats ON stats.key = current.key
        WHERE stats.min_value > 800
          AND stats.max_value < 8000
          AND stats.avg_value > 1000
        ORDER BY current.value DESC
        LIMIT 4;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        var values: [Double] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let value = sqlite3_column_double(stmt, 0)
            let time = sqlite3_column_double(stmt, 1)
            guard now - time <= 300, value >= 800, value < 8000 else { continue }
            let rounded = (value * 10).rounded() / 10
            if !values.contains(where: { abs($0 - rounded) < 20 }) {
                values.append(rounded)
            }
        }
        return values
    }

    private func consoleUserHome() -> String? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, let pw = getpwuid(st.st_uid), let dir = pw.pointee.pw_dir else {
            return nil
        }
        return String(cString: dir)
    }
}

import Foundation
import Logging
import Metrics

// The OTLP path. Deliberately routes the two data classes to two different OTel
// signals (see README "storage model"):
//   • system aggregates → METRICS (low cardinality, dashboards)
//   • per-PID rows       → LOGS   (wide events, PID as a field not a label)
// swift-otel's bootstrap has already pointed MetricsSystem/LoggingSystem at OTLP,
// so we just use the standard swift-metrics / swift-log facades here.
struct OTelEmitter: Emitter {
    let topN: Int
    let swarmThreshold: Int
    private let procLog = Logger(label: "progeny.proc")

    func emit(procs: [ProcSample], host: HostSample, at date: Date) {
        // --- Process aggregates → metrics ---
        let totalCPU = procs.reduce(0.0) { $0 + $1.cpuPercent }
        let totalEnergy = procs.reduce(0) { $0 + $1.energyDeltaNJ }
        let orphans = procs.filter(\.orphaned).count
        let spotlight = spotlightActivity(procs)
        // Gauge(label:) returns the registry-cached handler, so re-creating each
        // tick is free — no per-tick allocation churn.
        Gauge(label: "progeny.system.cpu.percent").record(totalCPU)
        Gauge(label: "progeny.system.process.count").record(Double(procs.count))
        Gauge(label: "progeny.system.orphan.count").record(Double(orphans))
        Gauge(label: "progeny.system.energy.nanojoules").record(Double(totalEnergy))

        // --- Host metrics → metrics (dimensions keep cardinality bounded) ---
        Gauge(label: "progeny.host.cpu.percent", dimensions: [("state", "user")]).record(host.cpuUserPct)
        Gauge(label: "progeny.host.cpu.percent", dimensions: [("state", "system")]).record(host.cpuSystemPct)
        Gauge(label: "progeny.host.cpu.percent", dimensions: [("state", "idle")]).record(host.cpuIdlePct)
        Gauge(label: "progeny.host.memory.bytes", dimensions: [("state", "wired")]).record(Double(host.memWiredBytes))
        Gauge(label: "progeny.host.memory.bytes", dimensions: [("state", "active")]).record(Double(host.memActiveBytes))
        Gauge(label: "progeny.host.memory.bytes", dimensions: [("state", "compressed")]).record(Double(host.memCompressedBytes))
        Gauge(label: "progeny.host.memory.bytes", dimensions: [("state", "free")]).record(Double(host.memFreeBytes))
        Gauge(label: "progeny.host.load", dimensions: [("window", "1m")]).record(host.load1)
        Gauge(label: "progeny.host.load", dimensions: [("window", "5m")]).record(host.load5)
        Gauge(label: "progeny.host.load", dimensions: [("window", "15m")]).record(host.load15)
        Gauge(label: "progeny.host.thermal.level").record(Double(host.thermalLevel))
        if let connected = host.externalPowerConnected {
            Gauge(label: "progeny.host.external_power.connected").record(connected ? 1.0 : 0.0)
        }
        if let percent = host.batteryPercent {
            Gauge(label: "progeny.host.battery.percent").record(percent)
        }
        if let watts = host.batteryPowerWatts {
            Gauge(label: "progeny.host.battery.power.watts").record(watts)
        }
        for (idx, rpm) in host.fanRPMs.enumerated() {
            Gauge(label: "progeny.host.fan.rpm", dimensions: [("fan", "\(idx)")]).record(rpm)
        }
        if let watts = host.cpuPowerWatts {
            Gauge(label: "progeny.host.cpu.power.watts").record(watts)
        }
        if let watts = host.gpuPowerWatts {
            Gauge(label: "progeny.host.gpu.power.watts").record(watts)
        }

        // --- Spotlight aggregates → metrics ---
        Gauge(label: "progeny.spotlight.active").record(spotlight.active ? 1.0 : 0.0)
        Gauge(label: "progeny.spotlight.process.count", dimensions: [("kind", "total")]).record(Double(spotlight.processCount))
        Gauge(label: "progeny.spotlight.process.count", dimensions: [("kind", "worker")]).record(Double(spotlight.workerCount))
        Gauge(label: "progeny.spotlight.process.count", dimensions: [("kind", "active_worker")]).record(Double(spotlight.activeWorkerCount))
        Gauge(label: "progeny.spotlight.cpu.percent", dimensions: [("kind", "total")]).record(spotlight.cpuPercent)
        Gauge(label: "progeny.spotlight.cpu.percent", dimensions: [("kind", "mds")]).record(spotlight.mdsCPUPercent)
        Gauge(label: "progeny.spotlight.cpu.percent", dimensions: [("kind", "mds_stores")]).record(spotlight.mdsStoresCPUPercent)
        Gauge(label: "progeny.spotlight.cpu.percent", dimensions: [("kind", "worker")]).record(spotlight.workerCPUPercent)
        Gauge(label: "progeny.spotlight.energy.nanojoules").record(Double(spotlight.energyDeltaNJ))
        Gauge(label: "progeny.spotlight.disk.bytes", dimensions: [("direction", "read")]).record(Double(spotlight.diskReadDelta))
        Gauge(label: "progeny.spotlight.disk.bytes", dimensions: [("direction", "write")]).record(Double(spotlight.diskWriteDelta))
        Gauge(label: "progeny.spotlight.mds_stores.rss.bytes").record(Double(spotlight.mdsStoresRSSBytes))

        // --- Orphan swarm → metric (always) + log (only when a real swarm exists) ---
        // Computed over ALL procs, not the top-N, so idle/parked swarms are caught.
        Gauge(label: "progeny.system.orphan.max_comm_count").record(Double(maxOrphanCommCount(procs)))
        for s in detectOrphanSwarms(procs, threshold: swarmThreshold) {
            procLog.warning("orphan_swarm", metadata: [
                "comm": "\(s.comm)",
                "count": "\(s.count)",
                "total_rss_bytes": "\(s.totalRssBytes)",
                "sum_energy_nj": "\(s.sumEnergyNJ)",
                "sample_pids": "\(s.samplePids.map(String.init).joined(separator: ","))",
                "sample_start_times": "\(s.sampleStartTimes.map(String.init).joined(separator: ","))",
                "sample_commands": "\(s.sampleCommands.joined(separator: " || "))",
                "original_parent_pids": "\(s.originalParentPids.map(String.init).joined(separator: ","))",
                "original_parent_commands": "\(s.originalParentCommands.joined(separator: " || "))",
                "original_parents_alive": "\(s.originalParentsAlive)",
                "example_ancestry": "\(s.exampleAncestry)",
                "example_first_ancestry": "\(s.exampleFirstAncestry)",
            ])
        }

        // --- Per-PID → logs (enriched with argv only for the emitted subset) ---
        let hot = procs.sorted { $0.energyDeltaNJ > $1.energyDeltaNJ }.prefix(topN)
        for row in hot {
            var md: Logger.Metadata = [
                "pid": "\(row.pid)",
                "ppid": "\(row.ppid)",
                "comm": "\(row.comm)",
                "ancestry": "\(row.ancestry)",
                "orphaned": "\(row.orphaned)",
                "cpu_percent": "\(row.cpuPercent)",
                "rss_bytes": "\(row.rssBytes)",
                "energy_nj": "\(row.energyDeltaNJ)",
                "wakeups": "\(row.wakeupsDelta)",
                "cycles": "\(row.cyclesDelta)",
                "instructions": "\(row.instructionsDelta)",
                "disk_read": "\(row.diskReadDelta)",
                "disk_write": "\(row.diskWriteDelta)",
                "start_time_sec": "\(row.startTimeSec)",
                "first_seen_sec": "\(row.firstSeenSec)",
                "first_ppid": "\(row.firstPpid)",
                "first_ancestry": "\(row.firstAncestry)",
                "original_parent_alive": "\(row.originalParentAlive)",
            ]
            if let parentComm = row.firstParentComm { md["first_parent_comm"] = "\(parentComm)" }
            if let parentPath = row.firstParentPath { md["first_parent_path"] = "\(parentPath)" }
            if let parentCommand = row.firstParentCommand { md["first_parent_command"] = "\(parentCommand)" }
            if let command = row.command { md["command"] = "\(command)" }
            if let path = row.path { md["path"] = "\(path)" }
            procLog.info("proc", metadata: md)
        }
    }
}

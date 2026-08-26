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
        let spotlight = spotlightActivity(procs)
        var summary: [String: String] = [:]
        summary["ts"] = ts
        summary["kind"] = "summary"
        summary["procs"] = String(procs.count)
        summary["orphans"] = String(orphans)
        summary["total_cpu_pct"] = String(format: "%.1f", totalCPU)
        summary["total_energy_nj"] = String(totalEnergy)
        summary["host_cpu_user_pct"] = String(host.cpuUserPct)
        summary["host_cpu_sys_pct"] = String(host.cpuSystemPct)
        summary["host_mem_wired_mb"] = String(host.memWiredBytes / 1_048_576)
        summary["host_mem_free_mb"] = String(host.memFreeBytes / 1_048_576)
        summary["host_load1"] = String(host.load1)
        summary["host_thermal"] = host.thermalState
        summary["host_external_power_connected"] = host.externalPowerConnected.map { String($0) } ?? ""
        summary["host_battery_percent"] = host.batteryPercent.map { String($0) } ?? ""
        summary["host_battery_power_watts"] = host.batteryPowerWatts.map { String($0) } ?? ""
        summary["host_fan_rpms"] = host.fanRPMs.map { String($0) }.joined(separator: ",")
        summary["host_cpu_power_watts"] = host.cpuPowerWatts.map { String($0) } ?? ""
        summary["host_gpu_power_watts"] = host.gpuPowerWatts.map { String($0) } ?? ""
        summary["spotlight_active"] = String(spotlight.active)
        summary["spotlight_process_count"] = String(spotlight.processCount)
        summary["spotlight_worker_count"] = String(spotlight.workerCount)
        summary["spotlight_active_worker_count"] = String(spotlight.activeWorkerCount)
        summary["spotlight_cpu_pct"] = String(spotlight.cpuPercent)
        summary["spotlight_energy_nj"] = String(spotlight.energyDeltaNJ)
        summary["spotlight_disk_read"] = String(spotlight.diskReadDelta)
        summary["spotlight_disk_write"] = String(spotlight.diskWriteDelta)
        printJSON(summary)

        // Orphan swarms detected over ALL procs (closes the top-N coverage gap).
        for s in detectOrphanSwarms(procs, threshold: swarmThreshold) {
            printJSON([
                "ts": ts, "kind": "orphan_swarm", "comm": s.comm,
                "count": String(s.count),
                "total_rss_mb": String(s.totalRssBytes / 1_048_576),
                "sample_pids": s.samplePids.map(String.init).joined(separator: ","),
                "sample_start_times": s.sampleStartTimes.map(String.init).joined(separator: ","),
                "sample_commands": s.sampleCommands.joined(separator: " || "),
                "original_parent_pids": s.originalParentPids.map(String.init).joined(separator: ","),
                "original_parent_commands": s.originalParentCommands.joined(separator: " || "),
                "original_parents_alive": String(s.originalParentsAlive),
                "example_first_ancestry": s.exampleFirstAncestry,
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

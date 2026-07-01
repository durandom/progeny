import Darwin
import Dispatch
import Foundation
import Logging
import OTel
import ServiceLifecycle

// progenyd — resident, macOS-native process & system observability daemon.
// Sinks: durable local NDJSON WAL (always) + optional OTLP (metrics + logs).

struct Config {
    var intervalSec: Double
    var topN: Int
    var swarmThreshold: Int
    var otlpEnabled: Bool
    var otlpEndpoint: String?   // base URL; SDK appends /v1/{metrics,logs}
    var walEnabled: Bool
    var walDir: URL
    var stdoutEnabled: Bool
    var memWindowMin: Double        // in-RAM full-history window
    var queryEnabled: Bool
    var queryPort: UInt16

    static func fromEnv() -> Config {
        let e = ProcessInfo.processInfo.environment
        let defaultWAL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/progeny")
        return Config(
            intervalSec: e["PROGENY_INTERVAL_SEC"].flatMap(Double.init) ?? 15,
            topN: e["PROGENY_TOP_N"].flatMap(Int.init) ?? 20,
            swarmThreshold: e["PROGENY_SWARM_THRESHOLD"].flatMap(Int.init) ?? 10,
            otlpEnabled: (e["PROGENY_OTLP"] ?? "0") == "1",
            otlpEndpoint: e["PROGENY_OTLP_ENDPOINT"],
            walEnabled: (e["PROGENY_WAL"] ?? "0") == "1",   // default OFF: no SSD write cycles
            walDir: e["PROGENY_WAL_DIR"].map { URL(fileURLWithPath: $0) } ?? defaultWAL,
            stdoutEnabled: (e["PROGENY_STDOUT"] ?? "0") == "1",
            memWindowMin: e["PROGENY_MEM_WINDOW_MIN"].flatMap(Double.init) ?? 240,   // 4h in RAM
            queryEnabled: (e["PROGENY_QUERY"] ?? "1") == "1",
            queryPort: e["PROGENY_QUERY_PORT"].flatMap { UInt16($0) } ?? 9847
        )
    }

    var ringCapacity: Int { max(1, Int((memWindowMin * 60) / intervalSec)) }
}

// `main.swift` top-level globals are @MainActor-isolated in Swift 6; the timer
// handler runs on a serial background queue. Access is serialized by that single
// queue, so we take responsibility with `nonisolated(unsafe)`.
nonisolated(unsafe) let config = Config.fromEnv()
nonisolated(unsafe) let sampler = ProcSampler()
nonisolated(unsafe) let hostSampler = HostSampler()
nonisolated(unsafe) let ring = RingEmitter(capacity: config.ringCapacity)
nonisolated(unsafe) var emitter: any Emitter = StdoutEmitter(topN: config.topN)
nonisolated(unsafe) var samplerTimer: (any DispatchSourceTimer)?
nonisolated(unsafe) var queryServer: QueryServer?

func buildEmitters(includingOTel otel: Bool) -> any Emitter {
    var list: [any Emitter] = []
    if config.queryEnabled { list.append(ring) }   // in-RAM deep-forensic buffer (no SSD)
    if config.walEnabled { list.append(WALEmitter(dir: config.walDir)) }
    if otel { list.append(OTelEmitter(topN: config.topN, swarmThreshold: config.swarmThreshold)) }
    if config.stdoutEnabled || list.isEmpty {
        list.append(StdoutEmitter(topN: config.topN, swarmThreshold: config.swarmThreshold))
    }
    return list.count == 1 ? list[0] : MultiEmitter(emitters: list)
}

// Human-readable sink list for the startup log — mirrors buildEmitters exactly.
func sinkLabel(otel: Bool) -> String {
    var s: [String] = []
    if config.queryEnabled { s.append("RAM(\(Int(config.memWindowMin))m@:\(config.queryPort))") }
    if config.walEnabled { s.append("WAL(\(config.walDir.path))") }
    if otel { s.append("OTLP→\(config.otlpEndpoint ?? "default")") }
    if config.stdoutEnabled || s.isEmpty { s.append("stdout") }
    return s.joined(separator: " + ")
}

// Global `func` (not a top-level statement) → nonisolated → its closures aren't
// inferred @MainActor, required for the background-queue handler.
//
// Energy-first: QoS .background pins work to efficiency cores; a coalesced timer
// with generous leeway lets the kernel batch our wakeups → fewer wakeups → less
// energy (the dominant lever for a periodic daemon).
func startTimer() {
    let queue = DispatchQueue(label: "progenyd.sampler", qos: .background)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let leeway = max(1.0, config.intervalSec / 3.0)
    timer.schedule(
        deadline: .now(),
        repeating: config.intervalSec,
        leeway: .milliseconds(Int(leeway * 1000))
    )
    timer.setEventHandler { @Sendable in
        // Sampler enriches its top-N with argv, so both WAL and OTLP carry it.
        emitter.emit(procs: sampler.sample(enrichTopN: config.topN),
                     host: hostSampler.sample(), at: Date())
    }
    samplerTimer = timer   // retain beyond function scope
    timer.resume()
}

func logStartup(_ sinks: String) {
    FileHandle.standardError.write(Data(
        "progenyd: \(sinks), every \(config.intervalSec)s (leeway ~\(config.intervalSec/3)s), top \(config.topN) by energy\n".utf8
    ))
}

// Start the localhost forensic query server over the in-RAM ring (if enabled).
if config.queryEnabled {
    queryServer = QueryServer(ring: ring, port: config.queryPort)
    queryServer?.start()
}

if config.otlpEnabled {
    var otel = OTel.Configuration.default
    otel.serviceName = "progenyd"
    otel.diagnosticLogLevel = .error
    otel.metrics.otlpExporter.protocol = .httpProtobuf
    otel.logs.otlpExporter.protocol = .httpProtobuf
    otel.traces.otlpExporter.protocol = .httpProtobuf
    otel.metrics.exportInterval = .seconds(config.intervalSec)
    otel.logs.batchLogRecordProcessor.scheduleDelay = .seconds(config.intervalSec)
    if let base = config.otlpEndpoint {
        otel.metrics.otlpExporter.endpoint = "\(base)/v1/metrics"
        otel.logs.otlpExporter.endpoint = "\(base)/v1/logs"
        otel.traces.otlpExporter.endpoint = "\(base)/v1/traces"
    }

    let observability = try OTel.bootstrap(configuration: otel)
    emitter = buildEmitters(includingOTel: true)
    logStartup(sinkLabel(otel: true))
    startTimer()

    let group = ServiceGroup(services: [observability], logger: Logger(label: "progeny.lifecycle"))
    try await group.run()
} else {
    emitter = buildEmitters(includingOTel: false)
    logStartup(sinkLabel(otel: false))
    startTimer()
    dispatchMain()
}

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
    var otlpDiagLevel: String       // swift-otel's own verbosity; see otelLogLevel
    var hostName: String            // resource attribute: which machine these series came from
    var alertEnabled: Bool
    var alertRuleDir: URL           // *.alert.json, the same files installed into OpenObserve
    var alertLogPath: URL
    var alertRetainMin: Int         // window table depth; bounds the evaluator's memory

    static func fromEnv() -> Config {
        let e = ProcessInfo.processInfo.environment
        let defaultWAL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/progeny")
        let defaultAlertDir = URL(fileURLWithPath: "/usr/local/share/progeny/alerts")
        // Delivery is a separate, unprivileged LaunchAgent (progenyd itself has
        // no GUI session), so the firing log is a handover point between two
        // different users. Under the root LaunchDaemon
        // `homeDirectoryForCurrentUser` is `/var/root`, which is 0750 — the
        // agent could not read a single line. Hand over somewhere both can reach.
        let defaultAlertLog = geteuid() == 0
            ? URL(fileURLWithPath: "/usr/local/var/progeny/alerts.ndjson")
            : defaultWAL.appendingPathComponent("alerts.ndjson")
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
            queryPort: e["PROGENY_QUERY_PORT"].flatMap { UInt16($0) } ?? 9847,
            otlpDiagLevel: e["PROGENY_OTLP_DIAG_LEVEL"] ?? "warning",
            hostName: e["PROGENY_HOST_NAME"] ?? Config.defaultHostName(),
            alertEnabled: (e["PROGENY_ALERT"] ?? "0") == "1",
            alertRuleDir: e["PROGENY_ALERT_DIR"].map { URL(fileURLWithPath: $0) } ?? defaultAlertDir,
            alertLogPath: e["PROGENY_ALERT_LOG"].map { URL(fileURLWithPath: $0) } ?? defaultAlertLog,
            alertRetainMin: e["PROGENY_ALERT_RETAIN_MIN"].flatMap(Int.init) ?? 60
        )
    }

    // swift-otel reports delivery failures as `logger.warning("Failed to export
    // metrics.")`. Anything stricter than .warning therefore turns a total export
    // outage into silence: progenyd held ESTABLISHED sockets to the sink for two
    // days in Aug 2026 while every batch was dropped, and the launchd log showed
    // only the startup banner. Default to .warning so the failure is loud.
    static func otelLogLevel(_ name: String) -> OTel.Configuration.LogLevel {
        switch name.lowercased() {
        case "error": .error
        case "warning": .warning
        case "info": .info
        case "debug": .debug
        case "trace": .trace
        default: .warning
        }
    }

    // `hostName` is "proteus.local" on a Mac; the trailing .local is noise in a
    // label that exists to tell two machines apart.
    static func defaultHostName() -> String {
        let raw = ProcessInfo.processInfo.hostName
        return raw.hasSuffix(".local") ? String(raw.dropLast(6)) : raw
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
nonisolated(unsafe) let alertEmitter: AlertEmitter? = buildAlertEmitter()
nonisolated(unsafe) var emitter: any Emitter = StdoutEmitter(topN: config.topN)
nonisolated(unsafe) var samplerTimer: (any DispatchSourceTimer)?
nonisolated(unsafe) var queryServer: QueryServer?

// Built once, outside buildEmitters, so the rule-loading problems can be logged
// at startup rather than swallowed inside the emitter fan-out.
func buildAlertEmitter() -> AlertEmitter? {
    guard config.alertEnabled else { return nil }
    let (rules, problems) = AlertRuleLoader.load(from: config.alertRuleDir)
    for p in problems {
        FileHandle.standardError.write(Data("progenyd: alert rule rejected — \(p)\n".utf8))
    }
    let skipped = rules.filter { !$0.isLocallyEvaluable }.map(\.name)
    if !skipped.isEmpty {
        // PromQL and real-time rules are valid in OpenObserve; they simply have
        // no local engine. Say so, or their silence here looks like a bug.
        FileHandle.standardError.write(Data(
            "progenyd: alert rules not evaluated locally (not sql): \(skipped.joined(separator: ", "))\n".utf8))
    }
    return AlertEmitter(rules: rules,
                        sink: AlertLogSink(path: config.alertLogPath),
                        hostName: config.hostName,
                        retainMinutes: config.alertRetainMin,
                        topN: config.topN)
}

func buildEmitters(includingOTel otel: Bool) -> any Emitter {
    var list: [any Emitter] = []
    if config.queryEnabled { list.append(ring) }   // in-RAM deep-forensic buffer (no SSD)
    if config.walEnabled { list.append(WALEmitter(dir: config.walDir)) }
    if let alerts = alertEmitter { list.append(alerts) }
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
    if alertEmitter != nil { s.append("alerts(\(config.alertRuleDir.path))") }
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
        "progenyd: \(sinks), host=\(config.hostName), every \(config.intervalSec)s (leeway ~\(config.intervalSec/3)s), top \(config.topN) by energy\n".utf8
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
    // Without host.name every writer produces the same series identity — same
    // service_name, same __hash__ — and the sink cannot tell two machines apart.
    // Cheap to add now, impossible to backfill once two hosts have merged.
    otel.resourceAttributes["host.name"] = config.hostName
    otel.diagnosticLogLevel = Config.otelLogLevel(config.otlpDiagLevel)
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

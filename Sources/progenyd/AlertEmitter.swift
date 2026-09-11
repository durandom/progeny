import Foundation
import SQLite3

// SQLite wants to know whether it may keep a borrowed pointer. Our strings are
// Swift-owned temporaries, so it must copy.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Where a fired alert goes. Deliberately a seam: local delivery (notification,
// generated report, both) is an open question, and the evaluator must not have
// to change when it is answered.
protocol AlertSink {
    func deliver(_ firing: AlertFiring)
}

struct AlertFiring {
    let rule: AlertRule
    let at: Date
    let matchCount: Int
    let rows: [[String: String]]   // the query's own result rows, verbatim
    let hostName: String
}

// Evaluates alert rules locally, against the same data and the same SQL that
// OpenObserve evaluates remotely.
//
// Why this lives in the daemon at all, given the rules also run server-side: it
// keeps working when the tailnet or the sink does not — which is exactly the
// moment a slow Mac needs explaining — and it fires on the tick rather than
// waiting for ingest plus the remote alert's evaluation cycle.
//
// It feeds on the SAME top-N-by-energy selection that OTelEmitter ships, and
// that is deliberate. Inserting all ~900 processes would make the local
// evaluator more sensitive than the remote one, which sounds like a feature and
// is really a trap: the identical rule would then mean two different things
// depending on where it ran, and a rule that fires locally but never remotely
// (or the reverse) is worse than no rule. Identical semantics beat sensitivity.
// The processes this is built to catch are high-energy by construction, so
// top-N by energy is where they live anyway.
//
// `alertTopN` may be raised above `PROGENY_TOP_N` for a locally-sharper eye, at
// the cost of that guarantee — and note that ProcSampler enriches only the first
// `PROGENY_TOP_N` rows with `path`/`command`, so rows beyond it arrive with
// those columns NULL and any rule filtering on them silently skips them.
final class AlertEmitter: Emitter, @unchecked Sendable {
    private let rules: [AlertRule]
    private let sink: any AlertSink
    private let hostName: String
    private let retainMinutes: Int
    private let topN: Int
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var insert: OpaquePointer?
    private var lastEvaluated: [String: Date] = [:]
    private var silencedUntil: [String: Date] = [:]

    // The columns are the OTLP per-PID log field names from OTelEmitter, plus
    // the two the pipeline adds downstream (`_timestamp`, `host_name`). Matching
    // them exactly is the whole mechanism: it is what lets one SQL string read
    // both this table and the `progeny_process_raw` stream in OpenObserve.
    // Column types are chosen to match that stream exactly; see openDatabase().
    private static let columns = [
        "_timestamp", "host_name", "pid", "ppid", "comm", "ancestry", "orphaned",
        "cpu_percent", "rss_bytes", "energy_nj", "wakeups", "cycles", "instructions",
        "disk_read", "disk_write", "start_time_sec", "first_seen_sec", "first_ppid",
        "first_ancestry", "original_parent_alive", "first_parent_comm",
        "first_parent_path", "first_parent_command", "command", "path",
    ]

    // The real table. Rules never name it — they name the view below, so the
    // rule text stays identical to the OpenObserve stream name.
    private static let baseTable = "progeny_process_raw_all"
    private static let ruleTable = "progeny_process_raw"

    init?(rules: [AlertRule], sink: any AlertSink, hostName: String, retainMinutes: Int, topN: Int) {
        self.rules = rules.filter(\.isLocallyEvaluable)
        self.sink = sink
        self.hostName = hostName
        self.topN = max(1, topN)
        // Retention must cover the longest rule's look-back, or that rule
        // evaluates over a window we already pruned and quietly under-reports.
        let longestPeriod = self.rules.map(\.triggerCondition.period).max() ?? retainMinutes
        self.retainMinutes = max(retainMinutes, longestPeriod)
        guard !self.rules.isEmpty else { return nil }
        guard openDatabase() else { return nil }
    }

    deinit {
        if let insert { sqlite3_finalize(insert) }
        if let db { sqlite3_close(db) }
    }

    private func openDatabase() -> Bool {
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else { return false }
        // `_timestamp` is INTEGER because OpenObserve stores it as a number, not
        // a string — a rule writes `max(_timestamp)`, with no CAST, and would
        // otherwise get a lexicographic max here and a numeric one there. Every
        // other column is TEXT for the same reason in reverse: OpenObserve keeps
        // them as strings, so the rule's `CAST(energy_nj AS DOUBLE)` has to mean
        // the same thing on both engines.
        let cols = Self.columns.map { name in
            name == "_timestamp" ? "\"_timestamp\" INTEGER" : "\"\(name)\" TEXT"
        }.joined(separator: ", ")
        let ddl = """
            CREATE TABLE \(Self.baseTable) (\(cols));
            CREATE INDEX idx_ts ON \(Self.baseTable) ("_timestamp");
            """
        guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else { return false }
        let placeholders = Self.columns.map { _ in "?" }.joined(separator: ",")
        let names = Self.columns.map { "\"\($0)\"" }.joined(separator: ",")
        let sql = "INSERT INTO \(Self.baseTable) (\(names)) VALUES (\(placeholders))"
        return sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK
    }

    func emit(procs: [ProcSample], host: HostSample, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let db, let insert else { return }

        // OpenObserve's `_timestamp` is microseconds since epoch; match it so a
        // rule can filter on time the same way on both engines.
        let micros = Int64(date.timeIntervalSince1970 * 1_000_000)

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        // Same selection OTelEmitter ships, so the same rule sees the same rows.
        let hot = procs.sorted { $0.energyDeltaNJ > $1.energyDeltaNJ }.prefix(topN)
        for p in hot {
            bindRow(insert, p, micros)
            sqlite3_step(insert)
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
        }
        // Prune before evaluating so a long-running daemon cannot grow without
        // bound if a rule's period is shortened after the fact.
        let cutoff = micros - Int64(retainMinutes) * 60 * 1_000_000
        sqlite3_exec(db, "DELETE FROM \(Self.baseTable) WHERE \"_timestamp\" < \(cutoff)", nil, nil, nil)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        evaluate(at: date, nowMicros: micros)
    }

    private func bindRow(_ stmt: OpaquePointer, _ p: ProcSample, _ micros: Int64) {
        sqlite3_bind_int64(stmt, 1, micros)   // "_timestamp", the one numeric column
        // Order must match `columns` from index 2 on.
        let values: [String?] = [
            hostName, String(p.pid), String(p.ppid), p.comm, p.ancestry,
            String(p.orphaned), String(p.cpuPercent), String(p.rssBytes), String(p.energyDeltaNJ),
            String(p.wakeupsDelta), String(p.cyclesDelta), String(p.instructionsDelta),
            String(p.diskReadDelta), String(p.diskWriteDelta), String(p.startTimeSec),
            String(p.firstSeenSec), String(p.firstPpid), p.firstAncestry,
            String(p.originalParentAlive), p.firstParentComm, p.firstParentPath,
            p.firstParentCommand, p.command, p.path,
        ]
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 2)   // +1 for 1-based, +1 for the bound "_timestamp"
            if let v { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, idx) }
        }
    }

    private func evaluate(at date: Date, nowMicros: Int64) {
        guard let db else { return }
        for rule in rules {
            let freq = TimeInterval(rule.triggerCondition.frequency * 60)
            if let last = lastEvaluated[rule.name], date.timeIntervalSince(last) < freq { continue }
            lastEvaluated[rule.name] = date
            if let until = silencedUntil[rule.name], date < until { continue }

            // The window. OpenObserve applies the alert's `period` outside the
            // SQL, so we must too — injecting a WHERE clause into the rule's own
            // text would change the string and break the "one rule, two engines"
            // guarantee. A temp view shadows the base table under the stream's
            // name instead, leaving the rule SQL byte-identical.
            let cutoff = nowMicros - Int64(rule.triggerCondition.period) * 60 * 1_000_000
            sqlite3_exec(db, "DROP VIEW IF EXISTS temp.\(Self.ruleTable)", nil, nil, nil)
            let view = """
                CREATE TEMP VIEW \(Self.ruleTable) AS
                SELECT * FROM \(Self.baseTable) WHERE "_timestamp" >= \(cutoff)
                """
            guard sqlite3_exec(db, view, nil, nil, nil) == SQLITE_OK else { continue }

            guard let sql = rule.queryCondition.sql else { continue }
            let rows = query(sql)
            guard rule.fires(rows.count) else { continue }

            silencedUntil[rule.name] = date.addingTimeInterval(TimeInterval(rule.triggerCondition.silence * 60))
            sink.deliver(AlertFiring(rule: rule, at: date, matchCount: rows.count,
                                     rows: rows, hostName: hostName))
        }
        sqlite3_exec(db, "DROP VIEW IF EXISTS temp.\(Self.ruleTable)", nil, nil, nil)
    }

    private func query(_ sql: String) -> [[String: String]] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            FileHandle.standardError.write(Data("progenyd: alert query failed: \(msg)\n".utf8))
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                if let text = sqlite3_column_text(stmt, i) {
                    row[name] = String(cString: text)
                }
            }
            out.append(row)
            if out.count >= 100 { break }   // a rule matching thousands is a bad rule, not a bigger report
        }
        return out
    }
}

// Default sink: append the firing to an NDJSON file and say so on stderr, which
// launchd captures. Deliberately boring — how a human actually finds out (a
// notification, a generated report, both) is still being decided, and this keeps
// firings recorded and inspectable until it is.
struct AlertLogSink: AlertSink {
    let path: URL

    func deliver(_ firing: AlertFiring) {
        var record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: firing.at),
            "kind": "alert",
            "rule": firing.rule.name,
            "host": firing.hostName,
            "matches": firing.matchCount,
            "rows": firing.rows,
        ]
        if let d = firing.rule.description { record["description"] = d }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]) else { return }

        // World-readable on purpose: written by the root daemon, read by the
        // unprivileged delivery agent. Set explicitly rather than inheriting
        // root's umask, which on a hardened box can be 027 and would make the
        // handover silently unreadable.
        let fm = FileManager.default
        try? fm.createDirectory(at: path.deletingLastPathComponent(),
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil,
                          attributes: [.posixPermissions: 0o644])
        }
        if let fh = try? FileHandle(forWritingTo: path) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: path)
        }
        FileHandle.standardError.write(Data(
            "progenyd: ALERT \(firing.rule.name) matched \(firing.matchCount) on \(firing.hostName)\n".utf8))
    }
}

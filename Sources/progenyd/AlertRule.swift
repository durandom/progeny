import Foundation

// An alert rule, in OpenObserve's own alert shape — deliberately not a shape of
// our own. The same JSON file is POSTed to OpenObserve (orrery's
// `scripts/openobserve-alert.py install`) and evaluated here against the in-RAM
// ring. One file, two engines, no translation layer and no bespoke DSL.
//
// The portability that makes this work is narrow and was measured, not assumed:
// OpenObserve runs Apache DataFusion, and a *plain aggregate* query — COUNT/SUM/
// AVG/MIN/MAX with WHERE/GROUP BY/HAVING and CAST — parses and evaluates
// identically in SQLite. DataFusion's full-text (`match_all`) and array helpers
// do not exist in SQLite, so a rule that reaches for them stops being portable.
// `AlertRule.validate()` is where that subset is enforced, so the breach is a
// startup error rather than a rule that silently only fires on one side.
struct AlertRule: Codable {
    var name: String
    var streamType: String
    var streamName: String
    var isRealTime: Bool
    var enabled: Bool
    var description: String?
    var destinations: [String]
    var queryCondition: QueryCondition
    var triggerCondition: TriggerCondition

    struct QueryCondition: Codable {
        var type: String        // only "sql" is evaluated locally; "promql" is remote-only
        var sql: String?
        var promql: String?
    }

    // OpenObserve keeps the threshold *beside* the query rather than embedded in
    // it (Prometheus does the opposite). That split is what makes local
    // evaluation cheap: we run the query, then compare the row count. No
    // expression language to reimplement.
    struct TriggerCondition: Codable {
        var period: Int             // look-back window, minutes
        var `operator`: String      // compares result-row count against `threshold`
        var threshold: Int
        var frequency: Int          // how often to evaluate
        var frequencyType: String?  // "minutes" (default); "cron" is remote-only
        var silence: Int            // cooldown after firing, minutes
    }

    enum CodingKeys: String, CodingKey {
        case name
        case streamType = "stream_type"
        case streamName = "stream_name"
        case isRealTime = "is_real_time"
        case enabled, description, destinations
        case queryCondition = "query_condition"
        case triggerCondition = "trigger_condition"
    }

    // Which rules this daemon can evaluate. A PromQL rule is valid and installs
    // into OpenObserve fine — it just has no local engine, so we skip it rather
    // than fail. Reported at startup so "my rule never fires locally" is visible
    // instead of mysterious.
    var isLocallyEvaluable: Bool {
        enabled && !isRealTime && queryCondition.type == "sql" && queryCondition.sql != nil
    }

    // Functions that exist in DataFusion but not in SQLite. A rule using one
    // would fire in OpenObserve and never locally — the worst failure mode,
    // because it looks like it works. Caught at load.
    static let nonPortableFunctions = [
        "match_all", "match_all_raw", "str_match", "re_match", "re_not_match",
        "cast_to_arr", "to_array_string", "unnest", "arr_descending",
        "date_bin", "percentile_cont", "approx_percentile_cont", "histogram",
    ]

    func validate() throws {
        guard !name.isEmpty else { throw AlertRuleError.invalid("rule has no name") }
        if let sql = queryCondition.sql {
            let lowered = sql.lowercased()
            // OpenObserve rejects SELECT * in alert queries; catching it here
            // keeps a rule from passing local evaluation and failing on install.
            if lowered.contains("select *") {
                throw AlertRuleError.invalid("\(name): `SELECT *` is rejected by OpenObserve alerts")
            }
            // Measured on OpenObserve v0.92.2, 2026-09-10: `CAST(x AS INTEGER)`
            // yields zero rows there while SQLite accepts it happily — the exact
            // one-sided silence this validator exists to prevent. `BIGINT` works
            // on both.
            if lowered.contains("as integer)") {
                throw AlertRuleError.invalid(
                    "\(name): `CAST(… AS INTEGER)` returns no rows in DataFusion — use BIGINT")
            }
            for fn in Self.nonPortableFunctions where lowered.contains(fn) {
                throw AlertRuleError.invalid(
                    "\(name): `\(fn)` is DataFusion-only and has no SQLite equivalent — "
                    + "the rule would fire in OpenObserve and stay silent locally")
            }
        }
        guard triggerCondition.period > 0 else {
            throw AlertRuleError.invalid("\(name): trigger_condition.period must be > 0")
        }
        guard triggerCondition.frequency > 0 else {
            throw AlertRuleError.invalid("\(name): trigger_condition.frequency must be > 0")
        }
        guard Self.compare(1, triggerCondition.operator, 1) != nil else {
            throw AlertRuleError.invalid("\(name): unknown operator `\(triggerCondition.operator)`")
        }
    }

    // OpenObserve accepts both symbolic and word operators depending on which
    // surface wrote the rule (UI vs k8s CRD), so both are honoured.
    static func compare(_ lhs: Int, _ op: String, _ rhs: Int) -> Bool? {
        switch op.lowercased() {
        case ">=", "greaterthanequals", "greaterthanorequal": lhs >= rhs
        case ">", "greaterthan": lhs > rhs
        case "<=", "lessthanequals", "lessthanorequal": lhs <= rhs
        case "<", "lessthan": lhs < rhs
        case "=", "==", "equalto", "equals": lhs == rhs
        case "!=", "<>", "notequalto": lhs != rhs
        default: nil
        }
    }

    var fires: (Int) -> Bool {
        { count in Self.compare(count, self.triggerCondition.operator, self.triggerCondition.threshold) ?? false }
    }
}

enum AlertRuleError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let m): "invalid alert rule: \(m)" }
    }
}

// Loads `*.alert.json` from a directory. Unreadable or invalid files are
// reported and skipped rather than taking the daemon down: a bad rule must not
// cost us the telemetry the rule was written to watch.
enum AlertRuleLoader {
    static func load(from dir: URL) -> (rules: [AlertRule], problems: [String]) {
        var rules: [AlertRule] = []
        var problems: [String] = []
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return ([], ["alert rule dir unreadable: \(dir.path)"])
        }
        let decoder = JSONDecoder()
        for name in names.sorted() where name.hasSuffix(".alert.json") {
            let url = dir.appendingPathComponent(name)
            do {
                let rule = try decoder.decode(AlertRule.self, from: try Data(contentsOf: url))
                try rule.validate()
                rules.append(rule)
            } catch {
                problems.append("\(name): \(error)")
            }
        }
        return (rules, problems)
    }
}

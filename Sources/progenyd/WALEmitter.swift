import Foundation

// Durable local write-ahead log — the forensic source of truth. Written every
// tick, unconditionally, independent of any network sink: the remote is
// unreachable during exactly the incidents we hunt, so the disk record must not
// depend on it. Plain flat NDJSON so DuckDB / jq read it directly (docs Option B).
// Captures ALL processes (not just the emitted top-N) for complete forensics.
final class WALEmitter: Emitter {
    private let dir: URL
    private let maxBytes: UInt64
    private let keep: Int
    private let lock = NSLock()
    private let currentURL: URL
    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    init(dir: URL, maxBytes: UInt64 = 128 * 1024 * 1024, keep: Int = 8) {
        self.dir = dir
        self.maxBytes = maxBytes
        self.keep = keep
        self.currentURL = dir.appendingPathComponent("progeny.ndjson")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func emit(procs: [ProcSample], host: HostSample, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        let ts = ISO8601DateFormatter().string(from: date)
        var buf = Data()
        if let d = try? encoder.encode(host) { buf.append(prefixed(d, ts: ts, kind: "host")) }
        for p in procs {
            if let d = try? encoder.encode(p) { buf.append(prefixed(d, ts: ts, kind: "proc")) }
        }
        append(buf)
    }

    // Flatten: splice ts/kind into the object instead of nesting it, so queries
    // hit `pid` directly, not `proc.pid`.
    private func prefixed(_ json: Data, ts: String, kind: String) -> Data {
        var body = json
        body.removeFirst()   // drop leading '{'
        return Data("{\"ts\":\"\(ts)\",\"kind\":\"\(kind)\",".utf8) + body + Data("\n".utf8)
    }

    private func append(_ data: Data) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: currentURL.path) {
                FileManager.default.createFile(atPath: currentURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: currentURL)
            _ = try? handle?.seekToEnd()
        }
        guard let h = handle else { return }
        try? h.write(contentsOf: data)
        if ((try? h.offset()) ?? 0) > maxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close(); handle = nil
        // Monotonic suffix from file count avoids needing a wall clock here.
        let rolled = dir.appendingPathComponent("progeny-\(Int(Date().timeIntervalSince1970)).ndjson")
        try? FileManager.default.moveItem(at: currentURL, to: rolled)
        prune()
    }

    private func prune() {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let rolls = all.filter { $0.lastPathComponent.hasPrefix("progeny-") && $0.pathExtension == "ndjson" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in rolls.dropLast(keep) { try? fm.removeItem(at: old) }
    }
}

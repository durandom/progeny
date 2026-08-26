import Darwin
import Foundation

// Minimal localhost-only HTTP/1.0 server exposing the in-memory ring for deep
// forensics — no framework, no disk. Blocking accept loop on a dedicated thread;
// queries are occasional and localhost, so simplicity beats async here.
//
// Routes (all return flat NDJSON, one record per line):
//   GET /stats                 buffer fill + window
//   GET /latest                every process in the newest snapshot
//   GET /pid/<pid>             one PID's rows across the whole buffer (its trajectory)
//   GET /comm/<name>           all rows for a command across the buffer (swarm churn!)
//   GET /window/<minutes>      every process row in the last N minutes
//   GET /host/latest           host metrics in the newest snapshot
//   GET /host/window/<minutes> host metrics over the last N minutes
//   GET /spotlight/latest      Spotlight aggregate in the newest snapshot
//   GET /spotlight/window/<m>  Spotlight aggregate over the last N minutes
final class QueryServer: @unchecked Sendable {
    private let ring: RingEmitter
    private let port: UInt16
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]; return e
    }()

    init(ring: RingEmitter, port: UInt16) { self.ring = ring; self.port = port }

    func start() {
        let t = Thread { [self] in run() }
        t.name = "progenyd.query"
        t.start()
    }

    private func run() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)   // localhost only — never expose the process list
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            FileHandle.standardError.write(Data("progenyd: query server failed to bind :\(port)\n".utf8))
            close(fd); return
        }
        FileHandle.standardError.write(Data("progenyd: query server on http://127.0.0.1:\(port)\n".utf8))
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            serve(client)
            close(client)
        }
    }

    private func serve(_ client: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(client, &buf, buf.count)
        guard n > 0 else { return }
        let req = String(decoding: buf[0..<n], as: UTF8.self)
        let rawPath = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = String(rawPath.split(separator: "?").first ?? "")
        let body = route(path)
        var out = Data("HTTP/1.0 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        writeAll(client, out)
    }

    private func route(_ path: String) -> Data {
        let c = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch c.first {
        case "stats":
            let s = ring.stats
            let span = ring.snapshots()
            let range = span.isEmpty ? "-" : "\(span.first!.date) .. \(span.last!.date)"
            return line(["kind": "stats", "ticks": "\(s.ticks)", "capacity": "\(s.capacity)", "window": range])
        case "latest":
            guard let snap = ring.latest() else { return Data() }
            return rows(snap.procs, ts: snap.date)
        case "pid":
            guard c.count > 1, let pid = Int32(c[1]) else { return err("usage: /pid/<pid>") }
            return history { $0.pid == pid }
        case "comm":
            guard c.count > 1, let name = c[1].removingPercentEncoding else { return err("usage: /comm/<name>") }
            return history { $0.comm == name }
        case "window":
            guard c.count > 1, let mins = Double(c[1]) else { return err("usage: /window/<minutes>") }
            let cutoff = Date().addingTimeInterval(-mins * 60)
            var out = Data()
            for snap in ring.snapshots() where snap.date >= cutoff { out.append(rows(snap.procs, ts: snap.date)) }
            return out
        case "host":
            guard c.count > 1 else { return err("usage: /host/latest or /host/window/<minutes>") }
            switch c[1] {
            case "latest":
                guard let snap = ring.latest() else { return Data() }
                return hostRow(snap.host, ts: snap.date)
            case "window":
                guard c.count > 2, let mins = Double(c[2]) else { return err("usage: /host/window/<minutes>") }
                let cutoff = Date().addingTimeInterval(-mins * 60)
                var out = Data()
                for snap in ring.snapshots() where snap.date >= cutoff {
                    out.append(hostRow(snap.host, ts: snap.date))
                }
                return out
            default:
                return err("usage: /host/latest or /host/window/<minutes>")
            }
        case "spotlight":
            guard c.count > 1 else { return err("usage: /spotlight/latest or /spotlight/window/<minutes>") }
            switch c[1] {
            case "latest":
                guard let snap = ring.latest() else { return Data() }
                return spotlightRow(spotlightActivity(snap.procs), ts: snap.date)
            case "window":
                guard c.count > 2, let mins = Double(c[2]) else { return err("usage: /spotlight/window/<minutes>") }
                let cutoff = Date().addingTimeInterval(-mins * 60)
                var out = Data()
                for snap in ring.snapshots() where snap.date >= cutoff {
                    out.append(spotlightRow(spotlightActivity(snap.procs), ts: snap.date))
                }
                return out
            default:
                return err("usage: /spotlight/latest or /spotlight/window/<minutes>")
            }
        default:
            return Data("{\"routes\":[\"/stats\",\"/latest\",\"/pid/<pid>\",\"/comm/<name>\",\"/window/<minutes>\",\"/host/latest\",\"/host/window/<minutes>\",\"/spotlight/latest\",\"/spotlight/window/<minutes>\"]}\n".utf8)
        }
    }

    // A proc filter applied across every buffered snapshot → per-member trajectory / churn.
    private func history(_ match: (ProcSample) -> Bool) -> Data {
        var out = Data()
        for snap in ring.snapshots() {
            out.append(rows(snap.procs.filter(match), ts: snap.date))
        }
        return out
    }

    private func rows(_ procs: [ProcSample], ts: Date) -> Data {
        let stamp = ISO8601DateFormatter().string(from: ts)
        var out = Data()
        for p in procs {
            guard let d = try? encoder.encode(p) else { continue }
            var body = d; body.removeFirst()   // drop leading '{'
            out.append(Data("{\"ts\":\"\(stamp)\",".utf8)); out.append(body); out.append(0x0A)
        }
        return out
    }

    private func hostRow(_ host: HostSample, ts: Date) -> Data {
        let stamp = ISO8601DateFormatter().string(from: ts)
        guard let d = try? encoder.encode(host) else { return Data() }
        var body = d; body.removeFirst()
        var out = Data("{\"ts\":\"\(stamp)\",".utf8)
        out.append(body)
        out.append(0x0A)
        return out
    }

    private func spotlightRow(_ spotlight: SpotlightActivity, ts: Date) -> Data {
        let stamp = ISO8601DateFormatter().string(from: ts)
        guard let d = try? encoder.encode(spotlight) else { return Data() }
        var body = d; body.removeFirst()
        var out = Data("{\"ts\":\"\(stamp)\",".utf8)
        out.append(body)
        out.append(0x0A)
        return out
    }

    private func line(_ dict: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)).map { $0 + Data([0x0A]) } ?? Data()
    }
    private func err(_ msg: String) -> Data { Data("{\"error\":\"\(msg)\"}\n".utf8) }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < data.count {
                let w = write(fd, base + off, data.count - off)
                if w <= 0 { break }
                off += w
            }
        }
    }
}

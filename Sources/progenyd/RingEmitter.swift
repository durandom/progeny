import Foundation

// In-memory write-ahead log — the WAL, but in RAM, so zero SSD transactions.
// Holds the last N full snapshots (all processes + host) in a ring. On a 128 GB
// box a few hours of full per-PID history is a few hundred MB. This is the DEEP
// forensic layer (full fidelity, recent window); OTLP/OpenObserve stays the
// summarized long-term layer. Served by QueryServer; never touches disk.
final class RingEmitter: Emitter, @unchecked Sendable {
    struct Snapshot {
        let date: Date
        let procs: [ProcSample]
        let host: HostSample
    }

    private let capacity: Int
    private let lock = NSLock()
    private var ring: [Snapshot] = []
    private var head = 0   // next write slot once full

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        ring.reserveCapacity(self.capacity)
    }

    func emit(procs: [ProcSample], host: HostSample, at date: Date) {
        let snap = Snapshot(date: date, procs: procs, host: host)
        lock.lock(); defer { lock.unlock() }
        if ring.count < capacity {
            ring.append(snap)
        } else {
            ring[head] = snap
            head = (head + 1) % capacity
        }
    }

    // Oldest → newest copy for read paths.
    func snapshots() -> [Snapshot] {
        lock.lock(); defer { lock.unlock() }
        guard ring.count == capacity else { return ring }
        return Array(ring[head...] + ring[..<head])
    }

    func latest() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard !ring.isEmpty else { return nil }
        let idx = ring.count < capacity ? ring.count - 1 : (head + capacity - 1) % capacity
        return ring[idx]
    }

    var stats: (ticks: Int, capacity: Int) {
        lock.lock(); defer { lock.unlock() }
        return (ring.count, capacity)
    }
}

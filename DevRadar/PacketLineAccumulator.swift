import Foundation

/// Incremental, bounded representation of tcpdump's packet-buffered stdout.
/// The raw PCAPNG remains on disk for export, while the inspector only keeps
/// the latest decoded packet summaries in memory.
struct PacketLineAccumulator {
    private(set) var count = 0
    private(set) var lines: [String] = []
    private var pending = Data()
    private let maximumRetained = 500

    mutating func reset() {
        count = 0
        lines.removeAll()
        pending.removeAll()
    }

    mutating func ingest(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        pending.append(chunk)
        // Handle a very long malformed/binary line without unlimited memory.
        if pending.count > 64 * 1024, !pending.contains(10) {
            pending.removeAll()
            return
        }
        var nextStart = pending.startIndex
        for newline in pending.indices where pending[newline] == 10 {
            let line = String(decoding: pending[nextStart..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            nextStart = pending.index(after: newline)
            guard !line.isEmpty else { continue }
            count += 1
            lines.append(line)
        }
        if nextStart != pending.startIndex {
            pending.removeSubrange(pending.startIndex..<nextStart)
        }
        if lines.count > maximumRetained {
            lines.removeFirst(lines.count - maximumRetained)
        }
    }
}

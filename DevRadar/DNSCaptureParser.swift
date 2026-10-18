import Foundation

struct DNSObservedQuery: Identifiable {
    let id: UUID
    let observedAt: Date
    let domain: String
    let queryType: String
    let transactionID: UInt16
    let client: String
    let server: String
    let pid: Int?
    let processName: String?
    var answers: [String]
    var responseStatus: String?
    var responseAt: Date?
}

/// Parses only cleartext port-53 DNS metadata. It cannot see DoH, DoT, QUIC
/// encrypted DNS, a prior cache hit or a query that predates capture.
struct DNSCaptureParser {
    private struct Pending {
        let id: UUID
        let at: Date
    }

    private var pending: [String: Pending] = [:]
    private(set) var events: [DNSObservedQuery] = []
    private(set) var packetsSeen = 0
    private let maximumEvents = 400

    mutating func reset() {
        pending.removeAll()
        events.removeAll()
        packetsSeen = 0
    }

    mutating func ingest(line: String, at date: Date) {
        guard line.contains(" > "), line.contains(": ") else { return }
        // tcpdump's Apple PKTAP PID may be unavailable on some interfaces;
        // only explicit metadata is accepted, never inferred from remote IP.
        let pidText = Self.first(#"(?i)\b(?:pid|epid)[ =:]+(\d+)\b"#, in: line, group: 1)
        let pid = pidText.flatMap(Int.init)
        let name = Self.first(#"(?i)\b(?:proc|process)[ =:]+([A-Za-z0-9_.-]+)"#, in: line, group: 1)
        guard let endpoints = Self.first(#"((?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]+)\.(\d+)\s*>\s*((?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]+)\.(\d+):\s"#, in: line, allGroups: 4) else { return }

        packetsSeen += 1
        let (src, srcPort, dst, dstPort) = (endpoints[0], endpoints[1], endpoints[2], endpoints[3])
        if dstPort == "53",
           let request = Self.first(#"\b(\d{1,5})\+?\s+([A-Z0-9]+)\?\s+([A-Za-z0-9_.-]+)\."#, in: line, allGroups: 3),
           let txid = UInt16(request[0]) {
            let key = Self.key(id: txid, client: "\(src).\(srcPort)", server: dst)
            let entry = DNSObservedQuery(
                id: UUID(), observedAt: date,
                domain: request[2].lowercased(), queryType: request[1],
                transactionID: txid, client: "\(src).\(srcPort)", server: dst,
                pid: pid, processName: name,
                answers: [], responseStatus: nil, responseAt: nil
            )
            events.insert(entry, at: 0)
            pending[key] = Pending(id: entry.id, at: date)
        } else if srcPort == "53",
                  let response = Self.first(#"\b(\d{1,5})\s+(?:[a-zA-Z]+\s+)?\d+/\d+/\d+"#, in: line, allGroups: 1),
                  let txid = UInt16(response[0]) {
            let key = Self.key(id: txid, client: "\(dst).\(dstPort)", server: src)
            guard let matched = pending.removeValue(forKey: key),
                  date.timeIntervalSince(matched.at) <= 30,
                  let idx = events.firstIndex(where: { $0.id == matched.id }) else { return }
            let ips = Self.matches(#"\b(?:A|AAAA)\s+([0-9a-fA-F:.]+)"#, in: line)
                .filter { (try? DNSDiagnosticsEngine.validate($0))?.isIPAddress == true }
            events[idx].answers = Array(Set(ips)).sorted()
            events[idx].responseStatus = line.localizedCaseInsensitiveContains("NXDomain") ? "NXDOMAIN"
                : line.localizedCaseInsensitiveContains("ServFail") ? "SERVFAIL" : "已响应"
            events[idx].responseAt = date
        }
        if events.count > maximumEvents { events.removeLast(events.count - maximumEvents) }
        let valid = Set(events.map(\.id))
        pending = pending.filter { date.timeIntervalSince($0.value.at) <= 30 && valid.contains($0.value.id) }
    }

    private static func key(id: UInt16, client: String, server: String) -> String {
        "\(id)|\(client)|\(server)"
    }

    private static func first(_ pattern: String, in text: String, group: Int) -> String? {
        first(pattern, in: text, allGroups: group)?.last
    }

    private static func first(_ pattern: String, in text: String, allGroups: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let groups = (1...allGroups).compactMap { group -> String? in
            guard let range = Range(match.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
        return groups.count == allGroups ? groups : nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

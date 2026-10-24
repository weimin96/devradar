import Foundation

/// Process-verified socket counters from nettop, not decrypted HTTP records.
/// Ports classify probable TLS/QUIC; using :443 does not prove HTTPS.
struct HTTPSConnection: Identifiable {
    let id: String
    let pid: Int
    let transport: String
    let localAddress: String
    let remoteAddress: String
    let remotePort: Int
    var uploadedBytes: UInt64
    var downloadedBytes: UInt64
    var latestBytesOut: UInt64
    var latestBytesIn: UInt64
    var lastObserved: Date

    var protocolLabel: String {
        if remotePort == 443 {
            return transport.hasPrefix("udp") ? "QUIC / UDP 443（推测）" : "HTTPS / TLS 443（推测）"
        }
        return transport.uppercased()
    }
}

/// The command emits process rows and socket rows after a CSV header every
/// sample. Counting only counter *deltas* prevents billing pre-existing traffic
/// as upload bytes transmitted during monitoring.
struct HTTPSConnectionTracker {
    private(set) var connections: [String: HTTPSConnection] = [:]
    private var currentPID: Int?
    private let allowedPIDs: Set<Int>
    private var frameCount = 0

    init(pids: [Int]) {
        allowedPIDs = Set(pids)
    }

    mutating func consume(line raw: String, at date: Date) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(",bytes_in,bytes_out") {
            frameCount += 1
            currentPID = nil
            connections = connections.filter { date.timeIntervalSince($0.value.lastObserved) <= 30 }
            if connections.count > 300 {
                let recent = connections.values.sorted { $0.lastObserved > $1.lastObserved }.prefix(300)
                connections = Dictionary(uniqueKeysWithValues: recent.map { ($0.id, $0) })
            }
            return true
        }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return false }
        let name = String(fields[0])
        if !name.hasPrefix("tcp") && !name.hasPrefix("udp") {
            let pidString = name.split(separator: ".").last ?? ""
            currentPID = Int(pidString)
            return false
        }
        guard let pid = currentPID, allowedPIDs.contains(pid),
              let bytesIn = UInt64(fields[1]), let bytesOut = UInt64(fields[2]) else {
            return false
        }
        let components = name.split(separator: " ", maxSplits: 1)
        guard components.count == 2 else { return false }
        let transport = String(components[0]).lowercased()
        let socket = String(components[1])
        guard let arrow = socket.range(of: "<->") else { return false }
        let local = String(socket[..<arrow.lowerBound])
        let remote = String(socket[arrow.upperBound...])
        let dot = remote.lastIndex(of: ".").flatMap { index in
            Int(remote[remote.index(after: index)...]) != nil ? index : nil
        }
        guard let separator = dot ?? remote.lastIndex(of: ":"),
              let port = Int(remote[remote.index(after: separator)...]),
              port > 0 && port <= 65535 else { return false }
        let id = "\(pid)|\(transport)|\(local)|\(remote)"
        if var previous = connections[id] {
            // Interface reconnection and process reuse can reset counters.
            // Never subtract backwards or carry earlier baseline into a new flow.
            previous.uploadedBytes += bytesOut >= previous.latestBytesOut
                ? bytesOut - previous.latestBytesOut : 0
            previous.downloadedBytes += bytesIn >= previous.latestBytesIn
                ? bytesIn - previous.latestBytesIn : 0
            previous.latestBytesOut = bytesOut
            previous.latestBytesIn = bytesIn
            previous.lastObserved = date
            connections[id] = previous
        } else {
            connections[id] = HTTPSConnection(
                id: id, pid: pid, transport: transport, localAddress: local,
                remoteAddress: remote, remotePort: port,
                uploadedBytes: 0, downloadedBytes: 0,
                latestBytesOut: bytesOut, latestBytesIn: bytesIn,
                lastObserved: date
            )
        }
        return true
    }

    var observed443Connections: [HTTPSConnection] {
        connections.values.filter { $0.remotePort == 443 }
            .sorted {
                if $0.uploadedBytes != $1.uploadedBytes {
                    return $0.uploadedBytes > $1.uploadedBytes
                }
                return $0.remoteAddress < $1.remoteAddress
            }
    }

    var monitoredUploadBytes: UInt64 {
        observed443Connections.reduce(0) { $0 + $1.uploadedBytes }
    }
}

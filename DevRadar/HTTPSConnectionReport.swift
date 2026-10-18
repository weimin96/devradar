import Foundation

/// Per-socket metadata only. In particular, it never contains TLS payloads,
/// decoded application requests or certificates/keys.
enum HTTPSConnectionReport {
    struct Entry: Encodable {
        let pid: Int
        let transport: String
        let localAddress: String
        let remoteAddress: String
        let classification: String
        let uploadedSinceMonitoringBytes: UInt64
        let downloadedSinceMonitoringBytes: UInt64
        let lastObserved: Date
    }

    private struct Report: Encodable {
        let schemaVersion: Int
        let exportedAt: Date
        let applicationName: String
        let observationType: String
        let caveat: String
        let observedConnections: [Entry]
    }

    static func encode(applicationName: String, connections: [HTTPSConnection], now: Date = Date()) throws -> Data {
        let report = Report(
            schemaVersion: 1,
            exportedAt: now,
            applicationName: applicationName,
            observationType: "nettop-per-socket-counter-deltas-from-selected-pids",
            caveat: "Port 443 indicates possible HTTPS/TLS or QUIC, not decrypted HTTP. Counters exclude bytes sent before monitoring. No request bodies or per-domain attribution.",
            observedConnections: connections.map {
                Entry(
                    pid: $0.pid, transport: $0.transport,
                    localAddress: $0.localAddress,
                    remoteAddress: $0.remoteAddress,
                    classification: $0.protocolLabel,
                    uploadedSinceMonitoringBytes: $0.uploadedBytes,
                    downloadedSinceMonitoringBytes: $0.downloadedBytes,
                    lastObserved: $0.lastObserved
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
}

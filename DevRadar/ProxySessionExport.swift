import Foundation

/// Export format intentionally excludes request paths, query strings, bodies,
/// headers and raw errors. A proxy-only capture has no verified source PID.
enum ProxySessionExport {
    struct Record: Encodable {
        let type: String
        let timestamp: String?
        let method: String?
        let host: String?
        let status: Int?
        let durationMs: Int64?
        let uploadBytes: Int64?
        let downloadBytes: Int64?
        let attribution: String
    }

    private struct Snapshot: Encodable {
        let schemaVersion: Int
        let createdAt: String
        let scope: String
        let captureLimit: String
        let totalRequests: Int
        let retainedRecords: Int
        let records: [Record]
    }

    static func encode(records: [Record], totalRequests: Int, now: Date = Date()) throws -> Data {
        let snapshot = Snapshot(
            schemaVersion: 1,
            createdAt: ISO8601DateFormatter().string(from: now),
            scope: "system-proxy-unattributed",
            captureLimit: "recent 2000 records, metadata only; not per application",
            totalRequests: totalRequests,
            retainedRecords: records.count,
            records: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }
}

import Foundation

/// Human-initiated, metadata-only export. No packet contents, URLs, headers,
/// clipboard data, input text, or arbitrary process command lines are saved.
enum UploadEvidenceReport {
    private struct Report: Encodable {
        let schemaVersion: Int
        let createdAt: Date
        let attribution: String
        let applicationName: String
        let observations: String
        let destinationByteAttribution: String
        let events: [UploadIncident]
    }

    static func encode(applicationName: String, incidents: [UploadIncident], now: Date = Date()) throws -> Data {
        let report = Report(
            schemaVersion: 1,
            createdAt: now,
            attribution: "application-pid-grouped-nettop-samples",
            applicationName: applicationName,
            observations: "Socket snapshots are correlated in time only, and can be missing or stale. They are not packet destinations.",
            destinationByteAttribution: "unavailable; no per-IP, per-host, or per-connection byte counts are measured",
            events: incidents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
}

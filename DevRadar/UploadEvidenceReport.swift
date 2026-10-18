import Foundation

/// Human-initiated, metadata-only export. No packet contents, URLs, headers,
/// clipboard data, input text, or arbitrary process command lines are saved.
enum UploadEvidenceReport {
    private struct Report: Encodable {
        let schemaVersion: Int
        let createdAt: Date
        let attribution: String
        let applicationID: String
        let applicationName: String
        let observations: String
        let destinationByteAttribution: String
        let links: [ReportLink]
    }

    private struct ReportLink: Encodable {
        let association: String
        let incident: UploadIncident?
        let automatic443: AutomaticHTTPSRecord?
    }

    static func encode(
        applicationID: String,
        applicationName: String,
        incidents: [UploadIncident],
        automaticRecords: [AutomaticHTTPSRecord],
        now: Date = Date()
    ) throws -> Data {
        let groups = CombinedUploadEvidenceMatcher.combine(
            applicationID: applicationID, incidents: incidents,
            automaticRecords: automaticRecords
        )
        let report = Report(
            schemaVersion: 2,
            createdAt: now,
            attribution: "application-pid-grouped-nettop-samples",
            applicationID: applicationID,
            applicationName: applicationName,
            observations: "Linkage requires same application ID, intersecting PIDs and triggers within 12 seconds. Unlinked automatic records can come from sustained upload. No link proves that an HTTP request or encrypted flow caused the spike.",
            destinationByteAttribution: "Incidents contain app-wide rate samples and time-correlated connection snapshots only; automatic443 observations contain per-socket counter deltas measured AFTER monitoring starts. Do not allocate app-wide upload bytes to a remote endpoint.",
            links: groups.map {
                ReportLink(
                    association: $0.isTimeLinked ? "temporal-pid-match-only" :
                        $0.incident != nil ? "app-rate-spike-only" : "automatic-socket-capture-only",
                    incident: $0.incident, automatic443: $0.automatic
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
}

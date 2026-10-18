import Foundation

/// UI/report representation of two independently collected sources.
/// A link means one application, overlapping PIDs and nearby trigger times;
/// it never proves which connection carried the application-level spike.
struct CombinedUploadEvidence: Identifiable {
    let incident: UploadIncident?
    let automatic: AutomaticHTTPSRecord?

    var id: String {
        incident.map { "spike:\($0.id.uuidString)" }
            ?? automatic.map { "socket:\($0.id.uuidString)" }
            ?? "empty"
    }

    var triggeredAt: Date {
        incident?.triggeredAt ?? automatic?.triggeredAt ?? .distantPast
    }

    var isTimeLinked: Bool { incident != nil && automatic != nil }
}

enum CombinedUploadEvidenceMatcher {
    /// Keep linkage conservative and one-to-one. A sustained-rate trigger may
    /// create an automatic record with no corresponding spike incident.
    static func combine(
        applicationID: String,
        incidents: [UploadIncident],
        automaticRecords: [AutomaticHTTPSRecord]
    ) -> [CombinedUploadEvidence] {
        let relevant = automaticRecords.filter { $0.applicationID == applicationID }
        var unused = Set(relevant.map(\.id))
        var merged: [CombinedUploadEvidence] = []
        for incident in incidents.sorted(by: { $0.triggeredAt > $1.triggeredAt }) {
            let match = relevant.filter { record in
                guard unused.contains(record.id),
                      abs(record.triggeredAt.timeIntervalSince(incident.triggeredAt)) <= 12 else {
                    return false
                }
                return !Set(record.pids).isDisjoint(with: incident.observedPIDs)
            }.min {
                abs($0.triggeredAt.timeIntervalSince(incident.triggeredAt)) <
                    abs($1.triggeredAt.timeIntervalSince(incident.triggeredAt))
            }
            if let match { unused.remove(match.id) }
            merged.append(CombinedUploadEvidence(incident: incident, automatic: match))
        }
        for record in relevant where unused.contains(record.id) {
            merged.append(CombinedUploadEvidence(incident: nil, automatic: record))
        }
        return merged.sorted { $0.triggeredAt > $1.triggeredAt }
    }
}

import Foundation
import Observation

struct AutomaticHTTPSFlow: Codable, Identifiable {
    let id: String
    let pid: Int
    let transport: String
    let remoteAddress: String
    let classification: String
    let uploadedBytes: UInt64
    let downloadedBytes: UInt64
}

struct AutomaticHTTPSObservation: Codable {
    let timestamp: Date
    let flows: [AutomaticHTTPSFlow]
}

struct AutomaticHTTPSRecord: Codable, Identifiable {
    let id: UUID
    let applicationID: String
    let applicationName: String
    let pids: [Int]
    let triggeredAt: Date
    let triggerUploadBytesPerSecond: Int
    let monitorStartedAt: Date
    let monitorFinishedAt: Date
    let status: String
    let observations: [AutomaticHTTPSObservation]

    var latestFlows: [AutomaticHTTPSFlow] {
        // Preserve flows that closed before the end of observation.
        var latest: [String: AutomaticHTTPSFlow] = [:]
        for observation in observations {
            for flow in observation.flows {
                if let previous = latest[flow.id], previous.uploadedBytes > flow.uploadedBytes { continue }
                latest[flow.id] = flow
            }
        }
        return latest.values.sorted {
            if $0.uploadedBytes != $1.uploadedBytes { return $0.uploadedBytes > $1.uploadedBytes }
            return $0.remoteAddress < $1.remoteAddress
        }
    }

    var uploadedBytes: UInt64 {
        latestFlows.reduce(UInt64(0)) { $0 &+ $1.uploadedBytes }
    }
}

enum AutomaticHTTPSPolicy {
    static let maxConcurrent = 2
    static let duration: TimeInterval = 30
    static let cooldown: TimeInterval = 600
    static let retention: TimeInterval = 7 * 86400
    static let maxSavedRecords = 50

    static func shouldBegin(
        now: Date,
        pids: [Int],
        uploadRate: Int,
        newSpike: Bool,
        consecutiveHighSamples: Int,
        activeCount: Int,
        lastCapture: Date?
    ) -> Bool {
        guard !pids.isEmpty, activeCount < maxConcurrent else { return false }
        guard lastCapture.map({ now.timeIntervalSince($0) >= cooldown }) ?? true else { return false }
        return (newSpike && uploadRate >= 1_048_576) || consecutiveHighSamples >= 2
    }
}

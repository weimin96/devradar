import Foundation

@main
struct CombinedUploadEvidenceTests {
    static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            guard value() else {
                fputs("FAILED: \(description)\n", stderr)
                exit(1)
            }
        }

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        func spike(pid: Int, offset: TimeInterval = 0) -> UploadIncident {
            UploadIncident(
                id: UUID(), applicationName: "WeType", observedPIDs: [pid],
                triggeredAt: now.addingTimeInterval(offset),
                triggerBytesPerSecond: 3_000_000,
                windowEnd: now.addingTimeInterval(offset + 20),
                samples: [.init(date: now.addingTimeInterval(offset), uploadBytesPerSecond: 3_000_000,
                                downloadBytesPerSecond: 400)],
                connections: [], isComplete: true
            )
        }
        func automatic(_ appID: String = "com.tencent.wetype",
                       pid: Int = 871, offset: TimeInterval = 3) -> AutomaticHTTPSRecord {
            let flow = AutomaticHTTPSFlow(
                id: "\(pid)|tcp4|127.0.0.1:40000|203.0.113.8:443",
                pid: pid, transport: "tcp4", remoteAddress: "203.0.113.8:443",
                classification: "TLS 443 candidate", uploadedBytes: 2480, downloadedBytes: 190
            )
            return AutomaticHTTPSRecord(
                id: UUID(), applicationID: appID, applicationName: "WeType",
                pids: [pid], triggeredAt: now.addingTimeInterval(offset),
                triggerUploadBytesPerSecond: 4_000_000,
                monitorStartedAt: now.addingTimeInterval(offset + 1),
                monitorFinishedAt: now.addingTimeInterval(offset + 31),
                status: "completed",
                observations: [
                    .init(timestamp: now.addingTimeInterval(offset + 4), flows: [flow])
                ]
            )
        }
        let incident = spike(pid: 871)
        let match = automatic()
        let unrelatedPID = automatic(pid: 987, offset: 2)
        let unrelatedApp = automatic("com.other.app", offset: 2)
        let distant = automatic(offset: 400)
        let merged = CombinedUploadEvidenceMatcher.combine(
            applicationID: "com.tencent.wetype",
            incidents: [incident],
            automaticRecords: [match, unrelatedPID, unrelatedApp, distant]
        )
        check(merged.count == 3, "same-app event plus two unmatched records; other app excluded")
        check(merged.filter(\.isTimeLinked).count == 1, "exactly one matching incident")
        check(merged.first { $0.isTimeLinked }?.automatic?.id == match.id, "closest PID-aligned record")
        check(merged.contains { $0.automatic?.id == distant.id && $0.incident == nil },
              "sustained or temporally distant event must remain standalone")
        check(merged.contains { $0.automatic?.id == unrelatedPID.id && $0.incident == nil },
              "a same-app record with a different PID must not be incorrectly linked")
        check(!merged.contains { $0.automatic?.id == unrelatedApp.id }, "strict application ID isolation")

        let unmatched = CombinedUploadEvidenceMatcher.combine(
            applicationID: "com.tencent.wetype", incidents: [], automaticRecords: [distant]
        )
        check(unmatched.count == 1 && !unmatched[0].isTimeLinked,
              "automatic event remains visible after rate samples expire")
        let data = try UploadEvidenceReport.encode(
            applicationID: "com.tencent.wetype", applicationName: "WeType",
            incidents: [incident], automaticRecords: [match, unrelatedApp], now: now
        )
        let text = String(decoding: data, as: UTF8.self)
        check(text.contains("\"schemaVersion\" : 2"), "versioned merged export")
        check(text.contains("temporal-pid-match-only"), "report discloses matching method")
        check(text.contains("2480") && text.contains("203.0.113.8:443"), "socket deltas included")
        check(!text.contains("com.other.app"), "export has no other app data")
        check(!text.contains("requestBody") && !text.contains("Authorization"),
              "no plaintext or HTTP headers in the merged report")
        print("CombinedUploadEvidenceTests: all tests passed")
    }
}

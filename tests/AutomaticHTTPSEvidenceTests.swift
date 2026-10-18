import Foundation

@main
struct AutomaticHTTPSEvidenceTests {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else {
                fputs("FAILED: \(message)\n", stderr)
                exit(1)
            }
        }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        func eligible(
            pids: [Int] = [871], rate: Int = 2_000_000, spike: Bool = false,
            consecutive: Int = 0, active: Int = 0, previous: Date? = nil
        ) -> Bool {
            AutomaticHTTPSPolicy.shouldBegin(
                now: now, pids: pids, uploadRate: rate,
                newSpike: spike, consecutiveHighSamples: consecutive,
                activeCount: active, lastCapture: previous
            )
        }
        check(eligible(spike: true), "fresh 1MB/s spike triggers HTTPS socket monitoring")
        check(eligible(consecutive: 2), "sustained threshold fires after two samples")
        check(!eligible(consecutive: 1), "single high frame not sustained")
        check(!eligible(pids: [], spike: true), "cannot monitor without a real PID")
        check(!eligible(spike: true, active: 2), "at most two concurrent readers")
        check(!eligible(spike: true, previous: now.addingTimeInterval(-90)), "cooldown protects process")
        check(eligible(spike: true, previous: now.addingTimeInterval(-601)), "cooldown eventually expires")
        check(!eligible(rate: 500_000, spike: true), "small spikes cannot trigger")

        let id = UUID()
        let earlier = AutomaticHTTPSFlow(
            id: "871|tcp4|192.168.1.2:123|203.0.113.11:443",
            pid: 871, transport: "tcp4", remoteAddress: "203.0.113.11:443",
            classification: "TLS candidate", uploadedBytes: 1000, downloadedBytes: 500
        )
        let later = AutomaticHTTPSFlow(
            id: earlier.id, pid: earlier.pid, transport: earlier.transport,
            remoteAddress: earlier.remoteAddress, classification: earlier.classification,
            uploadedBytes: 4200, downloadedBytes: 700
        )
        let report = AutomaticHTTPSRecord(
            id: id, applicationID: "org.sample.input", applicationName: "SampleInput",
            pids: [871], triggeredAt: now, triggerUploadBytesPerSecond: 6_000_000,
            monitorStartedAt: now, monitorFinishedAt: now.addingTimeInterval(30),
            status: "completed",
            observations: [
                .init(timestamp: now.addingTimeInterval(2), flows: [earlier]),
                .init(timestamp: now.addingTimeInterval(4), flows: [later]),
                .init(timestamp: now.addingTimeInterval(8), flows: [])
            ]
        )
        check(report.latestFlows.count == 1, "closed socket remains represented in evidence")
        check(report.uploadedBytes == 4200, "accumulate deltas per flow, not per snapshot")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let decoded = JSONDecoder()
        decoded.dateDecodingStrategy = .iso8601
        let restored = try decoded.decode(AutomaticHTTPSRecord.self, from: data)
        check(restored.uploadedBytes == 4200 && restored.pids == [871], "local evidence survives restart")
        let text = String(decoding: data, as: UTF8.self)
        check(!text.contains("password") && !text.contains("httpBody") && !text.contains("requestHeaders"),
              "serialized automatic evidence contains no plaintext content fields")
        print("AutomaticHTTPSEvidenceTests: all tests passed")
    }
}

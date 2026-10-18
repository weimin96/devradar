import Foundation

@main
struct TrafficAnalysisTests {
    static func main() {
        func verify(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else {
                fputs("FAILED: \(message)\n", stderr)
                exit(1)
            }
        }
        var history = TrafficAnalysisBuffer()
        let origin = Date(timeIntervalSince1970: 1_760_000_000)
        for index in 0..<8 {
            history.append(at: origin.addingTimeInterval(Double(index * 2)), upload: 15_000, download: 3_000)
        }
        verify(history.spikes.isEmpty, "baseline should not trigger anomalies")
        history.append(at: origin.addingTimeInterval(16), upload: 3_000_000, download: 0)
        verify(history.spikes.count == 1, "one significant sudden upload")
        history.append(at: origin.addingTimeInterval(18), upload: 4_000_000, download: 0)
        verify(history.spikes.count == 1, "continued upload must not create another spike")
        for index in 0..<180 {
            history.append(
                at: origin.addingTimeInterval(Double(20 + index * 2)),
                upload: 0, download: 0
            )
        }
        verify(history.samples.count == 150, "memory bounded to five minutes")
        verify(history.spikes.isEmpty, "outdated spike must be removed")
        verify(history.currentUploadBytesPerSecond == 0, "last sample is current rate")

        var evidence = TrafficAnalysisBuffer()
        let observedBefore = EvidenceConnectionSnapshot(
            capturedAt: origin.addingTimeInterval(12),
            endpoints: [.init(address: "203.0.113.9:443", transport: "TCP", state: "ESTABLISHED")]
        )
        for index in 0..<8 {
            evidence.append(
                at: origin.addingTimeInterval(Double(index * 2)), upload: 11_000, download: 900,
                applicationName: "TestInput", observedPIDs: [42]
            )
        }
        evidence.append(
            at: origin.addingTimeInterval(16), upload: 3_100_000, download: 0,
            applicationName: "TestInput", observedPIDs: [42], connectionSnapshot: observedBefore
        )
        verify(evidence.incidents.count == 1, "one evidence record per spike")
        verify(evidence.incidents[0].samples.count == 9, "preceding samples preserved")
        verify(evidence.incidents[0].observedPIDs == [42], "PID snapshot is attached")
        verify(evidence.incidents[0].connections.count == 1, "prior socket snapshot recorded")
        verify(!evidence.incidents[0].isComplete, "future window not yet complete")
        evidence.append(
            at: origin.addingTimeInterval(18), upload: 700_000, download: 0,
            applicationName: "TestInput", observedPIDs: [42],
            connectionSnapshot: .init(capturedAt: origin.addingTimeInterval(18), endpoints: [])
        )
        verify(evidence.incidents[0].connections.count == 2, "after-spike empty snapshot retained")
        // The same sampled socket snapshot is not duplicated on later frames.
        evidence.append(
            at: origin.addingTimeInterval(20), upload: 110_000, download: 0,
            applicationName: "TestInput", observedPIDs: [42],
            connectionSnapshot: .init(capturedAt: origin.addingTimeInterval(18), endpoints: [])
        )
        verify(evidence.incidents[0].connections.count == 2, "same timestamp not duplicated")
        for index in 11...18 {
            evidence.append(
                at: origin.addingTimeInterval(Double(index * 2)), upload: 10_000, download: 0,
                applicationName: "TestInput", observedPIDs: [42]
            )
        }
        verify(evidence.incidents[0].isComplete, "post-spike 20-second window completes")
        verify(evidence.incidents[0].peakUploadBytesPerSecond == 3_100_000, "peak preserved")
        let reportData = try! UploadEvidenceReport.encode(
            applicationName: "TestInput",
            incidents: evidence.incidents,
            now: origin
        )
        let report = String(decoding: reportData, as: UTF8.self)
        verify(report.contains("203.0.113.9:443") && report.contains("unavailable"),
               "report records endpoints but disclaims destination bytes")
        verify(!report.contains("HTTPBody") && !report.contains("requestPath"),
               "report contains no decrypted request content")
        evidence.append(at: origin.addingTimeInterval(2000), upload: 0, download: 0)
        verify(evidence.incidents.isEmpty, "evidence memory retention bounded to 30 minutes")

        var missingConnections = TrafficAnalysisBuffer()
        for index in 0..<8 {
            missingConnections.append(
                at: origin.addingTimeInterval(Double(index * 2)),
                upload: 12_000, download: 0
            )
        }
        missingConnections.append(
            at: origin.addingTimeInterval(16), upload: 2_000_000, download: 0,
            applicationName: "NoSockets", observedPIDs: [123],
            connectionSnapshot: .init(
                capturedAt: origin.addingTimeInterval(-100),
                endpoints: [.init(address: "198.51.100.2:443", transport: "TCP", state: nil)]
            )
        )
        verify(missingConnections.incidents.count == 1, "spike still saved without fresh socket inspection")
        verify(missingConnections.incidents[0].connections.isEmpty, "stale socket snapshots must not be attributed")

        let ranking = ProxyDestinationRanking.rank([
            .init(host: "API.EXAMPLE.COM", uploadBytes: 2_000),
            .init(host: "api.example.com", uploadBytes: 3_000),
            .init(host: "other.example.com", uploadBytes: 6_000),
            .init(host: "api.example.com", uploadBytes: -100)
        ])
        verify(ranking.count == 2, "case-folded host grouping")
        verify(ranking[0].host == "other.example.com" && ranking[0].uploadBytes == 6_000,
               "largest destination first")
        verify(ranking[1].uploadBytes == 5_000 && ranking[1].requestCount == 3,
               "bytes and counts aggregated without negative bytes")
        let grouped = ProxyUploadTimeline.buckets([
            .init(date: origin.addingTimeInterval(2), uploadBytes: 100),
            .init(date: origin.addingTimeInterval(6), uploadBytes: 200),
            .init(date: origin.addingTimeInterval(30), uploadBytes: 400),
            .init(date: origin.addingTimeInterval(31), uploadBytes: -50)
        ])
        verify(grouped.count >= 2, "upload times grouped by 15-second buckets")
        verify(grouped.reduce(Int64(0)) { $0 + $1.uploadBytes } == 700,
               "proxy time chart does not invent negative upload totals")
        verify(grouped.map(\.date) == grouped.map(\.date).sorted(),
               "proxy time series sorted chronologically")
        print("TrafficAnalysisTests: all tests passed")
    }
}

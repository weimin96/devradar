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

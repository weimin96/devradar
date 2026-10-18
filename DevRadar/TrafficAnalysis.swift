import Foundation

struct UploadRateSample: Identifiable {
    let date: Date
    let uploadBytesPerSecond: Int
    let downloadBytesPerSecond: Int
    var id: Date { date }
}

struct UploadSpike: Identifiable {
    let date: Date
    let bytesPerSecond: Int
    var id: Date { date }
}

/// A bounded, in-memory sample window. This uses nettop's application rate
/// samples, *not* the unattributed system HTTP proxy. Endpoints are separate
/// socket snapshots and do not carry per-destination byte counters.
struct TrafficAnalysisBuffer {
    private(set) var samples: [UploadRateSample] = []
    private(set) var spikes: [UploadSpike] = []
    private let maxSamples = 150 // approximately five minutes at 2 s/frame

    var peakUploadBytesPerSecond: Int { samples.map(\.uploadBytesPerSecond).max() ?? 0 }
    var currentUploadBytesPerSecond: Int { samples.last?.uploadBytesPerSecond ?? 0 }

    mutating func append(at date: Date, upload: Int, download: Int) {
        let safeUpload = max(0, upload)
        // Previous eight observations form a stable, easily explainable
        // baseline; require at least one MiB/s to avoid classifying idle noise.
        let baseline = samples.suffix(8).map(\.uploadBytesPerSecond).sorted()
        let median = baseline.isEmpty ? 0 : baseline[baseline.count / 2]
        let previous = samples.last?.uploadBytesPerSecond ?? 0
        let threshold = max(1_048_576, median * 4)
        if samples.count >= 4, safeUpload >= threshold, previous < threshold,
           date.timeIntervalSince(spikes.last?.date ?? .distantPast) >= 20 {
            spikes.append(UploadSpike(date: date, bytesPerSecond: safeUpload))
        }
        samples.append(UploadRateSample(
            date: date, uploadBytesPerSecond: safeUpload,
            downloadBytesPerSecond: max(0, download)
        ))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        if let first = samples.first?.date {
            spikes.removeAll { $0.date < first }
        }
    }
}

struct ProxyDestinationRow: Identifiable {
    let host: String
    let uploadBytes: Int64
    let requestCount: Int
    var id: String { host }
}

/// Numeric aggregation only. Callers must pass completed proxy events once;
/// there is no verified PID in these records.
struct ProxyUploadRecord {
    let host: String
    let uploadBytes: Int64
}

struct ProxyUploadSample {
    let date: Date
    let uploadBytes: Int64
}

struct ProxyUploadBucket: Identifiable {
    let date: Date
    let uploadBytes: Int64
    var id: Date { date }
}

enum ProxyUploadTimeline {
    static func buckets(_ samples: [ProxyUploadSample], interval: TimeInterval = 15) -> [ProxyUploadBucket] {
        guard interval > 0 else { return [] }
        var totals: [Date: Int64] = [:]
        for sample in samples {
            let intervalStart = floor(sample.date.timeIntervalSince1970 / interval) * interval
            let date = Date(timeIntervalSince1970: intervalStart)
            totals[date, default: 0] += max(0, sample.uploadBytes)
        }
        return totals.map { ProxyUploadBucket(date: $0.key, uploadBytes: $0.value) }
            .sorted { $0.date < $1.date }
    }
}

enum ProxyDestinationRanking {
    static func rank(_ events: [ProxyUploadRecord]) -> [ProxyDestinationRow] {
        var totals: [String: (bytes: Int64, count: Int)] = [:]
        for event in events {
            let key = event.host.lowercased()
            guard !key.isEmpty else { continue }
            var current = totals[key] ?? (0, 0)
            current.bytes += max(0, event.uploadBytes)
            current.count += 1
            totals[key] = current
        }
        return totals.map { host, total in
            ProxyDestinationRow(host: host, uploadBytes: total.bytes, requestCount: total.count)
        }.sorted {
            if $0.uploadBytes != $1.uploadBytes { return $0.uploadBytes > $1.uploadBytes }
            return $0.host < $1.host
        }
    }
}

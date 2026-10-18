import Foundation

struct UploadRateSample: Identifiable, Codable {
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

struct EvidenceEndpoint: Codable, Hashable {
    let address: String
    let transport: String
    let state: String?
}

/// Capturing a socket snapshot does not establish that upload bytes reached
/// any of these endpoints. Time correlation is the strongest available claim.
struct EvidenceConnectionSnapshot: Codable, Hashable {
    let capturedAt: Date
    let endpoints: [EvidenceEndpoint]
}

struct UploadIncident: Identifiable, Codable {
    let id: UUID
    let applicationName: String
    let observedPIDs: [Int]
    let triggeredAt: Date
    let triggerBytesPerSecond: Int
    let windowEnd: Date
    var samples: [UploadRateSample]
    var connections: [EvidenceConnectionSnapshot]
    var isComplete: Bool
    var peakUploadBytesPerSecond: Int {
        samples.map(\.uploadBytesPerSecond).max() ?? triggerBytesPerSecond
    }
}

/// A bounded, in-memory sample window. This uses nettop's application rate
/// samples, *not* the unattributed system HTTP proxy. Endpoints are separate
/// socket snapshots and do not carry per-destination byte counters.
struct TrafficAnalysisBuffer {
    private(set) var samples: [UploadRateSample] = []
    private(set) var spikes: [UploadSpike] = []
    private(set) var incidents: [UploadIncident] = []
    private var observedConnections: [EvidenceConnectionSnapshot] = []
    private let maxSamples = 150 // approximately five minutes at 2 s/frame

    var peakUploadBytesPerSecond: Int { samples.map(\.uploadBytesPerSecond).max() ?? 0 }
    var currentUploadBytesPerSecond: Int { samples.last?.uploadBytesPerSecond ?? 0 }

    mutating func append(
        at date: Date,
        upload: Int,
        download: Int,
        applicationName: String = "",
        observedPIDs: [Int] = [],
        connectionSnapshot: EvidenceConnectionSnapshot? = nil
    ) {
        let safeUpload = max(0, upload)
        if let connectionSnapshot,
           connectionSnapshot.capturedAt <= date,
           date.timeIntervalSince(connectionSnapshot.capturedAt) <= 8,
           observedConnections.last?.capturedAt != connectionSnapshot.capturedAt {
            observedConnections.append(connectionSnapshot)
        }
        observedConnections.removeAll { date.timeIntervalSince($0.capturedAt) > 20 }
        incidents.removeAll { date.timeIntervalSince($0.triggeredAt) > 1800 }
        // Previous eight observations form a stable, easily explainable
        // baseline; require at least one MiB/s to avoid classifying idle noise.
        let baseline = samples.suffix(8).map(\.uploadBytesPerSecond).sorted()
        let median = baseline.isEmpty ? 0 : baseline[baseline.count / 2]
        let previous = samples.last?.uploadBytesPerSecond ?? 0
        let threshold = max(1_048_576, median * 4)
        let isSpike = samples.count >= 4 && safeUpload >= threshold && previous < threshold &&
            date.timeIntervalSince(spikes.last?.date ?? .distantPast) >= 20
        if isSpike {
            spikes.append(UploadSpike(date: date, bytesPerSecond: safeUpload))
        }
        let sample = UploadRateSample(
            date: date, uploadBytesPerSecond: safeUpload,
            downloadBytesPerSecond: max(0, download)
        )
        samples.append(sample)
        for index in incidents.indices where !incidents[index].isComplete {
            if date <= incidents[index].windowEnd {
                incidents[index].samples.append(sample)
                if let connectionSnapshot,
                   connectionSnapshot.capturedAt <= date,
                   date.timeIntervalSince(connectionSnapshot.capturedAt) <= 8,
                   incidents[index].connections.last?.capturedAt != connectionSnapshot.capturedAt {
                    incidents[index].connections.append(connectionSnapshot)
                }
            }
            if date >= incidents[index].windowEnd {
                incidents[index].isComplete = true
            }
        }
        if isSpike {
            incidents.append(UploadIncident(
                id: UUID(),
                applicationName: applicationName,
                observedPIDs: observedPIDs.sorted(),
                triggeredAt: date,
                triggerBytesPerSecond: safeUpload,
                windowEnd: date.addingTimeInterval(20),
                samples: samples.filter { date.timeIntervalSince($0.date) <= 16 },
                connections: observedConnections.filter { date.timeIntervalSince($0.capturedAt) <= 16 },
                isComplete: false
            ))
            if incidents.count > 12 { incidents.removeFirst(incidents.count - 12) }
        }
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

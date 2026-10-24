import Foundation

struct TrafficHistorySnapshot {
    let applications: [HistoricalApplicationTraffic]
    let totals: TrafficTotals
}

final class NetworkTrafficHistoryStore {
    private struct Bucket: Codable {
        let appID: String
        var name: String
        var bundlePath: String?
        var bundleIdentifier: String?
        var launchSourceName: String?
        let hourStart: TimeInterval
        var downloadedBytes: UInt64
        var uploadedBytes: UInt64
    }

    private struct Payload: Codable {
        var buckets: [Bucket]
    }

    private let retention: TimeInterval = 8 * 24 * 60 * 60
    private let saveInterval: TimeInterval = 20
    private var bucketsByKey: [String: Bucket] = [:]
    private var lastObservedSessionTotals: [String: TrafficTotals] = [:]
    private var lastSaveAt = Date.distantPast

    private let overrideURL: URL?
    private(set) var loadError: Error?

    init(url: URL? = nil) {
        overrideURL = url
        if url == nil { migrateLegacyStoreIfNeeded() }
        do { try load() } catch { loadError = error }
        prune(now: Date())
    }

    func record(applications: [ApplicationTraffic]) throws {
        if let loadError { throw loadError }
        let now = Date()
        // 15-minute buckets keep 1/3/7-day rolling totals reasonably precise
        // without turning the tiny local history file into a per-sample log.
        let hourStart = floor(now.timeIntervalSince1970 / 900) * 900

        for app in applications {
            let current = TrafficTotals(
                downloadedBytes: app.downloadedBytes,
                uploadedBytes: app.uploadedBytes
            )
            let previous = lastObservedSessionTotals[app.id] ?? .zero
            let downloadedDelta = current.downloadedBytes >= previous.downloadedBytes
                ? current.downloadedBytes - previous.downloadedBytes
                : current.downloadedBytes
            let uploadedDelta = current.uploadedBytes >= previous.uploadedBytes
                ? current.uploadedBytes - previous.uploadedBytes
                : current.uploadedBytes
            lastObservedSessionTotals[app.id] = current

            guard downloadedDelta > 0 || uploadedDelta > 0 else { continue }

            let key = "\(app.id)|\(Int(hourStart))"
            if var bucket = bucketsByKey[key] {
                bucket.name = app.name
                bucket.bundlePath = app.bundlePath
                bucket.bundleIdentifier = app.bundleIdentifier
                bucket.launchSourceName = app.launchSourceName
                bucket.downloadedBytes += downloadedDelta
                bucket.uploadedBytes += uploadedDelta
                bucketsByKey[key] = bucket
            } else {
                bucketsByKey[key] = Bucket(
                    appID: app.id,
                    name: app.name,
                    bundlePath: app.bundlePath,
                    bundleIdentifier: app.bundleIdentifier,
                    launchSourceName: app.launchSourceName,
                    hourStart: hourStart,
                    downloadedBytes: downloadedDelta,
                    uploadedBytes: uploadedDelta
                )
            }
        }

        if now.timeIntervalSince(lastSaveAt) >= saveInterval {
            prune(now: now)
            try save()
            lastSaveAt = now
        }
    }

    func snapshot(days: Int) -> TrafficHistorySnapshot {
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60).timeIntervalSince1970
        let matching = bucketsByKey.values.filter { $0.hourStart >= cutoff }
        var grouped: [String: (
            name: String,
            bundlePath: String?,
            bundleIdentifier: String?,
            launchSourceName: String?,
            totals: TrafficTotals
        )] = [:]

        for bucket in matching {
            var entry = grouped[bucket.appID] ?? (
                bucket.name,
                bucket.bundlePath,
                bucket.bundleIdentifier,
                bucket.launchSourceName,
                .zero
            )
            entry.name = bucket.name
            entry.bundlePath = bucket.bundlePath
            entry.bundleIdentifier = bucket.bundleIdentifier
            entry.launchSourceName = bucket.launchSourceName
            entry.totals.downloadedBytes += bucket.downloadedBytes
            entry.totals.uploadedBytes += bucket.uploadedBytes
            grouped[bucket.appID] = entry
        }

        let applications = grouped.map { id, value in
            HistoricalApplicationTraffic(
                id: id,
                name: value.name,
                bundlePath: value.bundlePath,
                bundleIdentifier: value.bundleIdentifier,
                launchSourceName: value.launchSourceName,
                totals: value.totals
            )
        }
        .sorted { lhs, rhs in
            if lhs.totals.uploadedBytes != rhs.totals.uploadedBytes {
                return lhs.totals.uploadedBytes > rhs.totals.uploadedBytes
            }
            if lhs.totals.downloadedBytes != rhs.totals.downloadedBytes {
                return lhs.totals.downloadedBytes > rhs.totals.downloadedBytes
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let totals = applications.reduce(into: TrafficTotals.zero) { partial, app in
            partial.downloadedBytes += app.totals.downloadedBytes
            partial.uploadedBytes += app.totals.uploadedBytes
        }
        return TrafficHistorySnapshot(applications: applications, totals: totals)
    }

    func clear() throws {
        do { try FileManager.default.removeItem(at: storageURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
        bucketsByKey.removeAll(keepingCapacity: false)
        lastObservedSessionTotals.removeAll(keepingCapacity: false)
        lastSaveAt = Date()
        loadError = nil
    }

    func flush() throws {
        if let loadError { throw loadError }
        try save()
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention).timeIntervalSince1970
        bucketsByKey = bucketsByKey.filter { $0.value.hourStart >= cutoff }
    }

    private func load() throws {
        let data: Data
        do { data = try Data(contentsOf: storageURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var loaded: [String: Bucket] = [:]
        for bucket in payload.buckets {
            let key = "\(bucket.appID)|\(Int(bucket.hourStart))"
            guard loaded.updateValue(bucket, forKey: key) == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        bucketsByKey = loaded
    }

    private func save() throws {
        let payload = Payload(buckets: Array(bucketsByKey.values))
        let data = try JSONEncoder().encode(payload)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: [.atomic])
    }

    private func migrateLegacyStoreIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: storageURL.path),
              fileManager.fileExists(atPath: legacyStorageURL.path) else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyStorageURL, to: storageURL)

            let legacyDirectory = legacyStorageURL.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: legacyDirectory.path).isEmpty) == true {
                try? fileManager.removeItem(at: legacyDirectory)
            }
        } catch {
            loadError = error
        }
    }

    private var storageURL: URL {
        if let overrideURL { return overrideURL }
        return applicationSupportURL
            .appendingPathComponent("DevRadar", isDirectory: true)
            .appendingPathComponent("network-history.json")
    }

    private var legacyStorageURL: URL {
        applicationSupportURL
            .appendingPathComponent("pscan", isDirectory: true)
            .appendingPathComponent("network-history.json")
    }

    private var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }
}


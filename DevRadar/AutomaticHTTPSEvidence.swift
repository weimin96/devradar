import Foundation
import Observation

/// Explicitly metadata-only, automatic on an upload anomaly. This starts
/// non-privileged nettop for a bounded time, NOT tcpdump, MITM, or HTTPS body
/// capture. Records are local and never uploaded.
@Observable
final class AutomaticHTTPSEvidenceManager {
    private final class Running {
        let id = UUID()
        let app: ApplicationTraffic
        let triggeredAt: Date
        let startedAt: Date
        let reader: HTTPSConnectionReader
        var captured: [AutomaticHTTPSObservation] = []
        var timer: Timer?
        var error: String?

        init(app: ApplicationTraffic, triggeredAt: Date, reader: HTTPSConnectionReader) {
            self.app = app
            self.triggeredAt = triggeredAt
            self.startedAt = Date()
            self.reader = reader
        }
    }

    private(set) var records: [AutomaticHTTPSRecord] = []
    private(set) var activeApps: Set<String> = []
    var lastError: String?

    @ObservationIgnored private var sessions: [String: Running] = [:]
    @ObservationIgnored private var recentTriggers: [String: Date] = [:]
    @ObservationIgnored private var highSampleCount: [String: Int] = [:]

    private static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevRadar/AutomaticHTTPS", isDirectory: true)
    }

    private let directory: URL

    init(directory: URL = AutomaticHTTPSEvidenceManager.defaultDirectory) {
        self.directory = directory
        restoreFromDisk()
    }

    func observe(application: ApplicationTraffic, newlyDetectedSpike: Bool, at now: Date) {
        let enabled = (UserDefaults.standard.object(forKey: "automaticHTTPSConnectionEvidence") as? Bool) ?? true
        let ignored = IgnoreRules.strings(
            from: UserDefaults.standard.string(forKey: IgnoreRules.networkApplicationsKey) ?? "[]"
        )
        guard enabled, !ignored.contains(application.id) else {
            highSampleCount.removeValue(forKey: application.id)
            return
        }
        let warningRate = UserDefaults.standard.object(forKey: "networkAlertThresholdMBps") as? Double ?? 5
        let threshold = Int(max(1, warningRate) * 1_048_576)
        let count = application.uploadBytesPerSecond >= threshold
            ? min(3, (highSampleCount[application.id] ?? 0) + 1) : 0
        highSampleCount[application.id] = count
        guard AutomaticHTTPSPolicy.shouldBegin(
            now: now, pids: application.pids,
            uploadRate: application.uploadBytesPerSecond, newSpike: newlyDetectedSpike,
            consecutiveHighSamples: count,
            activeCount: sessions.count, lastCapture: recentTriggers[application.id]
        ) else { return }
        begin(application: application, triggeredAt: now)
    }

    func stopAll() {
        for key in Array(sessions.keys) { finish(key: key, status: "stopped") }
        highSampleCount.removeAll()
    }

    @discardableResult
    func clearSavedRecords() -> Bool {
        stopAll()
        do {
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
            records.removeAll()
            recentTriggers.removeAll()
            highSampleCount.removeAll()
            lastError = nil
            return true
        } catch {
            lastError = "自动连接证据清空失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteRecord(_ record: AutomaticHTTPSRecord) -> Bool {
        do {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(record.id.uuidString + ".json")) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
            records.removeAll { $0.id == record.id }
            lastError = nil
            return true
        } catch {
            lastError = "自动连接证据删除失败：\(error.localizedDescription)"
            return false
        }
    }

    private func begin(application: ApplicationTraffic, triggeredAt: Date) {
        let reader = HTTPSConnectionReader(pids: application.pids)
        let session = Running(app: application, triggeredAt: triggeredAt, reader: reader)
        sessions[application.id] = session
        recentTriggers[application.id] = triggeredAt
        activeApps.insert(application.id)
        reader.onUpdate = { [weak self, weak session] connections in
            DispatchQueue.main.async {
                guard let self, let session,
                      self.sessions[session.app.id] === session else { return }
                let time = Date()
                let flows = Array(connections.prefix(80)).map { connection in
                    AutomaticHTTPSFlow(
                        id: connection.id, pid: connection.pid,
                        transport: connection.transport, remoteAddress: connection.remoteAddress,
                        classification: connection.protocolLabel,
                        uploadedBytes: connection.uploadedBytes, downloadedBytes: connection.downloadedBytes
                    )
                }
                let observation = AutomaticHTTPSObservation(timestamp: time, flows: flows)
                if let last = session.captured.last,
                   time.timeIntervalSince(last.timestamp) < 1.5 {
                    // nettop may deliver multiple rows in separate chunks.
                    // Replace the partial current frame instead of filling the
                    // 32-observation limit in the first few milliseconds.
                    session.captured[session.captured.count - 1] = observation
                } else if session.captured.count < 32 {
                    session.captured.append(observation)
                }
            }
        }
        reader.onError = { [weak self, weak session] error in
            DispatchQueue.main.async {
                guard let self, let session,
                      self.sessions[session.app.id] === session else { return }
                session.error = error
                self.finish(key: session.app.id, status: "reader-error")
            }
        }
        reader.start()
        session.timer = Timer.scheduledTimer(withTimeInterval: AutomaticHTTPSPolicy.duration, repeats: false) { [weak self] _ in
            self?.finish(key: application.id, status: "completed")
        }
    }

    private func finish(key: String, status: String) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.timer?.invalidate()
        session.reader.stop()
        activeApps.remove(key)
        let record = AutomaticHTTPSRecord(
            id: session.id, applicationID: session.app.id,
            applicationName: session.app.name,
            pids: session.app.pids,
            triggeredAt: session.triggeredAt,
            triggerUploadBytesPerSecond: session.app.uploadBytesPerSecond,
            monitorStartedAt: session.startedAt, monitorFinishedAt: Date(),
            status: session.error.map { "\(status): \($0)" } ?? status,
            observations: session.captured
        )
        records.insert(record, at: 0)
        if records.count > AutomaticHTTPSPolicy.maxSavedRecords {
            records.removeLast(records.count - AutomaticHTTPSPolicy.maxSavedRecords)
        }
        persist(record)
    }

    private func persist(_ record: AutomaticHTTPSRecord) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let url = directory.appendingPathComponent(record.id.uuidString + ".json")
            try encoder.encode(record).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastError = nil
            pruneStorage()
        } catch {
            lastError = "自动连接证据保存失败：\(error.localizedDescription)"
        }
    }

    private func restoreFromDisk() {
        do {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var restored: [AutomaticHTTPSRecord] = []
            for file in files where file.pathExtension == "json" {
                do { restored.append(try decoder.decode(AutomaticHTTPSRecord.self, from: Data(contentsOf: file))) }
                catch { lastError = "自动连接证据读取失败（\(file.lastPathComponent)）：\(error.localizedDescription)" }
            }
            records = Array(restored.filter { Date().timeIntervalSince($0.triggeredAt) < AutomaticHTTPSPolicy.retention }
                .sorted { $0.triggeredAt > $1.triggeredAt }.prefix(AutomaticHTTPSPolicy.maxSavedRecords))
            pruneStorage()
        } catch {
            lastError = "自动连接证据读取失败：\(error.localizedDescription)"
        }
    }

    private func pruneStorage() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let retained = Set(records.map { $0.id.uuidString + ".json" })
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for file in files where file.pathExtension == "json" && !retained.contains(file.lastPathComponent) {
                do {
                    _ = try decoder.decode(AutomaticHTTPSRecord.self, from: Data(contentsOf: file))
                } catch {
                    lastError = "自动连接证据读取失败，已保留原文件：\(file.lastPathComponent)"
                    continue
                }
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            lastError = "自动连接证据清理失败：\(error.localizedDescription)"
        }
    }
}

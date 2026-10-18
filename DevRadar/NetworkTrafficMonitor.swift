import AppKit
import Foundation
import Observation
import UserNotifications

struct ProcessTraffic: Identifiable, Hashable {
    let pid: Int
    let processName: String
    let downloadBytesPerSecond: Int
    let uploadBytesPerSecond: Int
    let downloadedDeltaBytes: UInt64
    let uploadedDeltaBytes: UInt64
    let downloadedBytes: UInt64
    let uploadedBytes: UInt64
    let directory: String?
    let projectDirectory: String?
    let executablePath: String?
    let command: String?
    let launchSourceName: String?
    let launchSourceBundlePath: String?
    let launchSourceBundleIdentifier: String?
    let connectionCount: Int
    let remoteEndpoints: [RemoteEndpoint]

    var id: Int { pid }

    var projectName: String? {
        guard let projectDirectory else { return nil }
        let url = URL(fileURLWithPath: projectDirectory)
        let name = url.lastPathComponent
        if name.first?.isNumber == true, name.contains(".") {
            let parentName = url.deletingLastPathComponent().lastPathComponent
            if !parentName.isEmpty {
                return parentName
            }
        }
        return name
    }
}

struct RemoteEndpoint: Identifiable, Hashable {
    let transport: String
    let address: String
    let state: String?

    var id: String { "\(transport):\(address):\(state ?? "")" }

    var isLocal: Bool {
        let value = host.lowercased()
        return value.hasPrefix("127.") || value == "::1" || value == "localhost"
    }

    var scopeLabel: String? {
        if isLocal { return "本机" }
        if isPrivateNetwork { return "局域网" }
        return nil
    }

    private var host: String {
        if address.hasPrefix("["), let closing = address.firstIndex(of: "]") {
            return String(address[address.index(after: address.startIndex)..<closing])
        }
        guard let colon = address.lastIndex(of: ":") else { return address }
        return String(address[..<colon])
    }

    private var isPrivateNetwork: Bool {
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        guard host.hasPrefix("172."),
              let second = Int(host.split(separator: ".").dropFirst().first ?? "") else {
            return false
        }
        return (16...31).contains(second)
    }
}

struct ApplicationTraffic: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePath: String?
    let bundleIdentifier: String?
    let launchSourceName: String?
    let processNames: [String]
    let pids: [Int]
    let downloadBytesPerSecond: Int
    let uploadBytesPerSecond: Int
    let downloadedBytes: UInt64
    let uploadedBytes: UInt64
    let projectDirectories: [String]
    let workingDirectories: [String]
    let connectionCount: Int
    let remoteEndpoints: [RemoteEndpoint]

    var processCount: Int { pids.count }
}

struct TrafficTotals: Codable, Hashable {
    var downloadedBytes: UInt64 = 0
    var uploadedBytes: UInt64 = 0

    static let zero = TrafficTotals()
}

struct HistoricalApplicationTraffic: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePath: String?
    let bundleIdentifier: String?
    let launchSourceName: String?
    let totals: TrafficTotals
}

struct OpenProjectFile: Identifiable, Hashable {
    let pid: Int
    let processName: String
    let path: String
    let projectDirectory: String?

    var id: String { "\(pid):\(path)" }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

private struct ConnectionSnapshot {
    let count: Int
    let endpoints: [RemoteEndpoint]
}

private struct TrafficHistorySnapshot {
    let applications: [HistoricalApplicationTraffic]
    let totals: TrafficTotals
}

private struct ProcessOrigin {
    let command: String?
    let launchSourceName: String?
    let launchSourceBundlePath: String?
    let launchSourceBundleIdentifier: String?
    let inferredProjectDirectory: String?
}

@Observable
final class NetworkTrafficMonitor {
    var processes: [ProcessTraffic] = []
    var applications: [ApplicationTraffic] = []
    var totalDownloadBytesPerSecond = 0
    var totalUploadBytesPerSecond = 0
    var history1DayApplications: [HistoricalApplicationTraffic] = []
    var history3DayApplications: [HistoricalApplicationTraffic] = []
    var history7DayApplications: [HistoricalApplicationTraffic] = []
    var history1DayTotals = TrafficTotals.zero
    var history3DayTotals = TrafficTotals.zero
    var history7DayTotals = TrafficTotals.zero
    var lastError: String?
    var isRunning = false
    private(set) var uploadAnalysis: [String: TrafficAnalysisBuffer] = [:]

    private let sampleInterval = 2
    private let activityRetention: TimeInterval = 300
    private let historyStore = NetworkTrafficHistoryStore()
    private var reader: NettopTrafficReader?
    private var directoryCache: [Int: String] = [:]
    private var resolvedDirectoryPIDs = Set<Int>()
    private var executablePathCache: [Int: String] = [:]
    private var resolvedExecutablePIDs = Set<Int>()
    private var inputMethodProcesses: [Int: String] = [:]
    private var processOriginCache: [Int: ProcessOrigin] = [:]
    private var resolvedProcessOriginPIDs = Set<Int>()
    private var cumulativeByPID: [Int: (download: UInt64, upload: UInt64)] = [:]
    private var cumulativeByApplicationID: [String: (download: UInt64, upload: UInt64)] = [:]
    private var connectionsByPID: [Int: ConnectionSnapshot] = [:]
    private var lastConnectionInspectionAt: Date?
    private var processNamesByPID: [Int: String] = [:]
    private var lastActiveAtByPID: [Int: Date] = [:]
    private var frameNumber = 0
    private var inspectConnections = false
    private var lastHistoryRefreshAt = Date.distantPast
    private var highUploadFramesByApplicationID: [String: Int] = [:]
    private var lastNetworkAlertAtByApplicationID: [String: Date] = [:]

    init() {
        refreshHistorySnapshots()
    }

    func start() {
        guard reader == nil else { return }

        let reader = NettopTrafficReader(interval: sampleInterval)
        reader.onFrame = { [weak self] lines in
            self?.handleFrame(lines)
        }
        reader.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.lastError = message
                self?.isRunning = false
            }
        }
        self.reader = reader
        isRunning = true
        reader.start()
    }

    func stop() {
        reader?.stop()
        reader = nil
        isRunning = false
    }

    func clearTrafficHistory() {
        uploadAnalysis.removeAll()
        cumulativeByPID.removeAll(keepingCapacity: true)
        cumulativeByApplicationID.removeAll(keepingCapacity: true)
        historyStore.clear()

        processes = processes.map { process in
            ProcessTraffic(
                pid: process.pid,
                processName: process.processName,
                downloadBytesPerSecond: process.downloadBytesPerSecond,
                uploadBytesPerSecond: process.uploadBytesPerSecond,
                downloadedDeltaBytes: 0,
                uploadedDeltaBytes: 0,
                downloadedBytes: 0,
                uploadedBytes: 0,
                directory: process.directory,
                projectDirectory: process.projectDirectory,
                executablePath: process.executablePath,
                command: process.command,
                launchSourceName: process.launchSourceName,
                launchSourceBundlePath: process.launchSourceBundlePath,
                launchSourceBundleIdentifier: process.launchSourceBundleIdentifier,
                connectionCount: process.connectionCount,
                remoteEndpoints: process.remoteEndpoints
            )
        }

        var resetApplicationTotals: [String: (download: UInt64, upload: UInt64)] = [:]
        applications = Self.aggregateApplications(processes, cumulativeTotals: &resetApplicationTotals)
        cumulativeByApplicationID = resetApplicationTotals
        refreshHistorySnapshots()
        lastHistoryRefreshAt = Date()
    }

    func traffic(for pid: Int) -> ProcessTraffic? {
        processes.first { $0.pid == pid }
    }

    func setConnectionInspectionEnabled(_ enabled: Bool) {
        inspectConnections = enabled
        if !enabled {
            connectionsByPID.removeAll(keepingCapacity: true)
            lastConnectionInspectionAt = nil
        }
    }

    func inspectOpenProjectFiles(
        for pids: [Int],
        completion: @escaping ([OpenProjectFile]) -> Void
    ) {
        let processNames = Dictionary(uniqueKeysWithValues: processes
            .filter { pids.contains($0.pid) }
            .map { ($0.pid, $0.processName) })

        DispatchQueue.global(qos: .utility).async {
            let files = Self.openProjectFiles(for: pids, processNames: processNames)
            DispatchQueue.main.async {
                completion(files)
            }
        }
    }

    private func handleFrame(_ lines: [String]) {
        var ratesByPID: [Int: (name: String, download: Int, upload: Int, downloadDelta: Int, uploadDelta: Int)] = [:]

        for line in lines {
            guard let sample = parse(line) else { continue }
            let existing = ratesByPID[sample.pid]
            ratesByPID[sample.pid] = (
                sample.name,
                (existing?.download ?? 0) + sample.download,
                (existing?.upload ?? 0) + sample.upload,
                (existing?.downloadDelta ?? 0) + sample.downloadDelta,
                (existing?.uploadDelta ?? 0) + sample.uploadDelta
            )
        }

        for (pid, sample) in ratesByPID {
            if let previousName = processNamesByPID[pid], previousName != sample.name {
                cumulativeByPID[pid] = (0, 0)
            }
            let existing = cumulativeByPID[pid] ?? (0, 0)
            cumulativeByPID[pid] = (
                existing.download + UInt64(max(0, sample.downloadDelta)),
                existing.upload + UInt64(max(0, sample.uploadDelta))
            )
            processNamesByPID[pid] = sample.name
        }

        let totalDownload = ratesByPID.values.reduce(0) { $0 + $1.download }
        let totalUpload = ratesByPID.values.reduce(0) { $0 + $1.upload }
        let now = Date()
        for (pid, rate) in ratesByPID where rate.download > 0 || rate.upload > 0 {
            lastActiveAtByPID[pid] = now
        }

        frameNumber += 1
        // Input methods are long-lived background agents. Some connect
        // directly to remote IPs and remain idle between short upload bursts.
        // Keep their existing PIDs visible instead of hiding them whenever
        // nettop temporarily reports 0 bytes and a socket disappears.
        // Discover by installation location, not by product or vendor name.
        if frameNumber == 1 || frameNumber % 6 == 0 {
            let previousPIDs = Set(inputMethodProcesses.keys)
            inputMethodProcesses = Self.runningInputMethodProcesses()
            for pid in previousPIDs.subtracting(inputMethodProcesses.keys) {
                lastActiveAtByPID.removeValue(forKey: pid)
            }
        }
        for (pid, path) in inputMethodProcesses {
            lastActiveAtByPID[pid] = now
            executablePathCache[pid] = path
            resolvedExecutablePIDs.insert(pid)
            if processNamesByPID[pid] == nil {
                processNamesByPID[pid] = URL(fileURLWithPath: path).lastPathComponent
            }
        }
        if inspectConnections, (frameNumber == 1 || frameNumber % 3 == 0) {
            let connectionSnapshot = Self.connectionSnapshotsForAllProcesses()
            connectionsByPID = connectionSnapshot.snapshots
            lastConnectionInspectionAt = now
            for (pid, name) in connectionSnapshot.processNames {
                if processNamesByPID[pid] == nil {
                    processNamesByPID[pid] = name
                }
                lastActiveAtByPID[pid] = now
            }
        }

        lastActiveAtByPID = lastActiveAtByPID.filter { _, date in
            now.timeIntervalSince(date) <= activityRetention
        }
        let retainedPIDs = Set(lastActiveAtByPID.keys)
        processNamesByPID = processNamesByPID.filter { retainedPIDs.contains($0.key) }
        directoryCache = directoryCache.filter { retainedPIDs.contains($0.key) }
        resolvedDirectoryPIDs.formIntersection(retainedPIDs)
        executablePathCache = executablePathCache.filter { retainedPIDs.contains($0.key) }
        resolvedExecutablePIDs.formIntersection(retainedPIDs)
        processOriginCache = processOriginCache.filter { retainedPIDs.contains($0.key) }
        resolvedProcessOriginPIDs.formIntersection(retainedPIDs)
        connectionsByPID = connectionsByPID.filter { retainedPIDs.contains($0.key) }

        let active = retainedPIDs.map { pid in
            let rate = ratesByPID[pid]
            return (
                pid: pid,
                name: rate?.name ?? processNamesByPID[pid] ?? "process",
                download: rate?.download ?? 0,
                upload: rate?.upload ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.upload != rhs.upload { return lhs.upload > rhs.upload }
            if lhs.download != rhs.download { return lhs.download > rhs.download }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        // Directory lookup uses one batched lsof invocation and only runs for
        // newly-seen busy processes. This keeps the always-on monitor cheap.
        let enrichedPIDs = Array(active.prefix(24).map(\.pid))
        let unresolvedPIDs = enrichedPIDs.filter { !resolvedDirectoryPIDs.contains($0) }
        if !unresolvedPIDs.isEmpty {
            let resolved = PortScanner.workingDirectories(for: unresolvedPIDs)
            directoryCache.merge(resolved) { _, new in new }
            resolvedDirectoryPIDs.formUnion(unresolvedPIDs)
        }

        let unresolvedExecutablePIDs = Array(retainedPIDs).filter { !resolvedExecutablePIDs.contains($0) }
        if !unresolvedExecutablePIDs.isEmpty {
            let resolved = Self.executablePaths(for: Array(unresolvedExecutablePIDs.prefix(96)))
            executablePathCache.merge(resolved) { _, new in new }
            resolvedExecutablePIDs.formUnion(unresolvedExecutablePIDs.prefix(96))
        }

        let unresolvedOriginPIDs = Array(retainedPIDs).filter { !resolvedProcessOriginPIDs.contains($0) }
        if !unresolvedOriginPIDs.isEmpty {
            let targetPIDs = Array(unresolvedOriginPIDs.prefix(96))
            let resolved = Self.processOrigins(for: targetPIDs, directories: directoryCache)
            processOriginCache.merge(resolved) { _, new in new }
            resolvedProcessOriginPIDs.formUnion(targetPIDs)
        }

        let snapshots = active.map { item in
            let pid = item.pid
            let directory = directoryCache[pid]
            let origin = processOriginCache[pid]
            let projectDirectory = Self.meaningfulProjectDirectory(from: directory)
                ?? origin?.inferredProjectDirectory
            let cumulative = cumulativeByPID[pid] ?? (0, 0)
            return ProcessTraffic(
                pid: pid,
                processName: item.name,
                downloadBytesPerSecond: item.download,
                uploadBytesPerSecond: item.upload,
                downloadedDeltaBytes: UInt64(max(0, ratesByPID[pid]?.downloadDelta ?? 0)),
                uploadedDeltaBytes: UInt64(max(0, ratesByPID[pid]?.uploadDelta ?? 0)),
                downloadedBytes: cumulative.download,
                uploadedBytes: cumulative.upload,
                directory: directory,
                projectDirectory: projectDirectory,
                executablePath: executablePathCache[pid],
                command: origin?.command,
                launchSourceName: origin?.launchSourceName,
                launchSourceBundlePath: origin?.launchSourceBundlePath,
                launchSourceBundleIdentifier: origin?.launchSourceBundleIdentifier,
                connectionCount: connectionsByPID[pid]?.count ?? 0,
                remoteEndpoints: connectionsByPID[pid]?.endpoints ?? []
            )
        }

        // The socket inspection runs less frequently than nettop; carry the
        // actual socket observation time and never call an old snapshot new.
        let inspectedAt = inspectConnections ? lastConnectionInspectionAt : nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.processes = snapshots
            var applicationTotals = self.cumulativeByApplicationID
            self.applications = Self.aggregateApplications(snapshots, cumulativeTotals: &applicationTotals)
            let activeIDs = Set(self.applications.map(\.id))
            self.uploadAnalysis = self.uploadAnalysis.filter { id, buffer in
                activeIDs.contains(id) ||
                    buffer.incidents.contains { now.timeIntervalSince($0.triggeredAt) <= 1800 }
            }
            for app in self.applications {
                var buffer = self.uploadAnalysis[app.id] ?? TrafficAnalysisBuffer()
                buffer.append(
                    at: now,
                    upload: app.uploadBytesPerSecond,
                    download: app.downloadBytesPerSecond,
                    applicationName: app.name,
                    observedPIDs: app.pids,
                    connectionSnapshot: inspectedAt.map { observedAt in
                        EvidenceConnectionSnapshot(
                            capturedAt: observedAt,
                            endpoints: Array(app.remoteEndpoints.filter { !$0.isLocal }
                                .prefix(24).map {
                                    EvidenceEndpoint(
                                        address: $0.address,
                                        transport: $0.transport,
                                        state: $0.state
                                    )
                                })
                        )
                    }
                )
                self.uploadAnalysis[app.id] = buffer
            }
            self.cumulativeByApplicationID = applicationTotals
            self.evaluateNetworkAlerts()
            self.historyStore.record(applications: self.applications)
            let now = Date()
            if now.timeIntervalSince(self.lastHistoryRefreshAt) >= 10 {
                self.refreshHistorySnapshots()
                self.lastHistoryRefreshAt = now
            }
            self.totalDownloadBytesPerSecond = totalDownload
            self.totalUploadBytesPerSecond = totalUpload
            self.lastError = nil
            self.isRunning = true
        }
    }


    func requestNetworkAlertPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func evaluateNetworkAlerts() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "networkAlertEnabled") as? Bool ?? true
        guard enabled else {
            highUploadFramesByApplicationID.removeAll(keepingCapacity: true)
            return
        }

        let thresholdMBps = defaults.object(forKey: "networkAlertThresholdMBps") as? Double ?? 5
        let thresholdBytesPerSecond = Int(thresholdMBps * 1_024 * 1_024)
        let ignoredApplications = IgnoreRules.strings(
            from: defaults.string(forKey: IgnoreRules.networkApplicationsKey) ?? "[]"
        )
        let activeIDs = Set(applications.map(\.id))
        highUploadFramesByApplicationID = highUploadFramesByApplicationID.filter { activeIDs.contains($0.key) }

        for application in applications {
            guard !ignoredApplications.contains(application.id) else {
                highUploadFramesByApplicationID[application.id] = 0
                continue
            }

            if application.uploadBytesPerSecond >= thresholdBytesPerSecond {
                let frames = (highUploadFramesByApplicationID[application.id] ?? 0) + 1
                highUploadFramesByApplicationID[application.id] = frames
                guard frames >= 2 else { continue }

                let now = Date()
                if let previous = lastNetworkAlertAtByApplicationID[application.id],
                   now.timeIntervalSince(previous) < 600 {
                    continue
                }
                lastNetworkAlertAtByApplicationID[application.id] = now
                deliverNetworkAlert(application, thresholdMBps: thresholdMBps)
            } else {
                highUploadFramesByApplicationID[application.id] = 0
            }
        }
    }

    private func deliverNetworkAlert(_ application: ApplicationTraffic, thresholdMBps: Double) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "异常上传提醒"
        let rate = Double(application.uploadBytesPerSecond) / 1_024 / 1_024
        content.body = String(
            format: "%@ 持续上传 %.1f MB/s，超过 %.0f MB/s 阈值",
            application.name,
            rate,
            thresholdMBps
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "network-upload-\(application.id)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                center.add(request)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            default:
                break
            }
        }
    }

    private func refreshHistorySnapshots() {
        let oneDay = historyStore.snapshot(days: 1)
        let threeDays = historyStore.snapshot(days: 3)
        let sevenDays = historyStore.snapshot(days: 7)
        history1DayApplications = oneDay.applications
        history3DayApplications = threeDays.applications
        history7DayApplications = sevenDays.applications
        history1DayTotals = oneDay.totals
        history3DayTotals = threeDays.totals
        history7DayTotals = sevenDays.totals
    }

    private static func aggregateApplications(
        _ processes: [ProcessTraffic],
        cumulativeTotals: inout [String: (download: UInt64, upload: UInt64)]
    ) -> [ApplicationTraffic] {
        struct ApplicationKey: Hashable {
            let id: String
            let name: String
            let bundlePath: String?
            let bundleIdentifier: String?
            let launchSourceName: String?
        }

        let grouped = Dictionary(grouping: processes) { process -> ApplicationKey in
            let executableURL = process.executablePath.map(URL.init(fileURLWithPath:))
                ?? NSRunningApplication(processIdentifier: pid_t(process.pid))?.executableURL
            if let executableURL,
               let appURL = outermostApplicationURL(for: executableURL) {
                let bundle = Bundle(url: appURL)
                let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? appURL.deletingPathExtension().lastPathComponent
                return ApplicationKey(
                    id: "app:\(appURL.path)",
                    name: displayName,
                    bundlePath: appURL.path,
                    bundleIdentifier: bundle?.bundleIdentifier,
                    launchSourceName: nil
                )
            }

            let projectName = process.projectName
            let displayName: String
            if let projectName, !projectName.isEmpty {
                displayName = "\(process.processName) · \(projectName)"
            } else if let launchSourceName = process.launchSourceName, !launchSourceName.isEmpty {
                displayName = "\(process.processName) · \(launchSourceName)"
            } else {
                displayName = process.processName
            }

            let groupingID = [
                process.processName.lowercased(),
                process.projectDirectory ?? "",
                process.launchSourceBundlePath ?? process.launchSourceName ?? "",
            ].joined(separator: "|")
            return ApplicationKey(
                id: "process:\(groupingID)",
                name: displayName,
                bundlePath: process.launchSourceBundlePath,
                bundleIdentifier: process.launchSourceBundleIdentifier,
                launchSourceName: process.launchSourceName
            )
        }

        return grouped.map { key, items in
            let deltaDownload = items.reduce(UInt64.zero) { $0 + $1.downloadedDeltaBytes }
            let deltaUpload = items.reduce(UInt64.zero) { $0 + $1.uploadedDeltaBytes }
            let previous = cumulativeTotals[key.id] ?? (0, 0)
            let cumulative = (
                download: previous.download + deltaDownload,
                upload: previous.upload + deltaUpload
            )
            cumulativeTotals[key.id] = cumulative

            return ApplicationTraffic(
                id: key.id,
                name: key.name,
                bundlePath: key.bundlePath,
                bundleIdentifier: key.bundleIdentifier,
                launchSourceName: key.launchSourceName,
                processNames: Array(Set(items.map(\.processName))).sorted(),
                pids: items.map(\.pid).sorted(),
                downloadBytesPerSecond: items.reduce(0) { $0 + $1.downloadBytesPerSecond },
                uploadBytesPerSecond: items.reduce(0) { $0 + $1.uploadBytesPerSecond },
                downloadedBytes: cumulative.download,
                uploadedBytes: cumulative.upload,
                projectDirectories: Array(Set(items.compactMap(\.projectDirectory))).sorted(),
                workingDirectories: Array(Set(items.compactMap(\.directory))).sorted(),
                connectionCount: items.reduce(0) { $0 + $1.connectionCount },
                remoteEndpoints: Array(Set(items.flatMap(\.remoteEndpoints))).sorted { lhs, rhs in
                    if lhs.isLocal != rhs.isLocal { return !lhs.isLocal }
                    return lhs.address.localizedCaseInsensitiveCompare(rhs.address) == .orderedAscending
                }
            )
        }
        .filter { application in
            if application.bundlePath != nil { return true }
            return application.workingDirectories.contains { $0.hasPrefix(NSHomeDirectory()) }
                || application.projectDirectories.contains { $0.hasPrefix(NSHomeDirectory()) }
        }
        .sorted { lhs, rhs in
            if lhs.uploadBytesPerSecond != rhs.uploadBytesPerSecond {
                return lhs.uploadBytesPerSecond > rhs.uploadBytesPerSecond
            }
            if lhs.downloadBytesPerSecond != rhs.downloadBytesPerSecond {
                return lhs.downloadBytesPerSecond > rhs.downloadBytesPerSecond
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func executablePaths(for pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = [
            "-p", pids.map(String.init).joined(separator: ","),
            "-o", "pid=",
            "-o", "comm=",
        ]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            var result: [Int: String] = [:]
            for rawLine in output.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty,
                      let split = line.firstIndex(where: { $0.isWhitespace }),
                      let pid = Int(line[..<split]) else { continue }
                let path = line[split...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    result[pid] = path
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    private static func runningInputMethodProcesses() -> [Int: String] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,comm="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return [:] }
            var found: [Int: String] = [:]
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let split = trimmed.firstIndex(where: { $0.isWhitespace }),
                      let pid = Int(trimmed[..<split]) else { continue }
                let path = trimmed[split...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/Library/Input Methods/") ||
                      path.hasPrefix(NSHomeDirectory() + "/Library/Input Methods/"),
                      path.contains(".app/Contents/") else { continue }
                found[pid] = path
            }
            return found
        } catch {
            return [:]
        }
    }

    private static func processOrigins(
        for pids: [Int],
        directories: [Int: String]
    ) -> [Int: ProcessOrigin] {
        guard !pids.isEmpty else { return [:] }

        let commands = processCommands(for: pids)
        let parents = parentPIDMap()
        return Dictionary(uniqueKeysWithValues: pids.map { pid in
            let command = commands[pid]
            let launcher = launchSource(for: pid, parents: parents)
            let inferredProjectDirectory = projectDirectoryFromCommand(command)
            return (
                pid,
                ProcessOrigin(
                    command: command,
                    launchSourceName: launcher?.name,
                    launchSourceBundlePath: launcher?.bundlePath,
                    launchSourceBundleIdentifier: launcher?.bundleIdentifier,
                    inferredProjectDirectory: meaningfulProjectDirectory(from: directories[pid])
                        ?? inferredProjectDirectory
                )
            )
        })
    }

    private static func processCommands(for pids: [Int]) -> [Int: String] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = [
            "-ww",
            "-p", pids.map(String.init).joined(separator: ","),
            "-o", "pid=",
            "-o", "command=",
        ]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            var result: [Int: String] = [:]
            for rawLine in output.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty,
                      let split = line.firstIndex(where: { $0.isWhitespace }),
                      let pid = Int(line[..<split]) else { continue }
                let command = line[split...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty {
                    result[pid] = command
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    private static func parentPIDMap() -> [Int: Int] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            var result: [Int: Int] = [:]
            for line in output.components(separatedBy: .newlines) {
                let columns = line.split(whereSeparator: { $0.isWhitespace })
                guard columns.count >= 2,
                      let pid = Int(columns[0]),
                      let ppid = Int(columns[1]) else { continue }
                result[pid] = ppid
            }
            return result
        } catch {
            return [:]
        }
    }

    private static func launchSource(
        for pid: Int,
        parents: [Int: Int]
    ) -> (name: String, bundlePath: String, bundleIdentifier: String?)? {
        var currentPID = parents[pid]
        var depth = 0

        while let candidatePID = currentPID, candidatePID > 1, depth < 12 {
            if let runningApplication = NSRunningApplication(processIdentifier: pid_t(candidatePID)),
               let executableURL = runningApplication.executableURL,
               let appURL = outermostApplicationURL(for: executableURL),
               appURL.standardizedFileURL.path != Bundle.main.bundleURL.standardizedFileURL.path {
                let bundle = Bundle(url: appURL)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? appURL.deletingPathExtension().lastPathComponent
                return (name, appURL.path, bundle?.bundleIdentifier)
            }
            currentPID = parents[candidatePID]
            depth += 1
        }
        return nil
    }

    private static func projectDirectoryFromCommand(_ command: String?) -> String? {
        guard let command, !command.isEmpty else { return nil }
        let home = NSHomeDirectory()
        let ignoredPrefixes = [
            "\(home)/.nvm/",
            "\(home)/.npm/",
            "\(home)/.pnpm/",
            "\(home)/.local/",
            "\(home)/Library/",
            "/opt/homebrew/",
            "/usr/",
        ]
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).dropFirst()

        for rawToken in tokens {
            var token = String(rawToken).trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),[]{}"))
            if token.hasPrefix("~") {
                token = token.replacingOccurrences(of: "~", with: home, options: [.anchored])
            }
            guard token.hasPrefix(home) else { continue }
            guard !ignoredPrefixes.contains(where: { token.hasPrefix($0) }) else { continue }

            let path = URL(fileURLWithPath: token).standardizedFileURL.path
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let directory = isDirectory.boolValue
                ? path
                : URL(fileURLWithPath: path).deletingLastPathComponent().path
            if let projectDirectory = meaningfulProjectDirectory(from: directory) {
                return projectDirectory
            }
        }
        return nil
    }

    private static func meaningfulProjectDirectory(from directory: String?) -> String? {
        guard let projectDirectory = PortScanner.projectDirectory(from: directory) else { return nil }
        let normalized = URL(fileURLWithPath: projectDirectory).standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        return normalized == home ? nil : normalized
    }

    private static func outermostApplicationURL(for executableURL: URL) -> URL? {
        let components = executableURL.standardizedFileURL.pathComponents
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...appIndex])))
    }

    private func parse(_ line: String) -> (
        pid: Int,
        name: String,
        download: Int,
        upload: Int,
        downloadDelta: Int,
        uploadDelta: Int
    )? {
        let columns = line.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 3 else { return nil }

        let processField = String(columns[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processField.isEmpty, processField != "" else { return nil }

        let processParts = processField.split(separator: ".", omittingEmptySubsequences: false)
        guard processParts.count >= 2,
              let pid = Int(processParts.last ?? ""),
              pid > 0 else {
            return nil
        }

        let name = processParts.dropLast().joined(separator: ".")
        guard !name.isEmpty else { return nil }

        let downloadDelta = max(0, Int(columns[1]) ?? 0)
        let uploadDelta = max(0, Int(columns[2]) ?? 0)
        let download = downloadDelta / sampleInterval
        let upload = uploadDelta / sampleInterval
        return (pid, name, download, upload, downloadDelta, uploadDelta)
    }

    private static func connectionSnapshotsForAllProcesses() -> (
        snapshots: [Int: ConnectionSnapshot],
        processNames: [Int: String]
    ) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", "-n", "-P", "-FpcnPT"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            let output = String(decoding: data, as: UTF8.self)
            var currentPID: Int?
            var currentTransport = "TCP"
            var currentState: String?
            var currentRemote: String?
            var endpointsByPID: [Int: Set<RemoteEndpoint>] = [:]
            var counts: [Int: Int] = [:]
            var names: [Int: String] = [:]

            func flushConnection() {
                guard let pid = currentPID, let remote = currentRemote, !remote.isEmpty else {
                    currentRemote = nil
                    currentState = nil
                    return
                }
                endpointsByPID[pid, default: []].insert(
                    RemoteEndpoint(
                        transport: currentTransport,
                        address: remote,
                        state: currentState
                    )
                )
                counts[pid, default: 0] += 1
                currentRemote = nil
                currentState = nil
            }

            for line in output.components(separatedBy: .newlines) {
                guard let prefix = line.first else { continue }
                let value = String(line.dropFirst())
                switch prefix {
                case "p":
                    flushConnection()
                    currentPID = Int(value)
                    currentTransport = "TCP"
                    currentState = nil
                case "c":
                    if let currentPID, !value.isEmpty {
                        names[currentPID] = value
                    }
                case "f":
                    flushConnection()
                case "P":
                    currentTransport = value
                case "T":
                    if value.hasPrefix("ST=") {
                        currentState = String(value.dropFirst(3))
                    }
                case "n":
                    guard currentPID != nil,
                          let arrowRange = value.range(of: "->") else { continue }
                    let remote = String(value[arrowRange.upperBound...])
                    if !remote.isEmpty {
                        currentRemote = remote
                    }
                default:
                    continue
                }
            }
            flushConnection()

            let pids = Set(endpointsByPID.keys).union(counts.keys)
            let snapshots = Dictionary(uniqueKeysWithValues: pids.map { pid in
                let endpoints = endpointsByPID[pid, default: []].sorted { lhs, rhs in
                    if lhs.isLocal != rhs.isLocal { return !lhs.isLocal }
                    return lhs.address.localizedCaseInsensitiveCompare(rhs.address) == .orderedAscending
                }
                return (pid, ConnectionSnapshot(count: counts[pid, default: 0], endpoints: endpoints))
            })
            return (snapshots, names)
        } catch {
            return ([:], [:])
        }
    }

    private static func openProjectFiles(
        for pids: [Int],
        processNames: [Int: String]
    ) -> [OpenProjectFile] {
        guard !pids.isEmpty else { return [] }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = [
            "-a",
            "-p", pids.map(String.init).joined(separator: ","),
            "-Fpn",
        ]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            let home = NSHomeDirectory()
            let output = String(decoding: data, as: UTF8.self)
            var currentPID: Int?
            var seen = Set<String>()
            var files: [OpenProjectFile] = []

            for line in output.components(separatedBy: .newlines) {
                guard let prefix = line.first else { continue }
                let value = String(line.dropFirst())
                if prefix == "p" {
                    currentPID = Int(value)
                    continue
                }
                guard prefix == "n",
                      let currentPID,
                      value.hasPrefix(home),
                      isInterestingProjectFile(value),
                      !PortScanner.isSystemPath(value) else {
                    continue
                }

                let key = "\(currentPID):\(value)"
                guard seen.insert(key).inserted else { continue }
                let parent = URL(fileURLWithPath: value).deletingLastPathComponent().path
                files.append(
                    OpenProjectFile(
                        pid: currentPID,
                        processName: processNames[currentPID] ?? "process",
                        path: value,
                        projectDirectory: PortScanner.projectDirectory(from: parent)
                    )
                )
            }

            return files.sorted { lhs, rhs in
                let lhsProject = lhs.projectDirectory != nil
                let rhsProject = rhs.projectDirectory != nil
                if lhsProject != rhsProject { return lhsProject }
                if lhs.projectDirectory != rhs.projectDirectory {
                    return (lhs.projectDirectory ?? "") < (rhs.projectDirectory ?? "")
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
        } catch {
            return []
        }
    }

    private static func isInterestingProjectFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let extensionName = url.pathExtension.lowercased()
        let sourceExtensions: Set<String> = [
            "c", "cc", "cpp", "css", "dart", "go", "h", "hpp", "html",
            "java", "js", "json", "jsx", "kt", "kts", "md", "mjs", "php",
            "properties", "py", "rb", "rs", "scss", "sh", "sql", "swift",
            "toml", "ts", "tsx", "vue", "xml", "yaml", "yml",
        ]
        let projectFileNames: Set<String> = [
            ".env", ".env.local", ".env.production", "dockerfile", "gemfile",
            "go.mod", "package.json", "pnpm-lock.yaml", "pom.xml", "pyproject.toml",
            "requirements.txt", "settings.gradle", "settings.gradle.kts",
        ]
        return sourceExtensions.contains(extensionName) || projectFileNames.contains(name)
    }
}

private final class NetworkTrafficHistoryStore {
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

    init() {
        migrateLegacyStoreIfNeeded()
        load()
        prune(now: Date())
    }

    func record(applications: [ApplicationTraffic]) {
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
            save()
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

    func clear() {
        bucketsByKey.removeAll(keepingCapacity: false)
        lastObservedSessionTotals.removeAll(keepingCapacity: false)
        lastSaveAt = Date()
        try? FileManager.default.removeItem(at: storageURL)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention).timeIntervalSince1970
        bucketsByKey = bucketsByKey.filter { $0.value.hourStart >= cutoff }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }
        bucketsByKey = Dictionary(uniqueKeysWithValues: payload.buckets.map { bucket in
            ("\(bucket.appID)|\(Int(bucket.hourStart))", bucket)
        })
    }

    private func save() {
        let payload = Payload(buckets: Array(bucketsByKey.values))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let directory = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: [.atomic])
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
            // Migration is best-effort. A failed move must never prevent monitoring from starting.
        }
    }

    private var storageURL: URL {
        applicationSupportURL
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

private final class NettopTrafficReader {
    var onFrame: (([String]) -> Void)?
    var onFailure: ((String) -> Void)?

    private let interval: Int
    private let queue = DispatchQueue(label: "devradar.network.nettop", qos: .utility)
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var lineBuffer = Data()
    private var frameLines: [String] = []
    private var flushWork: DispatchWorkItem?
    private var droppedFirstFrame = false
    private var shouldRun = false

    init(interval: Int) {
        self.interval = interval
    }

    func start() {
        queue.async { [weak self] in
            self?.shouldRun = true
            self?.spawn()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            self.process?.terminationHandler = nil
            self.process?.terminate()
            self.cleanup()
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
        }
    }

    private func spawn() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        task.arguments = [
            "-q", "/dev/null",
            "/usr/bin/nettop",
            "-P",
            "-d",
            "-L", "0",
            "-J", "bytes_in,bytes_out",
            "-s", "\(interval)",
            "-c",
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        // nettop polls stdin. Keeping a pseudo-TTY and stdin open prevents its
        // terminal loop from busy-spinning when hosted by a menu-bar app.
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
        lineBuffer.removeAll(keepingCapacity: true)
        frameLines.removeAll(keepingCapacity: true)
        droppedFirstFrame = false

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.queue.async {
                self.consume(data)
            }
        }

        task.terminationHandler = { [weak self] _ in
            guard let queue = self?.queue else { return }
            queue.async { [weak self] in
                guard let self else { return }
                self.cleanup()
                guard self.shouldRun else { return }
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.spawn()
                }
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            onFailure?("无法启动网络监控：\(error.localizedDescription)")
            if shouldRun {
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.spawn()
                }
            }
        }
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                frameLines.append(line)
            }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushFrame()
        }
        flushWork = work
        queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func flushFrame() {
        guard !frameLines.isEmpty else { return }
        let frame = frameLines
        frameLines.removeAll(keepingCapacity: true)

        // The first delta-mode frame is cumulative state and is not a rate sample.
        guard droppedFirstFrame else {
            droppedFirstFrame = true
            return
        }
        onFrame?(frame)
    }

    private func cleanup() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        flushWork?.cancel()
        flushWork = nil
    }
}

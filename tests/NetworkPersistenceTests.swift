import Darwin
import Foundation

@main
struct NetworkPersistenceTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ProjectError.message(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DevRadar-Persistence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = ApplicationTraffic(id: "app:fixture", name: "持久化验证", bundlePath: nil,
            bundleIdentifier: nil, launchSourceName: nil, processNames: ["fixture"], pids: [42],
            downloadBytesPerSecond: 0, uploadBytesPerSecond: 0, downloadedBytes: 240, uploadedBytes: 100,
            projectDirectories: [], workingDirectories: [], connectionCount: 0, remoteEndpoints: [])
        let historyURL = root.appendingPathComponent("history.json")
        let store = NetworkTrafficHistoryStore(url: historyURL)
        try store.record(applications: [application])
        let restored = NetworkTrafficHistoryStore(url: historyURL)
        try check(restored.snapshot(days: 1).totals.uploadedBytes == 100, "保存后重新读取累计上传量")
        try check(chflags(historyURL.path, UInt32(UF_IMMUTABLE)) == 0, "设置受控文件删除失败条件")
        do {
            defer { _ = chflags(historyURL.path, 0) }
            do {
                try store.clear()
                throw ProjectError.message("磁盘清空失败必须显式返回错误")
            } catch is CocoaError {}
            try check(store.snapshot(days: 1).totals.uploadedBytes == 100, "清空失败不得丢弃内存记录")
        }
        try store.clear()
        try check(store.snapshot(days: 1).totals.uploadedBytes == 0, "清空成功后才更新内存")
        let corrupt = Data("corrupt-history".utf8)
        try corrupt.write(to: historyURL)
        let broken = NetworkTrafficHistoryStore(url: historyURL)
        try check(broken.loadError != nil, "损坏的历史数据必须报告读取失败")
        do {
            try broken.record(applications: [application])
            throw ProjectError.message("读取失败不得覆盖原文件")
        } catch is DecodingError {}
        try check(try Data(contentsOf: historyURL) == corrupt, "损坏的原文件被保留")
        try broken.clear()
        try broken.record(applications: [application])
        try broken.flush()
        try check(NetworkTrafficHistoryStore(url: historyURL).snapshot(days: 1).totals.uploadedBytes == 100,
                  "显式清空后可重新保存")
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let retry = NetworkTrafficHistoryStore(url: blocked.appendingPathComponent("history.json"))
        // The parent is initially unreadable as a directory. Clear that failure explicitly before recording.
        try FileManager.default.removeItem(at: blocked)
        try retry.clear()
        try Data().write(to: blocked)
        do {
            try retry.record(applications: [application])
            try retry.flush()
            throw ProjectError.message("保存失败必须显式返回错误")
        } catch is CocoaError {}
        try FileManager.default.removeItem(at: blocked)
        try retry.flush()
        try check(NetworkTrafficHistoryStore(url: blocked.appendingPathComponent("history.json"))
            .snapshot(days: 1).totals.uploadedBytes == 100, "保存失败的样本可以重试写入")

        let directory = root.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let record = AutomaticHTTPSRecord(id: UUID(), applicationID: "app:fixture", applicationName: "证据验证",
            pids: [42], triggeredAt: now, triggerUploadBytesPerSecond: 100,
            monitorStartedAt: now, monitorFinishedAt: now, status: "completed", observations: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let evidenceURL = directory.appendingPathComponent(record.id.uuidString + ".json")
        try encoder.encode(record).write(to: evidenceURL)
        let evidence = AutomaticHTTPSEvidenceManager(directory: directory)
        try check(evidence.records.count == 1, "重新读取自动证据")
        try check(chflags(directory.path, UInt32(UF_IMMUTABLE)) == 0, "设置证据目录删除失败条件")
        do {
            defer { _ = chflags(directory.path, 0) }
            try check(!evidence.deleteRecord(record) && evidence.records.count == 1 && evidence.lastError != nil,
                      "删除失败须保留证据并报告错误")
            try check(!evidence.clearSavedRecords() && evidence.records.count == 1 && evidence.lastError != nil,
                      "清空失败须保留证据并报告错误")
        }
        try check(evidence.deleteRecord(record) && evidence.records.isEmpty, "删除成功后才更新证据列表")
        let invalidURL = directory.appendingPathComponent("damaged.json")
        try corrupt.write(to: invalidURL)
        let damaged = AutomaticHTTPSEvidenceManager(directory: directory)
        try check(damaged.lastError != nil && FileManager.default.fileExists(atPath: invalidURL.path),
                  "不可解析的证据必须保留原文件并报告错误")
        print("网络持久化：保存、重试、损坏文件保护和真实删除失败验证通过")
    }
}

import AppKit
import Foundation
import Observation

enum LocalProxyState {
    case idle
    case starting
    case listening
    case stopped
    case failed
}

struct LocalProxyEvent: Decodable, Identifiable {
    var id = UUID()
    var type: String
    var requestID: String?
    var timestamp: String?
    var durationMs: Int64?
    var method: String?
    var host: String?
    var path: String?
    var status: Int?
    var uploadBytes: Int64?
    var downloadBytes: Int64?
    var contentType: String?
    var preview: String?
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case type, requestID = "requestId", timestamp, durationMs
        case method, host, path, status, uploadBytes, downloadBytes
        case contentType, preview, message
    }
}

@Observable
final class LocalProxyManager {
    var state = LocalProxyState.idle
    var applicationName = ""
    var proxyAddress = ""
    var events: [LocalProxyEvent] = []
    var requestCount = 0
    var uploadedBytes: Int64 = 0
    var lastError: String?
    var connectivityResult: String?
    var httpsDecryptionEnabled = false
    var systemProxy = SystemProxyController()
    var selectedApplication: ApplicationTraffic?

    /// Proxy-side HTTP events currently do not carry verified process IDs.
    /// Never imply that a request came from the app chosen in the menu.
    var attributionLabel: String { "来源未识别 · 系统代理" }

    private var process: Process?
    private var output: Pipe?
    private var startedAt: Date?
    private var timer: Timer?
    private let outputLock = NSLock()
    private var pendingBytes = Data()

    var isBusy: Bool { state == .starting || state == .listening }
    var isListening: Bool { state == .listening }
    var retainedLimit: Int { 2000 }

    static var caDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevRadar/CaptureCA", isDirectory: true)
    }

    static var caCertificate: URL {
        caDirectory.appendingPathComponent("DevRadar-Local-CA.pem")
    }

    static var importCertificate: URL {
        caDirectory.appendingPathComponent("DevRadar-Local-CA.cer")
    }

    private static var helper: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let executable = resourceURL.appendingPathComponent("devradar-proxy")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    func start(application: ApplicationTraffic) {
        guard !isBusy else { return }
        guard !systemProxy.pendingRecovery else {
            state = .failed
            lastError = "检测到尚未恢复的系统代理配置。请先在抓包窗口点击「恢复系统代理」"
            return
        }
        guard let executable = Self.helper else {
            state = .failed
            lastError = "找不到内置代理引擎，请重新构建并安装 DevRadar"
            return
        }
        stop()
        applicationName = application.name // Only the user's original entry point.
        selectedApplication = application
        events = []
        requestCount = 0
        uploadedBytes = 0
        proxyAddress = ""
        lastError = nil
        connectivityResult = nil
        pendingBytes.removeAll()
        httpsDecryptionEnabled = UserDefaults.standard.bool(forKey: "proxyDecryptHTTPS")
        let existingUpstream = systemProxy.inspectCurrentConnection()
        let task = Process()
        let pipe = Pipe()
        task.executableURL = executable
        task.arguments = [
            "--listen", "127.0.0.1:0",
            "--ca-dir", Self.caDirectory.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--https=\(httpsDecryptionEnabled)",
            "--preview=\(UserDefaults.standard.bool(forKey: "proxyBodyPreview"))"
        ]
        if let existingUpstream {
            task.arguments?.append(contentsOf: ["--upstream", existingUpstream])
        }
        task.standardOutput = pipe
        task.standardError = Pipe()
        output = pipe
        process = task
        state = .starting

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.outputLock.lock()
            self.pendingBytes.append(data)
            var lines: [Data] = []
            while let newline = self.pendingBytes.firstIndex(of: 10) {
                lines.append(Data(self.pendingBytes.prefix(upTo: newline)))
                self.pendingBytes.removeSubrange(...newline)
            }
            self.outputLock.unlock()
            DispatchQueue.main.async { [weak self] in
                for line in lines { self?.consume(line) }
            }
        }

        task.terminationHandler = { [weak self, weak task] _ in
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.timer?.invalidate()
                self.timer = nil
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil
                self.process = nil
                if self.state == .starting {
                    self.lastError = "本地代理未能启动，请检查端口或证书目录权限"
                    self.state = .failed
                } else {
                    self.state = .stopped
                }
                if self.systemProxy.pendingRecovery && !self.systemProxy.isPending {
                    self.systemProxy.restore { [weak self] succeeded in
                        if !succeeded {
                            self?.lastError = "抓包进程已退出，但系统代理恢复失败，请立即重试恢复"
                        }
                    }
                }
            }
        }

        do {
            try task.run()
            startedAt = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let startedAt = self.startedAt else { return }
                if Date().timeIntervalSince(startedAt) > 540 { self.stop() }
            }
        } catch {
            state = .failed
            lastError = error.localizedDescription
            pipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            output = nil
        }
    }

    func stop(completion: ((Bool) -> Void)? = nil) {
        if systemProxy.pendingRecovery {
            systemProxy.restore { [weak self] succeeded in
                if succeeded {
                    self?.stopEngine()
                } else {
                    self?.lastError = "系统代理尚未恢复，抓包引擎暂时保持运行；请点击恢复系统代理"
                }
                completion?(succeeded)
            }
        } else {
            stopEngine()
            completion?(true)
        }
    }

    func stopForQuit(completion: @escaping (Bool) -> Void) {
        stop(completion: completion)
    }

    private func stopEngine() {
        timer?.invalidate()
        timer = nil
        if let process, process.isRunning { process.terminate() }
    }

    func clear() {
        guard !isBusy else { return }
        events.removeAll()
        requestCount = 0
        uploadedBytes = 0
        applicationName = ""
        selectedApplication = nil
        proxyAddress = ""
        lastError = nil
        connectivityResult = nil
        state = .idle
    }

    func captureExistingApplications() {
        guard isListening else { return }
        systemProxy.enable(devRadarAddress: proxyAddress) { [weak self] succeeded in
            if !succeeded { self?.lastError = self?.systemProxy.message }
        }
    }

    /// An explicit, user-triggered probe distinguishing a broken proxy from
    /// a target app that simply has not been configured to use the proxy.
    func testProxyConnection() {
        guard isListening else { return }
        let address = proxyAddress
        connectivityResult = "正在发送 HTTPS 测试请求…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            let output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            task.arguments = [
                "--silent", "--show-error", "--output", "/dev/null",
                "--write-out", "%{http_code}", "--max-time", "12",
                "--noproxy", "", "--proxy", "http://\(address)",
                "--cacert", Self.caCertificate.path, "https://example.com/"
            ]
            task.standardOutput = output
            task.standardError = output
            do {
                try task.run()
                // Read bounded output (curl emits a tiny status/error line).
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let result = String(decoding: data.prefix(512), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard let self, self.proxyAddress == address else { return }
                    self.connectivityResult = task.terminationStatus == 0
                        ? "代理连通正常（HTTP \(result)），如列表仍为空，请为目标应用配置代理"
                        : "测试失败：\(result)"
                }
            } catch {
                DispatchQueue.main.async { self?.connectivityResult = "测试失败：\(error.localizedDescription)" }
            }
        }
    }

    func copyProxyEnvironment() {
        guard !proxyAddress.isEmpty else { return }
        let url = "http://\(proxyAddress)"
        let variables = """
        export HTTP_PROXY=\(url)
        export HTTPS_PROXY=\(url)
        export http_proxy=\(url)
        export https_proxy=\(url)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(variables, forType: .string)
    }

    func prepareCA() {
        guard let executable = Self.helper else {
            lastError = "当前安装包缺少内置代理引擎"
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            let errorPipe = Pipe()
            task.executableURL = executable
            task.arguments = ["--ca-dir", Self.caDirectory.path, "--init-ca"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = errorPipe
            do {
                try task.run()
                task.waitUntilExit()
                let detail = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if task.terminationStatus == 0 {
                        self.lastError = nil
                        NSWorkspace.shared.activateFileViewerSelecting([Self.importCertificate])
                    } else {
                        self.lastError = "证书生成失败：\(detail)"
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.lastError = error.localizedDescription }
            }
        }
    }

    func copyTrustCommand() {
        let quoted = "'" + Self.importCertificate.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "security add-trusted-cert -r trustRoot -p ssl -k \"$HOME/Library/Keychains/login.keychain-db\" \(quoted)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func copyImportCommand() {
        let quoted = "'" + Self.importCertificate.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "security import \(quoted) -k \"$HOME/Library/Keychains/login.keychain-db\" -t cert"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func openKeychainAccess() {
        let app = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Keychain Access.app")
        NSWorkspace.shared.open(app)
    }

    private func consume(_ data: Data) {
        guard var result = try? JSONDecoder().decode(LocalProxyEvent.self, from: data) else { return }
        if result.type == "ready", let address = result.host {
            proxyAddress = address
            state = .listening
            return
        }
        if result.type == "started" {
            requestCount += 1
            events.append(result)
        } else if let requestID = result.requestID,
                  let index = events.firstIndex(where: { $0.requestID == requestID }) {
            result.id = events[index].id
            events[index] = result
        } else {
            if result.type == "request" || result.type == "error" || result.type == "upgrade" {
                requestCount += 1
            }
            events.append(result)
        }
        uploadedBytes += max(0, result.uploadBytes ?? 0)
        if events.count > retainedLimit {
            events.removeFirst(events.count - retainedLimit)
        }
    }

    func exportSession() {
        guard !events.isEmpty else {
            lastError = "当前没有可导出的记录"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DevRadar-Proxy-Session.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Deliberately metadata-only; no path, headers, bodies or full URLs.
            // The original event previews remain session-only in memory.
            let records = events.map { event in
                ProxySessionExport.Record(
                    type: event.type,
                    timestamp: event.timestamp,
                    method: event.method,
                    host: event.host?.contains("@") == true ? nil : event.host,
                    status: event.status,
                    durationMs: event.durationMs,
                    uploadBytes: event.uploadBytes,
                    downloadBytes: event.downloadBytes,
                    attribution: "unverified"
                )
            }
            let json = try ProxySessionExport.encode(records: records, totalRequests: requestCount)
            try json.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastError = nil
        } catch {
            lastError = "导出会话失败：\(error.localizedDescription)"
        }
    }
}

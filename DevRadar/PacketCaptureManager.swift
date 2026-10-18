import AppKit
import Darwin
import Foundation
import Observation

enum PacketCaptureState: String {
    case idle
    case ready
    case authorizing
    case starting
    case capturing
    case stopping
    case completed
    case failed
}

@Observable
final class PacketCaptureManager {
    var state = PacketCaptureState.idle
    var applicationName = ""
    var packetLines: [String] = []
    var packetCount = 0
    var lastError: String?
    var selectedConnectionCount = 0
    var selectedRemoteEndpoints: [String] = []
    var selectedPIDs: [Int] = []

    private var directory: URL?
    private var capturePID: pid_t?
    private var timer: Timer?
    private var beganAt: Date?
    private var lastReadAt = Date.distantPast
    private var readingPackets = false
    private let maximumDuration: TimeInterval = 600

    init() {
        // Finished capture sessions cannot be resumed after an app restart.
        let base = FileManager.default.temporaryDirectory
        let previous = (try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        for folder in previous where folder.lastPathComponent.hasPrefix("DevRadar-Capture-") {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if Date().timeIntervalSince(modified) > 3600 {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    var isBusy: Bool {
        state == .authorizing || state == .starting || state == .capturing || state == .stopping
    }

    /// Opens the persistent inspector before authorization. A confirmation
    /// dialog inside MenuBarExtra can disappear while the menu is dismissed.
    func prepare(application: ApplicationTraffic) {
        guard !isBusy else { return }
        let pids = Array(Set(application.pids.filter { $0 > 0 })).sorted()
        guard !pids.isEmpty else {
            lastError = "应用没有可捕获的进程"
            state = .failed
            return
        }
        discardFinishedSession()
        selectedPIDs = pids
        applicationName = application.name
        selectedConnectionCount = application.connectionCount
        selectedRemoteEndpoints = Array(application.remoteEndpoints.filter { !$0.isLocal }.map(\.address).prefix(6))
        packetLines = []
        packetCount = 0
        lastError = nil
        state = .ready
    }

    /// Called only by the explicit Start button in the inspector window.
    func startPreparedCapture() {
        guard state == .ready || state == .failed,
              !selectedPIDs.isEmpty else { return }
        let pids = selectedPIDs
        let username = NSUserName()
        guard username.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil else {
            lastError = "当前账户名无法用于系统抓包降权"
            state = .failed
            return
        }
        discardFinishedSession()
        packetLines = []
        packetCount = 0
        lastError = nil
        state = .authorizing

        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("DevRadar-Capture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            directory = folder

            let expression = pids.map { "(pid=\($0) or epid=\($0))" }.joined(separator: " or ")
            // Never silently omit TLS traffic: input methods and many background
            // applications communicate directly over TCP/UDP 443. Metadata-only
            // captures remain encrypted; filtering these ports yields false zeroes.
            let filter = "tcp or udp"
            let capturePath = folder.appendingPathComponent("capture-%Y%m%d%H%M%S.pcapng").path
            let arguments = [
                "/usr/sbin/tcpdump", "-Z", username,
                "-i", "pktap,all", "--apple-md-filter", expression,
                "-n", "-s", "256", "-U", "-c", "10000",
                "-G", "600", "-W", "1", "-w", capturePath, filter
            ]
            let invocation = arguments.map(Self.shellQuote).joined(separator: " ")

            // The only privileged operation is opening the system pktap
            // device. tcpdump -Z switches to the logged-in user before
            // creating any capture files. No user-writable script runs as root.
            // AppleScript's privileged "do shell script" runs without a
            // controlling terminal. macOS nohup fails in that environment
            // with "can't detach from console: No such process". A background
            // child with all three standard streams redirected survives the
            // AppleScript process exit; no nohup or second application needed.
            //
            // Capture startup stderr into a root-owned, unpredictable mktemp
            // file and return it only if tcpdump exits immediately.
            // Never have a privileged shell truncate a user-controlled path.
            let command = """
            diagnostic=$(/usr/bin/mktemp -t DevRadarCapture) || exit 1
            /bin/sh -c \(Self.shellQuote("umask 077; ulimit -f 32768; exec \(invocation)")) </dev/null >/dev/null 2>"$diagnostic" &
            child=$!
            sleep 2
            if kill -0 "$child" 2>/dev/null; then
                printf 'STARTED:%s' "$child"
            else
                printf 'FAILED:%s' "$(/usr/bin/head -c 500 "$diagnostic")"
            fi
            /bin/rm -f "$diagnostic"
            """
            let escaped = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let source = "do shell script \"\(escaped)\" with administrator privileges"

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    process.waitUntilExit()
                    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    DispatchQueue.main.async {
                        guard let self, self.directory == folder else { return }
                        let response = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard process.terminationStatus == 0,
                              response.hasPrefix("STARTED:"),
                              let pid = Int32(response.dropFirst("STARTED:".count)),
                              pid > 0 else {
                            self.lastError = response.hasPrefix("FAILED:")
                                ? "抓包引擎启动失败：\(response.dropFirst("FAILED:".count).isEmpty ? "tcpdump 进程提前退出且未返回诊断内容" : String(response.dropFirst("FAILED:".count)))"
                                : errorText.isEmpty ? "管理员授权失败或被取消：\(response)" : errorText
                            self.state = .failed
                            return
                        }
                        self.capturePID = pid
                        self.beganAt = Date()
                        // An AppleScript exit code of 0 only means the shell
                        // started a background job, NOT that tcpdump started.
                        self.state = .starting
                        self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                            self?.refresh()
                        }
                        self.refresh()
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.state = .failed
                        self.lastError = error.localizedDescription
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            state = .failed
        }
    }

    func stop() {
        guard state == .capturing, let pid = capturePID else { return }
        if kill(pid, SIGINT) == 0 {
            state = .stopping
        } else {
            lastError = "停止抓包失败：进程尚未降权或已退出"
            refresh()
        }
    }

    func clear() {
        guard !isBusy else { return }
        discardFinishedSession()
        state = .idle
        applicationName = ""
        selectedPIDs = []
        selectedConnectionCount = 0
        selectedRemoteEndpoints = []
        packetLines = []
        packetCount = 0
        lastError = nil
    }

    func saveCapture() {
        guard state == .completed, let source = captureFile() else {
            lastError = "没有可导出的数据包"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DevRadar-Capture.pcapng"
        if panel.runModal() == .OK, let target = panel.url {
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                lastError = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func refresh() {
        guard state == .starting || state == .capturing || state == .stopping else { return }
        let file = captureFile()
        if state == .starting, file != nil {
            state = .capturing
        }
        if let pid = capturePID, kill(pid, 0) != 0, errno != EPERM {
            timer?.invalidate()
            timer = nil
            state = file == nil ? .failed : .completed
            if state == .failed {
                lastError = "抓包后台进程已退出，未生成 PCAPNG 文件。可能是 tcpdump / pktap 权限不足或启动参数不被支持。已停止启动，请勿把此状态当作没有网络流量。"
            }
            readCapturedPackets()
            return
        }
        if state == .starting, let beganAt,
           Date().timeIntervalSince(beganAt) > 12 {
            timer?.invalidate()
            timer = nil
            state = .failed
            lastError = "管理员授权后 12 秒内仍未生成抓包文件。tcpdump 未能正常开始捕获，请检查授权和系统抓包权限。"
            return
        }
        if let beganAt, Date().timeIntervalSince(beganAt) >= maximumDuration, state == .capturing {
            stop()
        }
        if Date().timeIntervalSince(lastReadAt) >= 4 {
            readCapturedPackets()
        }
    }

    private func readCapturedPackets() {
        guard !readingPackets, let source = captureFile() else { return }
        readingPackets = true
        lastReadAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/tcpdump")
            process.arguments = ["-n", "-q", "-c", "10000", "-r", source.path]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let lines = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline).map(String.init)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.readingPackets = false
                    if !lines.isEmpty {
                        self.packetCount = lines.count
                        self.packetLines = Array(lines.suffix(200))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.readingPackets = false
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    private func captureFile() -> URL? {
        guard let directory else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files.first {
            $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "pcapng"
        }
    }

    private func discardFinishedSession() {
        guard !isBusy else { return }
        timer?.invalidate()
        timer = nil
        capturePID = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
            self.directory = nil
        }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

import AppKit
import Darwin
import Foundation
import Observation

/// Opt-in, bounded cleartext DNS capture. The temporary text log is readable
/// only by the logged-in user; no packet payloads or headers are persisted.
@Observable
final class DNSCaptureManager {
    enum State {
        case idle, authorizing, starting, capturing, stopping, completed, failed
    }

    var state = State.idle
    var error: String?
    var parser = DNSCaptureParser()
    private var pid: pid_t?
    private var logURL: URL?
    private var offset: UInt64 = 0
    private var partialLine = ""
    private var startedAt: Date?
    private var timer: Timer?
    private var readPending = false
    private var generation = UUID()

    var running: Bool {
        state == .authorizing || state == .starting || state == .capturing || state == .stopping
    }

    func start() {
        guard !running else { return }
        let user = NSUserName()
        guard user.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil else {
            error = "无法安全识别当前用户"
            state = .failed
            return
        }
        cleanup()
        parser.reset()
        error = nil
        state = .authorizing
        let session = UUID()
        generation = session

        // No user-controlled script is executed as root. tcpdump opens PKTAP
        // while privileged, then -Z drops back to the logged-in user.
        let args = [
            "/usr/sbin/tcpdump", "-Z", user,
            "-i", "pktap,all", "-n", "-l", "-vv", "--apple-oneline",
            "-k", "NP", "-s", "512", "-c", "6000",
            "udp port 53 or tcp port 53"
        ]
        let invocation = args.map(Self.quote).joined(separator: " ")
        let command = """
        diagnostic=$(/usr/bin/mktemp -t DevRadarDNSDiag) || exit 1
        logfile=$(/usr/bin/mktemp -p /private/tmp -t DevRadarDNSLog) || exit 1
        /usr/sbin/chown \(Self.quote(user)) "$logfile" || exit 1
        /bin/chmod 600 "$logfile" || exit 1
        /bin/sh -c \(Self.quote("umask 077; ulimit -f 32768; exec \(invocation)")) </dev/null >"$logfile" 2>"$diagnostic" &
        child=$!
        sleep 2
        if kill -0 "$child" 2>/dev/null; then
          printf 'STARTED:%s:%s' "$child" "$logfile"
        else
          printf 'FAILED:%s' "$(/usr/bin/head -c 450 "$diagnostic")"
          /bin/rm -f "$logfile"
        fi
        /bin/rm -f "$diagnostic"
        """
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = stdout
            task.standardError = stderr
            do {
                try task.run()
                task.waitUntilExit()
                let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let diagnostics = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self, self.generation == session else { return }
                    let parts = output.split(separator: ":", maxSplits: 2)
                    guard task.terminationStatus == 0, parts.count == 3,
                          parts[0] == "STARTED", let pid = pid_t(parts[1]), pid > 0,
                          parts[2].hasPrefix("/private/tmp/DevRadarDNSLog.") ||
                          parts[2].hasPrefix("/tmp/DevRadarDNSLog.") else {
                        self.state = .failed
                        self.error = output.hasPrefix("FAILED:") ? String(output.dropFirst(7)) :
                            (diagnostics.isEmpty ? "管理员授权取消或 DNS 监听启动失败" : diagnostics)
                        return
                    }
                    self.pid = pid
                    self.logURL = URL(fileURLWithPath: String(parts[2]))
                    self.startedAt = Date()
                    if self.state == .stopping {
                        self.stop()
                        return
                    }
                    self.state = .capturing
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        self?.refresh()
                    }
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == session else { return }
                    self.state = .failed
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        // The authorization phase has no returned child PID yet. Invalidate
        // its callback; after authorization completes, orphan cleanup below
        // must still terminate the newly started tcpdump.
        guard running else { return }
        if state == .authorizing {
            state = .stopping
            return
        }
        if state == .stopping && pid == nil { return }
        guard let pid else { state = .failed; error = "监听进程未登记"; return }
        var executable = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &executable, UInt32(executable.count))
        guard count > 0, String(cString: executable) == "/usr/sbin/tcpdump" else {
            refresh()
            return
        }
        if kill(pid, SIGINT) == 0 {
            state = .stopping
        } else {
            error = "无法停止 DNS 监听进程"
            refresh()
        }
    }

    func clear() {
        guard !running else { return }
        cleanup()
        parser.reset()
        error = nil
        state = .idle
    }

    private func refresh() {
        guard state == .starting || state == .capturing || state == .stopping else { return }
        readNewLines()
        if let pid, kill(pid, 0) != 0 && errno != EPERM {
            state = .completed
            timer?.invalidate()
            timer = nil
            readNewLines()
            return
        }
        if let startedAt, Date().timeIntervalSince(startedAt) >= 300 && state != .stopping {
            stop()
        }
    }

    private func readNewLines() {
        guard !readPending, let url = logURL else { return }
        readPending = true
        let currentOffset = offset
        let session = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { () throws -> Data in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: currentOffset)
                return try handle.read(upToCount: 128 * 1024) ?? Data()
            }
            DispatchQueue.main.async {
                guard let self, self.generation == session else { return }
                self.readPending = false
                switch result {
                case .failure(let error):
                    self.error = "读取 DNS 记录失败：\(error.localizedDescription)"
                case .success(let data):
                    self.offset += UInt64(data.count)
                    guard !data.isEmpty else { return }
                    let text = self.partialLine + String(decoding: data, as: UTF8.self)
                    let fragments = text.components(separatedBy: "\n")
                    self.partialLine = String((fragments.last ?? "").prefix(2048))
                    for line in fragments.dropLast() {
                        self.parser.ingest(line: line, at: Date())
                    }
                    if self.state == .starting { self.state = .capturing }
                    if data.count == 128 * 1024 { self.readNewLines() }
                }
            }
        }
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        logURL = nil
        pid = nil
        offset = 0
        partialLine = ""
        readPending = false
        startedAt = nil
    }

    nonisolated private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

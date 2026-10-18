import Foundation

/// One non-privileged native nettop reader for the explicitly selected PIDs.
/// It does not alter the system proxy, inspect TLS payloads or start any app.
final class HTTPSConnectionReader {
    var onUpdate: (([HTTPSConnection]) -> Void)?
    var onError: ((String) -> Void)?
    private let pids: [Int]
    private let queue = DispatchQueue(label: "devradar.https.socket", qos: .utility)
    private var tracker: HTTPSConnectionTracker
    private var process: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var pending = Data()
    private var running = false
    private var lastPublishedAt = Date.distantPast

    init(pids: [Int]) {
        self.pids = Array(Set(pids.filter { $0 > 0 })).sorted().prefix(16).map { $0 }
        tracker = HTTPSConnectionTracker(pids: self.pids)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running, !self.pids.isEmpty else { return }
            self.running = true
            let task = Process()
            let stdout = Pipe()
            let stdin = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            task.arguments = [
                "-q", "/dev/null", "/usr/bin/nettop",
                "-n", "-x", "-L", "0", "-s", "2",
                "-J", "bytes_in,bytes_out",
            ] + self.pids.flatMap { ["-p", String($0)] }
            task.standardInput = stdin
            task.standardOutput = stdout
            task.standardError = FileHandle.nullDevice
            self.process = task
            self.stdin = stdin
            self.stdout = stdout
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async { [weak self] in self?.ingest(data) }
            }
            task.terminationHandler = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    if self.running {
                        self.onError?("逐连接网络监控已结束，请重新选择应用")
                    }
                    self.running = false
                    self.stdout?.fileHandleForReading.readabilityHandler = nil
                    self.process = nil
                    self.stdout = nil
                    self.stdin = nil
                }
            }
            do {
                try task.run()
            } catch {
                self.running = false
                self.onError?(error.localizedDescription)
            }
        }
    }

    func stop() {
        // Retain the reader until termination completes even if its owner
        // immediately replaces the selected application.
        queue.async { [self] in
            self.running = false
            self.stdout?.fileHandleForReading.readabilityHandler = nil
            // nettop reacts to 'q' while running inside script's pseudo-tty.
            try? self.stdin?.fileHandleForWriting.write(contentsOf: Data("q".utf8))
            if self.process?.isRunning == true { self.process?.terminate() }
            self.process = nil
            self.stdout = nil
            self.stdin = nil
        }
    }

    private func ingest(_ data: Data) {
        pending.append(data)
        if pending.count > 1024 * 1024 { pending.removeAll(); return }
        var latest = false
        while let newLine = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newLine], as: UTF8.self)
            pending.removeSubrange(...newLine)
            if tracker.consume(line: line, at: Date()) { latest = true }
        }
        if latest, Date().timeIntervalSince(lastPublishedAt) >= 1 {
            lastPublishedAt = Date()
            onUpdate?(tracker.observed443Connections)
        }
    }
}

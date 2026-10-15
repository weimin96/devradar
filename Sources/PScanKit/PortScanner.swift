import Darwin
import Foundation

public struct PortInfo: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let port: Int
    public let processName: String
    public let pid: Int
    public let directory: String?
    public let command: String?
    public let executable: String?
    public let projectDirectory: String?
    public let projectName: String?
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let uptimeSeconds: Int?

    public var runtimeName: String {
        let text = "\(processName) \(executable ?? "") \(command ?? "")".lowercased()
        if text.contains("spring-boot") || text.contains("org.springframework.boot") {
            return "Spring Boot"
        }
        if text.contains("vite") {
            return "Vite"
        }
        if text.contains("next dev") || text.contains("/next") {
            return "Next.js"
        }
        if text.contains("nuxt") {
            return "Nuxt"
        }
        if text.contains("uvicorn") {
            return "Uvicorn"
        }
        if text.contains("gunicorn") {
            return "Gunicorn"
        }
        if text.contains("flask") {
            return "Flask"
        }
        if text.contains("java") || text.contains("gradle") || text.contains("maven") {
            return "Java"
        }
        if text.contains("node") || text.contains("npm") || text.contains("pnpm") || text.contains("yarn") || text.contains("bun") {
            return "Node"
        }
        if text.contains("python") || text.contains("uvicorn") || text.contains("gunicorn") || text.contains("flask") {
            return "Python"
        }
        if text.contains("ruby") || text.contains("rails") {
            return "Ruby"
        }
        return processName
    }
}

public enum ProcessStopMode: Sendable {
    case terminate
    case force
    case processTree
}

public enum PortScannerError: LocalizedError, Sendable {
    case processNotFound(Int)
    case signalFailed(pid: Int, signal: Int32)

    public var errorDescription: String? {
        switch self {
        case .processNotFound(let pid):
            return "进程 \(pid) 已不存在"
        case .signalFailed(let pid, let signal):
            return "无法向进程 \(pid) 发送信号 \(signal)"
        }
    }
}

public final class PortScanner: @unchecked Sendable {
    private struct ProcessSnapshot {
        let command: String?
        let cpuPercent: Double?
        let memoryBytes: UInt64?
        let uptimeSeconds: Int?
    }

    public init() {}

    public func fetchPorts(includeAll: Bool = false, excludingPIDs: Set<Int> = []) -> [PortInfo] {
        let currentUser = NSUserName()
        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-u", currentUser, "-iTCP", "-sTCP:LISTEN", "-n", "-P"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            let output = String(decoding: data, as: UTF8.self)

            let lines = output.components(separatedBy: "\n").dropFirst()
            var seen = Set<Int>()
            var rawPorts: [(port: Int, processName: String, pid: Int)] = []

            for line in lines {
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                guard columns.count >= 9 else { continue }

                let processName = String(columns[0])
                let pid = Int(columns[1]) ?? 0
                let nameField = String(columns[8])

                guard pid > 0, !excludingPIDs.contains(pid) else { continue }

                if let colonIndex = nameField.lastIndex(of: ":") {
                    let portStr = nameField[nameField.index(after: colonIndex)...]
                    if let port = Int(portStr), !seen.contains(port) {
                        seen.insert(port)
                        rawPorts.append((port, processName, pid))
                    }
                }
            }

            let pids = Array(Set(rawPorts.map(\.pid)))
            let directories = Self.workingDirectories(for: pids)
            let snapshots = Self.processSnapshots(for: pids)

            var results = rawPorts.map { raw in
                let directory = directories[raw.pid]
                let projectDirectory = Self.projectDirectory(from: directory)
                let snapshot = snapshots[raw.pid]
                return PortInfo(
                    port: raw.port,
                    processName: raw.processName,
                    pid: raw.pid,
                    directory: directory,
                    command: snapshot?.command,
                    executable: Self.executablePath(for: raw.pid),
                    projectDirectory: projectDirectory,
                    projectName: Self.projectName(for: projectDirectory),
                    cpuPercent: snapshot?.cpuPercent,
                    memoryBytes: snapshot?.memoryBytes,
                    uptimeSeconds: snapshot?.uptimeSeconds
                )
            }

            if !includeAll {
                results = results.filter { $0.projectDirectory != nil }
            }

            return results.sorted { a, b in
                if (a.projectDirectory != nil) != (b.projectDirectory != nil) {
                    return a.projectDirectory != nil
                }
                if a.projectName != b.projectName {
                    return (a.projectName ?? "") < (b.projectName ?? "")
                }
                return a.port < b.port
            }
        } catch {
            return []
        }
    }

    public func stop(_ port: PortInfo, mode: ProcessStopMode) throws {
        guard Self.processExists(port.pid) else {
            throw PortScannerError.processNotFound(port.pid)
        }

        switch mode {
        case .terminate:
            try Self.send(signal: SIGTERM, to: port.pid)
        case .force:
            try Self.send(signal: SIGKILL, to: port.pid)
        case .processTree:
            let rootPID = Self.managedTreeRoot(for: port)
            let descendants = Self.descendants(of: rootPID)
            for pid in descendants.reversed() {
                if Self.processExists(pid) {
                    try Self.send(signal: SIGTERM, to: pid)
                }
            }
            if Self.processExists(rootPID) {
                try Self.send(signal: SIGTERM, to: rootPID)
            }
        }
    }

    public static func isSystemPath(_ path: String) -> Bool {
        let systemPrefixes = [
            "/Library/",
            "/System/",
            "/usr/",
            "/var/",
            "/private/",
            "/Applications/",
        ]
        let homeLibrary = NSHomeDirectory() + "/Library/"
        if path.hasPrefix(homeLibrary) { return true }
        return systemPrefixes.contains { path.hasPrefix($0) }
    }

    public static func workingDirectory(for pid: Int) -> String? {
        workingDirectories(for: [pid])[pid]
    }

    private static func workingDirectories(for pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }

        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-p", pids.map(String.init).joined(separator: ","), "-d", "cwd", "-Fpn"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            let output = String(decoding: data, as: UTF8.self)
            var currentPID: Int?
            var result: [Int: String] = [:]
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("p") {
                    currentPID = Int(line.dropFirst())
                } else if line.hasPrefix("n/"), let currentPID {
                    result[currentPID] = String(line.dropFirst())
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    public static func projectDirectory(from directory: String?) -> String? {
        guard let directory, directory != "/", !isSystemPath(directory) else { return nil }

        var url = URL(fileURLWithPath: directory).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var gitCandidate: URL?

        while url.path.count >= home.count {
            if containsProjectMarker(at: url) {
                return url.path
            }
            if gitCandidate == nil, FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                gitCandidate = url
            }

            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }

        return gitCandidate?.path ?? directory
    }

    private static let projectMarkers = [
        "package.json",
        "pnpm-workspace.yaml",
        "pom.xml",
        "build.gradle",
        "build.gradle.kts",
        "settings.gradle",
        "settings.gradle.kts",
        "gradlew",
        "pyproject.toml",
        "requirements.txt",
        "Gemfile",
        "Package.swift",
        "Cargo.toml",
        "go.mod",
    ]

    private static func containsProjectMarker(at directory: URL) -> Bool {
        projectMarkers.contains { marker in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path)
        }
    }

    private static func projectName(for projectDirectory: String?) -> String? {
        guard let projectDirectory else { return nil }

        let root = URL(fileURLWithPath: projectDirectory).standardizedFileURL
        let gitEntry = root.appendingPathComponent(".git")
        var isDirectory = ObjCBool(false)

        if FileManager.default.fileExists(atPath: gitEntry.path, isDirectory: &isDirectory), !isDirectory.boolValue,
           let contents = try? String(contentsOf: gitEntry, encoding: .utf8),
           let firstLine = contents.split(whereSeparator: { $0.isNewline }).first {
            let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("gitdir:") {
                let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDirectory: URL
                if rawPath.hasPrefix("/") {
                    gitDirectory = URL(fileURLWithPath: rawPath).standardizedFileURL
                } else {
                    gitDirectory = root.appendingPathComponent(rawPath).standardizedFileURL
                }

                if let range = gitDirectory.path.range(of: "/.git/worktrees/") {
                    let mainRepositoryPath = String(gitDirectory.path[..<range.lowerBound])
                    let name = URL(fileURLWithPath: mainRepositoryPath).lastPathComponent
                    if !name.isEmpty {
                        return name
                    }
                }
            }
        }

        return root.lastPathComponent
    }

    private static func processValue(pid: Int, field: String) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid), "-o", "\(field)="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard task.terminationStatus == 0, !value.isEmpty else {
                return nil
            }
            return value
        } catch {
            return nil
        }
    }

    private static func processSnapshots(for pids: [Int]) -> [Int: ProcessSnapshot] {
        guard !pids.isEmpty else { return [:] }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = [
            "-p", pids.map(String.init).joined(separator: ","),
            "-o", "pid=",
            "-o", "%cpu=",
            "-o", "rss=",
            "-o", "etime=",
            "-o", "command=",
        ]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            let output = String(decoding: data, as: UTF8.self)
            var result: [Int: ProcessSnapshot] = [:]
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let columns = trimmed.split(
                    maxSplits: 4,
                    omittingEmptySubsequences: true,
                    whereSeparator: { $0.isWhitespace }
                )
                guard columns.count >= 4, let pid = Int(columns[0]) else {
                    continue
                }

                let cpuPercent = Double(columns[1])
                let memoryBytes = UInt64(columns[2]).map { $0 * 1024 }
                let uptimeSeconds = parseElapsedTime(String(columns[3]))
                let command = columns.count == 5 ? String(columns[4]) : nil

                result[pid] = ProcessSnapshot(
                    command: command,
                    cpuPercent: cpuPercent,
                    memoryBytes: memoryBytes,
                    uptimeSeconds: uptimeSeconds
                )
            }
            return result
        } catch {
            return [:]
        }
    }

    private static func parseElapsedTime(_ value: String) -> Int? {
        let dayParts = value.split(separator: "-", maxSplits: 1)
        let days: Int
        let timePart: Substring

        if dayParts.count == 2 {
            guard let parsedDays = Int(dayParts[0]) else { return nil }
            days = parsedDays
            timePart = dayParts[1]
        } else {
            days = 0
            timePart = dayParts[0]
        }

        let components = timePart.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2 || components.count == 3 else { return nil }

        let hours = components.count == 3 ? components[0] : 0
        let minutes = components.count == 3 ? components[1] : components[0]
        let seconds = components.count == 3 ? components[2] : components[1]
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    private static func executablePath(for pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processExists(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private static func send(signal: Int32, to pid: Int) throws {
        guard kill(pid_t(pid), signal) == 0 else {
            if errno == ESRCH {
                throw PortScannerError.processNotFound(pid)
            }
            throw PortScannerError.signalFailed(pid: pid, signal: signal)
        }
    }

    private static func managedTreeRoot(for port: PortInfo) -> Int {
        guard let projectDirectory = port.projectDirectory else { return port.pid }

        var currentPID = port.pid

        for _ in 0..<8 {
            guard let parentPID = parentPID(of: currentPID), parentPID > 1,
                  let parentCommand = processValue(pid: parentPID, field: "command")?.lowercased(),
                  isManagedLauncher(parentCommand),
                  let parentDirectory = workingDirectory(for: parentPID),
                  isInsideProject(parentDirectory, projectDirectory: projectDirectory) else {
                break
            }
            currentPID = parentPID
        }

        return currentPID
    }

    private static func isManagedLauncher(_ command: String) -> Bool {
        guard let firstArgument = command.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        let executable = URL(fileURLWithPath: String(firstArgument)).lastPathComponent.lowercased()
        let launchers: Set<String> = [
            "node", "npm", "npx", "pnpm", "yarn", "bun",
            "vite", "next", "nodemon", "tsx", "ts-node",
            "java", "mvn", "mvnw", "gradle", "gradlew",
            "uvicorn", "gunicorn", "flask",
        ]
        return launchers.contains(executable) || executable.hasPrefix("python")
    }

    private static func isInsideProject(_ directory: String, projectDirectory: String) -> Bool {
        directory == projectDirectory || directory.hasPrefix(projectDirectory + "/")
    }

    private static func parentPID(of pid: Int) -> Int? {
        guard let value = processValue(pid: pid, field: "ppid") else { return nil }
        return Int(value)
    }

    private static func childPIDs(of pid: Int) -> [Int] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", String(pid)]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return output.split(whereSeparator: { $0.isNewline }).compactMap { Int($0) }
        } catch {
            return []
        }
    }

    private static func descendants(of pid: Int) -> [Int] {
        var result: [Int] = []
        for child in childPIDs(of: pid) {
            result.append(child)
            result.append(contentsOf: descendants(of: child))
        }
        return result
    }
}

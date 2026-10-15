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
    public let serviceName: String?
    public let containerID: String?
    public let containerName: String?
    public let composeProject: String?
    public let composeService: String?
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let uptimeSeconds: Int?

    public var isDevelopmentService: Bool {
        projectDirectory != nil || containerID != nil
    }

    public var runtimeName: String {
        if containerID != nil {
            return "Docker"
        }
        let text = "\(processName) \(executable ?? "") \(command ?? "")".lowercased()
        if serviceName != nil && (text.contains("java") || text.contains("gradle") || text.contains("maven")) {
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
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .processNotFound(let pid):
            return "进程 \(pid) 已不存在"
        case .signalFailed(let pid, let signal):
            return "无法向进程 \(pid) 发送信号 \(signal)"
        case .commandFailed(let message):
            return message
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

    private struct DockerPortSnapshot {
        let containerID: String
        let containerName: String
        let composeProject: String?
        let composeService: String?
        let projectDirectory: String?
        let command: String?
    }

    private struct DockerInspect: Decodable {
        let id: String
        let name: String
        let config: DockerConfig
        let networkSettings: DockerNetworkSettings

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case config = "Config"
            case networkSettings = "NetworkSettings"
        }
    }

    private struct DockerConfig: Decodable {
        let image: String?
        let command: [String]?
        let labels: [String: String]?

        enum CodingKeys: String, CodingKey {
            case image = "Image"
            case command = "Cmd"
            case labels = "Labels"
        }
    }

    private struct DockerNetworkSettings: Decodable {
        let ports: [String: [DockerPortBinding]?]?

        enum CodingKeys: String, CodingKey {
            case ports = "Ports"
        }
    }

    private struct DockerPortBinding: Decodable {
        let hostPort: String

        enum CodingKeys: String, CodingKey {
            case hostPort = "HostPort"
        }
    }

    private struct PM2Process: Decodable {
        let pid: Int?
        let pmID: Int?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case pid
            case pmID = "pm_id"
            case name
        }
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

            let dockerPorts = Self.dockerPortSnapshots()
            let regularRawPorts = rawPorts.filter { dockerPorts[$0.port] == nil }
            let pids = Array(Set(regularRawPorts.map(\.pid)))
            let directories = Self.workingDirectories(for: pids)
            let snapshots = Self.processSnapshots(for: pids)

            var results = regularRawPorts.map { raw in
                let directory = directories[raw.pid]
                let projectDirectory = Self.projectDirectory(from: directory)
                let snapshot = snapshots[raw.pid]
                let serviceName = Self.springBootServiceName(
                    command: snapshot?.command,
                    projectDirectory: projectDirectory
                )
                return PortInfo(
                    port: raw.port,
                    processName: raw.processName,
                    pid: raw.pid,
                    directory: directory,
                    command: snapshot?.command,
                    executable: Self.executablePath(for: raw.pid),
                    projectDirectory: projectDirectory,
                    projectName: Self.projectName(for: projectDirectory),
                    serviceName: serviceName,
                    containerID: nil,
                    containerName: nil,
                    composeProject: nil,
                    composeService: nil,
                    cpuPercent: snapshot?.cpuPercent,
                    memoryBytes: snapshot?.memoryBytes,
                    uptimeSeconds: snapshot?.uptimeSeconds
                )
            }

            results.append(contentsOf: dockerPorts.map { port, docker in
                PortInfo(
                    port: port,
                    processName: "docker",
                    pid: 0,
                    directory: docker.projectDirectory,
                    command: docker.command,
                    executable: nil,
                    projectDirectory: docker.projectDirectory,
                    projectName: docker.composeProject ?? docker.containerName,
                    serviceName: docker.composeService ?? docker.containerName,
                    containerID: docker.containerID,
                    containerName: docker.containerName,
                    composeProject: docker.composeProject,
                    composeService: docker.composeService,
                    cpuPercent: nil,
                    memoryBytes: nil,
                    uptimeSeconds: nil
                )
            })

            if !includeAll {
                results = results.filter(\.isDevelopmentService)
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
        if let containerID = port.containerID {
            try Self.stopDockerContainer(containerID, force: mode == .force)
            return
        }

        guard port.pid > 0 else {
            throw PortScannerError.commandFailed("没有可停止的宿主进程")
        }

        if let pm2 = Self.pm2Process(for: port) {
            try Self.stopPM2Process(pm2, port: port)
            return
        }

        guard Self.processExists(port.pid) else {
            throw PortScannerError.processNotFound(port.pid)
        }

        let managedRootPID = Self.managedTreeRoot(for: port)
        let respawningSupervisorPID = Self.nodemonSupervisorPID(for: port)
        switch mode {
        case .terminate:
            if let respawningSupervisorPID {
                try Self.stopManagedTree(respawningSupervisorPID, signal: SIGTERM)
            } else {
                try Self.send(signal: SIGTERM, to: port.pid)
            }
        case .force:
            if let respawningSupervisorPID {
                try Self.stopManagedTree(respawningSupervisorPID, signal: SIGKILL)
            } else {
                try Self.send(signal: SIGKILL, to: port.pid)
            }
        case .processTree:
            try Self.stopManagedTree(managedRootPID, signal: SIGTERM)
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

    private static func springBootServiceName(command: String?, projectDirectory: String?) -> String? {
        guard let command else { return nil }
        let lower = command.lowercased()
        let isJavaProcess = lower.contains("java") || lower.contains("mvn") || lower.contains("gradle")
        guard isJavaProcess else { return nil }

        if let explicit = firstRegexGroup(
            in: command,
            pattern: #"(?:-D|--)spring\.application\.name=([^\s]+)"#
        ) {
            return trimQuotes(explicit)
        }

        if let configured = springApplicationName(from: projectDirectory) {
            return configured
        }

        let looksLikeSpringBoot = lower.contains("spring-boot") ||
            lower.contains("org.springframework.boot") ||
            lower.contains("org.springframework.boot.loader")

        if looksLikeSpringBoot,
           let jarPath = firstRegexGroup(in: command, pattern: #"-jar\s+([^\s]+\.jar)"#) {
            return normalizedJarServiceName(jarPath)
        }

        return nil
    }

    private static func springApplicationName(from projectDirectory: String?) -> String? {
        guard let projectDirectory else { return nil }

        let root = URL(fileURLWithPath: projectDirectory)
        let relativeCandidates = [
            "src/main/resources/application.properties",
            "src/main/resources/application.yml",
            "src/main/resources/application.yaml",
            "src/main/resources/bootstrap.properties",
            "src/main/resources/bootstrap.yml",
            "src/main/resources/bootstrap.yaml",
            "config/application.properties",
            "config/application.yml",
            "config/application.yaml",
            "application.properties",
            "application.yml",
            "application.yaml",
        ]

        for relativePath in relativeCandidates {
            let url = root.appendingPathComponent(relativePath)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            if url.pathExtension == "properties" {
                for rawLine in content.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
                    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2,
                          parts[0].trimmingCharacters(in: .whitespaces) == "spring.application.name" else {
                        continue
                    }
                    let value = trimQuotes(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                    if !value.isEmpty, !value.contains("${") {
                        return value
                    }
                }
            } else if let value = springApplicationNameFromYAML(content) {
                return value
            }
        }

        return nil
    }

    private static func springApplicationNameFromYAML(_ content: String) -> String? {
        var springIndent: Int?
        var applicationIndent: Int?

        for rawLine in content.components(separatedBy: .newlines) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawLine
            let trimmed = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if let flat = firstRegexGroup(in: trimmed, pattern: #"^spring\.application\.name\s*:\s*(.+)$"#) {
                let value = trimQuotes(flat.trimmingCharacters(in: .whitespaces))
                if !value.isEmpty, !value.contains("${") { return value }
            }

            let indent = withoutComment.prefix { $0 == " " || $0 == "\t" }.count
            if trimmed == "spring:" {
                springIndent = indent
                applicationIndent = nil
                continue
            }

            if let activeSpringIndent = springIndent {
                if indent <= activeSpringIndent {
                    applicationIndent = nil
                    springIndent = nil
                    continue
                }
                if trimmed == "application:" {
                    applicationIndent = indent
                    continue
                }
            }

            if let applicationIndent, indent > applicationIndent, trimmed.hasPrefix("name:") {
                let value = trimQuotes(String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces))
                if !value.isEmpty, !value.contains("${") { return value }
            }
        }

        return nil
    }

    private static func normalizedJarServiceName(_ jarPath: String) -> String {
        var name = URL(fileURLWithPath: trimQuotes(jarPath)).deletingPathExtension().lastPathComponent
        if let range = name.range(
            of: #"-(?:\d+\.)+\d+(?:[-.][A-Za-z0-9]+)*$"#,
            options: .regularExpression
        ) {
            name.removeSubrange(range)
        }
        return name
    }

    private static func firstRegexGroup(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range])
    }

    private static func trimQuotes(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func dockerPortSnapshots() -> [Int: DockerPortSnapshot] {
        guard let dockerURL = dockerExecutableURL() else { return [:] }

        let list = runCommand(executableURL: dockerURL, arguments: ["ps", "-q"])
        guard list.status == 0 else { return [:] }

        let ids = list.output.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard !ids.isEmpty else { return [:] }

        let inspect = runCommand(executableURL: dockerURL, arguments: ["inspect"] + ids)
        guard inspect.status == 0,
              let data = inspect.output.data(using: .utf8),
              let containers = try? JSONDecoder().decode([DockerInspect].self, from: data) else {
            return [:]
        }

        var result: [Int: DockerPortSnapshot] = [:]
        for container in containers {
            let labels = container.config.labels ?? [:]
            let composeProject = labels["com.docker.compose.project"]
            let composeService = labels["com.docker.compose.service"]
            let workingDirectory = labels["com.docker.compose.project.working_dir"]
            let containerName = container.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            let commandParts = [container.config.image].compactMap { $0 } + (container.config.command ?? [])
            let command = commandParts.isEmpty ? nil : commandParts.joined(separator: " ")

            if let ports = container.networkSettings.ports {
                for (containerPort, bindings) in ports where containerPort.hasSuffix("/tcp") {
                    guard let bindings else { continue }
                    for binding in bindings {
                        guard let hostPort = Int(binding.hostPort) else { continue }
                        result[hostPort] = DockerPortSnapshot(
                            containerID: container.id,
                            containerName: containerName,
                            composeProject: composeProject,
                            composeService: composeService,
                            projectDirectory: workingDirectory,
                            command: command
                        )
                    }
                }
            }
        }

        return result
    }

    private static func dockerExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private static func stopDockerContainer(_ containerID: String, force: Bool) throws {
        guard let dockerURL = dockerExecutableURL() else {
            throw PortScannerError.commandFailed("未找到 Docker CLI")
        }

        let command = force ? "kill" : "stop"
        let result = runCommand(executableURL: dockerURL, arguments: [command, containerID])
        guard result.status == 0 else {
            throw PortScannerError.commandFailed("Docker \(command) 失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func runCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> (status: Int32, output: String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = executableURL
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = pipe
        if let environment {
            task.environment = environment
        }

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (task.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private static func pm2Process(for port: PortInfo) -> PM2Process? {
        guard isPM2DaemonRunning(), let pm2URL = pm2ExecutableURL(projectDirectory: port.projectDirectory) else { return nil }
        let environment = pm2Environment(pm2URL: pm2URL, nodeExecutable: port.executable)

        let result = runCommand(executableURL: pm2URL, arguments: ["jlist"], environment: environment)
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let processes = try? JSONDecoder().decode([PM2Process].self, from: data) else {
            return nil
        }
        return processes.first { $0.pid == port.pid }
    }

    private static func stopPM2Process(_ process: PM2Process, port: PortInfo) throws {
        guard let pmID = process.pmID, let pm2URL = pm2ExecutableURL(projectDirectory: port.projectDirectory) else {
            throw PortScannerError.commandFailed("无法确定 PM2 应用 ID")
        }
        let environment = pm2Environment(pm2URL: pm2URL, nodeExecutable: port.executable)

        let result = runCommand(
            executableURL: pm2URL,
            arguments: ["stop", String(pmID)],
            environment: environment
        )
        guard result.status == 0 else {
            let name = process.name ?? String(pmID)
            throw PortScannerError.commandFailed("PM2 停止 \(name) 失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func pm2Environment(pm2URL: URL, nodeExecutable: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var pathParts = [pm2URL.deletingLastPathComponent().path]
        if let nodeExecutable {
            let nodeURL = URL(fileURLWithPath: nodeExecutable)
            if nodeURL.lastPathComponent.lowercased().hasPrefix("node") {
                pathParts.append(nodeURL.deletingLastPathComponent().path)
            }
        }
        pathParts.append(environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["PATH"] = pathParts.joined(separator: ":")
        environment["PM2_SILENT"] = "true"
        environment["NO_COLOR"] = "1"
        return environment
    }

    private static func isPM2DaemonRunning() -> Bool {
        let result = runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", "PM2.*Daemon"]
        )
        return result.status == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func pm2ExecutableURL(projectDirectory: String?) -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let projectDirectory {
            candidates.append(URL(fileURLWithPath: projectDirectory).appendingPathComponent("node_modules/.bin/pm2").path)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/pm2",
            "/usr/local/bin/pm2",
            NSHomeDirectory() + "/Library/pnpm/pm2",
        ])

        let nvmRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions.map { $0.appendingPathComponent("bin/pm2").path })
        }

        if let candidate = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: candidate)
        }

        let shellLookup = runCommand(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lic", "command -v pm2"]
        )
        let path = shellLookup.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first { $0.hasPrefix("/") }
        guard shellLookup.status == 0, let path, fileManager.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
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

    private static func nodemonSupervisorPID(for port: PortInfo) -> Int? {
        guard let projectDirectory = port.projectDirectory else { return nil }

        var currentPID = port.pid
        for _ in 0..<8 {
            guard let parentPID = parentPID(of: currentPID), parentPID > 1,
                  let parentCommand = processValue(pid: parentPID, field: "command"),
                  let parentDirectory = workingDirectory(for: parentPID),
                  isInsideProject(parentDirectory, projectDirectory: projectDirectory) else {
                break
            }

            if parentCommand.lowercased().contains("nodemon") {
                return parentPID
            }
            currentPID = parentPID
        }

        return nil
    }

    private static func stopManagedTree(_ rootPID: Int, signal: Int32) throws {
        let descendants = descendants(of: rootPID)

        // Stop the supervisor/launcher first so nodemon/npm/pnpm cannot respawn a child
        // while we are tearing down the rest of the tree.
        if processExists(rootPID) {
            try send(signal: signal, to: rootPID)
        }

        if signal == SIGTERM {
            Thread.sleep(forTimeInterval: 0.2)
        }

        for pid in descendants.reversed() where processExists(pid) {
            do {
                try send(signal: signal, to: pid)
            } catch PortScannerError.processNotFound {
                continue
            }
        }
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

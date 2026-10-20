import Darwin
import Foundation

nonisolated struct ProjectPortImport {
    let project: ManagedProject
    let note: String

    @MainActor
    init(name: String, directory: String, ports: [PortInfo], existing: [ManagedProject]) throws {
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        try ProjectStore.checkDirectory(root)
        var project = existing.first {
            URL(fileURLWithPath: $0.directory).resolvingSymlinksInPath().standardizedFileURL.path == root
        } ?? ManagedProject(name: name, directory: root)
        var seen = Set<Int>()
        var unavailable = 0
        var added = 0
        for port in ports {
            guard port.containerID == nil else { unavailable += 1; continue }
            guard seen.insert(port.pid).inserted else { continue }
            guard let directory = port.directory, let executable = port.executable,
                  let liveDirectory = PortScanner.workingDirectory(for: port.pid) else {
                unavailable += 1
                continue
            }
            let working = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
            guard URL(fileURLWithPath: liveDirectory).resolvingSymlinksInPath().standardizedFileURL.path == working,
                  working == root || working.hasPrefix(root + "/"),
                  let arguments = Self.arguments(for: port.pid, executable: executable),
                  let command = Self.command(arguments: arguments, executable: executable) else {
                unavailable += 1
                continue
            }
            let relative = working == root ? "." : String(working.dropFirst(root.count + 1))
            let task = ProjectTask(name: working == root ? port.runtimeName : "\(port.runtimeName) · \(URL(fileURLWithPath: working).lastPathComponent)",
                                   command: command, directory: relative)
            if Self.append(task, to: &project) { added += 1 }
        }
        self.project = project
        var messages = [existing.contains(where: { $0.id == project.id })
                        ? "已匹配收藏项目，保留原有任务。" : "项目目录已预填，保存后加入项目列表。"]
        if added > 0 { messages.append("已预填 \(added) 个任务，请确认启动参数和所需环境变量。") }
        if unavailable > 0 { messages.append("部分服务无法还原启动命令，未生成任务（如 IDE 启动的 Java 或 Docker 服务）。") }
        if added == 0 && unavailable == 0 { messages.append("启动任务已存在，未重复添加。") }
        note = messages.joined(separator: "\n")
    }

    static func append(_ task: ProjectTask, to project: inout ManagedProject) -> Bool {
        let root = URL(fileURLWithPath: project.directory)
        let directory = root.appendingPathComponent(task.directory).resolvingSymlinksInPath().standardizedFileURL.path
        guard !project.tasks.contains(where: {
            $0.command == task.command && root.appendingPathComponent($0.directory).resolvingSymlinksInPath().standardizedFileURL.path == directory
        }) else { return false }
        project.tasks.append(task)
        return true
    }

    static func command(arguments: [String], executable: String) -> String? {
        guard arguments.count > 1, executable.hasPrefix("/"),
              !arguments.contains(where: { $0.hasPrefix("@") || $0.contains("/var/folders/") }) else { return nil }
        let runtime = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        guard runtime == "node" || runtime.hasPrefix("python") || runtime == "ruby" ||
              (runtime == "java" && arguments.contains("-jar")) else { return nil }
        return ([executable] + arguments.dropFirst()).map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
            .joined(separator: " ")
    }

    private static func arguments(for pid: Int, executable: String) -> [String]? {
        var query = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { sysctl(&query, UInt32(query.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        return parseArguments(Array(bytes.prefix(size)), executable: executable)
    }

    static func parseArguments(_ bytes: [UInt8], executable: String) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= bytes.count else { return nil }
        var index = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0),
                  let value = String(bytes: bytes[index..<end], encoding: .utf8) else { return nil }
            index = end + 1
            return value
        }
        guard readString() == executable else { return nil }
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard let argument = readString() else { return nil }
            arguments.append(argument)
        }
        return arguments
    }
}

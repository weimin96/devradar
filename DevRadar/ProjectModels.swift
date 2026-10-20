import Foundation

nonisolated struct ProjectTask: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = "开发服务"
    var command = ""
    var directory = "."
}

nonisolated struct ManagedProject: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var directory: String
    var tasks: [ProjectTask] = []

    func workingDirectory(for task: ProjectTask) throws -> URL {
        guard !task.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectError.message("任务名称和启动命令不能为空")
        }
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
        guard !task.directory.hasPrefix("/") else {
            throw ProjectError.message("工作目录须为项目内的相对路径")
        }
        let target = root.appendingPathComponent(task.directory).resolvingSymlinksInPath().standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw ProjectError.message("工作目录不能超出项目目录")
        }
        try ProjectStore.checkDirectory(target.path)
        return target
    }
}

nonisolated enum ProjectError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

nonisolated struct ProjectStore: Sendable {
    let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DevRadar/projects.json")) {
        self.url = url
    }

    func load() throws -> [ManagedProject] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ManagedProject].self, from: Data(contentsOf: url))
    }

    func save(_ projects: [ManagedProject]) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(projects).write(to: url, options: .atomic)
    }

    static func checkDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            throw ProjectError.message("项目目录不可用，请重新选择：\(path)")
        }
    }

    static func validate(_ project: ManagedProject, among projects: [ManagedProject]) throws {
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectError.message("项目名称不能为空")
        }
        try checkDirectory(project.directory)
        let path = URL(fileURLWithPath: project.directory).resolvingSymlinksInPath().standardizedFileURL.path
        guard !projects.contains(where: {
            $0.id != project.id && URL(fileURLWithPath: $0.directory).resolvingSymlinksInPath().standardizedFileURL.path == path
        }) else { throw ProjectError.message("该目录已添加") }
        for task in project.tasks { _ = try project.workingDirectory(for: task) }
    }
}

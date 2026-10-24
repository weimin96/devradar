import Darwin
import Foundation

@main
struct ProjectPortImportTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProjectError.message(message) }
    }

    @MainActor
    static func main() throws {
        let executable = "/opt/runtime/python3"
        let arguments = ["python3", "-c", "print('中文 $HOME `id`')", "", "路径 有空格"]
        var count = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &count) { Array($0) }
        bytes += Array(executable.utf8) + [0, 0]
        bytes += arguments.flatMap { Array($0.utf8) + [0] }
        bytes += Array("PRIVATE_ENV=not-an-argument".utf8) + [0]
        try expect(ProjectPortImport.parseArguments(bytes, executable: executable) == arguments,
                   "argv boundaries, Unicode and empty arguments survive; environment excluded")
        try expect(ProjectPortImport.parseArguments(bytes, executable: "/different/process") == nil, "changed executable is rejected")
        try expect(ProjectPortImport.parseArguments(Array(bytes.prefix(6)), executable: executable) == nil, "truncated data is rejected")

        guard let command = ProjectPortImport.command(arguments: arguments, executable: executable) else {
            throw ProjectError.message("Python arguments should be importable")
        }
        let output = try ProjectCommand.run(executable: "/bin/zsh", arguments: ["-c", "set -- " + command + "; printf '%s\\0' \"$@\""],
                                            directory: "/tmp").checked()
        let actual = output.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        try expect(actual == [executable] + arguments.dropFirst(), "shell quoting preserves literal arguments without expansion")
        try expect(ProjectPortImport.command(arguments: ["java", "com.company.Application"], executable: "/runtime/java") == nil,
                   "IDE Java command is not guessed")
        try expect(ProjectPortImport.command(arguments: ["java", "@/args"], executable: "/runtime/java") == nil,
                   "argument files are not persisted")
        try expect(ProjectPortImport.command(arguments: ["java", "-jar", "service.jar"], executable: "/runtime/java") != nil,
                   "direct Java jar command can be reviewed")
        try expect(ProjectPortImport.command(arguments: ["node", "/private/var/folders/cache/script.js"], executable: "/runtime/node") == nil,
                   "temporary launch paths are not persisted")
        var project = ManagedProject(name: "已有名称", directory: "/tmp", tasks: [ProjectTask(name: "已有任务", command: "pwd")])
        let original = project
        let task = ProjectTask(name: "前端", command: "node app.js", directory: "frontend")
        try expect(ProjectPortImport.append(task, to: &project), "new task is appended")
        try expect(!ProjectPortImport.append(task, to: &project), "repeated task is not appended")
        var equivalent = task
        equivalent.directory = "./frontend"
        try expect(!ProjectPortImport.append(equivalent, to: &project), "equivalent relative directory does not duplicate a task")
        try expect(project.id == original.id && project.name == original.name && project.tasks.first == original.tasks.first,
                   "existing project identity and tasks are preserved")
        let draft = try ProjectPortImport(name: "扫描名称", directory: "/tmp/.", ports: [], existing: [project])
        try expect(draft.project == project, "canonical directory reuses saved project")
        try expect(try ProjectPortImport(name: "新项目", directory: "/tmp", ports: [], existing: []).project.tasks.isEmpty,
                   "directory can be collected without inventing a task")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("DevRadar 收藏验证 \(UUID())")
        let module = workspace.appendingPathComponent("backend")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let readyFile = workspace.appendingPathComponent("backend.ready")
        func waitUntilReady(_ file: URL, process: Process) throws {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: file.path), process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            try expect(FileManager.default.fileExists(atPath: file.path), "验证进程未能就绪")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os,pathlib,time; pathlib.Path(os.environ['DEVRADAR_READY']).touch(); time.sleep(30)"]
        process.environment = ProcessInfo.processInfo.environment.merging(["DEVRADAR_READY": readyFile.path]) { _, value in value }
        process.currentDirectoryURL = module
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try waitUntilReady(readyFile, process: process)
        var pathBytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(process.processIdentifier, &pathBytes, UInt32(pathBytes.count)) > 0 else {
            throw ProjectError.message("无法读取验证进程路径")
        }
        let processExecutable = String(cString: pathBytes)
        func port(_ number: Int, owner: Process? = nil, directory: URL? = nil) -> PortInfo {
            PortInfo(port: number, processName: "python3", pid: Int((owner ?? process).processIdentifier), directory: (directory ?? module).path,
                     command: "python3", executable: processExecutable, projectDirectory: module.path,
                     projectRootDirectory: workspace.path, projectName: "收藏验证", serviceName: nil,
                     containerID: nil, containerName: nil, composeProject: nil, composeService: nil,
                     cpuPercent: nil, memoryBytes: nil, uptimeSeconds: nil)
        }
        let collected = try ProjectPortImport(name: "收藏验证", directory: workspace.path, ports: [port(8080), port(8081)], existing: [])
        try expect(collected.project.tasks.count == 1, "multiple ports from one live process create one task")
        try expect(collected.project.tasks.first?.directory == "backend", "task retains relative working directory")
        let repeated = try ProjectPortImport(name: "扫描名称", directory: workspace.path, ports: [port(8080)], existing: [collected.project])
        try expect(repeated.project == collected.project, "collecting again preserves identity and avoids duplicate tasks")
        let frontend = workspace.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: frontend, withIntermediateDirectories: true)
        let frontendProcess = Process()
        frontendProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let frontendReady = workspace.appendingPathComponent("frontend.ready")
        frontendProcess.arguments = ["-c", "import os,pathlib,time; pathlib.Path(os.environ['DEVRADAR_READY']).touch(); time.sleep(31)"]
        frontendProcess.environment = ProcessInfo.processInfo.environment.merging(["DEVRADAR_READY": frontendReady.path]) { _, value in value }
        frontendProcess.currentDirectoryURL = frontend
        try frontendProcess.run()
        defer { if frontendProcess.isRunning { frontendProcess.terminate(); frontendProcess.waitUntilExit() } }
        try waitUntilReady(frontendReady, process: frontendProcess)
        let services = [port(8080), port(8081), port(5189, owner: frontendProcess, directory: frontend)]
        let multiple = try ProjectPortImport(name: "收藏验证", directory: workspace.path, ports: services, existing: [collected.project])
        try expect(multiple.project.tasks.count == 2 && multiple.project.tasks.first == collected.project.tasks.first,
                   "multiple process commands are imported without replacing an existing task")
        try expect(multiple.project.tasks.map(\.directory) == ["backend", "frontend"], "each imported command keeps its own module directory")
        try expect(multiple.project.tasks[0].command != multiple.project.tasks[1].command && multiple.project.tasks[1].command.contains("time.sleep(31)"),
                   "distinct recognized arguments reach the corresponding task")
        let multipleAgain = try ProjectPortImport(name: "扫描名称", directory: workspace.path, ports: services, existing: [multiple.project])
        try expect(multipleAgain.project == multiple.project, "repeated multi-command collection remains unchanged")
        let store = ProjectStore(url: workspace.appendingPathComponent("projects.json"))
        try expect(!FileManager.default.fileExists(atPath: store.url.path), "preview does not persist configuration")
        try ProjectStore.validate(multiple.project, among: [])
        try store.save([multiple.project])
        try expect(try store.load() == [multiple.project], "all recognized commands survive confirmation and reload")
        process.terminate(); process.waitUntilExit()
        let exited = try ProjectPortImport(name: "已退出", directory: workspace.path, ports: [port(8080)], existing: [])
        try expect(exited.project.tasks.isEmpty && exited.note.contains("未生成任务"), "exited process is explicitly reported")
        print("ProjectPortImport: argument parsing, shell quoting, command eligibility, duplicate tasks and project reuse passed")
    }
}

import Foundation

@main
struct PortScannerTests {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "PortScannerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        }

        let repository = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".devradar-port-checks-\(UUID().uuidString)/产品/model-manager")
        let backend = repository.appendingPathComponent("backend")
        let frontend = repository.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frontend, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent().deletingLastPathComponent()) }
        try Data().write(to: backend.appendingPathComponent("pom.xml"))
        try Data().write(to: frontend.appendingPathComponent("package.json"))
        try Data().write(to: repository.appendingPathComponent(".git"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.currentDirectoryURL = backend
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        setenv("LC_ALL", "C", 1)
        try check(PortScanner.workingDirectory(for: Int(process.processIdentifier)) == backend.path,
              "C locale must preserve Chinese working directory")
        try check(PortScanner.projectDirectory(from: backend.path) == backend.path,
              "backend module remains the service directory")
        try check(PortScanner.projectDirectory(from: frontend.path) == frontend.path,
              "frontend module remains the service directory")
        try check(PortScanner.projectRootDirectory(from: backend.path) == repository.path,
                  "backend groups under repository root with git file")
        try check(PortScanner.projectRootDirectory(from: frontend.path) == repository.path,
                  "frontend groups under the same repository")
        try FileManager.default.removeItem(at: repository.appendingPathComponent(".git"))
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: false)
        try check(PortScanner.projectRootDirectory(from: backend.path) == repository.path,
                  "regular repository git directory is recognized")
        try FileManager.default.removeItem(at: repository.appendingPathComponent(".git"))
        try check(PortScanner.projectRootDirectory(from: backend.path) == backend.path,
                  "standalone module keeps its own directory")
        try check(PortScanner.projectRootDirectory(from: nil) == nil, "unknown root remains unknown")
        let listener = Process()
        let ready = Pipe()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        listener.arguments = ["-u", "-c", "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); print(s.getsockname()[1],flush=True); time.sleep(30)"]
        listener.standardOutput = ready
        try listener.run()
        defer { if listener.isRunning { listener.terminate(); listener.waitUntilExit() } }
        var line = Data()
        while let byte = try ready.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { line.append(byte) }
        guard let number = Int(String(decoding: line, as: UTF8.self)),
              let identity = ProcessIdentity.read(pid: Int(listener.processIdentifier)) else {
            throw PortScannerError.commandFailed("验证服务未就绪")
        }
        func snapshot(pid: Int, port: Int, identity: ProcessIdentity?) -> PortInfo {
            PortInfo(port: port, processName: "python3", pid: pid, directory: nil, command: nil,
                executable: identity?.executable, projectDirectory: nil, projectRootDirectory: nil,
                projectName: nil, serviceName: nil, containerID: nil, containerName: nil,
                composeProject: nil, composeService: nil, cpuPercent: nil, memoryBytes: nil,
                uptimeSeconds: nil, processIdentity: identity)
        }
        let pid = Int(listener.processIdentifier)
        let stale = ProcessIdentity(executable: identity.executable, startedAtSeconds: identity.startedAtSeconds + 1,
                                    startedAtMicroseconds: identity.startedAtMicroseconds)
        for port in [snapshot(pid: pid, port: number, identity: nil),
                     snapshot(pid: pid, port: number, identity: stale),
                     snapshot(pid: pid, port: number == 65535 ? 65534 : number + 1, identity: identity)] {
            do {
                try PortScanner().stop(port, mode: .terminate)
                throw NSError(domain: "PortScannerChecks", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "身份或端口不匹配时必须拒绝停止"])
            } catch is PortScannerError {}
        }
        try check(listener.isRunning, "被拒绝的停止操作不得影响现有服务")
        try PortScanner().stop(snapshot(pid: pid, port: number, identity: identity), mode: .force)
        listener.waitUntilExit()
        try check(!listener.isRunning, "身份和端口一致的服务可以停止")
        print("PortScannerTests: 路径识别、进程身份、端口归属及真实服务停止验证通过")
    }
}

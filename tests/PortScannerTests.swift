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
        print("PortScannerTests: 8 checks passed")
    }
}

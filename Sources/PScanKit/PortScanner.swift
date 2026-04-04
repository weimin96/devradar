import Foundation

public struct PortInfo: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let port: Int
    public let processName: String
    public let pid: Int
    public let directory: String?

    public var projectName: String? {
        guard let directory else { return nil }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
}

public final class PortScanner: @unchecked Sendable {
    public init() {}

    public func fetchPorts(includeAll: Bool = false) -> [PortInfo] {
        let currentUser = NSUserName()
        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P", "-u", currentUser]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return [] }

            let lines = output.components(separatedBy: "\n").dropFirst()
            var seen = Set<Int>()
            var results: [PortInfo] = []

            for line in lines {
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                guard columns.count >= 9 else { continue }

                let processName = String(columns[0])
                let pid = Int(columns[1]) ?? 0
                let nameField = String(columns[8])

                if let colonIndex = nameField.lastIndex(of: ":") {
                    let portStr = nameField[nameField.index(after: colonIndex)...]
                    if let port = Int(portStr), !seen.contains(port) {
                        seen.insert(port)
                        let dir = Self.workingDirectory(for: pid)
                        let isProject = dir != nil && dir != "/" && !Self.isSystemPath(dir!)
                        results.append(PortInfo(
                            port: port,
                            processName: processName,
                            pid: pid,
                            directory: isProject ? dir : nil
                        ))
                    }
                }
            }

            if !includeAll {
                results = results.filter { $0.directory != nil }
            }

            return results.sorted { a, b in
                if (a.directory != nil) != (b.directory != nil) {
                    return a.directory != nil
                }
                return a.port < b.port
            }
        } catch {
            return []
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
        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", String(pid), "-a", "-d", "cwd", "-Fn"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n/") {
                    return String(line.dropFirst())
                }
            }
        } catch {}

        return nil
    }
}

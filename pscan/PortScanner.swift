import AppKit
import Foundation
import Observation

struct PortInfo: Identifiable, Hashable {
    let id = UUID()
    let port: Int
    let processName: String
    let pid: Int
    let directory: String?

    var projectName: String? {
        guard let directory else { return nil }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
}

@Observable
final class PortScanner {
    var ports: [PortInfo] = []
    private var timer: Timer?

    private static let currentUser = NSUserName()

    func startScanning() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stopScanning() {
        timer?.invalidate()
        timer = nil
    }

    func scan() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let results = Self.fetchPorts()
            DispatchQueue.main.async {
                self.ports = results
            }
        }
    }

    private static func fetchPorts() -> [PortInfo] {
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

            // Get PIDs of all GUI apps to filter them out (must be on main thread)
            var guiAppPIDs = Set<Int>()
            DispatchQueue.main.sync {
                guiAppPIDs = Set(
                    NSWorkspace.shared.runningApplications
                        .filter { $0.bundleIdentifier != nil }
                        .map { Int($0.processIdentifier) }
                )
            }

            let lines = output.components(separatedBy: "\n").dropFirst() // skip header
            var seen = Set<Int>()
            var results: [PortInfo] = []

            for line in lines {
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                guard columns.count >= 9 else { continue }

                let processName = String(columns[0])
                let pid = Int(columns[1]) ?? 0
                let nameField = String(columns[8])

                // Skip GUI apps (Figma, Raycast, ControlCenter, etc.)
                if guiAppPIDs.contains(pid) { continue }

                // nameField looks like "*:3000" or "127.0.0.1:3000"
                if let colonIndex = nameField.lastIndex(of: ":") {
                    let portStr = nameField[nameField.index(after: colonIndex)...]
                    if let port = Int(portStr), !seen.contains(port) {
                        seen.insert(port)
                        let dir = workingDirectory(for: pid)
                        let isProject = dir != nil && dir != "/" && !isSystemPath(dir!)
                        results.append(PortInfo(port: port, processName: processName, pid: pid, directory: isProject ? dir : nil))
                    }
                }
            }

            // Project ports first, then others, each group sorted by port
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

    func kill(port: PortInfo) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = [String(port.pid)]
        try? process.run()
        process.waitUntilExit()
        // Refresh after kill
        scan()
    }

    private static func isSystemPath(_ path: String) -> Bool {
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

    private static func workingDirectory(for pid: Int) -> String? {
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

            // Output format: lines starting with "n" contain the path
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n/") {
                    return String(line.dropFirst()) // drop the "n" prefix
                }
            }
        } catch {}

        return nil
    }
}

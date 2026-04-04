import AppKit
import Foundation
import Observation
import PScanKit

@Observable
final class AppPortScanner {
    var ports: [PortInfo] = []
    private var timer: Timer?
    private let scanner = PortScanner()

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

            // Get PIDs of all GUI apps to filter them out (must be on main thread)
            var guiAppPIDs = Set<Int>()
            DispatchQueue.main.sync {
                guiAppPIDs = Set(
                    NSWorkspace.shared.runningApplications
                        .filter { $0.bundleIdentifier != nil }
                        .map { Int($0.processIdentifier) }
                )
            }

            var results = self.scanner.fetchPorts(includeAll: true)
            results = results.filter { !guiAppPIDs.contains($0.pid) }

            DispatchQueue.main.async {
                self.ports = results
            }
        }
    }

    func kill(port: PortInfo) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = [String(port.pid)]
        try? process.run()
        process.waitUntilExit()
        scan()
    }
}

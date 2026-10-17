import AppKit
import Foundation
import Observation

@Observable
final class AppPortScanner {
    var ports: [PortInfo] = []
    var lastError: String?
    var isScanning = false

    private var timer: Timer?
    private let scanner = PortScanner()

    func startScanning() {
        if timer != nil {
            scan()
            return
        }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stopScanning() {
        timer?.invalidate()
        timer = nil
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var guiAppPIDs = Set<Int>()
            DispatchQueue.main.sync {
                guiAppPIDs = Set(
                    NSWorkspace.shared.runningApplications
                        .filter { $0.bundleIdentifier != nil }
                        .map { Int($0.processIdentifier) }
                )
            }

            let results = scanner.fetchPorts(includeAll: true, excludingPIDs: guiAppPIDs)
            DispatchQueue.main.async {
                self.ports = results
                self.isScanning = false
            }
        }
    }

    func stop(port: PortInfo, mode: ProcessStopMode) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try scanner.stop(port, mode: mode)
                Thread.sleep(forTimeInterval: 0.25)
                DispatchQueue.main.async {
                    self.lastError = nil
                    self.scan()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.scan()
                }
            }
        }
    }
}

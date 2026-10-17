import Foundation
import SwiftUI

private enum LegacyPScanMigration {
    private static let legacyBundleIdentifier = "dev.dogancan.pscan"
    private static let migrationMarker = "devradar.didMigratePScanPreferences"
    private static let preferenceKeys = [
        "showAllPorts",
        "showKillButton",
        "showFinderButton",
        "showTerminalButton",
        "groupSortMode",
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationMarker) else { return }

        if let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier) {
            for key in preferenceKeys where defaults.object(forKey: key) == nil {
                if let value = legacy[key] {
                    defaults.set(value, forKey: key)
                }
            }
        }

        defaults.set(true, forKey: migrationMarker)
    }
}

@main
struct DevRadarApp: App {
    @State private var scanner: AppPortScanner
    @State private var trafficMonitor: NetworkTrafficMonitor
    @AppStorage("showAllPorts") private var showAll = false
    @AppStorage(IgnoreRules.projectsKey) private var ignoredProjectsRaw = "[]"
    @AppStorage(IgnoreRules.portsKey) private var ignoredPortsRaw = "[]"

    init() {
        LegacyPScanMigration.runIfNeeded()
        let scanner = AppPortScanner()
        let trafficMonitor = NetworkTrafficMonitor()
        _scanner = State(initialValue: scanner)
        _trafficMonitor = State(initialValue: trafficMonitor)
        scanner.startScanning()
        trafficMonitor.start()
    }

    private var activeCount: Int {
        let ignoredProjects = IgnoreRules.strings(from: ignoredProjectsRaw)
        let ignoredPorts = IgnoreRules.ports(from: ignoredPortsRaw)
        return Set(
            scanner.ports
                .filter { port in
                    port.isDevelopmentService
                        && !ignoredPorts.contains(port.port)
                        && !ignoredProjects.contains(port.projectDirectory ?? "")
                }
                .map { $0.containerID ?? "pid:\($0.pid)" }
        ).count
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(scanner: scanner, trafficMonitor: trafficMonitor, showAll: $showAll)
        } label: {
            HStack(spacing: 1) {
                Image(systemName: "network")
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 8, weight: .regular))
                        .monospacedDigit()
                        .baselineOffset(4)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

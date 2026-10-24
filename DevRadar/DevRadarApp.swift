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
    @NSApplicationDelegateAdaptor(ProjectAppDelegate.self) private var projectLifecycle
    @State private var projects = ProjectManager.shared
    @State private var scanner: AppPortScanner
    @State private var trafficMonitor: NetworkTrafficMonitor
    @State private var packetCapture: PacketCaptureManager
    @State private var localProxy: LocalProxyManager
    @AppStorage("showAllPorts") private var showAll = false
    @AppStorage(IgnoreRules.projectsKey) private var ignoredProjectsRaw = "[]"
    @AppStorage(IgnoreRules.portsKey) private var ignoredPortsRaw = "[]"

    init() {
        LegacyPScanMigration.runIfNeeded()
        let scanner = AppPortScanner()
        let trafficMonitor = NetworkTrafficMonitor()
        let packetCapture = PacketCaptureManager()
        let localProxy = LocalProxyManager()
        _packetCapture = State(initialValue: packetCapture)
        _localProxy = State(initialValue: localProxy)
        _scanner = State(initialValue: scanner)
        _trafficMonitor = State(initialValue: trafficMonitor)
        projectLifecycle.networkQuitReady = { !packetCapture.isBusy && !DNSDiagnosticsWindow.isCapturing }
        projectLifecycle.prepareNetworkQuit = { completion in
            localProxy.stopForQuit { restored in
                guard restored else {
                    CaptureInspectorWindow.open(mode: .proxy, localProxy: localProxy,
                        packetCapture: packetCapture, trafficMonitor: trafficMonitor)
                    completion(false)
                    return
                }
                DNSDiagnosticsWindow.stopCapture()
                packetCapture.stop()
                scanner.stopScanning()
                trafficMonitor.stop { saved in
                    if !saved {
                        scanner.startScanning()
                        trafficMonitor.start()
                        let alert = NSAlert()
                        alert.messageText = "网络记录保存失败"
                        alert.informativeText = trafficMonitor.lastError ?? "无法保存网络记录，已取消退出"
                        alert.runModal()
                    }
                    completion(saved)
                }
            }
        }
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
                        && !ignoredProjects.contains(port.projectRootDirectory ?? "")
                }
                .map { $0.containerID ?? "pid:\($0.pid)" }
        ).count
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                projects: projects,
                scanner: scanner,
                trafficMonitor: trafficMonitor,
                packetCapture: packetCapture,
                localProxy: localProxy,
                showAll: $showAll
            )
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

import PScanKit
import SwiftUI

@main
struct pscanApp: App {
    @State private var scanner: AppPortScanner
    @AppStorage("showAllPorts") private var showAll = false

    init() {
        let scanner = AppPortScanner()
        _scanner = State(initialValue: scanner)
        scanner.startScanning()
    }

    private var activeCount: Int {
        Set(
            scanner.ports
                .filter(\.isDevelopmentService)
                .map { $0.containerID ?? "pid:\($0.pid)" }
        ).count
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(scanner: scanner, showAll: $showAll)
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

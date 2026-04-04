import SwiftUI

@main
struct pscanApp: App {
    @State private var scanner = AppPortScanner()
    @AppStorage("showAllPorts") private var showAll = false

    private var activeCount: Int {
        scanner.ports.filter { $0.directory != nil }.count
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

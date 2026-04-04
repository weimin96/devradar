import ServiceManagement
import SwiftUI

struct SettingsWindow {
    static func open() {
        let windowRef = NSApp.windows.first { $0.title == "pscan Options" }
        if let window = windowRef {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingView = NSHostingView(rootView: settingsView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "pscan Options"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @AppStorage("showAllPorts") private var showAll = false
    @AppStorage("showKillButton") private var showKill = true
    @AppStorage("showFinderButton") private var showFinder = true
    @AppStorage("showTerminalButton") private var showTerminal = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                launchAtLogin = !newValue
                            }
                        }
                    Toggle("Show all ports", isOn: $showAll)
                }

                Section("Actions") {
                    Toggle("Kill process button", isOn: $showKill)
                    Toggle("Open in Finder button", isOn: $showFinder)
                    Toggle("Open in Terminal button", isOn: $showTerminal)
                }
            }
            .formStyle(.grouped)

            Divider()

            VStack(spacing: 4) {
                Text("pscan")
                    .font(.headline)
                Text("Lightweight menu bar port monitor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Text("Built by")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("@mavideniz", destination: URL(string: "https://github.com/mavideniz")!)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .frame(width: 300)
    }
}

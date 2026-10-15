import ServiceManagement
import SwiftUI

struct SettingsWindow {
    static func open() {
        let windowRef = NSApp.windows.first { $0.title == "pscan 设置" }
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
        window.title = "pscan 设置"
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
                Section("通用") {
                    Toggle("登录时启动", isOn: $launchAtLogin)
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
                    Toggle("显示所有端口", isOn: $showAll)
                }

                Section("操作") {
                    Toggle("显示停止按钮", isOn: $showKill)
                    Toggle("显示 Finder 按钮", isOn: $showFinder)
                    Toggle("显示终端按钮", isOn: $showTerminal)
                }
            }
            .formStyle(.grouped)

            Divider()

            VStack(spacing: 4) {
                Text("pscan")
                    .font(.headline)
                Text("轻量级开发进程与端口管理")
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

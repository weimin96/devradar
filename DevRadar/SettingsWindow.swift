import ServiceManagement
import SwiftUI

struct SettingsWindow {
    static func open(trafficMonitor: NetworkTrafficMonitor) {
        let windowRef = NSApp.windows.first { $0.title == "DevRadar 设置" }
        if let window = windowRef {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(trafficMonitor: trafficMonitor)
        let hostingView = NSHostingView(rootView: settingsView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DevRadar 设置"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    var trafficMonitor: NetworkTrafficMonitor
    @AppStorage("showAllPorts") private var showAll = false
    @AppStorage("showKillButton") private var showKill = true
    @AppStorage("showFinderButton") private var showFinder = true
    @AppStorage("showTerminalButton") private var showTerminal = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showClearTrafficConfirmation = false

    var body: some View {
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

            Section("网络监控") {
                Button("清空网络记录", role: .destructive) {
                    showClearTrafficConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .confirmationDialog(
            "清空网络记录？",
            isPresented: $showClearTrafficConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                trafficMonitor.clearTrafficHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空实时累计和 1/3/7 天历史流量，此操作不可恢复。")
        }
    }
}

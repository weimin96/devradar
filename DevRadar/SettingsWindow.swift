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
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
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
    @AppStorage("showBrowserButton") private var showBrowser = true
    @AppStorage("showFinderButton") private var showFinder = true
    @AppStorage("showTerminalButton") private var showTerminal = true
    @AppStorage("networkAlertEnabled") private var networkAlertEnabled = true
    @AppStorage("networkAlertThresholdMBps") private var networkAlertThresholdMBps = 5.0
    @AppStorage(IgnoreRules.projectsKey) private var ignoredProjectsRaw = "[]"
    @AppStorage(IgnoreRules.portsKey) private var ignoredPortsRaw = "[]"
    @AppStorage(IgnoreRules.networkApplicationsKey) private var ignoredApplicationsRaw = "[]"
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
                Toggle("显示浏览器按钮", isOn: $showBrowser)
                Toggle("显示终端按钮", isOn: $showTerminal)
                Toggle("显示 Finder 按钮", isOn: $showFinder)
            }

            Section("网络监控") {
                Toggle("异常上传提醒", isOn: $networkAlertEnabled)
                    .onChange(of: networkAlertEnabled) { _, enabled in
                        if enabled {
                            trafficMonitor.requestNetworkAlertPermission()
                        }
                    }
                if networkAlertEnabled {
                    Picker("上传速率阈值", selection: $networkAlertThresholdMBps) {
                        Text("1 MB/s").tag(1.0)
                        Text("5 MB/s").tag(5.0)
                        Text("10 MB/s").tag(10.0)
                        Text("20 MB/s").tag(20.0)
                        Text("50 MB/s").tag(50.0)
                    }
                    .pickerStyle(.menu)
                }
                Button("清空网络记录", role: .destructive) {
                    showClearTrafficConfirmation = true
                }
            }

            Section("隐藏规则") {
                let projectCount = IgnoreRules.strings(from: ignoredProjectsRaw).count
                let portCount = IgnoreRules.ports(from: ignoredPortsRaw).count
                let appCount = IgnoreRules.strings(from: ignoredApplicationsRaw).count

                if projectCount + portCount + appCount == 0 {
                    Text("暂无隐藏项")
                        .foregroundStyle(.secondary)
                } else {
                    if projectCount > 0 {
                        Button("恢复隐藏的项目（\(projectCount)）") {
                            ignoredProjectsRaw = "[]"
                        }
                    }
                    if portCount > 0 {
                        Button("恢复隐藏的端口（\(portCount)）") {
                            ignoredPortsRaw = "[]"
                        }
                    }
                    if appCount > 0 {
                        Button("恢复隐藏的网络应用（\(appCount)）") {
                            ignoredApplicationsRaw = "[]"
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
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

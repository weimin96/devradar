import ServiceManagement
import SwiftUI

struct SettingsWindow {
    static func open(trafficMonitor: NetworkTrafficMonitor, localProxy: LocalProxyManager) {
        let windowRef = NSApp.windows.first { $0.title == "DevRadar 设置" }
        if let window = windowRef {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(trafficMonitor: trafficMonitor, localProxy: localProxy)
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
    var localProxy: LocalProxyManager
    @AppStorage("showAllPorts") private var showAll = false
    @AppStorage("showKillButton") private var showKill = true
    @AppStorage("showBrowserButton") private var showBrowser = true
    @AppStorage("showFinderButton") private var showFinder = true
    @AppStorage("showTerminalButton") private var showTerminal = true
    @AppStorage("networkAlertEnabled") private var networkAlertEnabled = true
    @AppStorage("networkAlertThresholdMBps") private var networkAlertThresholdMBps = 5.0
    @AppStorage("proxyDecryptHTTPS") private var proxyDecryptHTTPS = false
    @AppStorage("proxyBodyPreview") private var proxyBodyPreview = false
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

            Section("抓包") {
                Text("按 PID 抓包始终包含 TCP/UDP 443 等加密连接。只会在你手动抓包时请求管理员授权，不会解密 HTTPS 请求正文。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("原始数据包的 HTTPS 正文仍然加密；要解密请使用下方本地代理。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("本地代理 · 个人使用") {
                Toggle("代理 HTTPS 解密", isOn: $proxyDecryptHTTPS)
                Toggle("记录脱敏正文预览", isOn: $proxyBodyPreview)
                Text("仅对主动配置为使用 DevRadar 代理的应用生效。需要安装并手动信任本机 CA；开启选项不会自动修改系统代理。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("生成 / 定位 CA 证书（.cer）") { localProxy.prepareCA() }
                Button("打开钥匙串访问") { localProxy.openKeychainAccess() }
                Text("先在钥匙串访问中选中「登录（login）」，再拖入 .cer 文件。不要选「本地项目」或「iCloud」。导入后双击证书，在「信任」中按需设置 SSL 信任。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("复制终端导入命令（备用）") { localProxy.copyImportCommand() }
                Button("复制仅 SSL 信任命令（备用）") { localProxy.copyTrustCommand() }
                Text("上述操作必须由你亲自授权。只导入公共证书，不导入 .key 私钥；排查完成后建议撤销信任。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let error = localProxy.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .systemRed))
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

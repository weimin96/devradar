import Foundation
import SwiftUI

private enum RuntimeVisual {
    static func icon(for port: PortInfo) -> String {
        let runtime = port.runtimeName.lowercased()
        if port.containerID != nil || runtime.contains("docker") { return "shippingbox.fill" }
        if runtime.contains("spring") { return "leaf.fill" }
        if runtime.contains("java") { return "cup.and.saucer.fill" }
        if runtime.contains("vite") { return "bolt.fill" }
        if runtime.contains("next") || runtime.contains("nuxt") || runtime.contains("node") { return "hexagon.fill" }
        if runtime.contains("python") || runtime.contains("uvicorn") || runtime.contains("gunicorn") || runtime.contains("flask") { return "terminal.fill" }
        return "circle.fill"
    }
}

private enum GroupSortMode: String {
    case name
    case cpu
    case memory
    case uptime

    var title: String {
        switch self {
        case .name: return "名称"
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .uptime: return "运行时长"
        }
    }
}

private enum MonitorPanel {
    case ports
    case network
}

private struct ServiceGroup: Identifiable {
    let id: String
    let name: String
    let directory: String?
    let ports: [PortInfo]

    private var processes: [PortInfo] {
        var seen = Set<Int>()
        return ports.filter { seen.insert($0.pid).inserted }
    }

    var cpuPercent: Double? {
        let values = processes.compactMap(\.cpuPercent)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var memoryBytes: UInt64? {
        let values = processes.compactMap(\.memoryBytes)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var uptimeSeconds: Int? {
        processes.compactMap(\.uptimeSeconds).max()
    }

}

struct ContentView: View {
    var scanner: AppPortScanner
    var trafficMonitor: NetworkTrafficMonitor
    var packetCapture: PacketCaptureManager
    var localProxy: LocalProxyManager
    @Binding var showAll: Bool
    @State private var searchText = ""
    @State private var panel = MonitorPanel.ports
    @AppStorage("groupSortMode") private var groupSortModeRaw = GroupSortMode.name.rawValue
    @AppStorage(IgnoreRules.projectsKey) private var ignoredProjectsRaw = "[]"
    @AppStorage(IgnoreRules.portsKey) private var ignoredPortsRaw = "[]"

    private var visiblePorts: [PortInfo] {
        let ignoredProjects = IgnoreRules.strings(from: ignoredProjectsRaw)
        let ignoredPorts = IgnoreRules.ports(from: ignoredPortsRaw)
        let notIgnored = scanner.ports.filter { port in
            !ignoredPorts.contains(port.port)
                && !ignoredProjects.contains(port.projectDirectory ?? "")
        }
        if showAll {
            return notIgnored
        }
        return notIgnored.filter(\.isDevelopmentService)
    }

    private var filteredPorts: [PortInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visiblePorts }

        return visiblePorts.filter { port in
            let fields = [
                port.projectName,
                port.projectDirectory,
                port.directory,
                port.runtimeName,
                port.processName,
                port.serviceName,
                port.containerName,
                port.composeProject,
                port.composeService,
                port.command,
                String(port.port),
                String(port.pid),
            ]
            return fields.compactMap { $0?.lowercased() }.contains { $0.contains(query) }
        }
    }

    private var groups: [ServiceGroup] {
        let grouped = Dictionary(grouping: filteredPorts) { port in
            if let projectDirectory = port.projectDirectory {
                return projectDirectory
            }
            if let composeProject = port.composeProject {
                return "compose:\(composeProject)"
            }
            if let containerID = port.containerID {
                return "docker:\(containerID)"
            }
            return "pid:\(port.pid)"
        }

        let result = grouped.map { key, ports in
            let sortedPorts = ports.sorted { $0.port < $1.port }
            let first = sortedPorts[0]
            return ServiceGroup(
                id: key,
                name: first.projectName ?? first.processName,
                directory: first.projectDirectory ?? first.directory,
                ports: sortedPorts
            )
        }

        let mode = GroupSortMode(rawValue: groupSortModeRaw) ?? .name
        return result.sorted { lhs, rhs in
            let lhsHasProject = lhs.directory != nil
            let rhsHasProject = rhs.directory != nil
            if lhsHasProject != rhsHasProject {
                return lhsHasProject
            }

            switch mode {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .cpu:
                let l = lhs.cpuPercent ?? -1
                let r = rhs.cpuPercent ?? -1
                if l != r { return l > r }
            case .memory:
                let l = lhs.memoryBytes ?? 0
                let r = rhs.memoryBytes ?? 0
                if l != r { return l > r }
            case .uptime:
                let l = lhs.uptimeSeconds ?? 0
                let r = rhs.uptimeSeconds ?? 0
                if l != r { return l > r }
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var listHeight: CGFloat {
        let estimated = groups.reduce(CGFloat.zero) { partial, group in
            partial + 64 + CGFloat(group.ports.count) * 44
        }
        return min(max(estimated, 150), 500)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if panel == .ports {
                portMonitorContent
            } else {
                NetworkMonitorView(trafficMonitor: trafficMonitor, packetCapture: packetCapture, localProxy: localProxy)
            }

            Divider()

            HStack {
                Button {
                    panel = panel == .ports ? .network : .ports
                    searchText = ""
                } label: {
                    Image(systemName: panel == .ports ? "arrow.up.arrow.down" : "network")
                    Text(panel == .ports ? "网络监控" : "端口监控")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Divider()
                    .frame(height: 12)

                Button {
                    SettingsWindow.open(trafficMonitor: trafficMonitor, localProxy: localProxy)
                } label: {
                    Image(systemName: "gearshape")
                    Text("设置")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Button("退出") {
                    packetCapture.stop()
                    localProxy.stopForQuit { restored in
                        if restored {
                            NSApplication.shared.terminate(nil)
                        } else {
                            CaptureInspectorWindow.open(
                                mode: .proxy,
                                localProxy: localProxy,
                                packetCapture: packetCapture,
                                trafficMonitor: trafficMonitor
                            )
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            if localProxy.systemProxy.pendingRecovery {
                HStack(spacing: 8) {
                    Label("系统代理待恢复", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("恢复") {
                        localProxy.systemProxy.restore { _ in }
                    }
                    .buttonStyle(.borderless)
                    .disabled(localProxy.systemProxy.isPending)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 410)
        .onAppear {
            scanner.startScanning()
            trafficMonitor.start()
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { scanner.lastError != nil },
                set: { if !$0 { scanner.lastError = nil } }
            )
        ) {
            Button("确定", role: .cancel) {
                scanner.lastError = nil
            }
        } message: {
            Text(scanner.lastError ?? "未知错误")
        }
    }

    @ViewBuilder
    private var portMonitorContent: some View {
        HStack(spacing: 8) {
            Text("开发服务")
                .font(.headline)
            if !visiblePorts.isEmpty {
                Text("\(groups.count) 项目 · \(filteredPorts.count) 端口")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.7))
                    .clipShape(Capsule())
            }
            Spacer()
            Menu {
                Button {
                    showAll = false
                } label: {
                    if !showAll {
                        Label("仅开发服务", systemImage: "checkmark")
                    } else {
                        Text("仅开发服务")
                    }
                }
                Button {
                    showAll = true
                } label: {
                    if showAll {
                        Label("所有监听端口", systemImage: "checkmark")
                    } else {
                        Text("所有监听端口")
                    }
                }
                Divider()
                ForEach([GroupSortMode.name, .cpu, .memory, .uptime], id: \.rawValue) { mode in
                    Button {
                        groupSortModeRaw = mode.rawValue
                    } label: {
                        if groupSortModeRaw == mode.rawValue {
                            Label("按\(mode.title)排序", systemImage: "checkmark")
                        } else {
                            Text("按\(mode.title)排序")
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(Color.accentColor.opacity(0.72))
            }
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("显示与排序")

            if scanner.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .help("正在扫描")
            } else {
                Button {
                    scanner.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color.accentColor.opacity(0.72))
                }
                .buttonStyle(.borderless)
                .help("刷新")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

        if !visiblePorts.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("搜索项目、端口、PID 或命令", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        searchText.isEmpty ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.32),
                        lineWidth: 1
                    )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }

        Divider()

        if visiblePorts.isEmpty {
            Text(showAll ? "没有发现监听端口" : "没有正在运行的开发服务")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if filteredPorts.isEmpty {
            Text("没有匹配的进程")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groups) { group in
                        ServiceGroupView(group: group, scanner: scanner)
                        if group.id != groups.last?.id {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
            }
            .frame(height: listHeight)
        }
    }
}

private struct ServiceGroupView: View {
    let group: ServiceGroup
    var scanner: AppPortScanner
    @AppStorage("showBrowserButton") private var showBrowser = true
    @AppStorage("showFinderButton") private var showFinder = true
    @AppStorage("showTerminalButton") private var showTerminal = true
    @AppStorage(IgnoreRules.projectsKey) private var ignoredProjectsRaw = "[]"
    @State private var isHovered = false

    private var shortDirectory: String? {
        group.directory?.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var projectRuleDirectory: String? {
        group.ports.compactMap(\.projectDirectory).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(group.name)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)

                if group.ports.count > 1 {
                    Text("\(group.ports.count) 端口")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer(minLength: 8)

                if showBrowser, let port = scanner.preferredWebPort(for: group.ports) {
                    Button {
                        openBrowser(port: port)
                    } label: {
                        Image(systemName: "safari")
                            .foregroundStyle(Color.accentColor.opacity(0.78))
                    }
                    .help(scanner.isWebService(port: port)
                        ? "打开已识别的 Web 服务 localhost:\(port)"
                        : "在浏览器中打开 localhost:\(port)")
                }

                if let directory = group.directory {
                    if showTerminal {
                        Button {
                            openTerminal(at: directory)
                        } label: {
                            Image(systemName: "terminal")
                                .foregroundStyle(Color.accentColor.opacity(0.78))
                        }
                        .help("在终端中打开项目")
                    }

                    if showFinder {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
                        } label: {
                            Image(systemName: "folder")
                                .foregroundStyle(Color.accentColor.opacity(0.62))
                        }
                        .help("在 Finder 中打开项目")
                    }
                }
            }

            if let shortDirectory {
                Text(shortDirectory)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group.directory ?? shortDirectory)
            }

            HStack(spacing: 7) {
                if let cpu = group.cpuPercent {
                    MetricPill(
                        text: String(format: "%.1f%%", cpu),
                        systemImage: "cpu",
                        color: cpuColor(cpu)
                    )
                }
                if let memory = group.memoryBytes {
                    MetricPill(
                        text: formatBytes(memory),
                        systemImage: "memorychip",
                        color: memoryColor(memory)
                    )
                }
                if let uptime = group.uptimeSeconds {
                    MetricPill(
                        text: formatUptime(uptime),
                        systemImage: "clock",
                        color: .secondary
                    )
                }
            }

            VStack(spacing: 5) {
                ForEach(group.ports) { port in
                    ServiceRow(port: port, scanner: scanner)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(isHovered ? 0.035 : 0))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if let directory = projectRuleDirectory {
                Button("隐藏此项目") {
                    ignoredProjectsRaw = IgnoreRules.adding(directory, to: ignoredProjectsRaw)
                }
            }
        }
    }

    private func openBrowser(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openTerminal(at directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", directory]
        do {
            try process.run()
        } catch {
            scanner.lastError = "无法打开终端：\(error.localizedDescription)"
        }
    }

    private func cpuColor(_ value: Double) -> Color {
        if value >= 80 { return Color(nsColor: .systemRed) }
        if value >= 40 { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .systemGreen)
    }

    private func memoryColor(_ value: UInt64) -> Color {
        if value >= 2 * 1_024 * 1_024 * 1_024 { return Color(nsColor: .systemRed) }
        if value >= 1_024 * 1_024 * 1_024 { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .systemGreen)
    }
}

private struct MetricPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.07))
            .clipShape(Capsule())
    }
}

private struct ServiceRow: View {
    let port: PortInfo
    var scanner: AppPortScanner
    @AppStorage("showKillButton") private var showKill = true
    @AppStorage(IgnoreRules.projectsKey) private var ignoredProjectsRaw = "[]"
    @AppStorage(IgnoreRules.portsKey) private var ignoredPortsRaw = "[]"
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                if let url = URL(string: "http://localhost:\(port.port)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text(":\(port.port)")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.82))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("打开 http://localhost:\(port.port)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Label(port.runtimeName, systemImage: RuntimeVisual.icon(for: port))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let serviceName = port.serviceName,
                       serviceName.caseInsensitiveCompare(port.projectName ?? "") != .orderedSame {
                        Text(serviceName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    if port.processName.caseInsensitiveCompare(port.runtimeName) != .orderedSame {
                        Text(port.processName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if scanner.isWebService(port: port.port) {
                        Label("Web", systemImage: "globe")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor.opacity(0.72))
                    }
                    if port.pid > 0 {
                        Text("PID \(port.pid)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if let containerName = port.containerName {
                        Text(containerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let command = port.command {
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(commandHelp(command))
                }
            }

            Spacer(minLength: 4)

            if showKill {
                Button {
                    scanner.stop(port: port, mode: .terminate)
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(nsColor: .systemRed).opacity(isHovered ? 0.95 : 0.62))
                        .padding(3)
                        .background(Color(nsColor: .systemRed).opacity(isHovered ? 0.10 : 0))
                        .clipShape(Circle())
                }
                .help(port.containerID == nil ? "停止进程" : "停止容器")
            }

            Menu {
                if port.containerID != nil {
                    Button("停止容器") {
                        scanner.stop(port: port, mode: .terminate)
                    }
                    Button("强制停止容器", role: .destructive) {
                        scanner.stop(port: port, mode: .force)
                    }
                } else {
                    Button("停止") {
                        scanner.stop(port: port, mode: .terminate)
                    }
                    Button("停止进程树") {
                        scanner.stop(port: port, mode: .processTree)
                    }
                    Divider()
                    Button("强制停止", role: .destructive) {
                        scanner.stop(port: port, mode: .force)
                    }
                }
                Divider()
                Button("隐藏此端口") {
                    ignoredPortsRaw = IgnoreRules.adding(port: port.port, to: ignoredPortsRaw)
                }
                if let projectDirectory = port.projectDirectory {
                    Button("隐藏此项目") {
                        ignoredProjectsRaw = IgnoreRules.adding(projectDirectory, to: ignoredProjectsRaw)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(Color.primary.opacity(isHovered ? 0.03 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if port.containerID != nil {
                Button("停止容器") {
                    scanner.stop(port: port, mode: .terminate)
                }
                Button("强制停止容器", role: .destructive) {
                    scanner.stop(port: port, mode: .force)
                }
            } else {
                Button("停止") {
                    scanner.stop(port: port, mode: .terminate)
                }
                Button("停止进程树") {
                    scanner.stop(port: port, mode: .processTree)
                }
                Button("强制停止", role: .destructive) {
                    scanner.stop(port: port, mode: .force)
                }
            }
            Divider()
            Button("隐藏此端口") {
                ignoredPortsRaw = IgnoreRules.adding(port: port.port, to: ignoredPortsRaw)
            }
            if let projectDirectory = port.projectDirectory {
                Button("隐藏此项目") {
                    ignoredProjectsRaw = IgnoreRules.adding(projectDirectory, to: ignoredProjectsRaw)
                }
            }
        }
    }

    private func commandHelp(_ command: String) -> String {
        guard let executable = port.executable else { return command }
        return "\(command)\n可执行文件：\(executable)"
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

private func formatUptime(_ seconds: Int) -> String {
    if seconds < 60 {
        return "<1分"
    }
    if seconds < 3_600 {
        return "\(seconds / 60)分"
    }
    if seconds < 86_400 {
        return "\(seconds / 3_600)小时"
    }
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    return hours == 0 ? "\(days)天" : "\(days)天 \(hours)小时"
}

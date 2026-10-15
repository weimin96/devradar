import Foundation
import PScanKit
import SwiftUI

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
    @Binding var showAll: Bool
    @State private var searchText = ""

    private var visiblePorts: [PortInfo] {
        if showAll {
            return scanner.ports
        }
        return scanner.ports.filter { $0.projectDirectory != nil }
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
                port.command,
                String(port.port),
                String(port.pid),
            ]
            return fields.compactMap { $0?.lowercased() }.contains { $0.contains(query) }
        }
    }

    private var groups: [ServiceGroup] {
        let grouped = Dictionary(grouping: filteredPorts) { port in
            port.projectDirectory ?? "pid:\(port.pid)"
        }

        return grouped.map { key, ports in
            let sortedPorts = ports.sorted { $0.port < $1.port }
            let first = sortedPorts[0]
            return ServiceGroup(
                id: key,
                name: first.projectName ?? first.processName,
                directory: first.projectDirectory ?? first.directory,
                ports: sortedPorts
            )
        }
        .sorted { lhs, rhs in
            let lhsHasProject = lhs.directory != nil
            let rhsHasProject = rhs.directory != nil
            if lhsHasProject != rhsHasProject {
                return lhsHasProject
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
            HStack(spacing: 8) {
                Text("开发服务")
                    .font(.headline)
                if !visiblePorts.isEmpty {
                    Text("\(groups.count) 项目 · \(visiblePorts.count) 端口")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(showAll ? "当前显示所有监听端口" : "当前仅显示开发服务")

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
                .background(.quaternary.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 6))
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

            Divider()

            HStack {
                Button {
                    SettingsWindow.open()
                } label: {
                    Image(systemName: "gearshape")
                    Text("设置")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 410)
        .onAppear {
            scanner.startScanning()
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
}

private struct ServiceGroupView: View {
    let group: ServiceGroup
    var scanner: AppPortScanner
    @AppStorage("showFinderButton") private var showFinder = true
    @AppStorage("showTerminalButton") private var showTerminal = true

    private var shortDirectory: String? {
        group.directory?.replacingOccurrences(of: NSHomeDirectory(), with: "~")
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
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer(minLength: 8)

                if let directory = group.directory {
                    if showTerminal {
                        Button {
                            openTerminal(at: directory)
                        } label: {
                            Image(systemName: "terminal")
                        }
                        .help("在终端中打开项目")
                    }

                    if showFinder {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
                        } label: {
                            Image(systemName: "folder")
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

            HStack(spacing: 10) {
                if let cpu = group.cpuPercent {
                    Label(String(format: "%.1f%%", cpu), systemImage: "cpu")
                }
                if let memory = group.memoryBytes {
                    Label(formatBytes(memory), systemImage: "memorychip")
                }
                if let uptime = group.uptimeSeconds {
                    Label(formatUptime(uptime), systemImage: "clock")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            VStack(spacing: 5) {
                ForEach(group.ports) { port in
                    ServiceRow(port: port, scanner: scanner)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
}

private struct ServiceRow: View {
    let port: PortInfo
    var scanner: AppPortScanner
    @AppStorage("showKillButton") private var showKill = true

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                if let url = URL(string: "http://localhost:\(port.port)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text(":\(port.port)")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("打开 http://localhost:\(port.port)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(port.runtimeName)
                        .font(.caption)
                    if port.processName.caseInsensitiveCompare(port.runtimeName) != .orderedSame {
                        Text(port.processName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("PID \(port.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
                .help("停止进程")
            }

            Menu {
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
        .contentShape(Rectangle())
        .contextMenu {
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

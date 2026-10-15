import PScanKit
import SwiftUI

struct ContentView: View {
    var scanner: AppPortScanner
    @Binding var showAll: Bool

    private var visiblePorts: [PortInfo] {
        if showAll {
            return scanner.ports
        }
        return scanner.ports.filter { $0.projectDirectory != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("开发服务")
                    .font(.headline)
                if !visiblePorts.isEmpty {
                    Text("\(visiblePorts.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    scanner.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if visiblePorts.isEmpty {
                Text(showAll ? "没有发现监听端口" : "没有正在运行的开发服务")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visiblePorts) { port in
                            PortRow(port: port, scanner: scanner)
                            if port.id != visiblePorts.last?.id {
                                Divider()
                                    .padding(.leading, 12)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
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
        .frame(width: 380)
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

struct PortRow: View {
    let port: PortInfo
    var scanner: AppPortScanner
    @AppStorage("showKillButton") private var showKill = true
    @AppStorage("showFinderButton") private var showFinder = true
    @AppStorage("showTerminalButton") private var showTerminal = true

    private var projectDirectory: String? {
        port.projectDirectory ?? port.directory
    }

    private var shortDirectory: String? {
        projectDirectory?.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var displayName: String {
        port.projectName ?? port.processName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(displayName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                Text(":\(port.port)")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if showKill {
                    Button {
                        scanner.stop(port: port, mode: .terminate)
                    } label: {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
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

            Text("\(port.runtimeName) · PID \(port.pid) · \(port.processName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let shortDirectory {
                Text(shortDirectory)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(projectDirectory ?? shortDirectory)
            }

            if let command = port.command {
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(commandHelp(command))
            }

            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: "http://localhost:\(port.port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("浏览器", systemImage: "safari")
                }
                .help("打开 http://localhost:\(port.port)")

                if let directory = projectDirectory {
                    if showTerminal {
                        Button {
                            openTerminal(at: directory)
                        } label: {
                            Label("终端", systemImage: "terminal")
                        }
                        .help("在终端中打开项目")
                    }

                    if showFinder {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
                        } label: {
                            Label("Finder", systemImage: "folder")
                        }
                        .help("在 Finder 中打开项目")
                    }
                }
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    private func commandHelp(_ command: String) -> String {
        guard let executable = port.executable else { return command }
        return "\(command)\n可执行文件：\(executable)"
    }
}

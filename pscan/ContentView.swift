import SwiftUI

struct ContentView: View {
    var scanner: AppPortScanner
    @Binding var showAll: Bool

    private var visiblePorts: [PortInfo] {
        if showAll {
            return scanner.ports
        }
        return scanner.ports.filter { $0.directory != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Active Ports")
                    .font(.headline)
                Spacer()
                Button {
                    scanner.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if visiblePorts.isEmpty {
                Text(showAll ? "No active ports found" : "No dev servers running")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(visiblePorts) { port in
                            PortRow(port: port, scanner: scanner)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Footer
            HStack {
                Button {
                    SettingsWindow.open()
                } label: {
                    Image(systemName: "gearshape")
                    Text("Options")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
        .onAppear {
            scanner.startScanning()
        }
    }
}

struct PortRow: View {
    let port: PortInfo
    var scanner: AppPortScanner
    @State private var showKillConfirm = false
    @AppStorage("showKillButton") private var showKill = true
    @AppStorage("showFinderButton") private var showFinder = true
    @AppStorage("showTerminalButton") private var showTerminal = true

    var body: some View {
        HStack {
            Button {
                if let url = URL(string: "http://localhost:\(port.port)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(":\(String(port.port))")
                            .font(.system(.body, design: .monospaced, weight: .medium))
                        if let projectName = port.projectName {
                            Text(projectName)
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    if let dir = port.directory {
                        let shortDir = dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                        Text("\(port.processName) · \(shortDir)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(port.processName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if let dir = port.directory {
                if showTerminal {
                    Button {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        process.arguments = ["-a", "Terminal", dir]
                        try? process.run()
                    } label: {
                        Image(systemName: "terminal")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("Open in Terminal")
                }

                if showFinder {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                    } label: {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("Open in Finder")
                }
            }

            if showKill {
                Button {
                    showKillConfirm = true
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Kill process")
                .alert("Kill :\(String(port.port))?", isPresented: $showKillConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Kill", role: .destructive) {
                        scanner.kill(port: port)
                    }
                } message: {
                    Text("\(port.processName) (PID: \(String(port.pid))) will be terminated.")
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

import AppKit
import SwiftUI

enum AutomaticHTTPSEvidenceWindow {
    static func open(trafficMonitor: NetworkTrafficMonitor) {
        if let window = NSApp.windows.first(where: { $0.title == "DevRadar · 自动 HTTPS 证据" }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "DevRadar · 自动 HTTPS 证据"
        window.contentView = NSHostingView(rootView: AutomaticHTTPSEvidenceView(trafficMonitor: trafficMonitor))
        window.minSize = NSSize(width: 710, height: 470)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AutomaticHTTPSEvidenceView: View {
    var trafficMonitor: NetworkTrafficMonitor
    @State private var exportError: String?

    private var manager: AutomaticHTTPSEvidenceManager { trafficMonitor.automaticHTTPSEvidence }

    private func matchedEvent(for record: AutomaticHTTPSRecord) -> CombinedUploadEvidence {
        let incidents = trafficMonitor.uploadAnalysis[record.applicationID]?.incidents ?? []
        return CombinedUploadEvidenceMatcher.combine(
            applicationID: record.applicationID,
            incidents: incidents,
            automaticRecords: manager.records
        ).first { $0.automatic?.id == record.id }
            ?? CombinedUploadEvidence(incident: nil, automatic: record)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("异常上传 · 自动 HTTPS 连接证据", systemImage: "lock.shield")
                    .font(.title3.weight(.semibold))
                Spacer()
                if !manager.activeApps.isEmpty {
                    Label("正在监控 \(manager.activeApps.count) 个应用", systemImage: "waveform.path")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text("上传突增或连续超阈值时自动开始约 30 秒的进程级 TCP/UDP 443 计数。仅保留本机连接元数据，无 HTTPS 解密、请求正文、管理员权限或代理切换。监控启动前的字节无法追溯。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = manager.lastError ?? exportError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            if manager.records.isEmpty {
                ContentUnavailableView(
                    "暂无自动记录",
                    systemImage: "waveform.path.ecg",
                    description: Text("检测到符合条件的上传异常后，将自动记录选中进程的 HTTPS 候选连接。")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(manager.records) { record in
                            recordCard(record)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 710, minHeight: 470)
    }

    private func recordCard(_ record: AutomaticHTTPSRecord) -> some View {
        let linked = matchedEvent(for: record)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                CombinedUploadEvidenceDetailView(evidence: linked)
                HStack {
                    Button("导出完整诊断 JSON") { export(record, linked: linked) }
                    Button("删除记录", role: .destructive) { manager.deleteRecord(record) }
                    Spacer()
                }
                .controlSize(.small)
            }
            .padding(.vertical, 10)
        } label: {
            HStack(spacing: 10) {
                Text(record.applicationName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(record.triggeredAt, style: .date)
                Text(record.triggeredAt, style: .time)
                Spacer()
                Text(record.status == "completed" ? "已记录" : record.status)
                    .foregroundStyle(.secondary)
                Text("↑ " + bytes(record.uploadedBytes))
                    .font(.caption.monospacedDigit())
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func export(_ record: AutomaticHTTPSRecord, linked: CombinedUploadEvidence) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DevRadar-Auto-HTTPS-\(record.id.uuidString.prefix(8)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try UploadEvidenceReport.encode(
                applicationID: record.applicationID,
                applicationName: record.applicationName,
                incidents: linked.incident.map { [$0] } ?? [],
                automaticRecords: [record]
            )
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            exportError = nil
        } catch {
            exportError = "导出失败：\(error.localizedDescription)"
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

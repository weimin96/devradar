import Charts
import SwiftUI

/// Shared event detail for live incident analysis and historical auto records.
/// Data sources keep their own timestamps and must never be summed together.
struct CombinedUploadEvidenceDetailView: View {
    let evidence: CombinedUploadEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if evidence.isTimeLinked {
                Label("已按应用 ID、PID 和触发时间关联两份证据；仅代表时间相关", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if evidence.incident != nil {
                Label("只有应用速率突增证据，未匹配到自动 HTTPS 连接记录", systemImage: "waveform.path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("自动连接监测独立触发，未匹配到瞬时突增时间线", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let incident = evidence.incident {
                Text("应用上传速率 · 触发前约 16 秒、后约 20 秒")
                    .font(.caption.weight(.semibold))
                if !incident.samples.isEmpty {
                    Chart {
                        ForEach(incident.samples) { sample in
                            LineMark(
                                x: .value("时间", sample.date),
                                y: .value("上传 KB/s", Double(sample.uploadBytesPerSecond) / 1024)
                            ).foregroundStyle(.orange)
                        }
                        RuleMark(x: .value("突增", incident.triggeredAt))
                            .lineStyle(StrokeStyle(dash: [4, 4]))
                            .foregroundStyle(.red)
                    }
                    .frame(height: 130)
                }
                HStack(spacing: 12) {
                    Text("触发时 PID：\(incident.observedPIDs.map(String.init).joined(separator: ", "))")
                    Spacer()
                    Text(incident.isComplete ? "速率采样已完成" : "速率采样中")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text("连接快照 · 无逐目的地字节数")
                    .font(.caption.weight(.semibold))
                if incident.connections.isEmpty {
                    Text("事件窗口没有可用连接快照")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(incident.connections, id: \.capturedAt) { snapshot in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.capturedAt, style: .time)
                                .font(.caption.weight(.medium))
                            if snapshot.endpoints.isEmpty {
                                Text("已检查，未发现非本机连接")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(snapshot.endpoints.prefix(6)), id: \.self) { endpoint in
                                    Text("\(endpoint.transport) · \(endpoint.address)")
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                }
                                if snapshot.endpoints.count > 6 {
                                    Text("其他 \(snapshot.endpoints.count - 6) 条快照连接详见 JSON")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("应用速率时间线不可用：可能由连续超阈值触发，也可能已重启或过了内存保留时间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let automatic = evidence.automatic {
                Divider()
                HStack {
                    Text("自动 TCP/UDP 443 计数")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(automatic.status == "completed" ? "已完成" : automatic.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("监控开始：\(automatic.monitorStartedAt.formatted(date: .abbreviated, time: .standard))；结束：\(automatic.monitorFinishedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("监控后上传：\(bytes(automatic.uploadedBytes))")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Text("已识别 \(automatic.latestFlows.count) 条连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if automatic.latestFlows.isEmpty {
                    Text("这段采样没有捕获到 443 连接；不代表应用没有其他联网行为。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(automatic.latestFlows.prefix(20))) { flow in
                        HStack(spacing: 8) {
                            Text(flow.remoteAddress)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            Text("PID \(flow.pid)")
                                .foregroundStyle(.secondary)
                            Text("↑ \(bytes(flow.uploadedBytes))")
                                .monospacedDigit()
                            Text("↓ \(bytes(flow.downloadedBytes))")
                                .monospacedDigit()
                        }
                        .font(.caption2)
                    }
                    if automatic.latestFlows.count > 20 {
                        Text("另有 \(automatic.latestFlows.count - 20) 条连接详见 JSON")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("仅统计监控开始后的 socket 字节增量；不能将应用峰值流量分配给任一 IP，不能判断 HTTPS 加密正文。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

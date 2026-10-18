import AppKit
import Charts
import SwiftUI

/// Two data scopes share a window but MUST NOT share their attribution:
/// nettop is grouped by application ID; HTTP proxy records are unverified.
struct CaptureAnalyticsView: View {
    let mode: CaptureInspectorMode
    var trafficMonitor: NetworkTrafficMonitor
    var packetCapture: PacketCaptureManager
    var localProxy: LocalProxyManager
    @State private var exportError: String?

    private var app: ApplicationTraffic? {
        trafficMonitor.applications.first { $0.id == packetCapture.selectedApplicationID }
    }

    private var appAnalysis: TrafficAnalysisBuffer {
        trafficMonitor.uploadAnalysis[packetCapture.selectedApplicationID] ?? TrafficAnalysisBuffer()
    }

    private var combinedIncidents: [CombinedUploadEvidence] {
        CombinedUploadEvidenceMatcher.combine(
            applicationID: packetCapture.selectedApplicationID,
            incidents: appAnalysis.incidents,
            automaticRecords: trafficMonitor.automaticHTTPSEvidence.records
        )
    }

    private var completedRequests: [LocalProxyEvent] {
        localProxy.events.filter { $0.type == "request" }
    }

    private var destinationRows: [ProxyDestinationRow] {
        ProxyDestinationRanking.rank(completedRequests.compactMap { event in
            guard let host = event.host else { return nil }
            return ProxyUploadRecord(host: host, uploadBytes: event.uploadBytes ?? 0)
        })
    }

    private var largestRequests: [LocalProxyEvent] {
        completedRequests.filter { ($0.uploadBytes ?? 0) > 0 }
            .sorted { ($0.uploadBytes ?? 0) > ($1.uploadBytes ?? 0) }
            .prefix(5).map { $0 }
    }

    private var proxyUploadBuckets: [ProxyUploadBucket] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let samples = completedRequests.compactMap { event -> ProxyUploadSample? in
            guard let timestamp = event.timestamp,
                  let date = formatter.date(from: timestamp) else { return nil }
            return ProxyUploadSample(date: date, uploadBytes: event.uploadBytes ?? 0)
        }
        return Array(ProxyUploadTimeline.buckets(samples).suffix(24))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("上传诊断概览")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text(mode == .proxy ? "本次代理会话" : "本机监控 · 最近 30 分钟事件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if mode == .proxy {
                    proxySummary
                } else {
                    applicationSummary
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var applicationSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("按应用进程归集的 nettop 速率；不是 HTTP 请求正文，也不能据此判断数据内容", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            httpsConnectionSection
            HStack(spacing: 12) {
                statistic("当前上传", networkRate(appAnalysis.currentUploadBytesPerSecond), symbol: "arrow.up")
                statistic("窗口峰值", networkRate(appAnalysis.peakUploadBytesPerSecond), symbol: "chart.line.uptrend.xyaxis")
                statistic("突增记录", "\(appAnalysis.spikes.count) 次", symbol: "waveform.path.ecg")
            }
            section("最近 5 分钟 · 上传速率") {
                if appAnalysis.samples.isEmpty {
                    unavailable("等待应用网络采样…")
                } else {
                    Chart {
                        ForEach(appAnalysis.samples) { point in
                            AreaMark(
                                x: .value("时间", point.date),
                                y: .value("上传 KB/s", Double(point.uploadBytesPerSecond) / 1024)
                            )
                            .foregroundStyle(.orange.opacity(0.16))
                            LineMark(
                                x: .value("时间", point.date),
                                y: .value("上传 KB/s", Double(point.uploadBytesPerSecond) / 1024)
                            )
                            .foregroundStyle(.orange)
                        }
                        ForEach(appAnalysis.spikes) { spike in
                            RuleMark(x: .value("突增时间", spike.date))
                                .foregroundStyle(.red.opacity(0.55))
                                .lineStyle(StrokeStyle(dash: [3, 3]))
                        }
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    .chartYAxisLabel("KB/s")
                    .frame(height: 160)
                }
                Text("突增判定：至少 4 个历史样本后，上行速率达到 1 MB/s 且超过近期基线 4 倍。持续高上传不重复触发。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !appAnalysis.spikes.isEmpty {
                section("最近突增") {
                    ForEach(appAnalysis.spikes.suffix(5).reversed()) { spike in
                        HStack {
                            Text(spike.date, style: .time)
                            Spacer()
                            Text(networkRate(spike.bytesPerSecond))
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
            incidentSection
            section("当前连接目标（快照，不代表上传量排名）") {
                let endpoints = (app?.remoteEndpoints ?? [])
                    .filter { !$0.isLocal }
                if endpoints.isEmpty {
                    unavailable("当前没有可识别的非本机连接。")
                } else {
                    ForEach(Array(endpoints.prefix(10)), id: \.id) { endpoint in
                        HStack(spacing: 8) {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                            Text(endpoint.address)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text(endpoint.transport)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("端点来自当前连接快照；未获得逐 IP/域名传输字节数，不能将上述上传速率分配给这些地址。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var httpsConnectionSection: some View {
        section("原应用 HTTPS / QUIC 连接 · 自动监控") {
            HStack {
                Text("TCP/UDP 443")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("导出连接证据 JSON") { exportHTTPSConnections() }
                    .font(.caption)
                    .disabled(packetCapture.httpsConnections.isEmpty)
            }
            HStack(spacing: 12) {
                statistic(
                    "监测到的 443 连接",
                    "\(packetCapture.httpsConnections.count)",
                    symbol: "lock.shield"
                )
                statistic(
                    "监测开始后上传",
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: packetCapture.httpsConnections.reduce(UInt64(0)) {
                            $0 &+ $1.uploadedBytes
                        }), countStyle: .file
                    ),
                    symbol: "arrow.up"
                )
            }
            Label("针对原应用 PID 的逐 socket 计数，无须代理或重启应用，也不读取 HTTPS 正文。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = packetCapture.httpsMonitoringError {
                Text("连接监控错误：\(error)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if packetCapture.httpsConnections.isEmpty {
                unavailable("等待该应用的 TCP/UDP 443 连接及新数据。没有连接时上传量为零。")
            } else {
                ForEach(Array(packetCapture.httpsConnections.prefix(15))) { connection in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(connection.remoteAddress)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: connection.uploadedBytes),
                                countStyle: .file
                            ))
                            .font(.caption.monospacedDigit())
                        }
                        HStack(spacing: 8) {
                            Text("PID \(connection.pid)")
                            Text(connection.protocolLabel)
                            Spacer()
                            Text("↓ " + ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: connection.downloadedBytes),
                                countStyle: .file
                            ))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
            Text("按 nettop 连接累计计数差值得出，仅统计开始监控后的字节；既有连接之前传输的数据不计入。443 端口只表示可能是 HTTPS/TLS 或 QUIC，无法证明应用层协议，也无法还原加密上传内容。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func exportHTTPSConnections() {
        guard !packetCapture.httpsConnections.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DevRadar-HTTPS-Connections.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bytes = try HTTPSConnectionReport.encode(
                applicationName: packetCapture.applicationName,
                connections: packetCapture.httpsConnections
            )
            try bytes.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
            exportError = nil
        } catch {
            exportError = "导出 HTTPS 连接证据失败：\(error.localizedDescription)"
        }
    }

    private var incidentSection: some View {
        section("异常事件时间线 · 自动 HTTPS 连接证据") {
            HStack {
                Text("应用速率存内存 30 分钟；自动连接记录保存最多 7 天")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("导出完整诊断 JSON") { exportApplicationEvidence() }
                    .font(.caption)
                    .disabled(combinedIncidents.isEmpty)
            }
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if combinedIncidents.isEmpty {
                unavailable("暂无突增或自动 HTTPS 连接记录。连续超阈值也可能触发自动记录。")
            } else {
                ForEach(combinedIncidents) { evidence in
                    DisclosureGroup {
                        CombinedUploadEvidenceDetailView(evidence: evidence)
                    } label: {
                        HStack(spacing: 8) {
                            Text(evidence.triggeredAt, style: .date)
                            Text(evidence.triggeredAt, style: .time)
                            Spacer()
                            if let incident = evidence.incident {
                                Text(networkRate(incident.peakUploadBytesPerSecond))
                                .monospacedDigit()
                            }
                            Text(evidence.isTimeLinked ? "速率 + 443 连接" :
                                 evidence.incident != nil ? "仅速率" : "仅自动连接")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            Text("仅在应用 ID、PID 与触发时间相符时合并；未匹配事件独立显示。报告不包含正文、HTTP URL 或代理解密内容。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func exportApplicationEvidence() {
        guard !combinedIncidents.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DevRadar-Upload-Evidence.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bytes = try UploadEvidenceReport.encode(
                applicationID: packetCapture.selectedApplicationID,
                applicationName: packetCapture.applicationName,
                incidents: appAnalysis.incidents,
                automaticRecords: trafficMonitor.automaticHTTPSEvidence.records
            )
            try bytes.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
            exportError = nil
        } catch {
            exportError = "导出报告失败：\(error.localizedDescription)"
        }
    }

    private var proxySummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("系统代理 · 请求来源未识别。域名统计包含所有经过该代理的应用，不能作为所选应用的证据。", systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.orange)
            HStack(spacing: 12) {
                statistic("已完成请求", "\(completedRequests.count)", symbol: "checkmark.circle")
                statistic("累计上传", ByteCountFormatter.string(fromByteCount: localProxy.uploadedBytes, countStyle: .file), symbol: "arrow.up")
                statistic("活跃域名", "\(destinationRows.count)", symbol: "globe")
            }
            section("代理请求上传趋势 · 15 秒窗口") {
                if proxyUploadBuckets.isEmpty {
                    unavailable("等待完成的 HTTP 请求…")
                } else {
                    Chart(proxyUploadBuckets) { point in
                        BarMark(
                            x: .value("时间", point.date),
                            y: .value("上传 KB", Double(point.uploadBytes) / 1024)
                        )
                        .foregroundStyle(.orange.opacity(0.8))
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    .chartYAxisLabel("KB / 15s")
                    .frame(height: 132)
                }
                Text("按请求完成时间归集。长连接、进行中的请求及部分透传字节不会出现在图表中。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            section("上传目的地 · 已保留请求") {
                if destinationRows.isEmpty {
                    unavailable("尚无已完成的 HTTP 请求。")
                } else {
                    ForEach(Array(destinationRows.prefix(10))) { item in
                        HStack(spacing: 8) {
                            Text(item.host)
                                .font(.caption)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Spacer()
                            Text("\(item.requestCount) 次")
                                .foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: item.uploadBytes, countStyle: .file))
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                Text("依据代理记录的请求正文读取字节统计；未包含直连流量、WebSocket 透传字节或被截断的旧记录。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            section("最大上传请求 · 已保留记录") {
                if largestRequests.isEmpty {
                    unavailable("暂无已完成的上传请求。")
                } else {
                    ForEach(largestRequests) { event in
                        HStack {
                            Text(event.method ?? "—")
                                .frame(width: 44, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(event.host ?? "—")
                                .lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: event.uploadBytes ?? 0, countStyle: .file))
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                Text("用于定位系统代理中的大请求，不代表某个指定应用上传。点击左侧请求可以查看详细信息。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statistic(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .minimumScaleFactor(0.75)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func section<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(name).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func unavailable(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
    }

    private func networkRate(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + "/s"
    }
}

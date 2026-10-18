import Charts
import SwiftUI

/// Two data scopes share a window but MUST NOT share their attribution:
/// nettop is grouped by application ID; HTTP proxy records are unverified.
struct CaptureAnalyticsView: View {
    let mode: CaptureInspectorMode
    var trafficMonitor: NetworkTrafficMonitor
    var packetCapture: PacketCaptureManager
    var localProxy: LocalProxyManager

    private var app: ApplicationTraffic? {
        trafficMonitor.applications.first { $0.id == packetCapture.selectedApplicationID }
    }

    private var appAnalysis: TrafficAnalysisBuffer {
        trafficMonitor.uploadAnalysis[packetCapture.selectedApplicationID] ?? TrafficAnalysisBuffer()
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
                    Text("本次内存会话")
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

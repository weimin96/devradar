import SwiftUI

private enum NetworkTimeRange: String, CaseIterable {
    case realtime
    case oneDay
    case threeDays
    case sevenDays

    var title: String {
        switch self {
        case .realtime: return "实时"
        case .oneDay: return "1天"
        case .threeDays: return "3天"
        case .sevenDays: return "7天"
        }
    }
}

private enum NetworkSortField {
    case download
    case upload
}

private func beginProxyCapture(
    _ application: ApplicationTraffic,
    localProxy: LocalProxyManager,
    packetCapture: PacketCaptureManager,
    trafficMonitor: NetworkTrafficMonitor
) {
    localProxy.start(application: application)
    CaptureInspectorWindow.open(
        mode: .proxy, localProxy: localProxy, packetCapture: packetCapture,
        trafficMonitor: trafficMonitor
    )
}

private func beginPacketCapture(
    _ application: ApplicationTraffic,
    localProxy: LocalProxyManager,
    packetCapture: PacketCaptureManager,
    trafficMonitor: NetworkTrafficMonitor
) {
    packetCapture.prepare(application: application)
    CaptureInspectorWindow.open(
        mode: .packets, localProxy: localProxy, packetCapture: packetCapture,
        trafficMonitor: trafficMonitor
    )
}

struct NetworkMonitorView: View {
    var trafficMonitor: NetworkTrafficMonitor
    var packetCapture: PacketCaptureManager
    var localProxy: LocalProxyManager
    @State private var searchText = ""
    @State private var timeRange = NetworkTimeRange.realtime
    @State private var sortField = NetworkSortField.upload
    @State private var sortAscending = false
    // Live byte rates change every two seconds. Keep the application's visual
    // position fixed so the action menu cannot move away while being clicked.
    @State private var stableApplicationOrder: [String] = []
    @AppStorage(IgnoreRules.networkApplicationsKey) private var ignoredApplicationsRaw = "[]"

    private var realtimeApplications: [ApplicationTraffic] {
        let ignored = IgnoreRules.strings(from: ignoredApplicationsRaw)
        return trafficMonitor.applications.filter { !ignored.contains($0.id) }
    }

    private var visibleApplications: [ApplicationTraffic] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = query.isEmpty ? realtimeApplications : realtimeApplications.filter { app in
            let fields: [String?] = [
                app.name,
                app.bundleIdentifier,
                app.bundlePath,
                app.launchSourceName,
                app.processNames.joined(separator: " "),
                app.pids.map(String.init).joined(separator: " "),
                app.projectDirectories.joined(separator: " "),
                app.workingDirectories.joined(separator: " "),
                app.remoteEndpoints.map(\.address).joined(separator: " "),
            ]
            return fields.compactMap { $0?.lowercased() }.contains { $0.contains(query) }
        }

        let ranks = Dictionary(uniqueKeysWithValues: stableApplicationOrder.enumerated().map { ($0.element, $0.offset) })
        return matching.sorted { lhs, rhs in
            let leftRank = ranks[lhs.id] ?? Int.max
            let rightRank = ranks[rhs.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var historicalApplications: [HistoricalApplicationTraffic] {
        let ignored = IgnoreRules.strings(from: ignoredApplicationsRaw)
        let applications: [HistoricalApplicationTraffic]
        switch timeRange {
        case .realtime:
            applications = []
        case .oneDay:
            applications = trafficMonitor.history1DayApplications
        case .threeDays:
            applications = trafficMonitor.history3DayApplications
        case .sevenDays:
            applications = trafficMonitor.history7DayApplications
        }
        return applications.filter { !ignored.contains($0.id) }
    }

    private var visibleHistoricalApplications: [HistoricalApplicationTraffic] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = query.isEmpty ? historicalApplications : historicalApplications.filter { app in
            [app.name, app.bundleIdentifier, app.bundlePath, app.launchSourceName]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }


        return matching.sorted { lhs, rhs in
            let left = historicalSortValue(lhs)
            let right = historicalSortValue(rhs)
            if left != right {
                return sortAscending ? left < right : left > right
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var historicalTotals: TrafficTotals {
        switch timeRange {
        case .realtime: return .zero
        case .oneDay: return trafficMonitor.history1DayTotals
        case .threeDays: return trafficMonitor.history3DayTotals
        case .sevenDays: return trafficMonitor.history7DayTotals
        }
    }

    private var displayedApplicationCount: Int {
        timeRange == .realtime ? realtimeApplications.count : historicalApplications.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            applicationList
            if packetCapture.state != .idle {
                Divider()
                captureSession
            }
            if localProxy.state != .idle {
                Divider()
                proxySession
            }
        }
        .onAppear {
            trafficMonitor.start()
            trafficMonitor.setConnectionInspectionEnabled(true)
            updateStableOrder()
        }
        .onChange(of: Set(realtimeApplications.map(\.id))) { _, _ in
            updateStableOrder()
        }
        .onDisappear {
            trafficMonitor.setConnectionInspectionEnabled(false)
        }
    }

    private var captureSession: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("抓包 · \(packetCapture.applicationName)", systemImage: "waveform.path")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(packetCapture.state == .capturing ? "捕获中" :
                     packetCapture.state == .authorizing ? "等待授权" :
                     packetCapture.state == .starting ? "启动中" :
                     packetCapture.state == .ready ? "等待开始" :
                     packetCapture.state == .stopping ? "正在结束" :
                     packetCapture.state == .completed ? "已结束" :
                     packetCapture.state == .failed ? "失败" : "未启动")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if packetCapture.state == .capturing {
                    Button("停止") { packetCapture.stop() }
                        .buttonStyle(.borderless)
                }
                if packetCapture.state == .ready || packetCapture.state == .failed {
                    Button("开始抓包") {
                        CaptureInspectorWindow.open(
                            mode: .packets, localProxy: localProxy, packetCapture: packetCapture,
                            trafficMonitor: trafficMonitor
                        )
                    }
                    .buttonStyle(.borderless)
                }
                if packetCapture.state == .completed {
                    Button("导出 PCAPNG") { packetCapture.saveCapture() }
                        .buttonStyle(.borderless)
                }
                if packetCapture.state == .completed || packetCapture.state == .failed {
                    Button("清除") { packetCapture.clear() }
                        .buttonStyle(.borderless)
                }
                Button("查看详情") {
                    CaptureInspectorWindow.open(
                        mode: .packets, localProxy: localProxy, packetCapture: packetCapture,
                        trafficMonitor: trafficMonitor
                    )
                }
                .buttonStyle(.borderless)
            }
            Text("已收到 \(packetCapture.packetCount) 条记录 · 不包含 HTTPS 明文")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = packetCapture.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .textSelection(.enabled)
            }
        }
        .padding(10)
    }

    private var proxySession: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("系统代理 · 来源未识别", systemImage: "network.badge.shield.half.filled")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if localProxy.isBusy {
                    Button("停止") { localProxy.stop() }
                        .buttonStyle(.borderless)
                } else {
                    Button("清除") { localProxy.clear() }
                        .buttonStyle(.borderless)
                }
                Button("查看详情") {
                    CaptureInspectorWindow.open(
                        mode: .proxy, localProxy: localProxy, packetCapture: packetCapture,
                        trafficMonitor: trafficMonitor
                    )
                }
                .buttonStyle(.borderless)
            }
            if localProxy.isListening {
                HStack {
                    Text("代理：\(localProxy.proxyAddress)")
                        .font(.caption2.monospaced())
                    Spacer()
                    Button("复制代理环境变量") { localProxy.copyProxyEnvironment() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
                Text("需要让目标应用主动使用该代理，已有连接不会自动改道。任意配置相同地址的应用都能进入此会话。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(localProxy.state == .starting ? "正在启动本机代理…" : "代理已停止")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("\(localProxy.requestCount) 个 HTTP 请求")
                Spacer()
                Text("上传 \(ByteCountFormatter.string(fromByteCount: localProxy.uploadedBytes, countStyle: .file))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            if let error = localProxy.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
        }
        .padding(10)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Text("网络监控")
                        .font(.headline)
                    if displayedApplicationCount > 0 {
                        Text("\(displayedApplicationCount) 应用")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.7))
                            .clipShape(Capsule())
                    }
                }

                Spacer()

                if timeRange == .realtime {
                    sortableMetricBadge(
                        field: .download,
                        title: "下载",
                        value: formatNetworkRate(trafficMonitor.totalDownloadBytesPerSecond),
                        symbol: "arrow.down",
                        tint: .secondary
                    )
                    sortableMetricBadge(
                        field: .upload,
                        title: "上传",
                        value: formatNetworkRate(trafficMonitor.totalUploadBytesPerSecond),
                        symbol: "arrow.up",
                        tint: Color(nsColor: .systemOrange)
                    )
                } else {
                    sortableMetricBadge(
                        field: .download,
                        title: "下载",
                        value: formatNetworkBytes(historicalTotals.downloadedBytes),
                        symbol: "arrow.down",
                        tint: .secondary
                    )
                    sortableMetricBadge(
                        field: .upload,
                        title: "上传",
                        value: formatNetworkBytes(historicalTotals.uploadedBytes),
                        symbol: "arrow.up",
                        tint: Color(nsColor: .systemOrange)
                    )
                }
            }

            Picker("时间范围", selection: $timeRange) {
                ForEach(NetworkTimeRange.allCases, id: \.rawValue) { range in
                    Text(range.title).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("搜索应用、PID、地址或项目", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(12)
    }

    private func realtimeSortValue(_ application: ApplicationTraffic) -> UInt64 {
        switch sortField {
        case .download:
            return UInt64(max(0, application.downloadBytesPerSecond))
        case .upload:
            return UInt64(max(0, application.uploadBytesPerSecond))
        }
    }

    private func updateStableOrder(forceSort: Bool = false) {
        let current = realtimeApplications
        let ids = Set(current.map(\.id))
        if forceSort || stableApplicationOrder.isEmpty {
            stableApplicationOrder = current.sorted { lhs, rhs in
                let left = realtimeSortValue(lhs)
                let right = realtimeSortValue(rhs)
                if left != right { return sortAscending ? left < right : left > right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }.map(\.id)
            return
        }
        let retained = stableApplicationOrder.filter { ids.contains($0) }
        let oldIDs = Set(retained)
        let newcomers = current.filter { !oldIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.id)
        let next = retained + newcomers
        if next != stableApplicationOrder { stableApplicationOrder = next }
    }

    private func historicalSortValue(_ application: HistoricalApplicationTraffic) -> UInt64 {
        switch sortField {
        case .download:
            return application.totals.downloadedBytes
        case .upload:
            return application.totals.uploadedBytes
        }
    }

    @ViewBuilder
    private func sortableMetricBadge(
        field: NetworkSortField,
        title: String,
        value: String,
        symbol: String,
        tint: Color
    ) -> some View {
        Button {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = false
            }
            if timeRange == .realtime { updateStableOrder(forceSort: true) }
        } label: {
            MetricBadge(
                title: title,
                value: value,
                symbol: symbol,
                tint: tint,
                isActive: sortField == field,
                sortAscending: sortAscending
            )
        }
        .buttonStyle(.plain)
        .help(sortField == field
            ? "按\(title)\(sortAscending ? "升序" : "降序")排列，点击切换"
            : "按\(title)降序排列")
    }

    @ViewBuilder
    private var applicationList: some View {
        if timeRange != .realtime {
            historicalApplicationList
        } else if !trafficMonitor.isRunning, let error = trafficMonitor.lastError {
            Text(error)
                .foregroundStyle(Color(nsColor: .systemRed))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if realtimeApplications.isEmpty {
            Text(trafficMonitor.applications.isEmpty ? "当前没有检测到网络活动" : "网络应用已全部隐藏")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if visibleApplications.isEmpty {
            Text("没有匹配的应用")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleApplications) { app in
                        ApplicationTrafficRow(
                            application: app,
                            processes: trafficMonitor.processes.filter { app.pids.contains($0.pid) },
                            trafficMonitor: trafficMonitor,
                            packetCapture: packetCapture,
                            localProxy: localProxy
                        )
                        if app.id != visibleApplications.last?.id {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
            .frame(height: min(max(CGFloat(visibleApplications.count) * 76, 180),
                               localProxy.isBusy || packetCapture.isBusy ? 260 : 500))
        }
    }

    @ViewBuilder
    private var historicalApplicationList: some View {
        if historicalApplications.isEmpty {
            VStack(spacing: 5) {
                Text("这个时间范围还没有历史流量")
                    .foregroundStyle(.secondary)
                Text("历史统计从新版 DevRadar 启动后开始累计")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if visibleHistoricalApplications.isEmpty {
            Text("没有匹配的应用")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleHistoricalApplications) { app in
                        HistoricalApplicationTrafficRow(
                            application: app,
                            liveApplication: trafficMonitor.applications.first { $0.id == app.id },
                            packetCapture: packetCapture,
                            localProxy: localProxy,
                            trafficMonitor: trafficMonitor
                        )
                        if app.id != visibleHistoricalApplications.last?.id {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
            .frame(height: min(max(CGFloat(visibleHistoricalApplications.count) * 62, 180), 500))
        }
    }
}

private struct HistoricalApplicationTrafficRow: View {
    let application: HistoricalApplicationTraffic
    let liveApplication: ApplicationTraffic?
    var packetCapture: PacketCaptureManager
    var localProxy: LocalProxyManager
    var trafficMonitor: NetworkTrafficMonitor
    @AppStorage(IgnoreRules.networkApplicationsKey) private var ignoredApplicationsRaw = "[]"

    private var icon: NSImage {
        guard let bundlePath = application.bundlePath else {
            return NSWorkspace.shared.icon(forFile: "/bin/sh")
        }
        return NSWorkspace.shared.icon(forFile: bundlePath)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(application.name)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                if let bundleIdentifier = application.bundleIdentifier {
                    Text(application.launchSourceName.map { "由 \($0) 启动" } ?? bundleIdentifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let launchSourceName = application.launchSourceName {
                    Text("由 \(launchSourceName) 启动")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text("↑ \(formatNetworkBytes(application.totals.uploadedBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Text("↓ \(formatNetworkBytes(application.totals.downloadedBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Menu {
                if let liveApplication {
                    Button("抓取当前应用数据包（无需代理）") {
                        beginPacketCapture(liveApplication, localProxy: localProxy, packetCapture: packetCapture, trafficMonitor: trafficMonitor)
                    }
                    .disabled(packetCapture.isBusy)
                    Button("分析系统代理 HTTPS（不限应用）") {
                        beginProxyCapture(liveApplication, localProxy: localProxy, packetCapture: packetCapture, trafficMonitor: trafficMonitor)
                    }
                    .disabled(localProxy.isBusy)
                } else {
                    Button("抓包需应用正在运行，请切换实时列表") {}
                        .disabled(true)
                }
                Divider()
                Button("隐藏此应用") {
                    ignoredApplicationsRaw = IgnoreRules.adding(application.id, to: ignoredApplicationsRaw)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多操作 · 抓包、隐藏应用")
            .accessibilityLabel("更多操作：\(application.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu {
            if let liveApplication {
                Button("抓取当前应用数据包（无需代理）") {
                    beginPacketCapture(liveApplication, localProxy: localProxy, packetCapture: packetCapture, trafficMonitor: trafficMonitor)
                }
                .disabled(packetCapture.isBusy)
                Button("分析系统代理 HTTPS（不限应用）") {
                    beginProxyCapture(liveApplication, localProxy: localProxy, packetCapture: packetCapture, trafficMonitor: trafficMonitor)
                }
                .disabled(localProxy.isBusy)
            }
            Button("隐藏此应用") {
                ignoredApplicationsRaw = IgnoreRules.adding(application.id, to: ignoredApplicationsRaw)
            }
        }
    }
}

private struct ApplicationTrafficRow: View {
    let application: ApplicationTraffic
    let processes: [ProcessTraffic]
    var trafficMonitor: NetworkTrafficMonitor
    var packetCapture: PacketCaptureManager
    var localProxy: LocalProxyManager
    @AppStorage(IgnoreRules.networkApplicationsKey) private var ignoredApplicationsRaw = "[]"
    @State private var isExpanded = false
    @State private var openFiles: [OpenProjectFile] = []
    @State private var isLoadingOpenFiles = false

    private var icon: NSImage {
        guard let bundlePath = application.bundlePath else {
            return NSWorkspace.shared.icon(forFile: "/bin/sh")
        }
        return NSWorkspace.shared.icon(forFile: bundlePath)
    }

    private var subtitle: String {
        if let launchSourceName = application.launchSourceName {
            return application.processCount > 1
                ? "由 \(launchSourceName) 启动 · \(application.processCount) 进程"
                : "由 \(launchSourceName) 启动"
        }
        if let bundleIdentifier = application.bundleIdentifier {
            return application.processCount > 1
                ? "\(bundleIdentifier) · \(application.processCount) 进程"
                : bundleIdentifier
        }
        if application.processCount > 1 {
            return "\(application.processCount) 个进程"
        }
        return "PID \(application.pids.first ?? 0)"
    }

    private var projectText: String? {
        let source = application.projectDirectories.isEmpty
            ? application.workingDirectories
            : application.projectDirectories
        guard !source.isEmpty else { return nil }
        let paths = source.map {
            $0.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        if paths.count == 1 {
            return paths[0]
        }
        return "\(paths[0]) 等 \(paths.count) 个项目"
    }

    private var canExpand: Bool {
        !processes.isEmpty || !application.remoteEndpoints.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(application.name)
                            .font(.system(.body, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if let projectText {
                        Text(projectText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 8) {
                        Text("本次 ↑ \(formatNetworkBytes(application.uploadedBytes))")
                        Text("↓ \(formatNetworkBytes(application.downloadedBytes))")
                        if application.connectionCount > 0 {
                            Label("\(application.connectionCount)", systemImage: "link")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("↑ \(formatNetworkRate(application.uploadBytesPerSecond))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            application.uploadBytesPerSecond > 0
                                ? Color(nsColor: .systemOrange)
                                : .secondary
                        )
                    Text("↓ \(formatNetworkRate(application.downloadBytesPerSecond))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if canExpand {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canExpand else { return }
                    let willExpand = !isExpanded
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                    if willExpand { inspectOpenFiles() }
                }

                Menu {
                    Button("抓取当前应用数据包（无需代理）") {
                        beginPacketCapture(application, localProxy: localProxy, packetCapture: packetCapture, trafficMonitor: trafficMonitor)
                    }
                    .disabled(packetCapture.isBusy)
                    Button("分析系统代理 HTTPS（不限应用）") {
                        beginProxyCapture(application, localProxy: localProxy, packetCapture: packetCapture, trafficMonitor: trafficMonitor)
                    }
                    .disabled(localProxy.isBusy)
                    Divider()
                    Button("隐藏此应用") {
                        ignoredApplicationsRaw = IgnoreRules.adding(application.id, to: ignoredApplicationsRaw)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("更多操作 · 抓包、隐藏应用")
                .accessibilityLabel("更多操作：\(application.name)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if isExpanded {
                ApplicationTrafficDetails(
                    application: application,
                    processes: processes,
                    openFiles: openFiles,
                    isLoadingOpenFiles: isLoadingOpenFiles
                )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contextMenu {
            Button("抓取当前应用数据包（无需代理）") {
                beginPacketCapture(application, localProxy: localProxy, packetCapture: packetCapture, trafficMonitor: trafficMonitor)
            }
            .disabled(packetCapture.isBusy)
            Button("分析系统代理 HTTPS（不限应用）") {
                beginProxyCapture(application, localProxy: localProxy, packetCapture: packetCapture, trafficMonitor: trafficMonitor)
            }
            .disabled(localProxy.isBusy)
            Divider()
            Button("隐藏此应用") {
                ignoredApplicationsRaw = IgnoreRules.adding(application.id, to: ignoredApplicationsRaw)
            }
        }
    }

    private func inspectOpenFiles() {
        isLoadingOpenFiles = true
        trafficMonitor.inspectOpenProjectFiles(for: application.pids) { files in
            openFiles = files
            isLoadingOpenFiles = false
        }
    }
}

private struct ApplicationTrafficDetails: View {
    let application: ApplicationTraffic
    let processes: [ProcessTraffic]
    let openFiles: [OpenProjectFile]
    let isLoadingOpenFiles: Bool

    private var sortedProcesses: [ProcessTraffic] {
        processes.sorted { lhs, rhs in
            if lhs.uploadBytesPerSecond != rhs.uploadBytesPerSecond {
                return lhs.uploadBytesPerSecond > rhs.uploadBytesPerSecond
            }
            return lhs.downloadBytesPerSecond > rhs.downloadBytesPerSecond
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !application.remoteEndpoints.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("远程连接", systemImage: "network")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ForEach(application.remoteEndpoints.prefix(5)) { endpoint in
                        HStack(spacing: 6) {
                            Text(endpoint.transport)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .leading)
                            Text(endpoint.address)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let scopeLabel = endpoint.scopeLabel {
                                Text(scopeLabel)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.quaternary.opacity(0.7))
                                    .clipShape(Capsule())
                            }
                            Spacer(minLength: 4)
                            if let state = endpoint.state, !state.isEmpty {
                                Text(state)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if application.remoteEndpoints.count > 5 {
                        Text("还有 \(application.remoteEndpoints.count - 5) 个连接")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if application.uploadBytesPerSecond > 0,
                       application.remoteEndpoints.allSatisfy(\.isLocal) {
                        Text("当前只看到本机连接，可能由代理转发；真实外部目标需从代理侧继续解析。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !sortedProcesses.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("进程", systemImage: "square.stack.3d.up")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ForEach(sortedProcesses) { process in
                        ProcessTrafficRow(process: process)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Label("当前打开的项目文件", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if isLoadingOpenFiles {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                if !isLoadingOpenFiles {
                    if openFiles.isEmpty {
                        Text("未发现当前仍保持打开状态的源码/配置文件")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(openFiles.prefix(8)) { file in
                            OpenProjectFileRow(file: file)
                        }
                        if openFiles.count > 8 {
                            Text("还有 \(openFiles.count - 8) 个文件")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text("仅表示扫描瞬间仍打开的文件，不等同于已经上传。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.leading, 52)
        .padding(.trailing, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(Color.primary.opacity(0.018))
    }
}

private struct OpenProjectFileRow: View {
    let file: OpenProjectFile

    private var shortPath: String {
        file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(file.fileName)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            Text("PID \(file.pid)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 5)
            Text(shortPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 165, alignment: .trailing)
        }
        .help(file.path)
    }
}

private struct ProcessTrafficRow: View {
    let process: ProcessTraffic

    private var shortDirectory: String? {
        (process.projectDirectory ?? process.directory)?
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(process.processName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("PID \(process.pid)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let launchSourceName = process.launchSourceName {
                    Text("· \(launchSourceName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("↑ \(formatNetworkRate(process.uploadBytesPerSecond))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(process.uploadBytesPerSecond > 0 ? Color(nsColor: .systemOrange) : .secondary)
                Text("↓ \(formatNetworkRate(process.downloadBytesPerSecond))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                if let shortDirectory {
                    Text(shortDirectory)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text("累计 ↑ \(formatNetworkBytes(process.uploadedBytes))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if let command = process.command {
                Text(command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(command)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct MetricBadge: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    let isActive: Bool
    let sortAscending: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            }
            if isActive {
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isActive ? tint.opacity(0.22) : .clear, lineWidth: 1)
        }
    }
}

private func formatNetworkRate(_ bytesPerSecond: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
}

private func formatNetworkBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(clamping: bytes))
}

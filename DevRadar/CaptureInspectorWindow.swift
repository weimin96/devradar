import AppKit
import SwiftUI

enum CaptureInspectorMode {
    case proxy
    case packets
}

@MainActor
enum CaptureInspectorWindow {
    private static var window: NSWindow?

    static func open(
        mode: CaptureInspectorMode,
        localProxy: LocalProxyManager,
        packetCapture: PacketCaptureManager
    ) {
        let view = CaptureInspectorView(
            mode: mode,
            localProxy: localProxy,
            packetCapture: packetCapture
        )
        if let window {
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "DevRadar · 抓包分析"
        newWindow.minSize = NSSize(width: 760, height: 500)
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = NSHostingView(rootView: view)
        newWindow.center()
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum RequestFilter: String, CaseIterable {
    case all = "全部"
    case uploads = "上传"
    case errors = "异常"
}

private struct PacketPreviewRow: Identifiable {
    let id: Int
    let line: String
}

private struct CaptureInspectorView: View {
    let mode: CaptureInspectorMode
    var localProxy: LocalProxyManager
    var packetCapture: PacketCaptureManager

    @State private var search = ""
    @State private var filter = RequestFilter.all
    @State private var selectedEventID: UUID?
    @State private var selectedPacket: Int?
    @State private var confirmSystemProxySwitch = false

    private var isProxy: Bool { mode == .proxy }

    private var events: [LocalProxyEvent] {
        localProxy.events.filter { event in
            switch filter {
            case .all: break
            case .uploads:
                if (event.uploadBytes ?? 0) == 0 { return false }
            case .errors:
                if event.type != "error" && (event.status ?? 0) < 400 { return false }
            }
            guard !search.isEmpty else { return true }
            return [event.host, event.path, event.method, event.message]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var selectedEvent: LocalProxyEvent? {
        guard let selectedEventID else { return nil }
        return localProxy.events.first { $0.id == selectedEventID }
    }

    private var packetRecords: [PacketPreviewRow] {
        let firstNumber = max(0, packetCapture.packetCount - packetCapture.packetLines.count)
        return packetCapture.packetLines.enumerated().compactMap { offset, line in
            guard search.isEmpty || line.localizedCaseInsensitiveContains(search) else { return nil }
            return PacketPreviewRow(id: firstNumber + offset + 1, line: line)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    listControls
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            if isProxy {
                                ForEach(events) { event in
                                    eventRow(event)
                                }
                            } else {
                                ForEach(packetRecords) { item in
                                    packetRow(index: item.id, line: item.line)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .overlay {
                        if isProxy ? events.isEmpty : packetRecords.isEmpty {
                            if isProxy {
                                proxyEmptyState
                            } else if packetCapture.state == .ready || packetCapture.state == .failed {
                                packetStartState
                            } else {
                                ContentUnavailableView(
                                    "暂无数据包",
                                    systemImage: "network",
                                    description: Text(packetCapture.state == .starting
                                        ? "已返回管理员授权，正在确认 tcpdump 启动…"
                                        : packetCapture.state == .authorizing
                                            ? "等待 macOS 管理员授权"
                                            : "等待目标进程产生网络流量")
                                )
                            }
                        }
                    }
                }
                .frame(minWidth: 330, idealWidth: 450, maxWidth: 550)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 500)
        .confirmationDialog(
            "临时修改 Mac 系统代理以捕获现有应用流量？",
            isPresented: $confirmSystemProxySwitch,
            titleVisibility: .visible
        ) {
            Button("确认临时切换系统代理") {
                localProxy.captureExistingApplications()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将临时修改默认网络服务的 HTTP/HTTPS 代理。其他遵循 macOS 系统代理的应用也会经过 DevRadar，其中 HTTPS 可能被解密；当前已有代理会通过上游连接保留。停止抓包会请求恢复原设置，异常退出后需手动恢复。不能仅限定为选中 PID。")
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: isProxy ? "network.badge.shield.half.filled" : "waveform.path")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isProxy ? (localProxy.httpsDecryptionEnabled ? "系统代理 · HTTPS 分析" : "系统代理 · HTTP 分析") : "原始数据包分析")
                        .font(.title3.weight(.semibold))
                    Text(isProxy ? "请求来源未识别（由 \(localProxy.applicationName) 进入）" : packetCapture.applicationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                status
                if isProxy {
                    if localProxy.isBusy {
                        Button("停止抓包", role: .destructive) { localProxy.stop() }
                            .disabled(localProxy.systemProxy.isPending)
                    } else {
                        Button("清除记录") { localProxy.clear() }
                    }
                    Button("导出会话 JSON") { localProxy.exportSession() }
                        .disabled(localProxy.events.isEmpty)
                        .help("只导出域名、方法、状态、耗时、流量；不导出路径、Headers、正文")
                } else {
                    if packetCapture.state == .ready || packetCapture.state == .failed {
                        Button(packetCapture.state == .failed ? "重新开始抓包" : "开始抓包") {
                            packetCapture.startPreparedCapture()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(packetCapture.selectedPIDs.isEmpty)
                    }
                    if packetCapture.state == .capturing {
                        Button("停止抓包", role: .destructive) { packetCapture.stop() }
                    }
                    if packetCapture.state == .completed {
                        Button("导出 PCAPNG") { packetCapture.saveCapture() }
                    }
                }
            }

            if isProxy {
                Label("进程归属未经验证：此窗口展示经过代理的全部应用请求，不能归因于 \(localProxy.applicationName)。", systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                HStack(spacing: 16) {
                    Label("\(localProxy.requestCount) 请求", systemImage: "list.bullet.rectangle")
                    if localProxy.requestCount > localProxy.retainedLimit {
                        Text("仅展示最近 \(localProxy.retainedLimit) 条")
                    }
                    Label(
                        "上传 \(ByteCountFormatter.string(fromByteCount: localProxy.uploadedBytes, countStyle: .file))",
                        systemImage: "arrow.up"
                    )
                    Spacer()
                    if localProxy.isListening {
                        Text(localProxy.proxyAddress)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("复制代理配置") { localProxy.copyProxyEnvironment() }
                        Button("测试代理") { localProxy.testProxyConnection() }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                systemProxyControls
                if let application = localProxy.selectedApplication,
                   application.remoteEndpoints.contains(where: { !$0.isLocal }) {
                    Label(
                        "该应用已有 \(application.connectionCount) 条网络连接。已建立的连接或绕过系统代理的直连不会被当前代理捕获。",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Text("原应用抓包有两种模式：按 PID 原始抓包不会改变系统设置；HTTP/HTTPS 明文分析需要临时切换本机系统代理，会影响其他使用该代理的应用，且不能保证只抓所选 PID。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !localProxy.httpsDecryptionEnabled {
                    Label("本次会话未开启 HTTPS 解密，请在设置中开启后重新启动代理", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if UserDefaults.standard.bool(forKey: "proxyBodyPreview") {
                    Label("已开启请求正文预览；自动脱敏不能保证覆盖全部隐私信息，请结束后在设置中关闭。", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let result = localProxy.connectivityResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if packetCapture.state == .ready {
                    Label(
                        "已选中 \(packetCapture.selectedPIDs.count) 个进程（PID：\(packetCapture.selectedPIDs.map(String.init).joined(separator: ", "))）。点击「开始抓包」后才会请求管理员授权。",
                        systemImage: "hand.tap"
                    )
                    .font(.caption)
                } else if packetCapture.state == .authorizing {
                    Label("等待 macOS 管理员授权，请查看系统授权窗口。", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if packetCapture.state == .starting {
                    Label("管理员授权已返回，正在检查 tcpdump 是否真正启动…", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("已记录 \(packetCapture.packetCount) 条数据包 · 按 PID 捕获 · HTTPS 内容保持加密")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if packetCapture.packetCount == 0 && packetCapture.selectedConnectionCount > 0 {
                    Text("已定位到目标应用的 \(packetCapture.selectedConnectionCount) 条现有连接。只有连接实际发送或接收新数据时才会产生数据包记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !packetCapture.selectedRemoteEndpoints.isEmpty {
                    HStack(spacing: 8) {
                        Text("抓包开始时连接目标：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(packetCapture.selectedRemoteEndpoints.joined(separator: "、"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
    }

    private var status: some View {
        HStack(spacing: 5) {
            Circle()
                .fill((isProxy ? localProxy.isBusy : packetCapture.isBusy) ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(isProxy ? proxyStatus : packetStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var systemProxyControls: some View {
        HStack(spacing: 10) {
            if localProxy.systemProxy.pendingRecovery {
                Button("恢复原系统代理") {
                    localProxy.systemProxy.restore { succeeded in
                        if !succeeded { localProxy.lastError = localProxy.systemProxy.message }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(localProxy.systemProxy.isPending)
            } else if localProxy.isListening {
                Button("让现有应用走代理（会影响系统网络）") {
                    confirmSystemProxySwitch = true
                }
                .buttonStyle(.bordered)
                .disabled(localProxy.systemProxy.isPending || localProxy.systemProxy.isActive ||
                          localProxy.systemProxy.originalUpstream == nil)
            }
            if localProxy.systemProxy.isActive {
                Label("临时系统代理已启用", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let message = localProxy.systemProxy.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(localProxy.systemProxy.pendingRecovery ? .orange : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var proxyEmptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "network.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("尚未收到代理请求")
                .font(.headline)
            Text("代理正在监听，但现有应用尚未连接它。若应用遵循 macOS 系统代理，可明确授权临时接管；否则请使用按 PID 原始数据包模式。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if localProxy.isListening {
                Button("测试代理连通性") { localProxy.testProxyConnection() }
                    .buttonStyle(.bordered)
                if let application = localProxy.selectedApplication {
                    Button("改用当前应用原始抓包（无需代理）") {
                        packetCapture.prepare(application: application)
                        CaptureInspectorWindow.open(
                            mode: .packets, localProxy: localProxy, packetCapture: packetCapture
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(packetCapture.isBusy)
                }
            }
        }
        .padding(24)
    }

    private var packetStartState: some View {
        VStack(spacing: 12) {
            Image(systemName: packetCapture.state == .failed
                ? "exclamationmark.triangle"
                : "waveform.path")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(packetCapture.state == .failed ? Color.orange : Color.secondary)
            Text(packetCapture.state == .failed ? "抓包启动失败" : "已选择抓包应用")
                .font(.headline)
            if packetCapture.state == .failed {
                Text(packetCapture.lastError ?? "抓包未启动，请重试")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 380)
            } else {
                Text("点击开始后将请求 macOS 管理员授权，最多抓取 10 分钟或 10,000 个数据包。HTTPS 正文不会被解密。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }
            Button(packetCapture.state == .failed ? "重试抓包" : "开始抓包") {
                packetCapture.startPreparedCapture()
            }
            .buttonStyle(.borderedProminent)
            .disabled(packetCapture.selectedPIDs.isEmpty)
        }
        .padding(24)
    }

    private var proxyStatus: String {
        switch localProxy.state {
        case .idle: return "未启动"
        case .starting: return "启动中"
        case .listening: return "监听中"
        case .stopped: return "已停止"
        case .failed: return "启动失败"
        }
    }

    private var packetStatus: String {
        switch packetCapture.state {
        case .idle: return "未启动"
        case .ready: return "等待开始"
        case .authorizing: return "等待授权"
        case .starting: return "启动检测中"
        case .capturing: return "捕获中"
        case .stopping: return "停止中"
        case .completed: return "已完成"
        case .failed: return "捕获失败"
        }
    }

    private var listControls: some View {
        VStack(spacing: 8) {
            if isProxy {
                Picker("请求筛选", selection: $filter) {
                    ForEach(RequestFilter.allCases, id: \.rawValue) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            TextField(isProxy ? "搜索域名、请求路径" : "搜索 IP、端口、协议", text: $search)
                .textFieldStyle(.roundedBorder)
        }
        .padding(10)
    }

    private func eventRow(_ event: LocalProxyEvent) -> some View {
        Button {
            selectedEventID = event.id
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Text(event.method ?? event.type.uppercased())
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .frame(width: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.host ?? "—")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(event.path ?? event.message ?? event.type)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isProxy {
                        Text("来源未识别")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    if let status = event.status {
                        Text("\(status)")
                            .font(.caption.monospacedDigit())
                    }
                    if let duration = event.durationMs {
                        Text("\(duration) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if event.type == "started" {
                        Text("进行中")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let bytes = event.uploadBytes, bytes > 0 {
                        Text("↑ \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(9)
            .background(selectedEventID == event.id ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func packetRow(index: Int, line: String) -> some View {
        Button {
            selectedPacket = index
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
                Text(line)
                    .font(.caption.monospaced())
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .background(selectedPacket == index ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        if isProxy, let event = selectedEvent {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("请求详情")
                        .font(.headline)
                    detailField("进程归属", "来源未识别（系统代理流量）")
                    detailField("方法 / 类型", event.method ?? event.type)
                    detailField("请求状态", event.type == "started" ? "进行中" :
                        event.type == "request" ? "已完成" :
                        event.type == "error" ? "失败" : event.type)
                    if let timestamp = event.timestamp {
                        detailField("事件时间 (UTC)", timestamp)
                    }
                    if let duration = event.durationMs {
                        detailField("请求耗时", "\(duration) ms")
                    }
                    detailField("主机", event.host ?? "—")
                    detailField("路径", event.path ?? "—")
                    detailField("响应状态", event.status.map(String.init) ?? "—")
                    detailField("上传", ByteCountFormatter.string(fromByteCount: event.uploadBytes ?? 0, countStyle: .file))
                    detailField("下载", ByteCountFormatter.string(fromByteCount: event.downloadBytes ?? 0, countStyle: .file))
                    if let contentType = event.contentType, !contentType.isEmpty {
                        detailField("内容类型", contentType)
                    }
                    if let preview = event.preview, !preview.isEmpty {
                        JSONPreviewView(preview: preview)
                            .id(event.id)
                    }
                    if let message = event.message, !message.isEmpty {
                        detailField("诊断信息", message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else if !isProxy, let selectedPacket,
                  let selectedLine = packetRecords.first(where: { $0.id == selectedPacket })?.line {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("数据包 #\(selectedPacket)")
                        .font(.headline)
                    Text(selectedLine)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else {
            ContentUnavailableView("选择一条记录查看详情", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func detailField(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            if let error = isProxy ? localProxy.lastError : packetCapture.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text("数据只在本机处理。关闭窗口不会停止当前抓包会话。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

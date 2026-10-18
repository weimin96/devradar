import AppKit
import Observation
import SwiftUI

@Observable
final class DNSDiagnosticsModel {
    var query = ""
    var result: DNSLookupResult?
    var queryError: String?
    var resolvers: [DNSResolverInfo] = []
    var configurationError: String?
    var isResolving = false
    var isLoadingConfiguration = false
    let capture = DNSCaptureManager()
    private var lookupGeneration = 0

    func refreshConfiguration() {
        guard !isLoadingConfiguration else { return }
        isLoadingConfiguration = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let response = Result { try DNSConfigurationReader.read() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingConfiguration = false
                switch response {
                case .success(let resolvers):
                    self.resolvers = resolvers
                    self.configurationError = resolvers.isEmpty ? "未检测到系统 DNS 解析器" : nil
                case .failure(let error):
                    self.configurationError = error.localizedDescription
                    self.resolvers = []
                }
            }
        }
    }

    func lookup() {
        lookupGeneration += 1
        let generation = lookupGeneration
        let input = query
        result = nil
        queryError = nil
        isResolving = false
        do {
            _ = try DNSDiagnosticsEngine.validate(input)
        } catch {
            queryError = error.localizedDescription
            return
        }
        isResolving = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let response = Result { try DNSDiagnosticsEngine.lookup(input) }
            DispatchQueue.main.async {
                guard let self, self.lookupGeneration == generation else { return }
                self.isResolving = false
                switch response {
                case .success(let result): self.result = result
                case .failure(let error): self.queryError = error.localizedDescription
                }
            }
        }
    }
}

enum DNSDiagnosticsWindow {
    private static let model = DNSDiagnosticsModel()

    static func open(trafficMonitor: NetworkTrafficMonitor, query: String? = nil) {
        if let query {
            model.query = query
            if !model.isResolving { model.lookup() }
        }
        if let window = NSApp.windows.first(where: { $0.title == "DevRadar DNS 诊断" }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 530),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DevRadar DNS 诊断"
        window.minSize = NSSize(width: 450, height: 380)
        window.contentView = NSHostingView(rootView: DNSDiagnosticsView(model: model, trafficMonitor: trafficMonitor))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func stopCapture() {
        model.capture.stop()
    }
}

private struct DNSDiagnosticsView: View {
    @Bindable var model: DNSDiagnosticsModel
    var trafficMonitor: NetworkTrafficMonitor

    private var matchingConnections: [(name: String, ip: String)] {
        guard let result = model.result, result.kind == .forward else { return [] }
        let ips = Set(result.answers)
        return trafficMonitor.applications.flatMap { application in
            application.remoteEndpoints.compactMap { endpoint -> (name: String, ip: String)? in
                guard let ip = DNSDiagnosticsEngine.endpointIP(endpoint.address), ips.contains(ip) else { return nil }
                return (application.name, ip)
            }
        }
        .reduce(into: [(name: String, ip: String)]()) { matches, value in
            if !matches.contains(where: { $0.name == value.name && $0.ip == value.ip }) {
                matches.append(value)
            }
        }
    }

    private func associations(for event: DNSObservedQuery) -> [String] {
        guard !event.answers.isEmpty else { return [] }
        // The application endpoint list is only a *current* snapshot. Do not
        // match old DNS records to a later socket (or recycled PID).
        guard abs(Date().timeIntervalSince(event.responseAt ?? event.observedAt)) <= 20 else { return [] }
        let resolvedIPs = Set(event.answers)
        return trafficMonitor.applications.compactMap { application -> String? in
            let sameIP = application.remoteEndpoints.contains {
                DNSDiagnosticsEngine.endpointIP($0.address).map(resolvedIPs.contains) ?? false
            }
            guard sameIP else { return nil }
            if let pid = event.pid, application.pids.contains(pid) {
                let incident = trafficMonitor.uploadAnalysis[application.id]?.incidents.contains {
                    abs($0.triggeredAt.timeIntervalSince(event.observedAt)) <= 20 &&
                        $0.observedPIDs.contains(pid)
                } ?? false
                return "\(application.name) · PID/IP 匹配\(incident ? " · 上传异常同时间段" : "")"
            }
            return event.pid == nil ? "\(application.name) · 仅 IP 匹配（未验证）" : nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("DNS 查询事件").font(.headline)
                        Spacer()
                        Text("\(model.capture.parser.events.count) 条")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if model.capture.running {
                            Button("停止监听") { model.capture.stop() }
                                .buttonStyle(.bordered)
                                .disabled(model.capture.state == .stopping)
                        } else {
                            Button("开始监听") { model.capture.start() }
                                .buttonStyle(.bordered)
                        }
                        Button("清空") { model.capture.clear() }
                            .buttonStyle(.borderless)
                            .disabled(model.capture.running)
                    }
                    switch model.capture.state {
                    case .authorizing:
                        Label("等待管理员授权…", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    case .capturing, .starting:
                        Label("正在监听明文 DNS（53 端口）", systemImage: "record.circle")
                            .font(.caption).foregroundStyle(.green)
                    case .stopping:
                        Text("正在停止监听…").font(.caption).foregroundStyle(.secondary)
                    case .completed:
                        Text("监听已结束").font(.caption).foregroundStyle(.secondary)
                    case .failed, .idle:
                        EmptyView()
                    }
                    if let error = model.capture.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Text("手动授权后监听最多 5 分钟，仅保留最近 400 条查询元数据；不会读取 HTTPS 内容或更改系统 DNS。DoH、DoT 和缓存命中无法在此观察。")
                        .font(.caption).foregroundStyle(.secondary)

                    if model.capture.parser.events.isEmpty && model.capture.state == .capturing {
                        Text("尚无可解析的 DNS 请求。没有记录不代表应用未联网。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.capture.parser.events.prefix(70)) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(event.domain)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text(event.queryType)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(event.observedAt, style: .time)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 7) {
                                Text(event.pid.map { "PID \($0)" } ?? "进程未识别")
                                Text(event.responseStatus ?? "等待响应")
                                if let responseAt = event.responseAt {
                                    Text("\(Int(responseAt.timeIntervalSince(event.observedAt) * 1_000)) ms")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if !event.answers.isEmpty {
                                Text(event.answers.joined(separator: " · "))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            ForEach(associations(for: event).prefix(4), id: \.self) { association in
                                Text(association)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                    if !model.capture.parser.events.isEmpty {
                        Text("PID 仅来自抓包元数据；IP 与连接匹配不等于访问了该域名，上传异常仅作时间关联。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("域名与 IP 查询")
                        .font(.headline)
                    HStack(spacing: 8) {
                        TextField("输入域名或 IP，例如 example.com", text: $model.query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.lookup() }
                        Button("查询") { model.lookup() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isResolving || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if model.isResolving {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在通过系统解析器查询…")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    if let error = model.queryError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let result = model.result {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(result.kind == .forward ? "系统解析结果" : "反向名称查询结果")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(result.elapsedMilliseconds) ms")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(result.query)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if result.answers.isEmpty {
                                Text("解析成功，但没有可显示的地址")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(result.answers, id: \.self) { answer in
                                    Text(answer)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            Text(result.kind == .forward
                                 ? "使用 macOS 系统解析能力，结果可能来自缓存、hosts、mDNS 或 VPN，并不等同于 DNS 抓包。"
                                 : "PTR / 系统反向名称仅作参考，不代表应用访问过该域名，也不证明服务器身份。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !matchingConnections.isEmpty {
                                Divider()
                                Text("与当前连接的 IP 相同")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(Array(matchingConnections.prefix(6).enumerated()), id: \.offset) { _, match in
                                    HStack {
                                        Text(match.name).lineLimit(1)
                                        Spacer()
                                        Text(match.ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                                Text("仅表示解析 IP 与应用连接目标相同；共享 IP、代理、CDN 均可能造成巧合，不能证明应用查询或访问了该域名。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("系统 DNS 配置").font(.headline)
                        Spacer()
                        Button {
                            model.refreshConfiguration()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isLoadingConfiguration)
                    }
                    if model.isLoadingConfiguration {
                        ProgressView().controlSize(.small)
                    }
                    if let error = model.configurationError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.resolvers) { resolver in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(resolver.domain ?? "默认解析器")
                                    .font(.subheadline.weight(.medium))
                                if resolver.scoped { Text("接口限定").font(.caption2).foregroundStyle(.secondary) }
                                Spacer()
                                if let interface = resolver.interface {
                                    Text(interface).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(resolver.nameservers.isEmpty ? (resolver.options ?? "系统服务") : resolver.nameservers.joined(separator: " · "))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            if !resolver.searchDomains.isEmpty {
                                Text("搜索域：\(resolver.searchDomains.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                    Text("只读取当前 macOS DNS 配置，不更改解析器、网络代理或证书。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refreshConfiguration() }
        .onDisappear { model.capture.stop() }
    }
}

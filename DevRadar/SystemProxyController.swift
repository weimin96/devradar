import Foundation
import Observation

nonisolated struct NetworkProxyEntry: Codable, Equatable {
    let enabled: Bool
    let server: String
    let port: Int
    let authenticated: Bool
}

nonisolated struct NetworkProxyBackup: Codable {
    let service: String
    let http: NetworkProxyEntry
    let https: NetworkProxyEntry
    let devRadarAddress: String
}

/// Explicit, temporary system-proxy switching for existing, already-running
/// clients that honor macOS proxy settings. NOT a per-process network hook.
/// Never updates SOCKS/PAC or bypass lists and never runs as root from a file.
@Observable
final class SystemProxyController {
    enum State {
        case idle, updating, active, restoring, failed
    }

    var state: State = .idle
    var message: String?
    var serviceName = ""
    private(set) var pendingRecovery = false
    private(set) var originalUpstream: String?

    private static var backupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevRadar/system-proxy-backup.json")
    }

    init() {
        pendingRecovery = FileManager.default.fileExists(atPath: Self.backupURL.path)
        if pendingRecovery {
            message = "检测到上次的临时系统代理记录。请先恢复原配置，不要开始新的系统代理会话。"
        }
    }

    var isActive: Bool { state == .active }
    var isPending: Bool { state == .updating || state == .restoring }

    /// Called before starting the local proxy process. All calls here are
    /// read-only; no network configuration is modified.
    func inspectCurrentConnection() -> String? {
        guard !pendingRecovery else { return nil }
        do {
            let backup = try Self.readCurrent(devRadarAddress: "")
            serviceName = backup.service
            let web = backup.http
            let secure = backup.https
            guard web.enabled, secure.enabled, !web.authenticated, !secure.authenticated,
                  web.server == secure.server, web.port == secure.port,
                  web.port > 0, !web.server.isEmpty else {
                originalUpstream = nil
                message = "当前系统 HTTP/HTTPS 代理不一致或有鉴权，无法安全自动接力。仍可抓取原始数据包。"
                return nil
            }
            originalUpstream = "http://\(web.server):\(web.port)"
            return originalUpstream
        } catch {
            originalUpstream = nil
            message = "无法识别当前网络代理：\(error.localizedDescription)"
            return nil
        }
    }

    func enable(devRadarAddress: String, completion: @escaping (Bool) -> Void) {
        guard !isPending, !pendingRecovery, state != .active else {
            message = "已有系统代理切换正在进行，或存在尚未恢复的配置"
            completion(false)
            return
        }
        guard let originalUpstream else {
            message = "现有 HTTP/HTTPS 代理无法安全串联，拒绝覆盖系统设置"
            completion(false)
            return
        }
        let expected = originalUpstream
        state = .updating
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let backup = try Self.readCurrent(devRadarAddress: devRadarAddress)
                let currentURL = "http://\(backup.http.server):\(backup.http.port)"
                guard backup.http.enabled && backup.https.enabled,
                      backup.http == backup.https,
                      !backup.http.authenticated,
                      currentURL == expected else {
                    throw ProxyError.invalid("系统代理已变化，拒绝覆盖，请重新开始抓包会话")
                }
                // Persist original settings before making any changes, so
                // a failed partial update remains recoverable.
                try Self.persist(backup)
                DispatchQueue.main.async { self?.pendingRecovery = true }
                let components = devRadarAddress.split(separator: ":")
                guard components.count == 2, components[0] == "127.0.0.1",
                      let port = Int(components[1]), (1...65535).contains(port) else {
                    throw ProxyError.invalid("代理监听地址无效")
                }
                try Self.setProxy(service: backup.service, port: port)
                // networksetup may return success while another proxy manager
                // immediately changes the active service. Verify both entries.
                let applied = try Self.readService(backup.service, devRadarAddress: devRadarAddress)
                let expectedProxy = NetworkProxyEntry(
                    enabled: true, server: "127.0.0.1", port: port, authenticated: false
                )
                guard applied.http == expectedProxy, applied.https == expectedProxy else {
                    throw ProxyError.invalid("系统代理未正确切换，请点击「恢复原系统代理」")
                }
                DispatchQueue.main.async {
                    self?.state = .active
                    self?.message = "已临时切换 \(backup.service) 的系统 HTTP/HTTPS 代理；其他遵循系统代理的应用也可能经过此端口。结束后必须恢复。"
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = .failed
                    self?.message = "切换失败：\(error.localizedDescription)。如已经修改了系统代理，请立即点击恢复。"
                    completion(false)
                }
            }
        }
    }

    /// Keeps the helper alive until restoration succeeds. Otherwise a network
    /// outage could be caused by stopping the proxy before reverting settings.
    func restore(completion: @escaping (Bool) -> Void) {
        guard !isPending else { completion(false); return }
        guard pendingRecovery else { state = .idle; completion(true); return }
        state = .restoring
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let backup = try Self.loadBackup()
                let current = try Self.readService(backup.service, devRadarAddress: backup.devRadarAddress)
                // A cancelled authorization may have left the system unchanged.
                // In that case no second elevation prompt should be necessary.
                if current.http != backup.http || current.https != backup.https {
                    let components = backup.devRadarAddress.split(separator: ":")
                    guard components.count == 2, let port = Int(components[1]) else {
                        throw ProxyError.invalid("原始恢复数据中的端口无效")
                    }
                    let devRadarProxy = NetworkProxyEntry(
                        enabled: true, server: "127.0.0.1", port: port, authenticated: false
                    )
                    // Refuse to overwrite changes made by other VPN/proxy
                    // clients during capture. Either setting can be partially
                    // switched if an administrator command was interrupted.
                    guard (current.http == backup.http || current.http == devRadarProxy),
                          (current.https == backup.https || current.https == devRadarProxy) else {
                        throw ProxyError.invalid("系统代理已被其他程序修改。为避免覆盖新设置，请手动核对原代理并完成恢复")
                    }
                    try Self.restoreProxy(backup)
                }
                // Do not delete recovery evidence until BOTH settings are
                // re-read and match the stored snapshot exactly.
                let verified = try Self.readService(backup.service, devRadarAddress: backup.devRadarAddress)
                guard verified.http == backup.http, verified.https == backup.https else {
                    throw ProxyError.invalid("系统代理恢复命令已执行，但验证未通过；恢复记录已保留")
                }
                try FileManager.default.removeItem(at: Self.backupURL)
                DispatchQueue.main.async {
                    self?.pendingRecovery = false
                    self?.state = .idle
                    self?.message = "已恢复 \(backup.service) 原有的 HTTP/HTTPS 代理设置"
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = .failed
                    self?.message = "恢复失败：\(error.localizedDescription)。系统代理备份仍保留，请重试恢复。"
                    completion(false)
                }
            }
        }
    }

    private enum ProxyError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return reason }
            return nil
        }
    }

    private static func output(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProxyError.invalid(result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func readCurrent(devRadarAddress: String) throws -> NetworkProxyBackup {
        let route = try output("/sbin/route", ["-n", "get", "default"])
        guard let interfaceLine = route.components(separatedBy: .newlines)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }),
              let interface = interfaceLine.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespacesAndNewlines), !interface.isEmpty else {
            throw ProxyError.invalid("无法识别默认网络接口")
        }
        let services = try output("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        let lines = services.components(separatedBy: .newlines)
        var service: String?
        for (index, line) in lines.enumerated() where line.contains("Device: \(interface)") {
            guard index > 0 else { continue }
            let previous = lines[index - 1]
            if let closing = previous.firstIndex(of: ")") {
                service = String(previous[previous.index(after: closing)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            break
        }
        guard let service, !service.isEmpty, !service.hasPrefix("*") else {
            throw ProxyError.invalid("默认接口 \(interface) 没有可用网络服务")
        }
        return try readService(service, devRadarAddress: devRadarAddress)
    }

    private static func readService(_ service: String, devRadarAddress: String) throws -> NetworkProxyBackup {
        let pac = try output("/usr/sbin/networksetup", ["-getautoproxyurl", service])
        guard !pac.contains("Enabled: Yes") else {
            throw ProxyError.invalid("检测到自动代理配置（PAC），为避免破坏现有网络，不进行系统代理切换")
        }
        let web = try parseProxy(output("/usr/sbin/networksetup", ["-getwebproxy", service]))
        let secure = try parseProxy(output("/usr/sbin/networksetup", ["-getsecurewebproxy", service]))
        return NetworkProxyBackup(service: service, http: web, https: secure, devRadarAddress: devRadarAddress)
    }

    private static func parseProxy(_ data: String) throws -> NetworkProxyEntry {
        let dict = Dictionary(uniqueKeysWithValues: data.components(separatedBy: .newlines)
            .compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<colon]), String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            })
        guard let enabled = dict["Enabled"], let server = dict["Server"],
              let rawPort = dict["Port"], let port = Int(rawPort) else {
            throw ProxyError.invalid("网络代理返回格式不受支持")
        }
        return NetworkProxyEntry(
            enabled: enabled == "Yes", server: server, port: port,
            authenticated: dict["Authenticated Proxy Enabled"] != "0"
        )
    }

    private static func persist(_ snapshot: NetworkProxyBackup) throws {
        let url = backupURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func loadBackup() throws -> NetworkProxyBackup {
        try JSONDecoder().decode(NetworkProxyBackup.self, from: Data(contentsOf: backupURL))
    }

    private static func setProxy(service: String, port: Int) throws {
        let svc = shellQuote(service)
        let commands = [
            "/usr/sbin/networksetup -setwebproxy \(svc) 127.0.0.1 \(port)",
            "/usr/sbin/networksetup -setsecurewebproxy \(svc) 127.0.0.1 \(port)"
        ]
        try runAdmin(commands)
    }

    private static func restoreProxy(_ backup: NetworkProxyBackup) throws {
        let svc = shellQuote(backup.service)
        func commands(_ entry: NetworkProxyEntry, isSecure: Bool) -> [String] {
            let operation = isSecure ? "securewebproxy" : "webproxy"
            var result: [String] = []
            if !entry.server.isEmpty && entry.port > 0 && entry.port <= 65535 {
                result.append("/usr/sbin/networksetup -set\(operation) \(svc) \(shellQuote(entry.server)) \(entry.port)")
            }
            result.append("/usr/sbin/networksetup -set\(operation)state \(svc) \(entry.enabled ? "on" : "off")")
            return result
        }
        try runAdmin(commands(backup.http, isSecure: false) + commands(backup.https, isSecure: true))
    }

    private static func runAdmin(_ commands: [String]) throws {
        let shell = "set -e; " + commands.joined(separator: "; ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        _ = try output("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

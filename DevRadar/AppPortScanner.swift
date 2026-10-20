import AppKit
import Foundation
import Observation

@Observable
final class AppPortScanner {
    var ports: [PortInfo] = []
    var lastError: String?
    var isScanning = false
    var webServicePorts = Set<Int>()

    private var timer: Timer?
    private var webProbeIdentities: [Int: String] = [:]
    private var webProbeLastAt: [Int: Date] = [:]
    private let scanner = PortScanner()

    func startScanning() {
        if timer != nil {
            scan()
            return
        }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stopScanning() {
        timer?.invalidate()
        timer = nil
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var guiAppPIDs = Set<Int>()
            DispatchQueue.main.sync {
                guiAppPIDs = Set(
                    NSWorkspace.shared.runningApplications
                        .filter { $0.bundleIdentifier != nil }
                        .map { Int($0.processIdentifier) }
                )
            }

            let results = scanner.fetchPorts(includeAll: true, excludingPIDs: guiAppPIDs)
            DispatchQueue.main.async {
                self.ports = results
                self.refreshWebServices(for: results)
                self.isScanning = false
            }
        }
    }

    func stop(port: PortInfo, mode: ProcessStopMode) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try scanner.stop(port, mode: mode)
                Thread.sleep(forTimeInterval: 0.25)
                DispatchQueue.main.async {
                    self.lastError = nil
                    self.scan()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.scan()
                }
            }
        }
    }
    func preferredWebPort(for ports: [PortInfo]) -> Int? {
        let detected = ports.filter { webServicePorts.contains($0.port) }
        let candidates = detected.isEmpty ? ports : detected
        return candidates.max { lhs, rhs in
            webScore(lhs) < webScore(rhs)
        }?.port
    }

    func isWebService(port: Int) -> Bool {
        webServicePorts.contains(port)
    }

    private func refreshWebServices(for ports: [PortInfo]) {
        let developmentPorts = ports.filter(\.isDevelopmentService)
        let currentPorts = Set(developmentPorts.map(\.port))
        webServicePorts.formIntersection(currentPorts)
        webProbeIdentities = webProbeIdentities.filter { currentPorts.contains($0.key) }
        webProbeLastAt = webProbeLastAt.filter { currentPorts.contains($0.key) }

        let now = Date()
        let candidates = developmentPorts.filter { port in
            let identity = "\(port.pid):\(port.processName):\(port.command ?? "")"
            let identityChanged = webProbeIdentities[port.port] != identity
            let probeExpired = now.timeIntervalSince(webProbeLastAt[port.port] ?? .distantPast) >= 30
            guard identityChanged || probeExpired else { return false }
            webProbeIdentities[port.port] = identity
            webProbeLastAt[port.port] = now
            if identityChanged {
                webServicePorts.remove(port.port)
            }
            return true
        }

        guard !candidates.isEmpty else { return }
        let identities = Dictionary(uniqueKeysWithValues: candidates.compactMap { port in
            webProbeIdentities[port.port].map { (port.port, $0) }
        })
        Self.probeWebServices(candidates) { [weak self] responsivePorts in
            guard let self else { return }
            let stillCurrent = Set(self.ports.map(\.port))
            let probedPorts = Set(identities.compactMap { port, identity in
                stillCurrent.contains(port) && self.webProbeIdentities[port] == identity ? port : nil
            })
            self.webServicePorts.subtract(probedPorts)
            self.webServicePorts.formUnion(responsivePorts.intersection(probedPorts))
        }
    }

    private func webScore(_ port: PortInfo) -> Int {
        var score = 0
        switch port.runtimeName.lowercased() {
        case let value where value.contains("vite"): score += 100
        case let value where value.contains("next") || value.contains("nuxt"): score += 95
        case let value where value.contains("spring") || value.contains("uvicorn") || value.contains("gunicorn") || value.contains("flask"): score += 80
        case let value where value.contains("node"): score += 40
        default: break
        }
        if [3000, 3001, 4000, 5000, 5173, 5174, 8000, 8080, 8081, 8888].contains(port.port) {
            score += 60
        } else if (3000...9999).contains(port.port) {
            score += 10
        }
        return score
    }

    private static func probeWebServices(
        _ ports: [PortInfo],
        completion: @escaping (Set<Int>) -> Void
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let group = DispatchGroup()
        let lock = NSLock()
        var responsivePorts = Set<Int>()

        for port in ports.prefix(48) {
            guard let url = URL(string: "http://127.0.0.1:\(port.port)/") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            group.enter()
            session.dataTask(with: request) { _, response, _ in
                if response is HTTPURLResponse {
                    lock.lock()
                    responsivePorts.insert(port.port)
                    lock.unlock()
                }
                group.leave()
            }.resume()
        }

        group.notify(queue: .main) {
            session.finishTasksAndInvalidate()
            completion(responsivePorts)
        }
    }

}

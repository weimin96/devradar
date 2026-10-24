import Foundation

struct ProcessTraffic: Identifiable, Hashable {
    let pid: Int
    let processName: String
    let downloadBytesPerSecond: Int
    let uploadBytesPerSecond: Int
    let downloadedDeltaBytes: UInt64
    let uploadedDeltaBytes: UInt64
    let downloadedBytes: UInt64
    let uploadedBytes: UInt64
    let directory: String?
    let projectDirectory: String?
    let executablePath: String?
    let command: String?
    let launchSourceName: String?
    let launchSourceBundlePath: String?
    let launchSourceBundleIdentifier: String?
    let connectionCount: Int
    let remoteEndpoints: [RemoteEndpoint]

    var id: Int { pid }

    var projectName: String? {
        guard let projectDirectory else { return nil }
        let url = URL(fileURLWithPath: projectDirectory)
        let name = url.lastPathComponent
        if name.first?.isNumber == true, name.contains(".") {
            let parentName = url.deletingLastPathComponent().lastPathComponent
            if !parentName.isEmpty {
                return parentName
            }
        }
        return name
    }
}

struct RemoteEndpoint: Identifiable, Hashable {
    let transport: String
    let address: String
    let state: String?

    var id: String { "\(transport):\(address):\(state ?? "")" }

    var isLocal: Bool {
        let value = host.lowercased()
        return value.hasPrefix("127.") || value == "::1" || value == "localhost"
    }

    var scopeLabel: String? {
        if isLocal { return "本机" }
        if isPrivateNetwork { return "局域网" }
        return nil
    }

    private var host: String {
        if address.hasPrefix("["), let closing = address.firstIndex(of: "]") {
            return String(address[address.index(after: address.startIndex)..<closing])
        }
        guard let colon = address.lastIndex(of: ":") else { return address }
        return String(address[..<colon])
    }

    private var isPrivateNetwork: Bool {
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        guard host.hasPrefix("172."),
              let second = Int(host.split(separator: ".").dropFirst().first ?? "") else {
            return false
        }
        return (16...31).contains(second)
    }
}

struct ApplicationTraffic: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePath: String?
    let bundleIdentifier: String?
    let launchSourceName: String?
    let processNames: [String]
    let pids: [Int]
    let downloadBytesPerSecond: Int
    var uploadBytesPerSecond: Int
    let downloadedBytes: UInt64
    let uploadedBytes: UInt64
    let projectDirectories: [String]
    let workingDirectories: [String]
    let connectionCount: Int
    let remoteEndpoints: [RemoteEndpoint]

    var processCount: Int { pids.count }
}

struct TrafficTotals: Codable, Hashable {
    var downloadedBytes: UInt64 = 0
    var uploadedBytes: UInt64 = 0

    static let zero = TrafficTotals()
}

struct HistoricalApplicationTraffic: Identifiable, Hashable {
    let id: String
    let name: String
    let bundlePath: String?
    let bundleIdentifier: String?
    let launchSourceName: String?
    let totals: TrafficTotals
}

struct OpenProjectFile: Identifiable, Hashable {
    let pid: Int
    let processName: String
    let path: String
    let projectDirectory: String?

    var id: String { "\(pid):\(path)" }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}


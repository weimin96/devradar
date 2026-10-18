import Darwin
import Foundation

struct DNSResolverInfo: Identifiable, Equatable {
    let id: String
    let domain: String?
    let nameservers: [String]
    let interface: String?
    let searchDomains: [String]
    let options: String?
    let scoped: Bool
}

enum DNSConfigurationReader {
    static func read() throws -> [DNSResolverInfo] {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        task.arguments = ["--dns"]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw DNSDiagnosticError.configurationUnavailable
        }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> [DNSResolverInfo] {
        var result: [DNSResolverInfo] = []
        var scoped = false
        var resolverNumber: String?
        var domain: String?
        var nameservers: [String] = []
        var searchDomains: [String] = []
        var interface: String?
        var options: String?

        func flush() {
            guard let resolverNumber, !nameservers.isEmpty || options != nil else { return }
            result.append(DNSResolverInfo(
                id: "\(scoped ? "scoped" : "default")-\(resolverNumber)",
                domain: domain,
                nameservers: nameservers,
                interface: interface,
                searchDomains: searchDomains,
                options: options,
                scoped: scoped
            ))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration (for scoped queries)") {
                flush()
                scoped = true
                resolverNumber = nil
                domain = nil
                nameservers = []
                searchDomains = []
                interface = nil
                options = nil
            } else if line.hasPrefix("resolver #") {
                flush()
                resolverNumber = String(line.dropFirst("resolver #".count))
                domain = nil
                nameservers = []
                searchDomains = []
                interface = nil
                options = nil
            } else if resolverNumber != nil, let separator = line.firstIndex(of: ":") {
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "domain": domain = value
                case let key where key.hasPrefix("nameserver["): nameservers.append(value)
                case let key where key.hasPrefix("search domain["): searchDomains.append(value)
                case "if_index": interface = value
                case "options": options = value
                default: break
                }
            }
        }
        flush()
        return result
    }
}

enum DNSDiagnosticError: LocalizedError {
    case invalidInput
    case configurationUnavailable
    case lookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput: "请输入合法域名或 IPv4 / IPv6 地址"
        case .configurationUnavailable: "无法读取系统 DNS 配置"
        case .lookupFailed(let description): "解析失败：\(description)"
        }
    }
}

struct DNSLookupResult {
    enum Kind {
        case forward
        case reverse
    }

    let query: String
    let kind: Kind
    let answers: [String]
    let elapsedMilliseconds: Int
}

enum DNSDiagnosticsEngine {
    static func validate(_ input: String) throws -> (query: String, isIPAddress: Bool) {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 253, !query.contains("://") else {
            throw DNSDiagnosticError.invalidInput
        }

        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if query.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 ||
            query.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return (query, true)
        }

        let canonical = query.hasSuffix(".") ? String(query.dropLast()) : query
        let labels = canonical.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 &&
                label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { byte in
                    (65...90).contains(byte) || (97...122).contains(byte) ||
                        (48...57).contains(byte) || byte == 45
                }
        }) else {
            throw DNSDiagnosticError.invalidInput
        }
        return (query, false)
    }

    static func lookup(_ input: String) throws -> DNSLookupResult {
        let (query, isIPAddress) = try validate(input)
        let started = Date()
        let answers = try isIPAddress ? reverse(query) : forward(query)
        return DNSLookupResult(
            query: query,
            kind: isIPAddress ? .reverse : .forward,
            answers: answers,
            elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1_000))
        )
    }

    // System resolver; can include /etc/hosts, cache, mDNS and VPN rules.
    // The result is not a wire-level DNS query log.
    private static func forward(_ domain: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(domain, nil, &hints, &first)
        guard code == 0 else {
            throw DNSDiagnosticError.lookupFailed(String(cString: gai_strerror(code)))
        }
        defer { if let first { freeaddrinfo(first) } }

        var answers: [String] = []
        var current = first
        while let entry = current?.pointee {
            if let address = entry.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, entry.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: buffer)
                    if !answers.contains(value) { answers.append(value) }
                }
            }
            current = entry.ai_next
        }
        return answers
    }

    private static func reverse(_ ip: String) throws -> [String] {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status: Int32
        if ip.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = ipv4
            status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else {
            guard ip.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else {
                throw DNSDiagnosticError.invalidInput
            }
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = ipv6
            status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
                }
            }
        }
        guard status == 0 else {
            throw DNSDiagnosticError.lookupFailed(String(cString: gai_strerror(status)))
        }
        return [String(cString: buffer)]
    }

    // Only explicit numeric endpoint formats are matchable. PTR results never
    // prove that a process queried a hostname, and shared IPs are ambiguous.
    static func endpointIP(_ endpoint: String) -> String? {
        let ip: String
        if endpoint.hasPrefix("["), let end = endpoint.firstIndex(of: "]") {
            ip = String(endpoint[endpoint.index(after: endpoint.startIndex)..<end])
            guard endpoint[endpoint.index(after: end)...].first == ":" else { return nil }
        } else {
            let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, UInt16(parts[1]) != nil else { return nil }
            ip = String(parts[0])
        }
        return (try? validate(ip)).flatMap { $0.isIPAddress ? $0.query : nil }
    }
}

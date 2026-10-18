import Foundation

@main
struct DNSDiagnosticsTests {
    static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
        }

        let config = """
        DNS configuration
        resolver #1
          nameserver[0] : 192.168.1.1
          nameserver[1] : 2001:db8::1
          search domain[0] : corp.example
          if_index : 14 (en0)
        resolver #2
          domain : corp.example
          nameserver[0] : 10.1.1.1
        resolver #3
          domain : local
          options : mdns
        DNS configuration (for scoped queries)
        resolver #1
          nameserver[0] : 192.168.1.1
          if_index : 14 (en0)
        """
        let resolvers = DNSConfigurationReader.parse(config)
        check(resolvers.count == 4, "parse default, domain-specific, mDNS and scoped resolvers")
        check(resolvers[0].nameservers == ["192.168.1.1", "2001:db8::1"], "keep IPv6 address intact")
        check(resolvers[0].searchDomains == ["corp.example"], "parse search domains")
        check(resolvers[1].domain == "corp.example", "parse supplemental domain")
        check(resolvers[2].domain == "local" && resolvers[2].options == "mdns", "mDNS resolver without nameservers")
        check(resolvers[3].scoped && resolvers[3].id != resolvers[0].id, "scoped IDs remain distinct")

        let domain = try DNSDiagnosticsEngine.validate("example.com")
        let ipv6 = try DNSDiagnosticsEngine.validate("2001:db8::1")
        let ipv4 = try DNSDiagnosticsEngine.validate("192.0.2.1")
        check(!domain.isIPAddress, "domain lookup")
        check(ipv6.isIPAddress, "IPv6 reverse lookup")
        check(ipv4.isIPAddress, "IPv4 reverse lookup")
        for input in ["", "https://example.com", "bad domain", "example..com", "-example.com", "example.com:443"] {
            do {
                _ = try DNSDiagnosticsEngine.validate(input)
                check(false, "invalid input rejected: \(input)")
            } catch DNSDiagnosticError.invalidInput {
                // expected
            }
        }

        check(DNSDiagnosticsEngine.endpointIP("192.0.2.1:443") == "192.0.2.1", "IPv4 endpoint")
        check(DNSDiagnosticsEngine.endpointIP("[2001:db8::1]:443") == "2001:db8::1", "IPv6 endpoint")
        check(DNSDiagnosticsEngine.endpointIP("example.com:443") == nil, "never infer IP from host")
        check(DNSDiagnosticsEngine.endpointIP("2001:db8::1:443") == nil, "reject ambiguous unbracketed IPv6")

        // Real system resolver smoke check; localhost has deterministic local addresses.
        let local = try DNSDiagnosticsEngine.lookup("localhost")
        check(local.kind == .forward && !local.answers.isEmpty, "system forward lookup")
        let reverseLoopback = try DNSDiagnosticsEngine.lookup("::1")
        check(reverseLoopback.kind == .reverse && !reverseLoopback.answers.isEmpty, "IPv6 reverse address is initialized")
        print("DNSDiagnosticsTests: all tests passed")
    }
}

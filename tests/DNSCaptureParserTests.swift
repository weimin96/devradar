import Foundation

@main
struct DNSCaptureParserTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fputs("FAILED: \(label)\n", stderr); exit(1) }
        }
        var parser = DNSCaptureParser()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        parser.ingest(
            line: "12:00:00 IP pid=1234 192.168.1.8.53210 > 192.168.1.1.53: 42531+ A? api.example.com. (33)",
            at: now
        )
        check(parser.events.count == 1, "DNS request recorded")
        check(parser.events[0].pid == 1234, "only explicitly supplied PID attributed")
        check(parser.events[0].domain == "api.example.com", "domain extracted")
        parser.ingest(
            line: "12:00:00 IP 192.168.1.1.53 > 192.168.1.8.53210: 42531 1/0/0 A 203.0.113.7 (49)",
            at: now.addingTimeInterval(0.023)
        )
        check(parser.events[0].answers == ["203.0.113.7"], "matched response address")
        check(parser.events[0].responseAt != nil, "response timestamp retained")
        parser.ingest(
            line: "12:00:01 IP 192.168.1.8.53211 > 192.168.1.1.53: 42532+ AAAA? ipv6.example. (31)",
            at: now.addingTimeInterval(1)
        )
        parser.ingest(
            line: "12:00:01 IP 192.168.1.1.53 > 192.168.1.8.53211: 42532 1/0/0 AAAA 2001:db8::12 (62)",
            at: now.addingTimeInterval(1.05)
        )
        check(parser.events[0].answers == ["2001:db8::12"], "IPv6 response")
        check(parser.events[0].pid == nil, "no false PID when metadata unavailable")
        parser.ingest(
            line: "12:00:02 IP 192.168.1.1.53 > 192.168.1.8.53210: 42531 1/0/0 A 192.0.2.99 (49)",
            at: now.addingTimeInterval(2)
        )
        check(parser.events[1].answers == ["203.0.113.7"], "duplicate response does not reassign query")
        parser.ingest(
            line: "12:00:02 IP 192.168.1.8.53212 > 192.168.1.1.53: 42533+ A? unknown.test. (33)",
            at: now.addingTimeInterval(2)
        )
        parser.ingest(
            line: "12:00:02 IP 192.168.1.1.53 > 192.168.1.8.53212: 42533 NXDomain 0/1/0 (98)",
            at: now.addingTimeInterval(2.04)
        )
        check(parser.events[0].responseStatus == "NXDOMAIN", "negative response")
        check(parser.events[0].answers.isEmpty, "no invented address for NXDOMAIN")
        parser.reset()
        check(parser.events.isEmpty && parser.packetsSeen == 0, "clear resets capture session")
        print("DNSCaptureParserTests: all tests passed")
    }
}

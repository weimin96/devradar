import Foundation

@main
struct HTTPSConnectionTrackerTests {
    static func main() {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
        }
        let first = Date(timeIntervalSince1970: 1_760_000_000)
        var tracker = HTTPSConnectionTracker(pids: [871])
        let header = ",bytes_in,bytes_out,"
        check(tracker.consume(line: header, at: first), "header recognized")
        _ = tracker.consume(line: "WeType.871,2027630,5063361,", at: first)
        _ = tracker.consume(
            line: "tcp4 192.168.1.104:49278<->120.233.18.62:443,1042655,2730873,",
            at: first
        )
        _ = tracker.consume(
            line: "tcp4 192.168.1.104:49253<->120.233.18.62:443,984975,2332488,",
            at: first
        )
        check(tracker.observed443Connections.count == 2, "two independent HTTPS candidates")
        check(tracker.monitoredUploadBytes == 0, "initial cumulative totals are baseline only")
        let export = try! HTTPSConnectionReport.encode(
            applicationName: "WeType", connections: tracker.observed443Connections,
            now: first
        )
        let report = String(decoding: export, as: UTF8.self)
        check(report.contains("120.233.18.62:443") && report.contains("not decrypted"),
              "metadata-only report includes address and decryption caveat")
        check(!report.contains("requestBody") && !report.contains("headers"),
              "report excludes HTTPS application content")
        _ = tracker.consume(line: header, at: first.addingTimeInterval(2))
        _ = tracker.consume(line: "WeType.871,2029010,5066829,", at: first.addingTimeInterval(2))
        _ = tracker.consume(
            line: "tcp4 192.168.1.104:49278<->120.233.18.62:443,1043147,2732511,",
            at: first.addingTimeInterval(2)
        )
        _ = tracker.consume(
            line: "tcp4 192.168.1.104:49253<->120.233.18.62:443,985863,2334318,",
            at: first.addingTimeInterval(2)
        )
        check(tracker.monitoredUploadBytes == 3468, "actual socket byte counter delta")
        check(tracker.observed443Connections.map(\.uploadedBytes).sorted() == [1638, 1830],
              "per-flow outgoing-byte accounting")
        _ = tracker.consume(line: header, at: first.addingTimeInterval(4))
        _ = tracker.consume(line: "OtherApp.9999,99,99,", at: first.addingTimeInterval(4))
        _ = tracker.consume(
            line: "tcp4 192.168.1.104:50000<->203.0.113.99:443,3000,9999,",
            at: first.addingTimeInterval(4)
        )
        check(tracker.observed443Connections.count == 2, "other process is not attributed")
        _ = tracker.consume(line: header, at: first.addingTimeInterval(6))
        _ = tracker.consume(line: "WeType.871,100,200,", at: first.addingTimeInterval(6))
        _ = tracker.consume(
            line: "udp4 192.168.1.104:32000<->2001:db8::1:443,0,500,",
            at: first.addingTimeInterval(6)
        )
        check(tracker.observed443Connections.count == 3, "QUIC/UDP 443 included")
        check(tracker.observed443Connections.contains(where: { $0.protocolLabel.contains("QUIC") }),
              "UDP QUIC candidate classified cautiously")
        _ = tracker.consume(line: header, at: first.addingTimeInterval(36))
        check(tracker.observed443Connections.count == 1, "stale socket entries aged out")
        print("HTTPSConnectionTrackerTests: all tests passed")
    }
}

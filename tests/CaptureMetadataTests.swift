import Foundation

@main
struct CaptureMetadataTests {
    static func main() throws {
        func assert(_ condition: @autoclosure () -> Bool, _ reason: String) {
            if !condition() {
                fputs("FAILED: \(reason)\n", stderr)
                exit(1)
            }
        }

        var accumulator = PacketLineAccumulator()
        accumulator.ingest(Data("IP 10.0.0.1.1000 > 1.1.1.1.443".utf8))
        assert(accumulator.count == 0, "partial packet must not count yet")
        accumulator.ingest(Data(": Flags [S]\nsecond packet\nthird".utf8))
        assert(accumulator.count == 2, "first two complete records counted once")
        accumulator.ingest(Data(" packet\n".utf8))
        assert(accumulator.count == 3, "split record completed without duplication")
        assert(accumulator.lines[2] == "third packet", "partial line preserved")
        let many = (0..<750).map { "packet \($0)" }.joined(separator: "\n") + "\n"
        accumulator.ingest(Data(many.utf8))
        assert(accumulator.count == 753, "running packet count unaffected by retention")
        assert(accumulator.lines.count == 500, "only retain bounded recent lines")
        assert(accumulator.lines.last == "packet 749", "most recent packet retained")

        let records = [
            ProxySessionExport.Record(
                type: "request",
                timestamp: "2026-10-18T08:00:00Z", method: "POST", host: "api.example.com",
                status: 202, durationMs: 17, uploadBytes: 35, downloadBytes: 24,
                attribution: "unverified"
            )
        ]
        let encoded = try ProxySessionExport.encode(
            records: records, totalRequests: 4,
            now: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let text = String(decoding: encoded, as: UTF8.self)
        assert(text.contains("\"totalRequests\" : 4"), "complete session count exported")
        assert(text.contains("unverified"), "unattributed scope persisted")
        assert(!text.contains("preview") && !text.contains("path") &&
               !text.contains("cookie") && !text.contains("requestBody"),
               "export excludes secret-bearing request content")
        print("CaptureMetadataTests: all tests passed")
    }
}

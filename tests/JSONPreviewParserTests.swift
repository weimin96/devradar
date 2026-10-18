import Foundation

@main
struct JSONPreviewParserTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else {
                fputs("FAIL: \(message)\n", stderr)
                exit(1)
            }
        }

        let simple = JSONPreviewDocument.parse(#"{"message":"ok","nested":{"enabled":true,"tags":[1,2]}}"#)
        check(simple.values.count == 1, "single JSON object")
        check(simple.remainingText.isEmpty, "single JSON has no trailing text")
        check(simple.prettyText.contains("\n"), "pretty-printed JSON has indentation")
        if case .object(let entries) = simple.values[0] {
            check(entries.count == 2, "object field count")
        } else {
            check(false, "object tree type")
        }

        let stream = JSONPreviewDocument.parse(
            #""# + #"{"message":"first","value":{"hello":"{world}","quote":"escaped \"brace}\""}}"#
            + "\n" + #"{"message":"second","list":[true,false,null]}"#
            + #"{"message":"third"}"#
        )
        check(stream.values.count == 3, "contiguous objects and NDJSON")
        check(stream.remainingText.isEmpty, "stream parsed without loss")
        check(stream.prettyText.contains("first") && stream.prettyText.contains("third"), "all objects retained")

        let truncated = JSONPreviewDocument.parse(#"{"a":1}{"b":{"incomplete":"#)
        check(truncated.values.count == 1, "complete object before truncated tail retained")
        check(truncated.remainingText.hasPrefix(#"{"b""#), "truncated JSON tail preserved")
        check(truncated.prettyText.contains("incomplete"), "truncated tail shown in text mode")

        let invalid = JSONPreviewDocument.parse("plain log text: not json")
        check(invalid.values.isEmpty && invalid.remainingText == "plain log text: not json",
              "non-JSON text unchanged")

        let escaped = JSONPreviewDocument.parse(#"{"nested":{"k":"hello \"quote\" and } brace"}}"#)
        check(escaped.values.count == 1, "escaped quotes inside nested strings")

        print("JSONPreviewParser: all tests passed")
    }
}

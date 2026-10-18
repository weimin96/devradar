import CoreFoundation
import Foundation

/// Parses the already-redacted, size-limited preview emitted by the capture
/// proxy. In addition to a single JSON document, some telemetry endpoints
/// concatenate multiple JSON objects or use newline-delimited JSON.
enum JSONPreviewValue {
    case object([(String, JSONPreviewValue)])
    case array([JSONPreviewValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null

    var summary: String {
        switch self {
        case .object(let children): return "{ \(children.count) 个字段 }"
        case .array(let children): return "[ \(children.count) 个元素 ]"
        case .string(let text): return String(reflecting: text)
        case .number(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    var isExpandable: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    var children: [(key: String, value: JSONPreviewValue)] {
        switch self {
        case .object(let entries):
            return entries.map { (key: $0.0, value: $0.1) }
        case .array(let entries):
            return entries.enumerated().map { (key: "[\($0.offset)]", value: $0.element) }
        default:
            return []
        }
    }

    static func make(from value: Any, depth: Int = 0) -> JSONPreviewValue {
        guard depth < 32 else { return .string("[层级过深]") }
        if value is NSNull { return .null }
        if let object = value as? [String: Any] {
            return .object(object.keys.sorted().map { key in
                (key, .make(from: object[key]!, depth: depth + 1))
            })
        }
        if let array = value as? [Any] {
            return .array(array.map { .make(from: $0, depth: depth + 1) })
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .number(number.stringValue)
        }
        if let text = value as? String { return .string(text) }
        return .string(String(describing: value))
    }
}

struct JSONPreviewDocument {
    let values: [JSONPreviewValue]
    let prettyText: String
    let remainingText: String

    var hasJSON: Bool { !values.isEmpty }

    /// Keep the unparseable tail visible. Proxy previews are capped at 2 KB
    /// and the final JSON object may legitimately be cut off.
    static func parse(_ text: String) -> JSONPreviewDocument {
        let chars = Array(text)
        var position = 0
        var values: [JSONPreviewValue] = []
        var pretty: [String] = []

        while position < chars.count {
            while position < chars.count && chars[position].isWhitespace { position += 1 }
            if position == chars.count { break }
            let start = position
            let first = chars[position]
            guard first == "{" || first == "[" else { break }

            var stack: [Character] = []
            var inString = false
            var escaped = false
            var completed = false
            while position < chars.count {
                let character = chars[position]
                position += 1
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                    continue
                }
                switch character {
                case "\"": inString = true
                case "{", "[": stack.append(character)
                case "}", "]":
                    guard let opening = stack.popLast(),
                          (opening == "{" && character == "}") ||
                          (opening == "[" && character == "]") else {
                        position = start
                        break
                    }
                    if stack.isEmpty { completed = true }
                default: break
                }
                if completed { break }
                if position == start { break }
            }
            guard completed else {
                position = start
                break
            }
            let fragment = String(chars[start..<position])
            guard let data = fragment.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let formatted = try? JSONSerialization.data(
                    withJSONObject: json,
                    options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
                  ),
                  let formattedText = String(data: formatted, encoding: .utf8) else {
                position = start
                break
            }
            values.append(.make(from: json))
            pretty.append(formattedText)
        }

        // JSON scalar previews are unusual, but valid application/json.
        if values.isEmpty, let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let formatted = try? JSONSerialization.data(
               withJSONObject: json,
               options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
           ), let formattedText = String(data: formatted, encoding: .utf8) {
            return JSONPreviewDocument(
                values: [.make(from: json)],
                prettyText: formattedText,
                remainingText: ""
            )
        }
        let remaining = String(chars[position...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let formatted = (pretty + (remaining.isEmpty ? [] : [remaining])).joined(separator: "\n\n")
        return JSONPreviewDocument(values: values, prettyText: formatted, remainingText: remaining)
    }
}

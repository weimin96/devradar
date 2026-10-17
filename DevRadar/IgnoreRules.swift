import Foundation

enum IgnoreRules {
    static let projectsKey = "ignoredProjectDirectories"
    static let portsKey = "ignoredPorts"
    static let networkApplicationsKey = "ignoredNetworkApplications"

    static func strings(from rawValue: String) -> Set<String> {
        guard let data = rawValue.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    static func ports(from rawValue: String) -> Set<Int> {
        Set(strings(from: rawValue).compactMap(Int.init))
    }

    static func adding(_ value: String, to rawValue: String) -> String {
        var values = strings(from: rawValue)
        values.insert(value)
        return encode(values)
    }

    static func adding(port: Int, to rawValue: String) -> String {
        adding(String(port), to: rawValue)
    }

    static func encode(_ values: Set<String>) -> String {
        let sorted = values.sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

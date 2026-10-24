import Foundation

/// Upload counters from nettop's non-loopback interface filter. Process
/// summaries retain the system's accounting instead of summing live sockets.
enum NettopUploadRates {
    enum ParseError: LocalizedError {
        case columns
        case counter(Int)

        var errorDescription: String? {
            switch self {
            case .columns: return "网络监控列顺序不受支持，已跳过本次采样"
            case .counter(let pid): return "进程 \(pid) 的上传计数无效，已跳过本次采样"
            }
        }
    }

    static func arguments(interval: Int, externalOnly: Bool) -> [String] {
        ["-P", "-n", "-x", "-d", "-L", "0", "-J", "bytes_in,bytes_out", "-s", String(interval), "-c"] +
            (externalOnly ? ["-t", "external"] : [])
    }

    static func parse(_ lines: [String], interval: Int) throws -> [Int: Int] {
        var rates: [Int: Int] = [:]
        for rawLine in lines {
            let fields = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            if fields[0].isEmpty {
                guard fields[1] == "bytes_in", fields[2] == "bytes_out" else { throw ParseError.columns }
                continue
            }
            guard !fields[0].contains("<->"),
                  let pid = fields[0].split(separator: ".").last.flatMap({ Int($0) }) else { continue }
            guard let bytes = Int(fields[2]) else { throw ParseError.counter(pid) }
            rates[pid, default: 0] += max(0, bytes) / interval
        }
        return rates
    }
}

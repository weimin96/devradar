import Darwin
import Foundation

@main
struct NettopUploadRatesTests {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
        }
        let rates = try NettopUploadRates.parse([
            ",bytes_in,bytes_out,", "short.upload.42,200,24000000,",
            "downloader.43,24000000,0,", "quic.uploader.44,200,24000000,"
        ], interval: 2)
        check(rates[42] == 12_000_000, "进程汇总有上传量时，不得因存活 socket 列表为空而漏计")
        check(rates[43] == 0 && rates[44] == 12_000_000, "下载和 UDP 上传须按对应方向解析")
        let empty = try NettopUploadRates.parse([",bytes_in,bytes_out,"], interval: 2)
        check(empty.isEmpty, "空帧不得沿用前一帧速率")
        do {
            _ = try NettopUploadRates.parse([",bytes_out,bytes_in,"], interval: 2)
            check(false, "不支持的列顺序必须显式报错")
        } catch NettopUploadRates.ParseError.columns {}
        do {
            _ = try NettopUploadRates.parse(["uploader.42,0,12 MiB,"], interval: 2)
            check(false, "无效发送计数必须显式报错")
        } catch NettopUploadRates.ParseError.counter(42) {}

        let receiver = socket(AF_INET, SOCK_DGRAM, 0)
        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        guard receiver >= 0, sender >= 0 else { throw POSIXError(.EIO) }
        defer { close(receiver); close(sender) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(receiver, $0, size) }
        }
        check(bound == 0, "绑定本机 UDP 验证端口")
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(receiver, $0, &size) }
        }
        check(named == 0, "读取验证端口")
        let payload = [UInt8](repeating: 0, count: 6000)
        var received = payload
        for _ in 0..<10 {
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sender, payload, payload.count, 0, $0, size)
                }
            }
            check(sent == payload.count && recv(receiver, &received, received.count, 0) == payload.count,
                  "完成受控的本机 UDP 收发")
        }
        func sample(externalOnly: Bool) throws -> [Int: Int] {
            let task = Process()
            let output = Pipe()
            var arguments = NettopUploadRates.arguments(interval: 1, externalOnly: externalOnly)
            arguments[arguments.firstIndex(of: "-L")! + 1] = "1"
            task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            task.arguments = arguments + ["-p", String(getpid())]
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            check(task.terminationStatus == 0, "系统接口过滤采样成功")
            return try NettopUploadRates.parse(String(decoding: data, as: UTF8.self).components(separatedBy: .newlines), interval: 1)
        }
        let all = try sample(externalOnly: false)
        let external = try sample(externalOnly: true)
        check((all[Int(getpid())] ?? 0) >= 60_000, "原进程口径确实包含本机 UDP 发送量")
        check((external[Int(getpid())] ?? 0) == 0, "通配地址 UDP 的回环流量不得计入上传告警")
        print("上传通知：方向、短连接汇总、异常计数和真实 UDP 回环过滤验证通过")
    }
}

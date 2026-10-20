import Darwin
import Foundation

nonisolated final class ProjectCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func cancel() { lock.lock(); requested = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

nonisolated struct ProjectCommandResult: Sendable {
    let output: Data
    let errorOutput: Data
    let exitCode: Int32
    let cancelled: Bool
    let timedOut: Bool
    let truncated: Bool

    func checked() throws -> Data {
        guard !cancelled else { throw ProjectError.message("操作已取消，请刷新确认实际状态") }
        guard !timedOut else { throw ProjectError.message("命令执行超时，请检查网络或在终端中处理") }
        guard exitCode == 0 else {
            let detail = String(decoding: errorOutput.isEmpty ? output : errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProjectError.message(detail.isEmpty ? "命令执行失败，退出码 \(exitCode)" : detail)
        }
        guard !truncated else { throw ProjectError.message("命令输出过大，无法完整读取结果") }
        return output
    }
}

nonisolated enum ProjectCommand {
    // Each invocation owns a process group. Cancellation never uses a persisted PID.
    static func run(
        executable: String, arguments: [String], directory: String,
        environment: [String: String] = [:], timeout: TimeInterval? = 60,
        cancellation: ProjectCancellation = ProjectCancellation(),
        onStarted: (() -> Void)? = nil, onOutput: ((Data) -> Void)? = nil
    ) throws -> ProjectCommandResult {
        try ProjectStore.checkDirectory(directory)
        if cancellation.isCancelled { throw ProjectError.message("操作已取消，请刷新确认实际状态") }
        var outputPipe: [Int32] = [0, 0]
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0 else { throw systemError("创建输出管道", errno) }
        defer { outputPipe.forEach { close($0) } }
        guard pipe(&errorPipe) == 0 else { throw systemError("创建错误管道", errno) }
        defer { errorPipe.forEach { close($0) } }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions), "初始化进程文件操作")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes), "初始化进程属性")
        defer { posix_spawnattr_destroy(&attributes) }
        if #available(macOS 26, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, directory), "设置工作目录")
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, directory), "设置工作目录")
        }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "设置标准输入")
        try check(posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO), "设置标准输出")
        try check(posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO), "设置错误输出")
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)), "设置进程组")
        try check(posix_spawnattr_setpgroup(&attributes, 0), "创建进程组")
        var values = ProcessInfo.processInfo.environment
        values.merge(environment) { _, value in value }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = values.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable, &actions, &attributes, argv, envp), "启动命令")
        onStarted?()
        // The parent must close its writers for EOF detection; remove them from deferred cleanup.
        close(outputPipe[1]); outputPipe[1] = -1
        close(errorPipe[1]); errorPipe[1] = -1
        for descriptor in [outputPipe[0], errorPipe[0]] {
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
                kill(-pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                throw systemError("设置输出管道", errno)
            }
        }

        let started = Date()
        var stoppedAt: Date?
        var timedOut = false
        var status: Int32 = 0
        var output = Data()
        var errors = Data()
        var truncated = false
        let limit = 1_048_576
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var reaped = false
        defer {
            if !reaped {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        while true {
            if stoppedAt == nil && (cancellation.isCancelled || timeout.map { Date().timeIntervalSince(started) >= $0 } == true) {
                timedOut = !cancellation.isCancelled
                stoppedAt = Date()
                kill(-pid, SIGTERM)
            }
            if let stoppedAt, Date().timeIntervalSince(stoppedAt) >= 2 { kill(-pid, SIGKILL) }
            for (index, descriptor) in [outputPipe[0], errorPipe[0]].enumerated() {
                // Bound each drain so an unending output stream cannot starve cancellation.
                for _ in 0..<16 {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count < 0 {
                        if errno == EAGAIN || errno == EINTR { break }
                        throw systemError("读取命令输出", errno)
                    }
                    if count == 0 { break }
                    let chunk = Data(buffer.prefix(count))
                    onOutput?(chunk)
                    if index == 0 { output.append(chunk) } else { errors.append(chunk) }
                    if output.count > limit { output.removeFirst(output.count - limit); truncated = true }
                    if errors.count > limit { errors.removeFirst(errors.count - limit); truncated = true }
                }
            }
            // Observe exit without reaping, retaining process-group identity while cleaning descendants.
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1 {
                if errno == EINTR { continue }
                throw systemError("读取进程状态", errno)
            }
            if info.si_pid != 0 {
                kill(-pid, SIGKILL)
                // Drain the final bytes after the parent exits.
                for (index, descriptor) in [outputPipe[0], errorPipe[0]].enumerated() {
                    while true {
                        let count = read(descriptor, &buffer, buffer.count)
                        if count <= 0 { break }
                        let chunk = Data(buffer.prefix(count))
                        onOutput?(chunk)
                        if index == 0 { output.append(chunk) } else { errors.append(chunk) }
                        if output.count > limit { output.removeFirst(output.count - limit); truncated = true }
                        if errors.count > limit { errors.removeFirst(errors.count - limit); truncated = true }
                    }
                }
                while waitpid(pid, &status, 0) == -1 {
                    if errno != EINTR { throw systemError("回收进程", errno) }
                }
                reaped = true
                break
            }
            usleep(30_000)
        }
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return ProjectCommandResult(output: output, errorOutput: errors, exitCode: exitCode,
                                    cancelled: cancellation.isCancelled, timedOut: timedOut, truncated: truncated)
    }

    private static func check(_ code: Int32, _ operation: String) throws {
        if code != 0 { throw systemError(operation, code) }
    }

    private static func systemError(_ operation: String, _ code: Int32) -> ProjectError {
        .message("\(operation)失败：\(String(cString: strerror(code)))")
    }
}

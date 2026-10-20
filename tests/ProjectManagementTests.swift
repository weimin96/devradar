import Darwin
import Foundation

@main
struct ProjectManagementTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProjectError.message(message) }
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw ProjectError.message(message)
    }

    static func git(_ arguments: [String], at directory: URL) throws -> String {
        String(decoding: try ProjectGit.command(arguments, at: directory.path), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    @MainActor
    static func main() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("DevRadar 项目验证 \(UUID())")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try configuration(in: workspace)
        try synchronization(in: workspace)
        try execution(in: workspace)
        try await lifecycle(in: workspace)
        print("ProjectManagement: configuration, Git synchronization and process lifecycle passed")
    }

    static func configuration(in workspace: URL) throws {
        let store = ProjectStore(url: workspace.appendingPathComponent("配置/projects.json"))
        try expect(try store.load().isEmpty, "missing configuration starts empty")
        let task = ProjectTask(name: "打印路径", command: "pwd")
        let project = ManagedProject(name: "中文项目", directory: workspace.path, tasks: [task])
        try ProjectStore.validate(project, among: [])
        try store.save([project])
        try expect(try store.load() == [project], "project and task identities survive reload")
        let duplicate = ManagedProject(name: "重复目录", directory: workspace.appendingPathComponent(".").path)
        try rejects("duplicate canonical directory must be rejected") { try ProjectStore.validate(duplicate, among: [project]) }
        try rejects("relative directory cannot escape project") {
            _ = try project.workingDirectory(for: ProjectTask(command: "pwd", directory: ".."))
        }
        let link = workspace.appendingPathComponent("外部目录")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace.deletingLastPathComponent())
        try rejects("symlink directory cannot escape project") {
            _ = try project.workingDirectory(for: ProjectTask(command: "pwd", directory: "外部目录"))
        }
        try rejects("empty commands must be rejected") { _ = try project.workingDirectory(for: ProjectTask()) }
        try Data("invalid json".utf8).write(to: store.url)
        try rejects("corrupt configuration must be reported") { _ = try store.load() }
        try expect(try Data(contentsOf: store.url) == Data("invalid json".utf8), "failed load does not overwrite configuration")
        print("PASS: configuration roundtrip, duplicate paths, symlink escape, corrupt data")
    }

    static func synchronization(in workspace: URL) throws {
        let remote = workspace.appendingPathComponent("远端.git")
        let first = workspace.appendingPathComponent("项目 一")
        let second = workspace.appendingPathComponent("项目 二")
        _ = try git(["init", "--bare", "--initial-branch=main", remote.path], at: workspace)
        _ = try git(["clone", remote.path, first.path], at: workspace)
        for directory in [first] {
            _ = try git(["config", "user.name", "DevRadar QA"], at: directory)
            _ = try git(["config", "user.email", "devradar-qa@example.invalid"], at: directory)
        }
        try Data("initial".utf8).write(to: first.appendingPathComponent("文件.txt"))
        _ = try git(["add", "."], at: first)
        _ = try git(["commit", "-m", "initial"], at: first)
        _ = try git(["push", "-u", "origin", "main"], at: first)
        _ = try git(["clone", remote.path, second.path], at: workspace)
        _ = try git(["config", "user.name", "DevRadar QA"], at: second)
        _ = try git(["config", "user.email", "devradar-qa@example.invalid"], at: second)

        let renamed = "改名\n# branch.head fake.txt"
        _ = try git(["mv", "文件.txt", renamed], at: first)
        try Data("untracked".utf8).write(to: first.appendingPathComponent("未跟踪\n空 格.txt"))
        let dirty = try ProjectGit.snapshot(at: first.path)
        try expect(dirty.changedFiles == 2 && dirty.branch == "main", "NUL parser handles rename and newline filenames")
        let target = try ProjectGit.target(at: first.path, action: .pull)
        try rejects("dirty worktree must block pull") {
            try ProjectGit.perform(.pull, target: target, at: first.path, cancellation: ProjectCancellation())
        }
        _ = try git(["add", "."], at: first)
        _ = try git(["commit", "-m", "rename"], at: first)
        try expect(try ProjectGit.snapshot(at: first.path).ahead == 1, "ahead commit count")
        try ProjectGit.perform(.push, target: ProjectGit.target(at: first.path, action: .push), at: first.path, cancellation: ProjectCancellation())
        try ProjectGit.perform(.fetch, target: ProjectGit.target(at: second.path, action: .fetch), at: second.path, cancellation: ProjectCancellation())
        try expect(try ProjectGit.snapshot(at: second.path).behind == 1, "fetch updates tracking state")
        try ProjectGit.perform(.pull, target: ProjectGit.target(at: second.path, action: .pull), at: second.path, cancellation: ProjectCancellation())
        try expect(try git(["rev-parse", "HEAD"], at: first) == git(["rev-parse", "HEAD"], at: second), "fast-forward updates exact commit")

        let staleTarget = try ProjectGit.target(at: second.path, action: .push)
        _ = try git(["config", "branch.main.merge", "refs/heads/other"], at: second)
        try rejects("changed target must be rejected") {
            try ProjectGit.perform(.push, target: staleTarget, at: second.path, cancellation: ProjectCancellation())
        }
        _ = try git(["config", "branch.main.merge", "refs/heads/main"], at: second)
        for (directory, name) in [(first, "远端变更"), (second, "本地变更")] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
            _ = try git(["add", "."], at: directory)
            _ = try git(["commit", "-m", name], at: directory)
        }
        try ProjectGit.perform(.push, target: ProjectGit.target(at: first.path, action: .push), at: first.path, cancellation: ProjectCancellation())
        let before = try git(["rev-parse", "HEAD"], at: second)
        try rejects("diverged branches must not merge automatically") {
            try ProjectGit.perform(.pull, target: ProjectGit.target(at: second.path, action: .pull), at: second.path, cancellation: ProjectCancellation())
        }
        try expect(try git(["rev-parse", "HEAD"], at: second) == before, "failed pull preserves local HEAD")
        try rejects("non-fast-forward push must fail without force") {
            try ProjectGit.perform(.push, target: ProjectGit.target(at: second.path, action: .push), at: second.path, cancellation: ProjectCancellation())
        }
        _ = try git(["checkout", "--detach"], at: second)
        try rejects("detached HEAD must not push") { _ = try ProjectGit.target(at: second.path, action: .push) }
        print("PASS: real bare remote, rename parsing, fetch/pull/push, dirty worktree, target changes, divergence, detached HEAD")
    }

    @MainActor
    static func lifecycle(in workspace: URL) async throws {
        let store = ProjectStore(url: workspace.appendingPathComponent("生命周期/projects.json"))
        let manager = ProjectManager(store: store)
        let task = ProjectTask(name: "持续运行", command: "/bin/sleep 30")
        let secondTask = ProjectTask(name: "独立运行", command: "/bin/sleep 31")
        let project = ManagedProject(name: "任务生命周期", directory: workspace.path, tasks: [task, secondTask])
        try manager.save(project)
        manager.start(task, in: project)
        guard let run = manager.runs[task.id] else { throw ProjectError.message("run was not created") }
        manager.start(task, in: project)
        try expect(manager.runs[task.id]?.id == run.id, "duplicate launch retains the original run")
        manager.start(secondTask, in: project)
        guard let secondRun = manager.runs[secondTask.id] else { throw ProjectError.message("second run was not created") }
        defer { manager.stopForQuit() }
        try expect(secondRun.id != run.id && run.active && secondRun.active, "multiple tasks in the same project run independently")
        run.stop()
        let stopDeadline = Date().addingTimeInterval(5)
        while run.active && Date() < stopDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try expect(!run.active && run.state == "已停止" && secondRun.active && !secondRun.cancellation.isCancelled,
                   "stopping one task leaves the other task running")
        try rejects("running project cannot be edited") { try manager.save(project) }
        manager.stopForQuit()
        let deadline = Date().addingTimeInterval(5)
        while manager.hasActiveWork && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try expect(!manager.hasActiveWork && run.state == "已停止" && secondRun.state == "已停止", "quit cancels queued or running work and converges")
        manager.start(task, in: project)
        try expect(manager.runs[task.id]?.id == run.id, "quitting prevents new runs")
        let log = ProjectLog()
        log.append(Data(repeating: 65, count: 150_000))
        try expect(log.text.hasPrefix("仅保留最近") && log.text.count < 132_000, "display log retention is bounded")
        try Data("broken".utf8).write(to: store.url)
        let broken = ProjectManager(store: store)
        try expect(broken.loadFailed, "load failure is exposed")
        try rejects("load failure must block overwriting stored projects") { try broken.save(project) }
        try expect(try Data(contentsOf: store.url) == Data("broken".utf8), "failed load preserves source file")
        print("PASS: duplicate launch, edit guard, quit lifecycle, log limit, failed-load write protection")
    }

    static func execution(in workspace: URL) throws {
        let result = try ProjectCommand.run(executable: "/bin/zsh", arguments: ["-lc", "pwd; printf '错误输出' >&2"], directory: workspace.path)
        try expect(result.exitCode == 0 && String(decoding: result.output, as: UTF8.self).contains(workspace.path), "working directory with unicode and spaces")
        try expect(String(decoding: result.errorOutput, as: UTF8.self) == "错误输出", "stderr retained separately")
        let failed = try ProjectCommand.run(executable: "/bin/zsh", arguments: ["-c", "exit 7"], directory: workspace.path)
        try expect(failed.exitCode == 7, "failure exit code retained")
        let timeout = try ProjectCommand.run(executable: "/bin/sleep", arguments: ["10"], directory: workspace.path, timeout: 0.15)
        try expect(timeout.timedOut, "long commands time out")
        let cancellation = ProjectCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { cancellation.cancel() }
        let stopped = try ProjectCommand.run(executable: "/bin/zsh",
            arguments: ["-c", "sleep 30 & child=$!; printf '%s' $child > child.pid; wait"],
            directory: workspace.path, timeout: 3, cancellation: cancellation)
        let childText = try String(contentsOf: workspace.appendingPathComponent("child.pid"), encoding: .utf8)
        guard let child = Int32(childText) else { throw ProjectError.message("missing child PID") }
        for _ in 0..<50 { if kill(child, 0) == -1 { break }; usleep(20_000) }
        try expect(stopped.cancelled && kill(child, 0) == -1 && errno == ESRCH, "cancellation also stops child process")
        let large = try ProjectCommand.run(executable: "/bin/zsh", arguments: ["-c", "head -c 1200000 /dev/zero"], directory: workspace.path)
        try expect(large.truncated && large.output.count == 1_048_576, "output retention is bounded")
        print("PASS: real shell, stderr, exit status, timeout, child cleanup, bounded output")
    }
}

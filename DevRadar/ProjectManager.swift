import AppKit
import Observation

nonisolated final class ProjectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var truncated = false

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(data)
        if bytes.count > 131_072 { bytes.removeFirst(bytes.count - 131_072); truncated = true }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return (truncated ? "仅保留最近 128 KB 日志\n" : "") + String(decoding: bytes, as: UTF8.self)
    }
}

@MainActor
@Observable
final class ProjectRun: Identifiable {
    let id = UUID()
    let projectID: UUID
    let task: ProjectTask
    let log = ProjectLog()
    let cancellation = ProjectCancellation()
    var state = "启动中"
    var active = true

    init(projectID: UUID, task: ProjectTask) {
        self.projectID = projectID; self.task = task
    }

    func stop() { state = "停止中"; cancellation.cancel() }
}

struct ProjectGitRequest: Identifiable {
    let id = UUID()
    let project: ManagedProject
    let action: ProjectGitAction
    let target: ProjectGitTarget
}

@MainActor
@Observable
final class ProjectManager {
    static let shared = ProjectManager()
    private(set) var projects: [ManagedProject] = []
    var error: String?
    private(set) var loadFailed = false
    private(set) var runs: [UUID: ProjectRun] = [:]
    private(set) var gitStates: [UUID: ProjectGitSnapshot] = [:]
    private(set) var gitMessages: [UUID: String] = [:]
    private(set) var gitProjectID: UUID?
    private var gitCancellation: ProjectCancellation?
    var gitRequest: ProjectGitRequest?
    private(set) var isQuitting = false
    private let store: ProjectStore

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
        reload()
    }

    func reload() {
        do { projects = try store.load(); loadFailed = false; error = nil }
        catch { loadFailed = true; self.error = "无法读取项目配置：\(error.localizedDescription)" }
    }

    func save(_ project: ManagedProject) throws {
        guard !loadFailed else { throw ProjectError.message("请先修复项目配置文件并重新读取") }
        guard !isBusy(project) else { throw ProjectError.message("请先停止该项目的任务并等待 Git 操作结束") }
        try ProjectStore.validate(project, among: projects)
        var updated = projects
        if let index = updated.firstIndex(where: { $0.id == project.id }) { updated[index] = project }
        else { updated.append(project) }
        try store.save(updated)
        projects = updated
        gitStates[project.id] = nil; gitMessages[project.id] = nil
    }

    func remove(_ project: ManagedProject) {
        do {
            guard !loadFailed, !isBusy(project) else { throw ProjectError.message("项目当前不可移除") }
            let updated = projects.filter { $0.id != project.id }
            try store.save(updated)
            projects = updated
            gitStates[project.id] = nil; gitMessages[project.id] = nil
            runs = runs.filter { $0.value.projectID != project.id }
        } catch { self.error = error.localizedDescription }
    }

    func isBusy(_ project: ManagedProject) -> Bool {
        gitProjectID == project.id || runs.values.contains { $0.projectID == project.id && $0.active }
    }

    func start(_ task: ProjectTask, in project: ManagedProject) {
        guard !isQuitting, runs[task.id]?.active != true else { return }
        do {
            let directory = try project.workingDirectory(for: task).path
            let run = ProjectRun(projectID: project.id, task: task)
            runs[task.id] = run
            let cancellation = run.cancellation
            let log = run.log
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome: String
                do {
                    let result = try ProjectCommand.run(executable: "/bin/zsh", arguments: ["-lc", task.command],
                        directory: directory, timeout: nil, cancellation: cancellation,
                        onStarted: { ApplicationRunLoop.perform { if !cancellation.isCancelled { run.state = "运行中" } } },
                        onOutput: log.append)
                    outcome = result.cancelled ? "已停止" : result.exitCode == 0 ? "已结束" : "失败，退出码 \(result.exitCode)"
                } catch { outcome = cancellation.isCancelled ? "已停止" : "失败：\(error.localizedDescription)" }
                ApplicationRunLoop.perform { run.state = outcome; run.active = false }
            }
        } catch { self.error = error.localizedDescription }
    }

    func refresh(_ project: ManagedProject) {
        performGitWork(project) { cancellation in try .state(ProjectGit.snapshot(at: project.directory, cancellation: cancellation)) }
    }

    func prepare(_ action: ProjectGitAction, for project: ManagedProject) {
        performGitWork(project) { cancellation in try .request(ProjectGit.target(at: project.directory, action: action, cancellation: cancellation), action) }
    }

    func execute(_ request: ProjectGitRequest) {
        performGitWork(request.project) { cancellation in
            try ProjectGit.perform(request.action, target: request.target, at: request.project.directory, cancellation: cancellation)
            do {
                return .completed(try ProjectGit.snapshot(at: request.project.directory, cancellation: cancellation), request.action)
            } catch {
                throw ProjectError.message("\(request.action.rawValue)已完成，但状态刷新失败：\(error.localizedDescription)")
            }
        }
    }

    nonisolated private enum GitOutcome: Sendable {
        case state(ProjectGitSnapshot)
        case request(ProjectGitTarget, ProjectGitAction)
        case completed(ProjectGitSnapshot, ProjectGitAction)
    }

    private func performGitWork(_ project: ManagedProject, work: @escaping @Sendable (ProjectCancellation) throws -> GitOutcome) {
        guard gitProjectID == nil, !isQuitting else { return }
        gitProjectID = project.id
        gitMessages[project.id] = nil
        let cancellation = ProjectCancellation()
        gitCancellation = cancellation
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(cancellation) }
            ApplicationRunLoop.perform {
                self.gitProjectID = nil; self.gitCancellation = nil
                switch result {
                case .success(.state(let state)): self.gitStates[project.id] = state
                case .success(.request(let target, let action)):
                    if !self.isQuitting { self.gitRequest = ProjectGitRequest(project: project, action: action, target: target) }
                case .success(.completed(let state, let action)):
                    self.gitStates[project.id] = state
                    self.gitMessages[project.id] = "\(action.rawValue)完成 · \(Date().formatted(date: .omitted, time: .shortened))"
                case .failure(let error):
                    self.gitStates[project.id] = nil
                    self.gitMessages[project.id] = error.localizedDescription
                }
            }
        }
    }

    func cancelGit() { gitCancellation?.cancel() }

    func openDirectory(_ project: ManagedProject, terminal: Bool) {
        do {
            try ProjectStore.checkDirectory(project.directory)
            if terminal {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", "Terminal", project.directory]
                try process.run()
            } else if !NSWorkspace.shared.open(URL(fileURLWithPath: project.directory)) {
                throw ProjectError.message("无法打开项目目录")
            }
        } catch { self.error = error.localizedDescription }
    }

    var hasActiveWork: Bool { gitProjectID != nil || runs.values.contains(where: \.active) }

    func stopForQuit() {
        isQuitting = true
        gitRequest = nil
        cancelGit()
        for run in runs.values where run.active { run.stop() }
    }
}

@MainActor
final class ProjectAppDelegate: NSObject, NSApplicationDelegate {
    private var quitTimer: Timer?
    private var preparingQuit = false
    var prepareNetworkQuit: ((@escaping (Bool) -> Void) -> Void)?
    var networkQuitReady: () -> Bool = { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !preparingQuit, let prepareNetworkQuit else { return .terminateCancel }
        let manager = ProjectManager.shared
        if manager.hasActiveWork {
            let alert = NSAlert()
            alert.messageText = "停止项目任务并退出？"
            alert.informativeText = "正在运行的项目任务和 Git 操作将被停止。"
            alert.addButton(withTitle: "停止并退出")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        preparingQuit = true
        prepareNetworkQuit { [weak self] succeeded in
            // Even a synchronous cleanup must reply after terminateLater is returned.
            ApplicationRunLoop.perform { [weak self] in
                guard let self else { return }
                guard succeeded else {
                    self.preparingQuit = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                manager.stopForQuit()
                self.quitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                    MainActor.assumeIsolated {
                        guard let self, !manager.hasActiveWork, self.networkQuitReady() else { return }
                        timer.invalidate(); self.quitTimer = nil
                        sender.reply(toApplicationShouldTerminate: true)
                    }
                }
                if let timer = self.quitTimer { RunLoop.main.add(timer, forMode: .modalPanel) }
            }
        }
        return .terminateLater
    }
}

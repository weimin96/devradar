import Foundation

nonisolated struct ProjectGitSnapshot: Sendable {
    var branch = ""
    var upstream: String?
    var changedFiles = 0
    var conflicts = 0
    var ahead = 0
    var behind = 0

    static func parse(_ data: Data) throws -> Self {
        var snapshot = Self()
        let records = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var skipOriginalPath = false
        for record in records {
            if skipOriginalPath { skipOriginalPath = false; continue }
            if record.hasPrefix("# branch.head ") { snapshot.branch = String(record.dropFirst(14)) }
            else if record.hasPrefix("# branch.upstream ") { snapshot.upstream = String(record.dropFirst(18)) }
            else if record.hasPrefix("# branch.ab ") {
                let counts = record.dropFirst(12).split(separator: " ")
                guard counts.count == 2, let ahead = Int(counts[0]), let behind = Int(counts[1]) else {
                    throw ProjectError.message("无法解析 Git 分支状态")
                }
                snapshot.ahead = ahead; snapshot.behind = abs(behind)
            } else if ["1 ", "2 ", "u ", "? "].contains(where: record.hasPrefix) {
                snapshot.changedFiles += 1
                if record.hasPrefix("u ") { snapshot.conflicts += 1 }
                skipOriginalPath = record.hasPrefix("2 ")
            }
        }
        guard !snapshot.branch.isEmpty else { throw ProjectError.message("无法读取 Git 分支") }
        return snapshot
    }
}

nonisolated enum ProjectGitAction: String, CaseIterable {
    case fetch = "获取远端更新"
    case pull = "拉取"
    case push = "推送"
}

nonisolated struct ProjectGitTarget: Sendable, Equatable {
    let branch: String
    let remote: String
    let remoteURL: String
    let reference: String

    var display: String { "\(remote) / \(reference.replacingOccurrences(of: "refs/heads/", with: ""))" }
}

nonisolated enum ProjectGit {
    static func command(_ arguments: [String], at directory: String,
                        cancellation: ProjectCancellation = ProjectCancellation()) throws -> Data {
        try ProjectCommand.run(executable: "/usr/bin/git", arguments: arguments, directory: directory,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "/usr/bin/ssh -oBatchMode=yes -oConnectTimeout=15",
                          "GCM_INTERACTIVE": "never", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0"],
            cancellation: cancellation).checked()
    }

    static func text(_ arguments: [String], at directory: String, cancellation: ProjectCancellation = ProjectCancellation()) throws -> String {
        String(decoding: try command(arguments, at: directory, cancellation: cancellation), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    static func snapshot(at directory: String, cancellation: ProjectCancellation = ProjectCancellation()) throws -> ProjectGitSnapshot {
        try ProjectGitSnapshot.parse(command(["status", "--porcelain=v2", "-z", "--branch"], at: directory, cancellation: cancellation))
    }

    static func target(at directory: String, action: ProjectGitAction, cancellation: ProjectCancellation = ProjectCancellation()) throws -> ProjectGitTarget {
        let state = try snapshot(at: directory, cancellation: cancellation)
        guard state.branch != "(detached)", state.upstream != nil else {
            throw ProjectError.message("当前分支未配置上游，请先在项目终端中设置")
        }
        let remote = try text(["config", "--get", "branch.\(state.branch).remote"], at: directory, cancellation: cancellation)
        let reference = try text(["config", "--get", "branch.\(state.branch).merge"], at: directory, cancellation: cancellation)
        guard remote != ".", !remote.isEmpty, reference.hasPrefix("refs/heads/"), !reference.contains("\n") else {
            throw ProjectError.message("上游配置不适用于远端同步，请在项目终端中检查")
        }
        // Display the actual push URL, including pushurl and URL rewrite rules.
        let arguments = ["remote", "get-url", "--all"] + (action == .push ? ["--push"] : []) + ["--", remote]
        let urls = try text(arguments, at: directory, cancellation: cancellation).split(separator: "\n").map(String.init)
        guard urls.count == 1 else { throw ProjectError.message("该远端配置了多个地址，请在终端中同步") }
        if action == .push {
            let mirror = try ProjectCommand.run(executable: "/usr/bin/git",
                arguments: ["config", "--bool", "--get", "remote.\(remote).mirror"], directory: directory, cancellation: cancellation)
            guard mirror.exitCode == 1 || (mirror.exitCode == 0 && String(decoding: mirror.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "false") else {
                throw ProjectError.message("该远端启用了镜像推送，请在终端中处理")
            }
        }
        return ProjectGitTarget(branch: state.branch, remote: remote, remoteURL: urls[0], reference: reference)
    }

    static func perform(_ action: ProjectGitAction, target expected: ProjectGitTarget, at directory: String,
                        cancellation: ProjectCancellation) throws {
        guard try target(at: directory, action: action, cancellation: cancellation) == expected else {
            throw ProjectError.message("分支或远端配置已变化，请重新确认操作")
        }
        let state = try snapshot(at: directory, cancellation: cancellation)
        guard state.conflicts == 0 else { throw ProjectError.message("存在未解决的冲突，请先在终端中处理") }
        switch action {
        case .fetch:
            _ = try command(["fetch", "--no-recurse-submodules", "--", expected.remote], at: directory, cancellation: cancellation)
        case .pull:
            guard state.changedFiles == 0 else { throw ProjectError.message("工作区有未提交改动，请先提交或在终端中处理") }
            _ = try command(["-c", "pull.squash=false", "pull", "--ff-only", "--no-rebase", "--no-autostash",
                             "--no-recurse-submodules", "--", expected.remote, expected.reference], at: directory, cancellation: cancellation)
        case .push:
            _ = try command(["push", "--porcelain", "--no-follow-tags", "--", expected.remote,
                             "HEAD:\(expected.reference)"], at: directory, cancellation: cancellation)
        }
    }
}

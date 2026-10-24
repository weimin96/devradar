import SwiftUI

struct ProjectPanel: View {
    var manager: ProjectManager
    var scanner: AppPortScanner
    @State private var query = ""
    @State private var removal: ManagedProject?

    private var projects: [ManagedProject] {
        manager.projects.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.directory.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目").font(.headline)
                Spacer()
                Button("添加项目", systemImage: "plus") { ProjectWindows.edit(nil, manager: manager) }
                    .disabled(manager.loadFailed || manager.isQuitting)
            }
            TextField("搜索项目或目录", text: $query)
                .textFieldStyle(.roundedBorder)
            if manager.loadFailed {
                Text(manager.error ?? "无法读取项目配置").foregroundStyle(.red).textSelection(.enabled)
                Button("重新读取") { manager.reload() }
            } else if projects.isEmpty {
                Text(manager.projects.isEmpty ? "暂无项目" : "没有匹配的项目")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(projects) { project in
                            ProjectRow(project: project, manager: manager, scanner: scanner) { removal = project }
                            Divider().padding(.vertical, 10)
                        }
                    }
                }
                .frame(height: min(max(CGFloat(projects.count) * 180, 220), 430))
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .confirmationDialog("移除项目？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible, presenting: removal) { project in
            Button("移除", role: .destructive) { manager.remove(project); self.removal = nil }
            Button("取消", role: .cancel) { self.removal = nil }
        } message: { _ in Text("仅移除 DevRadar 中的配置，项目文件保持不变。") }
        .alert("操作失败", isPresented: Binding(get: { manager.error != nil && !manager.loadFailed }, set: { if !$0 { manager.error = nil } })) {
            Button("确定", role: .cancel) { manager.error = nil }
        } message: { Text(manager.error ?? "") }
        .sheet(item: Binding(get: { manager.gitRequest }, set: { manager.gitRequest = $0 })) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text("\(request.action.rawValue) · \(request.project.name)").font(.headline)
                Text("本地分支：\(request.target.branch)")
                Text("目标分支：\(request.target.display)")
                Text(request.target.remoteURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if request.action == .push { Text("仅推送已有提交，未提交的文件改动不会上传。").foregroundStyle(.secondary) }
                if request.action == .pull { Text("仅允许快进更新，分支分叉时停止。").foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("取消") { manager.gitRequest = nil }.keyboardShortcut(.cancelAction)
                    Button(request.action.rawValue) { manager.gitRequest = nil; manager.execute(request) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 390)
        }
    }
}

private struct ProjectRow: View {
    let project: ManagedProject
    var manager: ProjectManager
    var scanner: AppPortScanner
    let remove: () -> Void
    @State private var expanded = false

    private var ports: [Int] {
        let root = URL(fileURLWithPath: project.directory).resolvingSymlinksInPath().standardizedFileURL.path
        return Set(scanner.ports.compactMap { port -> Int? in
            guard let path = port.projectDirectory ?? port.directory else { return nil }
            let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            return directory == root || directory.hasPrefix(root + "/") ? port.port : nil
        }).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Button { expanded.toggle(); if expanded { manager.refresh(project) } } label: {
                    HStack {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        Text(project.name).fontWeight(.semibold).lineLimit(1)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("打开目录") { manager.openDirectory(project, terminal: false) }
                    Button("打开终端") { manager.openDirectory(project, terminal: true) }
                    Button("项目设置") { ProjectWindows.edit(project, manager: manager) }.disabled(manager.isBusy(project))
                    Divider()
                    Button("移除项目", role: .destructive, action: remove).disabled(manager.isBusy(project))
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let state = manager.gitStates[project.id] {
                HStack(spacing: 12) {
                    Label(state.branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                    Spacer(minLength: 4)
                    Label(state.changedFiles == 0 ? "干净" : "\(state.changedFiles) 项改动",
                          systemImage: state.changedFiles == 0 ? "checkmark.circle" : "pencil.circle")
                        .fixedSize()
                }
                .foregroundStyle(.secondary)
                if expanded {
                    HStack(spacing: 12) {
                        Label(state.upstream ?? "未配置上游", systemImage: "point.3.connected.trianglepath.dotted")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if state.upstream != nil {
                            Label("\(state.ahead)", systemImage: "arrow.up")
                                .help("待推送 \(state.ahead) 个提交，以本地跟踪状态为准")
                            Label("\(state.behind)", systemImage: "arrow.down")
                                .help("待拉取 \(state.behind) 个提交，以本地跟踪状态为准")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .help("本地跟踪状态；获取远端更新后刷新")
                }
            }
            if expanded {
                Label(project.directory, systemImage: "folder")
                    .foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(1)
                    .truncationMode(.middle).help(project.directory)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("启动任务").foregroundStyle(.secondary)
                    Text(verbatim: "\(project.tasks.count)").foregroundStyle(.tertiary)
                    Spacer()
                    Button("添加任务", systemImage: "plus") {
                        var updated = project
                        updated.tasks.append(ProjectTask())
                        ProjectWindows.edit(updated, manager: manager)
                    }
                    .buttonStyle(.borderless)
                    .disabled(manager.isBusy(project) || manager.isQuitting)
                }
                ForEach(project.tasks) { task in
                    ProjectTaskRow(task: task, project: project, manager: manager)
                }
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                ForEach([ProjectGitAction.pull, .push], id: \.self) { action in
                    Button(action.rawValue, systemImage: action == .pull ? "arrow.down" : "arrow.up") {
                        manager.prepare(action, for: project)
                    }.disabled(manager.gitProjectID != nil || manager.isQuitting)
                }
                if expanded {
                    Divider().frame(height: 12)
                    Button("刷新状态", systemImage: "arrow.clockwise") { manager.refresh(project) }
                        .labelStyle(.iconOnly).help("刷新本地状态")
                        .disabled(manager.gitProjectID != nil || manager.isQuitting)
                    Button("获取远端更新", systemImage: "arrow.triangle.2.circlepath") { manager.prepare(.fetch, for: project) }
                        .labelStyle(.iconOnly).help("获取远端更新")
                        .disabled(manager.gitProjectID != nil || manager.isQuitting)
                }
                if manager.gitProjectID == project.id {
                    ProgressView().controlSize(.small)
                    Button("取消") { manager.cancelGit() }
                }
            }
            .buttonStyle(.borderless)
            if !ports.isEmpty {
                Text("监听端口：\(ports.map(String.init).joined(separator: "、"))").foregroundStyle(.secondary)
            }
            if let message = manager.gitMessages[project.id] {
                Text(message).lineLimit(5).textSelection(.enabled)
            }
        }
    }
}

private struct ProjectTaskRow: View {
    let task: ProjectTask
    let project: ManagedProject
    var manager: ProjectManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(task.name).fontWeight(.medium).lineLimit(1).help(task.name)
                Spacer(minLength: 4)
                if let run = manager.runs[task.id] {
                    Button("日志") { ProjectWindows.logs(run, projectName: project.name) }
                }
                if let run = manager.runs[task.id], run.active {
                    Button("停止", systemImage: "stop.fill") { run.stop() }
                        .disabled(run.cancellation.isCancelled)
                } else {
                    Button("启动", systemImage: "play.fill") { manager.start(task, in: project) }
                        .disabled(manager.isQuitting)
                }
            }
            .buttonStyle(.borderless)
            HStack(spacing: 8) {
                if task.directory != "." {
                    Text(task.directory).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle).help(task.directory)
                }
                Text(task.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .help(task.command)
            }
            if let run = manager.runs[task.id] {
                Text(run.state).foregroundStyle(.secondary).lineLimit(2).help(run.state)
            }
        }
    }
}

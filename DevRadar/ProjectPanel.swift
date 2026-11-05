import SwiftUI

struct ProjectPanel: View {
    var manager: ProjectManager
    var scanner: AppPortScanner
    @State private var query = ""
    @State private var removal: ManagedProject?
    @State private var removalError: String?
    @State private var expandedProjectIDs: Set<UUID> = []

    private var projects: [ManagedProject] {
        manager.projects.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.directory.localizedCaseInsensitiveContains(query)
        }
    }

    private var listHeight: CGFloat {
        let rows = projects.reduce(CGFloat.zero) { total, project in
            total + (expandedProjectIDs.contains(project.id) ? expandedRowHeight(project) : 58)
        }
        let spacing = CGFloat(max(projects.count - 1, 0)) * 8
        return min(max(rows + spacing + 4, 150), 430)
    }

    private var hasActiveDialog: Bool {
        removal != nil || manager.gitRequest != nil
    }

    var body: some View {
        // MenuBarExtra hosts this view in a status-item window. System sheets
        // and alerts presented from that window can lose their click target,
        // so confirmation UI stays inside the panel and owns its hit testing.
        ZStack {
            content
                .allowsHitTesting(!hasActiveDialog)

            if let project = removal {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture { removal = nil }
                removalPrompt(for: project)
            } else if let request = manager.gitRequest {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture { manager.gitRequest = nil }
                gitPrompt(for: request)
            }
        }
        .font(.system(size: 12))
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("项目").font(.system(size: 14, weight: .semibold))
                if !manager.projects.isEmpty {
                    Text(verbatim: "\(manager.projects.count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Spacer()
                Button("添加项目", systemImage: "plus") { ProjectWindows.edit(nil, manager: manager) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(manager.loadFailed || manager.isQuitting)
            }

            searchField

            if let error = manager.error, !manager.loadFailed {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 10.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        manager.error = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭错误提示")
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if manager.loadFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Text(manager.error ?? "无法读取项目配置")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("重新读取") { manager.reload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.vertical, 4)
            } else if projects.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: manager.projects.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(manager.projects.isEmpty ? "暂无项目" : "没有匹配的项目")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(projects) { project in
                            ProjectRow(
                                project: project,
                                manager: manager,
                                scanner: scanner,
                                isExpanded: expansionBinding(for: project)
                            ) {
                                removalError = nil
                                removal = project
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: listHeight)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索项目或目录", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }

    private func expansionBinding(for project: ManagedProject) -> Binding<Bool> {
        Binding(
            get: { expandedProjectIDs.contains(project.id) },
            set: { expanded in
                withAnimation(.easeInOut(duration: 0.18)) {
                    if expanded {
                        expandedProjectIDs.insert(project.id)
                    } else {
                        expandedProjectIDs.remove(project.id)
                    }
                }
            }
        )
    }

    private func expandedRowHeight(_ project: ManagedProject) -> CGFloat {
        let taskRows = max(project.tasks.count, 1)
        let gitHeight: CGFloat = manager.gitStates[project.id] == nil && manager.gitProjectID != project.id ? 0 : 44
        return 58 + 1 + 10 + 16 + 10 + gitHeight + 12 + 22 + CGFloat(taskRows) * 58
            + CGFloat(max(taskRows - 1, 0)) * 6 + 12 + 30 + 12
    }

    private func removalPrompt(for project: ManagedProject) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("移除项目？").font(.system(size: 14, weight: .semibold))
            Text("仅移除 DevRadar 中的配置，项目文件保持不变。")
                .fixedSize(horizontal: false, vertical: true)
            if let removalError {
                Text(removalError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("取消", role: .cancel) { removal = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("移除", role: .destructive) {
                    if manager.remove(project) {
                        removal = nil
                    } else {
                        removalError = manager.error ?? "移除失败"
                        manager.error = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(width: 278)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .onExitCommand { removal = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("移除项目确认")
    }

    private func gitPrompt(for request: ProjectGitRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(request.action.rawValue) · \(request.project.name)")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("本地分支").foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                    Text(request.target.branch).textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("目标分支").foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                    Text(request.target.display).textSelection(.enabled)
                }
            }
            .font(.system(size: 11.5))

            Text(request.target.remoteURL)
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if request.action == .push {
                Text("仅推送已有提交，未提交的文件改动不会上传。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else if request.action == .pull {
                Text("仅允许快进更新，分支分叉时停止。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("取消", role: .cancel) { manager.gitRequest = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button(request.action.rawValue) {
                    manager.gitRequest = nil
                    manager.execute(request)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(width: 338)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .onExitCommand { manager.gitRequest = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.action.rawValue)确认")
    }
}

private struct ProjectRow: View {
    let project: ManagedProject
    var manager: ProjectManager
    var scanner: AppPortScanner
    @Binding var isExpanded: Bool
    let remove: () -> Void
    @State private var isHovering = false

    private var ports: [Int] {
        let root = URL(fileURLWithPath: project.directory).resolvingSymlinksInPath().standardizedFileURL.path
        return Set(scanner.ports.compactMap { port -> Int? in
            guard let path = port.projectDirectory ?? port.directory else { return nil }
            let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            return directory == root || directory.hasPrefix(root + "/") ? port.port : nil
        }).sorted()
    }

    private var runningCount: Int {
        project.tasks.reduce(0) { count, task in
            count + (manager.runs[task.id]?.active == true ? 1 : 0)
        }
    }

    private var directoryWarningVisible: Bool {
        manager.gitMessages[project.id]?.contains("项目目录不可用") == true
    }

    private var vscodeAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.horizontal, 11)
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.055 : (isHovering ? 0.045 : 0.025)))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(isExpanded ? 0.09 : 0.055), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: toggleExpanded) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 22)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(verbatim: "\(project.tasks.count) 个任务")
                            if !ports.isEmpty {
                                metaDot
                                Text(verbatim: "\(ports.count) 个端口")
                            }
                            if runningCount > 0 {
                                metaDot
                                HStack(spacing: 4) {
                                    Circle().fill(Color.green).frame(width: 5, height: 5)
                                    Text(verbatim: "\(runningCount) 运行中")
                                        .foregroundStyle(Color.green)
                                }
                            }
                            if directoryWarningVisible {
                                metaDot
                                Label("目录不可用", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.orange)
                            }
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if vscodeAvailable {
                Button {
                    manager.openInVSCode(project)
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.055), in: Circle())
                }
                .buttonStyle(.plain)
                .help("用 VS Code 打开")
                .accessibilityLabel("用 VS Code 打开 \(project.name)")
                .disabled(manager.isQuitting)
            }

            Menu {
                Button("打开目录") { manager.openDirectory(project, terminal: false) }
                Button("用 VS Code 打开", systemImage: "chevron.left.forwardslash.chevron.right") {
                    manager.openInVSCode(project)
                }
                Button("打开终端") { manager.openDirectory(project, terminal: true) }
                Button("项目设置") { ProjectWindows.edit(project, manager: manager) }.disabled(manager.isBusy(project))
                Divider()
                Button("移除项目", role: .destructive, action: remove).disabled(manager.isBusy(project))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.055), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(minHeight: 58)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(project.directory)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .help(project.directory)

            gitDetails

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("启动任务")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(project.tasks.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("添加任务", systemImage: "plus") {
                        var updated = project
                        updated.tasks.append(ProjectTask())
                        ProjectWindows.edit(updated, manager: manager)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                    .disabled(manager.isBusy(project) || manager.isQuitting)
                }

                if project.tasks.isEmpty {
                    Text("暂无启动任务")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 6) {
                        ForEach(project.tasks) { task in
                            ProjectTaskRow(task: task, project: project, manager: manager)
                        }
                    }
                }
            }

            if !ports.isEmpty {
                Label("监听端口 \(ports.map(String.init).joined(separator: "、"))", systemImage: "network")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            gitActions

            if let message = manager.gitMessages[project.id] {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: message.contains("项目目录不可用") ? "exclamationmark.triangle.fill" : "info.circle")
                    Text(message)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(message.contains("项目目录不可用") ? Color.orange : Color.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var gitDetails: some View {
        if let state = manager.gitStates[project.id] {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Label(state.branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                    Label(
                        state.changedFiles == 0 ? "干净" : "\(state.changedFiles) 项改动",
                        systemImage: state.changedFiles == 0 ? "checkmark.circle" : "pencil.circle"
                    )
                    Spacer(minLength: 0)
                    if state.ahead > 0 {
                        Label("\(state.ahead)", systemImage: "arrow.up")
                            .help("待推送 \(state.ahead) 个提交")
                    }
                    if state.behind > 0 {
                        Label("\(state.behind)", systemImage: "arrow.down")
                            .help("待拉取 \(state.behind) 个提交")
                    }
                }
                HStack(spacing: 10) {
                    Label(state.upstream ?? "未配置上游", systemImage: "point.3.connected.trianglepath.dotted")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .help("本地跟踪状态；获取远端更新后刷新")
        } else if manager.gitProjectID == project.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在读取 Git 状态…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gitActions: some View {
        HStack(spacing: 8) {
            if manager.gitProjectID == project.id, manager.gitStates[project.id] != nil {
                ProgressView().controlSize(.small)
                Text("Git 操作中")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ForEach([ProjectGitAction.pull, .push], id: \.self) { action in
                Button(action.rawValue, systemImage: action == .pull ? "arrow.down" : "arrow.up") {
                    manager.prepare(action, for: project)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(manager.gitProjectID != nil || manager.isQuitting)
            }
            Button("刷新状态", systemImage: "arrow.clockwise") { manager.refresh(project) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("刷新本地状态")
                .disabled(manager.gitProjectID != nil || manager.isQuitting)
            Button("获取远端更新", systemImage: "arrow.triangle.2.circlepath") { manager.prepare(.fetch, for: project) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("获取远端更新")
                .disabled(manager.gitProjectID != nil || manager.isQuitting)
            if manager.gitProjectID == project.id {
                Button("取消") { manager.cancelGit() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }

    private var metaDot: some View {
        Text(verbatim: "·").foregroundStyle(.tertiary)
    }

    private func toggleExpanded() {
        isExpanded.toggle()
        if isExpanded {
            manager.refresh(project)
        }
    }
}

private struct ProjectTaskRow: View {
    let task: ProjectTask
    let project: ManagedProject
    var manager: ProjectManager

    private var run: ProjectRun? {
        manager.runs[task.id]
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(run?.active == true ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .help(task.name)
                    if let run {
                        Text(run.active ? "运行中" : run.state)
                            .font(.system(size: 10))
                            .foregroundStyle(run.active ? Color.green : Color.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    if task.directory != "." {
                        Text(task.directory)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text(task.command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(task.command)
                }
            }

            Spacer(minLength: 6)

            if let run {
                taskIconButton("doc.text", label: "日志") {
                    ProjectWindows.logs(run, projectName: project.name)
                }
            }
            if let run, run.active {
                taskIconButton("stop.fill", label: "停止", tint: .red) {
                    run.stop()
                }
                .disabled(run.cancellation.isCancelled)
            } else {
                taskIconButton("play.fill", label: "启动", tint: .accentColor) {
                    manager.start(task, in: project)
                }
                .disabled(manager.isQuitting)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
    }

    private func taskIconButton(_ systemImage: String, label: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.11), in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

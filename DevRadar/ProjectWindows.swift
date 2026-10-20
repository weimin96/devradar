import AppKit
import Combine
import SwiftUI

enum ProjectWindows {
    private static var editor: NSWindow?
    private static var logWindows: [UUID: NSWindow] = [:]

    static func collect(name: String, directory: String, ports: [PortInfo], manager: ProjectManager) {
        if let editor, editor.isVisible {
            editor.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.messageText = "请先保存或关闭当前项目编辑窗口"
            alert.beginSheetModal(for: editor)
            return
        }
        do {
            guard !manager.loadFailed, !manager.isQuitting else { throw ProjectError.message("项目配置当前不可编辑") }
            let draft = try ProjectPortImport(name: name, directory: directory, ports: ports, existing: manager.projects)
            guard !manager.isBusy(draft.project) else { throw ProjectError.message("请先停止该项目的任务并等待 Git 操作结束") }
            edit(draft.project, manager: manager, importNote: draft.note)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法收藏项目"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func edit(_ project: ManagedProject?, manager: ProjectManager, importNote: String? = nil) {
        if let editor, editor.isVisible { editor.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = manager.projects.contains(where: { $0.id == project?.id }) ? "DevRadar · 项目设置" : "DevRadar · 添加项目"
        window.contentView = NSHostingView(rootView: ProjectEditor(project: project ?? ManagedProject(name: "", directory: ""), importNote: importNote) { [weak window] updated in
            try manager.save(updated)
            window?.close()
        } cancel: { [weak window] in window?.close() })
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 400)
        window.isReleasedWhenClosed = false
        editor = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    static func logs(_ run: ProjectRun, projectName: String) {
        let window = logWindows[run.task.id] ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DevRadar · \(projectName) · \(run.task.name)"
        window.contentView = NSHostingView(rootView: ProjectLogView(run: run))
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 440, height: 280)
        window.isReleasedWhenClosed = false
        if logWindows[run.task.id] == nil { window.center() }
        logWindows[run.task.id] = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ProjectEditor: View {
    @State var project: ManagedProject
    var importNote: String? = nil
    let save: (ManagedProject) throws -> Void
    let cancel: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let importNote { Text(importNote).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("项目名称") {
                        TextField("项目名称", text: $project.name).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text(project.directory.isEmpty ? "未选择项目目录" : project.directory)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("选择目录") { chooseDirectory() }
                    }
                    Divider()
                    HStack {
                        Text("启动任务").font(.headline)
                        Spacer()
                        Button("添加任务") { project.tasks.append(ProjectTask()) }
                    }
                    ForEach($project.tasks) { $task in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                LabeledContent("任务名称") { TextField("任务名称", text: $task.name) }
                                Button("移除") {
                                    let taskID = task.id
                                    project.tasks.removeAll { $0.id == taskID }
                                }
                            }
                            LabeledContent("工作目录") { TextField("相对工作目录", text: $task.directory) }
                            Text("启动命令")
                            TextEditor(text: $task.command)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 75).border(Color(nsColor: .separatorColor))
                        }.textFieldStyle(.roundedBorder)
                        Divider()
                    }
                    if !project.tasks.isEmpty {
                        Text("命令通过 zsh 登录 Shell 在指定目录执行。任务需保持前台运行，结束后会清理同组子进程。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try save(project) } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 13)).padding(20)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = "选择项目目录"
        if panel.runModal() == .OK, let url = panel.url {
            project.directory = url.resolvingSymlinksInPath().path
            if project.name.isEmpty { project.name = url.lastPathComponent }
        }
    }
}

private struct ProjectLogView: View {
    var run: ProjectRun
    @State private var log = ""
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(run.task.name).font(.headline)
                Text(run.state).foregroundStyle(.secondary)
                Spacer()
                if run.active { Button("停止") { run.stop() }.disabled(run.cancellation.isCancelled) }
            }
            Text(run.task.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            ScrollView([.horizontal, .vertical]) {
                Text(log.isEmpty ? "暂无输出" : log)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(16)
        .onAppear { log = run.log.text }
        .onReceive(timer) { _ in log = run.log.text }
    }
}

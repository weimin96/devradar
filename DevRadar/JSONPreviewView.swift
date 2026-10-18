import AppKit
import SwiftUI

/// A read-only inspector for the proxy's redacted JSON sample.
/// Child nodes are rendered on demand so deeply nested telemetry does not
/// force a giant, unformatted text block into the request details pane.
struct JSONPreviewView: View {
    private enum DisplayMode: String, CaseIterable {
        case tree = "结构"
        case source = "格式化文本"
    }

    private let document: JSONPreviewDocument
    private let original: String
    @State private var displayMode = DisplayMode.tree
    @State private var expandedPaths: Set<String>

    init(preview: String) {
        original = preview
        let parsed = JSONPreviewDocument.parse(preview)
        document = parsed
        _expandedPaths = State(initialValue: Set(parsed.values.indices.map { "root-\($0)" }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(document.hasJSON ? "JSON 预览（尝试脱敏）" : "正文预览（尝试脱敏）")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if document.hasJSON {
                    Picker("预览模式", selection: $displayMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        document.hasJSON ? document.prettyText : original,
                        forType: .string
                    )
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制预览内容")
            }

            if document.hasJSON, displayMode == .tree {
                HStack(spacing: 12) {
                    Button("全部展开") { expandedPaths = allPaths() }
                    Button("全部折叠") { expandedPaths.removeAll() }
                    Spacer()
                    if document.values.count > 1 {
                        Text("\(document.values.count) 个 JSON 对象")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(document.values.indices, id: \.self) { index in
                        JSONPreviewNodeView(
                            title: document.values.count == 1 ? "JSON" : "对象 \(index + 1)",
                            value: document.values[index],
                            path: "root-\(index)",
                            depth: 0,
                            expandedPaths: $expandedPaths
                        )
                    }
                    if !document.remainingText.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("尾部 JSON 不完整，显示原文", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(document.remainingText)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(document.hasJSON ? document.prettyText : original)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            if !document.hasJSON && original.first == "{" {
                Text("内容可能已达到抓包预览上限，无法解析成完整 JSON；以上保留原始脱敏文本。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func allPaths() -> Set<String> {
        var result = Set<String>()
        func walk(_ node: JSONPreviewValue, path: String, depth: Int) {
            guard node.isExpandable, depth < 32 else { return }
            result.insert(path)
            for (index, child) in node.children.enumerated() {
                walk(child.value, path: "\(path)/\(index)", depth: depth + 1)
            }
        }
        for (index, node) in document.values.enumerated() {
            walk(node, path: "root-\(index)", depth: 0)
        }
        return result
    }
}

private struct JSONPreviewNodeView: View {
    let title: String
    let value: JSONPreviewValue
    let path: String
    let depth: Int
    @Binding var expandedPaths: Set<String>

    private var isExpanded: Bool { expandedPaths.contains(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 5) {
                if value.isExpandable {
                    Button {
                        if isExpanded {
                            expandedPaths.remove(path)
                        } else {
                            expandedPaths.insert(path)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 14, height: 17)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "折叠 \(title)" : "展开 \(title)")
                } else {
                    Color.clear.frame(width: 14, height: 17)
                }
                Text(title + ":")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value.summary)
                    .foregroundStyle(value.isExpandable ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced))
            if value.isExpandable && isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(value.children.enumerated()), id: \.offset) { index, child in
                        JSONPreviewNodeView(
                            title: child.key,
                            value: child.value,
                            path: "\(path)/\(index)",
                            depth: depth + 1,
                            expandedPaths: $expandedPaths
                        )
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}

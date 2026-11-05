// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

struct BatchArchiveCreation: View {
    let queue: ArchiveQueue
    var initialDestination: URL?
    var submitted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = BatchArchiveDraft()
    @State private var feedback = ""

    var body: some View {
        let conflicts = draft.conflictingNames
        let nested = draft.nestedEntries
        VStack(alignment: .leading, spacing: 16) {
            Text("批量创建任务").font(.title2.bold())
            Text("每个文件或文件夹各创建一个归档任务，整批共用一个保存位置。")
                .foregroundStyle(.secondary)
            HStack {
                Button("添加文件和文件夹…", systemImage: "plus") { chooseSources() }
                Spacer()
                Text("已添加 \(draft.entries.count) 项").foregroundStyle(.secondary)
            }
            if draft.entries.isEmpty {
                ContentUnavailableView("还没有来源", systemImage: "tray",
                                       description: Text("可以混选文件和文件夹，也可以分几次追加。"))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach($draft.entries) { $entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(entry.isDirectory ? "文件夹" : "文件",
                                      systemImage: entry.isDirectory ? "folder" : "doc")
                                TextField("归档名称", text: $entry.name)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("归档名称 · \(entry.source.lastPathComponent)")
                                Button("移除", systemImage: "minus.circle") {
                                    let id = entry.id
                                    draft.entries.removeAll { $0.id == id }
                                    feedback = ""
                                }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .accessibilityLabel("移除 \(entry.source.lastPathComponent)")
                            }
                            Text(entry.source.path).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if !BatchArchiveDraft.validName(entry.name) {
                                Text("请输入有效的归档名称。").foregroundStyle(.red).font(.caption)
                            } else if conflicts.contains(entry.id) {
                                Text("批次中有同名归档，请改名。").foregroundStyle(.red).font(.caption)
                            }
                            if nested.contains(entry.id) {
                                Text("该来源也在所选父文件夹内。保留此行会另外创建一个任务。")
                                    .foregroundStyle(.orange).font(.caption)
                            }
                        }.padding(.vertical, 5)
                    }
                }.frame(minHeight: 220)
            }
            HStack {
                Button("选择保存位置…", systemImage: "externaldrive") { chooseDestination() }
                Text(draft.destination?.path ?? "尚未选择").foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            if !feedback.isEmpty { Text(feedback).foregroundStyle(.orange).font(.callout) }
            Divider()
            HStack {
                Text("各任务独立确认来源与验证。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("加入队列（\(draft.entries.count)个任务）") {
                    do {
                        try queue.enqueueBatch(draft)
                        dismiss()
                        submitted()
                    } catch { feedback = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSubmit)
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 480, idealHeight: 560)
        .onAppear { if draft.destination == nil { draft.destination = initialDestination } }
    }

    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.title = "添加文件和文件夹"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        let rejected = draft.append(panel.urls)
        feedback = rejected == 0 ? "" : "有 \(rejected) 项不可用或不是普通文件、文件夹，已跳过。"
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "选择整批任务的保存位置"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = draft.destination
        if panel.runModal() == .OK {
            draft.destination = panel.url
            feedback = ""
        }
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

@main
struct ColdArchiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var queue = ArchiveQueue()
    init() {DiagnosticLog.shared.write(["event":"app_start"])}
    var body: some Scene {
        Window("冷归档", id: "main") {
            ContentView(queue: queue)
                .frame(minWidth: 880, minHeight: 650)
                .onAppear { delegate.queue = queue; DispatchQueue.main.async { NSApp.windows.first?.delegate = delegate }; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1040, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            ThirdPartyLicenseCommands()
            CommandGroup(after: .help) {
                Button("查看归档格式规范") { NSWorkspace.shared.open(Runtime.engine.appendingPathComponent("ARCHIVE_SPEC.md")) }
            }
        }
        Window("创建归档", id: "create-archive") { ArchiveCreationWindow(queue: queue) }
            .defaultSize(width: 760, height: 650)
        Settings { ReadingSettings() }
        Window("SNMP设置", id: "nas-settings") { NASSettings() }
            .windowResizability(.contentSize)
        Window("第三方组件与许可证", id: "third-party-licenses") {
            ThirdPartyLicensesView()
        }
        .defaultSize(width: 960, height: 680)
    }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var queue: ArchiveQueue?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let queue, queue.hasUnfinishedJobs else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "队列中仍有未完成任务"
        alert.informativeText = "请先完成或取消队列中的任务。正在执行的任务需要等待清理完成后才能退出。"
        alert.addButton(withTitle: "返回任务")
        alert.runModal()
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard queue?.hasUnfinishedJobs == true else { return true }
        let alert = NSAlert()
        alert.messageText = "请先完成或取消当前任务"
        alert.informativeText = "取消后请等待临时文件清理完成，再关闭窗口。"
        alert.addButton(withTitle: "返回任务")
        alert.runModal()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var queue: ArchiveQueue
    private var model: ArchiveModel { queue.draft }
    @State private var showingTasks = false
    @State private var queueHomeRequest = 0
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Label("冷归档", systemImage: "archivebox.fill").font(.title2.bold())
                Text("让长期保存有据可验").font(.subheadline).foregroundStyle(.secondary)
                Divider()
                VStack(spacing: 6) {
                    navigation("创建归档", icon: "plus.square.on.square", tasks: false)
                    navigation("任务队列", icon: "list.bullet.rectangle", tasks: true)
                }
                VStack(alignment: .leading, spacing: 15) {
                    feature("完整 SHA-512", "每个文件逐一校验", "checkmark.shield")
                    feature("真实恢复验证", "解压后比对文件与目录", "arrow.counterclockwise")
                    feature("源文件保持不变", "发布前再次完整复核", "lock.doc")
                }
                Spacer()
                VStack(alignment:.leading,spacing:10) {
                    SettingsLink { Label("通用设置", systemImage: "gearshape") }
                    Button { openWindow(id:"nas-settings") } label: {
                        Label("SNMP设置", systemImage:"network")
                    }
                }
                Text("Personal Cold Archive\nFormat 1.0").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 205).frame(maxHeight: .infinity).background(.quaternary.opacity(0.45))
            Divider()
            if showingTasks {
                TaskBoard(tasks: queue.records, cancel: queue.cancel, create: { openWindow(id: "create-archive") },
                          confirm: queue.showConfirmation, moveEarlier: queue.moveEarlier, retry: queue.retry, pauseReading: queue.toggleReadingPause,
                          pauseAll: queue.pauseAll, startAll: queue.startAll, deleteAll: queue.deleteAll, paused: queue.paused, togglePause: { queue.setPaused(!queue.paused) }, homeRequest: queueHomeRequest)
            } else {
            ArchiveCreationForm(queue: queue, submitted: {})
        }
        }
        
        .sheet(isPresented: Binding(get: { queue.confirmationID != nil }, set: { if !$0 { queue.confirmationID = nil } })) {
            if let jobModel = queue.confirmationModel {
                VStack(spacing: 0) {
                    Text(jobModel.archiveName).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding()
                    IntakeView(model: jobModel) { queue.confirmationID = nil }
                }.id(queue.confirmationID).interactiveDismissDisabled()
                .onChange(of: jobModel.error) { _, message in
                    if let message { jobModel.error = nil; FailureWindow.shared.show(message) }
                }
            }
        }
        .onChange(of: queue.showQueueRequest) { _, _ in queueHomeRequest += 1; showingTasks = true }
        .onChange(of: model.error) { _, message in
            guard let message else { return }
            model.error = nil
            if ArchiveFailure.describe(message).destinationConflict {
                model.resolveDestinationConflict()
            } else { FailureWindow.shared.show(message) }
        }
    }
    private func navigation(_ title: String, icon: String, tasks: Bool) -> some View {
        SidebarNavigationButton(title: title, icon: icon, selected: showingTasks == tasks) {
            if tasks { queueHomeRequest += 1 }
            showingTasks = tasks
        }
    }
    private func sectionTitle(_ number: String, _ title: String) -> some View {
        HStack { Text(number).font(.caption.bold()).frame(width: 23, height: 23).background(.quaternary, in: Circle()); Text(title).font(.headline) }
    }
    private func feature(_ title: String, _ detail: String, _ icon: String) -> some View {
        Label { VStack(alignment: .leading, spacing: 3) { Text(title).font(.callout); Text(detail).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: icon) }
    }
}

struct ArchiveCreationForm: View {
    @ObservedObject var queue: ArchiveQueue
    var submitted: () -> Void
    @State private var showingBatch = false
    private var model: ArchiveModel { queue.draft }
    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("创建可验证的长期归档").font(.largeTitle.bold())
                        Text("选择原始文件，确认来源，完成压缩与全部验证后发布。")
                            .foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionTitle("1", "选择归档内容")
                            HStack {
                                Button("添加文件…", systemImage: "doc.badge.plus") { model.chooseSources(directory: false) }
                                Button("选择文件夹…", systemImage: "folder.badge.plus") { model.chooseSources(directory: true) }
                                Button("批量创建任务…", systemImage: "list.bullet.rectangle") { showingBatch = true }
                            }
                            if model.sources.isEmpty {
                                Text("可多次添加不同位置的文件，合并为一个归档；也可选择一个完整文件夹。")
                                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                            } else {
                                HStack {
                                    Text("已选 \(model.sources.count) 项").font(.subheadline)
                                    Spacer()
                                    Button("清空", action: model.clearSources)
                                }
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(model.sources, id: \.path) { source in
                                            HStack(alignment: .top) {
                                                Label(source.path, systemImage: "doc").font(.callout)
                                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                                Spacer(minLength: 8)
                                                Button { model.removeSource(source) } label: { Image(systemName: "minus.circle") }
                                                    .buttonStyle(.borderless).help("从本批次移除，不删除原文件")
                                                    .accessibilityLabel("移除 \(source.lastPathComponent)")
                                            }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(maxHeight: 180)
                                Text("继续添加文件会保留本批次已有文件；选择文件夹会替换本批次。")
                                    .font(.caption).foregroundStyle(.secondary)

                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .disabled(model.working)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionTitle("2", "命名与保存位置")
                            TextField("归档名称（保留原样）", text: Binding(get: { model.archiveName }, set: { model.archiveName = $0 }))
                                .textFieldStyle(.roundedBorder).accessibilityLabel("归档名称")
                            HStack {
                                Button("选择保存位置…", systemImage: "externaldrive") { model.chooseDestination() }
                                Text(model.destination?.path ?? "尚未选择").foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                            Text("7z · LZMA2 Ultra · 64 MiB 字典 · SHA-512\n预留空间：源数据 × 2.2 + 1 GiB；执行前自动检查。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .disabled(model.working)
                    HStack {
                        Button {
                            let previous = queue.jobs.count
                            queue.enqueue()
                            if queue.jobs.count > previous { submitted() }
                        } label: {
                            Label("加入任务队列", systemImage: "arrow.right.circle.fill")
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canPrepare)
                        if model.task != nil {
                            Button("查看任务进度") { queue.showQueueRequest += 1 }
                        }
                    }
                    Text("不覆盖已有归档。失败或取消时清理本次临时文件；原始文件始终保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(30)
            }
            .sheet(isPresented: $showingBatch) {
                BatchArchiveCreation(queue: queue, initialDestination: model.destination, submitted: submitted)
            }
    }
    private func sectionTitle(_ number: String, _ title: String) -> some View {
        HStack { Text(number).font(.caption.bold()).frame(width: 23, height: 23).background(.quaternary, in: Circle()); Text(title).font(.headline) }
    }
}

struct ArchiveCreationWindow: View {
    @ObservedObject var queue: ArchiveQueue
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        ArchiveCreationForm(queue: queue) { dismissWindow(id: "create-archive") }
            .frame(minWidth: 650, minHeight: 560)
    }
}

struct IntakeView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: ArchiveModel
    let deferConfirmation: () -> Void
    @State private var choice = ""
    @State private var showingDiagnostics = false
    @State private var showingEvidence = false
    @StateObject private var draft = BilingualDraft()
    private var field: ProvenanceField { model.intake.current ?? .notes }
    private var group: FileConfirmationGroup? { model.intake.currentGroup }
    private var editable: Bool { choice == "candidate" || choice == "custom" }
    private var canSubmit: Bool { !choice.isEmpty && (!editable || draft.ready) }
    private var instruction: String {
        if field == .purpose { return "这组文件归档后作什么用途？例如长期备份、项目交付留存。" }
        if field == .notes { return "这组文件是否有需要补充说明的事项？" }
        if group?.conflict == true { return "这些文件的检测值存在冲突，请查看依据后自行填写，或选择未知、不填写。" }
        if group?.suggestion.isEmpty != false { return "未提取到这组文件的可用候选信息。你可以自行填写，或选择未知、不填写。" }
        return "请确认下面的信息是否适用于这组文件。你的回答只用于本组。"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("来源确认 · \(model.intake.stepIndex + 1)/5").font(.subheadline).foregroundStyle(.secondary)
            Text(field.title).font(.title2.bold())
            if let group {
                Text("第 \(model.intake.groupIndex + 1)/\(model.intake.currentGroups.count) 组 · \(group.category) · \(group.files.count) 个文件").font(.headline)
                Text("本项已确认 \(model.intake.confirmedGroupCount)/\(model.intake.currentGroups.count) 组").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("读取问题（\(model.metadata?.diagnosticGroups.count ?? 0) 类）…") { showingDiagnostics = true }
                    .disabled(model.metadata?.diagnosticGroups.isEmpty != false)
                Button("导出完整元数据…", action: model.exportMetadata)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let group {
                        DisclosureGroup("本组文件（\(group.files.count) 个）") {
                            ScrollView {
                                LazyVStack(alignment: .leading) {
                                    ForEach(group.files, id: \.self) { path in Text(path).font(.caption).textSelection(.enabled) }
                                }
                            }.frame(height: 100)
                        }.id(model.intake.positionID)
                    }
                    Text(instruction).font(.callout)
                    if let group, !group.suggestion.isEmpty {
                        Text("检测结果：\(group.suggestion)").textSelection(.enabled)
                    }
                    if group?.evidence.isEmpty == false {
                        Button("查看检测依据…") { showingEvidence = true }
                    }
                    Picker("本组确认", selection: Binding(get: { choice }, set: { value in
                        choice = value
                        if value == "candidate" {
                            draft.reset(chinese: group?.suggestion ?? "", english: group?.suggestionEnglish ?? "")
                            if draft.english.isEmpty { draft.edit(draft.chinese, side: .chinese) }
                        }
                    })) {
                        if group?.suggestion.isEmpty == false && group?.conflict == false {
                            Text("采用检测结果").tag("candidate")
                        }
                        Text(field == .notes ? "填写备注" : "自定义填写").tag("custom")
                        if field == .notes { Text("无补充").tag("none") }
                        else {
                            Text("未知（不清楚此项信息）").tag("unknown")
                            Text("不填写（不提供此项信息）").tag("blank")
                        }
                    }.pickerStyle(.radioGroup)
                    if editable { BilingualEditor(draft: draft) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("稍后确认", action: deferIntake).keyboardShortcut(.cancelAction)
                Button("返回上一步") { saveDraft(); model.previousIntakeStep() }.disabled(!model.intake.canGoBack)
                Spacer()
                Button(model.intake.isFinalConfirmation ? (model.defersArchive ? "确认并加入归档队列" : "确认并开始归档") : "确认本组并继续") {
                    saveDraft()
                    model.submit(answer: editable ? draft.chinese : (choice == "none" ? "无补充" : (choice == "blank" ? "不填写" : "未知")), english: draft.english)
                }.buttonStyle(.borderedProminent).disabled(!canSubmit)
            }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 680, height: 650)
        .sheet(isPresented: $showingDiagnostics) {
            VStack(alignment: .leading, spacing: 14) {
                Text("读取问题 · 按原因分组").font(.title2.bold())
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.metadata?.diagnosticGroups ?? []) { group in
                            DisclosureGroup("\(group.message)（\(group.files.count) 个文件）") {
                                ForEach(group.files.sorted(), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                            }
                        }
                    }
                }
                Button("关闭") { showingDiagnostics = false }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 620, height: 450)
        }
        .sheet(isPresented: $showingEvidence) {
            VStack(alignment: .leading) {
                Text("本组检测依据").font(.title2.bold())
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(Array((group?.evidence ?? []).enumerated()), id: \.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) }
                    }
                }
                Button("关闭") { showingEvidence = false }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 620, height: 450)
        }
        .onExitCommand {
            if showingDiagnostics { showingDiagnostics = false }
            else if showingEvidence { showingEvidence = false }
            else { deferIntake() }
        }
        .onAppear { prefill() }
        .onChange(of: model.intake.positionID) { _, _ in prefill() }
        .onDisappear { draft.reset(chinese: "", english: "") }
    }
    private func deferIntake() {
        saveDraft()
        deferConfirmation()
    }
    private func saveDraft() {
        model.intakeDrafts[model.intake.positionID] = ArchiveModel.SavedDraft(choice: choice, chinese: draft.chinese, english: draft.english, enabled: draft.enabled, pending: draft.enabled && !draft.ready, side: draft.side)
    }
    private func prefill() {
        if let saved = model.intakeDrafts[model.intake.positionID] {
            choice = saved.choice
            draft.setEnabled(saved.enabled); draft.reset(chinese: saved.chinese, english: saved.english)
            if saved.pending { draft.edit(saved.side == .chinese ? saved.chinese : saved.english, side: saved.side) }
            return
        }
        choice = ""
        draft.reset(chinese: "", english: "")
        if let group, !group.conflict, !group.suggestion.isEmpty {
            choice = "candidate"
            draft.reset(chinese: group.suggestion, english: group.suggestionEnglish)
            if draft.english.isEmpty { draft.edit(draft.chinese, side: .chinese) }
        } else if field == .purpose || field == .notes { choice = "custom" }
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

struct TaskBoard: View {
    let tasks: [ArchiveTask]
    let cancel: (UUID) -> Void
    let create: () -> Void
    var confirm: (UUID) -> Void = { _ in }
    var moveEarlier: (UUID) -> Void = { _ in }
    var retry: (UUID) -> Void = { _ in }
    var pauseReading: (UUID) -> Void = { _ in }
    var pauseAll: () -> Void = {}
    var startAll: () -> Void = {}
    var deleteAll: () -> Void = {}
    var paused = false
    var togglePause: (() -> Void)? = nil
    var homeRequest = 0
    @ObservedObject private var budgetStatus=WriteBudgetStatus.shared
    @State private var category = 0
    @State private var selectedID: UUID?
    @State private var search = ""
    private func matches(_ task: ArchiveTask, _ category: Int) -> Bool {
        switch category {
        case 1: return task.state == .completed
        case 2: return task.state == .failed || task.state == .cancelled
        default: return ![.completed, .failed, .cancelled].contains(task.state)
        }
    }
    private var visibleTasks: [ArchiveTask] {
        tasks.filter { matches($0, category) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("任务队列").font(.largeTitle.bold())
                Spacer()
                Button("创建归档", action: create).buttonStyle(.borderedProminent)
            }
            if let id = selectedID, let task = tasks.first(where: { $0.id == id }) {
                HStack {
                    Button { selectedID = nil } label: { Label("全部任务", systemImage: "chevron.left") }
                    Text("/").foregroundStyle(.tertiary)
                    Text(task.name).lineLimit(1)
                }
                ScrollView {
                    TaskCard(task: task, cancel: { cancel(id) }, confirm: { confirm(id) }, moveEarlier: { moveEarlier(id) }, retry: { retry(id) }, pauseReading: { pauseReading(id) })
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    let total = tasks.isEmpty ? 0 : tasks.reduce(0.0) { $0 + $1.overallProgress } / Double(tasks.count)
                    HStack {
                        Text("队列总进度").font(.headline)
                        Spacer()
                        Text("\(Int(total * 100))% · 已完成\(tasks.filter { $0.state == .completed }.count)/\(tasks.count)个任务").monospacedDigit()
                    }
                    ProgressView(value: total)
                    if !budgetStatus.message.isEmpty {Text(budgetStatus.message).font(.callout).foregroundStyle(.orange)}
                    Text("按流程步骤计算，任务等权；不代表耗时比例。新增任务会重新计算总进度。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(tasks.filter { !$0.detail.isEmpty }) { task in
                        Text("\(task.name)：\(task.detail)").font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if !tasks.contains(where: { !$0.detail.isEmpty }) {
                        Text(tasks.contains(where: { $0.state == .reading && $0.running }) ? "正在准备读取，等待监测数据…" : "当前没有正在读取的任务").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 28) {
                    ForEach(0..<3) { index in
                        Button { category = index } label: {
                            VStack(spacing: 10) {
                                Text("\(["进行中", "已完成", "未完成"][index])(\(tasks.filter { matches($0, index) }.count))")
                                    .font(.headline)
                                Capsule().fill(category == index ? Color.accentColor : .clear).frame(height: 3)
                            }.fixedSize(horizontal: true, vertical: false).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(category == index ? Color.accentColor : .primary)
                    }
                    Spacer()
                }
                HStack {
                    Button("全部暂停", action: pauseAll).disabled(tasks.isEmpty || paused)
                    Button("全部开始", action: startAll).disabled(tasks.isEmpty)
                    Button("全部删除", role: .destructive, action: deleteAll).disabled(tasks.isEmpty)

                    Text(paused ? "暂停已请求，当前操作安全收尾后暂停" : "来源提前读取 · 归档依次执行")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("搜索任务", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                }
                HStack {
                    Text("任务名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("进度 / 状态").frame(width: 190, alignment: .leading)
                    Text("操作").frame(width: 150, alignment: .leading)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                Divider()
                if visibleTasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray").font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text(search.isEmpty ? "此分类暂无任务" : "没有匹配的任务").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleTasks) { task in
                                HStack(spacing: 16) {
                                    Button { selectedID = task.id } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "archivebox.fill").font(.title2).foregroundStyle(Color.accentColor)
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(task.name).font(.headline).lineLimit(1)
                                                Text(task.createdAt, format: .dateTime.month().day().hour().minute())
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain).help("查看文件明细和执行记录")
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(task.cancelling ? "正在取消" : task.readingPauseRequested && task.state == .reading ? "读取暂停中" : task.state.rawValue).font(.callout)
                                        ProgressView(value: task.overallProgress).tint(task.state == .completed ? .green : .accentColor)
                                        Text("任务总进度\(Int(task.overallProgress * 100))%").font(.caption).foregroundStyle(.secondary)
                                    }.frame(width: 190, alignment: .leading).allowsHitTesting(false)
                                    HStack(spacing: 10) {
                                        if task.state == .confirming { Button("确认", action: { confirm(task.id) }) }
                                        if task.state == .reading && task.running {
                                            Button(task.readingPauseRequested ? "继续" : "暂停") { pauseReading(task.id) }.disabled(task.cancelling)
                                        }
                                        if task.state == .failed || task.state == .cancelled {
                                            Button("重试") { retry(task.id) }
                                        }
                                        Menu {
                                            Button("查看详情") { selectedID = task.id }
                                            if task.state == .queued { Button("提前读取") { moveEarlier(task.id) } }
                                            if let bundle = task.bundle { Button("在Finder中显示") { NSWorkspace.shared.activateFileViewerSelecting([bundle]) } }
                                            if ![.completed, .failed, .cancelled].contains(task.state) {
                                                Button("取消任务", role: .destructive) { cancel(task.id) }.disabled(task.cancelling)
                                            }
                                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
                                    }.frame(width: 150, alignment: .leading)
                                }.padding(.horizontal, 14).padding(.vertical, 18)
                                .background {
                                    Button { selectedID = task.id } label: {
                                        Color.clear.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel("查看任务详情：\(task.name)")
                                }
                                Divider()
                            }
                        }
                    }
                }
                Text("任务记录保留至退出应用 · 点击任务行查看文件明细与执行记录")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: homeRequest) { _, _ in selectedID = nil }
    }
}

private struct TaskCard: View {
    let task: ArchiveTask
    let cancel: () -> Void
    var confirm: () -> Void = {}
    var moveEarlier: () -> Void = {}
    var retry: () -> Void = {}
    var pauseReading: () -> Void = {}
    @State private var showLog = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.name).font(.title3.bold()).textSelection(.enabled)
                        Text(task.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(task.cancelling ? "正在取消" : task.state.rawValue)
                        .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
                HStack {
                    Text(task.status).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if task.running && task.state == .reading {
                        Button(task.readingPauseRequested ? "继续读取" : "暂停读取", action: pauseReading).disabled(task.cancelling || (!task.readingPauseRequested && !task.readingProgress.files.isEmpty && task.readingProgress.completed == task.readingProgress.files.count))
                    }
                    if task.running {
                        Button(task.cancelling ? "正在停止并清理…" : "取消任务", role: .destructive, action: cancel)
                            .disabled(task.cancelling)
                    }
                }
                ProgressView(value: task.overallProgress).tint(task.state == .completed ? .green : .accentColor)
                Text("任务总进度\(Int(task.overallProgress * 100))% · 读取来源 → 五项确认 → 归档与验证 → 完成")
                    .font(.callout)
                Text("按流程步骤计算，不代表耗时比例").font(.caption).foregroundStyle(.secondary)
                if task.state == .reading && task.readingPauseRequested {
                    Text(task.readingProgress.files.isEmpty ? "已请求暂停，正在完成文件枚举。" : task.readingProgress.active > 0 ? "暂停中：等当前\(task.readingProgress.active)个文件读完，不再启动新文件。" : "读取已暂停，点击继续后恢复。")
                        .foregroundStyle(.orange).font(.callout)
                }
                if !task.readingProgress.files.isEmpty {
                    ReadingFilesView(progress: task.readingProgress)
                }
                if task.state == .queued {
                    HStack { Button("提前", action: moveEarlier); Button("取消排队", role: .destructive, action: cancel) }
                }
                if task.state == .ready {
                    Button("取消等待归档") { cancel() }
                }
                if task.state == .confirming {
                    HStack { Button("确认来源", action: confirm).buttonStyle(.borderedProminent); Button("取消任务", role: .destructive, action: cancel) }
                    Text("后续任务可提前读取；确认完成后自动切换到下一个已读完的任务。").font(.callout).foregroundStyle(.secondary)
                }
                if task.state == .failed || task.state == .cancelled {
                    Button("重新加入队列", action: retry)
                }
                if let failure = task.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                if let location = task.bundle ?? task.destination {
                    HStack(alignment: .top) {
                        Label(location.path, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let bundle = task.bundle {
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([bundle]) }
                        }
                    }
                }
                if !task.log.isEmpty {
                    Button {
                        // Avoid animating a large text layout inside the task list.
                        var transaction = Transaction(); transaction.disablesAnimations = true
                        withTransaction(transaction) { showLog.toggle() }
                    } label: {
                        HStack {
                            Image(systemName: showLog ? "chevron.down" : "chevron.right")
                            Text(showLog ? "收起执行记录" : "查看执行记录")
                            Spacer()
                            Text("诊断详情").foregroundStyle(.secondary)
                        }.font(.callout).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if showLog {
                        ExecutionLogView(text: task.log).frame(height: 200)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

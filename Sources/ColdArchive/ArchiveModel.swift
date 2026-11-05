// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

private final class MetadataLease {
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class ArchiveModel: ObservableObject {
    @Published var sources: [URL] = []
    @Published var destination: URL?
    @Published var archiveName = ""
    @Published var intake = Intake()
    struct SavedDraft {
        let choice: String; let chinese: String; let english: String
        let enabled: Bool; let pending: Bool; let side: BilingualDraft.Side
    }
    var intakeDrafts: [String: SavedDraft] = [:]

    @Published var metadata: MetadataReport?
    @Published private(set) var metadataReportURL: URL?
    // Full evidence stays on disk during inspection/UI. Materialize only for the
    // legacy bilingual archive document or explicit compatibility callers.
    var metadataJSON: String {
        guard let url = metadataReportURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    private func clearMetadataFile() {
        if let url = metadataReportURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        metadataReportURL = nil
        metadataLease = nil
    }
    private var metadataLease: MetadataLease?
    func retainMetadataReport(_ url: URL) {
        metadataLease = MetadataLease(url.deletingLastPathComponent())
        metadataReportURL = url
    }
    @Published private(set) var readingProgress = ReadingProgress()
    @Published private(set) var readingPauseRequested = false
    @Published var metadataProgress = "正在枚举文件…"
    @Published var busy = false
    @Published var inspecting = false
    @Published var cancelling = false
    @Published var showingIntake = false
    @Published var log = ""
    @Published var phase = 0
    @Published var status = "准备归档"
    @Published var error: String?
    @Published var completedBundle: URL?
    @Published private(set) var task: ArchiveTask?
    @Published private(set) var taskHistory: [ArchiveTask] = []
    var tasks: [ArchiveTask] {
        guard var current = task else { return taskHistory }
        current.status = archivePauseRequested && busy ? "暂停已请求：当前操作结束后暂停，点击全部开始继续" : status
        current.detail = inspecting ? metadataProgress : ""
        current.readingProgress = readingProgress
        current.readingPauseRequested = readingPauseRequested
        current.confirmationSteps = Double(intake.stepIndex) + (intake.currentGroups.isEmpty ? 0 : Double(intake.groupIndex) / Double(intake.currentGroups.count))
        current.phase = phase
        current.log = log
        current.bundle = completedBundle
        current.running = working
        current.cancelling = cancelling
        return [current] + taskHistory
    }
    private func preserveTask() {
        if let current = tasks.first, task != nil { taskHistory.insert(current, at: 0) }
        task = nil
    }
    func beginTaskRecord() {
        preserveTask()
        task = ArchiveTask(id: UUID(), name: archiveName, createdAt: Date(), destination: destination)
    }
    private func failTask(_ message: String) {
        task?.state = .failed
        task?.failure = ArchiveFailure.describe(message).reason
    }
    private var runner: ProcessRunner?
    private var metadataScheduler: MetadataScheduler?
    private var choosing = false
    var working: Bool { busy || inspecting }
    var canPrepare: Bool { !sources.isEmpty && destination != nil && !archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !working }

    func chooseSources(directory: Bool) {
        guard !choosing, !working else { return }
        choosing = true; defer { choosing = false }
        let panel = NSOpenPanel()
        panel.title = directory ? "选择一个归档文件夹" : "选择需要归档的文件"
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = !directory
        guard panel.runModal() == .OK else { return }
        if directory { selectSources(panel.urls) } else { appendFiles(panel.urls) }
    }

    /// An accepted selection starts a fresh archive, retaining only its save location.
    func selectSources(_ selection: [URL]) {
        guard !working, !selection.isEmpty else { return }
        replaceSources(selection, name: selection.count == 1 ? selection[0].lastPathComponent : "")
    }

    /// File selection adds to the current batch. Directory selection remains a separate mode.
    func appendFiles(_ selection: [URL]) {
        guard !working, !selection.isEmpty else { return }
        if sources.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
            selectSources(selection)
            return
        }
        var seen = Set(sources.map { $0.standardizedFileURL.path })
        let additions = selection.filter { seen.insert($0.standardizedFileURL.path).inserted }
        guard !additions.isEmpty else { return }
        let combined = sources + additions
        let wasAutomaticName = sources.count == 1 && archiveName == sources[0].lastPathComponent
        let name = sources.isEmpty ? (combined.count == 1 ? combined[0].lastPathComponent : "") : (wasAutomaticName && combined.count > 1 ? "" : archiveName)
        replaceSources(combined, name: name)
    }
    func removeSource(_ source: URL) {
        guard !working else { return }
        let remaining = sources.filter { $0 != source }
        guard remaining.count != sources.count else { return }
        replaceSources(remaining, name: remaining.isEmpty ? "" : archiveName)
    }
    func clearSources() {
        guard !working else { return }
        replaceSources([], name: "")
    }
    private func replaceSources(_ selection: [URL], name: String) {
        preserveTask()
        sources = selection
        archiveName = name
        intake = Intake()
        metadata = nil
        clearMetadataFile()
        metadataProgress = "正在枚举文件…"
        completedBundle = nil
        log = ""
        phase = 0
        status = "准备归档"
        error = nil
        cancelling = false
        showingIntake = false
        runner = nil
    }
    func chooseDestination() {
        guard !choosing, !working else { return }
        choosing = true; defer { choosing = false }
        let panel = NSOpenPanel()
        panel.title = "选择归档保存位置"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { destination = panel.url }
    }
    func prepare() {
        guard canPrepare else { return }
        guard !archiveName.contains("/"), !archiveName.contains("\0"), archiveName != ".", archiveName != ".." else {
            error = "归档名称不能是路径或包含斜杠。"; return
        }
        beginTaskRecord()
        phase = 0
        readingProgress = ReadingProgress(); readingPauseRequested = false
        inspecting = true; cancelling = false; metadataProgress = "正在枚举文件…"; error = nil; log = ""; completedBundle = nil; intake = Intake()
        metadata = nil; clearMetadataFile()
        status = "正在检测来源元数据…"
        let scheduler = MetadataScheduler(); self.metadataScheduler = scheduler
        let concurrency = ConcurrencySettings.load()
        let config = NASConfiguration.load()
        let selectedPaths = sources.map(\.path)
        Task {
            var reportDirectory: URL?
            do {
                try WriteBudget.configure(.load())
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ColdArchive-Metadata-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                reportDirectory = directory
                let reportURL = directory.appendingPathComponent("metadata.json")
                let summaryURL = directory.appendingPathComponent("summary.json")
                let secrets:NASSecrets
                let mounts=mountedSources()
                let needsNAS=config.enabled && selectedPaths.contains {path in mounts.first {path==$0.path || path.hasPrefix($0.path == "/" ? "/":$0.path+"/")}?.local == false}
                do {secrets=needsNAS ? try NASKeychain.load():NASSecrets()}
                catch {secrets=NASSecrets(loadingError:error.localizedDescription)}
                try await scheduler.run(paths: selectedPaths, directory: directory, adaptive: concurrency.adaptive, customLimit: concurrency.readLimit, followsLiveSettings: true, config: config, secrets: secrets, fileProgress: { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self, self.metadataScheduler === scheduler, self.inspecting else { return }
                        self.readingProgress = snapshot
                    }
                }) { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.metadataScheduler === scheduler, self.inspecting else { return }
                        self.metadataProgress = message
                    }
                }
                if cancelling {
                    status = "元数据读取已取消"; task?.state = .cancelled
                } else {
                    let data = try await Task.detached { try Data(contentsOf: summaryURL) }.value
                    metadata = try JSONDecoder().decode(MetadataReport.self, from: data)
                    intakeDrafts.removeAll()
                    intake = Intake(report: metadata)
                    retainMetadataReport(reportURL)
                    reportDirectory = nil
                    showingIntake = true; status = "确认来源信息"; task?.state = .confirming
                }
            } catch is CancellationError { status = "元数据读取已取消"; task?.state = .cancelled }
            catch { DiagnosticLog.shared.write(["event":"metadata_error","code":DiagnosticLog.category(error)]);self.error = error.localizedDescription; status = "来源检测未完成"; failTask(error.localizedDescription) }
            if let directory = reportDirectory {
                do { try FileManager.default.removeItem(at: directory) }
                catch {DiagnosticLog.shared.write(["event":"cleanup_error","stage":"metadata","code":DiagnosticLog.category(error)]); failTask("元数据临时报告清理失败"); self.error = "元数据临时报告清理失败：\(directory.path)\n\(error.localizedDescription)" }
            }
            inspecting = false; cancelling = false; self.runner = nil; self.metadataScheduler = nil
        }
    }

    @Published private(set) var archivePauseRequested = false
    func setAllPaused(_ paused: Bool) {
        if inspecting && readingPauseRequested != paused { toggleReadingPause() }
        if busy {
            archivePauseRequested = paused
            runner?.setPaused(paused)
        }
    }
    var defersArchive = false
    func startQueuedArchive() {
        guard task?.state == .ready else { return }
        startArchive()
    }
    func submit(answer: String, english: String) {
        do {
            guard let field = intake.current else { return }
            try intake.submit(field, answer: answer, english: english)
            if intake.complete {
                intakeDrafts.removeAll()
                showingIntake = false
                if defersArchive { task?.state = .ready; status = "来源已确认，等待归档" }
                else { startArchive() }
            }
        } catch {DiagnosticLog.shared.write(["event":"application_error","code":DiagnosticLog.category(error)]); self.error = error.localizedDescription }
    }
    func previousIntakeStep() { intake.goBack() }
    func cancelIntake() { showingIntake = false; intake = Intake(); intakeDrafts.removeAll(); status = "已取消来源确认"; task?.state = .cancelled }
    func toggleReadingPause() {
        guard inspecting, !cancelling, let scheduler = metadataScheduler else { return }
        guard readingPauseRequested || readingProgress.files.isEmpty || readingProgress.completed < readingProgress.files.count else { return }
        readingPauseRequested.toggle()
        let paused = readingPauseRequested
        Task { await scheduler.setPaused(paused) }
    }
    func cancel() {
        guard working, !cancelling else { return }
        readingPauseRequested = false
        cancelling = true; status = "正在停止并清理临时文件…"; runner?.cancel(); if let scheduler = metadataScheduler { Task { await scheduler.cancel() } }
    }
    private func append(_ line: String) {
        log += line + "\n"
        if log.count > 120_000 { log = String(log.suffix(100_000)) }
        if busy, line.hasPrefix("PHASE "), let number = Int(line.split(separator: " ").dropFirst().first ?? "") {
            phase = number
            if !cancelling, Self.phaseNames.indices.contains(number - 1) { status = Self.phaseNames[number - 1] }
        }
    }
    private func startArchive() {
        guard let destination, intake.complete, !working else { return }
        task?.state = .archiving
        task?.failure = nil
        task?.destination = destination
        do {
            try WriteBudget.configure(.load())
            let answers = try intake.document(sources: sources)
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ColdArchive-\(UUID().uuidString)", isDirectory: true)
            let zh=metadata.map {"已检测 \($0.inspected_file_count)/\($0.total_included_files) 个文件。候选值未经确认；见下方原始检测记录。\n"} ?? ""
            let en=metadata.map {"Inspected \($0.inspected_file_count)/\($0.total_included_files) files. Candidates are unconfirmed; raw inspection record follows.\n"} ?? ""
            let report=metadataReportURL
            var args = sources.map(\.path)
            args += ["--archive-name", archiveName, "--output-dir", destination.path, "--require-source-confirmation", "--source-answers-json", workspace.appendingPathComponent("answers.json").path, "--source-details-json", workspace.appendingPathComponent("details.json").path]
            busy = true; cancelling = false; phase = 0; log = ""; error = nil; status = "正在启动完整归档流程…"
            let runner = ProcessRunner(); self.runner = runner
            Task {
                do {
                    try await ArchivePreparation.write(workspace:workspace,answers:answers,report:report,zh:zh,en:en)
                    let result = try await Task.detached { [args] in
                        try runner.run(script: "desktop_bridge.py", arguments: args) { [weak self] line in
                            Task { @MainActor in
                                guard let self, self.runner === runner, self.busy else { return }
                                self.append(line)
                            }
                        }
                    }.value
                    let resultLine = result.output.components(separatedBy: "\n").last(where: { $0.hasPrefix("DESKTOP_RESULT ") })
                    let desktop = resultLine.flatMap { try? JSONDecoder().decode(DesktopResult.self, from: Data($0.dropFirst(15).utf8)) }
                    DiagnosticLog.shared.write(["event":"archive_exit","exit_code":result.status])
                    if result.status == 0, desktop?.state == "completed", let path = desktop?.bundle {
                        completedBundle = URL(fileURLWithPath: path)
                        status = "归档完成 · 所有验证已通过"; phase = 15; task?.state = .completed
                    } else if result.status == 130 && desktop?.state == "cancelled" {
                        status = "归档已取消 · 临时文件已清理"; task?.state = .cancelled
                    } else {
                        status = "归档失败"
                        self.error = result.output; failTask(result.output)
                    }
                } catch {
                    if cancelling {status="归档已取消";task?.state = .cancelled}
                    else {DiagnosticLog.shared.write(["event":"archive_error","code":DiagnosticLog.category(error)]);status="无法执行归档";self.error=error.localizedDescription;failTask(error.localizedDescription)}
                }
                do {try await ArchivePreparation.remove(workspace)}
                catch {
                    DiagnosticLog.shared.write(["event":"cleanup_error","stage":"archive","code":DiagnosticLog.category(error)])
                    status=completedBundle == nil ? "归档清理失败":"归档已生成，但临时来源记录清理失败"
                    failTask("临时来源记录清理失败");self.error="临时来源记录清理失败：\(workspace.path)\n\(error.localizedDescription)"
                }
                busy = false; cancelling = false; self.runner = nil
            }
        } catch {DiagnosticLog.shared.write(["event":"application_error","code":DiagnosticLog.category(error)]); self.error = error.localizedDescription; status = "无法执行归档"; failTask(error.localizedDescription) }
    }
    func resolveDestinationConflict() {
        guard !working else { return }
        let previous = destination
        let panel = NSOpenPanel()
        panel.title = "归档已存在，请选择其他保存位置"
        panel.message = "当前文件的归档目录已存在。选择其他文件夹后，将保留来源确认信息并重新执行归档；不会覆盖已有归档。"
        panel.prompt = "选择并重试"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.directoryURL = destination
        choosing = true
        let response = panel.runModal()
        choosing = false
        guard response == .OK, let selected = panel.url else {
            status = "归档已存在 · 已取消更换保存位置"
            return
        }
        guard selected.resolvingSymlinksInPath().standardizedFileURL != previous?.resolvingSymlinksInPath().standardizedFileURL else {
            status = "归档已存在 · 保存位置未更改"
            error = "保存位置未更改，请选择其他文件夹或修改归档名称。"
            return
        }
        destination = selected
        startArchive()
    }
    func exportMetadata() {
        guard let reportURL = metadataReportURL else { return }
        let panel = NSSavePanel()
        panel.title = "导出完整元数据记录"
        panel.nameFieldStringValue = "metadata.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                    DispatchQueue.global(qos:.utility).async {
                        do {
                            let temporary=url.deletingLastPathComponent().appendingPathComponent(".metadata-\(UUID()).json")
                            defer {try? FileManager.default.removeItem(at:temporary)}
                            try WriteBudget.copyTarget(from:reportURL,to:temporary)
                            if FileManager.default.fileExists(atPath:url.path) {
                                _=try FileManager.default.replaceItemAt(url,withItemAt:temporary)
                            } else {try FileManager.default.moveItem(at:temporary,to:url)}
                            continuation.resume()
                        } catch {continuation.resume(throwing:error)}
                    }
                }
            } catch {DiagnosticLog.shared.write(["event":"application_error","code":DiagnosticLog.category(error)]);self.error=error.localizedDescription}
        }
    }
    func reveal() { if let completedBundle { NSWorkspace.shared.activateFileViewerSelecting([completedBundle]) } }
    static let phaseNames = ["检查环境", "确认路径", "检查文件类型", "检查可用空间", "验证文件名兼容性", "计算源文件 SHA-512", "创建 7z 压缩包", "验证压缩参数", "测试压缩包", "实际解压并校验恢复数据", "复核源文件未发生变化", "计算归档 SHA-512", "生成内容索引", "生成双语记录", "最终检查与发布"]
}

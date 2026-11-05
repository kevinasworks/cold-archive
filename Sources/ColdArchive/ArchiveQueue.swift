// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import Combine

/// Independent reading and archive lanes; each job owns its confirmation and evidence.
@MainActor
final class ArchiveQueue: ObservableObject {
    struct Job: Identifiable {
        let id = UUID()
        let createdAt = Date()
        let model: ArchiveModel
        var started = false
        var cancelled = false
    }
    @Published private(set) var draft = ArchiveModel()
    @Published private(set) var jobs: [Job] = []
    var readingID: UUID? { jobs.first { $0.model.inspecting }?.id }
    var archivingID: UUID? { jobs.first { $0.model.busy }?.id }
    @Published var showQueueRequest = 0
    private var submittedCount = 0
    @Published var paused = false
    @Published var confirmationID: UUID?
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var deletingIDs = Set<UUID>()
    private var draftSubscription: AnyCancellable?
    init() { observeDraft() }
    private func observeDraft() {
        draftSubscription = draft.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var confirmationModel: ArchiveModel? { jobs.first { $0.id == confirmationID }?.model }
    var hasUnfinishedJobs: Bool {
        jobs.contains { !$0.cancelled && (!$0.started || $0.model.working || [.confirming, .ready].contains($0.model.task?.state)) }
    }
    var records: [ArchiveTask] {
        jobs.map { job in
            if job.started, var record = job.model.tasks.first {
                record.id = job.id
                return record
            }
            var record = ArchiveTask(id: job.id, name: job.model.archiveName, createdAt: job.createdAt, destination: job.model.destination)
            record.state = job.cancelled ? .cancelled : .queued
            record.status = job.cancelled ? "已取消等待中的任务" : "等待执行"
            return record
        }
    }
    func enqueue() {
        guard draft.canPrepare else { return }
        guard BatchArchiveDraft.validName(draft.archiveName) else {
            draft.error = "归档名称不能是路径或包含斜杠、换行。"; return
        }
        appendJob(draft)
        registerSubmission(count: 1)
        let destination = draft.destination
        draft = ArchiveModel(); draft.destination = destination
        observeDraft()
        reconcile()
    }
    func enqueueBatch(_ batch: BatchArchiveDraft) throws {
        let destination = try batch.validatedDestination()
        for entry in batch.entries {
            let model = ArchiveModel()
            model.selectSources([entry.source])
            model.archiveName = entry.name
            model.destination = destination
            appendJob(model)
        }
        registerSubmission(count: batch.entries.count)
        reconcile()
    }
    private func registerSubmission(count: Int) {
        let policy = UserDefaults.standard.string(forKey: "newTaskNavigation") ?? "first"
        if policy == "always" || (policy == "first" && submittedCount == 0) {
            showQueueRequest += 1
        }
        submittedCount += count
    }
    func pauseAll() {
        DiagnosticLog.shared.write(["event":"queue_state","code":"pause_requested"])
        paused = true
        for job in jobs { job.model.setAllPaused(true) }
    }
    func startAll() {
        DiagnosticLog.shared.write(["event":"queue_state","code":"resume_requested"])
        for job in jobs { job.model.setAllPaused(false) }
        paused = false
        reconcile()
    }
    func deleteAll() {
        // Deletion has its own cleanup gate; it is not a user pause that
        // should carry into a new batch.
        DiagnosticLog.shared.write(["event":"queue_state","code":"delete_requested"])
        paused = false
        confirmationID = nil
        deletingIDs.formUnion(jobs.map(\.id))
        for job in jobs { job.model.setAllPaused(false); cancel(job.id) }
        reconcile()
    }
    func setPaused(_ value: Bool) { paused = value; reconcile() }
    func showConfirmation(_ id: UUID) {
        guard jobs.first(where: { $0.id == id })?.model.task?.state == .confirming else { return }
        confirmationID = id
    }
    func toggleReadingPause(_ id: UUID) {
        guard readingID == id else { return }
        jobs.first { $0.id == id }?.model.toggleReadingPause()
    }
    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if !jobs[index].started {
            jobs[index].cancelled = true
        } else {
            let model = jobs[index].model
            if [.confirming, .ready].contains(model.task?.state) { model.cancelIntake(); if confirmationID == id { confirmationID = nil } }
            else { model.cancel() }
        }
        // Cancelling the last paused job ends that batch's pause. Keep an
        // explicit pause if other queued/active work still needs it. Cleanup
        // itself remains protected by model.working and the deletion gate.
        let remaining = jobs.contains { job in
            !job.cancelled && !deletingIDs.contains(job.id) && !job.model.cancelling &&
            (!job.started || job.model.working || [.confirming,.ready].contains(job.model.task?.state))
        }
        if paused && !remaining {
            paused = false
            DiagnosticLog.shared.write(["event":"queue_state","code":"pause_cleared_after_cancellation"])
        }
        reconcile()
    }
    func retry(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }),
              job.cancelled || (job.model.task.map({ [.failed, .cancelled].contains($0.state) }) ?? false) else { return }
        let model = ArchiveModel()
        model.selectSources(job.model.sources)
        model.archiveName = job.model.archiveName
        model.destination = job.model.destination
        appendJob(model)
        reconcile()
    }
    private func appendJob(_ model: ArchiveModel) {
        model.defersArchive = true
        let job = Job(model: model)
        jobs.append(job)
        subscriptions[job.id] = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
                self?.reconcile()
            }
        }
    }
    func moveEarlier(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].started, !jobs[index].cancelled,
              let previous = jobs[..<index].lastIndex(where: { !$0.started && !$0.cancelled }) else { return }
        jobs.swapAt(index, previous)
    }
    private var lastDispatchGate:String?
    private func reconcile() {
        let removable = jobs.filter { deletingIDs.contains($0.id) && !$0.model.working }.map(\.id)
        for id in removable { subscriptions.removeValue(forKey: id); deletingIDs.remove(id) }
        if !removable.isEmpty { jobs.removeAll { removable.contains($0.id) } }

        if let id = confirmationID, let model = jobs.first(where: { $0.id == id })?.model,
           !model.showingIntake {
            confirmationID = model.intake.complete
                ? jobs.first(where: { $0.model.task?.state == .confirming })?.id : nil
        }
        let gate = paused ? "user_paused" : !deletingIDs.isEmpty ? "deletion_cleanup" : "open"
        if lastDispatchGate != gate {
            lastDispatchGate = gate
            DiagnosticLog.shared.write(["event":"queue_dispatch_gate","code":gate,"waiting":jobs.filter{!$0.started && !$0.cancelled}.count])
        }
        guard !paused, deletingIDs.isEmpty else { return }
        if readingID == nil, let index = jobs.firstIndex(where: { !$0.started && !$0.cancelled }) {
            jobs[index].started = true
            jobs[index].model.prepare()
        }
        if archivingID == nil, let job = jobs.first(where: { $0.model.task?.state == .ready && !$0.model.working }) {
            job.model.startQueuedArchive()
        }
    }
}

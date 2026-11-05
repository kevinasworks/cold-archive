// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class ArchiveQueueTests: XCTestCase {
    @MainActor private func waitUntil(_ predicate: () -> Bool, queue: ArchiveQueue) async throws {
        let end = Date().addingTimeInterval(45)
        while !predicate() && Date() < end {
            XCTAssertLessThanOrEqual(queue.jobs.filter { $0.model.inspecting }.count, 1)
            XCTAssertLessThanOrEqual(queue.jobs.filter { $0.model.busy }.count, 1)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(predicate(), "Queue did not reach expected state")
    }
    @MainActor private func add(_ file: URL, name: String, output: URL, to queue: ArchiveQueue) {
        queue.draft.selectSources([file]); queue.draft.archiveName = name
        queue.draft.destination = output; queue.enqueue()
    }
    @MainActor func testQueueSnapshotsReorderCancelAndRealSequentialArchives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        let queue = ArchiveQueue(); queue.setPaused(true)
        add(first, name: "one", output: root, to: queue)
        add(second, name: "two", output: root, to: queue)
        add(first, name: "cancelled", output: root, to: queue)
        let cancelledID = queue.jobs[2].id
        queue.cancel(cancelledID)
        let secondID = queue.jobs[1].id
        queue.moveEarlier(secondID)
        XCTAssertEqual(queue.jobs[0].id, secondID)
        XCTAssertTrue(queue.jobs.allSatisfy { !$0.started })
        queue.draft.archiveName = "different draft"
        XCTAssertEqual(queue.jobs[0].model.archiveName, "two")
        XCTAssertEqual(queue.jobs[0].model.sources, [second])
        queue.setPaused(false)
        try await waitUntil({ queue.jobs.filter { $0.model.task?.state == .confirming }.count == 2 }, queue: queue)
        XCTAssertNil(queue.archivingID)
        for expectedName in ["two", "one"] {
            try await waitUntil({ queue.jobs.first(where: { $0.model.archiveName == expectedName })?.model.task?.state == .confirming }, queue: queue)
            let active = try XCTUnwrap(queue.jobs.first { $0.model.archiveName == expectedName })
            XCTAssertEqual(active.model.archiveName, expectedName)
            queue.showConfirmation(active.id)
            XCTAssertTrue(queue.confirmationModel === active.model)
            var count = 0
            while active.model.intake.current != nil && count < 100 {
                count += 1; active.model.submit(answer: active.model.intake.current == .notes ? "无补充" : "未知", english: "Unknown")
            }
            try await waitUntil({ active.model.task?.state == .completed && !active.model.working }, queue: queue)
            XCTAssertNotNil(active.model.completedBundle)
        }
        try await waitUntil({ queue.readingID == nil && queue.archivingID == nil }, queue: queue)
        XCTAssertFalse(queue.hasUnfinishedJobs)
        XCTAssertEqual(queue.records.filter { $0.state == .completed }.count, 2)
        XCTAssertEqual(queue.records.first { $0.id == cancelledID }?.state, .cancelled)
        XCTAssertFalse(queue.jobs.first { $0.id == cancelledID }!.started)
    }
    @MainActor func testPreloadAndContinuousConfirmationWhileArchiveDispatchPaused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-handoff-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data("sample".utf8).write(to: file)
        let queue = ArchiveQueue()
        add(file, name: "first", output: root, to: queue)
        add(file, name: "second", output: root, to: queue)
        try await waitUntil({ queue.jobs.allSatisfy { $0.model.task?.state == .confirming } }, queue: queue)
        queue.setPaused(true)
        queue.showConfirmation(queue.jobs[0].id)
        let first = queue.jobs[0].model
        while let field = first.intake.current {
            first.submit(answer: field == .notes ? "无补充" : "未知", english: "Unknown")
        }
        try await waitUntil({ queue.confirmationID == queue.jobs[1].id }, queue: queue)
        XCTAssertEqual(first.task?.state, .ready)
        XCTAssertNil(queue.archivingID)
        XCTAssertTrue(queue.hasUnfinishedJobs)
        XCTAssertFalse(queue.jobs[1].model.intake.complete)
        queue.cancel(queue.jobs[0].id)
        XCTAssertEqual(first.task?.state, .cancelled)
        XCTAssertEqual(queue.confirmationID, queue.jobs[1].id)
        queue.cancel(queue.jobs[1].id)
        XCTAssertFalse(queue.hasUnfinishedJobs)
    }

    @MainActor func testCreationNavigationPolicies() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "newTaskNavigation")
        defer { if let previous { defaults.set(previous, forKey: "newTaskNavigation") } else { defaults.removeObject(forKey: "newTaskNavigation") } }
        for (policy, expected) in [("first", 1), ("always", 2), ("never", 0)] {
            defaults.set(policy, forKey: "newTaskNavigation")
            let queue = ArchiveQueue(); queue.pauseAll()
            let source = URL(fileURLWithPath: "/tmp/synthetic.txt")
            add(source, name: "one", output: URL(fileURLWithPath: "/tmp"), to: queue)
            add(source, name: "two", output: URL(fileURLWithPath: "/tmp"), to: queue)
            XCTAssertEqual(queue.showQueueRequest, expected)
            queue.deleteAll()
        }
    }
    @MainActor func testBulkDeleteDrainsReaderAndPreservesSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.txt")
        try Data("keep".utf8).write(to: file)
        let queue = ArchiveQueue()
        queue.pauseAll()
        add(file, name: "first", output: root, to: queue)
        add(file, name: "second", output: root, to: queue)
        XCTAssertTrue(queue.jobs.allSatisfy { !$0.started })
        queue.startAll()
        XCTAssertNotNil(queue.readingID)
        queue.pauseAll()
        XCTAssertTrue(queue.jobs[0].model.readingPauseRequested)
        queue.deleteAll()
        try await waitUntil({ queue.jobs.isEmpty }, queue: queue)
        XCTAssertFalse(queue.hasUnfinishedJobs)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
        queue.startAll()
        XCTAssertFalse(queue.paused)
    }
    @MainActor func testFailureAdvancesAndConfirmationCancelUnblocksQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("valid.txt")
        try Data("valid".utf8).write(to: file)
        let queue = ArchiveQueue(); queue.setPaused(true)
        add(file, name: "failed", output: root.appendingPathComponent("missing-output"), to: queue)
        add(file, name: "valid", output: root, to: queue)
        queue.setPaused(false)
        try await waitUntil({ queue.jobs[0].model.task?.state == .confirming }, queue: queue)
        let first = queue.jobs[0].model
        var steps = 0
        while let field = first.intake.current, steps < 100 {
            steps += 1
            first.submit(answer: field == .notes ? "无补充" : "未知", english: "Unknown")
        }
        try await waitUntil({ queue.jobs[1].model.task?.state == .confirming }, queue: queue)
        try await waitUntil({ queue.jobs[0].model.task?.state == .failed }, queue: queue)
        queue.cancel(queue.jobs[1].id)
        try await waitUntil({ !queue.hasUnfinishedJobs }, queue: queue)
        XCTAssertEqual(queue.records[1].state, .cancelled)
    }
    @MainActor func testPauseWaitsForActiveCleanupAndRetryGetsNewIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("valid.txt")
        try Data("valid".utf8).write(to: file)
        let queue = ArchiveQueue()
        add(file, name: "first", output: root, to: queue)
        add(file, name: "second", output: root, to: queue)
        queue.setPaused(true)
        let firstID = queue.jobs[0].id
        queue.cancel(firstID)
        try await waitUntil({ queue.readingID == nil && queue.archivingID == nil }, queue: queue)
        XCTAssertFalse(queue.jobs[1].started)
        queue.retry(firstID)
        XCTAssertEqual(queue.jobs.count, 3)
        XCTAssertNotEqual(queue.jobs[2].id, firstID)
        XCTAssertFalse(queue.jobs[2].started)
        queue.cancel(queue.jobs[2].id)
        queue.setPaused(false)
        try await waitUntil({ queue.jobs[1].model.task?.state == .confirming }, queue: queue)
        queue.cancel(queue.jobs[1].id)
        XCTAssertFalse(queue.hasUnfinishedJobs)
    }

    @MainActor func testDeleteAllDoesNotLeaveFutureTasksPaused() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("queue-reset-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("fixture.txt")
        try Data("unchanged".utf8).write(to:file)
        let queue=ArchiveQueue();queue.pauseAll()
        add(file,name:"old",output:root,to:queue)
        queue.deleteAll()
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertFalse(queue.paused,"Deleting the old batch must not pause future submissions")
        guard !queue.paused else {return}
        add(file,name:"new",output:root,to:queue)
        try await waitUntil({queue.jobs.first?.model.task?.state == .confirming},queue:queue)
        queue.cancel(queue.jobs[0].id)
        XCTAssertEqual(try Data(contentsOf:file),Data("unchanged".utf8))
    }
    @MainActor func testCancelLastPausedReaderThenEnqueueWithoutStartAll() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("queue-cancel-reset-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("fixture.txt")
        try Data("unchanged".utf8).write(to:file)
        let queue=ArchiveQueue()
        add(file,name:"old",output:root,to:queue)
        let old=queue.jobs[0]
        queue.pauseAll();queue.cancel(old.id)
        XCTAssertFalse(queue.paused)
        add(file,name:"new",output:root,to:queue)
        let new=queue.jobs[1]
        try await waitUntil({new.model.task?.state == .confirming && !old.model.working},queue:queue)
        XCTAssertEqual(old.model.task?.state,.cancelled)
        queue.cancel(new.id)
        XCTAssertEqual(try Data(contentsOf:file),Data("unchanged".utf8))
    }
    @MainActor func testCancellingOnePausedJobPreservesOtherPausedJobs() {
        let queue=ArchiveQueue();queue.pauseAll()
        let file=URL(fileURLWithPath:"/tmp/synthetic-queue-paused.txt")
        add(file,name:"one",output:file.deletingLastPathComponent(),to:queue)
        add(file,name:"two",output:file.deletingLastPathComponent(),to:queue)
        queue.cancel(queue.jobs[0].id)
        XCTAssertTrue(queue.paused)
        XCTAssertFalse(queue.jobs[1].started)
        queue.cancel(queue.jobs[1].id)
        XCTAssertFalse(queue.paused)
    }
    @MainActor func testEnqueueDuringBulkDeletionWaitsForCleanupThenStarts() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("queue-delete-drain-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("fixture.txt")
        try Data("unchanged".utf8).write(to:file)
        let queue=ArchiveQueue()
        add(file,name:"old",output:root,to:queue)
        let old=queue.jobs[0].model
        queue.pauseAll();queue.deleteAll()
        add(file,name:"new",output:root,to:queue)
        let new=try XCTUnwrap(queue.jobs.last).model
        try await waitUntil({queue.jobs.count==1 && new.task?.state == .confirming && !old.working},queue:queue)
        XCTAssertFalse(queue.paused)
        queue.cancel(queue.jobs[0].id)
        XCTAssertEqual(try Data(contentsOf:file),Data("unchanged".utf8))
    }

    @MainActor func testMixedBatchValidatesBeforeEnqueueAndCompletesIndependentArchives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-\(UUID())")
        let folder = root.appendingPathComponent("照片")
        let nested = folder.appendingPathComponent("原始")
        let destination = root.appendingPathComponent("归档")
        for directory in [nested, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let child = nested.appendingPathComponent("记录.csv")
        let independent = root.appendingPathComponent("记录.csv")
        try Data("child".utf8).write(to: child)
        try Data("independent".utf8).write(to: independent)

        var batch = BatchArchiveDraft()
        XCTAssertEqual(batch.append([folder, independent]), 0)
        XCTAssertEqual(batch.append([child, folder]), 0)
        XCTAssertEqual(batch.entries.map(\.source.path), [folder, independent, child].map(\.path))
        XCTAssertEqual(batch.entries.map(\.isDirectory), [true, false, false])
        XCTAssertEqual(batch.entries.map(\.name), ["照片", "记录.csv", "记录.csv"])
        XCTAssertEqual(batch.nestedEntries, [batch.entries[2].id])
        batch.destination = destination
        let queue = ArchiveQueue()
        queue.pauseAll()
        queue.draft.selectSources([independent])
        let originalDraft = queue.draft
        XCTAssertThrowsError(try queue.enqueueBatch(batch))
        XCTAssertTrue(queue.jobs.isEmpty)

        batch.entries[2].name = "照片记录"
        batch.destination = nested
        XCTAssertThrowsError(try queue.enqueueBatch(batch))
        XCTAssertTrue(queue.jobs.isEmpty)
        batch.destination = destination
        try queue.enqueueBatch(batch)
        XCTAssertTrue(queue.draft === originalDraft)
        XCTAssertEqual(queue.jobs.map { $0.model.sources.map(\.path) }, [[folder.path], [independent.path], [child.path]])
        XCTAssertTrue(queue.jobs.allSatisfy { $0.model.destination?.path == destination.path })
        XCTAssertEqual(Set(queue.jobs.map(\.id)).count, 3)
        queue.startAll()
        try await waitUntil({ queue.jobs.allSatisfy { $0.model.task?.state == .confirming } }, queue: queue)
        for job in queue.jobs {
            queue.showConfirmation(job.id)
            XCTAssertTrue(queue.confirmationModel === job.model)
            while let field = job.model.intake.current {
                job.model.submit(answer: field == .notes ? "无补充" : "未知", english: "Unknown")
            }
            try await waitUntil({ job.model.task?.state == .completed && !job.model.working }, queue: queue)
            let bundle = try XCTUnwrap(job.model.completedBundle)
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(job.model.archiveName + ".7z").path))
            if job.model.archiveName == "照片" {
                let manifest = try String(contentsOf: bundle.appendingPathComponent("Documents/SHA512.md"), encoding: .utf8)
                XCTAssertTrue(manifest.contains("原始/记录.csv"))
            }
        }
        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "child")
        XCTAssertEqual(try String(contentsOf: independent, encoding: .utf8), "independent")
    }

    @MainActor func testBatchNavigationAndIndependentCancelAndRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-nav-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ["a.txt", "b.txt"].map { root.appendingPathComponent($0) }
        for source in sources { try Data("fixture".utf8).write(to: source) }
        var batch = BatchArchiveDraft()
        _ = batch.append(sources)
        batch.destination = root
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "newTaskNavigation")
        defer {
            if let previous { defaults.set(previous, forKey: "newTaskNavigation") }
            else { defaults.removeObject(forKey: "newTaskNavigation") }
        }
        for (policy, first, second) in [("first", 1, 1), ("always", 1, 2), ("never", 0, 0)] {
            defaults.set(policy, forKey: "newTaskNavigation")
            let queue = ArchiveQueue()
            queue.pauseAll()
            try queue.enqueueBatch(batch)
            XCTAssertEqual(queue.showQueueRequest, first)
            let cancelled = queue.jobs[0].id
            queue.cancel(cancelled)
            XCTAssertEqual(queue.records.map(\.state), [.cancelled, .queued])
            queue.retry(cancelled)
            XCTAssertEqual(queue.jobs.last?.model.sources, [sources[0]])
            XCTAssertNotEqual(queue.jobs.last?.id, cancelled)
            try queue.enqueueBatch(batch)
            XCTAssertEqual(queue.showQueueRequest, second)
            queue.deleteAll()
        }
    }

}

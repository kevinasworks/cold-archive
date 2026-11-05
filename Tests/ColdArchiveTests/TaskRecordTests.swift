// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class TaskRecordTests: XCTestCase {
    @MainActor func testSelectionPreservesTaskResultAndIdentity() async {
        let model = ArchiveModel()
        model.archiveName = "第一批"
        model.destination = URL(fileURLWithPath: "/tmp/output")
        model.beginTaskRecord()
        let id = model.task!.id
        model.log = "执行记录"
        model.cancelIntake()
        model.selectSources([URL(fileURLWithPath: "/tmp/next")])
        XCTAssertNil(model.task)
        XCTAssertEqual(model.tasks.count, 1)
        XCTAssertEqual(model.tasks[0].id, id)
        XCTAssertEqual(model.tasks[0].name, "第一批")
        XCTAssertEqual(model.tasks[0].state, .cancelled)
        XCTAssertEqual(model.tasks[0].log, "执行记录")
        model.selectSources([URL(fileURLWithPath: "/tmp/another")])
        XCTAssertEqual(model.tasks.count, 1, "Form changes must not duplicate history")
        model.beginTaskRecord()
        XCTAssertNotEqual(model.task!.id, id)
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertEqual(model.tasks[1].log, "执行记录")
    }
    @MainActor func testLiveProgressAndCancellationStayActiveUntilWorkEnds() async {
        let model = ArchiveModel()
        model.beginTaskRecord()
        model.inspecting = true
        model.metadataProgress = "已完成 8/100 · 正在读取 10 个"
        XCTAssertEqual(model.tasks[0].detail, model.metadataProgress)
        model.cancel()
        XCTAssertTrue(model.tasks[0].running)
        XCTAssertTrue(model.tasks[0].cancelling)
        XCTAssertEqual(model.tasks[0].state, .reading)
        model.inspecting = false
        XCTAssertFalse(model.tasks[0].running)
    }
}

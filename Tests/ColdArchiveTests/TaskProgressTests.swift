// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class TaskProgressTests: XCTestCase {
    func testOverallProgressIncludesConfirmationAndRequiresPublication() {
        var task = ArchiveTask(id: UUID(), name: "test", createdAt: Date())
        task.state = .queued
        XCTAssertEqual(task.overallProgress, 0)
        task.state = .confirming
        XCTAssertEqual(task.overallProgress, 1.0 / 21.0, accuracy: 0.00001)
        task.confirmationSteps = 2.5
        XCTAssertEqual(task.overallProgress, 3.5 / 21.0, accuracy: 0.00001)
        task.state = .ready
        XCTAssertEqual(task.overallProgress, 6.0 / 21.0, accuracy: 0.00001)
        task.state = .archiving
        task.phase = 15
        XCTAssertLessThan(task.overallProgress, 1)
        task.state = .failed
        XCTAssertLessThan(task.overallProgress, 1)
        task.state = .completed
        XCTAssertEqual(task.overallProgress, 1)
    }
    func testActivePhaseIsNotCountedAsCompleteAndFailureKeepsStage() {
        var task = ArchiveTask(id: UUID(), name: "test", createdAt: Date())
        task.state = .confirming
        XCTAssertEqual(task.stageIndex, 1)
        task.state = .archiving
        task.phase = 7
        XCTAssertEqual(task.completedArchivePhases, 6)
        task.state = .failed
        XCTAssertEqual(task.stageIndex, 2)
        XCTAssertEqual(task.completedArchivePhases, 6)
        task.phase = 15
        XCTAssertEqual(task.completedArchivePhases, 14)
        task.state = .completed
        XCTAssertEqual(task.completedArchivePhases, 15)
        XCTAssertEqual(task.stageIndex, 3)
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class FailurePresentationTests: XCTestCase {
    func testConflictWinsOverEarlierSuccessfulChecks() {
        let failure = ArchiveFailure.describe("SOURCE_SHA512 MATCH\nEverything is Ok\nRefusing to overwrite existing final archive directory: /fixture/archive")
        XCTAssertTrue(failure.destinationConflict)
        XCTAssertEqual(failure.title, "归档已存在")
        XCTAssertFalse(failure.reason.contains("Everything is Ok"))
    }
    func testUnknownFailureDoesNotClaimSuccessfulHashIsFailure() {
        let failure = ArchiveFailure.describe("SOURCE_SHA512 MATCH\nUnexpected failure")
        XCTAssertEqual(failure.title, "操作未完成")
        XCTAssertFalse(failure.destinationConflict)
    }
    func testActionableCausesAndNoLogDump() {
        XCTAssertEqual(ArchiveFailure.describe("No space left on device").title, "存储空间不足")
        XCTAssertEqual(ArchiveFailure.describe("Permission denied").title, "无法访问文件或保存位置")
        XCTAssertEqual(ArchiveFailure.describe("File changed while hashing: /fixture").title, "源文件一致性检查未通过")
        XCTAssertEqual(ArchiveFailure.describe("归档名称不能是路径或包含斜杠。").reason, "归档名称不能是路径或包含斜杠。")
        XCTAssertLessThan(ArchiveFailure.describe(String(repeating: "tool log\n", count: 1000)).reason.count, 100)
    }
}

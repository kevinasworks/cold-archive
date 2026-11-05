// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class LifecycleTests: XCTestCase {
    @MainActor
    private func idle(_ model: ArchiveModel) async throws {
        let end = Date().addingTimeInterval(60)
        while model.working && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        if model.working { model.cancel(); XCTFail("Task timed out") }
        XCTAssertFalse(model.working)
    }
    @MainActor
    private func confirm(_ model: ArchiveModel) {
        var count = 0
        while let field = model.intake.current, count < 100 {
            count += 1
            model.submit(answer: field == .notes ? "无补充" : "未知／不填写", english: "")
        }
    }
    @MainActor
    func testAppendedFilesAcrossRootBranchesCompleteArchive() async throws {
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("QA/selection-\(UUID())")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID())")
        for directory in [local, temporary] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: temporary) }
        let first = local.appendingPathComponent("same.csv")
        let second = temporary.appendingPathComponent("same.csv")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let unselected = local.appendingPathComponent("not-selected.txt")
        try Data("must not archive".utf8).write(to: unselected)
        let model = ArchiveModel()
        model.destination = temporary
        model.appendFiles([first]); model.appendFiles([second, first])
        model.archiveName = "不同位置合并"
        model.prepare(); try await idle(model)
        XCTAssertNil(model.error)
        confirm(model); try await idle(model)
        XCTAssertNil(model.error)
        let bundle = try XCTUnwrap(model.completedBundle)
        let index = try String(contentsOf: bundle.appendingPathComponent("Documents/ARCHIVE_CONTENTS.md"), encoding: .utf8)
        XCTAssertFalse(index.contains("not-selected.txt"))
        XCTAssertTrue(index.contains(local.lastPathComponent))
        XCTAssertTrue(index.contains(temporary.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    @MainActor
    func testSequentialArchivesFailureAndRetryInSameModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ColdArchive-Lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let first = root.appendingPathComponent("first.csv")
        let second = root.appendingPathComponent("第二个.txt")
        try Data("name,value\ntest,42\n".utf8).write(to: first)
        try Data("Synthetic second file\n".utf8).write(to: second)
        let model = ArchiveModel(); model.destination = output
        for source in [first, second] {
            model.selectSources([source]); model.prepare(); try await idle(model)
            XCTAssertNil(model.error)
            XCTAssertTrue(model.showingIntake)
            confirm(model); try await idle(model)
            XCTAssertNil(model.error)
            XCTAssertNotNil(model.completedBundle)
            XCTAssertEqual(model.phase, 15)
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        model.selectSources([first]); model.prepare(); try await idle(model)
        confirm(model); try await idle(model)
        XCTAssertNotNil(model.error, "Existing archive must fail safely")
        XCTAssertNil(model.completedBundle)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(), before)
        model.selectSources([first, second]); model.archiveName = "Multiple"
        model.prepare(); try await idle(model); confirm(model); try await idle(model)
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.completedBundle)
        XCTAssertEqual(try Data(contentsOf: first), Data("name,value\ntest,42\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("Synthetic second file\n".utf8))
    }
    @MainActor
    func testImmediateCancelAtArchiveStartupIsNotFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ColdArchive-Cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("synthetic".utf8).write(to: file)
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let model = ArchiveModel(); model.destination = output
        model.selectSources([file]); model.prepare(); try await idle(model)
        for delay: UInt64 in [0, 2_000_000, 10_000_000, 30_000_000] {
            if !model.showingIntake { model.selectSources([file]); model.prepare(); try await idle(model) }
            confirm(model)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            model.cancel(); try await idle(model)
            XCTAssertNil(model.error, "Cancel delay: \(delay)")
            XCTAssertEqual(model.status, "归档已取消 · 临时文件已清理")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        }
        model.selectSources([file]); model.prepare(); model.cancel(); try await idle(model)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.showingIntake)
        XCTAssertEqual(model.status, "元数据读取已取消")
    }
    @MainActor
    func testInvalidNameMissingFileAndCancelledIntakeRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ColdArchive-Validation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.csv")
        try Data("a,b\n1,2\n".utf8).write(to: file)
        let model = ArchiveModel(); model.destination = root
        model.selectSources([file])
        for name in [".", "..", "a/b", "a\0b"] {
            model.archiveName = name; model.prepare()
            XCTAssertNotNil(model.error)
            XCTAssertFalse(model.working)
        }
        model.selectSources([file]); model.prepare(); try await idle(model)
        model.submit(answer: "表格", english: "Table")
        model.cancelIntake()
        XCTAssertEqual(model.intake.current, .sourceType)
        XCTAssertFalse(model.showingIntake)
        model.prepare(); try await idle(model)
        XCTAssertTrue(model.showingIntake)
        XCTAssertEqual(model.intake.current, .sourceType)
        try FileManager.default.removeItem(at: file)
        confirm(model)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.working)
        XCTAssertNil(model.completedBundle)
        model.selectSources([file]); model.prepare(); try await idle(model)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.showingIntake)
        XCTAssertNil(model.metadata)
    }
    @MainActor
    func testEmptyDirectoryAndZeroByteFileArchives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ColdArchive-Empty-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("空目录", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("zero.txt")
        try Data().write(to: file)
        let model = ArchiveModel(); model.destination = output
        for source in [folder, file] {
            model.selectSources([source]); model.prepare(); try await idle(model)
            XCTAssertNil(model.error)
            confirm(model); try await idle(model)
            XCTAssertNil(model.error)
            XCTAssertNotNil(model.completedBundle)
        }
    }
}

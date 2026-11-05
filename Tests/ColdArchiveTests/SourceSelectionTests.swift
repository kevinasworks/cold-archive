// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class SourceSelectionTests: XCTestCase {
    @MainActor
    func testAppendAcrossLocationsDeduplicatesAndPreservesCustomName() async {
        let model = ArchiveModel()
        let a = URL(fileURLWithPath: "/tmp/a/same.csv")
        let b = URL(fileURLWithPath: "/tmp/b/same.csv")
        model.appendFiles([a])
        model.appendFiles([a, b, b])
        XCTAssertEqual(model.sources, [a, b])
        XCTAssertEqual(model.archiveName, "")
        model.archiveName = "合并批次"
        model.appendFiles([URL(fileURLWithPath: "/tmp/c.txt")])
        XCTAssertEqual(model.archiveName, "合并批次")
        model.removeSource(a)
        XCTAssertEqual(model.sources.count, 2)
        XCTAssertEqual(model.archiveName, "合并批次")
        model.busy = true
        model.clearSources()
        model.appendFiles([a])
        model.removeSource(b)
        XCTAssertEqual(model.sources.count, 2)
        model.busy = false
        model.clearSources()
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertFalse(model.canPrepare)
    }

    @MainActor
    func testSelectionAfterCompletionResetsPreviousArchive() async throws {
        let model = ArchiveModel()
        let destination = URL(fileURLWithPath: "/tmp/archives")
        model.destination = destination
        model.selectSources([URL(fileURLWithPath: "/tmp/Disks.csv")])
        model.archiveName = "Previous custom name"
        model.completedBundle = destination.appendingPathComponent("Previous")
        model.log = "PHASE 9 completed"
        model.phase = 9
        model.status = "归档完成 · 所有验证已通过"
        model.error = "Previous error"
        let metadataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("selection-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: false)
        let metadataURL = metadataDirectory.appendingPathComponent("metadata.json")
        try "Previous metadata".write(to: metadataURL, atomically: true, encoding: .utf8)
        model.retainMetadataReport(metadataURL)
        model.metadataProgress = "Previous progress"
        model.showingIntake = true
        model.cancelling = true
        try model.intake.submit(.sourceType, answer: "照片", english: "Photos")

        let next = URL(fileURLWithPath: "/tmp/ch12_20250918094519.mp4")
        model.selectSources([next])
        XCTAssertEqual(model.sources, [next])
        XCTAssertEqual(model.archiveName, next.lastPathComponent)
        XCTAssertEqual(model.destination, destination)
        XCTAssertNil(model.completedBundle)
        XCTAssertNil(model.metadata)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.metadataJSON, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataDirectory.path))
        XCTAssertEqual(model.metadataProgress, "正在枚举文件…")
        XCTAssertEqual(model.log, "")
        XCTAssertEqual(model.phase, 0)
        XCTAssertEqual(model.status, "准备归档")
        XCTAssertEqual(model.intake.current, .sourceType)
        XCTAssertFalse(model.showingIntake)
        XCTAssertFalse(model.cancelling)
        XCTAssertTrue(model.canPrepare)
    }

    @MainActor
    func testRepeatedFileFolderAndMultipleSelections() async {
        let model = ArchiveModel()
        let file = URL(fileURLWithPath: "/tmp/照片.jpg")
        let folder = URL(fileURLWithPath: "/tmp/旅行资料", isDirectory: true)
        model.destination = URL(fileURLWithPath: "/tmp/output")
        model.selectSources([file])
        XCTAssertEqual(model.archiveName, "照片.jpg")
        model.selectSources([folder])
        XCTAssertEqual(model.archiveName, "旅行资料")
        model.selectSources([file, folder])
        XCTAssertEqual(model.archiveName, "")
        XCTAssertFalse(model.canPrepare)
        model.archiveName = "自定义"
        model.selectSources([file])
        XCTAssertEqual(model.archiveName, "照片.jpg")
        model.archiveName = "再次自定义"
        model.selectSources([file])
        XCTAssertEqual(model.archiveName, "照片.jpg")
    }

    @MainActor
    func testEmptySelectionAndActiveWorkPreserveCurrentTask() async {
        let model = ArchiveModel()
        let original = URL(fileURLWithPath: "/tmp/original")
        model.selectSources([original])
        model.archiveName = "Keep custom name"
        model.log = "Keep result"
        model.selectSources([])
        XCTAssertEqual(model.archiveName, "Keep custom name")
        XCTAssertEqual(model.log, "Keep result")
        model.busy = true
        model.selectSources([URL(fileURLWithPath: "/tmp/replacement")])
        XCTAssertEqual(model.sources, [original])
        model.busy = false
        model.inspecting = true
        model.selectSources([URL(fileURLWithPath: "/tmp/replacement")])
        XCTAssertEqual(model.sources, [original])
        XCTAssertEqual(model.archiveName, "Keep custom name")
    }
}

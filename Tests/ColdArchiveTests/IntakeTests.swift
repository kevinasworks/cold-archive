// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class IntakeTests: XCTestCase {
    func testUnknownAndOmittedRemainDistinctWithoutTranslation() throws {
        var intake = Intake()
        try intake.submit(.sourceType, answer: "未知", english: "")
        try intake.submit(.device, answer: "不填写", english: "")
        XCTAssertEqual(intake.answers["source_type"]?.answer, "未知")
        XCTAssertEqual(intake.answers["device"]?.answer, "不填写")
        XCTAssertNil(intake.answers["source_type"]?.en)
        XCTAssertNil(intake.answers["device"]?.en)
    }
    func testBackEditPreservesLaterAnswersAndRequiresForwardConfirmation() throws {
        var intake = Intake()
        intake.goBack()
        XCTAssertEqual(intake.stepIndex, 0)
        try intake.submit(.sourceType, answer: "照片", english: "Photos")
        try intake.submit(.device, answer: "未知／不填写", english: "")
        intake.goBack()
        intake.goBack()
        XCTAssertEqual(intake.current, .sourceType)
        XCTAssertEqual(intake.answers["device"]?.answer, "未知／不填写")
        try intake.submit(.sourceType, answer: "视频", english: "Video")
        XCTAssertEqual(intake.current, .device)
        XCTAssertFalse(intake.complete)
        XCTAssertThrowsError(try intake.document(sources: []))
        try intake.submit(.device, answer: "Camera", english: "Camera")
        try intake.submit(.software, answer: "未知／不填写", english: "")
        try intake.submit(.purpose, answer: "备份", english: "Backup")
        intake.goBack()
        XCTAssertEqual(intake.current, .purpose)
        try intake.submit(.purpose, answer: "留存", english: "Preservation")
        try intake.submit(.notes, answer: "无补充", english: "")
        XCTAssertTrue(intake.complete)
        XCTAssertEqual(intake.answers["source_type"]?.answer, "视频")
        XCTAssertEqual(intake.answers["purpose"]?.en, "Preservation")
    }
    func testCannotSkipOrSerializeIncompleteConfirmation() throws {
        var intake = Intake()
        XCTAssertThrowsError(try intake.document(sources: []))
        XCTAssertThrowsError(try intake.submit(.purpose, answer: "测试", english: "Test"))
        XCTAssertEqual(intake.current, .sourceType)
    }
    func testExactAnswersBoundToSourcesAndDistinctFields() throws {
        var intake = Intake()
        try intake.submit(.sourceType, answer: "原始照片", english: "Original photos")
        try intake.submit(.device, answer: "未知／不填写", english: "")
        try intake.submit(.software, answer: "未知／不填写", english: "")
        try intake.submit(.purpose, answer: "旅行留存", english: "Travel preservation")
        try intake.submit(.notes, answer: "无补充", english: "")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Intake-\(UUID()).txt")
        try Data("fixture".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let data = try intake.document(sources: [source])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 2)
        let answers = try XCTUnwrap(object["answers"] as? [String: [String: String]])
        XCTAssertEqual(answers["source_type"]?["answer"], "原始照片")
        XCTAssertEqual(answers["purpose"]?["answer"], "旅行留存")
        XCTAssertEqual(answers["notes"]?["answer"], "无补充")
        XCTAssertTrue(answers.values.allSatisfy { $0["status"] == "submitted" })
        XCTAssertTrue(intake.complete)
    }
    func testCustomNeedsContentAndTranslation() throws {
        var intake = Intake()
        XCTAssertThrowsError(try intake.submit(.sourceType, answer: "自定义填写", english: "Custom"))
        XCTAssertThrowsError(try intake.submit(.sourceType, answer: "照片", english: ""))
        XCTAssertEqual(intake.current, .sourceType)
    }
}

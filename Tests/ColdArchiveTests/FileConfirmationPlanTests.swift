// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class FileConfirmationPlanTests: XCTestCase {
    func fixture() -> MetadataReport {
        var paths: [String] = []; var candidates: [MetadataReport.Candidate] = []
        func add(_ file: String, _ field: String, _ value: String) {
            candidates.append(.init(field: field, value: value, file: file, tag: field, tool: "fixture", en: value, raw_value: nil, kind: nil))
        }
        for (prefix, count, category) in [("A",10,"Video"),("B",3,"Image"),("C",6,"CSV")] {
            for index in 1...count {
                let path = "/fixture/\(prefix)\(index)"; paths.append(path)
                add(path,"source_type",category)
                let device: String
                if prefix == "A" { device = index <= 5 ? "Device A" : (index <= 8 ? "Device B" : "Device C") }
                else if prefix == "B" { device = index == 1 ? "Device A" : "Device B" }
                else { device = index <= 3 ? "Device A" : (index <= 5 ? "Device B" : "Device C") }
                add(path,"capture_device_model",device)
            }
        }
        var report = MetadataReport(brand_findings: nil, total_included_files: 19, inspected_file_count: 19, selected_file_count: 19, coverage: "all", tool: "fixture", candidates: candidates, errors: [], warnings: [])
        report.file_paths = paths
        return report
    }
    func testUserExamplePartitionsByCategoryAndDevice() {
        let report = fixture()
        XCTAssertEqual(report.fileConfirmationPlan(for: .sourceType).count, 3)
        let groups = report.fileConfirmationPlan(for: .device)
        XCTAssertEqual(groups.count, 8)
        XCTAssertEqual(groups.filter { $0.category == "Video" }.map { $0.files.count }.sorted(), [2,3,5])
        XCTAssertEqual(groups.filter { $0.category == "Image" }.map { $0.files.count }.sorted(), [1,2])
        XCTAssertEqual(groups.filter { $0.category == "CSV" }.map { $0.files.count }.sorted(), [1,2,3])
        XCTAssertEqual(groups.flatMap(\.files).count, 19)
        XCTAssertEqual(Set(groups.flatMap(\.files)).count, 19)
        XCTAssertEqual(report.fileConfirmationPlan(for: .software).count, 3)
        XCTAssertEqual(report.fileConfirmationPlan(for: .purpose).count, 3)
    }
    func testPerGroupAnswersBackAndNoPrematureCompletion() throws {
        var intake = Intake(report: fixture())
        for _ in 0..<3 { try intake.submit(.sourceType, answer: "未知", english: "") }
        XCTAssertEqual(intake.current, .device)
        let firstFiles = intake.currentGroup!.files
        try intake.submit(.device, answer: "改正后的设备", english: "Corrected device")
        XCTAssertEqual(intake.current, .device)
        try intake.submit(.device, answer: "不填写", english: "")
        intake.goBack()
        XCTAssertEqual(intake.currentResponse?.answer, "不填写")
        intake.goBack()
        XCTAssertEqual(intake.currentResponse?.answer, "改正后的设备")
        XCTAssertEqual(intake.currentGroup?.files, firstFiles)
        try intake.submit(.device, answer: "未知", english: "")
        XCTAssertEqual(intake.groupedAnswers["device"]?.count, 2)
        XCTAssertEqual(intake.currentResponse?.answer, "不填写")
        XCTAssertThrowsError(try intake.document(sources: []))
        var count = 0
        while let field = intake.current {
            try intake.submit(field, answer: field == .notes ? "无补充" : "未知", english: "")
            count += 1; XCTAssertLessThan(count, 30)
        }
        XCTAssertTrue(intake.complete)
        XCTAssertEqual(intake.groupedAnswers["device"]?.count, 8)
    }
    func testConflictAndUnknownCannotDisappearOrDuplicateFiles() {
        let candidates = ["Device A", "Device B"].map { MetadataReport.Candidate(field: "capture_device_model", value: $0, file: "/a", tag: "Model", tool: "fixture", en: $0, raw_value: nil, kind: nil) }
        var report = MetadataReport(brand_findings: nil, total_included_files: 2, inspected_file_count: 1, selected_file_count: 2, coverage: "partial", tool: "fixture", candidates: candidates, errors: [], warnings: [])
        report.file_paths = ["/a", "/b"]
        let groups = report.fileConfirmationPlan(for: .device)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.first { $0.files == ["/a"] }!.conflict)
        XCTAssertTrue(groups.first { $0.files == ["/b"] }!.suggestion.isEmpty)
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class MetadataPresentationTests: XCTestCase {
    func testFormatConfirmationPreservesUncertaintyAndEvidence() throws {
        let finding = MetadataReport.BrandFinding(brand: "Hikvision", role: "format_family", basis: "signature", file: "/fixture/video.mp4", tag: "header.signature", scope: "main", status: "unverified")
        XCTAssertTrue(finding.confirmation.zh.contains("实际生成设备及型号未确认"))
        XCTAssertTrue(finding.confirmation.en.contains("unconfirmed"))
        XCTAssertTrue(finding.confirmation.zh.contains("header.signature"))
        let r = MetadataReport(brand_findings: [finding], total_included_files: 1, inspected_file_count: 1, selected_file_count: 1, coverage: "partial", tool: "exiftool", candidates: [], errors: [], warnings: [])
        XCTAssertEqual(r.formatFindings.count, 1)
        XCTAssertTrue(r.candidates(for: .device).isEmpty)
        XCTAssertTrue(r.suggestion(for: .device).zh.isEmpty)
        XCTAssertTrue(r.explanation(for: .device).contains("可选择保留线索"))
        XCTAssertTrue(MetadataReport.diagnostic("File format error").contains("ExifTool"))
        XCTAssertTrue(MetadataReport.diagnostic("File format error").contains("不代表文件损坏"))
        XCTAssertTrue(MetadataReport.diagnostic("Private format recognized; unknown proprietary fields may remain").contains("尚未解码"))
    }
    private func report(_ candidates: [[String: Any]] = [], count: Int = 1, read: Int = 1, errors: [[String:String]] = [], warnings: [[String:String]] = []) throws -> MetadataReport {
        let object: [String: Any] = ["total_included_files": count, "inspected_file_count": read,
            "selected_file_count": count, "coverage": "all_files", "tool": "/synthetic/exiftool",
            "candidates": candidates, "errors": errors, "warnings": warnings]
        return try JSONDecoder().decode(MetadataReport.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func candidate(_ field: String, _ value: String, english: String? = nil, file: String = "/synthetic/a") -> [String:Any] {
        var c: [String:Any] = ["field":field,"value":value,"file":file,"tag":"File:FileType","tool":"exiftool"]
        if let english { c["en"] = english }
        return c
    }
    func testCategoryReachesFormWithoutEvidencePollutingAnswer() throws {
        let r = try report([candidate("source_type", "CSV 数据文件", english: "CSV data files"), candidate("source_type", "CSV 数据文件", english: "CSV data files")])
        XCTAssertEqual(r.candidates(for: .sourceType).count, 2)
        XCTAssertEqual(r.suggestion(for: .sourceType).zh, "CSV 数据文件")
        XCTAssertEqual(r.suggestion(for: .sourceType).en, "CSV data files")
        XCTAssertTrue(r.explanation(for: .sourceType).contains("建议"))
    }
    func testNoMetadataClaimsForUserAuthoredFields() throws {
        for r in [try report(), try report(count: 0, read: 0), try report(read: 0, errors: [["error":"Failed"]])] {
            XCTAssertTrue(r.explanation(for: .purpose).contains("由你填写"))
            XCTAssertTrue(r.explanation(for: .notes).contains("由你决定"))
            XCTAssertTrue(r.candidates(for: .purpose).isEmpty)
            XCTAssertTrue(r.candidates(for: .notes).isEmpty)
        }
    }
    func testEmptyAndFailedAndSuccessfulReadsAreDistinct() throws {
        XCTAssertTrue(try report(count: 0, read: 0).summary.contains("没有可读取"))
        XCTAssertTrue(try report(read: 0, errors: [["error":"Failed"]]).explanation(for: .device).contains("尚无成功读取"))
        XCTAssertTrue(try report().explanation(for: .device).contains("没有找到可识别"))
        XCTAssertTrue(try report(warnings: [["file":"/synthetic/a","warning":"Partial"]]).explanation(for: .software).contains("不能据此判断"))
    }
    func testMixedDevicesRetainFileMappingAndNoInventedEnglish() throws {
        let r = try report([candidate("capture_device_model", "Camera A", english: "Camera A"), candidate("capture_device_model", "Camera B", english: "Camera B", file: "/synthetic/b")], count: 2, read: 2)
        XCTAssertTrue(r.suggestion(for: .device).zh.contains("Camera A [/synthetic/a]"))
        XCTAssertTrue(r.suggestion(for: .device).zh.contains("Camera B [/synthetic/b]"))
        let chinese = try report([candidate("capture_device_model", "中文型号")])
        XCTAssertEqual(chinese.suggestion(for: .device).en, "")
        XCTAssertEqual(chinese.suggestion(for: .device).zh, "中文型号")
    }
    func testMixedCategoriesAreNotCollapsedToOne() throws {
        let r = try report([candidate("source_type", "CSV 数据文件", english: "CSV data files"), candidate("source_type", "图像文件", english: "Image files", file: "/synthetic/b")], count: 2, read: 2)
        XCTAssertEqual(r.suggestion(for: .sourceType).zh, "CSV 数据文件；图像文件")
        XCTAssertEqual(r.suggestion(for: .sourceType).en, "CSV data files; Image files")
    }
}

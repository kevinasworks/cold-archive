// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class ConfirmationGroupsTests: XCTestCase {
    func test309FilesBecomeOneSelectableGroupWithoutLosingEvidence() {
        let findings = (0..<309).map { MetadataReport.BrandFinding(brand: "Hikvision", role: "format_family", basis: "signature", file: "/fixture/\($0).mp4", tag: "header.signature", scope: "main", status: "unverified") }
        let warnings = (0..<309).map { MetadataReport.InspectionWarning(file: "/fixture/\($0).mp4", warning: "Private format recognized; unknown proprietary fields may remain") }
        let report = MetadataReport(brand_findings: findings, total_included_files: 309, inspected_file_count: 309, selected_file_count: 309, coverage: "partial", tool: "exiftool", candidates: [], errors: [], warnings: warnings)
        let groups = report.confirmationGroups(for: .device)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 309)
        XCTAssertEqual(groups[0].evidence.count, 309)
        XCTAssertTrue(groups[0].answer.zh.contains("308.mp4"))
        XCTAssertTrue(groups[0].answer.en!.contains("unconfirmed"))
        XCTAssertEqual(report.diagnosticGroups.count, 1)
        XCTAssertEqual(report.diagnosticGroups[0].files.count, 309)
        XCTAssertTrue(report.confirmationGroups(for: .purpose).isEmpty)
    }
    func testDifferentCandidatesKeepTheirFileScopesAndMissingTranslations() {
        let candidates = [MetadataReport.Candidate(field: "capture_device_model", value: "A", file: "/a", tag: "Model", tool: "exiftool", en: "A", raw_value: nil, kind: nil), MetadataReport.Candidate(field: "capture_device_model", value: "B", file: "/b", tag: "Model", tool: "exiftool", en: nil, raw_value: nil, kind: nil)]
        let report = MetadataReport(brand_findings: nil, total_included_files: 2, inspected_file_count: 2, selected_file_count: 2, coverage: "all", tool: "exiftool", candidates: candidates, errors: [], warnings: [])
        let groups = report.confirmationGroups(for: .device)
        XCTAssertEqual(groups.count, 2)
        XCTAssertNotEqual(groups[0].id, groups[1].id)
        XCTAssertEqual(groups[0].files, ["/a"])
        XCTAssertEqual(groups[1].files, ["/b"])
        XCTAssertNil(groups[1].answer.en)
    }
}

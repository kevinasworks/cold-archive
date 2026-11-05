// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class FullMetadataTests: XCTestCase {
    @MainActor
    func testDesktopReceivesEveryFileAndUntruncatedLargeReport() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/exiftool") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/exiftool") else {
            throw XCTSkip("Full metadata integration test requires ExifTool")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ColdArchive-Swift-Metadata-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        for index in 0..<35 {
            let text = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:description=\"\(String(repeating: "x", count: 65000)) END-\(index)\"/></rdf:RDF></x:xmpmeta>"
            try text.write(to: source.appendingPathComponent(String(format: "%02d.xmp", index)), atomically: true, encoding: .utf8)
        }
        let model = ArchiveModel()
        model.sources = [source]; model.destination = output; model.archiveName = "Synthetic"
        model.prepare()
        let deadline = Date().addingTimeInterval(90)
        while model.inspecting && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if model.inspecting { model.cancel() }
        XCTAssertFalse(model.inspecting, "Metadata inspection timed out")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.metadata?.total_included_files, 35)
        XCTAssertEqual(model.metadata?.inspected_file_count, 35)
        XCTAssertGreaterThan(model.metadataJSON.utf8.count, 2_000_000)
        XCTAssertTrue(model.metadataJSON.contains("END-34"))
        XCTAssertTrue(model.showingIntake)
        XCTAssertFalse(model.metadata?.candidates(for: .sourceType).isEmpty ?? true)
        XCTAssertFalse(model.intake.complete)
        model.cancelIntake()
    }
}

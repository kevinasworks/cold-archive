// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class ChineseSpacingTests: XCTestCase {
    @MainActor func testMixedBoundariesAndPreservedWordSpaces() async {
        XCTAssertEqual(BilingualDraft.compactChineseSpacing("CSV 数据文件 3 个，设备 A 1 和 2 B 中文"), "CSV数据文件3个，设备A1和2B中文")
        XCTAssertEqual(BilingualDraft.compactChineseSpacing("中文　ABC\t123 中文\nABC 设备"), "中文ABC123中文\nABC设备")
        XCTAssertEqual(BilingualDraft.compactChineseSpacing("Final Cut Pro\n1 000\n中文段落"), "Final Cut Pro\n1 000\n中文段落")
    }
    @MainActor func testCandidatesEditsAndIncomingTranslationUseSameRule() async throws {
        let draft = BilingualDraft()
        draft.reset(chinese: "CSV 数据文件", english: "CSV data file")
        XCTAssertEqual(draft.chinese, "CSV数据文件")
        XCTAssertEqual(draft.english, "CSV data file")
        draft.edit("设备 A 1", side: .chinese)
        XCTAssertEqual(draft.chinese, "设备A1")
        draft.edit("Device A 1", side: .english)
        let request = try XCTUnwrap(draft.request())
        draft.accept("设备 A 1", for: request)
        XCTAssertEqual(draft.chinese, "设备A1")
        XCTAssertEqual(draft.english, "Device A 1")
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class TranslationTests: XCTestCase {
    @MainActor func testBothDirectionsAndNoFeedbackLoop() throws {
        let d = BilingualDraft()
        d.edit("测试", side: .chinese)
        let first = try XCTUnwrap(d.request())
        d.accept("Test", for: first)
        XCTAssertEqual(d.english, "Test"); XCTAssertNil(d.request()); XCTAssertTrue(d.ready)
        d.reset(chinese: "", english: "")
        d.edit("Long-term backup", side: .english)
        d.accept("长期备份", for: try XCTUnwrap(d.request()))
        XCTAssertEqual(d.chinese, "长期备份")
    }
    @MainActor func testStaleResponseAndFieldSwitchAreIgnored() throws {
        let d = BilingualDraft(); d.edit("旧内容", side: .chinese)
        let old = try XCTUnwrap(d.request())
        d.edit("新内容", side: .chinese); d.accept("Old text", for: old)
        XCTAssertEqual(d.english, "")
        let current = try XCTUnwrap(d.request())
        d.reset(chinese: "", english: ""); d.accept("New text", for: current)
        XCTAssertEqual(d.english, "")
    }
    @MainActor func testLastEditedSideWinsAndRetranslate() throws {
        let d = BilingualDraft(); d.edit("测试", side: .chinese)
        d.accept("Test", for: try XCTUnwrap(d.request()))
        d.edit("Custom translation", side: .english)
        let request = try XCTUnwrap(d.request()); d.accept("自定义翻译", for: request)
        d.retry(); XCTAssertNotNil(d.request())
        XCTAssertEqual(d.chinese, "自定义翻译")
    }
    @MainActor func testFailureAndDisabledModeDoNotLoseInput() throws {
        let d = BilingualDraft(); d.edit("测试", side: .chinese)
        let request = try XCTUnwrap(d.request()); d.fail("Download cancelled", for: request)
        XCTAssertFalse(d.busy); XCTAssertEqual(d.chinese, "测试"); XCTAssertFalse(d.ready)
        d.setEnabled(false); d.edit("Test", side: .english)
        XCTAssertTrue(d.ready); XCTAssertNil(d.request())
    }
    @MainActor func testFailedRetranslationCannotSubmitOldTranslation() throws {
        let d = BilingualDraft()
        d.edit("原文", side: .chinese)
        d.accept("Original", for: try XCTUnwrap(d.request()))
        d.edit("新内容", side: .chinese)
        d.fail("Unavailable", for: try XCTUnwrap(d.request()))
        XCTAssertEqual(d.english, "Original")
        XCTAssertFalse(d.ready)
        d.retry()
        d.accept("New content", for: try XCTUnwrap(d.request()))
        XCTAssertTrue(d.ready)
        d.edit("Again", side: .english)
        d.fail("Unavailable", for: try XCTUnwrap(d.request()))
        d.setEnabled(false)
        XCTAssertTrue(d.ready)
    }
}

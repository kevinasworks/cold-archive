// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SwiftUI
import AppKit
@testable import ColdArchive

final class CreationWindowLayoutTests: XCTestCase {
    @MainActor func testCreationFormRendersWithoutSidebar() throws {
        let queue = ArchiveQueue()
        let view = NSHostingView(rootView: ArchiveCreationForm(queue: queue, submitted: {}).frame(width: 760, height: 650).background(Color.white).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 650)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("QA/208/create.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        XCTAssertEqual(queue.jobs.count, 0)
    }
}

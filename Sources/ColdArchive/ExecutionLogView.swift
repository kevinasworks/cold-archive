// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

/// Native text scrolling keeps long diagnostic output out of SwiftUI's text layout.
struct ExecutionLogView: NSViewRepresentable {
    let text: String
    final class Coordinator { var displayed: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView()
        editor.isEditable = false
        editor.isSelectable = true
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.displayed != text, let editor = scroll.documentView as? NSTextView else { return }
        let offset = scroll.contentView.bounds.origin
        editor.string = text
        context.coordinator.displayed = text
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

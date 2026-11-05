// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

struct ArchiveFailure {
    let title: String
    let reason: String
    let solution: String
    let destinationConflict: Bool
    static func describe(_ text: String) -> ArchiveFailure {
        if text.contains("Refusing to overwrite existing final archive directory:") {
            return .init(title: "归档已存在", reason: "保存位置已有同名归档，为避免覆盖，本次发布已停止。", solution: "请选择其他保存位置，或修改归档名称后重试。", destinationConflict: true)
        }
        let lower = text.lowercased()
        if lower.contains("space") && (lower.contains("insufficient") || lower.contains("no space")) {
            return .init(title: "存储空间不足", reason: "可用空间无法容纳归档及恢复验证的临时文件。", solution: "释放空间或改用其他保存位置后重试。", destinationConflict: false)
        }
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return .init(title: "无法访问文件或保存位置", reason: "系统或存储设备拒绝了读写操作。", solution: "检查文件及目标文件夹的访问权限；网络存储请确认连接和账号权限。", destinationConflict: false)
        }
        if text.contains("File changed while hashing") || text.contains("SOURCE_SHA512 MISMATCH") {
            return .init(title: "源文件一致性检查未通过", reason: "读取期间文件发生变化，或复核结果不一致。", solution: "停止修改或同步这些文件，待文件稳定后重试。", destinationConflict: false)
        }
        if text.count < 400 && !text.contains("\n"), text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            return .init(title: "操作未完成", reason: text, solution: "请按上述提示调整后重试。", destinationConflict: false)
        }
        return .init(title: "操作未完成", reason: "操作未能通过执行或验证检查，目前无法自动确定具体原因。", solution: "请检查文件及保存位置是否可访问；进一步定位可查看任务界面的执行记录。", destinationConflict: false)
    }
}

@MainActor
final class FailureWindow: NSObject, NSWindowDelegate {
    static let shared = FailureWindow()
    private var window: NSWindow?
    func show(_ message: String) {
        window?.close()
        let failure = ArchiveFailure.describe(message)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = failure.title
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            Text(failure.title).font(.title2.bold())
            Text("原因：" + failure.reason)
            Text("处理办法：" + failure.solution)
            HStack { Spacer(); Button("好") { panel.close() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480).fixedSize(horizontal: false, vertical: true))
        panel.center(); panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

@MainActor
final class BilingualDraft: ObservableObject {
    enum Side: String { case chinese, english; var opposite: Side { self == .chinese ? .english : .chinese } }
    struct Request: Equatable {
        let revision: Int; let side: Side; let text: String
    }
    @Published private(set) var chinese = ""
    @Published private(set) var english = ""
    @Published private(set) var revision = 0
    @Published private(set) var status = "输入任一语言，自动填写另一栏。"
    @Published private(set) var busy = false
    @Published private(set) var enabled = true
    @Published private(set) var side: Side = .chinese
    private var translationFailed = false
    var ready: Bool { !busy && (!enabled || !translationFailed) && !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Remove horizontal spacing at mixed Han/Latin/number boundaries only.
    /// Preserve English word spaces, numeric grouping and paragraph breaks.
    static func compactChineseSpacing(_ text: String) -> String {
        let pattern = #"(?<=[\p{Han}])[\p{Zs}\t]+(?=[\p{Latin}\p{N}])|(?<=[\p{Latin}\p{N}])[\p{Zs}\t]+(?=\p{Han})|(?<=\p{Latin})[\p{Zs}\t]+(?=\p{N})|(?<=\p{N})[\p{Zs}\t]+(?=\p{Latin})"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    func reset(chinese: String, english: String) {
        revision += 1; self.chinese = Self.compactChineseSpacing(chinese); self.english = english
        busy = false; translationFailed = false
        status = "输入任一语言，自动填写另一栏。"
    }
    func edit(_ value: String, side: Side) {
        if side == .chinese { chinese = Self.compactChineseSpacing(value) } else { english = value }
        self.side = side; revision += 1; translationFailed = false
        busy = enabled && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        status = busy ? "等待输入完成…" : (enabled ? "请输入需要翻译的内容。" : "手动填写模式")
    }
    func setEnabled(_ value: Bool) {
        enabled = value; revision += 1; busy = value && !(side == .chinese ? chinese : english).isEmpty
        status = value ? "输入任一语言，自动填写另一栏。" : "手动填写模式"
    }
    func retry() { revision += 1; busy = true; status = "等待翻译…" }
    func request() -> Request? {
        guard enabled, busy else { return nil }
        let text = side == .chinese ? chinese : english
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { busy = false; return nil }
        status = "正在准备语言包并翻译…"
        return Request(revision: revision, side: side, text: text)
    }
    func accept(_ text: String, for request: Request) {
        guard enabled, request.revision == revision else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("系统未返回译文。", for: request); return }
        if request.side == .chinese { english = text } else { chinese = Self.compactChineseSpacing(text) }
        busy = false; translationFailed = false; status = "已自动填写译文，可修改后确认。"
    }
    func fail(_ message: String, for request: Request) {
        guard request.revision == revision else { return }
        busy = false; translationFailed = true; status = "翻译未完成：\(message) 可重试，或关闭自动翻译后手动填写。"
    }
}

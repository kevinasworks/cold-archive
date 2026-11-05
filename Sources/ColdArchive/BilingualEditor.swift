// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
import Translation

struct BilingualEditor: View {
    @ObservedObject var draft: BilingualDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("中文内容", text: Binding(get: { draft.chinese }, set: { draft.edit($0, side: .chinese) }), axis: .vertical)
                .lineLimit(2...4).accessibilityLabel("中文内容")
            TextField("English", text: Binding(get: { draft.english }, set: { draft.edit($0, side: .english) }), axis: .vertical)
                .lineLimit(2...4).accessibilityLabel("英文内容")
            if #available(macOS 15, *) {
                HStack {
                    Toggle("自动中英互译", isOn: Binding(get: { draft.enabled }, set: { draft.setEnabled($0) }))
                    if draft.busy { ProgressView().controlSize(.small) }
                    Button("重新翻译另一栏") { draft.retry() }.disabled(!draft.enabled || (draft.chinese.isEmpty && draft.english.isEmpty))
                }
                Text(draft.status).font(.callout).textSelection(.enabled)
                Text("以最后编辑的一栏为原文，自动更新另一栏。文字在本机翻译；首次使用可能需要下载语言包。")
                    .font(.caption).foregroundStyle(.secondary)
                TranslationDriver(draft: draft)
            } else {
                Text("自动翻译需要 macOS 15 或更新版本；当前请手动填写两栏。")
                    .font(.caption).onAppear { draft.setEnabled(false) }
            }
        }
    }
}

@available(macOS 15, *)
private struct TranslationDriver: View {
    @ObservedObject var draft: BilingualDraft
    @State private var configuration: TranslationSession.Configuration?
    @State private var pending: BilingualDraft.Request?
    var body: some View {
        Color.clear.frame(height: 1)
            .task(id: draft.revision) {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    // Don't translate uncommitted input-method composition.
                    while (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try Task.checkCancellation()
                    guard let request = draft.request() else { return }
                    pending = request
                    let source = Locale.Language(identifier: request.side == .chinese ? "zh-Hans" : "en")
                    let target = Locale.Language(identifier: request.side == .chinese ? "en" : "zh-Hans")
                    if configuration?.source == source && configuration?.target == target {
                        configuration?.invalidate()
                    } else { configuration = .init(source: source, target: target) }
                } catch { /* Superseded edits never change current state. */ }
            }
            .translationTask(configuration) { session in
                guard let request = pending else { return }
                let expected = request.side == .chinese ? "zh" : "en"
                guard session.sourceLanguage?.languageCode?.identifier == expected else { return }
                do {
                    let response = try await session.translate(request.text)
                    draft.accept(response.targetText, for: request)
                } catch {
                    draft.fail(error.localizedDescription, for: request)
                }
            }
    }
}

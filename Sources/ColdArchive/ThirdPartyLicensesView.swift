// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct ThirdPartyLicenseCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("第三方组件与许可证（Third-Party Licenses）") {
                openWindow(id: "third-party-licenses")
            }
        }
    }
}

struct ThirdPartyLicensesView: View {
    @State private var selected: URL?
    private let resources = Bundle.main.resourceURL

    private var documents: [URL] {
        guard let resources else { return [] }
        let summary = resources.appendingPathComponent("THIRD_PARTY_NOTICES.md")
        let runtime = resources.appendingPathComponent("Runtime")
        let projectDocuments = [summary, resources.appendingPathComponent("LICENSE"), resources.appendingPathComponent("OPEN_SOURCE.md")]
        guard let enumerator = FileManager.default.enumerator(
            at: runtime, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return projectDocuments }
        let licenses = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("license") || name.hasPrefix("licence")
                || name.hasPrefix("notice") || name.hasPrefix("authors")
                || name.hasPrefix("copying") || url.pathComponents.contains("Licenses")
            else { return nil }
            return url
        }
        return projectDocuments + licenses.sorted { $0.path < $1.path }
    }

    var body: some View {
        let files = documents
        NavigationSplitView {
            List(files, id: \.self, selection: $selected) { url in
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent)
                    if let resources {
                        Text(String(url.path.dropFirst(resources.path.count + 1)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(url)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 300)
        } detail: {
            let url = selected ?? files.first
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Cold Archive 原创代码：Copyright © 2026 Kevin Zheng · GPL-3.0-only。允许依 GPLv3 再分发，不提供担保。适用范围与待核权属见 OPEN_SOURCE.md。第三方组件各自许可证独立适用。")
                    Text(contents(of: url))
                }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding()
            }
        }
        .frame(minWidth: 740, minHeight: 480)
    }

    private func contents(of url: URL?) -> String {
        guard let url else { return "未找到随包许可材料。" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "无法读取许可材料。\n\(url.lastPathComponent)\n\(error.localizedDescription)"
        }
    }
}

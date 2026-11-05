// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct ReadingFilesView: View {
    let progress: ReadingProgress
    @State private var filter = 0
    @State private var search = ""
    private func matches(_ file: ReadingFile, category: Int? = nil) -> Bool {
        switch category ?? filter {
        case 1: return file.state == .completed
        case 2: return file.state == .failed || file.state == .cancelled
        default: return file.state == .pending || file.state == .reading
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ForEach(0..<3) { index in
                    Button { filter = index } label: {
                        VStack(spacing: 8) {
                            Text("\(["读取中与等待", "已读完", "未完成"][index])(\(progress.files.filter { matches($0, category: index) }.count))").font(.headline).monospacedDigit()
                            Capsule().fill(filter == index ? Color.accentColor : .clear).frame(height: 3)
                        }.fixedSize(horizontal: true, vertical: false).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(filter == index ? Color.accentColor : .secondary)
                }
                Spacer()
                Text("已读完\(progress.completed)/\(progress.files.count)个").font(.caption).foregroundStyle(.secondary)
            }
            Text("正在读取\(progress.active)个 · 等待\(progress.files.filter { $0.state == .pending }.count)个").font(.caption).foregroundStyle(.secondary)
            TextField("搜索文件名或路径", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Text("文件名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("读取状态").frame(width: 140, alignment: .leading)
            }.font(.caption).foregroundStyle(.secondary)
            Divider()
            let files = progress.files.filter { matches($0) && (search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)) }
            if files.isEmpty { Text("此分类暂无匹配文件").foregroundStyle(.secondary).padding(.vertical, 30) }
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.fill").font(.title2).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(URL(fileURLWithPath: file.path).lastPathComponent).lineLimit(1)
                            Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity, alignment: .leading).help(file.path)
                        HStack(spacing: 8) {
                            if file.state == .reading { ProgressView().controlSize(.small) }
                            if file.state == .completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            Text(file.state == .pending && progress.paused ? "等待继续" : file.state.rawValue).font(.callout)
                        }.frame(width: 140, alignment: .leading)
                    }.padding(.vertical, 15)
                    Divider()
                }
            }
        }
    }
}

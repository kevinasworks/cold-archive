// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ReadingFile: Identifiable, Equatable, Sendable {
    enum State: String, CaseIterable, Sendable { case pending = "未开始", reading = "正在读取", completed = "已读完", failed = "失败", cancelled = "已取消" }
    let id: Int
    let path: String
    var state: State = .pending
}
struct ReadingProgress: Equatable, Sendable {
    var files: [ReadingFile] = []
    var paused = false
    var completed: Int { files.filter { $0.state == .completed }.count }
    var active: Int { files.filter { $0.state == .reading }.count }
}

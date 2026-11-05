// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A task has its own identity and input snapshot, independent of the creation form.
struct ArchiveTask: Identifiable {
    enum State: String { case queued = "排队中", reading = "读取来源", confirming = "等待确认", ready = "等待归档", archiving = "正在归档", completed = "已完成", cancelled = "已取消", failed = "未完成" }
    var id: UUID
    let name: String
    let createdAt: Date
    var destination: URL?
    private(set) var stageIndex = 0
    var state: State = .reading {
        didSet {
            switch state {
            case .queued, .reading: stageIndex = 0
            case .confirming, .ready: stageIndex = 1
            case .archiving: stageIndex = 2
            case .completed: stageIndex = 3
            case .cancelled, .failed: break
            }
        }
    }
    var completedArchivePhases: Int { state == .completed ? 15 : max(0, min(14, phase - 1)) }
    var confirmationSteps: Double = 0
    /// 1 reading step, 5 confirmation steps, 15 validated archive phases.
    var overallProgress: Double {
        if state == .completed { return 1 }
        let reading = stageIndex >= 1 ? 1.0 : Double(readingProgress.completed) / Double(max(1, readingProgress.files.count))
        let confirmation = stageIndex >= 2 || state == .ready ? 5.0 : min(5, max(0, confirmationSteps))
        return min(20.0 / 21.0, (reading + confirmation + Double(completedArchivePhases)) / 21.0)
    }
    var status = "正在检测来源元数据…"
    var detail = ""
    var readingProgress = ReadingProgress()
    var readingPauseRequested = false
    var phase = 0
    var log = ""
    var bundle: URL?
    var failure: String?
    var running = false
    var cancelling = false
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

@MainActor final class WriteBudgetStatus:ObservableObject {
    static let shared=WriteBudgetStatus()
    @Published private(set) var message=""
    nonisolated static func publish(_ message:String) {
        Task { @MainActor in if shared.message != message {shared.message=message} }
    }
}

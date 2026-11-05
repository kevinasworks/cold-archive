// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Evidence materialization and permit waits never run on the UI/cooperative
/// executor. The engine still receives the same full bilingual evidence files.
enum ArchivePreparation {
    static func write(workspace:URL,answers:Data,report:URL?,zh:String,en:String) async throws {
        try await perform {
            guard mkdir(workspace.path,0o700)==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            try WriteBudget.native(kind:.temporary,destination:workspace.appendingPathComponent("answers.json")) {
                try answers.write(to:workspace.appendingPathComponent("answers.json"),options:.atomic)
            }
            let evidence:String
            if let report {
                let permit=try WriteBudget.reading(wait:true,domain:IOBudgetCoordinator.storageKey(path:report.path))
                defer {withExtendedLifetime(permit) {}}
                evidence=try String(contentsOf:report,encoding:.utf8)
            } else {evidence=""}
            guard report==nil || !evidence.isEmpty else {throw AppError.message("元数据证据文件无法读取，归档已停止。")}
            let details:[String:Any]=["metadata_evidence":["state":"provided","zh":zh+evidence,"en":en+evidence]]
            try WriteBudget.native(kind:.temporary,destination:workspace.appendingPathComponent("details.json")) {
                try JSONSerialization.data(withJSONObject:details,options:[.prettyPrinted,.sortedKeys]).write(to:workspace.appendingPathComponent("details.json"),options:.atomic)
            }
        }
    }
    static func remove(_ workspace:URL) async throws {
        try await perform {
            if FileManager.default.fileExists(atPath:workspace.path) {try FileManager.default.removeItem(at:workspace)}
        }
    }
    private static func perform(_ body:@escaping () throws->Void) async throws {
        try await withCheckedThrowingContinuation {(continuation:CheckedContinuation<Void,Error>) in
            DispatchQueue.global(qos:.utility).async {
                do {try body();continuation.resume()}
                catch {continuation.resume(throwing:error)}
            }
        }
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CryptoKit

private final class NativeWriteObservation {
    static let shared=NativeWriteObservation()
    private let lock=NSLock()
    private struct Total {var bytes:UInt64=0,calls:UInt64=0;var seconds=0.0;var valid=true}
    private var totals:[String:Total]=[:]
    private var reportedFailures=Set<String>()
    private let identity="native-"+UUID().uuidString
    func record(_ count:Int,seconds:Double,domain:String) throws {
        lock.lock();defer{lock.unlock()}
        var total=totals[domain] ?? Total()
        total.bytes += UInt64(count);total.calls += 1;total.seconds += seconds
        totals[domain]=total
        let suffix=SHA256.hash(data:Data(domain.utf8)).map{String(format:"%02x",$0)}.joined()
        let folder=try WriteBudget.directory.get().appendingPathComponent("observations")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONSerialization.data(withJSONObject:["bytes":total.bytes,"calls":total.calls,"seconds":total.seconds,
                "domain":domain,"stage":"export","pid":getpid(),"valid":total.valid]).write(to:folder.appendingPathComponent(identity+"-"+suffix),options:.atomic)
        } catch {
            total.valid=false;totals[domain]=total
            if reportedFailures.insert(domain).inserted {
                DiagnosticLog.shared.write(["event":"measurement_error","stage":"export","code":"write_observation_failed",
                    "target_ref":DiagnosticLog.shared.target(domain)])
            }
        }
    }
}
extension WriteBudget {
    /// Count completed writes directly. Export waiting/copying runs off MainActor.
    static func copyTarget(from source:URL,to destination:URL) throws {
        let read=try reading(wait:true,domain:IOBudgetCoordinator.storageKey(path:source.path))
        defer {withExtendedLifetime(read) {}}
        try native(destination:destination,stage:"export") {
            let descriptor=open(destination.path,O_WRONLY|O_CLOEXEC|O_CREAT|O_EXCL,0o600)
            guard descriptor>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            let output=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
            defer {try? output.close()}
            let input=try FileHandle(forReadingFrom:source)
            defer {try? input.close()}
            while let data=try input.read(upToCount:1024*1024),!data.isEmpty {
                let started=ProcessInfo.processInfo.systemUptime
                try output.write(contentsOf:data)
                // Diagnostics cannot turn a successful data write into failure.
                try? NativeWriteObservation.shared.record(data.count,seconds:ProcessInfo.processInfo.systemUptime-started,domain:IOBudgetCoordinator.storageKey(path:destination.path))
            }
            try output.synchronize()
        }
    }
}

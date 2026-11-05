// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Native/Python share this on-disk protocol. Admission is serialized, work is
/// not. Counting all occupied slots preserves draining after a target reduction.
enum PermitPool {
    final class Lease {
        private var descriptor:Int32
        var onRelease:(()->Void)?
        init(_ descriptor:Int32) {self.descriptor=descriptor}
        deinit {if descriptor>=0 {close(descriptor)};onRelease?()}
    }
    struct Snapshot {
        var valid=false
        var active=0
        var waiting=0
        var pids=Set<Int32>()
        var domains=Set<String>()
        var stages=Set<String>()
        var activeByDomain:[String:Int]=[:]
        var waitingByDomain:[String:Int]=[:]
        var pidsByDomain:[String:Set<Int32>]=[:]
        var stagesByDomain:[String:Set<String>]=[:]
        var pidsByStage:[String:[String:Set<Int32>]]=[:]
    }
    static func acquire(_ root:URL, wait:Bool=true, domain:String="unknown",stage:String="target_write") throws -> Lease? {
        let waiting=root.appendingPathComponent("waiters")
        try FileManager.default.createDirectory(at:waiting,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let marker=waiting.appendingPathComponent(UUID().uuidString)
        let waiter=open(marker.path,O_RDWR|O_CLOEXEC|O_CREAT|O_EXCL,0o600)
        guard waiter>=0 else {throw POSIXError(.EIO)}
        guard flock(waiter,LOCK_EX)==0 else {close(waiter);throw POSIXError(.EIO)}
        let queued=ProcessInfo.processInfo.systemUptime
        let markerData=try JSONSerialization.data(withJSONObject:["pid":getpid(),"domain":domain,"stage":stage,"queued_at":queued])
        _=markerData.withUnsafeBytes {write(waiter,$0.baseAddress,markerData.count)}
        defer {close(waiter);try? FileManager.default.removeItem(at:marker)}
        var failures=0
        repeat {
            if let lease=try attempt(root,domain:domain,stage:stage,ticket:.init(id:marker.lastPathComponent,domain:domain,queued:queued)) {
                let waited=ProcessInfo.processInfo.systemUptime-queued
                if waited>0.05 {DiagnosticLog.shared.write(["event":"permit_wait","stage":stage,"metric_source":"admission_wait","seconds":waited,"target_ref":DiagnosticLog.shared.target(domain)])}
                return lease
            }
            failures += 1
            if wait {usleep(useconds_t(min(50_000,5_000*(1+failures))))}
        } while wait
        return nil
    }
    private static func attempt(_ root:URL,domain:String,stage:String,ticket:AdmissionOrder.Waiter) throws -> Lease? {
        let gate=open(root.appendingPathComponent("admission").path,O_RDWR|O_CLOEXEC|O_CREAT,0o600)
        guard gate>=0 else {throw POSIXError(.EIO)}
        defer {close(gate)}
        guard flock(gate,LOCK_EX)==0 else {throw POSIXError(.EIO)}
        let policy=try WriteAdmissionPolicy.load(root)
        let limit=max(0,min(64,policy.limit))
        var free:[Int32]=[]
        defer {for fd in free {close(fd)}}
        var occupied=0,domainOccupied=0
        var owners:[String:Int]=[:]
        for i in 0..<64 {
            let fd=open(root.appendingPathComponent(String(i)).path,O_RDWR|O_CLOEXEC)
            if fd<0 && errno == ENOENT {continue}
            guard fd>=0 else {throw POSIXError(.EIO)}
            if flock(fd,LOCK_EX|LOCK_NB)==0 {if free.isEmpty {free.append(fd)} else {close(fd)}}
            else {
                let reason=errno;close(fd)
                guard reason==EWOULDBLOCK || reason==EAGAIN else {throw POSIXError(.EIO)}
                occupied += 1
                let url=root.appendingPathComponent(String(i))
                if let data=try? Data(contentsOf:url),let row=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let owner=row["domain"] as? String {
                    let canonical=policy.canonical(owner)
                    owners[canonical,default:0] += 1
                    if canonical==policy.canonical(domain) {domainOccupied += 1}
                } else {domainOccupied += 1}
            }
        }
        guard occupied<limit,domainOccupied<policy.domainLimit(domain),!free.isEmpty else {return nil}
        var waiting:[AdmissionOrder.Waiter]=[]
        for marker in (try? FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("waiters"),includingPropertiesForKeys:nil)) ?? [] {
            let fd=open(marker.path,O_RDWR|O_CLOEXEC)
            guard fd>=0 else {continue}
            if flock(fd,LOCK_EX|LOCK_NB) != 0,errno==EWOULDBLOCK || errno==EAGAIN,
               let data=try? Data(contentsOf:marker),let row=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
               let owner=row["domain"] as? String,let queued=row["queued_at"] as? Double,queued.isFinite {
                waiting.append(.init(id:marker.lastPathComponent,domain:owner,queued:queued))
            }
            close(fd)
        }
        guard AdmissionOrder.mayEnter(domain:domain,ticket:ticket,waiting:waiting,active:owners,policy:policy) else {return nil}
        let held=free.removeFirst()
        // Metadata is content-free and private to this app's temporary pool.
        let data=try JSONSerialization.data(withJSONObject:["pid":getpid(),"domain":domain,"stage":stage])
        guard ftruncate(held,0)==0 else {close(held);throw POSIXError(.EIO)}
        let written=data.withUnsafeBytes {write(held,$0.baseAddress,data.count)}
        guard written==data.count else {close(held);throw POSIXError(.EIO)}
        return Lease(held)
    }
    static func snapshot(_ root:URL)->Snapshot {
        var result=Snapshot()
        let gate=open(root.appendingPathComponent("admission").path,O_RDWR|O_CLOEXEC|O_CREAT,0o600)
        guard gate>=0 else {return result}
        defer {close(gate)}
        guard flock(gate,LOCK_EX)==0 else {return result}
        guard let policy=try? WriteAdmissionPolicy.load(root) else {return result}
        result.valid=true
        // Do not mistake free slots briefly locked by admission scanning for
        // actual writers. Take one coherent snapshot under that same gate.
        for i in 0..<64 {
            let url=root.appendingPathComponent(String(i))
            let fd=open(url.path,O_RDWR|O_CLOEXEC)
            guard fd>=0 else {if errno != ENOENT {result.valid=false};continue}
            if flock(fd,LOCK_EX|LOCK_NB) != 0 {
                if errno==EWOULDBLOCK || errno==EAGAIN {
                    result.active += 1
                    if let data=try? Data(contentsOf:url),let row=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                        let domain=policy.canonical(row["domain"] as? String ?? "unknown")
                        result.domains.insert(domain);result.activeByDomain[domain,default:0] += 1
                        if let pid=(row["pid"] as? NSNumber)?.int32Value {result.pids.insert(pid);result.pidsByDomain[domain,default:[]].insert(pid)}
                        if let stage=row["stage"] as? String {
                            result.stages.insert(stage);result.stagesByDomain[domain,default:[]].insert(stage)
                            if let pid=(row["pid"] as? NSNumber)?.int32Value {result.pidsByStage[domain,default:[:]][stage,default:[]].insert(pid)}
                        }
                    } else {result.valid=false}
                }
            }
            close(fd)
        }
        if let markers=try? FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("waiters"),includingPropertiesForKeys:nil) {
            for marker in markers {
                let fd=open(marker.path,O_RDWR|O_CLOEXEC)
                guard fd>=0 else {if errno != ENOENT {result.valid=false};continue}
                if flock(fd,LOCK_EX|LOCK_NB) != 0 {
                    if errno==EWOULDBLOCK || errno==EAGAIN {
                        result.waiting += 1
                        let data=try? Data(contentsOf:marker)
                        let row=data.flatMap{try? JSONSerialization.jsonObject(with:$0)} as? [String:Any]
                        let domain=policy.canonical(row?["domain"] as? String ?? "unknown")
                        result.waitingByDomain[domain,default:0] += 1
                        if let stage=row?["stage"] as? String {result.stagesByDomain[domain,default:[]].insert(stage)}
                    }
                } else if let attributes=try? FileManager.default.attributesOfItem(atPath:marker.path),let modified=attributes[.modificationDate] as? Date,Date().timeIntervalSince(modified)>30 {try? FileManager.default.removeItem(at:marker)}
                close(fd)
            }
        }
        return result
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Target and local temporary writes use independent cross-process permits.
/// Policy changes affect admission. Existing permit holders finish normally.
enum WriteBudget {
    // Implementation safety bound, not a claim about optimal concurrency.
    static let maximumReaders = 64
    static let maximumWriters = 64
    private static let nativeLock = NSRecursiveLock()
    private static let logLock=NSRecursiveLock()
    enum Kind { case target, temporary, log }
    static var localTemporaryDevice:UInt64? {
        let url=FileManager.default.temporaryDirectory
        guard (try? url.resourceValues(forKeys:[.volumeIsLocalKey]).volumeIsLocal)==true,
              let attributes=try? FileManager.default.attributesOfItem(atPath:url.path),
              let device=attributes[.systemNumber] as? NSNumber else {return nil}
        return device.uint64Value
    }
    static let directory: Result<URL, Error> = Result {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("cold-archive-writes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for i in 0..<64 {
            guard FileManager.default.createFile(atPath:url.appendingPathComponent(String(i)).path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw CocoaError(.fileWriteUnknown)}
        }
        let reads=url.appendingPathComponent("reading")
        try FileManager.default.createDirectory(at:reads,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for i in 0..<64 {FileManager.default.createFile(atPath:reads.appendingPathComponent(String(i)).path,contents:nil,attributes:[.posixPermissions:0o600])}
        try Data("64".utf8).write(to:reads.appendingPathComponent("limit"),options:.atomic)
        let temp=url.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for i in 0..<5 {FileManager.default.createFile(atPath:temp.appendingPathComponent(String(i)).path,contents:nil,attributes:[.posixPermissions:0o600])}
        let tempLimit=max(1,min(5,Int(ProcessInfo.processInfo.physicalMemory/(768*1024*1024))))
        try Data(String(tempLimit).utf8).write(to:temp.appendingPathComponent("limit"),options:.atomic)
        try Data("1".utf8).write(to:url.appendingPathComponent("limit"),options:.atomic)
        return url
    }
    static var configuredLimit:Int {
        nativeLock.lock();defer {nativeLock.unlock()}
        return (try? WriteAdmissionPolicy.load(directory.get()).limit) ?? 1
    }
    private static var settings:ConcurrencySettings?
    private static var generation=0
    static var currentSettings: ConcurrencySettings? {
        nativeLock.lock(); defer {nativeLock.unlock()}
        return settings
    }
    static func configure(_ value:ConcurrencySettings) throws {
        nativeLock.lock();defer {nativeLock.unlock()}
        guard settings != value else {return}
        let root=try directory.get()
        let readFile=root.appendingPathComponent("reading/limit")
        let previousRead=try Data(contentsOf:readFile)
        try Data(String(min(value.readLimit,IOBudgetCoordinator.shared.ceiling)).utf8).write(to:readFile,options:.atomic)
        let writeChanged=settings?.writeMode != value.writeMode || settings?.writers != value.writers
        guard writeChanged else {
            settings=value
            return
        }
        let initialLimit=min(value.writeLimit,IOBudgetCoordinator.shared.ceiling(for:.write))
        let policy=WriteAdmissionPolicy(limit:initialLimit,default_limit:value.writeMode == "smart" ? 1:value.writeLimit,
            domain_limits:[:],aliases:IOBudgetCoordinator.shared.currentAliases())
        do {
            try store(policy,root:root)
        } catch {
            try previousRead.write(to:readFile,options:.atomic)
            throw error
        }
        settings=value
        generation += 1
        SmartWriteScheduler.shared.configure(value,root:root,generation:generation)
    }
    private static func store(_ policy:WriteAdmissionPolicy,root:URL) throws {
        try JSONEncoder().encode(policy).write(to:root.appendingPathComponent("policy.json"),options:.atomic)
    }
    @discardableResult static func updatePolicy(_ policy:WriteAdmissionPolicy,generation expected:Int) throws -> Bool {
        nativeLock.lock();defer{nativeLock.unlock()}
        guard expected==generation else {return false}
        let root=try directory.get()
        if let current=try? WriteAdmissionPolicy.load(root),
           current.limit==policy.limit,current.default_limit==policy.default_limit,
           current.domain_limits==policy.domain_limits,current.aliases==policy.aliases {return true}
        try store(policy,root:root)
        return true
    }
    @discardableResult static func refreshReadCeiling() throws -> Int {
        nativeLock.lock();defer{nativeLock.unlock()}
        let limit=min(settings?.readLimit ?? 64,IOBudgetCoordinator.shared.ceiling)
        let file=try directory.get().appendingPathComponent("reading/limit")
        if (try? String(contentsOf:file)) != String(limit) {try Data(String(limit).utf8).write(to:file,options:.atomic)}
        return limit
    }
    static func reading(wait:Bool=false,domain:String="unknown",expectedSettings:ConcurrencySettings?=nil) throws -> PermitPool.Lease? {
        if expectedSettings != nil {nativeLock.lock()}
        defer {if expectedSettings != nil {nativeLock.unlock()}}
        if let expectedSettings, settings != expectedSettings {return nil}
        let permit=try PermitPool.acquire(directory.get().appendingPathComponent("reading"),wait:wait,domain:domain,stage:"read")
        if let permit {
            IOBudgetCoordinator.shared.changeNativePermits(.read,by:1)
            permit.onRelease={IOBudgetCoordinator.shared.changeNativePermits(.read,by:-1)}
        }
        return permit
    }
    static func verifiedLocalTemporary(_ destination:URL?)->Bool {
        guard let device=localTemporaryDevice else {return false}
        var path=(destination ?? FileManager.default.temporaryDirectory).resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath:path.path),path.path != "/" {path.deleteLastPathComponent()}
        path=path.resolvingSymlinksInPath()
        guard let attributes=try? FileManager.default.attributesOfItem(atPath:path.path),let actual=attributes[.systemNumber] as? NSNumber else {return false}
        return device==actual.uint64Value
    }
    static func native<T>(kind:Kind = .target,destination:URL?=nil,stage:String="native_write",_ body:() throws -> T) throws -> T {
        if kind == .log {logLock.lock();defer {logLock.unlock()};return try body()}
        let temporary=kind == .temporary && verifiedLocalTemporary(destination)
        // These bodies are synchronous; nesting belongs to this thread, not
        // the whole process. Holding a global lock here serialized all writers
        // and prevented configuration changes while a writer was blocked.
        let nestingKey=temporary ? "ColdArchive.temporaryPermit":"ColdArchive.targetPermit"
        if Thread.current.threadDictionary[nestingKey] != nil {return try body()}
        let base=try directory.get()
        let root=temporary ? base.appendingPathComponent("temporary"):base
        let lease=try PermitPool.acquire(root,domain:destination.map{IOBudgetCoordinator.storageKey(path:$0.path)} ?? "unknown",stage:stage)
        if !temporary {
            IOBudgetCoordinator.shared.changeNativePermits(.write,by:1)
            lease?.onRelease={IOBudgetCoordinator.shared.changeNativePermits(.write,by:-1)}
        }
        Thread.current.threadDictionary[nestingKey]=true
        defer {Thread.current.threadDictionary.removeObject(forKey:nestingKey);withExtendedLifetime(lease) {}}
        return try body()
    }
}

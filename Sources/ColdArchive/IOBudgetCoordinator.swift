// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import DiskArbitration
import NativeMonitor

/// Whole-app admission and storage-domain probe ownership. No paths enter logs.
final class IOBudgetCoordinator: @unchecked Sendable {
    static let shared=IOBudgetCoordinator()
    private let lock=NSLock()
    private var probes:[String:(owner:String,until:Double)]=[:]
    enum Lane {case read,write,auxiliary}
    private struct Footprint {let bytes:UInt64;let active:Int;let lane:Lane;let pid:Int32?}
    private var footprints:[String:Footprint]=[:]
    private let memoryBudget:UInt64
    private let descriptorOverride:Int?
    private let includeAppFootprint:Bool
    private let baselineDescriptors:Int
    private var nativeReaders=0,nativeWriters=0
    init(memoryBudget:UInt64?=nil,descriptorCeiling:Int?=nil) {
        self.memoryBudget=memoryBudget ?? ProcessInfo.processInfo.physicalMemory/3
        self.descriptorOverride=descriptorCeiling
        self.includeAppFootprint=memoryBudget == nil
        self.baselineDescriptors=max(0,Int(ca_process_fd_count(getpid())))
    }
    func changeNativePermits(_ lane:Lane,by delta:Int) {
        lock.lock();defer{lock.unlock()}
        if lane == .read {nativeReaders=max(0,nativeReaders+delta)}
        if lane == .write {nativeWriters=max(0,nativeWriters+delta)}
    }
    func updateFootprint(owner:String,bytes:UInt64?,active:Int=1,lane:Lane = .read,pid:Int32?=nil) {
        lock.lock();defer{lock.unlock()}
        guard let bytes,active>0 else {footprints.removeValue(forKey:owner);return}
        if let pid {
            // The archive's process observer covers its whole process tree.
            // A write-permit observation of the same PID must not double count.
            if lane == .write,footprints.contains(where:{$0.key != owner && $0.value.pid==pid && $0.value.lane == .auxiliary}) {footprints.removeValue(forKey:owner);return}
            if lane == .auxiliary {footprints=footprints.filter{!($0.value.pid==pid && $0.value.lane == .write)}}
        }
        footprints[owner]=Footprint(bytes:bytes,active:active,lane:lane,pid:pid)
    }
    var ceiling:Int {ceiling(for:.read)}
    struct Evidence {
        let ceiling:Int,memoryCeiling:Int,descriptorCeiling:Int
        let memoryBudget:UInt64
        let estimatedMemory:Double
        let reason:String
        let openDescriptors:Int,descriptorLimit:Int,estimatedDescriptorsPerTask:Int
        var fields:[String:Any] {["resource_reason":reason,"memory_ceiling":memoryCeiling,"descriptor_ceiling":descriptorCeiling,"memory_budget_bytes":memoryBudget,"estimated_memory_bytes":estimatedMemory,"file_descriptors_open":openDescriptors,"file_descriptor_limit":descriptorLimit,"estimated_fds_per_task":estimatedDescriptorsPerTask]}
    }
    func ceiling(for lane:Lane)->Int {evidence(for:lane).ceiling}
    func evidence(for lane:Lane)->Evidence {
        lock.lock();defer{lock.unlock()}
        var fdLimit=rlimit()
        let known=getrlimit(RLIMIT_NOFILE,&fdLimit)==0
        let soft=known ? Int(min(fdLimit.rlim_cur,1048576)):0
        let openCount=Int(ca_process_fd_count(getpid()))
        let native=lane == .read ? nativeReaders:nativeWriters
        // Reserve 32 descriptors for UI/network/launch transients. Estimate
        // incremental cost from live native readers, rather than a fixed /16.
        let observed=native>0 && openCount>=baselineDescriptors ? Int(ceil(Double(openCount-baselineDescriptors)/Double(native))):4
        let perTask=lane == .read ? max(2,min(8,observed)):4
        let descriptors=descriptorOverride ?? (known && openCount>=0 ? max(1,native+max(0,soft-openCount-32)/perTask):64)
        let records=footprints.values
        var app=CAProcessUsage()
        let appBytes=includeAppFootprint && ca_process_usage(getpid(),&app)==0 ? Double(app.footprint):0
        let total=records.reduce(appBytes){$0+Double($1.bytes)*Double($1.active)}
        let laneRecords=records.filter{$0.lane==lane}
        let active=laneRecords.reduce(0){$0+$1.active}
        let peak=laneRecords.map(\.bytes).max() ?? records.map(\.bytes).max() ?? 0
        let memory=peak>0 ? active+Int(floor((Double(memoryBudget)-total)/Double(peak))):64
        let reason=memory<64 && memory<=descriptors ? "memory_budget":descriptors<64 ? "file_descriptor_budget":"engineering_ceiling"
        return Evidence(ceiling:max(1,min(64,descriptors,memory)),memoryCeiling:max(1,memory),descriptorCeiling:descriptors,
            memoryBudget:memoryBudget,estimatedMemory:total,reason:reason,openDescriptors:openCount,descriptorLimit:soft,estimatedDescriptorsPerTask:perTask)
    }
    private var aliases:[String:(canonical:String,configuration:NASConfiguration)]=[:]
    func registerNAS(domain:String,configuration:NASConfiguration) {
        lock.lock();defer{lock.unlock()}
        aliases[domain]=("nas:"+configuration.host.lowercased()+":"+String(configuration.port),configuration)
    }
    func currentAliases()->[String:String] {
        let current=NASConfiguration.load()
        lock.lock();defer{lock.unlock()}
        return aliases.filter{$0.value.configuration==current}.mapValues(\.canonical)
    }
    func canonicalDomain(_ domain:String,current:NASConfiguration?=nil)->String {
        let current=current ?? NASConfiguration.load()
        lock.lock();defer{lock.unlock()}
        guard let alias=aliases[domain],alias.configuration==current else {return domain}
        return alias.canonical
    }
    @discardableResult func claimProbes(domains:[String],owner:String,seconds:Double,now:Double=ProcessInfo.processInfo.systemUptime)->Bool {
        lock.lock();defer{lock.unlock()}
        guard domains.allSatisfy({domain in probes[domain].map{$0.owner==owner || $0.until<=now} ?? true}) else {return false}
        for domain in domains {probes[domain]=(owner,now+seconds)}
        return true
    }
    func canProbe(domain:String,owner:String,now:Double=ProcessInfo.processInfo.systemUptime)->Bool {
        lock.lock();defer{lock.unlock()}
        guard let probe=probes[domain] else {return true}
        return probe.owner==owner || probe.until<=now
    }
    @discardableResult func claimProbe(domain:String,owner:String,seconds:Double,now:Double=ProcessInfo.processInfo.systemUptime)->Bool {
        lock.lock();defer{lock.unlock()}
        if let probe=probes[domain],probe.owner != owner,probe.until>now {return false}
        probes[domain]=(owner,now+seconds);return true
    }
    func release(owner:String) {
        lock.lock();defer{lock.unlock()}
        probes=probes.filter{$0.value.owner != owner};footprints.removeValue(forKey:owner)
    }
    static func storageKey(path:String,mounts:[MountedSource]?=nil)->String {
        let mounts=mounts ?? mountedSources()
        guard let volume=mounts.first(where:{path == $0.path || path.hasPrefix($0.path == "/" ? "/":$0.path+"/")}) else {return "unknown"}
        if !volume.local {
            // Shares on one SMB server contend for the same device resources.
            return shared.canonicalDomain("remote:"+(volume.identity?.split(separator:"/",maxSplits:1).first.map(String.init) ?? volume.path))
        }
        if let session=DASessionCreate(kCFAllocatorDefault),
           let disk=DADiskCreateFromVolumePath(kCFAllocatorDefault,session,URL(fileURLWithPath:volume.path) as CFURL),
           let whole=DADiskCopyWholeDisk(disk),let name=DADiskGetBSDName(whole) {return "disk:"+String(cString:name)}
        return "local:"+volume.path
    }
}

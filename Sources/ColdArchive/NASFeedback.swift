// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Only identity-confirmed storage domains receive this telemetry. Missing or
/// expired values remain unknown and never become a zero-load observation.
final class NASFeedback: @unchecked Sendable {
    static let shared=NASFeedback()
    private let lock=NSLock()
    private var samples:[String:(sample:NASSample,configuration:NASConfiguration)]=[:]
    func store(_ sample:NASSample,domain:String,configuration:NASConfiguration) {lock.lock();samples[domain]=(sample,configuration);lock.unlock()}
    func sample(domain:String)->NASSample? {
        let current=NASConfiguration.load()
        lock.lock();defer{lock.unlock()}
        guard let row=samples[domain],row.configuration==current else {return nil}
        return row.sample
    }
}

struct NASPressureEvidence {
    enum Direction {case read,write}
    private var direction:Direction?
    private var baseline:Double?
    private var timestamp:Double?
    private var pressuredSamples=0
    struct Result {
        var fresh=false,headroom=false,congested=false
        var age:Double?
        var latency:Double?
    }
    mutating func observe(_ sample:NASSample?,direction:Direction = .read,now:Double=ProcessInfo.processInfo.systemUptime)->Result {
        if self.direction != direction {self.direction=direction;baseline=nil;timestamp=nil;pressuredSamples=0}
        guard let sample,sample.valid,now>=sample.timestamp,now-sample.timestamp<30 else {
            pressuredSamples=0;timestamp=nil;baseline=nil
            return Result()
        }
        let measuredLatency=direction == .read ? sample.readLatency:sample.writeLatency
        var result=Result(fresh:true,age:now-sample.timestamp,latency:measuredLatency)
        if let cpu=sample.cpu,let disk=sample.diskLoad {result.headroom=cpu<75 && disk<85}
        var pressure=(sample.cpu.map{$0>90} ?? false)
        if let latency=measuredLatency,latency>0 {
            if let base=baseline {
                pressure = pressure || ((sample.diskLoad.map{$0>95} ?? false) && latency>max(5000,base*2))
                // Update baseline slowly only when the device is not congested.
                if !pressure {baseline=base*0.9+latency*0.1}
            } else {baseline=latency}
        }
        if timestamp != sample.timestamp {
            timestamp=sample.timestamp
            pressuredSamples=pressure ? pressuredSamples+1:0
        }
        result.congested=pressuredSamples>=3
        if pressure {result.headroom=false}
        return result
    }
}

/// The archive lane continues monitoring while the metadata lane is idle.
/// Keychain reads use the existing session cache. Identity is checked before
/// publishing metrics; changing the configured NAS cannot reuse old samples.
final class ArchiveNASMonitoring {
    private var task:Task<Void,Never>?
    init(config:NASConfiguration,secrets:NASSecrets,mounts:[MountedSource]) {
        guard config.enabled,mounts.contains(where:{!$0.local}) else {return}
        task=Task {
            let monitor=SynologyMonitor()
            var domains=Set<String>()
            while !Task.isCancelled {
                let sample=await monitor.sample(config,secrets:secrets,origin:"archive",includeIdentity:domains.isEmpty)
                guard !Task.isCancelled else {return}
                if domains.isEmpty {
                    for mount in mounts where !mount.local {
                        let match=NASAddressIdentity.match(mount.identity,host:config.host,interfaces:sample.interfaceAddresses)
                        if NASAddressIdentity.confirmed(match) {
                            let key=IOBudgetCoordinator.storageKey(path:mount.path,mounts:mounts)
                            IOBudgetCoordinator.shared.registerNAS(domain:key,configuration:config)
                            domains.insert(IOBudgetCoordinator.shared.canonicalDomain(key,current:config))
                        }
                    }
                }
                for domain in domains {NASFeedback.shared.store(sample,domain:domain,configuration:config)}
                try? await Task.sleep(nanoseconds:6_000_000_000)
            }
        }
    }
    deinit {task?.cancel()}
}

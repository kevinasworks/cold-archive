// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One atomic policy document is shared with Python. Absent documents retain
/// the legacy global-limit protocol used by standalone engine integrations.
struct WriteAdmissionPolicy:Codable {
    var limit:Int
    var default_limit:Int
    var domain_limits:[String:Int]
    var aliases:[String:String]
    func canonical(_ domain:String)->String {aliases[domain] ?? domain}
    func domainLimit(_ domain:String)->Int {max(0,min(64,domain_limits[canonical(domain)] ?? default_limit))}
    static func load(_ root:URL) throws -> Self {
        let policy=root.appendingPathComponent("policy.json")
        if FileManager.default.fileExists(atPath:policy.path) {
            return try JSONDecoder().decode(Self.self,from:Data(contentsOf:policy))
        }
        let limit=ConcurrencySettings.bounded(Int(try String(contentsOf:root.appendingPathComponent("limit"))) ?? 1)
        return Self(limit:limit,default_limit:limit,domain_limits:[:],aliases:[:])
    }
}

/// Allocate scarce admission capacity across devices before handing out spare
/// slots. Existing excess writers drain normally; queued devices get a share.
enum WriteAllocation {
    static func limits(targets:[String:Int],demand:[String:Int],ceiling:Int,priority:[String]=[])->[String:Int] {
        let available=demand.keys.filter{(demand[$0] ?? 0)>0}.sorted()
        let keys=priority.filter{available.contains($0)}+available.filter{!priority.contains($0)}
        var remaining=max(0,ceiling),result:[String:Int]=[:]
        while remaining>0 {
            var added=false
            for key in keys where remaining>0 {
                let wanted=min(demand[key] ?? 0,max(1,targets[key] ?? 1))
                if result[key,default:0]<wanted {result[key,default:0] += 1;remaining -= 1;added=true}
            }
            if !added {break}
        }
        // Zero is intentional for a temporarily unallocated domain. Clients
        // must preserve it rather than clamp it to one and exceed the budget.
        for key in keys where result[key]==nil {result[key]=0}
        return result
    }
}

/// FIFO reservations respect device quotas: a blocked device cannot reserve
/// another device's free slot. Used by read and write pools alike.
enum AdmissionOrder {
    struct Waiter {let id:String;let domain:String;let queued:Double}
    static func mayEnter(domain:String,ticket:Waiter,waiting:[Waiter],active:[String:Int],policy:WriteAdmissionPolicy)->Bool {
        var virtual=active
        var total=active.values.reduce(0,+)
        for waiter in waiting.sorted(by:{($0.queued,$0.id)<($1.queued,$1.id)}) {
            if (waiter.queued,waiter.id)>=(ticket.queued,ticket.id) {break}
            let key=policy.canonical(waiter.domain)
            if total<policy.limit,virtual[key,default:0]<policy.domainLimit(key) {virtual[key,default:0] += 1;total += 1}
        }
        let key=policy.canonical(domain)
        return total<policy.limit && virtual[key,default:0]<policy.domainLimit(key)
    }
}

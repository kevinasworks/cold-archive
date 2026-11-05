// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class WriteAdmissionTests:XCTestCase {
    func testOlderReadWaiterCannotBeStarvedByRepeatedNewAdmissions() {
        let policy=WriteAdmissionPolicy(limit:1,default_limit:1,domain_limits:[:],aliases:[:])
        let old=AdmissionOrder.Waiter(id:"old",domain:"archive-hash",queued:1)
        let incoming=AdmissionOrder.Waiter(id:"new",domain:"metadata",queued:2)
        XCTAssertFalse(AdmissionOrder.mayEnter(domain:"metadata",ticket:incoming,waiting:[old,incoming],active:[:],policy:policy))
        XCTAssertTrue(AdmissionOrder.mayEnter(domain:"archive-hash",ticket:old,waiting:[old,incoming],active:[:],policy:policy))
        var independent=policy;independent.limit=2;independent.domain_limits=["blocked":0,"metadata":2]
        let blocked=AdmissionOrder.Waiter(id:"blocked",domain:"blocked",queued:0)
        XCTAssertTrue(AdmissionOrder.mayEnter(domain:"metadata",ticket:incoming,waiting:[blocked,incoming],active:[:],policy:independent))
    }
    func testSeparateDeviceLimitsConfirmedAliasesZeroAndDrain() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        for i in 0..<64 {FileManager.default.createFile(atPath:root.appendingPathComponent(String(i)).path,contents:nil)}
        var policy=WriteAdmissionPolicy(limit:64,default_limit:1,domain_limits:["A":1,"B":2],aliases:["alias-A":"A"])
        func save() throws {try JSONEncoder().encode(policy).write(to:root.appendingPathComponent("policy.json"),options:.atomic)}
        try save()
        var a=try PermitPool.acquire(root,wait:false,domain:"A")
        XCTAssertNotNil(a)
        XCTAssertNil(try PermitPool.acquire(root,wait:false,domain:"alias-A"))
        var b=try PermitPool.acquire(root,wait:false,domain:"B")
        var b2=try PermitPool.acquire(root,wait:false,domain:"B")
        XCTAssertNotNil(b);XCTAssertNotNil(b2)
        XCTAssertNil(try PermitPool.acquire(root,wait:false,domain:"B"))
        XCTAssertEqual(PermitPool.snapshot(root).activeByDomain,["A":1,"B":2])
        policy.limit=0;try save()
        XCTAssertNil(try PermitPool.acquire(root,wait:false,domain:"new-device"))
        XCTAssertEqual(PermitPool.snapshot(root).active,3,"Safety pause never cancels existing work")
        b2=nil
        policy.limit=64;policy.domain_limits=["A":0,"B":1];try save()
        XCTAssertNil(try PermitPool.acquire(root,wait:false,domain:"A"))
        XCTAssertNil(try PermitPool.acquire(root,wait:false,domain:"B"))
        a=nil;b=nil
        XCTAssertNotNil(try PermitPool.acquire(root,wait:false,domain:"B"))
        XCTAssertEqual(PermitPool.snapshot(root).active,0)
    }
    func testFairAllocationAndSafetyPause() {
        let targets=["A":16,"B":8],demand=["A":20,"B":20]
        XCTAssertEqual(WriteAllocation.limits(targets:targets,demand:demand,ceiling:8),["A":4,"B":4])
        XCTAssertEqual(WriteAllocation.limits(targets:targets,demand:demand,ceiling:0),["A":0,"B":0])
        XCTAssertEqual(WriteAllocation.limits(targets:targets,demand:demand,ceiling:1,priority:["B","A"]),["A":0,"B":1])
        let allocated=WriteAllocation.limits(targets:["A":1,"B":16],demand:demand,ceiling:8)
        XCTAssertEqual(allocated,["A":1,"B":7])
    }
    func testLogicalMeasurementsRemainSeparateAcrossDevicesAndPhases() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder=root.appendingPathComponent("observations")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        for (name,domain,stage,bytes) in [("one","A","export",100),("two","B","target_write",200),("three","A","restore",300)] {
            try JSONSerialization.data(withJSONObject:["domain":domain,"stage":stage,"bytes":bytes,"calls":1,"seconds":0.5,"pid":42]).write(to:folder.appendingPathComponent(name))
        }
        var meter=LogicalWriteMeter()
        let samples=meter.sampleDomains(root:root)
        XCTAssertEqual(samples[.init(domain:"A",stage:"export")]?.bytes,100)
        XCTAssertEqual(samples[.init(domain:"B",stage:"target_write")]?.bytes,200)
        XCTAssertEqual(samples[.init(domain:"A",stage:"restore")]?.bytes,300)
        XCTAssertEqual(samples[.init(domain:"A",stage:"export")]?.producers,[42])
        XCTAssertEqual(meter.sampleDomains(root:root).values.reduce(UInt64(0)){$0+$1.bytes},0,"Cumulative counters are never counted twice")
    }
}

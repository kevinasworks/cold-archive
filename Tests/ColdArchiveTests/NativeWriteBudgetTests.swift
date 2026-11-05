// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class NativeWriteBudgetTests: XCTestCase {
    func testTemporaryDestinationResolvesMountSymlinks() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        XCTAssertTrue(WriteBudget.verifiedLocalTemporary(root.appendingPathComponent("not-created")))
        let link=root.appendingPathComponent("other-volume")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:URL(fileURLWithPath:"/dev"))
        XCTAssertFalse(WriteBudget.verifiedLocalTemporary(link.appendingPathComponent("not-created")))
    }
    func testEngineeringCeilingAdmits64RealNativeWriters() throws {
        try WriteBudget.configure(.init(readMode:"custom",writeMode:"custom",readers:64,writers:64))
        defer {try? WriteBudget.configure(.load())}
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        let group=DispatchGroup()
        for _ in 0..<64 {
            group.enter()
            Thread.detachNewThread {
                defer {group.leave()}
                do {
                    try WriteBudget.native {
                        entered.signal()
                        _=release.wait(timeout:.now()+10)
                    }
                } catch {XCTFail("64-slot admission failed: \(error)")}
            }
        }
        var count=0
        for _ in 0..<64 {
            if entered.wait(timeout:.now()+5) != .success {break}
            count += 1
        }
        let active=PermitPool.snapshot(try WriteBudget.directory.get()).active
        for _ in 0..<64 {release.signal()}
        XCTAssertEqual(group.wait(timeout:.now()+10),.success)
        XCTAssertEqual(count,64)
        XCTAssertEqual(active,64,"Safety ceiling must be executable, not just a settings number")
    }
    func testNativeExportCopyCountsActualBytesAndNeverOverwrites() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root);try? WriteBudget.configure(.load())}
        try WriteBudget.configure(.init(readMode:"custom",writeMode:"custom",readers:2,writers:2))
        let source=root.appendingPathComponent("input"),target=root.appendingPathComponent("output")
        let payload=Data(repeating:0x8f,count:3*1024*1024+17)
        try payload.write(to:source)
        var meter=LogicalWriteMeter()
        _=meter.sample(root:try WriteBudget.directory.get())
        try WriteBudget.copyTarget(from:source,to:target)
        let observed=meter.sample(root:try WriteBudget.directory.get())
        XCTAssertEqual(observed.bytes,UInt64(payload.count))
        XCTAssertEqual(observed.calls,4)
        XCTAssertEqual(try Data(contentsOf:target),payload)
        XCTAssertThrowsError(try WriteBudget.copyTarget(from:source,to:target))
        XCTAssertEqual(try Data(contentsOf:target),payload)
        XCTAssertEqual(try Data(contentsOf:source),payload)
    }
    func testNativeWritersActuallyOverlapAndConfigurationDoesNotBlock() throws {
        let previous = WriteBudget.configuredLimit
        defer { try? WriteBudget.configure(.init(readMode:"custom",writeMode:"custom",readers:1,writers:previous)) }
        try WriteBudget.configure(.init(readMode:"custom",writeMode:"custom",readers:1,writers:2))
        let entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
        let group=DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer {group.leave()}
                try? WriteBudget.native {
                    try WriteBudget.native {
                        entered.signal()
                        _=release.wait(timeout:.now()+5)
                    }
                }
            }
        }
        let first=entered.wait(timeout:.now()+2)
        let second=entered.wait(timeout:.now()+2)
        let configured=DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            try? WriteBudget.configure(.init(readMode:"custom",writeMode:"custom",readers:1,writers:1))
            configured.signal()
        }
        let changed=configured.wait(timeout:.now()+1)
        release.signal();release.signal()
        XCTAssertEqual(group.wait(timeout:.now()+5),.success)
        XCTAssertEqual(first,.success)
        XCTAssertEqual(second,.success,"Native pool must not serialize independent writers")
        XCTAssertEqual(changed,.success,"Updating target must not wait for active writes")
    }
    func testLiveWritePolicyChangesPreserveOutstandingLeases() throws {
        var settings=ConcurrencySettings(readMode:"custom",writeMode:"custom",readers:1,writers:1)
        try WriteBudget.configure(settings)
        defer {try? WriteBudget.configure(.load())}
        let root=try WriteBudget.directory.get()
        var first=try PermitPool.acquire(root,wait:false,domain:"fixture")
        XCTAssertNotNil(first)
        XCTAssertNil(try PermitPool.acquire(root,wait:false,domain:"fixture"))

        settings.writers=2
        try WriteBudget.configure(settings)
        var second=try PermitPool.acquire(root,wait:false,domain:"fixture")
        XCTAssertNotNil(second)
        settings.writeMode="smart"
        try WriteBudget.configure(settings)
        XCTAssertEqual(PermitPool.snapshot(root).active,2)
        XCTAssertNil(try PermitPool.acquire(root,wait:false,domain:"fixture"))
        first=nil
        XCTAssertNil(try PermitPool.acquire(root,wait:false,domain:"fixture"))

        settings.writeMode="custom"
        try WriteBudget.configure(settings)
        XCTAssertNotNil(try PermitPool.acquire(root,wait:false,domain:"fixture"))
        settings.writers=1
        try WriteBudget.configure(settings)
        XCTAssertNil(try PermitPool.acquire(root,wait:false,domain:"fixture"))
        second=nil
        XCTAssertNotNil(try PermitPool.acquire(root,wait:false,domain:"fixture"))
    }

}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class ProcessActivityTests: XCTestCase {
    func testNativeSelfSample() {
        let sample = ProcessActivity.sample(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(sample.processes.isEmpty)
        XCTAssertGreaterThan(sample.processes.first?.footprint ?? 0, 0)
    }
    func testCounterIdentityAndDisappearanceDoNotInventThroughput() {
        func row(_ pid: Int32, _ start: UInt64, _ read: UInt64) -> ProcessActivity.Usage {
            .init(identity:.init(pid:pid,start:start),cpu:read,read:read,write:0,footprint:100)
        }
        var delta = ProcessActivityDelta()
        let first = delta.observe(.init(processes:[row(1,10,100)],complete:true))
        XCTAssertEqual(first.readBytes,0); XCTAssertFalse(first.complete)
        let next = delta.observe(.init(processes:[row(1,10,150)],complete:true))
        XCTAssertEqual(next.readBytes,50); XCTAssertTrue(next.complete)
        let reused = delta.observe(.init(processes:[row(1,20,900)],complete:true))
        XCTAssertEqual(reused.readBytes,0); XCTAssertFalse(reused.complete)
        let gone = delta.observe(.init(processes:[],complete:true))
        XCTAssertEqual(gone.readBytes,0); XCTAssertFalse(gone.complete)
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class NASCPUAndReductionTests:XCTestCase {
    func counters(_ scale:Double)->[String:Double] {
        let raw:[Int:Double]=[50:20,51:0,52:10,53:70,54:900,56:0,61:0,64:0,11:3]
        return Dictionary(uniqueKeysWithValues:raw.map{("1.3.6.1.4.1.2021.11.\($0.key).0",$0.value*scale)})
    }
    func testIOWaitIsNotCPUAndOneMinuteIdleIsIgnored() throws {
        var delta=NASCPUDelta()
        XCTAssertNil(delta.sample(values:counters(1),time:0))
        let result=try XCTUnwrap(delta.sample(values:counters(2),time:6))
        XCTAssertEqual(result.busy,3,accuracy:0.001)
        XCTAssertEqual(result.wait,90,accuracy:0.001)
    }
    func testMissingResetStaleAndUnchangedCountersCannotCreateCPUOverload() {
        var delta=NASCPUDelta()
        XCTAssertNil(delta.sample(values:[:],time:0))
        XCTAssertNil(delta.sample(values:counters(1),time:6))
        XCTAssertNil(delta.sample(values:counters(1),time:12))
        XCTAssertNil(delta.sample(values:counters(0.1),time:18))
        XCTAssertNil(delta.sample(values:counters(2),time:60))
        var missing=counters(3);missing.removeValue(forKey:"1.3.6.1.4.1.2021.11.54.0")
        XCTAssertNil(delta.sample(values:missing,time:66))
        XCTAssertNil(delta.sample(values:counters(4),time:72))
    }
    func testDoNotStackReductionsBeforeRunningFilesFinish() {
        var c=ThroughputController(initial:4)
        var o=ThroughputController.Observation(rate:0,duration:0,active:4,waiting:20,ceiling:8,reliable:false,critical:true)
        XCTAssertEqual(c.observe(o).reason,"critical_resource_pressure")
        XCTAssertEqual(c.target,2)
        for _ in 0..<10 {
            XCTAssertEqual(c.observe(o).reason,"draining_existing_work")
            XCTAssertEqual(c.target,2)
        }
        o.active=2
        XCTAssertEqual(c.observe(o).target,1)
    }
    func testPlateauAndSingleNoisyWindowDoNotReduceConcurrency() {
        var c=ThroughputController(initial:4)
        var o=ThroughputController.Observation(rate:100,duration:4,active:4,waiting:20,ceiling:4)
        for _ in 0..<4 {_=c.observe(o)}
        o.rate=60;o.congested=true
        _=c.observe(o)
        XCTAssertEqual(c.target,4)
        o.rate=110;o.congested=false
        _=c.observe(o);_=c.observe(o)
        XCTAssertEqual(c.target,4)
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class ThroughputControllerTests: XCTestCase {
    func testOpaqueWorkRequiresActivityEvidenceForSlowExploration() {
        var c=ThroughputController()
        var o=ThroughputController.Observation(rate:0,duration:4,active:1,waiting:20,ceiling:20,reliable:false)
        for _ in 0..<12 {_=c.observe(o)}
        XCTAssertEqual(c.target,1)
        o.explorationPermitted=true
        for _ in 0..<3 {_=c.observe(o)}
        XCTAssertEqual(c.target,2)
        // No workers have filled the new target: never stack blind probes.
        for _ in 0..<12 {_=c.observe(o)}
        XCTAssertEqual(c.target,2)
    }
    private func sample(_ rate: Double, _ c: ThroughputController, waiting: Int = 100,
                        congested: Bool = false) -> ThroughputController.Observation {
        .init(rate: rate, duration: 4, active: c.target, waiting: waiting,
              ceiling: 64, congested: congested)
    }
    func testLowerProbeFindsFasterSettingBelowStartupWithoutResourceAlarm() {
        var c=ThroughputController(initial:8,reprobeWindows:1)
        var sawLower=false
        for _ in 0..<160 {
            // Random-access model: two readers maximize throughput; extra
            // seeks reduce it. CPU/NAS alarms are deliberately absent.
            let rate=c.target<=2 ? Double(c.target)*100:200/Double(c.target-1)
            let d=c.observe(sample(rate,c))
            if d.reason == "probe_lower" {sawLower=true}
        }
        XCTAssertTrue(sawLower)
        XCTAssertLessThanOrEqual(c.target,3)
        XCTAssertGreaterThanOrEqual(c.target,2)
    }
    func testExploresBeyondLegacyLimitsWithMeasuredGains() {
        var c = ThroughputController()
        for _ in 0..<60 { _ = c.observe(sample(Double(c.target) * 100, c)) }
        XCTAssertGreaterThan(c.target, 10)
        XCTAssertLessThanOrEqual(c.target, 64)
    }
    func testPlateauDoesNotRunToCeilingAndEventuallyReprobes() {
        var c = ThroughputController(reprobeWindows: 2)
        var reasons: [String] = []
        var peak = 0
        for _ in 0..<100 {
            let d = c.observe(sample(100, c)); reasons.append(d.reason)
            peak = max(peak, c.target)
        }
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertTrue(reasons.contains("probe_no_gain"))
        XCTAssertGreaterThan(reasons.filter { $0 == "probe_higher" }.count, 1)
    }
    func testReductionDrainsAndNeverStacks() {
        var c = ThroughputController(initial: 16)
        var o = sample(100, c); o.critical = true
        XCTAssertEqual(c.observe(o).target, 8)
        XCTAssertEqual(c.observe(o).reason, "draining_existing_work")
        XCTAssertEqual(c.target, 8)
    }
    func testUnknownDataTailAndSingleSpikeDoNotReduce() {
        var c = ThroughputController(initial: 12)
        _ = c.observe(sample(100, c))
        var o = sample(1, c); o.reliable = false
        XCTAssertEqual(c.observe(o).reason, "insufficient_measurement")
        XCTAssertEqual(c.observe(sample(1, c, waiting: 0)).reason, "insufficient_demand")
        _ = c.observe(sample(1, c, congested: true))
        XCTAssertEqual(c.target, 12)
    }
    func testChangeOfMetricOrPhaseDiscardsOldBaseline() {
        var c = ThroughputController()
        for _ in 0..<4 { _ = c.observe(sample(100, c)) }
        var o = sample(1, c); o.context = "hash-bytes"
        XCTAssertEqual(c.observe(o).reason, "context_changed")
        XCTAssertNil(c.baseline)
    }
}

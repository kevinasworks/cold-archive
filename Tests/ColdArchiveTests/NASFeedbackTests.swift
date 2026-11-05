// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class NASFeedbackTests:XCTestCase {
    func testReadAndWriteLatencyAreNotInterchangeable() {
        var evidence=NASPressureEvidence()
        var sample=NASSample();sample.valid=true;sample.timestamp=10;sample.diskLoad=99;sample.cpu=2
        sample.readLatency=1000;sample.writeLatency=1000
        _=evidence.observe(sample,direction:.write,now:10)
        for time in [16.0,22,28] {
            sample.timestamp=time;sample.readLatency=20000;sample.writeLatency=1000
            let result=evidence.observe(sample,direction:.write,now:time)
            XCTAssertFalse(result.congested,"High read latency cannot become write congestion")
            XCTAssertEqual(result.latency,1000)
        }
        for time in [34.0,40,46] {
            sample.timestamp=time;sample.writeLatency=20000
            _=evidence.observe(sample,direction:.write,now:time)
        }
        XCTAssertTrue(evidence.observe(sample,direction:.write,now:46).congested)
    }
    func testMissingValuesAndStalenessAreUnknown() {
        var evidence=NASPressureEvidence()
        var sample=NASSample();sample.valid=true;sample.timestamp=10
        let missing=evidence.observe(sample,now:11)
        XCTAssertTrue(missing.fresh);XCTAssertFalse(missing.headroom);XCTAssertFalse(missing.congested)
        sample.cpu=1;sample.diskLoad=10
        XCTAssertTrue(evidence.observe(sample,now:11).headroom)
        XCTAssertFalse(evidence.observe(sample,now:41).fresh)
        XCTAssertFalse(evidence.observe(sample,now:41).headroom)
    }
    func testRepeatedPollOfOneHighSampleIsNotSustainedPressure() {
        var evidence=NASPressureEvidence()
        var sample=NASSample();sample.valid=true;sample.timestamp=10;sample.cpu=99
        for _ in 0..<10 {XCTAssertFalse(evidence.observe(sample,now:11).congested)}
        sample.timestamp=16;XCTAssertFalse(evidence.observe(sample,now:17).congested)
        sample.timestamp=22;XCTAssertTrue(evidence.observe(sample,now:23).congested)
        sample.timestamp=28;sample.cpu=2
        XCTAssertFalse(evidence.observe(sample,now:29).congested)
    }
}

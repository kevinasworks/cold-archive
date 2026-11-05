// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class ConcurrencySettingsTests:XCTestCase {
    func testDefaultsMigrationAndIndependentModes() {
        let name=UUID().uuidString
        let d=UserDefaults(suiteName:name)!
        defer {d.removePersistentDomain(forName:name)}
        XCTAssertEqual(ConcurrencySettings.load(d).readLimit,64)
        XCTAssertEqual(ConcurrencySettings.load(d).writeLimit,64)
        d.set(false,forKey:"adaptiveReading")
        XCTAssertFalse(ConcurrencySettings.load(d).adaptive)
        XCTAssertEqual(ConcurrencySettings.load(d).readLimit,1)
        d.set("custom",forKey:"readConcurrencyMode");d.set(7,forKey:"customReaders")
        d.set("custom",forKey:"writeConcurrencyMode");d.set(1,forKey:"customWriters")
        XCTAssertEqual(ConcurrencySettings.load(d).readLimit,7)
        XCTAssertEqual(ConcurrencySettings.load(d).writeLimit,1)
        d.set("smart",forKey:"readConcurrencyMode")
        XCTAssertEqual(ConcurrencySettings.load(d).readLimit,64)
        XCTAssertEqual(ConcurrencySettings.load(d).writeLimit,1)
        d.set(-1,forKey:"customWriters");XCTAssertEqual(ConcurrencySettings.load(d).writeLimit,1)
        d.set(1000,forKey:"customWriters");XCTAssertEqual(ConcurrencySettings.load(d).writeLimit,64)
    }
    func testLocalTemporaryAndLogDoNotWaitForTargetPermit() throws {
        XCTAssertNotNil(WriteBudget.localTemporaryDevice)
        try WriteBudget.configure(ConcurrencySettings(readMode:"smart",writeMode:"custom",readers:10,writers:1))
        defer {try? WriteBudget.configure(.load())}
        for kind in [WriteBudget.Kind.temporary, .log] {
            let done=DispatchSemaphore(value:0)
            try WriteBudget.native {
                DispatchQueue.global().async {
                    defer {done.signal()}
                    do {try WriteBudget.native(kind:kind) {}} catch {XCTFail("Independent writer failed: \(error)")}
                }
                XCTAssertEqual(done.wait(timeout:.now()+3),.success)
            }
        }
    }
    func testNativeNestedWriteWithOnePermit() throws {
        try WriteBudget.configure(ConcurrencySettings(readMode:"smart",writeMode:"custom",readers:10,writers:1))
        defer {try? WriteBudget.configure(ConcurrencySettings(readMode:"smart",writeMode:"smart",readers:10,writers:5))}
        let value=try WriteBudget.native {try WriteBudget.native {42}}
        XCTAssertEqual(value,42)
    }
}

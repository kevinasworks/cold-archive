// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

final class CredentialSessionTests: XCTestCase {
    func testRepeatedReadsReuseAuthorizationAndSaveReplacesCache() throws {
        let cache = CredentialSessionCache()
        var reads = 0
        for _ in 0..<10 {
            let value = try cache.load { reads += 1; return NASSecrets(auth: "synthetic") }
            XCTAssertEqual(value.auth, "synthetic")
        }
        XCTAssertEqual(reads, 1)
        cache.saved(NASSecrets(auth: "updated"))
        XCTAssertEqual(try cache.load { XCTFail("must not read again"); return NASSecrets() }.auth, "updated")
    }
    func testDenialIsNotRetriedUntilExplicitRequest() throws {
        let cache = CredentialSessionCache()
        var reads = 0
        for _ in 0..<3 {
            XCTAssertThrowsError(try cache.load { reads += 1; throw CocoaError(.userCancelled) })
        }
        XCTAssertEqual(reads, 1)
        _ = try cache.load(retry: true) { reads += 1; return NASSecrets() }
        XCTAssertEqual(reads, 2)
    }
}

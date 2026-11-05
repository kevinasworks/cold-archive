// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Security
@testable import ColdArchive

private final class CredentialBackendFixture: NASCredentialBackend {
    var values:[String:NASSecrets]=[:]
    var calls:[(String,Bool)]=[]
    var writes=0
    var legacyDenied=false
    var writeDenied=false
    func read(service:String,interaction:Bool) throws -> NASSecrets? {
        calls.append((service,interaction))
        if service==NASCredentialStore.legacyService && legacyDenied {throw CredentialAccessError(status:errSecInteractionNotAllowed,migration:true)}
        return values[service]
    }
    func write(service:String,secrets:NASSecrets) throws {
        writes+=1
        if writeDenied {throw CredentialAccessError(status:errSecAuthFailed,migration:false)}
        values[service]=secrets
    }
}
final class NASCredentialStoreTests:XCTestCase {
    func testLegacyDeniedNeverPromptsEvenOnExplicitRetryAndSaveRecovers() throws {
        let backend=CredentialBackendFixture();backend.legacyDenied=true
        let store=NASCredentialStore(backend:backend)
        for _ in 0..<10 {XCTAssertThrowsError(try store.load())}
        XCTAssertEqual(backend.calls.count,2)
        XCTAssertTrue(backend.calls.allSatisfy{!$0.1})
        XCTAssertThrowsError(try store.load(retry:true))
        XCTAssertFalse(backend.calls.last!.1,"Legacy must never be interactive")
        let value=NASSecrets(auth:"synthetic",privacy:"synthetic-private")
        try store.save(value)
        XCTAssertEqual(try store.load(),value)
        XCTAssertEqual(backend.writes,1)
        XCTAssertNil(backend.values[NASCredentialStore.legacyService])
    }
    func testAccessibleLegacyMigratesOnceAndPreservesOldItem() throws {
        let backend=CredentialBackendFixture();let value=NASSecrets(auth:"synthetic")
        backend.values[NASCredentialStore.legacyService]=value
        let store=NASCredentialStore(backend:backend)
        for _ in 0..<10 {XCTAssertEqual(try store.load(),value)}
        XCTAssertEqual(backend.writes,1);XCTAssertEqual(backend.calls.count,2)
        XCTAssertEqual(backend.values[NASCredentialStore.legacyService],value)
        XCTAssertEqual(backend.values[NASCredentialStore.service],value)
        try store.save(value);XCTAssertEqual(backend.writes,1)
    }
    func testMigrationWriteFailureNeverClaimsSuccessAndExplicitRetryRecovers() throws {
        let backend=CredentialBackendFixture();backend.values[NASCredentialStore.legacyService]=NASSecrets(auth:"synthetic");backend.writeDenied=true
        let store=NASCredentialStore(backend:backend)
        XCTAssertThrowsError(try store.load());XCTAssertThrowsError(try store.load())
        XCTAssertEqual(backend.writes,1)
        backend.writeDenied=false
        XCTAssertEqual(try store.load(retry:true).auth,"synthetic")
        XCTAssertEqual(backend.writes,2)
    }
    func testConcurrentQueueAndSettingsLoadsFetchOnlyOnce() {
        let backend=CredentialBackendFixture();backend.values[NASCredentialStore.service]=NASSecrets(auth:"synthetic")
        let store=NASCredentialStore(backend:backend)
        DispatchQueue.concurrentPerform(iterations:30) {_ in _=try? store.load()}
        XCTAssertEqual(backend.calls.count,1)
        XCTAssertFalse(backend.calls[0].1)
    }
    func testEmptyOrFailureValuesCannotOverwriteCredentials() throws {
        let backend=CredentialBackendFixture();let store=NASCredentialStore(backend:backend)
        XCTAssertThrowsError(try store.save(NASSecrets()))
        XCTAssertThrowsError(try store.save(NASSecrets(auth:"synthetic",loadingError:"failed")))
        XCTAssertEqual(backend.writes,0)
    }
}

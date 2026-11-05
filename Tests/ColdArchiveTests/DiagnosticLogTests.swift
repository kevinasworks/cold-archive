// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class DiagnosticLogTests:XCTestCase {
    func testAllowlistExcludesSensitiveFieldsAndArbitraryErrorText() throws {
        let row=DiagnosticLog.sanitized(["event":"snmp_error","message":"secret host.example /Users/private", "password":"secret", "host":"host.example","user":"private", "community":"secret", "path":"/Users/private", "authentication":"secret", "oid":"host.example", "library_error": -24, "code":"timeout"])
        XCTAssertEqual(Set(row.keys),Set(["event","library_error","code"]))
        let fields=DiagnosticLog.errorFields("SNMP 会话失败（库错误 -24，系统错误 0）：Timeout private-host")
        XCTAssertEqual(fields["library_error"] as? Int,-24)
        XCTAssertEqual(fields["code"] as? String,"timeout")
        XCTAssertFalse(String(describing:fields).contains("private-host"))
    }
    func testPersistentRecordsPermissionsAndCorrelation() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let log=DiagnosticLog(directory:root)
        XCTAssertEqual(log.target("Private.Host"),log.target("private.host"))
        XCTAssertNotEqual(log.target("Private.Host"),log.target("second.host"))
        for event in ["snmp_begin","snmp_error","snmp_end"] {
            XCTAssertTrue(log.write(["event":event,"operation":"fixture","target_ref":log.target("Private.Host"),"message":"sentinel-secret"]))
        }
        let file=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first)
        let text=try String(contentsOf:file,encoding:.utf8)
        XCTAssertFalse(text.contains("Private.Host"));XCTAssertFalse(text.contains("sentinel-secret"))
        let rows=try text.split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
        XCTAssertEqual(rows.count,3);XCTAssertEqual(rows.last?["sequence"] as? Int,3)
        XCTAssertEqual(Set(rows.compactMap{$0["session"] as? String}).count,1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testRotationBoundsAndKeepsUnrelatedFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let other=root.appendingPathComponent("user-note.txt");try Data("keep".utf8).write(to:other)
        let log=DiagnosticLog(directory:root,maximumBytes:1)
        for _ in 0..<14 {XCTAssertTrue(log.write(["event":"test"]))}
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        XCTAssertEqual(files.filter{$0.pathExtension=="jsonl"}.count,10)
        XCTAssertTrue(FileManager.default.fileExists(atPath:other.path))
    }
    func testConnectionTestFailureIsPersistedWithoutCredentials() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let log=DiagnosticLog(directory:root)
        var config=NASConfiguration();config.host="https://sensitive.example";config.user="private-user"
        let result=SynologyMonitor.read(config,NASSecrets(auth:"auth-sentinel",privacy:"privacy-sentinel"),origin:"connection_test",diagnosticLogger:log)
        XCTAssertFalse(result.valid)
        let file=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first)
        let text=try String(contentsOf:file,encoding:.utf8)
        for secret in ["sensitive.example","private-user","auth-sentinel","privacy-sentinel"] {XCTAssertFalse(text.contains(secret))}
        for event in ["snmp_begin","snmp_error","snmp_end","connection_test","configuration"] {XCTAssertTrue(text.contains(event))}
    }
    func testWriteFailureIsReported() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to:file);defer{try? FileManager.default.removeItem(at:file)}
        let log=DiagnosticLog(directory:file)
        XCTAssertFalse(log.write(["event":"test"]));XCTAssertTrue(log.failure)
    }
}

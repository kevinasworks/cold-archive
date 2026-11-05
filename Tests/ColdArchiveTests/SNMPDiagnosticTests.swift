// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Darwin
@testable import ColdArchive
final class SNMPDiagnosticTests:XCTestCase {
    func testAddressClassificationAndTraceRedaction() throws {
        XCTAssertEqual(SNMPDiagnosticTrace.scope("192.168.120.2"),"private")
        XCTAssertEqual(SNMPDiagnosticTrace.scope("172.31.2.3"),"private")
        XCTAssertEqual(SNMPDiagnosticTrace.scope("100.64.0.1"),"shared")
        XCTAssertEqual(SNMPDiagnosticTrace.scope("28.0.0.74"),"other_ipv4")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let log=DiagnosticLog(directory:root)
        let trace=SNMPDiagnosticTrace(log:log,operation:"fixture",origin:"test",stage:"model",target:"target-1",oid:"1.3.6.1.2.1.1.3.0")
        trace.receive("dns_address","192.168.120.2",2,0)
        trace.receive("selected_address","192.168.120.2",2,0)
        trace.receive("route_interface","utun8",0,0)
        trace.receive("udp_send","failed",-1,13)
        trace.finish(success:false)
        let rows=try read(root)
        XCTAssertEqual(rows[0]["address_ref"] as? String,rows[1]["address_ref"] as? String)
        XCTAssertEqual(rows[2]["interface_name"] as? String,"utun8")
        XCTAssertEqual(rows.last?["code"] as? String,"local_send_failed")
        XCTAssertEqual(rows.last?["send_failures"] as? Int,1)
        XCTAssertFalse(String(describing:rows).contains("192.168.120.2"))
        XCTAssertNil(DiagnosticLog.sanitized(["interface_name":"private-user-network"])["interface_name"])
    }
    private func read(_ root:URL)throws->[[String:Any]] {
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        return try files.flatMap{try String(contentsOf:$0,encoding:.utf8).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}}
    }
    func testHostnameIPv6AndSampleSessionReuse() async throws {
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/snmp_fixture.py")
        for (host,tcp) in [("localhost",false),("::1",false),("localhost",true),("::1",true)] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer{try? FileManager.default.removeItem(at:root)}
            var hints=addrinfo();hints.ai_family=AF_UNSPEC;hints.ai_socktype=SOCK_DGRAM
            var addresses:UnsafeMutablePointer<addrinfo>?
            XCTAssertEqual(getaddrinfo("localhost","161",&hints,&addresses),0)
            let firstFamily=addresses?.pointee.ai_family
            if let addresses {freeaddrinfo(addresses)}
            // Bind only the opposite of the resolver's first candidate. No
            // assumptions about IPv4/IPv6 ordering on the test host.
            let useIPv6=host == "::1" || firstFamily == AF_INET
            let identityCheck=host == "::1" && tcp
            let process=Process();process.executableURL=Runtime.python
            process.arguments=["-u",fixture.path]+(useIPv6 ? ["--ipv6"]:[])+(tcp ? ["--tcp"]:[])+(identityCheck ? ["--identity"]:[])
            let pipe=Pipe();process.standardOutput=pipe
            let exited=DispatchSemaphore(value:0)
            process.terminationHandler={_ in exited.signal()}
            try process.run()
            defer {
                if process.isRunning {process.terminate()}
                XCTAssertEqual(exited.wait(timeout:.now()+5),.success,"Fixture cleanup timed out")
            }
            guard let line=String(data:pipe.fileHandleForReading.availableData,encoding:.utf8),let port=Int(line.trimmingCharacters(in:.whitespacesAndNewlines)) else {throw XCTSkip("Loopback bind unavailable")}
            var config=NASConfiguration();config.transport=tcp ? "TCP":"UDP";config.host=host;config.version=2;config.port=port
            XCTAssertNoThrow(try config.validate())
            let log=DiagnosticLog(directory:root)
            let result:NASSample=await withCheckedContinuation{c in
                SynologyMonitor.queue.async {c.resume(returning:SynologyMonitor.read(config,NASSecrets(auth:"fixture-secret"),origin:"connection_test",diagnosticLogger:log,includeIdentity:identityCheck))}
            }
            XCTAssertTrue(result.valid,result.message)
            XCTAssertTrue(result.smbAvailable)
            XCTAssertEqual(result.smbNames.count,32)
            XCTAssertEqual(result.values.keys.filter {$0.hasPrefix("1.3.6.1.4.1.6574.111.")}.count,64)
            XCTAssertEqual(result.values["1.3.6.1.4.1.6574.111.3.1.4.12"],2000,"Last SMB page must be read")
            if identityCheck {XCTAssertEqual(result.interfaceAddresses,["192.168.120.2"])}
            let rows=try read(root)
            XCTAssertEqual(rows.filter{($0["event"] as? String)=="snmp_session_reused"}.count,identityCheck ? 9:7)
            XCTAssertEqual(rows.filter{($0["event"] as? String)=="snmp_dns_begin"}.count,1)
            XCTAssertTrue(rows.contains{($0["event"] as? String)=="snmp_route_snapshot" && ($0["code"] as? String)=="actual_socket"})
            if host == "localhost" {XCTAssertEqual(rows.filter{($0["event"] as? String)=="snmp_candidate_attempt"}.count,2,"First localhost candidate must fall back to the other address family")}
            if host == "::1" {XCTAssertTrue(rows.contains{($0["event"] as? String)=="snmp_selected_address" && ($0["address_scope"] as? String)=="ipv6"})}
        }
    }
    func testRealTransportDropAndMalformedResponse() async throws {
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/snmp_fixture.py")
        for (mode,version) in [("--drop",2),("--malformed",2),("--drop",3)] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer{try? FileManager.default.removeItem(at:root)}
            let process=Process();process.executableURL=Runtime.python;process.arguments=["-u",fixture.path,mode]
            let pipe=Pipe();process.standardOutput=pipe
            let exited=DispatchSemaphore(value:0)
            process.terminationHandler={_ in exited.signal()}
            try process.run()
            defer {
                if process.isRunning {process.terminate()}
                XCTAssertEqual(exited.wait(timeout:.now()+5),.success,"Fixture cleanup timed out")
            }
            guard let line=String(data:pipe.fileHandleForReading.availableData,encoding:.utf8),let port=Int(line.trimmingCharacters(in:.whitespacesAndNewlines)) else {throw XCTSkip("Loopback bind unavailable")}
            var config=NASConfiguration();config.transport="UDP";config.host="127.0.0.1";config.version=version;config.user="fixture-user";config.port=port
            let log=DiagnosticLog(directory:root)
            let result:NASSample=await withCheckedContinuation{c in
                SynologyMonitor.queue.async {c.resume(returning:SynologyMonitor.read(config,NASSecrets(auth:"fixture-secret"),origin:"connection_test",diagnosticLogger:log))}
            }
            XCTAssertFalse(result.valid)
            let rows=try read(root)
            let summary=try XCTUnwrap(rows.first{($0["event"] as? String)=="snmp_transport_summary"})
            XCTAssertEqual(summary["send_count"] as? Int,2)
            XCTAssertEqual(summary["receive_count"] as? Int,mode=="--drop" ? 0:2)
            XCTAssertEqual(summary["code"] as? String,mode=="--drop" ? "sent_without_observed_receive":"received_but_query_failed")
            for e in ["snmp_dns_end","snmp_selected_address","snmp_route_interface","snmp_query_error","snmp_end"] {XCTAssertTrue(rows.contains{($0["event"] as? String)==e},e)}
            if version==3 {
                XCTAssertTrue(rows.contains{($0["event"] as? String)=="snmp_engine_state" && ($0["native_value"] as? Int)==0})
            }
            XCTAssertFalse(String(describing:rows).contains("fixture-secret"))
            XCTAssertFalse(String(describing:rows).contains("127.0.0.1"))
        }
    }
}

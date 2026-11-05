// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import NativeMonitor
@testable import ColdArchive
private final class ReadingTestPressure: @unchecked Sendable {
    private let lock=NSLock()
    private var enabled=false
    func observe(_ text:String) {
        if text.contains("正在读取 2 个") || text.contains("正在读取 4 个") {
            lock.lock();enabled=true;lock.unlock()
        }
    }
    func read()->Bool {lock.lock();defer{lock.unlock()};return enabled}
    func takeCritical()->Bool {lock.lock();defer{lock.unlock()};let value=enabled;enabled=false;return value}
}
final class AdaptiveReadingTests:XCTestCase {
    func testTransportDefaultsMigrationAndValidation() throws {
        var config=NASConfiguration();config.host="nas.local";config.user="fixture"
        XCTAssertEqual(config.transport,"TCP")
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(config)) as! [String:Any]
        object.removeValue(forKey:"transport")
        let old=try JSONDecoder().decode(NASConfiguration.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(old.transport ?? "TCP","TCP")
        config.transport="UDP"
        XCTAssertEqual(try JSONDecoder().decode(NASConfiguration.self,from:JSONEncoder().encode(config)).transport,"UDP")
        config.transport="invalid";XCTAssertThrowsError(try config.validate())
        XCTAssertEqual(DiagnosticLog.category("NAS 未响应 SNMP 请求"),"timeout")
    }
    func testObservedDSMVersionRepresentations() {
        for value in ["DSM 7.3-86009","DSM 7.3.2-86009 Update 3","7.3.2-86009"," DSM 7.3-86009\n"] {XCTAssertTrue(supportedDSMVersion(value),value)}
        for value in ["DSM 7.3-860090","DSM 7.2-86009","DSM 7.3.1-86009","DSM 7.3.2-86009 Update 4","", "garbage7.3.2-86009"] {XCTAssertFalse(supportedDSMVersion(value),value)}
    }
    func testNASStatusDistinguishesWaitingFailureStaleAndConnected() {
        var sample=NASSample()
        XCTAssertTrue(sample.progressDescription(received:false).contains("正在连接"))
        sample.message="认证失败"
        XCTAssertTrue(sample.progressDescription(received:true).contains("认证失败"))
        sample.valid=true
        XCTAssertEqual(sample.progressDescription(received:true),"NAS 监测已接入 · SMB 指标未返回")
        sample.timestamp -= 31
        XCTAssertTrue(sample.progressDescription(received:true).contains("已过期"))
    }
    func testNASIdentityAndLegacyConfiguration() throws {
        XCTAssertTrue(matchesNAS("nas.local/share",host:"NAS.local."))
        XCTAssertFalse(matchesNAS("other.local/share",host:"nas.local"))
        XCTAssertFalse(matchesNAS(nil,host:"nas.local"))
        XCTAssertFalse(matchesNAS("192.168.1.2/share",host:"nas.example.com"))
        var old=NASConfiguration();old.host="nas.local";old.user="fixture";old.privacy=true
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
        object.removeValue(forKey:"authProtocol");object.removeValue(forKey:"privacyProtocol")
        let restored=try JSONDecoder().decode(NASConfiguration.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertTrue(restored.privacy);XCTAssertEqual(restored.authProtocol ?? "SHA","SHA")
        XCTAssertFalse(NASConfiguration().privacy)
    }
    func testSchedulingReasonsAndMeasurementsSurviveRedaction() {
        let fields=DiagnosticLog.sanitized(["event":"control_window","code":"headroom_probe","nas_cpu":3,"disk_load":20,"mac_pressure":false,"nas_pressure":false,"nas_headroom":true,"samples":0,"rate":0.0,"window_seconds":6.0,"password":"must-not-survive"])
        XCTAssertEqual(fields["code"] as? String,"headroom_probe")
        XCTAssertEqual(fields["nas_cpu"] as? Int,3)
        XCTAssertEqual(fields["window_seconds"] as? Double,6)
        XCTAssertEqual(fields["nas_headroom"] as? Bool,true)
        XCTAssertNil(fields["password"])
    }
    func testConfigurationValidationAndStaleMetrics() throws {
        var c=NASConfiguration();c.host="https://example.test";XCTAssertThrowsError(try c.validate())
        c.host="192.0.2.1";c.version=2;XCTAssertNoThrow(try c.validate())
        c.port=0;XCTAssertThrowsError(try c.validate())
        var s=NASSample();s.valid=true;s.timestamp=ProcessInfo.processInfo.systemUptime-31;XCTAssertFalse(s.fresh)
    }
    func testNativeSNMPAgainstLoopbackAgent() async throws {
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/snmp_fixture.py")
        let process=Process();process.executableURL=Runtime.python;process.arguments=["-u",fixture.path]
        let pipe=Pipe();process.standardOutput=pipe
        let exited=DispatchSemaphore(value:0)
        process.terminationHandler={_ in exited.signal()}
        try process.run();defer{if process.isRunning {process.terminate()};XCTAssertEqual(exited.wait(timeout:.now()+5),.success)}
        let first=pipe.fileHandleForReading.availableData
        guard let text=String(data:first,encoding:.utf8),let port=Int(text.trimmingCharacters(in:.whitespacesAndNewlines)) else {throw XCTSkip("Loopback UDP unavailable")}
        var config=NASConfiguration();config.transport="UDP";config.host="127.0.0.1";config.port=port;config.version=2
        let monitor=SynologyMonitor()
        let sample=await monitor.sample(config,secrets:NASSecrets(auth:"fixture-only",privacy:""))
        XCTAssertTrue(sample.valid,sample.message);XCTAssertEqual(sample.model,"DS923+")
        XCTAssertNil(sample.cpu,"First raw-counter sample is a baseline, not a CPU reading");XCTAssertEqual(sample.readLatency,2000)
        XCTAssertNil(sample.diskLoad,"Missing table must not become zero")
        try await Task.sleep(nanoseconds:1_100_000_000)
        let next=await monitor.sample(config,secrets:NASSecrets(auth:"fixture-only",privacy:""))
        XCTAssertEqual(try XCTUnwrap(next.cpu),3,accuracy:0.001)
        XCTAssertEqual(try XCTUnwrap(next.cpuWait),90,accuracy:0.001)
        XCTAssertTrue(next.message.contains("CPU 运算"))
    }
    func testNativeSNMPv3AuthenticationAndPrivacy() async throws {
        guard FileManager.default.isExecutableFile(atPath:"/usr/libexec/snmpd") else {throw XCTSkip("No local SNMP agent")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SNMPv3Fixture-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        let port=Int.random(in:30000...50000)
        let conf=root.appendingPathComponent("agent.conf")
        let baseCombinations=[("SHA","AES",true),("SHA","DES",true),("MD5","AES",true),("MD5","DES",true),("SHA","AES",false),("MD5","AES",false)]
        let combinations=baseCombinations+baseCombinations
        var agentConfig="agentaddress udp:127.0.0.1:\(port),tcp:127.0.0.1:\(port)\nsysLocation ColdArchiveFixture\n"
        for (i,c) in combinations.enumerated() {
            agentConfig += "createUser fixture\(i) \(c.0) fixture-auth-123 \(c.1) fixture-priv-123\nrouser fixture\(i) \(c.2 ? "priv":"auth")\n"
        }
        try agentConfig.write(to:conf,atomically:true,encoding:.utf8)
        let agent=Process();agent.executableURL=URL(fileURLWithPath:"/usr/libexec/snmpd")
        agent.arguments=["-f","-C","-c",conf.path,"-Lf",root.appendingPathComponent("agent.log").path,"-p",root.appendingPathComponent("pid").path]
        var env=ProcessInfo.processInfo.environment;env["SNMP_PERSISTENT_DIR"]=root.path;env["MIBS"]="";agent.environment=env
        agent.standardOutput=FileHandle.nullDevice;agent.standardError=FileHandle.nullDevice
        let agentExited=DispatchSemaphore(value:0)
        agent.terminationHandler={_ in agentExited.signal()}
        try agent.run();defer{if agent.isRunning {agent.terminate()};XCTAssertEqual(agentExited.wait(timeout:.now()+5),.success)}
        try await Task.sleep(nanoseconds:700_000_000)
        guard agent.isRunning else {throw XCTSkip("Local SNMP agent cannot bind under sandbox")}
        for (i,c) in combinations.enumerated() {
            let result:(Int32,String)=await withCheckedContinuation { continuation in
                SynologyMonitor.queue.async {
                    var values=[CAMetric](repeating:CAMetric(),count:2),error=[CChar](repeating:0,count:256)
                    if i == 0 {
                        // Same engine and username: each failed configuration must
                        // be followed by a successful correction in this process.
                        for (password,algorithm,cipher) in [("wrong-auth-123",0,0),("fixture-auth-123",1,0),("fixture-auth-123",0,1)] {
                            let failed=ca_snmp("127.0.0.1",Int32(port),3,"fixture0",password,"fixture-priv-123",1,Int32(algorithm),Int32(cipher),"1.3.6.1.2.1.1.6.0",0,&values,2,&error,256)
                            XCTAssertLessThan(failed,0)
                            let corrected=ca_snmp("127.0.0.1",Int32(port),3,"fixture0","fixture-auth-123","fixture-priv-123",1,0,0,"1.3.6.1.2.1.1.6.0",0,&values,2,&error,256)
                            XCTAssertEqual(corrected,1,String(cString:error))
                        }
                    }
                    ca_snmp_batch_begin_transport(i >= 6 ? 1:0)
                    defer {ca_snmp_batch_end()}
                    let logger=DiagnosticLog(directory:root.appendingPathComponent("diagnostics/\(i)"))
                    let trace=SNMPDiagnosticTrace(log:logger,operation:"v3-test",origin:"fixture",stage:"model",target:"target-1",oid:"1.3.6.1.2.1.1.6.0")
                    let n=ca_snmp_diagnostic("127.0.0.1",Int32(port),3,"fixture\(i)","fixture-auth-123",c.2 ? "fixture-priv-123":"",c.2 ? 1:0,c.0 == "MD5" ? 1:0,c.1 == "DES" ? 1:0,"1.3.6.1.2.1.1.6.0",0,&values,2,&error,256,{context,event,value,number,syserr in
                        guard let context,let event,let value else{return}
                        Unmanaged<SNMPDiagnosticTrace>.fromOpaque(context).takeUnretainedValue().receive(String(cString:event),String(cString:value),Int(number),Int(syserr))
                    },Unmanaged.passUnretained(trace).toOpaque())
                    let reused=ca_snmp_diagnostic("127.0.0.1",Int32(port),3,"fixture\(i)","fixture-auth-123",c.2 ? "fixture-priv-123":"",c.2 ? 1:0,c.0 == "MD5" ? 1:0,c.1 == "DES" ? 1:0,"1.3.6.1.2.1.1.6.0",0,&values,2,&error,256,{context,event,value,number,syserr in
                        guard let context,let event,let value else{return}
                        Unmanaged<SNMPDiagnosticTrace>.fromOpaque(context).takeUnretainedValue().receive(String(cString:event),String(cString:value),Int(number),Int(syserr))
                    },Unmanaged.passUnretained(trace).toOpaque())
                    XCTAssertEqual(reused,1,String(cString:error))
                    trace.finish(success:n >= 0)
                    continuation.resume(returning:(n,String(cString:error)))
                }
            }
            XCTAssertEqual(result.0,1,"\(c): \(result.1)")
        }
        // A responding agent rejecting an unknown user must differ from silence.
        let rejectedLog=DiagnosticLog(directory:root.appendingPathComponent("rejected"))
        var rejectedConfig=NASConfiguration();rejectedConfig.transport="UDP";rejectedConfig.host="127.0.0.1";rejectedConfig.port=port;rejectedConfig.user="absent-fixture-user"
        let rejected:NASSample=await withCheckedContinuation{continuation in
            SynologyMonitor.queue.async {continuation.resume(returning:SynologyMonitor.read(rejectedConfig,NASSecrets(auth:"fixture-auth-123"),origin:"connection_test",diagnosticLogger:rejectedLog))}
        }
        XCTAssertFalse(rejected.valid)
        let rejectedFile=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("rejected"),includingPropertiesForKeys:nil).first)
        let rejectedText=try String(contentsOf:rejectedFile,encoding:.utf8)
        let rejectedRows=try rejectedText.split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
        XCTAssertTrue(rejectedRows.contains{($0["code"] as? String)=="received_but_query_failed"})
        XCTAssertTrue(rejectedRows.contains{($0["event"] as? String)=="snmp_query_error" && ($0["native_value"] as? Int ?? 0)<0})
        XCTAssertFalse(rejectedText.contains("absent-fixture-user"))
        let directories=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("diagnostics"),includingPropertiesForKeys:nil)
        let logs=try directories.flatMap{try FileManager.default.contentsOfDirectory(at:$0,includingPropertiesForKeys:nil)}
        XCTAssertEqual(logs.count,12)
        for file in logs {
            let text=try String(contentsOf:file,encoding:.utf8)
            for secret in ["fixture-auth-123","fixture-priv-123","127.0.0.1","ColdArchiveFixture"] {XCTAssertFalse(text.contains(secret))}
            let rows=try text.split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
            let summary=try XCTUnwrap(rows.last)
            XCTAssertEqual(summary["send_count"] as? Int,3)
            XCTAssertEqual(summary["receive_count"] as? Int,3)
            XCTAssertTrue(rows.contains{($0["event"] as? String)=="snmp_engine_state" && ($0["native_value"] as? Int)==1})
        }
    }
    func testNativeSchedulerParallelCompletenessAndCancellation() async throws {
        guard Runtime.python != nil,FileManager.default.isExecutableFile(atPath:"/opt/homebrew/bin/exiftool") else {throw XCTSkip("Host integration needs ExifTool")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AdaptiveTest-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("input"),output=root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:false)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
        for n in 0..<12 {
            try Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:description=\"fixture-\(n)\"/></rdf:RDF></x:xmpmeta>".utf8).write(to:source.appendingPathComponent("\(n).xmp"))
        }
        let pressure=ReadingTestPressure()
        let scheduler=MetadataScheduler(windowDuration:0.5,pressureReader:{let critical=pressure.takeCritical();return (critical,critical,0.1)},workerOperation:{runner,arguments in
            // Long-file stand-in: keep real extraction/output, make overlap deterministic.
            try await Task.sleep(nanoseconds:2_000_000_000)
            return try await runMetadataProcess(runner,arguments:arguments)
        })
        try await scheduler.run(paths:[source.path],directory:output,adaptive:true,config:NASConfiguration(),secrets:NASSecrets(),progress:{pressure.observe($0)})
        let report=try JSONSerialization.jsonObject(with:Data(contentsOf:output.appendingPathComponent("metadata.json"))) as! [String:Any]
        let rows=report["files"] as! [[String:Any]]
        XCTAssertEqual(rows.count,12);XCTAssertEqual(Set(rows.compactMap{$0["path"] as? String}).count,12)
        let trace=try String(contentsOf:output.appendingPathComponent("scheduling.jsonl"),encoding:.utf8)
        let events=try trace.split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
        XCTAssertTrue(events.contains{($0["event"] as? String)=="start" && ($0["active"] as? Int ?? 0)>1},"Actual parallel processes, not just target changes")
        XCTAssertTrue(events.contains {($0["event"] as? String)=="adjust" && ($0["code"] as? String)=="critical_resource_pressure"},"Exercise real scheduler reduction with readers in flight")
        let starts=events.filter{($0["event"] as? String)=="start"}.compactMap{$0["id"] as? Int}
        let finishes=events.filter{($0["event"] as? String)=="finish"}.compactMap{$0["id"] as? Int}
        XCTAssertEqual(starts.count,12);XCTAssertEqual(finishes.count,12)
        XCTAssertEqual(Set(starts),Set(finishes),"Every launched file completes despite lower concurrency")
        XCTAssertTrue(events.filter{($0["event"] as? String)=="worker_exit"}.allSatisfy{($0["exit_code"] as? Int)==0})
        let customOutput=root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at:customOutput,withIntermediateDirectories:false)
        let custom=MetadataScheduler(pressureReader:{(false,false,0)},workerOperation:{runner,arguments in
            try await Task.sleep(nanoseconds:300_000_000)
            return try await runMetadataProcess(runner,arguments:arguments)
        })
        try await custom.run(paths:[source.path],directory:customOutput,adaptive:false,customLimit:3,config:NASConfiguration(),secrets:NASSecrets(),progress:{_ in})
        let customEvents=try String(contentsOf:customOutput.appendingPathComponent("scheduling.jsonl"),encoding:.utf8).split(separator:"\n").map {try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
        XCTAssertEqual(customEvents.filter {($0["event"] as? String)=="start"}.compactMap {$0["active"] as? Int}.max(),3)
        XCTAssertEqual(customEvents.filter {($0["event"] as? String)=="finish"}.count,12)
        let cancelOutput=root.appendingPathComponent("cancel")
        try FileManager.default.createDirectory(at:cancelOutput,withIntermediateDirectories:false)
        let cancelled=MetadataScheduler()
        let job=Task {try await cancelled.run(paths:[source.path],directory:cancelOutput,adaptive:true,config:NASConfiguration(),secrets:NASSecrets(),progress:{_ in})}
        try await Task.sleep(nanoseconds:800_000_000);await cancelled.cancel()
        do {try await job.value;XCTFail("Cancellation must not publish success")} catch is CancellationError {} catch {XCTFail("Unexpected: \(error)")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:cancelOutput.appendingPathComponent("metadata.json").path))
    }
}

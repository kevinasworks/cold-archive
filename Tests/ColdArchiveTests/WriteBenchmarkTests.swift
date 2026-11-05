// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Darwin
@testable import ColdArchive
final class WriteBenchmarkTests:XCTestCase {
    func testRealWritesFixedVersusSmart() async throws {
        guard ProcessInfo.processInfo.environment["COLD_ARCHIVE_RUN_WRITE_BENCHMARK"] == "1" else {throw XCTSkip("Opt-in real write benchmark")}
        guard let python=Runtime.python else {throw XCTSkip("Python runtime unavailable")}
        let base=ProcessInfo.processInfo.environment["COLD_ARCHIVE_WRITE_BENCHMARK_ROOT"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory
        let root=base.appendingPathComponent(".coldarchive-writebench-\(UUID())")
        guard mkdir(root.path,0o700)==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        defer {
            do {try FileManager.default.removeItem(at:root)} catch {XCTFail("Owned fixture cleanup failed")}
            try? WriteBudget.configure(.load())
        }
        let jobs=Int(ProcessInfo.processInfo.environment["COLD_ARCHIVE_WRITE_JOBS"] ?? "384") ?? 384
        let chunks=Int(ProcessInfo.processInfo.environment["COLD_ARCHIVE_WRITE_CHUNKS"] ?? "32") ?? 32
        let delay=ProcessInfo.processInfo.environment["COLD_ARCHIVE_WRITE_DELAY"] ?? "0.05"
        let modes=(ProcessInfo.processInfo.environment["COLD_ARCHIVE_WRITE_MODES"] ?? "8,16,0").split(separator:",").compactMap{Int($0)}
        let devices=Int(ProcessInfo.processInfo.environment["COLD_ARCHIVE_WRITE_DEVICES"] ?? "1") ?? 1
        var results:[[String:Any]]=[]
        var batchFingerprint:String?
        for mode in modes {
            try WriteBudget.configure(.init(readMode:"custom",writeMode:mode==0 ? "smart":"custom",readers:64,writers:mode==0 ? 5:mode))
            let folder=root.appendingPathComponent("run-\(mode)")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            let process=Process();process.executableURL=python
            process.arguments=[FileManager.default.currentDirectoryPath+"/scripts/write_workload.py",folder.path,String(jobs),delay,"16",String(devices),String(chunks)]
            var env=Runtime.environment
            env["PYTHONPATH"]=Runtime.engine.path
            env["COLD_ARCHIVE_WRITE_NOCACHE"]=ProcessInfo.processInfo.environment["COLD_ARCHIVE_WRITE_NOCACHE"]
            env["COLD_ARCHIVE_WRITE_RANDOM"]=ProcessInfo.processInfo.environment["COLD_ARCHIVE_WRITE_RANDOM"]
            env["COLD_ARCHIVE_WRITE_BUDGET"]=try WriteBudget.directory.get().path
            process.environment=env
            let output=Pipe();process.standardOutput=output;process.standardError=output
            var verifier=LogicalWriteMeter()
            _=verifier.sample(root:try WriteBudget.directory.get())
            let started=ProcessInfo.processInfo.systemUptime
            try process.run()
            var peak=0,peakTargets:[String:Int]=[:]
            var timeline:[[String:Any]]=[],previousAllocations:[String:Int]=[:]
            let budget=try WriteBudget.directory.get()
            let deadline=started+240
            while process.isRunning,ProcessInfo.processInfo.systemUptime<deadline {
                let snapshot=PermitPool.snapshot(budget)
                peak=max(peak,snapshot.active)
                let policy=try WriteAdmissionPolicy.load(budget)
                for (domain,limit) in policy.domain_limits {peakTargets[domain]=max(peakTargets[domain] ?? 0,limit)}
                if policy.domain_limits != previousAllocations {
                    timeline.append(["seconds":ProcessInfo.processInfo.systemUptime-started,"allocations":policy.domain_limits,"active":snapshot.active,"waiting":snapshot.waiting])
                    previousAllocations=policy.domain_limits
                }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            if process.isRunning {process.terminate()}
            process.waitUntilExit()
            let elapsed=ProcessInfo.processInfo.systemUptime-started
            let text=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
            XCTAssertEqual(process.terminationStatus,0,text)
            let result=text.split(separator:"\n").last.flatMap{try? JSONSerialization.jsonObject(with:Data($0.utf8))} as? [String:Any]
            XCTAssertEqual(result?["completed"] as? Int,jobs,text)
            XCTAssertEqual(result?["integrity"] as? String,"passed",text)
            let fingerprint=try XCTUnwrap(result?["batch_fingerprint"] as? String)
            if let previous=batchFingerprint {XCTAssertEqual(fingerprint,previous,"Every mode processes exactly the same bytes")}
            batchFingerprint=fingerprint
            XCTAssertLessThanOrEqual(peak,mode==0 ? 64:mode)
            let measured=verifier.sample(root:budget)
            XCTAssertEqual(measured.bytes,UInt64(jobs*chunks*65536),"Count actual successful writes, not fixture file size")
            let row:[String:Any]=["mode":mode==0 ? "smart":"fixed-\(mode)","seconds":elapsed,"peak_active":peak,
                "domain_peak_allocations":peakTargets,"allocation_timeline":timeline,"completed":jobs,"devices":devices,"logical_bytes":jobs*chunks*65536,"observed_logical_bytes":measured.bytes,"batch_fingerprint":fingerprint,"client_cache_control":result?["client_cache_control"] as? String ?? "unknown"]
            results.append(row)
            print("WRITE_BENCHMARK "+String(decoding:try JSONSerialization.data(withJSONObject:row,options:.sortedKeys),as:UTF8.self))
        }
        if let path=ProcessInfo.processInfo.environment["COLD_ARCHIVE_WRITE_BENCHMARK_REPORT"] {
            try JSONSerialization.data(withJSONObject:["scenario":"bounded_reused_files","chunk_count":chunks,"delay_seconds":Double(delay) ?? 0,"storage_class":(try? base.resourceValues(forKeys:[.volumeIsLocalKey]).volumeIsLocal).map{$0 ? "local":"remote"} ?? "unknown","results":results],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path),options:.atomic)
        }
    }
}

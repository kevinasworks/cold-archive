// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive

/// Opt-in, real local subprocess benchmark. It measures this machine and fixture,
/// never infers SMB/network/NAS throughput from the fixture's total file size.
final class SchedulerBenchmarkTests:XCTestCase {
    func testLocalMetadataFixedVersusSmart() async throws {
        guard ProcessInfo.processInfo.environment["COLD_ARCHIVE_RUN_BENCHMARK"] == "1" else {throw XCTSkip("Opt-in real metadata benchmark")}
        guard Runtime.python != nil else {throw XCTSkip("Python runtime unavailable")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ColdArchive-Benchmark-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root);try? WriteBudget.configure(.load())}
        let input=root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at:input,withIntermediateDirectories:false)
        let count=Int(ProcessInfo.processInfo.environment["COLD_ARCHIVE_BENCHMARK_FILES"] ?? "96") ?? 96
        for index in 0..<count {
            let text="<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:description=\"\(String(repeating:"fixture",count:index%4 == 0 ? 3000:8))\"/></rdf:RDF></x:xmpmeta>"
            try Data(text.utf8).write(to:input.appendingPathComponent("\(index).xmp"))
        }
        var results:[[String:Any]]=[]
        let modes=(ProcessInfo.processInfo.environment["COLD_ARCHIVE_BENCHMARK_MODES"] ?? "1,4,8,0").split(separator:",").compactMap{Int($0)}
        for limit in modes {
            try WriteBudget.configure(.init(readMode:limit==0 ? "smart":"custom",writeMode:"custom",readers:max(1,limit),writers:5))
            let output=root.appendingPathComponent("run-\(limit)")
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
            let scheduler=MetadataScheduler()
            let started=ProcessInfo.processInfo.systemUptime
            try await scheduler.run(paths:[input.path],directory:output,adaptive:limit==0,customLimit:max(1,limit),config:NASConfiguration(),secrets:NASSecrets(),progress:{_ in})
            let elapsed=ProcessInfo.processInfo.systemUptime-started
            let data=try Data(contentsOf:output.appendingPathComponent("metadata.json"))
            let report=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let files=report["files"] as! [[String:Any]]
            XCTAssertEqual(files.count,count)
            XCTAssertEqual(Set(files.compactMap{$0["path"] as? String}).count,count)
            let trace=try String(contentsOf:output.appendingPathComponent("scheduling.jsonl"))
            let events=try trace.split(separator:"\n").map {try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
            let starts=events.filter{($0["event"] as? String)=="start"}
            let finishes=events.filter{($0["event"] as? String)=="finish"}
            XCTAssertEqual(starts.count,count);XCTAssertEqual(finishes.count,count)
            let peak=starts.compactMap{$0["active"] as? Int}.max() ?? 0
            let changes=events.filter{($0["event"] as? String)=="adjust"}
            let result:[String:Any]=["mode":limit==0 ? "smart":"fixed-\(limit)","seconds":elapsed,"files":files.count,
                "peak_active":peak,"adjustments":changes.count,
                "peak_open_fds":events.compactMap{$0["file_descriptors_open"] as? Int}.max() ?? 0,
                "peak_observed_footprint":events.compactMap{$0["footprint_bytes"] as? UInt64}.max() ?? 0,
                "reasons":changes.compactMap{$0["code"] as? String}]
            results.append(result)
            print("BENCHMARK "+String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
        }
        if let path=ProcessInfo.processInfo.environment["COLD_ARCHIVE_BENCHMARK_REPORT"] {
            try JSONSerialization.data(withJSONObject:["scenario":"local_mixed_xmp","file_count":count,"results":results],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path),options:.atomic)
        }
    }
}

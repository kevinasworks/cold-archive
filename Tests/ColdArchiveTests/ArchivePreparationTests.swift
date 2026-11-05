// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
private final class PreparationHolders:@unchecked Sendable {
    private let lock=NSLock()
    private var values:[PermitPool.Lease]
    init(_ values:[PermitPool.Lease]) {self.values=values}
    func release() {lock.lock();values=[];lock.unlock()}
}
final class ArchivePreparationTests:XCTestCase {
    @MainActor func testPermitWaitDoesNotFreezeUIAndEvidenceIsComplete() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        let report=root.appendingPathComponent("evidence.json")
        let text="{\"evidence\":\""+String(repeating:"中A1",count:100000)+"\"}"
        try Data(text.utf8).write(to:report)
        let temporary=try WriteBudget.directory.get().appendingPathComponent("temporary")
        let count=Int(try String(contentsOf:temporary.appendingPathComponent("limit")))!
        let holders=try PreparationHolders((0..<count).map{_ in try XCTUnwrap(PermitPool.acquire(temporary,wait:false))})
        DispatchQueue.global().asyncAfter(deadline:.now()+0.6) {holders.release()}
        let workspace=root.appendingPathComponent("workspace")
        let operation=Task {try await ArchivePreparation.write(workspace:workspace,answers:Data("{}".utf8),report:report,zh:"中文\n",en:"English\n")}
        let began=ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-began,0.3,"MainActor must remain responsive while background I/O waits for permits")
        holders.release()
        try await operation.value
        let details=try JSONSerialization.jsonObject(with:Data(contentsOf:workspace.appendingPathComponent("details.json"))) as! [String:[String:String]]
        XCTAssertEqual(details["metadata_evidence"]?["zh"],"中文\n"+text)
        XCTAssertEqual(details["metadata_evidence"]?["en"],"English\n"+text)
        try await ArchivePreparation.remove(workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath:workspace.path))
    }
}

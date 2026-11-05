// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Darwin
import NativeMonitor
@testable import ColdArchive

final class IOBudgetCoordinatorTests:XCTestCase {
    func testNativeDescriptorCounterMeasuresOpenFiles() throws {
        let before=ca_process_fd_count(getpid())
        XCTAssertGreaterThan(before,0)
        var files:[Int32]=[]
        defer {for file in files {close(file)}}
        for _ in 0..<16 {let fd=open("/dev/null",O_RDONLY|O_CLOEXEC);XCTAssertGreaterThanOrEqual(fd,0);files.append(fd)}
        XCTAssertGreaterThanOrEqual(ca_process_fd_count(getpid()),before+8)
    }
    func testMeasuredDescriptorBudgetDoesNotUseFixedDivisionBy16() throws {
        let c=IOBudgetCoordinator(memoryBudget:1024*1024*1024*1024)
        var files:[Int32]=[]
        defer {for file in files {close(file)}}
        for _ in 0..<24 {let fd=open("/dev/null",O_RDONLY|O_CLOEXEC);XCTAssertGreaterThanOrEqual(fd,0);files.append(fd)}
        c.changeNativePermits(.read,by:8)
        let evidence=c.evidence(for:.read)
        XCTAssertGreaterThan(evidence.openDescriptors,24)
        XCTAssertEqual(evidence.estimatedDescriptorsPerTask,3)
        if evidence.descriptorLimit==256 && evidence.openDescriptors<56 {XCTAssertEqual(evidence.ceiling,64)}
        XCTAssertGreaterThan(evidence.ceiling,16)
    }
    func testSafetyBudgetExplainsMemoryAndDescriptorLimits() {
        let memory=IOBudgetCoordinator(memoryBudget:1000,descriptorCeiling:64)
        memory.updateFootprint(owner:"worker",bytes:100,active:4)
        let evidence=memory.evidence(for:.read)
        XCTAssertEqual(evidence.ceiling,10)
        XCTAssertEqual(evidence.reason,"memory_budget")
        XCTAssertEqual(evidence.estimatedMemory,400)
        let descriptors=IOBudgetCoordinator(memoryBudget:1000000,descriptorCeiling:8)
        XCTAssertEqual(descriptors.evidence(for:.read).reason,"file_descriptor_budget")
        XCTAssertEqual(descriptors.ceiling,8)
    }
    func testOnlyConfirmedAliasesShareANASAndConfigurationChangesInvalidateThem() {
        let c=IOBudgetCoordinator()
        var config=NASConfiguration();config.host="nas.example";config.port=161
        c.registerNAS(domain:"remote:192.0.2.1",configuration:config)
        c.registerNAS(domain:"remote:nas.example",configuration:config)
        XCTAssertEqual(c.canonicalDomain("remote:192.0.2.1",current:config),c.canonicalDomain("remote:nas.example",current:config))
        XCTAssertEqual(c.canonicalDomain("remote:192.0.2.2",current:config),"remote:192.0.2.2")
        config.host="other.example"
        XCTAssertEqual(c.canonicalDomain("remote:192.0.2.1",current:config),"remote:192.0.2.1")
    }
    func testReadAndWriteMemoryShareOneBudgetAndArchivePIDIsNotCountedTwice() {
        let c=IOBudgetCoordinator(memoryBudget:1000,descriptorCeiling:64)
        c.updateFootprint(owner:"read",bytes:100,active:4,lane:.read)
        c.updateFootprint(owner:"write",bytes:200,lane:.write,pid:42)
        XCTAssertEqual(c.ceiling(for:.read),8)
        XCTAssertEqual(c.ceiling(for:.write),3)
        c.updateFootprint(owner:"archive",bytes:200,lane:.auxiliary,pid:42)
        c.updateFootprint(owner:"write",bytes:200,lane:.write,pid:42)
        XCTAssertEqual(c.ceiling(for:.read),8,"One process observed through two paths is counted once")
        c.updateFootprint(owner:"read",bytes:100,active:8,lane:.read)
        XCTAssertEqual(c.ceiling(for:.read),8)
        XCTAssertEqual(c.ceiling(for:.write),1)
        c.release(owner:"archive")
        XCTAssertEqual(c.ceiling(for:.read),10)
    }
    func testStorageProbeIsSharedByReadsAndWritesButNotOtherDevices() {
        let c=IOBudgetCoordinator()
        XCTAssertTrue(c.claimProbe(domain:"nas-A",owner:"read",seconds:20,now:10))
        XCTAssertFalse(c.claimProbe(domain:"nas-A",owner:"write",seconds:20,now:11))
        XCTAssertTrue(c.claimProbe(domain:"nas-B",owner:"write",seconds:20,now:11))
        XCTAssertTrue(c.canProbe(domain:"nas-A",owner:"write",now:31))
        c.release(owner:"read")
        XCTAssertTrue(c.claimProbe(domain:"nas-A",owner:"write",seconds:20,now:12))
    }
    func testGlobalReadPermitsAndPythonWriterShareTheNativeProtocol() throws {
        guard let python=Runtime.python else {throw XCTSkip("Python runtime unavailable")}
        try WriteBudget.configure(.init(readMode:"custom",writeMode:"custom",readers:1,writers:1))
        defer {try? WriteBudget.configure(.load())}
        var read=try WriteBudget.reading(domain:"fixture")
        XCTAssertNotNil(read)
        XCTAssertNil(try WriteBudget.reading(domain:"another-job"),"Separate jobs share one actual read cap")
        read=nil
        let again=try WriteBudget.reading(domain:"another-job")
        XCTAssertNotNil(again)
        withExtendedLifetime(again) {}
        let root=try WriteBudget.directory.get()
        let entered=expectation(description:"Native writer overlaps Python waiter")
        let process=Process();process.executableURL=python
        process.arguments=["-B","-c","import write_budget;\nwith write_budget.writing(): print('acquired',flush=True)"]
        var env=Runtime.environment
        env["PYTHONPATH"]=Runtime.engine.path
        env["COLD_ARCHIVE_WRITE_BUDGET"]=root.path
        process.environment=env
        let output=Pipe();process.standardOutput=output;process.standardError=output
        try WriteBudget.native {
            try process.run()
            let deadline=Date().addingTimeInterval(3)
            while Date()<deadline {
                let snapshot=PermitPool.snapshot(root)
                if snapshot.active==1 && snapshot.waiting==1 {entered.fulfill();break}
                Thread.sleep(forTimeInterval:0.01)
            }
            XCTAssertTrue(process.isRunning,"Python must wait for native writer's permit")
        }
        wait(for:[entered],timeout:0.1)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        XCTAssertTrue(String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).contains("acquired"))
        XCTAssertEqual(PermitPool.snapshot(root).active,0)
        XCTAssertEqual(PermitPool.snapshot(root).waiting,0)
    }
}

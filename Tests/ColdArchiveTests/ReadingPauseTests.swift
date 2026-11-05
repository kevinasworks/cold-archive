// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
private final class SnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ReadingProgress()
    func set(_ value: ReadingProgress) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> ReadingProgress { lock.lock(); defer { lock.unlock() }; return value }
}
private actor WorkerGate {
    private var released=Set<String>()
    private var open=false
    func wait(_ path:String) async {
        while !open && !released.contains(path) {
            try? await Task.sleep(nanoseconds:10_000_000)
        }
    }
    func release(_ paths:[String]) {released.formUnion(paths)}
    func releaseAll() {open=true}
}
final class ReadingPauseTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }
    func testPauseDrainsActiveFileThenResumePreservesEveryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pause-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<3).map { root.appendingPathComponent("\($0).txt") }
        for path in paths { try Data("sample".utf8).write(to: path) }
        let output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = SnapshotStore()
        let scheduler = MetadataScheduler(pressureReader: { (false, false, 0) }, workerOperation: { runner, args in
            try await Task.sleep(nanoseconds: 500_000_000)
            return try await runMetadataProcess(runner, arguments: args)
        })
        let work = Task { try await scheduler.run(paths: paths.map(\.path), directory: output, adaptive: false, customLimit: 1, config: NASConfiguration(), secrets: NASSecrets(), fileProgress: { store.set($0) }, progress: { _ in }) }
        try await wait { store.get().active == 1 }
        await scheduler.setPaused(true)
        try await wait { store.get().paused && store.get().active == 0 }
        XCTAssertEqual(store.get().completed, 1)
        XCTAssertEqual(store.get().files.filter { $0.state == .pending }.count, 2)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(store.get().completed, 1)
        await scheduler.setPaused(false)
        try await work.value
        XCTAssertEqual(store.get().completed, 3)
        XCTAssertEqual(Set(store.get().files.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }), Set(paths.map { $0.resolvingSymlinksInPath().path }))
        let cancelled = MetadataScheduler()
        let cancelledOutput = root.appendingPathComponent("cancelled")
        try FileManager.default.createDirectory(at: cancelledOutput, withIntermediateDirectories: true)
        await cancelled.setPaused(true)
        let store2 = SnapshotStore()
        let cancellation = Task { try await cancelled.run(paths: paths.map(\.path), directory: cancelledOutput, adaptive: false, config: NASConfiguration(), secrets: NASSecrets(), fileProgress: { store2.set($0) }, progress: { _ in }) }
        try await wait { store2.get().paused }
        await cancelled.cancel()
        do { try await cancellation.value; XCTFail("Expected cancellation") } catch is CancellationError {} 
    }
    func testSavedSettingsChangeRunningReaderAdmission() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        let suite="ColdArchive.LiveSettings."+UUID().uuidString
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {
            defaults.removePersistentDomain(forName:suite)
            try? WriteBudget.configure(.load())
            try? FileManager.default.removeItem(at:root)
        }
        let paths=(0..<8).map{root.appendingPathComponent("\($0).txt")}
        for path in paths {try Data("fixture".utf8).write(to:path)}
        let output=root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
        var settings=ConcurrencySettings(readMode:"custom",writeMode:"custom",readers:1,writers:2)
        try settings.save(defaults)
        let gate=WorkerGate()
        let snapshots=SnapshotStore()
        let scheduler=MetadataScheduler(pressureReader:{(false,false,0)},workerOperation:{runner,args in
            await gate.wait(args[1])
            return try await runMetadataProcess(runner,arguments:args)
        })
        let work=Task {
            try await scheduler.run(paths:paths.map(\.path),directory:output,adaptive:false,
                                    followsLiveSettings:true,config:NASConfiguration(),secrets:NASSecrets(),
                                    fileProgress:{snapshots.set($0)},progress:{_ in})
        }
        do {
            try await wait {snapshots.get().active==1}
            settings.readers=3
            try settings.save(defaults)
            try await wait {snapshots.get().active==3}
            XCTAssertEqual(snapshots.get().completed,0)

            settings.readers=1
            try settings.save(defaults)
            let active=snapshots.get().files.filter{$0.state == .reading}
            await gate.release(Array(active.prefix(2)).map(\.path))
            try await wait {snapshots.get().completed==2}
            XCTAssertEqual(snapshots.get().active,1)
            XCTAssertEqual(snapshots.get().files.filter{$0.state == .pending}.count,5)

            settings.readMode="smart"
            try settings.save(defaults)
            try await wait {snapshots.get().active>=2}
            settings.readMode="custom"
            try settings.save(defaults)
            XCTAssertEqual(ConcurrencySettings.load(defaults),settings)
            await gate.releaseAll()
            try await work.value
            XCTAssertEqual(snapshots.get().completed,paths.count)
        } catch {
            await scheduler.cancel()
            await gate.releaseAll()
            _=try? await work.value
            throw error
        }
    }

}

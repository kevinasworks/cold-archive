// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var paused=false
    private var stage="startup"
    private let operation=UUID().uuidString
    func activity() -> ProcessActivity? {
        lock.lock()
        let pid = process.flatMap { $0.isRunning ? $0.processIdentifier : nil }
        lock.unlock()
        return pid.map { ProcessActivity.sample(pid:$0) }
    }
    private let pauseURL = FileManager.default.temporaryDirectory.appendingPathComponent("archive-pause-\(UUID())")
    func setPaused(_ paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.paused=paused
        if paused { FileManager.default.createFile(atPath: pauseURL.path, contents: Data()) }
        else { try? FileManager.default.removeItem(at: pauseURL) }
    }
    deinit { try? FileManager.default.removeItem(at: pauseURL) }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        try? FileManager.default.removeItem(at: pauseURL)
        if let process, process.isRunning { process.terminate() }
    }
    func run(script: String, arguments: [String], onLine: @escaping @Sendable (String) -> Void) throws -> RunOutcome {
        lock.lock();let alreadyCancelled=cancelled;lock.unlock()
        if alreadyCancelled {return RunOutcome(status:130,output:"DESKTOP_RESULT {\"state\":\"cancelled\"}\n")}
        guard let python = Runtime.python else { throw AppError.message("应用运行时缺失，请使用完整应用包。") }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-B", "-u", Runtime.engine.appendingPathComponent(script).path] + arguments
        var environment = Runtime.environment
        environment["COLD_ARCHIVE_WRITE_BUDGET"] = try WriteBudget.directory.get().path
        if let device=WriteBudget.localTemporaryDevice {environment["COLD_ARCHIVE_LOCAL_TEMP_DEVICE"]=String(device)}
        environment["COLD_ARCHIVE_PAUSE_FILE"] = pauseURL.path
        environment["COLD_ARCHIVE_IO_DIAGNOSTICS"]="1"
        let mounts=mountedSources()
        let mapping=mounts.map {[$0.path,IOBudgetCoordinator.storageKey(path:$0.path,mounts:mounts)]}
        if let data=try? JSONSerialization.data(withJSONObject:mapping) {environment["COLD_ARCHIVE_STORAGE_DOMAINS"]=String(decoding:data,as:UTF8.self)}
        if let index=arguments.firstIndex(of:"--output-dir"),arguments.indices.contains(index+1) {
            environment["COLD_ARCHIVE_WRITE_DOMAIN"]=IOBudgetCoordinator.storageKey(path:arguments[index+1],mounts:mounts)
        }
        var nasMonitoring:ArchiveNASMonitoring?
        if script == "desktop_bridge.py" {
            let config=NASConfiguration.load()
            let paths=arguments.filter{$0.hasPrefix("/")}
            let used=mounts.filter {mount in !mount.local && paths.contains {path in path==mount.path || path.hasPrefix(mount.path+"/")}}
            if config.enabled,!used.isEmpty,let secrets=try? NASKeychain.load() {
                nasMonitoring=ArchiveNASMonitoring(config:config,secrets:secrets,mounts:used)
            }
        }
        defer {withExtendedLifetime(nasMonitoring) {}}
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); return RunOutcome(status: 130, output: "DESKTOP_RESULT {\"state\":\"cancelled\"}\n") }
        self.process = process
        do { try process.run() } catch { self.process = nil; lock.unlock(); throw error }
        lock.unlock()
        let monitorQueue=DispatchQueue(label:"ColdArchive.ProcessObservation",qos:.utility)
        var activityDelta=ProcessActivityDelta()
        var sampledAt=ProcessInfo.processInfo.systemUptime
        let monitor=DispatchSource.makeTimerSource(queue:monitorQueue)
        if script == "desktop_bridge.py" {
            monitor.schedule(deadline:.now()+1,repeating:1)
            monitor.setEventHandler { [weak self] in
                guard let self,let sample=self.activity() else {return}
                let delta=activityDelta.observe(sample)
                IOBudgetCoordinator.shared.updateFootprint(owner:self.operation,bytes:delta.footprint,lane:.auxiliary,pid:process.processIdentifier)
                let now=ProcessInfo.processInfo.systemUptime
                self.lock.lock();let stage=self.stage,paused=self.paused;self.lock.unlock()
                DiagnosticLog.shared.write(["event":"archive_process_activity","operation":self.operation,
                    "stage":stage,"metric_source":"kernel_process_tree","disk_read_bytes":delta.readBytes,
                    "disk_write_bytes":delta.writeBytes,"cpu_nanoseconds":delta.cpuNanoseconds,
                    "footprint_bytes":delta.footprint,"window_seconds":now-sampledAt,
                    "measurement_complete":delta.complete && !paused,"paused":paused])
                sampledAt=now
            }
        }
        monitor.resume()
        defer {monitor.cancel();monitorQueue.sync {};IOBudgetCoordinator.shared.release(owner:operation)}
        var pending = Data()
        var output = ""
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                if line.hasPrefix("IO_SAMPLE "),
                   let data=line.dropFirst(10).data(using:.utf8),
                   let fields=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                    DiagnosticLog.shared.write(fields.merging(["operation":operation,"phase":stage]) {_,new in new})
                    continue
                }
                if line.hasPrefix("PHASE "),let phase=line.split(separator:" ").dropFirst().first,Int(phase) != nil {
                    lock.lock();stage="phase_"+String(phase);lock.unlock()
                }
                output += line + "\n"
                // Keep diagnostics bounded; completion markers are always at the end.
                if output.utf8.count > 2_000_000 { output = String(output.suffix(1_000_000)) }
                onLine(line)
            }
        }
        if !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            output += line; onLine(line)
        }
        process.waitUntilExit()
        lock.lock(); self.process = nil; let wasCancelled = cancelled; lock.unlock()
        // Before desktop_bridge installs its SIGTERM handler, Python only imports
        // modules: no archive workspace or child tools exist yet. Once installed,
        // the bridge catches SIGTERM and emits its own cleanup result instead.
        if wasCancelled, script == "desktop_bridge.py",
           process.terminationReason == .uncaughtSignal, process.terminationStatus == 15 {
            return RunOutcome(status: 130, output: output + "\nDESKTOP_RESULT {\"state\":\"cancelled\"}\n")
        }
        return RunOutcome(status: process.terminationStatus, output: output)
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NativeMonitor
import DiskArbitration

/// Only blocking subprocess IO runs on this dedicated GCD queue, never on the
/// Swift cooperative executor or MainActor. Every worker has its own owner.
func runMetadataProcess(_ runner: ProcessRunner, arguments: [String]) async throws -> RunOutcome {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos:.utility).async {
            do { continuation.resume(returning:try runner.run(script:"inspect_source_metadata.py",arguments:arguments,onLine:{_ in})) }
            catch {continuation.resume(throwing:error)}
        }
    }
}
final class MacPressure: @unchecked Sendable {
    private let lock=NSLock()
    private var memoryLevel=0
    private var previous:(UInt64,UInt64,Double)?
    private var lastUsage=0.0
    private var highCPUSamples=0
    private let source=DispatchSource.makeMemoryPressureSource(eventMask:[.normal,.warning,.critical],queue:DispatchQueue(label:"ColdArchive.Pressure"))
    init() {
        source.setEventHandler {[weak self] in
            guard let self else{return}
            let event=self.source.data
            self.lock.lock();self.memoryLevel=event.contains(.critical) ? 2 : event.contains(.warning) ? 1:0;self.lock.unlock()
        };source.resume()
    }
    deinit {source.cancel()}
    func read() -> (pressure:Bool,critical:Bool,cpu:Double) {
        lock.lock();defer{lock.unlock()}
        var busy:UInt64=0,total:UInt64=0
        let now=ProcessInfo.processInfo.systemUptime
        if previous == nil || now-(previous?.2 ?? 0)>=1,ca_cpu(&busy,&total)==0 {
            if let p=previous,now-p.2<5,total>p.1,busy>=p.0 {
                lastUsage=Double(busy-p.0)/Double(total-p.1)
                highCPUSamples=lastUsage>0.95 ? highCPUSamples+1:0
            } else {lastUsage=0;highCPUSamples=0}
            previous=(busy,total,now)
        }
        let thermal=ProcessInfo.processInfo.thermalState
        return (memoryLevel>0 || thermal == .serious || thermal == .critical || highCPUSamples>=3,memoryLevel==2 || thermal == .critical,lastUsage)
    }
}
struct MetadataManifest: Decodable {let file_paths:[String];let file_sizes:[String:Int]?}
struct ScheduledFile {
    let index:Int;let path:String;let domain:String;let family:String;let nas:Bool
}
private struct DomainState {
    var control=ThroughputController()
    var diskBytes:UInt64=0
    var activityTicks=0
    var settled=true
    var cpuActivity:UInt64=0
    var completionsThisWindow=0
    var windowStart=ProcessInfo.processInfo.systemUptime
    var completionStart=ProcessInfo.processInfo.systemUptime
    var work=0.0;var samples=0
    var metric="normalized_completions"
    var emptyDiskWindows=0
    var lastEvaluation=ProcessInfo.processInfo.systemUptime
    var baselines:[String:[Double]]=[:]
    var nas=false
    var nasEvidence=NASPressureEvidence()
}
actor MetadataScheduler {
    private var cancelled=false
    private var paused=false
    func setPaused(_ value: Bool) {
        if paused && !value {
            let now=ProcessInfo.processInfo.systemUptime
            for key in Array(domains.keys) {domains[key]!.windowStart=now;domains[key]!.lastEvaluation=now;domains[key]!.work=0;domains[key]!.samples=0;domains[key]!.completionStart=now;domains[key]!.diskBytes=0;domains[key]!.activityTicks=0;domains[key]!.cpuActivity=0;domains[key]!.completionsThisWindow=0;domains[key]!.settled=true;domains[key]!.control.resetMeasurements()}
        }
        paused=value
    }
    private var active:[Int:ProcessRunner]=[:]
    private var permits:[Int:PermitPool.Lease]=[:]
    private var activityDeltas:[Int:ProcessActivityDelta]=[:]
    private var phaseRunner:ProcessRunner?
    private var completions:[(ScheduledFile,Double,Result<RunOutcome,Error>)]=[]
    private var domains:[String:DomainState]=[:]
    private var nasSample=NASSample()
    private var telemetryTask:Task<Void,Never>?
    private let pressure=MacPressure()
    private let testPressure: (@Sendable () -> (pressure:Bool,critical:Bool,cpu:Double))?
    private let workerOperation: @Sendable (ProcessRunner,[String]) async throws -> RunOutcome
    private let windowDuration: Double
    init(windowDuration: Double = 1, pressureReader: (@Sendable () -> (pressure:Bool,critical:Bool,cpu:Double))? = nil, workerOperation: @escaping @Sendable (ProcessRunner,[String]) async throws -> RunOutcome = {try await runMetadataProcess($0,arguments:$1)}) {
        self.windowDuration=windowDuration; self.testPressure=pressureReader;self.workerOperation=workerOperation
    }
    private let diagnosticOperation=UUID().uuidString
    private var audit:FileHandle?
    private var auditURL:URL?

    func cancel() {cancelled=true;paused=false;phaseRunner?.cancel();for runner in active.values {runner.cancel()}}
    private func completed(_ file:ScheduledFile,_ start:Double,_ result:Result<RunOutcome,Error>) {
        completions.append((file,ProcessInfo.processInfo.systemUptime-start,result))
    }
    private var configuration=NASConfiguration()
    private var receivedNAS=false
    private func acceptNAS(_ sample:NASSample) {
        nasSample=sample;receivedNAS=true
        for (key,domain) in domains where domain.nas {NASFeedback.shared.store(sample,domain:key,configuration:configuration)}
        var fields:[String:Any]=["event":"nas_sample","valid":sample.valid]
        for index in NASCPUDelta.fields {
            if let value=sample.values["1.3.6.1.4.1.2021.11.\(index).0"] {fields["cpu_counter_\(index)"]=value}
        }
        fields["code"]=sample.cpu != nil ? "cpu_interval_valid":NASCPUDelta.fields.allSatisfy{sample.values["1.3.6.1.4.1.2021.11.\($0).0"] != nil} ? "cpu_waiting_for_delta":"cpu_counters_missing"
        if let cpu=sample.cpu {fields["nas_cpu"]=cpu}
        if let wait=sample.cpuWait {fields["nas_iowait"]=wait}
        if let disk=sample.diskLoad {fields["disk_load"]=disk}
        if let latency=sample.readLatency {fields["latency"]=latency}
        record(fields)
    }
    private func record(_ event:[String:Any]) {
        guard let data=try? JSONSerialization.data(withJSONObject:DiagnosticLog.sanitized(event).merging(["time":ISO8601DateFormatter().string(from:Date())]) {old,_ in old},options:[.sortedKeys]) else{return}
        try? WriteBudget.native(kind:.temporary,destination:auditURL) { try? audit?.write(contentsOf:data+Data([10])) }
        DiagnosticLog.shared.write(event.merging(["operation":diagnosticOperation]) {_,new in new})
    }
    func run(paths:[String], directory:URL, adaptive initialAdaptive:Bool, customLimit:Int=1, followsLiveSettings:Bool=false, config:NASConfiguration, secrets:NASSecrets,
             fileProgress:@escaping @Sendable (ReadingProgress)->Void = { _ in },
             progress:@escaping @Sendable (String)->Void) async throws {
        configuration=config
        var readingOutcome="failed"
        let operation=diagnosticOperation
        var adaptive=initialAdaptive
        DiagnosticLog.shared.write(["event":"reading_begin","operation":operation,"max_readers":adaptive ? WriteBudget.maximumReaders:ConcurrencySettings.bounded(customLimit),"max_writers":WriteBudget.configuredLimit])
        defer {IOBudgetCoordinator.shared.release(owner:operation);permits.removeAll();DiagnosticLog.shared.write(["event":"reading_end","operation":operation,"outcome":cancelled ? "cancelled":readingOutcome])}
        let manifest=directory.appendingPathComponent("manifest.json")
        let runner=ProcessRunner();phaseRunner=runner
        let enumerated=try await runMetadataProcess(runner,arguments:paths+["--enumerate-only","--manifest",manifest.path])
        phaseRunner=nil
        guard !cancelled else {throw CancellationError()}
        guard enumerated.status==0 else {throw AppError.message(enumerated.output)}
        let list=try JSONDecoder().decode(MetadataManifest.self,from:Data(contentsOf:manifest))
        let workers=directory.appendingPathComponent("workers")
        try FileManager.default.createDirectory(at:workers,withIntermediateDirectories:false)
        let trace=directory.appendingPathComponent("scheduling.jsonl")
        FileManager.default.createFile(atPath:trace.path,contents:nil,attributes:[.posixPermissions:0o600])
        auditURL=trace
        audit=try FileHandle(forWritingTo:trace)
        defer {try? audit?.close();audit=nil;telemetryTask?.cancel();telemetryTask=nil}
        // Resolving volumes/file size can block on network mounts. Do it off actor.
        let sourceMounts=mountedSources()
        let hasRemoteSource=list.file_paths.contains { path in
            sourceMounts.first {path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path+"/")}?.local == false
        }
        var identitySample=NASSample()
        if config.enabled && hasRemoteSource {
            progress("正在核对文件来源与 NAS 网络接口…")
            identitySample=await SynologyMonitor().sample(config,secrets:secrets,origin:"identity_check",includeIdentity:true)
            acceptNAS(identitySample)
        }
        let nasInterfaces=identitySample.interfaceAddresses
        let files:[ScheduledFile]=try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.utility).async {
                let mounts=sourceMounts
                                var matchReasons:[String:String]=[:]
                let mapped=list.file_paths.enumerated().map { index,path -> ScheduledFile in
                    let url=URL(fileURLWithPath:path)
                    let volume=mounts.first {path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path+"/")}
                    let remote=volume?.local != true
                    let identity=volume?.identity ?? ""
                    if remote && config.enabled && matchReasons[identity]==nil {
                        let reason=NASAddressIdentity.match(volume?.identity,host:config.host,interfaces:nasInterfaces)
                        matchReasons[identity]=reason
                        DiagnosticLog.shared.write(["event":"nas_source_match","operation":operation,"code":reason])
                    }
                    let nas=remote && config.enabled && NASAddressIdentity.confirmed(matchReasons[identity] ?? "")
                    let rawDomain=IOBudgetCoordinator.storageKey(path:path,mounts:mounts)
                    if nas {IOBudgetCoordinator.shared.registerNAS(domain:rawDomain,configuration:config)}
                    let domain=IOBudgetCoordinator.shared.canonicalDomain(rawDomain,current:config)
                    let size=max(1,list.file_sizes?[path] ?? 1)
                    let bucket=Int(log2(Double(size))/4)
                    return ScheduledFile(index:index,path:path,domain:domain,family:"\(url.pathExtension.lowercased()):\(bucket)",nas:nas)
                }
                continuation.resume(returning:mapped)
            }
        }
        if cancelled {throw CancellationError()}
        for f in files {if domains[f.domain]==nil {var d=DomainState();d.control=ThroughputController(initial:max(2,min(4,ProcessInfo.processInfo.activeProcessorCount/2)),minimumWindow:windowDuration);d.nas=f.nas;domains[f.domain]=d}}
        record(["event":"nas_matching","enabled":config.enabled,"matchedFiles":files.filter{$0.nas}.count,"totalFiles":files.count,"protocol":config.version,"authentication":config.authProtocol ?? "SHA","privacyEnabled":config.privacy,"privacyProtocol":config.privacyProtocol ?? "AES"])
        if files.contains(where:{$0.nas}) {
            telemetryTask=Task { [weak self] in
                let monitor=SynologyMonitor()
                while !Task.isCancelled {
                    let sample=await monitor.sample(config,secrets:secrets)
                    if Task.isCancelled {break}
                    await self?.acceptNAS(sample)
                    try? await Task.sleep(nanoseconds:6_000_000_000)
                }
            }
        }
        let fileByID=Dictionary(uniqueKeysWithValues:files.map {($0.index,$0)})
        var fileStates=files.map { ReadingFile(id:$0.index,path:$0.path) }
        var lastSnapshot:ReadingProgress?
        var pending=files,finished=0
        var failure:Error?
        var lastTick=0.0
        var limit=adaptive ? ConcurrencySettings.bounded(WriteBudget.maximumReaders):ConcurrencySettings.bounded(customLimit)
        var requestedLimit=limit
        var appliedSettings:ConcurrencySettings?
        var peakWorkerFootprint:UInt64=0
        if !adaptive {for key in Array(domains.keys) {domains[key]!.control=ThroughputController(initial:limit,minimumWindow:windowDuration)}}
        while !pending.isEmpty || !active.isEmpty || (paused && !cancelled) {
            let now=ProcessInfo.processInfo.systemUptime
            for (file,duration,result) in completions {
                active.removeValue(forKey:file.index);permits.removeValue(forKey:file.index);finished += 1
                activityDeltas.removeValue(forKey:file.index)
                do {
                    let outcome=try result.get()
                    record(["event":"worker_exit","id":file.index,"exit_code":outcome.status])
                    if outcome.status != 0 && !cancelled {throw AppError.message("元数据读取工作进程未完成：\(URL(fileURLWithPath:file.path).lastPathComponent)（退出码 \(outcome.status)）")}
                    fileStates[file.index].state = cancelled ? .cancelled : .completed
                    var d=domains[file.domain]!
                    d.completionsThisWindow += 1
                    let baseline=d.baselines[file.family] ?? []
                    if !baseline.isEmpty {
                        d.work += baseline.sorted()[baseline.count/2]
                        d.samples += 1
                    }
                    if baseline.count<5 {d.baselines[file.family,default:[]].append(max(0.001,duration))}
                    domains[file.domain]=d
                } catch {fileStates[file.index].state = cancelled ? .cancelled : .failed;record(["event":"worker_error","id":file.index,"code":DiagnosticLog.category(error)]);if !cancelled {failure=error};cancel()}
                record(["event":"finish","id":file.index,"seconds":duration,"active":active.count])
            }
            completions.removeAll()
            if Task.isCancelled {cancel()}
            if cancelled {pending.removeAll()}
            if followsLiveSettings, let latest=WriteBudget.currentSettings, latest != appliedSettings {
                let readChanged=appliedSettings == nil || adaptive != latest.adaptive || requestedLimit != latest.readLimit
                appliedSettings=latest
                if readChanged {
                    adaptive=latest.adaptive
                    requestedLimit=latest.readLimit
                    limit=min(requestedLimit,IOBudgetCoordinator.shared.ceiling)
                    activityDeltas.removeAll()
                    for key in Array(domains.keys) {
                        var fresh=DomainState()
                        fresh.nas=domains[key]!.nas
                        let initial=adaptive ? max(2,min(4,ProcessInfo.processInfo.activeProcessorCount/2)):requestedLimit
                        fresh.control=ThroughputController(initial:initial,minimumWindow:windowDuration)
                        domains[key]=fresh
                    }
                    lastTick=0
                    record(["event":"read_settings_applied","code":latest.readMode,"configured_limit":requestedLimit,"active":active.count])
                }
            }
            let signals=testPressure?() ?? pressure.read()
            // Critical pressure is an admission event, not a throughput sample.
            // Handle it immediately so short events cannot disappear between windows.
            if adaptive && signals.critical && !paused {
                do {try WriteBudget.refreshReadCeiling()} catch {failure=error;cancel()}
                for key in Array(domains.keys) {
                    var d=domains[key]!
                    let running=active.keys.filter{fileByID[$0]?.domain==key}.count
                    let decision=d.control.observe(.init(rate:0,duration:0,active:running,
                        waiting:pending.filter{$0.domain==key}.count,ceiling:limit,
                        reliable:false,critical:true))
                    if decision.changed {
                        record(["event":"adjust","old":decision.previous,"target":decision.target,
                                "code":decision.reason,"active":running,"cpu":signals.cpu,
                                "nasFresh":nasSample.fresh])
                    }
                    domains[key]=d
                }
            }
            if !cancelled && !paused && !signals.critical {
                var position=0
                while position<pending.count && active.count<limit {
                    let file=pending[position],d=domains[file.domain]!
                    let running=active.keys.filter{fileByID[$0]?.domain==file.domain}.count
                    if running>=d.control.target {position += 1;continue}
                    do {
                        guard let permit=try WriteBudget.reading(domain:file.domain,expectedSettings:appliedSettings) else {position += 1;continue}
                        permits[file.index]=permit
                    } catch {failure=error;cancel();break}
                    pending.remove(at:position)
                    let runner=ProcessRunner();active[file.index]=runner
                    fileStates[file.index].state = .reading
                    let arguments=["--worker-file",file.path,"--output-json",workers.appendingPathComponent("\(file.index).json").path]
                    record(["event":"start","id":file.index,"active":active.count,"target":d.control.target,"target_ref":DiagnosticLog.shared.target(file.domain)])
                    Task {
                        let result:Result<RunOutcome,Error>
                        do {result = .success(try await workerOperation(runner,arguments))}
                        catch {result = .failure(error)}
                        self.completed(file,now,result)
                    }
                }
            }
            if now-lastTick>=1 {
                let activityInterval=lastTick>0 ? now-lastTick:0
                lastTick=now
                var diskRead:UInt64=0,diskWrite:UInt64=0,cpuTime:UInt64=0,footprint:UInt64=0
                var activityComplete = !active.isEmpty
                for (id,runner) in active {
                    guard let snapshot=runner.activity() else {activityComplete=false;continue}
                    var counter=activityDeltas[id] ?? ProcessActivityDelta()
                    let delta=counter.observe(snapshot);activityDeltas[id]=counter
                    diskRead += delta.readBytes;diskWrite += delta.writeBytes
                    cpuTime += delta.cpuNanoseconds;footprint += delta.footprint
                    peakWorkerFootprint=max(peakWorkerFootprint,delta.footprint)
                    activityComplete = activityComplete && delta.complete
                    if let key=fileByID[id]?.domain,delta.complete {
                        domains[key]!.diskBytes += delta.readBytes
                        domains[key]!.activityTicks += 1
                        domains[key]!.cpuActivity += delta.cpuNanoseconds
                    }
                }
                record(["event":"process_activity","stage":"metadata","metric_source":"kernel_process_tree",
                        "disk_read_bytes":diskRead,"disk_write_bytes":diskWrite,"cpu_nanoseconds":cpuTime,
                        "footprint_bytes":footprint,"measurement_complete":activityComplete,
                        "window_seconds":activityInterval,"active":active.count,"waiting":pending.count].merging(IOBudgetCoordinator.shared.evidence(for:.read).fields) {_,new in new})
                if adaptive,peakWorkerFootprint>0 {
                    // Reserve capacity for the UI, archive pipeline and OS.
                    // Use measured worker-tree footprint, not file size.
                    let memoryBudget=ProcessInfo.processInfo.physicalMemory/3
                    IOBudgetCoordinator.shared.updateFootprint(owner:operation,bytes:peakWorkerFootprint,active:active.count,lane:.read)
                    limit=min(IOBudgetCoordinator.shared.ceiling,max(1,min(WriteBudget.maximumReaders,Int(memoryBudget/peakWorkerFootprint))))
                }
                do {
                    let previousLimit=limit
                    limit=min(requestedLimit,try WriteBudget.refreshReadCeiling())
                    if previousLimit != limit {
                        record(["event":"resource_budget","code":limit<requestedLimit ? "resource_safety_guard":"resource_budget_recovered",
                                "configured_limit":requestedLimit,"ceiling":limit,"old":previousLimit,"active":active.count].merging(IOBudgetCoordinator.shared.evidence(for:.read).fields) {_,new in new})
                    }
                } catch {failure=error;cancel()}
                for key in Array(domains.keys) {
                    var d=domains[key]!
                    let running=active.keys.filter{fileByID[$0]?.domain==key}.count
                    if running<d.control.target {d.settled=false}
                    if adaptive && !paused && now-d.lastEvaluation>=windowDuration {
                        d.lastEvaluation=now
                        let evidence=d.nasEvidence.observe(d.nas ? nasSample:nil)
                        let nasPressure=evidence.congested
                        let nasHeadroom=evidence.headroom
                        let old=d.control.target
                        let pressured=signals.pressure || nasPressure
                        let waiting=pending.filter{$0.domain==key}.count
                        if d.diskBytes>0 && d.activityTicks>0 {d.metric="kernel_process_tree";d.emptyDiskWindows=0}
                        else {d.emptyDiskWindows += 1}
                        if d.emptyDiskWindows>=3 && d.samples>=3 {d.metric="normalized_completions"}
                        let useDisk=d.metric == "kernel_process_tree"
                        let metric=d.metric
                        let elapsed=now-(useDisk ? d.windowStart:d.completionStart)
                        let rate=useDisk ? Double(d.diskBytes)/max(0.001,elapsed):d.work/max(0.001,elapsed)
                        var candidate=d.control
                        let decision=candidate.observe(.init(rate:rate,duration:elapsed,active:running,
                            waiting:waiting,ceiling:limit,reliable:d.settled && (useDisk || d.samples>=3),
                            congested:pressured,critical:signals.critical,context:metric,
                            explorationPermitted:d.cpuActivity>0 || d.completionsThisWindow>0))
                        let coordinator=IOBudgetCoordinator.shared
                        let changesWork=decision.changed && !signals.critical && decision.reason != "safety_ceiling"
                        let allowed = !changesWork || coordinator.claimProbe(domain:key,owner:operation,seconds:windowDuration*8)
                        if allowed {d.control=candidate}
                        record(["event":"control_window","old":old,"target":d.control.target,"code":allowed ? decision.reason:"storage_probe_deferred",
                                "cpu":signals.cpu,"nasFresh":evidence.fresh,"nas_headroom":nasHeadroom,
                                "ceiling":limit,"baseline_rate":d.control.baseline ?? -1,"footprint_bytes":peakWorkerFootprint,
                                "nas_cpu":nasSample.cpu ?? -1,"disk_load":nasSample.diskLoad ?? -1,
                                "mac_pressure":signals.pressure,"nas_pressure":nasPressure,"samples":d.samples,
                                "nas_age_seconds":evidence.age ?? -1,"latency":evidence.latency ?? -1,"metric_source":metric,
                                "rate":rate,"window_seconds":elapsed,"active":running,"waiting":waiting])
                        if decision.changed && allowed {
                            record(["event":"adjust","old":old,"target":d.control.target,"code":decision.reason,"cpu":signals.cpu,"nasFresh":nasSample.fresh])
                        }
                        d.windowStart=now
                        // Sparse long-file completions may need several ticks to
                        // form one independent measurement. Never re-use a window.
                        if (decision.changed && allowed) || (!useDisk && d.samples>=3) {
                            d.work=0;d.samples=0;d.completionStart=now
                        }
                        d.diskBytes=0;d.activityTicks=0;d.settled=true;d.cpuActivity=0;d.completionsThisWindow=0
                    }
                    domains[key]=d
                }
                let targets=domains.values.reduce(0){$0+$1.control.target}
                let nasText:String
                if files.contains(where:{$0.nas}) {
                    nasText=" · "+nasSample.progressDescription(received:receivedNAS)
                } else if config.enabled && files.contains(where:{$0.domain.hasPrefix("remote:") && !$0.nas}) {
                    nasText=" · 未能通过 NAS 网卡地址确认 SMB 来源，使用 Mac 反馈（详见诊断日志）"
                } else {nasText=""}
                let safety=limit<requestedLimit ? " · 资源安全上限\(limit)（设置上限\(requestedLimit)）":""
                let settling=active.count>min(limit,targets) ? " · 现有任务继续读完，暂不补新任务":""
                progress("已完成 \(finished)/\(files.count) · 正在读取 \(active.count) 个 · 并发目标 \(min(limit,targets))\(safety)\(settling)\(nasText)")
            }
            let snapshot=ReadingProgress(files:fileStates,paused:paused)
            if snapshot != lastSnapshot {fileProgress(snapshot);lastSnapshot=snapshot}
            if !active.isEmpty || !pending.isEmpty || paused {try? await Task.sleep(nanoseconds:25_000_000)}
        }
        if let failure {throw failure}
        guard !cancelled else {throw CancellationError()}
        progress("全部读取完成，正在汇总完整元数据…")
        let merge=ProcessRunner();phaseRunner=merge
        let result=try await runMetadataProcess(merge,arguments:["--manifest",manifest.path,"--merge-directory",workers.path,"--output-json",directory.appendingPathComponent("metadata.json").path,"--summary-json",directory.appendingPathComponent("summary.json").path])
        phaseRunner=nil
        guard !cancelled else {throw CancellationError()}
        guard result.status==0 else {throw AppError.message("元数据汇总失败：\(result.output)")}
        try FileManager.default.removeItem(at:workers)
        readingOutcome="success"
    }
}

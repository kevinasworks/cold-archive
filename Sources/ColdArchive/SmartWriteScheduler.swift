// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// One feedback state per storage device, sharing one whole-app admission budget.
/// A process spanning devices is not attributable kernel I/O; exact instrumented
/// writes may still be attributed. Serial executors never invent parallel work.
final class SmartWriteScheduler: @unchecked Sendable {
    static let shared=SmartWriteScheduler()
    private struct Domain {
        var control=ThroughputController(minimumWindow:1)
        var last=ProcessInfo.processInfo.systemUptime
        var context=""
        var logical=LogicalWriteMeter.Sample()
        var kernelBytes:UInt64=0,cpu:UInt64=0
        var complete=true,settled=true
        var evidence=NASPressureEvidence()
        var lastServed=0.0
        var demandPeak=0
        var demandTime=0.0
        mutating func resetWindow(_ now:Double) {last=now;logical = .init();kernelBytes=0;cpu=0;complete=true;settled=true}
    }
    private let queue=DispatchQueue(label:"ColdArchive.WriteFeedback",qos:.utility)
    private var timer:DispatchSourceTimer?
    private var states:[String:Domain]=[:]
    private var counters:[Int32:ProcessActivityDelta]=[:]
    private var observedPIDs=Set<Int32>()
    private var logical=LogicalWriteMeter()
    private var settings=ConcurrencySettings.load()
    private var generation=0
    private var previousGlobalLimit:Int?
    private let owner=UUID().uuidString
    private let pressure=MacPressure()
    func configure(_ settings:ConcurrencySettings,root:URL,generation:Int) {
        queue.async {
            self.timer?.cancel();self.timer=nil
            for pid in self.observedPIDs {IOBudgetCoordinator.shared.release(owner:self.owner+"-"+String(pid))}
            for domain in self.states.keys {IOBudgetCoordinator.shared.release(owner:self.owner+"-"+domain)}
            self.observedPIDs=[];self.counters=[:];self.states=[:]
            // Discard bytes between the previous sampling tick and this policy change.
            _ = self.logical.sampleDomains(root:root)
            self.generation=generation;self.settings=settings;self.previousGlobalLimit=nil
            let timer=DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now()+1,repeating:1)
            timer.setEventHandler {[weak self] in self?.tick(root)}
            self.timer=timer;timer.resume()
        }
    }
    private func tick(_ root:URL) {
        let snapshot=PermitPool.snapshot(root)
        let coordinator=IOBudgetCoordinator.shared,now=ProcessInfo.processInfo.systemUptime
        let signals=pressure.read()
        var active:[String:Int]=[:],waiting:[String:Int]=[:],pids:[String:Set<Int32>]=[:],stages:[String:Set<String>]=[:]
        for (raw,count) in snapshot.activeByDomain {active[coordinator.canonicalDomain(raw),default:0] += count}
        for (raw,count) in snapshot.waitingByDomain {waiting[coordinator.canonicalDomain(raw),default:0] += count}
        for (raw,values) in snapshot.pidsByDomain {pids[coordinator.canonicalDomain(raw),default:[]].formUnion(values)}
        for (raw,values) in snapshot.stagesByDomain {stages[coordinator.canonicalDomain(raw),default:[]].formUnion(values)}
        let domains=Set(active.keys).union(waiting.keys)
        let samples=logical.sampleDomains(root:root)
        var measured:[String:LogicalWriteMeter.Sample]=[:]
        var coverage:[String:[String:Set<Int32>]]=[:]
        for (context,sample) in samples {
            let domain=coordinator.canonicalDomain(context.domain)
            if stages[domain]?.contains(context.stage)==true {
                measured[domain,default:.init()].add(sample)
                if sample.complete {coverage[domain,default:[:]][context.stage,default:[]].formUnion(sample.producers)}
            }
        }
        counters=counters.filter{snapshot.pids.contains($0.key)}
        for pid in observedPIDs.subtracting(snapshot.pids) {coordinator.release(owner:owner+"-"+String(pid))}
        observedPIDs=snapshot.pids
        var kernel:[Int32:ProcessActivityDelta.Sample]=[:]
        for pid in snapshot.pids {
            var counter=counters[pid] ?? ProcessActivityDelta()
            let sample=counter.observe(ProcessActivity.sample(pid:pid));counters[pid]=counter;kernel[pid]=sample
            if pid != getpid() {coordinator.updateFootprint(owner:owner+"-"+String(pid),bytes:sample.footprint,lane:.write,pid:pid)}
        }
        let resources=coordinator.evidence(for:.write)
        let ceiling=signals.critical ? 0:min(settings.writeLimit,resources.ceiling)
        if !snapshot.valid {
            DiagnosticLog.shared.write(["event":"write_measurement_error","operation":owner,"code":"permit_snapshot_failed"])
            for domain in states.keys {states[domain]!.resetWindow(now)}
            var fallback=(try? WriteAdmissionPolicy.load(root)) ?? .init(limit:1,default_limit:1,domain_limits:[:],aliases:coordinator.currentAliases())
            fallback.limit=min(fallback.limit,ceiling)
            do {_=try WriteBudget.updatePolicy(fallback,generation:generation)}
            catch {DiagnosticLog.shared.write(["event":"write_budget_error","code":DiagnosticLog.category(error)])}
            WriteBudgetStatus.publish("写入监测暂不可用，暂缓扩大并发；已有文件继续处理。")
            return
        }
        var rows:[String:[String:Any]]=[:]
        for domain in domains.sorted() {
            var state=states[domain] ?? Domain()
            let count=active[domain] ?? 0,queued=waiting[domain] ?? 0
            if count>0 {state.lastServed=now}
            if count+queued>=state.demandPeak || now-state.demandTime>2 {
                state.demandPeak=count+queued;state.demandTime=now
            }
            let context=(stages[domain] ?? []).sorted().joined(separator:"|")
            if context != state.context {
                let old=state.control.target
                let bootstrap=signals.critical ? 1:min(4,max(1,count+queued),max(1,ceiling))
                let claimed=bootstrap<=1 || coordinator.claimProbe(domain:domain,owner:owner+"-"+domain,seconds:8,now:now)
                state.context=context
                state.control=ThroughputController(initial:settings.writeMode == "smart" && claimed ? bootstrap:1,minimumWindow:1)
                state.resetWindow(now)
                if settings.writeMode == "smart" {
                    DiagnosticLog.shared.write(["event":"write_context_reset","operation":owner,"target_ref":DiagnosticLog.shared.target(domain),
                        "old":old,"target":state.control.target,"active":count,"waiting":queued,"measurement_complete":false,
                        "code":claimed ? "bootstrap_demand_probe":"storage_probe_deferred"])
                }
            }
            state.logical.add(measured[domain] ?? .init())
            for pid in pids[domain] ?? [] {
                let attributable=pids.values.filter{$0.contains(pid)}.count==1 && pid != getpid()
                if let value=kernel[pid],attributable {
                    state.kernelBytes += value.writeBytes;state.cpu += value.cpuNanoseconds
                    state.complete = state.complete && value.complete
                } else {state.complete=false}
            }
            if count<state.control.target {state.settled=false}
            let nas=state.evidence.observe(NASFeedback.shared.sample(domain:domain),direction:.write,now:now)
            let elapsed=now-state.last
            if elapsed>=0.99 || signals.critical {
                let producers=pids[domain] ?? []
                let covered=snapshot.pidsByStage.filter{coordinator.canonicalDomain($0.key)==domain}.values.allSatisfy { contexts in
                    contexts.allSatisfy {stage,owners in owners.isSubset(of:coverage[domain]?[stage] ?? [])}
                }
                let useLogical=state.logical.bytes>0 && covered && producers.isSubset(of:state.logical.producers)
                let metric=useLogical ? "logical_bytes":"kernel_process_tree"
                let reliable=snapshot.valid && state.settled && (useLogical ? state.logical.complete:state.complete && state.kernelBytes>0)
                let rate=Double(useLogical ? state.logical.bytes:state.kernelBytes)/max(0.001,elapsed)
                let previous=settings.writeMode == "smart" ? state.control.target:settings.writeLimit
                var code="custom_target"
                if settings.writeMode == "smart" {
                    var candidate=state.control
                    let decision=candidate.observe(.init(rate:rate,duration:elapsed,active:count,waiting:queued,
                        ceiling:max(1,ceiling),reliable:reliable,congested:signals.pressure || nas.congested,
                        critical:signals.critical,context:context+"|"+metric,
                        explorationPermitted:state.cpu>0 || state.logical.calls>0))
                    let needsClaim=decision.changed && !signals.critical && decision.reason != "safety_ceiling"
                    if !needsClaim || coordinator.claimProbe(domain:domain,owner:owner+"-"+domain,seconds:8,now:now) {
                        state.control=candidate;code=decision.reason
                    } else {code="storage_probe_deferred"}
                }
                if signals.critical {code="critical_resource_admission_paused"}
                else if settings.writeMode == "custom",ceiling<settings.writeLimit {code="custom_resource_safety_guard"}
                else if count<=1 && queued==0 {code="executor_serial_or_no_demand"}
                rows[domain]=["event":"write_control_window","operation":owner,"target_ref":DiagnosticLog.shared.target(domain),
                    "stage":stages[domain]?.count==1 ? stages[domain]!.first!:"mixed_writes","metric_source":metric,
                    "old":previous,"target":settings.writeMode == "smart" ? state.control.target:settings.writeLimit,
                    "active":count,"waiting":queued,"ceiling":ceiling,"configured_limit":settings.writeLimit,
                    "disk_write_bytes":state.kernelBytes,"bytes_written":state.logical.bytes,"io_calls":state.logical.calls,
                    "io_seconds":state.logical.seconds,"rate":rate,"window_seconds":elapsed,"valid":snapshot.valid,
                    "measurement_complete":reliable,"mac_pressure":signals.pressure,"nasFresh":nas.fresh,
                    "latency":nas.latency ?? -1,"nas_age_seconds":nas.age ?? -1,"nas_pressure":nas.congested,"nas_headroom":nas.headroom,"code":code].merging(resources.fields) {_,new in new}
                state.resetWindow(now)
            }
            states[domain]=state
        }
        for domain in Set(states.keys).subtracting(domains) {
            states[domain]!.control.resetMeasurements();states[domain]!.resetWindow(now)
            coordinator.release(owner:owner+"-"+domain)
        }
        let demand=Dictionary(uniqueKeysWithValues:domains.map{($0,max((active[$0] ?? 0)+(waiting[$0] ?? 0),states[$0]?.demandPeak ?? 0))})
        let targets=Dictionary(uniqueKeysWithValues:domains.map{($0,settings.writeMode == "smart" ? states[$0]!.control.target:settings.writeLimit)})
        let priority=domains.sorted{(states[$0]?.lastServed ?? 0, $0)<(states[$1]?.lastServed ?? 0, $1)}
        let allocation=WriteAllocation.limits(targets:targets,demand:demand,ceiling:ceiling,priority:priority)
        let policy=WriteAdmissionPolicy(limit:ceiling,default_limit:settings.writeMode == "smart" ? 1:settings.writeLimit,
            domain_limits:allocation,aliases:coordinator.currentAliases())
        do {
            guard try WriteBudget.updatePolicy(policy,generation:generation) else {return}
            for (domain,var row) in rows {
                row["allocation"]=allocation[domain] ?? 0
                if (allocation[domain] ?? 0)<min(targets[domain] ?? 1,demand[domain] ?? 0),
                   row["code"] as? String != "critical_resource_admission_paused",row["code"] as? String != "custom_resource_safety_guard" {
                    row["code"]="shared_budget_allocation"
                }
                DiagnosticLog.shared.write(row)
            }
            if previousGlobalLimit != ceiling {
                DiagnosticLog.shared.write(["event":"write_resource_budget","operation":owner,"configured_limit":settings.writeLimit,
                    "ceiling":ceiling,"active":snapshot.active,"waiting":snapshot.waiting,
                    "code":signals.critical ? "critical_resource_admission_paused":ceiling<settings.writeLimit ? "resource_safety_guard":"resource_budget_recovered"].merging(resources.fields) {_,new in new})
                previousGlobalLimit=ceiling
            }
            WriteBudgetStatus.publish(signals.critical ? "严重资源压力：暂缓新写入，已开始的文件继续完成。":
                ceiling<settings.writeLimit ? "写入资源安全上限\(ceiling)个（设置上限\(settings.writeLimit)个）；资源恢复后自动恢复。":"")
        } catch {DiagnosticLog.shared.write(["event":"write_budget_error","code":DiagnosticLog.category(error)])}
    }
}

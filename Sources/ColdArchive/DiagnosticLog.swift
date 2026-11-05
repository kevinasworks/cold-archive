// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OSLog

/// Logs accept only an explicit schema; arbitrary error text and tool output are never persisted.
final class DiagnosticLog: @unchecked Sendable {
    static let shared=DiagnosticLog()
    static let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ColdArchive")
    private let lock=NSLock()
    private let directory:URL
    private var handle:FileHandle?
    private var size=0
    private var sequence=0
    private var targets:[String:String]=[:]
    private var failed=false
    var failure:Bool {lock.lock();defer{lock.unlock()};return failed}
    private let maximumBytes:Int
    private let session=UUID().uuidString
    private let system=Logger(subsystem:"local.coldarchive",category:"diagnostics")
    init(directory:URL=DiagnosticLog.directory,maximumBytes:Int=2*1024*1024) {self.directory=directory;self.maximumBytes=maximumBytes}
    func target(_ host:String)->String {
        lock.lock();defer{lock.unlock()}
        let key=host.lowercased()
        if let ref=targets[key] {return ref}
        let ref="target-\(targets.count+1)";targets[key]=ref;return ref
    }
    static func category(_ error:Error)->String {category(error.localizedDescription)}
    static func category(_ message:String)->String {
        let m=message.lowercased()
        if m.contains("timeout") || m.contains("超时") || m.contains("未响应") {return "timeout"}
        if m.contains("security level") {return "security_level_mismatch"}
        if m.contains("unknown user") {return "unknown_user"}
        if m.contains("authentication") || m.contains("认证") {return "authentication_or_configuration"}
        if m.contains("钥匙串") {return "keychain_unavailable"}
        if m.contains("社群") {return "community_configuration"}
        if m.contains("地址") || m.contains("resolve") {return "address_or_configuration"}
        if m.contains("cancel") || m.contains("取消") {return "cancelled"}
        return "operation_failed"
    }
    static func errorFields(_ message:String)->[String:Any] {
        var fields:[String:Any]=["code":category(message)]
        if let regex=try? NSRegularExpression(pattern:"库错误 (-?[0-9]+)，系统错误 (-?[0-9]+)"),
           let match=regex.firstMatch(in:message,range:NSRange(message.startIndex...,in:message)) {
            for (i,key) in [(1,"library_error"),(2,"system_error")] {
                if let range=Range(match.range(at:i),in:message),let value=Int(message[range]) {fields[key]=value}
            }
        }
        return fields
    }
    // No free-form strings: event, stage and codes are internal constants, constrained tokens.
    static func sanitized(_ fields:[String:Any])->[String:Any] {
        let numbers:Set<String>=["file_descriptors_open","file_descriptor_limit","estimated_fds_per_task","memory_ceiling","descriptor_ceiling","memory_budget_bytes","estimated_memory_bytes","allocation","configured_limit","paused","baseline_rate","nas_age_seconds","ceiling","available","numeric_fields","name_fields","smb_read_rate","smb_write_rate","smb_read_latency","smb_write_latency","max_readers","max_writers","cpu_counter_50","cpu_counter_51","cpu_counter_52","cpu_counter_53","cpu_counter_54","cpu_counter_56","cpu_counter_61","cpu_counter_64","nas_iowait","pressure_samples","nas_cpu","nas_headroom","mac_pressure","nas_pressure","samples","rate","window_seconds","duration_ms","protocol","port","privacy","timeout_ms","retry_limit","rows","valid","cpu","disk_load","latency","id","active","target","old","seconds","nasFresh","matchedFiles","totalFiles","enabled","exit_code","library_error","system_error","native_value","elapsed_ms","send_count","receive_count","send_failures","receive_failures","bytes_sent","bytes_received","family"]
        let tokens:Set<String>=["resource_reason","phase","transport","event","stage","code","operation","target_ref","origin","oid","authentication","privacy_protocol","outcome","query_id","network_stage","address_ref","address_scope","interface_kind","interface_ref"]
        var out:[String:Any]=[:]
        let activityNumbers:Set<String>=["disk_read_bytes","disk_write_bytes","cpu_nanoseconds","footprint_bytes","measurement_complete","waiting","bytes_read","bytes_written","io_calls","io_seconds","max_io_seconds"]
        for (key,value) in fields {
            if activityNumbers.contains(key),let n=value as? NSNumber,n.doubleValue.isFinite {out[key]=n;continue}
            if key == "metric_source",let s=value as? String,["kernel_process_tree","logical_bytes","normalized_completions","admission_wait","tool_wall_time"].contains(s) {out[key]=s;continue}
            if key == "interface_name",let s=value as? String {
                if s.range(of:"^(en|utun|lo|bridge|awdl|llw|pdp_ip|ipsec)[0-9]{1,5}$",options:.regularExpression) != nil {out[key]=s};continue
            }
            if ["authentication","privacy_protocol"].contains(key), let s=value as? String {
                if ["SHA","MD5","AES","DES"].contains(s) {out[key]=s};continue
            }
            if key == "oid", let s=value as? String {
                if s.range(of:"^[0-9]+(?:\\.[0-9]+)+$",options:.regularExpression) != nil {out[key]=s};continue
            }
            if numbers.contains(key), let n=value as? NSNumber, n.doubleValue.isFinite {out[key]=n}
            else if tokens.contains(key), let s=value as? String, s.count<=100,
                    s.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil {out[key]=s}
        }
        return out
    }
    @discardableResult func write(_ fields:[String:Any])->Bool {
        lock.lock();defer{lock.unlock()}
        do { return try WriteBudget.native(kind:.log) {
            if handle==nil || size>=maximumBytes {
                try handle?.close();handle=nil
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.creationDateKey]).filter{$0.lastPathComponent.hasPrefix("diagnostic-") && $0.pathExtension=="jsonl"}.sorted{ (try? $0.resourceValues(forKeys:[.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast < (try? $1.resourceValues(forKeys:[.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast }
                for old in files.prefix(max(0,files.count-9)) {try FileManager.default.removeItem(at:old)}
                let file=directory.appendingPathComponent("diagnostic-\(UUID().uuidString).jsonl")
                guard FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw CocoaError(.fileWriteUnknown)}
                handle=try FileHandle(forWritingTo:file);size=0
            }
            var row=Self.sanitized(fields)
            let event=row["event"] as? String ?? "unknown"
            let outcome=row["outcome"] as? String ?? ""
            let exitCode=(row["exit_code"] as? NSNumber)?.intValue ?? 0
            row["level"] = event.hasSuffix("error") || outcome == "failed" || exitCode != 0 ? "error" : (outcome == "partial" || outcome == "missing" || outcome == "no_usable_metrics" || event.hasSuffix("rejected") ? "warning":"info")
            sequence+=1
            row["sequence"]=sequence;row["session"]=session;row["schema"]=2
            row["time"]=ISO8601DateFormatter().string(from:Date())
            row["uptime"]=ProcessInfo.processInfo.systemUptime
            row["os_version"]=ProcessInfo.processInfo.operatingSystemVersionString
            row["app_version"]=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development"
            let data=try JSONSerialization.data(withJSONObject:row,options:.sortedKeys)+Data([10])
            try handle?.write(contentsOf:data);size+=data.count;failed=false;return true
        } } catch {
            failed=true;handle=nil
            system.error("Diagnostic log write failed; no sensitive error details emitted")
            return false
        }
    }
}

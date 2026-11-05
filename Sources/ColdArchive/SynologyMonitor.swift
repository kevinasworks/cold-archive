// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security
import NativeMonitor
import Darwin

struct NASConfiguration: Codable, Equatable {
    var enabled = false
    var host = ""
    var port = 161
    var transport: String? = "TCP"
    var version = 3
    var user = ""
    var privacy = false
    var authProtocol: String? = "SHA"
    var privacyProtocol: String? = "AES"
    var mountPaths: [String] = []
    var mountIdentities: [String:String]? = [:]
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "nasConfiguration"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func validate() throws {
        var ipv6=in6_addr()
        let isIPv6=inet_pton(AF_INET6,host,&ipv6)==1
        guard !host.isEmpty, host.count < 250, (isIPv6 || host.range(of: #"^[a-zA-Z0-9.-]+$"#, options: .regularExpression) != nil),
              (1...65535).contains(port), [2,3].contains(version) else { throw AppError.message("请输入 NAS 的 IPv4、IPv6 地址或主机名和有效端口；不要填写网页 URL。") }
        guard ["TCP","UDP"].contains(transport ?? "TCP") else {throw AppError.message("请选择 TCP 或 UDP 传输协议。") }
        if !["SHA","MD5"].contains(authProtocol ?? "SHA") || !["AES","DES"].contains(privacyProtocol ?? "AES") { throw AppError.message("不支持的 SNMP 算法，请重新选择。") }
        if version == 3 && user.isEmpty { throw AppError.message("请填写 SNMPv3 用户名。") }
    }
    func save() throws { if enabled { try validate() }; UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "nasConfiguration") }
}
struct NASSecrets: Codable, Equatable { var auth = ""; var privacy = ""; var loadingError: String? = nil }
/// Serializes authorization and reuses the result, including denial, for this app session.
final class CredentialSessionCache {
    private let lock = NSRecursiveLock()
    private var result: Result<NASSecrets, Error>?
    func load(retry: Bool = false, fetch: () throws -> NASSecrets) throws -> NASSecrets {
        lock.lock(); defer { lock.unlock() }
        if retry { result = nil }
        if let result { return try result.get() }
        let fetched = Result { try fetch() }
        result = fetched
        return try fetched.get()
    }
    func saved(_ value: NASSecrets) { lock.lock(); defer { lock.unlock() }; result = .success(value) }
    func matches(_ value: NASSecrets) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .success(let cached) = result else { return false }
        return cached == value
    }
}
struct NASSample: Sendable {
    var timestamp=ProcessInfo.processInfo.systemUptime
    var model=""; var version=""
    var interfaceAddresses:Set<String>=[]
    var cpuWait:Double?
    var cpu: Double?; var diskLoad: Double?; var readLatency: Double?; var writeLatency:Double?
    var values: [String:Double]=[:]
    var smbNames: [String:String]=[:]
    var smbAvailable: Bool { (readLatency != nil && values["1.3.6.1.4.1.6574.111.2.1.3.14"] != nil) || (writeLatency != nil && values["1.3.6.1.4.1.6574.111.2.1.3.19"] != nil) }
    var message="正在连接 NAS，等待首次指标"
    var valid=false
    var fresh: Bool { valid && ProcessInfo.processInfo.systemUptime-timestamp < 30 }
    func progressDescription(received:Bool)->String {
        if !received {return "正在连接 NAS，使用 Mac 反馈"}
        if fresh {return smbAvailable ? "NAS 与 SMB 监测已接入":"NAS 监测已接入 · SMB 指标未返回"}
        if valid {return "NAS 指标已过期，使用 Mac 反馈"}
        return "NAS 监测失败：\(String(message.prefix(90))) · 详情见诊断日志，使用 Mac 反馈"
    }
}
final class SynologyMonitor: @unchecked Sendable {
    // Net-SNMP global initialization and all session access are serialized.
    static let queue=DispatchQueue(label:"ColdArchive.SNMP",qos:.utility)
    private var cpuDelta=NASCPUDelta()
    private var cpuConfiguration:NASConfiguration?
    func sample(_ config: NASConfiguration, secrets: NASSecrets, origin:String="reading", includeIdentity:Bool=false) async -> NASSample {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                if self.cpuConfiguration != config {self.cpuDelta=NASCPUDelta();self.cpuConfiguration=config}
                var sample=Self.read(config,secrets,origin:origin,includeIdentity:includeIdentity)
                if let measured=self.cpuDelta.sample(values:sample.values,time:sample.timestamp) {
                    sample.cpu=measured.busy;sample.cpuWait=measured.wait
                    sample.message=sample.message.replacingOccurrences(of:"CPU 等待有效的连续采样",with:String(format:"CPU 运算 %.1f%%；I/O 等待 %.1f%%",measured.busy,measured.wait))
                }
                continuation.resume(returning:sample)
            }
        }
    }
    static func read(_ config: NASConfiguration,_ secrets: NASSecrets,origin:String="reading",diagnosticLogger:DiagnosticLog = .shared,includeIdentity:Bool=false) -> NASSample {
        var result=NASSample()
        let log=diagnosticLogger, operation=UUID().uuidString
        let started=ProcessInfo.processInfo.systemUptime
        var stage="configuration"
        var outcome="failed"
        func record(_ event:String,_ extra:[String:Any]=[:]) {
            log.write(extra.merging(["event":event,"operation":operation,"origin":origin,"stage":stage,"target_ref":log.target(config.host)]) {_,new in new})
        }
        record("snmp_begin",["transport":config.transport ?? "TCP","protocol":config.version,"port":config.port,"privacy":config.privacy,"authentication":config.authProtocol ?? "SHA","privacy_protocol":config.privacyProtocol ?? "AES","timeout_ms":3000,"retry_limit":1])
        defer {record("snmp_end",["outcome":outcome,"valid":result.valid,"duration_ms":(ProcessInfo.processInfo.systemUptime-started)*1000])}
        do {
            try config.validate()
            if let error=secrets.loadingError {throw AppError.message(error)}
            if secrets.auth.isEmpty {throw AppError.message(config.version == 3 ? "未提供 SNMPv3 认证密码，请在设置中填写并保存。":"未提供 SNMP 社群，请在设置中填写并保存。") }
            ca_snmp_batch_begin_transport((config.transport ?? "TCP") == "TCP" ? 1:0)
            defer { ca_snmp_batch_end() }
            func query(_ oid:String, walk:Bool=false) throws -> [(String,String,Double?)] {
                let queryStart=ProcessInfo.processInfo.systemUptime
                record("snmp_request",["oid":oid])
                var rows=[CAMetric](repeating:CAMetric(),count:1024), error=[CChar](repeating:0,count:256)
                let trace=SNMPDiagnosticTrace(log:log,operation:operation,origin:origin,stage:stage,target:log.target(config.host),oid:oid)
                let n=ca_snmp_diagnostic(config.host,Int32(config.port),Int32(config.version),config.user,secrets.auth,secrets.privacy,config.privacy ? 1:0,config.authProtocol == "MD5" ? 1:0,config.privacyProtocol == "DES" ? 1:0,oid,walk ? 1:0,&rows,1024,&error,256,{context,event,value,number,systemError in
                    guard let context,let event,let value else{return}
                    Unmanaged<SNMPDiagnosticTrace>.fromOpaque(context).takeUnretainedValue().receive(String(cString:event),String(cString:value),Int(number),Int(systemError))
                },Unmanaged.passUnretained(trace).toOpaque())
                trace.finish(success:n >= 0)
                record("snmp_response",DiagnosticLog.errorFields(n < 0 ? String(cString:error):"").merging(["oid":oid,"rows":max(0,n),"outcome":n < 0 ? "failed":n == 0 ? "missing":"success","code":n < 0 ? DiagnosticLog.category(String(cString:error)):"none","duration_ms":(ProcessInfo.processInfo.systemUptime-queryStart)*1000]) {_,new in new})
                guard n >= 0 else { throw AppError.message(String(cString:error)) }
                return rows.prefix(Int(n)).map { row in
                    var r=row
                    let key=withUnsafePointer(to:&r.oid) { $0.withMemoryRebound(to:CChar.self,capacity:256) { String(cString:$0) } }
                    let text=withUnsafePointer(to:&r.text) { $0.withMemoryRebound(to:CChar.self,capacity:512) { String(cString:$0) } }
                    return (key,text,r.numeric == 1 ? r.number:nil)
                }
            }
            stage="model"
            result.model=try query("1.3.6.1.4.1.6574.1.5.1.0").first?.1 ?? ""
            guard result.model == "DS923+" else { record("snmp_rejected",["code":"model_not_supported"]); result.message="设备未确认为 DS923+，未用于调度（返回：\(result.model)）"; return result }
            stage="version"
            result.version=try query("1.3.6.1.4.1.6574.1.5.3.0").first?.1 ?? ""
            guard supportedDSMVersion(result.version) else { record("snmp_rejected",["code":"version_not_supported"]); result.message="DSM 版本不在当前适配范围：\(result.version)"; return result }
            if includeIdentity {
                stage="identity"
                // Address indices avoid relying on the library's textual rendering.
                for oid in NASAddressIdentity.tableOIDs {
                    do {
                        for (key,_,_) in try query(oid,walk:true) {
                            if let address=NASAddressIdentity.address(oid:key) {result.interfaceAddresses.insert(address)}
                        }
                    } catch {record("nas_identity_error",["code":DiagnosticLog.category(error)])}
                }
                record("nas_identity_result",["rows":result.interfaceAddresses.count])
            }
            // Missing OIDs are omitted, never interpreted as zero. Standard DSM
            // version OID may omit Update number; this is stated in the UI.
            let queries:[(String,Bool)]=[("1.3.6.1.4.1.2021.11",true),
                ("1.3.6.1.4.1.6574.101.1.1.8",true),
                ("1.3.6.1.4.1.6574.111",true),
                ("1.3.6.1.4.1.6574.101.1.1.12",true),
                ("1.3.6.1.2.1.31.1.1.1.6",true),("1.3.6.1.2.1.31.1.1.1.10",true)]
            stage="metrics"
            var failures:[String]=[]
            for (oid,walk) in queries {
                do { for (key,name,number) in try query(oid,walk:walk) {
                    if let number, number.isFinite, number >= 0 {result.values[key]=number}
                    if key.hasPrefix("1.3.6.1.4.1.6574.111."), !name.isEmpty {result.smbNames[key]=name}
                } }
                catch { failures.append("\(oid)：\(error.localizedDescription)") }
            }
            // Deprecated one-minute idle percentage is not instantaneous CPU work.
            result.cpu=nil
            result.diskLoad=result.values.filter { $0.key.hasPrefix("1.3.6.1.4.1.6574.101.1.1.8.") }.map(\.value).max()
            result.readLatency=result.values["1.3.6.1.4.1.6574.111.2.1.4.14"]
            result.writeLatency=result.values["1.3.6.1.4.1.6574.111.2.1.4.19"]
            result.valid=result.writeLatency != nil || result.diskLoad != nil || result.readLatency != nil || NASCPUDelta.fields.allSatisfy {result.values["1.3.6.1.4.1.2021.11.\($0).0"] != nil}
            result.timestamp=ProcessInfo.processInfo.systemUptime
            let cpu=result.cpu.map {String(format:"CPU %.0f%%",$0)} ?? "CPU 等待有效的连续采样"
            let disk=result.diskLoad.map {String(format:"磁盘最高负载 %.0f%%",$0)} ?? "磁盘负载不可用"
            record("snmp_smb_result",["outcome":result.smbAvailable ? "success":"missing","available":result.smbAvailable,"numeric_fields":result.values.keys.filter {$0.hasPrefix("1.3.6.1.4.1.6574.111.")}.count,"name_fields":result.smbNames.count])
            var smbLog:[String:Any]=[:]
            for (field,oid) in [("smb_read_rate","3.14"),("smb_write_rate","3.19"),("smb_read_latency","4.14"),("smb_write_latency","4.19")] {
                if let value=result.values["1.3.6.1.4.1.6574.111.2.1."+oid] {smbLog[field]=value}
            }
            record("snmp_smb_metrics",smbLog)
            let readRate=result.values["1.3.6.1.4.1.6574.111.2.1.3.14"].map {String(format:"读取 %.0f 次/秒",$0)} ?? "读取速率未返回"
            let writeRate=result.values["1.3.6.1.4.1.6574.111.2.1.3.19"].map {String(format:"写入 %.0f 次/秒",$0)} ?? "写入速率未返回"
            let writeLatency=result.values["1.3.6.1.4.1.6574.111.2.1.4.19"].map {String(format:"写入平均延迟 %.0f µs",$0)} ?? "写入延迟未返回"
            let latency=result.readLatency.map {String(format:"SMB 读取平均延迟 %.0f µs",$0)} ?? "SMB 读取延迟未返回（不代表设备不支持）"
            result.message="\(result.valid ? "监测已接入" : "设备已连接，但没有可用于调度的 CPU、磁盘负载或 SMB 延迟指标")\n\(result.model) · \(result.version)\n\(cpu)；\(disk)；\(latency)\nSMB：\(readRate)；\(writeRate)；\(writeLatency)\n\(!failures.isEmpty ? "部分请求失败："+failures.joined(separator:"；") : "")Update 3 补丁号需在 DSM 确认；计数仅作辅助，不代表本应用独占流量。"
            outcome=result.valid ? (failures.isEmpty ? "success":"partial") : "no_usable_metrics"
        } catch { result.message=error.localizedDescription;record("snmp_error",["code":DiagnosticLog.category(error)]) }
        if log.failure {result.message += "\n诊断日志未能写入，请检查日志目录权限或可用空间。"}
        return result
    }
}

/// Pins an explicitly associated mount to its actual SMB source. Remounting a
/// different share at the same path invalidates NAS telemetry association.
func mountIdentity(_ path:String) -> String? {
    mountedSources().first {path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path+"/") }?.identity
}

struct MountedSource {
    let path:String
    let local:Bool
    let identity:String?
}
/// Kernel mount table, MNT_NOWAIT: classification never probes a remote file.
func mountedSources() -> [MountedSource] {
    let count=getfsstat(nil,0,MNT_NOWAIT)
    guard count>0 else{return []}
    var rows: [Darwin.statfs] = Array(repeating: Darwin.statfs(), count: Int(count)+8)
    let n=rows.withUnsafeMutableBufferPointer {getfsstat($0.baseAddress,Int32($0.count*MemoryLayout<statfs>.stride),MNT_NOWAIT)}
    guard n>0 else{return []}
    var result:[MountedSource]=[]
    for row in rows.prefix(min(Int(n),rows.count)) {
        var r=row
        let path=withUnsafePointer(to:&r.f_mntonname){$0.withMemoryRebound(to:CChar.self,capacity:Int(MAXPATHLEN)){String(cString:$0)}}
        let raw=withUnsafePointer(to:&r.f_mntfromname){$0.withMemoryRebound(to:CChar.self,capacity:Int(MAXPATHLEN)){String(cString:$0)}}
        let parts=raw.dropFirst(2).split(separator:"/",maxSplits:1,omittingEmptySubsequences:false)
        let identity=raw.hasPrefix("//") && parts.count==2 ? (parts[0].split(separator:"@").last.map(String.init) ?? "").lowercased()+"/"+parts[1] : nil
        result.append(MountedSource(path:path,local:(r.f_flags & UInt32(MNT_LOCAL)) != 0,identity:identity))
    }
    return result.sorted{$0.path.count>$1.path.count}
}

/// Compare the mounted SMB server identity, never a user-selected folder.
/// DNS aliases and NAT endpoints are intentionally not assumed to be the same NAS.
func matchesNAS(_ identity:String?, host:String) -> Bool {
    guard let identity, let server=identity.split(separator:"/",maxSplits:1).first else{return false}
    func normalized(_ value:String)->String {value.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))}
    return normalized(String(server)) == normalized(host)
}

/// DSM SNMP omits the patch component on observed 7.3.2-86009 Update 3.
/// Match the release/build tuple; never claim the missing patch was measured.
func supportedDSMVersion(_ raw:String)->Bool {
    raw.trimmingCharacters(in:.whitespacesAndNewlines).range(of: #"^(?:DSM\s+)?7\.3(?:\.2)?-86009(?:\s+Update\s+3)?$"#, options:.regularExpression) != nil
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

struct NASSettings: View {
    @State private var config=NASConfiguration.load()
    @State private var secrets=NASSecrets()
    @State private var status="仅适配 DS923+ / DSM 7.3.2-86009 Update 3。"
    @State private var testing=false
    var body: some View {
        ScrollView { Form {
            Toggle("使用群晖 NAS 监测辅助调度",isOn:$config.enabled)
            TextField("NAS 地址",text:$config.host)
            Text("可填写域名或 IP，无需与 SMB 挂载地址文字相同。端口映射的 TCP/UDP 必须与下方传输协议一致。") .font(.caption)
            TextField("SNMP 端口",value:$config.port,format:.number)
            Picker("传输协议",selection:Binding(get:{config.transport ?? "TCP"},set:{config.transport=$0})) {Text("TCP").tag("TCP");Text("UDP").tag("UDP")}
            Picker("SNMP 版本",selection:$config.version) { Text("SNMPv3").tag(3);Text("SNMPv2c（现有配置）").tag(2) }
            if config.version == 3 {
                TextField("SNMP 用户名",text:$config.user)
                Picker("认证协议",selection:Binding(get:{config.authProtocol ?? "SHA"},set:{config.authProtocol=$0})) { Text("SHA（SHA-1）").tag("SHA");Text("MD5").tag("MD5") }
                Text("对应 DSM 的 SNMPv3 协议和密码，不是 DSM 登录密码。") .font(.caption)
                SecureField("认证密码",text:$secrets.auth)
                Toggle("启用 SNMP 隐私（加密）",isOn:$config.privacy)
                if config.privacy {
                    Picker("隐私协议",selection:Binding(get:{config.privacyProtocol ?? "AES"},set:{config.privacyProtocol=$0})) {Text("AES（AES-128）").tag("AES");Text("DES").tag("DES")}
                    SecureField("隐私密码",text:$secrets.privacy)
                }
                Text(config.privacy ? "认证并加密：DSM 也必须启用隐私，协议和两项密码分别一致。":"仅认证、不加密：对应 DSM 未勾选启用 SNMP 隐私。隐私密码不参与连接。").font(.caption)
            } else { SecureField("社群",text:$secrets.auth) }
            Divider()
            Text("读取前通过 SNMP 获取这台 NAS 的网卡地址，自动核对 SMB 来源；支持域名连接 NAS、内网 IP 读取文件。无法核实的跨 NAT 或代理地址不会自动关联，原因记录在诊断日志中。") .font(.caption)
            HStack {
                Button("保存设置") {
                    do {if config.enabled { try config.validate() };if !secrets.auth.isEmpty {try NASKeychain.save(secrets)} else if config.enabled {throw AppError.message("请先读取或重新填写SNMP凭据，再保存启用的监测设置。")};try config.save();status="已保存，下一次读取生效。"}
                    catch {status=error.localizedDescription;DiagnosticLog.shared.write(["event":"settings_error","code":DiagnosticLog.category(error)])}
                }
                Button(testing ? "正在测试…":"测试连接与指标") {
                    testing=true
                    Task {
                        let snapshot=config,credentials=secrets,monitor=SynologyMonitor()
                        var sample=await monitor.sample(snapshot,secrets:credentials,origin:"connection_test")
                        if sample.valid && sample.cpu==nil {
                            status="设备已连接，正在采集 CPU 的第二个样本…"
                            try? await Task.sleep(nanoseconds:2_000_000_000)
                            sample=await monitor.sample(snapshot,secrets:credentials,origin:"connection_test")
                        }
                        status=sample.message;testing=false
                    }
                }.disabled(testing || secrets.auth.isEmpty)
            }
            Button("重新授权读取凭据") {
                do { secrets = try NASKeychain.load(retry: true); status = "凭据已读取，本次运行的后续任务会复用。" }
                catch { status = error.localizedDescription }
            }.disabled(testing)
            Button("打开诊断日志文件夹") {
                let folder=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ColdArchive")
                do {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);NSWorkspace.shared.open(folder)} catch {status=error.localizedDescription;DiagnosticLog.shared.write(["event":"settings_error","code":DiagnosticLog.category(error)])}
            }
            Text(status).font(.callout).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            Text("凭据保存在macOS钥匙串。旧版授权不兼容时请重新填写并保存，旧条目保留；后台不会反复弹窗。测试只读，不会启用或修改 NAS 服务。指标缺失时回退到 Mac 反馈。") .font(.caption).foregroundStyle(.secondary)
        }.padding(24) }.frame(width:680,height:620).onAppear {
            do {secrets=try NASKeychain.load()} catch {status=error.localizedDescription;DiagnosticLog.shared.write(["event":"settings_error","code":DiagnosticLog.category(error)])}
        }
    }
}

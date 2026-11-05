// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit
struct ReadingSettings: View {
    @AppStorage("newTaskNavigation") private var newTaskNavigation = "first"
    @ObservedObject private var budgetStatus=WriteBudgetStatus.shared
    @State private var concurrency=ConcurrencySettings.load()
    @State private var readText=String(ConcurrencySettings.load().readers)
    @State private var writeText=String(ConcurrencySettings.load().writers)
    @State private var concurrencyStatus=""
    private func saveConcurrency() {
        let r=concurrency.readMode == "custom" ? Int(readText):concurrency.readers
        let w=concurrency.writeMode == "custom" ? Int(writeText):concurrency.writers
        guard let r, let w, (1...64).contains(r), (1...64).contains(w) else {
            concurrencyStatus="请输入 1～64 的整数。";return
        }
        concurrency.readers=r;concurrency.writers=w
        do {
            try concurrency.save()
        } catch {
            concurrencyStatus="并发设置应用失败，请重试。"
            DiagnosticLog.shared.write(["event":"concurrency_settings_error","code":DiagnosticLog.category(error)])
            return
        }
        concurrencyStatus="已保存，运行中的任务已应用新设置。正在处理的文件会继续完成。"
    }
    var body: some View {
        VStack(spacing:0) {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    VStack(alignment:.leading,spacing:5) {
                        Text("通用设置").font(.title2.bold())
                        Text("设置读取与目标写入的并发数量。").foregroundStyle(.secondary)
                    }
                    GroupBox("创建任务后") {
                        Picker("自动打开任务队列", selection: $newTaskNavigation) {
                            Text("仅本次运行的第一个任务").tag("first")
                            Text("每次创建任务").tag("always")
                            Text("不自动跳转").tag("never")
                        }.padding(10)
                        Text("此项立即保存。任务队列中的创建归档按钮打开独立窗口，提交后关闭窗口。")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    concurrencyCard(title:"文件读取",icon:"doc.text.magnifyingglass",mode:$concurrency.readMode,value:$readText,
                                    valueLabel:"同时读取",smart:"根据实测收益调整；资源安全上限最多64个，实际目标受内存与任务需求约束。",
                                    custom:"按填写数量调度读取；文件不足时按实际数量执行。触及资源安全边界时显示原因，并保留正在处理的文件。")
                    concurrencyCard(title:"目标文件写入",icon:"externaldrive",mode:$concurrency.writeMode,value:$writeText,
                                    valueLabel:"同时写入上限",smart:"根据实测写入活动与等待需求调整；资源安全上限最多64个，串行输出按执行器实际能力运行。",
                                    custom:"限制归档、恢复与导出文件的同时写入数量。资源保护会显示原因，资源恢复后自动恢复；已开始的文件继续完成。")
                    if !budgetStatus.message.isEmpty {Text(budgetStatus.message).font(.callout).foregroundStyle(.orange)}
                    HStack(alignment:.top,spacing:9) {
                        Image(systemName:"info.circle").foregroundStyle(.secondary)
                        Text("本机临时文件独立控制，最多 5 个；日志单独串行。临时文件若写到 NAS，仍计入目标写入上限。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(24)
            }
            Divider()
            HStack(spacing:16) {
                Text(concurrencyStatus.isEmpty ? "保存后立即应用。降低并发时，正在处理的文件继续完成。":concurrencyStatus)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,alignment:.leading)
                Button("保存设置",action:saveConcurrency).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(.horizontal,24).padding(.vertical,16)
        }.frame(width:600,height:600).background(Color(nsColor:.windowBackgroundColor))
    }
    private func concurrencyCard(title:String,icon:String,mode:Binding<String>,value:Binding<String>,valueLabel:String,smart:String,custom:String)->some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label(title,systemImage:icon).font(.headline)
                Spacer(minLength:16)
                Picker(title,selection:mode) {
                    Text("智能").tag("smart")
                    Text("自定义").tag("custom")
                }.pickerStyle(.segmented).labelsHidden().frame(width:180)
            }
            Text(mode.wrappedValue == "smart" ? smart:custom)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                .frame(maxWidth:.infinity,alignment:.leading)
            if mode.wrappedValue == "custom" {
                HStack(spacing:8) {
                    Text(valueLabel).font(.callout)
                    TextField("数量",text:value).textFieldStyle(.roundedBorder).frame(width:76)
                        .multilineTextAlignment(.trailing).accessibilityLabel(valueLabel)
                    Text("个").font(.callout)
                    Spacer()
                    Text("1～64 的整数").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(.background,in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(.quaternary,lineWidth:1))
    }
}

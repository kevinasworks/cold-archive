// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

enum ProvenanceField: String, CaseIterable, Codable {
    case sourceType = "source_type", device, software = "source_software", purpose, notes
    var title: String {
        switch self {
        case .sourceType: return "资料类别"
        case .device: return "生成文件的设备品牌及型号"
        case .software: return "生成或编辑文件的软件"
        case .purpose: return "此归档的用途"
        case .notes: return "备注"
        }
    }
}
struct SubmittedAnswer: Codable, Equatable {
    let status: String
    let answer: String
    let en: String?
    init(answer: String, english: String? = nil) {
        self.status = "submitted"; self.answer = answer; self.en = english
    }
}
struct AnswerDocument: Codable {
    let schema_version = 2
    let sources: [String]
    let answers: [String: SubmittedAnswer]
    enum CodingKeys: String, CodingKey { case schema_version, sources, answers }
}
struct Intake {
    private(set) var answers: [String: SubmittedAnswer] = [:]
    private(set) var stepIndex = 0
    private(set) var groupIndex = 0
    private(set) var groupedAnswers: [String: [GroupedAnswer]] = [:]
    private var plans: [String: [FileConfirmationGroup]] = [:]
    init(report: MetadataReport? = nil) {
        if let report { for field in ProvenanceField.allCases { plans[field.rawValue] = report.fileConfirmationPlan(for: field) } }
    }
    var currentGroups: [FileConfirmationGroup] { current.flatMap { plans[$0.rawValue] } ?? [] }
    var currentGroup: FileConfirmationGroup? { currentGroups.indices.contains(groupIndex) ? currentGroups[groupIndex] : nil }
    var positionID: String { "\(stepIndex):\(groupIndex)" }
    var isFinalConfirmation: Bool { stepIndex == ProvenanceField.allCases.count - 1 && groupIndex == max(0, currentGroups.count - 1) }
    var confirmedGroupCount: Int { current.map { groupedAnswers[$0.rawValue]?.count ?? 0 } ?? 0 }
    var currentResponse: SubmittedAnswer? {
        guard let current, let group = currentGroup else { return current.flatMap { answers[$0.rawValue] } }
        return groupedAnswers[current.rawValue]?.first { $0.group_id == group.id }?.response
    }
    var current: ProvenanceField? { ProvenanceField.allCases.indices.contains(stepIndex) ? ProvenanceField.allCases[stepIndex] : nil }
    var canGoBack: Bool { (stepIndex > 0 || groupIndex > 0) && !complete }
    mutating func goBack() {
        guard canGoBack else { return }
        if groupIndex > 0 { groupIndex -= 1 }
        else { stepIndex -= 1; groupIndex = max(0, currentGroups.count - 1) }
    }
    var complete: Bool { current == nil }
    mutating func submit(_ field: ProvenanceField, answer: String, english: String) throws {
        guard field == current else { throw AppError.message("请按顺序确认来源信息。") }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !["自由填写", "自定义填写", "Custom", "采用检测结果"].contains(trimmed) else { throw AppError.message("请输入实际内容。") }
        let unknown = ["未知／不填写", "未知/不填写", "未知", "不清楚", "Unknown", "不填写", "留空", "Leave blank"].contains(trimmed)
        let noNotes = ["无补充", "No additional notes"].contains(trimmed)
        guard !(field == .notes && unknown), !(field != .notes && noNotes) else {
            throw AppError.message("备注请选择无补充或填写实际内容；无补充仅适用于备注。")
        }
        let fixed = field == .notes ? trimmed == "无补充" : ["未知", "不填写", "未知／不填写"].contains(trimmed)
        guard fixed || !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("请填写英文内容，用于双语归档记录。") }
        answers[field.rawValue] = SubmittedAnswer(answer: answer, english: fixed ? nil : english)
        if let group = currentGroup {
            let record = GroupedAnswer(group_id: group.id, category: group.category, category_en: group.categoryEnglish,
                                       files: group.files, response: answers[field.rawValue]!)
            var records = groupedAnswers[field.rawValue] ?? []
            if let index = records.firstIndex(where: { $0.group_id == group.id }) { records[index] = record }
            else { records.append(record) }
            groupedAnswers[field.rawValue] = records
            if groupIndex + 1 < currentGroups.count { groupIndex += 1; return }
        }
        groupIndex = 0; stepIndex += 1
    }
    func document(sources: [URL]) throws -> Data {
        guard complete else { throw AppError.message("五项来源信息尚未全部确认。") }
        let resolvedSources = try sources.map { url in
            try url.withUnsafeFileSystemRepresentation { path in
                guard let path, let resolved = realpath(path, nil) else {
                    throw AppError.message("无法解析来源路径：\(url.path)")
                }
                defer { free(resolved) }
                return String(cString: resolved)
            }
        }
        if !plans.isEmpty {
            for field in ProvenanceField.allCases {
                guard groupedAnswers[field.rawValue]?.count == plans[field.rawValue]?.count else {
                    throw AppError.message("还有文件组尚未确认。")
                }
            }
            return try JSONEncoder().encode(GroupedAnswerDocument(sources: resolvedSources, grouped_answers: groupedAnswers))
        }
        return try JSONEncoder().encode(AnswerDocument(sources: resolvedSources, answers: answers))
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct MetadataProgress: Decodable { let current: Int; let total: Int; let file: String }
struct MetadataReport: Decodable {
    var file_paths: [String]? = nil
    struct Candidate: Decodable, Hashable {
        let field: String; let value: String; let file: String; let tag: String; let tool: String
        let en: String?
        let raw_value: String?
        let kind: String?
    }
    struct InspectionError: Decodable { let file: String?; let error: String }
    struct BrandFinding: Decodable {
        let brand: String; let role: String; let basis: String
        let file: String; let tag: String; let scope: String; let status: String
        var confirmation: (zh: String, en: String) {
            ("格式关联线索：\(brand)；实际生成设备及型号未确认。依据：\(file) · \(scope) · \(tag)",
             "Format association: \(brand); actual generating device and model are unconfirmed. Evidence: \(file) · \(scope) · \(tag)")
        }
        var evidenceLabel: String {
            if status == "file_declared" { return "文件内明确记载，待确认" }
            if status.contains("unverified") { return "疑似格式关联，尚未确认设备" }
            return "格式或结构线索，不能确定实际设备"
        }
        var roleLabel: String {
            switch role {
            case "capture_device": return "设备品牌（文件记载）"
            case "lens": return "镜头品牌"
            case "document_device_reference": return "文档或嵌入对象引用的设备（非文档来源证明）"
            case "encoding_device": return "编码设备厂商"
            case "software": return "软件厂商"
            default: return "格式关联线索（不是设备身份）"
            }
        }
    }
    let brand_findings: [BrandFinding]?
    let total_included_files: Int
    let inspected_file_count: Int
    let selected_file_count: Int
    let coverage: String
    let tool: String?
    let candidates: [Candidate]
    let errors: [InspectionError]
    struct InspectionWarning: Decodable { let file: String; let warning: String }
    let warnings: [InspectionWarning]
    var formatFindings: [BrandFinding] { (brand_findings ?? []).filter { $0.role == "format_family" } }
    static func diagnostic(_ raw: String) -> String {
        if raw == "File format error" {
            return "ExifTool：无法解析此文件格式；不代表文件损坏，其他读取器的结果仍保留。"
        }
        if raw == "Private format recognized; unknown proprietary fields may remain" {
            return "私有格式识别器：已识别格式特征，仍可能有尚未解码的私有字段。"
        }
        return raw
    }
    func candidates(for field: ProvenanceField) -> [Candidate] {
        candidates.filter { candidate in
            switch field {
            case .sourceType: return candidate.field == "source_type"
            case .device: return candidate.field.hasPrefix("capture_device")
            case .software: return candidate.field.contains("software")
            default: return false
            }
        }
    }
    var summary: String {
        if total_included_files == 0 { return "没有可读取的归档文件（文件夹可能为空）。" }
        if tool == nil { return "元数据工具不可用，尚未完成读取。" }
        let suffix = errors.isEmpty && warnings.isEmpty && inspected_file_count == total_included_files
            ? "各读取器未报告错误或警告；二进制元数据分类保留；内容载荷不导出，未定义结构不保证可解析。" : "存在未完成读取或读取警告，请查看详情。"
        return "元数据读取：\(inspected_file_count)/\(total_included_files) 个文件获得可识别元数据。" + suffix
    }
    func explanation(for field: ProvenanceField) -> String {
        switch field {
        case .purpose: return "用途由你填写，例如长期备份、项目交付留存；不会从元数据推断。"
        case .notes: return "备注由你决定，可选择无补充或填写额外说明。"
        default: break
        }
        if !candidates(for: field).isEmpty {
            return field == .sourceType
                ? "根据检测到的文件格式建议资料类别，待你确认；文件格式不能证明拍摄方式、下载来源或业务用途。"
                : "以下是元数据中记录的候选值，可能经过编辑；请确认实际设备或软件。"
        }
        if field == .device && !formatFindings.isEmpty {
            return "检测到品牌格式关联线索，但实际生成设备及型号尚未确认。可选择保留线索；这不会将其认定为摄像机或录像机品牌。"
        }
        if total_included_files == 0 { return "没有可用于此项建议的文件，请自行填写或明确选择未知。" }
        if tool == nil || inspected_file_count == 0 { return "尚无成功读取的文件，无法判断此项；请查看读取错误。" }
        if !errors.isEmpty || !warnings.isEmpty || inspected_file_count < total_included_files {
            return "在已读取且能识别的标签中没有找到此项候选；部分读取存在错误或警告，不能据此判断原文件没有相关信息。"
        }
        return field == .sourceType
            ? "已读取元数据，但没有可用于类别建议的文件格式信息，请自行填写。"
            : "已读取元数据，但没有找到可识别的\(field == .device ? "设备" : "软件")标签；这不代表文件没有元数据。"
    }
    func suggestion(for field: ProvenanceField) -> (zh: String, en: String) {
        let values = candidates(for: field)
        guard !values.isEmpty else { return ("", "") }
        func unique(_ items: [String]) -> [String] {
            var seen = Set<String>(); return items.filter { seen.insert($0).inserted }
        }
        // A single shared value needs no duplicated path/tag text in the answer.
        let zhValues = unique(values.map(\.value))
        let allEnglish = values.allSatisfy { !($0.en ?? "").isEmpty }
        if field == .sourceType || zhValues.count == 1 {
            return (zhValues.joined(separator: "；"), allEnglish ? unique(values.compactMap(\.en)).joined(separator: "; ") : "")
        }
        // Mixed devices/software retain per-file mappings, not one arbitrarily selected device.
        let files = unique(values.map(\.file))
        let zh = files.map { file in
            "\(unique(values.filter { $0.file == file }.map(\.value)).joined(separator: " / ")) [\(file)]"
        }.joined(separator: "; ")
        let en = allEnglish ? files.map { file in
            "\(unique(values.filter { $0.file == file }.compactMap(\.en)).joined(separator: " / ")) [\(file)]"
        }.joined(separator: "; ") : ""
        return (zh, en)
    }

}
struct DesktopResult: Decodable {
    let state: String
    let bundle: String?
}
struct RunOutcome {
    let status: Int32
    let output: String
}
enum Runtime {
    static var bundledRuntime: URL? {
        guard let resource = Bundle.main.resourceURL else { return nil }
        let runtime = resource.appendingPathComponent("Runtime")
        return FileManager.default.fileExists(atPath: runtime.path) ? runtime : nil
    }
    static var path: String {
        if let runtime = bundledRuntime { return runtime.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin" }
        return "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    static var python: URL? {
        if let runtime = bundledRuntime {
            let url = runtime.appendingPathComponent("python/bin/python3")
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
    static var engine: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Engine"), FileManager.default.fileExists(atPath: bundled.appendingPathComponent("desktop_bridge.py").path) { return bundled }
        return Bundle.module.url(forResource: "Engine", withExtension: nil)!
    }
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "PYTHONHOME", "PERL5LIB", "PERL5OPT", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"] { env.removeValue(forKey: key) }
        env["PATH"] = path; env["PYTHONUNBUFFERED"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"; env["PYTHONUTF8"] = "1"; env["PYTHONNOUSERSITE"] = "1"
        if let runtime = bundledRuntime { env["COLDARCHIVE_RUNTIME"] = runtime.path }
        else { env.removeValue(forKey: "COLDARCHIVE_RUNTIME") }
        return env
    }
}

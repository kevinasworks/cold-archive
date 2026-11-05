// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ConfirmationGroup: Identifiable {
    let id: String
    let title: String
    let english: String?
    let qualification: String
    let qualificationEnglish: String
    var evidence: [String]
    var files: Set<String>
    var answer: (zh: String, en: String?) {
        let mapping = evidence.joined(separator: "\n")
        return ("\(title)\(qualification)\n适用文件及依据：\n\(mapping)", english.map { "\($0)\(qualificationEnglish)\nApplicable files and evidence:\n\(mapping)" })
    }
}
extension MetadataReport {
    func confirmationGroups(for field: ProvenanceField) -> [ConfirmationGroup] {
        var groups: [ConfirmationGroup] = []
        func add(key: [String], title: String, english: String?, qualifier: String = "", qualifierEnglish: String = "", file: String, evidence: String) {
            let id = String(data: try! JSONEncoder().encode(key), encoding: .utf8)!
            if let i = groups.firstIndex(where: { $0.id == id }) {
                groups[i].files.insert(file)
                if !groups[i].evidence.contains(evidence) { groups[i].evidence.append(evidence) }
            } else {
                groups.append(.init(id: id, title: title, english: english, qualification: qualifier, qualificationEnglish: qualifierEnglish, evidence: [evidence], files: [file]))
            }
        }
        for c in candidates(for: field) {
            add(key: ["candidate", c.field, c.kind ?? "", c.value, c.en ?? ""], title: c.value,
                english: c.en.flatMap { $0.isEmpty ? nil : $0 }, file: c.file,
                evidence: "\(c.file) · \(c.tag) = \(c.raw_value ?? c.value) · \(c.tool)")
        }
        if field == .device {
            for f in formatFindings {
                add(key: ["format", f.brand, f.role, f.status, f.basis], title: f.brand, english: f.brand,
                    qualifier: "（格式关联线索；实际设备及型号未确认）",
                    qualifierEnglish: " (format association; actual device and model unconfirmed)",
                    file: f.file, evidence: "\(f.file) · \(f.scope) · \(f.tag) · \(f.basis)")
            }
        }
        return groups
    }
    struct DiagnosticGroup: Identifiable {
        var id: String { message }
        let message: String
        var files: Set<String>
    }
    var diagnosticGroups: [DiagnosticGroup] {
        var result: [DiagnosticGroup] = []
        let items = errors.map { ($0.file ?? "", "错误：" + Self.diagnostic($0.error)) }
            + warnings.map { ($0.file, "警告：" + Self.diagnostic($0.warning)) }
        for (file, message) in items {
            if let i = result.firstIndex(where: { $0.message == message }) { result[i].files.insert(file) }
            else { result.append(.init(message: message, files: [file])) }
        }
        return result
    }
}

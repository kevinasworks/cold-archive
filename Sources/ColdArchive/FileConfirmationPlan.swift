// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A partition of files for one question; candidates are not selectable file groups.
struct FileConfirmationGroup: Identifiable, Codable, Equatable {
    let id: String
    let category: String
    let categoryEnglish: String
    var files: [String]
    let suggestion: String
    let suggestionEnglish: String
    let conflict: Bool
    var evidence: [String]
}
struct GroupedAnswer: Codable, Equatable {
    let group_id: String
    let category: String
    let category_en: String
    let files: [String]
    let response: SubmittedAnswer
}
struct GroupedAnswerDocument: Encodable {
    let schema_version = 3
    let sources: [String]
    let grouped_answers: [String: [GroupedAnswer]]
}
extension MetadataReport {
    func fileConfirmationPlan(for field: ProvenanceField) -> [FileConfirmationGroup] {
        let universe = Set(file_paths ?? (candidates.map(\.file) + (brand_findings ?? []).map(\.file) + errors.compactMap(\.file) + warnings.map(\.file))).sorted()
        let categories = Dictionary(grouping: candidates(for: .sourceType), by: \.file)
        let values = Dictionary(grouping: candidates(for: field), by: \.file)
        let formats = Dictionary(grouping: formatFindings, by: \.file)
        var result: [FileConfirmationGroup] = []
        for file in universe {
            let types = categories[file] ?? []
            let category = Array(Set(types.map(\.value))).sorted().joined(separator: " / ")
            let categoryEN = Array(Set(types.compactMap(\.en))).sorted().joined(separator: " / ")
            let raw = values[file] ?? []
            // Same field/value from different readers is one fact; different values stay a conflict.
            let distinct = Dictionary(grouping: raw, by: { $0.field })
            let conflict = distinct.values.contains { Set($0.map(\.value)).count > 1 }
            let facts = Array(Set(raw.map { [$0.field, $0.value, $0.en ?? "", $0.kind ?? ""] })).sorted { $0.lexicographicallyPrecedes($1) }
            var zh = Array(Set(raw.map(\.value))).sorted().joined(separator: "；")
            var en = raw.allSatisfy { !($0.en ?? "").isEmpty } ? Array(Set(raw.compactMap(\.en))).sorted().joined(separator: "; ") : ""
            var evidence = raw.map { "\(file) · \($0.tag) = \($0.raw_value ?? $0.value) · \($0.tool)" }
            var keyFacts = facts
            if field == .device && raw.isEmpty {
                let clues = formats[file] ?? []
                keyFacts = Array(Set(clues.map { [$0.brand, $0.role, $0.status, $0.basis] })).sorted { $0.lexicographicallyPrecedes($1) }
                if !clues.isEmpty {
                    let brands = Array(Set(clues.map(\.brand))).sorted().joined(separator: ", ")
                    zh = "格式关联线索：\(brands)；实际生成设备及型号未确认。"
                    en = "Format association: \(brands); actual generating device and model unconfirmed."
                    evidence = clues.map { "\(file) · \($0.scope) · \($0.tag) · \($0.basis)" }
                }
            }
            let typeKey = Array(Set(types.map(\.value))).sorted()
            let key = String(data: try! JSONEncoder().encode([typeKey] + keyFacts), encoding: .utf8)!
            if let i = result.firstIndex(where: { $0.id == key }) {
                result[i].files.append(file)
                result[i].evidence += evidence
            } else {
                result.append(.init(id: key, category: category.isEmpty ? "未识别类别" : category,
                                    categoryEnglish: categoryEN.isEmpty ? "Unclassified files" : categoryEN,
                                    files: [file], suggestion: zh, suggestionEnglish: en,
                                    conflict: conflict, evidence: evidence))
            }
        }
        // Empty directories still require the five explicit answers.
        if result.isEmpty {
            result = [.init(id: "empty", category: "空文件夹", categoryEnglish: "Empty directories", files: [], suggestion: "", suggestionEnglish: "", conflict: false, evidence: [])]
        }
        return result
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct BatchArchiveDraft {
    struct Entry: Identifiable {
        let id = UUID()
        let source: URL
        let identity: String
        let isDirectory: Bool
        var name: String

        init?(source: URL) {
            guard source.isFileURL,
                  let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else { return nil }
            self.source = source.standardizedFileURL
            identity = self.source.resolvingSymlinksInPath().path
            isDirectory = values.isDirectory == true
            name = self.source.lastPathComponent
        }
    }

    var entries: [Entry] = []
    var destination: URL?

    /// Returns the number of selections that could not be added.
    mutating func append(_ urls: [URL]) -> Int {
        var identities = Set(entries.map(\.identity))
        var rejected = 0
        for url in urls {
            guard let entry = Entry(source: url) else {
                rejected += 1
                continue
            }
            if identities.insert(entry.identity).inserted { entries.append(entry) }
        }
        return rejected
    }

    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name != "." && name != ".." && !name.contains("/") && !name.contains("\0") &&
        !name.contains("\n") && !name.contains("\r")
    }

    var conflictingNames: Set<UUID> {
        let groups = Dictionary(grouping: entries) {
            $0.name.precomposedStringWithCanonicalMapping.lowercased()
        }
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }

    var nestedEntries: Set<UUID> {
        let folders = Set(entries.filter(\.isDirectory).map(\.identity))
        return Set(entries.filter { entry in
            var path = URL(fileURLWithPath: entry.identity)
            while path.path != "/" {
                path.deleteLastPathComponent()
                if folders.contains(path.path) { return true }
            }
            return false
        }.map(\.id))
    }

    var canSubmit: Bool {
        destination != nil && !entries.isEmpty &&
        entries.allSatisfy { Self.validName($0.name) } && conflictingNames.isEmpty
    }

    func validatedDestination() throws -> URL {
        guard canSubmit, let destination else {
            throw AppError.message("请添加来源、填写有效且互不重复的归档名称，并选择保存位置。")
        }
        let target = URL(fileURLWithPath: destination.path)
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw AppError.message("保存位置不可用，请重新选择目录。")
        }
        let targetPath = target.resolvingSymlinksInPath().path
        for entry in entries {
            guard let current = Entry(source: URL(fileURLWithPath: entry.source.path)),
                  current.identity == entry.identity, current.isDirectory == entry.isDirectory else {
                throw AppError.message("来源已变化或不可用，请移除后重新添加：\(entry.source.lastPathComponent)")
            }
            if entry.isDirectory {
                let prefix = entry.identity == "/" ? "/" : entry.identity + "/"
                if targetPath == entry.identity || targetPath.hasPrefix(prefix) {
                    throw AppError.message("保存位置不能位于所选文件夹内：\(entry.source.lastPathComponent)")
                }
            }
        }
        return target
    }
}

// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ConcurrencySettings: Equatable {
    var readMode: String
    var writeMode: String
    var readers: Int
    var writers: Int
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        let legacy=defaults.object(forKey:"adaptiveReading") as? Bool ?? true
        let read=defaults.string(forKey:"readConcurrencyMode") ?? (legacy ? "smart":"custom")
        return Self(readMode:read == "custom" ? "custom":"smart",
                    writeMode:defaults.string(forKey:"writeConcurrencyMode") == "custom" ? "custom":"smart",
                    readers:bounded(defaults.object(forKey:"customReaders") as? Int ?? (legacy ? 10:1)),
                    writers:bounded(defaults.object(forKey:"customWriters") as? Int ?? 5))
    }
    func save(_ defaults: UserDefaults = .standard) throws {
        try WriteBudget.configure(self)
        defaults.set(readMode,forKey:"readConcurrencyMode")
        defaults.set(writeMode,forKey:"writeConcurrencyMode")
        defaults.set(readers,forKey:"customReaders")
        defaults.set(writers,forKey:"customWriters")
    }
    static func bounded(_ value:Int)->Int {max(1,min(64,value))}
    var adaptive: Bool {readMode == "smart"}
    var readLimit: Int {adaptive ? WriteBudget.maximumReaders:readers}
    var writeLimit: Int {writeMode == "smart" ? WriteBudget.maximumWriters:writers}
}

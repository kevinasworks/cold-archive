// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// Current credentials get a fresh, owner-scoped ACL. Never rewrite the legacy
/// item's ACL/partition list or broaden it to other applications.
protocol NASCredentialBackend {
    func read(service: String, interaction: Bool) throws -> NASSecrets?
    func write(service: String, secrets: NASSecrets) throws
}
struct CredentialAccessError: LocalizedError {
    let status: OSStatus
    let migration: Bool
    var errorDescription: String? {
        if migration { return "旧版SNMP凭据需要重新授权。为避免旧钥匙串连续弹窗，请在此重新填写SNMP认证密码（启用隐私时也填写隐私密码）并保存；旧凭据仍保留。" }
        return "钥匙串凭据暂不可用。请解锁登录钥匙串后，在SNMP设置点击“重新授权读取凭据”；队列不会自动反复申请。"
    }
}
struct SystemNASCredentialBackend: NASCredentialBackend {
    var keychain:SecKeychain? = nil
    private static let interactionLock=NSRecursiveLock()
    // File-based keychains can ignore kSecUseAuthenticationUIFail. Serialize
    // this process-wide legacy switch and restore its previous value afterward.
    private static func withInteraction<T>(_ allowed:Bool,_ body:()->T) throws -> T {
        interactionLock.lock();defer{interactionLock.unlock()}
        var previous:DarwinBoolean=false
        let status=SecKeychainGetUserInteractionAllowed(&previous)
        guard status==errSecSuccess else {throw CredentialAccessError(status:status,migration:false)}
        let changed=SecKeychainSetUserInteractionAllowed(allowed && previous.boolValue)
        guard changed==errSecSuccess else {throw CredentialAccessError(status:changed,migration:false)}
        defer {
            let restored=SecKeychainSetUserInteractionAllowed(previous.boolValue)
            if restored != errSecSuccess {DiagnosticLog.shared.write(["event":"keychain_interaction_restore_error","system_error":restored])}
        }
        return body()
    }
    private func query(_ service: String) -> [String: Any] {
        var q:[String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
         kSecAttrAccount as String:"nas", kSecAttrSynchronizable as String:false]
        if let keychain {q[kSecMatchSearchList as String]=[keychain]}
        return q
    }
    func read(service: String, interaction: Bool) throws -> NASSecrets? {
        var q=query(service)
        q[kSecReturnData as String]=true
        q[kSecMatchLimit as String]=kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String]=interaction ? kSecUseAuthenticationUIAllow:kSecUseAuthenticationUIFail
        let began=ProcessInfo.processInfo.systemUptime
        let operation=UUID().uuidString
        let stage=service==NASCredentialStore.legacyService ? "legacy":"current"
        DiagnosticLog.shared.write(["event":"keychain_read_begin","operation":operation,"stage":stage,"enabled":interaction])
        var item:CFTypeRef?
        let status=try Self.withInteraction(interaction) {SecItemCopyMatching(q as CFDictionary,&item)}
        DiagnosticLog.shared.write(["event":"keychain_read_end","operation":operation,"stage":stage,"system_error":status,"duration_ms":(ProcessInfo.processInfo.systemUptime-began)*1000,"outcome":status==errSecSuccess ? "success":status==errSecItemNotFound ? "missing":"failed"])
        if status==errSecItemNotFound {return nil}
        guard status==errSecSuccess,let data=item as? Data else {throw CredentialAccessError(status:status,migration:stage=="legacy")}
        return try JSONDecoder().decode(NASSecrets.self,from:data)
    }
    func write(service: String, secrets: NASSecrets) throws {
        var value=NASSecrets(auth:secrets.auth,privacy:secrets.privacy)
        value.loadingError=nil
        let data=try JSONEncoder().encode(value)
        var q=query(service)
        q[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail
        let operation=UUID().uuidString
        DiagnosticLog.shared.write(["event":"keychain_write_begin","operation":operation,"stage":"current"])
        let status=try Self.withInteraction(false) {
            var status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
            if status==errSecItemNotFound {
                q.removeValue(forKey:kSecMatchSearchList as String)
                if let keychain {q[kSecUseKeychain as String]=keychain}
                q[kSecValueData as String]=data
                q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlocked
                status=SecItemAdd(q as CFDictionary,nil)
            }
            return status
        }
        DiagnosticLog.shared.write(["event":"keychain_write_end","operation":operation,"stage":"current","system_error":status,"outcome":status==errSecSuccess ? "success":"failed"])
        guard status==errSecSuccess else {throw CredentialAccessError(status:status,migration:false)}
    }
}

final class NASCredentialStore {
    static let service="local.coldarchive.snmp.v2"
    static let legacyService="local.coldarchive.snmp"
    private let backend:NASCredentialBackend
    private let cache=CredentialSessionCache()
    private let lock=NSRecursiveLock()
    init(backend:NASCredentialBackend) {self.backend=backend}
    func load(retry:Bool=false) throws -> NASSecrets {
        lock.lock();defer{lock.unlock()}
        return try cache.load(retry:retry) {
            // Only an explicit settings action may ask the OS to authorize a
            // current item. Legacy items are NEVER queried interactively.
            if let value=try backend.read(service:Self.service,interaction:retry) {return value}
            do {
                guard let legacy=try backend.read(service:Self.legacyService,interaction:false) else {return NASSecrets()}
                try backend.write(service:Self.service,secrets:legacy)
                DiagnosticLog.shared.write(["event":"keychain_migration","outcome":"success","code":"legacy_preserved"])
                return legacy
            } catch {
                DiagnosticLog.shared.write(["event":"keychain_migration","outcome":"failed","code":"manual_credentials_required"])
                // Do not mislabel disk/write/decode failures as successful migration.
                throw error
            }
        }
    }
    func save(_ value:NASSecrets) throws {
        lock.lock();defer{lock.unlock()}
        guard value.loadingError==nil,!value.auth.isEmpty else {throw AppError.message("请先填写SNMP认证密码或社群，再保存凭据。")}
        if cache.matches(value) {return}
        try backend.write(service:Self.service,secrets:value)
        cache.saved(value)
    }
}
enum NASKeychain {
    private static let store=NASCredentialStore(backend:SystemNASCredentialBackend())
    static func load(retry:Bool=false) throws -> NASSecrets {try store.load(retry:retry)}
    static func save(_ secrets:NASSecrets) throws {try store.save(secrets)}
}

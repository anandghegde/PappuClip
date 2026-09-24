import Foundation
import PappuCore
import Security
import Synchronization

/// Where a `secret` option's value lives (§8.9, SEC-3): never the store, which is exported, snapshotted
/// and restored without a filter precisely because nothing in it is secret.
///
/// Keyed by install, instance and option, as architecture §9.4 has it. The install is part of the key so
/// that two separate installs of one manifest identifier cannot read each other's API keys, and so that
/// uninstalling can take every value an install ever stored without knowing which options it had.
public protocol SecretStore: Sendable {
    func secret(_ option: String, of instance: InstanceID, owner: LocalIdentity) -> String?
    /// An empty value removes the entry: "no key" and "an empty key" are the same to every consumer.
    func setSecret(_ value: String, for option: String, of instance: InstanceID, owner: LocalIdentity) throws
    func removeSecrets(of owner: LocalIdentity) throws
}

extension SecretStore {
    /// Every `secret` option `options` declares, as `OptionValues.effective` takes them.
    public func secrets(for options: [OptionManifest], of instance: InstanceID, owner: LocalIdentity) -> [String: String] {
        var values: [String: String] = [:]
        for option in options where option.kind == .secret {
            guard let identifier = option.identifier, let value = secret(identifier, of: instance, owner: owner) else { continue }
            values[identifier] = value
        }
        return values
    }

    static func account(_ option: String, of instance: InstanceID, owner: LocalIdentity) -> String {
        "\(owner)/\(instance)/\(option)"
    }
}

/// The login Keychain, as generic passwords under one service.
///
/// `kSecAttrSynchronizable` is never set: a secret stays on the device that was given it until sync
/// (M6) decides otherwise, and an option's `keychain: sync` is read then, not now.
public struct KeychainSecretStore: SecretStore {
    public static let service = "app.pappuclip.extension-secret"

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case keychain(OSStatus)

        public var description: String {
            switch self {
            case .keychain(let status):
                "The Keychain refused the change (\(SecCopyErrorMessageString(status, nil) as String? ?? String(status)))."
            }
        }
    }

    public init() {}

    public func secret(_ option: String, of instance: InstanceID, owner: LocalIdentity) -> String? {
        var query = base(Self.account(option, of: instance, owner: owner))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String, for option: String, of instance: InstanceID, owner: LocalIdentity) throws {
        let query = base(Self.account(option, of: instance, owner: owner))
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        } else if status != errSecSuccess {
            throw Failure.keychain(status)
        }
    }

    /// Every account that starts with the install's identity. The Keychain cannot match on a prefix,
    /// so the accounts are listed and deleted one by one.
    public func removeSecrets(of owner: LocalIdentity) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        let prefix = "\(owner)/"
        for attributes in result as? [[String: Any]] ?? [] {
            guard let account = attributes[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { continue }
            query = base(account)
            let deleted = SecItemDelete(query as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Failure.keychain(deleted) }
        }
    }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// For tests, and for anything that must not touch the user's Keychain.
public final class InMemorySecretStore: SecretStore {
    private let values = Mutex<[String: String]>([:])

    public init() {}

    public func secret(_ option: String, of instance: InstanceID, owner: LocalIdentity) -> String? {
        values.withLock { $0[Self.account(option, of: instance, owner: owner)] }
    }

    public func setSecret(_ value: String, for option: String, of instance: InstanceID, owner: LocalIdentity) throws {
        values.withLock { $0[Self.account(option, of: instance, owner: owner)] = value.isEmpty ? nil : value }
    }

    public func removeSecrets(of owner: LocalIdentity) throws {
        values.withLock { stored in stored = stored.filter { !$0.key.hasPrefix("\(owner)/") } }
    }

    /// How many values are held, so a test can see an uninstall took them.
    public var count: Int { values.withLock(\.count) }
}

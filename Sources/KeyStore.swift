import Foundation
import Security

// MARK: - KeyStore

/// Abstraction over "where does a secret API key live" so the precedence
/// logic in Config.load(store:) and the Save/Test/import logic in
/// SettingsWindow can be exercised in --self-test against an in-memory fake
/// instead of the real macOS Keychain.
protocol KeyStore: Sendable {
    func get(_ account: String) -> String?
    func set(_ account: String, value: String) throws
    func delete(_ account: String) throws
}

/// Stable account names for the two keys this app owns in the Keychain —
/// shared by Config.load, SettingsWindow's rows, and the legacy-JSON field
/// names (they match on purpose: "openrouter_key" / "xai_key" either way),
/// so the mapping lives in exactly one place.
enum KeyAccount {
    static let openRouter = "openrouter_key"
    static let xai = "xai_key"
}

enum KeyStoreError: LocalizedError {
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}

/// A KeyStore backed by Security.framework's SecItem* API — service
/// "local.claude-usage-menubar", one generic-password item per account.
///
/// Deliberately NOT the /usr/bin/security subprocess Keychain (main.swift)
/// and AntigravityProvider (Providers.swift) use elsewhere in this app —
/// that subprocess path exists for reading OTHER apps' items (Claude Code's
/// OAuth token, Antigravity's go-keyring blob), where this app has no ACL
/// and a CLI round-trip is the only option. For items this app itself
/// creates, the SecItem* API is cleaner and, once the item's ACL grants this
/// app access, prompt-free for the creating app.
struct KeychainStore: KeyStore {
    static let service = "local.claude-usage-menubar"

    func get(_ account: String) -> String? {
        var query = Self.baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            // Any failure — item absent, a locked login keychain
            // (errSecInteractionNotAllowed, e.g. a headless --once over
            // SSH), an ACL denial after an ad-hoc re-sign — degrades to "no
            // key" rather than throwing, so callers (Config.load) fall
            // through to the legacy JSON/no-key tiers instead of crashing.
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeyStoreError.osStatus(errSecParam)
        }
        var addQuery = Self.baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }

        guard addStatus == errSecDuplicateItem else {
            throw KeyStoreError.osStatus(addStatus)
        }
        // Item already exists (a prior Save, or a value from another run) —
        // SecItemAdd doesn't overwrite, so fall back to SecItemUpdate.
        let updateStatus = SecItemUpdate(
            Self.baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw KeyStoreError.osStatus(updateStatus)
        }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.osStatus(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

// MARK: - Save semantics

/// "Clear the field, Save" must remove the key rather than store the empty
/// string — pulled out as a pure function (rather than inlined in
/// SettingsWindow's Save button action) so --self-test can assert the
/// semantics directly against a fake KeyStore without driving a real
/// NSButton click.
enum APIKeySave {
    /// Keys get pasted, and a copy out of a terminal or a web page routinely
    /// carries a trailing newline or space. Stored verbatim that becomes
    /// `Bearer sk-…\n`, which earns a 401 the user cannot diagnose — the
    /// field looks correct. Normalise in one place so Save, Test, and the
    /// empty-means-delete check can never disagree about what the key is.
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func apply(_ text: String, account: String, store: KeyStore) throws {
        let value = normalize(text)
        if value.isEmpty {
            try store.delete(account)
        } else {
            try store.set(account, value: value)
        }
    }
}

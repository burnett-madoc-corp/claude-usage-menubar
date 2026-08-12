import Foundation

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
    case blocked
    case commandFailed(action: String, code: Int32)
    case notStored(account: String)

    var errorDescription: String? {
        switch self {
        case .blocked:
            return "The Keychain did not answer in time."
        case .commandFailed(let action, let code):
            return "Keychain \(action) failed: security exited \(code)."
        case .notStored(let account):
            return "The Keychain reported success for \(account) but stored nothing."
        }
    }
}

// MARK: - security(1) argument construction

/// The argument vectors and output parsing, split out from the process
/// plumbing so --self-test can assert them directly. A wrong flag here is
/// invisible until it writes to the wrong service or silently stores an
/// empty value, and neither shows up as a build failure.
enum KeychainCommand {
    /// `security` reports a missing item with this exit status. It is a
    /// normal outcome — no key configured yet — not an error.
    static let itemNotFound: Int32 = 44
    /// ...and a colliding add with this one, which after a delete means the
    /// delete did not take, so it must surface rather than be swallowed.
    static let duplicateItem: Int32 = 45

    static func find(service: String, account: String) -> [String] {
        ["find-generic-password", "-s", service, "-a", account, "-w"]
    }

    static func add(service: String, account: String, value: String) -> [String] {
        // Deliberately no -U. Updating in place needs *decrypt* authorization
        // on the existing item, which is exactly what an item left over from
        // the Security.framework era will not grant without a dialog. set()
        // deletes first instead, so a surviving item means the delete failed
        // and the resulting "duplicate" error is worth seeing.
        ["add-generic-password", "-s", service, "-a", account, "-w", value]
    }

    static func delete(service: String, account: String) -> [String] {
        ["delete-generic-password", "-s", service, "-a", account]
    }

    /// `security -w` writes the password followed by one newline. Strip that
    /// and nothing else: the stored value is already normalized by
    /// APIKeySave.normalize, so any remaining whitespace would be part of the
    /// key itself.
    ///
    /// A value that is not valid UTF-8 comes back as hex digits instead, which
    /// would be silently wrong — but every value here was written by
    /// APIKeySave from text the user typed, so it round-trips as UTF-8.
    static func parse(_ data: Data) -> String? {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? nil : text
    }
}

// MARK: - KeychainStore

/// This app's own keys, in the login Keychain, reached through
/// `/usr/bin/security`.
///
/// Not Security.framework's SecItem* API, which is the obvious choice and was
/// the original one. macOS gates a Keychain item on *code identity*, twice
/// over: the item's ACL names trusted applications, and its partition list
/// names the signing identities allowed to use it. Both are filled in from
/// whoever creates the item. This app is ad-hoc signed, so it has no stable
/// identity — only a cdhash that changes with every build — and an item
/// written through SecItemAdd came out pinned to the exact binary that wrote
/// it, `Partitions: [cdhash:596a1133…]`. The next build was a stranger to it,
/// macOS asked for the login password, and "Always Allow" granted access to a
/// binary that was about to be replaced. The dialog therefore came back after
/// every single install, forever.
///
/// Routing through `security` borrows an identity that does not change:
/// the item's partition becomes `apple-tool:` and its trusted application is
/// `security` itself, neither of which cares what this app's cdhash is
/// today. It is also the path AntigravityProvider and the Claude Code token
/// reader already take, and the reason those reads never prompted.
///
/// The trade-off is explicit: any process running as this user can also run
/// `security` and read these keys back. That was already true of every other
/// Keychain item this app reads, and the code-identity gate it replaces was
/// not buying confidentiality — an ad-hoc app cannot hold one — it was only
/// buying a dialog.
struct KeychainStore: KeyStore {

    static let service = "local.claude-usage-menubar"

    func get(_ account: String) -> String? {
        switch KeychainCLI.read(KeychainCommand.find(service: Self.service, account: account)) {
        case .success(let data):
            return KeychainCommand.parse(data)
        case .failure:
            // Item absent, a locked login keychain (a headless --once over
            // SSH), a Keychain that never answered — all degrade to "no key"
            // rather than throwing, so Config.load falls through to the
            // legacy JSON/no-key tiers instead of crashing.
            return nil
        }
    }

    func set(_ account: String, value: String) throws {
        // Delete first: needs no authorization on the old item, so it
        // overwrites a stale Security.framework-era entry without a prompt.
        // A miss here is the normal case — nothing was stored yet.
        _ = KeychainCLI.read(KeychainCommand.delete(service: Self.service, account: account))

        switch KeychainCLI.read(KeychainCommand.add(service: Self.service, account: account, value: value)) {
        case .success:
            break
        case .failure(.blocked):
            throw KeyStoreError.blocked
        case .failure(.failed(let code)):
            throw KeyStoreError.commandFailed(action: "save", code: code)
        }

        // Read back before reporting success. `security` exits 0 having
        // stored an empty password if the value never reached it — measured,
        // not hypothetical — and a Settings window that says "Saved" over a
        // key that is not there is the worst possible outcome.
        guard get(account) == value else { throw KeyStoreError.notStored(account: account) }
    }

    func delete(_ account: String) throws {
        switch KeychainCLI.read(KeychainCommand.delete(service: Self.service, account: account)) {
        case .success:
            return
        case .failure(.failed(KeychainCommand.itemNotFound)):
            // "Clear the field, Save" with nothing stored is a no-op, not a
            // failure the user needs to hear about.
            return
        case .failure(.blocked):
            throw KeyStoreError.blocked
        case .failure(.failed(let code)):
            throw KeyStoreError.commandFailed(action: "delete", code: code)
        }
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

// MARK: - Legacy config.json import

/// L9: pulled out of SettingsWindow's importLegacyKeys() (which previously
/// used `if (try? keyStore.set(…)) != nil` — swallowing whatever
/// KeyStoreError the Keychain returned, so a real failure looked identical
/// to "nothing to import" with no explanation) so the error-surfacing
/// behaviour is testable against a fake store without driving a real
/// NSButton click.
enum LegacyImport {
    struct Result {
        var importedCount: Int
        var errors: [String]
    }

    /// Only imports a key that isn't already in the Keychain — Keychain
    /// always wins over the legacy file (see Config's precedence doc).
    static func run(legacy: (openRouterKey: String?, xaiKey: String?), store: KeyStore) -> Result {
        var imported = 0
        var errors: [String] = []
        if let value = legacy.openRouterKey, store.get(KeyAccount.openRouter) == nil {
            do { try store.set(KeyAccount.openRouter, value: value); imported += 1 }
            catch { errors.append("OpenRouter: \(error.localizedDescription)") }
        }
        if let value = legacy.xaiKey, store.get(KeyAccount.xai) == nil {
            do { try store.set(KeyAccount.xai, value: value); imported += 1 }
            catch { errors.append("Grok (xAI): \(error.localizedDescription)") }
        }
        return Result(importedCount: imported, errors: errors)
    }
}

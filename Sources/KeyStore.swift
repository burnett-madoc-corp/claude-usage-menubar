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

/// Stable account name for the one key this app owns in the Keychain —
/// shared by Config.load, SettingsWindow's row, and the legacy-JSON field
/// name (they match on purpose: "openrouter_key" either way), so the mapping
/// lives in exactly one place.
enum KeyAccount {
    static let openRouter = "openrouter_key"
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

    /// One argument, quoted for `security -i`'s stdin command line rather
    /// than handed to the process as an argv element: wrap in double quotes
    /// and backslash-escape the two characters that would otherwise end the
    /// quoted span early or start a stray escape — `\` and `"` themselves.
    /// Verified against the real `security -i` binary: a value containing
    /// both round-trips byte-for-byte through add then find.
    static func quoteForStdin(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for char in value {
            if char == "\\" || char == "\"" { escaped.append("\\") }
            escaped.append(char)
        }
        return "\"\(escaped)\""
    }

    /// A full `security -i` command line, fed on stdin rather than built as
    /// an argv array — see KeychainStore's doc comment for why a `-w` value
    /// must never be an argv element. `security -i` parses this the same way
    /// it would parse the equivalent argv, exit code included, so the
    /// itemNotFound/duplicateItem handling in KeychainStore.set is unchanged.
    ///
    /// Deliberately no -U. Updating in place needs *decrypt* authorization
    /// on the existing item, which is exactly what an item left over from
    /// the Security.framework era will not grant without a dialog. set()
    /// deletes first instead, so a surviving item means the delete failed
    /// and the resulting "duplicate" error is worth seeing.
    static func addLine(service: String, account: String, value: String) -> String {
        "add-generic-password -s \(quoteForStdin(service)) -a \(quoteForStdin(account)) -w \(quoteForStdin(value))\n"
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
/// today. It is also the path the Claude Code token reader already takes, and
/// the reason that read never prompted.
///
/// The trade-off is explicit: any process running as this user can also run
/// `security` and read these keys back. That was already true of every other
/// Keychain item this app reads, and the code-identity gate it replaces was
/// not buying confidentiality — an ad-hoc app cannot hold one — it was only
/// buying a dialog.
///
/// Saving a value still goes through `security -i` on stdin rather than a
/// `-w` argv element, though, for a cheaper and unrelated reason: an argv
/// element is visible in `ps`/Activity Monitor to *every* local process for
/// the entire lifetime of the child, with no `security` invocation of their
/// own required to see it. The trade-off above concedes the value is not
/// confidential from a process that goes looking for it; it should not also
/// be handed to one that is not looking, just because it walked past `ps`.
/// Accounts whose read parked behind an approval dialog, for the life of this
/// process.
///
/// An item written by a build from before this app moved to `security` is
/// pinned to that build's cdhash, so macOS will not hand it over without the
/// login password — and it asks again on the next poll, and the one after
/// that. Asking again after somebody has already left the dialog unanswered is
/// nagging, not diligence.
///
/// Process-wide rather than per-instance because the polling path and the
/// settings window hold separate `KeychainStore` values and must not each get
/// their own turn to ask. Deliberately *not* persisted: a flag that outlives
/// the process would silently ignore a perfectly good key after one bad
/// moment, e.g. a login keychain that happened to be locked.
final class BlockedAccounts: @unchecked Sendable {
    static let shared = BlockedAccounts()
    private let lock = NSLock()
    private var accounts: Set<String> = []

    func contains(_ account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accounts.contains(account)
    }

    func insert(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        accounts.insert(account)
    }

    func remove(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        accounts.remove(account)
    }
}

struct KeychainStore: KeyStore {

    static let service = "local.claude-usage-menubar"

    func get(_ account: String) -> String? {
        // A read nobody answered stays unanswered until something writes the
        // account — writing repairs the item in passing, so the next read
        // after a Save is worth making.
        if BlockedAccounts.shared.contains(account) { return nil }

        switch KeychainCLI.read(KeychainCommand.find(service: Self.service, account: account)) {
        case .success(let data):
            return KeychainCommand.parse(data)
        case .failure(.blocked):
            BlockedAccounts.shared.insert(account)
            return nil
        case .failure:
            // Item absent, or a locked login keychain (a headless --once over
            // SSH) — both degrade to "no key" rather than throwing, so
            // Config.load falls through to the legacy JSON/no-key tiers
            // instead of crashing. Not recorded as blocked: these come back
            // immediately and put nothing on screen, so retrying next poll
            // costs nobody anything.
            return nil
        }
    }

    func set(_ account: String, value: String) throws {
        // Delete first: needs no authorization on the old item, so it
        // overwrites a stale Security.framework-era entry without a prompt.
        // A miss here is the normal case — nothing was stored yet.
        _ = KeychainCLI.read(KeychainCommand.delete(service: Self.service, account: account))

        switch KeychainCLI.readStdin(KeychainCommand.addLine(service: Self.service, account: account, value: value)) {
        case .success:
            break
        case .failure(.blocked):
            throw KeyStoreError.blocked
        case .failure(.failed(let code)):
            throw KeyStoreError.commandFailed(action: "save", code: code)
        }

        // The item is this app's again, written through security like every
        // other one, so whatever made it unreadable is gone. Cleared before
        // the read-back below, which would otherwise short-circuit on it.
        BlockedAccounts.shared.remove(account)

        // Read back before reporting success. `security` exits 0 having
        // stored an empty password if the value never reached it — measured,
        // not hypothetical — and a Settings window that says "Saved" over a
        // key that is not there is the worst possible outcome.
        guard get(account) == value else { throw KeyStoreError.notStored(account: account) }
    }

    func delete(_ account: String) throws {
        BlockedAccounts.shared.remove(account)
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
    static func run(legacyOpenRouterKey: String?, store: KeyStore) -> Result {
        var imported = 0
        var errors: [String] = []
        if let value = legacyOpenRouterKey, store.get(KeyAccount.openRouter) == nil {
            do { try store.set(KeyAccount.openRouter, value: value); imported += 1 }
            catch { errors.append("OpenRouter: \(error.localizedDescription)") }
        }
        return Result(importedCount: imported, errors: errors)
    }
}

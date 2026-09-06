import Foundation

// MARK: - KeyStore

/// Secret API key storage abstraction for production and self-test implementations.
protocol KeyStore: Sendable {
    func get(_ account: String) -> String?
    func set(_ account: String, value: String) throws
    func delete(_ account: String) throws
}

/// Stable account identifiers for keys stored in the Keychain.
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

/// Builds argument vectors and parses output for security(1) CLI commands.
enum KeychainCommand {
    /// Exit status returned when a queried item is absent.
    static let itemNotFound: Int32 = 44
    /// Exit status returned on item collision.
    static let duplicateItem: Int32 = 45

    static func find(service: String, account: String) -> [String] {
        ["find-generic-password", "-s", service, "-a", account, "-w"]
    }

    /// Quotes an argument for security -i stdin by escaping quotes and backslashes.
    static func quoteForStdin(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for char in value {
            if char == "\\" || char == "\"" { escaped.append("\\") }
            escaped.append(char)
        }
        return "\"\(escaped)\""
    }

    /// Generates add-generic-password command line fed through stdin to avoid exposing secret in argv.
    static func addLine(service: String, account: String, value: String) -> String {
        "add-generic-password -s \(quoteForStdin(service)) -a \(quoteForStdin(account)) -w \(quoteForStdin(value))\n"
    }

    static func delete(service: String, account: String) -> [String] {
        ["delete-generic-password", "-s", service, "-a", account]
    }

    /// Strips trailing newline from security output.
    static func parse(_ data: Data) -> String? {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? nil : text
    }
}

// MARK: - KeychainStore

/// Manages Keychain secrets via /usr/bin/security to avoid ad-hoc signing prompt churn.
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
        // Skip reads for blocked accounts until a new value is written.
        if BlockedAccounts.shared.contains(account) { return nil }

        switch KeychainCLI.read(KeychainCommand.find(service: Self.service, account: account)) {
        case .success(let data):
            return KeychainCommand.parse(data)
        case .failure(.blocked):
            BlockedAccounts.shared.insert(account)
            return nil
        case .failure:
            // Treat absent item or locked keychain as missing key without blocking future polls.
            return nil
        }
    }

    func set(_ account: String, value: String) throws {
        // Delete existing entry first to prevent authorization prompts.
        _ = KeychainCLI.read(KeychainCommand.delete(service: Self.service, account: account))

        switch KeychainCLI.readStdin(KeychainCommand.addLine(service: Self.service, account: account, value: value)) {
        case .success:
            break
        case .failure(.blocked):
            throw KeyStoreError.blocked
        case .failure(.failed(let code)):
            throw KeyStoreError.commandFailed(action: "save", code: code)
        }

        // Clear blocked state before read-back verification.
        BlockedAccounts.shared.remove(account)

        // Verify key was persisted before confirming success.
        guard get(account) == value else { throw KeyStoreError.notStored(account: account) }
    }

    func delete(_ account: String) throws {
        BlockedAccounts.shared.remove(account)
        switch KeychainCLI.read(KeychainCommand.delete(service: Self.service, account: account)) {
        case .success:
            return
        case .failure(.failed(KeychainCommand.itemNotFound)):
            // Deleting a nonexistent key is treated as success.
            return
        case .failure(.blocked):
            throw KeyStoreError.blocked
        case .failure(.failed(let code)):
            throw KeyStoreError.commandFailed(action: "delete", code: code)
        }
    }
}

// MARK: - Save semantics

/// Coordinates key persistence and deletion semantics for settings input.
enum APIKeySave {
    /// Normalizes API keys by trimming surrounding whitespace and newlines.
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

/// Imports legacy configuration keys into the KeyStore.
enum LegacyImport {
    struct Result {
        var importedCount: Int
        var errors: [String]
    }

    /// Imports legacy keys only when absent from the primary KeyStore.
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

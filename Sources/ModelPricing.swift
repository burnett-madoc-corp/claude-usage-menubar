import Foundation

// MARK: - OpenRouter model pricing
//
// The SPENT column's estimated cell answers "what would these tokens have
// cost on the API?" — for sessions running on a Claude / Codex / agy plan,
// where nothing bills per token, the plan fee hides the burn. The prices are
// OpenRouter's: GET openrouter.ai/api/v1/models is public (no key), and each
// model carries a `pricing` block of USD-PER-TOKEN strings:
//
//   {"id": "anthropic/claude-sonnet-4.5",
//    "pricing": {"prompt": "0.000003", "completion": "0.000015",
//                "input_cache_read": "0.0000003",
//                "input_cache_write": "0.00000375", ...}}
//
// Per-token values are converted to USD per 1M tokens once, at parse time.
// The catalog is fetched at most once a day, cached to disk so a launch with
// no network still prices sessions, and never blocks a session row: an empty
// catalog just means the estimate cell stays "—" until the first fetch lands.
//
// Transcript model ids never match OpenRouter's catalog verbatim — Claude
// writes dated ids ("claude-sonnet-4-5-20250929"), agy writes variant ids
// ("gemini-3.1-pro-low"), OpenRouter lists "anthropic/claude-sonnet-4.5" —
// so lookup normalizes both sides (lowercase, separators dropped, trailing
// date stamped off) and prefers the most specific catalog entry contained
// in the query. Every step is pure and self-tested; nothing fabricates a
// price for a model the catalog cannot name.

/// USD per 1M tokens.
struct ModelPrice: Equatable, Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
}

enum OpenRouterCatalog {

    struct Catalog: Sendable {
        var byFullId: [String: ModelPrice] = [:]      // "anthropic/claude-sonnet-4.5"
        var byBareId: [String: ModelPrice] = [:]      // "claude-sonnet-4.5"
        /// Normalized bare ids kept sorted longest-first, so containment
        /// lookup deterministically prefers the most specific entry.
        var normalizedKeys: [String] = []
        var normalizedPrices: [String: ModelPrice] = [:]
    }

    // MARK: Parsing

    /// Pure parser for the /api/v1/models payload. Models with no numeric
    /// `prompt` price are skipped; a zero price is kept (free models are a
    /// real price, not an absence of one).
    static func parse(data: Data) -> Catalog {
        var catalog = Catalog()
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = obj["data"] as? [[String: Any]]
        else { return catalog }
        for model in models {
            guard let id = model["id"] as? String, !id.isEmpty,
                  let pricing = model["pricing"] as? [String: Any],
                  let prompt = Double(pricing["prompt"] as? String ?? ""),
                  let completion = Double(pricing["completion"] as? String ?? "")
            else { continue }
            let price = ModelPrice(
                input: prompt * 1_000_000,
                output: completion * 1_000_000,
                cacheRead: (Double(pricing["input_cache_read"] as? String ?? "") ?? prompt) * 1_000_000,
                cacheWrite: (Double(pricing["input_cache_write"] as? String ?? "") ?? prompt) * 1_000_000
            )
            let bare = id.split(separator: "/").last.map(String.init) ?? id
            catalog.byFullId[id] = price
            catalog.byBareId[bare] = price
            let key = normalize(bare)
            if catalog.normalizedPrices[key] == nil { catalog.normalizedKeys.append(key) }
            catalog.normalizedPrices[key] = price
        }
        catalog.normalizedKeys.sort { $0.count > $1.count }
        return catalog
    }

    /// Transcript id → lookup key: lowercase, drop any `[variant]` suffix,
    /// drop a trailing date stamp ("…-20250929") and the trailing effort/
    /// variant word agy and OpenRouter decorate ids with ("-low", "-preview",
    /// "-thinking" — "gemini-3.1-pro-low" and OpenRouter's
    /// "gemini-3.1-pro-preview" must land on the same key), then drop
    /// separators so "claude-sonnet-4-5" and "claude-sonnet-4.5" agree.
    /// OpenRouter embeds no dates, so stripping one never collides with a
    /// real version number (versions are single digits: 4.5, 3.1).
    static func normalize(_ raw: String) -> String {
        var id = raw.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        let suffixes = ["low", "high", "medium", "minimal", "xhigh", "thinking", "preview"]
        var changed = true
        while changed {
            changed = false
            if let range = id.range(of: #"-?\d{8}$"#, options: .regularExpression) {
                id = String(id[..<range.lowerBound])
                changed = true
            }
            for suffix in suffixes where id.hasSuffix("-\(suffix)") {
                id = String(id.dropLast(suffix.count + 1))
                changed = true
            }
        }
        return id.filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Lookup

    /// Exact bare-id match first, then normalized equality, then the longest
    /// catalog key contained in the normalized query ("gemini31pro" inside
    /// "gemini31prolow"). No match — unknown model, empty catalog — yields
    /// nil and the row renders "—" rather than an invented price.
    static func price(for model: String?, in catalog: Catalog) -> ModelPrice? {
        guard let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty
        else { return nil }
        let bare = model.split(separator: "/").last.map(String.init) ?? model
        if let price = catalog.byFullId[model] { return price }
        if let price = catalog.byBareId[bare] { return price }
        let key = normalize(bare)
        if let price = catalog.normalizedPrices[key] { return price }
        for candidate in catalog.normalizedKeys where key.contains(candidate) {
            return catalog.normalizedPrices[candidate]
        }
        return nil
    }

    // MARK: Estimation

    /// API-equivalent spend for one session. `input` must be the FRESH
    /// (non-cached) input count — callers subtract the cache components they
    /// tracked; cacheRead/cacheWrite default to 0 for sources (agy) that do
    /// not report them. Prices are per 1M, hence the 1e6 divisor.
    static func estimate(model: String?, catalog: Catalog,
                         input: Int64, output: Int64,
                         cacheRead: Int64 = 0, cacheWrite: Int64 = 0) -> Double? {
        guard let price = price(for: model, in: catalog) else { return nil }
        let total = Double(input) * price.input
            + Double(output) * price.output
            + Double(cacheRead) * price.cacheRead
            + Double(cacheWrite) * price.cacheWrite
        return total / 1_000_000
    }
}

// MARK: - Catalog store

/// Fetches and caches the OpenRouter catalog. `catalog()` never blocks on
/// the network: it returns the in-memory catalog immediately (loading the
/// disk cache once, on first call) and refreshes in the background when the
/// last successful fetch is older than `refreshInterval`. A failed fetch
/// keeps serving the stale catalog — estimates degrade to "—" only when no
/// catalog was ever obtained.
actor ModelPricingStore {
    static let shared = ModelPricingStore()

    static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    static let refreshInterval: TimeInterval = 24 * 3600

    /// Injected so --self-test can point the disk cache at a temp dir.
    var cacheURL: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first!
        .appendingPathComponent("ClaudeUsage/openrouter-model-pricing.json")

    static let failureRetryInterval: TimeInterval = 5 * 60

    private var catalog = OpenRouterCatalog.Catalog()
    private var catalogLoaded = false
    private var lastSuccessAt: Date?
    private var lastAttemptAt: Date?
    private var refreshTask: Task<Void, Never>?

    /// Returns the catalog immediately — memory, seeded from the disk cache
    /// on first call — and refreshes in the background only when due: a
    /// successful fetch is good for a day; a failed one is retried on the
    /// failure cadence so first-run-with-no-network does not wait a day to
    /// try again. Actor reentrancy is bounded by `refreshTask`: at most one
    /// fetch in flight, slot cleared when it settles.
    func catalog(now: Date = Date()) -> OpenRouterCatalog.Catalog {
        if !catalogLoaded {
            catalogLoaded = true
            if let (loaded, fetchedAt) = Self.loadDiskCache(url: cacheURL) {
                catalog = loaded
                lastSuccessAt = fetchedAt
            }
        }
        let due: Bool
        if let lastSuccessAt {
            due = now.timeIntervalSince(lastSuccessAt) > Self.refreshInterval
        } else {
            due = now.timeIntervalSince(lastAttemptAt ?? .distantPast) > Self.failureRetryInterval
        }
        if due { startRefresh() }
        return catalog
    }

    private func startRefresh() {
        guard refreshTask == nil else { return }
        lastAttemptAt = Date()
        refreshTask = Task {
            if let fresh = await Self.fetch(modelsURL: Self.modelsURL, cacheURL: cacheURL) {
                self.catalog = fresh
                self.lastSuccessAt = Date()
            }
            self.refreshTask = nil
        }
    }

    private nonisolated static func fetch(modelsURL: URL, cacheURL: URL) async -> OpenRouterCatalog.Catalog? {
        guard let json = try? await Net.getJSON(modelsURL, bearer: "") else { return nil }
        let catalog = OpenRouterCatalog.parse(data: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        writeDiskCache(catalog: catalog, at: Date(), url: cacheURL)
        return catalog
    }

    // MARK: Disk cache

    nonisolated static func writeDiskCache(catalog: OpenRouterCatalog.Catalog, at: Date, url: URL) {
        var models: [String: [String: Double]] = [:]
        for (id, price) in catalog.byFullId {
            models[id] = ["in": price.input, "out": price.output,
                          "cr": price.cacheRead, "cw": price.cacheWrite]
        }
        let payload: [String: Any] = ["fetchedAt": at.timeIntervalSince1970, "models": models]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    nonisolated static func loadDiskCache(url: URL) -> (OpenRouterCatalog.Catalog, Date)? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fetchedAt = (obj["fetchedAt"] as? NSNumber)?.doubleValue,
              let models = obj["models"] as? [String: [String: Any]]
        else { return nil }
        var catalog = OpenRouterCatalog.Catalog()
        for (id, entry) in models {
            guard let input = (entry["in"] as? NSNumber)?.doubleValue,
                  let output = (entry["out"] as? NSNumber)?.doubleValue
            else { continue }
            let price = ModelPrice(input: input, output: output,
                                   cacheRead: (entry["cr"] as? NSNumber)?.doubleValue ?? input,
                                   cacheWrite: (entry["cw"] as? NSNumber)?.doubleValue ?? input)
            let bare = id.split(separator: "/").last.map(String.init) ?? id
            catalog.byFullId[id] = price
            catalog.byBareId[bare] = price
            let key = OpenRouterCatalog.normalize(bare)
            if catalog.normalizedPrices[key] == nil { catalog.normalizedKeys.append(key) }
            catalog.normalizedPrices[key] = price
        }
        catalog.normalizedKeys.sort { $0.count > $1.count }
        return (catalog, Date(timeIntervalSince1970: fetchedAt))
    }
}

// MARK: - Self-tests

enum ModelPricingSelfTests {
    static func run() {
        testParse()
        testNormalize()
        testLookup()
        testEstimate()
        testDiskCacheRoundTrip()
    }

    private static func fixtureJSON(_ models: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["data": models])
    }

    private static func orModel(_ id: String, prompt: Double, completion: Double,
                                cacheRead: Double? = nil, cacheWrite: Double? = nil) -> [String: Any] {
        var pricing: [String: Any] = ["prompt": String(prompt), "completion": String(completion)]
        if let cacheRead { pricing["input_cache_read"] = String(cacheRead) }
        if let cacheWrite { pricing["input_cache_write"] = String(cacheWrite) }
        return ["id": id, "pricing": pricing]
    }

    private static func testParse() {
        let catalog = OpenRouterCatalog.parse(data: fixtureJSON([
            orModel("anthropic/claude-sonnet-4.5", prompt: 0.000003, completion: 0.000015,
                    cacheRead: 0.0000003, cacheWrite: 0.00000375),
            orModel("z-ai/glm-5.3-flash", prompt: 0, completion: 0),   // free model — kept
            orModel("openai/gpt-5.6-sol", prompt: 0.00000125, completion: 0.00001),
            ["id": "broken/no-pricing"],                                    // skipped
            ["id": "broken/no-id", "pricing": [:]],
        ]))
        let sonnet = catalog.byFullId["anthropic/claude-sonnet-4.5"]!
        precondition(sonnet.input == 3.0 && sonnet.output == 15.0, "per-token strings convert to USD per 1M")
        precondition(sonnet.cacheRead == 0.3 && sonnet.cacheWrite == 3.75)
        precondition(catalog.byFullId["z-ai/glm-5.3-flash"]?.input == 0, "a zero price is a real price, not an absence")
        precondition(catalog.byBareId["gpt-5.6-sol"]?.output == 10.0)
        precondition(catalog.byFullId["broken/no-pricing"] == nil)

        precondition(OpenRouterCatalog.parse(data: Data("not json".utf8)).byFullId.isEmpty)
        precondition(OpenRouterCatalog.parse(data: Data("[]".utf8)).byFullId.isEmpty)
    }

    private static func testNormalize() {
        precondition(OpenRouterCatalog.normalize("claude-sonnet-4-5-20250929") == "claudesonnet45",
                     "date-stamped transcript ids normalize onto OpenRouter's key")
        precondition(OpenRouterCatalog.normalize("claude-sonnet-4.5") == "claudesonnet45")
        precondition(OpenRouterCatalog.normalize("claude-opus-5[1m]") == "claudeopus5",
                     "the settings variant suffix is dropped before matching")
        precondition(OpenRouterCatalog.normalize("GPT-5.6-SOL") == "gpt56sol")
        precondition(OpenRouterCatalog.normalize("gemini-3.1-pro-low") == "gemini31pro",
                     "agy's effort suffix must not hide OpenRouter's -preview entry")
        precondition(OpenRouterCatalog.normalize("gemini-3.1-pro-preview") == "gemini31pro")
    }

    private static func testLookup() {
        let catalog = OpenRouterCatalog.parse(data: fixtureJSON([
            orModel("anthropic/claude-sonnet-4.5", prompt: 0.000003, completion: 0.000015),
            orModel("anthropic/claude-sonnet-4.5-thinking", prompt: 0.000003, completion: 0.000015),
            orModel("google/gemini-3.1-pro-preview", prompt: 0.000002, completion: 0.000012),
            orModel("x-ai/grok-4.6", prompt: 0.000003, completion: 0.000015),
            orModel("openai/gpt-5.6-sol", prompt: 0.00000125, completion: 0.00001),
        ]))

        // Exact bare id; full id when the transcript carries one.
        precondition(OpenRouterCatalog.price(for: "gpt-5.6-sol", in: catalog) != nil)
        precondition(OpenRouterCatalog.price(for: "x-ai/grok-4.6", in: catalog) != nil)

        // Dated / dotted / variant transcript forms.
        precondition(OpenRouterCatalog.price(for: "claude-sonnet-4-5-20250929", in: catalog) != nil)
        precondition(OpenRouterCatalog.price(for: "gemini-3.1-pro-low", in: catalog) != nil,
                     "agy's variant suffix must not hide the catalog entry")

        // Longest containment wins when several keys are contained.
        let thinking = OpenRouterCatalog.price(for: "claude-sonnet-4-5-thinking-20260101", in: catalog)
        precondition(thinking != nil)

        precondition(OpenRouterCatalog.price(for: nil, in: catalog) == nil)
        precondition(OpenRouterCatalog.price(for: "", in: catalog) == nil)
        precondition(OpenRouterCatalog.price(for: "totally-unknown-model", in: catalog) == nil,
                     "an unknown model must yield no price, never a fabricated one")
        precondition(OpenRouterCatalog.price(for: "claude-opus-5", in: OpenRouterCatalog.Catalog()) == nil,
                     "an empty catalog yields no price")
    }

    private static func testEstimate() {
        let catalog = OpenRouterCatalog.parse(data: fixtureJSON([
            orModel("anthropic/claude-opus-5", prompt: 0.000015, completion: 0.000075,
                    cacheRead: 0.0000015, cacheWrite: 0.00001875),
        ]))
        // 10k fresh in + 100k cache-read + 1k write + 2k out on opus:
        // (10000*15 + 100000*1.5 + 1000*18.75 + 2000*75)/1e6 = 0.15 + 0.15 + 0.01875 + 0.15
        let est = OpenRouterCatalog.estimate(model: "claude-opus-5-20260101", catalog: catalog,
                                             input: 10_000, output: 2_000,
                                             cacheRead: 100_000, cacheWrite: 1_000)
        precondition(abs(est! - 0.46875) < 1e-9, "estimate must price each component at its own rate, got \(est!)")

        precondition(OpenRouterCatalog.estimate(model: "unknown", catalog: catalog,
                                                input: 1, output: 1) == nil)
    }

    private static func testDiskCacheRoundTrip() {
        let catalog = OpenRouterCatalog.parse(data: fixtureJSON([
            orModel("anthropic/claude-sonnet-4.5", prompt: 0.000003, completion: 0.000015,
                    cacheRead: 0.0000003, cacheWrite: 0.00000375),
        ]))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pricing-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("openrouter-model-pricing.json")

        let at = Date(timeIntervalSince1970: 1_790_000_000)
        ModelPricingStore.writeDiskCache(catalog: catalog, at: at, url: url)
        let (loaded, fetchedAt) = ModelPricingStore.loadDiskCache(url: url)!
        precondition(loaded.byFullId == catalog.byFullId, "disk round-trip must preserve prices exactly")
        precondition(loaded.byBareId == catalog.byBareId)
        precondition(abs(fetchedAt.timeIntervalSince1970 - at.timeIntervalSince1970) < 1)
        precondition(ModelPricingStore.loadDiskCache(url: dir.appendingPathComponent("missing.json")) == nil)
    }
}

import Foundation

/// How often, and how recently, each palette command has been run — so the commands you
/// actually use rank first within a match tier ("f" → Fetch for someone who fetches a lot).
/// Keyed by `PaletteItem.usageKey`, persisted in `LeafSettings.store`.
final class CommandUsageStore {
    static let defaultsKey = "commandPaletteUsage"
    /// Least-recently-used entries past this are dropped, so the stored dictionary stays small.
    static let capacity = 200
    /// The most a habit can add to a match score. Match tiers (see `PaletteMatcher.score`):
    /// prefix 850–900, word-start 650–700, substring 450–500, keyword 400, fuzzy 100–399.
    /// The prefix and word-start tiers sit 150 above the next one down, more than any item's
    /// total boost (≤60 for a git command plus habit, ≤70 for a recent repo), so nothing lifts a weaker match over one.
    /// Below that the tiers are close — substring/keyword 50 apart, keyword/fuzzy 1 — and a habit
    /// (with repo and unavailable adjustments) can reorder those weak matches, which is intended.
    static let maxBoost = 40

    struct Entry: Codable, Equatable {
        var count: Int
        var lastUsed: Date
    }

    private let defaults: UserDefaults
    private(set) var entries: [String: Entry]

    init(defaults: UserDefaults = LeafSettings.store) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func recordUse(of key: String, at date: Date = Date()) {
        var entry = entries[key] ?? Entry(count: 0, lastUsed: date)
        entry.count += 1
        entry.lastUsed = date
        entries[key] = entry
        if entries.count > Self.capacity {
            let stale = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(entries.count - Self.capacity)
            for (key, _) in stale { entries.removeValue(forKey: key) }
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Frecency: grows with the log of the use count (the tenth run matters less than the
    /// second), scaled down the longer it's been since the last run.
    func boost(for key: String, now: Date = Date()) -> Int {
        guard let entry = entries[key], entry.count > 0 else { return 0 }
        let frequency = min(Double(Self.maxBoost), log2(Double(entry.count) + 1) * 12)
        let age = now.timeIntervalSince(entry.lastUsed)
        let day: TimeInterval = 86_400
        let recency: Double
        switch age {
        case ..<day: recency = 1
        case ..<(7 * day): recency = 0.75
        case ..<(30 * day): recency = 0.45
        default: recency = 0.2
        }
        return Int((frequency * recency).rounded())
    }
}

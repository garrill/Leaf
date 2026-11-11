import Foundation

/// A least-recently-used cache capped by a caller-defined *cost* (typically bytes or element
/// count) rather than entry count — one huge diff and a hundred tiny ones shouldn't count the
/// same. Used for every cache that would otherwise grow for the lifetime of a repo selection or
/// the app (`AppState`'s selection caches, `SyntaxHighlighter`'s token cache).
///
/// Not `NSCache`: that needs class keys/values and evicts on its own unpredictable schedule,
/// whereas callers here rely on a value they just stored still being there on the next read.
///
/// Recency is tracked with a monotonically increasing tick per entry; eviction scans for the
/// smallest tick. That's O(n) per eviction, but these caches hold tens-to-hundreds of entries
/// and only evict when over budget, so a linked list isn't worth the complexity.
nonisolated struct BoundedCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    let costLimit: Int
    private let cost: (Value) -> Int
    private var entries: [Key: Entry] = [:]
    private var tick: UInt64 = 0
    private(set) var totalCost = 0

    init(costLimit: Int, cost: @escaping (Value) -> Int) {
        self.costLimit = costLimit
        self.cost = cost
    }

    var count: Int { entries.count }

    /// Reading refreshes the entry's recency. Assigning `nil` removes it. Assigning a value whose
    /// own cost exceeds `costLimit` drops any existing entry for the key and stores nothing —
    /// caching it would only evict everything else and then itself.
    subscript(key: Key) -> Value? {
        mutating get {
            guard var entry = entries[key] else { return nil }
            tick &+= 1
            entry.lastUse = tick
            entries[key] = entry
            return entry.value
        }
        set {
            if let old = entries.removeValue(forKey: key) {
                totalCost -= old.cost
            }
            guard let newValue else { return }
            let newCost = max(cost(newValue), 0)
            guard newCost <= costLimit else { return }
            tick &+= 1
            entries[key] = Entry(value: newValue, cost: newCost, lastUse: tick)
            totalCost += newCost
            evictIfNeeded()
        }
    }

    /// Membership test that does *not* count as a use (e.g. a prefetch skipping work it already did).
    func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    private mutating func evictIfNeeded() {
        while totalCost > costLimit, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            entries.removeValue(forKey: oldest.key)
            totalCost -= oldest.value.cost
        }
    }
}

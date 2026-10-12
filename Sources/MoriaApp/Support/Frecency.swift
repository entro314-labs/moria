import Foundation

/// What was opened for which search, so the same search puts it first next time, as Spotlight
/// and launchers do. Frequency and recency: a use counts fully for ten days and half as much
/// for every ten days after; a search that begins with, or is the beginning of, a remembered
/// one counts for less, so "inv" learns from "invoice" without taking it over.
@MainActor
final class Frecency {
    struct Use: Codable, Equatable {
        var query: String
        var path: String
        var count: Int
        var last: Date
    }

    static let halfLife: TimeInterval = 10 * 86400
    static let maxUses = 500
    /// How much a search that merely begins with (or starts) the remembered one counts.
    static let partialWeight = 0.6

    private let defaults: UserDefaults
    private static let key = "frecency"
    private(set) var uses: [Use]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        uses = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Use].self, from: $0) } ?? []
    }

    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    func record(query: String, path: String, now: Date = Date()) {
        let query = Self.normalize(query)
        guard !query.isEmpty else { return }
        if let index = uses.firstIndex(where: { $0.query == query && $0.path == path }) {
            uses[index].count += 1
            uses[index].last = now
        } else {
            uses.append(Use(query: query, path: path, count: 1, last: now))
        }
        if uses.count > Self.maxUses {
            uses.sort { $0.last > $1.last }
            uses.removeLast(uses.count - Self.maxUses)
        }
        if let data = try? JSONEncoder().encode(uses) { defaults.set(data, forKey: Self.key) }
    }

    /// How strongly `path` has been chosen for `query`: the decayed number of uses, 0 when never.
    func weight(query: String, path: String, now: Date = Date()) -> Double {
        let query = Self.normalize(query)
        guard !query.isEmpty else { return 0 }
        return uses.reduce(0) { total, use in
            guard use.path == path else { return total }
            let relation: Double
            if use.query == query {
                relation = 1
            } else if query.count >= 2, use.query.hasPrefix(query) || query.hasPrefix(use.query) {
                relation = Self.partialWeight
            } else {
                return total
            }
            let age = max(0, now.timeIntervalSince(use.last))
            return total + relation * Double(use.count) * pow(0.5, age / Self.halfLife)
        }
    }

    func forget() {
        uses = []
        defaults.removeObject(forKey: Self.key)
    }
}

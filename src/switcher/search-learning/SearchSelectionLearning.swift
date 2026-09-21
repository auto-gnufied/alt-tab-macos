import Foundation

struct LearnedSearchSelection: Codable, Equatable {
    let normalizedQuery: String
    let bundleIdentifier: String
    var lastUsedAt: TimeInterval
}

struct SearchSelectionLearningState: Codable, Equatable {
    static let capacity = 100
    static let expiration: TimeInterval = 180 * 24 * 60 * 60
    static let maximumQueryLength = 64
    var records: [LearnedSearchSelection] = []

    func preferredBundleIdentifier(for query: String) -> String? {
        let query = Self.normalized(query)
        guard Self.accepts(query) else { return nil }
        return records.first { $0.normalizedQuery == query }?.bundleIdentifier
    }

    func record(query: String, bundleIdentifier: String, now: TimeInterval) -> Self {
        let query = Self.normalized(query)
        guard Self.accepts(query), !bundleIdentifier.isEmpty else { return self }
        var next = pruned(now: now)
        next.records.removeAll { $0.normalizedQuery == query }
        next.records.append(LearnedSearchSelection(normalizedQuery: query, bundleIdentifier: bundleIdentifier,
                                                   lastUsedAt: now))
        next.records = Self.bounded(next.records)
        return next
    }

    func touch(query: String, now: TimeInterval) -> Self {
        let query = Self.normalized(query)
        var next = pruned(now: now)
        guard let index = next.records.firstIndex(where: { $0.normalizedQuery == query }) else { return next }
        next.records[index].lastUsedAt = now
        return next
    }

    func pruned(now: TimeInterval) -> Self {
        let valid = records.filter {
            Self.accepts($0.normalizedQuery) && !$0.bundleIdentifier.isEmpty
                && now - $0.lastUsedAt <= Self.expiration
        }
        return Self(records: Self.bounded(Self.deduplicated(valid)))
    }

    private static func normalized(_ query: String) -> String { SearchTestable.normalize(query).text }
    private static func accepts(_ query: String) -> Bool { !query.isEmpty && query.count <= maximumQueryLength }

    private static func deduplicated(_ records: [LearnedSearchSelection]) -> [LearnedSearchSelection] {
        var newest = [String: LearnedSearchSelection]()
        for record in records where newest[record.normalizedQuery]?.lastUsedAt ?? -.infinity < record.lastUsedAt {
            newest[record.normalizedQuery] = record
        }
        return Array(newest.values)
    }

    private static func bounded(_ records: [LearnedSearchSelection]) -> [LearnedSearchSelection] {
        Array(records.sorted {
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }
            return $0.normalizedQuery < $1.normalizedQuery
        }.prefix(capacity))
    }
}

struct LossyLearnedSearchSelections: Decodable {
    let records: [LearnedSearchSelection]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var records = [LearnedSearchSelection]()
        while !container.isAtEnd {
            if let record = try? container.decode(LearnedSearchSelection.self) { records.append(record) }
            else { _ = try? container.decode(DiscardedLearnedSearchSelectionValue.self) }
        }
        self.records = records
    }
}

private struct DiscardedLearnedSearchSelectionValue: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd { _ = try? array.decode(Self.self) }
            return
        }
        if let object = try? decoder.container(keyedBy: LearnedSearchSelectionCodingKey.self) {
            for key in object.allKeys { _ = try? object.decode(Self.self, forKey: key) }
            return
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { return }
        if (try? value.decode(Bool.self)) != nil || (try? value.decode(Double.self)) != nil { return }
        _ = try? value.decode(String.self)
    }
}

private struct LearnedSearchSelectionCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

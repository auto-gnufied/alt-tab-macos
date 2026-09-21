import Foundation

enum SearchSelectionLearning {
    private static var state = SearchSelectionLearningState()
    private static var preferredByQuery = [String: String]()
    private static var loaded = false
    private static var writeScheduled = false
    private static var pendingRecords: [LearnedSearchSelection]?

    static func preferredBundleIdentifier(for normalizedQuery: String) -> String? {
        loadIfNeeded()
        return preferredByQuery[normalizedQuery]
    }

    static func recordCommittedFocus(session: SwitcherSession, window: Window?, directTileClick: Bool) {
        let query = Search.normalizedQuery(session.searchQuery)
        guard !query.isEmpty, let bundleIdentifier = window?.application.state.bundleIdentifier else { return }
        loadIfNeeded()
        let now = Date.timeIntervalSinceReferenceDate
        if session.userPickedSelection || directTileClick {
            update(state.record(query: query, bundleIdentifier: bundleIdentifier, now: now))
        } else if preferredByQuery[query] == bundleIdentifier {
            update(state.touch(query: query, now: now))
        }
    }

    static func reload() {
        state = SearchSelectionLearningState(records: Preferences.learnedSearchSelections)
            .pruned(now: Date.timeIntervalSinceReferenceDate)
        rebuildLookup()
        loaded = true
    }

    private static func loadIfNeeded() {
        if !loaded { reload() }
    }

    private static func update(_ next: SearchSelectionLearningState) {
        guard next != state else { return }
        state = next
        rebuildLookup()
        pendingRecords = state.records
        scheduleWrite()
    }

    private static func rebuildLookup() {
        preferredByQuery = Dictionary(uniqueKeysWithValues: state.records.map {
            ($0.normalizedQuery, $0.bundleIdentifier)
        })
    }

    private static func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.async {
            writeScheduled = false
            guard let records = pendingRecords else { return }
            pendingRecords = nil
            Preferences.setJson("learnedSearchSelections", records)
        }
    }
}

import XCTest

final class SearchSelectionLearningTests: XCTestCase {
    func testRecordsAndNormalizesQuery() {
        let state = SearchSelectionLearningState().record(query: " F ", bundleIdentifier: "org.mozilla.firefox", now: 1)
        XCTAssertEqual(state.preferredBundleIdentifier(for: "f"), "org.mozilla.firefox")
        XCTAssertEqual(state.preferredBundleIdentifier(for: " F "), "org.mozilla.firefox")
    }

    func testRetrainingReplacesApplication() {
        let first = SearchSelectionLearningState().record(query: "f", bundleIdentifier: "org.mozilla.firefox", now: 1)
        let second = first.record(query: "f", bundleIdentifier: "com.apple.finder", now: 2)
        XCTAssertEqual(second.preferredBundleIdentifier(for: "f"), "com.apple.finder")
        XCTAssertEqual(second.records.count, 1)
    }

    func testQueriesAreIndependent() {
        let first = SearchSelectionLearningState().record(query: "f", bundleIdentifier: "firefox", now: 1)
        let second = first.record(query: "fi", bundleIdentifier: "finder", now: 2)
        XCTAssertEqual(second.preferredBundleIdentifier(for: "f"), "firefox")
        XCTAssertEqual(second.preferredBundleIdentifier(for: "fi"), "finder")
    }

    func testCapacityEvictsLeastRecentlyUsed() {
        var state = SearchSelectionLearningState()
        for index in 0...SearchSelectionLearningState.capacity {
            state = state.record(query: "q\(index)", bundleIdentifier: "app\(index)", now: TimeInterval(index))
        }
        XCTAssertEqual(state.records.count, SearchSelectionLearningState.capacity)
        XCTAssertNil(state.preferredBundleIdentifier(for: "q0"))
        XCTAssertEqual(state.preferredBundleIdentifier(for: "q100"), "app100")
    }

    func testWritePrunesExpiredRecords() {
        let old = LearnedSearchSelection(normalizedQuery: "old", bundleIdentifier: "old.app", lastUsedAt: 0)
        let state = SearchSelectionLearningState(records: [old]).record(
            query: "new", bundleIdentifier: "new.app", now: SearchSelectionLearningState.expiration + 1)
        XCTAssertNil(state.preferredBundleIdentifier(for: "old"))
        XCTAssertEqual(state.preferredBundleIdentifier(for: "new"), "new.app")
    }

    func testTouchRefreshesTimestampWithoutChangingApplication() {
        let first = SearchSelectionLearningState().record(query: "f", bundleIdentifier: "firefox", now: 1)
        let second = first.touch(query: " F ", now: 5)
        XCTAssertEqual(second.records.first?.bundleIdentifier, "firefox")
        XCTAssertEqual(second.records.first?.lastUsedAt, 5)
    }

    func testMalformedRowDoesNotDiscardValidRows() throws {
        let json = #"[{"normalizedQuery":"f","bundleIdentifier":"firefox","lastUsedAt":1},{"bad":true}]"#
        let decoded = try JSONDecoder().decode(LossyLearnedSearchSelections.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.records, [LearnedSearchSelection(normalizedQuery: "f", bundleIdentifier: "firefox", lastUsedAt: 1)])
    }

    func testOverlongQueryIsRejected() {
        let query = String(repeating: "a", count: SearchSelectionLearningState.maximumQueryLength + 1)
        let state = SearchSelectionLearningState().record(query: query, bundleIdentifier: "app", now: 1)
        XCTAssertTrue(state.records.isEmpty)
    }
}

# Learned Search Selection Ranking

## Summary

AltTab currently ranks an active search by textual relevance and then by recent focus order. The ranking is deterministic, but it does not learn from an explicit choice. If `f` initially selects another match (such as Finder) and the user moves to Firefox, focuses it, and later searches for `f` again, Firefox receives no preference from that earlier choice.

Add a small, resilient, persisted learning layer that associates a normalized search query with the application the user explicitly chose. While that application has an eligible matching result in a later search, its best result should rank first. If the application is not running, has no matching windows, or is filtered out, search selection seamlessly reverts to the natural default ranking.

## Goal

Support this flow:

1. The user opens the switcher in search mode (or triggers search) and types `f`.
2. AltTab shows all normal text matches (e.g. Finder, Firefox, Font Book).
3. The user explicitly moves the selection to Firefox and commits it (via Return, shortcut, or tile click).
4. In a later session, typing `f` selects Firefox by default whenever Firefox is running and has an eligible matching result.
5. If Firefox is not running, is filtered out, or does not match `f`, selection falls back to the ordinary best match with zero lag or empty tiles.

Learning must be invisible, instantaneous, bounded, and reversible.

## Product Decisions

- **Learn an application, not a specific window:** Window IDs are transient and Space-dependent, whereas the user's intent is "prefer Firefox for `f`". Within the preferred application, retain normal relevance and MRU ordering so AltTab picks the best current Firefox window.
- **Key learning strictly by normalized query:** Choosing Firefox for `f` affects `f`; choosing Finder for `fi` affects `fi`. Do not automatically propagate a choice to prefixes or substrings, which would make unrelated short searches unpredictable.
- **Train only from explicit selection:**
  - Keyboard: Arrow keys or shortcut cycling moving away from the default initial pick (`session.userPickedSelection == true`), followed by a focus commit.
  - Mouse: Directly clicking a tile in `TilesView`.
  - Merely pressing Return on an untouched, unlearned default match does not train a new preference.
- **Keep active habits alive (Avoid LRU starvation):** When the user presses Return on a window belonging to an *already learned* application for the current query, touch its `lastUsedAt` timestamp. This prevents frequently used shortcuts from expiring after 180 days or being evicted by LRU capacity limits.
- **Reversible with natural correction:** If the user previously learned `f → Firefox` but later explicitly selects Finder for `f` and commits focus, Finder replaces Firefox as the learned choice for `f`. Selecting the natural top-ranked default match resets/replaces the learned preference cleanly.
- **Strict eligibility constraint:** Learned history can only reorder windows that already satisfy `Search.matches`. It must **never** promote or admit a nonmatching or filtered-out window.
- **Stable process identity:** Use the application bundle identifier (`bundleIdentifier`). If a process has no bundle identifier (e.g. certain raw CLI binaries), skip learning rather than storing volatile PIDs or localized names.
- **Windowless app support:** If the learned application is running with no open windows and windowless apps are enabled in preferences, its windowless app placeholder matches the application name and will be promoted, allowing the user to launch/activate it with Return.
- **Cross-slot scope:** Learned mappings apply across switcher shortcut slots. If a slot hides the preferred application via filters (e.g. "Only current Space"), the learned application does not participate and ranking falls back to the best visible match.

---

## Architecture & Implementation Details

### 1. Pure Learned-Ranking Model (`src/switcher/search-learning/`)

Create a dedicated feature triad:
- `SearchSelectionLearning.swift`
- `SearchSelectionLearningTests.swift`
- `SearchSelectionLearningSpecs.md`

Keep AppKit and `UserDefaults` completely decoupled from the pure model.

```swift
struct LearnedSearchSelection: Codable, Equatable {
    let normalizedQuery: String
    let bundleIdentifier: String
    var lastUsedAt: TimeInterval
}

struct SearchSelectionLearningState: Codable, Equatable {
    var records: [LearnedSearchSelection] = []
}
```

The pure engine exposes:
- `preferredBundleIdentifier(for normalizedQuery: String) -> String?`
- `record(query: String, bundleIdentifier: String, now: TimeInterval) -> SearchSelectionLearningState`
- `touch(query: String, now: TimeInterval) -> SearchSelectionLearningState`
- `pruned(now: TimeInterval) -> SearchSelectionLearningState`

Use an in-memory lookup table (`[String: String]`) for $O(1)$ query evaluation on the keystroke path.

### 2. Persistence & Bounded Storage

Store under preference key `learnedSearchSelections`:
- Default: `[]` (empty JSON array; zero behavioral changes out of the box).
- Capacity cap: Maximum 100 distinct normalized queries. Evict least-recently-used (`lastUsedAt`) entries when full.
- Expiration: Prune entries unused for more than 180 days on write.
- Query length: Max 64 characters (drop or truncate longer queries).
- Tolerant decoding: If any single entry in JSON is corrupt, drop only that entry rather than wiping out the entire learned history.
- Asynchronous / Non-blocking persistence: Perform preference writes off the critical focus/dismissal path or coalesced to avoid main-thread IPC stalls during window dismissal.
- Reset behavior: `Preferences.reset()` clears `learnedSearchSelections`.

### 3. Focus Commit Hook & Session Tracking

To ensure both keyboard and mouse commits are captured reliably:

```
[User Action]
   ├── Keyboard: Return / Focus shortcut ──► App.focusTarget() ──┐
   └── Mouse: Tile clicked in TilesView ─────────────────────────┴──► App.focusSelectedWindow(selectedWindow)
                                                                           │
                                                                           ├─► 1. SearchSelectionLearning.recordCommittedFocus(...)
                                                                           │      (Inspects session BEFORE teardown)
                                                                           │
                                                                           └─► 2. beginHideUi() [SwitcherSession.current = nil]
```

**Hook Location:** Entry of `App.focusSelectedWindow(_ selectedWindow: Window?)`, **before** calling `beginHideUi(true)`.

**Decision Logic inside `recordCommittedFocus(session:window:)`:**
1. Guard that `session.searchQuery` is non-empty.
2. Let `normalizedQuery = Search.normalizedQuery(session.searchQuery)`. Guard `!normalizedQuery.isEmpty`.
3. Guard that `window` has a valid `bundleIdentifier = window.application.state.bundleIdentifier`.
4. Check whether this is an explicit choice:
   - If `session.userPickedSelection == true` OR the commit originated from a direct tile click:
     - Record/replace `(normalizedQuery, bundleIdentifier)` in `SearchSelectionLearning`.
   - Else if `window.bundleIdentifier == preferredBundleIdentifier(for: normalizedQuery)`:
     - The user accepted the learned choice without changing it: call `touch(normalizedQuery)` to update `lastUsedAt`.
   - Otherwise (user accepted default without moving and without a prior learned preference): do not record.

### 4. Search Ordering Integration (`WindowOrderResolver`)

Extend `OrderWindow` with `isLearnedApplication: Bool`:

```swift
struct OrderWindow: Equatable {
    let state: WindowState
    let app: ApplicationState
    let searchMatches: Bool
    let searchRelevance: Double
    let isLearnedApplication: Bool
}
```

In `Windows.sort()`:
1. Normalize query once: `let trimmedQuery = Search.normalizedQuery(SwitcherSession.current?.searchQuery ?? "")`.
2. If `trimmedQuery.isEmpty`, `preferredBundleId = nil`. Otherwise, perform one constant-time dictionary lookup: `preferredBundleId = SearchSelectionLearning.preferredApp(for: trimmedQuery)`.
3. When building `OrderWindow`:
   ```swift
   let isLearned = searchMatches && (window.application.state.bundleIdentifier == preferredBundleId)
   ```
4. In `WindowOrderResolver.isOrderedBefore`:
   ```swift
   if searchActive {
       if a.searchMatches != b.searchMatches { return a.searchMatches }
       if a.isLearnedApplication != b.isLearnedApplication { return a.isLearnedApplication }
       if a.searchRelevance != b.searchRelevance { return a.searchRelevance > b.searchRelevance }
       return a.state.lastFocusOrder < b.state.lastFocusOrder
   }
   ```

**Properties of this ordering:**
- Matching results from the learned app sort ahead of matching results from other apps.
- Non-matching windows from the learned app are **never** promoted (`searchMatches == false`).
- Multiple windows from the learned app preserve their natural relevance and MRU (`lastFocusOrder`) order.
- If the learned app is not running or absent, `isLearnedApplication` is false for all windows, falling back seamlessly to standard relevance and MRU ranking.

### 5. Preference Event Isolation

When saving learned selections via `Preferences.set("learnedSearchSelections", ...)`:
- In `PreferencesEvents.swift`, handle `"learnedSearchSelections"` by updating the in-memory `SearchSelectionLearning` lookup cache.
- **Do NOT** trigger `App.resetPreferencesDependentComponents()` or reload `TilesPanel` when this key changes. Writing learned history occurs during switcher dismissal; triggering UI reset would disrupt window dismissal.

---

## Gaps Identified & Addressed

| Area | Initial Plan Gap | Updated Specification Resolution |
| :--- | :--- | :--- |
| **Commit Hook Placement** | Suggested placing hook in `App.focusTarget()`, which is bypassed by mouse tile clicks (`TileView` calls `focusSelectedWindow` directly). | Moved hook to the beginning of `App.focusSelectedWindow()`, before `beginHideUi()`, capturing both keyboard and mouse commits. |
| **LRU Expiry Starvation** | Requiring `userPickedSelection == true` meant active users who press Return on the learned item never refresh `lastUsedAt`, causing eviction after 180 days. | Added `touch(query)`: confirming the learned app by focusing it refreshes `lastUsedAt`, keeping daily habits permanently cached. |
| **Mouse Tile Click Detection** | Mouse clicks on tiles did not consistently set `session.userPickedSelection`, risking ignored clicks. | Explicitly treated mouse clicks in `TileView` as an explicit selection trigger. |
| **Windowless Application State** | Unclear whether running apps without windows (e.g. backgrounded Firefox with closed window) could be selected. | Specified that windowless placeholder tiles participate in learned ranking if `Search.matches` matches the application name. |
| **Preference Event Handling** | Risk of `PreferencesEvents` triggering a full switcher reset if `learnedSearchSelections` was handled like other preference changes. | Isolated `"learnedSearchSelections"` in `PreferencesEvents` to only update the in-memory cache, preventing UI churn during dismissal. |
| **Normalization Parity** | Risk of custom string normalization drifting from search matching. | Explicitly bound all query normalization to `Search.normalizedQuery` (`SearchTestable.normalize`). |

---

## Test Plan

### Pure Unit Tests (`SearchSelectionLearningTests.swift`)
- Associating `f → org.mozilla.firefox` and retrieving it for `f`, `F`, and ` f `.
- Retraining `f → com.apple.finder` replaces Firefox.
- Query independence: `f` and `fi` store distinct preferences.
- LRU capacity: inserting 101st entry evicts the least recently used record.
- Expiry: entries older than 180 days are pruned on write.
- `touch()` updates `lastUsedAt` without changing the assigned application.
- Malformed JSON recovery: decoding an array containing an invalid entry recovers valid entries.
- Overlong queries (>64 chars) are rejected or safely truncated.

### Ordering Tests (`WindowOrderResolverTests.swift`)
- Learned app matching window sorts ahead of a textually higher-scoring unlearned app window.
- Learned app with zero matches does not sort ahead of matching windows.
- Multiple windows for the learned app maintain internal relevance and MRU order.
- Unlearned queries retain exact standard ranking.
- Windowless app placeholder for learned app sorts first among matches.

### Session Integration Tests
- Typing `f`, navigating to Firefox, and pressing Return saves preference.
- Typing `f` and clicking Firefox tile with mouse saves preference.
- Typing `f` and pressing Return on default pick without moving does not train an unlearned query.
- Typing `f` on an already-learned query and pressing Return touches `lastUsedAt`.
- Dismissing switcher with Escape or cancelling does not record learning.
- Quitting learned app causes `f` to immediately select the natural default match.

---

## Verification Matrix

| Scenario | Input | Expected Outcome |
| :--- | :--- | :--- |
| **Initial Training** | Type `f`, arrow down to Firefox, press Return. | Firefox focuses; `f → org.mozilla.firefox` persisted. |
| **Subsequent Query** | Reopen switcher, type `f`. | Firefox is preselected at index 0 by default. |
| **Habit Confirmation** | Press Return on preselected Firefox. | Firefox focuses; `lastUsedAt` is refreshed. |
| **Target Not Running** | Quit Firefox, reopen switcher, type `f`. | Ordinary top match (e.g. Finder) is preselected. No lag or errors. |
| **Target Relaunched** | Relaunch Firefox, reopen switcher, type `f`. | Firefox is preselected at index 0 again. |
| **Preference Retraining**| Type `f`, arrow to Finder, press Return. | Finder focuses; `f` is now mapped to Finder. |
| **Different Query** | Type `fi`. | Independent ranking; does not inherit from `f`. |
| **Mouse Click** | Type `g`, click Chrome tile. | Chrome focuses; `g → com.google.Chrome` persisted. |
| **Preference Reset** | Preferences → Reset. | Learned history cleared; reverts to stock search ranking. |

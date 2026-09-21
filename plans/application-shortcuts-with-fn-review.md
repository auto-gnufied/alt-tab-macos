# Code Review: Application Shortcuts with fn Implementation

**Review Target:** Commit `345c89b98b6fcc93ae6ac8c7b95b1364b8555ee4` and uncommitted follow-up revisions  
**Specification Document:** [`plans/application-shortcuts-with-fn.md`](file:///Users/hekumar/checkout/alt-tab-macos/plans/application-shortcuts-with-fn.md)  
**Specs Reference:** [`src/events/ApplicationShortcutsSpecs.md`](file:///Users/hekumar/checkout/alt-tab-macos/src/events/ApplicationShortcutsSpecs.md)  
**Date:** 2026-09-20  
**Review Status:** **Substantially Fixed / Verified Working (Remaining items are minor polish / search index integration)**

---

## Executive Summary

The uncommitted revisions address and resolve virtually all critical safety, performance, and functional defects previously identified in commit `345c89b`. 

The global event tap path is now strictly $O(1)$, non-`fn` shortcuts are offloaded to Carbon, arrow and F-key recording correctly distinguishes physical `fn` from AppKit flags, deterministic MRU window target resolution is in place, and a complete conflict-handling and application-picker UX has been added.

Unit tests covering normalization, target resolution, phantom/tab window filtering, launch gate deduplication, and resilient JSON decoding all pass cleanly (1354/1354 tests passing).

---

## Review Comments Resolution Status

| Review Finding | Severity | Resolution in Uncommitted Changes | Status |
| :--- | :--- | :--- | :--- |
| **Linear search in event tap callback** | Critical | Implemented `ApplicationShortcutKey` hash lookup. `fnMappings` provides an $O(1)$ dictionary lookup under lock returning only `UUID`. No allocations or struct copying on keystroke path. | ✅ **FIXED** |
| **Cocoa `.function` false positive on Arrow/F-keys** | High | Recorder now explicitly tests physical modifier state via `CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)`, ignoring AppKit's implicit `.function` bit on navigation and F-keys. | ✅ **FIXED** |
| **All shortcuts forced onto CGEvent tap** | High | Carbon hotkey handler (`RegisterEventHotKey` / `InstallEventHandler`) implemented for all non-`fn` shortcuts. The CGEvent tap is enabled *only* when `!fnMappings.isEmpty`. | ✅ **FIXED** |
| **Incidental window resolution (`Windows.list.first`)** | High | Implemented `ApplicationShortcutTargetResolver`. Filters out phantom and tabbed windows, prioritizes last-attended window, then lowest `lastFocusOrder`, with windowless app fallback. | ✅ **FIXED** |
| **Spamming concurrent launches on slow-start apps** | Medium | Implemented `ApplicationLaunchGate` with `begin()` and `finish()` locking per bundle identifier. Repeated presses while launch is in flight are debounced. | ✅ **FIXED** |
| **Fragile preferences JSON decoding** | Medium | Implemented `LossyArray<Element>` and `DiscardedCodableValue`. Malformed rows in `applicationShortcuts` are discarded individually without clearing the user's valid shortcuts. | ✅ **FIXED** |
| **Silent conflict overwrite** | Medium | Implemented `resolveConflicts`. Detects collisions against other application shortcuts and AltTab switcher shortcuts. Shows confirmation dialog before unassigning. | ✅ **FIXED** |
| **Nested modal sheets in AppKit** | Medium | Moved `Application shortcuts…` button out of `AdditionalControlsSheet` directly onto the `ControlsTab` toolbar (`StackView([additionalControlsButton, applicationShortcutsButton, shortcutsButton], .horizontal)`). | ✅ **FIXED** |
| **App picker & row icons missing** | Low | Added "Add a running app" popup menu with running apps sorted by name, 16x16 icons, plus "Add an app from disk" `NSOpenPanel`. Added async icon loading to row presentation. | ✅ **FIXED** |
| **Accessibility / VoiceOver labels** | Low | Added explicit accessibility labels to row app names, recorder buttons, and remove buttons. | ✅ **FIXED** |
| **Specification document missing** | Low | Created [`src/events/ApplicationShortcutsSpecs.md`](file:///Users/hekumar/checkout/alt-tab-macos/src/events/ApplicationShortcutsSpecs.md) codifying routing, resolution, persistence, and UX contracts. | ✅ **FIXED** |
| **Inadequate test coverage** | Medium | Added 8 comprehensive unit tests in `KeyboardEventsTests.swift` verifying normalization, chord identity, target resolution, launch deduplication, and resilient decoding. | ✅ **FIXED** |

---

## Detailed Audit of Fixed Items

### 1. Event Tap Keystroke Path ($O(1)$ Lookup)
- **Before:** Iterated `mappings.first { ... }` with a linear search closure across all shortcuts on every system keystroke under lock.
- **After:** Keyed by `ApplicationShortcutKey(keyCode: keyCode, modifiers: modifiers)`. Lookup is a direct hash table query:
  ```swift
  let mappingId = lock.withLock { fnMappings[ApplicationShortcutKey(keyCode: keyCode, modifiers: modifiers)] }
  guard let mappingId else { return Unmanaged.passUnretained(event) }
  ```
  Only the `UUID` mapping ID is dispatched to the main queue for activation.

### 2. Elimination of Cocoa `.function` Interference
- **Before:** `ApplicationShortcutModifiers.from(event.modifierFlags)` set the function bit whenever `flags.contains(.function)`, which Cocoa sets automatically for Arrow keys, Home, End, PageUp, PageDown, and F1–F12.
- **After:** The recorder now checks physical hardware state:
  ```swift
  let physicalFn = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
  let modifiers = ApplicationShortcutModifiers.from(event.modifierFlags, physicalFunction: physicalFn)
  ```
  This is pinned by `testApplicationShortcutModifierNormalizationIgnoresImplicitCocoaFunction()`.

### 3. Target Window & Application Resolution Policy
- **Before:** Blindly invoked `Windows.list.first(where: { ... })?.focus()`, potentially focusing hidden tabs, phantom closing windows, or an arbitrary background window.
- **After:** Pure `ApplicationShortcutTargetResolver` processes filtered candidate snapshots:
  1. Rejects `isPhantom` and `isTabbed` windows.
  2. Prioritizes `AttentionEngine.lastAttendedWindow(pid)`.
  3. Falls back to MRU via `lastFocusOrder`.
  4. Falls back to windowless application placeholders.
  5. If no window exists, activates the running process or invokes `openApplication`.

### 4. Carbon Hotkey Offloading & Tap Enablement
- **Before:** All shortcuts were captured via the active CoreGraphics event tap.
- **After:**
  - Non-`fn` shortcuts register with the OS via Carbon `RegisterEventHotKey`.
  - The Carbon event dispatcher forwards non-AltTab shortcuts to `CallNextEventHandler`.
  - The CGEvent tap is only enabled when `enabled && !recording && !fnMappings.isEmpty`. If the user has only standard shortcuts configured, the tap remains completely inactive.

### 5. Conflict Management & User Safety
- **Before:** Overwrote existing assignments silently without confirmation, and ignored AltTab's global switcher hotkeys.
- **After:** Checks for collisions against both application shortcuts and `ControlsTab.shortcuts`. Prompts the user with `ControlsTab.confirmUnassigningConflict(message)` listing conflicting assignments before unassigning them.

---

## Remaining Gaps / Non-Critical Issues to Address

### 1. Settings Search Index Integration (Missing)
- **Issue:** In [`src/preferences/settings-window/SettingsSearchIndex.swift`](file:///Users/hekumar/checkout/alt-tab-macos/src/preferences/settings-window/SettingsSearchIndex.swift#L74-L82), `sheetSearchableStrings(forButtonAction:)` does not register `#selector(ControlsTab.showApplicationShortcutsSettings)`.
- **Impact:** Users typing "application shortcuts" or "shortcuts" in the Settings search bar will not see the "Application shortcuts…" button highlighted.
- **Recommended Fix:** Add a `searchableStrings: [String]` static array to `ApplicationShortcutsSheet` and map `#selector(ControlsTab.showApplicationShortcutsSettings)` in `SettingsSearchIndex.sheetSearchableStrings`.

### 2. Code Organization (Feature Folder vs Co-location)
- **Issue:** The original plan proposed a separate `src/app-shortcuts/` feature folder. The implementation chose instead to co-locate code in `KeyboardEvents.swift`, `KeyboardEventsTestable.swift`, `ApplicationShortcutsSpecs.md`, and `AdditionalControlsSheet.swift`.
- **Assessment:** This co-location is functional and consistent with how other AltTab event controllers are structured (e.g. `PreferencesEvents`, `CursorEvents`). However, if modular separation is desired in the future, these components can be cleanly moved into `src/app-shortcuts/`.

### 3. Frontmost Application Behavior
- **Issue:** `guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != mapping.bundleIdentifier else { return }` treats pressing the shortcut for the already-frontmost app as a no-op.
- **Assessment:** This is now documented and accepted in `ApplicationShortcutsSpecs.md` ("If the target application is already frontmost, the action is a no-op."). If multi-window cycling for the active app is desired in the future, this guard can be extended to cycle through that application's windows.

---

## Verification Summary

- **Build:** Clean build on Xcode 26+ (`BuildProject` succeeded with 0 errors).
- **Unit Tests:** 1354 passed, 0 failed across the entire test suite (`Test` scheme).
- **New Unit Tests Added:**
  - `testApplicationShortcutModifierNormalizationPreservesFunction`
  - `testApplicationShortcutModifierNormalizationIgnoresImplicitCocoaFunction`
  - `testApplicationShortcutChordIdentityIgnoresDisplayLabel`
  - `testApplicationShortcutTargetPrefersLastAttendedEligibleWindow`
  - `testApplicationShortcutTargetSkipsPhantomAndTabbedWindows`
  - `testApplicationShortcutTargetFallsBackToWindowlessPlaceholder`
  - `testApplicationLaunchGateDeduplicatesUntilFinished`
  - `testApplicationShortcutDecodingKeepsValidRowsAroundMalformedRow`

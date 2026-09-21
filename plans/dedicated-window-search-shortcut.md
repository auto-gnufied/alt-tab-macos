# Dedicated Window Search Shortcut

## Summary

AltTab can already approximate a separate window-search shortcut:

1. Open **Settings → Controls**.
2. Add or select a numbered shortcut.
3. Assign its **Trigger**.
4. Open that shortcut's **Appearance** tab.
5. Set **After keys are released** to **Search**.

That shortcut opens the switcher in search-editing mode while leaving other shortcuts configured for normal window switching. The existing in-switcher **Search** binding under **Shortcuts when active…** only toggles search after a switcher session is already open; it is not global.

The approximation has three limitations compared with Contexts:

- It consumes an additional numbered shortcut slot and is therefore Pro-gated.
- It uses AltTab's two-part hold-and-press trigger model instead of an ordinary global chord.
- Its purpose is hidden behind the per-shortcut “After keys are released” behavior rather than presented as a first-class “Search windows” command.

This plan adds a dedicated, optional global shortcut that summons AltTab directly in search mode.

## User experience

Add a row to **Settings → Controls** above the “Shortcuts when active…” button:

| Setting | Default | Behavior |
| --- | --- | --- |
| Search windows | Unassigned | A normal global chord such as ⌘Space or ⌥Space opens the switcher with the search field focused. |

The recorder should accept one key plus ordinary modifiers. It should not require a separate hold modifier.

On key down:

1. If no switcher session exists, open a session using shortcut slot 0's filtering, ordering, grouping, and appearance settings.
2. Start the session in search-editing mode before the panel is shown.
3. Do not advance to the second window as a normal next-window trigger does.
4. Keep the panel open when the chord's modifiers are released.
5. Place the caret on the triggering key path once the panel can accept input, so the first typed character is not lost.

If a switcher session is already active:

- When search is off, enter search mode and focus the field.
- When search is already active, keep it active and restore the caret rather than toggling it off.
- Do not replace the active session's shortcut index or rebuild its filters.

Escape closes the whole switcher for a session opened by the dedicated search command. This matches the existing started-in-search behavior. The existing in-session Search shortcut retains its toggle behavior and first-Escape-exits-search behavior.

## Product decisions

- Treat the dedicated global shortcut as another entry point to the existing Search Pro feature. Recording the shortcut may remain available, but invoking it must call the existing Search feature gate before opening or modifying a session.
- Reuse shortcut slot 0's effective presentation and filtering preferences. Do not add parallel search-only filters in the first version.
- Leave the preference unassigned by default to avoid conflicting with Spotlight and other launchers.
- Respect the existing “ignore shortcuts” application exceptions. When AltTab disables global shortcuts for the frontmost application, it must disable this command too.
- Do not change the existing searchShortcut preference. That remains the local “Search while active” binding; use a distinct key such as globalSearchShortcut.

## Design

### 1. Specify the entry-point state transition

Add a pure resolver beside SearchModeResolver, or extend it with an entry-point decision that distinguishes:

- inactive session → create a slot-0 session starting in search;
- active session with search off → enter editing without changing the session configuration;
- active session already editing → place the caret only;
- Pro gate denied → no session or UI mutation.

Document this behavior in src/switcher/state/SearchModeResolverSpecs.md and cover it in SearchModeResolverTests.swift. Keeping the decision pure prevents Carbon, AppKit, and Pro-transition side effects from being mixed into the state rules.

### 2. Add the persisted preference

Update src/preferences/Preferences.swift:

- Register globalSearchShortcut with an empty shortcut as its default.
- Add it to staticShortcutKeys so persistence, secure decoding, reset, and corruption checks follow the existing shortcut path.
- Expose Preferences.globalSearchShortcut.

No migration is required because the new preference is optional and has no legacy representation. Add persistence coverage alongside the existing static-shortcut tests.

### 3. Register it as a true global hotkey

Update KeyboardEventsTestable.globalShortcutsIds to allocate one stable Carbon hotkey ID outside the numbered hold/next ranges. Avoid deriving the ID from shortcutCount, so adding or removing numbered shortcuts cannot change it.

Update ControlsTab shortcut registration:

- Classify globalSearchShortcut as global with trigger phase down.
- Register/unregister it through the existing KeyboardEvents.addGlobalShortcut and removeGlobalShortcut paths.
- Include it in toggleGlobalShortcuts, conflict detection, native Command-Tab reconciliation, preference-change handling, and cleanup.
- Do not add it to ModifierReleaseLog switching chords; it has no release-driven focus behavior.

Add keyboard-routing tests proving:

- the global ID resolves to globalSearchShortcut;
- key down executes once and key up does nothing;
- autorepeat does not repeatedly reopen or toggle search;
- application exceptions unregister and restore it with other global shortcuts;
- numbered shortcut IDs remain stable.

### 4. Add a dedicated action

Add a globalSearchShortcut action in src/switcher/ShortcutAction.swift. Route it to a focused entry point such as App.showSearchUi().

App.showSearchUi() should:

1. Run the Search Pro gate before creating a session.
2. If a session is active, enable search editing without changing shortcutIndex.
3. Otherwise create a session through the same initialization path as showUiOrCycleSelection, using shortcut index 0 and an explicit summon mode such as search.

Refactor App.showUiOrCycleSelection only enough to share session creation and initial rendering. Prefer an explicit summon mode over a Boolean such as forceSearch.

| Summon mode | Initial selection | Initial search mode | Release behavior |
| --- | --- | --- | --- |
| Window cycling | Existing default/next-window rules | Effective shortcut style | Existing focus/hold/search rules |
| Dedicated search | First eligible result without an artificial cycle | Editing | Keep open |

The visible work must remain ahead of bookkeeping on this latency-critical path. Preserve the existing main-thread IPC ordering and defer first-responder work in the same way as TilesView.enableSearchEditing().

### 5. Track how the session was opened

Store an explicit entry style on SwitcherSession, for example a SwitcherEntry enum with cycling and dedicatedSearch cases.

Use it when resolving Escape and modifier release instead of reconstructing intent from Preferences.effectiveShortcutStyle(session.shortcutIndex). A dedicated search session must not accidentally focus a result when the user releases the global chord.

Keep searchQuery session-scoped and reset it through the existing startSearchSession/endSearchSession lifecycle.

### 6. Add the setting

In ControlsTab:

- Add a recorder row labelled **Search windows**.
- Place it with global activation controls, not in ShortcutsWhenActiveSheet.
- Add a Pro badge using the existing Search feature gate presentation.
- Add “Search windows”, “window search”, and the recorder label to the settings search index.
- Reuse CustomRecorderControl and the existing conflict prompt.

Update ControlsTab.staticShortcutLabels, or introduce a separate global-action label map if that name would become misleading, so conflict messages can name “Search windows” even when the control is not currently built.

### 7. Handle conflicts and platform behavior

Test and specify:

- A collision with a numbered global trigger prompts to unassign the existing action.
- A collision with a local when-active shortcut follows the existing scope-aware conflict policy.
- ⌘Space may be reserved by Spotlight. If Carbon registration fails, show the same registration failure feedback used by existing global shortcuts rather than silently accepting the preference.
- Escape absorption remains session-driven; binding Escape as the global search shortcut must not leave the HID event tap enabled while idle.
- IME marked text, keyboard layouts, and dead keys continue through the existing search-field routing.
- An empty result set still shows the search UI and allows query editing.
- Pressing the command during an active delayed-display summon cannot create a second session or show stale unfiltered content.

## Tests

Follow the repository's specs/tests/implementation triad.

### Unit tests

- SearchModeResolverTests.swift: every inactive/active/editing/gated transition.
- KeyboardEventsTests.swift: global ID routing, down/up/repeat behavior, disabled-shortcut behavior, and interaction with an active session.
- Preferences tests: default-empty value, round-trip persistence, invalid/corrupt data handling, and reset.
- ControlsTab tests: scope classification, registration, conflict naming, unassignment, and Settings search indexing.
- App or extracted summon-resolver tests: dedicated search uses slot 0, does not cycle, forces keep-open, and preserves an already-active session's slot.
- Pro transition tests: trial/pro execution, first free-pass behavior, and locked denial without creating a session.

### Manual verification

1. Assign ⌥Space, invoke it from Finder, and immediately type a query.
2. Confirm the first character is retained on cold and warm summons.
3. Release all modifiers and confirm the search panel stays open.
4. Press Escape and confirm the panel closes in one press.
5. Open normally with ⌥Tab, then press the dedicated command; confirm the current filter configuration and selection session remain intact while search gains focus.
6. Test Spotlight-conflicting ⌘Space and verify clear failure/conflict feedback.
7. Test with a non-Roman IME and composed text.
8. Test with an app covered by “ignore shortcuts” exceptions.
9. Lock Pro and verify the existing Search gate/free-pass UI is used.
10. Confirm the existing local Search shortcut still toggles search during a normal session.

## Delivery sequence

1. Add specs and pure transition tests.
2. Add the preference and stable global hotkey ID.
3. Add registration, conflict, and disable/restore behavior.
4. Refactor the summon path and implement showSearchUi().
5. Add the Controls setting and Settings-search metadata.
6. Add integration and Pro-transition tests.
7. Run ai/test.sh.
8. Copy the command from ai/build.sh and confirm the app target compiles.
9. Manually verify cold-start typing, modifier release, Escape, IME input, and exception handling.

## Acceptance criteria

- A user can assign one ordinary global chord specifically to window search.
- Invoking it from any allowed application opens AltTab with the search field ready for the first typed character.
- Releasing the chord does not focus a window or dismiss the panel.
- Escape dismisses a dedicated-search session in one press.
- Invoking it during an existing session enters or restores search without changing that session's shortcut-specific configuration.
- Shortcut conflicts and registration failures are visible and recoverable.
- Existing numbered shortcuts, the local Search shortcut, Pro gating, native macOS shortcut handling, and IME behavior do not regress.

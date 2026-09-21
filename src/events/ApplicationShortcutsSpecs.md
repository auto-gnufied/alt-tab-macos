# Application Shortcuts — Specs

Application shortcuts bind a physical key chord to an application bundle identifier. A mapping focuses an eligible tracked window, activates a running process when no tracked window is usable, or launches the configured bundle when it is not running. If the target application is already frontmost, the action is a no-op.

## Chords and routing

- Persist hardware key code plus project-owned Command, Control, Option, Shift, and Function bits.
- The display label is metadata and is not part of chord equality or hashing.
- Runtime `fn` comes from `CGEventFlags.maskSecondaryFn`.
- Recording accepts Function only when the physical Core Graphics Function flag is present. AppKit's implicit `.function` flag on arrows and F-row keys is not treated as a held `fn` modifier.
- Chords containing Function are detected by the permanent passive keyboard tap, using both tracked flags-changed state and the same physical Function-state query as the recorder. A separate active tap suppresses a matched down/up pair when macOS permits its creation; detection remains functional without it. Duplicate delivery across the two taps is rejected by event timestamp.
- Chords without Function use Carbon hotkeys. The application-shortcut Carbon handler forwards events with other signatures to the next handler.
- The active tap is enabled only when shortcuts are enabled, recording is inactive, and at least one Function mapping exists.

## Target resolution

For windows belonging to the configured bundle identifier:

1. Ignore phantom and hidden-tab windows.
2. Prefer the last-attended real window.
3. Otherwise prefer the real window with the lowest `lastFocusOrder`.
4. Otherwise use a windowless application placeholder.
5. If no tracked target exists, activate a matching running application.
6. If none is running, resolve and open its application URL.

Only one launch request per bundle identifier may be in flight.

## Persistence and conflicts

- Decode the stored array lossily: one malformed row does not remove valid mappings.
- A chord conflict compares key code and modifier bits, not its display label.
- Recording a chord already assigned to another application or AltTab action requires confirmation before the previous assignment is cleared.
- Delete clears a chord; Escape cancels recording; modifier-only recordings are rejected.

## Settings

Application Shortcuts is opened directly from Controls, never by attaching a second sheet while Additional Controls is already attached. The picker offers running applications and applications from disk. Each row exposes the app icon/name, recorder, and remove action with accessibility labels.

## Tests

`KeyboardEventsTests.swift` pins modifier normalization, display-label-independent chord identity, resilient decoding, target precedence, phantom/tab rejection, windowless fallback, and launch deduplication. Runtime registration and actual focus/launch remain integration behavior validated with a Release build and manual checks on macOS.

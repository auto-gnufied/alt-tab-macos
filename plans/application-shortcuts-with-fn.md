# Application Shortcuts with fn Support

## Summary

AltTab currently cannot bind a global shortcut to a specific application. Its global actions summon or cycle the switcher; none stores an application target or directly launches/activates one.

AltTab also cannot currently represent fn as a shortcut modifier:

- CustomRecorderControl.allowedModifiers contains only Command, Control, Option, and Shift.
- The vendored ShortcutRecorder SRCocoaModifierFlagsMask removes NSEvent.ModifierFlags.function.
- ShortcutRecorder's Carbon mask contains only Command, Option, Shift, and Control.
- ATShortcut.cleaned() explicitly removes fn and documents that it is unsupported.
- RegisterEventHotKey is the normal global-hotkey path, but the Carbon modifier representation used by that path has no supported fn bit.

Apple exposes the physical fn state on low-level keyboard events as CGEventFlags.maskSecondaryFn. AltTab already owns a CGEvent tap and has Accessibility permission, so fn plus a letter is implementable through a narrowly scoped event-tap matcher rather than Carbon registration.

## Goal

Let the user create mappings such as:

| Shortcut | Application |
| --- | --- |
| fn+G | Google Chrome |
| fn+T | iTerm |
| fn+S | Slack |

Pressing a mapping should:

1. Focus the application's most recently attended usable window when the app is running.
2. Activate the running application when no tracked window is available.
3. Launch the application when it is not running.
4. Do nothing destructive when the target is already frontmost.

The first version should not cycle among an application's windows. That can be a separate, explicit behavior later.

## User experience

Add an **Application Shortcuts** section to Settings → Controls.

Each row contains:

- the selected application's icon and localized name;
- a shortcut recorder that accepts fn, Command, Control, Option, and Shift;
- a remove button.

An **Add Application Shortcut…** button opens an application picker. Reuse the application discovery and NSOpenPanel patterns from ExceptionsTab so users can select a running app or any .app bundle.

New mappings are unassigned until the user records a chord. The recorder displays fn using the literal “fn” label, for example “fn G”.

If a chord conflicts with another application mapping or an existing AltTab global shortcut, show the existing conflict dialog and offer to unassign the old binding.

## Scope and decisions

- Support fn combined with a non-modifier key. An fn-only shortcut is out of scope.
- Support fn with letters, digits, punctuation, arrows, and function-row keys when macOS delivers an unambiguous hardware key code.
- Keep existing Command/Control/Option/Shift application shortcuts on the Carbon path when possible. Route any chord containing fn through the event-tap path.
- Respect AltTab's “ignore shortcuts” application exceptions.
- Application shortcuts are independent of numbered switcher shortcut slots and their filters.
- Store the target primarily by bundle identifier, with its last known bundle URL and display name as recovery metadata.
- Do not require the target app to be running when the shortcut is configured or invoked.
- Avoid a polling implementation. Use the existing keyboard event stream and NSWorkspace/application model.

## Architecture

### 1. Add a domain model

Create a feature folder such as src/app-shortcuts containing:

- ApplicationShortcut.swift
- ApplicationShortcutSpecs.md
- ApplicationShortcutTests.swift
- ApplicationShortcutResolver.swift
- ApplicationShortcutController.swift

Suggested persisted value:

~~~swift
struct ApplicationShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var chord: ApplicationShortcutChord?
    var bundleIdentifier: String
    var lastKnownBundleURL: URL?
    var displayName: String
}

struct ApplicationShortcutChord: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: ApplicationShortcutModifiers
}
~~~

ApplicationShortcutModifiers should be a project-owned OptionSet containing command, control, option, shift, and function. Do not use Carbon flags as the persisted representation because Carbon cannot faithfully represent fn.

Persist the mappings as JSON through the existing CachedUserDefaults/Preferences patterns. Validate decoded entries and drop only malformed rows rather than the whole list.

### 2. Normalize keyboard input

Add a pure ApplicationShortcutMatcher that converts input into the project-owned chord:

- use the hardware key code, not the produced character, so mappings remain stable across Shift and do not depend on the current text field;
- map CGEvent flags Command, Control, Alternate, Shift, and SecondaryFn into ApplicationShortcutModifiers;
- discard Caps Lock, numeric-pad, non-coalesced, and device-dependent noise;
- require exact modifier equality after normalization;
- treat autorepeat as a single press unless a future action explicitly opts into repeat.

The matcher must use CGEventFlags.maskSecondaryFn for runtime fn detection. NSEvent.ModifierFlags.function can be used by the settings recorder, but tests must confirm its conversion to the same project-owned function bit.

Do not reuse ATShortcut.cleaned(), because it intentionally removes fn and is coupled to switcher hold/release semantics.

### 3. Add an fn-capable recording control

Do not globally widen CustomRecorderControl or ShortcutRecorder's masks in the first implementation. Doing so could change how every existing switcher shortcut records F-keys, navigation keys, and implicit function flags.

Create ApplicationShortcutRecorderControl as a small feature-specific control:

- capture keyDown and flagsChanged while recording;
- read NSEvent.ModifierFlags.function for fn;
- store a project-owned ApplicationShortcutChord;
- render the chord with a formatter that prints fn before the other modifier glyphs;
- allow Delete to clear and Escape to cancel;
- reject modifier-only recordings;
- expose validation/conflict results without converting through ShortcutRecorder.Shortcut.

Before committing this approach, build a diagnostic test surface that logs both NSEvent.function and CGEvent.maskSecondaryFn for fn+letter, F-row keys, globe/fn keyboards, and external keyboards. The recorder/runtime representations must agree for fn+G and fn+T.

### 4. Route global shortcuts

Keep the existing Carbon RegisterEventHotKey path unchanged for current AltTab shortcuts.

For application mappings:

- mappings without fn may use a dedicated Carbon registration adapter;
- mappings with fn use a dedicated CGEvent tap matcher;
- both paths emit the same ApplicationShortcutTriggered(id) action on the main queue.

The fn event tap should be separate from the current passive session tap if suppression is required. Configure it as narrowly as possible:

- enable it only while at least one fn application shortcut exists;
- listen only for keyDown and keyUp;
- perform only immutable chord lookup and repeat suppression inside the callback;
- dispatch application activation to the appropriate queue;
- return nil only for an exact configured chord, allowing every unrelated event through;
- consume both halves of a matched chord as needed so the G or T keystroke does not leak into the previously active application;
- re-enable after tapDisabledByTimeout or tapDisabledByUserInput and log the cause.

Never call AppKit, NSWorkspace, NSRunningApplication, or accessibility APIs in the event-tap callback. The callback must remain bounded and allocation-light.

### 5. Maintain a thread-safe fn lookup snapshot

The keyboard callback runs on BackgroundWork.keyboardAndMouseAndTrackpadEventsThread while settings changes occur on the main thread.

Build an immutable lookup keyed by normalized key code and modifier bits. Publish complete snapshots atomically or through a small lock whose critical section only loads a reference. Do not read UserDefaults or traverse UI controls from the event callback.

The snapshot should contain only the mapping ID needed to enqueue the action. Resolve the application after leaving the callback.

### 6. Resolve the target application

Create a pure ApplicationTargetResolver with inputs describing:

- configured bundle identifier and last-known URL;
- known tracked applications and windows;
- frontmost application;
- running applications matching the bundle identifier;
- whether the configured bundle URL still exists.

Decision order:

1. If AltTab tracks eligible windows for the app, choose the most recently attended representative and focus it through the existing Window.focus() path.
2. Otherwise, if a matching NSRunningApplication exists, call activate with activateAllWindows.
3. Otherwise, resolve the current bundle URL using NSWorkspace.urlForApplication(withBundleIdentifier:).
4. Fall back to the stored URL if it still identifies the configured bundle.
5. Launch with NSWorkspace.openApplication.
6. If the app is no longer installed, surface a non-modal notification or mark the row as missing in Settings.

NSWorkspace and NSRunningApplication calls may run off-main as documented and as the repository's main-thread IPC policy already permits. Window.focus() must retain its existing queue and focus-intent behavior.

When several processes share a bundle identifier, prefer the process already represented in AltTab's tracked application model; otherwise use the regular, non-terminated NSRunningApplication.

### 7. Choose the target window predictably

Extract a pure window-selection policy rather than relying on incidental Windows.list order.

Prefer:

1. the app's last confirmed attended/focused representative;
2. the most recently focused eligible non-phantom window;
3. a windowless application placeholder;
4. application activation when no usable window exists.

Exclude windows the user cannot focus, but do not apply the active switcher shortcut's visual filters. An application shortcut means “go to this application,” not “find a tile visible under the current switcher configuration.”

For Chrome and other tabbed applications, reuse the existing representative/focus machinery so a tracked real window is raised rather than launching a duplicate instance.

### 8. Integrate preference and lifecycle changes

Add Preferences.applicationShortcuts and route changes through PreferencesEvents.

On change:

1. validate and deduplicate mappings;
2. unregister removed Carbon mappings;
3. register added non-fn mappings;
4. publish the new fn lookup snapshot;
5. enable or disable the fn event tap;
6. refresh conflict metadata and Settings rows.

When global shortcuts are disabled for an ignored application, unregister Carbon application mappings and make the fn matcher snapshot empty. Restore both when shortcuts are enabled again.

At termination, restore any native shortcut state touched by registration and release event-tap resources through the existing keyboard lifecycle.

## fn-specific risks

### Globe/fn system actions

macOS can assign the Globe/fn key to system actions such as changing input source, dictation, or emoji. Verify whether fn+letter still carries maskSecondaryFn under each configuration. Do not claim fn alone or override configured system actions.

### F-row and navigation keys

Apple's NSEvent function flag also describes function and navigation keys, while Core Graphics provides the more specific SecondaryFn runtime flag. Tests must distinguish:

- physical fn+G;
- G alone;
- F1 with and without physical fn;
- fn+arrow;
- an external keyboard without an fn key.

### Secure Input

The existing code documents that Secure Input can filter keyDown from event taps. When Secure Input is active, fn application shortcuts may be unavailable. Detect and log this condition where feasible; do not poll. Document the limitation in the setting help text if live testing confirms it.

### Event suppression

A listen-only tap can observe fn+G but cannot prevent G from reaching the old foreground application. Use an active tap only for configured fn chords and return immediately. Verify that key-up suppression does not leave the old app believing a key remains held.

## Settings implementation

Create ApplicationShortcutsView under the Controls feature folder.

Each row should support:

- application selection/change;
- shortcut recording;
- validation state;
- removal;
- missing-application state;
- VoiceOver labels for the app, chord, and buttons.

Reuse icon fetching and bundle selection logic already present in ExceptionsTab where appropriate, but keep the persisted model independent of ExceptionEntry.

Register “Application shortcuts,” “Open application,” “Switch application,” “fn,” and each configured application name with SettingsSearchIndex.

## Conflict policy

Create a unified normalized-chord conflict query covering:

- existing numbered global switcher shortcuts;
- application shortcuts;
- any future dedicated global actions;
- known macOS-reserved chords where detectable.

For fn chords, compare the project-owned modifier representation. For existing Carbon shortcuts, convert Command, Control, Option, and Shift into that representation.

If a user assigns a duplicate:

1. name the existing action or target application;
2. offer **Unassign existing shortcut and continue**;
3. mutate preferences through the normal callback path;
4. atomically publish the new registry so there is never a window where both actions fire.

## Tests

Follow the repository's specs/tests/implementation triad.

### Pure unit tests

- ApplicationShortcutChord encoding and decoding.
- Modifier normalization includes SecondaryFn and removes irrelevant bits.
- fn+G matches fn+G, but not G, Shift+fn+G, or F-key function flags.
- Autorepeat fires once.
- Duplicate mappings resolve deterministically.
- Target resolution chooses tracked MRU window, running application, resolved URL, stored URL, then missing.
- Multiple processes with one bundle identifier choose the tracked regular application.
- The frontmost target is a no-op.
- Ignored-application state produces an empty active registry.

### Keyboard integration tests

- A configured fn chord fires from CGEvent keyDown.
- Its keyDown and keyUp do not leak to the previous app.
- Unconfigured fn chords pass through unchanged.
- Adding the first fn mapping enables the tap; removing the last disables it.
- A disabled-by-timeout tap is restored.
- Settings changes publish a complete lookup snapshot under concurrent key input.
- Existing Option+Tab and other Carbon shortcuts remain unchanged.

### Application behavior tests

- Chrome running with windows focuses its chosen window.
- Chrome running without a tracked window activates the process.
- Chrome not running launches from the resolved bundle URL.
- A moved application is found again by bundle identifier.
- A removed application produces visible, non-blocking feedback.
- A window on another Space uses the existing Window.focus() behavior.
- Repeated presses while launch is in flight do not start duplicate launches.

### Manual matrix

Test on built-in and external keyboards:

| Chord | Expected |
| --- | --- |
| fn+G | Chrome launches or focuses; G does not leak |
| fn+T | iTerm launches or focuses; T does not leak |
| G | No application action |
| Shift+fn+G | No action unless explicitly assigned |
| fn+F1 | Matches only its exact recorded representation |
| fn+Arrow | Matches without breaking normal arrows when unassigned |

Also test each macOS Globe/fn system setting, Secure Input on/off, another Space, a minimized target window, a hidden target app, and a target that is already frontmost.

## Delivery sequence

1. Add the specs and pure chord/target resolver tests.
2. Build a temporary diagnostic surface to verify fn flags across supported keyboards and macOS versions.
3. Add the persisted model and Settings rows.
4. Add the feature-specific fn-capable recorder.
5. Add non-fn Carbon registration for application mappings.
6. Add the active, narrowly scoped fn event tap and immutable lookup snapshot.
7. Add application target resolution and focus/launch execution.
8. Integrate conflicts, ignored-app disabling, and lifecycle cleanup.
9. Run ai/test.sh.
10. Copy and run the command from ai/build.sh.
11. Complete the manual keyboard and application matrix.

## Acceptance criteria

- The user can assign fn+G to Chrome and fn+T to iTerm.
- The chord works globally without requiring Command, Control, Option, or Shift.
- A matched letter does not leak into the previously active app.
- A running target's most relevant window is focused; an installed non-running target launches.
- Existing AltTab shortcuts and normal unassigned fn chords behave exactly as before.
- Mappings survive relaunch and application moves.
- Duplicate and unavailable shortcuts produce clear feedback.
- The input callback stays bounded and performs no AppKit, workspace, accessibility, disk, or UserDefaults work.

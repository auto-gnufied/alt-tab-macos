# Eliminate false-positive `fn` application shortcuts

## Status

Design only. No implementation changes are part of this document.

## Problem

With an application shortcut mapping of `fn+T` to iTerm2, typing a plain `T` in Firefox's address bar can activate iTerm2. One reproducible string is `reddit.com/r/t`: entering the final `t` switches focus to iTerm2. Restarting AltTab does not prevent the problem, while quitting AltTab does. Secure Event Input is disabled during this reproduction.

This is a high-severity input-routing bug. A global shortcut must never trigger unless the modifier state for that specific key-down proves that its full chord is pressed. Incorrectly moving focus while the user types can lose input, submit text to the wrong application, or expose typed content to an unintended window.

## Evidence and current diagnosis

The saved mapping is unambiguous: hardware key code 17 plus the project-owned Function bit maps to `com.googlecode.iterm2`. Activating exactly that target on a plain `T` strongly indicates that AltTab is manufacturing or retaining the Function bit before its exact dictionary lookup. Firefox and the URL text have no direct role in application activation.

The current runtime matcher has three sources of Function state:

1. `CGEvent.flags` on the current key-down;
2. `CGEventSource.flagsState(.combinedSessionState)` sampled during the current key-down;
3. the unbounded `physicalFunctionIsDown` boolean last written by an earlier `flagsChanged` event.

It combines them with logical OR. Once the cached boolean becomes true, a missed, reordered, or differently represented Function-release event lets any later mapped letter match an `fn` chord even when both the current key-down and the current system state say Function is up.

The cache was added by commit `67204975` while investigating why `fn` shortcuts did not fire. That earlier failure was subsequently traced to Enpass 6.12.6 holding Secure Event Input, which prevents key-down delivery to event taps. Cached modifier state cannot solve Secure Input because there is no key-down to match. It instead creates a false-positive path after delivery resumes.

There is a second relevant input source on this machine. Karabiner maps Left Control to `keyboard_fn` for a Logitech MX Keys Mini (vendor `0x046d`, product `0xb369`). Synthetic modifier transitions from the virtual HID device may differ from the built-in keyboard's transitions. The fix must support that device without trusting historical state indefinitely.

The plain-key symptom was not reproduced with computer-use-generated input. That input does not traverse the same physical HID and Karabiner path, so it neither disproves the bug nor validates a fix.

## Required invariants

1. A key-down may match an `fn` shortcut only when Function is proven down for that key-down.
2. An earlier Function-down event is never sufficient evidence for a later key-down.
3. Missing a modifier release may cause a false negative, but must never cause a false positive.
4. Runtime chord comparison remains exact after normalization. `fn+T`, `fn+shift+T`, and plain `T` are distinct.
5. The event-tap callback remains bounded: no AppKit, Accessibility, workspace queries, preference reads, or application activation inside it.
6. A matched key-down and its key-up are suppressed as a pair. Unmatched typing always passes through.
7. The active and passive taps can observe the same event but may dispatch at most one action.
8. Non-`fn` application shortcuts continue to use Carbon and are unaffected.
9. Secure Input remains a documented OS limitation. AltTab must report it rather than attempting to infer missing keystrokes or bypass the protection.

## Design

### 1. Make runtime chord construction event-scoped

Introduce a pure `ApplicationShortcutRuntimeMatcher` in `KeyboardEventsTestable.swift`. Its input should contain only facts belonging to one key-down:

```swift
struct ApplicationShortcutRuntimeInput {
    let keyCode: UInt16
    let flags: CGEventFlags
    let isRepeat: Bool
    let timestamp: UInt64
}
```

Normalize Command, Control, Option, Shift, and Function directly from `input.flags`. Function at runtime comes from `CGEventFlags.maskSecondaryFn`. Discard Caps Lock, numeric-pad, non-coalesced, and other noise exactly as today. Look up the resulting `ApplicationShortcutKey` with exact modifier equality.

Remove `physicalFunctionIsDown` and `ApplicationShortcutModifiers.withPhysicalFunction`. Do not add Function based on an earlier `flagsChanged` event. Do not use `NSEvent.ModifierFlags.function` at runtime because AppKit adds it implicitly to arrows, navigation keys, and function-row keys.

The matcher should fail closed: if a device produces a key-down without `maskSecondaryFn`, that event does not match an `fn` shortcut. Supporting a device by guessing is unacceptable because guessing turns normal typing into global actions.

Before landing, use diagnostic logging in a local build to verify that both the built-in Function key and the MX Keys Mini's Karabiner-generated Function modifier put `maskSecondaryFn` on the letter key-down. If Karabiner does not, document that mapping as unsupported until its output can be made event-correct. Do not restore an unbounded cache.

### 2. Remove Function tracking from the application-shortcut tap

The application-shortcut active tap no longer needs `.flagsChanged`. Return its event mask to `.keyDown` and `.keyUp`, as specified in the original design. AltTab's permanent passive keyboard tap may continue receiving `.flagsChanged` for switcher hold/release behavior; application shortcuts must not consume that state.

`CGEventSource.flagsState` may remain in the settings recorder, where AppKit's event flags need to be distinguished from an implicit `.function` bit. It must not augment modifiers for global runtime matching.

### 3. Put enablement and recording state in the match decision

Today the passive tap can find a mapping while application shortcuts are disabled or the recorder is active, then rely on `activate` to reject it later. Make the callback decision atomic under the existing small lock:

```text
enabled && !recording
    → exact chord lookup
    → repeat/timestamp decision
    → enqueue mapping ID
```

When disabled or recording, return “unmatched” before touching duplicate or suppression state. This prevents an event matched under one state from becoming actionable after a state transition.

### 4. Give the active tap ownership of suppression

The active application-shortcut tap remains authoritative when it exists:

- classify the current key-down with the pure matcher;
- record the key code only after an exact match;
- dispatch the mapping ID once for a non-repeat key-down;
- suppress the matched key-down;
- suppress the corresponding key-up and remove it from the set.

Clear `suppressedKeyCodes` whenever the tap is disabled, times out, is disabled by user input, recording begins, or mappings are refreshed. This prevents an old matched press from swallowing an unrelated future key-up.

The permanent listen-only tap remains a detection fallback when creation of the active tap fails. It uses the same event-scoped matcher but cannot suppress input. Keep timestamp deduplication because both taps can see the same physical event during enable/disable transitions. Model the result as a small enum such as `.unmatched`, `.matched(UUID)`, and `.duplicate(UUID)` so dispatch and suppression behavior are explicit rather than encoded in a tuple of optionals and booleans.

### 5. Add privacy-safe diagnostics

Under `--logs=debug`, log only when the hardware key code is present in an application-shortcut lookup. Record:

- tap source (`active` or `passive`);
- key code;
- normalized modifier bit mask;
- whether `maskSecondaryFn` was present on the event;
- repeat status;
- match result and duplicate status.

Do not log produced characters, surrounding text, focused fields, URLs, or application content. These diagnostics make a future false positive attributable without turning AltTab into a keystroke logger.

Add an info-level message when a configured `fn` shortcut cannot receive key-downs because Secure Input is active, but emit it only on an existing lifecycle event or failed invocation diagnostic. Do not poll.

## Implementation sequence

1. Add the pure runtime input and matcher types to `KeyboardEventsTestable.swift`.
2. Add failing sequence tests that demonstrate a historical Function-down must not affect a later plain key-down.
3. Change both application-shortcut key-down routes to call the pure matcher.
4. Remove `physicalFunctionIsDown`, `withPhysicalFunction`, the application tap's `.flagsChanged` mask, and the corresponding test that blesses cached Function injection.
5. Move enabled/recording checks into the locked match decision.
6. Make active/passive ownership and timestamp deduplication explicit.
7. Reset suppression state on every tap or configuration transition.
8. Update `ApplicationShortcutsSpecs.md` to state the event-scoped evidence rule and fail-closed behavior.
9. Add debug-only candidate-key diagnostics.
10. Run focused tests, the full unit suite through `ai/test.sh`, and the build command copied from `ai/build.sh`.

## Automated tests

Add tests for the matcher and state transitions rather than mirroring dictionary implementation details.

### Modifier correctness

- `T` with no modifiers does not match `fn+T`.
- `T` with `maskSecondaryFn` matches `fn+T`.
- `T` with Shift does not match `fn+T`.
- `T` with Function and Shift does not match `fn+T` but does match `fn+shift+T`.
- Caps Lock, numeric-pad, and non-coalesced noise do not change the normalized chord.
- AppKit's implicit `.function` remains ignored by the recorder unless the physical Core Graphics Function state is present.

### Event sequences

- Function-down → `fn+T` key-down → Function-up dispatches once.
- Function-down → missing Function-up → plain `T` key-down does not dispatch.
- `fn+F` activates Firefox → plain `T` does not activate iTerm2.
- A tap timeout between Function-down and plain `T` cannot produce a match.
- Active and passive delivery with the same timestamp dispatches once.
- Two distinct presses with different timestamps each dispatch once.
- Autorepeat remains suppressed for a matched held chord but does not dispatch repeatedly.
- Refreshing mappings or entering recording mode clears matched key-up suppression.
- Disabled and recording states cannot create a pending activation.

### Persistence and routing

- Existing non-`fn` Carbon shortcut tests continue to pass.
- Multiple mapped letters cannot affect one another through shared modifier state.
- Removing the `fn+T` mapping immediately makes plain and modified T events pass through.

## Manual validation matrix

Run these checks with Secure Input confirmed off. Use an instrumented local build with `--logs=debug` for the first pass.

| Input source | Scenario | Expected result |
| --- | --- | --- |
| Built-in keyboard Function | Press and release every configured `fn` application shortcut | Exactly one activation; typed letter does not leak |
| Built-in keyboard Function | Release Function before pressing the mapped letter | No activation |
| MX Keys Mini with Karabiner Left Control → Function | Invoke every configured shortcut | The letter key-down contains `maskSecondaryFn`; exactly one activation |
| MX Keys Mini with Karabiner | Invoke `fn+F`, release it, then type `reddit.com/r/t` in Firefox | Firefox retains focus and the full string is entered |
| MX Keys Mini with Karabiner | Alternate rapidly among `fn+F`, `fn+T`, and ordinary typing | Only deliberate chords activate applications |
| Either keyboard | Hold Function and hold a mapped letter through repeat | One activation; no repeated launches or leaked characters |
| Either keyboard | Type paragraphs containing all mapped letters in Firefox, Messages, Notes, and a terminal | Zero application activations |
| Secure Input on | Try an `fn` shortcut | No activation, no inference from modifier history, and a useful diagnostic |
| Secure Input off again | Retry the chord, then type its letter plainly | Chord works; plain letter never activates |
| Active tap forced unavailable in a diagnostic build | Invoke a chord | Passive fallback activates once but cannot suppress the source letter |

Use Karabiner-EventViewer during the MX Keys Mini checks to retain evidence of the virtual HID event sequence. The standalone Swift process currently lacks Input Monitoring permission, so it is not a valid event-tracing substitute.

## Acceptance criteria

- The reported Firefox sequence cannot activate iTerm2 across 100 repetitions, including immediately after using `fn+F` to enter Firefox.
- Ten minutes of continuous typing containing every mapped letter produces zero application activations.
- Each configured `fn` shortcut works from the built-in keyboard and from the validated Karabiner mapping.
- A real chord dispatches exactly once and its letter does not appear in the source application.
- Missing modifier releases, tap timeouts, app switches, mapping refreshes, and recording transitions cannot convert a plain key into an `fn` chord.
- Non-`fn` Carbon shortcuts behave exactly as before.
- `ai/test.sh` passes and the app target builds using the command from `ai/build.sh`.

## Rejected approaches

- **Clear the cached boolean after activation or on restart.** The reproduced issue survives restart and can recur as soon as another modifier transition is missed.
- **Expire cached Function state after a timeout.** This narrows the false-positive window but cannot eliminate it.
- **Ignore T in Firefox or text fields.** This hides one reproduction while leaving every other mapped letter and application vulnerable.
- **Inspect the focused field in the event-tap callback.** Accessibility and AppKit calls can block and are forbidden on this latency-critical background callback.
- **Use AppKit's `.function` bit globally.** It is implicit on several non-Function keys and creates a different class of false positives.
- **Move `fn` shortcuts to Carbon.** Carbon's hotkey modifier representation does not faithfully support Function.
- **Bypass Secure Input.** Secure Input intentionally prevents interception; guessing missing key-downs weakens correctness and user expectations.

## Files expected to change during implementation

- `src/events/KeyboardEvents.swift`
- `src/events/KeyboardEventsTestable.swift`
- `src/events/KeyboardEventsTests.swift`
- `src/events/ApplicationShortcutsSpecs.md`

No preference migration or persisted chord-format change is required.

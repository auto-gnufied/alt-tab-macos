# Fn+Y → Ghostty: debugging findings

Investigation date: 2026-09-20, America/New_York.

## Conclusion

**The live session has Secure Event Input enabled. This is a concrete blocker for the implementation's global Fn shortcuts and the leading explanation for the reported failure.** Both of AltTab's relevant keyboard event taps exist and are enabled, and the saved Ghostty mapping is correct. Secure Input blocks the background keyboard events that those taps need to recognize Y; adding another event tap or recovering the Fn modifier does not recover a missing key-down event.

The session registry identifies PID **607**, `/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow`, as its Secure Input owner. This identifies the reported owner, **not why loginwindow is retaining Secure Input**. The investigation did not establish whether this is a stale login/unlock state or another system condition.

Confidence is high that Secure Input is a current blocker. An end-to-end success test with Secure Input inactive is still necessary before calling it the only defect. I did not disable Secure Input, restart loginwindow, log out, restart AltTab, change shortcuts, or modify implementation files.

## Reproduction and computer-control limitation

1. Used the available computer-use tool to inspect Finder and AltTab.
2. Attempted `finder.pressKey('fn+y')`. The tool rejected it with `keyNotFound("fn")`. It did **not** send a valid Fn+Y chord, so that attempt is not evidence of an AltTab failure.
3. Asked for a physical Fn+Y press with a non-Ghostty app focused. The user reported: “I did and nothing happened.”
4. Opened AltTab → Controls → Application shortcuts. The live UI displayed `Ghostty — fn Y` and `Emacs — fn F`; neither recorder was recording. Closed the sheet with Done without editing either mapping.
5. Queried CoreGraphics event-tap state and Carbon Secure Input state outside the shell sandbox. Secure Input was true on both checks. The first check reported Codex frontmost; the later check reported iTerm2 frontmost. Although Finder was targeted by computer control before the second check, the native query reported iTerm2, so this is not presented as a confirmed Finder-frontmost measurement.

## Runtime evidence

### Process and build identity

| Item | Observed value |
| --- | --- |
| macOS | 27.0, build 26A428 |
| AltTab PID | 79160 |
| Running executable | `/Applications/AltTab.app/Contents/MacOS/AltTab` |
| Installed executable modification/signing time | September 20, 2026, approximately 21:37 |
| Ghostty PID | 31189 |
| Ghostty executable | `/Applications/Ghostty.app/Contents/MacOS/ghostty` |
| Checkout HEAD | `bfc329fb` — Implement review comments for application shortcuts |

The installed executable contains the diagnostic string `could not create application-shortcut suppression tap; passive detection remains active`. That string belongs to the uncommitted fallback revision, rather than HEAD's older `could not create application-shortcut event tap` message. This establishes that the installed binary contains that newer code path; it is not a byte-for-byte verification of every current source edit.

The computer-use app inventory initially claimed AltTab was not running. Native process inspection and its accessible live settings proved otherwise. The process evidence is authoritative here.

### Persisted mapping

`defaults read com.lwouis.alt-tab-macos applicationShortcuts` returned valid JSON containing:

```json
{
  "id": "26A5FB3A-13A0-4F66-A576-806816D34829",
  "bundleIdentifier": "com.mitchellh.ghostty",
  "bundleURL": "file:///Applications/Ghostty.app/",
  "displayName": "Ghostty",
  "chord": {
    "keyLabel": "Y",
    "keyCode": 16,
    "modifiers": 16
  }
}
```

Hardware key code 16 is Y; the project's modifier bit 16 is Function. The other persisted mapping is Fn+F for Emacs (key code 3), so these two mappings do not collide. The live UI agrees with the stored mapping.

The existing uncommitted `Preferences.setJson` correction is relevant to the earlier persistence bug, but the current Ghostty row is successfully stored and displayed. There is no evidence that persistence is the present failure.

### Event taps and Secure Input

An unsandboxed read-only Swift diagnostic called `CGGetEventTapList` and `IsSecureEventInputEnabled`:

```text
tapList 0 count 24 secureInput true
pid 79160 point 1 options 0 enabled true  mask 1c00
pid 79160 point 1 options 1 enabled true  mask 1400
pid 79160 point 0 options 0 enabled false mask 400
```

| Tap | Decoded observation | Meaning |
| --- | --- | --- |
| Application-shortcut tap | Session, active/filter, keyDown + keyUp + flagsChanged, enabled | The Fn suppression tap was created and is enabled. |
| Permanent keyboard tap | Session, listen-only, keyDown + flagsChanged, enabled | The passive fallback also exists and is enabled. |
| Escape tap | HID, active/filter, keyDown, disabled | Expected outside an active switcher session; not the Fn route. |

`CGGetEventTapList` returning success and an enabled tap does not establish that protected keyboard events are delivered to its callback.

The second diagnostic again returned `secureInput true`, with the same two relevant taps enabled. The system registry independently contained:

```text
"kCGSSessionSecureInputPID"=607
```

`ps -p 607 -o pid,comm` resolved that PID to loginwindow.

An initial sandboxed attempt returned `CGGetEventTapList` error `268435459`, no taps, no frontmost application, and Secure Input false. Those results were discarded because the diagnostic could not access the live session. Only successful unsandboxed results support this report.

Apple's technical note explains that Secure Event Input prevents keyboard interception through event taps, including when the process enabling protection is in the background. See [Apple TN2150, Using Secure Event Input Fairly (archived mirror)](https://leopard-adc.pepas.com/technotes/tn2007/tn2150.html). The repository independently documents key-down filtering in `src/events/KeyboardEvents.swift:211` and anticipated this limitation in `plans/application-shortcuts-with-fn.md:227`.

## Why the current fallback does not solve this

The relevant source path is:

```text
Y keyDown delivered to either session tap
  → ApplicationShortcutsController.handleKeyDown
  → normalize modifiers / recover physical Fn
  → fnMappings[(keyCode: 16, modifiers: 16)]
  → dispatch activate(mappingID) to main
  → select Ghostty window and focus, or activate/launch Ghostty
```

- `src/events/KeyboardEvents.swift:39`: the permanent passive tap calls the application-shortcut matcher only from its key-down branch.
- `src/events/KeyboardEvents.swift:305`: the active tap's flags-changed branch records Fn state and returns; it does not trigger the application action.
- `src/events/KeyboardEvents.swift:323`: `handleKeyDown` merges the incoming flags, session Fn state, and tracked Fn state. Every one of those recovery paths still needs a Y key-down to call this method.
- `src/events/KeyboardEvents.swift:363`: Fn chords go into `fnMappings`; they do not register Carbon hotkeys. Therefore the existing Carbon route does not provide a fallback for Fn+Y.
- `src/events/KeyboardEvents.swift:400`: Ghostty focus/launch is downstream of a successful match. Ghostty is already running, so this reproduction is principally an activation case rather than a cold-launch case.

The recorder uses local `NSButton.keyDown` handling (`AdditionalControlsSheet.swift:72`) and queries physical Fn state. Recording a shortcut inside the foreground settings window does not prove that a background global event tap will later receive that same chord.

The passive fallback helps when creation of the active suppression tap fails. Physical Fn recovery helps when a delivered key event lacks the expected modifier flag. Neither addresses Secure Input filtering the key event itself.

## Other explanations assessed

| Hypothesis | Assessment |
| --- | --- |
| Wrong application or missing chord | Contradicted by stored JSON and live settings. |
| Running an entirely pre-fallback build | Contradicted by the installed binary's fallback diagnostic string. Exact source/binary equivalence was not established. |
| Failure to create either relevant event tap | Contradicted by the successful live tap listing. |
| Shortcut recorder left active / active tap disabled | Active tap was enabled and the UI showed `fn Y`, not `Type shortcut`. |
| Finder exception ignores shortcuts | The settings displayed Finder's Ignore shortcuts as Never. |
| Ghostty already frontmost, causing the deliberate no-op | The user tested from another application; diagnostic snapshots also showed non-Ghostty applications frontmost. |
| Ghostty focus or launch bug | Not independently ruled out; event delivery is blocked upstream, so no successful invocation of that path was observed. |
| Other keyboard software consumes/remaps Y | BetterMouse and other taps were present, but no evidence establishes they consume Fn+Y. Do not blame them based on their presence. |

## Additional source findings, separate from the current blocker

1. **The passive fallback does not actually maintain tracked Fn state.** Its flags-changed branch never updates `ApplicationShortcutsController.physicalFunctionIsDown`; only the active tap does. If the active tap cannot be created, the fallback relies on event flags and the live session-state query. `ApplicationShortcutsSpecs.md` currently describes the passive path more strongly than the implementation supports. This is not the observed failure because the active tap exists.
2. **Disabled/recording states are gated late on the passive route.** `refresh()` still populates `fnMappings` while disabled or recording, and the permanent tap can match and enqueue an action. `activate()` checks the state again and ordinarily discards it. A state transition between matching and dispatch could make that stale event actionable. This is a separate correctness issue, not evidence for this Fn+Y failure.
3. **There is no Secure Input diagnostic in the feature.** The original plan identified this limitation, but the implementation does not call `IsSecureEventInputEnabled` or explain the condition in the Application Shortcuts sheet. A correct-looking recorded shortcut consequently fails without an explanation.

## Verification limits and follow-up, without implementing changes

The earlier review's “Verified Working” statement and helper-unit-test results are not evidence of successful global Fn delivery in this session. The existing shortcut tests exercise normalization, decoding, chord identity, target selection, and launch gating; they do not demonstrate physical Fn+Y delivery under Secure Input.

AltTab was launched without a logging argument, and its stdout/stderr point to `/dev/null`. The inspected temporary logs contained no useful trace of this invocation. No debugger was attached and no callback-level trace of the user's physical chord was captured. Consequently, the causal conclusion combines the successful live Secure Input/tap queries, the reproduced symptom, Apple's documented behavior, and the source path; it does not claim a captured failing stack trace.

For the next validation session:

1. Investigate why loginwindow retains Secure Input. Let legitimate secure input finish normally. If loginwindow remains the reported owner on an ordinary desktop, a user-controlled fresh login/restart is a possible recovery experiment, not a proven fix from this investigation.
2. Confirm `IsSecureEventInputEnabled()` is false with a successful native session query before retesting physical Fn+Y from a non-Ghostty application.
3. Verify Ghostty activation, matched-key suppression, and Fn+F independently. Then cover cold launch, held-key repeat, and another Space.
4. If the failure persists with Secure Input false, trace event receipt, normalized chord, mapping match, enabled/recording state, and activation result in that order. This would distinguish event routing from Ghostty window focusing.
5. In a future authorized implementation change, add an on-demand Secure Input diagnostic/help message and tests for the passive fallback's state handling. Do not try to bypass Secure Input or clear another process's protection from AltTab.

No app build or unit test run was needed for this documentation-only investigation. The six pre-existing modified source/spec files were left untouched; this report is the only repository file added.

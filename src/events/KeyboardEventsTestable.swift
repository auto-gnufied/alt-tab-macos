import Cocoa
import Carbon.HIToolbox.Events
import ShortcutRecorder

struct ApplicationShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var chord: ApplicationShortcutChord?
    var bundleIdentifier: String
    var bundleURL: URL?
    var displayName: String
}

struct ApplicationShortcutChord: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: UInt
    let keyLabel: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }
}

struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements = [Element]()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) { elements.append(element) }
            else { _ = try container.decode(DiscardedCodableValue.self) }
        }
        self.elements = elements
    }
}

private struct DiscardedCodableValue: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd { _ = try array.decode(DiscardedCodableValue.self) }
            return
        }
        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in object.allKeys { _ = try object.decode(DiscardedCodableValue.self, forKey: key) }
            return
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { return }
        if (try? value.decode(Bool.self)) != nil { return }
        if (try? value.decode(Double.self)) != nil { return }
        _ = try value.decode(String.self)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

enum ApplicationShortcutModifiers {
    static let command = UInt(1 << 0)
    static let control = UInt(1 << 1)
    static let option = UInt(1 << 2)
    static let shift = UInt(1 << 3)
    static let function = UInt(1 << 4)

    static func from(_ flags: CGEventFlags) -> UInt {
        var result: UInt = 0
        if flags.contains(.maskCommand) { result |= command }
        if flags.contains(.maskControl) { result |= control }
        if flags.contains(.maskAlternate) { result |= option }
        if flags.contains(.maskShift) { result |= shift }
        if flags.contains(.maskSecondaryFn) { result |= function }
        return result
    }

    static func from(_ flags: NSEvent.ModifierFlags, physicalFunction: Bool) -> UInt {
        var result: UInt = 0
        if flags.contains(.command) { result |= command }
        if flags.contains(.control) { result |= control }
        if flags.contains(.option) { result |= option }
        if flags.contains(.shift) { result |= shift }
        if physicalFunction { result |= function }
        return result
    }

    static func string(_ modifiers: UInt) -> String {
        var result = ""
        if modifiers & function != 0 { result += "fn " }
        if modifiers & control != 0 { result += "⌃" }
        if modifiers & option != 0 { result += "⌥" }
        if modifiers & shift != 0 { result += "⇧" }
        if modifiers & command != 0 { result += "⌘" }
        return result
    }

    static func carbon(_ modifiers: UInt) -> UInt32 {
        var result = UInt32(0)
        if modifiers & command != 0 { result |= UInt32(cmdKey) }
        if modifiers & control != 0 { result |= UInt32(controlKey) }
        if modifiers & option != 0 { result |= UInt32(optionKey) }
        if modifiers & shift != 0 { result |= UInt32(shiftKey) }
        return result
    }
}

struct ApplicationShortcutRuntimeInput {
    let keyCode: UInt16
    let flags: CGEventFlags
    let isRepeat: Bool
    let timestamp: UInt64
}

enum ApplicationShortcutRuntimeMatch: Equatable {
    case unmatched
    case matched(UUID)
    case duplicate(UUID)
}

enum ApplicationShortcutRuntimeMatcher {
    static func match(_ input: ApplicationShortcutRuntimeInput,
                      mappings: [ApplicationShortcutKey: UUID]) -> UUID? {
        let modifiers = ApplicationShortcutModifiers.from(input.flags)
        return mappings[ApplicationShortcutKey(keyCode: input.keyCode, modifiers: modifiers)]
    }

    static func classify(_ input: ApplicationShortcutRuntimeInput,
                         mappings: [ApplicationShortcutKey: UUID], enabled: Bool, recording: Bool,
                         lastTriggeredTimestamp: UInt64) -> (ApplicationShortcutRuntimeMatch, UInt64) {
        guard enabled, !recording, let id = match(input, mappings: mappings) else {
            return (.unmatched, lastTriggeredTimestamp)
        }
        guard !input.isRepeat, input.timestamp != lastTriggeredTimestamp else {
            return (.duplicate(id), lastTriggeredTimestamp)
        }
        return (.matched(id), input.timestamp)
    }
}

struct ApplicationShortcutKey: Hashable {
    let keyCode: UInt16
    let modifiers: UInt
}

struct ApplicationShortcutTargetCandidate: Equatable {
    let id: String
    let windowId: CGWindowID?
    let isPhantom: Bool
    let isTabbed: Bool
    let isWindowless: Bool
    let lastFocusOrder: Int
}

enum ApplicationShortcutTargetResolver {
    static func resolve(_ candidates: [ApplicationShortcutTargetCandidate], lastAttendedWindowId: CGWindowID?) -> String? {
        let eligible = candidates.filter { !$0.isPhantom && !$0.isTabbed }
        if let lastAttendedWindowId,
           let attended = eligible.first(where: { $0.windowId == lastAttendedWindowId && !$0.isWindowless }) {
            return attended.id
        }
        if let window = eligible.filter({ !$0.isWindowless }).min(by: { $0.lastFocusOrder < $1.lastFocusOrder }) {
            return window.id
        }
        return eligible.first(where: { $0.isWindowless })?.id
    }
}

final class ApplicationLaunchGate {
    private var bundleIdentifiers = Set<String>()
    private let lock = NSLock()

    func begin(_ bundleIdentifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return bundleIdentifiers.insert(bundleIdentifier).inserted
    }

    func finish(_ bundleIdentifier: String) {
        lock.lock()
        bundleIdentifiers.remove(bundleIdentifier)
        lock.unlock()
    }
}

class KeyboardEventsTestable {
    static var globalShortcutsIds: [String: Int] {
        var ids = [String: Int]()
        (0..<Preferences.maxShortcutCount).forEach { ids[Preferences.indexToName("nextWindowShortcut", $0)] = $0 }
        (0..<Preferences.maxShortcutCount).forEach { ids[Preferences.indexToName("holdShortcut", $0)] = Preferences.maxShortcutCount + $0 }
        return ids
    }
}

@discardableResult
func handleKeyboardEvent(_ globalId: Int?, _ shortcutState: ShortcutState?, _ keyCode: UInt32?,
                         _ modifiers: NSEvent.ModifierFlags?, _ isARepeat: Bool, _ event: NSEvent? = nil,
                         _ recordedHoldRelease: Bool = false) -> Bool {
    if let event, shouldAbsorbSearchEditingKeyDown(event) {
        switch TilesView.handleSearchEditingKeyDown(event) {
        case .handled: return true
        case .passToField:
            TilesView.giveTheFieldTheCaretNow()
            return false
        case .passToShortcuts: break
        }
    }
    logKeyboardEvent(globalId, shortcutState, keyCode, modifiers, isARepeat)
    let someShortcutTriggered = triggerMatchingShortcuts(globalId, shortcutState, keyCode, modifiers,
                                                          isARepeat, recordedHoldRelease)
    return someShortcutTriggered
}

private func logKeyboardEvent(_ globalId: Int?, _ shortcutState: ShortcutState?, _ keyCode: UInt32?, _ modifiers: NSEvent.ModifierFlags?, _ isARepeat: Bool) {
    if let globalId, let shortcutState {
        Logger.debug {
            let shortcut = KeyboardEventsTestable.globalShortcutsIds.first { $0.value == globalId }
            return "globalShortcut:\(shortcut?.key ?? "") state:\(shortcutState)"
        }
        return
    }
    // TODO: use proper pattern from SwiftBeaver to not compute SymbolicModifierFlagsTransformer when logs are off
    Logger.debug {
        let modifiersAsString = modifiers.flatMap { SymbolicModifierFlagsTransformer.shared.transformedValue(NSNumber(value: $0.rawValue)) }
        let keyCodeAsString = keyCode.flatMap { SymbolicKeyCodeTransformer.shared.transformedValue(NSNumber(value: $0)) }
        return "keys:\(modifiersAsString ?? "")\(keyCodeAsString ?? "") isARepeat:\(isARepeat)"
    }
}

/// A hold modifier released late, or never delivered at all, leaves the previous session open, and the next
/// event to arrive is usually the next summon's key-down. Settle that stale session against the tile the
/// user was looking at BEFORE this event's action can move it: settled after, `nextWindowShortcut` has
/// already cycled, so the release commits one tile past what was asked and every alt-tab from then on
/// ping-pongs against a window the user never picked, seen live. Run again after the loop, for a session this
/// very event opened with the modifier already back up.
private func settleLostHoldRelease(_ recordedHoldRelease: Bool = false) {
    guard let session = SwitcherSession.current else { return }
    ControlsTab.shortcuts[Preferences.indexToName("holdShortcut", session.shortcutIndex)]?
        .settleLostRelease(recordedHoldRelease)
}

private func shouldAbsorbSearchEditingKeyDown(_ event: NSEvent?) -> Bool {
    guard let event, event.type == .keyDown, SwitcherSession.isActive, TilesPanel.shared.isKeyWindow, TilesView.isSearchEditing else {
        return false
    }
    return true
}

private func triggerMatchingShortcuts(_ globalId: Int?, _ shortcutState: ShortcutState?, _ keyCode: UInt32?,
                                      _ modifiers: NSEvent.ModifierFlags?, _ isARepeat: Bool,
                                      _ recordedHoldRelease: Bool) -> Bool {
    settleLostHoldRelease()
    var someShortcutTriggered = false
    for shortcut in ControlsTab.shortcuts.values {
        if shortcut.matches(globalId, shortcutState, keyCode, modifiers) && shortcut.shouldTrigger() {
            shortcut.executeAction(isARepeat)
            // we want to pass-through alt-up to the active app, since it saw alt-down previously
            if !shortcut.id.starts(with: "holdShortcut") {
                someShortcutTriggered = true
            }
        }
        shortcut.stopRepeatIfUp()
    }
    settleLostHoldRelease(recordedHoldRelease)
    // TODO if we manage to move all keyboard listening to the background thread, we'll have issues returning this boolean
    // this function uses many objects that are also used on the main-thread. It also executes the actions
    // we'll have to rework this whole approach. Today we rely on somewhat in-order events/actions
    // special attention should be given to SwitcherSession.current which is being set when executing the nextWindowShortcut action
    return someShortcutTriggered
}

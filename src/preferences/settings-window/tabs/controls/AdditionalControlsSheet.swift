import Cocoa
import Carbon.HIToolbox.Events

class AdditionalControlsSheet: SheetWindow {
    // Localized labels live here once. `searchableStrings` and `makeContentView` both reference
    // these constants so changing a string takes one edit, and search can't silently miss a row
    // because of a typo divergence between the two paths.
    private static let title = NSLocalizedString("Additional controls", comment: "")
    private static let titleMiscellaneous = NSLocalizedString("Miscellaneous", comment: "")
    private static let labelArrows = NSLocalizedString("Select windows using arrow keys", comment: "")
    private static let labelVim = NSLocalizedString("Select windows using vim keys", comment: "")
    private static let labelMouse = NSLocalizedString("Select windows on mouse hover", comment: "")
    private static let labelCursorFollow = NSLocalizedString("Cursor follows focus", comment: "")
    private static let labelTrackpad = NSLocalizedString("Trackpad haptic feedback", comment: "")
    private static let labelApplicationShortcuts = NSLocalizedString("Application shortcuts…", comment: "")

    /// Pre-build search index for the open-button. See `SettingsSearchIndex.sheetSearchableStrings`.
    static let searchableStrings: [String] = [
        title, titleMiscellaneous,
        labelArrows, labelVim, labelMouse,
        labelCursorFollow, labelTrackpad,
        labelApplicationShortcuts,
    ] + CursorFollowFocus.allCases.map { $0.localizedString }

    override func makeContentView() -> NSView {
        let enableArrows = TableGroupView.Row(leftTitle: Self.labelArrows,
            rightViews: [LabelAndControl.makeSwitch("arrowKeysEnabled", extraAction: ControlsTab.arrowKeysEnabledCallback)])
        let enableVimKeys = TableGroupView.Row(leftTitle: Self.labelVim,
            rightViews: [LabelAndControl.makeSwitch("vimKeysEnabled", extraAction: ControlsTab.vimKeysEnabledCallback)])
        let enableMouse = TableGroupView.Row(leftTitle: Self.labelMouse,
            rightViews: [LabelAndControl.makeSwitch("mouseHoverEnabled")])
        let enableCursorFollowFocus = TableGroupView.Row(leftTitle: Self.labelCursorFollow,
            rightViews: [LabelAndControl.makeDropdown("cursorFollowFocus", CursorFollowFocus.allCases)])
        let enableTrackpadHapticFeedback = TableGroupView.Row(leftTitle: Self.labelTrackpad,
            rightViews: [LabelAndControl.makeSwitch("trackpadHapticFeedbackEnabled")])
        let applicationShortcutsButton = Button(Self.labelApplicationShortcuts) { _ in ApplicationShortcutsSheet.show() }
        ControlsTab.arrowKeysCheckbox = enableArrows.rightViews[0] as? Switch
        ControlsTab.vimKeysCheckbox = enableVimKeys.rightViews[0] as? Switch
        ControlsTab.arrowKeysEnabledCallback(ControlsTab.arrowKeysCheckbox)
        ControlsTab.vimKeysEnabledCallback(ControlsTab.vimKeysCheckbox)
        let table1 = TableGroupView(title: Self.title, width: SheetWindow.width)
        _ = table1.addRow(enableArrows)
        _ = table1.addRow(enableVimKeys)
        _ = table1.addRow(enableMouse)
        let table2 = TableGroupView(title: Self.titleMiscellaneous, width: SheetWindow.width)
        _ = table2.addRow(enableCursorFollowFocus)
        _ = table2.addRow(enableTrackpadHapticFeedback)
        _ = table2.addRow(leftText: Self.labelApplicationShortcuts, rightViews: [applicationShortcutsButton])
        let view = TableGroupSetView(originalViews: [table1, table2], padding: 0)
        return view
    }
}

final class ApplicationShortcutRecorder: NSButton {
    private var chord: ApplicationShortcutChord?
    private let onChange: (ApplicationShortcutChord?) -> Void
    private var recording = false

    override var acceptsFirstResponder: Bool { true }

    init(_ chord: ApplicationShortcutChord?, _ onChange: @escaping (ApplicationShortcutChord?) -> Void) {
        self.chord = chord
        self.onChange = onChange
        super.init(frame: .zero)
        bezelStyle = .rounded
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        self.onAction = { [weak self] _ in self?.beginRecording() }
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) { finishRecording(); return }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            chord = nil
            onChange(nil)
            finishRecording()
            return
        }
        let modifiers = ApplicationShortcutModifiers.from(event.modifierFlags)
        guard modifiers != 0 else { NSSound.beep(); return }
        let label = event.charactersIgnoringModifiers?.uppercased() ?? String(event.keyCode)
        chord = ApplicationShortcutChord(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label)
        onChange(chord)
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        ApplicationShortcutsController.setRecording(false)
        refreshTitle()
        return super.resignFirstResponder()
    }

    private func beginRecording() {
        recording = true
        ApplicationShortcutsController.setRecording(true)
        title = NSLocalizedString("Type shortcut", comment: "")
        window?.makeFirstResponder(self)
    }

    private func finishRecording() {
        recording = false
        ApplicationShortcutsController.setRecording(false)
        refreshTitle()
        window?.makeFirstResponder(nil)
    }

    private func refreshTitle() {
        guard let chord else {
            title = NSLocalizedString("Record Shortcut", comment: "")
            return
        }
        title = ApplicationShortcutModifiers.string(chord.modifiers) + chord.keyLabel
    }
}

final class ApplicationShortcutsSheet: SheetWindow {
    private static var shared: ApplicationShortcutsSheet?
    private var rowsStack: NSStackView!

    static func show() {
        if shared == nil { shared = ApplicationShortcutsSheet() }
        guard let shared else { return }
        shared.rebuild()
        SettingsWindow.shared.beginSheetWithSearchHighlight(shared)
    }

    override func makeContentView() -> NSView {
        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = TableGroupSetView.tableGroupSpacing
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.widthAnchor.constraint(equalToConstant: SheetWindow.width).isActive = true
        rebuild()
        return rowsStack
    }

    private func rebuild() {
        guard let rowsStack else { return }
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let table = TableGroupView(title: NSLocalizedString("Application Shortcuts", comment: ""), width: SheetWindow.width)
        Preferences.applicationShortcuts.forEach { mapping in
            let recorder = ApplicationShortcutRecorder(mapping.chord) { chord in
                Self.update(mapping.id, chord)
            }
            let remove = Button(NSLocalizedString("Remove", comment: "")) { [weak self] _ in
                var mappings = Preferences.applicationShortcuts
                mappings.removeAll { $0.id == mapping.id }
                Preferences.set("applicationShortcuts", mappings)
                self?.rebuild()
            }
            _ = table.addRow(leftText: mapping.displayName, rightViews: [recorder, remove])
        }
        rowsStack.addArrangedSubview(table)
        let add = Button(NSLocalizedString("Add Application…", comment: "")) { [weak self] _ in self?.addApplication() }
        rowsStack.addArrangedSubview(add)
        add.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true
    }

    private static func update(_ id: UUID, _ chord: ApplicationShortcutChord?) {
        var mappings = Preferences.applicationShortcuts
        if let chord {
            for index in mappings.indices where mappings[index].id != id && mappings[index].chord == chord {
                mappings[index].chord = nil
            }
        }
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        mappings[index].chord = chord
        Preferences.set("applicationShortcuts", mappings)
        shared?.rebuild()
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url),
                  let bundleIdentifier = bundle.bundleIdentifier else { return }
            var mappings = Preferences.applicationShortcuts
            if mappings.contains(where: { $0.bundleIdentifier == bundleIdentifier }) { return }
            let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            mappings.append(ApplicationShortcut(id: UUID(), chord: nil, bundleIdentifier: bundleIdentifier,
                                                bundleURL: url, displayName: name))
            Preferences.set("applicationShortcuts", mappings)
            self?.rebuild()
        }
    }
}

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

    /// Pre-build search index for the open-button. See `SettingsSearchIndex.sheetSearchableStrings`.
    static let searchableStrings: [String] = [
        title, titleMiscellaneous,
        labelArrows, labelVim, labelMouse,
        labelCursorFollow, labelTrackpad,
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
        let view = TableGroupSetView(originalViews: [table1, table2], padding: 0)
        return view
    }
}

final class ApplicationShortcutRecorder: NSButton {
    private var chord: ApplicationShortcutChord?
    private let onChange: (ApplicationShortcutChord?) -> Bool
    private var recording = false

    override var acceptsFirstResponder: Bool { true }

    init(_ chord: ApplicationShortcutChord?, _ onChange: @escaping (ApplicationShortcutChord?) -> Bool) {
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
            if onChange(nil) { chord = nil }
            finishRecording()
            return
        }
        let physicalFn = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        let modifiers = ApplicationShortcutModifiers.from(event.modifierFlags, physicalFunction: physicalFn)
        guard modifiers != 0 else { NSSound.beep(); return }
        let label = event.charactersIgnoringModifiers?.uppercased() ?? String(event.keyCode)
        let candidate = ApplicationShortcutChord(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label)
        if onChange(candidate) { chord = candidate }
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
                Preferences.setJson("applicationShortcuts", mappings)
                self?.rebuild()
            }
            let icon = NSImageView(image: AppDisplayInfo.genericIcon)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let name = NSTextField(labelWithString: mapping.displayName)
            name.setAccessibilityLabel(mapping.displayName)
            recorder.setAccessibilityLabel(String(format: NSLocalizedString("Shortcut for %@", comment: ""), mapping.displayName))
            remove.setAccessibilityLabel(String(format: NSLocalizedString("Remove %@", comment: ""), mapping.displayName))
            _ = table.addRow(leftViews: [icon, name], rightViews: [recorder, remove])
            Self.loadIcon(mapping, into: icon)
        }
        rowsStack.addArrangedSubview(table)
        let add = Button(NSLocalizedString("Add Application…", comment: "")) { [weak self] sender in
            guard let button = sender as? NSButton else { return }
            self?.showAddMenu(button)
        }
        rowsStack.addArrangedSubview(add)
        add.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true
        resizeToFitContent()
    }

    private static func update(_ id: UUID, _ chord: ApplicationShortcutChord?) -> Bool {
        var mappings = Preferences.applicationShortcuts
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return false }
        guard resolveConflicts(id, chord, &mappings) else { return false }
        mappings[index].chord = chord
        Preferences.setJson("applicationShortcuts", mappings)
        shared?.rebuild()
        return true
    }

    private static func resolveConflicts(_ id: UUID, _ chord: ApplicationShortcutChord?, _ mappings: inout [ApplicationShortcut]) -> Bool {
        guard let chord else { return true }
        let applicationConflict = mappings.first { $0.id != id && $0.chord == chord }
        let altTabConflict = chord.modifiers & ApplicationShortcutModifiers.function == 0
            ? ControlsTab.shortcuts.values.first(where: {
                UInt16($0.shortcut.carbonKeyCode) == chord.keyCode
                    && $0.shortcut.carbonModifierFlags == ApplicationShortcutModifiers.carbon(chord.modifiers)
            }) : nil
        var names = [String]()
        if let applicationConflict { names.append(applicationConflict.displayName) }
        if let altTabConflict, let label = ControlsTab.conflictLabel(altTabConflict.id) { names.append(label) }
        guard !names.isEmpty else { return true }
        let list = names.map { "• " + ControlsTab.nonBreaking($0) }.joined(separator: "\n")
        let message = String(format: NSLocalizedString("Shortcut already assigned to:\n%@", comment: ""), list)
        guard ControlsTab.confirmUnassigningConflict(message) else { return false }
        if let applicationConflict, let oldIndex = mappings.firstIndex(where: { $0.id == applicationConflict.id }) {
            mappings[oldIndex].chord = nil
        }
        if let altTabConflict { ControlsTab.unassignShortcut(altTabConflict.id) }
        return true
    }

    private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let running = NSMenuItem(title: NSLocalizedString("Add a running app", comment: ""), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        runningApplications().forEach { app in
            guard let bundleIdentifier = app.bundleIdentifier else { return }
            let item = NSMenuItem(title: app.localizedName ?? bundleIdentifier, action: #selector(addRunningApplication(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bundleIdentifier
            if let image = app.icon?.copy() as? NSImage { image.size = NSSize(width: 16, height: 16); item.image = image }
            submenu.addItem(item)
        }
        running.submenu = submenu
        menu.addItem(running)
        let disk = NSMenuItem(title: NSLocalizedString("Add an app from disk", comment: ""), action: #selector(addApplicationFromDisk(_:)), keyEquivalent: "")
        disk.target = self
        menu.addItem(disk)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func runningApplications() -> [NSRunningApplication] {
        let existing = Set(Preferences.applicationShortcuts.map { $0.bundleIdentifier })
        var byIdentifier = [String: NSRunningApplication]()
        (Windows.list.map { $0.application.runningApplication } + NSWorkspace.shared.runningApplications).forEach {
            guard $0.activationPolicy == .regular, let identifier = $0.bundleIdentifier,
                  !existing.contains(identifier), byIdentifier[identifier] == nil else { return }
            byIdentifier[identifier] = $0
        }
        return byIdentifier.values.sorted {
            ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
        }
    }

    @objc private func addRunningApplication(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
        addApplication(bundleIdentifier, app.bundleURL, app.localizedName)
    }

    // periphery:ignore:parameters sender - NSMenuItem target/action signature
    @objc private func addApplicationFromDisk(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url),
                  let bundleIdentifier = bundle.bundleIdentifier else { return }
            let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            self?.addApplication(bundleIdentifier, url, name)
        }
    }

    private func addApplication(_ bundleIdentifier: String, _ bundleURL: URL?, _ displayName: String?) {
        var mappings = Preferences.applicationShortcuts
        guard !mappings.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        let name = displayName ?? bundleURL?.deletingPathExtension().lastPathComponent ?? bundleIdentifier
        mappings.append(ApplicationShortcut(id: UUID(), chord: nil, bundleIdentifier: bundleIdentifier,
                                            bundleURL: bundleURL, displayName: name))
        Preferences.setJson("applicationShortcuts", mappings)
        rebuild()
    }

    private func resizeToFitContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let contentView else { return }
            contentView.layoutSubtreeIfNeeded()
            setContentSize(contentView.fittingSize)
        }
    }

    private static func loadIcon(_ mapping: ApplicationShortcut, into imageView: NSImageView) {
        DispatchQueue.global(qos: .userInitiated).async { [weak imageView] in
            let image = mapping.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? AppDisplayInfo.resolve(bundleId: mapping.bundleIdentifier).icon
            DispatchQueue.main.async { imageView?.image = image }
        }
    }
}

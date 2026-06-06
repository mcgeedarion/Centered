import Cocoa

private enum PreferencesUIConstants {
    static let margins: CGFloat = 20
    static let labelWidth: CGFloat = 180
    static let spacing: CGFloat = 10
    static let smallSpacing: CGFloat = 6
    static let tinySpacing: CGFloat = 4
    static let keyRecorderHeight: CGFloat = 24
    static let tableViewHeight: CGFloat = 110
    static let keyRecorderFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    static let sectionFontSize: CGFloat = 13
    static let hintFontSize: CGFloat = 11
    static let windowWidth: CGFloat = 460
    static let windowHeight: CGFloat = 440
    static let bottomPadding: CGFloat = 16
}

protocol PreferencesHost: AnyObject {
    var settings: Settings { get }
    func rebindHotKey(to binding: HotKeyBinding)
    func rebindAllWindowsHotKey(to binding: HotKeyBinding)
    func setExcludedBundleIDs(_ ids: Set<String>)
    func preferencesWindowDidClose()
}

final class KeyRecorderField: NSTextField {

    var binding: HotKeyBinding { didSet { stringValue = binding.displayString } }
    var onBindingChanged: ((HotKeyBinding) -> Void)?
    /// Binding the recorder should reject as a duplicate of the sibling field.
    var conflictBinding: HotKeyBinding?

    private var isRecording = false

    init(binding: HotKeyBinding) {
        self.binding = binding
        super.init(frame: .zero)
        stringValue     = binding.displayString
        isEditable      = false
        isSelectable    = false
        isBordered      = true
        backgroundColor = .controlBackgroundColor
        alignment       = .center
        font            = PreferencesUIConstants.keyRecorderFont
        translatesAutoresizingMaskIntoConstraints = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        stringValue = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard hasRequiredModifier(mods), !isEscapeKey(event.keyCode) else {
            cancelRecording()
            return
        }
        commitRecording(HotKeyBinding(keyCode: event.keyCode, modifiers: mods))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        let preview = event.modifierFlags.hotKeyDisplayString
        stringValue = preview.isEmpty ? "Press shortcut…" : preview + "_"
    }

    private func hasRequiredModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
    }

    private func isEscapeKey(_ keyCode: UInt16) -> Bool {
        keyCode == 53 // kVK_Escape
    }

    private func cancelRecording() {
        isRecording = false
        stringValue = binding.displayString
    }

    private func commitRecording(_ newBinding: HotKeyBinding) {
        if let conflict = conflictBinding, newBinding == conflict {
            isRecording = false
            stringValue = binding.displayString
            showConflictAlert(for: newBinding)
            return
        }
        binding     = newBinding
        isRecording = false
        onBindingChanged?(newBinding)
    }

    private func showConflictAlert(for conflicting: HotKeyBinding) {
        let alert = NSAlert()
        alert.messageText     = "Shortcut Already in Use"
        alert.informativeText = "\(conflicting.displayString) is already assigned to the other shortcut. Please choose a different combination."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "OK")
        if let w = window { alert.beginSheetModal(for: w) }
        else              { alert.runModal() }
    }
}

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    // MARK: - Properties
    private weak var host: PreferencesHost?
    private var openPanel: NSOpenPanel?
    private var excludedIDs: Set<String> = []

    // Lazy UI components
    private lazy var activeKeyRecorder: KeyRecorderField = makeActiveKeyRecorder()
    private lazy var allKeyRecorder: KeyRecorderField = makeAllKeyRecorder()
    private lazy var tableView: NSTableView = makeTableView()
    private lazy var removeButton: NSButton = makeRemoveButton()

    // MARK: - Initialization
    init(host: PreferencesHost) {
        self.host = host
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PreferencesUIConstants.windowWidth, height: PreferencesUIConstants.windowHeight),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        win.title = "Centered Preferences"
        win.center()
        super.init(window: win)
        win.delegate = self
        buildUI()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: - Window Delegate
    func windowDidBecomeKey(_ notification: Notification) {
        guard let settings = host?.settings else { return }
        let activeBinding = settings.centerActiveBinding
        let allBinding    = settings.centerAllBinding
        activeKeyRecorder.binding         = activeBinding
        allKeyRecorder.binding            = allBinding
        activeKeyRecorder.conflictBinding = allBinding
        allKeyRecorder.conflictBinding    = activeBinding
        excludedIDs = settings.excludedBundleIDs
        tableView.reloadData()
    }

    func windowWillClose(_ notification: Notification) {
        openPanel?.cancel(nil)
        openPanel = nil
        host?.preferencesWindowDidClose()
    }

    // MARK: - UI Building
    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let hotkeysHeader = sectionLabel("Hotkeys")
        let activeLabel   = fieldLabel("Center Active Window")
        let allLabel      = fieldLabel("Center All Windows")
        let hotkeysHint = hintLabel("Click a field, then press your desired shortcut. Escape cancels.")

        let exclusionsHeader = sectionLabel("Auto-Center Exclusions")
        let exclusionsHint   = hintLabel("Apps listed here will never be auto-centered when focused.")
        excludedIDs          = host?.settings.excludedBundleIDs ?? []

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType          = .bezelBorder
        scrollView.documentView        = tableView

        let addButton = makeButton(title: "Add App…", action: #selector(addExclusion))

        let version    = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let aboutLabel = hintLabel("Centered v\(version) — personal use build")

        let subviews: [NSView] = [
            hotkeysHeader, activeLabel, activeKeyRecorder,
            allLabel, allKeyRecorder, hotkeysHint,
            exclusionsHeader, exclusionsHint, scrollView,
            addButton, removeButton, aboutLabel,
        ]
        subviews.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview($0)
        }

        applyConstraints(
            in: cv,
            hotkeysHeader:    hotkeysHeader,
            activeLabel:      activeLabel,
            allLabel:         allLabel,
            hotkeysHint:      hotkeysHint,
            exclusionsHeader: exclusionsHeader,
            exclusionsHint:   exclusionsHint,
            scrollView:       scrollView,
            addButton:        addButton,
            aboutLabel:       aboutLabel
        )
    }

    // MARK: - UI Component Factories
    private func makeActiveKeyRecorder() -> KeyRecorderField {
        let activeBinding = host?.settings.centerActiveBinding ?? .centerActive
        let recorder = KeyRecorderField(binding: activeBinding)
        recorder.onBindingChanged = { [weak self] b in
            self?.allKeyRecorder.conflictBinding = b
            self?.host?.rebindHotKey(to: b)
        }
        return recorder
    }

    private func makeAllKeyRecorder() -> KeyRecorderField {
        let allBinding = host?.settings.centerAllBinding ?? .centerAll
        let recorder = KeyRecorderField(binding: allBinding)
        recorder.onBindingChanged = { [weak self] b in
            self?.activeKeyRecorder.conflictBinding = b
            self?.host?.rebindAllWindowsHotKey(to: b)
        }
        return recorder
    }

    private func makeTableView() -> NSTableView {
        let tv = NSTableView()
        tv.dataSource = self
        tv.delegate   = self
        tv.rowHeight  = 20
        tv.headerView = nil
        let col = NSTableColumn(identifier: .init("bundleID"))
        col.title = "Bundle ID"
        tv.addTableColumn(col)
        return tv
    }

    private func makeRemoveButton() -> NSButton {
        let button = makeButton(title: "Remove", action: #selector(removeExclusion))
        button.isEnabled = false
        return button
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    // MARK: - Constraints
    private func applyConstraints(
        in cv:             NSView,
        hotkeysHeader:     NSView,
        activeLabel:       NSView,
        allLabel:          NSView,
        hotkeysHint:       NSView,
        exclusionsHeader:  NSView,
        exclusionsHint:    NSView,
        scrollView:        NSView,
        addButton:         NSView,
        aboutLabel:        NSView
    ) {
        var constraints: [NSLayoutConstraint] = []
        constraints.append(contentsOf: hotkeysConstraints(
            cv: cv,
            header: hotkeysHeader,
            activeLabel: activeLabel,
            allLabel: allLabel,
            hint: hotkeysHint
        ))
        constraints.append(contentsOf: exclusionsConstraints(
            cv: cv,
            header: exclusionsHeader,
            hint: exclusionsHint,
            scrollView: scrollView,
            addButton: addButton,
            aboutLabel: aboutLabel
        ))
        NSLayoutConstraint.activate(constraints)
    }

    private func hotkeysConstraints(
        cv: NSView,
        header: NSView,
        activeLabel: NSView,
        allLabel: NSView,
        hint: NSView
    ) -> [NSLayoutConstraint] {
        [
            header.topAnchor.constraint(equalTo: cv.topAnchor, constant: PreferencesUIConstants.margins),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: PreferencesUIConstants.margins),

            activeLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: PreferencesUIConstants.spacing),
            activeLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: PreferencesUIConstants.margins),
            activeLabel.widthAnchor.constraint(equalToConstant: PreferencesUIConstants.labelWidth),

            activeKeyRecorder.centerYAnchor.constraint(equalTo: activeLabel.centerYAnchor),
            activeKeyRecorder.leadingAnchor.constraint(equalTo: activeLabel.trailingAnchor, constant: PreferencesUIConstants.tinySpacing * 2),
            activeKeyRecorder.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -PreferencesUIConstants.margins),
            activeKeyRecorder.heightAnchor.constraint(equalToConstant: PreferencesUIConstants.keyRecorderHeight),

            allLabel.topAnchor.constraint(equalTo: activeLabel.bottomAnchor, constant: PreferencesUIConstants.spacing),
            allLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: PreferencesUIConstants.margins),
            allLabel.widthAnchor.constraint(equalToConstant: PreferencesUIConstants.labelWidth),

            allKeyRecorder.centerYAnchor.constraint(equalTo: allLabel.centerYAnchor),
            allKeyRecorder.leadingAnchor.constraint(equalTo: allLabel.trailingAnchor, constant: PreferencesUIConstants.tinySpacing * 2),
            allKeyRecorder.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -PreferencesUIConstants.margins),
            allKeyRecorder.heightAnchor.constraint(equalToConstant: PreferencesUIConstants.keyRecorderHeight),

            hint.topAnchor.constraint(equalTo: allLabel.bottomAnchor, constant: PreferencesUIConstants.smallSpacing),
            hint.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: PreferencesUIConstants.margins),
            hint.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -PreferencesUIConstants.margins),
        ]
    }

    private func exclusionsConstraints(
        cv: NSView,
        header: NSView,
        hint: NSView,
        scrollView: NSView,
        addButton: NSView,
        aboutLabel: NSView
    ) -> [NSLayoutConstraint] {
        [
            header.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: PreferencesUIConstants.margins),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: PreferencesUIConstants.margins),

            hint.topAnchor.constraint(equalTo: header.bottomAnchor, constant: PreferencesUIConstants.tinySpacing),
            hint.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: PreferencesUIConstants.margins),
            hint.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -PreferencesUIConstants.margins),

            scrollView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: PreferencesUIConstants.tinySpacing * 2),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: PreferencesUIConstants.margins),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -PreferencesUIConstants.margins),
            scrollView.heightAnchor.constraint(equalToConstant: PreferencesUIConstants.tableViewHeight),

            addButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: PreferencesUIConstants.tinySpacing * 2),
            addButton.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: PreferencesUIConstants.margins),

            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: PreferencesUIConstants.tinySpacing * 2),

            aboutLabel.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -PreferencesUIConstants.bottomPadding),
            aboutLabel.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
        ]
    }

    // MARK: - Actions
    @objc private func addExclusion() {
        let panel = configureOpenPanel()
        openPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.openPanel = nil
            guard response == .OK,
                  let url = panel.url,
                  let bid = Bundle(url: url)?.bundleIdentifier
            else { return }
            self.insertExclusion(bid)
        }
    }

    private func configureOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title                   = "Choose an Application"
        panel.allowedContentTypes     = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL            = URL(fileURLWithPath: "/Applications")
        return panel
    }

    private func insertExclusion(_ id: String) {
        guard !excludedIDs.contains(id) else { return }
        excludedIDs.insert(id)
        updateTableView()
    }

    @objc private func removeExclusion() {
        let row = tableView.selectedRow
        guard row >= 0, row < excludedIDs.count else { return }
        let sortedIDs = excludedIDs.sorted()
        excludedIDs.remove(sortedIDs[row])
        updateTableView()
    }

    private func updateTableView() {
        tableView.reloadData()
        saveExclusions()
    }

    private func saveExclusions() {
        host?.setExcludedBundleIDs(excludedIDs)
    }

    // MARK: - Label Factories
    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .boldSystemFont(ofSize: PreferencesUIConstants.sectionFontSize)
        return l
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font      = .systemFont(ofSize: PreferencesUIConstants.hintFontSize)
        l.textColor = .secondaryLabelColor
        return l
    }
}

// MARK: - Table View Data Source & Delegate
extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        excludedIDs.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("BundleIDCell")
        let cell   = tableView.makeView(withIdentifier: cellID, owner: self)
                     as? NSTableCellView ?? makeCellView(id: cellID)
        let sortedIDs = excludedIDs.sorted()
        cell.textField?.stringValue = sortedIDs[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    private func makeCellView(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: PreferencesUIConstants.tinySpacing),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        ])
        return cell
    }
}

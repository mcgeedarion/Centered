import Cocoa
import Carbon.HIToolbox

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
        font            = .monospacedSystemFont(ofSize: 13, weight: .medium)
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
        let hasRequiredModifier = mods.contains(.command)
                               || mods.contains(.option)
                               || mods.contains(.control)
        guard hasRequiredModifier, event.keyCode != UInt16(kVK_Escape) else {
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

    private weak var host: PreferencesHost?
    private var activeKeyRecorder:  KeyRecorderField!
    private var allKeyRecorder:     KeyRecorderField!
    private var tableView:          NSTableView!
    private var removeButton:       NSButton!
    private var excludedIDs:        [String] = []
    private var openPanel:          NSOpenPanel?

    init(host: PreferencesHost) {
        self.host = host
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
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

    func windowDidBecomeKey(_ notification: Notification) {
        guard let settings = host?.settings else { return }
        let activeBinding = settings.centerActiveBinding
        let allBinding    = settings.centerAllBinding
        activeKeyRecorder.binding         = activeBinding
        allKeyRecorder.binding            = allBinding
        activeKeyRecorder.conflictBinding = allBinding
        allKeyRecorder.conflictBinding    = activeBinding
        excludedIDs = Array(settings.excludedBundleIDs).sorted()
        tableView.reloadData()
    }

    func windowWillClose(_ notification: Notification) {
        openPanel?.cancel(nil)
        openPanel = nil
        host?.preferencesWindowDidClose()
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let hotkeysHeader = sectionLabel("Hotkeys")
        let activeLabel   = fieldLabel("Center Active Window")
        let allLabel      = fieldLabel("Center All Windows")

        let activeBinding = host?.settings.centerActiveBinding ?? .centerActive
        let allBinding    = host?.settings.centerAllBinding ?? .centerAll

        activeKeyRecorder = KeyRecorderField(binding: activeBinding)
        activeKeyRecorder.conflictBinding = allBinding
        activeKeyRecorder.onBindingChanged = { [weak self] b in
            self?.allKeyRecorder.conflictBinding = b
            self?.host?.rebindHotKey(to: b)
        }

        allKeyRecorder = KeyRecorderField(binding: allBinding)
        allKeyRecorder.conflictBinding = activeBinding
        allKeyRecorder.onBindingChanged = { [weak self] b in
            self?.activeKeyRecorder.conflictBinding = b
            self?.host?.rebindAllWindowsHotKey(to: b)
        }

        let hotkeysHint = hintLabel("Click a field, then press your desired shortcut. Escape cancels.")

        let exclusionsHeader = sectionLabel("Auto-Center Exclusions")
        let exclusionsHint   = hintLabel("Apps listed here will never be auto-centered when focused.")
        excludedIDs          = Array(host?.settings.excludedBundleIDs ?? []).sorted()

        let scrollView = buildTableView()

        let addButton = NSButton(title: "Add App…", target: self, action: #selector(addExclusion))
        addButton.bezelStyle = .rounded

        removeButton = NSButton(title: "Remove", target: self, action: #selector(removeExclusion))
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled  = false

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

    private func buildTableView() -> NSScrollView {
        let tv = NSTableView()
        tv.dataSource = self
        tv.delegate   = self
        tv.rowHeight  = 20
        tv.headerView = nil
        let col = NSTableColumn(identifier: .init("bundleID"))
        col.title = "Bundle ID"
        tv.addTableColumn(col)
        tableView = tv

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType          = .bezelBorder
        sv.documentView        = tv
        return sv
    }

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
        let m:  CGFloat = 20
        let lw: CGFloat = 180

        NSLayoutConstraint.activate([
            hotkeysHeader.topAnchor.constraint(equalTo: cv.topAnchor, constant: m),
            hotkeysHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),

            activeLabel.topAnchor.constraint(equalTo: hotkeysHeader.bottomAnchor, constant: 10),
            activeLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            activeLabel.widthAnchor.constraint(equalToConstant: lw),

            activeKeyRecorder.centerYAnchor.constraint(equalTo: activeLabel.centerYAnchor),
            activeKeyRecorder.leadingAnchor.constraint(equalTo: activeLabel.trailingAnchor, constant: 8),
            activeKeyRecorder.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            activeKeyRecorder.heightAnchor.constraint(equalToConstant: 24),

            allLabel.topAnchor.constraint(equalTo: activeLabel.bottomAnchor, constant: 10),
            allLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            allLabel.widthAnchor.constraint(equalToConstant: lw),

            allKeyRecorder.centerYAnchor.constraint(equalTo: allLabel.centerYAnchor),
            allKeyRecorder.leadingAnchor.constraint(equalTo: allLabel.trailingAnchor, constant: 8),
            allKeyRecorder.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            allKeyRecorder.heightAnchor.constraint(equalToConstant: 24),

            hotkeysHint.topAnchor.constraint(equalTo: allLabel.bottomAnchor, constant: 6),
            hotkeysHint.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            hotkeysHint.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            exclusionsHeader.topAnchor.constraint(equalTo: hotkeysHint.bottomAnchor, constant: m),
            exclusionsHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),

            exclusionsHint.topAnchor.constraint(equalTo: exclusionsHeader.bottomAnchor, constant: 4),
            exclusionsHint.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            exclusionsHint.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            scrollView.topAnchor.constraint(equalTo: exclusionsHint.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
            scrollView.heightAnchor.constraint(equalToConstant: 110),

            addButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            addButton.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),

            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),

            aboutLabel.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
            aboutLabel.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
        ])
    }

    @objc private func addExclusion() {
        let panel = NSOpenPanel()
        panel.title                   = "Choose an Application"
        panel.allowedContentTypes     = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL            = URL(fileURLWithPath: "/Applications")
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

    private func insertExclusion(_ id: String) {
        guard !excludedIDs.contains(id) else { return }
        excludedIDs.append(id)
        excludedIDs.sort()
        tableView.reloadData()
        saveExclusions()
    }

    @objc private func removeExclusion() {
        let row = tableView.selectedRow
        guard row >= 0, row < excludedIDs.count else { return }
        excludedIDs.remove(at: row)
        tableView.reloadData()
        saveExclusions()
    }

    private func saveExclusions() {
        host?.setExcludedBundleIDs(Set(excludedIDs))
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .boldSystemFont(ofSize: 13)
        return l
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font      = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }
}

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { excludedIDs.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("BundleIDCell")
        let cell   = tableView.makeView(withIdentifier: cellID, owner: self)
                     as? NSTableCellView ?? makeCellView(id: cellID)
        cell.textField?.stringValue = excludedIDs[row]
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
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        ])
        return cell
    }
}

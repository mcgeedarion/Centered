//
// PreferencesWindowController.swift
// Centered
//
// Programmatic preferences window — no XIB or Storyboard required.
//
// Sections:
//   1. Hotkeys     — key recorder fields for both shortcuts
//   2. Exclusions  — add/remove apps from the auto-center exclusion list
//   3. About       — bundle version string
//

import Cocoa
import Carbon.HIToolbox

// MARK: - KeyRecorderField

/// An NSTextField subclass that records the next key+modifier combo pressed
/// while it has focus. Displays the binding as a symbol string (e.g. "⌘⌥C").
final class KeyRecorderField: NSTextField {

    var binding: HotKeyBinding { didSet { stringValue = binding.displayString } }
    var onBindingChanged: ((HotKeyBinding) -> Void)?
    private var isRecording = false

    init(binding: HotKeyBinding) {
        self.binding = binding
        super.init(frame: .zero)
        stringValue  = binding.displayString
        isEditable   = false
        isSelectable = false
        isBordered   = true
        backgroundColor = .controlBackgroundColor
        alignment    = .center
        font         = .monospacedSystemFont(ofSize: 13, weight: .medium)
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
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var preview = ""
        if mods.contains(.control) { preview += "⌃" }
        if mods.contains(.option)  { preview += "⌥" }
        if mods.contains(.shift)   { preview += "⇧" }
        if mods.contains(.command) { preview += "⌘" }
        stringValue = preview.isEmpty ? "Press shortcut…" : preview + "_"
    }

    private func cancelRecording() {
        isRecording = false
        stringValue = binding.displayString
    }

    private func commitRecording(_ newBinding: HotKeyBinding) {
        binding     = newBinding
        isRecording = false
        onBindingChanged?(newBinding)
    }
}

// MARK: - PreferencesWindowController

@MainActor
final class PreferencesWindowController: NSWindowController {

    private weak var appDelegate: AppDelegate?
    private var activeKeyRecorder: KeyRecorderField!
    private var allKeyRecorder:    KeyRecorderField!
    private var tableView:         NSTableView!
    private var excludedIDs:       [String] = []   // sorted, drives tableView

    // MARK: Init

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        win.title = "Centered Preferences"
        win.center()
        super.init(window: win)
        buildUI()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // Hotkeys
        let hotkeysHeader = sectionLabel("Hotkeys")
        let activeLabel   = fieldLabel("Center Active Window")
        activeKeyRecorder = KeyRecorderField(binding: UserDefaults.standard.centerActiveBinding)
        activeKeyRecorder.onBindingChanged = { [weak self] b in self?.appDelegate?.rebindHotKey(to: b) }

        let allLabel   = fieldLabel("Center All Windows")
        allKeyRecorder = KeyRecorderField(binding: UserDefaults.standard.centerAllBinding)
        allKeyRecorder.onBindingChanged = { [weak self] b in self?.appDelegate?.rebindAllWindowsHotKey(to: b) }

        let hotkeysHint = hintLabel("Click a field, then press your desired shortcut. Escape cancels.")

        // Exclusions
        let exclusionsHeader = sectionLabel("Auto-Center Exclusions")
        let exclusionsHint   = hintLabel("Apps listed here will never be auto-centered when focused.")
        excludedIDs          = UserDefaults.standard.excludedBundleIDs.sorted()

        let scrollView = makeScrollView()
        let addButton  = NSButton(title: "Add App…", target: self, action: #selector(addExclusion))
        let removeBtn  = NSButton(title: "Remove",   target: self, action: #selector(removeExclusion))
        for btn in [addButton, removeBtn] {
            btn.bezelStyle = .rounded
            btn.translatesAutoresizingMaskIntoConstraints = false
        }

        // About
        let version    = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let aboutLabel = hintLabel("Centered v\(version) — personal use build")

        // Add all subviews
        for v in [hotkeysHeader, activeLabel, activeKeyRecorder,
                  allLabel, allKeyRecorder, hotkeysHint,
                  exclusionsHeader, exclusionsHint, scrollView,
                  addButton, removeBtn, aboutLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(v)
        }

        let m: CGFloat = 20   // common margin
        let lw: CGFloat = 180 // label width

        NSLayoutConstraint.activate([
            // — Hotkeys ——————————————————————————————————————————————————————
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

            // — Exclusions ———————————————————————————————————————————————————
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

            removeBtn.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeBtn.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),

            // — About ————————————————————————————————————————————————————————
            aboutLabel.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
            aboutLabel.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
        ])
    }

    private func makeScrollView() -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType          = .bezelBorder

        tableView            = NSTableView()
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.rowHeight  = 20
        tableView.headerView = nil

        let col = NSTableColumn(identifier: .init("bundleID"))
        col.title = "Bundle ID"
        tableView.addTableColumn(col)
        sv.documentView = tableView
        return sv
    }

    // MARK: Exclusion actions

    @objc private func addExclusion() {
        let panel = NSOpenPanel()
        panel.title                  = "Choose an Application"
        panel.allowedContentTypes    = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL           = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] response in
            guard response == .OK,
                  let url = panel.url,
                  let bid = Bundle(url: url)?.bundleIdentifier
            else { return }
            self?.insertExclusion(bid)
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
        appDelegate?.setExcludedBundleIDs(Set(excludedIDs))
    }

    // MARK: Label factory helpers

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

// MARK: - NSTableViewDataSource / NSTableViewDelegate

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

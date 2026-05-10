//
// PreferencesWindowController.swift
// Centered
//
// A programmatic preferences window with three sections:
//   1. Hotkeys  — key recorder fields for both shortcuts
//   2. Exclusions — add/remove apps from the auto-center exclusion list
//   3. About   — version info
//
// Built entirely in code (no XIB/Storyboard) so it drops straight into the
// project without Interface Builder wiring.
//

import Cocoa
import Carbon.HIToolbox

// MARK: - Key Recorder Field

/// A borderless text field that records the next key+modifier combo typed into it.
/// Displays the current binding as a human-readable string (e.g. "⌘⌥C").
final class KeyRecorderField: NSTextField {

    var binding: HotKeyBinding {
        didSet { stringValue = binding.displayString }
    }
    var onBindingChanged: ((HotKeyBinding) -> Void)?

    private var isRecording = false

    init(binding: HotKeyBinding) {
        self.binding = binding
        super.init(frame: .zero)
        stringValue       = binding.displayString
        isEditable        = false
        isSelectable      = false
        isBordered        = true
        backgroundColor   = .controlBackgroundColor
        alignment         = .center
        font              = .monospacedSystemFont(ofSize: 13, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        startRecording()
    }

    private func startRecording() {
        isRecording = true
        stringValue = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require at least one of ⌘/⌥/⌃ to avoid capturing plain letter keys.
        let hasModifier = mods.contains(.command) || mods.contains(.option) || mods.contains(.control)
        guard hasModifier, event.keyCode != UInt16(kVK_Escape) else {
            // Escape or no modifier — cancel recording.
            isRecording = false
            stringValue = binding.displayString
            return
        }

        let newBinding = HotKeyBinding(keyCode: event.keyCode, modifiers: mods)
        binding        = newBinding
        isRecording    = false
        onBindingChanged?(newBinding)
    }

    override func flagsChanged(with event: NSEvent) {
        // Show live modifier preview while recording.
        if isRecording {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var preview = ""
            if mods.contains(.control) { preview += "⌃" }
            if mods.contains(.option)  { preview += "⌥" }
            if mods.contains(.shift)   { preview += "⇧" }
            if mods.contains(.command) { preview += "⌘" }
            stringValue = preview.isEmpty ? "Press shortcut…" : preview + "_"
        }
    }
}

// MARK: - PreferencesWindowController

@MainActor
final class PreferencesWindowController: NSWindowController {

    private weak var appDelegate: AppDelegate?

    // Hotkey recorders
    private var activeKeyRecorder: KeyRecorderField!
    private var allKeyRecorder:    KeyRecorderField!

    // Exclusion list
    private var excludedIDs: [String] = []   // sorted array for the table
    private var tableView: NSTableView!
    private var removeButton: NSButton!

    // MARK: - Init

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

    // MARK: - UI construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // ── Hotkeys section ────────────────────────────────────────────────
        let hotkeysLabel = sectionLabel("Hotkeys")

        let activeLabel  = fieldLabel("Center Active Window")
        activeKeyRecorder = KeyRecorderField(binding: UserDefaults.standard.centerActiveBinding)
        activeKeyRecorder.onBindingChanged = { [weak self] b in
            self?.appDelegate?.rebindHotKey(to: b)
        }

        let allLabel  = fieldLabel("Center All Windows")
        allKeyRecorder = KeyRecorderField(binding: UserDefaults.standard.centerAllBinding)
        allKeyRecorder.onBindingChanged = { [weak self] b in
            self?.appDelegate?.rebindAllWindowsHotKey(to: b)
        }

        let hotkeysHint = hintLabel("Click a field, then press your desired shortcut. Escape cancels.")

        // ── Exclusions section ─────────────────────────────────────────────
        let exclusionsLabel = sectionLabel("Auto-Center Exclusions")
        let exclusionsHint  = hintLabel("Apps listed here will never be auto-centered when focused.")

        excludedIDs = UserDefaults.standard.excludedBundleIDs.sorted()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.rowHeight  = 20
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleID"))
        col.title = "Bundle ID"
        tableView.addTableColumn(col)
        tableView.headerView = nil
        scrollView.documentView = tableView

        let addButton = NSButton(title: "Add App…", target: self, action: #selector(addExclusion))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false

        removeButton = NSButton(title: "Remove", target: self, action: #selector(removeExclusion))
        removeButton.bezelStyle = .rounded
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        // ── About section ──────────────────────────────────────────────────
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let aboutLabel = hintLabel("Centered v\(version) — personal use build")

        // ── Layout ─────────────────────────────────────────────────────────
        for v in [hotkeysLabel, activeLabel, activeKeyRecorder!, allLabel, allKeyRecorder!,
                  hotkeysHint, exclusionsLabel, exclusionsHint, scrollView,
                  addButton, removeButton, aboutLabel] as [NSView] {
            contentView.addSubview(v)
        }

        NSLayoutConstraint.activate([
            // Hotkeys
            hotkeysLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            hotkeysLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            activeLabel.topAnchor.constraint(equalTo: hotkeysLabel.bottomAnchor, constant: 10),
            activeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            activeLabel.widthAnchor.constraint(equalToConstant: 180),

            activeKeyRecorder.centerYAnchor.constraint(equalTo: activeLabel.centerYAnchor),
            activeKeyRecorder.leadingAnchor.constraint(equalTo: activeLabel.trailingAnchor, constant: 8),
            activeKeyRecorder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            activeKeyRecorder.heightAnchor.constraint(equalToConstant: 24),

            allLabel.topAnchor.constraint(equalTo: activeLabel.bottomAnchor, constant: 10),
            allLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            allLabel.widthAnchor.constraint(equalToConstant: 180),

            allKeyRecorder.centerYAnchor.constraint(equalTo: allLabel.centerYAnchor),
            allKeyRecorder.leadingAnchor.constraint(equalTo: allLabel.trailingAnchor, constant: 8),
            allKeyRecorder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            allKeyRecorder.heightAnchor.constraint(equalToConstant: 24),

            hotkeysHint.topAnchor.constraint(equalTo: allLabel.bottomAnchor, constant: 6),
            hotkeysHint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            hotkeysHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // Exclusions
            exclusionsLabel.topAnchor.constraint(equalTo: hotkeysHint.bottomAnchor, constant: 20),
            exclusionsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            exclusionsHint.topAnchor.constraint(equalTo: exclusionsLabel.bottomAnchor, constant: 4),
            exclusionsHint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            exclusionsHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: exclusionsHint.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(equalToConstant: 110),

            addButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            addButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),

            // About
            aboutLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            aboutLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        ])
    }

    // MARK: - Exclusion list actions

    @objc private func addExclusion() {
        let panel = NSOpenPanel()
        panel.title              = "Choose an Application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL       = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] response in
            guard response == .OK,
                  let url    = panel.url,
                  let bundle = Bundle(url: url),
                  let bid    = bundle.bundleIdentifier
            else { return }
            self?.insertExclusion(bid)
        }
    }

    private func insertExclusion(_ bundleID: String) {
        guard !excludedIDs.contains(bundleID) else { return }
        excludedIDs.append(bundleID)
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

    // MARK: - Label helpers

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .boldSystemFont(ofSize: 13)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font      = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { excludedIDs.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id  = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                   ?? NSTableCellView()
        cell.identifier = id
        if cell.textField == nil {
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            ])
        }
        cell.textField?.stringValue = excludedIDs[row]
        return cell
    }
}

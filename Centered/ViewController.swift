//
// ViewController.swift
// Centered
//
// Created by Darion McGee on 7/22/25.
//

import Cocoa

@MainActor
class ViewController: NSViewController {

    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    @IBOutlet weak var toggleSwitch: NSSwitch!
    @IBOutlet weak var statusIndicator: NSImageView!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(updateUI), name: .appStateChanged, object: nil)
        nc.addObserver(self, selector: #selector(updateUI), name: .hotkeyPressed,   object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Actions

    @IBAction func toggleSwitchChanged(_ sender: NSSwitch) {
        guard let appDelegate else { return }
        sender.state == .on ? appDelegate.enableApp() : appDelegate.disableApp()
        updateUI()
    }

    // MARK: - UI update

    // @MainActor guarantees this always runs on the main thread — the
    // Thread.isMainThread branch in the previous version was redundant.
    @objc private func updateUI() {
        guard let enabled = appDelegate?.isEnabled else {
            toggleSwitch.isEnabled = false
            setStatus(symbol: "circle.fill", description: "Unknown", color: .gray)
            return
        }
        toggleSwitch.isEnabled = true
        toggleSwitch.state     = enabled ? .on : .off
        setStatus(
            symbol:      "circle.fill",
            description: enabled ? "Enabled" : "Disabled",
            color:       enabled ? .systemGreen : .systemRed
        )
    }

    private func setStatus(symbol: String, description: String, color: NSColor) {
        statusIndicator.image = NSImage(systemSymbolName: symbol,
                                        accessibilityDescription: description)
        statusIndicator.contentTintColor = color
    }
}

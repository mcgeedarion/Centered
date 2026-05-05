//
// ViewController.swift
// Centered
//
// Created by Darion McGee on 7/22/25.
//

import Cocoa

class ViewController: NSViewController {

    var appDelegate: AppDelegate? {
        return NSApplication.shared.delegate as? AppDelegate
    }

    @IBOutlet weak var toggleSwitch: NSSwitch!
    @IBOutlet weak var statusIndicator: NSImageView!

    override func viewDidLoad() {
        super.viewDidLoad()

        updateUI()

        // REFACTOR #9: Removed dead print(appLanguageCode) – the property no
        // longer exists now that it is not wired to any real localization logic.

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateUI),
            name: .appStateChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateUI),
            name: .hotkeyPressed,
            object: nil
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .appStateChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .hotkeyPressed, object: nil)
    }

    @IBAction func toggleSwitchChanged(_ sender: NSSwitch) {
        guard let appDelegate = appDelegate else { return }

        if sender.state == .on {
            appDelegate.enableApp()
        } else {
            appDelegate.disableApp()
        }

        updateUI()
    }

    // NotificationCenter delivers synchronously on the posting thread.
    // Dispatching to main here guarantees AppKit controls are always
    // updated on the correct thread regardless of who posts the notification.
    @objc private func updateUI() {
        DispatchQueue.main.async { [weak self] in
            self?.applyUI()
        }
    }

    private func applyUI() {
        guard let enabled = appDelegate?.isEnabled else {
            toggleSwitch.isEnabled = false
            statusIndicator.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Unknown"
            )
            statusIndicator.contentTintColor = .gray
            return
        }

        toggleSwitch.isEnabled = true
        toggleSwitch.state = enabled ? .on : .off

        statusIndicator.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: enabled ? "Enabled" : "Disabled"
        )
        statusIndicator.contentTintColor = enabled ? .systemGreen : .systemRed
    }
}

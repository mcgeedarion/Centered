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

        if let langCode = appDelegate?.appLanguageCode {
            print("Current language code:", langCode)
        }

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

    @objc private func updateUI() {
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

        if enabled {
            statusIndicator.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Enabled"
            )
            statusIndicator.contentTintColor = .systemGreen
        } else {
            statusIndicator.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Disabled"
            )
            statusIndicator.contentTintColor = .systemRed
        }
    }
}

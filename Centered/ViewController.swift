//
//  ViewController.swift
//  Centered
//
//  Created by Darion McGee on 7/22/25.
//

import Cocoa

class ViewController: NSViewController {
    var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    @IBOutlet weak var toggleSwitch: NSSwitch!
    @IBOutlet weak var statusIndicator: NSImageView!

    override func viewDidLoad() {
        super.viewDidLoad()

        DispatchQueue.main.async {
            self.updateUI()

            if let langCode = self.appDelegate?.appLanguageCode {
                print("Current language code:", langCode)
            }
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateUI),
                                               name: .appStateChanged,
                                               object: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateUI),
                                               name: .hotkeyPressed,
                                               object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @IBAction func toggleSwitchChanged(_ sender: NSSwitch) {
        DispatchQueue.main.async {
            if sender.state == .on {
                self.appDelegate?.enableApp()
            } else {
                self.appDelegate?.disableApp()
            }
            self.updateUI()
        }
    }

    @objc private func updateUI() {
        DispatchQueue.main.async {
            guard let enabled = self.appDelegate?.isEnabled else {
                self.toggleSwitch.isEnabled = false
                self.statusIndicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unknown")
                self.statusIndicator.contentTintColor = .gray
                return
            }

            self.toggleSwitch.isEnabled = true
            self.toggleSwitch.state = enabled ? .on : .off

            if enabled {
                self.statusIndicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Enabled")
                self.statusIndicator.contentTintColor = .systemGreen
            } else {
                self.statusIndicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Disabled")
                self.statusIndicator.contentTintColor = .systemRed
            }
        }
    }
}

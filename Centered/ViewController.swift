//
//  ViewController.swift
//  Centered
//
//  Created by Darion McGee on 7/22/25.
//  Security fixes applied
//

import Cocoa

class ViewController: NSViewController {
var appDelegate: AppDelegate? {
NSApplication.shared.delegate as? AppDelegate
}

```
@IBOutlet weak var toggleSwitch: NSSwitch!
@IBOutlet weak var statusIndicator: NSImageView!

override func viewDidLoad() {
    super.viewDidLoad()

    // FIXED: Ensure UI updates happen on main thread
    DispatchQueue.main.async { [weak self] in
        self?.updateUI()

        if let langCode = self?.appDelegate?.appLanguageCode {
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
    // FIXED: Ensure cleanup happens properly
    NotificationCenter.default.removeObserver(self, name: .appStateChanged, object: nil)
    NotificationCenter.default.removeObserver(self, name: .hotkeyPressed, object: nil)
}

@IBAction func toggleSwitchChanged(_ sender: NSSwitch) {
    // FIXED: Better error handling and main thread guarantee
    guard let appDelegate = appDelegate else { return }
    
    DispatchQueue.main.async { [weak self] in
        if sender.state == .on {
            appDelegate.enableApp()
        } else {
            appDelegate.disableApp()
        }
        self?.updateUI()
    }
}

@objc private func updateUI() {
    // FIXED: Ensure all UI updates happen on main thread with weak self
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
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
```

}
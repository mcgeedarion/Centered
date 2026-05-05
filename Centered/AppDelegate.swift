//
// AppDelegate.swift
// Centered
//
// Coordinator only: owns the status-bar item, permission checks, and the
// enable/disable lifecycle.  All centering logic lives in WindowCenterer;
// all AX observation lives in WindowObserver.
//

import Cocoa
import ApplicationServices

// MARK: - Notifications

extension Notification.Name {
    static let appStateChanged = Notification.Name("appStateChanged")
    static let hotkeyPressed   = Notification.Name("hotkeyPressed")
}

// MARK: -

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Sub-systems

    private let centerer = WindowCenterer()
    private let observer = WindowObserver()
    private let hotKey   = HotKey(key: .c, modifiers: [.command, .option])

    // MARK: - Status item

    private var statusItem: NSStatusItem?

    // MARK: - App enabled state

    private let stateQueue = DispatchQueue(label: "com.example.Centered.state")
    private var _isEnabled = false
    var isEnabled: Bool {
        get { stateQueue.sync { _isEnabled } }
        set { stateQueue.sync { _isEnabled = newValue } }
    }

    // MARK: - Screen selection (forwarded to centerer)

    var selectedScreen: NSScreen? {
        get { centerer.selectedScreen }
        set { centerer.selectedScreen = newValue }
    }

    // MARK: - Permissions

    private var permissionTimer: Timer?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestPermissionsIfNeeded()
        enableApp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        disableApp()
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Permissions

    private func requestPermissionsIfNeeded() {
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            )
        }
        _ = NSAppleScript(source: "tell application \"System Events\" to get its name")
              ?.executeAndReturnError(nil)
    }

    // MARK: - Enable / Disable

    @objc func enableApp() {
        guard !isEnabled else { return }
        guard AXIsProcessTrusted() else { showPermissionAlert(); return }

        isEnabled = true

        observer.onWindowEvent = { [weak self] window in
            self?.centerer.center(window: window)
        }
        observer.start()

        hotKey.keyDownHandler = { [weak self] in
            self?.centerer.centerFrontmost()
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
        hotKey.activate()

        postStateChanged()
        startPermissionChecks()
    }

    @objc func disableApp() {
        guard isEnabled else { return }

        isEnabled = false
        observer.stop()
        hotKey.deactivate()
        postStateChanged()
    }

    // MARK: - Manual trigger (menu / hotkey)

    @objc func centerActiveWindowManually() {
        guard isEnabled else { return }
        centerer.centerFrontmost()
    }

    // MARK: - Status item / menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "inset.filled.center.rectangle",
            accessibilityDescription: "Centered"
        )
        statusItem?.button?.contentTintColor = NSColor.labelColor
        updateScreenMenu()
    }

    private func updateScreenMenu() {
        let menu = NSMenu()
        let screens = NSScreen.screens

        guard !screens.isEmpty else { statusItem?.menu = menu; return }

        for (index, screen) in screens.enumerated() {
            let title = "Screen \(index + 1) - \(Int(screen.frame.width))x\(Int(screen.frame.height))"
            let item = NSMenuItem(
                title: title,
                action: #selector(selectScreen(_:)),
                keyEquivalent: ""
            )
            item.tag   = index
            item.state = (selectedScreen == screen) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Center Active Window",
            action: #selector(centerActiveWindowManually),
            keyEquivalent: "c"
        ).target = self

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Centered",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem?.menu = menu
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        guard sender.tag >= 0, sender.tag < screens.count else { return }
        selectedScreen = screens[sender.tag]
        updateScreenMenu()
    }

    // MARK: - Permission checks

    private func startPermissionChecks() {
        permissionTimer?.invalidate()
        // Schedule on RunLoop.main explicitly so the timer fires even if this
        // method is called from a background thread.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !AXIsProcessTrusted(), self.isEnabled {
                self.disableApp()
                self.showPermissionAlert()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: - Helpers

    private func postStateChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appStateChanged, object: nil)
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText    = "Accessibility Permission Required"
        alert.informativeText = "Please enable Centered in System Settings > Privacy & Security > Accessibility."
        alert.alertStyle     = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

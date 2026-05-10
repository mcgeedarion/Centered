//
// AppDelegate.swift
// Centered
//
// Coordinator only: owns the status-bar item, permission checks, and the
// enable/disable lifecycle.  All centering logic lives in WindowCenterer;
// all AX observation lives in WindowObserver.
//
// @MainActor: NSApplicationDelegate callbacks, NSStatusItem, and Timer all
// run on the main thread.  Annotating the class lets the compiler verify this
// and removes the need for stateQueue / _isEnabled.
//

import Cocoa
import ApplicationServices
import ServiceManagement
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Centered",
                            category: "AppDelegate")

// MARK: - Notifications

extension Notification.Name {
    static let appStateChanged = Notification.Name("appStateChanged")
    static let hotkeyPressed   = Notification.Name("hotkeyPressed")
}

// MARK: -

@MainActor
@main
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Sub-systems

    private let centerer = WindowCenterer()
    private let observer = WindowObserver()

    private lazy var hotKey: HotKey = {
        HotKey(key: .c, modifiers: [.command, .option]) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.centerer.centerFrontmost()
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    }()

    /// ⌘⇧C — centers every non-minimized window of the frontmost app.
    private lazy var allWindowsHotKey: HotKey = {
        HotKey(key: .c, modifiers: [.command, .shift]) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.centerer.centerAllWindows()
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    }()

    // MARK: - Status item

    private var statusItem: NSStatusItem?

    // MARK: - App enabled state

    var isEnabled = false

    // MARK: - Screen selection (forwarded to centerer + persisted)

    var selectedScreen: NSScreen? {
        get { centerer.selectedScreen }
        set {
            centerer.selectedScreen = newValue
            // Persist by localizedName so it survives relaunches.
            UserDefaults.standard.selectedScreenName = newValue?.localizedName
        }
    }

    // MARK: - Launch at login

    /// Whether the app is registered as a login item via SMAppService.
    var launchAtLogin: Bool {
        get {
            if #available(macOS 13, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
        set {
            guard #available(macOS 13, *) else { return }
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.debug("SMAppService toggle failed: \(error.localizedDescription, privacy: .public)")
            }
            // Rebuild menu so the checkmark reflects the new state.
            updateScreenMenu()
        }
    }

    // MARK: - Permissions

    private var permissionTimer: Timer?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        restoreSelectedScreen()
        requestPermissionsIfNeeded()
        enableApp()

        // Rebuild menu and validate selected screen when display configuration changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        disableApp()
    }

    // MARK: - Screen persistence

    /// Restores the previously selected screen by matching `localizedName`.
    /// Falls back to `NSScreen.main` if the saved screen is no longer connected.
    private func restoreSelectedScreen() {
        guard let savedName = UserDefaults.standard.selectedScreenName else { return }
        centerer.selectedScreen = NSScreen.screens.first { $0.localizedName == savedName }
        // Don't persist here — avoid overwriting a valid name with nil if the
        // screen happens to be temporarily disconnected at launch.
    }

    /// Called when displays are connected, disconnected, or rearranged.
    @objc private func screensDidChange() {
        let screens = NSScreen.screens
        // If the selected screen is no longer in the list, reset to main.
        if let current = centerer.selectedScreen, !screens.contains(current) {
            logger.debug("Selected screen disconnected — resetting to main")
            // Update centerer directly (don't persist the fallback as the user's preference).
            centerer.selectedScreen = NSScreen.main
        }
        updateScreenMenu()
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
        hotKey.activate()
        allWindowsHotKey.activate()

        NotificationCenter.default.post(name: .appStateChanged, object: nil)
        startPermissionChecks()
    }

    @objc func disableApp() {
        guard isEnabled else { return }

        isEnabled = false
        observer.stop()
        hotKey.deactivate()
        allWindowsHotKey.deactivate()
        centerer.cancelAnimation()
        stopPermissionChecks()

        NotificationCenter.default.post(name: .appStateChanged, object: nil)
    }

    // MARK: - Manual triggers (menu / hotkey)

    @objc func centerActiveWindowManually() {
        guard isEnabled else { return }
        centerer.centerFrontmost()
    }

    @objc func centerAllWindowsManually() {
        guard isEnabled else { return }
        centerer.centerAllWindows()
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
        let menu  = NSMenu()
        let screens = NSScreen.screens

        guard !screens.isEmpty else { statusItem?.menu = menu; return }

        // --- Screen picker ---
        for (index, screen) in screens.enumerated() {
            let title = "Screen \(index + 1) - \(Int(screen.frame.width))x\(Int(screen.frame.height))"
            let item  = NSMenuItem(
                title: title,
                action: #selector(selectScreen(_:)),
                keyEquivalent: ""
            )
            item.tag    = index
            item.state  = (selectedScreen == screen) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // --- Window commands ---
        let centerOne = menu.addItem(
            withTitle: "Center Active Window",
            action: #selector(centerActiveWindowManually),
            keyEquivalent: "c"
        )
        centerOne.keyEquivalentModifierMask = [.option, .command]
        centerOne.target = self

        let centerAll = menu.addItem(
            withTitle: "Center All Windows",
            action: #selector(centerAllWindowsManually),
            keyEquivalent: "c"
        )
        centerAll.keyEquivalentModifierMask = [.shift, .command]
        centerAll.target = self

        menu.addItem(.separator())

        // --- Launch at Login toggle ---
        if #available(macOS 13, *) {
            let loginItem = NSMenuItem(
                title: "Launch at Login",
                action: #selector(toggleLaunchAtLogin),
                keyEquivalent: ""
            )
            loginItem.state  = launchAtLogin ? .on : .off
            loginItem.target = self
            menu.addItem(loginItem)
            menu.addItem(.separator())
        }

        // --- Quit ---
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
        selectedScreen = screens[sender.tag]   // persists via the setter
        updateScreenMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        // updateScreenMenu() is called inside the launchAtLogin setter.
    }

    // MARK: - Permission checks

    private func startPermissionChecks() {
        permissionTimer?.invalidate()
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

    private func stopPermissionChecks() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Helpers

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText     = "Accessibility Permission Required"
        alert.informativeText = "Please enable Centered in System Settings > Privacy & Security > Accessibility."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

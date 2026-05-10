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
        HotKey(binding: UserDefaults.standard.centerActiveBinding) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.centerer.centerFrontmost()
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    }()

    private lazy var allWindowsHotKey: HotKey = {
        HotKey(binding: UserDefaults.standard.centerAllBinding) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.centerer.centerAllWindows()
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    }()

    // MARK: - Preferences window

    private var preferencesWindowController: PreferencesWindowController?

    // MARK: - Status item

    private var statusItem: NSStatusItem?

    // MARK: - App state

    var isEnabled = false

    // MARK: - Screen selection

    var selectedScreen: NSScreen? {
        get { centerer.selectedScreen }
        set {
            centerer.selectedScreen = newValue
            UserDefaults.standard.selectedScreenName = newValue?.localizedName
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get {
            if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
            return false
        }
        set {
            guard #available(macOS 13, *) else { return }
            do {
                if newValue { try SMAppService.mainApp.register() }
                else        { try SMAppService.mainApp.unregister() }
            } catch {
                logger.debug("SMAppService toggle failed: \(error.localizedDescription, privacy: .public)")
            }
            updateScreenMenu()
        }
    }

    // MARK: - Permissions timer

    private var permissionTimer: Timer?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        restoreSelectedScreen()
        requestPermissionsIfNeeded()
        enableApp()

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

    // MARK: - Hotkey rebind (called by PreferencesWindowController)

    func rebindHotKey(to binding: HotKeyBinding) {
        UserDefaults.standard.centerActiveBinding = binding
        hotKey.rebind(to: binding)
        updateScreenMenu()
    }

    func rebindAllWindowsHotKey(to binding: HotKeyBinding) {
        UserDefaults.standard.centerAllBinding = binding
        allWindowsHotKey.rebind(to: binding)
        updateScreenMenu()
    }

    // MARK: - Exclusion list (called by PreferencesWindowController)

    func setExcludedBundleIDs(_ ids: Set<String>) {
        UserDefaults.standard.excludedBundleIDs = ids
        observer.excludedBundleIDs = ids
    }

    // MARK: - Screen persistence

    private func restoreSelectedScreen() {
        guard let savedName = UserDefaults.standard.selectedScreenName else { return }
        centerer.selectedScreen = NSScreen.screens.first { $0.localizedName == savedName }
    }

    @objc private func screensDidChange() {
        if let current = centerer.selectedScreen, !NSScreen.screens.contains(current) {
            logger.debug("Selected screen disconnected — resetting to main")
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
        observer.onWindowEvent = { [weak self] window in self?.centerer.center(window: window) }
        observer.excludedBundleIDs = UserDefaults.standard.excludedBundleIDs
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

    // MARK: - Manual triggers

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

    func updateScreenMenu() {
        let menu    = NSMenu()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { statusItem?.menu = menu; return }

        // Screen picker
        for (index, screen) in screens.enumerated() {
            let title = "Screen \(index + 1) — \(Int(screen.frame.width))×\(Int(screen.frame.height))"
            let item  = NSMenuItem(title: title, action: #selector(selectScreen(_:)), keyEquivalent: "")
            item.tag    = index
            item.state  = (selectedScreen == screen) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Window commands — show current hotkey in title
        let activeBinding = UserDefaults.standard.centerActiveBinding
        let allBinding    = UserDefaults.standard.centerAllBinding

        let centerOne        = NSMenuItem(title: "Center Active Window  \(activeBinding.displayString)",
                                          action: #selector(centerActiveWindowManually),
                                          keyEquivalent: "")
        centerOne.target     = self
        menu.addItem(centerOne)

        let centerAll        = NSMenuItem(title: "Center All Windows  \(allBinding.displayString)",
                                          action: #selector(centerAllWindowsManually),
                                          keyEquivalent: "")
        centerAll.target     = self
        menu.addItem(centerAll)

        menu.addItem(.separator())

        // Preferences
        let prefs        = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target     = self
        menu.addItem(prefs)

        // Launch at login
        if #available(macOS 13, *) {
            let loginItem        = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.state      = launchAtLogin ? .on : .off
            loginItem.target     = self
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Centered", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        guard sender.tag >= 0, sender.tag < screens.count else { return }
        selectedScreen = screens[sender.tag]
        updateScreenMenu()
    }

    @objc private func toggleLaunchAtLogin() { launchAtLogin.toggle() }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(appDelegate: self)
        }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Permission checks

    private func startPermissionChecks() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !AXIsProcessTrusted(), self.isEnabled { self.disableApp(); self.showPermissionAlert() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func stopPermissionChecks() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

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

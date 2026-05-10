//
// AppDelegate.swift
// Centered
//
// Coordinator: owns the status-bar item, permission checks, and the
// enable/disable lifecycle. Centering logic → WindowCenterer;
// AX observation → WindowObserver.
//

import Cocoa
import ApplicationServices
import ServiceManagement
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Centered",
                            category: "AppDelegate")

// MARK: - Notification names

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

    private lazy var hotKey: HotKey = HotKey(binding: UserDefaults.standard.centerActiveBinding) {
        [weak self] in
        guard let self, isEnabled else { return }
        centerer.centerFrontmost()
        NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
    }

    private lazy var allWindowsHotKey: HotKey = HotKey(binding: UserDefaults.standard.centerAllBinding) {
        [weak self] in
        guard let self, isEnabled else { return }
        centerer.centerAllWindows()
        NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
    }

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var preferencesWindowController: PreferencesWindowController?
    private var permissionTimer: Timer?
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
            guard #available(macOS 13, *) else { return false }
            return SMAppService.mainApp.status == .enabled
        }
        set {
            guard #available(macOS 13, *) else { return }
            do {
                try newValue ? SMAppService.mainApp.register()
                             : SMAppService.mainApp.unregister()
            } catch {
                logger.debug("SMAppService error: \(error.localizedDescription, privacy: .public)")
            }
            updateScreenMenu()
        }
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        restoreSelectedScreen()
        requestPermissionsIfNeeded()
        enableApp()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
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
        guard let name = UserDefaults.standard.selectedScreenName else { return }
        centerer.selectedScreen = NSScreen.screens.first { $0.localizedName == name }
    }

    @objc private func screensDidChange() {
        if let cur = centerer.selectedScreen, !NSScreen.screens.contains(cur) {
            logger.debug("Selected screen disconnected — resetting to main")
            centerer.selectedScreen = NSScreen.main
        }
        updateScreenMenu()
    }

    // MARK: - Permissions

    private func requestPermissionsIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        _ = NSAppleScript(source: "tell application \"System Events\" to get its name")
              ?.executeAndReturnError(nil)
    }

    // MARK: - Enable / Disable

    @objc func enableApp() {
        guard !isEnabled else { return }
        guard AXIsProcessTrusted() else { showPermissionAlert(); return }
        isEnabled = true
        observer.onWindowEvent     = { [weak self] win in self?.centerer.center(window: win) }
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

    // MARK: - Status bar menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "inset.filled.center.rectangle",
            accessibilityDescription: "Centered"
        )
        statusItem?.button?.contentTintColor = .labelColor
        updateScreenMenu()
    }

    func updateScreenMenu() {
        let menu    = NSMenu()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { statusItem?.menu = menu; return }

        // Screen picker
        for (i, screen) in screens.enumerated() {
            let item = NSMenuItem(
                title:          "Screen \(i + 1) — \(Int(screen.frame.width))×\(Int(screen.frame.height))",
                action:         #selector(selectScreen(_:)),
                keyEquivalent:  ""
            )
            item.tag    = i
            item.state  = (selectedScreen == screen) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Window commands — live hotkey display
        menu.addItem(makeItem(
            title:  "Center Active Window  " + UserDefaults.standard.centerActiveBinding.displayString,
            action: #selector(centerActiveWindowManually)
        ))
        menu.addItem(makeItem(
            title:  "Center All Windows  " + UserDefaults.standard.centerAllBinding.displayString,
            action: #selector(centerAllWindowsManually)
        ))

        menu.addItem(.separator())

        menu.addItem(makeItem(title: "Preferences…", action: #selector(openPreferences), key: ","))

        if #available(macOS 13, *) {
            let item   = makeItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin))
            item.state = launchAtLogin ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Centered",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        statusItem?.menu = menu
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        guard sender.tag < screens.count else { return }
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
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !AXIsProcessTrusted(), isEnabled else { return }
            disableApp()
            showPermissionAlert()
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    private func stopPermissionChecks() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText     = "Accessibility Permission Required"
        alert.informativeText = "Please enable Centered in System Settings › Privacy & Security › Accessibility."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private func makeItem(title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

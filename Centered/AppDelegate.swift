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
        guard let self, self.isEnabled else { return }
        self.centerer.centerFrontmost()
        NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
    }

    private lazy var allWindowsHotKey: HotKey = HotKey(binding: UserDefaults.standard.centerAllBinding) {
        [weak self] in
        guard let self, self.isEnabled else { return }
        self.centerer.centerAllWindows()
        NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
    }

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var preferencesWindowController: PreferencesWindowController?
    // Legacy polling timer retained only as a fallback if the distributed
    // notification is unavailable (e.g. running under a stripped sandbox).
    private var permissionTimer: Timer?
    private(set) var isEnabled = false

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
            rebuildActionsSection()
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

    // MARK: - Hotkey rebind

    func rebindHotKey(to binding: HotKeyBinding) {
        UserDefaults.standard.centerActiveBinding = binding
        hotKey.rebind(to: binding)
        rebuildActionsSection()
    }

    func rebindAllWindowsHotKey(to binding: HotKeyBinding) {
        UserDefaults.standard.centerAllBinding = binding
        allWindowsHotKey.rebind(to: binding)
        rebuildActionsSection()
    }

    // MARK: - Exclusion list

    func setExcludedBundleIDs(_ ids: Set<String>) {
        UserDefaults.standard.excludedBundleIDs = ids
        observer.excludedBundleIDs = ids
    }

    // MARK: - Preferences window

    func preferencesWindowDidClose() {
        preferencesWindowController = nil
    }

    // MARK: - Screen persistence

    private func restoreSelectedScreen() {
        guard let name = UserDefaults.standard.selectedScreenName,
              !name.isEmpty,
              name.count <= 256
        else { return }
        centerer.selectedScreen = NSScreen.screens.first { $0.localizedName == name }
    }

    @objc private func screensDidChange() {
        if let cur = centerer.selectedScreen, !NSScreen.screens.contains(cur) {
            logger.debug("Selected screen disconnected — resetting to main")
            centerer.selectedScreen = NSScreen.main ?? NSScreen.screens.first
        }
        rebuildScreenSection()
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

    func enableApp() {
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

    func disableApp() {
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

    private enum MenuSection: Int {
        case screens = 100, actions = 200, system = 300
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "inset.filled.center.rectangle",
            accessibilityDescription: "Centered"
        )
        statusItem?.button?.contentTintColor = .labelColor
        buildFullMenu()
    }

    private func buildFullMenu() {
        let menu = NSMenu()
        appendScreenItems(to: menu)
        menu.addItem(.separator())
        appendActionItems(to: menu)
        menu.addItem(.separator())
        appendSystemItems(to: menu)
        statusItem?.menu = menu
    }

    private func rebuildScreenSection() {
        guard let menu = statusItem?.menu else { buildFullMenu(); return }
        removeItems(taggedIn: MenuSection.screens.rawValue ..< MenuSection.actions.rawValue, from: menu)
        let sep = menu.items.first(where: { $0.isSeparatorItem })
        let insertIdx = sep.map { menu.index(of: $0) } ?? 0
        for (offset, item) in makeScreenItems().enumerated() {
            menu.insertItem(item, at: insertIdx + offset)
        }
    }

    private func rebuildActionsSection() {
        guard let menu = statusItem?.menu else { buildFullMenu(); return }
        removeItems(taggedIn: MenuSection.actions.rawValue ..< MenuSection.system.rawValue, from: menu)
        let seps = menu.items.filter { $0.isSeparatorItem }
        let insertIdx = seps.first.map { menu.index(of: $0) + 1 } ?? menu.numberOfItems
        for (offset, item) in makeActionItems().enumerated() {
            menu.insertItem(item, at: insertIdx + offset)
        }
    }

    private func makeScreenItems() -> [NSMenuItem] {
        NSScreen.screens.enumerated().map { i, screen in
            let item = NSMenuItem(
                title:         "Screen \(i + 1) — \(Int(screen.frame.width))×\(Int(screen.frame.height))",
                action:        #selector(selectScreen(_:)),
                keyEquivalent: ""
            )
            item.tag               = MenuSection.screens.rawValue + i
            item.state             = (selectedScreen == screen) ? .on : .off
            item.target            = self
            item.representedObject = screen.localizedName
            return item
        }
    }

    private func makeActionItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let centerActive = makeItem(
            title:  "Center Active Window  " + UserDefaults.standard.centerActiveBinding.displayString,
            action: #selector(centerActiveWindowManually)
        )
        centerActive.tag = MenuSection.actions.rawValue + 1
        items.append(centerActive)

        let centerAll = makeItem(
            title:  "Center All Windows  " + UserDefaults.standard.centerAllBinding.displayString,
            action: #selector(centerAllWindowsManually)
        )
        centerAll.tag = MenuSection.actions.rawValue + 2
        items.append(centerAll)

        items.append(.separator())

        let prefs = makeItem(title: "Preferences…", action: #selector(openPreferences), key: ",")
        prefs.tag = MenuSection.actions.rawValue + 3
        items.append(prefs)

        if #available(macOS 13, *) {
            let lal = makeItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin))
            lal.state = launchAtLogin ? .on : .off
            lal.tag   = MenuSection.actions.rawValue + 4
            items.append(lal)
        }

        return items
    }

    private func appendScreenItems(to menu: NSMenu)  { makeScreenItems().forEach  { menu.addItem($0) } }
    private func appendActionItems(to menu: NSMenu)  { makeActionItems().forEach  { menu.addItem($0) } }

    private func appendSystemItems(to menu: NSMenu) {
        let quit = NSMenuItem(
            title: "Quit Centered",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.tag = MenuSection.system.rawValue
        menu.addItem(quit)
    }

    private func removeItems(taggedIn range: Range<Int>, from menu: NSMenu) {
        menu.items
            .filter { range.contains($0.tag) }
            .forEach { menu.removeItem($0) }
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        selectedScreen = NSScreen.screens.first { $0.localizedName == name }
        rebuildScreenSection()
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

    // Primary: Darwin distributed notification on "com.apple.accessibility.api".
    // This fires within milliseconds of TCC trust being revoked — far better
    // than the previous 30-second polling timer.
    //
    // Fallback: a 60-second timer catches any edge cases where the notification
    // is not delivered (e.g. very early in boot, or unusual system states).
    // The interval is doubled from the original 30 s because the notification
    // already handles the common case promptly.

    private func startPermissionChecks() {
        stopPermissionChecks()  // clear any existing observers before re-adding

        // Primary: instant notification on TCC change.
        let name     = "com.apple.accessibility.api" as CFString
        let selfPtr  = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            selfPtr,
            accessibilityChangedCallback,
            name,
            nil,
            .deliverImmediately
        )

        // Fallback: 60-second timer.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !AXIsProcessTrusted() else { return }
            self.disableApp()
            self.showPermissionAlert()
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    private func stopPermissionChecks() {
        permissionTimer?.invalidate()
        permissionTimer = nil

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            selfPtr,
            "com.apple.accessibility.api" as CFString,
            nil
        )
    }

    // Called from the C notification callback on the main thread.
    func handleAccessibilityTrustChange() {
        guard !AXIsProcessTrusted() else { return }   // trust still valid
        disableApp()
        showPermissionAlert()
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

    private func makeItem(title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

// MARK: - CFNotification callback (C function)

/// Fires on the main thread when com.apple.accessibility.api changes.
/// Reaches AppDelegate through the unretained observer pointer registered
/// in startPermissionChecks. Safe because the observer is always removed
/// in stopPermissionChecks before AppDelegate can be deallocated.
private let accessibilityChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async { delegate.handleAccessibilityTrustChange() }
}

//
// AppDelegate.swift
// Centered
//
// Coordinator: owns the status-bar item, permission checks, and the
// enable/disable lifecycle. Centering logic → AppCenteringController;
// AX observation → WindowObserver.
//

import Cocoa
import ApplicationServices
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "AppDelegate"
)

// MARK: - Notification names

extension Notification.Name {
    static let appStateChanged = Notification.Name("appStateChanged")
    static let hotkeyPressed  = Notification.Name("hotkeyPressed")
}

// MARK: - AppCoordinator protocol

protocol AppCoordinating: AnyObject {
    var selectedScreen: NSScreen? { get set }
    var launchAtLogin: Bool { get set }
    var isEnabled: Bool { get }

    func applicationDidFinishLaunching()
    func applicationWillTerminate()

    func centerActiveWindowManually()
    func centerAllWindowsManually()

    func rebindHotKey(to binding: HotKeyBinding)
    func rebindAllWindowsHotKey(to binding: HotKeyBinding)
    func setExcludedBundleIDs(_ ids: Set<String>)
    func preferencesWindowDidClose()
}

// MARK: - AppDelegate

@MainActor
@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private let coordinator: AppCoordinating = AppCenteringController(
        settings: DefaultSettings(),
        windowCenterer: WindowCenterer(),
        windowObserver: WindowObserver()
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.applicationDidFinishLaunching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.applicationWillTerminate()
    }
}

// MARK: - AppCenteringController

@MainActor
final class AppCenteringController: NSObject, AppCoordinating {

    // MARK: - Sub-systems

    private let centerer: WindowCenterer
    private let observer: WindowObserver
    private var settings: Settings

    private lazy var hotKey: HotKey = HotKey(binding: settings.centerActiveBinding) {
        [weak self] in
        guard let self, self.isEnabled else { return }
        self.centerer.centerFrontmost()
        NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
    }

    private lazy var allWindowsHotKey: HotKey = HotKey(binding: settings.centerAllBinding) {
        [weak self] in
        guard let self, self.isEnabled else { return }
        self.centerer.centerAllWindows()
        NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
    }

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var preferencesWindowController: PreferencesWindowController?
    private var permissionTimer: Timer?
    private(set) var isEnabled = false

    // MARK: - Init

    init(settings: Settings, windowCenterer: WindowCenterer, windowObserver: WindowObserver) {
        self.settings = settings
        self.centerer = windowCenterer
        self.observer = windowObserver
        super.init()
    }

    // MARK: - Screen selection

    var selectedScreen: NSScreen? {
        get { centerer.selectedScreen }
        set {
            centerer.selectedScreen = newValue
            settings.selectedScreenName = newValue?.localizedName
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { LaunchAtLoginService.isEnabled }
        set {
            LaunchAtLoginService.setEnabled(newValue)
            rebuildActionsSection()
        }
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching() {
        setupStatusItem()
        restoreSelectedScreen()
        AccessibilityAuthorization.requestIfNeeded()
        enableApp()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func applicationWillTerminate() {
        disableApp()
    }

    // MARK: - Hotkey rebind

    func rebindHotKey(to binding: HotKeyBinding) {
        settings.centerActiveBinding = binding
        hotKey.rebind(to: binding)
        rebuildActionsSection()
    }

    func rebindAllWindowsHotKey(to binding: HotKeyBinding) {
        settings.centerAllBinding = binding
        allWindowsHotKey.rebind(to: binding)
        rebuildActionsSection()
    }

    // MARK: - Exclusion list

    func setExcludedBundleIDs(_ ids: Set<String>) {
        settings.excludedBundleIDs = ids
        observer.excludedBundleIDs = ids
    }

    // MARK: - Preferences window

    func preferencesWindowDidClose() {
        preferencesWindowController = nil
    }

    // MARK: - Screen persistence

    private func restoreSelectedScreen() {
        guard let name = settings.selectedScreenName else { return }
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

    private func showPermissionAlert() {
        AccessibilityAuthorization.showAlertIfNeeded()
    }

    // MARK: - Enable / Disable

    func enableApp() {
        guard !isEnabled else { return }
        guard AccessibilityAuthorization.isTrusted else { showPermissionAlert(); return }
        isEnabled = true
        observer.onWindowEvent     = { [weak self] win in self?.centerer.center(window: win) }
        observer.excludedBundleIDs = settings.excludedBundleIDs
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

    func centerActiveWindowManually() {
        guard isEnabled else { return }
        centerer.centerFrontmost()
    }

    func centerAllWindowsManually() {
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
        let separator = menu.items.first(where: { $0.isSeparatorItem })
        let insertIndex = separator.map { menu.index(of: $0) } ?? 0
        insert(makeScreenItems(), into: menu, at: insertIndex)
    }

    private func rebuildActionsSection() {
        guard let menu = statusItem?.menu else { buildFullMenu(); return }
        removeItems(taggedIn: MenuSection.actions.rawValue ..< MenuSection.system.rawValue, from: menu)
        let separator = menu.items.first(where: { $0.isSeparatorItem })
        let insertIndex = separator.map { menu.index(of: $0) + 1 } ?? menu.numberOfItems
        insert(makeActionItems(), into: menu, at: insertIndex)
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
            title:  "Center Active Window  " + settings.centerActiveBinding.displayString,
            action: #selector(centerActiveMenuItem)
        )
        centerActive.tag = MenuSection.actions.rawValue + 1
        items.append(centerActive)

        let centerAll = makeItem(
            title:  "Center All Windows  " + settings.centerAllBinding.displayString,
            action: #selector(centerAllMenuItem)
        )
        centerAll.tag = MenuSection.actions.rawValue + 2
        items.append(centerAll)

        items.append(.separator())

        let prefs = makeItem(title: "Preferences…", action: #selector(openPreferences), key: ",")
        prefs.tag = MenuSection.actions.rawValue + 3
        items.append(prefs)

        if LaunchAtLoginService.isAvailable {
            let lal = makeItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin))
            lal.state = launchAtLogin ? .on : .off
            lal.tag   = MenuSection.actions.rawValue + 4
            items.append(lal)
        }

        return items
    }

    private func appendScreenItems(to menu: NSMenu) {
        makeScreenItems().forEach { menu.addItem($0) }
    }

    private func appendActionItems(to menu: NSMenu) {
        makeActionItems().forEach { menu.addItem($0) }
    }

    private func insert(_ items: [NSMenuItem], into menu: NSMenu, at index: Int) {
        for (offset, item) in items.enumerated() {
            menu.insertItem(item, at: index + offset)
        }
    }

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

    @objc private func centerActiveMenuItem() { centerActiveWindowManually() }
    @objc private func centerAllMenuItem()    { centerAllWindowsManually() }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(host: self)
        }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Permission checks

    private func startPermissionChecks() {
        stopPermissionChecks()

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            selfPtr,
            accessibilityChangedCallback,
            "com.apple.accessibility.api" as CFString,
            nil,
            .deliverImmediately
        )

        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, !AccessibilityAuthorization.isTrusted else { return }
            self.disableApp()
            self.showPermissionAlert()
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    private func stopPermissionChecks() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            "com.apple.accessibility.api" as CFString,
            nil
        )
    }

    func handleAccessibilityTrustChange() {
        guard !AccessibilityAuthorization.isTrusted else { return }
        disableApp()
        showPermissionAlert()
    }

    private func makeItem(title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

// MARK: - LaunchAtLoginService

enum LaunchAtLoginService {
    static var isAvailable: Bool {
        if #available(macOS 13, *) { true } else { false }
    }

    static var isEnabled: Bool {
        guard #available(macOS 13, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.debug("SMAppService error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - AccessibilityAuthorization

enum AccessibilityAuthorization {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        _ = NSAppleScript(source: "tell application \"System Events\" to get its name")?.executeAndReturnError(nil)
    }

    static func showAlertIfNeeded() {
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
}

// MARK: - CFNotification callback

private let accessibilityChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let controller = Unmanaged<AppCenteringController>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async { controller.handleAccessibilityTrustChange() }
}

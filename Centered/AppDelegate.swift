import Cocoa
import ApplicationServices
import os.log
import ServiceManagement

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Centered", category: "AppDelegate")

enum Constants {
    static let permissionCheckInterval: TimeInterval = 60
    static let accessibilityNotification = "com.apple.accessibility.api"
    static let accessibilityPreferencesURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let inputMonitoringPreferencesURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    static let statusIconName = "inset.filled.center.rectangle"
    static let preferencesKeyEquivalent = ","
    static let quitKeyEquivalent = "q"
}

enum AppStatus {
    case running, paused, permissionNeeded, disabled, hotKeyIssue
    var menuTitle: String {
        switch self {
        case .running: return "Status: Running"
        case .paused: return "Status: Paused"
        case .permissionNeeded: return "Status: Permission Needed"
        case .disabled: return "Status: Disabled"
        case .hotKeyIssue: return "Status: Running, some shortcuts unavailable"
        }
    }
    var tintColor: NSColor {
        switch self {
        case .running: return .labelColor
        case .paused, .hotKeyIssue: return .systemOrange
        case .permissionNeeded: return .systemRed
        case .disabled: return .secondaryLabelColor
        }
    }
}

extension Notification.Name {
    static let appStateChanged = Notification.Name("appStateChanged")
    static let hotkeyPressed = Notification.Name("hotkeyPressed")
}

@MainActor
protocol AppCoordinating: AnyObject {
    var selectedScreen: NSScreen? { get set }
    var launchAtLogin: Bool { get set }
    var isEnabled: Bool { get }
    var appStatus: AppStatus { get }
    var isAutoCenteringPaused: Bool { get set }
    var centersOnWindowScreen: Bool { get set }
    var animationStyle: WindowAnimationStyle { get set }
    var centerActiveBinding: HotKeyBinding { get }
    var centerAllBinding: HotKeyBinding { get }
    func applicationDidFinishLaunching()
    func applicationWillTerminate()
    func enableApp()
    func disableApp()
    func centerActiveWindowManually()
    func centerAllWindowsManually()
    func moveWindowToScreen(index: Int)
    func openPreferencesWindow()
    func recheckPermissions()
    func copyDiagnostics()
    func rebindHotKey(to binding: HotKeyBinding)
    func rebindAllWindowsHotKey(to binding: HotKeyBinding)
    func setExcludedBundleIDs(_ ids: Set<String>)
    func preferencesWindowDidClose()
}

@MainActor
@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: AppCoordinating = AppCenteringController(
        settings: DefaultSettings(), windowCenterer: WindowCenterer(), windowObserver: WindowObserver()
    )
    var isEnabled: Bool { coordinator.isEnabled }
    func applicationDidFinishLaunching(_ notification: Notification) { coordinator.applicationDidFinishLaunching() }
    func applicationWillTerminate(_ notification: Notification) { coordinator.applicationWillTerminate() }
    func enableApp() { coordinator.enableApp() }
    func disableApp() { coordinator.disableApp() }
}

@MainActor
struct MenuState {
    static let screensEnd = NSUserInterfaceItemIdentifier("Centered.screensEnd")
    static let actionsEnd = NSUserInterfaceItemIdentifier("Centered.actionsEnd")
    let screens: [NSMenuItem]
    let actions: [NSMenuItem]
    let system: [NSMenuItem]

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        screens.forEach { menu.addItem($0) }
        let screensBoundary = NSMenuItem.separator()
        screensBoundary.identifier = Self.screensEnd
        menu.addItem(screensBoundary)
        actions.forEach { menu.addItem($0) }
        let actionsBoundary = NSMenuItem.separator()
        actionsBoundary.identifier = Self.actionsEnd
        menu.addItem(actionsBoundary)
        system.forEach { menu.addItem($0) }
        return menu
    }

    static func replaceScreens(in menu: NSMenu, with items: [NSMenuItem]) -> Bool {
        guard let end = menu.items.firstIndex(where: { $0.identifier == screensEnd }) else { return false }
        for _ in 0..<end { menu.removeItem(at: 0) }
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        return true
    }

    static func replaceActions(in menu: NSMenu, with items: [NSMenuItem]) -> Bool {
        guard let start = menu.items.firstIndex(where: { $0.identifier == screensEnd }),
              let end = menu.items.firstIndex(where: { $0.identifier == actionsEnd }), end > start
        else { return false }
        for _ in (start + 1)..<end { menu.removeItem(at: start + 1) }
        for (index, item) in items.enumerated() { menu.insertItem(item, at: start + 1 + index) }
        return true
    }
}

@MainActor
enum DisplaySelection {
    static func id(for screen: NSScreen) -> UInt32? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return UInt32(exactly: number.uint64Value)
    }
    static func id(from item: NSMenuItem) -> UInt32? {
        guard let number = item.representedObject as? NSNumber else { return nil }
        return UInt32(exactly: number.uint64Value)
    }
    static func index(for id: UInt32, among ids: [UInt32?]) -> Int? {
        ids.firstIndex { $0 == id }
    }
}

@MainActor
final class MenuController {
    weak var coordinator: AppCoordinating?
    private weak var statusItem: NSStatusItem?
    init(statusItem: NSStatusItem) { self.statusItem = statusItem }
    func buildFullMenu() { rebuildMenu() }
    func rebuildScreenSection() {
        guard let coordinator, let menu = statusItem?.menu else { return }
        if !MenuState.replaceScreens(in: menu, with: makeScreenItems(coordinator: coordinator)) { rebuildMenu() }
    }
    func rebuildActionsSection() {
        guard let coordinator, let menu = statusItem?.menu else { return }
        if !MenuState.replaceActions(in: menu, with: makeActionItems(coordinator: coordinator)) { rebuildMenu() }
    }
    func rebuildMenu() {
        guard let coordinator else { return }
        statusItem?.menu = MenuState(
            screens: makeScreenItems(coordinator: coordinator),
            actions: makeActionItems(coordinator: coordinator),
            system: makeSystemItems()
        ).buildMenu()
    }
    private func makeScreenItems(coordinator: AppCoordinating) -> [NSMenuItem] {
        NSScreen.screens.enumerated().map { index, screen in
            let item = makeItem(
                title: "Screen \(index + 1) — \(Int(screen.frame.width))×\(Int(screen.frame.height))",
                action: #selector(selectScreen(_:))
            )
            item.state = coordinator.selectedScreen == screen ? .on : .off
            item.representedObject = DisplaySelection.id(for: screen).map { NSNumber(value: $0) }
            return item
        }
    }
    private func makeActionItems(coordinator: AppCoordinating) -> [NSMenuItem] {
        var items = [NSMenuItem]()
        let status = NSMenuItem(title: coordinator.appStatus.menuTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        items.append(status)
        let pause = makeItem(title: "Pause Auto-Centering", action: #selector(togglePause))
        pause.state = coordinator.isAutoCenteringPaused ? .on : .off
        items.append(pause)
        let mode = makeItem(title: "Center on Window’s Display", action: #selector(toggleWindowDisplayMode))
        mode.state = coordinator.centersOnWindowScreen ? .on : .off
        items.append(mode)
        let animationMenu = NSMenu()
        for style in WindowAnimationStyle.allCases {
            let item = makeItem(title: style.displayName, action: #selector(selectAnimationStyle(_:)))
            item.representedObject = style.rawValue
            item.state = coordinator.animationStyle == style ? .on : .off
            animationMenu.addItem(item)
        }
        let animation = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        animation.submenu = animationMenu
        items.append(animation)
        items.append(.separator())
        items.append(makeItem(title: "Center Active Window  " + coordinator.centerActiveBinding.displayString,
                              action: #selector(centerActiveMenuItem)))
        items.append(makeItem(title: "Center All Windows  " + coordinator.centerAllBinding.displayString,
                              action: #selector(centerAllMenuItem)))
        items.append(.separator())
        items.append(makeItem(title: "Preferences…", action: #selector(openPreferences), key: Constants.preferencesKeyEquivalent))
        items.append(makeItem(title: "Recheck Permissions", action: #selector(recheckPermissions)))
        items.append(makeItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics)))
        if LaunchAtLoginService.isAvailable {
            let item = makeItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin))
            item.state = coordinator.launchAtLogin ? .on : .off
            items.append(item)
        }
        return items
    }
    private func makeSystemItems() -> [NSMenuItem] {
        let quit = NSMenuItem(title: "Quit Centered", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: Constants.quitKeyEquivalent)
        quit.target = NSApp
        return [quit]
    }
    private func makeItem(title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
    @objc private func selectScreen(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        guard let id = DisplaySelection.id(from: sender),
              let index = DisplaySelection.index(for: id, among: screens.map { DisplaySelection.id(for: $0) })
        else { return }
        coordinator?.selectedScreen = screens[index]
        rebuildMenu()
    }
    @objc private func toggleLaunchAtLogin() { coordinator?.launchAtLogin.toggle() }
    @objc private func togglePause() { coordinator?.isAutoCenteringPaused.toggle(); rebuildMenu() }
    @objc private func toggleWindowDisplayMode() { coordinator?.centersOnWindowScreen.toggle(); rebuildMenu() }
    @objc private func selectAnimationStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = WindowAnimationStyle(rawValue: raw) else { return }
        coordinator?.animationStyle = style
        rebuildMenu()
    }
    @objc private func centerActiveMenuItem() { coordinator?.centerActiveWindowManually() }
    @objc private func centerAllMenuItem() { coordinator?.centerAllWindowsManually() }
    @objc private func openPreferences() { coordinator?.openPreferencesWindow() }
    @objc private func recheckPermissions() { coordinator?.recheckPermissions() }
    @objc private func copyDiagnostics() { coordinator?.copyDiagnostics() }
}

@MainActor
protocol RecoverableHotKey: AnyObject {
    var isActive: Bool { get }
    func activate() throws
    func deactivate()
    func rebind(to binding: HotKeyBinding, activateIfNeeded: Bool) throws
}

extension HotKey: RecoverableHotKey {}

@MainActor
enum ShortcutRecovery {
    static func rebind(
        _ hotKey: any RecoverableHotKey, to binding: HotKeyBinding, enabled: Bool,
        persist: (HotKeyBinding) -> Void
    ) throws {
        try hotKey.rebind(to: binding, activateIfNeeded: enabled)
        persist(binding)
    }
    static func activateUnavailable(_ keys: [(String, any RecoverableHotKey)]) -> Set<String> {
        for (name, key) in keys where !key.isActive {
            do { try key.activate() }
            catch { logger.error("Hot key activation failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        return unavailable(keys)
    }
    static func unavailable(_ keys: [(String, any RecoverableHotKey)]) -> Set<String> {
        Set(keys.filter { !$0.1.isActive }.map { $0.0 })
    }
}

@MainActor
final class PermissionManager {
    private weak var controller: AppCenteringController?
    private var permissionTimer: Timer?
    init(controller: AppCenteringController) { self.controller = controller }
    func startPermissionChecks() {
        stopPermissionChecks()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
            permissionChangedCallback, Constants.accessibilityNotification as CFString, nil, .deliverImmediately
        )
        let timer = Timer(timeInterval: Constants.permissionCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizePermissionState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }
    func stopPermissionChecks() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(rawValue: Constants.accessibilityNotification as CFString), nil
        )
    }
    func handleAccessibilityTrustChange() { synchronizePermissionState() }
    private func synchronizePermissionState() {
        guard let controller else { return }
        if AccessibilityAuthorization.isTrusted { controller.enableApp() }
        else { controller.disableApp(); controller.showPermissionAlert() }
    }
}

private let permissionChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let manager = Unmanaged<PermissionManager>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async { manager.handleAccessibilityTrustChange() }
}

@MainActor
final class AppCenteringController: NSObject, AppCoordinating, PreferencesHost {
    private let centerer: WindowCenterer
    private let observer: WindowObserver
    var settings: Settings
    private var menuController: MenuController?
    private var statusItem: NSStatusItem?
    private var preferencesWindowController: PreferencesWindowController?
    private var permissionManager: PermissionManager?
    private(set) var isEnabled = false
    private var failedHotKeyNames = Set<String>()

    private lazy var hotKey = makeHotKey(binding: settings.centerActiveBinding) { [weak self] in
        self?.centerActiveWindowManually()
        NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
    }
    private lazy var allWindowsHotKey = makeHotKey(binding: settings.centerAllBinding) { [weak self] in
        self?.centerAllWindowsManually()
        NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
    }
    private lazy var moveToScreen1HotKey = makeMoveHotKey(binding: .moveToScreen1, index: 0)
    private lazy var moveToScreen2HotKey = makeMoveHotKey(binding: .moveToScreen2, index: 1)
    private lazy var moveToScreen3HotKey = makeMoveHotKey(binding: .moveToScreen3, index: 2)
    private lazy var moveToScreen4HotKey = makeMoveHotKey(binding: .moveToScreen4, index: 3)
    private var hotKeyRegistrations: [(String, any RecoverableHotKey)] {
        [("Center Active Window", hotKey), ("Center All Windows", allWindowsHotKey),
         ("Move to Display 1", moveToScreen1HotKey), ("Move to Display 2", moveToScreen2HotKey),
         ("Move to Display 3", moveToScreen3HotKey), ("Move to Display 4", moveToScreen4HotKey)]
    }

    init(settings: Settings, windowCenterer: WindowCenterer, windowObserver: WindowObserver) {
        self.settings = settings
        centerer = windowCenterer
        observer = windowObserver
        super.init()
        permissionManager = PermissionManager(controller: self)
    }
    var selectedScreen: NSScreen? {
        get { centerer.selectedScreen }
        set {
            centerer.selectedScreen = newValue
            settings.selectedScreenName = newValue?.localizedName
            settings.selectedScreenID = newValue.flatMap { DisplaySelection.id(for: $0) }
            menuController?.rebuildScreenSection()
        }
    }
    var launchAtLogin: Bool {
        get { LaunchAtLoginService.isEnabled }
        set { LaunchAtLoginService.setEnabled(newValue); menuController?.rebuildMenu() }
    }
    var appStatus: AppStatus {
        if !AccessibilityAuthorization.isTrusted { return .permissionNeeded }
        if isAutoCenteringPaused { return .paused }
        if !isEnabled { return .disabled }
        return failedHotKeyNames.isEmpty ? .running : .hotKeyIssue
    }
    var isAutoCenteringPaused: Bool {
        get { settings.isAutoCenteringPaused }
        set {
            settings.isAutoCenteringPaused = newValue
            centerer.isPaused = newValue
            if newValue { centerer.cancelAnimation() }
            refreshStatusMenu()
        }
    }
    var centersOnWindowScreen: Bool {
        get { settings.centersOnWindowScreen }
        set { settings.centersOnWindowScreen = newValue; centerer.centersOnWindowScreen = newValue; menuController?.rebuildActionsSection() }
    }
    var animationStyle: WindowAnimationStyle {
        get { settings.animationStyle }
        set { settings.animationStyle = newValue; centerer.animationStyle = newValue; menuController?.rebuildActionsSection() }
    }
    var centerActiveBinding: HotKeyBinding { settings.centerActiveBinding }
    var centerAllBinding: HotKeyBinding { settings.centerAllBinding }

    func applicationDidFinishLaunching() {
        setupStatusItem()
        restoreSelectedScreen()
        centerer.isPaused = settings.isAutoCenteringPaused
        centerer.centersOnWindowScreen = settings.centersOnWindowScreen
        centerer.animationStyle = settings.animationStyle
        AccessibilityAuthorization.requestIfNeeded()
        enableApp()
        NotificationCenter.default.addObserver(self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func applicationWillTerminate() {
        disableApp()
        permissionManager?.stopPermissionChecks()
        NotificationCenter.default.removeObserver(self)
    }
    func rebindHotKey(to binding: HotKeyBinding) {
        rebind(hotKey, to: binding) { settings.centerActiveBinding = $0 }
    }
    func rebindAllWindowsHotKey(to binding: HotKeyBinding) {
        rebind(allWindowsHotKey, to: binding) { settings.centerAllBinding = $0 }
    }
    func setExcludedBundleIDs(_ ids: Set<String>) {
        settings.excludedBundleIDs = ids
        observer.excludedBundleIDs = ids
    }
    func preferencesWindowDidClose() { preferencesWindowController = nil }
    func openPreferencesWindow() { openPreferences() }
    func recheckPermissions() {
        if AccessibilityAuthorization.isTrusted { enableApp(); refreshStatusMenu() }
        else {
            AccessibilityAuthorization.requestIfNeeded()
            AccessibilityAuthorization.showAlertIfNeeded(force: true)
        }
    }
    func copyDiagnostics() {
        let diagnostics = DiagnosticsSnapshot(
            status: appStatus, selectedScreen: selectedScreen?.localizedName ?? "Main display",
            screenCount: NSScreen.screens.count, excludedBundleIDCount: settings.excludedBundleIDs.count,
            centerActiveBinding: settings.centerActiveBinding.displayString,
            centerAllBinding: settings.centerAllBinding.displayString,
            centersOnWindowScreen: centersOnWindowScreen, animationStyle: animationStyle, launchAtLogin: launchAtLogin
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.text, forType: .string)
    }
    func centerActiveWindowManually() {
        guard isEnabled else { return }
        runIgnoringPause { centerer.centerFrontmost() }
    }
    func centerAllWindowsManually() {
        guard isEnabled else { return }
        runIgnoringPause { centerer.centerAllWindows() }
    }
    func moveWindowToScreen(index: Int) {
        guard isEnabled else { return }
        runIgnoringPause { centerer.moveFrontmostWindow(toScreenIndex: index) }
    }
    private func rebind(_ hotKey: HotKey, to binding: HotKeyBinding, persist: (HotKeyBinding) -> Void) {
        do {
            try ShortcutRecovery.rebind(hotKey, to: binding, enabled: isEnabled, persist: persist)
            failedHotKeyNames = ShortcutRecovery.unavailable(hotKeyRegistrations)
            refreshStatusMenu()
            NotificationCenter.default.post(name: .appStateChanged, object: nil)
        } catch {
            failedHotKeyNames = ShortcutRecovery.unavailable(hotKeyRegistrations)
            refreshStatusMenu()
            showHotKeyError(error, binding: binding)
        }
    }
    private func runIgnoringPause(_ action: () -> Void) {
        let wasPaused = centerer.isPaused
        centerer.isPaused = false
        defer { centerer.isPaused = wasPaused }
        action()
    }
    private func refreshStatusMenu() {
        statusItem?.button?.contentTintColor = appStatus.tintColor
        menuController?.rebuildActionsSection()
    }
    private func showHotKeyError(_ error: Error, binding: HotKeyBinding) {
        logger.error("Hot key registration failed for \(binding.displayString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Shortcut Unavailable"
        alert.informativeText = "Centered could not register \(binding.displayString). It may already be used by macOS or another app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: Constants.statusIconName, accessibilityDescription: "Centered")
        statusItem?.button?.contentTintColor = appStatus.tintColor
        if let item = statusItem {
            menuController = MenuController(statusItem: item)
            menuController?.coordinator = self
            menuController?.rebuildMenu()
        }
    }
    private func restoreSelectedScreen() {
        let screens = NSScreen.screens
        if let id = settings.selectedScreenID {
            if let index = DisplaySelection.index(for: id, among: screens.map { DisplaySelection.id(for: $0) }) {
                centerer.selectedScreen = screens[index]
                return
            }
            // Keep the saved ID so reconnecting the display restores the user's choice.
            centerer.selectedScreen = NSScreen.main ?? screens.first
            return
        }
        if let name = settings.selectedScreenName {
            let matches = screens.filter { $0.localizedName == name }
            if matches.count == 1, let screen = matches.first {
                centerer.selectedScreen = screen
                settings.selectedScreenID = DisplaySelection.id(for: screen)
                return
            }
        }
        centerer.selectedScreen = NSScreen.main ?? screens.first
    }
    @objc private func screensDidChange() { restoreSelectedScreen(); menuController?.rebuildMenu() }
    func enableApp() {
        guard AccessibilityAuthorization.isTrusted else {
            if isEnabled { disableApp() }
            permissionManager?.startPermissionChecks()
            showPermissionAlert()
            refreshStatusMenu()
            return
        }
        if isEnabled {
            failedHotKeyNames = ShortcutRecovery.activateUnavailable(hotKeyRegistrations)
            refreshStatusMenu()
            return
        }
        observer.onWindowEvent = { [weak self] window in self?.centerer.center(window: window) }
        observer.excludedBundleIDs = settings.excludedBundleIDs
        observer.start()
        failedHotKeyNames = ShortcutRecovery.activateUnavailable(hotKeyRegistrations)
        isEnabled = true
        refreshStatusMenu()
        NotificationCenter.default.post(name: .appStateChanged, object: nil)
        permissionManager?.startPermissionChecks()
    }
    func disableApp() {
        guard isEnabled else { return }
        isEnabled = false
        failedHotKeyNames.removeAll()
        observer.stop()
        for (_, key) in hotKeyRegistrations { key.deactivate() }
        centerer.cancelAnimation()
        permissionManager?.stopPermissionChecks()
        refreshStatusMenu()
        NotificationCenter.default.post(name: .appStateChanged, object: nil)
    }
    func showPermissionAlert() { AccessibilityAuthorization.showAlertIfNeeded() }
    @objc private func openPreferences() {
        if preferencesWindowController == nil { preferencesWindowController = PreferencesWindowController(host: self) }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func makeHotKey(binding: HotKeyBinding, action: @escaping () -> Void) -> HotKey {
        HotKey(binding: binding, handler: action)
    }
    private func makeMoveHotKey(binding: HotKeyBinding, index: Int) -> HotKey {
        makeHotKey(binding: binding) { [weak self] in
            self?.moveWindowToScreen(index: index)
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    }
}

struct DiagnosticsSnapshot {
    let status: AppStatus
    let selectedScreen: String
    let screenCount: Int
    let excludedBundleIDCount: Int
    let centerActiveBinding: String
    let centerAllBinding: String
    let centersOnWindowScreen: Bool
    let animationStyle: WindowAnimationStyle
    let launchAtLogin: Bool
    var text: String {
        [
            "Centered Diagnostics",
            "Status: \(status.menuTitle.replacingOccurrences(of: "Status: ", with: ""))",
            "Accessibility Trusted: \(AccessibilityAuthorization.isTrusted)",
            "Selected Screen: \(selectedScreen)",
            "Screen Count: \(screenCount)",
            "Excluded Apps: \(excludedBundleIDCount)",
            "Center Active Hotkey: \(centerActiveBinding)",
            "Center All Hotkey: \(centerAllBinding)",
            "Center on Window Display: \(centersOnWindowScreen)",
            "Animation: \(animationStyle.displayName)",
            "Launch at Login: \(launchAtLogin)",
            "Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")",
            "Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")"
        ].joined(separator: "\n")
    }
}

enum LaunchAtLoginService {
    static var isAvailable: Bool {
        if #available(macOS 13, *) { return true }
        return false
    }
    static var isEnabled: Bool {
        guard #available(macOS 13, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }
    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { logger.debug("SMAppService error: \(error.localizedDescription, privacy: .public)") }
    }
}

enum AccessibilityAuthorization {
    private static var lastAlertDate: Date?
    private static let alertCooldown: TimeInterval = 120
    static var isTrusted: Bool { AXIsProcessTrusted() }
    static func requestIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        _ = NSAppleScript(source: "tell application \"System Events\" to get its name")?.executeAndReturnError(nil)
    }
    static func showAlertIfNeeded(force: Bool = false) {
        if !force, let lastAlertDate, Date().timeIntervalSince(lastAlertDate) < alertCooldown { return }
        lastAlertDate = Date()
        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = "Please enable Centered in System Settings › Privacy & Security › Accessibility. If global shortcuts do not fire, also enable Input Monitoring."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Open Input Monitoring")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        let urlString: String?
        switch response {
        case .alertFirstButtonReturn: urlString = Constants.accessibilityPreferencesURL
        case .alertSecondButtonReturn: urlString = Constants.inputMonitoringPreferencesURL
        default: urlString = nil
        }
        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

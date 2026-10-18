import Cocoa
import ApplicationServices
import os.log
import ServiceManagement

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "AppDelegate"
)

// MARK: - Constants

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
    case running
    case paused
    case permissionNeeded
    case disabled
    case hotKeyIssue

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
        case .paused: return .systemOrange
        case .permissionNeeded: return .systemRed
        case .disabled: return .secondaryLabelColor
        case .hotKeyIssue: return .systemOrange
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let appStateChanged = Notification.Name("appStateChanged")
    static let hotkeyPressed = Notification.Name("hotkeyPressed")
}

// MARK: - Protocols

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

// MARK: - App Delegate

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

    var isEnabled: Bool { coordinator.isEnabled }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.applicationWillTerminate()
    }

    func enableApp() {
        coordinator.enableApp()
    }

    func disableApp() {
        coordinator.disableApp()
    }
}

// MARK: - Menu State Model

struct MenuState {
    let screens: [NSMenuItem]
    let actions: [NSMenuItem]
    let system: [NSMenuItem]

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        screens.forEach { menu.addItem($0) }
        menu.addItem(.separator())
        actions.forEach { menu.addItem($0) }
        menu.addItem(.separator())
        system.forEach { menu.addItem($0) }
        return menu
    }
}

// MARK: - Menu Controller

@MainActor
final class MenuController {
    weak var coordinator: AppCoordinating?
    private weak var statusItem: NSStatusItem?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func buildFullMenu() {
        rebuildMenu()
    }

    func rebuildScreenSection() {
        guard let coordinator, let menu = statusItem?.menu else { return }
        let separators = menu.items.enumerated().filter { $0.element.isSeparatorItem }.map(\.offset)
        guard let firstSeparator = separators.first else { rebuildMenu(); return }
        for _ in 0..<firstSeparator { menu.removeItem(at: 0) }
        let items = makeScreenItems(coordinator: coordinator)
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
    }

    func rebuildActionsSection() {
        guard let coordinator, let menu = statusItem?.menu else { return }
        let separators = menu.items.enumerated().filter { $0.element.isSeparatorItem }.map(\.offset)
        guard separators.count >= 2 else { rebuildMenu(); return }
        let start = separators[0] + 1
        let end = separators[1]
        if end > start {
            for _ in start..<end { menu.removeItem(at: start) }
        }
        let items = makeActionItems(coordinator: coordinator)
        for (index, item) in items.enumerated() { menu.insertItem(item, at: start + index) }
    }

    func rebuildMenu() {
        guard let coordinator else { return }
        statusItem?.menu = createMenuState(coordinator: coordinator).buildMenu()
    }

    private func createMenuState(coordinator: AppCoordinating) -> MenuState {
        MenuState(
            screens: makeScreenItems(coordinator: coordinator),
            actions: makeActionItems(coordinator: coordinator),
            system: makeSystemItems(coordinator: coordinator)
        )
    }

    private func makeScreenItems(coordinator: AppCoordinating) -> [NSMenuItem] {
        NSScreen.screens.enumerated().map { i, screen in
            let item = NSMenuItem(
                title: "Screen \(i + 1) — \(Int(screen.frame.width))×\(Int(screen.frame.height))",
                action: #selector(selectScreen(_:)),
                keyEquivalent: ""
            )
            item.state = (coordinator.selectedScreen == screen) ? .on : .off
            item.target = self
            item.representedObject = screen.localizedName
            return item
        }
    }

    private func makeActionItems(coordinator: AppCoordinating) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let status = NSMenuItem(title: coordinator.appStatus.menuTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        items.append(status)

        let pause = makeItem(
            title: "Pause Auto-Centering",
            action: #selector(togglePause)
        )
        pause.state = coordinator.isAutoCenteringPaused ? .on : .off
        items.append(pause)

        let screenMode = makeItem(
            title: "Center on Window’s Display",
            action: #selector(toggleWindowDisplayMode)
        )
        screenMode.state = coordinator.centersOnWindowScreen ? .on : .off
        items.append(screenMode)

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

        let centerActive = makeItem(
            title: "Center Active Window  " + coordinator.centerActiveBinding.displayString,
            action: #selector(centerActiveMenuItem)
        )
        items.append(centerActive)

        let centerAll = makeItem(
            title: "Center All Windows  " + coordinator.centerAllBinding.displayString,
            action: #selector(centerAllMenuItem)
        )
        items.append(centerAll)

        items.append(.separator())

        let prefs = makeItem(
            title: "Preferences…",
            action: #selector(openPreferences),
            key: Constants.preferencesKeyEquivalent
        )
        items.append(prefs)

        let recheck = makeItem(
            title: "Recheck Permissions",
            action: #selector(recheckPermissions)
        )
        items.append(recheck)

        let diagnostics = makeItem(
            title: "Copy Diagnostics",
            action: #selector(copyDiagnostics)
        )
        items.append(diagnostics)

        if LaunchAtLoginService.isAvailable {
            let lal = makeItem(
                title: "Launch at Login",
                action: #selector(toggleLaunchAtLogin)
            )
            lal.state = coordinator.launchAtLogin ? .on : .off
            items.append(lal)
        }

        return items
    }

    private func makeSystemItems(coordinator: AppCoordinating) -> [NSMenuItem] {
        let quit = NSMenuItem(
            title: "Quit Centered",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: Constants.quitKeyEquivalent
        )
        quit.target = self
        return [quit]
    }

    private func makeItem(
        title: String,
        action: Selector,
        key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Menu Actions

    @objc private func selectScreen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        coordinator?.selectedScreen = NSScreen.screens.first { $0.localizedName == name }
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        coordinator?.launchAtLogin.toggle()
    }

    @objc private func togglePause() {
        coordinator?.isAutoCenteringPaused.toggle()
        rebuildMenu()
    }

    @objc private func toggleWindowDisplayMode() {
        coordinator?.centersOnWindowScreen.toggle()
        rebuildMenu()
    }

    @objc private func selectAnimationStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = WindowAnimationStyle(rawValue: raw)
        else { return }
        coordinator?.animationStyle = style
        rebuildMenu()
    }

    @objc private func centerActiveMenuItem() {
        coordinator?.centerActiveWindowManually()
    }

    @objc private func centerAllMenuItem() {
        coordinator?.centerAllWindowsManually()
    }

    @objc private func openPreferences() {
        coordinator?.openPreferencesWindow()
    }

    @objc private func recheckPermissions() {
        coordinator?.recheckPermissions()
    }

    @objc private func copyDiagnostics() {
        coordinator?.copyDiagnostics()
    }
}

// MARK: - Permission Manager

@MainActor
final class PermissionManager {
    private weak var controller: AppCenteringController?
    private var permissionTimer: Timer?
    private var notificationObserver: Any?

    init(controller: AppCenteringController) {
        self.controller = controller
    }

    func startPermissionChecks() {
        stopPermissionChecks()

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            selfPtr,
            permissionChangedCallback,
            CFNotificationName(rawValue: Constants.accessibilityNotification as CFString),
            nil,
            .deliverImmediately
        )

        let timer = Timer(
            timeInterval: Constants.permissionCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.performPermissionCheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    func stopPermissionChecks() {
        permissionTimer?.invalidate()
        permissionTimer = nil

        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(rawValue: Constants.accessibilityNotification as CFString),
            nil
        )
    }

    private func performPermissionCheck() {
        synchronizePermissionState(showAlertWhenMissing: true)
    }

    func handleAccessibilityTrustChange() {
        synchronizePermissionState(showAlertWhenMissing: true)
    }

    private func synchronizePermissionState(showAlertWhenMissing: Bool) {
        guard let controller else { return }

        if AccessibilityAuthorization.isTrusted {
            controller.enableApp()
            return
        }

        controller.disableApp()
        if showAlertWhenMissing {
            controller.showPermissionAlert()
        }
    }

}

private let permissionChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let manager = Unmanaged<PermissionManager>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async { manager.handleAccessibilityTrustChange() }
}

// MARK: - App Centering Controller

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

    private lazy var hotKey: HotKey = makeHotKey(
        binding: settings.centerActiveBinding,
        action: { [weak self] in
            self?.centerActiveWindowManually()
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    )

    private lazy var allWindowsHotKey: HotKey = makeHotKey(
        binding: settings.centerAllBinding,
        action: { [weak self] in
            self?.centerAllWindowsManually()
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    )

    private lazy var moveToScreen1HotKey: HotKey = makeHotKey(
        binding: .moveToScreen1,
        action: { [weak self] in
            self?.moveWindowToScreen(index: 0)
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    )

    private lazy var moveToScreen2HotKey: HotKey = makeHotKey(
        binding: .moveToScreen2,
        action: { [weak self] in
            self?.moveWindowToScreen(index: 1)
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    )

    private lazy var moveToScreen3HotKey: HotKey = makeHotKey(
        binding: .moveToScreen3,
        action: { [weak self] in
            self?.moveWindowToScreen(index: 2)
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    )

    private lazy var moveToScreen4HotKey: HotKey = makeHotKey(
        binding: .moveToScreen4,
        action: { [weak self] in
            self?.moveWindowToScreen(index: 3)
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    )

    init(
        settings: Settings,
        windowCenterer: WindowCenterer,
        windowObserver: WindowObserver
    ) {
        self.settings = settings
        self.centerer = windowCenterer
        self.observer = windowObserver
        super.init()
        self.permissionManager = PermissionManager(controller: self)
    }

    // MARK: - AppCoordinating Protocol

    var selectedScreen: NSScreen? {
        get { centerer.selectedScreen }
        set {
            centerer.selectedScreen = newValue
            settings.selectedScreenName = newValue?.localizedName
            settings.selectedScreenID = newValue.flatMap { Self.displayID(for: $0) }
            rebuildMenuSection(.screens)
        }
    }

    var launchAtLogin: Bool {
        get { LaunchAtLoginService.isEnabled }
        set {
            LaunchAtLoginService.setEnabled(newValue)
            menuController?.rebuildMenu()
        }
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
            updateStatusAppearance()
            menuController?.rebuildMenu()
        }
    }

    var centersOnWindowScreen: Bool {
        get { settings.centersOnWindowScreen }
        set {
            settings.centersOnWindowScreen = newValue
            centerer.centersOnWindowScreen = newValue
            menuController?.rebuildMenu()
        }
    }

    var animationStyle: WindowAnimationStyle {
        get { settings.animationStyle }
        set {
            settings.animationStyle = newValue
            centerer.animationStyle = newValue
            menuController?.rebuildMenu()
        }
    }

    var centerActiveBinding: HotKeyBinding { settings.centerActiveBinding }
    var centerAllBinding: HotKeyBinding { settings.centerAllBinding }

    func applicationDidFinishLaunching() {
        setupStatusItem()
        restoreSelectedScreen()
        applyBehaviorSettings()
        AccessibilityAuthorization.requestIfNeeded()
        enableApp()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate() {
        disableApp()
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

    func preferencesWindowDidClose() {
        preferencesWindowController = nil
    }

    func openPreferencesWindow() {
        openPreferences()
    }

    func recheckPermissions() {
        if AccessibilityAuthorization.isTrusted {
            enableApp()
            updateStatusAppearance()
            menuController?.rebuildMenu()
        } else {
            AccessibilityAuthorization.requestIfNeeded()
            AccessibilityAuthorization.showAlertIfNeeded(force: true)
        }
    }

    func copyDiagnostics() {
        let diagnostics = DiagnosticsSnapshot(
            status: appStatus,
            selectedScreen: selectedScreen?.localizedName ?? "Main display",
            screenCount: NSScreen.screens.count,
            excludedBundleIDCount: settings.excludedBundleIDs.count,
            centerActiveBinding: settings.centerActiveBinding.displayString,
            centerAllBinding: settings.centerAllBinding.displayString,
            centersOnWindowScreen: centersOnWindowScreen,
            animationStyle: animationStyle,
            launchAtLogin: launchAtLogin
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

    // MARK: - Private Methods

    private func rebind(
        _ hotKey: HotKey,
        to binding: HotKeyBinding,
        persist: (HotKeyBinding) -> Void
    ) {
        do {
            try hotKey.rebind(to: binding)
            persist(binding)
            menuController?.rebuildMenu()
        } catch {
            showHotKeyError(error, binding: binding)
        }
    }

    private func runIgnoringPause(_ action: () -> Void) {
        let wasPaused = centerer.isPaused
        centerer.isPaused = false
        action()
        centerer.isPaused = wasPaused
    }

    private func applyBehaviorSettings() {
        centerer.isPaused = settings.isAutoCenteringPaused
        centerer.centersOnWindowScreen = settings.centersOnWindowScreen
        centerer.animationStyle = settings.animationStyle
    }

    private enum MenuSection {
        case screens
        case actions
    }

    private func rebuildMenuSection(_ section: MenuSection) {
        switch section {
        case .screens:
            menuController?.rebuildScreenSection()
        case .actions:
            menuController?.rebuildActionsSection()
        }
    }

    private func refreshStatusMenu() {
        updateStatusAppearance()
        rebuildMenuSection(.actions)
    }

    private func updateStatusAppearance() {
        statusItem?.button?.contentTintColor = appStatus.tintColor
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
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusItem?.button?.image = NSImage(
            systemSymbolName: Constants.statusIconName,
            accessibilityDescription: "Centered"
        )
        updateStatusAppearance()

        if let item = statusItem {
            menuController = MenuController(statusItem: item)
            menuController?.coordinator = self
            menuController?.rebuildMenu()
        }
    }

    private static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .flatMap { UInt32(exactly: $0.uint32Value) }
    }

    private func restoreSelectedScreen() {
        if let savedID = settings.selectedScreenID,
           let screen = NSScreen.screens.first(where: { Self.displayID(for: $0) == savedID }) {
            centerer.selectedScreen = screen
            return
        }
        guard let name = settings.selectedScreenName else { return }
        let matches = NSScreen.screens.filter { $0.localizedName == name }
        if matches.count == 1, let screen = matches.first {
            centerer.selectedScreen = screen
            settings.selectedScreenID = Self.displayID(for: screen)
        } else {
            logger.warning("Saved display could not be uniquely identified; using main display")
            centerer.selectedScreen = NSScreen.main ?? NSScreen.screens.first
        }
    }

    @objc private func screensDidChange() {
        if let current = centerer.selectedScreen,
           !NSScreen.screens.contains(current) {
            logger.debug("Selected screen disconnected — resetting to main")
            centerer.selectedScreen = NSScreen.main ?? NSScreen.screens.first
        }
        menuController?.rebuildMenu()
    }

    func enableApp() {
        guard !isEnabled else { return }
        guard AccessibilityAuthorization.isTrusted else {
            permissionManager?.startPermissionChecks()
            showPermissionAlert()
            updateStatusAppearance()
            menuController?.rebuildMenu()
            return
        }

        failedHotKeyNames.removeAll()
        observer.onWindowEvent = { [weak self] win in
            self?.centerer.center(window: win)
        }
        observer.excludedBundleIDs = settings.excludedBundleIDs
        observer.start()
        let hotKeyActivations: [(String, () throws -> Void)] = [
            ("Center Active Window", { try self.hotKey.activate() }),
            ("Center All Windows", { try self.allWindowsHotKey.activate() }),
            ("Move to Display 1", { try self.moveToScreen1HotKey.activate() }),
            ("Move to Display 2", { try self.moveToScreen2HotKey.activate() }),
            ("Move to Display 3", { try self.moveToScreen3HotKey.activate() }),
            ("Move to Display 4", { try self.moveToScreen4HotKey.activate() })
        ]
        for (name, activate) in hotKeyActivations {
            do {
                try activate()
            } catch {
                failedHotKeyNames.insert(name)
                logger.error("Hot key activation failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        isEnabled = true
        updateStatusAppearance()
        menuController?.rebuildMenu()
        NotificationCenter.default.post(name: .appStateChanged, object: nil)
        permissionManager?.startPermissionChecks()
    }

    func disableApp() {
        guard isEnabled else { return }
        isEnabled = false
        failedHotKeyNames.removeAll()
        observer.stop()
        hotKey.deactivate()
        allWindowsHotKey.deactivate()
        moveToScreen1HotKey.deactivate()
        moveToScreen2HotKey.deactivate()
        moveToScreen3HotKey.deactivate()
        moveToScreen4HotKey.deactivate()
        centerer.cancelAnimation()
        permissionManager?.stopPermissionChecks()
        updateStatusAppearance()
        menuController?.rebuildMenu()
        NotificationCenter.default.post(name: .appStateChanged, object: nil)
    }

    func showPermissionAlert() {
        AccessibilityAuthorization.showAlertIfNeeded()
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(host: self)
        }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeHotKey(
        binding: HotKeyBinding,
        action: @escaping () -> Void
    ) -> HotKey {
        HotKey(binding: binding, handler: action)
    }
}

// MARK: - Diagnostics

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

// MARK: - Launch at Login Service

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
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.debug(
                "SMAppService error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

// MARK: - Accessibility Authorization

enum AccessibilityAuthorization {
    private static var lastAlertDate: Date?
    private static let alertCooldown: TimeInterval = 120

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        _ = NSAppleScript(
            source: "tell application \"System Events\" to get its name"
        )?.executeAndReturnError(nil)
    }

    static func showAlertIfNeeded(force: Bool = false) {
        if !force, let lastAlertDate, Date().timeIntervalSince(lastAlertDate) < alertCooldown {
            return
        }
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
        case .alertFirstButtonReturn:
            urlString = Constants.accessibilityPreferencesURL
        case .alertSecondButtonReturn:
            urlString = Constants.inputMonitoringPreferencesURL
        default:
            urlString = nil
        }

        guard let urlString, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

import Cocoa
import ApplicationServices
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "AppDelegate"
)

// MARK: - Constants

enum Constants {
    static let permissionCheckInterval: TimeInterval = 60
    static let accessibilityNotification = "com.apple.accessibility.api"
    static let systemPreferencesURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let statusIconName = "inset.filled.center.rectangle"
    static let preferencesKeyEquivalent = ","
    static let quitKeyEquivalent = "q"
}

// MARK: - Notifications

extension Notification.Name {
    static let appStateChanged = Notification.Name("appStateChanged")
    static let hotkeyPressed = Notification.Name("hotkeyPressed")
}

// MARK: - Protocols

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

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.applicationWillTerminate()
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
        guard let coordinator else { return }
        let menuState = createMenuState(coordinator: coordinator)
        statusItem?.menu = menuState.buildMenu()
    }

    func rebuildScreenSection() {
        guard let coordinator else { return }
        let menuState = createMenuState(coordinator: coordinator)
        statusItem?.menu = menuState.buildMenu()
    }

    func rebuildActionsSection() {
        guard let coordinator else { return }
        let menuState = createMenuState(coordinator: coordinator)
        statusItem?.menu = menuState.buildMenu()
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

        let centerActive = makeItem(
            title: "Center Active Window  " + (getBinding(.active)?.displayString ?? ""),
            action: #selector(centerActiveMenuItem)
        )
        items.append(centerActive)

        let centerAll = makeItem(
            title: "Center All Windows  " + (getBinding(.all)?.displayString ?? ""),
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
        rebuildScreenSection()
    }

    @objc private func toggleLaunchAtLogin() {
        coordinator?.launchAtLogin.toggle()
    }

    @objc private func centerActiveMenuItem() {
        coordinator?.centerActiveWindowManually()
    }

    @objc private func centerAllMenuItem() {
        coordinator?.centerAllWindowsManually()
    }

    @objc private func openPreferences() {
        // This will be handled by AppCenteringController
        // PostNotification or delegate pattern could be used here
    }

    private func getBinding(_ type: BindingType) -> HotKeyBinding? {
        // This is a placeholder - in real implementation, coordinator would provide this
        nil
    }

    enum BindingType {
        case active
        case all
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

        // Register for CFNotification
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            selfPtr,
            permissionChangedCallback,
            Constants.accessibilityNotification as CFString,
            nil,
            .deliverImmediately
        )

        // Start periodic timer
        let timer = Timer(
            timeInterval: Constants.permissionCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.performPermissionCheck()
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
            Constants.accessibilityNotification as CFString,
            nil
        )
    }

    private func performPermissionCheck() {
        guard !AccessibilityAuthorization.isTrusted else { return }
        controller?.disableApp()
        controller?.showPermissionAlert()
    }

    func handleAccessibilityTrustChange() {
        guard !AccessibilityAuthorization.isTrusted else { return }
        controller?.disableApp()
        controller?.showPermissionAlert()
    }

    deinit {
        stopPermissionChecks()
    }
}

private let permissionChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let manager = Unmanaged<PermissionManager>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async { manager.handleAccessibilityTrustChange() }
}

// MARK: - App Centering Controller

@MainActor
final class AppCenteringController: NSObject, AppCoordinating {

    private let centerer: WindowCenterer
    private let observer: WindowObserver
    private var settings: Settings

    private var menuController: MenuController?
    private var statusItem: NSStatusItem?
    private var preferencesWindowController: PreferencesWindowController?
    private var permissionManager: PermissionManager?

    private(set) var isEnabled = false

    private lazy var hotKey: HotKey = makeHotKey(
        binding: settings.centerActiveBinding,
        action: { [weak self] in
            self?.centerer.centerFrontmost()
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
    )

    private lazy var allWindowsHotKey: HotKey = makeHotKey(
        binding: settings.centerAllBinding,
        action: { [weak self] in
            self?.centerer.centerAllWindows()
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

    deinit {
        permissionManager?.stopPermissionChecks()
    }

    // MARK: - AppCoordinating Protocol

    var selectedScreen: NSScreen? {
        get { centerer.selectedScreen }
        set {
            centerer.selectedScreen = newValue
            settings.selectedScreenName = newValue?.localizedName
            menuController?.rebuildScreenSection()
        }
    }

    var launchAtLogin: Bool {
        get { LaunchAtLoginService.isEnabled }
        set {
            LaunchAtLoginService.setEnabled(newValue)
            menuController?.rebuildActionsSection()
        }
    }

    func applicationDidFinishLaunching() {
        setupStatusItem()
        restoreSelectedScreen()
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
        settings.centerActiveBinding = binding
        hotKey.rebind(to: binding)
        menuController?.rebuildActionsSection()
    }

    func rebindAllWindowsHotKey(to binding: HotKeyBinding) {
        settings.centerAllBinding = binding
        allWindowsHotKey.rebind(to: binding)
        menuController?.rebuildActionsSection()
    }

    func setExcludedBundleIDs(_ ids: Set<String>) {
        settings.excludedBundleIDs = ids
        observer.excludedBundleIDs = ids
    }

    func preferencesWindowDidClose() {
        preferencesWindowController = nil
    }

    func centerActiveWindowManually() {
        guard isEnabled else { return }
        centerer.centerFrontmost()
    }

    func centerAllWindowsManually() {
        guard isEnabled else { return }
        centerer.centerAllWindows()
    }

    // MARK: - Private Methods

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusItem?.button?.image = NSImage(
            systemSymbolName: Constants.statusIconName,
            accessibilityDescription: "Centered"
        )
        statusItem?.button?.contentTintColor = .labelColor

        if let item = statusItem {
            menuController = MenuController(statusItem: item)
            menuController?.coordinator = self
            menuController?.buildFullMenu()
        }
    }

    private func restoreSelectedScreen() {
        guard let name = settings.selectedScreenName else { return }
        if let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            centerer.selectedScreen = screen
        } else {
            logger.warning("Saved screen '\(name, privacy: .public)' not found; using main screen")
            centerer.selectedScreen = NSScreen.main ?? NSScreen.screens.first
        }
    }

    @objc private func screensDidChange() {
        if let current = centerer.selectedScreen,
           !NSScreen.screens.contains(current) {
            logger.debug("Selected screen disconnected — resetting to main")
            centerer.selectedScreen = NSScreen.main ?? NSScreen.screens.first
        }
        menuController?.rebuildScreenSection()
    }

    func enableApp() {
        guard !isEnabled else { return }
        guard AccessibilityAuthorization.isTrusted else {
            showPermissionAlert()
            return
        }

        isEnabled = true
        observer.onWindowEvent = { [weak self] win in
            self?.centerer.center(window: win)
        }
        observer.excludedBundleIDs = settings.excludedBundleIDs
        observer.start()
        hotKey.activate()
        allWindowsHotKey.activate()

        NotificationCenter.default.post(name: .appStateChanged, object: nil)
        permissionManager?.startPermissionChecks()
    }

    func disableApp() {
        guard isEnabled else { return }
        isEnabled = false
        observer.stop()
        hotKey.deactivate()
        allWindowsHotKey.deactivate()
        centerer.cancelAnimation()
        permissionManager?.stopPermissionChecks()
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
        HotKey(binding: binding, action: action)
    }
}

// MARK: - Launch at Login Service

enum LaunchAtLoginService {
    static var isAvailable: Bool {
        #available(macOS 13, *) ? true : false
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

    static func showAlertIfNeeded() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Please enable Centered in System Settings › Privacy & Security › Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: Constants.systemPreferencesURL)
        else { return }

        NSWorkspace.shared.open(url)
    }
}

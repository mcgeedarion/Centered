//
// AppDelegate.swift
// Centered
//
// Created by Darion McGee on 7/22/25.
//

import Cocoa
import ApplicationServices

// MARK: - Notifications

extension Notification.Name {
    static let appStateChanged = Notification.Name("appStateChanged")
    static let hotkeyPressed   = Notification.Name("hotkeyPressed")
}

// MARK: - AX Helpers

private func asAXUIElement(_ object: AnyObject) -> AXUIElement? {
    return CFGetTypeID(object) == AXUIElementGetTypeID() ? (object as? AXUIElement) : nil
}

// Observer callback used for all AXObservers
private let observerCallback: AXObserverCallback = { _, element, _, refcon in
    guard
        let refcon = refcon,
        CFGetTypeID(element) == AXUIElementGetTypeID()
    else { return }

    let appDelegate = Unmanaged<AppDelegate>
        .fromOpaque(refcon)
        .takeUnretainedValue()

    appDelegate.center(window: element as AXUIElement)
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - UI / Status

    var statusItem: NSStatusItem?

    // MARK: - AX Observers state

    private let observersQueue = DispatchQueue(
        label: "com.example.Centered.observers",
        attributes: .concurrent
    )
    private var _observers = [pid_t: AXObserver]()
    private var observers: [pid_t: AXObserver] {
        get { observersQueue.sync { _observers } }
        set { observersQueue.sync(flags: .barrier) { _observers = newValue } }
    }

    // MARK: - Hotkey

    let centerHotKey = HotKey(key: .c, modifiers: [.command, .option])

    // MARK: - App enabled state

    private let stateQueue = DispatchQueue(label: "com.example.Centered.state")
    private var _isEnabled = false
    var isEnabled: Bool {
        get { stateQueue.sync { _isEnabled } }
        set { stateQueue.sync { _isEnabled = newValue } }
    }

    // MARK: - Permissions & screen

    private var permissionTimer: Timer?
    var selectedScreen: NSScreen?

    var appLanguageCode: String {
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

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

        // Warm up AppleScript / System Events so first call is faster
        _ = NSAppleScript(source: "tell application \"System Events\" to get its name")?
            .executeAndReturnError(nil)
    }

    // MARK: - Enable / Disable

    @objc func enableApp() {
        guard !isEnabled else { return }
        guard AXIsProcessTrusted() else {
            showPermissionAlert()
            return
        }

        isEnabled = true

        startObservingWindows()

        centerHotKey.keyDownHandler = { [weak self] in
            self?.centerActiveWindowManually()
            NotificationCenter.default.post(name: .hotkeyPressed, object: nil)
        }
        centerHotKey.activate()

        NotificationCenter.default.post(name: .appStateChanged, object: nil)
        startPermissionChecks()
    }

    @objc func disableApp() {
        guard isEnabled else { return }

        isEnabled = false
        cleanupObservers()
        centerHotKey.deactivate()

        NotificationCenter.default.post(name: .appStateChanged, object: nil)
    }

    // MARK: - Status Item / Menu

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
        guard !screens.isEmpty else {
            statusItem?.menu = menu
            return
        }

        for (index, screen) in screens.enumerated() {
            let title =
                "Screen \(index + 1) - \(Int(screen.frame.width))x\(Int(screen.frame.height))"
            let item = NSMenuItem(
                title: title,
                action: #selector(selectScreen(_:)),
                keyEquivalent: ""
            )
            item.tag = index
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

    // MARK: - AX Observers

    private func cleanupObservers() {
        observersQueue.sync(flags: .barrier) {
            for observer in _observers.values {
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(observer),
                    .defaultMode
                )
            }
            _observers.removeAll()
        }
    }

    private func startPermissionChecks() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !AXIsProcessTrusted() && self.isEnabled {
                self.disableApp()
                self.showPermissionAlert()
            }
        }
    }

    private func startObservingWindows() {
        guard AXIsProcessTrusted() else { return }

        let workspace = NSWorkspace.shared

        workspace.runningApplications
            .filter { $0.activationPolicy == .regular }
            .forEach { observe(app: $0) }

        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(appTerminated),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func appLaunched(notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            observe(app: app)
        }
    }

    @objc private func appTerminated(notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            observersQueue.sync(flags: .barrier) {
                if let observer = _observers.removeValue(forKey: app.processIdentifier) {
                    CFRunLoopRemoveSource(
                        CFRunLoopGetMain(),
                        AXObserverGetRunLoopSource(observer),
                        .defaultMode
                    )
                }
            }
        }
    }

    private func observe(app: NSRunningApplication) {
        observersQueue.sync(flags: .barrier) {
            guard _observers[app.processIdentifier] == nil else { return }

            var observer: AXObserver?
            if AXObserverCreate(app.processIdentifier, observerCallback, &observer) == .success,
               let observer = observer {
                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                let appElement = AXUIElementCreateApplication(app.processIdentifier)

                AXObserverAddNotification(
                    observer,
                    appElement,
                    kAXWindowCreatedNotification as CFString,
                    selfPtr
                )
                AXObserverAddNotification(
                    observer,
                    appElement,
                    kAXWindowMiniaturizedNotification as CFString,
                    selfPtr
                )
                AXObserverAddNotification(
                    observer,
                    appElement,
                    kAXFocusedWindowChangedNotification as CFString,
                    selfPtr
                )

                CFRunLoopAddSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(observer),
                    .defaultMode
                )
                _observers[app.processIdentifier] = observer
            }
        }
    }

    // MARK: - Centering logic (AX)

    private func animateWindowPosition(_ window: AXUIElement, to point: CGPoint) {
        guard let currentPosValue = getWindowPosition(window) else { return }

        var currentPos = CGPoint()
        AXValueGetValue(currentPosValue, .cgPoint, &currentPos)

        let steps = 10
        let dx = (point.x - currentPos.x) / CGFloat(steps)
        let dy = (point.y - currentPos.y) / CGFloat(steps)

        func step(_ i: Int, _ current: CGPoint) {
            guard i <= steps else { return }

            let newX = current.x + dx
            let newY = current.y + dy
            var intermediate = CGPoint(x: newX, y: newY)

            if let posVal = AXValueCreate(.cgPoint, &intermediate) {
                AXUIElementSetAttributeValue(
                    window,
                    kAXPositionAttribute as CFString,
                    posVal
                )
            }

            if i < steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                    step(i + 1, intermediate)
                }
            }
        }

        step(1, currentPos)
    }

    private func getWindowPosition(_ window: AXUIElement) -> AXValue? {
        var posValue: AnyObject?
        if AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &posValue
        ) == .success,
           let value = posValue,
           CFGetTypeID(value) == AXValueGetTypeID() {
            return (value as! AXValue)
        }
        return nil
    }

    func center(window: AXUIElement) {
        var minimized: AnyObject?
        if AXUIElementCopyAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            &minimized
        ) == .success,
           let isMinimized = minimized as? Bool,
           isMinimized {
            return
        }

        var main: AnyObject?
        if AXUIElementCopyAttributeValue(
            window,
            kAXMainAttribute as CFString,
            &main
        ) == .success,
           let isMain = main as? Bool,
           !isMain {
            return
        }

        if !centerWindow(window),
           let app = NSWorkspace.shared.frontmostApplication {
            if let bundleId = app.bundleIdentifier {
                centerWithAppleScript(bundleIdentifier: bundleId)
            } else {
                let safeAppName = (app.localizedName ?? "Unknown App")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                centerWithAppleScript(appName: safeAppName)
            }
        }
    }

    private func centerWindow(_ window: AXUIElement) -> Bool {
        guard let screen = selectedScreen ?? NSScreen.main else { return false }

        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
           let size = sizeValue,
           CFGetTypeID(size) == AXValueGetTypeID() else {
            return false
        }

        var windowSize = CGSize()
        guard AXValueGetValue(size as! AXValue, .cgSize, &windowSize) else { return false }

        guard windowSize.width > 0, windowSize.height > 0 else {
            return false
        }

        let newOrigin = CGPoint(
            x: screen.frame.midX - windowSize.width / 2,
            y: screen.frame.midY - windowSize.height / 2
        )
        animateWindowPosition(window, to: newOrigin)
        return true
    }

    // MARK: - AppleScript fallback

    private func centerWithAppleScript(bundleIdentifier: String) {
        let script = """
        tell application id "\(bundleIdentifier)"
            activate
            try
                set win to front window
                set winBounds to bounds of win
                tell application "System Events" to tell first desktop
                    set screenBounds to bounds
                    set screenWidth to item 3 of screenBounds
                    set screenHeight to item 4 of screenBounds
                end tell
                set winWidth to item 3 of winBounds - item 1 of winBounds
                set winHeight to item 4 of winBounds - item 2 of winBounds
                set newX to (screenWidth - winWidth) / 2
                set newY to (screenHeight - winHeight) / 2
                try
                    set bounds of win to {newX, newY, newX + winWidth, newY + winHeight} with animation
                on error
                    set position of win to {newX, newY}
                    set size of win to {winWidth, winHeight}
                end try
            end try
        end tell
        """

        var error: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)

        if let error = error {
            NSLog("AppleScript error for bundle \(bundleIdentifier): \(error)")
        }
    }

    private func centerWithAppleScript(appName: String) {
        // Comprehensive sanitization to prevent injection
        let sanitized = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\0", with: "")

        let allowedCharacterSet = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ".-_"))

        guard sanitized.unicodeScalars.allSatisfy({ allowedCharacterSet.contains($0) }) else {
            NSLog("Rejected potentially malicious app name: \(appName)")
            return
        }

        let script = """
        tell application "\(sanitized)"
            activate
            try
                set win to front window
                set winBounds to bounds of win
                tell application "System Events" to tell first desktop
                    set screenBounds to bounds
                    set screenWidth to item 3 of screenBounds
                    set screenHeight to item 4 of screenBounds
                end tell
                set winWidth to item 3 of winBounds - item 1 of winBounds
                set winHeight to item 4 of winBounds - item 2 of winBounds
                set newX to (screenWidth - winWidth) / 2
                set newY to (screenHeight - winHeight) / 2
                try
                    set bounds of win to {newX, newY, newX + winWidth, newY + winHeight} with animation
                on error
                    set position of win to {newX, newY}
                    set size of win to {winWidth, winHeight}
                end try
            end try
        end tell
        """

        var error: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)

        if let error = error {
            NSLog("AppleScript error for app \(sanitized): \(error)")
        }
    }

    // MARK: - Manual centering trigger

    @objc func centerActiveWindowManually() {
        guard isEnabled,
              let app = NSWorkspace.shared.frontmostApplication
        else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?

        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success,
           let focused = focusedWindow,
           let window = asAXUIElement(focused) {
            center(window: window)
        } else if let window = getWindowsForApp(appElement)?.first {
            center(window: window)
        } else {
            if let bundleId = app.bundleIdentifier {
                centerWithAppleScript(bundleIdentifier: bundleId)
            } else {
                let safeAppName = (app.localizedName ?? "Unknown App")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                centerWithAppleScript(appName: safeAppName)
            }
        }
    }

    private func getWindowsForApp(_ appElement: AXUIElement) -> [AXUIElement]? {
        var windows: AnyObject?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windows
        ) == .success {
            return (windows as? [AnyObject])?.compactMap { asAXUIElement($0) }
        }
        return nil
    }

    // MARK: - Permission alert

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText =
        "Please enable Centered in System Settings > Privacy & Security > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - HotKey

class HotKey {

    let key: Key
    let modifiers: NSEvent.ModifierFlags
    var keyDownHandler: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(key: Key, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    func activate() {
        guard globalMonitor == nil && localMonitor == nil else { return }

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == self.modifiers,
               event.keyCode == self.key.rawValue {
                self.keyDownHandler?()
            }
        }

        // Triggers when app is in background
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)

        // Triggers when app is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    func deactivate() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMonitor = nil
        }

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMonitor = nil
        }
    }

    enum Key: UInt16 {
        case c = 8 // US QWERTY; consider kVK_ANSI_C if you want better layout independence
    }
}

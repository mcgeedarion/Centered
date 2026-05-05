//
// WindowCenterer.swift
// Centered
//
// Owns all window-centering logic: AX attribute reads, animation, and the
// AppleScript fallback path.  AppDelegate instantiates one and delegates to it.
//

import Cocoa
import ApplicationServices

// MARK: - AX casting helper (file-private, used by both WindowCenterer and WindowObserver)

extension AnyObject {
    /// Returns `self` as an `AXUIElement` iff the CF type IDs match.
    var asAXUIElement: AXUIElement? {
        CFGetTypeID(self) == AXUIElementGetTypeID() ? (self as? AXUIElement) : nil
    }
}

// MARK: -

final class WindowCenterer {

    // MARK: - Selected screen (queue-protected)

    private let screenQueue = DispatchQueue(label: "com.example.Centered.screen")
    private var _selectedScreen: NSScreen?

    var selectedScreen: NSScreen? {
        get { screenQueue.sync { _selectedScreen } }
        set { screenQueue.sync { _selectedScreen = newValue } }
    }

    // MARK: - Animation cancellation token

    private var animationWorkItem: DispatchWorkItem?

    // MARK: - Public entry points

    /// Centers `window` on the selected (or main) screen.
    /// Silently skips minimized or non-main windows.
    func center(window: AXUIElement) {
        var minimized: AnyObject?
        if AXUIElementCopyAttributeValue(
            window, kAXMinimizedAttribute as CFString, &minimized
        ) == .success,
           let isMinimized = minimized as? Bool, isMinimized { return }

        var main: AnyObject?
        if AXUIElementCopyAttributeValue(
            window, kAXMainAttribute as CFString, &main
        ) == .success,
           let isMain = main as? Bool, !isMain { return }

        if !centerViaAX(window: window),
           let app = NSWorkspace.shared.frontmostApplication {
            centerFrontmostWithAppleScript(app)
        }
    }

    /// Centers the frontmost application window, trying AX first then AppleScript.
    func centerFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?

        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow
        ) == .success,
           let focused = focusedWindow,
           let window = focused.asAXUIElement {
            center(window: window)
        } else if let window = windows(for: appElement)?.first {
            center(window: window)
        } else {
            centerFrontmostWithAppleScript(app)
        }
    }

    // MARK: - AX centering

    private func centerViaAX(window: AXUIElement) -> Bool {
        // Use visibleFrame so the Dock and menu bar are excluded.
        guard let screen = selectedScreen ?? NSScreen.main else { return false }

        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &sizeValue
        ) == .success,
              let size = sizeValue,
              CFGetTypeID(size) == AXValueGetTypeID() else { return false }

        var windowSize = CGSize()
        guard AXValueGetValue(size as! AXValue, .cgSize, &windowSize),
              windowSize.width > 0, windowSize.height > 0 else { return false }

        let target = CGPoint(
            x: screen.visibleFrame.midX - windowSize.width  / 2,
            y: screen.visibleFrame.midY - windowSize.height / 2
        )
        animateWindowPosition(window, to: target)
        return true
    }

    private func animateWindowPosition(_ window: AXUIElement, to point: CGPoint) {
        guard let currentPosValue = windowPosition(window) else { return }

        var currentPos = CGPoint()
        AXValueGetValue(currentPosValue, .cgPoint, &currentPos)

        // Cancel any in-flight animation before starting a new one.
        animationWorkItem?.cancel()

        let steps = 10
        let dx = (point.x - currentPos.x) / CGFloat(steps)
        let dy = (point.y - currentPos.y) / CGFloat(steps)

        // Capture a fresh work item so stale closures can detect cancellation.
        let workItem = DispatchWorkItem {}
        animationWorkItem = workItem

        func step(_ i: Int) {
            guard i <= steps, !workItem.isCancelled else { return }

            var pos = CGPoint(
                x: currentPos.x + dx * CGFloat(i),
                y: currentPos.y + dy * CGFloat(i)
            )
            if let val = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, val)
            }
            if i < steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { step(i + 1) }
            }
        }

        step(1)
    }

    private func windowPosition(_ window: AXUIElement) -> AXValue? {
        var posValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &posValue
        ) == .success,
              let value = posValue,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return value as! AXValue
    }

    private func windows(for appElement: AXUIElement) -> [AXUIElement]? {
        var windows: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windows
        ) == .success else { return nil }
        return (windows as? [AnyObject])?.compactMap { $0.asAXUIElement }
    }

    // MARK: - AppleScript fallback

    private func centerFrontmostWithAppleScript(_ app: NSRunningApplication) {
        if let bundleId = app.bundleIdentifier {
            executeAppleScriptCentering(appTarget: "id \"\(bundleId)\"",
                                        logLabel:  "bundle \(bundleId)")
        } else {
            centerWithAppleScript(appName: app.localizedName ?? "Unknown App")
        }
    }

    private func centerWithAppleScript(appName: String) {
        let sanitized = appName
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\0", with: "")

        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ".-_"))

        guard sanitized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            NSLog("Rejected potentially malicious app name: \(appName)")
            return
        }
        executeAppleScriptCentering(appTarget: "\"\(sanitized)\"",
                                    logLabel:  "app \(sanitized)")
    }

    /// Single AppleScript body; `appTarget` is a fully-formed AS target expression.
    private func executeAppleScriptCentering(appTarget: String, logLabel: String) {
        let script = """
        tell application \(appTarget)
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
        if let error = error { NSLog("AppleScript error for \(logLabel): \(error)") }
    }
}

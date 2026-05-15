//
// WindowCenterer.swift
// Centered
//
// All window-centering logic: AX attribute reads, ease-out animation, and the
// AppleScript fallback path. AppDelegate owns one instance and delegates to it.
//
// @MainActor: AX callbacks and hotkey handlers both run on the main thread.
//
// AppleScript note:
//   executeAppleScriptCentering dispatches to a background queue because
//   NSAppleScript.executeAndReturnError is synchronous and can stall the
//   main run loop for hundreds of milliseconds.
//
//   SECURITY: bundle ID is validated with three checks before interpolation:
//     1. Character allowlist (alphanumerics + '.-')
//     2. Length bound (≤ 255)
//     3. Cross-verification against NSRunningApplication to block spoof attacks
//

import Cocoa
import ApplicationServices
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "WindowCenterer"
)

// MARK: - Animation constants

/// 16 steps × 12 ms ≈ 192 ms total, ~83 fps.
private let kAnimationSteps = 16
private let kAnimationInterval: TimeInterval = 0.012

// MARK: - Bundle-ID validation

private let kBundleIDAllowedChars = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"
)
private let kBundleIDMaxLength: Int = 255

private let appleScriptQueue = DispatchQueue(label: "com.centered.applescript", qos: .userInitiated)

// MARK: - AX helpers

private func axElement(_ object: AnyObject) -> AXUIElement? {
    CFGetTypeID(object) == AXUIElementGetTypeID() ? (object as? AXUIElement) : nil
}

private func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success
    else { return nil }
    return raw as? Bool
}

private func axValue(_ element: AXUIElement, attribute: String) -> AXValue? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let value = raw,
          CFGetTypeID(value) == AXValueGetTypeID(),
          let axVal = value as? AXValue
    else { return nil }
    return axVal
}

private func axElementAttr(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let value = raw
    else { return nil }
    return axElement(value)
}

private func axIsValid(_ element: AXUIElement) -> Bool {
    var raw: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw)
    return err != .invalidUIElement && err != .cannotComplete
}

// MARK: - WindowCenterer

@MainActor
final class WindowCenterer {

    var selectedScreen: NSScreen?
    private(set) var isCentering = false
    private var animationWorkItems: [DispatchWorkItem] = []

    // MARK: - Public API

    /// Centers `window` on the selected (or main) screen.
    /// Skips minimized and non-main windows; a nil axBool is treated permissively.
    func center(window: AXUIElement) {
        guard axBool(window, attribute: kAXMinimizedAttribute) != true,
              axBool(window, attribute: kAXMainAttribute)      != false
        else { return }

        if !centerViaAX(window: window),
           let app = NSWorkspace.shared.frontmostApplication {
            centerFrontmostWithAppleScript(app)
        }
    }

    /// Centers the focused window of the frontmost app; falls back to AppleScript.
    func centerFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)

        if let win = axElementAttr(el, attribute: kAXFocusedWindowAttribute) {
            center(window: win)
        } else if let win = axWindows(el)?.first {
            center(window: win)
        } else {
            centerFrontmostWithAppleScript(app)
        }
    }

    /// Centers every non-minimized window of the frontmost app.
    func centerAllWindows() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)

        guard let windows = axWindows(el), !windows.isEmpty else {
            centerFrontmostWithAppleScript(app)
            return
        }

        var anyFailed = false
        for win in windows where axBool(win, attribute: kAXMinimizedAttribute) != true {
            if !centerViaAX(window: win) { anyFailed = true }
        }
        if anyFailed { centerFrontmostWithAppleScript(app) }
    }

    func cancelAnimation() {
        animationWorkItems.forEach { $0.cancel() }
        animationWorkItems.removeAll()
        isCentering = false
    }

    // MARK: - Geometry

    nonisolated static func centeredOrigin(windowSize: CGSize, in screenRect: CGRect) -> CGPoint {
        CGPoint(
            x: screenRect.midX - windowSize.width / 2,
            y: screenRect.midY - windowSize.height / 2
        )
    }

    /// Cubic ease-out: f(t) = 1-(1-t)³.
    nonisolated static func animationPosition(
        from start: CGPoint,
        to end: CGPoint,
        step i: Int,
        totalSteps: Int
    ) -> CGPoint {
        guard totalSteps > 0 else { return end }
        let clampedStep = min(max(i, 0), totalSteps)
        let t = 1.0 - pow(1.0 - CGFloat(clampedStep) / CGFloat(totalSteps), 3.0)
        return CGPoint(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t
        )
    }

    nonisolated static func isValidAppleScriptBundleID(_ bundleID: String) -> Bool {
        !bundleID.isEmpty &&
        bundleID.count <= kBundleIDMaxLength &&
        bundleID.unicodeScalars.allSatisfy { kBundleIDAllowedChars.contains($0) }
    }

    // MARK: - AX centering

    @discardableResult
    private func centerViaAX(window: AXUIElement) -> Bool {
        guard let screen  = selectedScreen ?? NSScreen.main,
              let sizeVal = axValue(window, attribute: kAXSizeAttribute)
        else { return false }

        var size = CGSize()
        guard AXValueGetValue(sizeVal, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return false }

        let target = CGPoint.centeredOrigin(of: size, in: screen.visibleFrame)
        animateWindowPosition(window, to: target)
        return true
    }

    private func animateWindowPosition(_ window: AXUIElement, to target: CGPoint) {
        guard let posVal = axValue(window, attribute: kAXPositionAttribute) else { return }
        var start = CGPoint()
        guard AXValueGetValue(posVal, .cgPoint, &start), start != target else { return }

        isCentering = true
        let token   = DispatchWorkItem {}
        animationWorkItems.append(token)
        let posKey  = kAXPositionAttribute as CFString

        func finish() {
            animationWorkItems.removeAll { $0 === token }
            if animationWorkItems.isEmpty { isCentering = false }
        }

        func step(_ i: Int) {
            guard i <= kAnimationSteps,
                  !token.isCancelled,
                  axIsValid(window)
            else { finish(); return }

            var pos = WindowCenterer.animationPosition(
                from: start, to: target, step: i, totalSteps: kAnimationSteps
            )
            if let val = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(window, posKey, val)
            }
            if i < kAnimationSteps {
                DispatchQueue.main.asyncAfter(deadline: .now() + kAnimationInterval) { step(i + 1) }
            } else {
                finish()
            }
        }

        step(1)
    }

    private func axWindows(_ el: AXUIElement) -> [AXUIElement]? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &raw) == .success,
              let list = raw as? [AnyObject]
        else { return nil }
        return list.compactMap { axElement($0) }
    }

    // MARK: - AppleScript fallback

    private func centerFrontmostWithAppleScript(_ app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier else {
            logger.debug("AppleScript fallback skipped: no bundle ID for pid \(app.processIdentifier)")
            return
        }
        executeAppleScriptCentering(bundleID: bid, app: app)
    }

    private func executeAppleScriptCentering(bundleID: String, app: NSRunningApplication) {
        guard WindowCenterer.isValidAppleScriptBundleID(bundleID) else {
            logger.debug("Rejected bundle ID with invalid format")
            return
        }
        guard NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { $0.processIdentifier == app.processIdentifier })
        else {
            logger.debug("Rejected bundle ID \(bundleID, privacy: .public): pid mismatch (possible spoof)")
            return
        }

        let script = """
        tell application id \"\(bundleID)\"
            activate
            try
                set win to front window
                set winBounds to bounds of win
                tell application "System Events" to tell first desktop
                    set screenBounds to bounds
                    set screenWidth  to item 3 of screenBounds
                    set screenHeight to item 4 of screenBounds
                end tell
                set winWidth  to item 3 of winBounds - item 1 of winBounds
                set winHeight to item 4 of winBounds - item 2 of winBounds
                set newX to (screenWidth  - winWidth)  / 2
                set newY to (screenHeight - winHeight) / 2
                try
                    set bounds of win to {newX, newY, newX + winWidth, newY + winHeight} with animation
                on error
                    set position of win to {newX, newY}
                    set size     of win to {winWidth, winHeight}
                end try
            end try
        end tell
        """
        appleScriptQueue.async {
            var error: NSDictionary?
            _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                logger.debug("AppleScript error (\(bundleID, privacy: .public)): \(error)")
            }
        }
    }
}

// MARK: - CGPoint convenience

private extension CGPoint {
    static func centeredOrigin(of size: CGSize, in rect: CGRect) -> CGPoint {
        WindowCenterer.centeredOrigin(windowSize: size, in: rect)
    }
}

//
// WindowCenterer.swift
// Centered
//
// All window-centering logic: AX attribute reads, ease-out animation, and the
// AppleScript fallback path. AppDelegate owns one instance and delegates to it.
//
// @MainActor: AX callbacks fire on the main run loop; hotkey handlers dispatch
// to main. The compiler enforces this.
//
// AppleScript note:
//   executeAppleScriptCentering dispatches NSAppleScript.executeAndReturnError
//   to a background queue because it is a synchronous blocking call that can
//   stall the main run loop for hundreds of milliseconds on slow or busy apps.
//
//   SECURITY: The bundleID passed into the AppleScript source string is
//   sanitised against kBundleIDAllowedChars (.alphanumerics + ".-") before
//   interpolation. That allowlist is the *only* thing preventing script
//   injection — do not remove or relax it.
//

import Cocoa
import ApplicationServices
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Centered",
                            category: "WindowCenterer")

// MARK: - Animation constants

/// 16 steps × 12 ms ≈ 192 ms total, ~83 fps.
private let kAnimationSteps:    Int    = 16
private let kAnimationInterval: Double = 0.012

// MARK: - Bundle-ID allowlist (built once)

private let kBundleIDAllowedChars: CharacterSet =
    .alphanumerics.union(CharacterSet(charactersIn: ".-"))

/// Dedicated serial queue for blocking AppleScript calls so the main run loop
/// is never stalled by a slow or unresponsive target application.
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

/// Returns true if `element` still refers to a live UI element.
private func axIsValid(_ element: AXUIElement) -> Bool {
    var raw: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw)
    return err != .invalidUIElement && err != .cannotComplete
}

// MARK: - WindowCenterer

@MainActor
final class WindowCenterer {

    // MARK: Properties

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
    /// For each window where AX centering fails, falls back to AppleScript
    /// for that app (one AppleScript call covers all windows in the app).
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
        // If any AX centering failed, issue one AppleScript call for the app.
        // AppleScript operates on the front window, so this is best-effort for
        // partially-AX-compliant apps (e.g. Finder).
        if anyFailed { centerFrontmostWithAppleScript(app) }
    }

    /// Cancels all in-flight animations immediately.
    func cancelAnimation() {
        animationWorkItems.forEach { $0.cancel() }
        animationWorkItems.removeAll()
        isCentering = false
    }

    // MARK: - Geometry (static — usable from tests)

    static func centeredOrigin(windowSize: CGSize, in screenRect: CGRect) -> CGPoint {
        CGPoint(x: screenRect.midX - windowSize.width  / 2,
                y: screenRect.midY - windowSize.height / 2)
    }

    /// Cubic ease-out: f(t) = 1-(1-t)³.
    static func animationPosition(from start: CGPoint, to end: CGPoint,
                                  step i: Int, totalSteps: Int) -> CGPoint {
        let t = 1.0 - pow(1.0 - CGFloat(i) / CGFloat(totalSteps), 3.0)
        return CGPoint(x: start.x + (end.x - start.x) * t,
                       y: start.y + (end.y - start.y) * t)
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
        AXValueGetValue(posVal, .cgPoint, &start)

        // Skip animation if the window is already at the target position.
        guard start != target else { return }

        isCentering = true
        let token   = DispatchWorkItem {}
        animationWorkItems.append(token)
        let posKey  = kAXPositionAttribute as CFString

        func finish() {
            animationWorkItems.removeAll { $0 === token }
            if animationWorkItems.isEmpty { isCentering = false }
        }

        func step(_ i: Int) {
            // Validity check before writing: if the window was destroyed between
            // frames, bail immediately rather than attempting a write.
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
        executeAppleScriptCentering(bundleID: bid)
    }

    private func executeAppleScriptCentering(bundleID: String) {
        // SECURITY: bundleID is validated against kBundleIDAllowedChars before
        // being interpolated into the script string. Do not remove this check.
        guard bundleID.unicodeScalars.allSatisfy({ kBundleIDAllowedChars.contains($0) }) else {
            logger.debug("Rejected bundle ID with disallowed characters")
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
        // NSAppleScript.executeAndReturnError is synchronous and can block for
        // hundreds of milliseconds. Dispatch to a background queue so the main
        // run loop — and therefore all UI and AX callbacks — remain responsive.
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

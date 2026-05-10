//
// WindowCenterer.swift
// Centered
//
// Owns all window-centering logic: AX attribute reads, animation, and the
// AppleScript fallback path.  AppDelegate instantiates one and delegates to it.
//
// @MainActor: all methods are called on the main thread (AX callbacks fire on
// the main run loop; hotkey handler dispatches to main).  The compiler now
// enforces this instead of relying on documentation.
//

import Cocoa
import ApplicationServices
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Centered",
                            category: "WindowCenterer")

// MARK: - Animation constants

/// Total number of animation steps.  At kAnimationInterval seconds each this
/// gives a ~192 ms animation duration.
private let kAnimationSteps:    Int     = 16
/// Seconds between each animation frame (~83 fps).
private let kAnimationInterval: Double  = 0.012

// MARK: - AX helpers (file-private)

/// Casts `object` to `AXUIElement` iff the CF type IDs match.
private func axElement(_ object: AnyObject) -> AXUIElement? {
    CFGetTypeID(object) == AXUIElementGetTypeID() ? (object as? AXUIElement) : nil
}

/// Reads a Bool attribute from `element`; returns `nil` on any failure.
private func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success
    else { return nil }
    return raw as? Bool
}

/// Reads a typed AXValue attribute from `element`; returns `nil` on any failure.
/// NOTE: Do NOT use for attributes that return AXUIElement (e.g. kAXFocusedWindowAttribute).
private func axValue(_ element: AXUIElement, attribute: String) -> AXValue? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    return (value as! AXValue)
}

/// Reads an AXUIElement-typed attribute (e.g. kAXFocusedWindowAttribute).
private func axElementAttr(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    var raw: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let value = raw
    else { return nil }
    return axElement(value)
}

// MARK: -

@MainActor
final class WindowCenterer {

    // MARK: - Selected screen
    // Plain stored property — @MainActor serialises all access.

    var selectedScreen: NSScreen?

    // MARK: - Animation state
    // One active work-item token per in-flight animation.  Cancelling it stops
    // the recursive step() chain for that window.

    private var animationWorkItems: [DispatchWorkItem] = []
    private(set) var isCentering = false

    // MARK: - Public entry points

    /// Centers `window` on the selected (or main) screen.
    /// Silently skips minimized or non-main windows.
    /// - Note: `nil` from axBool means the attribute is unreadable; we treat
    ///   that as "not minimized" / "is main" so centering proceeds rather than
    ///   silently no-oping for apps that don't expose these attributes.
    func center(window: AXUIElement) {
        guard axBool(window, attribute: kAXMinimizedAttribute) != true,
              axBool(window, attribute: kAXMainAttribute)      != false
        else { return }

        if !centerViaAX(window: window),
           let app = NSWorkspace.shared.frontmostApplication {
            centerFrontmostWithAppleScript(app)
        }
    }

    /// Centers the frontmost application window, trying AX first then AppleScript.
    func centerFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let window = axElementAttr(appElement, attribute: kAXFocusedWindowAttribute)
                        ?? axWindows(appElement)?.first {
            center(window: window)
        } else {
            centerFrontmostWithAppleScript(app)
        }
    }

    /// Centers every non-minimized window belonging to the frontmost application.
    /// Each window is animated independently; animations run concurrently.
    func centerAllWindows() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        guard let windows = axWindows(appElement), !windows.isEmpty else {
            // No AX windows — fall back to single-window AppleScript path.
            centerFrontmostWithAppleScript(app)
            return
        }

        for window in windows {
            // Skip minimized windows; treat unreadable attribute as non-minimized.
            guard axBool(window, attribute: kAXMinimizedAttribute) != true else { continue }
            _ = centerViaAX(window: window)
        }
    }

    /// Cancels all in-flight animations and resets centering state.
    func cancelAnimation() {
        animationWorkItems.forEach { $0.cancel() }
        animationWorkItems.removeAll()
        isCentering = false
    }

    // MARK: - Geometry (static — safe to call from tests without an actor)

    /// Returns the top-left origin that centers a window of `windowSize`
    /// within `screenRect` (pass `screen.visibleFrame`).
    static func centeredOrigin(windowSize: CGSize, in screenRect: CGRect) -> CGPoint {
        CGPoint(
            x: screenRect.midX - windowSize.width  / 2,
            y: screenRect.midY - windowSize.height / 2
        )
    }

    /// Returns the eased position at animation step `i` of `totalSteps` between
    /// `start` and `end` using a cubic ease-out curve: f(t) = 1 - (1-t)^3.
    ///
    /// Ease-out decelerates toward the target, giving the motion a native macOS
    /// feel (fast start, smooth settle) compared to linear interpolation.
    static func animationPosition(from start: CGPoint,
                                  to end: CGPoint,
                                  step i: Int,
                                  totalSteps: Int) -> CGPoint {
        let linear = CGFloat(i) / CGFloat(totalSteps)
        // Cubic ease-out: starts fast, decelerates into the final position.
        let t = 1.0 - pow(1.0 - linear, 3.0)
        return CGPoint(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t
        )
    }

    // MARK: - AX centering

    private func centerViaAX(window: AXUIElement) -> Bool {
        guard let screen  = selectedScreen ?? NSScreen.main,
              let sizeVal = axValue(window, attribute: kAXSizeAttribute)
        else { return false }

        var windowSize = CGSize()
        guard AXValueGetValue(sizeVal, .cgSize, &windowSize),
              windowSize.width > 0, windowSize.height > 0 else { return false }

        animateWindowPosition(window, to: .centeredOrigin(of: windowSize, in: screen.visibleFrame))
        return true
    }

    private func animateWindowPosition(_ window: AXUIElement, to point: CGPoint) {
        guard let posVal = axValue(window, attribute: kAXPositionAttribute) else { return }

        var currentPos = CGPoint()
        AXValueGetValue(posVal, .cgPoint, &currentPos)

        isCentering = true

        let workItem = DispatchWorkItem {}
        animationWorkItems.append(workItem)

        func step(_ i: Int) {
            guard i <= kAnimationSteps, !workItem.isCancelled else {
                // Clean up this work item and clear isCentering if nothing else is running.
                self.animationWorkItems.removeAll { $0 === workItem }
                if self.animationWorkItems.isEmpty { self.isCentering = false }
                return
            }
            var pos = WindowCenterer.animationPosition(
                from: currentPos, to: point, step: i, totalSteps: kAnimationSteps
            )
            if let val = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, val)
            }
            if i < kAnimationSteps {
                DispatchQueue.main.asyncAfter(deadline: .now() + kAnimationInterval) { step(i + 1) }
            } else {
                self.animationWorkItems.removeAll { $0 === workItem }
                if self.animationWorkItems.isEmpty { self.isCentering = false }
            }
        }
        step(1)
    }

    private func axWindows(_ appElement: AXUIElement) -> [AXUIElement]? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &raw
        ) == .success else { return nil }
        return (raw as? [AnyObject])?.compactMap { axElement($0) } ?? []
    }

    // MARK: - AppleScript fallback
    // Only uses the bundle identifier — never interpolates user-visible app names
    // into the script string, eliminating the AppleScript injection vector.

    private func centerFrontmostWithAppleScript(_ app: NSRunningApplication) {
        guard let bundleId = app.bundleIdentifier else {
            logger.debug("Skipping AppleScript fallback: no bundle ID for pid \(app.processIdentifier)")
            return
        }
        executeAppleScriptCentering(bundleId: bundleId)
    }

    private func executeAppleScriptCentering(bundleId: String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard bundleId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            logger.debug("Rejected bundle ID with disallowed characters")
            return
        }

        let script = """
        tell application id \"\(bundleId)\"
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
            logger.debug("AppleScript error for bundle \(bundleId, privacy: .public): \(error)")
        }
    }
}

// MARK: - CGPoint convenience

private extension CGPoint {
    static func centeredOrigin(of size: CGSize, in rect: CGRect) -> CGPoint {
        WindowCenterer.centeredOrigin(windowSize: size, in: rect)
    }
}

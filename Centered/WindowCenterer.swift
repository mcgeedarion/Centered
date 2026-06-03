import Cocoa
import ApplicationServices

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "WindowCenterer"
)

private struct AnimationConfig {
    let steps: Int
    let interval: TimeInterval
    
    static let `default` = AnimationConfig(steps: 16, interval: 0.012)
}

private struct AXWindow: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    // AXUIElement is not Hashable; hash by pid + pointer identity.
    func hash(into hasher: inout Hasher) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        hasher.combine(pid)
        hasher.combine(Unmanaged.passUnretained(element).toOpaque())
    }

    static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        lhs.element === rhs.element
    }

    var isValid: Bool {
        var raw: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw)
        return err != .invalidUIElement && err != .cannotComplete && raw != nil
    }

    var isMinimized: Bool? { bool(for: kAXMinimizedAttribute) }
    var isMain: Bool?      { bool(for: kAXMainAttribute) }

    var size: CGSize? {
        guard let value = axValue(for: kAXSizeAttribute) else { return nil }
        var size = CGSize()
        guard AXValueGetValue(value, .cgSize, &size), size.width > 0, size.height > 0
        else { return nil }
        return size
    }

    var position: CGPoint? {
        guard let value = axValue(for: kAXPositionAttribute) else { return nil }
        var point = CGPoint()
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    func setPosition(_ point: CGPoint) {
        var p = point
        if let val = AXValueCreate(.cgPoint, &p) {
            let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val)
            if err != .success {
                logger.warning("Failed to set window position: \(err)")
            }
        } else {
            logger.warning("Failed to create CGPoint AXValue")
        }
    }

    private func bool(for attribute: String) -> Bool? {
        getAttribute(attribute, as: Bool.self)
    }

    private func axValue(for attribute: String) -> AXValue? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXValueGetTypeID(),
              let axVal = value as? AXValue
        else { return nil }
        return axVal
    }

    private func getAttribute<T>(_ attribute: String, as type: T.Type) -> T? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
            return nil
        }
        return raw as? T
    }
}

@MainActor
final class WindowCenterer {

    var selectedScreen: NSScreen?
    private(set) var isCentering = false

    // Track animation tokens per window so we can cancel/replace cleanly.
    private var animationTokens: [AXWindow: DispatchWorkItem] = [:]

    // Debounce repeated events for the same window.
    private var debounceTokens: [AXWindow: DispatchWorkItem] = [:]
    private let debounceInterval: TimeInterval = 0.03
    
    private let animationConfig = AnimationConfig.default

    func center(window element: AXUIElement) {
        center(window: AXWindow(element))
    }

    private func center(window: AXWindow) {
        guard window.isMinimized != true,
              window.isMain      != false
        else { return }

        let token = DispatchWorkItem { [weak self] in
            self?.performCenter(window: window)
        }
        debounceTokens[window]?.cancel()
        debounceTokens[window] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: token)
    }

    func centerFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)

        if let win = axFocusedWindow(in: el) {
            center(window: win)
        } else if let win = axWindows(el)?.first {
            center(window: win)
        } else {
            AppleScriptCenterer.centerFrontmostWindow(of: app)
        }
    }

    func centerAllWindows() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)

        guard let windows = axWindows(el), !windows.isEmpty else {
            AppleScriptCenterer.centerFrontmostWindow(of: app)
            return
        }

        var anyFailed = false
        for w in windows where w.isMinimized != true {
            if !centerViaAX(window: w) { anyFailed = true }
        }
        if anyFailed {
            AppleScriptCenterer.centerFrontmostWindow(of: app)
        }
    }

    func cancelAnimation() {
        animationTokens.values.forEach { $0.cancel() }
        animationTokens.removeAll()
        debounceTokens.values.forEach { $0.cancel() }
        debounceTokens.removeAll()
        isCentering = false
    }

    private func performCenter(window: AXWindow) {
        // Check and atomically update animation tokens to prevent race condition
        if let token = animationTokens[window], !token.isCancelled {
            return
        }
        
        if !centerViaAX(window: window),
           let app = NSWorkspace.shared.frontmostApplication {
            AppleScriptCenterer.centerFrontmostWindow(of: app)
        }
    }

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

    @discardableResult
    private func centerViaAX(window: AXWindow) -> Bool {
        guard let screen = selectedScreen ?? NSScreen.main,
              let size   = window.size
        else { return false }

        let target = CGPoint.centeredOrigin(of: size, in: screen.visibleFrame)
        animateWindowPosition(window, to: target)
        return true
    }

    private func animateWindowPosition(_ window: AXWindow, to target: CGPoint) {
        guard let start = window.position, start != target else { return }

        isCentering = true
        let token   = DispatchWorkItem {}
        animationTokens[window]?.cancel()
        animationTokens[window] = token

        func finish() {
            if let current = animationTokens[window], current === token {
                animationTokens.removeValue(forKey: window)
            }
            if animationTokens.isEmpty { isCentering = false }
        }

        func step(_ i: Int) {
            guard i <= animationConfig.steps,
                  !token.isCancelled,
                  window.isValid
            else { finish(); return }

            let pos = WindowCenterer.animationPosition(
                from: start, to: target, step: i, totalSteps: animationConfig.steps
            )
            window.setPosition(pos)

            if i < animationConfig.steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + animationConfig.interval) { [weak self] in
                    self?.step(i + 1)
                }
            } else {
                finish()
            }
        }

        step(1)
    }

    private func axFocusedWindow(in appElement: AXUIElement) -> AXWindow? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXUIElementGetTypeID(),
              let el = value as? AXUIElement
        else { return nil }
        return AXWindow(el)
    }

    private func axWindows(_ el: AXUIElement) -> [AXWindow]? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &raw) == .success,
              let list = raw as? [AnyObject]
        else { return nil }
        return list.compactMap { obj in
            guard CFGetTypeID(obj) == AXUIElementGetTypeID(),
                  let el = obj as? AXUIElement else { return nil }
            return AXWindow(el)
        }
    }
}

private extension CGPoint {
    static func centeredOrigin(of size: CGSize, in rect: CGRect) -> CGPoint {
        WindowCenterer.centeredOrigin(windowSize: size, in: rect)
    }
}

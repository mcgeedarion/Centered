import Cocoa
import ApplicationServices
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "WindowCenterer"
)

enum WindowAnimationStyle: String, CaseIterable, Codable {
    case instant
    case subtle
    case smooth

    var displayName: String {
        switch self {
        case .instant: return "Instant"
        case .subtle: return "Subtle"
        case .smooth: return "Smooth"
        }
    }
}

private struct AnimationConfig {
    let steps: Int
    let interval: TimeInterval

    static func config(for style: WindowAnimationStyle) -> AnimationConfig {
        switch style {
        case .instant: return AnimationConfig(steps: 1, interval: 0)
        case .subtle:  return AnimationConfig(steps: 8, interval: 0.01)
        case .smooth:  return AnimationConfig(steps: 16, interval: 0.012)
        }
    }
}

private struct AXWindow: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

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
    var isPaused = false
    var centersOnWindowScreen = true
    var animationStyle: WindowAnimationStyle = .smooth
    private(set) var isCentering = false

    private var animationTokens: [AXWindow: DispatchWorkItem] = [:]

    private var debounceTokens: [AXWindow: DispatchWorkItem] = [:]
    private let debounceInterval: TimeInterval = 0.03
    

    func center(window element: AXUIElement) {
        guard !isPaused else { return }
        center(window: AXWindow(element))
    }

    private func center(window: AXWindow) {
        guard window.isMinimized != true,
              window.isMain      != false
        else { return }

        let token = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceTokens.removeValue(forKey: window)
            self.performCenter(window: window)
        }
        debounceTokens[window]?.cancel()
        debounceTokens[window] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: token)
    }

    func centerFrontmost() {
        guard !isPaused, let app = NSWorkspace.shared.frontmostApplication else { return }
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
        guard !isPaused, let app = NSWorkspace.shared.frontmostApplication else { return }
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

    func moveFrontmostWindow(toScreenIndex index: Int) {
        guard !isPaused, let app = NSWorkspace.shared.frontmostApplication else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let screens = NSScreen.screens

        guard index >= 0 && index < screens.count else { return }

        if let win = axFocusedWindow(in: el) ?? axWindows(el)?.first {
            moveWindowToScreen(win, to: screens[index])
        } else {
            // Fallback to AppleScript if AX fails
            AppleScriptCenterer.moveFrontmostWindow(toScreenIndex: index, of: app)
        }
    }

    private func moveWindowToScreen(_ window: AXWindow, to screen: NSScreen) {
        guard let size = window.size else { return }
        let targetOrigin = CGPoint.centeredOrigin(of: size, in: screen.visibleFrame)
        window.setPosition(targetOrigin)
    }

    func cancelAnimation() {
        animationTokens.values.forEach { $0.cancel() }
        animationTokens.removeAll()
        debounceTokens.values.forEach { $0.cancel() }
        debounceTokens.removeAll()
        isCentering = false
    }

    private func performCenter(window: AXWindow) {
        if let existing = animationTokens[window] {
            existing.cancel()
            animationTokens.removeValue(forKey: window)
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
        guard let size = window.size,
              let position = window.position,
              let screen = targetScreen(forWindowFrame: CGRect(origin: position, size: size))
        else { return false }

        guard !WindowCenterer.isEffectivelyFullScreen(windowSize: size, in: screen.visibleFrame) else {
            logger.debug("Skipping near full-screen window")
            return true
        }

        let target = CGPoint.centeredOrigin(of: size, in: screen.visibleFrame)
        animateWindowPosition(window, from: position, to: target)
        return true
    }

    private func animateWindowPosition(_ window: AXWindow, from start: CGPoint, to target: CGPoint) {
        guard start != target else { return }

        let animationConfig = AnimationConfig.config(for: animationStyle)
        if animationConfig.steps <= 1 {
            window.setPosition(target)
            return
        }

        isCentering = true
        let token = DispatchWorkItem {}
        animationTokens[window]?.cancel()
        animationTokens[window] = token

        runAnimationStep(
            1,
            window: window,
            from: start,
            to: target,
            config: animationConfig,
            token: token
        )
    }

    private func runAnimationStep(
        _ step: Int,
        window: AXWindow,
        from start: CGPoint,
        to target: CGPoint,
        config: AnimationConfig,
        token: DispatchWorkItem
    ) {
        guard step <= config.steps,
              !token.isCancelled,
              window.isValid
        else {
            finishAnimation(for: window, token: token)
            return
        }

        let position = WindowCenterer.animationPosition(
            from: start,
            to: target,
            step: step,
            totalSteps: config.steps
        )
        window.setPosition(position)

        if step < config.steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + config.interval) { [weak self] in
                self?.runAnimationStep(
                    step + 1,
                    window: window,
                    from: start,
                    to: target,
                    config: config,
                    token: token
                )
            }
        } else {
            finishAnimation(for: window, token: token)
        }
    }

    private func finishAnimation(for window: AXWindow, token: DispatchWorkItem) {
        if let current = animationTokens[window], current === token {
            animationTokens.removeValue(forKey: window)
        }
        if animationTokens.isEmpty { isCentering = false }
    }

    private func targetScreen(forWindowFrame windowFrame: CGRect) -> NSScreen? {
        if centersOnWindowScreen,
           let screen = WindowCenterer.screen(containing: windowFrame, screens: NSScreen.screens) {
            return screen
        }
        return selectedScreen ?? NSScreen.main ?? NSScreen.screens.first
    }

    nonisolated static func isValidAppleScriptBundleID(_ bundleID: String) -> Bool {
        AppleScriptCenterer.isValidBundleID(bundleID)
    }

    nonisolated static func isEffectivelyFullScreen(windowSize: CGSize, in screenRect: CGRect) -> Bool {
        windowSize.width >= screenRect.width * 0.98 && windowSize.height >= screenRect.height * 0.98
    }

    static func screen(containing windowFrame: CGRect, screens: [NSScreen]) -> NSScreen? {
        guard let index = bestScreenIndex(containing: windowFrame, screenRects: screens.map(\.visibleFrame)) else {
            return nil
        }
        return screens[index]
    }

    nonisolated static func bestScreenIndex(containing windowFrame: CGRect, screenRects: [CGRect]) -> Int? {
        guard !screenRects.isEmpty else { return nil }

        let overlapAreas = screenRects.map { $0.intersection(windowFrame).area }
        if let largestOverlap = overlapAreas.max(), largestOverlap > 0 {
            return screenRects.indices.max { overlapAreas[$0] < overlapAreas[$1] }
        }

        return screenRects.indices.min {
            screenRects[$0].center.squaredDistance(to: windowFrame.center) <
            screenRects[$1].center.squaredDistance(to: windowFrame.center)
        }
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

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

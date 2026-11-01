import Cocoa
import ApplicationServices
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "WindowCenterer"
)

enum WindowAnimationStyle: String, CaseIterable, Codable {
    case instant, subtle, smooth

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
        case .subtle: return AnimationConfig(steps: 8, interval: 0.01)
        case .smooth: return AnimationConfig(steps: 16, interval: 0.012)
        }
    }
}

enum WindowPositioningResult: Equatable {
    case succeeded, failed, cancelled
}

@MainActor
final class WindowPositioningOperation {
    private(set) var result: WindowPositioningResult?
    private var completion: ((WindowPositioningResult) -> Void)?

    init(completion: @escaping (WindowPositioningResult) -> Void) {
        self.completion = completion
    }

    func finish(_ result: WindowPositioningResult) {
        guard self.result == nil else { return }
        self.result = result
        let callback = completion
        completion = nil
        callback?(result)
    }
}

enum AXPositionWriter {
    static func write(
        _ point: CGPoint,
        to element: AXUIElement,
        setter: (AXUIElement, CFString, CFTypeRef) -> AXError = {
            AXUIElementSetAttributeValue($0, $1, $2)
        }
    ) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else {
            logger.warning("Failed to create CGPoint AXValue")
            return false
        }
        let error = setter(element, kAXPositionAttribute as CFString, value)
        guard error == .success else {
            logger.warning("Failed to set window position, AXError code: \(error.rawValue)")
            return false
        }
        return true
    }
}

private struct AXWindow: Hashable {
    let element: AXUIElement

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    var isValid: Bool {
        var raw: AnyObject?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success
            && raw != nil
    }

    var isMinimized: Bool? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &raw) == .success
        else { return nil }
        return raw as? Bool
    }

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

    func setPosition(_ point: CGPoint) -> Bool {
        AXPositionWriter.write(point, to: element)
    }

    private func axValue(for attribute: String) -> AXValue? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

@MainActor
final class WindowCenterer {
    var selectedScreen: NSScreen?
    var isPaused = false
    var centersOnWindowScreen = true
    var animationStyle: WindowAnimationStyle = .smooth
    var onPositioningFailure: ((AXUIElement) -> Void)?
    private(set) var isCentering = false

    private var animationTokens: [AXWindow: WindowPositioningOperation] = [:]
    private var debounceTokens: [AXWindow: DispatchWorkItem] = [:]
    private let debounceInterval: TimeInterval = 0.03

    func center(window element: AXUIElement) {
        guard !isPaused else { return }
        let window = AXWindow(element: element)
        guard window.isMinimized != true else { return }
        let token = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceTokens.removeValue(forKey: window)
            guard !self.isPaused else { return }
            self.centerViaAX(window: window) { [weak self] result in
                if result == .failed { self?.reportFailure(window) }
            }
        }
        debounceTokens.removeValue(forKey: window)?.cancel()
        debounceTokens[window] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: token)
    }

    func centerFrontmost() {
        guard !isPaused, let app = NSWorkspace.shared.frontmostApplication else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = axFocusedWindow(in: element) ?? axWindows(element)?.first else {
            AppleScriptCenterer.centerFrontmostWindow(of: app, in: fallbackScreenFrame())
            return
        }
        centerViaAX(window: window) { [weak self] result in
            guard let self, result == .failed else { return }
            self.reportFailure(window)
            self.fallbackForManualWindow(window, app: app, frame: self.fallbackScreenFrame(for: window))
        }
    }

    func centerAllWindows() {
        guard !isPaused, let app = NSWorkspace.shared.frontmostApplication else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axWindows(element), !windows.isEmpty else {
            AppleScriptCenterer.centerAllWindows(of: app, in: fallbackScreenFrame())
            return
        }
        for window in windows where window.isMinimized != true {
            centerViaAX(window: window) { [weak self] result in
                guard let self, result == .failed else { return }
                self.reportFailure(window)
                // AX array indices are not stable AppleScript window identifiers.
                // Only retry the still-focused window; report other partial failures.
                let currentApp = AXUIElementCreateApplication(app.processIdentifier)
                guard let focused = self.axFocusedWindow(in: currentApp), focused == window else { return }
                self.fallbackForManualWindow(window, app: app, frame: self.fallbackScreenFrame(for: window))
            }
        }
    }

    func moveFrontmostWindow(toScreenIndex index: Int) {
        guard !isPaused, let app = NSWorkspace.shared.frontmostApplication else { return }
        let screens = NSScreen.screens
        guard screens.indices.contains(index) else { return }
        let frame = Self.accessibilityFrame(for: screens[index])
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = axFocusedWindow(in: element) ?? axWindows(element)?.first else {
            AppleScriptCenterer.centerFrontmostWindow(of: app, in: frame)
            return
        }
        cancelWork(for: window)
        guard let size = window.size,
              window.setPosition(Self.centeredOrigin(windowSize: size, in: frame)) else {
            reportFailure(window)
            fallbackForManualWindow(window, app: app, frame: frame)
            return
        }
    }

    func cancelAnimation() {
        let operations = Array(animationTokens.values)
        animationTokens.removeAll()
        debounceTokens.values.forEach { $0.cancel() }
        debounceTokens.removeAll()
        isCentering = false
        operations.forEach { $0.finish(.cancelled) }
    }

    private func cancelWork(for window: AXWindow) {
        debounceTokens.removeValue(forKey: window)?.cancel()
        let previous = animationTokens.removeValue(forKey: window)
        isCentering = !animationTokens.isEmpty
        previous?.finish(.cancelled)
    }

    private func reportFailure(_ window: AXWindow) {
        logger.warning("Window positioning failed; the requested operation was not completed via AX")
        onPositioningFailure?(window.element)
    }

    private func fallbackForManualWindow(_ window: AXWindow, app: NSRunningApplication, frame: CGRect?) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if let focused = axFocusedWindow(in: element), focused != window { return }
        AppleScriptCenterer.centerFrontmostWindow(of: app, in: frame)
    }

    /// All centering, overlap tests and fallback bounds use AX's top-left coordinates.
    nonisolated static func accessibilityRect(fromAppKit rect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func accessibilityFrame(for screen: NSScreen) -> CGRect {
        // NSScreen.main follows keyboard focus; the first screen anchors global coordinates.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return accessibilityRect(fromAppKit: screen.visibleFrame, primaryScreenTop: primaryTop)
    }

    nonisolated static func centeredOrigin(windowSize: CGSize, in screenRect: CGRect) -> CGPoint {
        CGPoint(x: screenRect.midX - windowSize.width / 2, y: screenRect.midY - windowSize.height / 2)
    }

    nonisolated static func animationPosition(
        from start: CGPoint, to end: CGPoint, step: Int, totalSteps: Int
    ) -> CGPoint {
        guard totalSteps > 0 else { return end }
        let clampedStep = min(max(step, 0), totalSteps)
        let t = 1.0 - pow(1.0 - CGFloat(clampedStep) / CGFloat(totalSteps), 3.0)
        return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
    }

    private func centerViaAX(window: AXWindow, completion: @escaping (WindowPositioningResult) -> Void) {
        cancelWork(for: window)
        guard window.isMinimized != true else { completion(.succeeded); return }
        guard let size = window.size, let position = window.position,
              let screen = targetScreen(forWindowFrame: CGRect(origin: position, size: size))
        else { completion(.failed); return }
        let frame = Self.accessibilityFrame(for: screen)
        guard !Self.isEffectivelyFullScreen(windowSize: size, in: frame) else {
            completion(.succeeded)
            return
        }
        let target = Self.centeredOrigin(windowSize: size, in: frame)
        guard position != target else { completion(.succeeded); return }
        let config = AnimationConfig.config(for: animationStyle)
        if config.steps <= 1 {
            completion(window.setPosition(target) ? .succeeded : .failed)
            return
        }
        let operation = WindowPositioningOperation(completion: completion)
        animationTokens[window] = operation
        isCentering = true
        runAnimationStep(1, window: window, from: position, to: target, config: config, operation: operation)
    }

    private func runAnimationStep(
        _ step: Int, window: AXWindow, from start: CGPoint, to target: CGPoint,
        config: AnimationConfig, operation: WindowPositioningOperation
    ) {
        guard operation.result == nil else { return }
        guard window.isValid else {
            finishAnimation(for: window, operation: operation, result: .failed)
            return
        }
        let position = Self.animationPosition(from: start, to: target, step: step, totalSteps: config.steps)
        guard window.setPosition(position) else {
            finishAnimation(for: window, operation: operation, result: .failed)
            return
        }
        if step < config.steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + config.interval) { [weak self] in
                guard let self else { operation.finish(.cancelled); return }
                self.runAnimationStep(step + 1, window: window, from: start, to: target, config: config, operation: operation)
            }
        } else {
            finishAnimation(for: window, operation: operation, result: .succeeded)
        }
    }

    private func finishAnimation(
        for window: AXWindow, operation: WindowPositioningOperation, result: WindowPositioningResult
    ) {
        if let current = animationTokens[window], current === operation {
            animationTokens.removeValue(forKey: window)
        }
        isCentering = !animationTokens.isEmpty
        operation.finish(result)
    }

    private func targetScreen(forWindowFrame windowFrame: CGRect) -> NSScreen? {
        if centersOnWindowScreen, let screen = Self.screen(containing: windowFrame, screens: NSScreen.screens) {
            return screen
        }
        return selectedScreen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func fallbackScreenFrame(for window: AXWindow? = nil) -> CGRect? {
        if let window, let size = window.size, let position = window.position,
           let screen = targetScreen(forWindowFrame: CGRect(origin: position, size: size)) {
            return Self.accessibilityFrame(for: screen)
        }
        guard let screen = selectedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        return Self.accessibilityFrame(for: screen)
    }

    nonisolated static func isValidAppleScriptBundleID(_ bundleID: String) -> Bool {
        AppleScriptCenterer.isValidBundleID(bundleID)
    }

    nonisolated static func isEffectivelyFullScreen(windowSize: CGSize, in screenRect: CGRect) -> Bool {
        windowSize.width >= screenRect.width * 0.98 && windowSize.height >= screenRect.height * 0.98
    }

    static func screen(containing windowFrame: CGRect, screens: [NSScreen]) -> NSScreen? {
        guard let index = bestScreenIndex(containing: windowFrame, screenRects: screens.map { accessibilityFrame(for: $0) })
        else { return nil }
        return screens[index]
    }

    nonisolated static func bestScreenIndex(containing windowFrame: CGRect, screenRects: [CGRect]) -> Int? {
        guard !screenRects.isEmpty else { return nil }
        let overlapAreas = screenRects.map { $0.intersection(windowFrame).area }
        if let largest = overlapAreas.max(), largest > 0 {
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
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return AXWindow(element: unsafeBitCast(value, to: AXUIElement.self))
    }

    private func axWindows(_ appElement: AXUIElement) -> [AXWindow]? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &raw) == .success,
              let list = raw as? [AnyObject] else { return nil }
        return list.compactMap { object in
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return AXWindow(element: unsafeBitCast(object, to: AXUIElement.self))
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

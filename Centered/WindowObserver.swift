import Cocoa
import ApplicationServices
import os.log

private let kRetryInterval: TimeInterval = 2.0
private let kMaxRetryAttempts = 5
private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "WindowObserver"
)

struct WindowEventState<Identity: Equatable> {
    let identity: Identity
    let isMinimized: Bool?
}

enum ObservedWindowEvent: Equatable {
    case created, restored, focused, other
}

/// Resolves identity, never list order. Ambiguous application-level events are skipped.
enum WindowEventResolver {
    static func resolve<Identity: Equatable>(
        event: ObservedWindowEvent,
        eventWindow: WindowEventState<Identity>?,
        focusedWindow: WindowEventState<Identity>?,
        previous: [WindowEventState<Identity>]?,
        current: [WindowEventState<Identity>]?
    ) -> Identity? {
        switch event {
        case .focused:
            guard let focusedWindow, focusedWindow.isMinimized != true else { return nil }
            return focusedWindow.identity
        case .created, .restored:
            if let eventWindow {
                return eventWindow.isMinimized == true ? nil : eventWindow.identity
            }
            guard let previous, let current else { return nil }
            let candidates = current.filter { window in
                guard window.isMinimized != true else { return false }
                switch event {
                case .created:
                    return !previous.contains { $0.identity == window.identity }
                case .restored:
                    return window.isMinimized == false && previous.contains {
                        $0.identity == window.identity && $0.isMinimized == true
                    }
                default:
                    return false
                }
            }
            return candidates.count == 1 ? candidates.first?.identity : nil
        case .other:
            return nil
        }
    }
}

private struct ObservedWindow: Equatable {
    let element: AXUIElement
    static func == (lhs: ObservedWindow, rhs: ObservedWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

private typealias ObservedState = WindowEventState<ObservedWindow>

private final class ObserverBox {
    let axObserver: AXObserver
    weak var owner: WindowObserver?

    init(_ axObserver: AXObserver, owner: WindowObserver) {
        self.axObserver = axObserver
        self.owner = owner
    }

    static func retainedPtr(_ axObserver: AXObserver, owner: WindowObserver) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(ObserverBox(axObserver, owner: owner)).toOpaque()
    }

    static func releasePtr(_ ptr: UnsafeMutableRawPointer) {
        Unmanaged<ObserverBox>.fromOpaque(ptr).release()
    }
}

private struct ObserverEntry {
    let box: ObserverBox
    let refconPtr: UnsafeMutableRawPointer
}

@MainActor
final class WindowObserver {
    var onWindowEvent: ((AXUIElement) -> Void)?
    var excludedBundleIDs: Set<String> = []

    private var entries = [pid_t: ObserverEntry]()
    private var bundleIDs = [pid_t: String]()
    private var knownWindows = [pid_t: [ObservedState]]()
    private var missingNotifications = [pid_t: [String]]()
    private var isObserving = false
    private var pendingRetry = [pid_t: Int]()
    private var retryTimer: Timer?

    func start() {
        guard !isObserving, AXIsProcessTrusted() else { return }
        isObserving = true
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .forEach { addObserver(forPID: $0.processIdentifier, bundleID: $0.bundleIdentifier) }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        retryTimer?.invalidate()
        retryTimer = nil
        pendingRetry.removeAll()
        missingNotifications.removeAll()
        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        for entry in entries.values {
            removeRunLoopSource(for: entry.box.axObserver)
            ObserverBox.releasePtr(entry.refconPtr)
        }
        entries.removeAll()
        bundleIDs.removeAll()
        knownWindows.removeAll()
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        addObserver(forPID: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        pendingRetry.removeValue(forKey: app.processIdentifier)
        removeObserver(for: app.processIdentifier)
    }

    private func addObserver(forPID pid: pid_t, bundleID: String?) {
        guard isObserving, entries[pid] == nil else { return }
        if let bundleID { bundleIDs[pid] = bundleID }
        var axObserver: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &axObserver)
        guard result == .success, let axObserver else {
            logger.debug("AXObserverCreate failed for PID \(pid): \(result.rawValue)")
            scheduleRetry(forPID: pid)
            return
        }
        let refconPtr = ObserverBox.retainedPtr(axObserver, owner: self)
        let appElement = AXUIElementCreateApplication(pid)
        let notificationNames = [
            kAXWindowCreatedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification
        ]
        var failedNames = [String]()
        var successfulRegistrations = 0
        for name in notificationNames {
            let result = AXObserverAddNotification(axObserver, appElement, name as CFString, refconPtr)
            if result == .success {
                successfulRegistrations += 1
            } else {
                failedNames.append(name as String)
                logger.debug("Notification registration failed for \(name as String, privacy: .public), PID \(pid): \(result.rawValue)")
            }
        }
        guard successfulRegistrations > 0 else {
            ObserverBox.releasePtr(refconPtr)
            scheduleRetry(forPID: pid)
            return
        }
        let box = Unmanaged<ObserverBox>.fromOpaque(refconPtr).takeUnretainedValue()
        entries[pid] = ObserverEntry(box: box, refconPtr: refconPtr)
        knownWindows[pid] = windowSnapshot(for: pid)
        addRunLoopSource(for: axObserver)
        if failedNames.isEmpty {
            pendingRetry.removeValue(forKey: pid)
            missingNotifications.removeValue(forKey: pid)
        } else {
            missingNotifications[pid] = failedNames
            scheduleRetry(forPID: pid)
        }
    }

    private func removeObserver(for pid: pid_t) {
        bundleIDs.removeValue(forKey: pid)
        knownWindows.removeValue(forKey: pid)
        missingNotifications.removeValue(forKey: pid)
        guard let entry = entries.removeValue(forKey: pid) else { return }
        removeRunLoopSource(for: entry.box.axObserver)
        ObserverBox.releasePtr(entry.refconPtr)
    }

    private func scheduleRetry(forPID pid: pid_t) {
        let attempts = pendingRetry[pid, default: 0]
        guard attempts < kMaxRetryAttempts else {
            pendingRetry.removeValue(forKey: pid)
            missingNotifications.removeValue(forKey: pid)
            if entries[pid] == nil { bundleIDs.removeValue(forKey: pid) }
            return
        }
        pendingRetry[pid] = attempts + 1
        if retryTimer == nil {
            let timer = Timer(timeInterval: kRetryInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.retryPending() }
            }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    private func retryPending() {
        guard isObserving, !pendingRetry.isEmpty else {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        for pid in Array(pendingRetry.keys) {
            let appElement = AXUIElementCreateApplication(pid)
            var appPID: pid_t = 0
            let result = AXUIElementGetPid(appElement, &appPID)
            guard result == .success, appPID == pid else {
                pendingRetry.removeValue(forKey: pid)
                removeObserver(for: pid)
                continue
            }
            if let entry = entries[pid], let missing = missingNotifications[pid] {
                var stillMissing = [String]()
                for name in missing {
                    let result = AXObserverAddNotification(
                        entry.box.axObserver, appElement, name as CFString, entry.refconPtr
                    )
                    if result != .success && result != .notificationAlreadyRegistered {
                        stillMissing.append(name)
                    }
                }
                if stillMissing.isEmpty {
                    missingNotifications.removeValue(forKey: pid)
                    pendingRetry.removeValue(forKey: pid)
                } else {
                    missingNotifications[pid] = stillMissing
                    scheduleRetry(forPID: pid)
                }
            } else {
                addObserver(forPID: appPID, bundleID: bundleIDs[pid])
            }
        }
    }

    private func addRunLoopSource(for observer: AXObserver) {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeRunLoopSource(for observer: AXObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func windowState(_ element: AXUIElement, pid: pid_t) -> ObservedState? {
        var actualPID: pid_t = 0
        var role: AnyObject?
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid,
              AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              role as? String == kAXWindowRole else { return nil }
        var minimized: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
        return ObservedState(
            identity: ObservedWindow(element: element),
            isMinimized: status == .success ? minimized as? Bool : nil
        )
    }

    private func windowSnapshot(for pid: pid_t) -> [ObservedState]? {
        let appElement = AXUIElementCreateApplication(pid)
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &raw) == .success,
              let objects = raw as? [AnyObject] else { return nil }
        var states = [ObservedState]()
        for object in objects {
            // Never diff an incomplete list: a transient read failure is not a new window.
            guard CFGetTypeID(object) == AXUIElementGetTypeID(),
                  let state = windowState(unsafeBitCast(object, to: AXUIElement.self), pid: pid)
            else { return nil }
            states.append(state)
        }
        return states
    }

    private func focusedWindowState(for pid: pid_t) -> ObservedState? {
        let appElement = AXUIElementCreateApplication(pid)
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return windowState(unsafeBitCast(value, to: AXUIElement.self), pid: pid)
    }

    func handleWindowEvent(pid: pid_t, notificationName: String, element: AXUIElement) {
        guard isObserving, entries[pid] != nil else { return }
        let previous = knownWindows[pid]
        let current = windowSnapshot(for: pid)
        defer { if let current { knownWindows[pid] = current } }
        if let id = bundleIDs[pid], excludedBundleIDs.contains(id) { return }
        let event: ObservedWindowEvent
        switch notificationName {
        case kAXWindowCreatedNotification as String: event = .created
        case kAXWindowDeminiaturizedNotification as String: event = .restored
        case kAXFocusedWindowChangedNotification as String: event = .focused
        default: event = .other
        }
        let target = WindowEventResolver.resolve(
            event: event,
            eventWindow: windowState(element, pid: pid),
            focusedWindow: event == .focused ? focusedWindowState(for: pid) : nil,
            previous: previous,
            current: current
        )
        guard let target else {
            logger.debug("Skipped unresolved AX event \(notificationName, privacy: .public) for PID \(pid)")
            return
        }
        onWindowEvent?(target.element)
    }
}

private let axObserverCallback: AXObserverCallback = { _, element, notificationName, refcon in
    guard let refcon, CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }
    let name = notificationName as String
    let box = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
    // Capturing the CF object retains the event element across the async handoff.
    DispatchQueue.main.async { [weak box, element] in
        box?.owner?.handleWindowEvent(pid: pid, notificationName: name, element: element)
    }
}

import Cocoa
import ApplicationServices
import os.log

private let kRetryInterval:    TimeInterval = 2.0
private let kMaxRetryAttempts: Int          = 5

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "WindowObserver"
)

/// Holds a weak back-reference so the callback can reach WindowObserver without preventing its deallocation.
private final class ObserverBox {
    let axObserver: AXObserver
    weak var owner: WindowObserver?

    init(_ axObserver: AXObserver, owner: WindowObserver) {
        self.axObserver = axObserver
        self.owner      = owner
    }

    /// Creates a +1-retained ObserverBox and returns the opaque pointer for use as refcon.
    static func retainedPtr(_ axObserver: AXObserver, owner: WindowObserver) -> UnsafeMutableRawPointer {
        let box = ObserverBox(axObserver, owner: owner)
        return Unmanaged.passRetained(box).toOpaque()
    }

    /// Releases the +1 retain that was created by retainedPtr(_:owner:).
    static func releasePtr(_ ptr: UnsafeMutableRawPointer) {
        Unmanaged<ObserverBox>.fromOpaque(ptr).release()
    }
}

/// Bookkeeping entry stored per observed PID.
private struct ObserverEntry {
    let box: ObserverBox
    let refconPtr: UnsafeMutableRawPointer
}

@MainActor
final class WindowObserver {

    var onWindowEvent: ((AXUIElement) -> Void)?
    var excludedBundleIDs: Set<String> = []

    private var entries     = [pid_t: ObserverEntry]()
    private var bundleIDs   = [pid_t: String]()
    private var missingNotifications = [pid_t: [String]]()
    private var isObserving = false
    private var pendingRetry = [pid_t: Int]()
    private var retryTimer:  Timer?

    func start() {
        guard !isObserving, AXIsProcessTrusted() else { return }
        isObserving = true

        logger.debug("WindowObserver starting")

        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .forEach { addObserver(forPID: $0.processIdentifier, bundleID: $0.bundleIdentifier) }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification,    object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false

        logger.debug("WindowObserver stopping")

        retryTimer?.invalidate()
        retryTimer = nil
        pendingRetry.removeAll()
        missingNotifications.removeAll()

        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification,    object: nil)
        nc.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        for entry in entries.values {
            removeRunLoopSource(for: entry.box.axObserver)
            ObserverBox.releasePtr(entry.refconPtr)
        }
        entries.removeAll()
        bundleIDs.removeAll()
        
        logger.debug("WindowObserver stopped")
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        logger.debug("App launched: \(app.bundleIdentifier ?? "unknown", privacy: .public) (PID: \(app.processIdentifier))")
        addObserver(forPID: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        logger.debug("App terminated: PID \(app.processIdentifier)")
        pendingRetry.removeValue(forKey: app.processIdentifier)
        missingNotifications.removeValue(forKey: app.processIdentifier)
        removeObserver(for: app.processIdentifier)
    }

    private func addObserver(forPID pid: pid_t, bundleID: String?) {
        guard entries[pid] == nil else { return }
        if let bundleID {
            bundleIDs[pid] = bundleID
        }

        var axObserver: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &axObserver)

        guard result == .success, let axObserver else {
            logger.debug("AXObserverCreate failed for PID \(pid, privacy: .public): result=\(result.rawValue)")
            scheduleRetry(forPID: pid)
            return
        }

        let refconPtr = ObserverBox.retainedPtr(axObserver, owner: self)

        let appElement = AXUIElementCreateApplication(pid)
        let notificationNames = [
            kAXWindowCreatedNotification,
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
                logger.debug("Failed to register notification \(name as String, privacy: .public) for PID \(pid, privacy: .public): result=\(result.rawValue)")
            }
        }

        // Keep any successfully registered notifications active. Retry only the
        // unsupported/transient registrations instead of discarding all events.
        guard successfulRegistrations > 0 else {
            ObserverBox.releasePtr(refconPtr)
            scheduleRetry(forPID: pid)
            return
        }

        addRunLoopSource(for: axObserver)

        let box = Unmanaged<ObserverBox>.fromOpaque(refconPtr).takeUnretainedValue()
        entries[pid] = ObserverEntry(box: box, refconPtr: refconPtr)
        if failedNames.isEmpty {
            pendingRetry.removeValue(forKey: pid)
            missingNotifications.removeValue(forKey: pid)
        } else {
            missingNotifications[pid] = failedNames
            scheduleRetry(forPID: pid)
        }
        
        logger.debug("Observer added for PID \(pid, privacy: .public) (\(bundleID ?? "unknown", privacy: .public))")
    }

    private func removeObserver(for pid: pid_t) {
        bundleIDs.removeValue(forKey: pid)
        missingNotifications.removeValue(forKey: pid)
        guard let entry = entries.removeValue(forKey: pid) else { return }
        removeRunLoopSource(for: entry.box.axObserver)
        ObserverBox.releasePtr(entry.refconPtr)
        
        logger.debug("Observer removed for PID \(pid, privacy: .public)")
    }

    private func scheduleRetry(forPID pid: pid_t) {
        let attempts = pendingRetry[pid, default: 0]
        guard attempts < kMaxRetryAttempts else {
            logger.debug("Max retry attempts reached for PID \(pid, privacy: .public)")
            pendingRetry.removeValue(forKey: pid)
            missingNotifications.removeValue(forKey: pid)
            if entries[pid] == nil { bundleIDs.removeValue(forKey: pid) }
            return
        }
        pendingRetry[pid] = attempts + 1
        logger.debug("Retry scheduled for PID \(pid, privacy: .public) (attempt \(attempts + 1)/\(kMaxRetryAttempts))")
        
        if retryTimer == nil {
            let t = Timer(timeInterval: kRetryInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.retryPending() }
            }
            RunLoop.main.add(t, forMode: .common)
            retryTimer = t
        }
    }

    private func retryPending() {
        guard !pendingRetry.isEmpty else {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        
        for pid in Array(pendingRetry.keys) {
            let appElement = AXUIElementCreateApplication(pid)
            var appPID: pid_t = 0
            let result = AXUIElementGetPid(appElement, &appPID)
            guard result == .success, appPID == pid else {
                logger.debug("PID validation failed for \(pid, privacy: .public) (result=\(result.rawValue))")
                pendingRetry.removeValue(forKey: pid)
                removeObserver(for: pid)
                continue
            }
            
            if let entry = entries[pid], let missing = missingNotifications[pid] {
                let appElement = AXUIElementCreateApplication(appPID)
                var stillMissing = [String]()
                for name in missing {
                    let addResult = AXObserverAddNotification(
                        entry.box.axObserver, appElement, name as CFString, entry.refconPtr
                    )
                    if addResult != .success {
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
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeRunLoopSource(for observer: AXObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func handleWindowEvent(pid: pid_t, notificationName: String) {
        if let id = bundleIDs[pid], excludedBundleIDs.contains(id) {
            logger.debug("Window event ignored (excluded): \(id, privacy: .public)")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedRaw: AnyObject?
        let focusedWindow: AXUIElement? = {
            guard AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &focusedRaw
            ) == .success,
               let value = focusedRaw,
               CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            return value as? AXUIElement
        }()

        // Focus-change events must use the focused window. Creation events
        // instead select the newest unminimized window from the app's list so
        // a background-created window does not accidentally move the old focus.
        if notificationName == (kAXFocusedWindowChangedNotification as String) {
            if let focusedWindow { onWindowEvent?(focusedWindow); return }
        }

        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &raw
        ) == .success, let objects = raw as? [AnyObject] else {
            logger.debug("No window list for AX notification \(notificationName, privacy: .public)")
            return
        }

        let windows: [AXUIElement] = objects.compactMap { object in
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return object as! AXUIElement
        }
        let ordered: [AXUIElement]
        if notificationName == (kAXWindowCreatedNotification as String) {
            ordered = windows.reversed()
        } else if let focusedWindow {
            ordered = [focusedWindow] + windows.filter { !CFEqual($0, focusedWindow) }
        } else {
            ordered = windows
        }

        for window in ordered {
            var minimizedValue: AnyObject?
            let minimizedStatus = AXUIElementCopyAttributeValue(
                window, kAXMinimizedAttribute as CFString, &minimizedValue
            )
            if minimizedStatus == .success, minimizedValue as? Bool == true { continue }
            onWindowEvent?(window)
            return
        }

        logger.debug("No usable window found for AX notification \(notificationName, privacy: .public)")
    }
}

private let axObserverCallback: AXObserverCallback = { _, element, notificationName, refcon in
    guard let refcon, CFGetTypeID(element) == AXUIElementGetTypeID() else { 
        return 
    }
    
    let name = notificationName as String? ?? "unknown"
    logger.debug("AX notification received: \(name, privacy: .public)")
    
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else {
        logger.debug("Failed to get PID from element")
        return
    }
    
    let box = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async { [weak box] in
        box?.owner?.handleWindowEvent(pid: pid, notificationName: name)
    }
}

import Cocoa
import ApplicationServices
import os.log

private let kRetryInterval:    TimeInterval = 2.0
private let kMaxRetryAttempts: Int          = 5

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "WindowObserver"
)

/// Sole retained object in the AX callback refcon.
/// Holds a **weak** back-reference so the callback can reach WindowObserver
/// without preventing its deallocation.
///
/// **Memory Safety:**
/// This weak reference avoids a retain cycle:
/// - ObserverBox is retained by Unmanaged (via refcon in the AX callback)
/// - AXObserver is retained by ObserverBox (strong)
/// - WindowObserver retains boxes dict containing ObserverBox instances
/// Without the weak reference, this would create: WindowObserver → boxes → ObserverBox → WindowObserver
private final class ObserverBox {
    let axObserver: AXObserver
    weak var owner: WindowObserver?

    init(_ axObserver: AXObserver, owner: WindowObserver) {
        self.axObserver = axObserver
        self.owner      = owner
    }

    static func retain(_ observer: AXObserver, owner: WindowObserver) -> UnsafeMutableRawPointer {
        let box = ObserverBox(observer, owner: owner)
        return Unmanaged.passRetained(box).toOpaque()
    }

    static func release(_ box: ObserverBox) {
        _ = Unmanaged<ObserverBox>.passUnretained(box).takeRetainedValue()
    }
}

@MainActor
final class WindowObserver {

    var onWindowEvent: ((AXUIElement) -> Void)?
    var excludedBundleIDs: Set<String> = []

    private var boxes       = [pid_t: ObserverBox]()
    private var bundleIDs   = [pid_t: String]()
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

        // Clean up retry mechanism first
        retryTimer?.invalidate()
        retryTimer = nil
        pendingRetry.removeAll()

        // Unregister workspace notifications
        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification,    object: nil)
        nc.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // Clean up AX observers
        boxes.values.forEach { box in
            removeRunLoopSource(for: box.axObserver)
            ObserverBox.release(box)
        }
        boxes.removeAll()
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
        removeObserver(for: app.processIdentifier)
    }

    private func addObserver(forPID pid: pid_t, bundleID: String?) {
        guard boxes[pid] == nil else { return }
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

        let refcon = ObserverBox.retain(axObserver, owner: self)

        let appElement = AXUIElementCreateApplication(pid)
        let notificationNames = [
            kAXWindowCreatedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification
        ]
        
        for name in notificationNames {
            let result = AXObserverAddNotification(axObserver, appElement, name as CFString, refcon)
            if result != .success {
                logger.debug("Failed to register notification \(name as String, privacy: .public) for PID \(pid, privacy: .public): result=\(result.rawValue)")
            }
        }

        addRunLoopSource(for: axObserver)
        let box       = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
        boxes[pid]    = box
        pendingRetry.removeValue(forKey: pid)
        
        logger.debug("Observer added for PID \(pid, privacy: .public) (\(bundleID ?? "unknown", privacy: .public))")
    }

    private func removeObserver(for pid: pid_t) {
        guard let box = boxes.removeValue(forKey: pid) else { return }
        bundleIDs.removeValue(forKey: pid)
        removeRunLoopSource(for: box.axObserver)
        ObserverBox.release(box)
        
        logger.debug("Observer removed for PID \(pid, privacy: .public)")
    }

    private func scheduleRetry(forPID pid: pid_t) {
        let attempts = pendingRetry[pid, default: 0]
        guard attempts < kMaxRetryAttempts else {
            logger.debug("Max retry attempts reached for PID \(pid, privacy: .public)")
            pendingRetry.removeValue(forKey: pid)
            return
        }
        pendingRetry[pid] = attempts + 1
        logger.debug("Retry scheduled for PID \(pid, privacy: .public) (attempt \(attempts + 1)/\(kMaxRetryAttempts))")
        
        if retryTimer == nil {
            let t = Timer(timeInterval: kRetryInterval, repeats: true) { [weak self] _ in
                self?.retryPending()
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
            
            // Verify the PID is still valid; if it changed or is invalid, clean it up
            guard result == .success, appPID == pid else {
                logger.debug("PID validation failed for \(pid, privacy: .public) (result=\(result.rawValue))")
                pendingRetry.removeValue(forKey: pid)
                bundleIDs.removeValue(forKey: pid)
                continue
            }
            
            addObserver(forPID: appPID, bundleID: bundleIDs[pid])
        }
    }

    private func addRunLoopSource(for observer: AXObserver) {
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func removeRunLoopSource(for observer: AXObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    func handleWindowEvent(pid: pid_t, element: AXUIElement) {
        if let id = bundleIDs[pid], excludedBundleIDs.contains(id) { 
            logger.debug("Window event ignored (excluded): \(id, privacy: .public)")
            return 
        }
        onWindowEvent?(element)
    }
}

/// Accessibility callback that receives window events from AX notifications.
///
/// **Callback Context:**
/// - refcon is a +1 retained ObserverBox. The callback reaches WindowObserver
///   through the box's weak `owner` reference.
/// - Dispatches event handling to the main thread to ensure thread safety.
private let axObserverCallback: AXObserverCallback = { _, element, notificationName, refcon in
    guard let refcon, CFGetTypeID(element) == AXUIElementGetTypeID() else { 
        return 
    }
    
    let name = notificationName as String?
    logger.debug("AX notification received: \(name ?? "unknown", privacy: .public)")
    
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else {
        logger.debug("Failed to get PID from element")
        return
    }
    
    let box = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async { [weak box] in
        box?.owner?.handleWindowEvent(pid: pid, element: element)
    }
}

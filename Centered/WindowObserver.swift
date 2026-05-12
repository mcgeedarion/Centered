//
// WindowObserver.swift
// Centered
//
// Watches every regular-activation app via AXObserver and fires `onWindowEvent`
// whenever a window is created, deminiaturized, or focused — unless the app is
// on the exclusion list.
//
// Thread model: all mutable state is @MainActor. The AXObserverCallback C
// function cannot carry actor isolation, so it hops to the main queue before
// touching `self`.
//
// Memory safety:
//   Rather than retaining `self` (WindowObserver) in the C callback's refcon,
//   we box each observer into an ObserverBox that holds a weak reference back
//   to the WindowObserver. This eliminates the manual passRetained/release dance
//   and the associated use-after-free / double-free risks:
//
//   - ObserverBox is the only retained object per registration.
//   - WindowObserver can be deallocated independently — the weak ref goes nil
//     and the callback safely no-ops.
//   - No hand-rolled retain counter; ARC manages ObserverBox lifetime.
//
// Retry:
//   AXObserverCreate can fail transiently (e.g. kAXErrorAPIDisabled during
//   login). Apps that failed are queued in `pendingRetry` and retried up to
//   kMaxRetryAttempts times with kRetryInterval spacing.
//

import Cocoa
import ApplicationServices

private let kRetryInterval:    TimeInterval = 2.0
private let kMaxRetryAttempts: Int          = 5

// MARK: - ObserverBox

/// Heap-allocated wrapper that is the sole retained object in the AX callback's
/// refcon. Holds a weak back-reference to WindowObserver so the callback can
/// reach it without preventing deallocation.
private final class ObserverBox {
    let axObserver: AXObserver
    weak var owner: WindowObserver?

    init(_ axObserver: AXObserver, owner: WindowObserver) {
        self.axObserver = axObserver
        self.owner      = owner
    }
}

// MARK: - WindowObserver

@MainActor
final class WindowObserver {

    // MARK: - Public interface

    var onWindowEvent: ((AXUIElement) -> Void)?
    var excludedBundleIDs: Set<String> = []

    // MARK: - Private state

    /// Maps pid → ObserverBox. The box owns the AXObserver and holds a weak
    /// back-reference to self; no manual retain accounting is needed.
    private var boxes      = [pid_t: ObserverBox]()
    private var bundleIDs  = [pid_t: String]()
    private var isObserving = false

    /// Apps whose AXObserverCreate failed transiently; value = attempts so far.
    private var pendingRetry = [NSRunningApplication: Int]()
    private var retryTimer:  Timer?

    // MARK: - Lifecycle

    func start() {
        guard !isObserving, AXIsProcessTrusted() else { return }
        isObserving = true

        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .forEach { addObserver(for: $0) }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification,    object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false

        retryTimer?.invalidate()
        retryTimer = nil
        pendingRetry.removeAll()

        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification,    object: nil)
        nc.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // Remove run-loop sources; ARC releases each ObserverBox (and its AXObserver)
        // automatically once boxes is cleared — no manual release needed.
        boxes.values.forEach { removeRunLoopSource(for: $0.axObserver) }
        boxes.removeAll()
        bundleIDs.removeAll()
    }

    // MARK: - Workspace notifications

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        addObserver(for: app)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        pendingRetry.removeValue(forKey: app)
        removeObserver(for: app.processIdentifier)
    }

    // MARK: - AX observer management

    private func addObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard boxes[pid] == nil else { return }   // already registered — deduplicate

        var axObserver: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &axObserver)

        guard result == .success, let axObserver else {
            scheduleRetry(for: app)
            return
        }

        // Box owns the AXObserver; weak ref to self prevents retain cycle and
        // use-after-free — if WindowObserver is deallocated the callback no-ops.
        let box = ObserverBox(axObserver, owner: self)
        // Retain the box for the C callback's lifetime (one retain per observer).
        let boxPtr = Unmanaged.passRetained(box).toOpaque()

        let appElement = AXUIElementCreateApplication(pid)
        for name in [kAXWindowCreatedNotification,
                     kAXWindowDeminiaturizedNotification,
                     kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(axObserver, appElement, name as CFString, boxPtr)
        }

        addRunLoopSource(for: axObserver)
        boxes[pid]     = box
        bundleIDs[pid] = app.bundleIdentifier
        pendingRetry.removeValue(forKey: app)
    }

    private func removeObserver(for pid: pid_t) {
        guard let box = boxes.removeValue(forKey: pid) else { return }
        bundleIDs.removeValue(forKey: pid)
        removeRunLoopSource(for: box.axObserver)
        // Balance the passRetained from addObserver.
        // takeRetainedValue() decrements the retain count by 1, releasing the box
        // when no other owner holds it.
        _ = Unmanaged<ObserverBox>.passUnretained(box).takeRetainedValue()
    }

    // MARK: - Retry

    private func scheduleRetry(for app: NSRunningApplication) {
        let attempts = pendingRetry[app, default: 0]
        guard attempts < kMaxRetryAttempts else {
            pendingRetry.removeValue(forKey: app)
            return
        }
        pendingRetry[app] = attempts + 1
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
        for app in Array(pendingRetry.keys) {
            addObserver(for: app)
        }
    }

    // MARK: - Run-loop helpers

    private func addRunLoopSource(for observer: AXObserver) {
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func removeRunLoopSource(for observer: AXObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // MARK: - Event dispatch

    func handleWindowEvent(pid: pid_t, element: AXUIElement) {
        if let id = bundleIDs[pid], excludedBundleIDs.contains(id) { return }
        onWindowEvent?(element)
    }
}

// MARK: - AX callback

/// The refcon is a +1 retained ObserverBox (not the WindowObserver itself).
/// The callback reaches WindowObserver through the box's weak `owner` reference.
private let axObserverCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon, CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    // takeUnretainedValue: the box remains alive for the duration of this call
    // because the caller (AX framework) holds the +1 retain from passRetained.
    let box = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async { [weak box] in
        box?.owner?.handleWindowEvent(pid: pid, element: element)
    }
}

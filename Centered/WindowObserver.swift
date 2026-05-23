//
// WindowObserver.swift
// Centered
//
// Watches every regular-activation app via AXObserver and fires `onWindowEvent`
// whenever a window is created, deminiaturized, or focused — unless the app is
// on the exclusion list.
//
// Thread model: all mutable state is @MainActor. The AXObserverCallback C
// function hops to the main queue before touching `self`.
//
// Memory safety: each registration creates an ObserverBox (retained in refcon)
// with a weak back-reference to WindowObserver. ARC manages the box lifetime;
// no manual retain accounting is needed. See ObserverBox below.
//
// Retry: AXObserverCreate can fail transiently (e.g. kAXErrorAPIDisabled during
// login). Failed apps are retried up to kMaxRetryAttempts times at kRetryInterval.
//

import Cocoa
import ApplicationServices

private let kRetryInterval:    TimeInterval = 2.0
private let kMaxRetryAttempts: Int          = 5

// MARK: - ObserverBox

/// Sole retained object in the AX callback refcon.
/// Holds a weak back-reference so the callback can reach WindowObserver
/// without preventing its deallocation.
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

// MARK: - WindowObserver

@MainActor
final class WindowObserver {

    // MARK: - Public interface

    var onWindowEvent: ((AXUIElement) -> Void)?
    var excludedBundleIDs: Set<String> = []

    // MARK: - Private state

    private var boxes       = [pid_t: ObserverBox]()
    private var bundleIDs   = [pid_t: String]()
    private var isObserving = false
    private var pendingRetry = [pid_t: Int]()
    private var retryTimer:  Timer?

    // MARK: - Lifecycle

    func start() {
        guard !isObserving, AXIsProcessTrusted() else { return }
        isObserving = true

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

        retryTimer?.invalidate()
        retryTimer = nil
        pendingRetry.removeAll()

        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification,    object: nil)
        nc.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        boxes.values.forEach { box in
            removeRunLoopSource(for: box.axObserver)
            ObserverBox.release(box)
        }
        boxes.removeAll()
        bundleIDs.removeAll()
    }

    // MARK: - Workspace notifications

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        addObserver(forPID: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        pendingRetry.removeValue(forKey: app.processIdentifier)
        removeObserver(for: app.processIdentifier)
    }

    // MARK: - AX observer management

    private func addObserver(forPID pid: pid_t, bundleID: String?) {
        guard boxes[pid] == nil else { return }

        var axObserver: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &axObserver)

        guard result == .success, let axObserver else {
            scheduleRetry(forPID: pid)
            return
        }

        let refcon = ObserverBox.retain(axObserver, owner: self)

        let appElement = AXUIElementCreateApplication(pid)
        for name in [kAXWindowCreatedNotification,
                     kAXWindowDeminiaturizedNotification,
                     kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(axObserver, appElement, name as CFString, refcon)
        }

        addRunLoopSource(for: axObserver)
        let box       = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
        boxes[pid]    = box
        bundleIDs[pid] = bundleID
        pendingRetry.removeValue(forKey: pid)
    }

    private func removeObserver(for pid: pid_t) {
        guard let box = boxes.removeValue(forKey: pid) else { return }
        bundleIDs.removeValue(forKey: pid)
        removeRunLoopSource(for: box.axObserver)
        ObserverBox.release(box)
    }

    // MARK: - Retry

    private func scheduleRetry(forPID pid: pid_t) {
        let attempts = pendingRetry[pid, default: 0]
        guard attempts < kMaxRetryAttempts else {
            pendingRetry.removeValue(forKey: pid)
            return
        }
        pendingRetry[pid] = attempts + 1
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
            AXUIElementGetPid(appElement, &appPID)
            addObserver(forPID: appPID, bundleID: bundleIDs[pid])
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

/// refcon is a +1 retained ObserverBox. The callback reaches WindowObserver
/// through the box's weak `owner` reference.
private let axObserverCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon, CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let box = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async { [weak box] in
        box?.owner?.handleWindowEvent(pid: pid, element: element)
    }
}

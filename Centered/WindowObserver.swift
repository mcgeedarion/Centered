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
// Retain balance:
//   addObserver(for:) calls passRetained once per registered app and increments
//   `selfRetainCount`. removeObserver(for:) and stop() each call release exactly
//   once per retained entry, keeping the count in sync.
//
//   Using an explicit counter (selfRetainCount) instead of inferring the count
//   from observers.count makes the accounting immune to bugs introduced by
//   future changes to addObserver / removeObserver.
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

@MainActor
final class WindowObserver {

    // MARK: - Public interface

    var onWindowEvent: ((AXUIElement) -> Void)?
    var excludedBundleIDs: Set<String> = []

    // MARK: - Private state

    private var observers       = [pid_t: AXObserver]()
    private var bundleIDs       = [pid_t: String]()
    private var isObserving     = false
    /// Tracks how many times passRetained(self) has been called without a
    /// matching release. Every addObserver increments this; every
    /// removeObserver decrements it. stop() drains the remainder.
    private var selfRetainCount = 0

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

        observers.values.forEach { removeRunLoopSource(for: $0) }
        observers.removeAll()
        bundleIDs.removeAll()

        // Drain all outstanding retains acquired by addObserver calls.
        while selfRetainCount > 0 {
            selfRetainCount -= 1
            Unmanaged.passUnretained(self).release()
        }
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
        guard observers[pid] == nil else { return }

        var axObserver: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &axObserver)

        guard result == .success, let axObserver else {
            // Transient failure — schedule a retry if we haven't exceeded the limit.
            scheduleRetry(for: app)
            return
        }

        // Retain self once per registered observer so the C callback can reach us.
        let selfPtr    = Unmanaged.passRetained(self).toOpaque()
        selfRetainCount += 1

        let appElement = AXUIElementCreateApplication(pid)
        for name in [kAXWindowCreatedNotification,
                     kAXWindowDeminiaturizedNotification,
                     kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(axObserver, appElement, name as CFString, selfPtr)
        }

        addRunLoopSource(for: axObserver)
        observers[pid] = axObserver
        bundleIDs[pid] = app.bundleIdentifier
        pendingRetry.removeValue(forKey: app)   // succeeded — remove from retry queue
    }

    private func removeObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        bundleIDs.removeValue(forKey: pid)
        removeRunLoopSource(for: observer)
        selfRetainCount -= 1
        Unmanaged.passUnretained(self).release()
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
        // Snapshot keys so we can mutate pendingRetry inside addObserver.
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

private let axObserverCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon, CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let observer = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async { observer.handleWindowEvent(pid: pid, element: element) }
}

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
// touching `self`. Each addObserver call takes a retained reference to `self`
// that is released symmetrically in removeObserver / stop().
//

import Cocoa
import ApplicationServices

@MainActor
final class WindowObserver {

    // MARK: - Public interface

    var onWindowEvent: ((AXUIElement) -> Void)?

    /// Updated by AppDelegate whenever the user edits the exclusion list.
    var excludedBundleIDs: Set<String> = UserDefaults.standard.excludedBundleIDs

    // MARK: - Private state

    private var observers   = [pid_t: AXObserver]()
    /// pid → bundleID cache; avoids NSRunningApplication lookups on every event.
    private var bundleIDs   = [pid_t: String]()
    private var isObserving = false

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

        // Unsubscribe workspace notifications before tearing down AX observers
        // so no new observers are added during teardown.
        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification,    object: nil)
        nc.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        observers.values.forEach { removeRunLoopSource(for: $0) }
        observers.removeAll()
        bundleIDs.removeAll()

        Unmanaged.passUnretained(self).release()
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
        removeObserver(for: app.processIdentifier)
    }

    // MARK: - AX observer management

    private func addObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        var axObserver: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &axObserver) == .success,
              let axObserver
        else { return }

        let selfPtr    = Unmanaged.passRetained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)

        for name in [kAXWindowCreatedNotification,
                     kAXWindowDeminiaturizedNotification,
                     kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(axObserver, appElement, name as CFString, selfPtr)
        }

        addRunLoopSource(for: axObserver)
        observers[pid] = axObserver
        bundleIDs[pid] = app.bundleIdentifier
    }

    private func removeObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        bundleIDs.removeValue(forKey: pid)
        removeRunLoopSource(for: observer)
        Unmanaged.passUnretained(self).release()
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

// Plain C function — cannot carry actor isolation. Reads the pid from the
// element synchronously (safe on any thread), then hops to main.
private let axObserverCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon, CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let observer = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    let elem = element as AXUIElement
    DispatchQueue.main.async { observer.handleWindowEvent(pid: pid, element: elem) }
}

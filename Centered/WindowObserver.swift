//
// WindowObserver.swift
// Centered
//
// Watches every regular-activation app via AXObserver and calls the provided
// callback whenever a window is created, deminiaturized, or focused.
// AppDelegate owns one instance and starts/stops it as the app is enabled.
//
// @MainActor: all mutable state lives on the main actor.  The AXObserverCallback
// C closure cannot be @MainActor directly, so it hops back to main via
// DispatchQueue.main.async before touching `self`.
//

import Cocoa
import ApplicationServices

@MainActor
final class WindowObserver {

    var onWindowEvent: ((AXUIElement) -> Void)?

    // MARK: - Private state
    // Plain stored properties — @MainActor serialises all access.
    // No concurrent queue, no barrier writes, no double-checked locking needed.

    private var observers   = [pid_t: AXObserver]()
    private var isObserving = false

    // MARK: - Lifecycle

    func start() {
        guard !isObserving, AXIsProcessTrusted() else { return }
        isObserving = true

        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .forEach { addObserver(for: $0) }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched),
                       name: NSWorkspace.didLaunchApplicationNotification,  object: nil)
        nc.addObserver(self, selector: #selector(appTerminated),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false

        // Remove workspace observers first so no new AX observers are added
        // while we are tearing down.
        let nc = NSWorkspace.shared.notificationCenter
        nc.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification,   object: nil)
        nc.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        observers.values.forEach { removeRunLoopSource(for: $0) }
        observers.removeAll()
    }

    // MARK: - NSWorkspace notifications

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        addObserver(for: app)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        removeObserver(for: app.processIdentifier)
    }

    // MARK: - AX observer management

    private func addObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        var axObserver: AXObserver?
        guard AXObserverCreate(pid, observerCallback, &axObserver) == .success,
              let axObserver else { return }

        let selfPtr    = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)

        for notifName in [kAXWindowCreatedNotification,
                          kAXWindowDeminiaturizedNotification,
                          kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(axObserver, appElement, notifName as CFString, selfPtr)
        }
        addRunLoopSource(for: axObserver)
        observers[pid] = axObserver
    }

    private func removeObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        removeRunLoopSource(for: observer)
    }

    // MARK: - Run-loop source helpers

    private func addRunLoopSource(for observer: AXObserver) {
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)
    }

    private func removeRunLoopSource(for observer: AXObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer),
                              .defaultMode)
    }

    // MARK: - AX callback entry point

    func handleWindowEvent(_ element: AXUIElement) {
        onWindowEvent?(element)
    }
}

// The AXObserverCallback is a plain C function pointer — it cannot carry
// actor isolation.  It hops to the main actor before touching WindowObserver.
private let observerCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon,
          CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
    let observer = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    let elem     = element as AXUIElement
    DispatchQueue.main.async {
        observer.handleWindowEvent(elem)
    }
}

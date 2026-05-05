//
// WindowObserver.swift
// Centered
//
// Watches every regular-activation app via AXObserver and calls the provided
// callback whenever a window is created, deminiaturized, or focused.
// AppDelegate owns one instance and starts/stops it as the app is enabled.
//

import Cocoa
import ApplicationServices

final class WindowObserver {

    // Called on the main run loop whenever a relevant AX window event fires.
    var onWindowEvent: ((AXUIElement) -> Void)?

    // MARK: - Private state

    private let queue = DispatchQueue(
        label: "com.example.Centered.observers",
        attributes: .concurrent
    )
    private var _observers    = [pid_t: AXObserver]()
    // isObserving is guarded by the same concurrent queue via barrier writes
    // so start()/stop() calls from any thread are safe.
    private var _isObserving  = false

    // MARK: - Lifecycle

    /// Begin watching all currently-running apps and listen for future launches.
    /// Safe to call repeatedly; subsequent calls while already observing are no-ops.
    func start() {
        // Barrier write: atomically check-and-set _isObserving.
        var shouldStart = false
        queue.sync(flags: .barrier) {
            guard !_isObserving, AXIsProcessTrusted() else { return }
            _isObserving = true
            shouldStart  = true
        }
        guard shouldStart else { return }

        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .forEach { addObserver(for: $0) }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
    }

    /// Stop watching all apps and remove all AX observers.
    /// Safe to call repeatedly; calls while already stopped are no-ops.
    /// After stop() returns, start() can be called again cleanly.
    func stop() {
        var shouldStop = false
        queue.sync(flags: .barrier) {
            guard _isObserving else { return }
            _isObserving = false
            shouldStop   = true
        }
        guard shouldStop else { return }

        // Remove NSWorkspace observers first so no new AX observers are added
        // while we are tearing down.
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )

        queue.sync(flags: .barrier) {
            for observer in _observers.values {
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(observer),
                    .defaultMode
                )
            }
            _observers.removeAll()
        }
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

        // Fast read-path: bail immediately if we already have an observer.
        let alreadyTracked: Bool = queue.sync { _observers[pid] != nil }
        guard !alreadyTracked else { return }

        // Do all slow AX work outside the lock.
        var axObserver: AXObserver?
        guard AXObserverCreate(pid, observerCallback, &axObserver) == .success,
              let axObserver = axObserver else { return }

        let selfPtr    = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)

        for notifName in [
            kAXWindowCreatedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification
        ] {
            AXObserverAddNotification(axObserver, appElement,
                                      notifName as CFString, selfPtr)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(axObserver),
            .defaultMode
        )

        // Barrier write only for the dictionary update.
        queue.sync(flags: .barrier) {
            // Double-check: another call may have raced us.
            guard _observers[pid] == nil else {
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(axObserver),
                    .defaultMode
                )
                return
            }
            _observers[pid] = axObserver
        }
    }

    private func removeObserver(for pid: pid_t) {
        queue.sync(flags: .barrier) {
            guard let observer = _observers.removeValue(forKey: pid) else { return }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
    }

    // MARK: - AX callback

    func handleWindowEvent(_ element: AXUIElement) {
        onWindowEvent?(element)
    }
}

// The AXObserverCallback must be a C function (or a global/static closure).
// We store a raw pointer to the WindowObserver in the `refcon` field.
private let observerCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon = refcon,
          CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
    Unmanaged<WindowObserver>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .handleWindowEvent(element as AXUIElement)
}

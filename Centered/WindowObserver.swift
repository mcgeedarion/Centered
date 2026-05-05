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

    var onWindowEvent: ((AXUIElement) -> Void)?

    // MARK: - Private state

    private let queue = DispatchQueue(
        label: "com.example.Centered.observers",
        attributes: .concurrent
    )
    private var _observers   = [pid_t: AXObserver]()
    private var _isObserving = false

    // MARK: - Lifecycle

    func start() {
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

    func stop() {
        var shouldStop = false
        queue.sync(flags: .barrier) {
            guard _isObserving else { return }
            _isObserving = false
            shouldStop   = true
        }
        guard shouldStop else { return }

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

        let alreadyTracked: Bool = queue.sync { _observers[pid] != nil }
        guard !alreadyTracked else { return }

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

        queue.sync(flags: .barrier) {
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

    func handleWindowEvent(_ element: AXUIElement) {
        onWindowEvent?(element)
    }
}

private let observerCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon = refcon,
          CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
    Unmanaged<WindowObserver>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .handleWindowEvent(element as AXUIElement)
}

//
// HotKey.swift
// Centered
//
// Created by Darion McGee on 7/22/25.
//
// A lightweight global + local keyboard-shortcut monitor built on NSEvent.
//

import Cocoa
import Carbon.HIToolbox

final class HotKey {

    // MARK: - Types

    enum Key: UInt16 {
        /// Physical key for "C" on all keyboard layouts (kVK_ANSI_C = 8).
        case c = 8
    }

    // MARK: - Properties

    let key: Key
    let modifiers: NSEvent.ModifierFlags
    var keyDownHandler: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor:  Any?

    // MARK: - Init

    init(key: Key, modifiers: NSEvent.ModifierFlags, handler: (() -> Void)? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.keyDownHandler = handler
    }

    // MARK: - Activation

    func activate() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == self.modifiers,
                  event.keyCode == UInt16(kVK_ANSI_C)
            else { return }
            self.keyDownHandler?()
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor  = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event); return event
        }
    }

    func deactivate() {
        removeMonitor(&globalMonitor)
        removeMonitor(&localMonitor)
    }

    deinit { deactivate() }

    // MARK: - Helpers

    private func removeMonitor(_ monitor: inout Any?) {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
    }
}

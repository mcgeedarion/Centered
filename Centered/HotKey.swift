//
// HotKey.swift
// Centered
//
// A lightweight global + local keyboard-shortcut monitor built on NSEvent.
// Supports any key+modifier combination and can be rebound at runtime without
// deallocation via rebind(keyCode:modifiers:).
//

import Cocoa
import Carbon.HIToolbox

// MARK: - HotKeyBinding

/// A serialisable key+modifier pair stored in UserDefaults.
struct HotKeyBinding: Equatable {
    /// The Carbon virtual key code (e.g. kVK_ANSI_C = 8).
    var keyCode:   UInt16
    /// Device-independent modifier flags (command, option, shift, control).
    var modifiers: NSEvent.ModifierFlags

    // MARK: Defaults
    static let centerActive  = HotKeyBinding(keyCode: UInt16(kVK_ANSI_C),
                                              modifiers: [.command, .option])
    static let centerAll     = HotKeyBinding(keyCode: UInt16(kVK_ANSI_C),
                                              modifiers: [.command, .shift])

    // MARK: UserDefaults round-trip
    /// Encodes as ["keyCode": Int, "modifiers": UInt].
    var dictionaryRepresentation: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": modifiers.rawValue]
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode   = keyCode
        self.modifiers = modifiers
    }

    init?(dictionary: [String: Any]) {
        guard let kc = dictionary["keyCode"]   as? Int,
              let mf = dictionary["modifiers"] as? UInt else { return nil }
        keyCode   = UInt16(kc)
        modifiers = NSEvent.ModifierFlags(rawValue: mf)
    }

    // MARK: Display
    /// Human-readable string shown in the Preferences window, e.g. "⌘⌥C".
    var displayString: String {
        var s = ""
        let m = modifiers.intersection(.deviceIndependentFlagsMask)
        if m.contains(.control)  { s += "⌃" }
        if m.contains(.option)   { s += "⌥" }
        if m.contains(.shift)    { s += "⇧" }
        if m.contains(.command)  { s += "⌘" }
        s += keyCodeDisplayString(keyCode)
        return s
    }
}

/// Returns a printable string for a Carbon virtual key code.
private func keyCodeDisplayString(_ keyCode: UInt16) -> String {
    // Common printable keys — extend as needed.
    let table: [UInt16: String] = [
        UInt16(kVK_ANSI_A):"A", UInt16(kVK_ANSI_B):"B", UInt16(kVK_ANSI_C):"C",
        UInt16(kVK_ANSI_D):"D", UInt16(kVK_ANSI_E):"E", UInt16(kVK_ANSI_F):"F",
        UInt16(kVK_ANSI_G):"G", UInt16(kVK_ANSI_H):"H", UInt16(kVK_ANSI_I):"I",
        UInt16(kVK_ANSI_J):"J", UInt16(kVK_ANSI_K):"K", UInt16(kVK_ANSI_L):"L",
        UInt16(kVK_ANSI_M):"M", UInt16(kVK_ANSI_N):"N", UInt16(kVK_ANSI_O):"O",
        UInt16(kVK_ANSI_P):"P", UInt16(kVK_ANSI_Q):"Q", UInt16(kVK_ANSI_R):"R",
        UInt16(kVK_ANSI_S):"S", UInt16(kVK_ANSI_T):"T", UInt16(kVK_ANSI_U):"U",
        UInt16(kVK_ANSI_V):"V", UInt16(kVK_ANSI_W):"W", UInt16(kVK_ANSI_X):"X",
        UInt16(kVK_ANSI_Y):"Y", UInt16(kVK_ANSI_Z):"Z",
        UInt16(kVK_ANSI_0):"0", UInt16(kVK_ANSI_1):"1", UInt16(kVK_ANSI_2):"2",
        UInt16(kVK_ANSI_3):"3", UInt16(kVK_ANSI_4):"4", UInt16(kVK_ANSI_5):"5",
        UInt16(kVK_ANSI_6):"6", UInt16(kVK_ANSI_7):"7", UInt16(kVK_ANSI_8):"8",
        UInt16(kVK_ANSI_9):"9",
        UInt16(kVK_Space):"Space", UInt16(kVK_Return):"↩",
        UInt16(kVK_Tab):"⇥",     UInt16(kVK_Delete):"⌫",
        UInt16(kVK_F1):"F1",     UInt16(kVK_F2):"F2",  UInt16(kVK_F3):"F3",
        UInt16(kVK_F4):"F4",     UInt16(kVK_F5):"F5",  UInt16(kVK_F6):"F6",
        UInt16(kVK_F7):"F7",     UInt16(kVK_F8):"F8",  UInt16(kVK_F9):"F9",
        UInt16(kVK_F10):"F10",   UInt16(kVK_F11):"F11",UInt16(kVK_F12):"F12",
    ]
    return table[keyCode] ?? "(\(keyCode))"
}

// MARK: - HotKey

final class HotKey {

    // MARK: - Properties

    private(set) var binding: HotKeyBinding
    var keyDownHandler: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor:  Any?
    private var isActive = false

    // MARK: - Init

    init(binding: HotKeyBinding, handler: (() -> Void)? = nil) {
        self.binding        = binding
        self.keyDownHandler = handler
    }

    // MARK: - Activation

    func activate() {
        guard !isActive else { return }
        isActive = true
        attachMonitors()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        removeMonitor(&globalMonitor)
        removeMonitor(&localMonitor)
    }

    /// Updates the key binding and re-attaches monitors without deallocation.
    /// Safe to call while the hotkey is active.
    func rebind(to newBinding: HotKeyBinding) {
        let wasActive = isActive
        if wasActive {
            removeMonitor(&globalMonitor)
            removeMonitor(&localMonitor)
        }
        binding = newBinding
        if wasActive { attachMonitors() }
    }

    deinit { deactivate() }

    // MARK: - Private

    private func attachMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let pressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard pressed == self.binding.modifiers,
                  event.keyCode == self.binding.keyCode
            else { return }
            self.keyDownHandler?()
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor  = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event); return event
        }
    }

    private func removeMonitor(_ monitor: inout Any?) {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
    }
}

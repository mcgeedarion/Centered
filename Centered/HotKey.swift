//
// HotKey.swift
// Centered
//
// A lightweight global + local keyboard-shortcut monitor built on NSEvent.
// Supports any key+modifier combination and can be rebound at runtime
// without deallocation via rebind(to:).
//
// @MainActor: activate/deactivate/rebind must always be called on the main
// thread. NSEvent monitors are added and removed on the thread that calls
// addGlobalMonitorForEvents — which is always main here. The handler closure
// captures `self` weakly and performs its work synchronously on the callback
// thread (NSEvent global monitors fire on a private GCD queue), so it must
// only touch thread-safe state. keyDownHandler itself is called on that queue;
// callers are responsible for dispatching back to main if needed.
//

import Cocoa
import Carbon.HIToolbox

// MARK: - HotKeyBinding

/// A serialisable key+modifier pair stored in UserDefaults.
struct HotKeyBinding: Equatable {

    var keyCode:   UInt16
    var modifiers: NSEvent.ModifierFlags

    static let centerActive = HotKeyBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .option])
    static let centerAll    = HotKeyBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift])

    var dictionaryRepresentation: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": modifiers.rawValue]
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode   = keyCode
        self.modifiers = modifiers
    }

    init?(dictionary: [String: Any]) {
        guard let kc = dictionary["keyCode"]   as? Int,
              let mf = dictionary["modifiers"] as? UInt
        else { return nil }
        keyCode   = UInt16(kc)
        modifiers = NSEvent.ModifierFlags(rawValue: mf)
    }

    var displayString: String {
        let m = modifiers.intersection(.deviceIndependentFlagsMask)
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += keyCodeDisplayString(keyCode)
        return s
    }
}

// MARK: - Key-code display table (built once at file scope)

private let kKeyDisplayTable: [UInt16: String] = {
    var t = [UInt16: String]()
    let entries: [(Int32, String)] = [
        (kVK_ANSI_A,"A"),(kVK_ANSI_B,"B"),(kVK_ANSI_C,"C"),(kVK_ANSI_D,"D"),
        (kVK_ANSI_E,"E"),(kVK_ANSI_F,"F"),(kVK_ANSI_G,"G"),(kVK_ANSI_H,"H"),
        (kVK_ANSI_I,"I"),(kVK_ANSI_J,"J"),(kVK_ANSI_K,"K"),(kVK_ANSI_L,"L"),
        (kVK_ANSI_M,"M"),(kVK_ANSI_N,"N"),(kVK_ANSI_O,"O"),(kVK_ANSI_P,"P"),
        (kVK_ANSI_Q,"Q"),(kVK_ANSI_R,"R"),(kVK_ANSI_S,"S"),(kVK_ANSI_T,"T"),
        (kVK_ANSI_U,"U"),(kVK_ANSI_V,"V"),(kVK_ANSI_W,"W"),(kVK_ANSI_X,"X"),
        (kVK_ANSI_Y,"Y"),(kVK_ANSI_Z,"Z"),
        (kVK_ANSI_0,"0"),(kVK_ANSI_1,"1"),(kVK_ANSI_2,"2"),(kVK_ANSI_3,"3"),
        (kVK_ANSI_4,"4"),(kVK_ANSI_5,"5"),(kVK_ANSI_6,"6"),(kVK_ANSI_7,"7"),
        (kVK_ANSI_8,"8"),(kVK_ANSI_9,"9"),
        (kVK_Space,"Space"),(kVK_Return,"↩"),(kVK_Tab,"⇥"),(kVK_Delete,"⌫"),
        (kVK_F1,"F1"),(kVK_F2,"F2"),(kVK_F3,"F3"),(kVK_F4,"F4"),
        (kVK_F5,"F5"),(kVK_F6,"F6"),(kVK_F7,"F7"),(kVK_F8,"F8"),
        (kVK_F9,"F9"),(kVK_F10,"F10"),(kVK_F11,"F11"),(kVK_F12,"F12"),
    ]
    for (code, label) in entries { t[UInt16(code)] = label }
    return t
}()

private func keyCodeDisplayString(_ keyCode: UInt16) -> String {
    kKeyDisplayTable[keyCode] ?? "(\(keyCode))"
}

// MARK: - HotKey

/// Must be created, activated, deactivated, and rebound on @MainActor.
/// The keyDownHandler closure is invoked on NSEvent's private callback queue;
/// callers should dispatch to main if touching UI or actor-isolated state.
@MainActor
final class HotKey {

    private(set) var binding: HotKeyBinding
    var keyDownHandler: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor:  Any?
    private var isActive = false

    init(binding: HotKeyBinding, handler: (() -> Void)? = nil) {
        self.binding        = binding
        self.keyDownHandler = handler
    }

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

    func rebind(to newBinding: HotKeyBinding) {
        let wasActive = isActive
        if wasActive {
            removeMonitor(&globalMonitor)
            removeMonitor(&localMonitor)
        }
        binding = newBinding
        if wasActive { attachMonitors() }
    }

    deinit {
        // NSEvent monitors must be removed; removeMonitor is thread-safe.
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
    }

    private func attachMonitors() {
        // Capture binding by value so the closure doesn't need `self`
        // for the hot comparison path — avoids a weak/strong dance on
        // every keypress.
        let b = binding
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == b.modifiers,
                  event.keyCode == b.keyCode
            else { return }
            self?.keyDownHandler?()
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

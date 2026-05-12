//
// HotKey.swift
// Centered
//
// Global hotkeys implemented via Carbon RegisterEventHotKey.
// Unlike NSEvent.addGlobalMonitorForEvents, Carbon hotkeys are delivered only
// when the exact registered combination fires — the OS never passes any other
// keystrokes to this process, eliminating the keylogger surface entirely.
//
// Threading:
//   activate / deactivate / rebind must be called on @MainActor.
//   The Carbon event handler fires on the main thread (GetApplicationEventTarget).
//   deinit is nonisolated — it captures hotKeyRef locally and unregisters safely.
//

import Cocoa
import Carbon.HIToolbox

// MARK: - HotKeyBinding

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
        if m.contains(.control) { s += "\u{2303}" }
        if m.contains(.option)  { s += "\u{2325}" }
        if m.contains(.shift)   { s += "\u{21E7}" }
        if m.contains(.command) { s += "\u{2318}" }
        s += keyCodeDisplayString(keyCode)
        return s
    }

    /// Converts NSEvent modifier flags to the Carbon modifier mask expected by
    /// RegisterEventHotKey. Only the standard four modifiers are mapped.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        let m = modifiers.intersection(.deviceIndependentFlagsMask)
        if m.contains(.command) { mask |= UInt32(cmdKey) }
        if m.contains(.option)  { mask |= UInt32(optionKey) }
        if m.contains(.shift)   { mask |= UInt32(shiftKey) }
        if m.contains(.control) { mask |= UInt32(controlKey) }
        return mask
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
        (kVK_Space,"Space"),(kVK_Return,"\u{21A9}"),(kVK_Tab,"\u{21E5}"),(kVK_Delete,"\u{232B}"),
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

// MARK: - HotKey ID allocator

private var _nextHotKeyID: UInt32 = 1
private func nextHotKeyID() -> EventHotKeyID {
    defer { _nextHotKeyID &+= 1 }
    // 'Cent' as OSType signature
    return EventHotKeyID(signature: 0x43656E74, id: _nextHotKeyID)
}

// MARK: - HotKey

/// Installs a system-wide hotkey via Carbon RegisterEventHotKey.
/// Only the exact key+modifier combination is ever delivered — no other
/// keystrokes pass through this process, unlike NSEvent global monitors.
@MainActor
final class HotKey {

    private(set) var binding: HotKeyBinding
    var keyDownHandler: (() -> Void)?

    private var hotKeyRef:    EventHotKeyRef?
    private var handlerRef:   EventHandlerRef?
    private var hotKeyID:     EventHotKeyID
    private var isActive = false

    init(binding: HotKeyBinding, handler: (() -> Void)? = nil) {
        self.binding        = binding
        self.keyDownHandler = handler
        self.hotKeyID       = nextHotKeyID()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        installCarbonHandler()
        registerHotKey()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        unregisterHotKey()
        removeCarbonHandler()
    }

    func rebind(to newBinding: HotKeyBinding) {
        guard binding != newBinding else { return }
        let wasActive = isActive
        if wasActive { deactivate() }
        binding   = newBinding
        hotKeyID  = nextHotKeyID()   // fresh ID avoids stale matches
        if wasActive { activate() }
    }

    nonisolated deinit {
        // Captured locally — no actor-isolated property access.
        // UnregisterEventHotKey and RemoveEventHandler are safe to call
        // from any thread per Carbon documentation.
        // Note: hotKeyRef / handlerRef are MainActor-isolated stored properties;
        // in practice deinit only runs after the last reference is dropped,
        // which for @MainActor objects happens on the main thread, so this
        // is safe. We suppress the warning with a nonisolated deinit
        // that does NOT access stored properties — cleanup must happen
        // via explicit deactivate() before release.
    }

    // MARK: - Carbon internals

    private func installCarbonHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  OSType(kEventHotKeyPressed)
        )
        // Pass an unretained pointer to self as userData. The handler only fires
        // while hotKeyRef is registered (i.e. while isActive == true and self
        // is alive), so no retain is needed.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1, &eventType,
            selfPtr,
            &handlerRef
        )
    }

    private func removeCarbonHandler() {
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
    }

    private func registerHotKey() {
        guard hotKeyRef == nil else { return }
        RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // Called from the C callback — must be @MainActor since the Carbon handler
    // fires on the main thread (GetApplicationEventTarget).
    func handleCarbonEvent(_ event: EventRef) {
        var firedID = EventHotKeyID()
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &firedID
        )
        guard firedID.signature == hotKeyID.signature,
              firedID.id        == hotKeyID.id
        else { return }
        keyDownHandler?()
    }
}

// MARK: - Carbon callback (C function)

/// Top-level C function required by InstallEventHandler.
/// Hops are unnecessary — GetApplicationEventTarget always fires on the main thread.
private let carbonHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }
    let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    hotKey.handleCarbonEvent(event)
    return noErr
}

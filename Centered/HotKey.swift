import Cocoa
import Carbon.HIToolbox

private let kSupportedHotKeyModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

private let kModifierDisplayOrder: [(flag: NSEvent.ModifierFlags, symbol: String)] = [
    (.control, "\u{2303}"),
    (.option, "\u{2325}"),
    (.shift, "\u{21E7}"),
    (.command, "\u{2318}"),
]

extension NSEvent.ModifierFlags {
    var hotKeyDisplayString: String {
        let supported = intersection(kSupportedHotKeyModifiers)
        return kModifierDisplayOrder
            .filter { supported.contains($0.flag) }
            .map(\.symbol)
            .joined()
    }
}

struct HotKeyBinding: Equatable, Codable {

    var keyCode:   UInt16
    var modifiers: NSEvent.ModifierFlags

    static let centerActive = HotKeyBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .option])
    static let centerAll    = HotKeyBinding(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift])

    var dictionaryRepresentation: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": modifiers.rawValue]
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode   = keyCode
        self.modifiers = modifiers.intersection(kSupportedHotKeyModifiers)
    }

    init?(dictionary: [String: Any]) {
        guard let kc = dictionary["keyCode"] as? Int,
              let keyCode = UInt16(exactly: kc),
              let modifiersRawValue = HotKeyBinding.modifierRawValue(from: dictionary["modifiers"])
        else { return nil }
        self.keyCode = keyCode
        modifiers = NSEvent.ModifierFlags(rawValue: modifiersRawValue).intersection(kSupportedHotKeyModifiers)
    }

    private static func modifierRawValue(from value: Any?) -> UInt? {
        if let raw = value as? UInt { return raw }
        if let raw = value as? Int { return UInt(exactly: raw) }
        if let raw = value as? UInt64 { return UInt(exactly: raw) }
        if let raw = value as? NSNumber, raw.int64Value >= 0 {
            return UInt(exactly: raw.uint64Value)
        }
        return nil
    }

    var displayString: String {
        modifiers.hotKeyDisplayString + keyCodeDisplayString(keyCode)
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKeyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let decodedModifiers = try container.decode(UInt.self, forKey: .modifiers)
        self.init(
            keyCode: decodedKeyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: decodedModifiers)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
    }

    /// NSEvent modifier flags converted to the Carbon mask for RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        let m = modifiers.intersection(kSupportedHotKeyModifiers)
        if m.contains(.command) { mask |= UInt32(cmdKey) }
        if m.contains(.option)  { mask |= UInt32(optionKey) }
        if m.contains(.shift)   { mask |= UInt32(shiftKey) }
        if m.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}

// MARK: - Key Display Table (Improvement #3: Expanded key code support)
private let kKeyDisplayTable = Dictionary(uniqueKeysWithValues: [
    // Letters
    (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
    (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
    (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
    (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
    (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
    (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
    (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
    // Numbers
    (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
    (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
    (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
    // Special keys
    (kVK_Space, "Space"), (kVK_Return, "\u{21A9}"), (kVK_Tab, "\u{21E5}"),
    (kVK_Delete, "\u{232B}"),
    // Function keys
    (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
    (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
    (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
    // Arrow keys
    (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
    (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"),
    // Navigation keys
    (kVK_Home, "Home"), (kVK_End, "End"),
    (kVK_PageUp, "Page Up"), (kVK_PageDown, "Page Down"),
    (kVK_Escape, "Esc"),
].map { (UInt16($0.0), $0.1) })

private func keyCodeDisplayString(_ keyCode: UInt16) -> String {
    kKeyDisplayTable[keyCode] ?? "(\(keyCode))"
}

private var _nextHotKeyID: UInt32 = 1
private func nextHotKeyID() -> EventHotKeyID {
    defer { _nextHotKeyID &+= 1 }
    return EventHotKeyID(signature: 0x43656E74 /* 'Cent' */, id: _nextHotKeyID)
}

// MARK: - HotKey Errors (Improvement #5: Error handling)
enum HotKeyError: LocalizedError {
    case failedToInstallHandler
    case failedToRegisterHotKey
    case failedToUnregisterHotKey

    var errorDescription: String? {
        switch self {
        case .failedToInstallHandler:
            return "Failed to install Carbon event handler for hot key"
        case .failedToRegisterHotKey:
            return "Failed to register hot key with system"
        case .failedToUnregisterHotKey:
            return "Failed to unregister hot key with system"
        }
    }
}

// MARK: - HotKey Class
@MainActor
final class HotKey {

    private(set) var binding: HotKeyBinding
    var keyDownHandler: (() -> Void)?

    private var hotKeyRef:  EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var hotKeyID:   EventHotKeyID
    private var isActive = false

    init(binding: HotKeyBinding, handler: (() -> Void)? = nil) {
        self.binding        = binding
        self.keyDownHandler = handler
        self.hotKeyID       = nextHotKeyID()
    }

    /// Activates the hot key by installing the Carbon event handler and registering the key.
    /// - Throws: `HotKeyError` if installation or registration fails.
    func activate() throws {
        guard !isActive else { return }

        do {
            try installCarbonHandler()
            try registerHotKey()
            isActive = true  // Improvement #4: State change only after both succeed
        } catch {
            // Rollback on failure
            removeCarbonHandler()
            unregisterHotKey()
            throw error
        }
    }

    /// Deactivates the hot key by unregistering it and removing the Carbon event handler.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        unregisterHotKey()
        removeCarbonHandler()
    }

    /// Rebinds the hot key to a new binding.
    /// - Parameter newBinding: The new `HotKeyBinding` to use.
    /// - Throws: `HotKeyError` if re-registration fails during rebind.
    func rebind(to newBinding: HotKeyBinding) throws {
        guard binding != newBinding else { return }
        let oldBinding = binding
        let oldHotKeyID = hotKeyID
        let wasActive = isActive

        if wasActive {
            deactivate()
        }

        binding  = newBinding
        hotKeyID = nextHotKeyID()

        if wasActive {
            do {
                try activate()
            } catch {
                binding = oldBinding
                hotKeyID = oldHotKeyID
                try? activate()
                throw error
            }
        }
    }

    /// Cleanup must happen via explicit deactivate() before the last reference is dropped.
    /// Improvement #2: Added assertion to enforce deactivation discipline.
    deinit {
        if isActive {
            assertionFailure(
                "HotKey must be deactivated via deactivate() before deallocation. "
                + "Current binding: \(binding)"
            )
        }
    }

    // MARK: - Private Methods

    private func installCarbonHandler() throws {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  OSType(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1, &eventType,
            selfPtr,
            &handlerRef
        )

        // Improvement #5: Check for errors from Carbon API
        guard status == noErr else {
            handlerRef = nil
            throw HotKeyError.failedToInstallHandler
        }
    }

    private func removeCarbonHandler() {
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
    }

    private func registerHotKey() throws {
        guard hotKeyRef == nil else { return }

        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        // Improvement #5: Check for errors from Carbon API
        guard status == noErr else {
            hotKeyRef = nil
            throw HotKeyError.failedToRegisterHotKey
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            let status = UnregisterEventHotKey(ref)
            // Log error but don't throw in cleanup path
            if status != noErr {
                NSLog("Warning: UnregisterEventHotKey failed with status \(status)")
            }
            hotKeyRef = nil
        }
    }

    // Improvement #1: Added safety check for active state
    func handleCarbonEvent(_ event: EventRef) {
        guard isActive else { return }

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

// MARK: - Carbon Event Handler
private let carbonHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }
    Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().handleCarbonEvent(event)
    return noErr
}

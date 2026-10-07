import Foundation

/// Limits what the root daemon forwards to the app while no mode is active
/// (keyboard NOT seized). Idle is exactly when the user may be typing a
/// password — the daemon only connects under Secure Input — so ordinary typing
/// must never leave the daemon.
///
/// The app only needs, while idle:
///  - modifier/Fn down/up, to detect activation taps (tap left ⌥ / left ⌘ ...);
///  - ⌃/⌘/Fn+key chords, for shortcuts like ⌘⇧Space / ⌘⇧D / Fn+Space;
///  - "some other key went down while ⇧ or ⌥ was held", so Shift+A does not
///    register as a Shift tap (KeyHandler cancels pending taps on any keyDown).
///    Those combos type characters (A, é, ß...), so they are sent REDACTED —
///    no identity, just the fact.
/// Everything else is dropped. While a mode is active (seized) the app owns the
/// keyboard and every key is forwarded unchanged.
struct IdleKeyGate {
    enum Decision: Equatable {
        case forward
        case redact
        case drop
    }

    /// HID usage 0x00 ("no event") on the keyboard page, mapped to an
    /// out-of-range virtual keycode no binding can match.
    static let redactedUsage: UInt32 = 0x00
    static let redactedKeyCode: UInt16 = 0xFFFF

    // KeyEventMessage.modifiers bits (see KeyboardGrabber.updateModifierState).
    private static let textBits: UInt8 = 0x02 | 0x04 // shift, option
    private static let chordBits: UInt8 = 0x01 | 0x08 // control, command

    /// Decision made for each key's keyDown, so its keyUp mirrors it.
    private var downDecisions: [UInt32: Decision] = [:]
    private var fnHeld = false

    static func isModifier(usagePage: UInt32, usage: UInt32) -> Bool {
        if usagePage == HIDUsageMap.keyboardOrKeypadPage { return (0xE0...0xE7).contains(usage) }
        return usagePage == HIDUsageMap.appleVendorTopCasePage && usage == HIDUsageMap.appleKeyboardFnUsage
    }

    /// Returns the message to send to the app, or nil to send nothing.
    mutating func filter(_ event: KeyEventMessage, modeActive: Bool) -> KeyEventMessage? {
        let isDown = event.eventType == "keyDown"
        let modifier = Self.isModifier(usagePage: event.usagePage, usage: event.usage)
        if event.usagePage == HIDUsageMap.appleVendorTopCasePage && event.usage == HIDUsageMap.appleKeyboardFnUsage {
            fnHeld = isDown
        }

        let decision: Decision
        if modeActive || modifier {
            decision = .forward
        } else if isDown {
            if event.modifiers & Self.chordBits != 0 || fnHeld {
                decision = .forward
            } else if event.modifiers & Self.textBits != 0 {
                decision = .redact
            } else {
                decision = .drop
            }
        } else {
            decision = downDecisions[event.usage] ?? .drop
        }

        if !modifier {
            if isDown { downDecisions[event.usage] = decision } else { downDecisions[event.usage] = nil }
        }

        switch decision {
        case .drop:
            return nil
        case .forward where modeActive:
            return event
        case .forward:
            return event.withPressedKeys(onlyModifiersFrom: event.pressedKeysSnapshot)
        case .redact:
            return KeyEventMessage(
                keyCode: Self.redactedKeyCode,
                usagePage: HIDUsageMap.keyboardOrKeypadPage,
                usage: Self.redactedUsage,
                value: event.value,
                modifiers: event.modifiers,
                eventType: event.eventType,
                pressedKeysSnapshot: []
            )
        }
    }
}

private extension KeyEventMessage {
    /// The snapshot lists every held key; idle forwards must not reveal them.
    func withPressedKeys(onlyModifiersFrom keys: [UInt32]) -> KeyEventMessage {
        KeyEventMessage(
            keyCode: keyCode,
            usagePage: usagePage,
            usage: usage,
            value: value,
            modifiers: modifiers,
            eventType: eventType,
            pressedKeysSnapshot: keys.filter { (0xE0...0xE7).contains($0) }
        )
    }
}

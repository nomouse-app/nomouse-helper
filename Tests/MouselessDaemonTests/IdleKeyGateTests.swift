import XCTest
@testable import mouseless_daemon

/// Locks the daemon's idle privacy contract: while no mode is active, plain
/// typing (e.g. a password) never leaves the daemon, ⇧/⌥ combos only reveal
/// that a key was pressed, and activation taps + ⌃/⌘/Fn shortcuts still work.
final class IdleKeyGateTests: XCTestCase {
    // HID keyboard-page usages.
    private let a: UInt32 = 0x04
    private let d: UInt32 = 0x07
    private let space: UInt32 = 0x2C
    private let leftShift: UInt32 = 0xE1
    private let leftOption: UInt32 = 0xE2
    private let leftCommand: UInt32 = 0xE3

    private func key(_ usage: UInt32, down: Bool, modifiers: UInt8 = 0, page: UInt32 = 0x07,
                     pressed: [UInt32] = []) -> KeyEventMessage {
        KeyEventMessage(keyCode: UInt16(usage), usagePage: page, usage: usage, value: down ? 1 : 0,
                        modifiers: modifiers, eventType: down ? "keyDown" : "keyUp",
                        pressedKeysSnapshot: pressed)
    }

    func testPlainTypingIsDroppedWhileIdle() {
        var gate = IdleKeyGate()
        XCTAssertNil(gate.filter(key(a, down: true), modeActive: false))
        XCTAssertNil(gate.filter(key(a, down: false), modeActive: false))
    }

    func testModifierTapIsForwardedWhileIdle() {
        var gate = IdleKeyGate()
        XCTAssertEqual(gate.filter(key(leftOption, down: true, modifiers: 0x04), modeActive: false)?.usage, leftOption)
        XCTAssertEqual(gate.filter(key(leftOption, down: false), modeActive: false)?.usage, leftOption)
    }

    func testShiftAndOptionCombosAreRedacted() {
        var gate = IdleKeyGate()
        for mods: UInt8 in [0x02, 0x04] {
            let down = gate.filter(key(a, down: true, modifiers: mods), modeActive: false)
            XCTAssertEqual(down?.usage, IdleKeyGate.redactedUsage)
            XCTAssertEqual(down?.keyCode, IdleKeyGate.redactedKeyCode)
            XCTAssertEqual(down?.eventType, "keyDown", "a keyDown is what cancels a pending modifier tap")
            // The keyUp mirrors its keyDown even after the modifier is released.
            XCTAssertEqual(gate.filter(key(a, down: false), modeActive: false)?.usage, IdleKeyGate.redactedUsage)
        }
    }

    func testCommandAndControlChordsAreForwarded() {
        var gate = IdleKeyGate()
        for mods: UInt8 in [0x08, 0x08 | 0x02, 0x01] {
            XCTAssertEqual(gate.filter(key(d, down: true, modifiers: mods), modeActive: false)?.usage, d)
            XCTAssertEqual(gate.filter(key(d, down: false), modeActive: false)?.usage, d)
        }
    }

    func testFnChordIsForwarded() {
        var gate = IdleKeyGate()
        XCTAssertNotNil(gate.filter(key(0x03, down: true, page: 0x00ff), modeActive: false))
        XCTAssertEqual(gate.filter(key(space, down: true), modeActive: false)?.usage, space)
        XCTAssertNotNil(gate.filter(key(0x03, down: false, page: 0x00ff), modeActive: false))
        XCTAssertNil(gate.filter(key(space, down: true), modeActive: false))
    }

    func testIdleForwardsHideHeldNonModifierKeys() {
        var gate = IdleKeyGate()
        let out = gate.filter(key(leftCommand, down: true, modifiers: 0x08, pressed: [a, leftCommand]),
                              modeActive: false)
        XCTAssertEqual(out?.pressedKeysSnapshot, [leftCommand])
    }

    func testEverythingIsForwardedWhileModeActive() {
        var gate = IdleKeyGate()
        let event = key(a, down: true, pressed: [a, leftShift])
        let out = gate.filter(event, modeActive: true)
        XCTAssertEqual(out?.usage, a)
        XCTAssertEqual(out?.pressedKeysSnapshot, [a, leftShift])
    }

    func testKeyHeldIntoModeExitStillReleases() {
        var gate = IdleKeyGate()
        XCTAssertNotNil(gate.filter(key(a, down: true), modeActive: true))
        XCTAssertEqual(gate.filter(key(a, down: false), modeActive: false)?.usage, a)
    }
}

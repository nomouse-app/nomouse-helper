import Foundation

/// Normalizes HID usages from the daemon's IOHID path into the macOS virtual
/// keycodes used by the app/keymap layer.
enum HIDUsageMap {
    static let keyboardOrKeypadPage: UInt32 = 0x07
    static let appleVendorTopCasePage: UInt32 = 0x00ff
    static let appleKeyboardFnUsage: UInt32 = 0x03

    /// HID usage -> macOS virtual keycode. Covers letters, digits, the keys the
    /// grid/free-mode features use, modifiers, and common navigation keys.
    private static let usageToVirtual: [UInt32: UInt16] = [
        // Letters (HID 0x04..0x1D = A..Z)
        0x04: 0x00, // a
        0x05: 0x0B, // b
        0x06: 0x08, // c
        0x07: 0x02, // d
        0x08: 0x0E, // e
        0x09: 0x03, // f
        0x0A: 0x05, // g
        0x0B: 0x04, // h
        0x0C: 0x22, // i
        0x0D: 0x26, // j
        0x0E: 0x28, // k
        0x0F: 0x25, // l
        0x10: 0x2E, // m
        0x11: 0x2D, // n
        0x12: 0x1F, // o
        0x13: 0x23, // p
        0x14: 0x0C, // q
        0x15: 0x0F, // r
        0x16: 0x01, // s
        0x17: 0x11, // t
        0x18: 0x20, // u
        0x19: 0x09, // v
        0x1A: 0x0D, // w
        0x1B: 0x07, // x
        0x1C: 0x10, // y
        0x1D: 0x06, // z

        // Digits (HID 0x1E..0x27 = 1..9,0)
        0x1E: 0x12, // 1
        0x1F: 0x13, // 2
        0x20: 0x14, // 3
        0x21: 0x15, // 4
        0x22: 0x17, // 5
        0x23: 0x16, // 6
        0x24: 0x1A, // 7
        0x25: 0x1C, // 8
        0x26: 0x19, // 9
        0x27: 0x1D, // 0

        // Whitespace / editing
        0x28: 0x24, // return (enter)
        0x29: 0x35, // escape
        0x2A: 0x33, // delete (backspace)
        0x2B: 0x30, // tab
        0x2C: 0x31, // space

        // Punctuation
        0x2D: 0x1B, // - _
        0x2E: 0x18, // = +
        0x2F: 0x21, // [ {
        0x30: 0x1E, // ] }
        0x31: 0x2A, // \\ |
        0x33: 0x29, // ; :
        0x34: 0x27, // ' "
        0x35: 0x32, // ` ~
        0x36: 0x2B, // , <
        0x37: 0x2F, // . >
        0x38: 0x2C, // / ?
        0x39: 0x39, // caps lock

        // Function row
        0x3A: 0x7A, // F1
        0x3B: 0x78, // F2
        0x3C: 0x63, // F3
        0x3D: 0x76, // F4
        0x3E: 0x60, // F5
        0x3F: 0x61, // F6
        0x40: 0x62, // F7
        0x41: 0x64, // F8
        0x42: 0x65, // F9
        0x43: 0x6D, // F10
        0x44: 0x67, // F11
        0x45: 0x6F, // F12

        // Navigation
        0x4A: 0x73, // home
        0x4B: 0x74, // page up
        0x4C: 0x75, // forward delete
        0x4D: 0x77, // end
        0x4E: 0x79, // page down
        0x4F: 0x7C, // right arrow
        0x50: 0x7B, // left arrow
        0x51: 0x7D, // down arrow
        0x52: 0x7E, // up arrow

        // Modifiers (HID 0xE0..0xE7)
        0xE0: 0x3B, // left control
        0xE1: 0x38, // left shift
        0xE2: 0x3A, // left option/alt
        0xE3: 0x37, // left command/gui
        0xE4: 0x3E, // right control
        0xE5: 0x3C, // right shift
        0xE6: 0x3D, // right option/alt
        0xE7: 0x36  // right command/gui
    ]

    static func shouldForward(usagePage: UInt32, usage: UInt32) -> Bool {
        if usagePage == keyboardOrKeypadPage { return usage >= 4 && usage <= 231 }
        return usagePage == appleVendorTopCasePage && usage == appleKeyboardFnUsage
    }

    static func virtualKeyCode(usagePage: UInt32, usage: UInt32) -> UInt16? {
        if usagePage == appleVendorTopCasePage && usage == appleKeyboardFnUsage {
            return 0x3F
        }
        guard usagePage == keyboardOrKeypadPage else { return nil }
        return usageToVirtual[usage]
    }
}

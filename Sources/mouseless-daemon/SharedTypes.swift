import Foundation

struct KeyboardHIDReport {
    var reportId: UInt8 = 0x01
    var modifiers: UInt8 = 0
    var reserved: UInt8 = 0
    var keycodes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0)

    var bytes: [UInt8] {
        [reportId, modifiers, reserved,
         keycodes.0, keycodes.1, keycodes.2,
         keycodes.3, keycodes.4, keycodes.5]
    }
}

struct AbsolutePointingReport {
    var reportId: UInt8 = 0x01
    var buttons: UInt8 = 0
    var x: UInt16 = 0
    var y: UInt16 = 0

    var bytes: [UInt8] {
        [reportId, buttons,
         UInt8(x & 0xFF), UInt8(x >> 8),
         UInt8(y & 0xFF), UInt8(y >> 8)]
    }
}

struct RelativePointingReport {
    var reportId: UInt8 = 0x02
    var buttons: UInt8 = 0
    var dx: Int8 = 0
    var dy: Int8 = 0
    var scroll: Int8 = 0
    var hScroll: Int8 = 0

    var bytes: [UInt8] {
        [reportId, buttons,
         UInt8(bitPattern: dx),
         UInt8(bitPattern: dy),
         UInt8(bitPattern: scroll),
         UInt8(bitPattern: hScroll)]
    }
}

enum DaemonCommand: Codable {
    case mouseAbsoluteMove(x: UInt16, y: UInt16)
    case mouseRelativeMove(dx: Int8, dy: Int8)
    case mouseClick(button: ButtonType)
    case mouseClickWithModifiers(button: ButtonType, modifiers: UInt8)
    case doubleClick(button: ButtonType)
    case tripleClick(button: ButtonType)
    case dragStart
    case dragEnd
    case scroll(dx: Int8, dy: Int8)
    case consumeKey(keyCode: UInt16)
    case passthroughKey(keyCode: UInt16)
    case activateOverlay
    case deactivateOverlay

    enum ButtonType: String, Codable {
        case left, right, middle, back, forward

        var mask: UInt8 {
            switch self {
            case .left: return 0x01
            case .right: return 0x02
            case .middle: return 0x04
            case .back: return 0x08
            case .forward: return 0x10
            }
        }
    }
}

struct KeyEventMessage: Codable {
    let keyCode: UInt16
    let usagePage: UInt32
    let usage: UInt32
    let value: Int
    let modifiers: UInt8
    let eventType: String
    let pressedKeysSnapshot: [UInt32]
}

enum IPCError: Error {
    case connectionFailed(Int32)
    case socketCreationFailed
    case bindFailed(Int32)
    case listenFailed(Int32)
}

enum GrabError: Error {
    case seizeFailed(Int32)
    case managerCreationFailed
}

enum VirtualHIDError: Error {
    case dextNotFound
    case connectionFailed(Int32)
    case initializationFailed(Int32)
}

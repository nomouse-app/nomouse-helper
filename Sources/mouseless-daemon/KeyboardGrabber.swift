import Foundation
import IOKit.hid

/// Reads the Karabiner DriverKit Virtual HID Keyboard at the IOKit HID layer
/// (which sees keys *below* macOS Secure Input, unlike a CGEventTap), and can
/// SEIZE it on demand so grid/free-mode keys are swallowed (never reach the OS)
/// even inside a password field.
///
/// Why the Karabiner virtual keyboard and not the physical one: Karabiner-
/// Elements seizes the physical keyboard 24/7 for its remaps, then re-emits
/// through its virtual HID keyboard (vendor 1452 / product 591). That virtual
/// device is NOT held exclusively, so a root process can seize it. We sit
/// *after* Karabiner — no conflict.
///
/// Implementation note: this uses the **per-device** IOHIDDevice API (not the
/// IOHIDManager-level open). Registering the input callback on the manager while
/// separately opening/seizing the device causes the callback to stop firing
/// once seized — so we open each device directly, register its callback, and
/// schedule it on the MAIN runloop. To change seize state we must UNSCHEDULE,
/// close, re-open with the new option, re-register, and re-schedule — all on the
/// main runloop.
final class KeyboardGrabber {

    private var manager: IOHIDManager?
    var onKeyEvent: ((KeyEventMessage) -> Void)?
    private var currentModifiers: UInt8 = 0
    private var pressedKeys: Set<UInt32> = []

    private(set) var seized = false
    /// Devices we've matched and currently have open.
    private var openDevices: [IOHIDDevice] = []

    private lazy var context = Unmanaged.passUnretained(self).toOpaque()

    private let inputCallback: IOHIDValueCallback = { ctx, _, _, value in
        guard let ctx = ctx else { return }
        Unmanaged<KeyboardGrabber>.fromOpaque(ctx).takeUnretainedValue()
            .handleInputValue(value)
    }

    // MARK: - lifecycle

    /// Start observing the Karabiner vkb (SHARED). Uses an IOHIDManager only to
    /// DISCOVER matching devices; actual open/seize + input callbacks are
    /// per-device. Must run on the main thread (callbacks fire on the main
    /// runloop).
    func start() throws {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.karabinerVendorID,
            kIOHIDProductIDKey as String: Self.karabinerProductID,
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        // Schedule the manager only to receive the device set; we don't open it.
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // Enumerate currently-present matching devices and open each (shared).
        if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> {
            for device in set where isTargetKeyboard(device) {
                openDevice(device, seize: false)
            }
        }

        // Also catch hot-plugged devices.
        let matchCallback: IOHIDDeviceCallback = { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<KeyboardGrabber>.fromOpaque(ctx).takeUnretainedValue()
                .handleDeviceMatched(device)
        }
        let removalCallback: IOHIDDeviceCallback = { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<KeyboardGrabber>.fromOpaque(ctx).takeUnretainedValue()
                .handleDeviceRemoved(device)
        }
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, removalCallback, context)

        NSLog("KeyboardGrabber: started (observing, shared) — %d device(s)", openDevices.count)
    }

    func release() {
        setSeized(false)
        for device in openDevices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        openDevices.removeAll()
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            manager = nil
        }
        NSLog("KeyboardGrabber: released")
    }

    // MARK: - per-device open

    /// Open a device with the given mode, register its input callback, and
    /// schedule it on the main runloop. Replaces any prior open of the device.
    private func openDevice(_ device: IOHIDDevice, seize: Bool) {
        // Ensure a clean slate (idempotent if it wasn't open).
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

        let options = seize
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        let r = IOHIDDeviceOpen(device, options)
        if r != kIOReturnSuccess {
            NSLog("KeyboardGrabber: open %@ (%@) failed 0x%x",
                  productName(device), seize ? "seize" : "shared", r)
            return
        }
        // Register the input callback + schedule AFTER opening, so it stays
        // bound to this open session (incl. when seized).
        IOHIDDeviceRegisterInputValueCallback(device, inputCallback, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        if !openDevices.contains(device) { openDevices.append(device) }
    }

    // MARK: - seize toggle

    /// Seize (true) / share (false) the matched keyboard(s). MUST run on the
    /// main runloop (re-opens devices + re-registers callbacks there).
    func setSeized(_ want: Bool) {
        if Thread.isMainThread {
            performSetSeized(want)
        } else {
            DispatchQueue.main.async { [weak self] in self?.performSetSeized(want) }
        }
    }

    private func performSetSeized(_ want: Bool) {
        guard want != seized else { return }
        let devices = openDevices.filter { isTargetKeyboard($0) }
        for device in devices {
            openDevice(device, seize: want) // close+reopen with new mode + re-register
        }
        seized = want
        if !want { pressedKeys.removeAll(); currentModifiers = 0 }
        NSLog("KeyboardGrabber: setSeized(%@) -> %d device(s)", want ? "true" : "false", devices.count)
    }

    // MARK: - device matching

    private static let karabinerVendorID = 1452
    private static let karabinerProductID = 591
    private static let virtualProductNameHints = ["Karabiner", "VirtualHIDKeyboard", "Virtual HID"]

    private func intProp(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private func productName(_ device: IOHIDDevice) -> String {
        (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Unknown"
    }

    private func isTargetKeyboard(_ device: IOHIDDevice) -> Bool {
        if let v = intProp(device, kIOHIDVendorIDKey as String),
           let p = intProp(device, kIOHIDProductIDKey as String),
           v == Self.karabinerVendorID, p == Self.karabinerProductID {
            return true
        }
        let name = productName(device)
        return Self.virtualProductNameHints.contains { name.localizedCaseInsensitiveContains($0) }
    }

    private func handleDeviceMatched(_ device: IOHIDDevice) {
        guard isTargetKeyboard(device) else { return }
        NSLog("KeyboardGrabber: device matched: %@", productName(device))
        openDevice(device, seize: seized)
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        NSLog("KeyboardGrabber: device removed: %@", productName(device))
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        openDevices.removeAll { $0 == device }
    }

    // MARK: - input

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let usagePageValue = UInt32(usagePage)
        let usageValue = UInt32(usage)
        guard HIDUsageMap.shouldForward(usagePage: usagePageValue, usage: usageValue) else { return }

        updateModifierState(usage: usageValue, value: intValue)

        let eventType: String
        if intValue != 0 {
            pressedKeys.insert(usageValue)
            eventType = "keyDown"
        } else {
            pressedKeys.remove(usageValue)
            eventType = "keyUp"
        }

        let virtualKeyCode = HIDUsageMap.virtualKeyCode(usagePage: usagePageValue, usage: usageValue)

        let event = KeyEventMessage(
            keyCode: virtualKeyCode ?? UInt16(usage),
            usagePage: usagePageValue,
            usage: usageValue,
            value: intValue,
            modifiers: currentModifiers,
            eventType: eventType,
            pressedKeysSnapshot: Array(pressedKeys)
        )

        onKeyEvent?(event)
    }

    private func updateModifierState(usage: UInt32, value: Int) {
        let bit: UInt8
        switch usage {
        case 0xE0, 0xE4: bit = 0x01 // control
        case 0xE1, 0xE5: bit = 0x02 // shift
        case 0xE2, 0xE6: bit = 0x04 // option/alt
        case 0xE3, 0xE7: bit = 0x08 // command/gui
        default: return
        }
        if value != 0 { currentModifiers |= bit } else { currentModifiers &= ~bit }
    }
}

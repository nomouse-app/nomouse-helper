import Foundation

@available(*, deprecated, message: "Use shared HIDUsageMap so daemon and app stay in sync.")
enum HIDKeyMap {
    static func virtualKeyCode(forUsage usage: UInt32) -> UInt16? {
        HIDUsageMap.virtualKeyCode(usagePage: HIDUsageMap.keyboardOrKeypadPage, usage: usage)
    }
}

import Foundation
@preconcurrency import IOKit.hid

enum HIDElementValueDecoder {
    static func verticalScrollNotches(
        usagePage: UInt32,
        usage: UInt32,
        integerValue: CFIndex
    ) -> Int? {
        guard usagePage == UInt32(kHIDPage_GenericDesktop),
              usage == UInt32(kHIDUsage_GD_Wheel),
              integerValue != 0 else {
            return nil
        }
        return Int(integerValue)
    }
}

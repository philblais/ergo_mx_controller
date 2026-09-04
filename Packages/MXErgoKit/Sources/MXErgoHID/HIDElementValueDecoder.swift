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

    /// Wheel tilt. The MX Ergo reports it as AC Pan on the Consumer page, not
    /// as a button — confirmed on hardware 2026-09-04, and consistent with the
    /// device exposing CIDs 005B/005D, which are Left Scroll and Right Scroll.
    /// Positive is a right tilt.
    static func horizontalScrollNotches(
        usagePage: UInt32,
        usage: UInt32,
        integerValue: CFIndex
    ) -> Int? {
        guard usagePage == UInt32(kHIDPage_Consumer),
              usage == UInt32(kHIDUsage_Csmr_ACPan),
              integerValue != 0 else {
            return nil
        }
        return Int(integerValue)
    }
}

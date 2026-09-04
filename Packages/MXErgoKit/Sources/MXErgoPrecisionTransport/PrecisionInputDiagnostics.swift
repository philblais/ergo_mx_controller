import Foundation

/// Read-only evidence about what the Precision runtime's input path actually
/// received. It drives no routing and gates nothing.
///
/// It exists because the 2026-09-04 hardware session could not distinguish two
/// very different failures: the device sending no diverted-control notification
/// at all, versus the runtime receiving one and declining to route it. The
/// counters already existed inside the callback channel but were reachable from
/// nowhere, so the runtime could not report which had happened and the fix
/// could only have been guessed at.
///
/// `observedCount` counts frames that passed report type, report ID, length,
/// device identity, connection epoch and Root generation checks — that is,
/// frames genuinely from this device on this connection. `unsolicitedCount`
/// counts the subset routed as HID++ notifications. A gap between the two means
/// frames arrived and were not treated as notifications.
package struct PrecisionInputDiagnostics: Sendable, Equatable {
    package let observedCount: Int
    package let unsolicitedCount: Int
    package let acceptedCount: Int
    package let droppedCount: Int
    package let lastObservedFrameBytes: [UInt8]?

    package init(
        observedCount: Int,
        unsolicitedCount: Int,
        acceptedCount: Int,
        droppedCount: Int,
        lastObservedFrameBytes: [UInt8]?
    ) {
        self.observedCount = observedCount
        self.unsolicitedCount = unsolicitedCount
        self.acceptedCount = acceptedCount
        self.droppedCount = droppedCount
        self.lastObservedFrameBytes = lastObservedFrameBytes
    }
}

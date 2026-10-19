import CoreGraphics
import Foundation
@preconcurrency import IOKit.hid
import MXErgoCore

/// Input-value-only observer for MX Ergo vertical wheel notches.
///
/// It does not open vendor control reports, send output, or use the observer restart
/// fence, so it can run while the Precision runtime owns the vendor interface.
/// While `shouldSuppressScroll` is true, matching HID-level scroll events are
/// swallowed so Precision-held volume does not also scroll the frontmost app.
public final class MXErgoWheelObserver: @unchecked Sendable {
    public typealias NotchHandler = @Sendable (Int) -> Void
    public typealias SuppressCheck = @Sendable () -> Bool
    /// Read-only report of every scroll CGEvent this tap saw, and what was
    /// done with it. Optional because it exists for one measurement — which
    /// sign of the horizontal delta a left tilt produces — and adds nothing to
    /// the Precision path.
    public typealias ScrollTapObserver = @Sendable (ScrollTapSample) -> Void

    private let lock = NSLock()
    private var inputLoop: Loop?

    public init() {}

    public func start(
        handler: @escaping NotchHandler,
        shouldSuppressScroll: @escaping SuppressCheck,
        scrollTapObserver: ScrollTapObserver? = nil
    ) {
        lock.lock()
        guard inputLoop == nil else {
            lock.unlock()
            return
        }
        let loop = Loop(
            handler: handler,
            shouldSuppressScroll: shouldSuppressScroll,
            scrollTapObserver: scrollTapObserver
        )
        inputLoop = loop
        lock.unlock()
        loop.start()
    }

    public func stop() {
        lock.lock()
        let loop = inputLoop
        inputLoop = nil
        lock.unlock()
        loop?.stop()
    }
}

private final class Loop: @unchecked Sendable {
    let handler: MXErgoWheelObserver.NotchHandler
    let shouldSuppressScroll: MXErgoWheelObserver.SuppressCheck
    let scrollTapObserver: MXErgoWheelObserver.ScrollTapObserver?
    private let stateLock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var scrollTap: CFMachPort?
    private var inputDeliveryReady = false
    private var stopRequested = false

    init(
        handler: @escaping MXErgoWheelObserver.NotchHandler,
        shouldSuppressScroll: @escaping MXErgoWheelObserver.SuppressCheck,
        scrollTapObserver: MXErgoWheelObserver.ScrollTapObserver?
    ) {
        self.handler = handler
        self.shouldSuppressScroll = shouldSuppressScroll
        self.scrollTapObserver = scrollTapObserver
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.run()
        }
        thread.name = "com.phib.MXErgoController.WheelObserver"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        stateLock.lock()
        stopRequested = true
        let loop = runLoop
        stateLock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(loop)
        }
        CFRunLoopWakeUp(loop)
    }

    private func run() {
        autoreleasepool {
            guard let currentRunLoop = CFRunLoopGetCurrent() else { return }
            stateLock.lock()
            runLoop = currentRunLoop
            let shouldStop = stopRequested
            stateLock.unlock()
            guard !shouldStop else { return }

            let manager = IOHIDManagerCreate(
                kCFAllocatorDefault,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )
            let matching: [String: Any] = [
                kIOHIDVendorIDKey: DeviceIdentity.mxErgo.vendorID,
                kIOHIDProductIDKey: DeviceIdentity.mxErgo.productID,
            ]
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
            IOHIDManagerSetInputValueMatching(manager, [
                kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDElementUsageKey: kHIDUsage_GD_Wheel,
            ] as CFDictionary)

            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterInputValueCallback(
                manager,
                wheelValueCallback,
                context
            )
            IOHIDManagerScheduleWithRunLoop(
                manager,
                currentRunLoop,
                CFRunLoopMode.defaultMode.rawValue
            )
            let openResult = IOHIDManagerOpen(
                manager,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )

            var tap: CFMachPort?
            var tapSource: CFRunLoopSource?
            // Partial startup must not leave HID volume delivery running
            // without the tap that prevents the same gesture scrolling a page.
            defer {
                stateLock.withLock {
                    inputDeliveryReady = false
                    scrollTap = nil
                    runLoop = nil
                }
                if let tap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                }
                if let tapSource {
                    CFRunLoopRemoveSource(currentRunLoop, tapSource, .commonModes)
                }
                IOHIDManagerUnscheduleFromRunLoop(
                    manager, currentRunLoop, CFRunLoopMode.defaultMode.rawValue
                )
                IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
                _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            guard openResult == kIOReturnSuccess,
                  let createdTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(
                    1 << CGEventType.scrollWheel.rawValue
                ),
                callback: scrollTapCallback,
                userInfo: context
                  ) else { return }
            tap = createdTap
            guard let source = CFMachPortCreateRunLoopSource(
                kCFAllocatorDefault, createdTap, 0
            ) else { return }
            tapSource = source
            CFRunLoopAddSource(currentRunLoop, source, .commonModes)
            stateLock.withLock { scrollTap = createdTap }
            CGEvent.tapEnable(tap: createdTap, enable: true)
            let shouldRun = stateLock.withLock {
                inputDeliveryReady = !stopRequested
                return !stopRequested
            }
            if shouldRun { CFRunLoopRun() }
        }
    }

    fileprivate func handleScrollTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        WheelScrollTapHandler.handle(
            type: type,
            event: event,
            isStopping: stateLock.withLock { stopRequested },
            shouldSuppressScroll: shouldSuppressScroll,
            reenableTap: { [self] in
                stateLock.withLock {
                    guard !stopRequested, let scrollTap else { return }
                    CGEvent.tapEnable(tap: scrollTap, enable: true)
                }
            },
            scrollTapObserver: scrollTapObserver
        )
    }

    fileprivate func receivedValue(result: IOReturn, value: IOHIDValue) {
        guard stateLock.withLock({ inputDeliveryReady && !stopRequested }) else { return }
        guard result == kIOReturnSuccess else { return }
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let properties = HIDDevicePropertyDecoder.decode(device)
        guard properties.isMXErgo else { return }
        guard let notches = HIDElementValueDecoder.verticalScrollNotches(
            usagePage: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element),
            integerValue: IOHIDValueGetIntegerValue(value)
        ) else {
            return
        }
        handler(notches)
    }
}

private let wheelValueCallback: IOHIDValueCallback = { context, result, _, value in
    guard let context else { return }
    Unmanaged<Loop>.fromOpaque(context).takeUnretainedValue()
        .receivedValue(result: result, value: value)
}

private let scrollTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let loop = Unmanaged<Loop>.fromOpaque(refcon).takeUnretainedValue()
    return loop.handleScrollTap(type: type, event: event)
}

/// Callback policy kept separate from installing the live tap, so disabled-tap
/// recovery and the scrolls that must remain usable can be exercised offline.
enum WheelScrollTapHandler {
    static func handle(
        type: CGEventType,
        event: CGEvent,
        isStopping: Bool,
        shouldSuppressScroll: () -> Bool,
        reenableTap: () -> Void,
        scrollTapObserver: MXErgoWheelObserver.ScrollTapObserver? = nil
    ) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        guard !isStopping else { return passThrough }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-arming this existing event tap sends no device command. Without
            // it, HID volume changes continue while the page starts scrolling.
            reenableTap()
            return passThrough
        }
        guard type == .scrollWheel else { return passThrough }

        let vertical = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let horizontal = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        // Only discrete vertical wheel input belongs to Precision volume.
        // Trackpad gestures, tilt and mixed-axis scroll retain their behavior.
        let suppress = !continuous && vertical != 0 && horizontal == 0
            && shouldSuppressScroll()
        scrollTapObserver?(ScrollTapSample(
            deltaAxis1: vertical,
            deltaAxis2: horizontal,
            isContinuous: continuous,
            wasSuppressed: suppress
        ))
        return suppress ? nil : passThrough
    }
}

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
            if openResult == kIOReturnSuccess,
               let createdTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(
                    1 << CGEventType.scrollWheel.rawValue
                ),
                callback: scrollTapCallback,
                userInfo: context
               ) {
                tap = createdTap
                if let source = CFMachPortCreateRunLoopSource(
                    kCFAllocatorDefault,
                    createdTap,
                    0
                ) {
                    tapSource = source
                    CFRunLoopAddSource(
                        currentRunLoop,
                        source,
                        .commonModes
                    )
                    CGEvent.tapEnable(tap: createdTap, enable: true)
                }
            }

            CFRunLoopRun()

            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            if let tapSource {
                CFRunLoopRemoveSource(
                    currentRunLoop,
                    tapSource,
                    .commonModes
                )
            }
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                currentRunLoop,
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    fileprivate func receivedValue(result: IOReturn, value: IOHIDValue) {
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
    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let loop = Unmanaged<Loop>.fromOpaque(refcon).takeUnretainedValue()
    let suppress = loop.shouldSuppressScroll()
    // Reported after the decision so the sample says what actually happened,
    // and only when someone asked: the Precision path passes no observer and
    // is unchanged by this.
    if let observe = loop.scrollTapObserver {
        observe(ScrollTapSample(
            deltaAxis1: Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
            deltaAxis2: Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            wasSuppressed: suppress
        ))
    }
    return suppress ? nil : Unmanaged.passUnretained(event)
}

import Foundation
import MXErgoHIDPP
import Testing
@testable import MXErgoPrecisionRuntimeAdmission
@testable import MXErgoPrecisionRuntimeComposition
@testable import MXErgoPrecisionRuntimeJournal

@Test func admissionOrdersAuthorizationLeaseHandoffBootstrapStartAndOperation()
    async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let now: UInt64 = 100
    let intent = try fixture.intent(operation: .activate, deadline: 200)
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: now
    )
    let events = AdmissionEventRecorder()
    let handoff = ExactAdmissionHandoff(intent: intent, events: events)
    let configuration = admissionConfiguration(
        intent: intent,
        authorization: authorization,
        handoff: handoff,
        events: events
    )

    let admission = try await PrecisionRuntimeAdmissionFactory.admit(
        configuration: configuration,
        inspect: { request in
            events.record("inspect")
            return try PrecisionRuntimeJournalBootstrap.inspect(request)
        },
        acquireLease: { url in
            events.record("lease")
            return try MXErgoDeviceOperationLease.acquire(beside: url)
        },
        bootstrap: { request, lease in
            events.record("bootstrap")
            return try await PrecisionRuntimeJournalBootstrap.prepare(
                request,
                operationLease: lease
            )
        },
        makeRuntime: { configuration in
            events.record("runtime-make")
            return AdmissionFakeRuntime(
                context: configuration.journalContext,
                events: events
            )
        }
    )

    #expect(await admission.state == .active)
    #expect(events.values == [
        "inspect",
        "scan",
        "lease",
        "inspect",
        "handoff",
        "scan",
        "bootstrap",
        "runtime-make",
        "activate",
    ])
    #expect(throws: MXErgoDeviceOperationLeaseError.unavailable) {
        _ = try MXErgoDeviceOperationLease.acquire(
            beside: fixture.runtimeURL
        )
    }

    let report = await admission.shutdown()
    #expect(report.disposition == .recoveryRequired(.active))
    #expect(events.values.last == "shutdown")
    let released = try MXErgoDeviceOperationLease.acquire(
        beside: fixture.runtimeURL
    )
    #expect(released.protects(journalURL: fixture.runtimeURL))
}

@Test func explicitAuthorizationIsRequiredExpiredOneUseAndCrossLaunchBound()
    async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 200)

    #expect(throws: PrecisionRuntimeAdmissionError
        .explicitConfirmationRequired) {
        _ = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
            for: intent,
            explicitlyConfirmed: false,
            nowUptimeNanoseconds: 100
        )
    }
    #expect(throws: PrecisionRuntimeAdmissionError.authorizationExpired) {
        _ = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
            for: intent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 201
        )
    }

    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 100
    )
    let otherIntent = try PrecisionRuntimeAdmissionReview.makeIntent(
        launchID: UUID(),
        observerRunID: fixture.observerRunID,
        operation: .activate,
        readiness: fixture.readiness,
        session: fixture.session,
        rootGeneration: fixture.rootGeneration,
        sourceBaselineURL: fixture.sourceURL,
        runtimeJournalURL: fixture.runtimeURL,
        expiresAtUptimeNanoseconds: 200
    )
    let effects = AdmissionCounter()
    let configuration = admissionConfiguration(
        intent: otherIntent,
        authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: otherIntent),
        effects: effects
    )
    await expectAdmissionFailure(stage: .authorization) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { _ in effects.increment(); return nil },
            acquireLease: { _ in
                effects.increment()
                return try MXErgoDeviceOperationLease.acquire(
                    beside: fixture.runtimeURL
                )
            },
            bootstrap: { _, _ in
                effects.increment()
                throw AdmissionTestError.unused
            },
            makeRuntime: { _ in
                effects.increment()
                throw AdmissionTestError.unused
            }
        )
    }
    #expect(effects.value == 0)

    await expectAdmissionFailure(stage: .authorization) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { _ in effects.increment(); return nil },
            acquireLease: { _ in throw AdmissionTestError.unused },
            bootstrap: { _, _ in throw AdmissionTestError.unused },
            makeRuntime: { _ in throw AdmissionTestError.unused }
        )
    }
    #expect(effects.value == 0)
}

@Test func observerRunIdentityIsBoundIntoAuthorizationAndHandoffReceipts()
    async throws
{
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    #expect(throws: PrecisionRuntimeAdmissionError.invalidAuthorizationBinding) {
        _ = try PrecisionRuntimeAdmissionReview.makeIntent(
            launchID: UUID(),
            observerRunID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000000"
            )!,
            operation: .activate,
            readiness: fixture.readiness,
            session: fixture.session,
            rootGeneration: fixture.rootGeneration,
            sourceBaselineURL: fixture.sourceURL,
            runtimeJournalURL: fixture.runtimeURL,
            expiresAtUptimeNanoseconds: 200
        )
    }

    let intent = try fixture.intent(operation: .activate, deadline: 200)
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 100
    )
    let otherRunIntent = try fixture.intent(
        operation: .activate,
        deadline: 200,
        observerRunID: UUID()
    )
    let effects = AdmissionCounter()
    let configuration = admissionConfiguration(
        intent: otherRunIntent,
        authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: otherRunIntent),
        effects: effects
    )
    await expectAdmissionFailure(stage: .authorization) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { _ in effects.increment(); return nil },
            acquireLease: { _ in
                effects.increment()
                throw AdmissionTestError.unused
            },
            bootstrap: { _, _ in
                effects.increment()
                throw AdmissionTestError.unused
            },
            makeRuntime: { _ in
                effects.increment()
                throw AdmissionTestError.unused
            }
        )
    }
    #expect(effects.value == 0)

    let handoffFixture = try admissionFixture()
    defer { handoffFixture.cleanup() }
    let handoffIntent = try handoffFixture.intent(
        operation: .activate,
        deadline: 200
    )
    let handoffAuthorization = try
        PrecisionRuntimeAdmissionAuthorizationFactory.issue(
            for: handoffIntent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 100
        )
    let wrongRunHandoff = ExactAdmissionHandoff(
        intent: handoffIntent,
        observerRunIDOverride: UUID()
    )
    let handoffEffects = AdmissionCounter()
    let handoffConfiguration = admissionConfiguration(
        intent: handoffIntent,
        authorization: handoffAuthorization,
        handoff: wrongRunHandoff,
        effects: handoffEffects
    )
    await expectAdmissionFailure(stage: .hostHandoff) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: handoffConfiguration,
            inspect: { request in
                try PrecisionRuntimeJournalBootstrap.inspect(request)
            },
            acquireLease: {
                try MXErgoDeviceOperationLease.acquire(beside: $0)
            },
            bootstrap: { _, _ in
                handoffEffects.increment()
                throw AdmissionTestError.unused
            },
            makeRuntime: { _ in
                handoffEffects.increment()
                throw AdmissionTestError.unused
            }
        )
    }
    #expect(handoffEffects.value == 0)
}

@Test func changedJournalEvidenceAndEarlyCompetitorHaveZeroHostOrHardwareEffects()
    async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 200)
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 100
    )
    try Data("changed".utf8).write(to: fixture.sourceURL)
    let effects = AdmissionCounter()
    let configuration = admissionConfiguration(
        intent: intent,
        authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: intent),
        effects: effects
    )
    await expectAdmissionFailure(stage: .authorization) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { request in
                try PrecisionRuntimeJournalBootstrap.inspect(request)
            },
            acquireLease: { _ in effects.increment(); throw AdmissionTestError.unused },
            bootstrap: { _, _ in effects.increment(); throw AdmissionTestError.unused },
            makeRuntime: { _ in effects.increment(); throw AdmissionTestError.unused }
        )
    }
    #expect(effects.value == 0)

    let competitorFixture = try admissionFixture()
    defer { competitorFixture.cleanup() }
    let competitorIntent = try competitorFixture.intent(
        operation: .activate,
        deadline: 200
    )
    let competitorAuthorization = try
        PrecisionRuntimeAdmissionAuthorizationFactory.issue(
            for: competitorIntent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 100
        )
    let hostOrHardwareEffects = AdmissionCounter()
    let competitorConfiguration = PrecisionRuntimeAdmissionConfiguration(
        intent: competitorIntent,
        authorization: competitorAuthorization,
        hostHandoff: ExactAdmissionHandoff(intent: competitorIntent),
        competitorProbe: { [hostOrHardwareEffects] in
            _ = hostOrHardwareEffects
            return ["BetterTouchTool"]
        },
        sessionProvider: { competitorFixture.session },
        rootGenerationProvider: { competitorFixture.rootGeneration },
        nowProvider: { 100 }
    )
    await expectAdmissionFailure(stage: .competitorScan) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: competitorConfiguration,
            inspect: { request in
                try PrecisionRuntimeJournalBootstrap.inspect(request)
            },
            acquireLease: { _ in
                hostOrHardwareEffects.increment()
                throw AdmissionTestError.unused
            },
            bootstrap: { _, _ in
                hostOrHardwareEffects.increment()
                throw AdmissionTestError.unused
            },
            makeRuntime: { _ in
                hostOrHardwareEffects.increment()
                throw AdmissionTestError.unused
            }
        )
    }
    #expect(hostOrHardwareEffects.value == 0)
}

@Test func wrongLeaseAndInvalidHandoffFailBeforeBootstrapAndAcquisition()
    async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 200)
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 100
    )
    let effects = AdmissionCounter()
    let configuration = admissionConfiguration(
        intent: intent,
        authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: intent),
        effects: effects
    )
    let wrongURL = fixture.directory
        .appendingPathComponent("other", isDirectory: true)
        .appendingPathComponent("runtime.json")
    await expectAdmissionFailure(stage: .operationLease) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { request in
                try PrecisionRuntimeJournalBootstrap.inspect(request)
            },
            acquireLease: { _ in
                try MXErgoDeviceOperationLease.acquire(beside: wrongURL)
            },
            bootstrap: { _, _ in effects.increment(); throw AdmissionTestError.unused },
            makeRuntime: { _ in effects.increment(); throw AdmissionTestError.unused }
        )
    }
    #expect(effects.value == 0)

    let handoffFixture = try admissionFixture()
    defer { handoffFixture.cleanup() }
    let handoffIntent = try handoffFixture.intent(
        operation: .activate,
        deadline: 200
    )
    let handoffAuthorization = try
        PrecisionRuntimeAdmissionAuthorizationFactory.issue(
            for: handoffIntent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 100
        )
    let invalidHandoff = ExactAdmissionHandoff(
        intent: handoffIntent,
        observerDeviceWasClosed: false
    )
    let handoffEffects = AdmissionCounter()
    let handoffConfiguration = admissionConfiguration(
        intent: handoffIntent,
        authorization: handoffAuthorization,
        handoff: invalidHandoff,
        effects: handoffEffects
    )
    await expectAdmissionFailure(stage: .hostHandoff) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: handoffConfiguration,
            inspect: { request in
                try PrecisionRuntimeJournalBootstrap.inspect(request)
            },
            acquireLease: {
                try MXErgoDeviceOperationLease.acquire(beside: $0)
            },
            bootstrap: { _, _ in
                handoffEffects.increment()
                throw AdmissionTestError.unused
            },
            makeRuntime: { _ in
                handoffEffects.increment()
                throw AdmissionTestError.unused
            }
        )
    }
    #expect(handoffEffects.value == 0)
}

@Test func initialOperationFailureSettlesDurableStateAndShutsDownBeforeLeaseRelease()
    async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 200)
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 100
    )
    let events = AdmissionEventRecorder()
    let configuration = admissionConfiguration(
        intent: intent,
        authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: intent, events: events),
        events: events
    )

    await expectAdmissionFailure(stage: .operation) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { request in
                try PrecisionRuntimeJournalBootstrap.inspect(request)
            },
            acquireLease: {
                try MXErgoDeviceOperationLease.acquire(beside: $0)
            },
            bootstrap: { request, lease in
                try await PrecisionRuntimeJournalBootstrap.prepare(
                    request,
                    operationLease: lease
                )
            },
            makeRuntime: { configuration in
                AdmissionFakeRuntime(
                    context: configuration.journalContext,
                    events: events,
                    activationFailure: .operation
                )
            }
        )
    }
    #expect(events.values.suffix(2) == ["activate", "shutdown"])
    let released = try MXErgoDeviceOperationLease.acquire(
        beside: fixture.runtimeURL
    )
    #expect(released.protects(journalURL: fixture.runtimeURL))
}

@Test func activeRuntimeRequiresAFreshExactAuthorizationToRestore() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let initialIntent = try fixture.intent(
        operation: .activate,
        deadline: 200
    )
    let initialAuthorization = try
        PrecisionRuntimeAdmissionAuthorizationFactory.issue(
            for: initialIntent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 100
        )
    let events = AdmissionEventRecorder()
    let configuration = admissionConfiguration(
        intent: initialIntent,
        authorization: initialAuthorization,
        handoff: ExactAdmissionHandoff(
            intent: initialIntent,
            events: events
        ),
        events: events
    )
    let admission = try await PrecisionRuntimeAdmissionFactory.admit(
        configuration: configuration,
        inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
        acquireLease: {
            try MXErgoDeviceOperationLease.acquire(beside: $0)
        },
        bootstrap: { request, lease in
            try await PrecisionRuntimeJournalBootstrap.prepare(
                request,
                operationLease: lease
            )
        },
        makeRuntime: { configuration in
            AdmissionFakeRuntime(
                context: configuration.journalContext,
                events: events
            )
        }
    )
    #expect(await admission.state == .active)

    let restoreIntent = try await admission.reviewIntent(
        for: .deactivate,
        expiresAtUptimeNanoseconds: 300
    )
    let restoreAuthorization = try
        PrecisionRuntimeAdmissionAuthorizationFactory.issue(
            for: restoreIntent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 200
        )
    try await admission.perform(
        restoreIntent,
        authorization: restoreAuthorization
    )
    #expect(await admission.state == .restored)
    #expect(events.count("activate") == 1)
    #expect(events.count("deactivate") == 1)

    await #expect(throws: PrecisionRuntimeAdmissionError
        .authorizationAlreadyConsumed) {
        try await admission.perform(
            restoreIntent,
            authorization: restoreAuthorization
        )
    }
    let report = await admission.shutdown()
    #expect(report.disposition == .clean(.restored))
}

@Test func completedRuntimeJournalCannotBeReactivatedOrRecreated() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    var setupLease: MXErgoDeviceOperationLease? = try
        MXErgoDeviceOperationLease.acquire(
        beside: fixture.runtimeURL
    )
    let request = fixture.bootstrapRequest()
    let context = try await PrecisionRuntimeJournalBootstrap.prepare(
        request,
        operationLease: try #require(setupLease)
    )
    var envelope = context.snapshot.envelope
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .armApply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            intended: fixture.readiness.plan.activeState,
            attemptID: UUID(),
            now: Date()
        )
    ).envelope
    _ = try await context.source.commit(envelope, expectedRevision: 0)
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .observeApply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            state: fixture.readiness.plan.activeState,
            now: Date()
        )
    ).envelope
    _ = try await context.source.commit(envelope, expectedRevision: 1)
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .armRestore(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            attemptID: UUID(),
            now: Date()
        )
    ).envelope
    _ = try await context.source.commit(envelope, expectedRevision: 2)
    envelope = try DeviceTransactionReducer.reduce(
        envelope,
        event: .observeRestore(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            state: fixture.readiness.plan.baseline,
            now: Date()
        )
    ).envelope
    _ = try await context.source.commit(envelope, expectedRevision: 3)
    let completedBytes = try Data(contentsOf: fixture.runtimeURL)
    setupLease = nil

    let intent = try fixture.intent(operation: .activate, deadline: 200)
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 100
    )
    let configuration = admissionConfiguration(
        intent: intent,
        authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: intent)
    )
    await expectAdmissionFailure(stage: .stateValidation) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
            acquireLease: {
                try MXErgoDeviceOperationLease.acquire(beside: $0)
            },
            bootstrap: { request, operationLease in
                try await PrecisionRuntimeJournalBootstrap.prepare(
                    request,
                    operationLease: operationLease
                )
            },
            makeRuntime: { _ in throw AdmissionTestError.unused }
        )
    }
    #expect(try Data(contentsOf: fixture.runtimeURL) == completedBytes)
}

@Test func authorizationExpiryAfterHandoffPreventsBootstrapAndRuntimeCreation()
    async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let clock = AdmissionClock(now: 100)
    let intent = try fixture.intent(operation: .activate, deadline: 200)
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 100
    )
    let effects = AdmissionCounter()
    let handoff = AdvancingAdmissionHandoff(
        clock: clock,
        advancedNow: 201
    )
    let configuration = admissionConfiguration(
        intent: intent,
        authorization: authorization,
        handoff: handoff,
        effects: effects,
        nowProvider: { clock.value }
    )

    await expectAdmissionFailure(stage: .hostHandoff) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
            acquireLease: {
                try MXErgoDeviceOperationLease.acquire(beside: $0)
            },
            bootstrap: { _, _ in
                effects.increment()
                throw AdmissionTestError.unused
            },
            makeRuntime: { _ in
                effects.increment()
                throw AdmissionTestError.unused
            }
        )
    }
    #expect(effects.value == 0)
    let released = try MXErgoDeviceOperationLease.acquire(
        beside: fixture.runtimeURL
    )
    #expect(released.protects(journalURL: fixture.runtimeURL))
}

@Test func bootstrapMustReturnTheExactAuthorizedDisposition() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 200)
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 100
    )
    let runtimeCreations = AdmissionCounter()
    let configuration = admissionConfiguration(
        intent: intent,
        authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: intent)
    )

    await expectAdmissionFailure(stage: .stateValidation) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
            acquireLease: {
                try MXErgoDeviceOperationLease.acquire(beside: $0)
            },
            bootstrap: { request, lease in
                let context = try await PrecisionRuntimeJournalBootstrap.prepare(
                    request,
                    operationLease: lease
                )
                return PrecisionRuntimeJournalContext(
                    plan: context.plan,
                    session: context.session,
                    rootGeneration: context.rootGeneration,
                    sourceBaselineSHA256: context.sourceBaselineSHA256,
                    sourceBaselineTransactionID:
                        context.sourceBaselineTransactionID,
                    source: context.source,
                    snapshot: context.snapshot,
                    disposition: .reused(.prepared)
                )
            },
            makeRuntime: { _ in
                runtimeCreations.increment()
                throw AdmissionTestError.unused
            }
        )
    }
    #expect(runtimeCreations.value == 0)
}

@Test func shutdownDuringAuthorizedOperationCannotBeOverwrittenByItsResume()
    async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let initialIntent = try fixture.intent(
        operation: .activate,
        deadline: 200
    )
    let initialAuthorization = try
        PrecisionRuntimeAdmissionAuthorizationFactory.issue(
            for: initialIntent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 100
        )
    let events = AdmissionEventRecorder()
    let operationGate = AdmissionAsyncGate()
    let configuration = admissionConfiguration(
        intent: initialIntent,
        authorization: initialAuthorization,
        handoff: ExactAdmissionHandoff(intent: initialIntent),
        events: events
    )
    let admission = try await PrecisionRuntimeAdmissionFactory.admit(
        configuration: configuration,
        inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
        acquireLease: {
            try MXErgoDeviceOperationLease.acquire(beside: $0)
        },
        bootstrap: { request, lease in
            try await PrecisionRuntimeJournalBootstrap.prepare(
                request,
                operationLease: lease
            )
        },
        makeRuntime: { configuration in
            AdmissionFakeRuntime(
                context: configuration.journalContext,
                events: events,
                deactivationGate: operationGate
            )
        }
    )
    let intent = try await admission.reviewIntent(
        for: .deactivate,
        expiresAtUptimeNanoseconds: 300
    )
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent,
        explicitlyConfirmed: true,
        nowUptimeNanoseconds: 100
    )
    let operation = Task {
        try await admission.perform(intent, authorization: authorization)
    }
    await waitForEvent("deactivate", in: events)
    let report = await admission.shutdown()
    await operationGate.open()

    do {
        try await operation.value
        Issue.record("Expected the resumed operation to fail after shutdown")
    } catch let failure as PrecisionRuntimeAdmissionFailure {
        #expect(failure.stage == .operation)
        #expect(failure.shutdownReport == report)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(await admission.state == .stopped(report.disposition))
}

@Test func reviewIntentCannotEscapeAfterShutdownBegins() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let initialIntent = try fixture.intent(
        operation: .activate,
        deadline: 200
    )
    let initialAuthorization = try
        PrecisionRuntimeAdmissionAuthorizationFactory.issue(
            for: initialIntent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 100
        )
    let events = AdmissionEventRecorder()
    let reviewGate = AdmissionAsyncGate()
    let configuration = PrecisionRuntimeAdmissionConfiguration(
        intent: initialIntent,
        authorization: initialAuthorization,
        hostHandoff: ExactAdmissionHandoff(intent: initialIntent),
        competitorProbe: { [] },
        sessionProvider: {
            events.record("review-session")
            await reviewGate.wait()
            return initialIntent.session
        },
        rootGenerationProvider: { initialIntent.rootGeneration },
        nowProvider: { 100 }
    )
    let admission = try await PrecisionRuntimeAdmissionFactory.admit(
        configuration: configuration,
        inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
        acquireLease: {
            try MXErgoDeviceOperationLease.acquire(beside: $0)
        },
        bootstrap: { request, lease in
            try await PrecisionRuntimeJournalBootstrap.prepare(
                request,
                operationLease: lease
            )
        },
        makeRuntime: { configuration in
            AdmissionFakeRuntime(
                context: configuration.journalContext,
                events: events
            )
        }
    )
    let review = Task {
        try await admission.reviewIntent(
            for: .deactivate,
            expiresAtUptimeNanoseconds: 300
        )
    }
    await waitForEvent("review-session", in: events)
    let report = await admission.shutdown()
    await reviewGate.open()

    await #expect(throws: PrecisionRuntimeAdmissionError.stopped) {
        _ = try await review.value
    }
    #expect(await admission.state == .stopped(report.disposition))
}

@Test func initialOperationSelectsRecoverForActiveRuntimeAndActivateWhenAbsent()
    throws
{
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    #expect(try PrecisionRuntimeAdmissionReview.initialOperation(for: nil) == .activate)

    let journal = try JSONDecoder().decode(
        DeviceStateJournal.self,
        from: fixture.sourceData
    )
    let prepared = try DeviceTransactionEnvelope(baselineJournal: journal)
    #expect(try PrecisionRuntimeAdmissionReview.initialOperation(
        for: admissionSnapshot(prepared)
    ) == .activate)

    var active = try DeviceTransactionReducer.reduce(
        prepared,
        event: .armApply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            intended: fixture.readiness.plan.activeState,
            attemptID: UUID(),
            now: Date()
        )
    ).envelope
    active = try DeviceTransactionReducer.reduce(
        active,
        event: .observeApply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            state: fixture.readiness.plan.activeState,
            now: Date()
        )
    ).envelope
    #expect(try PrecisionRuntimeAdmissionReview.initialOperation(
        for: admissionSnapshot(active)
    ) == .recover)

    let restoreAttemptID = UUID()
    var unknownRestore = try DeviceTransactionReducer.reduce(
        active,
        event: .armRestore(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            attemptID: restoreAttemptID,
            now: Date()
        )
    ).envelope
    unknownRestore = try DeviceTransactionReducer.reduce(
        unknownRestore,
        event: .recordInvocationOutcome(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            attemptID: restoreAttemptID,
            outcome: .outcomeUnknown,
            detail: "restore lost",
            now: Date()
        )
    ).envelope
    #expect(unknownRestore.hasAmbiguousRestoreSET)
    #expect(throws: PrecisionRuntimeAdmissionError.actionNotPermitted) {
        try validateAction(
            .recover,
            snapshot: admissionSnapshot(unknownRestore),
            permitsDeactivate: false
        )
    }
}

@Test func recoverAdmissionOnANewEpochCallsRecoverNotActivate() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let events = AdmissionEventRecorder()
    let activateIntent = try fixture.intent(operation: .activate, deadline: 200)
    let activateAuthorization = try PrecisionRuntimeAdmissionAuthorizationFactory
        .issue(
            for: activateIntent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 100
        )
    let first = try await PrecisionRuntimeAdmissionFactory.admit(
        configuration: admissionConfiguration(
            intent: activateIntent,
            authorization: activateAuthorization,
            handoff: ExactAdmissionHandoff(intent: activateIntent, events: events),
            events: events
        ),
        inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
        acquireLease: { try MXErgoDeviceOperationLease.acquire(beside: $0) },
        bootstrap: { request, lease in
            try await PrecisionRuntimeJournalBootstrap.prepare(
                request,
                operationLease: lease
            )
        },
        makeRuntime: { configuration in
            AdmissionFakeRuntime(
                context: configuration.journalContext,
                events: events
            )
        }
    )
    _ = await first.shutdown()

    let recoverIntent = try fixture.intent(operation: .recover, deadline: 400)
    let recoverAuthorization = try PrecisionRuntimeAdmissionAuthorizationFactory
        .issue(
            for: recoverIntent,
            explicitlyConfirmed: true,
            nowUptimeNanoseconds: 300
        )
    let recovered = try await PrecisionRuntimeAdmissionFactory.admit(
        configuration: admissionConfiguration(
            intent: recoverIntent,
            authorization: recoverAuthorization,
            handoff: ExactAdmissionHandoff(intent: recoverIntent, events: events),
            events: events
        ),
        inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
        acquireLease: { try MXErgoDeviceOperationLease.acquire(beside: $0) },
        bootstrap: { request, lease in
            try await PrecisionRuntimeJournalBootstrap.prepare(
                request,
                operationLease: lease
            )
        },
        makeRuntime: { configuration in
            AdmissionFakeRuntime(
                context: configuration.journalContext,
                events: events
            )
        }
    )
    #expect(await recovered.state == .restored)
    #expect(events.values.contains("recover"))
    #expect(events.count("activate") == 1)
    _ = await recovered.shutdown()
}

@Test func exactActionPolicyRejectsTerminalAndUnrelatedDirtyStates() throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let journal = try JSONDecoder().decode(
        DeviceStateJournal.self,
        from: fixture.sourceData
    )
    let prepared = try DeviceTransactionEnvelope(baselineJournal: journal)
    try validateAction(
        .activate,
        snapshot: admissionSnapshot(prepared),
        permitsDeactivate: false
    )
    #expect(throws: PrecisionRuntimeAdmissionError.actionNotPermitted) {
        try validateAction(
            .deactivate,
            snapshot: admissionSnapshot(prepared),
            permitsDeactivate: true
        )
    }

    let applyAttempt = UUID()
    let armedApply = try DeviceTransactionReducer.reduce(
        prepared,
        event: .armApply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            intended: fixture.readiness.plan.activeState,
            attemptID: applyAttempt,
            now: Date()
        )
    ).envelope
    try validateAction(
        .recover,
        snapshot: admissionSnapshot(armedApply),
        permitsDeactivate: false
    )
    let active = try DeviceTransactionReducer.reduce(
        armedApply,
        event: .observeApply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            state: fixture.readiness.plan.activeState,
            now: Date()
        )
    ).envelope
    try validateAction(
        .recover,
        snapshot: admissionSnapshot(active),
        permitsDeactivate: false
    )
    try validateAction(
        .deactivate,
        snapshot: admissionSnapshot(active),
        permitsDeactivate: true
    )

    let rejectedAttempt = UUID()
    var abortedClean = try DeviceTransactionReducer.reduce(
        prepared,
        event: .armApply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            intended: fixture.readiness.plan.activeState,
            attemptID: rejectedAttempt,
            now: Date()
        )
    ).envelope
    abortedClean = try DeviceTransactionReducer.reduce(
        abortedClean,
        event: .recordInvocationOutcome(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            attemptID: rejectedAttempt,
            outcome: .rejectedBeforeDispatch,
            detail: "matrix",
            now: Date()
        )
    ).envelope
    abortedClean = try DeviceTransactionReducer.reduce(
        abortedClean,
        event: .observeApply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            state: fixture.readiness.plan.baseline,
            now: Date()
        )
    ).envelope
    #expect(abortedClean.status == .abortedClean)
    #expect(throws: PrecisionRuntimeAdmissionError.actionNotPermitted) {
        try validateAction(
            .activate,
            snapshot: admissionSnapshot(abortedClean),
            permitsDeactivate: true
        )
    }

    let restoreAttempt = UUID()
    var completed = try DeviceTransactionReducer.reduce(
        active,
        event: .armRestore(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            attemptID: restoreAttempt,
            now: Date()
        )
    ).envelope
    completed = try DeviceTransactionReducer.reduce(
        completed,
        event: .observeRestore(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            state: fixture.readiness.plan.baseline,
            now: Date()
        )
    ).envelope
    #expect(completed.status == .completed)
    for operation in [
        PrecisionTemporaryDiversionOperation.activate,
        .deactivate,
        .recover,
    ] {
        #expect(throws: PrecisionRuntimeAdmissionError.actionNotPermitted) {
            try validateAction(
                operation,
                snapshot: admissionSnapshot(completed),
                permitsDeactivate: true
            )
        }
    }

    let conflictState = try fixture.readiness.plan.baseline
        .replacingRawFlags(0x00FF, featureVersion: 3)
    let conflicted = try DeviceTransactionReducer.reduce(
        armedApply,
        event: .observeApply(
            controlID: PrecisionTemporaryDiversionPlan.controlID,
            state: conflictState,
            now: Date()
        )
    ).envelope
    #expect(conflicted.status == .conflicted)
    #expect(throws: PrecisionRuntimeAdmissionError.actionNotPermitted) {
        try validateAction(
            .recover,
            snapshot: admissionSnapshot(conflicted),
            permitsDeactivate: true
        )
    }

    let multiFixture = try admissionFixture(includeUnrelatedControl: true)
    defer { multiFixture.cleanup() }
    let multiJournal = try JSONDecoder().decode(
        DeviceStateJournal.self,
        from: multiFixture.sourceData
    )
    let multiPrepared = try DeviceTransactionEnvelope(
        baselineJournal: multiJournal
    )
    let unrelatedID: UInt16 = 0x00C3
    let unrelatedBaseline = try multiPrepared.control(unrelatedID).baseline
    let unrelatedIntended = try unrelatedBaseline.replacingRawFlags(
        1,
        featureVersion: 3
    )
    let unrelatedDirty = try DeviceTransactionReducer.reduce(
        multiPrepared,
        event: .armApply(
            controlID: unrelatedID,
            intended: unrelatedIntended,
            attemptID: UUID(),
            now: Date()
        )
    ).envelope
    #expect(unrelatedDirty.status == .recoveryRequired)
    #expect(throws: PrecisionRuntimeAdmissionError.actionNotPermitted) {
        try validateAction(
            .recover,
            snapshot: admissionSnapshot(unrelatedDirty),
            permitsDeactivate: true
        )
    }
}

@Test func admissionTargetIsProductlessUnwiredAndCapabilityMinimal() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let projectRoot = packageRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifest = try String(
        contentsOf: packageRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    // The boundary is line-anchored. Splitting on a bare "targets: ["
    // truncates at the first *product's* targets list, which left this
    // check scanning two lines of the manifest.
    let products = try #require(
        manifest.split(separator: "\n    targets: [", maxSplits: 1).first
    )
    #expect(!products.contains("MXErgoPrecisionRuntimeAdmission"))
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionRuntimeAdmission\""
    ).count - 1 == 8)
    #expect(manifest.components(
        separatedBy: "\"MXErgoPrecisionRuntimeAdmissionTests\""
    ).count - 1 == 1)

    let projectYAML = try String(
        contentsOf: projectRoot.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    let projectFile = try String(
        contentsOf: projectRoot
            .appendingPathComponent("MXErgoController.xcodeproj")
            .appendingPathComponent("project.pbxproj"),
        encoding: .utf8
    )
    #expect(!projectYAML.contains("MXErgoPrecisionRuntimeAdmission"))
    #expect(!projectFile.contains("MXErgoPrecisionRuntimeAdmission"))

    let source = try sourceText(
        under: packageRoot.appendingPathComponent(
            "Sources/MXErgoPrecisionRuntimeAdmission"
        )
    )
    for required in [
        "authorization.consume(",
        "MXErgoDeviceOperationLease.acquire(",
        "hostHandoff.stopAndWait(",
        "expectedObserverRunID:",
        "receipt.observerRunID == intent.observerRunID",
        "PrecisionRuntimeJournalBootstrap.prepare(",
        "PrecisionRuntimeCompositionFactory.make(",
        "operationLease.protects(",
        "await runtime.shutdown()",
        "deviceDisconnectHandler",
        "initialOperation(",
    ] {
        #expect(source.contains(required))
    }
    for forbidden in [
        "import IOKit",
        "IOHIDManager",
        "IOHIDDeviceOpen(",
        "IOHIDDeviceClose(",
        "SetReport",
        "@main",
        "UserDefaults",
        ": Codable",
        "public ",
        "@_spi",
    ] {
        #expect(!source.contains(forbidden))
    }
}

private enum AdmissionTestError: Error, Sendable {
    case operation
    case unused
}

private struct AdmissionFixture {
    let directory: URL
    let sourceURL: URL
    let runtimeURL: URL
    let sourceData: Data
    let readiness: PrecisionTemporaryDiversionReadinessSnapshot
    let session: DeviceTransactionSession
    let rootGeneration: UInt64
    let observerRunID: UUID

    func intent(
        operation: PrecisionTemporaryDiversionOperation,
        deadline: UInt64,
        observerRunID: UUID? = nil
    ) throws -> PrecisionRuntimeAdmissionIntent {
        try PrecisionRuntimeAdmissionReview.makeIntent(
            launchID: UUID(),
            observerRunID: observerRunID ?? self.observerRunID,
            operation: operation,
            readiness: readiness,
            session: session,
            rootGeneration: rootGeneration,
            sourceBaselineURL: sourceURL,
            runtimeJournalURL: runtimeURL,
            expiresAtUptimeNanoseconds: deadline
        )
    }

    func bootstrapRequest() -> PrecisionRuntimeJournalBootstrapRequest {
        PrecisionRuntimeJournalBootstrapRequest(
            plan: readiness.plan,
            session: session,
            rootGeneration: rootGeneration,
            sourceBaselineURL: sourceURL,
            sourceBaselineSHA256: readiness.sourceJournalSHA256,
            sourceBaselineTransactionID: readiness.sourceBaselineTransactionID,
            runtimeJournalURL: runtimeURL
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private func admissionFixture(
    includeUnrelatedControl: Bool = false
) throws -> AdmissionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "precision-runtime-admission-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let device = JournalDeviceIdentity(
        deviceID: "1133-45085-29-1-2",
        vendorID: 0x046D,
        productID: 0xB01D,
        transport: "Bluetooth Low Energy",
        serialNumber: "RUNTIME-ADMISSION-TEST",
        locationID: 29,
        firmwareIdentity: "runtime-admission-test-firmware"
    )
    let control = try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: 5,
            controlID: 0x00ED,
            taskID: 0x00C4,
            capabilityFlags: 0x71,
            position: 0,
            group: 1,
            groupMask: 1,
            rawXYCapability: false,
            rawParameters: admissionPadded([0x00, 0xED])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: 0x00ED,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: admissionPadded([0x00, 0xED, 0, 0, 0])
        )
    )
    let unrelatedControl = try DeviceControlJournalEntry(
        controlInfo: ReprogControlInfo(
            index: 6,
            controlID: 0x00C3,
            taskID: 0x00C3,
            capabilityFlags: 0x01,
            position: 1,
            group: 1,
            groupMask: 1,
            rawXYCapability: false,
            rawParameters: admissionPadded([0x00, 0xC3])
        ),
        baselineReporting: ReprogControlReportingState(
            controlID: 0x00C3,
            rawFlags: 0,
            rawMappedControlID: 0,
            rawParameters: admissionPadded([0x00, 0xC3, 0, 0, 0])
        )
    )
    let feature = HIDPP20FeatureDescriptor(
        index: 0x0A,
        type: 0,
        version: 3,
        rawParameters: admissionPadded([0x0A, 0, 3])
    )
    let controls = includeUnrelatedControl
        ? [control, unrelatedControl]
        : [control]
    let journal = try DeviceStateJournal(
        transactionID: UUID(),
        appBuild: "runtime-admission-test",
        device: device,
        feature: feature,
        expectedControlCount: controls.count,
        controls: controls
    )
    let sourceData = try admissionEncoded(journal)
    let sourceURL = directory.appendingPathComponent("device-state-journal.json")
    try sourceData.write(to: sourceURL)
    let plan = try PrecisionTemporaryDiversionPlan.make(
        journal: journal,
        currentFeature: feature,
        deviceIndex: 0,
        softwareID: 0x0E
    )
    let session = DeviceTransactionSession(
        device: device,
        featureID: ReprogControlsV4.featureID,
        featureVersion: feature.version,
        featureIndex: feature.index,
        connectionEpoch: 71
    )
    let rootGeneration: UInt64 = 44
    let readiness = PrecisionTemporaryDiversionReadinessSnapshot(
        plan: plan,
        sourceJournalSHA256:
            PrecisionTemporaryDiversionReadinessAudit.sourceJournalSHA256(
                sourceData
            ),
        sourceBaselineTransactionID: journal.transactionID,
        connectionGeneration: rootGeneration,
        connectionEpoch: session.connectionEpoch,
        authorization: .notAuthorizedForExecution
    )
    return AdmissionFixture(
        directory: directory,
        sourceURL: sourceURL,
        runtimeURL: directory.appendingPathComponent(
            "precision-runtime-v3.json"
        ),
        sourceData: sourceData,
        readiness: readiness,
        session: session,
        rootGeneration: rootGeneration,
        observerRunID: UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!
    )
}

private func admissionConfiguration(
    intent: PrecisionRuntimeAdmissionIntent,
    authorization: PrecisionRuntimeAdmissionAuthorization,
    handoff: any PrecisionRuntimeHostHandoff,
    events: AdmissionEventRecorder? = nil,
    effects: AdmissionCounter? = nil,
    nowProvider: @escaping @Sendable () -> UInt64 = { 100 }
) -> PrecisionRuntimeAdmissionConfiguration {
    PrecisionRuntimeAdmissionConfiguration(
        intent: intent,
        authorization: authorization,
        hostHandoff: handoff,
        competitorProbe: {
            events?.record("scan")
            _ = effects
            return []
        },
        sessionProvider: { intent.session },
        rootGenerationProvider: { intent.rootGeneration },
        nowProvider: nowProvider
    )
}

private struct ExactAdmissionHandoff: PrecisionRuntimeHostHandoff {
    let intent: PrecisionRuntimeAdmissionIntent
    let events: AdmissionEventRecorder?
    let observerDeviceWasClosed: Bool
    let observerRunIDOverride: UUID?

    init(
        intent: PrecisionRuntimeAdmissionIntent,
        events: AdmissionEventRecorder? = nil,
        observerDeviceWasClosed: Bool = true,
        observerRunIDOverride: UUID? = nil
    ) {
        self.intent = intent
        self.events = events
        self.observerDeviceWasClosed = observerDeviceWasClosed
        self.observerRunIDOverride = observerRunIDOverride
    }

    func stopAndWait(
        launchID: UUID,
        expectedSession: DeviceTransactionSession,
        expectedRootGeneration: UInt64,
        expectedObserverRunID: UUID,
        timeoutNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeHostHandoffReceipt {
        _ = timeoutNanoseconds
        events?.record("handoff")
        return PrecisionRuntimeHostHandoffReceipt(
            launchID: launchID,
            session: expectedSession,
            rootGeneration: expectedRootGeneration,
            observerRunID: observerRunIDOverride ?? expectedObserverRunID,
            pendingRequestCount: 0,
            observerWasUnscheduled: true,
            observerDeviceWasClosed: observerDeviceWasClosed
        )
    }
}

private struct AdvancingAdmissionHandoff: PrecisionRuntimeHostHandoff {
    let clock: AdmissionClock
    let advancedNow: UInt64

    func stopAndWait(
        launchID: UUID,
        expectedSession: DeviceTransactionSession,
        expectedRootGeneration: UInt64,
        expectedObserverRunID: UUID,
        timeoutNanoseconds: UInt64
    ) async throws -> PrecisionRuntimeHostHandoffReceipt {
        _ = timeoutNanoseconds
        clock.set(advancedNow)
        return PrecisionRuntimeHostHandoffReceipt(
            launchID: launchID,
            session: expectedSession,
            rootGeneration: expectedRootGeneration,
            observerRunID: expectedObserverRunID,
            pendingRequestCount: 0,
            observerWasUnscheduled: true,
            observerDeviceWasClosed: true
        )
    }
}

private actor AdmissionFakeRuntime: PrecisionRuntimeControlling {
    private let context: PrecisionRuntimeJournalContext
    private let events: AdmissionEventRecorder
    private let activationFailure: AdmissionTestError?
    private let deactivationGate: AdmissionAsyncGate?

    init(
        context: PrecisionRuntimeJournalContext,
        events: AdmissionEventRecorder,
        activationFailure: AdmissionTestError? = nil,
        deactivationGate: AdmissionAsyncGate? = nil
    ) {
        self.context = context
        self.events = events
        self.activationFailure = activationFailure
        self.deactivationGate = deactivationGate
    }

    func lifecycleState() async throws -> PrecisionTemporaryDiversionLifecycleState {
        let envelope = try await context.source.loadValidatedSnapshot().envelope
        return try admissionLifecycleState(envelope)
    }

    func activate() async throws -> DeviceTransactionEnvelope {
        events.record("activate")
        if let activationFailure { throw activationFailure }
        var envelope = try await context.source.loadValidatedSnapshot().envelope
        let oldRevision = envelope.revision
        envelope = try DeviceTransactionReducer.reduce(
            envelope,
            event: .armApply(
                controlID: PrecisionTemporaryDiversionPlan.controlID,
                intended: context.plan.activeState,
                attemptID: UUID(),
                now: Date()
            )
        ).envelope
        _ = try await context.source.commit(
            envelope,
            expectedRevision: oldRevision
        )
        let armedRevision = envelope.revision
        envelope = try DeviceTransactionReducer.reduce(
            envelope,
            event: .observeApply(
                controlID: PrecisionTemporaryDiversionPlan.controlID,
                state: context.plan.activeState,
                now: Date()
            )
        ).envelope
        _ = try await context.source.commit(
            envelope,
            expectedRevision: armedRevision
        )
        return envelope
    }

    func resumeVerified() async throws -> DeviceTransactionEnvelope {
        events.record("resume")
        return try await context.source.loadValidatedSnapshot().envelope
    }

    func deactivate() async throws -> DeviceTransactionEnvelope {
        events.record("deactivate")
        if let deactivationGate { await deactivationGate.wait() }
        var envelope = try await context.source.loadValidatedSnapshot().envelope
        let oldRevision = envelope.revision
        envelope = try DeviceTransactionReducer.reduce(
            envelope,
            event: .armRestore(
                controlID: PrecisionTemporaryDiversionPlan.controlID,
                attemptID: UUID(),
                now: Date()
            )
        ).envelope
        _ = try await context.source.commit(
            envelope,
            expectedRevision: oldRevision
        )
        let armedRevision = envelope.revision
        envelope = try DeviceTransactionReducer.reduce(
            envelope,
            event: .observeRestore(
                controlID: PrecisionTemporaryDiversionPlan.controlID,
                state: context.plan.baseline,
                now: Date()
            )
        ).envelope
        _ = try await context.source.commit(
            envelope,
            expectedRevision: armedRevision
        )
        return envelope
    }

    func recoverExplicitly() async throws -> DeviceTransactionRecoveryReport {
        events.record("recover")
        var envelope = try await context.source.loadValidatedSnapshot().envelope
        let controlID = PrecisionTemporaryDiversionPlan.controlID
        if envelope.dirtyControlIDs.contains(controlID) {
            let oldRevision = envelope.revision
            envelope = try DeviceTransactionReducer.reduce(
                envelope,
                event: .armRestore(
                    controlID: controlID,
                    attemptID: UUID(),
                    now: Date()
                )
            ).envelope
            _ = try await context.source.commit(
                envelope,
                expectedRevision: oldRevision
            )
            let armedRevision = envelope.revision
            envelope = try DeviceTransactionReducer.reduce(
                envelope,
                event: .observeRestore(
                    controlID: controlID,
                    state: context.plan.baseline,
                    now: Date()
                )
            ).envelope
            _ = try await context.source.commit(
                envelope,
                expectedRevision: armedRevision
            )
        }
        return DeviceTransactionRecoveryReport(
            transactionID: envelope.transactionID,
            inspectedControlIDs: [controlID],
            restoredControlIDs: [controlID],
            finalStatus: envelope.status
        )
    }

    func shutdown() async -> PrecisionRuntimeShutdownReport {
        events.record("shutdown")
        do {
            let lifecycle = try await lifecycleState()
            let disposition: PrecisionRuntimeShutdownDisposition
            switch lifecycle {
            case .inactive, .restored:
                disposition = .clean(lifecycle)
            case .active, .recoveryRequired, .conflicted:
                disposition = .recoveryRequired(lifecycle)
            }
            return PrecisionRuntimeShutdownReport(
                disposition: disposition,
                deviceCloseReturn: 0
            )
        } catch {
            return PrecisionRuntimeShutdownReport(
                disposition: .stateUnavailable(String(describing: error)),
                deviceCloseReturn: 0
            )
        }
    }
}

private func admissionLifecycleState(
    _ envelope: DeviceTransactionEnvelope
) throws -> PrecisionTemporaryDiversionLifecycleState {
    let control = try envelope.control(
        PrecisionTemporaryDiversionPlan.controlID
    )
    switch control.phase {
    case .baselineVerified: return .inactive
    case .appliedVerified: return .active
    case .restoredVerified: return .restored
    case .applyMayHaveOccurred, .restoreMayHaveOccurred:
        return .recoveryRequired
    case .conflicted: return .conflicted
    }
}

private func expectAdmissionFailure(
    stage: PrecisionRuntimeAdmissionStage,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected admission failure at \(stage)")
    } catch let failure as PrecisionRuntimeAdmissionFailure {
        #expect(failure.stage == stage)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private final class AdmissionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func count(_ value: String) -> Int {
        lock.withLock { storage.filter { $0 == value }.count }
    }
    func record(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class AdmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class AdmissionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt64

    init(now: UInt64) { storage = now }

    var value: UInt64 { lock.withLock { storage } }
    func set(_ value: UInt64) { lock.withLock { storage = value } }
}

private actor AdmissionAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func waitForEvent(
    _ event: String,
    in recorder: AdmissionEventRecorder
) async {
    for _ in 0..<10_000 {
        if recorder.count(event) > 0 { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for event: \(event)")
}

private func admissionEncoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
}

private func admissionSnapshot(
    _ envelope: DeviceTransactionEnvelope
) -> PrecisionRuntimeJournalSnapshot {
    PrecisionRuntimeJournalSnapshot(
        data: Data(),
        envelope: envelope,
        sha256: String(repeating: "0", count: 64)
    )
}

private func admissionPadded(_ bytes: [UInt8]) -> [UInt8] {
    bytes + Array(
        repeating: 0,
        count: HIDPP20LongMessage.parameterCount - bytes.count
    )
}

private func sourceText(under directory: URL) throws -> String {
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
    )
    let files = enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    return try files.map {
        try String(contentsOf: $0, encoding: .utf8)
    }.joined(separator: "\n")
}


@Test func seamlessRestartPolicyDefaultsOffAndBindsConsentToExactEvidence() throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let off = PrecisionSeamlessRestartConsent(readiness: fixture.readiness)
    #expect(PrecisionSeamlessRestartPolicy.review(consent: nil, readiness: fixture.readiness, runtime: nil) == .disabled)
    #expect(PrecisionSeamlessRestartPolicy.review(consent: off, readiness: fixture.readiness, runtime: nil) == .disabled)
    let on = PrecisionSeamlessRestartConsent(enabled: true, readiness: fixture.readiness)
    let bytes = try JSONEncoder().encode(on)
    #expect(try JSONDecoder().decode(PrecisionSeamlessRestartConsent.self, from: bytes) == on)
    #expect(PrecisionSeamlessRestartPolicy.review(consent: on, readiness: fixture.readiness, runtime: nil) == .activateAfterFreshBaseline)
    for field in ["version", "sourceBaselineSHA256", "sourceBaselineTransactionID", "firmwareIdentity", "deviceID", "serialNumber"] {
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        switch field {
        case "version": object[field] = 2
        case "sourceBaselineSHA256": object[field] = String(repeating: "0", count: 64)
        case "sourceBaselineTransactionID": object[field] = UUID().uuidString
        default:
            var device = try #require(object["device"] as? [String: Any])
            device[field] = "different"
            object["device"] = device
        }
        let changed = try JSONDecoder().decode(PrecisionSeamlessRestartConsent.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(PrecisionSeamlessRestartPolicy.review(consent: changed, readiness: fixture.readiness, runtime: nil) == .reviewRequired)
    }
}

@Test func seamlessRestartPolicyDistinguishesVerifiedResumeFromEveryUncertainPhase() throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let journal = try JSONDecoder().decode(DeviceStateJournal.self, from: fixture.sourceData)
    let prepared = try DeviceTransactionEnvelope(baselineJournal: journal)
    let applyID = UUID()
    let armed = try DeviceTransactionReducer.reduce(prepared, event: .armApply(
        controlID: 0x00ED, intended: fixture.readiness.plan.activeState, attemptID: applyID, now: Date()
    )).envelope
    let active = try DeviceTransactionReducer.reduce(armed, event: .observeApply(
        controlID: 0x00ED, state: fixture.readiness.plan.activeState, now: Date()
    )).envelope
    let restoreID = UUID()
    let restoreArmed = try DeviceTransactionReducer.reduce(active, event: .armRestore(
        controlID: 0x00ED, attemptID: restoreID, now: Date()
    )).envelope
    let completed = try #require(try DeviceTransactionReducer.reduceRecoveryObservation(
        active, controlID: 0x00ED, state: fixture.readiness.plan.baseline
    )).envelope
    let unknownApply = try DeviceTransactionReducer.reduce(armed, event: .recordInvocationOutcome(
        controlID: 0x00ED, attemptID: applyID, outcome: .outcomeUnknown, detail: "lost", now: Date()
    )).envelope
    let unknownRestore = try DeviceTransactionReducer.reduce(restoreArmed, event: .recordInvocationOutcome(
        controlID: 0x00ED, attemptID: restoreID, outcome: .outcomeUnknown, detail: "lost", now: Date()
    )).envelope
    let aborted = try DeviceTransactionReducer.reduce(armed, event: .observeApply(
        controlID: 0x00ED, state: fixture.readiness.plan.baseline, now: Date()
    )).envelope
    var unexpected = fixture.readiness.plan.baseline.rawParameters
    unexpected[15] = 0x80
    let conflicted = try #require(try DeviceTransactionReducer.reduceRecoveryObservation(
        active, controlID: 0x00ED, state: try DeviceTransactionWireState(rawParameters: unexpected)
    )).envelope
    let cases: [(DeviceTransactionEnvelope, PrecisionSeamlessRestartDecision)] = [
        (prepared, .activateAfterFreshBaseline), (active, .resumeWithFreshRead),
        (completed, .archiveCompletedAndRefresh), (armed, .reviewRequired),
        (restoreArmed, .reviewRequired), (unknownApply, .reviewRequired),
        (unknownRestore, .reviewRequired), (aborted, .reviewRequired), (conflicted, .reviewRequired)
    ]
    let consent = PrecisionSeamlessRestartConsent(enabled: true, readiness: fixture.readiness)
    for (envelope, expected) in cases {
        #expect(PrecisionSeamlessRestartPolicy.review(
            consent: consent, readiness: fixture.readiness, runtime: admissionSnapshot(envelope)
        ) == expected)
        if expected == .resumeWithFreshRead {
            try validateAction(.resume, snapshot: admissionSnapshot(envelope), permitsDeactivate: false)
        } else {
            #expect(throws: PrecisionRuntimeAdmissionError.actionNotPermitted) {
                try validateAction(.resume, snapshot: admissionSnapshot(envelope), permitsDeactivate: false)
            }
        }
    }
}

@Test func resumeAdmissionOnNewLaunchAndEpochDoesNotCallActivateOrRecover() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let journal = try JSONDecoder().decode(DeviceStateJournal.self, from: fixture.sourceData)
    let prepared = try DeviceTransactionEnvelope(baselineJournal: journal)
    let armed = try DeviceTransactionReducer.reduce(prepared, event: .armApply(
        controlID: 0x00ED, intended: fixture.readiness.plan.activeState, attemptID: UUID(), now: Date()
    )).envelope
    let active = try DeviceTransactionReducer.reduce(armed, event: .observeApply(
        controlID: 0x00ED, state: fixture.readiness.plan.activeState, now: Date()
    )).envelope
    try admissionEncoded(active).write(to: fixture.runtimeURL)
    let before = try Data(contentsOf: fixture.runtimeURL)
    let original = fixture.session
    let session = DeviceTransactionSession(device: original.device, featureID: original.featureID,
        featureVersion: original.featureVersion, featureIndex: original.featureIndex,
        connectionEpoch: original.connectionEpoch + 1)
    let readiness = PrecisionTemporaryDiversionReadinessSnapshot(
        plan: fixture.readiness.plan, sourceJournalSHA256: fixture.readiness.sourceJournalSHA256,
        sourceBaselineTransactionID: fixture.readiness.sourceBaselineTransactionID,
        connectionGeneration: fixture.rootGeneration + 1, connectionEpoch: session.connectionEpoch,
        authorization: .notAuthorizedForExecution)
    let intent = try PrecisionRuntimeAdmissionReview.makeIntent(
        launchID: UUID(), observerRunID: UUID(), operation: .resume, readiness: readiness,
        session: session, rootGeneration: fixture.rootGeneration + 1,
        sourceBaselineURL: fixture.sourceURL, runtimeJournalURL: fixture.runtimeURL,
        expiresAtUptimeNanoseconds: 400)
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issue(
        for: intent, explicitlyConfirmed: true, nowUptimeNanoseconds: 300)
    let events = AdmissionEventRecorder()
    let configuration = admissionConfiguration(intent: intent, authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: intent, events: events), events: events,
        nowProvider: { 300 })
    let resumed = try await PrecisionRuntimeAdmissionFactory.admit(
        configuration: configuration,
        inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
        acquireLease: { try MXErgoDeviceOperationLease.acquire(beside: $0) },
        bootstrap: { request, lease in
            try await PrecisionRuntimeJournalBootstrap.prepare(request, operationLease: lease)
        },
        makeRuntime: { configuration in
            AdmissionFakeRuntime(context: configuration.journalContext, events: events)
        })
    #expect(await resumed.state == .active)
    #expect(events.count("resume") == 1)
    #expect(events.count("activate") == 0)
    #expect(events.count("recover") == 0)
    #expect(events.count("deactivate") == 0)
    #expect(try Data(contentsOf: fixture.runtimeURL) == before)
    _ = await resumed.shutdown()
    await expectAdmissionFailure(stage: .authorization) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { _ in throw AdmissionTestError.unused },
            acquireLease: { _ in throw AdmissionTestError.unused },
            bootstrap: { _, _ in throw AdmissionTestError.unused },
            makeRuntime: { _ in throw AdmissionTestError.unused })
    }
}

@Test func automaticAuthorizationRequiresBoundConsentAndBurnsEachOperationOnce() throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 400)
    let permit = PrecisionAutomaticRunPermit(consent: PrecisionSeamlessRestartConsent(enabled: true,
        readiness: fixture.readiness), consentIsCurrent: { true })
    _ = try PrecisionRuntimeAdmissionAuthorizationFactory.issueAutomatically(for: intent, permit: permit, nowUptimeNanoseconds: 300)
    #expect(throws: PrecisionAutomaticRunError.operationAlreadyUsed) {
        _ = try PrecisionRuntimeAdmissionAuthorizationFactory.issueAutomatically(for: intent, permit: permit, nowUptimeNanoseconds: 300)
    }
    try permit.claimMutation()
    #expect(permit.revoke())
    // Let an entered write finish its classification; never permit a second.
    try permit.validateInitialOperation()
    #expect(throws: PrecisionAutomaticRunError.rejectedBeforeDispatch) { try permit.claimMutation() }
    #expect(throws: PrecisionAutomaticRunError.revoked) { try permit.validate() }
}

@Test func automaticPermitCannotAuthorizeDisabledChangedOrRevokedConsent() throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 400)
    for mode in 0...2 {
        let permit = PrecisionAutomaticRunPermit(consent: PrecisionSeamlessRestartConsent(enabled: mode != 0,
            readiness: fixture.readiness), consentIsCurrent: { mode != 1 })
        if mode == 2 { #expect(!permit.revoke()) }
        #expect(throws: (any Error).self) {
            _ = try PrecisionRuntimeAdmissionAuthorizationFactory.issueAutomatically(for: intent, permit: permit, nowUptimeNanoseconds: 300)
        }
    }
}

@Test func automaticPermitNeverAuthorizesRecoveryOrDeactivation() throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let permit = PrecisionAutomaticRunPermit(consent: PrecisionSeamlessRestartConsent(enabled: true,
        readiness: fixture.readiness), consentIsCurrent: { true })
    for operation in [PrecisionTemporaryDiversionOperation.recover, .deactivate] {
        #expect(throws: PrecisionAutomaticRunError.invalidConsent) {
            try permit.reserve(operation, readiness: fixture.readiness)
        }
    }
}

@Test func automaticRevocationAfterAuthorizationPreventsAnyHandoff() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 400)
    let permit = PrecisionAutomaticRunPermit(consent: PrecisionSeamlessRestartConsent(enabled: true,
        readiness: fixture.readiness), consentIsCurrent: { true })
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issueAutomatically(for: intent,
        permit: permit, nowUptimeNanoseconds: 300)
    permit.revoke()
    let configuration = admissionConfiguration(intent: intent, authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: intent), nowProvider: { 300 })
    await expectAdmissionFailure(stage: .authorization) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(configuration: configuration,
            inspect: { _ in Issue.record("Inspection entered after revoked authority"); throw AdmissionTestError.unused },
            acquireLease: { _ in Issue.record("Lease entered"); throw AdmissionTestError.unused },
            bootstrap: { _, _ in Issue.record("Bootstrap entered"); throw AdmissionTestError.unused },
            makeRuntime: { _ in Issue.record("Runtime entered"); throw AdmissionTestError.unused })
    }
}

@Test func automaticResumeOnNewLaunchAndEpochNeverActivatesOrRecovers() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let journal = try JSONDecoder().decode(DeviceStateJournal.self, from: fixture.sourceData)
    let prepared = try DeviceTransactionEnvelope(baselineJournal: journal)
    let armed = try DeviceTransactionReducer.reduce(prepared, event: .armApply(
        controlID: 0x00ED, intended: fixture.readiness.plan.activeState, attemptID: UUID(), now: Date()
    )).envelope
    let active = try DeviceTransactionReducer.reduce(armed, event: .observeApply(
        controlID: 0x00ED, state: fixture.readiness.plan.activeState, now: Date()
    )).envelope
    try admissionEncoded(active).write(to: fixture.runtimeURL)
    let before = try Data(contentsOf: fixture.runtimeURL)
    let original = fixture.session
    let session = DeviceTransactionSession(device: original.device, featureID: original.featureID,
        featureVersion: original.featureVersion, featureIndex: original.featureIndex,
        connectionEpoch: original.connectionEpoch + 1)
    let readiness = PrecisionTemporaryDiversionReadinessSnapshot(
        plan: fixture.readiness.plan, sourceJournalSHA256: fixture.readiness.sourceJournalSHA256,
        sourceBaselineTransactionID: fixture.readiness.sourceBaselineTransactionID,
        connectionGeneration: fixture.rootGeneration + 1, connectionEpoch: session.connectionEpoch,
        authorization: .notAuthorizedForExecution)
    let intent = try PrecisionRuntimeAdmissionReview.makeIntent(
        launchID: UUID(), observerRunID: UUID(), operation: .resume, readiness: readiness,
        session: session, rootGeneration: fixture.rootGeneration + 1,
        sourceBaselineURL: fixture.sourceURL, runtimeJournalURL: fixture.runtimeURL,
        expiresAtUptimeNanoseconds: 400)
    let permit = PrecisionAutomaticRunPermit(consent: PrecisionSeamlessRestartConsent(enabled: true, readiness: readiness), consentIsCurrent: { true })
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issueAutomatically(
        for: intent, permit: permit, nowUptimeNanoseconds: 300)
    let events = AdmissionEventRecorder()
    let configuration = admissionConfiguration(intent: intent, authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: intent, events: events), events: events,
        nowProvider: { 300 })
    let resumed = try await PrecisionRuntimeAdmissionFactory.admit(
        configuration: configuration,
        inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
        acquireLease: { try MXErgoDeviceOperationLease.acquire(beside: $0) },
        bootstrap: { request, lease in
            try await PrecisionRuntimeJournalBootstrap.prepare(request, operationLease: lease)
        },
        makeRuntime: { configuration in
            AdmissionFakeRuntime(context: configuration.journalContext, events: events)
        })
    #expect(await resumed.state == .active)
    #expect(events.count("resume") == 1)
    #expect(events.count("activate") == 0)
    #expect(events.count("recover") == 0)
    #expect(events.count("deactivate") == 0)
    #expect(try Data(contentsOf: fixture.runtimeURL) == before)
    _ = await resumed.shutdown()
    await expectAdmissionFailure(stage: .authorization) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(
            configuration: configuration,
            inspect: { _ in throw AdmissionTestError.unused },
            acquireLease: { _ in throw AdmissionTestError.unused },
            bootstrap: { _, _ in throw AdmissionTestError.unused },
            makeRuntime: { _ in throw AdmissionTestError.unused })
    }
}


private struct AutomaticRevokingHandoff: PrecisionRuntimeHostHandoff {
    let permit: PrecisionAutomaticRunPermit
    func stopAndWait(launchID: UUID, expectedSession: DeviceTransactionSession,
        expectedRootGeneration: UInt64, expectedObserverRunID: UUID,
        timeoutNanoseconds: UInt64) async throws -> PrecisionRuntimeHostHandoffReceipt {
        permit.revoke()
        return PrecisionRuntimeHostHandoffReceipt(launchID: launchID, session: expectedSession,
            rootGeneration: expectedRootGeneration, observerRunID: expectedObserverRunID,
            pendingRequestCount: 0, observerWasUnscheduled: true, observerDeviceWasClosed: true)
    }
}

@Test func automaticRevocationDuringHandoffPreventsBootstrapAndAcquisition() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 400)
    let permit = PrecisionAutomaticRunPermit(consent: PrecisionSeamlessRestartConsent(enabled: true,
        readiness: fixture.readiness), consentIsCurrent: { true })
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issueAutomatically(for: intent,
        permit: permit, nowUptimeNanoseconds: 300)
    let configuration = admissionConfiguration(intent: intent, authorization: authorization,
        handoff: AutomaticRevokingHandoff(permit: permit), nowProvider: { 300 })
    await expectAdmissionFailure(stage: .competitorScan) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(configuration: configuration,
            inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
            acquireLease: { try MXErgoDeviceOperationLease.acquire(beside: $0) },
            bootstrap: { _, _ in Issue.record("Bootstrap after opt-out"); throw AdmissionTestError.unused },
            makeRuntime: { _ in Issue.record("Acquisition after opt-out"); throw AdmissionTestError.unused })
    }
}

@Test func automaticRevocationAfterAcquisitionShutsDownWithoutActivation() async throws {
    let fixture = try admissionFixture()
    defer { fixture.cleanup() }
    let intent = try fixture.intent(operation: .activate, deadline: 400)
    let permit = PrecisionAutomaticRunPermit(consent: PrecisionSeamlessRestartConsent(enabled: true,
        readiness: fixture.readiness), consentIsCurrent: { true })
    let authorization = try PrecisionRuntimeAdmissionAuthorizationFactory.issueAutomatically(for: intent,
        permit: permit, nowUptimeNanoseconds: 300)
    let events = AdmissionEventRecorder()
    let configuration = admissionConfiguration(intent: intent, authorization: authorization,
        handoff: ExactAdmissionHandoff(intent: intent), nowProvider: { 300 })
    await #expect(throws: PrecisionAutomaticRunError.revoked) {
        _ = try await PrecisionRuntimeAdmissionFactory.admit(configuration: configuration,
            inspect: { try PrecisionRuntimeJournalBootstrap.inspect($0) },
            acquireLease: { try MXErgoDeviceOperationLease.acquire(beside: $0) },
            bootstrap: { request, lease in try await PrecisionRuntimeJournalBootstrap.prepare(request, operationLease: lease) },
            makeRuntime: { configuration in
                permit.revoke()
                return AdmissionFakeRuntime(context: configuration.journalContext, events: events)
            })
    }
    #expect(events.count("activate") == 0)
    #expect(events.count("resume") == 0)
    #expect(events.count("recover") == 0)
    #expect(events.count("shutdown") == 1)
}

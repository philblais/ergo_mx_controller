import Testing
@testable import MXErgoCore

@Test @MainActor func automaticStartupResumesWithoutRolloverAndCannotRunTwice() async {
    let flow = PrecisionAutomaticStartupFlow()
    var preparations = 0
    var rollovers = 0
    for expected in [PrecisionAutomaticStartupFlow.Result.active, .stopped] {
        let result = await flow.perform(isCurrent: { true }, prepare: { _ in
            preparations += 1; return .active
        }, releaseAndRefresh: { rollovers += 1 })
        #expect(result == expected)
    }
    #expect(preparations == 1)
    #expect(rollovers == 0)
}

@Test @MainActor func automaticStartupReactivatesOnlyAfterCleanRollover() async {
    let flow = PrecisionAutomaticStartupFlow()
    var events: [String] = []
    let result = await flow.perform(isCurrent: { true }, prepare: { fresh in
        events.append(fresh ? "fresh activation" : "resume baseline")
        return fresh ? .active : .restored
    }, releaseAndRefresh: { events.append("drain close retire fresh observer") })
    #expect(result == .active)
    #expect(events == ["resume baseline", "drain close retire fresh observer", "fresh activation"])
}

@Test @MainActor func automaticStartupStopsOnRevocationAtEverySuspension() async {
    for revokeAt in 0...2 {
        let flow = PrecisionAutomaticStartupFlow()
        var current = true
        var calls = 0
        let result = await flow.perform(isCurrent: { current }, prepare: { fresh in
            if calls == revokeAt { current = false }
            calls += 1
            return fresh ? .active : .restored
        }, releaseAndRefresh: {
            if calls == revokeAt { current = false }
            calls += 1
        })
        #expect(result == .stopped)
        #expect(calls == revokeAt + 1)
    }
}

@Test @MainActor func automaticStartupNeverLoopsOnRepeatedBaselineOrFailure() async {
    for initial in [PrecisionAutomaticStartupFlow.Result.stopped, .restored] {
        let flow = PrecisionAutomaticStartupFlow()
        var calls = 0
        let result = await flow.perform(isCurrent: { true }, prepare: { _ in
            calls += 1; return initial
        }, releaseAndRefresh: {})
        #expect(result == .stopped)
        #expect(calls == (initial == .restored ? 2 : 1))
    }
}

@Test @MainActor func automaticStartupFailedReleaseCannotActivate() async {
    enum Failed: Error { case release }
    let flow = PrecisionAutomaticStartupFlow()
    var calls = 0
    let result = await flow.perform(isCurrent: { true }, prepare: { _ in
        calls += 1; return .restored
    }, releaseAndRefresh: { throw Failed.release })
    #expect(result == .stopped)
    #expect(calls == 1)
}

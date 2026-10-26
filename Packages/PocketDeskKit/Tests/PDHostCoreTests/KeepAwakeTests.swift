#if os(macOS)
import Foundation
import IOKit.pwr_mgt
import Synchronization
import Testing
@testable import PDHostCore

struct KeepAwakeTests {
    @Test func multipleSessionsHoldUntilTheLastOneEnds() {
        let now = ContinuousClock.now
        let first = UUID(), second = UUID()
        var state = KeepAwakeState(settings: .init(whileStreaming: true))
        state = state.reduce(.tick(.external), now: now)
        state = state.reduce(.streaming(first, true), now: now)
        state = state.reduce(.streaming(second, true), now: now)
        #expect(state.shouldHold)
        state = state.reduce(.streaming(first, false), now: now)
        #expect(state.shouldHold)
        state = state.reduce(.streaming(second, false), now: now)
        #expect(!state.shouldHold)
    }

    @Test func batteryPolicyAndTimerUseElapsedTime() {
        let now = ContinuousClock.now
        var state = KeepAwakeState()
        state = state.reduce(.tick(.external), now: now)
        state = state.reduce(.keepAvailable(seconds: 60), now: now)
        #expect(state.shouldHold)
        state = state.reduce(.tick(.battery), now: now + .seconds(10))
        #expect(!state.shouldHold)
        #expect(state.waitingForPower)
        #expect(state.remainingSeconds == 50)
        state = state.reduce(.settings(.init(allowOnBattery: true)), now: now + .seconds(20))
        #expect(state.shouldHold)
        state = state.reduce(.tick(.external), now: now + .seconds(61))
        #expect(!state.hasRequest)
        #expect(state.remainingSeconds == 0)
    }

    @Test func endNowAndManualSleepDoNotReassertForTheSameSession() {
        let now = ContinuousClock.now, first = UUID(), second = UUID()
        var state = KeepAwakeState(settings: .init(whileStreaming: true, allowOnBattery: true))
        state = state.reduce(.streaming(first, true), now: now)
        state = state.reduce(.keepAvailable(seconds: 120), now: now)
        state = state.reduce(.endNow, now: now)
        #expect(!state.shouldHold)
        #expect(state.settings.whileStreaming)
        state = state.reduce(.tick(.external), now: now + .seconds(1))
        #expect(!state.shouldHold)
        state = state.reduce(.streaming(second, true), now: now)
        #expect(state.shouldHold)
        state = state.reduce(.sleep, now: now)
        state = state.reduce(.wake, now: now)
        #expect(!state.shouldHold)
        #expect(state.remainingSeconds == 0)
        state = state.reduce(.settings(.init(whileStreaming: false, allowOnBattery: true)), now: now)
        state = state.reduce(.settings(.init(whileStreaming: true, allowOnBattery: true)), now: now)
        #expect(state.shouldHold)
    }

    @Test func disablingStreamingDoesNotCancelAnExplicitTimer() {
        let now = ContinuousClock.now
        var state = KeepAwakeState(settings: .init(whileStreaming: true, allowOnBattery: true))
        state = state.reduce(.streaming(UUID(), true), now: now)
        state = state.reduce(.keepAvailable(seconds: 30), now: now)
        state = state.reduce(.settings(.init(whileStreaming: false, allowOnBattery: true)), now: now)
        #expect(state.shouldHold)
        state = state.reduce(.tick(.external), now: now + .seconds(30))
        #expect(!state.shouldHold)
        state = state.reduce(.stop, now: now)
        state = state.reduce(.keepAvailable(seconds: 60), now: now)
        #expect(!state.shouldHold)
        #expect(!state.hasRequest)
    }

    @Test func preferencesRoundTripButNewLaunchHasNoTimer() throws {
        let suite = "com.pocketdesk.tests.keepawake.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(KeepAwakeSettings.load(from: defaults) == .init())
        let settings = KeepAwakeSettings(whileStreaming: true, allowOnBattery: true)
        settings.save(to: defaults)
        let state = KeepAwakeState(settings: .load(from: defaults))
        #expect(state.settings == settings)
        #expect(!state.hasRequest)
    }

    @Test func assertionOwnershipAndFailureRecovery() async {
        let assertion = RecordingSleepAssertion()
        let snapshots = Mutex<[KeepAwakeState]>([])
        let manager = KeepAwake(settings: .init(whileStreaming: true), assertion: assertion,
                                readPower: { .external }) { state in snapshots.withLock { $0.append(state) } }
        let first = UUID(), second = UUID()
        await manager.send(.tick(.external))
        await manager.send(.streaming(first, true))
        await manager.send(.streaming(second, true))
        #expect(assertion.calls.withLock { $0.acquired } == 1)
        await manager.send(.streaming(first, false))
        #expect(assertion.calls.withLock { $0.released.isEmpty })
        await manager.send(.tick(.battery))
        #expect(assertion.calls.withLock { $0.released } == [1])
        assertion.calls.withLock { $0.fail = true }
        await manager.send(.tick(.external))
        #expect(snapshots.withLock { $0.last?.isActive } == false)
        #expect(snapshots.withLock { $0.last?.error } != nil)
        assertion.calls.withLock { $0.fail = false }
        await manager.send(.tick(.external))
        #expect(snapshots.withLock { $0.last?.isActive } == true)
        #expect(snapshots.withLock { $0.last?.error } == nil)
        await manager.stop()
        await manager.stop()
        #expect(assertion.calls.withLock { $0.released } == [1, 2])
    }

    @Test func realAssertionIsIdleSystemOnlyAndReleased() throws {
        let assertion = MacIdleSleepAssertion()
        let id = try assertion.acquire()
        let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
        assertion.release(id)
        #expect(properties?[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep)
        #expect(properties?[kIOPMAssertionLevelKey] as? Int == Int(kIOPMAssertionLevelOn))
        #expect(IOPMAssertionCopyProperties(id) == nil)
    }

    @Test func timerExpiresWithoutAnOpenMenu() async throws {
        let assertion = RecordingSleepAssertion()
        let manager = KeepAwake(assertion: assertion, readPower: { .external })
        await manager.start()
        await manager.send(.keepAvailable(seconds: 1))
        #expect(assertion.calls.withLock { $0.acquired } == 1)
        for _ in 0..<30 where assertion.calls.withLock({ $0.released.isEmpty }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(assertion.calls.withLock { $0.released } == [1])
        await manager.stop()
    }
}

final class RecordingSleepAssertion: IdleSleepAssertion {
    struct Calls { var acquired: UInt32 = 0; var released: [UInt32] = []; var fail = false }
    let calls = Mutex(Calls())
    func acquire() throws -> UInt32 {
        try calls.withLock {
            if $0.fail { throw CocoaError(.fileReadUnknown) }
            $0.acquired += 1
            return $0.acquired
        }
    }
    func release(_ id: UInt32) { calls.withLock { $0.released.append(id) } }
}
#endif

#if os(macOS)
import Foundation
import IOKit.pwr_mgt
import IOKit.ps

public struct KeepAwakeSettings: Sendable, Equatable {
    public var whileStreaming: Bool
    public var allowOnBattery: Bool

    public init(whileStreaming: Bool = false, allowOnBattery: Bool = false) {
        self.whileStreaming = whileStreaming
        self.allowOnBattery = allowOnBattery
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(whileStreaming: defaults.bool(forKey: "PocketDesk.keepAwake.whileStreaming"),
             allowOnBattery: defaults.bool(forKey: "PocketDesk.keepAwake.allowOnBattery"))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(whileStreaming, forKey: "PocketDesk.keepAwake.whileStreaming")
        defaults.set(allowOnBattery, forKey: "PocketDesk.keepAwake.allowOnBattery")
    }
}

/// Pure policy. A timer is deliberately not persisted: relaunching never starts a new hold.
public struct KeepAwakeState: Sendable, Equatable {
    public enum Power: Sendable, Equatable { case external, battery, unknown }
    public var settings = KeepAwakeSettings()
    public private(set) var power: Power = .unknown
    public private(set) var remainingSeconds = 0
    public private(set) var isActive = false
    public private(set) var error: String?
    private var sessions: Set<UUID> = []
    private var suppressed: Set<UUID> = []
    private var deadline: ContinuousClock.Instant?
    private var sleeping = false
    private var stopped = false

    public enum Event: Sendable {
        case settings(KeepAwakeSettings)
        case streaming(UUID, Bool)
        case keepAvailable(seconds: Int)
        case tick(Power)
        case endNow
        case sleep
        case wake
        case stop
        case assertion(active: Bool, error: String?)
    }

    public init(settings: KeepAwakeSettings = .init()) { self.settings = settings }

    public var hasRequest: Bool {
        remainingSeconds > 0 || (settings.whileStreaming && !sessions.subtracting(suppressed).isEmpty)
    }

    public var waitingForPower: Bool { hasRequest && !settings.allowOnBattery && power != .external }
    var shouldHold: Bool { hasRequest && !waitingForPower && !sleeping && !stopped }

    public func reduce(_ event: Event, now: ContinuousClock.Instant) -> Self {
        var next = self
        switch event {
        case .settings(let settings):
            // Turning it back on is an explicit request, even after End Now.
            if settings.whileStreaming && !next.settings.whileStreaming { next.suppressed = [] }
            next.settings = settings
        case .streaming(let id, true): next.sessions.insert(id)
        case .streaming(let id, false):
            next.sessions.remove(id)
            next.suppressed.remove(id)
        case .keepAvailable(let seconds):
            if !stopped, seconds > 0 { next.deadline = now + .seconds(min(seconds, 8 * 3600)) }
        case .tick(let power): next.power = power
        case .endNow, .sleep:
            next.deadline = nil
            next.suppressed = next.sessions
            if case .sleep = event { next.sleeping = true }
        case .wake: next.sleeping = false
        case .stop:
            next.stopped = true
            next.deadline = nil
            next.sessions = []
            next.suppressed = []
        case .assertion(let active, let error):
            next.isActive = active
            next.error = error
        }
        if let deadline = next.deadline {
            let duration = (deadline - now).components
            next.remainingSeconds = max(0, Int(duration.seconds) + (duration.attoseconds > 0 ? 1 : 0))
            if deadline <= now { next.deadline = nil; next.remainingSeconds = 0 }
        } else {
            next.remainingSeconds = 0
        }
        return next
    }
}

/// The assertion ID has exactly one owner. The OS also releases it if the process crashes.
protocol IdleSleepAssertion: Sendable {
    func acquire() throws -> UInt32
    func release(_ id: UInt32)
}

struct MacIdleSleepAssertion: IdleSleepAssertion {
    func acquire() throws -> UInt32 {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "PocketDesk remote availability" as CFString, &id)
        guard result == kIOReturnSuccess else { throw NSError(domain: NSMachErrorDomain, code: Int(result)) }
        return id
    }

    func release(_ id: UInt32) { IOPMAssertionRelease(id) }

    static func power() -> KeepAwakeState.Power {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return .unknown }
        if source == kIOPSACPowerValue as CFString { return .external }
        if source == kIOPSBatteryPowerValue as CFString { return .battery }
        return .unknown
    }
}

/// Lives independently of the menu's visibility. Polls power and expiry once a second;
/// observable updates are only published when something actually changes.
public actor KeepAwake {
    private var state: KeepAwakeState
    private let assertion: any IdleSleepAssertion
    private let readPower: @Sendable () -> KeepAwakeState.Power
    private let onChange: @Sendable (KeepAwakeState) -> Void
    private var assertionID: UInt32?
    private var timer: Task<Void, Never>?

    public init(settings: KeepAwakeSettings = .init(), onChange: @escaping @Sendable (KeepAwakeState) -> Void) {
        self.init(settings: settings, assertion: MacIdleSleepAssertion(), readPower: MacIdleSleepAssertion.power,
                  onChange: onChange)
    }

    init(settings: KeepAwakeSettings = .init(), assertion: any IdleSleepAssertion,
         readPower: @escaping @Sendable () -> KeepAwakeState.Power,
         onChange: @escaping @Sendable (KeepAwakeState) -> Void = { _ in }) {
        state = KeepAwakeState(settings: settings)
        self.assertion = assertion
        self.readPower = readPower
        self.onChange = onChange
    }

    deinit {
        timer?.cancel()
        if let assertionID { assertion.release(assertionID) }
    }

    public func start() {
        guard timer == nil else { return }
        send(.tick(readPower()))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.tick()
            }
        }
    }

    private func tick() { send(.tick(readPower())) }

    public func send(_ event: KeepAwakeState.Event, now: ContinuousClock.Instant = .now) {
        let old = state
        state = state.reduce(event, now: now)
        if state.shouldHold, assertionID == nil {
            do {
                assertionID = try assertion.acquire()
                state = state.reduce(.assertion(active: true, error: nil), now: now)
            } catch {
                state = state.reduce(.assertion(active: false, error: "macOS couldn't keep this Mac awake. Try again or check Energy settings."), now: now)
            }
        } else if !state.shouldHold {
            if let assertionID { assertion.release(assertionID) }
            assertionID = nil
            state = state.reduce(.assertion(active: false, error: nil), now: now)
        }
        if state != old { onChange(state) }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        send(.stop)
    }
}
#endif

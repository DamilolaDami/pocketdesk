/// First-connection guidance, independent of pairing and transport. The app persists dismissal.
public struct PhoneOnboarding: Sendable, Equatable {
    public static let finishedKey = "phoneSetupFinished"

    public enum Step: Int, Sendable, CaseIterable {
        case welcome, mac, find
        public var previous: Self? { Self(rawValue: rawValue - 1) }
        public var next: Self? { Self(rawValue: rawValue + 1) }
    }

    public private(set) var step: Step = .welcome
    public private(set) var isPresented: Bool
    public private(set) var showsControls = false
    private var offersControls: Bool

    public init(finished: Bool, hasPairedMacs: Bool) {
        isPresented = !finished && !hasPairedMacs
        offersControls = isPresented
    }

    public mutating func advance() { if let next = step.next { step = next } }
    public mutating func back() { if let previous = step.previous { step = previous } }
    public mutating func findMac() { step = .find }
    public mutating func dismiss() { isPresented = false }
    public mutating func dismissControls() { showsControls = false }

    /// Pairing/connecting keep their existing screens. Only a real stream completes setup.
    public mutating func receive(_ state: SessionState) {
        if case .streaming = state {
            guard offersControls else { return }
            isPresented = false
            showsControls = true
            offersControls = false
        } else {
            showsControls = false
        }
    }
}

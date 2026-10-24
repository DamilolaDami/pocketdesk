/// The Mac app's first-run steps, in order. Pure; the window draws them.
public enum OnboardingStep: Int, CaseIterable, Sendable, Comparable {
    case welcome, screenRecording, accessibility, wakeAndLogin, pair, done

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var next: Self? { Self(rawValue: rawValue + 1) }
    public var previous: Self? { Self(rawValue: rawValue - 1) }

    /// The permission this step asks for, if any.
    public var permission: HostPermissions.Kind? {
        switch self {
        case .screenRecording: .screenRecording
        case .accessibility: .accessibility
        default: nil
        }
    }

    /// Where to go from `self`: skips permission steps already granted, so someone who
    /// granted both in an earlier run goes straight on.
    public func advanced(granted: (HostPermissions.Kind) -> Bool) -> Self? {
        var step = next
        while let current = step, let permission = current.permission, granted(permission) {
            step = current.next
        }
        return step
    }
}

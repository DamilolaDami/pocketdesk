import LocalAuthentication

/// Proving it's the phone's owner, for Macs locked behind Face ID: Face ID or Touch ID,
/// falling back to the iPhone's passcode.
enum DeviceOwner {
    @MainActor static func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        // No passcode set at all: there's nothing to lock with, so don't lock anyone out.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// "Face ID", "Touch ID", or "Passcode" on a phone without either.
    static var method: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    static var symbol: String {
        switch method {
        case "Face ID": "faceid"
        case "Touch ID": "touchid"
        case "Optic ID": "opticid"
        default: "lock.fill"
        }
    }
}

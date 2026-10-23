import UIKit

/// Which ways the app may turn. On iPhone everything is portrait except the stream, which
/// turns sideways with the phone or from its Landscape button. iPad turns everywhere.
@MainActor
enum Orientation {
    private(set) static var allowsLandscape = false

    static var supported: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad || allowsLandscape ? .all : .portrait
    }

    /// The stream calls this as it appears and disappears. Leaving it turns the app back upright.
    static func allowLandscape(_ allowed: Bool) {
        allowsLandscape = allowed
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if !allowed { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.supported
    }
}

import UIKit

/// Classic (non-scene) UIKit entry point — minimal on purpose. No storyboard,
/// no scene manifest in Info.plist, so UIKit uses this `window`. A shipping
/// universal app would adopt `UIScene`; for the proof this is the smallest
/// thing that puts a real `UICollectionView` on screen.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: LibraryGridViewController())
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

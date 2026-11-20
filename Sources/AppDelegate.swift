import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let browser = BrowserViewController()
        let nav = UINavigationController(rootViewController: browser)
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = .white
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

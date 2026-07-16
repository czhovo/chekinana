import SwiftUI
import SwiftData
import UIKit

final class StatusBarHostingController<Content: View>: UIHostingController<Content> {
    override var prefersStatusBarHidden: Bool {
        false
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .darkContent
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }

#if DEBUG
        ChekinanaDataStore.resetForUITestingIfRequested()
#endif
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = StatusBarHostingController(
            rootView: ContentView()
                .modelContainer(ChekinanaDataStore.shared)
        )
        self.window = window
        window.makeKeyAndVisible()
    }
}

@main
final class ChekinanaApp: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

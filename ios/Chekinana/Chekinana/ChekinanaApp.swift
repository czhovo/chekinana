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

private struct ChekinanaLocalizedRootView: View {
    @StateObject private var languageStore = ChekinanaLanguageStore.shared
    let content: AnyView

    var body: some View {
        content
            .environment(\.locale, languageStore.displayLocale)
            .environment(\.chekinanaLanguageRevision, languageStore.revision)
            .environmentObject(languageStore)
    }
}

private struct ChekinanaDataStoreRecoveryView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.purple)
                .accessibilityHidden(true)

            Text(ChekinanaL10n.text(
                "datastore.recovery.title",
                fallback: "Your library could not be opened"
            ))
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)

            Text(ChekinanaL10n.text(
                "datastore.recovery.message",
                fallback: "Your saved data was not cleared or replaced. Retry opening the same library."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Button(action: onRetry) {
                Text(ChekinanaL10n.text("common.retry", fallback: "Retry"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .accessibilityIdentifier("datastore.retry")
        }
        .padding(28)
        .frame(maxWidth: 460)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("datastore.recovery")
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

        let window = UIWindow(windowScene: windowScene)
        self.window = window
        installRoot(in: window)
        window.makeKeyAndVisible()
    }

    private func installRoot(in window: UIWindow) {
        switch ChekinanaDataStore.open() {
        case .success(let container):
            installProductRoot(in: window, container: container)
        case .failure:
            installRecoveryRoot(in: window)
        }
    }

    private func installRecoveryRoot(in window: UIWindow) {
        let recovery = ChekinanaDataStoreRecoveryView { [weak self, weak window] in
            guard let self, let window else { return }
            self.installRoot(in: window)
        }
        window.rootViewController = StatusBarHostingController(
            rootView: ChekinanaLocalizedRootView(content: AnyView(recovery))
        )
    }

    private func installProductRoot(
        in window: UIWindow,
        container: ModelContainer
    ) {
#if DEBUG
        do {
            try ChekinanaDataStore.resetForUITestingIfRequested(in: container)
        } catch {
            installRecoveryRoot(in: window)
            return
        }
#endif
        let launchContext = ModelContext(container)
        try? ChekinanaEventMediaJournal.recover(modelContext: launchContext)
        ChekinanaGalleryMediaStore.cleanupRestoreRecoveries()
        ChekinanaGalleryMediaStore.cleanupCommittedDeletions()
        ChekinanaGalleryMediaStore.cleanupOrphanedImports()
        ChekinanaGalleryMediaStore.cleanupStagedImports()
        ChekinanaCapturedPhotoStore.cleanupStaleFiles()
        do {
            try ChekinanaIdolPatternPersistence
                .discardIncompatiblePatternsIfNeeded(in: launchContext)
        } catch {
            installRecoveryRoot(in: window)
            return
        }
#if DEBUG
        ChekinanaProductUITestFixture.seedIfRequested(in: container)
#endif
        Task { @MainActor in
            try? await ChekinanaIdolPatternPersistence
                .refreshPendingCataloguePatterns(in: launchContext)
        }
        let rootView: AnyView
#if DEBUG
        if ProcessInfo.processInfo.environment["CHEKINANA_UI_LAUNCH_ID"] != nil
            || ProcessInfo.processInfo.environment["CHEKINANA_UI_OPEN_ASSISTANT"] == "1" {
            rootView = AnyView(ContentView())
        } else {
            rootView = AnyView(ChekinanaProductShell())
        }
#else
        rootView = AnyView(ChekinanaProductShell())
#endif
        window.rootViewController = StatusBarHostingController(
            rootView: ChekinanaLocalizedRootView(content: rootView)
                .modelContainer(container)
        )
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

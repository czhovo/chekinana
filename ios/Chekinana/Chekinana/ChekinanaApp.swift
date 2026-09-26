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
    @StateObject private var themeStore = ChekinanaThemeStore.shared
    let content: AnyView

    var body: some View {
        let _ = themeStore.revision
        content
            .monospacedDigit()
            .environment(\.locale, languageStore.displayLocale)
            .environment(\.chekinanaLanguageRevision, languageStore.revision)
            .environment(\.chekinanaThemeRevision, themeStore.revision)
            .environmentObject(languageStore)
            .environmentObject(themeStore)
            .tint(themeStore.accent)
    }
}

private struct ChekinanaDataStoreRecoveryView: View {
    let onRetry: () -> Void
    var message: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(ChekinanaDesignSystem.accent)
                .accessibilityHidden(true)

            Text(ChekinanaL10n.text(
                "datastore.recovery.title",
                fallback: "Your library could not be opened"
            ))
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)

            Text(message ?? ChekinanaL10n.text(
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
            .tint(ChekinanaDesignSystem.accent)
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

    private func installRecoveryRoot(in window: UIWindow, message: String? = nil) {
        let recovery = ChekinanaDataStoreRecoveryView(
            onRetry: { [weak self, weak window] in
                guard let self, let window else { return }
                self.installRoot(in: window)
            },
            message: message
        )
        window.rootViewController = StatusBarHostingController(
            rootView: ChekinanaLocalizedRootView(content: AnyView(recovery))
        )
    }

    private func installProductRoot(
        in window: UIWindow,
        container: ModelContainer
    ) {
        let launchContext = ModelContext(container)
        do {
            try ChekinanaDataImporter.recoverUnfinishedImport(in: launchContext)
            // A Cheki edit intent is durable before its formal UUID file can
            // change. Resolve its generation/record witness before any launch
            // cleanup can classify that file as current or orphaned.
            try ChekinanaChekiEditRecovery.recoverUnfinishedEdit(
                in: launchContext
            )
            _ = try ChekinanaChekiDeletionRecovery.recoverUnfinishedDeletion(
                in: launchContext
            )
            if try ChekinanaChekiIndexing.repairPersistedMediaItems(
                in: launchContext
            ) > 0 {
                try launchContext.save()
            }
#if DEBUG
            try ChekinanaDebugMediaItemNoteClearer.clearRecordNotesIfRequested(in: container)
            try ChekinanaDebugMediaItemNoteClearer.clearIfRequested(in: launchContext)
#endif
        } catch {
            installRecoveryRoot(in: window, message: error.localizedDescription)
            return
        }
#if DEBUG
        do {
            try ChekinanaDataStore.resetForUITestingIfRequested(in: container)
        } catch {
            installRecoveryRoot(in: window)
            return
        }
#endif
        // Import recovery must finish before any ordinary media cleanup. Those
        // queues cannot safely classify files while two library generations
        // are still present.
        Task { @MainActor in
            let clearRecovery = await ChekinanaLocalDataClearer
                .recoverUnfinishedClear(modelContext: launchContext)
            guard !clearRecovery.needsRetry else { return }
            // Pending Event/Travel files are only eligible for orphan
            // recovery at this process boundary, before any editor session
            // can become active. Runtime cleanup handles committed deletion
            // intents only, so a Travel mutation cannot collect an Event
            // editor's unsaved images.
            ChekinanaEventTravelMediaOwnership.reconcileAfterProcessRestart(
                currentGeneration: try? ChekinanaLibraryGenerationStore.current(
                    in: launchContext
                )
            )
            _ = await ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueues(
                in: launchContext,
                recoverEventPending: true
            )
        }
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
            // Cache-only: keep unresolved states pending when no local bank exists.
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

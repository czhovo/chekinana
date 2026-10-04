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

/// UIKit submits the launch artwork and a render-server animation before the
/// existing synchronous library bootstrap begins on the main thread.
private struct ChekinanaLaunchSchedule {
    private(set) var pendingToken: UInt = 0
    private(set) var isScheduled = false
    private(set) var hasStarted = false

    mutating func schedule() -> UInt? {
        guard !isScheduled, !hasStarted else { return nil }
        pendingToken &+= 1
        isScheduled = true
        return pendingToken
    }

    mutating func cancel(token: UInt? = nil) {
        guard !hasStarted, token == nil || token == pendingToken else { return }
        isScheduled = false
        pendingToken &+= 1
    }

    mutating func begin(token: UInt) -> Bool {
        guard isScheduled, !hasStarted, token == pendingToken else { return false }
        isScheduled = false
        hasStarted = true
        return true
    }

    mutating func retryIfNotStarted(_ started: Bool) {
        if !started { hasStarted = false }
    }
}

private final class ChekinanaLaunchViewController: UIViewController {
    var onReady: (() -> Bool)?
    private let iconView = UIImageView(image: UIImage(
        systemName: "camera.aperture",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 96, weight: .regular)
    )?.withRenderingMode(.alwaysTemplate))
    private var firstFrameLink: CADisplayLink?
    private var schedule = ChekinanaLaunchSchedule()

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }
    override var prefersStatusBarHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = UIColor(ChekinanaThemeStore.shared.accent)
        iconView.backgroundColor = .clear
        iconView.isAccessibilityElement = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96)
        ])
        let title = UILabel()
        title.text = "Chekinana"
        title.textColor = .label
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.transform = CGAffineTransform(translationX: 0, y: 48)
        let stack = UIStackView(arrangedSubviews: [iconView, title])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateMotionPreference),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleInitializationIfNeeded()
    }

    func scheduleInitializationIfNeeded() {
        guard viewIfLoaded?.window != nil, schedule.schedule() != nil else { return }
        updateMotionPreference()
        view.window?.layoutIfNeeded()
        view.layoutIfNeeded()
        // Flush the layer tree now; the one-shot display tick lets that first
        // frame reach the screen without imposing an artificial loading delay.
        CATransaction.flush()
        let link = CADisplayLink(target: self, selector: #selector(beginInitialization))
        firstFrameLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func updateMotionPreference() {
        iconView.layer.removeAnimation(forKey: "launch.rotation")
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 1.8
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        iconView.layer.add(rotation, forKey: "launch.rotation")
    }

    @objc private func beginInitialization() {
        firstFrameLink?.invalidate()
        firstFrameLink = nil
        let token = schedule.pendingToken
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let window = self.viewIfLoaded?.window,
                  window.rootViewController === self,
                  let scene = window.windowScene,
                  scene.activationState != .unattached,
                  UIApplication.shared.connectedScenes.contains(scene) else {
                self.schedule.cancel(token: token)
                return
            }
            guard self.schedule.begin(token: token) else { return }
            let started = self.onReady?() ?? false
            self.schedule.retryIfNotStarted(started)
            if started { self.onReady = nil }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        firstFrameLink?.invalidate()
        firstFrameLink = nil
        schedule.cancel()
        iconView.layer.removeAnimation(forKey: "launch.rotation")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Observes taps without consuming the original control/list interaction.
/// Register only on our content window, never on keyboard or system overlay windows.
@MainActor
private final class ChekinanaKeyboardDismissal: NSObject, UIGestureRecognizerDelegate {
    private weak var window: UIWindow?
    private weak var activeInput: UIView?
    private weak var tappedInput: UIView?
    private var keyboardIsVisible = false
    private let tap = UITapGestureRecognizer()

    init(window: UIWindow) {
        self.window = window
        super.init()
        tap.addTarget(self, action: #selector(didTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        window.addGestureRecognizer(tap)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            center.addObserver(self, selector: #selector(inputDidBegin(_:)), name: name, object: nil)
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            center.addObserver(self, selector: #selector(inputDidEnd(_:)), name: name, object: nil)
        }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        tap.view?.removeGestureRecognizer(tap)
        tap.delegate = nil
        window = nil
        activeInput = nil
        tappedInput = nil
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func inputDidBegin(_ notification: Notification) {
        guard let input = notification.object as? UIView,
              input.window === window else { return }
        activeInput = input
    }

    @objc private func inputDidEnd(_ notification: Notification) {
        guard let input = notification.object as? UIView, input === activeInput else { return }
        activeInput = nil
    }

    @objc private func keyboardWillShow() {
        keyboardIsVisible = true
        if let window { activeInput = Self.firstTextInput(in: window) }
    }

    @objc private func keyboardWillHide() {
        keyboardIsVisible = false
    }

    private static func firstTextInput(in view: UIView) -> UIView? {
        if view.isFirstResponder, view is any UITextInput { return view }
        for child in view.subviews {
            if let input = firstTextInput(in: child) { return input }
        }
        return nil
    }

    private static func isInputInteraction(_ view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is any UITextInput { return true }
            current = candidate.superview
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        tappedInput = nil
        guard let window, touch.view?.window === window,
              !Self.isInputInteraction(touch.view) else { return false }
        if activeInput?.isFirstResponder != true, keyboardIsVisible {
            activeInput = Self.firstTextInput(in: window)
        }
        guard let input = activeInput, input.window === window,
              input.isFirstResponder else { return false }
        tappedInput = input
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }

    @objc private func didTap(_ recognizer: UITapGestureRecognizer) {
        defer { tappedInput = nil }
        guard recognizer.state == .ended,
              let input = tappedInput, input.window === window,
              input.isFirstResponder else { return }
        // Resign only the input present when the tap began. A button may have
        // focused a different field by now; never endEditing the whole window.
        input.endEditing(false)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var keyboardDismissal: ChekinanaKeyboardDismissal?

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
        keyboardDismissal?.detach()
        keyboardDismissal = ChekinanaKeyboardDismissal(window: window)
        let launch = ChekinanaLaunchViewController()
        launch.onReady = { [weak self, weak window, weak launch] in
            guard let self, let window, let launch,
                  self.window === window,
                  window.rootViewController === launch,
                  let scene = window.windowScene,
                  scene.activationState != .unattached,
                  UIApplication.shared.connectedScenes.contains(scene) else { return false }
#if DEBUG
            if ChekinanaDebugChekiIndexReallocator.runIfRequested() {
                window.rootViewController = UIViewController()
                window.rootViewController?.view.backgroundColor = .systemBackground
                return true
            }
#endif
            self.installRoot(in: window)
            return true
        }
        window.rootViewController = launch
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard window?.windowScene === scene else { return }
        keyboardDismissal?.detach()
        keyboardDismissal = nil
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard window?.windowScene === scene else { return }
        (window?.rootViewController as? ChekinanaLaunchViewController)?
            .scheduleInitializationIfNeeded()
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
            try ChekinanaDebugMediaItemNoteClearer.removeIdolNameSpacesIfRequested(in: container)
            try ChekinanaDebugMediaItemNoteClearer.repairEventDatesIfRequested(in: container)
            try ChekinanaDebugMediaItemNoteClearer.insertEventsIfRequested(in: container)
            try ChekinanaDebugMediaItemNoteClearer.trimEventCitiesIfRequested(in: container)
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

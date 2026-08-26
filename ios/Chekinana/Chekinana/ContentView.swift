import PhotosUI
import OSLog
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ChekinanaAccessibilityMetrics {
    static let minimumTouchTarget: CGFloat = 44
}

extension View {
    func chekinanaMinimumTouchTarget() -> some View {
        frame(
            minWidth: ChekinanaAccessibilityMetrics.minimumTouchTarget,
            minHeight: ChekinanaAccessibilityMetrics.minimumTouchTarget
        )
        .contentShape(Rectangle())
    }
}

struct ChekinanaRotatingActivityArc: View {
    @State private var rotation = Angle.zero

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .frame(width: 26, height: 26)
            .rotationEffect(rotation)
            .onAppear {
                rotation = .degrees(360)
            }
            .animation(
                .linear(duration: 0.8).repeatForever(autoreverses: false),
                value: rotation
            )
    }
}

fileprivate struct PendingNaturalLanguageRequest: Equatable, Sendable {
    let input: String
    let draft: ChekinanaNLRequestDraft?
    let activeConfirmationCodes: Set<String>
    let selections: ChekinanaConversationSelections
}

#if DEBUG
enum ChekinanaAssistantTimingLog {
    private static let logger = Logger(
        subsystem: "app.chekinana.ios",
        category: "AssistantTiming"
    )

    static func completed(
        stage: String,
        messageCount: Int,
        cardCount: Int,
        startedAt: UInt64
    ) {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        logger.debug(
            "stage=\(stage, privacy: .public) messages=\(messageCount, privacy: .public) cards=\(cardCount, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)"
        )
    }
}

private enum ChekinanaNLTimingLog {
    private static let logger = Logger(
        subsystem: "app.chekinana.ios",
        category: "NLTiming"
    )

    static func completed(operationCount: Int, startedAt: UInt64) {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        logger.debug(
            "interpret completed operations=\(operationCount, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)"
        )
    }

    static func failed(startedAt: UInt64) {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        logger.debug("interpret failed operations=0 elapsed_ms=\(elapsed, privacy: .public)")
    }
}
#endif

private struct TemporaryChekiEditorDraft: Equatable {
    var id = UUID()
    var idolIDs = Set<UUID>()
    var hasDate = false
    var date = Date()
    var eventID: UUID?
    var idxText = ""
    var initialIdxText = ""
    var userAppears: Bool?
    var size: ChekiSize?
    var isFavorite = false
    var hasPostedToSNS = false
    var note = ""
}

enum ChekinanaPromptSubmissionPolicy {
    static func shouldSubmitTrailingNewline(
        oldValue: String,
        newValue: String,
        isFocused: Bool,
        isSubmitting: Bool
    ) -> Bool {
        guard isFocused, !isSubmitting else {
            return false
        }

        guard !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return newValue == oldValue + "\n"
    }
}

enum ChekinanaGreetingLanguage {
    static let response = "你好！我是 Chekinana。我可以陪你用自然语言添加和查看 Idol、记录 Event，并在你选好照片后准备扫描和整理 Cheki。"

    static func response(for input: String) -> String? {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[\s，,。.!！?？~～]+"#, with: "", options: .regularExpression)

        let greetings: Set<String> = [
            "你好",
            "您好",
            "嗨",
            "哈喽",
            "hello",
            "hi",
            "你好chekinana",
            "chekinana你好",
            "hichekinana",
            "hellochekinana",
        ]
        return greetings.contains(normalized) ? response : nil
    }
}

enum ChekinanaScannerRecognitionDefaults {
    static let dateIsEnabled = false
    static let idolIsEnabled = false
}

enum ChekinanaDateOnly {
    private static let carrierCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func canonicalDate(
        from date: Date,
        displayedIn sourceCalendar: Calendar
    ) -> Date? {
        let displayCalendar = gregorianCalendar(in: sourceCalendar.timeZone)
        let components = displayCalendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return canonicalDate(
            year: components.year,
            month: components.month,
            day: components.day
        )
    }

    static func canonicalized(_ date: Date) -> Date? {
        let components = carrierCalendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return canonicalDate(
            year: components.year,
            month: components.month,
            day: components.day
        )
    }

    static func displayDate(
        from canonicalDate: Date,
        calendar sourceCalendar: Calendar
    ) -> Date? {
        let components = carrierCalendar.dateComponents(
            [.year, .month, .day],
            from: canonicalDate
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        var displayed = DateComponents()
        displayed.year = year
        displayed.month = month
        displayed.day = day
        displayed.hour = 12
        return gregorianCalendar(in: sourceCalendar.timeZone).date(from: displayed)
    }

    static func canonicalDate(year: Int?, month: Int?, day: Int?) -> Date? {
        guard let year, let month, let day else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = carrierCalendar.date(from: components) else { return nil }
        let resolved = carrierCalendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day else { return nil }
        return date
    }

    static func parse(_ value: String) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        return canonicalDate(year: year, month: month, day: day)
    }

    static func string(_ canonicalDate: Date) -> String {
        let components = components(canonicalDate)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func sameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        string(lhs) == string(rhs)
    }

    static func components(_ canonicalDate: Date) -> DateComponents {
        carrierCalendar.dateComponents([.year, .month, .day], from: canonicalDate)
    }

    private static func gregorianCalendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}

#if DEBUG
@MainActor
enum ChekinanaMediaUITestFixture {
    static func pendingChekiImages() -> [ChekinanaPendingChekiImage] {
        let colors: [UIColor] = [
            UIColor(red: 0.92, green: 0.18, blue: 0.22, alpha: 1),
            UIColor(red: 0.14, green: 0.68, blue: 0.32, alpha: 1),
            UIColor(red: 0.16, green: 0.38, blue: 0.92, alpha: 1),
        ]
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return colors.map { color in
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: 2, height: 2),
                format: format
            )
            let data = renderer.pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            return ChekinanaPendingChekiImage(data: data, filenameExtension: "png")
        }
    }

    static func previewCard() -> ChekinanaChekiCard {
        let boundingBox = ChekinanaChekiDateBoundingBox(
            x1: 120,
            y1: 680,
            x2: 880,
            y2: 900
        )!
        let annotation = ChekinanaChekiDateAnnotation(
            text: "2026.07.04",
            precision: .fullDate,
            boundingBox: boundingBox
        )!
        return ChekinanaChekiCard(
            id: UUID(),
            imageRef: nil,
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: pendingChekiImages()[0].data,
            idx: 1,
            idolNames: ["Preview Idol"],
            eventName: "Preview Event",
            dateAnnotationState: .detected(annotation)
        )
    }
}
#endif

enum ChekinanaSelectedChekiLanguage {
    private static let referencePattern = #"(?:(?:这张|刚才那张|选中的)\s*(?:cheki|切己|切)|(?:this|the\s+selected|selected|the\s+last)\s+cheki|(?:この|選択した|さっきの)\s*(?:チェキ|cheki))"#

    static func referencesSelectedCheki(_ input: String) -> Bool {
        input.range(
            of: referencePattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func rewrittenUtterance(_ input: String, selectedChekiID: UUID) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: referencePattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard regex.firstMatch(in: input, range: range) != nil else {
            return nil
        }
        return regex.stringByReplacingMatches(
            in: input,
            range: range,
            withTemplate: "Cheki \(selectedChekiID.uuidString.lowercased())"
        )
    }
}

struct ChekinanaOwnedExecutionGate {
    private(set) var owner: UUID?

    mutating func begin() -> UUID {
        let newOwner = UUID()
        owner = newOwner
        return newOwner
    }

    func accepts(_ candidate: UUID, isCancelled: Bool) -> Bool {
        !isCancelled && owner == candidate
    }

    @discardableResult
    mutating func finish(_ candidate: UUID) -> Bool {
        guard owner == candidate else { return false }
        owner = nil
        return true
    }

    mutating func invalidate() {
        owner = nil
    }
}

struct ContentView: View {
    private static let transcriptBottomID = "chekinana.transcript.bottom"
    private static let idolConfirmationTimeoutNanoseconds: UInt64 = 5_000_000_000

    private let onClose: (() -> Void)?
    private let onShellAction: ((ChekinanaAssistantShellAction) -> Void)?
    private let initialScannerLaunch: ChekinanaAssistantScanLaunch?
    private let session: ChekinanaAssistantSession

    @Environment(\.modelContext) private var modelContext

    @State private var prompt = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var albumAddChekiItems: [PhotosPickerItem] = []
    @State private var albumAddChekiRequest: ChekinanaAlbumAddChekiRequest?
    @State private var albumPickerState = ChekinanaAlbumPickerStateMachine()
    @State private var albumPickerCancellationTask: Task<Void, Never>?
    @State private var albumProcessingTask: Task<Void, Never>?
    @State private var commandExecutionTask: Task<Void, Never>?
    @State private var idolCandidateSelectionTask: Task<Void, Never>?
    @State private var idolCandidateSelectionGate = ChekinanaOwnedExecutionGate()
    @State private var idolConfirmationTask: Task<Void, Never>?
    @State private var idolConfirmationTimeoutTask: Task<Void, Never>?
    @State private var idolConfirmationGate = ChekinanaOwnedExecutionGate()
    @State private var eventCandidateState = ChekinanaEventCandidateStateMachine()
    @State private var eventCandidateBusyOwner = ChekinanaEventCandidateBusyOwner()
    @State private var eventCandidateTask: Task<Void, Never>?
    @State private var activeEventCandidateRequest: EventCandidateRequest?
    @State private var mediaLoadProgress = ""
    @State private var transcriptMessages: [TranscriptMessage]
    @State private var activeIdolCandidateTokens: Set<String>
    @State private var confirmedIdolCandidateTokens: Set<String>
    @State private var isSubmitting = false
    @State private var confirmationLedger: ChekinanaConfirmationLedger
    @State private var conversationState: ChekinanaConversationState
    @State private var clarificationDate = Date()
    @State private var nlRequestTask: Task<Void, Never>?
    @State private var nlRequestGate = ChekinanaNLRequestGenerationGate()
    @State private var activeNLRequest: PendingNaturalLanguageRequest?
    @State private var pendingNLRetry: PendingNaturalLanguageRequest?
    @State private var selectedChekiID: UUID?
    @State private var transcriptScrollRequest = ChekinanaTranscriptScrollRequest.none
    @State private var isClosing = false
    @State private var isScannerDateRecognitionEnabled =
        ChekinanaScannerRecognitionDefaults.dateIsEnabled
    @State private var isScannerIdolRecognitionEnabled =
        ChekinanaScannerRecognitionDefaults.idolIsEnabled
    @State private var scannerDateBounds: ChekinanaScannerDateBounds?
    @State private var scannerCandidateIDs: Set<UUID>?
    @State private var scannerIncludesUnassignedCandidate = false
    @State private var didHandleInitialScannerLaunch = false
    @State private var temporaryEditorDraft = TemporaryChekiEditorDraft()
    @State private var isTemporaryEditorPresented = false
    @FocusState private var isPromptFocused: Bool

    init(
        session: ChekinanaAssistantSession = ChekinanaAssistantSession(),
        onClose: (() -> Void)? = nil,
        onShellAction: ((ChekinanaAssistantShellAction) -> Void)? = nil,
        initialScannerLaunch: ChekinanaAssistantScanLaunch? = nil,
        initialPrompt: String? = nil
    ) {
        self.session = session
        self.onClose = onClose
        self.onShellAction = onShellAction
        self.initialScannerLaunch = initialScannerLaunch
        _prompt = State(initialValue: initialPrompt ?? (initialScannerLaunch == nil ? session.prompt : "scancheki"))
        _transcriptMessages = State(initialValue: session.transcriptMessages)
        _activeIdolCandidateTokens = State(initialValue: session.activeIdolCandidateTokens)
        _confirmedIdolCandidateTokens = State(initialValue: session.confirmedIdolCandidateTokens)
        _confirmationLedger = State(initialValue: session.confirmationLedger)
        _conversationState = State(initialValue: session.conversationState)
        _selectedChekiID = State(initialValue: session.selectedChekiID)
        _pendingNLRetry = State(initialValue: session.pendingNLRetry)
        _selectedItems = State(initialValue: initialScannerLaunch?.items ?? [])
        _isScannerDateRecognitionEnabled = State(
            initialValue: initialScannerLaunch?.dateRecognitionEnabled
                ?? ChekinanaScannerRecognitionDefaults.dateIsEnabled
        )
        _isScannerIdolRecognitionEnabled = State(
            initialValue: initialScannerLaunch?.idolRecognitionEnabled
                ?? ChekinanaScannerRecognitionDefaults.idolIsEnabled
        )
        _scannerDateBounds = State(initialValue: initialScannerLaunch?.dateBounds)
        _scannerCandidateIDs = State(initialValue: initialScannerLaunch?.candidateIDs)
        _scannerIncludesUnassignedCandidate = State(
            initialValue: initialScannerLaunch?.includesUnassigned ?? false
        )
    }

    var body: some View {
        ZStack {
            ChekinanaDesignSystem.pageBackground
                .ignoresSafeArea(.container, edges: .all)

            VStack(spacing: 0) {
                titleBar
                transcript
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.root")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .statusBarHidden(false)
        .photosPicker(
            isPresented: albumPickerPresentationBinding,
            selection: albumPickerSelectionBinding,
            maxSelectionCount: 0,
            matching: .images
        )
        .sheet(isPresented: $isTemporaryEditorPresented) {
            let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
            TemporaryChekiEditorView(
                draft: $temporaryEditorDraft,
                idols: ((try? modelContext.fetch(FetchDescriptor<Idol>())) ?? [])
                    .filter { ChekinanaVisibilityPolicy.includesIdol($0.id, hiddenIDs: hiddenIDs) },
                events: (try? modelContext.fetch(FetchDescriptor<Event>())) ?? [],
                onSave: saveTemporaryEditor,
                onCancel: { isTemporaryEditorPresented = false }
            )
        }
        .onAppear {
#if DEBUG
            if let prefill = ProcessInfo.processInfo.environment["CHEKINANA_UI_PREFILL"],
               prompt.isEmpty {
                prompt = prefill
            }
            if ProcessInfo.processInfo.environment["CHEKINANA_CHEKI_PREVIEW_UI_STUB"] == "fixture",
               transcriptMessages.isEmpty {
                transcriptMessages.append(TranscriptMessage(
                    content: .chekiCards([ChekinanaMediaUITestFixture.previewCard()])
                ))
            }
            if ProcessInfo.processInfo.environment["CHEKINANA_ASSISTANT_SESSION_UI_STUB"] == "long_candidates",
               transcriptMessages.isEmpty {
                installLongCandidateUITestFixture()
            }
#endif
            guard initialScannerLaunch != nil, !didHandleInitialScannerLaunch else {
                return
            }
            didHandleInitialScannerLaunch = true
            Task { @MainActor in
                await Task.yield()
                submitPrompt()
            }
        }
        .onDisappear {
            suspendAssistantSession()
            captureAssistantSession()
        }
        .overlay(alignment: .topLeading) {
            uiTestLaunchMarker
        }
        .overlay(alignment: .topTrailing) {
            initialScanLaunchMarker
        }
    }

    @ViewBuilder
    private var uiTestLaunchMarker: some View {
#if DEBUG
        if let launchID = ProcessInfo.processInfo.environment["CHEKINANA_UI_LAUNCH_ID"],
           !launchID.isEmpty {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("UI test launch marker")
                .accessibilityValue(launchID)
                .accessibilityIdentifier("chekinana.launch-marker")
                .allowsHitTesting(false)
        }
#else
        EmptyView()
#endif
    }

    @ViewBuilder
    private var initialScanLaunchMarker: some View {
#if DEBUG
        if let launch = initialScannerLaunch {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Initial scanner launch")
                .accessibilityValue(
                    "photos=\(launch.items.count);date=\(launch.dateRecognitionEnabled ? 1 : 0);idol=\(launch.idolRecognitionEnabled ? 1 : 0);candidates=\(launch.candidateIDs.count);unassigned=\(launch.includesUnassigned ? 1 : 0);handled=\(didHandleInitialScannerLaunch ? 1 : 0)"
                )
                .accessibilityIdentifier("chekinana.assistant.scan-launch")
                .allowsHitTesting(false)
        }
#else
        EmptyView()
#endif
    }

    private var titleBar: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if onClose != nil {
                    Button(action: requestClose) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .disabled(isClosing)
                    .accessibilityLabel(ChekinanaL10n.text("assistant.back_home", fallback: "Back to home"))
                    .accessibilityIdentifier("chekinana.assistant.close")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }

                Spacer()

                Text("Chekinana")
                    .font(.headline)
                    .foregroundStyle(.black)

                Spacer()

                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(height: 0.5)
            }

        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriptMessages) { message in
                        transcriptMessageView(message)
                            .id(message.id)
                    }

                    if isSubmitting {
                        transcriptActivityStatus
                            .id("chekinana.transcript.activity.row")
                    } else if pendingNLRetry != nil {
                        transcriptRetryStatus
                            .id("chekinana.transcript.retry.row")
                    }

                    if conversationState.draft != nil {
                        clarificationPanel
                            .id("chekinana.clarification")
                    }

                    eventCandidatePanel
                        .id("chekinana.event.candidate.panel")

                    Color.clear
                        .frame(height: 1)
                        .id(Self.transcriptBottomID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Rectangle()
                    .fill(ChekinanaDesignSystem.pageBackground)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier("chekinana.transcript")
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture {
                isPromptFocused = false
            }
            .onChange(of: transcriptMessages.count) {
                session.persistTextHistory(from: transcriptMessages)
                guard let last = transcriptMessages.last else {
                    transcriptScrollRequest = .none
                    return
                }
                transcriptScrollRequest = ChekinanaTranscriptScrollPolicy.request(
                    for: last,
                    isRestoringHistory: false
                )
            }
            .onChange(of: transcriptScrollRequest) { _, request in
                guard request != .none else { return }
                Task { @MainActor in
                    await Task.yield()
                    switch request {
                    case .none:
                        break
                    case .bottom:
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
                        }
                    case .messageTop(let messageID, _):
                        // Long candidate responses deliberately reveal their
                        // beginning instead of moving the user to the final
                        // card or cancellation controls.
                        proxy.scrollTo(messageID, anchor: .top)
                    }
                    if transcriptScrollRequest == request {
                        transcriptScrollRequest = .none
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptMessageView(_ message: TranscriptMessage) -> some View {
        if message.role == .user, case .text(let text) = message.content {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 52)
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contextMenu {
                        Button(ChekinanaL10n.text("assistant.copy", fallback: "Copy")) {
                            UIPasteboard.general.string = text
                        }
                    }
                    .accessibilityIdentifier("chekinana.transcript.user-message")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            transcriptAssistantContent(message.content)
        }
    }

    @ViewBuilder
    private func transcriptAssistantContent(_ content: TranscriptContent) -> some View {
        switch content {
        case .text(let text):
            Text(text)
                .font(.body)
                .foregroundStyle(.black)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(ChekinanaDesignSystem.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: ChekinanaDesignSystem.compactRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ChekinanaDesignSystem.compactRadius, style: .continuous)
                        .stroke(ChekinanaDesignSystem.border, lineWidth: 0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button(ChekinanaL10n.text("assistant.copy", fallback: "Copy")) {
                        UIPasteboard.general.string = text
                    }
                }
        case .idolCard(let idol):
            IdolCardView(idol: idol)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .idolCards(let idols):
            IdolCardCollectionView(
                idols: idols,
                activeSelectionTokens: activeIdolCandidateTokens,
                confirmedSelectionTokens: confirmedIdolCandidateTokens,
                isInteractionEnabled: !isSubmitting,
                onSelectCandidate: selectIdolCandidate,
                onCancelCandidates: cancelIdolCandidates
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .idolCardsWithNotice(let idols, let notice):
            VStack(alignment: .leading, spacing: 10) {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
                    .textSelection(.enabled)
                IdolCardCollectionView(
                    idols: idols,
                    activeSelectionTokens: activeIdolCandidateTokens,
                    confirmedSelectionTokens: confirmedIdolCandidateTokens,
                    isInteractionEnabled: !isSubmitting,
                    onSelectCandidate: selectIdolCandidate,
                    onCancelCandidates: cancelIdolCandidates
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .idolSections(let sections):
            IdolSectionCollectionView(
                sections: sections,
                selectedChekiID: selectedChekiID,
                onSelectCheki: selectCheki
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .eventCard(let event):
            EventCardView(event: event)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .eventCards(let events):
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(events) { event in
                    EventCardView(event: event)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .chekiScannedCards(let count, let warningCount, let chekis):
            ScannedChekiTranscriptView(
                count: count,
                warningCount: warningCount,
                chekis: chekis,
                onEdit: beginEditingTemporaryCheki,
                onDelete: deleteTemporaryCheki,
                onDownload: downloadTemporaryCheki
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        case .pendingChekiCards(let summary, let chekis):
            PendingChekiTranscriptView(summary: summary, chekis: chekis)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .chekiCards(let chekis):
            ChekiListTranscriptView(
                chekis: chekis,
                selectedChekiID: selectedChekiID,
                onSelectCheki: selectCheki
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        case .confirmationActions(let codes):
            ConfirmationActionView(codes: codes) { command in
                submitExplicitCommand(command)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isSubmitting)
        case .scanAllShortcut:
            Button(ChekinanaL10n.text("assistant.scan_all", fallback: "Add details to all Cheki")) {
                beginScanAllClarification()
            }
            .buttonStyle(.bordered)
            .disabled(isSubmitting || conversationState.draft != nil)
        }
    }

    private var transcriptActivityStatus: some View {
        HStack(spacing: 8) {
            ChekinanaRotatingActivityArc()
                .accessibilityLabel(ChekinanaL10n.text("assistant.processing", fallback: "Processing request"))
                .accessibilityIdentifier("chekinana.transcript.activity")
            Spacer(minLength: 8)
            if activeNLRequest != nil {
                Button(ChekinanaL10n.text("action.cancel", fallback: "Cancel")) {
                    cancelRemoteInterpretation()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityHint(ChekinanaL10n.text(
                    "assistant.cancel_request_hint",
                    fallback: "Stop this request and preserve the current input"
                ))
                .accessibilityIdentifier("chekinana.nl.cancel")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptRetryStatus: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                retryPreservedMessage
                Spacer(minLength: 8)
                retryActionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                retryPreservedMessage
                retryActionButtons
            }
        }
        .padding(10)
        .background(ChekinanaDesignSystem.softAccent)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var retryPreservedMessage: some View {
        Text(ChekinanaL10n.text("assistant.input_preserved", fallback: "Your input was preserved"))
            .font(.footnote)
            .foregroundStyle(Color(.secondaryLabel))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var retryActionButtons: some View {
        HStack(spacing: 8) {
            Button(ChekinanaL10n.text("action.retry", fallback: "Retry")) {
                retryRemoteInterpretation()
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityHint(ChekinanaL10n.text("assistant.retry_hint", fallback: "Send the preserved request again"))
            .accessibilityIdentifier("chekinana.nl.retry")
            Button(ChekinanaL10n.text("action.cancel", fallback: "Cancel")) {
                cancelPendingRetry()
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityHint(ChekinanaL10n.text("assistant.cancel_retry_hint", fallback: "Keep the input without retrying"))
            .accessibilityIdentifier("chekinana.nl.cancel")
        }
    }

    private var clarificationCancelButton: some View {
        Button(ChekinanaL10n.text("assistant.cancel_conversation", fallback: "Cancel conversation")) {
            cancelConversation()
        }
        .font(.footnote)
        .buttonStyle(.plain)
        .foregroundStyle(Color(.secondaryLabel))
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityHint(ChekinanaL10n.text("assistant.cancel_conversation_hint", fallback: "Discard the current clarification"))
        .accessibilityIdentifier("chekinana.clarification.cancel")
    }

    private var clarificationHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(clarificationPromptText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                clarificationCancelButton
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(clarificationPromptText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                clarificationCancelButton
            }
        }
    }

    private var clarificationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            clarificationHeader

            clarificationControls
                .disabled(isSubmitting)
        }
        .padding(12)
        .background(ChekinanaDesignSystem.softAccent)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ChekinanaDesignSystem.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var eventCandidatePanel: some View {
        switch eventCandidateState.phase {
        case .idle:
            EmptyView()
        case .extracting:
            // The transcript-wide activity indicator is the only in-flight UI.
            EmptyView()
        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("chekinana.event.candidate.error")
                HStack(spacing: 8) {
                    Button(ChekinanaL10n.text("action.retry", fallback: "Retry")) {
                        if let activeEventCandidateRequest {
                            startEventCandidateExtraction(
                                request: activeEventCandidateRequest,
                                echo: nil
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("chekinana.event.candidate.retry")
                    .accessibilityHint(ChekinanaL10n.text("assistant.event_retry_hint", fallback: "Call the Event extraction service again"))
                    Button(ChekinanaL10n.text("action.cancel", fallback: "Cancel")) {
                        cancelEventCandidateFlow(announce: true)
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("chekinana.event.candidate.cancel")
                    .accessibilityHint(ChekinanaL10n.text("assistant.event_cancel_hint", fallback: "Close the candidate without creating an Event"))
                }
            }
            .eventCandidatePanelStyle()
        case .editing(let fields):
            EventCandidateEditorView(
                fields: eventCandidateFieldsBinding(fallback: fields),
                blockers: ChekinanaEventCandidateValidator.blockers(for: fields),
                isDisabled: isSubmitting,
                onPrepare: prepareEventCandidateConfirmation,
                onCancel: { cancelEventCandidateFlow(announce: true) }
            )
        }
    }

    @ViewBuilder
    private var clarificationControls: some View {
        if let localChoice = conversationState.draft?.localChoice {
            FlowChoiceView(options: localChoice.options, selectedIDs: []) { id in
                applyLocalChoice(id)
            }
        } else if let missing = conversationState.draft?.missing.first {
            switch missing {
            case .idol:
                if conversationState.draft?.requiresFreeTextIdolName == true {
                    Text(ChekinanaL10n.text("assistant.prompt.idol_name", fallback: "Enter the Idol name to add."))
                        .font(.footnote)
                        .foregroundStyle(Color(.secondaryLabel))
                } else {
                    let choices = ChekinanaConversationCoordinator.idolChoices(modelContext: modelContext)
                    if choices.isEmpty {
                        Text(ChekinanaConversationMessage.idolNotFound.text)
                            .font(.footnote)
                            .foregroundStyle(Color(.secondaryLabel))
                    } else {
                        FlowChoiceView(
                            options: choices,
                            selectedIDs: Set(conversationState.draft?.selections.selectedIdolIDs ?? [])
                        ) { id in
                            toggleSelectedIdol(id)
                        }
                        Button(ChekinanaL10n.text("action.continue", fallback: "Continue")) {
                            completeIdolSelection()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("chekinana.clarification.continue")
                        .disabled(conversationState.draft?.selections.selectedIdolIDs.isEmpty != false)
                    }
                }
            case .eventOrDate:
                let choices = ChekinanaConversationCoordinator.eventChoices(modelContext: modelContext)
                if !choices.isEmpty {
                    FlowChoiceView(options: choices, selectedIDs: []) { id in
                        chooseEvent(id)
                    }
                }
                Button(ChekinanaL10n.text("assistant.use_date", fallback: "Use date")) {
                    chooseDateInsteadOfEvent()
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("chekinana.clarification.use-date")
            case .eventName:
                Text(ChekinanaL10n.text("assistant.prompt.event_name", fallback: "Enter an Event name. The URL, if any, was preserved."))
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
            case .date:
                DatePicker(
                    ChekinanaL10n.text("assistant.date", fallback: "Date"),
                    selection: $clarificationDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                Button(ChekinanaL10n.text("assistant.use_this_date", fallback: "Use this date")) {
                    completeDateSelection()
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("chekinana.clarification.confirm-date")
            case .temporaryCheki:
                let choices = confirmationLedger.availableTemporaryChekiChoices().enumerated().map { index, temporary in
                    ChekinanaLocalChoice(
                        id: temporary.id,
                        title: ChekinanaL10n.format("assistant.scan_result_index", fallback: "Scan result %lld", Int64(index + 1)),
                        subtitle: nil
                    )
                }
                if choices.isEmpty {
                    Text(ChekinanaL10n.text("assistant.no_scan_results", fallback: "No scan results are available. Select photos and scan first."))
                        .font(.footnote)
                        .foregroundStyle(Color(.secondaryLabel))
                } else {
                    FlowChoiceView(
                        options: choices,
                        selectedIDs: Set(conversationState.draft?.selections.selectedTemporaryIDs ?? [])
                    ) { id in
                        toggleSelectedTemporaryCheki(id)
                    }
                    HStack(spacing: 8) {
                        Button(ChekinanaL10n.text("assistant.use_selected", fallback: "Use selected")) {
                            completeTemporarySelection()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("chekinana.clarification.use-selected")
                        .disabled(conversationState.draft?.selections.selectedTemporaryIDs.isEmpty != false)

                        Button(ChekinanaL10n.text("assistant.use_all", fallback: "All scan results")) {
                            useAllTemporaryChekis()
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("chekinana.clarification.use-all")
                    }
                }
            }
        }
    }

    private var clarificationPromptText: String {
        guard let draft = conversationState.draft else { return "" }
        if let localChoice = draft.localChoice {
            switch localChoice.kind {
            case .idol:
                return ChekinanaL10n.text("assistant.prompt.multiple_idol", fallback: "Multiple Idols matched. Choose one.")
            case .event:
                return ChekinanaL10n.text("assistant.prompt.multiple_event", fallback: "Multiple Events matched. Choose one.")
            }
        }
        switch draft.missing.first {
        case .idol:
            return draft.requiresFreeTextIdolName
                ? ChekinanaL10n.text("assistant.prompt.idol_name", fallback: "Enter the Idol name to add.")
                : ChekinanaL10n.text("assistant.prompt.idol", fallback: "Choose at least one local Idol.")
        case .eventOrDate:
            return ChekinanaL10n.text("assistant.prompt.event_or_date", fallback: "Choose a local Event or use a date.")
        case .eventName:
            return ChekinanaL10n.text("assistant.prompt.event_name", fallback: "Enter an Event name. The URL, if any, was preserved.")
        case .date:
            return ChekinanaL10n.text("assistant.prompt.date", fallback: "Choose a date.")
        case .temporaryCheki:
            return ChekinanaL10n.text("assistant.prompt.scan_result", fallback: "Choose the scan results to save.")
        case nil:
            return ChekinanaL10n.text("assistant.prompt.complete", fallback: "Complete this operation.")
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            VStack(spacing: 12) {
                TextField(ChekinanaL10n.text("assistant.ask_placeholder", fallback: "Ask Chekinana…"), text: $prompt, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit {
                        submitPrompt()
                    }
                    .onChange(of: prompt) { oldValue, newValue in
                        guard ChekinanaPromptSubmissionPolicy.shouldSubmitTrailingNewline(
                            oldValue: oldValue,
                            newValue: newValue,
                            isFocused: isPromptFocused,
                            isSubmitting: isSubmitting
                        ) else {
                            return
                        }

                        prompt = oldValue
                        submitPrompt()
                    }
                    .focused($isPromptFocused)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                    .accessibilityIdentifier("chekinana.prompt")
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()

                            Button(ChekinanaL10n.text("action.done", fallback: "Done")) {
                                isPromptFocused = false
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("chekinana.keyboard.done")
                        }
                    }

                if !selectedItems.isEmpty {
                    selectedPhotosSummary
                }

                HStack {
                    PhotosPicker(selection: $selectedItems, maxSelectionCount: 0, matching: .images) {
                        Image(systemName: "plus")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(ChekinanaDesignSystem.accent)
                            .frame(width: 28, height: 28)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                    .accessibilityLabel(ChekinanaL10n.text("assistant.choose_photos", fallback: "Choose photos"))
                    .accessibilityIdentifier("chekinana.photos")

                    Spacer()

                    Button {
                        submitPrompt()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle((prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting) ? Color(.systemGray3) : .white)
                            .frame(width: 28, height: 28)
                            .background((prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting) ? Color(.systemGray6) : ChekinanaDesignSystem.accent)
                            .clipShape(Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                    .accessibilityLabel(ChekinanaL10n.text("assistant.send", fallback: "Send"))
                    .accessibilityHint(ChekinanaL10n.text("assistant.send_hint", fallback: "Send this message to Chekinana"))
                    .accessibilityIdentifier("chekinana.send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 9)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: ChekinanaDesignSystem.cardRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: ChekinanaDesignSystem.cardRadius, style: .continuous).stroke(ChekinanaDesignSystem.border, lineWidth: 0.5) }
        }
        .padding(.horizontal, 7)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(ChekinanaDesignSystem.softAccent)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.composer")
    }

    private func applyQuickAction(_ action: ChekinanaQuickActionDefinition) {
        guard !isSubmitting, ChekinanaQuickActions.shouldApply(to: prompt) else { return }
        prompt = ChekinanaQuickActions.prefilledPrompt(
            currentPrompt: prompt,
            action: action,
            hasSelectedPhotos: !selectedItems.isEmpty
        )
        isPromptFocused = true
    }

    private var selectedPhotosSummary: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(.secondaryLabel))

                Text(ChekinanaL10n.quantity(
                    "assistant.photos_selected",
                    count: selectedItems.count,
                    one: "%lld photo selected",
                    other: "%lld photos selected"
                ))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(2)
                    .accessibilityLabel(ChekinanaL10n.text("assistant.photos_selected_label", fallback: "Selected photos"))
                    .accessibilityValue("\(selectedItems.count)")
                    .accessibilityIdentifier("chekinana.photos.summary")

                Spacer(minLength: 8)

                Button {
                    selectedItems = []
                    isScannerDateRecognitionEnabled =
                        ChekinanaScannerRecognitionDefaults.dateIsEnabled
                    isScannerIdolRecognitionEnabled =
                        ChekinanaScannerRecognitionDefaults.idolIsEnabled
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color(.systemGray2))
                        .frame(width: 24, height: 24)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityLabel(ChekinanaL10n.text("assistant.clear_photos", fallback: "Clear selected photos"))
            }

            Divider()
                .padding(.horizontal, 10)

            Toggle(isOn: $isScannerDateRecognitionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ChekinanaL10n.text("assistant.recognize_date", fallback: "Recognize handwritten dates"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.black)
                    Text(ChekinanaL10n.text("assistant.recognize_date_detail", fallback: "Requests dates and bounding boxes; boxes are shown only in previews."))
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .toggleStyle(.switch)
            .disabled(isSubmitting)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityHint(ChekinanaL10n.text("assistant.recognize_date_hint", fallback: "Does not modify or save images with boxes"))
            .accessibilityIdentifier("chekinana.scanner.date-recognition")

            Toggle(isOn: $isScannerIdolRecognitionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ChekinanaL10n.text("assistant.recognize_idol", fallback: "Recognize Idols"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.black)
                    Text(ChekinanaL10n.text("assistant.recognize_idol_detail", fallback: "Uses the on-device encoder to compare existing Idol patterns."))
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .toggleStyle(.switch)
            .disabled(isSubmitting)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityHint(ChekinanaL10n.text("assistant.recognize_idol_hint", fallback: "Uses all valid local patterns and the Unassigned candidate"))
            .accessibilityIdentifier("chekinana.scanner.idol-recognition")
        }
        .frame(minHeight: 44)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func submitPrompt() {
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isSubmitting else {
            return
        }

        // Keep request, retry, and media controls above the software keyboard.
        // The user can tap the retained input to continue editing at any time.
        isPromptFocused = false

        guard !ChekinanaNLPrivacyGuard.containsCredentialedHTTPURL(input) else {
            prompt = ""
            appendUserMessage(redactedCommandEcho(for: input))
            transcriptMessages.append(TranscriptMessage(content: .text(ChekinanaConversationMessage.privacyProtected.text)))
            return
        }

        let activeConfirmationCodes = confirmationLedger.activeConfirmationCodes
        guard ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(
            input,
            activeConfirmationCodes: activeConfirmationCodes
        ) else {
            prompt = ""
            appendUserMessage(redactedCommandEcho(for: input))
            transcriptMessages.append(
                TranscriptMessage(content: .text(ChekinanaConversationMessage.privacyProtected.text))
            )
            return
        }

        appendUserMessage(redactedCommandEcho(for: input))
        prompt = ""
        let requestDraft = conversationState.draft.map {
            ChekinanaNLRequestDraft(operation: $0.operation, missing: $0.missing)
        }
        var selections = conversationState.draft?.selections ?? .init()
        selections.selectedChekiID = selectedChekiID
        startRemoteInterpretation(.init(
            input: input,
            draft: requestDraft,
            activeConfirmationCodes: activeConfirmationCodes,
            selections: selections
        ))
    }

    private func startRemoteInterpretation(_ request: PendingNaturalLanguageRequest) {
        nlRequestTask?.cancel()
        let requestGeneration = nlRequestGate.begin()
        activeNLRequest = request
        pendingNLRetry = nil
        isSubmitting = true
        let task = Task { @MainActor in
#if DEBUG
            let interpretationStartedAt = DispatchTime.now().uptimeNanoseconds
#endif
            do {
                let interpretation = try await ChekinanaNLInterpretClient().interpret(
                    utterance: request.input,
                    localDate: ChekinanaNLInterpretClient.localDateString(),
                    timezone: TimeZone.current.identifier,
                    draft: request.draft,
                    activeConfirmationCodes: request.activeConfirmationCodes
                )
#if DEBUG
                let operationCount: Int
                switch interpretation {
                case .plan(let operations): operationCount = operations.count
                case .clarify: operationCount = 1
                case .reject: operationCount = 0
                }
                ChekinanaNLTimingLog.completed(
                    operationCount: operationCount,
                    startedAt: interpretationStartedAt
                )
#endif
                guard nlRequestGate.accepts(
                    requestGeneration,
                    isCancelled: Task.isCancelled
                ) else { return }
                nlRequestTask = nil
                activeNLRequest = nil
                pendingNLRetry = nil
                processConversationResult(
                    ChekinanaConversationCoordinator.compile(
                        interpretation,
                        continuingIntent: request.draft?.intent,
                        selections: request.selections,
                        modelContext: modelContext
                    ),
                    originalUtterance: request.input
                )
            } catch {
#if DEBUG
                ChekinanaNLTimingLog.failed(startedAt: interpretationStartedAt)
#endif
                guard nlRequestGate.accepts(
                    requestGeneration,
                    isCancelled: Task.isCancelled
                ) else { return }
                nlRequestTask = nil
                activeNLRequest = nil
                let clientError = error as? ChekinanaNLClientError
                let message = clientError.map(ChekinanaConversationMessage.forClientError) ?? .networkUnavailable
                transcriptMessages.append(
                    TranscriptMessage(content: .text(message.text))
                )
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prompt = request.input
                }
                if clientError != .sensitiveInput && clientError != .invalidRequest {
                    pendingNLRetry = request
                }
                isSubmitting = false
            }
        }
        nlRequestTask = task
    }

    @MainActor
    private func startEventCandidateExtraction(url: String, echo: String?) {
        startEventCandidateExtraction(request: .weiboURL(url), echo: echo)
    }

    private enum EventCandidateRequest: Equatable {
        case weiboURL(String)
        case text(String)

        var stateKey: String {
            switch self {
            case .weiboURL(let url): url
            case .text: "event-candidate-text"
            }
        }
    }

    @MainActor
    private func startEventCandidateExtraction(
        request: EventCandidateRequest,
        echo: String?
    ) {
        guard !isSubmitting else { return }
        if let echo {
            appendUserMessage(redactedCommandEcho(for: echo))
        }
        eventCandidateTask?.cancel()
        activeEventCandidateRequest = request
        let generation = eventCandidateState.begin(url: request.stateKey)
        guard eventCandidateBusyOwner.acquire(generation: generation) else {
            eventCandidateState.invalidate()
            return
        }
        isSubmitting = true
        let task = Task { @MainActor in
            do {
                let client = ChekinanaEventCandidateClient()
                let fields: ChekinanaEventCandidateFields
                switch request {
                case .weiboURL(let url):
                    fields = try await client.fetch(weiboURL: url)
                case .text(let text):
                    fields = try await client.parse(text: text)
                }
                guard eventCandidateState.accepts(generation, isCancelled: Task.isCancelled),
                      eventCandidateBusyOwner.owns(
                        generation: generation,
                        isCancelled: Task.isCancelled
                      ) else {
                    return
                }
                eventCandidateTask = nil
                guard eventCandidateState.complete(fields, generation: generation) else { return }
                guard releaseEventCandidateBusy(generation: generation) else { return }
                transcriptMessages.append(TranscriptMessage(content: .text(
                    ChekinanaL10n.text(
                        "assistant.event.extracted",
                        fallback: "Event details were extracted. Review every field; nothing has been saved yet."
                    )
                )))
            } catch is CancellationError {
                guard eventCandidateState.accepts(generation, isCancelled: Task.isCancelled),
                      eventCandidateBusyOwner.owns(
                        generation: generation,
                        isCancelled: Task.isCancelled
                      ) else {
                    return
                }
                eventCandidateTask = nil
                eventCandidateState.invalidate()
                _ = releaseEventCandidateBusy(generation: generation)
            } catch {
                guard eventCandidateState.accepts(generation, isCancelled: Task.isCancelled),
                      eventCandidateBusyOwner.owns(
                        generation: generation,
                        isCancelled: Task.isCancelled
                      ) else {
                    return
                }
                eventCandidateTask = nil
                let message = (error as? ChekinanaEventCandidateClientError)?.localizedDescription
                    ?? ChekinanaEventCandidateClientError.networkUnavailable.localizedDescription
                guard eventCandidateState.fail(
                    url: request.stateKey,
                    message: message,
                    generation: generation
                ) else {
                    return
                }
                _ = releaseEventCandidateBusy(generation: generation)
            }
        }
        eventCandidateTask = task
    }

    private func eventCandidateFieldsBinding(
        fallback: ChekinanaEventCandidateFields
    ) -> Binding<ChekinanaEventCandidateFields> {
        Binding(
            get: {
                guard case .editing(let fields) = eventCandidateState.phase else { return fallback }
                return fields
            },
            set: {
                guard !isSubmitting else { return }
                eventCandidateState.update($0)
            }
        )
    }

    @MainActor
    private func prepareEventCandidateConfirmation() {
        guard !isSubmitting,
              case .editing(let fields) = eventCandidateState.phase,
              ChekinanaEventCandidateValidator.blockers(for: fields).isEmpty else {
            return
        }
        let executor = ChekinanaCommandExecutor(
            modelContext: modelContext,
            confirmationLedger: confirmationLedger
        )
        let output = executor.prepareEventCandidate(fields)
        if case .text(let text) = output, text.hasPrefix("error:") {
            handleCommandResponse(output)
            return
        }
        eventCandidateTask = nil
        eventCandidateState.invalidate()
        activeEventCandidateRequest = nil
        handleCommandResponse(output)
    }

    @MainActor
    private func cancelEventCandidateFlow(announce: Bool) {
        let ownedGeneration = eventCandidateBusyOwner.generation
        eventCandidateTask?.cancel()
        eventCandidateTask = nil
        eventCandidateState.invalidate()
        activeEventCandidateRequest = nil
        if let ownedGeneration {
            _ = releaseEventCandidateBusy(generation: ownedGeneration)
        }
        if announce {
            transcriptMessages.append(TranscriptMessage(content: .text(
                ChekinanaL10n.text(
                    "assistant.event.cancelled",
                    fallback: "The Event candidate was cancelled. No Event was saved."
                )
            )))
        }
    }

    @MainActor
    private func invalidateEventCandidateFlow() {
        cancelEventCandidateFlow(announce: false)
    }

    @discardableResult
    private func releaseEventCandidateBusy(generation: UInt64) -> Bool {
        guard eventCandidateBusyOwner.release(generation: generation) else {
            return false
        }
        isSubmitting = false
        return true
    }

    private func retryRemoteInterpretation() {
        guard let request = pendingNLRetry, !isSubmitting else { return }
        prompt = ""
        startRemoteInterpretation(request)
    }

    private func cancelRemoteInterpretation() {
        let request = activeNLRequest
        invalidateRemoteRequest()
        activeNLRequest = nil
        pendingNLRetry = nil
        isSubmitting = false
        if let request, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = request.input
        }
        transcriptMessages.append(TranscriptMessage(content: .text(
            ChekinanaL10n.text(
                "assistant.interpretation.cancelled",
                fallback: "The request was cancelled. Your input and current selections were preserved."
            )
        )))
    }

    private func cancelPendingRetry() {
        pendingNLRetry = nil
        transcriptMessages.append(TranscriptMessage(content: .text(
            ChekinanaL10n.text(
                "assistant.retry.cancelled",
                fallback: "Retry was cancelled. Your input remains in the composer."
            )
        )))
    }

    private func invalidateRemoteRequest() {
        nlRequestTask?.cancel()
        nlRequestTask = nil
        nlRequestGate.invalidate()
    }

    private func invalidateIdolRunners() {
        idolCandidateSelectionGate.invalidate()
        idolConfirmationGate.invalidate()
        idolCandidateSelectionTask?.cancel()
        idolCandidateSelectionTask = nil
        idolConfirmationTask?.cancel()
        idolConfirmationTask = nil
        idolConfirmationTimeoutTask?.cancel()
        idolConfirmationTimeoutTask = nil
        confirmationLedger.invalidateIdolCandidates()
        activeIdolCandidateTokens.removeAll()
        isSubmitting = false
    }

    private func cancelConversation() {
        invalidateRemoteRequest()
        activeNLRequest = nil
        pendingNLRetry = nil
        confirmationLedger.invalidateIdolCandidates()
        activeIdolCandidateTokens.removeAll()
        conversationState.clearDraft()
        isSubmitting = false
        transcriptMessages.append(TranscriptMessage(content: .text(
            ChekinanaL10n.text("assistant.conversation.cancelled", fallback: "The conversation was cancelled.")
        )))
    }

    private func submitExplicitCommand(_ command: String) {
        guard !isSubmitting else { return }
        let actionText = commandName(from: command) == "cancel"
            ? ChekinanaL10n.text("assistant.action.cancelled", fallback: "Cancelled")
            : ChekinanaL10n.text("assistant.action.confirmed", fallback: "Confirmed")
        transcriptMessages.append(
            TranscriptMessage(role: .user, content: .text(actionText))
        )
        executeCommands([command], announceSingle: false)
    }

    private func executeCommands(
        _ commands: [String],
        announceSingle: Bool = true,
        continuesAfterOperationFailure: Bool = false,
        batchesIdolAdds: Bool = true
    ) {
        guard !commands.isEmpty, !isSubmitting else { return }
        if batchesIdolAdds, commands.allSatisfy({ commandName(from: $0) == "addidol" }) {
            isSubmitting = true
            commandExecutionTask = Task { @MainActor in
                defer {
                    commandExecutionTask = nil
                    isSubmitting = false
                }
                let executor = ChekinanaCommandExecutor(
                    modelContext: modelContext,
                    confirmationLedger: confirmationLedger
                )
                let output = await executor.addIdols(commands)
                guard !Task.isCancelled else { return }
                handleCommandResponse(output)
            }
            return
        }
        if commands.count == 1,
           let command = commands.first,
           isAddIdolConfirmationCommand(command) {
            executeAddIdolConfirmation(command)
            return
        }
        if commands.contains(where: invalidatesVisibleIdolCandidates) {
            activeIdolCandidateTokens.removeAll()
        }
        isSubmitting = true

        let task = Task { @MainActor in
            defer { commandExecutionTask = nil }
            let executor = ChekinanaCommandExecutor(
                modelContext: modelContext,
                confirmationLedger: confirmationLedger
            )
            for (index, command) in commands.enumerated() {
                guard !Task.isCancelled else {
                    isSubmitting = false
                    return
                }
                let output: ChekinanaCommandResponse
                do {
                    let pendingImages = try await loadPendingChekiImages(for: command)
                    output = await executor.execute(command, pendingChekiImages: pendingImages)
                } catch ChekinanaAsyncDeadlineError.cancelled {
                    isSubmitting = false
                    return
                } catch {
                    output = .text(ChekinanaL10n.format(
                        "assistant.photo.load_failed",
                        fallback: "error: The selected photos could not be loaded. Keep them selected and try again. %@",
                        error.localizedDescription
                    ))
                }
                guard !Task.isCancelled else {
                    isSubmitting = false
                    return
                }
                handleCommandResponse(output)

                if ChekinanaConversationCoordinator.responseStopsPlan(output) {
                    if index + 1 < commands.count {
                        if continuesAfterOperationFailure,
                           case .text(let text) = output,
                           text.hasPrefix("error:") {
                            continue
                        }
                        transcriptMessages.append(TranscriptMessage(content: .text(
                            ChekinanaL10n.text(
                                "assistant.plan.stopped",
                                fallback: "Later operations were stopped safely. Complete the current choice or correct the error first."
                            )
                        )))
                    }
                    if case .requestAddChekiPhoto = output {
                        return
                    }
                    isSubmitting = false
                    return
                }
            }
            isSubmitting = false
        }
        commandExecutionTask = task
    }

    private func executeAddIdolConfirmation(_ command: String) {
        guard !isSubmitting else { return }
        isSubmitting = true
        let executionID = idolConfirmationGate.begin()

        let operationTask = Task { @MainActor in
            guard idolConfirmationGate.accepts(
                executionID,
                isCancelled: Task.isCancelled
            ) else { return }
#if DEBUG
            if ProcessInfo.processInfo.environment["CHEKINANA_IDOL_CONFIRM_UI_STUB"] == "hang" {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
            }
#endif
            guard idolConfirmationGate.accepts(
                executionID,
                isCancelled: Task.isCancelled
            ) else { return }
            let executor = ChekinanaCommandExecutor(
                modelContext: modelContext,
                confirmationLedger: confirmationLedger
            )
            let output = await executor.execute(command)
            guard idolConfirmationGate.accepts(
                executionID,
                isCancelled: Task.isCancelled
            ) else { return }
            finishAddIdolConfirmation(executionID: executionID, output: output)
        }
        idolConfirmationTask = operationTask

        idolConfirmationTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.idolConfirmationTimeoutNanoseconds)
            } catch {
                return
            }
            guard idolConfirmationGate.accepts(executionID, isCancelled: false) else { return }
            operationTask.cancel()
            guard idolConfirmationGate.finish(executionID) else { return }
            idolConfirmationTask = nil
            idolConfirmationTimeoutTask = nil
            isSubmitting = false
            handleCommandResponse(.text(
                ChekinanaL10n.text(
                    "assistant.idol.confirmation_timeout",
                    fallback: "error: Idol confirmation timed out before saving. No Idol was saved, and the confirmation can be retried."
                )
            ))
        }
    }

    private func finishAddIdolConfirmation(
        executionID: UUID,
        output: ChekinanaCommandResponse
    ) {
        guard idolConfirmationGate.finish(executionID) else { return }
        idolConfirmationTimeoutTask?.cancel()
        idolConfirmationTimeoutTask = nil
        idolConfirmationTask = nil
        // Publish the response only after the composer and confirmation actions
        // are ready again. This prevents card layout from delaying busy cleanup.
        isSubmitting = false
        handleCommandResponse(output)
        if case .idolCard(let idol) = output {
            transcriptMessages.append(TranscriptMessage(content: .text(
                ChekinanaL10n.format("assistant.idol.added", fallback: "Added %@.", idol.name)
            )))
        }
    }

    private func isAddIdolConfirmationCommand(_ command: String) -> Bool {
        let tokens = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let code: String?
        if tokens.count == 1, ChekinanaConfirmationLedger.isCode(tokens[0]) {
            code = tokens[0]
        } else if tokens.count == 2,
                  tokens[0].lowercased() == "confirm",
                  ChekinanaConfirmationLedger.isCode(tokens[1]) {
            code = tokens[1]
        } else if tokens.count == 1,
                  tokens[0].lowercased() == "confirm",
                  case .code(let implicitCode) = confirmationLedger.implicitConfirmation() {
            code = implicitCode
        } else {
            code = nil
        }
        guard let code,
              let entry = confirmationLedger.entry(for: code),
              case .addIdol = entry.action else {
            return false
        }
        return true
    }

    private func invalidatesVisibleIdolCandidates(_ command: String) -> Bool {
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch commandName(from: normalized) {
        case "addidol", "selectidolcandidate", "clear":
            return true
        case "cancel":
            return normalized.split(whereSeparator: { $0.isWhitespace }).dropFirst().first == "all"
        default:
            return false
        }
    }

    private func cancelMediaProcessing() {
        commandExecutionTask?.cancel()
        commandExecutionTask = nil
        albumProcessingTask?.cancel()
        albumProcessingTask = nil
        if let sessionID = albumPickerState.activeSessionID {
            _ = albumPickerState.cancelProcessing(sessionID: sessionID)
        }
        albumAddChekiRequest = nil
        albumAddChekiItems = []
        mediaLoadProgress = ""
        isSubmitting = false
        transcriptMessages.append(TranscriptMessage(content: .text(
            ChekinanaL10n.text(
                "assistant.photo_processing.cancelled",
                fallback: "Photo processing was cancelled. No new Cheki was created."
            )
        )))
    }

    @MainActor
    private func processConversationResult(
        _ result: ChekinanaConversationCompileResult,
        originalUtterance: String? = nil
    ) {
        switch result {
        case .commands(let commands):
            conversationState.clearDraft()
            isSubmitting = false
            executeTypedCommands(commands)
        case .eventCandidateURL:
            conversationState.clearDraft()
            isSubmitting = false
            guard case .weiboURL(let routedURL) = ChekinanaEventCandidateConversationRoute.resolve(
                result,
                originalUtterance: originalUtterance
            ) else {
                transcriptMessages.append(TranscriptMessage(content: .text(
                    ChekinanaConversationMessage.invalidPlan.text
                )))
                return
            }
            startEventCandidateExtraction(url: routedURL, echo: nil)
        case .eventCandidateText:
            conversationState.clearDraft()
            isSubmitting = false
            guard case .text(let text) = ChekinanaEventCandidateConversationRoute.resolve(
                result,
                originalUtterance: originalUtterance
            ) else {
                transcriptMessages.append(TranscriptMessage(content: .text(
                    ChekinanaConversationMessage.invalidPlan.text
                )))
                return
            }
            startEventCandidateExtraction(request: .text(text), echo: nil)
        case .clarification(let draft):
            conversationState.draft = draft
            clarificationDate = Date()
            transcriptMessages.append(
                TranscriptMessage(content: .text(clarificationPrompt(for: draft)))
            )
            isSubmitting = false
        case .message(let message):
            conversationState.clearDraft()
            transcriptMessages.append(TranscriptMessage(content: .text(message.text)))
            isSubmitting = false
        }
    }

    private func executeTypedCommands(_ commands: [String]) {
        let idolCandidateIDs = (
            try? modelContext.fetch(FetchDescriptor<Idol>())
        )?
            .filter {
                $0.hasRecognitionPatterns
                    && ChekinanaVisibilityPolicy.includesIdol(
                        $0.id,
                        hiddenIDs: ChekinanaHiddenIdolPersistence.load()
                    )
            }
            .map(\.id) ?? []
        let selectedCandidateIDs = scannerCandidateIDs.map { selected in
            idolCandidateIDs.filter(selected.contains)
        } ?? idolCandidateIDs
        switch ChekinanaScannerConfiguration.prepareTypedCommands(
            commands,
            baseURLResolution: ChekinanaScannerConfiguration.configuredBaseURL(),
            dateRecognitionEnabled: isScannerDateRecognitionEnabled,
            dateBounds: scannerDateBounds,
            idolRecognitionEnabled: isScannerIdolRecognitionEnabled,
            idolCandidateIDs: selectedCandidateIDs,
            includeUnassignedCandidate: scannerIncludesUnassignedCandidate
        ) {
        case .ready(let preparedCommands):
            executeCommands(
                preparedCommands,
                continuesAfterOperationFailure: true,
                batchesIdolAdds: false
            )
        case .rejected(let failure):
            transcriptMessages.append(
                TranscriptMessage(content: .text(failure.userMessage))
            )
        }
    }

    @MainActor
    private func handleCommandResponse(_ output: ChekinanaCommandResponse) {
        switch output {
        case .clearTranscript:
            invalidateRemoteRequest()
            invalidateEventCandidateFlow()
            confirmationLedger.invalidateIdolCandidates()
            transcriptMessages.removeAll()
            activeIdolCandidateTokens.removeAll()
            confirmedIdolCandidateTokens.removeAll()
            conversationState.clearDraft()
            selectedChekiID = nil
            pendingNLRetry = nil
        case .requestAddChekiPhoto(let request):
            albumPickerCancellationTask?.cancel()
            albumPickerCancellationTask = nil
            albumAddChekiRequest = request
            albumAddChekiItems = []
            albumPickerState.begin()
        case .shellAction(let action, let message):
            if let onShellAction {
                onShellAction(action)
                transcriptMessages.append(TranscriptMessage(content: .text(message)))
            } else {
                transcriptMessages.append(TranscriptMessage(content: .text(
                    ChekinanaL10n.text(
                        "assistant.navigation.unavailable",
                        fallback: "This navigation action is not available from the current presentation."
                    )
                )))
            }
        default:
            if case .idolCards(let cards) = output {
                removeIdolCandidateMessages()
                activeIdolCandidateTokens = Set(cards.compactMap(\.selectionToken))
                confirmedIdolCandidateTokens.removeAll()
            } else if case .idolCardsWithNotice(let cards, _) = output {
                removeIdolCandidateMessages()
                activeIdolCandidateTokens = Set(cards.compactMap(\.selectionToken))
                confirmedIdolCandidateTokens.removeAll()
            }
            transcriptMessages.append(TranscriptMessage(content: .commandResponse(output)))
            let codes = ChekinanaConversationCoordinator.confirmationCodes(in: output)
            if !codes.isEmpty {
                transcriptMessages.append(TranscriptMessage(content: .confirmationActions(codes)))
            }
            if case .chekiScannedCards = output {
                transcriptMessages.append(TranscriptMessage(content: .scanAllShortcut))
            }
            if output.consumesSelectedPhotos {
                selectedItems = []
                isScannerDateRecognitionEnabled =
                    ChekinanaScannerRecognitionDefaults.dateIsEnabled
                isScannerIdolRecognitionEnabled =
                    ChekinanaScannerRecognitionDefaults.idolIsEnabled
            }
            if case .text(let text) = output, text.hasPrefix("已删除这张切") {
                selectedChekiID = nil
            }
        }
    }

    private func selectCheki(_ card: ChekinanaChekiCard) {
        selectedChekiID = card.id
        let title = card.idx.map {
            ChekinanaL10n.format("assistant.cheki.index", fallback: "Cheki #%lld", Int64($0))
        } ?? ChekinanaL10n.text("assistant.cheki.this", fallback: "this Cheki")
        transcriptMessages.append(TranscriptMessage(content: .text(
            ChekinanaL10n.format(
                "assistant.cheki.selected",
                fallback: "Selected %@. You can now ask to view, edit, or delete it.",
                title
            )
        )))
    }

    private func beginEditingTemporaryCheki(_ card: ChekinanaChekiCard) {
        guard let temporary = confirmationLedger.temporaryCheki(card.id) else {
            transcriptMessages.append(TranscriptMessage(
                content: .text(ChekinanaL10n.text(
                    "assistant.temporary.invalid",
                    fallback: "This temporary Cheki is no longer available."
                ))
            ))
            return
        }
        temporaryEditorDraft = TemporaryChekiEditorDraft(
            id: temporary.id,
            idolIDs: Set(temporary.idolIDs),
            hasDate: temporary.date != nil,
            date: temporary.date.flatMap {
                ChekinanaDateOnly.displayDate(from: $0, calendar: .current)
            } ?? Date(),
            eventID: temporary.eventID,
            idxText: temporary.idx.map(String.init) ?? "",
            initialIdxText: temporary.idx.map(String.init) ?? "",
            userAppears: temporary.userAppears,
            size: temporary.size,
            isFavorite: temporary.isFavorite,
            hasPostedToSNS: temporary.hasPostedToSNS,
            note: temporary.note
        )
        isTemporaryEditorPresented = true
    }

    private func saveTemporaryEditor() {
        let draft = temporaryEditorDraft
        let normalizedDate: Date?
        if draft.hasDate {
            guard let date = ChekinanaDateOnly.canonicalDate(
                from: draft.date,
                displayedIn: .current
            ) else {
                transcriptMessages.append(TranscriptMessage(
                    content: .text(ChekinanaL10n.text(
                        "assistant.temporary.invalid_date",
                        fallback: "The selected date could not be read. Choose it again."
                    ))
                ))
                return
            }
            normalizedDate = date
        } else {
            normalizedDate = nil
        }
        let normalizedIdxText = draft.idxText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let idx: Int?
        if normalizedIdxText.isEmpty {
            idx = nil
        } else if let parsed = Int(normalizedIdxText), parsed > 0 {
            idx = parsed
        } else {
            transcriptMessages.append(TranscriptMessage(
                content: .text(ChekinanaL10n.text(
                    "assistant.temporary.invalid_index",
                    fallback: "The index must be empty or a positive integer."
                ))
            ))
            return
        }
        let group = ChekinanaChekiGroupKey(
            idolIDs: Array(draft.idolIDs),
            date: normalizedDate
        )
        if idx != nil, group == nil {
            transcriptMessages.append(TranscriptMessage(
                content: .text(ChekinanaL10n.text(
                    "assistant.temporary.index_requires_group",
                    fallback: "A positive index requires a date and at least one Idol."
                ))
            ))
            return
        }
        if normalizedIdxText != draft.initialIdxText,
           let idx, let group,
           ((try? modelContext.fetch(FetchDescriptor<Cheki>())) ?? []).contains(where: {
               ChekinanaChekiGroupKey(
                   idolIDs: $0.idols.map(\.id),
                   date: $0.date
               ) == group && $0.idx == idx
           }) {
            transcriptMessages.append(TranscriptMessage(
                content: .text(ChekinanaL10n.format(
                    "assistant.temporary.index_conflict",
                    fallback: "Index #%lld is already used by this Idol/date group.",
                    Int64(idx)
                ))
            ))
            return
        }
        guard let currentTemporary = confirmationLedger.temporaryCheki(draft.id) else {
            transcriptMessages.append(TranscriptMessage(
                content: .text(ChekinanaL10n.text(
                    "assistant.temporary.update_failed",
                    fallback: "This temporary Cheki could not be updated; it may have expired."
                ))
            ))
            return
        }
        let validEventID = ChekinanaChekiEventSelectionPolicy.validatedEventID(
            draft.eventID,
            recordDate: normalizedDate,
            events: (try? modelContext.fetch(FetchDescriptor<Event>())) ?? []
        )
        guard confirmationLedger.updateTemporaryCheki(
            id: draft.id,
            idolIDs: Array(draft.idolIDs),
            date: normalizedDate,
            eventID: validEventID,
            userAppears: draft.userAppears ?? false,
            size: draft.size,
            isFavorite: draft.isFavorite,
            hasPostedToSNS: draft.hasPostedToSNS,
            note: draft.note,
            idx: idx,
            idxWasManuallyEdited: normalizedIdxText != draft.initialIdxText,
            existingChekiID: currentTemporary.existingChekiID,
            existingSelectionIsManual: currentTemporary.existingSelectionIsManual
        ) else {
            transcriptMessages.append(TranscriptMessage(
                content: .text(ChekinanaL10n.text(
                    "assistant.temporary.update_unavailable",
                    fallback: "This temporary Cheki could not be updated; it may have expired or entered confirmation."
                ))
            ))
            isTemporaryEditorPresented = false
            return
        }
        refreshTemporaryChekiCard(draft.id)
        isTemporaryEditorPresented = false
    }

    private func deleteTemporaryCheki(_ card: ChekinanaChekiCard) {
        guard confirmationLedger.discardTemporaryCheki(id: card.id) else {
            transcriptMessages.append(TranscriptMessage(content: .text(
                ChekinanaL10n.text(
                    "assistant.temporary.delete_failed",
                    fallback: "This temporary Cheki could not be deleted. Cancel its confirmation first if needed."
                )
            )))
            return
        }
        refreshTemporaryChekiCard(card.id)
        transcriptMessages.append(TranscriptMessage(content: .text(
            ChekinanaL10n.text(
                "assistant.temporary.deleted",
                fallback: "The temporary Cheki was deleted without changing the database or image storage."
            )
        )))
    }

    private func downloadTemporaryCheki(_ card: ChekinanaChekiCard) {
        executeCommands([
            "downloadtemporarycheki \(card.id.uuidString.lowercased())",
        ])
    }

    private func refreshTemporaryChekiCard(_ id: UUID) {
        let temporary = confirmationLedger.temporaryCheki(id)
        let idolsByID = Dictionary(
            uniqueKeysWithValues: ((try? modelContext.fetch(FetchDescriptor<Idol>())) ?? [])
                .filter {
                    ChekinanaVisibilityPolicy.includesIdol(
                        $0.id,
                        hiddenIDs: ChekinanaHiddenIdolPersistence.load()
                    )
                }
                .map { ($0.id, $0) }
        )
        let eventsByID = Dictionary(
            uniqueKeysWithValues: ((try? modelContext.fetch(FetchDescriptor<Event>())) ?? [])
                .map { ($0.id, $0) }
        )
        let replacement = temporary.map { value in
            ChekinanaChekiCard(
                id: value.id,
                imageRef: nil,
                createdAt: value.createdAt,
                confirmationCode: nil,
                thumbnailImageData: value.thumbnailImageData,
                idolNames: value.idolIDs.compactMap { idolsByID[$0]?.name },
                eventName: value.eventID.flatMap { eventsByID[$0]?.name },
                eventDateText: value.date.map(calendarDateString),
                userAppears: value.userAppears,
                size: value.size,
                isFavorite: value.isFavorite,
                hasPostedToSNS: value.hasPostedToSNS,
                note: value.note,
                dateAnnotationState: value.dateAnnotationState
            )
        }
        for index in transcriptMessages.indices {
            guard case .chekiScannedCards(
                _,
                let warningCount,
                let cards
            ) = transcriptMessages[index].content,
                  cards.contains(where: { $0.id == id }) else {
                continue
            }
            let updatedCards = cards.compactMap { card -> ChekinanaChekiCard? in
                guard card.id == id else { return card }
                return replacement
            }
            transcriptMessages[index] = TranscriptMessage(
                id: transcriptMessages[index].id,
                role: transcriptMessages[index].role,
                content: .chekiScannedCards(
                    count: updatedCards.count,
                    warningCount: warningCount,
                    chekis: updatedCards
                )
            )
        }
    }

    private func calendarDateString(_ date: Date) -> String {
        ChekinanaDateOnly.string(date)
    }

    private func selectIdolCandidate(_ token: String) {
        guard !isSubmitting, activeIdolCandidateTokens.contains(token) else { return }
        isSubmitting = true
        let executionID = idolCandidateSelectionGate.begin()

        let task = Task { @MainActor in
            guard idolCandidateSelectionGate.accepts(
                executionID,
                isCancelled: Task.isCancelled
            ) else { return }
            let executor = ChekinanaCommandExecutor(
                modelContext: modelContext,
                confirmationLedger: confirmationLedger
            )
            let output = await executor.execute("confirmidolcandidate \(token)")
            guard idolCandidateSelectionGate.accepts(
                executionID,
                isCancelled: Task.isCancelled
            ) else { return }
            finishIdolCandidateSelection(
                executionID: executionID,
                token: token,
                output: output
            )
        }
        idolCandidateSelectionTask = task
    }

    private func finishIdolCandidateSelection(
        executionID: UUID,
        token: String,
        output: ChekinanaCommandResponse
    ) {
        guard idolCandidateSelectionGate.finish(executionID) else { return }
        idolCandidateSelectionTask = nil
        isSubmitting = false
        if case .idolCard(let idol) = output {
            activeIdolCandidateTokens.remove(token)
            confirmedIdolCandidateTokens.insert(token)
            // Candidate success is represented by the in-place checkmark.
            // Appending a new transcript row would trigger the normal
            // assistant-text bottom scroll and move a long candidate list
            // away from the card the user just selected.
            UIAccessibility.post(
                notification: .announcement,
                argument: ChekinanaL10n.format(
                    "assistant.idol.added_announcement",
                    fallback: "Added %@.",
                    idol.name
                )
            )
        } else {
            handleCommandResponse(output)
        }
    }

    private func cancelIdolCandidates() {
        guard !isSubmitting else { return }
        confirmationLedger.invalidateIdolCandidates()
        activeIdolCandidateTokens.removeAll()
        confirmedIdolCandidateTokens.removeAll()
        removeIdolCandidateMessages()
        transcriptMessages.append(TranscriptMessage(content: .text(
            ChekinanaL10n.text(
                "assistant.idol_candidates.cancelled",
                fallback: "The Idol candidates were cancelled. Their previous buttons are no longer active."
            )
        )))
    }

    private func removeIdolCandidateMessages(containing token: String? = nil) {
        transcriptMessages.removeAll { message in
            let cards: [ChekinanaIdolCard]
            switch message.content {
            case .idolCards(let values), .idolCardsWithNotice(let values, _):
                cards = values
            default:
                return false
            }
            guard let token else { return cards.contains { $0.selectionToken != nil } }
            return cards.contains { $0.selectionToken == token }
        }
    }

    private func toggleSelectedIdol(_ id: UUID) {
        guard var draft = conversationState.draft else { return }
        if let index = draft.selections.selectedIdolIDs.firstIndex(of: id) {
            draft.selections.selectedIdolIDs.remove(at: index)
        } else {
            draft.selections.selectedIdolIDs.append(id)
        }
        conversationState.draft = draft
    }

    private func completeIdolSelection() {
        guard var draft = conversationState.draft,
              !draft.selections.selectedIdolIDs.isEmpty else { return }
        draft.removeMissing(.idol)
        conversationState.draft = draft
        advanceConversationDraft()
    }

    private func chooseEvent(_ id: UUID) {
        guard var draft = conversationState.draft else { return }
        draft.selections.selectedEventID = id
        draft.selections.selectedDate = nil
        draft.removeMissing(.eventOrDate)
        conversationState.draft = draft
        advanceConversationDraft()
    }

    private func chooseDateInsteadOfEvent() {
        guard var draft = conversationState.draft else { return }
        clarificationDate = Date()
        draft.selections.selectedEventID = nil
        draft.removeMissing(.eventOrDate)
        if !draft.missing.contains(.date) {
            draft.missing.insert(.date, at: 0)
        }
        conversationState.draft = draft
        transcriptMessages.append(
            TranscriptMessage(content: .text(clarificationPrompt(for: draft)))
        )
    }

    private func completeDateSelection() {
        guard var draft = conversationState.draft else { return }
        draft.selections.selectedDate = ChekinanaNLInterpretClient.localDateString(clarificationDate)
        draft.selections.selectedEventID = nil
        draft.removeMissing(.date)
        draft.removeMissing(.eventOrDate)
        conversationState.draft = draft
        advanceConversationDraft()
    }

    private func toggleSelectedTemporaryCheki(_ id: UUID) {
        guard var draft = conversationState.draft else { return }
        if let index = draft.selections.selectedTemporaryIDs.firstIndex(of: id) {
            draft.selections.selectedTemporaryIDs.remove(at: index)
        } else {
            draft.selections.selectedTemporaryIDs.append(id)
        }
        draft.selections.usesAllTemporaryChekis = false
        conversationState.draft = draft
    }

    private func completeTemporarySelection() {
        guard var draft = conversationState.draft,
              !draft.selections.selectedTemporaryIDs.isEmpty else { return }
        draft.removeMissing(.temporaryCheki)
        conversationState.draft = draft
        advanceConversationDraft()
    }

    private func useAllTemporaryChekis() {
        guard var draft = conversationState.draft else { return }
        draft.selections.usesAllTemporaryChekis = true
        draft.selections.selectedTemporaryIDs = []
        draft.removeMissing(.temporaryCheki)
        conversationState.draft = draft
        advanceConversationDraft()
    }

    private func applyLocalChoice(_ id: UUID) {
        guard var draft = conversationState.draft,
              let localChoice = draft.localChoice,
              localChoice.options.contains(where: { $0.id == id }) else { return }
        switch localChoice.kind {
        case .idol(let query):
            draft.selections.idolOverrides[query] = id
        case .event(let query):
            draft.selections.eventOverrides[query] = id
        }
        draft.localChoice = nil
        conversationState.draft = draft
        advanceConversationDraft()
    }

    private func advanceConversationDraft() {
        guard let draft = conversationState.draft else { return }
        if !draft.missing.isEmpty || draft.localChoice != nil {
            transcriptMessages.append(
                TranscriptMessage(content: .text(clarificationPrompt(for: draft)))
            )
            return
        }
        processConversationResult(
            ChekinanaConversationCoordinator.resume(draft, modelContext: modelContext)
        )
    }

    private func beginScanAllClarification() {
        guard !confirmationLedger.availableTemporaryChekiChoices().isEmpty else {
            transcriptMessages.append(
                TranscriptMessage(content: .text(ChekinanaL10n.text(
                    "assistant.no_scan_results",
                    fallback: "No scan results are available. Select photos and scan first."
                )))
            )
            return
        }
        conversationState.clearDraft()
        executeCommands(["addscancheki all"])
    }

    private func clarificationPrompt(for draft: ChekinanaConversationDraftState) -> String {
        if let localChoice = draft.localChoice {
            switch localChoice.kind {
            case .idol:
                return ChekinanaL10n.text("assistant.prompt.multiple_idol", fallback: "Multiple Idols matched. Choose one.")
            case .event:
                return ChekinanaL10n.text("assistant.prompt.multiple_event", fallback: "Multiple Events matched. Choose one.")
            }
        }
        switch draft.missing.first {
        case .idol:
            return draft.requiresFreeTextIdolName
                ? ChekinanaL10n.text("assistant.prompt.idol_name", fallback: "Enter the Idol name to add.")
                : ChekinanaL10n.text("assistant.prompt.idol", fallback: "Choose at least one local Idol.")
        case .eventOrDate:
            return ChekinanaL10n.text("assistant.prompt.event_or_date", fallback: "Choose a local Event or use a date.")
        case .eventName:
            return ChekinanaL10n.text("assistant.prompt.event_name", fallback: "Enter an Event name. The URL, if any, was preserved.")
        case .date:
            return ChekinanaL10n.text("assistant.prompt.date", fallback: "Choose a date.")
        case .temporaryCheki:
            return ChekinanaL10n.text("assistant.prompt.scan_result", fallback: "Choose the scan results to save.")
        case nil:
            return ChekinanaL10n.text("assistant.prompt.complete", fallback: "Complete this operation.")
        }
    }

    private var albumPickerPresentationBinding: Binding<Bool> {
        let sessionID = albumPickerState.activeSessionID
        return Binding(
            get: {
                guard sessionID == albumPickerState.activeSessionID else { return false }
                return albumPickerState.isPresented
            },
            set: { isPresented in
                guard let sessionID else { return }
                if !isPresented {
                    scheduleAlbumPickerCancellation(sessionID: sessionID)
                }
            }
        )
    }

    private var albumPickerSelectionBinding: Binding<[PhotosPickerItem]> {
        let sessionID = albumPickerState.activeSessionID
        return Binding(
            get: {
                guard sessionID == albumPickerState.activeSessionID else { return [] }
                return albumAddChekiItems
            },
            set: { items in
                guard let sessionID, !items.isEmpty else { return }
                handleAlbumAddChekiSelection(items, sessionID: sessionID)
            }
        )
    }

    @MainActor
    private func scheduleAlbumPickerCancellation(sessionID: UUID) {
        guard albumPickerState.markAwaitingSelection(sessionID: sessionID) else { return }
        albumPickerCancellationTask?.cancel()
        albumPickerCancellationTask = Task { @MainActor in
            do {
                // PhotosPicker can dismiss before its selection binding is
                // updated. Give that binding a short, cancellable window to
                // settle before treating dismissal as a real cancellation.
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }

            guard albumPickerState.cancel(sessionID: sessionID) else { return }
            albumAddChekiRequest = nil
            albumAddChekiItems = []
            albumPickerCancellationTask = nil
            transcriptMessages.append(TranscriptMessage(content: .text(
                ChekinanaL10n.text("assistant.album.cancelled", fallback: "Album selection was cancelled.")
            )))
            isSubmitting = false
        }
    }

    @MainActor
    private func handleAlbumAddChekiSelection(_ items: [PhotosPickerItem], sessionID: UUID) {
        guard let request = albumAddChekiRequest,
              isSubmitting,
              albumPickerState.beginProcessing(sessionID: sessionID) else {
            return
        }

        albumPickerCancellationTask?.cancel()
        albumPickerCancellationTask = nil
        albumAddChekiItems = items

        let task = Task { @MainActor in
            defer {
                albumProcessingTask = nil
                mediaLoadProgress = ""
            }
            var prepared: [ChekinanaPreparedAlbumCheki] = []
            var failedCount = 0
            // Process a bounded batch sequentially. This avoids decoding and
            // copying several full-resolution Photos assets at once.
            let boundedItems = items
            for (index, item) in boundedItems.enumerated() {
                guard !Task.isCancelled else { return }
                mediaLoadProgress = ChekinanaL10n.format(
                    "assistant.photo.reading",
                    fallback: "Reading photo %1$lld/%2$lld…",
                    Int64(index + 1),
                    Int64(boundedItems.count)
                )
                do {
                    let image = try await loadPendingChekiImage(from: item)
                    prepared.append(await ChekinanaCommandExecutor.prepareAlbumAddCheki(
                        request,
                        image: image
                    ))
                } catch ChekinanaAsyncDeadlineError.cancelled {
                    return
                } catch {
                    failedCount += 1
                }
            }
            guard !prepared.isEmpty else {
                guard albumPickerState.failProcessing(sessionID: sessionID) else { return }
                albumAddChekiRequest = nil
                albumAddChekiItems = []
                handleCommandResponse(.text(ChekinanaL10n.text(
                    "assistant.photo.batch_failed",
                    fallback: "error: The selected photos could not be loaded. No Cheki was prepared."
                )))
                isSubmitting = false
                return
            }

            do {
                let executor = ChekinanaCommandExecutor(
                    modelContext: modelContext,
                    confirmationLedger: confirmationLedger
                )
                // `finalize` checks the session and executes the synchronous
                // ledger transaction without any await between those steps.
                guard let output = try albumPickerState.finalize(sessionID: sessionID, operation: {
                    try executor.finalizeAlbumAddChekis(prepared, failedCount: failedCount)
                }) else { return }
                albumAddChekiRequest = nil
                albumAddChekiItems = []
                handleCommandResponse(output)
                isSubmitting = false
            } catch {
                albumAddChekiRequest = nil
                albumAddChekiItems = []
                handleCommandResponse(.text(ChekinanaL10n.format(
                    "assistant.photo.prepare_failed",
                    fallback: "error: A selected photo could not be prepared. No Cheki was prepared. %@",
                    error.localizedDescription
                )))
                isSubmitting = false
            }
        }
        albumProcessingTask = task
    }

    private func loadPendingChekiImages(for command: String) async throws -> [ChekinanaPendingChekiImage] {
        guard commandName(from: command) == "scancheki" else {
            return []
        }

#if DEBUG
        if ProcessInfo.processInfo.environment["CHEKINANA_MEDIA_UI_STUB"] == "fixture" {
            return ChekinanaMediaUITestFixture.pendingChekiImages()
        }
#endif
        var pendingImages: [ChekinanaPendingChekiImage] = []

        for (index, item) in selectedItems.enumerated() {
            guard !Task.isCancelled else { throw ChekinanaAsyncDeadlineError.cancelled }
            mediaLoadProgress = ChekinanaL10n.format(
                "assistant.photo.reading",
                fallback: "Reading photo %1$lld/%2$lld…",
                Int64(index + 1),
                Int64(selectedItems.count)
            )
            pendingImages.append(try await loadPendingChekiImage(from: item))
        }

        return pendingImages
    }

    private func loadPendingChekiImage(from item: PhotosPickerItem) async throws -> ChekinanaPendingChekiImage {
        try await ChekinanaAsyncDeadline.run(nanoseconds: 5_000_000_000) {
            try await loadPendingChekiImageWithoutDeadline(from: item)
        }
    }

    private func loadPendingChekiImageWithoutDeadline(from item: PhotosPickerItem) async throws -> ChekinanaPendingChekiImage {
#if DEBUG
        if ProcessInfo.processInfo.environment["CHEKINANA_MEDIA_UI_STUB"] == "hang" {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
#endif
        if let imageData = try? await item.loadTransferable(type: ChekinanaTransferableImageData.self),
           !imageData.data.isEmpty {
            return ChekinanaPendingChekiImage(
                data: imageData.data,
                filenameExtension: filenameExtension(for: item)
            )
        }

        if let data = try? await item.loadTransferable(type: Data.self),
           !data.isEmpty {
            return ChekinanaPendingChekiImage(
                data: data,
                filenameExtension: filenameExtension(for: item)
            )
        }

        if let fallbackImage = try? await item.loadTransferable(type: ChekinanaTransferableFallbackImageData.self),
           let data = await ChekinanaImageWorker.reencodedJPEGData(from: fallbackImage.data),
           !data.isEmpty {
            return ChekinanaPendingChekiImage(data: data, filenameExtension: "jpg")
        }

        throw PendingChekiImageLoadError.unreadableImage
    }

    private func commandName(from command: String) -> String? {
        command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased()
    }

    private func redactedCommandEcho(for command: String) -> String {
        if ChekinanaNLPrivacyGuard.containsCredentialedHTTPURL(command) {
            return ChekinanaL10n.text(
                "assistant.redacted_url",
                fallback: "[URL containing credentials hidden]"
            )
        }
        if ChekinanaNLPrivacyGuard.containsPodScanCredential(command) {
            return ChekinanaL10n.text(
                "assistant.redacted_input",
                fallback: "[Input containing credentials hidden]"
            )
        }
        guard ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(command) else {
            return ChekinanaL10n.text(
                "assistant.redacted_input",
                fallback: "[Input containing credentials hidden]"
            )
        }
        return command
    }

    private func appendUserMessage(_ text: String) {
        transcriptMessages.append(
            TranscriptMessage(role: .user, content: .text(text))
        )
    }

    private func requestClose() {
        guard !isClosing else { return }
        isClosing = true
#if DEBUG
        let startedAt = DispatchTime.now().uptimeNanoseconds
#endif
        isPromptFocused = false
        // SwiftUI owns focus dismissal. Forcing UIKit to resign a stale
        // responder during cover dismissal generated invalid-session and
        // keyboard-snapshot work on the main thread.
        suspendAssistantSession()
        captureAssistantSession()
#if DEBUG
        ChekinanaAssistantTimingLog.completed(
            stage: "close-ready",
            messageCount: transcriptMessages.count,
            cardCount: session.candidateCardCount,
            startedAt: startedAt
        )
#endif
        onClose?()
    }

    private func suspendAssistantSession() {
        if let activeNLRequest,
           prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = activeNLRequest.input
        }
        if pendingNLRetry == nil { pendingNLRetry = activeNLRequest }
        invalidateRemoteRequest()
        activeNLRequest = nil
        commandExecutionTask?.cancel()
        commandExecutionTask = nil
        idolCandidateSelectionGate.invalidate()
        idolConfirmationGate.invalidate()
        idolCandidateSelectionTask?.cancel()
        idolCandidateSelectionTask = nil
        idolConfirmationTask?.cancel()
        idolConfirmationTask = nil
        idolConfirmationTimeoutTask?.cancel()
        idolConfirmationTimeoutTask = nil
        invalidateEventCandidateFlow()
        albumProcessingTask?.cancel()
        albumProcessingTask = nil
        isSubmitting = false
    }

    private func captureAssistantSession() {
        session.capture(
            prompt: prompt,
            transcriptMessages: transcriptMessages,
            activeIdolCandidateTokens: activeIdolCandidateTokens,
            confirmedIdolCandidateTokens: confirmedIdolCandidateTokens,
            confirmationLedger: confirmationLedger,
            conversationState: conversationState,
            selectedChekiID: selectedChekiID,
            pendingNLRetry: pendingNLRetry
        )
    }

#if DEBUG
    private func installLongCandidateUITestFixture() {
        for index in 1...10 {
            transcriptMessages.append(TranscriptMessage(
                content: .text("History message \(index)")
            ))
        }
        let avatarData = ChekinanaMediaUITestFixture.pendingChekiImages()[0].data
        let prepared = (1...10).map { index in
            let sourceID = String(format: "fixture_%02d", index)
            let avatarURL = "https://fixtures.chekinana.invalid/avatar-\(index).jpg"
            return ChekinanaPreparedIdolCandidate(
                candidate: ChekinanaEnrichedIdol(
                    sourceId: sourceID,
                    idolName: "Candidate \(index)",
                    groupName: "Fixture Group",
                    color: nil,
                    birthday: nil,
                    verification: "Fixture verified",
                    bio: nil,
                    avatarUrl: avatarURL
                ),
                avatarThumbnailData: avatarData,
                avatarIdentity: ChekinanaIdolAvatarIdentity.make(
                    sourceID: sourceID,
                    avatarURL: avatarURL
                )
            )
        }
        let generation = confirmationLedger.beginIdolQuery()
        guard let choices = confirmationLedger.replaceIdolCandidates(
            prepared,
            generation: generation
        ) else { return }
        let cards = choices.map { choice in
            ChekinanaIdolCard(
                id: UUID(),
                catalogueID: choice.candidate.candidate.sourceId,
                name: choice.candidate.candidate.idolName,
                group: choice.candidate.candidate.groupName,
                color: nil,
                birthday: nil,
                verification: choice.candidate.candidate.verification,
                bio: nil,
                avatarImageRef: nil,
                avatarThumbnailData: nil,
                avatarIdentity: nil,
                detail: .addCandidate,
                confirmationCode: nil,
                selectionToken: choice.token
            )
        }
        activeIdolCandidateTokens = Set(choices.map(\.token))
        transcriptMessages.append(TranscriptMessage(content: .idolCards(cards)))
    }
#endif

    private func filenameExtension(for item: PhotosPickerItem) -> String {
        item.supportedContentTypes
            .first { $0.conforms(to: .image) }?
            .preferredFilenameExtension ?? "jpg"
    }
}

enum ChekinanaTranscriptRole: String, Codable, Equatable {
    case user
    case assistant
}

struct TranscriptMessage: Identifiable {
    let id: UUID
    let role: ChekinanaTranscriptRole
    let content: TranscriptContent

    init(
        id: UUID = UUID(),
        role: ChekinanaTranscriptRole = .assistant,
        content: TranscriptContent
    ) {
        self.id = id
        self.role = role
        self.content = content
    }
}

enum TranscriptContent {
    case text(String)
    case idolCard(ChekinanaIdolCard)
    case idolCards([ChekinanaIdolCard])
    case idolCardsWithNotice([ChekinanaIdolCard], String)
    case idolSections([ChekinanaIdolSection])
    case eventCard(ChekinanaEventCard)
    case eventCards([ChekinanaEventCard])
    case chekiScannedCards(count: Int, warningCount: Int, chekis: [ChekinanaChekiCard])
    case pendingChekiCards(summary: String, chekis: [ChekinanaChekiCard])
    case chekiCards([ChekinanaChekiCard])
    case confirmationActions([String])
    case scanAllShortcut

    static func commandResponse(_ response: ChekinanaCommandResponse) -> TranscriptContent {
        switch response {
        case .text(let text):
            return .text(text)
        case .confirmationText:
            return .text(ChekinanaL10n.text(
                "assistant.confirmation.ready",
                fallback: "This change is ready. Use the buttons below to confirm or cancel."
            ))
        case .chekiAdded(let count):
            return .text(ChekinanaL10n.quantity(
                "assistant.cheki.added_count",
                count: count,
                one: "Added %lld Cheki.",
                other: "Added %lld Cheki."
            ))
        case .chekiScanned(let count, let warningCount):
            if warningCount > 0 {
                return .text(ChekinanaL10n.format(
                    "assistant.cheki.scanned_with_warnings",
                    fallback: "Scanned %1$lld Cheki. Warnings: %2$lld.",
                    Int64(count),
                    Int64(warningCount)
                ))
            }

            return .text(ChekinanaL10n.quantity(
                "assistant.cheki.scanned_count",
                count: count,
                one: "Scanned %lld Cheki.",
                other: "Scanned %lld Cheki."
            ))
        case .chekiScannedCards(let count, let warningCount, let chekis):
            return .chekiScannedCards(count: count, warningCount: warningCount, chekis: chekis)
        case .pendingChekiCards(let summary, let chekis, _):
            return .pendingChekiCards(summary: summary, chekis: chekis)
        case .chekiCards(let chekis):
            return .chekiCards(chekis)
        case .idolCard(let idol):
            return .idolCard(idol)
        case .idolCards(let idols):
            return .idolCards(idols)
        case .idolCardsWithNotice(let idols, let notice):
            return .idolCardsWithNotice(idols, notice)
        case .idolSections(let sections):
            return .idolSections(sections)
        case .eventCard(let event):
            return .eventCard(event)
        case .eventCards(let events):
            return .eventCards(events)
        case .requestAddChekiPhoto:
            return .text(ChekinanaL10n.text(
                "assistant.choose_photo_request",
                fallback: "Choose one or more photos. The Cheki will be previewed before saving."
            ))
        case .shellAction(_, let message):
            return .text(message)
        case .clearTranscript:
            return .text("")
        }
    }
}

enum ChekinanaTranscriptAppendKind: Equatable {
    case userText
    case assistantText
    case idolCandidates(count: Int)
    case otherRichContent
}

enum ChekinanaTranscriptScrollBehavior: Equatable {
    case none
    case bottom
    case responseTop
}

struct ChekinanaTranscriptScrollPolicy {
    static func behavior(
        for kind: ChekinanaTranscriptAppendKind,
        isRestoringHistory: Bool
    ) -> ChekinanaTranscriptScrollBehavior {
        guard !isRestoringHistory else { return .none }
        switch kind {
        case .idolCandidates(let count) where count >= 6:
            return .responseTop
        case .userText, .assistantText, .idolCandidates, .otherRichContent:
            return .bottom
        }
    }

    fileprivate static func request(
        for message: TranscriptMessage,
        isRestoringHistory: Bool
    ) -> ChekinanaTranscriptScrollRequest {
        let kind: ChekinanaTranscriptAppendKind
        switch message.content {
        case .text:
            kind = message.role == .user ? .userText : .assistantText
        case .idolCards(let cards), .idolCardsWithNotice(let cards, _):
            kind = .idolCandidates(count: cards.count)
        default:
            kind = .otherRichContent
        }
        switch behavior(for: kind, isRestoringHistory: isRestoringHistory) {
        case .none: return .none
        case .bottom: return .bottom(UUID())
        case .responseTop: return .messageTop(message.id, UUID())
        }
    }
}

fileprivate enum ChekinanaTranscriptScrollRequest: Equatable {
    case none
    case bottom(UUID)
    case messageTop(UUID, UUID)
}

struct ChekinanaPersistedTranscriptRecord: Codable, Equatable, Sendable {
    let role: ChekinanaTranscriptRole
    let text: String
}

private enum ChekinanaAssistantHistoryWriteQueue {
    private static let queue = DispatchQueue(
        label: "app.chekinana.ios.assistant-history",
        qos: .utility
    )

    static func save(
        _ records: [ChekinanaPersistedTranscriptRecord],
        to url: URL
    ) {
        queue.async {
            ChekinanaAssistantHistoryStore.save(records, to: url)
        }
    }
}

enum ChekinanaAssistantHistoryStore {
    static let maximumRecords = 200
    static let maximumTextCharacters = 4_000

    static func load(from url: URL) -> [ChekinanaPersistedTranscriptRecord] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        guard let records = try? JSONDecoder().decode(
            [ChekinanaPersistedTranscriptRecord].self,
            from: data
        ) else {
            // Unknown legacy bytes are not a safe history format.
            try? FileManager.default.removeItem(at: url)
            return []
        }
        let sanitized = boundedSanitizedRecords(records)
        if sanitized.isEmpty || sanitized != records {
            if !writeSanitizedRecords(sanitized, to: url) {
                // Do not leave the known-unsafe legacy bytes behind if the
                // atomic replacement cannot be completed.
                try? FileManager.default.removeItem(at: url)
            }
        }
        return sanitized
    }

    static func save(_ records: [ChekinanaPersistedTranscriptRecord], to url: URL) {
        writeSanitizedRecords(boundedSanitizedRecords(records), to: url)
    }

    @discardableResult
    private static func writeSanitizedRecords(
        _ records: [ChekinanaPersistedTranscriptRecord],
        to url: URL
    ) -> Bool {
        if records.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            // History is best-effort and must never make the Assistant unusable.
            return false
        }
    }

    static func persistableRecords(
        from messages: [TranscriptMessage]
    ) -> [ChekinanaPersistedTranscriptRecord] {
        messages.compactMap { message in
            guard let text = persistableText(for: message.content) else { return nil }
            return sanitizedRecord(
                ChekinanaPersistedTranscriptRecord(role: message.role, text: text)
            )
        }
    }

    private static func persistableText(for content: TranscriptContent) -> String? {
        switch content {
        case .text(let text):
            return text
        case .idolCard(let idol):
            return ChekinanaL10n.format("assistant.history.idol", fallback: "Idol: %@", idol.name)
        case .idolCards(let idols), .idolCardsWithNotice(let idols, _):
            let names = idols.map(\.name)
            return names.isEmpty ? nil : ChekinanaL10n.format(
                "assistant.history.idols",
                fallback: "Idols: %@",
                names.joined(separator: ChekinanaL10n.text("assistant.list_separator", fallback: ", "))
            )
        case .eventCard(let event):
            return ChekinanaL10n.format("assistant.history.event", fallback: "Event: %@", event.name)
        case .eventCards(let events):
            let names = events.map(\.name)
            return names.isEmpty ? nil : ChekinanaL10n.format(
                "assistant.history.events",
                fallback: "Events: %@",
                names.joined(separator: ChekinanaL10n.text("assistant.list_separator", fallback: ", "))
            )
        case .chekiScannedCards(let count, let warningCount, _):
            return warningCount == 0
                ? ChekinanaL10n.quantity(
                    "assistant.history.scan",
                    count: count,
                    one: "Scan complete: %lld Cheki",
                    other: "Scan complete: %lld Cheki"
                )
                : ChekinanaL10n.format(
                    "assistant.history.scan_warnings",
                    fallback: "Scan complete: %1$lld Cheki, %2$lld warnings",
                    Int64(count),
                    Int64(warningCount)
                )
        case .pendingChekiCards(let summary, _):
            return summary
        case .chekiCards(let cards):
            return ChekinanaL10n.quantity(
                "assistant.history.cheki",
                count: cards.count,
                one: "Cheki: %lld item",
                other: "Cheki: %lld items"
            )
        case .idolSections:
            return ChekinanaL10n.text(
                "assistant.history.idol_cheki",
                fallback: "Idol and Cheki results were returned."
            )
        case .confirmationActions, .scanAllShortcut:
            return nil
        }
    }

    private static func boundedSanitizedRecords(
        _ records: [ChekinanaPersistedTranscriptRecord]
    ) -> [ChekinanaPersistedTranscriptRecord] {
        Array(records.compactMap(sanitizedRecord).suffix(maximumRecords))
    }

    private static func sanitizedRecord(
        _ record: ChekinanaPersistedTranscriptRecord
    ) -> ChekinanaPersistedTranscriptRecord? {
        // Persisted history is a separate trust boundary from the in-process
        // transcript. Apply the same fail-closed privacy guard to both user and
        // assistant text so an echoed credential or confirmation code cannot
        // bypass the user-input checks. Sensitive records are omitted rather
        // than partially redacted because retaining an unrecognised fragment is
        // riskier than losing one best-effort history entry.
        guard ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(record.text),
              !containsExplicitHistorySecret(record.text) else {
            return nil
        }
        return ChekinanaPersistedTranscriptRecord(
            role: record.role,
            text: String(record.text.prefix(maximumTextCharacters))
        )
    }

    private static func containsExplicitHistorySecret(_ text: String) -> Bool {
        text.range(
            of: #"(?i)\b(?:password|passwd|passcode|api[_-]?key|client[_-]?secret|secret|session(?:[_-]?(?:id|key|token))?|private[\s_-]*key)\s*[:：=]\s*\S+"#,
            options: .regularExpression
        ) != nil
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Chekinana", isDirectory: true)
            .appendingPathComponent("assistant-history-v1.json", isDirectory: false)
    }
}

@MainActor
final class ChekinanaAssistantSession {
    fileprivate var prompt: String
    fileprivate var transcriptMessages: [TranscriptMessage]
    fileprivate var activeIdolCandidateTokens: Set<String>
    fileprivate var confirmedIdolCandidateTokens: Set<String>
    fileprivate var confirmationLedger: ChekinanaConfirmationLedger
    fileprivate var conversationState: ChekinanaConversationState
    fileprivate var selectedChekiID: UUID?
    fileprivate var pendingNLRetry: PendingNaturalLanguageRequest?
    private let historyURL: URL

    init(historyURL: URL = ChekinanaAssistantHistoryStore.defaultURL()) {
        self.historyURL = historyURL
        if ProcessInfo.processInfo.environment["CHEKINANA_UI_RESET_STORE"] == "1" {
            try? FileManager.default.removeItem(at: historyURL)
        }
        prompt = ""
        activeIdolCandidateTokens = []
        confirmedIdolCandidateTokens = []
        confirmationLedger = ChekinanaConfirmationLedger()
        conversationState = ChekinanaConversationState()
        selectedChekiID = nil
        pendingNLRetry = nil
        transcriptMessages = ChekinanaAssistantHistoryStore.load(from: historyURL).map {
            TranscriptMessage(role: $0.role, content: .text($0.text))
        }
    }

    var messageCount: Int { transcriptMessages.count }

    var candidateCardCount: Int {
        transcriptMessages.reduce(into: 0) { count, message in
            switch message.content {
            case .idolCards(let cards), .idolCardsWithNotice(let cards, _):
                count += cards.count
            default:
                break
            }
        }
    }

    fileprivate func capture(
        prompt: String,
        transcriptMessages: [TranscriptMessage],
        activeIdolCandidateTokens: Set<String>,
        confirmedIdolCandidateTokens: Set<String>,
        confirmationLedger: ChekinanaConfirmationLedger,
        conversationState: ChekinanaConversationState,
        selectedChekiID: UUID?,
        pendingNLRetry: PendingNaturalLanguageRequest?
    ) {
        self.prompt = prompt
        self.transcriptMessages = transcriptMessages
        self.activeIdolCandidateTokens = activeIdolCandidateTokens
        self.confirmedIdolCandidateTokens = confirmedIdolCandidateTokens
        self.confirmationLedger = confirmationLedger
        self.conversationState = conversationState
        self.selectedChekiID = selectedChekiID
        self.pendingNLRetry = pendingNLRetry
        persistTextHistory(from: transcriptMessages)
    }

    fileprivate func persistTextHistory(from messages: [TranscriptMessage]) {
        let records = ChekinanaAssistantHistoryStore.persistableRecords(from: messages)
        // Keep message publication, keyboard transitions, and dismissal off
        // the atomic filesystem write path while preserving write order.
        ChekinanaAssistantHistoryWriteQueue.save(records, to: historyURL)
    }
}

private struct EventCandidateEditorView: View {
    @Binding var fields: ChekinanaEventCandidateFields
    let blockers: [ChekinanaEventCandidateBlocker]
    let isDisabled: Bool
    let onPrepare: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ChekinanaL10n.text("assistant.event_candidate", fallback: "Event candidate · Not saved"))
                .font(.headline)

            candidateField(
                ChekinanaL10n.text("assistant.event.field.name_required", fallback: "Name *"),
                text: $fields.name,
                identifier: "name"
            )
            candidateField(
                ChekinanaL10n.text("assistant.event.field.date", fallback: "Date"),
                text: $fields.date,
                identifier: "date",
                prompt: ChekinanaL10n.text("assistant.event.date_optional", fallback: "YYYY-MM-DD or empty")
            )
            if fields.date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(ChekinanaL10n.text("assistant.event_no_date", fallback: "No date was found; the Event will be saved without a date."))
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("chekinana.event.candidate.date-undetermined")
            }
            candidateField(
                "OPEN",
                text: optionalFieldBinding(\.openTime),
                identifier: "open-time",
                prompt: "HH:mm"
            )
            candidateField(
                "START",
                text: optionalFieldBinding(\.startTime),
                identifier: "start-time",
                prompt: "HH:mm"
            )
            candidateField(ChekinanaL10n.text("assistant.event.field.city", fallback: "City"), text: $fields.city, identifier: "city")
            candidateField(ChekinanaL10n.text("assistant.event.field.livehouse", fallback: "Livehouse"), text: $fields.livehouse, identifier: "livehouse")
            candidateField(ChekinanaL10n.text("assistant.event.field.price", fallback: "Price"), text: $fields.price, identifier: "price")
            candidateField(
                ChekinanaL10n.text(
                    "assistant.event.field.weibo_required",
                    fallback: "Weibo URL *"
                ),
                text: $fields.weiboURL,
                identifier: "weibo-url",
                offersDirectPaste: true
            )
            candidateField(ChekinanaL10n.text("assistant.event.field.ticket", fallback: "Ticket URL"), text: $fields.ticketURL, identifier: "ticket-url")

            if !blockers.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(blockers) { blocker in
                        Text("• \(blocker.message)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("chekinana.event.candidate.blocker.\(blocker.id)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chekinana.event.candidate.blockers")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { eventCandidateButtons }
                VStack(alignment: .leading, spacing: 8) { eventCandidateButtons }
            }
        }
        .eventCandidatePanelStyle()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(ChekinanaL10n.text("action.done", fallback: "Done")) {
                    isFieldFocused = false
                }
            }
        }
    }

    @ViewBuilder
    private var eventCandidateButtons: some View {
                Button(ChekinanaL10n.text("assistant.prepare_confirmation", fallback: "Prepare confirmation")) {
                    onPrepare()
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(isDisabled || !blockers.isEmpty)
                .accessibilityIdentifier("chekinana.event.candidate.prepare")
                .accessibilityHint(
                    isDisabled
                        ? ChekinanaL10n.text("assistant.event.prepare_wait", fallback: "Wait for the current operation to finish")
                        : blockers.isEmpty
                            ? ChekinanaL10n.text("assistant.event.prepare_hint", fallback: "Freeze these fields and create a confirmation card")
                            : ChekinanaL10n.text("assistant.event.prepare_blocked", fallback: "Correct the listed issues first")
                )

                Button(ChekinanaL10n.text("action.cancel", fallback: "Cancel")) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(isDisabled)
                .accessibilityIdentifier("chekinana.event.candidate.cancel")
                .accessibilityHint(ChekinanaL10n.text("assistant.event_cancel_hint", fallback: "Close the candidate without creating an Event"))
    }

    private func candidateField(
        _ label: String,
        text: Binding<String>,
        identifier: String,
        prompt: String = ChekinanaL10n.text("assistant.optional", fallback: "Optional"),
        offersDirectPaste: Bool = false
    ) -> some View {
        let pasteTitle = ChekinanaL10n.text(
            "product.events.paste_weibo",
            fallback: "Paste Weibo URL"
        )
        let visiblePrompt = offersDirectPaste ? pasteTitle : prompt
        return VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.footnote.weight(.medium))
            TextField(
                "",
                text: text,
                prompt: Text(visiblePrompt).foregroundStyle(
                    offersDirectPaste ? Color.blue : Color.secondary
                ),
                axis: .vertical
            )
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(isDisabled)
            .focused($isFieldFocused)
            .accessibilityHidden(offersDirectPaste && text.wrappedValue.isEmpty)
            .accessibilityIdentifier("chekinana.event.candidate.\(identifier)")
            .overlay(alignment: .leading) {
                if offersDirectPaste, text.wrappedValue.isEmpty {
                    ChekinanaDirectStringPasteControl(
                        title: pasteTitle,
                        accessibilityIdentifier: "chekinana.event.candidate.\(identifier).paste"
                    ) { pasted in
                        text.wrappedValue = pasted
                        isFieldFocused = true
                    }
                    .disabled(isDisabled)
                }
            }
        }
    }

    private func optionalFieldBinding(
        _ keyPath: WritableKeyPath<ChekinanaEventCandidateFields, String?>
    ) -> Binding<String> {
        Binding(
            get: { fields[keyPath: keyPath] ?? "" },
            set: { value in
                fields[keyPath: keyPath] = value.isEmpty ? nil : value
            }
        )
    }
}

private struct EventCardView: View {
    let event: ChekinanaEventCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(event.confirmationCode == nil
                ? ChekinanaL10n.text("assistant.event.title", fallback: "Event")
                : ChekinanaL10n.text("assistant.event.pending", fallback: "Pending Event"))
                .font(.footnote.weight(.semibold).monospaced())
                .foregroundStyle(event.confirmationCode == nil ? Color(.secondaryLabel) : .orange)
            value(ChekinanaL10n.text("assistant.event.field.name", fallback: "Name"), event.name)
            value(
                ChekinanaL10n.text("assistant.event.field.date", fallback: "Date"),
                event.date.isEmpty
                    ? ChekinanaL10n.text("assistant.event.date_undetermined", fallback: "Undetermined")
                    : ChekinanaDisplayFormat.date(event.date)
            )
            value(ChekinanaL10n.text("assistant.event.field.city", fallback: "City"), emptyFallback(event.city))
            value(ChekinanaL10n.text("assistant.event.field.livehouse", fallback: "Livehouse"), emptyFallback(event.livehouse))
            value(ChekinanaL10n.text("assistant.event.field.price", fallback: "Price"), emptyFallback(event.price))
            if let schedule = ChekinanaEventTime.summary(
                openTime: event.openTime,
                startTime: event.startTime
            ) {
                Text(schedule)
                    .font(.subheadline.monospacedDigit())
            }
            value(ChekinanaL10n.text("assistant.event.field.weibo", fallback: "Weibo"), emptyFallback(event.weiboURL))
            value(ChekinanaL10n.text("assistant.event.field.ticket_short", fallback: "Tickets"), emptyFallback(event.ticketURL))
            value(ChekinanaL10n.text("assistant.note", fallback: "Note"), emptyFallback(event.note))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .accessibilityIdentifier("chekinana.event.card.\(event.id.uuidString.lowercased())")
    }

    private func value(_ label: String, _ value: String) -> some View {
        Text(ChekinanaL10n.format("assistant.field_value", fallback: "%1$@: %2$@", label, value))
            .font(.subheadline)
            .foregroundStyle(.black)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func emptyFallback(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ChekinanaL10n.text("assistant.not_set", fallback: "Not set")
            : value
    }
}

private extension View {
    func eventCandidatePanelStyle() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
            )
    }
}

private struct ConfirmationActionView: View {
    let codes: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(codes, id: \.self) { code in
                HStack(spacing: 8) {
                    Button(ChekinanaL10n.text("assistant.confirm", fallback: "Confirm")) {
                        action("confirm \(code)")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("chekinana.confirm.\(code)")

                    Button(ChekinanaL10n.text("action.cancel", fallback: "Cancel")) {
                        action("cancel \(code)")
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("chekinana.cancel.\(code)")
                }
            }
        }
    }
}

private struct FlowChoiceView: View {
    let options: [ChekinanaLocalChoice]
    let selectedIDs: Set<UUID>
    let action: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    Button {
                        action(option.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            if let subtitle = option.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Color(.secondaryLabel))
                                    .lineLimit(2)
                            }
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(selectedIDs.contains(option.id) ? Color(.systemGray4) : Color(.systemGray6))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(selectedIDs.contains(option.id) ? .isSelected : [])
                    .accessibilityIdentifier("chekinana.choice.\(option.id.uuidString.lowercased())")
                }
            }
        }
    }
}

private struct ChekiListTranscriptView: View {
    let chekis: [ChekinanaChekiCard]
    let selectedChekiID: UUID?
    let onSelectCheki: (ChekinanaChekiCard) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(chekis) { cheki in
                    ChekiCardView(
                        cheki: cheki,
                        isSelected: cheki.id == selectedChekiID,
                        onSelect: { onSelectCheki(cheki) }
                    )
                }
            }
            .padding(.vertical, 1)
        }
    }
}

private struct ScannedChekiTranscriptView: View {
    let count: Int
    let warningCount: Int
    let chekis: [ChekinanaChekiCard]
    let onEdit: (ChekinanaChekiCard) -> Void
    let onDelete: (ChekinanaChekiCard) -> Void
    let onDownload: (ChekinanaChekiCard) -> Void

    private var summaryText: String {
        var lines = [
            ChekinanaL10n.quantity(
                "assistant.scan.recognized",
                count: count,
                one: "Recognized %lld Cheki.",
                other: "Recognized %lld Cheki."
            ),
            ChekinanaL10n.text(
                "assistant.scan.edit_help",
                fallback: "Edit each result's Idol, date, Event, and other details, or delete it and save its clean image."
            ),
            ChekinanaL10n.text(
                "assistant.scan.unsaved",
                fallback: "These results are not saved yet. Each needs a date before confirmation."
            ),
        ]
        if warningCount > 0 {
            lines.append(ChekinanaL10n.quantity(
                "assistant.scan.warnings",
                count: warningCount,
                one: "The scan produced %lld warning, such as a count mismatch or an earlier unused result being released.",
                other: "The scan produced %lld warnings, such as a count mismatch or an earlier unused result being released."
            ))
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summaryText)
                .font(.subheadline)
                .foregroundStyle(.black)
                .textSelection(.enabled)

            if !chekis.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(chekis) { cheki in
                            VStack(spacing: 6) {
                                ChekiCardView(cheki: cheki)
                                Button(ChekinanaL10n.text("assistant.edit", fallback: "Edit")) { onEdit(cheki) }
                                    .buttonStyle(.bordered)
                                    .chekinanaMinimumTouchTarget()
                                    .accessibilityIdentifier(
                                        "chekinana.temporary.edit.\(cheki.id.uuidString.lowercased())"
                                    )
                                Button(ChekinanaL10n.text("assistant.save_original", fallback: "Save original")) { onDownload(cheki) }
                                    .buttonStyle(.bordered)
                                    .chekinanaMinimumTouchTarget()
                                    .accessibilityHint(ChekinanaL10n.text(
                                        "assistant.save_original_hint",
                                        fallback: "Save the clean image without the date bounding box"
                                    ))
                                    .accessibilityIdentifier(
                                        "chekinana.temporary.download.\(cheki.id.uuidString.lowercased())"
                                    )
                                Button(ChekinanaL10n.text("assistant.delete", fallback: "Delete"), role: .destructive) { onDelete(cheki) }
                                    .buttonStyle(.bordered)
                                    .chekinanaMinimumTouchTarget()
                                    .accessibilityIdentifier(
                                        "chekinana.temporary.delete.\(cheki.id.uuidString.lowercased())"
                                    )
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }
}

private struct PendingChekiTranscriptView: View {
    let summary: String
    let chekis: [ChekinanaChekiCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(summary)\n\(ChekinanaL10n.text("assistant.confirm_below", fallback: "Use the buttons below to confirm or cancel."))")
                .font(.subheadline)
                .foregroundStyle(.black)
                .textSelection(.enabled)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(chekis) { cheki in
                        ChekiCardView(cheki: cheki)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}

private struct TemporaryChekiEditorView: View {
    @Binding var draft: TemporaryChekiEditorDraft
    let idols: [Idol]
    let events: [Event]
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var isIndexFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section(ChekinanaL10n.text("assistant.temporary.idols", fallback: "Idols (optional, multiple allowed)")) {
                    if idols.isEmpty {
                        Text(ChekinanaL10n.text("assistant.no_local_idol", fallback: "No local Idols"))
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    ForEach(idols.sorted(by: { $0.name < $1.name })) { idol in
                        Toggle(
                            idol.name,
                            isOn: Binding(
                                get: { draft.idolIDs.contains(idol.id) },
                                set: { selected in
                                    if selected {
                                        draft.idolIDs.insert(idol.id)
                                    } else {
                                        draft.idolIDs.remove(idol.id)
                                    }
                                }
                            )
                        )
                    }
                }

                Section(ChekinanaL10n.text("assistant.temporary.date_section", fallback: "Date (required before confirmation)")) {
                    Toggle(ChekinanaL10n.text("assistant.temporary.set_date", fallback: "Set date"), isOn: $draft.hasDate)
                    if draft.hasDate {
                        DatePicker(
                            ChekinanaL10n.text("assistant.date", fallback: "Date"),
                            selection: $draft.date,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.compact)
                    }
                }

                Section(ChekinanaL10n.text("assistant.temporary.event", fallback: "Event (optional; does not affect index)")) {
                    Picker(ChekinanaL10n.text("assistant.event.title", fallback: "Event"), selection: $draft.eventID) {
                        Text(ChekinanaL10n.text("assistant.none", fallback: "None")).tag(UUID?.none)
                        ForEach(selectableEvents.sorted(by: { $0.name < $1.name })) { event in
                            Text(event.name).tag(Optional(event.id))
                        }
                    }
                }

                Section(ChekinanaL10n.text("assistant.temporary.other", fallback: "Other details")) {
                    TextField(ChekinanaL10n.text("assistant.index_optional", fallback: "Index (optional)"), text: $draft.idxText)
                        .keyboardType(.numberPad)
                        .focused($isIndexFocused)
                    Picker(ChekinanaL10n.text("assistant.temporary.size", fallback: "Size"), selection: $draft.size) {
                        Text(ChekinanaL10n.text("assistant.not_set", fallback: "Not set")).tag(ChekiSize?.none)
                        ForEach(ChekiSize.allCases) { size in
                            Text(size == .mini
                                ? ChekinanaL10n.text("assistant.size.mini", fallback: "Mini")
                                : ChekinanaL10n.text("assistant.size.wide", fallback: "Wide"))
                                .tag(Optional(size))
                        }
                    }
                    Toggle(ChekinanaL10n.text("assistant.temporary.favorite", fallback: "Favorite"), isOn: $draft.isFavorite)
                    Toggle(ChekinanaL10n.text("assistant.temporary.posted", fallback: "Posted to SNS"), isOn: $draft.hasPostedToSNS)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ChekinanaL10n.text("assistant.note", fallback: "Note"))
                        TextEditor(text: $draft.note)
                            .frame(minHeight: 90)
                    }
                }
            }
            .onChange(of: draft.hasDate) { _, _ in
                clearInvalidEventSelection()
            }
            .onChange(of: draft.date) { _, _ in
                clearInvalidEventSelection()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(ChekinanaL10n.text("assistant.temporary.edit_title", fallback: "Edit Temporary Cheki"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaL10n.text("action.cancel", fallback: "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChekinanaL10n.text("assistant.save", fallback: "Save"), action: onSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(ChekinanaL10n.text("action.done", fallback: "Done")) {
                        isIndexFocused = false
                    }
                }
            }
        }
    }

    private var draftCanonicalDate: Date? {
        guard draft.hasDate else { return nil }
        return ChekinanaDateOnly.canonicalDate(
            from: draft.date,
            displayedIn: .current
        )
    }

    private var selectableEvents: [Event] {
        ChekinanaChekiEventSelectionPolicy.eligibleEvents(
            events,
            for: draftCanonicalDate
        )
    }

    private func clearInvalidEventSelection() {
        draft.eventID = ChekinanaChekiEventSelectionPolicy.validatedEventID(
            draft.eventID,
            recordDate: draftCanonicalDate,
            events: events
        )
    }
}

private enum ChekinanaCardMetrics {
    static let cardHeight: CGFloat = 104
}

private enum ChekinanaCardBatching {
    static let initialCount = 50
    static let increment = 50
}

private struct IdolCardCollectionView: View {
    let idols: [ChekinanaIdolCard]
    let activeSelectionTokens: Set<String>
    let confirmedSelectionTokens: Set<String>
    let isInteractionEnabled: Bool
    let onSelectCandidate: (String) -> Void
    let onCancelCandidates: () -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(idols) { idol in
                IdolCardView(
                    idol: idol,
                    onSelectCandidate: selectionAction(for: idol),
                    isCandidateConfirmed: idol.selectionToken.map(confirmedSelectionTokens.contains) ?? false,
                    isCandidateInteractionEnabled: isInteractionEnabled
                )
            }
            if idols.contains(where: { idol in
                idol.selectionToken.map(activeSelectionTokens.contains) ?? false
            }) {
                Button(ChekinanaL10n.text("assistant.cancel_candidates", fallback: "Cancel these candidates")) {
                    onCancelCandidates()
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(!isInteractionEnabled)
                .accessibilityIdentifier("chekinana.idol.candidates.cancel")
            }
        }
    }

    private func selectionAction(for idol: ChekinanaIdolCard) -> (() -> Void)? {
        guard let token = idol.selectionToken,
              activeSelectionTokens.contains(token) else {
            return nil
        }
        return { onSelectCandidate(token) }
    }

}

private struct IdolSectionCollectionView: View {
    let sections: [ChekinanaIdolSection]
    let selectedChekiID: UUID?
    let onSelectCheki: (ChekinanaChekiCard) -> Void
    @State private var visibleCount = ChekinanaCardBatching.initialCount

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(sections.prefix(visibleCount)) { section in
                IdolSectionView(
                    section: section,
                    selectedChekiID: selectedChekiID,
                    onSelectCheki: onSelectCheki
                )
            }
            if visibleCount < sections.count {
                Button(ChekinanaL10n.format(
                    "assistant.load_more",
                    fallback: "Load %1$lld more · %2$lld remaining",
                    Int64(min(ChekinanaCardBatching.increment, sections.count - visibleCount)),
                    Int64(sections.count - visibleCount)
                )) {
                    visibleCount = min(sections.count, visibleCount + ChekinanaCardBatching.increment)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityHint(ChekinanaL10n.text("assistant.load_more_hint", fallback: "Show the next Idol cards"))
            }
        }
    }
}

private struct IdolSectionView: View {
    let section: ChekinanaIdolSection
    let selectedChekiID: UUID?
    let onSelectCheki: (ChekinanaChekiCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IdolCardView(idol: section.idol)

            if !section.chekis.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(section.chekis) { cheki in
                            ChekiCardView(
                                cheki: cheki,
                                isSelected: cheki.id == selectedChekiID,
                                onSelect: { onSelectCheki(cheki) }
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }
}

struct ChekinanaChekiPreviewSource: Equatable, Sendable {
    enum PreferredKind: Equatable, Sendable {
        case imageRef
        case embeddedThumbnail
        case unavailable
    }

    let chekiID: UUID
    let imageRef: String?
    let embeddedThumbnailData: Data?
    let preferredKind: PreferredKind
    let transientDateAnnotation: ChekinanaChekiDateAnnotation?

    init(cheki: ChekinanaChekiCard) {
        chekiID = cheki.id
        let trimmedRef = cheki.imageRef?.trimmingCharacters(in: .whitespacesAndNewlines)
        imageRef = trimmedRef?.isEmpty == false ? trimmedRef : nil
        if let data = cheki.thumbnailImageData, !data.isEmpty {
            embeddedThumbnailData = data
        } else {
            embeddedThumbnailData = nil
        }
        if imageRef != nil {
            preferredKind = .imageRef
        } else if embeddedThumbnailData != nil {
            preferredKind = .embeddedThumbnail
        } else {
            preferredKind = .unavailable
        }
        if imageRef == nil,
           cheki.idx == nil,
           case .detected(let annotation) = cheki.dateAnnotationState {
            transientDateAnnotation = annotation
        } else {
            transientDateAnnotation = nil
        }
    }

    var loadID: String {
        "\(chekiID.uuidString)|\(imageRef ?? "no-ref")|\(embeddedThumbnailData?.count ?? 0)"
    }
}

enum ChekinanaChekiPreviewLoadedSource: Equatable, Sendable {
    case imageRef
    case embeddedThumbnail
}

struct ChekinanaChekiPreviewLoadOutcome {
    let image: ChekinanaRenderedImage?
    let loadedSource: ChekinanaChekiPreviewLoadedSource?

    static let unavailable = ChekinanaChekiPreviewLoadOutcome(
        image: nil,
        loadedSource: nil
    )
}

@MainActor
struct ChekinanaChekiPreviewLoader {
    typealias ImageRefLoader = (String, Int) async -> ChekinanaRenderedImage?
    typealias EmbeddedLoader = (Data, Int) async -> ChekinanaRenderedImage?

    private let imageRefLoader: ImageRefLoader
    private let embeddedLoader: EmbeddedLoader

    init(
        imageRefLoader: @escaping ImageRefLoader = { imageRef, maxDimension in
            await ChekinanaImageWorker.previewImage(
                fromImageRef: imageRef,
                maxDimension: maxDimension
            )
        },
        embeddedLoader: @escaping EmbeddedLoader = { data, maxDimension in
            await ChekinanaImageWorker.previewImage(
                from: data,
                maxDimension: maxDimension
            )
        }
    ) {
        self.imageRefLoader = imageRefLoader
        self.embeddedLoader = embeddedLoader
    }

    func load(
        source: ChekinanaChekiPreviewSource,
        maxDimension: Int = 2_048
    ) async -> ChekinanaChekiPreviewLoadOutcome {
        guard !Task.isCancelled else { return .unavailable }
        if let imageRef = source.imageRef,
           let image = await imageRefLoader(imageRef, maxDimension) {
            guard !Task.isCancelled else { return .unavailable }
            return ChekinanaChekiPreviewLoadOutcome(
                image: image,
                loadedSource: .imageRef
            )
        }
        guard !Task.isCancelled else { return .unavailable }
        if let data = source.embeddedThumbnailData,
           let image = await embeddedLoader(data, maxDimension) {
            guard !Task.isCancelled else { return .unavailable }
            return ChekinanaChekiPreviewLoadOutcome(
                image: image,
                loadedSource: .embeddedThumbnail
            )
        }
        return .unavailable
    }
}

enum ChekinanaChekiPreviewLoadState: Equatable, Sendable {
    case loading
    case loaded(ChekinanaChekiPreviewLoadedSource)
    case unavailable
}

struct ChekinanaChekiPreviewPresentationState: Equatable, Sendable {
    private(set) var isPresented = false

    mutating func open() {
        isPresented = true
    }

    mutating func close() {
        isPresented = false
    }
}

enum ChekinanaChekiDateOverlayGeometry {
    static func fittedImageRect(
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect? {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              containerSize.width.isFinite,
              containerSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return nil
        }
        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let fittedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    static func annotationRect(
        boundingBox: ChekinanaChekiDateBoundingBox,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect? {
        guard let imageRect = fittedImageRect(
            imageSize: imageSize,
            containerSize: containerSize
        ) else {
            return nil
        }
        let x1 = imageRect.minX + imageRect.width * CGFloat(boundingBox.x1) / 1_000
        let y1 = imageRect.minY + imageRect.height * CGFloat(boundingBox.y1) / 1_000
        let x2 = imageRect.minX + imageRect.width * CGFloat(boundingBox.x2) / 1_000
        let y2 = imageRect.minY + imageRect.height * CGFloat(boundingBox.y2) / 1_000
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}

private struct ChekinanaChekiDateOverlay: View {
    let annotation: ChekinanaChekiDateAnnotation
    let imageSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            if let rect = ChekinanaChekiDateOverlayGeometry.annotationRect(
                boundingBox: annotation.boundingBox,
                imageSize: imageSize,
                containerSize: proxy.size
            ) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(Color.green, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)

                    Text(annotation.text)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .fixedSize()
                        .offset(
                            x: max(2, min(rect.minX, proxy.size.width - 64)),
                            y: max(2, rect.minY - 17)
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChekiCardView: View {
    let cheki: ChekinanaChekiCard
    let isSelected: Bool
    let onSelect: (() -> Void)?
    @State private var renderedThumbnail: ChekinanaRenderedImage?
    @State private var previewState = ChekinanaChekiPreviewPresentationState()

    init(
        cheki: ChekinanaChekiCard,
        isSelected: Bool = false,
        onSelect: (() -> Void)? = nil
    ) {
        self.cheki = cheki
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    private var title: String {
        if cheki.confirmationCode != nil {
            return ChekinanaL10n.text("assistant.cheki.pending", fallback: "Pending")
        }
        if let idx = cheki.idx {
            return ChekinanaL10n.format("assistant.cheki.index", fallback: "Cheki #%lld", Int64(idx))
        }
        return ChekinanaL10n.text("assistant.cheki.scan_result", fallback: "Scan result")
    }

    private var associationText: String? {
        let idols = cheki.idolNames.joined(separator: ChekinanaL10n.text("assistant.list_separator", fallback: ", "))
        let occasion = cheki.eventName ?? cheki.eventDateText
        let parts = [idols.isEmpty ? nil : idols, occasion].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var imageLoadID: String {
        "\(cheki.id.uuidString)|\(cheki.confirmationCode ?? "saved")|\(cheki.imageRef ?? "")|\(cheki.thumbnailImageData?.count ?? 0)"
    }

    private var previewSource: ChekinanaChekiPreviewSource {
        ChekinanaChekiPreviewSource(cheki: cheki)
    }

    private var dateAnnotationStatusText: String? {
        switch cheki.dateAnnotationState {
        case .notRequested:
            nil
        case .detected(let annotation):
            ChekinanaL10n.format(
                "assistant.cheki.detected_date",
                fallback: "Date: %@",
                ChekinanaDisplayFormat.date(annotation.text)
            )
        case .notDetected:
            ChekinanaL10n.text("assistant.cheki.date_not_detected", fallback: "No date detected")
        case .unavailable:
            ChekinanaL10n.text("assistant.cheki.date_unavailable", fallback: "Date recognition unavailable")
        }
    }

    private var dateAnnotationStatusColor: Color {
        if case .detected = cheki.dateAnnotationState {
            return .green
        }
        return Color(.secondaryLabel)
    }

    private var dateAnnotationAccessibilityValue: String {
        switch cheki.dateAnnotationState {
        case .notRequested:
            return ChekinanaL10n.text("assistant.cheki.date_not_requested", fallback: "Handwritten date recognition was not requested")
        case .detected(let annotation):
            return ChekinanaL10n.format(
                "assistant.cheki.date_detected_accessibility",
                fallback: "Detected handwritten date %@",
                ChekinanaDisplayFormat.date(annotation.text)
            )
        case .notDetected:
            return ChekinanaL10n.text("assistant.cheki.date_not_detected_accessibility", fallback: "No handwritten date was detected")
        case .unavailable:
            return ChekinanaL10n.text("assistant.cheki.date_unavailable_accessibility", fallback: "Handwritten date recognition was unavailable; the image can still be used")
        }
    }

    private var previewIsPresented: Binding<Bool> {
        Binding(
            get: { previewState.isPresented },
            set: { isPresented in
                if isPresented {
                    previewState.open()
                } else {
                    previewState.close()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                previewState.open()
            } label: {
                ZStack(alignment: .bottom) {
                    Color(.systemGray6)

                    if let renderedThumbnail {
                        Image(decorative: renderedThumbnail.cgImage, scale: 1, orientation: .up)
                            .resizable()
                            .scaledToFit()
                        if case .detected(let annotation) = cheki.dateAnnotationState {
                            ChekinanaChekiDateOverlay(
                                annotation: annotation,
                                imageSize: CGSize(
                                    width: renderedThumbnail.cgImage.width,
                                    height: renderedThumbnail.cgImage.height
                                )
                            )
                        }
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(Color(.systemGray3))
                    }

                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(cheki.confirmationCode == nil ? .black.opacity(0.58) : .orange.opacity(0.9))
                }
                .frame(width: 96, height: ChekinanaCardMetrics.cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(ChekinanaL10n.text("assistant.cheki.preview", fallback: "View full-size Cheki"))
            .accessibilityHint(ChekinanaL10n.text("assistant.cheki.preview_hint", fallback: "Open a full-screen preview without selecting or changing this Cheki"))
            .accessibilityValue(dateAnnotationAccessibilityValue)
            .accessibilityIdentifier("chekinana.cheki.preview.open.\(cheki.id.uuidString.lowercased())")

            if let associationText {
                Text(associationText)
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(3)
            }

            if let note = cheki.note, !note.isEmpty {
                Text(ChekinanaL10n.format("assistant.cheki.note", fallback: "Note: %@", note))
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(3)
            }

            if let dateAnnotationStatusText {
                Text(dateAnnotationStatusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(dateAnnotationStatusColor)
                    .lineLimit(2)
                    .accessibilityIdentifier(
                        "chekinana.cheki.date-annotation.\(cheki.id.uuidString.lowercased())"
                    )
            }

            if cheki.confirmationCode == nil, cheki.idx != nil, let onSelect {
                Button(isSelected
                    ? ChekinanaL10n.text("assistant.cheki.selected_button", fallback: "Selected")
                    : ChekinanaL10n.text("assistant.cheki.select_button", fallback: "Select this Cheki")) {
                    onSelect()
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? Color.accentColor : Color(.secondaryLabel))
                .frame(minWidth: 96, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("chekinana.cheki.select.\(cheki.id.uuidString.lowercased())")
            }
        }
        .padding(6)
        .frame(minWidth: 132, idealWidth: 160, maxWidth: 220, alignment: .topLeading)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color(.systemGray4).opacity(0.7), lineWidth: isSelected ? 2 : 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
        .task(id: imageLoadID) {
            renderedThumbnail = nil
            let thumbnail: ChekinanaRenderedImage?
            if let data = cheki.thumbnailImageData {
                thumbnail = await ChekinanaThumbnailCache.shared.thumbnailImage(
                    from: data,
                    key: imageLoadID,
                    maxDimension: 512
                )
            } else {
                thumbnail = await ChekinanaThumbnailCache.shared.thumbnailImage(
                    forImageRef: cheki.imageRef,
                    key: imageLoadID,
                    maxDimension: 512
                )
            }
            guard !Task.isCancelled else { return }
            renderedThumbnail = thumbnail
        }
        .fullScreenCover(isPresented: previewIsPresented, onDismiss: {
            previewState.close()
        }) {
            ChekinanaChekiImagePreview(source: previewSource)
        }
    }
}

private struct ChekinanaChekiImagePreview: View {
    @Environment(\.dismiss) private var dismiss
    let source: ChekinanaChekiPreviewSource
    @State private var renderedImage: ChekinanaRenderedImage?
    @State private var loadState: ChekinanaChekiPreviewLoadState = .loading

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(ChekinanaL10n.text("assistant.cheki.preview_title", fallback: "Cheki Preview"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("chekinana.cheki.preview.title")

                    Spacer(minLength: 8)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.14))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(ChekinanaL10n.text("assistant.cheki.preview_close", fallback: "Close full-size preview"))
                    .accessibilityHint(ChekinanaL10n.text("assistant.cheki.preview_close_hint", fallback: "Return to the Cheki card"))
                    .accessibilityIdentifier("chekinana.cheki.preview.close")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ZStack {
                    if let renderedImage,
                       case .loaded = loadState {
                        let imageSize = CGSize(
                            width: renderedImage.cgImage.width,
                            height: renderedImage.cgImage.height
                        )
                        ChekinanaZoomableImageViewport(
                            imageSize: imageSize,
                            resetID: source.loadID
                        ) {
                            ZStack {
                                Image(
                                    decorative: renderedImage.cgImage,
                                    scale: 1,
                                    orientation: .up
                                )
                                .resizable()
                                .scaledToFit()
                                .accessibilityHidden(true)

                                if let annotation = source.transientDateAnnotation {
                                    ChekinanaChekiDateOverlay(
                                        annotation: annotation,
                                        imageSize: imageSize
                                    )
                                }
                            }
                        }

                        VStack {
                            Spacer()
                            Text(ChekinanaL10n.text("assistant.cheki.preview_loaded", fallback: "Full-size image loaded"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.55))
                                .clipShape(Capsule())
                                .accessibilityIdentifier("chekinana.cheki.preview.loaded")
                        }
                    } else if loadState == .unavailable {
                        VStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.system(size: 42, weight: .light))
                            Text(ChekinanaL10n.text("assistant.cheki.preview_unavailable", fallback: "The full-size Cheki image could not be loaded."))
                                .font(.subheadline)
                        }
                        .foregroundStyle(Color(.systemGray2))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("chekinana.cheki.preview.unavailable")
                    } else {
                        ProgressView()
                            .tint(.white)
                            .accessibilityLabel(ChekinanaL10n.text("assistant.cheki.preview_loading", fallback: "Loading full-size Cheki"))
                            .accessibilityIdentifier("chekinana.cheki.preview.loading")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: source.loadID) {
            renderedImage = nil
            loadState = .loading
            let outcome = await ChekinanaChekiPreviewLoader().load(source: source)
            guard !Task.isCancelled else { return }
            renderedImage = outcome.image
            if let loadedSource = outcome.loadedSource,
               outcome.image != nil {
                loadState = .loaded(loadedSource)
            } else {
                loadState = .unavailable
            }
        }
        .onDisappear {
            // Preview-resolution images are owned only by this presentation.
            // Dropping the state releases them instead of retaining them in the
            // shared thumbnail cache after the full-screen cover closes.
            renderedImage = nil
            loadState = .loading
        }
    }
}

struct ChekinanaIdolCardPresentation: Equatable {
    enum ThirdLineKind: Equatable {
        case verification
        case bio
        case chekiCount
    }

    let lines: [String]
    let thirdLineKind: ThirdLineKind

    init(idol: ChekinanaIdolCard) {
        let thirdLine: String
        switch idol.detail {
        case .addCandidate:
            let verification = Self.trimmed(idol.verification)
            if verification.isEmpty {
                thirdLineKind = .bio
                thirdLine = Self.nonempty(idol.bio)
            } else {
                thirdLineKind = .verification
                thirdLine = verification
            }
        case .deleteCandidate:
            thirdLineKind = .chekiCount
            thirdLine = ChekinanaRecordKind.cheki.countLabel(0)
        case .chekiCount(let count):
            thirdLineKind = .chekiCount
            thirdLine = ChekinanaRecordKind.cheki.countLabel(count)
        }
        lines = [
            Self.nonempty(idol.name),
            Self.nonempty(idol.group),
            thirdLine,
        ]
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func nonempty(_ value: String?) -> String {
        let value = trimmed(value)
        return value.isEmpty ? "—" : value
    }
}

private struct IdolCardView: View {
    let idol: ChekinanaIdolCard
    let onSelectCandidate: (() -> Void)?
    let isCandidateConfirmed: Bool
    let isCandidateInteractionEnabled: Bool
    @State private var renderedLocalAvatar: ChekinanaRenderedImage?
    @State private var renderedRemoteAvatar: ChekinanaRenderedImage?

    init(
        idol: ChekinanaIdolCard,
        onSelectCandidate: (() -> Void)? = nil,
        isCandidateConfirmed: Bool = false,
        isCandidateInteractionEnabled: Bool = true
    ) {
        self.idol = idol
        self.onSelectCandidate = onSelectCandidate
        self.isCandidateConfirmed = isCandidateConfirmed
        self.isCandidateInteractionEnabled = isCandidateInteractionEnabled
    }

    private var ringColors: [Color] {
        Color.chekinanaIdolColors(idol.color)
    }

    private var avatarURL: URL? {
        guard let ref = idol.avatarImageRef,
              let url = URL(string: ref),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }

        return url
    }

    private var localAvatarLoadID: String? {
        guard avatarURL == nil,
              let ref = idol.avatarImageRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ref.isEmpty else {
            return nil
        }
        return "\(idol.id.uuidString)|\(ref)"
    }

    private var embeddedAvatarImage: ChekinanaRenderedImage? {
        guard idol.avatarThumbnailData?.isEmpty == false,
              idol.avatarIdentity == ChekinanaIdolAvatarIdentity.make(
                sourceID: idol.catalogueID ?? "",
                avatarURL: idol.avatarImageRef
              ) else {
            return nil
        }
        return idol.avatarThumbnailImage
    }

    private var avatarPlaceholderText: String {
        guard let first = idol.name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "?"
        }

        return String(first).uppercased()
    }

    var body: some View {
        let presentation = ChekinanaIdolCardPresentation(idol: idol)
        HStack(alignment: .center, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.lines[0])
                    .font(.headline)
                    .foregroundStyle(Color(.label))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("chekinana.idol.card.line.1")
                    .textSelection(.enabled)
                    .contextMenu {
                        Button(ChekinanaL10n.text("assistant.copy", fallback: "Copy")) {
                            UIPasteboard.general.string = presentation.lines[0]
                        }
                    }

                ForEach(Array(presentation.lines.dropFirst().enumerated()), id: \.offset) { index, line in
                    informationLine(line, number: index + 2)
                }

            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chekinana.idol.card.information")

            if idol.selectionToken != nil {
                if isCandidateConfirmed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel(ChekinanaL10n.text("assistant.candidate.confirmed", fallback: "Confirmed"))
                        .accessibilityAddTraits(.isSelected)
                        .accessibilityIdentifier("chekinana.idol.candidate.confirmed.\(idol.id.uuidString.lowercased())")
                } else if let onSelectCandidate {
                    Button {
                        onSelectCandidate()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isCandidateInteractionEnabled)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(ChekinanaL10n.format("assistant.candidate.add", fallback: "Add %@", idol.name))
                    .accessibilityHint(ChekinanaL10n.text("assistant.candidate.add_hint", fallback: "Confirm this Idol candidate"))
                    .accessibilityIdentifier("chekinana.idol.candidate.select.\(idol.id.uuidString.lowercased())")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.7), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
    }

    private func informationLine(_ value: String, number: Int) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(Color(.secondaryLabel))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .accessibilityIdentifier("chekinana.idol.card.line.\(number)")
            .textSelection(.enabled)
            .contextMenu {
                Button(ChekinanaL10n.text("assistant.copy", fallback: "Copy")) {
                    UIPasteboard.general.string = value
                }
            }
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray4), lineWidth: 8)

            ForEach(Array(ringColors.enumerated()), id: \.offset) { index, color in
                Circle()
                    .trim(
                        from: Double(index) / Double(ringColors.count),
                        to: Double(index + 1) / Double(ringColors.count)
                    )
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            if let embeddedAvatarImage {
                Image(decorative: embeddedAvatarImage.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
            } else if let renderedLocalAvatar {
                Image(decorative: renderedLocalAvatar.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
            } else if let renderedRemoteAvatar {
                Image(decorative: renderedRemoteAvatar.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
            } else {
                placeholderAvatar
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
            }
        }
        .frame(width: 76, height: 76)
        .accessibilityHidden(true)
        .task(id: localAvatarLoadID) {
            guard let localAvatarLoadID else {
                renderedLocalAvatar = nil
                return
            }
            renderedLocalAvatar = nil
            let thumbnail = await ChekinanaThumbnailCache.shared.thumbnailImage(
                forManagedImageRef: idol.avatarImageRef,
                key: localAvatarLoadID,
                maxDimension: 256
            )
            guard !Task.isCancelled else { return }
            renderedLocalAvatar = thumbnail
        }
        .task(id: avatarURL) {
            renderedRemoteAvatar = nil
            guard embeddedAvatarImage == nil,
                  idol.detail != .addCandidate,
                  let avatarURL else { return }
            let thumbnail = await ChekinanaRemoteImageCache.shared.image(
                for: avatarURL,
                maxDimension: 256
            )
            guard !Task.isCancelled else { return }
            renderedRemoteAvatar = thumbnail
        }
    }

    private var placeholderAvatar: some View {
        ZStack {
            Circle()
                .fill(Color(.systemGray5))

            Text(avatarPlaceholderText)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(.secondaryLabel))
        }
    }
}

private enum PendingChekiImageLoadError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            ChekinanaL10n.text(
                "assistant.photo.unreadable",
                fallback: "One or more selected photos are unavailable or cannot be converted to image data."
            )
        }
    }
}

struct ChekinanaTransferableImageData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            ChekinanaTransferableImageData(data: data)
        }
    }
}

struct ChekinanaTransferableFallbackImageData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            ChekinanaTransferableFallbackImageData(data: data)
        }
    }
}

private extension Color {
    static func chekinanaIdolColors(_ value: String?) -> [Color] {
        let components = value?
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let colors = components.map(chekinanaIdolColor)
        return colors.isEmpty ? [chekinanaIdolColor("")] : colors
    }

    private static func chekinanaIdolColor(_ value: String) -> Color {
        if let preset = ChekinanaIdolPalette.presetName(hex: value) {
            // Keep legacy RGB imports aligned with the product shell's exact
            // preset table without duplicating the table here.
            return chekinanaIdolColor(preset)
        }
        switch value {
        case "棕", "棕色": return Color(red: 0.49, green: 0.30, blue: 0.20)
        case "橙", "橙色": return .orange
        case "水", "水色": return Color(red: 129 / 255, green: 212 / 255, blue: 250 / 255)
        case "灰", "灰色": return .gray
        case "白", "白色": return Color(red: 224 / 255, green: 224 / 255, blue: 224 / 255)
        case "粉", "粉色": return Color(red: 1.0, green: 0.42, blue: 0.68)
        case "紫", "紫色": return .purple
        case "红", "红色": return .red
        case "绿", "绿色": return .green
        case "蓝", "蓝色": return .blue
        case "黑", "黑色": return .black
        case "黄", "黄色": return .yellow
        case "金", "金色": return Color(red: 0.83, green: 0.64, blue: 0.10)
        case "青", "青色", "薄青色": return .cyan
        default: break
        }

        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let rawValue = UInt64(hex, radix: 16) else {
            return Color(red: 1.0, green: 0.824, blue: 0.118)
        }

        let red = Double((rawValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rawValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rawValue & 0x0000FF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                Idol.self,
                Event.self,
                EventSchedule.self,
                Cheki.self,
                Shame.self,
                Douga.self,
            ],
            inMemory: true
        )
}

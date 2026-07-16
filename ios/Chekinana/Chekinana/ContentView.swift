import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct PendingNaturalLanguageRequest: Equatable, Sendable {
    let input: String
    let draft: ChekinanaNLRequestDraft?
    let activeConfirmationCodes: Set<String>
    let selections: ChekinanaConversationSelections
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
        ChekinanaChekiCard(
            id: UUID(),
            imageRef: nil,
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: pendingChekiImages()[0].data,
            idx: 1,
            idolNames: ["Preview Idol"],
            eventName: "Preview Event"
        )
    }
}
#endif

enum ChekinanaSelectedChekiLanguage {
    private static let referencePattern = #"(?:这张|刚才那张|选中的)\s*(?:cheki|切己|切)"#

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
    @State private var mediaLoadProgress = ""
    @State private var transcriptMessages: [TranscriptMessage] = []
    @State private var activeIdolCandidateTokens = Set<String>()
    @State private var isSubmitting = false
    @State private var confirmationLedger = ChekinanaConfirmationLedger()
    @State private var conversationState = ChekinanaConversationState()
    @State private var clarificationDate = Date()
    @State private var nlRequestTask: Task<Void, Never>?
    @State private var nlRequestGate = ChekinanaNLRequestGenerationGate()
    @State private var activeNLRequest: PendingNaturalLanguageRequest?
    @State private var pendingNLRetry: PendingNaturalLanguageRequest?
    @State private var selectedChekiID: UUID?
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white
                .ignoresSafeArea()

            VStack(spacing: 0) {
                titleBar
                transcript
                composer
            }
        }
        .statusBarHidden(false)
        .preferredColorScheme(.light)
        .photosPicker(
            isPresented: albumPickerPresentationBinding,
            selection: albumPickerSelectionBinding,
            maxSelectionCount: 9,
            matching: .images
        )
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
#endif
        }
        .onDisappear {
            invalidateRemoteRequest()
            commandExecutionTask?.cancel()
            invalidateIdolRunners()
            invalidateEventCandidateFlow()
            albumProcessingTask?.cancel()
        }
        .overlay(alignment: .topLeading) {
            uiTestLaunchMarker
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

    private var titleBar: some View {
        Text("Chekinana")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.white)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(height: 0.5)
            }
            .accessibilityIdentifier("chekinana.root")
            .accessibilityValue(isSubmitting ? "busy" : "ready")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if shouldShowEmptyState {
                        transcriptEmptyState
                    }

                    ForEach(transcriptMessages) { message in
                        transcriptMessageView(message)
                            .id(message.id)
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
                    .fill(Color(.systemGray6))
                    .accessibilityElement()
                    .accessibilityLabel("Transcript")
                    .accessibilityValue(transcriptAccessibilityValue)
                    .accessibilityIdentifier("chekinana.transcript")
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                isPromptFocused = false
            }
            .onChange(of: transcriptMessages.count) {
                Task { @MainActor in
                    // Let LazyVStack finish laying out newly appended cards and
                    // confirmation controls before resolving the scroll target.
                    await Task.yield()
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var shouldShowEmptyState: Bool {
        ChekinanaTranscriptEmptyStatePolicy.shouldShow(
            messageCount: transcriptMessages.count,
            hasDraft: conversationState.draft != nil,
            hasEventCandidatePanel: eventCandidateState.phase != .idle
        )
    }

    private var transcriptEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("用自然语言开始整理")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.black)

            Text("智能助手会理解你的需求，再由 App 安全地添加或查看 Idol、用公开微博创建 Event，并整理 Cheki。")
                .font(.system(size: 14))
                .foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)

            Label("要扫描 Cheki，请先选择照片，再发送扫描需求。", systemImage: "photo.on.rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.empty-state")
    }

    @ViewBuilder
    private func transcriptMessageView(_ message: TranscriptMessage) -> some View {
        switch message.content {
        case .text(let text):
            Text(text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.black)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button("复制") {
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
                onSelectCandidate: selectIdolCandidate,
                onCancelCandidates: cancelIdolCandidates
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isSubmitting)
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
            ScannedChekiTranscriptView(count: count, warningCount: warningCount, chekis: chekis)
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
            Button("为全部切补充信息") {
                beginScanAllClarification()
            }
            .buttonStyle(.bordered)
            .disabled(isSubmitting || conversationState.draft != nil)
        }
    }

    private var clarificationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(clarificationPromptText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.black)

                Spacer(minLength: 8)

                Button("取消本次对话") {
                    cancelConversation()
                }
                .font(.system(size: 12))
                .buttonStyle(.plain)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("chekinana.clarification.cancel")
            }

            clarificationControls
                .disabled(isSubmitting)
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var eventCandidatePanel: some View {
        switch eventCandidateState.phase {
        case .idle:
            EmptyView()
        case .extracting(let url):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在提取 Event 候选")
                        .accessibilityIdentifier("chekinana.event.candidate.extracting")
                    Text("正在从公开 Weibo 状态提取 Event 候选…")
                        .font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 8)
                    Button("取消") {
                        cancelEventCandidateFlow(announce: true)
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("chekinana.event.candidate.extract.cancel")
                    .accessibilityHint("取消本次提取，不创建待确认项或 Event")
                }
                Text(url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(2)
            }
            .eventCandidatePanelStyle()
        case .failed(let url, let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("chekinana.event.candidate.error")
                HStack(spacing: 8) {
                    Button("重试") {
                        startEventCandidateExtraction(url: url, echo: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("chekinana.event.candidate.retry")
                    .accessibilityHint("重新调用 Event 提取服务")
                    Button("取消") {
                        cancelEventCandidateFlow(announce: true)
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("chekinana.event.candidate.cancel")
                    .accessibilityHint("关闭候选，不创建待确认项或 Event")
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

    private var naturalLanguageRequestPanel: some View {
        HStack(spacing: 10) {
            if isSubmitting && activeNLRequest != nil {
                ProgressView()
                    .controlSize(.small)
                Text("正在解释需求…")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Button("取消") {
                    cancelRemoteInterpretation()
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("chekinana.nl.cancel")
            } else if pendingNLRetry != nil {
                Text("原输入已保留")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Button("重试") {
                    retryRemoteInterpretation()
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("chekinana.nl.retry")
                Button("取消") {
                    cancelPendingRetry()
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("chekinana.nl.cancel")
            }
        }
        .padding(12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
    }

    private var mediaProcessingPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(mediaLoadProgress.isEmpty ? "正在处理…" : mediaLoadProgress)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Button("取消") {
                cancelMediaProcessing()
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("chekinana.media.cancel")
        }
        .padding(.horizontal, 12)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
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
                    Text("请在输入框继续输入要添加的 Idol 名称。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(.secondaryLabel))
                } else {
                    let choices = ChekinanaConversationCoordinator.idolChoices(modelContext: modelContext)
                    if choices.isEmpty {
                        Text(ChekinanaConversationMessage.idolNotFound.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(.secondaryLabel))
                    } else {
                        FlowChoiceView(
                            options: choices,
                            selectedIDs: Set(conversationState.draft?.selections.selectedIdolIDs ?? [])
                        ) { id in
                            toggleSelectedIdol(id)
                        }
                        Button("继续") {
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
                Button("使用日期") {
                    chooseDateInsteadOfEvent()
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("chekinana.clarification.use-date")
            case .eventName:
                Text("请在输入框继续输入 Event 名称。已保留 URL（如有）。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(.secondaryLabel))
            case .date:
                DatePicker(
                    "日期",
                    selection: $clarificationDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                Button("使用这个日期") {
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
                        title: "扫描结果 \(index + 1)",
                        subtitle: nil
                    )
                }
                if choices.isEmpty {
                    Text("当前没有可用的扫描结果，请先选择照片并扫描。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(.secondaryLabel))
                } else {
                    FlowChoiceView(
                        options: choices,
                        selectedIDs: Set(conversationState.draft?.selections.selectedTemporaryIDs ?? [])
                    ) { id in
                        toggleSelectedTemporaryCheki(id)
                    }
                    HStack(spacing: 8) {
                        Button("使用所选") {
                            completeTemporarySelection()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("chekinana.clarification.use-selected")
                        .disabled(conversationState.draft?.selections.selectedTemporaryIDs.isEmpty != false)

                        Button("全部扫描结果") {
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
                return "找到多个匹配的 Idol，请选择一个。"
            case .event:
                return "找到多个匹配的 Event，请选择一个。"
            }
        }
        switch draft.missing.first {
        case .idol:
            return draft.requiresFreeTextIdolName
                ? "请补充要添加的 Idol 名称。"
                : "请选择至少一个本地 Idol。"
        case .eventOrDate:
            return "请选择一个本地 Event，或使用日期。"
        case .eventName:
            return "还需要 Event 名称。"
        case .date:
            return "请选择日期。"
        case .temporaryCheki:
            return "请选择要保存的扫描结果。"
        case nil:
            return "请完成本次操作。"
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(ChekinanaQuickActions.all) { action in
                    Button {
                        applyQuickAction(action)
                    } label: {
                        Text(action.label)
                            .font(.system(size: 14))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color(.systemGray4), lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                    .accessibilityLabel(action.label)
                    .accessibilityHint("输入框为空时预填建议，不会立即发送或覆盖已有输入")
                    .accessibilityIdentifier("chekinana.quick.\(action.id)")
                }
            }
            .padding(.horizontal, 7)
            .accessibilityIdentifier("chekinana.quick-actions")

            VStack(spacing: 12) {
                TextField("输入自然语言需求或命令…", text: $prompt, axis: .vertical)
                    .font(.system(size: 16))
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
                    .simultaneousGesture(TapGesture().onEnded {
                        isPromptFocused = true
                    })
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                    .accessibilityIdentifier("chekinana.prompt")
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()

                            Button("完成") {
                                isPromptFocused = false
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("chekinana.keyboard.done")
                        }
                    }

                if (isSubmitting && activeNLRequest != nil) || pendingNLRetry != nil {
                    naturalLanguageRequestPanel
                }

                if isSubmitting && activeNLRequest == nil && (albumProcessingTask != nil || commandExecutionTask != nil) {
                    mediaProcessingPanel
                }

                if !selectedItems.isEmpty {
                    selectedPhotosSummary
                }

                HStack {
                    PhotosPicker(selection: $selectedItems, maxSelectionCount: 9, matching: .images) {
                        Image(systemName: "plus")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.black)
                            .frame(width: 28, height: 28)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                    .accessibilityLabel("选择照片")
                    .accessibilityIdentifier("chekinana.photos")

                    Spacer()

                    Button {
                        submitPrompt()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle((prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting) ? Color(.systemGray3) : .white)
                            .frame(width: 28, height: 28)
                            .background((prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting) ? Color(.systemGray6) : .black)
                            .clipShape(Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                    .accessibilityIdentifier("chekinana.send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 9)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 7)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(red: 0.965, green: 0.965, blue: 0.965))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 0.5)
        }
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
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))

            Text("已选择 \(selectedItems.count) 张照片")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
                .accessibilityLabel("已选择照片")
                .accessibilityValue("\(selectedItems.count)")
                .accessibilityIdentifier("chekinana.photos.summary")

            Spacer(minLength: 8)

            Button {
                selectedItems = []
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
            .accessibilityLabel("清空已选照片")
        }
        .padding(.horizontal, 10)
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
            transcriptMessages.append(TranscriptMessage(content: .text(ChekinanaConversationMessage.privacyProtected.text)))
            return
        }

        if let command = ChekinanaPromptRouting.localBareScannerCommand(from: input) {
            transcriptMessages.append(TranscriptMessage(content: .text("> \(command)")))
            prompt = ""
            conversationState.clearDraft()
            executeTypedCommands([command])
            return
        }

        if let command = ChekinanaPromptRouting.localStateCommand(from: input) {
            transcriptMessages.append(TranscriptMessage(content: .text("> \(redactedCommandEcho(for: input))")))
            prompt = ""
            executeCommands([command], announceSingle: false)
            return
        }

        let activeConfirmationCodes = confirmationLedger.activeConfirmationCodes
        guard ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(
            input,
            activeConfirmationCodes: activeConfirmationCodes
        ) else {
            prompt = ""
            transcriptMessages.append(
                TranscriptMessage(content: .text(ChekinanaConversationMessage.privacyProtected.text))
            )
            return
        }

        transcriptMessages.append(TranscriptMessage(content: .text("> \(redactedCommandEcho(for: input))")))
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

    @MainActor
    private func handleSelectedChekiUtterance(_ input: String) -> Bool {
        guard ChekinanaSelectedChekiLanguage.referencesSelectedCheki(input) else {
            return false
        }

        transcriptMessages.append(TranscriptMessage(content: .text("> \(input)")))
        prompt = ""

        guard let selectedChekiID else {
            transcriptMessages.append(TranscriptMessage(content: .text(
                "请先从下方选择一张切，再继续刚才的需求。"
            )))
            executeCommands(["listcheki"], announceSingle: false)
            return true
        }

        guard let rewritten = ChekinanaSelectedChekiLanguage.rewrittenUtterance(
            input,
            selectedChekiID: selectedChekiID
        ) else {
            transcriptMessages.append(TranscriptMessage(content: .text(
                "没有理解你指的是哪张切，请重新选择后再试。"
            )))
            return true
        }

        let translation = ChekinanaNaturalLanguageTranslator.translate(rewritten)
        guard !translation.commands.isEmpty, !translation.needsClarification else {
            transcriptMessages.append(TranscriptMessage(content: .text(translation.message)))
            return true
        }

        transcriptMessages.append(TranscriptMessage(content: .text(translation.message)))
        executeCommands(translation.commands, announceSingle: false)
        return true
    }

    private func startRemoteInterpretation(_ request: PendingNaturalLanguageRequest) {
        nlRequestTask?.cancel()
        let requestGeneration = nlRequestGate.begin()
        activeNLRequest = request
        pendingNLRetry = nil
        isSubmitting = true
        let task = Task { @MainActor in
            do {
                let interpretation = try await ChekinanaNLInterpretClient().interpret(
                    utterance: request.input,
                    localDate: ChekinanaNLInterpretClient.localDateString(),
                    timezone: TimeZone.current.identifier,
                    draft: request.draft,
                    activeConfirmationCodes: request.activeConfirmationCodes
                )
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
                    )
                )
            } catch {
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
    private func handleEventWeiboCandidateInput(_ input: String) -> Bool {
        guard let url = ChekinanaEventWeiboInput.extractedURL(from: input) else {
            return false
        }
        transcriptMessages.append(TranscriptMessage(content: .text("> \(redactedCommandEcho(for: input))")))
        prompt = ""
        guard ChekinanaEventCandidateValidator.isPublicWeiboStatusURL(url) else {
            transcriptMessages.append(TranscriptMessage(content: .text(
                ChekinanaEventCandidateClientError.invalidURL.localizedDescription
            )))
            return true
        }
        startEventCandidateExtraction(url: url, echo: nil)
        return true
    }

    @MainActor
    private func startEventCandidateExtraction(url: String, echo: String?) {
        guard !isSubmitting else { return }
        if let echo {
            transcriptMessages.append(TranscriptMessage(content: .text("> \(redactedCommandEcho(for: echo))")))
        }
        eventCandidateTask?.cancel()
        let generation = eventCandidateState.begin(url: url)
        guard eventCandidateBusyOwner.acquire(generation: generation) else {
            eventCandidateState.invalidate()
            return
        }
        isSubmitting = true
        let task = Task { @MainActor in
            do {
                let fields = try await ChekinanaEventCandidateClient().fetch(weiboURL: url)
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
                    "已提取 Event 候选。请检查并编辑全部字段；此时尚未创建待确认项或写入数据。"
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
                guard eventCandidateState.fail(url: url, message: message, generation: generation) else {
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
        handleCommandResponse(output)
    }

    @MainActor
    private func cancelEventCandidateFlow(announce: Bool) {
        let ownedGeneration = eventCandidateBusyOwner.generation
        eventCandidateTask?.cancel()
        eventCandidateTask = nil
        eventCandidateState.invalidate()
        if let ownedGeneration {
            _ = releaseEventCandidateBusy(generation: ownedGeneration)
        }
        if announce {
            transcriptMessages.append(TranscriptMessage(content: .text(
                "已取消 Event 候选；未创建待确认项，也未写入 Event。"
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

    @MainActor
    private func handleLocalEventUtterance(_ input: String) -> Bool {
        guard let eventDraft = ChekinanaLocalEventLanguage.draft(from: input) else {
            return false
        }
        transcriptMessages.append(TranscriptMessage(content: .text("> \(redactedCommandEcho(for: input))")))
        prompt = ""
        let state = ChekinanaConversationDraftState(
            operation: eventDraft.operation,
            missing: eventDraft.missing
        )
        if eventDraft.missing.isEmpty {
            conversationState.clearDraft()
            processConversationResult(
                ChekinanaConversationCoordinator.compile(
                    [eventDraft.operation],
                    modelContext: modelContext
                )
            )
        } else {
            conversationState.draft = state
            clarificationDate = Date()
            transcriptMessages.append(TranscriptMessage(content: .text(
                clarificationPrompt(for: state)
            )))
        }
        return true
    }

    @MainActor
    private func handleLocalDraftFollowUp(_ input: String) -> Bool {
        guard var draft = conversationState.draft,
              let missing = draft.missing.first else {
            return false
        }
        let originalDraft = draft

        switch missing {
        case .idol:
            if draft.requiresFreeTextIdolName {
                draft.operation.slots.name = input
            } else {
                let normalized = input
                    .replacingOccurrences(of: "、", with: ",")
                    .replacingOccurrences(of: "，", with: ",")
                draft.operation.slots.idols = normalized
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            draft.removeMissing(.idol)
        case .eventOrDate:
            if ChekinanaNLSchemaValidator.isCalendarDate(input) {
                draft.operation.slots.event = nil
                draft.operation.slots.date = input
                draft.selections.selectedEventID = nil
                draft.selections.selectedDate = input
            } else {
                draft.operation.slots.date = nil
                draft.operation.slots.event = input
                draft.selections.selectedDate = nil
            }
            draft.removeMissing(.eventOrDate)
        case .date:
            guard ChekinanaNLSchemaValidator.isCalendarDate(input) else {
                transcriptMessages.append(TranscriptMessage(content: .text("日期请使用 YYYY-MM-DD，例如 2026-07-16。当前选择已保留。")))
                return true
            }
            draft.operation.slots.date = input
            draft.selections.selectedDate = input
            draft.removeMissing(.date)
        case .eventName:
            let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) == nil else {
                transcriptMessages.append(TranscriptMessage(content: .text(
                    "Event 名称不能为空，也不能直接使用 URL。当前 URL 和其他输入已保留。"
                )))
                return true
            }
            draft.operation.slots.name = name
            draft.removeMissing(.eventName)
        case .temporaryCheki:
            return false
        }

        let result = ChekinanaConversationCoordinator.resume(draft, modelContext: modelContext)
        switch result {
        case .commands(let commands):
            transcriptMessages.append(TranscriptMessage(content: .text("> \(redactedCommandEcho(for: input))")))
            prompt = ""
            conversationState.clearDraft()
            executeCommands(commands)
        case .eventCandidateURL(let url):
            transcriptMessages.append(TranscriptMessage(content: .text("> \(redactedCommandEcho(for: input))")))
            prompt = ""
            conversationState.clearDraft()
            startEventCandidateExtraction(url: url, echo: nil)
        case .clarification(let updated):
            transcriptMessages.append(TranscriptMessage(content: .text("> \(redactedCommandEcho(for: input))")))
            prompt = ""
            conversationState.draft = updated
            clarificationDate = Date()
            transcriptMessages.append(TranscriptMessage(content: .text(clarificationPrompt(for: updated))))
        case .message(let message):
            conversationState.draft = originalDraft
            transcriptMessages.append(TranscriptMessage(content: .text("\(message.text) 当前选择和输入均已保留。")))
        }
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
        transcriptMessages.append(TranscriptMessage(content: .text("已取消本次解释请求；原输入和当前选择均已保留。")))
    }

    private func cancelPendingRetry() {
        pendingNLRetry = nil
        transcriptMessages.append(TranscriptMessage(content: .text("已取消重试；原输入仍保留在输入框中。")))
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
        transcriptMessages.append(TranscriptMessage(content: .text("已取消本次对话。")))
    }

    private func submitExplicitCommand(_ command: String) {
        guard !isSubmitting else { return }
        let actionText = commandName(from: command) == "cancel" ? "已选择取消" : "已选择确认"
        transcriptMessages.append(
            TranscriptMessage(content: .text(actionText))
        )
        executeCommands([command], announceSingle: false)
    }

    private func executeCommands(_ commands: [String], announceSingle: Bool = true) {
        guard !commands.isEmpty, !isSubmitting else { return }
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
                if commands.count > 1 {
                    transcriptMessages.append(
                        TranscriptMessage(content: .text("正在准备第 \(index + 1)/\(commands.count) 项操作。"))
                    )
                } else if announceSingle,
                          commandName(from: command) != "confirm",
                          commandName(from: command) != "cancel" {
                    transcriptMessages.append(
                        TranscriptMessage(content: .text("已理解你的需求，正在处理。"))
                    )
                }

                let output: ChekinanaCommandResponse
                do {
                    let pendingImages = try await loadPendingChekiImages(for: command)
                    output = await executor.execute(command, pendingChekiImages: pendingImages)
                } catch ChekinanaAsyncDeadlineError.cancelled {
                    isSubmitting = false
                    return
                } catch {
                    output = .text("error: selected photos could not be loaded. Please keep the photos selected and try again. \(error.localizedDescription)")
                }
                guard !Task.isCancelled else {
                    isSubmitting = false
                    return
                }
                handleCommandResponse(output)

                if ChekinanaConversationCoordinator.responseStopsPlan(output) {
                    if index + 1 < commands.count {
                        transcriptMessages.append(
                            TranscriptMessage(content: .text("后续操作已安全停止，请先完成当前选择或修正错误。"))
                        )
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
                "error: Idol confirmation timed out before persistence started; no Idol was saved. The confirmation remains available to retry."
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
        transcriptMessages.append(TranscriptMessage(content: .text("已取消照片处理；未创建新的 Cheki。")))
    }

    @MainActor
    private func processConversationResult(_ result: ChekinanaConversationCompileResult) {
        switch result {
        case .commands(let commands):
            conversationState.clearDraft()
            isSubmitting = false
            executeTypedCommands(commands)
        case .eventCandidateURL(let url):
            conversationState.clearDraft()
            isSubmitting = false
            startEventCandidateExtraction(url: url, echo: nil)
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
        switch ChekinanaScannerConfiguration.prepareTypedCommands(
            commands,
            configuredPodID: ChekinanaScannerConfiguration.configuredPodID()
        ) {
        case .ready(let preparedCommands):
            executeCommands(preparedCommands)
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
            transcriptMessages.removeAll()
            activeIdolCandidateTokens.removeAll()
            conversationState.clearDraft()
            selectedChekiID = nil
        case .requestAddChekiPhoto(let request):
            albumPickerCancellationTask?.cancel()
            albumPickerCancellationTask = nil
            albumAddChekiRequest = request
            albumAddChekiItems = []
            albumPickerState.begin()
        default:
            if case .idolCards(let cards) = output {
                removeIdolCandidateMessages()
                activeIdolCandidateTokens = Set(cards.compactMap(\.selectionToken))
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
            }
            if case .text(let text) = output, text.hasPrefix("已删除这张切") {
                selectedChekiID = nil
            }
        }
    }

    private func selectCheki(_ card: ChekinanaChekiCard) {
        selectedChekiID = card.id
        let title = card.idx.map { "第 \($0) 张切" } ?? "这张切"
        transcriptMessages.append(TranscriptMessage(content: .text(
            "已选中\(title)。现在可以说“查看这张切”“把这张切的备注改成……”或“删除这张切”。"
        )))
    }

    private func selectIdolCandidate(_ token: String) {
        guard !isSubmitting, activeIdolCandidateTokens.contains(token) else { return }
        // Resolve the whole visible batch immediately. The ledger consumes the
        // same batch synchronously, so no old candidate can become selectable
        // again after this operation returns to ready.
        activeIdolCandidateTokens.removeAll()
        removeIdolCandidateMessages(containing: token)
        transcriptMessages.append(TranscriptMessage(content: .text(
            "已选择此 Idol，正在准备确认预览。"
        )))
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
            let output = await executor.execute("selectidolcandidate \(token)")
            guard idolCandidateSelectionGate.accepts(
                executionID,
                isCancelled: Task.isCancelled
            ) else { return }
            finishIdolCandidateSelection(executionID: executionID, output: output)
        }
        idolCandidateSelectionTask = task
    }

    private func finishIdolCandidateSelection(
        executionID: UUID,
        output: ChekinanaCommandResponse
    ) {
        guard idolCandidateSelectionGate.finish(executionID) else { return }
        idolCandidateSelectionTask = nil
        // Clear the sole busy owner before publishing the preview. Appending a
        // card can immediately trigger LazyVStack layout and animated scrolling.
        isSubmitting = false
        handleCommandResponse(output)
    }

    private func cancelIdolCandidates() {
        guard !isSubmitting else { return }
        confirmationLedger.invalidateIdolCandidates()
        activeIdolCandidateTokens.removeAll()
        removeIdolCandidateMessages()
        transcriptMessages.append(TranscriptMessage(content: .text(
            "已取消本次 Idol 候选；旧候选按钮已失效。"
        )))
    }

    private func removeIdolCandidateMessages(containing token: String? = nil) {
        transcriptMessages.removeAll { message in
            guard case .idolCards(let cards) = message.content else { return false }
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
                TranscriptMessage(content: .text("当前没有可用的扫描结果，请先选择照片并扫描。"))
            )
            return
        }
        var state = ChekinanaConversationDraftState(
            operation: .init(
                intent: .addscancheki,
                slots: .init(temporary: "all")
            ),
            missing: [.idol, .eventOrDate]
        )
        state.selections.usesAllTemporaryChekis = true
        conversationState.draft = state
        transcriptMessages.append(
            TranscriptMessage(content: .text(clarificationPrompt(for: state)))
        )
    }

    private func clarificationPrompt(for draft: ChekinanaConversationDraftState) -> String {
        if let localChoice = draft.localChoice {
            switch localChoice.kind {
            case .idol:
                return "找到多个匹配的 Idol，请从本地候选中选择一个。"
            case .event:
                return "找到多个匹配的 Event，请从本地候选中选择一个。"
            }
        }
        switch draft.missing.first {
        case .idol:
            return draft.requiresFreeTextIdolName
                ? "请补充要添加的 Idol 名称。"
                : "还需要 Idol：请选择至少一个本地 Idol。"
        case .eventOrDate:
            return "还需要 Event 或日期：请选择本地 Event，或使用日期。"
        case .eventName:
            return "还需要 Event 名称；已保留 URL（如有），请继续输入名称。"
        case .date:
            return "还需要日期，请选择。"
        case .temporaryCheki:
            return "还需要扫描结果：请选择一个或多个，或使用全部。"
        case nil:
            return "请完成本次操作。"
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
            transcriptMessages.append(TranscriptMessage(content: .text("album selection cancelled")))
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
            let boundedItems = Array(items.prefix(9))
            for (index, item) in boundedItems.enumerated() {
                guard !Task.isCancelled else { return }
                mediaLoadProgress = "正在读取照片 \(index + 1)/\(boundedItems.count)…"
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
                handleCommandResponse(.text("error: selected photos could not be loaded. No Cheki was prepared."))
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
                handleCommandResponse(.text("error: selected photo could not be prepared. No Cheki was prepared. \(error.localizedDescription)"))
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
            mediaLoadProgress = "正在读取照片 \(index + 1)/\(selectedItems.count)…"
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
            return "[已隐藏包含凭据的 URL]"
        }
        if ChekinanaNLPrivacyGuard.containsPodScanCredential(command) {
            return "[已隐藏包含凭据的输入]"
        }
        guard ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(command) else {
            return "[已隐藏包含凭据的输入]"
        }
        return command
    }

    private var transcriptAccessibilityValue: String {
        let visibleText = transcriptMessages.compactMap { message -> String? in
            guard case .text(let text) = message.content else { return nil }
            return text
        }
        return (["messages=\(transcriptMessages.count)"] + visibleText).joined(separator: "\n")
    }

    private func filenameExtension(for item: PhotosPickerItem) -> String {
        item.supportedContentTypes
            .first { $0.conforms(to: .image) }?
            .preferredFilenameExtension ?? "jpg"
    }
}

private struct TranscriptMessage: Identifiable {
    let id = UUID()
    let content: TranscriptContent
}

private enum TranscriptContent {
    case text(String)
    case idolCard(ChekinanaIdolCard)
    case idolCards([ChekinanaIdolCard])
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
            return .text("已准备好这项更改。请使用下方按钮确认或取消。")
        case .chekiAdded(let count):
            return .text("added cheki: \(count)")
        case .chekiScanned(let count, let warningCount):
            if warningCount > 0 {
                return .text("scanned cheki: \(count)\nwarnings: \(warningCount)")
            }

            return .text("scanned cheki: \(count)")
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
        case .idolSections(let sections):
            return .idolSections(sections)
        case .eventCard(let event):
            return .eventCard(event)
        case .eventCards(let events):
            return .eventCards(events)
        case .requestAddChekiPhoto:
            return .text("请选择一张或多张照片。选好后我会先展示待保存的切。")
        case .clearTranscript:
            return .text("")
        }
    }
}

private struct EventCandidateEditorView: View {
    @Binding var fields: ChekinanaEventCandidateFields
    let blockers: [ChekinanaEventCandidateBlocker]
    let isDisabled: Bool
    let onPrepare: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Event 候选（尚未写入）")
                .font(.system(size: 16, weight: .semibold))

            candidateField("名称 *", text: $fields.name, identifier: "name")
            candidateField("日期", text: $fields.date, identifier: "date", prompt: "YYYY-MM-DD 或留空")
            if fields.date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("未确定日期；将保存为空日期。")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("chekinana.event.candidate.date-undetermined")
            }
            candidateField("城市", text: $fields.city, identifier: "city")
            candidateField("场地", text: $fields.livehouse, identifier: "livehouse")
            candidateField("微博链接 *", text: $fields.weiboURL, identifier: "weibo-url")
            candidateField("票务链接", text: $fields.ticketURL, identifier: "ticket-url")

            VStack(alignment: .leading, spacing: 5) {
                Text("备注")
                    .font(.system(size: 12, weight: .medium))
                TextEditor(text: $fields.note)
                    .frame(minHeight: 72)
                    .padding(6)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .disabled(isDisabled)
                    .accessibilityIdentifier("chekinana.event.candidate.note")
            }

            if !blockers.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(blockers) { blocker in
                        Text("• \(blocker.message)")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("chekinana.event.candidate.blocker.\(blocker.id)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chekinana.event.candidate.blockers")
            }

            HStack(spacing: 8) {
                Button("准备确认") {
                    onPrepare()
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(isDisabled || !blockers.isEmpty)
                .accessibilityIdentifier("chekinana.event.candidate.prepare")
                .accessibilityHint(
                    isDisabled
                        ? "请等待当前操作完成"
                        : blockers.isEmpty
                            ? "冻结当前七个字段并生成确认卡"
                            : "请先修正候选中的阻断问题"
                )

                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(isDisabled)
                .accessibilityIdentifier("chekinana.event.candidate.cancel")
                .accessibilityHint("关闭候选，不创建待确认项或 Event")
            }
        }
        .eventCandidatePanelStyle()
    }

    private func candidateField(
        _ label: String,
        text: Binding<String>,
        identifier: String,
        prompt: String = "可留空"
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isDisabled)
                .accessibilityIdentifier("chekinana.event.candidate.\(identifier)")
        }
    }
}

private struct EventCardView: View {
    let event: ChekinanaEventCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(event.confirmationCode == nil ? "Event" : "待确认 Event")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(event.confirmationCode == nil ? Color(.secondaryLabel) : .orange)
            value("名称", event.name)
            value("日期", event.date.isEmpty ? "未确定日期" : event.date)
            value("城市", emptyFallback(event.city))
            value("场地", emptyFallback(event.livehouse))
            value("微博", emptyFallback(event.weiboURL))
            value("票务", emptyFallback(event.ticketURL))
            value("备注", emptyFallback(event.note))
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
        Text("\(label)：\(value)")
            .font(.system(size: 13))
            .foregroundStyle(.black)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func emptyFallback(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未设置" : value
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
                    Button("确认") {
                        action("confirm \(code)")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("chekinana.confirm.\(code)")

                    Button("取消") {
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
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            if let subtitle = option.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(.secondaryLabel))
                                    .lineLimit(1)
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

    private var summaryText: String {
        var lines = [
            "已识别出 \(count) 张切。",
            "点击“为全部切补充信息”，再选择一个或多个 Idol，以及 Event 或日期。",
            "这些结果尚未保存；完成信息并确认后才会写入。",
        ]
        if warningCount > 0 {
            lines.append("扫描过程有 \(warningCount) 条提醒（例如识别数量与预期不同，或较早的未使用结果被释放）。")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summaryText)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.black)
                .textSelection(.enabled)

            if !chekis.isEmpty {
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
}

private struct PendingChekiTranscriptView: View {
    let summary: String
    let chekis: [ChekinanaChekiCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(summary)\n请使用下方按钮确认或取消。")
                .font(.system(size: 14, design: .monospaced))
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
    let onSelectCandidate: (String) -> Void
    let onCancelCandidates: () -> Void
    @State private var visibleCount = ChekinanaCardBatching.initialCount

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(idols.prefix(visibleCount)) { idol in
                IdolCardView(
                    idol: idol,
                    onSelectCandidate: selectionAction(for: idol)
                )
            }
            if visibleCount < idols.count {
                loadMoreButton(totalCount: idols.count)
            }
            if idols.contains(where: { idol in
                idol.selectionToken.map(activeSelectionTokens.contains) ?? false
            }) {
                Button("取消本次候选") {
                    onCancelCandidates()
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
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

    private func loadMoreButton(totalCount: Int) -> some View {
        Button("Load more (\(min(ChekinanaCardBatching.increment, totalCount - visibleCount)) of \(totalCount - visibleCount) remaining)") {
            visibleCount = min(totalCount, visibleCount + ChekinanaCardBatching.increment)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .accessibilityHint("Shows the next Idol cards")
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
                Button("Load more (\(min(ChekinanaCardBatching.increment, sections.count - visibleCount)) of \(sections.count - visibleCount) remaining)") {
                    visibleCount = min(sections.count, visibleCount + ChekinanaCardBatching.increment)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityHint("Shows the next Idol cards")
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
            return "待确认"
        }
        if let idx = cheki.idx {
            return "第 \(idx) 张切"
        }
        return "扫描结果"
    }

    private var associationText: String? {
        let idols = cheki.idolNames.joined(separator: "、")
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
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(Color(.systemGray3))
                    }

                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
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
            .accessibilityLabel("查看 Cheki 大图")
            .accessibilityHint("打开全屏图片预览，不会选择或修改这张切")
            .accessibilityIdentifier("chekinana.cheki.preview.open.\(cheki.id.uuidString.lowercased())")

            if let associationText {
                Text(associationText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(2)
            }

            if let note = cheki.note, !note.isEmpty {
                Text("备注：\(note)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(2)
            }

            if cheki.confirmationCode == nil, cheki.idx != nil, let onSelect {
                Button(isSelected ? "已选中" : "选择这张切") {
                    onSelect()
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? Color.accentColor : Color(.secondaryLabel))
                .frame(minWidth: 96, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("chekinana.cheki.select.\(cheki.id.uuidString.lowercased())")
            }
        }
        .padding(6)
        .frame(width: 132, alignment: .topLeading)
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
                    Text("Cheki 大图预览")
                        .font(.system(size: 16, weight: .semibold))
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
                    .accessibilityLabel("关闭大图预览")
                    .accessibilityHint("关闭预览并返回原 Cheki 卡片")
                    .accessibilityIdentifier("chekinana.cheki.preview.close")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ZStack {
                    if let renderedImage,
                       case .loaded = loadState {
                        Image(decorative: renderedImage.cgImage, scale: 1, orientation: .up)
                            .resizable()
                            .scaledToFit()
                            .accessibilityHidden(true)

                        VStack {
                            Spacer()
                            Text("大图已加载")
                                .font(.system(size: 11, weight: .medium))
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
                            Text("无法加载这张 Cheki 的大图。")
                                .font(.system(size: 14))
                        }
                        .foregroundStyle(Color(.systemGray2))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("chekinana.cheki.preview.unavailable")
                    } else {
                        ProgressView()
                            .tint(.white)
                            .accessibilityLabel("正在加载 Cheki 大图")
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
    enum FourthLineKind: Equatable {
        case verification
        case chekiCount
    }

    let lines: [String]
    let fourthLineKind: FourthLineKind

    init(idol: ChekinanaIdolCard) {
        let fourthLine: String
        switch idol.detail {
        case .addCandidate:
            fourthLineKind = .verification
            fourthLine = "Verification: \(Self.nonempty(idol.verification))"
        case .deleteCandidate:
            fourthLineKind = .chekiCount
            fourthLine = "0 cheki"
        case .chekiCount(let count):
            fourthLineKind = .chekiCount
            fourthLine = "\(count) \(count > 1 ? "chekis" : "cheki")"
        }
        lines = [
            Self.nonempty(idol.name),
            Self.nonempty(idol.group),
            "Birthday: \(Self.nonempty(idol.birthday))",
            fourthLine,
        ]
    }

    private static func nonempty(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "—" : trimmed
    }
}

private struct IdolCardView: View {
    let idol: ChekinanaIdolCard
    let onSelectCandidate: (() -> Void)?
    @State private var renderedLocalAvatar: ChekinanaRenderedImage?
    @State private var renderedRemoteAvatar: ChekinanaRenderedImage?

    init(
        idol: ChekinanaIdolCard,
        onSelectCandidate: (() -> Void)? = nil
    ) {
        self.idol = idol
        self.onSelectCandidate = onSelectCandidate
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

    private var remoteAvatarUsesCacheOnly: Bool {
        guard case .addCandidate = idol.detail else { return false }
        return idol.selectionToken == nil && idol.confirmationCode != nil
    }

    private var avatarPlaceholderText: String {
        guard let first = idol.name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "?"
        }

        return String(first).uppercased()
    }

    var body: some View {
        let presentation = ChekinanaIdolCardPresentation(idol: idol)
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.lines[0])
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier("chekinana.idol.card.line.1")
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("复制") {
                            UIPasteboard.general.string = presentation.lines[0]
                        }
                    }

                ForEach(Array(presentation.lines.dropFirst().enumerated()), id: \.offset) { index, line in
                    informationLine(line, number: index + 2)
                }

                if idol.selectionToken != nil, let onSelectCandidate {
                    Button("选择此 Idol") {
                        onSelectCandidate()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("chekinana.idol.candidate.select.\(idol.id.uuidString.lowercased())")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Color(.secondaryLabel))
            .lineLimit(1)
            .multilineTextAlignment(.leading)
            .accessibilityIdentifier("chekinana.idol.card.line.\(number)")
            .textSelection(.enabled)
            .contextMenu {
                Button("复制") {
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

            if let renderedLocalAvatar {
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
            guard let avatarURL else { return }
            let thumbnail: ChekinanaRenderedImage?
            if remoteAvatarUsesCacheOnly {
                // Selecting a catalogue candidate is a local state transition.
                // Reuse an already rendered candidate avatar, but never start a
                // fresh request while preparing its confirmation preview.
                thumbnail = await ChekinanaRemoteImageCache.shared.cachedImage(
                    for: avatarURL,
                    maxDimension: 256
                )
            } else {
                thumbnail = await ChekinanaRemoteImageCache.shared.image(
                    for: avatarURL,
                    maxDimension: 256
                )
            }
            guard !Task.isCancelled else { return }
            renderedRemoteAvatar = thumbnail
        }
    }

    private var placeholderAvatar: some View {
        ZStack {
            Circle()
                .fill(Color(.systemGray5))

            Text(avatarPlaceholderText)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
        }
    }
}

private enum PendingChekiImageLoadError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "One or more selected photos are unavailable or cannot be converted to image data."
        }
    }
}

private struct ChekinanaTransferableImageData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            ChekinanaTransferableImageData(data: data)
        }
    }
}

private struct ChekinanaTransferableFallbackImageData: Transferable {
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
        switch value {
        case "棕", "棕色": return Color(red: 0.49, green: 0.30, blue: 0.20)
        case "橙", "橙色": return .orange
        case "水", "水色": return Color(red: 0.31, green: 0.78, blue: 0.91)
        case "灰", "灰色": return .gray
        case "白", "白色": return .white
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
        .modelContainer(for: [Idol.self, Event.self, Cheki.self], inMemory: true)
}

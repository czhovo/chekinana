import Foundation
import XCTest
@testable import Chekinana

private actor ReplyLanguageRequestRecorder {
    private var requests: [ChekinanaReplyLanguageRequest] = []

    func record(_ request: ChekinanaReplyLanguageRequest) {
        requests.append(request)
    }

    var values: [ChekinanaReplyLanguageRequest] { requests }
}

private struct ReplyLanguageMockClient: ChekinanaReplyLanguageClientProtocol {
    let recorder: ReplyLanguageRequestRecorder?
    let decision: ChekinanaReplyLanguageDecision
    let error: ChekinanaNLClientError?

    init(
        recorder: ReplyLanguageRequestRecorder? = nil,
        decision: ChekinanaReplyLanguageDecision = .init(
            language: .undetermined,
            switchRequested: false,
            directiveOnly: false
        ),
        error: ChekinanaNLClientError? = nil
    ) {
        self.recorder = recorder
        self.decision = decision
        self.error = error
    }

    init(error: ChekinanaNLClientError) {
        self.init(error: Optional(error))
    }

    func decide(
        request: ChekinanaReplyLanguageRequest,
        activeConfirmationCodes: Set<String>
    ) async throws -> ChekinanaReplyLanguageDecision {
        await recorder?.record(request)
        if let error { throw error }
        return decision
    }
}

private struct ReplyLanguageDelayedMockClient: ChekinanaReplyLanguageClientProtocol {
    func decide(
        request: ChekinanaReplyLanguageRequest,
        activeConfirmationCodes: Set<String>
    ) async throws -> ChekinanaReplyLanguageDecision {
        try? await Task.sleep(nanoseconds: 20_000_000)
        return .init(language: .english, switchRequested: false, directiveOnly: false)
    }
}

@MainActor
final class ChekinanaAssistantDialogueTests: XCTestCase {
    func testReplyLanguageRequestUsesInitialThenContinuationPhase() async {
        let recorder = ReplyLanguageRequestRecorder()
        let client = ReplyLanguageMockClient(
            recorder: recorder,
            decision: .init(
                language: .english,
                switchRequested: false,
                directiveOnly: false
            )
        )
        let first = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "Please list every event",
            currentLanguage: nil,
            interfaceFallback: .japanese,
            activeConfirmationCodes: [],
            client: client
        )
        XCTAssertEqual(first.language, .english)
        let continuation = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "イベントを一覧表示して",
            currentLanguage: first.language,
            interfaceFallback: .japanese,
            activeConfirmationCodes: [],
            client: client
        )
        XCTAssertEqual(continuation.language, .english)

        let requests = await recorder.values
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].phase, .initial)
        XCTAssertNil(requests[0].currentLanguage)
        XCTAssertEqual(requests[1].phase, .continuation)
        XCTAssertEqual(requests[1].currentLanguage, .english)
    }

    func testInitialReplyLanguageUsesEachModelLanguage() async {
        let cases: [(ChekinanaReplyLanguageCode, ChekinanaAssistantReplyLanguage)] = [
            (.simplifiedChinese, .simplifiedChinese),
            (.traditionalChinese, .traditionalChinese),
            (.japanese, .japanese),
            (.english, .english),
        ]
        for (code, expected) in cases {
            let resolution = await ChekinanaReplyLanguageResolver.resolve(
                utterance: "the first user utterance",
                currentLanguage: nil,
                interfaceFallback: .japanese,
                activeConfirmationCodes: [],
                client: ReplyLanguageMockClient(
                    decision: .init(
                        language: code,
                        switchRequested: false,
                        directiveOnly: false
                    )
                )
            )
            XCTAssertEqual(resolution.language, expected)
            XCTAssertEqual(resolution.businessUtterance, "the first user utterance")
            XCTAssertFalse(resolution.switchRequested)
        }
    }

    func testInitialUndeterminedAndLanguageEndpointErrorUseInterfaceFallback() async {
        let undetermined = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "Alice",
            currentLanguage: nil,
            interfaceFallback: .traditionalChinese,
            activeConfirmationCodes: [],
            client: ReplyLanguageMockClient(
                decision: .init(
                    language: .undetermined,
                    switchRequested: false,
                    directiveOnly: false
                )
            )
        )
        XCTAssertEqual(undetermined.language, .traditionalChinese)

        let failed = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "https://example.com/event/123",
            currentLanguage: nil,
            interfaceFallback: .japanese,
            activeConfirmationCodes: [],
            client: ReplyLanguageMockClient(error: .timedOut)
        )
        XCTAssertEqual(failed.language, .japanese)
        XCTAssertEqual(failed.businessUtterance, "https://example.com/event/123")
    }

    func testContinuationKeepsLanguageWithoutSwitchAndAcceptsSameLanguageSwitch() async {
        let kept = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "Please list all events",
            currentLanguage: .japanese,
            interfaceFallback: .english,
            activeConfirmationCodes: [],
            client: ReplyLanguageMockClient(
                decision: .init(
                    language: .english,
                    switchRequested: false,
                    directiveOnly: false
                )
            )
        )
        XCTAssertEqual(kept.language, .japanese)
        XCTAssertEqual(kept.businessUtterance, "Please list all events")
        XCTAssertFalse(kept.switchRequested)

        let sameLanguageSwitch = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "日本語のまま返信してください",
            currentLanguage: .japanese,
            interfaceFallback: .english,
            activeConfirmationCodes: [],
            client: ReplyLanguageMockClient(
                decision: .init(
                    language: .japanese,
                    switchRequested: true,
                    directiveOnly: true
                )
            )
        )
        XCTAssertEqual(sameLanguageSwitch.language, .japanese)
        XCTAssertTrue(sameLanguageSwitch.switchRequested)
        XCTAssertNil(sameLanguageSwitch.businessUtterance)
    }

    func testPureAndCombinedSwitchUseModelTargetAndOnlyBusinessSubstring() async {
        let pure = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "Please reply in English.",
            currentLanguage: .simplifiedChinese,
            interfaceFallback: .japanese,
            activeConfirmationCodes: [],
            client: ReplyLanguageMockClient(
                decision: .init(
                    language: .english,
                    switchRequested: true,
                    directiveOnly: true
                )
            )
        )
        XCTAssertEqual(pure.language, .english)
        XCTAssertTrue(pure.switchRequested)
        XCTAssertNil(pure.businessUtterance)

        let combined = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "切换到繁体中文，并列出全部活动",
            currentLanguage: .simplifiedChinese,
            interfaceFallback: .english,
            activeConfirmationCodes: [],
            client: ReplyLanguageMockClient(
                decision: .init(
                    language: .traditionalChinese,
                    switchRequested: true,
                    directiveOnly: false,
                    businessUtterance: "列出全部活动"
                )
            )
        )
        XCTAssertEqual(combined.language, .traditionalChinese)
        XCTAssertTrue(combined.switchRequested)
        XCTAssertEqual(combined.businessUtterance, "列出全部活动")
    }

    func testInvalidLanguageResponsesFallBackWithoutDroppingBusinessInput() async throws {
        let input = "切换到英文，然后列出活动"
        let invalidDecisions: [ChekinanaReplyLanguageDecision] = [
            .init(language: .undetermined, switchRequested: true, directiveOnly: true),
            .init(language: .english, switchRequested: false, directiveOnly: true),
            .init(language: .english, switchRequested: false, directiveOnly: false, businessUtterance: "列出活动"),
            .init(language: .english, switchRequested: true, directiveOnly: false),
            .init(language: .english, switchRequested: true, directiveOnly: false, businessUtterance: "不存在的业务文本"),
        ]
        for decision in invalidDecisions {
            XCTAssertThrowsError(try ChekinanaReplyLanguageClient.validate(decision, for: input))
            let resolution = await ChekinanaReplyLanguageResolver.resolve(
                utterance: input,
                currentLanguage: .japanese,
                interfaceFallback: .english,
                activeConfirmationCodes: [],
                client: ReplyLanguageMockClient(decision: decision)
            )
            XCTAssertEqual(resolution.language, .japanese)
            XCTAssertEqual(resolution.businessUtterance, input)
            XCTAssertFalse(resolution.switchRequested)
        }

        let unknownKey = Data(#"{"version":1,"language":"en","switch_requested":false,"directive_only":false,"extra":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ChekinanaReplyLanguageDecision.self, from: unknownKey))
    }

    func testEndpointFailureOnContinuationKeepsCurrentLanguage() async {
        let resolution = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "请列出全部偶像",
            currentLanguage: .traditionalChinese,
            interfaceFallback: .japanese,
            activeConfirmationCodes: [],
            client: ReplyLanguageMockClient(error: .notConnectedToInternet)
        )
        XCTAssertEqual(resolution.language, .traditionalChinese)
        XCTAssertEqual(resolution.businessUtterance, "请列出全部偶像")
    }

    func testPrivacyGuardAndExactConfirmationBypassDoNotCallLanguageClient() async {
        let code = "1a2b3c4d"
        XCTAssertTrue(ChekinanaAssistantInput.isExactLocalConfirmationCommand(
            "confirm \(code)",
            activeCodes: [code]
        ))
        XCTAssertTrue(ChekinanaAssistantInput.isExactLocalConfirmationCommand(
            "cancel \(code)",
            activeCodes: [code]
        ))
        XCTAssertFalse(ChekinanaAssistantInput.isExactLocalConfirmationCommand(
            "confirm \(code) and switch to English",
            activeCodes: [code]
        ))
        XCTAssertTrue(ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(
            "How should an API key be stored?"
        ))

        let recorder = ReplyLanguageRequestRecorder()
        let resolution = await ChekinanaReplyLanguageResolver.resolve(
            utterance: "token=secret-value",
            currentLanguage: .japanese,
            interfaceFallback: .english,
            activeConfirmationCodes: [],
            client: ReplyLanguageMockClient(
                recorder: recorder,
                decision: .init(language: .english, switchRequested: false, directiveOnly: false)
            )
        )
        XCTAssertEqual(resolution.language, .japanese)
        let recordedRequests = await recorder.values
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testCancelledLanguageRequestGateRejectsLateCallback() async {
        var gate = ChekinanaNLRequestGenerationGate()
        let generation = gate.begin()
        let task = Task {
            await ChekinanaReplyLanguageResolver.resolve(
                utterance: "Please list every event",
                currentLanguage: nil,
                interfaceFallback: .japanese,
                activeConfirmationCodes: [],
                client: ReplyLanguageDelayedMockClient()
            )
        }
        gate.invalidate()
        task.cancel()
        _ = await task.value
        XCTAssertFalse(gate.accepts(generation, isCancelled: task.isCancelled))
    }

    func testNoLocalLanguageDetectorOrDirectiveRemainsAndExitInvalidatesLanguageRequest() async throws {
        let dialogueSource = try assistantSource("ChekinanaAssistantDialogue.swift")
        XCTAssertFalse(dialogueSource.contains("ChekinanaAssistantInputLanguageDetector"))
        XCTAssertFalse(dialogueSource.contains("ChekinanaAssistantLanguageDirective"))
        let contentSource = try assistantSource("ContentView.swift")
        XCTAssertTrue(contentSource.contains("invalidateReplyLanguageRequest()"))
        XCTAssertTrue(contentSource.contains("session.replyLanguage = resolution.language"))
    }

    func testReplyLocalizationSurvivesAsyncSuspensionAndUsesTurnLanguage() async {
        let observed = await ChekinanaAssistantReplyLanguage.simplifiedChinese.localized {
            await Task.yield()
            return ChekinanaAssistantReplyLocalization.language
        }
        XCTAssertEqual(observed, .simplifiedChinese)

        let language = ChekinanaAssistantReplyLanguage.simplifiedChinese
        XCTAssertEqual(
            language.text(
                "assistant.dialog.unsupported",
                fallback: "I could not safely match that request."
            ),
            "无法安全确定该请求对应的操作。请明确偶像、拍立得记录、活动或日期范围，未更改任何内容。"
        )
        XCTAssertEqual(
            language.text(
                "assistant.error.network",
                fallback: "The natural-language service is unavailable."
            ),
            "自然语言服务暂时不可用。已保留原输入；可以重试或取消。"
        )
    }

    func testAssistantExitClearsSessionAndReopeningStartsBlank() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("assistant-history-v1.json")
        ChekinanaAssistantHistoryStore.save([.init(role: .user, text: "Old conversation")], to: url)
        let session = ChekinanaAssistantSession(historyURL: url)
        XCTAssertEqual(session.messageCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let oldDialogue = session.dialogue
        let operation = ChekinanaNLOperation(intent: .addidol, slots: .init(name: "Alice"))
        session.prompt = "Unsent text"
        session.transcriptMessages = [.init(content: .text("Current conversation"))]
        session.activeIdolCandidateTokens = ["candidate"]
        session.confirmedIdolCandidateTokens = ["confirmed"]
        session.conversationState.draft = .init(operation: operation, missing: [.idol])
        session.selectedChekiID = UUID()
        session.pendingNLRetry = .init(input: "Retry", draft: nil, activeConfirmationCodes: [], selections: .init())
        session.replyLanguage = .traditionalChinese
        oldDialogue.pendingOperation = operation
        oldDialogue.pendingCodes = ["pending"]
        oldDialogue.remainingOperations = [operation]
        oldDialogue.remainingCommands = ["addidol Alice"]
        oldDialogue.lastSubmittedText = "Old request"
        oldDialogue.consumedConfirmationCodes = ["consumed"]
        let oldLedger = session.confirmationLedger
        session.clearForExit(confirmationLedger: oldLedger)
        XCTAssertEqual(session.prompt, "")
        XCTAssertEqual(session.messageCount, 0)
        XCTAssertTrue(session.activeIdolCandidateTokens.isEmpty)
        XCTAssertTrue(session.confirmedIdolCandidateTokens.isEmpty)
        XCTAssertNil(session.conversationState.draft)
        XCTAssertNil(session.selectedChekiID)
        XCTAssertNil(session.pendingNLRetry)
        XCTAssertNil(session.replyLanguage)
        XCTAssertFalse(session.dialogue === oldDialogue)
        XCTAssertFalse(session.confirmationLedger === oldLedger)
        XCTAssertTrue(session.confirmationLedger.activeConfirmationCodes.isEmpty)
        XCTAssertNil(session.dialogue.pendingOperation)
        XCTAssertTrue(session.dialogue.pendingCodes.isEmpty)
        XCTAssertTrue(session.dialogue.remainingOperations.isEmpty)
        XCTAssertTrue(session.dialogue.remainingCommands.isEmpty)
        XCTAssertTrue(session.dialogue.consumedConfirmationCodes.isEmpty)
        session.clearForExit(confirmationLedger: session.confirmationLedger)
        XCTAssertEqual(session.messageCount, 0)
        XCTAssertEqual(session.prompt, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let reopened = ChekinanaAssistantSession(historyURL: url)
        XCTAssertEqual(reopened.messageCount, 0)
        XCTAssertNil(reopened.pendingNLRetry)
        XCTAssertNil(reopened.replyLanguage)
        XCTAssertNil(reopened.dialogue.target)
        XCTAssertNil(reopened.dialogue.statistics)
    }

    func testAssistantHistoryClearDrainsQueuedOldWritesBeforeDeleting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("assistant-history-v1.json")
        let session = ChekinanaAssistantSession(historyURL: url)
        // Submit enough old serial writes to exercise pending and completed jobs.
        for index in 0..<100 {
            ChekinanaAssistantHistoryWriteQueue.save([.init(role: .assistant, text: "Old response \(index)")], to: url)
        }
        session.clearForExit(confirmationLedger: session.confirmationLedger)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        ChekinanaAssistantHistoryWriteQueue.clear(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(ChekinanaAssistantHistoryStore.load(from: url).isEmpty)
        XCTAssertEqual(ChekinanaAssistantSession(historyURL: url).messageCount, 0)
    }

    func testAssistantExitCancelsOrdinaryConfirmationAndRetainsRequiredRecovery() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("assistant-history-v1.json")
        let session = ChekinanaAssistantSession(historyURL: url)
        var ledger: ChekinanaConfirmationLedger? = session.confirmationLedger
        weak var retained = ledger
        let ordinary = try XCTUnwrap(ledger).insert(.deleteCheki(.init(chekiID: UUID(), phase: .deleteModel)))
        let recovery = try XCTUnwrap(ledger).insert(.deleteCheki(.init(chekiID: UUID(), phase: .cleanupQuarantine(url))))
        session.clearForExit(confirmationLedger: try XCTUnwrap(ledger))
        XCTAssertNil(ledger?.entry(for: ordinary))
        XCTAssertNotNil(ledger?.entry(for: recovery))
        XCTAssertTrue(try XCTUnwrap(ledger).cancellationRequiresRecovery(recovery))
        XCTAssertTrue(session.confirmationLedger.activeConfirmationCodes.isEmpty)
        ledger = nil
        XCTAssertNotNil(retained, "Clearing the chat must keep required recovery ownership")
        session.clearForExit(confirmationLedger: session.confirmationLedger)
        XCTAssertNotNil(retained?.entry(for: recovery))
    }

    func testAllAssistantExitRoutesUseTheSameCancellationAndReset() async throws {
        let source = try assistantSource("ContentView.swift")
        XCTAssertTrue(source.contains(".onDisappear {\n            exitAssistantSession()"))
        XCTAssertTrue(source.contains("guard !isClosing else { return }\n        exitAssistantSession()\n        onClose?()"))
        XCTAssertTrue(source.contains("if let onShellAction {\n                exitAssistantSession()\n                onShellAction(action)"))
        XCTAssertFalse(source.contains("captureAssistantSession"))
        XCTAssertFalse(source.contains("persistTextHistory"))
        let begin = try XCTUnwrap(source.range(of: "private func exitAssistantSession()")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "private func installLongCandidateUITestFixture()")?.lowerBound)
        let exit = String(source[begin..<end])
        for fragment in ["guard !isClosing", "invalidateRemoteRequest()", "commandExecutionTask?.cancel()", "idolCandidateSelectionGate.invalidate()", "idolConfirmationGate.invalidate()", "invalidateEventCandidateFlow()", "session.clearForExit", "prompt = \"\"", "transcriptMessages = []", "pendingNLRetry = nil", "activeNLRequest = nil", "retainedEventFields = nil", "plannedOperations = []", "pendingClarificationPlan = []", "plannedRawTail = []", "clarificationRawTail = []", "replacementEventBackup = nil", "selectedChekiID = nil"] {
            XCTAssertTrue(exit.contains(fragment), fragment)
        }
        XCTAssertLessThan(try XCTUnwrap(exit.range(of: "commandExecutionTask?.cancel()")?.lowerBound), try XCTUnwrap(exit.range(of: "session.clearForExit")?.lowerBound))
    }

    func testSpecifiedScanConfirmationForZeroOneAndMultipleIdols() async {
        for count in [0, 1, 2] {
            var policy = ChekinanaSpecifiedIdolScanConfirmation()
            let ids = Set((0..<count).map { _ in UUID() })
            var launches: [Set<UUID>] = []
            if policy.request(mode: .specified, count: count, canStart: true, isProcessing: false) { launches.append(ids) }
            XCTAssertEqual(policy.isPresented, count != 1)
            XCTAssertEqual(launches.count, count == 1 ? 1 : 0)
            if count != 1 {
                XCTAssertFalse(policy.request(mode: .specified, count: count, canStart: true, isProcessing: false))
                policy.cancel()
                XCTAssertFalse(policy.proceed(canStart: true, isProcessing: false))
                XCTAssertTrue(launches.isEmpty)
                XCTAssertFalse(policy.request(mode: .specified, count: count, canStart: true, isProcessing: false))
                policy.dismissPresentation() // SwiftUI may dismiss before delivering Continue.
                if policy.proceed(canStart: true, isProcessing: false) { launches.append(ids) }
                XCTAssertFalse(policy.proceed(canStart: true, isProcessing: false))
                XCTAssertEqual(launches, [ids])
            }
        }
        for mode: ChekinanaScanRecognitionMode in [.enabled, .disabled] {
            var policy = ChekinanaSpecifiedIdolScanConfirmation()
            XCTAssertTrue(policy.request(mode: mode, count: 0, canStart: true, isProcessing: false))
            XCTAssertFalse(policy.isPresented)
        }
        var policy = ChekinanaSpecifiedIdolScanConfirmation()
        XCTAssertFalse(policy.request(mode: .specified, count: 0, canStart: false, isProcessing: false))
        XCTAssertFalse(policy.request(mode: .specified, count: 2, canStart: true, isProcessing: true))
        XCTAssertFalse(policy.isPresented)
        XCTAssertFalse(policy.request(mode: .specified, count: 2, canStart: true, isProcessing: false))
        XCTAssertFalse(policy.proceed(canStart: false, isProcessing: false))
        XCTAssertFalse(policy.proceed(canStart: true, isProcessing: false))
    }

    func testScanButtonAndJapaneseSharedTitleUseTheApprovedPolicy() async throws {
        let shell = try assistantSource("ChekinanaProductShell.swift")
        XCTAssertFalse(shell.contains("chekinana.scan.specified-idol-required"))
        let canStartBegin = try XCTUnwrap(shell.range(of: "private var canStart: Bool")?.lowerBound)
        let canStartEnd = try XCTUnwrap(shell.range(of: "private var scannerDateBounds:")?.lowerBound)
        XCTAssertFalse(shell[canStartBegin..<canStartEnd].contains("specifiedIdols"))
        let start = try XCTUnwrap(shell.range(of: "private var startButton: some View")?.lowerBound)
        let end = try XCTUnwrap(shell.range(of: "private var scanProgressCard:")?.lowerBound)
        let button = String(shell[start..<end])
        XCTAssertTrue(button.contains("specifiedScanConfirmation.request(mode: idolRecognitionMode"))
        XCTAssertTrue(button.contains("specifiedScanConfirmation.proceed(canStart: canStart, isProcessing: isProcessing)"))
        XCTAssertTrue(button.contains("specifiedScanConfirmation.cancel()"))
        XCTAssertTrue(shell.contains("let forcedIdols = specifiedIdols"))
        let data = try XCTUnwrap(try assistantSource("Localizable.xcstrings").data(using: .utf8))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        func value(_ key: String, _ language: String) throws -> String {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let languages = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let localized = try XCTUnwrap(languages[language] as? [String: Any])
            let unit = try XCTUnwrap(localized["stringUnit"] as? [String: Any])
            return try XCTUnwrap(unit["value"] as? String)
        }
        XCTAssertEqual(try value("product.idols.title", "ja"), "推し")
        XCTAssertTrue(shell.contains("case .idols:\n            ChekinanaProductCopy.text(\"idols.title\""))
        for suffix in ["title", "continue", "none", "multiple"] {
            for language in ["en", "zh-Hans", "zh-Hant", "ja"] {
                XCTAssertFalse(try value("product.scan.specified_confirm." + suffix, language).isEmpty)
            }
        }
    }

    func testTextOnlyScopeRejectsImageCreationAndRetainsTextCRUD() async {
        XCTAssertFalse(ChekinanaAssistantScope.allows([.init(intent: .addcheki)]))
        XCTAssertFalse(ChekinanaAssistantScope.allows([.init(intent: .scancheki)]))
        XCTAssertFalse(ChekinanaAssistantScope.allows([.init(intent: .addscancheki)]))
        for intent: ChekinanaNLIntent in [.addevent, .addrecord, .listcheki, .showcheki, .editcheki, .deletecheki, .statscheki] {
            XCTAssertTrue(ChekinanaAssistantScope.allowedIntents.contains(intent))
        }
        for name in ["addcheki", "scancheki", "addscancheki", "openscan"] { XCTAssertFalse(ChekinanaAssistantScope.allowsCommand(name)) }
        for name in ["addevent", "addrecord", "editcheki", "deletecheki", "confirm"] { XCTAssertTrue(ChekinanaAssistantScope.allowsCommand(name)) }
    }

    func testUnexpectedImageRequestIsTextOnlyAndDoesNotOfferAChooser() async {
        let response = ChekinanaCommandResponse.requestAddChekiPhoto(.init(arguments: [:]))
        guard case .text(let message) = TranscriptContent.commandResponse(response) else { return XCTFail("Unexpected image input must remain a text response") }
        XCTAssertEqual(message, ChekinanaL10n.text("assistant.dialog.text_only", fallback: "Assistant accepts text only. You can manage Idols, existing Cheki, Events, and Cheki quantity records without photos."))
        XCTAssertFalse(message.contains("Choose one or more photos"))
        XCTAssertFalse(message.contains("Scan or Gallery"))
    }

    func testAssistantSurfaceHasNoPhotoIngressAndEntryIsOpen() async throws {
        let content = try assistantSource("ContentView.swift")
        for forbidden in ["PhotosPicker", ".photosPicker", "initialScannerLaunch", "loadTransferable", "loadPendingChekiImages", "selectedPhotosSummary"] {
            XCTAssertFalse(content.contains(forbidden), forbidden)
        }
        let commandStart = try XCTUnwrap(content.range(of: "private func executeCommands(")?.lowerBound)
        let commandEnd = try XCTUnwrap(content.range(of: "private func executeAddIdolConfirmation(")?.lowerBound)
        let execution = String(content[commandStart..<commandEnd])
        let scope = try XCTUnwrap(execution.range(of: "ChekinanaAssistantScope.allowsCommand")?.lowerBound)
        let execute = try XCTUnwrap(execution.range(of: "await executor.execute(command)")?.lowerBound)
        XCTAssertLessThan(scope, execute)
        XCTAssertFalse(execution.contains("pendingChekiImages:"))
        let shell = try assistantSource("ChekinanaProductShell.swift")
        XCTAssertTrue(shell.contains("static let assistantDrawerEntryEnabled = true"))
        let sidebar = String(shell[try XCTUnwrap(shell.range(of: "private struct ChekinanaSidebar: View")?.lowerBound)...])
        let assistant = try XCTUnwrap(sidebar.range(of: "identifier: \"chekinana.shell.drawer.assistant\"")?.lowerBound)
        let match = try XCTUnwrap(sidebar.range(of: "identifier: \"chekinana.shell.drawer.match-game\"")?.lowerBound)
        let entry = String(sidebar[assistant..<match])
        XCTAssertTrue(entry.contains("action: openAssistant"))
        XCTAssertFalse(entry.contains(".disabled(true)"))
        XCTAssertTrue(shell.contains("ContentView("))
        XCTAssertTrue(shell.contains("PhotosPicker("), "Other app pages retain their photo selection controls")
        XCTAssertFalse(shell.contains("ChekinanaAssistantScanLaunch"))
    }

    func testSupportedStatusURLsUseOnlyInjectedExtractorAndProduceConfirmationPreview() async throws {
        let urls = ["https://weibo.com/example/Abc123", "https://x.com/example/status/1234567890123456789"]
        for url in urls {
            let operation = ChekinanaNLOperation(intent: .addevent, slots: .init(url: url))
            XCTAssertEqual(try ChekinanaAssistantEventFlow.extractionURL(in: [operation]), url)
            var requested: [String] = []
            let fields = try await ChekinanaAssistantEventFlow.extract(url: url) { received in
                requested.append(received)
                return ChekinanaEventCandidateFields(name: "Mock Live", date: "2026-09-12", city: "Tokyo", livehouse: "Mock Hall", price: "3000", weiboURL: received, ticketURL: "https://ticketdive.com/event/example", openTime: "18:00", startTime: "18:30")
            }
            XCTAssertEqual(requested, [url])
            XCTAssertEqual(ChekinanaAssistantEventFlow.nextStep(for: fields), .ready)
            let card = ChekinanaAssistantEventFlow.previewCard(fields, confirmationCode: "a1b2c3d4")
            guard case .eventCard(let preview) = TranscriptContent.commandResponse(.eventCard(card)) else { return XCTFail("The event preview must reach the conversation") }
            XCTAssertEqual(preview.name, "Mock Live")
            XCTAssertEqual(preview.date, "2026-09-12")
            XCTAssertEqual(preview.city, "Tokyo")
            XCTAssertEqual(preview.livehouse, "Mock Hall")
            XCTAssertEqual(preview.price, "3000")
            XCTAssertEqual(preview.weiboURL, url)
            XCTAssertEqual(preview.ticketURL, "https://ticketdive.com/event/example")
            XCTAssertEqual(preview.openTime, "18:00")
            XCTAssertEqual(preview.startTime, "18:30")
            XCTAssertEqual(preview.confirmationCode, "a1b2c3d4")
            XCTAssertTrue(ChekinanaAssistantScope.allowsCommand("confirm"))
        }
    }

    func testControllerCandidateContinuationDoesNotExtractAgainForClarify() async throws {
        let url = "https://weibo.com/example/Abc123"
        var extractionCount = 0
        func extract() async throws -> ChekinanaEventCandidateFields {
            try await ChekinanaAssistantEventFlow.extract(url: url) { received in
                extractionCount += 1
                return .init(name: "", date: "", city: "", livehouse: "Preserved Hall", price: "3000", weiboURL: received, ticketURL: "https://ticketdive.com/event/example")
            }
        }
        var retained = try await extract()
        func handle(_ interpretation: ChekinanaNLInterpretation, operation: ChekinanaNLOperation) async throws {
            let before = ChekinanaAssistantEventFlow.operation(for: retained)
            let missing = ChekinanaNLSchemaValidator.expectedMissing(for: before)
            if !missing.isEmpty {
                try ChekinanaNLSchemaValidator.validateContinuation(interpretation, requestDraft: .init(operation: before, missing: missing))
            }
            // This is the same decision used before Coordinator routing in ContentView.
            if let continued = try ChekinanaAssistantEventFlow.continuedCandidate(for: interpretation, retained: retained, resolvedOperation: operation, isCorrection: false) {
                retained = continued
            } else { retained = try await extract() }
        }
        var nameOnly = ChekinanaAssistantEventFlow.operation(for: retained)
        nameOnly.slots.name = "My Live"
        try await handle(.clarify(draft: nameOnly, missing: [.date]), operation: nameOnly)
        XCTAssertEqual(ChekinanaAssistantEventFlow.nextStep(for: retained), .missing([.date]))
        XCTAssertEqual(retained.name, "My Live")
        var dated = nameOnly
        dated.slots.date = "2026-09-12"
        try await handle(.plan([dated]), operation: dated)
        XCTAssertEqual(ChekinanaAssistantEventFlow.nextStep(for: retained), .city)
        var complete = dated
        complete.slots.city = "Tokyo"
        try await handle(.plan([complete]), operation: complete)
        XCTAssertEqual(ChekinanaAssistantEventFlow.nextStep(for: retained), .ready)
        XCTAssertEqual(extractionCount, 1)
        XCTAssertEqual(retained.livehouse, "Preserved Hall")
        XCTAssertEqual(retained.price, "3000")
        let preview = ChekinanaAssistantEventFlow.previewCard(retained, confirmationCode: "a1b2c3d4")
        XCTAssertEqual(preview.name, "My Live")
        XCTAssertEqual(preview.date, "2026-09-12")
        XCTAssertEqual(preview.city, "Tokyo")
        XCTAssertEqual(preview.weiboURL, url)
    }

    func testCandidateContinuationDoesNotWeakenPendingCorrectionValidation() async throws {
        let fields = ChekinanaEventCandidateFields(name: "Original", date: "2026-09-12", city: "Tokyo", livehouse: "Hall", weiboURL: "https://weibo.com/example/Abc123", ticketURL: "")
        let partial = ChekinanaNLOperation(intent: .addevent, slots: .init(name: "Changed", url: fields.weiboURL))
        XCTAssertThrowsError(try ChekinanaAssistantEventFlow.continuedCandidate(for: .clarify(draft: partial, missing: [.date]), retained: fields, resolvedOperation: partial, isCorrection: true))
        XCTAssertEqual(fields.name, "Original")
        XCTAssertNil(try ChekinanaAssistantEventFlow.continuedCandidate(for: .clarify(draft: partial, missing: [.date]), retained: nil, resolvedOperation: partial, isCorrection: false))
    }

    func testURLCandidateMissingNameDateThenCityAdvancesWithoutLosingFields() async throws {
        var fields = ChekinanaEventCandidateFields(name: "", date: "", city: "", livehouse: "Mock Hall", price: "3000", weiboURL: "https://weibo.com/example/Abc123", ticketURL: "https://ticketdive.com/event/example")
        XCTAssertEqual(ChekinanaAssistantEventFlow.nextStep(for: fields), .missing([.eventName, .date]))
        fields = ChekinanaAssistantEventFlow.merge(fields, operation: .init(intent: .addevent, slots: .init(name: "Confirmed Live")))
        XCTAssertEqual(ChekinanaAssistantEventFlow.nextStep(for: fields), .missing([.date]))
        fields = ChekinanaAssistantEventFlow.merge(fields, operation: .init(intent: .addevent, slots: .init(date: "2026-09-12")))
        XCTAssertEqual(ChekinanaAssistantEventFlow.nextStep(for: fields), .city)
        fields = ChekinanaAssistantEventFlow.merge(fields, operation: .init(intent: .addevent, slots: .init(city: "Tokyo")))
        XCTAssertEqual(ChekinanaAssistantEventFlow.nextStep(for: fields), .ready)
        let operation = ChekinanaAssistantEventFlow.operation(for: fields)
        try ChekinanaNLSchemaValidator.validateOperation(operation, allowingPartial: false)
        XCTAssertEqual(operation.slots.name, "Confirmed Live")
        XCTAssertEqual(operation.slots.date, "2026-09-12")
        XCTAssertEqual(operation.slots.city, "Tokyo")
        XCTAssertEqual(operation.slots.livehouse, "Mock Hall")
        XCTAssertEqual(operation.slots.price, "3000")
        XCTAssertEqual(operation.slots.url, "https://weibo.com/example/Abc123")
    }

    func testExplicitEventFieldsOverrideExtractionAndPreserveUnspecifiedMetadata() async {
        let extracted = ChekinanaEventCandidateFields(name: "Extracted", date: "2026-09-11", city: "Osaka", livehouse: "Original Hall", price: "2000", avatarURL: "https://example.com/fixture.jpg", imageUrls: ["https://example.com/fixture.jpg"], weiboURL: "https://weibo.com/example/Abc123", ticketURL: "https://ticketdive.com/event/original", openTime: "18:00", startTime: "18:30")
        let requested = ChekinanaNLOperation(intent: .addevent, slots: .init(name: "My Live", date: "2026-09-12", note: "My own note", city: "Tokyo", livehouse: "New Hall", price: "3000", ticketURL: "https://ticketdive.com/event/updated"))
        let merged = ChekinanaAssistantEventFlow.merge(extracted, operation: requested)
        XCTAssertEqual(merged.name, "My Live")
        XCTAssertEqual(merged.date, "2026-09-12")
        XCTAssertEqual(merged.city, "Tokyo")
        XCTAssertEqual(merged.livehouse, "New Hall")
        XCTAssertEqual(merged.price, "3000")
        XCTAssertEqual(merged.note, "My own note")
        XCTAssertEqual(merged.ticketURL, "https://ticketdive.com/event/updated")
        XCTAssertEqual(merged.weiboURL, extracted.weiboURL)
        XCTAssertEqual(merged.avatarURL, extracted.avatarURL)
        XCTAssertEqual(merged.imageUrls, extracted.imageUrls)
        XCTAssertEqual(merged.openTime, "18:00")
    }

    func testInvalidURLNeverReachesInjectedExtractor() async {
        var invoked = false
        do {
            _ = try await ChekinanaAssistantEventFlow.extract(url: "https://user:fixture@example.com/status/123") { _ in
                invoked = true
                return .init(name: "Bad", date: "", city: "", livehouse: "", weiboURL: "", ticketURL: "")
            }
            XCTFail("Unsupported or credentialed URLs must be rejected")
        } catch {}
        XCTAssertFalse(invoked)
    }

    private func assistantSource(_ name: String) throws -> String {
#if CHEKINANA_ASSISTANT_HOST
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["CHEKINANA_SOURCE_ROOT"])
        return try String(contentsOfFile: root + "/Chekinana/" + name, encoding: .utf8)
#else
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Chekinana/" + name), encoding: .utf8)
#endif
    }

    func testConfirmationTranscriptPreservesReviewedObjectAndQuantity() async {
        let summary = "Add 3 Cheki\nAlice · 2026-09-12 · Birthday Live"
        let content = TranscriptContent.commandResponse(.confirmationText(summary, confirmationCode: "a1b2c3d4"))
        guard case .text(let shown) = content else { return XCTFail("A confirmation must retain its reviewed text") }
        XCTAssertEqual(shown, summary)
        XCTAssertFalse(shown.contains("a1b2c3d4"))
    }

    func testQuantityContractAndDatePairAreStrict() async throws {
        for count in [1, 3, 100] {
            try ChekinanaNLSchemaValidator.validateOperation(.init(intent: .addrecord, slots: .init(recordType: "cheki", count: count)), allowingPartial: false)
        }
        for count in [0, 101, -1] {
            XCTAssertThrowsError(try ChekinanaNLSchemaValidator.validateOperation(.init(intent: .addrecord, slots: .init(recordType: "cheki", count: count)), allowingPartial: false))
        }
        try ChekinanaNLSchemaValidator.validateOperation(.init(intent: .editrecord, slots: .init(target: "the selected record", recordType: "cheki", count: 0)), allowingPartial: false)
        XCTAssertThrowsError(try ChekinanaNLSchemaValidator.validateOperation(.init(intent: .editcheki, slots: .init(target: "the selected Cheki", count: 3)), allowingPartial: false))
        XCTAssertThrowsError(try ChekinanaNLSchemaValidator.validateOperation(.init(intent: .statscheki, slots: .init(dateFrom: "2026-09-01")), allowingPartial: false))
        try ChekinanaNLSchemaValidator.validateDraft(.init(intent: .statscheki, slots: .init(dateFrom: "2026-09-01")), missing: [.date])
        XCTAssertThrowsError(try ChekinanaNLSchemaValidator.validateOperation(.init(intent: .statscheki, slots: .init(dateFrom: "2026-09-10", dateTo: "2026-09-01")), allowingPartial: false))
        try ChekinanaNLSchemaValidator.validateOperation(.init(intent: .statscheki, slots: .init(dateFrom: "2026-09-01", dateTo: "2026-09-10")), allowingPartial: false)
    }

    func testBoundSimpleAdditionRequiresCurrentCountAndPreservesIdentity() async throws {
        let context = ChekinanaNLContext(lastTarget: .init(kind: .chekiRecord, name: nil))
        try context.validate(.init(intent: .addrecord, slots: .init(recordType: "cheki", count: 3, contextRef: "last_target")))
        XCTAssertThrowsError(try context.validate(.init(intent: .addrecord, slots: .init(recordType: "cheki", contextRef: "last_target"))))
        XCTAssertThrowsError(try context.validate(.init(intent: .addrecord, slots: .init(date: "2026-09-12", recordType: "cheki", count: 3, contextRef: "last_target"))))
        XCTAssertThrowsError(try context.validate(.init(intent: .statscheki, slots: .init(contextRef: "last_target"))))
    }

    func testWrongKindAndMissingContextCannotAuthorizeWrites() async throws {
        let idolContext = ChekinanaNLContext(lastTarget: .init(kind: .idol, name: "Alice"))
        try idolContext.validate(.init(intent: .favoriteidol, slots: .init(favorite: true, contextRef: "last_target")))
        XCTAssertThrowsError(try idolContext.validate(.init(intent: .deletecheki, slots: .init(contextRef: "last_target"))))
        XCTAssertThrowsError(try idolContext.validate(.init(intent: .deleteidol, slots: .init(target: "Bob", contextRef: "last_target"))))
        XCTAssertThrowsError(try ChekinanaNLContext.validate(.plan([.init(intent: .deleteidol, slots: .init(contextRef: "last_target"))]), using: nil))
        let queryContext = ChekinanaNLContext(lastStatistics: .init(idol: "Alice", dateFrom: "2026-09-01", dateTo: "2026-09-10"))
        try queryContext.validate(.init(intent: .statscheki, slots: .init(dateFrom: "2026-08-01", dateTo: "2026-08-31", contextRef: "last_statistics")))
        XCTAssertThrowsError(try queryContext.validate(.init(intent: .deletecheki, slots: .init(contextRef: "last_statistics"))))
    }

    func testCompletePendingCorrectionsRetainFieldsAndClearMembership() async throws {
        let original = ChekinanaNLOperation(intent: .addrecord, slots: .init(date: "2026-09-12", idols: ["Alice"], recordType: "cheki", count: 2))
        let draft = ChekinanaNLRequestDraft(operation: original, missing: [])
        try ChekinanaNLSchemaValidator.validateDraft(original, missing: [])
        var correction = original
        correction.slots.count = 3
        try ChekinanaNLSchemaValidator.validateContinuation(.plan([correction]), requestDraft: draft)
        correction.slots.idols = nil
        XCTAssertThrowsError(try ChekinanaNLSchemaValidator.validateContinuation(.plan([correction]), requestDraft: draft))
        let cleared = ChekinanaNLOperation(intent: .editidol, slots: .init(target: "Alice", clearFields: ["bio", "birthday"]))
        var replacement = ChekinanaNLOperation(intent: .editidol, slots: .init(target: "Alice", bio: "Happy", clearFields: ["birthday"]))
        try ChekinanaNLSchemaValidator.validateContinuation(.plan([replacement]), requestDraft: .init(operation: cleared, missing: []))
        replacement.slots.clearFields = nil
        XCTAssertThrowsError(try ChekinanaNLSchemaValidator.validateContinuation(.plan([replacement]), requestDraft: .init(operation: cleared, missing: [])))
    }

    func testPartialEventFieldsCannotBeSilentlyOverwritten() async throws {
        let operation = ChekinanaNLOperation(intent: .addevent, slots: .init(name: "Birthday Live", note: "Doors at six", city: "Shanghai", livehouse: "Hall A", price: "100", ticketURL: "https://example.com/tickets"))
        let draft = ChekinanaNLRequestDraft(operation: operation, missing: [.date])
        var filled = operation
        filled.slots.date = "2026-09-12"
        try ChekinanaNLSchemaValidator.validateContinuation(.plan([filled]), requestDraft: draft)
        for field in ["city", "venue", "price", "ticket"] {
            var changed = filled
            switch field {
            case "city": changed.slots.city = "Beijing"
            case "venue": changed.slots.livehouse = "Hall B"
            case "price": changed.slots.price = "200"
            default: changed.slots.ticketURL = "https://example.com/other"
            }
            XCTAssertThrowsError(try ChekinanaNLSchemaValidator.validateContinuation(.plan([changed]), requestDraft: draft))
        }
    }

    func testRequestDoesNotEncodeLocalAuthorizationFlagOrPrivateIdentity() async throws {
        var slots = ChekinanaNLSlots(recordType: "cheki", count: 3)
        slots.isLocallyResolved = true
        let json = String(decoding: try JSONEncoder().encode(slots), as: UTF8.self)
        XCTAssertFalse(json.contains("isLocallyResolved"))
        XCTAssertThrowsError(try JSONDecoder().decode(ChekinanaNLSlots.self, from: Data(#"{"record_type":"cheki","count":true}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ChekinanaNLSlots.self, from: Data(#"{"isLocallyResolved":true}"#.utf8)))
        let bad = ChekinanaNLContext(lastTarget: .init(kind: .idol, name: "10000000-0000-0000-0000-000000000001"))
        XCTAssertThrowsError(try bad.validatePrivacy(activeConfirmationCodes: []))
    }

    func testFourLanguageControlsAndCorrections() async {
        for text in ["确认", "確認", "confirm", "はい"] { XCTAssertEqual(ChekinanaAssistantInput.control(text), .confirm) }
        for text in ["取消", "cancel", "キャンセル"] { XCTAssertEqual(ChekinanaAssistantInput.control(text), .cancel) }
        for text in ["日期改成昨天", "數量改為3張", "change the date to yesterday", "日付を昨日にして", "数量を3枚に変えて"] {
            XCTAssertTrue(ChekinanaAssistantInput.isCorrection(text), text)
        }
        XCTAssertFalse(ChekinanaAssistantInput.isCorrection("统计上个月"))
    }

    func testOrdinalsDoNotBecomeCountsOrGuessNames() async {
        for value in ["第三张", "第3張", "3枚目", "third cheki", "3rd item"] { XCTAssertEqual(ChekinanaAssistantInput.ordinal(value), 2, value) }
        XCTAssertNil(ChekinanaAssistantInput.ordinal("Third Act"))
        XCTAssertNil(ChekinanaAssistantInput.ordinal("Alice"))
        XCTAssertNil(ChekinanaAssistantInput.ordinal("add 3 Cheki"))
    }

    func testRepeatPermissionIsAnActionNotANoteOrName() async {
        XCTAssertFalse(ChekinanaAssistantInput.isExplicitRepeat("昨天切A3张，备注是又见面了"))
        XCTAssertFalse(ChekinanaAssistantInput.isExplicitRepeat("Add 3 Cheki with Again", excluding: ["Again"]))
        XCTAssertFalse(ChekinanaAssistantInput.isExplicitRepeat("Add 3 Cheki with Again", excluding: ["again"]))
        XCTAssertTrue(ChekinanaAssistantInput.isExplicitRepeat("再给A加3张"))
        XCTAssertTrue(ChekinanaAssistantInput.isExplicitRepeat("Add 3 more Cheki with Alice", excluding: ["Alice"]))
        var history = ChekinanaAssistantWriteHistory()
        let generation = UUID()
        history.complete("Yesterday Alice 3", generation: generation)
        XCTAssertTrue(history.contains("Yesterday Alice 3", generation: generation))
        XCTAssertFalse(history.contains("Yesterday Alice 3", generation: UUID()))
    }

    func testPartialPhotoConfirmationKeepsOtherCodesAndAppliedWriteHistory() async {
        var group = ChekinanaAssistantConfirmationGroup(["photo-one", "photo-two", "recovery-three"])
        var history = ChekinanaAssistantWriteHistory()
        let generation = UUID()
        XCTAssertTrue(group.recordSuccess("photo-one"))
        history.complete("Add these three photos", generation: generation)
        XCTAssertFalse(group.isComplete)
        XCTAssertEqual(group.pendingCodes, ["photo-two", "recovery-three"])
        XCTAssertFalse(group.recordSuccess("photo-one"))
        XCTAssertEqual(group.pendingCodes, ["photo-two", "recovery-three"])
        XCTAssertTrue(history.contains("Add these three photos", generation: generation), "Cancelling remaining photos must not make an already applied photo eligible for replay")
        // Failed/unconfirmed recovery entries remain until their own successful completion.
        XCTAssertFalse(group.recordSuccess("unrelated"))
        XCTAssertTrue(group.recordSuccess("photo-two"))
        XCTAssertFalse(group.isComplete)
        XCTAssertEqual(group.pendingCodes, ["recovery-three"])
        XCTAssertTrue(group.recordSuccess("recovery-three"))
        XCTAssertTrue(group.isComplete)
        XCTAssertFalse(group.recordSuccess("recovery-three"))
    }

    func testLatestNumberedSourceCannotConfirmAnOlderCatalogueCandidate() async {
        XCTAssertEqual(ChekinanaAssistantChoicePolicy.route(1, source: .library, libraryCount: 3, catalogueCount: 5, clarificationCount: 0), .library)
        XCTAssertEqual(ChekinanaAssistantChoicePolicy.route(1, source: .catalogue, libraryCount: 3, catalogueCount: 5, clarificationCount: 0), .catalogue)
        XCTAssertEqual(ChekinanaAssistantChoicePolicy.route(1, source: .none, libraryCount: 3, catalogueCount: 5, clarificationCount: 0), .none)
        XCTAssertEqual(ChekinanaAssistantChoicePolicy.route(4, source: .library, libraryCount: 3, catalogueCount: 5, clarificationCount: 0), .none)
    }

    func testControlledErrorDoesNotExposeLocalUUIDOrConfirmationCode() async {
        let id = "10000000-0000-0000-0000-000000000001"
        let cleaned = ChekinanaAssistantInput.sanitizedError("error: No Idol matches \(id)", privateCodes: [])
        XCTAssertTrue(cleaned.hasPrefix("error:"))
        XCTAssertFalse(cleaned.contains(id))
        XCTAssertFalse(ChekinanaAssistantInput.sanitizedError("error: expired a1b2c3d4", privateCodes: ["a1b2c3d4"]).contains("a1b2c3d4"))
    }

#if CHEKINANA_ASSISTANT_HOST
    func testPendingOrdinalCorrectionKeepsItsResolvedObjectAfterANewList() async throws {
        let original = ChekiRecord(count: 5)
        let other = ChekiRecord(count: 2)
        let database = AssistantHostContainer(records: [original, other])
        let context = ModelContext(database)
        let dialogue = ChekinanaAssistantDialogue()
        let request = ChekinanaNLOperation(intent: .editrecord, slots: .init(target: "第1条", recordType: "cheki", count: 3))
        dialogue.pendingOperation = request
        dialogue.pendingTarget = try XCTUnwrap(dialogue.captureWriteTarget("editrecord cheki target=\(original.id.uuidString.lowercased()) count=3", in: context))
        // A permitted intervening read displays another numbered list.
        dialogue.choices = [try XCTUnwrap(dialogue.capture(.init(kind: .chekiRecord, id: other.id), in: context))]
        var correction = request
        correction.slots.count = 4
        let resolved = try dialogue.resolveCorrection(correction, previous: request, in: context)
        XCTAssertEqual(resolved.slots.target, original.id.uuidString.lowercased())
        XCTAssertEqual(resolved.slots.count, 4)
        correction.slots.target = "1"
        XCTAssertEqual(try dialogue.resolveCorrection(correction, previous: request, in: context).slots.target, original.id.uuidString.lowercased())
        correction.slots.target = "第2条"
        XCTAssertThrowsError(try dialogue.resolveCorrection(correction, previous: request, in: context))
        XCTAssertFalse(ChekinanaAssistantInput.explicitlyChangesTarget("数量改成2张", from: "第1条", to: "第2条"))
        XCTAssertTrue(ChekinanaAssistantInput.explicitlyChangesTarget("目标改为第2条", from: "第1条", to: "第2条"))
        XCTAssertFalse(ChekinanaAssistantInput.explicitlyChangesTarget("备注改成不是Alice是Bob", from: "Alice", to: "Bob", excluding: ["不是Alice是Bob"]))
        correction.slots.target = "第1条"
        original.count = 8
        XCTAssertThrowsError(try dialogue.resolveCorrection(correction, previous: request, in: context))
        XCTAssertEqual(dialogue.pendingOperation, request)
    }

    func testBoundIdolAndSimpleRecordCountCorrectionsKeepTheirBindings() async throws {
        let idol = Idol(name: "Alice")
        let record = ChekiRecord(idols: [idol], date: ChekinanaDateOnly.parse("2026-09-12"), count: 2)
        let unassigned = ChekiRecord(count: 2)
        let context = ModelContext(AssistantHostContainer(idols: [idol], records: [record, unassigned]))
        let references: [ChekinanaAssistantTargetReference] = [.init(kind: .idol, id: idol.id), .init(kind: .chekiRecord, id: record.id), .init(kind: .chekiRecord, id: unassigned.id)]
        for reference in references {
            let dialogue = ChekinanaAssistantDialogue()
            let executionTarget = try XCTUnwrap(dialogue.capture(reference, in: context))
            let initial = ChekinanaNLOperation(intent: .addrecord, slots: .init(recordType: "cheki", count: 2, contextRef: "last_target"))
            dialogue.pendingTarget = dialogue.captureWriteTarget("addrecord cheki count=2", in: context) ?? executionTarget
            var corrected = initial
            corrected.slots.count = 3
            let resolved = try dialogue.resolveCorrection(corrected, previous: initial, in: context)
            try ChekinanaNLSchemaValidator.validateOperation(resolved, allowingPartial: false)
            XCTAssertEqual(resolved.slots.count, 3)
            if reference.id == unassigned.id {
                XCTAssertNil(resolved.slots.idols)
                XCTAssertNil(resolved.slots.note)
            } else { XCTAssertEqual(resolved.slots.idols, [idol.id.uuidString.lowercased()]) }
            if reference.id == record.id { XCTAssertEqual(resolved.slots.date, "2026-09-12") }
        }
        XCTAssertEqual(record.count, 2, "Preparing a correction must not apply it")
    }

    func testCorrectionTargetBindingMatrix() async throws {
        for allowsChange in [false, true] {
            for sameSelector in [false, true] {
                for oldSnapshotValid in [false, true] {
                    let original = ChekiRecord(count: 5)
                    let firstNow = ChekiRecord(count: 2)
                    let secondNow = ChekiRecord(count: 6)
                    let context = ModelContext(AssistantHostContainer(records: [original, firstNow, secondNow]))
                    let dialogue = ChekinanaAssistantDialogue()
                    dialogue.pendingTarget = try XCTUnwrap(dialogue.capture(.init(kind: .chekiRecord, id: original.id), in: context))
                    dialogue.choices = [firstNow, secondNow].map { dialogue.capture(.init(kind: .chekiRecord, id: $0.id), in: context)! }
                    if !oldSnapshotValid { original.count = 9 }
                    let before = ChekinanaNLOperation(intent: .editrecord, slots: .init(target: "第1条", recordType: "cheki", count: 3))
                    let after = ChekinanaNLOperation(intent: .editrecord, slots: .init(target: sameSelector ? "第1条" : "第2条", recordType: "cheki", count: 4))
                    if allowsChange {
                        let resolved = try dialogue.resolveCorrection(after, previous: before, allowsTargetChange: true, in: context)
                        XCTAssertEqual(resolved.slots.target, (sameSelector ? firstNow.id : secondNow.id).uuidString.lowercased())
                    } else if sameSelector && oldSnapshotValid {
                        XCTAssertEqual(try dialogue.resolveCorrection(after, previous: before, in: context).slots.target, original.id.uuidString.lowercased())
                    } else {
                        XCTAssertThrowsError(try dialogue.resolveCorrection(after, previous: before, in: context))
                    }
                }
            }
        }
    }

    func testPendingNameCorrectionDoesNotRebindToAReusedName() async throws {
        let original = Idol(name: "Alice")
        let database = AssistantHostContainer(idols: [original])
        let context = ModelContext(database)
        let dialogue = ChekinanaAssistantDialogue()
        let request = ChekinanaNLOperation(intent: .editidol, slots: .init(target: "Alice", bio: "First"))
        dialogue.pendingTarget = try XCTUnwrap(dialogue.captureWriteTarget("editidol \(original.id.uuidString.lowercased()) bio=First", in: context))
        original.name = "Renamed"
        database.idols.append(Idol(name: "Alice"))
        var correction = request
        correction.slots.bio = "Second"
        XCTAssertThrowsError(try dialogue.resolveCorrection(correction, previous: request, in: context))
    }

    func testOriginalBoundBStaysBWhenCreatingANewA() async throws {
        let b = Idol(name: "B")
        let database = AssistantHostContainer(idols: [b])
        let context = ModelContext(database)
        let dialogue = ChekinanaAssistantDialogue()
        let original = try XCTUnwrap(dialogue.capture(.init(kind: .idol, id: b.id), in: context))
        let a = Idol(name: "A")
        database.idols.append(a)
        dialogue.target = dialogue.capture(.init(kind: .idol, id: a.id), in: context)
        let request = ChekinanaNLOperation(intent: .addrecord, slots: .init(recordType: "cheki", count: 3, contextRef: "last_target"))
        let bound = try dialogue.resolveBound(request, to: original, in: context)
        XCTAssertEqual(bound.slots.idols, [b.id.uuidString.lowercased()])
        XCTAssertEqual(dialogue.target?.reference.id, a.id)
        b.name = "Changed"
        XCTAssertThrowsError(try dialogue.resolveBound(request, to: original, in: context))
    }

    func testOrdinalWritesRequireTheMatchingPhysicalKind() async throws {
        let simple = ChekiRecord(count: 5)
        let photo = MediaItem()
        let database = AssistantHostContainer(media: [photo], records: [simple])
        let context = ModelContext(database)
        let dialogue = ChekinanaAssistantDialogue()
        dialogue.choices = [try XCTUnwrap(dialogue.capture(.init(kind: .chekiRecord, id: simple.id), in: context)), try XCTUnwrap(dialogue.capture(.init(kind: .cheki, id: photo.id), in: context))]
        XCTAssertThrowsError(try dialogue.resolve(.init(intent: .deletecheki, slots: .init(target: "第1张")), in: context))
        let media = try dialogue.resolve(.init(intent: .deletecheki, slots: .init(target: "2枚目")), in: context)
        XCTAssertEqual(media.slots.target, photo.id.uuidString.lowercased())
        let wholeRecord = try dialogue.resolve(.init(intent: .deleterecord, slots: .init(target: "第1条", recordType: "cheki")), in: context)
        XCTAssertEqual(wholeRecord.slots.target, simple.id.uuidString.lowercased())
    }

    func testRenamedStatisticsFilterDoesNotRebindToAReplacementName() async throws {
        let original = Idol(name: "A")
        let database = AssistantHostContainer(idols: [original])
        let context = ModelContext(database)
        let dialogue = ChekinanaAssistantDialogue()
        _ = try ChekinanaAssistantLibrary.read(.init(name: "statscheki", target: nil, arguments: ["idol": "A"]), in: context, dialogue: dialogue)
        XCTAssertNotNil(dialogue.safeContext(in: context, codes: [])?.lastStatistics)
        original.name = "B"
        database.idols.append(Idol(name: "A"))
        XCTAssertNil(dialogue.safeContext(in: context, codes: [])?.lastStatistics)
    }

    func testStatisticsReadsFreshVisibleRowsAndUsesRecordDate() async throws {
        let a = Idol(name: "A")
        let b = Idol(name: "B")
        let record = ChekiRecord(idols: [a], date: ChekinanaDateOnly.parse("2026-09-01"), count: 2)
        let photo = MediaItem(idols: [a, b], date: ChekinanaDateOnly.parse("2026-09-10"))
        let database = AssistantHostContainer(idols: [a, b], media: [photo], records: [record])
        let context = ModelContext(database)
        let dialogue = ChekinanaAssistantDialogue()
        let command = ChekinanaParsedCommand(name: "statscheki", target: nil, arguments: ["idol": "A", "date_from": "2026-09-01", "date_to": "2026-09-10"])
        let first = try XCTUnwrap(ChekinanaAssistantLibrary.read(command, in: context, dialogue: dialogue))
        XCTAssertTrue(first.contains("Total: 3"))
        XCTAssertFalse(first.contains("B:"))
        record.count = 5
        let second = try XCTUnwrap(ChekinanaAssistantLibrary.read(command, in: context, dialogue: dialogue))
        XCTAssertTrue(second.contains("Total: 6"))
        XCTAssertThrowsError(try ChekinanaAssistantLibrary.read(.init(name: "statscheki", target: nil, arguments: ["date_from": "2026-09-01"]), in: context, dialogue: dialogue))
        XCTAssertThrowsError(try ChekinanaAssistantLibrary.read(.init(name: "statscheki", target: nil, arguments: ["unknown_filter": "A"]), in: context, dialogue: dialogue))
    }

    func testNewLibraryListingOwnsNumbersEvenWhileCataloguePending() async throws {
        let context = ModelContext(AssistantHostContainer(idols: [Idol(name: "A"), Idol(name: "B")]))
        let dialogue = ChekinanaAssistantDialogue()
        dialogue.choiceSource = .catalogue
        _ = try ChekinanaAssistantLibrary.read(.init(name: "listidol", target: nil, arguments: [:]), in: context, dialogue: dialogue)
        XCTAssertEqual(ChekinanaAssistantChoicePolicy.route(1, source: dialogue.choiceSource, libraryCount: dialogue.choices.count, catalogueCount: 4, clarificationCount: 0), .library)
    }
#endif
}

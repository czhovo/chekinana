import SwiftData
import XCTest
@testable import Chekinana

@MainActor
final class ChekinanaConversationCoordinatorTests: XCTestCase {
    func testGreetingIsHandledLocallyWithoutSwallowingARequestedAction() {
        XCTAssertEqual(
            ChekinanaGreetingLanguage.response(for: "你好，Chekinana！"),
            ChekinanaGreetingLanguage.response
        )
        XCTAssertEqual(
            ChekinanaGreetingLanguage.response(for: "Hi!"),
            ChekinanaGreetingLanguage.response
        )
        XCTAssertNil(ChekinanaGreetingLanguage.response(for: "你好，请添加偶像 Alice"))
    }

    private struct Fixture {
        let context: ModelContext
        let ledger: ChekinanaConfirmationLedger
        let executor: ChekinanaCommandExecutor
    }

    func testPromptSubmissionPolicyOnlyAcceptsFocusedSingleTrailingNewline() {
        XCTAssertTrue(ChekinanaPromptSubmissionPolicy.shouldSubmitTrailingNewline(
            oldValue: "listidol",
            newValue: "listidol\n",
            isFocused: true,
            isSubmitting: false
        ))

        let rejectedInputs: [(oldValue: String, newValue: String, isFocused: Bool, isSubmitting: Bool)] = [
            ("", "\n", true, false),
            ("   ", "   \n", true, false),
            ("listidol", "listidol\n", false, false),
            ("listidol", "listidol\n", true, true),
            ("", "listidol\n", true, false),
            ("listidol", "listidol\n\n", true, false),
            ("listidol", "list\nidol", true, false),
            ("", "listidol", false, false),
        ]

        for input in rejectedInputs {
            XCTAssertFalse(ChekinanaPromptSubmissionPolicy.shouldSubmitTrailingNewline(
                oldValue: input.oldValue,
                newValue: input.newValue,
                isFocused: input.isFocused,
                isSubmitting: input.isSubmitting
            ))
        }
    }

    func testPromptRoutingKeepsOnlyLocalStateControlsOffNetwork() {
        for input in ["确认上一步", "confirm deadbeef", "取消全部操作", "清空聊天记录"] {
            XCTAssertNotNil(ChekinanaPromptRouting.localStateCommand(from: input), input)
        }
        for input in [
            "你好",
            "列出所有偶像",
            "添加活动 Summer Live 2026-08-01",
            "查看这张切",
            "扫描这些切",
            "https://weibo.com/123456/AbC123",
            "创建 Event https://weibo.com/123456/AbC123",
            "listidol",
        ] {
            XCTAssertNil(ChekinanaPromptRouting.localStateCommand(from: input), input)
        }
    }

    func testPromptRoutingAllowsOnlyExactBareScannerCommandLocally() {
        for input in ["scancheki", "  SCANCHEKI\n"] {
            XCTAssertEqual(
                ChekinanaPromptRouting.localBareScannerCommand(from: input),
                "scancheki",
                input
            )
        }
        for input in [
            "scancheki pod=fakevalue",
            "scancheki expected=2",
            "scancheki extra",
            "ſcancheki",
            "ｓｃａｎｃｈｅｋｉ",
            "scan cheki",
            "扫描这些切",
            "listidol",
        ] {
            XCTAssertNil(ChekinanaPromptRouting.localBareScannerCommand(from: input), input)
        }
    }

    func testQuickActionsPrefillOnlyEmptyPromptAndUseProductLabels() throws {
        XCTAssertEqual(
            ChekinanaQuickActions.all.map(\.label),
            ["添加 Idol", "微博建 Event", "扫描照片", "查看 Cheki"]
        )
        XCTAssertEqual(Set(ChekinanaQuickActions.all.map(\.id)).count, 4)
        XCTAssertEqual(
            ChekinanaQuickActions.all.map {
                $0.suggestedPrompt(hasSelectedPhotos: false)
            },
            [
                "添加 Idol ",
                "根据这条公开微博创建 Event：",
                "请先选择照片，再扫描这些照片",
                "查看所有 Cheki",
            ]
        )

        for action in ChekinanaQuickActions.all {
            XCTAssertTrue(ChekinanaQuickActions.shouldApply(to: "   \n"))
            XCTAssertFalse(ChekinanaQuickActions.shouldApply(to: "保留我的输入"))
            let prefilled = ChekinanaQuickActions.prefilledPrompt(
                currentPrompt: "   ",
                action: action,
                hasSelectedPhotos: false
            )
            XCTAssertFalse(prefilled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(
                ChekinanaQuickActions.prefilledPrompt(
                    currentPrompt: "保留我的输入",
                    action: action,
                    hasSelectedPhotos: false
                ),
                "保留我的输入"
            )
        }

        let scan = try XCTUnwrap(ChekinanaQuickActions.all.first { $0.kind == .scanPhotos })
        XCTAssertEqual(scan.suggestedPrompt(hasSelectedPhotos: false), "请先选择照片，再扫描这些照片")
        XCTAssertEqual(scan.suggestedPrompt(hasSelectedPhotos: true), "扫描已选择的照片")
    }

    func testIdolCardPresentationUsesExactlyFourStateSpecificInformationLines() {
        func card(
            detail: ChekinanaIdolCardDetail,
            verification: String? = "verified",
            confirmationCode: String? = nil,
            selectionToken: String? = nil
        ) -> ChekinanaIdolCard {
            ChekinanaIdolCard(
                id: UUID(),
                catalogueID: "catalogue-hidden",
                name: "Aina",
                group: "空色轨迹",
                color: nil,
                birthday: "2000-01-01",
                verification: verification,
                bio: "bio-hidden",
                avatarImageRef: nil,
                detail: detail,
                confirmationCode: confirmationCode,
                selectionToken: selectionToken
            )
        }

        let multiCandidate = ChekinanaIdolCardPresentation(idol: card(
            detail: .addCandidate,
            selectionToken: "candidate-token"
        ))
        let singleCandidate = ChekinanaIdolCardPresentation(idol: card(
            detail: .addCandidate,
            confirmationCode: "deadbeef"
        ))
        XCTAssertEqual(multiCandidate.lines, [
            "Aina", "空色轨迹", "Birthday: 2000-01-01", "Verification: verified",
        ])
        XCTAssertEqual(singleCandidate.lines, multiCandidate.lines)
        XCTAssertEqual(multiCandidate.fourthLineKind, .verification)

        let saved = ChekinanaIdolCardPresentation(idol: card(detail: .chekiCount(2)))
        XCTAssertEqual(saved.lines, [
            "Aina", "空色轨迹", "Birthday: 2000-01-01", "2 chekis",
        ])
        XCTAssertEqual(saved.fourthLineKind, .chekiCount)

        let pendingDelete = ChekinanaIdolCardPresentation(idol: card(detail: .deleteCandidate))
        XCTAssertEqual(pendingDelete.lines.count, 4)
        XCTAssertEqual(pendingDelete.lines[3], "0 cheki")

        for presentation in [multiCandidate, singleCandidate, saved, pendingDelete] {
            XCTAssertEqual(presentation.lines.count, 4)
            let visibleText = presentation.lines.joined(separator: "\n")
            XCTAssertFalse(visibleText.contains("Catalogue"))
            XCTAssertFalse(visibleText.contains("Bio"))
            XCTAssertFalse(visibleText.contains("待确认"))
            XCTAssertFalse(visibleText.contains("已保存"))
        }
    }

    func testChekiPreviewPolicyPrefersSavedImageRefAndSupportsTemporaryFallback() {
        let embedded = Data([1, 2, 3, 4])
        let savedCard = ChekinanaChekiCard(
            id: UUID(),
            imageRef: "saved-cheki.jpg",
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: embedded
        )
        let saved = ChekinanaChekiPreviewSource(cheki: savedCard)
        XCTAssertEqual(saved.preferredKind, .imageRef)
        XCTAssertEqual(saved.imageRef, "saved-cheki.jpg")
        XCTAssertEqual(saved.embeddedThumbnailData, embedded)

        let temporaryCard = ChekinanaChekiCard(
            id: UUID(),
            imageRef: nil,
            createdAt: Date(),
            confirmationCode: "deadbeef",
            thumbnailImageData: embedded
        )
        let temporary = ChekinanaChekiPreviewSource(cheki: temporaryCard)
        XCTAssertEqual(temporary.preferredKind, .embeddedThumbnail)
        XCTAssertNil(temporary.imageRef)
        XCTAssertEqual(temporary.embeddedThumbnailData, embedded)

        let unavailableCard = ChekinanaChekiCard(
            id: UUID(),
            imageRef: nil,
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: nil
        )
        XCTAssertEqual(
            ChekinanaChekiPreviewSource(cheki: unavailableCard).preferredKind,
            .unavailable
        )

        var presentation = ChekinanaChekiPreviewPresentationState()
        XCTAssertFalse(presentation.isPresented)
        presentation.open()
        XCTAssertTrue(presentation.isPresented)
        presentation.close()
        XCTAssertFalse(presentation.isPresented)
    }

    func testTranscriptEmptyStatePolicyIsNonPersistentAndExclusive() {
        XCTAssertTrue(ChekinanaTranscriptEmptyStatePolicy.shouldShow(
            messageCount: 0,
            hasDraft: false,
            hasEventCandidatePanel: false
        ))
        XCTAssertFalse(ChekinanaTranscriptEmptyStatePolicy.shouldShow(
            messageCount: 1,
            hasDraft: false,
            hasEventCandidatePanel: false
        ))
        XCTAssertFalse(ChekinanaTranscriptEmptyStatePolicy.shouldShow(
            messageCount: 0,
            hasDraft: true,
            hasEventCandidatePanel: false
        ))
        XCTAssertFalse(ChekinanaTranscriptEmptyStatePolicy.shouldShow(
            messageCount: 0,
            hasDraft: false,
            hasEventCandidatePanel: true
        ))
    }

    func testTypedScannerCommandInjectsOnlyValidatedLocalConfiguration() {
        let configuredValue = "scanner-test-123"
        XCTAssertEqual(
            ChekinanaScannerConfiguration.configuredPodID(infoDictionary: [
                ChekinanaScannerConfiguration.infoDictionaryKey: "  \(configuredValue)  ",
            ]),
            configuredValue
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["listidol", "scancheki"],
                configuredPodID: configuredValue
            ),
            .ready(["listidol", "scancheki pod=\(configuredValue)"])
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["scancheki pod=model-supplied"],
                configuredPodID: configuredValue
            ),
            .rejected(.invalidScannerPlan)
        )
    }

    func testMissingOrMalformedScannerConfigurationRejectsBeforeExecutionWithoutDisclosure() {
        for value in [nil, "", "$(UNRESOLVED)", "contains spaces", "short"] as [String?] {
            XCTAssertEqual(
                ChekinanaScannerConfiguration.prepareTypedCommands(
                    ["scancheki"],
                    configuredPodID: value
                ),
                .rejected(.scannerNotConfigured)
            )
        }
        let message = ChekinanaTypedCommandPreparationFailure.scannerNotConfigured.userMessage
        XCTAssertTrue(message.contains("未读取照片"))
        XCTAssertTrue(message.contains("未发起扫描请求"))
        XCTAssertFalse(message.contains("scanner-test-123"))
    }

    func testEverySupportedTypedIntentCompilesOnlyToWhitelistedCommands() throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "A")
        let event = Event(name: "E")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        try fixture.context.save()

        let cases: [(ChekinanaNLOperation, String)] = [
            (.init(intent: .addidol, slots: .init(name: "New Idol")), "addidol \"New Idol\""),
            (.init(intent: .addevent, slots: .init(name: "New Event", url: "https://example.com/live", date: "2026-07-16")), "addevent https://example.com/live name=\"New Event\" date=2026-07-16"),
            (.init(intent: .listidol), "listidol"),
            (.init(intent: .listevent), "listevent"),
            (.init(intent: .scancheki), "scancheki"),
            (.init(intent: .addcheki, slots: .init(date: "2026-07-16", idols: ["A"])), "addcheki idols=\(shortID(idol.id)) date=2026-07-16"),
            (.init(intent: .addscancheki, slots: .init(idols: ["A"], event: "E", temporary: "all")), "addscancheki all idols=\(shortID(idol.id)) event=\(shortID(event.id))"),
            (.init(intent: .listcheki, slots: .init(idol: "A")), "listcheki idol=\(shortID(idol.id))"),
            (.init(intent: .showidol, slots: .init(target: "A")), "showidol \(shortID(idol.id))"),
            (.init(intent: .showevent, slots: .init(target: "E")), "showevent \(shortID(event.id))"),
            (.init(intent: .showcheki, slots: .init(target: "deadbeef")), "showcheki deadbeef"),
        ]
        XCTAssertEqual(cases.count, ChekinanaNLIntent.allCases.count)
        for (operation, expected) in cases {
            XCTAssertEqual(
                ChekinanaConversationCoordinator.compile([operation], modelContext: fixture.context),
                .commands([expected]),
                operation.intent.rawValue
            )
        }
    }

    func testTypedScannerPlanReachesLocalConfigurationPreparation() throws {
        let fixture = try makeFixture()
        let configuredValue = "scanner-review-123"
        let compiled = ChekinanaConversationCoordinator.compile(
            [.init(intent: .scancheki)],
            modelContext: fixture.context
        )
        guard case .commands(let commands) = compiled else {
            return XCTFail("validated typed scan should compile to a bare local command")
        }
        XCTAssertEqual(commands, ["scancheki"])
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                commands,
                configuredPodID: configuredValue
            ),
            .ready(["scancheki pod=\(configuredValue)"])
        )
    }

    func testTypedWeiboEventRoutesToExtractorAndRejectsInvalidWeiboShape() throws {
        let fixture = try makeFixture()
        let url = "https://weibo.com/123456/AbC123"
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                .clarify(
                    draft: .init(intent: .addevent, slots: .init(url: url)),
                    missing: [.eventName, .date]
                ),
                modelContext: fixture.context
            ),
            .eventCandidateURL(url)
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                [.init(intent: .addevent, slots: .init(name: "Ignored", url: url, date: "2026-07-16"))],
                modelContext: fixture.context
            ),
            .eventCandidateURL(url)
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                [.init(intent: .addevent, slots: .init(name: "Unsafe", url: url + "?x=1", date: "2026-07-16"))],
                modelContext: fixture.context
            ),
            .message(.invalidPlan)
        )
    }

    func testTypedSelectedChekiReferenceUsesOnlyLocalSelectionAfterLLM() throws {
        let fixture = try makeFixture()
        let cheki = Cheki(note: "selected")
        fixture.context.insert(cheki)
        try fixture.context.save()
        var selections = ChekinanaConversationSelections()
        selections.selectedChekiID = cheki.id

        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                [.init(intent: .showcheki, slots: .init(target: "这张切"))],
                selections: selections,
                modelContext: fixture.context
            ),
            .commands(["showcheki \(shortID(cheki.id))"])
        )
    }

    func testDraftSelectionsCannotLeakAcrossIntentOrConflictingSlots() throws {
        let fixture = try makeFixture()
        let idolA = Idol(name: "A")
        let idolB = Idol(name: "B")
        fixture.context.insert(idolA)
        fixture.context.insert(idolB)
        try fixture.context.save()
        var selections = ChekinanaConversationSelections()
        selections.selectedIdolIDs = [idolA.id]

        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                .plan([.init(intent: .showidol, slots: .init(target: "A"))]),
                continuingIntent: .addcheki,
                selections: selections,
                modelContext: fixture.context
            ),
            .message(.invalidPlan)
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                .plan([.init(
                    intent: .addcheki,
                    slots: .init(date: "2026-07-16", idols: ["B"])
                )]),
                continuingIntent: .addcheki,
                selections: selections,
                modelContext: fixture.context
            ),
            .message(.invalidPlan)
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                .plan([.init(
                    intent: .addcheki,
                    slots: .init(date: "2026-07-16", idols: ["A"])
                )]),
                continuingIntent: .addcheki,
                selections: selections,
                modelContext: fixture.context
            ),
            .commands(["addcheki idols=\(shortID(idolA.id)) date=2026-07-16"])
        )
    }

    func testSelectedChekiLanguageRewritesOnlyExplicitLocalReference() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let cases = [
            ("查看这张切", "查看Cheki \(id.uuidString.lowercased())"),
            ("把这张切的备注改成 after live", "把Cheki \(id.uuidString.lowercased())的备注改成 after live"),
            ("删除刚才那张 Cheki", "删除Cheki \(id.uuidString.lowercased())"),
        ]

        for (input, expected) in cases {
            XCTAssertTrue(ChekinanaSelectedChekiLanguage.referencesSelectedCheki(input))
            XCTAssertEqual(
                ChekinanaSelectedChekiLanguage.rewrittenUtterance(input, selectedChekiID: id),
                expected
            )
        }

        XCTAssertFalse(ChekinanaSelectedChekiLanguage.referencesSelectedCheki("显示所有切"))
        XCTAssertNil(ChekinanaSelectedChekiLanguage.rewrittenUtterance(
            "显示所有切",
            selectedChekiID: id
        ))
    }

    func testNaturalScanPhrasesWithoutPodAskLocallyForPod() {
        for input in ["扫描这些切", "帮我记录这些切"] {
            let translation = ChekinanaNaturalLanguageTranslator.translate(input)
            XCTAssertNil(translation.command, input)
            XCTAssertEqual(translation.disposition, .localClarification, input)
            XCTAssertTrue(translation.needsClarification, input)
            XCTAssertTrue(translation.message.contains("Pod"), input)
        }
    }

    func testNaturalPodScanPhrasesCompileLocallyWithoutRemoteInterpretation() {
        for (input, podID) in [
            ("使用 Pod testpod123 扫描这些切", "testpod123"),
            ("用 Pod abcdefghi 扫描这些切", "abcdefghi"),
        ] {
            let translation = ChekinanaNaturalLanguageTranslator.translate(input)
            XCTAssertEqual(translation.command, "scancheki pod=\(podID)", input)
            XCTAssertEqual(translation.source, .rule, input)
            XCTAssertEqual(translation.disposition, .localCommand, input)
            XCTAssertFalse(translation.needsClarification, input)
            XCTAssertFalse(ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(input), input)
        }
    }

    func testMultiAddIdolPlanCompilesToCanonicalCommands() throws {
        let fixture = try makeFixture()
        let operations = [
            ChekinanaNLOperation(intent: .addidol, slots: .init(name: "A")),
            ChekinanaNLOperation(intent: .addidol, slots: .init(name: "B Idol")),
        ]
        guard case .commands(let commands) = ChekinanaConversationCoordinator.compile(
            operations,
            modelContext: fixture.context
        ) else {
            return XCTFail("expected commands")
        }
        XCTAssertEqual(commands, ["addidol A", "addidol \"B Idol\""])
    }

    func testEventResolutionIsExactFirstThenAmbiguousOrNotFound() throws {
        let fixture = try makeFixture()
        let exact = Event(name: "Live")
        let longer = Event(name: "Live Night")
        let nightA = Event(name: "Night A")
        let nightB = Event(name: "Night B")
        [exact, longer, nightA, nightB].forEach(fixture.context.insert)
        try fixture.context.save()

        let exactOperation = ChekinanaNLOperation(
            intent: .showevent,
            slots: .init(target: "Live")
        )
        guard case .commands(let exactCommands) = ChekinanaConversationCoordinator.compile(
            [exactOperation],
            modelContext: fixture.context
        ) else {
            return XCTFail("expected exact command")
        }
        XCTAssertEqual(exactCommands, ["showevent \(shortID(exact.id))"])

        let ambiguousOperation = ChekinanaNLOperation(
            intent: .showevent,
            slots: .init(target: "Night")
        )
        guard case .clarification(let ambiguous) = ChekinanaConversationCoordinator.compile(
            [ambiguousOperation],
            modelContext: fixture.context
        ) else {
            return XCTFail("expected candidates")
        }
        XCTAssertEqual(ambiguous.localChoice?.options.count, 3)

        let missing = ChekinanaNLOperation(
            intent: .showevent,
            slots: .init(target: "不存在")
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile([missing], modelContext: fixture.context),
            .message(.eventNotFound)
        )
    }

    func testMultipleIdolsAndEventCompileWithoutDroppingCombination() throws {
        let fixture = try makeFixture()
        let idolA = Idol(name: "Alice")
        let idolB = Idol(name: "Bob")
        let event = Event(name: "Live")
        [idolA, idolB].forEach(fixture.context.insert)
        fixture.context.insert(event)
        try fixture.context.save()

        let operation = ChekinanaNLOperation(
            intent: .addcheki,
            slots: .init(idols: ["Ali", "Bob"], event: "Live", note: "双人切")
        )
        guard case .commands(let commands) = ChekinanaConversationCoordinator.compile(
            [operation],
            modelContext: fixture.context
        ) else {
            return XCTFail("expected command")
        }
        XCTAssertEqual(
            commands,
            ["addcheki idols=\(shortID(idolA.id)),\(shortID(idolB.id)) event=\(shortID(event.id)) note=双人切"]
        )
    }

    func testEventDateConflictAndMixedIntentPlansAreRejected() throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "A")
        let event = Event(name: "E")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        try fixture.context.save()

        let conflict = ChekinanaNLOperation(
            intent: .addcheki,
            slots: .init(date: "2026-07-16", idols: ["A"], event: "E")
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile([conflict], modelContext: fixture.context),
            .message(.invalidPlan)
        )

        let mixed = [
            ChekinanaNLOperation(intent: .addidol, slots: .init(name: "A")),
            ChekinanaNLOperation(intent: .addevent, slots: .init(name: "E", date: "2026-07-16")),
        ]
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(mixed, modelContext: fixture.context),
            .message(.invalidPlan)
        )
    }

    func testTemporaryAllAndClarificationSelectionsCompile() throws {
        let fixture = try makeFixture()
        let idolA = Idol(name: "A")
        let idolB = Idol(name: "B")
        fixture.context.insert(idolA)
        fixture.context.insert(idolB)
        try fixture.context.save()

        var state = ChekinanaConversationDraftState(
            operation: .init(
                intent: .addscancheki,
                slots: .init(note: "after live", temporary: "all")
            ),
            missing: [.idol, .eventOrDate]
        )
        state.selections.selectedIdolIDs = [idolA.id, idolB.id]
        state.selections.selectedDate = "2026-07-16"
        state.selections.usesAllTemporaryChekis = true
        state.missing = []

        guard case .commands(let commands) = ChekinanaConversationCoordinator.resume(
            state,
            modelContext: fixture.context
        ) else {
            return XCTFail("expected command")
        }
        XCTAssertEqual(
            commands,
            ["addscancheki all idols=\(shortID(idolA.id)),\(shortID(idolB.id)) date=2026-07-16 note=\"after live\""]
        )
    }

    func testLocalAmbiguityChoiceCanResume() throws {
        let fixture = try makeFixture()
        let eventA = Event(name: "Tour Tokyo")
        let eventB = Event(name: "Tour Osaka")
        fixture.context.insert(eventA)
        fixture.context.insert(eventB)
        try fixture.context.save()
        let operation = ChekinanaNLOperation(intent: .showevent, slots: .init(target: "Tour"))

        guard case .clarification(var draft) = ChekinanaConversationCoordinator.compile(
            [operation],
            modelContext: fixture.context
        ) else {
            return XCTFail("expected clarification")
        }
        draft.selections.eventOverrides["Tour"] = eventB.id
        draft.localChoice = nil
        guard case .commands(let commands) = ChekinanaConversationCoordinator.resume(
            draft,
            modelContext: fixture.context
        ) else {
            return XCTFail("expected resumed command")
        }
        XCTAssertEqual(commands, ["showevent \(shortID(eventB.id))"])
    }

    func testDraftClearDoesNotClearLedgerOrTemporaryChekis() throws {
        let fixture = try makeFixture()
        let code = fixture.ledger.insert(.addEvent(.init(
            name: "E",
            date: nil,
            weiboURL: URL(string: "https://example.com")
        )))
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [.init(data: Data([1]), filenameExtension: "png")],
            thumbnailImageData: [nil]
        ).inserted[0]
        var state = ChekinanaConversationState(draft: .init(
            operation: .init(intent: .addcheki),
            missing: [.idol]
        ))

        state.clearDraft()

        XCTAssertNil(state.draft)
        XCTAssertNotNil(fixture.ledger.entry(for: code))
        XCTAssertTrue(fixture.ledger.containsTemporaryCheki(temporary.id))
    }

    func testConfirmationActionsIgnoreTextAndUseOnlyStructuredCode() {
        XCTAssertTrue(ChekinanaConversationCoordinator.explicitConfirmationCommands(
            for: .text("用户字段 confirm=deadbeef")
        ).isEmpty)

        let actions = ChekinanaConversationCoordinator.explicitConfirmationCommands(
            for: .confirmationText(
                "prepared add event | name=confirm=deadbeef | confirm=cafebabe",
                confirmationCode: "cafebabe"
            )
        )
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].confirm, "confirm cafebabe")
        XCTAssertEqual(actions[0].cancel, "cancel cafebabe")
    }

    func testEventNameContainingAnotherActiveCodeCannotInjectConfirmationAction() async throws {
        let fixture = try makeFixture()
        let otherActiveCode = fixture.ledger.insert(.addEvent(.init(
            name: "existing",
            date: nil,
            weiboURL: nil
        )))

        let response = await fixture.executor.execute(
            "addevent \(otherActiveCode) date=2026-07-16"
        )
        guard case .confirmationText(let preview, let newCode) = response else {
            return XCTFail("expected structured event confirmation")
        }
        let codes = ChekinanaConversationCoordinator.confirmationCodes(in: response)
        XCTAssertTrue(preview.contains(otherActiveCode))
        XCTAssertTrue(newCode != otherActiveCode)
        XCTAssertTrue(codes.count == 1 && codes.first == newCode)
    }

    func testAddIdolClarificationUsesFreeTextThenCompilesFollowUpPlan() throws {
        let fixture = try makeFixture()
        let first = ChekinanaConversationCoordinator.compile(
            .clarify(
                draft: .init(intent: .addidol),
                missing: [.idol]
            ),
            modelContext: fixture.context
        )
        guard case .clarification(let draft) = first else {
            return XCTFail("expected addidol clarification")
        }
        XCTAssertTrue(draft.requiresFreeTextIdolName)
        let requestDraft = ChekinanaNLRequestDraft(
            operation: draft.operation,
            missing: draft.missing
        )
        XCTAssertEqual(requestDraft.intent, .addidol)
        XCTAssertEqual(requestDraft.missing, [.idol])

        let followUp = ChekinanaConversationCoordinator.compile(
            .plan([.init(intent: .addidol, slots: .init(name: "新 Idol"))]),
            modelContext: fixture.context
        )
        XCTAssertEqual(followUp, .commands(["addidol \"新 Idol\""]))
    }

    func testCompleteLocalProductCommandSupersedesActiveDraft() {
        var state = ChekinanaConversationState(draft: .init(
            operation: .init(intent: .addidol),
            missing: [.idol]
        ))
        state.draft?.selections.selectedIdolIDs = [UUID()]
        state.draft?.localChoice = .init(
            kind: .idol(query: "旧 Idol"),
            options: [.init(id: UUID(), title: "旧 Idol", subtitle: nil)]
        )
        let translation = ChekinanaNaturalLanguageTranslator.translate("添加 Idol 新 Idol")

        XCTAssertEqual(translation.intent, "addidol")
        XCTAssertEqual(translation.command, "addidol \"新 Idol\"")
        XCTAssertTrue(ChekinanaConversationArbitration.applyLocalCommand(translation, to: &state))
        XCTAssertNil(state.draft)

        state.draft = .init(operation: .init(intent: .addidol), missing: [.idol])
        let differentProductCommand = ChekinanaNaturalLanguageTranslator.translate("listidol")
        XCTAssertTrue(ChekinanaConversationArbitration.applyLocalCommand(differentProductCommand, to: &state))
        XCTAssertNil(state.draft)

        for command in [
            "editidol target name=new",
            "deleteevent target",
            "downloadcheki deadbeef",
            "discardcheki all",
        ] {
            state.draft = .init(operation: .init(intent: .addidol), missing: [.idol])
            let translation = ChekinanaNaturalLanguageTranslator.translate(command)
            XCTAssertTrue(ChekinanaConversationArbitration.applyLocalCommand(translation, to: &state), command)
            XCTAssertNil(state.draft, command)
        }
    }

    func testOfflineTranslatorCoversEventAndChekiCRUDAndMultiIdolAdd() {
        let expectations: [(String, [String])] = [
            (
                "添加 Event https://example.com/live 名称 Cheki Demo 日期 2026-07-11",
                ["addevent https://example.com/live name=\"Cheki Demo\" date=2026-07-11"]
            ),
            ("添加 Event Summer Live 2026-08-01", ["addevent \"Summer Live\" date=2026-08-01"]),
            ("列出 Event", ["listevent"]),
            ("查看 Event Summer Live", ["showevent \"Summer Live\""]),
            ("把 Event Summer Live 的日期改为 2026-08-02", ["editevent \"Summer Live\" date=2026-08-02"]),
            ("删除 Event Summer Live", ["deleteevent \"Summer Live\""]),
            ("查看 Cheki deadbeef", ["showcheki deadbeef"]),
            ("把 Cheki deadbeef 的备注改为 很开心", ["editcheki deadbeef note=很开心"]),
            ("删除 Cheki deadbeef", ["deletecheki deadbeef"]),
            ("添加 Idol Alice、Bob Idol", ["addidol Alice", "addidol \"Bob Idol\""]),
            ("给 Alice、Bob 从相册添加 Cheki date=2026-08-01", ["addcheki Alice,Bob date=2026-08-01"]),
        ]
        for (input, commands) in expectations {
            let translation = ChekinanaNaturalLanguageTranslator.translate(input)
            XCTAssertEqual(translation.commands, commands, "\(input): \(translation.message)")
            XCTAssertEqual(translation.disposition, .localCommand, "\(input): \(translation.message)")
        }

        let missingEventDate = ChekinanaNaturalLanguageTranslator.translate("添加 Event Summer Live")
        XCTAssertEqual(missingEventDate.disposition, .localClarification)
        XCTAssertTrue(missingEventDate.message.contains("日期"))

        let urlOnly = ChekinanaNaturalLanguageTranslator.translate("添加 Event https://example.com/live")
        XCTAssertNil(urlOnly.command)
        XCTAssertEqual(urlOnly.disposition, .localClarification)
        XCTAssertTrue(urlOnly.message.contains("名称"))
        XCTAssertTrue(urlOnly.message.contains("日期"))

        let unknown = ChekinanaNaturalLanguageTranslator.translate("今天心情怎么样")
        XCTAssertEqual(unknown.disposition, .remoteFallback)
    }

    func testLocalEventURLDraftPreservesURLAndCompletesNameThenDate() throws {
        let fixture = try makeFixture()
        let url = "https://example.com/live"
        let parsed = try XCTUnwrap(ChekinanaLocalEventLanguage.draft(
            from: "添加 Event \(url)"
        ))
        XCTAssertEqual(parsed.operation.slots.url, url)
        XCTAssertNil(parsed.operation.slots.name)
        XCTAssertNil(parsed.operation.slots.date)
        XCTAssertEqual(parsed.missing, [.eventName, .date])

        let withName = try XCTUnwrap(ChekinanaLocalEventLanguage.draft(
            from: "添加 Event \(url) 名称 Cheki Demo"
        ))
        XCTAssertEqual(withName.operation.slots.name, "Cheki Demo")
        XCTAssertEqual(withName.missing, [.date])

        let withDate = try XCTUnwrap(ChekinanaLocalEventLanguage.draft(
            from: "添加 Event \(url) 日期 2026-07-11"
        ))
        XCTAssertEqual(withDate.operation.slots.date, "2026-07-11")
        XCTAssertEqual(withDate.missing, [.eventName])

        var state = ChekinanaConversationDraftState(
            operation: parsed.operation,
            missing: parsed.missing
        )
        state.operation.slots.name = "Cheki Demo"
        state.removeMissing(.eventName)
        guard case .clarification(let afterName) = ChekinanaConversationCoordinator.resume(
            state,
            modelContext: fixture.context
        ) else {
            return XCTFail("date should still be required")
        }
        XCTAssertEqual(afterName.operation.slots.url, url)
        XCTAssertEqual(afterName.operation.slots.name, "Cheki Demo")
        XCTAssertEqual(afterName.missing, [.date])

        var complete = afterName
        complete.operation.slots.date = "2026-07-11"
        complete.removeMissing(.date)
        guard case .commands(let commands) = ChekinanaConversationCoordinator.resume(
            complete,
            modelContext: fixture.context
        ) else {
            return XCTFail("expected complete Event command")
        }
        XCTAssertEqual(
            commands,
            ["addevent https://example.com/live name=\"Cheki Demo\" date=2026-07-11"]
        )

        let allAtOnce = try XCTUnwrap(ChekinanaLocalEventLanguage.draft(
            from: "添加 Event \(url) 名称 Cheki Demo 日期 2026-07-11"
        ))
        XCTAssertTrue(allAtOnce.missing.isEmpty)
    }

    func testUnmatchedProductKeywordLanguageUsesTypedRemoteFallback() {
        for input in [
            "帮我记录今天 A 的 cheki",
            "这个 Event 要和 Alice 的 Cheki 放一起",
        ] {
            let translation = ChekinanaNaturalLanguageTranslator.translate(input)
            XCTAssertNil(translation.command, input)
            XCTAssertFalse(translation.candidates.isEmpty, "test must exercise scored product keywords: \(input)")
            XCTAssertEqual(translation.disposition, .remoteFallback, input)
        }
    }

    func testExplicitMissingOrUnsafeSyntaxRemainsLocalClarification() {
        let inputs = [
            "addevent Summer Live",
            "addcheki",
            "添加 Event Summer Live",
            "从相册添加 Cheki",
            "下载 Cheki deadbeef 并删除 Cheki deadbeef",
            "listidol; deleteidol A",
            "添加 Idol A\\B",
        ]
        for input in inputs {
            let translation = ChekinanaNaturalLanguageTranslator.translate(input)
            XCTAssertNil(translation.command, input)
            XCTAssertEqual(translation.disposition, .localClarification, "\(input): \(translation.message)")
        }
    }

    func testCredentialedEventURLFailsClosedAndNeverAppearsInTranslation() {
        let input = "addevent https://user:password@example.com/live"
        XCTAssertTrue(ChekinanaNLPrivacyGuard.containsCredentialedHTTPURL(input))
        let translation = ChekinanaNaturalLanguageTranslator.translate(input)
        XCTAssertTrue(translation.needsClarification)
        XCTAssertNil(translation.command)
        XCTAssertFalse(translation.message.contains("password"))
    }

    func testClientErrorsMapToActionableDistinctMessages() {
        let cases: [(ChekinanaNLClientError, ChekinanaConversationMessage)] = [
            (.cannotFindHost, .cannotResolveHost),
            (.notConnectedToInternet, .offline),
            (.timedOut, .requestTimedOut),
            (.networkConnectionLost, .connectionLost),
            (.invalidHTTPStatus(401), .serviceNotDeployed),
            (.invalidHTTPStatus(404), .serviceNotDeployed),
            (.invalidHTTPStatus(429), .rateLimited),
            (.serviceRejected(code: "rate_limit_unavailable", status: 503), .rateLimitUnavailable),
            (.serviceRejected(code: "upstream_timeout", status: 503), .upstreamTimedOut),
            (.serviceRejected(code: "upstream_unavailable", status: 503), .upstreamUnavailable),
            (.serviceRejected(code: "invalid_model_output", status: 422), .invalidModelOutput),
            (.serviceRejected(code: "invalid_request", status: 400), .requestInvalid),
            (.serviceRejected(code: "rate_limited", status: 429), .rateLimited),
            (.serviceRejected(code: "service_unavailable", status: 503), .serviceUnavailable),
            (.invalidSchema, .invalidServiceResponse),
        ]
        for (error, message) in cases {
            XCTAssertEqual(ChekinanaConversationMessage.forClientError(error), message)
        }
    }

    func testLocalControlCommandDoesNotDiscardConversationDraft() {
        var state = ChekinanaConversationState(draft: .init(
            operation: .init(intent: .addidol),
            missing: [.idol]
        ))
        let confirmation = ChekinanaNaturalLanguageTranslator.translate("confirm deadbeef")

        XCTAssertFalse(ChekinanaConversationArbitration.applyLocalCommand(confirmation, to: &state))
        XCTAssertNotNil(state.draft)
    }

    func testCompiledCommandStillPreparesExecutorConfirmationWithoutWriting() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let idol = Idol(name: "A")
        let event = Event(name: "E")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        try fixture.context.save()
        _ = try fixture.ledger.insertTemporaryChekis(
            [.init(data: Data([1]), filenameExtension: "png")],
            thumbnailImageData: [nil]
        )
        let operation = ChekinanaNLOperation(
            intent: .addscancheki,
            slots: .init(idols: ["A"], event: "E", temporary: "all")
        )
        guard case .commands(let commands) = ChekinanaConversationCoordinator.compile(
            [operation],
            modelContext: fixture.context
        ) else {
            return XCTFail("expected command")
        }

        let response = await fixture.executor.execute(try XCTUnwrap(commands.first))

        guard case .pendingChekiCards(_, let cards, _) = response else {
            return XCTFail("expected pending confirmation")
        }
        XCTAssertEqual(cards.count, 1)
        XCTAssertNotNil(cards[0].confirmationCode)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    private func makeFixture() throws -> Fixture {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let ledger = ChekinanaConfirmationLedger()
        return Fixture(
            context: context,
            ledger: ledger,
            executor: ChekinanaCommandExecutor(modelContext: context, confirmationLedger: ledger)
        )
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private func cleanupManagedImages(in context: ModelContext) {
        guard let chekis = try? context.fetch(FetchDescriptor<Cheki>()) else { return }
        for cheki in chekis {
            guard let url = ChekiImageRefResolver.managedChekiFileURL(
                for: cheki.imageRef,
                chekiID: cheki.id
            ) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

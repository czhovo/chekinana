import SwiftData
import XCTest
@testable import Chekinana

@MainActor
final class ChekinanaConversationCoordinatorTests: XCTestCase {
    func testEventChoicesSubtitleUsesStoredDateOnlyValueInNegativeTimeZone() throws {
        let fixture = try makeFixture()
        let canonicalDate = try XCTUnwrap(
            ChekinanaDateOnly.canonicalDate(year: 2026, month: 8, day: 4)
        )
        fixture.context.insert(Event(name: "Night Live", date: canonicalDate))
        try fixture.context.save()

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        XCTAssertEqual(
            ChekinanaNLInterpretClient.localDateString(
                canonicalDate,
                calendar: losAngeles
            ),
            "2026-08-03",
            "A live instant formatter would shift the canonical carrier in this zone"
        )

        let choices = ChekinanaConversationCoordinator.eventChoices(
            modelContext: fixture.context
        )
        let choice = try XCTUnwrap(choices.first { $0.title == "Night Live" })
        XCTAssertEqual(choice.subtitle, "2026-08-04")
    }

    func testLongCandidateScrollPolicyKeepsResponseTopAndRestoreDoesNothing() {
        XCTAssertEqual(
            ChekinanaTranscriptScrollPolicy.behavior(
                for: .idolCandidates(count: 10),
                isRestoringHistory: false
            ),
            .responseTop
        )
        XCTAssertEqual(
            ChekinanaTranscriptScrollPolicy.behavior(
                for: .idolCandidates(count: 5),
                isRestoringHistory: false
            ),
            .bottom
        )
        XCTAssertEqual(
            ChekinanaTranscriptScrollPolicy.behavior(
                for: .userText,
                isRestoringHistory: true
            ),
            .none
        )
    }

    func testAssistantHistorySanitizesBothRolesAndExcludesRichInteractions() throws {
        let card = ChekinanaIdolCard(
            id: UUID(), catalogueID: nil, name: "Not persisted", group: nil,
            color: nil, birthday: nil, verification: nil, bio: nil,
            avatarImageRef: nil, avatarThumbnailData: nil, avatarIdentity: nil,
            detail: .addCandidate, confirmationCode: nil, selectionToken: "ephemeral"
        )
        let explicitSecrets = [
            "password=value",
            "passwd: value",
            "passcode：value",
            "api_key=value",
            "api-key: value",
            "apikey：value",
            "client_secret=value",
            "client-secret: value",
            "secret：value",
            "session=value",
            "session_id=value",
            "session-id: value",
            "sessionid：value",
            "session_key=value",
            "session-key: value",
            "sessiontoken=value",
            "private key: value",
            "private_key=value",
            "private-key: value",
        ]
        let explicitSecretMessages = explicitSecrets.enumerated().map { index, text in
            TranscriptMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: .text(text)
            )
        }
        let messages = [
            TranscriptMessage(role: .user, content: .text("ordinary user text")),
            TranscriptMessage(content: .text("ordinary assistant text")),
            TranscriptMessage(
                role: .user,
                content: .text("Please explain password managers and API key rotation.")
            ),
            TranscriptMessage(content: .text("Session key documentation is public.")),
            TranscriptMessage(
                role: .user,
                content: .text("Session IDs and session tokens are security concepts.")
            ),
            TranscriptMessage(
                content: .text("Private key rotation guidance contains no credential value.")
            ),
            TranscriptMessage(
                content: .text("error: invalid or expired confirmation code: deadbeef")
            ),
            TranscriptMessage(
                role: .user,
                content: .text("addevent https://user:password@example.com/live")
            ),
            TranscriptMessage(role: .user, content: .text("Authorization: secret-value")),
            TranscriptMessage(role: .user, content: .text("refresh_token=secret-value")),
            TranscriptMessage(content: .text("Bearer assistant-echoed-secret")),
            TranscriptMessage(
                role: .user,
                content: .text("object 00000000-0000-4000-8000-000000000000")
            ),
            TranscriptMessage(role: .user, content: .text("scancheki pod=secret123")),
            TranscriptMessage(content: .idolCards([card])),
        ] + explicitSecretMessages
        let records = ChekinanaAssistantHistoryStore.persistableRecords(from: messages)
        XCTAssertEqual(records.count, 7)
        XCTAssertEqual(
            records.map(\.text),
            [
                "ordinary user text",
                "ordinary assistant text",
                "Please explain password managers and API key rotation.",
                "Session key documentation is public.",
                "Session IDs and session tokens are security concepts.",
                "Private key rotation guidance contains no credential value.",
                "Idol：Not persisted",
            ]
        )
        XCTAssertFalse(records.contains {
            $0.text.contains("deadbeef")
                || $0.text.contains("secret")
                || $0.text.contains("00000000")
                || $0.text.contains("ephemeral")
        })
        for explicitSecret in explicitSecrets {
            XCTAssertFalse(records.contains { $0.text == explicitSecret }, explicitSecret)
        }
    }

    func testAssistantHistorySaveLoadBoundsAndAtomicallyReplacesFile() throws {
        let ordinaryRecords = (0...ChekinanaAssistantHistoryStore.maximumRecords).map {
            ChekinanaPersistedTranscriptRecord(role: .user, text: "ordinary \($0)")
        }
        let boundary = ChekinanaPersistedTranscriptRecord(
            role: .assistant,
            text: String(repeating: "x", count: ChekinanaAssistantHistoryStore.maximumTextCharacters + 1)
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        ChekinanaAssistantHistoryStore.save(
            [ChekinanaPersistedTranscriptRecord(role: .assistant, text: "stale")],
            to: url
        )
        ChekinanaAssistantHistoryStore.save(
            ordinaryRecords + [
                ChekinanaPersistedTranscriptRecord(role: .user, text: "api_key=direct-save-secret"),
                boundary,
            ],
            to: url
        )
        let restored = ChekinanaAssistantHistoryStore.load(from: url)
        XCTAssertEqual(restored.count, ChekinanaAssistantHistoryStore.maximumRecords)
        XCTAssertEqual(restored.first?.text, "ordinary 2")
        XCTAssertEqual(restored.last?.role, .assistant)
        XCTAssertEqual(restored.last?.text.count, ChekinanaAssistantHistoryStore.maximumTextCharacters)
        XCTAssertFalse(restored.contains { $0.text == "stale" })

        let onDisk = try JSONDecoder().decode(
            [ChekinanaPersistedTranscriptRecord].self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(onDisk, restored)
    }

    func testAssistantHistoryLoadFailsClosedForLegacySensitiveFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-history-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = [
            ChekinanaPersistedTranscriptRecord(role: .assistant, text: "ordinary"),
            ChekinanaPersistedTranscriptRecord(
                role: .assistant,
                text: "error: confirmation code expired: cafebabe"
            ),
        ]
        try JSONEncoder().encode(legacy).write(to: url)

        XCTAssertEqual(
            ChekinanaAssistantHistoryStore.load(from: url),
            [ChekinanaPersistedTranscriptRecord(role: .assistant, text: "ordinary")]
        )
        let scrubbedOnDisk = try JSONDecoder().decode(
            [ChekinanaPersistedTranscriptRecord].self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(
            scrubbedOnDisk,
            [ChekinanaPersistedTranscriptRecord(role: .assistant, text: "ordinary")]
        )

        let sensitiveOnlyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-history-sensitive-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: sensitiveOnlyURL) }
        try JSONEncoder().encode(Array(legacy.dropFirst())).write(to: sensitiveOnlyURL)
        XCTAssertTrue(ChekinanaAssistantHistoryStore.load(from: sensitiveOnlyURL).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sensitiveOnlyURL.path))
    }

    func testPatternCountLabelUsesCorrectPluralization() {
        XCTAssertEqual(ChekinanaPatternCountLabel.text(0), "No patterns")
        XCTAssertEqual(ChekinanaPatternCountLabel.text(0, whenEmpty: "No pattern"), "No pattern")
        XCTAssertEqual(ChekinanaPatternCountLabel.text(1), "1 pattern")
        XCTAssertEqual(ChekinanaPatternCountLabel.text(2), "2 patterns")
    }

    func testChekiCountLabelUsesLowercaseEnglishPluralization() throws {
        let bundle = try XCTUnwrap(
            Bundle(path: try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj")))
        )
        let locale = Locale(identifier: "en")
        XCTAssertEqual(
            ChekinanaRecordKind.cheki.countLabel(0, bundle: bundle, locale: locale),
            "0 chekis"
        )
        XCTAssertEqual(
            ChekinanaRecordKind.cheki.countLabel(1, bundle: bundle, locale: locale),
            "1 Cheki"
        )
        XCTAssertEqual(
            ChekinanaRecordKind.cheki.countLabel(2, bundle: bundle, locale: locale),
            "2 chekis"
        )
    }

    func testMiniChekiIconUsesPhysicalFrameAspectRatio() {
        XCTAssertEqual(
            ChekinanaMiniChekiIconMetrics.outerAspectRatio,
            CGFloat(1_200) / CGFloat(1_908),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            ChekinanaMiniChekiIconMetrics.width / ChekinanaMiniChekiIconMetrics.height,
            ChekinanaMiniChekiIconMetrics.outerAspectRatio,
            accuracy: 0.000_001
        )
    }

    func testIdolPatternStatusUsesOnlyStoredStateForZeroOneAndTwoPatterns() {
        let statuses = [0, 1, 2].map {
            ChekinanaIdolPatternStatus.make(hasRecognitionPatterns: $0 > 0)
        }
        XCTAssertEqual(statuses.map(\.systemImageName), [
            "circle.dashed", "checkmark.seal", "checkmark.seal",
        ])
        XCTAssertEqual(statuses.map(\.accessibilityValue), [
            "No stored pattern", "Stored pattern available", "Stored pattern available",
        ])
    }

    func testIdolDragPreviewMovesInRealTimeAndRejectsFavoriteBoundary() {
        let favorite = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let source = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let sameGroup = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let orderedIDs = [favorite, source, sameGroup]
        let favoriteByID = [favorite: true, source: false, sameGroup: false]
        XCTAssertEqual(
            ChekinanaIdolOrdering.previewMove(
                source,
                onto: sameGroup,
                in: orderedIDs,
                favoriteByID: favoriteByID
            ),
            [favorite, sameGroup, source]
        )
        XCTAssertEqual(
            ChekinanaIdolOrdering.previewMove(
                source,
                onto: favorite,
                in: orderedIDs,
                favoriteByID: favoriteByID
            ),
            orderedIDs
        )
    }

    func testIdolOrderingUsesFavoriteFirstLegacyFallbackAndProtectedGroupMoves() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let first = Idol(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "First", createdAt: base
        )
        let second = Idol(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Second", createdAt: base.addingTimeInterval(1)
        )
        let appended = Idol(name: "Appended", createdAt: base.addingTimeInterval(2))
        let favorite = Idol(name: "Favorite", isFavorite: true, createdAt: base.addingTimeInterval(3))
        let idols = [appended, second, favorite, first]

        XCTAssertEqual(
            ChekinanaIdolOrdering.ordered(idols).map(\.name),
            ["Favorite", "First", "Second", "Appended"]
        )
        XCTAssertFalse(ChekinanaIdolOrdering.move(first.id, before: favorite.id, in: idols))
        XCTAssertTrue(ChekinanaIdolOrdering.move(appended.id, offset: -1, in: idols))
        XCTAssertEqual(
            ChekinanaIdolOrdering.ordered(idols).filter { !$0.isFavorite }.map(\.name),
            ["First", "Appended", "Second"]
        )

        let preview = ChekinanaIdolOrdering.previewMove(
            second.id,
            onto: first.id,
            in: ChekinanaIdolOrdering.ordered(idols).map(\.id),
            favoriteByID: Dictionary(uniqueKeysWithValues: idols.map { ($0.id, $0.isFavorite) })
        )
        XCTAssertTrue(
            ChekinanaIdolOrdering.applyPreviewOrder(
                preview,
                favorite: false,
                in: idols
            )
        )
        XCTAssertEqual(
            ChekinanaIdolOrdering.ordered(idols).filter { !$0.isFavorite }.map(\.name),
            ["Second", "First", "Appended"]
        )

        ChekinanaIdolOrdering.toggleFavorite(second, in: idols)
        XCTAssertEqual(
            ChekinanaIdolOrdering.ordered(idols).map(\.name),
            ["Favorite", "Second", "First", "Appended"]
        )

        let fixture = try makeFixture()
        idols.forEach(fixture.context.insert)
        try fixture.context.save()
        let fetched = try fixture.context.fetch(FetchDescriptor<Idol>())
        XCTAssertEqual(
            ChekinanaIdolOrdering.ordered(fetched).map(\.name),
            ["Favorite", "Second", "First", "Appended"]
        )
        XCTAssertTrue(fetched.contains { $0.sortOrder != nil })
    }

    func testListAndDetailFavoriteEntrancesUseIdenticalTargetGroupAppendOrdering() throws {
        func toggledOrder() throws -> [String] {
            let fixture = try makeFixture()
            let favorite = Idol(
                name: "Existing Favorite",
                isFavorite: true,
                sortOrder: 0
            )
            let target = Idol(name: "Target", sortOrder: 0)
            let other = Idol(name: "Other", sortOrder: 1)
            [favorite, target, other].forEach(fixture.context.insert)
            try fixture.context.save()
            try ChekinanaIdolFavoriteAction.toggle(
                target,
                in: [favorite, target, other],
                modelContext: fixture.context,
                now: Date(timeIntervalSince1970: 123)
            )
            return ChekinanaIdolOrdering.ordered(
                try fixture.context.fetch(FetchDescriptor<Idol>())
            ).map(\.name)
        }

        let listEntranceOrder = try toggledOrder()
        let detailEntranceOrder = try toggledOrder()
        XCTAssertEqual(listEntranceOrder, ["Existing Favorite", "Target", "Other"])
        XCTAssertEqual(detailEntranceOrder, listEntranceOrder)
    }

    func testCandidateSelectionDefaultsOnceAndPreservesIntentionalEmptySelection() {
        let first = UUID()
        let second = UUID()
        let newlyEligible = UUID()
        var state = ChekinanaCandidateSelectionState()

        state.reconcile(validIDs: [first, second])
        XCTAssertEqual(state.selectedIDs, [first, second])

        state.selectedIDs.removeAll()
        state.reconcile(validIDs: [first, second])
        XCTAssertTrue(state.selectedIDs.isEmpty)

        state.selectedIDs = [first, UUID()]
        state.reconcile(validIDs: [first, second])
        XCTAssertEqual(state.selectedIDs, [first])

        state.reconcile(validIDs: [first, second, newlyEligible])
        XCTAssertEqual(state.selectedIDs, [first, newlyEligible])

        state.reconcile(validIDs: [second, newlyEligible])
        XCTAssertEqual(state.selectedIDs, [newlyEligible])
    }
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

    func testIdolCardPresentationUsesExactlyThreeStateSpecificInformationLines() {
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
                avatarThumbnailData: nil,
                avatarIdentity: nil,
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
            "Aina", "空色轨迹", "verified",
        ])
        XCTAssertEqual(singleCandidate.lines, multiCandidate.lines)
        XCTAssertEqual(multiCandidate.thirdLineKind, .verification)

        let bioFallback = ChekinanaIdolCardPresentation(idol: card(
            detail: .addCandidate,
            verification: " "
        ))
        XCTAssertEqual(bioFallback.lines, ["Aina", "空色轨迹", "bio-hidden"])
        XCTAssertEqual(bioFallback.thirdLineKind, .bio)

        let saved = ChekinanaIdolCardPresentation(idol: card(detail: .chekiCount(2)))
        XCTAssertEqual(saved.lines, [
            "Aina", "空色轨迹", "2 Cheki",
        ])
        XCTAssertEqual(saved.thirdLineKind, .chekiCount)

        let pendingDelete = ChekinanaIdolCardPresentation(idol: card(detail: .deleteCandidate))
        XCTAssertEqual(pendingDelete.lines.count, 3)
        XCTAssertEqual(pendingDelete.lines[2], "0 Cheki")

        for presentation in [multiCandidate, singleCandidate, bioFallback, saved, pendingDelete] {
            XCTAssertEqual(presentation.lines.count, 3)
            let visibleText = presentation.lines.joined(separator: "\n")
            XCTAssertFalse(visibleText.contains("Birthday"))
            XCTAssertFalse(visibleText.contains("Catalogue"))
            XCTAssertFalse(visibleText.contains("Bio"))
            XCTAssertFalse(visibleText.contains("待确认"))
            XCTAssertFalse(visibleText.contains("已保存"))
        }
    }

    func testChekiPreviewPolicyCarriesDateOverlayOnlyForTemporaryFallback() throws {
        let embedded = Data([1, 2, 3, 4])
        let boundingBox = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 100,
            y1: 200,
            x2: 400,
            y2: 300
        ))
        let annotation = try XCTUnwrap(ChekinanaChekiDateAnnotation(
            text: "2026.07.04",
            precision: .fullDate,
            boundingBox: boundingBox
        ))
        let savedCard = ChekinanaChekiCard(
            id: UUID(),
            imageRef: "saved-cheki.jpg",
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: embedded,
            idx: 1,
            dateAnnotationState: .detected(annotation)
        )
        let saved = ChekinanaChekiPreviewSource(cheki: savedCard)
        XCTAssertEqual(saved.preferredKind, .imageRef)
        XCTAssertEqual(saved.imageRef, "saved-cheki.jpg")
        XCTAssertEqual(saved.embeddedThumbnailData, embedded)
        XCTAssertNil(saved.transientDateAnnotation)

        let temporaryCard = ChekinanaChekiCard(
            id: UUID(),
            imageRef: nil,
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: embedded,
            dateAnnotationState: .detected(annotation)
        )
        let temporary = ChekinanaChekiPreviewSource(cheki: temporaryCard)
        XCTAssertEqual(temporary.preferredKind, .embeddedThumbnail)
        XCTAssertNil(temporary.imageRef)
        XCTAssertEqual(temporary.embeddedThumbnailData, embedded)
        XCTAssertEqual(temporary.transientDateAnnotation, annotation)
        let unavailableCard = ChekinanaChekiCard(
            id: UUID(),
            imageRef: nil,
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: nil
        )
        let unavailable = ChekinanaChekiPreviewSource(cheki: unavailableCard)
        XCTAssertEqual(unavailable.preferredKind, .unavailable)
        XCTAssertNil(unavailable.transientDateAnnotation)

        var presentation = ChekinanaChekiPreviewPresentationState()
        XCTAssertFalse(presentation.isPresented)
        presentation.open()
        XCTAssertTrue(presentation.isPresented)
        presentation.close()
        XCTAssertFalse(presentation.isPresented)
    }

    func testMinimumTouchTargetIsAtLeast44Points() {
        XCTAssertGreaterThanOrEqual(
            ChekinanaAccessibilityMetrics.minimumTouchTarget,
            44
        )
    }

    func testTypedScannerCommandUsesManagedProxyWithoutCredentialArguments() throws {
        let fixedBounds = try XCTUnwrap(
            ChekinanaScannerDateBounds.fixed(
                try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")),
                calendar: Calendar(identifier: .gregorian)
            )
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["listidol", "scancheki"]
            ),
            .ready(["listidol", "scancheki"])
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["listidol", "scancheki"],
                dateRecognitionEnabled: true,
                dateBounds: fixedBounds,
                idolRecognitionEnabled: true,
                idolCandidateIDs: [
                    UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                ]
            ),
            .ready([
                "listidol",
                "scancheki date_recognition=true date_scope=fixed date_from=2026-07-16 date_to=2026-07-16 idol_recognition=true candidates=11111111-1111-1111-1111-111111111111,unassigned",
            ])
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["scancheki"],
                dateRecognitionEnabled: true,
                dateBounds: fixedBounds
            ),
            .ready(["scancheki date_recognition=true date_scope=fixed date_from=2026-07-16 date_to=2026-07-16"])
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["scancheki"],
                directInputEnabled: true
            ),
            .ready(["scancheki direct=true scanner_size=mini"])
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["scancheki"],
                idolRecognitionEnabled: true,
                idolCandidateIDs: []
            ),
            .ready([
                "scancheki idol_recognition=true candidates=unassigned",
            ])
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["scancheki"],
                idolRecognitionEnabled: true,
                idolCandidateIDs: [
                    UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                ],
                includeUnassignedCandidate: false
            ),
            .ready([
                "scancheki idol_recognition=true candidates=22222222-2222-2222-2222-222222222222",
            ])
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["scancheki"],
                idolRecognitionEnabled: true,
                idolCandidateIDs: [],
                includeUnassignedCandidate: false
            ),
            .rejected(.invalidScannerPlan)
        )
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["scancheki pod=model-supplied"]
            ),
            .rejected(.invalidScannerPlan)
        )
    }

    func testScannerConfigurationIgnoresLocalOverridesAndClientTokens() throws {
        let productionURL = ChekinanaScannerConfiguration.productionBaseURL
        let overrides = [
            nil,
            "",
            "http://localhost:8787",
            "http://192.168.1.50:8787",
            "https://scanner.example.test",
            "not a URL",
        ] as [String?]
        for rawValue in overrides {
            XCTAssertEqual(
                ChekinanaScannerConfiguration.resolveBaseURL(
                    rawValue,
                    allowsInsecureLocalHTTP: true
                ),
                .resolved(productionURL)
            )
        }
        XCTAssertEqual(
            ChekinanaScannerConfiguration.configuredBaseURL(
                infoDictionary: [
                    ChekinanaScannerConfiguration.baseURLInfoDictionaryKey:
                        "http://192.168.1.50:8787",
                ],
                allowsInsecureLocalHTTP: true
            ),
            .resolved(productionURL)
        )
        XCTAssertFalse(ChekinanaScannerConfiguration.currentBuildAllowsInsecureLocalHTTP)
    }

    func testInvalidScannerBaseURLRejectsTypedScanBeforePhotoReadMessage() {
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(
                ["scancheki"],
                baseURLResolution: .invalid
            ),
            .rejected(.invalidScannerConfiguration)
        )
        let message =
            ChekinanaTypedCommandPreparationFailure.invalidScannerConfiguration.userMessage
        XCTAssertEqual(
            message,
            "扫描服务地址配置无效；未读取照片，也未发起扫描请求。"
        )
        XCTAssertFalse(message.contains("http"))
    }

    func testProductionScannerPreparationRequiresNoClientCredential() {
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(["scancheki"]),
            .ready(["scancheki"])
        )
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
            (.init(intent: .editidol, slots: .init(name: "Renamed", target: "A")), "editidol \(shortID(idol.id)) name=Renamed"),
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
        let compiled = ChekinanaConversationCoordinator.compile(
            [.init(intent: .scancheki)],
            modelContext: fixture.context
        )
        guard case .commands(let commands) = compiled else {
            return XCTFail("validated typed scan should compile to a bare local command")
        }
        XCTAssertEqual(commands, ["scancheki"])
        XCTAssertEqual(
            ChekinanaScannerConfiguration.prepareTypedCommands(commands),
            .ready(["scancheki"])
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

        let rawText = "添加 Event：8 月 3 日上海公演，场地 MAO Livehouse"
        let textResult = ChekinanaConversationCoordinator.compile(
            [.init(intent: .addevent, slots: .init(name: "上海公演", date: "2026-08-03"))],
            modelContext: fixture.context
        )
        XCTAssertEqual(textResult, .eventCandidateText)
        XCTAssertEqual(
            ChekinanaEventCandidateConversationRoute.resolve(
                textResult,
                originalUtterance: rawText
            ),
            .text(rawText),
            "An Add Event without a public Weibo URL must send the unmodified user utterance to the shared text parser."
        )
        XCTAssertEqual(
            ChekinanaEventCandidateConversationRoute.resolve(
                .eventCandidateURL(url),
                originalUtterance: rawText
            ),
            .weiboURL(url),
            "Conversation URL parsing must use the same Weibo candidate fetch route as Add Event."
        )
        XCTAssertNil(
            ChekinanaEventCandidateConversationRoute.resolve(
                .eventCandidateText,
                originalUtterance: "   "
            )
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                [
                    .init(intent: .addevent, slots: .init(url: url)),
                    .init(intent: .listevent),
                ],
                modelContext: fixture.context
            ),
            .message(.invalidPlan),
            "A conversation may add only one Event and may not mix it with other operations."
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
            ("edit the selected Cheki", "edit Cheki \(id.uuidString.lowercased())"),
            ("選択したチェキを編集", "Cheki \(id.uuidString.lowercased())を編集"),
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

    func testNaturalScanPhrasesCompileWithoutBackendIdentifiers() {
        for input in ["扫描这些切", "帮我记录这些切"] {
            let translation = ChekinanaNaturalLanguageTranslator.translate(input)
            XCTAssertEqual(translation.command, "scancheki", input)
            XCTAssertEqual(translation.source, .rule, input)
            XCTAssertEqual(translation.disposition, .localCommand, input)
            XCTAssertFalse(translation.needsClarification, input)
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

    func testPlanCardinalityAllowsTwentyFiveAddIdolsButRejectsSixAddEvents() throws {
        let addIdols = (1...25).map {
            ChekinanaNLOperation(intent: .addidol, slots: .init(name: "Idol \($0)"))
        }
        XCTAssertNoThrow(try ChekinanaNLSchemaValidator.validatePlan(addIdols))
        let fixture = try makeFixture()
        guard case .commands(let commands) = ChekinanaConversationCoordinator.compile(
            addIdols,
            modelContext: fixture.context
        ) else {
            return XCTFail("expected all Add Idol operations to compile")
        }
        XCTAssertEqual(commands.count, 25)
        XCTAssertEqual(commands.first, "addidol \"Idol 1\"")
        XCTAssertEqual(commands.last, "addidol \"Idol 25\"")

        let addEvents = (1...6).map {
            ChekinanaNLOperation(
                intent: .addevent,
                slots: .init(name: "Event \($0)", date: "2026-07-24")
            )
        }
        XCTAssertThrowsError(try ChekinanaNLSchemaValidator.validatePlan(addEvents)) {
            XCTAssertEqual($0 as? ChekinanaNLClientError, .invalidSchema)
        }
    }

    func testDetectedDateScanPlanCanReachExecutorWithoutEventOrDate() throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "巫歌")
        fixture.context.insert(idol)
        try fixture.context.save()
        let operation = ChekinanaNLOperation(
            intent: .addscancheki,
            slots: .init(idols: ["巫歌"], temporary: "all")
        )
        XCTAssertEqual(ChekinanaNLSchemaValidator.expectedMissing(for: operation), [])
        guard case .commands(let commands) = ChekinanaConversationCoordinator.compile(
            [operation],
            modelContext: fixture.context
        ) else {
            return XCTFail("expected addscancheki command")
        }
        XCTAssertEqual(
            commands,
            ["addscancheki all idols=\(shortID(idol.id))"]
        )

        let autoAssociation = ChekinanaNLOperation(
            intent: .addscancheki,
            slots: .init(temporary: "all")
        )
        XCTAssertEqual(
            ChekinanaNLSchemaValidator.expectedMissing(for: autoAssociation),
            []
        )
        guard case .commands(let autoCommands) = ChekinanaConversationCoordinator.compile(
            [autoAssociation],
            modelContext: fixture.context
        ) else {
            return XCTFail("pattern association must be allowed to reach the executor")
        }
        XCTAssertEqual(autoCommands, ["addscancheki all"])
        XCTAssertEqual(
            ChekinanaNaturalLanguageTranslator.translate("addscancheki all").command,
            "addscancheki all"
        )
    }

    func testMediaOnlyChekiPlansCompileWithoutIdolEventOrDate() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                [.init(intent: .addcheki)],
                modelContext: fixture.context
            ),
            .commands(["addcheki"])
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                [.init(intent: .addscancheki)],
                modelContext: fixture.context
            ),
            .commands(["addscancheki all"])
        )
    }

    func testEditIdolNaturalLanguageClearsOptionalFieldsAndCoordinatorKeepsDash() throws {
        let phrases: [(String, String)] = [
            ("把巫歌的团体清空", "group"),
            ("移除巫歌的生日", "birthday"),
            ("删除巫歌的颜色", "color"),
            ("清空巫歌的认证", "verification"),
            ("把巫歌的简介删除掉", "bio"),
            ("移除巫歌的头像", "avatar"),
        ]
        for (utterance, field) in phrases {
            XCTAssertEqual(
                ChekinanaNaturalLanguageTranslator.translate(utterance).command,
                "editidol 巫歌 \(field)=-",
                utterance
            )
        }

        let fixture = try makeFixture()
        let idol = Idol(name: "巫歌")
        fixture.context.insert(idol)
        try fixture.context.save()
        let operation = ChekinanaNLOperation(
            intent: .editidol,
            slots: .init(target: "巫歌", bio: "-")
        )
        guard case .commands(let commands) = ChekinanaConversationCoordinator.compile(
            [operation],
            modelContext: fixture.context
        ) else {
            return XCTFail("expected editidol clear command")
        }
        XCTAssertEqual(commands, ["editidol \(shortID(idol.id)) bio=-"])
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
        let eventDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z")
        )
        let event = Event(name: "Live", date: eventDate)
        [idolA, idolB].forEach(fixture.context.insert)
        fixture.context.insert(event)
        try fixture.context.save()

        let operation = ChekinanaNLOperation(
            intent: .addcheki,
            slots: .init(
                date: "2026-07-16",
                idols: ["Ali", "Bob"],
                event: "Live",
                note: "双人切"
            )
        )
        guard case .commands(let commands) = ChekinanaConversationCoordinator.compile(
            [operation],
            modelContext: fixture.context
        ) else {
            return XCTFail("expected command")
        }
        XCTAssertEqual(
            commands,
            ["addcheki idols=\(shortID(idolA.id)),\(shortID(idolB.id)) event=\(shortID(event.id)) date=2026-07-16 note=双人切"]
        )
    }

    func testEventAndDateCanCoexistWhileMixedIntentPlansAreRejected() throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "A")
        let event = Event(name: "E")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        try fixture.context.save()

        let combined = ChekinanaNLOperation(
            intent: .addcheki,
            slots: .init(date: "2026-07-16", idols: ["A"], event: "E")
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile([combined], modelContext: fixture.context),
            .commands([
                "addcheki idols=\(shortID(idol.id)) event=\(shortID(event.id)) date=2026-07-16",
            ])
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

        XCTAssertEqual(
            ChekinanaNaturalLanguageTranslator.translate(
                "我要添加一些idol：巫歌，饭饭，木兰，mina，aina，eriko"
            ).commands,
            [
                "addidol 巫歌",
                "addidol 饭饭",
                "addidol 木兰",
                "addidol mina",
                "addidol aina",
                "addidol eriko",
            ]
        )

        let nineNames = ["巫歌", "饭饭", "木兰", "aina", "eriko", "mina", "萝北", "石榴", "优子"]
        XCTAssertEqual(
            ChekinanaNaturalLanguageTranslator.translate(
                "添加以下几个偶像：\(nineNames.joined(separator: " "))"
            ).commands,
            nineNames.map { "addidol \($0)" }
        )
        let screenshotNames = ["巫歌", "饭饭", "木兰", "aina", "eriko", "mina", "石榴", "优子", "萝北"]
        let screenshotBulk = ChekinanaNaturalLanguageTranslator.translate(
            "添加以下这些idol：\(screenshotNames.joined(separator: " "))"
        )
        XCTAssertEqual(screenshotBulk.disposition, .localCommand)
        XCTAssertEqual(screenshotBulk.intent, "addidol")
        XCTAssertEqual(screenshotBulk.commands, screenshotNames.map { "addidol \($0)" })
        XCTAssertEqual(
            ChekinanaNaturalLanguageTranslator.translate(
                "添加下列 Idol：巫歌、\"Bob Idol\"，mina 和 eriko"
            ).commands,
            ["addidol 巫歌", "addidol \"Bob Idol\"", "addidol mina", "addidol eriko"]
        )
        XCTAssertEqual(
            ChekinanaNaturalLanguageTranslator.translate("添加 Idol Bob Idol").commands,
            ["addidol \"Bob Idol\""]
        )
        let malformedBulk = ChekinanaNaturalLanguageTranslator.translate(
            "添加下列 Idol：Alice、、Bob"
        )
        XCTAssertEqual(malformedBulk.disposition, .localClarification)
        XCTAssertTrue(malformedBulk.commands.isEmpty)

        let manyNames = (1...25).map { "偶像\($0)" }
        let manyTranslation = ChekinanaNaturalLanguageTranslator.translate(
            "添加多个idol：\(manyNames.joined(separator: "、"))"
        )
        XCTAssertEqual(manyTranslation.disposition, .localCommand)
        XCTAssertEqual(
            manyTranslation.commands,
            manyNames.map { "addidol \($0)" }
        )

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
            slots: .init(date: "2026-07-16", idols: ["A"], event: "E", temporary: "all")
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

    func testWorkerParityCompilesExplicitIdolClearsAndChekiUserPatchesWithoutSentinels() throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "Mina", bio: "bio")
        fixture.context.insert(idol)
        let cheki = Cheki(userAppears: true)
        fixture.context.insert(cheki)
        cheki.idols = [idol]
        try fixture.context.save()
        var selections = ChekinanaConversationSelections()
        selections.selectedChekiID = cheki.id

        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                [.init(intent: .editidol, slots: .init(
                    target: "Mina",
                    clearFields: ["avatar", "bio"]
                ))],
                modelContext: fixture.context
            ),
            .commands(["editidol \(shortID(idol.id)) clear_fields=avatar,bio"])
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                [.init(intent: .editcheki, slots: .init(
                    user: "false",
                    target: "the selected Cheki"
                ))],
                selections: selections,
                modelContext: fixture.context
            ),
            .commands(["editrecord cheki target=\(shortID(cheki.id)) user=false"])
        )
        XCTAssertEqual(
            ChekinanaConversationCoordinator.compile(
                [.init(intent: .editcheki, slots: .init(
                    target: "the selected Cheki",
                    clearFields: ["user"]
                ))],
                selections: selections,
                modelContext: fixture.context
            ),
            .commands(["editrecord cheki target=\(shortID(cheki.id)) clear_fields=user"])
        )
    }

    private func makeFixture() throws -> Fixture {
        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self])
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

    func testOfflineChekiEditMapsExplicitAssociationClearsToDash() {
        let expectations = [
            ("把 Cheki deadbeef 的 idol 清空", "editcheki deadbeef idols=-"),
            ("把 Cheki deadbeef 的 event 删除掉", "editcheki deadbeef event=-"),
            ("把 Cheki deadbeef 的日期改为 无", "editcheki deadbeef date=-"),
        ]
        for (utterance, command) in expectations {
            XCTAssertEqual(
                ChekinanaNaturalLanguageTranslator.translate(utterance).command,
                command,
                utterance
            )
        }
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

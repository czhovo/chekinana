import Foundation
import AVFoundation
import Combine
import CoreData
import ImageIO
import SwiftData
import UIKit
import XCTest
@testable import Chekinana

@MainActor
final class ChekinanaCommandExecutorTests: XCTestCase {
    private struct Fixture {
        let context: ModelContext
        let ledger: ChekinanaConfirmationLedger
        let executor: ChekinanaCommandExecutor
    }

    func testEventChekiOrderingIsIdolFirstStableAndHiddenAware() throws {
        func id(_ value: String) -> UUID { UUID(uuidString: value)! }
        let idolA = ChekinanaEventChekiOrdering.IdolValue(
            id: id("00000000-0000-0000-0000-00000000000A"),
            sortOrder: 0
        )
        let idolB = ChekinanaEventChekiOrdering.IdolValue(
            id: id("00000000-0000-0000-0000-00000000000B"),
            sortOrder: 1
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func value(
            _ suffix: String,
            idols: [ChekinanaEventChekiOrdering.IdolValue],
            idx: Int? = nil,
            offset: TimeInterval = 0
        ) -> ChekinanaEventChekiOrdering.Value {
            .init(
                id: id("10000000-0000-0000-0000-0000000000\(suffix)"),
                idols: idols,
                idx: idx,
                createdAt: base.addingTimeInterval(offset)
            )
        }

        let a2 = value("02", idols: [idolA], idx: 2)
        let a1 = value("01", idols: [idolA], idx: 1, offset: 10)
        let multi = value("03", idols: [idolB, idolA], idx: 1)
        let b = value("04", idols: [idolB], idx: 1)
        let unassigned = value("05", idols: [], idx: 1)
        let duplicateA2 = value("02", idols: [idolA], idx: 99)

        XCTAssertEqual(
            ChekinanaEventChekiOrdering.orderedIDs([
                unassigned, b, multi, a2, a1, duplicateA2,
            ]),
            [a1.id, a2.id, multi.id, b.id, unassigned.id]
        )
        XCTAssertEqual(
            ChekinanaEventChekiOrdering.orderedIDs(
                [unassigned, b, multi, a2, a1],
                hiddenIDs: [idolB.id]
            ),
            [a1.id, a2.id, unassigned.id]
        )

        let highUUID = ChekinanaEventChekiOrdering.IdolValue(
            id: id("F0000000-0000-0000-0000-000000000001"),
            sortOrder: nil
        )
        let lowUUID = ChekinanaEventChekiOrdering.IdolValue(
            id: id("E0000000-0000-0000-0000-000000000001"),
            sortOrder: nil
        )
        let high = value("07", idols: [highUUID])
        let low = value("06", idols: [lowUUID])
        XCTAssertEqual(
            ChekinanaEventChekiOrdering.orderedIDs([high, low]),
            [low.id, high.id]
        )

        XCTAssertEqual(
            ChekinanaEventChekiOrdering.groupedIDs([
                unassigned, b, multi, a2, a1, duplicateA2,
            ]),
            [
                .init(
                    key: .init(idolIDs: [idolA.id]),
                    recordIDs: [a1.id, a2.id]
                ),
                .init(
                    key: .init(idolIDs: [idolA.id, idolB.id]),
                    recordIDs: [multi.id]
                ),
                .init(key: .init(idolIDs: [idolB.id]), recordIDs: [b.id]),
                .init(key: .init(idolIDs: []), recordIDs: [unassigned.id]),
            ]
        )
        XCTAssertEqual(
            ChekinanaEventChekiOrdering.groupedIDs([
                value("09", idols: [idolB, idolA], idx: 2),
                value("08", idols: [idolA, idolB], idx: 1),
            ]).map(\.recordIDs),
            [[
                id("10000000-0000-0000-0000-000000000008"),
                id("10000000-0000-0000-0000-000000000009"),
            ]]
        )
        XCTAssertEqual(
            ChekinanaEventChekiOrdering.groupedIDs(
                [unassigned, multi, a2, a1],
                hiddenIDs: [idolB.id]
            ).map(\.recordIDs),
            [[a1.id, a2.id], [unassigned.id]]
        )
    }

    func testHiddenIdolPersistenceAndAnyMemberVisibility() {
        let suiteName = "ChekinanaHiddenIdolTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibleID = UUID()
        let hiddenID = UUID()
        let store = ChekinanaHiddenIdolStore(defaults: defaults)

        store.hide(hiddenID)
        XCTAssertEqual(ChekinanaHiddenIdolPersistence.load(defaults: defaults), [hiddenID])
        XCTAssertTrue(ChekinanaVisibilityPolicy.includesRecord(
            idolIDs: [visibleID],
            hiddenIDs: store.hiddenIDs
        ))
        XCTAssertFalse(ChekinanaVisibilityPolicy.includesRecord(
            idolIDs: [visibleID, hiddenID],
            hiddenIDs: store.hiddenIDs
        ))

        let relaunched = ChekinanaHiddenIdolStore(defaults: defaults)
        XCTAssertEqual(relaunched.hiddenIDs, [hiddenID])
        relaunched.unhide(hiddenID)
        XCTAssertTrue(relaunched.hiddenIDs.isEmpty)
    }

    func testUniqueSameDayEventAssociationRequiresExactlyOneMatch() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let target = utcDate(2026, 8, 13)
        let firstID = UUID()
        let secondID = UUID()

        XCTAssertNil(ChekinanaChekiEventAutoAssociation.uniqueEventID(
            for: target,
            events: [],
            calendar: calendar
        ))
        XCTAssertEqual(ChekinanaChekiEventAutoAssociation.uniqueEventID(
            for: target,
            events: [(firstID, utcDate(2026, 8, 13))],
            calendar: calendar
        ), firstID)
        XCTAssertNil(ChekinanaChekiEventAutoAssociation.uniqueEventID(
            for: target,
            events: [
                (firstID, utcDate(2026, 8, 13)),
                (secondID, utcDate(2026, 8, 13)),
            ],
            calendar: calendar
        ))
        XCTAssertNil(ChekinanaChekiEventAutoAssociation.uniqueEventID(
            for: nil,
            events: [(firstID, target)],
            calendar: calendar
        ))
    }

    func testQuickDateReplacesAutomaticEventAndPreservesExplicitEvent() throws {
        let fixture = try makeFixture()
        let eventA = UUID()
        let eventB = UUID()
        let firstDate = utcDate(2026, 8, 13)
        let secondDate = utcDate(2026, 8, 14)
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [ChekinanaPendingChekiImage(
                data: scannerPNGData(color: .purple),
                filenameExtension: "png"
            )],
            thumbnailImageData: [nil],
            dates: [firstDate],
            eventIDs: [eventA],
            eventAutoMatched: [true]
        ).inserted[0]

        XCTAssertTrue(fixture.ledger.updateTemporaryChekiDate(
            id: temporary.id,
            date: secondDate,
            automaticEventID: eventB
        ))
        var result = try XCTUnwrap(fixture.ledger.temporaryCheki(temporary.id))
        XCTAssertEqual(result.eventID, eventB)
        XCTAssertTrue(result.eventWasAutoMatched)

        XCTAssertTrue(fixture.ledger.updateTemporaryChekiDate(
            id: temporary.id,
            date: firstDate,
            automaticEventID: nil
        ))
        result = try XCTUnwrap(fixture.ledger.temporaryCheki(temporary.id))
        XCTAssertNil(result.eventID)
        XCTAssertFalse(result.eventWasAutoMatched)

        XCTAssertTrue(fixture.ledger.updateTemporaryCheki(
            id: temporary.id,
            idolIDs: result.idolIDs,
            date: result.date,
            eventID: eventA,
            userAppears: result.userAppears,
            size: result.size,
            isFavorite: result.isFavorite,
            hasPostedToSNS: result.hasPostedToSNS,
            note: result.note,
            eventWasExplicitlyEdited: true
        ))
        XCTAssertTrue(fixture.ledger.updateTemporaryChekiDate(
            id: temporary.id,
            date: secondDate,
            automaticEventID: eventB
        ))
        result = try XCTUnwrap(fixture.ledger.temporaryCheki(temporary.id))
        XCTAssertEqual(result.eventID, eventA)
        XCTAssertFalse(result.eventWasAutoMatched)
    }

    func testNoOpExistingMatchStillRefreshesQuickEditCard() {
        var reconcileCount = 0
        var refreshCount = 0
        XCTAssertTrue(ChekinanaScanReviewReconciliationPolicy.reconcileThenRefresh(
            reconcile: {
                reconcileCount += 1
                return true
            },
            refresh: {
                refreshCount += 1
                return true
            }
        ))
        XCTAssertEqual(reconcileCount, 1)
        XCTAssertEqual(refreshCount, 1)
    }

    func testHiddenLateTemporaryPolicyFiltersAnyHiddenMember() {
        let visibleID = UUID()
        let hiddenID = UUID()
        let visibleCard = ChekinanaChekiCard(
            id: UUID(),
            imageRef: nil,
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: nil
        )
        let mixedCard = ChekinanaChekiCard(
            id: UUID(),
            imageRef: nil,
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: nil
        )
        let idsByCard = [
            visibleCard.id: [visibleID],
            mixedCard.id: [visibleID, hiddenID],
        ]

        XCTAssertEqual(ChekinanaHiddenTemporaryReviewPolicy.hiddenCardIDs(
            [visibleCard, mixedCard],
            hiddenIdolIDs: [hiddenID],
            idolIDs: { idsByCard[$0] }
        ), [mixedCard.id])
    }

    func testCalendarDayNumberIsNumericAcrossSupportedLocales() {
        let samples = [
            (ChekinanaProductDate.date(year: 2026, month: 8, day: 1), "1"),
            (ChekinanaProductDate.date(year: 2026, month: 8, day: 10), "10"),
            (ChekinanaProductDate.date(year: 2026, month: 8, day: 31), "31"),
        ]

        for identifier in ["en", "zh-Hans", "ja"] {
            let locale = Locale(identifier: identifier)
            for (date, expected) in samples {
                let value = ChekinanaProductDate.dayNumber(date, locale: locale)
                XCTAssertEqual(value, expected, identifier)
                XCTAssertFalse(value.contains("日"), identifier)
            }
        }
    }

    func testCalendarCrossMonthSelectionKeepsDisplayedPage() {
        let displayedMonth = ChekinanaProductDate.date(
            year: 2026,
            month: 8,
            day: 1
        )
        let leadingDate = ChekinanaProductDate.date(
            year: 2026,
            month: 7,
            day: 26
        )
        let selection = ChekinanaCalendarSelectionPolicy.selecting(
            leadingDate,
            displayedMonth: displayedMonth
        )
        XCTAssertEqual(selection.selectedDate, leadingDate)
        XCTAssertEqual(selection.displayedMonth, displayedMonth)
    }

    func testBirthdayUsesCanonicalDateOnlyAndJapaneseTerm() throws {
        XCTAssertEqual(
            ChekinanaBirthdayValue.parse("2001-02-03"),
            ChekinanaDateOnly.parse("2001-02-03")
        )
        XCTAssertEqual(
            ChekinanaBirthdayValue.parse("2001年2月3日"),
            ChekinanaDateOnly.parse("2001-02-03")
        )
        XCTAssertEqual(
            ChekinanaBirthdayValue.parse("2001.02.03"),
            ChekinanaDateOnly.parse("2001-02-03")
        )
        XCTAssertNil(ChekinanaBirthdayValue.parse("02.03"))
        XCTAssertNil(ChekinanaBirthdayValue.parse("3月2日"))
        XCTAssertEqual(
            try ChekinanaBirthdayValue.normalizedStorage("2001年2月3日"),
            "2001-02-03"
        )
        for legacy in ["3月2日", "03月02日", "03.02", "3/2", "--03-02"] {
            XCTAssertEqual(
                ChekinanaBirthdayValue.semantic(legacy),
                .monthDay(month: 3, day: 2),
                legacy
            )
            XCTAssertEqual(
                try ChekinanaBirthdayValue.normalizedStorage(legacy),
                "--03-02",
                legacy
            )
        }
        XCTAssertThrowsError(try ChekinanaBirthdayValue.normalizedStorage("not a date"))
        XCTAssertEqual(
            ChekinanaBirthdayValue.localizedDisplay(
                "--03-02",
                locale: Locale(identifier: "ja")
            ),
            "3月2日"
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
        let displayed = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2001,
            month: 2,
            day: 3
        )))
        XCTAssertEqual(
            ChekinanaBirthdayValue.canonicalString(
                from: displayed,
                calendar: calendar
            ),
            "2001-02-03"
        )
        let japaneseBundle = try localizedAppBundle(language: "ja")
        XCTAssertEqual(
            ChekinanaProductCopy.text(
                "idols.birthday",
                "Birthday",
                bundle: japaneseBundle
            ),
            "誕生日"
        )
        XCTAssertTrue(
            ChekinanaProductCopy.text(
                "idols.catalogue_autofill",
                "Auto-fills birthday",
                bundle: japaneseBundle
            ).contains("誕生日")
        )
    }

    func testBirthdayEditorSupportsUnknownYearFullDateAndClearWithoutFakeYear() throws {
        XCTAssertEqual(
            ChekinanaBirthdayEditorPolicy.initialMode(
                for: .monthDay(month: 2, day: 29)
            ),
            .unknownYear
        )
        XCTAssertEqual(
            ChekinanaBirthdayEditorPolicy.initialMode(
                for: .fullDate(year: 2004, month: 2, day: 29)
            ),
            .fullDate
        )
        XCTAssertEqual(
            ChekinanaBirthdayEditorPolicy.dayRange(month: 2),
            1...29
        )
        XCTAssertEqual(
            ChekinanaBirthdayEditorPolicy.clampedDay(31, month: 4),
            30
        )

        let referenceDate = try XCTUnwrap(
            ChekinanaDateOnly.canonicalDate(year: 2_000, month: 2, day: 29)
        )
        XCTAssertEqual(
            try ChekinanaBirthdayEditorPolicy.storageValue(
                hasBirthday: true,
                mode: .unknownYear,
                fullDate: referenceDate,
                unknownMonth: 2,
                unknownDay: 29,
                fullYearConfirmed: false
            ),
            "--02-29"
        )
        XCTAssertThrowsError(
            try ChekinanaBirthdayEditorPolicy.storageValue(
                hasBirthday: true,
                mode: .unknownYear,
                fullDate: referenceDate,
                unknownMonth: 2,
                unknownDay: 30,
                fullYearConfirmed: false
            )
        )
        XCTAssertThrowsError(
            try ChekinanaBirthdayEditorPolicy.storageValue(
                hasBirthday: true,
                mode: .fullDate,
                fullDate: referenceDate,
                unknownMonth: 2,
                unknownDay: 29,
                fullYearConfirmed: false
            )
        )
        XCTAssertEqual(
            try ChekinanaBirthdayEditorPolicy.storageValue(
                hasBirthday: true,
                mode: .fullDate,
                fullDate: referenceDate,
                unknownMonth: 2,
                unknownDay: 29,
                fullYearConfirmed: true
            ),
            "2000-02-29"
        )
        XCTAssertNil(
            try ChekinanaBirthdayEditorPolicy.storageValue(
                hasBirthday: false,
                mode: .fullDate,
                fullDate: referenceDate,
                unknownMonth: 2,
                unknownDay: 29,
                fullYearConfirmed: false
            )
        )
    }

    func testBirthdayEditorModeCopyIsCompleteInAllSupportedLanguages() throws {
        let expected: [String: [String]] = [
            "en": ["Birthday precision", "Year unknown", "Full date"],
            "zh-Hans": ["生日精度", "年份未知", "完整日期"],
            "ja": ["誕生日の精度", "生年不明", "年月日"],
        ]
        for (language, values) in expected {
            let bundle = try localizedAppBundle(language: language)
            XCTAssertEqual(
                ChekinanaProductCopy.text(
                    "idols.birthday_precision",
                    "Birthday precision",
                    bundle: bundle
                ),
                values[0]
            )
            XCTAssertEqual(
                ChekinanaProductCopy.text(
                    "idols.birthday_mode.unknown_year",
                    "Year unknown",
                    bundle: bundle
                ),
                values[1]
            )
            XCTAssertEqual(
                ChekinanaProductCopy.text(
                    "idols.birthday_mode.full_date",
                    "Full date",
                    bundle: bundle
                ),
                values[2]
            )
        }
    }

    func testCatalogueBirthdayDecodeNormalizesSupportedAPIValuesAndIsolatesInvalid() throws {
        let data = Data(#"""
        [
            {"id":"full","idolName":"Full","birthday":"2001-02-03"},
            {"id":"zh","idolName":"Chinese","birthday":"3月14日"},
            {"id":"dot","idolName":"Dot","birthday":"03.14"},
            {"id":"slash","idolName":"Slash","birthday":"3/14"},
            {"id":"reduced","idolName":"Reduced","birthday":"--03-14"},
            {"id":"empty","idolName":"Empty","birthday":"   "},
            {"id":"invalid","idolName":"Invalid","birthday":"spring"}
        ]
        """#.utf8)
        let values = try JSONDecoder().decode([ChekinanaEnrichedIdol].self, from: data)

        XCTAssertEqual(values.map(\.birthday), [
            "2001-02-03", "--03-14", "--03-14", "--03-14", "--03-14", nil,
            "spring",
        ])
        XCTAssertEqual(values.map(\.birthdayIsInvalid), [
            false, false, false, false, false, false, true,
        ])
        XCTAssertThrowsError(
            try ChekinanaBirthdayValue.normalizedCatalogueCandidate(values[6])
        )
    }

    func testEditIdolNormalizesMonthDayBirthdayAndRejectsInvalidText() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "Birthday Target")
        fixture.context.insert(idol)
        try fixture.context.save()
        let target = String(idol.id.uuidString.prefix(8)).lowercased()

        guard case .idolCard(let preview) = await fixture.executor.execute(
            "editidol \(target) birthday=3月14日"
        ), let code = preview.confirmationCode else {
            return XCTFail("Expected normalized month/day confirmation.")
        }
        XCTAssertEqual(preview.birthday, "--03-14")
        _ = await fixture.executor.execute("confirm \(code)")
        XCTAssertEqual(idol.birthday, "--03-14")

        let invalid = await fixture.executor.execute(
            "editidol \(target) birthday=unknown"
        )
        XCTAssertTrue(text(from: invalid).contains("valid full date"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertEqual(idol.birthday, "--03-14")
    }

    func testCatalogueConfirmationNormalizesMonthDayBirthday() async throws {
        let fixture = try makeFixture()
        let candidate = ChekinanaEnrichedIdol(
            sourceId: "birthday-month-day",
            idolName: "Month Day Idol",
            groupName: nil,
            color: nil,
            birthday: "6月24日",
            verification: nil,
            bio: nil,
            avatarUrl: "https://catalogue.test/month-day.jpg"
        )
        let prepared = ChekinanaPreparedIdolCandidate(
            candidate: candidate,
            avatarThumbnailData: scannerPNGData(color: .purple),
            avatarIdentity: ChekinanaIdolAvatarIdentity.make(
                sourceID: candidate.sourceId,
                avatarURL: candidate.avatarUrl
            )
        )
        let generation = fixture.ledger.beginIdolQuery()
        let code = try XCTUnwrap(fixture.ledger.publishIdolConfirmation(
            prepared,
            generation: generation
        ))
        guard let entry = fixture.ledger.entry(for: code),
              case .addIdol(let payload) = entry.action else {
            return XCTFail("Expected a canonical Catalogue payload in the ledger.")
        }
        XCTAssertEqual(payload.candidate.birthday, "--06-24")

        _ = await fixture.executor.execute("confirm \(code)")
        let saved = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<Idol>()).first)
        XCTAssertEqual(saved.birthday, "--06-24")
        _ = try? ChekinanaIdolReferenceStore.removeManagedAvatar(
            saved.avatarImageRef,
            idolID: saved.id
        )

        let invalid = ChekinanaPreparedIdolCandidate(
            candidate: ChekinanaEnrichedIdol(
                sourceId: "birthday-invalid",
                idolName: "Invalid Birthday Idol",
                groupName: nil,
                color: nil,
                birthday: "not a date",
                verification: nil,
                bio: nil,
                avatarUrl: nil
            ),
            avatarThumbnailData: nil,
            avatarIdentity: nil
        )
        let invalidGeneration = fixture.ledger.beginIdolQuery()
        XCTAssertNil(fixture.ledger.publishIdolConfirmation(
            invalid,
            generation: invalidGeneration
        ))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
    }

    func testNoMediaChekiNoteGroupingTreatsNilAndEmptyAsSameButKeepsExactText() {
        XCTAssertEqual(
            ChekinanaIdolNoMediaChekiGrouping.exactNoteKey(nil),
            ChekinanaIdolNoMediaChekiGrouping.exactNoteKey("")
        )
        XCTAssertNotEqual(
            ChekinanaIdolNoMediaChekiGrouping.exactNoteKey("note"),
            ChekinanaIdolNoMediaChekiGrouping.exactNoteKey(" note ")
        )
    }

    func testIdolChekiReorderMovesNoteBlockWithinExactGroup() throws {
        let idolID = UUID()
        let date = utcDate(2026, 8, 2)
        let group = try XCTUnwrap(ChekinanaChekiGroupKey(
            idolIDs: [idolID],
            date: date
        ))
        let first = UUID()
        let second = UUID()
        let media = UUID()
        let moved = ChekinanaIdolChekiReorderPlan.movedBlocks(
            [[first, second], [media]],
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        )
        let assignments = try ChekinanaIdolChekiReorderPlan.assignments(
            for: moved,
            liveSnapshots: [
                .init(chekiID: first, group: group, idx: 1),
                .init(chekiID: second, group: group, idx: 2),
                .init(chekiID: media, group: group, idx: 3),
            ]
        )
        XCTAssertEqual(assignments[media], 1)
        XCTAssertEqual(assignments[first], 2)
        XCTAssertEqual(assignments[second], 3)
        XCTAssertEqual(Set(assignments.values), [1, 2, 3])
    }

    func testIdolChekiReorderRejectsMixedOrChangedGroups() throws {
        let firstID = UUID()
        let secondID = UUID()
        let date = utcDate(2026, 8, 2)
        let firstGroup = try XCTUnwrap(ChekinanaChekiGroupKey(
            idolIDs: [UUID()],
            date: date
        ))
        let secondGroup = try XCTUnwrap(ChekinanaChekiGroupKey(
            idolIDs: [UUID()],
            date: date
        ))
        XCTAssertThrowsError(try ChekinanaIdolChekiReorderPlan.assignments(
            for: [[firstID], [secondID]],
            liveSnapshots: [
                .init(chekiID: firstID, group: firstGroup, idx: 1),
                .init(chekiID: secondID, group: secondGroup, idx: 1),
            ]
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaIdolChekiReorderError,
                .mixedGroups
            )
        }
        XCTAssertThrowsError(try ChekinanaIdolChekiReorderPlan.assignments(
            for: [[firstID]],
            liveSnapshots: [
                .init(chekiID: firstID, group: firstGroup, idx: 1),
                .init(chekiID: secondID, group: firstGroup, idx: 2),
            ]
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaIdolChekiReorderError,
                .changedRecords
            )
        }
    }

    func testIdolChekiReorderPersistsAcrossStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chekinana-idol-reorder-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Reorder.store")
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let configuration = ModelConfiguration(
            "Reorder",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let idolID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let date = utcDate(2026, 8, 2)

        var container: ModelContainer? = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        do {
            let context = ModelContext(try XCTUnwrap(container))
            let idol = Idol(id: idolID, name: "Reorder")
            context.insert(idol)
            let records = [
                Cheki(id: firstID, date: date, idx: 1),
                Cheki(id: secondID, date: date, idx: 2),
                Cheki(id: thirdID, date: date, idx: 3),
            ]
            for record in records {
                context.insert(record)
                record.idols = [idol]
            }
            try context.save()
            let group = try XCTUnwrap(ChekinanaChekiGroupKey(
                idolIDs: [idolID],
                date: date
            ))
            let moved = ChekinanaIdolChekiReorderPlan.movedBlocks(
                [[firstID], [secondID], [thirdID]],
                fromOffsets: IndexSet(integer: 2),
                toOffset: 0
            )
            let assignments = try ChekinanaIdolChekiReorderPlan.assignments(
                for: moved,
                liveSnapshots: records.map {
                    .init(chekiID: $0.id, group: group, idx: $0.idx)
                }
            )
            for record in records {
                record.idx = assignments[record.id]
            }
            try context.save()
        }
        container = nil

        let reopened = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let reopenedContext = ModelContext(reopened)
        let ordered = ChekinanaRecordOrdering.orderedChekis(
            try reopenedContext.fetch(FetchDescriptor<Cheki>())
        )
        XCTAssertEqual(ordered.map(\.id), [thirdID, firstID, secondID])
        XCTAssertEqual(ordered.compactMap(\.idx), [1, 2, 3])
    }

    func testNoMediaChekiBatchIncreaseDecreaseAndNoteUseLiveContextAndContiguousIndices() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Batch Idol")
        let event = Event(name: "Batch Event")
        setup.insert(idol)
        setup.insert(event)
        let date = utcDate(2026, 8, 2)
        let first = Cheki(
            date: date,
            idx: 3,
            userAppears: true,
            size: .wide,
            isFavorite: true,
            hasPostedToSNS: true,
            note: "same",
            createdAt: date.addingTimeInterval(1)
        )
        let second = Cheki(
            date: date,
            idx: 7,
            userAppears: true,
            size: .wide,
            isFavorite: true,
            hasPostedToSNS: true,
            note: "same",
            createdAt: date.addingTimeInterval(2)
        )
        let unrelated = Cheki(
            date: date,
            idx: 9,
            userAppears: true,
            size: .wide,
            isFavorite: true,
            hasPostedToSNS: true,
            note: "different",
            createdAt: date.addingTimeInterval(3)
        )
        for cheki in [first, second, unrelated] {
            setup.insert(cheki)
            cheki.idols = [idol]
            cheki.event = event
        }
        try setup.save()

        let draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [first.id, second.id],
            allChekis: try setup.fetch(FetchDescriptor<Cheki>())
        )
        let insertedGroupIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            draft,
            quantity: 4,
            note: "updated",
            in: ModelContext(container)
        )
        XCTAssertEqual(insertedGroupIDs.count, 4)

        let afterIncrease = ModelContext(container)
        let increased = try afterIncrease.fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(increased.count, 5)
        XCTAssertEqual(increased.compactMap(\.idx).sorted(), [1, 2, 3, 4, 5])
        let selectedAfterIncrease = increased.filter { insertedGroupIDs.contains($0.id) }
        XCTAssertEqual(selectedAfterIncrease.count, 4)
        XCTAssertTrue(selectedAfterIncrease.allSatisfy {
            $0.note == "updated"
                && $0.imageRef == nil
                && $0.event?.id == event.id
                && $0.idols.map(\.id) == [idol.id]
                && $0.sizeRawValue == ChekiSize.wide.rawValue
                && $0.userAppears == true
                && $0.isFavorite
                && $0.hasPostedToSNS
        })
        XCTAssertEqual(
            increased.first(where: { $0.id == unrelated.id })?.note,
            "different"
        )

        let decreaseDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: insertedGroupIDs,
            allChekis: increased
        )
        let retainedIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            decreaseDraft,
            quantity: 2,
            note: "final",
            in: ModelContext(container)
        )
        XCTAssertEqual(Set(retainedIDs), [first.id, second.id])
        let final = try ModelContext(container).fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(final.count, 3)
        XCTAssertEqual(final.compactMap(\.idx).sorted(), [1, 2, 3])
        XCTAssertTrue(final.filter { retainedIDs.contains($0.id) }.allSatisfy {
            $0.note == "final"
        })
        XCTAssertEqual(final.first(where: { $0.id == unrelated.id })?.note, "different")
    }

    func testNoMediaChekiBatchUndatedClearsWholeGroupIndicesAndRejectsLateMutation() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Undated Batch")
        setup.insert(idol)
        let createdAt = utcDate(2026, 8, 2)
        let first = Cheki(idx: 4, note: "same", createdAt: createdAt)
        let second = Cheki(
            idx: 8,
            note: "same",
            createdAt: createdAt.addingTimeInterval(1)
        )
        let otherBlock = Cheki(
            idx: 9,
            note: "other",
            createdAt: createdAt.addingTimeInterval(2)
        )
        let media = Cheki(
            idx: 10,
            imageRef: "managed-existing.jpg",
            note: "media",
            createdAt: createdAt.addingTimeInterval(3)
        )
        for cheki in [first, second, otherBlock, media] {
            setup.insert(cheki)
            cheki.idols = [idol]
        }
        try setup.save()

        let staleDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [first.id, second.id],
            allChekis: try setup.fetch(FetchDescriptor<Cheki>())
        )
        let lateContext = ModelContext(container)
        let lateOther = try XCTUnwrap(
            lateContext.fetch(FetchDescriptor<Cheki>()).first { $0.id == otherBlock.id }
        )
        lateOther.isFavorite = true
        lateOther.updatedAt = createdAt.addingTimeInterval(500)
        try lateContext.save()

        XCTAssertThrowsError(try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            staleDraft,
            quantity: 3,
            note: "must not apply",
            in: ModelContext(container)
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaIdolNoMediaChekiBatchError,
                .changedRecords
            )
        }
        let afterRejected = try ModelContext(container).fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(afterRejected.count, 4)
        XCTAssertEqual(afterRejected.compactMap(\.idx).sorted(), [4, 8, 9, 10])

        let freshDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [first.id, second.id],
            allChekis: afterRejected
        )
        let increasedIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            freshDraft,
            quantity: 4,
            note: "updated",
            in: ModelContext(container)
        )
        XCTAssertEqual(increasedIDs.count, 4)
        let afterIncrease = try ModelContext(container).fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(afterIncrease.count, 6)
        XCTAssertTrue(afterIncrease.allSatisfy { $0.date == nil && $0.idx == nil })
        XCTAssertTrue(afterIncrease.filter { increasedIDs.contains($0.id) }.allSatisfy {
            $0.note == "updated"
        })
        XCTAssertEqual(
            afterIncrease.first(where: { $0.id == otherBlock.id })?.note,
            "other"
        )
        XCTAssertEqual(
            afterIncrease.first(where: { $0.id == media.id })?.imageRef,
            "managed-existing.jpg"
        )

        let decreaseDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: increasedIDs,
            allChekis: afterIncrease
        )
        let retainedIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            decreaseDraft,
            quantity: 2,
            note: "final",
            in: ModelContext(container)
        )
        XCTAssertEqual(Set(retainedIDs), [first.id, second.id])
        let final = try ModelContext(container).fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(final.count, 4)
        XCTAssertTrue(final.allSatisfy { $0.date == nil && $0.idx == nil })
        XCTAssertTrue(final.filter { retainedIDs.contains($0.id) }.allSatisfy {
            $0.note == "final"
        })
    }

    func testNoMediaChekiBatchNoteCollisionReturnsMergedIdentityForSecondEdit() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Merge Batch")
        setup.insert(idol)
        let date = utcDate(2026, 8, 2)
        let sourceFirst = Cheki(date: date, idx: 1, note: "source")
        let sourceSecond = Cheki(date: date, idx: 2, note: "source")
        let targetFirst = Cheki(date: date, idx: 3, note: "target")
        let targetSecond = Cheki(date: date, idx: 4, note: "target")
        for cheki in [sourceFirst, sourceSecond, targetFirst, targetSecond] {
            setup.insert(cheki)
            cheki.idols = [idol]
        }
        try setup.save()

        let sourceDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [sourceFirst.id, sourceSecond.id],
            allChekis: try setup.fetch(FetchDescriptor<Cheki>())
        )
        let mergedIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            sourceDraft,
            quantity: 3,
            note: "target",
            in: ModelContext(container)
        )
        XCTAssertEqual(mergedIDs.count, 5)
        XCTAssertTrue(Set(mergedIDs).isSuperset(of: [targetFirst.id, targetSecond.id]))
        let afterMerge = try ModelContext(container).fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(afterMerge.count, 5)
        XCTAssertEqual(afterMerge.compactMap(\.idx).sorted(), [1, 2, 3, 4, 5])
        XCTAssertTrue(afterMerge.allSatisfy { $0.note == "target" })

        let secondDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: mergedIDs,
            allChekis: afterMerge
        )
        XCTAssertEqual(secondDraft.quantity, 5)
        let secondEditIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            secondDraft,
            quantity: 4,
            note: "target",
            in: ModelContext(container)
        )
        XCTAssertEqual(secondEditIDs.count, 4)
        let final = try ModelContext(container).fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(final.count, 4)
        XCTAssertEqual(final.compactMap(\.idx).sorted(), [1, 2, 3, 4])
        XCTAssertTrue(final.allSatisfy { $0.note == "target" })
    }

    func testNoMediaChekiBatchIdentityDoesNotCoalesceMixedMetadata() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Identity")
        let date = utcDate(2026, 8, 2)
        let event = Event(name: "Event")
        context.insert(idol)
        context.insert(event)
        let values = [
            Cheki(date: date, userAppears: false, size: .mini, note: "same"),
            Cheki(date: date, userAppears: false, size: .mini, note: "same"),
            Cheki(date: date, userAppears: true, size: .mini, note: "same"),
            Cheki(date: date, userAppears: false, size: .wide, note: "same"),
            Cheki(date: date, userAppears: false, size: .mini, isFavorite: true, note: "same"),
            Cheki(date: date, userAppears: false, size: .mini, hasPostedToSNS: true, note: "same"),
        ]
        for value in values {
            context.insert(value)
            value.idols = [idol]
        }
        values[1].event = event
        try context.save()
        XCTAssertEqual(Set(values.compactMap(ChekinanaIdolNoMediaChekiIdentity.init)).count, 6)
        let draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [values[0].id],
            allChekis: values
        )
        XCTAssertEqual(draft.quantity, 1)
        XCTAssertEqual(draft.selectedRecordIDs, [values[0].id])
    }

    func testNoMediaChekiBatchRejectsLateMutationWithoutPartialWrite() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Late")
        setup.insert(idol)
        let date = utcDate(2026, 8, 2)
        let first = Cheki(date: date, idx: 4, note: "same")
        let second = Cheki(date: date, idx: 8, note: "same")
        for value in [first, second] {
            setup.insert(value)
            value.idols = [idol]
        }
        try setup.save()
        let draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [first.id, second.id],
            allChekis: try setup.fetch(FetchDescriptor<Cheki>())
        )
        XCTAssertThrowsError(try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            draft,
            quantity: 0,
            note: "invalid",
            in: ModelContext(container)
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaIdolNoMediaChekiBatchError,
                .invalidQuantity
            )
            XCTAssertEqual(
                error.localizedDescription,
                ChekinanaProductRecordCreationError.invalidBatchQuantity.localizedDescription
            )
        }

        let lateContext = ModelContext(container)
        let late = try XCTUnwrap(
            lateContext.fetch(FetchDescriptor<Cheki>()).first { $0.id == first.id }
        )
        late.note = "late mutation"
        late.updatedAt = date.addingTimeInterval(500)
        try lateContext.save()

        XCTAssertThrowsError(try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            draft,
            quantity: 3,
            note: "must not apply",
            in: ModelContext(container)
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaIdolNoMediaChekiBatchError,
                .changedRecords
            )
        }
        let final = try ModelContext(container).fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(final.count, 2)
        XCTAssertEqual(final.compactMap(\.idx).sorted(), [4, 8])
        XCTAssertEqual(final.first(where: { $0.id == first.id })?.note, "late mutation")
        XCTAssertEqual(final.first(where: { $0.id == second.id })?.note, "same")
    }

    func testGalleryShotTypeFilterUsesStrictOptionalBooleanSemantics() {
        XCTAssertTrue(ChekinanaGalleryShotTypeFilter.all.includes(nil))
        XCTAssertTrue(ChekinanaGalleryShotTypeFilter.all.includes(false))
        XCTAssertTrue(ChekinanaGalleryShotTypeFilter.all.includes(true))
        XCTAssertFalse(ChekinanaGalleryShotTypeFilter.solo.includes(nil))
        XCTAssertTrue(ChekinanaGalleryShotTypeFilter.solo.includes(false))
        XCTAssertFalse(ChekinanaGalleryShotTypeFilter.solo.includes(true))
        XCTAssertFalse(ChekinanaGalleryShotTypeFilter.twoShot.includes(nil))
        XCTAssertFalse(ChekinanaGalleryShotTypeFilter.twoShot.includes(false))
        XCTAssertTrue(ChekinanaGalleryShotTypeFilter.twoShot.includes(true))
        XCTAssertEqual(
            ChekinanaGalleryShotTypeFilter.allCases.map(\.rawValue),
            ["all", "solo", "two-shot"]
        )
    }

    func testShotTypeControlCopyIsCompleteInAllSupportedLanguages() throws {
        let expectations: [String: [String]] = [
            "en": ["Shot type", "Unknown", "All"],
            "zh-Hans": ["合影类型", "未知", "全部"],
            "ja": ["撮影タイプ", "不明", "すべて"],
        ]
        for (language, expected) in expectations {
            let bundle = try localizedAppBundle(language: language)
            XCTAssertEqual([
                ChekinanaProductCopy.text(
                    "scan.shot_type",
                    "Shot type",
                    bundle: bundle
                ),
                ChekinanaProductCopy.text(
                    "scan.shot_type.unknown",
                    "Unknown",
                    bundle: bundle
                ),
                ChekinanaProductCopy.text(
                    "gallery.shot_filter.all",
                    "All",
                    bundle: bundle
                ),
            ], expected, language)
        }
    }

    func testAppLanguagePreferenceMappingAndBundles() throws {
        XCTAssertEqual(ChekinanaAppLanguage.resolve(nil), .system)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("invalid"), .system)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("system"), .system)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("zh-Hans"), .simplifiedChinese)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("en"), .english)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("ja"), .japanese)

        let suiteName = "ChekinanaLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(ChekinanaLanguagePreference.language(defaults: defaults), .system)
        ChekinanaLanguagePreference.set(.japanese, defaults: defaults)
        XCTAssertEqual(ChekinanaLanguagePreference.language(defaults: defaults), .japanese)

        let candidates = [Bundle.main, Bundle(for: Self.self)]
            + Bundle.allBundles
            + Bundle.allFrameworks
        for (language, expected) in [
            (ChekinanaAppLanguage.english, "Settings"),
            (.simplifiedChinese, "设置"),
            (.japanese, "設定"),
        ] {
            let bundle = ChekinanaLanguagePreference.localizationBundle(
                for: language,
                candidates: candidates
            )
            XCTAssertEqual(
                ChekinanaProductCopy.text(
                    "settings.title",
                    "Settings",
                    bundle: bundle
                ),
                expected,
                language.rawValue
            )
        }
    }

    func testEventChekiGroupCountsUseChekiSpecificClassifiersInEveryLanguage() throws {
        let expectations: [(String, [String])] = [
            ("en", ["0 chekis", "1 Cheki", "2 chekis"]),
            ("zh-Hans", ["0张拍立得", "1张拍立得", "2张拍立得"]),
            ("ja", ["チェキ0枚", "チェキ1枚", "チェキ2枚"]),
        ]
        for (language, expected) in expectations {
            let bundle = try localizedAppBundle(language: language)
            let locale = Locale(identifier: language)
            let actual = [0, 1, 2].map { count in
                ChekinanaProductCopy.quantity(
                    "events.cheki_group_count",
                    count: count,
                    one: "%lld record",
                    other: "%lld records",
                    bundle: bundle,
                    locale: locale
                )
            }
            XCTAssertEqual(actual, expected, language)
        }
    }

    func testGlobalChekiCountsUseChekiSpecificClassifiersInEveryLanguage() throws {
        let expectations: [(String, [String])] = [
            ("en", ["0 chekis", "1 Cheki", "2 chekis"]),
            ("zh-Hans", ["0张拍立得", "1张拍立得", "2张拍立得"]),
            ("ja", ["チェキ0枚", "チェキ1枚", "チェキ2枚"]),
        ]
        for (language, expected) in expectations {
            let bundle = try localizedAppBundle(language: language)
            let locale = Locale(identifier: language)
            XCTAssertEqual(
                [0, 1, 2].map {
                    ChekinanaRecordKind.cheki.countLabel(
                        $0,
                        bundle: bundle,
                        locale: locale
                    )
                },
                expected,
                language
            )
        }
    }

    func testLanguageStorePublishesAfterNewBundlePreferenceIsVisible() {
        let store = ChekinanaLanguageStore.shared
        let original = store.language
        defer { store.language = original }
        store.language = .english
        var textSeenDuringNotification: String?
        let cancellable = store.objectWillChange.sink {
            textSeenDuringNotification = ChekinanaProductCopy.text(
                "settings.title",
                "Settings"
            )
        }

        store.language = .japanese

        XCTAssertEqual(textSeenDuringNotification, "設定")
        XCTAssertEqual(store.language, .japanese)
        XCTAssertEqual(store.displayLocale.identifier, "ja")
        withExtendedLifetime(cancellable) {}
    }

    func testBottomTabBarIsSevenPointsShorterWithAccessibleHitTargets() {
        XCTAssertEqual(
            ChekinanaBottomTabBarMetrics.previousMinimumHeight
                - ChekinanaBottomTabBarMetrics.minimumHeight,
            7
        )
        XCTAssertGreaterThanOrEqual(
            ChekinanaBottomTabBarMetrics.buttonMinimumHeight,
            44
        )
        XCTAssertEqual(
            ChekinanaBottomTabBarMetrics.buttonMinimumHeight
                + ChekinanaBottomTabBarMetrics.topPadding
                + ChekinanaBottomTabBarMetrics.bottomPadding,
            ChekinanaBottomTabBarMetrics.minimumHeight
        )
    }

    func testExecutorLocalizesVisibleEmptyCancelAndConfirmationResultsWithoutChangingSentinel() async throws {
        let fixture = try makeFixture(idolSearch: { _ in [] })

        let noConfirmation = await fixture.executor.execute("confirm")
        XCTAssertEqual(
            noConfirmation,
            .text("error: " + ChekinanaProductCopy.text(
                "assistant.executor.confirmation.none",
                "There is no pending operation to confirm."
            ))
        )
        let cancelled = await fixture.executor.execute("cancel all")
        XCTAssertEqual(
            cancelled,
            .text(ChekinanaProductCopy.format(
                "assistant.executor.confirmation.cancelled_all",
                "Cancelled pending confirmations: %lld.",
                Int64(0)
            ))
        )
        let idols = await fixture.executor.execute("listidol")
        XCTAssertEqual(
            idols,
            .text(ChekinanaProductCopy.text(
                "assistant.executor.idol.none",
                "No Idols have been added yet."
            ))
        )
        let events = await fixture.executor.execute("listevent")
        XCTAssertEqual(
            events,
            .text(ChekinanaProductCopy.text(
                "assistant.executor.event.none",
                "No Events have been added yet."
            ))
        )
        let chekis = await fixture.executor.execute("listcheki")
        XCTAssertEqual(
            chekis,
            .text(ChekinanaProductCopy.text(
                "assistant.executor.cheki.none",
                "No Cheki have been saved yet."
            ))
        )
        let records = await fixture.executor.execute(.init(
            name: "listrecord",
            target: "cheki",
            arguments: [:]
        ))
        XCTAssertEqual(
            records,
            .text(ChekinanaProductCopy.text(
                "assistant.executor.record.none",
                "No matching records."
            ))
        )
    }

    func testExecutorCatalogEnglishPreservesDynamicUserTextAndFormatsCounts() throws {
        let bundle = try localizedAppBundle(language: "en")
        let locale = Locale(identifier: "en")
        XCTAssertEqual(
            ChekinanaProductCopy.quantity(
                "assistant.executor.cheki.album_prepared",
                count: 2,
                one: "fallback",
                other: "fallback",
                bundle: bundle,
                locale: locale
            ),
            "Prepared 2 chekis from the photo library"
        )
        let note = "原样 note テスト"
        XCTAssertEqual(
            ChekinanaProductCopy.format(
                "assistant.executor.field.note",
                "fallback %@",
                bundle: bundle,
                locale: locale,
                note
            ),
            "Note: \(note)"
        )
    }

    func testExecutorCatalogSimplifiedChineseFormatsSuccessErrorAndPreservesIDs() throws {
        let bundle = try localizedAppBundle(language: "zh-Hans")
        let locale = Locale(identifier: "zh-Hans")
        XCTAssertEqual(
            ChekinanaProductCopy.text(
                "assistant.executor.idol.deleted",
                "fallback",
                bundle: bundle
            ),
            "已删除 Idol。"
        )
        XCTAssertEqual(
            ChekinanaProductCopy.format(
                "assistant.executor.error.scan_http_status",
                "fallback %lld",
                bundle: bundle,
                locale: locale,
                Int64(503)
            ),
            "扫描请求失败，HTTP 503。"
        )
        XCTAssertEqual(
            ChekinanaProductCopy.format(
                "assistant.executor.confirmation.cancelled",
                "fallback %@",
                bundle: bundle,
                locale: locale,
                "deadbeef"
            ),
            "已取消确认：deadbeef。"
        )
    }

    func testExecutorCatalogJapaneseFormatsRecordAndScanResults() throws {
        let bundle = try localizedAppBundle(language: "ja")
        let locale = Locale(identifier: "ja")
        XCTAssertEqual(
            ChekinanaProductCopy.text(
                "assistant.executor.record.completed",
                "fallback",
                bundle: bundle
            ),
            "記録の操作が完了しました。"
        )
        XCTAssertEqual(
            ChekinanaProductCopy.quantity(
                "assistant.executor.cheki.scan_results_prepared",
                count: 2,
                one: "fallback",
                other: "fallback",
                bundle: bundle,
                locale: locale
            ),
            "2件のスキャン結果を保存する準備ができました。"
        )
    }

    func testThumbnailValidationRejectsNonFiniteOrUnsafeSourceProperties() {
        let valid: [CFString: Any] = [
            kCGImagePropertyPixelWidth: NSNumber(value: 2),
            kCGImagePropertyPixelHeight: NSNumber(value: 2),
            kCGImagePropertyOrientation: NSNumber(value: 1),
        ]
        XCTAssertTrue(ChekinanaImageSourceValidator.accepts(properties: valid))

        var nonFiniteWidth = valid
        nonFiniteWidth[kCGImagePropertyPixelWidth] = NSNumber(value: Double.nan)
        XCTAssertFalse(ChekinanaImageSourceValidator.accepts(properties: nonFiniteWidth))

        var unrelatedNonFiniteMetadata = valid
        unrelatedNonFiniteMetadata[kCGImagePropertyExifDictionary] = [
            kCGImagePropertyExifExposureTime: NSNumber(value: Double.infinity),
        ] as [CFString: Any]
        XCTAssertTrue(
            ChekinanaImageSourceValidator.accepts(properties: unrelatedNonFiniteMetadata),
            "Unrelated EXIF metadata must not reject otherwise safe thumbnail dimensions"
        )

        var largeButDownsampleable = valid
        largeButDownsampleable[kCGImagePropertyPixelWidth] = NSNumber(value: 8_000)
        largeButDownsampleable[kCGImagePropertyPixelHeight] = NSNumber(value: 6_000)
        XCTAssertTrue(ChekinanaImageSourceValidator.accepts(
            properties: largeButDownsampleable
        ))

        var decompressionBomb = valid
        decompressionBomb[kCGImagePropertyPixelWidth] = NSNumber(value: 32_768)
        decompressionBomb[kCGImagePropertyPixelHeight] = NSNumber(value: 32_768)
        XCTAssertFalse(ChekinanaImageSourceValidator.accepts(
            properties: decompressionBomb
        ))

        var zeroHeight = valid
        zeroHeight[kCGImagePropertyPixelHeight] = NSNumber(value: 0)
        XCTAssertFalse(ChekinanaImageSourceValidator.accepts(properties: zeroHeight))

        var excessivePixels = valid
        excessivePixels[kCGImagePropertyPixelWidth] = NSNumber(value: 20_000)
        excessivePixels[kCGImagePropertyPixelHeight] = NSNumber(value: 20_000)
        XCTAssertFalse(ChekinanaImageSourceValidator.accepts(properties: excessivePixels))
    }

    func testThumbnailWorkerRejectsMalformedDataAndInvalidDimensions() async {
        let validImage = scannerPNGData(color: .purple)
        let malformedImage = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])

        let malformed = await ChekinanaImageWorker.thumbnailData(
            from: malformedImage,
            maxDimension: 256
        )
        let zeroDimension = await ChekinanaImageWorker.thumbnailData(
            from: validImage,
            maxDimension: 0
        )
        let excessiveDimension = await ChekinanaImageWorker.thumbnailImage(
            from: validImage,
            maxDimension: ChekinanaImageSourceValidator.maximumThumbnailDimension + 1
        )

        XCTAssertNil(malformed)
        XCTAssertNil(zeroDimension)
        XCTAssertNil(excessiveDimension)
    }

    func testBoundedImageDownloaderReturnsValidImageAndRemovesTemporaryFile() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://catalogue.test/avatar"))
        let payload = scannerPNGData(color: .purple)
        let temporaryURL = try temporaryDownloadFile(data: payload)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "image/png",
                "Content-Length": "\(payload.count)",
            ]
        ))
        let downloader = ChekinanaBoundedRemoteImageDownloader { _ in
            (temporaryURL, response)
        }

        let result = try await downloader.data(for: URLRequest(url: requestURL))

        XCTAssertEqual(result, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testBoundedImageDownloaderRejectsHTTPAndContentTypeFailures() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://catalogue.test/avatar"))

        let httpFile = try temporaryDownloadFile(data: Data([0x01]))
        let httpResponse = try XCTUnwrap(HTTPURLResponse(
            url: requestURL,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        ))
        let httpDownloader = ChekinanaBoundedRemoteImageDownloader { _ in
            (httpFile, httpResponse)
        }
        do {
            _ = try await httpDownloader.data(for: URLRequest(url: requestURL))
            XCTFail("expected invalid HTTP response")
        } catch {
            XCTAssertEqual(
                error as? ChekinanaBoundedRemoteImageDownloader.DownloadError,
                .invalidResponse
            )
        }

        let contentFile = try temporaryDownloadFile(data: Data([0x01]))
        let contentResponse = try XCTUnwrap(HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        ))
        let contentDownloader = ChekinanaBoundedRemoteImageDownloader { _ in
            (contentFile, contentResponse)
        }
        do {
            _ = try await contentDownloader.data(for: URLRequest(url: requestURL))
            XCTFail("expected invalid content type")
        } catch {
            XCTAssertEqual(
                error as? ChekinanaBoundedRemoteImageDownloader.DownloadError,
                .invalidContentType
            )
        }
    }

    func testBoundedImageDownloaderPropagatesPACDNSAndTimeoutFailures() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://catalogue.test/avatar"))
        for expectedCode in [URLError.cannotFindHost, .timedOut] {
            let downloader = ChekinanaBoundedRemoteImageDownloader { _ in
                throw URLError(expectedCode)
            }
            do {
                _ = try await downloader.data(for: URLRequest(url: requestURL))
                XCTFail("expected URL loading failure")
            } catch let error as URLError {
                XCTAssertEqual(error.code, expectedCode)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBoundedImageDownloaderCancellationReleasesStalledRequest() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://catalogue.test/avatar"))
        let downloader = ChekinanaBoundedRemoteImageDownloader { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw URLError(.timedOut)
        }
        let startedAt = Date()
        let task = Task {
            try await downloader.data(for: URLRequest(url: requestURL))
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected. URLSession's native async API follows this same
            // cancellation contract when its delegate never produces data.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testNativeImageDownloadCancellationReleasesNeverCallbackProtocol() async throws {
        let requestURL = try XCTUnwrap(URL(string: "https://catalogue.test/never-callback"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaNeverCompletingURLProtocol.self]
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        let downloader = ChekinanaBoundedRemoteImageDownloader(
            session: URLSession(configuration: configuration)
        )
        let startedAt = Date()
        let task = Task {
            try await downloader.data(for: URLRequest(url: requestURL))
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: URLProtocol deliberately never calls its client.
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testQueuedDecodeCancellationReturnsImmediatelyAndReleasesLargeCapture() async throws {
        let gate = ChekinanaBlockingDecodeGate()
        let first = Task.detached {
            await ChekinanaImageWorker.testingPerformDecode {
                gate.blockingValue(1)
            }
        }
        let second = Task.detached {
            await ChekinanaImageWorker.testingPerformDecode {
                gate.blockingValue(2)
            }
        }
        let blockersStarted = await gate.waitForStarted(count: 2, timeout: 2)
        XCTAssertTrue(blockersStarted)

        let deinitProbe = ChekinanaAtomicCounter()
        var largeCapture: ChekinanaLargeDecodeCapture? = .init(
            byteCount: 8 * 1_024 * 1_024,
            deinitProbe: deinitProbe
        )
        weak let weakCapture = largeCapture
        let queued = chekinanaQueuedDecodeTask(capture: try XCTUnwrap(largeCapture))
        largeCapture = nil
        for _ in 0..<200 where ChekinanaImageWorker.testingDecodeOperationCount < 3 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertGreaterThanOrEqual(ChekinanaImageWorker.testingDecodeOperationCount, 3)

        let cancelledAt = Date()
        queued.cancel()
        let queuedValue = await queued.value

        XCTAssertNil(queuedValue)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.2)
        for _ in 0..<100 where weakCapture != nil {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNil(weakCapture)
        XCTAssertEqual(deinitProbe.value(), 1)

        gate.release(count: 2)
        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertEqual(Set([firstValue, secondValue].compactMap { $0 }), Set([1, 2]))
        for _ in 0..<100 where ChekinanaImageWorker.testingDecodeOperationCount != 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(ChekinanaImageWorker.testingDecodeOperationCount, 0)
    }

    func testDecodeCancelBeforeContinuationInstallReturnsNilWithoutExecutingCapture() async throws {
        let executionProbe = ChekinanaAtomicCounter()
        let deinitProbe = ChekinanaAtomicCounter()
        var largeCapture: ChekinanaLargeDecodeCapture? = .init(
            byteCount: 8 * 1_024 * 1_024,
            deinitProbe: deinitProbe
        )
        weak let weakCapture = largeCapture
        let task = Task { [largeCapture] in
            await ChekinanaImageWorker.testingPerformDecode {
                executionProbe.increment()
                return largeCapture?.data.count ?? 0
            }
        }
        largeCapture = nil

        // This task inherits MainActor and cannot begin until this test yields.
        task.cancel()
        let value = await task.value

        XCTAssertNil(value)
        XCTAssertEqual(executionProbe.value(), 0)
        for _ in 0..<100 where weakCapture != nil {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNil(weakCapture)
        XCTAssertEqual(deinitProbe.value(), 1)
    }

    func testDecodeCompletionAndCancellationRaceResumesExactlyOnce() async throws {
        var cancellationWins = 0
        var completionWins = 0
        for index in 0..<10 {
            let gate = ChekinanaBlockingDecodeGate()
            let task = Task.detached {
                await ChekinanaImageWorker.testingPerformDecode {
                    gate.blockingValue(index)
                }
            }
            let operationStarted = await gate.waitForStarted(count: 1, timeout: 2)
            XCTAssertTrue(operationStarted)
            if index.isMultiple(of: 2) {
                task.cancel()
                gate.release(count: 1)
            } else {
                gate.release(count: 1)
                chekinanaTestBlockingSleep(0.01)
                task.cancel()
            }
            let value = await task.value
            if value == nil {
                cancellationWins += 1
            } else {
                XCTAssertEqual(value, index)
                completionWins += 1
            }
        }
        XCTAssertGreaterThan(cancellationWins, 0)
        XCTAssertGreaterThan(completionWins, 0)
        XCTAssertEqual(ChekinanaImageWorker.testingDecodeOperationCount, 0)
    }

    func testNineAvatarThumbnailBatchCompletesResponsivelyAndPreservesOrder() async {
        let colors: [UIColor] = [
            .red, .green, .blue, .orange, .purple, .cyan, .brown, .magenta, .yellow,
        ]
        let images = colors.map { scannerPNGData(color: $0) }
        let startedAt = Date()

        let thumbnails = await ChekinanaImageWorker.thumbnailDataBatch(
            from: images,
            maxDimension: 256
        )

        XCTAssertEqual(thumbnails.count, images.count)
        XCTAssertTrue(thumbnails.allSatisfy { data in
            guard let data else { return false }
            return UIImage(data: data) != nil
        })
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
    }

    func testIdolFavoriteDefaultsFalseAndRoundTripsTrue() throws {
        let defaultIdol = Idol(name: "Default")
        XCTAssertFalse(defaultIdol.isFavorite)

        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let writeContext = ModelContext(container)
        let favorite = Idol(name: "Favorite", isFavorite: true)
        writeContext.insert(favorite)
        try writeContext.save()

        let favoriteID = favorite.id
        let readContext = ModelContext(container)
        let fetched = try XCTUnwrap(readContext.fetch(FetchDescriptor<Idol>(
            predicate: #Predicate { $0.id == favoriteID }
        )).first)
        XCTAssertTrue(fetched.isFavorite)
    }

    func testThumbnailReferenceCacheKeyChangesForNilAndReplacementRefs() {
        let nilKey = ChekinanaThumbnailCache.referenceCacheKey(
            kind: "managed-ref",
            imageRef: nil,
            sourceKey: "idol-1",
            maxDimension: 256
        )
        let firstKey = ChekinanaThumbnailCache.referenceCacheKey(
            kind: "managed-ref",
            imageRef: "avatar-a.jpg",
            sourceKey: "idol-1",
            maxDimension: 256
        )
        let replacementKey = ChekinanaThumbnailCache.referenceCacheKey(
            kind: "managed-ref",
            imageRef: "avatar-b.jpg",
            sourceKey: "idol-1",
            maxDimension: 256
        )
        XCTAssertNotEqual(nilKey, firstKey)
        XCTAssertNotEqual(firstKey, replacementKey)
        XCTAssertEqual(
            firstKey,
            ChekinanaThumbnailCache.referenceCacheKey(
                kind: "managed-ref",
                imageRef: "  avatar-a.jpg  ",
                sourceKey: "idol-1",
                maxDimension: 256
            )
        )
    }

    func testClearAllLocalDataDeletesRecordsAndManagedFilesButProtectsSibling() throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Clear me", isFavorite: true)
        let event = Event(name: "Clear event")
        let cheki = Cheki(idols: [idol], event: event, date: Date(), idx: 1)
        let shame = Shame(idols: [idol], note: "clear image")
        let douga = Douga(idols: [idol], note: "clear video")
        context.insert(idol)
        context.insert(event)
        context.insert(cheki)
        context.insert(shame)
        context.insert(douga)
        try context.save()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-clear-\(UUID().uuidString)", isDirectory: true)
        let managed = root.appendingPathComponent("ChekiImages", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = managed.appendingPathComponent("\(cheki.id.uuidString).jpg")
        let second = managed.appendingPathComponent(
            ChekinanaIdolReferenceStore.managedFilename(idolID: idol.id)
        )
        let sibling = root.appendingPathComponent("keep.txt")
        try Data([0x01]).write(to: first)
        try Data([0x02]).write(to: second)
        try Data([0x03]).write(to: sibling)

        let suiteName = "ChekinanaClearTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(ChekinanaPresetSeedPolicy.isSuppressed(defaults: defaults))
        let restoreID = UUID()
        let restoreRef = try ChekinanaGalleryMediaStore.saveImage(
            scannerPNGData(color: .blue),
            id: restoreID,
            filenameExtension: "png",
            directory: managed
        )
        let restoreStage = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
            kind: .shame,
            id: restoreID,
            reference: restoreRef,
            directory: managed
        )
        ChekinanaGalleryMediaStore.recordRestoreRecovery(
            restoreStage,
            directory: managed,
            defaults: defaults
        )
        let orphanID = UUID()
        let orphanRef = try ChekinanaGalleryMediaStore.saveImage(
            scannerPNGData(color: .red),
            id: orphanID,
            filenameExtension: "png",
            directory: managed
        )
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .shame,
            id: orphanID,
            reference: orphanRef,
            defaults: defaults
        )

        let result = try ChekinanaLocalDataClearer.clear(
            modelContext: context,
            managedImagesDirectory: managed,
            defaults: defaults
        )

        XCTAssertEqual(result, .init(
            chekiCount: 1,
            shameCount: 1,
            dougaCount: 1,
            eventCount: 1,
            idolCount: 1,
            removedFileCount: 4
        ))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Cheki>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Shame>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Douga>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Event>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingRestoreRecoveryCount(defaults: defaults),
            0
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(ChekinanaPresetSeedPolicy.isSuppressed(defaults: defaults))
        XCTAssertFalse(ChekinanaPresetSeedPolicy.shouldSeed(environment: [:], defaults: defaults))
        XCTAssertTrue(ChekinanaPresetSeedPolicy.shouldSeed(
            environment: ["CHEKINANA_UI_RESET_STORE": "1"],
            defaults: defaults
        ))
    }

    func testClearAllLocalDataDeletesHiddenQuarantineButSkipsHiddenSymlinkAndDirectory() throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-clear-hidden-\(UUID().uuidString)", isDirectory: true)
        let managed = root.appendingPathComponent("ChekiImages", isDirectory: true)
        let hiddenDirectory = managed.appendingPathComponent(".hidden-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let quarantine = managed.appendingPathComponent(".delete-test.quarantine")
        let outsideTarget = root.appendingPathComponent("outside-target.jpg")
        let hiddenSymlink = managed.appendingPathComponent(".hidden-link.jpg")
        let nestedFile = hiddenDirectory.appendingPathComponent("nested.jpg")
        try Data([0x01]).write(to: quarantine)
        try Data([0x02]).write(to: outsideTarget)
        try Data([0x03]).write(to: nestedFile)
        try FileManager.default.createSymbolicLink(
            at: hiddenSymlink,
            withDestinationURL: outsideTarget
        )

        let suiteName = "ChekinanaClearHiddenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let result = try ChekinanaLocalDataClearer.clear(
            modelContext: context,
            managedImagesDirectory: managed,
            defaults: defaults
        )

        XCTAssertEqual(result.removedFileCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenSymlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideTarget.path))
    }

    func testClearAllLocalDataDatabaseFailurePreservesFilesAndSeedPolicy() throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Keep")
        context.insert(idol)
        try context.save()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-clear-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keep.jpg")
        try Data([0x01]).write(to: file)
        let suiteName = "ChekinanaClearFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertThrowsError(try ChekinanaLocalDataClearer.clear(
            modelContext: context,
            managedImagesDirectory: directory,
            defaults: defaults,
            saveContext: { _ in throw NSError(domain: "test.database", code: 1) }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("No data was cleared"))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(ChekinanaPresetSeedPolicy.isSuppressed(defaults: defaults))
    }

    func testClearAllLocalDataFileFailureKeepsClearedDatabaseAndSuppression() throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.insert(Idol(name: "Cleared despite file failure"))
        try context.save()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-clear-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphanID = UUID()
        let orphanReference = "shame-\(orphanID.uuidString.lowercased()).png"
        let file = directory.appendingPathComponent(orphanReference)
        try Data([0x01]).write(to: file)
        let suiteName = "ChekinanaClearPartialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .shame,
            id: orphanID,
            reference: orphanReference,
            defaults: defaults
        )

        XCTAssertThrowsError(try ChekinanaLocalDataClearer.clear(
            modelContext: context,
            managedImagesDirectory: directory,
            defaults: defaults,
            removeFile: { _ in throw NSError(domain: "test.files", code: 2) }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("All local records were cleared"))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(ChekinanaPresetSeedPolicy.isSuppressed(defaults: defaults))
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingRestoreRecoveryCount(defaults: defaults),
            0
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            1
        )
    }

    func testShameAndDougaRoundTripAndUnifiedGalleryOrderingSearch() throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Airi")
        let event = Event(name: "Summer Live")
        let older = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-02"))
        let newer = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-03"))
        let cheki = Cheki(idols: [idol], event: event, date: older, isFavorite: true)
        let shame = Shame(
            imageRef: "shame.jpg",
            idols: [idol],
            date: newer,
            note: "phone photo"
        )
        let douga = Douga(
            videoRef: "douga.mov",
            idols: [idol],
            date: nil,
            note: "encore video"
        )
        context.insert(idol)
        context.insert(event)
        context.insert(cheki)
        context.insert(shame)
        context.insert(douga)
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Shame>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Douga>()), 1)
        let ordered = ChekinanaGalleryItem.ordered([
            .douga(douga),
            .cheki(cheki),
            .shame(shame),
        ])
        XCTAssertEqual(ordered.map(\.modelID), [shame.id, cheki.id, douga.id])
        XCTAssertTrue(ChekinanaGalleryItem.shame(shame).matches(query: "Airi"))
        XCTAssertFalse(ChekinanaGalleryItem.shame(shame).matches(query: "Summer"))
        XCTAssertTrue(ChekinanaGalleryItem.shame(shame).matches(query: "2026-08-03"))
        XCTAssertTrue(ChekinanaGalleryItem.douga(douga).matches(query: "encore"))
        XCTAssertTrue(ChekinanaGalleryItem.douga(douga).matches(query: "Douga"))
        XCTAssertTrue(ChekinanaGalleryItem.cheki(cheki).isFavoriteCheki)
        XCTAssertFalse(ChekinanaGalleryItem.shame(shame).isFavoriteCheki)
        XCTAssertFalse(ChekinanaGalleryItem.douga(douga).isFavoriteCheki)
    }

    func testLegacyMediaRelationshipsMigrateToExplicitManyToManySchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chekinana-media-schema-migration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("MigrationEvidence.store")
        XCTAssertTrue(storeURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))

        let firstIdolID = UUID()
        let secondIdolID = UUID()
        let eventID = UUID()
        let eventImageID = UUID()
        let chekiID = UUID()
        let legacyShameIDs = [UUID(), UUID()]
        let legacyDougaIDs = [UUID(), UUID()]
        let newShameIDs = [UUID(), UUID(), UUID()]
        let newDougaIDs = [UUID(), UUID(), UUID()]
        let chekiDate = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-01"))
        let mediaDate = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-02"))
        let idolCreatedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let idolUpdatedAt = Date(timeIntervalSince1970: 1_700_000_002)
        let eventCreatedAt = Date(timeIntervalSince1970: 1_700_000_003)
        let eventUpdatedAt = Date(timeIntervalSince1970: 1_700_000_004)
        let chekiCreatedAt = Date(timeIntervalSince1970: 1_700_000_005)
        let chekiUpdatedAt = Date(timeIntervalSince1970: 1_700_000_006)
        let legacySchema = Schema(versionedSchema: ChekinanaSchemaV1.self)

        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [ModelConfiguration(
                "MigrationEvidence",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(legacyContainer))
            let firstIdol = ChekinanaSchemaV1.Idol(
                id: firstIdolID,
                sourceId: "legacy-source-first",
                name: "Legacy First",
                group: "Legacy Group",
                color: "#123456",
                birthday: "2001-02-03",
                avatarImageRef: "legacy-first-avatar.jpg",
                isFavorite: true,
                sortOrder: 4.5,
                note: "first idol",
                createdAt: idolCreatedAt,
                updatedAt: idolUpdatedAt,
                verification: "verified",
                bio: "first bio",
                patterns: [[0.11, 0.22], [0.33, 0.44]]
            )
            firstIdol.pattern = [0.55, 0.66]
            let secondIdol = ChekinanaSchemaV1.Idol(
                id: secondIdolID,
                sourceId: "legacy-source-second",
                name: "Legacy Second",
                group: "Second Group",
                color: "#654321",
                birthday: "2004-05-06",
                avatarImageRef: "legacy-second-avatar.jpg",
                isFavorite: false,
                sortOrder: 9.5,
                note: "second idol",
                createdAt: idolCreatedAt.addingTimeInterval(10),
                updatedAt: idolUpdatedAt.addingTimeInterval(10),
                verification: "pending",
                bio: "second bio",
                patterns: [[0.77, 0.88]]
            )
            secondIdol.pattern = [0.99]
            let event = ChekinanaSchemaV1.Event(
                id: eventID,
                name: "Legacy Live",
                date: chekiDate,
                city: "Tokyo",
                livehouse: "Legacy House",
                avatarImageRef: "legacy-event-avatar.jpg",
                price: "¥3,500",
                weiboURL: URL(string: "https://example.com/weibo/legacy"),
                ticketURL: URL(string: "https://example.com/ticket/legacy"),
                note: "event note",
                createdAt: eventCreatedAt,
                updatedAt: eventUpdatedAt
            )
            event.legacyVenue = "Legacy Venue Column"
            let eventImage = EventImage(
                id: eventImageID,
                eventID: eventID,
                imageRef: "legacy-event-image.jpg",
                sortOrder: 7
            )
            context.insert(firstIdol)
            context.insert(secondIdol)
            context.insert(event)
            context.insert(eventImage)

            let cheki = ChekinanaSchemaV1.Cheki(
                id: chekiID,
                date: chekiDate,
                idx: 3,
                userAppears: true,
                sizeRawValue: ChekiSize.mini.rawValue,
                imageRef: "legacy-cheki.jpg",
                isFavorite: true,
                hasPostedToSNS: true,
                note: "legacy cheki",
                createdAt: chekiCreatedAt,
                updatedAt: chekiUpdatedAt
            )
            context.insert(cheki)
            cheki.idols = [firstIdol]
            cheki.event = event

            for (index, id) in legacyShameIDs.enumerated() {
                let record = ChekinanaSchemaV1.Shame(
                    id: id,
                    imageRef: "legacy-shame-\(index).jpg",
                    date: mediaDate,
                    note: "legacy shame \(index)"
                )
                context.insert(record)
                record.idols = index == 0
                    ? [firstIdol, secondIdol]
                    : [firstIdol]
                record.event = event
            }
            for (index, id) in legacyDougaIDs.enumerated() {
                let record = ChekinanaSchemaV1.Douga(
                    id: id,
                    videoRef: "legacy-douga-\(index).mov",
                    date: mediaDate,
                    note: "legacy douga \(index)"
                )
                context.insert(record)
                record.idols = index == 0
                    ? [firstIdol, secondIdol]
                    : [firstIdol]
                record.event = event
            }
            try context.save()
        }
        legacyContainer = nil

        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: storeURL
        )
        let hashes = try XCTUnwrap(
            metadata[NSStoreModelVersionHashesKey] as? [String: Data]
        )
        XCTAssertEqual(
            Set(hashes.keys),
            Set(["Idol", "Event", "EventImage", "Cheki", "Shame", "Douga"])
        )
        let physicalStoreHashes = [
            "Cheki": "bdCVx3P7qmIxqC4jviUgmdCavBUMwJEtQb9bsrbVKSA=",
            "Douga": "mpjvu8329K/OXXcqnEU+NQMMx+3JMVC/kaR8UrHroR4=",
            "Event": "PxVMgOeNbq4+BBWESyqNQkt7RPL7zwiliJGfFSpOamQ=",
            "EventImage": "qpkUgZ6Azv0jsDbDk4+34d1ndj/9cGQNV0+d7lMCHzQ=",
            "Idol": "fmBENvaxQvBW1zgQk6+OB4SM1UdFrnqdw55IapAeaR4=",
            "Shame": "GyBNBAA8mo/+s1LDTA6XSMjTF0PStDQ4frSI+6395js=",
        ]
        XCTAssertEqual(
            hashes.mapValues { $0.base64EncodedString() },
            physicalStoreHashes,
            "The V1 fixture must remain byte-hash compatible with the retained pre-migration physical store metadata."
        )

        var legacyShameIdols = [UUID: Set<UUID>]()
        var legacyDougaIdols = [UUID: Set<UUID>]()
        legacyContainer = try ModelContainer(
            for: legacySchema,
            configurations: [ModelConfiguration(
                "MigrationEvidence",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(legacyContainer))
            let shames = try context.fetch(FetchDescriptor<ChekinanaSchemaV1.Shame>())
            let dougas = try context.fetch(FetchDescriptor<ChekinanaSchemaV1.Douga>())
            XCTAssertEqual(Set(shames.map(\.id)), Set(legacyShameIDs))
            XCTAssertEqual(Set(dougas.map(\.id)), Set(legacyDougaIDs))
            let legacyEvent = try XCTUnwrap(
                context.fetch(FetchDescriptor<ChekinanaSchemaV1.Event>()).first
            )
            XCTAssertEqual(Set(legacyEvent.shames.map(\.id)), Set(legacyShameIDs))
            XCTAssertEqual(Set(legacyEvent.dougas.map(\.id)), Set(legacyDougaIDs))
            legacyShameIdols = Dictionary(uniqueKeysWithValues: shames.map {
                ($0.id, Set($0.idols.map(\.id)))
            })
            legacyDougaIdols = Dictionary(uniqueKeysWithValues: dougas.map {
                ($0.id, Set($0.idols.map(\.id)))
            })
        }
        legacyContainer = nil

        let currentSchema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        func currentContainer() throws -> ModelContainer {
            try ModelContainer(
                for: currentSchema,
                migrationPlan: ChekinanaSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(
                    "MigrationEvidence",
                    schema: currentSchema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )]
            )
        }

        var migratedContainer: ModelContainer? = try currentContainer()
        do {
            let context = ModelContext(try XCTUnwrap(migratedContainer))
            let idolsByID = Dictionary(uniqueKeysWithValues:
                try context.fetch(FetchDescriptor<Idol>()).map { ($0.id, $0) }
            )
            let firstIdol = try XCTUnwrap(idolsByID[firstIdolID])
            XCTAssertEqual(firstIdol.sourceId, "legacy-source-first")
            XCTAssertEqual(firstIdol.name, "Legacy First")
            XCTAssertEqual(firstIdol.group, "Legacy Group")
            XCTAssertEqual(firstIdol.color, "#123456")
            XCTAssertEqual(firstIdol.birthday, "2001-02-03")
            XCTAssertEqual(firstIdol.avatarImageRef, "legacy-first-avatar.jpg")
            XCTAssertTrue(firstIdol.isFavorite)
            XCTAssertEqual(firstIdol.sortOrder, 4.5)
            XCTAssertEqual(firstIdol.note, "first idol")
            XCTAssertEqual(firstIdol.createdAt, idolCreatedAt)
            XCTAssertEqual(firstIdol.updatedAt, idolUpdatedAt)
            XCTAssertEqual(firstIdol.verification, "verified")
            XCTAssertEqual(firstIdol.bio, "first bio")
            XCTAssertEqual(firstIdol.pattern, [0.55, 0.66])
            XCTAssertEqual(firstIdol.patterns, [[0.11, 0.22], [0.33, 0.44]])

            let secondIdol = try XCTUnwrap(idolsByID[secondIdolID])
            XCTAssertEqual(secondIdol.sourceId, "legacy-source-second")
            XCTAssertEqual(secondIdol.name, "Legacy Second")
            XCTAssertEqual(secondIdol.group, "Second Group")
            XCTAssertEqual(secondIdol.color, "#654321")
            XCTAssertEqual(secondIdol.birthday, "2004-05-06")
            XCTAssertEqual(secondIdol.avatarImageRef, "legacy-second-avatar.jpg")
            XCTAssertFalse(secondIdol.isFavorite)
            XCTAssertEqual(secondIdol.sortOrder, 9.5)
            XCTAssertEqual(secondIdol.note, "second idol")
            XCTAssertEqual(secondIdol.createdAt, idolCreatedAt.addingTimeInterval(10))
            XCTAssertEqual(secondIdol.updatedAt, idolUpdatedAt.addingTimeInterval(10))
            XCTAssertEqual(secondIdol.verification, "pending")
            XCTAssertEqual(secondIdol.bio, "second bio")
            XCTAssertEqual(secondIdol.pattern, [0.99])
            XCTAssertEqual(secondIdol.patterns, [[0.77, 0.88]])

            let event = try XCTUnwrap(context.fetch(FetchDescriptor<Event>()).first)
            XCTAssertEqual(event.id, eventID)
            XCTAssertEqual(event.name, "Legacy Live")
            XCTAssertEqual(event.date, chekiDate)
            XCTAssertEqual(event.city, "Tokyo")
            XCTAssertEqual(event.livehouse, "Legacy House")
            XCTAssertEqual(event.legacyVenue, "Legacy Venue Column")
            XCTAssertEqual(event.avatarImageRef, "legacy-event-avatar.jpg")
            XCTAssertEqual(event.price, "¥3,500")
            XCTAssertEqual(event.weiboURL, URL(string: "https://example.com/weibo/legacy"))
            XCTAssertEqual(event.ticketURL, URL(string: "https://example.com/ticket/legacy"))
            XCTAssertEqual(event.note, "event note")
            XCTAssertEqual(event.createdAt, eventCreatedAt)
            XCTAssertEqual(event.updatedAt, eventUpdatedAt)

            let eventImage = try XCTUnwrap(
                context.fetch(FetchDescriptor<EventImage>()).first
            )
            XCTAssertEqual(eventImage.id, eventImageID)
            XCTAssertEqual(eventImage.eventID, eventID)
            XCTAssertEqual(eventImage.imageRef, "legacy-event-image.jpg")
            XCTAssertEqual(eventImage.sortOrder, 7)

            let cheki = try XCTUnwrap(context.fetch(FetchDescriptor<Cheki>()).first)
            XCTAssertEqual(cheki.id, chekiID)
            XCTAssertEqual(Set(cheki.idols.map(\.id)), [firstIdolID])
            XCTAssertEqual(cheki.event?.id, eventID)
            XCTAssertEqual(cheki.date, chekiDate)
            XCTAssertEqual(cheki.idx, 3)
            XCTAssertEqual(cheki.userAppears, true)
            XCTAssertEqual(cheki.size, .mini)
            XCTAssertEqual(cheki.imageRef, "legacy-cheki.jpg")
            XCTAssertTrue(cheki.isFavorite)
            XCTAssertTrue(cheki.hasPostedToSNS)
            XCTAssertEqual(cheki.note, "legacy cheki")
            XCTAssertEqual(cheki.createdAt, chekiCreatedAt)
            XCTAssertEqual(cheki.updatedAt, chekiUpdatedAt)
            XCTAssertEqual(Set(event.chekis.map(\.id)), [chekiID])

            let migratedShames = try context.fetch(FetchDescriptor<Shame>())
            let migratedDougas = try context.fetch(FetchDescriptor<Douga>())
            XCTAssertEqual(Set(migratedShames.map(\.id)), Set(legacyShameIDs))
            XCTAssertEqual(Set(migratedDougas.map(\.id)), Set(legacyDougaIDs))
            for record in migratedShames {
                XCTAssertEqual(Set(record.idols.map(\.id)), legacyShameIdols[record.id])
                XCTAssertEqual(record.imageRef, "legacy-shame-\(legacyShameIDs.firstIndex(of: record.id)!).jpg")
                XCTAssertEqual(record.date, mediaDate)
                XCTAssertEqual(record.note, "legacy shame \(legacyShameIDs.firstIndex(of: record.id)!)")
            }
            for record in migratedDougas {
                XCTAssertEqual(Set(record.idols.map(\.id)), legacyDougaIdols[record.id])
                XCTAssertEqual(record.videoRef, "legacy-douga-\(legacyDougaIDs.firstIndex(of: record.id)!).mov")
                XCTAssertEqual(record.date, mediaDate)
                XCTAssertEqual(record.note, "legacy douga \(legacyDougaIDs.firstIndex(of: record.id)!)")
            }

            for (index, id) in newShameIDs.enumerated() {
                let record = Shame(
                    id: id,
                    imageRef: "new-shame-\(index).jpg",
                    date: mediaDate,
                    note: "new shame \(index)"
                )
                context.insert(record)
                record.idols = index == 2 ? [firstIdol, secondIdol] : [firstIdol]
            }
            for (index, id) in newDougaIDs.enumerated() {
                let record = Douga(
                    id: id,
                    videoRef: "new-douga-\(index).mov",
                    date: mediaDate,
                    note: "new douga \(index)"
                )
                context.insert(record)
                record.idols = index == 2 ? [firstIdol, secondIdol] : [firstIdol]
            }
            try context.save()
        }
        migratedContainer = nil

        migratedContainer = try currentContainer()
        do {
            let context = ModelContext(try XCTUnwrap(migratedContainer))
            let shames = try context.fetch(FetchDescriptor<Shame>())
            let dougas = try context.fetch(FetchDescriptor<Douga>())
            XCTAssertTrue(newShameIDs.allSatisfy { id in
                shames.first(where: { $0.id == id })?.idols.contains(where: {
                    $0.id == firstIdolID
                }) == true
            })
            XCTAssertTrue(newDougaIDs.allSatisfy { id in
                dougas.first(where: { $0.id == id })?.idols.contains(where: {
                    $0.id == firstIdolID
                }) == true
            })
            XCTAssertEqual(
                Set(shames.first(where: { $0.id == newShameIDs[2] })?.idols.map(\.id) ?? []),
                [firstIdolID, secondIdolID]
            )
            XCTAssertEqual(
                Set(dougas.first(where: { $0.id == newDougaIDs[2] })?.idols.map(\.id) ?? []),
                [firstIdolID, secondIdolID]
            )
            let firstIdol = try XCTUnwrap(
                context.fetch(FetchDescriptor<Idol>()).first { $0.id == firstIdolID }
            )
            XCTAssertTrue(Set(newShameIDs).isSubset(of: Set(firstIdol.shames.map(\.id))))
            XCTAssertTrue(Set(newDougaIDs).isSubset(of: Set(firstIdol.dougas.map(\.id))))
            context.delete(firstIdol)
            try context.save()
        }
        migratedContainer = nil

        let deleteCheckContainer = try currentContainer()
        let deleteContext = ModelContext(deleteCheckContainer)
        for record in try deleteContext.fetch(FetchDescriptor<Shame>()) {
            XCTAssertFalse(record.idols.contains { $0.id == firstIdolID })
        }
        for record in try deleteContext.fetch(FetchDescriptor<Douga>()) {
            XCTAssertFalse(record.idols.contains { $0.id == firstIdolID })
        }
        XCTAssertEqual(
            Set(try deleteContext.fetch(FetchDescriptor<Shame>())
                .first(where: { $0.id == newShameIDs[2] })?.idols.map(\.id) ?? []),
            [secondIdolID]
        )
        XCTAssertEqual(
            Set(try deleteContext.fetch(FetchDescriptor<Douga>())
                .first(where: { $0.id == newDougaIDs[2] })?.idols.map(\.id) ?? []),
            [secondIdolID]
        )
    }

    func testDataStoreOpenFailureReturnsRecoveryStateAndRetryCanSucceed() throws {
        enum ExpectedOpenError: Error { case failed }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chekinana-datastore-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: directory,
            legacyStoreName: "Original.store",
            namespace: "recovery-test"
        )

        let failed = ChekinanaDataStore.openPreservingStoreFamily(paths: paths) { _ in
            throw ExpectedOpenError.failed
        }
        guard case .failure(let failure) = failed else {
            return XCTFail("A persistent open error must not create an empty fallback container.")
        }
        XCTAssertEqual(failure.code, ChekinanaDataStore.OpenFailure.stableCode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.activeMarkerURL.path))

        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let retried = ChekinanaDataStore.openPreservingStoreFamily(paths: paths) { candidateURL in
            try ModelContainer(
                for: schema,
                migrationPlan: ChekinanaSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(
                    "RecoveryTest",
                    schema: schema,
                    url: candidateURL,
                    cloudKitDatabase: .none
                )]
            )
        }
        guard case .success(let container) = retried else {
            return XCTFail("Retry must publish the successfully reopened container.")
        }
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<Cheki>()),
            0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.activeMarkerURL.path))
    }

    func testCurrentV4ActiveStoreReopensInPlaceWithoutCopyOrRotation() throws {
        enum UnexpectedCopy: Error { case invoked }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "chekinana-datastore-direct-open-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: directory) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: directory,
            legacyStoreName: "Original.store",
            namespace: "direct-open-test"
        )
        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        func diskContainer(at url: URL) throws -> ModelContainer {
            try ModelContainer(
                for: schema,
                migrationPlan: ChekinanaSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(
                    "DirectOpenTest",
                    schema: schema,
                    url: url,
                    cloudKitDatabase: .none
                )]
            )
        }

        var createdContainer: ModelContainer?
        let created = ChekinanaDataStore.openPreservingStoreFamily(paths: paths) { url in
            let container = try diskContainer(at: url)
            createdContainer = container
            return container
        }
        guard case .success = created else {
            return XCTFail("Initial activation must publish a V4 marker.")
        }
        let retainedChekiID = UUID()
        let createdContext = ModelContext(try XCTUnwrap(createdContainer))
        createdContext.insert(Cheki(id: retainedChekiID, note: "direct-open sentinel"))
        try createdContext.save()
        createdContainer = nil
        let activeURL = try XCTUnwrap(
            ChekinanaDataStore.currentActiveStoreURL(paths: paths)
        )
        let markerBefore = try Data(contentsOf: paths.activeMarkerURL)
        let directoryNamesBefore = try Set(fileManager.contentsOfDirectory(
            atPath: paths.candidateRootURL.path
        ))

        for _ in 0..<3 {
            var openedURL: URL?
            var reopenedContainer: ModelContainer?
            let reopened = ChekinanaDataStore.openPreservingStoreFamily(
                paths: paths,
                copyStore: { _, _, _ in throw UnexpectedCopy.invoked }
            ) { url in
                openedURL = url
                let container = try diskContainer(at: url)
                reopenedContainer = container
                return container
            }
            guard case .success = reopened else {
                return XCTFail("A valid V4 active store must not depend on copying.")
            }
            XCTAssertEqual(openedURL?.standardizedFileURL, activeURL.standardizedFileURL)
            XCTAssertEqual(try Data(contentsOf: paths.activeMarkerURL), markerBefore)
            XCTAssertEqual(
                try ModelContext(try XCTUnwrap(reopenedContainer))
                    .fetch(FetchDescriptor<Cheki>())
                    .first(where: { $0.id == retainedChekiID })?.note,
                "direct-open sentinel"
            )
            XCTAssertEqual(
                try Set(fileManager.contentsOfDirectory(atPath: paths.candidateRootURL.path)),
                directoryNamesBefore,
                "Repeated cold opens must not create or rotate candidates."
            )
            reopenedContainer = nil
        }
    }

    func testFailedMigrationRetriesBoundDiagnosticsAndPreserveAuthoritativeFamily() throws {
        enum ExpectedMigrationFailure: Error { case failed }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "chekinana-datastore-bounded-failures-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: directory,
            legacyStoreName: "Original.store",
            namespace: "bounded-failure-test"
        )
        let legacyFamily = [
            (paths.legacyStoreURL, Data("legacy-main".utf8)),
            (URL(fileURLWithPath: paths.legacyStoreURL.path + "-wal"), Data("legacy-wal".utf8)),
            (URL(fileURLWithPath: paths.legacyStoreURL.path + "-shm"), Data("legacy-shm".utf8)),
        ]
        for (url, data) in legacyFamily {
            try data.write(to: url)
        }
        let unknownDirectory = paths.candidateRootURL
            .appendingPathComponent("manual-backup", isDirectory: true)
        try fileManager.createDirectory(
            at: unknownDirectory,
            withIntermediateDirectories: true
        )
        try Data("do-not-delete".utf8).write(
            to: unknownDirectory.appendingPathComponent("current.store")
        )

        for _ in 0..<5 {
            let result = ChekinanaDataStore.openPreservingStoreFamily(
                paths: paths,
                copyStore: { source, destination, manager in
                    try manager.copyItem(at: source, to: destination)
                    let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
                    try manager.copyItem(
                        at: sourceWAL,
                        to: URL(fileURLWithPath: destination.path + "-wal")
                    )
                    try Data("failed-shm".utf8).write(
                        to: URL(fileURLWithPath: destination.path + "-shm")
                    )
                }
            ) { _ in
                throw ExpectedMigrationFailure.failed
            }
            guard case .failure = result else {
                return XCTFail("Injected migration failure must not activate a candidate.")
            }
            XCTAssertFalse(fileManager.fileExists(atPath: paths.activeMarkerURL.path))
            for (url, expected) in legacyFamily {
                XCTAssertEqual(try Data(contentsOf: url), expected)
            }
            XCTAssertTrue(fileManager.fileExists(atPath: unknownDirectory.path))

            let managed = try fileManager.contentsOfDirectory(
                at: paths.candidateRootURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { url in
                guard url.lastPathComponent.hasPrefix("store-") else { return false }
                return UUID(uuidString: String(url.lastPathComponent.dropFirst(6))) != nil
            }
            XCTAssertEqual(managed.count, 1, "Only the newest diagnostic candidate may remain.")
            let failedStore = managed[0].appendingPathComponent("current.store")
            XCTAssertTrue(fileManager.fileExists(atPath: failedStore.path))
            XCTAssertTrue(fileManager.fileExists(atPath: failedStore.path + "-wal"))
            XCTAssertTrue(fileManager.fileExists(atPath: failedStore.path + "-shm"))
        }
    }

    func testMissingCarrierFailsMigrationAndPreservesOriginalStoreFamily() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chekinana-missing-carrier-migration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("MissingCarrier.store")
        let bridgeSchema = Schema(versionedSchema: ChekinanaSchemaBridge.self)
        let existingIdolID = UUID()
        let missingIdolID = UUID()
        let shameID = UUID()

        var bridgeContainer: ModelContainer? = try ModelContainer(
            for: bridgeSchema,
            configurations: [ModelConfiguration(
                "MissingCarrier",
                schema: bridgeSchema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(bridgeContainer))
            let idol = ChekinanaSchemaBridge.Idol(
                id: existingIdolID,
                name: "Existing Idol"
            )
            context.insert(idol)
            let shame = ChekinanaSchemaBridge.Shame(
                id: shameID,
                migrationIdolIDs: [existingIdolID, missingIdolID],
                note: "must survive failed migration"
            )
            context.insert(shame)
            shame.legacyIdols = [idol]
            try context.save()
        }
        bridgeContainer = nil

        let familyURLs = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        let before = try Dictionary(uniqueKeysWithValues: familyURLs.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })

        let currentSchema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: directory,
            legacyStoreName: storeURL.lastPathComponent,
            namespace: "missing-carrier"
        )
        let migrationResult = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths
        ) { candidateURL in
            try ModelContainer(
                for: currentSchema,
                migrationPlan: ChekinanaSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(
                    "MissingCarrier",
                    schema: currentSchema,
                    url: candidateURL,
                    cloudKitDatabase: .none
                )]
            )
        }
        guard case .failure = migrationResult else {
            return XCTFail("An unresolved carrier must fail before activation.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.activeMarkerURL.path))

        for url in familyURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(
                try Data(contentsOf: url),
                before[url.lastPathComponent],
                "A failed relationship repair must leave every original store file unchanged."
            )
        }

        bridgeContainer = try ModelContainer(
            for: bridgeSchema,
            configurations: [ModelConfiguration(
                "MissingCarrier",
                schema: bridgeSchema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let bridgeContext = ModelContext(try XCTUnwrap(bridgeContainer))
        let surviving = try XCTUnwrap(
            bridgeContext.fetch(FetchDescriptor<ChekinanaSchemaBridge.Shame>())
                .first(where: { $0.id == shameID })
        )
        XCTAssertEqual(surviving.note, "must survive failed migration")
        XCTAssertEqual(surviving.migrationIdolIDs, [existingIdolID, missingIdolID])
        XCTAssertEqual(Set(surviving.legacyIdols.map(\.id)), [existingIdolID])
    }

    func testRelationshipRepairRejectsDuplicateAndUnresolvedCarrierIDs() throws {
        let idolID = UUID()
        let first = ChekinanaSchemaRelationshipRepair.Idol(
            id: idolID,
            name: "First"
        )
        let duplicate = ChekinanaSchemaRelationshipRepair.Idol(
            id: idolID,
            name: "Duplicate"
        )
        XCTAssertThrowsError(
            try ChekinanaSchemaMigrationPlan.strictIdolMap([first, duplicate])
        ) { error in
            XCTAssertEqual(
                error as? ChekinanaMigrationIntegrityError,
                .duplicateIdolID
            )
        }

        let idolsByID = try ChekinanaSchemaMigrationPlan.strictIdolMap([first])
        XCTAssertThrowsError(
            try ChekinanaSchemaMigrationPlan.resolveCarrierIdols(
                [idolID, idolID],
                idolsByID: idolsByID
            )
        ) { error in
            XCTAssertEqual(
                error as? ChekinanaMigrationIntegrityError,
                .duplicateCarrierIdolID
            )
        }
        XCTAssertThrowsError(
            try ChekinanaSchemaMigrationPlan.resolveCarrierIdols(
                [UUID()],
                idolsByID: idolsByID
            )
        ) { error in
            XCTAssertEqual(
                error as? ChekinanaMigrationIntegrityError,
                .missingCarrierIdol
            )
        }
        XCTAssertEqual(
            try ChekinanaSchemaMigrationPlan.resolveCarrierIdols(
                [idolID],
                idolsByID: idolsByID
            ).map(\.id),
            [idolID]
        )
    }

    func testRecordCommandsRejectNoMediaCreationAndStillEditLegacyRecords() async throws {
        let fixture = try makeFixture()
        let firstIdol = Idol(name: "First")
        let secondIdol = Idol(name: "Second")
        fixture.context.insert(firstIdol)
        fixture.context.insert(secondIdol)
        let legacyShame = Shame(note: "legacy")
        let legacyDouga = Douga(note: "legacy")
        fixture.context.insert(legacyShame)
        fixture.context.insert(legacyDouga)
        legacyShame.idols = [firstIdol]
        legacyDouga.idols = [firstIdol]
        try fixture.context.save()

        let confirmationCount = fixture.ledger.activeConfirmationCodes.count
        for (kind, expected) in [
            ("shame", ChekinanaMediaBackedCreationError.shameRequiresImage),
            ("douga", ChekinanaMediaBackedCreationError.dougaRequiresVideo),
        ] {
            let rejected = await fixture.executor.execute(
                "addrecord \(kind) idols=\(shortID(firstIdol.id)) date=2026-08-08 note=new"
            )
            XCTAssertTrue(text(from: rejected).contains(expected.localizedDescription))
            XCTAssertEqual(fixture.ledger.activeConfirmationCodes.count, confirmationCount)
        }
        for kind in ["shame", "douga"] {
            let typed = ChekinanaNLOperation(
                intent: .addrecord,
                slots: .init(note: "typed", recordType: kind)
            )
            guard case .commands(let commands) = ChekinanaConversationCoordinator.compile(
                [typed],
                modelContext: fixture.context
            ), let command = commands.first else {
                return XCTFail("expected typed \(kind) plan to reach the executor boundary")
            }
            let rejected = await fixture.executor.execute(command)
            let expected = kind == "shame"
                ? ChekinanaMediaBackedCreationError.shameRequiresImage
                : ChekinanaMediaBackedCreationError.dougaRequiresVideo
            XCTAssertTrue(text(from: rejected).contains(expected.localizedDescription))
            XCTAssertEqual(fixture.ledger.activeConfirmationCodes.count, confirmationCount)
        }

        let staleCode = fixture.ledger.insert(.mutateRecord(.init(
            kind: .shame,
            mutation: .add,
            expectedFingerprint: nil,
            idolIDs: [firstIdol.id],
            eventID: nil,
            date: utcDate(2026, 8, 8),
            idx: nil,
            note: "stale payload",
            userAppears: nil,
            favorite: false,
            size: nil
        )))
        let staleConfirmation = await fixture.executor.execute("confirm \(staleCode)")
        XCTAssertTrue(text(from: staleConfirmation).contains(
            ChekinanaMediaBackedCreationError.shameRequiresImage.localizedDescription
        ))
        XCTAssertNotNil(fixture.ledger.entry(for: staleCode))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Shame>()), 1)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Douga>()), 1)

        guard case .confirmationText(_, let editCode) = await fixture.executor.execute(
            "editrecord shame target=\(shortID(legacyShame.id)) idols=\(shortID(firstIdol.id)),\(shortID(secondIdol.id))"
        ) else {
            return XCTFail("expected multi-Idol edit confirmation")
        }
        try requireSuccess(await fixture.executor.execute("confirm \(editCode)"))
        XCTAssertEqual(Set(legacyShame.idols.map(\.id)), [firstIdol.id, secondIdol.id])

        guard case .confirmationText(_, let deleteCode) = await fixture.executor.execute(
            "deleterecord douga target=\(shortID(legacyDouga.id))"
        ) else {
            return XCTFail("expected legacy no-media Douga delete confirmation")
        }
        try requireSuccess(await fixture.executor.execute("confirm \(deleteCode)"))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Douga>()), 0)
    }

    func testGalleryManagedMediaResolverQuarantineAndStagingCleanupAreContained() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-gallery-media-\(UUID().uuidString)", isDirectory: true)
        let managed = root.appendingPathComponent("ChekiImages", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let reference = try ChekinanaGalleryMediaStore.saveImage(
            scannerPNGData(color: .magenta),
            id: id,
            filenameExtension: "png",
            directory: managed
        )
        let original = try XCTUnwrap(ChekinanaGalleryMediaStore.managedURL(
            for: reference,
            id: id,
            kind: .shame,
            directory: managed
        ))
        XCTAssertNil(ChekinanaGalleryMediaStore.managedURL(
            for: reference,
            id: UUID(),
            kind: .shame,
            directory: managed
        ))
        XCTAssertNil(ChekinanaGalleryMediaStore.managedURL(
            for: "../outside.jpg",
            id: id,
            kind: .shame,
            directory: managed
        ))
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.thumbnailURL(id: id, directory: managed),
            ChekinanaGalleryMediaStore.thumbnailURL(id: id, directory: managed)
        )

        let firstStage = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
            kind: .shame,
            id: id,
            reference: reference,
            directory: managed
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        try ChekinanaGalleryMediaStore.restoreStagedFiles(firstStage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))

        let secondStage = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
            kind: .shame,
            id: id,
            reference: reference,
            directory: managed
        )
        let suiteName = "ChekinanaGalleryCleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        ChekinanaGalleryMediaStore.recordCommittedDeletion(
            secondStage,
            directory: managed,
            defaults: defaults
        )
        ChekinanaGalleryMediaStore.cleanupCommittedDeletions(
            directory: managed,
            defaults: defaults
        )
        XCTAssertTrue(secondStage.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.quarantine.path)
        })

        let source = root.appendingPathComponent("source.mov")
        try Data([0x00, 0x01, 0x02]).write(to: source)
        let stagedVideo = try ChekinanaGalleryMediaStore.makeStagedVideoCopy(from: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedVideo.path))
        ChekinanaGalleryMediaStore.cleanupStagedImports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMediaBackedGalleryShameAndDougaRemainPersistable() throws {
        let fixture = try makeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-gallery-media-backed-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shameID = UUID()
        let shameRef = try ChekinanaGalleryMediaStore.saveImage(
            scannerPNGData(color: .purple),
            id: shameID,
            filenameExtension: "png",
            directory: directory
        )
        let dougaID = UUID()
        let dougaRef = "douga-\(dougaID.uuidString.lowercased()).mov"
        try Data("local-video".utf8).write(
            to: directory.appendingPathComponent(dougaRef)
        )
        let shame = Shame(id: shameID, imageRef: shameRef)
        let douga = Douga(id: dougaID, videoRef: dougaRef)
        fixture.context.insert(shame)
        fixture.context.insert(douga)
        try fixture.context.save()

        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<Shame>()).first?.imageRef,
            shameRef
        )
        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<Douga>()).first?.videoRef,
            dougaRef
        )
    }

    func testGalleryRestoreRecoveryQueueSurvivesFailureAndLaunchRetryWithoutCommittedCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-restore-recovery-\(UUID().uuidString)", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "ChekinanaGalleryRestore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let id = UUID()
        let reference = try ChekinanaGalleryMediaStore.saveImage(
            scannerPNGData(color: .cyan),
            id: id,
            filenameExtension: "png",
            directory: managed
        )
        let staged = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
            kind: .shame,
            id: id,
            reference: reference,
            directory: managed
        )
        ChekinanaGalleryMediaStore.recordRestoreRecovery(
            staged,
            directory: managed,
            defaults: defaults
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingRestoreRecoveryCount(defaults: defaults),
            1
        )
        XCTAssertThrowsError(
            try ChekinanaGalleryMediaStore.restoreStagedFiles(staged) { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        )

        ChekinanaGalleryMediaStore.recordCommittedDeletion(
            staged,
            directory: managed,
            defaults: defaults
        )
        ChekinanaGalleryMediaStore.cleanupCommittedDeletions(
            directory: managed,
            defaults: defaults
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged[0].quarantine.path))

        let outsideOriginal = outside.appendingPathComponent(reference)
        let outsideQuarantine = outside.appendingPathComponent(
            ".delete-\(UUID().uuidString.lowercased())-\(reference)"
        )
        ChekinanaGalleryMediaStore.recordRestoreRecovery(
            [(outsideOriginal, outsideQuarantine)],
            directory: managed,
            defaults: defaults
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingRestoreRecoveryCount(defaults: defaults),
            1,
            "Out-of-directory pairs must never enter the recovery queue"
        )

        XCTAssertFalse(ChekinanaGalleryMediaStore.cleanupRestoreRecoveries(
            directory: managed,
            defaults: defaults,
            moveItem: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        ))
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingRestoreRecoveryCount(defaults: defaults),
            1
        )
        XCTAssertTrue(ChekinanaGalleryMediaStore.cleanupRestoreRecoveries(
            directory: managed,
            defaults: defaults
        ))
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingRestoreRecoveryCount(defaults: defaults),
            0
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: managed.appendingPathComponent(reference).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged[0].quarantine.path))
    }

    func testGalleryImportCleanupQueueRetriesShameDougaAndThumbnailWithoutEscapingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-orphan-cleanup-\(UUID().uuidString)", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "ChekinanaGalleryOrphan.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let shameID = UUID()
        let shameRef = try ChekinanaGalleryMediaStore.saveImage(
            scannerPNGData(color: .magenta),
            id: shameID,
            filenameExtension: "png",
            directory: managed
        )
        let dougaID = UUID()
        let dougaRef = "douga-\(dougaID.uuidString.lowercased()).mov"
        let dougaURL = managed.appendingPathComponent(dougaRef)
        let thumbnailURL = ChekinanaGalleryMediaStore.thumbnailURL(
            id: dougaID,
            directory: managed
        )
        try Data([0x01]).write(to: dougaURL)
        try scannerPNGData(color: .yellow).write(to: thumbnailURL)

        XCTAssertThrowsError(try ChekinanaGalleryMediaStore.removeFiles(
            kind: .shame,
            id: shameID,
            reference: shameRef,
            directory: managed,
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
        ))
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .shame,
            id: shameID,
            reference: shameRef,
            defaults: defaults
        )
        XCTAssertThrowsError(try ChekinanaGalleryMediaStore.removeFiles(
            kind: .douga,
            id: dougaID,
            reference: dougaRef,
            directory: managed,
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
        ))
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .douga,
            id: dougaID,
            reference: dougaRef,
            defaults: defaults
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            3
        )
        ChekinanaGalleryMediaStore.cleanupOrphanedImports(
            directory: managed,
            defaults: defaults,
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            3
        )
        ChekinanaGalleryMediaStore.cleanupOrphanedImports(
            directory: managed,
            defaults: defaults
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            0
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.appendingPathComponent(shameRef).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dougaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
    }

    func testStagedVideoCopyRejectsZeroAndOversizeBeforeCopyAndAllowsBoundary() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-video-size-\(UUID().uuidString).mov")
        try Data([0x01]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var copyCount = 0
        let copy: (URL, URL) throws -> Void = { source, destination in
            copyCount += 1
            try FileManager.default.copyItem(at: source, to: destination)
        }
        XCTAssertThrowsError(try ChekinanaGalleryMediaStore.makeStagedVideoCopy(
            from: source,
            fileSize: { _ in 0 },
            copyItem: copy
        ))
        XCTAssertThrowsError(try ChekinanaGalleryMediaStore.makeStagedVideoCopy(
            from: source,
            fileSize: { _ in 2 * 1_024 * 1_024 * 1_024 + 1 },
            copyItem: copy
        ))
        XCTAssertEqual(copyCount, 0)

        let staged = try ChekinanaGalleryMediaStore.makeStagedVideoCopy(
            from: source,
            fileSize: { _ in 2 * 1_024 * 1_024 * 1_024 },
            copyItem: copy
        )
        XCTAssertEqual(copyCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        ChekinanaGalleryMediaStore.discardStagedVideo(at: staged)
    }

    func testGalleryStagedImageAndManagedCopyUseBackgroundFileIO() async throws {
        let managed = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "gallery-staged-image-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: managed,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: managed) }

        let ranOnMainThread = try await ChekinanaGalleryMediaStore.performFileIO {
            Thread.isMainThread
        }
        XCTAssertFalse(ranOnMainThread)

        let staged = try await ChekinanaGalleryMediaStore.makeStagedImageCopy(
            from: scannerPNGData(color: .orange),
            filenameExtension: "png"
        )
        XCTAssertEqual(
            staged.deletingLastPathComponent().lastPathComponent,
            "ChekinanaGalleryImports"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        let id = UUID()
        let reference = try await ChekinanaGalleryMediaStore.saveImage(
            from: staged,
            id: id,
            filenameExtension: "png",
            directory: managed
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: managed.appendingPathComponent(reference).path
        ))

        await ChekinanaGalleryMediaStore.discardStagedImport(at: staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testGalleryImportGatesPreventDuplicateWorkAndStaleRequestCompletion() {
        var once = ChekinanaGalleryImportOnceGate()
        let draftID = UUID()
        XCTAssertTrue(once.claim(draftID))
        XCTAssertFalse(once.claim(draftID))
        XCTAssertTrue(once.claim(UUID()))

        var requests = ChekinanaGalleryImportRequestGate()
        let first = requests.begin()
        let second = requests.begin()
        XCTAssertFalse(requests.isCurrent(first))
        XCTAssertFalse(requests.finish(first))
        XCTAssertTrue(requests.isCurrent(second))
        XCTAssertTrue(requests.finish(second))
        XCTAssertNil(requests.activeID)

        XCTAssertTrue(ChekinanaGalleryImportEditorTeardownPolicy.shouldCancelImport(
            didFinish: false
        ))
        XCTAssertFalse(ChekinanaGalleryImportEditorTeardownPolicy.shouldCancelImport(
            didFinish: true
        ))
        let previewDraftID = UUID()
        XCTAssertTrue(ChekinanaGalleryImportPreviewPolicy.shouldPrepare(
            preparedDraftID: nil,
            draftID: previewDraftID
        ))
        XCTAssertFalse(ChekinanaGalleryImportPreviewPolicy.shouldPrepare(
            preparedDraftID: previewDraftID,
            draftID: previewDraftID
        ))
        XCTAssertTrue(ChekinanaGalleryImportPreviewPolicy.shouldPrepare(
            preparedDraftID: previewDraftID,
            draftID: UUID()
        ))
    }

    func testDirectProcessingPhaseHasSpecificWholeChekiProgressText() {
        XCTAssertEqual(
            ChekinanaScannerPhasePresentation.text(
                "direct_processing",
                directInputEnabled: true
            ),
            "正在规范化整张 Cheki"
        )
        XCTAssertNotEqual(
            ChekinanaScannerPhasePresentation.text(
                "direct_processing",
                directInputEnabled: true
            ),
            "后端处理中"
        )
    }

    func testScanReviewSourceRegistryPreservesMixedOrderAndDeletesLatestCameraRepeatedly() {
        let libraryA = UUID()
        let cameraA = UUID()
        let libraryB = UUID()
        let cameraB = UUID()
        var registry = ChekinanaScanReviewSourceRegistry(sources: [
            .init(id: libraryA, origin: .library),
            .init(id: cameraA, origin: .camera),
            .init(id: libraryB, origin: .library),
            .init(id: cameraB, origin: .camera),
        ])
        XCTAssertEqual(registry.sourceIDs, [libraryA, cameraA, libraryB, cameraB])
        XCTAssertTrue(registry.hasCapturedPhoto)

        var mappedResults: [UUID: [UUID]] = [
            cameraA: [UUID(), UUID()],
            cameraB: [],
        ]
        let first = registry.removeLatestCapturedPhoto { mappedResults[$0] }
        guard case .removed(let firstSource, let firstResults) = first else {
            return XCTFail("expected the newest zero-result camera source")
        }
        XCTAssertEqual(firstSource, cameraB)
        XCTAssertTrue(firstResults.isEmpty)
        mappedResults[cameraB] = nil

        let second = registry.removeLatestCapturedPhoto { mappedResults[$0] }
        guard case .removed(let secondSource, let secondResults) = second else {
            return XCTFail("expected the remaining camera source")
        }
        XCTAssertEqual(secondSource, cameraA)
        XCTAssertEqual(secondResults.count, 2)
        XCTAssertFalse(registry.hasCapturedPhoto)
        XCTAssertEqual(registry.sourceIDs, [libraryA, libraryB])
        XCTAssertEqual(
            registry.removeLatestCapturedPhoto { _ in [] },
            .unavailable
        )
    }

    func testBoundedScanPipelineKeepsHighResolutionLoadAndProcessingWindowsAtTwo() async throws {
        var retainedLoadedSources = 0
        var maximumRetainedSources = 0
        var processorInFlight = 0
        var maximumProcessorsInFlight = 0
        let windows = try await ChekinanaBoundedScanPipeline.run(
            inputs: Array(0..<7),
            load: { value, _ in
                retainedLoadedSources += 1
                maximumRetainedSources = max(maximumRetainedSources, retainedLoadedSources)
                if value == 3 {
                    retainedLoadedSources -= 1
                    throw ScannerMockError.failed
                }
                return Data(repeating: UInt8(value), count: 128)
            },
            process: { loaded, _ in
                processorInFlight += 1
                maximumProcessorsInFlight = max(maximumProcessorsInFlight, processorInFlight)
                XCTAssertLessThanOrEqual(loaded.count, 2)
                retainedLoadedSources -= loaded.count
                processorInFlight -= 1
                return loaded.count
            }
        )

        XCTAssertEqual(windows.map(\.sourceRange), [0..<2, 2..<4, 4..<6, 6..<7])
        XCTAssertEqual(windows.reduce(0) { $0 + $1.loadFailureCount }, 1)
        XCTAssertLessThanOrEqual(maximumRetainedSources, 2)
        XCTAssertEqual(maximumProcessorsInFlight, 1)
        XCTAssertEqual(retainedLoadedSources, 0)
    }

    func testBoundedScanPipelinePreservesOriginalIndexAfterEarlierLoadFailure() async throws {
        var processedOriginalIndices: [[Int]] = []
        let windows = try await ChekinanaBoundedScanPipeline.run(
            inputs: ["first", "second", "third"],
            load: { value, originalIndex in
                if originalIndex == 0 { throw ScannerMockError.failed }
                return value
            },
            process: { loadedItems, _ in
                processedOriginalIndices.append(loadedItems.map(\.originalIndex))
                return loadedItems.map(\.value)
            }
        )

        XCTAssertEqual(processedOriginalIndices, [[1], [2]])
        XCTAssertEqual(windows.map(\.loadFailureCount), [1, 0])
        XCTAssertEqual(windows.compactMap(\.output), [["second"], ["third"]])
    }

    func testBoundedScanProgressUsesOriginalSourceAndMonotonicCrossWindowTotals() {
        var translator = ChekinanaBoundedScanProgressTranslator()
        let secondSource = [ChekinanaBoundedScanLoadedItem(originalIndex: 1, value: "second")]
        let firstWindow = translator.translate(
            ChekinanaScanProgress(
                sourceIndex: 1,
                sourceCount: 1,
                publishedResultCount: 3,
                downloadedResultCount: 2,
                preparedResultCount: 1,
                stage: .generatingPreview
            ),
            loadedItems: secondSource,
            totalSourceCount: 4
        )
        let staleFirstWindowCallback = translator.translate(
            ChekinanaScanProgress(
                sourceIndex: 1,
                sourceCount: 1,
                publishedResultCount: 2,
                downloadedResultCount: 1,
                preparedResultCount: 0,
                stage: .generatingPreview
            ),
            loadedItems: secondSource,
            totalSourceCount: 4
        )
        XCTAssertEqual(firstWindow.sourceIndex, 2)
        XCTAssertEqual(firstWindow.sourceCount, 4)
        XCTAssertEqual(staleFirstWindowCallback.publishedResultCount, 3)
        XCTAssertEqual(staleFirstWindowCallback.downloadedResultCount, 2)
        XCTAssertEqual(staleFirstWindowCallback.preparedResultCount, 1)

        translator.completeWindow()
        let fourthSource = [ChekinanaBoundedScanLoadedItem(originalIndex: 3, value: "fourth")]
        let secondWindow = translator.translate(
            ChekinanaScanProgress(
                sourceIndex: 1,
                sourceCount: 1,
                publishedResultCount: 1,
                downloadedResultCount: 1,
                preparedResultCount: 1,
                stage: .generatingPreview
            ),
            loadedItems: fourthSource,
            totalSourceCount: 4
        )
        XCTAssertEqual(secondWindow.sourceIndex, 4)
        XCTAssertEqual(secondWindow.publishedResultCount, 4)
        XCTAssertEqual(secondWindow.downloadedResultCount, 3)
        XCTAssertEqual(secondWindow.preparedResultCount, 2)
    }

    func testReviewProtectionPreventsCrossWindowEvictionAndReconcilesGhostCards() async throws {
        let ledger = ChekinanaConfirmationLedger(maximumTemporaryChekiBytes: 10)
        let firstSourceID = UUID()
        let inputs = [
            ChekinanaPendingChekiImage(
                data: Data(repeating: 0x1, count: 6),
                filenameExtension: "jpg",
                sourceID: firstSourceID,
                sourceOrigin: .camera
            ),
            ChekinanaPendingChekiImage(
                data: Data(repeating: 0x2, count: 6),
                filenameExtension: "jpg",
                sourceID: UUID(),
                sourceOrigin: .library
            ),
        ]
        var aggregatedCards: [ChekinanaChekiCard] = []
        var warningCount = 0
        let windows = try await ChekinanaBoundedScanPipeline.run(
            inputs: inputs,
            windowSize: 1,
            load: { image, _ in image },
            process: { loadedItems, _ in
                do {
                    let insertion = try ledger.insertTemporaryChekis(
                        loadedItems.map(\.value),
                        thumbnailImageData: Array(repeating: nil, count: loadedItems.count)
                    )
                    let cards = insertion.inserted.map { temporary in
                        ChekinanaChekiCard(
                            id: temporary.id,
                            imageRef: nil,
                            createdAt: temporary.createdAt,
                            confirmationCode: nil,
                            thumbnailImageData: nil
                        )
                    }
                    ledger.protectTemporaryChekisForReview(cards.map(\.id))
                    aggregatedCards.append(contentsOf: cards)
                    return cards.count
                } catch {
                    warningCount += 1
                    return 0
                }
            }
        )
        XCTAssertEqual(windows.compactMap(\.output), [1, 0])
        XCTAssertEqual(warningCount, 1)
        let first = try XCTUnwrap(ledger.temporaryCheki(aggregatedCards[0].id))
        XCTAssertTrue(ledger.isTemporaryChekiProtectedForReview(first.id))
        XCTAssertTrue(ledger.containsTemporaryCheki(first.id))

        let ghostCard = ChekinanaChekiCard(
            id: UUID(),
            imageRef: nil,
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: nil
        )
        XCTAssertEqual(
            ChekinanaScanReviewCardReconciler.existing(
                aggregatedCards + [ghostCard],
                containsTemporaryCheki: ledger.containsTemporaryCheki
            ).map(\.id),
            [first.id]
        )

        XCTAssertEqual(ledger.discardTemporaryChekis(sourceID: firstSourceID), [first.id])
        XCTAssertFalse(ledger.isTemporaryChekiProtectedForReview(first.id))
        XCTAssertFalse(ledger.containsTemporaryCheki(first.id))
    }

    func testCapturedPhotoStorePreservesFullResolutionBytesWithoutReencoding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-camera-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = UUID()
        let original = scannerPNGData(color: .systemPink)

        let photo = try ChekinanaCapturedPhotoStore.save(
            original,
            filenameExtension: "heic",
            id: sourceID,
            directory: directory
        )

        XCTAssertEqual(try ChekinanaCapturedPhotoStore.load(photo, directory: directory), original)
        XCTAssertEqual(photo.filenameExtension, "heic")
        XCTAssertEqual(photo.fileURL.deletingLastPathComponent(), directory)
        XCTAssertFalse(photo.fileURL.path.contains("ChekiImages"))
        ChekinanaCapturedPhotoStore.remove(photo, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.fileURL.path))
    }

    func testNativeScanInputRotationNormalizesAndReconcileRetainsPerSourceState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-input-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = UUID()
        let secondID = UUID()
        let firstPhoto = try ChekinanaCapturedPhotoStore.save(
            scannerJPEGDataWithOrientation(1),
            filenameExtension: "jpg",
            id: firstID,
            directory: directory
        )
        let secondPhoto = try ChekinanaCapturedPhotoStore.save(
            scannerJPEGData(color: .purple),
            filenameExtension: "jpg",
            id: secondID,
            directory: directory
        )
        let first = ChekinanaNativeScanInput(
            id: firstID,
            payload: .camera(firstPhoto),
            rotationQuarterTurns: 5
        )
        let second = ChekinanaNativeScanInput(
            id: secondID,
            payload: .camera(secondPhoto),
            rotationQuarterTurns: -1
        )
        XCTAssertEqual(first.rotationQuarterTurns, 1)
        XCTAssertEqual(first.nextCounterclockwiseRotationQuarterTurns, 2)
        XCTAssertEqual(second.rotationQuarterTurns, 3)
        XCTAssertEqual(second.nextCounterclockwiseRotationQuarterTurns, 0)

        let retained = ChekinanaNativeScanInputReconciler.retainedInputs(
            existing: [first, second],
            retainedIDs: [firstID],
            origin: .camera,
            isDirect: false
        )
        XCTAssertEqual(retained.map(\.id), [firstID])
        XCTAssertEqual(retained.first?.rotationQuarterTurns, 1)
    }

    func testInputRotationRegistryGatesStartAndMutationsUntilMatchingCommitOrFailure() {
        let firstID = UUID()
        let secondID = UUID()
        let firstToken = UUID()
        let secondToken = UUID()
        var registry = ChekinanaNativeScanInputRotationRegistry()
        XCTAssertTrue(registry.allowsInputMutation(
            isProcessing: false,
            hasReviewSession: false
        ))
        XCTAssertEqual(registry.begin(
            sourceID: firstID,
            expectedQuarterTurns: 0,
            token: firstToken
        ), firstToken)
        XCTAssertFalse(registry.allowsInputMutation(
            isProcessing: false,
            hasReviewSession: false
        ))
        XCTAssertTrue(registry.hasInFlightRotations)
        XCTAssertTrue(registry.isRotating(sourceID: firstID))
        XCTAssertNil(registry.begin(
            sourceID: firstID,
            expectedQuarterTurns: 0
        ))
        XCTAssertEqual(registry.begin(
            sourceID: secondID,
            expectedQuarterTurns: 2,
            token: secondToken
        ), secondToken)
        XCTAssertFalse(registry.commit(
            sourceID: firstID,
            token: UUID(),
            currentQuarterTurns: 0,
            newQuarterTurns: 1
        ))
        XCTAssertTrue(registry.isRotating(sourceID: firstID))
        XCTAssertTrue(registry.commit(
            sourceID: firstID,
            token: firstToken,
            currentQuarterTurns: 0,
            newQuarterTurns: 1
        ))
        XCTAssertFalse(registry.isRotating(sourceID: firstID))
        XCTAssertTrue(registry.hasInFlightRotations)
        XCTAssertFalse(registry.fail(sourceID: secondID, token: UUID()))
        XCTAssertTrue(registry.isRotating(sourceID: secondID))
        XCTAssertTrue(registry.fail(sourceID: secondID, token: secondToken))
        XCTAssertFalse(registry.hasInFlightRotations)
        XCTAssertTrue(registry.allowsInputMutation(
            isProcessing: false,
            hasReviewSession: false
        ))
        XCTAssertFalse(registry.allowsInputMutation(
            isProcessing: true,
            hasReviewSession: false
        ))
        XCTAssertFalse(registry.allowsInputMutation(
            isProcessing: false,
            hasReviewSession: true
        ))
    }

    func testInputRotationRegistryRejectsStaleRevisionWithoutReleasingTransaction() {
        let sourceID = UUID()
        let token = UUID()
        var registry = ChekinanaNativeScanInputRotationRegistry()
        XCTAssertEqual(registry.begin(
            sourceID: sourceID,
            expectedQuarterTurns: 1,
            token: token
        ), token)
        XCTAssertFalse(registry.commit(
            sourceID: sourceID,
            token: token,
            currentQuarterTurns: 2,
            newQuarterTurns: 3
        ))
        XCTAssertTrue(registry.hasInFlightRotations)
        XCTAssertTrue(registry.fail(sourceID: sourceID, token: token))
        XCTAssertFalse(registry.hasInFlightRotations)
    }

    func testInputLoaderAppliesRotationOnlyToSelectedSourceAndFourTurnsRestoreOriginal() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstData = scannerJPEGDataWithOrientation(1)
        let secondData = scannerJPEGData(color: .purple, size: CGSize(width: 24, height: 40))
        let firstPhoto = try ChekinanaCapturedPhotoStore.save(
            firstData,
            filenameExtension: "jpg",
            id: firstID
        )
        let secondPhoto = try ChekinanaCapturedPhotoStore.save(
            secondData,
            filenameExtension: "jpg",
            id: secondID
        )
        defer {
            ChekinanaCapturedPhotoStore.remove(firstPhoto)
            ChekinanaCapturedPhotoStore.remove(secondPhoto)
        }
        let rotatedInput = ChekinanaNativeScanInput(
            id: firstID,
            payload: .camera(firstPhoto),
            rotationQuarterTurns: 1
        )
        let untouchedInput = ChekinanaNativeScanInput(
            id: secondID,
            payload: .camera(secondPhoto)
        )
        let rotated = try await ChekinanaProductMediaLoader.load(rotatedInput)
        let untouched = try await ChekinanaProductMediaLoader.load(untouchedInput)
        XCTAssertEqual(rotated.sourceID, firstID)
        XCTAssertEqual(rotated.sourceOrigin, .camera)
        XCTAssertEqual(untouched.data, secondData)
        XCTAssertEqual(untouched.sourceID, secondID)
        XCTAssertNotEqual(
            try quadrantColorLabels(rotated.data),
            try quadrantColorLabels(firstData)
        )
        XCTAssertEqual(
            try quadrantColorLabels(rotated.data),
            [1, 3, 0, 2],
            "One Input rotation must move pixels 90° counterclockwise."
        )
        let previewValue = await ChekinanaImageWorker.thumbnailImage(
            from: firstData,
            maxDimension: 240
        )
        let preview = try XCTUnwrap(previewValue)
        let rotatedPreview = try await ChekinanaProductMediaLoader
            .rotatePreviewCounterclockwise(preview)
        let rotatedPreviewData = try XCTUnwrap(
            UIImage(cgImage: rotatedPreview.cgImage).pngData()
        )
        XCTAssertEqual(
            try quadrantColorLabels(rotatedPreviewData),
            try quadrantColorLabels(rotated.data),
            "The thumbnail preview and processing loader must publish the same direction."
        )

        let fourTurns = try await ChekinanaProductMediaLoader
            .applyingCounterclockwiseRotation(
                to: ChekinanaPendingChekiImage(
                    data: firstData,
                    filenameExtension: "jpg",
                    sourceID: firstID,
                    sourceOrigin: .camera
                ),
                quarterTurns: 4
            )
        XCTAssertEqual(fourTurns.data, firstData)
        XCTAssertEqual(fourTurns.sourceID, firstID)
        XCTAssertEqual(
            try quadrantColorLabels(fourTurns.data),
            try quadrantColorLabels(firstData)
        )
    }

    func testInputRotationFailureAndCancellationDoNotPublishReplacement() async throws {
        let original = ChekinanaPendingChekiImage(
            data: scannerJPEGDataWithOrientation(1),
            filenameExtension: "jpg",
            sourceID: UUID(),
            sourceOrigin: .library
        )
        do {
            _ = try await ChekinanaProductMediaLoader
                .applyingCounterclockwiseRotation(
                to: .init(data: Data("invalid".utf8), filenameExtension: "jpg"),
                quarterTurns: 1
            )
            XCTFail("Invalid input rotation must fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertFalse(original.data.isEmpty)

        let cancelled = Task {
            try Task.checkCancellation()
            return try await ChekinanaProductMediaLoader
                .applyingCounterclockwiseRotation(
                to: original,
                quarterTurns: 1
            )
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled input rotation must not publish")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(original.sourceOrigin, .library)
    }

    func testScanCarriesSourceIdentityToMultipleTemporaryResultsInInputOrder() async throws {
        let libraryID = UUID()
        let cameraID = UUID()
        let resultA = scannerPNGData(color: .red)
        let resultB = scannerPNGData(color: .green)
        let resultC = scannerPNGData(color: .blue)
        let fixture = try makeFixture { image, _ in
            if image.sourceID == cameraID {
                return ChekinanaScannerProcessResult(
                    images: [resultB, resultC],
                    warningCount: 0
                )
            }
            return ChekinanaScannerProcessResult(images: [resultA], warningCount: 0)
        }
        let response = await fixture.executor.execute(
            "scancheki",
            pendingChekiImages: [
                ChekinanaPendingChekiImage(
                    data: resultA,
                    filenameExtension: "png",
                    sourceID: libraryID,
                    sourceOrigin: .library
                ),
                ChekinanaPendingChekiImage(
                    data: resultB,
                    filenameExtension: "png",
                    sourceID: cameraID,
                    sourceOrigin: .camera
                ),
            ]
        )
        guard case .chekiScannedCards(3, 0, let cards) = response else {
            return XCTFail("expected one library and two camera results")
        }
        let temporary = try cards.map {
            try fixture.ledger.resolveTemporaryCheki(shortID($0.id))
        }
        XCTAssertEqual(temporary.map(\.sourceID), [libraryID, cameraID, cameraID])
        XCTAssertEqual(temporary.map(\.sourceOrigin), [.library, .camera, .camera])
    }

    func testDeleteCapturedSourceIsAtomicWhenAnyResultHasConfirmationLock() throws {
        let fixture = try makeFixture()
        let sourceID = UUID()
        let image = ChekinanaPendingChekiImage(
            data: scannerPNGData(color: .orange),
            filenameExtension: "png",
            sourceID: sourceID,
            sourceOrigin: .camera
        )
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [image],
            thumbnailImageData: [nil],
            dates: [Date()]
        ).inserted[0]
        let payload = ChekinanaConfirmationLedger.AddChekiPayload(
            id: temporary.id,
            temporaryChekiID: temporary.id,
            image: temporary.image,
            thumbnailImageData: temporary.thumbnailImageData,
            idolIDs: [],
            eventID: nil,
            date: temporary.date,
            userAppears: nil,
            size: .mini,
            isFavorite: false,
            hasPostedToSNS: false,
            note: "",
            createdAt: Date(),
            requestedIdx: nil,
            existingChekiID: nil,
            explicitlyEditedFields: []
        )
        let code = fixture.ledger.insert(.addCheki(payload))
        var registry = ChekinanaScanReviewSourceRegistry(sources: [
            .init(id: sourceID, origin: .camera),
        ])

        XCTAssertEqual(
            registry.removeLatestCapturedPhoto(
                discardResults: fixture.ledger.discardTemporaryChekis
            ),
            .locked(sourceID: sourceID)
        )
        XCTAssertTrue(fixture.ledger.containsTemporaryCheki(temporary.id))
        XCTAssertTrue(registry.hasCapturedPhoto)
        XCTAssertTrue(fixture.ledger.cancel(code))
        guard case .removed(let removedSource, let removedIDs) = registry.removeLatestCapturedPhoto(
            discardResults: fixture.ledger.discardTemporaryChekis
        ) else {
            return XCTFail("expected complete removal after unlocking")
        }
        XCTAssertEqual(removedSource, sourceID)
        XCTAssertEqual(removedIDs, [temporary.id])
        XCTAssertFalse(fixture.ledger.containsTemporaryCheki(temporary.id))
    }

    func testSavePlanTargetsOnlyVisibleReviewCardsAndSuccessfulSessionClearsItsSources() async throws {
        let fixture = try makeFixture()
        let sourceIDs = [UUID(), UUID(), UUID()]
        let images = sourceIDs.enumerated().map { index, sourceID in
            ChekinanaPendingChekiImage(
                data: scannerPNGData(color: index == 0 ? .red : index == 1 ? .green : .blue),
                filenameExtension: "png",
                sourceID: sourceID,
                sourceOrigin: index == 1 ? .library : .camera
            )
        }
        let inserted = try fixture.ledger.insertTemporaryChekis(
            images,
            thumbnailImageData: [nil, nil, nil],
            dates: [Date(), Date(), Date()]
        ).inserted
        let visibleIDs = [inserted[0].id, inserted[2].id]
        let selection = try XCTUnwrap(ChekinanaScanReviewSavePlan.selection(
            cardIDs: visibleIDs,
            containsTemporaryCheki: fixture.ledger.containsTemporaryCheki
        ))
        XCTAssertEqual(selection, visibleIDs.map(\.uuidString).joined(separator: ","))

        let prepared = await fixture.executor.execute("addscancheki \(selection)")
        guard case .pendingChekiCards(_, let cards, _) = prepared else {
            return XCTFail("expected current review cards only")
        }
        let preparedTemporaryIDs: [UUID] = cards.compactMap(\.confirmationCode).compactMap { code -> UUID? in
            guard let entry = fixture.ledger.entry(for: code),
                  case .addCheki(let payload) = entry.action else { return nil }
            return payload.temporaryChekiID
        }
        XCTAssertEqual(preparedTemporaryIDs, visibleIDs)
        XCTAssertTrue(fixture.ledger.containsTemporaryCheki(inserted[1].id))
        fixture.ledger.cancelTemporaryChekiConfirmations(cards.compactMap(\.confirmationCode))

        var registry = ChekinanaScanReviewSourceRegistry(sources: sourceIDs.enumerated().map {
            .init(id: $0.element, origin: $0.offset == 1 ? .library : .camera)
        })
        registry.removeSources(ids: Set(registry.sourceIDs))
        XCTAssertTrue(registry.sources.isEmpty)
    }

    func testNoMediaPolicyTreatsNilEmptyAndWhitespaceReferencesEqually() {
        XCTAssertTrue(ChekinanaNoMediaPolicy.hasNoImage(nil))
        XCTAssertTrue(ChekinanaNoMediaPolicy.hasNoImage(""))
        XCTAssertTrue(ChekinanaNoMediaPolicy.hasNoImage(" \n\t "))
        XCTAssertFalse(ChekinanaNoMediaPolicy.hasNoImage("managed.jpg"))
    }

    func testBatchAttachOverwritesLegacyWhitespaceImageReference() async throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 9)
        let target = Cheki(date: date, imageRef: "  \n ")
        fixture.context.insert(target)
        try fixture.context.save()
        let code = try attachConfirmation(
            in: fixture,
            target: target,
            date: date,
            imageData: scannerPNGData(color: .purple)
        )

        guard case .chekiCards(let cards) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: [code]) else {
            return XCTFail("expected successful existing-record attachment")
        }

        XCTAssertEqual(cards.map(\.id), [target.id])
        XCTAssertNotNil(target.imageRef?.nonEmpty)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<Cheki>()).count, 1)
        cleanupManagedImages(in: fixture.context)
    }

    func testBatchAttachRejectsDuplicateReservationOfOneExistingRecord() async throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 9)
        let target = Cheki(date: date, imageRef: nil)
        fixture.context.insert(target)
        try fixture.context.save()
        let codes = try [UIColor.red, .blue].map { color in
            try attachConfirmation(
                in: fixture,
                target: target,
                date: date,
                imageData: scannerPNGData(color: color)
            )
        }

        guard case .text(let message) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: codes) else {
            return XCTFail("expected duplicate reservation rejection")
        }
        XCTAssertTrue(message.hasPrefix("error:"))
        XCTAssertTrue(ChekinanaNoMediaPolicy.hasNoImage(target.imageRef))
    }

    func testConcurrentBatchesLockSameExistingTargetBeforeAnySecondFileWrite() async throws {
        let limiter = ChekinanaRemoteRequestLimiter(limit: 1)
        let holderStarted = expectation(description: "hold image preparation")
        let holderRelease = ScannerReleaseGate()
        let holder = Task {
            try await limiter.perform {
                holderStarted.fulfill()
                await holderRelease.wait()
            }
        }
        await fulfillment(of: [holderStarted], timeout: 1)

        let fixture = try makeFixture(batchImagePreparationLimiter: limiter)
        let date = utcDate(2026, 8, 9)
        let target = Cheki(date: date, imageRef: nil)
        fixture.context.insert(target)
        try fixture.context.save()
        let firstCode = try attachConfirmation(
            in: fixture,
            target: target,
            date: date,
            imageData: scannerPNGData(color: .purple)
        )
        let secondCode = try attachConfirmation(
            in: fixture,
            target: target,
            date: date,
            imageData: scannerPNGData(color: .orange)
        )
        let first = Task {
            await fixture.executor.confirmTemporaryChekiBatch(
                confirmationCodes: [firstCode]
            )
        }
        let didReserveTarget = await waitForExistingTargetReservation(
            fixture.ledger,
            targetID: target.id
        )
        XCTAssertTrue(didReserveTarget)

        guard case .text(let rejection) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: [secondCode]) else {
            return XCTFail("a second batch must not reserve the same target")
        }
        XCTAssertTrue(rejection.hasPrefix("error:"))
        XCTAssertNil(ChekiImageRefResolver.managedChekiFileURL(
            for: target.imageRef,
            chekiID: target.id
        ))
        XCTAssertNotNil(fixture.ledger.entry(for: secondCode))

        await holderRelease.release()
        _ = try await holder.value
        guard case .chekiCards(let firstCards) = await first.value else {
            return XCTFail("the first reserved batch must remain saveable")
        }
        XCTAssertEqual(firstCards.map(\.id), [target.id])
        XCTAssertNotNil(ChekiImageRefResolver.managedChekiFileURL(
            for: target.imageRef,
            chekiID: target.id
        ))
        XCTAssertFalse(fixture.ledger.isTemporaryExistingChekiTargetReserved(target.id))
        XCTAssertNotNil(fixture.ledger.entry(for: secondCode))
        XCTAssertTrue(fixture.ledger.cancel(secondCode))
        cleanupManagedImages(in: fixture.context)
    }

    func testConcurrentBatchesAllowDifferentExistingTargets() async throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 9)
        let firstTarget = Cheki(date: date, imageRef: nil)
        let secondTarget = Cheki(date: date, imageRef: nil)
        fixture.context.insert(firstTarget)
        fixture.context.insert(secondTarget)
        try fixture.context.save()
        let firstCode = try attachConfirmation(
            in: fixture,
            target: firstTarget,
            date: date,
            imageData: scannerPNGData(color: .red)
        )
        let secondCode = try attachConfirmation(
            in: fixture,
            target: secondTarget,
            date: date,
            imageData: scannerPNGData(color: .blue)
        )

        let first = Task {
            await fixture.executor.confirmTemporaryChekiBatch(
                confirmationCodes: [firstCode]
            )
        }
        let second = Task {
            await fixture.executor.confirmTemporaryChekiBatch(
                confirmationCodes: [secondCode]
            )
        }
        let responses = await [first.value, second.value]
        XCTAssertTrue(responses.allSatisfy {
            if case .chekiCards = $0 { return true }
            return false
        })
        XCTAssertNotNil(firstTarget.imageRef?.nonEmpty)
        XCTAssertNotNil(secondTarget.imageRef?.nonEmpty)
        XCTAssertFalse(fixture.ledger.isTemporaryExistingChekiTargetReserved(firstTarget.id))
        XCTAssertFalse(fixture.ledger.isTemporaryExistingChekiTargetReserved(secondTarget.id))
        cleanupManagedImages(in: fixture.context)
    }

    func testLiveIndexValidationReassignsAutomaticIdxAfterSnapshotRace() async throws {
        let date = utcDate(2026, 8, 9)
        let legacySameDayDate = date.addingTimeInterval(12 * 60 * 60)
        let injector = ChekinanaBatchIndexRaceInjector(date: legacySameDayDate, idx: 1)
        let fixture = try makeFixture(batchBeforeLiveIndexValidation: {
            try injector.insertIfNeeded()
        })
        let idol = Idol(name: "Race Idol")
        fixture.context.insert(idol)
        try fixture.context.save()
        injector.configure(context: fixture.context, idol: idol)
        let pending = try newChekiConfirmation(
            in: fixture,
            idolIDs: [idol.id],
            date: date,
            requestedIdx: nil,
            idxIsExplicit: false
        )

        guard case .chekiCards(let cards) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: [pending.code]) else {
            return XCTFail("automatic idx must be replanned against live records")
        }
        XCTAssertEqual(cards.map(\.idx), [2])
        let records = try fixture.context.fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(records.first(where: { $0.id == pending.id })?.idx, 2)
        XCTAssertEqual(records.first(where: { $0.id == injector.insertedID })?.idx, 1)
        XCTAssertEqual(records.first(where: { $0.id == injector.insertedID })?.date, legacySameDayDate)
        cleanupManagedImages(in: fixture.context)
    }

    func testLiveIndexValidationRejectsExplicitCollisionWithoutDamage() async throws {
        let date = utcDate(2026, 8, 9)
        let legacySameDayDate = date.addingTimeInterval(18 * 60 * 60)
        let injector = ChekinanaBatchIndexRaceInjector(date: legacySameDayDate, idx: 1)
        let fixture = try makeFixture(batchBeforeLiveIndexValidation: {
            try injector.insertIfNeeded()
        })
        let idol = Idol(name: "Explicit Race Idol")
        fixture.context.insert(idol)
        try fixture.context.save()
        injector.configure(context: fixture.context, idol: idol)
        let pending = try newChekiConfirmation(
            in: fixture,
            idolIDs: [idol.id],
            date: date,
            requestedIdx: 1,
            idxIsExplicit: true
        )

        guard case .text(let rejection) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: [pending.code]) else {
            return XCTFail("a late explicit idx collision must reject before save")
        }
        XCTAssertTrue(rejection.hasPrefix("error:"))
        XCTAssertTrue(rejection.contains("idx #1 is already used"))
        XCTAssertNotNil(fixture.ledger.entry(for: pending.code))
        XCTAssertFalse(fixture.ledger.isTemporaryChekiBatchReserved(pending.code))
        XCTAssertNil(ChekiImageRefResolver.managedChekiFileURL(
            for: "\(pending.id.uuidString).png",
            chekiID: pending.id
        ))
        let records = try fixture.context.fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(records.map(\.id), [injector.insertedID])
        XCTAssertEqual(records.first?.idx, 1)
        XCTAssertEqual(records.first?.date, legacySameDayDate)
    }

    func testBatchLedgerReservationRejectsDuplicateInConstantTimeAndReleases() async throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 9)
        let target = Cheki(date: date, imageRef: nil)
        fixture.context.insert(target)
        try fixture.context.save()
        let code = try attachConfirmation(
            in: fixture,
            target: target,
            date: date,
            imageData: scannerPNGData(color: .purple)
        )
        let entry = try XCTUnwrap(fixture.ledger.entry(for: code))
        let reservation = try XCTUnwrap(
            fixture.ledger.reserveTemporaryChekiBatch([entry])
        )

        XCTAssertNil(fixture.ledger.reserveTemporaryChekiBatch([entry]))
        XCTAssertTrue(fixture.ledger.isTemporaryChekiBatchReserved(code))
        XCTAssertFalse(fixture.ledger.cancel(code))
        guard case .text(let reservedMessage) = await fixture.executor.execute(
            "confirm \(code)"
        ) else {
            return XCTFail("single confirmation must not bypass a live batch reservation")
        }
        XCTAssertTrue(reservedMessage.hasPrefix("error:"))
        XCTAssertTrue(
            fixture.ledger.releaseTemporaryChekiBatchReservation(reservation)
        )
        XCTAssertFalse(fixture.ledger.isTemporaryChekiBatchReserved(code))
        XCTAssertTrue(fixture.ledger.cancel(code))
    }

    func testBatchAttachRefetchRejectsTargetThatBecameMediaBacked() async throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 9)
        let target = Cheki(date: date, imageRef: nil)
        fixture.context.insert(target)
        try fixture.context.save()
        let code = try attachConfirmation(
            in: fixture,
            target: target,
            date: date,
            imageData: scannerPNGData(color: .green)
        )
        target.imageRef = "already-managed.jpg"
        try fixture.context.save()

        guard case .text(let message) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: [code]) else {
            return XCTFail("expected media-backed conflict")
        }
        XCTAssertTrue(message.hasPrefix("error:"))
        XCTAssertEqual(target.imageRef, "already-managed.jpg")
    }

    func testBatchAttachFilePreparationFailureLeavesExistingRecordRecoverable() async throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 9)
        let target = Cheki(date: date, imageRef: " \t ")
        fixture.context.insert(target)
        try fixture.context.save()
        let code = try attachConfirmation(
            in: fixture,
            target: target,
            date: date,
            imageData: Data([0x00, 0x01, 0x02])
        )

        guard case .text(let message) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: [code]) else {
            return XCTFail("expected image preparation failure")
        }
        XCTAssertTrue(message.hasPrefix("error:"))
        XCTAssertEqual(target.imageRef, " \t ")
        XCTAssertNotNil(fixture.ledger.entry(for: code))
        XCTAssertFalse(fixture.ledger.isTemporaryChekiBatchReserved(code))
        XCTAssertFalse(fixture.ledger.isTemporaryExistingChekiTargetReserved(target.id))
        XCTAssertTrue(fixture.ledger.cancel(code))
    }

    func testBatchCancellationBeforeSaveReleasesReservation() async throws {
        let limiter = ChekinanaRemoteRequestLimiter(limit: 1)
        let holderStarted = expectation(description: "image permit held")
        let holderRelease = ScannerReleaseGate()
        let holder = Task {
            try await limiter.perform {
                holderStarted.fulfill()
                await holderRelease.wait()
            }
        }
        await fulfillment(of: [holderStarted], timeout: 1)

        let fixture = try makeFixture(batchImagePreparationLimiter: limiter)
        let date = utcDate(2026, 8, 9)
        let target = Cheki(date: date, imageRef: nil)
        fixture.context.insert(target)
        try fixture.context.save()
        let code = try attachConfirmation(
            in: fixture,
            target: target,
            date: date,
            imageData: scannerPNGData(color: .green)
        )
        let save = Task {
            await fixture.executor.confirmTemporaryChekiBatch(
                confirmationCodes: [code]
            )
        }
        let didQueueImagePreparation = await waitForLimiter(
            limiter,
            active: 1,
            waiting: 1
        )
        XCTAssertTrue(didQueueImagePreparation)
        save.cancel()
        guard case .text(let message) = await save.value else {
            return XCTFail("expected canceled batch")
        }
        XCTAssertTrue(message.hasPrefix("error:"))
        XCTAssertFalse(fixture.ledger.isTemporaryChekiBatchReserved(code))
        XCTAssertFalse(fixture.ledger.isTemporaryExistingChekiTargetReserved(target.id))
        XCTAssertNotNil(fixture.ledger.entry(for: code))
        await holderRelease.release()
        _ = try await holder.value
    }

    func testBatchFinalizeRecoveryPreservesCommittedRecordAndManagedFile() async throws {
        let fixture = try makeFixture(simulateBatchFinalizeInvariantFailure: true)
        let date = utcDate(2026, 8, 9)
        let target = Cheki(date: date, imageRef: nil)
        fixture.context.insert(target)
        try fixture.context.save()
        let code = try attachConfirmation(
            in: fixture,
            target: target,
            date: date,
            imageData: scannerPNGData(color: .orange)
        )

        guard case .chekiCards(let cards) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: [code]) else {
            return XCTFail("a post-save finalization invariant must remain committed")
        }
        XCTAssertEqual(cards.map(\.id), [target.id])
        let fileURL = try XCTUnwrap(ChekiImageRefResolver.managedChekiFileURL(
            for: target.imageRef,
            chekiID: target.id
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(fixture.ledger.entry(for: code))
        XCTAssertEqual(fixture.ledger.committedTemporaryBatchRecoveryCount, 1)
        XCTAssertFalse(fixture.ledger.isTemporaryExistingChekiTargetReserved(target.id))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<Cheki>()).count, 1)
        cleanupManagedImages(in: fixture.context)
    }

    func testBatchImagePreparationLimiterCapsConcurrencyAtFour() async throws {
        let limiter = ChekinanaRemoteRequestLimiter(limit: 4)
        let probe = ChekinanaBatchPreparationConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await limiter.perform {
                        await probe.begin()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await probe.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await probe.peak()
        let finalLimiterState = await limiter.snapshot()
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(finalLimiterState, .init(activeCount: 0, waitingCount: 0))
    }

    func testCameraHardwareFixtureCoversPermissionDeviceFailureFocusAndMaximumQuality() {
        let unsupported = ChekinanaCameraFocusCapabilities(
            supportsFocusPoint: false,
            supportsAutoFocus: false,
            supportsContinuousAutoFocus: false,
            supportsExposurePoint: false,
            supportsAutoExposure: false,
            supportsContinuousAutoExposure: false
        )
        let denied = ChekinanaCameraHardwareFixture(
            permission: .denied,
            hasBackCamera: true,
            captureDataAvailable: false,
            captureErrorDescription: "capture failed",
            focusCapabilities: unsupported
        )
        XCTAssertEqual(
            denied.initialState,
            .unavailable("Camera access is denied. Enable it in Settings to take photos.")
        )
        XCTAssertEqual(denied.captureState, .failed("capture failed"))

        let noDevice = ChekinanaCameraHardwareFixture(
            permission: .authorized,
            hasBackCamera: false,
            captureDataAvailable: true,
            captureErrorDescription: nil,
            focusCapabilities: unsupported
        )
        XCTAssertEqual(
            noDevice.initialState,
            .unavailable("No rear camera is available on this device.")
        )

        let supported = ChekinanaCameraHardwareFixture(
            permission: .authorized,
            hasBackCamera: true,
            captureDataAvailable: true,
            captureErrorDescription: nil,
            focusCapabilities: .init(
                supportsFocusPoint: true,
                supportsAutoFocus: true,
                supportsContinuousAutoFocus: true,
                supportsExposurePoint: true,
                supportsAutoExposure: false,
                supportsContinuousAutoExposure: true
            )
        )
        let plan = supported.focusPlan(at: CGPoint(x: 1.4, y: -0.2))
        XCTAssertEqual(plan.point, CGPoint(x: 1, y: 0))
        XCTAssertEqual(plan.focusMode, .autoFocus)
        XCTAssertEqual(plan.exposureMode, .continuousAutoExposure)
        XCTAssertEqual(supported.initialState, .configuring)
        XCTAssertEqual(supported.captureState, .ready)

        let largest = ChekinanaCameraPhotoQuality.largestDimensions([
            CMVideoDimensions(width: 4_032, height: 3_024),
            CMVideoDimensions(width: 8_064, height: 6_048),
            CMVideoDimensions(width: 1_920, height: 1_080),
        ])
        XCTAssertEqual(largest?.width, 8_064)
        XCTAssertEqual(largest?.height, 6_048)
    }

    func testCameraPreviewAndPhotoRotationStayAlignedForEveryInterfaceOrientation() {
        XCTAssertEqual(ChekinanaCameraVideoRotation.angle(for: .portrait), 90)
        XCTAssertEqual(ChekinanaCameraVideoRotation.angle(for: .portraitUpsideDown), 270)
        XCTAssertEqual(ChekinanaCameraVideoRotation.angle(for: .landscapeLeft), 180)
        XCTAssertEqual(ChekinanaCameraVideoRotation.angle(for: .landscapeRight), 0)
        XCTAssertNil(ChekinanaCameraVideoRotation.angle(for: .unknown))
    }

    func testCameraInterruptionAndRuntimeErrorStatesCannotPretendSessionIsReady() {
        XCTAssertEqual(
            ChekinanaCameraStateResolver.interruption(
                reason: AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue
            ),
            .interrupted("The camera is in use by another app.")
        )
        XCTAssertEqual(
            ChekinanaCameraStateResolver.runtimeError(
                code: AVError.Code.mediaServicesWereReset.rawValue,
                message: "reset"
            ),
            .configuring
        )
        XCTAssertEqual(
            ChekinanaCameraStateResolver.runtimeError(code: -123, message: "offline"),
            .failed("Camera runtime error: offline")
        )
    }

    func testCameraControlsRemainLockedUntilCapturedSourceDeliveryCompletes() {
        XCTAssertTrue(ChekinanaCameraCaptureControls.canDismiss(isCaptureInFlight: false))
        XCTAssertFalse(ChekinanaCameraCaptureControls.canDismiss(isCaptureInFlight: true))
        XCTAssertTrue(ChekinanaCameraCaptureControls.canCapture(
            state: .ready,
            isCaptureInFlight: false
        ))
        XCTAssertFalse(ChekinanaCameraCaptureControls.canCapture(
            state: .capturing,
            isCaptureInFlight: false
        ))
        XCTAssertFalse(ChekinanaCameraCaptureControls.canCapture(
            state: .ready,
            isCaptureInFlight: true
        ))
    }

    func testEmptyScanReviewCanDiscardWhileNonemptyReviewOnlyCloses() {
        XCTAssertTrue(ChekinanaScanReviewLifecycle.closeDiscardsReview(cardsAreEmpty: true))
        XCTAssertFalse(ChekinanaScanReviewLifecycle.closeDiscardsReview(cardsAreEmpty: false))
        XCTAssertTrue(ChekinanaScanReviewLifecycle.shouldDiscardAfterDeletion(
            cardsAreEmpty: true,
            hasCapturedPhoto: false
        ))
        XCTAssertFalse(ChekinanaScanReviewLifecycle.shouldDiscardAfterDeletion(
            cardsAreEmpty: true,
            hasCapturedPhoto: true
        ))
        XCTAssertFalse(ChekinanaScanReviewLifecycle.shouldDiscardAfterDeletion(
            cardsAreEmpty: false,
            hasCapturedPhoto: false
        ))
    }

    func testCalendarGroupsMultiIdolChekiPerIdolAndKeepsUniqueDayTotal() {
        let first = Idol(name: "A")
        let second = Idol(name: "B")
        let shared = Cheki(idols: [first, second], date: Date(), idx: 1)
        let firstOnly = Cheki(idols: [first], date: Date(), idx: 2)
        let unassigned = Cheki(date: Date(), idx: 1)

        let groups = ChekinanaCalendarIdolGroup.groups(for: [shared, firstOnly, unassigned])
        XCTAssertEqual(groups.first { $0.idol?.id == first.id }?.chekis.count, 2)
        XCTAssertEqual(groups.first { $0.idol?.id == second.id }?.chekis.count, 1)
        XCTAssertEqual(groups.first { $0.idol == nil }?.chekis.count, 1)
        XCTAssertEqual(Set([shared.id, firstOnly.id, unassigned.id]).count, 3)
    }

    func testNoMediaRecordsRemainInStatsButAreExcludedFromGallery() {
        let idol = Idol(name: "Local")
        let cheki = Cheki(idols: [idol], date: Date(), idx: 1)
        let shame = Shame(idols: [idol], date: Date())
        let douga = Douga(idols: [idol], date: Date())

        XCTAssertFalse(ChekinanaGalleryItem.cheki(cheki).hasMedia)
        XCTAssertFalse(ChekinanaGalleryItem.shame(shame).hasMedia)
        XCTAssertFalse(ChekinanaGalleryItem.douga(douga).hasMedia)
        XCTAssertEqual(idol.chekis.count, 1)
        XCTAssertEqual(shame.idols.map(\.id), [idol.id])
        XCTAssertEqual(douga.idols.map(\.id), [idol.id])
    }

    func testNoMediaRecordsPersistEditAndDeleteInMemory() throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let idol = Idol(name: "Persisted")
        let cheki = Cheki(idols: [idol], date: Date(), idx: 1, size: .mini)
        let shame = Shame(idols: [idol], date: Date(), note: "before")
        let douga = Douga(idols: [idol], date: Date())
        context.insert(idol); context.insert(cheki); context.insert(shame); context.insert(douga)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Cheki>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Shame>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Douga>()), 1)
        XCTAssertFalse(ChekinanaGalleryItem.cheki(cheki).hasMedia)
        XCTAssertFalse(ChekinanaGalleryItem.shame(shame).hasMedia)
        XCTAssertFalse(ChekinanaGalleryItem.douga(douga).hasMedia)
        shame.note = "after"; try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Shame>()).first?.note, "after")
        context.delete(douga); try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Douga>()), 0)
    }

    func testGalleryAvatarLayoutKeepsEveryCircleInsideCanvas() {
        let overlayInset: CGFloat = 6
        XCTAssertGreaterThanOrEqual(overlayInset, 4)
        for count in [1, 4, 20, 100] {
            let contentWidth: CGFloat = 120
            let layout = ChekinanaGalleryAvatarLayout.make(
                availableWidth: contentWidth - (overlayInset * 2),
                count: count
            )
            XCTAssertGreaterThan(layout.diameter, 0)
            XCTAssertLessThanOrEqual(layout.diameter, 24)
            for index in 0..<count {
                XCTAssertGreaterThanOrEqual(
                    overlayInset + layout.x(for: index),
                    overlayInset
                )
                XCTAssertLessThanOrEqual(
                    overlayInset + layout.x(for: index) + layout.diameter,
                    contentWidth - overlayInset + 0.001
                )
            }
        }
    }

    func testAvatarRemovePolicyRejectsStalePreviewAndNeverReadsOldFile() {
        let deleted = ChekinanaIdolAvatarSelectionPolicy.afterDelete(generation: 3)
        XCTAssertEqual(deleted.generation, 4)
        XCTAssertTrue(deleted.removesAvatar)
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsPreview(generation: 3, currentGeneration: 4, itemMatches: true, removesAvatar: false))
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsPreview(generation: 4, currentGeneration: 4, itemMatches: true, removesAvatar: true))
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.shouldReadExistingAvatar(explicitlyRemoving: true))
    }

    func testCatalogueAvatarPreviewRejectsFailedReplacementAndOutOfOrderCandidate() {
        // A success belongs to generation 1; selecting B immediately clears A
        // and makes only B's generation eligible to publish.
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(generation: 1, currentGeneration: 2, candidateMatches: false, removesAvatar: false, hasLocalItem: false))
        XCTAssertTrue(ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(generation: 2, currentGeneration: 2, candidateMatches: true, removesAvatar: false, hasLocalItem: false))
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(generation: 2, currentGeneration: 2, candidateMatches: true, removesAvatar: true, hasLocalItem: false))
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(generation: 2, currentGeneration: 2, candidateMatches: true, removesAvatar: false, hasLocalItem: true))
    }

    func testIdolPatternsDefaultEmptyAndLegacyPatternMigratesWithoutLoss() throws {
        let idol = Idol(name: "Patternless")
        XCTAssertNil(idol.pattern)
        XCTAssertTrue(idol.patterns.isEmpty)

        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let writeContext = ModelContext(container)
        writeContext.insert(idol)
        try writeContext.save()

        let idolID = idol.id
        let predicate = #Predicate<Idol> { $0.id == idolID }
        var descriptor = FetchDescriptor<Idol>(predicate: predicate)
        descriptor.fetchLimit = 1

        let readContext = ModelContext(container)
        let fetched = try XCTUnwrap(readContext.fetch(descriptor).first)
        XCTAssertNil(fetched.pattern)

        let prototype = (0..<256).map { Float($0) / 255 }
        fetched.pattern = prototype
        try readContext.save()

        let verificationContext = ModelContext(container)
        let roundTripped = try XCTUnwrap(verificationContext.fetch(descriptor).first)
        XCTAssertEqual(roundTripped.pattern, prototype)
        XCTAssertEqual(roundTripped.recognitionPatterns, [prototype])
        XCTAssertTrue(roundTripped.migrateLegacyPatternIfNeeded())
        try verificationContext.save()
        XCTAssertEqual(roundTripped.patterns, [prototype])
    }

    func testPresetIdolSeederIsIdempotentAndMergesMinaPrototypes() throws {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let first = try ChekinanaPresetIdolSeeder.ensureSeeds(in: context)
        XCTAssertEqual(first.insertedIdolCount, 11)
        XCTAssertEqual(first.appendedPatternCount, 12)
        let idols = try context.fetch(FetchDescriptor<Idol>())
        XCTAssertEqual(idols.count, 11)
        XCTAssertEqual(
            Set(idols.compactMap(\.sourceId)),
            Set(ChekinanaLocalPatternRegistry.entries.map(\.sourceId))
        )
        XCTAssertTrue(idols.allSatisfy { !$0.patterns.isEmpty })
        XCTAssertTrue(idols.flatMap(\.patterns).allSatisfy {
            $0.count == ChekinanaPatternClassifier.embeddingDimension
        })
        XCTAssertEqual(ChekinanaPresetIdolSeeder.prototypeOwnerNamesInOrder, [
            "aina", "巫歌", "恋恋", "木兰", "aoyi", "eriko", "kotomi",
            "mina（凌晨12点）", "mina（凌晨12点）", "niku", "ririsu", "优子",
        ])
        XCTAssertEqual(ChekinanaPresetIdolSeeder.prototypeVectors.count, 12)
        XCTAssertEqual(
            ChekinanaPresetIdolSeeder.prototypeSourceSHA256,
            "7512e1762a1744e3ad79abea92cc99c12d289b75451269d190c12fbb03d4ee82"
        )
        for vector in ChekinanaPresetIdolSeeder.prototypeVectors {
            let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
            XCTAssertEqual(norm, 1, accuracy: 0.0001)
        }
        let mina = try XCTUnwrap(idols.first { $0.name == "mina（凌晨12点）" })
        XCTAssertEqual(mina.patterns.count, 2)

        let second = try ChekinanaPresetIdolSeeder.ensureSeeds(in: context)
        XCTAssertEqual(second.insertedIdolCount, 0)
        XCTAssertEqual(second.appendedPatternCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 11)
        XCTAssertEqual(mina.patterns.count, 2)
    }

    func testPresetIdolSeederDoesNotRestoreADeletedPatternForCurrentSourceID() throws {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let first = try ChekinanaPresetIdolSeeder.ensureSeeds(in: context)
        XCTAssertEqual(first.appendedPatternCount, 12)
        let mina = try XCTUnwrap(
            context.fetch(FetchDescriptor<Idol>()).first {
                $0.sourceId == "idol_001326"
            }
        )
        XCTAssertEqual(mina.patterns.count, 2)

        mina.patterns.removeFirst()
        try context.save()
        let remaining = mina.patterns

        let second = try ChekinanaPresetIdolSeeder.ensureSeeds(in: context)
        XCTAssertEqual(second.appendedPatternCount, 0)
        XCTAssertEqual(mina.patterns, remaining)
    }

    func testLocalPatternRegistryMapsExactPrototypeOrderAndRejectsUnknownIDs() throws {
        try ChekinanaLocalPatternRegistry.validate()
        let expected: [(String, [Int])] = [
            ("idol_002009", [0]),
            ("idol_000513", [1]),
            ("idol_001042", [2]),
            ("idol_001958", [3]),
            ("idol_001325", [4]),
            ("idol_002008", [5]),
            ("idol_002004", [6]),
            ("idol_001326", [7, 8]),
            ("idol_000812", [9]),
            ("idol_002005", [10]),
            ("idol_001500", [11]),
        ]
        XCTAssertEqual(ChekinanaLocalPatternRegistry.entries.count, 11)
        XCTAssertEqual(ChekinanaPresetIdolSeeder.prototypeVectors.count, 12)
        for (offset, item) in expected.enumerated() {
            let entry = ChekinanaLocalPatternRegistry.entries[offset]
            XCTAssertEqual(entry.sourceId, item.0)
            XCTAssertEqual(entry.prototypeIndexes, item.1)
            XCTAssertEqual(
                ChekinanaLocalPatternRegistry.patterns(for: item.0),
                item.1.map { ChekinanaPresetIdolSeeder.prototypeVectors[$0] }
            )
        }
        XCTAssertEqual(
            ChekinanaLocalPatternRegistry.patterns(for: "idol_001326").count,
            2
        )
        XCTAssertTrue(ChekinanaLocalPatternRegistry.patterns(for: "idol_unknown").isEmpty)
        XCTAssertTrue(ChekinanaLocalPatternRegistry.patterns(for: nil).isEmpty)
        for vector in ChekinanaPresetIdolSeeder.prototypeVectors {
            XCTAssertEqual(vector.count, 256)
            XCTAssertTrue(vector.allSatisfy(\.isFinite))
            XCTAssertEqual(
                sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 }),
                1,
                accuracy: 0.0001
            )
        }
    }

    func testPresetIdolSeederPreservesMatchingUserFieldsAndVectors() throws {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        var custom = Array(repeating: Float.zero, count: 256)
        custom[17] = 1
        let existing = Idol(
            name: "aina",
            group: "User group",
            isFavorite: true,
            note: "Keep this",
            patterns: [custom]
        )
        let cheki = Cheki(idols: [existing], note: "Keep relation")
        context.insert(existing)
        context.insert(cheki)
        try context.save()

        _ = try ChekinanaPresetIdolSeeder.ensureSeeds(in: context)
        XCTAssertEqual(existing.group, "User group")
        XCTAssertEqual(existing.note, "Keep this")
        XCTAssertTrue(existing.isFavorite)
        XCTAssertEqual(existing.sourceId, "idol_002009")
        XCTAssertTrue(existing.patterns.contains(custom))
        XCTAssertEqual(existing.patterns.count, 2)
        XCTAssertEqual(existing.chekis.map(\.id), [cheki.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Idol>()).filter { $0.name == "aina" }.count, 1)
    }

    func testPresetIdolSeederMigratesLegacySourceIDWithoutLosingUserData() throws {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        var custom = Array(repeating: Float.zero, count: 256)
        custom[31] = 1
        let legacy = Idol(
            sourceId: "fixed-pattern-v1:utaka",
            name: "User-renamed Utaka",
            group: "Preserved group",
            isFavorite: true,
            note: "Preserved note",
            patterns: [custom]
        )
        let cheki = Cheki(idols: [legacy])
        context.insert(legacy)
        context.insert(cheki)
        try context.save()

        _ = try ChekinanaPresetIdolSeeder.ensureSeeds(in: context)

        XCTAssertEqual(legacy.sourceId, "idol_000513")
        XCTAssertEqual(legacy.name, "User-renamed Utaka")
        XCTAssertEqual(legacy.group, "Preserved group")
        XCTAssertEqual(legacy.note, "Preserved note")
        XCTAssertTrue(legacy.isFavorite)
        XCTAssertTrue(legacy.patterns.contains(custom))
        XCTAssertTrue(legacy.patterns.contains(
            ChekinanaPresetIdolSeeder.prototypeVectors[1]
        ))
        XCTAssertEqual(legacy.chekis.map(\.id), [cheki.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 11)
    }

    func testPresetIdolSeederNeverHijacksSameNameWithAnotherCatalogueID() throws {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let unrelated = Idol(sourceId: "idol_external", name: "aina", isFavorite: true)
        context.insert(unrelated)
        try context.save()

        _ = try ChekinanaPresetIdolSeeder.ensureSeeds(in: context)

        XCTAssertEqual(unrelated.sourceId, "idol_external")
        XCTAssertTrue(unrelated.patterns.isEmpty)
        XCTAssertTrue(unrelated.isFavorite)
        let idols = try context.fetch(FetchDescriptor<Idol>())
        XCTAssertEqual(idols.count, 12)
        let real = try XCTUnwrap(idols.first { $0.sourceId == "idol_002009" })
        XCTAssertEqual(real.patterns, [ChekinanaPresetIdolSeeder.prototypeVectors[0]])
    }

    func testPresetIdolSeederKeepsRealAndLegacyDuplicatesWithoutOverridingCurrentPatterns() throws {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let real = Idol(sourceId: "idol_001500", name: "Real Yuko")
        let legacy = Idol(
            sourceId: "fixed-pattern-v1:yuko",
            name: "Legacy Yuko",
            note: "Do not merge"
        )
        context.insert(real)
        context.insert(legacy)
        try context.save()

        _ = try ChekinanaPresetIdolSeeder.ensureSeeds(in: context)

        XCTAssertTrue(real.patterns.isEmpty)
        XCTAssertEqual(legacy.sourceId, "fixed-pattern-v1:yuko")
        XCTAssertEqual(legacy.note, "Do not merge")
        XCTAssertTrue(legacy.patterns.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 12)
    }

    func testCataloguePatternSelectionReplacesPreviousRegistryPatterns() {
        var selection = ChekinanaCataloguePatternSelectionState()
        selection.select(sourceId: "idol_002009")
        XCTAssertEqual(selection.patterns, [ChekinanaPresetIdolSeeder.prototypeVectors[0]])

        selection.select(sourceId: "idol_000513")
        XCTAssertEqual(selection.sourceId, "idol_000513")
        XCTAssertEqual(selection.patterns, [ChekinanaPresetIdolSeeder.prototypeVectors[1]])
        XCTAssertFalse(selection.patterns.contains(ChekinanaPresetIdolSeeder.prototypeVectors[0]))

        selection.select(sourceId: "idol_unknown")
        XCTAssertEqual(selection.sourceId, "idol_unknown")
        XCTAssertTrue(selection.patterns.isEmpty)
    }

    func testCatalogueSameSourceUpsertPreservesFavoriteChekiAndCustomPattern() throws {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        var custom = Array(repeating: Float.zero, count: 256)
        custom[73] = 1
        let existing = Idol(
            sourceId: "idol_002009",
            name: "Old name",
            isFavorite: true,
            note: "Keep note",
            patterns: [custom]
        )
        let cheki = Cheki(idols: [existing])
        context.insert(existing)
        context.insert(cheki)
        try context.save()

        let resolution = try ChekinanaCatalogueIdolUpsert.resolve(
            sourceId: "idol_002009",
            fallbackName: "Catalogue name",
            in: context
        )
        XCTAssertFalse(resolution.shouldInsert)
        XCTAssertEqual(resolution.idol.id, existing.id)
        let merged = ChekinanaLocalPatternRegistry.mergedPatterns([
            resolution.idol.recognitionPatterns,
            ChekinanaLocalPatternRegistry.patterns(for: "idol_002009"),
            ChekinanaLocalPatternRegistry.patterns(for: "idol_002009"),
        ])
        _ = try ChekinanaIdolPersistence.save(
            resolution.idol,
            inserting: resolution.shouldInsert,
            previousAvatarRef: resolution.idol.avatarImageRef,
            stagedAvatar: nil,
            in: context
        ) { target in
            target.name = "Catalogue name"
            target.group = "Catalogue group"
            target.patterns = merged
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 1)
        XCTAssertEqual(existing.name, "Catalogue name")
        XCTAssertEqual(existing.group, "Catalogue group")
        XCTAssertTrue(existing.isFavorite)
        XCTAssertEqual(existing.note, "Keep note")
        XCTAssertEqual(existing.chekis.map(\.id), [cheki.id])
        XCTAssertTrue(existing.patterns.contains(custom))
        XCTAssertEqual(existing.patterns.filter {
            $0 == ChekinanaPresetIdolSeeder.prototypeVectors[0]
        }.count, 1)
    }

    func testManualIdolNameOnlyPersistsTrimmedNameAndNilOptionalFields() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idol = try ChekinanaManualIdolInput.makeNameOnlyIdol(
            name: "  Name Only Idol\n"
        )

        _ = try ChekinanaIdolPersistence.save(
            idol,
            inserting: true,
            previousAvatarRef: nil,
            stagedAvatar: nil,
            in: context
        ) { target in
            target.name = idol.name
        }

        let saved = try XCTUnwrap(
            context.fetch(FetchDescriptor<Idol>()).first(where: { $0.id == idol.id })
        )
        XCTAssertEqual(saved.name, "Name Only Idol")
        XCTAssertNil(saved.sourceId)
        XCTAssertNil(saved.group)
        XCTAssertNil(saved.color)
        XCTAssertNil(saved.birthday)
        XCTAssertNil(saved.avatarImageRef)
        XCTAssertNil(saved.verification)
        XCTAssertNil(saved.bio)
        XCTAssertNil(saved.pattern)
        XCTAssertTrue(saved.patterns.isEmpty)
        XCTAssertFalse(saved.isFavorite)
        XCTAssertEqual(saved.note, "")

        let reopenedContext = ModelContext(container)
        let reopened = try XCTUnwrap(
            reopenedContext.fetch(FetchDescriptor<Idol>())
                .first(where: { $0.id == idol.id })
        )
        XCTAssertFalse(ChekinanaManualIdolInput.requiresManagedAvatar(
            sourceId: reopened.sourceId
        ))
        _ = try ChekinanaIdolPersistence.save(
            reopened,
            inserting: false,
            previousAvatarRef: reopened.avatarImageRef,
            stagedAvatar: nil,
            in: reopenedContext
        ) { target in
            target.group = "Optional Group"
        }

        let finalContext = ModelContext(container)
        let edited = try XCTUnwrap(
            finalContext.fetch(FetchDescriptor<Idol>())
                .first(where: { $0.id == idol.id })
        )
        XCTAssertEqual(edited.group, "Optional Group")
        XCTAssertNil(edited.avatarImageRef)
    }

    func testManualIdolBlankOrWhitespaceNameIsRejectedBeforeInsert() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        for value in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(
                try ChekinanaManualIdolInput.makeNameOnlyIdol(name: value)
            ) { error in
                XCTAssertEqual(
                    error as? ChekinanaManualIdolInputError,
                    .nameRequired
                )
            }
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 0)
    }

    func testCatalogueReferencePatternAppendKeepsRegistryPatternAndDeduplicates() {
        var reference = Array(repeating: Float.zero, count: 256)
        reference[119] = 1
        let registry = ChekinanaLocalPatternRegistry.patterns(for: "idol_000513")
        let merged = ChekinanaLocalPatternRegistry.mergedPatterns([
            registry,
            [reference],
            [reference],
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(ChekinanaPresetIdolSeeder.prototypeVectors[1]))
        XCTAssertTrue(merged.contains(reference))
    }

    func testEventAutoMatcherRequiresUniqueFullDateCandidate() throws {
        let detected = try dateAnnotation(text: "2026.08.02", precision: .fullDate)
        let firstID = UUID()
        let secondID = UUID()
        let first = ChekinanaEventDateCandidate(id: firstID, date: utcDate(2026, 8, 2))
        let second = ChekinanaEventDateCandidate(id: secondID, date: utcDate(2026, 8, 2))

        XCTAssertNil(ChekinanaEventAutoMatcher.uniqueEventID(for: detected, candidates: []))
        XCTAssertEqual(
            ChekinanaEventAutoMatcher.uniqueEventID(for: detected, candidates: [first]),
            firstID
        )
        XCTAssertNil(ChekinanaEventAutoMatcher.uniqueEventID(
            for: detected,
            candidates: [first, second]
        ))
    }

    func testEventAutoMatcherMatchesMonthDayWithoutInventingYear() throws {
        let detected = try dateAnnotation(text: "08.02", precision: .monthDay)
        let firstID = UUID()
        let first = ChekinanaEventDateCandidate(id: firstID, date: utcDate(2025, 8, 2))
        let otherYear = ChekinanaEventDateCandidate(id: UUID(), date: utcDate(2030, 8, 2))

        XCTAssertEqual(
            ChekinanaEventAutoMatcher.uniqueEventID(for: detected, candidates: [first]),
            firstID
        )
        XCTAssertNil(ChekinanaEventAutoMatcher.uniqueEventID(
            for: detected,
            candidates: [first, otherYear]
        ))
    }

    func testChekiFavoriteAndSNSFlagsDefaultFalseAndRoundTripTrue() throws {
        let defaultCheki = Cheki()
        XCTAssertFalse(defaultCheki.isFavorite)
        XCTAssertFalse(defaultCheki.hasPostedToSNS)

        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let writeContext = ModelContext(container)
        let flaggedCheki = Cheki(isFavorite: true, hasPostedToSNS: true)
        writeContext.insert(flaggedCheki)
        try writeContext.save()

        let readContext = ModelContext(container)
        let flaggedID = flaggedCheki.id
        var descriptor = FetchDescriptor<Cheki>(
            predicate: #Predicate { $0.id == flaggedID }
        )
        descriptor.fetchLimit = 1
        let fetched = try XCTUnwrap(readContext.fetch(descriptor).first)
        XCTAssertTrue(fetched.isFavorite)
        XCTAssertTrue(fetched.hasPostedToSNS)
    }

    func testEditIdolTypedPlanPreviewsThenConfirmsAllSupportedFields() async throws {
        let fixture = try makeFixture()
        let idol = Idol(
            name: "Old",
            group: "Old Group",
            color: "red",
            birthday: "2000-01-01",
            avatarImageRef: "https://example.com/old.jpg",
            verification: "old verification",
            bio: "old bio"
        )
        fixture.context.insert(idol)
        try fixture.context.save()

        let operation = ChekinanaNLOperation(
            intent: .editidol,
            slots: .init(
                name: "New",
                target: "Old",
                group: "New Group",
                birthday: "2001-02-03",
                color: "blue",
                verification: "official",
                bio: "new bio",
                avatar: "https://example.com/new.jpg"
            )
        )
        guard case .commands(let commands) = ChekinanaConversationCoordinator.compile(
            [operation],
            modelContext: fixture.context
        ), let command = commands.first else {
            return XCTFail("expected editidol command")
        }
        XCTAssertTrue(command.hasPrefix("editidol \(String(idol.id.uuidString.prefix(8)).lowercased()) "))
        for field in ["name=New", "group=\"New Group\"", "birthday=2001-02-03",
                      "color=blue", "verification=official", "bio=\"new bio\"",
                      "avatar=https://example.com/new.jpg"] {
            XCTAssertTrue(command.contains(field), field)
        }

        guard case .idolCard(let preview) = await fixture.executor.execute(command),
              let code = preview.confirmationCode else {
            return XCTFail("expected confirmation preview")
        }
        XCTAssertEqual(idol.name, "Old")
        XCTAssertEqual(idol.verification, "old verification")

        _ = await fixture.executor.execute("confirm \(code)")
        XCTAssertEqual(idol.name, "New")
        XCTAssertEqual(idol.group, "New Group")
        XCTAssertEqual(idol.birthday, "2001-02-03")
        XCTAssertEqual(idol.color, "blue")
        XCTAssertEqual(idol.verification, "official")
        XCTAssertEqual(idol.bio, "new bio")
        XCTAssertEqual(idol.avatarImageRef, "https://example.com/new.jpg")
    }

    func testEditIdolRejectsOversizedFieldsAndCredentialedAvatarWithoutConfirmation() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "Safe")
        fixture.context.insert(idol)
        try fixture.context.save()
        let target = String(idol.id.uuidString.prefix(8)).lowercased()
        let oversized = String(repeating: "a", count: 201)

        for field in ["name", "group", "birthday", "color", "verification", "bio", "avatar"] {
            let response = await fixture.executor.execute(
                "editidol \(target) \(field)=\(oversized)"
            )
            XCTAssertTrue(text(from: response).contains("invalid or too long"), field)
            XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty, field)
        }

        let credentialed = await fixture.executor.execute(
            "editidol \(target) avatar=https://user:password@example.com/avatar.jpg"
        )
        XCTAssertTrue(text(from: credentialed).contains("avatar must be"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertEqual(idol.avatarImageRef, nil)
    }

    func testEditIdolClearsEveryOptionalFieldButNeverName() async throws {
        let fixture = try makeFixture()
        let idol = Idol(
            name: "Keep",
            group: "Group",
            color: "blue",
            birthday: "2000-01-01",
            avatarImageRef: "managed-avatar.jpg",
            verification: "official",
            bio: "bio"
        )
        fixture.context.insert(idol)
        try fixture.context.save()
        let target = String(idol.id.uuidString.prefix(8)).lowercased()

        guard case .idolCard(let preview) = await fixture.executor.execute(
            "editidol \(target) group=- birthday=- color=- verification=- bio=- avatar=-"
        ), let code = preview.confirmationCode else {
            return XCTFail("expected clear confirmation")
        }
        _ = await fixture.executor.execute("confirm \(code)")
        XCTAssertEqual(idol.name, "Keep")
        XCTAssertNil(idol.group)
        XCTAssertNil(idol.birthday)
        XCTAssertNil(idol.color)
        XCTAssertNil(idol.verification)
        XCTAssertNil(idol.bio)
        XCTAssertNil(idol.avatarImageRef)

        let clearName = await fixture.executor.execute("editidol \(target) name=-")
        XCTAssertTrue(text(from: clearName).contains("name requires"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertEqual(idol.name, "Keep")
    }

    func testTypedIdolAvatarClearAndChekiUserSetClearConfirmSafely() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "Mina", bio: "bio")
        let storedAvatar = try await ChekinanaIdolReferenceStore.saveAvatar(
            scannerPNGData(color: .purple),
            idolID: idol.id
        )
        idol.avatarImageRef = storedAvatar.ref
        fixture.context.insert(idol)
        let cheki = Cheki(userAppears: true)
        fixture.context.insert(cheki)
        cheki.idols = [idol]
        try fixture.context.save()
        defer { try? FileManager.default.removeItem(at: storedAvatar.url) }

        let idolTarget = String(idol.id.uuidString.prefix(8)).lowercased()
        guard case .idolCard(let idolPreview) = await fixture.executor.execute(
            "editidol \(idolTarget) clear_fields=avatar,bio"
        ), let idolCode = idolPreview.confirmationCode else {
            return XCTFail("expected Idol clear confirmation")
        }
        _ = await fixture.executor.execute("confirm \(idolCode)")
        XCTAssertNil(idol.avatarImageRef)
        XCTAssertNil(idol.bio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedAvatar.url.path))

        let chekiTarget = String(cheki.id.uuidString.prefix(8)).lowercased()
        guard case .confirmationText(_, let setCode) = await fixture.executor.execute(
            "editrecord cheki target=\(chekiTarget) user=false"
        ) else {
            return XCTFail("expected Cheki user confirmation")
        }
        _ = await fixture.executor.execute("confirm \(setCode)")
        XCTAssertEqual(cheki.userAppears, false)

        guard case .confirmationText(_, let clearCode) = await fixture.executor.execute(
            "editrecord cheki target=\(chekiTarget) clear_fields=user"
        ) else {
            return XCTFail("expected Cheki user clear confirmation")
        }
        _ = await fixture.executor.execute("confirm \(clearCode)")
        XCTAssertNil(cheki.userAppears)
    }

    func testConfirmedEventDeleteRemovesManagedAvatarAfterSave() async throws {
        let fixture = try makeFixture()
        let event = Event(name: "Avatar Event")
        let avatarRef = "event-avatar-\(event.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        let directory = try ChekiImageRefResolver.chekiImagesDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let avatarURL = directory.appendingPathComponent(avatarRef)
        try Data([0x01, 0x02]).write(to: avatarURL, options: .atomic)
        let imageRef = "event-image-\(event.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        let imageURL = directory.appendingPathComponent(imageRef)
        try Data([0x03, 0x04]).write(to: imageURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: avatarURL) }
        defer { try? FileManager.default.removeItem(at: imageURL) }
        event.avatarImageRef = avatarRef
        fixture.context.insert(event)
        fixture.context.insert(EventImage(
            eventID: event.id,
            imageRef: imageRef,
            sortOrder: 0
        ))
        try fixture.context.save()

        guard case .confirmationText(_, let code) = await fixture.executor.execute(
            "deleteevent \(shortID(event.id))"
        ) else {
            return XCTFail("expected event delete confirmation")
        }
        try requireSuccess(await fixture.executor.execute("confirm \(code)"))

        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Event>()), 0)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<EventImage>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: avatarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testEventDeleteSaveFailureDoesNotRemoveAvatar() throws {
        let fixture = try makeFixture()
        let event = Event(name: "Keep Avatar")
        event.avatarImageRef = "event-avatar-\(event.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        fixture.context.insert(event)
        try fixture.context.save()

        XCTAssertThrowsError(try ChekinanaEventPersistence.delete(
            event,
            from: fixture.context,
            saveContext: { _ in
                XCTAssertTrue(ChekinanaEventMediaJournal.deletionRefs().contains(
                    try XCTUnwrap(event.avatarImageRef)
                ))
                throw NSError(domain: "save", code: 1)
            }
        ))

        XCTAssertFalse(ChekinanaEventMediaJournal.deletionRefs().contains(
            try XCTUnwrap(event.avatarImageRef)
        ))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Event>()), 1)
    }

    func testEventPersistsOrderedImageRecordsWithoutChangingEventEntity() throws {
        let fixture = try makeFixture()
        let event = Event(name: "Illustrated")
        let imageRefs = [
            "event-image-\(event.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg",
            "event-image-\(event.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg",
        ]
        imageRefs.forEach { ChekinanaEventMediaJournal.recordPending($0) }
        fixture.context.insert(event)
        try ChekinanaEventPersistence.save(
            event,
            images: imageRefs.map { .init(id: nil, imageRef: $0) },
            previousAvatarRef: nil,
            in: fixture.context
        )

        let records = try ChekinanaEventPersistence.images(for: event.id, in: fixture.context)
        XCTAssertEqual(records.map(\.imageRef), imageRefs)
        XCTAssertEqual(records.map(\.sortOrder), [0, 1])
        XCTAssertTrue(imageRefs.allSatisfy(ChekinanaEventImageStore.isManaged))
        XCTAssertTrue(imageRefs.allSatisfy {
            !ChekinanaEventMediaJournal.pendingRefs().contains($0)
        })
    }

    func testLegacyEventDiskStoreAddsEventImageTableWithoutLosingEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-event-image-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("LegacyEvent.store")
        let legacySchema = Schema([
            Idol.self, Event.self, Cheki.self, Shame.self, Douga.self,
        ])
        let currentSchema = Schema([
            Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self,
        ])
        let eventID = UUID()
        let eventDate = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))

        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [ModelConfiguration(
                "LegacyEvent",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(legacyContainer))
            context.insert(Event(
                id: eventID,
                name: "Legacy Event",
                date: eventDate,
                city: "Shanghai",
                livehouse: "Legacy House",
                note: "keep"
            ))
            try context.save()
        }
        legacyContainer = nil

        let currentContainer = try ModelContainer(
            for: currentSchema,
            configurations: [ModelConfiguration(
                "LegacyEvent",
                schema: currentSchema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(currentContainer)
        let event = try XCTUnwrap(context.fetch(FetchDescriptor<Event>()).first)
        XCTAssertEqual(event.id, eventID)
        XCTAssertEqual(event.name, "Legacy Event")
        XCTAssertEqual(event.date, eventDate)
        XCTAssertEqual(event.city, "Shanghai")
        XCTAssertEqual(event.resolvedLivehouse, "Legacy House")
        XCTAssertEqual(event.note, "keep")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventImage>()), 0)
    }

    func testEventSaveGateBlocksCancelWhileCommitIsInFlightAndRejectsStaleToken() throws {
        var gate = ChekinanaEventSaveGate()
        let token = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.isInFlight)
        XCTAssertNil(gate.begin())
        XCTAssertFalse(gate.cancelIfIdle())
        XCTAssertTrue(gate.accepts(token))
        XCTAssertTrue(gate.finish(token))
        XCTAssertFalse(gate.isInFlight)
        XCTAssertTrue(gate.cancelIfIdle())
        XCTAssertFalse(gate.accepts(token))
        XCTAssertFalse(gate.finish(token))
    }

    func testEventRemoteImageRedirectPolicyAllowsTrustedTargetsAndRejectsEvilOrPrivate() throws {
        let delegate = ChekinanaEventRemoteImageRedirectDelegate()
        let allowed = URLRequest(url: try XCTUnwrap(
            URL(string: "https://wx2.sinaimg.cn/large/redirected.jpg")
        ))
        let evil = URLRequest(url: try XCTUnwrap(
            URL(string: "https://evil.example/redirected.jpg")
        ))
        let privateTarget = URLRequest(url: try XCTUnwrap(
            URL(string: "https://127.0.0.1/private.jpg")
        ))

        XCTAssertEqual(delegate.trustedRedirectRequest(allowed)?.url, allowed.url)
        XCTAssertNil(delegate.trustedRedirectRequest(evil))
        XCTAssertNil(delegate.trustedRedirectRequest(privateTarget))
    }

    func testEventRemoteImageDownloaderRevalidatesFinalResponseURL() async throws {
        let initialURL = try XCTUnwrap(URL(string: "https://wx1.sinaimg.cn/start.jpg"))
        let payload = scannerPNGData(color: .cyan)
        let allowedFile = try temporaryDownloadFile(data: payload)
        let allowedResponse = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://wx2.sinaimg.cn/final.jpg")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        ))
        let allowedDownloader = ChekinanaEventRemoteImageDownloader { _ in
            (allowedFile, allowedResponse)
        }
        let allowedData = try await allowedDownloader.data(for: initialURL)
        XCTAssertEqual(allowedData, payload)

        let evilFile = try temporaryDownloadFile(data: payload)
        let evilResponse = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://evil.example/final.jpg")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        ))
        let evilDownloader = ChekinanaEventRemoteImageDownloader { _ in
            (evilFile, evilResponse)
        }
        do {
            _ = try await evilDownloader.data(for: initialURL)
            XCTFail("Expected final redirect target rejection")
        } catch {
            XCTAssertEqual(
                error as? ChekinanaEventRemoteImageDownloader.DownloadError,
                .invalidResponse
            )
        }
    }

    func testEventImagePolicyRejectsTinyCompressedHugePixelFixtureBeforeDecode() async throws {
        let hugeTIFF = oversizedTIFFFixture(width: 32_768, height: 32_768)
        XCTAssertLessThan(hugeTIFF.count, 64)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(hugeTIFF as CFData, nil))
        XCTAssertFalse(ChekinanaImageSourceValidator.accepts(
            source: source,
            maxDimension: 2_048
        ))
        let rejected = await ChekinanaImageWorker.downsampledJPEGData(
            from: hugeTIFF,
            maxDimension: 2_048
        )
        XCTAssertNil(rejected)

        let safe = scannerPNGData(color: .green)
        let accepted = await ChekinanaImageWorker.downsampledJPEGData(
            from: safe,
            maxDimension: 512
        )
        XCTAssertNotNil(accepted)
    }

    func testEventMediaJournalRecoversCrashWindowsAndProtectsReferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-event-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "chekinana-event-journal-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let eventID = UUID()

        let orphan = "event-image-\(eventID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        ChekinanaEventMediaJournal.recordPending(orphan, defaults: defaults)
        let orphanURL = directory.appendingPathComponent(orphan)
        try Data([0x01]).write(to: orphanURL)
        ChekinanaEventMediaJournal.recover(
            referencedRefs: [],
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertFalse(ChekinanaEventMediaJournal.pendingRefs(defaults: defaults).contains(orphan))

        let referenced = "event-avatar-\(eventID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        ChekinanaEventMediaJournal.recordPending(referenced, defaults: defaults)
        ChekinanaEventMediaJournal.queueDeletion([referenced], defaults: defaults)
        let referencedURL = directory.appendingPathComponent(referenced)
        try Data([0x02]).write(to: referencedURL)
        ChekinanaEventMediaJournal.recover(
            referencedRefs: [referenced],
            directory: directory,
            defaults: defaults
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path))
        XCTAssertFalse(ChekinanaEventMediaJournal.pendingRefs(defaults: defaults).contains(referenced))
        XCTAssertFalse(ChekinanaEventMediaJournal.deletionRefs(defaults: defaults).contains(referenced))

        let deleted = "event-image-\(eventID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        ChekinanaEventMediaJournal.queueDeletion([deleted], defaults: defaults)
        let deletedURL = directory.appendingPathComponent(deleted)
        try Data([0x03]).write(to: deletedURL)
        ChekinanaEventMediaJournal.recover(
            referencedRefs: [],
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedURL.path))
        XCTAssertFalse(ChekinanaEventMediaJournal.deletionRefs(defaults: defaults).contains(deleted))
    }

    func testEventMediaJournalKeepsFailedDeletionForLaunchRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-event-journal-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "chekinana-event-journal-retry-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ref = "event-image-\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        let url = directory.appendingPathComponent(ref)
        try Data([0x04]).write(to: url)
        ChekinanaEventMediaJournal.queueDeletion([ref], defaults: defaults)

        ChekinanaEventMediaJournal.recover(
            referencedRefs: [],
            directory: directory,
            defaults: defaults,
            removeItem: { _ in throw NSError(domain: "delete", code: 1) }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(ChekinanaEventMediaJournal.deletionRefs(defaults: defaults).contains(ref))

        ChekinanaEventMediaJournal.recover(
            referencedRefs: [],
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(ChekinanaEventMediaJournal.deletionRefs(defaults: defaults).contains(ref))
    }

    func testEventImageRemoteStagingIsBoundedOrderedAndKeepsPartialSuccess() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let jpeg = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let probe = ChekinanaEventImageFetchProbe(data: jpeg)
        let eventID = UUID()
        let urls = (0..<7).map { index in
            "https://wx1.sinaimg.cn/large/\(index == 3 ? "fail" : "image-\(index)").jpg"
        }

        let staged = try await ChekinanaEventImageStore.stageRemoteImages(
            urls,
            eventID: eventID,
            fetch: { try await probe.fetch($0) }
        )
        let refs = staged.compactMap { $0 }
        defer { ChekinanaEventImageStore.remove(refs) }

        XCTAssertEqual(ChekinanaEventImageStore.maximumConcurrentDownloads, 3)
        XCTAssertEqual(staged.count, urls.count)
        XCTAssertNil(staged[3])
        XCTAssertEqual(refs.count, 6)
        XCTAssertTrue(Set(refs).isSubset(of: ChekinanaEventMediaJournal.pendingRefs()))
        let peakConcurrency = await probe.peakConcurrency()
        XCTAssertEqual(peakConcurrency, 3)
        XCTAssertTrue(refs.allSatisfy(ChekinanaEventImageStore.isManaged))
    }

    func testEventImageRemoteStagingCancellationRemovesCompletedFiles() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let jpeg = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let eventID = UUID()
        let directory = try ChekiImageRefResolver.chekiImagesDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = ChekinanaEventImageFetchProbe(data: jpeg, delayNanoseconds: 40_000_000)
        let task = Task {
            try await ChekinanaEventImageStore.stageRemoteImages(
                (0..<6).map { "https://wx1.sinaimg.cn/large/cancel-\($0).jpg" },
                eventID: eventID,
                fetch: { try await probe.fetch($0) }
            )
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let prefix = "event-image-\(eventID.uuidString.lowercased())-"
        let leaked = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
        XCTAssertTrue(leaked.isEmpty)
    }

    func testEventAndCalendarUISourceKeepsImagesOutOfListsAndMonthCells() throws {
        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)

        func slice(_ start: String, _ end: String) throws -> Substring {
            let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
            let endIndex = try XCTUnwrap(source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
            return source[startIndex..<endIndex]
        }

        let eventList = try slice(
            "private struct ChekinanaEventsView",
            "private struct ChekinanaEventDetailView"
        )
        XCTAssertFalse(eventList.contains("imageRefs"))
        XCTAssertFalse(eventList.contains("ChekinanaEventImageStore"))
        XCTAssertFalse(eventList.contains("EventImage"))

        let detail = try slice(
            "private struct ChekinanaEventDetailView",
            "private struct ChekinanaEventImageDraft"
        )
        XCTAssertTrue(detail.contains("@Query private var eventImages"))
        XCTAssertTrue(detail.contains("ForEach(Array(eventImages.enumerated())"))
        XCTAssertTrue(detail.contains("chekinana.events.detail.image"))

        let editor = try slice(
            "private struct ChekinanaEventEditorView",
            "enum ChekinanaGalleryMediaKind"
        )
        XCTAssertTrue(editor.contains("Paste Weibo URL"))
        XCTAssertTrue(editor.contains("Parse Weibo URL"))
        XCTAssertTrue(editor.contains("chekinana.events.editor.images.add"))
        XCTAssertFalse(editor.contains("sourceText"))
        XCTAssertFalse(editor.contains("parse-text"))
        let applyIndex = try XCTUnwrap(editor.range(of: "apply(candidate)")?.lowerBound)
        let stageIndex = try XCTUnwrap(editor.range(of: "stageParsedImages(candidate.imageUrls")?.lowerBound)
        XCTAssertLessThan(applyIndex, stageIndex)
        XCTAssertTrue(editor.contains("ChekinanaEventPersistence.save("))
        XCTAssertTrue(editor.contains("discardUncommittedImages()"))
        XCTAssertTrue(editor.contains("interactiveDismissDisabled(isSaving)"))
        XCTAssertTrue(editor.contains("guard !isSaving else { return }"))
        XCTAssertTrue(editor.contains(".disabled(isSaving)"))
        XCTAssertTrue(editor.contains("saveGate.accepts(token"))
        XCTAssertTrue(editor.contains("didCommit = true"))

        let monthCell = try slice(
            "private func calendarDay(_ cell: ChekinanaCalendarCell)",
            "private var selectedDayCard"
        )
        XCTAssertFalse(monthCell.contains("eventCount"))
        XCTAssertFalse(monthCell.contains("music.note.house"))
        let selectedDay = try slice(
            "private var selectedDayCard",
            "private struct ChekinanaCalendarGroupSummary"
        )
        XCTAssertTrue(selectedDay.contains("music.note.house"))
        XCTAssertTrue(selectedDay.contains("ForEach(selectedEvents)"))

        let gallery = try slice(
            "private struct ChekinanaGalleryView",
            "private struct ChekinanaGalleryCard"
        )
        XCTAssertTrue(gallery.contains(".filter { $0.hasMedia }"))
        XCTAssertTrue(gallery.contains("Text(\"Cheki\").tag(\"Cheki\")"))
        XCTAssertTrue(gallery.contains("Text(\"Shame\").tag(\"Shame\")"))
        XCTAssertTrue(gallery.contains("Text(\"Douga\").tag(\"Douga\")"))
        XCTAssertTrue(gallery.contains("GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)"))

        let recordEditor = try slice(
            "private struct ChekinanaCalendarRecordEditor",
            "struct ChekinanaCalendarIdolGroup"
        )
        XCTAssertTrue(recordEditor.contains("in: 1...100"))
        XCTAssertTrue(recordEditor.contains("$0.idols.count == 1"))
        XCTAssertTrue(recordEditor.contains("size: .mini"))
    }

    func testEditChekiExplicitlyClearsAssociationsWithoutClearingOmittedFields() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "Association Idol")
        let event = Event(name: "Association Event")
        let date = utcDate(2026, 8, 5)
        let cheki = Cheki(idols: [idol], event: event, date: date, idx: 1, note: "before")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        fixture.context.insert(cheki)
        try fixture.context.save()
        let target = shortID(cheki.id)

        guard case .pendingChekiCards(_, let noteCards, _) = await fixture.executor.execute(
            "editcheki \(target) note=after"
        ), let noteCode = noteCards.first?.confirmationCode else {
            return XCTFail("expected note edit confirmation")
        }
        try requireSuccess(await fixture.executor.execute("confirm \(noteCode)"))
        XCTAssertEqual(cheki.idols.map(\.id), [idol.id])
        XCTAssertEqual(cheki.event?.id, event.id)
        XCTAssertEqual(cheki.date, date)
        XCTAssertEqual(cheki.idx, 1)

        guard case .pendingChekiCards(_, let clearCards, _) = await fixture.executor.execute(
            "editcheki \(target) idols=- event=- date=-"
        ), let clearCard = clearCards.first,
           let clearCode = clearCard.confirmationCode else {
            return XCTFail("expected association clear confirmation")
        }
        XCTAssertTrue(clearCard.idolNames.isEmpty)
        XCTAssertNil(clearCard.eventName)
        XCTAssertNil(clearCard.eventDateText)
        XCTAssertNil(clearCard.idx)
        XCTAssertEqual(cheki.idols.map(\.id), [idol.id], "confirmation must not mutate early")

        try requireSuccess(await fixture.executor.execute("confirm \(clearCode)"))
        XCTAssertTrue(cheki.idols.isEmpty)
        XCTAssertNil(cheki.event)
        XCTAssertNil(cheki.date)
        XCTAssertNil(cheki.idx)
        XCTAssertEqual(cheki.note, "after")
    }

#if DEBUG
    func testMediaUITestFixtureProvidesThreeSmallDistinctImages() {
        let images = ChekinanaMediaUITestFixture.pendingChekiImages()

        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(Set(images.map(\.data)).count, 3)
        XCTAssertTrue(images.allSatisfy { $0.filenameExtension == "png" })
        XCTAssertTrue(images.allSatisfy { !$0.data.isEmpty && $0.data.count < 4_096 })
        XCTAssertTrue(images.allSatisfy { UIImage(data: $0.data) != nil })
    }
#endif


    func testScannerDateAnnotationHeaderParserStrictStates() throws {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://api.chekinana.top/api/result/task/result")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        }

        let full = ChekinanaScannerDateAnnotationHeaderParser.parse(
            response: response([
                "x-cheki-date-status": "detected",
                "X-Cheki-Date-Text": "2026.07.04",
                "X-Cheki-Date-Precision": "full_date",
                "X-Cheki-Date-Bbox": "100,200,900,800",
            ]),
            isEnabled: true
        )
        guard case .detected(let fullAnnotation) = full else {
            return XCTFail("expected full-date annotation")
        }
        XCTAssertEqual(fullAnnotation.text, "2026.07.04")
        XCTAssertEqual(fullAnnotation.precision, .fullDate)
        XCTAssertEqual(fullAnnotation.boundingBox.x1, 100)

        let monthDay = ChekinanaScannerDateAnnotationHeaderParser.parse(
            response: response([
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "02.29",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "0,0,1000,1000",
            ]),
            isEnabled: true
        )
        guard case .detected(let monthDayAnnotation) = monthDay else {
            return XCTFail("expected month-day annotation")
        }
        XCTAssertEqual(monthDayAnnotation.text, "02.29")
        XCTAssertEqual(monthDayAnnotation.precision, .monthDay)

        XCTAssertEqual(
            ChekinanaScannerDateAnnotationHeaderParser.parse(
                response: response(["X-Cheki-Date-Status": "not_detected"]),
                isEnabled: true
            ),
            .notDetected
        )
        XCTAssertEqual(
            ChekinanaScannerDateAnnotationHeaderParser.parse(
                response: response([
                    "X-Cheki-Date-Status": "unavailable",
                    "X-Cheki-Date-Error": "upstream_unavailable",
                ]),
                isEnabled: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            ChekinanaScannerDateAnnotationHeaderParser.parse(
                response: response([
                    "X-Cheki-Date-Status": "detected",
                    "X-Cheki-Date-Text": "2026.07.04",
                    "X-Cheki-Date-Precision": "full_date",
                    "X-Cheki-Date-Bbox": "100,200,900,800",
                ]),
                isEnabled: false
            ),
            .notRequested
        )

        let malformedHeaders: [[String: String]] = [
            ["X-Cheki-Date-Status": "unknown"],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "2026.02.29",
                "X-Cheki-Date-Precision": "full_date",
                "X-Cheki-Date-Bbox": "100,200,900,800",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "full_date",
                "X-Cheki-Date-Bbox": "100,200,900,800",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "100.0,200,900,800",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "100,200,900",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "100,200,1001,800",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "900,200,100,800",
            ],
            [
                "X-Cheki-Date-Status": "not_detected",
                "X-Cheki-Date-Bbox": "100,200,900,800",
            ],
        ]
        for headers in malformedHeaders {
            XCTAssertEqual(
                ChekinanaScannerDateAnnotationHeaderParser.parse(
                    response: response(headers),
                    isEnabled: true
                ),
                .unavailable,
                "\(headers)"
            )
        }
    }

    func testScannerLegacyResultsAndDateSwitchKeepCleanImageContract() async throws {
        let image = scannerPNGData(color: .purple)
        var dateEnabled = true
        var downloadedResultIDs: [String] = []
        ChekinanaScannerDateMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/process") {
                return (Data(#"{"task_id":"task-1"}"#.utf8), [:])
            }
            if path.hasSuffix("/api/status/task-1") {
                return (
                    Data(#"{"status":"done","source_image":{"width":64,"height":64},"coordinate_system":{"space":"exif_transposed_original_pixels","origin":"top_left","x_axis":"right","y_axis":"down","quad_order":["top_left","top_right","bottom_right","bottom_left"]},"results":[{"id":1,"type":"polaroid","label":"first","quadrilateral":[[4,5],[59,6],[58,60],[3,59]]},{"id":2,"type":"other","label":"ignored"}]}"#.utf8),
                    [:]
                )
            }
            if path.hasSuffix("/api/result/task-1/1") {
                downloadedResultIDs.append("1")
                XCTAssertEqual(
                    request.url?.query,
                    dateEnabled ? "date_annotation=1" : nil
                )
                return (
                    image,
                    [
                        "X-Cheki-Date-Status": "detected",
                        "X-Cheki-Date-Text": "2026.07.04",
                        "X-Cheki-Date-Precision": "full_date",
                        "X-Cheki-Date-Bbox": "100,200,900,800",
                    ]
                )
            }
            XCTFail("unexpected URL \(request.url?.absoluteString ?? "-")")
            return (Data(), [:])
        }
        defer { ChekinanaScannerDateMockURLProtocol.handler = nil }
        let client = ChekinanaScannerClient(
            baseURL: URL(string: "https://scanner.test")!,
            session: scannerDateMockSession()
        )

        let enabled = try await client.process(
            ChekinanaPendingChekiImage(data: image, filenameExtension: "png"),
            options: scannerOptions(dateRecognitionEnabled: true)
        )
        XCTAssertEqual(enabled.images.count, 1)
        XCTAssertEqual(enabled.images[0].data, image)
        XCTAssertEqual(enabled.images[0].sourceAnnotation?.quadrilateral.count, 4)
        XCTAssertNotEqual(enabled.images[0].sourceAnnotation?.previewImageData, image)
        guard case .detected(let annotation) = enabled.images[0].dateAnnotationState else {
            return XCTFail("expected date annotation")
        }
        XCTAssertEqual(annotation.text, "2026.07.04")

        dateEnabled = false
        let disabled = try await client.process(
            ChekinanaPendingChekiImage(data: image, filenameExtension: "png"),
            options: scannerOptions(dateRecognitionEnabled: false)
        )
        XCTAssertEqual(disabled.images[0].data, image)
        XCTAssertEqual(disabled.images[0].dateAnnotationState, .notRequested)

        let fixedBounds = try XCTUnwrap(
            ChekinanaScannerDateBounds.fixed(utcDate(2026, 7, 4))
        )
        let fixed = try await client.process(
            ChekinanaPendingChekiImage(data: image, filenameExtension: "png"),
            options: scannerOptions(
                dateRecognitionEnabled: true,
                dateBounds: fixedBounds
            )
        )
        XCTAssertEqual(fixed.images[0].data, image)
        XCTAssertEqual(fixed.images[0].dateAnnotationState, .notRequested)
        XCTAssertEqual(downloadedResultIDs, ["1", "1", "1"])
    }

    func testScannerInvalidCoordinateMetadataKeepsCleanResultWithoutAnnotation() async throws {
        let image = scannerPNGData(color: .blue)
        ChekinanaScannerDateMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/process") {
                return (Data(#"{"task_id":"invalid-quad"}"#.utf8), [:])
            }
            if path.hasSuffix("/api/status/invalid-quad") {
                return (Data(#"{"status":"done","source_image":{"width":2,"height":2},"coordinate_system":{"space":"exif_transposed_original_pixels","origin":"top_left","x_axis":"right","y_axis":"up","quad_order":["top_left","top_right","bottom_right","bottom_left"]},"results":[{"id":"1","type":"polaroid","quadrilateral":[[0,0],[2,0],[2,2],[0,2]]}]}"#.utf8), [:])
            }
            if path.hasSuffix("/api/result/invalid-quad/1") {
                return (image, [:])
            }
            throw URLError(.badServerResponse)
        }
        defer { ChekinanaScannerDateMockURLProtocol.handler = nil }
        let client = ChekinanaScannerClient(
            baseURL: try XCTUnwrap(URL(string: "https://scanner.test")),
            session: scannerDateMockSession()
        )
        let result = try await client.process(
            ChekinanaPendingChekiImage(data: image, filenameExtension: "png"),
            options: scannerOptions(dateRecognitionEnabled: false)
        )
        XCTAssertEqual(result.images.map(\.data), [image])
        XCTAssertNil(result.images[0].sourceAnnotation)
    }

    func testScannerDownloadsDoneResultsOnceWithoutConcurrencyCap() async throws {
        let imageIDsInPublishedOrder = ["1", "3", "2", "5", "4"]
        let imagesByID = [
            "1": scannerPNGData(color: .red),
            "2": scannerPNGData(color: .green),
            "3": scannerPNGData(color: .blue),
            "4": scannerPNGData(color: .orange),
            "5": scannerPNGData(color: .purple),
        ]
        let probe = ScannerProgressiveResultProbe()
        ChekinanaScannerDateMockURLProtocol.asyncHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/process") {
                return (Data(#"{"task_id":"task-progressive"}"#.utf8), [:])
            }
            if path.hasSuffix("/api/status/task-progressive") {
                return (await probe.nextStatusResponse(), [:])
            }
            guard let resultID = path.split(separator: "/").last.map(String.init),
                  let image = imagesByID[resultID] else {
                throw URLError(.badServerResponse)
            }

            await probe.begin(resultID: resultID, query: request.url?.query)
            do {
                let delayByID: [String: UInt64] = [
                    "1": 150_000_000,
                    "3": 130_000_000,
                    "2": 110_000_000,
                    "5": 90_000_000,
                    "4": 70_000_000,
                ]
                let delay = delayByID[resultID] ?? 0
                try await Task.sleep(nanoseconds: delay)
            } catch {
                await probe.end()
                throw error
            }
            await probe.end()
            return (
                image,
                ["X-Cheki-Date-Status": "not_detected"]
            )
        }
        defer { ChekinanaScannerDateMockURLProtocol.asyncHandler = nil }

        let client = ChekinanaScannerClient(
            baseURL: try XCTUnwrap(URL(string: "https://scanner.test")),
            session: scannerDateMockSession(),
            statusPollIntervalNanoseconds: 30_000_000
        )
        var progressUpdates: [ChekinanaScannerTaskProgress] = []
        let result = try await client.process(
            ChekinanaPendingChekiImage(
                data: scannerPNGData(color: .white),
                filenameExtension: "png"
            ),
            options: scannerOptions(dateRecognitionEnabled: true),
            progressObserver: { progressUpdates.append($0) }
        )
        let snapshot = await probe.snapshot()

        XCTAssertEqual(
            result.images.map(\.data),
            try imageIDsInPublishedOrder.map { try XCTUnwrap(imagesByID[$0]) }
        )
        XCTAssertEqual(snapshot.statusRequestCount, 2)
        XCTAssertEqual(
            snapshot.resultRequestCounts,
            Dictionary(uniqueKeysWithValues: imageIDsInPublishedOrder.map { ($0, 1) })
        )
        XCTAssertEqual(snapshot.peak, 5, "all five published results should be in flight")
        XCTAssertEqual(
            snapshot.queries,
            Array(repeating: "date_annotation=1", count: imageIDsInPublishedOrder.count)
        )
        XCTAssertLessThan(
            try XCTUnwrap(snapshot.events.firstIndex(of: "status:2")),
            try XCTUnwrap(snapshot.events.firstIndex(of: "get:1")),
            "API 1.2 results must only publish after the terminal status"
        )
        XCTAssertTrue(progressUpdates.contains { $0.phase == "extracting" })
        XCTAssertTrue(progressUpdates.contains { $0.phase == "complete" })
        XCTAssertEqual(progressUpdates.last?.phase, "retrieving_results_with_date")
        XCTAssertEqual(progressUpdates.last?.publishedResultCount, 5)
        XCTAssertEqual(progressUpdates.last?.downloadedResultCount, 5)
        XCTAssertEqual(progressUpdates.last?.expectedPolaroids, 5)
        XCTAssertEqual(progressUpdates.last?.extractionComplete, true)

        XCTAssertEqual(ChekinanaScannerClient.defaultStatusPollIntervalNanoseconds, 250_000_000)
        XCTAssertEqual(ChekinanaScannerClient.defaultMaximumStatusPollAttempts, 480)
        XCTAssertEqual(
            ChekinanaScannerClient.defaultStatusPollIntervalNanoseconds
                * UInt64(ChekinanaScannerClient.defaultMaximumStatusPollAttempts),
            120_000_000_000
        )
    }

    func testScannerKeepsPartialDownloadOnFailedTerminalAndDoesNotRetryDateUnavailable() async throws {
        let image = scannerPNGData(color: .cyan)
        let probe = ScannerPartialResultProbe()
        ChekinanaScannerDateMockURLProtocol.asyncHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/process") {
                return (Data(#"{"task_id":"task-partial"}"#.utf8), [:])
            }
            if path.hasSuffix("/api/status/task-partial") {
                return (
                    Data(#"{"status":"failed","phase":"complete","results_count":2,"expected_polaroids":2,"extraction_complete":true,"results":[{"id":1,"type":"polaroid"},{"id":2,"type":"polaroid"}]}"#.utf8),
                    [:]
                )
            }
            let resultID = String(path.split(separator: "/").last ?? "")
            await probe.record(resultID: resultID, query: request.url?.query)
            if resultID == "1" {
                return (
                    image,
                    [
                        "X-Cheki-Date-Status": "unavailable",
                        "X-Cheki-Date-Error": "date_annotation_unavailable",
                    ]
                )
            }
            throw URLError(.cannotDecodeContentData)
        }
        defer { ChekinanaScannerDateMockURLProtocol.asyncHandler = nil }

        let client = ChekinanaScannerClient(
            baseURL: try XCTUnwrap(URL(string: "https://scanner.test")),
            session: scannerDateMockSession()
        )
        let result = try await client.process(
            ChekinanaPendingChekiImage(data: image, filenameExtension: "png"),
            options: scannerOptions(dateRecognitionEnabled: true)
        )
        let requests = await probe.snapshot()

        XCTAssertEqual(result.images.map(\.data), [image])
        XCTAssertEqual(result.images[0].dateAnnotationState, .unavailable)
        XCTAssertEqual(result.warningCount, 2, "failed terminal and one failed GET")
        XCTAssertEqual(requests.counts, ["1": 1, "2": 1])
        XCTAssertEqual(requests.queries, ["date_annotation=1", "date_annotation=1"])
    }

    func testScannerCountsBackendPartialWarningOnceWithoutExpectedMismatchDuplicate() async throws {
        let image = scannerPNGData(color: .orange)
        ChekinanaScannerDateMockURLProtocol.asyncHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/process") {
                return (Data(#"{"task_id":"task-backend-warning"}"#.utf8), [:])
            }
            if path.hasSuffix("/api/status/task-backend-warning") {
                return (
                    Data(#"{"status":"completed","warning":"partial extraction","results_count":1,"expected_polaroids":2,"extraction_complete":true,"results":[{"id":1,"type":"polaroid"}]}"#.utf8),
                    [:]
                )
            }
            return (image, [:])
        }
        defer { ChekinanaScannerDateMockURLProtocol.asyncHandler = nil }

        let client = ChekinanaScannerClient(
            baseURL: try XCTUnwrap(URL(string: "https://scanner.test")),
            session: scannerDateMockSession()
        )
        let result = try await client.process(
            ChekinanaPendingChekiImage(data: image, filenameExtension: "png"),
            options: scannerOptions(
                dateRecognitionEnabled: false,
                expectedPolaroids: 2
            )
        )

        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.warningCount, 1)
    }

    func testScannerFailedGETAndExpectedMismatchCountAsOneIncompleteResultWarning() async throws {
        let image = scannerPNGData(color: .green)
        ChekinanaScannerDateMockURLProtocol.asyncHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/process") {
                return (Data(#"{"task_id":"task-get-warning"}"#.utf8), [:])
            }
            if path.hasSuffix("/api/status/task-get-warning") {
                return (
                    Data(#"{"status":"completed","results_count":2,"expected_polaroids":2,"extraction_complete":true,"results":[{"id":1,"type":"polaroid"},{"id":2,"type":"polaroid"}]}"#.utf8),
                    [:]
                )
            }
            if path.hasSuffix("/1") {
                return (image, [:])
            }
            throw URLError(.cannotDecodeContentData)
        }
        defer { ChekinanaScannerDateMockURLProtocol.asyncHandler = nil }

        let client = ChekinanaScannerClient(
            baseURL: try XCTUnwrap(URL(string: "https://scanner.test")),
            session: scannerDateMockSession()
        )
        let result = try await client.process(
            ChekinanaPendingChekiImage(data: image, filenameExtension: "png"),
            options: scannerOptions(
                dateRecognitionEnabled: false,
                expectedPolaroids: 2
            )
        )

        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.warningCount, 1)
    }

    func testScannerCountsRepeatedBackendWarningOnlyOnceAcrossStatusPolls() async throws {
        let image = scannerPNGData(color: .purple)
        let probe = ScannerRepeatedWarningProbe()
        ChekinanaScannerDateMockURLProtocol.asyncHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/process") {
                return (Data(#"{"task_id":"task-repeated-warning"}"#.utf8), [:])
            }
            if path.hasSuffix("/api/status/task-repeated-warning") {
                return (await probe.nextStatus(), [:])
            }
            return (image, [:])
        }
        defer { ChekinanaScannerDateMockURLProtocol.asyncHandler = nil }

        let client = ChekinanaScannerClient(
            baseURL: try XCTUnwrap(URL(string: "https://scanner.test")),
            session: scannerDateMockSession(),
            statusPollIntervalNanoseconds: 0
        )
        let result = try await client.process(
            ChekinanaPendingChekiImage(data: image, filenameExtension: "png"),
            options: scannerOptions(dateRecognitionEnabled: false)
        )

        let statusCount = await probe.statusCount()
        XCTAssertEqual(statusCount, 2)
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.warningCount, 1)
    }

    func testMonthDayInferrerUsesLocalTodayCrossYearAndNearestLeapDay() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let regularReference = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-04T12:00:00Z")
        )
        XCTAssertEqual(
            ChekinanaMonthDayDateInferrer.mostRecentDate(
                from: "07.04",
                relativeTo: regularReference,
                calendar: utc
            ),
            utcDate(2026, 7, 4)
        )
        XCTAssertEqual(
            ChekinanaMonthDayDateInferrer.mostRecentDate(
                from: "07.03",
                relativeTo: regularReference,
                calendar: utc
            ),
            utcDate(2026, 7, 3)
        )
        XCTAssertEqual(
            ChekinanaMonthDayDateInferrer.mostRecentDate(
                from: "12.31",
                relativeTo: regularReference,
                calendar: utc
            ),
            utcDate(2025, 12, 31)
        )

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let boundaryReference = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-01T00:30:00Z")
        )
        XCTAssertEqual(
            ChekinanaMonthDayDateInferrer.mostRecentDate(
                from: "01.01",
                relativeTo: boundaryReference,
                calendar: losAngeles
            ),
            utcDate(2025, 1, 1)
        )

        for (reference, expected) in [
            ("2026-03-01T00:00:00Z", utcDate(2024, 2, 29)),
            ("2028-02-28T12:00:00Z", utcDate(2024, 2, 29)),
            ("2028-02-29T12:00:00Z", utcDate(2028, 2, 29)),
        ] {
            XCTAssertEqual(
                ChekinanaMonthDayDateInferrer.mostRecentDate(
                    from: "02.29",
                    relativeTo: try XCTUnwrap(
                        ISO8601DateFormatter().date(from: reference)
                    ),
                    calendar: utc
                ),
                expected
            )
        }
    }

    func testScannerDateBoundsAreInclusiveAndMonthDayInferenceStaysInsideRange() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!

        let fixed = try XCTUnwrap(
            ChekinanaScannerDateBounds.fixed(utcDate(2026, 7, 4), calendar: utc)
        )
        XCTAssertFalse(fixed.requestsDateAnnotation)
        XCTAssertEqual(fixed.fixedDate, utcDate(2026, 7, 4))

        let range = try XCTUnwrap(
            ChekinanaScannerDateBounds.range(
                from: utcDate(2025, 12, 31),
                to: utcDate(2026, 1, 2),
                calendar: utc
            )
        )
        XCTAssertTrue(range.contains(utcDate(2025, 12, 31)))
        XCTAssertTrue(range.contains(utcDate(2026, 1, 2)))
        XCTAssertEqual(
            ChekinanaMonthDayDateInferrer.date(
                from: "01.01",
                within: range,
                calendar: utc
            ),
            utcDate(2026, 1, 1)
        )
        XCTAssertNil(
            ChekinanaMonthDayDateInferrer.date(
                from: "12.30",
                within: range,
                calendar: utc
            )
        )

        let recent = try XCTUnwrap(
            ChekinanaScannerDateBounds.recent(
                relativeTo: utcDate(2026, 8, 4),
                calendar: utc
            )
        )
        XCTAssertEqual(recent.scope, .recent)
        XCTAssertEqual(recent.from, utcDate(2025, 8, 4))
        XCTAssertEqual(recent.to, utcDate(2026, 8, 4))
        XCTAssertTrue(recent.contains(recent.from))
        XCTAssertTrue(recent.contains(recent.to))
    }

    func testPatternCandidateFilteringThresholdAndInvalidVectors() throws {
        let firstID = UUID()
        let secondID = UUID()
        var input = Array(repeating: Float.zero, count: 256)
        input[0] = 1
        var first = input
        var second = Array(repeating: Float.zero, count: 256)
        second[1] = 1

        XCTAssertEqual(
            try ChekinanaPatternClassifier.classify(
                embedding: input,
                candidatePatterns: [
                    (firstID, [second, first]),
                    (secondID, [second]),
                ],
                includesUnassigned: true
            ).idolID,
            firstID
        )
        first[0] = 0.5
        first[1] = sqrt(0.75)
        let rejected = try ChekinanaPatternClassifier.classify(
            embedding: input,
            candidatePatterns: [(firstID, [first])],
            includesUnassigned: true
        )
        XCTAssertNil(rejected.idolID)
        XCTAssertLessThan(try XCTUnwrap(rejected.similarity), 0.870)

        let forced = try ChekinanaPatternClassifier.classify(
            embedding: input,
            candidatePatterns: [(secondID, [second])],
            includesUnassigned: false
        )
        XCTAssertEqual(forced.idolID, secondID)
        XCTAssertThrowsError(try ChekinanaPatternClassifier.classify(
            embedding: input,
            candidatePatterns: [
                (firstID, [Array(repeating: .nan, count: 256)]),
                (secondID, [Array(repeating: 0, count: 255)]),
            ],
            includesUnassigned: false
        ))
        XCTAssertNil(try ChekinanaPatternClassifier.classify(
            embedding: input,
            candidatePatterns: [(firstID, [])],
            includesUnassigned: true
        ).idolID)
    }

    func testScanIdolRecognitionUsesCandidateParameterAndOnlyOneIdol() async throws {
        var encoderCalls = 0
        var embedding = Array(repeating: Float.zero, count: 256)
        embedding[0] = 1
        let resultImage = scannerPNGData(color: .red)
        let fixture = try makeFixture(
            scannerProcess: { _, _ in
                ChekinanaScannerProcessResult(images: [resultImage], warningCount: 0)
            },
            patternEncode: { _ in
                encoderCalls += 1
                return embedding
            }
        )
        let first = Idol(name: "First")
        let second = Idol(name: "Second")
        first.patterns = [embedding]
        var secondPattern = Array(repeating: Float.zero, count: 256)
        secondPattern[1] = 1
        second.patterns = [secondPattern]
        fixture.context.insert(first)
        fixture.context.insert(second)
        try fixture.context.save()

        let disabled = await fixture.executor.execute(
            "scancheki",
            pendingChekiImages: [testImage(1)]
        )
        guard case .chekiScannedCards(_, _, let disabledCards) = disabled else {
            return XCTFail("expected disabled scan cards")
        }
        XCTAssertEqual(encoderCalls, 0)
        XCTAssertTrue(try fixture.ledger.resolveTemporaryCheki(
            shortID(disabledCards[0].id)
        ).idolIDs.isEmpty)

        let narrow = await fixture.executor.execute(
            "scancheki idol_recognition=true candidates=\(second.id.uuidString.lowercased()),unassigned",
            pendingChekiImages: [testImage(2)]
        )
        guard case .chekiScannedCards(_, _, let narrowCards) = narrow else {
            return XCTFail("expected narrow scan cards")
        }
        XCTAssertEqual(encoderCalls, 1)
        XCTAssertTrue(try fixture.ledger.resolveTemporaryCheki(
            shortID(narrowCards[0].id)
        ).idolIDs.isEmpty)

        let defaultCandidates = await fixture.executor.execute(
            "scancheki idol_recognition=true",
            pendingChekiImages: [testImage(3)]
        )
        guard case .chekiScannedCards(_, _, let defaultCards) = defaultCandidates else {
            return XCTFail("expected recognized scan cards")
        }
        XCTAssertEqual(encoderCalls, 2)
        XCTAssertEqual(
            try fixture.ledger.resolveTemporaryCheki(
                shortID(defaultCards[0].id)
            ).idolIDs,
            [first.id]
        )
    }

    func testCoreMLPatternEncoderLoadsAndReturnsNormalized256Vector() async throws {
        let embedding = try await ChekinanaPatternEncoder.shared.encode(
            scannerPNGData(color: .orange)
        )
        XCTAssertEqual(embedding.count, 256)
        XCTAssertTrue(embedding.allSatisfy(\.isFinite))
        let norm = sqrt(embedding.reduce(Float.zero) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1, accuracy: 0.0001)
    }

    func testProgrammaticRGBFixtureMatchesPythonPreprocessAndPyTorchGolden() async throws {
        let width = 173
        let height = 109
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                var red = x * 255 / (width - 1)
                var green = y * 255 / (height - 1)
                var blue = (x + 2 * y) * 255
                    / (width - 1 + 2 * (height - 1))
                if (12..<68).contains(x), (9..<35).contains(y) {
                    (red, green, blue) = (242, 28, 75)
                }
                if (101..<164).contains(x), (61..<102).contains(y) {
                    (red, green, blue) = (18, 221, 147)
                }
                if abs(2 * x - 3 * y - 20) < 6 {
                    (red, green, blue) = (35, 85, 235)
                }
                if x < 10 || x >= width - 10
                    || y < 10 || y >= height - 10
                    || (65..<75).contains(y) {
                    (red, green, blue) = (93, 147, 201)
                }
                pixels[offset] = UInt8(red)
                pixels[offset + 1] = UInt8(green)
                pixels[offset + 2] = UInt8(blue)
                pixels[offset + 3] = 255
            }
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        )
        let provider = try XCTUnwrap(
            CGDataProvider(data: Data(pixels) as CFData)
        )
        let image = try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        let imageData = try XCTUnwrap(UIImage(cgImage: image).pngData())
        let regions = try ChekinanaPatternImagePreprocessor.regions(
            from: imageData
        )
        var channelSums = [Double](repeating: 0, count: 6)
        for channel in 0..<6 {
            for position in 0..<(256 * 256) {
                channelSums[channel] += Double(
                    regions[channel * 256 * 256 + position].floatValue
                )
            }
        }
        let probes = [
            15_390, 20_560, 18_120, 38_440,
            47_570, 26_910, 33_360, 37_320,
        ]
        let probeValues = (0..<6).map { channel in
            probes.map {
                regions[channel * 256 * 256 + $0].floatValue
            }
        }
        print("PROGRAMMATIC_REGIONS sums=\(channelSums) probes=\(probeValues)")
        let pythonChannelSums = [
            -22301.5820, 23646.6895, 75980.9453,
            -39508.3672, 43525.5781, 104410.8281,
        ]
        for channel in 0..<6 {
            XCTAssertEqual(
                channelSums[channel],
                pythonChannelSums[channel],
                accuracy: 1,
                "channel \(channel), probes \(probeValues[channel])"
            )
        }
        let pythonProbeValues: [[Float]] = [
            [
                -0.71367413, 2.02628636, 1.30704677, -0.52530187,
                -1.80965841, -1.62128615, -0.74792361, -0.52530187,
            ],
            [
                0.69537824, -1.54551816, -1.40546203, 0.53781521,
                1.83333325, -0.42506999, 0.27521020, 0.53781521,
            ],
            [
                1.85568643, -0.49725482, 0.07790857, 1.69882369,
                0.75764722, -0.68897593, 0.09533776, 1.69882369,
            ],
            [
                -0.52530187, -0.52530187, -0.52530187, -0.52530187,
                -0.52530187, -0.52530187, -0.74792361, -0.88492167,
            ],
            [
                0.53781521, 0.53781521, 0.53781521, 0.53781521,
                0.53781521, 0.53781521, 1.62324929, 0.88795525,
            ],
            [
                1.69882369, 1.69882369, 1.69882369, 1.69882369,
                1.69882369, 1.69882369, 0.84479320, 1.43738580,
            ],
        ]
        for channel in 0..<6 {
            for probe in probes.indices {
                XCTAssertEqual(
                    probeValues[channel][probe],
                    pythonProbeValues[channel][probe],
                    accuracy: 0.01,
                    "channel \(channel), probe \(probe)"
                )
            }
        }
        let actual = try await ChekinanaPatternEncoder.shared.encode(imageData)
        let golden: [Float] = [
            0.0725212917, -0.00687094685, -0.000636380923, -0.0846997872,
            -0.0175135937, 0.0625780523, 0.123147815, 0.0414632373,
            0.0570417717, 0.0456279404, -0.161208987, 0.0742051378,
            0.0314567462, 0.0865700692, 0.0954407454, 0.0733082220,
            0.0111938454, -0.0386517681, -0.00472336588, -0.0688400194,
            0.0133485468, 0.0183948707, 0.0372149944, -0.0213270802,
            0.0842645168, -0.0388381295, -0.0374499410, -0.0870473981,
            -0.0361998118, 0.0311967488, -0.0218826402, -0.0201884620,
            -0.0231460202, -0.0821777508, -0.0997745320, 0.0282031149,
            0.0953113660, 0.00315372576, -0.0459278002, -0.0106899673,
            -0.00592989894, -0.0298488718, -0.0185325462, 0.102790169,
            0.0187262949, 0.0204326119, 0.00974773895, -0.0108098667,
            0.0168551896, 0.0330322608, -0.208464146, -0.0605190732,
            0.0511328429, -0.0276442319, 0.0444437601, -0.0229803640,
            0.0386974402, -0.0511341579, -0.00687084300, -0.0912948772,
            -0.0827408731, 0.0332511142, -0.00146703224, 0.0346262157,
            0.0437787436, -0.0930141285, 0.131589904, -0.0588957891,
            -0.0433120094, -0.0127963079, 0.140644312, -0.0343769751,
            -0.0124813551, 0.0441630594, 0.117277674, 0.0289509576,
            0.0810370073, -0.0653534904, 0.0528785065, -0.0485536940,
            0.0834806189, -0.0755552426, -0.0818384960, -0.0208076779,
            0.0375742391, -0.00653694849, 0.0294807386, -0.0355624706,
            0.0362790115, 0.0337346941, 0.132088676, 0.0246877912,
            0.0889804363, 0.00585621223, -0.0176474191, 0.0769382864,
            0.00327819819, -0.0393624417, 0.0383223444, -0.0381498970,
            -0.0219423808, -0.0617229231, 0.0404706001, -0.0496664494,
            0.0135001345, -0.184699580, 0.0777480528, -0.0912295505,
            -0.0566198528, 0.00598990684, 0.0603609532, -0.0899937302,
            0.0315520912, 0.00301805395, 0.0614021756, 0.0290511195,
            -0.000714637572, -0.0379150920, 0.00234945258, 0.00854735915,
            -0.0169374142, -0.0567057617, 0.0736092553, -0.0880015492,
            0.0958312899, -0.0299252234, 0.0142187951, 0.00890577119,
            0.164423645, -0.0482513420, 0.00755315460, 0.00330634112,
            -0.0245469343, 0.0175219383, -0.105861485, 0.111925438,
            0.0201105028, -0.0291187018, 0.0192648880, -0.0798227042,
            0.00197280874, 0.119433358, -0.0536122769, 0.0264941324,
            0.0298483577, -0.0142151956, -0.0548266508, -0.0550749823,
            -0.00764731085, -0.0663338304, 0.0288229939, 0.0240231287,
            0.133502305, 0.0725791678, 0.208857939, 0.0662593320,
            0.0839707553, 0.0341417268, 0.0293115266, 0.0209284667,
            0.0517579094, 0.0195036996, 0.0628548041, -0.0588774681,
            -0.0649281815, 0.0685424656, -0.00510945357, 0.0176092088,
            -0.0142338518, 0.00788452104, -0.00854529720, -0.0212203246,
            -0.00761662284, -0.0605945364, 0.0740916580, -0.0583618656,
            0.0507487394, -0.0815222263, 0.0908433720, -0.0804874822,
            -0.0309629645, 0.0456575006, -0.0916805565, 0.0664083287,
            -0.0360535346, -0.0281646959, -0.100025289, -0.0363883674,
            0.00794025511, -0.0434956625, 0.0160437394, 0.0396048799,
            -0.00765675632, -0.140608296, -0.00827927422, 0.0971146151,
            -0.0182924680, -0.0275697783, -0.0361004621, -0.122415699,
            0.0296876952, 0.0288672522, -0.0928709805, -0.0837269276,
            -0.0191547479, -0.0765387863, 0.0833557770, -0.0508373268,
            -0.0280922577, 0.0919790491, -0.0331079178, -0.000604305940,
            -0.0402973667, 0.0324589275, -0.0000396513278, 0.0102466280,
            0.0201735478, -0.0697290897, 0.00473863585, 0.0279184114,
            -0.0523936935, -0.0546040349, -0.0148675069, 0.100977451,
            -0.0427692793, -0.0371432491, 0.168809086, 0.0249470938,
            -0.00334075280, -0.0541291237, -0.0324352942, 0.0773166493,
            -0.0317974128, -0.0438425690, 0.0759449527, -0.00811036676,
            -0.0472382605, -0.0663752332, 0.0340514407, 0.0486679450,
            0.0596038438, -0.0432738960, 0.0359881334, 0.0582022928,
            -0.0363650247, 0.130805224, 0.0196349323, 0.0614129864,
            -0.114544585, -0.0301792547, 0.0731824711, 0.0790550783,
            0.00558637362, 0.0154532250, 0.0361600816, -0.0557503626,
        ]

        XCTAssertEqual(actual.count, golden.count)
        let differences = zip(actual, golden).map {
            abs(Double($0.0) - Double($0.1))
        }
        let maxDifference = try XCTUnwrap(differences.max())
        let meanDifference = differences.reduce(0, +) / Double(differences.count)
        let dot = zip(actual, golden).reduce(0.0) {
            $0 + Double($1.0) * Double($1.1)
        }
        let actualNorm = sqrt(actual.reduce(0.0) {
            $0 + Double($1) * Double($1)
        })
        let goldenNorm = sqrt(golden.reduce(0.0) {
            $0 + Double($1) * Double($1)
        })
        let cosine = dot / (actualNorm * goldenNorm)
        print(
            "PROGRAMMATIC_PARITY cosine=\(cosine) "
                + "max=\(maxDifference) mean=\(meanDifference)"
        )

        XCTAssertGreaterThan(cosine, 0.999)
        XCTAssertLessThan(maxDifference, 0.01)
        XCTAssertLessThan(meanDifference, 0.002)
    }

    func testDateOnlyUsesTheCalendarDateVisibleToTheUser() throws {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let shanghaiSelection = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-15T16:30:00Z")
        )
        XCTAssertEqual(
            ChekinanaDateOnly.canonicalDate(
                from: shanghaiSelection,
                displayedIn: shanghai
            ),
            ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z")
        )

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/Los_Angeles")
        )
        let losAngelesSelection = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-16T06:30:00Z")
        )
        XCTAssertEqual(
            ChekinanaDateOnly.canonicalDate(
                from: losAngelesSelection,
                displayedIn: losAngeles
            ),
            ISO8601DateFormatter().date(from: "2026-07-15T00:00:00Z")
        )
    }

    func testCanonicalDateOnlyDisplaysAndSavesTheSameYMDInDifferentTimeZones() throws {
        let canonical = utcDate(2026, 8, 4)
        for identifier in ["Asia/Shanghai", "America/Los_Angeles"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
            let displayed = try XCTUnwrap(
                ChekinanaDateOnly.displayDate(from: canonical, calendar: calendar)
            )
            let components = calendar.dateComponents([.year, .month, .day], from: displayed)
            XCTAssertEqual(components.year, 2026, identifier)
            XCTAssertEqual(components.month, 8, identifier)
            XCTAssertEqual(components.day, 4, identifier)
            XCTAssertEqual(
                ChekinanaDateOnly.canonicalDate(from: displayed, displayedIn: calendar),
                canonical,
                identifier
            )
        }
    }


    func testScannerRuntimeClientUsesOneWebSocketUntilReadyAndSendsNoSecret() async throws {
        let probe = ScannerRuntimeFailureProbe()
        ChekinanaRuntimeMockURLProtocol.handler = { request in
            await probe.response(for: request)
        }
        defer { ChekinanaRuntimeMockURLProtocol.handler = nil }
        let startProbe = ScannerRuntimeStartFactoryProbe(frames: [
            scannerRuntimeJSON(state: "closed"),
            scannerRuntimeJSON(state: "preparing"),
            scannerRuntimeJSON(state: "ready"),
        ])
        let client = ChekinanaScannerRuntimeClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession(),
            startSocketFactory: { request in
                await startProbe.open(request)
            }
        )

        let closed = try await client.status()
        XCTAssertEqual(closed.state, .closed)
        XCTAssertTrue(closed.retryAllowed)
        XCTAssertTrue(closed.canStart)
        let ready = try await client.start()
        XCTAssertEqual(ready.state, .ready)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.methods, ["GET"])
        XCTAssertFalse(snapshot.sawSensitiveTransport)
        let startSnapshot = await startProbe.snapshot()
        XCTAssertEqual(startSnapshot.connectionCount, 1)
        XCTAssertEqual(startSnapshot.receiveCount, 3)
        XCTAssertEqual(startSnapshot.cancelCount, 1)
        XCTAssertEqual(startSnapshot.method, "GET")
        XCTAssertEqual(startSnapshot.scheme, "wss")
        XCTAssertEqual(startSnapshot.path, "/api/scanner/runtime/start")
        XCTAssertEqual(startSnapshot.timeout, 16 * 60)
        XCTAssertFalse(startSnapshot.sawSensitiveTransport)
    }

    func testScannerRuntimeProgressDecodesBackwardCompatiblyAndRejectsInvalidValues() throws {
        let absent = try JSONDecoder().decode(
            ChekinanaScannerRuntimeStatus.self,
            from: scannerRuntimeJSON(state: "preparing")
        )
        XCTAssertNil(absent.progress)

        for current in 1...3 {
            let status = try JSONDecoder().decode(
                ChekinanaScannerRuntimeStatus.self,
                from: scannerRuntimeProgressJSON(current: current, total: 3)
            )
            XCTAssertEqual(status.progress, .init(current: current, total: 3))
        }

        let invalidFixtures = [
            scannerRuntimeProgressJSON(current: 0, total: 3),
            scannerRuntimeProgressJSON(current: 4, total: 3),
            scannerRuntimeProgressJSON(current: 1, total: 4),
            Data(#"{"ok":true,"state":"ready","phase":"ready","progress":{"current":3,"total":3}}"#.utf8),
            Data(#"{"ok":true,"state":"preparing","phase":"preparing","progress":{"current":"1","total":3}}"#.utf8),
        ]
        for fixture in invalidFixtures {
            let status = try JSONDecoder().decode(
                ChekinanaScannerRuntimeStatus.self,
                from: fixture
            )
            XCTAssertNil(status.progress)
        }
    }

    func testScannerRuntimeStartPublishesEveryProgressFrameUntilReady() async throws {
        let capture = ScannerRuntimeStatusCaptureProbe()
        let startProbe = ScannerRuntimeStartFactoryProbe(frames: [
            scannerRuntimeJSON(state: "closed"),
            scannerRuntimeProgressJSON(current: 1, total: 3),
            scannerRuntimeProgressJSON(current: 2, total: 3),
            scannerRuntimeProgressJSON(current: 3, total: 3),
            scannerRuntimeJSON(state: "ready"),
        ])
        let client = ChekinanaScannerRuntimeClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession(),
            startSocketFactory: { request in
                await startProbe.open(request)
            }
        )

        let ready = try await client.start { status in
            await capture.append(status)
        }

        XCTAssertEqual(ready.state, .ready)
        let updates = await capture.snapshot()
        XCTAssertEqual(updates.map(\.state), [
            .closed, .preparing, .preparing, .preparing, .ready,
        ])
        XCTAssertEqual(updates.compactMap(\.progress?.current), [1, 2, 3])
    }

    func testScannerRuntimeWebSocketClosesOnFixedFailureWithoutStatusPolling() async throws {
        let startProbe = ScannerRuntimeStartFactoryProbe(frames: [
            scannerRuntimeJSON(state: "closed"),
            scannerRuntimeJSON(state: "preparing"),
            Data(#"{"ok":false,"state":"closed","phase":"closed","message":"No GPU is currently available.","retryAllowed":true,"canStart":true,"canTerminate":false}"#.utf8),
        ])
        let client = ChekinanaScannerRuntimeClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession(),
            startSocketFactory: { request in
                await startProbe.open(request)
            }
        )

        let failure = try await client.start()

        XCTAssertFalse(failure.ok)
        XCTAssertEqual(failure.state, .closed)
        XCTAssertEqual(failure.message, "No GPU is currently available.")
        let snapshot = await startProbe.snapshot()
        XCTAssertEqual(snapshot.connectionCount, 1)
        XCTAssertEqual(snapshot.receiveCount, 3)
        XCTAssertEqual(snapshot.cancelCount, 1)
    }

    func testScannerRuntimeClientUsesOperationSpecificHTTPTimeouts() async throws {
        let probe = ScannerRuntimeTimeoutProbe()
        ChekinanaRuntimeMockURLProtocol.handler = { request in
            await probe.response(for: request)
        }
        defer { ChekinanaRuntimeMockURLProtocol.handler = nil }
        let client = ChekinanaScannerRuntimeClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession()
        )

        _ = try await client.status()
        _ = try await client.stop()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot["GET /api/scanner/runtime"], 7)
        XCTAssertEqual(snapshot["POST /api/scanner/runtime/stop"], 25)
    }

    func testGPUStatusContractAndControlsExposeOnlyClosedPreparingReady() throws {
        let fixtures: [(String, ChekinanaScannerRuntimeState, ChekinanaGPUControlAction)] = [
            (#"{"ok":true,"state":"closed","phase":"closed","retryAllowed":true,"canStart":true,"canTerminate":false}"#, .closed, .start),
            (#"{"ok":true,"state":"preparing","phase":"preparing","retryAllowed":false,"canStart":false,"canTerminate":false}"#, .preparing, .none),
            (#"{"ok":true,"state":"ready","phase":"ready","retryAllowed":false,"canStart":false,"canTerminate":true}"#, .ready, .terminate),
        ]

        for (json, expectedState, expectedAction) in fixtures {
            let status = try JSONDecoder().decode(
                ChekinanaScannerRuntimeStatus.self,
                from: Data(json.utf8)
            )
            XCTAssertEqual(status.state, expectedState)
            XCTAssertEqual(status.phase, expectedState.rawValue)
            XCTAssertEqual(
                ChekinanaGPUStatusPresentation.controlAction(
                    status: status,
                    isRefreshing: false
                ),
                expectedAction
            )
            XCTAssertEqual(
                ChekinanaGPUStatusPresentation.allowsGPUInput(status),
                expectedState == .ready
            )
        }
        XCTAssertEqual(
            ChekinanaGPUStatusPresentation.visibleState(status: nil, isRefreshing: true),
            .preparing
        )
        XCTAssertEqual(
            ChekinanaGPUStatusPresentation.visibleState(status: nil, isRefreshing: false),
            .closed
        )
        XCTAssertTrue(ChekinanaGPUStatusPresentation.showsPreparationProgress(
            visibleState: .preparing,
            isStarting: false,
            isShuttingDown: false
        ))
        XCTAssertTrue(ChekinanaGPUStatusPresentation.showsPreparationProgress(
            visibleState: .preparing,
            isStarting: true,
            isShuttingDown: false
        ))
        XCTAssertFalse(ChekinanaGPUStatusPresentation.showsPreparationProgress(
            visibleState: .preparing,
            isStarting: false,
            isShuttingDown: true
        ))
        let legacyClosed = try JSONDecoder().decode(
            ChekinanaScannerRuntimeStatus.self,
            from: Data(
                #"{"ok":true,"state":"closed","phase":"closed","retryAllowed":true}"#.utf8
            )
        )
        let legacyReady = try JSONDecoder().decode(
            ChekinanaScannerRuntimeStatus.self,
            from: Data(
                #"{"ok":true,"state":"ready","phase":"ready","retryAllowed":false}"#.utf8
            )
        )
        XCTAssertFalse(legacyClosed.canStart)
        XCTAssertFalse(legacyReady.canTerminate)
        XCTAssertEqual(
            ChekinanaGPUStatusPresentation.controlAction(
                status: legacyClosed,
                isRefreshing: false
            ),
            .none
        )

        let capacityFailure = ChekinanaScannerRuntimeStatus(
            state: .closed,
            phase: "closed",
            message: "No GPU is currently available.",
            retryAllowed: true,
            canStart: true,
            canTerminate: false
        )
        XCTAssertEqual(
            ChekinanaGPUStatusPresentation.message(
                status: capacityFailure,
                requestError: nil
            ),
            "No GPU is currently available."
        )
        let scheduledTermination = ChekinanaScannerRuntimeStatus(
            state: .preparing,
            phase: "preparing",
            message: "Termination scheduled in 60 seconds.",
            retryAllowed: false
        )
        XCTAssertNil(ChekinanaGPUStatusPresentation.message(
            status: scheduledTermination,
            requestError: nil
        ))
        let busyFailure = ChekinanaScannerRuntimeStatus(
            ok: false,
            state: .ready,
            phase: "ready",
            message: "A scan is still active.",
            retryAllowed: true,
            canTerminate: false
        )
        XCTAssertEqual(
            ChekinanaGPUStatusPresentation.message(
                status: busyFailure,
                requestError: nil
            ),
            "A scan is still active."
        )
        let unavailable = ChekinanaScannerRuntimeStatus.clientUnavailable(
            message: "Unable to refresh GPU status."
        )
        XCTAssertFalse(unavailable.canStart)
        XCTAssertEqual(
            ChekinanaGPUStatusPresentation.controlAction(
                status: unavailable,
                isRefreshing: false
            ),
            .none
        )
        XCTAssertEqual(
            ChekinanaGPUStatusPresentation.message(
                status: unavailable,
                requestError: unavailable.message
            ),
            "Unable to refresh GPU status."
        )
    }

    func testTemporaryPodCapacityErrorDecodesAndMapsToLocalGPUMessage() throws {
        let status = try JSONDecoder().decode(
            ChekinanaScannerRuntimeStatus.self,
            from: Data(
                #"{"ok":false,"state":"closed","phase":"closed","message":"server message","error":"temporary_pod_create_failed","retryAllowed":true,"canStart":true,"canTerminate":false}"#.utf8
            )
        )

        XCTAssertEqual(status.error, "temporary_pod_create_failed")
        XCTAssertEqual(
            ChekinanaGPUStatusPresentation.message(
                status: status,
                requestError: "transport message"
            ),
            "GPU out of capacity, try later"
        )
    }

    func testScanGPUPreflightAllowsOfflineImportAndBlocksGPUOrMixedQueues() {
        let closed = ChekinanaScannerRuntimeStatus(
            state: .closed,
            phase: "closed",
            retryAllowed: true
        )
        let ready = ChekinanaScannerRuntimeStatus(
            state: .ready,
            phase: "ready",
            retryAllowed: false
        )
        XCTAssertEqual(
            ChekinanaScanGPUPreflight.decision(
                status: closed,
                hasGPUInput: false,
                hasDirectInput: true
            ),
            .allowDirectOnly
        )
        XCTAssertEqual(
            ChekinanaScanGPUPreflight.decision(
                status: closed,
                hasGPUInput: true,
                hasDirectInput: false
            ),
            .blockGPUOnly
        )
        XCTAssertEqual(
            ChekinanaScanGPUPreflight.decision(
                status: nil,
                hasGPUInput: true,
                hasDirectInput: true
            ),
            .blockMixed
        )
        XCTAssertEqual(
            ChekinanaScanGPUPreflight.decision(
                status: ready,
                hasGPUInput: true,
                hasDirectInput: true
            ),
            .allowAll
        )
        XCTAssertTrue(ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled)
        XCTAssertEqual(
            ChekinanaTemporaryGPUManagementPolicy.preflight(
                hasGPUInput: false,
                hasDirectInput: true
            ),
            .allowDirectOnly
        )
        XCTAssertEqual(
            ChekinanaTemporaryGPUManagementPolicy.preflight(
                hasGPUInput: true,
                hasDirectInput: false
            ),
            .blockGPUOnly
        )
        XCTAssertEqual(
            ChekinanaTemporaryGPUManagementPolicy.preflight(
                hasGPUInput: true,
                hasDirectInput: true
            ),
            .blockMixed
        )
    }

    func testRuntimeConfirmationSchedulerUsesOneExactDelayPerTrigger() async {
        XCTAssertEqual(
            ChekinanaScannerRuntimeRefreshScheduler.stopConfirmationDelayNanoseconds,
            40_000_000_000
        )
        XCTAssertEqual(
            ChekinanaScannerRuntimeRefreshScheduler.lastScanConfirmationDelayNanoseconds,
            140_000_000_000
        )
        let probe = ScannerRuntimeSchedulerProbe()
        let scheduler = ChekinanaScannerRuntimeRefreshScheduler { delay in
            await probe.recordDelay(delay)
        }

        scheduler.scheduleStopConfirmation {
            await probe.recordRequest("stop")
        }
        scheduler.scheduleLastScanConfirmation {
            await probe.recordRequest("scan")
        }
        for _ in 0..<10 { await Task.yield() }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(
            snapshot.delays.sorted(),
            [
                ChekinanaScannerRuntimeRefreshScheduler.stopConfirmationDelayNanoseconds,
                ChekinanaScannerRuntimeRefreshScheduler.lastScanConfirmationDelayNanoseconds,
            ].sorted()
        )
        XCTAssertEqual(snapshot.requests.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(snapshot.requests.filter { $0 == "scan" }.count, 1)
    }

    func testLastScanConfirmationSupersedesEarlierPendingConfirmation() async {
        let probe = ScannerRuntimeSchedulerProbe()
        let scheduler = ChekinanaScannerRuntimeRefreshScheduler { delay in
            await probe.recordDelay(delay)
        }

        scheduler.scheduleLastScanConfirmation {
            await probe.recordRequest("superseded")
        }
        scheduler.scheduleLastScanConfirmation {
            await probe.recordRequest("last")
        }
        for _ in 0..<10 { await Task.yield() }

        let snapshot = await probe.snapshot()
        XCTAssertFalse(snapshot.requests.contains("superseded"))
        XCTAssertEqual(snapshot.requests, ["last"])
    }

    func testLateDelayedRuntimeGETCannotOverwriteNewerStartReady() async {
        let probe = ScannerRuntimeStoreOperationProbe()
        let scheduler = ChekinanaScannerRuntimeRefreshScheduler { _ in }
        let store = ChekinanaScannerRuntimePresentationStore(
            refreshScheduler: scheduler,
            statusRequest: { await probe.statusRequest() },
            startRequest: { await probe.startRequest() }
        )
        store.scheduleLastScanConfirmation()
        for _ in 0..<20 {
            if await probe.snapshot().statusCount == 1 { break }
            await Task.yield()
        }
        let delayedSnapshot = await probe.snapshot()
        XCTAssertEqual(delayedSnapshot.statusCount, 1)

        store.requestStart()
        for _ in 0..<20 {
            if await probe.snapshot().startCount == 1 { break }
            await Task.yield()
        }
        await probe.completeNextStart(.init(
            state: .ready,
            phase: "ready",
            retryAllowed: false,
            canStart: false,
            canTerminate: true
        ))
        for _ in 0..<20 {
            if !store.isStarting { break }
            await Task.yield()
        }
        XCTAssertEqual(store.status?.state, .ready)

        await probe.completeNextStatus(.init(
            state: .closed,
            phase: "closed",
            retryAllowed: true,
            canStart: true,
            canTerminate: false
        ))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(store.status?.state, .ready)
        XCTAssertFalse(store.isStarting)
    }

    func testSharedRuntimeStoreCoalescesEquivalentPageStartRequests() async {
        let probe = ScannerRuntimeStoreOperationProbe()
        let store = ChekinanaScannerRuntimePresentationStore(
            startRequest: { await probe.startRequest() }
        )

        store.requestStart()
        store.requestStart()
        for _ in 0..<20 {
            if await probe.snapshot().startCount == 1 { break }
            await Task.yield()
        }

        XCTAssertTrue(store.isStarting)
        let coalescedSnapshot = await probe.snapshot()
        XCTAssertEqual(coalescedSnapshot.startCount, 1)
        await probe.completeNextStart(.init(
            state: .ready,
            phase: "ready",
            retryAllowed: false,
            canStart: false,
            canTerminate: true
        ))
        for _ in 0..<20 {
            if !store.isStarting { break }
            await Task.yield()
        }

        XCTAssertFalse(store.isStarting)
        XCTAssertFalse(store.isControlInFlight)
        XCTAssertEqual(store.status?.state, .ready)
        let completedSnapshot = await probe.snapshot()
        XCTAssertEqual(completedSnapshot.startCount, 1)
    }

    func testRuntimeStoreIgnoresInitialClosedAndLateProgressAfterCancel() async {
        let probe = ScannerRuntimeStreamingStartProbe()
        let store = ChekinanaScannerRuntimePresentationStore(
            streamingStartRequest: { update in
                await probe.start(update: update)
            }
        )

        store.requestStart()
        for _ in 0..<20 {
            if await probe.isStarted { break }
            await Task.yield()
        }

        await probe.emit(.init(
            state: .closed,
            phase: "closed",
            retryAllowed: true,
            canStart: true,
            canTerminate: false
        ))
        XCTAssertEqual(store.status?.state, .preparing)
        XCTAssertNil(store.status?.progress)

        for current in 1...3 {
            await probe.emit(.init(
                state: .preparing,
                phase: "preparing",
                retryAllowed: false,
                canStart: false,
                canTerminate: false,
                progress: .init(current: current, total: 3)
            ))
            XCTAssertEqual(store.status?.progress?.current, current)
        }

        store.cancelStart()
        await probe.emit(.init(
            state: .preparing,
            phase: "preparing",
            retryAllowed: false,
            progress: .init(current: 1, total: 3)
        ))
        await probe.finish(.init(
            state: .ready,
            phase: "ready",
            retryAllowed: false,
            canStart: false,
            canTerminate: true
        ))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(store.isStarting)
        XCTAssertEqual(store.status?.state, .closed)
        XCTAssertNil(store.status?.progress)
    }

    func testSharedRuntimeStartFailureCleansUpAndCanRetry() async {
        let probe = ScannerRuntimeStoreOperationProbe()
        let store = ChekinanaScannerRuntimePresentationStore(
            startRequest: { await probe.startRequest() }
        )

        store.requestStart()
        for _ in 0..<20 {
            if await probe.snapshot().startCount == 1 { break }
            await Task.yield()
        }
        await probe.completeNextStart(.init(
            ok: false,
            state: .closed,
            phase: "closed",
            message: "fixed startup failure",
            retryAllowed: true,
            canStart: true,
            canTerminate: false
        ))
        for _ in 0..<20 {
            if !store.isStarting { break }
            await Task.yield()
        }
        XCTAssertFalse(store.isStarting)
        XCTAssertEqual(store.status?.state, .closed)

        store.requestStart()
        for _ in 0..<20 {
            if await probe.snapshot().startCount == 2 { break }
            await Task.yield()
        }
        let retrySnapshot = await probe.snapshot()
        XCTAssertEqual(retrySnapshot.startCount, 2)
        await probe.completeNextStart(.init(
            state: .ready,
            phase: "ready",
            retryAllowed: false,
            canStart: false,
            canTerminate: true
        ))
        for _ in 0..<20 {
            if !store.isStarting { break }
            await Task.yield()
        }

        XCTAssertFalse(store.isStarting)
        XCTAssertEqual(store.status?.state, .ready)
    }

    func testSharedRuntimeExplicitCancelClosesStartSocket() async {
        let socket = ScannerRuntimeBlockingStartSocketProbe()
        let client = ChekinanaScannerRuntimeClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession(),
            startSocketFactory: { _ in socket }
        )
        let store = ChekinanaScannerRuntimePresentationStore(
            startRequest: { try await client.start() }
        )

        store.requestStart()
        for _ in 0..<20 {
            if socket.snapshot().receiveCount == 1 { break }
            await Task.yield()
        }
        store.cancelStart()
        for _ in 0..<20 { await Task.yield() }

        let snapshot = socket.snapshot()
        XCTAssertEqual(snapshot.receiveCount, 1)
        XCTAssertGreaterThanOrEqual(snapshot.cancelCount, 1)
        XCTAssertFalse(store.isStarting)
        XCTAssertEqual(store.status?.state, .closed)
    }

    func testStopInFlightBlocksGPUInputsAndPreflightButKeepsImportAvailable() async {
        let probe = ScannerRuntimeStoreOperationProbe()
        let store = ChekinanaScannerRuntimePresentationStore(
            statusRequest: { await probe.statusRequest() },
            stopRequest: { await probe.stopRequest() }
        )
        let refresh = Task { await store.refreshManually() }
        for _ in 0..<20 {
            if await probe.snapshot().statusCount == 1 { break }
            await Task.yield()
        }
        await probe.completeNextStatus(.init(
            state: .ready,
            phase: "ready",
            retryAllowed: false,
            canStart: false,
            canTerminate: true
        ))
        await refresh.value

        store.requestStop()
        for _ in 0..<20 {
            if await probe.snapshot().stopCount == 1 { break }
            await Task.yield()
        }
        XCTAssertTrue(store.isStopping)
        XCTAssertTrue(store.isShuttingDown)
        XCTAssertFalse(ChekinanaGPUStatusPresentation.allowsGPUInput(
            store.status,
            isControlInFlight: store.isControlInFlight
        ))
        XCTAssertFalse(ChekinanaScanStartRuntimeGate.allowsStart(
            hasGPUInput: true,
            gpuInputsEnabled: false
        ))
        XCTAssertTrue(ChekinanaScanStartRuntimeGate.allowsStart(
            hasGPUInput: false,
            gpuInputsEnabled: false
        ))
        XCTAssertEqual(
            ChekinanaScanGPUPreflight.decision(
                status: store.status,
                hasGPUInput: true,
                hasDirectInput: false,
                isControlInFlight: store.isControlInFlight
            ),
            .blockGPUOnly
        )
        XCTAssertEqual(
            ChekinanaScanGPUPreflight.decision(
                status: store.status,
                hasGPUInput: false,
                hasDirectInput: true,
                isControlInFlight: store.isControlInFlight
            ),
            .allowDirectOnly
        )
        XCTAssertEqual(
            ChekinanaScanGPUPreflight.decision(
                status: store.status,
                hasGPUInput: true,
                hasDirectInput: true,
                isControlInFlight: store.isControlInFlight
            ),
            .blockMixed
        )

        await probe.completeNextStop(.init(
            ok: false,
            state: .ready,
            phase: "ready",
            message: "scan still active",
            retryAllowed: true,
            canStart: false,
            canTerminate: false
        ))
        for _ in 0..<20 {
            if !store.isStopping { break }
            await Task.yield()
        }

        XCTAssertFalse(store.isStopping)
        XCTAssertFalse(store.isShuttingDown)
        XCTAssertTrue(ChekinanaGPUStatusPresentation.allowsGPUInput(
            store.status,
            isControlInFlight: store.isControlInFlight
        ))
        XCTAssertEqual(
            ChekinanaScanGPUPreflight.decision(
                status: store.status,
                hasGPUInput: true,
                hasDirectInput: false,
                isControlInFlight: store.isControlInFlight
            ),
            .allowAll
        )
    }

    func testSuccessfulStopStaysStaticShuttingDownUntilGETReturnsClosed() async {
        let operationProbe = ScannerRuntimeStoreOperationProbe()
        let schedulerProbe = ScannerRuntimeSchedulerProbe()
        let scheduler = ChekinanaScannerRuntimeRefreshScheduler { delay in
            await schedulerProbe.recordDelay(delay)
        }
        let store = ChekinanaScannerRuntimePresentationStore(
            refreshScheduler: scheduler,
            statusRequest: { await operationProbe.statusRequest() },
            stopRequest: { await operationProbe.stopRequest() }
        )
        let initialRefresh = Task { await store.refreshManually() }
        for _ in 0..<20 {
            if await operationProbe.snapshot().statusCount == 1 { break }
            await Task.yield()
        }
        await operationProbe.completeNextStatus(.init(
            state: .ready,
            phase: "ready",
            retryAllowed: false,
            canStart: false,
            canTerminate: true
        ))
        await initialRefresh.value

        store.requestStop()
        XCTAssertTrue(store.isShuttingDown)
        XCTAssertFalse(ChekinanaGPUStatusPresentation.showsPreparationProgress(
            visibleState: .ready,
            isStarting: false,
            isShuttingDown: store.isShuttingDown
        ))
        for _ in 0..<20 {
            if await operationProbe.snapshot().stopCount == 1 { break }
            await Task.yield()
        }
        await operationProbe.completeNextStop(.init(
            state: .preparing,
            phase: "preparing",
            message: "shutdown accepted",
            retryAllowed: false,
            canStart: false,
            canTerminate: false
        ))
        for _ in 0..<40 {
            if await operationProbe.snapshot().statusCount == 2 { break }
            await Task.yield()
        }

        XCTAssertFalse(store.isStopping)
        XCTAssertTrue(store.isShuttingDown)
        XCTAssertFalse(ChekinanaGPUStatusPresentation.showsPreparationProgress(
            visibleState: .preparing,
            isStarting: false,
            isShuttingDown: store.isShuttingDown
        ))
        let scheduled = await schedulerProbe.snapshot()
        XCTAssertEqual(scheduled.delays, [40_000_000_000])

        await operationProbe.completeNextStatus(.init(
            state: .preparing,
            phase: "preparing",
            retryAllowed: false,
            canStart: false,
            canTerminate: false
        ))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(store.isShuttingDown)
        let afterConfirmation = await operationProbe.snapshot()
        XCTAssertEqual(afterConfirmation.statusCount, 2)

        let manualRefresh = Task { await store.refreshManually() }
        for _ in 0..<20 {
            if await operationProbe.snapshot().statusCount == 3 { break }
            await Task.yield()
        }
        await operationProbe.completeNextStatus(.init(
            state: .closed,
            phase: "closed",
            retryAllowed: true,
            canStart: true,
            canTerminate: false
        ))
        await manualRefresh.value

        XCTAssertFalse(store.isShuttingDown)
        XCTAssertEqual(store.status?.state, .closed)
    }

    func testInFlightLastScanConfirmationIsRestoredOnceWhenStopFails() async {
        let operationProbe = ScannerRuntimeStoreOperationProbe()
        let schedulerProbe = ScannerRuntimeSchedulerProbe()
        let scheduler = ChekinanaScannerRuntimeRefreshScheduler { delay in
            await schedulerProbe.recordDelay(delay)
        }
        let store = ChekinanaScannerRuntimePresentationStore(
            refreshScheduler: scheduler,
            statusRequest: { await operationProbe.statusRequest() },
            stopRequest: { await operationProbe.stopRequest() }
        )
        let refresh = Task { await store.refreshManually() }
        for _ in 0..<20 {
            if await operationProbe.snapshot().statusCount == 1 { break }
            await Task.yield()
        }
        await operationProbe.completeNextStatus(.init(
            state: .ready,
            phase: "ready",
            retryAllowed: false,
            canStart: false,
            canTerminate: true
        ))
        await refresh.value

        store.scheduleLastScanConfirmation()
        for _ in 0..<20 {
            if await operationProbe.snapshot().statusCount == 2 { break }
            await Task.yield()
        }
        store.requestStop()
        for _ in 0..<20 {
            if await operationProbe.snapshot().stopCount == 1 { break }
            await Task.yield()
        }
        await operationProbe.completeNextStop(.init(
            ok: false,
            state: .ready,
            phase: "ready",
            message: "scan still active",
            retryAllowed: true,
            canStart: false,
            canTerminate: false
        ))
        for _ in 0..<40 {
            if await operationProbe.snapshot().statusCount == 3 { break }
            await Task.yield()
        }

        let operationSnapshot = await operationProbe.snapshot()
        let schedulerSnapshot = await schedulerProbe.snapshot()
        XCTAssertEqual(operationSnapshot.statusCount, 3)
        XCTAssertEqual(
            schedulerSnapshot.delays.filter {
                $0 == ChekinanaScannerRuntimeRefreshScheduler
                    .lastScanConfirmationDelayNanoseconds
            }.count,
            2
        )
        XCTAssertFalse(schedulerSnapshot.delays.contains(
            ChekinanaScannerRuntimeRefreshScheduler.stopConfirmationDelayNanoseconds
        ))

        // Complete the canceled old GET first. Its stale generation must not
        // commit or clear the replacement confirmation.
        await operationProbe.completeNextStatus(.init(
            state: .closed,
            phase: "closed",
            retryAllowed: true,
            canStart: true,
            canTerminate: false
        ))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.status?.state, .ready)

        await operationProbe.completeNextStatus(.init(
            state: .ready,
            phase: "ready",
            retryAllowed: false,
            canStart: false,
            canTerminate: true
        ))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.status?.state, .ready)
    }

    func testLocalImportChekiProducesDeterministicMiniImageAndDateState() async throws {
        let source = ChekinanaPendingChekiImage(
            data: scannerPNGData(color: .white),
            filenameExtension: "png"
        )
        let first = try await ChekinanaLocalImportChekiProcessor.normalize(
            source.data,
            appliesWhiteBalance: true
        )
        let second = try await ChekinanaLocalImportChekiProcessor.normalize(
            source.data,
            appliesWhiteBalance: true
        )
        XCTAssertEqual(first.width, 1_200)
        XCTAssertEqual(first.height, 1_908)
        XCTAssertTrue(first.whiteBalanceApplied)
        XCTAssertEqual(first.data, second.data)

        let dateInputProbe = LocalImportDateInputProbe()
        let result = try await ChekinanaLocalImportChekiProcessor.process(
            source,
            options: scannerOptions(
                dateRecognitionEnabled: true,
                directInputEnabled: true
            ),
            dateAnnotate: { processedImage in
                await dateInputProbe.record(processedImage)
                return .detected(ChekinanaChekiDateAnnotation(
                    text: "2026.08.05",
                    precision: .fullDate,
                    boundingBox: ChekinanaChekiDateBoundingBox(
                        x1: 100,
                        y1: 700,
                        x2: 900,
                        y2: 900
                    )!
                )!)
            }
        )
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images[0].imagePixelWidth, 1_200)
        XCTAssertEqual(result.images[0].imagePixelHeight, 1_908)
        let recordedDateInput = await dateInputProbe.snapshot()
        let annotatedInput = try XCTUnwrap(recordedDateInput)
        XCTAssertEqual(annotatedInput.filenameExtension, "png")
        XCTAssertEqual(annotatedInput.data, result.images[0].data)
        guard case .detected(let annotation) = result.images[0].dateAnnotationState else {
            return XCTFail("expected detected annotation")
        }
        XCTAssertEqual(annotation.text, "2026.08.05")
    }

    func testImportedChekiSizePolicyIsIndependentOfOrientation() {
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 1_200, height: 1_908
        ), .mini)
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 1_908, height: 1_200
        ), .mini)
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 2_400, height: 1_908
        ), .wide)
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 1_908, height: 2_400
        ), .wide)
        XCTAssertNil(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 1_200, height: 1_200
        ))
    }

    func testLocalImportPreservesLandscapeAndPortraitWithoutStretching() async throws {
        let portrait = try await ChekinanaLocalImportChekiProcessor.normalize(
            scannerJPEGData(
                color: .purple,
                size: CGSize(width: 1_200, height: 1_908)
            ),
            appliesWhiteBalance: false
        )
        XCTAssertEqual(portrait.width, 1_200)
        XCTAssertEqual(portrait.height, 1_908)
        XCTAssertEqual(portrait.inferredSize, .mini)

        let landscape = try await ChekinanaLocalImportChekiProcessor.normalize(
            scannerJPEGData(
                color: .purple,
                size: CGSize(width: 1_908, height: 1_200)
            ),
            appliesWhiteBalance: false
        )
        XCTAssertEqual(landscape.width, 1_908)
        XCTAssertEqual(landscape.height, 1_200)
        XCTAssertEqual(landscape.inferredSize, .mini)

        let fitted = try XCTUnwrap(ChekinanaLocalImportRenderGeometry.fittedRect(
            sourceWidth: 1_600,
            sourceHeight: 900,
            outputWidth: 1_908,
            outputHeight: 1_200
        ))
        XCTAssertEqual(fitted.width / fitted.height, 1_600.0 / 900.0, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(fitted.width, 1_908)
        XCTAssertLessThanOrEqual(fitted.height, 1_200)
    }

    func testWideImportCanvasAndLedgerSizePreserveOrientation() async throws {
        let fixture = try makeFixture()
        let portrait = try await ChekinanaLocalImportChekiProcessor.normalize(
            scannerJPEGData(
                color: .purple,
                size: CGSize(width: 159, height: 200)
            ),
            appliesWhiteBalance: false
        )
        XCTAssertEqual(portrait.width, 1_908)
        XCTAssertEqual(portrait.height, 2_400)
        XCTAssertEqual(portrait.inferredSize, .wide)

        let landscape = try await ChekinanaLocalImportChekiProcessor.normalize(
            scannerJPEGData(
                color: .purple,
                size: CGSize(width: 200, height: 159)
            ),
            appliesWhiteBalance: false
        )
        XCTAssertEqual(landscape.width, 2_400)
        XCTAssertEqual(landscape.height, 1_908)
        XCTAssertEqual(landscape.inferredSize, .wide)

        let inserted = try fixture.ledger.insertTemporaryChekis(
            [ChekinanaPendingChekiImage(
                data: landscape.data,
                filenameExtension: "jpg"
            )],
            thumbnailImageData: [nil],
            sizes: [landscape.inferredSize]
        ).inserted
        XCTAssertEqual(inserted.first?.size, .wide)

        XCTAssertEqual(
            ChekinanaImportedChekiCanvasPolicy.dimensions(
                inferredSize: nil,
                isLandscape: true
            ).width,
            1_908
        )
    }

    func testExifAndInputQuarterTurnFeedUprightImportGeometry() async throws {
        let exifSix = scannerJPEGDataWithOrientation(
            6,
            size: CGSize(width: 40, height: 24)
        )
        let upright = try XCTUnwrap(ChekinanaImagePixelGeometry.uprightDimensions(
            in: exifSix
        ))
        XCTAssertGreaterThan(upright.height, upright.width)

        let original = ChekinanaPendingChekiImage(
            data: exifSix,
            filenameExtension: "jpg"
        )
        let rotated = try await ChekinanaProductMediaLoader
            .applyingCounterclockwiseRotation(to: original, quarterTurns: 1)
        let dimensions = try XCTUnwrap(ChekinanaImagePixelGeometry.uprightDimensions(
            in: rotated.data
        ))
        XCTAssertGreaterThan(dimensions.width, dimensions.height)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(
            rotated.data as CFData,
            nil
        ))
        XCTAssertEqual(
            ChekinanaImageSourceValidator.effectiveExifOrientation(source: source),
            1
        )
    }

    func testDirectDateAnnotationJSONSupportsDetectedNotDetectedAndUnavailable() {
        let detected = ChekinanaDirectDateAnnotationClient.decode(Data(
            #"{"status":"detected","text":"2026.08.05","precision":"full_date","bbox":[100,700,900,900]}"#.utf8
        ))
        guard case .detected(let annotation) = detected else {
            return XCTFail("expected detected annotation")
        }
        XCTAssertEqual(annotation.text, "2026.08.05")
        XCTAssertEqual(
            ChekinanaDirectDateAnnotationClient.decode(Data(
                #"{"annotation":{"status":"not_detected"}}"#.utf8
            )),
            .notDetected
        )
        XCTAssertEqual(
            ChekinanaDirectDateAnnotationClient.decode(Data(
                #"{"status":"unavailable","error":"model_unavailable"}"#.utf8
            )),
            .unavailable
        )
    }

    func testLocalImportChekiAppliesValidatedEXIFOrientationBeforeResize() async throws {
        let up = try await ChekinanaLocalImportChekiProcessor.normalize(
            scannerJPEGDataWithOrientation(1),
            appliesWhiteBalance: false
        )
        let rotated = try await ChekinanaLocalImportChekiProcessor.normalize(
            scannerJPEGDataWithOrientation(6),
            appliesWhiteBalance: false
        )

        XCTAssertEqual(up.width, 1_200)
        XCTAssertEqual(rotated.height, 1_908)
        XCTAssertNotEqual(
            up.data,
            rotated.data,
            "EXIF rotation must change the rendered pixel layout before fixed-size resize"
        )
    }

    func testLocalImportChekiAppliesEXIFThreeExactlyOnceAndWritesUprightPNG() async throws {
        let up = try await ChekinanaLocalImportChekiProcessor.normalize(
            scannerJPEGDataWithOrientation(1),
            appliesWhiteBalance: false
        )
        let exifThree = try await ChekinanaLocalImportChekiProcessor.normalize(
            scannerJPEGDataWithOrientation(3),
            appliesWhiteBalance: false
        )
        let upSamples = try quadrantColorLabels(up.data)
        let rotatedSamples = try quadrantColorLabels(exifThree.data)

        XCTAssertEqual(
            rotatedSamples,
            [upSamples[3], upSamples[2], upSamples[1], upSamples[0]],
            "EXIF 3 must rotate the asymmetric pixels once, not be ignored or applied twice"
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(
            exifThree.data as CFData,
            nil
        ))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let outputOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        XCTAssertTrue(
            outputOrientation == nil || outputOrientation == 1,
            "Normalized PNG must not carry orientation metadata that a review image can apply again"
        )
    }

    func testDirectDateAnnotationPostsRawPNGWithWorkerCompatibleTimeout() async throws {
        let png = scannerPNGData(color: .cyan)
        let probe = DirectDateAnnotationRequestProbe()
        ChekinanaRuntimeMockURLProtocol.handler = { request in
            await probe.response(for: request)
        }
        defer { ChekinanaRuntimeMockURLProtocol.handler = nil }
        let client = ChekinanaDirectDateAnnotationClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession()
        )

        let state = try await client.annotate(ChekinanaPendingChekiImage(
            data: png,
            filenameExtension: "png"
        ))

        XCTAssertEqual(state, .notDetected)
        let request = await probe.snapshot()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/cheki/date-annotation")
        XCTAssertEqual(request.contentType, "image/png")
        XCTAssertEqual(request.body, png)
        XCTAssertGreaterThanOrEqual(request.timeout, 60)
        XCTAssertFalse(request.hasClientToken)
    }

    func testScannerProcessMakesNoImplicitRuntimeControlRequest() async throws {
        let probe = ScannerManagedProxyProbe(resultImage: scannerPNGData(color: .white))
        ChekinanaRuntimeMockURLProtocol.handler = { request in
            await probe.response(for: request)
        }
        defer { ChekinanaRuntimeMockURLProtocol.handler = nil }
        let client = ChekinanaScannerClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession(),
            statusPollIntervalNanoseconds: 0,
            maximumStatusPollAttempts: 3
        )

        let result = try await client.process(
            ChekinanaPendingChekiImage(
                data: scannerPNGData(color: .white),
                filenameExtension: "png"
            ),
            options: scannerOptions(dateRecognitionEnabled: false)
        )

        XCTAssertEqual(result.images.count, 1)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.runtimeStatusCount, 0)
        XCTAssertEqual(snapshot.startCount, 0)
        XCTAssertEqual(snapshot.events.first, "process")
    }

    func testScannerRuntimeClientMapsTransportTimeoutAndProducesRetryableFailure() async {
        ChekinanaRuntimeMockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        defer { ChekinanaRuntimeMockURLProtocol.handler = nil }
        let client = ChekinanaScannerRuntimeClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession()
        )

        do {
            _ = try await client.status()
            XCTFail("runtime status should time out")
        } catch {
            XCTAssertEqual(error as? ChekinanaScannerRuntimeError, .timedOut)
            let status = ChekinanaScannerRuntimeStatus.clientUnavailable(
                message: error.localizedDescription
            )
            XCTAssertFalse(status.ok)
            XCTAssertEqual(status.state, .closed)
            XCTAssertEqual(status.phase, "closed")
            XCTAssertTrue(status.retryAllowed)
            XCTAssertFalse((status.message ?? "").isEmpty)
        }
    }

    func testScannerRuntimeStatusUsesWallClockDeadlineWhenSessionNeverCompletes() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaNeverCompletingURLProtocol.self]
        let client = ChekinanaScannerRuntimeClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: URLSession(configuration: configuration),
            statusWallClockTimeout: 0.12
        )
        let started = ContinuousClock.now

        do {
            _ = try await client.status()
            XCTFail("a status session that never calls back must reach the wall-clock deadline")
        } catch {
            XCTAssertEqual(error as? ChekinanaScannerRuntimeError, .timedOut)
            XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        }
    }

    func testScannerRuntimeStatusCancellationReturnsWithoutWaitingForURLSession() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaNeverCompletingURLProtocol.self]
        let client = ChekinanaScannerRuntimeClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: URLSession(configuration: configuration),
            statusWallClockTimeout: 5
        )
        let task = Task { () -> Bool in
            do {
                _ = try await client.status()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        let started = ContinuousClock.now
        task.cancel()

        let returnedCancellation = await task.value
        XCTAssertTrue(returnedCancellation)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testMediaRelationshipResolverRefetchesAcrossModelContextsBeforeInsert() throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let selectionContext = ModelContext(container)
        let idol = Idol(name: "Cross-context Idol")
        let event = Event(name: "Cross-context Event")
        selectionContext.insert(idol)
        selectionContext.insert(event)
        try selectionContext.save()

        // Only stable values cross the presentation boundary. The write context
        // must receive its own model instances before relationships are set.
        let idolIDs = Set([idol.id])
        let eventID = event.id
        let writeContext = ModelContext(container)
        let relationships = try ChekinanaModelContextResolver.relationships(
            idolIDs: idolIDs,
            eventID: eventID,
            in: writeContext
        )
        XCTAssertTrue(relationships.idols.allSatisfy { $0.modelContext === writeContext })
        XCTAssertTrue(relationships.event?.modelContext === writeContext)

        let shame = Shame()
        let douga = Douga()
        let cheki = Cheki()
        writeContext.insert(shame)
        writeContext.insert(douga)
        writeContext.insert(cheki)
        shame.idols = relationships.idols
        douga.idols = relationships.idols
        cheki.idols = relationships.idols
        cheki.event = relationships.event
        try writeContext.save()

        let verificationContext = ModelContext(container)
        let savedShame = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Shame>())
                .first(where: { $0.id == shame.id })
        )
        let savedDouga = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Douga>())
                .first(where: { $0.id == douga.id })
        )
        let savedCheki = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Cheki>())
                .first(where: { $0.id == cheki.id })
        )
        for ids in [
            Set(savedShame.idols.map(\.id)),
            Set(savedDouga.idols.map(\.id)),
            Set(savedCheki.idols.map(\.id)),
        ] {
            XCTAssertEqual(ids, idolIDs)
        }
        XCTAssertEqual(savedCheki.event?.id, eventID)
    }

    func testScannerRuntimeClientPreservesBusyStop409Status() async throws {
        ChekinanaRuntimeMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/scanner/runtime/stop")
            return .init(
                statusCode: 409,
                data: Data(
                    #"{"ok":false,"state":"ready","phase":"ready","message":"A scan task is still in progress. Try stopping again after it finishes.","retryAllowed":true,"canStart":false,"canTerminate":false,"updatedAt":"2026-08-05T00:00:00Z"}"#.utf8
                ),
                headers: ["Content-Type": "application/json"]
            )
        }
        defer { ChekinanaRuntimeMockURLProtocol.handler = nil }
        let client = ChekinanaScannerRuntimeClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession()
        )

        let status = try await client.stop()

        XCTAssertFalse(status.ok)
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.phase, "ready")
        XCTAssertTrue(status.retryAllowed)
        XCTAssertFalse(status.canTerminate)
        XCTAssertEqual(
            status.message,
            "A scan task is still in progress. Try stopping again after it finishes."
        )
    }

    func testScannerMultipartUsesOnlyBackendTwelveFields() async throws {
        let probe = ScannerManagedProxyProbe(resultImage: scannerPNGData(color: .orange))
        ChekinanaRuntimeMockURLProtocol.handler = { request in
            await probe.response(for: request)
        }
        defer { ChekinanaRuntimeMockURLProtocol.handler = nil }
        let client = ChekinanaScannerClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession(),
            statusPollIntervalNanoseconds: 0,
            maximumStatusPollAttempts: 3
        )

        let image = ChekinanaPendingChekiImage(
            data: scannerPNGData(color: .white),
            filenameExtension: "png"
        )
        let options = scannerOptions(
            dateRecognitionEnabled: false,
            directInputEnabled: true,
            sleevesEnabled: true,
            postprocessMode: .sharpen
        )
        let multipartData = client.multipartBody(
            for: image,
            options: options,
            boundary: "test-boundary"
        )
        for expected in [
            "name=\"sleeve\"\r\n\r\n1",
            "name=\"wb\"\r\n\r\n1",
            "name=\"denoise\"\r\n\r\n1",
            "name=\"sharpen\"\r\n\r\n1",
            "name=\"file\"; filename=\"source.png\"",
        ] {
            XCTAssertNotNil(multipartData.range(of: Data(expected.utf8)), expected)
        }
        for legacy in ["name=\"image\"", "name=\"direct\"", "postprocess_mode", "expected_polaroids", "rotation_degrees", "polaroid_size"] {
            XCTAssertNil(multipartData.range(of: Data(legacy.utf8)), legacy)
        }

        let result = try await client.process(image, options: options)

        XCTAssertEqual(result.images.count, 1)
        let snapshot = await probe.snapshot()
        XCTAssertFalse(snapshot.sawSensitiveTransport)
    }

    func testProductionScannerUsesWorkerWithoutRuntimeControlOrClientToken() async throws {
        let probe = ScannerManagedProxyProbe(resultImage: scannerPNGData(color: .purple))
        ChekinanaRuntimeMockURLProtocol.handler = { request in
            await probe.response(for: request)
        }
        defer { ChekinanaRuntimeMockURLProtocol.handler = nil }
        let client = ChekinanaScannerClient(
            baseURL: ChekinanaScannerConfiguration.productionBaseURL,
            session: runtimeMockSession(),
            statusPollIntervalNanoseconds: 0,
            maximumStatusPollAttempts: 3
        )

        let result = try await client.process(
            ChekinanaPendingChekiImage(
                data: scannerPNGData(color: .white),
                filenameExtension: "png"
            ),
            options: scannerOptions(dateRecognitionEnabled: false)
        )

        XCTAssertEqual(result.images.count, 1)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.startCount, 0)
        XCTAssertEqual(snapshot.runtimeStatusCount, 0)
        XCTAssertFalse(snapshot.sawSensitiveTransport)
        XCTAssertFalse(snapshot.sawDirectField)
        XCTAssertEqual(snapshot.events.first, "process")
    }

    func testSleeveMultipartDefaultsOffAndMapsPostprocessFlags() throws {
        let client = ChekinanaScannerClient(baseURL: try XCTUnwrap(URL(string: "https://scanner.test")))
        let image = ChekinanaPendingChekiImage(
            data: scannerPNGData(color: .white),
            filenameExtension: "png"
        )
        let cases: [(ChekinanaScannerPostprocessMode, String, String)] = [
            (.off, "0", "0"),
            (.denoise, "1", "0"),
            (.sharpen, "1", "1"),
        ]
        for (mode, denoise, sharpen) in cases {
            let body = client.multipartBody(
                for: image,
                options: scannerOptions(
                    dateRecognitionEnabled: false,
                    postprocessMode: mode
                ),
                boundary: "fields"
            )
            XCTAssertNotNil(body.range(of: Data("name=\"sleeve\"\r\n\r\n0".utf8)))
            XCTAssertNotNil(body.range(of: Data("name=\"denoise\"\r\n\r\n\(denoise)".utf8)))
            XCTAssertNotNil(body.range(of: Data("name=\"sharpen\"\r\n\r\n\(sharpen)".utf8)))
        }
    }

    func testLiveUploadNormalizesHEICToSupportedUprightJPEG() async throws {
        XCTAssertTrue(ChekinanaLiveScannerUploadPreparer.fileFitsBackendLimit(
            ChekinanaLiveScannerUploadPreparer.maximumUploadBytes
        ))
        XCTAssertFalse(ChekinanaLiveScannerUploadPreparer.fileFitsBackendLimit(
            ChekinanaLiveScannerUploadPreparer.maximumUploadBytes + 1
        ))
        guard let heic = scannerHEICDataWithOrientation(6) else {
            throw XCTSkip("HEIC encoder is unavailable on this test host")
        }
        let prepared = try await ChekinanaLiveScannerUploadPreparer.prepare(
            ChekinanaPendingChekiImage(data: heic, filenameExtension: "heic")
        )
        XCTAssertEqual(prepared.image.filenameExtension, "jpg")
        XCTAssertLessThanOrEqual(
            prepared.image.data.count,
            ChekinanaLiveScannerUploadPreparer.maximumUploadBytes
        )
        let uploadSource = try XCTUnwrap(CGImageSourceCreateWithData(
            prepared.image.data as CFData,
            nil
        ))
        XCTAssertEqual(CGImageSourceGetType(uploadSource) as String?, "public.jpeg")
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(uploadSource, 0, nil) as? [CFString: Any]
        )
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        XCTAssertTrue(orientation == nil || orientation == 1)
        XCTAssertGreaterThan(prepared.annotationPreviewPixelWidth, 0)
        XCTAssertGreaterThan(prepared.annotationPreviewPixelHeight, 0)
    }

    func testQuadrilateralValidationAndFixedChekiFramePolicy() throws {
        let preview = scannerPNGData(color: .white)
        let valid = ChekinanaScannerSourceAnnotation(
            previewImageData: preview,
            sourcePixelWidth: 100,
            sourcePixelHeight: 200,
            quadrilateral: [
                .init(x: 1, y: 2), .init(x: 99, y: 2),
                .init(x: 99, y: 198), .init(x: 1, y: 198),
            ]
        )
        XCTAssertTrue(valid.isValid)
        XCTAssertFalse(ChekinanaScannerSourceAnnotation(
            previewImageData: preview,
            sourcePixelWidth: 100,
            sourcePixelHeight: 200,
            quadrilateral: [
                .init(x: -1, y: 2), .init(x: 99, y: 2),
                .init(x: 99, y: 198), .init(x: 1, y: 198),
            ]
        ).isValid)
        XCTAssertEqual(
            ChekinanaChekiDisplayFramePolicy.aspectRatio,
            CGFloat(1_200) / CGFloat(1_908),
            accuracy: 0.000_001
        )
    }

    func testPreRenderedSourceAnnotationIsDisplayedWithoutSecondQuadrilateralStroke() {
        let clean = scannerPNGData(color: .white)
        let renderedAnnotation = scannerPNGData(color: .orange)
        let annotation = ChekinanaScannerSourceAnnotation(
            previewImageData: renderedAnnotation,
            sourcePixelWidth: 2,
            sourcePixelHeight: 2,
            quadrilateral: [
                .init(x: 0, y: 0), .init(x: 2, y: 0),
                .init(x: 2, y: 2), .init(x: 0, y: 2),
            ]
        )
        XCTAssertFalse(ChekinanaScanAnnotationDisplayPolicy.drawsQuadrilateralInView)
        XCTAssertEqual(
            ChekinanaScanAnnotationDisplayPolicy.displayedData(
                cleanImageData: clean,
                sourceAnnotation: annotation,
                showsSourceAnnotation: true
            ),
            renderedAnnotation
        )
        XCTAssertEqual(
            ChekinanaScanAnnotationDisplayPolicy.displayedData(
                cleanImageData: clean,
                sourceAnnotation: annotation,
                showsSourceAnnotation: false
            ),
            clean
        )
    }

    func testReviewInteractionPolicySerializesSaveRotateAndDownload() {
        XCTAssertTrue(ChekinanaScanReviewInteractionPolicy.allowsCardInteraction(
            isSaving: false,
            isRotating: false,
            isDownloading: false
        ))
        XCTAssertFalse(ChekinanaScanReviewInteractionPolicy.allowsCardInteraction(
            isSaving: true,
            isRotating: false,
            isDownloading: false
        ))
        XCTAssertFalse(ChekinanaScanReviewInteractionPolicy.allowsCardInteraction(
            isSaving: false,
            isRotating: true,
            isDownloading: false
        ))
        XCTAssertFalse(ChekinanaScanReviewInteractionPolicy.allowsCardInteraction(
            isSaving: false,
            isRotating: false,
            isDownloading: true
        ))
        XCTAssertTrue(ChekinanaScanReviewInteractionPolicy.allowsConfirmAll(
            isSaving: false,
            hasRotations: false,
            hasDownloads: false
        ))
        XCTAssertFalse(ChekinanaScanReviewInteractionPolicy.allowsConfirmAll(
            isSaving: false,
            hasRotations: false,
            hasDownloads: true
        ))
    }

    func testPreviewPublicationRejectsCancelledOrStaleThumbnailLoads() {
        XCTAssertTrue(ChekinanaScanPreviewLoadPublicationPolicy.canPublish(
            completedToken: "source-2",
            requestedToken: "source-2",
            isCancelled: false
        ))
        XCTAssertFalse(ChekinanaScanPreviewLoadPublicationPolicy.canPublish(
            completedToken: "clean-1",
            requestedToken: "source-2",
            isCancelled: false
        ))
        XCTAssertFalse(ChekinanaScanPreviewLoadPublicationPolicy.canPublish(
            completedToken: "source-2",
            requestedToken: "source-2",
            isCancelled: true
        ))
    }

    func testRotateChangesCleanImageOnlyAndKeepsSourceAnnotationEphemeral() async throws {
        let clean = ChekinanaPendingChekiImage(
            data: scannerJPEGDataWithOrientation(1),
            filenameExtension: "jpg"
        )
        let annotation = ChekinanaScannerSourceAnnotation(
            previewImageData: scannerPNGData(color: .orange),
            sourcePixelWidth: 64,
            sourcePixelHeight: 64,
            quadrilateral: [
                .init(x: 1, y: 1), .init(x: 63, y: 1),
                .init(x: 63, y: 63), .init(x: 1, y: 63),
            ]
        )
        let ledger = ChekinanaConfirmationLedger()
        let inserted = try ledger.insertTemporaryChekis(
            [clean],
            thumbnailImageData: [nil],
            sourceAnnotations: [annotation]
        )
        let id = try XCTUnwrap(inserted.inserted.first?.id)
        let rotated = try await ChekinanaScanCleanImageRotation.counterclockwise(clean)
        XCTAssertTrue(ledger.replaceTemporaryChekiImage(
            id: id,
            image: rotated,
            thumbnailImageData: nil,
            dateAnnotationState: .notRequested
        ))
        let value = try XCTUnwrap(ledger.temporaryCheki(id))
        XCTAssertEqual(value.image.data, rotated.data)
        XCTAssertNotEqual(value.image.data, clean.data)
        XCTAssertEqual(value.sourceAnnotation, annotation)
        XCTAssertNotEqual(value.image.data, value.sourceAnnotation?.previewImageData)
        XCTAssertEqual(value.imageRotationQuarterTurns, 1)
        XCTAssertEqual(
            try quadrantColorLabels(value.image.data),
            [1, 3, 0, 2],
            "One Review rotation must move pixels 90° counterclockwise."
        )
    }

    func testCounterclockwiseRotationTransformsDateBoundingBoxAndKeepsSourceAnnotation() throws {
        let box = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 100,
            y1: 200,
            x2: 400,
            y2: 600
        ))
        let annotation = try XCTUnwrap(ChekinanaChekiDateAnnotation(
            text: "2026.08.12",
            precision: .fullDate,
            boundingBox: box
        ))
        let state = ChekinanaScanCleanImageRotation.counterclockwiseDateAnnotation(
            .detected(annotation)
        )
        guard case .detected(let rotated) = state else {
            return XCTFail("Expected rotated date annotation")
        }
        XCTAssertEqual(rotated.boundingBox.x1, 200)
        XCTAssertEqual(rotated.boundingBox.y1, 600)
        XCTAssertEqual(rotated.boundingBox.x2, 600)
        XCTAssertEqual(rotated.boundingBox.y2, 900)
        var restoredState: ChekinanaChekiDateAnnotationState = .detected(annotation)
        for _ in 0..<4 {
            restoredState = ChekinanaScanCleanImageRotation
                .counterclockwiseDateAnnotation(restoredState)
        }
        XCTAssertEqual(restoredState, .detected(annotation))

        let source = ChekinanaScannerSourceAnnotation(
            previewImageData: scannerPNGData(color: .orange),
            sourcePixelWidth: 64,
            sourcePixelHeight: 64,
            quadrilateral: [
                .init(x: 1, y: 2), .init(x: 61, y: 2),
                .init(x: 61, y: 62), .init(x: 1, y: 62),
            ]
        )
        let ledger = ChekinanaConfirmationLedger()
        let clean = ChekinanaPendingChekiImage(
            data: scannerJPEGDataWithOrientation(1),
            filenameExtension: "jpg"
        )
        let id = try XCTUnwrap(ledger.insertTemporaryChekis(
            [clean],
            thumbnailImageData: [nil],
            sourceAnnotations: [source]
        ).inserted.first?.id)
        XCTAssertEqual(ledger.temporaryCheki(id)?.sourceAnnotation, source)
    }

    func testFourCounterclockwiseRotationsRestorePixelsAndStayIsolatedPerCard() async throws {
        let firstOriginal = ChekinanaPendingChekiImage(
            data: scannerJPEGDataWithOrientation(1),
            filenameExtension: "jpg"
        )
        let secondOriginal = ChekinanaPendingChekiImage(
            data: scannerJPEGData(color: .purple, size: CGSize(width: 24, height: 40)),
            filenameExtension: "jpg"
        )
        let ledger = ChekinanaConfirmationLedger()
        let inserted = try ledger.insertTemporaryChekis(
            [firstOriginal, secondOriginal],
            thumbnailImageData: [nil, nil]
        ).inserted
        XCTAssertEqual(inserted.count, 2)
        let firstID = inserted[0].id
        let secondID = inserted[1].id
        let originalPixels = try quadrantColorLabels(firstOriginal.data)

        var current = firstOriginal
        for expectedQuarterTurns in 1...4 {
            current = try await ChekinanaScanCleanImageRotation.counterclockwise(current)
            XCTAssertTrue(ledger.replaceTemporaryChekiImage(
                id: firstID,
                image: current,
                thumbnailImageData: nil,
                dateAnnotationState: .notRequested
            ))
            XCTAssertEqual(
                ledger.temporaryCheki(firstID)?.imageRotationQuarterTurns,
                expectedQuarterTurns % 4
            )
            XCTAssertEqual(ledger.temporaryCheki(secondID)?.image, secondOriginal)
            XCTAssertEqual(ledger.temporaryCheki(secondID)?.imageRotationQuarterTurns, 0)
        }
        XCTAssertEqual(try quadrantColorLabels(current.data), originalPixels)
    }

    func testCounterclockwiseReviewRotationFeedsIdenticalSaveAndDownloadSourceBytes() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let original = ChekinanaPendingChekiImage(
            data: scannerJPEGDataWithOrientation(1),
            filenameExtension: "jpg"
        )
        let temporaryID = try XCTUnwrap(fixture.ledger.insertTemporaryChekis(
            [original],
            thumbnailImageData: [nil]
        ).inserted.first?.id)
        let rotated = try await ChekinanaScanCleanImageRotation.counterclockwise(original)
        XCTAssertTrue(fixture.ledger.replaceTemporaryChekiImage(
            id: temporaryID,
            image: rotated,
            thumbnailImageData: nil,
            dateAnnotationState: .notRequested
        ))

        let downloadSource = try XCTUnwrap(
            fixture.ledger.temporaryCheki(temporaryID)?.image.data
        )
        let prepared = await fixture.executor.execute(
            "addscancheki \(temporaryID.uuidString.lowercased())"
        )
        guard case .pendingChekiCards(_, let cards, _) = prepared,
              let code = cards.first?.confirmationCode,
              let entry = fixture.ledger.entry(for: code),
              case .addCheki(let payload) = entry.action else {
            return XCTFail("Expected a pending Review save using the rotated image.")
        }
        XCTAssertEqual(payload.image.data, downloadSource)
        XCTAssertEqual(payload.image.data, rotated.data)

        guard case .chekiCards(let savedCards) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: [code]),
              let savedID = savedCards.first?.id else {
            return XCTFail("Expected the rotated Review image to save.")
        }
        let saved = try XCTUnwrap(fixture.context.fetch(
            FetchDescriptor<Cheki>(predicate: #Predicate { $0.id == savedID })
        ).first)
        let savedURL = try XCTUnwrap(ChekiImageRefResolver.managedChekiFileURL(
            for: saved.imageRef,
            chekiID: saved.id
        ))
        let savedData = try Data(contentsOf: savedURL)
        XCTAssertEqual(savedData, downloadSource)
        XCTAssertEqual(try quadrantColorLabels(savedData), [1, 3, 0, 2])
    }

    func testRotationFailureCancellationAndStalePublicationKeepOriginalCards() async throws {
        let original = ChekinanaPendingChekiImage(
            data: scannerJPEGDataWithOrientation(1),
            filenameExtension: "jpg"
        )
        let ledger = ChekinanaConfirmationLedger()
        let id = try XCTUnwrap(ledger.insertTemporaryChekis(
            [original],
            thumbnailImageData: [nil]
        ).inserted.first?.id)

        do {
            _ = try await ChekinanaScanCleanImageRotation.counterclockwise(
                ChekinanaPendingChekiImage(
                    data: Data("invalid".utf8),
                    filenameExtension: "jpg"
                )
            )
            XCTFail("Invalid image data must fail rotation")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertEqual(ledger.temporaryCheki(id)?.image, original)
        XCTAssertEqual(ledger.temporaryCheki(id)?.imageRotationQuarterTurns, 0)

        let cancelled = Task {
            try Task.checkCancellation()
            return try await ChekinanaScanCleanImageRotation.counterclockwise(original)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled rotation must not publish")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(ledger.temporaryCheki(id)?.image, original)
        XCTAssertEqual(ledger.temporaryCheki(id)?.imageRotationQuarterTurns, 0)

        XCTAssertTrue(ledger.discardTemporaryCheki(id: id))
        let rotated = try await ChekinanaScanCleanImageRotation.counterclockwise(original)
        XCTAssertFalse(ledger.replaceTemporaryChekiImage(
            id: id,
            image: rotated,
            thumbnailImageData: nil,
            dateAnnotationState: .notRequested
        ))
        XCTAssertNil(ledger.temporaryCheki(id))
    }

    func testChekiPreviewLoaderPriorityFallbackAndUnavailableOutcomes() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let rendered = ChekinanaRenderedImage(cgImage: try XCTUnwrap(image.cgImage))
        let embeddedData = try XCTUnwrap(image.pngData())

        func source(imageRef: String?, embeddedData: Data?) -> ChekinanaChekiPreviewSource {
            ChekinanaChekiPreviewSource(cheki: ChekinanaChekiCard(
                id: UUID(),
                imageRef: imageRef,
                createdAt: Date(),
                confirmationCode: nil,
                thumbnailImageData: embeddedData
            ))
        }

        var embeddedWasCalled = false
        let preferred = await ChekinanaChekiPreviewLoader(
            imageRefLoader: { _, maxDimension in
                XCTAssertEqual(maxDimension, 2_048)
                return rendered
            },
            embeddedLoader: { _, _ in
                embeddedWasCalled = true
                return rendered
            }
        ).load(source: source(imageRef: "saved.jpg", embeddedData: embeddedData))
        XCTAssertEqual(preferred.loadedSource, .imageRef)
        XCTAssertNotNil(preferred.image)
        XCTAssertFalse(embeddedWasCalled)

        var refWasCalled = false
        embeddedWasCalled = false
        let fallback = await ChekinanaChekiPreviewLoader(
            imageRefLoader: { _, _ in
                refWasCalled = true
                return nil
            },
            embeddedLoader: { data, maxDimension in
                embeddedWasCalled = true
                XCTAssertEqual(data, embeddedData)
                XCTAssertEqual(maxDimension, 2_048)
                return rendered
            }
        ).load(source: source(imageRef: "missing.jpg", embeddedData: embeddedData))
        XCTAssertTrue(refWasCalled)
        XCTAssertTrue(embeddedWasCalled)
        XCTAssertEqual(fallback.loadedSource, .embeddedThumbnail)
        XCTAssertNotNil(fallback.image)

        refWasCalled = false
        let embeddedOnly = await ChekinanaChekiPreviewLoader(
            imageRefLoader: { _, _ in
                refWasCalled = true
                return rendered
            },
            embeddedLoader: { _, _ in rendered }
        ).load(source: source(imageRef: nil, embeddedData: embeddedData))
        XCTAssertFalse(refWasCalled)
        XCTAssertEqual(embeddedOnly.loadedSource, .embeddedThumbnail)
        XCTAssertNotNil(embeddedOnly.image)

        refWasCalled = false
        embeddedWasCalled = false
        let unavailable = await ChekinanaChekiPreviewLoader(
            imageRefLoader: { _, _ in
                refWasCalled = true
                return rendered
            },
            embeddedLoader: { _, _ in
                embeddedWasCalled = true
                return rendered
            }
        ).load(source: source(imageRef: nil, embeddedData: nil))
        XCTAssertFalse(refWasCalled)
        XCTAssertFalse(embeddedWasCalled)
        XCTAssertNil(unavailable.loadedSource)
        XCTAssertNil(unavailable.image)
    }


    func testScanUsesScannerResultsForTemporaryChekisWithoutPersistence() async throws {
        var receivedSources: [Data] = []
        let pngResult = scannerPNGData(color: .red)
        let jpegResult = scannerJPEGData(color: .green)
        let secondPNGResult = scannerPNGData(color: .blue)
        let sourceImages = [testImage(1), testImage(2)]
        let scannerResults = [
            ChekinanaScannerProcessResult(images: [pngResult], warningCount: 1),
            ChekinanaScannerProcessResult(images: [jpegResult, secondPNGResult], warningCount: 2),
        ]
        let fixture = try makeFixture { image, _ in
            receivedSources.append(image.data)
            let sourceIndex = try XCTUnwrap(
                sourceImages.firstIndex(where: { $0.data == image.data })
            )
            return scannerResults[sourceIndex]
        }

        let response = await fixture.executor.execute(
            "scancheki",
            pendingChekiImages: sourceImages
        )

        guard case .chekiScannedCards(let count, let warningCount, let cards) = response else {
            return XCTFail("expected scanner result cards")
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(warningCount, 3)
        XCTAssertTrue(cards.allSatisfy { $0.size == .mini })
        XCTAssertEqual(Set(receivedSources), Set(sourceImages.map(\.data)))
        let temporaryImages = try cards.map {
            try fixture.ledger.resolveTemporaryCheki(shortID($0.id)).image
        }
        XCTAssertTrue(temporaryImages.allSatisfy { $0.filenameExtension == "jpg" })
        XCTAssertTrue(temporaryImages.allSatisfy { UIImage(data: $0.data) != nil })
        XCTAssertTrue(temporaryImages.allSatisfy { !sourceImages.map(\.data).contains($0.data) })
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    func testChekiIndexIdentityUsesUnorderedIdolSetAndDateNotEvent() throws {
        let firstIdol = UUID()
        let secondIdol = UUID()
        let chekiID = UUID()
        let date = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-07-04T00:00:00Z"
        ))
        let group = try XCTUnwrap(ChekinanaChekiGroupKey(
            idolIDs: [firstIdol, secondIdol],
            date: date
        ))
        let reordered = try XCTUnwrap(ChekinanaChekiGroupKey(
            idolIDs: [secondIdol, firstIdol],
            date: date
        ))
        XCTAssertEqual(group, reordered)
        XCTAssertEqual(try ChekinanaChekiIndexing.nextIndex(
            for: group,
            existing: [
                .init(chekiID: chekiID, group: reordered, idx: 4),
            ],
            excludingChekiID: nil
        ), 5)
        let nextDate = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-07-05T00:00:00Z"
        ))
        let otherGroup = try XCTUnwrap(ChekinanaChekiGroupKey(
            idolIDs: [firstIdol, secondIdol],
            date: nextDate
        ))
        XCTAssertEqual(try ChekinanaChekiIndexing.nextIndex(
            for: otherGroup,
            existing: [.init(chekiID: chekiID, group: group, idx: 4)],
            excludingChekiID: nil
        ), 1)
    }

    func testCalendarBatchWriterAddsOneHundredChekisWithExactGroupIndices() throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 10)
        let selectedIdol = Idol(name: "Calendar Batch")
        let otherIdol = Idol(name: "Other Group")
        fixture.context.insert(selectedIdol)
        fixture.context.insert(otherIdol)
        let existing = Cheki(date: date.addingTimeInterval(12 * 60 * 60), idx: 7)
        fixture.context.insert(existing)
        existing.idols = [selectedIdol]
        let otherGroup = Cheki(date: date, idx: 99)
        fixture.context.insert(otherGroup)
        otherGroup.idols = [otherIdol]
        try fixture.context.save()

        let insertedIDs = try ChekinanaCalendarRecordBatchWriter.commit(
            .init(
                kind: .cheki,
                idolIDs: [selectedIdol.id],
                date: date,
                quantity: 100,
                manualStart: nil,
                note: "batch",
                eventID: nil
            ),
            in: fixture.context
        )

        XCTAssertEqual(insertedIDs.count, 100)
        let insertedIDSet = Set(insertedIDs)
        let inserted = try fixture.context.fetch(FetchDescriptor<Cheki>())
            .filter { insertedIDSet.contains($0.id) }
            .sorted { ($0.idx ?? 0) < ($1.idx ?? 0) }
        XCTAssertEqual(inserted.compactMap(\.idx), Array(8...107))
        XCTAssertTrue(inserted.allSatisfy { $0.imageRef == nil })
        XCTAssertTrue(inserted.allSatisfy {
            Set($0.idols.map(\.id)) == [selectedIdol.id]
                && $0.idols.allSatisfy { $0.modelContext === fixture.context }
        })
    }

    func testCalendarBatchWriterReplansAutomaticIndicesAgainstLateLiveOwner() throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 10)
        let idol = Idol(name: "Late Automatic")
        fixture.context.insert(idol)
        try fixture.context.save()
        let group = try XCTUnwrap(ChekinanaChekiGroupKey(
            idolIDs: [idol.id],
            date: date
        ))
        let earlySnapshots = try ChekinanaChekiIndexing.snapshots(
            forCanonicalDate: date,
            in: fixture.context
        )
        XCTAssertEqual(try ChekinanaChekiIndexing.batchIndices(
            for: group,
            quantity: 2,
            manualStart: nil,
            existing: earlySnapshots
        ), [1, 2])

        let lateOwner = Cheki(date: date.addingTimeInterval(16 * 60 * 60), idx: 1)
        fixture.context.insert(lateOwner)
        lateOwner.idols = [idol]
        try fixture.context.save()
        let insertedIDs = try ChekinanaCalendarRecordBatchWriter.commit(
            .init(
                kind: .cheki,
                idolIDs: [idol.id],
                date: date,
                quantity: 2,
                manualStart: nil,
                note: "",
                eventID: nil
            ),
            in: fixture.context
        )
        let insertedIDSet = Set(insertedIDs)
        let insertedIndices = try fixture.context.fetch(FetchDescriptor<Cheki>())
            .filter { insertedIDSet.contains($0.id) }
            .compactMap(\.idx)
            .sorted()
        XCTAssertEqual(insertedIndices, [2, 3])
    }

    func testCalendarBatchWriterRejectsLateManualCollisionAndRollsBack() throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 10)
        let idol = Idol(name: "Late Manual")
        fixture.context.insert(idol)
        try fixture.context.save()
        let group = try XCTUnwrap(ChekinanaChekiGroupKey(
            idolIDs: [idol.id],
            date: date
        ))
        XCTAssertEqual(try ChekinanaChekiIndexing.batchIndices(
            for: group,
            quantity: 3,
            manualStart: 10,
            existing: []
        ), [10, 11, 12])

        let lateOwner = Cheki(date: date.addingTimeInterval(8 * 60 * 60), idx: 11)
        fixture.context.insert(lateOwner)
        lateOwner.idols = [idol]
        try fixture.context.save()
        XCTAssertThrowsError(try ChekinanaCalendarRecordBatchWriter.commit(
            .init(
                kind: .cheki,
                idolIDs: [idol.id],
                date: date,
                quantity: 3,
                manualStart: 10,
                note: "",
                eventID: nil
            ),
            in: fixture.context
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("already used"))
        }
        let remaining = try fixture.context.fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(remaining.map(\.id), [lateOwner.id])
        XCTAssertEqual(remaining.first?.idx, 11)
    }

    func testCalendarQuantityPolicySupportsOnlyChekiUpToOneHundred() {
        XCTAssertEqual(
            ChekinanaCalendarRecordQuantityPolicy.normalized(72, for: .shame),
            1
        )
        XCTAssertEqual(
            ChekinanaCalendarRecordQuantityPolicy.normalized(72, for: .douga),
            1
        )
        XCTAssertEqual(
            ChekinanaCalendarRecordQuantityPolicy.normalized(72, for: .cheki),
            72
        )
        XCTAssertTrue(ChekinanaCalendarRecordQuantityPolicy.accepts(100, for: .cheki))
        XCTAssertFalse(ChekinanaCalendarRecordQuantityPolicy.accepts(1, for: .shame))
        XCTAssertFalse(ChekinanaCalendarRecordQuantityPolicy.accepts(1, for: .douga))
        XCTAssertFalse(ChekinanaCalendarRecordQuantityPolicy.accepts(0, for: .shame))
        XCTAssertFalse(ChekinanaCalendarRecordQuantityPolicy.accepts(101, for: .douga))
    }

    func testCalendarRecordCreationErrorsUseStableLocalizedKeys() {
        XCTAssertEqual(
            ChekinanaProductRecordCreationError.allCases.map(\.localizationKey),
            [
                "error.record_context_mismatch",
                "error.index_overflow",
                "error.invalid_index",
                "error.index_collision",
                "error.record_quantity",
            ]
        )
        for error in ChekinanaProductRecordCreationError.allCases {
            XCTAssertEqual(
                error.localizedDescription,
                ChekinanaProductCopy.text(error.localizationKey, error.fallback)
            )
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testCalendarBatchWriterRejectsShameAndDougaBeforeWrite() throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 10)
        let idol = Idol(name: "Quantity Guard")
        fixture.context.insert(idol)
        try fixture.context.save()
        for kind in [ChekinanaRecordKind.shame, .douga] {
            XCTAssertThrowsError(try ChekinanaCalendarRecordBatchWriter.commit(
                .init(
                    kind: kind,
                    idolIDs: [idol.id],
                    date: date,
                    quantity: 2,
                    manualStart: nil,
                    note: "",
                    eventID: nil
                ),
                in: fixture.context
            )) { error in
                XCTAssertEqual(
                    error as? ChekinanaMediaBackedCreationError,
                    ChekinanaMediaBackedCreationError(kind: kind)
                )
            }
        }
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Shame>()), 0)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Douga>()), 0)
    }

    func testCalendarWriterRejectsSingleNoMediaShameAndDouga() throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 10)
        let idol = Idol(name: "Single No Media")
        fixture.context.insert(idol)
        try fixture.context.save()
        for kind in [ChekinanaRecordKind.shame, .douga] {
            XCTAssertThrowsError(try ChekinanaCalendarRecordBatchWriter.commit(
                .init(
                    kind: kind,
                    idolIDs: [idol.id],
                    date: date,
                    quantity: 1,
                    manualStart: nil,
                    note: "legacy",
                    eventID: nil
                ),
                in: fixture.context
            ))
        }
        let verificationContext = ModelContext(fixture.context.container)
        XCTAssertEqual(try verificationContext.fetchCount(FetchDescriptor<Shame>()), 0)
        XCTAssertEqual(try verificationContext.fetchCount(FetchDescriptor<Douga>()), 0)
    }

    func testTemporaryEditConfirmUsesDateIdentityAndPersistsCleanImageOnly() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let firstIdol = Idol(name: "First")
        let secondIdol = Idol(name: "Second")
        let firstEvent = Event(name: "First Event")
        let secondEvent = Event(name: "Second Event")
        [firstIdol, secondIdol].forEach(fixture.context.insert)
        [firstEvent, secondEvent].forEach(fixture.context.insert)
        try fixture.context.save()
        let firstDate = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-07-04T00:00:00Z"
        ))
        let secondDate = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-07-05T00:00:00Z"
        ))

        func insert(
            idols: [Idol],
            date: Date?,
            event: Event?
        ) throws -> ChekinanaConfirmationLedger.TemporaryCheki {
            let cleanImage = scannerPNGData(color: .cyan)
            let temporary = try fixture.ledger.insertTemporaryChekis(
                [ChekinanaPendingChekiImage(data: cleanImage, filenameExtension: "png")],
                thumbnailImageData: [cleanImage]
            ).inserted[0]
            XCTAssertEqual(temporary.size, .mini)
            XCTAssertTrue(fixture.ledger.updateTemporaryCheki(
                id: temporary.id,
                idolIDs: idols.map(\.id),
                date: date,
                eventID: event?.id,
                userAppears: nil,
                size: .mini,
                isFavorite: true,
                hasPostedToSNS: true,
                note: "edited"
            ))
            return try fixture.ledger.resolveTemporaryCheki(shortID(temporary.id))
        }

        let first = try insert(
            idols: [firstIdol, secondIdol],
            date: firstDate,
            event: firstEvent
        )
        let firstCleanBytes = first.image.data
        let prepared = await fixture.executor.execute(
            "addscancheki \(shortID(first.id))"
        )
        guard case .pendingChekiCards(_, let pendingCards, _) = prepared else {
            return XCTFail("expected pending card")
        }
        XCTAssertEqual(pendingCards[0].idolNames.count, 2)
        XCTAssertEqual(pendingCards[0].eventName, firstEvent.name)
        XCTAssertNil(pendingCards[0].idx)
        XCTAssertEqual(pendingCards[0].size, .mini)
        try requireSuccess(await fixture.executor.execute("confirm"))
        let firstSaved = try XCTUnwrap(
            try fixture.context.fetch(FetchDescriptor<Cheki>()).first
        )
        XCTAssertEqual(firstSaved.idx, 1)
        XCTAssertEqual(Set(firstSaved.idols.map(\.id)), Set([firstIdol.id, secondIdol.id]))
        XCTAssertEqual(firstSaved.event?.id, firstEvent.id)
        XCTAssertEqual(firstSaved.date, firstDate)
        XCTAssertNil(firstSaved.userAppears)
        XCTAssertEqual(firstSaved.size, .mini)
        XCTAssertTrue(firstSaved.isFavorite)
        XCTAssertTrue(firstSaved.hasPostedToSNS)
        XCTAssertEqual(firstSaved.note, "edited")
        let firstURL = try XCTUnwrap(
            ChekiImageRefResolver.managedLocalFileURL(for: firstSaved.imageRef)
        )
        XCTAssertEqual(try Data(contentsOf: firstURL), firstCleanBytes)

        let second = try insert(
            idols: [secondIdol, firstIdol],
            date: firstDate,
            event: secondEvent
        )
        _ = await fixture.executor.execute("addscancheki \(shortID(second.id))")
        try requireSuccess(await fixture.executor.execute("confirm"))
        let savedAfterSecond = try fixture.context.fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(savedAfterSecond.first(where: { $0.idols.count == 2 && $0.event?.id == secondEvent.id })?.idx, 2)

        let otherDate = try insert(
            idols: [firstIdol, secondIdol],
            date: secondDate,
            event: firstEvent
        )
        _ = await fixture.executor.execute("addscancheki \(shortID(otherDate.id))")
        try requireSuccess(await fixture.executor.execute("confirm"))
        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<Cheki>())
                .first(where: { $0.date == secondDate })?.idx,
            1
        )

        let eventOnly = try insert(idols: [firstIdol], date: nil, event: firstEvent)
        let eventOnlyResponse = await fixture.executor.execute(
            "addscancheki \(shortID(eventOnly.id)) event=\(shortID(secondEvent.id))"
        )
        guard case .pendingChekiCards(_, let eventOnlyCards, _) = eventOnlyResponse,
              let eventOnlyCode = eventOnlyCards.first?.confirmationCode else {
            return XCTFail("missing-date Cheki should remain confirmable")
        }
        try requireSuccess(await fixture.executor.execute("confirm \(eventOnlyCode)"))
        let savedEventOnly = try XCTUnwrap(
            try fixture.context.fetch(FetchDescriptor<Cheki>())
                .first(where: { $0.event?.id == secondEvent.id && $0.date == nil })
        )
        XCTAssertNil(savedEventOnly.idx)
        XCTAssertFalse(fixture.ledger.containsTemporaryCheki(eventOnly.id))

        let deleted = try insert(idols: [], date: firstDate, event: nil)
        let countBeforeDelete = try fixture.context.fetchCount(FetchDescriptor<Cheki>())
        fixture.ledger.discardTemporaryCheki(id: deleted.id)
        XCTAssertFalse(fixture.ledger.containsTemporaryCheki(deleted.id))
        XCTAssertEqual(
            try fixture.context.fetchCount(FetchDescriptor<Cheki>()),
            countBeforeDelete
        )
    }

    func testTemporaryChekiInsertionHasNoImageCountLimit() throws {
        let fixture = try makeFixture()
        let smallImage = scannerPNGData(color: .white)
        let images = (0..<21).map { _ in
            ChekinanaPendingChekiImage(
                data: smallImage,
                filenameExtension: "png"
            )
        }

        let insertion = try fixture.ledger.insertTemporaryChekis(
            images,
            thumbnailImageData: Array(repeating: nil, count: images.count)
        )

        XCTAssertEqual(insertion.inserted.count, 21)
        XCTAssertEqual(insertion.evictedCount, 0)
        XCTAssertTrue(insertion.inserted.allSatisfy {
            fixture.ledger.containsTemporaryCheki($0.id)
        })
        XCTAssertTrue(insertion.inserted.allSatisfy { $0.size == .mini })
    }

    func testTemporaryQuickEditsPreserveUnrelatedFieldsAndHiddenUserAppears() throws {
        let fixture = try makeFixture()
        let firstIdolID = UUID()
        let secondIdolID = UUID()
        let eventID = UUID()
        let firstDate = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-02T00:00:00Z"
        ))
        let secondDate = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-03T00:00:00Z"
        ))
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [ChekinanaPendingChekiImage(
                data: scannerPNGData(color: .purple),
                filenameExtension: "png"
            )],
            thumbnailImageData: [nil],
            dates: [firstDate],
            eventIDs: [eventID],
            eventAutoMatched: [true]
        ).inserted[0]
        XCTAssertEqual(temporary.size, .mini)
        XCTAssertTrue(temporary.eventWasAutoMatched)
        XCTAssertTrue(fixture.ledger.updateTemporaryCheki(
            id: temporary.id,
            idolIDs: [firstIdolID],
            date: firstDate,
            eventID: eventID,
            userAppears: true,
            size: .wide,
            isFavorite: false,
            hasPostedToSNS: true,
            note: "preserve me"
        ))

        XCTAssertTrue(fixture.ledger.replaceTemporaryChekiIdols(
            id: temporary.id,
            idolIDs: [firstIdolID, secondIdolID]
        ))
        var result = try fixture.ledger.resolveTemporaryCheki(shortID(temporary.id))
        XCTAssertEqual(Set(result.idolIDs), Set([firstIdolID, secondIdolID]))
        XCTAssertEqual(result.date, firstDate)
        XCTAssertEqual(result.eventID, eventID)
        XCTAssertFalse(result.eventWasAutoMatched)
        XCTAssertEqual(result.userAppears, true)
        XCTAssertEqual(result.size, .wide)
        XCTAssertFalse(result.isFavorite)
        XCTAssertTrue(result.hasPostedToSNS)
        XCTAssertEqual(result.note, "preserve me")

        XCTAssertTrue(fixture.ledger.replaceTemporaryChekiIdols(
            id: temporary.id,
            idolIDs: []
        ))
        result = try fixture.ledger.resolveTemporaryCheki(shortID(temporary.id))
        XCTAssertTrue(result.idolIDs.isEmpty)
        XCTAssertEqual(result.userAppears, true)
        XCTAssertEqual(result.eventID, eventID)

        XCTAssertTrue(fixture.ledger.updateTemporaryChekiDate(
            id: temporary.id,
            date: secondDate
        ))
        result = try fixture.ledger.resolveTemporaryCheki(shortID(temporary.id))
        XCTAssertEqual(result.date, secondDate)
        XCTAssertEqual(result.eventID, eventID)
        XCTAssertEqual(result.userAppears, true)
        XCTAssertEqual(result.size, .wide)

        XCTAssertEqual(fixture.ledger.toggleTemporaryChekiFavorite(id: temporary.id), true)
        result = try fixture.ledger.resolveTemporaryCheki(shortID(temporary.id))
        XCTAssertTrue(result.isFavorite)
        XCTAssertEqual(result.date, secondDate)
        XCTAssertEqual(result.eventID, eventID)
        XCTAssertEqual(result.userAppears, true)
        XCTAssertTrue(result.hasPostedToSNS)
        XCTAssertEqual(result.note, "preserve me")
    }

    func testTemporaryChekiByteCapacityRejectionIsAtomic() throws {
        let fixture = try makeFixture()
        let existing = try fixture.ledger.insertTemporaryChekis(
            [ChekinanaPendingChekiImage(data: Data([0x01]), filenameExtension: "jpg")],
            thumbnailImageData: [nil]
        ).inserted[0]
        let oversized = ChekinanaPendingChekiImage(
            data: Data(count: 100 * 1_024 * 1_024 + 1),
            filenameExtension: "jpg"
        )

        XCTAssertThrowsError(try fixture.ledger.insertTemporaryChekis(
            [oversized],
            thumbnailImageData: [nil]
        ))
        XCTAssertTrue(fixture.ledger.containsTemporaryCheki(existing.id))
        XCTAssertEqual(
            fixture.ledger.availableTemporaryChekiChoices().map(\.id),
            [existing.id]
        )
    }

    func testConfirmationValidatorRejectsUnprefixedFailuresAndWrongOperations() {
        let expectedID = UUID()
        let unprefixedFailure = ChekinanaCommandResponse.text(
            "确认失败，这项操作仍然保留在待确认列表中。database unavailable"
        )
        XCTAssertFalse(ChekinanaConfirmationResponseValidator.isAddScanChekiSuccess(
            unprefixedFailure,
            expectedChekiID: expectedID
        ))
        XCTAssertFalse(ChekinanaConfirmationResponseValidator.isDeleteChekiSuccess(
            unprefixedFailure
        ))

        let savedCard = ChekinanaChekiCard(
            id: expectedID,
            imageRef: "\(expectedID.uuidString).jpg",
            createdAt: Date(),
            confirmationCode: nil,
            thumbnailImageData: nil
        )
        XCTAssertTrue(ChekinanaConfirmationResponseValidator.isAddScanChekiSuccess(
            .chekiCards([savedCard]),
            expectedChekiID: expectedID
        ))
        XCTAssertFalse(ChekinanaConfirmationResponseValidator.isAddScanChekiSuccess(
            .chekiCards([savedCard]),
            expectedChekiID: UUID()
        ))
        XCTAssertTrue(ChekinanaConfirmationResponseValidator.isDeleteChekiSuccess(
            .text(ChekinanaConfirmationResponseValidator.chekiDeletionSuccessText)
        ))
        XCTAssertFalse(ChekinanaConfirmationResponseValidator.isDeleteChekiSuccess(
            .text("cancelled confirmation")
        ))

        let preparedDeletion = ChekinanaCommandResponse.pendingChekiCards(
            "prepared",
            [ChekinanaChekiCard(
                id: expectedID,
                imageRef: "\(expectedID.uuidString).jpg",
                createdAt: Date(),
                confirmationCode: "deadbeef",
                thumbnailImageData: nil
            )],
            consumesSelectedPhotos: false
        )
        XCTAssertEqual(
            ChekinanaConfirmationResponseValidator.deleteChekiConfirmationCode(
                from: preparedDeletion,
                expectedChekiID: expectedID
            ),
            "deadbeef"
        )
        XCTAssertNil(ChekinanaConfirmationResponseValidator.deleteChekiConfirmationCode(
            from: .confirmationText("prepared", confirmationCode: "deadbeef"),
            expectedChekiID: expectedID
        ))
    }

    func testGalleryDeleteDismissPolicyProtectsRecoveryRequiredLedgerEntry() throws {
        XCTAssertTrue(ChekinanaGalleryDeleteDismissPolicy.canDismiss(
            pendingConfirmationCode: "deadbeef",
            recoveryRequired: false
        ))
        XCTAssertFalse(ChekinanaGalleryDeleteDismissPolicy.canDismiss(
            pendingConfirmationCode: "deadbeef",
            recoveryRequired: true
        ))
        XCTAssertTrue(ChekinanaGalleryDeleteDismissPolicy.canDismiss(
            pendingConfirmationCode: nil,
            recoveryRequired: true
        ))

        let ledger = ChekinanaConfirmationLedger()
        let ordinaryCode = ledger.insert(.deleteCheki(.init(
            chekiID: UUID(),
            phase: .deleteModel
        )))
        XCTAssertFalse(ledger.cancellationRequiresRecovery(ordinaryCode))
        XCTAssertTrue(ChekinanaGalleryDeleteDismissPolicy.canDismiss(
            pendingConfirmationCode: ordinaryCode,
            recoveryRequired: ledger.cancellationRequiresRecovery(ordinaryCode)
        ))
        XCTAssertTrue(ledger.cancel(ordinaryCode))

        let recoveryCode = ledger.insert(.deleteCheki(.init(
            chekiID: UUID(),
            phase: .restoreThenDelete(
                originalURL: URL(fileURLWithPath: "/tmp/original.jpg"),
                quarantineURL: URL(fileURLWithPath: "/tmp/quarantine.jpg")
            )
        )))
        XCTAssertTrue(ledger.cancellationRequiresRecovery(recoveryCode))
        XCTAssertFalse(ChekinanaGalleryDeleteDismissPolicy.canDismiss(
            pendingConfirmationCode: recoveryCode,
            recoveryRequired: ledger.cancellationRequiresRecovery(recoveryCode)
        ))
        XCTAssertFalse(ledger.cancel(recoveryCode))
        XCTAssertNotNil(ledger.entry(for: recoveryCode), "recovery-required entry must remain live")

        let recoveryEntry = try XCTUnwrap(ledger.entry(for: recoveryCode))
        ledger.removeAfterSuccess(recoveryEntry)
        XCTAssertNil(ledger.entry(for: recoveryCode))
        XCTAssertTrue(ChekinanaGalleryDeleteDismissPolicy.canDismiss(
            pendingConfirmationCode: nil,
            recoveryRequired: ledger.cancellationRequiresRecovery(recoveryCode)
        ))
    }

    func testScanConfirmationRecoveryAfterPartialSuccessKeepsRemainingTemporaryChekiEditable() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let imageData = scannerPNGData(color: .purple)
        let date = utcDate(2026, 8, 2)
        let inserted = try fixture.ledger.insertTemporaryChekis(
            (0..<2).map { _ in
                ChekinanaPendingChekiImage(data: imageData, filenameExtension: "png")
            },
            thumbnailImageData: [nil, nil],
            dates: [date, date]
        ).inserted

        let prepared = await fixture.executor.execute("addscancheki all")
        guard case .pendingChekiCards(_, let pendingCards, _) = prepared else {
            return XCTFail("expected scanner confirmations")
        }
        XCTAssertEqual(pendingCards.count, 2)
        let codes = try pendingCards.map { try XCTUnwrap($0.confirmationCode) }

        let firstResult = await fixture.executor.execute("confirm \(codes[0])")
        XCTAssertTrue(ChekinanaConfirmationResponseValidator.isAddScanChekiSuccess(
            firstResult,
            expectedChekiID: pendingCards[0].id
        ))
        let simulatedUnprefixedFailure = ChekinanaCommandResponse.text(
            "确认失败，这项操作仍然保留在待确认列表中。retry later"
        )
        XCTAssertFalse(ChekinanaConfirmationResponseValidator.isAddScanChekiSuccess(
            simulatedUnprefixedFailure,
            expectedChekiID: pendingCards[1].id
        ))

        XCTAssertEqual(fixture.ledger.cancelTemporaryChekiConfirmations(codes), 1)
        let remaining = inserted.filter { fixture.ledger.containsTemporaryCheki($0.id) }
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(
            Set(fixture.ledger.availableTemporaryChekiChoices().map(\.id)),
            Set(remaining.map(\.id))
        )
        XCTAssertTrue(fixture.ledger.updateTemporaryCheki(
            id: try XCTUnwrap(remaining.first?.id),
            idolIDs: [],
            date: date,
            eventID: nil,
            userAppears: true,
            size: .mini,
            isFavorite: false,
            hasPostedToSNS: false,
            note: "retryable"
        ))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Cheki>()), 1)
    }

    func testIdolAvatarSaveFailureRemovesNewFileAndPreservesOldReference() throws {
        let fixture = try makeFixture()
        let directory = try makeTemporaryAvatarDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let idol = Idol(name: "Before")
        let oldRef = ChekinanaIdolReferenceStore.managedFilename(idolID: idol.id)
        idol.avatarImageRef = oldRef
        fixture.context.insert(idol)
        try fixture.context.save()
        let oldURL = directory.appendingPathComponent(oldRef)
        try Data([0x01]).write(to: oldURL)
        let stagedRef = ChekinanaIdolReferenceStore.managedFilename(idolID: idol.id)
        let stagedURL = directory.appendingPathComponent(stagedRef)
        try Data([0x02]).write(to: stagedURL)
        let staged = ChekinanaIdolReferenceStore.StoredAvatar(ref: stagedRef, url: stagedURL)

        XCTAssertThrowsError(try ChekinanaIdolPersistence.save(
            idol,
            inserting: false,
            previousAvatarRef: oldRef,
            stagedAvatar: staged,
            in: fixture.context,
            avatarDirectory: directory,
            saveContext: { _ in throw NSError(domain: "test", code: 1) }
        ) { target in
            target.name = "After"
            target.avatarImageRef = stagedRef
        })

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        let idolID = idol.id
        let persisted = try XCTUnwrap(fixture.context.fetch(
            FetchDescriptor<Idol>(predicate: #Predicate { $0.id == idolID })
        ).first)
        XCTAssertEqual(persisted.name, "Before")
        XCTAssertEqual(persisted.avatarImageRef, oldRef)
    }

    func testIdolAvatarSaveAndRollbackCleanupFailureReturnsRetryableTarget() throws {
        let fixture = try makeFixture()
        let directory = try makeTemporaryAvatarDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let idol = Idol(name: "Before")
        let oldRef = ChekinanaIdolReferenceStore.managedFilename(idolID: idol.id)
        idol.avatarImageRef = oldRef
        fixture.context.insert(idol)
        try fixture.context.save()
        let oldURL = directory.appendingPathComponent(oldRef)
        try Data([0x01]).write(to: oldURL)
        let stagedRef = ChekinanaIdolReferenceStore.managedFilename(idolID: idol.id)
        let stagedURL = directory.appendingPathComponent(stagedRef)
        try Data([0x02]).write(to: stagedURL)
        let staged = ChekinanaIdolReferenceStore.StoredAvatar(ref: stagedRef, url: stagedURL)
        var pendingCleanup: ChekinanaIdolAvatarCleanupTarget?

        do {
            _ = try ChekinanaIdolPersistence.save(
                idol,
                inserting: false,
                previousAvatarRef: oldRef,
                stagedAvatar: staged,
                in: fixture.context,
                avatarDirectory: directory,
                saveContext: { _ in throw NSError(domain: "save", code: 1) },
                removeStagedAvatar: { _ in throw NSError(domain: "cleanup", code: 2) }
            ) { target in
                target.name = "After"
                target.avatarImageRef = stagedRef
            }
            XCTFail("expected structured save and cleanup failure")
        } catch let error as ChekinanaIdolPersistenceError {
            pendingCleanup = error.pendingCleanupTarget
            XCTAssertTrue(error.localizedDescription.contains("database was not saved"))
            XCTAssertTrue(error.localizedDescription.contains("staged avatar still needs cleanup"))
        }

        let cleanup = try XCTUnwrap(pendingCleanup)
        XCTAssertEqual(cleanup.imageRef, stagedRef)
        XCTAssertEqual(cleanup.idolID, idol.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        let idolID = idol.id
        let persisted = try XCTUnwrap(fixture.context.fetch(
            FetchDescriptor<Idol>(predicate: #Predicate { $0.id == idolID })
        ).first)
        XCTAssertEqual(persisted.name, "Before")
        XCTAssertEqual(persisted.avatarImageRef, oldRef)

        XCTAssertTrue(try ChekinanaIdolReferenceStore.removeManagedAvatar(
            cleanup.imageRef,
            idolID: cleanup.idolID,
            directory: cleanup.directory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
    }

    func testIdolAvatarReplacementAndDeletionCleanupAreCommittedAfterDatabaseSave() throws {
        let fixture = try makeFixture()
        let directory = try makeTemporaryAvatarDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let idol = Idol(name: "Avatar Idol")
        let oldRef = ChekinanaIdolReferenceStore.managedFilename(idolID: idol.id)
        idol.avatarImageRef = oldRef
        fixture.context.insert(idol)
        try fixture.context.save()
        let oldURL = directory.appendingPathComponent(oldRef)
        try Data([0x01]).write(to: oldURL)
        let stagedRef = ChekinanaIdolReferenceStore.managedFilename(idolID: idol.id)
        let stagedURL = directory.appendingPathComponent(stagedRef)
        try Data([0x02]).write(to: stagedURL)

        let replacement = try ChekinanaIdolPersistence.save(
            idol,
            inserting: false,
            previousAvatarRef: oldRef,
            stagedAvatar: .init(ref: stagedRef, url: stagedURL),
            in: fixture.context,
            avatarDirectory: directory
        ) { target in
            target.avatarImageRef = stagedRef
        }
        XCTAssertNil(replacement.pendingAvatarCleanup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(idol.avatarImageRef, stagedRef)

        let deletion = try ChekinanaIdolPersistence.delete(
            idol,
            from: fixture.context,
            avatarDirectory: directory
        )
        XCTAssertNil(deletion.pendingAvatarCleanup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Idol>()), 0)
    }

    func testIdolAvatarCleanupNeverDeletesRemoteOrNonIdolFiles() throws {
        let directory = try makeTemporaryAvatarDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let idolID = UUID()
        let chekiFilename = "\(UUID().uuidString).jpg"
        let chekiURL = directory.appendingPathComponent(chekiFilename)
        try Data([0x01]).write(to: chekiURL)
        let otherIdolID = UUID()
        let otherIdolRef = ChekinanaIdolReferenceStore.managedFilename(idolID: otherIdolID)
        let otherIdolURL = directory.appendingPathComponent(otherIdolRef)
        try Data([0x02]).write(to: otherIdolURL)

        XCTAssertFalse(try ChekinanaIdolReferenceStore.removeManagedAvatar(
            "https://example.com/avatar.jpg",
            idolID: idolID,
            directory: directory
        ))
        XCTAssertFalse(try ChekinanaIdolReferenceStore.removeManagedAvatar(
            chekiFilename,
            idolID: idolID,
            directory: directory
        ))
        XCTAssertFalse(try ChekinanaIdolReferenceStore.removeManagedAvatar(
            otherIdolRef,
            idolID: idolID,
            directory: directory
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chekiURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherIdolURL.path))
    }

    func testIdolDeleteDatabaseFailurePreservesManagedAvatar() throws {
        let fixture = try makeFixture()
        let directory = try makeTemporaryAvatarDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let idol = Idol(name: "Keep")
        let avatarRef = ChekinanaIdolReferenceStore.managedFilename(idolID: idol.id)
        idol.avatarImageRef = avatarRef
        fixture.context.insert(idol)
        try fixture.context.save()
        let avatarURL = directory.appendingPathComponent(avatarRef)
        try Data([0x01]).write(to: avatarURL)

        XCTAssertThrowsError(try ChekinanaIdolPersistence.delete(
            idol,
            from: fixture.context,
            avatarDirectory: directory,
            saveContext: { _ in throw NSError(domain: "test", code: 2) }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: avatarURL.path))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Idol>()), 1)
    }

    func testAddScanChekiAllAllowsMissingDateAndPersistsEachCheki() async throws {
        let fixture = try makeFixture()
        let firstDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-04T00:00:00Z")
        )
        let images = [
            ChekinanaPendingChekiImage(
                data: scannerPNGData(color: .red),
                filenameExtension: "png"
            ),
            ChekinanaPendingChekiImage(
                data: scannerPNGData(color: .blue),
                filenameExtension: "png"
            ),
        ]
        let inserted = try fixture.ledger.insertTemporaryChekis(
            images,
            thumbnailImageData: [nil, nil],
            dates: [firstDate, nil]
        ).inserted
        let response = await fixture.executor.execute("addscancheki all")
        guard case .pendingChekiCards(_, let cards, _) = response else {
            return XCTFail("both temporary Cheki should be prepared")
        }
        XCTAssertEqual(cards.count, 2)
        for code in cards.compactMap(\.confirmationCode) {
            try requireSuccess(await fixture.executor.execute("confirm \(code)"))
        }
        let saved = try fixture.context.fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.filter { $0.date == nil && $0.idx == nil }.count, 1)
        XCTAssertEqual(saved.filter { $0.date != nil && $0.idx == nil }.count, 1)
        XCTAssertTrue(inserted.allSatisfy { !fixture.ledger.containsTemporaryCheki($0.id) })
    }

    func testMonthDayScanInfersDateAndMatchesEventUsingTheInferredYear() async throws {
        let boundingBox = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 100,
            y1: 650,
            x2: 900,
            y2: 900
        ))
        let annotation = try XCTUnwrap(ChekinanaChekiDateAnnotation(
            text: "07.04",
            precision: .monthDay,
            boundingBox: boundingBox
        ))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixture = try makeFixture(
            scannerProcess: { _, options in
                XCTAssertTrue(options.dateRecognitionEnabled)
                return ChekinanaScannerProcessResult(
                    images: [
                        ChekinanaScannerResultImage(
                            data: self.scannerPNGData(color: .purple),
                            dateAnnotationState: .detected(annotation)
                        ),
                    ],
                    warningCount: 0
                )
            },
            now: { self.utcDate(2026, 7, 5) },
            calendar: utc
        )
        let matchingEvent = Event(name: "Current", date: utcDate(2026, 7, 4))
        let sameMonthDayOtherYear = Event(name: "Old", date: utcDate(2025, 7, 4))
        fixture.context.insert(matchingEvent)
        fixture.context.insert(sameMonthDayOtherYear)
        try fixture.context.save()

        let scan = await fixture.executor.execute(
            "scancheki date_recognition=true",
            pendingChekiImages: [testImage(1)]
        )
        guard case .chekiScannedCards(_, _, let cards) = scan,
              let card = cards.first else {
            return XCTFail("expected a temporary scan result")
        }
        XCTAssertEqual(card.dateAnnotationState, .detected(annotation))
        XCTAssertEqual(card.eventDateText, "2026-07-04")
        let temporary = try fixture.ledger.resolveTemporaryCheki(shortID(card.id))
        XCTAssertEqual(temporary.dateAnnotationState, .detected(annotation))
        XCTAssertEqual(temporary.date, utcDate(2026, 7, 4))
        XCTAssertEqual(temporary.eventID, matchingEvent.id)
        XCTAssertTrue(
            temporary.eventWasAutoMatched,
            "The review hint must retain the actual complete-date match even when another year shares MM.DD."
        )

        guard case .pendingChekiCards = await fixture.executor.execute(
            "addscancheki \(shortID(card.id))"
        ) else {
            return XCTFail("the inferred complete date should prepare confirmation")
        }
    }

    func testMonthDayScanInShanghaiKeepsTheRecognizedDateOnlyValue() async throws {
        let boundingBox = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 100,
            y1: 650,
            x2: 900,
            y2: 900
        ))
        let annotation = try XCTUnwrap(ChekinanaChekiDateAnnotation(
            text: "07.05",
            precision: .monthDay,
            boundingBox: boundingBox
        ))
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let localReference = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-04T16:30:00Z")
        )
        let fixture = try makeFixture(
            scannerProcess: { _, options in
                XCTAssertEqual(options.dateBounds?.to, self.utcDate(2026, 7, 5))
                return ChekinanaScannerProcessResult(
                    images: [
                        ChekinanaScannerResultImage(
                            data: self.scannerPNGData(color: .purple),
                            dateAnnotationState: .detected(annotation)
                        ),
                    ],
                    warningCount: 0
                )
            },
            now: { localReference },
            calendar: shanghai
        )
        let matchingEvent = Event(name: "Shanghai day", date: utcDate(2026, 7, 5))
        let previousDay = Event(name: "Previous day", date: utcDate(2026, 7, 4))
        fixture.context.insert(matchingEvent)
        fixture.context.insert(previousDay)
        try fixture.context.save()

        let scan = await fixture.executor.execute(
            "scancheki date_recognition=true",
            pendingChekiImages: [testImage(1)]
        )
        guard case .chekiScannedCards(_, _, let cards) = scan,
              let card = cards.first else {
            return XCTFail("expected a temporary scan result")
        }
        XCTAssertEqual(card.eventDateText, "2026-07-05")
        let temporary = try fixture.ledger.resolveTemporaryCheki(shortID(card.id))
        XCTAssertEqual(temporary.date, utcDate(2026, 7, 5))
        XCTAssertEqual(temporary.eventID, matchingEvent.id)
        XCTAssertTrue(temporary.eventWasAutoMatched)
    }

    func testMonthDayScanAtLosAngelesEndBoundKeepsTheSameDateOnlyYear() async throws {
        let boundingBox = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 100,
            y1: 650,
            x2: 900,
            y2: 900
        ))
        let annotation = try XCTUnwrap(ChekinanaChekiDateAnnotation(
            text: "08.04",
            precision: .monthDay,
            boundingBox: boundingBox
        ))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let localReference = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-04T12:00:00Z")
        )
        let fixture = try makeFixture(
            scannerProcess: { _, options in
                XCTAssertEqual(options.dateBounds?.to, self.utcDate(2026, 8, 4))
                return ChekinanaScannerProcessResult(
                    images: [
                        ChekinanaScannerResultImage(
                            data: self.scannerPNGData(color: .purple),
                            dateAnnotationState: .detected(annotation)
                        ),
                    ],
                    warningCount: 0
                )
            },
            now: { localReference },
            calendar: losAngeles
        )
        let matchingEvent = Event(name: "LA end day", date: utcDate(2026, 8, 4))
        fixture.context.insert(matchingEvent)
        try fixture.context.save()

        let scan = await fixture.executor.execute(
            "scancheki date_recognition=true",
            pendingChekiImages: [testImage(1)]
        )
        guard case .chekiScannedCards(_, _, let cards) = scan,
              let card = cards.first else {
            return XCTFail("expected a temporary scan result")
        }
        XCTAssertEqual(card.eventDateText, "2026-08-04")
        let temporary = try fixture.ledger.resolveTemporaryCheki(shortID(card.id))
        XCTAssertEqual(temporary.date, utcDate(2026, 8, 4))
        XCTAssertEqual(temporary.eventID, matchingEvent.id)
        XCTAssertTrue(temporary.eventWasAutoMatched)
    }

    func testOutOfRangeDetectedDateBecomesUnrecognizedBeforeTemporaryInsertion() async throws {
        let boundingBox = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 100,
            y1: 650,
            x2: 900,
            y2: 900
        ))
        let annotation = try XCTUnwrap(ChekinanaChekiDateAnnotation(
            text: "2025.07.04",
            precision: .fullDate,
            boundingBox: boundingBox
        ))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixture = try makeFixture(
            scannerProcess: { _, options in
                XCTAssertEqual(options.dateBounds?.scope, .range)
                return ChekinanaScannerProcessResult(
                    images: [
                        ChekinanaScannerResultImage(
                            data: self.scannerPNGData(color: .purple),
                            dateAnnotationState: .detected(annotation)
                        ),
                    ],
                    warningCount: 0
                )
            },
            calendar: utc
        )

        let scan = await fixture.executor.execute(
            "scancheki date_recognition=true date_scope=range date_from=2026-07-01 date_to=2026-07-31",
            pendingChekiImages: [testImage(1)]
        )
        guard case .chekiScannedCards(_, _, let cards) = scan,
              let card = cards.first else {
            return XCTFail("expected a temporary scan result")
        }
        XCTAssertEqual(card.dateAnnotationState, .notDetected)
        XCTAssertNil(card.eventDateText)
        let temporary = try fixture.ledger.resolveTemporaryCheki(shortID(card.id))
        XCTAssertEqual(temporary.dateAnnotationState, .notDetected)
        XCTAssertNil(temporary.date)
    }

    func testFixedDateCommandKeepsItsYMDInANegativeTimeZone() async throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let fixture = try makeFixture(
            scannerProcess: { _, options in
                XCTAssertEqual(options.dateBounds?.scope, .fixed)
                XCTAssertFalse(options.requestsDateAnnotation)
                return ChekinanaScannerProcessResult(
                    images: [
                        ChekinanaScannerResultImage(
                            data: self.scannerPNGData(color: .purple),
                            dateAnnotationState: .notDetected
                        ),
                    ],
                    warningCount: 0
                )
            },
            calendar: losAngeles
        )

        let scan = await fixture.executor.execute(
            "scancheki date_recognition=true date_scope=fixed date_from=2026-08-04 date_to=2026-08-04",
            pendingChekiImages: [testImage(1)]
        )
        guard case .chekiScannedCards(_, _, let cards) = scan,
              let card = cards.first else {
            return XCTFail("expected a temporary scan result")
        }
        XCTAssertEqual(card.dateAnnotationState, .notRequested)
        XCTAssertEqual(card.eventDateText, "2026-08-04")
        let temporary = try fixture.ledger.resolveTemporaryCheki(shortID(card.id))
        XCTAssertEqual(temporary.dateAnnotationState, .notRequested)
        XCTAssertEqual(temporary.date, utcDate(2026, 8, 4))
    }

    func testProtectedTemporaryChekiDeleteReturnsFalseUntilConfirmationCancelled() throws {
        let fixture = try makeFixture()
        let date = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-04T00:00:00Z")
        )
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [testImage(1)],
            thumbnailImageData: [nil],
            dates: [date]
        ).inserted[0]
        let payload = ChekinanaConfirmationLedger.AddChekiPayload(
            id: UUID(),
            temporaryChekiID: temporary.id,
            image: temporary.image,
            thumbnailImageData: temporary.thumbnailImageData,
            idolIDs: [],
            eventID: nil,
            date: date,
            userAppears: nil,
            size: nil,
            isFavorite: false,
            hasPostedToSNS: false,
            note: "",
            createdAt: Date(),
            requestedIdx: nil,
            existingChekiID: nil,
            explicitlyEditedFields: []
        )
        let code = fixture.ledger.insert(.addCheki(payload))

        XCTAssertFalse(fixture.ledger.discardTemporaryCheki(id: temporary.id))
        XCTAssertTrue(fixture.ledger.containsTemporaryCheki(temporary.id))
        XCTAssertTrue(fixture.ledger.cancel(code))
        XCTAssertTrue(fixture.ledger.discardTemporaryCheki(id: temporary.id))
        XCTAssertFalse(fixture.ledger.containsTemporaryCheki(temporary.id))
    }


    func testScanSourceFailureKeepsEarlierPartialResultsWithoutFallingBackToSource() async throws {
        let validResult = scannerPNGData(color: .red)
        let sourceImages = [testImage(1), testImage(2)]
        let fixture = try makeFixture { image, _ in
            if image.data == sourceImages[0].data {
                return ChekinanaScannerProcessResult(
                    images: [validResult],
                    warningCount: 0
                )
            }
            throw ScannerMockError.failed
        }

        let response = await fixture.executor.execute(
            "scancheki",
            pendingChekiImages: sourceImages
        )

        guard case .chekiScannedCards(let count, let warningCount, let cards) = response else {
            return XCTFail("expected the successful source result to be retained")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(warningCount, 1)
        XCTAssertEqual(cards.count, 1)
        let temporary = try fixture.ledger.resolveTemporaryCheki(shortID(cards[0].id))
        XCTAssertFalse(sourceImages.map(\.data).contains(temporary.image.data))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    func testHumanBodyPoseCountMappingAndInvalidImageFallback() {
        XCTAssertFalse(ChekinanaUserAppearsInference.value(observationCount: 0))
        XCTAssertFalse(ChekinanaUserAppearsInference.value(observationCount: 1))
        XCTAssertTrue(ChekinanaUserAppearsInference.value(observationCount: 2))
        XCTAssertTrue(ChekinanaUserAppearsInference.value(observationCount: 4))
        XCTAssertEqual(
            ChekinanaUserAppearsInference.preserving(existing: true, detected: nil),
            true
        )
        XCTAssertNil(ChekinanaUserAppearsInference.preserving(
            existing: nil,
            detected: nil
        ))
        XCTAssertThrowsError(try ChekinanaHumanBodyPoseDetector.observationCount(
            in: Data([0x01, 0x02, 0x03])
        ))
    }

    func testBodyPosePreparationKeepsStandardChekiAndBoundsOversizedDecode() throws {
        let standard = try ChekinanaHumanBodyPoseDetector.prepareImage(
            in: scannerJPEGData(
                color: .purple,
                size: CGSize(width: 1_200, height: 1_908)
            )
        )
        XCTAssertEqual(standard.cgImage.width, 1_200)
        XCTAssertEqual(standard.cgImage.height, 1_908)
        XCTAssertEqual(standard.orientation, .up)

        let oversized = try ChekinanaHumanBodyPoseDetector.prepareImage(
            in: scannerJPEGData(
                color: .orange,
                size: CGSize(width: 3_000, height: 1_200)
            )
        )
        XCTAssertLessThanOrEqual(
            max(oversized.cgImage.width, oversized.cgImage.height),
            ChekinanaHumanBodyPoseDetector.maximumDecodedDimension + 1
        )
        let oriented = try ChekinanaHumanBodyPoseDetector.prepareImage(
            in: scannerJPEGDataWithOrientation(6)
        )
        XCTAssertEqual(oriented.orientation, .right)
        XCTAssertThrowsError(try ChekinanaHumanBodyPoseDetector.prepareImage(
            in: oversizedTIFFFixture(width: 50_000, height: 50_000)
        ))
    }

    func testBodyPoseLimiterCapsConcurrencyAtFour() async throws {
        let limiter = ChekinanaBodyPoseLimiter()
        let probe = ChekinanaBatchPreparationConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await limiter.perform {
                        await probe.begin()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await probe.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await probe.peak()
        let finalState = await limiter.snapshot()
        XCTAssertEqual(peak, ChekinanaBodyPoseLimiter.defaultLimit)
        XCTAssertEqual(finalState, .init(activeCount: 0, waitingCount: 0))
    }

    func testBodyPoseLimiterCancellationRemovesWaiterAndReturnsPermit() async throws {
        let limiter = ChekinanaBodyPoseLimiter(limit: 1)
        let holderStarted = expectation(description: "Body Pose permit acquired")
        let holderRelease = ScannerReleaseGate()
        let holder = Task {
            try await limiter.perform {
                holderStarted.fulfill()
                await holderRelease.wait()
            }
        }
        await fulfillment(of: [holderStarted], timeout: 1)
        let operation = LimiterOperationProbe()
        let cancelled = Task { () -> Bool in
            do {
                try await limiter.perform {
                    await operation.recordExecution()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let waiterQueued = await waitForBodyPoseLimiter(
            limiter,
            active: 1,
            waiting: 1
        )
        XCTAssertTrue(waiterQueued)
        cancelled.cancel()
        let cancellationObserved = await cancelled.value
        let executionCount = await operation.count()
        let stateAfterCancellation = await limiter.snapshot()
        XCTAssertTrue(cancellationObserved)
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(stateAfterCancellation, .init(activeCount: 1, waitingCount: 0))
        await holderRelease.release()
        _ = try await holder.value
        let finalState = await limiter.snapshot()
        XCTAssertEqual(finalState, .init(activeCount: 0, waitingCount: 0))
    }

    func testScanInfersUserAppearsOnceThenTogglePersistsThroughBatchSave() async throws {
        let detectionCount = ChekinanaAtomicCounter()
        let resultImage = scannerPNGData(color: .magenta)
        let fixture = try makeFixture(
            scannerProcess: { _, _ in
                ChekinanaScannerProcessResult(images: [resultImage], warningCount: 0)
            },
            userAppearsDetect: { data in
                XCTAssertEqual(data, resultImage)
                detectionCount.increment()
                return true
            }
        )
        defer { cleanupManagedImages(in: fixture.context) }

        let response = await fixture.executor.execute(
            "scancheki",
            pendingChekiImages: [testImage(1)]
        )
        guard case .chekiScannedCards(1, 0, let cards) = response,
              let card = cards.first else {
            return XCTFail("expected one inferred Review card")
        }
        XCTAssertEqual(card.userAppears, true)
        XCTAssertEqual(detectionCount.value(), 1)
        let temporary = try fixture.ledger.resolveTemporaryCheki(shortID(card.id))
        XCTAssertEqual(temporary.inferredUserAppears, true)
        XCTAssertEqual(temporary.userAppears, true)
        XCTAssertEqual(
            fixture.ledger.toggleTemporaryChekiUserAppears(id: temporary.id),
            false
        )
        XCTAssertTrue(try fixture.ledger.resolveTemporaryCheki(
            shortID(card.id)
        ).explicitlyEditedFields.contains(.userAppears))

        let prepared = await fixture.executor.execute(
            "addscancheki \(card.id.uuidString.lowercased())"
        )
        guard case .pendingChekiCards(_, let pendingCards, _) = prepared,
              let code = pendingCards.first?.confirmationCode else {
            return XCTFail("expected one pending save")
        }
        guard case .chekiCards(let savedCards) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: [code]) else {
            return XCTFail("expected the batch save to complete")
        }
        let savedID = try XCTUnwrap(savedCards.first?.id)
        let saved = try XCTUnwrap(fixture.context.fetch(
            FetchDescriptor<Cheki>(predicate: #Predicate { $0.id == savedID })
        ).first)
        XCTAssertEqual(saved.userAppears, false)
        XCTAssertFalse(fixture.ledger.containsTemporaryCheki(temporary.id))
    }

    func testScanBodyPoseFailureKeepsReviewResultWithNilValueAndWarning() async throws {
        let resultImage = scannerPNGData(color: .yellow)
        let fixture = try makeFixture(
            scannerProcess: { _, _ in
                ChekinanaScannerProcessResult(images: [resultImage], warningCount: 0)
            },
            userAppearsDetect: { _ in throw ScannerMockError.failed }
        )

        let response = await fixture.executor.execute(
            "scancheki",
            pendingChekiImages: [testImage(1)]
        )
        guard case .chekiScannedCards(1, 1, let cards) = response,
              let card = cards.first else {
            return XCTFail("Vision failure must remain a nonfatal Review warning")
        }
        XCTAssertNil(card.userAppears)
        let temporary = try fixture.ledger.resolveTemporaryCheki(shortID(card.id))
        XCTAssertNil(temporary.inferredUserAppears)
        XCTAssertNil(temporary.userAppears)
    }

    func testInferredUserAppearsPersistsThroughSingleConfirmation() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [ChekinanaPendingChekiImage(
                data: scannerPNGData(color: .cyan),
                filenameExtension: "png"
            )],
            thumbnailImageData: [nil],
            scannerMetadata: [.init(matchedIdolID: nil, userAppears: true)]
        ).inserted[0]
        let prepared = await fixture.executor.execute(
            "addscancheki \(temporary.id.uuidString.lowercased())"
        )
        guard case .pendingChekiCards(_, let cards, _) = prepared,
              let card = cards.first,
              let code = card.confirmationCode else {
            return XCTFail("expected one single-save confirmation")
        }
        let result = await fixture.executor.execute("confirm \(code)")
        guard ChekinanaConfirmationResponseValidator.isAddScanChekiSuccess(
            result,
            expectedChekiID: card.id
        ) else {
            return XCTFail("expected the single save to complete")
        }
        let savedID = card.id
        let saved = try XCTUnwrap(fixture.context.fetch(
            FetchDescriptor<Cheki>(predicate: #Predicate { $0.id == savedID })
        ).first)
        XCTAssertEqual(saved.userAppears, true)
        XCTAssertFalse(fixture.ledger.containsTemporaryCheki(temporary.id))
    }

    func testSingleConfirmAttachAdoptsDetectionWhenExistingValueIsNil() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let target = Cheki(date: utcDate(2026, 8, 11), userAppears: nil)
        fixture.context.insert(target)
        try fixture.context.save()
        let prepared = try await prepareSingleAttachConfirmation(
            in: fixture,
            target: target,
            imageData: scannerPNGData(color: .purple),
            detectedUserAppears: true
        )

        let response = await fixture.executor.execute("confirm \(prepared.code)")
        XCTAssertTrue(ChekinanaConfirmationResponseValidator.isAddScanChekiSuccess(
            response,
            expectedChekiID: target.id
        ))
        XCTAssertEqual(target.userAppears, true)
        XCTAssertFalse(ChekinanaNoMediaPolicy.hasNoImage(target.imageRef))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Cheki>()), 1)
        XCTAssertFalse(fixture.ledger.containsTemporaryCheki(prepared.temporaryID))
    }

    func testSingleConfirmAttachPreservesExistingNonNilAutomaticValue() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let target = Cheki(date: utcDate(2026, 8, 12), userAppears: true)
        fixture.context.insert(target)
        try fixture.context.save()
        let prepared = try await prepareSingleAttachConfirmation(
            in: fixture,
            target: target,
            imageData: scannerPNGData(color: .green),
            detectedUserAppears: false,
            inheritsExistingUserAppears: false
        )

        let response = await fixture.executor.execute("confirm \(prepared.code)")
        XCTAssertTrue(ChekinanaConfirmationResponseValidator.isAddScanChekiSuccess(
            response,
            expectedChekiID: target.id
        ))
        XCTAssertEqual(target.userAppears, true)
    }

    func testSingleConfirmAttachExplicitToggleOverridesExistingValue() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let target = Cheki(date: utcDate(2026, 8, 13), userAppears: true)
        fixture.context.insert(target)
        try fixture.context.save()
        let prepared = try await prepareSingleAttachConfirmation(
            in: fixture,
            target: target,
            imageData: scannerPNGData(color: .blue),
            detectedUserAppears: true,
            togglesUserAppears: true
        )

        let response = await fixture.executor.execute("confirm \(prepared.code)")
        XCTAssertTrue(ChekinanaConfirmationResponseValidator.isAddScanChekiSuccess(
            response,
            expectedChekiID: target.id
        ))
        XCTAssertEqual(target.userAppears, false)
    }

    func testSingleConfirmAttachRejectsLateMediaWithoutWritingAFile() async throws {
        let fixture = try makeFixture()
        let target = Cheki(date: utcDate(2026, 8, 14), imageRef: nil)
        fixture.context.insert(target)
        try fixture.context.save()
        let prepared = try await prepareSingleAttachConfirmation(
            in: fixture,
            target: target,
            imageData: scannerPNGData(color: .red),
            detectedUserAppears: false
        )
        let filesBefore = try managedChekiFilenames()
        target.imageRef = "late-external.jpg"
        target.updatedAt = Date()
        try fixture.context.save()

        guard case .text(let message) = await fixture.executor.execute(
            "confirm \(prepared.code)"
        ) else { return XCTFail("expected a retained confirmation failure") }
        XCTAssertTrue(message.hasPrefix("error:"))
        XCTAssertEqual(target.imageRef, "late-external.jpg")
        XCTAssertEqual(try managedChekiFilenames(), filesBefore)
        XCTAssertNotNil(fixture.ledger.entry(for: prepared.code))
        XCTAssertTrue(fixture.ledger.containsTemporaryCheki(prepared.temporaryID))
        XCTAssertFalse(fixture.ledger.isTemporaryExistingChekiTargetReserved(target.id))
    }

    func testSingleConfirmAttachInvalidImageLeavesTargetAndLedgerRecoverable() async throws {
        let fixture = try makeFixture()
        let target = Cheki(date: utcDate(2026, 8, 15), imageRef: nil)
        fixture.context.insert(target)
        try fixture.context.save()
        let prepared = try await prepareSingleAttachConfirmation(
            in: fixture,
            target: target,
            imageData: Data([0x00, 0x01, 0x02]),
            detectedUserAppears: false
        )
        let filesBefore = try managedChekiFilenames()

        guard case .text(let message) = await fixture.executor.execute(
            "confirm \(prepared.code)"
        ) else { return XCTFail("expected image validation failure") }
        XCTAssertTrue(message.hasPrefix("error:"))
        XCTAssertTrue(ChekinanaNoMediaPolicy.hasNoImage(target.imageRef))
        XCTAssertEqual(try managedChekiFilenames(), filesBefore)
        XCTAssertNotNil(fixture.ledger.entry(for: prepared.code))
        XCTAssertTrue(fixture.ledger.containsTemporaryCheki(prepared.temporaryID))
        XCTAssertFalse(fixture.ledger.isTemporaryExistingChekiTargetReserved(target.id))
    }

    func testTemporaryExistingSelectionUsesEffectiveUserAppearsUntilExplicitToggle() throws {
        let fixture = try makeFixture()
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [testImage(1)],
            thumbnailImageData: [nil],
            scannerMetadata: [.init(matchedIdolID: nil, userAppears: true)]
        ).inserted[0]

        XCTAssertTrue(fixture.ledger.setTemporaryExistingCheki(
            id: temporary.id,
            existingChekiID: UUID(),
            selectionIsManual: false,
            inheritedIdx: nil,
            inheritedUserAppears: false
        ))
        XCTAssertEqual(fixture.ledger.temporaryCheki(temporary.id)?.userAppears, false)
        XCTAssertTrue(fixture.ledger.setTemporaryExistingCheki(
            id: temporary.id,
            existingChekiID: nil,
            selectionIsManual: false,
            inheritedIdx: nil,
            inheritedUserAppears: nil
        ))
        XCTAssertEqual(fixture.ledger.temporaryCheki(temporary.id)?.userAppears, true)
        XCTAssertEqual(
            fixture.ledger.toggleTemporaryChekiUserAppears(id: temporary.id),
            false
        )
        XCTAssertTrue(fixture.ledger.setTemporaryExistingCheki(
            id: temporary.id,
            existingChekiID: UUID(),
            selectionIsManual: true,
            inheritedIdx: nil,
            inheritedUserAppears: true
        ))
        XCTAssertEqual(fixture.ledger.temporaryCheki(temporary.id)?.userAppears, false)
    }

    func testBatchAttachUserAppearsPreservesExistingUnlessNilOrExplicitlyEdited() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let preserved = Cheki(date: utcDate(2026, 8, 1), userAppears: true)
        let inferred = Cheki(date: utcDate(2026, 8, 2), userAppears: nil)
        let overridden = Cheki(date: utcDate(2026, 8, 3), userAppears: true)
        fixture.context.insert(preserved)
        fixture.context.insert(inferred)
        fixture.context.insert(overridden)
        try fixture.context.save()
        let codes = try [
            attachConfirmation(
                in: fixture,
                target: preserved,
                date: try XCTUnwrap(preserved.date),
                imageData: scannerPNGData(color: .red),
                payloadUserAppears: false
            ),
            attachConfirmation(
                in: fixture,
                target: inferred,
                date: try XCTUnwrap(inferred.date),
                imageData: scannerPNGData(color: .green),
                payloadUserAppears: true
            ),
            attachConfirmation(
                in: fixture,
                target: overridden,
                date: try XCTUnwrap(overridden.date),
                imageData: scannerPNGData(color: .blue),
                payloadUserAppears: false,
                explicitlyEditedFields: [.userAppears]
            ),
        ]

        guard case .chekiCards(let cards) = await fixture.executor
            .confirmTemporaryChekiBatch(confirmationCodes: codes) else {
            return XCTFail("expected mixed attach batch to save")
        }
        XCTAssertEqual(cards.map(\.id), [preserved.id, inferred.id, overridden.id])
        let saved = try fixture.context.fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(saved.first { $0.id == preserved.id }?.userAppears, true)
        XCTAssertEqual(saved.first { $0.id == inferred.id }?.userAppears, true)
        XCTAssertEqual(saved.first { $0.id == overridden.id }?.userAppears, false)
        XCTAssertTrue(saved.allSatisfy { !ChekinanaNoMediaPolicy.hasNoImage($0.imageRef) })
    }

    func testScanSubmitsAllSourcesBeforeLocalResultPreparation() async throws {
        let bothSourcesStarted = expectation(description: "both sources submitted")
        bothSourcesStarted.expectedFulfillmentCount = 2
        let releaseGate = ScannerReleaseGate()
        let resultImage = scannerPNGData(color: .orange)
        let fixture = try makeFixture { _, _ in
            bothSourcesStarted.fulfill()
            await releaseGate.wait()
            return ChekinanaScannerProcessResult(
                images: [resultImage],
                warningCount: 0
            )
        }
        let task = Task { @MainActor in
            await fixture.executor.execute(
                "scancheki",
                pendingChekiImages: [testImage(1), testImage(2)]
            )
        }

        await fulfillment(of: [bothSourcesStarted], timeout: 1)
        await releaseGate.release()
        let response = await task.value

        guard case .chekiScannedCards(let count, let warningCount, _) = response else {
            return XCTFail("expected both queued sources to complete")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(warningCount, 0)
    }

    func testScanSkipsInvalidResultAndKeepsClassificationFailureAsUnassigned() async throws {
        let firstImage = scannerPNGData(color: .red)
        let invalidImage = Data([0x01, 0x02, 0x03, 0x04])
        let secondImage = scannerPNGData(color: .blue)
        var embedding = Array(repeating: Float.zero, count: 256)
        embedding[0] = 1
        let fixture = try makeFixture(
            scannerProcess: { _, _ in
                ChekinanaScannerProcessResult(
                    images: [firstImage, invalidImage, secondImage],
                    warningCount: 0
                )
            },
            patternEncode: { data in
                if data == firstImage {
                    throw ScannerMockError.failed
                }
                return embedding
            }
        )
        let idol = Idol(name: "Candidate")
        idol.patterns = [embedding]
        fixture.context.insert(idol)
        try fixture.context.save()

        let response = await fixture.executor.execute(
            "scancheki idol_recognition=true candidates=\(idol.id.uuidString.lowercased())",
            pendingChekiImages: [testImage(1)]
        )

        guard case .chekiScannedCards(let count, let warningCount, let cards) = response else {
            return XCTFail("expected valid images to survive item failures")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(warningCount, 2, "one invalid image and one classification failure")
        let temporary = try cards.map {
            try fixture.ledger.resolveTemporaryCheki(shortID($0.id))
        }
        XCTAssertTrue(temporary[0].idolIDs.isEmpty)
        XCTAssertEqual(temporary[1].idolIDs, [idol.id])
    }

    func testScanDateUnavailableWarnsOnlyThatResultAndKeepsDetectedAnnotation() async throws {
        let box = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 100,
            y1: 200,
            x2: 900,
            y2: 800
        ))
        let annotation = try XCTUnwrap(ChekinanaChekiDateAnnotation(
            text: "2026.08.02",
            precision: .fullDate,
            boundingBox: box
        ))
        let fixture = try makeFixture { _, _ in
            ChekinanaScannerProcessResult(
                images: [
                    ChekinanaScannerResultImage(
                        data: self.scannerPNGData(color: .red),
                        dateAnnotationState: .unavailable
                    ),
                    ChekinanaScannerResultImage(
                        data: self.scannerPNGData(color: .green),
                        dateAnnotationState: .detected(annotation)
                    ),
                ],
                warningCount: 0
            )
        }

        let response = await fixture.executor.execute(
            "scancheki date_recognition=true",
            pendingChekiImages: [testImage(1)]
        )

        guard case .chekiScannedCards(let count, let warningCount, let cards) = response else {
            return XCTFail("expected both clean images")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(warningCount, 1)
        XCTAssertEqual(cards[0].dateAnnotationState, .unavailable)
        XCTAssertEqual(cards[1].dateAnnotationState, .detected(annotation))
    }

    func testScanProgressObserverCoversBackendLocalIdolWorkAndPreview() async throws {
        var updates: [ChekinanaScanProgress] = []
        var embedding = Array(repeating: Float.zero, count: 256)
        embedding[0] = 1
        let resultImages = [
            scannerPNGData(color: .red),
            scannerPNGData(color: .blue),
        ]
        let fixture = try makeFixture(
            scannerProcess: { _, _ in
                ChekinanaScannerProcessResult(images: resultImages, warningCount: 0)
            },
            patternEncode: { _ in embedding },
            scanProgressObserver: { updates.append($0) }
        )
        let idol = Idol(name: "Progress Candidate")
        idol.patterns = [embedding]
        fixture.context.insert(idol)
        try fixture.context.save()

        _ = await fixture.executor.execute(
            "scancheki idol_recognition=true candidates=\(idol.id.uuidString.lowercased())",
            pendingChekiImages: [testImage(1)]
        )

        XCTAssertTrue(updates.contains {
            if case .backend = $0.stage { return true }
            return false
        })
        XCTAssertTrue(updates.contains {
            if case .preparingResult(let index, let count, let recognizesIdol) = $0.stage {
                return index == 1 && count == 2 && recognizesIdol
            }
            return false
        })
        XCTAssertTrue(updates.contains {
            if case .generatingPreview = $0.stage { return true }
            return false
        })
        XCTAssertEqual(updates.last?.downloadedResultCount, 2)
        XCTAssertEqual(updates.last?.preparedResultCount, 2)
    }

    func testScanRejectsNonEmptyNonImageResultWithoutTemporaryWrite() async throws {
        let fixture = try makeFixture { _, _ in
            ChekinanaScannerProcessResult(
                images: [Data([0x01, 0x02, 0x03, 0x04])],
                warningCount: 0
            )
        }

        let response = await fixture.executor.execute(
            "scancheki",
            pendingChekiImages: [testImage(1)]
        )

        XCTAssertTrue(text(from: response).contains("no Cheki images"))
        XCTAssertTrue(fixture.ledger.availableTemporaryChekiChoices().isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    func testCancelledScanIgnoresLateNonCooperativeScannerResult() async throws {
        let scannerStarted = expectation(description: "scanner started")
        let scannerRelease = ScannerReleaseGate()
        let validResult = scannerPNGData(color: .purple)
        let fixture = try makeFixture { _, _ in
            scannerStarted.fulfill()
            await scannerRelease.wait()
            return ChekinanaScannerProcessResult(images: [validResult], warningCount: 0)
        }

        let task = Task { @MainActor in
            await fixture.executor.execute(
                "scancheki",
                pendingChekiImages: [testImage(1)]
            )
        }
        await fulfillment(of: [scannerStarted], timeout: 1)
        task.cancel()
        await scannerRelease.release()
        _ = await task.value

        XCTAssertTrue(fixture.ledger.availableTemporaryChekiChoices().isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    func testCancelledMultiSourceScanDrainsLateTasksAndSuppressesProgressBeforeReturning() async throws {
        let bothSourcesStarted = expectation(description: "both non-cooperative scanners started")
        bothSourcesStarted.expectedFulfillmentCount = 2
        let scannerRelease = ScannerReleaseGate()
        let lifecycle = ScannerCancellationLifecycleProbe()
        let validResult = scannerPNGData(color: .brown)
        var progressUpdates: [ChekinanaScanProgress] = []
        let fixture = try makeFixture(
            scannerProcess: { _, _ in
                bothSourcesStarted.fulfill()
                await scannerRelease.wait()
                await lifecycle.sourceFinished()
                return ChekinanaScannerProcessResult(
                    images: [validResult],
                    warningCount: 0
                )
            },
            scanProgressObserver: { progressUpdates.append($0) }
        )

        let task = Task { @MainActor in
            let response = await fixture.executor.execute(
                "scancheki",
                pendingChekiImages: [testImage(1), testImage(2)]
            )
            await lifecycle.executeReturned()
            return response
        }
        await fulfillment(of: [bothSourcesStarted], timeout: 1)
        task.cancel()
        let progressCountAtCancellation = progressUpdates.count
        try? await Task.sleep(nanoseconds: 50_000_000)

        let finishedBeforeRelease = await lifecycle.finishedSourceCount()
        let returnedBeforeRelease = await lifecycle.hasExecuteReturned()
        XCTAssertEqual(finishedBeforeRelease, 0)
        XCTAssertFalse(returnedBeforeRelease)

        await scannerRelease.release()
        _ = await task.value

        let finishedAfterRelease = await lifecycle.finishedSourceCount()
        let returnedAfterRelease = await lifecycle.hasExecuteReturned()
        XCTAssertEqual(finishedAfterRelease, 2)
        XCTAssertTrue(returnedAfterRelease)
        XCTAssertEqual(progressUpdates.count, progressCountAtCancellation)
        XCTAssertTrue(fixture.ledger.availableTemporaryChekiChoices().isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    func testScanWithoutPodFailsLocallyBeforeScannerOrTemporaryWrite() async throws {
        var scannerWasCalled = false
        let fixture = try makeFixture { _, _ in
            scannerWasCalled = true
            return ChekinanaScannerProcessResult(images: [Data([101])], warningCount: 0)
        }

        let response = await fixture.executor.execute(
            "scancheki",
            pendingChekiImages: [testImage(1)]
        )

        XCTAssertTrue(text(from: response).contains("pod is required"))
        XCTAssertFalse(scannerWasCalled)
        XCTAssertTrue(fixture.ledger.availableTemporaryChekiChoices().isEmpty)
    }

    func testCredentialedEventURLIsRejectedWithoutWriteLedgerEntryOrEcho() async throws {
        let fixture = try makeFixture()
        let response = await fixture.executor.execute(
            "addevent https://user:password@example.com/live"
        )

        let output = text(from: response)
        XCTAssertTrue(output.contains("invalid event url"))
        XCTAssertFalse(output.contains("user"))
        XCTAssertFalse(output.contains("password"))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
    }

    func testHelpAndInvalidUsageDescribeMediaOnlyAddChekiContract() async throws {
        let fixture = try makeFixture()
        let help = text(from: await fixture.executor.execute("help"))
        let optionalUsage = "addcheki [idol=<idol_id_or_name[,idol_id_or_name...]>] [event=<event_id>] [date=YYYY-MM-DD]"

        XCTAssertTrue(help.contains("可直接用已选相册照片添加 Cheki"))
        XCTAssertTrue(help.contains("idol、event、date 和其他 metadata 均可稍后填写"))
        let oldMandatoryUsage = "addcheki <idol_id_or_name[,idol_id_or_name...]> "
            + "date=YYYY-MM-DD"
        let oldDateError = "date=YYYY-MM-DD is required before "
            + "a Cheki can be confirmed"
        XCTAssertFalse(help.contains(oldMandatoryUsage))
        XCTAssertFalse(help.contains(oldDateError))

        let invalidUsage = text(from: await fixture.executor.execute("addcheki unsupported=value"))
        XCTAssertTrue(invalidUsage.contains(optionalUsage))
        XCTAssertTrue(invalidUsage.contains("idol, event, date, and other metadata are optional"))

        guard case .requestAddChekiPhoto = await fixture.executor.execute("addcheki") else {
            return XCTFail("media-only addcheki must open the selected-photo flow")
        }
    }

    func testEventNameResolutionSupportsChekiAndDuplicateIsDistinctFromAmbiguity() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "Alice")
        let exact = Event(name: "Summer")
        let longer = Event(name: "Summer Tour")
        fixture.context.insert(idol)
        fixture.context.insert(exact)
        fixture.context.insert(longer)
        try fixture.context.save()

        let request = await fixture.executor.execute(
            "addcheki idol=Alice event=Summer date=2026-08-01"
        )
        guard case .requestAddChekiPhoto = request else {
            return XCTFail("exact Event name should resolve for Cheki")
        }

        let ambiguous = await fixture.executor.execute(
            "addcheki idol=Alice event=Summ date=2026-08-01"
        )
        XCTAssertTrue(text(from: ambiguous).contains("ambiguous event"))

        let duplicate = await fixture.executor.execute("addevent Summer date=2026-08-01")
        guard case .confirmationText(_, let code) = duplicate else {
            return XCTFail("date makes this a distinct event")
        }
        _ = await fixture.executor.execute("confirm \(code)")
        let duplicateAgain = await fixture.executor.execute("addevent Summer date=2026-08-01")
        XCTAssertTrue(text(from: duplicateAgain).contains("same name, date, and url"))
    }

    func testIdolMultiResultPreservesAPIOrderFiltersAndConfirmsIndependently() async throws {
        let exact = enrichedIdol(sourceID: "catalogue-exact", name: "Aina", group: "空色轨迹")
        let fuzzy = enrichedIdol(sourceID: "catalogue-fuzzy", name: "Aina Related", group: "Other")
        let duplicate = enrichedIdol(sourceID: exact.sourceId, name: "Duplicate", group: nil)
        let alreadyAdded = enrichedIdol(sourceID: "catalogue-existing", name: "Existing", group: nil)
        let fixture = try makeFixture(idolSearch: { _ in
            [exact, fuzzy, duplicate, alreadyAdded]
        })
        fixture.context.insert(Idol(sourceId: alreadyAdded.sourceId, name: alreadyAdded.idolName))
        try fixture.context.save()

        let response = await fixture.executor.execute("addidol Aina")
        guard case .idolCards(let cards) = response else {
            return XCTFail("expected multiple selectable Idol cards")
        }
        XCTAssertEqual(cards.map(\.catalogueID), [exact.sourceId, fuzzy.sourceId])
        XCTAssertEqual(cards.map(\.name), [exact.idolName, fuzzy.idolName])
        XCTAssertTrue(cards.allSatisfy { $0.confirmationCode == nil && $0.selectionToken != nil })
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)

        let fuzzyToken = try XCTUnwrap(cards[1].selectionToken)
        guard case .idolCard(let fuzzySaved) = await fixture.executor.execute(
            "confirmidolcandidate \(fuzzyToken)"
        ) else {
            return XCTFail("expected selected Idol to save")
        }
        XCTAssertEqual(fuzzySaved.catalogueID, fuzzy.sourceId)

        let exactToken = try XCTUnwrap(cards[0].selectionToken)
        guard case .idolCard(let exactSaved) = await fixture.executor.execute(
            "confirmidolcandidate \(exactToken)"
        ) else {
            return XCTFail("expected another candidate in the same batch to remain confirmable")
        }
        XCTAssertEqual(exactSaved.catalogueID, exact.sourceId)
        let saved = try fixture.context.fetch(FetchDescriptor<Idol>())
        XCTAssertNotNil(saved.first { $0.sourceId == fuzzy.sourceId })
        XCTAssertNotNil(saved.first { $0.sourceId == exact.sourceId })
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
    }

    func testSingleIdolConfirmationAddsMappedLocalPatternWithoutDuplicates() async throws {
        let candidate = enrichedIdol(
            sourceID: "idol_002009",
            name: "aina",
            group: "Catalogue group"
        )
        let fixture = try makeFixture(idolSearch: { _ in [candidate] })

        guard case .idolCard(let preview) = await fixture.executor.execute("addidol aina"),
              let code = preview.confirmationCode else {
            return XCTFail("expected single Idol confirmation")
        }
        guard case .idolCard = await fixture.executor.execute("confirm \(code)") else {
            return XCTFail("expected confirmed Idol card")
        }

        let saved = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<Idol>()).first)
        XCTAssertEqual(saved.sourceId, candidate.sourceId)
        XCTAssertEqual(
            saved.patterns,
            ChekinanaLocalPatternRegistry.patterns(for: candidate.sourceId)
        )
        XCTAssertEqual(saved.patterns.count, 1)
    }

    func testBatchCandidateConfirmAddsMinaPatternsAndLeavesUnknownEmpty() async throws {
        let mina = enrichedIdol(
            sourceID: "idol_001326",
            name: "mina",
            group: "凌晨12点"
        )
        let unknown = enrichedIdol(
            sourceID: "idol_unknown_dialogue",
            name: "Unknown",
            group: nil
        )
        let fixture = try makeFixture(idolSearch: { query in
            query == "mina" ? [mina] : [unknown]
        })

        guard case .idolCards(let cards) = await fixture.executor.addIdols([
            "addidol mina",
            "addidol Unknown",
        ]) else {
            return XCTFail("expected batch candidate cards")
        }
        XCTAssertEqual(cards.map(\.catalogueID), [mina.sourceId, unknown.sourceId])
        for card in cards {
            let token = try XCTUnwrap(card.selectionToken)
            guard case .idolCard = await fixture.executor.execute(
                "confirmidolcandidate \(token)"
            ) else {
                return XCTFail("expected direct candidate confirmation")
            }
        }

        let saved = try fixture.context.fetch(FetchDescriptor<Idol>())
        let savedMina = try XCTUnwrap(saved.first { $0.sourceId == mina.sourceId })
        XCTAssertEqual(
            savedMina.patterns,
            ChekinanaLocalPatternRegistry.patterns(for: mina.sourceId)
        )
        XCTAssertEqual(savedMina.patterns.count, 2)
        let savedUnknown = try XCTUnwrap(saved.first { $0.sourceId == unknown.sourceId })
        XCTAssertTrue(savedUnknown.patterns.isEmpty)
    }

    func testSelectedCandidateThenConfirmationAddsMappedPatternOnce() async throws {
        let mapped = enrichedIdol(
            sourceID: "idol_000513",
            name: "巫歌",
            group: "Catalogue group"
        )
        let other = enrichedIdol(
            sourceID: "idol_other_dialogue",
            name: "Other",
            group: nil
        )
        let fixture = try makeFixture(idolSearch: { _ in [mapped, other] })

        guard case .idolCards(let cards) = await fixture.executor.execute("addidol 巫歌"),
              let token = cards.first?.selectionToken else {
            return XCTFail("expected multiple candidates")
        }
        guard case .idolCard(let selected) = await fixture.executor.execute(
            "selectidolcandidate \(token)"
        ), let code = selected.confirmationCode else {
            return XCTFail("expected selected candidate confirmation")
        }
        guard case .idolCard = await fixture.executor.execute("confirm \(code)") else {
            return XCTFail("expected selected candidate save")
        }

        let saved = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<Idol>()).first)
        XCTAssertEqual(saved.sourceId, mapped.sourceId)
        XCTAssertEqual(
            saved.patterns,
            ChekinanaLocalPatternRegistry.patterns(for: mapped.sourceId)
        )
        XCTAssertEqual(saved.patterns.count, 1)
    }

    func testAddIdolBatchKeepsInputThenCandidateOrder() async throws {
        let fixture = try makeFixture(idolSearch: { query in
            switch query {
            case "巫歌":
                return [
                    self.enrichedIdol(sourceID: "wuge-1", name: "巫歌", group: "Lumina"),
                    self.enrichedIdol(sourceID: "wuge-2", name: "巫歌 B", group: "Other"),
                ]
            case "Mina":
                return [
                    self.enrichedIdol(sourceID: "mina-1", name: "Mina", group: "First"),
                    self.enrichedIdol(sourceID: "mina-2", name: "Mina", group: "凌晨12点"),
                ]
            default:
                return []
            }
        })

        guard case .idolCards(let cards) = await fixture.executor.addIdols([
            "addidol 巫歌",
            "addidol Mina",
        ]) else {
            return XCTFail("expected a single stable candidate batch")
        }
        XCTAssertEqual(cards.map(\.catalogueID), ["wuge-1", "wuge-2", "mina-1", "mina-2"])
        XCTAssertEqual(cards.count, 4)
        XCTAssertTrue(cards.allSatisfy { $0.selectionToken != nil })
    }

    func testIdolAvatarPreparationPreservesSearchOrderAndStrictIdentity() async throws {
        let firstData = Data([0xA1])
        let secondData = Data([0xB2])
        let first = enrichedIdol(
            sourceID: "avatar-first",
            name: "First",
            group: nil,
            avatarURL: "https://example.com/first.jpg"
        )
        let second = enrichedIdol(
            sourceID: "avatar-second",
            name: "Second",
            group: nil,
            avatarURL: "https://example.com/second.jpg"
        )
        let fixture = try makeFixture(
            idolSearch: { _ in [first, second] },
            idolAvatarPrepare: { candidate in
                if candidate.sourceId == first.sourceId {
                    try await Task.sleep(nanoseconds: 40_000_000)
                    return firstData
                }
                return secondData
            }
        )

        guard case .idolCards(let cards) = await fixture.executor.execute("addidol Avatar") else {
            return XCTFail("expected prepared candidates")
        }
        XCTAssertEqual(cards.map(\.catalogueID), [first.sourceId, second.sourceId])
        XCTAssertEqual(cards.map(\.avatarThumbnailData), [firstData, secondData])
        XCTAssertEqual(cards.map(\.avatarIdentity), [
            ChekinanaIdolAvatarIdentity.make(sourceID: first.sourceId, avatarURL: first.avatarUrl),
            ChekinanaIdolAvatarIdentity.make(sourceID: second.sourceId, avatarURL: second.avatarUrl),
        ])
    }

    func testIdolAvatarFailureIsolatedAndPreparedDataSurvivesSelectionAndConfirmation() async throws {
        let firstData = Data([0x11])
        let thirdData = Data([0x33])
        let first = enrichedIdol(
            sourceID: "prepared-first",
            name: "First",
            group: nil,
            avatarURL: "https://example.com/first.jpg"
        )
        let failed = enrichedIdol(
            sourceID: "prepared-failed",
            name: "Failed",
            group: nil,
            avatarURL: "https://example.com/failed.jpg"
        )
        let third = enrichedIdol(
            sourceID: "prepared-third",
            name: "Third",
            group: nil,
            avatarURL: "https://example.com/third.jpg"
        )
        let fixture = try makeFixture(
            idolSearch: { query in
                switch query {
                case "First": return [first]
                case "Failed": return [failed]
                default: return [third]
                }
            },
            idolAvatarPrepare: { candidate in
                switch candidate.sourceId {
                case first.sourceId: return firstData
                case third.sourceId: return thirdData
                default: throw ScannerMockError.failed
                }
            }
        )

        guard case .idolCardsWithNotice(let cards, let notice) = await fixture.executor.addIdols([
            "addidol First",
            "addidol Failed",
            "addidol Third",
        ]) else {
            return XCTFail("expected successful cards and isolated failure notice")
        }
        XCTAssertEqual(cards.map(\.catalogueID), [first.sourceId, failed.sourceId, third.sourceId])
        XCTAssertEqual(cards.map(\.avatarThumbnailData), [firstData, nil, thirdData])
        XCTAssertEqual(cards.map(\.avatarIdentity), [
            ChekinanaIdolAvatarIdentity.make(sourceID: first.sourceId, avatarURL: first.avatarUrl),
            nil,
            ChekinanaIdolAvatarIdentity.make(sourceID: third.sourceId, avatarURL: third.avatarUrl),
        ])
        XCTAssertTrue(notice.contains("1 个候选头像"))
        XCTAssertTrue(notice.contains("固定占位图"))

        let token = try XCTUnwrap(cards.first?.selectionToken)
        guard case .idolCard(let selected) = await fixture.executor.execute(
            "selectidolcandidate \(token)"
        ), let code = selected.confirmationCode else {
            return XCTFail("expected selected confirmation card")
        }
        XCTAssertEqual(selected.avatarThumbnailData, firstData)
        XCTAssertEqual(selected.avatarIdentity, cards[0].avatarIdentity)

        guard case .idolCard(let saved) = await fixture.executor.execute("confirm \(code)") else {
            return XCTFail("expected confirmed Idol card")
        }
        XCTAssertEqual(saved.avatarThumbnailData, firstData)
        XCTAssertEqual(saved.avatarIdentity, cards[0].avatarIdentity)
    }

    func testTenIdolAvatarCandidatesPublishInOrderAfterPartialFailureAndBatchTimeout() async throws {
        let results = (0..<10).map { index in
            enrichedIdol(
                sourceID: "batch-\(index)",
                name: "Batch \(index)",
                group: nil,
                avatarURL: "https://example.com/batch-\(index).jpg"
            )
        }
        let fixture = try makeFixture(
            idolSearch: { _ in results },
            idolAvatarPrepare: { candidate in
                let index = Int(candidate.sourceId.split(separator: "-").last ?? "") ?? -1
                switch index {
                case 0..<5:
                    return Data([UInt8(index + 1)])
                case 5:
                    throw ScannerMockError.failed
                case 6:
                    return nil
                default:
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return Data([0xFF])
                }
            },
            idolAvatarBatchTimeoutNanoseconds: 80_000_000
        )
        let startedAt = Date()

        guard case .idolCardsWithNotice(let cards, let notice) =
                await fixture.executor.execute("addidol Batch") else {
            return XCTFail("expected all candidates with a placeholder notice")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertEqual(cards.count, 10)
        XCTAssertEqual(cards.map(\.catalogueID), results.map(\.sourceId))
        XCTAssertEqual(cards.prefix(5).map(\.avatarThumbnailData), (1...5).map { Data([UInt8($0)]) })
        XCTAssertTrue(cards.dropFirst(5).allSatisfy { $0.avatarThumbnailData == nil })
        XCTAssertEqual(cards.prefix(5).map(\.avatarIdentity), results.prefix(5).map {
            ChekinanaIdolAvatarIdentity.make(sourceID: $0.sourceId, avatarURL: $0.avatarUrl)
        })
        XCTAssertTrue(cards.dropFirst(5).allSatisfy { $0.avatarIdentity == nil })
        XCTAssertTrue(cards.allSatisfy { $0.selectionToken != nil })
        XCTAssertTrue(notice.contains("5 个候选头像"))
        XCTAssertTrue(notice.contains("固定占位图"))
    }

    func testNonCooperativeAvatarBatchPublishesBeforeLateChildrenAndNeverOverwritesLedger() async throws {
        let results = (0..<10).map { index in
            enrichedIdol(
                sourceID: "noncoop-\(index)",
                name: "Noncoop \(index)",
                group: nil,
                avatarURL: "https://example.com/noncoop-\(index).jpg"
            )
        }
        let networkLimiter = ChekinanaRemoteRequestLimiter(limit: 2)
        let probe = ChekinanaNonCooperativeAvatarProbe()
        let fixture = try makeFixture(
            idolSearch: { _ in results },
            idolAvatarPrepare: { candidate in
                let index = Int(candidate.sourceId.split(separator: "-").last ?? "") ?? 0
                let data = try await networkLimiter.perform { Data([UInt8(index + 1)]) }
                probe.recordStarted(index)
                chekinanaTestBlockingSleep(0.6)
                probe.recordFinished(index)
                return data
            },
            idolAvatarBatchTimeoutNanoseconds: 20_000_000
        )
        let startedAt = Date()

        guard case .idolCardsWithNotice(let cards, let notice) =
                await fixture.executor.execute("addidol Noncoop") else {
            return XCTFail("expected timed-out candidates with placeholders")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.4)
        XCTAssertEqual(cards.map(\.catalogueID), results.map(\.sourceId))
        XCTAssertTrue(cards.allSatisfy { $0.avatarThumbnailData == nil })
        XCTAssertTrue(cards.allSatisfy { $0.avatarIdentity == nil })
        XCTAssertTrue(notice.contains("10 个候选头像"))
        let initialProbe = probe.snapshot()
        XCTAssertGreaterThan(initialProbe.started.count, 0)
        XCTAssertTrue(initialProbe.finished.isEmpty)
        let limiterAfterTimeout = await networkLimiter.snapshot()
        XCTAssertEqual(limiterAfterTimeout, .init(activeCount: 0, waitingCount: 0))

        try await Task.sleep(nanoseconds: 750_000_000)
        let lateProbe = probe.snapshot()
        XCTAssertEqual(lateProbe.finished, lateProbe.started)
        XCTAssertGreaterThan(lateProbe.finished.count, 0)

        let token = try XCTUnwrap(cards.first?.selectionToken)
        guard case .idolCard(let selected) = await fixture.executor.execute(
            "selectidolcandidate \(token)"
        ) else {
            return XCTFail("expected candidate stored at publication boundary")
        }
        XCTAssertNil(selected.avatarThumbnailData)
        XCTAssertNil(selected.avatarIdentity)
        let limiterAfterLateResult = await networkLimiter.snapshot()
        XCTAssertEqual(limiterAfterLateResult, .init(activeCount: 0, waitingCount: 0))
    }

    func testTenIdolAvatarCandidateCancellationReleasesExecutorPromptly() async throws {
        let results = (0..<10).map { index in
            enrichedIdol(
                sourceID: "cancel-\(index)",
                name: "Cancel \(index)",
                group: nil,
                avatarURL: "https://example.com/cancel-\(index).jpg"
            )
        }
        let networkLimiter = ChekinanaRemoteRequestLimiter(limit: 2)
        let probe = ChekinanaNonCooperativeAvatarProbe()
        let fixture = try makeFixture(
            idolSearch: { _ in results },
            idolAvatarPrepare: { candidate in
                let index = Int(candidate.sourceId.split(separator: "-").last ?? "") ?? 0
                let data = try await networkLimiter.perform { Data([UInt8(index + 1)]) }
                probe.recordStarted(index)
                chekinanaTestBlockingSleep(0.6)
                probe.recordFinished(index)
                return data
            }
        )
        let task = Task { await fixture.executor.execute("addidol Cancel") }

        for _ in 0..<100 where probe.snapshot().started.isEmpty {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(probe.snapshot().started.isEmpty)
        let cancelledAt = Date()
        task.cancel()
        let response = await task.value

        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.4)
        guard case .text(let message) = response else {
            return XCTFail("cancelled executor must not publish partial candidate cards")
        }
        XCTAssertTrue(message.hasPrefix("error:"))
        let limiterAfterCancellation = await networkLimiter.snapshot()
        XCTAssertEqual(limiterAfterCancellation, .init(activeCount: 0, waitingCount: 0))
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(probe.snapshot().finished, probe.snapshot().started)
        let limiterAfterCancelledChildrenFinish = await networkLimiter.snapshot()
        XCTAssertEqual(
            limiterAfterCancelledChildrenFinish,
            .init(activeCount: 0, waitingCount: 0)
        )
    }

    func testIdolWithoutDeclaredAvatarUsesStablePlaceholderCandidate() async throws {
        let result = enrichedIdol(sourceID: "no-avatar", name: "No Avatar", group: nil)
        let fixture = try makeFixture(
            idolSearch: { _ in [result] },
            idolAvatarPrepare: { _ in
                XCTFail("avatar preparation must not run without an API avatar URL")
                return Data([0xFF])
            }
        )

        guard case .idolCard(let card) = await fixture.executor.execute("addidol \"No Avatar\"") else {
            return XCTFail("expected direct confirmation card")
        }
        XCTAssertNil(card.avatarThumbnailData)
        XCTAssertNil(card.avatarIdentity)
    }

    func testSingleIdolPreparedAvatarSurvivesDirectConfirmation() async throws {
        let thumbnail = Data([0x71, 0x72])
        let result = enrichedIdol(
            sourceID: "single-avatar",
            name: "Single Avatar",
            group: nil,
            avatarURL: "https://example.com/single.jpg"
        )
        let fixture = try makeFixture(
            idolSearch: { _ in [result] },
            idolAvatarPrepare: { _ in thumbnail }
        )

        guard case .idolCard(let preview) = await fixture.executor.execute(
            "addidol \"Single Avatar\""
        ), let code = preview.confirmationCode else {
            return XCTFail("expected direct confirmation card")
        }
        XCTAssertEqual(preview.avatarThumbnailData, thumbnail)
        let expectedIdentity = ChekinanaIdolAvatarIdentity.make(
            sourceID: result.sourceId,
            avatarURL: result.avatarUrl
        )
        XCTAssertEqual(preview.avatarIdentity, expectedIdentity)

        guard case .idolCard(let saved) = await fixture.executor.execute("confirm \(code)") else {
            return XCTFail("expected saved Idol card")
        }
        XCTAssertEqual(saved.avatarThumbnailData, thumbnail)
        XCTAssertEqual(saved.avatarIdentity, expectedIdentity)
    }

    func testAddIdolBatchExecutesAllTwentyFiveNamesWithoutTruncation() async throws {
        var searched: [String] = []
        let fixture = try makeFixture(idolSearch: { query in
            searched.append(query)
            return [self.enrichedIdol(
                sourceID: "source-\(query)",
                name: query,
                group: nil
            )]
        })
        let names = (1...25).map { "偶像\($0)" }

        guard case .idolCards(let cards) = await fixture.executor.addIdols(
            names.map { "addidol \($0)" }
        ) else {
            return XCTFail("expected all candidates in one batch")
        }

        XCTAssertEqual(searched.count, names.count)
        XCTAssertEqual(Set(searched), Set(names))
        XCTAssertEqual(cards.map(\.name), names)
        XCTAssertEqual(cards.count, 25)
        XCTAssertTrue(cards.allSatisfy { $0.selectionToken != nil })
    }

    func testAddIdolBatchContinuesAfterMiddleSearchFailureAndShowsRetryNotice() async throws {
        var searched: [String] = []
        let fixture = try makeFixture(idolSearch: { query in
            searched.append(query)
            if query == "饭饭" {
                throw ScannerMockError.failed
            }
            return [
                self.enrichedIdol(
                    sourceID: "source-\(query)",
                    name: query,
                    group: "Group"
                )
            ]
        })

        let response = await fixture.executor.addIdols([
            "addidol 巫歌",
            "addidol 饭饭",
            "addidol 木兰",
        ])
        guard case .idolCardsWithNotice(let cards, let notice) = response else {
            return XCTFail("expected successful cards plus a retry notice")
        }
        XCTAssertEqual(Set(searched), Set(["巫歌", "饭饭", "木兰"]))
        XCTAssertEqual(cards.map(\.name), ["巫歌", "木兰"])
        XCTAssertTrue(notice.contains("饭饭"))
        XCTAssertTrue(notice.contains("重试"))
    }

    func testAddIdolCatalogueSearchesRunConcurrentlyThenRestoreInputOrderAndIsolateFailure() async throws {
        let started = expectation(description: "four catalogue searches started concurrently")
        started.expectedFulfillmentCount = 4
        let release = ScannerReleaseGate()
        let first = enrichedIdol(sourceID: "concurrent-first", name: "First", group: nil)
        let firstSecond = enrichedIdol(
            sourceID: "concurrent-first-second",
            name: "First Second Result",
            group: nil
        )
        let duplicateFirst = enrichedIdol(
            sourceID: first.sourceId,
            name: "Late Duplicate",
            group: nil
        )
        let third = enrichedIdol(sourceID: "concurrent-third", name: "Third", group: nil)
        let fourth = enrichedIdol(sourceID: "concurrent-fourth", name: "Fourth", group: nil)
        let fixture = try makeFixture(idolSearch: { query in
            started.fulfill()
            await release.wait()
            switch query {
            case "First":
                try await Task.sleep(nanoseconds: 45_000_000)
            case "Failed":
                try await Task.sleep(nanoseconds: 10_000_000)
                throw ScannerMockError.failed
            case "Fourth":
                try await Task.sleep(nanoseconds: 25_000_000)
            default:
                break
            }
            switch query {
            case "First": return [first, firstSecond]
            case "Third": return [duplicateFirst, third]
            default: return [fourth]
            }
        })

        let task = Task { @MainActor in
            await fixture.executor.addIdols([
                "addidol First",
                "addidol Failed",
                "addidol Third",
                "addidol Fourth",
            ])
        }
        await fulfillment(of: [started], timeout: 1)
        await release.release()

        guard case .idolCardsWithNotice(let cards, let notice) = await task.value else {
            return XCTFail("expected ordered successes and an isolated failure")
        }
        XCTAssertEqual(
            cards.map(\.name),
            ["First", "First Second Result", "Third", "Fourth"]
        )
        XCTAssertTrue(notice.contains("Failed"))
        XCTAssertTrue(notice.contains("重试"))
    }

    func testIdolCatalogueRequestHasBoundedTimeoutWithoutChangingEndpoint() throws {
        let request = try ChekinanaIdolEnrichmentClient.request(for: "  mina  ")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "idol.chekinana.top")
        XCTAssertEqual(request.url?.path, "/api/search/idol")
        XCTAssertEqual(request.timeoutInterval, ChekinanaIdolEnrichmentClient.requestTimeout)
        XCTAssertGreaterThan(request.timeoutInterval, 0)
        XCTAssertLessThanOrEqual(request.timeoutInterval, 15)
        let components = URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "idolName" })?.value,
            "mina"
        )
    }

    func testRemoteRequestLimiterRemovesCancelledWaiterBeforePermitRelease() async throws {
        let limiter = ChekinanaRemoteRequestLimiter(limit: 1)
        let holderStarted = expectation(description: "permit holder started")
        let holderRelease = ScannerReleaseGate()
        let holder = Task {
            try await limiter.perform {
                holderStarted.fulfill()
                await holderRelease.wait()
                return "holder"
            }
        }
        await fulfillment(of: [holderStarted], timeout: 1)

        let cancelledOperation = LimiterOperationProbe()
        let cancelledFinished = expectation(description: "cancelled waiter completed immediately")
        let cancelled = Task { () -> Bool in
            defer { cancelledFinished.fulfill() }
            do {
                _ = try await limiter.perform {
                    await cancelledOperation.recordExecution()
                    return "cancelled"
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let didQueueCancelled = await waitForLimiter(limiter, active: 1, waiting: 1)
        XCTAssertTrue(didQueueCancelled)

        cancelled.cancel()
        await fulfillment(of: [cancelledFinished], timeout: 1)
        let cancellationWasObserved = await cancelled.value
        let cancelledExecutionCount = await cancelledOperation.count()
        let stateAfterCancellation = await limiter.snapshot()
        XCTAssertTrue(cancellationWasObserved)
        XCTAssertEqual(cancelledExecutionCount, 0)
        XCTAssertEqual(stateAfterCancellation, .init(activeCount: 1, waitingCount: 0))

        let successorStarted = expectation(description: "successor received released permit")
        let successor = Task {
            try await limiter.perform {
                successorStarted.fulfill()
                return "successor"
            }
        }
        let didQueueSuccessor = await waitForLimiter(limiter, active: 1, waiting: 1)
        XCTAssertTrue(didQueueSuccessor)
        await holderRelease.release()
        await fulfillment(of: [successorStarted], timeout: 1)
        let holderValue = try await holder.value
        let successorValue = try await successor.value
        let finalState = await limiter.snapshot()
        XCTAssertEqual(holderValue, "holder")
        XCTAssertEqual(successorValue, "successor")
        XCTAssertEqual(finalState, .init(activeCount: 0, waitingCount: 0))
    }

    func testRemoteRequestLimiterCancellationPermitRaceNeverRunsCancelledOperation() async throws {
        let limiter = ChekinanaRemoteRequestLimiter(limit: 1)
        let holderStarted = expectation(description: "race holder started")
        let holderRelease = ScannerReleaseGate()
        let holder = Task {
            try await limiter.perform {
                holderStarted.fulfill()
                await holderRelease.wait()
                return 1
            }
        }
        await fulfillment(of: [holderStarted], timeout: 1)

        let cancelledProbe = LimiterOperationProbe()
        let cancelled = Task { () -> Bool in
            do {
                _ = try await limiter.perform {
                    await cancelledProbe.recordExecution()
                    return 2
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let successorStarted = expectation(description: "race successor started")
        let successor = Task {
            try await limiter.perform {
                successorStarted.fulfill()
                return 3
            }
        }
        let didQueueBoth = await waitForLimiter(limiter, active: 1, waiting: 2)
        XCTAssertTrue(didQueueBoth)

        // Mark cancellation before releasing the active operation. Depending
        // on actor scheduling, cancellation removes the waiter or the permit
        // is granted first and the pre-operation check transfers it onward.
        cancelled.cancel()
        await holderRelease.release()

        await fulfillment(of: [successorStarted], timeout: 1)
        let cancellationWasObserved = await cancelled.value
        let cancelledExecutionCount = await cancelledProbe.count()
        let holderValue = try await holder.value
        let successorValue = try await successor.value
        let finalState = await limiter.snapshot()
        XCTAssertTrue(cancellationWasObserved)
        XCTAssertEqual(cancelledExecutionCount, 0)
        XCTAssertEqual(holderValue, 1)
        XCTAssertEqual(successorValue, 3)
        XCTAssertEqual(finalState, .init(activeCount: 0, waitingCount: 0))

        do {
            _ = try await limiter.perform { () -> Int in
                throw ScannerMockError.failed
            }
            XCTFail("limiter must preserve operation errors")
        } catch ScannerMockError.failed {
            // Expected: limiter owns concurrency, not error translation.
        }
        let stateAfterError = await limiter.snapshot()
        XCTAssertEqual(stateAfterError, .init(activeCount: 0, waitingCount: 0))
    }

    func testAddIdolBatchReportsAlreadyAddedAndFailedNamesTogether() async throws {
        let existing = self.enrichedIdol(
            sourceID: "source-existing",
            name: "A",
            group: "Group"
        )
        let fixture = try makeFixture(idolSearch: { query in
            if query == "B" {
                throw ScannerMockError.failed
            }
            return [existing]
        })
        fixture.context.insert(Idol(sourceId: existing.sourceId, name: existing.idolName))
        try fixture.context.save()

        let response = await fixture.executor.addIdols([
            "addidol A",
            "addidol B",
        ])
        let output = text(from: response)
        XCTAssertTrue(output.contains("已添加的 Idol：A"))
        XCTAssertTrue(output.contains("搜索失败"))
        XCTAssertTrue(output.contains("B"))
        XCTAssertTrue(output.contains("重试"))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<Idol>()).count, 1)
    }

    func testIdolCandidateTokenBecomesStaleAfterNewQueryAndInvalidTokenDoesNotWrite() async throws {
        let firstResults = [
            enrichedIdol(sourceID: "first-a", name: "First A", group: nil),
            enrichedIdol(sourceID: "first-b", name: "First B", group: nil),
        ]
        let secondResults = [
            enrichedIdol(sourceID: "second-a", name: "Second A", group: nil),
            enrichedIdol(sourceID: "second-b", name: "Second B", group: nil),
        ]
        let fixture = try makeFixture(idolSearch: { query in
            query == "first" ? firstResults : secondResults
        })
        guard case .idolCards(let firstCards) = await fixture.executor.execute("addidol first") else {
            return XCTFail("expected first candidates")
        }
        let staleToken = try XCTUnwrap(firstCards.first?.selectionToken)
        guard case .idolCards(let secondCards) = await fixture.executor.execute("addidol second") else {
            return XCTFail("expected second candidates")
        }
        let currentToken = try XCTUnwrap(secondCards.first?.selectionToken)

        let staleResponse = await fixture.executor.execute("selectidolcandidate \(staleToken)")
        XCTAssertTrue(text(from: staleResponse).contains("no longer available"))
        let invalidatedCurrentResponse = await fixture.executor.execute(
            "selectidolcandidate \(currentToken)"
        )
        XCTAssertTrue(text(from: invalidatedCurrentResponse).contains("no longer available"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)
    }

    func testInvalidIdolCandidateTokenInvalidatesCurrentBatch() async throws {
        let results = [
            enrichedIdol(sourceID: "invalid-a", name: "Invalid A", group: nil),
            enrichedIdol(sourceID: "invalid-b", name: "Invalid B", group: nil),
        ]
        let fixture = try makeFixture(idolSearch: { _ in results })
        guard case .idolCards(let cards) = await fixture.executor.execute("addidol Invalid") else {
            return XCTFail("expected candidates")
        }
        let currentToken = try XCTUnwrap(cards.first?.selectionToken)

        let invalidResponse = await fixture.executor.execute(
            "selectidolcandidate \(UUID().uuidString.lowercased())"
        )
        XCTAssertTrue(text(from: invalidResponse).contains("no longer available"))
        let currentResponse = await fixture.executor.execute(
            "selectidolcandidate \(currentToken)"
        )

        XCTAssertTrue(text(from: currentResponse).contains("no longer available"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)
    }

    func testLateOldIdolQueryCannotOverwriteNewCandidates() async throws {
        let oldResults = [
            enrichedIdol(sourceID: "late-old-a", name: "Late Old A", group: nil),
            enrichedIdol(sourceID: "late-old-b", name: "Late Old B", group: nil),
        ]
        let newResults = [
            enrichedIdol(sourceID: "current-a", name: "Current A", group: nil),
            enrichedIdol(sourceID: "current-b", name: "Current B", group: nil),
        ]
        let oldSearchStarted = expectation(description: "old Idol search started")
        let oldSearchRelease = ScannerReleaseGate()
        let fixture = try makeFixture(idolSearch: { query in
            if query == "old" {
                oldSearchStarted.fulfill()
                await oldSearchRelease.wait()
                return oldResults
            }
            return newResults
        })

        let oldTask = Task { @MainActor in
            await fixture.executor.execute("addidol old")
        }
        await fulfillment(of: [oldSearchStarted], timeout: 1)

        guard case .idolCards(let currentCards) = await fixture.executor.execute("addidol new") else {
            return XCTFail("expected current candidates")
        }
        let currentToken = try XCTUnwrap(currentCards.first?.selectionToken)
        await oldSearchRelease.release()
        let oldResponse = await oldTask.value

        XCTAssertTrue(text(from: oldResponse).contains("no longer active"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        let selection = await fixture.executor.execute("selectidolcandidate \(currentToken)")
        guard case .idolCard(let preview) = selection else {
            return XCTFail("current candidates must remain selectable")
        }
        XCTAssertEqual(preview.catalogueID, newResults[0].sourceId)
        let code = try XCTUnwrap(preview.confirmationCode)
        _ = await fixture.executor.execute("confirm \(code)")
        let saved = try fixture.context.fetch(FetchDescriptor<Idol>())
        XCTAssertEqual(saved.map(\.sourceId), [newResults[0].sourceId])
    }

    func testCancelledLateSingleIdolQueryDoesNotCreateHiddenConfirmation() async throws {
        let result = enrichedIdol(sourceID: "cancelled-single", name: "Cancelled", group: nil)
        let searchStarted = expectation(description: "single Idol search started")
        let searchRelease = ScannerReleaseGate()
        let fixture = try makeFixture(idolSearch: { _ in
            searchStarted.fulfill()
            await searchRelease.wait()
            return [result]
        })

        let task = Task { @MainActor in
            await fixture.executor.execute("addidol Cancelled")
        }
        await fulfillment(of: [searchStarted], timeout: 1)
        _ = await fixture.executor.execute("cancel all")
        task.cancel()
        await searchRelease.release()
        _ = await task.value

        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)
    }

    func testCancelledSelectionOwnerBeforeStartCreatesNoHiddenConfirmationAndAllowsRetry() async throws {
        let results = [
            enrichedIdol(sourceID: "owner-selection-a", name: "Owner A", group: nil),
            enrichedIdol(sourceID: "owner-selection-b", name: "Owner B", group: nil),
        ]
        let fixture = try makeFixture(idolSearch: { _ in results })
        guard case .idolCards = await fixture.executor.execute("addidol Owner") else {
            return XCTFail("expected initial candidates")
        }

        var cancelledGate = ChekinanaOwnedExecutionGate()
        let cancelledOwner = cancelledGate.begin()
        cancelledGate.invalidate()
        fixture.ledger.invalidateIdolCandidates()
        XCTAssertFalse(cancelledGate.accepts(cancelledOwner, isCancelled: true))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)

        guard case .idolCards(let retryCards) = await fixture.executor.execute("addidol Owner") else {
            return XCTFail("expected retry candidates")
        }
        let retryToken = try XCTUnwrap(retryCards.first?.selectionToken)
        var retryGate = ChekinanaOwnedExecutionGate()
        let retryOwner = retryGate.begin()
        XCTAssertTrue(retryGate.accepts(retryOwner, isCancelled: false))
        let retryResponse = await fixture.executor.execute("selectidolcandidate \(retryToken)")
        XCTAssertTrue(retryGate.finish(retryOwner))
        guard case .idolCard(let preview) = retryResponse else {
            return XCTFail("new owner should be able to select a candidate")
        }
        XCTAssertNotNil(preview.confirmationCode)
        XCTAssertEqual(fixture.ledger.activeConfirmationCodes.count, 1)
    }

    func testCancelledConfirmationOwnerBeforeStartDoesNotWriteAndAllowsRetry() async throws {
        let result = enrichedIdol(sourceID: "owner-confirm", name: "Owner Confirm", group: nil)
        let fixture = try makeFixture(idolSearch: { _ in [result] })
        guard case .idolCard(let preview) = await fixture.executor.execute("addidol \"Owner Confirm\""),
              let code = preview.confirmationCode else {
            return XCTFail("expected AddIdol confirmation")
        }

        var cancelledGate = ChekinanaOwnedExecutionGate()
        let cancelledOwner = cancelledGate.begin()
        cancelledGate.invalidate()
        XCTAssertFalse(cancelledGate.accepts(cancelledOwner, isCancelled: true))
        XCTAssertEqual(fixture.ledger.activeConfirmationCodes, Set([code]))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)

        var retryGate = ChekinanaOwnedExecutionGate()
        let retryOwner = retryGate.begin()
        XCTAssertTrue(retryGate.accepts(retryOwner, isCancelled: false))
        try requireSuccess(await fixture.executor.execute("confirm \(code)"))
        XCTAssertTrue(retryGate.finish(retryOwner))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<Idol>()).map(\.sourceId), [result.sourceId])
    }

    func testCancelAllInvalidatesUnconfirmedIdolCandidates() async throws {
        let results = [
            enrichedIdol(sourceID: "cancel-a", name: "Cancel A", group: nil),
            enrichedIdol(sourceID: "cancel-b", name: "Cancel B", group: nil),
        ]
        let fixture = try makeFixture(idolSearch: { _ in results })
        guard case .idolCards(let cards) = await fixture.executor.execute("addidol Cancel") else {
            return XCTFail("expected candidates")
        }
        let token = try XCTUnwrap(cards.first?.selectionToken)

        _ = await fixture.executor.execute("cancel all")
        let response = await fixture.executor.execute("selectidolcandidate \(token)")

        XCTAssertTrue(text(from: response).contains("no longer available"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)
    }

    func testEventURLRequiresNameAndDateThenSavesCompleteFields() async throws {
        let fixture = try makeFixture()
        let url = "https://example.com/weibo/123"
        for command in [
            "addevent \(url)",
            "addevent \(url) name=ChekiDemo",
            "addevent \(url) date=2026-07-11",
        ] {
            let response = await fixture.executor.execute(command)
            XCTAssertTrue(text(from: response).contains("requires an explicit name and date"), command)
            XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty, command)
            XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty, command)
        }

        let complete = await fixture.executor.execute(
            "addevent \(url) name=\"Cheki Demo\" date=2026-07-11"
        )
        guard case .confirmationText(_, let code) = complete else {
            return XCTFail("expected complete Event confirmation")
        }
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)
        _ = await fixture.executor.execute("confirm \(code)")
        let saved = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<Event>()).first)
        XCTAssertEqual(saved.name, "Cheki Demo")
        XCTAssertEqual(saved.weiboURL?.absoluteString, url)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.day, from: try XCTUnwrap(saved.date)), 11)
    }

    func testEventConfirmationRechecksDuplicateBeforeFinalInsert() async throws {
        let fixture = try makeFixture()
        let cases = [
            (
                command: "addevent Duplicate date=2026-07-12",
                expectedURL: nil as String?
            ),
            (
                command: "addevent https://example.com/weibo/duplicate name=URLDuplicate date=2026-07-13",
                expectedURL: "https://example.com/weibo/duplicate" as String?
            ),
        ]

        for testCase in cases {
            guard case .confirmationText(_, let firstCode) = await fixture.executor.execute(testCase.command),
                  case .confirmationText(_, let secondCode) = await fixture.executor.execute(testCase.command) else {
                return XCTFail("expected two independently prepared Event confirmations")
            }

            try requireSuccess(await fixture.executor.execute("confirm \(firstCode)"))
            let duplicateResponse = await fixture.executor.execute("confirm \(secondCode)")
            XCTAssertTrue(text(from: duplicateResponse).contains("same name, date, and url"))
            XCTAssertTrue(fixture.ledger.activeConfirmationCodes.contains(secondCode))
        }

        let events = try fixture.context.fetch(FetchDescriptor<Event>())
        XCTAssertEqual(events.count, cases.count)
        XCTAssertEqual(
            events.compactMap { $0.weiboURL?.absoluteString },
            cases.compactMap(\.expectedURL)
        )
    }

    func testExtractedEventCandidateFreezesSevenFieldsAndConfirmsAtomicallyWithNilDate() async throws {
        let fixture = try makeFixture()
        let fields = ChekinanaEventCandidateFields(
            name: "Seven Field Live",
            date: "",
            city: "上海",
            livehouse: "新歌空间中大二号馆",
            weiboURL: "https://weibo.com/123456/AbC123",
            ticketURL: "https://tickets.showstart.com/event/42",
            note: "用户修订备注"
        )

        let prepared = fixture.executor.prepareEventCandidate(fields)
        guard case .eventCard(let card) = prepared,
              let code = card.confirmationCode else {
            return XCTFail("expected structured Event confirmation card")
        }
        XCTAssertEqual(card.date, "")
        XCTAssertEqual(card.city, fields.city)
        XCTAssertEqual(card.livehouse, fields.livehouse)
        XCTAssertEqual(card.ticketURL, fields.ticketURL)
        XCTAssertEqual(card.note, "")
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)

        try requireSuccess(await fixture.executor.execute("confirm \(code)"))
        let saved = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<Event>()).first)
        XCTAssertEqual(saved.name, fields.name)
        XCTAssertNil(saved.date)
        XCTAssertEqual(saved.city, fields.city)
        XCTAssertEqual(saved.livehouse, fields.livehouse)
        XCTAssertEqual(saved.weiboURL?.absoluteString, fields.weiboURL)
        XCTAssertEqual(saved.ticketURL?.absoluteString, fields.ticketURL)
        XCTAssertEqual(saved.note, "")

        guard case .eventCards(let listed) = await fixture.executor.execute("listevent") else {
            return XCTFail("expected structured Event list")
        }
        XCTAssertEqual(listed.first?.city, fields.city)
        XCTAssertEqual(listed.first?.livehouse, fields.livehouse)
        XCTAssertEqual(listed.first?.ticketURL, fields.ticketURL)
    }

    func testTextEventCandidateWithoutWeiboURLConfirmsAndPersistsAllFields() async throws {
        let fixture = try makeFixture()
        let fields = ChekinanaEventCandidateFields(
            name: "Text Parsed Live",
            date: "2026-08-03",
            city: "上海",
            livehouse: "MAO Livehouse",
            weiboURL: "",
            ticketURL: "https://showstart.com/event/text-live",
            note: "Parsed from pasted text"
        )

        XCTAssertTrue(ChekinanaEventCandidateValidator.blockers(for: fields).isEmpty)
        guard case .eventCard(let card) = fixture.executor.prepareEventCandidate(fields),
              let code = card.confirmationCode else {
            return XCTFail("A valid Text candidate without a Weibo URL must be confirmable.")
        }
        XCTAssertEqual(card.weiboURL, "")
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)

        try requireSuccess(await fixture.executor.execute("confirm \(code)"))

        let saved = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<Event>()).first)
        XCTAssertEqual(saved.name, fields.name)
        XCTAssertEqual(saved.date, utcDate(2026, 8, 3))
        XCTAssertEqual(saved.city, fields.city)
        XCTAssertEqual(saved.livehouse, fields.livehouse)
        XCTAssertNil(saved.weiboURL)
        XCTAssertEqual(saved.ticketURL?.absoluteString, fields.ticketURL)
        XCTAssertEqual(saved.note, "")

        var invalid = fields
        invalid.weiboURL = "https://evil.example/status/1"
        XCTAssertTrue(
            ChekinanaEventCandidateValidator.blockers(for: invalid).contains(.invalidWeiboURL)
        )
        XCTAssertTrue(text(from: fixture.executor.prepareEventCandidate(invalid)).contains("not ready"))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<Event>()).count, 1)
    }

    func testEditEventPreservesExtractedFieldsItDoesNotEdit() async throws {
        let fixture = try makeFixture()
        let event = Event(
            name: "Before",
            date: nil,
            city: "上海",
            livehouse: "新歌空间中大二号馆",
            weiboURL: URL(string: "https://weibo.com/123/AbC"),
            ticketURL: URL(string: "https://showstart.com/event/1"),
            note: "keep"
        )
        fixture.context.insert(event)
        try fixture.context.save()

        let prepared = await fixture.executor.execute("editevent \(shortID(event.id)) name=After")
        guard case .confirmationText(_, let code) = prepared else {
            return XCTFail("expected edit confirmation")
        }
        try requireSuccess(await fixture.executor.execute("confirm \(code)"))
        XCTAssertEqual(event.name, "After")
        XCTAssertEqual(event.city, "上海")
        XCTAssertEqual(event.livehouse, "新歌空间中大二号馆")
        XCTAssertEqual(event.ticketURL?.absoluteString, "https://showstart.com/event/1")
        XCTAssertEqual(event.note, "keep")
    }

    func testEventCandidateBlockersAndCancellationCreateNoWrites() async throws {
        let fixture = try makeFixture()
        let base = ChekinanaEventCandidateFields(
            name: "Blocked",
            date: "2026-08-02",
            city: "北京",
            livehouse: "北京市朝阳区幸福路100号",
            weiboURL: "https://weibo.com/123/AbC",
            ticketURL: "https://evil.example/ticket",
            note: ""
        )
        let blocked = fixture.executor.prepareEventCandidate(base)
        XCTAssertTrue(text(from: blocked).contains("not ready"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)

        var valid = base
        valid.livehouse = "幸福Livehouse朝阳店"
        valid.ticketURL = ""
        guard case .eventCard(let card) = fixture.executor.prepareEventCandidate(valid),
              let code = card.confirmationCode else {
            return XCTFail("expected corrected Event candidate")
        }
        _ = await fixture.executor.execute("cancel \(code)")
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)
    }

    func testEventCandidateStrictEnvelopeInputAndGenerationGate() throws {
        let success = Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Live","date":"","city":"","livehouse":"中大二号馆","address":"","price":"88","avatar_url":"https://wx1.sinaimg.cn/avatar.jpg","imageUrls":["https://wx1.sinaimg.cn/large/first.jpg","https://wx2.sinaimg.cn/large/second.jpg"],"weiboURL":"https://weibo.com/123/AbC","ticketURL":""}}"#.utf8)
        let fields = try ChekinanaEventCandidateClient.decodeSuccess(success)
        XCTAssertEqual(fields.name, "Live")
        XCTAssertEqual(fields.price, "88")
        XCTAssertEqual(fields.imageUrls, [
            "https://wx1.sinaimg.cn/large/first.jpg",
            "https://wx2.sinaimg.cn/large/second.jpg",
        ])
        XCTAssertTrue(ChekinanaEventCandidateValidator.blockers(for: fields).isEmpty)
        XCTAssertNotNil(ChekinanaEventWeiboInput.extractedURL(from: fields.weiboURL))
        XCTAssertEqual(
            ChekinanaEventWeiboInput.extractedURL(from: "创建 Event \(fields.weiboURL)"),
            fields.weiboURL
        )
        XCTAssertEqual(
            ChekinanaEventWeiboInput.extractedURL(from: "addevent \(fields.weiboURL)"),
            fields.weiboURL
        )

        let extra = Data(#"{"version":1,"kind":"candidate","extra":true,"candidate":{"name":"Live","date":"","city":"","livehouse":"","weiboURL":"https://weibo.com/123/AbC","ticketURL":"","note":""}}"#.utf8)
        XCTAssertThrowsError(try ChekinanaEventCandidateClient.decodeSuccess(extra))
        XCTAssertEqual(
            ChekinanaEventCandidateClient.decodeReject(Data(#"{"version":1,"kind":"reject","code":"invalid_weibo_url"}"#.utf8)),
            .rejected("invalid_weibo_url")
        )

        var state = ChekinanaEventCandidateStateMachine()
        let staleGeneration = state.begin(url: fields.weiboURL)
        state.invalidate()
        XCTAssertFalse(state.complete(fields, generation: staleGeneration))
        XCTAssertEqual(state.phase, .idle)
        let currentGeneration = state.begin(url: fields.weiboURL)
        XCTAssertTrue(state.complete(fields, generation: currentGeneration))
        XCTAssertEqual(state.phase, .editing(fields))
        XCTAssertFalse(state.accepts(currentGeneration, isCancelled: false))

        var busyOwner = ChekinanaEventCandidateBusyOwner()
        XCTAssertTrue(busyOwner.acquire(generation: currentGeneration))
        XCTAssertFalse(busyOwner.acquire(generation: currentGeneration &+ 1))
        XCTAssertTrue(busyOwner.owns(generation: currentGeneration, isCancelled: false))
        XCTAssertFalse(busyOwner.release(generation: currentGeneration &+ 1))
        XCTAssertTrue(busyOwner.release(generation: currentGeneration))
        XCTAssertNil(busyOwner.generation)

        var extractionGate = ChekinanaEventCandidateExtractionGate()
        let firstExtraction = extractionGate.begin()
        let replacementExtraction = extractionGate.begin()
        XCTAssertFalse(extractionGate.accepts(firstExtraction, isCancelled: false))
        XCTAssertTrue(extractionGate.accepts(replacementExtraction, isCancelled: false))
        XCTAssertFalse(extractionGate.accepts(replacementExtraction, isCancelled: true))
        extractionGate.invalidate()
        XCTAssertFalse(extractionGate.accepts(replacementExtraction, isCancelled: false))

        let legacy = Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Legacy","date":"","city":"","livehouse":"","weiboURL":"https://weibo.com/123/AbC","ticketURL":"","note":"model text must be dropped"}}"#.utf8)
        XCTAssertEqual(try ChekinanaEventCandidateClient.decodeSuccess(legacy).note, "")
    }

    func testEventCandidateWeiboURLShapeMatchesWorkerContract() throws {
        let accepted = [
            "https://weibo.com/123456/AbC123",
            "https://www.weibo.com/user_name/Z9",
            "https://weibo.com/%E5%81%B6%E5%83%8F/%41bC123",
            "https://weibo.com/\(String(repeating: "u", count: 200))/AbC123",
        ]
        let rejected = [
            "http://weibo.com/123456/AbC123",
            "https://user@weibo.com/123456/AbC123",
            "https://weibo.com:443/123456/AbC123",
            "https://weibo.com/123456/AbC123?source=app",
            "https://weibo.com/123456/AbC123#detail",
            "https://weibo.com/123456/AbC123/",
            "https://weibo.com//123456/AbC123",
            "https://weibo.com/123456/extra/AbC123",
            "https://weibo.com/123456/AbC-123",
            "https://weibo.com/foo%2Fbar/AbC123",
            "https://weibo.com/foo%3Fbar/AbC123",
            "https://weibo.com/foo%23bar/AbC123",
            "https://weibo.com/foo%00bar/AbC123",
            "https://weibo.com/foo%7Fbar/AbC123",
            "https://weibo.com/./AbC123",
            "https://weibo.com/../AbC123",
            "https://weibo.com/%2e%2e/AbC123",
            "https://weibo.com/foo\\bar/AbC123",
            "https://weibo.com/foo%5Cbar/AbC123",
            "https://weibo.com/foo%ZZ/AbC123",
            "https://weibo.com/foo%FF/AbC123",
            "https://weibo.com/123456/AbC%2F123",
            "https://weibo.com/\(String(repeating: "u", count: 201))/AbC123",
            "https://m.weibo.com/123456/AbC123",
        ]
        accepted.forEach {
            XCTAssertTrue(ChekinanaEventCandidateValidator.isPublicWeiboStatusURL($0), $0)
        }
        rejected.forEach {
            XCTAssertFalse(ChekinanaEventCandidateValidator.isPublicWeiboStatusURL($0), $0)
        }

        let fixture = try makeFixture()
        var fields = ChekinanaEventCandidateFields(
            name: "Strict URL",
            date: "",
            city: "",
            livehouse: "Fixture Livehouse 中大二号馆",
            weiboURL: accepted[0],
            ticketURL: "",
            note: ""
        )
        fields.weiboURL = rejected[3]
        XCTAssertTrue(text(from: fixture.executor.prepareEventCandidate(fields)).contains("not ready"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)
    }

    func testEventCandidateConservativeLivehouseAddressBlocker() {
        let blocked = [
            "北京市朝阳区幸福路一百号",
            "北京市朝阳区幸福路东段",
            "幸福路东段",
            "上海市幸福路100号",
            "北京市朝阳区幸福路",
            "朝阳区幸福街",
        ]
        let allowed = [
            "Fixture Livehouse 中大二号馆",
            "幸福Livehouse朝阳店",
            "新歌空间中大二号馆",
            "MAO Livehouse 五棵松店",
        ]
        blocked.forEach {
            XCTAssertTrue(ChekinanaEventCandidateValidator.livehouseLooksLikeDetailedAddress($0), $0)
        }
        allowed.forEach {
            XCTAssertFalse(ChekinanaEventCandidateValidator.livehouseLooksLikeDetailedAddress($0), $0)
        }
    }

    func testEventCandidateClientPostsExactRequestAndDecodesSevenStrings() async throws {
        let url = "https://weibo.com/123/AbC"
        let endpoint = try XCTUnwrap(
            URL(string: "https://windows.test:8787/api/event/weibo-candidate")
        )
        let builtRequest = try ChekinanaEventCandidateClient.makeRequest(
            endpointURL: endpoint,
            weiboURL: url
        )
        XCTAssertEqual(builtRequest.url, endpoint)
        XCTAssertEqual(builtRequest.httpMethod, "POST")
        XCTAssertEqual(builtRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(builtRequest.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(builtRequest.timeoutInterval, 45)
        XCTAssertEqual(builtRequest.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        let body = try XCTUnwrap(builtRequest.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "weiboURL"]))
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["weiboURL"] as? String, url)

        ChekinanaEventCandidateMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://windows.test:8787/api/event/weibo-candidate")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Live","date":"2026-08-02","city":"合肥","livehouse":"791Crow","address":"","price":"","avatar_url":"","weiboURL":"https://weibo.com/123/AbC","ticketURL":""}}"#.utf8)
        }
        defer { ChekinanaEventCandidateMockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaEventCandidateMockURLProtocol.self]
        let client = ChekinanaEventCandidateClient(
            baseURL: try XCTUnwrap(URL(string: "https://windows.test:8787")),
            session: URLSession(configuration: configuration)
        )

        let fields = try await client.fetch(weiboURL: url)
        XCTAssertEqual(fields.name, "Live")
        XCTAssertEqual(fields.city, "合肥")
    }

    func testEventCandidateClientDefaultAlwaysUsesProductionEndpoint() async throws {
        let weiboURL = "https://weibo.com/123/AbC"
        let expectedEndpoint = ChekinanaScannerConfiguration.productionBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("event")
            .appendingPathComponent("weibo-candidate")
        ChekinanaEventCandidateMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url, expectedEndpoint)
            return Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Production Route","date":"","city":"","livehouse":"","address":"","price":"","avatar_url":"","weiboURL":"https://weibo.com/123/AbC","ticketURL":""}}"#.utf8)
        }
        defer { ChekinanaEventCandidateMockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaEventCandidateMockURLProtocol.self]

        let candidate = try await ChekinanaEventCandidateClient(
            session: URLSession(configuration: configuration)
        ).fetch(weiboURL: weiboURL)

        XCTAssertEqual(candidate.name, "Production Route")
    }

    func testCatalogueAvatarLocalizerRequiresExactIdentityAndWritesManagedLocalImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-avatar-localizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = ChekinanaEnrichedIdol(
            sourceId: "catalogue-id-1",
            idolName: "Fixture Idol",
            groupName: nil,
            color: nil,
            birthday: nil,
            verification: nil,
            bio: nil,
            avatarUrl: "https://catalogue.test/avatar.jpg"
        )
        let expectedIdentity = try XCTUnwrap(ChekinanaIdolAvatarIdentity.make(
            sourceID: candidate.sourceId,
            avatarURL: candidate.avatarUrl
        ))
        let idolID = UUID()

        do {
            _ = try await ChekinanaCatalogueIdolAvatarLocalizer.stage(
                .init(
                    candidate: candidate,
                    avatarThumbnailData: scannerPNGData(color: .purple),
                    avatarIdentity: "wrong|https://catalogue.test/avatar.jpg"
                ),
                idolID: idolID,
                directory: directory
            )
            XCTFail("A mismatched catalogue/avatar identity must not be persisted.")
        } catch {
            guard let localizerError = error as? ChekinanaCatalogueIdolAvatarLocalizerError,
                  case .identityMismatch = localizerError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        do {
            _ = try await ChekinanaCatalogueIdolAvatarLocalizer.stage(
                .init(
                    candidate: candidate,
                    avatarThumbnailData: nil,
                    avatarIdentity: expectedIdentity
                ),
                idolID: idolID,
                directory: directory
            )
            XCTFail("Missing avatar bytes must prevent insertion.")
        } catch {
            guard let localizerError = error as? ChekinanaCatalogueIdolAvatarLocalizerError,
                  case .missingAvatar = localizerError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        let stored = try await ChekinanaCatalogueIdolAvatarLocalizer.stage(
            .init(
                candidate: candidate,
                avatarThumbnailData: scannerPNGData(color: .purple),
                avatarIdentity: expectedIdentity
            ),
            idolID: idolID,
            directory: directory
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.url.path))
        XCTAssertEqual(
            try ChekinanaIdolReferenceStore.managedAvatarURL(
                for: stored.ref,
                idolID: idolID,
                directory: directory
            ),
            stored.url
        )
        XCTAssertNotNil(UIImage(data: try Data(contentsOf: stored.url)))
    }

    @MainActor
    func testMissingManagedAvatarRepairUsesExactSourceAndPersistsOnlyThatIdolsFile() async throws {
        let fixture = try makeFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-avatar-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let idol = Idol(
            sourceId: "catalogue-id-exact",
            name: "Exact Idol",
            avatarImageRef: nil
        )
        fixture.context.insert(idol)
        try fixture.context.save()
        let candidate = ChekinanaEnrichedIdol(
            sourceId: "catalogue-id-exact",
            idolName: "Exact Idol",
            groupName: nil,
            color: nil,
            birthday: nil,
            verification: nil,
            bio: nil,
            avatarUrl: "https://catalogue.test/exact.jpg"
        )
        let identity = try XCTUnwrap(ChekinanaIdolAvatarIdentity.make(
            sourceID: candidate.sourceId,
            avatarURL: candidate.avatarUrl
        ))
        var requestedSourceID: String?
        var requestedQuery: String?

        let repaired = try await ChekinanaIdolAvatarRepairCoordinator.repairIfNeeded(
            idol,
            in: fixture.context,
            directory: directory,
            prepareExact: { sourceID, query in
                requestedSourceID = sourceID
                requestedQuery = query
                return ChekinanaPreparedIdolCandidate(
                    candidate: candidate,
                    avatarThumbnailData: self.scannerPNGData(color: .purple),
                    avatarIdentity: identity
                )
            }
        )

        XCTAssertTrue(repaired)
        XCTAssertEqual(requestedSourceID, candidate.sourceId)
        XCTAssertEqual(requestedQuery, idol.name)
        let imageRef = try XCTUnwrap(idol.avatarImageRef)
        XCTAssertTrue(imageRef.hasPrefix("idol-avatar-\(idol.id.uuidString.lowercased())-"))
        let validatedAvatar = await ChekinanaIdolReferenceStore.validatedManagedAvatar(
            imageRef: imageRef,
            idolID: idol.id,
            directory: directory
        )
        XCTAssertNotNil(validatedAvatar)
        let secondRepair = try await ChekinanaIdolAvatarRepairCoordinator.repairIfNeeded(
            idol,
            in: fixture.context,
            directory: directory,
            prepareExact: { _, _ in
                XCTFail("A verified local avatar must not trigger another catalogue request.")
                return ChekinanaPreparedIdolCandidate(
                    candidate: candidate,
                    avatarThumbnailData: nil,
                    avatarIdentity: nil
                )
            }
        )
        XCTAssertFalse(secondRepair)
    }

    @MainActor
    func testMissingAvatarRepairIsSingleFlightAndLeavesOneManagedFile() async throws {
        let fixture = try makeFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-avatar-single-flight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let idol = Idol(sourceId: "catalogue-single-flight", name: "One Idol")
        fixture.context.insert(idol)
        try fixture.context.save()
        let candidate = ChekinanaEnrichedIdol(
            sourceId: "catalogue-single-flight",
            idolName: "One Idol",
            groupName: nil,
            color: nil,
            birthday: nil,
            verification: nil,
            bio: nil,
            avatarUrl: "https://catalogue.test/one.jpg"
        )
        let identity = try XCTUnwrap(ChekinanaIdolAvatarIdentity.make(
            sourceID: candidate.sourceId,
            avatarURL: candidate.avatarUrl
        ))
        let prepareCount = ChekinanaAtomicCounter()
        let prepare: ChekinanaIdolAvatarRepairCoordinator.PrepareExact = { _, _ in
            prepareCount.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return ChekinanaPreparedIdolCandidate(
                candidate: candidate,
                avatarThumbnailData: self.scannerPNGData(color: .purple),
                avatarIdentity: identity
            )
        }

        let first = Task { @MainActor in
            try await ChekinanaIdolAvatarRepairCoordinator.repairIfNeeded(
                idol,
                in: fixture.context,
                directory: directory,
                prepareExact: prepare
            )
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await ChekinanaIdolAvatarRepairCoordinator.repairIfNeeded(
                idol,
                in: fixture.context,
                directory: directory,
                prepareExact: prepare
            )
        }
        _ = try await (first.value, second.value)

        XCTAssertEqual(prepareCount.value(), 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count,
            1
        )
        let validatedAvatar = await ChekinanaIdolReferenceStore.validatedManagedAvatar(
            imageRef: idol.avatarImageRef,
            idolID: idol.id,
            directory: directory
        )
        XCTAssertNotNil(validatedAvatar)
    }

    @MainActor
    func testMissingAvatarRepairStopsWhenIdolIsDeletedDuringPrepare() async throws {
        let fixture = try makeFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-avatar-deleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let idol = Idol(sourceId: "catalogue-deleted", name: "Deleted Idol")
        fixture.context.insert(idol)
        try fixture.context.save()
        let candidate = ChekinanaEnrichedIdol(
            sourceId: "catalogue-deleted",
            idolName: "Deleted Idol",
            groupName: nil,
            color: nil,
            birthday: nil,
            verification: nil,
            bio: nil,
            avatarUrl: "https://catalogue.test/deleted.jpg"
        )
        let identity = try XCTUnwrap(ChekinanaIdolAvatarIdentity.make(
            sourceID: candidate.sourceId,
            avatarURL: candidate.avatarUrl
        ))
        let prepareStarted = ChekinanaAtomicCounter()
        let stageCount = ChekinanaAtomicCounter()
        let releasePrepare = ScannerReleaseGate()

        let repair = Task { @MainActor in
            try await ChekinanaIdolAvatarRepairCoordinator.repairIfNeeded(
                idol,
                in: fixture.context,
                directory: directory,
                prepareExact: { _, _ in
                    prepareStarted.increment()
                    await releasePrepare.wait()
                    return ChekinanaPreparedIdolCandidate(
                        candidate: candidate,
                        avatarThumbnailData: self.scannerPNGData(color: .purple),
                        avatarIdentity: identity
                    )
                },
                stage: { prepared, idolID, directory in
                    stageCount.increment()
                    return try await ChekinanaCatalogueIdolAvatarLocalizer.stage(
                        prepared,
                        idolID: idolID,
                        directory: directory
                    )
                }
            )
        }
        for _ in 0..<200 where prepareStarted.value() == 0 {
            await Task.yield()
        }
        XCTAssertEqual(prepareStarted.value(), 1)
        fixture.context.delete(idol)
        await releasePrepare.release()

        do {
            _ = try await repair.value
            XCTFail("A deleted Idol must not be staged or saved by an in-flight repair.")
        } catch {
            XCTAssertEqual(stageCount.value(), 0)
        }
        XCTAssertEqual(stageCount.value(), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCatalogueResultAvatarAcceptsOnlyItsVerifiedPreparedThumbnail() async throws {
        let first = ChekinanaEnrichedIdol(
            sourceId: "catalogue-first",
            idolName: "First",
            groupName: nil,
            color: nil,
            birthday: nil,
            verification: nil,
            bio: nil,
            avatarUrl: "https://catalogue.test/first.jpg"
        )
        let second = ChekinanaEnrichedIdol(
            sourceId: "catalogue-second",
            idolName: "Second",
            groupName: nil,
            color: nil,
            birthday: nil,
            verification: nil,
            bio: nil,
            avatarUrl: "https://catalogue.test/second.jpg"
        )
        let changedAvatarForFirst = ChekinanaEnrichedIdol(
            sourceId: first.sourceId,
            idolName: first.idolName,
            groupName: nil,
            color: nil,
            birthday: nil,
            verification: nil,
            bio: nil,
            avatarUrl: "https://catalogue.test/first-new.jpg"
        )
        let renderedImage = await ChekinanaImageWorker.thumbnailImage(
            from: scannerPNGData(color: .purple),
            maxDimension: 256
        )
        let image = try XCTUnwrap(renderedImage)
        let prepared = ChekinanaPreparedIdolCandidate(
            candidate: first,
            avatarThumbnailData: scannerPNGData(color: .purple),
            avatarIdentity: ChekinanaIdolAvatarIdentity.make(
                sourceID: first.sourceId,
                avatarURL: first.avatarUrl
            ),
            avatarThumbnailImage: image
        )

        XCTAssertNotNil(ChekinanaCatalogueIdolCardAvatarPresentation.preparedImage(
            from: prepared,
            for: first
        ))
        XCTAssertNil(ChekinanaCatalogueIdolCardAvatarPresentation.preparedImage(
            from: prepared,
            for: second
        ))
        let oldIdentity = ChekinanaCatalogueIdolCardAvatarPresentation.identity(for: first)
        XCTAssertNotEqual(
            oldIdentity,
            ChekinanaCatalogueIdolCardAvatarPresentation.identity(for: changedAvatarForFirst)
        )
        XCTAssertNil(ChekinanaCatalogueIdolCardAvatarPresentation.preparedImage(
            from: prepared,
            for: changedAvatarForFirst,
            taskIdentity: oldIdentity
        ))
    }

    func testEventCandidateClientPostsExactTextRequestAndAcceptsEmptyResponseWeiboURL() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://windows.test:8787/api/event/weibo-candidate")
        )
        let text = "演出名称：Text Live\n日期：2026-08-03\n地点：上海"
        let builtRequest = try ChekinanaEventCandidateClient.makeTextRequest(
            endpointURL: endpoint,
            text: text
        )
        XCTAssertEqual(builtRequest.url, endpoint)
        XCTAssertEqual(builtRequest.httpMethod, "POST")
        XCTAssertEqual(builtRequest.timeoutInterval, 45)
        let body = try XCTUnwrap(builtRequest.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "text"]))
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["text"] as? String, text)

        ChekinanaEventCandidateMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url, endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Text Live","date":"2026-08-03","city":"上海","livehouse":"MAO Livehouse","address":"","price":"","avatar_url":"","weiboURL":"","ticketURL":""}}"#.utf8)
        }
        defer { ChekinanaEventCandidateMockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaEventCandidateMockURLProtocol.self]
        let client = ChekinanaEventCandidateClient(
            endpointURL: endpoint,
            session: URLSession(configuration: configuration)
        )

        let fields = try await client.parse(text: text)
        XCTAssertEqual(fields.name, "Text Live")
        XCTAssertEqual(fields.weiboURL, "")
        XCTAssertFalse(
            ChekinanaEventCandidateValidator.blockers(for: fields).contains(.invalidWeiboURL),
            "Text candidates may omit a Weibo URL; a nonempty URL remains strictly validated."
        )
    }

    func testEventCandidateClientRejectsNonemptyResponseWeiboURLForTextInput() async throws {
        let endpoint = try XCTUnwrap(
            URL(string: "https://windows.test:8787/api/event/weibo-candidate")
        )
        ChekinanaEventCandidateMockURLProtocol.handler = { _ in
            Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Text Live","date":"","city":"","livehouse":"","weiboURL":"https://weibo.com/123/AbC","ticketURL":"","note":""}}"#.utf8)
        }
        defer { ChekinanaEventCandidateMockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaEventCandidateMockURLProtocol.self]
        let client = ChekinanaEventCandidateClient(
            endpointURL: endpoint,
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.parse(text: "Event text")
            XCTFail("Text input must reject a response that invents a Weibo URL")
        } catch {
            XCTAssertEqual(error as? ChekinanaEventCandidateClientError, .invalidResponse)
        }
    }

    func testEventCandidateTextValidationRejectsBlankControlAndOversizedInput() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.test/api/event/weibo-candidate"))
        XCTAssertThrowsError(try ChekinanaEventCandidateClient.makeTextRequest(
            endpointURL: endpoint,
            text: " \n\t "
        )) { XCTAssertEqual($0 as? ChekinanaEventCandidateClientError, .emptyText) }
        XCTAssertThrowsError(try ChekinanaEventCandidateClient.makeTextRequest(
            endpointURL: endpoint,
            text: "Live\u{0000}Event"
        )) { XCTAssertEqual($0 as? ChekinanaEventCandidateClientError, .invalidTextCharacters) }
        XCTAssertThrowsError(try ChekinanaEventCandidateClient.makeTextRequest(
            endpointURL: endpoint,
            text: String(repeating: "a", count: ChekinanaEventCandidateClient.maximumTextBytes + 1)
        )) { XCTAssertEqual($0 as? ChekinanaEventCandidateClientError, .textTooLarge) }
        XCTAssertNoThrow(try ChekinanaEventCandidateClient.makeTextRequest(
            endpointURL: endpoint,
            text: "第一行\n第二行\t信息"
        ))

        XCTAssertThrowsError(try ChekinanaEventCandidateClient.makeTextRequest(
            endpointURL: endpoint,
            text: String(repeating: "a", count: ChekinanaEventCandidateClient.maximumTextBytes)
        )) { XCTAssertEqual($0 as? ChekinanaEventCandidateClientError, .textTooLarge) }

        var lowerBound = 1
        var upperBound = ChekinanaEventCandidateClient.maximumTextBytes
        while lowerBound < upperBound {
            let candidate = (lowerBound + upperBound + 1) / 2
            if (try? ChekinanaEventCandidateClient.makeTextRequest(
                endpointURL: endpoint,
                text: String(repeating: "a", count: candidate)
            )) != nil {
                lowerBound = candidate
            } else {
                upperBound = candidate - 1
            }
        }
        let boundaryRequest = try ChekinanaEventCandidateClient.makeTextRequest(
            endpointURL: endpoint,
            text: String(repeating: "a", count: lowerBound)
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(boundaryRequest.httpBody).count,
            ChekinanaEventCandidateClient.maximumRequestBytes
        )
        XCTAssertThrowsError(try ChekinanaEventCandidateClient.makeTextRequest(
            endpointURL: endpoint,
            text: String(repeating: "a", count: lowerBound + 1)
        )) { XCTAssertEqual($0 as? ChekinanaEventCandidateClientError, .textTooLarge) }
    }

    func testEventCandidateClientMapsTransportAndServiceTimeoutsClearly() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.test/api/event/weibo-candidate"))
        ChekinanaEventCandidateMockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        defer { ChekinanaEventCandidateMockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaEventCandidateMockURLProtocol.self]
        let client = ChekinanaEventCandidateClient(
            endpointURL: endpoint,
            session: URLSession(configuration: configuration)
        )
        do {
            _ = try await client.parse(text: "Event text")
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? ChekinanaEventCandidateClientError, .timedOut)
        }

        ChekinanaEventCandidateMockURLProtocol.handler = { _ in
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        }
        do {
            _ = try await client.parse(text: "Cancelled Event text")
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Cancellation must not become networkUnavailable")
        }

        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("weibo_upstream_timeout")
                .localizedDescription.contains("微博正文超时")
        )
        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("upstream_timeout")
                .localizedDescription.contains("Weibo 状态超时")
        )
        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("weibo_upstream_unavailable")
                .localizedDescription.contains("暂时无法读取这条微博正文")
        )
        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("status_unavailable")
                .localizedDescription.contains("无法读取这条公开 Weibo 状态")
        )
        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("model_timeout")
                .localizedDescription.contains("模型解析 Event 信息超时")
        )
        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("service_unavailable")
                .localizedDescription.contains("Event 提取服务暂时不可用")
        )
        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("model_unavailable")
                .localizedDescription.contains("Event 解析模型暂时不可用")
        )
        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("invalid_model_output")
                .localizedDescription.contains("未能从正文安全解析出 Event 信息")
        )
        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("model_rejected")
                .localizedDescription.contains("模型未能解析")
        )
        XCTAssertTrue(
            ChekinanaEventCandidateClientError.rejected("rate_limited")
                .localizedDescription.contains("请求过于频繁")
        )
    }

    private func dateAnnotation(
        text: String,
        precision: ChekinanaChekiDateAnnotation.Precision
    ) throws -> ChekinanaChekiDateAnnotationState {
        let box = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 100,
            y1: 700,
            x2: 900,
            y2: 900
        ))
        return .detected(try XCTUnwrap(ChekinanaChekiDateAnnotation(
            text: text,
            precision: precision,
            boundingBox: box
        )))
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day
        ))!
    }

    private func makeTemporaryAvatarDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-idol-avatar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func temporaryDownloadFile(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-download-test-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func waitForLimiter(
        _ limiter: ChekinanaRemoteRequestLimiter,
        active: Int,
        waiting: Int
    ) async -> Bool {
        for _ in 0..<200 {
            if await limiter.snapshot() == .init(
                activeCount: active,
                waitingCount: waiting
            ) {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func waitForBodyPoseLimiter(
        _ limiter: ChekinanaBodyPoseLimiter,
        active: Int,
        waiting: Int
    ) async -> Bool {
        for _ in 0..<200 {
            if await limiter.snapshot() == .init(
                activeCount: active,
                waitingCount: waiting
            ) {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func waitForExistingTargetReservation(
        _ ledger: ChekinanaConfirmationLedger,
        targetID: UUID
    ) async -> Bool {
        for _ in 0..<200 {
            if ledger.isTemporaryExistingChekiTargetReserved(targetID) {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func localizedAppBundle(language: String) throws -> Bundle {
        let candidates = [Bundle.main, Bundle(for: Self.self)]
            + Bundle.allBundles
            + Bundle.allFrameworks
        for candidate in candidates {
            guard let path = candidate.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            return bundle
        }
        throw XCTSkip("The built app does not contain the \(language) localization bundle.")
    }

    private func makeFixture(
        scannerProcess: ChekinanaCommandExecutor.ScannerProcess? = nil,
        patternEncode: ChekinanaCommandExecutor.PatternEncode? = nil,
        userAppearsDetect: @escaping ChekinanaCommandExecutor.UserAppearsDetect = { _ in false },
        idolSearch: ChekinanaCommandExecutor.IdolSearch? = nil,
        idolAvatarPrepare: ChekinanaCommandExecutor.IdolAvatarPrepare? = nil,
        idolAvatarBatchTimeoutNanoseconds: UInt64 = 15_000_000_000,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        scanProgressObserver: ChekinanaCommandExecutor.ScanProgressObserver? = nil,
        batchImagePreparationLimiter: ChekinanaRemoteRequestLimiter = .init(limit: 4),
        batchSaveProgressObserver: ChekinanaCommandExecutor.BatchSaveProgressObserver? = nil,
        simulateBatchFinalizeInvariantFailure: Bool = false,
        batchBeforeLiveIndexValidation: ChekinanaCommandExecutor.BatchBeforeLiveIndexValidation? = nil
    ) throws -> Fixture {
        let schema = Schema([Idol.self, Event.self, EventImage.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let ledger = ChekinanaConfirmationLedger()
        let resolvedIdolSearch: ChekinanaCommandExecutor.IdolSearch = idolSearch ?? { name in
            try await ChekinanaIdolEnrichmentClient().search(for: name)
        }
        let executor = ChekinanaCommandExecutor(
            modelContext: context,
            confirmationLedger: ledger,
            scannerProcess: scannerProcess,
            patternEncode: patternEncode,
            userAppearsDetect: userAppearsDetect,
            idolSearch: resolvedIdolSearch,
            idolAvatarPrepare: idolAvatarPrepare,
            idolAvatarBatchTimeoutNanoseconds: idolAvatarBatchTimeoutNanoseconds,
            now: now,
            calendar: calendar,
            scanProgressObserver: scanProgressObserver,
            batchImagePreparationLimiter: batchImagePreparationLimiter,
            batchSaveProgressObserver: batchSaveProgressObserver,
            simulateBatchFinalizeInvariantFailure: simulateBatchFinalizeInvariantFailure,
            batchBeforeLiveIndexValidation: batchBeforeLiveIndexValidation
        )
        return Fixture(context: context, ledger: ledger, executor: executor)
    }

    private func attachConfirmation(
        in fixture: Fixture,
        target: Cheki,
        date: Date,
        imageData: Data,
        payloadUserAppears: Bool? = nil,
        explicitlyEditedFields: Set<ChekinanaConfirmationLedger.TemporaryChekiField> = []
    ) throws -> String {
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [ChekinanaPendingChekiImage(
                data: imageData,
                filenameExtension: "png",
                sourceID: UUID(),
                sourceOrigin: .unspecified
            )],
            thumbnailImageData: [nil],
            dates: [date]
        ).inserted[0]
        let payload = ChekinanaConfirmationLedger.AddChekiPayload(
            id: target.id,
            temporaryChekiID: temporary.id,
            image: temporary.image,
            thumbnailImageData: temporary.thumbnailImageData,
            idolIDs: target.idols.map(\.id),
            eventID: target.event?.id,
            date: date,
            userAppears: payloadUserAppears ?? target.userAppears,
            size: target.size,
            isFavorite: target.isFavorite,
            hasPostedToSNS: target.hasPostedToSNS,
            note: target.note,
            createdAt: temporary.createdAt,
            requestedIdx: target.idx,
            existingChekiID: target.id,
            explicitlyEditedFields: explicitlyEditedFields
        )
        return fixture.ledger.insert(.addCheki(payload))
    }

    private func prepareSingleAttachConfirmation(
        in fixture: Fixture,
        target: Cheki,
        imageData: Data,
        detectedUserAppears: Bool,
        inheritsExistingUserAppears: Bool = true,
        togglesUserAppears: Bool = false
    ) async throws -> (code: String, temporaryID: UUID) {
        let date = try XCTUnwrap(target.date)
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [ChekinanaPendingChekiImage(
                data: imageData,
                filenameExtension: "png"
            )],
            thumbnailImageData: [nil],
            scannerMetadata: [.init(
                matchedIdolID: nil,
                userAppears: detectedUserAppears
            )],
            dates: [date]
        ).inserted[0]
        XCTAssertTrue(fixture.ledger.setTemporaryExistingCheki(
            id: temporary.id,
            existingChekiID: target.id,
            selectionIsManual: true,
            inheritedIdx: target.idx,
            inheritedUserAppears: inheritsExistingUserAppears
                ? target.userAppears : nil
        ))
        if togglesUserAppears {
            XCTAssertNotNil(fixture.ledger.toggleTemporaryChekiUserAppears(
                id: temporary.id
            ))
        }
        let prepared = await fixture.executor.execute(
            "addscancheki \(temporary.id.uuidString.lowercased())"
        )
        guard case .pendingChekiCards(_, let cards, _) = prepared,
              cards.count == 1,
              cards[0].id == target.id,
              let code = cards[0].confirmationCode else {
            throw ScannerMockError.failed
        }
        return (code, temporary.id)
    }

    private func managedChekiFilenames() throws -> Set<String> {
        let directory = try ChekiImageRefResolver.chekiImagesDirectory()
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private func newChekiConfirmation(
        in fixture: Fixture,
        idolIDs: [UUID],
        date: Date,
        requestedIdx: Int?,
        idxIsExplicit: Bool
    ) throws -> (code: String, id: UUID) {
        let image = ChekinanaPendingChekiImage(
            data: scannerPNGData(color: .cyan),
            filenameExtension: "png",
            sourceID: UUID(),
            sourceOrigin: .unspecified
        )
        let temporary = try fixture.ledger.insertTemporaryChekis(
            [image],
            thumbnailImageData: [nil],
            dates: [date]
        ).inserted[0]
        let id = UUID()
        let payload = ChekinanaConfirmationLedger.AddChekiPayload(
            id: id,
            temporaryChekiID: temporary.id,
            image: temporary.image,
            thumbnailImageData: temporary.thumbnailImageData,
            idolIDs: idolIDs,
            eventID: nil,
            date: date,
            userAppears: nil,
            size: .mini,
            isFavorite: false,
            hasPostedToSNS: false,
            note: "",
            createdAt: temporary.createdAt,
            requestedIdx: requestedIdx,
            existingChekiID: nil,
            explicitlyEditedFields: idxIsExplicit ? [.idx] : []
        )
        return (fixture.ledger.insert(.addCheki(payload)), id)
    }

    private func enrichedIdol(
        sourceID: String,
        name: String,
        group: String?,
        avatarURL: String? = nil
    ) -> ChekinanaEnrichedIdol {
        ChekinanaEnrichedIdol(
            sourceId: sourceID,
            idolName: name,
            groupName: group,
            color: "#3366CC",
            birthday: "2000-01-01",
            verification: "verified",
            bio: "catalogue bio",
            avatarUrl: avatarURL
        )
    }

    private func prepareAlbumChekis(
        count: Int,
        idol: Idol,
        event: Event,
        fixture: Fixture
    ) throws -> [ChekinanaChekiCard] {
        let request = ChekinanaAlbumAddChekiRequest(arguments: [
            "idol": shortID(idol.id),
            "event": shortID(event.id),
        ])
        let prepared = (0..<count).map { index in
            ChekinanaPreparedAlbumCheki(
                request: request,
                image: testImage(UInt8(index + 1)),
                thumbnailImageData: nil
            )
        }
        let response = try fixture.executor.finalizeAlbumAddChekis(prepared, failedCount: 0)
        guard case .pendingChekiCards(_, let cards, _) = response else {
            XCTFail("expected pending Cheki cards")
            return []
        }
        return cards
    }

    private func requireSuccess(_ response: ChekinanaCommandResponse) throws {
        if case .text(let value) = response, value.hasPrefix("error:") {
            XCTFail(value)
            throw HarnessError.unexpectedResponse(value)
        }
    }

    private func text(from response: ChekinanaCommandResponse) -> String {
        guard case .text(let value) = response else { return "" }
        return value
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private func testImage(_ marker: UInt8) -> ChekinanaPendingChekiImage {
        ChekinanaPendingChekiImage(data: Data([marker]), filenameExtension: "png")
    }

    private func scannerOptions(
        dateRecognitionEnabled: Bool,
        dateBounds: ChekinanaScannerDateBounds? = nil,
        expectedPolaroids: Int? = nil,
        directInputEnabled: Bool = false,
        sleevesEnabled: Bool = false,
        postprocessMode: ChekinanaScannerPostprocessMode = .off
    ) -> ChekinanaScannerOptions {
        ChekinanaScannerOptions(
            expectedPolaroids: expectedPolaroids,
            scannerSize: .auto,
            postprocessMode: postprocessMode,
            whiteBalance: true,
            sleevesEnabled: sleevesEnabled,
            directInputEnabled: directInputEnabled,
            dateRecognitionEnabled: dateRecognitionEnabled,
            dateBounds: dateBounds
        )
    }

    private func scannerDateMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaScannerDateMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func runtimeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaRuntimeMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func scannerPNGData(color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2),
            format: format
        ).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func oversizedTIFFFixture(width: UInt32, height: UInt32) -> Data {
        func littleEndianBytes(_ value: UInt32) -> [UInt8] {
            [
                UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF),
            ]
        }
        var bytes: [UInt8] = [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]
        bytes += [0x02, 0x00]
        bytes += [0x00, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00]
        bytes += littleEndianBytes(width)
        bytes += [0x01, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00]
        bytes += littleEndianBytes(height)
        bytes += [0x00, 0x00, 0x00, 0x00]
        return Data(bytes)
    }

    private func scannerJPEGData(
        color: UIColor,
        size: CGSize = CGSize(width: 2, height: 2)
    ) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    private func scannerJPEGDataWithOrientation(
        _ orientation: Int,
        size: CGSize = CGSize(width: 40, height: 40)
    ) -> Data {
        let image = UIGraphicsImageRenderer(size: size).image {
            context in
            let halfWidth = size.width / 2
            let halfHeight = size.height / 2
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))
            UIColor.green.setFill()
            context.fill(CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight))
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(
            destination,
            image.cgImage!,
            [
                kCGImageDestinationLossyCompressionQuality: 1.0,
                kCGImagePropertyOrientation: orientation,
            ] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func scannerHEICDataWithOrientation(_ orientation: Int) -> Data? {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?
            .contains("public.heic") == true else { return nil }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 24)).image {
            context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 24))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 20, y: 0, width: 20, height: 24))
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.heic" as CFString,
            1,
            nil
        ), let cgImage = image.cgImage else { return nil }
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func quadrantColorLabels(_ data: Data) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let palette: [(r: Int, g: Int, b: Int)] = [
            (255, 0, 0),
            (0, 255, 0),
            (0, 0, 255),
            (255, 255, 0),
        ]
        func nearestColorIndex(at offset: Int) -> Int {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            var bestIndex = 0
            var bestDistance = Int.max
            for (index, color) in palette.enumerated() {
                let redDifference = color.r - red
                let greenDifference = color.g - green
                let blueDifference = color.b - blue
                let distance = redDifference * redDifference
                    + greenDifference * greenDifference
                    + blueDifference * blueDifference
                if distance < bestDistance {
                    bestIndex = index
                    bestDistance = distance
                }
            }
            return bestIndex
        }
        let points = [
            (width / 4, height / 4),
            (width * 3 / 4, height / 4),
            (width / 4, height * 3 / 4),
            (width * 3 / 4, height * 3 / 4),
        ]
        return points.map { point in
            let (x, y) = point
            let offset = (y * width + x) * 4
            return nearestColorIndex(at: offset)
        }
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

    private enum HarnessError: Error {
        case unexpectedResponse(String)
    }

    private enum ScannerMockError: LocalizedError {
        case failed

        var errorDescription: String? {
            "mock scanner failed"
        }
    }

    private actor ScannerReleaseGate {
        private var isReleased = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isReleased else { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func release() {
            isReleased = true
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor LimiterOperationProbe {
        private(set) var executionCount = 0

        func recordExecution() {
            executionCount += 1
        }

        func count() -> Int {
            executionCount
        }
    }
}

private final class ChekinanaAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class ChekinanaLargeDecodeCapture: @unchecked Sendable {
    let data: Data
    private let deinitProbe: ChekinanaAtomicCounter

    init(byteCount: Int, deinitProbe: ChekinanaAtomicCounter) {
        data = Data(repeating: 0xA5, count: byteCount)
        self.deinitProbe = deinitProbe
    }

    deinit {
        deinitProbe.increment()
    }
}

private final class ChekinanaBlockingDecodeGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func blockingValue(_ value: Int) -> Int {
        started.signal()
        _ = released.wait(timeout: .now() + 5)
        return value
    }

    func waitForStarted(count: Int, timeout: TimeInterval) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            waitForStartedSynchronously(count: count, timeout: timeout)
        }.value
    }

    private func waitForStartedSynchronously(count: Int, timeout: TimeInterval) -> Bool {
        for _ in 0..<count {
            guard started.wait(timeout: .now() + timeout) == .success else {
                return false
            }
        }
        return true
    }

    func release(count: Int) {
        for _ in 0..<count {
            released.signal()
        }
    }
}

private func chekinanaQueuedDecodeTask(
    capture: ChekinanaLargeDecodeCapture
) -> Task<Int?, Never> {
    Task.detached {
        await ChekinanaImageWorker.testingPerformDecode {
            capture.data.count
        }
    }
}

private final class ChekinanaNonCooperativeAvatarProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = Set<Int>()
    private var finished = Set<Int>()

    func recordStarted(_ index: Int) {
        lock.lock()
        started.insert(index)
        lock.unlock()
    }

    func recordFinished(_ index: Int) {
        lock.lock()
        finished.insert(index)
        lock.unlock()
    }

    func snapshot() -> (started: Set<Int>, finished: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        return (started, finished)
    }
}

private func chekinanaTestBlockingSleep(_ interval: TimeInterval) {
    Thread.sleep(forTimeInterval: interval)
}

private actor ChekinanaBatchPreparationConcurrencyProbe {
    private var active = 0
    private var maximum = 0

    func begin() {
        active += 1
        maximum = max(maximum, active)
    }

    func end() {
        active -= 1
    }

    func peak() -> Int { maximum }
}

@MainActor
private final class ChekinanaBatchIndexRaceInjector {
    let insertedID = UUID()
    private let date: Date
    private let idx: Int
    private var context: ModelContext?
    private var idol: Idol?
    private var didInsert = false

    init(date: Date, idx: Int) {
        self.date = date
        self.idx = idx
    }

    func configure(context: ModelContext, idol: Idol) {
        self.context = context
        self.idol = idol
    }

    func insertIfNeeded() throws {
        guard !didInsert, let context, let idol else { return }
        let cheki = Cheki(id: insertedID, date: date, idx: idx)
        context.insert(cheki)
        cheki.idols = [idol]
        try context.save()
        didInsert = true
    }
}

private final class ChekinanaNeverCompletingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Deliberately never calls the URLProtocolClient. This reproduces the
        // callback omission that previously leaked the custom continuation.
    }

    override func stopLoading() {}
}

private actor ChekinanaEventImageFetchProbe {
    private let data: Data
    private let delayNanoseconds: UInt64
    private var activeCount = 0
    private var peakCount = 0

    init(data: Data, delayNanoseconds: UInt64 = 10_000_000) {
        self.data = data
        self.delayNanoseconds = delayNanoseconds
    }

    func fetch(_ url: URL) async throws -> Data {
        activeCount += 1
        peakCount = max(peakCount, activeCount)
        defer { activeCount -= 1 }
        try await Task.sleep(nanoseconds: delayNanoseconds)
        if url.lastPathComponent == "fail.jpg" {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    func peakConcurrency() -> Int { peakCount }
}

private final class ChekinanaEventCandidateMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let data = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct ChekinanaRuntimeMockResponse: Sendable {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    init(statusCode: Int = 200, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }
}

private final class ChekinanaRuntimeMockURLProtocol: URLProtocol, @unchecked Sendable {
    private final class LoadingContext: @unchecked Sendable {
        weak var owner: ChekinanaRuntimeMockURLProtocol?

        init(owner: ChekinanaRuntimeMockURLProtocol) {
            self.owner = owner
        }

        func load(
            request: URLRequest,
            using handler: @Sendable (URLRequest) async throws -> ChekinanaRuntimeMockResponse
        ) async {
            guard let owner else { return }
            do {
                owner.deliver(try await handler(request), for: request)
            } catch {
                owner.client?.urlProtocol(owner, didFailWithError: error)
            }
        }
    }

    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) async throws -> ChekinanaRuntimeMockResponse)?
    private var loadingTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let request = self.request
        let context = LoadingContext(owner: self)
        loadingTask = Task {
            await context.load(request: request, using: handler)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }

    private func deliver(_ result: ChekinanaRuntimeMockResponse, for request: URLRequest) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: result.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor ScannerRuntimeTimeoutProbe {
    private var requestTimeouts: [String: TimeInterval] = [:]

    func response(for request: URLRequest) -> ChekinanaRuntimeMockResponse {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        requestTimeouts[key] = request.timeoutInterval
        return .init(
            data: Data(
                #"{"ok":true,"state":"ready","phase":"ready","message":null,"retryAllowed":false,"canStart":false,"canTerminate":true,"updatedAt":null}"#.utf8
            ),
            headers: ["Content-Type": "application/json"]
        )
    }

    func snapshot() -> [String: TimeInterval] {
        requestTimeouts
    }
}

private func scannerRuntimeJSON(state: String) -> Data {
    let retryAllowed = state == "closed"
    let canStart = state == "closed"
    let canTerminate = state == "ready"
    return Data(
        "{\"ok\":true,\"state\":\"\(state)\",\"phase\":\"\(state)\",\"message\":null,\"retryAllowed\":\(retryAllowed),\"canStart\":\(canStart),\"canTerminate\":\(canTerminate),\"updatedAt\":null}"
            .utf8
    )
}

private func scannerRuntimeProgressJSON(current: Int, total: Int) -> Data {
    Data(
        "{\"ok\":true,\"state\":\"preparing\",\"phase\":\"preparing\",\"message\":null,\"retryAllowed\":false,\"canStart\":false,\"canTerminate\":false,\"progress\":{\"current\":\(current),\"total\":\(total)}}"
            .utf8
    )
}

private actor ScannerRuntimeStatusCaptureProbe {
    private var statuses: [ChekinanaScannerRuntimeStatus] = []

    func append(_ status: ChekinanaScannerRuntimeStatus) {
        statuses.append(status)
    }

    func snapshot() -> [ChekinanaScannerRuntimeStatus] {
        statuses
    }
}

private actor ScannerRuntimeStreamingStartProbe {
    private var update: ChekinanaScannerRuntimePresentationStore.RuntimeStartUpdate?
    private var continuation: CheckedContinuation<ChekinanaScannerRuntimeStatus, Never>?

    var isStarted: Bool { update != nil }

    func start(
        update: @escaping ChekinanaScannerRuntimePresentationStore.RuntimeStartUpdate
    ) async -> ChekinanaScannerRuntimeStatus {
        self.update = update
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ status: ChekinanaScannerRuntimeStatus) async {
        await update?(status)
    }

    func finish(_ status: ChekinanaScannerRuntimeStatus) async {
        let update = self.update
        self.update = nil
        let continuation = self.continuation
        self.continuation = nil
        await update?(status)
        continuation?.resume(returning: status)
    }
}

private final class ScannerRuntimeStartSocketProbe:
    ChekinanaScannerRuntimeStartSocket,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var frames: [Data]
    private var receiveCount = 0
    private var cancelCount = 0

    init(frames: [Data]) {
        self.frames = frames
    }

    func receive() async throws -> Data {
        try nextFrame()
    }

    func cancel() {
        lock.lock()
        cancelCount += 1
        lock.unlock()
    }

    func snapshot() -> (receiveCount: Int, cancelCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (receiveCount, cancelCount)
    }

    private func nextFrame() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else {
            throw ChekinanaScannerRuntimeError.invalidResponse
        }
        receiveCount += 1
        return frames.removeFirst()
    }
}

private final class ScannerRuntimeBlockingStartSocketProbe:
    ChekinanaScannerRuntimeStartSocket,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var receiveCount = 0
    private var cancelCount = 0

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let continuation: CheckedContinuation<Data, Error>?
        lock.lock()
        cancelCount += 1
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func snapshot() -> (receiveCount: Int, cancelCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (receiveCount, cancelCount)
    }

    private func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        receiveCount += 1
        self.continuation = continuation
        lock.unlock()
    }
}

private actor ScannerRuntimeStartFactoryProbe {
    private let socket: ScannerRuntimeStartSocketProbe
    private var connectionCount = 0
    private var method: String?
    private var scheme: String?
    private var path: String?
    private var timeout: TimeInterval?
    private var sawSensitiveTransport = false

    init(frames: [Data]) {
        socket = ScannerRuntimeStartSocketProbe(frames: frames)
    }

    func open(_ request: URLRequest) -> any ChekinanaScannerRuntimeStartSocket {
        connectionCount += 1
        method = request.httpMethod
        scheme = request.url?.scheme
        path = request.url?.path
        timeout = request.timeoutInterval
        sawSensitiveTransport = request.value(forHTTPHeaderField: "Authorization") != nil
            || request.value(forHTTPHeaderField: "X-Cheki-Token") != nil
            || URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "token" }) == true
        return socket
    }

    func snapshot() -> (
        connectionCount: Int,
        receiveCount: Int,
        cancelCount: Int,
        method: String?,
        scheme: String?,
        path: String?,
        timeout: TimeInterval?,
        sawSensitiveTransport: Bool
    ) {
        let socketSnapshot = socket.snapshot()
        return (
            connectionCount,
            socketSnapshot.receiveCount,
            socketSnapshot.cancelCount,
            method,
            scheme,
            path,
            timeout,
            sawSensitiveTransport
        )
    }
}

private actor ScannerRuntimeSchedulerProbe {
    private var delays: [UInt64] = []
    private var requests: [String] = []

    func recordDelay(_ delay: UInt64) {
        delays.append(delay)
    }

    func recordRequest(_ request: String) {
        requests.append(request)
    }

    func snapshot() -> (delays: [UInt64], requests: [String]) {
        (delays, requests)
    }
}

private actor ScannerRuntimeStoreOperationProbe {
    private var statusContinuations: [
        CheckedContinuation<ChekinanaScannerRuntimeStatus, Never>
    ] = []
    private var startContinuations: [
        CheckedContinuation<ChekinanaScannerRuntimeStatus, Never>
    ] = []
    private var stopContinuations: [
        CheckedContinuation<ChekinanaScannerRuntimeStatus, Never>
    ] = []
    private var statusCount = 0
    private var startCount = 0
    private var stopCount = 0

    func statusRequest() async -> ChekinanaScannerRuntimeStatus {
        statusCount += 1
        return await withCheckedContinuation { continuation in
            statusContinuations.append(continuation)
        }
    }

    func startRequest() async -> ChekinanaScannerRuntimeStatus {
        startCount += 1
        return await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func stopRequest() async -> ChekinanaScannerRuntimeStatus {
        stopCount += 1
        return await withCheckedContinuation { continuation in
            stopContinuations.append(continuation)
        }
    }

    func completeNextStatus(_ status: ChekinanaScannerRuntimeStatus) {
        guard !statusContinuations.isEmpty else { return }
        statusContinuations.removeFirst().resume(returning: status)
    }

    func completeNextStart(_ status: ChekinanaScannerRuntimeStatus) {
        guard !startContinuations.isEmpty else { return }
        startContinuations.removeFirst().resume(returning: status)
    }

    func completeNextStop(_ status: ChekinanaScannerRuntimeStatus) {
        guard !stopContinuations.isEmpty else { return }
        stopContinuations.removeFirst().resume(returning: status)
    }

    func snapshot() -> (statusCount: Int, startCount: Int, stopCount: Int) {
        (statusCount, startCount, stopCount)
    }
}

private actor ScannerRuntimeFailureProbe {
    private var methods: [String] = []
    private var sawSensitiveTransport = false

    func response(for request: URLRequest) -> ChekinanaRuntimeMockResponse {
        methods.append(request.httpMethod ?? "GET")
        sawSensitiveTransport = sawSensitiveTransport
            || request.value(forHTTPHeaderField: "X-Cheki-Token") != nil
            || URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "token" }) == true
        if request.httpMethod == "POST" {
            return .init(
                statusCode: 503,
                data: Data(#"{"ok":true,"state":"closed","phase":"closed","message":"No GPU is currently available. Please try again later.","retryAllowed":true,"canStart":true,"canTerminate":false,"updatedAt":"2026-08-04T12:00:00Z"}"#.utf8),
                headers: ["Content-Type": "application/json"]
            )
        }
        return .init(
            data: Data(#"{"ok":true,"state":"closed","phase":"closed","message":null,"retryAllowed":true,"canStart":true,"canTerminate":false,"updatedAt":null}"#.utf8),
            headers: ["Content-Type": "application/json"]
        )
    }

    func snapshot() -> (methods: [String], sawSensitiveTransport: Bool) {
        (methods, sawSensitiveTransport)
    }
}

private actor ScannerManagedProxyProbe {
    private let resultImage: Data
    private var runtimeStatusCount = 0
    private var startCount = 0
    private var sawSensitiveTransport = false
    private var sawDirectField = false
    private var events: [String] = []

    init(resultImage: Data) {
        self.resultImage = resultImage
    }

    func response(for request: URLRequest) -> ChekinanaRuntimeMockResponse {
        let path = request.url?.path ?? ""
        let bodyText = requestBodyData(request)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        sawSensitiveTransport = sawSensitiveTransport
            || request.value(forHTTPHeaderField: "X-Cheki-Token") != nil
            || URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "token" }) == true
            || bodyText.contains("name=\"token\"")

        if path == "/api/scanner/runtime" {
            runtimeStatusCount += 1
            let state: String
            switch runtimeStatusCount {
            case 1: state = "closed"
            case 2: state = "preparing"
            default: state = "ready"
            }
            events.append("runtime:\(state)")
            return .init(data: runtimeJSON(state: state))
        }
        if path == "/api/scanner/runtime/start" {
            startCount += 1
            events.append("start")
            return .init(data: runtimeJSON(state: "preparing"))
        }
        if path == "/api/process" {
            sawDirectField = sawDirectField
                || bodyText.contains("name=\"direct\"")
                    && bodyText.contains("\r\n\r\n1\r\n")
            events.append("process")
            return .init(data: Data(#"{"task_id":"task-1","status":"queued"}"#.utf8))
        }
        if path == "/api/status/task-1" {
            events.append("scan-status")
            return .init(data: Data(#"{"status":"completed","phase":"complete","results_count":1,"expected_polaroids":1,"extraction_complete":true,"results":[{"id":1,"type":"polaroid"}]}"#.utf8))
        }
        if path == "/api/result/task-1/1" {
            events.append("result")
            return .init(data: resultImage, headers: ["Content-Type": "image/png"])
        }
        return .init(statusCode: 404, data: Data())
    }

    private func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    func snapshot() -> (
        runtimeStatusCount: Int,
        startCount: Int,
        sawSensitiveTransport: Bool,
        sawDirectField: Bool,
        events: [String]
    ) {
        (
            runtimeStatusCount,
            startCount,
            sawSensitiveTransport,
            sawDirectField,
            events
        )
    }

    private func runtimeJSON(state: String) -> Data {
        let retryAllowed = state == "closed"
        let canStart = state == "closed"
        let canTerminate = state == "ready"
        return Data(
            "{\"ok\":true,\"state\":\"\(state)\",\"phase\":\"\(state)\",\"message\":null,\"retryAllowed\":\(retryAllowed),\"canStart\":\(canStart),\"canTerminate\":\(canTerminate),\"updatedAt\":null}"
                .utf8
        )
    }
}

private final class ChekinanaScannerDateMockURLProtocol: URLProtocol, @unchecked Sendable {
    private final class LoadingContext: @unchecked Sendable {
        weak var owner: ChekinanaScannerDateMockURLProtocol?

        init(owner: ChekinanaScannerDateMockURLProtocol) {
            self.owner = owner
        }

        func load(
            using handler: @Sendable (URLRequest) async throws -> (
                data: Data,
                headers: [String: String]
            )
        ) async {
            guard let owner else { return }
            do {
                owner.deliver(try await handler(owner.request))
            } catch {
                owner.client?.urlProtocol(owner, didFailWithError: error)
            }
        }
    }

    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (data: Data, headers: [String: String]))?
    nonisolated(unsafe) static var asyncHandler:
        (@Sendable (URLRequest) async throws -> (data: Data, headers: [String: String]))?

    private var loadingTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let asyncHandler = Self.asyncHandler {
            let context = LoadingContext(owner: self)
            loadingTask = Task {
                await context.load(using: asyncHandler)
            }
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: result.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }

    private func deliver(_ result: (data: Data, headers: [String: String])) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: result.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor ScannerProgressiveResultProbe {
    private var active = 0
    private var peak = 0
    private var queries: [String?] = []
    private var statusRequestCount = 0
    private var resultRequestCounts: [String: Int] = [:]
    private var events: [String] = []

    func nextStatusResponse() -> Data {
        statusRequestCount += 1
        events.append("status:\(statusRequestCount)")
        switch statusRequestCount {
        case 1:
            return Data(#"{"status":"processing","phase":"extracting","results_count":"1","expected_polaroids":5,"extraction_complete":false,"results":[{"id":1,"type":"polaroid"}]}"#.utf8)
        default:
            return Data(#"{"status":"processing","phase":"complete","results_count":5,"expected_polaroids":"5","extraction_complete":"true","results":[{"id":1,"type":"polaroid"},{"id":3,"type":"polaroid"},{"id":2,"type":"polaroid"},{"id":5,"type":"polaroid"},{"id":4,"type":"polaroid"}]}"#.utf8)
        }
    }

    func begin(resultID: String, query: String?) {
        active += 1
        peak = max(peak, active)
        queries.append(query)
        resultRequestCounts[resultID, default: 0] += 1
        events.append("get:\(resultID)")
    }

    func end() {
        active -= 1
    }

    func snapshot() -> (
        statusRequestCount: Int,
        resultRequestCounts: [String: Int],
        peak: Int,
        queries: [String?],
        events: [String]
    ) {
        (statusRequestCount, resultRequestCounts, peak, queries, events)
    }
}

private actor ScannerPartialResultProbe {
    private var counts: [String: Int] = [:]
    private var queries: [String?] = []

    func record(resultID: String, query: String?) {
        counts[resultID, default: 0] += 1
        queries.append(query)
    }

    func snapshot() -> (counts: [String: Int], queries: [String?]) {
        (counts, queries)
    }
}

private actor ScannerRepeatedWarningProbe {
    private var count = 0

    func nextStatus() -> Data {
        count += 1
        if count == 1 {
            return Data(#"{"status":"processing","warning":"partial extraction","results_count":1,"extraction_complete":false,"results":[{"id":1,"type":"polaroid"}]}"#.utf8)
        }
        return Data(#"{"status":"completed","warning":"partial extraction","results_count":1,"extraction_complete":true,"results":[{"id":1,"type":"polaroid"}]}"#.utf8)
    }

    func statusCount() -> Int {
        count
    }
}

private actor ScannerCancellationLifecycleProbe {
    private var finishedSources = 0
    private var didReturn = false

    func sourceFinished() {
        finishedSources += 1
    }

    func executeReturned() {
        didReturn = true
    }

    func finishedSourceCount() -> Int {
        finishedSources
    }

    func hasExecuteReturned() -> Bool {
        didReturn
    }
}

private actor LocalImportDateInputProbe {
    private var image: ChekinanaPendingChekiImage?

    func record(_ image: ChekinanaPendingChekiImage) {
        self.image = image
    }

    func snapshot() -> ChekinanaPendingChekiImage? {
        image
    }
}

private actor DirectDateAnnotationRequestProbe {
    private var method = ""
    private var path = ""
    private var contentType: String?
    private var body = Data()
    private var timeout: TimeInterval = 0
    private var hasClientToken = false

    func response(for request: URLRequest) -> ChekinanaRuntimeMockResponse {
        method = request.httpMethod ?? ""
        path = request.url?.path ?? ""
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        body = requestBodyData(request) ?? Data()
        timeout = request.timeoutInterval
        hasClientToken = request.value(forHTTPHeaderField: "X-Cheki-Token") != nil
        return .init(
            data: Data(#"{"status":"not_detected"}"#.utf8),
            headers: ["Content-Type": "application/json"]
        )
    }

    func snapshot() -> (
        method: String,
        path: String,
        contentType: String?,
        body: Data,
        timeout: TimeInterval,
        hasClientToken: Bool
    ) {
        (method, path, contentType, body, timeout, hasClientToken)
    }

    private func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

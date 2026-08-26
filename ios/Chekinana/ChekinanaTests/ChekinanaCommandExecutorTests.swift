import Foundation
import AVFoundation
import Combine
import CoreData
import ImageIO
import SwiftData
import SwiftUI
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

    func testTemporaryEditorDateTransitionsPreserveExplicitIntent() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDate = utcDate(2026, 8, 13)
        let secondDate = utcDate(2026, 8, 14)
        let ambiguousDate = utcDate(2026, 8, 15)
        let firstID = UUID()
        let secondID = UUID()
        let events: [(id: UUID, date: Date?)] = [
            (firstID, firstDate),
            (secondID, secondDate),
            (UUID(), ambiguousDate),
            (UUID(), ambiguousDate),
        ]

        XCTAssertEqual(
            ChekinanaNativeTemporaryEditorEventPolicy.dateChanged(
                currentEventID: nil,
                eventWasExplicitlyEdited: false,
                date: firstDate,
                events: events,
                calendar: calendar
            ),
            .init(eventID: firstID, eventWasExplicitlyEdited: false)
        )
        XCTAssertEqual(
            ChekinanaNativeTemporaryEditorEventPolicy.dateChanged(
                currentEventID: firstID,
                eventWasExplicitlyEdited: false,
                date: secondDate,
                events: events,
                calendar: calendar
            ),
            .init(eventID: secondID, eventWasExplicitlyEdited: false)
        )
        XCTAssertEqual(
            ChekinanaNativeTemporaryEditorEventPolicy.dateChanged(
                currentEventID: secondID,
                eventWasExplicitlyEdited: false,
                date: ambiguousDate,
                events: events,
                calendar: calendar
            ),
            .init(eventID: nil, eventWasExplicitlyEdited: false)
        )
        XCTAssertEqual(
            ChekinanaNativeTemporaryEditorEventPolicy.dateChanged(
                currentEventID: secondID,
                eventWasExplicitlyEdited: false,
                date: nil,
                events: events,
                calendar: calendar
            ),
            .init(eventID: nil, eventWasExplicitlyEdited: false)
        )
        XCTAssertEqual(
            ChekinanaNativeTemporaryEditorEventPolicy.dateChanged(
                currentEventID: firstID,
                eventWasExplicitlyEdited: true,
                date: secondDate,
                events: events,
                calendar: calendar
            ),
            .init(eventID: firstID, eventWasExplicitlyEdited: true)
        )
        XCTAssertEqual(
            ChekinanaNativeTemporaryEditorEventPolicy.dateChanged(
                currentEventID: nil,
                eventWasExplicitlyEdited: true,
                date: firstDate,
                events: events,
                calendar: calendar
            ),
            .init(eventID: nil, eventWasExplicitlyEdited: true)
        )
        XCTAssertEqual(
            ChekinanaNativeTemporaryEditorEventPolicy.dateChanged(
                currentEventID: UUID(),
                eventWasExplicitlyEdited: true,
                date: firstDate,
                events: events,
                calendar: calendar
            ),
            .init(eventID: nil, eventWasExplicitlyEdited: true)
        )

        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let editorStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaNativeTemporaryEditor")?.lowerBound
        )
        let editorEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaCandidatePicker",
            range: editorStart..<source.endIndex
        )?.lowerBound)
        let editor = String(source[editorStart..<editorEnd])
        XCTAssertEqual(
            editor.components(
                separatedBy: "refreshEventSelectionForDateChange()"
            ).count - 1,
            3
        )
        XCTAssertTrue(editor.contains(
            "draft.eventWasExplicitlyEdited = state.eventWasExplicitlyEdited"
        ))
        XCTAssertTrue(editor.contains("draft.eventWasExplicitlyEdited = true"))
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

    func testNativeScanReviewMetadataEditorAndActionsKeepRequiredStructure() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
        let productSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "ChekinanaProductShell.swift"
            ),
            encoding: .utf8
        )
        let commandSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "ChekinanaCommandExecutor.swift"
            ),
            encoding: .utf8
        )

        func slice(
            _ source: String,
            from startMarker: String,
            to endMarker: String
        ) throws -> String {
            let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
            let end = try XCTUnwrap(source.range(
                of: endMarker,
                range: start..<source.endIndex
            )?.lowerBound)
            return String(source[start..<end])
        }

        let review = try slice(
            productSource,
            from: "private struct ChekinanaNativeScanReview",
            to: "enum ChekinanaScanReviewLayout"
        )
        XCTAssertTrue(review.contains("temporaryMetadataGrid(temporary"))
        XCTAssertFalse(review.contains("Create new Cheki"))
        XCTAssertFalse(review.contains("Attach to existing"))
        XCTAssertFalse(review.contains("Auto matched from the recognized date"))
        XCTAssertFalse(review.contains("chekinana.scan.review.event-auto"))

        let metadata = try slice(
            review,
            from: "private func temporaryMetadataGrid",
            to: "private func compactAvatarStack"
        )
        XCTAssertEqual(
            metadata.components(
                separatedBy: "GridItem(.flexible(minimum: 0), spacing: 8)"
            ).count - 1,
            2
        )
        let idol = try XCTUnwrap(metadata.range(of: ".accessibilityLabel(\"Idol\")"))
        let date = try XCTUnwrap(metadata.range(of: ".accessibilityLabel(\"Date\")"))
        let size = try XCTUnwrap(metadata.range(of: ".accessibilityLabel(\"Size\")"))
        let event = try XCTUnwrap(metadata.range(of: ".accessibilityLabel(\"Event\")"))
        XCTAssertLessThan(idol.lowerBound, date.lowerBound)
        XCTAssertLessThan(date.lowerBound, size.lowerBound)
        XCTAssertLessThan(size.lowerBound, event.lowerBound)
        XCTAssertTrue(metadata.contains("temporary.eventID.flatMap"))
        XCTAssertTrue(metadata.contains("?? \"No Event\""))
        XCTAssertTrue(metadata.contains("alignment: .trailing"))
        XCTAssertTrue(metadata.contains(".lineLimit(1)"))
        XCTAssertTrue(metadata.contains(".truncationMode(.tail)"))

        let actions = try slice(
            review,
            from: "private func temporaryActionRow",
            to: "private var orderedIdols"
        )
        XCTAssertTrue(actions.contains("\"Download\""))
        XCTAssertTrue(actions.contains("\"View annotation\""))
        XCTAssertEqual(
            actions.components(separatedBy:
                "minHeight: actionTextRegionHeight"
            ).count - 1,
            1
        )
        XCTAssertEqual(
            actions.components(separatedBy:
                "maxHeight: actionTextRegionHeight"
            ).count - 1,
            1
        )
        XCTAssertEqual(
            actions.components(separatedBy: ".contentShape(Rectangle())").count - 1,
            1
        )
        XCTAssertTrue(actions.contains(".lineLimit(2)"))
        XCTAssertTrue(actions.contains(".multilineTextAlignment(.center)"))
        XCTAssertTrue(actions.contains("alignment: .top"))
        XCTAssertFalse(actions.contains(".minimumScaleFactor("))
        XCTAssertFalse(actions.contains("actionButtonHeight"))
        XCTAssertTrue(review.contains("@ScaledMetric(relativeTo: .caption2)"))
        XCTAssertTrue(review.contains(
            "ChekinanaScanReviewLayout.actionTextRegionBaseHeight"
        ))
        XCTAssertEqual(ChekinanaScanReviewLayout.actionTextRegionBaseHeight, 28)

        let editor = try slice(
            productSource,
            from: "private struct ChekinanaNativeTemporaryEditor",
            to: "private struct ChekinanaCandidatePicker"
        )
        XCTAssertTrue(editor.contains("ChekinanaNativeIdolSelectionGrid("))
        XCTAssertTrue(editor.contains("selectedIDs: $draft.idolIDs"))
        XCTAssertFalse(editor.contains("Toggle(idol.name"))
        XCTAssertFalse(editor.contains("ForEach(idols)"))

        let idolGrid = try slice(
            productSource,
            from: "private struct ChekinanaNativeIdolSelectionGrid",
            to: "private struct ChekinanaNativeDateSelectionView"
        )
        XCTAssertTrue(idolGrid.contains("ChekinanaIdolAvatar(idol: idol, size: 62)"))
        XCTAssertTrue(idolGrid.contains("ChekinanaNeutralIdolAvatar(size: 62)"))
        XCTAssertTrue(idolGrid.contains("checkmark.circle.fill"))
        XCTAssertTrue(idolGrid.contains("selectedIDs.removeAll()"))
        XCTAssertTrue(idolGrid.contains("let label = idol?.name"))
        XCTAssertTrue(idolGrid.contains("common.unassigned"))
        XCTAssertFalse(idolGrid.contains("Text(label)"))
        XCTAssertTrue(idolGrid.contains(
            "columns: ChekinanaIdolAvatarSelectionLayout.columns"
        ))
        XCTAssertFalse(idolGrid.contains(".adaptive("))

        XCTAssertEqual(ChekinanaIdolAvatarSelectionLayout.columnCount, 3)
        XCTAssertEqual(ChekinanaIdolAvatarSelectionLayout.columns.count, 3)

        let neutralAvatar = try slice(
            productSource,
            from: "private struct ChekinanaNeutralIdolAvatar",
            to: "private struct ChekinanaExpandableDateWheel"
        )
        XCTAssertTrue(neutralAvatar.contains(".clipShape(Circle())"))
        XCTAssertTrue(neutralAvatar.contains("Circle().strokeBorder("))

        let avatarImage = try slice(
            productSource,
            from: "private struct ChekinanaIdolAvatarImage",
            to: "private struct ChekinanaIdolDetailView"
        )
        XCTAssertEqual(
            avatarImage.components(separatedBy: ".scaledToFill()").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            avatarImage.components(separatedBy: ".clipShape(Circle())").count - 1,
            4
        )
        XCTAssertTrue(avatarImage.contains("Circle().strokeBorder("))
        XCTAssertFalse(avatarImage.contains(".clipped()"))

        let staging = try slice(
            productSource,
            from: "private func stageImportInput",
            to: "private func executeNativeScan"
        )
        XCTAssertTrue(staging.contains("inferredSize: normalized.inferredSize"))
        XCTAssertTrue(productSource.contains("inferredChekiSize: staged.inferredSize"))
        XCTAssertTrue(review.contains("temporary.size?.rawValue"))

        let recognitionAssociation = try slice(
            commandSource,
            from: "private func uniqueEventID(\n        for inferredDate",
            to: "private func scanCheki"
        )
        XCTAssertTrue(recognitionAssociation.contains(
            "ChekinanaChekiEventAutoAssociation.uniqueEventID("
        ))
        XCTAssertTrue(recognitionAssociation.contains(
            "events: candidates.map { ($0.id, $0.date) }"
        ))
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

    func testCalendarTodayVisualStateUsesHalfAccentStrokeAndSelectedFillWins() {
        XCTAssertEqual(
            ChekinanaCalendarDayVisualState.resolve(
                isSelected: false,
                isToday: true
            ),
            .today
        )
        XCTAssertEqual(ChekinanaCalendarDayVisualState.today.fillAccentOpacity, 0)
        XCTAssertEqual(ChekinanaCalendarDayVisualState.today.strokeAccentOpacity, 0.5)
        XCTAssertEqual(
            ChekinanaCalendarDayVisualState.resolve(
                isSelected: true,
                isToday: true
            ),
            .selected
        )
        XCTAssertEqual(
            ChekinanaCalendarDayVisualState.selected.fillAccentOpacity,
            1
        )
        XCTAssertEqual(ChekinanaCalendarDayVisualState.selected.strokeAccentOpacity, 0)
    }

    func testGalleryDateRangeIsCanonicalClosedAndNormalizesInvalidBounds() {
        let first = utcDate(2026, 8, 10)
        let middle = utcDate(2026, 8, 11)
        let last = utcDate(2026, 8, 12)

        let closed = ChekinanaGalleryDateRange(start: first, end: last)
        XCTAssertTrue(closed.includes(first))
        XCTAssertTrue(closed.includes(last.addingTimeInterval(60 * 60 * 12)))
        XCTAssertFalse(closed.includes(nil))

        var startMovesPastEnd = ChekinanaGalleryDateRange(start: first, end: middle)
        startMovesPastEnd.setStart(last)
        XCTAssertEqual(startMovesPastEnd.start, last)
        XCTAssertEqual(startMovesPastEnd.end, last)
        var endMovesBeforeStart = ChekinanaGalleryDateRange(start: middle, end: last)
        endMovesBeforeStart.setEnd(first)
        XCTAssertEqual(endMovesBeforeStart.start, first)
        XCTAssertEqual(endMovesBeforeStart.end, first)
    }

    func testGalleryDateDefaultsTrackEarlierMediaUntilUserEditsStart() {
        let first = utcDate(2026, 8, 10)
        let earlier = utcDate(2026, 8, 8)
        let manual = utcDate(2026, 8, 9)
        let today = utcDate(2026, 8, 24)
        var state = ChekinanaGalleryDateRangeState(today: today)

        state.syncDefaults(earliest: first, today: today)
        XCTAssertEqual(state.range.start, first)
        XCTAssertEqual(state.range.end, today)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.includes(nil))
        XCTAssertTrue(state.includes(utcDate(2027, 1, 1)))

        state.syncDefaults(earliest: earlier, today: today)
        XCTAssertEqual(state.range.start, earlier)
        var edited = state.range
        edited.setStart(manual)
        state.applyUserRange(edited, startWasEdited: true)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.includes(nil))
        state.syncDefaults(earliest: utcDate(2026, 8, 1), today: today)
        XCTAssertEqual(state.range.start, manual)

        state.reset()
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.range.start, utcDate(2026, 8, 1))
        XCTAssertEqual(state.range.end, today)
    }

    func testGalleryIdolOrderingUsesPrimaryIdolThenDateAndLeavesUnassignedLast() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV8.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let context = ModelContext(container)
        let firstIdol = Idol(name: "First", sortOrder: 1)
        let secondIdol = Idol(name: "Second", sortOrder: 2)
        context.insert(firstIdol)
        context.insert(secondIdol)
        let firstDay = utcDate(2026, 8, 10)
        let secondDay = utcDate(2026, 8, 11)
        let firstEarlier = Cheki(date: firstDay, imageRef: "first-earlier.jpg")
        let firstLater = Cheki(date: secondDay, imageRef: "first-later.jpg")
        let multi = Cheki(date: firstDay, imageRef: "multi.jpg")
        let second = Cheki(date: firstDay, imageRef: "second.jpg")
        let unassigned = Cheki(date: firstDay, imageRef: "unassigned.jpg")
        for value in [firstEarlier, firstLater, multi, second, unassigned] {
            context.insert(value)
        }
        firstEarlier.idols = [firstIdol]
        firstLater.idols = [firstIdol]
        multi.idols = [secondIdol, firstIdol]
        second.idols = [secondIdol]
        try context.save()

        let values = [unassigned, second, firstLater, multi, firstEarlier]
            .map(ChekinanaGalleryItem.cheki)
        let ascendingIDs = ChekinanaGalleryOrdering.ordered(
            values,
            order: .dateAscending,
            sortByIdol: true
        ).map(\.modelID)
        XCTAssertEqual(Set(ascendingIDs.prefix(2)), [firstEarlier.id, multi.id])
        XCTAssertEqual(ascendingIDs.dropFirst(2), [
            firstLater.id,
            second.id,
            unassigned.id,
        ])
        XCTAssertEqual(
            ChekinanaGalleryOrdering.primaryIdolID(for: .cheki(multi)),
            firstIdol.id
        )
        XCTAssertEqual(
            ChekinanaGalleryOrdering.ordered(
                values,
                order: .dateDescending,
                sortByIdol: true
            ).last?.modelID,
            unassigned.id
        )
        XCTAssertEqual(
            ChekinanaGalleryOrdering.ordered(
                [firstEarlier, firstLater].map(ChekinanaGalleryItem.cheki),
                order: .dateDescending,
                sortByIdol: true
            ).map(\.modelID),
            [firstLater.id, firstEarlier.id]
        )
    }

    func testGalleryDateOrderCyclesIndependentlyThroughTwoStates() {
        XCTAssertEqual(ChekinanaGalleryOrder.dateAscending.next, .dateDescending)
        XCTAssertEqual(ChekinanaGalleryOrder.dateDescending.next, .dateAscending)
        XCTAssertEqual(ChekinanaGalleryOrder.allCases.count, 2)
    }

    func testIdolListOrderingUsesFavoriteThenCountPersistedOrderNameAndUUID() {
        let sameCreatedAt = utcDate(2026, 8, 24)
        let favoriteHigh = Idol(name: "Favorite high", isFavorite: true, sortOrder: 9)
        let favoriteLow = Idol(name: "Favorite low", isFavorite: true, sortOrder: 0)
        let countHigh = Idol(name: "Count high", sortOrder: 9)
        let persistedFirst = Idol(name: "Zed", sortOrder: 1)
        let persistedSecond = Idol(name: "Able", sortOrder: 2)
        let nameFirst = Idol(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Alpha",
            createdAt: sameCreatedAt
        )
        let nameSecond = Idol(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Beta",
            createdAt: sameCreatedAt
        )
        let values = [
            nameSecond, persistedSecond, favoriteLow, countHigh,
            nameFirst, favoriteHigh, persistedFirst,
        ]
        let counts = [
            favoriteHigh.id: 2,
            favoriteLow.id: 0,
            countHigh.id: 7,
            persistedFirst.id: 3,
            persistedSecond.id: 3,
            nameFirst.id: 3,
            nameSecond.id: 3,
        ]

        XCTAssertEqual(
            ChekinanaIdolOrdering.orderedForList(
                values,
                chekiCountsByIdolID: counts
            ).map(\.id),
            [
                favoriteHigh.id, favoriteLow.id, countHigh.id,
                persistedFirst.id, persistedSecond.id, nameFirst.id, nameSecond.id,
            ]
        )
    }

    func testChekiRecordRelationshipIndexResolvesLargePrefetchedCatalogueByIDs() {
        let idols = (0..<2_232).map { Idol(name: "Idol \($0)") }
        let event = Event(name: "Event")
        let selected = [idols[2_231], idols[7], idols[1_024]]
        let record = ChekiRecord(idols: selected, event: event)
        let index = ChekinanaChekiRecordRelationshipIndex(
            idols: idols,
            events: [event]
        )

        XCTAssertEqual(index.idols(for: record).map(\.id), selected.map(\.id))
        XCTAssertEqual(index.event(for: record)?.id, event.id)
        XCTAssertEqual(index.idolName(id: idols[1_024].id), "Idol 1024")
        XCTAssertTrue(ChekinanaChekiRecordReadPolicy.isVisible(record, hiddenIDs: []))
        XCTAssertFalse(ChekinanaChekiRecordReadPolicy.isVisible(
            record,
            hiddenIDs: [selected[1].id]
        ))
        XCTAssertTrue(ChekinanaChekiRecordReadPolicy.containsIdol(
            record,
            idolID: selected[2].id
        ))
        XCTAssertTrue(ChekinanaChekiRecordReadPolicy.isLinked(
            record,
            eventID: event.id
        ))
        XCTAssertNil(ChekinanaChekiRecordReadPolicy.singleIdolID(record))
        let unassigned = ChekiRecord()
        XCTAssertTrue(ChekinanaChekiRecordReadPolicy.isUndatedAndUnassigned(unassigned))
        let single = ChekiRecord(idols: [selected[0]])
        XCTAssertEqual(
            ChekinanaChekiRecordReadPolicy.singleIdolID(single),
            selected[0].id
        )
    }

    func testChekiViewerRoutesEditingTapThroughExclusiveZoomInteraction() throws {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(
            ChekinanaChekiViewerRoutingPolicy.initialID(
                requested: second,
                available: [first, second]
            ),
            second
        )
        XCTAssertEqual(
            ChekinanaChekiViewerRoutingPolicy.initialID(
                requested: UUID(),
                available: [first, second]
            ),
            first
        )
        XCTAssertNil(ChekinanaChekiViewerRoutingPolicy.initialID(
            requested: first,
            available: []
        ))

        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let viewerStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaChekiImageViewer")?.lowerBound
        )
        let viewerEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaChekiViewerPage",
            range: viewerStart..<source.endIndex
        )?.lowerBound)
        let viewer = String(source[viewerStart..<viewerEnd])
        let viewportStart = try XCTUnwrap(
            source.range(of: "struct ChekinanaZoomableImageViewport")?.lowerBound
        )
        let viewportEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaEventImageViewerSelection",
            range: viewportStart..<source.endIndex
        )?.lowerBound)
        let viewport = String(source[viewportStart..<viewportEnd])
        let tapSurfaceStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaReliableSingleTapSurface")?
                .lowerBound
        )
        let tapSurface = String(source[tapSurfaceStart..<viewportStart])

        XCTAssertTrue(viewer.contains("onTap: { editingCheki = cheki }"))
        XCTAssertTrue(viewer.contains(".sheet(item: $editingCheki)"))
        XCTAssertTrue(viewer.contains("ChekinanaChekiEditorView("))
        XCTAssertTrue(viewer.contains("allowsDelete: true"))
        XCTAssertTrue(viewer.contains("onDelete: close"))
        XCTAssertTrue(viewer.contains(".scrollTargetBehavior(.paging)"))
        XCTAssertTrue(viewer.contains(".scrollDisabled(visibleImageIsZoomed)"))
        XCTAssertTrue(viewer.contains("visibleImageIsZoomed = false"))
        XCTAssertFalse(viewer.contains("TapGesture"))
        XCTAssertFalse(viewer.contains("DragGesture"))
        XCTAssertFalse(viewer.contains("minimumDistance: 0"))
        XCTAssertFalse(source.contains("routesTap(maximumTranslation:"))
        XCTAssertTrue(viewport.contains(".simultaneously(with: pan)"))
        XCTAssertFalse(viewport.contains("TapGesture().onEnded"))
        XCTAssertTrue(viewport.contains("ChekinanaReliableSingleTapSurface("))
        XCTAssertTrue(tapSurface.contains("UITapGestureRecognizer("))
        XCTAssertTrue(tapSurface.contains("recognizer.cancelsTouchesInView = false"))
        XCTAssertTrue(tapSurface.contains("shouldRecognizeSimultaneouslyWith"))
        XCTAssertTrue(tapSurface.contains("onSingleTap()"))
        XCTAssertFalse(viewport.contains(".exclusively(before: TapGesture())"))
        XCTAssertTrue(viewport.contains(".onChange(of: resetID)"))
        XCTAssertTrue(viewport.contains(".onChange(of: isActive)"))

        XCTAssertEqual(
            source.components(separatedBy: "ChekinanaGalleryDetailView(cheki:").count - 1,
            5
        )
        XCTAssertEqual(
            source.components(separatedBy: "ChekinanaChekiImageViewer(").count - 1,
            2
        )
        func routeSlice(_ start: String, _ end: String) throws -> Substring {
            let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
            let endIndex = try XCTUnwrap(
                source.range(
                    of: end,
                    range: startIndex..<source.endIndex
                )?.lowerBound
            )
            return source[startIndex..<endIndex]
        }
        XCTAssertTrue(try routeSlice(
            "private struct ChekinanaIdolDetailView",
            "private struct ChekinanaIdolLinkedEventsView"
        ).contains("ChekinanaGalleryDetailView(cheki:"))
        XCTAssertTrue(try routeSlice(
            "private struct ChekinanaIdolEventChekiView",
            "private typealias ChekinanaIdolMediaKind"
        ).contains("ChekinanaGalleryDetailView(cheki:"))
        XCTAssertTrue(try routeSlice(
            "private struct ChekinanaIdolMediaDateGroupView",
            "private struct ChekinanaIdolNoMediaChekiGroupView"
        ).contains("ChekinanaGalleryDetailView(cheki:"))
        XCTAssertTrue(try routeSlice(
            "private struct ChekinanaEventDetailView",
            "private struct ChekinanaEventChekiGroupView"
        ).contains("ChekinanaGalleryDetailView(cheki:"))
        XCTAssertTrue(try routeSlice(
            "private struct ChekinanaGalleryView",
            "private struct ChekinanaGalleryCompactFilterLabel"
        ).contains("ChekinanaGalleryDetailView(cheki:"))
        XCTAssertTrue(try routeSlice(
            "private struct ChekinanaCalendarGroupSummary",
            "struct ChekinanaLocalDataClearResult"
        ).contains("ChekinanaChekiImageViewer("))
        XCTAssertTrue(source.contains(".accessibilityValue(cheki.id.uuidString.lowercased())"))
    }

    func testCalendarViewerUsesOrderedRowMediaAndRequestedThumbnail() throws {
        let idol = Idol(name: "Ordered")
        let first = Cheki(idols: [idol], imageRef: "first.jpg")
        let withoutMedia = Cheki(idols: [idol])
        let second = Cheki(idols: [idol], imageRef: "second.jpg")
        let group = ChekinanaCalendarIdolGroup(
            id: idol.id.uuidString.lowercased(),
            idol: idol,
            chekis: [first, withoutMedia, second]
        )

        let selection = ChekinanaCalendarMediaSelection(
            group: group,
            initialID: second.id
        )
        XCTAssertEqual(selection.mediaChekis.map(\.id), [first.id, second.id])
        XCTAssertEqual(selection.resolvedInitialID, second.id)
        XCTAssertEqual(
            ChekinanaCalendarMediaSelection(
                group: group,
                initialID: UUID()
            ).resolvedInitialID,
            first.id
        )

        let other = Idol(name: "Other")
        let multi = Cheki(
            idols: [other, idol],
            imageRef: "multi.jpg"
        )
        let multiGroup = try XCTUnwrap(
            ChekinanaCalendarIdolGroup.groups(
                for: [first, second, multi],
                records: [],
                relationshipIndex: .init(idols: [idol, other]),
                groupsByExactIdolCombination: true
            ).first { $0.chekis.first?.id == multi.id }
        )
        XCTAssertTrue(multiGroup.isStandaloneMultiIdol)
        XCTAssertEqual(
            ChekinanaCalendarMediaSelection(
                group: multiGroup,
                initialID: multi.id
            ).mediaChekis.map(\.id),
            [multi.id]
        )

        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("openCalendarMedia(group, initialID: cheki.id)"))
        XCTAssertTrue(source.contains("ForEach(Array(chekis.prefix(5)))"))
        XCTAssertTrue(source.contains("appearance: .calendar"))
        XCTAssertTrue(source.contains("var backgroundColor: Color {\n        ChekinanaProductTheme.pageBackground"))
        XCTAssertTrue(source.contains("isPresented: $isMediaViewerPresented"))
        XCTAssertTrue(source.contains("onDismiss: { selectedMediaSelection = nil }"))
        XCTAssertFalse(source.contains("case .immersive: .black"))
    }

    func testCalendarCombinationRowRoutesToUnifiedEditorAndMediaEditorsPersistEventLinks() throws {
        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let calendarStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaCalendarView")?.lowerBound
        )
        let calendarEnd = try XCTUnwrap(source.range(
            of: "private enum ChekinanaCalendarNoMediaRecord",
            range: calendarStart..<source.endIndex
        )?.lowerBound)
        let calendar = String(source[calendarStart..<calendarEnd])
        XCTAssertTrue(calendar.contains("groupsByExactIdolCombination: true"))
        XCTAssertTrue(calendar.contains("selectedGroupEditor = .init("))
        XCTAssertTrue(calendar.contains(".sheet(item: $selectedGroupEditor)"))
        XCTAssertTrue(calendar.contains("isPresented: $isMediaViewerPresented"))
        XCTAssertTrue(calendar.contains("if let selection = selectedMediaSelection"))
        XCTAssertFalse(calendar.contains("ChekinanaCalendarNoMediaRecordEditor(record:"))

        let editorStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaCalendarGroupEditor")?.lowerBound
        )
        let editorEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaCalendarGroupSummary",
            range: editorStart..<source.endIndex
        )?.lowerBound)
        let editor = String(source[editorStart..<editorEnd])
        XCTAssertTrue(editor.contains("ForEach($recordDrafts)"))
        XCTAssertTrue(editor.contains("ChekinanaChekiRecordEditorFields("))
        XCTAssertTrue(editor.contains("mediaStripSection("))
        XCTAssertTrue(editor.contains(
            "group.chekis.map(ChekinanaGalleryItem.cheki)"
        ))
        XCTAssertTrue(editor.contains(
            "group.shames.map(ChekinanaGalleryItem.shame)"
        ))
        XCTAssertTrue(editor.contains(
            "group.dougas.map(ChekinanaGalleryItem.douga)"
        ))
        XCTAssertTrue(editor.contains("ScrollView(.horizontal)"))
        XCTAssertTrue(editor.contains("LazyHStack(spacing: 10)"))
        XCTAssertTrue(editor.contains(".sheet(item: $editingMediaItem)"))
        XCTAssertTrue(editor.contains("ChekinanaChekiEditorView("))
        XCTAssertTrue(editor.contains("allowsDelete: true"))
        XCTAssertTrue(editor.contains("ChekinanaGalleryMetadataEditor("))
        XCTAssertFalse(editor.contains("ForEach($chekiDrafts)"))
        XCTAssertFalse(editor.contains("ForEach($mediaDrafts)"))
        XCTAssertFalse(editor.contains("ChekinanaChekiEditorFields("))
        XCTAssertFalse(editor.contains("ChekinanaMediaMetadataEditorFields("))
        XCTAssertTrue(editor.contains("action: saveAll"))
        XCTAssertEqual(
            editor.components(separatedBy: "group-editor.save").count - 1,
            1
        )
        XCTAssertTrue(editor.contains("let recordPlans = try plannedRecordMutations()"))
        XCTAssertFalse(editor.contains("plannedChekiMutations"))
        XCTAssertFalse(editor.contains("plannedMediaMutations"))
        XCTAssertEqual(
            editor.components(separatedBy: "try modelContext.save()").count - 1,
            1
        )
        XCTAssertTrue(editor.contains("modelContext.rollback()"))
        XCTAssertTrue(editor.contains("target.idolIDs = relationships.idols.map(\\.id)"))
        XCTAssertTrue(editor.contains("target.count = plan.draft.count"))
        XCTAssertTrue(editor.contains("if plan.draft.count == 0"))
        XCTAssertFalse(editor.contains("ChekinanaChekiRecordStore.update("))
        XCTAssertTrue(editor.contains("deleteRecord(id:"))
        XCTAssertFalse(editor.contains("ChekinanaMediaEventLinkStore.set("))

        let thumbnailStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaCalendarGroupMediaThumbnail")?
                .lowerBound
        )
        let thumbnailEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaCalendarGroupSummary",
            range: thumbnailStart..<source.endIndex
        )?.lowerBound)
        let thumbnail = String(source[thumbnailStart..<thumbnailEnd])
        XCTAssertTrue(thumbnail.contains(".scaledToFit()"))
        XCTAssertTrue(thumbnail.contains("thumbnailReference(id: douga.id)"))

        let chekiEditorStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaChekiEditorView")?.lowerBound
        )
        let chekiEditorEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaCalendarView",
            range: chekiEditorStart..<source.endIndex
        )?.lowerBound)
        let chekiEditor = String(source[chekiEditorStart..<chekiEditorEnd])
        XCTAssertFalse(chekiEditor.contains("ChekinanaChekiIndexing.nextIndex("))
        XCTAssertFalse(chekiEditor.contains("target.idx ="))
        XCTAssertFalse(chekiEditor.contains("idxText"))
        XCTAssertTrue(chekiEditor.contains("target.userAppears = userAppears"))
        XCTAssertTrue(chekiEditor.contains("gallery.save_to_photos"))
        XCTAssertTrue(chekiEditor.contains("role: .destructive"))
        XCTAssertTrue(chekiEditor.contains(".foregroundStyle(.red)"))
        XCTAssertFalse(chekiEditor.contains("ToolbarItemGroup(placement: .bottomBar)"))
        XCTAssertTrue(chekiEditor.contains(
            "@State private var confirmationLedger = ChekinanaConfirmationLedger()"
        ))
        XCTAssertTrue(chekiEditor.contains("cancellationRequiresRecovery("))

        let sharedFieldsStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaChekiEditorFields")?.lowerBound
        )
        let sharedFieldsEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaChekiRecordEditorFields",
            range: sharedFieldsStart..<source.endIndex
        )?.lowerBound)
        let sharedFields = String(source[sharedFieldsStart..<sharedFieldsEnd])
        XCTAssertFalse(sharedFields.contains("common.index_optional"))
        XCTAssertFalse(sharedFields.contains("current_index"))
        XCTAssertFalse(sharedFields.contains("idxText"))
        XCTAssertTrue(sharedFields.contains("common.favorite"))
        XCTAssertTrue(sharedFields.contains("common.posted_to_sns"))
        XCTAssertFalse(sharedFields.contains("ChekinanaQuantityControl("))
        XCTAssertTrue(sharedFields.contains("ChekinanaUserAppearsPicker("))
        XCTAssertTrue(sharedFields.contains("ChekinanaChekiEventSelectionField("))

        let fieldStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaChekiEventSelectionField")?.lowerBound
        )
        let fieldEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaAllEventSelectionView",
            range: fieldStart..<source.endIndex
        )?.lowerBound)
        let field = String(source[fieldStart..<fieldEnd])
        XCTAssertTrue(field.contains("hasResolvedSelection"))
        XCTAssertTrue(field.contains(
            "? ChekinanaProductTheme.accent : Color.secondary"
        ))
        XCTAssertFalse(field.contains(".opacity("))

        let importStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaGalleryImportEditor")?.lowerBound
        )
        let metadataStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaGalleryMetadataEditor")?.lowerBound
        )
        let noMediaStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaCalendarNoMediaRecordEditor")?.lowerBound
        )
        let metadataEnd = try XCTUnwrap(source.range(
            of: "private enum ChekinanaProductPhotoSaver",
            range: metadataStart..<source.endIndex
        )?.lowerBound)
        let groupStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaCalendarGroupEditor")?.lowerBound
        )
        let importEditor = String(source[importStart..<metadataStart])
        let metadataEditor = String(source[metadataStart..<metadataEnd])
        let noMediaEditor = String(source[noMediaStart..<groupStart])
        for editorSource in [importEditor, noMediaEditor] {
            XCTAssertTrue(editorSource.contains("ChekinanaChekiEventSelectionField("))
            XCTAssertTrue(editorSource.contains("ChekinanaMediaEventLinkStore.set("))
        }
        XCTAssertTrue(metadataEditor.contains("ChekinanaMediaMetadataEditorFields("))
        XCTAssertTrue(metadataEditor.contains("ChekinanaMediaEventLinkStore.set("))

        let mediaDetailStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaGalleryMediaDetailView")?.lowerBound
        )
        let mediaDetailEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaGalleryImportEditor",
            range: mediaDetailStart..<source.endIndex
        )?.lowerBound)
        let mediaDetail = String(source[mediaDetailStart..<mediaDetailEnd])
        XCTAssertTrue(mediaDetail.contains(
            "ChekinanaProductTheme.pageBackground.ignoresSafeArea()"
        ))
        XCTAssertFalse(mediaDetail.contains(".preferredColorScheme(.light)"))
        XCTAssertFalse(mediaDetail.contains(".padding(12)"))
        XCTAssertFalse(mediaDetail.contains(
            ".clipShape(RoundedRectangle(cornerRadius: 18"
        ))
        XCTAssertTrue(mediaDetail.contains("onSingleTap: { isEditing = true }"))
        XCTAssertTrue(mediaDetail.contains("ChekinanaEditableVideoPlayer("))
        XCTAssertTrue(mediaDetail.contains(".accessibilityAction { isEditing = true }"))
        let stagedDelete = try XCTUnwrap(metadataEditor.range(
            of: "staged = try ChekinanaGalleryMediaStore.stageFilesForDeletion("
        ))
        let mutationBoundary = try XCTUnwrap(metadataEditor.range(
            of: "do {\n                try ChekinanaMediaEventLinkStore.delete(",
            range: stagedDelete.upperBound..<metadataEditor.endIndex
        ))
        let eventLinkDelete = try XCTUnwrap(metadataEditor.range(
            of: "try ChekinanaMediaEventLinkStore.delete(",
            range: mutationBoundary.lowerBound..<metadataEditor.endIndex
        ))
        let shotTypeDelete = try XCTUnwrap(metadataEditor.range(
            of: "try ChekinanaMediaShotTypeStore.delete(",
            range: eventLinkDelete.upperBound..<metadataEditor.endIndex
        ))
        let mutationSave = try XCTUnwrap(metadataEditor.range(
            of: "try modelContext.save()",
            range: shotTypeDelete.upperBound..<metadataEditor.endIndex
        ))
        let mutationRecovery = try XCTUnwrap(metadataEditor.range(
            of: "} catch let databaseError {\n                modelContext.rollback()",
            range: mutationSave.upperBound..<metadataEditor.endIndex
        ))
        XCTAssertTrue(metadataEditor[mutationRecovery.lowerBound...].contains(
            "ChekinanaGalleryMediaStore.recordRestoreRecovery(staged)"
        ))
        XCTAssertTrue(metadataEditor[mutationRecovery.lowerBound...].contains(
            "try ChekinanaGalleryMediaStore.restoreStagedFiles(staged)"
        ))

        XCTAssertTrue(metadataEditor.contains("@State private var userAppears: Bool"))
        XCTAssertTrue(metadataEditor.contains("ChekinanaMediaShotTypeStore.set("))
        XCTAssertTrue(metadataEditor.contains("ChekinanaMediaShotTypeStore.userAppears("))
        XCTAssertTrue(metadataEditor.contains("ChekinanaMediaMetadataEditorFields("))
        XCTAssertTrue(metadataEditor.contains("gallery.save_to_photos"))
        XCTAssertTrue(metadataEditor.contains("gallery.media.editor.delete"))
    }

    func testZoomInteractionRoutesOnlyCleanTap() {
        XCTAssertTrue(
            ChekinanaZoomInteractionResolution.cleanTap.routesSingleTap
        )
        XCTAssertFalse(ChekinanaZoomInteractionResolution.pan.routesSingleTap)
        XCTAssertFalse(ChekinanaZoomInteractionResolution.pinch.routesSingleTap)
        XCTAssertFalse(
            ChekinanaZoomInteractionResolution.panAndPinch.routesSingleTap
        )
    }

    func testZoomPanGeometryClampsPanToAspectFitImageBounds() {
        let imageSize = CGSize(width: 100, height: 200)
        let viewport = CGSize(width: 300, height: 300)

        XCTAssertEqual(
            ChekinanaZoomPanGeometry.aspectFitSize(
                imageSize: imageSize,
                viewportSize: viewport
            ),
            CGSize(width: 150, height: 300)
        )
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.clampedOffset(
                CGSize(width: 80, height: -90),
                imageSize: imageSize,
                viewportSize: viewport,
                scale: 1
            ),
            .zero
        )
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.clampedOffset(
                CGSize(width: 500, height: -500),
                imageSize: imageSize,
                viewportSize: viewport,
                scale: 2
            ),
            CGSize(width: 0, height: -150)
        )
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.clampedOffset(
                CGSize(width: 500, height: -500),
                imageSize: imageSize,
                viewportSize: viewport,
                scale: 4
            ),
            CGSize(width: 150, height: -450)
        )

        let landscapeImage = CGSize(width: 200, height: 100)
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.aspectFitSize(
                imageSize: landscapeImage,
                viewportSize: viewport
            ),
            CGSize(width: 300, height: 150)
        )
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.clampedOffset(
                CGSize(width: 500, height: 200),
                imageSize: landscapeImage,
                viewportSize: viewport,
                scale: 2
            ),
            CGSize(width: 150, height: 0)
        )
    }

    func testZoomPanGeometryKeepsPinchAnchorStableAndResetsAtOneX() {
        let viewport = CGSize(width: 300, height: 300)
        let zoomedOffset = ChekinanaZoomPanGeometry.offsetKeepingAnchorFixed(
            .zero,
            from: 1,
            to: 2,
            anchor: .topLeading,
            viewportSize: viewport
        )
        XCTAssertEqual(zoomedOffset, CGSize(width: 150, height: 150))

        let resetOffset = ChekinanaZoomPanGeometry.offsetKeepingAnchorFixed(
            zoomedOffset,
            from: 2,
            to: 1,
            anchor: .topLeading,
            viewportSize: viewport
        )
        XCTAssertEqual(resetOffset, .zero)
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.clampedOffset(
                zoomedOffset,
                imageSize: viewport,
                viewportSize: viewport,
                scale: 1
            ),
            .zero
        )
        XCTAssertEqual(ChekinanaZoomPanGeometry.clampedScale(0.2), 1)
        XCTAssertEqual(ChekinanaZoomPanGeometry.clampedScale(8), 4)
    }

    func testZoomPanGeometryRejectsZeroAndNonFiniteInputs() {
        let validSize = CGSize(width: 300, height: 200)
        let invalidSizes = [
            CGSize.zero,
            CGSize(width: 0, height: 200),
            CGSize(width: 300, height: 0),
            CGSize(width: CGFloat.nan, height: 200),
            CGSize(width: 300, height: CGFloat.infinity),
        ]

        for invalid in invalidSizes {
            XCTAssertEqual(
                ChekinanaZoomPanGeometry.aspectFitSize(
                    imageSize: invalid,
                    viewportSize: validSize
                ),
                .zero
            )
            XCTAssertEqual(
                ChekinanaZoomPanGeometry.aspectFitSize(
                    imageSize: validSize,
                    viewportSize: invalid
                ),
                .zero
            )
            XCTAssertEqual(
                ChekinanaZoomPanGeometry.clampedOffset(
                    CGSize(width: 20, height: 20),
                    imageSize: invalid,
                    viewportSize: validSize,
                    scale: 2
                ),
                .zero
            )
            XCTAssertEqual(
                ChekinanaZoomPanGeometry.clampedOffset(
                    CGSize(width: 20, height: 20),
                    imageSize: validSize,
                    viewportSize: invalid,
                    scale: 2
                ),
                .zero
            )
        }

        XCTAssertEqual(ChekinanaZoomPanGeometry.clampedScale(.nan), 1)
        XCTAssertEqual(ChekinanaZoomPanGeometry.clampedScale(.infinity), 1)
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.clampedOffset(
                CGSize(width: CGFloat.infinity, height: 10),
                imageSize: validSize,
                viewportSize: validSize,
                scale: 2
            ),
            .zero
        )
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.clampedOffset(
                CGSize(width: 10, height: 10),
                imageSize: validSize,
                viewportSize: validSize,
                scale: .nan
            ),
            .zero
        )
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.offsetKeepingAnchorFixed(
                CGSize(width: CGFloat.nan, height: 10),
                from: 1,
                to: 2,
                anchor: .center,
                viewportSize: validSize
            ),
            .zero
        )
        XCTAssertEqual(
            ChekinanaZoomPanGeometry.offsetKeepingAnchorFixed(
                .zero,
                from: 1,
                to: 2,
                anchor: UnitPoint(x: CGFloat.nan, y: 0.5),
                viewportSize: validSize
            ),
            .zero
        )
        let normalizedScaleOffset = ChekinanaZoomPanGeometry
            .offsetKeepingAnchorFixed(
                CGSize(width: 12, height: -8),
                from: .nan,
                to: .infinity,
                anchor: .center,
                viewportSize: validSize
            )
        XCTAssertTrue(normalizedScaleOffset.width.isFinite)
        XCTAssertTrue(normalizedScaleOffset.height.isFinite)
    }

    func testCalendarBatchWriterCreatesOnlySimpleRecordsAndAutoLinksUniqueEvent() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV8.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Record Idol")
        let day = utcDate(2026, 8, 24)
        let event = Event(name: "Same Day", date: day)
        context.insert(idol)
        context.insert(event)
        try context.save()

        let ids = try ChekinanaCalendarRecordBatchWriter.commit(
            .init(
                kind: .cheki,
                idolIDs: [idol.id],
                date: day,
                quantity: 2,
                manualStart: nil,
                note: "record note",
                eventID: nil
            ),
            in: context
        )
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Cheki>()), 0)
        let records = try context.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 1)
        for record in records {
            XCTAssertEqual(record.count, 2)
            XCTAssertEqual(record.date, day)
            XCTAssertEqual(record.size, .mini)
            XCTAssertEqual(record.note, "record note")
            XCTAssertEqual(Set(record.idols.map(\.id)), [idol.id])
            XCTAssertEqual(record.event?.id, event.id)
        }
    }

    func testCalendarBatchWriterPersistsEverySelectedIdolOnce() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV8.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let context = ModelContext(container)
        let first = Idol(name: "First selected Idol")
        let second = Idol(name: "Second selected Idol")
        context.insert(first)
        context.insert(second)
        try context.save()

        let insertedIDs = try ChekinanaCalendarRecordBatchWriter.commit(
            .init(
                kind: .cheki,
                idolIDs: [first.id, second.id],
                date: utcDate(2026, 8, 25),
                quantity: 3,
                manualStart: nil,
                note: "multi Idol",
                eventID: nil
            ),
            in: context
        )

        XCTAssertEqual(insertedIDs.count, 1)
        let record = try XCTUnwrap(
            context.fetch(FetchDescriptor<ChekiRecord>()).first
        )
        XCTAssertEqual(record.count, 3)
        XCTAssertEqual(Set(record.idolIDs), [first.id, second.id])
        XCTAssertEqual(Set(record.idols.map(\.id)), [first.id, second.id])
    }

    func testRequiredIdolSelectionRejectsClearedAndResolvesVisibleUniqueIDs() {
        let first = UUID()
        let second = UUID()
        let hidden = UUID()

        XCTAssertTrue(ChekinanaRequiredIdolSelectionPolicy.resolvedIDs(
            selectedIDs: [],
            visibleIDs: [first, second]
        ).isEmpty)
        XCTAssertEqual(
            ChekinanaRequiredIdolSelectionPolicy.resolvedIDs(
                selectedIDs: [hidden, second, first],
                visibleIDs: [first, first, second]
            ),
            [first, second]
        )
    }

    func testCalendarBatchWriterPersistsSelectedSizeAndKeepsItInRecordIdentity() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Sized Record Idol")
        let day = utcDate(2026, 8, 24)
        context.insert(idol)
        try context.save()

        let inputs: [(size: ChekiSize?, quantity: Int)] = [
            (.wide, 2),
            (nil, 3),
            (.wide, 1),
        ]
        for (size, quantity) in inputs {
            _ = try ChekinanaCalendarRecordBatchWriter.commit(
                .init(
                    kind: .cheki,
                    idolIDs: [idol.id],
                    date: day,
                    quantity: quantity,
                    manualStart: nil,
                    note: "same identity except size",
                    eventID: nil,
                    size: size
                ),
                in: context
            )
        }

        let records = try context.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first(where: { $0.size == .wide })?.count, 3)
        XCTAssertEqual(records.first(where: { $0.size == nil })?.count, 3)
    }

    func testChekiRecordStoreUpsertsOrderlessIdentityAndDeletesAtZero() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let first = Idol(name: "First")
        let second = Idol(name: "Second")
        let day = utcDate(2026, 8, 24)
        let event = Event(name: "Event", date: day)
        context.insert(first)
        context.insert(second)
        context.insert(event)

        let created = try ChekinanaChekiRecordStore.upsert(
            idols: [first, second],
            event: event,
            date: day.addingTimeInterval(60 * 60),
            size: .mini,
            note: "same",
            adding: 2,
            in: context
        )
        let merged = try ChekinanaChekiRecordStore.upsert(
            idols: [second, first],
            event: event,
            date: day,
            size: .mini,
            note: "same",
            adding: 3,
            in: context
        )
        XCTAssertEqual(created.id, merged.id)
        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(merged.date, day)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChekiRecord>()), 1)

        XCTAssertNil(try ChekinanaChekiRecordStore.update(
            merged,
            idols: [first, second],
            event: event,
            date: day,
            size: .mini,
            note: "same",
            count: 0,
            in: context
        ))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChekiRecord>()), 0)
    }

    func testChekiRecordStoreCountOverflowRollsBackWithoutChangingRecord() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Overflow")
        let day = utcDate(2026, 8, 24)
        let record = ChekiRecord(
            idols: [idol],
            date: day,
            size: .mini,
            note: "same",
            count: Int.max
        )
        context.insert(idol)
        context.insert(record)
        try context.save()

        XCTAssertThrowsError(try ChekinanaChekiRecordStore.upsert(
            idols: [idol],
            event: nil,
            date: day,
            size: .mini,
            note: "same",
            adding: 1,
            in: context
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaChekiRecordMutationError,
                .quantityOverflow
            )
        }
        let reopened = ModelContext(container)
        let records = try reopened.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.count, Int.max)
    }

    func testIdolLinkedEventCountIncludesCurrentIdolMediaAndSimpleRecords() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let context = ModelContext(container)
        let target = Idol(name: "Target")
        let other = Idol(name: "Other")
        let event = Event(name: "Shared")
        let recordOnlyEvent = Event(name: "Record only")
        let otherRecordOnlyEvent = Event(name: "Other record only")
        context.insert(target)
        context.insert(other)
        context.insert(event)
        context.insert(recordOnlyEvent)
        context.insert(otherRecordOnlyEvent)
        let targetMedia = Cheki(imageRef: "target.jpg")
        let multiMedia = Cheki(imageRef: "multi.jpg")
        let otherMedia = Cheki(imageRef: "other.jpg")
        for value in [targetMedia, multiMedia, otherMedia] {
            context.insert(value)
            value.event = event
        }
        targetMedia.idols = [target]
        multiMedia.idols = [target, other]
        otherMedia.idols = [other]
        let targetSimple = ChekiRecord(idols: [target], event: event, count: 4)
        let multiSimple = ChekiRecord(idols: [target, other], event: event, count: 2)
        let otherSimple = ChekiRecord(idols: [other], event: event)
        let targetRecordOnly = ChekiRecord(idols: [target], event: recordOnlyEvent)
        let otherRecordOnly = ChekiRecord(idols: [other], event: otherRecordOnlyEvent)
        let simpleRecords = [
            targetSimple,
            multiSimple,
            otherSimple,
            targetRecordOnly,
            otherRecordOnly,
        ]
        for record in simpleRecords { context.insert(record) }
        try context.save()
        let relationshipIndex = ChekinanaChekiRecordRelationshipIndex(
            idols: [target, other],
            events: [event, recordOnlyEvent, otherRecordOnlyEvent]
        )

        XCTAssertEqual(
            Set(ChekinanaIdolLinkedEventCount.linkedEvents(
                mediaChekis: [targetMedia, multiMedia, otherMedia],
                simpleRecords: simpleRecords,
                relationshipIndex: relationshipIndex,
                idolID: target.id,
                hiddenIDs: []
            ).map(\.id)),
            [event.id, recordOnlyEvent.id]
        )

        XCTAssertEqual(
            ChekinanaIdolLinkedEventCount.chekiCount(
                event: event,
                simpleRecords: simpleRecords,
                idolID: target.id,
                hiddenIDs: []
            ),
            9
        )
        XCTAssertEqual(
            ChekinanaIdolLinkedEventCount.chekiCount(
                event: event,
                simpleRecords: simpleRecords,
                idolID: other.id,
                hiddenIDs: []
            ),
            5
        )
        XCTAssertEqual(
            ChekinanaIdolLinkedEventCount.chekiCount(
                event: recordOnlyEvent,
                simpleRecords: simpleRecords,
                idolID: target.id,
                hiddenIDs: []
            ),
            1
        )
        XCTAssertEqual(
            ChekinanaIdolLinkedEventCount.chekiCount(
                event: recordOnlyEvent,
                simpleRecords: simpleRecords,
                idolID: other.id,
                hiddenIDs: []
            ),
            0
        )
        XCTAssertEqual(
            Set(ChekinanaIdolEventChekiScope.mediaChekis(
                event: event,
                idolID: target.id,
                hiddenIDs: []
            ).map(\.id)),
            [targetMedia.id, multiMedia.id]
        )
        XCTAssertEqual(
            Set(ChekinanaIdolEventChekiScope.simpleRecords(
                simpleRecords,
                eventID: event.id,
                idolID: target.id,
                hiddenIDs: []
            ).map(\.id)),
            [targetSimple.id, multiSimple.id]
        )
        XCTAssertEqual(
            ChekinanaIdolEventChekiScope.mediaChekis(
                event: event,
                idolID: target.id,
                hiddenIDs: [other.id]
            ).map(\.id),
            [targetMedia.id]
        )
        XCTAssertEqual(
            ChekinanaIdolEventChekiScope.simpleRecords(
                simpleRecords,
                eventID: event.id,
                idolID: target.id,
                hiddenIDs: [other.id]
            ).map(\.id),
            [targetSimple.id]
        )
        XCTAssertEqual(
            ChekinanaIdolLinkedEventCount.chekiCount(
                event: event,
                simpleRecords: simpleRecords,
                idolID: target.id,
                hiddenIDs: [other.id]
            ),
            5
        )
        XCTAssertEqual(
            ChekinanaIdolLinkedEventCount.chekiCount(
                event: event,
                simpleRecords: simpleRecords,
                idolID: target.id,
                hiddenIDs: [target.id]
            ),
            0
        )
        XCTAssertEqual(
            Set(ChekinanaIdolLinkedEventCount.linkedEvents(
                mediaChekis: [targetMedia, multiMedia, otherMedia],
                simpleRecords: simpleRecords,
                relationshipIndex: relationshipIndex,
                idolID: target.id,
                hiddenIDs: [target.id]
            ).map(\.id)),
            []
        )
    }

    func testEventChekiCountAddsMediaAndSimpleRecordQuantities() {
        let event = Event(name: "Counted Event")
        let idol = Idol(name: "Visible")
        let media = Cheki(idols: [idol], event: event, imageRef: "media.jpg")
        let first = ChekiRecord(idols: [idol], event: event, count: 2)
        let second = ChekiRecord(idols: [idol], event: event, count: 3)

        XCTAssertEqual(
            ChekinanaEventChekiCount.total(
                eventID: event.id,
                mediaChekis: [media],
                simpleRecords: [first, second],
                hiddenIDs: []
            ),
            6
        )
    }

    func testEventChekiCountExcludesMediaAndRecordsLinkedToHiddenIdols() {
        let event = Event(name: "Visibility Event")
        let visible = Idol(name: "Visible")
        let hidden = Idol(name: "Hidden")
        let visibleMedia = Cheki(idols: [visible], event: event, imageRef: "visible.jpg")
        let hiddenMedia = Cheki(idols: [hidden], event: event, imageRef: "hidden.jpg")
        let visibleRecord = ChekiRecord(idols: [visible], event: event, count: 2)
        let hiddenRecord = ChekiRecord(idols: [hidden], event: event, count: 9)

        XCTAssertEqual(
            ChekinanaEventChekiCount.total(
                eventID: event.id,
                mediaChekis: [visibleMedia, hiddenMedia],
                simpleRecords: [visibleRecord, hiddenRecord],
                hiddenIDs: [hidden.id]
            ),
            3
        )
    }

    func testEventRemainingDaysUsesLocalCalendarDaysAcrossBoundariesAndDST() {
        func date(
            _ year: Int,
            _ month: Int,
            _ day: Int,
            _ hour: Int,
            _ minute: Int,
            calendar: Calendar
        ) -> Date {
            calendar.date(from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            ))!
        }

        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let sameDayNow = date(2026, 8, 25, 0, 1, calendar: shanghai)
        let sameDayEvent = date(2026, 8, 25, 23, 59, calendar: shanghai)
        let beforeMidnight = date(2026, 8, 25, 23, 59, calendar: shanghai)
        let afterMidnight = date(2026, 8, 26, 0, 1, calendar: shanghai)
        XCTAssertEqual(
            ChekinanaEventListPresentation.remainingDays(
                until: sameDayEvent,
                from: sameDayNow,
                calendar: shanghai
            ),
            0
        )
        XCTAssertEqual(
            ChekinanaEventListPresentation.remainingDays(
                until: afterMidnight,
                from: beforeMidnight,
                calendar: shanghai
            ),
            1
        )
        XCTAssertEqual(
            ChekinanaEventListPresentation.remainingDays(
                until: date(2027, 1, 1, 0, 1, calendar: shanghai),
                from: date(2026, 12, 31, 23, 59, calendar: shanghai),
                calendar: shanghai
            ),
            1
        )

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(
            ChekinanaEventListPresentation.remainingDays(
                until: date(2026, 3, 9, 0, 5, calendar: losAngeles),
                from: date(2026, 3, 7, 23, 55, calendar: losAngeles),
                calendar: losAngeles
            ),
            2
        )
    }

    func testEventListCityRemovesOnlyOneTrailingMunicipalitySuffix() {
        XCTAssertEqual(ChekinanaEventListPresentation.displayedCity("上海市"), "上海")
        XCTAssertEqual(ChekinanaEventListPresentation.displayedCity("横浜市市"), "横浜市")
        XCTAssertEqual(ChekinanaEventListPresentation.displayedCity("市中心"), "市中心")
        XCTAssertEqual(
            ChekinanaEventListPresentation.displayedCity("北京市朝阳区"),
            "北京市朝阳区"
        )
        XCTAssertNil(ChekinanaEventListPresentation.displayedCity("市"))
        XCTAssertNil(ChekinanaEventListPresentation.displayedCity("  "))
    }

    func testEventListUsesLocalizedCountdownOnlyForUpcomingRows() throws {
        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private struct ChekinanaEventsView")?.lowerBound
        )
        let end = try XCTUnwrap(source.range(
            of: "private struct ChekinanaEventDetailView",
            range: start..<source.endIndex
        )?.lowerBound)
        let eventsView = source[start..<end]
        XCTAssertTrue(eventsView.contains(
            "events: future,\n                                showsRemainingDays: true"
        ))
        XCTAssertTrue(eventsView.contains(
            "events: past,\n                                showsRemainingDays: false"
        ))
        XCTAssertTrue(eventsView.contains(
            "events: undated,\n                                showsRemainingDays: false"
        ))
        XCTAssertTrue(eventsView.contains(
            "if showsRemainingDays, let date = event.date"
        ))
        XCTAssertTrue(eventsView.contains(
            "return ChekinanaEventListPresentation.remainingDaysLabel(dayDifference)"
        ))
        XCTAssertTrue(eventsView.contains(
            "return ChekinanaRecordKind.cheki.countLabel(chekiCount(event))"
        ))

        let localizationURL = productSourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Localizable.xcstrings")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: localizationURL))
                as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        func value(_ key: String, _ locale: String) throws -> String {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
            return try XCTUnwrap(unit["value"] as? String)
        }
        XCTAssertEqual(try value("product.events.remaining_days.today", "en"), "Today")
        XCTAssertEqual(try value("product.events.remaining_days.today", "ja"), "今日")
        XCTAssertEqual(try value("product.events.remaining_days.today", "zh-Hans"), "今天")
        XCTAssertEqual(
            try value("product.events.remaining_days.tomorrow", "en"),
            "Tomorrow"
        )
        XCTAssertEqual(try value("product.events.remaining_days.tomorrow", "ja"), "明日")
        XCTAssertEqual(
            try value("product.events.remaining_days.tomorrow", "zh-Hans"),
            "明天"
        )
        XCTAssertEqual(
            try value("product.events.remaining_days.future", "en"),
            "In %lld days"
        )
        XCTAssertEqual(
            try value("product.events.remaining_days.future", "ja"),
            "あと%lld日"
        )
        XCTAssertEqual(
            try value("product.events.remaining_days.future", "zh-Hans"),
            "还有%lld天"
        )
        XCTAssertEqual(
            try value("product.calendar.edit_cheki_records", "ja"),
            "チェキ記録を編集"
        )
        XCTAssertEqual(
            try value("record.kind_count.shame.other", "ja"),
            "写メ%lld枚"
        )
        XCTAssertEqual(
            try value("record.kind_count.shame.other", "zh-Hans"),
            "%lld张手机合影"
        )
        XCTAssertEqual(
            try value("record.kind_count.douga.other", "ja"),
            "動画%lld本"
        )
        XCTAssertEqual(
            try value("record.kind_count.douga.other", "zh-Hans"),
            "%lld个视频"
        )
    }

    func testEventSimpleRecordOnlyContentBuildsEditableNonemptyGroup() throws {
        let event = Event(name: "Record-only Event")
        let idol = Idol(name: "Record Idol")
        let record = ChekiRecord(idols: [idol], event: event, count: 4)
        let visibleRecords = ChekinanaEventChekiCount.visibleRecords(
            [record],
            eventID: event.id,
            hiddenIDs: []
        )
        let groups = ChekinanaCalendarIdolGroup.groups(
            for: [],
            records: visibleRecords,
            relationshipIndex: .init(idols: [idol], events: [event])
        )

        XCTAssertEqual(
            ChekinanaEventChekiCount.total(
                eventID: event.id,
                mediaChekis: [],
                simpleRecords: [record],
                hiddenIDs: []
            ),
            4
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].records.map(\.id), [record.id])
        XCTAssertEqual(
            ChekinanaCalendarIdolGroupRouting.primaryRoute(for: groups[0]),
            .groupEditor([record.id])
        )

        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let detailStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaEventDetailView")?.lowerBound
        )
        let detailEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaEventChekiGroupView",
            range: detailStart..<source.endIndex
        )?.lowerBound)
        let detail = source[detailStart..<detailEnd]
        let branchSelection = try XCTUnwrap(
            detail.range(of: "selectRecord: { selectedChekiRecord = $0 }")
        )
        let commonSheet = try XCTUnwrap(
            detail.range(of: ".sheet(item: $selectedChekiRecord)")
        )
        let branchModifierEnd = try XCTUnwrap(
            detail.range(of: ".onChange(of: chekiGroups.map(\\.id))")
        )
        XCTAssertLessThan(branchSelection.lowerBound, commonSheet.lowerBound)
        XCTAssertLessThan(branchModifierEnd.lowerBound, commonSheet.lowerBound)
        XCTAssertEqual(
            detail.components(separatedBy: ".sheet(item: $selectedChekiRecord)").count - 1,
            1
        )
        XCTAssertTrue(detail.contains("ChekinanaChekiRecordEditor(record: record)"))
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

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let graphicalLeapDay = try XCTUnwrap(
            ChekinanaBirthdayEditorPolicy.unknownYearDate(
                month: 2,
                day: 29,
                calendar: calendar
            )
        )
        XCTAssertEqual(
            ChekinanaBirthdayEditorPolicy.unknownYearMonthDay(
                from: graphicalLeapDay,
                calendar: calendar
            )?.month,
            2
        )
        XCTAssertEqual(
            ChekinanaBirthdayEditorPolicy.unknownYearMonthDay(
                from: graphicalLeapDay,
                calendar: calendar
            )?.day,
            29
        )
        let graphicalRange = ChekinanaBirthdayEditorPolicy.unknownYearRange(
            calendar: calendar
        )
        XCTAssertTrue(graphicalRange.contains(graphicalLeapDay))

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

    func testSimpleChekiRecordBatchIncreaseDecreaseAndNoteUseLiveContext() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Batch Idol")
        let date = utcDate(2026, 8, 2)
        let event = Event(name: "Batch Event", date: date)
        setup.insert(idol)
        setup.insert(event)
        let first = ChekiRecord(
            date: date,
            size: .wide,
            note: "same"
        )
        let second = ChekiRecord(
            date: date,
            size: .wide,
            note: "same"
        )
        let unrelated = ChekiRecord(
            date: date,
            size: .wide,
            note: "different"
        )
        for record in [first, second, unrelated] {
            setup.insert(record)
            record.idols = [idol]
            record.event = event
        }
        try setup.save()

        let draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [first.id, second.id],
            allRecords: try setup.fetch(FetchDescriptor<ChekiRecord>())
        )
        let insertedGroupIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            draft,
            quantity: 4,
            note: "updated",
            in: ModelContext(container)
        )
        XCTAssertEqual(insertedGroupIDs.count, 1)

        let afterIncrease = ModelContext(container)
        let increased = try afterIncrease.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(increased.count, 2)
        let selectedAfterIncrease = increased.filter { insertedGroupIDs.contains($0.id) }
        XCTAssertEqual(selectedAfterIncrease.count, 1)
        XCTAssertTrue(selectedAfterIncrease.allSatisfy {
            $0.note == "updated"
                && $0.count == 4
                && $0.event?.id == event.id
                && $0.idols.map(\.id) == [idol.id]
                && $0.sizeRawValue == ChekiSize.wide.rawValue
        })
        XCTAssertEqual(
            increased.first(where: { $0.id == unrelated.id })?.note,
            "different"
        )

        let decreaseDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: insertedGroupIDs,
            allRecords: increased
        )
        let retainedIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            decreaseDraft,
            quantity: 2,
            note: "final",
            in: ModelContext(container)
        )
        XCTAssertEqual(retainedIDs, insertedGroupIDs)
        let final = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(final.count, 2)
        XCTAssertTrue(final.filter { retainedIDs.contains($0.id) }.allSatisfy {
            $0.note == "final" && $0.count == 2
        })
        XCTAssertEqual(final.first(where: { $0.id == unrelated.id })?.note, "different")

        let deleteDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: retainedIDs,
            allRecords: final
        )
        XCTAssertTrue(try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            deleteDraft,
            quantity: 0,
            note: "final",
            in: ModelContext(container)
        ).isEmpty)
        let afterZero = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(afterZero.map(\.id), [unrelated.id])
    }

    func testSimpleChekiRecordBatchKeepsExplicitEventOutsideNearbyDateWindow() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Cross-range Batch Idol")
        let recordDate = utcDate(2026, 8, 2)
        let event = Event(name: "Explicit distant Event", date: utcDate(2026, 9, 20))
        let record = ChekiRecord(
            idols: [idol],
            event: event,
            date: recordDate,
            size: .mini,
            note: "before",
            count: 1
        )
        setup.insert(idol)
        setup.insert(event)
        setup.insert(record)
        try setup.save()

        let draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [record.id],
            allRecords: try setup.fetch(FetchDescriptor<ChekiRecord>())
        )
        let retainedIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            draft,
            quantity: 4,
            note: "after",
            in: ModelContext(container)
        )

        XCTAssertEqual(retainedIDs, [record.id])
        let saved = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<ChekiRecord>()).first
        )
        XCTAssertEqual(saved.eventID, event.id)
        XCTAssertEqual(saved.count, 4)
        XCTAssertEqual(saved.note, "after")
        XCTAssertEqual(saved.date, recordDate)
    }

    func testSimpleChekiRecordBatchUndatedRejectsLateMutation() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Undated Batch")
        setup.insert(idol)
        let createdAt = utcDate(2026, 8, 2)
        let first = ChekiRecord(note: "same")
        let second = ChekiRecord(note: "same")
        let otherBlock = ChekiRecord(note: "other")
        let media = Cheki(
            imageRef: "managed-existing.jpg",
            note: "media",
            createdAt: createdAt.addingTimeInterval(3)
        )
        for record in [first, second, otherBlock] {
            setup.insert(record)
            record.idols = [idol]
        }
        setup.insert(media)
        media.idols = [idol]
        try setup.save()

        let staleDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [first.id, second.id],
            allRecords: try setup.fetch(FetchDescriptor<ChekiRecord>())
        )
        let lateContext = ModelContext(container)
        let lateOther = try XCTUnwrap(
            lateContext.fetch(FetchDescriptor<ChekiRecord>()).first { $0.id == otherBlock.id }
        )
        lateOther.note = "late mutation"
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
        let afterRejected = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(afterRejected.count, 3)

        let freshDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [first.id, second.id],
            allRecords: afterRejected
        )
        let increasedIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            freshDraft,
            quantity: 4,
            note: "updated",
            in: ModelContext(container)
        )
        XCTAssertEqual(increasedIDs.count, 1)
        let afterIncrease = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(afterIncrease.count, 2)
        XCTAssertTrue(afterIncrease.allSatisfy { $0.date == nil })
        XCTAssertTrue(afterIncrease.filter { increasedIDs.contains($0.id) }.allSatisfy {
            $0.note == "updated" && $0.count == 4
        })
        XCTAssertEqual(
            afterIncrease.first(where: { $0.id == otherBlock.id })?.note,
            "late mutation"
        )
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<Cheki>()).first?.imageRef,
            "managed-existing.jpg"
        )

        let decreaseDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: increasedIDs,
            allRecords: afterIncrease
        )
        let retainedIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            decreaseDraft,
            quantity: 2,
            note: "final",
            in: ModelContext(container)
        )
        XCTAssertEqual(retainedIDs.count, 1)
        let final = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(final.count, 2)
        XCTAssertTrue(final.allSatisfy { $0.date == nil })
        XCTAssertTrue(final.filter { retainedIDs.contains($0.id) }.allSatisfy {
            $0.note == "final" && $0.count == 2
        })
    }

    func testSimpleChekiRecordBatchNoteCollisionReturnsMergedIdentityForSecondEdit() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Merge Batch")
        setup.insert(idol)
        let date = utcDate(2026, 8, 2)
        let sourceFirst = ChekiRecord(date: date, note: "source")
        let sourceSecond = ChekiRecord(date: date, note: "source")
        let targetFirst = ChekiRecord(date: date, note: "target")
        let targetSecond = ChekiRecord(date: date, note: "target")
        for record in [sourceFirst, sourceSecond, targetFirst, targetSecond] {
            setup.insert(record)
            record.idols = [idol]
        }
        try setup.save()

        let sourceDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [sourceFirst.id, sourceSecond.id],
            allRecords: try setup.fetch(FetchDescriptor<ChekiRecord>())
        )
        let mergedIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            sourceDraft,
            quantity: 3,
            note: "target",
            in: ModelContext(container)
        )
        XCTAssertEqual(mergedIDs.count, 1)
        let afterMerge = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(afterMerge.count, 1)
        XCTAssertEqual(afterMerge.first?.note, "target")
        XCTAssertEqual(afterMerge.first?.count, 5)

        let secondDraft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: mergedIDs,
            allRecords: afterMerge
        )
        XCTAssertEqual(secondDraft.quantity, 5)
        let secondEditIDs = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            secondDraft,
            quantity: 4,
            note: "target",
            in: ModelContext(container)
        )
        XCTAssertEqual(secondEditIDs.count, 1)
        let final = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.note, "target")
        XCTAssertEqual(final.first?.count, 4)
    }

    func testLargeImportedRecordCanReopenSaveUnchangedAndAcceptDirectInput() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Imported quantity")
        let record = ChekiRecord(
            idols: [idol],
            date: utcDate(2026, 8, 24),
            size: .mini,
            note: "imported",
            count: 150
        )
        setup.insert(idol)
        setup.insert(record)
        try setup.save()

        var reopened = ModelContext(container)
        var live = try XCTUnwrap(
            reopened.fetch(FetchDescriptor<ChekiRecord>()).first
        )
        var draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [live.id],
            allRecords: [live]
        )
        XCTAssertEqual(draft.quantity, 150)
        _ = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            draft,
            quantity: 150,
            note: "imported",
            in: reopened
        )

        reopened = ModelContext(container)
        live = try XCTUnwrap(reopened.fetch(FetchDescriptor<ChekiRecord>()).first)
        XCTAssertEqual(live.count, 150)
        draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [live.id],
            allRecords: [live]
        )
        _ = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
            draft,
            quantity: 250,
            note: "imported",
            in: reopened
        )

        let final = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.count, 250)
    }

    func testSimpleChekiRecordBatchIdentityUsesOnlyRecordBusinessFields() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Identity")
        let otherIdol = Idol(name: "Other")
        let date = utcDate(2026, 8, 2)
        let event = Event(name: "Event")
        context.insert(idol)
        context.insert(otherIdol)
        context.insert(event)
        let values = [
            ChekiRecord(date: date, size: .mini, note: "same"),
            ChekiRecord(date: date, size: .mini, note: "same"),
            ChekiRecord(date: date, size: .wide, note: "same"),
            ChekiRecord(date: date, size: .mini, note: "different"),
            ChekiRecord(date: nil, size: .mini, note: "same"),
            ChekiRecord(date: date, size: .mini, note: "same"),
        ]
        for value in values {
            context.insert(value)
            value.idols = [idol]
        }
        values[1].event = event
        values[5].idols = [otherIdol]
        try context.save()
        XCTAssertEqual(Set(values.compactMap(ChekinanaIdolNoMediaChekiIdentity.init)).count, 6)
        let draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [values[0].id],
            allRecords: values
        )
        XCTAssertEqual(draft.quantity, 1)
        XCTAssertEqual(draft.selectedRecordIDs, [values[0].id])
    }

    func testSimpleChekiRecordBatchRejectsLateMutationWithoutPartialWrite() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Late")
        setup.insert(idol)
        let date = utcDate(2026, 8, 2)
        let first = ChekiRecord(date: date, note: "same")
        let second = ChekiRecord(date: date, note: "same")
        for value in [first, second] {
            setup.insert(value)
            value.idols = [idol]
        }
        try setup.save()
        let draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
            selectedRecordIDs: [first.id, second.id],
            allRecords: try setup.fetch(FetchDescriptor<ChekiRecord>())
        )
        let lateContext = ModelContext(container)
        let late = try XCTUnwrap(
            lateContext.fetch(FetchDescriptor<ChekiRecord>()).first { $0.id == first.id }
        )
        late.note = "late mutation"
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
        let final = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(final.count, 2)
        XCTAssertEqual(final.first(where: { $0.id == first.id })?.note, "late mutation")
        XCTAssertEqual(final.first(where: { $0.id == second.id })?.note, "same")
    }

    func testGalleryShotFilterCyclesAllSoloTwoShotAndTreatsNilAsSolo() {
        XCTAssertTrue(ChekinanaGalleryShotFilter.all.includes(nil))
        XCTAssertTrue(ChekinanaGalleryShotFilter.all.includes(false))
        XCTAssertTrue(ChekinanaGalleryShotFilter.all.includes(true))
        XCTAssertTrue(ChekinanaGalleryShotFilter.solo.includes(nil))
        XCTAssertTrue(ChekinanaGalleryShotFilter.solo.includes(false))
        XCTAssertFalse(ChekinanaGalleryShotFilter.solo.includes(true))
        XCTAssertFalse(ChekinanaGalleryShotFilter.twoShot.includes(nil))
        XCTAssertFalse(ChekinanaGalleryShotFilter.twoShot.includes(false))
        XCTAssertTrue(ChekinanaGalleryShotFilter.twoShot.includes(true))
        XCTAssertEqual(ChekinanaGalleryShotFilter.all.next, .solo)
        XCTAssertEqual(ChekinanaGalleryShotFilter.solo.next, .twoShot)
        XCTAssertEqual(ChekinanaGalleryShotFilter.twoShot.next, .all)
        XCTAssertEqual(
            ChekinanaGalleryShotFilter.allCases.map(\.rawValue),
            ["all", "solo", "two-shot"]
        )
    }

    func testGallerySixSlotCopyUsesExplicitDateAndIdolOrderInAllLanguages() throws {
        let expectations: [String: [String]] = [
            "en": ["Idols", "Favorite", "Date range", "Oldest first", "Newest first", "Idol order", "All", "solo", "2-shot"],
            "zh-Hans": ["偶像", "收藏", "日期范围", "最早优先", "最新优先", "偶像顺序", "全部", "单人", "双人"],
            "ja": ["アイドル", "お気に入り", "期間", "古い順", "新しい順", "アイドル順", "すべて", "ソロ", "2ショット"],
        ]
        for (language, expected) in expectations {
            let bundle = try localizedAppBundle(language: language)
            XCTAssertEqual([
                ChekinanaProductCopy.text("gallery.filter.idols", "Idols", bundle: bundle),
                ChekinanaProductCopy.text("common.favorite", "Favorite", bundle: bundle),
                ChekinanaProductCopy.text("gallery.date_filter", "Date range", bundle: bundle),
                ChekinanaProductCopy.text("gallery.sort.time.ascending", "Oldest first", bundle: bundle),
                ChekinanaProductCopy.text("gallery.sort.time.descending", "Newest first", bundle: bundle),
                ChekinanaProductCopy.text("gallery.sort.idol", "Idol order", bundle: bundle),
                ChekinanaProductCopy.text("gallery.shot_filter.all", "All", bundle: bundle),
                ChekinanaProductCopy.text("gallery.shot_filter.solo", "solo", bundle: bundle),
                ChekinanaProductCopy.text("gallery.shot_filter.two_shot", "2-shot", bundle: bundle),
            ], expected, language)
        }
    }

    func testGalleryFilterBarHasSixFixedSlotsThatFitNarrowPhoneContent() {
        XCTAssertEqual(
            ChekinanaGalleryFilterBarPolicy.slots,
            [.idol, .favorite, .dateRange, .dateOrder, .idolOrder, .shot]
        )
        XCTAssertEqual(ChekinanaGalleryFilterBarPolicy.slots.count, 6)
        XCTAssertGreaterThanOrEqual(
            ChekinanaGalleryFilterBarPolicy.slotWidth(availableWidth: 288),
            44
        )
    }

    func testGalleryGridSizeSliderMapsLargeToOneAndSmallToTenColumns() {
        XCTAssertEqual(ChekinanaGalleryGridSizePolicy.minimumColumnCount, 1)
        XCTAssertEqual(ChekinanaGalleryGridSizePolicy.maximumColumnCount, 10)
        XCTAssertEqual(ChekinanaGalleryGridSizePolicy.defaultColumnCount, 3)
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.columnCount(forSliderValue: -4),
            1
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.columnCount(forSliderValue: 1),
            1
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.columnCount(forSliderValue: 3),
            3
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.columnCount(forSliderValue: 10),
            10
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.columnCount(forSliderValue: 14),
            10
        )
        XCTAssertLessThan(
            ChekinanaGalleryGridSizePolicy.columnCount(forSliderValue: 1),
            ChekinanaGalleryGridSizePolicy.columnCount(forSliderValue: 10)
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.sliderValue(forColumnCount: 3),
            3
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.avatarDiameter(forColumnCount: 1),
            72,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.avatarDiameter(forColumnCount: 2),
            36,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.avatarDiameter(forColumnCount: 3),
            24,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.avatarDiameter(forColumnCount: 10),
            7.2,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            ChekinanaGalleryGridSizePolicy.avatarDiameter(forColumnCount: 3),
            ChekinanaGalleryGridSizePolicy.avatarDiameter(forColumnCount: 10)
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.avatarBorderLineWidth(
                forDiameter: ChekinanaGalleryGridSizePolicy
                    .avatarDiameter(forColumnCount: 3)
            ),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.avatarBorderLineWidth(
                forDiameter: ChekinanaGalleryGridSizePolicy
                    .avatarDiameter(forColumnCount: 4)
            ),
            1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.avatarBorderLineWidth(
                forDiameter: ChekinanaGalleryGridSizePolicy
                    .avatarDiameter(forColumnCount: 10)
            ),
            ChekinanaGalleryGridSizePolicy.minimumAvatarBorderLineWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChekinanaGalleryGridSizePolicy.avatarBorderLineWidth(
                forDiameter: ChekinanaGalleryGridSizePolicy
                    .avatarDiameter(forColumnCount: 1)
            ),
            ChekinanaGalleryGridSizePolicy.maximumAvatarBorderLineWidth,
            accuracy: 0.001
        )
        XCTAssertNotEqual(
            ChekinanaGalleryGridSizePolicy.avatarBorderLineWidth(
                forDiameter: ChekinanaGalleryGridSizePolicy
                    .avatarDiameter(forColumnCount: 3)
            ),
            ChekinanaGalleryGridSizePolicy.avatarBorderLineWidth(
                forDiameter: ChekinanaGalleryGridSizePolicy
                    .avatarDiameter(forColumnCount: 10)
            )
        )
    }

    func testLocalizationCatalogIsCompleteIsolatedAndPlaceholderSafe() throws {
        let productDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
        let localizationURL = productDirectory
            .appendingPathComponent("Localizable.xcstrings")
        let sourceURL = productDirectory
            .appendingPathComponent("ChekinanaProductShell.swift")
        let localizationData = try Data(contentsOf: localizationURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: localizationData)
                as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertFalse(strings.isEmpty)

        let placeholderRegex = try NSRegularExpression(
            pattern: #"%(?:(\d+)\$)?(lld|ld|d|@|s|f)"#
        )
        func placeholderSignature(_ value: String) -> [String] {
            var implicitPosition = 0
            return placeholderRegex.matches(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            ).map { match in
                let explicitRange = match.range(at: 1)
                let position: Int
                if explicitRange.location == NSNotFound {
                    implicitPosition += 1
                    position = implicitPosition
                } else {
                    position = Int((value as NSString).substring(with: explicitRange)) ?? 0
                }
                let type = (value as NSString).substring(with: match.range(at: 2))
                return "\(position):\(type)"
            }.sorted()
        }

        let intentionalChineseMiddleDotSpacingKeys: Set<String> = [
            "%@ · %@",
            "Existing%@ · %@",
            "GPU · %@",
            "Pattern %lld · 256D",
            "assistant.event_candidate",
            "assistant.load_more",
            "import.local_identity",
            "import.progress.idol_name",
            "import.progress.records",
            "import.record_summary",
            "import.step1",
            "import.step2",
            "product.calendar.no_media_metadata",
            "product.scan.candidates.unassigned_only",
        ]

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            var values: [String: String] = [:]
            for language in ["en", "ja", "zh-Hans"] {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "\(key) / \(language)"
                )
                let stringUnit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "\(key) / \(language)"
                )
                let value = try XCTUnwrap(
                    stringUnit["value"] as? String,
                    "\(key) / \(language)"
                )
                XCTAssertFalse(value.isEmpty, "\(key) / \(language)")
                values[language] = value
            }
            let englishSignature = placeholderSignature(try XCTUnwrap(values["en"]))
            XCTAssertEqual(
                placeholderSignature(try XCTUnwrap(values["ja"])),
                englishSignature,
                "\(key) / ja"
            )
            XCTAssertEqual(
                placeholderSignature(try XCTUnwrap(values["zh-Hans"])),
                englishSignature,
                "\(key) / zh-Hans"
            )
            let sourceSignature = placeholderSignature(key)
            if !sourceSignature.isEmpty {
                XCTAssertEqual(englishSignature, sourceSignature, "\(key) / source")
            }

            let japanese = try XCTUnwrap(values["ja"])
            XCTAssertFalse(
                japanese.contains("Idol"),
                "\(key) leaked Idol into Japanese"
            )
            XCTAssertFalse(
                japanese.contains("Event"),
                "\(key) leaked Event into Japanese"
            )
            XCTAssertNil(
                japanese.range(
                    of: #"\b(?:Idols?|Events?|Save|Cancel|Done|Edit|Delete|Add|Settings)\b"#,
                    options: [.regularExpression, .caseInsensitive]
                ),
                "\(key) leaked English UI copy into Japanese"
            )
            let chinese = try XCTUnwrap(values["zh-Hans"])
            XCTAssertFalse(chinese.contains("Idol"), "\(key) leaked Idol into Chinese")
            XCTAssertFalse(chinese.contains("Event"), "\(key) leaked Event into Chinese")
            XCTAssertNil(
                chinese.range(
                    of: #"\b(?:Idols?|Events?|Save|Cancel|Done|Edit|Delete|Add|Settings)\b"#,
                    options: [.regularExpression, .caseInsensitive]
                ),
                "\(key) leaked English UI copy into Simplified Chinese"
            )
            XCTAssertNil(
                chinese.range(of: "[ぁ-ゖァ-ヺ]", options: .regularExpression),
                "\(key) leaked Japanese UI copy into Simplified Chinese"
            )
            XCTAssertNil(
                chinese.range(
                    of: "[一-龯] +[一-龯]",
                    options: .regularExpression
                ),
                "\(key) has mechanical Han-to-Han spacing"
            )
            XCTAssertNil(
                chinese.range(
                    of: " +[，。！？；：、]",
                    options: .regularExpression
                ),
                "\(key) has a space before Chinese punctuation"
            )
            XCTAssertNil(
                chinese.range(
                    of: #"[一-龯] +%|%(?:(?:[0-9]+)\$)?(?:lld|ld|d|@|s|f) +[一-龯]"#,
                    options: .regularExpression
                ),
                "\(key) has mechanical spacing around a placeholder"
            )
            if chinese.contains(" · ") {
                XCTAssertTrue(
                    intentionalChineseMiddleDotSpacingKeys.contains(key),
                    "\(key) needs an explicit formatted-layout spacing exception"
                )
            }
            if chinese.contains("  ") {
                XCTAssertEqual(key, "%@  %@")
            }
            XCTAssertFalse(chinese.contains(" — "), "\(key) uses spaced em dash")
            let english = try XCTUnwrap(values["en"])
            XCTAssertNil(
                english.range(
                    of: "[一-龯ぁ-ゖァ-ヺ]",
                    options: .regularExpression
                ),
                "\(key) leaked CJK UI copy into English"
            )
            XCTAssertNil(
                japanese.range(
                    of: "[ぁ-んァ-ヶ一-龯] +[ぁ-んァ-ヶ一-龯]",
                    options: .regularExpression
                ),
                "\(key) has mechanical Japanese token spacing"
            )
            XCTAssertNil(
                japanese.range(
                    of: #"[ぁ-んァ-ヶ一-龯] +%|%(?:(?:[0-9]+)\$)?(?:lld|ld|d|@|s|f) +[ぁ-んァ-ヶ一-龯]"#,
                    options: .regularExpression
                ),
                "\(key) has mechanical Japanese placeholder spacing"
            )
            XCTAssertFalse(japanese.contains("： "), "\(key) has a space after ：")
            XCTAssertFalse(japanese.contains(" — "), "\(key) uses spaced em dash")
        }

        let idolTitle = try XCTUnwrap(strings["product.idols.title"] as? [String: Any])
        let idolTitleLocalizations = try XCTUnwrap(
            idolTitle["localizations"] as? [String: Any]
        )
        let idolTitleJapanese = try XCTUnwrap(
            idolTitleLocalizations["ja"] as? [String: Any]
        )
        let idolTitleStringUnit = try XCTUnwrap(
            idolTitleJapanese["stringUnit"] as? [String: Any]
        )
        XCTAssertEqual(idolTitleStringUnit["value"] as? String, "推し")

        func catalogValue(_ key: String, _ language: String) throws -> String {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            let localization = try XCTUnwrap(
                localizations[language] as? [String: Any],
                "\(key) / \(language)"
            )
            let unit = try XCTUnwrap(
                localization["stringUnit"] as? [String: Any],
                "\(key) / \(language)"
            )
            return try XCTUnwrap(unit["value"] as? String)
        }
        XCTAssertEqual(
            try catalogValue("Search catalogue", "zh-Hans"),
            "搜索偶像资料库"
        )
        XCTAssertEqual(
            try catalogValue("Search catalogue", "ja"),
            "カタログを検索"
        )
        XCTAssertEqual(
            try catalogValue("import.error.not_zip", "en"),
            "The selected file is not a valid ZIP-based ChekiRoku backup."
        )
        XCTAssertEqual(
            try catalogValue("import.error.not_zip", "ja"),
            "選択したファイルは有効なZIP形式のChekiRokuバックアップではありません。"
        )
        XCTAssertEqual(
            try catalogValue("import.error.not_zip", "zh-Hans"),
            "所选文件不是有效的 ChekiRoku ZIP 格式备份。"
        )
        XCTAssertEqual(
            try catalogValue("product.scan.shot_type.toggle_hint", "ja"),
            "ダブルタップでソロと2ショットを切り替えます。"
        )
        for key in [
            "product.idols.delete.error.linked_records",
            "product.idols.no_media_group.changed",
            "product.idols.reorder_changed",
            "product.scan.rotate_failed",
            "product.scan.temporary_unavailable",
        ] {
            for language in ["ja", "zh-Hans"] {
                XCTAssertFalse(
                    try catalogValue(key, language).contains("Cheki"),
                    "\(key) leaked Cheki into \(language)"
                )
            }
        }
        XCTAssertEqual(
            try catalogValue("import.existing_skip", "ja"),
            "既存のアイドル：スキップ"
        )
        XCTAssertEqual(
            try catalogValue("import.member_excluded", "ja"),
            "未選択：このアイドルと記録は除外されます。"
        )
        XCTAssertEqual(
            try catalogValue("import.new_create", "ja"),
            "新しいアイドル：作成予定"
        )

        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let productCopyRegex = try NSRegularExpression(
            pattern: #"ChekinanaProductCopy\.(text|format|quantity)\(\s*\"([^\"]+)\""#
        )
        for match in productCopyRegex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ) {
            let method = (source as NSString).substring(with: match.range(at: 1))
            let baseKey = "product." + (source as NSString)
                .substring(with: match.range(at: 2))
            let requiredKeys = method == "quantity"
                ? ["\(baseKey).one", "\(baseKey).other"]
                : [baseKey]
            for requiredKey in requiredKeys {
                XCTAssertNotNil(
                    strings[requiredKey],
                    "Active ProductShell copy key is missing: \(requiredKey)"
                )
            }
        }
    }

    func testAppLanguagePreferenceMappingAndBundles() throws {
        XCTAssertEqual(ChekinanaAppLanguage.resolve(nil), .system)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("invalid"), .system)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("system"), .system)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("zh-Hans"), .simplifiedChinese)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("en"), .english)
        XCTAssertEqual(ChekinanaAppLanguage.resolve("ja"), .japanese)
        XCTAssertEqual(
            ChekinanaAppLanguage.settingsVisibleCases,
            [.system, .simplifiedChinese, .japanese]
        )
        XCTAssertTrue(ChekinanaAppLanguage.allCases.contains(.english))
        XCTAssertFalse(ChekinanaAppLanguage.settingsVisibleCases.contains(.english))

        let suiteName = "ChekinanaLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(ChekinanaLanguagePreference.language(defaults: defaults), .system)
        ChekinanaLanguagePreference.set(.japanese, defaults: defaults)
        XCTAssertEqual(ChekinanaLanguagePreference.language(defaults: defaults), .japanese)
        ChekinanaLanguagePreference.set(.english, defaults: defaults)
        _ = ChekinanaAppLanguage.settingsVisibleCases
        XCTAssertEqual(
            ChekinanaLanguagePreference.language(defaults: defaults),
            .english,
            "Building the visible Settings options must not rewrite a persisted English preference."
        )

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

        let englishBundle = ChekinanaLanguagePreference.localizationBundle(
            for: .english,
            candidates: candidates
        )
        XCTAssertEqual(
            ChekinanaProductCopy.text(
                "settings.language.en",
                "English",
                bundle: englishBundle
            ),
            "English"
        )

        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let settingsStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaSettingsView")?.lowerBound
        )
        let settings = String(source[settingsStart..<source.endIndex])
        XCTAssertTrue(settings.contains(
            "ForEach(ChekinanaAppLanguage.settingsVisibleCases)"
        ))
        XCTAssertFalse(settings.contains(
            "ForEach(ChekinanaAppLanguage.allCases)"
        ))
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

        let schema = Schema([Idol.self, IdolPatternState.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
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
        let schema = Schema(versionedSchema: ChekinanaSchemaV12.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Clear me", isFavorite: true)
        let event = Event(name: "Clear event")
        let cheki = Cheki(idols: [idol], event: event, date: Date(), idx: 1)
        let record = ChekiRecord(idols: [idol], event: event, date: Date())
        let shame = Shame(idols: [idol], note: "clear image")
        let douga = Douga(idols: [idol], note: "clear video")
        let travel = TravelSegment(
            mode: .flight,
            operatorName: "Clear airline",
            serviceNumber: "CL100",
            departureCity: "Shanghai",
            departureLocation: "PVG T1",
            arrivalCity: "Tokyo",
            arrivalLocation: "NRT T2",
            departureTime: Date(),
            arrivalTime: Date().addingTimeInterval(7_200)
        )
        context.insert(idol)
        context.insert(event)
        context.insert(EventSchedule(
            eventID: event.id,
            openTime: "14:15",
            startTime: "15:00"
        ))
        context.insert(cheki)
        context.insert(record)
        context.insert(shame)
        context.insert(douga)
        context.insert(MediaShotType(
            mediaID: shame.id,
            kind: .shame,
            userAppears: true
        ))
        context.insert(travel)
        context.insert(IdolPatternState(
            idolID: idol.id,
            encoderVersion: ChekinanaPatternContract.encoderVersion
        ))
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
            chekiCount: 2,
            shameCount: 1,
            dougaCount: 1,
            eventCount: 1,
            idolCount: 1,
            removedFileCount: 4
        ))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Cheki>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChekiRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Shame>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Douga>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MediaShotType>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Event>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventSchedule>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TravelSegment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IdolPatternState>()), 0)
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
    }

    func testClearAllLocalDataDeletesHiddenQuarantineButSkipsHiddenSymlinkAndDirectory() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV12.self)
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

    func testClearAllLocalDataDatabaseFailurePreservesFiles() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV12.self)
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
    }

    func testClearAllLocalDataFileFailureKeepsClearedDatabase() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV12.self)
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
        let schema = Schema([Idol.self, IdolPatternState.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
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

        let currentSchema = Schema(versionedSchema: ChekinanaSchemaV11.self)
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

    func testV7StoreOpensToV10WithAutomaticLightweightMigrationWithoutStagedPlan() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "chekinana-v7-automatic-v9-open-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("current.store")
        let eventID = UUID()
        let v7Schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        var v7Container: ModelContainer? = try ModelContainer(
            for: v7Schema,
            configurations: [ModelConfiguration(
                "Chekinana",
                schema: v7Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(v7Container))
            context.insert(Event(id: eventID, name: "Preserved V7 Event"))
            try context.save()
        }
        v7Container = nil

        let v10Schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        let v10Container = try ModelContainer(
            for: v10Schema,
            configurations: [ModelConfiguration(
                "Chekinana",
                schema: v10Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(v10Container)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Event>()).first?.id,
            eventID
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<EventSchedule>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MediaEventLink>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CalendarGroupOrder>()).isEmpty)
    }

    func testPhysicalV7UsesAutomaticMigrationWhenMarkerStillSaysV6() throws {
        struct Marker: Codable {
            let schemaVersion: Int
            let directoryName: String
        }
        enum UnexpectedStagedMigration: Error { case invoked }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "chekinana-v7-v6-marker-mismatch-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: root,
            legacyStoreName: "Original.store",
            namespace: "v7-v6-marker-mismatch"
        )
        try fileManager.createDirectory(
            at: paths.candidateRootURL,
            withIntermediateDirectories: true
        )
        let directoryName = "store-\(UUID().uuidString)"
        let directory = paths.candidateRootURL.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("current.store")
        let eventID = UUID()
        let v7Schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        var v7Container: ModelContainer? = try ModelContainer(
            for: v7Schema,
            configurations: [ModelConfiguration(
                "MarkerMismatch",
                schema: v7Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let v7Context = ModelContext(try XCTUnwrap(v7Container))
        v7Context.insert(Event(id: eventID, name: "Marker mismatch"))
        try v7Context.save()
        v7Container = nil
        try JSONEncoder().encode(Marker(
            schemaVersion: 6,
            directoryName: directoryName
        )).write(to: paths.activeMarkerURL, options: .atomic)

        let v10Schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        let result = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            inspectStoreVersion: ChekinanaDataStore.physicalStoreVersion,
            makeAutomaticContainer: { url in
                try ModelContainer(
                    for: v10Schema,
                    configurations: [ModelConfiguration(
                        "MarkerMismatch",
                        schema: v10Schema,
                        url: url,
                        cloudKitDatabase: .none
                    )]
                )
            }
        ) { _ in
            throw UnexpectedStagedMigration.invoked
        }
        guard case .success(let container) = result else {
            return XCTFail("The supported physical V7 store must select automatic migration.")
        }
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<Event>()).first?.id,
            eventID
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                Marker.self,
                from: Data(contentsOf: paths.activeMarkerURL)
            ).schemaVersion,
            10
        )
    }

    func testUnknownPhysicalMetadataFailsClosedBeforeCopyOrContainerOpen() throws {
        struct Marker: Codable {
            let schemaVersion: Int
            let directoryName: String
        }
        enum UnexpectedCall: Error { case invoked }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "chekinana-unknown-physical-store-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: root,
            legacyStoreName: "Original.store",
            namespace: "unknown-physical-store"
        )
        try fileManager.createDirectory(
            at: paths.candidateRootURL,
            withIntermediateDirectories: true
        )
        let directoryName = "store-\(UUID().uuidString)"
        let directory = paths.candidateRootURL.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("current.store")
        let storeBefore = Data("unknown physical model".utf8)
        try storeBefore.write(to: storeURL)
        try JSONEncoder().encode(Marker(
            schemaVersion: 7,
            directoryName: directoryName
        )).write(to: paths.activeMarkerURL, options: .atomic)
        let markerBefore = try Data(contentsOf: paths.activeMarkerURL)

        let result = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            copyStore: { _, _, _ in throw UnexpectedCall.invoked },
            inspectStoreVersion: { _ in nil },
            makeAutomaticContainer: { _ in throw UnexpectedCall.invoked }
        ) { _ in
            throw UnexpectedCall.invoked
        }
        guard case .failure = result else {
            return XCTFail("Unknown physical metadata must fail closed.")
        }
        XCTAssertEqual(try Data(contentsOf: paths.activeMarkerURL), markerBefore)
        XCTAssertEqual(try Data(contentsOf: storeURL), storeBefore)
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(
                at: paths.candidateRootURL,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent),
            [directoryName]
        )
    }

    func testV7ActiveMarkerMigratesEventSchedulesAndMediaLinksToV9AndReopensIdempotently() throws {
        struct Marker: Codable {
            let schemaVersion: Int
            let directoryName: String
        }
        enum UnexpectedCopy: Error { case invoked }
        enum UnexpectedStagedMigration: Error { case invoked }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "chekinana-v7-v8-event-schedule-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: root,
            legacyStoreName: "Original.store",
            namespace: "v7-event-schedule"
        )
        try fileManager.createDirectory(
            at: paths.candidateRootURL,
            withIntermediateDirectories: true
        )
        let oldDirectoryName = "store-\(UUID().uuidString)"
        let oldDirectory = paths.candidateRootURL.appendingPathComponent(
            oldDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        let oldStoreURL = oldDirectory.appendingPathComponent("current.store")
        let eventID = UUID()
        let v7Schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        var oldContainer: ModelContainer? = try ModelContainer(
            for: v7Schema,
            configurations: [ModelConfiguration(
                "V7EventSchedule",
                schema: v7Schema,
                url: oldStoreURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(oldContainer))
            context.insert(Event(id: eventID, name: "Frozen V7 Event"))
            try context.save()
        }
        oldContainer = nil
        let v7Metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: oldStoreURL
        )
        XCTAssertEqual(
            v7Metadata["NSStoreModelVersionChecksumKey"] as? String,
            ChekinanaDataStore.schemaV7StoreChecksum
        )
        XCTAssertEqual(
            try ChekinanaDataStore.physicalStoreVersion(at: oldStoreURL),
            .v7
        )
        try JSONEncoder().encode(Marker(
            schemaVersion: 7,
            directoryName: oldDirectoryName
        )).write(to: paths.activeMarkerURL, options: .atomic)

        let v10Schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        func openV10Automatically(at url: URL) throws -> ModelContainer {
            try ModelContainer(
                for: v10Schema,
                configurations: [ModelConfiguration(
                    "V7EventSchedule",
                    schema: v10Schema,
                    url: url,
                    cloudKitDatabase: .none
                )]
            )
        }

        var migratedContainer: ModelContainer?
        let migrated = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            inspectStoreVersion: ChekinanaDataStore.physicalStoreVersion,
            makeAutomaticContainer: { url in
                let container = try openV10Automatically(at: url)
                migratedContainer = container
                return container
            }
        ) { _ in
            throw UnexpectedStagedMigration.invoked
        }
        guard case .success = migrated else {
            return XCTFail("A supported V7 marker must migrate to V9.")
        }
        let marker = try JSONDecoder().decode(
            Marker.self,
            from: Data(contentsOf: paths.activeMarkerURL)
        )
        XCTAssertEqual(marker.schemaVersion, 12)
        let activeURL = try XCTUnwrap(
            ChekinanaDataStore.currentActiveStoreURL(paths: paths)
        )
        XCTAssertNotEqual(activeURL.standardizedFileURL, oldStoreURL.standardizedFileURL)
        do {
            let context = ModelContext(try XCTUnwrap(migratedContainer))
            XCTAssertEqual(
                try context.fetch(FetchDescriptor<Event>()).first?.id,
                eventID
            )
            XCTAssertTrue(try context.fetch(FetchDescriptor<MediaEventLink>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<EventSchedule>()).isEmpty)
            try ChekinanaEventSchedulePersistence.set(
                eventID: eventID,
                openTime: "14:15",
                startTime: "15:00",
                in: context
            )
            try context.save()
        }
        migratedContainer = nil

        var reopenedURL: URL?
        let reopened = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            copyStore: { _, _, _ in throw UnexpectedCopy.invoked },
            inspectStoreVersion: ChekinanaDataStore.physicalStoreVersion,
            makeAutomaticContainer: { url in
                reopenedURL = url
                return try openV10Automatically(at: url)
            }
        ) { _ in
            throw UnexpectedStagedMigration.invoked
        }
        guard case .success(let reopenedContainer) = reopened else {
            return XCTFail("A current V10 marker must reopen in place.")
        }
        XCTAssertEqual(reopenedURL?.standardizedFileURL, activeURL.standardizedFileURL)
        let reopenedContext = ModelContext(reopenedContainer)
        XCTAssertEqual(
            try ChekinanaEventSchedulePersistence.value(
                for: eventID,
                in: reopenedContext
            ),
            .init(openTime: "14:15", startTime: "15:00")
        )
    }

    func testV5ToV9MigratesImageLessChekisAndMergesDuplicateIdentityAtomically() throws {
        struct Marker: Codable {
            let schemaVersion: Int
            let directoryName: String
        }
        enum UnexpectedCopy: Error { case invoked }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-v5-v6-record-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: directory,
            legacyStoreName: "Original.store",
            namespace: "v5-count"
        )
        try FileManager.default.createDirectory(
            at: paths.candidateRootURL,
            withIntermediateDirectories: true
        )
        let oldDirectoryName = "store-\(UUID().uuidString)"
        let oldDirectory = paths.candidateRootURL.appendingPathComponent(
            oldDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        let storeURL = oldDirectory.appendingPathComponent("current.store")
        let v5Schema = Schema(versionedSchema: ChekinanaSchemaV5.self)
        let idolID = UUID()
        let eventID = UUID()
        let mediaID = UUID()
        let nilImageID = try XCTUnwrap(UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        ))
        let duplicateNilImageID = try XCTUnwrap(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        ))
        let blankImageID = UUID()
        let day = utcDate(2026, 8, 24)

        var v5Container: ModelContainer? = try ModelContainer(
            for: v5Schema,
            configurations: [ModelConfiguration(
                "Records",
                schema: v5Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(v5Container))
            let idol = Idol(id: idolID, name: "Migrated Idol")
            let event = Event(id: eventID, name: "Migrated Event", date: day)
            let media = Cheki(
                id: mediaID,
                date: day,
                idx: 9,
                userAppears: true,
                size: .wide,
                imageRef: "media-byte-sentinel.jpg",
                isFavorite: true,
                hasPostedToSNS: true,
                note: "media",
                createdAt: day.addingTimeInterval(1),
                updatedAt: day.addingTimeInterval(2)
            )
            media.userAppears = nil
            let nilImage = Cheki(
                id: nilImageID,
                date: day,
                idx: 7,
                userAppears: false,
                size: .mini,
                imageRef: nil,
                isFavorite: true,
                hasPostedToSNS: true,
                note: "nil image"
            )
            let blankImage = Cheki(
                id: blankImageID,
                date: day.addingTimeInterval(2 * 60 * 60),
                idx: 8,
                userAppears: true,
                size: .wide,
                imageRef: "  \n ",
                isFavorite: true,
                hasPostedToSNS: true,
                note: "blank image"
            )
            let duplicateNilImage = Cheki(
                id: duplicateNilImageID,
                date: day.addingTimeInterval(60 * 60),
                idx: 10,
                userAppears: true,
                size: .mini,
                imageRef: nil,
                isFavorite: false,
                hasPostedToSNS: false,
                note: "nil image"
            )
            context.insert(idol)
            context.insert(event)
            for cheki in [media, nilImage, duplicateNilImage, blankImage] {
                context.insert(cheki)
                cheki.idols = [idol]
                cheki.event = event
            }
            try context.save()
        }
        v5Container = nil
        try JSONEncoder().encode(Marker(
            schemaVersion: 5,
            directoryName: oldDirectoryName
        )).write(to: paths.activeMarkerURL, options: .atomic)

        let currentSchema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        func openCurrent(at url: URL) throws -> ModelContainer {
            try ModelContainer(
                for: currentSchema,
                migrationPlan: ChekinanaSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(
                    "Records",
                    schema: currentSchema,
                    url: url,
                    cloudKitDatabase: .none
                )]
            )
        }

        var migratedContainer: ModelContainer?
        let migrated = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths
        ) { url in
            let container = try openCurrent(at: url)
            migratedContainer = container
            return container
        }
        guard case .success = migrated else {
            return XCTFail("A supported V5 marker must migrate to V9.")
        }
        let upgradedMarker = try JSONDecoder().decode(
            Marker.self,
            from: Data(contentsOf: paths.activeMarkerURL)
        )
        XCTAssertEqual(upgradedMarker.schemaVersion, 12)
        do {
            let context = ModelContext(try XCTUnwrap(migratedContainer))
            let mediaChekis = try context.fetch(FetchDescriptor<Cheki>())
            XCTAssertEqual(mediaChekis.map(\.id), [mediaID])
            let media = try XCTUnwrap(mediaChekis.first)
            XCTAssertEqual(media.imageRef, "media-byte-sentinel.jpg")
            XCTAssertEqual(media.idx, 9)
            XCTAssertEqual(media.userAppears, false)
            XCTAssertEqual(media.size, .wide)
            XCTAssertTrue(media.isFavorite)
            XCTAssertTrue(media.hasPostedToSNS)
            XCTAssertEqual(media.note, "media")
            XCTAssertEqual(Set(media.idols.map(\.id)), [idolID])
            XCTAssertEqual(media.event?.id, eventID)

            let records = try context.fetch(FetchDescriptor<ChekiRecord>())
            XCTAssertEqual(records.count, 2)
            for record in records {
                XCTAssertEqual(record.date, day)
                XCTAssertEqual(Set(record.idols.map(\.id)), [idolID])
                XCTAssertEqual(record.event?.id, eventID)
            }
            XCTAssertEqual(
                records.first(where: { $0.note == "nil image" })?.size,
                .mini
            )
            XCTAssertEqual(
                records.first(where: { $0.note == "nil image" })?.count,
                2
            )
            XCTAssertEqual(
                records.first(where: { $0.note == "blank image" })?.size,
                .wide
            )
            XCTAssertEqual(
                records.first(where: { $0.note == "blank image" })?.count,
                1
            )
        }
        migratedContainer = nil

        let activeURL = try XCTUnwrap(
            ChekinanaDataStore.currentActiveStoreURL(paths: paths)
        )
        var reopenedURL: URL?
        let reopenedResult = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            copyStore: { _, _, _ in throw UnexpectedCopy.invoked }
        ) { url in
            reopenedURL = url
            return try openCurrent(at: url)
        }
        guard case .success(let reopenedContainer) = reopenedResult else {
            return XCTFail("The migrated V7 store must reopen in place.")
        }
        XCTAssertEqual(reopenedURL?.standardizedFileURL, activeURL.standardizedFileURL)
        let reopened = ModelContext(reopenedContainer)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Cheki>()), 1)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<ChekiRecord>()), 2)
        XCTAssertEqual(
            ChekinanaChekiRecordStore.totalCount(
                try reopened.fetch(FetchDescriptor<ChekiRecord>())
            ),
            3
        )
    }

    func testV4ActiveMarkerColdStartMigratesIsolatedStoreToV9AndReopensIdempotently() throws {
        struct Marker: Codable {
            let schemaVersion: Int
            let directoryName: String
        }
        enum UnexpectedCopy: Error { case invoked }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "chekinana-v4-marker-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: directory) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: directory,
            legacyStoreName: "Original.store",
            namespace: "v4-marker"
        )
        try fileManager.createDirectory(
            at: paths.candidateRootURL,
            withIntermediateDirectories: true
        )
        let oldDirectoryName = "store-\(UUID().uuidString)"
        let oldDirectory = paths.candidateRootURL.appendingPathComponent(
            oldDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldStoreURL = oldDirectory.appendingPathComponent("current.store")
        let v4Schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let idolID = UUID()
        let eventID = UUID()
        let mediaID = UUID()
        let recordID = UUID()
        let day = utcDate(2026, 8, 24)
        let mediaCreatedAt = day.addingTimeInterval(1)
        let mediaUpdatedAt = day.addingTimeInterval(2)

        var v4Container: ModelContainer? = try ModelContainer(
            for: v4Schema,
            configurations: [ModelConfiguration(
                "V4Marker",
                schema: v4Schema,
                url: oldStoreURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(v4Container))
            let idol = Idol(id: idolID, name: "V4 Idol")
            let event = Event(id: eventID, name: "V4 Event", date: day)
            let media = Cheki(
                id: mediaID,
                date: day,
                idx: 7,
                userAppears: true,
                size: .wide,
                imageRef: "v4-media.jpg",
                isFavorite: true,
                hasPostedToSNS: true,
                note: "media sentinel",
                createdAt: mediaCreatedAt,
                updatedAt: mediaUpdatedAt
            )
            media.userAppears = nil
            let noMedia = Cheki(
                id: recordID,
                date: day,
                idx: 99,
                userAppears: false,
                size: .mini,
                imageRef: "  \n ",
                isFavorite: true,
                hasPostedToSNS: true,
                note: "record sentinel"
            )
            context.insert(idol)
            context.insert(event)
            for value in [media, noMedia] {
                context.insert(value)
                value.idols = [idol]
                value.event = event
            }
            try context.save()
        }
        v4Container = nil
        try JSONEncoder().encode(Marker(
            schemaVersion: 4,
            directoryName: oldDirectoryName
        )).write(to: paths.activeMarkerURL, options: .atomic)

        let v6Schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        func openV6(at url: URL) throws -> ModelContainer {
            try ModelContainer(
                for: v6Schema,
                migrationPlan: ChekinanaSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(
                    "V4Marker",
                    schema: v6Schema,
                    url: url,
                    cloudKitDatabase: .none
                )]
            )
        }

        var migratedContainer: ModelContainer?
        let migrated = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths
        ) { url in
            let container = try openV6(at: url)
            migratedContainer = container
            return container
        }
        guard case .success = migrated else {
            return XCTFail("A supported V4 marker must migrate through an isolated candidate.")
        }
        let activeURL = try XCTUnwrap(
            ChekinanaDataStore.currentActiveStoreURL(paths: paths)
        )
        XCTAssertNotEqual(activeURL.standardizedFileURL, oldStoreURL.standardizedFileURL)
        let upgradedMarker = try JSONDecoder().decode(
            Marker.self,
            from: Data(contentsOf: paths.activeMarkerURL)
        )
        XCTAssertEqual(upgradedMarker.schemaVersion, 12)
        XCTAssertEqual(upgradedMarker.directoryName, activeURL.deletingLastPathComponent().lastPathComponent)

        do {
            let context = ModelContext(try XCTUnwrap(migratedContainer))
            let mediaChekis = try context.fetch(FetchDescriptor<Cheki>())
            XCTAssertEqual(mediaChekis.map(\.id), [mediaID])
            let media = try XCTUnwrap(mediaChekis.first)
            XCTAssertEqual(media.imageRef, "v4-media.jpg")
            XCTAssertEqual(media.idx, 7)
            XCTAssertEqual(media.userAppears, false)
            XCTAssertEqual(media.size, .wide)
            XCTAssertTrue(media.isFavorite)
            XCTAssertTrue(media.hasPostedToSNS)
            XCTAssertEqual(media.note, "media sentinel")
            XCTAssertEqual(media.createdAt, mediaCreatedAt)
            XCTAssertEqual(media.updatedAt, mediaUpdatedAt)
            XCTAssertEqual(media.idols.map(\.id), [idolID])
            XCTAssertEqual(media.event?.id, eventID)

            let records = try context.fetch(FetchDescriptor<ChekiRecord>())
            XCTAssertEqual(records.map(\.id), [recordID])
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.idols.map(\.id), [idolID])
            XCTAssertEqual(record.event?.id, eventID)
            XCTAssertEqual(record.date, day)
            XCTAssertEqual(record.size, .mini)
            XCTAssertEqual(record.note, "record sentinel")
            XCTAssertEqual(record.count, 1)
        }
        migratedContainer = nil

        var reopenedURL: URL?
        let reopened = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            copyStore: { _, _, _ in throw UnexpectedCopy.invoked }
        ) { url in
            reopenedURL = url
            return try openV6(at: url)
        }
        guard case .success(let reopenedContainer) = reopened else {
            return XCTFail("A current V9 marker must reopen in place.")
        }
        XCTAssertEqual(reopenedURL?.standardizedFileURL, activeURL.standardizedFileURL)
        let reopenedContext = ModelContext(reopenedContainer)
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<Cheki>()), 1)
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<ChekiRecord>()), 1)
    }

    func testV6ActiveMarkerMigratesCountsAndMergesDuplicateIdentityToV9() throws {
        struct Marker: Codable {
            let schemaVersion: Int
            let directoryName: String
        }
        enum UnexpectedCopy: Error { case invoked }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "chekinana-v6-v7-count-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: root,
            legacyStoreName: "Original.store",
            namespace: "v6-count"
        )
        try fileManager.createDirectory(
            at: paths.candidateRootURL,
            withIntermediateDirectories: true
        )
        let oldDirectoryName = "store-\(UUID().uuidString)"
        let oldDirectory = paths.candidateRootURL.appendingPathComponent(
            oldDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        let oldStoreURL = oldDirectory.appendingPathComponent("current.store")
        let v6Schema = Schema(versionedSchema: ChekinanaSchemaV6.self)
        let idolID = UUID()
        let eventID = UUID()
        let legacyMediaID = UUID()
        let day = utcDate(2026, 8, 24)
        let nonCanonicalID = try XCTUnwrap(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        ))
        let canonicalID = try XCTUnwrap(UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        ))

        var oldContainer: ModelContainer? = try ModelContainer(
            for: v6Schema,
            configurations: [ModelConfiguration(
                "V6Count",
                schema: v6Schema,
                url: oldStoreURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(oldContainer))
            context.insert(Idol(id: idolID, name: "V6 Idol"))
            context.insert(Event(id: eventID, name: "V6 Event", date: day))
            let legacyMedia = Cheki(
                id: legacyMediaID,
                date: day,
                imageRef: "v6-media.jpg"
            )
            legacyMedia.userAppears = nil
            context.insert(legacyMedia)
            context.insert(ChekinanaSchemaV6.ChekiRecord(
                id: nonCanonicalID,
                idolIDs: [idolID],
                eventID: eventID,
                date: day.addingTimeInterval(60 * 60),
                sizeRawValue: ChekiSize.mini.rawValue,
                note: "duplicate"
            ))
            context.insert(ChekinanaSchemaV6.ChekiRecord(
                id: canonicalID,
                idolIDs: [idolID],
                eventID: eventID,
                date: day,
                sizeRawValue: ChekiSize.mini.rawValue,
                note: "duplicate"
            ))
            context.insert(ChekinanaSchemaV6.ChekiRecord(
                id: UUID(),
                idolIDs: [idolID],
                eventID: eventID,
                date: day.addingTimeInterval(2 * 60 * 60),
                sizeRawValue: ChekiSize.wide.rawValue,
                note: "different"
            ))
            try context.save()
        }
        oldContainer = nil
        try JSONEncoder().encode(Marker(
            schemaVersion: 6,
            directoryName: oldDirectoryName
        )).write(to: paths.activeMarkerURL, options: .atomic)

        let currentSchema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        func currentContainer(at url: URL) throws -> ModelContainer {
            try ModelContainer(
                for: currentSchema,
                migrationPlan: ChekinanaSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(
                    "V6Count",
                    schema: currentSchema,
                    url: url,
                    cloudKitDatabase: .none
                )]
            )
        }

        var migratedContainer: ModelContainer?
        let migrated = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths
        ) { url in
            let container = try currentContainer(at: url)
            migratedContainer = container
            return container
        }
        guard case .success = migrated else {
            return XCTFail("A supported V6 marker must migrate to V9.")
        }
        let marker = try JSONDecoder().decode(
            Marker.self,
            from: Data(contentsOf: paths.activeMarkerURL)
        )
        XCTAssertEqual(marker.schemaVersion, 12)
        let context = ModelContext(try XCTUnwrap(migratedContainer))
        let media = try context.fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(media.map(\.id), [legacyMediaID])
        XCTAssertEqual(media.first?.userAppears, false)
        let records = try context.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first(where: { $0.note == "duplicate" })?.count, 2)
        XCTAssertEqual(records.first(where: { $0.note == "different" })?.count, 1)
        XCTAssertEqual(
            records.first(where: { $0.note == "duplicate" })?.date,
            day
        )
        XCTAssertEqual(
            records.first(where: { $0.note == "different" })?.date,
            day
        )
        migratedContainer = nil

        let activeURL = try XCTUnwrap(
            ChekinanaDataStore.currentActiveStoreURL(paths: paths)
        )
        var reopenedURL: URL?
        let reopened = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            copyStore: { _, _, _ in throw UnexpectedCopy.invoked }
        ) { url in
            reopenedURL = url
            return try currentContainer(at: url)
        }
        guard case .success(let reopenedContainer) = reopened else {
            return XCTFail("The migrated V7 store must reopen in place.")
        }
        XCTAssertEqual(reopenedURL?.standardizedFileURL, activeURL.standardizedFileURL)
        XCTAssertEqual(
            try ModelContext(reopenedContainer).fetchCount(
                FetchDescriptor<ChekiRecord>()
            ),
            2
        )
        XCTAssertEqual(
            try ModelContext(reopenedContainer).fetch(FetchDescriptor<Cheki>())
                .first?.userAppears,
            false
        )
    }

    func testV4ActiveMarkerMigrationFailurePreservesMarkerAndAuthoritativeStore() throws {
        struct Marker: Codable {
            let schemaVersion: Int
            let directoryName: String
        }
        enum ExpectedFailure: Error { case injected }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "chekinana-v4-marker-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: directory) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: directory,
            legacyStoreName: "Original.store",
            namespace: "v4-marker-failure"
        )
        try fileManager.createDirectory(
            at: paths.candidateRootURL,
            withIntermediateDirectories: true
        )
        let oldDirectoryName = "store-\(UUID().uuidString)"
        let oldDirectory = paths.candidateRootURL.appendingPathComponent(
            oldDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldStoreURL = oldDirectory.appendingPathComponent("current.store")
        let v4Schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        var v4Container: ModelContainer? = try ModelContainer(
            for: v4Schema,
            configurations: [ModelConfiguration(
                "V4Failure",
                schema: v4Schema,
                url: oldStoreURL,
                cloudKitDatabase: .none
            )]
        )
        let sentinelID = UUID()
        do {
            let context = ModelContext(try XCTUnwrap(v4Container))
            context.insert(Cheki(
                id: sentinelID,
                imageRef: "authoritative.jpg",
                note: "must survive"
            ))
            try context.save()
        }
        v4Container = nil
        try JSONEncoder().encode(Marker(
            schemaVersion: 4,
            directoryName: oldDirectoryName
        )).write(to: paths.activeMarkerURL, options: .atomic)
        let markerBefore = try Data(contentsOf: paths.activeMarkerURL)
        let familyURLs = ["", "-wal", "-shm"].map {
            URL(fileURLWithPath: oldStoreURL.path + $0)
        }.filter { fileManager.fileExists(atPath: $0.path) }
        let familyBefore = try Dictionary(uniqueKeysWithValues: familyURLs.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })

        let result = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths
        ) { _ in
            throw ExpectedFailure.injected
        }
        guard case .failure = result else {
            return XCTFail("An injected migration failure must not activate its candidate.")
        }
        XCTAssertEqual(try Data(contentsOf: paths.activeMarkerURL), markerBefore)
        XCTAssertTrue(fileManager.fileExists(atPath: oldDirectory.path))
        for url in familyURLs {
            XCTAssertEqual(
                try Data(contentsOf: url),
                familyBefore[url.lastPathComponent]
            )
        }

        v4Container = try ModelContainer(
            for: v4Schema,
            configurations: [ModelConfiguration(
                "V4Failure",
                schema: v4Schema,
                url: oldStoreURL,
                cloudKitDatabase: .none
            )]
        )
        XCTAssertEqual(
            try ModelContext(try XCTUnwrap(v4Container))
                .fetch(FetchDescriptor<Cheki>()).first?.id,
            sentinelID
        )
    }

    func testUnsupportedActiveMarkerVersionsAreRejectedWithoutTouchingStore() throws {
        struct Marker: Codable {
            let schemaVersion: Int
            let directoryName: String
        }
        enum UnexpectedCall: Error { case invoked }

        let fileManager = FileManager.default
        for unsupportedVersion in [3, 9] {
            let directory = fileManager.temporaryDirectory.appendingPathComponent(
                "chekinana-unsupported-marker-\(unsupportedVersion)-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: directory) }
            let paths = ChekinanaDataStore.StorePaths(
                rootDirectory: directory,
                legacyStoreName: "Original.store",
                namespace: "unsupported-marker-\(unsupportedVersion)"
            )
            try fileManager.createDirectory(
                at: paths.candidateRootURL,
                withIntermediateDirectories: true
            )
            let directoryName = "store-\(UUID().uuidString)"
            let activeDirectory = paths.candidateRootURL.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: activeDirectory,
                withIntermediateDirectories: true
            )
            let storeURL = activeDirectory.appendingPathComponent("current.store")
            let storeBefore = Data("unsupported marker sentinel".utf8)
            try storeBefore.write(to: storeURL)
            try JSONEncoder().encode(Marker(
                schemaVersion: unsupportedVersion,
                directoryName: directoryName
            )).write(to: paths.activeMarkerURL, options: .atomic)
            let markerBefore = try Data(contentsOf: paths.activeMarkerURL)

            var copied = false
            var opened = false
            let result = ChekinanaDataStore.openPreservingStoreFamily(
                paths: paths,
                copyStore: { _, _, _ in
                    copied = true
                    throw UnexpectedCall.invoked
                }
            ) { _ in
                opened = true
                throw UnexpectedCall.invoked
            }

            guard case .failure = result else {
                return XCTFail("Unsupported marker version \(unsupportedVersion) must fail closed.")
            }
            XCTAssertFalse(copied)
            XCTAssertFalse(opened)
            XCTAssertEqual(try Data(contentsOf: paths.activeMarkerURL), markerBefore)
            XCTAssertEqual(try Data(contentsOf: storeURL), storeBefore)
        }
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

        let schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
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

    func testCurrentV10ActiveStoreReopensInPlaceWithoutCopyOrRotation() throws {
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
        let schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
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
            return XCTFail("Initial activation must publish a V10 marker.")
        }
        let retainedChekiID = UUID()
        let createdContext = ModelContext(try XCTUnwrap(createdContainer))
        createdContext.insert(Cheki(
            id: retainedChekiID,
            imageRef: "direct-open.jpg",
            note: "direct-open sentinel"
        ))
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
                return XCTFail("A valid V6 active store must not depend on copying.")
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

        let currentSchema = Schema(versionedSchema: ChekinanaSchemaV5.self)
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

    func testRecordCommandsUseSimpleChekiRecordAndRetainLegacyShameDougaEditing() async throws {
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

        guard case .confirmationText(_, let addCode) = await fixture.executor.execute(
            "addrecord cheki idols=\(shortID(firstIdol.id)) date=2026-08-08 size=wide note=new count=3"
        ) else {
            return XCTFail("expected simple Cheki record confirmation")
        }
        try requireSuccess(await fixture.executor.execute("confirm \(addCode)"))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Cheki>()), 0)
        let simpleRecord = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<ChekiRecord>()).first
        )
        XCTAssertEqual(simpleRecord.idols.map(\.id), [firstIdol.id])
        XCTAssertEqual(simpleRecord.date, utcDate(2026, 8, 8))
        XCTAssertEqual(simpleRecord.size, .wide)
        XCTAssertEqual(simpleRecord.note, "new")
        XCTAssertEqual(simpleRecord.count, 3)

        guard case .text = await fixture.executor.execute(
            "addrecord cheki idols=\(shortID(firstIdol.id)) date=2026-08-08 count=101"
        ) else {
            return XCTFail("a single command add delta above 100 must remain rejected")
        }

        guard case .confirmationText(_, let recordEditCode) = await fixture.executor.execute(
            "editrecord cheki target=\(shortID(simpleRecord.id)) idols=\(shortID(firstIdol.id)),\(shortID(secondIdol.id)) size=mini note=edited count=250"
        ) else {
            return XCTFail("expected simple Cheki record edit confirmation")
        }
        try requireSuccess(
            await fixture.executor.execute("confirm \(recordEditCode)")
        )
        XCTAssertEqual(Set(simpleRecord.idols.map(\.id)), [firstIdol.id, secondIdol.id])
        XCTAssertEqual(simpleRecord.size, .mini)
        XCTAssertEqual(simpleRecord.note, "edited")
        XCTAssertEqual(simpleRecord.count, 250)
        let listedRecords = await fixture.executor.execute("listrecord cheki")
        XCTAssertTrue(text(from: listedRecords).contains(shortID(simpleRecord.id)))

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
            size: nil,
            count: 1,
            expectedChekiRecordSnapshot: nil
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

        guard case .confirmationText(_, let recordDeleteCode) = await fixture.executor.execute(
            "editrecord cheki target=\(shortID(simpleRecord.id)) count=0"
        ) else {
            return XCTFail("expected zero-count Cheki record delete confirmation")
        }
        try requireSuccess(
            await fixture.executor.execute("confirm \(recordDeleteCode)")
        )
        XCTAssertEqual(
            try fixture.context.fetchCount(FetchDescriptor<ChekiRecord>()),
            0
        )
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

    func testCalendarGroupsMediaAndCountedRecordsPerIdolWithStableRouting() {
        let first = Idol(name: "A")
        let second = Idol(name: "B")
        let shared = Cheki(idols: [first, second], date: Date(), idx: 1)
        let firstOnly = Cheki(idols: [first], date: Date(), idx: 2)
        let unassigned = Cheki(date: Date(), idx: 1)
        let firstRecord = ChekiRecord(idols: [first], date: Date(), count: 3)
        let secondRecord = ChekiRecord(idols: [second], date: Date(), count: 2)
        let secondRecordOtherIdentity = ChekiRecord(
            idols: [second],
            date: Date(),
            size: .wide,
            note: "other",
            count: 4
        )

        let groups = ChekinanaCalendarIdolGroup.groups(
            for: [shared, firstOnly, unassigned],
            records: [firstRecord, secondRecord, secondRecordOtherIdentity],
            relationshipIndex: .init(idols: [first, second])
        )
        let firstGroup = try! XCTUnwrap(groups.first { $0.idol?.id == first.id })
        let secondGroup = try! XCTUnwrap(groups.first { $0.idol?.id == second.id })
        XCTAssertEqual(firstGroup.chekis.count, 2)
        XCTAssertEqual(firstGroup.count, 5)
        XCTAssertEqual(secondGroup.chekis.count, 1)
        XCTAssertEqual(secondGroup.count, 7)
        XCTAssertEqual(groups.first { $0.idol == nil }?.chekis.count, 1)
        XCTAssertEqual(Set([shared.id, firstOnly.id, unassigned.id]).count, 3)
        XCTAssertEqual(
            ChekinanaCalendarIdolGroupRouting.primaryRoute(for: firstGroup),
            .groupEditor(firstGroup.allObjectIDs)
        )

        let recordOnly = ChekinanaCalendarIdolGroup.groups(
            for: [],
            records: [secondRecord, secondRecordOtherIdentity],
            relationshipIndex: .init(idols: [first, second])
        )[0]
        XCTAssertEqual(
            ChekinanaCalendarIdolGroupRouting.primaryRoute(for: recordOnly),
            .groupEditor([secondRecord.id, secondRecordOtherIdentity.id])
        )
        let singleRecordOnly = ChekinanaCalendarIdolGroup.groups(
            for: [],
            records: [firstRecord],
            relationshipIndex: .init(idols: [first, second])
        )[0]
        XCTAssertEqual(
            ChekinanaCalendarIdolGroupRouting.primaryRoute(for: singleRecordOnly),
            .groupEditor([firstRecord.id])
        )
    }

    func testCalendarSelectedDayGroupsByExactIdolCombinationAndKeepsRepresentativeOrder() {
        let first = Idol(name: "A")
        let second = Idol(name: "B")
        let firstEvent = Event(name: "First Event")
        let secondEvent = Event(name: "Second Event")
        let singleMediaA = Cheki(idols: [first], date: Date(), idx: 1)
        let singleMediaB = Cheki(idols: [first], date: Date(), idx: 2)
        let singleRecord = ChekiRecord(idols: [first], date: Date(), count: 3)
        let multiMediaA = Cheki(idols: [second, first], date: Date(), idx: 3)
        let multiMediaB = Cheki(idols: [first, second], date: Date(), idx: 4)
        let multiRecordA = ChekiRecord(
            idols: [second, first],
            event: firstEvent,
            date: Date(),
            size: .mini,
            count: 4
        )
        let multiRecordB = ChekiRecord(
            idols: [first, second],
            event: secondEvent,
            date: Date(),
            size: .wide,
            count: 5
        )
        let shame = Shame(
            imageRef: "shame.jpg",
            idols: [first, second],
            date: Date()
        )
        let douga = Douga(
            videoRef: "douga.mov",
            idols: [second, first],
            date: Date()
        )

        let groups = ChekinanaCalendarIdolGroup.groups(
            for: [singleMediaA, singleMediaB, multiMediaA, multiMediaB],
            records: [singleRecord, multiRecordA, multiRecordB],
            relationshipIndex: .init(idols: [first, second]),
            groupsByExactIdolCombination: true,
            shames: [shame],
            dougas: [douga]
        )

        XCTAssertEqual(groups.count, 2)
        let singleGroup = try! XCTUnwrap(
            groups.first { $0.combinationKey == .init([first.id]) }
        )
        XCTAssertEqual(singleGroup.chekis.map(\.id), [singleMediaA.id, singleMediaB.id])
        XCTAssertEqual(singleGroup.records.map(\.id), [singleRecord.id])
        XCTAssertEqual(singleGroup.count, 5)
        XCTAssertFalse(singleGroup.isStandaloneMultiIdol)
        XCTAssertFalse(singleGroup.chekis.contains { $0.id == multiMediaA.id })
        XCTAssertFalse(singleGroup.records.contains { $0.id == multiRecordA.id })

        let combinationGroup = try! XCTUnwrap(
            groups.first {
                $0.combinationKey == .init([first.id, second.id])
            }
        )
        XCTAssertTrue(combinationGroup.isStandaloneMultiIdol)
        XCTAssertEqual(combinationGroup.orderedIdols.map(\.id), [second.id, first.id])
        XCTAssertEqual(combinationGroup.chekis.map(\.id), [multiMediaA.id, multiMediaB.id])
        XCTAssertEqual(combinationGroup.records.map(\.id), [multiRecordA.id, multiRecordB.id])
        XCTAssertEqual(combinationGroup.shames.map(\.id), [shame.id])
        XCTAssertEqual(combinationGroup.dougas.map(\.id), [douga.id])
        XCTAssertEqual(combinationGroup.chekiCount, 11)
        XCTAssertEqual(combinationGroup.shameCount, 1)
        XCTAssertEqual(combinationGroup.dougaCount, 1)
        XCTAssertEqual(combinationGroup.count, 13)
        XCTAssertEqual(
            ChekinanaCalendarIdolGroupRouting.primaryRoute(for: combinationGroup),
            .groupEditor(combinationGroup.allObjectIDs)
        )
        XCTAssertEqual(
            Set(combinationGroup.allObjectIDs),
            [
                multiMediaA.id, multiMediaB.id, multiRecordA.id,
                multiRecordB.id, shame.id, douga.id,
            ]
        )

        XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, 18)
    }

    func testCalendarExactCombinationRemainsMultiWhenOnlyOneRelationshipResolves() {
        let idol = Idol(name: "Available")
        let record = ChekiRecord(idols: [idol], date: Date(), count: 2)
        record.idolIDs = [idol.id, UUID()]

        let groups = ChekinanaCalendarIdolGroup.groups(
            for: [],
            records: [record],
            relationshipIndex: .init(idols: [idol]),
            groupsByExactIdolCombination: true
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isStandaloneMultiIdol)
        XCTAssertNil(groups[0].idol)
        XCTAssertEqual(groups[0].orderedIdols.map(\.id), [idol.id])
        XCTAssertEqual(groups[0].records.map(\.id), [record.id])
        XCTAssertEqual(groups[0].count, 2)
    }

    func testCalendarGroupOrderUsesDateAndExactCombinationIdentityWithStableFallback() {
        let dateKey = "2026-08-26"
        let otherDateKey = "2026-08-27"
        let first = "idol-a"
        let second = "idol-a+idol-b"
        let newGroup = "idol-c"
        let orders = [
            CalendarGroupOrder(dateKey: dateKey, groupKey: second, sortOrder: 0),
            CalendarGroupOrder(dateKey: dateKey, groupKey: first, sortOrder: 1),
            CalendarGroupOrder(dateKey: otherDateKey, groupKey: newGroup, sortOrder: -1),
        ]

        XCTAssertEqual(
            ChekinanaCalendarGroupOrderPolicy.orderedGroupKeys(
                [first, second, newGroup],
                dateKey: dateKey,
                orders: orders
            ),
            [second, first, newGroup]
        )
        XCTAssertEqual(
            ChekinanaCalendarGroupOrderPolicy.orderedGroupKeys(
                [newGroup, first],
                dateKey: otherDateKey,
                orders: orders
            ),
            [newGroup, first]
        )
        XCTAssertEqual(
            ChekinanaReorderPreview.move(
                second,
                onto: newGroup,
                in: [second, first, newGroup]
            ),
            [first, newGroup, second]
        )
    }

    @MainActor
    func testCalendarGroupOrderPersistsAndUpsertsWithoutDuplicateIdentity() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV10.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let dateKey = "2026-08-26"

        try ChekinanaCalendarGroupOrderStore.setOrder(
            ["idol-a", "idol-a+idol-b"],
            dateKey: dateKey,
            in: context
        )
        try ChekinanaCalendarGroupOrderStore.setOrder(
            ["idol-a+idol-b", "idol-a"],
            dateKey: dateKey,
            in: context
        )

        let reopenedContext = ModelContext(container)
        let stored = try reopenedContext.fetch(FetchDescriptor<CalendarGroupOrder>())
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(Set(stored.map(\.id)).count, 2)
        XCTAssertEqual(
            ChekinanaCalendarGroupOrderPolicy.orderedGroupKeys(
                ["idol-a", "idol-a+idol-b"],
                dateKey: dateKey,
                orders: stored
            ),
            ["idol-a+idol-b", "idol-a"]
        )
    }

    @MainActor
    func testScheduleClientBuildsExactRequestAndDecodesOffsetOvernightRoute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 29))
        )
        let signature = ChekinanaScheduleRequestSignature(
            mode: .train,
            serviceNumber: " のぞみ 343 ",
            date: date,
            timeZone: calendar.timeZone
        )
        let request = try ChekinanaScheduleClient.request(for: signature)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Scanner-Token"))
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.chekinana.top")
        XCTAssertEqual(components.path, "/api/v1/schedule")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }),
            ["type": "train", "code": "のぞみ343", "date": "2026-08-29"]
        )
        XCTAssertTrue(
            try XCTUnwrap(request.url?.absoluteString)
                .contains("code=%E3%81%AE%E3%81%9E%E3%81%BF343")
        )

        let payload = Data(#"""
        {
          "operator":"jr",
          "stops":[
            {"name":"東京駅","departure":"2026-08-29T23:50:00+09:00"},
            {"name":"名古屋駅","arrival":"2026-08-30T01:30:00+09:00","departure":"2026-08-30T01:35:00+09:00"},
            {"name":"新大阪駅","arrival":"2026-08-30T02:25:00+09:00"}
          ]
        }
        """#.utf8)
        let result = try ChekinanaScheduleClient.decode(
            ChekinanaScheduleHTTPResponse(data: payload, statusCode: 200)
        )
        XCTAssertEqual(result.operatorCode, "jr")
        XCTAssertEqual(result.stops.map(\.name), ["東京駅", "名古屋駅", "新大阪駅"])
        XCTAssertEqual(result.stops[0].departureTimeZone?.secondsFromGMT(), 9 * 3_600)
        XCTAssertEqual(result.stops[2].arrivalTimeZone?.secondsFromGMT(), 9 * 3_600)
        XCTAssertLessThan(
            try XCTUnwrap(result.stops[0].departure),
            try XCTUnwrap(result.stops[2].arrival)
        )
    }

    func testScheduleClientErrorsCancellationSelectionAndOperatorIcons() async throws {
        let validPayload = Data(#"""
        {
          "operator":"MU",
          "stops":[
            {"name":"上海浦东国际机场T1","departure":"2026-08-29T23:50:00+08:00"},
            {"name":"东京羽田机场T3","arrival":"2026-08-30T04:15:00+09:00"}
          ]
        }
        """#.utf8)
        let client = ChekinanaScheduleClient { request in
            let code = request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)
            }?.queryItems?.first(where: { $0.name == "code" })?.value
            if code == "FIRST" {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return ChekinanaScheduleHTTPResponse(data: validPayload, statusCode: 200)
        }
        let date = Date(timeIntervalSince1970: 1_787_936_400)
        let first = Task {
            try await client.schedule(
                mode: .flight,
                serviceNumber: "FIRST",
                date: date
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = try await client.schedule(
            mode: .flight,
            serviceNumber: "MU2482",
            date: date
        )
        XCTAssertEqual(second.operatorCode, "MU")
        do {
            _ = try await first.value
            XCTFail("The superseded lookup must be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let notFound = Data(#"{"error":{"code":"not_found"}}"#.utf8)
        XCTAssertThrowsError(
            try ChekinanaScheduleClient.decode(
                ChekinanaScheduleHTTPResponse(data: notFound, statusCode: 404)
            )
        ) {
            XCTAssertEqual($0 as? ChekinanaScheduleClientError, .notFound)
        }
        for (status, code, expected) in [
            (400, "invalid_date", ChekinanaScheduleClientError.invalidRequest),
            (502, "upstream_failed", .upstreamUnavailable),
            (503, "temporarily_unavailable", .upstreamUnavailable),
        ] {
            let body = Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)
            XCTAssertThrowsError(
                try ChekinanaScheduleClient.decode(
                    ChekinanaScheduleHTTPResponse(data: body, statusCode: status)
                )
            ) {
                XCTAssertEqual($0 as? ChekinanaScheduleClientError, expected)
            }
        }
        let invalidOrder = Data(#"""
        {
          "operator":"CR",
          "stops":[
            {"name":"A","departure":"2026-08-29T12:00:00+08:00"},
            {"name":"B","arrival":"2026-08-29T11:00:00+08:00"}
          ]
        }
        """#.utf8)
        XCTAssertThrowsError(
            try ChekinanaScheduleClient.decode(
                ChekinanaScheduleHTTPResponse(data: invalidOrder, statusCode: 200)
            )
        ) {
            XCTAssertEqual($0 as? ChekinanaScheduleClientError, .invalidSchedule)
        }

        let automatic = try XCTUnwrap(
            ChekinanaTravelRouteSelectionPolicy.automaticSelection(for: second)
        )
        XCTAssertEqual(automatic.0, 0)
        XCTAssertEqual(automatic.1, 1)
        let route = try XCTUnwrap(
            ChekinanaTravelRouteSelectionPolicy.resolvedRoute(
                result: second,
                originIndex: automatic.0,
                destinationIndex: automatic.1
            )
        )
        XCTAssertEqual(route.departureLocation, "上海浦东国际机场T1")
        XCTAssertEqual(route.arrivalLocation, "东京羽田机场T3")
        XCTAssertNil(
            ChekinanaTravelRouteSelectionPolicy.resolvedRoute(
                result: second,
                originIndex: 1,
                destinationIndex: 0
            )
        )
        let middleArrival = try XCTUnwrap(second.stops[1].arrival)
            .addingTimeInterval(-1_800)
        let multiStop = ChekinanaScheduleResult(
            operatorCode: "MU",
            stops: [
                second.stops[0],
                ChekinanaScheduleStop(
                    name: "大阪关西机场T1",
                    arrival: middleArrival,
                    departure: middleArrival.addingTimeInterval(300)
                ),
                second.stops[1],
            ]
        )
        XCTAssertNil(
            ChekinanaTravelRouteSelectionPolicy.automaticSelection(for: multiStop)
        )
        XCTAssertEqual(
            ChekinanaTravelRouteSelectionPolicy.resolvedRoute(
                result: multiStop,
                originIndex: 0,
                destinationIndex: 2
            )?.arrivalLocation,
            "东京羽田机场T3"
        )
        XCTAssertNil(
            ChekinanaTravelRouteSelectionPolicy.resolvedRoute(
                result: multiStop,
                originIndex: 2,
                destinationIndex: 1
            )
        )
        let tappedDestinationFirst = ChekinanaTravelStopTapSelectionPolicy.selection(
            afterTapping: 2,
            in: multiStop,
            current: .init(originIndex: nil, destinationIndex: nil)
        )
        XCTAssertEqual(
            tappedDestinationFirst,
            .init(originIndex: 2, destinationIndex: nil)
        )
        let normalizedSelection = ChekinanaTravelStopTapSelectionPolicy.selection(
            afterTapping: 0,
            in: multiStop,
            current: tappedDestinationFirst
        )
        XCTAssertEqual(
            normalizedSelection,
            .init(originIndex: 0, destinationIndex: 2)
        )
        XCTAssertEqual(
            ChekinanaTravelRouteSelectionPolicy.resolvedRoute(
                result: multiStop,
                originIndex: normalizedSelection.originIndex,
                destinationIndex: normalizedSelection.destinationIndex
            )?.arrivalLocation,
            "东京羽田机场T3"
        )
        let priorPickerData = Data([0x01, 0x02])
        XCTAssertEqual(
            ChekinanaTravelIconPickerPolicy.selectedData(
                afterPickerResult: nil,
                current: priorPickerData
            ),
            priorPickerData,
            "Cancelling the picker must not clear the current icon override"
        )
        XCTAssertEqual(
            ChekinanaTravelIconPickerPolicy.selectedData(
                afterPickerResult: Data([0x03]),
                current: priorPickerData
            ),
            Data([0x03])
        )

        let schema = Schema(versionedSchema: ChekinanaSchemaV12.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let value = TravelSegment(
            mode: .flight,
            serviceNumber: "MU2482",
            departureCity: "",
            departureLocation: route.departureLocation,
            arrivalCity: "",
            arrivalLocation: route.arrivalLocation,
            departureTime: route.departureTime,
            arrivalTime: route.arrivalTime
        )
        _ = try ChekinanaTravelSegmentPersistence.save(
            value,
            inserting: true,
            fields: ChekinanaTravelSegmentFields(
                mode: .flight,
                operatorName: "",
                serviceNumber: "MU2482",
                departureCity: "",
                departureLocation: route.departureLocation,
                arrivalCity: "",
                arrivalLocation: route.arrivalLocation,
                departureTime: route.departureTime,
                arrivalTime: route.arrivalTime,
                seatNumber: "18A",
                carriageNumber: "",
                note: ""
            ),
            operatorIconRef: ChekinanaTravelOperatorIcon.assetReference(
                forOperatorCode: second.operatorCode
            ),
            previousIconRef: nil,
            in: context
        )
        let persisted = try XCTUnwrap(
            try context.fetch(FetchDescriptor<TravelSegment>()).first
        )
        XCTAssertEqual(persisted.departureLocation, route.departureLocation)
        XCTAssertEqual(persisted.arrivalLocation, route.arrivalLocation)
        XCTAssertEqual(persisted.departureTime, route.departureTime)
        XCTAssertEqual(persisted.arrivalTime, route.arrivalTime)
        XCTAssertEqual(persisted.operatorIconRef, "asset://TravelOperatorMU")
        XCTAssertTrue(persisted.departureCity.isEmpty)
        XCTAssertTrue(persisted.arrivalCity.isEmpty)

        let managedOverride = "event-avatar-\(value.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        _ = try ChekinanaTravelSegmentPersistence.save(
            persisted,
            inserting: false,
            expectedUpdatedAt: persisted.updatedAt,
            fields: ChekinanaTravelSegmentFields(
                mode: .flight,
                operatorName: "",
                serviceNumber: "MU2482",
                departureCity: "",
                departureLocation: route.departureLocation,
                arrivalCity: "",
                arrivalLocation: route.arrivalLocation,
                departureTime: route.departureTime,
                arrivalTime: route.arrivalTime,
                seatNumber: "18A",
                carriageNumber: "",
                note: ""
            ),
            operatorIconRef: managedOverride,
            previousIconRef: persisted.operatorIconRef,
            in: context
        )
        XCTAssertEqual(persisted.operatorIconRef, managedOverride)

        XCTAssertEqual(ChekinanaTravelOperatorIcon.airlineCodes.count, 35)
        XCTAssertEqual(ChekinanaTravelOperatorIcon.trainCodes, Set(["CR", "JR"]))
        XCTAssertEqual(
            ChekinanaTravelOperatorIcon.assetReference(forOperatorCode: "mu"),
            "asset://TravelOperatorMU"
        )
        XCTAssertEqual(
            ChekinanaTravelOperatorIcon.assetReference(forOperatorCode: "jr"),
            "asset://TravelOperatorJR"
        )
        XCTAssertNil(ChekinanaTravelOperatorIcon.assetReference(forOperatorCode: "XX"))
        XCTAssertNil(ChekinanaTravelOperatorIcon.assetName(from: "asset://TravelOperatorXX"))
    }

    func testScheduleClientRejectsNonCooperativeABAResponses() async throws {
        let probe = ScheduleNonCooperativeTransportProbe()
        let client = ChekinanaScheduleClient { request in
            try await probe.response(for: request)
        }
        let date = Date(timeIntervalSince1970: 1_787_936_400)
        let oldA = Task {
            try await client.schedule(
                mode: .flight,
                serviceNumber: "ABA",
                date: date
            )
        }
        await probe.waitUntilPending(code: "ABA", count: 1)
        let supersededB = Task {
            try await client.schedule(
                mode: .flight,
                serviceNumber: "B",
                date: date
            )
        }
        await probe.waitUntilPending(code: "B", count: 1)
        let currentA = Task {
            try await client.schedule(
                mode: .flight,
                serviceNumber: "ABA",
                date: date
            )
        }
        await probe.waitUntilPending(code: "ABA", count: 2)

        await probe.resumeNewest(
            code: "ABA",
            response: Self.scheduleResponse(operatorCode: "NEW")
        )
        let currentResult = try await currentA.value
        XCTAssertEqual(currentResult.operatorCode, "NEW")

        await probe.resumeOldest(
            code: "ABA",
            response: Self.scheduleResponse(operatorCode: "OLD")
        )
        await probe.resumeOldest(
            code: "B",
            response: Self.scheduleResponse(operatorCode: "B")
        )
        do {
            _ = try await oldA.value
            XCTFail("The stale first A response must not be returned")
        } catch is CancellationError {
            // Expected even though the transport ignored cancellation.
        }
        do {
            _ = try await supersededB.value
            XCTFail("The stale B response must not be returned")
        } catch is CancellationError {
            // Expected even though the transport ignored cancellation.
        }
    }

    private static func scheduleResponse(
        operatorCode: String
    ) -> ChekinanaScheduleHTTPResponse {
        ChekinanaScheduleHTTPResponse(
            data: Data(#"""
            {
              "operator":"\#(operatorCode)",
              "stops":[
                {"name":"Origin","departure":"2026-08-29T10:00:00+08:00"},
                {"name":"Destination","arrival":"2026-08-29T12:00:00+08:00"}
              ]
            }
            """#.utf8),
            statusCode: 200
        )
    }

    func testTravelOperatorAssetsAreCompleteRGBAAndMediaTravelSourceContracts() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetRoot = projectRoot
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("Assets.xcassets")
        let expectedCodes = ChekinanaTravelOperatorIcon.airlineCodes
            .union(ChekinanaTravelOperatorIcon.trainCodes)
        for code in expectedCodes {
            let imageURL = assetRoot
                .appendingPathComponent("TravelOperator\(code).imageset")
                .appendingPathComponent("TravelOperator\(code).png")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 256, code)
            XCTAssertEqual(image.height, 256, code)
            XCTAssertFalse(
                [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo),
                code
            )
        }

        let productURL = projectRoot
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productURL, encoding: .utf8)
        let viewerStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaChekiImageViewer")?.lowerBound
        )
        let viewerEnd = try XCTUnwrap(
            source.range(
                of: "private struct ChekinanaChekiViewerPage",
                range: viewerStart..<source.endIndex
            )?.lowerBound
        )
        let viewer = source[viewerStart..<viewerEnd]
        XCTAssertTrue(viewer.contains("visibleCheki.idols"))
        XCTAssertTrue(viewer.contains("ChekinanaProductDate.displayString("))
        XCTAssertTrue(viewer.contains("visibleCheki.date"))
        XCTAssertTrue(viewer.contains("onChange(of: visibleID)"))
        XCTAssertTrue(viewer.contains("VStack(alignment: .leading, spacing: 3)"))
        XCTAssertTrue(viewer.contains("size: 34"))
        XCTAssertTrue(viewer.contains(".padding(.horizontal, 16)"))
        XCTAssertTrue(viewer.contains(".padding(.vertical, 8)"))
        XCTAssertFalse(viewer.contains("ChekinanaRecordKind.cheki.title"))

        let detailStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaGalleryMediaDetailView")?.lowerBound
        )
        let detailBodyEnd = try XCTUnwrap(
            source.range(of: ".task(id: item.id)", range: detailStart..<source.endIndex)?.lowerBound
        )
        let detailBody = source[detailStart..<detailBodyEnd]
        XCTAssertFalse(detailBody.contains("Text(item.typeName).font"))
        XCTAssertFalse(detailBody.contains("chekinana.gallery.media.detail.edit"))
        XCTAssertFalse(detailBody.contains("chekinana.gallery.media.detail.export"))
        XCTAssertFalse(detailBody.contains("chekinana.gallery.media.detail.delete"))
        XCTAssertTrue(detailBody.contains("onSingleTap: { isEditing = true }"))

        let editorStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaGalleryMetadataEditor")?.lowerBound
        )
        let editorEnd = try XCTUnwrap(
            source.range(
                of: "private enum ChekinanaProductPhotoSaver",
                range: editorStart..<source.endIndex
            )?.lowerBound
        )
        let editor = source[editorStart..<editorEnd]
        XCTAssertTrue(editor.contains("gallery.save_to_photos"))
        XCTAssertTrue(editor.contains("foregroundStyle(.red)"))
        XCTAssertTrue(editor.contains("isDeleteConfirmationPresented"))
        XCTAssertTrue(editor.contains("stageFilesForDeletion"))
        XCTAssertTrue(editor.contains("modelContext.rollback()"))
        XCTAssertTrue(editor.contains("restoreStagedFiles(staged)"))

        let travelStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaTravelSegmentEditorView")?.lowerBound
        )
        let travelEnd = try XCTUnwrap(
            source.range(
                of: "private struct ChekinanaEventDetailView",
                range: travelStart..<source.endIndex
            )?.lowerBound
        )
        let travel = source[travelStart..<travelEnd]
        XCTAssertTrue(travel.contains("lookupSchedule()"))
        XCTAssertTrue(travel.contains("scheduleSelection(result:"))
        XCTAssertTrue(travel.contains("hasInvalidatedStoredRoute"))
        XCTAssertTrue(travel.contains("@State private var lookupRequestID: UUID?"))
        XCTAssertTrue(travel.contains("let requestID = UUID()"))
        XCTAssertGreaterThanOrEqual(
            travel.components(separatedBy: "lookupRequestID == requestID").count - 1,
            3
        )
        XCTAssertTrue(travel.contains("lookupRequestID = nil"))
        XCTAssertTrue(travel.contains("PhotosPicker(selection: $iconPickerItem"))
        XCTAssertTrue(travel.contains("ChekinanaEventAvatarStore.save("))
        XCTAssertTrue(travel.contains("selectedIconData = nil"))
        XCTAssertTrue(travel.contains("isServiceNumberFocused = false"))
        XCTAssertTrue(travel.contains("Button {\n                    selectStop(index"))
        XCTAssertTrue(travel.contains("Text(result.stops[index].name)"))
        XCTAssertTrue(travel.contains("Text(stopTimeLabel(at: index, in: result))"))
        XCTAssertTrue(travel.contains(
            ".frame(maxWidth: .infinity, alignment: .leading)\n                    .contentShape(Rectangle())"
        ))
        XCTAssertFalse(travel.contains("travel.schedule.origin\", \"Origin\"),\n                    selection:"))
        XCTAssertFalse(travel.contains("travel.schedule.destination\", \"Destination\"),\n                    selection:"))
        XCTAssertFalse(travel.contains("trainOperatorPreset"))
        XCTAssertFalse(travel.contains("@State private var departureCity"))
        XCTAssertFalse(travel.contains("@State private var arrivalCity"))
        XCTAssertFalse(travel.contains("text: $departureCity"))
        XCTAssertFalse(travel.contains("text: $arrivalCity"))

        let galleryStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaGalleryView")?.lowerBound
        )
        let galleryEnd = try XCTUnwrap(
            source.range(
                of: "private struct ChekinanaGalleryCompactFilterLabel",
                range: galleryStart..<source.endIndex
            )?.lowerBound
        )
        let gallery = source[galleryStart..<galleryEnd]
        XCTAssertFalse(gallery.contains("navigationTitle(ChekinanaProductTab.gallery.title)"))
        XCTAssertFalse(gallery.contains("ToolbarItem(placement: .principal)"))
        XCTAssertTrue(gallery.contains("Text(ChekinanaProductTab.gallery.title)"))
        XCTAssertTrue(gallery.contains("chekinana.gallery.title"))
        XCTAssertTrue(gallery.contains("HStack(alignment: .center, spacing: 12)"))
        XCTAssertTrue(gallery.contains("chekinana.gallery.header"))
        XCTAssertTrue(source.contains(
            ".frame(minWidth: 96, idealWidth: 138, maxWidth: 138)"
        ))
        let galleryTitle = try XCTUnwrap(
            gallery.range(of: "chekinana.gallery.title")?.lowerBound
        )
        let gridControls = try XCTUnwrap(
            gallery.range(of: "chekinana.gallery.grid-controls")?.lowerBound
        )
        let mediaType = try XCTUnwrap(
            gallery.range(of: "Picker(\"Media type\"")?.lowerBound
        )
        XCTAssertLessThan(galleryTitle, gridControls)
        XCTAssertLessThan(gridControls, mediaType)
        XCTAssertTrue(gallery.contains("private var filteredChekis: [Cheki]"))
        XCTAssertTrue(gallery.contains("chekis: filteredChekis"))

        let idolGroupStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaIdolMediaDateGroupView")?.lowerBound
        )
        let idolGroupEnd = try XCTUnwrap(
            source.range(
                of: "private struct ChekinanaIdolNoMediaChekiGroupView",
                range: idolGroupStart..<source.endIndex
            )?.lowerBound
        )
        let idolGroup = source[idolGroupStart..<idolGroupEnd]
        XCTAssertTrue(idolGroup.contains("private var dateGroupMediaChekis: [Cheki]"))
        XCTAssertTrue(idolGroup.contains("chekis: dateGroupMediaChekis"))
        XCTAssertTrue(idolGroup.contains("initialID: value.id"))
    }

    @MainActor
    func testTravelSegmentValidationCRUDAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-travel-crud-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("travel.store")
        let schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        func container() throws -> ModelContainer {
            try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(
                    "TravelCRUD",
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )]
            )
        }

        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        let arrival = departure.addingTimeInterval(7_200)
        let validFields = ChekinanaTravelSegmentFields(
            mode: .train,
            operatorName: ChekinanaTrainOperatorPreset.jrEast.title,
            serviceNumber: "はやぶさ25号",
            departureCity: "東京",
            departureLocation: "東京駅",
            arrivalCity: "仙台",
            arrivalLocation: "仙台駅",
            departureTime: departure,
            arrivalTime: arrival,
            seatNumber: "7A",
            carriageNumber: "5",
            note: "window"
        )
        XCTAssertNoThrow(try ChekinanaTravelSegmentValidator.validate(validFields))
        var routeWithoutLegacyCities = validFields
        routeWithoutLegacyCities.departureCity = ""
        routeWithoutLegacyCities.arrivalCity = ""
        XCTAssertNoThrow(
            try ChekinanaTravelSegmentValidator.validate(routeWithoutLegacyCities)
        )
        var invalid = validFields
        invalid.arrivalTime = departure.addingTimeInterval(-1)
        XCTAssertThrowsError(try ChekinanaTravelSegmentValidator.validate(invalid)) {
            XCTAssertEqual(
                $0 as? ChekinanaTravelSegmentValidationError,
                .arrivalBeforeDeparture
            )
        }
        invalid = validFields
        invalid.departureLocation = ""
        XCTAssertThrowsError(try ChekinanaTravelSegmentValidator.validate(invalid)) {
            XCTAssertEqual(
                $0 as? ChekinanaTravelSegmentValidationError,
                .missingRequiredFields
            )
        }

        var firstContainer: ModelContainer? = try container()
        let id = UUID()
        do {
            let context = ModelContext(try XCTUnwrap(firstContainer))
            let segment = TravelSegment(
                id: id,
                mode: .train,
                serviceNumber: validFields.serviceNumber,
                departureCity: validFields.departureCity,
                departureLocation: validFields.departureLocation,
                arrivalCity: validFields.arrivalCity,
                arrivalLocation: validFields.arrivalLocation,
                departureTime: departure,
                arrivalTime: arrival
            )
            _ = try ChekinanaTravelSegmentPersistence.save(
                segment,
                inserting: true,
                fields: validFields,
                operatorIconRef: nil,
                previousIconRef: nil,
                in: context
            )
        }
        firstContainer = nil

        var reopened: ModelContainer? = try container()
        do {
            let context = ModelContext(try XCTUnwrap(reopened))
            let stored = try XCTUnwrap(
                try context.fetch(FetchDescriptor<TravelSegment>()).first
            )
            XCTAssertEqual(stored.id, id)
            XCTAssertEqual(stored.mode, .train)
            XCTAssertEqual(stored.carriageNumber, "5")
            var flightFields = validFields
            flightFields.mode = .flight
            flightFields.carriageNumber = "must clear"
            _ = try ChekinanaTravelSegmentPersistence.save(
                stored,
                inserting: false,
                expectedUpdatedAt: stored.updatedAt,
                fields: flightFields,
                operatorIconRef: nil,
                previousIconRef: nil,
                in: context
            )
            XCTAssertNil(stored.carriageNumber)
        }
        reopened = nil

        let finalContainer = try container()
        let finalContext = ModelContext(finalContainer)
        let final = try XCTUnwrap(
            try finalContext.fetch(FetchDescriptor<TravelSegment>()).first
        )
        XCTAssertEqual(final.mode, .flight)
        try ChekinanaTravelSegmentPersistence.delete(final, from: finalContext)
        XCTAssertEqual(
            try finalContext.fetchCount(FetchDescriptor<TravelSegment>()),
            0
        )
    }

    @MainActor
    func testExpiredTravelIsExcludedAndPersistentlyPrunedWhileFutureTravelStaysOrdered() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 12))
        )
        func segment(id: UUID, departure: Date, serviceNumber: String) -> TravelSegment {
            TravelSegment(
                id: id,
                mode: .flight,
                serviceNumber: serviceNumber,
                departureCity: "上海",
                departureLocation: "PVG",
                arrivalCity: "東京",
                arrivalLocation: "HND",
                departureTime: departure,
                arrivalTime: departure.addingTimeInterval(7_200)
            )
        }

        let expired = segment(
            id: UUID(),
            departure: now.addingTimeInterval(-86_400),
            serviceNumber: "EXPIRED"
        )
        let later = segment(
            id: UUID(),
            departure: now.addingTimeInterval(2 * 86_400),
            serviceNumber: "LATER"
        )
        let sooner = segment(
            id: UUID(),
            departure: now.addingTimeInterval(86_400),
            serviceNumber: "SOONER"
        )
        [expired, later, sooner].forEach(context.insert)
        try context.save()

        let visible = ChekinanaTravelTimelinePolicy.futureSegments(
            [expired, later, sooner],
            from: now,
            calendar: calendar
        )
        XCTAssertEqual(Set(visible.map(\.id)), Set([later.id, sooner.id]))
        XCTAssertFalse(
            ChekinanaTravelTimelinePolicy.isUpcoming(
                departureTime: expired.departureTime,
                from: now,
                calendar: calendar
            )
        )
        XCTAssertEqual(
            ChekinanaTimelineOrdering.ordered(
                visible.map {
                    ChekinanaTimelineOrderingValue(
                        id: $0.id.uuidString,
                        title: $0.serviceNumber,
                        effectiveTime: $0.departureTime
                    )
                },
                ascending: true
            ).map(\.id),
            [sooner.id.uuidString, later.id.uuidString]
        )

        XCTAssertEqual(
            ChekinanaTravelTimelinePolicy.pruneExpiredSegments(
                [expired, later, sooner],
                from: now,
                calendar: calendar,
                in: context
            ),
            1
        )
        let stored = try context.fetch(FetchDescriptor<TravelSegment>())
        XCTAssertEqual(Set(stored.map(\.id)), Set([later.id, sooner.id]))
    }

    func testV10MigratesToV11WithoutLosingExistingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-v10-v11-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("migration.store")
        let idolID = UUID()
        let eventID = UUID()

        let v10Schema = Schema(versionedSchema: ChekinanaSchemaV10.self)
        var v10Container: ModelContainer? = try ModelContainer(
            for: v10Schema,
            configurations: [ModelConfiguration(
                "V10TravelMigration",
                schema: v10Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(v10Container))
            context.insert(Idol(id: idolID, name: "Preserved"))
            context.insert(Event(id: eventID, name: "Preserved Event"))
            context.insert(CalendarGroupOrder(
                dateKey: "2027-01-03",
                groupKey: idolID.uuidString.lowercased(),
                sortOrder: 0
            ))
            try context.save()
        }
        v10Container = nil

        let v11Schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        var v11Container: ModelContainer? = try ModelContainer(
            for: v11Schema,
            migrationPlan: ChekinanaSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(
                "V10TravelMigration",
                schema: v11Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(v11Container))
            XCTAssertEqual(
                try context.fetch(FetchDescriptor<Idol>()).first?.id,
                idolID
            )
            XCTAssertEqual(
                try context.fetch(FetchDescriptor<Event>()).first?.id,
                eventID
            )
            XCTAssertEqual(
                try context.fetch(FetchDescriptor<CalendarGroupOrder>()).count,
                1
            )
            XCTAssertTrue(
                try context.fetch(FetchDescriptor<TravelSegment>()).isEmpty
            )
        }
        v11Container = nil
        XCTAssertEqual(
            try ChekinanaDataStore.physicalStoreVersion(at: storeURL),
            .v11
        )
    }

    func testV11MigratesMediaShotTypeToV12WithoutLosingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-v11-v12-media-shot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("migration.store")
        let idolID = UUID()
        let shameID = UUID()
        let dougaID = UUID()
        let day = try XCTUnwrap(
            ChekinanaDateOnly.canonicalDate(year: 2027, month: 3, day: 4)
        )

        let v11Schema = Schema(versionedSchema: ChekinanaSchemaV11.self)
        var v11Container: ModelContainer? = try ModelContainer(
            for: v11Schema,
            configurations: [ModelConfiguration(
                "V11MediaShotMigration",
                schema: v11Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(v11Container))
            let idol = Idol(id: idolID, name: "Preserved")
            context.insert(idol)
            context.insert(Shame(
                id: shameID,
                imageRef: "preserved.jpg",
                idols: [idol],
                date: day,
                note: "shame-note"
            ))
            context.insert(Douga(
                id: dougaID,
                videoRef: "preserved.mov",
                idols: [idol],
                date: day,
                note: "douga-note"
            ))
            try context.save()
        }
        v11Container = nil

        let v12Schema = Schema(versionedSchema: ChekinanaSchemaV12.self)
        let v12Container = try ModelContainer(
            for: v12Schema,
            migrationPlan: ChekinanaSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(
                "V11MediaShotMigration",
                schema: v12Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(v12Container)
        let shame = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Shame>()).first
        )
        let douga = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Douga>()).first
        )
        XCTAssertEqual(shame.id, shameID)
        XCTAssertEqual(shame.imageRef, "preserved.jpg")
        XCTAssertEqual(shame.idols.map(\.id), [idolID])
        XCTAssertEqual(shame.date, day)
        XCTAssertEqual(shame.note, "shame-note")
        XCTAssertEqual(douga.id, dougaID)
        XCTAssertEqual(douga.videoRef, "preserved.mov")
        XCTAssertEqual(douga.idols.map(\.id), [idolID])
        XCTAssertEqual(douga.date, day)
        XCTAssertEqual(douga.note, "douga-note")
        let shotTypes = try context.fetch(FetchDescriptor<MediaShotType>())
        XCTAssertTrue(shotTypes.isEmpty)
        XCTAssertFalse(ChekinanaMediaShotTypeStore.userAppears(
            mediaID: shameID,
            kind: .shame,
            values: shotTypes
        ))
        XCTAssertFalse(ChekinanaMediaShotTypeStore.userAppears(
            mediaID: dougaID,
            kind: .douga,
            values: shotTypes
        ))
        XCTAssertEqual(
            try ChekinanaDataStore.physicalStoreVersion(at: storeURL),
            .v12
        )
    }

    func testTimelineOrderingUsesEventStartThenOpenAndTravelDeparture() throws {
        let day = try XCTUnwrap(
            ChekinanaDateOnly.canonicalDate(year: 2027, month: 1, day: 3)
        )
        let openOnly = Event(id: UUID(), name: "Open", date: day)
        let started = Event(id: UUID(), name: "Start", date: day)
        let dateOnly = Event(id: UUID(), name: "Date only", date: day)
        let schedules = [
            EventSchedule(eventID: openOnly.id, openTime: "09:00"),
            EventSchedule(eventID: started.id, openTime: "07:00"),
            EventSchedule(eventID: started.id, openTime: "08:00", startTime: "15:00"),
        ]
        let openTime = try XCTUnwrap(
            ChekinanaEventOrdering.effectiveDate(for: openOnly, schedules: schedules)
        )
        let startTime = try XCTUnwrap(
            ChekinanaEventOrdering.effectiveDate(for: started, schedules: schedules)
        )
        let dateOnlyTime = try XCTUnwrap(
            ChekinanaEventOrdering.effectiveDate(for: dateOnly, schedules: schedules)
        )
        XCTAssertEqual(dateOnlyTime, Calendar.current.startOfDay(for: openTime))
        let travelTime = openTime.addingTimeInterval(3 * 60 * 60)
        let values = [
            ChekinanaTimelineOrderingValue(
                id: "event-date-only",
                title: dateOnly.name,
                effectiveTime: dateOnlyTime
            ),
            ChekinanaTimelineOrderingValue(
                id: "event-start",
                title: started.name,
                effectiveTime: startTime
            ),
            ChekinanaTimelineOrderingValue(
                id: "travel",
                title: "上海 → 东京",
                effectiveTime: travelTime
            ),
            ChekinanaTimelineOrderingValue(
                id: "event-open",
                title: openOnly.name,
                effectiveTime: openTime
            ),
        ]
        XCTAssertEqual(
            ChekinanaTimelineOrdering.ordered(values, ascending: true).map(\.id),
            ["event-date-only", "event-open", "travel", "event-start"]
        )
        XCTAssertEqual(
            ChekinanaTimelineOrdering.ordered(values, ascending: false).map(\.id),
            ["event-start", "travel", "event-open", "event-date-only"]
        )
    }

    func testCalendarEventIconAndOutsideMonthPoliciesExcludeTravel() throws {
        XCTAssertTrue(
            ChekinanaCalendarDayContentPolicy.showsEventIcon(
                hasEvent: true,
                isSelected: false
            )
        )
        XCTAssertFalse(
            ChekinanaCalendarDayContentPolicy.showsEventIcon(
                hasEvent: true,
                isSelected: true
            )
        )
        XCTAssertFalse(
            ChekinanaCalendarDayContentPolicy.showsEventIcon(
                hasEvent: false,
                isSelected: false
            )
        )
        XCTAssertTrue(
            ChekinanaCalendarDayContentPolicy.usesSecondaryDateNumber(
                isInDisplayedMonth: false
            )
        )
        XCTAssertFalse(
            ChekinanaCalendarDayContentPolicy.usesSecondaryDateNumber(
                isInDisplayedMonth: true
            )
        )
        XCTAssertTrue(
            ChekinanaCalendarDayContentPolicy.usesSecondaryChekiCount(
                isInDisplayedMonth: false
            )
        )
        XCTAssertFalse(
            ChekinanaCalendarDayContentPolicy.usesSecondaryChekiCount(
                isInDisplayedMonth: true
            )
        )

        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let calendarStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaCalendarView")?.lowerBound
        )
        let calendarEnd = try XCTUnwrap(
            source.range(
                of: "private enum ChekinanaCalendarNoMediaRecord",
                range: calendarStart..<source.endIndex
            )?.lowerBound
        )
        let calendar = source[calendarStart..<calendarEnd]
        XCTAssertTrue(calendar.contains("music.note.house"))
        XCTAssertTrue(calendar.contains("showsEventIcon"))
        XCTAssertTrue(calendar.contains("day-event."))
        XCTAssertTrue(calendar.contains("isInDisplayedMonth"))
        XCTAssertTrue(calendar.contains("chekiCountForeground"))
        XCTAssertTrue(calendar.contains("usesSecondaryChekiCount"))
        XCTAssertFalse(calendar.contains("TravelSegment"))
    }

    func testEventsTimelineSourceHasTravelRoutesAndNoOrderButton() throws {
        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private struct ChekinanaEventsView")?.lowerBound
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private struct ChekinanaTravelOperatorAvatar",
                range: start..<source.endIndex
            )?.lowerBound
        )
        let eventsView = source[start..<end]
        XCTAssertTrue(eventsView.contains("@Query private var travelSegments"))
        XCTAssertTrue(eventsView.contains("airplane.departure"))
        XCTAssertTrue(eventsView.contains("HStack(spacing: 0)"))
        XCTAssertTrue(eventsView.contains(".font(.system(size: 14, weight: .regular))"))
        XCTAssertTrue(eventsView.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(eventsView.contains("ChekinanaEventTimelineEntry.travel"))
        XCTAssertTrue(eventsView.contains("ascending: true"))
        XCTAssertTrue(eventsView.contains("ascending: false"))
        XCTAssertTrue(eventsView.contains("segment.departureTime"))
        XCTAssertTrue(eventsView.contains("ChekinanaTravelTimelinePolicy.futureSegments("))
        XCTAssertTrue(eventsView.contains("pruneExpiredTravelSegments(from:"))
        let pastStart = try XCTUnwrap(
            eventsView.range(of: "private var past:")?.lowerBound
        )
        let pastEnd = try XCTUnwrap(
            eventsView.range(
                of: "private var undated:",
                range: pastStart..<eventsView.endIndex
            )?.lowerBound
        )
        let pastPartition = eventsView[pastStart..<pastEnd]
        XCTAssertTrue(pastPartition.contains("datedEvents.filter"))
        XCTAssertTrue(pastPartition.contains(") < 0"))
        XCTAssertFalse(pastPartition.contains("TravelSegment"))
        XCTAssertFalse(pastPartition.contains("futureSegments"))
        XCTAssertTrue(
            source.contains(
                #""\(segment.displayedDepartureLocation) → \(segment.displayedArrivalLocation)""#
            )
        )
        XCTAssertFalse(eventsView.contains("chekinana.events.sort"))
        XCTAssertFalse(eventsView.contains("sortsAscending"))
    }

    func testCalendarMonthYearWheelSelectsImmediatelyAndClampsDay() throws {
        let january31 = utcDate(2027, 1, 31)
        let commonYear = try XCTUnwrap(
            ChekinanaCalendarMonthYearWheelPolicy.selection(
                year: 2027,
                month: 2,
                preservingDayFrom: january31
            )
        )
        XCTAssertEqual(
            ChekinanaProductDate.calendar.dateComponents(
                [.year, .month, .day],
                from: commonYear.selectedDate
            ),
            DateComponents(year: 2027, month: 2, day: 28)
        )
        let leapYear = try XCTUnwrap(
            ChekinanaCalendarMonthYearWheelPolicy.selection(
                year: 2028,
                month: 2,
                preservingDayFrom: january31
            )
        )
        XCTAssertEqual(
            ChekinanaProductDate.calendar.dateComponents(
                [.year, .month, .day],
                from: leapYear.selectedDate
            ),
            DateComponents(year: 2028, month: 2, day: 29)
        )
        XCTAssertNil(ChekinanaCalendarMonthYearWheelPolicy.selection(
            year: 0,
            month: 1,
            preservingDayFrom: january31
        ))
        XCTAssertNil(ChekinanaCalendarMonthYearWheelPolicy.selection(
            year: 2027,
            month: 13,
            preservingDayFrom: january31
        ))

        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let calendarStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaCalendarView")?.lowerBound
        )
        let calendarEnd = try XCTUnwrap(
            source.range(
                of: "private enum ChekinanaCalendarNoMediaRecord",
                range: calendarStart..<source.endIndex
            )?.lowerBound
        )
        let calendar = String(source[calendarStart..<calendarEnd])
        XCTAssertTrue(calendar.contains("isMonthYearWheelExpanded.toggle()"))
        XCTAssertTrue(calendar.contains("ChekinanaCalendarMonthYearWheels("))
        XCTAssertFalse(calendar.contains("ChekinanaMonthPicker("))
        XCTAssertFalse(calendar.contains("isPickingMonth"))

        let wheelsStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaCalendarMonthYearWheels")?.lowerBound
        )
        let wheelsEnd = try XCTUnwrap(
            source.range(
                of: "private struct ChekinanaMonthPicker",
                range: wheelsStart..<source.endIndex
            )?.lowerBound
        )
        let wheels = String(source[wheelsStart..<wheelsEnd])
        XCTAssertTrue(wheels.contains(".pickerStyle(.wheel)"))
        XCTAssertTrue(wheels.contains("month-year.year-wheel"))
        XCTAssertTrue(wheels.contains("month-year.month-wheel"))
        XCTAssertTrue(wheels.contains("displayedMonth = next.displayedMonth"))
        XCTAssertTrue(wheels.contains("selectedDate = next.selectedDate"))
    }

    func testIdolCardChekiCountAddsRecordQuantityInsteadOfRecordRows() {
        let target = Idol(name: "Target")
        let other = Idol(name: "Other")
        let firstMedia = Cheki(idols: [target], imageRef: "first.jpg")
        let secondMedia = Cheki(idols: [target], imageRef: "second.jpg")
        let sharedMedia = Cheki(idols: [other, target], imageRef: "shared.jpg")
        let countedRecord = ChekiRecord(
            idols: [target, other],
            count: 3
        )

        var counts = ChekinanaIdolCardChekiCount.countsByIdolID(
            mediaChekis: [firstMedia, secondMedia, sharedMedia],
            simpleRecords: [countedRecord],
            hiddenIDs: []
        )
        XCTAssertEqual(counts[target.id], 6)
        XCTAssertEqual(counts[other.id], 4)

        firstMedia.imageRef = nil
        counts = ChekinanaIdolCardChekiCount.countsByIdolID(
            mediaChekis: [firstMedia, secondMedia, sharedMedia],
            simpleRecords: [countedRecord],
            hiddenIDs: []
        )
        XCTAssertEqual(counts[target.id], 5)
        XCTAssertEqual(counts[other.id], 4)
    }

    func testSimpleRecordsRemainLinkedWhileGalleryOnlyAcceptsMediaModels() {
        let idol = Idol(name: "Local")
        let record = ChekiRecord(idols: [idol], date: Date(), size: .mini)
        let cheki = Cheki(idols: [idol], date: Date(), imageRef: "media.jpg")
        let shame = Shame(idols: [idol], date: Date())
        let douga = Douga(idols: [idol], date: Date())

        XCTAssertTrue(ChekinanaGalleryItem.cheki(cheki).hasMedia)
        XCTAssertFalse(ChekinanaGalleryItem.shame(shame).hasMedia)
        XCTAssertFalse(ChekinanaGalleryItem.douga(douga).hasMedia)
        XCTAssertEqual(cheki.idols.map(\.id), [idol.id])
        XCTAssertEqual(record.idols.map(\.id), [idol.id])
        XCTAssertEqual(shame.idols.map(\.id), [idol.id])
        XCTAssertEqual(douga.idols.map(\.id), [idol.id])
    }

    func testSimpleRecordsPersistEditAndDeleteInMemory() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let idol = Idol(name: "Persisted")
        let record = ChekiRecord(idols: [idol], date: Date(), size: .mini, note: "before")
        let shame = Shame(idols: [idol], date: Date(), note: "before")
        let douga = Douga(idols: [idol], date: Date())
        context.insert(idol); context.insert(record); context.insert(shame); context.insert(douga)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Cheki>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChekiRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Shame>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Douga>()), 1)
        XCTAssertFalse(ChekinanaGalleryItem.shame(shame).hasMedia)
        XCTAssertFalse(ChekinanaGalleryItem.douga(douga).hasMedia)
        record.note = "after"; try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChekiRecord>()).first?.note, "after")
        context.delete(record); context.delete(douga); try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChekiRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Douga>()), 0)
    }

    func testChekiRecordExpectedSnapshotRejectsLateIncrementAndDeletionWithoutPartialWrite() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let editorContext = ModelContext(container)
        let idol = Idol(name: "Snapshot Idol")
        let day = utcDate(2026, 8, 24)
        let record = ChekiRecord(
            idols: [idol],
            date: day,
            size: .mini,
            note: "original",
            count: 2
        )
        let deletedRecord = ChekiRecord(
            idols: [idol],
            date: day,
            size: .wide,
            note: "delete target",
            count: 1
        )
        editorContext.insert(idol)
        editorContext.insert(record)
        editorContext.insert(deletedRecord)
        try editorContext.save()
        let staleSnapshot = ChekinanaChekiRecordSnapshot(record)
        let deletedSnapshot = ChekinanaChekiRecordSnapshot(deletedRecord)

        let importerContext = ModelContext(container)
        try ChekinanaChekiRecordStore.withMutationLock {
            let live = try XCTUnwrap(
                importerContext.fetch(FetchDescriptor<ChekiRecord>())
                    .first { $0.id == record.id }
            )
            live.count += 3
            try importerContext.save()
        }

        XCTAssertThrowsError(try ChekinanaChekiRecordStore.update(
            record,
            idols: [idol],
            event: nil,
            date: day,
            size: .wide,
            note: "stale overwrite",
            count: 2,
            expected: staleSnapshot,
            in: editorContext
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaChekiRecordMutationError,
                .changedRecord
            )
        }
        var verification = ModelContext(container)
        var values = try verification.fetch(FetchDescriptor<ChekiRecord>())
        let incremented = try XCTUnwrap(values.first { $0.id == record.id })
        XCTAssertEqual(incremented.count, 5)
        XCTAssertEqual(incremented.note, "original")
        XCTAssertEqual(incremented.size, .mini)

        let deletionContext = ModelContext(container)
        try ChekinanaChekiRecordStore.withMutationLock {
            let live = try XCTUnwrap(
                deletionContext.fetch(FetchDescriptor<ChekiRecord>())
                    .first { $0.id == deletedRecord.id }
            )
            deletionContext.delete(live)
            try deletionContext.save()
        }
        XCTAssertThrowsError(try ChekinanaChekiRecordStore.update(
            deletedRecord,
            idols: [idol],
            event: nil,
            date: day,
            size: .wide,
            note: "must not resurrect",
            count: 4,
            expected: deletedSnapshot,
            in: editorContext
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaChekiRecordMutationError,
                .changedRecord
            )
        }
        verification = ModelContext(container)
        values = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertNil(values.first { $0.id == deletedRecord.id })
        XCTAssertEqual(values.first { $0.id == record.id }?.count, 5)
    }

    func testChekiRecordSaveFailuresRollbackEveryMutationAndReleaseGate() throws {
        enum InjectedFailure: Error { case save }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-record-save-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Records.store")
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let configuration = ModelConfiguration(
            "Records",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let idolID = UUID()
        let recordID = UUID()
        let day = utcDate(2026, 8, 24)

        var container: ModelContainer? = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        do {
            let context = ModelContext(try XCTUnwrap(container))
            let idol = Idol(id: idolID, name: "Rollback Idol")
            context.insert(idol)
            context.insert(ChekiRecord(
                id: recordID,
                idols: [idol],
                date: day,
                size: .mini,
                note: "original",
                count: 2
            ))
            try context.save()
        }

        do {
            let context = ModelContext(try XCTUnwrap(container))
            let idol = try XCTUnwrap(
                context.fetch(FetchDescriptor<Idol>()).first { $0.id == idolID }
            )
            XCTAssertThrowsError(try ChekinanaChekiRecordStore.upsert(
                idols: [idol],
                event: nil,
                date: day,
                size: .mini,
                note: "original",
                adding: 3,
                in: context,
                saveContext: { _ in throw InjectedFailure.save }
            ))
        }
        do {
            let context = ModelContext(try XCTUnwrap(container))
            let idol = try XCTUnwrap(context.fetch(FetchDescriptor<Idol>()).first)
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<ChekiRecord>()).first)
            let snapshot = ChekinanaChekiRecordSnapshot(record)
            XCTAssertEqual(record.count, 2)
            XCTAssertThrowsError(try ChekinanaChekiRecordStore.update(
                record,
                idols: [idol],
                event: nil,
                date: day,
                size: .wide,
                note: "dirty update",
                count: 9,
                expected: snapshot,
                in: context,
                saveContext: { _ in throw InjectedFailure.save }
            ))
        }
        do {
            let context = ModelContext(try XCTUnwrap(container))
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<ChekiRecord>()).first)
            XCTAssertEqual(record.count, 2)
            XCTAssertEqual(record.note, "original")
            XCTAssertEqual(record.size, .mini)
            XCTAssertThrowsError(try ChekinanaChekiRecordStore.delete(
                record,
                expected: ChekinanaChekiRecordSnapshot(record),
                in: context,
                saveContext: { _ in throw InjectedFailure.save }
            ))
        }
        do {
            let context = ModelContext(try XCTUnwrap(container))
            let idol = try XCTUnwrap(context.fetch(FetchDescriptor<Idol>()).first)
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<ChekiRecord>()).first)
            XCTAssertEqual(record.count, 2)
            _ = try ChekinanaChekiRecordStore.upsert(
                idols: [idol],
                event: nil,
                date: day,
                size: .mini,
                note: "original",
                adding: 3,
                in: context
            )
        }
        container = nil

        container = try ModelContainer(for: schema, configurations: [configuration])
        let reopened = ModelContext(try XCTUnwrap(container))
        let records = try reopened.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, recordID)
        XCTAssertEqual(records.first?.count, 5)
        XCTAssertEqual(records.first?.note, "original")
        XCTAssertEqual(records.first?.size, .mini)
    }

    func testChekiRecordMutationRejectsRelationshipsDeletedAfterResolveWithoutDanglingKeys() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let originalIdol = Idol(name: "Original Idol")
        let targetIdol = Idol(name: "Deleted Target")
        let targetEvent = Event(name: "Deleted Event")
        let day = utcDate(2026, 8, 24)
        let original = ChekiRecord(
            idols: [originalIdol],
            date: day,
            size: .mini,
            note: "original",
            count: 2
        )
        setup.insert(originalIdol)
        setup.insert(targetIdol)
        setup.insert(targetEvent)
        setup.insert(original)
        try setup.save()
        let originalIdolID = originalIdol.id
        let targetIdolID = targetIdol.id
        let targetEventID = targetEvent.id
        let originalID = original.id

        let addContext = ModelContext(container)
        let addTargetIdol = try XCTUnwrap(
            addContext.fetch(FetchDescriptor<Idol>()).first { $0.id == targetIdolID }
        )
        let addTargetEvent = try XCTUnwrap(
            addContext.fetch(FetchDescriptor<Event>()).first { $0.id == targetEventID }
        )
        let editContext = ModelContext(container)
        let editTargetIdol = try XCTUnwrap(
            editContext.fetch(FetchDescriptor<Idol>()).first { $0.id == targetIdolID }
        )
        let editTargetEvent = try XCTUnwrap(
            editContext.fetch(FetchDescriptor<Event>()).first { $0.id == targetEventID }
        )
        let editRecord = try XCTUnwrap(
            editContext.fetch(FetchDescriptor<ChekiRecord>()).first { $0.id == originalID }
        )
        let editSnapshot = ChekinanaChekiRecordSnapshot(editRecord)

        let deletionContext = ModelContext(container)
        let deleteEvent = try XCTUnwrap(
            deletionContext.fetch(FetchDescriptor<Event>()).first { $0.id == targetEventID }
        )
        let deleteIdol = try XCTUnwrap(
            deletionContext.fetch(FetchDescriptor<Idol>()).first { $0.id == targetIdolID }
        )
        try ChekinanaEventPersistence.delete(deleteEvent, from: deletionContext)
        _ = try ChekinanaIdolPersistence.delete(deleteIdol, from: deletionContext)

        XCTAssertThrowsError(try ChekinanaChekiRecordStore.upsert(
            idols: [addTargetIdol],
            event: addTargetEvent,
            date: day,
            size: .wide,
            note: "must not insert",
            adding: 3,
            in: addContext
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaChekiRecordMutationError,
                .missingRelationships
            )
        }
        XCTAssertThrowsError(try ChekinanaChekiRecordStore.update(
            editRecord,
            idols: [editTargetIdol],
            event: editTargetEvent,
            date: day,
            size: .wide,
            note: "must not update",
            count: 5,
            expected: editSnapshot,
            in: editContext
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaChekiRecordMutationError,
                .missingRelationships
            )
        }

        let verification = ModelContext(container)
        XCTAssertNil(
            try verification.fetch(FetchDescriptor<Idol>())
                .first { $0.id == targetIdolID }
        )
        XCTAssertNil(
            try verification.fetch(FetchDescriptor<Event>())
                .first { $0.id == targetEventID }
        )
        let records = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 1)
        let retained = try XCTUnwrap(records.first)
        XCTAssertEqual(retained.id, originalID)
        XCTAssertEqual(retained.idolIDs, [originalIdolID])
        XCTAssertNil(retained.eventID)
        XCTAssertEqual(retained.note, "original")
        XCTAssertEqual(retained.size, .mini)
        XCTAssertEqual(retained.count, 2)
    }

    func testSimpleRecordLinksPersistAcrossRestartAndGateIdolEventDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-simple-record-links-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Records.store")
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let configuration = ModelConfiguration(
            "Records",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let idolID = UUID()
        let eventID = UUID()
        let recordID = UUID()

        var container: ModelContainer? = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        do {
            let context = ModelContext(try XCTUnwrap(container))
            let idol = Idol(id: idolID, name: "Linked Idol")
            let event = Event(id: eventID, name: "Linked Event")
            context.insert(idol)
            context.insert(event)
            context.insert(ChekiRecord(
                id: recordID,
                idols: [idol],
                event: event,
                size: .mini,
                note: "persist"
            ))
            try context.save()
        }
        container = nil

        container = try ModelContainer(for: schema, configurations: [configuration])
        do {
            let context = ModelContext(try XCTUnwrap(container))
            let record = try XCTUnwrap(
                context.fetch(FetchDescriptor<ChekiRecord>()).first
            )
            let idol = try XCTUnwrap(
                context.fetch(FetchDescriptor<Idol>()).first { $0.id == idolID }
            )
            let event = try XCTUnwrap(
                context.fetch(FetchDescriptor<Event>()).first { $0.id == eventID }
            )
            XCTAssertEqual(record.id, recordID)
            XCTAssertEqual(record.idolIDs, [idolID])
            XCTAssertEqual(record.idols.map(\.id), [idolID])
            XCTAssertEqual(record.eventID, eventID)
            XCTAssertEqual(record.event?.id, eventID)
            XCTAssertThrowsError(try ChekinanaIdolPersistence.delete(
                idol,
                from: context
            ))
            XCTAssertThrowsError(try ChekinanaEventPersistence.delete(
                event,
                from: context
            ))
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Idol>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Event>()), 1)

            record.idols = []
            record.event = nil
            try context.save()
        }
        container = nil

        container = try ModelContainer(for: schema, configurations: [configuration])
        let reopened = ModelContext(try XCTUnwrap(container))
        let record = try XCTUnwrap(
            reopened.fetch(FetchDescriptor<ChekiRecord>()).first
        )
        XCTAssertEqual(record.id, recordID)
        XCTAssertTrue(record.idolIDs.isEmpty)
        XCTAssertTrue(record.idols.isEmpty)
        XCTAssertNil(record.eventID)
        XCTAssertNil(record.event)
    }

    func testGalleryAvatarLayoutKeepsEveryCircleInsideCanvas() {
        let overlayInset: CGFloat = 6
        XCTAssertGreaterThanOrEqual(overlayInset, 4)
        for count in [1, 4, 20, 100] {
            let contentWidth: CGFloat = 120
            let layout = ChekinanaGalleryAvatarLayout.make(
                availableWidth: contentWidth - (overlayInset * 2),
                count: count,
                maximumDiameter: ChekinanaGalleryGridSizePolicy
                    .avatarDiameter(forColumnCount: 1)
            )
            XCTAssertGreaterThan(layout.diameter, 0)
            XCTAssertLessThanOrEqual(
                layout.diameter,
                ChekinanaGalleryGridSizePolicy.avatarDiameter(forColumnCount: 1)
            )
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
        XCTAssertFalse(deleted.isPreparingCatalogueAvatar)
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsPreview(
            generation: 3,
            currentGeneration: 4,
            itemMatches: true
        ))
        XCTAssertTrue(ChekinanaIdolAvatarSelectionPolicy.acceptsPreview(
            generation: 4,
            currentGeneration: 4,
            itemMatches: true
        ))
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsPreview(
            generation: 4,
            currentGeneration: 4,
            itemMatches: false
        ))
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.shouldReadExistingAvatar(explicitlyRemoving: true))
    }

    func testCatalogueAvatarInvalidationRejectsStaleCompletionForEveryUserPath() {
        let localSelection = ChekinanaIdolAvatarSelectionPolicy
            .invalidatingCataloguePreparation(generation: 8)
        let manualSwitch = ChekinanaIdolAvatarSelectionPolicy
            .invalidatingCataloguePreparation(generation: 8)
        let explicitRemoval = ChekinanaIdolAvatarSelectionPolicy
            .afterDelete(generation: 8)

        XCTAssertEqual(localSelection.generation, 9)
        XCTAssertFalse(localSelection.isPreparingCatalogueAvatar)
        XCTAssertEqual(manualSwitch.generation, 9)
        XCTAssertFalse(manualSwitch.isPreparingCatalogueAvatar)
        XCTAssertEqual(explicitRemoval.generation, 9)
        XCTAssertFalse(explicitRemoval.isPreparingCatalogueAvatar)
        XCTAssertTrue(explicitRemoval.removesAvatar)

        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsCatalogueCompletion(
            generation: 8,
            currentGeneration: localSelection.generation,
            candidateMatches: true
        ))
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(
            generation: 8,
            currentGeneration: localSelection.generation,
            candidateMatches: true,
            removesAvatar: false,
            hasLocalItem: false
        ))
    }

    func testCatalogueAvatarPreviewRejectsFailedReplacementAndOutOfOrderCandidate() {
        // A success belongs to generation 1; selecting B immediately clears A
        // and makes only B's generation eligible to publish.
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(generation: 1, currentGeneration: 2, candidateMatches: false, removesAvatar: false, hasLocalItem: false))
        XCTAssertTrue(ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(generation: 2, currentGeneration: 2, candidateMatches: true, removesAvatar: false, hasLocalItem: false))
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(generation: 2, currentGeneration: 2, candidateMatches: true, removesAvatar: true, hasLocalItem: false))
        XCTAssertFalse(ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(generation: 2, currentGeneration: 2, candidateMatches: true, removesAvatar: false, hasLocalItem: true))
    }

    func testPatternMigrationClearsLegacyVectorsOnlyOnceAndMarksCataloguePending() throws {
        let suiteName = "ChekinanaPatternMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let schema = Schema(versionedSchema: ChekinanaSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let legacy = ChekinanaPatternDebugFixture.unitVector(7)
        let catalogue = Idol(
            sourceId: "idol_catalogue",
            name: "Catalogue",
            patterns: [legacy]
        )
        catalogue.pattern = legacy
        let manual = Idol(name: "Manual", patterns: [legacy])
        context.insert(catalogue)
        context.insert(manual)
        try context.save()

        try ChekinanaIdolPatternPersistence.discardIncompatiblePatternsIfNeeded(
            in: context,
            defaults: defaults
        )

        XCTAssertNil(catalogue.pattern)
        XCTAssertTrue(catalogue.patterns.isEmpty)
        XCTAssertTrue(manual.patterns.isEmpty)
        XCTAssertEqual(
            try ChekinanaIdolPatternPersistence.state(
                for: catalogue.id,
                in: context
            )?.encoderVersion,
            ChekinanaIdolPatternPersistence.pendingVersion
        )
        XCTAssertEqual(
            try ChekinanaIdolPatternPersistence.state(for: manual.id, in: context)?
                .encoderVersion,
            ChekinanaPatternContract.encoderVersion
        )

        let currentCustom = ChekinanaPatternDebugFixture.unitVector(11)
        _ = try ChekinanaIdolPatternPersistence.replaceCataloguePatterns(
            for: manual,
            patternIDs: [],
            prototypes: [],
            customPatterns: [currentCustom],
            in: context
        )
        try context.save()
        try ChekinanaIdolPatternPersistence.discardIncompatiblePatternsIfNeeded(
            in: context,
            defaults: defaults
        )
        XCTAssertEqual(manual.patterns, [currentCustom])
    }

    func testPatternStateDistinguishesDeletedCataloguePrototypeFromCustomVector() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let first = ChekinanaPatternDebugFixture.unitVector(1)
        let second = ChekinanaPatternDebugFixture.unitVector(2)
        let custom = ChekinanaPatternDebugFixture.unitVector(3)
        let idol = Idol(sourceId: "idol_mina", name: "Mina")
        context.insert(idol)
        let state = try ChekinanaIdolPatternPersistence.replaceCataloguePatterns(
            for: idol,
            patternIDs: ["Mina_XII_P1", "Mina_XII_P2"],
            prototypes: [first, second],
            customPatterns: [custom],
            in: context
        )
        try context.save()

        let split = ChekinanaIdolPatternPersistence.splitEditedPatterns(
            [second, custom],
            for: idol,
            state: state
        )
        XCTAssertEqual(split.cataloguePatternIDs, ["Mina_XII_P2"])
        XCTAssertEqual(split.cataloguePatterns, [second])
        XCTAssertEqual(split.customPatterns, [custom])
    }

    func testCataloguePatternSelectionTracksResolvedPatternIDsAndVectors() {
        let prototype = ChekinanaPatternDebugFixture.unitVector(4)
        var selection = ChekinanaCataloguePatternSelectionState()
        selection.select(
            sourceId: "idol_aoyi",
            patternIds: ["Aoyi_XII_P1"],
            patterns: [prototype]
        )
        XCTAssertEqual(selection.sourceId, "idol_aoyi")
        XCTAssertEqual(selection.patternIds, ["Aoyi_XII_P1"])
        XCTAssertEqual(selection.patterns, [prototype])
        XCTAssertTrue(selection.isResolved)
        selection.clear()
        XCTAssertFalse(selection.isResolved)
    }

    func testCataloguePatternIDsDecodeMissingAsEmptyAndNormalizeDuplicates() throws {
        let missing = try JSONDecoder().decode(
            ChekinanaEnrichedIdol.self,
            from: Data("""
            {"id":"idol_missing","idolName":"Missing"}
            """.utf8)
        )
        XCTAssertTrue(missing.patternIds.isEmpty)

        let mapped = try JSONDecoder().decode(
            ChekinanaEnrichedIdol.self,
            from: Data("""
            {
              "id":"idol_mapped",
              "idolName":"Mapped",
              "patternIds":[" Mina_XII_P1 ","Mina_XII_P1","Mina_XII_P2"]
            }
            """.utf8)
        )
        XCTAssertEqual(mapped.patternIds, ["Mina_XII_P1", "Mina_XII_P2"])
    }

    func testPatternProductionRevisionUsesCacheBustedManifestMapAndCachePath() {
        XCTAssertEqual(ChekinanaPatternContract.encoderVersion, "pattern-6541-v1")
        XCTAssertEqual(
            ChekinanaPatternContract.resourceRevision,
            "catalogue-b462a208c0d75264"
        )
        XCTAssertEqual(
            ChekinanaPatternContract.manifestURL.absoluteString,
            "https://idol.chekinana.top/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/manifest.json"
        )
        XCTAssertEqual(
            ChekinanaPatternContract.prototypesURL.absoluteString,
            "https://idol.chekinana.top/assets/pattern-recognition/v1/prototypes.json"
        )
        XCTAssertEqual(
            ChekinanaPatternContract.idolPatternMapURL.absoluteString,
            "https://idol.chekinana.top/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/idol-pattern-map.json"
        )
        let cache = ChekinanaPatternContract.validatedResourceCacheDirectory(
            baseDirectory: URL(fileURLWithPath: "/cache-root", isDirectory: true)
        )
        XCTAssertEqual(cache.lastPathComponent, ChekinanaPatternContract.resourceRevision)
        XCTAssertEqual(
            cache.deletingLastPathComponent().lastPathComponent,
            ChekinanaPatternContract.encoderVersion
        )
    }

    func testPatternProductionManifestRejectsOldRootMappingURL() async throws {
        let endpoints = ChekinanaPatternResourceEndpoints.production
        let manifest = try JSONSerialization.data(withJSONObject: [
            "version": ChekinanaPatternContract.encoderVersion,
            "embeddingDimension": ChekinanaPatternContract.embeddingDimension,
            "patternCount": ChekinanaPatternContract.patternCount,
            "encoderCheckpointSHA256": ChekinanaPatternContract.encoderCheckpointSHA256,
            "prototypesUrl": endpoints.prototypesURL.absoluteString,
            "idolPatternMapUrl": "https://idol.chekinana.top/assets/pattern-recognition/v1/idol-pattern-map.json",
        ])
        ChekinanaPatternResourceMockURLProtocol.handler = { _ in manifest }
        defer { ChekinanaPatternResourceMockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaPatternResourceMockURLProtocol.self]
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-pattern-revision-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let resources = ChekinanaRemotePatternResources(
            endpoints: endpoints,
            session: URLSession(configuration: configuration),
            cacheDirectory: cache
        )
        do {
            _ = try await resources.snapshot()
            XCTFail("Old root mapping URL must not be accepted by the new revision.")
        } catch {
            XCTAssertEqual(
                error as? ChekinanaPatternResourceError,
                .invalidManifest
            )
        }
    }

    func testRemotePatternResourcesValidateAndReuseLastGoodCacheOffline() async throws {
        let root = try XCTUnwrap(URL(string: "https://patterns.test/v1/"))
        let endpoints = ChekinanaPatternResourceEndpoints(
            manifestURL: root.appendingPathComponent("manifest.json"),
            prototypesURL: root.appendingPathComponent("prototypes.json"),
            idolPatternMapURL: root.appendingPathComponent("idol-pattern-map.json")
        )
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-pattern-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let patternIDs = (0..<ChekinanaPatternContract.patternCount).map {
            "pattern_\($0)"
        }
        let prototypes = (0..<ChekinanaPatternContract.patternCount).map {
            ChekinanaPatternDebugFixture.unitVector($0)
        }
        let manifest = try JSONSerialization.data(withJSONObject: [
            "version": ChekinanaPatternContract.encoderVersion,
            "embeddingDimension": ChekinanaPatternContract.embeddingDimension,
            "patternCount": ChekinanaPatternContract.patternCount,
            "encoderCheckpointSHA256": ChekinanaPatternContract.encoderCheckpointSHA256,
            "prototypesUrl": endpoints.prototypesURL.absoluteString,
            "idolPatternMapUrl": endpoints.idolPatternMapURL.absoluteString,
        ])
        let bank = try JSONSerialization.data(withJSONObject: [
            "format": ChekinanaPatternContract.prototypeFormat,
            "encoder_checkpoint_sha256": ChekinanaPatternContract.encoderCheckpointSHA256,
            "embedding_dim": ChekinanaPatternContract.embeddingDimension,
            "pattern_ids": patternIDs,
            "prototypes": prototypes,
        ])
        let mapping = try JSONSerialization.data(withJSONObject: [
            "format": ChekinanaPatternContract.mappingFormat,
            "version": ChekinanaPatternContract.encoderVersion,
            "idolPatternIDs": ["idol_mina": [patternIDs[0], patternIDs[1]]],
        ])
        let responses = [
            endpoints.manifestURL: manifest,
            endpoints.prototypesURL: bank,
            endpoints.idolPatternMapURL: mapping,
        ]
        ChekinanaPatternResourceMockURLProtocol.handler = { request in
            guard let data = responses[try XCTUnwrap(request.url)] else {
                throw URLError(.badURL)
            }
            return data
        }
        defer { ChekinanaPatternResourceMockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaPatternResourceMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let online = ChekinanaRemotePatternResources(
            endpoints: endpoints,
            session: session,
            cacheDirectory: cache
        )
        let first = try await online.snapshot()
        XCTAssertEqual(
            try first.patterns(for: first.idolPatternIDs["idol_mina"] ?? []),
            Array(prototypes.prefix(2))
        )

        ChekinanaPatternResourceMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let offline = ChekinanaRemotePatternResources(
            endpoints: endpoints,
            session: session,
            cacheDirectory: cache
        )
        let cached = try await offline.snapshot()
        XCTAssertEqual(cached.idolPatternIDs["idol_mina"], [patternIDs[0], patternIDs[1]])
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
        let catalogue = ChekinanaPatternDebugFixture.unitVector(9)
        let merged = ChekinanaPatternVectors.mergedPatterns([
            resolution.idol.recognitionPatterns,
            [catalogue],
            [catalogue],
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
            $0 == catalogue
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

    func testCatalogueReferencePatternAppendKeepsCloudPatternAndDeduplicates() {
        var reference = Array(repeating: Float.zero, count: 256)
        reference[119] = 1
        let catalogue = ChekinanaPatternDebugFixture.unitVector(8)
        let merged = ChekinanaPatternVectors.mergedPatterns([
            [catalogue],
            [reference],
            [reference],
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(catalogue))
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

    func testChekiEventSelectionWindowIncludesOnlyCanonicalDayPlusOrMinusOne() {
        let day = utcDate(2026, 8, 24)
        XCTAssertTrue(ChekinanaChekiEventSelectionPolicy.includes(
            recordDate: day,
            eventDate: utcDate(2026, 8, 23)
        ))
        XCTAssertTrue(ChekinanaChekiEventSelectionPolicy.includes(
            recordDate: day,
            eventDate: day.addingTimeInterval(12 * 60 * 60)
        ))
        XCTAssertTrue(ChekinanaChekiEventSelectionPolicy.includes(
            recordDate: day,
            eventDate: utcDate(2026, 8, 25)
        ))
        XCTAssertFalse(ChekinanaChekiEventSelectionPolicy.includes(
            recordDate: day,
            eventDate: utcDate(2026, 8, 22)
        ))
        XCTAssertFalse(ChekinanaChekiEventSelectionPolicy.includes(
            recordDate: day,
            eventDate: utcDate(2026, 8, 26)
        ))
        XCTAssertFalse(ChekinanaChekiEventSelectionPolicy.includes(
            recordDate: nil,
            eventDate: day
        ))
        XCTAssertFalse(ChekinanaChekiEventSelectionPolicy.includes(
            recordDate: day,
            eventDate: nil
        ))
    }

    func testChekiEventNearbyCandidatesPutSameDayFirstThenPreviousAndNextByStart() {
        let recordDay = utcDate(2026, 8, 24)
        let sameLate = Event(name: "Same late", date: recordDay)
        let sameEarly = Event(name: "Same early", date: recordDay)
        let previous = Event(name: "Previous", date: utcDate(2026, 8, 23))
        let next = Event(name: "Next", date: utcDate(2026, 8, 25))
        let outside = Event(name: "Outside", date: utcDate(2026, 8, 26))
        let schedules = [
            EventSchedule(eventID: sameLate.id, startTime: "19:00"),
            EventSchedule(eventID: sameEarly.id, startTime: "10:00"),
        ]

        XCTAssertEqual(
            ChekinanaChekiEventSelectionPolicy.eligibleEvents(
                [next, sameLate, outside, previous, sameEarly],
                schedules: schedules,
                for: recordDay
            ).map(\.id),
            [sameEarly.id, sameLate.id, previous.id, next.id]
        )
    }

    func testChekiEventValidationKeepsExistingExplicitSelectionOutsideNearbyWindow() {
        let selected = Event(name: "Explicit", date: utcDate(2026, 9, 10))
        XCTAssertEqual(
            ChekinanaChekiEventSelectionPolicy.validatedEventID(
                selected.id,
                recordDate: utcDate(2026, 8, 24),
                events: [selected]
            ),
            selected.id
        )
        XCTAssertNil(ChekinanaChekiEventSelectionPolicy.validatedEventID(
            UUID(),
            recordDate: utcDate(2026, 8, 24),
            events: [selected]
        ))
    }

    func testChekiRecordStoreAcceptsAnyExistingExplicitEventAndRejectsMissingEvent() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idol = Idol(name: "Event window")
        let day = utcDate(2026, 8, 24)
        let previous = Event(name: "Previous", date: utcDate(2026, 8, 23))
        let following = Event(name: "Following", date: utcDate(2026, 8, 25))
        let tooLate = Event(name: "Too late", date: utcDate(2026, 8, 26))
        let undated = Event(name: "Undated")
        [idol].forEach(context.insert)
        [previous, following, tooLate, undated].forEach(context.insert)
        try context.save()

        _ = try ChekinanaChekiRecordStore.upsert(
            idols: [idol],
            event: previous,
            date: day,
            size: .mini,
            note: "previous",
            adding: 1,
            in: context
        )
        _ = try ChekinanaChekiRecordStore.upsert(
            idols: [idol],
            event: following,
            date: day,
            size: .mini,
            note: "following",
            adding: 1,
            in: context
        )
        for (event, recordDate) in [(tooLate, Optional(day)), (undated, Optional(day)), (previous, nil)] {
            _ = try ChekinanaChekiRecordStore.upsert(
                idols: [idol],
                event: event,
                date: recordDate,
                size: .mini,
                note: "explicit-\(event.id.uuidString)-\(recordDate == nil)",
                adding: 1,
                in: context
            )
        }
        let missing = Event(name: "Missing", date: day)
        XCTAssertThrowsError(try ChekinanaChekiRecordStore.upsert(
            idols: [idol],
            event: missing,
            date: day,
            size: .mini,
            note: "missing",
            adding: 1,
            in: context
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaChekiRecordMutationError,
                .missingRelationships
            )
        }
        let saved = try context.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(saved.count, 5)
        XCTAssertEqual(
            Set(saved.compactMap(\.eventID)),
            Set([previous.id, following.id, tooLate.id, undated.id])
        )
        XCTAssertFalse(saved.contains { $0.note == "missing" })
    }

    func testQuantityInputPolicySupportsLargeCountsWithoutClampingOrOverflow() {
        XCTAssertEqual(ChekinanaQuantityInputPolicy.digits("1a２-3"), "123")
        XCTAssertEqual(
            ChekinanaQuantityInputPolicy.value(from: "0", allowedRange: 0...Int.max),
            0
        )
        XCTAssertNil(
            ChekinanaQuantityInputPolicy.value(from: "", allowedRange: 0...Int.max)
        )
        XCTAssertNil(
            ChekinanaQuantityInputPolicy.value(from: "-1", allowedRange: 0...Int.max)
        )
        XCTAssertEqual(
            ChekinanaQuantityInputPolicy.value(from: "250", allowedRange: 0...Int.max),
            250
        )
        XCTAssertEqual(
            ChekinanaQuantityInputPolicy.adjusted(150, by: -1, allowedRange: 0...Int.max),
            149
        )
        XCTAssertEqual(
            ChekinanaQuantityInputPolicy.adjusted(150, by: 1, allowedRange: 0...Int.max),
            151
        )
        XCTAssertEqual(
            ChekinanaQuantityInputPolicy.adjusted(Int.max, by: 1, allowedRange: 0...Int.max),
            Int.max
        )
        XCTAssertNil(
            ChekinanaQuantityInputPolicy.value(
                from: String(Int.max) + "0",
                allowedRange: 0...Int.max
            )
        )
    }

    func testQuantityControlUsesSmallerVisibleButtonsInsideAccessibleHitTargets() {
        XCTAssertEqual(ChekinanaQuantityControlMetrics.hitTarget, 44)
        XCTAssertLessThan(
            ChekinanaQuantityControlMetrics.visibleButtonDiameter,
            ChekinanaQuantityControlMetrics.hitTarget
        )
        XCTAssertLessThan(
            ChekinanaQuantityControlMetrics.iconPointSize,
            ChekinanaQuantityControlMetrics.visibleButtonDiameter
        )
        XCTAssertGreaterThan(ChekinanaQuantityControlMetrics.fillOpacity, 0)
        XCTAssertGreaterThan(ChekinanaQuantityControlMetrics.strokeOpacity, 0)
        XCTAssertGreaterThan(ChekinanaQuantityControlMetrics.strokeWidth, 0)
    }

    func testQuantityControlButtonStyleHasContrastingFillAndStroke() throws {
        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private func adjustmentButton(")?.lowerBound
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private func applyTypedValue(",
                range: start..<source.endIndex
            )?.lowerBound
        )
        let buttonSource = source[start..<end]

        XCTAssertTrue(buttonSource.contains("ChekinanaProductTheme.accent.opacity("))
        XCTAssertTrue(buttonSource.contains(".stroke("))
        XCTAssertTrue(buttonSource.contains("visibleButtonDiameter"))
        XCTAssertTrue(buttonSource.contains("hitTarget"))
        XCTAssertFalse(buttonSource.contains("secondarySystemGroupedBackground"))
    }

    func testQuantityControlAccessibilityCopyIsLocalized() throws {
        let expectations: [String: [String]] = [
            "en": ["Quantity", "Decrease quantity", "Increase quantity"],
            "zh-Hans": ["数量", "减少数量", "增加数量"],
            "ja": ["枚数", "枚数を減らす", "枚数を増やす"],
        ]
        for (language, expected) in expectations {
            let bundle = try localizedAppBundle(language: language)
            XCTAssertEqual([
                ChekinanaProductCopy.text("common.quantity", "Quantity", bundle: bundle),
                ChekinanaProductCopy.text("common.quantity.decrease", "Decrease quantity", bundle: bundle),
                ChekinanaProductCopy.text("common.quantity.increase", "Increase quantity", bundle: bundle),
            ], expected, language)
        }
    }

    func testChekiFavoriteAndSNSFlagsDefaultFalseAndRoundTripTrue() throws {
        let defaultCheki = Cheki()
        XCTAssertFalse(defaultCheki.isFavorite)
        XCTAssertFalse(defaultCheki.hasPostedToSNS)
        XCTAssertEqual(defaultCheki.userAppears, false)
        XCTAssertEqual(Cheki(userAppears: nil).userAppears, false)

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
        XCTAssertEqual(cheki.userAppears, false)
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
        fixture.context.insert(EventSchedule(
            eventID: event.id,
            openTime: "18:00",
            startTime: "18:30"
        ))
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
        XCTAssertEqual(
            try fixture.context.fetchCount(FetchDescriptor<EventSchedule>()),
            0
        )
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
        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: "18:00",
            startTime: nil,
            in: fixture.context
        )

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
        XCTAssertEqual(
            try ModelContext(fixture.context.container)
                .fetch(FetchDescriptor<EventSchedule>()).first?.openTime,
            "18:00"
        )
    }

    func testEventPersistsOrderedImageRecordsWithoutChangingEventEntity() throws {
        let fixture = try makeFixture()
        let event = Event(name: "Illustrated")
        let imageRefs = [
            "event-image-\(event.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg",
            "event-image-\(event.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg",
        ]
        imageRefs.forEach { ChekinanaEventMediaJournal.recordPending($0) }
        try ChekinanaEventPersistence.save(
            event,
            inserting: true,
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

    func testEventRemoteImageDownloaderAcceptsAndStoresValidPayloadLargerThanEightMiB() async throws {
        let initialURL = try XCTUnwrap(URL(string: "https://wx1.sinaimg.cn/large.jpg"))
        let width = 1_800
        let height = 1_800
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            var value = UInt32(truncatingIfNeeded: pixel)
            value = value &* 1_664_525 &+ 1_013_904_223
            let offset = pixel * 4
            pixels[offset] = UInt8(truncatingIfNeeded: value)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            pixels[offset + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            encoded,
            "public.tiff" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFCompression: 1,
            ],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let payload = encoded as Data
        XCTAssertGreaterThan(payload.count, 8 * 1_024 * 1_024)
        XCTAssertNotNil(CGImageSourceCreateWithData(payload as CFData, nil))

        let downloadFile = try temporaryDownloadFile(data: payload)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: initialURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "image/tiff",
                "Content-Length": "\(payload.count)",
            ]
        ))
        let downloader = ChekinanaEventRemoteImageDownloader { _ in
            (downloadFile, response)
        }

        let downloaded = try await downloader.data(for: initialURL)
        XCTAssertEqual(downloaded.count, payload.count)
        let ref = try await ChekinanaEventImageStore.save(downloaded, eventID: UUID())
        defer { ChekinanaEventImageStore.remove([ref]) }
        XCTAssertNotNil(ChekinanaEventImageStore.image(for: ref))
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

    func testSystemPasteCoordinatorLoadsTrimmedStringAndInvokesCallback() async {
        let didPaste = expectation(description: "System item provider string is delivered")
        var pastedValue: String?
        let coordinator = ChekinanaSystemStringPasteControl.Coordinator { pasted in
            pastedValue = pasted
            didPaste.fulfill()
        }
        let provider = NSItemProvider(
            object: NSString(string: "  https://weibo.com/example/status\n")
        )

        coordinator.paste(itemProviders: [provider])
        await fulfillment(of: [didPaste], timeout: 2)
        XCTAssertEqual(pastedValue, "https://weibo.com/example/status")
    }

    func testSystemPasteCoordinatorIgnoresWhitespaceOnlyString() async throws {
        let didPaste = expectation(description: "Whitespace is not delivered")
        didPaste.isInverted = true
        let coordinator = ChekinanaSystemStringPasteControl.Coordinator { _ in
            didPaste.fulfill()
        }
        coordinator.paste(itemProviders: [
            NSItemProvider(object: NSString(string: " \n\t "))
        ])

        await fulfillment(of: [didPaste], timeout: 0.2)
    }

    func testSystemPasteCoordinatorLoadsURLObjectAndInvokesCallback() async {
        let didPaste = expectation(description: "System item provider URL is delivered")
        var pastedValue: String?
        let coordinator = ChekinanaSystemStringPasteControl.Coordinator { pasted in
            pastedValue = pasted
            didPaste.fulfill()
        }
        let provider = NSItemProvider(
            object: NSURL(string: "https://weibo.com/example/url-object")!
        )

        coordinator.paste(itemProviders: [provider])
        await fulfillment(of: [didPaste], timeout: 2)
        XCTAssertEqual(pastedValue, "https://weibo.com/example/url-object")
    }

    func testSystemPasteRepresentableCreationAndUpdateKeepStockControlHittable() {
        var pastedValue = ""
        let host = UIHostingController(
            rootView: ChekinanaSystemStringPasteControl(
                title: "Paste Weibo URL",
                accessibilityIdentifier: "paste.lifecycle"
            ) { pastedValue = $0 }
            .frame(width: 180, height: 44)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 180, height: 44))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.loadViewIfNeeded()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        host.rootView = ChekinanaSystemStringPasteControl(
            title: "Paste another Weibo URL",
            accessibilityIdentifier: "paste.lifecycle.updated"
        ) { pastedValue = $0 }
        .frame(width: 180, height: 44)
        host.view.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        func pasteControl(in view: UIView) -> UIPasteControl? {
            if let control = view as? UIPasteControl { return control }
            for subview in view.subviews {
                if let control = pasteControl(in: subview) { return control }
            }
            return nil
        }

        let control = pasteControl(in: host.view)
        XCTAssertNotNil(control)
        XCTAssertGreaterThan(control?.bounds.width ?? 0, 0)
        XCTAssertGreaterThan(control?.bounds.height ?? 0, 0)
        XCTAssertTrue(control?.isEnabled == true)
        XCTAssertNotNil(control?.target)
        XCTAssertTrue(control?.target is ChekinanaSystemStringPasteControl.Coordinator)
        XCTAssertEqual(control?.alpha, 1)
        XCTAssertEqual(control?.layer.opacity, 1)
        XCTAssertEqual(pastedValue, "")
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
        XCTAssertTrue(detail.contains("@Query private var eventSchedules"))
        XCTAssertTrue(detail.contains("chekinana.events.detail.schedule"))
        XCTAssertTrue(detail.contains("ForEach(Array(eventImages.enumerated())"))
        XCTAssertTrue(detail.contains("chekinana.events.detail.image"))

        let editor = try slice(
            "private struct ChekinanaEventEditorView",
            "enum ChekinanaGalleryMediaKind"
        )
        XCTAssertTrue(editor.contains("Paste Weibo URL"))
        XCTAssertTrue(editor.contains("ChekinanaSystemStringPasteControl("))
        XCTAssertTrue(editor.contains("sourceURL = pasted"))
        XCTAssertTrue(editor.contains("chekinana.events.editor.weibo-paste"))
        XCTAssertTrue(editor.contains("if sourceURL.isEmpty"))
        XCTAssertEqual(
            editor.components(
                separatedBy: "ChekinanaEventEditorLayout.singleLineInputHeight"
            ).count - 1,
            4,
            "Paste, URL TextField and parse row must share the same system-derived height."
        )
        XCTAssertFalse(editor.contains("directWeiboPasteControl"))
        XCTAssertFalse(editor.contains("prompt: Text(weiboPasteTitle)"))
        XCTAssertFalse(editor.contains(".accessibilityHidden(sourceURL.isEmpty)"))
        XCTAssertTrue(editor.contains("parsedAddress = candidate.address"))
        XCTAssertTrue(editor.contains("address: parsedAddress"))
        XCTAssertFalse(editor.contains("UIPasteboard.general.string"))
        XCTAssertFalse(editor.contains("pasteWeiboURL"))
        XCTAssertTrue(editor.contains("Parse Weibo URL"))
        XCTAssertTrue(editor.contains(
            "_sourceURL = State(initialValue: event?.weiboURL?.absoluteString ?? \"\")"
        ))
        XCTAssertTrue(editor.contains("chekinana.events.editor.images.add"))
        XCTAssertTrue(editor.contains("label: \"OPEN\""))
        XCTAssertTrue(editor.contains("label: \"START\""))
        XCTAssertTrue(editor.contains("isOn: $hasDate"))
        XCTAssertTrue(editor.contains("if hasDate"))
        XCTAssertTrue(editor.contains("hasDate = true"))
        XCTAssertTrue(editor.contains("liveEvent.date = selectedDate"))
        XCTAssertTrue(editor.contains("displayedComponents: .hourAndMinute"))
        XCTAssertTrue(editor.contains("openTimeDraft.replace(with: candidate.openTime)"))
        XCTAssertTrue(editor.contains("startTimeDraft.replace(with: candidate.startTime)"))
        XCTAssertTrue(editor.contains("schedule: ChekinanaEventScheduleValue("))
        XCTAssertFalse(editor.contains("sourceText"))
        XCTAssertFalse(editor.contains("parse-text"))
        XCTAssertFalse(editor.contains("regularExpression"))
        let applyIndex = try XCTUnwrap(editor.range(of: "apply(candidate)")?.lowerBound)
        let stageIndex = try XCTUnwrap(editor.range(of: "stageParsedImages(candidate.imageUrls")?.lowerBound)
        XCTAssertLessThan(applyIndex, stageIndex)
        XCTAssertTrue(editor.contains("ChekinanaEventPersistence.save("))
        XCTAssertTrue(editor.contains(
            "ChekinanaEventCandidateValidator.blockers(for: fields)"
        ))
        XCTAssertTrue(editor.contains("discardUncommittedImages()"))
        XCTAssertTrue(editor.contains("interactiveDismissDisabled(isSaving)"))
        XCTAssertTrue(editor.contains("guard !isSaving else { return }"))
        XCTAssertTrue(editor.contains(".disabled(isSaving)"))
        XCTAssertTrue(editor.contains("saveGate.accepts(token"))
        XCTAssertTrue(editor.contains("didCommit = true"))

        let eventsPage = try slice(
            "private struct ChekinanaEventsView",
            "private struct ChekinanaEventDetailView"
        )
        XCTAssertEqual(
            eventsPage.components(separatedBy: "isAdding = true").count - 1,
            2,
            "Both the empty-state action and the navigation plus button must open Add Event."
        )
        XCTAssertTrue(eventsPage.contains(
            ".sheet(isPresented: $isAdding) { ChekinanaEventEditorView(event: nil) }"
        ))

        let pasteControl = try slice(
            "struct ChekinanaSystemStringPasteControl",
            "struct ChekinanaDirectStringPasteControl"
        )
        XCTAssertTrue(pasteControl.contains(
            "UIFont.preferredFont(forTextStyle: .body).lineHeight"
        ))
        XCTAssertTrue(pasteControl.contains("UIViewRepresentable"))
        XCTAssertTrue(pasteControl.contains(
            "final class Coordinator: UIResponder"
        ))
        XCTAssertTrue(pasteControl.contains("let control = UIPasteControl(configuration: configuration)"))
        XCTAssertTrue(pasteControl.contains("configuration.displayMode = .labelOnly"))
        XCTAssertTrue(pasteControl.contains("configuration.cornerStyle = .fixed"))
        XCTAssertTrue(pasteControl.contains("configuration.cornerRadius = 10"))
        XCTAssertTrue(pasteControl.contains("configuration.baseForegroundColor = .systemBlue"))
        XCTAssertTrue(pasteControl.contains("configuration.baseBackgroundColor = .white"))
        XCTAssertFalse(pasteControl.contains("ChekinanaInvisiblePasteContainer"))
        XCTAssertFalse(pasteControl.contains("ChekinanaTransparentStringPasteControl"))
        XCTAssertFalse(pasteControl.contains("Text(title)"))
        XCTAssertFalse(pasteControl.contains("CATextLayer"))
        XCTAssertFalse(pasteControl.contains("UILabel"))
        XCTAssertFalse(pasteControl.contains("UIGraphicsImageRenderer("))
        XCTAssertFalse(pasteControl.contains("promptCover"))
        XCTAssertFalse(pasteControl.contains("backgroundColor ="))
        XCTAssertFalse(pasteControl.contains("isOpaque ="))
        XCTAssertFalse(pasteControl.contains("override var isHighlighted: Bool"))
        XCTAssertFalse(pasteControl.contains(".alpha ="))
        XCTAssertFalse(pasteControl.contains("layer.opacity"))
        XCTAssertFalse(pasteControl.contains(".overlay"))
        XCTAssertFalse(pasteControl.contains(".hidden()"))
        XCTAssertTrue(pasteControl.contains("control.target = context.coordinator"))
        XCTAssertTrue(pasteControl.contains("control.isAccessibilityElement = true"))
        XCTAssertTrue(pasteControl.contains("control.accessibilityLabel = title"))
        XCTAssertTrue(pasteControl.contains("control.accessibilityTraits = .button"))
        XCTAssertTrue(pasteControl.contains("override func paste(itemProviders: [NSItemProvider])"))
        XCTAssertTrue(pasteControl.contains("loadObject(ofClass: NSString.self)"))
        XCTAssertTrue(pasteControl.contains("loadObject(ofClass: NSURL.self)"))
        XCTAssertTrue(pasteControl.contains("self?.deliver(pasted)"))
        XCTAssertFalse(pasteControl.contains("PasteButton("))
        XCTAssertFalse(pasteControl.contains("UIPasteboard"))

        let containerCreation = try XCTUnwrap(
            pasteControl.range(
                of: "let control = UIPasteControl(configuration: configuration)"
            )?.upperBound
        )
        let afterContainerCreation = pasteControl[containerCreation...]
        XCTAssertFalse(afterContainerCreation.contains("control.configuration"))
        XCTAssertFalse(afterContainerCreation.contains("configuration."))

        let contentViewSourceURL = productSourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("ContentView.swift")
        let contentViewSource = try String(contentsOf: contentViewSourceURL, encoding: .utf8)
        XCTAssertTrue(contentViewSource.contains(
            "blockers: ChekinanaEventCandidateValidator.blockers(for: fields)"
        ))
        let candidateStart = try XCTUnwrap(
            contentViewSource.range(of: "private struct EventCandidateEditorView")?.lowerBound
        )
        let candidateEnd = try XCTUnwrap(
            contentViewSource.range(
                of: "private struct EventCardView",
                range: candidateStart..<contentViewSource.endIndex
            )?.lowerBound
        )
        let candidateEditor = contentViewSource[candidateStart..<candidateEnd]
        XCTAssertTrue(candidateEditor.contains("offersDirectPaste: true"))
        XCTAssertTrue(candidateEditor.contains("ChekinanaDirectStringPasteControl("))
        XCTAssertTrue(candidateEditor.contains("text.wrappedValue = pasted"))
        XCTAssertTrue(candidateEditor.contains("chekinana.event.candidate.\\(identifier).paste"))
        XCTAssertTrue(candidateEditor.contains(
            "if offersDirectPaste, text.wrappedValue.isEmpty"
        ))
        XCTAssertTrue(candidateEditor.contains("let visiblePrompt"))
        XCTAssertTrue(candidateEditor.contains("offersDirectPaste ? Color.blue"))
        XCTAssertTrue(candidateEditor.contains(
            ".accessibilityHidden(offersDirectPaste && text.wrappedValue.isEmpty)"
        ))
        XCTAssertFalse(candidateEditor.contains("UIPasteboard.general.string"))

        let monthCell = try slice(
            "private func calendarDay(_ cell: ChekinanaCalendarCell)",
            "private var selectedDayCard"
        )
        XCTAssertFalse(monthCell.contains("eventCount"))
        XCTAssertTrue(monthCell.contains("music.note.house"))
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
        XCTAssertTrue(gallery.contains("ForEach(ChekinanaRecordKind.allCases)"))
        XCTAssertTrue(gallery.contains("Text(kind.title)"))
        XCTAssertTrue(gallery.contains(
            "@State private var gridColumnCount = ChekinanaGalleryGridSizePolicy"
        ))
        XCTAssertTrue(gallery.contains(
            "repeating: GridItem(.flexible(), spacing: 4)"
        ))
        XCTAssertTrue(gallery.contains("count: gridColumnCount"))
        XCTAssertFalse(gallery.contains("ToolbarItem(placement: .principal)"))
        XCTAssertTrue(gallery.contains("ChekinanaGalleryGridSizeControl("))
        XCTAssertTrue(gallery.contains("chekinana.gallery.grid-controls"))
        XCTAssertFalse(gallery.contains(
            "navigationTitle(ChekinanaProductTab.gallery.title)"
        ))
        let dateOrderStart = try XCTUnwrap(
            gallery.range(of: "Button { galleryOrder = galleryOrder.next }")?.lowerBound
        )
        let idolOrderStart = try XCTUnwrap(
            gallery.range(of: "Button { sortByIdol.toggle() }")?.lowerBound
        )
        XCTAssertLessThan(dateOrderStart, idolOrderStart)
        let dateOrderButton = gallery[dateOrderStart..<idolOrderStart]
        XCTAssertTrue(dateOrderButton.contains("title: galleryOrder.stateTitle"))
        XCTAssertTrue(dateOrderButton.contains(
            "galleryOrder == .dateAscending"
        ))
        XCTAssertTrue(dateOrderButton.contains("\"arrow.up\" : \"arrow.down\""))
        XCTAssertFalse(dateOrderButton.contains("\"gallery.order\""))
        XCTAssertTrue(gallery.contains("avatarMaximumDiameter:"))
        XCTAssertTrue(gallery.contains(".avatarDiameter("))
        XCTAssertTrue(gallery.contains("forColumnCount:"))
        let galleryAvatarOverlay = try slice(
            "private struct ChekinanaGalleryOverlayAvatars",
            "struct ChekinanaGalleryAvatarLayout"
        )
        XCTAssertTrue(galleryAvatarOverlay.contains("borderLineWidth:"))
        XCTAssertTrue(galleryAvatarOverlay.contains(
            "avatarBorderLineWidth(forDiameter: layout.diameter)"
        ))
        XCTAssertTrue(gallery[idolOrderStart...].contains(
            "\"gallery.sort.idol\""
        ))
        let gridSizeControl = try slice(
            "private struct ChekinanaGalleryGridSizeControl",
            "private struct ChekinanaGalleryView"
        )
        let largeImageIcon = try XCTUnwrap(
            gridSizeControl.range(of: "photo.fill")?.lowerBound
        )
        let slider = try XCTUnwrap(
            gridSizeControl.range(of: "Slider(")?.lowerBound
        )
        let denseGridIcon = try XCTUnwrap(
            gridSizeControl.range(of: "square.grid.3x3.fill")?.lowerBound
        )
        XCTAssertLessThan(largeImageIcon, slider)
        XCTAssertLessThan(slider, denseGridIcon)
        XCTAssertTrue(gridSizeControl.contains("step: 1"))
        XCTAssertTrue(gridSizeControl.contains(
            "ChekinanaGalleryGridSizePolicy.minimumColumnCount"
        ))
        XCTAssertTrue(gridSizeControl.contains(
            "ChekinanaGalleryGridSizePolicy.maximumColumnCount"
        ))
        XCTAssertTrue(gridSizeControl.contains("gallery.grid_size.label"))
        XCTAssertTrue(gridSizeControl.contains("gallery.grid_size.columns"))
        XCTAssertTrue(gridSizeControl.contains("gallery.grid_size.hint"))
        XCTAssertTrue(gallery.contains("chekinana.gallery.grid-controls"))
        XCTAssertFalse(gallery.contains("ScrollView(.horizontal"))

        let recordEditor = try slice(
            "private struct ChekinanaCalendarRecordEditor",
            "struct ChekinanaCalendarIdolGroup"
        )
        XCTAssertTrue(recordEditor.contains("ChekinanaQuantityControl("))
        XCTAssertTrue(recordEditor.contains("allowedRange: 1...ChekinanaQuantityInputPolicy.maximum"))
        XCTAssertTrue(recordEditor.contains("selection: $size"))
        XCTAssertTrue(recordEditor.contains("ForEach(ChekiSize.allCases)"))
        XCTAssertTrue(recordEditor.contains("chekinana.calendar.add_record.size"))
        XCTAssertTrue(recordEditor.contains("@State private var idolIDs = Set<UUID>()"))
        XCTAssertTrue(recordEditor.contains("ChekinanaIdolSelectionSummaryButton("))
        XCTAssertTrue(recordEditor.contains("ChekinanaIdolAvatarCheckSelectionView("))
        XCTAssertTrue(recordEditor.contains("idolIDs: selectedIDs"))
        XCTAssertFalse(recordEditor.contains("selection: $idolID"))
        XCTAssertTrue(recordEditor.contains("eventID: nil"))
        XCTAssertTrue(recordEditor.contains("size: size"))
        XCTAssertEqual(
            source.components(separatedBy: "ChekinanaQuantityControl(").count - 1,
            3
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "allowedRange: 0...ChekinanaQuantityInputPolicy.maximum"
            ).count - 1,
            2
        )
        XCTAssertFalse(source.contains("Stepper("))
    }

    func testCalendarGroupRowsUseWholeRowReorderGestureWithoutDragHandle() throws {
        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)

        func slice(_ start: String, _ end: String) throws -> Substring {
            let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
            let endIndex = try XCTUnwrap(
                source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound
            )
            return source[startIndex..<endIndex]
        }

        let selectedDay = try slice(
            "private var selectedDayCard",
            "private struct ChekinanaCalendarGroupSummary"
        )
        let groupRows = try slice(
            "ForEach(displayedGroups) { group in",
            "private func openCalendarMedia"
        )
        let eventRowsEnd = try XCTUnwrap(
            selectedDay.range(of: "ForEach(displayedGroups) { group in")?.lowerBound
        )
        let eventRows = selectedDay[..<eventRowsEnd]

        XCTAssertTrue(groupRows.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(groupRows.contains("ChekinanaCalendarGroupGestureSurface("))
        XCTAssertTrue(groupRows.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        XCTAssertTrue(source.contains("UITapGestureRecognizer("))
        XCTAssertTrue(source.contains("UILongPressGestureRecognizer("))
        XCTAssertTrue(source.contains("tap.require(toFail: longPress)"))
        XCTAssertTrue(source.contains("longPress.cancelsTouchesInView = false"))
        XCTAssertTrue(source.contains("tap.cancelsTouchesInView = false"))
        XCTAssertFalse(groupRows.contains(".highPriorityGesture("))
        XCTAssertTrue(groupRows.contains("handleCalendarGroupTap("))
        XCTAssertTrue(groupRows.contains("rowSize: size"))
        XCTAssertTrue(groupRows.contains("dateKey: selectedDateKey"))
        XCTAssertTrue(groupRows.contains("orderedGroupKeys: orderedGroupKeys"))
        XCTAssertEqual(ChekinanaCalendarGroupDragPolicy.minimumPressDuration, 0.4)
        XCTAssertEqual(ChekinanaCalendarGroupDragPolicy.maximumPreDragDistance, 18)
        XCTAssertEqual(
            ChekinanaCalendarGroupDragPolicy.targetIndex(
                sourceIndex: 1,
                translationY: 0,
                count: 4
            ),
            1
        )
        XCTAssertEqual(
            ChekinanaCalendarGroupDragPolicy.targetIndex(
                sourceIndex: 1,
                translationY: ChekinanaCalendarGroupDragPolicy.rowStride,
                count: 4
            ),
            2
        )
        XCTAssertFalse(ChekinanaCalendarGroupDragPolicy.shouldUpdatePreview(
            previousTargetIndex: 2,
            targetIndex: 2
        ))
        XCTAssertTrue(ChekinanaCalendarGroupDragPolicy.shouldUpdatePreview(
            previousTargetIndex: 1,
            targetIndex: 2
        ))
        let rowSize = CGSize(width: 340, height: 62)
        let stripWidth = ChekinanaCalendarSelectedDayLayout.thumbnailStripWidth(count: 2)
        XCTAssertNil(ChekinanaCalendarGroupTapPolicy.thumbnailIndex(
            at: CGPoint(x: 120, y: 31),
            rowSize: rowSize,
            thumbnailCount: 2
        ))
        XCTAssertEqual(ChekinanaCalendarGroupTapPolicy.thumbnailIndex(
            at: CGPoint(x: rowSize.width - stripWidth + 4, y: 31),
            rowSize: rowSize,
            thumbnailCount: 2
        ), 0)
        XCTAssertEqual(ChekinanaCalendarGroupTapPolicy.thumbnailIndex(
            at: CGPoint(x: rowSize.width - 3, y: 31),
            rowSize: rowSize,
            thumbnailCount: 2
        ), 1)
        XCTAssertTrue(source.contains("ChekinanaCalendarGroupDragPolicy.minimumPressDuration"))
        XCTAssertTrue(source.contains("case .changed:"))
        XCTAssertTrue(source.contains("case .ended:"))
        XCTAssertTrue(source.contains("window.resizableSnapshotView("))
        XCTAssertTrue(source.contains("sourceSnapshot.transform = CGAffineTransform("))
        XCTAssertTrue(source.contains("updatePeerSnapshotPositions("))
        XCTAssertTrue(source.contains("scrollView.isScrollEnabled = false"))
        XCTAssertTrue(source.contains("dragScrollView.isScrollEnabled = dragScrollViewWasEnabled"))
        XCTAssertFalse(selectedDay.contains("dragResidualOffsetY"))
        XCTAssertFalse(selectedDay.contains("dragPreviewGroupKeys"))
        XCTAssertFalse(selectedDay.contains("updateGroupDrag("))
        XCTAssertFalse(selectedDay.contains("beginGroupDrag("))
        XCTAssertEqual(
            source.components(separatedBy: "surface.onReorderEnded(targetIndex)")
                .count - 1,
            1
        )
        XCTAssertEqual(
            selectedDay.components(
                separatedBy: "ChekinanaCalendarGroupOrderStore.setOrder("
            ).count - 1,
            1
        )
        XCTAssertTrue(groupRows.contains("openCalendarGroupEditor(group)"))
        XCTAssertTrue(selectedDay.contains("selectedGroupEditor = .init("))
        XCTAssertTrue(groupRows.contains("ChekinanaCalendarThumbnailStrip("))
        XCTAssertTrue(groupRows.contains("openCalendarMedia(group, initialID:"))
        XCTAssertFalse(eventRows.contains("ChekinanaCalendarGroupGestureSurface"))
        XCTAssertFalse(selectedDay.contains("calendarGroupDragHandle"))
        XCTAssertFalse(selectedDay.contains("calendar.group.drag-handle"))
        XCTAssertFalse(selectedDay.contains("line.3.horizontal"))

        var metrics = ChekinanaCalendarGroupDragRuntimeMetrics()
        for _ in 0..<240 { metrics.recordChangedFrame() }
        for _ in 0..<3 { metrics.recordTargetTransition() }
        metrics.recordPersistenceRequest(isReordered: true)
        XCTAssertEqual(metrics.changedFrameCount, 240)
        XCTAssertEqual(metrics.targetTransitionCount, 3)
        XCTAssertEqual(metrics.swiftStateNotificationCount, 0)
        XCTAssertEqual(metrics.persistenceRequestCount, 1)
    }

    func testActiveEditorsUseAvatarChecksDirectIdolEditAndWheelDates() throws {
        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)

        func slice(_ start: String, _ end: String) throws -> Substring {
            let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
            let endIndex = try XCTUnwrap(
                source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound
            )
            return source[startIndex..<endIndex]
        }

        let sharedSelection = try slice(
            "private struct ChekinanaIdolAvatarCheckSelectionView",
            "private struct ChekinanaNativeDateSelectionView"
        )
        XCTAssertTrue(sharedSelection.contains("ChekinanaNativeIdolSelectionGrid("))
        XCTAssertTrue(sharedSelection.contains("selectedIDs: $selectedIDs"))

        let avatarCheckGrid = try slice(
            "private struct ChekinanaNativeIdolSelectionGrid",
            "private struct ChekinanaIdolAvatarCheckSelectionView"
        )
        XCTAssertTrue(avatarCheckGrid.contains("accessibilityLabel(label)"))
        XCTAssertFalse(avatarCheckGrid.contains("Text(label)"))
        XCTAssertTrue(avatarCheckGrid.contains("minHeight: 74"))
        XCTAssertTrue(avatarCheckGrid.contains("ChekinanaNeutralIdolAvatar(size: 62)"))
        XCTAssertTrue(avatarCheckGrid.contains("ChekinanaIdolAvatar(idol: idol, size: 62)"))
        XCTAssertTrue(avatarCheckGrid.contains(
            "columns: ChekinanaIdolAvatarSelectionLayout.columns"
        ))
        XCTAssertFalse(avatarCheckGrid.contains(".adaptive("))

        let calendarEditor = try slice(
            "private struct ChekinanaCalendarRecordEditor",
            "struct ChekinanaCalendarIdolGroup"
        )
        XCTAssertTrue(calendarEditor.contains("ChekinanaIdolSelectionSummaryButton("))
        XCTAssertFalse(calendarEditor.contains("common.change_idols"))
        XCTAssertTrue(calendarEditor.contains("ChekinanaIdolAvatarCheckSelectionView("))
        XCTAssertTrue(calendarEditor.contains("guard !selectedIDs.isEmpty"))
        XCTAssertTrue(calendarEditor.contains("idolIDs: selectedIDs"))

        let recordEditor = try slice(
            "private struct ChekinanaChekiRecordEditor",
            "private struct ChekinanaMonthPicker"
        )
        XCTAssertTrue(recordEditor.contains("ChekinanaIdolAvatarCheckSelectionView("))
        XCTAssertTrue(recordEditor.contains("ChekinanaIdolSelectionSummaryButton("))
        XCTAssertFalse(recordEditor.contains("common.change_idols"))
        XCTAssertTrue(recordEditor.contains("chekinana.record.editor.idol-selection"))
        XCTAssertTrue(recordEditor.contains(
            "ChekinanaRequiredIdolSelectionPolicy.resolvedIDs("
        ))
        XCTAssertTrue(recordEditor.contains("guard !selectedIDs.isEmpty"))
        XCTAssertTrue(recordEditor.contains("idolIDs: Set(selectedIDs)"))
        let requiredIdolGuard = try XCTUnwrap(
            recordEditor.range(of: "guard !selectedIDs.isEmpty")?.lowerBound
        )
        let recordMutation = try XCTUnwrap(
            recordEditor.range(of: "ChekinanaChekiRecordStore.update(")?.lowerBound
        )
        XCTAssertLessThan(requiredIdolGuard, recordMutation)

        let detail = try slice(
            "private struct ChekinanaIdolDetailView",
            "private struct ChekinanaIdolLinkedEventsView"
        )
        XCTAssertTrue(detail.contains("Button(\"Edit\")"))
        XCTAssertTrue(detail.contains("chekinana.idols.detail.edit"))
        XCTAssertTrue(detail.contains("onDeleted:"))
        XCTAssertFalse(detail.contains("Menu {"))
        XCTAssertFalse(detail.contains("chekinana.idols.detail.hide"))

        let idolEditor = try slice(
            "private struct ChekinanaIdolEditorView",
            "enum ChekinanaIdolAvatarSelectionPolicy"
        )
        XCTAssertTrue(idolEditor.contains("chekinana.idols.editor.hide.section"))
        XCTAssertTrue(idolEditor.contains(".foregroundStyle(.black)"))
        XCTAssertTrue(idolEditor.contains("if idol != nil"))
        let errorIndex = try XCTUnwrap(idolEditor.range(of: "if let errorMessage")?.lowerBound)
        let hideIndex = try XCTUnwrap(
            idolEditor.range(of: "chekinana.idols.editor.hide.section")?.lowerBound
        )
        XCTAssertLessThan(errorIndex, hideIndex)
        let deleteRequestIndex = try XCTUnwrap(
            idolEditor.range(of: "chekinana.idols.editor.delete.request")?.lowerBound
        )
        XCTAssertLessThan(hideIndex, deleteRequestIndex)
        XCTAssertTrue(idolEditor.contains("isHideConfirmationPresented = true"))
        XCTAssertTrue(idolEditor.contains("idols.hide.confirm.title"))
        XCTAssertTrue(idolEditor.contains("idols.hide.confirm.message"))
        XCTAssertTrue(idolEditor.contains("idols.hide.confirm.action"))
        XCTAssertTrue(idolEditor.contains("chekinana.idols.editor.hide.confirm"))
        XCTAssertTrue(idolEditor.contains("chekinana.idols.editor.hide.cancel"))
        XCTAssertTrue(idolEditor.contains("isDeleteConfirmationPresented = true"))
        XCTAssertTrue(idolEditor.contains("chekinana.idols.editor.delete.confirm"))
        XCTAssertTrue(idolEditor.contains("chekinana.idols.editor.delete.cancel"))
        XCTAssertTrue(idolEditor.contains("ChekinanaIdolPersistence.delete("))
        XCTAssertTrue(idolEditor.contains("hiddenIdols.removeDeleted(idol.id)"))
        XCTAssertTrue(idolEditor.contains("onDeleted(result.pendingAvatarCleanup)"))
        XCTAssertTrue(idolEditor.contains(".overlay(alignment: .topLeading)"))
        let formPrefixEnd = try XCTUnwrap(
            idolEditor.range(of: "if idol == nil {")?.lowerBound
        )
        XCTAssertFalse(
            idolEditor[idolEditor.startIndex..<formPrefixEnd]
                .contains("ChekinanaAccessibilityMarker(")
        )

        let avatarPickerLabel = try slice(
            "private struct ChekinanaIdolEditorAvatarPickerLabel",
            "private struct ChekinanaIdolEditorView"
        )
        XCTAssertTrue(avatarPickerLabel.contains("frame(width: 62, height: 62)"))
        XCTAssertTrue(avatarPickerLabel.contains("ChekinanaIdolAvatar(idol: idol, size: 62)"))
        XCTAssertTrue(idolEditor.contains("PhotosPicker(selection: $avatarPickerItem"))
        XCTAssertTrue(idolEditor.contains("ChekinanaIdolEditorAvatarPickerLabel("))
        XCTAssertFalse(idolEditor.contains("Label(avatarPickerTitle"))
        XCTAssertTrue(idolEditor.contains("chekinana.idols.editor.avatar.picker"))
        XCTAssertTrue(idolEditor.contains("chekinana.idols.editor.avatar.remove"))
        XCTAssertTrue(idolEditor.contains(".onChange(of: avatarPickerItem)"))
        let avatarChange = try XCTUnwrap(
            idolEditor.range(of: ".onChange(of: avatarPickerItem)")
        )
        let avatarChangeSource = idolEditor[avatarChange.lowerBound...]
        let previewGuard = try XCTUnwrap(
            avatarChangeSource.range(of: "guard let preview")?.lowerBound
        )
        let acceptedItem = try XCTUnwrap(
            avatarChangeSource.range(of: "avatarItem = item")?.lowerBound
        )
        let clearsRemoval = try XCTUnwrap(
            avatarChangeSource.range(of: "removesAvatar = false")?.lowerBound
        )
        XCTAssertLessThan(previewGuard, acceptedItem)
        XCTAssertLessThan(acceptedItem, clearsRemoval)
        let localInvalidation = try XCTUnwrap(
            avatarChangeSource.range(of: "invalidatingCataloguePreparation")?.lowerBound
        )
        let localLoad = try XCTUnwrap(
            avatarChangeSource.range(of: "ChekinanaProductMediaLoader.load(item)")?.lowerBound
        )
        XCTAssertLessThan(localInvalidation, localLoad)
        XCTAssertTrue(avatarChangeSource.contains(
            "isPreparingCatalogueAvatar = invalidation.isPreparingCatalogueAvatar"
        ))

        let modeChange = try slice(
            ".onChange(of: mode)",
            ".onChange(of: avatarPickerItem)"
        )
        XCTAssertTrue(modeChange.contains("invalidatingCataloguePreparation"))
        XCTAssertTrue(modeChange.contains(
            "isPreparingCatalogueAvatar = invalidation.isPreparingCatalogueAvatar"
        ))
        XCTAssertTrue(modeChange.contains("isPreparingAvatarPreview = false"))
        XCTAssertTrue(modeChange.contains("if avatarItem == nil"))
        XCTAssertTrue(modeChange.contains("avatarPickerItem = nil"))
        XCTAssertTrue(modeChange.contains("avatarPreview = nil"))
        XCTAssertTrue(modeChange.contains("selectedCatalogueCandidate = nil"))

        let avatarRemove = try XCTUnwrap(
            idolEditor.range(of: "ChekinanaIdolAvatarSelectionPolicy.afterDelete(")
        )
        let avatarRemoveSource = idolEditor[avatarRemove.lowerBound...]
        XCTAssertTrue(avatarRemoveSource.contains(
            "isPreparingCatalogueAvatar = next.isPreparingCatalogueAvatar"
        ))

        let catalogueSelection = try slice(
            "private func select(_ rawCandidate: ChekinanaEnrichedIdol)",
            "private func save(generation: Int)"
        )
        XCTAssertTrue(catalogueSelection.contains(
            "ChekinanaIdolAvatarSelectionPolicy.acceptsCatalogueCompletion("
        ))

        let localizationURL = productSourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Localizable.xcstrings")
        let localization = try String(contentsOf: localizationURL, encoding: .utf8)
        for key in [
            "product.idols.hide.confirm.title",
            "product.idols.hide.confirm.message",
            "product.idols.hide.confirm.action",
            "product.idols.avatar.choose",
            "product.idols.avatar.replace",
            "product.idols.avatar.picker.hint",
            "product.idols.avatar.remove",
        ] {
            XCTAssertTrue(localization.contains("\"\(key)\""), key)
        }

        XCTAssertTrue(idolEditor.contains("birthday.month-wheel"))
        XCTAssertTrue(idolEditor.contains("birthday.day-wheel"))
        XCTAssertTrue(idolEditor.contains("ChekinanaExpandableMonthDayWheels("))
        XCTAssertTrue(idolEditor.contains("ChekinanaExpandableDateWheel("))
        XCTAssertFalse(idolEditor.contains("birthday.month-day-calendar"))
        XCTAssertTrue(idolEditor.contains("pendingPatternRemovalIndex = index"))
        XCTAssertTrue(idolEditor.contains("idols.pattern.remove.confirm.title"))
        XCTAssertTrue(idolEditor.contains(
            "chekinana.idols.editor.pattern.remove.confirm"
        ))
        XCTAssertTrue(idolEditor.contains(
            "chekinana.idols.editor.pattern.remove.cancel"
        ))
        XCTAssertTrue(idolEditor.contains("private func confirmPatternRemoval()"))
        XCTAssertFalse(idolEditor.contains(
            "Button(role: .destructive) { patterns.remove(at: index) }"
        ))
        XCTAssertEqual(
            idolEditor.components(separatedBy: "patterns.remove(at: index)").count - 1,
            1
        )
        XCTAssertFalse(source.contains(".datePickerStyle(.graphical)"))

        let mediaSummary = try slice(
            "@ViewBuilder private func mediaSummaryRow(",
            "private func mediaItems("
        )
        XCTAssertTrue(mediaSummary.contains("value: total.formatted()"))
        XCTAssertTrue(mediaSummary.contains("kind.countLabel(total)"))
        XCTAssertFalse(mediaSummary.contains(
            "value: kind.countLabel(count ?? items.count)"
        ))

        let linkedEventPage = try slice(
            "private struct ChekinanaIdolLinkedEventsView",
            "private typealias ChekinanaIdolMediaKind"
        )
        XCTAssertTrue(linkedEventPage.contains("ChekinanaIdolEventChekiView("))
        XCTAssertTrue(linkedEventPage.contains(
            "ChekinanaIdolEventChekiScope.mediaChekis("
        ))
        XCTAssertTrue(linkedEventPage.contains(
            "ChekinanaIdolEventChekiScope.simpleRecords("
        ))
        XCTAssertTrue(linkedEventPage.contains(
            "@ObservedObject private var hiddenIdols"
        ))
        XCTAssertTrue(linkedEventPage.contains("private var visibleEvents"))
        XCTAssertTrue(linkedEventPage.contains("hiddenIDs: hiddenIdols.hiddenIDs"))
        XCTAssertTrue(linkedEventPage.contains("@Query private var chekiRecords"))
        XCTAssertTrue(linkedEventPage.contains(
            "group.chekis.isEmpty && group.records.isEmpty"
        ))
        XCTAssertTrue(linkedEventPage.contains("calendar.no_records"))
        XCTAssertTrue(linkedEventPage.contains(
            "chekinana.idols.detail.event-cheki.empty.back"
        ))
        XCTAssertTrue(linkedEventPage.contains(
            "ChekinanaL10n.text(\"action.back\", fallback: \"Back\")"
        ))
        XCTAssertTrue(linkedEventPage.contains("ChekinanaChekiRecordEditor("))
        XCTAssertFalse(linkedEventPage.contains("ChekinanaEventDetailView("))

        let expandableDate = try slice(
            "private struct ChekinanaExpandableDateWheel",
            "private struct ChekinanaExpandableMonthDayWheels"
        )
        XCTAssertTrue(expandableDate.contains("@State private var isExpanded = false"))
        XCTAssertTrue(expandableDate.contains("isExpanded.toggle()"))
        XCTAssertTrue(expandableDate.contains("ChekinanaProductDate.displayString(selection)"))
        XCTAssertTrue(expandableDate.contains("displayedComponents: .date"))
        XCTAssertTrue(expandableDate.contains(".datePickerStyle(.wheel)"))
        XCTAssertEqual(
            source.components(separatedBy: "ChekinanaExpandableDateWheel(").count - 1,
            16
        )
        XCTAssertEqual(
            source.components(separatedBy: "displayedComponents: .date").count - 1,
            2
        )

        let monthDayWheels = try slice(
            "private struct ChekinanaExpandableMonthDayWheels",
            "enum ChekinanaScanReviewLayout"
        )
        XCTAssertTrue(monthDayWheels.contains("@State private var isExpanded = false"))
        XCTAssertTrue(monthDayWheels.contains("ChekinanaBirthdayValue.localizedDisplay"))
        XCTAssertTrue(monthDayWheels.contains("ChekinanaBirthdayEditorPolicy.dayRange(month: month)"))
        XCTAssertTrue(monthDayWheels.contains("accessibilityIdentifier(monthIdentifier)"))
        XCTAssertTrue(monthDayWheels.contains("accessibilityIdentifier(dayIdentifier)"))

        let detachedIdolSelection = try slice(
            "private struct ChekinanaIdolSelectionView",
            "private struct ChekinanaChekiEventSelectionField"
        )
        XCTAssertTrue(detachedIdolSelection.contains("accessibilityLabel(idol.name)"))
        XCTAssertFalse(detachedIdolSelection.contains("Text(idol.name)"))
        XCTAssertTrue(detachedIdolSelection.contains(
            "columns: ChekinanaIdolAvatarSelectionLayout.columns"
        ))
        XCTAssertFalse(detachedIdolSelection.contains("List {"))
        XCTAssertFalse(detachedIdolSelection.contains(".adaptive("))

        let recognitionCandidateSelection = try slice(
            "private struct ChekinanaCandidatePicker",
            "private struct ChekinanaSelectedPhotoThumbnail"
        )
        XCTAssertTrue(recognitionCandidateSelection.contains(
            "accessibilityLabel(idol.name)"
        ))
        XCTAssertFalse(recognitionCandidateSelection.contains("Text(idol.name)"))
        XCTAssertFalse(recognitionCandidateSelection.contains("similarityThreshold"))
        XCTAssertFalse(recognitionCandidateSelection.contains("Similarity threshold"))
        XCTAssertFalse(recognitionCandidateSelection.contains("Slider("))
        XCTAssertFalse(recognitionCandidateSelection.contains(
            "chekinana.scan.candidate.threshold"
        ))
        XCTAssertTrue(recognitionCandidateSelection.contains(
            "columns: ChekinanaIdolAvatarSelectionLayout.columns"
        ))
        XCTAssertFalse(recognitionCandidateSelection.contains(".adaptive("))

        let galleryIdolSelection = try slice(
            "private struct ChekinanaGalleryIdolFilterPicker",
            "private struct ChekinanaGalleryCard"
        )
        XCTAssertTrue(galleryIdolSelection.contains(
            "accessibilityLabel(idol.name)"
        ))
        XCTAssertFalse(galleryIdolSelection.contains("Text(idol.name)"))
        XCTAssertTrue(galleryIdolSelection.contains(
            "columns: ChekinanaIdolAvatarSelectionLayout.columns"
        ))
        XCTAssertFalse(galleryIdolSelection.contains(".adaptive("))
        XCTAssertEqual(
            source.components(
                separatedBy: "columns: ChekinanaIdolAvatarSelectionLayout.columns"
            ).count - 1,
            4
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "ChekinanaIdolSelectionSummaryButton("
            ).count - 1,
            6
        )
        XCTAssertFalse(source.contains("common.change_idols"))

        let timePicker = try slice(
            "private func optionalTimeControl(",
            "private func startExtraction()"
        )
        XCTAssertTrue(timePicker.contains("displayedComponents: .hourAndMinute"))
        XCTAssertFalse(timePicker.contains(".datePickerStyle(.wheel)"))
    }

    func testCalendarSelectedDayCompactsOnlyInterRowSpacing() throws {
        XCTAssertEqual(ChekinanaCalendarSelectedDayLayout.sectionSpacing, 14)
        XCTAssertEqual(ChekinanaCalendarSelectedDayLayout.recordSpacing, 8)
        XCTAssertLessThan(
            ChekinanaCalendarSelectedDayLayout.recordSpacing,
            ChekinanaCalendarSelectedDayLayout.sectionSpacing
        )
        XCTAssertEqual(ChekinanaCalendarSelectedDayLayout.thumbnailWidth, 38)
        XCTAssertEqual(ChekinanaCalendarSelectedDayLayout.thumbnailHeight, 50)
        XCTAssertEqual(ChekinanaCalendarSelectedDayLayout.thumbnailOverlap, -12)

        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private var selectedDayCard")?.lowerBound
        )
        let end = try XCTUnwrap(source.range(
            of: "private func idolNames",
            range: start..<source.endIndex
        )?.lowerBound)
        let selectedDay = String(source[start..<end])

        XCTAssertTrue(selectedDay.contains(
            "spacing: ChekinanaCalendarSelectedDayLayout.sectionSpacing"
        ))
        XCTAssertTrue(selectedDay.contains(
            "spacing: ChekinanaCalendarSelectedDayLayout.recordSpacing"
        ))
        XCTAssertTrue(selectedDay.contains("HStack(spacing: 12)"))
        XCTAssertTrue(selectedDay.contains(".padding(12)"))
        XCTAssertTrue(selectedDay.contains("size: 46"))
        XCTAssertTrue(selectedDay.contains("width: 46,"))
        XCTAssertTrue(selectedDay.contains("height: 46"))
        XCTAssertTrue(selectedDay.contains(".frame(height: 62)"))
        XCTAssertEqual(
            selectedDay.components(
                separatedBy: ".font(.subheadline.weight(.semibold))"
            ).count - 1,
            2
        )
        XCTAssertTrue(selectedDay.contains(".font(.caption)"))
        XCTAssertTrue(selectedDay.contains(".lineLimit(1)"))
        XCTAssertTrue(selectedDay.contains(".truncationMode(.tail)"))
        XCTAssertFalse(selectedDay.contains("eventVerticalPadding"))
        XCTAssertFalse(selectedDay.contains("eventHorizontalPadding"))
        XCTAssertFalse(selectedDay.contains("minimumHitHeight"))
    }

    func testIdolListUISourceKeepsDragImplementationButDisablesItsEntryPoint() throws {
        let productSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana")
            .appendingPathComponent("ChekinanaProductShell.swift")
        let source = try String(contentsOf: productSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("reorderEnabled: false"))
        XCTAssertTrue(source.contains("private func beginDrag(_ idolID: UUID)"))
        XCTAssertTrue(source.contains("private var dragGesture: some Gesture"))
        XCTAssertTrue(source.contains("if reorderEnabled {"))
        XCTAssertTrue(source.contains("else {\n            EmptyView()"))
    }

    func testEditChekiExplicitlyClearsAssociationsWithoutClearingOmittedFields() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "Association Idol")
        let date = utcDate(2026, 8, 5)
        let event = Event(name: "Association Event", date: date)
        let outsideWindow = Event(
            name: "Outside Window",
            date: utcDate(2026, 8, 10)
        )
        let cheki = Cheki(idols: [idol], event: event, date: date, idx: 1, note: "before")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        fixture.context.insert(outsideWindow)
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

        guard case .text = await fixture.executor.execute(
            "editcheki \(target) event=\(shortID(outsideWindow.id))"
        ) else {
            return XCTFail("an explicitly selected out-of-window Event must be rejected")
        }
        XCTAssertEqual(cheki.event?.id, event.id)

        guard case .pendingChekiCards(_, let movedCards, _) = await fixture.executor.execute(
            "editcheki \(target) date=2026-08-08"
        ), let movedCard = movedCards.first,
           let movedCode = movedCard.confirmationCode else {
            return XCTFail("expected date move confirmation")
        }
        XCTAssertNil(movedCard.eventName)
        try requireSuccess(await fixture.executor.execute("confirm \(movedCode)"))
        XCTAssertNil(cheki.event, "moving outside the ±1-day window clears the old Event")
        XCTAssertEqual(cheki.date, utcDate(2026, 8, 8))

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
            ChekinanaPatternClassifier.unassignedThreshold,
            0.6184226274,
            accuracy: 0.00000000001
        )
        XCTAssertTrue(ChekinanaPatternClassifier.assignsCandidate(
            similarity: ChekinanaPatternClassifier.unassignedThreshold,
            includesUnassigned: true
        ))
        XCTAssertFalse(ChekinanaPatternClassifier.assignsCandidate(
            similarity: ChekinanaPatternClassifier.unassignedThreshold.nextDown,
            includesUnassigned: true
        ))
        XCTAssertTrue(ChekinanaPatternClassifier.assignsCandidate(
            similarity: ChekinanaPatternClassifier.unassignedThreshold.nextDown,
            includesUnassigned: false
        ))

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
        XCTAssertLessThan(
            Double(try XCTUnwrap(rejected.similarity)),
            ChekinanaPatternClassifier.unassignedThreshold
        )

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
            "scancheki idol_recognition=true candidates=\(second.id.uuidString.lowercased()),unassigned idol_threshold=0",
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
            for position in 0..<(224 * 224) {
                channelSums[channel] += Double(
                    regions[channel * 224 * 224 + position].floatValue
                )
            }
        }
        let probes = [
            15_390, 20_560, 18_120, 38_440,
            47_570, 26_910, 33_360, 37_320,
        ]
        let probeValues = (0..<6).map { channel in
            probes.map {
                regions[channel * 224 * 224 + $0].floatValue
            }
        }
        print("PROGRAMMATIC_REGIONS sums=\(channelSums) probes=\(probeValues)")
        let pythonChannelSums = [
            -17072.5898, 18097.2832, 58162.5859,
            -30734.1719, 33702.4297, 78479.0313,
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
                0.96455175, 1.32417154, 1.78653991, -0.52530187,
                -0.52530187, -1.53566241, -1.80965841, -1.80965841,
            ],
            [
                -1.17787099, -0.44257697, -0.81022400, 0.53781521,
                0.53781521, 0.48529422, 1.83333325, 1.83333325,
            ],
            [
                0.06047938, 0.63564289, 0.63564289, 1.69882369,
                1.69882369, -0.14867094, 0.75764722, 0.75764722,
            ],
            [
                -0.52530187, -0.52530187, 1.95778739, -0.52530187,
                -0.52530187, -1.53566241, -0.52530187, -0.52530187,
            ],
            [
                0.53781521, 0.53781521, 0.36274520, 0.53781521,
                0.53781521, 1.71078432, 0.53781521, 0.53781521,
            ],
            [
                1.69882369, 1.69882369, 1.36766899, 1.69882369,
                1.69882369, 0.53106773, 1.69882369, 1.69882369,
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
            -0.0625289530, -0.0726452321, 0.0312285479, 0.0438625328,
            0.0590493642, 0.0039647729, 0.0276495870, -0.0873372555,
            -0.0405003466, 0.0343170241, 0.0138347214, -0.0902185738,
            -0.0792106763, 0.0815956444, -0.0225812364, -0.0385975763,
            -0.0918025523, -0.0536626354, 0.0850608423, -0.0000978574,
            -0.0070976191, 0.1818254888, -0.0378582440, -0.0786243007,
            -0.0355873816, 0.0656801239, 0.0306868590, -0.0365515277,
            -0.0286468044, 0.0252130479, -0.0655443370, 0.0600497201,
            0.0375626385, -0.0040317560, 0.0906233713, 0.0265563447,
            -0.0855601206, 0.0145179573, -0.0660951138, 0.1008356363,
            -0.0547989085, -0.0594857037, -0.0952514932, 0.0677765906,
            0.0185979102, -0.0336937904, -0.0509279184, -0.0158617981,
            -0.0840485245, 0.0569985397, -0.0800872743, 0.0224761609,
            0.0332499072, -0.0470711812, 0.0416735150, 0.0063371225,
            0.1659098268, 0.0700215325, -0.1165262386, -0.0284255873,
            0.0688674226, 0.0557550341, 0.0736099854, 0.0869497582,
            0.0146031883, -0.0633703321, -0.0460399874, 0.0960610658,
            -0.0676059946, -0.0153577337, 0.0257940497, -0.0756197721,
            0.0019956192, -0.0254563261, -0.0570065603, -0.0963906050,
            0.0354410931, -0.1296666414, 0.0146933645, -0.0008578456,
            -0.0379852206, 0.0120474594, 0.1061848029, 0.0919231623,
            -0.0329031572, 0.0361691490, 0.0519770533, 0.0042025228,
            0.0220109597, 0.0380098522, -0.0415515937, -0.1014095172,
            -0.0310916901, 0.0215543639, -0.0122981900, 0.0182502531,
            0.0013439415, -0.0682357848, 0.0767440051, -0.0457254462,
            0.0520732999, -0.0684271753, 0.0732871294, 0.0927593261,
            0.0405084901, -0.1132248193, 0.0275004487, -0.0178830028,
            0.1193000451, 0.0315888524, 0.0619544275, 0.0109337009,
            -0.0602093711, 0.0677344874, -0.0679114684, -0.0411932878,
            -0.0404530913, 0.0885267481, -0.1151442751, 0.0663475543,
            -0.0062082238, 0.0439863354, -0.0308618806, 0.0056206207,
            0.0379901938, -0.0422536470, 0.1094726697, -0.0497717373,
            0.0744796246, 0.0595054738, -0.0132759297, -0.0796617493,
            0.0121390969, -0.0502486825, 0.0703131258, 0.0006218281,
            0.0816641748, -0.0079006562, 0.0547648892, 0.0261363760,
            0.0431805998, -0.1013719961, -0.0124473311, -0.0103687514,
            -0.1278236806, 0.0075429473, 0.0359199941, -0.0649377108,
            -0.0070655639, 0.0204566568, 0.0471078046, 0.1255840510,
            -0.0413884632, 0.0185137633, 0.0034835266, -0.0683376566,
            -0.0730543584, 0.1228022277, -0.0005148174, 0.0238838699,
            -0.0595577210, -0.0544485673, 0.0540861376, 0.0004602585,
            -0.0279694386, 0.0907269642, -0.0441549234, -0.1326335967,
            -0.0703788847, 0.0411117487, -0.1133398041, 0.1014288366,
            0.0663560256, -0.0923196599, 0.0505008735, -0.0908140391,
            0.0552143306, -0.0888102576, -0.0025573561, -0.0290633887,
            0.0066960864, 0.0085109696, -0.0608410388, 0.0457034744,
            -0.0171480514, 0.0600224845, -0.0026074417, 0.0492762439,
            -0.0502750389, 0.0221835729, -0.0017277139, 0.0212914217,
            -0.0938333198, -0.0602977648, -0.0111394208, -0.0522011034,
            -0.0672538877, -0.0169360209, 0.0507316701, -0.0037101598,
            0.0787256435, -0.0572285168, 0.0330689140, -0.0192684848,
            0.0543633178, 0.0655936003, -0.1516882479, 0.0082333907,
            0.0105156172, -0.0732112974, -0.0111630904, 0.0295728855,
            -0.0159638133, 0.0076350863, -0.1437869221, -0.0224399976,
            -0.0401022807, 0.0808667764, -0.0244717784, 0.0206397492,
            0.0147711225, 0.0333194211, -0.0167948585, -0.0501779467,
            -0.0093507124, 0.0274400506, 0.0908213556, -0.1229535341,
            0.0009471900, 0.1056156531, -0.0471555106, -0.0555847697,
            0.1376198381, -0.0182092916, 0.1062071472, 0.0693772212,
            -0.0311481990, -0.0239685271, 0.0810380131, -0.1178330928,
            -0.0590902530, -0.0160140302, -0.0245638229, 0.0860219374,
            0.1038131341, 0.0396488719, 0.0942594036, -0.0347351693,
            -0.0412906259, -0.0769709274, -0.0197706204, -0.0648584962,
            -0.0130620524, 0.0567012094, -0.0103035467, -0.0931411758,
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
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.maximumRelativeError, 0.05)
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
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 1_200, height: 1_830
        ), .mini)
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 1_830, height: 1_200
        ), .mini)
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 2_300, height: 1_908
        ), .wide)
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 1_908, height: 2_300
        ), .wide)
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 1_200, height: 1_200
        ), .other)
        XCTAssertEqual(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 1_600, height: 1_200
        ), .other)
        XCTAssertNil(ChekinanaImportedChekiSizePolicy.inferredSize(
            width: 0, height: 1_200
        ))
    }

    func testImportedOtherSizeFlowsThroughNormalizeScannerResultAndLedger() async throws {
        let fixture = try makeFixture()
        let source = ChekinanaPendingChekiImage(
            data: scannerJPEGData(
                color: .purple,
                size: CGSize(width: 320, height: 320)
            ),
            filenameExtension: "jpg"
        )
        let normalized = try await ChekinanaLocalImportChekiProcessor.normalize(
            source.data,
            appliesWhiteBalance: false
        )
        XCTAssertEqual(normalized.inferredSize, .other)

        let result = try await ChekinanaLocalImportChekiProcessor.process(
            source,
            options: scannerOptions(
                dateRecognitionEnabled: false,
                directInputEnabled: true
            )
        )
        let resultImage = try XCTUnwrap(result.images.first)
        XCTAssertEqual(resultImage.inferredChekiSize, .other)

        let inserted = try fixture.ledger.insertTemporaryChekis(
            [ChekinanaPendingChekiImage(
                data: resultImage.data,
                filenameExtension: "jpg"
            )],
            thumbnailImageData: [nil],
            sizes: [resultImage.inferredChekiSize]
        ).inserted
        XCTAssertEqual(inserted.first?.size, .other)
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
        let schema = Schema([Idol.self, IdolPatternState.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self])
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

    func testCalendarBatchWriterStoresLargeQuantityInOneSimpleRecord() throws {
        let fixture = try makeFixture()
        let date = utcDate(2026, 8, 10)
        let selectedIdol = Idol(name: "Calendar Batch")
        let otherIdol = Idol(name: "Other Group")
        fixture.context.insert(selectedIdol)
        fixture.context.insert(otherIdol)
        let existing = Cheki(
            date: date.addingTimeInterval(12 * 60 * 60),
            idx: 7,
            imageRef: "existing.jpg"
        )
        fixture.context.insert(existing)
        existing.idols = [selectedIdol]
        let otherGroup = Cheki(date: date, idx: 99, imageRef: "other.jpg")
        fixture.context.insert(otherGroup)
        otherGroup.idols = [otherIdol]
        try fixture.context.save()

        let insertedIDs = try ChekinanaCalendarRecordBatchWriter.commit(
            .init(
                kind: .cheki,
                idolIDs: [selectedIdol.id],
                date: date,
                quantity: 150,
                manualStart: nil,
                note: "batch",
                eventID: nil
            ),
            in: fixture.context
        )

        XCTAssertEqual(insertedIDs.count, 1)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Cheki>()), 2)
        let inserted = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<ChekiRecord>()).first
        )
        XCTAssertEqual(inserted.id, insertedIDs.first)
        XCTAssertEqual(inserted.count, 150)
        XCTAssertEqual(inserted.idolIDs, [selectedIdol.id])
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

    func testCalendarQuantityPolicySupportsAnyPositiveChekiCount() {
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
        XCTAssertTrue(ChekinanaCalendarRecordQuantityPolicy.accepts(150, for: .cheki))
        XCTAssertTrue(ChekinanaCalendarRecordQuantityPolicy.accepts(Int.max, for: .cheki))
        XCTAssertFalse(ChekinanaCalendarRecordQuantityPolicy.accepts(0, for: .cheki))
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
        firstEvent.date = firstDate
        secondEvent.date = secondDate
        try fixture.context.save()

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
        XCTAssertEqual(firstSaved.userAppears, false)
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

        let undated = try insert(idols: [firstIdol], date: nil, event: nil)
        let undatedResponse = await fixture.executor.execute(
            "addscancheki \(shortID(undated.id))"
        )
        guard case .pendingChekiCards(_, let undatedCards, _) = undatedResponse,
              let undatedCode = undatedCards.first?.confirmationCode else {
            return XCTFail("an undated Cheki with no Event should remain confirmable")
        }
        try requireSuccess(await fixture.executor.execute("confirm \(undatedCode)"))
        let savedUndated = try XCTUnwrap(
            try fixture.context.fetch(FetchDescriptor<Cheki>())
                .first(where: { $0.date == nil && $0.event == nil })
        )
        XCTAssertNil(savedUndated.event)
        XCTAssertNil(savedUndated.idx)
        XCTAssertFalse(fixture.ledger.containsTemporaryCheki(undated.id))

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

    func testIdolMergeMovesEveryRelationshipOnceAndPreservesTargetAndRecordFields() throws {
        let fixture = try makeFixture()
        let source = Idol(
            sourceId: "source-catalogue",
            name: "Source",
            group: "Source Group",
            color: "#111111",
            birthday: "2000-01-02",
            avatarImageRef: "https://example.com/source.jpg",
            isFavorite: false,
            sortOrder: 9,
            note: "source note",
            verification: "source verification",
            bio: "source bio",
            patterns: [[Float](repeating: 0.1, count: 256)]
        )
        let targetCreatedAt = Date(timeIntervalSince1970: 123)
        let targetUpdatedAt = Date(timeIntervalSince1970: 456)
        let target = Idol(
            sourceId: "target-catalogue",
            name: "Target",
            group: "Target Group",
            color: "#abcdef",
            birthday: "02-29",
            avatarImageRef: "https://example.com/target.jpg",
            isFavorite: true,
            sortOrder: 1,
            note: "target note",
            createdAt: targetCreatedAt,
            updatedAt: targetUpdatedAt,
            verification: "target verification",
            bio: "target bio",
            patterns: [[Float](repeating: 0.2, count: 256)]
        )
        let other = Idol(name: "Other", sortOrder: 2)
        let event = Event(name: "Event", date: Date(timeIntervalSince1970: 10_000))
        let cheki = Cheki(
            idols: [source, other],
            event: event,
            date: Date(timeIntervalSince1970: 20_000),
            imageRef: "cheki.jpg",
            note: "cheki"
        )
        let chekiAlreadyLinked = Cheki(
            idols: [source, target, other],
            imageRef: "already.jpg"
        )
        let shame = Shame(imageRef: "shame.jpg", idols: [source, target, other])
        let douga = Douga(videoRef: "douga.mov", idols: [other, source])
        let recordDate = Date(timeIntervalSince1970: 30_000)
        let record = ChekiRecord(
            idols: [source, target, other],
            event: event,
            date: recordDate,
            size: .mini,
            note: "record note",
            count: 7
        )
        record.idolIDs = [source.id, target.id, other.id, source.id]
        let sourceState = IdolPatternState(
            idolID: source.id,
            encoderVersion: "source-version",
            cataloguePatternIDs: ["source-pattern"],
            cataloguePatternCount: 1
        )
        let targetState = IdolPatternState(
            idolID: target.id,
            encoderVersion: "target-version",
            cataloguePatternIDs: ["target-pattern"],
            cataloguePatternCount: 1
        )
        fixture.context.insert(source)
        fixture.context.insert(target)
        fixture.context.insert(other)
        fixture.context.insert(event)
        fixture.context.insert(cheki)
        fixture.context.insert(chekiAlreadyLinked)
        fixture.context.insert(shame)
        fixture.context.insert(douga)
        fixture.context.insert(record)
        fixture.context.insert(sourceState)
        fixture.context.insert(targetState)
        try fixture.context.save()
        let expectedChekiIDs = ChekinanaIdolMergePolicy.replacingSource(
            in: cheki.idols.map(\.id), sourceID: source.id, with: target.id
        )
        let expectedAlreadyLinkedIDs = ChekinanaIdolMergePolicy.replacingSource(
            in: chekiAlreadyLinked.idols.map(\.id), sourceID: source.id, with: target.id
        )
        let expectedShameIDs = ChekinanaIdolMergePolicy.replacingSource(
            in: shame.idols.map(\.id), sourceID: source.id, with: target.id
        )
        let expectedDougaIDs = ChekinanaIdolMergePolicy.replacingSource(
            in: douga.idols.map(\.id), sourceID: source.id, with: target.id
        )
        let expectedRecordIdolIDs = ChekinanaIdolMergePolicy.replacingSource(
            in: record.idolIDs, sourceID: source.id, with: target.id
        )
        var saveCount = 0

        let result = try ChekinanaIdolPersistence.merge(
            sourceID: source.id,
            into: target.id,
            in: fixture.context,
            saveContext: { context in
                saveCount += 1
                try context.save()
            }
        )

        XCTAssertEqual(saveCount, 1)
        XCTAssertNil(result.pendingAvatarCleanup)
        let persistedIdolIDs: [UUID] = try fixture.context
            .fetch(FetchDescriptor<Idol>())
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        let expectedIdolIDs: [UUID] = [target.id, other.id]
            .sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(persistedIdolIDs, expectedIdolIDs)
        XCTAssertEqual(Set(cheki.idols.map(\.id)), Set(expectedChekiIDs))
        XCTAssertEqual(cheki.idols.count, expectedChekiIDs.count)
        XCTAssertEqual(Set(chekiAlreadyLinked.idols.map(\.id)), Set(expectedAlreadyLinkedIDs))
        XCTAssertEqual(chekiAlreadyLinked.idols.count, expectedAlreadyLinkedIDs.count)
        XCTAssertEqual(Set(shame.idols.map(\.id)), Set(expectedShameIDs))
        XCTAssertEqual(shame.idols.count, expectedShameIDs.count)
        XCTAssertEqual(Set(douga.idols.map(\.id)), Set(expectedDougaIDs))
        XCTAssertEqual(douga.idols.count, expectedDougaIDs.count)
        XCTAssertEqual(record.idolIDs, expectedRecordIdolIDs)
        XCTAssertEqual(record.eventID, event.id)
        XCTAssertEqual(record.date, recordDate)
        XCTAssertEqual(record.size, .mini)
        XCTAssertEqual(record.note, "record note")
        XCTAssertEqual(record.count, 7)

        let targetID = target.id
        let persistedTarget = try XCTUnwrap(fixture.context.fetch(
            FetchDescriptor<Idol>(predicate: #Predicate { $0.id == targetID })
        ).first)
        XCTAssertEqual(persistedTarget.sourceId, "target-catalogue")
        XCTAssertEqual(persistedTarget.name, "Target")
        XCTAssertEqual(persistedTarget.group, "Target Group")
        XCTAssertEqual(persistedTarget.color, "#abcdef")
        XCTAssertEqual(persistedTarget.birthday, "02-29")
        XCTAssertEqual(persistedTarget.avatarImageRef, "https://example.com/target.jpg")
        XCTAssertTrue(persistedTarget.isFavorite)
        XCTAssertEqual(persistedTarget.sortOrder, 1)
        XCTAssertEqual(persistedTarget.note, "target note")
        XCTAssertEqual(persistedTarget.createdAt, targetCreatedAt)
        XCTAssertEqual(persistedTarget.updatedAt, targetUpdatedAt)
        XCTAssertEqual(persistedTarget.verification, "target verification")
        XCTAssertEqual(persistedTarget.bio, "target bio")
        XCTAssertEqual(persistedTarget.patterns, [[Float](repeating: 0.2, count: 256)])
        let states = try fixture.context.fetch(FetchDescriptor<IdolPatternState>())
        XCTAssertNil(states.first { $0.idolID == source.id })
        let persistedTargetState = try XCTUnwrap(states.first { $0.idolID == target.id })
        XCTAssertEqual(persistedTargetState.encoderVersion, "target-version")
        XCTAssertEqual(persistedTargetState.cataloguePatternIDs, ["target-pattern"])
        XCTAssertEqual(persistedTargetState.cataloguePatternCount, 1)
    }

    func testIdolMergeSaveFailureRollsBackSourceRelationshipsAndPatternState() throws {
        let fixture = try makeFixture()
        let source = Idol(name: "Source")
        let target = Idol(name: "Target")
        let other = Idol(name: "Other")
        let cheki = Cheki(idols: [source, other], imageRef: "cheki.jpg")
        let shame = Shame(imageRef: "shame.jpg", idols: [source, target])
        let douga = Douga(videoRef: "douga.mov", idols: [source])
        let record = ChekiRecord(idols: [source, other], note: "keep", count: 3)
        let sourceState = IdolPatternState(
            idolID: source.id,
            encoderVersion: "source-version"
        )
        fixture.context.insert(source)
        fixture.context.insert(target)
        fixture.context.insert(other)
        fixture.context.insert(cheki)
        fixture.context.insert(shame)
        fixture.context.insert(douga)
        fixture.context.insert(record)
        fixture.context.insert(sourceState)
        try fixture.context.save()
        let originalChekiIDs = cheki.idols.map(\.id)
        let originalShameIDs = shame.idols.map(\.id)
        let originalDougaIDs = douga.idols.map(\.id)
        let originalRecordIdolIDs = record.idolIDs

        XCTAssertThrowsError(try ChekinanaIdolPersistence.merge(
            sourceID: source.id,
            into: target.id,
            in: fixture.context,
            saveContext: { _ in throw NSError(domain: "merge-save", code: 1) }
        ))

        let idols = try fixture.context.fetch(FetchDescriptor<Idol>())
        XCTAssertNotNil(idols.first { $0.id == source.id })
        XCTAssertNotNil(idols.first { $0.id == target.id })
        XCTAssertEqual(Set(cheki.idols.map(\.id)), Set(originalChekiIDs))
        XCTAssertEqual(cheki.idols.count, originalChekiIDs.count)
        XCTAssertEqual(Set(shame.idols.map(\.id)), Set(originalShameIDs))
        XCTAssertEqual(shame.idols.count, originalShameIDs.count)
        XCTAssertEqual(Set(douga.idols.map(\.id)), Set(originalDougaIDs))
        XCTAssertEqual(douga.idols.count, originalDougaIDs.count)
        XCTAssertEqual(record.idolIDs, originalRecordIdolIDs)
        XCTAssertEqual(record.note, "keep")
        XCTAssertEqual(record.count, 3)
        XCTAssertNotNil(try fixture.context.fetch(FetchDescriptor<IdolPatternState>())
            .first { $0.idolID == source.id })
    }

    func testIdolMergeTargetsUseStableOrderAndExcludeSourceAndHiddenIdols() {
        let source = Idol(name: "Source", sortOrder: 2)
        let first = Idol(name: "First", sortOrder: 0)
        let hidden = Idol(name: "Hidden", sortOrder: 1)
        let last = Idol(name: "Last", sortOrder: 3)

        let targets = ChekinanaIdolMergePolicy.targets(
            from: [last, source, hidden, first],
            sourceID: source.id,
            hiddenIDs: [hidden.id]
        )

        XCTAssertEqual(targets.map(\.id), [first.id, last.id])
        XCTAssertEqual(
            ChekinanaIdolMergePolicy.replacingSource(
                in: [last, source, hidden, last, first],
                sourceID: source.id,
                with: first
            ).map(\.id),
            [last.id, first.id, hidden.id]
        )
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
        target.userAppears = nil
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
        inferred.userAppears = nil
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
        let date = utcDate(2026, 8, 1)
        let exact = Event(name: "Summer", date: date)
        let longer = Event(name: "Summer Tour", date: date)
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
        guard case .text = ambiguous else {
            return XCTFail("a partial Event name matching multiple records must be rejected")
        }

        let duplicate = await fixture.executor.execute("addevent Summer date=2026-08-03")
        guard case .confirmationText(_, let code) = duplicate else {
            return XCTFail("date makes this a distinct event")
        }
        _ = await fixture.executor.execute("confirm \(code)")
        let duplicateAgain = await fixture.executor.execute("addevent Summer date=2026-08-01")
        guard case .text = duplicateAgain else {
            return XCTFail("the same Event name and date must be rejected as a duplicate")
        }
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

    func testSingleIdolConfirmationAddsMappedCloudPatternWithoutDuplicates() async throws {
        let prototype = ChekinanaPatternDebugFixture.unitVector(20)
        let candidate = enrichedIdol(
            sourceID: "idol_002009",
            name: "aina",
            group: "Catalogue group",
            avatarURL: "https://example.com/aina.jpg",
            patternIDs: ["Aina_P1"]
        )
        let avatarData = scannerPNGData(color: .purple)
        let fixture = try makeFixture(
            patternResolve: { _ in [prototype] },
            idolSearch: { _ in [candidate] },
            idolAvatarPrepare: { _ in avatarData }
        )

        guard case .idolCard(let preview) = await fixture.executor.execute("addidol aina"),
              let code = preview.confirmationCode else {
            return XCTFail("expected single Idol confirmation")
        }
        guard case .idolCard = await fixture.executor.execute("confirm \(code)") else {
            return XCTFail("expected confirmed Idol card")
        }

        let saved = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<Idol>()).first)
        XCTAssertEqual(saved.sourceId, candidate.sourceId)
        XCTAssertEqual(saved.patterns, [prototype])
        XCTAssertEqual(saved.patterns.count, 1)
        XCTAssertEqual(
            try ChekinanaIdolPatternPersistence.state(
                for: saved.id,
                in: fixture.context
            )?.cataloguePatternIDs,
            ["Aina_P1"]
        )
    }

    func testBatchCandidateConfirmAddsMinaPatternsAndLeavesUnknownEmpty() async throws {
        let first = ChekinanaPatternDebugFixture.unitVector(21)
        let second = ChekinanaPatternDebugFixture.unitVector(22)
        let mina = enrichedIdol(
            sourceID: "idol_001326",
            name: "mina",
            group: "凌晨12点",
            avatarURL: "https://example.com/mina.jpg",
            patternIDs: ["Mina_XII_P1", "Mina_XII_P2"]
        )
        let unknown = enrichedIdol(
            sourceID: "idol_unknown_dialogue",
            name: "Unknown",
            group: nil,
            avatarURL: "https://example.com/unknown.jpg"
        )
        let avatarData = scannerPNGData(color: .purple)
        let fixture = try makeFixture(
            patternResolve: { patternIDs in
                patternIDs.map { $0 == "Mina_XII_P1" ? first : second }
            },
            idolSearch: { query in query == "mina" ? [mina] : [unknown] },
            idolAvatarPrepare: { _ in avatarData }
        )

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
        XCTAssertEqual(savedMina.patterns, [first, second])
        XCTAssertEqual(savedMina.patterns.count, 2)
        let savedUnknown = try XCTUnwrap(saved.first { $0.sourceId == unknown.sourceId })
        XCTAssertTrue(savedUnknown.patterns.isEmpty)
    }

    func testSelectedCandidateThenConfirmationAddsMappedPatternOnce() async throws {
        let prototype = ChekinanaPatternDebugFixture.unitVector(23)
        let mapped = enrichedIdol(
            sourceID: "idol_000513",
            name: "巫歌",
            group: "Catalogue group",
            avatarURL: "https://example.com/utaka.jpg",
            patternIDs: ["Utaka_P1"]
        )
        let other = enrichedIdol(
            sourceID: "idol_other_dialogue",
            name: "Other",
            group: nil,
            avatarURL: "https://example.com/other.jpg"
        )
        let avatarData = scannerPNGData(color: .purple)
        let fixture = try makeFixture(
            patternResolve: { _ in [prototype] },
            idolSearch: { _ in [mapped, other] },
            idolAvatarPrepare: { _ in avatarData }
        )

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
        XCTAssertEqual(saved.patterns, [prototype])
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

    func testEventTimeNormalizationAndOptionalDraftRoundTrip() {
        XCTAssertEqual(ChekinanaEventTime.normalized("0:00"), "00:00")
        XCTAssertEqual(ChekinanaEventTime.normalized("9:50"), "09:50")
        XCTAssertEqual(ChekinanaEventTime.normalized("23:59"), "23:59")
        for invalid in ["", "24:00", "12:60", "9:5", "09.50", "OPEN 09:00"] {
            XCTAssertNil(ChekinanaEventTime.normalized(invalid), invalid)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fallback = utcDate(2026, 8, 24)
        var draft = ChekinanaEventTimeDraft(
            storedValue: "9:50",
            calendar: calendar,
            fallback: fallback
        )
        XCTAssertTrue(draft.isEnabled)
        XCTAssertEqual(draft.persistedValue(calendar: calendar), "09:50")
        draft.isEnabled = false
        XCTAssertNil(draft.persistedValue(calendar: calendar))
        draft.replace(with: "23:59", calendar: calendar, fallback: fallback)
        XCTAssertEqual(draft.persistedValue(calendar: calendar), "23:59")
        draft.replace(with: nil, calendar: calendar, fallback: fallback)
        XCTAssertFalse(draft.isEnabled)
        XCTAssertNil(draft.persistedValue(calendar: calendar))
    }

    func testEventDateStateKeepsNewEventUndatedUntilEnabledOrParsed() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fallback = utcDate(2026, 8, 24)

        XCTAssertNil(ChekinanaEventDateState.persistedDate(
            hasDate: false,
            selection: fallback,
            calendar: calendar
        ))
        XCTAssertEqual(
            ChekinanaEventDateState.persistedDate(
                hasDate: true,
                selection: fallback,
                calendar: calendar
            ),
            fallback
        )
        XCTAssertNil(ChekinanaEventDateState.parsedCandidateDate(
            "",
            calendar: calendar
        ))
        XCTAssertNil(ChekinanaEventDateState.parsedCandidateDate(
            "2026-02-30",
            calendar: calendar
        ))
        let parsedDisplayDate = try XCTUnwrap(
            ChekinanaEventDateState.parsedCandidateDate(
                "2026-08-25",
                calendar: calendar
            )
        )
        XCTAssertEqual(
            ChekinanaDateOnly.canonicalDate(
                from: parsedDisplayDate,
                displayedIn: calendar
            ),
            utcDate(2026, 8, 25)
        )
    }

    func testEventOrderingReversesOnlyDateGroupsAndKeepsSameDayStartAscending() {
        let earlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let lateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let missingID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let nextDayID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let sameStartID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let day = utcDate(2026, 8, 24)
        let nextDay = utcDate(2026, 8, 25)
        let early = Event(id: earlyID, name: "Z", date: day)
        let late = Event(id: lateID, name: "A", date: day)
        let missing = Event(id: missingID, name: "M", date: day)
        let next = Event(id: nextDayID, name: "Next", date: nextDay)
        let sameStart = Event(id: sameStartID, name: "A sorts after Z by ID", date: day)
        let schedules = [
            EventSchedule(eventID: lateID, startTime: "19:00"),
            EventSchedule(eventID: earlyID, startTime: "10:00"),
            EventSchedule(eventID: sameStartID, startTime: "10:00"),
        ]

        XCTAssertEqual(
            ChekinanaEventOrdering.ordered(
                [missing, sameStart, next, late, early],
                schedules: schedules,
                dateAscending: true
            ).map(\.id),
            [earlyID, sameStartID, lateID, missingID, nextDayID]
        )
        XCTAssertEqual(
            ChekinanaEventOrdering.ordered(
                [missing, sameStart, next, late, early],
                schedules: schedules,
                dateAscending: false
            ).map(\.id),
            [nextDayID, earlyID, sameStartID, lateID, missingID]
        )
    }

    func testEventCandidateTimeFieldsAcceptMissingNullValidAndInvalidValues() throws {
        let missing = Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Missing","date":"","city":"","livehouse":"","address":"","price":"","avatar_url":"","imageUrls":[],"weiboURL":"","ticketURL":""}}"#.utf8)
        XCTAssertNil(try ChekinanaEventCandidateClient.decodeSuccess(missing).openTime)
        XCTAssertNil(try ChekinanaEventCandidateClient.decodeSuccess(missing).startTime)

        let null = Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Null","date":"","city":"","livehouse":"","address":"","price":"","avatar_url":"","imageUrls":[],"weiboURL":"","ticketURL":"","openTime":null,"startTime":null}}"#.utf8)
        XCTAssertNil(try ChekinanaEventCandidateClient.decodeSuccess(null).openTime)
        XCTAssertNil(try ChekinanaEventCandidateClient.decodeSuccess(null).startTime)

        let valid = Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Valid","date":"","city":"","livehouse":"","address":"","price":"","avatar_url":"","imageUrls":[],"weiboURL":"","ticketURL":"","openTime":"9:50","startTime":"23:59"}}"#.utf8)
        let validFields = try ChekinanaEventCandidateClient.decodeSuccess(valid)
        XCTAssertEqual(validFields.openTime, "09:50")
        XCTAssertEqual(validFields.startTime, "23:59")

        let invalid = Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Invalid","date":"","city":"","livehouse":"","address":"","price":"","avatar_url":"","imageUrls":[],"weiboURL":"","ticketURL":"","openTime":"24:00","startTime":42}}"#.utf8)
        XCTAssertNil(try ChekinanaEventCandidateClient.decodeSuccess(invalid).openTime)
        XCTAssertNil(try ChekinanaEventCandidateClient.decodeSuccess(invalid).startTime)
    }

    func testEventSchedulePersistenceNormalizesEditsAndDeletesClearedSchedule() throws {
        let fixture = try makeFixture()
        let event = Event(name: "Schedule")
        fixture.context.insert(event)
        try fixture.context.save()
        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: "9:50",
            startTime: "0:00",
            in: fixture.context
        )
        XCTAssertEqual(
            try ChekinanaEventSchedulePersistence.value(for: event.id, in: fixture.context),
            .init(openTime: "09:50", startTime: "00:00")
        )

        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: "not-a-time",
            startTime: nil,
            in: fixture.context
        )
        XCTAssertEqual(
            try ChekinanaEventSchedulePersistence.value(for: event.id, in: fixture.context),
            .empty
        )
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<EventSchedule>()).isEmpty)
    }

    func testMediaEventLinksRoundTripUpdateClearAndRemainUniquePerMediaKind() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let context = ModelContext(container)
        let firstEvent = Event(name: "First")
        let secondEvent = Event(name: "Second")
        let shame = Shame(imageRef: "shame.jpg")
        let douga = Douga(videoRef: "douga.mov")
        [firstEvent, secondEvent].forEach(context.insert)
        context.insert(shame)
        context.insert(douga)
        try context.save()

        XCTAssertNil(ChekinanaMediaEventLinkStore.eventID(
            mediaID: shame.id,
            kind: .shame,
            links: try context.fetch(FetchDescriptor<MediaEventLink>())
        ))
        try ChekinanaMediaEventLinkStore.set(
            mediaID: shame.id,
            kind: .shame,
            eventID: firstEvent.id,
            in: context
        )
        try ChekinanaMediaEventLinkStore.set(
            mediaID: douga.id,
            kind: .douga,
            eventID: firstEvent.id,
            in: context
        )
        var links = try context.fetch(FetchDescriptor<MediaEventLink>())
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(
            ChekinanaMediaEventLinkStore.eventID(
                mediaID: shame.id,
                kind: .shame,
                links: links
            ),
            firstEvent.id
        )

        try ChekinanaMediaEventLinkStore.set(
            mediaID: shame.id,
            kind: .shame,
            eventID: secondEvent.id,
            in: context
        )
        links = try context.fetch(FetchDescriptor<MediaEventLink>())
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(
            links.first { $0.mediaID == shame.id }?.eventID,
            secondEvent.id
        )

        try ChekinanaMediaEventLinkStore.set(
            mediaID: shame.id,
            kind: .shame,
            eventID: nil,
            in: context
        )
        links = try context.fetch(FetchDescriptor<MediaEventLink>())
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.mediaID, douga.id)

        let verification = ModelContext(container)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<MediaEventLink>()).first?.eventID,
            firstEvent.id
        )
    }

    func testMediaEventLinkCleanupRemovesMediaAndEventReferences() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let context = ModelContext(container)
        let event = Event(name: "Linked")
        let shame = Shame(imageRef: "shame.jpg")
        let douga = Douga(videoRef: "douga.mov")
        context.insert(event)
        context.insert(shame)
        context.insert(douga)
        try context.save()
        try ChekinanaMediaEventLinkStore.set(
            mediaID: shame.id,
            kind: .shame,
            eventID: event.id,
            in: context
        )
        try ChekinanaMediaEventLinkStore.set(
            mediaID: douga.id,
            kind: .douga,
            eventID: event.id,
            in: context
        )

        try ChekinanaMediaEventLinkStore.delete(
            mediaID: shame.id,
            kind: .shame,
            in: context
        )
        context.delete(shame)
        try context.save()
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MediaEventLink>()).map(\.mediaID),
            [douga.id]
        )

        try ChekinanaMediaEventLinkStore.delete(eventID: event.id, in: context)
        context.delete(event)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<MediaEventLink>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Douga>()).first?.id, douga.id)
    }

    func testMediaShotTypesRoundTripUpsertAndDeleteCleanup() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV12.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )]
        )
        let context = ModelContext(container)
        let shame = Shame(imageRef: "shame.jpg")
        let douga = Douga(videoRef: "douga.mov")
        context.insert(shame)
        context.insert(douga)
        try context.save()

        XCTAssertFalse(ChekinanaMediaShotTypeStore.userAppears(
            mediaID: shame.id,
            kind: .shame,
            values: try context.fetch(FetchDescriptor<MediaShotType>())
        ))
        try ChekinanaMediaShotTypeStore.set(
            mediaID: shame.id,
            kind: .shame,
            userAppears: true,
            in: context
        )
        try ChekinanaMediaShotTypeStore.set(
            mediaID: douga.id,
            kind: .douga,
            userAppears: true,
            in: context
        )
        try ChekinanaMediaShotTypeStore.set(
            mediaID: shame.id,
            kind: .shame,
            userAppears: false,
            in: context
        )

        let verification = ModelContext(container)
        let values = try verification.fetch(FetchDescriptor<MediaShotType>())
        XCTAssertEqual(values.count, 2)
        XCTAssertFalse(ChekinanaMediaShotTypeStore.userAppears(
            mediaID: shame.id,
            kind: .shame,
            values: values
        ))
        XCTAssertTrue(ChekinanaMediaShotTypeStore.userAppears(
            mediaID: douga.id,
            kind: .douga,
            values: values
        ))

        try ChekinanaMediaShotTypeStore.delete(
            mediaID: shame.id,
            kind: .shame,
            in: context
        )
        context.delete(shame)
        try context.save()
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MediaShotType>()).map(\.mediaID),
            [douga.id]
        )

        try ChekinanaMediaShotTypeStore.delete(
            mediaID: douga.id,
            kind: .douga,
            in: context
        )
        context.delete(douga)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<MediaShotType>()).isEmpty)
    }

    func testV8MediaStoreMigratesToV9WithPreservedMediaAndNoInventedLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-v8-v9-media-link-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("current.store")
        let eventID = UUID()
        let shameID = UUID()
        let dougaID = UUID()

        let v8Schema = Schema(versionedSchema: ChekinanaSchemaV8.self)
        var v8Container: ModelContainer? = try ModelContainer(
            for: v8Schema,
            configurations: [ModelConfiguration(
                "Chekinana",
                schema: v8Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(v8Container))
            context.insert(Event(id: eventID, name: "Preserved Event"))
            context.insert(Shame(id: shameID, imageRef: "shame.jpg"))
            context.insert(Douga(id: dougaID, videoRef: "douga.mov"))
            try context.save()
        }
        v8Container = nil

        let v9Schema = Schema(versionedSchema: ChekinanaSchemaV9.self)
        let v9Container = try ModelContainer(
            for: v9Schema,
            migrationPlan: ChekinanaSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(
                "Chekinana",
                schema: v9Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(v9Container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Event>()).first?.id, eventID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Shame>()).first?.id, shameID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Douga>()).first?.id, dougaID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MediaEventLink>()).isEmpty)
    }

    func testV9StoreMigratesToV10WithPreservedDataAndEmptyCalendarOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-v9-v10-calendar-order-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("current.store")
        let idolID = UUID()

        let v9Schema = Schema(versionedSchema: ChekinanaSchemaV9.self)
        var v9Container: ModelContainer? = try ModelContainer(
            for: v9Schema,
            configurations: [ModelConfiguration(
                "Chekinana",
                schema: v9Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(v9Container))
            context.insert(Idol(id: idolID, name: "Preserved Idol"))
            try context.save()
        }
        v9Container = nil

        let v10Schema = Schema(versionedSchema: ChekinanaSchemaV10.self)
        var v10Container: ModelContainer? = try ModelContainer(
            for: v10Schema,
            migrationPlan: ChekinanaSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(
                "Chekinana",
                schema: v10Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        do {
            let context = ModelContext(try XCTUnwrap(v10Container))
            XCTAssertEqual(try context.fetch(FetchDescriptor<Idol>()).first?.id, idolID)
            XCTAssertTrue(try context.fetch(FetchDescriptor<CalendarGroupOrder>()).isEmpty)
            try ChekinanaCalendarGroupOrderStore.setOrder(
                [idolID.uuidString.lowercased()],
                dateKey: "2026-08-26",
                in: context
            )
        }
        v10Container = nil

        v10Container = try ModelContainer(
            for: v10Schema,
            configurations: [ModelConfiguration(
                "Chekinana",
                schema: v10Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
        let reopenedContext = ModelContext(try XCTUnwrap(v10Container))
        XCTAssertEqual(
            try reopenedContext.fetch(FetchDescriptor<CalendarGroupOrder>()).first?.groupKey,
            idolID.uuidString.lowercased()
        )
    }

    func testEventDeleteFirstRejectsStaleEditorScheduleSaveWithoutOrphan() throws {
        let fixture = try makeFixture()
        let event = Event(name: "Delete First")
        fixture.context.insert(event)
        try fixture.context.save()

        let staleContext = ModelContext(fixture.context.container)
        staleContext.autosaveEnabled = false
        let staleEvent = try XCTUnwrap(
            try staleContext.fetch(FetchDescriptor<Event>()).first
        )
        let expectedUpdatedAt = staleEvent.updatedAt

        let deleteContext = ModelContext(fixture.context.container)
        deleteContext.autosaveEnabled = false
        let deleteEvent = try XCTUnwrap(
            try deleteContext.fetch(FetchDescriptor<Event>()).first
        )
        try ChekinanaEventPersistence.delete(deleteEvent, from: deleteContext)

        XCTAssertThrowsError(try ChekinanaEventPersistence.update(
            eventID: staleEvent.id,
            expectedUpdatedAt: expectedUpdatedAt,
            schedule: .init(openTime: "18:00", startTime: "18:30"),
            in: staleContext,
            apply: { $0.name = "Must Not Return" }
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaEventMutationError,
                .changedOrMissingEvent
            )
        }
        XCTAssertThrowsError(try ChekinanaEventSchedulePersistence.set(
            eventID: staleEvent.id,
            openTime: "20:00",
            startTime: nil,
            in: staleContext
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaEventMutationError,
                .changedOrMissingEvent
            )
        }

        let verification = ModelContext(fixture.context.container)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<Event>()).isEmpty)
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<EventSchedule>()).isEmpty
        )
    }

    func testEventScheduleSaveFirstThenDeleteRemovesSchedule() throws {
        let fixture = try makeFixture()
        let event = Event(name: "Save First")
        fixture.context.insert(event)
        try fixture.context.save()

        let scheduleContext = ModelContext(fixture.context.container)
        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: "18:00",
            startTime: "18:30",
            in: scheduleContext
        )

        let deleteContext = ModelContext(fixture.context.container)
        let liveEvent = try XCTUnwrap(
            try deleteContext.fetch(FetchDescriptor<Event>()).first
        )
        try ChekinanaEventPersistence.delete(liveEvent, from: deleteContext)

        let verification = ModelContext(fixture.context.container)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<Event>()).isEmpty)
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<EventSchedule>()).isEmpty
        )
    }

    func testEventUpdateSaveFailureRollsBackFieldsAndScheduleAndReleasesGate() throws {
        enum InjectedFailure: Error { case save }

        let fixture = try makeFixture()
        let event = Event(name: "Original")
        fixture.context.insert(event)
        try fixture.context.save()
        let expectedUpdatedAt = event.updatedAt

        let failedContext = ModelContext(fixture.context.container)
        XCTAssertThrowsError(try ChekinanaEventPersistence.update(
            eventID: event.id,
            expectedUpdatedAt: expectedUpdatedAt,
            schedule: .init(openTime: "18:00", startTime: "18:30"),
            in: failedContext,
            saveContext: { _ in throw InjectedFailure.save },
            apply: {
                $0.name = "Partial"
                $0.updatedAt = expectedUpdatedAt.addingTimeInterval(1)
            }
        )) { error in
            XCTAssertTrue(error is InjectedFailure)
        }

        var verification = ModelContext(fixture.context.container)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<Event>()).first?.name,
            "Original"
        )
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<EventSchedule>()).isEmpty
        )

        let successfulContext = ModelContext(fixture.context.container)
        try ChekinanaEventPersistence.update(
            eventID: event.id,
            expectedUpdatedAt: expectedUpdatedAt,
            schedule: .init(openTime: "19:00", startTime: "19:30"),
            in: successfulContext,
            apply: {
                $0.name = "Committed"
                $0.updatedAt = expectedUpdatedAt.addingTimeInterval(2)
            }
        )

        verification = ModelContext(fixture.context.container)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<Event>()).first?.name,
            "Committed"
        )
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<EventSchedule>()).first?.openTime,
            "19:00"
        )
    }

    func testEventNoteDraftRejectsConcurrentFullEditWithoutOverwritingIt() throws {
        let fixture = try makeFixture()
        let event = Event(name: "Original", note: "original note")
        fixture.context.insert(event)
        try fixture.context.save()
        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: "18:00",
            startTime: "18:30",
            in: fixture.context
        )

        let staleContext = ModelContext(fixture.context.container)
        staleContext.autosaveEnabled = false
        let staleEvent = try XCTUnwrap(
            try staleContext.fetch(FetchDescriptor<Event>()).first
        )
        let staleRevision = staleEvent.updatedAt

        let fullEditContext = ModelContext(fixture.context.container)
        fullEditContext.autosaveEnabled = false
        try ChekinanaEventPersistence.update(
            eventID: event.id,
            expectedUpdatedAt: staleRevision,
            schedule: .init(openTime: "19:00", startTime: "19:30"),
            in: fullEditContext,
            apply: {
                $0.name = "Full Edit"
                $0.note = "full edit note"
                $0.updatedAt = staleRevision.addingTimeInterval(1)
            }
        )

        XCTAssertThrowsError(try ChekinanaEventPersistence.update(
            eventID: event.id,
            expectedUpdatedAt: staleRevision,
            in: staleContext,
            apply: {
                $0.note = "stale note"
                $0.updatedAt = staleRevision.addingTimeInterval(2)
            }
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaEventMutationError,
                .changedOrMissingEvent
            )
        }

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<Event>()).first
        )
        XCTAssertEqual(saved.name, "Full Edit")
        XCTAssertEqual(saved.note, "full edit note")
        XCTAssertEqual(
            try ChekinanaEventSchedulePersistence.value(
                for: event.id,
                in: verification
            ),
            .init(openTime: "19:00", startTime: "19:30")
        )
    }

    func testEventNoteDraftRejectsDeletedEventWithoutRecreatingIt() throws {
        let fixture = try makeFixture()
        let event = Event(name: "Delete Note", note: "original")
        fixture.context.insert(event)
        try fixture.context.save()

        let staleContext = ModelContext(fixture.context.container)
        staleContext.autosaveEnabled = false
        let staleEvent = try XCTUnwrap(
            try staleContext.fetch(FetchDescriptor<Event>()).first
        )
        let staleRevision = staleEvent.updatedAt

        let deleteContext = ModelContext(fixture.context.container)
        deleteContext.autosaveEnabled = false
        let liveEvent = try XCTUnwrap(
            try deleteContext.fetch(FetchDescriptor<Event>()).first
        )
        try ChekinanaEventPersistence.delete(liveEvent, from: deleteContext)

        XCTAssertThrowsError(try ChekinanaEventPersistence.update(
            eventID: event.id,
            expectedUpdatedAt: staleRevision,
            in: staleContext,
            apply: {
                $0.note = "must not return"
                $0.updatedAt = staleRevision.addingTimeInterval(1)
            }
        )) { error in
            XCTAssertEqual(
                error as? ChekinanaEventMutationError,
                .changedOrMissingEvent
            )
        }

        let verification = ModelContext(fixture.context.container)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<Event>()).isEmpty)
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<EventSchedule>()).isEmpty
        )
    }

    func testEventNoteUpdatePreservesScheduleAndFailureRollsBackAndReleasesGate() throws {
        enum InjectedFailure: Error { case save }

        let fixture = try makeFixture()
        let event = Event(name: "Note", note: "original")
        fixture.context.insert(event)
        try fixture.context.save()
        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: "18:00",
            startTime: "18:30",
            in: fixture.context
        )
        let revision = event.updatedAt

        let failedContext = ModelContext(fixture.context.container)
        failedContext.autosaveEnabled = false
        XCTAssertThrowsError(try ChekinanaEventPersistence.update(
            eventID: event.id,
            expectedUpdatedAt: revision,
            in: failedContext,
            saveContext: { _ in throw InjectedFailure.save },
            apply: {
                $0.note = "partial"
                $0.updatedAt = revision.addingTimeInterval(1)
            }
        )) { error in
            XCTAssertTrue(error is InjectedFailure)
        }

        var verification = ModelContext(fixture.context.container)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<Event>()).first?.note,
            "original"
        )
        XCTAssertEqual(
            try ChekinanaEventSchedulePersistence.value(
                for: event.id,
                in: verification
            ),
            .init(openTime: "18:00", startTime: "18:30")
        )

        let successfulContext = ModelContext(fixture.context.container)
        successfulContext.autosaveEnabled = false
        try ChekinanaEventPersistence.update(
            eventID: event.id,
            expectedUpdatedAt: revision,
            in: successfulContext,
            apply: {
                $0.note = "committed"
                $0.updatedAt = revision.addingTimeInterval(2)
            }
        )

        verification = ModelContext(fixture.context.container)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<Event>()).first?.note,
            "committed"
        )
        XCTAssertEqual(
            try ChekinanaEventSchedulePersistence.value(
                for: event.id,
                in: verification
            ),
            .init(openTime: "18:00", startTime: "18:30")
        )
    }

    func testEventCreateSaveFailureRollsBackEventAndScheduleAndReleasesGate() throws {
        enum InjectedFailure: Error { case save }

        let fixture = try makeFixture()
        let failedEvent = Event(name: "Must Roll Back")
        XCTAssertThrowsError(try ChekinanaEventPersistence.save(
            failedEvent,
            inserting: true,
            images: [],
            schedule: .init(openTime: "18:00", startTime: "18:30"),
            previousAvatarRef: nil,
            in: fixture.context,
            saveContext: { _ in throw InjectedFailure.save }
        )) { error in
            XCTAssertTrue(error is InjectedFailure)
        }

        var verification = ModelContext(fixture.context.container)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<Event>()).isEmpty)
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<EventSchedule>()).isEmpty
        )

        let committedEvent = Event(name: "Committed")
        try ChekinanaEventPersistence.save(
            committedEvent,
            inserting: true,
            images: [],
            schedule: .init(openTime: "19:00", startTime: nil),
            previousAvatarRef: nil,
            in: fixture.context
        )
        verification = ModelContext(fixture.context.container)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<Event>()), 1)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<EventSchedule>()).first?.openTime,
            "19:00"
        )
    }

    func testStandaloneScheduleSetClearIsIdempotentAndPreservesCallerPendingWork() throws {
        let fixture = try makeFixture()
        let event = Event(name: "Persisted")
        fixture.context.insert(event)
        try fixture.context.save()
        let pending = Event(name: "Pending")
        fixture.context.insert(pending)

        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: "9:50",
            startTime: nil,
            in: fixture.context
        )
        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: "10:00",
            startTime: "10:30",
            in: fixture.context
        )
        XCTAssertTrue(fixture.context.hasChanges)

        var verification = ModelContext(fixture.context.container)
        XCTAssertEqual(
            try verification.fetchCount(FetchDescriptor<EventSchedule>()),
            1
        )
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<EventSchedule>()).first?.openTime,
            "10:00"
        )
        XCTAssertNil(
            try verification.fetch(FetchDescriptor<Event>())
                .first(where: { $0.id == pending.id })
        )

        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: nil,
            startTime: nil,
            in: fixture.context
        )
        verification = ModelContext(fixture.context.container)
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<EventSchedule>()).isEmpty
        )
        XCTAssertTrue(fixture.context.hasChanges)
    }

    func testExtractedEventCandidateFreezesWorkerFieldsAndConfirmsAtomicallyWithNilDate() async throws {
        let fixture = try makeFixture()
        let fields = ChekinanaEventCandidateFields(
            name: "Seven Field Live",
            date: "",
            city: "上海",
            livehouse: "新歌空间中大二号馆",
            weiboURL: "https://weibo.com/123456/AbC123",
            ticketURL: "https://tickets.showstart.com/event/42",
            openTime: "9:50",
            startTime: "14:15",
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
        XCTAssertEqual(card.openTime, "09:50")
        XCTAssertEqual(card.startTime, "14:15")
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
        XCTAssertEqual(
            try ChekinanaEventSchedulePersistence.value(for: saved.id, in: fixture.context),
            .init(openTime: "09:50", startTime: "14:15")
        )

        guard case .eventCards(let listed) = await fixture.executor.execute("listevent") else {
            return XCTFail("expected structured Event list")
        }
        XCTAssertEqual(listed.first?.city, fields.city)
        XCTAssertEqual(listed.first?.livehouse, fields.livehouse)
        XCTAssertEqual(listed.first?.ticketURL, fields.ticketURL)
        XCTAssertEqual(listed.first?.openTime, "09:50")
        XCTAssertEqual(listed.first?.startTime, "14:15")
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

    func testEventCandidatePriceLimitMatchesWorkerUTF8ByteContract() throws {
        XCTAssertEqual(
            ChekinanaEventCandidateValidator.priceMaximumUTF8ByteCount,
            2_000
        )
        var fields = ChekinanaEventCandidateFields(
            name: "Price boundary",
            date: "",
            city: "",
            livehouse: "",
            price: "",
            weiboURL: "",
            ticketURL: ""
        )

        fields.price = String(repeating: "a", count: 2_000)
        XCTAssertEqual(fields.price.utf8.count, 2_000)
        XCTAssertFalse(
            ChekinanaEventCandidateValidator.blockers(for: fields)
                .contains(where: isPriceLengthBlocker)
        )

        fields.price.append("a")
        XCTAssertEqual(fields.price.utf8.count, 2_001)
        XCTAssertTrue(
            ChekinanaEventCandidateValidator.blockers(for: fields)
                .contains(where: isPriceLengthBlocker)
        )

        fields.price = String(repeating: "价", count: 666) + "ab"
        XCTAssertEqual(fields.price.utf8.count, 2_000)
        XCTAssertFalse(
            ChekinanaEventCandidateValidator.blockers(for: fields)
                .contains(where: isPriceLengthBlocker)
        )

        fields.price = String(repeating: "价", count: 667)
        XCTAssertEqual(fields.price.utf8.count, 2_001)
        XCTAssertTrue(
            ChekinanaEventCandidateValidator.blockers(for: fields)
                .contains(where: isPriceLengthBlocker)
        )

        let fixture = try makeFixture()
        fields.price = String(repeating: "价", count: 666) + "ab"
        guard case .eventCard = fixture.executor.prepareEventCandidate(fields) else {
            return XCTFail("Assistant Prepare must accept a 2,000-byte price.")
        }
        fields.price.append("a")
        XCTAssertTrue(
            text(from: fixture.executor.prepareEventCandidate(fields)).contains("not ready"),
            "Assistant Prepare must reject a 2,001-byte price through the shared validator."
        )
    }

    private func isPriceLengthBlocker(_ blocker: ChekinanaEventCandidateBlocker) -> Bool {
        guard case .fieldTooLong(let field) = blocker else { return false }
        return field == ChekinanaL10n.text(
            "assistant.event.field.price",
            fallback: "Price"
        )
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
        try ChekinanaEventSchedulePersistence.set(
            eventID: event.id,
            openTime: "18:00",
            startTime: "18:30",
            in: fixture.context
        )

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
        XCTAssertEqual(
            try ChekinanaEventSchedulePersistence.value(for: event.id, in: fixture.context),
            .init(openTime: "18:00", startTime: "18:30")
        )
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
            "BEACH NO.11杭州（11号沙滩）",
        ]
        blocked.forEach {
            XCTAssertTrue(ChekinanaEventCandidateValidator.livehouseLooksLikeDetailedAddress($0), $0)
        }
        allowed.forEach {
            XCTAssertFalse(ChekinanaEventCandidateValidator.livehouseLooksLikeDetailedAddress($0), $0)
        }

        let structured = ChekinanaEventCandidateFields(
            name: "测试活动",
            date: "2026-08-29",
            city: "杭州",
            livehouse: "BEACH NO.11杭州（11号沙滩）",
            address: "杭州钱塘区高沙路134号",
            weiboURL: "https://weibo.com/7890706297/5293529858316367",
            ticketURL: ""
        )
        XCTAssertFalse(
            ChekinanaEventCandidateValidator.blockers(for: structured).contains(
                .livehouseLooksLikeAddress
            )
        )
        XCTAssertTrue(
            ChekinanaEventCandidateValidator.livehouseLooksLikeDetailedAddress(
                structured.address,
                separateAddress: structured.address
            )
        )
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
        patternResolve: ChekinanaCommandExecutor.PatternResolve? = nil,
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
        let schema = Schema(versionedSchema: ChekinanaSchemaV9.self)
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
            patternResolve: patternResolve,
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
        avatarURL: String? = nil,
        patternIDs: [String] = []
    ) -> ChekinanaEnrichedIdol {
        ChekinanaEnrichedIdol(
            sourceId: sourceID,
            idolName: name,
            groupName: group,
            color: "#3366CC",
            birthday: "2000-01-01",
            verification: "verified",
            bio: "catalogue bio",
            avatarUrl: avatarURL,
            patternIds: patternIDs
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

private final class ChekinanaPatternResourceMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let data = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
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

private actor ScheduleNonCooperativeTransportProbe {
    typealias Continuation = CheckedContinuation<ChekinanaScheduleHTTPResponse, Error>

    private var pending: [String: [Continuation]] = [:]
    private var waiters: [
        String: [(count: Int, continuation: CheckedContinuation<Void, Never>)]
    ] = [:]

    func response(for request: URLRequest) async throws -> ChekinanaScheduleHTTPResponse {
        let code = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value ?? ""
        return try await withCheckedThrowingContinuation { continuation in
            pending[code, default: []].append(continuation)
            resumeSatisfiedWaiters(for: code)
        }
    }

    func waitUntilPending(code: String, count: Int) async {
        guard pending[code, default: []].count < count else { return }
        await withCheckedContinuation { continuation in
            waiters[code, default: []].append((count, continuation))
        }
    }

    func resumeOldest(code: String, response: ChekinanaScheduleHTTPResponse) {
        guard var queue = pending[code], !queue.isEmpty else { return }
        let continuation = queue.removeFirst()
        pending[code] = queue
        continuation.resume(returning: response)
    }

    func resumeNewest(code: String, response: ChekinanaScheduleHTTPResponse) {
        guard var queue = pending[code], !queue.isEmpty else { return }
        let continuation = queue.removeLast()
        pending[code] = queue
        continuation.resume(returning: response)
    }

    private func resumeSatisfiedWaiters(for code: String) {
        let count = pending[code, default: []].count
        let candidates = waiters.removeValue(forKey: code) ?? []
        var remaining: [
            (count: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in candidates {
            if count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        if !remaining.isEmpty {
            waiters[code] = remaining
        }
    }
}

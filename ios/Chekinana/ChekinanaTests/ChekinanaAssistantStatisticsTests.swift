import Foundation
import XCTest
@testable import Chekinana

final class ChekinanaAssistantStatisticsTests: XCTestCase {
    private typealias Statistics = ChekinanaAssistantStatistics
    private let idolA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let idolB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let eventA = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let eventB = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    func testMixedImageAndSimpleRecordsCountSharedIdolsWithoutInflatingTotal() throws {
        let result = try Statistics.aggregate(rows: mixedRows())
        XCTAssertEqual(result.total, 7)
        XCTAssertEqual(result.withImage, 2)
        XCTAssertEqual(result.withoutImage, 5)
        XCTAssertEqual(result.byIdol, [idolA: 7, idolB: 3])
        XCTAssertNotEqual(result.total, result.byIdol.values.reduce(0, +))
    }

    func testIdolUnionCountsEveryMatchingObjectOnlyOnce() throws {
        let result = try Statistics.aggregate(
            rows: mixedRows(), query: .init(idolIDs: [idolA, idolB])
        )
        XCTAssertEqual(result.total, 7)
        XCTAssertEqual(result.byIdol, [idolA: 7, idolB: 3])

        let onlyB = try Statistics.aggregate(
            rows: mixedRows(), query: .init(idolIDs: [idolB])
        )
        XCTAssertEqual(onlyB.total, 3)
        XCTAssertEqual(onlyB.withImage, 1)
        XCTAssertEqual(onlyB.withoutImage, 2)
    }

    func testEmptyIdolSelectionMatchesNothing() throws {
        let result = try Statistics.aggregate(rows: mixedRows(), query: .init(idolIDs: []))
        XCTAssertEqual(result.total, 0)
        XCTAssertTrue(result.byIdol.isEmpty)
    }

    func testReplacingOneOfFiveSimpleChekisWithAnImagePreservesTotal() throws {
        let simpleID = UUID()
        let before = try Statistics.aggregate(rows: [
            .init(source: .simple, id: simpleID, idolIDs: [idolA], date: "2026-09-01", count: 5)
        ])
        let after = try Statistics.aggregate(rows: [
            .init(source: .simple, id: simpleID, idolIDs: [idolA], date: "2026-09-01", count: 4),
            .init(source: .media, id: UUID(), idolIDs: [idolA], date: "2026-09-01")
        ])
        XCTAssertEqual(before.total, 5)
        XCTAssertEqual(after.total, before.total)
        XCTAssertEqual(after.withImage, 1)
        XCTAssertEqual(after.withoutImage, 4)
        XCTAssertEqual(after.byIdol[idolA], 5)
    }

    func testDateRangeIncludesBothBoundaryDaysAndReportsExcludedUndatedQuantity() throws {
        let rows: [Statistics.Row] = [
            .init(source: .simple, id: UUID(), idolIDs: [idolA], date: "2026-08-31", count: 20),
            .init(source: .media, id: UUID(), idolIDs: [idolA], date: "2026-09-01"),
            .init(source: .simple, id: UUID(), idolIDs: [idolA], date: "2026-09-03", count: 2),
            .init(source: .simple, id: UUID(), idolIDs: [idolA], date: "2026-09-05", count: 3),
            .init(source: .simple, id: UUID(), idolIDs: [idolA], date: "2026-09-06", count: 40),
            .init(source: .simple, id: UUID(), idolIDs: [idolA], count: 5)
        ]
        let bounded = try Statistics.aggregate(
            rows: rows, query: .init(dateFrom: "2026-09-01", dateTo: "2026-09-05")
        )
        XCTAssertEqual(bounded.total, 6)
        XCTAssertEqual(bounded.undatedCount, 0)
        XCTAssertEqual(bounded.excludedUndatedCount, 5)
        let allTime = try Statistics.aggregate(rows: rows)
        XCTAssertEqual(allTime.total, 71)
        XCTAssertEqual(allTime.undatedCount, 5)
        XCTAssertEqual(allTime.excludedUndatedCount, 0)
        let oneDay = try Statistics.aggregate(
            rows: rows, query: .init(dateFrom: "2026-09-05", dateTo: "2026-09-05")
        )
        XCTAssertEqual(oneDay.total, 3)
    }

    func testCanonicalDayKeysDoNotShiftWithDeviceTimeZone() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let rows: [Statistics.Row] = [
            .init(source: .media, id: UUID(), idolIDs: [idolA], date: "2026-09-01"),
            .init(source: .simple, id: UUID(), idolIDs: [idolA], date: "2026-09-02", count: 8)
        ]
        for identifier in ["America/Los_Angeles", "Asia/Tokyo", "Pacific/Kiritimati"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: identifier))
            let result = try Statistics.aggregate(
                rows: rows, query: .init(dateFrom: "2026-09-01", dateTo: "2026-09-01")
            )
            XCTAssertEqual(result.total, 1, identifier)
        }
    }

    func testDateRangeRequiresBothBoundariesEvenForAnEmptySnapshot() {
        assertError(.invalidDateRange) {
            try Statistics.aggregate(rows: [], query: .init(dateFrom: "2026-09-02"))
        }
        assertError(.invalidDateRange) {
            try Statistics.aggregate(rows: [], query: .init(dateTo: "2026-09-02"))
        }
    }

    func testAnyHiddenIdolExcludesTheEntireSharedRecord() throws {
        let result = try Statistics.aggregate(rows: mixedRows(), hiddenIdolIDs: [idolB])
        XCTAssertEqual(result.total, 4)
        XCTAssertEqual(result.byIdol, [idolA: 4])
        XCTAssertEqual(result.withImage, 1)
        XCTAssertEqual(result.withoutImage, 3)
    }

    func testHiddenUndatedRecordsDoNotLeakIntoExcludedCount() throws {
        let result = try Statistics.aggregate(
            rows: [.init(source: .simple, id: UUID(), idolIDs: [idolA, idolB], count: 9)],
            hiddenIdolIDs: [idolB],
            query: .init(idolIDs: [idolA], dateFrom: "2026-09-01", dateTo: "2026-09-30")
        )
        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(result.excludedUndatedCount, 0)
        XCTAssertTrue(result.byIdol.isEmpty)
    }

    func testOtherMediaKindsAndUnpersistedDraftsAreExcluded() throws {
        let rows: [Statistics.Row] = [
            .init(source: .media, id: UUID(), kind: .cheki),
            .init(source: .media, id: UUID(), kind: .shame),
            .init(source: .media, id: UUID(), kind: .douga),
            .init(source: .media, id: UUID(), isPersisted: false),
            .init(source: .simple, id: UUID(), count: 9, isPersisted: false)
        ]
        let result = try Statistics.aggregate(rows: rows)
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.withImage, 1)
        XCTAssertEqual(result.withoutImage, 0)
    }

    func testIdenticalSnapshotObjectsAreDeduplicatedBySourceAndID() throws {
        let sharedID = UUID()
        let media = Statistics.Row(source: .media, id: sharedID, idolIDs: [idolA])
        let simple = Statistics.Row(source: .simple, id: sharedID, idolIDs: [idolA], count: 3)
        let result = try Statistics.aggregate(rows: [media, simple, media, simple])
        XCTAssertEqual(result.total, 4, "The two stores have distinct identity namespaces")
        XCTAssertEqual(result.byIdol[idolA], 4)
    }

    func testConflictingSnapshotsOfOneObjectFailInsteadOfChoosingAnArbitraryCount() {
        let id = UUID()
        assertError(.conflictingDuplicate) {
            try Statistics.aggregate(rows: [
                .init(source: .simple, id: id, count: 1),
                .init(source: .simple, id: id, count: 2)
            ])
        }
    }

    func testEventAndIdolFiltersIntersectAndMissingMetadataIsExplained() throws {
        let rows: [Statistics.Row] = [
            .init(source: .simple, id: UUID(), idolIDs: [idolA], eventID: eventA, count: 3),
            .init(source: .simple, id: UUID(), idolIDs: [idolB], eventID: eventA, count: 5),
            .init(source: .simple, id: UUID(), idolIDs: [idolA], eventID: eventB, count: 7),
            .init(source: .simple, id: UUID(), date: "2026-09-01", eventID: eventA, count: 2)
        ]
        let selected = try Statistics.aggregate(
            rows: rows, query: .init(idolIDs: [idolA], eventID: eventA)
        )
        XCTAssertEqual(selected.total, 3)
        XCTAssertEqual(selected.undatedCount, 3)
        XCTAssertEqual(selected.unassociatedCount, 0)
        let event = try Statistics.aggregate(rows: rows, query: .init(eventID: eventA))
        XCTAssertEqual(event.total, 10)
        XCTAssertEqual(event.undatedCount, 8)
        XCTAssertEqual(event.unassociatedCount, 2)
        let datedEvent = try Statistics.aggregate(
            rows: rows,
            query: .init(idolIDs: [idolA], eventID: eventA, dateFrom: "2026-09-01", dateTo: "2026-09-30")
        )
        XCTAssertEqual(datedEvent.total, 0)
        XCTAssertEqual(datedEvent.excludedUndatedCount, 3)
    }

    func testInvalidAndReversedQueryDatesFailEvenForAnEmptySnapshot() {
        for invalid in ["", "2026-9-01", "2026-02-29", "1900-02-29", "0000-01-01", "2026-13-01", "2026-09-31", "２０２６-09-01"] {
            assertError(.invalidQueryDate) {
                try Statistics.aggregate(rows: [], query: .init(dateFrom: invalid, dateTo: "2026-09-30"))
            }
        }
        assertError(.invalidDateRange) {
            try Statistics.aggregate(rows: [], query: .init(dateFrom: "2026-09-02", dateTo: "2026-09-01"))
        }
    }

    func testGregorianLeapDayIsAcceptedAndInvalidRecordDatesFail() throws {
        let result = try Statistics.aggregate(
            rows: [.init(source: .media, id: UUID(), date: "2000-02-29")],
            query: .init(dateFrom: "2000-02-29", dateTo: "2000-02-29")
        )
        XCTAssertEqual(result.total, 1)
        assertError(.invalidRecordDate) {
            try Statistics.aggregate(rows: [.init(source: .media, id: UUID(), date: "2026-02-30")])
        }
    }

    func testInvalidSimpleCountsFailWhileMediaAlwaysCountsOneObject() throws {
        for count in [0, -1] {
            assertError(.invalidCount) {
                try Statistics.aggregate(rows: [.init(source: .simple, id: UUID(), count: count)])
            }
        }
        let media = try Statistics.aggregate(rows: [.init(source: .media, id: UUID(), count: Int.max)])
        XCTAssertEqual(media.total, 1)
    }

    func testTotalOverflowFailsExplicitly() {
        assertError(.overflow) {
            try Statistics.aggregate(rows: [
                .init(source: .simple, id: UUID(), idolIDs: [idolA], count: Int.max),
                .init(source: .media, id: UUID(), idolIDs: [idolB])
            ])
        }
    }

    func testExcludedUndatedQuantityOverflowAlsoFailsExplicitly() {
        assertError(.overflow) {
            try Statistics.aggregate(
                rows: [
                    .init(source: .simple, id: UUID(), count: Int.max),
                    .init(source: .media, id: UUID())
                ],
                query: .init(dateFrom: "2026-09-01", dateTo: "2026-09-30")
            )
        }
    }

    private func mixedRows() -> [Statistics.Row] {
        [
            .init(source: .media, id: UUID(), idolIDs: [idolA], date: "2026-09-01"),
            .init(source: .media, id: UUID(), idolIDs: [idolA, idolB], date: "2026-09-01"),
            .init(source: .simple, id: UUID(), idolIDs: [idolA], date: "2026-09-01", count: 3),
            .init(source: .simple, id: UUID(), idolIDs: [idolA, idolB], date: "2026-09-01", count: 2)
        ]
    }

    private func assertError(
        _ expected: Statistics.StatisticsError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Statistics.Result
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? Statistics.StatisticsError, expected, file: file, line: line)
        }
    }
}

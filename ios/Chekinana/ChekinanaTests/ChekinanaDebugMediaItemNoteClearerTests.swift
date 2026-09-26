import SwiftData
import XCTest
@testable import Chekinana

final class ChekinanaDebugMediaItemNoteClearerTests: XCTestCase {
    @MainActor
    func testFlaggedClearOnlyErasesMediaItemNotesAndIsIdempotent() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                ),
            ]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let idol = Idol(name: "Cleanup Fixture Idol")
        let event = Event(name: "Cleanup Fixture Event")
        context.insert(idol)
        context.insert(event)

        let mediaID = UUID()
        let mediaOwnerID = UUID()
        let date = Date(timeIntervalSince1970: 1_725_000_000)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let cheki = MediaItem(
            id: mediaID,
            mediaOwnerID: mediaOwnerID,
            kind: .cheki,
            idols: [idol],
            event: event,
            date: date,
            idx: -17,
            userAppears: true,
            size: .wide,
            mediaRef: "fixture-cheki.jpg",
            isFavorite: true,
            hasPostedToSNS: true,
            note: "erase cheki note",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let shame = MediaItem(
            kind: .shame,
            idols: [idol],
            event: event,
            date: date,
            userAppears: true,
            mediaRef: "fixture-shame.jpg",
            note: ""
        )
        let douga = MediaItem(
            kind: .douga,
            idols: [idol],
            event: event,
            date: date,
            mediaRef: "fixture-douga.mov",
            note: "erase douga note"
        )
        let record = ChekiRecord(
            idols: [idol],
            event: event,
            date: date,
            size: .mini,
            note: "preserve record note",
            count: 4
        )
        context.insert(cheki)
        context.insert(shame)
        context.insert(douga)
        context.insert(record)
        try context.save()

        XCTAssertEqual(
            try ChekinanaDebugMediaItemNoteClearer.clearIfRequested(
                in: context,
                environment: [:]
            ),
            0
        )
        XCTAssertEqual(cheki.note, "erase cheki note")
        XCTAssertEqual(douga.note, "erase douga note")

        let enabledEnvironment = [
            ChekinanaDebugMediaItemNoteClearer.environmentKey: "1",
        ]
        XCTAssertEqual(
            try ChekinanaDebugMediaItemNoteClearer.clearIfRequested(
                in: context,
                environment: enabledEnvironment
            ),
            2
        )

        let verification = ModelContext(container)
        let savedMedia = try verification.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(savedMedia.count, 3)
        XCTAssertTrue(savedMedia.allSatisfy { $0.note.isEmpty })

        let savedCheki = try XCTUnwrap(savedMedia.first { $0.id == mediaID })
        XCTAssertEqual(savedCheki.mediaOwnerID, mediaOwnerID)
        XCTAssertEqual(savedCheki.kind, .cheki)
        XCTAssertEqual(savedCheki.idolIDs, [idol.id])
        XCTAssertEqual(savedCheki.eventID, event.id)
        XCTAssertEqual(savedCheki.date, date)
        XCTAssertTrue(savedCheki.userAppears)
        XCTAssertTrue(savedCheki.isFavorite)
        XCTAssertTrue(savedCheki.hasPostedToSNS)
        XCTAssertEqual(savedCheki.mediaRef, "fixture-cheki.jpg")
        XCTAssertEqual(savedCheki.sizeRawValue, ChekiSize.wide.rawValue)
        XCTAssertEqual(savedCheki.idx, -17)
        XCTAssertEqual(savedCheki.createdAt, createdAt)
        XCTAssertEqual(savedCheki.updatedAt, updatedAt)

        let savedRecord = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<ChekiRecord>()).first
        )
        XCTAssertEqual(savedRecord.note, "preserve record note")
        XCTAssertEqual(savedRecord.idolIDs, [idol.id])
        XCTAssertEqual(savedRecord.eventID, event.id)
        XCTAssertEqual(savedRecord.date, date)
        XCTAssertEqual(savedRecord.sizeRawValue, ChekiSize.mini.rawValue)
        XCTAssertEqual(savedRecord.count, 4)

        XCTAssertEqual(
            try ChekinanaDebugMediaItemNoteClearer.clearIfRequested(
                in: verification,
                environment: enabledEnvironment
            ),
            0
        )
    }

    @MainActor
    func testRecordCleanupPreservesSixRecordsAndEveryOtherBusinessField() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let idol = Idol(name: "Record Cleanup Idol")
        let event = Event(name: "Record Cleanup Event")
        context.insert(idol)
        context.insert(event)
        let records = (0..<9).map { index in
            ChekiRecord(
                idols: [idol], event: event,
                date: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                size: .wide, note: index == 8 ? "" : "note \(index)", count: index + 1
            )
        }
        records.forEach { context.insert($0) }
        for kind in [MediaItemKind.cheki, .shame, .douga] {
            context.insert(MediaItem(kind: kind, mediaRef: "fixture", note: "preserve media note"))
        }
        try context.save()
        let preserved = Array(records.prefix(6))
        let ids = preserved.map { $0.id.uuidString }.joined(separator: ",")
        let enabled = [
            ChekinanaDebugMediaItemNoteClearer.recordEnvironmentKey: "1",
            ChekinanaDebugMediaItemNoteClearer.preservedRecordIDsEnvironmentKey: ids,
        ]
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.clearRecordNotesIfRequested(
            in: container, environment: [:]
        ), 0)

        // Invalid, duplicate, undersized, and missing-preserved-record inputs
        // must all fail before clearing any record or MediaItem.
        for invalid in ["", "invalid," + ids, ids + "," + UUID().uuidString,
                        Array(repeating: preserved[0].id.uuidString, count: 6).joined(separator: ","),
                        preserved.prefix(5).map { $0.id.uuidString }.joined(separator: ","),
                        preserved.prefix(5).map { $0.id.uuidString }.joined(separator: ",") + "," + UUID().uuidString] {
            var environment = enabled
            environment[ChekinanaDebugMediaItemNoteClearer.preservedRecordIDsEnvironmentKey] = invalid
            XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.clearRecordNotesIfRequested(
                in: container, environment: environment
            ))
        }
        var conflicting = enabled
        conflicting[ChekinanaDebugMediaItemNoteClearer.environmentKey] = "1"
        XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.clearRecordNotesIfRequested(
            in: container, environment: conflicting
        ))
        XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.clearIfRequested(
            in: context, environment: conflicting
        ))
        let before = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(before.filter { !$0.note.isEmpty }.count, 8)

        // An unsaved edit in another context must not be persisted by cleanup.
        event.name = "Pending unrelated edit"
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.clearRecordNotesIfRequested(
            in: container, environment: enabled
        ), 2)
        let verification = ModelContext(container)
        let saved = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(saved.count, records.count)
        for (index, original) in records.enumerated() {
            let record = try XCTUnwrap(saved.first { $0.id == original.id })
            XCTAssertEqual(record.note, index < 6 ? "note \(index)" : "")
            XCTAssertEqual(record.idolIDs, original.idolIDs)
            XCTAssertEqual(record.eventID, original.eventID)
            XCTAssertEqual(record.date, original.date)
            XCTAssertEqual(record.sizeRawValue, original.sizeRawValue)
            XCTAssertEqual(record.count, original.count)
        }
        let media = try verification.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(media.count, 3)
        XCTAssertTrue(media.allSatisfy { $0.note == "preserve media note" })
        XCTAssertEqual(try verification.fetch(FetchDescriptor<Event>()).first?.name, "Record Cleanup Event")
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.clearRecordNotesIfRequested(
            in: container, environment: enabled
        ), 0)
    }

}

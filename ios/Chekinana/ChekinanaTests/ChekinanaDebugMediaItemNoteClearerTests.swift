import SwiftData
import XCTest
@testable import Chekinana

final class ChekinanaDebugMediaItemNoteClearerTests: XCTestCase {
    @MainActor
    func testIdolNameSpacesPreflightAndOnlyNameChanges() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let idol = Idol(sourceId: "fixture-source", name: " Alpha  Beta ", group: "Keep Group",
                        color: "red", birthday: "01-01", avatarImageRef: "fixture-avatar",
                        isFavorite: true, sortOrder: 7, note: "keep note", createdAt: stamp,
                        updatedAt: stamp, verification: "verified", bio: "keep bio", patterns: [[1, 2]])
        idol.pattern = [3, 4]
        let second = Idol(name: "Gamma Delta")
        let untouched = Idol(name: "Unselected Name")
        let event = Event(name: "Keep Event")
        let media = MediaItem(kind: .cheki, idols: [idol], event: event, mediaRef: "fixture", note: "keep media")
        let record = ChekiRecord(idols: [idol], event: event, note: "keep record", count: 3)
        context.insert(idol)
        context.insert(second)
        context.insert(untouched)
        context.insert(event)
        context.insert(media)
        context.insert(record)
        try context.save()
        func environment(_ rows: [[String: String]]) throws -> [String: String] {
            [ChekinanaDebugMediaItemNoteClearer.idolNameSpacesEnvironmentKey: "1",
             ChekinanaDebugMediaItemNoteClearer.idolNameSpacesPayloadEnvironmentKey:
                String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!]
        }
        let first = ["id": idol.id.uuidString, "expectedName": idol.name]
        let next = ["id": second.id.uuidString, "expectedName": second.name]
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.removeIdolNameSpacesIfRequested(in: container, environment: [:]), 0)
        for rows in [[], [first, first], [first, ["id": UUID().uuidString, "expectedName": "Missing Name"]],
                     [first, ["id": second.id.uuidString, "expectedName": "Changed Name"]]] {
            XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.removeIdolNameSpacesIfRequested(in: container, environment: environment(rows)))
            let check = ModelContext(container)
            XCTAssertEqual(try check.fetch(FetchDescriptor<Idol>()).first { $0.id == idol.id }?.name, " Alpha  Beta ")
        }
        for flag in [ChekinanaDebugMediaItemNoteClearer.environmentKey,
                     ChekinanaDebugMediaItemNoteClearer.recordEnvironmentKey,
                     ChekinanaDebugMediaItemNoteClearer.eventCityEnvironmentKey,
                     ChekinanaDebugMediaItemNoteClearer.eventInsertEnvironmentKey,
                     ChekinanaDebugMediaItemNoteClearer.eventDateRepairEnvironmentKey,
                     "CHEKINANA_UI_RESET_STORE", "CHEKINANA_UI_TEST_STORE"] {
            var conflicting = try environment([first, next])
            conflicting[flag] = "1"
            XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.removeIdolNameSpacesIfRequested(in: container, environment: conflicting))
        }
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.removeIdolNameSpacesIfRequested(in: container, environment: environment([first, next])), 2)
        let check = ModelContext(container)
        let idols = try check.fetch(FetchDescriptor<Idol>())
        XCTAssertEqual(Set(idols.map(\.id)), Set([idol.id, second.id, untouched.id]))
        let saved = try XCTUnwrap(idols.first { $0.id == idol.id })
        XCTAssertEqual(saved.name, "AlphaBeta")
        XCTAssertEqual(idols.first { $0.id == second.id }?.name, "GammaDelta")
        XCTAssertEqual(idols.first { $0.id == untouched.id }?.name, "Unselected Name")
        XCTAssertEqual(saved.sourceId, "fixture-source")
        XCTAssertEqual(saved.group, "Keep Group")
        XCTAssertEqual(saved.color, "red")
        XCTAssertEqual(saved.birthday, "01-01")
        XCTAssertEqual(saved.avatarImageRef, "fixture-avatar")
        XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(saved.sortOrder, 7)
        XCTAssertEqual(saved.note, "keep note")
        XCTAssertEqual(saved.createdAt, stamp)
        XCTAssertEqual(saved.updatedAt, stamp)
        XCTAssertEqual(saved.verification, "verified")
        XCTAssertEqual(saved.bio, "keep bio")
        XCTAssertEqual(saved.pattern, [3, 4])
        XCTAssertEqual(saved.patterns, [[1, 2]])
        let events = try check.fetch(FetchDescriptor<Event>())
        XCTAssertEqual(events.map(\.id), [event.id])
        XCTAssertEqual(events.first?.name, "Keep Event")
        let items = try check.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.map(\.id), [media.id])
        XCTAssertEqual(items.first?.note, "keep media")
        XCTAssertEqual(items.first?.idols.map(\.id), [idol.id])
        XCTAssertEqual(items.first?.event?.id, event.id)
        let records = try check.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.map(\.id), [record.id])
        XCTAssertEqual(records.first?.note, "keep record")
        XCTAssertEqual(records.first?.count, 3)
        XCTAssertEqual(records.first?.idols.map(\.id), [idol.id])
        XCTAssertEqual(records.first?.event?.id, event.id)
    }

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

    @MainActor
    func testEventCityUpdateOnlyRemovesOneTrailingCharacterFromExactTargets() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let cities: [String?] = ["上海市", "市中市市", "杭州市", "市中", "上海市 ", nil, ""]
        let events = cities.enumerated().map { index, city in
            Event(name: "Event \(index)", date: stamp, city: city, livehouse: "Venue",
                  avatarImageRef: "fixture.jpg", price: "100", note: "keep note",
                  createdAt: stamp, updatedAt: stamp)
        }
        events.forEach { context.insert($0) }
        let media = MediaItem(kind: .cheki, mediaRef: "fixture.jpg", note: "media note")
        let record = ChekiRecord(note: "record note", count: 3)
        context.insert(media)
        context.insert(record)
        try context.save()
        let targets = [events[0].id.uuidString: "上海市", events[1].id.uuidString: "市中市市"]
        func environment(_ values: [String: String]) throws -> [String: String] {
            [ChekinanaDebugMediaItemNoteClearer.eventCityEnvironmentKey: "1",
             ChekinanaDebugMediaItemNoteClearer.eventCityTargetsEnvironmentKey:
                String(decoding: try JSONEncoder().encode(values), as: UTF8.self)]
        }
        let enabled = try environment(targets)
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.trimEventCitiesIfRequested(
            in: container, environment: [:]
        ), 0)

        // Every malformed or stale target set must fail without partial writes.
        for invalid in [[:], ["bad-uuid": "上海市"],
                        [events[0].id.uuidString: "上海"],
                        [events[0].id.uuidString: "上海市", UUID().uuidString: "杭州市"],
                        [events[0].id.uuidString: "上海市", events[1].id.uuidString: "杭州市"]] {
            XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.trimEventCitiesIfRequested(
                in: container, environment: environment(invalid)
            ))
            let unchanged = try ModelContext(container).fetch(FetchDescriptor<Event>())
            for event in unchanged {
                let index = try XCTUnwrap(events.firstIndex { $0.id == event.id })
                XCTAssertEqual(event.city, cities[index])
            }
        }
        for noteFlag in [ChekinanaDebugMediaItemNoteClearer.environmentKey,
                         ChekinanaDebugMediaItemNoteClearer.recordEnvironmentKey] {
            var conflicting = enabled
            conflicting[noteFlag] = "1"
            XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.trimEventCitiesIfRequested(
                in: container, environment: conflicting
            ))
        }
        events[2].name = "Unsaved unrelated change"
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.trimEventCitiesIfRequested(
            in: container, environment: enabled
        ), 2)
        let verification = ModelContext(container)
        let saved = try verification.fetch(FetchDescriptor<Event>())
        XCTAssertEqual(saved.count, events.count)
        for event in saved {
            let index = try XCTUnwrap(events.firstIndex { $0.id == event.id })
            XCTAssertEqual(event.city, index == 0 ? "上海" : index == 1 ? "市中市" : cities[index])
            XCTAssertEqual(event.name, "Event \(index)")
            XCTAssertEqual(event.note, "keep note")
            XCTAssertEqual(event.date, stamp)
            XCTAssertEqual(event.createdAt, stamp)
            XCTAssertEqual(event.updatedAt, stamp)
            XCTAssertEqual(event.livehouse, "Venue")
            XCTAssertEqual(event.avatarImageRef, "fixture.jpg")
            XCTAssertEqual(event.price, "100")
            XCTAssertNil(event.legacyVenue)
            XCTAssertNil(event.weiboURL)
            XCTAssertNil(event.ticketURL)
            XCTAssertNil(event.sourceRawValue)
        }
        XCTAssertEqual(try verification.fetch(FetchDescriptor<MediaItem>()).map(\.note), ["media note"])
        XCTAssertEqual(try verification.fetch(FetchDescriptor<ChekiRecord>()).map(\.note), ["record note"])
        // Replaying the stale request fails closed, so a second trailing 市 is not removed.
        XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.trimEventCitiesIfRequested(
            in: container, environment: enabled
        ))
    }

    @MainActor
    func testInsertEventsIsInsertOnlyAndPreservesIntentionalDuplicates() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let old = Event(name: "Existing", date: stamp, city: "City", livehouse: "Venue",
                        avatarImageRef: "avatar", price: "100", note: "keep",
                        createdAt: stamp, updatedAt: stamp)
        old.legacyVenue = "legacy"
        old.weiboURL = URL(string: "https://example.com/weibo")
        old.ticketURL = URL(string: "https://example.com/ticket")
        old.sourceRawValue = "fixture"
        let media = MediaItem(kind: .cheki, event: old, date: stamp, mediaRef: "fixture", note: "media")
        let record = ChekiRecord(event: old, date: stamp, note: "record", count: 2)
        context.insert(old)
        context.insert(media)
        context.insert(record)
        try context.save()
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let first = ["id": firstID, "name": "Duplicate", "date": "2025-08-29", "city": "大阪", "livehouse": "BIGCAT"]
        var second = first
        second["id"] = secondID
        func environment(_ rows: [[String: String]]) throws -> [String: String] {
            [ChekinanaDebugMediaItemNoteClearer.eventInsertEnvironmentKey: "1",
             ChekinanaDebugMediaItemNoteClearer.eventInsertPayloadEnvironmentKey:
                String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)]
        }
        let enabled = try environment([first, second])
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.insertEventsIfRequested(in: container, environment: [:]), 0)
        var collision = second
        collision["id"] = old.id.uuidString
        var invalidDate = second
        invalidDate["date"] = "2025-02-29"
        var missingField = second
        missingField.removeValue(forKey: "livehouse")
        var invalidID = second
        invalidID["id"] = "invalid"
        for rows in [[], [first, first], [first, collision], [first, invalidDate], [first, missingField], [first, invalidID]] {
            XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.insertEventsIfRequested(
                in: container, environment: environment(rows)))
            XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Event>()), 1)
        }
        for flag in [ChekinanaDebugMediaItemNoteClearer.environmentKey,
                     ChekinanaDebugMediaItemNoteClearer.recordEnvironmentKey,
                     ChekinanaDebugMediaItemNoteClearer.eventCityEnvironmentKey,
                     "CHEKINANA_UI_RESET_STORE", "CHEKINANA_UI_TEST_STORE"] {
            var conflicting = enabled
            conflicting[flag] = "1"
            XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.insertEventsIfRequested(in: container, environment: conflicting))
            XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Event>()), 1)
        }
        old.name = "Unsaved unrelated edit"
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.insertEventsIfRequested(in: container, environment: enabled), 2)
        let verification = ModelContext(container)
        let saved = try verification.fetch(FetchDescriptor<Event>())
        XCTAssertEqual(saved.count, 3)
        let added = saved.filter { $0.id != old.id }
        XCTAssertEqual(Set(added.map { $0.id.uuidString }), Set([firstID, secondID]))
        for event in added {
            XCTAssertEqual(event.name, "Duplicate")
            XCTAssertEqual(event.date, ChekinanaDateOnly.parse("2025-08-29"))
            XCTAssertEqual(event.city, "大阪")
            XCTAssertEqual(event.livehouse, "BIGCAT")
            XCTAssertEqual(event.note, "")
            XCTAssertNil(event.legacyVenue)
            XCTAssertNil(event.avatarImageRef)
            XCTAssertNil(event.price)
            XCTAssertNil(event.weiboURL)
            XCTAssertNil(event.sourceRawValue)
            XCTAssertNil(event.ticketURL)
        }
        let preserved = try XCTUnwrap(saved.first { $0.id == old.id })
        XCTAssertEqual(preserved.name, "Existing")
        XCTAssertEqual(preserved.date, stamp)
        XCTAssertEqual(preserved.city, "City")
        XCTAssertEqual(preserved.livehouse, "Venue")
        XCTAssertEqual(preserved.note, "keep")
        XCTAssertEqual(preserved.createdAt, stamp)
        XCTAssertEqual(preserved.updatedAt, stamp)
        XCTAssertEqual(preserved.avatarImageRef, "avatar")
        XCTAssertEqual(preserved.price, "100")
        XCTAssertEqual(preserved.legacyVenue, "legacy")
        XCTAssertEqual(preserved.weiboURL, old.weiboURL)
        XCTAssertEqual(preserved.ticketURL, old.ticketURL)
        XCTAssertEqual(preserved.sourceRawValue, "fixture")
        let savedMedia = try verification.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(savedMedia.count, 1)
        XCTAssertEqual(savedMedia.first?.id, media.id)
        XCTAssertEqual(savedMedia.first?.note, "media")
        XCTAssertEqual(savedMedia.first?.eventID, old.id)
        XCTAssertEqual(savedMedia.first?.date, stamp)
        let savedRecords = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(savedRecords.count, 1)
        XCTAssertEqual(savedRecords.first?.id, record.id)
        XCTAssertEqual(savedRecords.first?.note, "record")
        XCTAssertEqual(savedRecords.first?.eventID, old.id)
        XCTAssertEqual(savedRecords.first?.date, stamp)
        XCTAssertEqual(savedRecords.first?.count, 2)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<EventImage>()), 0)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<EventSchedule>()), 0)
        XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.insertEventsIfRequested(in: container, environment: enabled))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Event>()), 3)
    }

    @MainActor
    func testDateRepairUsesExistingDateOnlyContractAndChangesOnlyExactTargetDates() throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let target = try XCTUnwrap(ChekinanaDateOnly.parse("2025-08-29"))
        let oldDate = target.addingTimeInterval(-8 * 3600)
        XCTAssertEqual(ChekinanaDateOnly.string(oldDate), "2025-08-28")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let event = Event(name: "Duplicate", date: oldDate, city: "大阪", livehouse: "BIGCAT",
                          avatarImageRef: "avatar", price: "100", note: "keep",
                          createdAt: stamp, updatedAt: stamp)
        event.legacyVenue = "legacy"
        event.weiboURL = URL(string: "https://example.com/weibo")
        event.ticketURL = URL(string: "https://example.com/ticket")
        event.sourceRawValue = "fixture"
        let untouched = Event(name: "Duplicate", date: oldDate, city: "大阪", livehouse: "BIGCAT")
        context.insert(event)
        context.insert(untouched)
        let media = MediaItem(kind: .cheki, event: event, date: oldDate, mediaRef: "fixture", note: "media")
        let record = ChekiRecord(event: event, date: oldDate, note: "record", count: 2)
        context.insert(media)
        context.insert(record)
        try context.save()
        let row: [String: Any] = ["id": event.id.uuidString, "date": "2025-08-29",
                                   "expectedOldReferenceSeconds": oldDate.timeIntervalSinceReferenceDate]
        func environment(_ rows: [[String: Any]]) throws -> [String: String] {
            [ChekinanaDebugMediaItemNoteClearer.eventDateRepairEnvironmentKey: "1",
             ChekinanaDebugMediaItemNoteClearer.eventDateRepairPayloadEnvironmentKey:
                String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)]
        }
        let enabled = try environment([row])
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.repairEventDatesIfRequested(in: container, environment: [:]), 0)
        var missing = row
        missing["id"] = UUID().uuidString
        var stale = row
        stale["id"] = untouched.id.uuidString
        stale["expectedOldReferenceSeconds"] = 1
        var invalid = row
        invalid["date"] = "2025-02-29"
        for rows in [[], [row, row], [row, missing], [row, stale], [invalid]] {
            XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.repairEventDatesIfRequested(in: container, environment: environment(rows)))
            let saved = try ModelContext(container).fetch(FetchDescriptor<Event>())
            XCTAssertEqual(saved.count, 2)
            XCTAssertTrue(saved.allSatisfy { $0.date == oldDate })
        }
        for flag in [ChekinanaDebugMediaItemNoteClearer.environmentKey,
                     ChekinanaDebugMediaItemNoteClearer.recordEnvironmentKey,
                     ChekinanaDebugMediaItemNoteClearer.eventCityEnvironmentKey,
                     ChekinanaDebugMediaItemNoteClearer.eventInsertEnvironmentKey,
                     "CHEKINANA_UI_RESET_STORE", "CHEKINANA_UI_TEST_STORE"] {
            var conflicting = enabled
            conflicting[flag] = "1"
            XCTAssertThrowsError(try ChekinanaDebugMediaItemNoteClearer.repairEventDatesIfRequested(in: container, environment: conflicting))
        }
        untouched.name = "Unsaved unrelated edit"
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.repairEventDatesIfRequested(in: container, environment: enabled), 1)
        let verification = ModelContext(container)
        let saved = try verification.fetch(FetchDescriptor<Event>())
        XCTAssertEqual(saved.count, 2)
        let repaired = try XCTUnwrap(saved.first { $0.id == event.id })
        XCTAssertEqual(repaired.date, target)
        XCTAssertEqual(repaired.name, "Duplicate")
        XCTAssertEqual(repaired.city, "大阪")
        XCTAssertEqual(repaired.livehouse, "BIGCAT")
        XCTAssertEqual(repaired.note, "keep")
        XCTAssertEqual(repaired.createdAt, stamp)
        XCTAssertEqual(repaired.updatedAt, stamp)
        XCTAssertEqual(repaired.avatarImageRef, "avatar")
        XCTAssertEqual(repaired.price, "100")
        XCTAssertEqual(repaired.legacyVenue, "legacy")
        XCTAssertEqual(repaired.weiboURL, event.weiboURL)
        XCTAssertEqual(repaired.ticketURL, event.ticketURL)
        XCTAssertEqual(repaired.sourceRawValue, "fixture")
        let preserved = try XCTUnwrap(saved.first { $0.id == untouched.id })
        XCTAssertEqual(preserved.name, "Duplicate")
        XCTAssertEqual(preserved.date, oldDate)
        XCTAssertEqual(preserved.city, "大阪")
        XCTAssertEqual(preserved.livehouse, "BIGCAT")
        XCTAssertEqual(preserved.note, "")
        XCTAssertEqual(preserved.createdAt, untouched.createdAt)
        XCTAssertEqual(preserved.updatedAt, untouched.updatedAt)
        let savedMedia = try verification.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(savedMedia.count, 1)
        XCTAssertEqual(savedMedia.first?.id, media.id)
        XCTAssertEqual(savedMedia.first?.note, "media")
        XCTAssertEqual(savedMedia.first?.eventID, event.id)
        XCTAssertEqual(savedMedia.first?.date, oldDate)
        let savedRecords = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(savedRecords.count, 1)
        XCTAssertEqual(savedRecords.first?.id, record.id)
        XCTAssertEqual(savedRecords.first?.note, "record")
        XCTAssertEqual(savedRecords.first?.eventID, event.id)
        XCTAssertEqual(savedRecords.first?.date, oldDate)
        XCTAssertEqual(savedRecords.first?.count, 2)
        XCTAssertEqual(try ChekinanaDebugMediaItemNoteClearer.repairEventDatesIfRequested(in: container, environment: enabled), 0)
        // Exercise the same display projection used by app UI, including negative offsets.
        for zone in ["Asia/Shanghai", "Asia/Tokyo", "America/Los_Angeles"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let shown = try XCTUnwrap(ChekinanaDateOnly.displayDate(from: target, calendar: calendar))
            let parts = calendar.dateComponents([.year, .month, .day], from: shown)
            XCTAssertEqual(parts.year, 2025)
            XCTAssertEqual(parts.month, 8)
            XCTAssertEqual(parts.day, 29)
            XCTAssertEqual(ChekinanaDateOnly.string(target), "2025-08-29")
        }
    }

}

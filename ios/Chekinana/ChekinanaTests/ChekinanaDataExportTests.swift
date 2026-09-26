import Foundation
import CoreData
import SwiftData
import XCTest
@testable import Chekinana

private enum ChekinanaV14ToV15MemoryTestMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ChekinanaSchemaV14.self, ChekinanaSchemaV15.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ChekinanaSchemaV14.self, toVersion: ChekinanaSchemaV15.self)]
    }
}

/// Reproduces a shipped V14-family store whose identifier was reused after an
/// additive model change. Its entity hashes intentionally differ from the
/// current V14 snapshot while every retained entity uses the production model.
private enum ChekinanaHistoricalV14DriftFixtureSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(14, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventSchedule.self,
            EventImage.self,
            TravelSegment.self,
            MediaItem.self,
            ChekiRecord.self,
        ]
    }
}

private enum ChekinanaMemoryCommitterTestError: Error {
    case databaseSave
    case cleanup
}

final class ChekinanaDataExportTests: XCTestCase {
    @MainActor
    func testLegacyDefaultAndInvalidSizesUseConstructedRecordIdentity() throws {
        for version in [7, 8, 13] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "legacy-default-size-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = root.appendingPathComponent("isolated.store")
            try autoreleasepool {
                let schema: Schema
                switch version {
                case 7: schema = Schema(versionedSchema: ChekinanaSchemaV7.self)
                case 8: schema = Schema(versionedSchema: ChekinanaSchemaV8.self)
                default: schema = Schema(versionedSchema: ChekinanaSchemaV13.self)
                }
                let source = try ModelContainer(for: schema, configurations: [ModelConfiguration(
                    "DefaultSizeFixture", schema: schema, url: store, cloudKitDatabase: .none
                )])
                let context = ModelContext(source)
                context.autosaveEnabled = false
                let idol = ChekinanaLegacyMediaSchema.Idol(name: "Fixture Idol")
                context.insert(idol)
                for (note, size) in [("default", Optional<String>.none),
                                     ("invalid", Optional("historical-invalid")), ("wide", Optional("wide"))] {
                    let media = ChekinanaLegacyMediaSchema.Cheki()
                    media.idols = [idol]; media.note = note; media.imageRef = "opaque-\(note).jpg"
                    if let size { media.sizeRawValue = size }
                    else { XCTAssertNil(media.sizeRawValue) }
                    context.insert(media)
                }
                let noMedia = ChekinanaLegacyMediaSchema.Cheki()
                noMedia.idols = [idol]; noMedia.note = "merged"
                XCTAssertNil(noMedia.imageRef)
                XCTAssertNil(noMedia.sizeRawValue)
                context.insert(noMedia)
                let nilRecord = ChekiRecord(note: "merged", count: 2)
                nilRecord.idolIDs = [idol.id]; nilRecord.sizeRawValue = nil
                let miniRecord = ChekiRecord(size: .mini, note: "merged", count: 3)
                miniRecord.idolIDs = [idol.id]
                context.insert(nilRecord); context.insert(miniRecord)
                try context.save()
            }
            let migrated: ModelContainer
            if let legacyVersion = ChekinanaDataStore.PhysicalStoreVersion(rawValue: version), version < 13 {
                migrated = try ChekinanaDataStore.legacyMediaContainer(
                    at: store, sourceVersion: legacyVersion, configurationName: "DefaultSizeFixture"
                )
            } else {
                let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
                migrated = try ModelContainer(for: schema, migrationPlan: ChekinanaSchemaMigrationPlan.self,
                    configurations: [ModelConfiguration("DefaultSizeFixture", schema: schema, url: store, cloudKitDatabase: .none)])
            }
            let context = ModelContext(migrated)
            let media = try context.fetch(FetchDescriptor<MediaItem>())
            XCTAssertEqual(media.first { $0.note == "default" }?.sizeRawValue, "mini")
            XCTAssertEqual(media.first { $0.note == "invalid" }?.sizeRawValue, "mini")
            XCTAssertEqual(media.first { $0.note == "wide" }?.sizeRawValue, "wide")
            let records = try context.fetch(FetchDescriptor<ChekiRecord>())
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.sizeRawValue, "mini")
            XCTAssertEqual(records.first?.count, 6)
        }
    }

    @MainActor
    func testLegacyV7AndV8BridgePreservesMediaAndIndependentLargeQuantities() throws {
        for version in [ChekinanaDataStore.PhysicalStoreVersion.v7, .v8] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "legacy-media-bridge-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = root.appendingPathComponent("isolated.store")
            let idolID = UUID()
            let eventID = UUID()
            let mediaID = UUID()
            try autoreleasepool {
                let schema = version == .v7
                    ? Schema(versionedSchema: ChekinanaSchemaV7.self)
                    : Schema(versionedSchema: ChekinanaSchemaV8.self)
                let source = try ModelContainer(for: schema, configurations: [ModelConfiguration(
                    "LegacyMediaFixture", schema: schema, url: store, cloudKitDatabase: .none
                )])
                let context = ModelContext(source)
                context.autosaveEnabled = false
                let idol = ChekinanaLegacyMediaSchema.Idol(id: idolID, name: "Fixture Idol")
                let event = ChekinanaLegacyMediaSchema.Event(id: eventID, name: "Fixture Event")
                let image = ChekinanaLegacyMediaSchema.Cheki(id: mediaID)
                image.idols = [idol]; image.event = event; image.imageRef = "opaque-reference.jpg"
                image.note = "preserve this media"
                context.insert(idol); context.insert(event); context.insert(image)
                let first = ChekiRecord(note: "first identity", count: Int.max)
                first.idolIDs = [idolID]
                let second = ChekiRecord(note: "different identity", count: 1)
                second.idolIDs = [idolID]
                context.insert(first); context.insert(second)
                try context.save()
            }
            let migrated = try ChekinanaDataStore.legacyMediaContainer(
                at: store, sourceVersion: version, configurationName: "LegacyMediaFixture"
            )
            let context = ModelContext(migrated)
            let media = try context.fetch(FetchDescriptor<MediaItem>())
            XCTAssertEqual(media.count, 1)
            XCTAssertEqual(media.first?.mediaOwnerID, mediaID)
            XCTAssertEqual(media.first?.idolIDs, [idolID])
            XCTAssertEqual(media.first?.eventID, eventID)
            XCTAssertEqual(media.first?.mediaRef, "opaque-reference.jpg")
            XCTAssertEqual(media.first?.note, "preserve this media")
            let records = try context.fetch(FetchDescriptor<ChekiRecord>())
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(records.first { $0.note == "first identity" }?.count, Int.max)
            XCTAssertEqual(records.first { $0.note == "different identity" }?.count, 1)
        }
    }

    func testCustomSizeRejectsUnsafeRoundedDimensionsBeforeIntegerConversion() {
        for ratio in [Double(Int.max) / 1_200, Double.greatestFiniteMagnitude, .infinity, .nan] {
            XCTAssertNil(ChekinanaCustomChekiSizePolicy.pixelDimensions(widthRatio: ratio, heightRatio: 1))
        }
        let boundary = ChekinanaCustomChekiSizePolicy.pixelDimensions(
            widthRatio: 8_192.0 / 1_200, heightRatio: 1
        )
        XCTAssertEqual(boundary?.width, 8_192)
        XCTAssertEqual(boundary?.height, 1_200)
        XCTAssertNil(ChekinanaCustomChekiSizePolicy.pixelDimensions(
            widthRatio: 8_192.5 / 1_200, heightRatio: 1
        ))
    }

    func testImportedEventMediaNamesPreserveLegalExtensionsAndUseOwnerUUID() throws {
        let ownerID = UUID()
        for ext in ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"] {
            for kind in [ChekinanaEventMediaReference.Kind.avatar, .image] {
                let ref = try ChekinanaEventMediaReference.importedFilename(
                    kind: kind, ownerID: ownerID, originalReference: "original.\(ext)"
                )
                let parsed = try XCTUnwrap(ChekinanaEventMediaReference.parse(ref))
                XCTAssertEqual(parsed.kind, kind)
                XCTAssertEqual(parsed.fileExtension, ext)
                XCTAssertFalse(parsed.isLegacyBackup)
                XCTAssertTrue(ref.contains(ownerID.uuidString.lowercased()))
                XCTAssertTrue(ChekinanaEventMediaJournal.isManaged(ref))
            }
        }
        XCTAssertThrowsError(try ChekinanaEventMediaReference.importedFilename(
            kind: .image, ownerID: ownerID, originalReference: "original.bin"
        ))
    }

    func testLegacyBackupNamesStayReadableWithoutGrantingImmediateDeletion() throws {
        let id = UUID().uuidString.lowercased()
        for (prefix, kind) in [
            ("backup-event", ChekinanaEventMediaReference.Kind.avatar),
            ("backup-event-image", .image), ("backup-travel", .avatar),
        ] {
            let ref = "\(prefix)-\(id).png"
            let parsed = try XCTUnwrap(ChekinanaEventMediaReference.parse(ref))
            XCTAssertEqual(parsed.kind, kind)
            XCTAssertTrue(parsed.isLegacyBackup)
            XCTAssertFalse(parsed.permitsImmediateDiscard)
            XCTAssertEqual(ChekinanaEventAvatarStore.isManaged(ref), kind == .avatar)
            XCTAssertEqual(ChekinanaEventImageStore.isManaged(ref), kind == .image)
        }
        for ref in [
            "../backup-event-image-\(id).jpg", "/backup-event-image-\(id).jpg",
            "backup-event-image-\(id).bin", "backup-event-image-invalid.jpg",
            "event-image-\(id).jpg", "other-\(id).jpg",
        ] {
            XCTAssertNil(ChekinanaEventMediaReference.parse(ref))
        }
    }

    @MainActor
    func testRestoredEventImagesLoadInOrderAndMissingFilesCannotBecomeAnEmptyDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "backup-event-image-regression-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(ChekinanaSchemaV17.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let event = Event(name: "Restored Event")
        event.city = "Fixture City"
        XCTAssertNil(event.avatarImageRef)
        context.insert(event)
        let legacyRef = "backup-event-image-\(UUID().uuidString.lowercased()).png"
        let currentRef = try ChekinanaEventMediaReference.importedFilename(
            kind: .image, ownerID: event.id, originalReference: "fixture.jpg"
        )
        let refs = [legacyRef, currentRef]
        let rows = refs.enumerated().map {
            EventImage(eventID: event.id, imageRef: $0.element, sortOrder: $0.offset)
        }
        for (index, row) in rows.enumerated() {
            try Data([UInt8(index + 1), 2, 3]).write(to: root.appendingPathComponent(row.imageRef))
            context.insert(row)
        }
        try context.save()
        let fresh = ModelContext(container)
        let values = try ChekinanaEventPersistence.imageValues(
            for: event.id, in: fresh, directory: root
        )
        XCTAssertEqual(values.map(\.id), rows.map { Optional($0.id) })
        XCTAssertEqual(values.map(\.imageRef), refs)
        try FileManager.default.removeItem(at: root.appendingPathComponent(legacyRef))
        XCTAssertThrowsError(try ChekinanaEventPersistence.imageValues(
            for: event.id, in: fresh, directory: root
        ))
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<EventImage>()).count, 2)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(legacyRef),
            withDestinationURL: root.appendingPathComponent(currentRef)
        )
        XCTAssertNil(ChekinanaEventMediaReference.localFileURL(for: legacyRef, directory: root))
        XCTAssertThrowsError(try ChekinanaEventPersistence.imageValues(
            for: event.id, in: fresh, directory: root
        ))
    }

    @MainActor
    func testV15ToV16MigratesSocialSourceOntoEventField() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("event-source-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.sqlite")
        let eventID = UUID()
        do {
            let legacySchema = Schema(versionedSchema: ChekinanaSchemaV15.self)
            let legacy = try ModelContainer(
                for: legacySchema,
                configurations: ModelConfiguration(schema: legacySchema, url: store)
            )
            let context = ModelContext(legacy)
            let event = ChekinanaPreEventSourceSchema.Event(id: eventID, name: "Legacy")
            event.weiboURL = URL(string: "https://m.weibo.cn/status/1")
            context.insert(event)
            try context.save()
        }

        let currentSchema = Schema(versionedSchema: ChekinanaSchemaV16.self)
        let current = try ModelContainer(
            for: currentSchema,
            migrationPlan: ChekinanaSchemaMigrationPlan.self,
            configurations: ModelConfiguration(schema: currentSchema, url: store)
        )
        let events = try ModelContext(current).fetch(FetchDescriptor<Event>())
        XCTAssertEqual(events.map(\.id), [eventID])
        XCTAssertEqual(events.first?.sourceRawValue, ChekinanaEventSource.weibo.rawValue)
        XCTAssertEqual(events.first?.source, .weibo)
    }

    @MainActor
    func testCurrentV17MarkerAndPhysicalStoreReopenInPlace() throws {
        struct Marker: Codable { let schemaVersion: Int; let directoryName: String }
        enum Unexpected: Error { case copied, migrated }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-current-v17-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: root,
            legacyStoreName: "legacy.store",
            namespace: "memory-v17-test"
        )
        let directoryName = "store-\(UUID().uuidString)"
        let activeDirectory = paths.candidateRootURL
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        let activeStore = activeDirectory.appendingPathComponent("current.store")
        try Data("v17".utf8).write(to: activeStore)
        try JSONEncoder().encode(Marker(schemaVersion: 17, directoryName: directoryName))
            .write(to: paths.activeMarkerURL)
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        var reopenedURL: URL?
        let result = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            copyStore: { _, _, _ in throw Unexpected.copied },
            inspectStoreVersion: { _ in .v17 },
            makeAutomaticContainer: { url in reopenedURL = url; return container }
        ) { _ in throw Unexpected.migrated }
        guard case .success = result else { return XCTFail("V17 must reopen in place") }
        XCTAssertEqual(reopenedURL?.standardizedFileURL, activeStore.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: paths.activeMarkerURL),
                       try JSONEncoder().encode(Marker(schemaVersion: 17, directoryName: directoryName)))
    }

    @MainActor
    func testLegacyV14FamilyUsesIsolatedAutomaticLightweightMigration() throws {
        struct Marker: Codable { let schemaVersion: Int; let directoryName: String }
        enum Unexpected: Error { case stagedMigration }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "memory-legacy-v14-family-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: root,
            legacyStoreName: "legacy.store",
            namespace: "memory-v14-family-test"
        )
        let oldDirectoryName = "store-\(UUID().uuidString)"
        let oldDirectory = paths.candidateRootURL.appendingPathComponent(
            oldDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldStore = oldDirectory.appendingPathComponent("current.store")
        let sentinel = Data("pre-memory-v14-family".utf8)
        try sentinel.write(to: oldStore)
        let oldMarker = try JSONEncoder().encode(Marker(
            schemaVersion: 14,
            directoryName: oldDirectoryName
        ))
        try oldMarker.write(to: paths.activeMarkerURL)

        let schema = Schema(versionedSchema: ChekinanaSchemaV16.self)
        let inMemory = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        var automaticURL: URL?
        let result = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            copyStore: { source, destination, manager in
                try manager.copyItem(at: source, to: destination)
            },
            inspectStoreVersion: { _ in .v14 },
            makeAutomaticContainer: { url in
                automaticURL = url
                XCTAssertEqual(try Data(contentsOf: url), sentinel)
                return inMemory
            }
        ) { _ in
            throw Unexpected.stagedMigration
        }

        guard case .success = result else {
            return XCTFail("A historical V14-family store must use isolated automatic migration")
        }
        let activatedURL = try XCTUnwrap(automaticURL)
        XCTAssertNotEqual(activatedURL.standardizedFileURL, oldStore.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: activatedURL), sentinel)
        XCTAssertEqual(try Data(contentsOf: oldStore), sentinel)
        let published = try JSONDecoder().decode(
            Marker.self,
            from: Data(contentsOf: paths.activeMarkerURL)
        )
        XCTAssertEqual(published.schemaVersion, 16)
        XCTAssertEqual(
            activatedURL.deletingLastPathComponent().lastPathComponent,
            published.directoryName
        )
    }

    @MainActor
    func testRealChecksumDriftedV14SQLiteAutomaticallyMigratesToProductionV15() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "memory-real-v14-drift-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let store = directory.appendingPathComponent("current.store")
        let idolID = UUID()
        let eventID = UUID()
        let mediaID = UUID()
        let recordID = UUID()
        let date = Date(timeIntervalSince1970: 1_788_000_000)

        do {
            let historicalSchema = Schema(
                versionedSchema: ChekinanaHistoricalV14DriftFixtureSchema.self
            )
            let historical = try ModelContainer(
                for: historicalSchema,
                configurations: ModelConfiguration(schema: historicalSchema, url: store)
            )
            let context = ModelContext(historical)
            let idol = Idol(id: idolID, name: "V14 Idol", note: "idol sentinel")
            let event = Event(
                id: eventID,
                name: "V14 Event",
                date: date,
                note: "event sentinel"
            )
            context.insert(idol)
            context.insert(event)
            context.insert(MediaItem(
                id: mediaID,
                idols: [idol],
                event: event,
                date: date,
                imageRef: "v14-sentinel.jpg",
                note: "media sentinel"
            ))
            context.insert(ChekiRecord(
                id: recordID,
                idols: [idol],
                event: event,
                date: date,
                note: "record sentinel",
                count: 3
            ))
            try context.save()
        }

        let beforeMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: store
        )
        let identifiers: Set<String>
        if let stored = beforeMetadata[NSStoreModelVersionIdentifiersKey] as? Set<String> {
            identifiers = stored
        } else if let stored = beforeMetadata[NSStoreModelVersionIdentifiersKey] as? [String] {
            identifiers = Set(stored)
        } else {
            identifiers = []
        }
        XCTAssertEqual(identifiers, ["14.0.0"])
        let historicalHashes = try XCTUnwrap(
            beforeMetadata[NSStoreModelVersionHashesKey] as? [String: Data]
        )
        XCTAssertNil(historicalHashes["CalendarGroupOrder"])
        XCTAssertEqual(try ChekinanaDataStore.physicalStoreVersion(at: store), .v14)

        let productionV15 = Schema(versionedSchema: ChekinanaSchemaV15.self)
        let migrated = try ModelContainer(
            for: productionV15,
            configurations: ModelConfiguration(schema: productionV15, url: store)
        )
        let context = ModelContext(migrated)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Idol>()).first?.name, "V14 Idol")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Event>()).first?.name, "V14 Event")
        let media = try XCTUnwrap(try context.fetch(FetchDescriptor<MediaItem>()).first)
        XCTAssertEqual(media.id, mediaID)
        XCTAssertEqual(media.note, "media sentinel")
        XCTAssertEqual(media.idolIDs, [idolID])
        XCTAssertEqual(media.eventID, eventID)
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<ChekiRecord>()).first)
        XCTAssertEqual(record.id, recordID)
        XCTAssertEqual(record.count, 3)
        XCTAssertEqual(record.note, "record sentinel")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MemoryAttachment>()).isEmpty)
        XCTAssertEqual(try ChekinanaDataStore.physicalStoreVersion(at: store), .v15)
    }

    @MainActor
    func testV14AutomaticFailurePreservesSourceAndMarkerUntilRetrySucceeds() throws {
        struct Marker: Codable { let schemaVersion: Int; let directoryName: String }
        enum Injected: Error { case firstOpen }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "memory-v14-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let paths = ChekinanaDataStore.StorePaths(
            rootDirectory: root,
            legacyStoreName: "legacy.store",
            namespace: "memory-v14-retry"
        )
        let sourceDirectoryName = "store-\(UUID().uuidString)"
        let sourceDirectory = paths.candidateRootURL.appendingPathComponent(
            sourceDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceStore = sourceDirectory.appendingPathComponent("current.store")
        let sourceBytes = Data("v14-authoritative-family".utf8)
        try sourceBytes.write(to: sourceStore)
        let markerBytes = try JSONEncoder().encode(Marker(
            schemaVersion: 14,
            directoryName: sourceDirectoryName
        ))
        try markerBytes.write(to: paths.activeMarkerURL)

        let copy: (URL, URL, FileManager) throws -> Void = { source, destination, manager in
            try manager.copyItem(at: source, to: destination)
        }
        let failed = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            copyStore: copy,
            inspectStoreVersion: { _ in .v14 },
            makeAutomaticContainer: { _ in throw Injected.firstOpen }
        ) { _ in throw Injected.firstOpen }
        guard case .failure = failed else { return XCTFail("Injected open must fail") }
        XCTAssertEqual(try Data(contentsOf: sourceStore), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: paths.activeMarkerURL), markerBytes)

        let schema = Schema(versionedSchema: ChekinanaSchemaV16.self)
        let inMemory = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        var retriedURL: URL?
        let retried = ChekinanaDataStore.openPreservingStoreFamily(
            paths: paths,
            copyStore: copy,
            inspectStoreVersion: { _ in .v14 },
            makeAutomaticContainer: { url in retriedURL = url; return inMemory }
        ) { _ in throw Injected.firstOpen }
        guard case .success = retried else { return XCTFail("Retry must succeed") }
        XCTAssertEqual(try Data(contentsOf: sourceStore), sourceBytes)
        XCTAssertNotEqual(retriedURL?.standardizedFileURL, sourceStore.standardizedFileURL)
        let published = try JSONDecoder().decode(
            Marker.self,
            from: Data(contentsOf: paths.activeMarkerURL)
        )
        XCTAssertEqual(published.schemaVersion, 16)
        XCTAssertEqual(
            retriedURL?.deletingLastPathComponent().lastPathComponent,
            published.directoryName
        )
    }

    func testSmallStoredZIPContainsReadableEntryAndCRC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.chekinana")
        let payload = Data("hello-backup".utf8)

        try ChekinanaStreamingZIP.write([.data("manifest.json", payload)], to: url)
        let archive = try Data(contentsOf: url)
        XCTAssertEqual(archive.uint32LE(at: 0), 0x04034b50)
        XCTAssertEqual(archive.uint16LE(at: 8), 0) // stored, not compressed
        XCTAssertEqual(archive.uint32LE(at: 18), UInt32(payload.count))
        let expectedCRC = independentCRC32(payload)
        XCTAssertEqual(archive.uint32LE(at: 14), expectedCRC)
        let nameLength = Int(archive.uint16LE(at: 26))
        let extraLength = Int(archive.uint16LE(at: 28))
        XCTAssertEqual(String(data: archive[30..<(30 + nameLength)], encoding: .utf8), "manifest.json")
        XCTAssertEqual(Data(archive[(30 + nameLength + extraLength)..<(30 + nameLength + extraLength + payload.count)]), payload)
        let central = try XCTUnwrap(archive.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        XCTAssertEqual(archive.uint32LE(at: central + 16), expectedCRC)
        XCTAssertNotNil(archive.range(of: Data([0x50, 0x4b, 0x05, 0x06])))
    }

    func testZip64BoundaryPolicy() {
        XCTAssertFalse(ChekinanaStreamingZIP.requiresZip64(
            entryCount: 1, centralOffset: 100, centralSize: 100, containsLargeEntry: false
        ))
        XCTAssertTrue(ChekinanaStreamingZIP.requiresZip64(
            entryCount: Int(UInt16.max), centralOffset: 100, centralSize: 100, containsLargeEntry: false
        ))
        XCTAssertTrue(ChekinanaStreamingZIP.requiresZip64(
            entryCount: 1, centralOffset: UInt64(UInt32.max), centralSize: 100, containsLargeEntry: false
        ))
        XCTAssertTrue(ChekinanaStreamingZIP.requiresZip64(
            entryCount: 1, centralOffset: 100, centralSize: 100, containsLargeEntry: true
        ))
        let record = ChekinanaStreamingZIP.zip64EndRecord(
            entryCount: 70_000,
            centralSize: 5_000_000_000,
            centralOffset: 6_000_000_000
        )
        XCTAssertEqual(record.uint32LE(at: 0), 0x06064b50)
        XCTAssertEqual(record.uint64LE(at: 24), 70_000)
        XCTAssertEqual(record.uint64LE(at: 40), 5_000_000_000)
        XCTAssertEqual(record.uint64LE(at: 48), 6_000_000_000)
    }

    func testArchivePathsRejectTraversalAndDuplicates() throws {
        XCTAssertTrue(ChekinanaStreamingZIP.safe("media/000001.jpg"))
        XCTAssertFalse(ChekinanaStreamingZIP.safe("../secret"))
        XCTAssertFalse(ChekinanaStreamingZIP.safe("/absolute"))
        XCTAssertFalse(ChekinanaStreamingZIP.safe("media\\secret"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try ChekinanaStreamingZIP.write([
            .data("same", Data()), .data("same", Data()),
        ], to: url))
    }

    func testMissingMediaInspectionFails() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try ChekinanaStreamingZIP.inspect(missing))
    }

    func testTemporaryArchiveCleanupIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chekinana-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("backup.chekinana")
        try Data("temporary".utf8).write(to: archive)

        ChekinanaExportTemporaryFiles.cleanupArchive(at: archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        ChekinanaExportTemporaryFiles.cleanupArchive(at: archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMediaInspectionProducesManifestChecksum() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("checksum-fixture".utf8)
        try bytes.write(to: url)
        let result = try ChekinanaStreamingZIP.inspect(url)
        XCTAssertEqual(result.size, UInt64(bytes.count))
        XCTAssertEqual(result.crc32, independentCRC32(bytes))
        XCTAssertEqual(
            result.sha256,
            "c607d4bcf3b114340fc781bfb5cb3c6b3d9bc8190c72965c8998460989192417"
        )
    }

    func testSinglePassMediaBackfillsCRCAndWritesManifestLast() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let bytes = Data(repeating: 37, count: 1_048_577)
        try bytes.write(to: source)
        let archive = root.appendingPathComponent("backup.chekinana")
        var completed: ChekinanaStreamingZIP.Inspection?
        try ChekinanaStreamingZIP.write([
            .data("data.json", Data("{}".utf8)),
            .data("settings.json", Data("{}".utf8)),
            .streamingFile("media/source.bin", source, try ChekinanaStreamingZIP.fileIdentity(at: source)),
        ], to: archive) { inspections in
            XCTAssertEqual(inspections.count, 3)
            completed = inspections.last
            return [.data("manifest.json", Data("{}".utf8))]
        }
        let extracted = try ChekinanaStoredBackupReader.extract(archive)
        defer {
            if let manifest = extracted["manifest.json"] {
                try? FileManager.default.removeItem(at: manifest.url.deletingLastPathComponent())
            }
        }
        let media = try XCTUnwrap(extracted["media/source.bin"])
        XCTAssertEqual(try Data(contentsOf: media.url), bytes)
        XCTAssertEqual(media.crc32, independentCRC32(bytes))
        XCTAssertEqual(media.sha256, completed?.sha256)
        XCTAssertEqual(completed?.size, UInt64(bytes.count))
    }

    func testSinglePassRejectsFileReplacedAfterMetadataPlan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let archive = root.appendingPathComponent("backup.chekinana")
        try Data([1, 2, 3]).write(to: source)
        let entry = ChekinanaStreamingZIP.Entry.streamingFile(
            "media/source.bin", source, try ChekinanaStreamingZIP.fileIdentity(at: source)
        )
        try Data([4, 5, 6]).write(to: source, options: .atomic)
        XCTAssertThrowsError(try ChekinanaStreamingZIP.write([entry], to: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(try Data(contentsOf: source), Data([4, 5, 6]))
    }

    func testSinglePassManifestFailureRemovesOnlyIncompleteArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let archive = root.appendingPathComponent("backup.chekinana")
        try Data([1, 2, 3]).write(to: source)
        let entry = ChekinanaStreamingZIP.Entry.streamingFile(
            "media/source.bin", source, try ChekinanaStreamingZIP.fileIdentity(at: source)
        )
        XCTAssertThrowsError(try ChekinanaStreamingZIP.write([entry], to: archive) { _ in
            throw NSError(domain: "SyntheticManifestFailure", code: 1)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    @MainActor
    func testEmptyV16SnapshotHasAllEntitiesAndSettings() throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let snapshot = try ChekinanaDataExportSnapshot.capture(
            in: ModelContext(container)
        )
        XCTAssertEqual(Set(snapshot.entityCounts.keys), [
            "Idol", "IdolPatternState", "Event", "EventSchedule", "EventImage",
            "CalendarGroupOrder", "TravelSegment", "MediaItem", "ChekiRecord",
            "Memory", "MemoryAttachment", "CustomChekiSize",
        ])
        XCTAssertTrue(snapshot.entityCounts.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(Set(snapshot.settings.keys), [
            ChekinanaLanguagePreference.defaultsKey,
            ChekinanaThemePreference.defaultsKey,
            ChekinanaHiddenIdolPersistence.defaultsKey,
        ])
        XCTAssertTrue(snapshot.media.isEmpty)
    }

    func testMemoryPolicyPreservesMultilineBodyAndRejectsOnlyEmptyDraft() {
        let body = " first line\n\nsecond line "
        let title = "  preserved title  "
        XCTAssertEqual(ChekinanaMemoryPolicy.meaningfulText(body), body)
        XCTAssertEqual(ChekinanaMemoryPolicy.normalizedTitle(title), title)
        XCTAssertNil(ChekinanaMemoryPolicy.normalizedTitle(" \n "))
        XCTAssertNil(ChekinanaMemoryPolicy.meaningfulText(" \n\t "))
        XCTAssertFalse(ChekinanaMemoryPolicy.isValid(
            title: " ", bodyText: "\n", date: nil, eventID: nil,
            idolIDs: [], attachmentCount: 0
        ))
        XCTAssertTrue(ChekinanaMemoryPolicy.isValid(
            title: nil, bodyText: body, date: nil, eventID: nil,
            idolIDs: [], attachmentCount: 0
        ))
    }

    func testMemoryIdolRelationshipDraftKeepsHiddenIDsForUnrelatedEdits() {
        let visibleID = UUID()
        let hiddenID = UUID()
        let persistedIDs = [visibleID, hiddenID]
        let draft = ChekinanaMemoryIdolRelationshipDraft(
            initialIDs: persistedIDs
        )

        XCTAssertEqual(draft.initialIDs, Set(persistedIDs))
        XCTAssertEqual(
            draft.selectedVisibleIDs(
                currentPersistedIDs: persistedIDs,
                visibleIDs: [visibleID]
            ),
            [visibleID]
        )
        XCTAssertEqual(
            draft.resolvedIDs(
                currentPersistedIDs: persistedIDs,
                validIDs: Set(persistedIDs)
            ),
            Set(persistedIDs)
        )
    }

    func testMemoryIdolRelationshipDraftAppliesOnlyExplicitVisibleChanges() {
        let retainedHiddenID = UUID()
        let removedVisibleID = UUID()
        let addedVisibleID = UUID()
        let persistedIDs = [retainedHiddenID, removedVisibleID]
        var draft = ChekinanaMemoryIdolRelationshipDraft(
            initialIDs: persistedIDs
        )

        draft.recordVisibleSelection(
            [addedVisibleID],
            visibleIDs: [removedVisibleID, addedVisibleID],
            currentPersistedIDs: persistedIDs
        )

        XCTAssertEqual(draft.explicitlyAddedIDs, [addedVisibleID])
        XCTAssertEqual(draft.explicitlyRemovedIDs, [removedVisibleID])
        XCTAssertEqual(
            draft.resolvedIDs(
                currentPersistedIDs: persistedIDs,
                validIDs: [retainedHiddenID, removedVisibleID, addedVisibleID]
            ),
            [retainedHiddenID, addedVisibleID]
        )
    }

    func testMemoryIdolRelationshipDraftIgnoresHideAndUnhideDuringEditing() {
        let linkedID = UUID()
        let persistedIDs = [linkedID]
        let draft = ChekinanaMemoryIdolRelationshipDraft(
            initialIDs: persistedIDs
        )

        XCTAssertEqual(
            draft.selectedVisibleIDs(
                currentPersistedIDs: persistedIDs,
                visibleIDs: [linkedID]
            ),
            [linkedID]
        )
        XCTAssertTrue(draft.selectedVisibleIDs(
            currentPersistedIDs: persistedIDs,
            visibleIDs: []
        ).isEmpty)
        XCTAssertEqual(
            draft.selectedVisibleIDs(
                currentPersistedIDs: persistedIDs,
                visibleIDs: [linkedID]
            ),
            [linkedID]
        )
        XCTAssertTrue(draft.explicitlyAddedIDs.isEmpty)
        XCTAssertTrue(draft.explicitlyRemovedIDs.isEmpty)
    }

    func testMemoryIdolRelationshipDraftUsesDeletionAndMergeMaintenance() {
        let deletedID = UUID()
        let mergeSourceID = UUID()
        let mergeTargetID = UUID()
        let nonexistentID = UUID()

        let deletedDraft = ChekinanaMemoryIdolRelationshipDraft(
            initialIDs: [deletedID]
        )
        XCTAssertTrue(deletedDraft.resolvedIDs(
            currentPersistedIDs: [],
            validIDs: [mergeTargetID]
        ).isEmpty)

        let mergedDraft = ChekinanaMemoryIdolRelationshipDraft(
            initialIDs: [mergeSourceID, nonexistentID]
        )
        XCTAssertEqual(
            mergedDraft.resolvedIDs(
                currentPersistedIDs: [mergeTargetID, nonexistentID],
                validIDs: [mergeTargetID]
            ),
            [mergeTargetID]
        )
    }

    func testMemoryAttachmentLifecycleSeparatesStagedAndManagedDeletion() {
        let stagedURL = URL(fileURLWithPath: "/tmp/staged-memory-image")
        XCTAssertTrue(ChekinanaMemoryAttachmentLifecyclePolicy.removesStagedFileImmediately(
            existingReference: nil, stagedURL: stagedURL
        ))
        XCTAssertFalse(ChekinanaMemoryAttachmentLifecyclePolicy.removesStagedFileImmediately(
            existingReference: "managed.jpg", stagedURL: nil
        ))
        XCTAssertFalse(ChekinanaMemoryAttachmentLifecyclePolicy
            .removesManagedFileBeforeSuccessfulSave(existingReference: "managed.jpg"))
    }

    func testMemoryAttachmentImportGateBlocksSaveAndRejectsLateCompletion() throws {
        var gate = ChekinanaMemoryAttachmentImportGate()
        let first = try XCTUnwrap(gate.begin())
        let second = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.isImporting)
        XCTAssertFalse(gate.allowsSave)
        XCTAssertTrue(gate.acceptsCompletion(first))
        gate.finish(first)
        XCTAssertTrue(gate.isImporting)
        XCTAssertFalse(gate.allowsSave)
        gate.finish(second)
        let saveOwner = UUID()
        XCTAssertTrue(gate.beginSave(ownerID: saveOwner))
        XCTAssertEqual(gate.saveOwnerID, saveOwner)
        XCTAssertNil(gate.begin(), "A late picker callback must not join a frozen save")
        gate.finishSave(ownerID: UUID())
        XCTAssertEqual(gate.saveOwnerID, saveOwner, "Only the owning save may reopen imports")
        gate.finishSave(ownerID: saveOwner)
        XCTAssertTrue(gate.allowsSave)
        let closingImport = try XCTUnwrap(gate.begin())
        gate.close()
        XCTAssertFalse(gate.acceptsCompletion(closingImport))
        XCTAssertNil(gate.begin())
        gate.finish(closingImport)
        XCTAssertFalse(gate.isImporting)
        XCTAssertFalse(gate.allowsSave)
        XCTAssertTrue(gate.activeTokens.isEmpty)
    }

    func testMemoryEditorCleanupIsExplicitAndPreviewSafe() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chekinana/ChekinanaProductShell.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let committerStart = try XCTUnwrap(
            source.range(of: "enum ChekinanaMemorySaveCommitter")
        )
        let start = try XCTUnwrap(source.range(of: "private struct ChekinanaMemoryEditor"))
        let committer = String(source[committerStart.lowerBound..<start.lowerBound])
        let end = try XCTUnwrap(source.range(
            of: "private struct ChekinanaGalleryCompactFilterLabel",
            range: start.upperBound..<source.endIndex
        ))
        let editor = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(editor.contains(".onDisappear {\n            guard !didFinish"))
        XCTAssertTrue(editor.contains(".interactiveDismissDisabled()"))
        XCTAssertTrue(editor.contains("cancelAndDismiss()"))
        XCTAssertTrue(editor.contains("removeAttachment(at: index)"))
        XCTAssertTrue(editor.contains("importTasks: [UUID: Task<Void, Never>]"))
        XCTAssertTrue(editor.contains("guard canSave, importGate.allowsSave else"))
        XCTAssertTrue(editor.contains("importGate.beginSave(ownerID: ownerID)"))
        XCTAssertTrue(editor.contains("let draft = try frozenSaveDraft()"))
        XCTAssertTrue(editor.contains(".disabled(isSaving || isDeleting)"))
        XCTAssertTrue(editor.contains("guard !isSaving, !isDeleting else { return }"))
        XCTAssertTrue(editor.contains(
            "guard !isSaving, !isDeleting, attachments.indices.contains(index)"
        ))
        XCTAssertTrue(editor.contains("resumeDeferredPickerImports()"))
        XCTAssertTrue(editor.contains("await task.value"))
        XCTAssertTrue(editor.contains("importGate.acceptsCompletion(token)"))
        XCTAssertEqual(
            editor.components(separatedBy: "preferredItemEncoding: .current").count - 1,
            2
        )
        XCTAssertTrue(editor.contains("type: ChekinanaGalleryImageTransfer.self"))
        XCTAssertTrue(editor.contains(
            "item.loadTransferable(type: ChekinanaGalleryVideoTransfer.self)"
        ))
        XCTAssertTrue(editor.contains("ChekinanaMemorySaveCommitter.save("))
        XCTAssertTrue(editor.contains("ChekinanaMemorySaveCommitter.delete("))
        XCTAssertTrue(committer.contains(
            "ChekinanaLibraryMutationProtocol.withExclusiveOperation"
        ))
        XCTAssertTrue(committer.contains(
            "ChekinanaPersistenceMutationCoordinator.withLock"
        ))
        XCTAssertTrue(committer.contains("ChekinanaLibraryGenerationStore"))
        XCTAssertTrue(committer.contains("canRemoveManagedFileLocked"))
        XCTAssertTrue(committer.contains("referencedFilenames"))
        XCTAssertTrue(committer.contains("recordOrphanedImport"))
        XCTAssertTrue(committer.contains("if !databaseCommitted"))
        XCTAssertTrue(editor.contains(
            "@State private var idolRelationshipDraft: ChekinanaMemoryIdolRelationshipDraft"
        ))
        XCTAssertTrue(editor.contains("selectedIDs: visibleIdolSelection"))
        XCTAssertTrue(editor.contains("idols.filter { resolvedIdolIDs.contains($0.id) }"))
        XCTAssertFalse(editor.contains(
            "target.idolIDs = idolOrdering.ordered(visibleIdols.filter"
        ))
    }

    func testMemorySaveDraftFreezesEverySubmittedFieldAndAttachmentOrder() {
        let date = ChekinanaPersistedContentDatePolicy.minimumCanonicalDate
        let eventID = UUID()
        let idolIDs = [UUID(), UUID()]
        let imageID = UUID()
        let videoID = UUID()
        let imageURL = URL(fileURLWithPath: "/tmp/frozen-memory-image")
        let videoURL = URL(fileURLWithPath: "/tmp/frozen-memory-video")
        let frozen = ChekinanaMemorySaveDraft(
            title: "Frozen title",
            bodyText: "Frozen body",
            date: date,
            eventID: eventID,
            idolIDs: idolIDs,
            attachments: [
                .init(
                    id: videoID,
                    kind: .video,
                    existingReference: nil,
                    stagedURL: videoURL,
                    sortOrder: 0
                ),
                .init(
                    id: imageID,
                    kind: .image,
                    existingReference: nil,
                    stagedURL: imageURL,
                    sortOrder: 1
                ),
            ]
        )

        var liveTitle = frozen.title
        var liveBody = frozen.bodyText
        var liveDate = frozen.date
        var liveEventID = frozen.eventID
        var liveIdolIDs = frozen.idolIDs
        var liveAttachments = frozen.attachments
        liveTitle = "Changed title"
        liveBody = "Changed body"
        liveDate = nil
        liveEventID = nil
        liveIdolIDs.removeAll()
        liveAttachments.removeFirst()
        liveAttachments.reverse()

        XCTAssertEqual(frozen.title, "Frozen title")
        XCTAssertEqual(frozen.bodyText, "Frozen body")
        XCTAssertEqual(frozen.date, date)
        XCTAssertEqual(frozen.eventID, eventID)
        XCTAssertEqual(frozen.idolIDs, idolIDs)
        XCTAssertEqual(frozen.attachments.map(\.id), [videoID, imageID])
        XCTAssertEqual(frozen.attachments.map(\.sortOrder), [0, 1])
        XCTAssertNotEqual(liveTitle, frozen.title)
        XCTAssertNotEqual(liveBody, frozen.bodyText)
        XCTAssertNotEqual(liveDate, frozen.date)
        XCTAssertNotEqual(liveEventID, frozen.eventID)
        XCTAssertNotEqual(liveIdolIDs, frozen.idolIDs)
        XCTAssertNotEqual(liveAttachments, frozen.attachments)
    }

    @MainActor
    func testMemorySaveCommitterCreatesOwnerScopedTargetFromFrozenDraft() async throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let firstIdol = Idol(name: "First")
        let secondIdol = Idol(name: "Second")
        let event = Event(name: "Frozen Event")
        context.insert(firstIdol)
        context.insert(secondIdol)
        context.insert(event)
        try context.save()

        let ownerID = UUID()
        let targetID = UUID()
        let firstAttachmentID = UUID()
        let secondAttachmentID = UUID()
        let date = ChekinanaPersistedContentDatePolicy.minimumCanonicalDate
        let draft = ChekinanaMemorySaveDraft(
            title: "Frozen title",
            bodyText: "Frozen body",
            date: date,
            eventID: event.id,
            idolIDs: [secondIdol.id, firstIdol.id],
            attachments: [
                .init(
                    id: secondAttachmentID,
                    kind: .video,
                    existingReference: nil,
                    stagedURL: URL(fileURLWithPath: "/tmp/second.mov"),
                    sortOrder: 0
                ),
                .init(
                    id: firstAttachmentID,
                    kind: .image,
                    existingReference: nil,
                    stagedURL: URL(fileURLWithPath: "/tmp/first.jpg"),
                    sortOrder: 1
                ),
            ]
        )
        var materializedIDs: [UUID] = []

        let authorization = try await ChekinanaMemorySaveCommitter.save(
            draft: draft,
            expectedTarget: nil,
            ownerID: ownerID,
            targetID: targetID,
            in: context,
            materializeAttachment: { attachment in
                materializedIDs.append(attachment.id)
                return attachment.kind == .image
                    ? "shame-\(attachment.id.uuidString.lowercased()).jpg"
                    : "douga-\(attachment.id.uuidString.lowercased()).mov"
            },
            removeManagedFile: { _, _, _ in
                XCTFail("A successful new save must not delete its outputs")
            },
            recordOrphanedFile: { _, _, _ in
                XCTFail("A successful new save must not enqueue its outputs")
            }
        )

        XCTAssertEqual(authorization.ownerID, ownerID)
        XCTAssertEqual(authorization.targetID, targetID)
        XCTAssertNil(authorization.expectedTarget)
        XCTAssertEqual(
            authorization.libraryGeneration,
            try ChekinanaLibraryGenerationStore.current(in: context)
        )
        XCTAssertEqual(materializedIDs, [secondAttachmentID, firstAttachmentID])
        let memory = try XCTUnwrap(
            context.fetch(FetchDescriptor<Memory>()).first { $0.id == targetID }
        )
        XCTAssertEqual(memory.title, draft.title)
        XCTAssertEqual(memory.bodyText, draft.bodyText)
        XCTAssertEqual(memory.date, draft.date)
        XCTAssertEqual(memory.eventID, draft.eventID)
        XCTAssertEqual(memory.idolIDs, draft.idolIDs)
        let attachments = try context.fetch(FetchDescriptor<MemoryAttachment>())
            .filter { $0.memoryID == targetID }
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(attachments.map(\.id), [secondAttachmentID, firstAttachmentID])
        XCTAssertEqual(attachments.map(\.kind), [.video, .image])
    }

    @MainActor
    func testMemorySaveCommitterDoesNotResurrectTargetDeletedDuringMaterialization() async throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: "Original")
        let existing = MemoryAttachment(
            memoryID: memory.id,
            kind: .image,
            managedRef: "shame-\(UUID().uuidString.lowercased()).jpg",
            sortOrder: 0
        )
        context.insert(memory)
        context.insert(existing)
        try context.save()
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let expected = try XCTUnwrap(
            ChekinanaMemorySaveCommitter.targetSnapshot(
                memoryID: memory.id,
                in: context
            )
        )
        let newID = UUID()
        let draft = ChekinanaMemorySaveDraft(
            title: "Edited",
            bodyText: "",
            date: nil,
            eventID: nil,
            idolIDs: [],
            attachments: [
                .init(
                    id: newID,
                    kind: .image,
                    existingReference: nil,
                    stagedURL: URL(fileURLWithPath: "/tmp/retry.jpg"),
                    sortOrder: 0
                ),
            ]
        )
        var removedOutputIDs: [UUID] = []

        do {
            _ = try await ChekinanaMemorySaveCommitter.save(
                draft: draft,
                expectedTarget: expected,
                ownerID: UUID(),
                targetID: memory.id,
                in: context,
                materializeAttachment: { attachment in
                    try ChekinanaPersistenceMutationCoordinator.withLock {
                        let attachments = try context.fetch(
                            FetchDescriptor<MemoryAttachment>()
                        ).filter { $0.memoryID == memory.id }
                        attachments.forEach(context.delete)
                        let targets = try context.fetch(FetchDescriptor<Memory>())
                            .filter { $0.id == memory.id }
                        targets.forEach(context.delete)
                        try context.save()
                    }
                    return "shame-\(attachment.id.uuidString.lowercased()).jpg"
                },
                removeManagedFile: { _, id, _ in removedOutputIDs.append(id) },
                recordOrphanedFile: { _, _, _ in }
            )
            XCTFail("A save authorized for a deleted Memory must fail")
        } catch {
            XCTAssertEqual(
                error as? ChekinanaMemorySaveMutationError,
                .changedMemory
            )
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MemoryAttachment>()).isEmpty)
        XCTAssertEqual(removedOutputIDs, [newID])
    }

    @MainActor
    func testMemoryDeleteCompletingFirstRejectsAStaleSave() async throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: "Delete wins")
        let attachment = MemoryAttachment(
            memoryID: memory.id,
            kind: .image,
            managedRef: "shame-\(UUID().uuidString.lowercased()).jpg",
            sortOrder: 0
        )
        context.insert(memory)
        context.insert(attachment)
        try context.save()
        let attachmentID = attachment.id
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let staleTarget = try XCTUnwrap(
            ChekinanaMemorySaveCommitter.targetSnapshot(
                memoryID: memory.id,
                in: context
            )
        )
        var deletedFileIDs: [UUID] = []

        try await ChekinanaMemorySaveCommitter.delete(
            expectedTarget: staleTarget,
            in: context,
            removeManagedFile: { _, id, _ in deletedFileIDs.append(id) },
            recordOrphanedFile: { _, _, _ in }
        )
        XCTAssertEqual(deletedFileIDs, [attachmentID])

        let staleDraft = ChekinanaMemorySaveDraft(
            title: "Must not return",
            bodyText: "",
            date: nil,
            eventID: nil,
            idolIDs: [],
            attachments: []
        )
        do {
            _ = try await ChekinanaMemorySaveCommitter.save(
                draft: staleDraft,
                expectedTarget: staleTarget,
                ownerID: UUID(),
                targetID: staleTarget.record.id,
                in: context,
                materializeAttachment: { _ in "" },
                removeManagedFile: { _, _, _ in },
                recordOrphanedFile: { _, _, _ in }
            )
            XCTFail("A completed delete must invalidate the older editor")
        } catch {
            XCTAssertEqual(
                error as? ChekinanaMemorySaveMutationError,
                .changedMemory
            )
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MemoryAttachment>()).isEmpty)
    }

    @MainActor
    func testMemorySaveCommitterRejectsGenerationReplacementBeforeCommit() async throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let attachmentID = UUID()
        let targetID = UUID()
        let draft = ChekinanaMemorySaveDraft(
            title: "New",
            bodyText: "",
            date: nil,
            eventID: nil,
            idolIDs: [],
            attachments: [
                .init(
                    id: attachmentID,
                    kind: .image,
                    existingReference: nil,
                    stagedURL: URL(fileURLWithPath: "/tmp/generation.jpg"),
                    sortOrder: 0
                ),
            ]
        )
        var removedOutputIDs: [UUID] = []
        var queuedOutputIDs: [UUID] = []

        do {
            _ = try await ChekinanaMemorySaveCommitter.save(
                draft: draft,
                expectedTarget: nil,
                ownerID: UUID(),
                targetID: targetID,
                in: context,
                materializeAttachment: { attachment in
                    try ChekinanaLibraryGenerationStore.publish(UUID(), in: context)
                    try context.save()
                    return "shame-\(attachment.id.uuidString.lowercased()).jpg"
                },
                removeManagedFile: { _, id, _ in removedOutputIDs.append(id) },
                recordOrphanedFile: { _, id, _ in queuedOutputIDs.append(id) }
            )
            XCTFail("An old-generation save must not publish")
        } catch {
            XCTAssertEqual(
                error as? ChekinanaMemorySaveMutationError,
                .changedLibrary
            )
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MemoryAttachment>()).isEmpty)
        XCTAssertTrue(removedOutputIDs.isEmpty)
        XCTAssertEqual(queuedOutputIDs, [attachmentID])
    }

    @MainActor
    func testMemorySaveFailureKeepsStagedInputAndQueuesFailedOutputCleanupForRetry() async throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let attachmentID = UUID()
        let stagedURL = URL(fileURLWithPath: "/tmp/preserved-for-retry.jpg")
        let targetID = UUID()
        let draft = ChekinanaMemorySaveDraft(
            title: "Retryable",
            bodyText: "",
            date: nil,
            eventID: nil,
            idolIDs: [],
            attachments: [
                .init(
                    id: attachmentID,
                    kind: .image,
                    existingReference: nil,
                    stagedURL: stagedURL,
                    sortOrder: 0
                ),
            ]
        )
        var cleanupAttempts: [UUID] = []
        var queuedIDs: [UUID] = []

        do {
            _ = try await ChekinanaMemorySaveCommitter.save(
                draft: draft,
                expectedTarget: nil,
                ownerID: UUID(),
                targetID: targetID,
                in: context,
                saveContext: { _ in
                    throw ChekinanaMemoryCommitterTestError.databaseSave
                },
                materializeAttachment: { attachment in
                    "shame-\(attachment.id.uuidString.lowercased()).jpg"
                },
                removeManagedFile: { _, id, _ in
                    cleanupAttempts.append(id)
                    throw ChekinanaMemoryCommitterTestError.cleanup
                },
                recordOrphanedFile: { _, id, _ in queuedIDs.append(id) }
            )
            XCTFail("The injected database failure must be reported")
        } catch {
            XCTAssertTrue(error is ChekinanaMemoryCommitterTestError)
        }
        XCTAssertEqual(draft.attachments.first?.stagedURL, stagedURL)
        XCTAssertEqual(cleanupAttempts, [attachmentID])
        XCTAssertEqual(queuedIDs, [attachmentID])
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MemoryAttachment>()).isEmpty)

        _ = try await ChekinanaMemorySaveCommitter.save(
            draft: draft,
            expectedTarget: nil,
            ownerID: UUID(),
            targetID: targetID,
            in: context,
            materializeAttachment: { attachment in
                "shame-\(attachment.id.uuidString.lowercased()).jpg"
            },
            removeManagedFile: { _, _, _ in },
            recordOrphanedFile: { _, _, _ in }
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<Memory>()).map(\.id), [targetID])
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MemoryAttachment>()).map(\.id),
            [attachmentID]
        )
    }

    @MainActor
    func testMemorySuccessfulCommitQueuesOnlyFailedOldFileCleanup() async throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: "Original")
        let firstOld = MemoryAttachment(
            memoryID: memory.id,
            kind: .image,
            managedRef: "shame-\(UUID().uuidString.lowercased()).jpg",
            sortOrder: 0
        )
        let failedOld = MemoryAttachment(
            memoryID: memory.id,
            kind: .video,
            managedRef: "douga-\(UUID().uuidString.lowercased()).mov",
            sortOrder: 1
        )
        let retainedOld = MemoryAttachment(
            memoryID: memory.id,
            kind: .image,
            managedRef: "shame-\(UUID().uuidString.lowercased()).jpg",
            sortOrder: 2
        )
        context.insert(memory)
        context.insert(firstOld)
        context.insert(failedOld)
        context.insert(retainedOld)
        try context.save()
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let expected = try XCTUnwrap(
            ChekinanaMemorySaveCommitter.targetSnapshot(
                memoryID: memory.id,
                in: context
            )
        )
        let newID = UUID()
        let draft = ChekinanaMemorySaveDraft(
            title: "Committed",
            bodyText: "",
            date: nil,
            eventID: nil,
            idolIDs: [],
            attachments: [
                .init(
                    id: retainedOld.id,
                    kind: retainedOld.kind,
                    existingReference: retainedOld.managedRef,
                    stagedURL: nil,
                    sortOrder: 0
                ),
                .init(
                    id: newID,
                    kind: .image,
                    existingReference: nil,
                    stagedURL: URL(fileURLWithPath: "/tmp/new-valid.jpg"),
                    sortOrder: 1
                ),
            ]
        )
        var removalAttempts: [UUID] = []
        var queuedIDs: [UUID] = []

        _ = try await ChekinanaMemorySaveCommitter.save(
            draft: draft,
            expectedTarget: expected,
            ownerID: UUID(),
            targetID: memory.id,
            in: context,
            materializeAttachment: { attachment in
                "shame-\(attachment.id.uuidString.lowercased()).jpg"
            },
            removeManagedFile: { _, id, _ in
                removalAttempts.append(id)
                if id == failedOld.id {
                    throw ChekinanaMemoryCommitterTestError.cleanup
                }
            },
            recordOrphanedFile: { _, id, _ in queuedIDs.append(id) }
        )

        XCTAssertEqual(Set(removalAttempts), Set([firstOld.id, failedOld.id]))
        XCTAssertEqual(queuedIDs, [failedOld.id])
        XCTAssertFalse(removalAttempts.contains(newID))
        let savedAttachments = try context.fetch(FetchDescriptor<MemoryAttachment>())
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(savedAttachments.map(\.id), [retainedOld.id, newID])
        XCTAssertEqual(savedAttachments.map(\.sortOrder), [0, 1])
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Memory>()).first?.title,
            "Committed"
        )
    }

    @MainActor
    func testMemorySuccessfulCommitNeverDeletesAStillReferencedOldFile() async throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let editedMemory = Memory(title: "Edited")
        let retainingMemory = Memory(title: "Retaining")
        let sharedReference = "shame-\(UUID().uuidString.lowercased()).jpg"
        let removed = MemoryAttachment(
            memoryID: editedMemory.id,
            kind: .image,
            managedRef: sharedReference,
            sortOrder: 0
        )
        let retained = MemoryAttachment(
            memoryID: retainingMemory.id,
            kind: .image,
            managedRef: sharedReference,
            sortOrder: 0
        )
        context.insert(editedMemory)
        context.insert(retainingMemory)
        context.insert(removed)
        context.insert(retained)
        try context.save()
        let removedID = removed.id
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let expected = try XCTUnwrap(
            ChekinanaMemorySaveCommitter.targetSnapshot(
                memoryID: editedMemory.id,
                in: context
            )
        )
        let draft = ChekinanaMemorySaveDraft(
            title: "Committed",
            bodyText: "",
            date: nil,
            eventID: nil,
            idolIDs: [],
            attachments: []
        )
        var removalAttempts: [UUID] = []
        var queuedIDs: [UUID] = []

        _ = try await ChekinanaMemorySaveCommitter.save(
            draft: draft,
            expectedTarget: expected,
            ownerID: UUID(),
            targetID: editedMemory.id,
            in: context,
            materializeAttachment: { _ in
                XCTFail("No attachment should materialize")
                return ""
            },
            removeManagedFile: { _, id, _ in removalAttempts.append(id) },
            recordOrphanedFile: { _, id, _ in queuedIDs.append(id) }
        )

        XCTAssertTrue(removalAttempts.isEmpty)
        XCTAssertEqual(queuedIDs, [removedID])
        let persistedAttachments = try context.fetch(FetchDescriptor<MemoryAttachment>())
        XCTAssertEqual(persistedAttachments.map(\.id), [retained.id])
        XCTAssertEqual(persistedAttachments.first?.managedRef, sharedReference)
    }

    @MainActor
    func testMemorySaveCommitterRejectsChangedExistingVersion() async throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: "Original")
        context.insert(memory)
        try context.save()
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let expected = try XCTUnwrap(
            ChekinanaMemorySaveCommitter.targetSnapshot(
                memoryID: memory.id,
                in: context
            )
        )
        memory.bodyText = "Concurrent edit"
        memory.updatedAt = memory.updatedAt.addingTimeInterval(1)
        try context.save()
        let draft = ChekinanaMemorySaveDraft(
            title: "Stale overwrite",
            bodyText: "",
            date: nil,
            eventID: nil,
            idolIDs: [],
            attachments: []
        )

        do {
            _ = try await ChekinanaMemorySaveCommitter.save(
                draft: draft,
                expectedTarget: expected,
                ownerID: UUID(),
                targetID: memory.id,
                in: context,
                materializeAttachment: { _ in
                    XCTFail("No attachment should materialize")
                    return ""
                },
                removeManagedFile: { _, _, _ in },
                recordOrphanedFile: { _, _, _ in }
            )
            XCTFail("A changed persisted version must reject the stale draft")
        } catch {
            XCTAssertEqual(
                error as? ChekinanaMemorySaveMutationError,
                .changedMemory
            )
        }
        XCTAssertEqual(memory.bodyText, "Concurrent edit")
        XCTAssertEqual(memory.title, "Original")
    }

    @MainActor
    func testMemoryDeletePersistsPerFileJournalBeforeRemovingDatabaseReference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-delete-journal-order-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: "Journal first")
        let attachmentID = UUID()
        let reference = "shame-\(attachmentID.uuidString.lowercased()).jpg"
        let fileURL = directory.appendingPathComponent(reference)
        try Data("memory-journal-first".utf8).write(to: fileURL)
        let attachment = MemoryAttachment(
            id: attachmentID,
            memoryID: memory.id,
            kind: .image,
            managedRef: reference,
            sortOrder: 0
        )
        context.insert(memory)
        context.insert(attachment)
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let expected = try XCTUnwrap(
            ChekinanaMemorySaveCommitter.targetSnapshot(
                memoryID: memory.id,
                in: context
            )
        )
        var observedDurableIntent = false

        try await ChekinanaMemorySaveCommitter.delete(
            expectedTarget: expected,
            in: context,
            directory: directory,
            deletionJournalPersisted: { journal in
                observedDurableIntent = true
                XCTAssertEqual(journal.entries.map(\.filename), [reference])
                XCTAssertEqual(journal.entries.map(\.status), [.pending])
                XCTAssertNotNil(try ChekinanaMemoryAttachmentDeletionJournalStore.load(
                    operationID: journal.operationID,
                    in: directory
                ))
                XCTAssertEqual(
                    try context.fetch(FetchDescriptor<MemoryAttachment>()).map(\.id),
                    [attachmentID],
                    "The durable intent must precede the in-context delete"
                )
                XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            }
        )

        XCTAssertTrue(observedDurableIntent)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MemoryAttachment>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(
            try ChekinanaMemoryAttachmentDeletionJournalStore.discover(
                in: directory
            ).isEmpty
        )
    }

    @MainActor
    func testMemoryDeletionCrashRecoveryKeepsThumbnailFailureAndRetriesIdempotently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-delete-journal-partial-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: "Partial delete")
        let attachmentID = UUID()
        let reference = "douga-\(attachmentID.uuidString.lowercased()).mov"
        let mainURL = directory.appendingPathComponent(reference)
        let thumbnailURL = ChekinanaGalleryMediaStore.thumbnailURL(
            id: attachmentID,
            directory: directory
        )
        try Data("memory-video-main".utf8).write(to: mainURL)
        try Data("memory-video-thumbnail".utf8).write(to: thumbnailURL)
        let attachment = MemoryAttachment(
            id: attachmentID,
            memoryID: memory.id,
            kind: .video,
            managedRef: reference,
            sortOrder: 0
        )
        context.insert(memory)
        context.insert(attachment)
        let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let journal = try XCTUnwrap(
            ChekinanaMemoryAttachmentDeletionCoordinator.preparePersistedDeletion(
                [ChekinanaMemoryAttachmentRecordSnapshot(attachment)],
                libraryGeneration: generation,
                in: context,
                directory: directory
            )
        )
        XCTAssertEqual(Set(journal.entries.map(\.filename)), Set([
            mainURL.lastPathComponent,
            thumbnailURL.lastPathComponent,
        ]))

        // Simulate termination immediately after DB commit: the journal still
        // has its pre-commit phase, so recovery must use the durable DB witness.
        context.delete(attachment)
        context.delete(memory)
        try context.save()
        var thumbnailFailures = 0
        let first = ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
            in: context,
            directory: directory,
            removeItem: { url in
                if url.lastPathComponent == thumbnailURL.lastPathComponent {
                    thumbnailFailures += 1
                    throw ChekinanaMemoryCommitterTestError.cleanup
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        XCTAssertEqual(first, 1)
        XCTAssertEqual(thumbnailFailures, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
        let pending = try XCTUnwrap(
            ChekinanaMemoryAttachmentDeletionJournalStore.load(
                operationID: journal.operationID,
                in: directory
            )
        )
        XCTAssertEqual(
            pending.entries.first { $0.role == .main }?.status,
            .removed
        )
        XCTAssertEqual(
            pending.entries.first { $0.role == .thumbnail }?.status,
            .pending
        )

        XCTAssertEqual(
            ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
                in: context,
                directory: directory
            ),
            0
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
        XCTAssertTrue(
            try ChekinanaMemoryAttachmentDeletionJournalStore.discover(
                in: directory
            ).isEmpty
        )
        XCTAssertEqual(
            ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
                in: context,
                directory: directory
            ),
            0,
            "A completed journal replay must remain idempotent"
        )
    }

    @MainActor
    func testMemoryDeletionJournalCancelsWhenNewObjectReusesTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-delete-journal-reuse-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let oldMemory = Memory(title: "Old")
        let attachmentID = UUID()
        let reference = "shame-\(attachmentID.uuidString.lowercased()).jpg"
        let fileURL = directory.appendingPathComponent(reference)
        let bytes = Data("memory-reused-file".utf8)
        try bytes.write(to: fileURL)
        let oldAttachment = MemoryAttachment(
            id: attachmentID,
            memoryID: oldMemory.id,
            kind: .image,
            managedRef: reference,
            sortOrder: 0
        )
        context.insert(oldMemory)
        context.insert(oldAttachment)
        let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let journal = try XCTUnwrap(
            ChekinanaMemoryAttachmentDeletionCoordinator.preparePersistedDeletion(
                [ChekinanaMemoryAttachmentRecordSnapshot(oldAttachment)],
                libraryGeneration: generation,
                in: context,
                directory: directory
            )
        )
        context.delete(oldAttachment)
        context.delete(oldMemory)
        try context.save()

        let newMemory = Memory(title: "New owner")
        context.insert(newMemory)
        context.insert(MemoryAttachment(
            id: attachmentID,
            memoryID: newMemory.id,
            kind: .image,
            managedRef: reference,
            sortOrder: 0
        ))
        try context.save()

        XCTAssertEqual(
            ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
                in: context,
                directory: directory
            ),
            0
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        XCTAssertNil(try ChekinanaMemoryAttachmentDeletionJournalStore.load(
            operationID: journal.operationID,
            in: directory
        ))
    }

    @MainActor
    func testMemoryDeletionJournalCancelsWhenFilenameNowHasDifferentBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-delete-journal-byte-reuse-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: "Old bytes")
        let attachmentID = UUID()
        let reference = "shame-\(attachmentID.uuidString.lowercased()).jpg"
        let fileURL = directory.appendingPathComponent(reference)
        try Data("old-memory-bytes".utf8).write(to: fileURL)
        let attachment = MemoryAttachment(
            id: attachmentID,
            memoryID: memory.id,
            kind: .image,
            managedRef: reference,
            sortOrder: 0
        )
        context.insert(memory)
        context.insert(attachment)
        let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let journal = try XCTUnwrap(
            ChekinanaMemoryAttachmentDeletionCoordinator.preparePersistedDeletion(
                [ChekinanaMemoryAttachmentRecordSnapshot(attachment)],
                libraryGeneration: generation,
                in: context,
                directory: directory
            )
        )
        context.delete(attachment)
        context.delete(memory)
        try context.save()
        let replacement = Data("different-new-memory-bytes".utf8)
        try replacement.write(to: fileURL, options: [.atomic])

        XCTAssertEqual(
            ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
                in: context,
                directory: directory
            ),
            0
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), replacement)
        XCTAssertNil(try ChekinanaMemoryAttachmentDeletionJournalStore.load(
            operationID: journal.operationID,
            in: directory
        ))
    }

    @MainActor
    func testMemoryMultiAttachmentDeletionRetainsOnlyFailedFileAcrossRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-delete-journal-multiple-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: "Multiple")
        let firstID = UUID()
        let secondID = UUID()
        let firstRef = "shame-\(firstID.uuidString.lowercased()).jpg"
        let secondRef = "shame-\(secondID.uuidString.lowercased()).jpg"
        let firstURL = directory.appendingPathComponent(firstRef)
        let secondURL = directory.appendingPathComponent(secondRef)
        try Data("memory-first".utf8).write(to: firstURL)
        try Data("memory-second".utf8).write(to: secondURL)
        let first = MemoryAttachment(
            id: firstID,
            memoryID: memory.id,
            kind: .image,
            managedRef: firstRef,
            sortOrder: 0
        )
        let second = MemoryAttachment(
            id: secondID,
            memoryID: memory.id,
            kind: .image,
            managedRef: secondRef,
            sortOrder: 1
        )
        context.insert(memory)
        context.insert(first)
        context.insert(second)
        let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let journal = try XCTUnwrap(
            ChekinanaMemoryAttachmentDeletionCoordinator.preparePersistedDeletion(
                [
                    ChekinanaMemoryAttachmentRecordSnapshot(first),
                    ChekinanaMemoryAttachmentRecordSnapshot(second),
                ],
                libraryGeneration: generation,
                in: context,
                directory: directory
            )
        )
        context.delete(first)
        context.delete(second)
        context.delete(memory)
        try context.save()

        XCTAssertEqual(
            ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
                in: context,
                directory: directory,
                removeItem: { url in
                    if url.lastPathComponent == secondRef {
                        throw ChekinanaMemoryCommitterTestError.cleanup
                    }
                    try FileManager.default.removeItem(at: url)
                }
            ),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        let pending = try XCTUnwrap(
            ChekinanaMemoryAttachmentDeletionJournalStore.load(
                operationID: journal.operationID,
                in: directory
            )
        )
        XCTAssertEqual(
            pending.entries.first { $0.filename == firstRef }?.status,
            .removed
        )
        XCTAssertEqual(
            pending.entries.first { $0.filename == secondRef }?.status,
            .pending
        )
        XCTAssertEqual(
            ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
                in: context,
                directory: directory
            ),
            0
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @MainActor
    func testMemoryDeletionJournalGenerationChangeRetiresWithoutDeletingNewLibraryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-delete-journal-generation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: "Old generation")
        let attachmentID = UUID()
        let reference = "shame-\(attachmentID.uuidString.lowercased()).jpg"
        let fileURL = directory.appendingPathComponent(reference)
        let bytes = Data("new-library-must-keep".utf8)
        try bytes.write(to: fileURL)
        let attachment = MemoryAttachment(
            id: attachmentID,
            memoryID: memory.id,
            kind: .image,
            managedRef: reference,
            sortOrder: 0
        )
        context.insert(memory)
        context.insert(attachment)
        let oldGeneration = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let journal = try XCTUnwrap(
            ChekinanaMemoryAttachmentDeletionCoordinator.preparePersistedDeletion(
                [ChekinanaMemoryAttachmentRecordSnapshot(attachment)],
                libraryGeneration: oldGeneration,
                in: context,
                directory: directory
            )
        )
        context.delete(attachment)
        context.delete(memory)
        try ChekinanaLibraryGenerationStore.publish(UUID(), in: context)
        try context.save()

        XCTAssertEqual(
            ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
                in: context,
                directory: directory
            ),
            0
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        XCTAssertNil(try ChekinanaMemoryAttachmentDeletionJournalStore.load(
            operationID: journal.operationID,
            in: directory
        ))
    }

    @MainActor
    func testMemoryMaterializedRollbackJournalWaitsForLeaseThenDeletesOnRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-delete-journal-lease-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let ownerID = UUID()
        let attachmentID = UUID()
        let reference = "shame-\(attachmentID.uuidString.lowercased()).jpg"
        let fileURL = directory.appendingPathComponent(reference)
        try Data("materialized-before-db-failure".utf8).write(to: fileURL)
        let output = ChekinanaMemoryMaterializedAttachment(
            ownerID: ownerID,
            libraryGeneration: generation,
            id: attachmentID,
            kind: .image,
            managedRef: reference
        )
        ChekinanaMemoryAttachmentLeaseRegistry.acquire(
            ownerID: ownerID,
            generation: generation,
            filenames: [reference]
        )
        defer { ChekinanaMemoryAttachmentLeaseRegistry.release(ownerID: ownerID) }
        _ = try XCTUnwrap(
            ChekinanaMemoryAttachmentDeletionCoordinator.prepareMaterializedRollback(
                output,
                in: context,
                directory: directory
            )
        )

        XCTAssertEqual(
            ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
                in: context,
                directory: directory
            ),
            1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        ChekinanaMemoryAttachmentLeaseRegistry.release(ownerID: ownerID)
        XCTAssertEqual(
            ChekinanaMemoryAttachmentDeletionCoordinator.recoverExclusively(
                in: context,
                directory: directory
            ),
            0
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEventAndIdolMemoryEntryPointsUseTheSharedRelationshipSafeEditor() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chekinana/ChekinanaProductShell.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let idolStart = try XCTUnwrap(source.range(of: "private struct ChekinanaIdolDetailView"))
        let eventStart = try XCTUnwrap(source.range(of: "private struct ChekinanaEventDetailView"))
        let memoryDetailStart = try XCTUnwrap(source.range(
            of: "private struct ChekinanaMemoryDetailView"
        ))
        let memoryEditorStart = try XCTUnwrap(source.range(
            of: "private struct ChekinanaMemoryEditor"
        ))
        let idolDetail = String(source[idolStart.lowerBound..<eventStart.lowerBound])
        let eventDetail = String(source[eventStart.lowerBound..<memoryDetailStart.lowerBound])
        let memoryDetail = String(
            source[memoryDetailStart.lowerBound..<memoryEditorStart.lowerBound]
        )

        XCTAssertTrue(idolDetail.contains("ChekinanaMemoryDetailView(memory: memory)"))
        XCTAssertTrue(eventDetail.contains("ChekinanaMemoryDetailView(memory: $0)"))
        XCTAssertTrue(memoryDetail.contains("ChekinanaMemoryEditor(memory: memory"))
    }

    func testMemoryLocalizationKeysAreReachableInEveryCatalogLanguage() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chekinana/Localizable.xcstrings")
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let keys = [
            "product.gallery.memory", "product.gallery.add.memory",
            "product.gallery.memory.empty", "product.gallery.memory.empty.message",
            "product.memory.content", "product.memory.title", "product.memory.body",
            "product.memory.body.empty",
            "product.memory.relationships", "product.memory.attachments",
            "product.memory.attachment.image", "product.memory.attachment.video",
            "product.memory.attachment.open_hint",
            "product.memory.attachment.unavailable",
            "product.memory.add.image", "product.memory.add.video",
            "product.memory.add", "product.memory.edit", "product.memory.delete",
            "product.memory.error",
        ]
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            XCTAssertEqual(Set(localizations.keys), ["en", "ja", "zh-Hans", "zh-Hant"], key)
        }
        let emptyBody = try XCTUnwrap(strings["product.memory.body.empty"] as? [String: Any])
        let emptyBodyLocalizations = try XCTUnwrap(
            emptyBody["localizations"] as? [String: Any]
        )
        let japanese = try XCTUnwrap(emptyBodyLocalizations["ja"] as? [String: Any])
        let japaneseUnit = try XCTUnwrap(japanese["stringUnit"] as? [String: Any])
        XCTAssertEqual(japaneseUnit["value"] as? String, "本文なし")
    }

    func testDataImportExportCatalogUsesProductKeyspaceInEveryLanguage() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chekinana/Localizable.xcstrings")
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
                as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let suffixes = [
            "settings.export",
            "settings.export.error.archive",
            "settings.export.error.missing_media",
            "settings.export.error.title",
            "settings.export.preparing",
            "settings.import",
            "settings.import.action",
            "settings.import.confirm.message",
            "settings.import.confirm.title",
            "settings.import.continue",
            "settings.import.error.archive",
            "settings.import.error.media",
            "settings.import.error.relationships",
            "settings.import.error.replace",
            "settings.import.error.title",
            "settings.import.error.version",
            "settings.import.final.message",
            "settings.import.final.title",
            "settings.import.importing",
            "settings.import.preparing",
            "settings.import.success",
            "settings.import.success.title",
        ]
        for suffix in suffixes {
            XCTAssertNil(strings[suffix], "Unprefixed duplicate remains: \(suffix)")
            let key = "product.\(suffix)"
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(
                Set(localizations.keys),
                ["en", "ja", "zh-Hans", "zh-Hant"],
                key
            )
        }
    }

    func testSettingsAlgorithmCatalogUsesProductKeyspaceInEveryLanguage() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chekinana/Localizable.xcstrings")
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
                as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let suffixes = [
            "settings.algorithms",
            "settings.algorithm.cheki_scan",
            "settings.algorithm.idol_recognition",
            "settings.algorithm.cheki_scan.notice.title",
            "settings.algorithm.cheki_scan.notice.message",
        ]
        for suffix in suffixes {
            XCTAssertNil(strings[suffix], "Unprefixed duplicate remains: \(suffix)")
            let key = "product.\(suffix)"
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(
                Set(localizations.keys),
                ["en", "ja", "zh-Hans", "zh-Hant"],
                key
            )
        }

        let notice = try XCTUnwrap(
            strings["product.settings.algorithm.cheki_scan.notice.message"]
                as? [String: Any]
        )
        let localizations = try XCTUnwrap(notice["localizations"] as? [String: Any])
        let simplifiedChinese = try XCTUnwrap(
            localizations["zh-Hans"] as? [String: Any]
        )
        let stringUnit = try XCTUnwrap(
            simplifiedChinese["stringUnit"] as? [String: Any]
        )
        XCTAssertEqual(
            stringUnit["value"] as? String,
            "当前算法的边缘精度尚有欠缺，处理重叠或不完整等复杂情形可能出错，但可以先凑合着用，也许哪天作者心情好还会再次升级"
        )
    }

    @MainActor
    func testMemoryExportIncludesOrderedAttachmentAndManagedFile() throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV16.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(title: " export ")
        let attachmentID = UUID()
        let onePixelPNG = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let reference = try ChekinanaGalleryMediaStore.saveImage(
            onePixelPNG, id: attachmentID, filenameExtension: "png"
        )
        defer {
            try? ChekinanaGalleryMediaStore.removeFiles(
                kind: .shame, id: attachmentID, reference: reference
            )
        }
        context.insert(memory)
        context.insert(MemoryAttachment(
            id: attachmentID, memoryID: memory.id, kind: .image,
            managedRef: reference, sortOrder: 3
        ))
        try context.save()
        let snapshot = try ChekinanaDataExportSnapshot.capture(in: context)
        let entities = try XCTUnwrap(snapshot.data["entities"] as? [String: [[String: Any]]])
        let exported = try XCTUnwrap(entities["MemoryAttachment"]?.first)
        XCTAssertEqual(exported["sortOrder"] as? Int, 3)
        XCTAssertEqual(exported["memoryID"] as? String, memory.id.uuidString.lowercased())
        XCTAssertEqual(snapshot.media.count, 1)
        XCTAssertEqual(snapshot.media.first?.ownerType, "MemoryAttachment")
        XCTAssertEqual(snapshot.media.first?.reference, reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(snapshot.media.first).url.path))
    }

    func testMemoryDatePolicyUsesPersistedContentBounds() throws {
        let minimum = ChekinanaPersistedContentDatePolicy.minimumCanonicalDate
        let maximum = ChekinanaPersistedContentDatePolicy.maximumCanonicalDate
        XCTAssertEqual(try ChekinanaMemoryPolicy.validatedDate(minimum), minimum)
        XCTAssertEqual(try ChekinanaMemoryPolicy.validatedDate(maximum), maximum)
        XCTAssertThrowsError(try ChekinanaMemoryPolicy.validatedDate(
            Calendar.current.date(byAdding: .day, value: -1, to: minimum)
        ))
        XCTAssertThrowsError(try ChekinanaMemoryPolicy.validatedDate(
            Calendar.current.date(byAdding: .day, value: 1, to: maximum)
        ))
    }

    func testMemoryRowCopyRules() {
        XCTAssertEqual(
            ChekinanaMemoryRowPresentation.copy(
                title: "Title",
                bodyText: nil,
                dateText: "2026-09-02",
                eventName: "Live",
                emptyBody: "No body text"
            ),
            .init(primary: "2026-09-02 · Title", secondary: "No body text")
        )
        XCTAssertEqual(
            ChekinanaMemoryRowPresentation.copy(
                title: nil, bodyText: "line 1\nline 2", dateText: "2026-09-02", eventName: "Live"
            ),
            .init(primary: "2026-09-02 · Live", secondary: "line 1\nline 2")
        )
        XCTAssertEqual(
            ChekinanaMemoryRowPresentation.copy(
                title: nil,
                bodyText: nil,
                dateText: nil,
                eventName: nil,
                noDate: "No date",
                memoryName: "Memory",
                emptyBody: "No body text"
            ),
            .init(primary: "No date", secondary: "No body text")
        )
        XCTAssertEqual(
            ChekinanaMemoryRowPresentation.copy(
                title: "Title", bodyText: nil, dateText: "2026-09-02", eventName: "Live",
                attachmentSummary: "Images: 2 · Videos: 1"
            ),
            .init(primary: "2026-09-02 · Title", secondary: "Images: 2 · Videos: 1")
        )
    }

    func testMemoryRowsOpenViewerAndEditorUsesDateScopedEvents() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chekinana/ChekinanaProductShell.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let rowStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaMemoryRow:")?.lowerBound
        )
        let rowEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaMemoryListView:",
            range: rowStart..<source.endIndex
        )?.lowerBound)
        let row = String(source[rowStart..<rowEnd])
        XCTAssertTrue(row.contains("emptyBody: ChekinanaProductCopy.text("))
        XCTAssertTrue(row.contains("\"memory.body.empty\""))
        XCTAssertTrue(row.contains(".frame(width: 36, alignment: .leading)"))

        let detailStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaMemoryDetailView:")?.lowerBound
        )
        let previewStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaMemoryAttachmentPreview:")?
                .lowerBound
        )
        let attachmentPreview = String(source[previewStart..<detailStart])
        XCTAssertTrue(attachmentPreview.contains("ChekinanaPlaybackVideoPlayer("))
        XCTAssertTrue(attachmentPreview.contains("asset.load(.isPlayable)"))
        XCTAssertTrue(attachmentPreview.contains("replaceCurrentItem(with: nil)"))
        XCTAssertTrue(attachmentPreview.contains(
            "thumbnailReference(id: selection.id)"
        ))
        XCTAssertTrue(attachmentPreview.contains("videoThumbnailImage("))
        XCTAssertFalse(attachmentPreview.contains(
            "guard selection.kind == .image else { return }"
        ))
        let editorStart = try XCTUnwrap(source.range(
            of: "private struct ChekinanaMemoryEditor:",
            range: detailStart..<source.endIndex
        )?.lowerBound)
        let detail = String(source[detailStart..<editorStart])
        XCTAssertTrue(detail.contains("ChekinanaMemoryAttachmentPreview(selection:"))
        XCTAssertTrue(detail.contains("ChekinanaMemoryEditor(memory: memory, onDeleted:"))
        XCTAssertTrue(detail.contains("chekinana.memory.detail.attachment."))

        let editorEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaGalleryCompactFilterLabel",
            range: editorStart..<source.endIndex
        )?.lowerBound)
        let editor = String(source[editorStart..<editorEnd])
        let dateToggle = try XCTUnwrap(editor.range(
            of: "Toggle(ChekinanaProductCopy.text(\"common.include_date\""
        )?.lowerBound)
        let eventField = try XCTUnwrap(editor.range(
            of: "ChekinanaChekiEventSelectionField("
        )?.lowerBound)
        XCTAssertLessThan(dateToggle, eventField)
        XCTAssertTrue(editor.contains("recordDate: draftCanonicalDate"))
        XCTAssertTrue(editor.contains("primaryScope: .exactDate"))
        XCTAssertFalse(editor.contains(
            "Picker(ChekinanaProductCopy.text(\"common.event\""
        ))
    }

    func testIdolListAndDetailHideRecognitionPatternStatus() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chekinana/ChekinanaProductShell.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let rowStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaIdolRow:")?.lowerBound
        )
        let rowEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaIdolAvatar:",
            range: rowStart..<source.endIndex
        )?.lowerBound)
        let row = String(source[rowStart..<rowEnd])
        XCTAssertFalse(row.contains("ChekinanaIdolPatternStatus.make"))
        XCTAssertFalse(row.contains("hasRecognitionPatterns"))

        let detailStart = try XCTUnwrap(
            source.range(of: "private struct ChekinanaIdolDetailView:")?.lowerBound
        )
        let detailEnd = try XCTUnwrap(source.range(
            of: "private struct ChekinanaIdolLinkedEventsView:",
            range: detailStart..<source.endIndex
        )?.lowerBound)
        let detail = String(source[detailStart..<detailEnd])
        XCTAssertFalse(detail.contains("\"idols.recognition\""))
        XCTAssertFalse(detail.contains("recognitionPatterns.count"))
    }

    @MainActor
    func testMemoryAndOrderedAttachmentsPersistIndependentlyFromMediaItem() throws {
        let container = try ModelContainer(
            for: Schema(ChekinanaSchemaV15.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let memory = Memory(bodyText: "a\n\nb")
        let second = MemoryAttachment(
            memoryID: memory.id,
            kind: .video,
            managedRef: "douga-\(UUID().uuidString.lowercased()).mov",
            sortOrder: 1
        )
        let first = MemoryAttachment(
            memoryID: memory.id,
            kind: .image,
            managedRef: "shame-\(UUID().uuidString.lowercased()).jpg",
            sortOrder: 0
        )
        context.insert(memory); context.insert(second); context.insert(first)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MemoryAttachment>())
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(fetched.map(\.kind), [.image, .video])
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Memory>()).first?.bodyText, "a\n\nb")
    }

    @MainActor
    func testV14ToV15MemoryMigrationPreservesExistingRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.sqlite")
        do {
            let schema = Schema(versionedSchema: ChekinanaSchemaV14.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: store)
            )
            let context = ModelContext(container)
            context.insert(Idol(name: "Existing"))
            try context.save()
        }
        let schema = Schema(versionedSchema: ChekinanaSchemaV15.self)
        let migrated = try ModelContainer(
            for: schema,
            migrationPlan: ChekinanaV14ToV15MemoryTestMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: store)
        )
        let context = ModelContext(migrated)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Idol>()).map(\.name), ["Existing"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).isEmpty)
    }

    @MainActor
    func testExportedBackupValidatesThenRestoresEveryV17ExportEntityTypeAndAvatarIntent() async throws {
        let schema = Schema(ChekinanaSchemaV17.models)
        let sourceContainer = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let source = ModelContext(sourceContainer)
        let idol = Idol(name: "Imported Idol", patterns: [[0.25, 0.5]])
        let event = Event(
            name: "Imported Event",
            date: ChekinanaPersistedContentDatePolicy.minimumCanonicalDate,
            weiboURL: URL(string: "https://m.weibo.cn/status/fixture")
        )
        let customSize = CustomChekiSize(
            name: "Square",
            widthRatio: 1,
            heightRatio: 1,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let memory = Memory(
            title: "Imported Memory",
            bodyText: "line one\nline two",
            date: ChekinanaPersistedContentDatePolicy.minimumCanonicalDate,
            eventID: event.id,
            idolIDs: [idol.id]
        )
        let directory = try ChekiImageRefResolver.chekiImagesDirectory()
        let pixel = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let eventImageRef = "event-import-test-\(UUID().uuidString.lowercased()).png"
        let eventImageURL = directory.appendingPathComponent(eventImageRef)
        try pixel.write(to: eventImageURL, options: .atomic)
        let mediaOwnerID = UUID()
        let chekiRef = "\(mediaOwnerID.uuidString.lowercased()).png"
        let chekiURL = directory.appendingPathComponent(chekiRef)
        try pixel.write(to: chekiURL, options: .atomic)
        let attachmentID = UUID()
        let attachmentRef = try ChekinanaGalleryMediaStore.saveImage(
            pixel,
            id: attachmentID,
            filenameExtension: "png"
        )
        defer {
            try? FileManager.default.removeItem(at: eventImageURL)
            try? FileManager.default.removeItem(at: chekiURL)
            try? ChekinanaGalleryMediaStore.removeFiles(
                kind: .shame,
                id: attachmentID,
                reference: attachmentRef
            )
        }

        source.insert(idol)
        let avatarState = IdolAvatarState(
            idolID: idol.id,
            source: .none,
            intent: .explicitlyRemoved
        )
        source.insert(avatarState)
        let patternState = IdolPatternState(
            idolID: idol.id,
            encoderVersion: "test-encoder",
            cataloguePatternIDs: ["p1"],
            cataloguePatternCount: 1
        )
        source.insert(patternState)
        event.source = .weibo
        source.insert(event)
        source.insert(customSize)
        let schedule = EventSchedule(eventID: event.id, openTime: "12:00", startTime: "13:00")
        source.insert(schedule)
        let eventImage = EventImage(eventID: event.id, imageRef: eventImageRef, sortOrder: 0)
        source.insert(eventImage)
        let groupOrder = CalendarGroupOrder(
            dateKey: ChekinanaDateOnly.string(ChekinanaPersistedContentDatePolicy.minimumCanonicalDate),
            groupKey: ChekinanaIdolCombinationKey([idol.id]).id,
            sortOrder: 0
        )
        source.insert(groupOrder)
        let travel = TravelSegment(
            mode: .train,
            serviceNumber: "T1",
            departureCity: "A",
            departureLocation: "A1",
            arrivalCity: "B",
            arrivalLocation: "B1",
            departureTime: Date(timeIntervalSince1970: 1_800_000_000),
            arrivalTime: Date(timeIntervalSince1970: 1_800_003_600)
        )
        source.insert(travel)
        let mediaItem = MediaItem(
            mediaOwnerID: mediaOwnerID,
            kind: .cheki,
            idols: [idol],
            event: event,
            date: ChekinanaPersistedContentDatePolicy.minimumCanonicalDate,
            size: customSize.size,
            mediaRef: chekiRef
        )
        source.insert(mediaItem)
        let record = ChekiRecord(
            idols: [idol],
            event: event,
            date: ChekinanaPersistedContentDatePolicy.minimumCanonicalDate,
            size: customSize.size,
            count: 2
        )
        source.insert(record)
        source.insert(memory)
        let attachment = MemoryAttachment(
            id: attachmentID,
            memoryID: memory.id,
            kind: .image,
            managedRef: attachmentRef,
            sortOrder: 0
        )
        source.insert(attachment)
        try source.save()

        let archive = try await ChekinanaDataExporter.archiveURL(
            for: ChekinanaDataExportSnapshot.capture(in: source)
        )
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: archive) }
        let prepared = try await ChekinanaDataImporter.prepare(from: archive)
        defer { ChekinanaDataImportTemporaryFiles.cleanup(prepared) }
        XCTAssertEqual(prepared.payload.entities.counts.values.reduce(0, +), 12)

        let targetContainer = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let target = ModelContext(targetContainer)
        target.insert(Idol(id: idol.id, name: "Existing value with same stable ID"))
        target.insert(Idol(name: "Existing data to remove"))
        try target.save()
        try await ChekinanaDataImporter.replaceLocalLibrary(with: prepared, in: target)

        let restoredIdols = try target.fetch(FetchDescriptor<Idol>())
        XCTAssertEqual(restoredIdols.map(\.id), [idol.id])
        XCTAssertEqual(restoredIdols.map(\.name), ["Imported Idol"])
        let restoredAvatarState = try ChekinanaIdolAvatarStatePersistence.snapshot(
            for: idol.id,
            in: target
        )
        XCTAssertEqual(restoredAvatarState.source, .none)
        XCTAssertEqual(restoredAvatarState.intent, .explicitlyRemoved)
        XCTAssertEqual(try target.fetch(FetchDescriptor<IdolPatternState>()).map(\.idolID), [patternState.idolID])
        let restoredEvents = try target.fetch(FetchDescriptor<Event>())
        XCTAssertEqual(restoredEvents.map(\.id), [event.id])
        XCTAssertEqual(restoredEvents.first?.source, .weibo)
        XCTAssertEqual(
            restoredEvents.first?.date.map(ChekinanaDateOnly.string),
            ChekinanaDateOnly.string(
                ChekinanaPersistedContentDatePolicy.minimumCanonicalDate
            )
        )
        let restoredCustomSizes = try target.fetch(FetchDescriptor<CustomChekiSize>())
        XCTAssertEqual(restoredCustomSizes.map(\.id), [customSize.id])
        XCTAssertEqual(restoredCustomSizes.first?.name, "Square")
        XCTAssertEqual(restoredCustomSizes.first?.pixelWidth, 1_200)
        XCTAssertEqual(restoredCustomSizes.first?.pixelHeight, 1_200)
        XCTAssertEqual(try target.fetch(FetchDescriptor<EventSchedule>()).map(\.eventID), [schedule.eventID])
        XCTAssertEqual(try target.fetch(FetchDescriptor<EventImage>()).map(\.id), [eventImage.id])
        let restoredOrders = try target.fetch(FetchDescriptor<CalendarGroupOrder>())
            .filter { !ChekinanaLibraryGenerationStore.isMarker($0) }
        XCTAssertEqual(restoredOrders.map(\.id), [groupOrder.id])
        XCTAssertEqual(restoredOrders.map(\.groupKey), [groupOrder.groupKey])
        XCTAssertNotNil(try ChekinanaLibraryGenerationStore.current(in: target))
        XCTAssertEqual(try target.fetch(FetchDescriptor<TravelSegment>()).map(\.id), [travel.id])
        let restoredMedia = try target.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(restoredMedia.map(\.id), [mediaItem.id])
        XCTAssertEqual(restoredMedia.map(\.mediaOwnerID), [mediaOwnerID])
        XCTAssertEqual(restoredMedia.first?.sizeRawValue, customSize.size.rawValue)
        XCTAssertEqual(
            restoredMedia.first?.date.map(ChekinanaDateOnly.string),
            ChekinanaDateOnly.string(
                ChekinanaPersistedContentDatePolicy.minimumCanonicalDate
            )
        )
        let restoredRecords = try target.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(restoredRecords.map(\.id), [record.id])
        XCTAssertEqual(restoredRecords.first?.count, 2)
        XCTAssertEqual(
            restoredRecords.first?.sizeRawValue,
            customSize.size.rawValue
        )
        XCTAssertEqual(
            restoredRecords.first?.date.map(ChekinanaDateOnly.string),
            ChekinanaDateOnly.string(
                ChekinanaPersistedContentDatePolicy.minimumCanonicalDate
            )
        )
        let restoredMemories = try target.fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(restoredMemories.map(\.id), [memory.id])
        XCTAssertEqual(restoredMemories.first?.bodyText, "line one\nline two")
        XCTAssertEqual(
            restoredMemories.first?.date.map(ChekinanaDateOnly.string),
            ChekinanaDateOnly.string(
                ChekinanaPersistedContentDatePolicy.minimumCanonicalDate
            )
        )
        XCTAssertEqual(try target.fetch(FetchDescriptor<MemoryAttachment>()).map(\.id), [attachment.id])
    }

    func testImportRejectsMediaCRCMismatchBeforePreparingReplacement() async throws {
        let fixture = try makeManualBackup(includeMedia: true)
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: fixture.url) }
        var archive = try Data(contentsOf: fixture.url)
        let payloadRange = try XCTUnwrap(archive.range(of: fixture.mediaBytes))
        archive[payloadRange.lowerBound] ^= 0xff
        try archive.write(to: fixture.url, options: .atomic)

        do {
            _ = try await ChekinanaDataImporter.prepare(from: fixture.url)
            XCTFail("A stored entry with a bad CRC must be rejected")
        } catch {
            XCTAssertEqual(error as? ChekinanaDataImportError, .mediaIntegrity)
        }
    }

    func testImportRejectsManifestSHAAndBrokenRelationships() async throws {
        let badSHA = try makeManualBackup(includeMedia: true, manifestSHA256: String(repeating: "0", count: 64))
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: badSHA.url) }
        do {
            _ = try await ChekinanaDataImporter.prepare(from: badSHA.url)
            XCTFail("Manifest SHA drift must be rejected")
        } catch {
            XCTAssertEqual(error as? ChekinanaDataImportError, .mediaIntegrity)
        }

        let unknownIdolID = UUID().uuidString.lowercased()
        var entities = emptyImportEntities()
        entities["ChekiRecord"] = [[
            "id": UUID().uuidString.lowercased(),
            "idolIDs": [unknownIdolID],
            "eventID": NSNull(),
            "date": NSNull(),
            "size": "mini",
            "note": "",
            "count": 1,
        ]]
        let badRelationship = try makeManualBackup(entities: entities)
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: badRelationship.url) }
        do {
            _ = try await ChekinanaDataImporter.prepare(from: badRelationship.url)
            XCTFail("Dangling relationship IDs must be rejected")
        } catch {
            XCTAssertEqual(error as? ChekinanaDataImportError, .invalidRelationships)
        }
    }

    func testImportRejectsCustomSizeBeyondSafeCanvasLimit() async throws {
        let now = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: 1_800_000_000)
        )
        var entities = emptyImportEntities()
        entities["CustomChekiSize"] = [[
            "id": UUID().uuidString.lowercased(),
            "name": "Unsafe",
            "widthRatio": 8_193,
            "heightRatio": 1_200,
            "pixelWidth": 8_193,
            "pixelHeight": 1_200,
            "createdAt": now,
        ]]
        let fixture = try makeManualBackup(
            entities: entities,
            schemaVersion: "16.0.0"
        )
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: fixture.url) }

        do {
            _ = try await ChekinanaDataImporter.prepare(from: fixture.url)
            XCTFail("An oversized custom canvas must be rejected before replacement")
        } catch {
            XCTAssertEqual(error as? ChekinanaDataImportError, .invalidArchive)
        }
    }

    @MainActor
    func testV16BackupWithoutAvatarStateImportsCompatibilityDefault() async throws {
        let idolID = UUID()
        let now = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: 1_800_000_000)
        )
        var entities = emptyImportEntities()
        entities["CustomChekiSize"] = []
        entities["Idol"] = [[
            "id": idolID.uuidString.lowercased(),
            "sourceId": "legacy-catalogue-id",
            "name": "Legacy Backup Idol",
            "group": NSNull(),
            "color": NSNull(),
            "birthday": NSNull(),
            "avatarImageRef": NSNull(),
            "isFavorite": false,
            "sortOrder": NSNull(),
            "note": "",
            "createdAt": now,
            "updatedAt": now,
            "verification": NSNull(),
            "bio": NSNull(),
            "pattern": NSNull(),
            "patterns": [],
        ]]
        let fixture = try makeManualBackup(
            entities: entities,
            schemaVersion: "16.0.0"
        )
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: fixture.url) }
        let prepared = try await ChekinanaDataImporter.prepare(from: fixture.url)
        defer { ChekinanaDataImportTemporaryFiles.cleanup(prepared) }
        let schema = Schema(ChekinanaSchemaV17.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        try await ChekinanaDataImporter.replaceLocalLibrary(
            with: prepared,
            in: context
        )

        XCTAssertNil(try context.fetch(FetchDescriptor<Idol>()).first?.avatarImageRef)
        XCTAssertEqual(
            try ChekinanaIdolAvatarStatePersistence.snapshot(
                for: idolID,
                in: context
            ),
            ChekinanaIdolAvatarStateSnapshot(
                source: .legacyUnknown,
                intent: .unspecified,
                revision: try XCTUnwrap(
                    ChekinanaIdolAvatarStatePersistence.state(
                        for: idolID,
                        in: context
                    )?.revision
                )
            )
        )
    }

    func testV17BackupRejectsInvalidAvatarStateField() async throws {
        let now = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: 1_800_000_000)
        )
        var entities = emptyImportEntities()
        entities["CustomChekiSize"] = []
        entities["Idol"] = [[
            "id": UUID().uuidString.lowercased(),
            "sourceId": NSNull(),
            "name": "Invalid Avatar State",
            "group": NSNull(),
            "color": NSNull(),
            "birthday": NSNull(),
            "avatarImageRef": NSNull(),
            "avatarSource": "not-a-source",
            "avatarIntent": "explicitlyRemoved",
            "isFavorite": false,
            "sortOrder": NSNull(),
            "note": "",
            "createdAt": now,
            "updatedAt": now,
            "verification": NSNull(),
            "bio": NSNull(),
            "pattern": NSNull(),
            "patterns": [],
        ]]
        let fixture = try makeManualBackup(
            entities: entities,
            schemaVersion: "17.0.0"
        )
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: fixture.url) }

        do {
            _ = try await ChekinanaDataImporter.prepare(from: fixture.url)
            XCTFail("An invalid current avatar state must be rejected.")
        } catch {
            XCTAssertEqual(error as? ChekinanaDataImportError, .invalidArchive)
        }
    }

    func testImportRejectsTrailingGarbageAndCentralDirectoryDrift() async throws {
        let trailing = try makeManualBackup()
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: trailing.url) }
        var trailingBytes = try Data(contentsOf: trailing.url)
        trailingBytes.append(0xaa)
        try trailingBytes.write(to: trailing.url, options: .atomic)
        XCTAssertThrowsError(try ChekinanaStoredBackupReader.extract(trailing.url))

        let central = try makeManualBackup()
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: central.url) }
        var centralBytes = try Data(contentsOf: central.url)
        let centralSignature = Data([0x50, 0x4b, 0x01, 0x02])
        let centralOffset = try XCTUnwrap(centralBytes.range(of: centralSignature)).lowerBound
        centralBytes[centralOffset + 42] ^= 0x01
        try centralBytes.write(to: central.url, options: .atomic)
        XCTAssertThrowsError(try ChekinanaStoredBackupReader.extract(central.url))
    }

    func testZIP64LocatorAndEndRecordAreValidatedAgainstCentralDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip64-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backup.chekinana")
        let entries = [
            ("data.json", Data("{}".utf8)),
            ("settings.json", Data("{}".utf8)),
            ("manifest.json", Data("{}".utf8)),
        ]
        let valid = zip64StoredArchive(entries)
        try valid.write(to: url)
        let extracted = try ChekinanaStoredBackupReader.extract(url)
        let extractedRoot = extracted.values.first?.url.deletingLastPathComponent()
        defer { if let extractedRoot { try? FileManager.default.removeItem(at: extractedRoot) } }
        XCTAssertEqual(Set(extracted.keys), Set(entries.map { $0.0 }))

        var broken = valid
        let eocd = try XCTUnwrap(broken.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards)).lowerBound
        broken.replaceUInt64LE(at: eocd - 12, with: 1)
        try broken.write(to: url, options: .atomic)
        XCTAssertThrowsError(try ChekinanaStoredBackupReader.extract(url))
    }

    @MainActor
    func testImportSaveFailureRollsBackAndKeepsExistingLibrary() async throws {
        enum Injected: Error { case save }
        let languageStore = ChekinanaLanguageStore.shared
        let themeStore = ChekinanaThemeStore.shared
        let hiddenStore = ChekinanaHiddenIdolStore.shared
        let previousLanguage = languageStore.language
        let previousTheme = themeStore.theme
        let previousHidden = hiddenStore.hiddenIDs
        defer {
            languageStore.language = previousLanguage
            themeStore.theme = previousTheme
            hiddenStore.clear()
            previousHidden.forEach(hiddenStore.hide)
        }
        let schema = Schema(ChekinanaSchemaV16.models)
        let sourceContainer = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let source = ModelContext(sourceContainer)
        let sourceIdol = Idol(name: "Backup Idol")
        let sourceOwnerID = UUID()
        let sourceRef = "\(sourceOwnerID.uuidString.lowercased()).png"
        let directory = try ChekiImageRefResolver.chekiImagesDirectory()
        let sourceURL = directory.appendingPathComponent(sourceRef)
        let sourceBytes = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try sourceBytes.write(to: sourceURL, options: .atomic)
        source.insert(sourceIdol)
        source.insert(MediaItem(
            mediaOwnerID: sourceOwnerID,
            kind: .cheki,
            idols: [sourceIdol],
            size: .mini,
            mediaRef: sourceRef
        ))
        try source.save()
        languageStore.language = .japanese
        themeStore.theme = .red
        hiddenStore.clear()
        hiddenStore.hide(sourceIdol.id)
        let archive = try await ChekinanaDataExporter.archiveURL(
            for: ChekinanaDataExportSnapshot.capture(in: source)
        )
        defer { ChekinanaExportTemporaryFiles.cleanupArchive(at: archive) }
        let prepared = try await ChekinanaDataImporter.prepare(from: archive)
        defer { ChekinanaDataImportTemporaryFiles.cleanup(prepared) }

        let targetContainer = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let target = ModelContext(targetContainer)
        let targetIdol = Idol(name: "Keep me")
        let targetOwnerID = UUID()
        let targetRef = "\(targetOwnerID.uuidString.lowercased()).png"
        let targetURL = directory.appendingPathComponent(targetRef)
        let targetBytes = Data("existing-media-must-survive".utf8)
        try targetBytes.write(to: targetURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        target.insert(targetIdol)
        target.insert(MediaItem(
            mediaOwnerID: targetOwnerID,
            kind: .cheki,
            idols: [targetIdol],
            size: .mini,
            mediaRef: targetRef
        ))
        try target.save()
        languageStore.language = .simplifiedChinese
        themeStore.theme = .blue
        hiddenStore.clear()
        hiddenStore.hide(targetIdol.id)
        do {
            try await ChekinanaDataImporter.replaceLocalLibrary(
                with: prepared,
                in: target,
                saveContext: { _ in throw Injected.save }
            )
            XCTFail("The injected save error must fail the replacement")
        } catch {
            XCTAssertEqual(error as? ChekinanaDataImportError, .replacementFailed)
        }
        XCTAssertEqual(try target.fetch(FetchDescriptor<Idol>()).map(\.name), ["Keep me"])
        XCTAssertEqual(try target.fetch(FetchDescriptor<MediaItem>()).map(\.mediaOwnerID), [targetOwnerID])
        XCTAssertEqual(try Data(contentsOf: targetURL), targetBytes)
        XCTAssertEqual(languageStore.language, .simplifiedChinese)
        XCTAssertEqual(themeStore.theme, .blue)
        XCTAssertEqual(hiddenStore.hiddenIDs, Set([targetIdol.id]))
    }

    private struct ManualBackup {
        let url: URL
        let mediaBytes: Data
    }

    private func emptyImportEntities() -> [String: [[String: Any]]] {
        [
            "Idol": [],
            "IdolPatternState": [],
            "Event": [],
            "EventSchedule": [],
            "EventImage": [],
            "CalendarGroupOrder": [],
            "TravelSegment": [],
            "MediaItem": [],
            "ChekiRecord": [],
            "Memory": [],
            "MemoryAttachment": [],
        ]
    }

    private func makeManualBackup(
        entities suppliedEntities: [String: [[String: Any]]]? = nil,
        includeMedia: Bool = false,
        manifestSHA256: String? = nil,
        schemaVersion: String = "15.0.0"
    ) throws -> ManualBackup {
        var entities = suppliedEntities ?? emptyImportEntities()
        let mediaBytes = Data("manual-backup-media".utf8)
        var mediaManifest: [[String: Any]] = []
        var mediaEntries: [ChekinanaStreamingZIP.Entry] = []
        if includeMedia {
            let idolID = UUID()
            let mediaID = UUID()
            let mediaOwnerID = UUID()
            let reference = "\(mediaOwnerID.uuidString.lowercased()).png"
            let now = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000))
            entities["Idol"] = [[
                "id": idolID.uuidString.lowercased(),
                "sourceId": NSNull(),
                "name": "Fixture Idol",
                "group": NSNull(),
                "color": NSNull(),
                "birthday": NSNull(),
                "avatarImageRef": NSNull(),
                "isFavorite": false,
                "sortOrder": NSNull(),
                "note": "",
                "createdAt": now,
                "updatedAt": now,
                "verification": NSNull(),
                "bio": NSNull(),
                "pattern": NSNull(),
                "patterns": [],
            ]]
            entities["MediaItem"] = [[
                "id": mediaID.uuidString.lowercased(),
                "mediaOwnerID": mediaOwnerID.uuidString.lowercased(),
                "kind": "cheki",
                "idolIDs": [idolID.uuidString.lowercased()],
                "eventID": NSNull(),
                "date": NSNull(),
                "userAppears": false,
                "isFavorite": false,
                "hasPostedToSNS": false,
                "note": "",
                "mediaRef": reference,
                "size": "mini",
                "idx": NSNull(),
                "createdAt": now,
                "updatedAt": now,
            ]]
            let inspection = ChekinanaStreamingZIP.inspect(mediaBytes)
            let archivePath = "media/000001.png"
            mediaManifest = [[
                "archivePath": archivePath,
                "ownerType": "MediaItem",
                "ownerID": mediaID.uuidString.lowercased(),
                "originalReference": reference,
                "byteCount": inspection.size,
                "sha256": manifestSHA256 ?? inspection.sha256,
                "crc32": Int64(inspection.crc32),
            ]]
            mediaEntries = [.data(archivePath, mediaBytes)]
        }
        let counts = entities.mapValues(\.count)
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion,
            "entities": entities,
        ])
        let settings = try JSONSerialization.data(withJSONObject: [
            ChekinanaLanguagePreference.defaultsKey: ChekinanaAppLanguage.system.rawValue,
            ChekinanaThemePreference.defaultsKey: ChekinanaThemeOption.purple.rawValue,
            ChekinanaHiddenIdolPersistence.defaultsKey: [],
        ])
        let manifest = try JSONSerialization.data(withJSONObject: [
            "format": "chekinana-backup",
            "exportVersion": 1,
            "schemaVersion": schemaVersion,
            "entityCounts": counts,
            "media": mediaManifest,
        ])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("backup.chekinana")
        try ChekinanaStreamingZIP.write(
            [.data("data.json", data), .data("settings.json", settings)]
                + mediaEntries
                + [.data("manifest.json", manifest)],
            to: url
        )
        return ManualBackup(url: url, mediaBytes: mediaBytes)
    }

    private func zip64StoredArchive(_ entries: [(String, Data)]) -> Data {
        struct CentralValue {
            let name: Data
            let payload: Data
            let crc32: UInt32
            let localOffset: UInt64
        }
        var archive = Data()
        var centralValues: [CentralValue] = []
        for (nameValue, payload) in entries {
            let name = Data(nameValue.utf8)
            let crc = independentCRC32(payload)
            let offset = UInt64(archive.count)
            var extra = Data()
            extra.appendUInt16LE(0x0001)
            extra.appendUInt16LE(16)
            extra.appendUInt64LE(UInt64(payload.count))
            extra.appendUInt64LE(UInt64(payload.count))
            archive.appendUInt32LE(0x04034b50)
            archive.appendUInt16LE(45)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(crc)
            archive.appendUInt32LE(.max)
            archive.appendUInt32LE(.max)
            archive.appendUInt16LE(UInt16(name.count))
            archive.appendUInt16LE(UInt16(extra.count))
            archive.append(name)
            archive.append(extra)
            archive.append(payload)
            centralValues.append(CentralValue(
                name: name,
                payload: payload,
                crc32: crc,
                localOffset: offset
            ))
        }
        let centralOffset = UInt64(archive.count)
        for value in centralValues {
            var extra = Data()
            extra.appendUInt16LE(0x0001)
            extra.appendUInt16LE(24)
            extra.appendUInt64LE(UInt64(value.payload.count))
            extra.appendUInt64LE(UInt64(value.payload.count))
            extra.appendUInt64LE(value.localOffset)
            archive.appendUInt32LE(0x02014b50)
            archive.appendUInt16LE(45)
            archive.appendUInt16LE(45)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(value.crc32)
            archive.appendUInt32LE(.max)
            archive.appendUInt32LE(.max)
            archive.appendUInt16LE(UInt16(value.name.count))
            archive.appendUInt16LE(UInt16(extra.count))
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(0)
            archive.appendUInt32LE(.max)
            archive.append(value.name)
            archive.append(extra)
        }
        let centralSize = UInt64(archive.count) - centralOffset
        let recordOffset = UInt64(archive.count)
        archive.append(ChekinanaStreamingZIP.zip64EndRecord(
            entryCount: UInt64(entries.count),
            centralSize: centralSize,
            centralOffset: centralOffset
        ))
        archive.appendUInt32LE(0x07064b50)
        archive.appendUInt32LE(0)
        archive.appendUInt64LE(recordOffset)
        archive.appendUInt32LE(1)
        archive.appendUInt32LE(0x06054b50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(.max)
        archive.appendUInt16LE(.max)
        archive.appendUInt32LE(.max)
        archive.appendUInt32LE(.max)
        archive.appendUInt16LE(0)
        return archive
    }

    func testImportTransactionJournalsBeforeFirstMoveAndRecoversPartialStage() throws {
        enum Injected: Error { case secondMove }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "backup-transaction-stage-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.jpg")
        let second = directory.appendingPathComponent("second.jpg")
        let firstBytes = Data("old-first".utf8)
        let secondBytes = Data("old-second".utf8)
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)
        let oldGeneration = UUID()
        let transaction = try ChekinanaImportTransactionHandle.create(
            in: directory,
            oldGeneration: oldGeneration,
            newGeneration: UUID(),
            language: .system,
            theme: .purple,
            hiddenIdolIDs: [],
            preexistingFiles: [first, second]
        )

        XCTAssertTrue(fileManager.fileExists(atPath: transaction.journalURL.path))
        XCTAssertEqual(try transaction.load().phase, .stagingOld)
        var moveCount = 0
        XCTAssertThrowsError(try transaction.stageOldFiles(moveItem: { source, destination in
            moveCount += 1
            if moveCount == 2 { throw Injected.secondMove }
            try fileManager.moveItem(at: source, to: destination)
        })) { error in
            XCTAssertEqual(error as? ChekinanaImportTransactionError, .incomplete)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: transaction.journalURL.path))

        XCTAssertEqual(
            try transaction.recover(currentGeneration: oldGeneration),
            .restoreOld
        )
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
        XCTAssertFalse(fileManager.fileExists(atPath: transaction.rootDirectory.path))
    }

    func testImportTransactionUsesHashesForSameFilenameAcrossGenerations() throws {
        enum Injected: Error { case discard }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "backup-transaction-same-name-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let filename = "same-uuid.jpg"
        let destination = directory.appendingPathComponent(filename)
        let oldBytes = Data("old-generation-bytes".utf8)
        let newBytes = Data("new-generation-bytes".utf8)
        try oldBytes.write(to: destination)
        let oldGeneration = UUID()
        let firstNewGeneration = UUID()
        let rollbackTransaction = try ChekinanaImportTransactionHandle.create(
            in: directory,
            oldGeneration: oldGeneration,
            newGeneration: firstNewGeneration,
            language: .system,
            theme: .purple,
            hiddenIdolIDs: [],
            preexistingFiles: [destination]
        )
        try rollbackTransaction.stageOldFiles()
        let created = ChekinanaImportTransactionJournal.CreatedFile(
            filename: filename,
            identity: ChekinanaImportFileIdentity(newBytes)
        )
        try rollbackTransaction.reserveCreatedFiles([created])
        XCTAssertEqual(try rollbackTransaction.load().createdFiles, [created])
        try rollbackTransaction.materialize(newBytes, as: filename)
        XCTAssertEqual(try Data(contentsOf: destination), newBytes)

        XCTAssertEqual(
            try rollbackTransaction.recover(currentGeneration: oldGeneration),
            .restoreOld
        )
        XCTAssertEqual(try Data(contentsOf: destination), oldBytes)

        let committedGeneration = UUID()
        let commitTransaction = try ChekinanaImportTransactionHandle.create(
            in: directory,
            oldGeneration: oldGeneration,
            newGeneration: committedGeneration,
            language: .system,
            theme: .purple,
            hiddenIdolIDs: [],
            preexistingFiles: [destination]
        )
        try commitTransaction.stageOldFiles()
        try commitTransaction.reserveCreatedFiles([created])
        try commitTransaction.materialize(newBytes, as: filename)
        XCTAssertThrowsError(try commitTransaction.recover(
            currentGeneration: committedGeneration,
            removeItem: { url in
                if url.deletingLastPathComponent().standardizedFileURL
                    == commitTransaction.rollbackDirectory.standardizedFileURL {
                    throw Injected.discard
                }
                try fileManager.removeItem(at: url)
            }
        )) {
            XCTAssertEqual($0 as? ChekinanaImportTransactionError, .incomplete)
        }
        XCTAssertEqual(try Data(contentsOf: destination), newBytes)
        XCTAssertTrue(fileManager.fileExists(atPath: commitTransaction.journalURL.path))
        XCTAssertEqual(
            try commitTransaction.recover(currentGeneration: committedGeneration),
            .completeNew
        )
        XCTAssertEqual(try Data(contentsOf: destination), newBytes)
        XCTAssertFalse(fileManager.fileExists(atPath: commitTransaction.rootDirectory.path))
    }

    func testImportRecoveryPreservesOccupiedDestinationAndRetriesMoveFailure() throws {
        enum Injected: Error { case restoreMove }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "backup-transaction-conflict-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("occupied.jpg")
        let oldBytes = Data("only-old-copy".utf8)
        let occupantBytes = Data("unrelated-occupant".utf8)
        try oldBytes.write(to: destination)
        let oldGeneration = UUID()
        let transaction = try ChekinanaImportTransactionHandle.create(
            in: directory,
            oldGeneration: oldGeneration,
            newGeneration: UUID(),
            language: .system,
            theme: .purple,
            hiddenIdolIDs: [],
            preexistingFiles: [destination]
        )
        try transaction.stageOldFiles()
        let oldRecord = try XCTUnwrap(transaction.load().oldFiles.first)
        let rollback = transaction.rollbackDirectory.appendingPathComponent(
            oldRecord.rollbackName
        )
        try occupantBytes.write(to: destination)

        XCTAssertThrowsError(try transaction.recover(currentGeneration: oldGeneration)) {
            XCTAssertEqual($0 as? ChekinanaImportTransactionError, .indeterminate)
        }
        XCTAssertEqual(try Data(contentsOf: destination), occupantBytes)
        XCTAssertEqual(try Data(contentsOf: rollback), oldBytes)
        XCTAssertTrue(fileManager.fileExists(atPath: transaction.journalURL.path))

        try fileManager.removeItem(at: destination)
        XCTAssertThrowsError(try transaction.recover(
            currentGeneration: oldGeneration,
            moveItem: { _, _ in throw Injected.restoreMove }
        )) {
            XCTAssertEqual($0 as? ChekinanaImportTransactionError, .incomplete)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: rollback), oldBytes)

        XCTAssertEqual(
            try transaction.recover(currentGeneration: oldGeneration),
            .restoreOld
        )
        XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
    }

    func testLaunchRecoversImportBeforeEveryOrdinaryMediaCleanup() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chekinana/ChekinanaApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let installStart = try XCTUnwrap(source.range(
            of: "private func installProductRoot("
        )?.lowerBound)
        let appStart = try XCTUnwrap(source.range(
            of: "@main",
            range: installStart..<source.endIndex
        )?.lowerBound)
        let install = String(source[installStart..<appStart])
        let recovery = try XCTUnwrap(install.range(
            of: "ChekinanaDataImporter.recoverUnfinishedImport"
        )?.lowerBound)
        let clearRecovery = try XCTUnwrap(install.range(
            of: "ChekinanaLocalDataClearer"
        )?.lowerBound)
        XCTAssertLessThan(recovery, clearRecovery)
        for cleanup in [
            "ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueues",
            "ChekinanaGalleryMediaStore.cleanupStagedImports",
            "ChekinanaCapturedPhotoStore.cleanupStaleFiles",
        ] {
            let cleanupIndex = try XCTUnwrap(install.range(of: cleanup)?.lowerBound)
            XCTAssertLessThan(recovery, cleanupIndex, "\(cleanup) ran before import recovery")
            if cleanup == "ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueues" {
                XCTAssertLessThan(
                    clearRecovery,
                    cleanupIndex,
                    "ordinary queue cleanup ran before clear recovery"
                )
            }
        }
        XCTAssertTrue(install.contains("guard !clearRecovery.needsRetry else { return }"))
        XCTAssertTrue(install.contains(
            "installRecoveryRoot(in: window, message: error.localizedDescription)"
        ))
    }

    @MainActor
    func testLibraryGenerationWitnessTracksOnlySavedReplacement() throws {
        let schema = Schema(ChekinanaSchemaV16.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let writer = ModelContext(container)
        let oldGeneration = try ChekinanaLibraryGenerationStore.ensureCurrent(in: writer)
        XCTAssertEqual(
            try ChekinanaLibraryGenerationStore.current(in: ModelContext(container)),
            oldGeneration
        )

        let uncommittedGeneration = UUID()
        try ChekinanaLibraryGenerationStore.publish(uncommittedGeneration, in: writer)
        writer.rollback()
        XCTAssertEqual(
            try ChekinanaLibraryGenerationStore.current(in: ModelContext(container)),
            oldGeneration
        )

        let committedGeneration = UUID()
        try writer.transaction {
            try ChekinanaLibraryGenerationStore.publish(committedGeneration, in: writer)
            try writer.save()
        }
        XCTAssertEqual(
            try ChekinanaLibraryGenerationStore.current(in: ModelContext(container)),
            committedGeneration
        )
        XCTAssertThrowsError(try ChekinanaImportRecoveryDirection.resolve(
            oldGeneration: oldGeneration,
            newGeneration: committedGeneration,
            currentGeneration: UUID()
        )) {
            XCTAssertEqual($0 as? ChekinanaImportTransactionError, .indeterminate)
        }
    }

    @MainActor
    func testLibraryReferenceSnapshotIncludesEveryManagedOwnerAndDerivedThumbnail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-reference-snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(ChekinanaSchemaV16.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let idolRef = "backup-idol-\(UUID().uuidString.lowercased()).jpg"
        let eventRef = "backup-event-\(UUID().uuidString.lowercased()).jpg"
        let eventImageRef = "backup-event-image-\(UUID().uuidString.lowercased()).jpg"
        let travelRef = "backup-travel-\(UUID().uuidString.lowercased()).jpg"
        let chekiOwner = UUID()
        let chekiRef = "\(chekiOwner.uuidString.lowercased()).jpg"
        let shameOwner = UUID()
        let shameRef = "shame-\(shameOwner.uuidString.lowercased()).jpg"
        let dougaOwner = UUID()
        let dougaRef = "douga-\(dougaOwner.uuidString.lowercased()).mov"
        let dougaThumbnail = ChekinanaGalleryMediaStore.thumbnailURL(
            id: dougaOwner,
            directory: directory
        ).lastPathComponent
        let memory = Memory(title: "References")
        let imageAttachmentID = UUID()
        let imageAttachmentRef = "shame-\(imageAttachmentID.uuidString.lowercased()).jpg"
        let videoAttachmentID = UUID()
        let videoAttachmentRef = "douga-\(videoAttachmentID.uuidString.lowercased()).mov"
        let videoAttachmentThumbnail = ChekinanaGalleryMediaStore.thumbnailURL(
            id: videoAttachmentID,
            directory: directory
        ).lastPathComponent
        let expected = Set([
            idolRef,
            eventRef,
            eventImageRef,
            travelRef,
            chekiRef,
            shameRef,
            dougaRef,
            dougaThumbnail,
            imageAttachmentRef,
            videoAttachmentRef,
            videoAttachmentThumbnail,
        ])
        for (index, filename) in expected.sorted().enumerated() {
            try Data("reference-\(index)".utf8).write(
                to: directory.appendingPathComponent(filename)
            )
        }

        let idol = Idol(name: "Idol", avatarImageRef: idolRef)
        let event = Event(name: "Event", avatarImageRef: eventRef)
        context.insert(idol)
        context.insert(event)
        context.insert(EventImage(
            eventID: event.id,
            imageRef: eventImageRef,
            sortOrder: 0
        ))
        context.insert(TravelSegment(
            mode: .train,
            operatorIconRef: travelRef,
            serviceNumber: "T1",
            departureCity: "A",
            departureLocation: "A",
            arrivalCity: "B",
            arrivalLocation: "B",
            departureTime: Date(timeIntervalSince1970: 1_800_000_000),
            arrivalTime: Date(timeIntervalSince1970: 1_800_003_600)
        ))
        context.insert(MediaItem(
            mediaOwnerID: chekiOwner,
            kind: .cheki,
            mediaRef: chekiRef
        ))
        context.insert(MediaItem(
            mediaOwnerID: shameOwner,
            kind: .shame,
            mediaRef: shameRef
        ))
        context.insert(MediaItem(
            mediaOwnerID: dougaOwner,
            kind: .douga,
            mediaRef: dougaRef
        ))
        context.insert(memory)
        context.insert(MemoryAttachment(
            id: imageAttachmentID,
            memoryID: memory.id,
            kind: .image,
            managedRef: imageAttachmentRef,
            sortOrder: 0
        ))
        context.insert(MemoryAttachment(
            id: videoAttachmentID,
            memoryID: memory.id,
            kind: .video,
            managedRef: videoAttachmentRef,
            sortOrder: 1
        ))
        let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        try context.save()

        let snapshot = try ChekinanaLibraryFileReferenceSnapshot.capture(
            in: ModelContext(container),
            directory: directory,
            requireEveryReferencedFile: true
        )
        XCTAssertEqual(snapshot.generation, generation)
        XCTAssertEqual(snapshot.referencedFilenames, expected)
        XCTAssertEqual(Set(snapshot.identitiesByFilename.keys), expected)
    }

    @MainActor
    func testCommittedImportReconcilesEveryQueueThenCleansIdempotently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-queue-commit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "library-queue-commit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema(ChekinanaSchemaV16.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let referencedID = UUID()
        let referencedRef = "shame-\(referencedID.uuidString.lowercased()).jpg"
        let referencedURL = directory.appendingPathComponent(referencedRef)
        let oldReferencedBytes = Data("old-gallery".utf8)
        let newReferencedBytes = Data("new-gallery".utf8)
        try oldReferencedBytes.write(to: referencedURL)
        let oldRestore = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
            kind: .shame,
            id: referencedID,
            reference: referencedRef,
            directory: directory
        )
        ChekinanaGalleryMediaStore.recordRestoreRecovery(
            oldRestore,
            directory: directory,
            defaults: defaults
        )
        try newReferencedBytes.write(to: referencedURL)
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .shame,
            id: referencedID,
            reference: referencedRef,
            defaults: defaults
        )

        let committedID = UUID()
        let committedRef = "shame-\(committedID.uuidString.lowercased()).jpg"
        let committedURL = directory.appendingPathComponent(committedRef)
        try Data("committed-delete".utf8).write(to: committedURL)
        let committed = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
            kind: .shame,
            id: committedID,
            reference: committedRef,
            directory: directory
        )
        ChekinanaGalleryMediaStore.recordCommittedDeletion(
            committed,
            directory: directory,
            defaults: defaults
        )

        let orphanID = UUID()
        let orphanRef = "shame-\(orphanID.uuidString.lowercased()).jpg"
        let orphanURL = directory.appendingPathComponent(orphanRef)
        try Data("gallery-orphan".utf8).write(to: orphanURL)
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .shame,
            id: orphanID,
            reference: orphanRef,
            defaults: defaults
        )

        let videoID = UUID()
        let videoRef = "douga-\(videoID.uuidString.lowercased()).mov"
        let videoURL = directory.appendingPathComponent(videoRef)
        let videoThumbnailURL = ChekinanaGalleryMediaStore.thumbnailURL(
            id: videoID,
            directory: directory
        )
        let videoBytes = Data("current-douga".utf8)
        let videoThumbnailBytes = Data("current-douga-thumbnail".utf8)
        try videoBytes.write(to: videoURL)
        try videoThumbnailBytes.write(to: videoThumbnailURL)
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .douga,
            id: videoID,
            reference: videoRef,
            defaults: defaults
        )

        let memory = Memory(title: "Imported memory")
        let attachmentID = UUID()
        let attachmentRef = "douga-\(attachmentID.uuidString.lowercased()).mov"
        let attachmentURL = directory.appendingPathComponent(attachmentRef)
        let attachmentThumbnailURL = ChekinanaGalleryMediaStore.thumbnailURL(
            id: attachmentID,
            directory: directory
        )
        let attachmentBytes = Data("current-memory-video".utf8)
        let attachmentThumbnailBytes = Data("current-memory-thumbnail".utf8)
        try attachmentBytes.write(to: attachmentURL)
        try attachmentThumbnailBytes.write(to: attachmentThumbnailURL)
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .douga,
            id: attachmentID,
            reference: attachmentRef,
            defaults: defaults
        )

        let eventID = UUID()
        let currentEventRef = "event-avatar-\(eventID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        let currentEventURL = directory.appendingPathComponent(currentEventRef)
        let currentEventBytes = Data("current-event".utf8)
        try currentEventBytes.write(to: currentEventURL)
        ChekinanaEventMediaJournal.recordPending(currentEventRef, defaults: defaults)
        ChekinanaEventMediaJournal.queueDeletion([currentEventRef], defaults: defaults)
        let pendingEventRef = "event-image-\(eventID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        let pendingEventURL = directory.appendingPathComponent(pendingEventRef)
        try Data("pending-event".utf8).write(to: pendingEventURL)
        ChekinanaEventMediaJournal.recordPending(pendingEventRef, defaults: defaults)
        let deletedEventRef = "event-image-\(eventID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        let deletedEventURL = directory.appendingPathComponent(deletedEventRef)
        try Data("deleted-event".utf8).write(to: deletedEventURL)
        ChekinanaEventMediaJournal.queueDeletion([deletedEventRef], defaults: defaults)

        context.insert(MediaItem(
            mediaOwnerID: referencedID,
            kind: .shame,
            mediaRef: referencedRef
        ))
        context.insert(MediaItem(
            mediaOwnerID: videoID,
            kind: .douga,
            mediaRef: videoRef
        ))
        context.insert(memory)
        context.insert(MemoryAttachment(
            id: attachmentID,
            memoryID: memory.id,
            kind: .video,
            managedRef: attachmentRef,
            sortOrder: 0
        ))
        context.insert(Event(
            id: eventID,
            name: "Imported Event",
            avatarImageRef: currentEventRef
        ))
        let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        try context.save()

        let reconcile = try ChekinanaLibraryQueueReconciler
            .reconcileImportRecoveryExclusively(
                direction: .completeNew,
                expectedGeneration: generation,
                in: context,
                directory: directory,
                defaults: defaults
            )
        XCTAssertFalse(reconcile.needsRetry)
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingRestoreRecoveryCount(defaults: defaults),
            0
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingCommittedDeletionCount(defaults: defaults),
            2
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            1
        )
        XCTAssertEqual(ChekinanaEventMediaJournal.pendingRefs(defaults: defaults), [pendingEventRef])
        XCTAssertEqual(ChekinanaEventMediaJournal.deletionRefs(defaults: defaults), [deletedEventRef])

        let first = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(first.needsRetry)
        XCTAssertEqual(try Data(contentsOf: referencedURL), newReferencedBytes)
        XCTAssertEqual(try Data(contentsOf: currentEventURL), currentEventBytes)
        XCTAssertEqual(try Data(contentsOf: videoURL), videoBytes)
        XCTAssertEqual(try Data(contentsOf: videoThumbnailURL), videoThumbnailBytes)
        XCTAssertEqual(try Data(contentsOf: attachmentURL), attachmentBytes)
        XCTAssertEqual(
            try Data(contentsOf: attachmentThumbnailURL),
            attachmentThumbnailBytes
        )
        for removedURL in [
            oldRestore[0].quarantine,
            committed[0].quarantine,
            orphanURL,
            pendingEventURL,
            deletedEventURL,
        ] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: removedURL.path))
        }
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingCommittedDeletionCount(defaults: defaults),
            0
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            0
        )
        XCTAssertTrue(ChekinanaEventMediaJournal.pendingRefs(defaults: defaults).isEmpty)
        XCTAssertTrue(ChekinanaEventMediaJournal.deletionRefs(defaults: defaults).isEmpty)

        let second = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(second.needsRetry)
        XCTAssertEqual(try Data(contentsOf: referencedURL), newReferencedBytes)
        XCTAssertEqual(try Data(contentsOf: currentEventURL), currentEventBytes)
        XCTAssertEqual(try Data(contentsOf: videoURL), videoBytes)
        XCTAssertEqual(try Data(contentsOf: videoThumbnailURL), videoThumbnailBytes)
        XCTAssertEqual(try Data(contentsOf: attachmentURL), attachmentBytes)
        XCTAssertEqual(
            try Data(contentsOf: attachmentThumbnailURL),
            attachmentThumbnailBytes
        )
    }

    @MainActor
    func testFailedImportDirectionKeepsOldRestoreWorkForTwoLaunches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-queue-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "library-queue-rollback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema(ChekinanaSchemaV16.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let mediaID = UUID()
        let mediaRef = "shame-\(mediaID.uuidString.lowercased()).jpg"
        let mediaURL = directory.appendingPathComponent(mediaRef)
        let mediaBytes = Data("old-library-media".utf8)
        try mediaBytes.write(to: mediaURL)
        let restore = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
            kind: .shame,
            id: mediaID,
            reference: mediaRef,
            directory: directory
        )
        ChekinanaGalleryMediaStore.recordRestoreRecovery(
            restore,
            directory: directory,
            defaults: defaults
        )
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .shame,
            id: mediaID,
            reference: mediaRef,
            defaults: defaults
        )
        let committedID = UUID()
        let committedRef = "shame-\(committedID.uuidString.lowercased()).jpg"
        let committedURL = directory.appendingPathComponent(committedRef)
        try Data("old-committed-delete".utf8).write(to: committedURL)
        let committed = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
            kind: .shame,
            id: committedID,
            reference: committedRef,
            directory: directory
        )
        ChekinanaGalleryMediaStore.recordCommittedDeletion(
            committed,
            directory: directory,
            defaults: defaults
        )
        let eventID = UUID()
        let eventRef = "event-avatar-\(eventID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        let eventURL = directory.appendingPathComponent(eventRef)
        let eventBytes = Data("old-library-event".utf8)
        try eventBytes.write(to: eventURL)
        ChekinanaEventMediaJournal.recordPending(eventRef, defaults: defaults)
        ChekinanaEventMediaJournal.queueDeletion([eventRef], defaults: defaults)
        context.insert(MediaItem(
            mediaOwnerID: mediaID,
            kind: .shame,
            mediaRef: mediaRef
        ))
        context.insert(Event(id: eventID, name: "Old", avatarImageRef: eventRef))
        let oldGeneration = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        try context.save()

        let rollback = try ChekinanaLibraryQueueReconciler
            .reconcileImportRecoveryExclusively(
                direction: .restoreOld,
                expectedGeneration: oldGeneration,
                in: context,
                directory: directory,
                defaults: defaults
            )
        XCTAssertFalse(rollback.needsRetry)
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingRestoreRecoveryCount(defaults: defaults),
            1
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            1
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingCommittedDeletionCount(defaults: defaults),
            1
        )
        XCTAssertEqual(
            ChekinanaEventMediaJournal.pendingRefs(defaults: defaults),
            [eventRef]
        )
        XCTAssertEqual(
            ChekinanaEventMediaJournal.deletionRefs(defaults: defaults),
            [eventRef]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: restore[0].quarantine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))

        let first = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(first.needsRetry)
        XCTAssertEqual(try Data(contentsOf: mediaURL), mediaBytes)
        XCTAssertEqual(try Data(contentsOf: eventURL), eventBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed[0].quarantine.path))
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingRestoreRecoveryCount(defaults: defaults),
            0
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingCommittedDeletionCount(defaults: defaults),
            0
        )
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            0
        )
        XCTAssertTrue(ChekinanaEventMediaJournal.pendingRefs(defaults: defaults).isEmpty)
        XCTAssertTrue(ChekinanaEventMediaJournal.deletionRefs(defaults: defaults).isEmpty)

        let second = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(second.needsRetry)
        XCTAssertEqual(try Data(contentsOf: mediaURL), mediaBytes)
        XCTAssertEqual(try Data(contentsOf: eventURL), eventBytes)
    }

    @MainActor
    func testQueueCleanupRechecksGenerationImmediatelyBeforeUnlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-queue-generation-race-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "library-queue-generation-race-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema(ChekinanaSchemaV16.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let orphanID = UUID()
        let orphanRef = "shame-\(orphanID.uuidString.lowercased()).jpg"
        let orphanURL = directory.appendingPathComponent(orphanRef)
        try Data("generation-race".utf8).write(to: orphanURL)
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .shame,
            id: orphanID,
            reference: orphanRef,
            defaults: defaults
        )
        var changedGeneration = false
        var hookError: Error?
        let first = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults,
            beforeCandidateValidation: {
                guard !changedGeneration else { return }
                changedGeneration = true
                do {
                    try ChekinanaLibraryGenerationStore.publish(UUID(), in: context)
                    try context.save()
                } catch {
                    hookError = error
                }
            }
        )
        XCTAssertNil(hookError)
        XCTAssertTrue(first.needsRetry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            1
        )

        let second = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(second.needsRetry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @MainActor
    func testQueueCleanupRechecksFileIdentityImmediatelyBeforeUnlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-queue-identity-race-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "library-queue-identity-race-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema(ChekinanaSchemaV16.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let orphanID = UUID()
        let orphanRef = "shame-\(orphanID.uuidString.lowercased()).jpg"
        let orphanURL = directory.appendingPathComponent(orphanRef)
        try Data("first-identity".utf8).write(to: orphanURL)
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .shame,
            id: orphanID,
            reference: orphanRef,
            defaults: defaults
        )
        let replacement = Data("replacement-identity".utf8)
        var replaced = false
        var hookError: Error?
        let first = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults,
            beforeCandidateValidation: {
                guard !replaced else { return }
                replaced = true
                do {
                    try replacement.write(to: orphanURL, options: .atomic)
                } catch {
                    hookError = error
                }
            }
        )
        XCTAssertNil(hookError)
        XCTAssertTrue(first.needsRetry)
        XCTAssertEqual(try Data(contentsOf: orphanURL), replacement)
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            1
        )

        let second = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(second.needsRetry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @MainActor
    func testQueueCleanupRechecksNewDatabaseReferenceImmediatelyBeforeUnlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-queue-reference-race-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "library-queue-reference-race-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema(ChekinanaSchemaV16.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
        let mediaID = UUID()
        let mediaRef = "shame-\(mediaID.uuidString.lowercased()).jpg"
        let mediaURL = directory.appendingPathComponent(mediaRef)
        let mediaBytes = Data("reference-race".utf8)
        try mediaBytes.write(to: mediaURL)
        ChekinanaGalleryMediaStore.recordOrphanedImport(
            kind: .shame,
            id: mediaID,
            reference: mediaRef,
            defaults: defaults
        )
        var insertedReference = false
        var hookError: Error?
        let first = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults,
            beforeCandidateValidation: {
                guard !insertedReference else { return }
                insertedReference = true
                context.insert(MediaItem(
                    mediaOwnerID: mediaID,
                    kind: .shame,
                    mediaRef: mediaRef
                ))
                do {
                    try context.save()
                } catch {
                    hookError = error
                }
            }
        )
        XCTAssertNil(hookError)
        XCTAssertTrue(first.needsRetry)
        XCTAssertEqual(try Data(contentsOf: mediaURL), mediaBytes)
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            1
        )

        let second = ChekinanaLibraryQueueReconciler.cleanupOrdinaryQueuesExclusively(
            in: context,
            directory: directory,
            defaults: defaults
        )
        XCTAssertFalse(second.needsRetry)
        XCTAssertEqual(try Data(contentsOf: mediaURL), mediaBytes)
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingOrphanCleanupCount(defaults: defaults),
            0
        )
    }

    @MainActor
    func testQueueCleanupProtectsDatabaseReferencedCommittedQuarantine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "library-queue-committed-reference-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "library-queue-committed-reference-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema(ChekinanaSchemaV16.models)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        _ = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)

        let mediaID = UUID()
        let originalRef = "shame-\(mediaID.uuidString.lowercased()).jpg"
        let originalURL = directory.appendingPathComponent(originalRef)
        let quarantineURL = directory.appendingPathComponent(
            ".delete-\(UUID().uuidString.lowercased())-\(originalRef)"
        )
        let mediaBytes = Data("referenced-committed-quarantine".utf8)
        try mediaBytes.write(to: quarantineURL)
        ChekinanaGalleryMediaStore.recordCommittedDeletion(
            [(original: originalURL, quarantine: quarantineURL)],
            directory: directory,
            defaults: defaults
        )
        context.insert(MediaItem(
            mediaOwnerID: mediaID,
            kind: .shame,
            mediaRef: quarantineURL.lastPathComponent
        ))
        try context.save()

        let report = ChekinanaLibraryQueueReconciler
            .cleanupOrdinaryQueuesExclusively(
                in: context,
                directory: directory,
                defaults: defaults
            )

        XCTAssertTrue(report.needsRetry)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), mediaBytes)
        XCTAssertEqual(
            ChekinanaGalleryMediaStore.pendingCommittedDeletionCount(defaults: defaults),
            1
        )
    }

    private func independentCRC32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1
            }
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(uint16LE(at: offset)) | UInt32(uint16LE(at: offset + 2)) << 16
    }
    func uint64LE(at offset: Int) -> UInt64 {
        UInt64(uint32LE(at: offset)) | UInt64(uint32LE(at: offset + 4)) << 32
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func replaceUInt64LE(at offset: Int, with value: UInt64) {
        var encoded = Data()
        encoded.appendUInt64LE(value)
        replaceSubrange(offset..<(offset + 8), with: encoded)
    }
}

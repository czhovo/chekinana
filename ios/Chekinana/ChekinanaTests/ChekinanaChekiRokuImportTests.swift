import XCTest
import SQLite3
import SwiftData
import zlib
@testable import Chekinana

final class ChekinanaChekiRokuImportTests: XCTestCase {
    func testMatcherPrefersExactAndSupportsContainsButNotOneEmptyGroup() {
        let source = ChekinanaChekiRokuImport.SourceIdol(id: 1, name: "砂糖心跳", group: "DokiDoki", color: "#FFFFFF", avatarName: nil)
        XCTAssertTrue(ChekiRokuIdolMatcher.exact(source: source, local: Idol(name: "砂糖心跳", group: "dokidoki")))
        XCTAssertTrue(ChekiRokuIdolMatcher.matches(source: source, local: Idol(name: "砂糖心跳dokidoki", group: "DokiDoki")))
        XCTAssertFalse(ChekiRokuIdolMatcher.matches(source: source, local: Idol(name: "砂糖心跳", group: nil)))
    }

    func testImportedPalettePresentationRoundTripsCanonicalStorageAndKeepsHex() {
        for canonical in ["绿色", "蓝色", "水色", "紫色", "粉色", "红色", "橙色", "黄色", "白色"] {
            let displayed = ChekinanaIdolPalette.localizedTitle(forStorageValue: canonical)
            XCTAssertEqual(
                ChekinanaIdolPalette.storageValue(forLocalizedTitle: displayed),
                canonical
            )
        }
        XCTAssertEqual(
            ChekinanaIdolPalette.storageValue(forLocalizedTitle: "#F0F4C3"),
            "#F0F4C3"
        )
    }

    func testRecordKindCountsUseEnglishSingularAndPluralsForZeroOneTwo() throws {
        let bundle = try localizedAppBundle(language: "en")
        let locale = Locale(identifier: "en")
        XCTAssertEqual(labels(for: .cheki, bundle: bundle, locale: locale), ["0 Cheki", "1 Cheki", "2 Cheki"])
        XCTAssertEqual(labels(for: .shame, bundle: bundle, locale: locale), ["0 Phone Photos", "1 Phone Photo", "2 Phone Photos"])
        XCTAssertEqual(labels(for: .douga, bundle: bundle, locale: locale), ["0 Videos", "1 Video", "2 Videos"])
    }

    func testRecordKindCountsStayInvariantInSimplifiedChineseForZeroOneTwo() throws {
        let bundle = try localizedAppBundle(language: "zh-Hans")
        let locale = Locale(identifier: "zh-Hans")
        XCTAssertEqual(labels(for: .cheki, bundle: bundle, locale: locale), ["0张拍立得", "1张拍立得", "2张拍立得"])
        XCTAssertEqual(labels(for: .shame, bundle: bundle, locale: locale), ["0张手机合影", "1张手机合影", "2张手机合影"])
        XCTAssertEqual(labels(for: .douga, bundle: bundle, locale: locale), ["0个视频", "1个视频", "2个视频"])
    }

    func testRecordKindCountsStayInvariantInJapaneseForZeroOneTwo() throws {
        let bundle = try localizedAppBundle(language: "ja")
        let locale = Locale(identifier: "ja")
        XCTAssertEqual(labels(for: .cheki, bundle: bundle, locale: locale), ["チェキ0枚", "チェキ1枚", "チェキ2枚"])
        XCTAssertEqual(labels(for: .shame, bundle: bundle, locale: locale), ["写メ0枚", "写メ1枚", "写メ2枚"])
        XCTAssertEqual(labels(for: .douga, bundle: bundle, locale: locale), ["動画0本", "動画1本", "動画2本"])
    }

    func testAvatarPreviewerRejectsMalformedBytesBeforePublishingPreview() async {
        let previews = await ChekiRokuAvatarPreviewer.makePreviews([
            "unsafe.jpg": Data([0xFF, 0xD8, 0xFF, 0xD9]),
        ])
        XCTAssertTrue(previews.isEmpty)
    }

    func testSelectedFileReaderCopiesValidChekiRokuIntoTemporaryStorage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekinanaSelectedFileReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("backup.chekiroku")
        let payload = Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02])
        try payload.write(to: source)

        let temporaryCopy = try ChekinanaChekiRokuSelectedFileReader
            .copyToTemporaryStorage(source)
        defer { try? FileManager.default.removeItem(at: temporaryCopy) }

        XCTAssertNotEqual(temporaryCopy, source)
        XCTAssertEqual(temporaryCopy.pathExtension, "chekiroku")
        XCTAssertEqual(try Data(contentsOf: temporaryCopy), payload)
    }

    func testSelectedFileReaderRejectsWrongExtensionNonZipAndOversizedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekinanaSelectedFileReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let wrongExtension = directory.appendingPathComponent("backup.zip")
        try Data([0x50, 0x4B]).write(to: wrongExtension)
        XCTAssertThrowsError(
            try ChekinanaChekiRokuSelectedFileReader.copyToTemporaryStorage(wrongExtension)
        ) { error in
            XCTAssertEqual(error as? ChekinanaChekiRokuSelectedFileError, .invalidFile)
        }

        let nonZIP = directory.appendingPathComponent("not-zip.chekiroku")
        try Data([0x00, 0x01]).write(to: nonZIP)
        XCTAssertThrowsError(
            try ChekinanaChekiRokuSelectedFileReader.copyToTemporaryStorage(nonZIP)
        ) { error in
            XCTAssertEqual(error as? ChekinanaChekiRokuSelectedFileError, .notZIP)
        }

        let directorySelection = directory.appendingPathComponent("folder.chekiroku", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directorySelection,
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(
            try ChekinanaChekiRokuSelectedFileReader.copyToTemporaryStorage(directorySelection)
        ) { error in
            XCTAssertEqual(error as? ChekinanaChekiRokuSelectedFileError, .invalidFile)
        }

        let oversized = directory.appendingPathComponent("oversized.chekiroku")
        try Data([0x50, 0x4B]).write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(
            ChekinanaChekiRokuSelectedFileReader.maximumArchiveSize + 1
        ))
        try handle.close()
        XCTAssertThrowsError(
            try ChekinanaChekiRokuSelectedFileReader.copyToTemporaryStorage(oversized)
        ) { error in
            XCTAssertEqual(error as? ChekinanaChekiRokuSelectedFileError, .invalidFile)
        }
    }

    func testImportPublicationPolicyRejectsCloseOrCancellationAfterYield() {
        let startedGeneration = 7
        XCTAssertTrue(ChekinanaChekiRokuImportPublicationPolicy.shouldPublish(
            isCancelled: false,
            generation: startedGeneration,
            currentGeneration: startedGeneration
        ))
        XCTAssertFalse(ChekinanaChekiRokuImportPublicationPolicy.shouldPublish(
            isCancelled: false,
            generation: startedGeneration,
            currentGeneration: startedGeneration + 1
        ))
        XCTAssertFalse(ChekinanaChekiRokuImportPublicationPolicy.shouldPublish(
            isCancelled: true,
            generation: startedGeneration,
            currentGeneration: startedGeneration
        ))
    }

    private func labels(
        for kind: ChekinanaRecordKind,
        bundle: Bundle,
        locale: Locale
    ) -> [String] {
        (0 ... 2).map { kind.countLabel($0, bundle: bundle, locale: locale) }
    }

    private func localizedAppBundle(language: String) throws -> Bundle {
        let candidates = [Bundle.main, Bundle(for: Self.self)] + Bundle.allBundles + Bundle.allFrameworks
        for candidate in candidates {
            guard let path = candidate.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            return bundle
        }
        throw XCTSkip("The built app does not contain the \(language) localization bundle.")
    }

    private func importCalendar(timeZoneID: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZoneID))
        return calendar
    }

    private func sourceMilliseconds(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) throws -> Int64 {
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func memberDraft(
        id: Int,
        name: String = "Idol",
        choice: ChekiRokuIdolChoice = .create,
        candidates: [Idol] = []
    ) -> ChekiRokuIdolDraft {
        ChekiRokuIdolDraft(
            memberID: id,
            name: name,
            group: "Group",
            color: "绿色",
            avatarData: nil,
            avatarPreview: nil,
            matchCandidates: candidates,
            choice: choice,
            resolution: .init(
                query: .init(name: name, group: "Group"),
                outcome: .fallback(.notFound)
            )
        )
    }

    func testCatalogueImportRequiresUniqueExactNameAndGroup() {
        let query = ChekiRokuCatalogueMatching.Query(name: " Alice ", group: "Group")
        let first = ChekinanaEnrichedIdol(
            sourceId: "one", idolName: "Ａlice", groupName: "GROUP", color: nil,
            birthday: nil, verification: nil, bio: nil, avatarUrl: nil
        )
        let otherGroup = ChekinanaEnrichedIdol(
            sourceId: "two", idolName: "Alice", groupName: "Other", color: nil,
            birthday: nil, verification: nil, bio: nil, avatarUrl: nil
        )
        let duplicateName = ChekinanaEnrichedIdol(
            sourceId: "three", idolName: "Alice", groupName: "Group", color: nil,
            birthday: nil, verification: nil, bio: nil, avatarUrl: nil
        )
        XCTAssertEqual(ChekiRokuCatalogueMatching.match(query, candidates: [first, otherGroup]), .matched(first))
        XCTAssertEqual(ChekiRokuCatalogueMatching.match(query, candidates: [otherGroup]), .fallback(.groupMismatch))
        XCTAssertEqual(ChekiRokuCatalogueMatching.match(query, candidates: [first, duplicateName]), .fallback(.ambiguous))
        XCTAssertEqual(ChekiRokuCatalogueMatching.match(query, candidates: Array(repeating: first, count: 200)), .fallback(.incomplete))
        XCTAssertEqual(ChekiRokuCatalogueMatching.match(.init(name: "Alice", group: ""), candidates: [first]), .fallback(.missingGroup))
    }

    func testCatalogueQueriesLeaveExistingChoicesAndExcludedMembersAlone() {
        var existing = memberDraft(id: 1, choice: .existing(UUID()))
        existing.resolution = nil
        var excluded = memberDraft(id: 2)
        excluded.resolution = nil
        excluded.isSelected = false
        XCTAssertTrue(ChekiRokuMemberSelectionPolicy.catalogueQueries([existing, excluded]).isEmpty)
        XCTAssertTrue(ChekiRokuMemberSelectionPolicy.canAdvance([existing, excluded]))

        var fresh = memberDraft(id: 3, name: "Alice")
        let originalChoice = fresh.choice
        fresh.group = "Edited Group"
        XCTAssertFalse(fresh.hasCurrentResolution)
        XCTAssertNil(fresh.catalogueCandidate)
        XCTAssertEqual(fresh.choice, originalChoice)
        XCTAssertFalse(ChekiRokuMemberSelectionPolicy.canAdvance([fresh]))
        XCTAssertEqual(ChekiRokuMemberSelectionPolicy.catalogueQueries([fresh]), [fresh.query])
    }

    func testCatalogueSearchDeduplicatesNamesAcrossGroupsAndBoundsConcurrency() async throws {
        let probe = ChekiRokuCatalogueSearchProbe()
        let queries = (0..<11).map { ChekiRokuCatalogueMatching.Query(name: "Name-\($0)", group: "Group") }
        let results = try await ChekiRokuCatalogueMatching.resolve(
            queries + queries + [.init(name: "Name-0", group: "Other")]
        ) { try await probe.search($0) }
        let (names, peak) = await probe.snapshot()
        XCTAssertEqual(names.count, 11)
        XCTAssertEqual(Set(names).count, 11)
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(results.count, 12)
    }

    func testCancelledCatalogueRequestDoesNotBecomeBackupFallback() async throws {
        let started = expectation(description: "search started")
        let query = ChekiRokuCatalogueMatching.Query(name: "Alice", group: "Group")
        let task = Task {
            try await ChekiRokuCatalogueMatching.resolve([query]) { _ in
                started.fulfill()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { throw ChekinanaIdolEnrichmentError.network("cancelled") }
                return []
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled search must not authorize fallback creation")
        } catch is CancellationError {}
    }

    func testSourceDayPreservesPositiveTimezoneDayInsteadOfPersistingLocalMidnight() throws {
        let calendar = try importCalendar(timeZoneID: "Asia/Shanghai")
        for (hour, minute) in [(0, 1), (23, 59)] {
            let milliseconds = try sourceMilliseconds(
                year: 2026,
                month: 8,
                day: 8,
                hour: hour,
                minute: minute,
                calendar: calendar
            )
            let day = try XCTUnwrap(
                ChekinanaChekiRokuImport.sourceDay(
                    milliseconds,
                    calendar: calendar
                )
            )
            XCTAssertEqual(ChekinanaDateOnly.string(day), "2026-08-08")
        }

        let midnightMilliseconds = try sourceMilliseconds(
            year: 2026,
            month: 8,
            day: 8,
            hour: 0,
            minute: 0,
            calendar: calendar
        )
        let legacyLocalMidnight = calendar.startOfDay(for: Date(
            timeIntervalSince1970: TimeInterval(midnightMilliseconds) / 1_000
        ))
        XCTAssertEqual(
            ChekinanaDateOnly.string(legacyLocalMidnight),
            "2026-08-07",
            "Persisting the old local-midnight instant reproduces the reported -1 day shift"
        )
        XCTAssertNil(ChekinanaChekiRokuImport.sourceDay(nil, calendar: calendar))
    }

    func testSourceDayPreservesDSTTransitionDayInAnotherTimezone() throws {
        let calendar = try importCalendar(timeZoneID: "America/Los_Angeles")
        for (hour, minute) in [(0, 1), (23, 59)] {
            let milliseconds = try sourceMilliseconds(
                year: 2026,
                month: 3,
                day: 8,
                hour: hour,
                minute: minute,
                calendar: calendar
            )
            let day = try XCTUnwrap(
                ChekinanaChekiRokuImport.sourceDay(
                    milliseconds,
                    calendar: calendar
                )
            )
            XCTAssertEqual(ChekinanaDateOnly.string(day), "2026-03-08")
        }
    }

    func testReaderCanonicalizesSourceDatesAndPreservesNil() throws {
        let fixture = try Fixture()
        let calendar = try importCalendar(timeZoneID: "Asia/Shanghai")
        let milliseconds = try sourceMilliseconds(
            year: 2026,
            month: 8,
            day: 8,
            hour: 0,
            minute: 1,
            calendar: calendar
        )
        let database = try fixture.database(sql: """
            DELETE FROM cheki_info;
            INSERT INTO cheki_info VALUES(1,\(milliseconds),1,1,'dated');
            INSERT INTO cheki_info VALUES(1,NULL,1,1,'undated');
            """)
        let archive = try ChekinanaChekiRokuImport.read(
            fixture.archive(database: database),
            calendar: calendar
        )
        defer { ChekinanaChekiRokuImport.cleanup(archive) }
        XCTAssertEqual(
            archive.records.compactMap(\.date).map(ChekinanaDateOnly.string),
            ["2026-08-08"]
        )
        XCTAssertEqual(archive.records.filter { $0.date == nil }.count, 1)
    }

    func testMemberSelectionDefaultsAllAndSupportsBulkActions() {
        var drafts = [memberDraft(id: 1), memberDraft(id: 2, name: "")]
        XCTAssertEqual(drafts.filter(\.isSelected).count, 2)
        XCTAssertTrue(ChekiRokuMemberSelectionPolicy.controlsEnabled(isSaving: false, isMatching: false))
        XCTAssertFalse(ChekiRokuMemberSelectionPolicy.controlsEnabled(isSaving: true, isMatching: false))
        XCTAssertFalse(ChekiRokuMemberSelectionPolicy.controlsEnabled(isSaving: false, isMatching: true))

        ChekiRokuMemberSelectionPolicy.setAll(false, drafts: &drafts)
        XCTAssertTrue(drafts.allSatisfy { !$0.isSelected })
        ChekiRokuMemberSelectionPolicy.setAll(true, drafts: &drafts)
        XCTAssertTrue(drafts.allSatisfy(\.isSelected))
    }

    func testSelectedUnresolvedBlocksWhileUnselectedUnresolvedBypassesValidation() {
        var unresolved = memberDraft(
            id: 1,
            choice: .unresolved,
            candidates: [Idol(name: "A"), Idol(name: "B")]
        )
        XCTAssertFalse(ChekiRokuMemberSelectionPolicy.canAdvance([unresolved]))
        unresolved.isSelected = false
        XCTAssertTrue(ChekiRokuMemberSelectionPolicy.canAdvance([unresolved]))

        var incomplete = memberDraft(id: 2, name: "", choice: .create)
        XCTAssertFalse(ChekiRokuMemberSelectionPolicy.canAdvance([incomplete]))
        incomplete.isSelected = false
        XCTAssertTrue(ChekiRokuMemberSelectionPolicy.canAdvance([incomplete]))
    }

    func testPartialMemberSelectionExcludesSourceRowsAndPlannedObjects() throws {
        let selectedID = UUID()
        let first = memberDraft(id: 1)
        var second = memberDraft(id: 2)
        second.isSelected = false
        let drafts = [first, second]
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let records = [
            ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 2, category: 1, memo: "included"),
            ChekinanaChekiRokuImport.SourceRecord(memberID: 2, date: day, count: 4, category: 1, memo: "excluded"),
        ]
        let selectedRecords = ChekiRokuMemberSelectionPolicy.selectedRecords(
            records,
            drafts: drafts
        )
        XCTAssertEqual(selectedRecords.count, 1)
        XCTAssertEqual(selectedRecords.reduce(0) { $0 + $1.count }, 2)
        let plan = try ChekiRokuRecordImportPlanner.make(
            records: selectedRecords,
            memberMap: [1: selectedID],
            existing: []
        )
        XCTAssertEqual(plan.map(\.count), [2])
        XCTAssertEqual(plan.first?.memoRuns, [.init(memo: "included", count: 2)])
    }

    func testReaderAcceptsStoredDeflatedAndAvatarBasename() throws {
        let fixture = try Fixture()
        let url = try fixture.archive(entries: [
            .init(name: "version.json", data: Data(#"{"version":2}"#.utf8)),
            .init(name: "my.db", data: try fixture.database(avatarPath: "/not-trusted/path/avatar.jpg"), method: 8),
            .init(name: "images/avatar.jpg", data: Fixture.jpeg)
        ])
        let result = try ChekinanaChekiRokuImport.read(url)
        defer { ChekinanaChekiRokuImport.cleanup(result) }
        XCTAssertEqual(result.idols.count, 1); XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.idols.first?.avatarName, "avatar.jpg")
        XCTAssertEqual(result.imageData["avatar.jpg"], Fixture.jpeg)
    }

    func testReaderAcceptsCRCWithHighBit() throws {
        let fixture = try Fixture(); let db = try fixture.database()
        let good = try fixture.archive(entries: [.init(name: "version.json", data: Data(#"{"version":2}"#.utf8)), .init(name: "my.db", data: db)])
        // The generated database CRC is deliberately high on all supported test
        // runtimes, guarding UInt32 conversion in the central directory reader.
        XCTAssertGreaterThanOrEqual(Fixture.crc(of: db), 0x8000_0000)
        let result = try ChekinanaChekiRokuImport.read(good); ChekinanaChekiRokuImport.cleanup(result)
    }

    func testSQLiteTerminalResultOnlyAcceptsDone() throws {
        XCTAssertNoThrow(try ChekinanaChekiRokuImport.requireCompletedStep(SQLITE_DONE))
        for result in [SQLITE_ROW, SQLITE_ERROR, SQLITE_CORRUPT, SQLITE_INTERRUPT] {
            XCTAssertThrowsError(
                try ChekinanaChekiRokuImport.requireCompletedStep(result),
                "SQLite result \(result) must not publish a partial archive"
            )
        }
    }

    func testReaderAcceptsEmptyAndMultiPageOrdinaryTables() throws {
        let fixture = try Fixture()
        let emptyDatabase = try fixture.database(sql: """
            DELETE FROM cheki_info;
            DELETE FROM member_info;
            DELETE FROM group_name;
            """)
        let emptyArchive = try ChekinanaChekiRokuImport.read(
            try fixture.archive(database: emptyDatabase)
        )
        XCTAssertTrue(emptyArchive.idols.isEmpty)
        XCTAssertTrue(emptyArchive.records.isEmpty)
        ChekinanaChekiRokuImport.cleanup(emptyArchive)

        let multiPageDatabase = try fixture.database(sql: """
            DELETE FROM cheki_info;
            WITH RECURSIVE n(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 400
            )
            INSERT INTO cheki_info
            SELECT 1,1700000000000,1,1,'memo-' || x FROM n;
            """)
        let multiPageArchive = try ChekinanaChekiRokuImport.read(
            try fixture.archive(database: multiPageDatabase)
        )
        XCTAssertEqual(multiPageArchive.records.count, 400)
        ChekinanaChekiRokuImport.cleanup(multiPageArchive)
    }

    func testReaderRequiresOnlyThreeOrdinaryTablesAndAllowsUnrelatedViewAndTrigger() throws {
        let fixture = try Fixture()
        let database = try fixture.database(sql: """
            CREATE TABLE audit(value TEXT);
            CREATE VIEW harmless_view AS SELECT id,name FROM group_name;
            CREATE TRIGGER harmless_trigger AFTER INSERT ON audit
            BEGIN
                UPDATE audit SET value = value WHERE rowid = NEW.rowid;
            END;
            """)
        let archive = try ChekinanaChekiRokuImport.read(
            try fixture.archive(database: database)
        )
        XCTAssertEqual(archive.idols.count, 1)
        XCTAssertEqual(archive.records.count, 1)
        ChekinanaChekiRokuImport.cleanup(archive)
    }

    func testReaderRejectsRequiredViewAndVirtualTable() throws {
        let fixture = try Fixture()
        let viewDatabase = try fixture.databaseFromScratch(sql: """
            CREATE TABLE group_source(id INTEGER,name TEXT);
            INSERT INTO group_source VALUES(1,'group');
            CREATE VIEW group_name AS SELECT id,name FROM group_source;
            CREATE TABLE member_info(id INTEGER,member_name TEXT,group_id INTEGER,red INTEGER,green INTEGER,blue INTEGER,image_path TEXT);
            CREATE TABLE cheki_info(member_id INTEGER,date INTEGER,count INTEGER,category_id INTEGER,memo TEXT);
            """)
        XCTAssertThrowsError(
            try ChekinanaChekiRokuImport.read(try fixture.archive(database: viewDatabase))
        )

        let virtualDatabase = try fixture.databaseFromScratch(sql: """
            CREATE VIRTUAL TABLE group_name USING fts5(id UNINDEXED,name);
            CREATE TABLE member_info(id INTEGER,member_name TEXT,group_id INTEGER,red INTEGER,green INTEGER,blue INTEGER,image_path TEXT);
            CREATE TABLE cheki_info(member_id INTEGER,date INTEGER,count INTEGER,category_id INTEGER,memo TEXT);
            """)
        XCTAssertThrowsError(
            try ChekinanaChekiRokuImport.read(try fixture.archive(database: virtualDatabase))
        )
        XCTAssertTrue(ChekinanaChekiRokuImport.isOrdinaryTableSchema(
            type: "table",
            sql: "CREATE TABLE group_name(id INTEGER, name TEXT)"
        ))
        XCTAssertFalse(ChekinanaChekiRokuImport.isOrdinaryTableSchema(
            type: "table",
            sql: "/* legacy runtime */ CREATE VIRTUAL TABLE group_name USING fts5(id, name)"
        ))
    }

    func testReaderRejectsPrepareFailureAndTruncatedLastPageWithoutPartialArchive() throws {
        let fixture = try Fixture()
        let missingColumnDatabase = try fixture.databaseFromScratch(sql: """
            CREATE TABLE group_name(id INTEGER,name TEXT);
            CREATE TABLE member_info(id INTEGER,member_name TEXT,group_id INTEGER,red INTEGER,green INTEGER,blue INTEGER,image_path TEXT);
            CREATE TABLE cheki_info(member_id INTEGER,date INTEGER,count INTEGER,category_id INTEGER);
            """)
        var before = Fixture.tempImportDirectories()
        XCTAssertThrowsError(
            try ChekinanaChekiRokuImport.read(
                try fixture.archive(database: missingColumnDatabase)
            )
        )
        XCTAssertEqual(Fixture.tempImportDirectories(), before)

        let lateInvalidValueDatabase = try fixture.database(sql: """
            INSERT INTO cheki_info VALUES(1,1700000000000,'invalid',1,'late failure');
            """)
        before = Fixture.tempImportDirectories()
        XCTAssertThrowsError(
            try ChekinanaChekiRokuImport.read(
                try fixture.archive(database: lateInvalidValueDatabase)
            )
        )
        XCTAssertEqual(Fixture.tempImportDirectories(), before)

        let multiPageDatabase = try fixture.database(sql: """
            DELETE FROM cheki_info;
            WITH RECURSIVE n(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 3000
            )
            INSERT INTO cheki_info
            SELECT 1,1700000000000,1,1,printf('%0400d', x) FROM n;
            """)
        XCTAssertGreaterThan(multiPageDatabase.count, 8_192)
        let pageSize = Int(multiPageDatabase[16]) << 8 | Int(multiPageDatabase[17])
        let actualPageSize = pageSize == 1 ? 65_536 : pageSize
        XCTAssertGreaterThan(actualPageSize, 0)
        let truncated = Data(multiPageDatabase.dropLast(actualPageSize))
        before = Fixture.tempImportDirectories()
        XCTAssertThrowsError(
            try ChekinanaChekiRokuImport.read(
                try fixture.archive(database: truncated)
            )
        )
        XCTAssertEqual(Fixture.tempImportDirectories(), before)
    }

    func testReaderRejectsDuplicateEntityPrimaryKeysButAllowsRepeatedForeignKeys() throws {
        let duplicateCases = [
            "INSERT INTO group_name VALUES(1,'other group')",
            "INSERT INTO member_info VALUES(1,'idol',1,4,5,6,NULL)",
            "INSERT INTO member_info VALUES(1,'other idol',1,4,5,6,NULL)",
        ]
        for sql in duplicateCases {
            let fixture = try Fixture()
            let before = Fixture.tempImportDirectories()
            XCTAssertThrowsError(
                try ChekinanaChekiRokuImport.read(
                    try fixture.archive(database: try fixture.database(sql: sql))
                )
            )
            XCTAssertEqual(Fixture.tempImportDirectories(), before)
        }

        let fixture = try Fixture()
        let database = try fixture.database(sql: """
            INSERT INTO member_info VALUES(2,'second',1,4,5,6,NULL);
            INSERT INTO cheki_info VALUES(1,1700000000000,1,1,'same member again');
            INSERT INTO cheki_info VALUES(2,1700000000000,1,1,'second member');
            """)
        let archive = try ChekinanaChekiRokuImport.read(
            try fixture.archive(database: database)
        )
        XCTAssertEqual(Set(archive.idols.map(\.id)), Set([1, 2]))
        XCTAssertEqual(archive.records.filter { $0.memberID == 1 }.count, 2)
        XCTAssertEqual(archive.records.filter { $0.memberID == 2 }.count, 1)
        ChekinanaChekiRokuImport.cleanup(archive)
    }

    func testReaderRejectsUnsafeZipForms() throws {
        let fixture = try Fixture(); let db = try fixture.database()
        let base = [Fixture.Entry(name: "version.json", data: Data(#"{"version":2}"#.utf8)), .init(name: "my.db", data: db)]
        let cases: [(String, [Fixture.Entry])] = [
            ("bad CRC", [.init(name: "version.json", data: Data(#"{"version":2}"#.utf8), crc: 1), .init(name: "my.db", data: db)]),
            ("traversal", [.init(name: "../my.db", data: db), base[0]]),
            ("absolute", [.init(name: "/my.db", data: db), base[0]]),
            ("NUL", [.init(name: "my\\0.db", data: db), base[0]]),
            ("duplicate", [base[0], base[1], base[1]]),
            ("Zip64", [.init(name: "version.json", data: base[0].data, zip64: true), base[1]]),
            ("encrypted", [.init(name: "version.json", data: base[0].data, flags: 1), base[1]]),
            ("unsupported", [.init(name: "version.json", data: base[0].data, method: 12), base[1]]),
            ("symlink", [.init(name: "version.json", data: base[0].data, external: 0xA000 << 16), base[1]]),
            ("ratio", [.init(name: "version.json", data: Data(repeating: 65, count: 10_100), method: 8), base[1]])
        ]
        for (label, entries) in cases { XCTAssertThrowsError(try ChekinanaChekiRokuImport.read(try fixture.archive(entries: entries)), label) }
        XCTAssertThrowsError(try ChekinanaChekiRokuImport.read(try fixture.archive(entries: base, multiDisk: true)))
    }

    func testReaderAcceptsUnixRegularFileAndRejectsSymlinkAttributes() throws {
        let fixture = try Fixture()
        let database = try fixture.database()
        let version = Data(#"{"version":2}"#.utf8)
        let regularArchive = try fixture.archive(entries: [
            .init(name: "version.json", data: version, external: 0x81A4 << 16),
            .init(name: "my.db", data: database, external: 0x81A4 << 16),
        ])
        let parsed = try ChekinanaChekiRokuImport.read(regularArchive)
        ChekinanaChekiRokuImport.cleanup(parsed)

        let symlinkArchive = try fixture.archive(entries: [
            .init(name: "version.json", data: version),
            .init(name: "my.db", data: database, external: 0xA000 << 16),
        ])
        XCTAssertThrowsError(try ChekinanaChekiRokuImport.read(symlinkArchive))
    }

    func testReaderRejectsInvalidSQLiteValuesAndDoesNotLeakTemporaryDirectory() throws {
        let mutations: [(String, String)] = [
            ("required null", "UPDATE member_info SET member_name=NULL"), ("wrong type", "UPDATE cheki_info SET count='one'"),
            ("name long", "UPDATE member_info SET member_name='" + String(repeating: "n", count: 201) + "'"),
            ("group long", "UPDATE group_name SET name='" + String(repeating: "g", count: 201) + "'"),
            ("memo long", "UPDATE cheki_info SET memo='" + String(repeating: "m", count: 2001) + "'"),
            ("path long", "UPDATE member_info SET image_path='" + String(repeating: "p", count: 4097) + "'"),
            ("negative count", "UPDATE cheki_info SET count=-1"), ("zero count", "UPDATE cheki_info SET count=0"), ("large count", "UPDATE cheki_info SET count=1001"),
            ("unknown member", "UPDATE cheki_info SET member_id=999"), ("unknown category", "UPDATE cheki_info SET category_id=4")
        ]
        for (label, sql) in mutations {
            let fixture = try Fixture(); let db = try fixture.database(sql: sql); let before = Fixture.tempImportDirectories()
            XCTAssertThrowsError(try ChekinanaChekiRokuImport.read(try fixture.archive(database: db)), label)
            XCTAssertEqual(Fixture.tempImportDirectories(), before, "\(label) leaked a temporary database")
        }
    }

    func testReaderRejectsAggregateAndRowLimits() throws {
        let cases: [(String, String)] = [
            ("total", "UPDATE cheki_info SET count=1000; INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a'); INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a'); INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a'); INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a'); INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a'); INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a'); INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a'); INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a'); INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a'); INSERT INTO cheki_info VALUES(1,1700000000000,1000,1,'a');"),
            ("idols", "WITH RECURSIVE n(x) AS (SELECT 2 UNION ALL SELECT x+1 FROM n WHERE x<=501) INSERT INTO member_info SELECT x,'n',1,1,2,3,NULL FROM n;"),
            ("groups", "WITH RECURSIVE n(x) AS (SELECT 2 UNION ALL SELECT x+1 FROM n WHERE x<=501) INSERT INTO group_name SELECT x,'g' FROM n;"),
            ("rows", "WITH RECURSIVE n(x) AS (SELECT 2 UNION ALL SELECT x+1 FROM n WHERE x<=10001) INSERT INTO cheki_info SELECT 1,1700000000000,1,1,'m' FROM n;")
        ]
        for (label, sql) in cases { let fixture = try Fixture(); XCTAssertThrowsError(try ChekinanaChekiRokuImport.read(try fixture.archive(database: try fixture.database(sql: sql))), label) }
    }

    func testReaderAcceptsDocumentedBusinessLimitsWithinGlobalWorkBudget() throws {
        let fixture = try Fixture()
        let database = try fixture.database(sql: """
            WITH RECURSIVE n(x) AS (
                SELECT 2 UNION ALL SELECT x + 1 FROM n WHERE x < 500
            )
            INSERT INTO group_name SELECT x,'group-' || x FROM n;
            WITH RECURSIVE n(x) AS (
                SELECT 2 UNION ALL SELECT x + 1 FROM n WHERE x < 500
            )
            INSERT INTO member_info SELECT x,'idol-' || x,1,1,2,3,NULL FROM n;
            WITH RECURSIVE n(x) AS (
                SELECT 2 UNION ALL SELECT x + 1 FROM n WHERE x <= 10000
            )
            INSERT INTO cheki_info SELECT 1,1700000000000,1,1,'' FROM n;
            """)
        let archive = try ChekinanaChekiRokuImport.read(
            try fixture.archive(database: database)
        )
        XCTAssertEqual(archive.idols.count, 500)
        XCTAssertEqual(archive.records.count, 10_000)
        ChekinanaChekiRokuImport.cleanup(archive)
    }

    func testReaderCountsManyNonChekiRowsBeforeFilteringAndRejectsTheirWorkload() throws {
        let fixture = try Fixture()
        let database = try fixture.database(sql: """
            DELETE FROM cheki_info;
            WITH RECURSIVE n(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 110
            )
            INSERT INTO cheki_info
            SELECT 999, -1, 1001,
                   CASE WHEN (a.x + b.x) % 2 = 0 THEN 2 ELSE 3 END,
                   NULL
            FROM n a CROSS JOIN n b
            UNION ALL
            SELECT 999, -1, 1001, 2, NULL FROM n
            LIMIT 11500;
            """)
        let before = Fixture.tempImportDirectories()
        XCTAssertThrowsError(
            try ChekinanaChekiRokuImport.read(
                try fixture.archive(database: database)
            )
        )
        XCTAssertEqual(Fixture.tempImportDirectories(), before)
    }

    func testReaderCountsRowsBeforeDuplicateMergingAndEnforcesVMWorkBudget() throws {
        let fixture = try Fixture()
        let duplicateDatabase = try fixture.database(sql: """
            INSERT INTO group_name VALUES(1,'duplicate');
            """)
        let rowBudget = ChekinanaChekiRokuImport.ReadLimits(
            maximumScannedRows: 7,
            progressInstructionInterval: 1_000,
            maximumApproximateVMInstructions: 50_000_000,
            maximumDurationNanoseconds: 15_000_000_000
        )
        XCTAssertThrowsError(
            try ChekinanaChekiRokuImport.read(
                try fixture.archive(database: duplicateDatabase),
                limits: rowBudget
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                ChekinanaL10n.text(
                    "import.error.database_budget",
                    fallback: "Backup database reading was cancelled or exceeded its resource limit."
                )
            )
        }

        let noVMWork = ChekinanaChekiRokuImport.ReadLimits(
            maximumScannedRows: 12_000,
            progressInstructionInterval: 1,
            maximumApproximateVMInstructions: 0,
            maximumDurationNanoseconds: 15_000_000_000
        )
        XCTAssertThrowsError(
            try ChekinanaChekiRokuImport.read(
                try fixture.archive(database: try fixture.database()),
                limits: noVMWork
            )
        )

        let noWallTime = ChekinanaChekiRokuImport.ReadLimits(
            maximumScannedRows: 12_000,
            progressInstructionInterval: 1_000,
            maximumApproximateVMInstructions: 50_000_000,
            maximumDurationNanoseconds: 0
        )
        XCTAssertThrowsError(
            try ChekinanaChekiRokuImport.read(
                try fixture.archive(database: try fixture.database()),
                limits: noWallTime
            )
        )
    }

    func testDetachedReaderCancellationAtPrepareStepGapAndBeforePublicationCleansUp() async throws {
        let phases: [ChekinanaChekiRokuImport.ReadPhase] = [
            .beforePrepare("schema.group_name"),
            .beforeStep("group_name"),
            .betweenQueries("group_name", "member_info"),
            .beforePublication,
        ]
        for phase in phases {
            let fixture = try Fixture()
            let archiveURL = try fixture.archive(database: try fixture.database())
            let gate = ChekiRokuReadPhaseGate(target: phase)
            let before = Fixture.tempImportDirectories()
            let task = Task {
                try await ChekinanaChekiRokuImport.readDetached(
                    archiveURL,
                    testingHooks: .init(onPhase: { gate.observe($0) })
                )
            }
            let didReachPhase = await gate.waitUntilBlocked()
            XCTAssertTrue(didReachPhase, "Reader did not reach \(phase)")
            task.cancel()
            gate.release()
            do {
                let archive = try await task.value
                ChekinanaChekiRokuImport.cleanup(archive)
                XCTFail("Cancelled reader published \(phase)")
            } catch {
                XCTAssertTrue(error is CancellationError || error is ChekinanaChekiRokuImport.Error)
            }
            XCTAssertEqual(Fixture.tempImportDirectories(), before)
            XCTAssertFalse(gate.didFinish)
        }
    }

    func testCancelledDetachedReaderCanBeReopenedWithoutBackgroundAccess() async throws {
        let fixture = try Fixture()
        let archiveURL = try fixture.archive(database: try fixture.database())
        let gate = ChekiRokuReadPhaseGate(target: .beforeStep("group_name"))
        let cancelled = Task {
            try await ChekinanaChekiRokuImport.readDetached(
                archiveURL,
                testingHooks: .init(onPhase: { gate.observe($0) })
            )
        }
        let didReachPhase = await gate.waitUntilBlocked()
        XCTAssertTrue(didReachPhase)
        cancelled.cancel()

        let replacement = Task {
            try await ChekinanaChekiRokuImport.readDetached(archiveURL)
        }
        gate.release()
        _ = try? await cancelled.value
        let archive = try await replacement.value
        XCTAssertEqual(archive.idols.count, 1)
        ChekinanaChekiRokuImport.cleanup(archive)
        XCTAssertFalse(gate.didFinish)
    }

    func testPlannerSkipsNonChekiAndOnlyPlansChekiShortage() throws {
        let idol = UUID(), day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let records = [ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 3, category: 1, memo: "cheki"), ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 1, category: 2, memo: "shame"), ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 1, category: 3, memo: "douga")]
        let existing = [ChekiRokuRecordImportPlanner.Existing(idolID: idol, day: day, category: 1)]
        let first = try ChekiRokuRecordImportPlanner.make(records: records, memberMap: [1: idol], existing: existing)
        XCTAssertEqual(first.map(\.category), [1]); XCTAssertEqual(first.first?.count, 2); XCTAssertEqual(first.first?.memoRuns, [.init(memo: "cheki", count: 2)])
    }

    func testPlannerKeepsOrderedMemoRunsWithoutExpandingEveryObject() throws {
        let idol = UUID(), day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let records = [
            ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 3, category: 1, memo: "first"),
            ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 2, category: 1, memo: "second"),
        ]
        let existing = [
            ChekiRokuRecordImportPlanner.Existing(
                idolID: idol,
                day: day,
                category: 1,
                count: 2
            ),
        ]
        let item = try ChekiRokuRecordImportPlanner.make(records: records, memberMap: [1: idol], existing: existing).first
        XCTAssertEqual(item?.count, 3)
        XCTAssertEqual(item?.memoRuns, [.init(memo: "first", count: 1), .init(memo: "second", count: 2)])
    }

    func testPlannerUsesOnlyRelevantSegmentedExistingQuotas() throws {
        let idol = UUID()
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let otherDay = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-09"))
        let existing: [ChekiRokuRecordImportPlanner.Existing] = [
            .init(idolID: idol, day: day, category: 1, count: Int.max),
            .init(idolID: idol, day: day, category: 1, count: 1),
        ]
        let covered = try ChekiRokuRecordImportPlanner.make(
            records: [.init(memberID: 1, date: day, count: 1, category: 1, memo: "source")],
            memberMap: [1: idol],
            existing: existing
        )
        XCTAssertTrue(covered.isEmpty)
        let unrelated = try ChekiRokuRecordImportPlanner.make(
            records: [.init(memberID: 1, date: otherDay, count: 1, category: 1, memo: "new day")],
            memberMap: [1: idol],
            existing: existing
        )
        XCTAssertEqual(unrelated.map(\.count), [1])
        XCTAssertEqual(unrelated.first?.memoRuns, [.init(memo: "new day", count: 1)])
        XCTAssertEqual(existing.map(\.count), [Int.max, 1])
    }

    func testPlannerConsumesQuotasBeyondIntMaxWithoutSaturation() throws {
        let idol = UUID()
        let source: [ChekinanaChekiRokuImport.SourceRecord] = [
            .init(memberID: 1, date: nil, count: Int.max, category: 1, memo: "first"),
            .init(memberID: 1, date: nil, count: 1, category: 1, memo: "last"),
        ]
        let maximum = ChekiRokuRecordImportPlanner.Existing(
            idolID: idol, day: nil, category: 1, count: Int.max
        )
        let covered = try ChekiRokuRecordImportPlanner.make(
            records: source,
            memberMap: [1: idol],
            existing: [maximum, .init(idolID: idol, day: nil, category: 1)]
        )
        XCTAssertTrue(covered.isEmpty, "A saturated Int quota would invent a one-record deficit")
        let oneMissing = try ChekiRokuRecordImportPlanner.make(
            records: source,
            memberMap: [1: idol],
            existing: [maximum]
        )
        XCTAssertEqual(oneMissing.first?.memoRuns, [.init(memo: "last", count: 1)])
        XCTAssertEqual(oneMissing.map(\.count), [1])
    }

    func testRecordSelectionKeepsSourceQuotaAndStableRowsWhenNotesAreIgnored() throws {
        let idol = UUID()
        let source: [ChekinanaChekiRokuImport.SourceRecord] = [
            .init(memberID: 1, date: nil, count: 99, category: 2, memo: "excluded"),
            .init(memberID: 1, date: nil, count: 2, category: 1, memo: "first"),
            .init(memberID: 1, date: nil, count: 2, category: 1, memo: "second"),
        ]
        let rows = try ChekiRokuRecordImportPlanner.makeRows(
            records: source, memberMap: [1: idol],
            existing: [.init(idolID: idol, day: nil, category: 1, count: 2)]
        )
        XCTAssertEqual(rows.map(\.sourceIndex), [2])
        let normal = ChekiRokuRecordImportPlanner.Selection(quantities: [2: 2], ignoresNotes: false)
        XCTAssertEqual(try ChekiRokuRecordImportPlanner.makeItems(from: rows, selection: normal).first?.memoRuns,
                       [.init(memo: "second", count: 2)])
        let ignored = ChekiRokuRecordImportPlanner.Selection(quantities: [2: 2], ignoresNotes: true)
        XCTAssertEqual(try ChekiRokuRecordImportPlanner.makeItems(from: rows, selection: ignored).first?.memoRuns,
                       [.init(memo: "", count: 2)])
        XCTAssertEqual(try ChekiRokuRecordImportPlanner.makeItems(from: rows, selection: normal).first?.memoRuns,
                       [.init(memo: "second", count: 2)])
        XCTAssertEqual(source[2].memo, "second")
        XCTAssertTrue(try ChekiRokuRecordImportPlanner.makeItems(from: rows, selection: .init(quantities: [:], ignoresNotes: false)).isEmpty)
        let live = try ChekiRokuRecordImportPlanner.makeRows(records: source, memberMap: [1: idol], existing: [])
        XCTAssertEqual(try ChekiRokuRecordImportPlanner.makeItems(from: live, selection: .init(quantities: [2: 1], ignoresNotes: false)).first?.count, 1)
    }

    func testIdenticalMemoSourceRowsRemainIndividuallySelectable() throws {
        let idol = UUID()
        let records: [ChekinanaChekiRokuImport.SourceRecord] = [
            .init(memberID: 1, date: nil, count: 2, category: 1, memo: "same"),
            .init(memberID: 1, date: nil, count: 3, category: 1, memo: "same")
        ]
        let rows = try ChekiRokuRecordImportPlanner.makeRows(records: records, memberMap: [1: idol], existing: [])
        XCTAssertEqual(rows.map(\.sourceIndex), [0, 1])
        XCTAssertEqual(try ChekiRokuRecordImportPlanner.makeItems(from: rows, selection: .init(quantities: [1: 3], ignoresNotes: false)).first?.count, 3)
        XCTAssertEqual(try ChekiRokuRecordImportPlanner.makeItems(from: rows, selection: .init(quantities: [0: 2, 1: 3], ignoresNotes: false)).first?.count, 5)
    }

    func testCatalogueQueriesCanBeLimitedToExplicitlyEnabledMember() {
        var first = memberDraft(id: 1, name: "First")
        var second = memberDraft(id: 2, name: "Second")
        first.resolution = nil; second.resolution = nil
        first.isSelected = false; second.isSelected = false
        XCTAssertTrue(ChekiRokuMemberSelectionPolicy.catalogueQueries([first, second]).isEmpty)
        first.isSelected = true; second.isSelected = true
        XCTAssertEqual(ChekiRokuMemberSelectionPolicy.catalogueQueries([first, second], memberIDs: [2]), [second.query])
        XCTAssertEqual(Set(ChekiRokuMemberSelectionPolicy.catalogueQueries([first, second])), Set([first.query, second.query]))
        second.isSelected = false
        XCTAssertTrue(ChekiRokuMemberSelectionPolicy.catalogueQueries([first, second], memberIDs: [2]).isEmpty)
    }

    func testSelectedRecordActorPreservesUnselectedDuplicatesAndOriginalNotes() async throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let setup = ModelContext(container)
        let idol = Idol(name: "Selected"), other = Idol(name: "Unselected")
        setup.insert(idol); setup.insert(other)
        let existing = ChekiRecord(idols: [idol], date: nil, size: .mini, note: "keep note", count: 2)
        let first = ChekiRecord(idols: [other], date: nil, size: .mini, note: "duplicate", count: 1)
        let second = ChekiRecord(idols: [other], date: nil, size: .mini, note: "duplicate", count: 1)
        setup.insert(existing); setup.insert(first); setup.insert(second); try setup.save()
        let idolID = idol.id, otherID = other.id
        let source: [ChekinanaChekiRokuImport.SourceRecord] = [
            .init(memberID: 1, date: nil, count: 2, category: 1, memo: "covered"),
            .init(memberID: 1, date: nil, count: 2, category: 1, memo: "ignore me"),
            .init(memberID: 2, date: nil, count: 5, category: 1, memo: "not selected")
        ]
        let importer = await Task.detached { ChekiRokuRecordImportActor(modelContainer: container) }.value
        let inserted = try await importer.save(records: source, memberMap: [1: idolID, 2: otherID], idolNames: [idolID: "Selected", otherID: "Unselected"], selection: .init(quantities: [1: 2], ignoresNotes: true)) { _ in }
        XCTAssertEqual(inserted, 2)
        let saved = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(saved.count, 4)
        XCTAssertEqual(saved.filter { $0.idolIDs == [otherID] }.count, 2)
        XCTAssertEqual(saved.first { $0.id == existing.id }?.note, "keep note")
        XCTAssertEqual(saved.first { $0.id == existing.id }?.count, 2)
        XCTAssertEqual(saved.first { $0.note.isEmpty }?.count, 2)
        let zero = try await importer.save(records: source, memberMap: [1: idolID, 2: otherID], idolNames: [idolID: "Selected", otherID: "Unselected"], selection: .init(quantities: [1: 2], ignoresNotes: true)) { _ in }
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>()).count, 4)
    }

    func testV17RokuActorPreservesDifferentIdentitiesAndReplansZeroDeficit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chekinana-roku-quota-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "RokuQuota", schema: schema,
                url: directory.appendingPathComponent("RokuQuota.store"),
                cloudKitDatabase: .none
            )]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Quota Idol")
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let otherDay = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-09"))
        setup.insert(idol)
        setup.insert(ChekiRecord(idols: [idol], date: day, size: .mini, note: "maximum", count: Int.max))
        setup.insert(ChekiRecord(idols: [idol], date: day, size: .mini, note: "separate", count: 1))
        try setup.save()
        let idolID = idol.id
        let members = [1: idolID]
        let names = [idolID: "Quota Idol"]
        let source = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1, date: day, count: 1, category: 1, memo: "source"
        )]
        let planner = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let preview = try await planner.plan(records: source, memberMap: members)
        XCTAssertTrue(preview.isEmpty)
        // Mirror the Wizard: commit uses a separate actor from the preview.
        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let covered = try await importer.save(records: source, memberMap: members, idolNames: names) { _ in }
        XCTAssertEqual(covered, 0)
        let newDay = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1, date: otherDay, count: 1, category: 1, memo: "new day"
        )]
        let inserted = try await importer.save(records: newDay, memberMap: members, idolNames: names) { _ in }
        XCTAssertEqual(inserted, 1)
        let repeated = try await importer.save(records: newDay, memberMap: members, idolNames: names) { _ in }
        XCTAssertEqual(repeated, 0)
        let verification = ModelContext(container)
        let saved = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(saved.first(where: { $0.note == "maximum" })?.count, Int.max)
        XCTAssertEqual(saved.first(where: { $0.note == "separate" })?.count, 1)
        XCTAssertEqual(saved.first(where: { $0.note == "new day" })?.count, 1)
        XCTAssertEqual(saved.first(where: { $0.note == "new day" })?.date, otherDay)
    }

    func testBackgroundImportActorUsesItsOwnRelationshipsAndReplansIdempotently() async throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "fixture", group: "group")
        setup.insert(idol)
        let sourceCalendar = try importCalendar(timeZoneID: "Asia/Shanghai")
        let day = try XCTUnwrap(ChekinanaChekiRokuImport.sourceDay(
            sourceMilliseconds(
                year: 2026,
                month: 8,
                day: 8,
                hour: 0,
                minute: 1,
                calendar: sourceCalendar
            ),
            calendar: sourceCalendar
        ))
        let event = Event(name: "Same day", date: day)
        setup.insert(event)
        let existing = MediaItem(
            date: day,
            idx: 7,
            size: .mini,
            imageRef: "existing.jpg",
            note: "existing"
        )
        setup.insert(existing)
        existing.idols = [idol]
        try setup.save()

        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let source = [
            ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 3, category: 1, memo: "cheki"),
            ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 1, category: 2, memo: "shame"),
            ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 1, category: 3, memo: "douga"),
            ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: nil, count: 1, category: 1, memo: "undated"),
        ]
        let planned = try await importer.plan(records: source, memberMap: [1: idol.id])
        XCTAssertEqual(planned.reduce(0) { $0 + $1.count }, 3)
        let inserted = try await importer.save(
            records: source,
            memberMap: [1: idol.id],
            idolNames: [idol.id: idol.name]
        ) { _ in }
        XCTAssertEqual(inserted, 3)
        let secondPlan = try await importer.plan(records: source, memberMap: [1: idol.id])
        XCTAssertTrue(
            secondPlan.isEmpty,
            "Unexpected deficits: \(secondPlan.map { ($0.category, $0.day.map(ChekinanaDateOnly.string), $0.count) })"
        )

        let verification = ModelContext(container)
        let importedRecords = try verification.fetch(FetchDescriptor<ChekiRecord>())
            .filter { $0.note == "cheki" }
        XCTAssertEqual(importedRecords.count, 1)
        XCTAssertEqual(importedRecords.first?.count, 2)
        XCTAssertTrue(importedRecords.allSatisfy { $0.idols.map(\.id) == [idol.id] })
        XCTAssertTrue(importedRecords.allSatisfy { $0.event?.id == event.id })
        XCTAssertTrue(importedRecords.allSatisfy { $0.size == .mini })
        XCTAssertEqual(Set(importedRecords.compactMap { $0.date.map(ChekinanaDateOnly.string) }), ["2026-08-08"])
        let undatedRecord = try verification.fetch(FetchDescriptor<ChekiRecord>()).first {
            $0.note == "undated"
        }
        XCTAssertEqual(undatedRecord?.date, nil)
        XCTAssertEqual(undatedRecord?.idols.map(\.id), [idol.id])
        XCTAssertNil(undatedRecord?.event)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<MediaItem>()), 1)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<MediaItem>()).first?.imageRef,
            "existing.jpg"
        )
        XCTAssertTrue(try verification.fetch(FetchDescriptor<MediaItem>())
            .filter { $0.kind == .shame }.isEmpty)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<MediaItem>())
            .filter { $0.kind == .douga }.isEmpty)
    }

    func testBackgroundImportActorIgnoresLegacyMaximumIndexAndCreatesSimpleRecord() async throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "fixture")
        setup.insert(idol)
        let day = Calendar.current.startOfDay(for: Date())
        let occupied = MediaItem(
            date: day,
            idx: Int.max,
            size: .mini,
            imageRef: "occupied.jpg",
            note: "occupied"
        )
        setup.insert(occupied)
        occupied.idols = [idol]
        try setup.save()
        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let source = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1,
            date: day,
            count: 2,
            category: 1,
            memo: "overflow"
        )]
        let inserted = try await importer.save(
            records: source,
            memberMap: [1: idol.id],
            idolNames: [idol.id: idol.name]
        ) { _ in }
        XCTAssertEqual(inserted, 1)
        let records = try ModelContext(container).fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.note, "occupied")
        let simpleRecords = try ModelContext(container).fetch(
            FetchDescriptor<ChekiRecord>()
        )
        XCTAssertEqual(simpleRecords.count, 1)
        XCTAssertEqual(simpleRecords.first?.note, "overflow")
        XCTAssertEqual(simpleRecords.first?.count, 1)
    }

    func testBackgroundImportActorCancellationBeforeSaveRollsBackWholeBatch() async throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "fixture")
        setup.insert(idol)
        try setup.save()
        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let source = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1,
            date: Calendar.current.startOfDay(for: Date()),
            count: 150,
            category: 1,
            memo: "cancel"
        )]

        do {
            _ = try await importer.save(
                records: source,
                memberMap: [1: idol.id],
                idolNames: [idol.id: idol.name],
                beforePersistForTesting: {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            ) { _ in }
            XCTFail("Expected cancellation before save")
        } catch is CancellationError {}

        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<MediaItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>()).isEmpty)

        let idolID = idol.id
        let idolName = idol.name
        let recovered = try await Task.detached {
            try await importer.save(
                records: source,
                memberMap: [1: idolID],
                idolNames: [idolID: idolName]
            ) { _ in }
        }.value
        XCTAssertEqual(recovered, 150)
        let recoveredRecords = try ModelContext(container).fetch(
            FetchDescriptor<ChekiRecord>()
        )
        XCTAssertEqual(recoveredRecords.count, 1)
        XCTAssertEqual(recoveredRecords.first?.count, 150)
    }

    func testBackgroundImporterHandlesLiveIntMaxCountWithoutOverflow() async throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Maximum Idol")
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        setup.insert(idol)
        setup.insert(ChekiRecord(
            idols: [idol],
            date: day,
            size: .mini,
            note: "maximum",
            count: Int.max
        ))
        try setup.save()

        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let source = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1,
            date: day,
            count: 1,
            category: 1,
            memo: "maximum"
        )]
        let inserted = try await importer.save(
            records: source,
            memberMap: [1: idol.id],
            idolNames: [idol.id: idol.name]
        ) { _ in }

        XCTAssertEqual(inserted, 0)
        let records = try ModelContext(container).fetch(
            FetchDescriptor<ChekiRecord>()
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.count, Int.max)
    }

    func testBackgroundImporterDuplicateMergeOverflowRollsBackAndReleasesGate() async throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Overflow Idol")
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        setup.insert(idol)
        setup.insert(ChekiRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            idols: [idol],
            date: day.addingTimeInterval(60 * 60),
            size: .mini,
            note: "duplicate",
            count: Int.max
        ))
        setup.insert(ChekiRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            idols: [idol],
            date: day,
            size: .mini,
            note: "duplicate",
            count: 1
        ))
        try setup.save()

        let source = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1,
            date: day,
            count: 1,
            category: 1,
            memo: "duplicate"
        )]
        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        do {
            _ = try await importer.save(
                records: source,
                memberMap: [1: idol.id],
                idolNames: [idol.id: idol.name]
            ) { _ in }
            XCTFail("Expected duplicate count overflow")
        } catch let error as ChekinanaChekiRecordMutationError {
            XCTAssertEqual(error, .quantityOverflow)
        }

        var verification = ModelContext(container)
        var records = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.count).sorted(), [1, Int.max])
        XCTAssertTrue(records.contains { $0.date == day.addingTimeInterval(60 * 60) })

        let repair = ModelContext(container)
        let repairRecords = try repair.fetch(FetchDescriptor<ChekiRecord>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        repairRecords[0].count = 1
        repairRecords.dropFirst().forEach(repair.delete)
        try repair.save()

        let recoveryDay = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-09"))
        let recovered = try await importer.save(
            records: [.init(
                memberID: 1,
                date: recoveryDay,
                count: 2,
                category: 1,
                memo: "recovered"
            )],
            memberMap: [1: idol.id],
            idolNames: [idol.id: idol.name]
        ) { _ in }
        XCTAssertEqual(recovered, 2)

        verification = ModelContext(container)
        records = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first(where: { $0.note == "duplicate" })?.count, 1)
        XCTAssertEqual(records.first(where: { $0.note == "recovered" })?.count, 2)
    }

    func testCommitReplansAfterLateSimpleRecordInsertion() async throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "fixture")
        setup.insert(idol)
        try setup.save()
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let source = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1,
            date: day,
            count: 3,
            category: 1,
            memo: "source"
        )]
        let previewActor = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let preview = try await previewActor.plan(records: source, memberMap: [1: idol.id])
        XCTAssertEqual(preview.first?.count, 3)

        let late = ChekiRecord(
            idols: [idol],
            date: day.addingTimeInterval(60 * 60),
            size: .mini,
            note: "late"
        )
        setup.insert(late)
        try setup.save()

        let commitActor = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let inserted = try await commitActor.save(
            records: source,
            memberMap: [1: idol.id],
            idolNames: [idol.id: idol.name]
        ) { _ in }
        XCTAssertEqual(inserted, 2)
        let values = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.first(where: { $0.note == "late" })?.count, 1)
        XCTAssertEqual(values.first(where: { $0.note == "late" })?.date, day)
        XCTAssertEqual(values.first(where: { $0.note == "source" })?.count, 2)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<MediaItem>()).isEmpty)
    }

    func testCommitReplansSatisfiedStalePreviewToZeroWrites() async throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "fixture")
        setup.insert(idol)
        try setup.save()
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let source = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1,
            date: day,
            count: 1,
            category: 1,
            memo: "source"
        )]
        let previewActor = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let preview = try await previewActor.plan(records: source, memberMap: [1: idol.id])
        XCTAssertEqual(preview.first?.count, 1)

        let late = ChekiRecord(idols: [idol], date: day, size: .mini, note: "late")
        setup.insert(late)
        try setup.save()
        let commitActor = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let inserted = try await commitActor.save(
            records: source,
            memberMap: [1: idol.id],
            idolNames: [idol.id: idol.name]
        ) { _ in }
        XCTAssertEqual(inserted, 0)
        let values = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.note, "late")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<MediaItem>()).isEmpty)
    }

    func testSameActorConcurrentSavesDoNotDuplicateSimpleRecordCounts() async throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "fixture")
        setup.insert(idol)
        try setup.save()
        let idolID = idol.id
        let idolName = idol.name
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let source = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1,
            date: day,
            count: 3,
            category: 1,
            memo: "source"
        )]
        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let first = Task {
            try await importer.save(
                commitID: UUID(),
                records: source,
                memberMap: [1: idolID],
                idolNames: [idolID: idolName]
            ) { _ in }
        }
        let second = Task {
            try await importer.save(
                commitID: UUID(),
                records: source,
                memberMap: [1: idolID],
                idolNames: [idolID: idolName]
            ) { _ in }
        }
        let results = try await [first.value, second.value].sorted()
        XCTAssertEqual(results, [0, 3])
        let records = try ModelContext(container).fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.count, 3)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<MediaItem>()).isEmpty)
    }

    func testImporterAndMainActorUpsertSerializeAcrossContextsAndPreserveBothDeltas() async throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Concurrent Idol")
        setup.insert(idol)
        try setup.save()
        let idolID = idol.id
        let idolName = idol.name
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let source = [ChekinanaChekiRokuImport.SourceRecord(
            memberID: 1,
            date: day,
            count: 3,
            category: 1,
            memo: "same"
        )]
        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let interleave = ChekiRokuBeforePersistGate()
        let importTask = Task {
            try await importer.save(
                records: source,
                memberMap: [1: idolID],
                idolNames: [idolID: idolName],
                beforePersistForTesting: interleave.block
            ) { _ in }
        }
        let didBlock = await interleave.waitUntilBlocked()
        XCTAssertTrue(didBlock)
        let releaser = Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            interleave.release()
        }
        _ = try await MainActor.run { () throws -> UUID in
            let context = ModelContext(container)
            let liveIdol = try XCTUnwrap(
                context.fetch(FetchDescriptor<Idol>()).first { $0.id == idolID }
            )
            return try ChekinanaChekiRecordStore.upsert(
                idols: [liveIdol],
                event: nil,
                date: day.addingTimeInterval(2 * 60 * 60),
                size: .mini,
                note: "same",
                adding: 2,
                in: context
            ).id
        }
        _ = await releaser.value
        let imported = try await importTask.value
        XCTAssertEqual(imported, 3)

        var verification = ModelContext(container)
        var records = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.count, 5)
        XCTAssertEqual(records.first?.date, day)

        try await MainActor.run {
            let context = ModelContext(container)
            let liveIdol = try XCTUnwrap(
                context.fetch(FetchDescriptor<Idol>()).first { $0.id == idolID }
            )
            _ = try ChekinanaChekiRecordStore.upsert(
                idols: [liveIdol],
                event: nil,
                date: day,
                size: .mini,
                note: "different",
                adding: 4,
                in: context
            )
        }
        verification = ModelContext(container)
        records = try verification.fetch(FetchDescriptor<ChekiRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first(where: { $0.note == "same" })?.count, 5)
        XCTAssertEqual(records.first(where: { $0.note == "different" })?.count, 4)
    }

    func testImporterBeforeSaveSerializesWithIdolDeletionAndRejectsDanglingKeys() async throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "Protected Idol")
        setup.insert(idol)
        try setup.save()
        let idolID = idol.id
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let interleave = ChekiRokuBeforePersistGate()
        let importTask = Task {
            try await importer.save(
                records: [.init(
                    memberID: 1,
                    date: day,
                    count: 2,
                    category: 1,
                    memo: "linked"
                )],
                memberMap: [1: idolID],
                idolNames: [idolID: "Protected Idol"],
                beforePersistForTesting: interleave.block
            ) { _ in }
        }
        let didBlock = await interleave.waitUntilBlocked()
        XCTAssertTrue(didBlock)
        let releaser = Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            interleave.release()
        }
        do {
            try await MainActor.run {
                let context = ModelContext(container)
                let live = try XCTUnwrap(
                    context.fetch(FetchDescriptor<Idol>()).first { $0.id == idolID }
                )
                _ = try ChekinanaIdolPersistence.delete(live, from: context)
            }
            XCTFail("A newly linked Idol must not be deleted.")
        } catch let error as ChekinanaIdolPersistenceError {
            guard case .linkedChekiRecords(let count) = error else {
                return XCTFail("Unexpected Idol deletion error: \(error)")
            }
            XCTAssertEqual(count, 2)
        }
        _ = await releaser.value
        let imported = try await importTask.value
        XCTAssertEqual(imported, 2)
        let verification = ModelContext(container)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<Idol>()), 1)
        let record = try XCTUnwrap(
            verification.fetch(FetchDescriptor<ChekiRecord>()).first
        )
        XCTAssertEqual(record.idolIDs, [idolID])
        XCTAssertEqual(record.count, 2)
    }

    func testImporterBeforeSaveSerializesWithEventDeletionAndUnbindsImportedRecord() async throws {
        let schema = Schema(versionedSchema: ChekinanaSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let idol = Idol(name: "Event Idol")
        let event = Event(name: "Protected Event", date: day)
        setup.insert(idol)
        setup.insert(event)
        try setup.save()
        let idolID = idol.id
        let eventID = event.id
        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let interleave = ChekiRokuBeforePersistGate()
        let importTask = Task {
            try await importer.save(
                records: [.init(
                    memberID: 1,
                    date: day,
                    count: 3,
                    category: 1,
                    memo: "event linked"
                )],
                memberMap: [1: idolID],
                idolNames: [idolID: "Event Idol"],
                beforePersistForTesting: interleave.block
            ) { _ in }
        }
        let didBlock = await interleave.waitUntilBlocked()
        XCTAssertTrue(didBlock)
        let releaser = Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            interleave.release()
        }
        try await MainActor.run {
            let context = ModelContext(container)
            let live = try XCTUnwrap(
                context.fetch(FetchDescriptor<Event>()).first { $0.id == eventID }
            )
            try ChekinanaEventPersistence.delete(live, from: context)
        }
        _ = await releaser.value
        let imported = try await importTask.value
        XCTAssertEqual(imported, 3)
        let verification = ModelContext(container)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<Event>()), 0)
        let record = try XCTUnwrap(
            verification.fetch(FetchDescriptor<ChekiRecord>()).first
        )
        XCTAssertNil(record.eventID)
        XCTAssertEqual(record.count, 3)
    }

    func testRecordProgressPolicyRejectsLateWrongAndRegressiveUpdates() {
        let commitID = UUID()
        let current = ChekiRokuRecordImportProgress(
            commitID: commitID,
            completed: 5,
            total: 10,
            idolName: "fixture"
        )
        XCTAssertTrue(ChekiRokuRecordProgressPolicy.shouldAccept(
            activeCommitID: commitID,
            update: current,
            currentCompleted: 4,
            importCompleted: false
        ))
        XCTAssertFalse(ChekiRokuRecordProgressPolicy.shouldAccept(
            activeCommitID: commitID,
            update: .init(commitID: commitID, completed: 3, total: 10, idolName: "fixture"),
            currentCompleted: 4,
            importCompleted: false
        ))
        XCTAssertFalse(ChekiRokuRecordProgressPolicy.shouldAccept(
            activeCommitID: UUID(),
            update: current,
            currentCompleted: 4,
            importCompleted: false
        ))
        XCTAssertFalse(ChekiRokuRecordProgressPolicy.shouldAccept(
            activeCommitID: commitID,
            update: current,
            currentCompleted: 4,
            importCompleted: true
        ))
    }

    func testCommitSkipsMultipleShameAndDougaForSameIdol() async throws {
        for category in [2, 3] {
            let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            let setup = ModelContext(container)
            let idol = Idol(name: "fixture")
            setup.insert(idol)
            try setup.save()
            let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
            let source = [ChekinanaChekiRokuImport.SourceRecord(
                memberID: 1,
                date: day,
                count: 2,
                category: category,
                memo: "unsafe"
            )]
            let importer = await Task.detached {
                ChekiRokuRecordImportActor(modelContainer: container)
            }.value
            let inserted = try await importer.save(
                records: source,
                memberMap: [1: idol.id],
                idolNames: [idol.id: idol.name]
            ) { _ in }
            XCTAssertEqual(inserted, 0)
            let verification = ModelContext(container)
            if category == 2 {
                let values = try verification.fetch(FetchDescriptor<MediaItem>())
                XCTAssertTrue(values.isEmpty)
            } else {
                let values = try verification.fetch(FetchDescriptor<MediaItem>())
                XCTAssertTrue(values.isEmpty)
            }
        }
    }

    func testCommitSkipsShameAndDougaAndPreservesExistingRecords() async throws {
        for category in [2, 3] {
            let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            let setup = ModelContext(container)
            let idol = Idol(name: "fixture")
            setup.insert(idol)
            let existingDay = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-07"))
            if category == 2 {
                let existing = MediaItem(
                    kind: .shame,
                    date: existingDay,
                    mediaRef: "existing-shame.jpg",
                    note: "existing"
                )
                setup.insert(existing)
                existing.idols = [idol]
            } else {
                let existing = MediaItem(
                    kind: .douga,
                    date: existingDay,
                    mediaRef: "existing-douga.mov",
                    note: "existing"
                )
                setup.insert(existing)
                existing.idols = [idol]
            }
            try setup.save()
            let importDay = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
            let source = [ChekinanaChekiRokuImport.SourceRecord(
                memberID: 1,
                date: importDay,
                count: 1,
                category: category,
                memo: "new"
            )]
            let importer = await Task.detached {
                ChekiRokuRecordImportActor(modelContainer: container)
            }.value
            let inserted = try await importer.save(
                records: source,
                memberMap: [1: idol.id],
                idolNames: [idol.id: idol.name]
            ) { _ in }
            XCTAssertEqual(inserted, 0)
            let verification = ModelContext(container)
            if category == 2 {
                let values = try verification.fetch(FetchDescriptor<MediaItem>())
                XCTAssertEqual(values.count, 1)
                XCTAssertTrue(values.allSatisfy { $0.idols.map(\.id) == [idol.id] })
            } else {
                let values = try verification.fetch(FetchDescriptor<MediaItem>())
                XCTAssertEqual(values.count, 1)
                XCTAssertTrue(values.allSatisfy { $0.idols.map(\.id) == [idol.id] })
            }
        }
    }

    func testCommitNonChekiOnlyReturnsZeroWithoutError() async throws {
        let schema = Schema([Idol.self, Event.self, EventImage.self, MediaItem.self, ChekiRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let setup = ModelContext(container)
        let idol = Idol(name: "fixture")
        setup.insert(idol)
        try setup.save()
        let day = try XCTUnwrap(ChekinanaDateOnly.parse("2026-08-08"))
        let source = [
            ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 1, category: 2, memo: "shame"),
            ChekinanaChekiRokuImport.SourceRecord(memberID: 1, date: day, count: 1, category: 3, memo: "douga"),
        ]
        let importer = await Task.detached {
            ChekiRokuRecordImportActor(modelContainer: container)
        }.value
        let inserted = try await importer.save(
            records: source,
            memberMap: [1: idol.id],
            idolNames: [idol.id: idol.name]
        ) { _ in }
        XCTAssertEqual(inserted, 0)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<MediaItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<MediaItem>()).isEmpty)
    }

    func testThemePreferenceMapsNineStableKeysAndFallsBackToPurple() {
        let expected: [(ChekinanaThemeOption, String, String)] = [
            (.green, "green", "#2E7D32"), (.blue, "blue", "#1565C0"),
            (.aqua, "aqua", "#0277BD"), (.purple, "purple", "#4F337A"),
            (.pink, "pink", "#AD1457"), (.red, "red", "#C62828"),
            (.orange, "orange", "#E65100"), (.yellow, "yellow", "#827717"),
            (.gray, "gray", "#616161"),
        ]
        XCTAssertEqual(ChekinanaThemeOption.allCases.count, 9)
        for (option, key, hex) in expected {
            XCTAssertEqual(option.rawValue, key)
            XCTAssertEqual(option.hex, hex)
        }
        XCTAssertEqual(ChekinanaThemeOption.resolve(nil), .purple)
        XCTAssertEqual(ChekinanaThemeOption.resolve("unknown"), .purple)
    }

    @MainActor
    func testThemeStorePersistsAndPublishesImmediateRevision() {
        let suite = "ChekinanaThemeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid", forKey: ChekinanaThemePreference.defaultsKey)
        let renderState = ChekinanaThemeRenderState(.red)
        let store = ChekinanaThemeStore(
            defaults: defaults,
            renderState: renderState
        )
        XCTAssertEqual(store.theme, .purple)
        XCTAssertEqual(renderState.theme, .purple)
        XCTAssertEqual(store.revision, 0)
        store.theme = .aqua
        XCTAssertEqual(store.theme, .aqua)
        XCTAssertEqual(renderState.theme, .aqua)
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(
            defaults.string(forKey: ChekinanaThemePreference.defaultsKey),
            "aqua"
        )
        defaults.set("pink", forKey: ChekinanaThemePreference.defaultsKey)
        XCTAssertEqual(store.theme, .aqua)
        XCTAssertEqual(renderState.theme, .aqua)
    }

    func testGalleryAddPhotoAndVideoCopyIsLocalizedWithoutChekiInEnglish() throws {
        let expected = [
            "en": ("Add Photo", "Add Video"),
            "ja": ("写メを追加", "動画を追加"),
            "zh-Hans": ("添加手机合影", "添加视频"),
            "zh-Hant": ("新增手機合照", "新增影片"),
        ]
        for (language, copy) in expected {
            let bundle = try localizedAppBundle(language: language)
            XCTAssertEqual(
                ChekinanaProductCopy.text(
                    "gallery.add.photo",
                    "Add Photo",
                    bundle: bundle
                ),
                copy.0,
                language
            )
            XCTAssertEqual(
                ChekinanaProductCopy.text(
                    "gallery.add.video",
                    "Add Video",
                    bundle: bundle
                ),
                copy.1,
                language
            )
        }
    }

    func testManualIdolColorPolicyNormalizesOrRejectsBeforeSave() throws {
        XCTAssertNil(try ChekinanaIdolColorInputPolicy.normalizedStorageValue("  "))
        for preset in [
            "绿色", "蓝色", "水色", "紫色", "粉色", "红色", "橙色", "黄色", "白色",
        ] {
            XCTAssertEqual(
                try ChekinanaIdolColorInputPolicy.normalizedStorageValue(preset),
                preset
            )
        }
        XCTAssertEqual(
            try ChekinanaIdolColorInputPolicy.normalizedStorageValue("green"),
            "绿色"
        )
        XCTAssertEqual(
            try ChekinanaIdolColorInputPolicy.normalizedStorageValue("ピンク"),
            "粉色"
        )
        XCTAssertEqual(
            try ChekinanaIdolColorInputPolicy.normalizedStorageValue("#abcdef"),
            "#ABCDEF"
        )
        XCTAssertEqual(
            try ChekinanaIdolColorInputPolicy.normalizedStorageValue("#4caf50"),
            "绿色"
        )
        XCTAssertThrowsError(
            try ChekinanaIdolColorInputPolicy.normalizedStorageValue("not-a-color")
        )
    }

    func testIdolPaletteUsesOneCanonicalRGBMappingForLocalizedAliases() throws {
        let expectedPink = ChekinanaIdolPalette.RGB(red: 244, green: 143, blue: 177)
        for value in ["粉色", "粉", "ピンク", "pink", "#F48FB1"] {
            XCTAssertEqual(ChekinanaIdolPalette.rgb(for: value), expectedPink, value)
            XCTAssertEqual(
                try ChekinanaIdolColorInputPolicy.normalizedStorageValue(value),
                "粉色",
                value
            )
        }
        XCTAssertEqual(
            ChekinanaIdolPalette.rgb(for: "緑色"),
            .init(red: 76, green: 175, blue: 80)
        )
        XCTAssertEqual(
            ChekinanaIdolPalette.rgb(for: "赤色"),
            .init(red: 244, green: 67, blue: 54)
        )
    }

    func testProductSourceKeepsAssistantEntryOpenAndValidatesColorFirst() throws {
        XCTAssertTrue(ChekinanaFeatureAvailability.assistantDrawerEntryEnabled)
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana/ChekinanaProductShell.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sidebarStart = try XCTUnwrap(source.range(of: "private struct ChekinanaSidebar: View {")?.lowerBound)
        let sidebarEnd = try XCTUnwrap(source.range(of: "private struct ChekinanaPageToolbar:")?.lowerBound)
        let sidebar = String(source[sidebarStart..<sidebarEnd])
        XCTAssertFalse(sidebar.contains("if ChekinanaFeatureAvailability.assistantDrawerEntryEnabled"))
        let assistantStart = try XCTUnwrap(sidebar.range(
            of: "title: ChekinanaProductCopy.text(\"sidebar.assistant\","
        )?.lowerBound)
        let matchStart = try XCTUnwrap(sidebar.range(
            of: "title: ChekinanaProductCopy.text(\"sidebar.match\","
        )?.lowerBound)
        let assistantRow = String(sidebar[assistantStart..<matchStart])
        XCTAssertFalse(assistantRow.contains("action: {}"))
        XCTAssertFalse(assistantRow.contains(".disabled(true)"))
        XCTAssertTrue(assistantRow.contains("action: openAssistant"))
        XCTAssertFalse(assistantRow.contains("prewarm"))
        XCTAssertTrue(source.contains("private func openAssistant()"))
        XCTAssertTrue(source.contains("ContentView("))
        let validation = try XCTUnwrap(source.range(
            of: "let normalizedColor = try ChekinanaIdolColorInputPolicy"
        )?.lowerBound)
        let mutation = try XCTUnwrap(source.range(
            of: "target.color = normalizedColor"
        )?.lowerBound)
        XCTAssertLessThan(validation, mutation)
        XCTAssertFalse(source.contains("default: return ChekinanaProductTheme.accent"))
        XCTAssertTrue(source.contains("ChekinanaGalleryAddCopy.photo"))
        XCTAssertTrue(source.contains("ChekinanaGalleryAddCopy.video"))
        XCTAssertFalse(source.contains("Label(\"Add Cheki photo\""))
        XCTAssertFalse(source.contains("Label(\"Add Cheki video\""))
        XCTAssertFalse(source.contains("case .shame: \"Add Shame\""))
        XCTAssertFalse(source.contains("case .douga: \"Add Douga\""))
    }

    func testThemeRenderPathUsesCachedStateInsteadOfReadingDefaultsPerColor() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana/ChekinanaPresentation.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("ChekinanaThemeStore.currentTheme.accent"))
        XCTAssertTrue(source.contains("ChekinanaThemeStore.currentTheme.softAccent"))
        XCTAssertFalse(source.contains(
            "static var accent: Color { ChekinanaThemePreference.theme().accent }"
        ))
        XCTAssertFalse(source.contains(
            "static var softAccent: Color { ChekinanaThemePreference.theme().softAccent }"
        ))
    }

    func testChekiRokuEntryUsesOnlyNewFileExportGuide() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Chekinana/ChekinanaChekiRokuImportWizard.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("\"import.export_steps\""))
        XCTAssertTrue(source.contains("ChekinanaChekiRokuNavigationTitle"))
        XCTAssertTrue(source.contains(".minimumScaleFactor(0.68)"))
        XCTAssertTrue(source.contains(".fileImporter("))
        XCTAssertFalse(source.contains("\"import.intro\""))
    }
}

private final class ChekiRokuBeforePersistGate: @unchecked Sendable {
    private let blocked = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func block() {
        blocked.signal()
        _ = released.wait(timeout: .now() + 10)
    }

    func waitUntilBlocked() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [blocked] in
                continuation.resume(
                    returning: blocked.wait(timeout: .now() + 10) == .success
                )
            }
        }
    }

    func release() {
        released.signal()
    }
}

private final class ChekiRokuReadPhaseGate: @unchecked Sendable {
    private let target: ChekinanaChekiRokuImport.ReadPhase
    private let lock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private var hasBlocked = false
    private var finished = false

    init(target: ChekinanaChekiRokuImport.ReadPhase) {
        self.target = target
    }

    func observe(_ phase: ChekinanaChekiRokuImport.ReadPhase) {
        lock.lock()
        if phase == .finished { finished = true }
        let shouldBlock = phase == target && !hasBlocked
        if shouldBlock { hasBlocked = true }
        lock.unlock()
        guard shouldBlock else { return }
        blocked.signal()
        _ = released.wait(timeout: .now() + 10)
    }

    func waitUntilBlocked() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [blocked] in
                continuation.resume(
                    returning: blocked.wait(timeout: .now() + 10) == .success
                )
            }
        }
    }

    func release() {
        released.signal()
    }

    var didFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

private final class Fixture {
    struct Entry { var name: String; var data: Data; var method: UInt16 = 0; var flags: UInt16 = 0; var crc: UInt32? = nil; var external: UInt32 = 0; var zip64 = false }
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let directory: URL
    init() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChekiRokuFixture-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func database(avatarPath: String? = nil, sql: String? = nil) throws -> Data {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).db"); var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        func exec(_ value: String) { XCTAssertEqual(sqlite3_exec(db, value, nil, nil, nil), SQLITE_OK, value) }
        exec("CREATE TABLE group_name(id INTEGER,name TEXT); CREATE TABLE member_info(id INTEGER,member_name TEXT,group_id INTEGER,red INTEGER,green INTEGER,blue INTEGER,image_path TEXT); CREATE TABLE cheki_info(member_id INTEGER,date INTEGER,count INTEGER,category_id INTEGER,memo TEXT);")
        exec("INSERT INTO group_name VALUES(1,'group'); INSERT INTO member_info VALUES(1,'idol',1,1,2,3,\(avatarPath.map { "'\($0)'" } ?? "NULL")); INSERT INTO cheki_info VALUES(1,1700000000000,1,1,'memo');")
        if let sql { exec(sql) }; return try Data(contentsOf: url)
    }
    func databaseFromScratch(sql: String) throws -> Data {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).db")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "fixture.sqlite", code: 1)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "fixture.sqlite",
                code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        return try Data(contentsOf: url)
    }
    func archive(database: Data) throws -> URL { try archive(entries: [.init(name: "version.json", data: Data(#"{"version":2}"#.utf8)), .init(name: "my.db", data: database)]) }
    func archive(entries: [Entry], multiDisk: Bool = false) throws -> URL {
        var out = Data(), central = Data(), offset = 0
        for entry in entries {
            let payload = try entry.method == 8 ? Self.deflate(entry.data) : entry.data; let crc = entry.crc ?? Self.crc(of: entry.data); let name = Data(entry.name.utf8)
            Self.u32(&out, 0x04034B50); Self.u16(&out, 20); Self.u16(&out, entry.flags); Self.u16(&out, entry.method); Self.u16(&out, 0); Self.u16(&out, 0); Self.u32(&out, crc); Self.u32(&out, UInt32(payload.count)); Self.u32(&out, UInt32(entry.data.count)); Self.u16(&out, UInt16(name.count)); Self.u16(&out, 0); out.append(name); out.append(payload)
            Self.u32(&central, 0x02014B50); Self.u16(&central, 0x031E); Self.u16(&central, 20); Self.u16(&central, entry.flags); Self.u16(&central, entry.method); Self.u16(&central, 0); Self.u16(&central, 0); Self.u32(&central, crc); Self.u32(&central, entry.zip64 ? .max : UInt32(payload.count)); Self.u32(&central, entry.zip64 ? .max : UInt32(entry.data.count)); Self.u16(&central, UInt16(name.count)); Self.u16(&central, 0); Self.u16(&central, 0); Self.u16(&central, 0); Self.u16(&central, 0); Self.u32(&central, entry.external); Self.u32(&central, entry.zip64 ? .max : UInt32(offset)); central.append(name); offset = out.count
        }
        let centralOffset = out.count; out.append(central); Self.u32(&out, 0x06054B50); Self.u16(&out, multiDisk ? 1 : 0); Self.u16(&out, 0); Self.u16(&out, UInt16(entries.count)); Self.u16(&out, UInt16(entries.count)); Self.u32(&out, UInt32(central.count)); Self.u32(&out, UInt32(centralOffset)); Self.u16(&out, 0)
        let url = directory.appendingPathComponent("archive-\(UUID().uuidString).chekiroku"); try out.write(to: url); return url
    }
    static func tempImportDirectories() -> Int { ((try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory.appendingPathComponent("ChekinanaChekiRoku"), includingPropertiesForKeys: nil)) ?? []).count }
    static func crc(of data: Data) -> UInt32 { UInt32(truncatingIfNeeded: crc32(0, [UInt8](data), uInt(data.count))) }
    static func deflate(_ data: Data) throws -> Data { var z = z_stream(); var out = Data(count: data.count + 128); let outputCapacity = out.count; let status = data.withUnsafeBytes { input in out.withUnsafeMutableBytes { output -> Int32 in z.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress); z.avail_in = uInt(data.count); z.next_out = output.bindMemory(to: Bytef.self).baseAddress; z.avail_out = uInt(outputCapacity); guard deflateInit2_(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Z_STREAM_ERROR }; defer { deflateEnd(&z) }; return zlib.deflate(&z, Z_FINISH) } }; guard status == Z_STREAM_END else { throw NSError(domain: "fixture", code: Int(status)) }; out.count = Int(z.total_out); return out }
    static func u16(_ data: inout Data, _ value: UInt16) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
    static func u32(_ data: inout Data, _ value: UInt32) { u16(&data, UInt16(value & 65535)); u16(&data, UInt16(value >> 16)) }
}

private actor ChekiRokuCatalogueSearchProbe {
    private var names: [String] = []
    private var active = 0
    private var peak = 0

    func search(_ name: String) async throws -> [ChekinanaEnrichedIdol] {
        names.append(name); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 2_000_000)
        return []
    }

    func snapshot() -> ([String], Int) { (names, peak) }
}

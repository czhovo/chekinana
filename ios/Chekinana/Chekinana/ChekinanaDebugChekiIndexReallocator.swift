#if DEBUG
import CryptoKit
import Foundation
import SQLite3

/// Explicit maintenance entry, called before opening any ModelContainer. Normal
/// launches never enter it. The active store is updated in place; no file is
/// promoted, replaced, imported, or deleted.
enum ChekinanaDebugChekiIndexReallocator {
    static let requestKey = "CHEKINANA_DEBUG_REALLOCATE_CHEKI_IDX"
    static let expectedDigestKey = "CHEKINANA_DEBUG_REALLOCATE_CHEKI_EXPECTED_SHA256"

    enum Mode: String { case dryRun = "dry-run", apply }

    struct Assignment: Codable, Equatable {
        let primaryKey: Int64
        let idHex: String
        let oldIndex: Int64?
        let newIndex: Int64
    }

    struct Report: Codable {
        let status: String
        let mode: String
        let chekiCount: Int
        let groupCount: Int
        let changedCount: Int
        let rowCounts: [String: Int]
        let beforeDigest: String
        let afterDigest: String
        let protectedDigest: String
        let assignments: [Assignment]
    }

    enum MaintenanceError: Error {
        case invalidRequest, unexpectedStore, invalidSchema, invalidRow, duplicateIdentity
        case sql(Int32), digestMismatch, protectedDataChanged, updateCountMismatch
        case injectedFailure, postCommitVerificationFailed
    }

    /// A true return means the caller must not proceed to the normal app/store
    /// startup, including on failure. This keeps legacy startup repair and media
    /// cleanup out of an explicitly requested index-only maintenance session.
    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let rawMode = environment[requestKey] else { return false }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekinanaChekiIndexMaintenance", isDirectory: true)
            .appendingPathComponent("report.json")
        do {
            guard let mode = Mode(rawValue: rawMode),
                  environment.filter({ $0.key.hasPrefix("CHEKINANA_") &&
                      $0.key != requestKey && $0.key != expectedDigestKey })
                    .allSatisfy({ !$0.key.contains("DEBUG_") && !$0.key.contains("UI_") }) else {
                throw MaintenanceError.invalidRequest
            }
            let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
            let marker = root.appendingPathComponent("Chekinana-production-active-store")
            struct Marker: Decodable { let schemaVersion: Int; let directoryName: String }
            let value = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: marker))
            guard value.schemaVersion == 17, value.directoryName.hasPrefix("store-"),
                  UUID(uuidString: String(value.directoryName.dropFirst(6))) != nil else {
                throw MaintenanceError.unexpectedStore
            }
            let store = root.appendingPathComponent("Chekinana-production-stores", isDirectory: true)
                .appendingPathComponent(value.directoryName, isDirectory: true)
                .appendingPathComponent("current.store")
            let expectedResolvedStore = root.resolvingSymlinksInPath()
                .appendingPathComponent("Chekinana-production-stores", isDirectory: true)
                .appendingPathComponent(value.directoryName, isDirectory: true)
                .appendingPathComponent("current.store").standardizedFileURL
            guard store.resolvingSymlinksInPath().standardizedFileURL == expectedResolvedStore,
                  FileManager.default.fileExists(atPath: store.path) else {
                throw MaintenanceError.unexpectedStore
            }
            _ = try execute(at: store, mode: mode,
                            expectedDigest: environment[expectedDigestKey], reportURL: output)
        } catch {
            // Error names/codes only: never serialize database values or paths
            // into an on-screen message or console log.
            let failure = ["status": "failed", "mode": rawMode,
                           "error": String(describing: error)]
            if let data = try? JSONEncoder().encode(failure) {
                try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? data.write(to: output, options: .atomic)
            }
        }
        return true
    }

    /// `failAfterUpdates` is test-only fault injection, never accepted from
    /// launch configuration. Audit files are separate from the active store.
    static func execute(at store: URL, mode: Mode, expectedDigest: String?, reportURL: URL,
                        failAfterUpdates: Int? = nil) throws -> Report {
        if mode == .apply {
            guard let expectedDigest, expectedDigest.count == 64,
                  expectedDigest.allSatisfy({ $0.isHexDigit }) else {
                throw MaintenanceError.invalidRequest
            }
        }
        var handle: OpaquePointer?
        let flags = mode == .apply ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        let opened = sqlite3_open_v2(store.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw MaintenanceError.sql(opened)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        try command(db, mode == .apply ? "BEGIN IMMEDIATE" : "BEGIN")
        var transactionOpen = true
        defer { if transactionOpen { try? command(db, "ROLLBACK") } }

        let before = try snapshot(db)
        if mode == .apply, before.digest != expectedDigest?.lowercased() {
            throw MaintenanceError.digestMismatch
        }
        let plan = try assignments(db)
        let changes = plan.values.filter { $0.oldIndex != $0.newIndex }
        let pending = Report(status: "prepared", mode: mode.rawValue,
                             chekiCount: plan.values.count, groupCount: plan.groups,
                             changedCount: changes.count, rowCounts: before.rowCounts,
                             beforeDigest: before.digest, afterDigest: before.digest,
                             protectedDigest: before.protectedDigest, assignments: plan.values)
        // Persist the exact old/new values before the first UPDATE so a bounded
        // inverse UPDATE remains possible even if the process is interrupted.
        if mode == .apply { try write(pending, to: reportURL.deletingLastPathComponent()
            .appendingPathComponent("prepared.json")) }
        if mode == .apply {
            let update = try prepare(db, "UPDATE ZMEDIAITEM SET ZIDX=? WHERE Z_PK=? AND ZKINDRAWVALUE='cheki' AND ZIDX IS ?")
            defer { sqlite3_finalize(update) }
            for (offset, value) in changes.enumerated() {
                sqlite3_reset(update)
                sqlite3_clear_bindings(update)
                try bind(value.newIndex, to: update, at: 1)
                try bind(value.primaryKey, to: update, at: 2)
                try bind(value.oldIndex, to: update, at: 3)
                let result = sqlite3_step(update)
                guard result == SQLITE_DONE else { throw MaintenanceError.sql(result) }
                guard sqlite3_changes(db) == 1 else { throw MaintenanceError.updateCountMismatch }
                if failAfterUpdates == offset + 1 { throw MaintenanceError.injectedFailure }
            }
            let after = try snapshot(db)
            guard after.protectedDigest == before.protectedDigest,
                  after.rowCounts == before.rowCounts else {
                throw MaintenanceError.protectedDataChanged
            }
            try verifyIndices(db, assignments: plan.values)
            try command(db, "COMMIT")
            transactionOpen = false
            // Read back after commit on the same original file. If this check
            // fails, keep prepared.json for an audited inverse-field operation.
            let committed = try snapshot(db)
            guard committed.digest == after.digest,
                  committed.protectedDigest == before.protectedDigest else {
                throw MaintenanceError.postCommitVerificationFailed
            }
            try verifyIndices(db, assignments: plan.values)
            let report = Report(status: "applied", mode: mode.rawValue,
                                chekiCount: plan.values.count, groupCount: plan.groups,
                                changedCount: changes.count, rowCounts: committed.rowCounts,
                                beforeDigest: before.digest, afterDigest: committed.digest,
                                protectedDigest: committed.protectedDigest, assignments: plan.values)
            try write(report, to: reportURL)
            return report
        }
        try command(db, "ROLLBACK")
        transactionOpen = false
        let report = Report(status: "dry-run", mode: mode.rawValue,
                            chekiCount: plan.values.count, groupCount: plan.groups,
                            changedCount: changes.count, rowCounts: before.rowCounts,
                            beforeDigest: before.digest, afterDigest: before.digest,
                            protectedDigest: before.protectedDigest, assignments: plan.values)
        try write(report, to: reportURL)
        return report
    }

    private struct Group: Hashable { let idols: Set<UUID>; let day: String? }
    private struct Row {
        let pk: Int64; let id: Data; let createdAt: Double; let old: Int64?; let group: Group
    }

    private static func assignments(_ db: OpaquePointer) throws -> (values: [Assignment], groups: Int) {
        let sql = "SELECT Z_PK,ZID,ZCREATEDAT,ZIDX,ZIDOLIDS,ZDATE FROM ZMEDIAITEM WHERE ZKINDRAWVALUE='cheki'"
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        var identities = Set<Data>()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw MaintenanceError.sql(step) }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                  [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(statement, 2)),
                  [SQLITE_NULL, SQLITE_INTEGER].contains(sqlite3_column_type(statement, 3)),
                  sqlite3_column_type(statement, 4) == SQLITE_BLOB else {
                throw MaintenanceError.invalidRow
            }
            let id = bytes(statement, column: 1)
            guard id.count == 16, identities.insert(id).inserted else {
                throw MaintenanceError.duplicateIdentity
            }
            let createdAt = sqlite3_column_double(statement, 2)
            guard createdAt.isFinite,
                  let encoded = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSData.self, from: bytes(statement, column: 4)) else {
                throw MaintenanceError.invalidRow
            }
            // Verified against the current device schema: SwiftData stores the
            // UUID array as JSON Data inside an NSKeyedArchiver NSData envelope.
            let idols = Set(try JSONDecoder().decode([UUID].self, from: encoded as Data))
            let day: String?
            if sqlite3_column_type(statement, 5) == SQLITE_NULL { day = nil }
            else {
                guard [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(statement, 5)) else {
                    throw MaintenanceError.invalidRow
                }
                let seconds = sqlite3_column_double(statement, 5)
                guard seconds.isFinite else { throw MaintenanceError.invalidRow }
                let value = calendar.dateComponents([.year, .month, .day],
                    from: Date(timeIntervalSinceReferenceDate: seconds))
                guard let year = value.year, let month = value.month, let dayValue = value.day else {
                    throw MaintenanceError.invalidRow
                }
                day = String(format: "%04d-%02d-%02d", year, month, dayValue)
            }
            rows.append(Row(pk: sqlite3_column_int64(statement, 0), id: id, createdAt: createdAt,
                            old: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 3),
                            group: Group(idols: idols, day: day)))
        }
        let groups = Dictionary(grouping: rows, by: \.group)
        var result: [Assignment] = []
        for members in groups.values {
            let ordered = members.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.lexicographicallyPrecedes($1.id)
            }
            for (offset, row) in ordered.enumerated() {
                result.append(Assignment(primaryKey: row.pk, idHex: hex(row.id), oldIndex: row.old,
                                         newIndex: Int64(offset + 1)))
            }
        }
        return (result.sorted { $0.primaryKey < $1.primaryKey }, groups.count)
    }

    private struct Snapshot {
        let digest: String; let protectedDigest: String; let rowCounts: [String: Int]
    }

    /// Exact type/byte serialization, including BLOBs and Z_OPT. Only a Cheki's
    /// ZIDX cell is masked in the protected digest; every non-Cheki cell and all
    /// other tables/schema entries remain part of the comparison.
    private static func snapshot(_ db: OpaquePointer) throws -> Snapshot {
        let schema = try prepare(db, "SELECT type,name,tbl_name,rootpage,sql FROM sqlite_master ORDER BY type,name")
        defer { sqlite3_finalize(schema) }
        var full = Data(), protected = Data()
        var tables: [String] = []
        while true {
            let step = sqlite3_step(schema)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw MaintenanceError.sql(step) }
            let row = try serializedRow(schema)
            append(row, to: &full); append(row, to: &protected)
            if text(schema, column: 0) == "table", let name = text(schema, column: 1) { tables.append(name) }
        }
        var counts: [String: Int] = [:]
        var foundMedia = false
        for name in tables.sorted() {
            let statement = try prepare(db, "SELECT * FROM \(quoted(name))")
            defer { sqlite3_finalize(statement) }
            let columns = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
            let indexColumn = columns.firstIndex(of: "ZIDX")
            let kindColumn = columns.firstIndex(of: "ZKINDRAWVALUE")
            if name == "ZMEDIAITEM" {
                guard indexColumn != nil, kindColumn != nil else { throw MaintenanceError.invalidSchema }
                foundMedia = true
            }
            var completeRows: [Data] = [], protectedRows: [Data] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw MaintenanceError.sql(step) }
                completeRows.append(try serializedRow(statement))
                let mask = name == "ZMEDIAITEM" && kindColumn.map({ text(statement, column: Int32($0)) == "cheki" }) == true
                    ? indexColumn : nil
                protectedRows.append(try serializedRow(statement, maskedColumn: mask))
            }
            counts[name] = completeRows.count
            append(Data(name.utf8), to: &full); append(Data(name.utf8), to: &protected)
            for column in columns { append(Data(column.utf8), to: &full); append(Data(column.utf8), to: &protected) }
            for row in completeRows.sorted(by: { $0.lexicographicallyPrecedes($1) }) { append(row, to: &full) }
            for row in protectedRows.sorted(by: { $0.lexicographicallyPrecedes($1) }) { append(row, to: &protected) }
        }
        guard foundMedia else { throw MaintenanceError.invalidSchema }
        return Snapshot(digest: hex(Data(SHA256.hash(data: full))),
                        protectedDigest: hex(Data(SHA256.hash(data: protected))), rowCounts: counts)
    }

    private static func serializedRow(_ statement: OpaquePointer, maskedColumn: Int? = nil) throws -> Data {
        var row = Data()
        for column in 0..<sqlite3_column_count(statement) {
            let type = maskedColumn == Int(column) ? SQLITE_NULL : sqlite3_column_type(statement, column)
            row.append(UInt8(type))
            switch type {
            case SQLITE_NULL: break
            case SQLITE_INTEGER:
                var value = sqlite3_column_int64(statement, column).bigEndian
                withUnsafeBytes(of: &value) { row.append(contentsOf: $0) }
            case SQLITE_FLOAT:
                var value = sqlite3_column_double(statement, column).bitPattern.bigEndian
                withUnsafeBytes(of: &value) { row.append(contentsOf: $0) }
            case SQLITE_TEXT, SQLITE_BLOB: append(bytes(statement, column: column), to: &row)
            default: throw MaintenanceError.invalidRow
            }
        }
        return row
    }

    private static func verifyIndices(_ db: OpaquePointer, assignments: [Assignment]) throws {
        let statement = try prepare(db, "SELECT Z_PK,ZID,ZIDX FROM ZMEDIAITEM WHERE ZKINDRAWVALUE='cheki'")
        defer { sqlite3_finalize(statement) }
        let expected = Dictionary(uniqueKeysWithValues: assignments.map { ($0.primaryKey, $0) })
        var count = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw MaintenanceError.sql(step) }
            guard let value = expected[sqlite3_column_int64(statement, 0)],
                  hex(bytes(statement, column: 1)) == value.idHex,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 2) == value.newIndex else {
                throw MaintenanceError.updateCountMismatch
            }
            count += 1
        }
        guard count == assignments.count else { throw MaintenanceError.updateCountMismatch }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw MaintenanceError.sql(result) }
        return statement
    }
    private static func command(_ db: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw MaintenanceError.sql(result) }
    }
    private static func bind(_ value: Int64?, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw MaintenanceError.sql(result) }
    }
    private static func bytes(_ statement: OpaquePointer, column: Int32) -> Data {
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: length)
    }
    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
        return String(data: bytes(statement, column: column), encoding: .utf8)
    }
    private static func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }
    private static func append(_ value: Data, to output: inout Data) {
        var count = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
        output.append(value)
    }
    private static func write(_ report: Report, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
#endif

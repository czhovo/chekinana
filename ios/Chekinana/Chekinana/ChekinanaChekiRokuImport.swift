import Foundation
import Dispatch
import SQLite3
import zlib

/// The fixed Idol palette used by ProductShell. Import keeps only its
/// canonical labels so imported and manually selected colours behave alike.
enum ChekinanaIdolPalette {
    struct RGB: Equatable, Sendable {
        let red: Int
        let green: Int
        let blue: Int
    }

    private static let values: [(name: String, red: Int, green: Int, blue: Int)] = [
        ("绿色", 76, 175, 80), ("蓝色", 33, 150, 243), ("水色", 129, 212, 250),
        ("紫色", 171, 71, 188), ("粉色", 244, 143, 177), ("红色", 244, 67, 54),
        ("橙色", 255, 152, 0), ("黄色", 255, 235, 59), ("白色", 224, 224, 224),
    ]

    private static let aliases: [(storage: String, values: Set<String>)] = [
        ("绿色", ["绿色", "绿", "綠色", "綠", "緑色", "緑", "green"]),
        ("蓝色", ["蓝色", "蓝", "藍色", "藍", "青色", "青", "blue"]),
        ("水色", ["水色", "浅蓝色", "淺藍色", "light blue", "lightblue", "aqua"]),
        ("紫色", ["紫色", "紫", "purple"]),
        ("粉色", ["粉色", "粉", "ピンク", "pink"]),
        ("红色", ["红色", "红", "紅色", "紅", "赤色", "赤", "red"]),
        ("橙色", ["橙色", "橙", "オレンジ", "orange"]),
        ("黄色", ["黄色", "黄", "黃色", "黃", "yellow"]),
        ("白色", ["白色", "白", "white"]),
    ]

    static var presetStorageValues: [String] { values.map(\.name) }

    static func canonicalPresetName(_ rawValue: String) -> String? {
        let folded = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return aliases.first { $0.values.contains(folded) }?.storage
    }

    static func rgb(for rawValue: String) -> RGB? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let canonical = canonicalPresetName(trimmed),
           let preset = values.first(where: { $0.name == canonical }) {
            return RGB(red: preset.red, green: preset.green, blue: preset.blue)
        }
        let hex = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
        guard hex.count == 7, let raw = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        return RGB(
            red: Int((raw >> 16) & 0xFF),
            green: Int((raw >> 8) & 0xFF),
            blue: Int(raw & 0xFF)
        )
    }

    static func storageValue(red: Int, green: Int, blue: Int) -> String {
        if let preset = values.first(where: { $0.red == red && $0.green == green && $0.blue == blue }) {
            return preset.name
        }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func presetName(hex: String) -> String? {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#",
              let raw = UInt32(value.dropFirst(), radix: 16) else { return nil }
        let red = Int((raw >> 16) & 0xFF), green = Int((raw >> 8) & 0xFF), blue = Int(raw & 0xFF)
        return values.first(where: { $0.red == red && $0.green == green && $0.blue == blue })?.name
    }
}

/// The ChekiRoku interchange reader deliberately accepts a small, auditable
/// ZIP subset only.  It never trusts a path recorded by the exporting app.
enum ChekinanaChekiRokuImport {
    enum Error: LocalizedError { case invalid(String); case sqlite(String)
        var errorDescription: String? { switch self { case .invalid(let s), .sqlite(let s): s } }
    }
    struct ReadLimits: Sendable {
        var maximumScannedRows: Int
        var progressInstructionInterval: Int32
        var maximumApproximateVMInstructions: Int
        var maximumDurationNanoseconds: UInt64

        static let standard = ReadLimits(
            maximumScannedRows: 11_100,
            progressInstructionInterval: 1_000,
            maximumApproximateVMInstructions: 50_000_000,
            maximumDurationNanoseconds: 15_000_000_000
        )
    }

    enum ReadPhase: Equatable, Sendable {
        case beforePrepare(String)
        case beforeStep(String)
        case betweenQueries(String, String)
        case beforePublication
        case finished
    }

    struct ReadTestingHooks: @unchecked Sendable {
        let onPhase: @Sendable (ReadPhase) -> Void
    }

    final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        fileprivate var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    struct SourceIdol: Identifiable, Sendable { let id: Int; var name, group, color: String; let avatarName: String? }
    struct SourceRecord: Sendable { let memberID: Int; let date: Date?; let count, category: Int; let memo: String }
    struct Archive: Sendable { let idols: [SourceIdol]; let records: [SourceRecord]; let imageData: [String: Data]; let temporaryDirectory: URL }

    static func read(
        _ url: URL,
        calendar: Calendar = .current,
        limits: ReadLimits = .standard,
        cancellationToken: CancellationToken = CancellationToken(),
        testingHooks: ReadTestingHooks? = nil
    ) throws -> Archive {
        try checkCancellation(cancellationToken)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 32 * 1_024 * 1_024 else { throw Error.invalid(ChekinanaL10n.text("import.error.file", fallback: "Import file is too large or invalid.")) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try checkCancellation(cancellationToken)
        let zip = try SafeZIP(data)
        let version = try zip.data(named: "version.json")
        guard let object = try JSONSerialization.jsonObject(with: version) as? [String: Any],
              (object["version"] as? Int) == 2 else { throw Error.invalid(ChekinanaL10n.text("import.error.version", fallback: "Unsupported ChekiRoku backup version.")) }
        let dbData = try zip.data(named: "my.db")
        try checkCancellation(cancellationToken)
        let directory = try makeTemporaryDirectory()
        var transferred = false
        defer { if !transferred { try? FileManager.default.removeItem(at: directory) } }
        let dbURL = directory.appendingPathComponent("my.db")
        try dbData.write(to: dbURL, options: [.atomic])
        let decoded = try readDatabase(
            dbURL,
            zip: zip,
            calendar: calendar,
            limits: limits,
            cancellationToken: cancellationToken,
            testingHooks: testingHooks
        )
        testingHooks?.onPhase(.beforePublication)
        try checkCancellation(cancellationToken)
        let archive = Archive(idols: decoded.idols, records: decoded.records, imageData: decoded.images, temporaryDirectory: directory)
        transferred = true
        testingHooks?.onPhase(.finished)
        return archive
    }

    static func readDetached(
        _ url: URL,
        calendar: Calendar = .current,
        limits: ReadLimits = .standard,
        testingHooks: ReadTestingHooks? = nil
    ) async throws -> Archive {
        let cancellationToken = CancellationToken()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try read(
                    url,
                    calendar: calendar,
                    limits: limits,
                    cancellationToken: cancellationToken,
                    testingHooks: testingHooks
                )
            }.value
        } onCancel: {
            cancellationToken.cancel()
        }
    }

    static func cleanup(_ archive: Archive) { try? FileManager.default.removeItem(at: archive.temporaryDirectory) }
    static func normalized(_ value: String?) -> String { (value ?? "").precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    static func fieldsMatch(_ a: String?, _ b: String?, isName: Bool = false) -> Bool {
        let x = normalized(a), y = normalized(b); if x.isEmpty || y.isEmpty { return !isName && x.isEmpty && y.isEmpty }
        return x == y || x.contains(y) || y.contains(x)
    }
    /// ChekiRoku stores a millisecond instant for a user-visible calendar day.
    /// Extract that day in the import-time time zone, then encode it in
    /// Chekinana's UTC date-only carrier. Persisting local midnight directly
    /// makes positive time zones appear as the previous UTC day.
    static func sourceDay(
        _ milliseconds: Int64?,
        calendar: Calendar = .current
    ) -> Date? {
        guard let milliseconds else { return nil }
        return ChekinanaDateOnly.canonicalDate(
            from: Date(
                timeIntervalSince1970: TimeInterval(milliseconds) / 1_000
            ),
            displayedIn: calendar
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ChekinanaChekiRoku", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir
    }
    private static func readDatabase(
        _ url: URL,
        zip: SafeZIP,
        calendar: Calendar,
        limits: ReadLimits,
        cancellationToken: CancellationToken,
        testingHooks: ReadTestingHooks?
    ) throws -> (idols: [SourceIdol], records: [SourceRecord], images: [String: Data]) {
        var dbPointer: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &dbPointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let db = dbPointer else {
            if let dbPointer { sqlite3_close(dbPointer) }
            throw Error.sqlite(ChekinanaL10n.text(
                "import.error.database_open",
                fallback: "Cannot open backup database."
            ))
        }
        defer { sqlite3_close(db) }

        let budget = SQLiteReadBudget(
            limits: limits,
            cancellationToken: cancellationToken
        )
        let retainedBudget = Unmanaged.passRetained(budget)
        sqlite3_progress_handler(
            db,
            limits.progressInstructionInterval,
            chekinanaChekiRokuSQLiteProgressHandler,
            retainedBudget.toOpaque()
        )
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            retainedBudget.release()
        }

        guard sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            try budget.checkpoint()
            throw databaseError()
        }

        var previousQuery: String?
        func rows(
            _ sql: String,
            label: String,
            _ block: (OpaquePointer?) throws -> Void
        ) throws {
            if let previousQuery {
                testingHooks?.onPhase(.betweenQueries(previousQuery, label))
            }
            previousQuery = label
            try budget.checkpoint()
            testingHooks?.onPhase(.beforePrepare(label))
            try budget.checkpoint()

            var statement: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard prepareResult == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                throw databaseError()
            }
            defer { sqlite3_finalize(statement) }

            while true {
                testingHooks?.onPhase(.beforeStep(label))
                try budget.checkpoint()
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    try budget.consumeRow()
                    try block(statement)
                    continue
                }
                try requireCompletedStep(result)
                return
            }
        }

        func validateOrdinaryTable(_ name: String) throws {
            var schemaType: String?
            var creationSQL: String?
            var schemaRows = 0
            try rows(
                "SELECT type,sql FROM main.sqlite_schema WHERE name='\(name)' COLLATE BINARY",
                label: "schema.\(name)"
            ) { statement in
                schemaRows += 1
                schemaType = try text(statement, 0, 32)
                creationSQL = try text(statement, 1, 16_384)
            }
            guard schemaRows == 1, schemaType == "table" else {
                throw requiredTableError()
            }

            if sqlite3_libversion_number() >= 3_037_000 {
                var tableListRows = 0
                var tableListType: String?
                try rows("PRAGMA main.table_list('\(name)')", label: "table_list.\(name)") { statement in
                    guard try text(statement, 0, 64) == "main",
                          try text(statement, 1, 512) == name else { return }
                    tableListRows += 1
                    tableListType = try text(statement, 2, 32)
                }
                guard tableListRows == 1, tableListType == "table" else {
                    throw requiredTableError()
                }
            } else {
                // PRAGMA table_list was added in SQLite 3.37. iOS 17 ships a
                // newer SQLite, but keep a fail-closed schema-text fallback so
                // the importer is not coupled to the build SDK's SQLite.
                guard isOrdinaryTableSchema(type: schemaType, sql: creationSQL) else {
                    throw requiredTableError()
                }
            }
        }

        func databaseError() -> Error {
            Error.sqlite(ChekinanaL10n.text(
                "import.error.database",
                fallback: "Invalid backup database."
            ))
        }

        func requiredTableError() -> Error {
            Error.sqlite(ChekinanaL10n.text(
                "import.error.required_table",
                fallback: "A required backup object is not an ordinary table."
            ))
        }

        func integer(_ s: OpaquePointer?, _ index: Int, _ range: ClosedRange<Int64>) throws -> Int {
            guard sqlite3_column_type(s, Int32(index)) == SQLITE_INTEGER else { throw Error.sqlite(ChekinanaL10n.text("import.error.integer", fallback: "Backup contains an invalid integer.")) }
            let value = sqlite3_column_int64(s, Int32(index)); guard range.contains(value) else { throw Error.sqlite(ChekinanaL10n.text("import.error.integer_range", fallback: "Backup integer is outside its allowed range.")) }; return Int(value)
        }
        func optionalInteger(
            _ s: OpaquePointer?,
            _ index: Int,
            _ range: ClosedRange<Int64>
        ) throws -> Int64? {
            let type = sqlite3_column_type(s, Int32(index))
            if type == SQLITE_NULL { return nil }
            guard type == SQLITE_INTEGER else {
                throw Error.sqlite(ChekinanaL10n.text(
                    "import.error.integer",
                    fallback: "Backup contains an invalid integer."
                ))
            }
            let value = sqlite3_column_int64(s, Int32(index))
            guard range.contains(value) else {
                throw Error.sqlite(ChekinanaL10n.text(
                    "import.error.integer_range",
                    fallback: "Backup integer is outside its allowed range."
                ))
            }
            return value
        }
        func text(_ s: OpaquePointer?, _ index: Int, _ limit: Int, nullable: Bool = false) throws -> String? {
            let type = sqlite3_column_type(s, Int32(index)); if type == SQLITE_NULL && nullable { return nil }
            guard type == SQLITE_TEXT, let raw = sqlite3_column_text(s, Int32(index)) else { throw Error.sqlite(ChekinanaL10n.text("import.error.text", fallback: "Backup contains invalid text.")) }
            let value = String(cString: raw); guard value.unicodeScalars.count <= limit else { throw Error.sqlite(ChekinanaL10n.text("import.error.text_length", fallback: "Backup text exceeds its allowed length.")) }; return value
        }
        try validateOrdinaryTable("group_name")
        try validateOrdinaryTable("member_info")
        try validateOrdinaryTable("cheki_info")

        var groups: [Int:String] = [:]
        var groupIDs = Set<Int>()
        try rows("SELECT id,name FROM main.group_name", label: "group_name") { s in
            guard groups.count < 500 else { throw Error.sqlite(ChekinanaL10n.text("import.error.groups", fallback: "Too many groups.")) }
            let id = try integer(s, 0, 1...Int64.max)
            guard groupIDs.insert(id).inserted else {
                throw Error.sqlite(ChekinanaL10n.text(
                    "import.error.duplicate_group_id",
                    fallback: "Backup contains a duplicate group ID."
                ))
            }
            groups[id] = try text(s, 1, 200)!
        }
        var idols:[SourceIdol]=[]; var wanted=Set<String>()
        var memberIDs = Set<Int>()
        try rows("SELECT id,member_name,group_id,red,green,blue,image_path FROM main.member_info", label: "member_info") { s in
            guard idols.count < 500 else { throw Error.sqlite(ChekinanaL10n.text("import.error.idols", fallback: "Too many Idols.")) }; let id = try integer(s, 0, 1...Int64.max); let groupID = try integer(s, 2, 1...Int64.max); guard let group = groups[groupID] else { throw Error.sqlite(ChekinanaL10n.text("import.error.group_reference", fallback: "Idol references an unknown group.")) }; let name = try text(s, 1, 200)!.trimmingCharacters(in: .whitespacesAndNewlines); let path = try text(s, 6, 4096, nullable: true); let avatar = path.map { URL(fileURLWithPath:$0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }; if let avatar { wanted.insert("images/" + avatar) }
            guard memberIDs.insert(id).inserted else {
                throw Error.sqlite(ChekinanaL10n.text(
                    "import.error.duplicate_member_id",
                    fallback: "Backup contains a duplicate Idol ID."
                ))
            }
            let red = try integer(s,3,0...255), green = try integer(s,4,0...255), blue = try integer(s,5,0...255)
            idols.append(SourceIdol(id:id, name:name, group:group, color:ChekinanaIdolPalette.storageValue(red: red, green: green, blue: blue), avatarName:avatar))
        }
        var records: [SourceRecord] = []
        var total = 0
        let members = Set(idols.map(\.id))
        try rows("SELECT member_id,date,count,category_id,memo FROM main.cheki_info", label: "cheki_info") { s in
            let category = try integer(s, 3, 1...3)
            // Chekinana imports only Cheki. Phone Photo/Video rows do not
            // participate in validation, limits, totals, planning or writes.
            guard category == 1 else { return }
            guard records.count < 10_000 else {
                throw Error.sqlite(ChekinanaL10n.text(
                    "import.error.records",
                    fallback: "Too many records."
                ))
            }
            let member = try integer(s, 0, 1...Int64.max)
            guard members.contains(member) else {
                throw Error.sqlite(ChekinanaL10n.text(
                    "import.error.idol_reference",
                    fallback: "Record references an unknown Idol."
                ))
            }
            let milliseconds = try optionalInteger(s, 1, 0...4_102_444_800_000)
            let count = try integer(s, 2, 1...1_000)
            let memo = try text(s, 4, 2_000, nullable: true) ?? ""
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow, next <= 10_000 else {
                throw Error.sqlite(ChekinanaL10n.text(
                    "import.error.objects",
                    fallback: "Too many target objects."
                ))
            }
            total = next
            records.append(SourceRecord(
                memberID: member,
                date: sourceDay(milliseconds, calendar: calendar),
                count: count,
                category: category,
                memo: memo
            ))
        }
        var images:[String:Data]=[:]
        for name in wanted {
            try budget.checkpoint()
            if let value = try? zip.data(named:name) {
                images[URL(fileURLWithPath:name).lastPathComponent] = value
            }
        }
        return (idols,records,images)
    }

    static func requireCompletedStep(_ result: Int32) throws {
        guard result == SQLITE_DONE else {
            throw Error.sqlite(ChekinanaL10n.text(
                "import.error.database",
                fallback: "Invalid backup database."
            ))
        }
    }

    static func isOrdinaryTableSchema(
        type: String?,
        sql: String?
    ) -> Bool {
        guard type == "table", let sql else { return false }
        let uncommented = sql
            .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"--[^\r\n]*"#, with: " ", options: .regularExpression)
        let words = uncommented
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        return words.count >= 2 && words[0] == "create" && words[1] == "table"
    }

    private static func checkCancellation(_ token: CancellationToken) throws {
        if token.isCancelled { throw CancellationError() }
    }
}

private final class SQLiteReadBudget: @unchecked Sendable {
    private let limits: ChekinanaChekiRokuImport.ReadLimits
    private let cancellationToken: ChekinanaChekiRokuImport.CancellationToken
    private let deadline: UInt64
    private let lock = NSLock()
    private var scannedRows = 0
    private var progressCallbacks = 0

    init(
        limits: ChekinanaChekiRokuImport.ReadLimits,
        cancellationToken: ChekinanaChekiRokuImport.CancellationToken
    ) {
        self.limits = limits
        self.cancellationToken = cancellationToken
        let now = DispatchTime.now().uptimeNanoseconds
        let (candidate, overflow) = now.addingReportingOverflow(limits.maximumDurationNanoseconds)
        deadline = overflow ? UInt64.max : candidate
    }

    func checkpoint() throws {
        guard !shouldInterrupt(countProgress: false) else {
            throw ChekinanaChekiRokuImport.Error.sqlite(ChekinanaL10n.text(
                "import.error.database_budget",
                fallback: "Backup database reading was cancelled or exceeded its resource limit."
            ))
        }
    }

    func consumeRow() throws {
        lock.lock()
        scannedRows += 1
        let exceeded = scannedRows > limits.maximumScannedRows
        lock.unlock()
        guard !exceeded else {
            throw ChekinanaChekiRokuImport.Error.sqlite(ChekinanaL10n.text(
                "import.error.database_budget",
                fallback: "Backup database reading was cancelled or exceeded its resource limit."
            ))
        }
        try checkpoint()
    }

    func progressShouldInterrupt() -> Bool {
        shouldInterrupt(countProgress: true)
    }

    private func shouldInterrupt(countProgress: Bool) -> Bool {
        if cancellationToken.isCancelled || DispatchTime.now().uptimeNanoseconds >= deadline {
            return true
        }
        lock.lock()
        if countProgress { progressCallbacks += 1 }
        let (instructions, overflow) = progressCallbacks.multipliedReportingOverflow(
            by: Int(limits.progressInstructionInterval)
        )
        lock.unlock()
        return overflow || instructions > limits.maximumApproximateVMInstructions
    }
}

private func chekinanaChekiRokuSQLiteProgressHandler(
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 1 }
    let budget = Unmanaged<SQLiteReadBudget>
        .fromOpaque(context)
        .takeUnretainedValue()
    return budget.progressShouldInterrupt() ? 1 : 0
}

private struct SafeZIP {
    private struct Entry { let name:String; let method:Int; let compressed:Int; let uncompressed:Int; let crc:UInt32; let offset:Int }
    private let data:Data; private let entries:[String:Entry]
    init(_ data: Data) throws {
        guard data.count >= 22 else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip", fallback: "Invalid ZIP.")) }; self.data=data
        func u16(_ i:Int)->Int { Int(data[i]) | Int(data[i+1]) << 8 }; func u32(_ i:Int)->Int { u16(i) | u16(i+2) << 16 }
        let start=max(0,data.count-65_557); guard let e=(start...(data.count-22)).reversed().first(where:{ u32($0)==0x06054b50 }) else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_directory", fallback: "ZIP directory missing.")) }
        guard u16(e+4)==0, u16(e+6)==0, u16(e+8)==u16(e+10), u16(e+20)==0 else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_variant", fallback: "Multipart or Zip64 archives are not supported.")) }
        let n=u16(e+10), size=u32(e+12), p0=u32(e+16); guard n <= 256, size <= data.count, p0 <= data.count-size else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_limits", fallback: "ZIP limits exceeded.")) }
        var p=p0, out:[String:Entry]=[:], total=0
        for _ in 0..<n { guard p+46<=data.count,u32(p)==0x02014b50 else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_entry", fallback: "Invalid ZIP entry.")) }; let flags=u16(p+8), method=u16(p+10), cs=u32(p+20), us=u32(p+24), nl=u16(p+28), xl=u16(p+30), cl=u16(p+32), ext=u32(p+38), off=u32(p+42); guard flags & 1 == 0, flags & 8 == 0, (method==0 || method==8), cs != 0xffff_ffff, us != 0xffff_ffff, off != 0xffff_ffff, p+46+nl+xl+cl<=data.count else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_unsafe", fallback: "Unsafe ZIP entry.")) }; let name=String(data:data.subdata(in:p+46..<p+46+nl),encoding:.utf8) ?? ""; let unixFileType=(ext >> 16) & 0xF000; guard !name.isEmpty,!name.hasPrefix("/"),!name.contains("\\"),!name.contains("\0"),!name.split(separator:"/").contains(".."),(unixFileType == 0 || unixFileType == 0x8000) else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_path", fallback: "Unsafe ZIP path.")) }; guard out[name] == nil else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_duplicate", fallback: "Duplicate ZIP entry.")) }; total += us; guard total<=64*1_024*1_024, us<=16*1_024*1_024, cs==0 || us/cs<=100 else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_expansion", fallback: "ZIP expansion limit exceeded.")) }; out[name]=Entry(name:name,method:method,compressed:cs,uncompressed:us,crc:UInt32(truncatingIfNeeded:u32(p+16)),offset:off); p += 46+nl+xl+cl }
        guard p==p0+size, out["my.db"] != nil, out["version.json"] != nil else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.entries", fallback: "Required backup entries are missing.")) }; entries=out
    }
    func data(named name:String) throws -> Data { guard let e=entries[name] else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.entry", fallback: "Required backup entry missing.")) }; func u16(_ i:Int)->Int { Int(data[i])|Int(data[i+1])<<8 }; func u32(_ i:Int)->Int { u16(i)|u16(i+2)<<16 }; guard e.offset+30<=data.count,u32(e.offset)==0x04034b50,u16(e.offset+8)==e.method else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_header", fallback: "Invalid ZIP local header.")) }; let nl=u16(e.offset+26),xl=u16(e.offset+28), s=e.offset+30+nl+xl; guard s<=data.count-e.compressed, String(data:data.subdata(in:e.offset+30..<e.offset+30+nl),encoding:.utf8)==name else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_mismatch", fallback: "ZIP entry mismatch.")) }; let input=data.subdata(in:s..<s+e.compressed); let output:Data; if e.method==0 { output=input } else { output=try inflate(input, expected:e.uncompressed) }; guard output.count==e.uncompressed, output.withUnsafeBytes({ bytes in crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) })==e.crc else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_integrity", fallback: "ZIP integrity check failed.")) }; return output }
    private func inflate(_ input:Data, expected:Int) throws -> Data { var z=z_stream(); var result=Data(count:expected); let code=input.withUnsafeBytes { i in result.withUnsafeMutableBytes { o -> Int32 in z.next_in=UnsafeMutablePointer(mutating:i.bindMemory(to:Bytef.self).baseAddress); z.avail_in=uInt(input.count); z.next_out=o.bindMemory(to:Bytef.self).baseAddress; z.avail_out=uInt(expected); guard inflateInit2_(&z,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else{return Z_STREAM_ERROR}; defer{inflateEnd(&z)}; return zlib.inflate(&z,Z_FINISH) } }; guard code==Z_STREAM_END, z.avail_out==0 else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_compressed", fallback: "Invalid compressed ZIP data.")) }; return result }
}

/// A catalogue result belongs to the exact editable name/group pair reviewed by
/// the user. Neither partial-name matches nor an unverified group can create a
/// catalogue identity during ChekiRoku import.
enum ChekiRokuCatalogueMatching {
    /// Matching only: preserve source names and the API's spaced search term.
    static func matchingKey(_ value: String?) -> String {
        let compatible = (value ?? "").precomposedStringWithCompatibilityMapping
        let compact = String(String.UnicodeScalarView(
            compatible.unicodeScalars.filter { !$0.properties.isWhitespace }
        ))
        return compact.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    struct Query: Hashable, Sendable {
        let name: String
        let group: String
        let searchName: String
        init(name: String, group: String) {
            self.name = ChekiRokuCatalogueMatching.matchingKey(name)
            self.group = ChekiRokuCatalogueMatching.matchingKey(group)
            self.searchName = ChekinanaChekiRokuImport.normalized(name)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.group == rhs.group
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(group)
        }
    }

    enum Fallback: String, Sendable {
        case missingGroup, notFound, groupMismatch, ambiguous, unavailable, incomplete, invalidMetadata
    }

    enum Outcome: Equatable, Sendable {
        case matched(ChekinanaEnrichedIdol)
        case fallback(Fallback)
    }

    struct Resolution: Equatable, Sendable {
        let query: Query
        let outcome: Outcome
    }

    static func match(_ query: Query, candidates: [ChekinanaEnrichedIdol]) -> Outcome {
        guard !query.group.isEmpty else { return .fallback(.missingGroup) }
        guard !query.name.isEmpty else { return .fallback(.notFound) }
        // The existing search contract returns at most 200 candidates. Its
        // count is not a documented total, so never infer uniqueness at the cap.
        guard candidates.count < 200 else { return .fallback(.incomplete) }
        let sameName = candidates.filter {
            matchingKey($0.idolName) == query.name
        }
        guard !sameName.isEmpty else { return .fallback(.notFound) }
        let exact = sameName.filter {
            matchingKey($0.groupName) == query.group
        }
        guard !exact.isEmpty else { return .fallback(.groupMismatch) }
        guard let candidate = exact.first,
              exact.allSatisfy({ $0 == candidate }) else { return .fallback(.ambiguous) }
        guard !candidate.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.birthdayIsInvalid else { return .fallback(.invalidMetadata) }
        return .matched(candidate)
    }

    typealias Search = @Sendable (String) async throws -> [ChekinanaEnrichedIdol]
    private struct Response: Sendable {
        let name: String
        let candidates: [ChekinanaEnrichedIdol]
        let failure: Fallback?
    }

    static func resolve(
        _ queries: [Query],
        search: @escaping Search = { try await ChekinanaIdolEnrichmentClient().search(for: $0) }
    ) async throws -> [Query: Resolution] {
        try Task.checkCancellation()
        let unique = Set(queries)
        var resolutions: [Query: Resolution] = [:]
        let searchable = unique.filter { !$0.name.isEmpty && !$0.group.isEmpty }
        for query in unique where !searchable.contains(query) {
            resolutions[query] = .init(query: query, outcome: .fallback(
                query.group.isEmpty ? .missingGroup : .notFound
            ))
        }
        let byName = Dictionary(grouping: searchable, by: \.name)
        let searchNames = Dictionary(
            queries.map { ($0.name, $0.searchName) },
            uniquingKeysWith: { first, _ in first }
        )
        let names = byName.keys.sorted()
        try await withThrowingTaskGroup(of: Response.self) { group in
            var next = 0
            func enqueue(_ name: String) {
                group.addTask {
                    do {
                        let candidates = try await search(searchNames[name] ?? name)
                        try Task.checkCancellation()
                        return Response(name: name, candidates: candidates, failure: nil)
                    } catch {
                        // The existing client wraps URLSession cancellation in
                        // .network; cancellation is never a fallback decision.
                        try Task.checkCancellation()
                        if error is CancellationError { throw CancellationError() }
                        if let error = error as? ChekinanaIdolEnrichmentError,
                           case .notFound = error {
                            return Response(name: name, candidates: [], failure: .notFound)
                        }
                        return Response(name: name, candidates: [], failure: .unavailable)
                    }
                }
            }
            while next < min(4, names.count) { enqueue(names[next]); next += 1 }
            while let response = try await group.next() {
                try Task.checkCancellation()
                for query in byName[response.name] ?? [] {
                    let outcome = response.failure.map(Outcome.fallback)
                        ?? match(query, candidates: response.candidates)
                    resolutions[query] = .init(query: query, outcome: outcome)
                }
                if next < names.count { enqueue(names[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
        return resolutions
    }
}

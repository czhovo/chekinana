import Foundation
import SQLite3
import zlib

/// The fixed Idol palette used by ProductShell. Import keeps only its
/// canonical labels so imported and manually selected colours behave alike.
enum ChekinanaIdolPalette {
    private static let values: [(name: String, red: Int, green: Int, blue: Int)] = [
        ("绿色", 76, 175, 80), ("蓝色", 33, 150, 243), ("水色", 129, 212, 250),
        ("紫色", 171, 71, 188), ("粉色", 244, 143, 177), ("红色", 244, 67, 54),
        ("橙色", 255, 152, 0), ("黄色", 255, 235, 59), ("白色", 224, 224, 224),
    ]

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
    struct SourceIdol: Identifiable, Sendable { let id: Int; var name, group, color: String; let avatarName: String? }
    struct SourceRecord: Sendable { let memberID: Int; let date: Date?; let count, category: Int; let memo: String }
    struct Archive: Sendable { let idols: [SourceIdol]; let records: [SourceRecord]; let imageData: [String: Data]; let temporaryDirectory: URL }

    static func read(_ url: URL, calendar: Calendar = .current) throws -> Archive {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 32 * 1_024 * 1_024 else { throw Error.invalid(ChekinanaL10n.text("import.error.file", fallback: "Import file is too large or invalid.")) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let zip = try SafeZIP(data)
        let version = try zip.data(named: "version.json")
        guard let object = try JSONSerialization.jsonObject(with: version) as? [String: Any],
              (object["version"] as? Int) == 2 else { throw Error.invalid(ChekinanaL10n.text("import.error.version", fallback: "Unsupported ChekiRoku backup version.")) }
        let dbData = try zip.data(named: "my.db")
        let directory = try makeTemporaryDirectory()
        var transferred = false
        defer { if !transferred { try? FileManager.default.removeItem(at: directory) } }
        let dbURL = directory.appendingPathComponent("my.db")
        try dbData.write(to: dbURL, options: [.atomic])
        let decoded = try readDatabase(dbURL, zip: zip, calendar: calendar)
        let archive = Archive(idols: decoded.idols, records: decoded.records, imageData: decoded.images, temporaryDirectory: directory)
        transferred = true
        return archive
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
        calendar: Calendar
    ) throws -> (idols: [SourceIdol], records: [SourceRecord], images: [String: Data]) {
        var db: OpaquePointer?; guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else { throw Error.sqlite(ChekinanaL10n.text("import.error.database_open", fallback: "Cannot open backup database.")) }; defer { sqlite3_close(db) }
        _ = sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)
        func rows(_ sql: String, _ block: (OpaquePointer?) throws -> Void) throws { var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw Error.sqlite(ChekinanaL10n.text("import.error.database", fallback: "Invalid backup database.")) }; defer { sqlite3_finalize(s) }; while sqlite3_step(s) == SQLITE_ROW { try block(s) } }
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
        var groups: [Int:String] = [:]; try rows("SELECT id,name FROM group_name") { s in guard groups.count < 500 else { throw Error.sqlite(ChekinanaL10n.text("import.error.groups", fallback: "Too many groups.")) }; groups[try integer(s, 0, 1...Int64.max)] = try text(s, 1, 200)! }
        var idols:[SourceIdol]=[]; var wanted=Set<String>()
        try rows("SELECT id,member_name,group_id,red,green,blue,image_path FROM member_info") { s in
            guard idols.count < 500 else { throw Error.sqlite(ChekinanaL10n.text("import.error.idols", fallback: "Too many Idols.")) }; let id = try integer(s, 0, 1...Int64.max); let groupID = try integer(s, 2, 1...Int64.max); guard let group = groups[groupID] else { throw Error.sqlite(ChekinanaL10n.text("import.error.group_reference", fallback: "Idol references an unknown group.")) }; let name = try text(s, 1, 200)!.trimmingCharacters(in: .whitespacesAndNewlines); let path = try text(s, 6, 4096, nullable: true); let avatar = path.map { URL(fileURLWithPath:$0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }; if let avatar { wanted.insert("images/" + avatar) }
            let red = try integer(s,3,0...255), green = try integer(s,4,0...255), blue = try integer(s,5,0...255)
            idols.append(SourceIdol(id:id, name:name, group:group, color:ChekinanaIdolPalette.storageValue(red: red, green: green, blue: blue), avatarName:avatar))
        }
        var records: [SourceRecord] = []
        var total = 0
        let members = Set(idols.map(\.id))
        try rows("SELECT member_id,date,count,category_id,memo FROM cheki_info") { s in
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
        var images:[String:Data]=[:]; for name in wanted { if let value = try? zip.data(named:name) { images[URL(fileURLWithPath:name).lastPathComponent] = value } }
        return (idols,records,images)
    }
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
    func data(named name:String) throws -> Data { guard let e=entries[name] else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.entry", fallback: "Required backup entry missing.")) }; func u16(_ i:Int)->Int { Int(data[i])|Int(data[i+1])<<8 }; func u32(_ i:Int)->Int { u16(i)|u16(i+2)<<16 }; guard e.offset+30<=data.count,u32(e.offset)==0x04034b50,u16(e.offset+8)==e.method else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_header", fallback: "Invalid ZIP local header.")) }; let nl=u16(e.offset+26),xl=u16(e.offset+28), s=e.offset+30+nl+xl; guard s<=data.count-e.compressed, String(data:data.subdata(in:e.offset+30..<e.offset+30+nl),encoding:.utf8)==name else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_mismatch", fallback: "ZIP entry mismatch.")) }; let input=data.subdata(in:s..<s+e.compressed); let output:Data; if e.method==0 { output=input } else { output=try inflate(input, expected:e.uncompressed) }; guard output.count==e.uncompressed, crc32(0, [UInt8](output), uInt(output.count))==e.crc else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_integrity", fallback: "ZIP integrity check failed.")) }; return output }
    private func inflate(_ input:Data, expected:Int) throws -> Data { var z=z_stream(); var result=Data(count:expected); let code=input.withUnsafeBytes { i in result.withUnsafeMutableBytes { o -> Int32 in z.next_in=UnsafeMutablePointer(mutating:i.bindMemory(to:Bytef.self).baseAddress); z.avail_in=uInt(input.count); z.next_out=o.bindMemory(to:Bytef.self).baseAddress; z.avail_out=uInt(expected); guard inflateInit2_(&z,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else{return Z_STREAM_ERROR}; defer{inflateEnd(&z)}; return zlib.inflate(&z,Z_FINISH) } }; guard code==Z_STREAM_END, z.avail_out==0 else { throw ChekinanaChekiRokuImport.Error.invalid(ChekinanaL10n.text("import.error.zip_compressed", fallback: "Invalid compressed ZIP data.")) }; return result }
}

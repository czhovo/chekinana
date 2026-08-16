import Foundation
import SwiftData

enum ChekiSize: String, Codable, CaseIterable, Identifiable {
    case mini
    case wide
    case other = "else"

    var id: String {
        rawValue
    }
}

struct ChekinanaChekiDateBoundingBox: Equatable, Sendable {
    let x1: Int
    let y1: Int
    let x2: Int
    let y2: Int

    init?(x1: Int, y1: Int, x2: Int, y2: Int) {
        guard (0...1_000).contains(x1),
              (0...1_000).contains(y1),
              (0...1_000).contains(x2),
              (0...1_000).contains(y2),
              x1 < x2,
              y1 < y2 else {
            return nil
        }
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

struct ChekinanaChekiPixelBoundingBox: Equatable, Sendable {
    let x1: Int
    let y1: Int
    let x2: Int
    let y2: Int

    init?(x1: Int, y1: Int, x2: Int, y2: Int) {
        guard x1 < x2, y1 < y2 else {
            return nil
        }
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    func normalized(
        imageWidth: Int,
        imageHeight: Int
    ) -> ChekinanaChekiDateBoundingBox? {
        // ImageIO dimensions are bounded before this method is called. Keep a
        // defensive limit here so the integer scaling below cannot overflow.
        guard (1...1_000_000).contains(imageWidth),
              (1...1_000_000).contains(imageHeight) else {
            return nil
        }
        let clampedX1 = min(max(x1, 0), imageWidth)
        let clampedY1 = min(max(y1, 0), imageHeight)
        let clampedX2 = min(max(x2, 0), imageWidth)
        let clampedY2 = min(max(y2, 0), imageHeight)
        guard clampedX1 < clampedX2, clampedY1 < clampedY2 else {
            return nil
        }

        func scaledFloor(_ value: Int, dimension: Int) -> Int {
            Int(Int64(value) * 1_000 / Int64(dimension))
        }

        func scaledCeil(_ value: Int, dimension: Int) -> Int {
            let product = Int64(value) * 1_000
            let divisor = Int64(dimension)
            return Int((product + divisor - 1) / divisor)
        }

        return ChekinanaChekiDateBoundingBox(
            x1: scaledFloor(clampedX1, dimension: imageWidth),
            y1: scaledFloor(clampedY1, dimension: imageHeight),
            x2: scaledCeil(clampedX2, dimension: imageWidth),
            y2: scaledCeil(clampedY2, dimension: imageHeight)
        )
    }
}

struct ChekinanaChekiDateAnnotation: Equatable, Sendable {
    enum Precision: String, Equatable, Sendable {
        case fullDate = "full_date"
        case monthDay = "month_day"
    }

    let text: String
    let precision: Precision
    let boundingBox: ChekinanaChekiDateBoundingBox

    init?(
        text: String,
        precision: Precision,
        boundingBox: ChekinanaChekiDateBoundingBox
    ) {
        guard Self.isValid(text: text, precision: precision) else {
            return nil
        }
        self.text = text
        self.precision = precision
        self.boundingBox = boundingBox
    }

    static func isValid(text: String, precision: Precision) -> Bool {
        let calendarText: String
        switch precision {
        case .fullDate:
            guard text.range(
                of: #"^\d{4}\.\d{2}\.\d{2}$"#,
                options: .regularExpression
            ) != nil else {
                return false
            }
            calendarText = text.replacingOccurrences(of: ".", with: "-")
        case .monthDay:
            guard text.range(
                of: #"^\d{2}\.\d{2}$"#,
                options: .regularExpression
            ) != nil else {
                return false
            }
            // Use a leap year so a genuine 02.29 annotation is accepted
            // without inventing or persisting a year.
            calendarText = "2000-\(text.replacingOccurrences(of: ".", with: "-"))"
        }

        guard let date = ChekinanaDateOnly.parse(calendarText) else { return false }
        return ChekinanaDateOnly.string(date) == calendarText
    }
}

enum ChekinanaChekiDateAnnotationState: Equatable, Sendable {
    case notRequested
    case detected(ChekinanaChekiDateAnnotation)
    case notDetected
    case unavailable
}

struct ChekinanaEventDateCandidate: Equatable, Sendable {
    let id: UUID
    let date: Date?
}

enum ChekinanaEventAutoMatcher {
    static func uniqueEventID(
        for state: ChekinanaChekiDateAnnotationState,
        candidates: [ChekinanaEventDateCandidate]
    ) -> UUID? {
        guard case .detected(let annotation) = state else { return nil }
        let matches: [ChekinanaEventDateCandidate]
        switch annotation.precision {
        case .fullDate:
            guard let detected = parseFullDate(annotation.text) else { return nil }
            matches = candidates.filter { candidate in
                guard let date = candidate.date else { return false }
                return ChekinanaDateOnly.sameDay(date, detected)
            }
        case .monthDay:
            let parts = annotation.text.split(separator: ".")
            guard parts.count == 2,
                  let month = Int(parts[0]),
                  let day = Int(parts[1]) else { return nil }
            matches = candidates.filter { candidate in
                guard let date = candidate.date else { return false }
                let components = ChekinanaDateOnly.components(date)
                return components.month == month && components.day == day
            }
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func parseFullDate(_ value: String) -> Date? {
        ChekinanaDateOnly.parse(value.replacingOccurrences(of: ".", with: "-"))
    }
}

@Model
final class Idol {
    @Attribute(.unique) var id: UUID
    // Stable identifier from the Cloudflare idol catalogue. Historical local
    // records predate this field and intentionally remain nil.
    var sourceId: String?
    var name: String
    var group: String?
    var color: String?
    var birthday: String?
    var avatarImageRef: String?
    var isFavorite: Bool = false
    // Optional for a lightweight migration of existing stores. Until the user
    // reorders Idols, legacy rows retain deterministic creation order.
    var sortOrder: Double?
    var note: String
    @Relationship(deleteRule: .nullify, inverse: \Cheki.idols) var chekis: [Cheki]
    @Relationship(deleteRule: .nullify, inverse: \Shame.idols) var shames: [Shame]
    @Relationship(deleteRule: .nullify, inverse: \Douga.idols) var dougas: [Douga]
    var createdAt: Date
    var updatedAt: Date
    var verification: String?
    var bio: String?
    // Legacy single-prototype storage retained so existing installations can
    // migrate without losing an already saved encoder vector. New code reads
    // and writes `patterns`.
    var pattern: [Float]?
    var patterns: [[Float]] = []

    init(
        id: UUID = UUID(),
        sourceId: String? = nil,
        name: String,
        group: String? = nil,
        color: String? = nil,
        birthday: String? = nil,
        avatarImageRef: String? = nil,
        isFavorite: Bool = false,
        sortOrder: Double? = nil,
        note: String = "",
        chekis: [Cheki] = [],
        shames: [Shame] = [],
        dougas: [Douga] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        verification: String? = nil,
        bio: String? = nil,
        patterns: [[Float]] = []
    ) {
        self.id = id
        self.sourceId = sourceId
        self.name = name
        self.group = group
        self.color = color
        self.birthday = birthday
        self.avatarImageRef = avatarImageRef
        self.isFavorite = isFavorite
        self.sortOrder = sortOrder
        self.note = note
        self.chekis = chekis
        self.shames = shames
        self.dougas = dougas
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.verification = verification
        self.bio = bio
        self.pattern = nil
        self.patterns = patterns
    }

    /// All usable prototypes, including a legacy single vector until it has
    /// been copied into `patterns` by the launch migration.
    var recognitionPatterns: [[Float]] {
        var values = patterns.filter(ChekinanaPatternClassifier.isValidEmbedding)
        if ChekinanaPatternClassifier.isValidEmbedding(pattern),
           let pattern,
           !values.contains(pattern) {
            values.append(pattern)
        }
        return values
    }

    var hasRecognitionPatterns: Bool {
        !recognitionPatterns.isEmpty
    }

    @discardableResult
    func migrateLegacyPatternIfNeeded() -> Bool {
        guard ChekinanaPatternClassifier.isValidEmbedding(pattern),
              let pattern,
              !patterns.contains(pattern) else {
            return false
        }
        patterns.append(pattern)
        return true
    }
}

enum ChekinanaIdolOrdering {
    static func ordered(_ idols: [Idol]) -> [Idol] {
        idols.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            switch (lhs.sortOrder, rhs.sortOrder) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    @discardableResult
    static func move(_ sourceID: UUID, before targetID: UUID, in idols: [Idol]) -> Bool {
        guard sourceID != targetID,
              let source = idols.first(where: { $0.id == sourceID }),
              let target = idols.first(where: { $0.id == targetID }),
              source.isFavorite == target.isFavorite else { return false }
        var group = ordered(idols).filter { $0.isFavorite == source.isFavorite }
        guard let sourceIndex = group.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = group.firstIndex(where: { $0.id == targetID }) else { return false }
        let value = group.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        group.insert(value, at: insertionIndex)
        assignStableOrder(group)
        return true
    }

    @discardableResult
    static func move(_ idolID: UUID, offset: Int, in idols: [Idol]) -> Bool {
        guard offset != 0,
              let idol = idols.first(where: { $0.id == idolID }) else { return false }
        let group = ordered(idols).filter { $0.isFavorite == idol.isFavorite }
        guard let index = group.firstIndex(where: { $0.id == idolID }) else { return false }
        let destination = index + offset
        guard group.indices.contains(destination) else { return false }
        var reordered = group
        reordered.swapAt(index, destination)
        assignStableOrder(reordered)
        return true
    }

    static func previewMove(
        _ sourceID: UUID,
        onto targetID: UUID,
        in orderedIDs: [UUID],
        favoriteByID: [UUID: Bool]
    ) -> [UUID] {
        guard sourceID != targetID,
              favoriteByID[sourceID] == favoriteByID[targetID],
              let sourceIndex = orderedIDs.firstIndex(of: sourceID),
              let targetIndex = orderedIDs.firstIndex(of: targetID) else {
            return orderedIDs
        }
        var result = orderedIDs
        let moved = result.remove(at: sourceIndex)
        guard let targetIndexAfterRemoval = result.firstIndex(of: targetID) else {
            return orderedIDs
        }
        let insertionIndex = sourceIndex < targetIndex
            ? min(targetIndexAfterRemoval + 1, result.count)
            : targetIndexAfterRemoval
        result.insert(moved, at: insertionIndex)
        return result
    }

    @discardableResult
    static func applyPreviewOrder(
        _ orderedIDs: [UUID],
        favorite: Bool,
        in idols: [Idol]
    ) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: idols.map { ($0.id, $0) })
        let group = orderedIDs.compactMap { id -> Idol? in
            guard let idol = byID[id], idol.isFavorite == favorite else { return nil }
            return idol
        }
        let expectedIDs = Set(idols.filter { $0.isFavorite == favorite }.map(\.id))
        guard group.count == expectedIDs.count,
              Set(group.map(\.id)) == expectedIDs else {
            return false
        }
        let changed = group.enumerated().contains { index, idol in
            idol.sortOrder != Double(index)
        }
        guard changed else { return false }
        assignStableOrder(group)
        return true
    }

    static func toggleFavorite(_ idol: Idol, in idols: [Idol]) {
        let before = ordered(idols)
        assignStableOrder(before.filter(\.isFavorite))
        assignStableOrder(before.filter { !$0.isFavorite })
        idol.isFavorite.toggle()
        let targetGroup = idols.filter { $0.id != idol.id && $0.isFavorite == idol.isFavorite }
        idol.sortOrder = (targetGroup.compactMap(\.sortOrder).max() ?? -1) + 1
    }

    private static func assignStableOrder(_ idols: [Idol]) {
        for (index, idol) in idols.enumerated() {
            idol.sortOrder = Double(index)
        }
    }
}

enum ChekinanaIdolFavoriteAction {
    static func toggle(
        _ idol: Idol,
        in idols: [Idol],
        modelContext: ModelContext,
        now: Date = Date()
    ) throws {
        ChekinanaIdolOrdering.toggleFavorite(idol, in: idols)
        idol.updatedAt = now
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

@Model
final class Event {
    @Attribute(.unique) var id: UUID
    var name: String
    var date: Date?
    var city: String?
    var livehouse: String?
    // Keep the former persisted venue column readable while all new writes use
    // `livehouse`. Existing stores migrate this optional value without losing it.
    @Attribute(originalName: "venue") var legacyVenue: String?
    var avatarImageRef: String?
    var price: String?
    var weiboURL: URL?
    var ticketURL: URL?
    var note: String
    @Relationship(deleteRule: .nullify, inverse: \Cheki.event) var chekis: [Cheki]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        date: Date? = nil,
        city: String? = nil,
        livehouse: String? = nil,
        avatarImageRef: String? = nil,
        price: String? = nil,
        weiboURL: URL? = nil,
        ticketURL: URL? = nil,
        note: String = "",
        chekis: [Cheki] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.city = city
        self.livehouse = livehouse
        self.legacyVenue = nil
        self.avatarImageRef = avatarImageRef
        self.price = price
        self.weiboURL = weiboURL
        self.ticketURL = ticketURL
        self.note = note
        self.chekis = chekis
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var resolvedLivehouse: String? {
        let current = livehouse?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current, !current.isEmpty { return current }
        let legacy = legacyVenue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (legacy?.isEmpty == false) ? legacy : nil
    }
}

@Model
final class EventImage {
    @Attribute(.unique) var id: UUID
    var eventID: UUID
    var imageRef: String
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        eventID: UUID,
        imageRef: String,
        sortOrder: Int
    ) {
        self.id = id
        self.eventID = eventID
        self.imageRef = imageRef
        self.sortOrder = sortOrder
    }
}

@Model
final class Cheki {
    @Attribute(.unique) var id: UUID
    var idols: [Idol]
    var event: Event?
    // `date` is the calendar-day component of the Cheki business identity.
    // The original storage name preserves existing eventDate values without
    // fabricating a date for historical Event-only records.
    @Attribute(originalName: "eventDate") var date: Date?
    var idx: Int?
    // nil: unknown, false: user is not in frame, true: user appears in frame.
    var userAppears: Bool?
    var sizeRawValue: String?
    var imageRef: String?
    var isFavorite: Bool = false
    var hasPostedToSNS: Bool = false
    var note: String
    var createdAt: Date
    var updatedAt: Date

    var size: ChekiSize? {
        get {
            sizeRawValue.flatMap(ChekiSize.init(rawValue:))
        }
        set {
            sizeRawValue = newValue?.rawValue
        }
    }

    init(
        id: UUID = UUID(),
        idols: [Idol] = [],
        event: Event? = nil,
        date: Date? = nil,
        idx: Int? = nil,
        userAppears: Bool? = nil,
        size: ChekiSize? = nil,
        imageRef: String? = nil,
        isFavorite: Bool = false,
        hasPostedToSNS: Bool = false,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.idols = idols
        self.event = event
        self.date = date
        self.idx = idx
        self.userAppears = userAppears
        self.sizeRawValue = size?.rawValue
        self.imageRef = imageRef
        self.isFavorite = isFavorite
        self.hasPostedToSNS = hasPostedToSNS
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A regular phone photo kept alongside Cheki in Gallery. Product metadata is
/// intentionally limited to the imported image and the shared library fields.
@Model
final class Shame {
    @Attribute(.unique) var id: UUID
    var imageRef: String?
    @Relationship(deleteRule: .nullify) var idols: [Idol]
    var date: Date?
    var note: String

    init(
        id: UUID = UUID(),
        imageRef: String? = nil,
        idols: [Idol] = [],
        date: Date? = nil,
        note: String = ""
    ) {
        self.id = id
        self.imageRef = imageRef
        self.idols = idols
        self.date = date
        self.note = note
    }
}

/// An imported animation or video kept alongside Cheki in Gallery. The video
/// reference always names an app-managed copy, never a Photos temporary URL.
@Model
final class Douga {
    @Attribute(.unique) var id: UUID
    var videoRef: String?
    @Relationship(deleteRule: .nullify) var idols: [Idol]
    var date: Date?
    var note: String

    init(
        id: UUID = UUID(),
        videoRef: String? = nil,
        idols: [Idol] = [],
        date: Date? = nil,
        note: String = ""
    ) {
        self.id = id
        self.videoRef = videoRef
        self.idols = idols
        self.date = date
        self.note = note
    }
}

/// The schema used by every unversioned Chekinana store written before the
/// media-ownership repair. Nested model names deliberately remain exactly
/// `Idol`, `Event`, `Cheki`, `Shame`, and `Douga`; tests verify that physical
/// entity identity before exercising migration.
enum ChekinanaSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self]
    }

    @Model final class Idol {
        @Attribute(.unique) var id: UUID
        var sourceId: String?
        var name: String
        var group: String?
        var color: String?
        var birthday: String?
        var avatarImageRef: String?
        var isFavorite: Bool = false
        var sortOrder: Double?
        var note: String
        @Relationship(deleteRule: .nullify, inverse: \Cheki.idols) var chekis: [Cheki]
        var createdAt: Date
        var updatedAt: Date
        var verification: String?
        var bio: String?
        var pattern: [Float]?
        var patterns: [[Float]] = []

        init(
            id: UUID = UUID(),
            sourceId: String? = nil,
            name: String,
            group: String? = nil,
            color: String? = nil,
            birthday: String? = nil,
            avatarImageRef: String? = nil,
            isFavorite: Bool = false,
            sortOrder: Double? = nil,
            note: String = "",
            chekis: [Cheki] = [],
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            verification: String? = nil,
            bio: String? = nil,
            patterns: [[Float]] = []
        ) {
            self.id = id
            self.sourceId = sourceId
            self.name = name
            self.group = group
            self.color = color
            self.birthday = birthday
            self.avatarImageRef = avatarImageRef
            self.isFavorite = isFavorite
            self.sortOrder = sortOrder
            self.note = note
            self.chekis = chekis
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.verification = verification
            self.bio = bio
            self.pattern = nil
            self.patterns = patterns
        }
    }

    @Model final class Event {
        @Attribute(.unique) var id: UUID
        var name: String
        var date: Date?
        var city: String?
        var livehouse: String?
        @Attribute(originalName: "venue") var legacyVenue: String?
        var avatarImageRef: String?
        var price: String?
        var weiboURL: URL?
        var ticketURL: URL?
        var note: String
        @Relationship(deleteRule: .nullify, inverse: \Cheki.event) var chekis: [Cheki]
        @Relationship(deleteRule: .nullify, inverse: \Shame.event) var shames: [Shame]
        @Relationship(deleteRule: .nullify, inverse: \Douga.event) var dougas: [Douga]
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            date: Date? = nil,
            city: String? = nil,
            livehouse: String? = nil,
            avatarImageRef: String? = nil,
            price: String? = nil,
            weiboURL: URL? = nil,
            ticketURL: URL? = nil,
            note: String = "",
            chekis: [Cheki] = [],
            shames: [Shame] = [],
            dougas: [Douga] = [],
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.date = date
            self.city = city
            self.livehouse = livehouse
            self.legacyVenue = nil
            self.avatarImageRef = avatarImageRef
            self.price = price
            self.weiboURL = weiboURL
            self.ticketURL = ticketURL
            self.note = note
            self.chekis = chekis
            self.shames = shames
            self.dougas = dougas
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model final class Cheki {
        @Attribute(.unique) var id: UUID
        var idols: [Idol]
        var event: Event?
        @Attribute(originalName: "eventDate") var date: Date?
        var idx: Int?
        var userAppears: Bool?
        var sizeRawValue: String?
        var imageRef: String?
        var isFavorite: Bool = false
        var hasPostedToSNS: Bool = false
        var note: String
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            idols: [Idol] = [],
            event: Event? = nil,
            date: Date? = nil,
            idx: Int? = nil,
            userAppears: Bool? = nil,
            sizeRawValue: String? = nil,
            imageRef: String? = nil,
            isFavorite: Bool = false,
            hasPostedToSNS: Bool = false,
            note: String = "",
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.idols = idols
            self.event = event
            self.date = date
            self.idx = idx
            self.userAppears = userAppears
            self.sizeRawValue = sizeRawValue
            self.imageRef = imageRef
            self.isFavorite = isFavorite
            self.hasPostedToSNS = hasPostedToSNS
            self.note = note
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model final class Shame {
        @Attribute(.unique) var id: UUID
        var imageRef: String?
        @Relationship(deleteRule: .nullify) var idols: [Idol]
        var event: Event?
        var date: Date?
        var note: String

        init(
            id: UUID = UUID(),
            imageRef: String? = nil,
            idols: [Idol] = [],
            event: Event? = nil,
            date: Date? = nil,
            note: String = ""
        ) {
            self.id = id
            self.imageRef = imageRef
            self.idols = idols
            self.event = event
            self.date = date
            self.note = note
        }
    }

    @Model final class Douga {
        @Attribute(.unique) var id: UUID
        var videoRef: String?
        @Relationship(deleteRule: .nullify) var idols: [Idol]
        var event: Event?
        var date: Date?
        var note: String

        init(
            id: UUID = UUID(),
            videoRef: String? = nil,
            idols: [Idol] = [],
            event: Event? = nil,
            date: Date? = nil,
            note: String = ""
        ) {
            self.id = id
            self.videoRef = videoRef
            self.idols = idols
            self.event = event
            self.date = date
            self.note = note
        }
    }
}

/// Transitional schema that keeps the old relationship intact under a unique
/// name while freezing its destinations as scalar UUIDs. The scalar carrier
/// lets the next migration rebuild the corrected many-to-many relationship
/// without relying on Core Data to infer a changed inverse.
enum ChekinanaSchemaBridge: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self]
    }

    @Model final class Idol {
        @Attribute(.unique) var id: UUID
        var sourceId: String?
        var name: String
        var group: String?
        var color: String?
        var birthday: String?
        var avatarImageRef: String?
        var isFavorite: Bool = false
        var sortOrder: Double?
        var note: String
        @Relationship(deleteRule: .nullify, inverse: \Cheki.idols) var chekis: [Cheki]
        var createdAt: Date
        var updatedAt: Date
        var verification: String?
        var bio: String?
        var pattern: [Float]?
        var patterns: [[Float]] = []

        init(
            id: UUID = UUID(),
            name: String,
            note: String = "",
            chekis: [Cheki] = [],
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.sourceId = nil
            self.name = name
            self.group = nil
            self.color = nil
            self.birthday = nil
            self.avatarImageRef = nil
            self.isFavorite = false
            self.sortOrder = nil
            self.note = note
            self.chekis = chekis
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.verification = nil
            self.bio = nil
            self.pattern = nil
            self.patterns = []
        }
    }

    @Model final class Event {
        @Attribute(.unique) var id: UUID
        var name: String
        var date: Date?
        var city: String?
        var livehouse: String?
        @Attribute(originalName: "venue") var legacyVenue: String?
        var avatarImageRef: String?
        var price: String?
        var weiboURL: URL?
        var ticketURL: URL?
        var note: String
        @Relationship(deleteRule: .nullify, inverse: \Cheki.event) var chekis: [Cheki]
        @Relationship(deleteRule: .nullify, inverse: \Shame.event) var shames: [Shame]
        @Relationship(deleteRule: .nullify, inverse: \Douga.event) var dougas: [Douga]
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            note: String = "",
            chekis: [Cheki] = [],
            shames: [Shame] = [],
            dougas: [Douga] = [],
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.date = nil
            self.city = nil
            self.livehouse = nil
            self.legacyVenue = nil
            self.avatarImageRef = nil
            self.price = nil
            self.weiboURL = nil
            self.ticketURL = nil
            self.note = note
            self.chekis = chekis
            self.shames = shames
            self.dougas = dougas
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model final class Cheki {
        @Attribute(.unique) var id: UUID
        var idols: [Idol]
        var event: Event?
        @Attribute(originalName: "eventDate") var date: Date?
        var idx: Int?
        var userAppears: Bool?
        var sizeRawValue: String?
        var imageRef: String?
        var isFavorite: Bool = false
        var hasPostedToSNS: Bool = false
        var note: String
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            idols: [Idol] = [],
            event: Event? = nil,
            note: String = "",
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.idols = idols
            self.event = event
            self.date = nil
            self.idx = nil
            self.userAppears = nil
            self.sizeRawValue = nil
            self.imageRef = nil
            self.isFavorite = false
            self.hasPostedToSNS = false
            self.note = note
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model final class Shame {
        @Attribute(.unique) var id: UUID
        var imageRef: String?
        @Relationship(
            deleteRule: .nullify,
            originalName: "idols"
        ) var legacyIdols: [Idol]
        var migrationIdolIDs: [UUID] = []
        var event: Event?
        var date: Date?
        var note: String

        init(
            id: UUID = UUID(),
            imageRef: String? = nil,
            legacyIdols: [Idol] = [],
            migrationIdolIDs: [UUID] = [],
            event: Event? = nil,
            date: Date? = nil,
            note: String = ""
        ) {
            self.id = id
            self.imageRef = imageRef
            self.legacyIdols = legacyIdols
            self.migrationIdolIDs = migrationIdolIDs
            self.event = event
            self.date = date
            self.note = note
        }
    }

    @Model final class Douga {
        @Attribute(.unique) var id: UUID
        var videoRef: String?
        @Relationship(
            deleteRule: .nullify,
            originalName: "idols"
        ) var legacyIdols: [Idol]
        var migrationIdolIDs: [UUID] = []
        var event: Event?
        var date: Date?
        var note: String

        init(
            id: UUID = UUID(),
            videoRef: String? = nil,
            legacyIdols: [Idol] = [],
            migrationIdolIDs: [UUID] = [],
            event: Event? = nil,
            date: Date? = nil,
            note: String = ""
        ) {
            self.id = id
            self.videoRef = videoRef
            self.legacyIdols = legacyIdols
            self.migrationIdolIDs = migrationIdolIDs
            self.event = event
            self.date = date
            self.note = note
        }
    }
}

/// Relationship-repair schema. At this point the legacy relationship and
/// Shame/Douga Event edges are gone; the UUID carrier remains long enough for
/// `didMigrate` to rebuild the corrected relationship in the destination
/// context.
enum ChekinanaSchemaRelationshipRepair: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self]
    }

    @Model final class Idol {
        @Attribute(.unique) var id: UUID
        var sourceId: String?
        var name: String
        var group: String?
        var color: String?
        var birthday: String?
        var avatarImageRef: String?
        var isFavorite: Bool = false
        var sortOrder: Double?
        var note: String
        @Relationship(deleteRule: .nullify, inverse: \Cheki.idols) var chekis: [Cheki]
        @Relationship(deleteRule: .nullify, inverse: \Shame.idols) var shames: [Shame]
        @Relationship(deleteRule: .nullify, inverse: \Douga.idols) var dougas: [Douga]
        var createdAt: Date
        var updatedAt: Date
        var verification: String?
        var bio: String?
        var pattern: [Float]?
        var patterns: [[Float]] = []

        init(
            id: UUID = UUID(),
            name: String,
            note: String = "",
            chekis: [Cheki] = [],
            shames: [Shame] = [],
            dougas: [Douga] = [],
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.sourceId = nil
            self.name = name
            self.group = nil
            self.color = nil
            self.birthday = nil
            self.avatarImageRef = nil
            self.isFavorite = false
            self.sortOrder = nil
            self.note = note
            self.chekis = chekis
            self.shames = shames
            self.dougas = dougas
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.verification = nil
            self.bio = nil
            self.pattern = nil
            self.patterns = []
        }
    }

    @Model final class Event {
        @Attribute(.unique) var id: UUID
        var name: String
        var date: Date?
        var city: String?
        var livehouse: String?
        @Attribute(originalName: "venue") var legacyVenue: String?
        var avatarImageRef: String?
        var price: String?
        var weiboURL: URL?
        var ticketURL: URL?
        var note: String
        @Relationship(deleteRule: .nullify, inverse: \Cheki.event) var chekis: [Cheki]
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            note: String = "",
            chekis: [Cheki] = [],
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.date = nil
            self.city = nil
            self.livehouse = nil
            self.legacyVenue = nil
            self.avatarImageRef = nil
            self.price = nil
            self.weiboURL = nil
            self.ticketURL = nil
            self.note = note
            self.chekis = chekis
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model final class Cheki {
        @Attribute(.unique) var id: UUID
        var idols: [Idol]
        var event: Event?
        @Attribute(originalName: "eventDate") var date: Date?
        var idx: Int?
        var userAppears: Bool?
        var sizeRawValue: String?
        var imageRef: String?
        var isFavorite: Bool = false
        var hasPostedToSNS: Bool = false
        var note: String
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            idols: [Idol] = [],
            event: Event? = nil,
            note: String = "",
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.idols = idols
            self.event = event
            self.date = nil
            self.idx = nil
            self.userAppears = nil
            self.sizeRawValue = nil
            self.imageRef = nil
            self.isFavorite = false
            self.hasPostedToSNS = false
            self.note = note
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model final class Shame {
        @Attribute(.unique) var id: UUID
        var imageRef: String?
        @Relationship(deleteRule: .nullify) var idols: [Idol]
        var migrationIdolIDs: [UUID] = []
        var date: Date?
        var note: String

        init(
            id: UUID = UUID(),
            imageRef: String? = nil,
            idols: [Idol] = [],
            migrationIdolIDs: [UUID] = [],
            date: Date? = nil,
            note: String = ""
        ) {
            self.id = id
            self.imageRef = imageRef
            self.idols = idols
            self.migrationIdolIDs = migrationIdolIDs
            self.date = date
            self.note = note
        }
    }

    @Model final class Douga {
        @Attribute(.unique) var id: UUID
        var videoRef: String?
        @Relationship(deleteRule: .nullify) var idols: [Idol]
        var migrationIdolIDs: [UUID] = []
        var date: Date?
        var note: String

        init(
            id: UUID = UUID(),
            videoRef: String? = nil,
            idols: [Idol] = [],
            migrationIdolIDs: [UUID] = [],
            date: Date? = nil,
            note: String = ""
        ) {
            self.id = id
            self.videoRef = videoRef
            self.idols = idols
            self.migrationIdolIDs = migrationIdolIDs
            self.date = date
            self.note = note
        }
    }
}

enum ChekinanaSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self]
    }
}

enum ChekinanaMigrationIntegrityError: Error, Equatable {
    case duplicateIdolID
    case duplicateCarrierIdolID
    case missingCarrierIdol
}

enum ChekinanaSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            ChekinanaSchemaV1.self,
            ChekinanaSchemaBridge.self,
            ChekinanaSchemaRelationshipRepair.self,
            ChekinanaSchemaV4.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: ChekinanaSchemaV1.self,
                toVersion: ChekinanaSchemaBridge.self,
                willMigrate: nil,
                didMigrate: { context in
                    for record in try context.fetch(
                        FetchDescriptor<ChekinanaSchemaBridge.Shame>()
                    ) {
                        record.migrationIdolIDs = uniqueIDs(
                            record.legacyIdols.map(\.id)
                        )
                    }
                    for record in try context.fetch(
                        FetchDescriptor<ChekinanaSchemaBridge.Douga>()
                    ) {
                        record.migrationIdolIDs = uniqueIDs(
                            record.legacyIdols.map(\.id)
                        )
                    }
                    try context.save()
                }
            ),
            .custom(
                fromVersion: ChekinanaSchemaBridge.self,
                toVersion: ChekinanaSchemaRelationshipRepair.self,
                willMigrate: nil,
                didMigrate: { context in
                    let idols = try context.fetch(
                        FetchDescriptor<ChekinanaSchemaRelationshipRepair.Idol>()
                    )
                    let idolsByID = try strictIdolMap(idols)
                    for record in try context.fetch(
                        FetchDescriptor<ChekinanaSchemaRelationshipRepair.Shame>()
                    ) {
                        record.idols = try resolveCarrierIdols(
                            record.migrationIdolIDs,
                            idolsByID: idolsByID
                        )
                    }
                    for record in try context.fetch(
                        FetchDescriptor<ChekinanaSchemaRelationshipRepair.Douga>()
                    ) {
                        record.idols = try resolveCarrierIdols(
                            record.migrationIdolIDs,
                            idolsByID: idolsByID
                        )
                    }
                    try context.save()
                }
            ),
            .lightweight(
                fromVersion: ChekinanaSchemaRelationshipRepair.self,
                toVersion: ChekinanaSchemaV4.self
            ),
        ]
    }

    private static func uniqueIDs(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }

    static func strictIdolMap(
        _ idols: [ChekinanaSchemaRelationshipRepair.Idol]
    ) throws -> [UUID: ChekinanaSchemaRelationshipRepair.Idol] {
        var result: [UUID: ChekinanaSchemaRelationshipRepair.Idol] = [:]
        result.reserveCapacity(idols.count)
        for idol in idols {
            guard result.updateValue(idol, forKey: idol.id) == nil else {
                throw ChekinanaMigrationIntegrityError.duplicateIdolID
            }
        }
        return result
    }

    static func resolveCarrierIdols(
        _ ids: [UUID],
        idolsByID: [UUID: ChekinanaSchemaRelationshipRepair.Idol]
    ) throws -> [ChekinanaSchemaRelationshipRepair.Idol] {
        guard Set(ids).count == ids.count else {
            throw ChekinanaMigrationIntegrityError.duplicateCarrierIdolID
        }
        return try ids.map { id in
            guard let idol = idolsByID[id] else {
                throw ChekinanaMigrationIntegrityError.missingCarrierIdol
            }
            return idol
        }
    }
}

struct ChekinanaResolvedMediaRelationships {
    let idols: [Idol]
    let event: Event?
}

enum ChekinanaModelContextResolver {
    enum ResolutionError: LocalizedError {
        case missingCheki
        case missingShame
        case missingDouga
        case hiddenIdol

        var errorDescription: String? {
            switch self {
            case .missingCheki: "The Cheki is no longer available."
            case .missingShame: "The Shame photo is no longer available."
            case .missingDouga: "The Douga video is no longer available."
            case .hiddenIdol: "A hidden Idol cannot be selected or modified."
            }
        }
    }

    static func idols(
        idolIDs: Set<UUID>,
        in modelContext: ModelContext
    ) throws -> [Idol] {
        let fetchedIdols = try modelContext.fetch(FetchDescriptor<Idol>())
        let resolved = ChekinanaIdolOrdering.ordered(
            fetchedIdols.filter { idolIDs.contains($0.id) }
        )
        guard resolved.count == idolIDs.count,
              ChekinanaVisibilityPolicy.includesRecord(
                idolIDs: resolved.map(\.id),
                hiddenIDs: ChekinanaHiddenIdolPersistence.load()
              ) else {
            throw ResolutionError.hiddenIdol
        }
        return resolved
    }

    static func relationships(
        idolIDs: Set<UUID>,
        eventID: UUID?,
        in modelContext: ModelContext
    ) throws -> ChekinanaResolvedMediaRelationships {
        let selectedIdols = try idols(idolIDs: idolIDs, in: modelContext)
        let selectedEvent: Event?
        if let eventID {
            selectedEvent = try modelContext.fetch(FetchDescriptor<Event>())
                .first { $0.id == eventID }
        } else {
            selectedEvent = nil
        }
        return ChekinanaResolvedMediaRelationships(
            idols: selectedIdols,
            event: selectedEvent
        )
    }

    static func cheki(id: UUID, in modelContext: ModelContext) throws -> Cheki {
        guard let value = try modelContext.fetch(FetchDescriptor<Cheki>())
            .first(where: { $0.id == id }) else {
            throw ResolutionError.missingCheki
        }
        return value
    }

    static func shame(id: UUID, in modelContext: ModelContext) throws -> Shame {
        guard let value = try modelContext.fetch(FetchDescriptor<Shame>())
            .first(where: { $0.id == id }) else {
            throw ResolutionError.missingShame
        }
        return value
    }

    static func douga(id: UUID, in modelContext: ModelContext) throws -> Douga {
        guard let value = try modelContext.fetch(FetchDescriptor<Douga>())
            .first(where: { $0.id == id }) else {
            throw ResolutionError.missingDouga
        }
        return value
    }
}

enum ChekinanaDataStore {
    private static let currentMarkerSchemaVersion = 4

    private final class ProcessCache: @unchecked Sendable {
        let lock = NSLock()
        var container: ModelContainer?
    }

    private static let processCache = ProcessCache()

    struct OpenFailure: Error, Equatable {
        static let stableCode = "persistent_store_open_failed"

        let code: String

        init(code: String = Self.stableCode) {
            self.code = code
        }
    }

    struct StorePaths: Equatable {
        let rootDirectory: URL
        let legacyStoreURL: URL
        let activeMarkerURL: URL
        let candidateRootURL: URL

        init(rootDirectory: URL, legacyStoreName: String, namespace: String) {
            self.rootDirectory = rootDirectory
            self.legacyStoreURL = rootDirectory.appendingPathComponent(legacyStoreName)
            self.activeMarkerURL = rootDirectory
                .appendingPathComponent("Chekinana-\(namespace)-active-store")
            self.candidateRootURL = rootDirectory
                .appendingPathComponent("Chekinana-\(namespace)-stores", isDirectory: true)
        }
    }

    private struct ActiveMarker: Codable, Equatable {
        let schemaVersion: Int
        let directoryName: String
    }

    private enum MarkerState: Equatable {
        case current(directoryName: String)
        case legacy(directoryName: String)

        var directoryName: String {
            switch self {
            case .current(let directoryName), .legacy(let directoryName):
                directoryName
            }
        }
    }

    static func open() -> Result<ModelContainer, OpenFailure> {
        processCache.lock.lock()
        defer { processCache.lock.unlock() }
        if let container = processCache.container {
            return .success(container)
        }

        let schema = Schema(versionedSchema: ChekinanaSchemaV4.self)
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let paths: StorePaths
        let configurationName: String
#if DEBUG
        if ProcessInfo.processInfo.environment["CHEKINANA_UI_TEST_STORE"] == "1" {
            paths = StorePaths(
                rootDirectory: applicationSupport,
                legacyStoreName: "ChekinanaUITests.store",
                namespace: "ui-tests"
            )
            configurationName = "ChekinanaUITests"
        } else {
            paths = StorePaths(
                rootDirectory: applicationSupport,
                legacyStoreName: "default.store",
                namespace: "production"
            )
            configurationName = "Chekinana"
        }
#else
        paths = StorePaths(
            rootDirectory: applicationSupport,
            legacyStoreName: "default.store",
            namespace: "production"
        )
        configurationName = "Chekinana"
#endif

        let result = openPreservingStoreFamily(paths: paths) { candidateURL in
            try ModelContainer(
                for: schema,
                migrationPlan: ChekinanaSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(
                    configurationName,
                    schema: schema,
                    url: candidateURL,
                    cloudKitDatabase: .none
                )]
            )
        }
        if case .success(let container) = result {
            processCache.container = container
        }
        return result
    }

    static func openPreservingStoreFamily(
        paths: StorePaths,
        fileManager: FileManager = .default,
        copyStore: ((URL, URL, FileManager) throws -> Void)? = nil,
        makeContainer: (URL) throws -> ModelContainer
    ) -> Result<ModelContainer, OpenFailure> {
        var sourceURL: URL?
        var markerState: MarkerState?
        var candidateDirectory: URL?
        do {
            try fileManager.createDirectory(
                at: paths.rootDirectory,
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: paths.activeMarkerURL.path) {
                let markerData = try Data(contentsOf: paths.activeMarkerURL)
                guard let parsedMarker = parseMarker(markerData) else {
                    return .failure(OpenFailure())
                }
                markerState = parsedMarker
                let directoryName = parsedMarker.directoryName
                let activeURL = paths.candidateRootURL
                    .appendingPathComponent(directoryName, isDirectory: true)
                    .appendingPathComponent("current.store")
                guard fileManager.fileExists(atPath: activeURL.path) else {
                    return .failure(OpenFailure())
                }
                sourceURL = activeURL
            } else if fileManager.fileExists(atPath: paths.legacyStoreURL.path) {
                markerState = nil
                sourceURL = paths.legacyStoreURL
            } else {
                markerState = nil
                sourceURL = nil
            }

            try fileManager.createDirectory(
                at: paths.candidateRootURL,
                withIntermediateDirectories: true
            )

            if case .current = markerState, let sourceURL {
                // A versioned marker is published only after this exact V4
                // store has opened successfully. Reopen it in place on every
                // later cold launch; copying or rotating it would add startup
                // I/O and make the active store less stable.
                cleanupManagedCandidates(
                    in: paths.candidateRootURL,
                    preserving: [sourceURL.deletingLastPathComponent()],
                    diagnosticLimit: 1,
                    fileManager: fileManager
                )
                return .success(try makeContainer(sourceURL))
            }

            let sourceDirectory = sourceURL.flatMap {
                managedCandidateDirectory(containing: $0, under: paths.candidateRootURL)
            }
            cleanupManagedCandidates(
                in: paths.candidateRootURL,
                preserving: sourceDirectory.map { [$0] } ?? [],
                diagnosticLimit: 1,
                fileManager: fileManager
            )
            let candidateName = "store-\(UUID().uuidString)"
            let newCandidateDirectory = paths.candidateRootURL
                .appendingPathComponent(candidateName, isDirectory: true)
            candidateDirectory = newCandidateDirectory
            try fileManager.createDirectory(
                at: newCandidateDirectory,
                withIntermediateDirectories: false
            )
            let candidateURL = newCandidateDirectory.appendingPathComponent("current.store")
            if let sourceURL {
                if let copyStore {
                    try copyStore(sourceURL, candidateURL, fileManager)
                } else {
                    try copyStoreFamily(
                        from: sourceURL,
                        to: candidateURL,
                        fileManager: fileManager
                    )
                }
            }

            let container = try makeContainer(candidateURL)
            try markerData(directoryName: candidateName).write(
                to: paths.activeMarkerURL,
                options: .atomic
            )

            // Once the marker atomically points at the successfully opened
            // candidate, an older managed candidate is no longer authoritative.
            // The original legacy store and its sidecars are intentionally
            // never removed, so a pre-repair physical backup stays available.
            if let sourceURL,
               sourceURL.deletingLastPathComponent().deletingLastPathComponent()
                    .standardizedFileURL == paths.candidateRootURL.standardizedFileURL {
                try? fileManager.removeItem(at: sourceURL.deletingLastPathComponent())
            }
            cleanupManagedCandidates(
                in: paths.candidateRootURL,
                preserving: [newCandidateDirectory],
                diagnosticLimit: 0,
                fileManager: fileManager
            )
            return .success(container)
        } catch {
            // The authoritative source and active marker are never modified
            // before the candidate opens successfully. A failed candidate is
            // retained for deterministic diagnostics; Retry starts again from
            // the same authoritative source instead of an empty store. Keep
            // only this latest failed managed candidate for diagnostics; the
            // legacy source and current marker target are never cleanup
            // candidates.
            let authoritativeDirectory = sourceURL.flatMap {
                managedCandidateDirectory(containing: $0, under: paths.candidateRootURL)
            }
            let preserved = [authoritativeDirectory, candidateDirectory].compactMap { $0 }
            cleanupManagedCandidates(
                in: paths.candidateRootURL,
                preserving: preserved,
                diagnosticLimit: 0,
                fileManager: fileManager
            )
            return .failure(OpenFailure())
        }
    }

    static func currentActiveStoreURL(
        paths: StorePaths,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: paths.activeMarkerURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: paths.activeMarkerURL)
        guard case .current(let directoryName) = parseMarker(data) else {
            return nil
        }
        return paths.candidateRootURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("current.store")
    }

    private static func markerData(directoryName: String) throws -> Data {
        try JSONEncoder().encode(ActiveMarker(
            schemaVersion: currentMarkerSchemaVersion,
            directoryName: directoryName
        ))
    }

    private static func parseMarker(_ data: Data) -> MarkerState? {
        if let marker = try? JSONDecoder().decode(ActiveMarker.self, from: data) {
            guard marker.schemaVersion == currentMarkerSchemaVersion,
                  isValidCandidateDirectoryName(marker.directoryName) else {
                return nil
            }
            return .current(directoryName: marker.directoryName)
        }
        guard let directoryName = String(data: data, encoding: .utf8),
              isValidCandidateDirectoryName(directoryName) else {
            return nil
        }
        return .legacy(directoryName: directoryName)
    }

    private static func managedCandidateDirectory(
        containing storeURL: URL,
        under candidateRootURL: URL
    ) -> URL? {
        let directory = storeURL.deletingLastPathComponent().standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL
                == candidateRootURL.standardizedFileURL,
              isValidCandidateDirectoryName(directory.lastPathComponent) else {
            return nil
        }
        return directory
    }

    private static func cleanupManagedCandidates(
        in candidateRootURL: URL,
        preserving preservedDirectories: [URL],
        diagnosticLimit: Int,
        fileManager: FileManager
    ) {
        let root = candidateRootURL.standardizedFileURL
        let preserved = Set(preservedDirectories.map { $0.standardizedFileURL })
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let removable = children.compactMap { url -> (URL, Date)? in
            let standardized = url.standardizedFileURL
            guard !preserved.contains(standardized),
                  standardized.deletingLastPathComponent() == root,
                  isValidCandidateDirectoryName(standardized.lastPathComponent),
                  let values = try? standardized.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                  ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return (standardized, values.contentModificationDate ?? .distantPast)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.lastPathComponent > $1.0.lastPathComponent
        }

        for (directory, _) in removable.dropFirst(max(0, diagnosticLimit)) {
            // Removing the whole strictly-managed directory also removes its
            // SQLite main/WAL/SHM family. Unknown paths and symlinks are never
            // traversed or deleted.
            try? fileManager.removeItem(at: directory)
        }
    }

    private static func copyStoreFamily(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        // The SQLite main file plus WAL contain all committed data. SHM is a
        // transient lock/index file and is regenerated for the isolated copy.
        for suffix in ["", "-wal"] {
            let source = URL(fileURLWithPath: sourceURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: destinationURL.path + suffix)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private static func isValidCandidateDirectoryName(_ value: String) -> Bool {
        guard value.hasPrefix("store-") else { return false }
        return UUID(uuidString: String(value.dropFirst("store-".count))) != nil
    }

#if DEBUG
    static func resetForUITestingIfRequested(in container: ModelContainer) throws {
        guard ProcessInfo.processInfo.environment["CHEKINANA_UI_RESET_STORE"] == "1" else {
            return
        }

        let context = ModelContext(container)
        do {
            for douga in try context.fetch(FetchDescriptor<Douga>()) {
                context.delete(douga)
            }
            for shame in try context.fetch(FetchDescriptor<Shame>()) {
                context.delete(shame)
            }
            for cheki in try context.fetch(FetchDescriptor<Cheki>()) {
                context.delete(cheki)
            }
            try context.save()
            let eventImages = try context.fetch(FetchDescriptor<EventImage>())
            let events = try context.fetch(FetchDescriptor<Event>())
            ChekinanaEventMediaJournal.queueDeletion(
                eventImages.map(\.imageRef) + events.compactMap(\.avatarImageRef)
            )
            eventImages.forEach(context.delete)
            for event in events {
                context.delete(event)
            }
            for idol in try context.fetch(FetchDescriptor<Idol>()) {
                context.delete(idol)
            }
            try context.save()
            try? ChekinanaEventMediaJournal.recover(modelContext: context)
            try ChekinanaGalleryMediaStore.removeAllManagedMediaFiles()
        } catch {
            context.rollback()
            throw error
        }
    }
#endif
}

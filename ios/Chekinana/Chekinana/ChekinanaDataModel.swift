import Foundation
import CoreData
import SwiftData

enum ChekiSize: String, Codable, CaseIterable, Identifiable, Sendable {
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

enum ChekinanaChekiEventSelectionPolicy {
    static let allowedDayOffset = 1

    static func includes(recordDate: Date?, eventDate: Date?) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let recordDay = recordDate.flatMap(ChekinanaDateOnly.canonicalized),
              let eventDay = eventDate.flatMap(ChekinanaDateOnly.canonicalized),
              let lowerBound = calendar.date(
                  byAdding: .day,
                  value: -allowedDayOffset,
                  to: recordDay
              ),
              let upperBound = calendar.date(
                  byAdding: .day,
                  value: allowedDayOffset,
                  to: recordDay
              ) else {
            return false
        }
        return eventDay >= lowerBound && eventDay <= upperBound
    }

    static func eligibleEvents(
        _ events: [Event],
        schedules: [EventSchedule] = [],
        for recordDate: Date?
    ) -> [Event] {
        guard let recordDay = recordDate.flatMap(ChekinanaDateOnly.canonicalized) else {
            return []
        }
        let eligible = events.filter {
            includes(recordDate: recordDay, eventDate: $0.date)
        }
        let startByEventID = ChekinanaEventOrdering.scheduleStartTimes(schedules)
        return eligible.sorted { lhs, rhs in
            let leftDay = lhs.date.flatMap(ChekinanaDateOnly.canonicalized)
            let rightDay = rhs.date.flatMap(ChekinanaDateOnly.canonicalized)
            let leftPartition = candidatePartition(leftDay, recordDay: recordDay)
            let rightPartition = candidatePartition(rightDay, recordDay: recordDay)
            if leftPartition != rightPartition { return leftPartition < rightPartition }
            return ChekinanaEventOrdering.comesBefore(
                lhs,
                rhs,
                startByEventID: startByEventID,
                dateAscending: true
            )
        }
    }

    static func validatedEventID(
        _ eventID: UUID?,
        recordDate: Date?,
        events: [Event]
    ) -> UUID? {
        _ = recordDate
        guard let eventID,
              events.contains(where: { $0.id == eventID }) else {
            return nil
        }
        return eventID
    }

    private static func candidatePartition(_ eventDay: Date?, recordDay: Date) -> Int {
        guard let eventDay else { return 3 }
        if eventDay == recordDay { return 0 }
        return eventDay < recordDay ? 1 : 2
    }
}

enum ChekinanaEventOrdering {
    static func ordered(
        _ events: [Event],
        schedules: [EventSchedule],
        dateAscending: Bool
    ) -> [Event] {
        let startByEventID = scheduleStartTimes(schedules)
        return events.sorted {
            comesBefore(
                $0,
                $1,
                startByEventID: startByEventID,
                dateAscending: dateAscending
            )
        }
    }

    static func comesBefore(
        _ lhs: Event,
        _ rhs: Event,
        startByEventID: [UUID: String],
        dateAscending: Bool
    ) -> Bool {
        let leftDate = effectiveDate(
            for: lhs,
            startByEventID: startByEventID
        )
        let rightDate = effectiveDate(
            for: rhs,
            startByEventID: startByEventID
        )
        switch (leftDate, rightDate) {
        case let (left?, right?) where left != right:
            return dateAscending ? left < right : left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func effectiveDate(
        for event: Event,
        schedules: [EventSchedule],
        calendar: Calendar = .current
    ) -> Date? {
        return effectiveDate(
            for: event,
            startByEventID: scheduleStartTimes(schedules),
            calendar: calendar
        )
    }

    static func effectiveDate(
        for event: Event,
        startByEventID: [UUID: String],
        calendar: Calendar = .current
    ) -> Date? {
        guard let canonicalDate = event.date,
              let displayDate = ChekinanaDateOnly.displayDate(
                  from: canonicalDate,
                  calendar: calendar
              ) else {
            return nil
        }
        guard let startTime = startByEventID[event.id] else {
            return calendar.startOfDay(for: displayDate)
        }
        return ChekinanaEventTime.date(
            for: startTime,
            calendar: calendar,
            fallback: displayDate
        )
    }

    static func startTime(
        for eventID: UUID,
        schedules: [EventSchedule]
    ) -> String? {
        scheduleStartTimes(schedules)[eventID]
    }

    static func scheduleStartTimes(
        _ schedules: [EventSchedule]
    ) -> [UUID: String] {
        var startByEventID: [UUID: String] = [:]
        var openByEventID: [UUID: String] = [:]
        for schedule in schedules {
            if let start = ChekinanaEventTime.normalized(schedule.startTime) {
                if let existing = startByEventID[schedule.eventID] {
                    startByEventID[schedule.eventID] = min(existing, start)
                } else {
                    startByEventID[schedule.eventID] = start
                }
            }
            if let open = ChekinanaEventTime.normalized(schedule.openTime) {
                if let existing = openByEventID[schedule.eventID] {
                    openByEventID[schedule.eventID] = min(existing, open)
                } else {
                    openByEventID[schedule.eventID] = open
                }
            }
        }
        return openByEventID.merging(startByEventID) { _, start in start }
    }
}

enum ChekinanaTravelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case flight
    case train

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flight:
            ChekinanaProductCopy.text("travel.mode.flight", "Flight")
        case .train:
            ChekinanaProductCopy.text("travel.mode.train", "Train")
        }
    }

    var systemImage: String {
        switch self {
        case .flight: "airplane"
        case .train: "train.side.front.car"
        }
    }
}

enum ChekinanaTrainOperatorPreset: String, CaseIterable, Identifiable, Sendable {
    case chinaRailway
    case jrHokkaido
    case jrEast
    case jrCentral
    case jrWest
    case jrShikoku
    case jrKyushu
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chinaRailway: "中国铁路"
        case .jrHokkaido: "JR北海道"
        case .jrEast: "JR東日本"
        case .jrCentral: "JR東海"
        case .jrWest: "JR西日本"
        case .jrShikoku: "JR四国"
        case .jrKyushu: "JR九州"
        case .custom: ChekinanaProductCopy.text("travel.operator.custom", "Other")
        }
    }

    static func matching(_ value: String) -> ChekinanaTrainOperatorPreset {
        allCases.first { $0 != .custom && $0.title == value } ?? .custom
    }
}

@Model
final class TravelSegment {
    @Attribute(.unique) var id: UUID
    var modeRawValue: String
    var operatorName: String
    var operatorIconRef: String?
    var serviceNumber: String
    var departureCity: String
    var departureLocation: String
    var arrivalCity: String
    var arrivalLocation: String
    var departureTime: Date
    var arrivalTime: Date
    var seatNumber: String
    var carriageNumber: String?
    var note: String
    var createdAt: Date
    var updatedAt: Date

    var mode: ChekinanaTravelMode {
        get { ChekinanaTravelMode(rawValue: modeRawValue) ?? .flight }
        set {
            modeRawValue = newValue.rawValue
            if newValue == .flight { carriageNumber = nil }
        }
    }

    var displayedDepartureLocation: String {
        departureLocation.nonEmpty ?? departureCity
    }

    var displayedArrivalLocation: String {
        arrivalLocation.nonEmpty ?? arrivalCity
    }

    init(
        id: UUID = UUID(),
        mode: ChekinanaTravelMode,
        operatorName: String = "",
        operatorIconRef: String? = nil,
        serviceNumber: String,
        departureCity: String,
        departureLocation: String,
        arrivalCity: String,
        arrivalLocation: String,
        departureTime: Date,
        arrivalTime: Date,
        seatNumber: String = "",
        carriageNumber: String? = nil,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        modeRawValue = mode.rawValue
        self.operatorName = operatorName
        self.operatorIconRef = operatorIconRef
        self.serviceNumber = serviceNumber
        self.departureCity = departureCity
        self.departureLocation = departureLocation
        self.arrivalCity = arrivalCity
        self.arrivalLocation = arrivalLocation
        self.departureTime = departureTime
        self.arrivalTime = arrivalTime
        self.seatNumber = seatNumber
        self.carriageNumber = mode == .train ? carriageNumber : nil
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ChekinanaTravelSegmentFields: Equatable, Sendable {
    var mode: ChekinanaTravelMode
    var operatorName: String
    var serviceNumber: String
    var departureCity: String
    var departureLocation: String
    var arrivalCity: String
    var arrivalLocation: String
    var departureTime: Date
    var arrivalTime: Date
    var seatNumber: String
    var carriageNumber: String
    var note: String
}

enum ChekinanaTravelSegmentValidationError: LocalizedError, Equatable {
    case missingRequiredFields
    case arrivalBeforeDeparture

    var errorDescription: String? {
        switch self {
        case .missingRequiredFields:
            ChekinanaProductCopy.text(
                "travel.error.required",
                "Look up a schedule and select valid departure and arrival stops."
            )
        case .arrivalBeforeDeparture:
            ChekinanaProductCopy.text(
                "travel.error.arrival_before_departure",
                "Arrival must not be earlier than departure."
            )
        }
    }
}

enum ChekinanaTravelSegmentValidator {
    static func validate(_ fields: ChekinanaTravelSegmentFields) throws {
        let required = [
            fields.serviceNumber,
            fields.departureLocation,
            fields.arrivalLocation,
        ]
        guard required.allSatisfy({ $0.nonEmpty != nil }) else {
            throw ChekinanaTravelSegmentValidationError.missingRequiredFields
        }
        guard fields.arrivalTime >= fields.departureTime else {
            throw ChekinanaTravelSegmentValidationError.arrivalBeforeDeparture
        }
    }
}

@MainActor
enum ChekinanaTravelSegmentPersistence {
    enum PersistenceError: LocalizedError, Equatable {
        case changedOrMissing

        var errorDescription: String? {
            ChekinanaProductCopy.text(
                "travel.error.changed_reopen",
                "This trip changed or was deleted. Reopen it and try again."
            )
        }
    }

    @discardableResult
    static func save(
        _ segment: TravelSegment,
        inserting: Bool,
        expectedUpdatedAt: Date? = nil,
        fields: ChekinanaTravelSegmentFields,
        operatorIconRef: String?,
        previousIconRef: String?,
        in modelContext: ModelContext,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> TravelSegment {
        try ChekinanaTravelSegmentValidator.validate(fields)
        var deletionRefs: [String] = []
        return try ChekinanaPersistenceMutationCoordinator.withLock {
            do {
                let live: TravelSegment
                if inserting {
                    let existing = try modelContext.fetch(
                        FetchDescriptor<TravelSegment>()
                    )
                    guard !existing.contains(where: { $0.id == segment.id }) else {
                        throw PersistenceError.changedOrMissing
                    }
                    modelContext.insert(segment)
                    live = segment
                } else {
                    let matches = try modelContext.fetch(FetchDescriptor<TravelSegment>())
                        .filter { $0.id == segment.id }
                    guard matches.count == 1,
                          expectedUpdatedAt == nil
                            || matches[0].updatedAt == expectedUpdatedAt else {
                        throw PersistenceError.changedOrMissing
                    }
                    live = matches[0]
                }
                live.mode = fields.mode
                live.operatorName = fields.operatorName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                live.operatorIconRef = operatorIconRef
                live.serviceNumber = fields.serviceNumber.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                live.departureCity = fields.departureCity.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                live.departureLocation = fields.departureLocation.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                live.arrivalCity = fields.arrivalCity.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                live.arrivalLocation = fields.arrivalLocation.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                live.departureTime = fields.departureTime
                live.arrivalTime = fields.arrivalTime
                live.seatNumber = fields.seatNumber.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                live.carriageNumber = fields.mode == .train
                    ? fields.carriageNumber.nonEmpty : nil
                live.note = fields.note
                live.updatedAt = Date()
                if let previousIconRef,
                   previousIconRef != operatorIconRef,
                   ChekinanaEventAvatarStore.isManaged(previousIconRef) {
                    deletionRefs = [previousIconRef]
                    ChekinanaEventMediaJournal.queueDeletion(deletionRefs)
                }
                try saveContext(modelContext)
                ChekinanaEventMediaJournal.clearPending(
                    [operatorIconRef].compactMap { $0 }
                )
                return live
            } catch {
                modelContext.rollback()
                ChekinanaEventMediaJournal.cancelDeletion(deletionRefs)
                throw error
            }
        }
    }

    static func delete(
        _ segment: TravelSegment,
        from modelContext: ModelContext,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        var deletionRefs: [String] = []
        try ChekinanaPersistenceMutationCoordinator.withLock {
            do {
                let matches = try modelContext.fetch(FetchDescriptor<TravelSegment>())
                    .filter { $0.id == segment.id }
                guard matches.count == 1 else {
                    throw PersistenceError.changedOrMissing
                }
                let live = matches[0]
                deletionRefs = live.operatorIconRef.flatMap { reference in
                    ChekinanaEventAvatarStore.isManaged(reference) ? reference : nil
                }.map { [$0] } ?? []
                ChekinanaEventMediaJournal.queueDeletion(deletionRefs)
                modelContext.delete(live)
                try saveContext(modelContext)
            } catch {
                modelContext.rollback()
                ChekinanaEventMediaJournal.cancelDeletion(deletionRefs)
                throw error
            }
        }
        try? ChekinanaEventMediaJournal.recover(modelContext: modelContext)
    }
}

struct ChekinanaTimelineOrderingValue: Equatable, Sendable {
    let id: String
    let title: String
    let effectiveTime: Date
}

enum ChekinanaTimelineOrdering {
    static func ordered(
        _ values: [ChekinanaTimelineOrderingValue],
        ascending: Bool
    ) -> [ChekinanaTimelineOrderingValue] {
        values.sorted { lhs, rhs in
            if lhs.effectiveTime != rhs.effectiveTime {
                return ascending
                    ? lhs.effectiveTime < rhs.effectiveTime
                    : lhs.effectiveTime > rhs.effectiveTime
            }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}

enum ChekinanaEventDateState {
    static func parsedCandidateDate(
        _ rawValue: String,
        calendar: Calendar = .current
    ) -> Date? {
        guard let canonical = ChekinanaDateOnly.parse(rawValue) else { return nil }
        return ChekinanaDateOnly.displayDate(from: canonical, calendar: calendar)
    }

    static func persistedDate(
        hasDate: Bool,
        selection: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard hasDate else { return nil }
        return ChekinanaDateOnly.canonicalDate(from: selection, displayedIn: calendar)
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

    /// Current encoder prototypes. The legacy single-vector field is retained
    /// only so old stores can be opened and is never used for recognition.
    var recognitionPatterns: [[Float]] {
        patterns.filter(ChekinanaPatternClassifier.isValidEmbedding)
    }

    var hasRecognitionPatterns: Bool {
        !recognitionPatterns.isEmpty
    }

}

/// Versioned metadata that distinguishes catalogue prototypes from custom
/// reference-photo embeddings without changing the legacy Idol storage shape.
/// `cataloguePatternCount` identifies the leading catalogue vectors in the
/// corresponding Idol's `patterns` array; all remaining vectors are custom.
@Model
final class IdolPatternState {
    @Attribute(.unique) var idolID: UUID
    var encoderVersion: String
    var cataloguePatternIDs: [String]
    var cataloguePatternCount: Int

    init(
        idolID: UUID,
        encoderVersion: String,
        cataloguePatternIDs: [String] = [],
        cataloguePatternCount: Int = 0
    ) {
        self.idolID = idolID
        self.encoderVersion = encoderVersion
        self.cataloguePatternIDs = cataloguePatternIDs
        self.cataloguePatternCount = cataloguePatternCount
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

    static func orderedForList(
        _ idols: [Idol],
        chekiCountsByIdolID: [UUID: Int]
    ) -> [Idol] {
        idols.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            let leftCount = chekiCountsByIdolID[lhs.id] ?? 0
            let rightCount = chekiCountsByIdolID[rhs.id] ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            let leftOrder = lhs.sortOrder.flatMap { $0.isFinite ? $0 : nil }
            let rightOrder = rhs.sortOrder.flatMap { $0.isFinite ? $0 : nil }
            switch (leftOrder, rightOrder) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
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
              favoriteByID[sourceID] == favoriteByID[targetID] else {
            return orderedIDs
        }
        return ChekinanaReorderPreview.move(
            sourceID,
            onto: targetID,
            in: orderedIDs
        )
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

/// Shared, side-effect-free ordering preview used by long-press drag surfaces.
/// Persistence remains owned by the feature using the interaction.
enum ChekinanaReorderPreview {
    static func move<ID: Equatable>(
        _ sourceID: ID,
        onto targetID: ID,
        in orderedIDs: [ID]
    ) -> [ID] {
        guard sourceID != targetID,
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

enum ChekinanaEventTime {
    static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1...2).contains(parts[0].count),
              parts[1].count == 2,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy(\.isNumber)
              }),
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    static func date(
        for storedValue: String?,
        calendar: Calendar = .current,
        fallback: Date = Date()
    ) -> Date {
        guard let normalized = normalized(storedValue) else { return fallback }
        let components = normalized.split(separator: ":")
        guard let hour = Int(components[0]), let minute = Int(components[1]) else {
            return fallback
        }
        var dateComponents = calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day],
            from: fallback
        )
        dateComponents.hour = hour
        dateComponents.minute = minute
        dateComponents.second = 0
        return calendar.date(from: dateComponents) ?? fallback
    }

    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(
            format: "%02d:%02d",
            components.hour ?? 0,
            components.minute ?? 0
        )
    }

    static func summary(openTime: String?, startTime: String?) -> String? {
        let parts = [
            normalized(openTime).map { "OPEN \($0)" },
            normalized(startTime).map { "START \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }
}

struct ChekinanaEventTimeDraft: Equatable {
    var isEnabled: Bool
    var selection: Date

    init(
        storedValue: String?,
        calendar: Calendar = .current,
        fallback: Date = Date()
    ) {
        let normalized = ChekinanaEventTime.normalized(storedValue)
        isEnabled = normalized != nil
        selection = ChekinanaEventTime.date(
            for: normalized,
            calendar: calendar,
            fallback: fallback
        )
    }

    func persistedValue(calendar: Calendar = .current) -> String? {
        guard isEnabled else { return nil }
        return ChekinanaEventTime.string(from: selection, calendar: calendar)
    }

    mutating func replace(
        with storedValue: String?,
        calendar: Calendar = .current,
        fallback: Date = Date()
    ) {
        self = ChekinanaEventTimeDraft(
            storedValue: storedValue,
            calendar: calendar,
            fallback: fallback
        )
    }
}

/// V8 additive storage for Event schedule fields. Keeping these fields in a
/// separate scalar-keyed model preserves the frozen V4-V7 Event entity hashes,
/// so an existing store can be validated before its isolated migration copy is
/// opened. At most one row exists for each Event.
@Model
final class EventSchedule {
    @Attribute(.unique) var eventID: UUID
    var openTime: String?
    var startTime: String?

    init(eventID: UUID, openTime: String? = nil, startTime: String? = nil) {
        self.eventID = eventID
        self.openTime = ChekinanaEventTime.normalized(openTime)
        self.startTime = ChekinanaEventTime.normalized(startTime)
    }
}

struct ChekinanaEventScheduleValue: Equatable, Sendable {
    let openTime: String?
    let startTime: String?

    static let empty = ChekinanaEventScheduleValue(openTime: nil, startTime: nil)
}

enum ChekinanaEventMutationError: LocalizedError, Equatable {
    case changedOrMissingEvent

    var errorDescription: String? {
        ChekinanaProductCopy.text(
            "error.event_changed_reopen",
            "This Event changed or was deleted. Reopen it and try again."
        )
    }
}

enum ChekinanaEventSchedulePersistence {
    static func value(
        for eventID: UUID,
        in modelContext: ModelContext
    ) throws -> ChekinanaEventScheduleValue {
        var descriptor = FetchDescriptor<EventSchedule>(
            predicate: #Predicate { $0.eventID == eventID }
        )
        descriptor.fetchLimit = 1
        guard let schedule = try modelContext.fetch(descriptor).first else {
            return .empty
        }
        return ChekinanaEventScheduleValue(
            openTime: ChekinanaEventTime.normalized(schedule.openTime),
            startTime: ChekinanaEventTime.normalized(schedule.startTime)
        )
    }

    static func set(
        eventID: UUID,
        openTime: String?,
        startTime: String?,
        in modelContext: ModelContext,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try ChekinanaPersistenceMutationCoordinator.withLock {
            // Standalone schedule edits use a dedicated context so they never
            // commit or roll back unrelated pending work in the caller's
            // context. The fresh context is also the authoritative Event
            // existence check for a prior cross-context deletion.
            let mutationContext = ModelContext(modelContext.container)
            mutationContext.autosaveEnabled = false
            do {
                try applyLocked(
                    eventID: eventID,
                    openTime: openTime,
                    startTime: startTime,
                    in: mutationContext
                )
                try saveContext(mutationContext)
            } catch {
                mutationContext.rollback()
                throw error
            }
        }
    }

    /// Caller must hold `ChekinanaPersistenceMutationCoordinator` through the
    /// surrounding Event mutation and save. The live Event check deliberately
    /// happens in the same context and critical section as the schedule write.
    static func applyLocked(
        eventID: UUID,
        openTime: String?,
        startTime: String?,
        in modelContext: ModelContext
    ) throws {
        let eventMatches = try modelContext.fetch(FetchDescriptor<Event>())
            .filter { $0.id == eventID }
        guard eventMatches.count == 1 else {
            throw ChekinanaEventMutationError.changedOrMissingEvent
        }
        try applyRowsLocked(
            eventID: eventID,
            openTime: openTime,
            startTime: startTime,
            in: modelContext
        )
    }

    /// Returns the authoritative persisted revision using a fresh context.
    /// Callers hold the shared mutation lock until their own context saves, so
    /// a relationship delete cannot interleave after this validation.
    static func persistedEventUpdatedAtLocked(
        eventID: UUID,
        from modelContext: ModelContext
    ) throws -> Date {
        let verificationContext = ModelContext(modelContext.container)
        verificationContext.autosaveEnabled = false
        let matches = try verificationContext.fetch(FetchDescriptor<Event>())
            .filter { $0.id == eventID }
        guard matches.count == 1 else {
            throw ChekinanaEventMutationError.changedOrMissingEvent
        }
        return matches[0].updatedAt
    }

    static func applyRowsLocked(
        eventID: UUID,
        openTime: String?,
        startTime: String?,
        in modelContext: ModelContext
    ) throws {
        let normalizedOpen = ChekinanaEventTime.normalized(openTime)
        let normalizedStart = ChekinanaEventTime.normalized(startTime)
        let descriptor = FetchDescriptor<EventSchedule>(
            predicate: #Predicate { $0.eventID == eventID }
        )
        let matches = try modelContext.fetch(descriptor)
            .sorted { $0.persistentModelID.hashValue < $1.persistentModelID.hashValue }
        let existing = matches.first
        matches.dropFirst().forEach(modelContext.delete)
        guard normalizedOpen != nil || normalizedStart != nil else {
            if let existing { modelContext.delete(existing) }
            return
        }
        let schedule = existing ?? EventSchedule(eventID: eventID)
        if existing == nil { modelContext.insert(schedule) }
        schedule.openTime = normalizedOpen
        schedule.startTime = normalizedStart
    }

    /// Internal delete primitive for Event deletion/clear-all while the shared
    /// mutation gate is already held. It intentionally does not require the
    /// Event to survive the surrounding transaction.
    static func deleteLocked(eventID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<EventSchedule>(
            predicate: #Predicate { $0.eventID == eventID }
        )
        for schedule in try modelContext.fetch(descriptor) {
            modelContext.delete(schedule)
        }
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

enum ChekinanaMediaEventKind: String, Codable, CaseIterable, Sendable {
    case shame
    case douga
}

/// Scalar-keyed Event association for media entities whose frozen historical
/// SwiftData schemas cannot safely gain a new stored property in place.
@Model
final class MediaEventLink {
    @Attribute(.unique) var id: String
    var mediaID: UUID
    var kindRawValue: String
    var eventID: UUID

    var kind: ChekinanaMediaEventKind? {
        ChekinanaMediaEventKind(rawValue: kindRawValue)
    }

    init(mediaID: UUID, kind: ChekinanaMediaEventKind, eventID: UUID) {
        id = Self.key(mediaID: mediaID, kind: kind)
        self.mediaID = mediaID
        kindRawValue = kind.rawValue
        self.eventID = eventID
    }

    static func key(mediaID: UUID, kind: ChekinanaMediaEventKind) -> String {
        "\(kind.rawValue)-\(mediaID.uuidString.lowercased())"
    }
}

@MainActor
enum ChekinanaMediaEventLinkStore {
    static func eventID(
        mediaID: UUID,
        kind: ChekinanaMediaEventKind,
        links: some Sequence<MediaEventLink>
    ) -> UUID? {
        links.first {
            $0.id == MediaEventLink.key(mediaID: mediaID, kind: kind)
        }?.eventID
    }

    static func set(
        mediaID: UUID,
        kind: ChekinanaMediaEventKind,
        eventID: UUID?,
        in modelContext: ModelContext,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try ChekinanaPersistenceMutationCoordinator.withLock {
            do {
                try validateMedia(mediaID: mediaID, kind: kind, in: modelContext)
                if let eventID {
                    guard try modelContext.fetch(FetchDescriptor<Event>())
                        .contains(where: { $0.id == eventID }) else {
                        throw ChekinanaChekiRecordMutationError.missingRelationships
                    }
                }
                let key = MediaEventLink.key(mediaID: mediaID, kind: kind)
                let matches = try modelContext.fetch(
                    FetchDescriptor<MediaEventLink>()
                ).filter { $0.id == key }
                if let eventID {
                    let link = matches.first ?? MediaEventLink(
                        mediaID: mediaID,
                        kind: kind,
                        eventID: eventID
                    )
                    if matches.isEmpty { modelContext.insert(link) }
                    link.mediaID = mediaID
                    link.kindRawValue = kind.rawValue
                    link.eventID = eventID
                    matches.dropFirst().forEach(modelContext.delete)
                } else {
                    matches.forEach(modelContext.delete)
                }
                try saveContext(modelContext)
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    static func delete(
        mediaID: UUID,
        kind: ChekinanaMediaEventKind,
        in modelContext: ModelContext
    ) throws {
        let key = MediaEventLink.key(mediaID: mediaID, kind: kind)
        try modelContext.fetch(FetchDescriptor<MediaEventLink>())
            .filter { $0.id == key }
            .forEach(modelContext.delete)
    }

    static func delete(eventID: UUID, in modelContext: ModelContext) throws {
        try modelContext.fetch(FetchDescriptor<MediaEventLink>())
            .filter { $0.eventID == eventID }
            .forEach(modelContext.delete)
    }

    private static func validateMedia(
        mediaID: UUID,
        kind: ChekinanaMediaEventKind,
        in modelContext: ModelContext
    ) throws {
        switch kind {
        case .shame:
            guard try modelContext.fetch(FetchDescriptor<Shame>())
                .contains(where: { $0.id == mediaID }) else {
                throw ChekinanaModelContextResolver.ResolutionError.missingShame
            }
        case .douga:
            guard try modelContext.fetch(FetchDescriptor<Douga>())
                .contains(where: { $0.id == mediaID }) else {
                throw ChekinanaModelContextResolver.ResolutionError.missingDouga
            }
        }
    }
}

/// Scalar-keyed shot-type metadata for Shame and Douga. Keeping this entity
/// relationship-free lets V12 add the field without changing the frozen media
/// entity identity used by V4-V11 stores.
@Model
final class MediaShotType {
    @Attribute(.unique) var id: String
    var mediaID: UUID
    var kindRawValue: String
    var userAppears: Bool

    var kind: ChekinanaMediaEventKind? {
        ChekinanaMediaEventKind(rawValue: kindRawValue)
    }

    init(
        mediaID: UUID,
        kind: ChekinanaMediaEventKind,
        userAppears: Bool
    ) {
        id = Self.key(mediaID: mediaID, kind: kind)
        self.mediaID = mediaID
        kindRawValue = kind.rawValue
        self.userAppears = userAppears
    }

    static func key(mediaID: UUID, kind: ChekinanaMediaEventKind) -> String {
        "\(kind.rawValue)-\(mediaID.uuidString.lowercased())"
    }
}

@MainActor
enum ChekinanaMediaShotTypeStore {
    static func userAppears(
        mediaID: UUID,
        kind: ChekinanaMediaEventKind,
        values: some Sequence<MediaShotType>
    ) -> Bool {
        values.first {
            $0.id == MediaShotType.key(mediaID: mediaID, kind: kind)
        }?.userAppears ?? false
    }

    static func set(
        mediaID: UUID,
        kind: ChekinanaMediaEventKind,
        userAppears: Bool,
        in modelContext: ModelContext,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        try ChekinanaPersistenceMutationCoordinator.withLock {
            do {
                try validateMedia(mediaID: mediaID, kind: kind, in: modelContext)
                let key = MediaShotType.key(mediaID: mediaID, kind: kind)
                let matches = try modelContext.fetch(
                    FetchDescriptor<MediaShotType>()
                ).filter { $0.id == key }
                let value = matches.first ?? MediaShotType(
                    mediaID: mediaID,
                    kind: kind,
                    userAppears: userAppears
                )
                if matches.isEmpty { modelContext.insert(value) }
                value.mediaID = mediaID
                value.kindRawValue = kind.rawValue
                value.userAppears = userAppears
                matches.dropFirst().forEach(modelContext.delete)
                try saveContext(modelContext)
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    static func delete(
        mediaID: UUID,
        kind: ChekinanaMediaEventKind,
        in modelContext: ModelContext
    ) throws {
        let key = MediaShotType.key(mediaID: mediaID, kind: kind)
        try modelContext.fetch(FetchDescriptor<MediaShotType>())
            .filter { $0.id == key }
            .forEach(modelContext.delete)
    }

    private static func validateMedia(
        mediaID: UUID,
        kind: ChekinanaMediaEventKind,
        in modelContext: ModelContext
    ) throws {
        switch kind {
        case .shame:
            guard try modelContext.fetch(FetchDescriptor<Shame>())
                .contains(where: { $0.id == mediaID }) else {
                throw ChekinanaModelContextResolver.ResolutionError.missingShame
            }
        case .douga:
            guard try modelContext.fetch(FetchDescriptor<Douga>())
                .contains(where: { $0.id == mediaID }) else {
                throw ChekinanaModelContextResolver.ResolutionError.missingDouga
            }
        }
    }
}

/// User-defined ordering for one exact Idol-set row on one Calendar day.
/// The scalar identity deliberately stays independent from media objects, so
/// regrouping never mutates or deletes Cheki data.
@Model
final class CalendarGroupOrder {
    @Attribute(.unique) var id: String
    var dateKey: String
    var groupKey: String
    var sortOrder: Int

    init(dateKey: String, groupKey: String, sortOrder: Int) {
        id = Self.key(dateKey: dateKey, groupKey: groupKey)
        self.dateKey = dateKey
        self.groupKey = groupKey
        self.sortOrder = sortOrder
    }

    static func key(dateKey: String, groupKey: String) -> String {
        "\(dateKey)|\(groupKey)"
    }
}

enum ChekinanaCalendarGroupOrderPolicy {
    static func orderedGroupKeys(
        _ fallbackGroupKeys: [String],
        dateKey: String,
        orders: some Sequence<CalendarGroupOrder>
    ) -> [String] {
        var seen = Set<String>()
        let available = fallbackGroupKeys.filter { seen.insert($0).inserted }
        let availableSet = Set(available)
        var bestByGroupKey: [String: CalendarGroupOrder] = [:]
        for order in orders where order.dateKey == dateKey
            && availableSet.contains(order.groupKey) {
            if let current = bestByGroupKey[order.groupKey] {
                if order.sortOrder < current.sortOrder
                    || (order.sortOrder == current.sortOrder && order.id < current.id) {
                    bestByGroupKey[order.groupKey] = order
                }
            } else {
                bestByGroupKey[order.groupKey] = order
            }
        }
        let known = available.compactMap { key -> CalendarGroupOrder? in
            bestByGroupKey[key]
        }.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.groupKey < $1.groupKey
        }.map(\.groupKey)
        let knownSet = Set(known)
        return known + available.filter { !knownSet.contains($0) }
    }
}

@MainActor
enum ChekinanaCalendarGroupOrderStore {
    static func setOrder(
        _ orderedGroupKeys: [String],
        dateKey: String,
        in modelContext: ModelContext,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        var seen = Set<String>()
        let uniqueKeys = orderedGroupKeys.filter { seen.insert($0).inserted }
        let matches = try modelContext.fetch(FetchDescriptor<CalendarGroupOrder>())
            .filter { $0.dateKey == dateKey }
        let existingByGroupKey = Dictionary(
            matches.map { ($0.groupKey, $0) },
            uniquingKeysWith: { lhs, _ in lhs }
        )
        do {
            for (index, groupKey) in uniqueKeys.enumerated() {
                let order = existingByGroupKey[groupKey] ?? CalendarGroupOrder(
                    dateKey: dateKey,
                    groupKey: groupKey,
                    sortOrder: index
                )
                if existingByGroupKey[groupKey] == nil {
                    modelContext.insert(order)
                }
                order.dateKey = dateKey
                order.groupKey = groupKey
                order.sortOrder = index
            }
            try saveContext(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
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
    // Historical stores may contain nil. All current writes normalize it to
    // false so an omitted shot type is consistently treated as solo.
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
        userAppears: Bool? = false,
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
        self.userAppears = userAppears ?? false
        self.sizeRawValue = size?.rawValue
        self.imageRef = imageRef
        self.isFavorite = isFavorite
        self.hasPostedToSNS = hasPostedToSNS
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A Cheki business record without media. This deliberately does not share
/// the media Cheki's index, favorite, user-appearance, SNS or file metadata.
@Model
final class ChekiRecord {
    @Attribute(.unique) var id: UUID
    /// Technical relationship keys are used instead of SwiftData relationships
    /// because this deliberately unidirectional model has no inverse on the
    /// existing Idol/Event entities. Keeping the keys scalar makes persistence
    /// and V5 migration deterministic without changing those legacy entities.
    var idolIDs: [UUID]
    var eventID: UUID?
    @Transient private var detachedIdols: [Idol] = []
    @Transient private var detachedEvent: Event?
    var date: Date?
    var sizeRawValue: String?
    var note: String
    var count: Int = 1

    var idols: [Idol] {
        get {
            // One-off compatibility accessor only. Collection/filter/grouping
            // code must use `idolIDs` or a prebuilt relationship index so it
            // never issues one SwiftData query per record.
            guard let modelContext else { return detachedIdols }
            return idolIDs.compactMap { id in
                var descriptor = FetchDescriptor<Idol>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                return try? modelContext.fetch(descriptor).first
            }
        }
        set {
            detachedIdols = newValue
            var seen = Set<UUID>()
            idolIDs = newValue.map(\.id).filter { seen.insert($0).inserted }
        }
    }

    var event: Event? {
        get {
            // One-off compatibility accessor only; batch readers use eventID.
            guard let modelContext else { return detachedEvent }
            guard let eventID else { return nil }
            var descriptor = FetchDescriptor<Event>(
                predicate: #Predicate { $0.id == eventID }
            )
            descriptor.fetchLimit = 1
            return try? modelContext.fetch(descriptor).first
        }
        set {
            detachedEvent = newValue
            eventID = newValue?.id
        }
    }

    var size: ChekiSize? {
        get { sizeRawValue.flatMap(ChekiSize.init(rawValue:)) }
        set { sizeRawValue = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        idols: [Idol] = [],
        event: Event? = nil,
        date: Date? = nil,
        size: ChekiSize? = nil,
        note: String = "",
        count: Int = 1
    ) {
        self.id = id
        var seen = Set<UUID>()
        self.idolIDs = idols.map(\.id).filter { seen.insert($0).inserted }
        self.eventID = event?.id
        self.detachedIdols = idols
        self.detachedEvent = event
        self.date = date
        self.sizeRawValue = size?.rawValue
        self.note = note
        self.count = max(1, count)
    }
}

struct ChekinanaChekiRecordIdentity: Hashable, Sendable {
    let idolIDs: [UUID]
    let canonicalDate: Date?
    let eventID: UUID?
    let sizeRawValue: String?
    let note: String

    init(
        idolIDs: some Sequence<UUID>,
        date: Date?,
        eventID: UUID?,
        sizeRawValue: String?,
        note: String
    ) {
        self.idolIDs = Array(Set(idolIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        canonicalDate = date.flatMap(ChekinanaDateOnly.canonicalized)
        self.eventID = eventID
        self.sizeRawValue = sizeRawValue
        self.note = note
    }

    init(_ record: ChekiRecord) {
        self.init(
            idolIDs: record.idolIDs,
            date: record.date,
            eventID: record.eventID,
            sizeRawValue: record.sizeRawValue,
            note: record.note
        )
    }
}

struct ChekinanaChekiRecordSnapshot: Hashable, Sendable {
    let id: UUID
    let identity: ChekinanaChekiRecordIdentity
    let count: Int

    init(_ record: ChekiRecord) {
        id = record.id
        identity = ChekinanaChekiRecordIdentity(record)
        count = max(1, record.count)
    }
}

enum ChekinanaChekiRecordMutationError: LocalizedError, Equatable {
    case changedRecord
    case missingRelationships
    case quantityOverflow

    var errorDescription: String? {
        switch self {
        case .changedRecord:
            ChekinanaProductCopy.text(
                "idols.no_media_group.changed",
                "This Cheki record changed. Reopen it and try again."
            )
        case .missingRelationships:
            ChekinanaProductCopy.text(
                "error.record_context_mismatch",
                "The selected relationships are no longer available in this library."
            )
        case .quantityOverflow:
            ChekinanaProductCopy.text(
                "error.record_quantity",
                "Quantity is outside the supported range."
            )
        }
    }
}

private final class ChekinanaPersistenceMutationGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private let chekinanaPersistenceMutationGate =
    ChekinanaPersistenceMutationGate()

/// Serializes scalar relationship validation with all related creates,
/// updates, deletes, and saves across ModelContexts. ChekiRecord keeps its
/// existing forwarding API for source compatibility, while Event schedule
/// persistence uses the coordinator directly.
enum ChekinanaPersistenceMutationCoordinator {
    nonisolated static func withLock<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        try chekinanaPersistenceMutationGate.withLock(operation)
    }
}

@MainActor
enum ChekinanaChekiRecordStore {
    typealias SaveContext = (ModelContext) throws -> Void

    nonisolated static func withMutationLock<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        try ChekinanaPersistenceMutationCoordinator.withLock(operation)
    }

    nonisolated static func totalCount(
        _ records: some Sequence<ChekiRecord>
    ) -> Int {
        records.reduce(0) { partialResult, record in
            let (sum, overflow) = partialResult.addingReportingOverflow(
                max(1, record.count)
            )
            return overflow ? Int.max : sum
        }
    }

    @discardableResult
    static func upsert(
        idols: [Idol],
        event: Event?,
        date: Date?,
        size: ChekiSize?,
        note: String,
        adding quantity: Int,
        in modelContext: ModelContext,
        saveContext: SaveContext = { try $0.save() }
    ) throws -> ChekiRecord {
        precondition(quantity > 0)
        let requestedIdolIDs = idols.map(\.id)
        let requestedEventID = event?.id
        return try withMutationLock {
            do {
                let relationships = try validatedRelationshipIDs(
                    idolIDs: requestedIdolIDs,
                    eventID: requestedEventID,
                    recordDate: date,
                    in: modelContext
                )
                let identity = ChekinanaChekiRecordIdentity(
                    idolIDs: relationships.idolIDs,
                    date: date,
                    eventID: relationships.eventID,
                    sizeRawValue: size?.rawValue,
                    note: note
                )
                let matches = try modelContext.fetch(FetchDescriptor<ChekiRecord>())
                    .filter { ChekinanaChekiRecordIdentity($0) == identity }
                    .sorted { $0.id.uuidString < $1.id.uuidString }
                if let retained = matches.first {
                    retained.date = identity.canonicalDate
                    var mergedCount = quantity
                    for match in matches {
                        mergedCount = try checkedCountSum(
                            mergedCount,
                            max(1, match.count)
                        )
                    }
                    retained.count = mergedCount
                    matches.dropFirst().forEach(modelContext.delete)
                    try saveContext(modelContext)
                    return retained
                }
                let record = ChekiRecord(
                    date: identity.canonicalDate,
                    size: size,
                    note: note,
                    count: quantity
                )
                record.idolIDs = relationships.idolIDs
                record.eventID = relationships.eventID
                modelContext.insert(record)
                try saveContext(modelContext)
                return record
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    @discardableResult
    static func update(
        _ record: ChekiRecord,
        idols: [Idol],
        event: Event?,
        date: Date?,
        size: ChekiSize?,
        note: String,
        count: Int,
        expected: ChekinanaChekiRecordSnapshot? = nil,
        in modelContext: ModelContext,
        saveContext: SaveContext = { try $0.save() }
    ) throws -> ChekiRecord? {
        let requestedIdolIDs = idols.map(\.id)
        let requestedEventID = event?.id
        return try withMutationLock { () -> ChekiRecord? in
            do {
                if expected != nil {
                    modelContext.rollback()
                }
                guard let live = try modelContext.fetch(FetchDescriptor<ChekiRecord>())
                    .first(where: { $0.id == record.id }),
                      expected == nil || ChekinanaChekiRecordSnapshot(live) == expected else {
                    throw ChekinanaChekiRecordMutationError.changedRecord
                }
                guard count > 0 else {
                    modelContext.delete(live)
                    try saveContext(modelContext)
                    return nil
                }
                let relationships = try validatedRelationshipIDs(
                    idolIDs: requestedIdolIDs,
                    eventID: requestedEventID,
                    recordDate: date,
                    in: modelContext
                )
                live.idolIDs = relationships.idolIDs
                live.eventID = relationships.eventID
                live.date = date.flatMap(ChekinanaDateOnly.canonicalized)
                live.size = size
                live.note = note
                live.count = count
                let identity = ChekinanaChekiRecordIdentity(live)
                live.date = identity.canonicalDate
                let collisions = try modelContext.fetch(FetchDescriptor<ChekiRecord>())
                    .filter {
                        $0.id != live.id
                            && ChekinanaChekiRecordIdentity($0) == identity
                    }
                for collision in collisions {
                    live.count = try checkedCountSum(
                        live.count,
                        max(1, collision.count)
                    )
                    modelContext.delete(collision)
                }
                try saveContext(modelContext)
                return live
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    static func delete(
        _ record: ChekiRecord,
        expected: ChekinanaChekiRecordSnapshot? = nil,
        in modelContext: ModelContext,
        saveContext: SaveContext = { try $0.save() }
    ) throws {
        try withMutationLock {
            do {
                if expected != nil {
                    modelContext.rollback()
                }
                guard let live = try modelContext.fetch(FetchDescriptor<ChekiRecord>())
                    .first(where: { $0.id == record.id }),
                      expected == nil || ChekinanaChekiRecordSnapshot(live) == expected else {
                    throw ChekinanaChekiRecordMutationError.changedRecord
                }
                modelContext.delete(live)
                try saveContext(modelContext)
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    nonisolated static func mergeDuplicates(
        in modelContext: ModelContext
    ) throws {
        try withMutationLock {
            do {
                let records = try modelContext.fetch(FetchDescriptor<ChekiRecord>())
                    .sorted { $0.id.uuidString < $1.id.uuidString }
                var retainedByIdentity: [ChekinanaChekiRecordIdentity: ChekiRecord] = [:]
                for record in records {
                    record.count = max(1, record.count)
                    let identity = ChekinanaChekiRecordIdentity(record)
                    record.date = identity.canonicalDate
                    if let retained = retainedByIdentity[identity] {
                        retained.count = try checkedCountSum(
                            retained.count,
                            record.count
                        )
                        modelContext.delete(record)
                    } else {
                        retainedByIdentity[identity] = record
                    }
                }
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    private static func validatedRelationshipIDs(
        idolIDs: [UUID],
        eventID: UUID?,
        recordDate: Date?,
        in modelContext: ModelContext
    ) throws -> (idolIDs: [UUID], eventID: UUID?) {
        _ = recordDate
        var seen = Set<UUID>()
        let uniqueIdolIDs = idolIDs.filter { seen.insert($0).inserted }
        let existingIdolIDs = Set(
            try modelContext.fetch(FetchDescriptor<Idol>()).map(\.id)
        )
        guard uniqueIdolIDs.allSatisfy(existingIdolIDs.contains) else {
            throw ChekinanaChekiRecordMutationError.missingRelationships
        }
        if let eventID {
            let eventMatches = try modelContext.fetch(FetchDescriptor<Event>())
                .filter { $0.id == eventID }
            guard eventMatches.count == 1 else {
                throw ChekinanaChekiRecordMutationError.missingRelationships
            }
        }
        return (uniqueIdolIDs, eventID)
    }

    nonisolated static func checkedCountSum(
        _ lhs: Int,
        _ rhs: Int
    ) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum >= 0 else {
            throw ChekinanaChekiRecordMutationError.quantityOverflow
        }
        return sum
    }
}

/// Builds the entity lookup maps once for UI or command output that must turn
/// persisted ChekiRecord relationship IDs back into display objects.
struct ChekinanaChekiRecordRelationshipIndex {
    private let idolsByID: [UUID: Idol]
    private let eventsByID: [UUID: Event]

    init(idols: [Idol], events: [Event] = []) {
        idolsByID = Dictionary(uniqueKeysWithValues: idols.map { ($0.id, $0) })
        eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    }

    func idols(for record: ChekiRecord) -> [Idol] {
        record.idolIDs.compactMap { idolsByID[$0] }
    }

    func event(for record: ChekiRecord) -> Event? {
        record.eventID.flatMap { eventsByID[$0] }
    }

    func idolName(id: UUID) -> String? {
        idolsByID[id]?.name
    }

    func event(id: UUID) -> Event? {
        eventsByID[id]
    }
}

/// Query-free predicates used by every collection hot path. These deliberately
/// inspect only the persisted scalar keys and never resolve SwiftData objects.
enum ChekinanaChekiRecordReadPolicy {
    static func isVisible(_ record: ChekiRecord, hiddenIDs: Set<UUID>) -> Bool {
        ChekinanaVisibilityPolicy.includesRecord(
            idolIDs: record.idolIDs,
            hiddenIDs: hiddenIDs
        )
    }

    static func containsIdol(_ record: ChekiRecord, idolID: UUID) -> Bool {
        record.idolIDs.contains(idolID)
    }

    static func singleIdolID(_ record: ChekiRecord) -> UUID? {
        record.idolIDs.count == 1 ? record.idolIDs.first : nil
    }

    static func isUndatedAndUnassigned(_ record: ChekiRecord) -> Bool {
        record.idolIDs.isEmpty && record.date == nil
    }

    static func isLinked(_ record: ChekiRecord, eventID: UUID) -> Bool {
        record.eventID == eventID
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
        [
            Idol.self,
            Event.self,
            EventImage.self,
            Cheki.self,
            Shame.self,
            Douga.self,
        ]
    }
}

enum ChekinanaSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventImage.self,
            Cheki.self,
            Shame.self,
            Douga.self,
        ]
    }
}

enum ChekinanaSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventImage.self,
            Cheki.self,
            ChekinanaSchemaV6.ChekiRecord.self,
            Shame.self,
            Douga.self,
        ]
    }

    /// Frozen production V6 representation. V7 owns the additive `count`
    /// field and duplicate-identity merge.
    @Model final class ChekiRecord {
        @Attribute(.unique) var id: UUID
        var idolIDs: [UUID]
        var eventID: UUID?
        var date: Date?
        var sizeRawValue: String?
        var note: String

        init(
            id: UUID = UUID(),
            idolIDs: [UUID] = [],
            eventID: UUID? = nil,
            date: Date? = nil,
            sizeRawValue: String? = nil,
            note: String = ""
        ) {
            self.id = id
            self.idolIDs = idolIDs
            self.eventID = eventID
            self.date = date
            self.sizeRawValue = sizeRawValue
            self.note = note
        }
    }
}

enum ChekinanaSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventImage.self,
            Cheki.self,
            ChekiRecord.self,
            Shame.self,
            Douga.self,
        ]
    }
}

enum ChekinanaSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventSchedule.self,
            EventImage.self,
            Cheki.self,
            ChekiRecord.self,
            Shame.self,
            Douga.self,
        ]
    }
}

enum ChekinanaSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventSchedule.self,
            EventImage.self,
            MediaEventLink.self,
            Cheki.self,
            ChekiRecord.self,
            Shame.self,
            Douga.self,
        ]
    }
}

enum ChekinanaSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventSchedule.self,
            EventImage.self,
            MediaEventLink.self,
            CalendarGroupOrder.self,
            Cheki.self,
            ChekiRecord.self,
            Shame.self,
            Douga.self,
        ]
    }
}

enum ChekinanaSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventSchedule.self,
            EventImage.self,
            MediaEventLink.self,
            CalendarGroupOrder.self,
            TravelSegment.self,
            Cheki.self,
            ChekiRecord.self,
            Shame.self,
            Douga.self,
        ]
    }
}

enum ChekinanaSchemaV12: VersionedSchema {
    static let versionIdentifier = Schema.Version(12, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventSchedule.self,
            EventImage.self,
            MediaEventLink.self,
            MediaShotType.self,
            CalendarGroupOrder.self,
            TravelSegment.self,
            Cheki.self,
            ChekiRecord.self,
            Shame.self,
            Douga.self,
        ]
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
            ChekinanaSchemaV5.self,
            ChekinanaSchemaV6.self,
            ChekinanaSchemaV7.self,
            ChekinanaSchemaV8.self,
            ChekinanaSchemaV9.self,
            ChekinanaSchemaV10.self,
            ChekinanaSchemaV11.self,
            ChekinanaSchemaV12.self,
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
            .lightweight(
                fromVersion: ChekinanaSchemaV4.self,
                toVersion: ChekinanaSchemaV5.self
            ),
            .custom(
                fromVersion: ChekinanaSchemaV5.self,
                toVersion: ChekinanaSchemaV6.self,
                willMigrate: nil,
                didMigrate: { context in
                    try context.transaction {
                        let legacyRecords = try context.fetch(
                            FetchDescriptor<Cheki>()
                        ).filter { $0.imageRef?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty != false }
                        for legacy in legacyRecords {
                            let record = ChekinanaSchemaV6.ChekiRecord(
                                id: legacy.id,
                                idolIDs: legacy.idols.map(\.id),
                                eventID: legacy.event?.id,
                                date: legacy.date,
                                sizeRawValue: legacy.sizeRawValue,
                                note: legacy.note
                            )
                            context.insert(record)
                            context.delete(legacy)
                        }
                        try context.save()
                    }
                }
            ),
            .custom(
                fromVersion: ChekinanaSchemaV6.self,
                toVersion: ChekinanaSchemaV7.self,
                willMigrate: nil,
                didMigrate: { context in
                    try context.transaction {
                        for cheki in try context.fetch(FetchDescriptor<Cheki>())
                        where cheki.userAppears == nil {
                            cheki.userAppears = false
                        }
                        try ChekinanaChekiRecordStore.mergeDuplicates(in: context)
                        try context.save()
                    }
                }
            ),
            .lightweight(
                fromVersion: ChekinanaSchemaV7.self,
                toVersion: ChekinanaSchemaV8.self
            ),
            .lightweight(
                fromVersion: ChekinanaSchemaV8.self,
                toVersion: ChekinanaSchemaV9.self
            ),
            .lightweight(
                fromVersion: ChekinanaSchemaV9.self,
                toVersion: ChekinanaSchemaV10.self
            ),
            .lightweight(
                fromVersion: ChekinanaSchemaV10.self,
                toVersion: ChekinanaSchemaV11.self
            ),
            .lightweight(
                fromVersion: ChekinanaSchemaV11.self,
                toVersion: ChekinanaSchemaV12.self
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
        case missingChekiRecord
        case missingShame
        case missingDouga
        case hiddenIdol

        var errorDescription: String? {
            switch self {
            case .missingCheki: "The Cheki is no longer available."
            case .missingChekiRecord: "The record is no longer available."
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

    static func chekiRecord(
        id: UUID,
        in modelContext: ModelContext
    ) throws -> ChekiRecord {
        var descriptor = FetchDescriptor<ChekiRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let value = try modelContext.fetch(descriptor).first else {
            throw ResolutionError.missingChekiRecord
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
    private static let currentMarkerSchemaVersion = 12
    private static let migratableMarkerSchemaVersions: Set<Int> = [4, 5, 6, 7, 8, 9, 10, 11]
    /// Frozen Core Data checksum for the production V7 schema. The V7 store
    /// copied from the affected iOS 17 device and a store generated from
    /// `ChekinanaSchemaV7` have this exact checksum.
    static let schemaV7StoreChecksum =
        "+mCqY1NsM6YYHUtYg6UeB9mGUNw241qgi2fzPCYcidg="

    enum PhysicalStoreVersion: Int, Equatable {
        case v1 = 1
        case bridge = 2
        case relationshipRepair = 3
        case v4 = 4
        case v5 = 5
        case v6 = 6
        case v7 = 7
        case v8 = 8
        case v9 = 9
        case v10 = 10
        case v11 = 11
        case v12 = 12
    }

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

        let schema = Schema(versionedSchema: ChekinanaSchemaV12.self)
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

        let automaticContainer: (URL) throws -> ModelContainer = { candidateURL in
            try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(
                    configurationName,
                    schema: schema,
                    url: candidateURL,
                    cloudKitDatabase: .none
                )]
            )
        }
        let result = openPreservingStoreFamily(
            paths: paths,
            inspectStoreVersion: physicalStoreVersion,
            makeAutomaticContainer: automaticContainer
        ) { candidateURL in
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
        inspectStoreVersion: ((URL) throws -> PhysicalStoreVersion?)? = nil,
        makeAutomaticContainer: ((URL) throws -> ModelContainer)? = nil,
        makeContainer: (URL) throws -> ModelContainer
    ) -> Result<ModelContainer, OpenFailure> {
        var sourceURL: URL?
        var markerState: MarkerState?
        var physicalStoreVersion: PhysicalStoreVersion?
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

            if let sourceURL, let inspectStoreVersion {
                guard let detectedVersion = try inspectStoreVersion(sourceURL) else {
                    // Never hand an unknown physical model to SwiftData staged
                    // migration. On older iOS releases that becomes an opaque
                    // 134504 failure and repeated diagnostic candidates.
                    return .failure(OpenFailure())
                }
                physicalStoreVersion = detectedVersion
            }

            try fileManager.createDirectory(
                at: paths.candidateRootURL,
                withIntermediateDirectories: true
            )

            if case .current = markerState,
               let sourceURL,
               physicalStoreVersion == nil || physicalStoreVersion == .v12 {
                // A versioned marker is published only after this exact V12
                // store has opened successfully. Reopen it in place on every
                // later cold launch; copying or rotating it would add startup
                // I/O and make the active store less stable.
                cleanupManagedCandidates(
                    in: paths.candidateRootURL,
                    preserving: [sourceURL.deletingLastPathComponent()],
                    diagnosticLimit: 1,
                    fileManager: fileManager
                )
                if let makeAutomaticContainer {
                    return .success(try makeAutomaticContainer(sourceURL))
                }
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

            let container: ModelContainer
            if physicalStoreVersion == .v7 || physicalStoreVersion == .v8,
               let makeAutomaticContainer {
                // iOS 17.3.1 cannot recognize this otherwise valid V7 store
                // when it is opened with the full staged plan (134504). The
                // V8 through V12 changes only add scalar-keyed entities/fields, so the
                // automatic lightweight path is sufficient and compatible.
                container = try makeAutomaticContainer(candidateURL)
            } else {
                // V1-V6 retain their custom/staged repair and data migration
                // chain. A newly created store also uses this closure.
                container = try makeContainer(candidateURL)
            }
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
            guard isValidCandidateDirectoryName(marker.directoryName) else {
                return nil
            }
            if marker.schemaVersion == currentMarkerSchemaVersion {
                return .current(directoryName: marker.directoryName)
            }
            if migratableMarkerSchemaVersions.contains(marker.schemaVersion) {
                // A supported older active store remains authoritative while
                // an isolated copy is opened through the full migration plan.
                // Only a successful open publishes the current schema marker.
                return .legacy(directoryName: marker.directoryName)
            }
            return nil
        }
        guard let directoryName = String(data: data, encoding: .utf8),
              isValidCandidateDirectoryName(directoryName) else {
            return nil
        }
        return .legacy(directoryName: directoryName)
    }

    static func physicalStoreVersion(at storeURL: URL) throws -> PhysicalStoreVersion? {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: storeURL
        )
        let rawIdentifiers = metadata[NSStoreModelVersionIdentifiersKey]
        let identifiers: [String]
        if let values = rawIdentifiers as? Set<String> {
            identifiers = Array(values)
        } else if let values = rawIdentifiers as? [String] {
            identifiers = values
        } else if let values = rawIdentifiers as? NSSet {
            identifiers = values.compactMap { $0 as? String }
        } else {
            return nil
        }
        guard identifiers.count == 1,
              let majorText = identifiers[0].split(separator: ".").first,
              let major = Int(majorText),
              let version = PhysicalStoreVersion(rawValue: major) else {
            return nil
        }
        if version == .v7 {
            guard metadata["NSStoreModelVersionChecksumKey"] as? String
                    == schemaV7StoreChecksum else {
                return nil
            }
        }
        return version
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
            try ChekinanaChekiRecordStore.withMutationLock {
                for order in try context.fetch(FetchDescriptor<CalendarGroupOrder>()) {
                    context.delete(order)
                }
                for link in try context.fetch(FetchDescriptor<MediaEventLink>()) {
                    context.delete(link)
                }
                for shotType in try context.fetch(FetchDescriptor<MediaShotType>()) {
                    context.delete(shotType)
                }
                for douga in try context.fetch(FetchDescriptor<Douga>()) {
                    context.delete(douga)
                }
                for shame in try context.fetch(FetchDescriptor<Shame>()) {
                    context.delete(shame)
                }
                for cheki in try context.fetch(FetchDescriptor<Cheki>()) {
                    context.delete(cheki)
                }
                for record in try context.fetch(FetchDescriptor<ChekiRecord>()) {
                    context.delete(record)
                }
                try context.save()
                let eventImages = try context.fetch(FetchDescriptor<EventImage>())
                let eventSchedules = try context.fetch(FetchDescriptor<EventSchedule>())
                let events = try context.fetch(FetchDescriptor<Event>())
                let travelSegments = try context.fetch(
                    FetchDescriptor<TravelSegment>()
                )
                ChekinanaEventMediaJournal.queueDeletion(
                    eventImages.map(\.imageRef)
                        + events.compactMap(\.avatarImageRef)
                        + travelSegments.compactMap(\.operatorIconRef)
                )
                eventImages.forEach(context.delete)
                eventSchedules.forEach(context.delete)
                for event in events {
                    context.delete(event)
                }
                travelSegments.forEach(context.delete)
                for idol in try context.fetch(FetchDescriptor<Idol>()) {
                    context.delete(idol)
                }
                try context.save()
            }
            try? ChekinanaEventMediaJournal.recover(modelContext: context)
            try ChekinanaGalleryMediaStore.removeAllManagedMediaFiles()
        } catch {
            context.rollback()
            throw error
        }
    }
#endif
}

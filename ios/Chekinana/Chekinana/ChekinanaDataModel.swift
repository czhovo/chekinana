import Foundation
import CoreData
import SwiftData
import SQLite3
import CryptoKit

struct ChekiSize: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    static let mini = ChekiSize(uncheckedRawValue: "mini")
    static let wide = ChekiSize(uncheckedRawValue: "wide")
    static let builtInCases: [ChekiSize] = [.mini, .wide]

    let rawValue: String

    var id: String { rawValue }

    init?(rawValue: String) {
        if rawValue == Self.mini.rawValue || rawValue == Self.wide.rawValue {
            self.rawValue = rawValue
            return
        }
        guard Self.parseCustomRawValue(rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let size = ChekiSize(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Cheki size: \(value)"
            )
        }
        self = size
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func custom(
        id: UUID,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> ChekiSize {
        precondition(
            ChekinanaCustomChekiSizePolicy.isValidPixelDimensions(
                width: pixelWidth,
                height: pixelHeight
            )
        )
        return ChekiSize(uncheckedRawValue:
            "custom:\(id.uuidString.lowercased()):\(pixelWidth)x\(pixelHeight)"
        )
    }

    var customID: UUID? { Self.parseCustomRawValue(rawValue)?.id }

    var customPixelDimensions: (width: Int, height: Int)? {
        guard let parsed = Self.parseCustomRawValue(rawValue) else { return nil }
        return (parsed.width, parsed.height)
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    private static func parseCustomRawValue(
        _ value: String
    ) -> (id: UUID, width: Int, height: Int)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "custom",
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        let dimensions = parts[2].split(separator: "x", omittingEmptySubsequences: false)
        guard dimensions.count == 2,
              let width = Int(dimensions[0]), width > 0,
              let height = Int(dimensions[1]), height > 0,
              ChekinanaCustomChekiSizePolicy.isValidPixelDimensions(
                width: width,
                height: height
              ) else { return nil }
        return (id, width, height)
    }
}

enum ChekinanaCustomChekiSizePolicy {
    static let shortEdge = 1_200
    static let maximumLongEdge = 8_192
    static let maximumPixelCount = shortEdge * maximumLongEdge

    static func isValidPixelDimensions(width: Int, height: Int) -> Bool {
        guard min(width, height) == shortEdge,
              max(width, height) <= maximumLongEdge else { return false }
        let pixelCount = width.multipliedReportingOverflow(by: height)
        return !pixelCount.overflow && pixelCount.partialValue <= maximumPixelCount
    }

    static func pixelDimensions(
        widthRatio: Double,
        heightRatio: Double
    ) -> (width: Int, height: Int)? {
        guard widthRatio.isFinite, heightRatio.isFinite,
              widthRatio > 0, heightRatio > 0 else { return nil }
        let scale = Double(shortEdge) / min(widthRatio, heightRatio)
        let width = (widthRatio * scale).rounded()
        let height = (heightRatio * scale).rounded()
        guard width.isFinite, height.isFinite,
              width >= 1, height >= 1,
              width <= Double(maximumLongEdge),
              height <= Double(maximumLongEdge) else { return nil }
        let dimensions = (width: Int(width), height: Int(height))
        guard isValidPixelDimensions(
            width: dimensions.width,
            height: dimensions.height
        ) else { return nil }
        return dimensions
    }
}

@Model
final class CustomChekiSize {
    @Attribute(.unique) var id: UUID
    var name: String
    var widthRatio: Double
    var heightRatio: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        widthRatio: Double,
        heightRatio: Double,
        createdAt: Date = Date()
    ) {
        guard let dimensions = ChekinanaCustomChekiSizePolicy.pixelDimensions(
            widthRatio: widthRatio,
            heightRatio: heightRatio
        ) else {
            preconditionFailure("Custom Cheki size ratios must be positive finite values")
        }
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.widthRatio = widthRatio
        self.heightRatio = heightRatio
        pixelWidth = dimensions.width
        pixelHeight = dimensions.height
        self.createdAt = createdAt
    }

    var size: ChekiSize {
        .custom(id: id, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}

struct ChekinanaChekiSizeOption: Identifiable, Hashable {
    let size: ChekiSize
    let title: String

    var id: String { size.rawValue }
}

enum ChekinanaChekiSizeCatalog {
    static func options(customSizes: [CustomChekiSize]) -> [ChekinanaChekiSizeOption] {
        let builtIns = ChekiSize.builtInCases.map {
            ChekinanaChekiSizeOption(size: $0, title: title(for: $0, customSizes: []))
        }
        let custom = customSizes
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { ChekinanaChekiSizeOption(size: $0.size, title: $0.name) }
        return builtIns + custom
    }

    static func title(for size: ChekiSize, customSizes: [CustomChekiSize]) -> String {
        if size == .mini {
            return ChekinanaL10n.text("cheki.size.mini", fallback: "mini")
        }
        if size == .wide {
            return ChekinanaL10n.text("cheki.size.wide", fallback: "wide")
        }
        return customSizes.first { $0.id == size.customID }?.name ?? size.rawValue
    }
}

enum ChekinanaEventSource: String, Codable, Sendable {
    case weibo
    case x

    static func infer(from url: URL?) -> ChekinanaEventSource? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        else { return nil }
        if host == "weibo.com" || host.hasSuffix(".weibo.com")
            || host == "weibo.cn" || host.hasSuffix(".weibo.cn") {
            return .weibo
        }
        if host == "x.com" || host == "www.x.com" { return .x }
        return nil
    }

    static func validatedURL(
        from rawValue: String
    ) -> (url: URL, source: ChekinanaEventSource)? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == rawValue,
              value.utf8.count <= 2_048,
              let url = URL(string: value) else { return nil }
        let source: ChekinanaEventSource
        if ChekinanaEventCandidateValidator.isPublicWeiboStatusURL(value) {
            source = .weibo
        } else if ChekinanaEventCandidateValidator.isPublicXStatusURL(value) {
            source = .x
        } else {
            return nil
        }
        return (url, source)
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

    static func eventsOnExactDate(
        _ events: [Event],
        schedules: [EventSchedule] = [],
        for recordDate: Date?
    ) -> [Event] {
        guard let recordDay = recordDate.flatMap(ChekinanaDateOnly.canonicalized) else {
            return []
        }
        let startByEventID = ChekinanaEventOrdering.scheduleStartTimes(schedules)
        return events.filter {
            $0.date.flatMap(ChekinanaDateOnly.canonicalized) == recordDay
        }.sorted {
            ChekinanaEventOrdering.comesBefore(
                $0,
                $1,
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
    case arrivalBeforeToday

    var errorDescription: String? {
        switch self {
        case .missingRequiredFields:
            ChekinanaProductCopy.text(
                "travel.error.required",
                "Enter a flight or train number, departure location, and destination."
            )
        case .arrivalBeforeToday:
            ChekinanaProductCopy.text(
                "travel.error.arrival_before_today",
                "A new trip must end today or later."
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
        saveContext: (ModelContext) throws -> Void = { try $0.save() },
        validateManagedFiles: Bool = false,
        expectedGeneration: UUID? = nil,
        mediaOwnerID: UUID? = nil,
        mediaOwnerReferences: [String] = []
    ) throws -> TravelSegment {
        try ChekinanaTravelSegmentValidator.validate(fields)
        var deletionRefs: [String] = []
        return try ChekinanaLibraryMutationProtocol.withExclusiveOperationSync {
            try ChekinanaLibraryMutationPreflight.requireImportConvergedExclusively(in: modelContext)
            return try ChekinanaPersistenceMutationCoordinator.withLock {
            do {
                if let mediaOwnerID, let expectedGeneration {
                    try ChekinanaEventTravelMediaOwnership.validateSaveAuthorization(
                        ownerID: mediaOwnerID,
                        expectedGeneration: expectedGeneration,
                        ownedReferences: mediaOwnerReferences,
                        in: modelContext
                    )
                } else if validateManagedFiles {
                    throw ChekinanaEventTravelMediaOwnership
                        .SaveAuthorizationError.ownerUnavailable
                }
                if validateManagedFiles {
                    try ChekinanaEventMediaJournal.validateManagedFiles(
                        [operatorIconRef].compactMap { $0 }
                    )
                }
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
                if let mediaOwnerID, let expectedGeneration {
                    try ChekinanaEventTravelMediaOwnership.validateSaveAuthorization(
                        ownerID: mediaOwnerID,
                        expectedGeneration: expectedGeneration,
                        ownedReferences: mediaOwnerReferences,
                        in: modelContext
                    )
                } else if validateManagedFiles {
                    throw ChekinanaEventTravelMediaOwnership
                        .SaveAuthorizationError.ownerUnavailable
                }
                try saveContext(modelContext)
                ChekinanaEventMediaJournal.clearPending(
                    [operatorIconRef].compactMap { $0 }
                )
                if let mediaOwnerID {
                    ChekinanaEventTravelMediaOwnership.release(ownerID: mediaOwnerID)
                }
                return live
            } catch {
                modelContext.rollback()
                ChekinanaEventMediaJournal.cancelDeletion(deletionRefs)
                throw error
            }
            }
        }
    }

    static func delete(
        _ segment: TravelSegment,
        from modelContext: ModelContext,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        var deletionRefs: [String] = []
        try ChekinanaLibraryMutationProtocol.withExclusiveOperationSync {
            try ChekinanaLibraryMutationPreflight.requireImportConvergedExclusively(in: modelContext)
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
        }
        ChekinanaEventMediaJournal.scheduleSafeCleanup(in: modelContext)
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
        return ChekinanaPersistedContentDatePolicy.canonicalDate(
            from: selection,
            displayedIn: calendar
        )
    }
}

/// Frozen V4-V12 media graph. Historical schemas must reference these carrier
/// types so the active Idol/Event models can drop their old SwiftData
/// relationships without changing a shipped model checksum.
enum ChekinanaLegacyMediaSchema {
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

        init(id: UUID = UUID(), name: String) {
            self.id = id
            sourceId = nil
            self.name = name
            group = nil
            color = nil
            birthday = nil
            avatarImageRef = nil
            sortOrder = nil
            note = ""
            chekis = []
            shames = []
            dougas = []
            createdAt = Date()
            updatedAt = Date()
            verification = nil
            bio = nil
            pattern = nil
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

        init(id: UUID = UUID(), name: String) {
            self.id = id
            self.name = name
            date = nil
            city = nil
            livehouse = nil
            legacyVenue = nil
            avatarImageRef = nil
            price = nil
            weiboURL = nil
            ticketURL = nil
            note = ""
            chekis = []
            createdAt = Date()
            updatedAt = Date()
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

        init(id: UUID = UUID()) {
            self.id = id
            idols = []
            event = nil
            date = nil
            idx = nil
            userAppears = nil
            sizeRawValue = nil
            imageRef = nil
            note = ""
            createdAt = Date()
            updatedAt = Date()
        }
    }

    @Model final class Shame {
        @Attribute(.unique) var id: UUID
        var imageRef: String?
        var idols: [Idol]
        var date: Date?
        var note: String

        init(id: UUID = UUID()) {
            self.id = id
            imageRef = nil
            idols = []
            date = nil
            note = ""
        }
    }

    @Model final class Douga {
        @Attribute(.unique) var id: UUID
        var videoRef: String?
        var idols: [Idol]
        var date: Date?
        var note: String

        init(id: UUID = UUID()) {
            self.id = id
            videoRef = nil
            idols = []
            date = nil
            note = ""
        }
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

/// Durable provenance for the current Idol avatar. Absence of this sidecar is
/// the compatibility state for rows created before avatar intent was stored;
/// it must never be interpreted as an explicit removal or as permission to
/// fetch a catalogue replacement.
enum ChekinanaIdolAvatarSource: String, Codable, CaseIterable, Sendable {
    case legacyUnknown
    case none
    case catalogue
    case custom
}

enum ChekinanaIdolAvatarIntent: String, Codable, CaseIterable, Sendable {
    case unspecified
    case automatic
    case userSelected
    case explicitlyRemoved
}

struct ChekinanaIdolAvatarStateSnapshot: Equatable, Sendable {
    static let compatibilityDefault = Self(
        source: .legacyUnknown,
        intent: .unspecified,
        revision: nil
    )

    let source: ChekinanaIdolAvatarSource
    let intent: ChekinanaIdolAvatarIntent
    let revision: UUID?

    var allowsCatalogueRepair: Bool {
        source == .catalogue
            && (intent == .automatic || intent == .userSelected)
    }

    func isValid(avatarImageRef: String?) -> Bool {
        let hasReference = avatarImageRef?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false
        switch (source, intent) {
        case (.legacyUnknown, .unspecified):
            return true
        case (.none, .explicitlyRemoved):
            return !hasReference
        case (.catalogue, .automatic), (.catalogue, .userSelected),
                (.custom, .userSelected):
            return hasReference
        default:
            return false
        }
    }
}

@Model
final class IdolAvatarState {
    @Attribute(.unique) var idolID: UUID
    var sourceRawValue: String
    var intentRawValue: String
    /// Changes on every avatar transition and import replacement so an async
    /// repair cannot publish against a logically replaced same-UUID row.
    var revision: UUID

    init(
        idolID: UUID,
        source: ChekinanaIdolAvatarSource,
        intent: ChekinanaIdolAvatarIntent,
        revision: UUID = UUID()
    ) {
        self.idolID = idolID
        sourceRawValue = source.rawValue
        intentRawValue = intent.rawValue
        self.revision = revision
    }

    var snapshot: ChekinanaIdolAvatarStateSnapshot {
        guard let source = ChekinanaIdolAvatarSource(rawValue: sourceRawValue),
              let intent = ChekinanaIdolAvatarIntent(rawValue: intentRawValue) else {
            return .compatibilityDefault
        }
        return .init(source: source, intent: intent, revision: revision)
    }
}

enum ChekinanaIdolAvatarStatePersistence {
    static func state(
        for idolID: UUID,
        in modelContext: ModelContext
    ) throws -> IdolAvatarState? {
        var descriptor = FetchDescriptor<IdolAvatarState>(
            predicate: #Predicate { $0.idolID == idolID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    static func snapshot(
        for idolID: UUID,
        in modelContext: ModelContext
    ) throws -> ChekinanaIdolAvatarStateSnapshot {
        try state(for: idolID, in: modelContext)?.snapshot
            ?? .compatibilityDefault
    }

    @discardableResult
    static func record(
        idolID: UUID,
        source: ChekinanaIdolAvatarSource,
        intent: ChekinanaIdolAvatarIntent,
        in modelContext: ModelContext
    ) throws -> IdolAvatarState {
        let value: IdolAvatarState
        if let existing = try state(for: idolID, in: modelContext) {
            value = existing
            value.sourceRawValue = source.rawValue
            value.intentRawValue = intent.rawValue
            value.revision = UUID()
        } else {
            value = IdolAvatarState(
                idolID: idolID,
                source: source,
                intent: intent
            )
            modelContext.insert(value)
        }
        return value
    }

    static func delete(
        for idolID: UUID,
        in modelContext: ModelContext
    ) throws {
        if let value = try state(for: idolID, in: modelContext) {
            modelContext.delete(value)
        }
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

enum ChekinanaSingleOshiPreference {
    static let enabledKey = "chekinana.singleOshi.enabled"
    static let idolIDKey = "chekinana.singleOshi.idolID"

    static var selectedID: UUID? {
        guard UserDefaults.standard.bool(forKey: enabledKey),
              let value = UserDefaults.standard.string(forKey: idolIDKey) else { return nil }
        return UUID(uuidString: value)
    }

    static func prioritized<Value>(
        _ values: [Value], preferredID: UUID? = selectedID,
        contains: (Value, UUID) -> Bool
    ) -> [Value] {
        guard let preferredID else { return values }
        return values.filter { contains($0, preferredID) }
            + values.filter { !contains($0, preferredID) }
    }
}

enum ChekinanaIdolOrdering {
    struct Context: Equatable, Sendable {
        let chekiCountsByIdolID: [UUID: Int]
        let preferredID: UUID?

        init(chekiCountsByIdolID: [UUID: Int] = [:], preferredID: UUID? = ChekinanaSingleOshiPreference.selectedID) {
            self.preferredID = preferredID
            self.chekiCountsByIdolID = chekiCountsByIdolID
        }

        func ordered(_ idols: [Idol]) -> [Idol] {
            ChekinanaIdolOrdering.orderedForList(
                idols,
                chekiCountsByIdolID: chekiCountsByIdolID, preferredID: preferredID
            )
        }

        func orderedUnique(_ idols: [Idol]) -> [Idol] {
            var uniqueByID: [UUID: Idol] = [:]
            for idol in idols where uniqueByID[idol.id] == nil {
                uniqueByID[idol.id] = idol
            }
            return ordered(Array(uniqueByID.values))
        }

        /// Orders exact Idol combinations without depending on relationship
        /// storage order. `nil` means both values describe the same set.
        func combinationPrecedes(_ lhs: [Idol], _ rhs: [Idol]) -> Bool? {
            let left = orderedUnique(lhs)
            let right = orderedUnique(rhs)
            switch (left.first, right.first) {
            case (nil, nil):
                return nil
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (.some, .some):
                break
            }

            let all = orderedUnique(left + right)
            let rankByID = Dictionary(
                uniqueKeysWithValues: all.enumerated().map { ($0.element.id, $0.offset) }
            )
            for (leftIdol, rightIdol) in zip(left, right) {
                guard leftIdol.id != rightIdol.id else { continue }
                return rankByID[leftIdol.id, default: .max]
                    < rankByID[rightIdol.id, default: .max]
            }
            if left.count != right.count { return left.count < right.count }
            return nil
        }
    }

    static func ordered(_ idols: [Idol], preferredID: UUID? = ChekinanaSingleOshiPreference.selectedID) -> [Idol] {
        idols.sorted { lhs, rhs in
            if (lhs.id == preferredID) != (rhs.id == preferredID) { return lhs.id == preferredID }
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
        chekiCountsByIdolID: [UUID: Int],
        preferredID: UUID? = ChekinanaSingleOshiPreference.selectedID
    ) -> [Idol] {
        idols.sorted { lhs, rhs in
            if (lhs.id == preferredID) != (rhs.id == preferredID) { return lhs.id == preferredID }
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            let leftCount = chekiCountsByIdolID[lhs.id] ?? 0
            let rightCount = chekiCountsByIdolID[rhs.id] ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            let groupComparison = (lhs.group ?? "").localizedStandardCompare(rhs.group ?? "")
            if groupComparison != .orderedSame { return groupComparison == .orderedAscending }
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
    var sourceRawValue: String?
    var ticketURL: URL?
    var note: String
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
        source: ChekinanaEventSource? = nil,
        ticketURL: URL? = nil,
        note: String = "",
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
        self.sourceRawValue = source?.rawValue
        self.ticketURL = ticketURL
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var resolvedLivehouse: String? {
        let current = livehouse?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current, !current.isEmpty { return current }
        let legacy = legacyVenue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (legacy?.isEmpty == false) ? legacy : nil
    }

    var source: ChekinanaEventSource? {
        get { sourceRawValue.flatMap(ChekinanaEventSource.init(rawValue:)) }
        set { sourceRawValue = newValue?.rawValue }
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
        let eventMatches = try modelContext.fetch(FetchDescriptor<Event>(
            predicate: #Predicate { $0.id == eventID }
        ))
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
        let matches = try verificationContext.fetch(FetchDescriptor<Event>(
            predicate: #Predicate { $0.id == eventID }
        ))
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
        if schedule.openTime != normalizedOpen { schedule.openTime = normalizedOpen }
        if schedule.startTime != normalizedStart { schedule.startTime = normalizedStart }
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
            guard try modelContext.fetch(FetchDescriptor<MediaItem>())
                .contains(where: { $0.id == mediaID && $0.kind == .shame }) else {
                throw ChekinanaModelContextResolver.ResolutionError.missingShame
            }
        case .douga:
            guard try modelContext.fetch(FetchDescriptor<MediaItem>())
                .contains(where: { $0.id == mediaID && $0.kind == .douga }) else {
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
            guard try modelContext.fetch(FetchDescriptor<MediaItem>())
                .contains(where: { $0.id == mediaID && $0.kind == .shame }) else {
                throw ChekinanaModelContextResolver.ResolutionError.missingShame
            }
        case .douga:
            guard try modelContext.fetch(FetchDescriptor<MediaItem>())
                .contains(where: { $0.id == mediaID && $0.kind == .douga }) else {
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
        let matches = try modelContext.fetch(FetchDescriptor<CalendarGroupOrder>(
            predicate: #Predicate { $0.dateKey == dateKey }
        ))
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
                if order.sortOrder != index {
                    order.sortOrder = index
                }
            }
            try saveContext(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

enum MediaItemKind: String, Codable, CaseIterable, Sendable {
    case cheki
    case shame
    case douga
}

enum MemoryAttachmentKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
}

enum ChekinanaMemoryValidationError: LocalizedError, Equatable {
    case empty
    case invalidDate
    case invalidAttachment

    var errorDescription: String? {
        switch self {
        case .empty: ChekinanaL10n.text("product.memory.validation.empty", fallback: "Memory must contain at least one value.")
        case .invalidDate: ChekinanaL10n.text("product.memory.validation.invalid_date", fallback: "The Memory date is outside the supported range.")
        case .invalidAttachment: ChekinanaL10n.text("product.memory.validation.invalid_attachment", fallback: "A Memory attachment is invalid.")
        }
    }
}

enum ChekinanaMemoryPolicy {
    static func meaningfulText(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    static func normalizedTitle(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    static func isValid(
        title: String?,
        bodyText: String?,
        date: Date?,
        eventID: UUID?,
        idolIDs: [UUID],
        attachmentCount: Int
    ) -> Bool {
        normalizedTitle(title) != nil
            || meaningfulText(bodyText) != nil
            || date != nil
            || eventID != nil
            || !idolIDs.isEmpty
            || attachmentCount > 0
    }

    static func validatedDate(_ value: Date?) throws -> Date? {
        try ChekinanaPersistedContentDatePolicy.validatedCanonical(value)
    }

    static func validateContent(
        title: String?,
        bodyText: String?,
        date: Date?,
        eventID: UUID?,
        idolIDs: [UUID],
        attachmentCount: Int
    ) throws -> Date? {
        guard isValid(
            title: title,
            bodyText: bodyText,
            date: date,
            eventID: eventID,
            idolIDs: idolIDs,
            attachmentCount: attachmentCount
        ) else { throw ChekinanaMemoryValidationError.empty }
        return try validatedDate(date)
    }
}

struct ChekinanaMemoryIdolRelationshipDraft: Equatable {
    /// The complete relationship snapshot at editor initialization, including hidden Idols.
    let initialIDs: Set<UUID>
    private(set) var explicitlyAddedIDs = Set<UUID>()
    private(set) var explicitlyRemovedIDs = Set<UUID>()

    init(initialIDs: some Sequence<UUID>) {
        self.initialIDs = Set(initialIDs)
    }

    func selectedIDs(
        currentPersistedIDs: some Sequence<UUID>
    ) -> Set<UUID> {
        var result = maintenanceAdjustedInitialIDs(
            currentPersistedIDs: currentPersistedIDs
        )
        result.formUnion(explicitlyAddedIDs)
        result.subtract(explicitlyRemovedIDs)
        return result
    }

    func selectedVisibleIDs(
        currentPersistedIDs: some Sequence<UUID>,
        visibleIDs: Set<UUID>
    ) -> Set<UUID> {
        selectedIDs(currentPersistedIDs: currentPersistedIDs)
            .intersection(visibleIDs)
    }

    mutating func recordVisibleSelection(
        _ selectedVisibleIDs: Set<UUID>,
        visibleIDs: Set<UUID>,
        currentPersistedIDs: some Sequence<UUID>
    ) {
        let previousVisibleIDs = self.selectedVisibleIDs(
            currentPersistedIDs: currentPersistedIDs,
            visibleIDs: visibleIDs
        )
        let selectedVisibleIDs = selectedVisibleIDs.intersection(visibleIDs)
        let addedIDs = selectedVisibleIDs.subtracting(previousVisibleIDs)
        let removedIDs = previousVisibleIDs.subtracting(selectedVisibleIDs)

        explicitlyRemovedIDs.subtract(addedIDs)
        explicitlyAddedIDs.formUnion(addedIDs)
        explicitlyAddedIDs.subtract(removedIDs)
        explicitlyRemovedIDs.formUnion(removedIDs)
    }

    func resolvedIDs(
        currentPersistedIDs: some Sequence<UUID>,
        validIDs: Set<UUID>
    ) -> Set<UUID> {
        selectedIDs(currentPersistedIDs: currentPersistedIDs)
            .intersection(validIDs)
    }

    private func maintenanceAdjustedInitialIDs(
        currentPersistedIDs: some Sequence<UUID>
    ) -> Set<UUID> {
        let currentPersistedIDs = Set(currentPersistedIDs)
        // Replay relationship maintenance that happened while the editor was open.
        // Deletions remove stale IDs and merges contribute their surviving target IDs.
        let removedByMaintenance = initialIDs.subtracting(currentPersistedIDs)
        let addedByMaintenance = currentPersistedIDs.subtracting(initialIDs)
        var result = initialIDs
        result.subtract(removedByMaintenance)
        result.formUnion(addedByMaintenance)
        return result
    }
}

enum ChekinanaMemoryAttachmentLifecyclePolicy {
    static func removesStagedFileImmediately(
        existingReference: String?,
        stagedURL: URL?
    ) -> Bool {
        existingReference == nil && stagedURL != nil
    }

    static func removesManagedFileBeforeSuccessfulSave(existingReference: String?) -> Bool {
        false
    }
}

struct ChekinanaMemoryAttachmentImportGate: Equatable {
    private(set) var activeTokens = Set<UUID>()
    private(set) var isClosing = false
    private(set) var saveOwnerID: UUID?

    var isImporting: Bool { !activeTokens.isEmpty }
    var allowsSave: Bool {
        !isClosing && saveOwnerID == nil && activeTokens.isEmpty
    }

    mutating func begin() -> UUID? {
        guard !isClosing, saveOwnerID == nil else { return nil }
        let token = UUID()
        activeTokens.insert(token)
        return token
    }

    func acceptsCompletion(_ token: UUID) -> Bool {
        !isClosing && activeTokens.contains(token)
    }

    mutating func finish(_ token: UUID) {
        activeTokens.remove(token)
    }

    mutating func beginSave(ownerID: UUID) -> Bool {
        guard !isClosing, saveOwnerID == nil, activeTokens.isEmpty else {
            return false
        }
        saveOwnerID = ownerID
        return true
    }

    mutating func finishSave(ownerID: UUID) {
        guard saveOwnerID == ownerID else { return }
        saveOwnerID = nil
    }

    mutating func close() {
        isClosing = true
        saveOwnerID = nil
    }
}

@Model
final class Memory {
    @Attribute(.unique) var id: UUID
    var title: String?
    var bodyText: String?
    var date: Date?
    var eventID: UUID?
    var idolIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String? = nil,
        bodyText: String? = nil,
        date: Date? = nil,
        eventID: UUID? = nil,
        idolIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = ChekinanaMemoryPolicy.normalizedTitle(title)
        self.bodyText = ChekinanaMemoryPolicy.meaningfulText(bodyText)
        self.date = date
        self.eventID = eventID
        var seen = Set<UUID>()
        self.idolIDs = idolIDs.filter { seen.insert($0).inserted }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class MemoryAttachment {
    @Attribute(.unique) var id: UUID
    var memoryID: UUID
    private(set) var kindRawValue: String
    private(set) var managedRef: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    var kind: MemoryAttachmentKind {
        MemoryAttachmentKind(rawValue: kindRawValue) ?? .image
    }

    init(
        id: UUID = UUID(),
        memoryID: UUID,
        kind: MemoryAttachmentKind,
        managedRef: String,
        sortOrder: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        guard let normalized = managedRef.nonEmpty else {
            preconditionFailure("MemoryAttachment requires managed media")
        }
        self.id = id
        self.memoryID = memoryID
        kindRawValue = kind.rawValue
        self.managedRef = normalized
        self.sortOrder = max(0, sortOrder)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func replaceFromBackup(
        memoryID: UUID,
        kind: MemoryAttachmentKind,
        managedRef: String,
        sortOrder: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        guard let normalized = managedRef.nonEmpty else {
            preconditionFailure("MemoryAttachment requires managed media")
        }
        self.memoryID = memoryID
        kindRawValue = kind.rawValue
        self.managedRef = normalized
        self.sortOrder = max(0, sortOrder)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ChekinanaMemoryRecordSnapshot: Equatable, Sendable {
    let id: UUID
    let title: String?
    let bodyText: String?
    let date: Date?
    let eventID: UUID?
    let idolIDs: [UUID]
    let createdAt: Date
    let updatedAt: Date

    init(_ memory: Memory) {
        id = memory.id
        title = memory.title
        bodyText = memory.bodyText
        date = memory.date
        eventID = memory.eventID
        idolIDs = memory.idolIDs
        createdAt = memory.createdAt
        updatedAt = memory.updatedAt
    }
}

struct ChekinanaMemoryAttachmentRecordSnapshot: Equatable, Sendable {
    let id: UUID
    let memoryID: UUID
    let kind: MemoryAttachmentKind
    let managedRef: String
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    init(_ attachment: MemoryAttachment) {
        id = attachment.id
        memoryID = attachment.memoryID
        kind = attachment.kind
        managedRef = attachment.managedRef
        sortOrder = attachment.sortOrder
        createdAt = attachment.createdAt
        updatedAt = attachment.updatedAt
    }
}

struct ChekinanaMemoryTargetSnapshot: Equatable, Sendable {
    let record: ChekinanaMemoryRecordSnapshot
    let attachments: [ChekinanaMemoryAttachmentRecordSnapshot]

    init(
        record: ChekinanaMemoryRecordSnapshot,
        attachments: [ChekinanaMemoryAttachmentRecordSnapshot]
    ) {
        self.record = record
        self.attachments = attachments.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct ChekinanaMemorySaveAttachmentDraft: Equatable, Sendable {
    let id: UUID
    let kind: MemoryAttachmentKind
    let existingReference: String?
    let stagedURL: URL?
    let sortOrder: Int
}

struct ChekinanaMemorySaveDraft: Equatable, Sendable {
    let title: String
    let bodyText: String
    let date: Date?
    let eventID: UUID?
    let idolIDs: [UUID]
    let attachments: [ChekinanaMemorySaveAttachmentDraft]
}

struct ChekinanaMemorySaveAuthorization: Equatable, Sendable {
    let ownerID: UUID
    let libraryGeneration: UUID
    let targetID: UUID
    let expectedTarget: ChekinanaMemoryTargetSnapshot?
}

struct ChekinanaMemoryMaterializedAttachment: Equatable, Sendable {
    let ownerID: UUID
    let libraryGeneration: UUID
    let id: UUID
    let kind: MemoryAttachmentKind
    let managedRef: String
}

enum ChekinanaMemorySaveMutationError: LocalizedError, Equatable {
    case changedLibrary
    case changedMemory
    case changedRelationships
    case invalidDraft

    var errorDescription: String? {
        switch self {
        case .changedLibrary:
            ChekinanaL10n.message("The library changed while this Memory was saving. Retry in the current library.")
        case .changedMemory:
            ChekinanaL10n.message("This Memory changed or was deleted. Reopen it before saving.")
        case .changedRelationships:
            ChekinanaL10n.message("A selected relationship changed. Review the Memory and try again.")
        case .invalidDraft:
            ChekinanaL10n.message("The Memory draft changed while it was saving. Try again.")
        }
    }
}

enum ChekinanaNewMediaDefaults {
    /// New Photo/写メ items are 2-shot by default. Existing persisted values
    /// remain authoritative and migration call sites pass their stored value.
    static func userAppears(for kind: MediaItemKind) -> Bool {
        kind == .shame
    }
}

enum ChekinanaMediaItemInvariantError: Error, Equatable {
    case invalidKind
    case missingMedia
    case nonChekiMetadata
}

/// The only active persisted media entity. ChekiRecord deliberately remains a
/// separate no-media business record.
@Model
final class MediaItem {
    @Attribute(.unique) var id: UUID
    /// Stable owner of the existing managed media files. This deliberately
    /// remains the legacy UUID when a cross-kind database ID collision forces
    /// `id` to be remapped during migration.
    var mediaOwnerID: UUID
    private(set) var kindRawValue: String
    var idolIDs: [UUID] {
        didSet {
            if detachedIdols.map(\.id) != idolIDs {
                detachedIdols = []
            }
        }
    }
    var eventID: UUID? {
        didSet {
            if detachedEvent?.id != eventID {
                detachedEvent = nil
            }
        }
    }
    var date: Date?
    var userAppears: Bool
    var isFavorite: Bool = false
    var hasPostedToSNS: Bool = false
    var note: String
    private(set) var mediaRef: String
    var sizeRawValue: String? {
        didSet {
            precondition(kind == .cheki || sizeRawValue == nil, "Only Cheki can store a size")
        }
    }
    var idx: Int? {
        didSet {
            precondition(kind == .cheki || idx == nil, "Only Cheki can store an index")
        }
    }
    var createdAt: Date
    var updatedAt: Date
    @Transient private var detachedIdols: [Idol] = []
    @Transient private var detachedEvent: Event?

    var kind: MediaItemKind {
        MediaItemKind(rawValue: kindRawValue) ?? .cheki
    }

    var idols: [Idol] {
        get {
            guard let modelContext else { return detachedIdols }
            if detachedIdols.map(\.id) == idolIDs,
               detachedIdols.allSatisfy({ $0.modelContext === modelContext }) {
                return detachedIdols
            }
            let wanted = Set(idolIDs)
            let resolved = ((try? modelContext.fetch(FetchDescriptor<Idol>())) ?? [])
                .filter { wanted.contains($0.id) }
                .sorted { lhs, rhs in
                    let left = idolIDs.firstIndex(of: lhs.id) ?? .max
                    let right = idolIDs.firstIndex(of: rhs.id) ?? .max
                    return left < right
                }
            detachedIdols = resolved
            return resolved
        }
        set {
            detachedIdols = newValue
            var seen = Set<UUID>()
            idolIDs = newValue.map(\.id).filter { seen.insert($0).inserted }
        }
    }

    var event: Event? {
        get {
            guard let modelContext, let eventID else { return detachedEvent }
            if let detachedEvent,
               detachedEvent.id == eventID,
               detachedEvent.modelContext === modelContext {
                return detachedEvent
            }
            let resolved = ((try? modelContext.fetch(FetchDescriptor<Event>())) ?? [])
                .first { $0.id == eventID }
            detachedEvent = resolved
            return resolved
        }
        set {
            detachedEvent = newValue
            eventID = newValue?.id
        }
    }

    var imageRef: String? {
        get { kind == .douga ? nil : mediaRef }
        set {
            precondition(kind != .douga, "Video media cannot store an image reference")
            guard let newValue, let normalized = newValue.nonEmpty else {
                preconditionFailure("MediaItem requires media")
            }
            mediaRef = normalized
        }
    }

    var videoRef: String? {
        get { kind == .douga ? mediaRef : nil }
        set {
            precondition(kind == .douga, "Image media cannot store a video reference")
            guard let newValue, let normalized = newValue.nonEmpty else {
                preconditionFailure("MediaItem requires media")
            }
            mediaRef = normalized
        }
    }

    var size: ChekiSize? {
        get {
            kind == .cheki
                ? (sizeRawValue.flatMap(ChekiSize.init(rawValue:)) ?? .mini) : nil
        }
        set {
            precondition(kind == .cheki, "Only Cheki can store a size")
            sizeRawValue = (newValue ?? .mini).rawValue
        }
    }

    init(
        id: UUID = UUID(),
        mediaOwnerID: UUID? = nil,
        kind: MediaItemKind,
        idols: [Idol] = [],
        event: Event? = nil,
        date: Date? = nil,
        idx: Int? = nil,
        userAppears: Bool? = nil,
        size: ChekiSize? = nil,
        mediaRef: String,
        isFavorite: Bool = false,
        hasPostedToSNS: Bool = false,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let normalizedRef = mediaRef.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedRef.isEmpty, "MediaItem requires media")
        self.id = id
        self.mediaOwnerID = mediaOwnerID ?? id
        kindRawValue = kind.rawValue
        var seen = Set<UUID>()
        idolIDs = idols.map(\.id).filter { seen.insert($0).inserted }
        eventID = event?.id
        detachedIdols = idols
        detachedEvent = event
        self.date = date
        self.userAppears = userAppears ?? ChekinanaNewMediaDefaults.userAppears(for: kind)
        self.isFavorite = isFavorite
        self.hasPostedToSNS = hasPostedToSNS
        self.note = note
        self.mediaRef = normalizedRef
        sizeRawValue = kind == .cheki ? (size ?? .mini).rawValue : nil
        self.idx = kind == .cheki ? idx : nil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Source-compatible Cheki constructor used by existing creation paths
    /// while all persisted media is backed by MediaItem.
    convenience init(
        id: UUID = UUID(),
        mediaOwnerID: UUID? = nil,
        idols: [Idol] = [],
        event: Event? = nil,
        date: Date? = nil,
        idx: Int? = nil,
        userAppears: Bool? = nil,
        size: ChekiSize? = nil,
        imageRef: String,
        isFavorite: Bool = false,
        hasPostedToSNS: Bool = false,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.init(
            id: id,
            mediaOwnerID: mediaOwnerID,
            kind: .cheki,
            idols: idols,
            event: event,
            date: date,
            idx: idx,
            userAppears: userAppears ?? false,
            size: size,
            mediaRef: imageRef,
            isFavorite: isFavorite,
            hasPostedToSNS: hasPostedToSNS,
            note: note,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Source-compatible Shame constructor. Cheki-only carriers are always nil.
    convenience init(
        id: UUID = UUID(),
        mediaOwnerID: UUID? = nil,
        imageRef: String,
        idols: [Idol] = [],
        date: Date? = nil,
        note: String = ""
    ) {
        self.init(
            id: id,
            mediaOwnerID: mediaOwnerID,
            kind: .shame,
            idols: idols,
            date: date,
            mediaRef: imageRef,
            note: note
        )
    }

    /// Source-compatible Douga constructor. Cheki-only carriers are always nil.
    convenience init(
        id: UUID = UUID(),
        mediaOwnerID: UUID? = nil,
        videoRef: String,
        idols: [Idol] = [],
        date: Date? = nil,
        note: String = ""
    ) {
        self.init(
            id: id,
            mediaOwnerID: mediaOwnerID,
            kind: .douga,
            idols: idols,
            date: date,
            mediaRef: videoRef,
            note: note
        )
    }

    init(
        id: UUID,
        mediaOwnerID: UUID? = nil,
        kind: MediaItemKind,
        idolIDs: [UUID],
        eventID: UUID?,
        date: Date?,
        userAppears: Bool,
        isFavorite: Bool,
        hasPostedToSNS: Bool,
        note: String,
        mediaRef: String,
        sizeRawValue: String?,
        idx: Int?,
        createdAt: Date,
        updatedAt: Date
    ) {
        let normalizedRef = mediaRef.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedRef.isEmpty, "MediaItem requires media")
        self.id = id
        self.mediaOwnerID = mediaOwnerID ?? id
        kindRawValue = kind.rawValue
        var seen = Set<UUID>()
        self.idolIDs = idolIDs.filter { seen.insert($0).inserted }
        self.eventID = eventID
        self.date = date
        self.userAppears = userAppears
        self.isFavorite = isFavorite
        self.hasPostedToSNS = hasPostedToSNS
        self.note = note
        self.mediaRef = normalizedRef
        self.sizeRawValue = kind == .cheki
            ? (sizeRawValue.flatMap(ChekiSize.init(rawValue:)) ?? .mini).rawValue
            : nil
        self.idx = kind == .cheki ? idx : nil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func setChekiMetadata(size: ChekiSize?, idx: Int?) throws {
        guard kind == .cheki else {
            throw ChekinanaMediaItemInvariantError.nonChekiMetadata
        }
        sizeRawValue = (size ?? .mini).rawValue
        self.idx = idx
    }

    func replaceMediaRef(_ value: String) throws {
        guard let normalized = value.nonEmpty else {
            throw ChekinanaMediaItemInvariantError.missingMedia
        }
        mediaRef = normalized
    }

    func replaceFromBackup(
        mediaOwnerID: UUID,
        kind: MediaItemKind,
        idolIDs: [UUID],
        eventID: UUID?,
        date: Date?,
        userAppears: Bool,
        isFavorite: Bool,
        hasPostedToSNS: Bool,
        note: String,
        mediaRef: String,
        sizeRawValue: String?,
        idx: Int?,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard let normalizedRef = mediaRef.nonEmpty else {
            throw ChekinanaMediaItemInvariantError.missingMedia
        }
        self.mediaOwnerID = mediaOwnerID
        kindRawValue = kind.rawValue
        var seen = Set<UUID>()
        self.idolIDs = idolIDs.filter { seen.insert($0).inserted }
        self.eventID = eventID
        self.date = date
        self.userAppears = userAppears
        self.isFavorite = isFavorite
        self.hasPostedToSNS = hasPostedToSNS
        self.note = note
        self.mediaRef = normalizedRef
        self.sizeRawValue = kind == .cheki
            ? (sizeRawValue.flatMap(ChekiSize.init(rawValue:)) ?? .mini).rawValue
            : nil
        self.idx = kind == .cheki ? idx : nil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func validateInvariant() throws {
        guard MediaItemKind(rawValue: kindRawValue) != nil else {
            throw ChekinanaMediaItemInvariantError.invalidKind
        }
        guard mediaRef.nonEmpty != nil else {
            throw ChekinanaMediaItemInvariantError.missingMedia
        }
        guard kind == .cheki || (sizeRawValue == nil && idx == nil) else {
            throw ChekinanaMediaItemInvariantError.nonChekiMetadata
        }
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
        get { sizeRawValue.flatMap(ChekiSize.init(rawValue:)) ?? .mini }
        set { sizeRawValue = (newValue ?? .mini).rawValue }
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
        self.sizeRawValue = (size ?? .mini).rawValue
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

/// Applies an explicit Event association to otherwise-unassigned records for
/// the same single Idol and canonical day. This mutates only scalar Event keys;
/// callers keep the propagation in the same transaction as the source save.
enum ChekinanaEventAssociationPropagation {
    @discardableResult
    static func propagate(
        from source: MediaItem,
        in modelContext: ModelContext
    ) throws -> Int {
        try propagate(
            idolIDs: source.idolIDs,
            eventID: source.eventID,
            date: source.date,
            protectingRecordIDs: [],
            in: modelContext
        )
    }

    @discardableResult
    static func propagate(
        from source: ChekiRecord,
        in modelContext: ModelContext
    ) throws -> Int {
        try propagate(
            idolIDs: source.idolIDs,
            eventID: source.eventID,
            date: source.date,
            protectingRecordIDs: [],
            in: modelContext
        )
    }

    /// Batch editors use `protectingRecordIDs` for rows whose Event field was
    /// explicitly touched. In particular, an explicit clear must remain nil
    /// even when a sibling row supplies an Event to the same propagation group.
    @discardableResult
    static func propagate(
        idolIDs: [UUID],
        eventID: UUID?,
        date: Date?,
        protectingRecordIDs: Set<UUID>,
        in modelContext: ModelContext,
        editIntentDirectory: URL? = nil
    ) throws -> Int {
        try ChekinanaPersistenceMutationCoordinator.withLock {
            // Every association writer reaches this shared preflight before it
            // can mutate a MediaItem. The lock is recursive for callers that
            // already own the wider validation/save transaction.
            try ChekinanaChekiEditRecovery.requireConvergedExclusively(
                in: modelContext,
                directory: editIntentDirectory
            )
            guard idolIDs.count == 1,
                  let idolID = idolIDs.first,
                  let eventID,
                  let date,
                  let canonicalDay = ChekinanaDateOnly.canonicalized(date) else {
                return 0
            }
            let nextDay = canonicalDay.addingTimeInterval(86_400)
            let missingDateSentinel = Date.distantPast

            let mediaDescriptor = FetchDescriptor<MediaItem>(
                predicate: #Predicate {
                    $0.eventID == nil
                        && ($0.date ?? missingDateSentinel) >= canonicalDay
                        && ($0.date ?? missingDateSentinel) < nextDay
                }
            )
            let recordDescriptor = FetchDescriptor<ChekiRecord>(
                predicate: #Predicate {
                    $0.eventID == nil
                        && ($0.date ?? missingDateSentinel) >= canonicalDay
                        && ($0.date ?? missingDateSentinel) < nextDay
                }
            )

            var mutationCount = 0
            for target in try modelContext.fetch(mediaDescriptor) where
                target.eventID == nil
                    && target.idolIDs.count == 1
                    && target.idolIDs.first == idolID
                    && target.date.flatMap(ChekinanaDateOnly.canonicalized)
                        == canonicalDay {
                target.eventID = eventID
                mutationCount += 1
            }
            for target in try modelContext.fetch(recordDescriptor) where
                target.eventID == nil
                    && !protectingRecordIDs.contains(target.id)
                    && target.idolIDs.count == 1
                    && target.idolIDs.first == idolID
                    && target.date.flatMap(ChekinanaDateOnly.canonicalized)
                        == canonicalDay {
                target.eventID = eventID
                mutationCount += 1
            }
            return mutationCount
        }
    }
}

enum ChekinanaDisplayCount {
    nonisolated static func normalized(_ value: Int) -> Int {
        max(0, value)
    }

    nonisolated static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = normalized(lhs).addingReportingOverflow(
            normalized(rhs)
        )
        return overflow ? Int.max : sum
    }

    nonisolated static func total(_ values: some Sequence<Int>) -> Int {
        values.reduce(0) { adding($0, $1) }
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

    /// User-visible/statistical total. Persistence mutations must use
    /// `checkedCountSum` so real quantity overflow remains an explicit failure.
    nonisolated static func totalCount(
        _ records: some Sequence<ChekiRecord>
    ) -> Int {
        records.reduce(0) { partialResult, record in
            ChekinanaDisplayCount.adding(partialResult, record.count)
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
        let normalizedSize = size ?? .mini
        let validatedDate = try ChekinanaPersistedContentDatePolicy
            .validatedCanonical(date)
        return try withMutationLock {
            do {
                let relationships = try validatedRelationshipIDs(
                    idolIDs: requestedIdolIDs,
                    eventID: requestedEventID,
                    recordDate: validatedDate,
                    in: modelContext
                )
                let identity = ChekinanaChekiRecordIdentity(
                    idolIDs: relationships.idolIDs,
                    date: validatedDate,
                    eventID: relationships.eventID,
                    sizeRawValue: normalizedSize.rawValue,
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
                    try ChekinanaEventAssociationPropagation.propagate(
                        from: retained,
                        in: modelContext
                    )
                    try saveContext(modelContext)
                    return retained
                }
                let record = ChekiRecord(
                    date: identity.canonicalDate,
                    size: normalizedSize,
                    note: note,
                    count: quantity
                )
                record.idolIDs = relationships.idolIDs
                record.eventID = relationships.eventID
                modelContext.insert(record)
                try ChekinanaEventAssociationPropagation.propagate(
                    from: record,
                    in: modelContext
                )
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
        try update(
            recordID: record.id,
            idolIDs: idols.map(\.id),
            eventID: event?.id,
            date: date,
            size: size,
            note: note,
            count: count,
            expected: expected,
            in: modelContext,
            saveContext: saveContext
        )
    }

    /// Scalar-keyed update used by record editors. ChekiRecord persists these
    /// relationship keys directly, so resolving them into full model objects
    /// before entering the store only duplicates the store's validation work.
    @discardableResult
    static func update(
        recordID: UUID,
        idolIDs: [UUID],
        eventID: UUID?,
        date: Date?,
        size: ChekiSize?,
        note: String,
        count: Int,
        expected: ChekinanaChekiRecordSnapshot? = nil,
        in modelContext: ModelContext,
        saveContext: SaveContext = { try $0.save() }
    ) throws -> ChekiRecord? {
        let validatedDate = try ChekinanaPersistedContentDatePolicy
            .validatedCanonical(date)
        let normalizedSize = size ?? .mini
        return try withMutationLock { () -> ChekiRecord? in
            try verifyPersistedSnapshot(
                expected,
                recordID: recordID,
                in: modelContext
            )
            guard let live = try record(
                id: recordID,
                in: modelContext
            ),
                  expected == nil || ChekinanaChekiRecordSnapshot(live) == expected else {
                throw ChekinanaChekiRecordMutationError.changedRecord
            }

            guard count > 0 else {
                do {
                    modelContext.delete(live)
                    try saveContext(modelContext)
                    return nil
                } catch {
                    modelContext.rollback()
                    throw error
                }
            }

            let relationships = try validatedRelationshipIDs(
                idolIDs: idolIDs,
                eventID: eventID,
                recordDate: validatedDate,
                in: modelContext
            )
            let identity = ChekinanaChekiRecordIdentity(
                idolIDs: relationships.idolIDs,
                date: validatedDate,
                eventID: relationships.eventID,
                sizeRawValue: normalizedSize.rawValue,
                note: note
            )
            let collisions = try collisionCandidates(
                for: identity,
                excluding: live.id,
                in: modelContext
            )
                .filter {
                    ChekinanaChekiRecordIdentity($0) == identity
                }
            let mergedCount = try collisions.reduce(count) { partial, collision in
                try checkedCountSum(partial, max(1, collision.count))
            }

            // Everything above this boundary is read-only validation. A stale
            // snapshot or missing relationship must not roll back unrelated
            // unsaved UI state in the shared ModelContext. From here onward,
            // failures do require rollback because model objects are mutated.
            do {
                live.idolIDs = relationships.idolIDs
                live.eventID = relationships.eventID
                live.date = identity.canonicalDate
                live.sizeRawValue = identity.sizeRawValue
                live.note = identity.note
                live.count = mergedCount
                for collision in collisions {
                    modelContext.delete(collision)
                }
                try ChekinanaEventAssociationPropagation.propagate(
                    from: live,
                    in: modelContext
                )
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
            try verifyPersistedSnapshot(
                expected,
                recordID: record.id,
                in: modelContext
            )
            guard let live = try Self.record(id: record.id, in: modelContext),
                  expected == nil || ChekinanaChekiRecordSnapshot(live) == expected else {
                throw ChekinanaChekiRecordMutationError.changedRecord
            }

            do {
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
        try mergeDuplicates(in: modelContext, fetchedRecords: nil)
    }

    fileprivate nonisolated static func mergeDuplicates(
        in modelContext: ModelContext,
        fetchedRecords: [ChekiRecord]?
    ) throws {
        try withMutationLock {
            do {
                let records = try (fetchedRecords
                    ?? modelContext.fetch(FetchDescriptor<ChekiRecord>()))
                var identities = Set<ChekinanaChekiRecordIdentity>()
                var hasDuplicates = false
                var prepared = records.map { record in
                    let identity = ChekinanaChekiRecordIdentity(record)
                    if !hasDuplicates && !identities.insert(identity).inserted { hasDuplicates = true }
                    return (record: record, identity: identity)
                }
                // Only duplicate groups need UUID ordering to choose the survivor.
                if hasDuplicates {
                    prepared.sort { $0.record.id.uuidString < $1.record.id.uuidString }
                }
                var retainedByIdentity: [ChekinanaChekiRecordIdentity: ChekiRecord] = [:]
                for (record, identity) in prepared {
                    let normalizedCount = max(1, record.count)
                    if record.count != normalizedCount { record.count = normalizedCount }
                    if record.date != identity.canonicalDate { record.date = identity.canonicalDate }
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
        if !uniqueIdolIDs.isEmpty {
            let requestedIdolIDs = uniqueIdolIDs
            var idolDescriptor = FetchDescriptor<Idol>(
                predicate: #Predicate { requestedIdolIDs.contains($0.id) }
            )
            idolDescriptor.fetchLimit = requestedIdolIDs.count
            let existingIdolIDs = Set(
                try modelContext.fetch(idolDescriptor).map(\.id)
            )
            guard existingIdolIDs.count == requestedIdolIDs.count else {
                throw ChekinanaChekiRecordMutationError.missingRelationships
            }
        }
        if let eventID {
            var eventDescriptor = FetchDescriptor<Event>(
                predicate: #Predicate { $0.id == eventID }
            )
            eventDescriptor.fetchLimit = 1
            guard try modelContext.fetch(eventDescriptor).first != nil else {
                throw ChekinanaChekiRecordMutationError.missingRelationships
            }
        }
        return (uniqueIdolIDs, eventID)
    }

    private static func record(
        id: UUID,
        in modelContext: ModelContext
    ) throws -> ChekiRecord? {
        var descriptor = FetchDescriptor<ChekiRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Conflict checks must observe the persistent store, but rolling back the
    /// editor's shared main context invalidates every registered object and
    /// forces all visible SwiftData queries to rebuild. A targeted read in an
    /// isolated context preserves the same stale-edit rejection without that
    /// global synchronous reset.
    private static func verifyPersistedSnapshot(
        _ expected: ChekinanaChekiRecordSnapshot?,
        recordID: UUID,
        in modelContext: ModelContext
    ) throws {
        guard let expected else { return }
        let verificationContext = ModelContext(modelContext.container)
        verificationContext.autosaveEnabled = false
        guard let persisted = try record(
            id: recordID,
            in: verificationContext
        ), ChekinanaChekiRecordSnapshot(persisted) == expected else {
            throw ChekinanaChekiRecordMutationError.changedRecord
        }
    }

    /// The exact business identity still gets checked in Swift so legacy
    /// non-canonical dates remain merge-compatible. Restricting the fetch to
    /// the same note and canonical day avoids materializing the whole record
    /// library on every editor save.
    private static func collisionCandidates(
        for identity: ChekinanaChekiRecordIdentity,
        excluding recordID: UUID,
        in modelContext: ModelContext
    ) throws -> [ChekiRecord] {
        let note = identity.note
        if let day = identity.canonicalDate {
            let nextDay = day.addingTimeInterval(86_400)
            let missingDateSentinel = Date.distantPast
            let descriptor = FetchDescriptor<ChekiRecord>(
                predicate: #Predicate {
                    $0.id != recordID
                        && $0.note == note
                        && ($0.date ?? missingDateSentinel) >= day
                        && ($0.date ?? missingDateSentinel) < nextDay
                }
            )
            return try modelContext.fetch(descriptor)
        }
        let descriptor = FetchDescriptor<ChekiRecord>(
            predicate: #Predicate {
                $0.id != recordID
                    && $0.note == note
                    && $0.date == nil
            }
        )
        return try modelContext.fetch(descriptor)
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

    func idols(for media: MediaItem) -> [Idol] {
        media.idolIDs.compactMap { idolsByID[$0] }
    }

    func event(for record: ChekiRecord) -> Event? {
        record.eventID.flatMap { eventsByID[$0] }
    }

    func event(for media: MediaItem) -> Event? {
        media.eventID.flatMap { eventsByID[$0] }
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
            ChekinanaLegacyMediaSchema.Idol.self,
            ChekinanaLegacyMediaSchema.Event.self,
            EventImage.self,
            ChekinanaLegacyMediaSchema.Cheki.self,
            ChekinanaLegacyMediaSchema.Shame.self,
            ChekinanaLegacyMediaSchema.Douga.self,
        ]
    }
}

enum ChekinanaSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ChekinanaLegacyMediaSchema.Idol.self,
            IdolPatternState.self,
            ChekinanaLegacyMediaSchema.Event.self,
            EventImage.self,
            ChekinanaLegacyMediaSchema.Cheki.self,
            ChekinanaLegacyMediaSchema.Shame.self,
            ChekinanaLegacyMediaSchema.Douga.self,
        ]
    }
}

enum ChekinanaSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ChekinanaLegacyMediaSchema.Idol.self,
            IdolPatternState.self,
            ChekinanaLegacyMediaSchema.Event.self,
            EventImage.self,
            ChekinanaLegacyMediaSchema.Cheki.self,
            ChekinanaSchemaV6.ChekiRecord.self,
            ChekinanaLegacyMediaSchema.Shame.self,
            ChekinanaLegacyMediaSchema.Douga.self,
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
            ChekinanaLegacyMediaSchema.Idol.self,
            IdolPatternState.self,
            ChekinanaLegacyMediaSchema.Event.self,
            EventImage.self,
            ChekinanaLegacyMediaSchema.Cheki.self,
            ChekiRecord.self,
            ChekinanaLegacyMediaSchema.Shame.self,
            ChekinanaLegacyMediaSchema.Douga.self,
        ]
    }
}

enum ChekinanaSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ChekinanaLegacyMediaSchema.Idol.self,
            IdolPatternState.self,
            ChekinanaLegacyMediaSchema.Event.self,
            EventSchedule.self,
            EventImage.self,
            ChekinanaLegacyMediaSchema.Cheki.self,
            ChekiRecord.self,
            ChekinanaLegacyMediaSchema.Shame.self,
            ChekinanaLegacyMediaSchema.Douga.self,
        ]
    }
}

enum ChekinanaSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ChekinanaLegacyMediaSchema.Idol.self,
            IdolPatternState.self,
            ChekinanaLegacyMediaSchema.Event.self,
            EventSchedule.self,
            EventImage.self,
            MediaEventLink.self,
            ChekinanaLegacyMediaSchema.Cheki.self,
            ChekiRecord.self,
            ChekinanaLegacyMediaSchema.Shame.self,
            ChekinanaLegacyMediaSchema.Douga.self,
        ]
    }
}

enum ChekinanaSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ChekinanaLegacyMediaSchema.Idol.self,
            IdolPatternState.self,
            ChekinanaLegacyMediaSchema.Event.self,
            EventSchedule.self,
            EventImage.self,
            MediaEventLink.self,
            CalendarGroupOrder.self,
            ChekinanaLegacyMediaSchema.Cheki.self,
            ChekiRecord.self,
            ChekinanaLegacyMediaSchema.Shame.self,
            ChekinanaLegacyMediaSchema.Douga.self,
        ]
    }
}

enum ChekinanaSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ChekinanaLegacyMediaSchema.Idol.self,
            IdolPatternState.self,
            ChekinanaLegacyMediaSchema.Event.self,
            EventSchedule.self,
            EventImage.self,
            MediaEventLink.self,
            CalendarGroupOrder.self,
            TravelSegment.self,
            ChekinanaLegacyMediaSchema.Cheki.self,
            ChekiRecord.self,
            ChekinanaLegacyMediaSchema.Shame.self,
            ChekinanaLegacyMediaSchema.Douga.self,
        ]
    }
}

enum ChekinanaSchemaV12: VersionedSchema {
    static let versionIdentifier = Schema.Version(12, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ChekinanaLegacyMediaSchema.Idol.self,
            IdolPatternState.self,
            ChekinanaLegacyMediaSchema.Event.self,
            EventSchedule.self,
            EventImage.self,
            MediaEventLink.self,
            MediaShotType.self,
            CalendarGroupOrder.self,
            TravelSegment.self,
            ChekinanaLegacyMediaSchema.Cheki.self,
            ChekiRecord.self,
            ChekinanaLegacyMediaSchema.Shame.self,
            ChekinanaLegacyMediaSchema.Douga.self,
        ]
    }
}

/// Additive bridge: legacy media and scalar auxiliary rows remain readable
/// while MediaItem is populated transactionally by the V13 -> V14 stage.
enum ChekinanaSchemaV13: VersionedSchema {
    static let versionIdentifier = Schema.Version(13, 0, 0)
    static var models: [any PersistentModel.Type] {
        ChekinanaSchemaV12.models + [MediaItem.self]
    }
}

/// Frozen Event entity used by the shipped V14/V15 schemas. V16 replaces this
/// carrier with the active Event model, which adds the persisted social source.
enum ChekinanaPreEventSourceSchema {
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
        var createdAt: Date
        var updatedAt: Date

        init(id: UUID = UUID(), name: String) {
            self.id = id
            self.name = name
            date = nil
            city = nil
            livehouse = nil
            legacyVenue = nil
            avatarImageRef = nil
            price = nil
            weiboURL = nil
            ticketURL = nil
            note = ""
            createdAt = Date()
            updatedAt = Date()
        }
    }
}

/// Final active schema. Legacy media entities and their two scalar side tables
/// are intentionally absent; all product media reads and writes use MediaItem.
enum ChekinanaSchemaV14: VersionedSchema {
    static let versionIdentifier = Schema.Version(14, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            ChekinanaPreEventSourceSchema.Event.self,
            EventSchedule.self,
            EventImage.self,
            CalendarGroupOrder.self,
            TravelSegment.self,
            MediaItem.self,
            ChekiRecord.self,
        ]
    }
}

/// Adds the independent Memory domain without changing MediaItem semantics.
enum ChekinanaSchemaV15: VersionedSchema {
    static let versionIdentifier = Schema.Version(15, 0, 0)
    static var models: [any PersistentModel.Type] {
        ChekinanaSchemaV14.models + [Memory.self, MemoryAttachment.self]
    }
}

/// Adds persisted custom Cheki sizes and a source field directly on Event.
enum ChekinanaSchemaV16: VersionedSchema {
    static let versionIdentifier = Schema.Version(16, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Idol.self,
            IdolPatternState.self,
            Event.self,
            EventSchedule.self,
            EventImage.self,
            CalendarGroupOrder.self,
            TravelSegment.self,
            MediaItem.self,
            ChekiRecord.self,
            Memory.self,
            MemoryAttachment.self,
            CustomChekiSize.self,
        ]
    }
}

/// Adds durable avatar provenance and user intent without changing the frozen
/// Idol entity used by the preceding schema versions.
enum ChekinanaSchemaV17: VersionedSchema {
    static let versionIdentifier = Schema.Version(17, 0, 0)
    static var models: [any PersistentModel.Type] {
        ChekinanaSchemaV16.models + [IdolAvatarState.self]
    }
}

enum ChekinanaMigrationIntegrityError: Error, Equatable {
    case duplicateIdolID
    case duplicateCarrierIdolID
    case missingCarrierIdol
    case duplicateMediaID
    case invalidMediaItem
    case mediaCountMismatch
    case convertedRecordCountMismatch
}

/// Mirrors the existing ChekiRecord/MediaItem constructors and V16 repair.
/// Projects newly constructed rows and final witnesses; existing V13 records
/// retain their raw size identity until the original V16 normalization stage.
private enum ChekinanaMigrationChekiSize {
    static func normalizedRawValue(_ value: String?) -> String {
        (value.flatMap(ChekiSize.init(rawValue:)) ?? .mini).rawValue
    }
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
            ChekinanaSchemaV13.self,
            ChekinanaSchemaV14.self,
            ChekinanaSchemaV15.self,
            ChekinanaSchemaV16.self,
            ChekinanaSchemaV17.self,
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
                            FetchDescriptor<ChekinanaLegacyMediaSchema.Cheki>()
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
                        for cheki in try context.fetch(
                            FetchDescriptor<ChekinanaLegacyMediaSchema.Cheki>()
                        )
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
            .lightweight(
                fromVersion: ChekinanaSchemaV12.self,
                toVersion: ChekinanaSchemaV13.self
            ),
            .custom(
                fromVersion: ChekinanaSchemaV13.self,
                toVersion: ChekinanaSchemaV14.self,
                willMigrate: { context in
                    try migrateLegacyMediaToMediaItems(in: context)
                },
                didMigrate: { context in
                    let items = try context.fetch(FetchDescriptor<MediaItem>())
                    guard Set(items.map(\.id)).count == items.count else {
                        throw ChekinanaMigrationIntegrityError.duplicateMediaID
                    }
                    for item in items {
                        do {
                            try item.validateInvariant()
                        } catch {
                            throw ChekinanaMigrationIntegrityError.invalidMediaItem
                        }
                    }
                }
            ),
            .lightweight(
                fromVersion: ChekinanaSchemaV14.self,
                toVersion: ChekinanaSchemaV15.self
            ),
            .custom(
                fromVersion: ChekinanaSchemaV15.self,
                toVersion: ChekinanaSchemaV16.self,
                willMigrate: nil,
                didMigrate: { context in
                    for event in try context.fetch(FetchDescriptor<Event>()) {
                        event.source = ChekinanaEventSource.infer(from: event.weiboURL)
                    }
                    for record in try context.fetch(FetchDescriptor<ChekiRecord>()) {
                        guard let rawValue = record.sizeRawValue,
                              ChekiSize(rawValue: rawValue) != nil else {
                            record.sizeRawValue = ChekiSize.mini.rawValue
                            continue
                        }
                    }
                    try ChekinanaChekiRecordStore.mergeDuplicates(in: context)
                    try context.save()
                }
            ),
            .lightweight(
                fromVersion: ChekinanaSchemaV16.self,
                toVersion: ChekinanaSchemaV17.self
            ),
        ]
    }

    private static func migrateLegacyMediaToMediaItems(
        in context: ModelContext
    ) throws {
        try context.transaction {
            let legacyChekis = try context.fetch(
                FetchDescriptor<ChekinanaLegacyMediaSchema.Cheki>()
            )
            let legacyShames = try context.fetch(
                FetchDescriptor<ChekinanaLegacyMediaSchema.Shame>()
            )
            let legacyDougas = try context.fetch(
                FetchDescriptor<ChekinanaLegacyMediaSchema.Douga>()
            )
            let links = try context.fetch(FetchDescriptor<MediaEventLink>())
            let shotTypes = try context.fetch(FetchDescriptor<MediaShotType>())
            let linksByKey = Dictionary(
                links.map { ($0.id, $0.eventID) },
                uniquingKeysWith: { first, _ in first }
            )
            let shotsByKey = Dictionary(
                shotTypes.map { ($0.id, $0.userAppears) },
                uniquingKeysWith: { first, _ in first }
            )

            for existing in try context.fetch(FetchDescriptor<MediaItem>()) {
                context.delete(existing)
            }

            var occupiedMediaIDs = Set<UUID>()
            let initialRecords = try context.fetch(FetchDescriptor<ChekiRecord>())
                .sorted { $0.id.uuidString < $1.id.uuidString }
            var recordIDs = Set(initialRecords.map(\.id))
            var recordsByIdentity: [ChekinanaChekiRecordIdentity: ChekiRecord] = [:]
            var expectedRecordQuantities: [ChekinanaChekiRecordIdentity: Int] = [:]
            for record in initialRecords {
                let identity = ChekinanaChekiRecordIdentity(record)
                expectedRecordQuantities[identity] = try ChekinanaChekiRecordStore.checkedCountSum(
                    expectedRecordQuantities[identity, default: 0],
                    max(1, record.count)
                )
                if let retained = recordsByIdentity[identity] {
                    retained.count = try ChekinanaChekiRecordStore.checkedCountSum(
                        retained.count,
                        max(1, record.count)
                    )
                    context.delete(record)
                } else {
                    record.date = identity.canonicalDate
                    recordsByIdentity[identity] = record
                }
            }
            var validCounts: [MediaItemKind: Int] = [.cheki: 0, .shame: 0, .douga: 0]

            for cheki in legacyChekis.sorted(by: legacyMediaOrder) {
                guard let mediaRef = cheki.imageRef?.nonEmpty else {
                    let identity = ChekinanaChekiRecordIdentity(
                        idolIDs: uniqueIDs(cheki.idols.map(\.id)),
                        date: cheki.date,
                        eventID: cheki.event?.id,
                        sizeRawValue: ChekinanaMigrationChekiSize.normalizedRawValue(
                            cheki.sizeRawValue
                        ),
                        note: cheki.note
                    )
                    expectedRecordQuantities[identity] = try ChekinanaChekiRecordStore.checkedCountSum(
                        expectedRecordQuantities[identity, default: 0],
                        1
                    )
                    if let retained = recordsByIdentity[identity] {
                        retained.count = try ChekinanaChekiRecordStore.checkedCountSum(
                            max(1, retained.count),
                            1
                        )
                    } else {
                        let recordID = availableID(
                            original: cheki.id,
                            kind: .cheki,
                            occupied: &recordIDs,
                            namespace: "record"
                        )
                        let record = ChekiRecord(
                            id: recordID,
                            idols: [],
                            event: nil,
                            date: identity.canonicalDate,
                            size: cheki.sizeRawValue.flatMap(ChekiSize.init(rawValue:)),
                            note: cheki.note,
                            count: 1
                        )
                        record.idolIDs = identity.idolIDs
                        record.eventID = identity.eventID
                        context.insert(record)
                        recordsByIdentity[identity] = record
                    }
                    continue
                }
                let id = availableID(
                    original: cheki.id,
                    kind: .cheki,
                    occupied: &occupiedMediaIDs
                )
                context.insert(MediaItem(
                    id: id,
                    mediaOwnerID: cheki.id,
                    kind: .cheki,
                    idolIDs: uniqueIDs(cheki.idols.map(\.id)),
                    eventID: cheki.event?.id,
                    date: cheki.date,
                    userAppears: cheki.userAppears ?? false,
                    isFavorite: cheki.isFavorite,
                    hasPostedToSNS: cheki.hasPostedToSNS,
                    note: cheki.note,
                    mediaRef: mediaRef,
                    sizeRawValue: cheki.sizeRawValue,
                    idx: cheki.idx,
                    createdAt: cheki.createdAt,
                    updatedAt: cheki.updatedAt
                ))
                validCounts[.cheki, default: 0] += 1
            }

            for shame in legacyShames.sorted(by: legacyMediaOrder) {
                guard let mediaRef = shame.imageRef?.nonEmpty else { continue }
                let id = availableID(
                    original: shame.id,
                    kind: .shame,
                    occupied: &occupiedMediaIDs
                )
                let key = MediaEventLink.key(mediaID: shame.id, kind: .shame)
                let shotKey = MediaShotType.key(mediaID: shame.id, kind: .shame)
                let timestamp = shame.date ?? Date(timeIntervalSince1970: 0)
                context.insert(MediaItem(
                    id: id,
                    mediaOwnerID: shame.id,
                    kind: .shame,
                    idolIDs: uniqueIDs(shame.idols.map(\.id)),
                    eventID: linksByKey[key],
                    date: shame.date,
                    userAppears: shotsByKey[shotKey] ?? false,
                    isFavorite: false,
                    hasPostedToSNS: false,
                    note: shame.note,
                    mediaRef: mediaRef,
                    sizeRawValue: nil,
                    idx: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp
                ))
                validCounts[.shame, default: 0] += 1
            }

            for douga in legacyDougas.sorted(by: legacyMediaOrder) {
                guard let mediaRef = douga.videoRef?.nonEmpty else { continue }
                let id = availableID(
                    original: douga.id,
                    kind: .douga,
                    occupied: &occupiedMediaIDs
                )
                let key = MediaEventLink.key(mediaID: douga.id, kind: .douga)
                let shotKey = MediaShotType.key(mediaID: douga.id, kind: .douga)
                let timestamp = douga.date ?? Date(timeIntervalSince1970: 0)
                context.insert(MediaItem(
                    id: id,
                    mediaOwnerID: douga.id,
                    kind: .douga,
                    idolIDs: uniqueIDs(douga.idols.map(\.id)),
                    eventID: linksByKey[key],
                    date: douga.date,
                    userAppears: shotsByKey[shotKey] ?? false,
                    isFavorite: false,
                    hasPostedToSNS: false,
                    note: douga.note,
                    mediaRef: mediaRef,
                    sizeRawValue: nil,
                    idx: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp
                ))
                validCounts[.douga, default: 0] += 1
            }

            let migrated = try context.fetch(FetchDescriptor<MediaItem>())
            guard Set(migrated.map(\.id)).count == migrated.count else {
                throw ChekinanaMigrationIntegrityError.duplicateMediaID
            }
            let migratedCounts = Dictionary(grouping: migrated, by: \.kind)
                .mapValues(\.count)
            guard MediaItemKind.allCases.allSatisfy({ kind in
                migratedCounts[kind, default: 0] == validCounts[kind, default: 0]
            }) else {
                throw ChekinanaMigrationIntegrityError.mediaCountMismatch
            }
            let migratedRecords = try context.fetch(FetchDescriptor<ChekiRecord>())
            var migratedRecordQuantities: [ChekinanaChekiRecordIdentity: Int] = [:]
            for record in migratedRecords {
                let identity = ChekinanaChekiRecordIdentity(record)
                migratedRecordQuantities[identity] = try ChekinanaChekiRecordStore.checkedCountSum(
                    migratedRecordQuantities[identity, default: 0],
                    max(1, record.count)
                )
            }
            guard Set(migratedRecords.map(\.id)).count == migratedRecords.count,
                  Set(migratedRecords.map(ChekinanaChekiRecordIdentity.init)).count
                    == migratedRecords.count,
                  migratedRecordQuantities == expectedRecordQuantities else {
                throw ChekinanaMigrationIntegrityError.convertedRecordCountMismatch
            }
            for item in migrated {
                do { try item.validateInvariant() }
                catch { throw ChekinanaMigrationIntegrityError.invalidMediaItem }
            }
            try context.save()
        }
    }

    private static func legacyMediaOrder<T>(
        _ lhs: T,
        _ rhs: T
    ) -> Bool where T: PersistentModel {
        String(describing: lhs.persistentModelID)
            < String(describing: rhs.persistentModelID)
    }

    private static func availableID(
        original: UUID,
        kind: MediaItemKind,
        occupied: inout Set<UUID>,
        namespace: String = "media"
    ) -> UUID {
        if occupied.insert(original).inserted { return original }
        var attempt = 0
        while true {
            let value = deterministicUUID(
                "\(namespace)|\(kind.rawValue)|\(original.uuidString.lowercased())|\(attempt)"
            )
            if occupied.insert(value).inserted { return value }
            attempt += 1
        }
    }

    private static func deterministicUUID(_ value: String) -> UUID {
        func fnv64(seed: UInt64, bytes: some Sequence<UInt8>) -> UInt64 {
            bytes.reduce(seed) { partial, byte in
                (partial ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        let bytes = Array(value.utf8)
        let high = fnv64(seed: 14_695_981_039_346_656_037, bytes: bytes)
        let low = fnv64(seed: 10_995_116_282_11, bytes: bytes.reversed())
        let compact = String(format: "%016llx%016llx", high, low)
        let formatted = "\(compact.prefix(8))-\(compact.dropFirst(8).prefix(4))-4\(compact.dropFirst(13).prefix(3))-a\(compact.dropFirst(17).prefix(3))-\(compact.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted)!
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
            case .missingCheki: ChekinanaL10n.message("The Cheki is no longer available.")
            case .missingChekiRecord: ChekinanaL10n.message("The record is no longer available.")
            case .missingShame: ChekinanaL10n.message("The Phone Photo is no longer available.")
            case .missingDouga: ChekinanaL10n.message("The Video is no longer available.")
            case .hiddenIdol: ChekinanaL10n.message("A hidden Idol cannot be selected or modified.")
            }
        }
    }

    static func idols(
        idolIDs: Set<UUID>,
        preservingExistingIDs: Set<UUID> = [],
        in modelContext: ModelContext
    ) throws -> [Idol] {
        guard !idolIDs.isEmpty else { return [] }
        let requestedIDs = Array(idolIDs)
        var descriptor = FetchDescriptor<Idol>(
            predicate: #Predicate { requestedIDs.contains($0.id) }
        )
        descriptor.fetchLimit = requestedIDs.count
        let resolved = ChekinanaIdolOrdering.ordered(
            try modelContext.fetch(descriptor)
        )
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        let preservedHiddenIDs = preservingExistingIDs.intersection(hiddenIDs)
        guard resolved.count == idolIDs.count,
              preservedHiddenIDs.isEmpty
                || ChekinanaFourPageVisibilityPolicy.includesRecord(
                    idolIDs: preservingExistingIDs, hiddenIDs: hiddenIDs
                ),
              Set(resolved.map(\.id)).intersection(hiddenIDs)
                .isSubset(of: preservedHiddenIDs) else {
            throw ResolutionError.hiddenIdol
        }
        return resolved
    }

    static func relationships(
        idolIDs: Set<UUID>,
        eventID: UUID?,
        preservingExistingIDs: Set<UUID> = [],
        in modelContext: ModelContext
    ) throws -> ChekinanaResolvedMediaRelationships {
        let selectedIdols = try idols(
            idolIDs: idolIDs, preservingExistingIDs: preservingExistingIDs,
            in: modelContext
        )
        let selectedEvent: Event?
        if let eventID {
            var descriptor = FetchDescriptor<Event>(
                predicate: #Predicate { $0.id == eventID }
            )
            descriptor.fetchLimit = 1
            selectedEvent = try modelContext.fetch(descriptor).first
        } else {
            selectedEvent = nil
        }
        return ChekinanaResolvedMediaRelationships(
            idols: selectedIdols,
            event: selectedEvent
        )
    }

    static func mediaItem(
        id: UUID,
        kind: MediaItemKind,
        in modelContext: ModelContext
    ) throws -> MediaItem {
        let kindRawValue = kind.rawValue
        var descriptor = FetchDescriptor<MediaItem>(
            predicate: #Predicate {
                $0.id == id && $0.kindRawValue == kindRawValue
            }
        )
        descriptor.fetchLimit = 1
        guard let value = try modelContext.fetch(descriptor).first else {
            switch kind {
            case .cheki: throw ResolutionError.missingCheki
            case .shame: throw ResolutionError.missingShame
            case .douga: throw ResolutionError.missingDouga
            }
        }
        return value
    }

    static func cheki(id: UUID, in modelContext: ModelContext) throws -> MediaItem {
        try mediaItem(id: id, kind: .cheki, in: modelContext)
    }

    static func shame(id: UUID, in modelContext: ModelContext) throws -> MediaItem {
        try mediaItem(id: id, kind: .shame, in: modelContext)
    }

    static func douga(id: UUID, in modelContext: ModelContext) throws -> MediaItem {
        try mediaItem(id: id, kind: .douga, in: modelContext)
    }

    static func mediaItem(id: UUID, in modelContext: ModelContext) throws -> MediaItem {
        var descriptor = FetchDescriptor<MediaItem>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let value = try modelContext.fetch(descriptor).first else {
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

}

/// Pure values only: no bridge model/context may survive into the next open.
private struct ChekinanaLegacyMediaMigrationWitness: Equatable {
    struct Media: Hashable {
        let ownerID: UUID
        let kind: MediaItemKind
        let idolIDs: [UUID]
        let eventID: UUID?
        let date: Date?
        let userAppears: Bool
        let isFavorite: Bool
        let hasPostedToSNS: Bool
        let note: String
        let mediaRef: String
        let sizeRawValue: String?
        let idx: Int?
        let createdAt: Date
        let updatedAt: Date
    }

    let idolIDs: Set<UUID>
    let eventIDs: Set<UUID>
    let media: Set<Media>
    let recordQuantities: [ChekinanaChekiRecordIdentity: Int]

    private static func ordered(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    private static func recordIdentity(
        idolIDs: [UUID], date: Date?, eventID: UUID?, size: String?, note: String
    ) -> ChekinanaChekiRecordIdentity {
        // This is the existing V16 metadata normalization, which happens
        // before the final container is published by the production opener.
        ChekinanaChekiRecordIdentity(
            idolIDs: idolIDs, date: date, eventID: eventID,
            sizeRawValue: ChekinanaMigrationChekiSize.normalizedRawValue(size),
            note: note
        )
    }

    private static func quantities(
        in context: ModelContext
    ) throws -> [ChekinanaChekiRecordIdentity: Int] {
        var result: [ChekinanaChekiRecordIdentity: Int] = [:]
        for value in try context.fetch(FetchDescriptor<ChekiRecord>()) {
            let identity = recordIdentity(idolIDs: value.idolIDs, date: value.date,
                eventID: value.eventID, size: value.sizeRawValue, note: value.note)
            result[identity] = try ChekinanaChekiRecordStore.checkedCountSum(
                result[identity, default: 0], max(1, value.count)
            )
        }
        return result
    }

    static func legacy(in context: ModelContext) throws -> Self {
        var media = Set<Media>()
        var quantities = try quantities(in: context)
        for value in try context.fetch(FetchDescriptor<ChekinanaLegacyMediaSchema.Cheki>()) {
            let ids = ordered(value.idols.map(\.id))
            guard let ref = value.imageRef?.nonEmpty else {
                let identity = recordIdentity(idolIDs: ids, date: value.date,
                    eventID: value.event?.id, size: value.sizeRawValue, note: value.note)
                quantities[identity] = try ChekinanaChekiRecordStore.checkedCountSum(
                    quantities[identity, default: 0], 1
                )
                continue
            }
            media.insert(Media(ownerID: value.id, kind: .cheki, idolIDs: ids,
                eventID: value.event?.id, date: value.date, userAppears: value.userAppears ?? false,
                isFavorite: value.isFavorite, hasPostedToSNS: value.hasPostedToSNS,
                note: value.note, mediaRef: ref,
                sizeRawValue: ChekinanaMigrationChekiSize.normalizedRawValue(value.sizeRawValue),
                idx: value.idx, createdAt: value.createdAt, updatedAt: value.updatedAt))
        }
        for value in try context.fetch(FetchDescriptor<ChekinanaLegacyMediaSchema.Shame>()) {
            guard let ref = value.imageRef?.nonEmpty else { continue }
            let timestamp = value.date ?? Date(timeIntervalSince1970: 0)
            media.insert(Media(ownerID: value.id, kind: .shame,
                idolIDs: ordered(value.idols.map(\.id)), eventID: nil, date: value.date,
                userAppears: false, isFavorite: false, hasPostedToSNS: false,
                note: value.note, mediaRef: ref, sizeRawValue: nil, idx: nil,
                createdAt: timestamp, updatedAt: timestamp))
        }
        for value in try context.fetch(FetchDescriptor<ChekinanaLegacyMediaSchema.Douga>()) {
            guard let ref = value.videoRef?.nonEmpty else { continue }
            let timestamp = value.date ?? Date(timeIntervalSince1970: 0)
            media.insert(Media(ownerID: value.id, kind: .douga,
                idolIDs: ordered(value.idols.map(\.id)), eventID: nil, date: value.date,
                userAppears: false, isFavorite: false, hasPostedToSNS: false,
                note: value.note, mediaRef: ref, sizeRawValue: nil, idx: nil,
                createdAt: timestamp, updatedAt: timestamp))
        }
        return Self(
            idolIDs: Set(try context.fetch(FetchDescriptor<ChekinanaLegacyMediaSchema.Idol>()).map(\.id)),
            eventIDs: Set(try context.fetch(FetchDescriptor<ChekinanaLegacyMediaSchema.Event>()).map(\.id)),
            media: media, recordQuantities: quantities
        )
    }

    static func current(in context: ModelContext) throws -> Self {
        let values = try context.fetch(FetchDescriptor<MediaItem>())
        let media = Set(values.map { value in
            Media(ownerID: value.mediaOwnerID, kind: value.kind,
                idolIDs: ordered(value.idolIDs), eventID: value.eventID, date: value.date,
                userAppears: value.userAppears, isFavorite: value.isFavorite,
                hasPostedToSNS: value.hasPostedToSNS, note: value.note,
                mediaRef: value.mediaRef, sizeRawValue: value.sizeRawValue, idx: value.idx,
                createdAt: value.createdAt, updatedAt: value.updatedAt)
        })
        guard media.count == values.count else {
            throw ChekinanaMigrationIntegrityError.duplicateMediaID
        }
        return Self(
            idolIDs: Set(try context.fetch(FetchDescriptor<Idol>()).map(\.id)),
            eventIDs: Set(try context.fetch(FetchDescriptor<Event>()).map(\.id)),
            media: media, recordQuantities: try quantities(in: context)
        )
    }
}

enum ChekinanaDataStore {
    private static let currentMarkerSchemaVersion = 17
    private static let preservedV16SourceMarker = ".preserved-v16-source"
    private static let migratableMarkerSchemaVersions: Set<Int> = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
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
        case v13 = 13
        case v14 = 14
        case v15 = 15
        case v16 = 16
        case v17 = 17
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

        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
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
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(
                    configurationName,
                    schema: schema,
                    url: candidateURL,
                    cloudKitDatabase: .none
                )]
            )
            try normalizeV16Metadata(in: container)
            return container
        }
        let result = openPreservingStoreFamily(
            paths: paths,
            inspectStoreVersion: physicalStoreVersion,
            makeAutomaticContainer: automaticContainer,
            makeCompatibleV16Container: { candidateURL in
                try compatibleV16Container(at: candidateURL, configurationName: configurationName)
            },
            makeLegacyMediaContainer: { candidateURL, version in
                try legacyMediaContainer(at: candidateURL, sourceVersion: version,
                    configurationName: configurationName)
            }
        ) { candidateURL in
            let container = try ModelContainer(
                for: schema,
                migrationPlan: ChekinanaSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(
                    configurationName,
                    schema: schema,
                    url: candidateURL,
                    cloudKitDatabase: .none
                )]
            )
            try normalizeV16Metadata(in: container)
            return container
        }
        if case .success(let container) = result {
            processCache.container = container
        }
        return result
    }

    /// Idempotent post-open repair also covers production V14 stores that must
    /// use Core Data's automatic additive migration because their shipped V14
    /// model checksum predates the frozen staged-migration schema.
    static func normalizeV16Metadata(in container: ModelContainer) throws {
        let context = ModelContext(container)
        try context.transaction {
            for event in try context.fetch(FetchDescriptor<Event>())
            where event.source == nil {
                let source = ChekinanaEventSource.infer(from: event.weiboURL)
                if event.sourceRawValue != source?.rawValue {
                    event.source = source
                }
            }
            let records = try context.fetch(FetchDescriptor<ChekiRecord>())
            for record in records
            where record.sizeRawValue.flatMap(ChekiSize.init(rawValue:)) == nil {
                record.sizeRawValue = ChekiSize.mini.rawValue
            }
            try ChekinanaChekiRecordStore.mergeDuplicates(
                in: context, fetchedRecords: records
            )
            if context.hasChanges { try context.save() }
        }
    }

    /// Permit the additive V16 -> V17 upgrade without requiring a checksum
    /// match to the full historical staged plan. Admit this path only when
    /// exact version/entity metadata and stored values survive unchanged.
    static func compatibleV16Container(
        at candidateURL: URL,
        configurationName: String,
        afterMigration: (URL) throws -> Void = { _ in }
    ) throws -> ModelContainer {
        let before = try v16EntityHashes(at: candidateURL, expectedVersion: "16.0.0")
        let valuesBefore = try v16StoredValues(at: candidateURL)
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(configurationName, schema: schema, url: candidateURL,
                cloudKitDatabase: .none)
        ])
        try afterMigration(candidateURL)
        let after = try v16EntityHashes(at: candidateURL, expectedVersion: "17.0.0")
        guard before == after,
              try v16StoredValues(at: candidateURL) == valuesBefore else {
            throw OpenFailure()
        }
        // Existing normalization is intentional business repair, so compare
        // the raw additive result before performing it.
        try validateV16ModelProjection(in: container)
        try normalizeV16Metadata(in: container)
        return container
    }

    /// Ask the current model mapping to compile a projection of every stored
    /// property, even for an empty table. This validates renamed properties
    /// without assuming a physical column spelling from another OS.
    private static func validateV16ModelProjection(in container: ModelContainer) throws {
        func validate<Model: PersistentModel>(
            _ model: Model.Type, _ properties: [PartialKeyPath<Model>]
        ) throws {
            try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                var descriptor = FetchDescriptor<Model>()
                descriptor.fetchLimit = 1
                descriptor.includePendingChanges = false
                descriptor.propertiesToFetch = properties
                _ = try context.fetch(descriptor)
            }
        }
        try validate(Idol.self, [
            \.id, \.sourceId, \.name, \.group, \.color, \.birthday,
            \.avatarImageRef, \.isFavorite, \.sortOrder, \.note,
            \.createdAt, \.updatedAt, \.verification, \.bio, \.pattern, \.patterns,
        ])
        try validate(IdolPatternState.self, [
            \.idolID, \.encoderVersion, \.cataloguePatternIDs, \.cataloguePatternCount,
        ])
        try validate(Event.self, [
            \.id, \.name, \.date, \.city, \.livehouse, \.legacyVenue,
            \.avatarImageRef, \.price, \.weiboURL, \.sourceRawValue,
            \.ticketURL, \.note, \.createdAt, \.updatedAt,
        ])
        try validate(EventSchedule.self, [\.eventID, \.openTime, \.startTime])
        try validate(EventImage.self, [\.id, \.eventID, \.imageRef, \.sortOrder])
        try validate(CalendarGroupOrder.self, [\.id, \.dateKey, \.groupKey, \.sortOrder])
        try validate(TravelSegment.self, [
            \.id, \.modeRawValue, \.operatorName, \.operatorIconRef, \.serviceNumber,
            \.departureCity, \.departureLocation, \.arrivalCity, \.arrivalLocation,
            \.departureTime, \.arrivalTime, \.seatNumber, \.carriageNumber,
            \.note, \.createdAt, \.updatedAt,
        ])
        try validate(MediaItem.self, [
            \.id, \.mediaOwnerID, \.kindRawValue, \.idolIDs, \.eventID, \.date,
            \.userAppears, \.isFavorite, \.hasPostedToSNS, \.note, \.mediaRef,
            \.sizeRawValue, \.idx, \.createdAt, \.updatedAt,
        ])
        try validate(ChekiRecord.self, [
            \.id, \.idolIDs, \.eventID, \.date, \.sizeRawValue, \.note, \.count,
        ])
        try validate(Memory.self, [
            \.id, \.title, \.bodyText, \.date, \.eventID, \.idolIDs,
            \.createdAt, \.updatedAt,
        ])
        try validate(MemoryAttachment.self, [
            \.id, \.memoryID, \.kindRawValue, \.managedRef, \.sortOrder,
            \.createdAt, \.updatedAt,
        ])
        try validate(CustomChekiSize.self, [
            \.id, \.name, \.widthRatio, \.heightRatio,
            \.pixelWidth, \.pixelHeight, \.createdAt,
        ])
    }

    private static let v16Tables: [(entity: String, table: String, key: String)] = [
        ("Idol", "ZIDOL", "ZID"),
        ("IdolPatternState", "ZIDOLPATTERNSTATE", "ZIDOLID"),
        ("Event", "ZEVENT", "ZID"),
        ("EventSchedule", "ZEVENTSCHEDULE", "ZEVENTID"),
        ("EventImage", "ZEVENTIMAGE", "ZID"),
        ("CalendarGroupOrder", "ZCALENDARGROUPORDER", "ZID"),
        ("TravelSegment", "ZTRAVELSEGMENT", "ZID"),
        ("MediaItem", "ZMEDIAITEM", "ZID"),
        ("ChekiRecord", "ZCHEKIRECORD", "ZID"),
        ("Memory", "ZMEMORY", "ZID"),
        ("MemoryAttachment", "ZMEMORYATTACHMENT", "ZID"),
        ("CustomChekiSize", "ZCUSTOMCHEKISIZE", "ZID"),
    ]

    private static func v16EntityHashes(
        at url: URL, expectedVersion: String
    ) throws -> [String: Data] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        let identifiers: [String]
        if let values = metadata[NSStoreModelVersionIdentifiersKey] as? [String] {
            identifiers = values
        } else if let values = metadata[NSStoreModelVersionIdentifiersKey] as? Set<String> {
            identifiers = Array(values)
        } else {
            throw OpenFailure()
        }
        guard identifiers == [expectedVersion],
              let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data] else {
            throw OpenFailure()
        }
        let originalNames = Set(v16Tables.map { $0.entity })
        let expectedNames = expectedVersion == "17.0.0"
            ? originalNames.union(["IdolAvatarState"]) : originalNames
        guard Set(hashes.keys) == expectedNames,
              hashes.values.allSatisfy({ !$0.isEmpty }) else { throw OpenFailure() }
        return hashes.filter { originalNames.contains($0.key) }
    }

    private struct V16StoredValues: Equatable {
        let columns: [String]
        let rows: Int
        let digest: Data
    }

    /// The current V16 entities have scalar keys, not Core Data relationships.
    /// Stream one row at a time; do not fetch all models or copy large blobs.
    private static func v16StoredValues(at url: URL) throws -> [String: V16StoredValues] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw OpenFailure()
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw OpenFailure()
        }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard result == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                throw OpenFailure()
            }
            return statement
        }
        var result: [String: V16StoredValues] = [:]
        for item in v16Tables {
            let names = try prepare("PRAGMA table_info(\"\(item.table)\")")
            var columns: [String] = []
            var code = sqlite3_step(names)
            while code == SQLITE_ROW {
                guard let value = sqlite3_column_text(names, 1) else {
                    sqlite3_finalize(names)
                    throw OpenFailure()
                }
                let name = String(cString: value)
                guard name.utf8.allSatisfy({
                    ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 95
                }) else {
                    sqlite3_finalize(names)
                    throw OpenFailure()
                }
                if !["Z_PK", "Z_ENT", "Z_OPT"].contains(name) { columns.append(name) }
                code = sqlite3_step(names)
            }
            sqlite3_finalize(names)
            guard code == SQLITE_DONE, columns.contains(item.key) else { throw OpenFailure() }
            columns.sort()
            let projection = columns.map { "\"\($0)\"" }.joined(separator: ",")
            let statement = try prepare(
                "SELECT \(projection) FROM \"\(item.table)\" ORDER BY \"\(item.key)\""
            )
            defer { sqlite3_finalize(statement) }
            var hash = SHA256()
            func append(_ value: UInt64) {
                var bits = value.littleEndian
                withUnsafeBytes(of: &bits) { hash.update(data: Data($0)) }
            }
            var rows = 0
            code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                let next = rows.addingReportingOverflow(1)
                guard !next.overflow else { throw OpenFailure() }
                rows = next.partialValue
                for column in columns.indices {
                    let index = Int32(column)
                    let type = sqlite3_column_type(statement, index)
                    append(UInt64(type))
                    switch type {
                    case SQLITE_NULL:
                        break
                    case SQLITE_INTEGER:
                        append(UInt64(bitPattern: sqlite3_column_int64(statement, index)))
                    case SQLITE_FLOAT:
                        append(sqlite3_column_double(statement, index).bitPattern)
                    case SQLITE_TEXT, SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        append(UInt64(count))
                        if count > 0 {
                            guard let bytes = sqlite3_column_blob(statement, index) else {
                                throw OpenFailure()
                            }
                            // SQLite owns this memory until the next step.
                            // Feed bounded slices synchronously to the hasher.
                            var offset = 0
                            while offset < count {
                                let size = min(65_536, count - offset)
                                hash.update(data: Data(bytes: bytes.advanced(by: offset), count: size))
                                offset += size
                            }
                        }
                    default:
                        throw OpenFailure()
                    }
                }
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw OpenFailure() }
            result[item.entity] = V16StoredValues(
                columns: columns, rows: rows, digest: Data(hash.finalize())
            )
        }
        return result
    }

    /// V7/V8 need automatic additive repair on older runtimes, but that repair
    /// must end at V13 while every legacy media entity is still present.
    static func legacyMediaContainer(
        at candidateURL: URL,
        sourceVersion: PhysicalStoreVersion,
        configurationName: String,
        afterBridge: () throws -> Void = {}
    ) throws -> ModelContainer {
        let sourceSchema: Schema
        switch sourceVersion {
        case .v7: sourceSchema = Schema(versionedSchema: ChekinanaSchemaV7.self)
        case .v8: sourceSchema = Schema(versionedSchema: ChekinanaSchemaV8.self)
        default: throw OpenFailure()
        }
        func configuration(_ schema: Schema) -> ModelConfiguration {
            ModelConfiguration(configurationName, schema: schema, url: candidateURL,
                cloudKitDatabase: .none)
        }
        let expected = try autoreleasepool {
            let source = try ModelContainer(for: sourceSchema,
                configurations: [configuration(sourceSchema)])
            let context = ModelContext(source)
            context.autosaveEnabled = false
            return try ChekinanaLegacyMediaMigrationWitness.legacy(in: context)
        }
        try autoreleasepool {
            let bridgeSchema = Schema(versionedSchema: ChekinanaSchemaV13.self)
            let bridge = try ModelContainer(for: bridgeSchema,
                configurations: [configuration(bridgeSchema)])
            let context = ModelContext(bridge)
            context.autosaveEnabled = false
            guard try ChekinanaLegacyMediaMigrationWitness.legacy(in: context) == expected else {
                throw ChekinanaMigrationIntegrityError.mediaCountMismatch
            }
        }
        // Both earlier autorelease pools return pure values/void. No source
        // or bridge model, context, or container is retained into this open.
        try afterBridge()
        let schema = Schema(versionedSchema: ChekinanaSchemaV17.self)
        let container = try ModelContainer(for: schema,
            migrationPlan: ChekinanaSchemaMigrationPlan.self,
            configurations: [configuration(schema)])
        try normalizeV16Metadata(in: container)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard try ChekinanaLegacyMediaMigrationWitness.current(in: context) == expected else {
            throw ChekinanaMigrationIntegrityError.mediaCountMismatch
        }
        return container
    }

    static func openPreservingStoreFamily(
        paths: StorePaths,
        fileManager: FileManager = .default,
        copyStore: ((URL, URL, FileManager) throws -> Void)? = nil,
        inspectStoreVersion: ((URL) throws -> PhysicalStoreVersion?)? = nil,
        makeAutomaticContainer: ((URL) throws -> ModelContainer)? = nil,
        makeCompatibleV16Container: ((URL) throws -> ModelContainer)? = nil,
        makeLegacyMediaContainer: ((URL, PhysicalStoreVersion) throws -> ModelContainer)? = nil,
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
               physicalStoreVersion == nil
                    || physicalStoreVersion?.rawValue == currentMarkerSchemaVersion {
                // A versioned marker is published only after this current
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

            // V7/V8 use their dedicated additive bridge plus explicit media
            // conversion. V14 was published before its model
            // checksum was frozen. Some
            // production stores therefore identify themselves as 14.x while
            // their entity hashes do not match the V14 snapshot embedded in
            // the staged plan. Handing those stores to staged migration fails
            // with NSCocoaErrorDomain 134504 (unknown model version). V14 ->
            // V15 is purely additive, so migrate the isolated candidate with
            // Core Data's inferred lightweight mapping instead. The
            // authoritative source and marker remain untouched until this
            // open succeeds.
            let container: ModelContainer
            if let physicalStoreVersion,
               [PhysicalStoreVersion.v7, .v8].contains(physicalStoreVersion),
               let makeLegacyMediaContainer {
                container = try makeLegacyMediaContainer(candidateURL, physicalStoreVersion)
            } else if physicalStoreVersion == .v16,
               let makeCompatibleV16Container {
                container = try makeCompatibleV16Container(candidateURL)
            } else if physicalStoreVersion == .v14,
               let makeAutomaticContainer {
                container = try makeAutomaticContainer(candidateURL)
            } else {
                container = try makeContainer(candidateURL)
            }
            if physicalStoreVersion == .v16, let sourceDirectory {
                // Only a verified successful V16 candidate earns a durable
                // source-retention flag. Failed candidates are still bounded.
                try Data("16".utf8).write(
                    to: sourceDirectory.appendingPathComponent(preservedV16SourceMarker),
                    options: .atomic
                )
            }
            try markerData(directoryName: candidateName).write(
                to: paths.activeMarkerURL,
                options: .atomic
            )

            // Once the marker atomically points at the successfully opened
            // candidate, an older managed candidate is no longer authoritative.
            // The original legacy store is never removed. Keep the historical
            // V14 managed candidate as well because it is the only byte-exact
            // rollback source for an installation whose reused V14 identifier
            // does not describe its entity hashes.
            if physicalStoreVersion != .v14, physicalStoreVersion != .v16,
               let sourceURL,
               sourceURL.deletingLastPathComponent().deletingLastPathComponent()
                    .standardizedFileURL == paths.candidateRootURL.standardizedFileURL {
                try? fileManager.removeItem(at: sourceURL.deletingLastPathComponent())
            }
            let successfullyPreservedDirectories = [
                newCandidateDirectory,
                (physicalStoreVersion == .v14 || physicalStoreVersion == .v16)
                    ? sourceDirectory : nil,
            ].compactMap { $0 }
            cleanupManagedCandidates(
                in: paths.candidateRootURL,
                preserving: successfullyPreservedDirectories,
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
            guard !fileManager.fileExists(atPath: standardized
                .appendingPathComponent(preservedV16SourceMarker).path) else { return nil }
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
                for item in try context.fetch(FetchDescriptor<MediaItem>()) {
                    context.delete(item)
                }
                for record in try context.fetch(FetchDescriptor<ChekiRecord>()) {
                    context.delete(record)
                }
                for attachment in try context.fetch(FetchDescriptor<MemoryAttachment>()) {
                    context.delete(attachment)
                }
                for memory in try context.fetch(FetchDescriptor<Memory>()) {
                    context.delete(memory)
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
                for size in try context.fetch(FetchDescriptor<CustomChekiSize>()) {
                    context.delete(size)
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

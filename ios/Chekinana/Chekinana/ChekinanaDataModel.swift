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

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: calendarText) else {
            return false
        }
        return formatter.string(from: date) == calendarText
    }
}

enum ChekinanaChekiDateAnnotationState: Equatable, Sendable {
    case notRequested
    case detected(ChekinanaChekiDateAnnotation)
    case notDetected
    case unavailable
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
    var note: String
    @Relationship(deleteRule: .nullify, inverse: \Cheki.idols) var chekis: [Cheki]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sourceId: String? = nil,
        name: String,
        group: String? = nil,
        color: String? = nil,
        birthday: String? = nil,
        avatarImageRef: String? = nil,
        note: String = "",
        chekis: [Cheki] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceId = sourceId
        self.name = name
        self.group = group
        self.color = color
        self.birthday = birthday
        self.avatarImageRef = avatarImageRef
        self.note = note
        self.chekis = chekis
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Event {
    @Attribute(.unique) var id: UUID
    var name: String
    var date: Date?
    var city: String?
    var livehouse: String?
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
        self.weiboURL = weiboURL
        self.ticketURL = ticketURL
        self.note = note
        self.chekis = chekis
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Cheki {
    @Attribute(.unique) var id: UUID
    var idols: [Idol]
    var event: Event?
    // Calendar-day fallback for Cheki that are not attached to an Event.
    // Historical records intentionally migrate with nil here.
    var eventDate: Date?
    var idx: Int?
    // nil: unknown, false: user is not in frame, true: user appears in frame.
    var userAppears: Bool?
    var sizeRawValue: String?
    var imageRef: String?
    var handwrittenDateText: String?
    var handwrittenDateBboxX1: Int?
    var handwrittenDateBboxY1: Int?
    var handwrittenDateBboxX2: Int?
    var handwrittenDateBboxY2: Int?
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

    var handwrittenDateAnnotation: ChekinanaChekiDateAnnotation? {
        guard let text = handwrittenDateText,
              let x1 = handwrittenDateBboxX1,
              let y1 = handwrittenDateBboxY1,
              let x2 = handwrittenDateBboxX2,
              let y2 = handwrittenDateBboxY2,
              let boundingBox = ChekinanaChekiDateBoundingBox(
                x1: x1,
                y1: y1,
                x2: x2,
                y2: y2
              ) else {
            return nil
        }
        let precision: ChekinanaChekiDateAnnotation.Precision =
            text.count == 10 ? .fullDate : .monthDay
        return ChekinanaChekiDateAnnotation(
            text: text,
            precision: precision,
            boundingBox: boundingBox
        )
    }

    init(
        id: UUID = UUID(),
        idols: [Idol] = [],
        event: Event? = nil,
        eventDate: Date? = nil,
        idx: Int? = nil,
        userAppears: Bool? = nil,
        size: ChekiSize? = nil,
        imageRef: String? = nil,
        handwrittenDateAnnotation: ChekinanaChekiDateAnnotation? = nil,
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.idols = idols
        self.event = event
        self.eventDate = eventDate
        self.idx = idx
        self.userAppears = userAppears
        self.sizeRawValue = size?.rawValue
        self.imageRef = imageRef
        self.handwrittenDateText = handwrittenDateAnnotation?.text
        self.handwrittenDateBboxX1 = handwrittenDateAnnotation?.boundingBox.x1
        self.handwrittenDateBboxY1 = handwrittenDateAnnotation?.boundingBox.y1
        self.handwrittenDateBboxX2 = handwrittenDateAnnotation?.boundingBox.x2
        self.handwrittenDateBboxY2 = handwrittenDateAnnotation?.boundingBox.y2
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum ChekinanaDataStore {
    static let shared: ModelContainer = {
        let schema = Schema([
            Idol.self,
            Event.self,
            Cheki.self,
        ])
        let configuration: ModelConfiguration
#if DEBUG
        if ProcessInfo.processInfo.environment["CHEKINANA_UI_TEST_STORE"] == "1" {
            let storeURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ChekinanaUITests.store")
            configuration = ModelConfiguration(
                "ChekinanaUITests",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }
#else
        configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
#endif

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create Chekinana SwiftData container: \(error)")
        }
    }()

#if DEBUG
    static func resetForUITestingIfRequested() {
        guard ProcessInfo.processInfo.environment["CHEKINANA_UI_RESET_STORE"] == "1" else {
            return
        }

        let context = ModelContext(shared)
        do {
            for cheki in try context.fetch(FetchDescriptor<Cheki>()) {
                context.delete(cheki)
            }
            try context.save()
            for event in try context.fetch(FetchDescriptor<Event>()) {
                context.delete(event)
            }
            for idol in try context.fetch(FetchDescriptor<Idol>()) {
                context.delete(idol)
            }
            try context.save()
        } catch {
            fatalError("Failed to reset Chekinana UI test store: \(error)")
        }
    }
#endif
}

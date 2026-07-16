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
        eventDate: Date? = nil,
        idx: Int? = nil,
        userAppears: Bool? = nil,
        size: ChekiSize? = nil,
        imageRef: String? = nil,
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

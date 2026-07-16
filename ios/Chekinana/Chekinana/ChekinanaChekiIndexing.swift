import Foundation

struct ChekinanaChekiGroupKey: Equatable {
    enum Occasion: Equatable {
        case event(UUID)
        case date(String)
    }

    let idolIDs: Set<UUID>
    let occasion: Occasion

    init?(idolIDs: [UUID], eventID: UUID?, eventDate: Date?) {
        guard !idolIDs.isEmpty, (eventID != nil) != (eventDate != nil) else { return nil }
        self.idolIDs = Set(idolIDs)
        if let eventID {
            occasion = .event(eventID)
        } else if let eventDate {
            occasion = .date(Self.normalizedDate(eventDate))
        } else {
            return nil
        }
    }

    private static func normalizedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct ChekinanaChekiIndexSnapshot {
    let chekiID: UUID
    let group: ChekinanaChekiGroupKey
    let idx: Int?
}

enum ChekinanaChekiIndexingError: Error {
    case overflow
}

enum ChekinanaChekiIndexing {
    static func nextIndex(
        for group: ChekinanaChekiGroupKey,
        existing: [ChekinanaChekiIndexSnapshot],
        excludingChekiID: UUID?
    ) throws -> Int {
        let currentMaximum = existing.lazy
            .filter { $0.chekiID != excludingChekiID && $0.group == group }
            .compactMap(\.idx)
            .max() ?? 0
        guard currentMaximum < Int.max else { throw ChekinanaChekiIndexingError.overflow }
        return max(0, currentMaximum) + 1
    }
}

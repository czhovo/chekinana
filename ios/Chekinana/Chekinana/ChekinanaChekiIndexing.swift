import Foundation
import SwiftData

struct ChekinanaChekiGroupKey: Hashable, Sendable {
    let idolIDs: Set<UUID>
    let date: String

    init?(idolIDs: [UUID], date: Date?) {
        let uniqueIdolIDs = Set(idolIDs)
        guard let date, !uniqueIdolIDs.isEmpty else { return nil }
        self.idolIDs = uniqueIdolIDs
        self.date = Self.normalizedDate(date)
    }

    private static func normalizedDate(_ date: Date) -> String {
        ChekinanaDateOnly.string(date)
    }
}

struct ChekinanaChekiIndexSnapshot: Sendable {
    let chekiID: UUID
    let group: ChekinanaChekiGroupKey
    let idx: Int?
}

enum ChekinanaChekiIndexingError: Error, Equatable {
    case overflow
    case collision
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

    static func batchIndices(
        for group: ChekinanaChekiGroupKey,
        quantity: Int,
        manualStart: Int?,
        existing: [ChekinanaChekiIndexSnapshot]
    ) throws -> [Int] {
        guard quantity > 0 else { return [] }
        let occupied = Set(existing.lazy.filter { $0.group == group }.compactMap(\.idx))
        let start: Int
        if let manualStart {
            guard manualStart > 0 else { throw ChekinanaChekiIndexingError.overflow }
            start = manualStart
        } else {
            let currentMaximum = max(0, occupied.max() ?? 0)
            guard currentMaximum < Int.max else {
                throw ChekinanaChekiIndexingError.overflow
            }
            start = currentMaximum + 1
        }
        guard quantity - 1 <= Int.max - start else {
            throw ChekinanaChekiIndexingError.overflow
        }
        let indices = (0..<quantity).map { start + $0 }
        if manualStart != nil,
           !occupied.isDisjoint(with: Set(indices)) {
            throw ChekinanaChekiIndexingError.collision
        }
        return indices
    }

    static func snapshots(
        forCanonicalDate canonicalDate: Date,
        in modelContext: ModelContext
    ) throws -> [ChekinanaChekiIndexSnapshot] {
        let rangeStart = canonicalDate
        let rangeEnd = canonicalDate.addingTimeInterval(24 * 60 * 60)
        let descriptor = FetchDescriptor<Cheki>(predicate: #Predicate { cheki in
            if let storedDate = cheki.date {
                storedDate >= rangeStart && storedDate < rangeEnd
            } else {
                false
            }
        })
        let canonicalKey = ChekinanaDateOnly.string(canonicalDate)
        return try modelContext.fetch(descriptor).compactMap { cheki in
            guard let date = cheki.date,
                  ChekinanaDateOnly.string(date) == canonicalKey,
                  let group = ChekinanaChekiGroupKey(
                      idolIDs: cheki.idols.map(\.id),
                      date: date
                  ) else {
                return nil
            }
            return ChekinanaChekiIndexSnapshot(
                chekiID: cheki.id,
                group: group,
                idx: cheki.idx
            )
        }
    }
}

@ModelActor
actor ChekinanaChekiIndexSnapshotActor {
    func snapshots(
        forCanonicalDate canonicalDate: Date
    ) throws -> [ChekinanaChekiIndexSnapshot] {
        try ChekinanaChekiIndexing.snapshots(
            forCanonicalDate: canonicalDate,
            in: modelContext
        )
    }
}

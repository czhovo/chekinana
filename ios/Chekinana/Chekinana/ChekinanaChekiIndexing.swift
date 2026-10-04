import Foundation
import SwiftData

/// The complete unordered Idol set and canonical optional calendar day are the
/// identity. `nil` is a real, independent date;
/// Event, favorite and solo/2shot state never change the group.
struct ChekinanaChekiGroupKey: Hashable, Sendable {
    let idolIDs: Set<UUID>
    let date: String?

    init?(idolIDs: [UUID], date: Date?) {
        self.idolIDs = Set(idolIDs)
        self.date = date.map(ChekinanaDateOnly.string)
    }
}

struct ChekinanaChekiIndexSnapshot: Sendable {
    let chekiID: UUID
    let group: ChekinanaChekiGroupKey
    let idx: Int?
    let isFavorite: Bool
    let createdAt: Date

    init(
        chekiID: UUID,
        group: ChekinanaChekiGroupKey,
        idx: Int?,
        isFavorite: Bool = false,
        createdAt: Date = .distantPast
    ) {
        self.chekiID = chekiID
        self.group = group
        self.idx = idx
        self.isFavorite = isFavorite
        self.createdAt = createdAt
    }
}

enum ChekinanaChekiIndexingError: Error, Equatable {
    case overflow
    case collision
}

enum ChekinanaChekiIndexing {
    static func isValid(_ idx: Int?, isFavorite: Bool) -> Bool {
        guard let idx else { return false }
        return idx > 0
    }

    static func normalizedExplicitIndex(
        _ idx: Int?,
        isFavorite: Bool
    ) throws -> Int? {
        guard let idx else { return nil }
        guard idx > 0 else {
            throw ChekinanaChekiIndexingError.overflow
        }
        return idx
    }

    static func reassignedIndex(
        currentIndex: Int?,
        previousGroup: ChekinanaChekiGroupKey?,
        targetGroup: ChekinanaChekiGroupKey?,
        previousFavorite: Bool = false,
        targetFavorite: Bool = false,
        chekiID: UUID,
        existing: [ChekinanaChekiIndexSnapshot]
    ) throws -> Int? {
        guard let targetGroup else { throw ChekinanaChekiIndexingError.overflow }
        if previousGroup == targetGroup,
           isValid(currentIndex, isFavorite: targetFavorite),
           existing.lazy.filter({ $0.chekiID != chekiID && $0.group == targetGroup })
            .allSatisfy({ $0.idx != currentIndex }) {
            return currentIndex
        }
        return try nextIndex(
            for: targetGroup,
            isFavorite: targetFavorite,
            existing: existing,
            excludingChekiID: chekiID
        )
    }

    static func nextIndex(
        for group: ChekinanaChekiGroupKey,
        isFavorite: Bool = false,
        existing: [ChekinanaChekiIndexSnapshot],
        excludingChekiID: UUID?
    ) throws -> Int {
        let occupied = existing.lazy
            .filter { $0.chekiID != excludingChekiID && $0.group == group }
            .compactMap(\.idx)
            .filter { $0 > 0 }
        let currentMaximum = occupied.max() ?? 0
        guard currentMaximum < Int.max else { throw ChekinanaChekiIndexingError.overflow }
        return currentMaximum + 1
    }

    static func batchIndices(
        for group: ChekinanaChekiGroupKey,
        quantity: Int,
        manualStart: Int?,
        isFavorite: Bool = false,
        existing: [ChekinanaChekiIndexSnapshot]
    ) throws -> [Int] {
        guard quantity > 0 else { return [] }
        let occupied = Set(existing.lazy.filter { $0.group == group }.compactMap(\.idx))
        if let manualStart {
            guard isValid(manualStart, isFavorite: isFavorite) else {
                throw ChekinanaChekiIndexingError.overflow
            }
            guard quantity - 1 <= Int.max - manualStart else { throw ChekinanaChekiIndexingError.overflow }
            let indices = (0..<quantity).map { manualStart + $0 }
            guard occupied.isDisjoint(with: Set(indices)) else {
                throw ChekinanaChekiIndexingError.collision
            }
            return indices
        }

        var planned: [Int] = []
        var snapshots = existing
        for offset in 0..<quantity {
            let id = UUID()
            let idx = try nextIndex(
                for: group,
                isFavorite: isFavorite,
                existing: snapshots,
                excludingChekiID: nil
            )
            planned.append(idx)
            snapshots.append(.init(
                chekiID: id,
                group: group,
                idx: idx,
                isFavorite: isFavorite,
                createdAt: Date(timeIntervalSinceReferenceDate: Double(offset))
            ))
        }
        return planned
    }

    /// Returns only values that must change. A fully valid group is untouched,
    /// including any gaps. Invalid or duplicate values append after the current
    /// maximum without changing other valid indices.
    static func repairAssignments(
        for snapshots: [ChekinanaChekiIndexSnapshot]
    ) throws -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for groupValues in Dictionary(grouping: snapshots, by: \.group).values {
            guard !hasValidIndices(groupValues) else { continue }

            var used = Set<Int>()
            var next = groupValues.compactMap(\.idx).filter { $0 > 0 }.max() ?? 0
            for value in groupValues.sorted(by: addedPrecedes) {
                if let idx = value.idx, idx > 0, used.insert(idx).inserted { continue }
                guard next < Int.max else { throw ChekinanaChekiIndexingError.overflow }
                next += 1
                used.insert(next)
                result[value.chekiID] = next
            }
        }
        return result
    }

    /// Snapshots already contain the merged Idol IDs. Existing target indices
    /// take precedence; unrelated groups and usable gaps remain unchanged.
    static func assignmentsForMergedGroups(
        _ snapshots: [ChekinanaChekiIndexSnapshot],
        movingChekiIDs: Set<UUID>
    ) throws -> [UUID: Int] {
        let affectedGroups = Set(snapshots.filter {
            movingChekiIDs.contains($0.chekiID)
        }.map(\.group))
        var result: [UUID: Int] = [:]
        for (group, values) in Dictionary(grouping: snapshots, by: \.group)
        where affectedGroups.contains(group) {
            let targets = values.filter { !movingChekiIDs.contains($0.chekiID) }
            let targetRepairs = try repairAssignments(for: targets)
            var reserved = targets.map { value in
                ChekinanaChekiIndexSnapshot(
                    chekiID: value.chekiID, group: group,
                    idx: targetRepairs[value.chekiID] ?? value.idx,
                    isFavorite: value.isFavorite, createdAt: value.createdAt
                )
            }
            result.merge(targetRepairs) { _, repaired in repaired }
            let pending = values.filter { movingChekiIDs.contains($0.chekiID) }.sorted(by: addedPrecedes)
            // Joining another base group always appends; existing target indices stay fixed.
            for value in pending {
                let idx = try nextIndex(
                    for: group, isFavorite: value.isFavorite,
                    existing: reserved, excludingChekiID: nil
                )
                result[value.chekiID] = idx
                reserved.append(.init(
                    chekiID: value.chekiID, group: group, idx: idx,
                    isFavorite: value.isFavorite, createdAt: value.createdAt
                ))
            }
        }
        return result
    }

    private static func hasValidIndices(_ groupValues: [ChekinanaChekiIndexSnapshot]) -> Bool {
        let indices = groupValues.compactMap(\.idx)
        return indices.count == groupValues.count
            && Set(indices).count == indices.count
            && groupValues.allSatisfy { isValid($0.idx, isFavorite: $0.isFavorite) }
    }

    @discardableResult
    static func repairPersistedMediaItems(in modelContext: ModelContext) throws -> Int {
        let photoKind = MediaItemKind.shame.rawValue
        let videoKind = MediaItemKind.douga.rawValue
        let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate {
            ($0.kindRawValue != photoKind && $0.kindRawValue != videoKind) || $0.idx != nil
        })
        let items = try modelContext.fetch(descriptor)
        let assignments = try repairAssignments(for: snapshots(items))
        var changed = 0
        for item in items {
            guard let idx = assignments[item.id], item.idx != idx else { continue }
            item.idx = idx
            changed += 1
        }
        for item in items where item.kind != .cheki && item.idx != nil {
            item.idx = nil
            changed += 1
        }
        return changed
    }

    static func snapshots(_ items: [MediaItem]) -> [ChekinanaChekiIndexSnapshot] {
        items.compactMap { item in
            guard item.kind == .cheki, let group = ChekinanaChekiGroupKey(idolIDs: item.idolIDs, date: item.date) else { return nil }
            return .init(chekiID: item.id, group: group, idx: item.idx, isFavorite: item.isFavorite, createdAt: item.createdAt)
        }
    }

    static func snapshots(in modelContext: ModelContext) throws -> [ChekinanaChekiIndexSnapshot] {
        snapshots(try modelContext.fetch(FetchDescriptor<MediaItem>()))
    }

    /// Explicit one-off migration plan only. The caller controls the database
    /// transaction; normal startup never renumbers already valid records.
    static func initializationAssignments(_ values: [ChekinanaChekiIndexSnapshot]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for group in Dictionary(grouping: values, by: \.group).values {
            for (offset, value) in group.sorted(by: addedPrecedes).enumerated() { result[value.chekiID] = offset + 1 }
        }
        return result
    }

    private static func addedPrecedes(_ lhs: ChekinanaChekiIndexSnapshot, _ rhs: ChekinanaChekiIndexSnapshot) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.chekiID.uuidString < rhs.chekiID.uuidString
    }

    static func snapshots(
        forCanonicalDate canonicalDate: Date,
        in modelContext: ModelContext
    ) throws -> [ChekinanaChekiIndexSnapshot] {
        let canonicalKey = ChekinanaDateOnly.string(canonicalDate)
        return try snapshots(in: modelContext).filter {
            $0.group.date == canonicalKey
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

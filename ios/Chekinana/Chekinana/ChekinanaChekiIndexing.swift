import Foundation
import SwiftData

/// The complete unordered Idol set and canonical optional calendar day are the
/// sole identity of a Cheki index group. `nil` is a real, independent date;
/// Event and favorite state never change the group.
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
        guard let idx, idx != 0 else { return false }
        return isFavorite ? idx < 0 : idx > 0
    }

    static func normalizedExplicitIndex(
        _ idx: Int?,
        isFavorite: Bool
    ) throws -> Int? {
        guard let idx else { return nil }
        guard idx != 0, idx != Int.min else {
            throw ChekinanaChekiIndexingError.overflow
        }
        let magnitude = abs(idx)
        return isFavorite ? -magnitude : magnitude
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
           previousFavorite == targetFavorite,
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
            .filter { isFavorite ? $0 < 0 : $0 > 0 }
        if isFavorite {
            let currentMinimum = occupied.min() ?? 0
            guard currentMinimum > Int.min else { throw ChekinanaChekiIndexingError.overflow }
            return currentMinimum - 1
        }
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
            let indices: [Int]
            if isFavorite {
                guard quantity - 1 <= manualStart - Int.min else {
                    throw ChekinanaChekiIndexingError.overflow
                }
                indices = (0..<quantity).map { manualStart - $0 }
            } else {
                guard quantity - 1 <= Int.max - manualStart else {
                    throw ChekinanaChekiIndexingError.overflow
                }
                indices = (0..<quantity).map { manualStart + $0 }
            }
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
    /// including any gaps. Invalid partitions keep usable numeric anchors when
    /// enough space exists while restoring deterministic legacy display order.
    static func repairAssignments(
        for snapshots: [ChekinanaChekiIndexSnapshot]
    ) throws -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for groupValues in Dictionary(grouping: snapshots, by: \.group).values {
            let indices = groupValues.compactMap(\.idx)
            let valid = indices.count == groupValues.count
                && Set(indices).count == indices.count
                && groupValues.allSatisfy { isValid($0.idx, isFavorite: $0.isFavorite) }
            guard !valid else { continue }

            let legacyOrdered = groupValues.sorted(by: legacyPrecedes)
            try repairPartition(
                legacyOrdered.filter(\.isFavorite),
                isFavorite: true,
                into: &result
            )
            try repairPartition(
                legacyOrdered.filter { !$0.isFavorite },
                isFavorite: false,
                into: &result
            )
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
            var occupied = Set(reserved.compactMap(\.idx))
            var pending: [ChekinanaChekiIndexSnapshot] = []
            for value in values.filter({ movingChekiIDs.contains($0.chekiID) })
                .sorted(by: legacyPrecedes) {
                if let idx = value.idx,
                   isValid(idx, isFavorite: value.isFavorite),
                   occupied.insert(idx).inserted {
                    reserved.append(value)
                } else {
                    pending.append(value)
                }
            }
            // Reserve all valid incoming anchors before allocating conflicts.
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

    @discardableResult
    static func repairPersistedMediaItems(in modelContext: ModelContext) throws -> Int {
        let mediaItems = try modelContext.fetch(FetchDescriptor<MediaItem>())
        let chekis = mediaItems.filter { $0.kind == .cheki }
        let assignments = try repairAssignments(for: chekis.compactMap { cheki in
            guard let group = ChekinanaChekiGroupKey(
                idolIDs: cheki.idolIDs,
                date: cheki.date
            ) else { return nil }
            return ChekinanaChekiIndexSnapshot(
                chekiID: cheki.id,
                group: group,
                idx: cheki.idx,
                isFavorite: cheki.isFavorite,
                createdAt: cheki.createdAt
            )
        })
        var changed = 0
        for cheki in chekis {
            guard let idx = assignments[cheki.id], cheki.idx != idx else { continue }
            cheki.idx = idx
            changed += 1
        }
        for item in mediaItems where item.kind != .cheki && item.idx != nil {
            item.idx = nil
            changed += 1
        }
        return changed
    }

    static func snapshots(in modelContext: ModelContext) throws -> [ChekinanaChekiIndexSnapshot] {
        try modelContext.fetch(FetchDescriptor<MediaItem>()).compactMap { cheki in
            guard cheki.kind == .cheki,
                  let group = ChekinanaChekiGroupKey(
                    idolIDs: cheki.idolIDs,
                    date: cheki.date
                  ) else { return nil }
            return .init(
                chekiID: cheki.id,
                group: group,
                idx: cheki.idx,
                isFavorite: cheki.isFavorite,
                createdAt: cheki.createdAt
            )
        }
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

    private static func legacyPrecedes(
        _ lhs: ChekinanaChekiIndexSnapshot,
        _ rhs: ChekinanaChekiIndexSnapshot
    ) -> Bool {
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        if lhs.idx != rhs.idx { return (lhs.idx ?? .max) < (rhs.idx ?? .max) }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.chekiID.uuidString < rhs.chekiID.uuidString
    }

    private static func repairPartition(
        _ values: [ChekinanaChekiIndexSnapshot],
        isFavorite: Bool,
        into assignments: inout [UUID: Int]
    ) throws {
        guard !values.isEmpty else { return }
        if isFavorite {
            let reversed = Array(values.reversed())
            let repaired = try repairedPositiveSequence(reversed.map { snapshot in
                let candidate = snapshot.idx.flatMap { value -> Int? in
                    guard value < 0, value != Int.min else { return nil }
                    return -value
                }
                return (snapshot.chekiID, candidate)
            })
            for (id, magnitude) in repaired { assignments[id] = -magnitude }
        } else {
            let repaired = try repairedPositiveSequence(values.map {
                ($0.chekiID, ($0.idx ?? 0) > 0 ? $0.idx : nil)
            })
            for (id, idx) in repaired { assignments[id] = idx }
        }
    }

    private static func repairedPositiveSequence(
        _ values: [(UUID, Int?)]
    ) throws -> [(UUID, Int)] {
        var result: [(UUID, Int)] = []
        var previous = 0
        for (id, candidate) in values {
            let next: Int
            if let candidate, candidate > previous {
                next = candidate
            } else {
                guard previous < Int.max else { throw ChekinanaChekiIndexingError.overflow }
                next = previous + 1
            }
            result.append((id, next))
            previous = next
        }
        return result
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

import Foundation

/// Aggregates an immutable snapshot of persisted records. It deliberately has
/// no dependency on SwiftData, network responses, or generated language text.
enum ChekinanaAssistantStatistics {
    enum Source: String, Hashable, Sendable {
        case media
        case simple
    }

    enum Kind: String, Hashable, Sendable {
        case cheki
        case shame
        case douga
    }

    struct Row: Hashable, Sendable {
        let source: Source
        let id: UUID
        let idolIDs: Set<UUID>
        /// A record's own canonical yyyy-MM-dd key, obtained with
        /// ChekinanaDateOnly.string. Never use createdAt or an event's date.
        let date: String?
        let eventID: UUID?
        /// Only simple records use this quantity. A media object always counts once.
        let count: Int
        let kind: Kind
        /// Snapshots fetched from the persisted stores use true. Drafts and
        /// temporary scanner results must never contribute to statistics.
        let isPersisted: Bool

        init(
            source: Source,
            id: UUID,
            idolIDs: Set<UUID> = [],
            date: String? = nil,
            eventID: UUID? = nil,
            count: Int = 1,
            kind: Kind = .cheki,
            isPersisted: Bool = true
        ) {
            self.source = source
            self.id = id
            self.idolIDs = idolIDs
            self.date = date
            self.eventID = eventID
            self.count = count
            self.kind = kind
            self.isPersisted = isPersisted
        }
    }

    struct Query: Equatable, Sendable {
        /// nil means all idols; a non-nil set selects its union, counted once
        /// per record. An empty set matches no records.
        let idolIDs: Set<UUID>?
        let eventID: UUID?
        /// A range must provide both inclusive boundaries, or neither.
        let dateFrom: String?
        let dateTo: String?

        init(
            idolIDs: Set<UUID>? = nil,
            eventID: UUID? = nil,
            dateFrom: String? = nil,
            dateTo: String? = nil
        ) {
            self.idolIDs = idolIDs
            self.eventID = eventID
            self.dateFrom = dateFrom
            self.dateTo = dateTo
        }
    }

    struct Result: Equatable, Sendable {
        let total: Int
        let withImage: Int
        let withoutImage: Int
        /// Every associated idol receives the full quantity of a shared record.
        /// Consequently these values must not be added to obtain the total.
        let byIdol: [UUID: Int]
        /// Quantities included in total that lack a record date or idol link.
        let undatedCount: Int
        let unassociatedCount: Int
        /// Otherwise matching quantities omitted because a date filter is active.
        let excludedUndatedCount: Int
    }

    enum StatisticsError: Swift.Error, Equatable {
        case invalidQueryDate
        case invalidDateRange
        case invalidRecordDate
        case invalidCount
        case conflictingDuplicate
        case overflow
    }

    private struct Identity: Hashable {
        let source: Source
        let id: UUID
    }

    static func aggregate(
        rows: [Row],
        hiddenIdolIDs: Set<UUID> = [],
        query: Query = Query()
    ) throws -> Result {
        guard (query.dateFrom == nil) == (query.dateTo == nil) else {
            throw StatisticsError.invalidDateRange
        }
        for boundary in [query.dateFrom, query.dateTo].compactMap({ $0 }) {
            guard isCanonicalDay(boundary) else {
                throw StatisticsError.invalidQueryDate
            }
        }
        if let from = query.dateFrom, let to = query.dateTo, from > to {
            throw StatisticsError.invalidDateRange
        }

        // Only object identity deduplicates records. A saved image may have
        // consumed part of a simple record already; names and dates cannot
        // determine another deduction here.
        var uniqueRows: [Identity: Row] = [:]
        for row in rows where row.isPersisted && row.kind == .cheki {
            let identity = Identity(source: row.source, id: row.id)
            if let previous = uniqueRows[identity], previous != row {
                throw StatisticsError.conflictingDuplicate
            }
            uniqueRows[identity] = row
        }

        var total = 0
        var withImage = 0
        var withoutImage = 0
        var byIdol: [UUID: Int] = [:]
        var undatedCount = 0
        var unassociatedCount = 0
        var excludedUndatedCount = 0
        let hasDateFilter = query.dateFrom != nil || query.dateTo != nil

        for row in uniqueRows.values {
            // Visibility follows the app's whole-record hidden-idol policy.
            guard row.idolIDs.isDisjoint(with: hiddenIdolIDs) else { continue }
            if let wanted = query.idolIDs, row.idolIDs.isDisjoint(with: wanted) {
                continue
            }
            if let eventID = query.eventID, row.eventID != eventID { continue }

            let quantity = row.source == .media ? 1 : row.count
            guard quantity > 0 else { throw StatisticsError.invalidCount }
            if let date = row.date {
                guard isCanonicalDay(date) else {
                    throw StatisticsError.invalidRecordDate
                }
                if let from = query.dateFrom, date < from { continue }
                if let to = query.dateTo, date > to { continue }
            } else if hasDateFilter {
                excludedUndatedCount = try adding(quantity, to: excludedUndatedCount)
                continue
            }

            total = try adding(quantity, to: total)
            if row.source == .media {
                withImage = try adding(quantity, to: withImage)
            } else {
                withoutImage = try adding(quantity, to: withoutImage)
            }
            for idolID in row.idolIDs {
                byIdol[idolID] = try adding(quantity, to: byIdol[idolID, default: 0])
            }
            if row.date == nil { undatedCount = try adding(quantity, to: undatedCount) }
            if row.idolIDs.isEmpty {
                unassociatedCount = try adding(quantity, to: unassociatedCount)
            }
        }

        return Result(
            total: total,
            withImage: withImage,
            withoutImage: withoutImage,
            byIdol: byIdol,
            undatedCount: undatedCount,
            unassociatedCount: unassociatedCount,
            excludedUndatedCount: excludedUndatedCount
        )
    }

    private static func adding(_ quantity: Int, to subtotal: Int) throws -> Int {
        let (value, overflow) = subtotal.addingReportingOverflow(quantity)
        guard !overflow else { throw StatisticsError.overflow }
        return value
    }

    /// ASCII, fixed-width Gregorian calendar days compare chronologically as
    /// strings. Validation uses calendar arithmetic, never a device time zone.
    private static func isCanonicalDay(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
        for index in [0, 1, 2, 3, 5, 6, 8, 9] {
            guard (48...57).contains(bytes[index]) else { return false }
        }
        let year = bytes[0..<4].reduce(0) { $0 * 10 + Int($1 - 48) }
        let month = bytes[5..<7].reduce(0) { $0 * 10 + Int($1 - 48) }
        let day = bytes[8..<10].reduce(0) { $0 * 10 + Int($1 - 48) }
        guard year >= 1, (1...12).contains(month) else { return false }
        let leapYear = year.isMultiple(of: 400)
            || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let monthLengths = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...monthLengths[month - 1]).contains(day)
    }
}

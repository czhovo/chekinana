import AVFoundation
import AVKit
import CoreTransferable
import PhotosUI
import Photos
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChekinanaAssistantScanLaunch {
    let items: [PhotosPickerItem]
    let dateRecognitionEnabled: Bool
    let idolRecognitionEnabled: Bool
    let candidateIDs: Set<UUID>
    let includesUnassigned: Bool
    let dateBounds: ChekinanaScannerDateBounds?

    init(
        items: [PhotosPickerItem],
        dateRecognitionEnabled: Bool,
        idolRecognitionEnabled: Bool,
        candidateIDs: Set<UUID>,
        includesUnassigned: Bool,
        dateBounds: ChekinanaScannerDateBounds? = nil
    ) {
        self.items = items
        self.dateRecognitionEnabled = dateRecognitionEnabled
        self.idolRecognitionEnabled = idolRecognitionEnabled
        self.candidateIDs = candidateIDs
        self.includesUnassigned = includesUnassigned
        self.dateBounds = dateBounds
    }
}

struct ChekinanaCandidateSelectionState {
    var selectedIDs = Set<UUID>()
    private(set) var didInitialize = false
    private(set) var validIDs = Set<UUID>()

    mutating func reconcile(validIDs: Set<UUID>) {
        if !didInitialize {
            selectedIDs = validIDs
            didInitialize = true
        } else {
            let newlyEligible = validIDs.subtracting(self.validIDs)
            selectedIDs.formIntersection(validIDs)
            selectedIDs.formUnion(newlyEligible)
        }
        self.validIDs = validIDs
    }
}

private struct ChekinanaAssistantPresentation: Identifiable {
    let id = UUID()
    var initialPrompt: String?
    var scanLaunch: ChekinanaAssistantScanLaunch?
}

private enum ChekinanaProductTab: String, Hashable {
    case scan
    case idols
    case calendar
    case events
    case gallery

    var title: String {
        switch self {
        case .scan:
            ChekinanaProductCopy.text("tabs.scan", "Scan")
        case .idols:
            ChekinanaProductCopy.text("common.idols", "Idols")
        case .calendar:
            ChekinanaProductCopy.text("calendar.title", "Calendar")
        case .events:
            ChekinanaProductCopy.text("events.title", "Events")
        case .gallery:
            ChekinanaProductCopy.text("tabs.gallery", "Gallery")
        }
    }
}

private enum ChekinanaProductTheme {
    static let accent = ChekinanaDesignSystem.accent
    static let softAccent = ChekinanaDesignSystem.softAccent
    static let pageBackground = ChekinanaDesignSystem.pageBackground
    static let cardBackground = ChekinanaDesignSystem.cardBackground
    static let border = ChekinanaDesignSystem.border
    static let cardRadius = ChekinanaDesignSystem.cardRadius
    static let compactRadius = ChekinanaDesignSystem.compactRadius
    static let pageSpacing = ChekinanaDesignSystem.pageSpacing
}

enum ChekinanaPatternCountLabel {
    static func text(_ count: Int, whenEmpty: String = "No patterns") -> String {
        guard count > 0 else { return whenEmpty }
        return count == 1 ? "1 pattern" : "\(count) patterns"
    }
}

enum ChekinanaChekiCountLabel {
    static func text(_ count: Int) -> String {
        ChekinanaRecordKind.cheki.countLabel(count)
    }
}

enum ChekinanaMiniChekiIconMetrics {
    static let outerAspectRatio = CGFloat(1_200) / CGFloat(1_908)
    static let width: CGFloat = 10
    static let height = width / outerAspectRatio
}

enum ChekinanaChekiDisplayFramePolicy {
    static let aspectRatio = CGFloat(1_200) / CGFloat(1_908)
}

/// A single, deterministic ordering used anywhere the product presents dated
/// records.  Missing dates are intentionally always last, even in reverse.
enum ChekinanaRecordOrdering {
    static func ascending(_ lhs: ChekinanaGalleryItem, _ rhs: ChekinanaGalleryItem) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return tie(lhs, rhs)
        }
    }

    static func ordered(_ values: [ChekinanaGalleryItem], ascending: Bool) -> [ChekinanaGalleryItem] {
        let dated = values.filter { $0.date != nil }.sorted { ascending ? self.ascending($0, $1) : self.ascending($1, $0) }
        let undated = values.filter { $0.date == nil }.sorted(by: tie)
        return dated + undated
    }

    static func orderedChekis(_ values: [Cheki], ascending: Bool = true) -> [Cheki] {
        let dated = values.filter { $0.date != nil }.sorted { lhs, rhs in
            guard let left = lhs.date, let right = rhs.date else { return false }
            if left != right { return ascending ? left < right : left > right }
            if lhs.idx != rhs.idx { return (lhs.idx ?? .max) < (rhs.idx ?? .max) }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return dated + values.filter { $0.date == nil }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func tie(_ lhs: ChekinanaGalleryItem, _ rhs: ChekinanaGalleryItem) -> Bool {
        if case let (.cheki(left), .cheki(right)) = (lhs, rhs), left.idx != right.idx {
            return (left.idx ?? .max) < (right.idx ?? .max)
        }
        return lhs.modelID.uuidString < rhs.modelID.uuidString
    }
}

/// Event details are browsed by performer first. This ordering is deliberately
/// independent from localized display strings and keeps `idx` scoped to the
/// exact Idol set where it has meaning.
enum ChekinanaEventChekiOrdering {
    struct GroupKey: Hashable, Identifiable {
        let idolIDs: Set<UUID>

        var id: String { stableIdentifier }

        var stableIdentifier: String {
            guard !idolIDs.isEmpty else { return "unassigned" }
            return idolIDs.map { $0.uuidString.lowercased() }.sorted()
                .joined(separator: ".")
        }
    }

    struct Group: Identifiable {
        let key: GroupKey
        let idols: [Idol]
        let chekis: [Cheki]

        var id: GroupKey { key }
    }

    struct ValueGroup: Equatable {
        let key: GroupKey
        let recordIDs: [UUID]
    }

    struct IdolValue: Equatable {
        let id: UUID
        let sortOrder: Double?
    }

    struct Value: Equatable {
        let id: UUID
        let idols: [IdolValue]
        let idx: Int?
        let createdAt: Date
    }

    static func ordered(
        _ chekis: [Cheki],
        hiddenIDs: Set<UUID> = []
    ) -> [Cheki] {
        let visible = chekis.filter {
            ChekinanaVisibilityPolicy.includesRecord(
                idolIDs: $0.idols.map(\.id),
                hiddenIDs: hiddenIDs
            )
        }
        let uniqueByID = visible.reduce(into: [UUID: Cheki]()) { result, cheki in
            result[cheki.id] = result[cheki.id] ?? cheki
        }
        let valueByID = uniqueByID.mapValues(value)
        return uniqueByID.values.sorted {
            guard let lhs = valueByID[$0.id], let rhs = valueByID[$1.id] else {
                return $0.id.uuidString < $1.id.uuidString
            }
            return precedes(lhs, rhs)
        }
    }

    static func groups(
        _ chekis: [Cheki],
        hiddenIDs: Set<UUID> = []
    ) -> [Group] {
        var result: [Group] = []
        var indexByKey: [GroupKey: Int] = [:]
        for cheki in ordered(chekis, hiddenIDs: hiddenIDs) {
            let key = GroupKey(idolIDs: Set(cheki.idols.map(\.id)))
            if let index = indexByKey[key] {
                let current = result[index]
                result[index] = Group(
                    key: key,
                    idols: current.idols,
                    chekis: current.chekis + [cheki]
                )
            } else {
                indexByKey[key] = result.count
                result.append(Group(
                    key: key,
                    idols: orderedIdols(cheki.idols),
                    chekis: [cheki]
                ))
            }
        }
        return result
    }

    static func orderedIDs(
        _ values: [Value],
        hiddenIDs: Set<UUID> = []
    ) -> [UUID] {
        var uniqueByID: [UUID: Value] = [:]
        for value in values
        where uniqueByID[value.id] == nil
            && ChekinanaVisibilityPolicy.includesRecord(
                idolIDs: value.idols.map(\.id),
                hiddenIDs: hiddenIDs
            ) {
            uniqueByID[value.id] = value
        }
        return uniqueByID.values.sorted(by: precedes).map(\.id)
    }

    static func groupedIDs(
        _ values: [Value],
        hiddenIDs: Set<UUID> = []
    ) -> [ValueGroup] {
        let valueByID = values.reduce(into: [UUID: Value]()) { result, value in
            result[value.id] = result[value.id] ?? value
        }
        var result: [ValueGroup] = []
        var indexByKey: [GroupKey: Int] = [:]
        for id in orderedIDs(values, hiddenIDs: hiddenIDs) {
            guard let value = valueByID[id] else { continue }
            let key = GroupKey(idolIDs: Set(value.idols.map(\.id)))
            if let index = indexByKey[key] {
                let current = result[index]
                result[index] = ValueGroup(
                    key: key,
                    recordIDs: current.recordIDs + [id]
                )
            } else {
                indexByKey[key] = result.count
                result.append(ValueGroup(key: key, recordIDs: [id]))
            }
        }
        return result
    }

    private static func value(_ cheki: Cheki) -> Value {
        Value(
            id: cheki.id,
            idols: cheki.idols.map {
                IdolValue(id: $0.id, sortOrder: $0.sortOrder)
            },
            idx: cheki.idx,
            createdAt: cheki.createdAt
        )
    }

    private static func precedes(_ lhs: Value, _ rhs: Value) -> Bool {
        let leftIdols = stableIdols(lhs.idols)
        let rightIdols = stableIdols(rhs.idols)
        if leftIdols.isEmpty != rightIdols.isEmpty { return !leftIdols.isEmpty }
        if let idolComparison = lexicographicComparison(leftIdols, rightIdols) {
            return idolComparison
        }

        // The UUID is part of every Idol key, so equal sequences are the same
        // exact Idol set. Only inside that group does idx have ordering meaning.
        if lhs.idx != rhs.idx { return (lhs.idx ?? .max) < (rhs.idx ?? .max) }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func stableIdols(_ values: [IdolValue]) -> [IdolValue] {
        var uniqueByID: [UUID: IdolValue] = [:]
        for value in values where uniqueByID[value.id] == nil {
            uniqueByID[value.id] = value
        }
        return uniqueByID.values.sorted(by: idolPrecedes)
    }

    private static func orderedIdols(_ idols: [Idol]) -> [Idol] {
        let uniqueByID = idols.reduce(into: [UUID: Idol]()) { result, idol in
            result[idol.id] = result[idol.id] ?? idol
        }
        let orderedIDs = stableIdols(uniqueByID.values.map {
            IdolValue(id: $0.id, sortOrder: $0.sortOrder)
        }).map(\.id)
        return orderedIDs.compactMap { uniqueByID[$0] }
    }

    private static func lexicographicComparison(
        _ lhs: [IdolValue],
        _ rhs: [IdolValue]
    ) -> Bool? {
        for (left, right) in zip(lhs, rhs) {
            if idolPrecedes(left, right) { return true }
            if idolPrecedes(right, left) { return false }
        }
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        return nil
    }

    private static func idolPrecedes(_ lhs: IdolValue, _ rhs: IdolValue) -> Bool {
        let leftOrder = lhs.sortOrder.flatMap { $0.isFinite ? $0 : nil }
        let rightOrder = rhs.sortOrder.flatMap { $0.isFinite ? $0 : nil }
        switch (leftOrder, rightOrder) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum ChekinanaBirthdayValue {
    enum Semantic: Equatable {
        case fullDate(year: Int, month: Int, day: Int)
        case monthDay(month: Int, day: Int)

        var storageString: String {
            switch self {
            case .fullDate(let year, let month, let day):
                String(format: "%04d-%02d-%02d", year, month, day)
            case .monthDay(let month, let day):
                String(format: "--%02d-%02d", month, day)
            }
        }

        var monthAndDay: (month: Int, day: Int) {
            switch self {
            case .fullDate(_, let month, let day), .monthDay(let month, let day):
                (month, day)
            }
        }

        var hasKnownYear: Bool {
            if case .fullDate = self { return true }
            return false
        }
    }

    enum ValidationError: LocalizedError, Equatable {
        case invalid

        var errorDescription: String? {
            ChekinanaProductCopy.text(
                "idols.birthday_value_invalid",
                "Birthday must be a valid full date or month and day."
            )
        }
    }

    static func semantic(_ rawValue: String?) -> Semantic? {
        guard let rawValue = rawValue?.nonEmpty else { return nil }
        if let canonical = ChekinanaDateOnly.parse(rawValue) {
            let pieces = ChekinanaDateOnly.string(canonical).split(separator: "-")
            if pieces.count == 3,
               let year = Int(pieces[0]),
               let month = Int(pieces[1]),
               let day = Int(pieces[2]) {
                return .fullDate(year: year, month: month, day: day)
            }
        }

        let normalized = rawValue
            .replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let pieces = normalized.split(separator: "-", omittingEmptySubsequences: true)
        if pieces.count == 3,
           pieces[0].count == 4,
           let year = Int(pieces[0]),
           let month = Int(pieces[1]),
           let day = Int(pieces[2]),
           ChekinanaDateOnly.canonicalDate(
               year: year,
               month: month,
               day: day
           ) != nil {
            return .fullDate(year: year, month: month, day: day)
        }
        if pieces.count == 2,
           let month = Int(pieces[0]),
           let day = Int(pieces[1]),
           validMonthDay(month: month, day: day) {
            return .monthDay(month: month, day: day)
        }
        return nil
    }

    static func normalizedStorage(_ rawValue: String?) throws -> String? {
        guard rawValue?.nonEmpty != nil else { return nil }
        guard let semantic = semantic(rawValue) else { throw ValidationError.invalid }
        return semantic.storageString
    }

    static func normalizedCatalogueCandidate(
        _ candidate: ChekinanaEnrichedIdol
    ) throws -> ChekinanaEnrichedIdol {
        guard !candidate.birthdayIsInvalid else { throw ValidationError.invalid }
        return ChekinanaEnrichedIdol(
            sourceId: candidate.sourceId,
            idolName: candidate.idolName,
            groupName: candidate.groupName,
            color: candidate.color,
            birthday: try normalizedStorage(candidate.birthday),
            verification: candidate.verification,
            bio: candidate.bio,
            avatarUrl: candidate.avatarUrl
        )
    }

    static func parse(_ rawValue: String?) -> Date? {
        guard case .fullDate(let year, let month, let day) = semantic(rawValue) else {
            return nil
        }
        return ChekinanaDateOnly.canonicalDate(year: year, month: month, day: day)
    }

    static func displayDate(
        _ rawValue: String?,
        calendar: Calendar = .current
    ) -> Date? {
        parse(rawValue).flatMap {
            ChekinanaDateOnly.displayDate(from: $0, calendar: calendar)
        }
    }

    static func canonicalString(
        from displayedDate: Date,
        calendar: Calendar = .current
    ) -> String? {
        ChekinanaDateOnly.canonicalDate(
            from: displayedDate,
            displayedIn: calendar
        ).map(ChekinanaDateOnly.string)
    }

    static func localizedDisplay(
        _ rawValue: String?,
        calendar: Calendar = .current,
        locale: Locale? = nil
    ) -> String? {
        guard rawValue?.nonEmpty != nil else { return nil }
        guard let semantic = semantic(rawValue) else {
            return ChekinanaProductCopy.text("common.unknown", "Unknown")
        }
        let date: Date
        switch semantic {
        case .fullDate:
            guard let parsed = displayDate(rawValue, calendar: calendar) else {
                return ChekinanaProductCopy.text("common.unknown", "Unknown")
            }
            date = parsed
        case .monthDay(let month, let day):
            guard let reduced = displayDate(
                year: 2_000,
                month: month,
                day: day,
                calendar: calendar
            ) else {
                return ChekinanaProductCopy.text("common.unknown", "Unknown")
            }
            date = reduced
        }
        let formatter = DateFormatter()
        formatter.locale = locale ?? ChekinanaLanguagePreference.displayLocale()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(
            semantic.hasKnownYear ? "yMMMd" : "MMMd"
        )
        return formatter.string(from: date)
    }

    static func draftDisplayDate(
        for semantic: Semantic,
        defaultYear: Int,
        calendar: Calendar = .current
    ) -> Date? {
        let monthAndDay = semantic.monthAndDay
        let year: Int
        switch semantic {
        case .fullDate(let value, _, _): year = value
        case .monthDay: year = defaultYear
        }
        return displayDate(
            year: year,
            month: monthAndDay.month,
            day: monthAndDay.day,
            calendar: calendar
        )
    }

    private static func validMonthDay(month: Int, day: Int) -> Bool {
        ChekinanaDateOnly.canonicalDate(year: 2_000, month: month, day: day) != nil
    }

    private static func displayDate(
        year: Int,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == year,
              verified.month == month,
              verified.day == day else { return nil }
        return date
    }
}

enum ChekinanaBirthdayEditorMode: String, CaseIterable, Identifiable {
    case unknownYear
    case fullDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unknownYear:
            ChekinanaProductCopy.text(
                "idols.birthday_mode.unknown_year",
                "Year unknown"
            )
        case .fullDate:
            ChekinanaProductCopy.text(
                "idols.birthday_mode.full_date",
                "Full date"
            )
        }
    }
}

enum ChekinanaBirthdayEditorPolicy {
    static func initialMode(for semantic: ChekinanaBirthdayValue.Semantic?)
        -> ChekinanaBirthdayEditorMode
    {
        if case .monthDay = semantic { return .unknownYear }
        return .fullDate
    }

    static func dayRange(month: Int) -> ClosedRange<Int> {
        let upperBound: Int
        switch month {
        case 2: upperBound = 29
        case 4, 6, 9, 11: upperBound = 30
        default: upperBound = 31
        }
        return 1...upperBound
    }

    static func clampedDay(_ day: Int, month: Int) -> Int {
        min(max(day, 1), dayRange(month: month).upperBound)
    }

    static func storageValue(
        hasBirthday: Bool,
        mode: ChekinanaBirthdayEditorMode,
        fullDate: Date,
        unknownMonth: Int,
        unknownDay: Int,
        fullYearConfirmed: Bool,
        calendar: Calendar = .current
    ) throws -> String? {
        guard hasBirthday else { return nil }
        switch mode {
        case .unknownYear:
            let semantic = ChekinanaBirthdayValue.Semantic.monthDay(
                month: unknownMonth,
                day: unknownDay
            )
            guard ChekinanaBirthdayValue.semantic(semantic.storageString) == semantic else {
                throw ChekinanaBirthdayValue.ValidationError.invalid
            }
            return semantic.storageString
        case .fullDate:
            guard fullYearConfirmed,
                  let canonical = ChekinanaBirthdayValue.canonicalString(
                    from: fullDate,
                    calendar: calendar
                  ) else {
                throw ChekinanaProductDateSelectionError.invalidBirthday
            }
            return canonical
        }
    }
}

enum ChekinanaProductDateSelectionError: LocalizedError {
    case invalidBirthday

    var errorDescription: String? {
        switch self {
        case .invalidBirthday:
            ChekinanaProductCopy.text(
                "idols.birthday_invalid",
                "Unable to normalize the selected birthday."
            )
        }
    }
}

enum ChekinanaCalendarSelectionPolicy {
    static func selecting(
        _ date: Date,
        displayedMonth: Date
    ) -> (selectedDate: Date, displayedMonth: Date) {
        (date, displayedMonth)
    }
}

struct ChekinanaIdolChekiReorderSnapshot: Equatable {
    let chekiID: UUID
    let group: ChekinanaChekiGroupKey
    let idx: Int?
}

enum ChekinanaIdolChekiReorderError: Error, Equatable {
    case empty
    case duplicateRecord
    case changedRecords
    case mixedGroups
    case overflow
}

enum ChekinanaIdolChekiReorderPlan {
    static func movedBlocks(
        _ blocks: [[UUID]],
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> [[UUID]] {
        var result = blocks
        result.move(fromOffsets: fromOffsets, toOffset: toOffset)
        return result
    }

    static func assignments(
        for blocks: [[UUID]],
        liveSnapshots: [ChekinanaIdolChekiReorderSnapshot]
    ) throws -> [UUID: Int] {
        let orderedIDs = blocks.flatMap { $0 }
        guard !orderedIDs.isEmpty, blocks.allSatisfy({ !$0.isEmpty }) else {
            throw ChekinanaIdolChekiReorderError.empty
        }
        guard Set(orderedIDs).count == orderedIDs.count else {
            throw ChekinanaIdolChekiReorderError.duplicateRecord
        }
        let liveIDs = Set(liveSnapshots.map(\.chekiID))
        guard liveIDs == Set(orderedIDs), liveSnapshots.count == orderedIDs.count else {
            throw ChekinanaIdolChekiReorderError.changedRecords
        }
        guard Set(liveSnapshots.map(\.group)).count == 1 else {
            throw ChekinanaIdolChekiReorderError.mixedGroups
        }
        guard orderedIDs.count < Int.max else {
            throw ChekinanaIdolChekiReorderError.overflow
        }
        return Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map {
            ($0.element, $0.offset + 1)
        })
    }
}

enum ChekinanaIdolNoMediaChekiGrouping {
    static func exactNoteKey(_ note: String?) -> String {
        note ?? ""
    }
}

enum ChekinanaScanAnnotationDisplayPolicy {
    // `previewImageData` is already rendered off the main actor with the
    // result's single quadrilateral. The SwiftUI layer must not stroke it again.
    static let drawsQuadrilateralInView = false

    static func displayedData(
        cleanImageData: Data,
        sourceAnnotation: ChekinanaScannerSourceAnnotation?,
        showsSourceAnnotation: Bool
    ) -> Data {
        guard showsSourceAnnotation,
              sourceAnnotation?.isValid == true,
              let sourceAnnotation else { return cleanImageData }
        return sourceAnnotation.previewImageData
    }
}

enum ChekinanaScanPreviewLoadPublicationPolicy {
    static func canPublish(
        completedToken: String,
        requestedToken: String?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && completedToken == requestedToken
    }
}

enum ChekinanaNoMediaPolicy {
    static func hasNoImage(_ imageRef: String?) -> Bool {
        imageRef?.nonEmpty == nil
    }
}

struct ChekinanaMiniChekiIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: max(1, size.width * 0.12), style: .continuous)
                    .stroke(Color.secondary, lineWidth: 1)
                RoundedRectangle(cornerRadius: max(0.5, size.width * 0.05), style: .continuous)
                    .fill(ChekinanaProductTheme.accent.opacity(0.10))
                    .frame(width: size.width * 0.72, height: size.height * 0.66)
                    .padding(.top, size.height * 0.09)
            }
        }
        .aspectRatio(ChekinanaMiniChekiIconMetrics.outerAspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct ChekinanaIdolPatternStatus: Equatable {
    let systemImageName: String
    let accessibilityValue: String

    static func make(hasRecognitionPatterns: Bool) -> Self {
        if hasRecognitionPatterns {
            return Self(
                systemImageName: "checkmark.seal",
                accessibilityValue: "Stored pattern available"
            )
        }
        return Self(
            systemImageName: "circle.dashed",
            accessibilityValue: "No stored pattern"
        )
    }
}

private struct ChekinanaAccessibilityMarker: View {
    let identifier: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Chekinana screen marker")
            .accessibilityValue(identifier)
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }
}

private struct ChekinanaAccessibilityValueMarker: View {
    let identifier: String
    let label: String
    let value: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }
}

private extension View {
    func chekinanaScreenMarker(_ identifier: String) -> some View {
        overlay(alignment: .topLeading) {
            ChekinanaAccessibilityMarker(identifier: identifier)
        }
    }

    func chekinanaGroupedPageBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(ChekinanaProductTheme.pageBackground)
    }
}

struct ChekinanaProductShell: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Query private var idols: [Idol]
    @Query private var shames: [Shame]
    @Query private var dougas: [Douga]
    @Query private var events: [Event]
    @Query private var chekis: [Cheki]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared

    @State private var selectedTab: ChekinanaProductTab = .scan
    @State private var isDrawerPresented = false
    @State private var assistantPresentation: ChekinanaAssistantPresentation?
    @State private var assistantSession = ChekinanaAssistantSession()
    @State private var isAssistantTransitioning = false
    @State private var isSettingsPresented = false
    @State private var isMatchGamePresented = false
    @State private var isChekiRokuImportPresented = false
    @State private var pendingShellAction: ChekinanaAssistantShellAction?
    @State private var calendarNavigationDate: Date?

    var body: some View {
        let _ = languageRevision
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                productTabs
                    .allowsHitTesting(!isDrawerPresented && !isChekiRokuImportPresented)
                    .accessibilityHidden(isDrawerPresented || isChekiRokuImportPresented)

                ChekinanaAccessibilityMarker(identifier: "chekinana.shell.root")

                if isDrawerPresented {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .transition(.opacity)
                        .accessibilityLabel("关闭侧边栏")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("chekinana.shell.drawer.scrim")

                    ChekinanaSidebar(
                        idolCount: visibleIdols.count,
                        chekiCount: visibleChekis.count,
                        eventCount: events.count,
                        openAssistant: openAssistant,
                        openMatchGame: {
                            closeDrawer()
                            isMatchGamePresented = true
                        },
                        openSettings: {
                            closeDrawer()
                            isSettingsPresented = true
                        },
                        importChekiRoku: {
                            closeDrawer()
                            isChekiRokuImportPresented = true
                        },
                        close: closeDrawer
                    )
                    .frame(width: min(336, geometry.size.width * 0.86))
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .leading))

                    ChekinanaAccessibilityMarker(identifier: "chekinana.shell.drawer")
                }
            }
        }
        .tint(ChekinanaProductTheme.accent)
        .preferredColorScheme(.light)
        .statusBarHidden(false)
        .animation(.snappy(duration: 0.3), value: isDrawerPresented)
        .fullScreenCover(item: $assistantPresentation, onDismiss: {
            isAssistantTransitioning = false
            if let action = pendingShellAction {
                pendingShellAction = nil
                applyShellAction(action)
            }
        }) { presentation in
            ContentView(
                session: assistantSession,
                onClose: { assistantPresentation = nil },
                onShellAction: handleShellAction,
                initialScannerLaunch: presentation.scanLaunch,
                initialPrompt: presentation.initialPrompt
            )
        }
        .sheet(isPresented: $isSettingsPresented) {
            ChekinanaSettingsView()
                .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $isMatchGamePresented) {
            ChekinanaLianliankanView {
                isMatchGamePresented = false
            }
        }
        .overlay {
            if isChekiRokuImportPresented {
                ChekinanaChekiRokuClipboardImportView { isChekiRokuImportPresented = false }
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var visibleIdols: [Idol] {
        ChekinanaVisibilityPolicy.visibleIdols(idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }

    private var visibleChekis: [Cheki] {
        chekis.filter {
            ChekinanaVisibilityPolicy.includesRecord(
                idols: $0.idols,
                hiddenIDs: hiddenIdols.hiddenIDs
            )
        }
    }

    private var productTabs: some View {
        productTabContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChekinanaBottomTabBar(selection: $selectedTab)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var productTabContent: some View {
        TabView(selection: $selectedTab) {
            ChekinanaScanView(openMenu: openDrawer)
                .tag(ChekinanaProductTab.scan)
            ChekinanaIdolsView(openMenu: openDrawer)
                .tag(ChekinanaProductTab.idols)
            ChekinanaCalendarView(
                openMenu: openDrawer,
                navigationDate: $calendarNavigationDate
            )
                .tag(ChekinanaProductTab.calendar)
            ChekinanaEventsView(openMenu: openDrawer)
                .tag(ChekinanaProductTab.events)
            ChekinanaGalleryView(openMenu: openDrawer)
                .tag(ChekinanaProductTab.gallery)
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private func openDrawer() {
        withAnimation(.snappy(duration: 0.3)) { isDrawerPresented = true }
    }

    private func closeDrawer() {
        withAnimation(.snappy(duration: 0.3)) { isDrawerPresented = false }
    }

    private func openAssistant() {
        guard !isAssistantTransitioning, assistantPresentation == nil else { return }
        isAssistantTransitioning = true
#if DEBUG
        let startedAt = DispatchTime.now().uptimeNanoseconds
#endif
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isDrawerPresented = false }
        Task { @MainActor in
            await Task.yield()
            assistantPresentation = ChekinanaAssistantPresentation()
#if DEBUG
            ChekinanaAssistantTimingLog.completed(
                stage: "entry-presented",
                messageCount: assistantSession.messageCount,
                cardCount: assistantSession.candidateCardCount,
                startedAt: startedAt
            )
#endif
        }
    }

    private func handleShellAction(_ action: ChekinanaAssistantShellAction) {
        guard assistantPresentation != nil else {
            applyShellAction(action)
            return
        }
        pendingShellAction = action
        assistantPresentation = nil
    }

    private func applyShellAction(_ action: ChekinanaAssistantShellAction) {
        closeDrawer()
        switch action {
        case .navigate(let destination, let date):
            switch destination {
            case .scan:
                selectedTab = .scan
            case .idols:
                selectedTab = .idols
            case .calendar:
                if let date, let canonical = ChekinanaDateOnly.canonicalized(date) {
                    calendarNavigationDate = canonical
                }
                selectedTab = .calendar
            case .events:
                selectedTab = .events
            case .gallery:
                selectedTab = .gallery
            case .settings:
                isSettingsPresented = true
            case .chekiRokuImport:
                isChekiRokuImportPresented = true
            }
        case .openScan(let request):
            let dateBounds: ChekinanaScannerDateBounds?
            if let fixedDate = request.fixedDate {
                dateBounds = ChekinanaScannerDateBounds.fixedCanonicalDate(fixedDate)
            } else if let from = request.dateFrom, let to = request.dateTo {
                dateBounds = ChekinanaScannerDateBounds.canonicalRange(from: from, to: to)
            } else if request.recognizeDate {
                dateBounds = ChekinanaScannerDateBounds.recent(relativeTo: Date())
            } else {
                dateBounds = nil
            }
            selectedTab = .scan
            assistantPresentation = ChekinanaAssistantPresentation(
                scanLaunch: ChekinanaAssistantScanLaunch(
                    items: [],
                    dateRecognitionEnabled: request.recognizeDate,
                    idolRecognitionEnabled: request.recognizeIdol,
                    candidateIDs: Set(request.candidateIdolIDs),
                    includesUnassigned: request.includesUnassigned,
                    dateBounds: dateBounds
                )
            )
        }
    }

}

enum ChekinanaBottomTabBarMetrics {
    static let previousMinimumHeight: CGFloat = 58
    static let minimumHeight: CGFloat = 51
    static let buttonMinimumHeight: CGFloat = 44
    static let topPadding: CGFloat = 5
    static let bottomPadding: CGFloat = 2
}

private struct ChekinanaBottomTabBar: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Binding var selection: ChekinanaProductTab

    var body: some View {
        let _ = languageRevision
        HStack(spacing: 4) {
            tabButton(.scan, title: ChekinanaProductTab.scan.title, image: "viewfinder")
            tabButton(
                .idols,
                title: ChekinanaProductTab.idols.title,
                image: "person.2",
                asset: ("NavIdols", "NavIdolsActive")
            )
            tabButton(
                .calendar,
                title: ChekinanaProductTab.calendar.title,
                image: "calendar",
                asset: ("NavCalendar", "NavCalendarActive")
            )
            tabButton(.events, title: ChekinanaProductTab.events.title, image: "music.note.house")
            tabButton(.gallery, title: ChekinanaProductTab.gallery.title, image: "square.grid.2x2")
        }
        .padding(.horizontal, 10)
        .padding(.top, ChekinanaBottomTabBarMetrics.topPadding)
        .padding(.bottom, ChekinanaBottomTabBarMetrics.bottomPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: ChekinanaBottomTabBarMetrics.minimumHeight
        )
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ChekinanaProductTheme.border)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.shell.tabbar")
    }

    private func tabButton(
        _ tab: ChekinanaProductTab,
        title: String,
        image: String,
        asset: (normal: String, selected: String)? = nil
    ) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let asset {
                        Image(isSelected ? asset.selected : asset.normal)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: image)
                            .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                    }
                }
                .frame(width: 20, height: 20)
                Text(title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? ChekinanaProductTheme.accent : Color.secondary)
            .frame(
                maxWidth: .infinity,
                minHeight: ChekinanaBottomTabBarMetrics.buttonMinimumHeight
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chekinana.shell.tab.\(tab.rawValue)")
    }
}

private struct ChekinanaSidebar: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    let idolCount: Int
    let chekiCount: Int
    let eventCount: Int
    let openAssistant: () -> Void
    let openMatchGame: () -> Void
    let openSettings: () -> Void
    let importChekiRoku: () -> Void
    let close: () -> Void

    var body: some View {
        let _ = languageRevision
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ChekinanaProductTheme.accent)
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Chekinana")
                        .font(.headline)
                    Text(ChekinanaProductCopy.text("sidebar.subtitle", "Your local cheki library"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(ChekinanaProductCopy.text("sidebar.close", "Close sidebar"))
                .accessibilityIdentifier("chekinana.shell.drawer.close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 20)

            VStack(spacing: 8) {
                sidebarButton(
                    title: ChekinanaProductCopy.text("sidebar.assistant", "Assistant"),
                    subtitle: ChekinanaProductCopy.text("sidebar.assistant.subtitle", "Conversations, confirmations, and advanced actions"),
                    systemImage: "bubble.left.and.bubble.right",
                    identifier: "chekinana.shell.drawer.assistant",
                    action: openAssistant
                )
                sidebarButton(
                    title: ChekinanaProductCopy.text("sidebar.match", "Match Game"),
                    subtitle: ChekinanaProductCopy.text("sidebar.match.subtitle", "Chekinana matching game"),
                    systemImage: "square.grid.3x3.fill",
                    identifier: "chekinana.shell.drawer.match-game",
                    action: openMatchGame
                )
                sidebarButton(
                    title: ChekinanaProductCopy.text("settings.title", "Settings"),
                    subtitle: ChekinanaProductCopy.text("sidebar.settings.subtitle", "Local features and service status"),
                    systemImage: "gearshape",
                    identifier: "chekinana.shell.drawer.settings",
                    action: openSettings
                )
                sidebarButton(
                    title: ChekinanaProductCopy.text("sidebar.import", "Import from ChekiRoku"),
                    subtitle: ChekinanaProductCopy.text("sidebar.import.subtitle", "Import a local .chekiroku backup"),
                    systemImage: "square.and.arrow.down",
                    identifier: "chekinana.shell.drawer.chekiroku-import",
                    action: importChekiRoku
                )
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 12) {
                Text(ChekinanaProductCopy.text("sidebar.on_device", "ON THIS DEVICE"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    sidebarMetric(value: idolCount, label: ChekinanaProductCopy.text("common.idols", "Idols"))
                    Divider().frame(height: 34)
                    sidebarMetric(value: chekiCount, label: ChekinanaRecordKind.cheki.title)
                    Divider().frame(height: 34)
                    sidebarMetric(value: eventCount, label: ChekinanaProductCopy.text("events.title", "Events"))
                }
            }
            .padding(16)
            .background(ChekinanaProductTheme.softAccent.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .shadow(color: .black.opacity(0.16), radius: 24, x: 10, y: 0)
    }

    private func sidebarButton(
        title: String,
        subtitle: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ChekinanaProductTheme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .frame(minHeight: ChekinanaAccessibilityMetrics.minimumTouchTarget)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func sidebarMetric(value: Int, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted())
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChekinanaPageToolbar: ToolbarContent {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    let pageID: String
    let openMenu: () -> Void

    var body: some ToolbarContent {
        let _ = languageRevision
        ToolbarItem(id: "chekinana.menu.\(pageID)", placement: .topBarLeading) {
            Button(action: openMenu) {
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(ChekinanaProductTheme.accent)
                            .frame(width: 18, height: 2.5)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(ChekinanaProductCopy.text("sidebar.open", "Open sidebar"))
            .accessibilityIdentifier("chekinana.shell.menu")
        }
    }
}

private struct ChekinanaSectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(ChekinanaProductTheme.pageSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChekinanaProductTheme.cardBackground)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ChekinanaProductTheme.cardRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: ChekinanaProductTheme.cardRadius,
                    style: .continuous
                )
                    .stroke(ChekinanaProductTheme.border, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

private struct ChekinanaInlineStatus: View {
    enum Kind: Equatable {
        case information
        case loading
        case error

        var color: Color {
            switch self {
            case .information, .loading: ChekinanaProductTheme.accent
            case .error: .red
            }
        }

        var systemImage: String {
            switch self {
            case .information: "info.circle"
            case .loading: "hourglass"
            case .error: "exclamationmark.triangle"
            }
        }
    }

    let message: String
    let kind: Kind

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if kind == .loading {
                ProgressView()
                    .tint(kind.color)
            } else {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(kind.color)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(kind == .error ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.08))
        .clipShape(
            RoundedRectangle(
                cornerRadius: ChekinanaProductTheme.compactRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }
}

private struct ChekinanaEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(ChekinanaProductTheme.accent)
                .frame(width: 68, height: 68)
                .background(ChekinanaProductTheme.softAccent)
                .clipShape(Circle())
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(ChekinanaProductTheme.accent)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
    }
}

private enum ChekinanaScanInitialConfiguration {
    static var idolRecognitionEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment[
            "CHEKINANA_NATIVE_SCAN_UI_DISABLE_IDOL_RECOGNITION"
        ] != "1"
#else
        true
#endif
    }

    static var autoStartsFixtureReview: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment[
            "CHEKINANA_NATIVE_SCAN_UI_AUTO_START"
        ] == "1"
#else
        false
#endif
    }

    static var seedsInputFixture: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment[
            "CHEKINANA_NATIVE_SCAN_UI_INPUT_FIXTURE"
        ] == "1"
#else
        false
#endif
    }
}

@MainActor
final class ChekinanaScannerRuntimePresentationStore: ObservableObject {
    static let shared = ChekinanaScannerRuntimePresentationStore()

    typealias RuntimeRequest = @Sendable () async throws
        -> ChekinanaScannerRuntimeStatus
    typealias RuntimeStartUpdate = ChekinanaScannerRuntimeClient.StartStatusHandler
    typealias RuntimeStartRequest = @Sendable (
        @escaping RuntimeStartUpdate
    ) async throws -> ChekinanaScannerRuntimeStatus

    @Published private(set) var status: ChekinanaScannerRuntimeStatus?
    @Published private(set) var requestError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isShuttingDown = false

    private let refreshScheduler: ChekinanaScannerRuntimeRefreshScheduler
    private let statusRequest: RuntimeRequest
    private let startRequest: RuntimeStartRequest
    private let stopRequest: RuntimeRequest
    private var controlGeneration: UInt64 = 0
    private var latestStatusReadID: UInt64 = 0
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var hasPendingStopConfirmation = false
    private var hasPendingLastScanConfirmation = false
    private var stopConfirmationID: UInt64 = 0
    private var lastScanConfirmationID: UInt64 = 0

    init(
        refreshScheduler: ChekinanaScannerRuntimeRefreshScheduler = .init(),
        statusRequest: @escaping RuntimeRequest = {
            try await ChekinanaScannerRuntimeClient().status()
        },
        startRequest: RuntimeRequest? = nil,
        streamingStartRequest: RuntimeStartRequest? = nil,
        stopRequest: @escaping RuntimeRequest = {
            try await ChekinanaScannerRuntimeClient().stop()
        }
    ) {
        self.refreshScheduler = refreshScheduler
        self.statusRequest = statusRequest
        if let streamingStartRequest {
            self.startRequest = streamingStartRequest
        } else if let startRequest {
            self.startRequest = { _ in try await startRequest() }
        } else {
            self.startRequest = { update in
                try await ChekinanaScannerRuntimeClient().start(onStatus: update)
            }
        }
        self.stopRequest = stopRequest
    }

    var isControlInFlight: Bool {
        isStarting || isStopping
    }

    var blocksGPUInput: Bool {
        isControlInFlight || isShuttingDown
    }

    func refreshManually() async {
        guard !isRefreshing, !isControlInFlight else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await performStatusRefresh(expectedControlGeneration: controlGeneration)
    }

    func requestStart() {
        guard startTask == nil, stopTask == nil else { return }
        let token = beginControlOperation()
        isShuttingDown = false
        isStarting = true
        status = .init(
            state: .preparing,
            phase: "preparing",
            retryAllowed: false,
            canStart: false,
            canTerminate: false
        )
        requestError = nil
        let request = startRequest
        startTask = Task { @MainActor [weak self] in
            do {
                let result = try await request { [weak self] update in
                    await self?.acceptStartUpdate(update, token: token)
                }
                self?.finishStart(result: .success(result), token: token)
            } catch {
                self?.finishStart(result: .failure(error), token: token)
            }
        }
    }

    func cancelStart() {
        guard let startTask else { return }
        controlGeneration &+= 1
        latestStatusReadID &+= 1
        startTask.cancel()
        self.startTask = nil
        isStarting = false
        isShuttingDown = false
        let message = "GPU startup was canceled. Refresh status before trying again."
        status = .init(
            ok: false,
            state: .closed,
            phase: "closed",
            message: message,
            retryAllowed: true,
            canStart: false,
            canTerminate: false
        )
        requestError = message
    }

    func requestStop() {
        guard startTask == nil,
              stopTask == nil,
              status?.state == .ready,
              status?.canTerminate == true else { return }
        let shouldRestoreLastScanConfirmation = hasPendingLastScanConfirmation
        let token = beginControlOperation()
        isShuttingDown = true
        isStopping = true
        requestError = nil
        let request = stopRequest
        stopTask = Task { @MainActor [weak self] in
            do {
                let result = try await request()
                self?.finishStop(
                    result: .success(result),
                    token: token,
                    restoresLastScanConfirmation: shouldRestoreLastScanConfirmation
                )
            } catch {
                self?.finishStop(
                    result: .failure(error),
                    token: token,
                    restoresLastScanConfirmation: shouldRestoreLastScanConfirmation
                )
            }
        }
    }

    func scheduleStopConfirmation() {
        stopConfirmationID &+= 1
        let confirmationID = stopConfirmationID
        hasPendingStopConfirmation = true
        let generation = controlGeneration
        refreshScheduler.scheduleStopConfirmation { [weak self] in
            guard let self else { return }
            let completed = await self.performStatusRefresh(
                expectedControlGeneration: generation
            )
            guard completed,
                  generation == self.controlGeneration,
                  confirmationID == self.stopConfirmationID else { return }
            self.hasPendingStopConfirmation = false
        }
    }

    func scheduleLastScanConfirmation() {
        lastScanConfirmationID &+= 1
        let confirmationID = lastScanConfirmationID
        hasPendingLastScanConfirmation = true
        let generation = controlGeneration
        refreshScheduler.scheduleLastScanConfirmation { [weak self] in
            guard let self else { return }
            let completed = await self.performStatusRefresh(
                expectedControlGeneration: generation
            )
            guard completed,
                  generation == self.controlGeneration,
                  confirmationID == self.lastScanConfirmationID else { return }
            self.hasPendingLastScanConfirmation = false
        }
    }

    private func beginControlOperation() -> UInt64 {
        cancelScheduledConfirmations()
        controlGeneration &+= 1
        latestStatusReadID &+= 1
        isRefreshing = false
        return controlGeneration
    }

    private func cancelScheduledConfirmations() {
        refreshScheduler.cancelAll()
        stopConfirmationID &+= 1
        lastScanConfirmationID &+= 1
        hasPendingStopConfirmation = false
        hasPendingLastScanConfirmation = false
    }

    private func performStatusRefresh(
        expectedControlGeneration: UInt64
    ) async -> Bool {
        guard expectedControlGeneration == controlGeneration,
              !isControlInFlight else { return false }
        latestStatusReadID &+= 1
        let readID = latestStatusReadID
        do {
            let refreshed = try await statusRequest()
            guard expectedControlGeneration == controlGeneration,
                  readID == latestStatusReadID else { return false }
            status = refreshed
            requestError = nil
            if refreshed.state == .closed {
                isShuttingDown = false
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard expectedControlGeneration == controlGeneration,
                  readID == latestStatusReadID else { return false }
            let message = error.localizedDescription
            requestError = message
            return true
        }
    }

    private func finishStart(
        result: Result<ChekinanaScannerRuntimeStatus, Error>,
        token: UInt64
    ) {
        guard token == controlGeneration else { return }
        startTask = nil
        isStarting = false
        switch result {
        case .success(let result):
            status = result
            requestError = nil
        case .failure(let error):
            if error is CancellationError { return }
            let message = error.localizedDescription
            status = .init(
                ok: false,
                state: .closed,
                phase: "closed",
                message: message,
                retryAllowed: true,
                canStart: true,
                canTerminate: false
            )
            requestError = message
        }
    }

    private func acceptStartUpdate(
        _ update: ChekinanaScannerRuntimeStatus,
        token: UInt64
    ) {
        guard token == controlGeneration,
              isStarting,
              update.state == .preparing else { return }
        status = update
        requestError = nil
    }

    private func finishStop(
        result: Result<ChekinanaScannerRuntimeStatus, Error>,
        token: UInt64,
        restoresLastScanConfirmation: Bool
    ) {
        guard token == controlGeneration else { return }
        stopTask = nil
        isStopping = false
        switch result {
        case .success(let result):
            status = result
            requestError = nil
            if result.ok {
                isShuttingDown = true
                cancelScheduledConfirmations()
                scheduleStopConfirmation()
            } else {
                isShuttingDown = false
                if restoresLastScanConfirmation {
                    scheduleLastScanConfirmation()
                }
            }
        case .failure(let error):
            isShuttingDown = false
            if !(error is CancellationError) {
                let message = error.localizedDescription
                status = .clientUnavailable(message: message)
                requestError = message
            }
            if restoresLastScanConfirmation {
                scheduleLastScanConfirmation()
            }
        }
    }
}

@MainActor
final class ChekinanaScannerRuntimeRefreshScheduler {
    // Worker shutdown deadlines plus one 20-second confirmation buffer.
    static let stopConfirmationDelayNanoseconds: UInt64 = 40_000_000_000
    static let lastScanConfirmationDelayNanoseconds: UInt64 = 140_000_000_000

    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private let sleeper: Sleeper
    private var stopConfirmationTask: Task<Void, Never>?
    private var lastScanConfirmationTask: Task<Void, Never>?

    init(
        sleeper: @escaping Sleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.sleeper = sleeper
    }

    func scheduleStopConfirmation(
        action: @escaping @MainActor @Sendable () async -> Void
    ) {
        stopConfirmationTask?.cancel()
        stopConfirmationTask = scheduledTask(
            delayNanoseconds: Self.stopConfirmationDelayNanoseconds,
            action: action
        )
    }

    func scheduleLastScanConfirmation(
        action: @escaping @MainActor @Sendable () async -> Void
    ) {
        lastScanConfirmationTask?.cancel()
        lastScanConfirmationTask = scheduledTask(
            delayNanoseconds: Self.lastScanConfirmationDelayNanoseconds,
            action: action
        )
    }

    func cancelAll() {
        stopConfirmationTask?.cancel()
        lastScanConfirmationTask?.cancel()
        stopConfirmationTask = nil
        lastScanConfirmationTask = nil
    }

    private func scheduledTask(
        delayNanoseconds: UInt64,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let sleeper = sleeper
        return Task { @MainActor in
            do {
                try await sleeper(delayNanoseconds)
                try Task.checkCancellation()
                await action()
            } catch {
                // A newer completion of the same kind supersedes this one.
            }
        }
    }
}

enum ChekinanaGPUControlAction: Equatable {
    case start
    case terminate
    case none
}

enum ChekinanaGPUStatusPresentation {
    static func preparingTitle(
        status: ChekinanaScannerRuntimeStatus?
    ) -> String {
        guard let progress = status?.progress else {
            return ChekinanaProductCopy.text(
                "settings.runtime.preparing",
                "Preparing"
            )
        }
        return ChekinanaProductCopy.format(
            "settings.runtime.preparing_progress",
            "Preparing %lld/%lld",
            Int64(progress.current),
            Int64(progress.total)
        )
    }

    static func visibleState(
        status: ChekinanaScannerRuntimeStatus?,
        isRefreshing: Bool
    ) -> ChekinanaScannerRuntimeState {
        // A GET never changes the presentation until its response is accepted.
        status?.state ?? .closed
    }

    static func controlAction(
        status: ChekinanaScannerRuntimeStatus?,
        isRefreshing: Bool
    ) -> ChekinanaGPUControlAction {
        guard !isRefreshing, let status else { return .none }
        switch status.state {
        case .closed:
            return status.canStart ? .start : .none
        case .preparing:
            return .none
        case .ready:
            return status.canTerminate ? .terminate : .none
        }
    }

    static func allowsGPUInput(
        _ status: ChekinanaScannerRuntimeStatus?,
        isControlInFlight: Bool = false
    ) -> Bool {
        status?.state == .ready && !isControlInFlight
    }

    static func showsPreparationProgress(
        visibleState: ChekinanaScannerRuntimeState,
        isStarting: Bool,
        isShuttingDown: Bool
    ) -> Bool {
        !isShuttingDown && (isStarting || visibleState == .preparing)
    }

    static func message(
        status: ChekinanaScannerRuntimeStatus?,
        requestError: String?
    ) -> String? {
        if status?.error == "temporary_pod_create_failed" {
            return "GPU out of capacity, try later"
        }
        let statusMessage = status?.message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let status,
           let statusMessage,
           !statusMessage.isEmpty,
           status.state == .closed || !status.ok {
            return statusMessage
        }
        let requestMessage = requestError?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return requestMessage?.isEmpty == false
            ? requestMessage
            : nil
    }
}

enum ChekinanaScanGPUPreflightDecision: Equatable {
    case allowAll
    case allowDirectOnly
    case blockGPUOnly
    case blockMixed
}

enum ChekinanaScanGPUPreflight {
    static func decision(
        status: ChekinanaScannerRuntimeStatus?,
        hasGPUInput: Bool,
        hasDirectInput: Bool,
        isControlInFlight: Bool = false
    ) -> ChekinanaScanGPUPreflightDecision {
        if status?.state == .ready && !isControlInFlight { return .allowAll }
        if hasGPUInput && hasDirectInput { return .blockMixed }
        if hasGPUInput { return .blockGPUOnly }
        return .allowDirectOnly
    }
}

enum ChekinanaScanStartRuntimeGate {
    static func allowsStart(
        hasGPUInput: Bool,
        gpuInputsEnabled: Bool
    ) -> Bool {
        !hasGPUInput || gpuInputsEnabled
    }
}

private struct ChekinanaScanTaskProgress {
    var imageCompleted = 0
    var imageTotal = 0
    var dateCompleted = 0
    var dateTotal = 0
    var idolCompleted = 0
    var idolTotal = 0
}

private struct ChekinanaStagedImport {
    let fileURL: URL
    let sourceID: UUID?
    let sourceOrigin: ChekinanaScanSourceOrigin
    let inferredSize: ChekiSize?
    let pixelWidth: Int
    let pixelHeight: Int
}

private enum ChekinanaImportStaging {
    static func createSessionDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekinanaImportStage", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func writeJPEG(_ data: Data, in directory: URL) throws -> URL {
        guard !data.isEmpty, data.count <= 32 * 1_024 * 1_024 else {
            throw ChekinanaLocalImportChekiError.renderFailed
        }
        let url = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        return url
    }

    static func removeSessionDirectory(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ChekinanaImportPipelineCoordinator {
    private var recognized = Set<Int>()

    func waitUntilResultCanPublish(at index: Int) async throws {
        while index > 0 && !recognized.contains(index - 1) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func markRecognized(_ index: Int) {
        recognized.insert(index)
    }
}

private struct ChekinanaScanView: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Idol.name) private var idols: [Idol]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let openMenu: () -> Void

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var importedChekiItems: [PhotosPickerItem] = []
    @State private var scanInputs: [ChekinanaNativeScanInput] = []
    @State private var isCameraPresented = false
    @State private var dateRecognitionEnabled = true
    @State private var declaresFixedDate = false
    @State private var declaresDateRange = false
    @State private var fixedDate = Date()
    @State private var dateRangeFrom = Calendar.current.date(
        byAdding: .month,
        value: -1,
        to: Date()
    ) ?? Date()
    @State private var dateRangeTo = Date()
    @State private var idolRecognitionEnabled = ChekinanaScanInitialConfiguration.idolRecognitionEnabled
    @State private var sleevesEnabled = false
    @State private var candidateSelection = ChekinanaCandidateSelectionState()
    @State private var includesUnassigned = false
    @State private var idolSimilarityThreshold = Double(
        ChekinanaPatternClassifier.unassignedThreshold
    )
    @State private var isCandidatePickerPresented = false
    @State private var isProcessing = false
    @State private var taskProgress = ChekinanaScanTaskProgress()
    @State private var processingTask: Task<Void, Never>?
    @State private var processingGeneration = UUID()
    @State private var inputRotationRegistry = ChekinanaNativeScanInputRotationRegistry()
    @State private var activeScannerTaskIDs = Set<String>()
    @State private var imageLoadFailureCount = 0
    @State private var cancellationMessage: String?
    @State private var activeImportStagingDirectory: URL?
    @State private var errorMessage: String?
    @State private var reviewCards: [ChekinanaChekiCard] = []
    @State private var reviewSourceRegistry = ChekinanaScanReviewSourceRegistry()
    @State private var hasReviewSession = false
    @State private var reviewWarningCount = 0
    @State private var isReviewPresented = false
    @State private var confirmationLedger = ChekinanaConfirmationLedger()
    @State private var didAutoStartFixtureReview = false
    @State private var didSeedInputFixture = false
    @StateObject private var runtimePresentation =
        ChekinanaScannerRuntimePresentationStore.shared

    private var patternIdols: [Idol] {
        idols.filter {
            $0.hasRecognitionPatterns
                && ChekinanaVisibilityPolicy.includesIdol(
                    $0.id,
                    hiddenIDs: hiddenIdols.hiddenIDs
                )
        }
    }

    private var patternEligibilityKey: String {
        patternIdols
            .map { $0.id.uuidString.lowercased() }
            .sorted()
            .joined(separator: ";")
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    gpuStatusCard
                    photoCard
                    recognitionCard
                    if hasReviewSession {
                        Button {
                            isReviewPresented = true
                        } label: {
                            Label("Resume \(reviewCards.count) temporary Cheki", systemImage: "rectangle.stack")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("chekinana.scan.resume-review")
                    }
                    startButton
                    if let cancellationMessage {
                        Text(cancellationMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chekinana.scan.canceled")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle(ChekinanaProductTab.scan.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ChekinanaPageToolbar(pageID: "scan", openMenu: openMenu) }
            .sheet(isPresented: $isCandidatePickerPresented) {
                ChekinanaCandidatePicker(
                    idols: patternIdols,
                    selectedIDs: $candidateSelection.selectedIDs,
                    includesUnassigned: $includesUnassigned,
                    similarityThreshold: $idolSimilarityThreshold
                )
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $isReviewPresented) {
                ChekinanaNativeScanReview(
                    cards: $reviewCards,
                    sourceRegistry: $reviewSourceRegistry,
                    warningCount: reviewWarningCount,
                    ledger: confirmationLedger,
                    onDeleteSource: { sourceID in
                        removeInput(sourceID: sourceID, allowReviewSourceRemoval: true)
                    },
                    onSaved: { sourceIDs in
                        removeInputs(
                            sourceIDs: Set(sourceIDs),
                            allowReviewSourceRemoval: true
                        )
                        hasReviewSession = false
                        reviewSourceRegistry = ChekinanaScanReviewSourceRegistry()
                        reviewWarningCount = 0
                        isReviewPresented = false
                    },
                    onDiscarded: { sourceIDs in
                        discardCurrentScanSession(sourceIDs: sourceIDs)
                    },
                    onClose: { isReviewPresented = false }
                )
            }
            .fullScreenCover(isPresented: $isCameraPresented) {
                ChekinanaCameraCaptureView { capture in
                    guard inputRotationRegistry.allowsInputMutation(
                        isProcessing: isProcessing,
                        hasReviewSession: hasReviewSession
                    ) else {
                        ChekinanaCapturedPhotoStore.remove(capture.photo)
                        return
                    }
                    scanInputs.append(ChekinanaNativeScanInput(
                        id: capture.id,
                        payload: .camera(capture.photo)
                    ))
                }
            }
            .alert("Scan unavailable", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .overlay {
                if isProcessing {
                    ZStack {
                        Color.black.opacity(0.18).ignoresSafeArea()
                        scanProgressCard
                        .padding(20)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .accessibilityIdentifier("chekinana.scan.processing")
                }
            }
        }
        .onAppear {
            let validIDs = Set(patternIdols.map(\.id))
            candidateSelection.reconcile(validIDs: validIDs)
        }
        .onChange(of: patternEligibilityKey) { _, _ in
            let validIDs = Set(patternIdols.map(\.id))
            candidateSelection.reconcile(validIDs: validIDs)
            retireHiddenReviewTemporaries()
        }
        .onChange(of: selectedItems) { _, items in
            reconcileLibraryInputs(items, isDirect: false)
        }
        .onChange(of: importedChekiItems) { _, items in
            reconcileLibraryInputs(items, isDirect: true)
        }
        .onChange(of: declaresFixedDate) { _, enabled in
            if enabled { declaresDateRange = false }
        }
        .onChange(of: declaresDateRange) { _, enabled in
            if enabled { declaresFixedDate = false }
        }
        .task {
            seedInputFixtureIfNeeded()
            guard ChekinanaScanInitialConfiguration.autoStartsFixtureReview,
                  !didAutoStartFixtureReview else { return }
            didAutoStartFixtureReview = true
            beginNativeScan()
            await processingTask?.value
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.scan.page")
        .chekinanaScreenMarker("chekinana.scan.page")
    }

    private func seedInputFixtureIfNeeded() {
#if DEBUG
        guard ChekinanaScanInitialConfiguration.seedsInputFixture,
              !didSeedInputFixture else { return }
        didSeedInputFixture = true
        for pending in ChekinanaMediaUITestFixture.pendingChekiImages().prefix(2) {
            let id = UUID()
            guard let photo = try? ChekinanaCapturedPhotoStore.save(
                pending.data,
                filenameExtension: pending.filenameExtension,
                id: id
            ) else { continue }
            scanInputs.append(ChekinanaNativeScanInput(
                id: id,
                payload: .camera(photo)
            ))
        }
#endif
    }

    private var gpuStatusCard: some View {
        ChekinanaSectionCard {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled
                    ? runtimeStatusIcon
                    : "pause.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled
                        ? runtimeStatusColor
                        : Color.secondary)
                    .frame(width: 38, height: 38)
                    .background((ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled
                        ? runtimeStatusColor
                        : Color.secondary).opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled
                        ? "GPU · \(runtimeStatusTitle)"
                        : "GPU management paused")
                        .font(.headline)
                    if !ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled {
                        Text("Camera and Photos are temporarily unavailable. Import Cheki remains available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let gpuStatusMessage {
                        Text(gpuStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled {
                    Button {
                        Task { await runtimePresentation.refreshManually() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .frame(width: 36, height: 36)
                    .buttonStyle(.bordered)
                    .disabled(
                        runtimePresentation.isRefreshing
                            || runtimePresentation.isControlInFlight
                    )
                    .accessibilityLabel("Refresh GPU status")
                    .accessibilityIdentifier("chekinana.scan.gpu.refresh")

                    if runtimePresentation.isStarting {
                        Button("Cancel", role: .cancel) {
                            runtimePresentation.cancelStart()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("chekinana.scan.gpu.cancel-start")
                    } else {
                        switch gpuControlAction {
                        case .terminate:
                            Button("Terminate", role: .destructive) {
                                runtimePresentation.requestStop()
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("chekinana.scan.gpu.terminate")
                        case .start:
                            Button("Start") {
                                runtimePresentation.requestStart()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ChekinanaProductTheme.accent)
                            .accessibilityIdentifier("chekinana.scan.gpu.start")
                        case .none:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(runtimeStatusTitle)
        .accessibilityIdentifier("chekinana.scan.gpu.status")
    }

    private var runtimeStatusTitle: String {
        if runtimePresentation.status == nil { return "Unknown" }
        if runtimePresentation.isShuttingDown { return "Shutting down" }
        return switch visibleGPUState {
        case .closed: "Offline"
        case .preparing:
            ChekinanaGPUStatusPresentation.preparingTitle(
                status: runtimePresentation.status
            )
        case .ready: "Ready"
        }
    }

    private var runtimeStatusIcon: String {
        if runtimePresentation.status == nil { return "questionmark.circle" }
        if runtimePresentation.isShuttingDown { return "power.circle.fill" }
        return switch visibleGPUState {
        case .closed: "power"
        case .preparing: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        }
    }

    private var runtimeStatusColor: Color {
        if runtimePresentation.status == nil { return .secondary }
        if runtimePresentation.isShuttingDown { return .orange }
        return switch visibleGPUState {
        case .closed: .secondary
        case .preparing: .orange
        case .ready: .green
        }
    }

    private var visibleGPUState: ChekinanaScannerRuntimeState {
        ChekinanaGPUStatusPresentation.visibleState(
            status: runtimePresentation.status,
            isRefreshing: runtimePresentation.isRefreshing
                || runtimePresentation.isControlInFlight
        )
    }

    private var gpuControlAction: ChekinanaGPUControlAction {
        ChekinanaGPUStatusPresentation.controlAction(
            status: runtimePresentation.status,
            isRefreshing: runtimePresentation.isRefreshing
                || runtimePresentation.isControlInFlight
                || runtimePresentation.isShuttingDown
        )
    }

    private var gpuInputsEnabled: Bool {
        ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled
            && ChekinanaGPUStatusPresentation.allowsGPUInput(
                runtimePresentation.status,
                isControlInFlight: runtimePresentation.blocksGPUInput
            )
    }

    private var hasGPUInput: Bool {
        scanInputs.contains { !$0.isDirect }
    }

    private var hasImportChekiInput: Bool {
        scanInputs.contains(where: \.isDirect)
    }

    private var showsSleevesOption: Bool {
        visibleGPUState == .ready
            && !runtimePresentation.blocksGPUInput
            && !hasImportChekiInput
    }

    private var gpuStatusMessage: String? {
        ChekinanaGPUStatusPresentation.message(
            status: runtimePresentation.status,
            requestError: runtimePresentation.requestError
        )
    }

    private var photoCard: some View {
        ChekinanaSectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Input photos").font(.headline)
                    if !scanInputs.isEmpty {
                        Text("\(scanInputs.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !scanInputs.isEmpty {
                        Button("Clear") { clearInputs() }
                            .font(.subheadline.weight(.medium))
                            .disabled(
                                !inputRotationRegistry.allowsInputMutation(
                                    isProcessing: isProcessing,
                                    hasReviewSession: hasReviewSession
                                )
                            )
                            .accessibilityIdentifier("chekinana.scan.clear")
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button { isCameraPresented = true } label: {
                            InputSourceButton(
                                title: "Camera",
                                subtitle: "Take a photo",
                                systemImage: "camera"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            !inputRotationRegistry.allowsInputMutation(
                                isProcessing: isProcessing,
                                hasReviewSession: hasReviewSession
                            ) || !gpuInputsEnabled || hasImportChekiInput
                        )
                        .accessibilityIdentifier("chekinana.scan.camera")

                        PhotosPicker(
                            selection: $selectedItems,
                            maxSelectionCount: 0,
                            selectionBehavior: .ordered,
                            matching: .images,
                            preferredItemEncoding: .current
                        ) {
                            InputSourceButton(
                                title: "Photos",
                                subtitle: "Choose from library",
                                systemImage: "photo.badge.plus"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            !inputRotationRegistry.allowsInputMutation(
                                isProcessing: isProcessing,
                                hasReviewSession: hasReviewSession
                            ) || !gpuInputsEnabled || hasImportChekiInput
                        )
                        .accessibilityIdentifier("chekinana.scan.photos")

                        PhotosPicker(
                            selection: $importedChekiItems,
                            maxSelectionCount: 0,
                            selectionBehavior: .ordered,
                            matching: .images,
                            preferredItemEncoding: .current
                        ) {
                            InputSourceButton(
                                title: "Import Cheki",
                                subtitle: "Skip extraction",
                                systemImage: "rectangle.portrait.and.arrow.forward"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            !inputRotationRegistry.allowsInputMutation(
                                isProcessing: isProcessing,
                                hasReviewSession: hasReviewSession
                            ) || hasGPUInput
                        )
                        .accessibilityIdentifier("chekinana.scan.import-cheki")
                    }
                }

                if !gpuInputsEnabled {
                    Text("Camera and Photos require GPU Ready. Import Cheki remains available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !scanInputs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(scanInputs) { input in
                                ChekinanaSelectedPhotoThumbnail(
                                    input: input,
                                    isRotationDisabled: hasReviewSession || isProcessing,
                                    isDeleteDisabled: !inputRotationRegistry.allowsInputMutation(
                                        isProcessing: isProcessing,
                                        hasReviewSession: hasReviewSession
                                    ),
                                    isRotationInFlight: inputRotationRegistry
                                        .isRotating(sourceID: input.id),
                                    onRotationBegan: {
                                        beginInputRotation(
                                            sourceID: input.id,
                                            expectedQuarterTurns: input.rotationQuarterTurns
                                        )
                                    },
                                    onRotationCompleted: { token, quarterTurns in
                                        completeInputRotation(
                                            sourceID: input.id,
                                            token: token,
                                            quarterTurns: quarterTurns
                                        )
                                    },
                                    onRotationFailed: { token, showsError in
                                        failInputRotation(
                                            sourceID: input.id,
                                            token: token,
                                            showsError: showsError
                                        )
                                    },
                                    onDelete: { removeInput(sourceID: input.id) }
                                )
                            }
                        }
                    }
                    .frame(height: 88)
                }
            }
        }
    }

    private var recognitionCard: some View {
        ChekinanaSectionCard {
            VStack(spacing: 0) {
                recognitionToggle(
                    title: "Recognize date",
                    systemImage: "calendar.badge.clock",
                    isOn: $dateRecognitionEnabled,
                    identifier: "chekinana.scan.date-recognition"
                )
                if dateRecognitionEnabled {
                    Divider().padding(.leading, 46)
                    dateDeclarationControls
                }
                Divider().padding(.leading, 46)
                recognitionToggle(
                    title: "Recognize Idol",
                    systemImage: "person.crop.rectangle.stack",
                    isOn: $idolRecognitionEnabled,
                    identifier: "chekinana.scan.idol-recognition"
                )

                if idolRecognitionEnabled {
                    Divider().padding(.leading, 46)
                    Button { isCandidatePickerPresented = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "scope")
                                .foregroundStyle(ChekinanaProductTheme.accent)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Candidate range")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(candidateSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chekinana.scan.candidates")
                }
                if showsSleevesOption {
                    Divider().padding(.leading, 46)
                    recognitionToggle(
                        title: "Sleeves",
                        systemImage: "rectangle.on.rectangle",
                        isOn: $sleevesEnabled,
                        identifier: "chekinana.scan.sleeves"
                    )
                }
            }
        }
    }

    private var dateDeclarationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Fixed date", isOn: $declaresFixedDate)
                .frame(minHeight: 44)
                .accessibilityIdentifier("chekinana.scan.date-scope.fixed")
            if declaresFixedDate {
                DatePicker("Date", selection: $fixedDate, displayedComponents: .date)
                    .accessibilityIdentifier("chekinana.scan.date-fixed")
            }
            Toggle("Date range", isOn: $declaresDateRange)
                .frame(minHeight: 44)
                .accessibilityIdentifier("chekinana.scan.date-scope.range")
            if declaresDateRange {
                DatePicker("From", selection: $dateRangeFrom, displayedComponents: .date)
                    .accessibilityIdentifier("chekinana.scan.date-range-from")
                    .onChange(of: dateRangeFrom) { _, value in
                        if value > dateRangeTo { dateRangeTo = value }
                    }
                DatePicker(
                    "To",
                    selection: $dateRangeTo,
                    in: dateRangeFrom...Date.distantFuture,
                    displayedComponents: .date
                )
                .accessibilityIdentifier("chekinana.scan.date-range-to")
            }
        }
        .padding(.leading, 46)
        .padding(.vertical, 10)
    }

    private struct InputSourceButton: View {
        let title: String
        let subtitle: String
        let systemImage: String

        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .light))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(ChekinanaProductTheme.accent.opacity(0.78))
                    .lineLimit(1)
            }
            .foregroundStyle(ChekinanaProductTheme.accent)
            .frame(width: 148, height: 120)
            .background(ChekinanaProductTheme.softAccent.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        ChekinanaProductTheme.accent.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1, dash: [6])
                    )
            }
        }
    }

    private func reconcileLibraryInputs(
        _ items: [PhotosPickerItem],
        isDirect: Bool
    ) {
        guard inputRotationRegistry.allowsInputMutation(
            isProcessing: isProcessing,
            hasReviewSession: hasReviewSession
        ) else {
            restoreLibraryPickerSelection(isDirect: isDirect)
            return
        }
        if isDirect, hasGPUInput {
            importedChekiItems = []
            return
        }
        if !isDirect, hasImportChekiInput {
            selectedItems = []
            return
        }
        let existingLibrary = scanInputs.compactMap { input -> (UUID, PhotosPickerItem)? in
            guard input.isDirect == isDirect,
                  let item = input.libraryItem else { return nil }
            return (input.id, item)
        }
        var retainedIDs = Set<UUID>()
        for item in items {
            if let existing = existingLibrary.first(where: { _, candidate in
                if let identifier = item.itemIdentifier,
                   let candidateIdentifier = candidate.itemIdentifier {
                    return identifier == candidateIdentifier
                }
                return item == candidate
            }) {
                retainedIDs.insert(existing.0)
            } else {
                let id = UUID()
                retainedIDs.insert(id)
                scanInputs.append(ChekinanaNativeScanInput(
                    id: id,
                    payload: .library(item),
                    isDirect: isDirect
                ))
            }
        }
        scanInputs = ChekinanaNativeScanInputReconciler.retainedInputs(
            existing: scanInputs,
            retainedIDs: retainedIDs,
            origin: .library,
            isDirect: isDirect
        )
    }

    private func restoreLibraryPickerSelection(isDirect: Bool) {
        let retained = scanInputs.compactMap { input -> PhotosPickerItem? in
            guard input.isDirect == isDirect else { return nil }
            return input.libraryItem
        }
        if isDirect {
            if importedChekiItems != retained { importedChekiItems = retained }
        } else if selectedItems != retained {
            selectedItems = retained
        }
    }

    private func removeInput(
        sourceID: UUID,
        allowReviewSourceRemoval: Bool = false
    ) {
        guard !isProcessing,
              !inputRotationRegistry.hasInFlightRotations,
              !hasReviewSession || allowReviewSourceRemoval else { return }
        guard let input = scanInputs.first(where: { $0.id == sourceID }) else { return }
        if let photo = input.capturedPhoto {
            ChekinanaCapturedPhotoStore.remove(photo)
        }
        if let item = input.libraryItem {
            let removeItem: (inout [PhotosPickerItem]) -> Void = { items in
                items.removeAll { selected in
                    if let identifier = item.itemIdentifier,
                       let selectedIdentifier = selected.itemIdentifier {
                        return identifier == selectedIdentifier
                    }
                    return item == selected
                }
            }
            if input.isDirect {
                removeItem(&importedChekiItems)
            } else {
                removeItem(&selectedItems)
            }
        }
        scanInputs.removeAll { $0.id == sourceID }
    }

    private func beginInputRotation(
        sourceID: UUID,
        expectedQuarterTurns: Int
    ) -> UUID? {
        guard !hasReviewSession,
              !isProcessing,
              let index = scanInputs.firstIndex(where: { $0.id == sourceID }),
              scanInputs[index].rotationQuarterTurns == expectedQuarterTurns else {
            return nil
        }
        return inputRotationRegistry.begin(
            sourceID: sourceID,
            expectedQuarterTurns: expectedQuarterTurns
        )
    }

    private func completeInputRotation(
        sourceID: UUID,
        token: UUID,
        quarterTurns: Int
    ) -> Bool {
        guard let index = scanInputs.firstIndex(where: { $0.id == sourceID }),
              inputRotationRegistry.commit(
                sourceID: sourceID,
                token: token,
                currentQuarterTurns: scanInputs[index].rotationQuarterTurns,
                newQuarterTurns: quarterTurns
              ) else {
            return false
        }
        scanInputs[index].rotationQuarterTurns = ChekinanaNativeScanInput
            .normalizedQuarterTurns(quarterTurns)
        return true
    }

    private func failInputRotation(
        sourceID: UUID,
        token: UUID,
        showsError: Bool
    ) {
        guard inputRotationRegistry.fail(sourceID: sourceID, token: token) else { return }
        if showsError {
            errorMessage = ChekinanaProductCopy.text(
                "scan.input.rotate_failed",
                "Couldn't rotate this input photo. The original is unchanged."
            )
        }
    }

    private func removeInputs(
        sourceIDs: Set<UUID>,
        allowReviewSourceRemoval: Bool = false
    ) {
        for sourceID in sourceIDs {
            removeInput(
                sourceID: sourceID,
                allowReviewSourceRemoval: allowReviewSourceRemoval
            )
        }
    }

    private func clearInputs(allowReviewSession: Bool = false) {
        guard !isProcessing,
              !inputRotationRegistry.hasInFlightRotations,
              !hasReviewSession || allowReviewSession else { return }
        for input in scanInputs {
            if let photo = input.capturedPhoto {
                ChekinanaCapturedPhotoStore.remove(photo)
            }
        }
        scanInputs = []
        selectedItems = []
        importedChekiItems = []
    }

    private func discardCurrentScanSession(sourceIDs: [UUID]) {
        processingGeneration = UUID()
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        ChekinanaImportStaging.removeSessionDirectory(activeImportStagingDirectory)
        activeImportStagingDirectory = nil
        for sourceID in Set(sourceIDs).union(reviewSourceRegistry.sourceIDs) {
            _ = confirmationLedger.discardTemporaryChekis(sourceID: sourceID)
        }
        for card in reviewCards {
            _ = confirmationLedger.discardTemporaryCheki(id: card.id)
        }
        clearInputs(allowReviewSession: true)
        reviewCards = []
        reviewSourceRegistry = ChekinanaScanReviewSourceRegistry()
        hasReviewSession = false
        reviewWarningCount = 0
        isReviewPresented = false
        taskProgress = ChekinanaScanTaskProgress()
        imageLoadFailureCount = 0
        activeScannerTaskIDs.removeAll()
        cancellationMessage = nil
        errorMessage = nil
        confirmationLedger = ChekinanaConfirmationLedger()
    }

    private func retireHiddenReviewTemporaries() {
        let hiddenCardIDs = ChekinanaHiddenTemporaryReviewPolicy.hiddenCardIDs(
            reviewCards,
            hiddenIdolIDs: hiddenIdols.hiddenIDs,
            idolIDs: { confirmationLedger.temporaryCheki($0)?.idolIDs }
        )
        guard !hiddenCardIDs.isEmpty else { return }
        for id in hiddenCardIDs {
            _ = confirmationLedger.discardTemporaryCheki(id: id)
        }
        // Pending confirmation can temporarily lock its ledger object, but it
        // must disappear from UI immediately. Final write resolution rejects a
        // hidden Idol even if that confirmation was already in flight.
        reviewCards.removeAll { hiddenCardIDs.contains($0.id) }
    }

    private func recognitionToggle(
        title: String,
        systemImage: String,
        isOn: Binding<Bool>,
        identifier: String
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(ChekinanaProductTheme.accent)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 38)
                Text(title).font(.headline)
            }
        }
        .frame(minHeight: 56)
        .accessibilityIdentifier(identifier)
    }

    private var candidateSummary: String {
        let idolCount = candidateSelection.selectedIDs.count
        if patternIdols.isEmpty {
            return includesUnassigned ? "Unassigned only · no stored patterns" : "No usable candidates"
        }
        return "\(idolCount) Idol\(idolCount == 1 ? "" : "s")\(includesUnassigned ? " + Unassigned" : "")"
    }

    private var canStart: Bool {
        (!scanInputs.isEmpty || nativeFixtureEnabled)
            && !hasReviewSession
            && !inputRotationRegistry.hasInFlightRotations
            && ChekinanaScanStartRuntimeGate.allowsStart(
                hasGPUInput: scanInputs.contains(where: { !$0.isDirect }),
                gpuInputsEnabled: gpuInputsEnabled
            )
            && (!dateRecognitionEnabled || scannerDateBounds != nil)
            && (!idolRecognitionEnabled || !candidateSelection.selectedIDs.isEmpty || includesUnassigned)
    }

    private var scannerDateBounds: ChekinanaScannerDateBounds? {
        guard dateRecognitionEnabled else { return nil }
        if declaresFixedDate {
            return ChekinanaScannerDateBounds.fixed(fixedDate)
        }
        if declaresDateRange {
            return ChekinanaScannerDateBounds.range(
                from: dateRangeFrom,
                to: dateRangeTo
            )
        }
        return ChekinanaScannerDateBounds.recent(relativeTo: Date())
    }

    private var nativeFixtureEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["CHEKINANA_NATIVE_SCAN_UI_STUB"] == "fixture"
#else
        false
#endif
    }

    private var startButton: some View {
        Button {
            beginNativeScan()
        } label: {
            Label("Start scan", systemImage: "viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(ChekinanaProductTheme.accent)
        .disabled(!canStart || isProcessing || inputRotationRegistry.hasInFlightRotations)
        .accessibilityHint("直接处理已选照片并显示可编辑的临时 Cheki")
        .accessibilityIdentifier("chekinana.scan.start")
    }

    private var scanProgressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            scanProgressRow(
                title: "Image process",
                completed: taskProgress.imageCompleted,
                total: taskProgress.imageTotal
            )
            if dateRecognitionEnabled || idolRecognitionEnabled {
                Text("Recognition")
                    .font(.headline)
                if dateRecognitionEnabled {
                    scanProgressRow(
                        title: "Date",
                        completed: taskProgress.dateCompleted,
                        total: taskProgress.dateTotal
                    )
                }
                if idolRecognitionEnabled {
                    scanProgressRow(
                        title: "Idol",
                        completed: taskProgress.idolCompleted,
                        total: taskProgress.idolTotal
                    )
                }
            }
            Button("Cancel", role: .cancel, action: cancelNativeScan)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chekinana.scan.cancel")
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private func scanProgressRow(
        title: String,
        completed: Int,
        total: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(completed)/\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                    Rectangle()
                        .fill(ChekinanaProductTheme.accent)
                        .frame(width: geometry.size.width * progressFraction(
                            completed: completed,
                            total: total
                        ))
                }
            }
            .frame(height: 3)
            .clipShape(Capsule())
        }
    }

    private func progressFraction(completed: Int, total: Int) -> CGFloat {
        guard total > 0 else { return 0 }
        return min(max(CGFloat(completed) / CGFloat(total), 0), 1)
    }

    @MainActor
    private func beginNativeScan() {
        guard processingTask == nil,
              !isProcessing,
              !hasReviewSession,
              !inputRotationRegistry.hasInFlightRotations else { return }
        let generation = UUID()
        processingGeneration = generation
        isProcessing = true
        cancellationMessage = nil
        activeScannerTaskIDs.removeAll()
        imageLoadFailureCount = 0
        reviewCards = []
        reviewWarningCount = 0
        taskProgress = ChekinanaScanTaskProgress(
            imageTotal: nativeFixtureEnabled ? 1 : scanInputs.count
        )
        processingTask = Task { @MainActor in
            await startNativeScan(generation: generation)
        }
    }

    @MainActor
    private func cancelNativeScan() {
        guard isProcessing else { return }
        let taskIDs = activeScannerTaskIDs
        processingGeneration = UUID()
        processingTask?.cancel()
        processingTask = nil
        activeScannerTaskIDs.removeAll()
        isProcessing = false
        ChekinanaImportStaging.removeSessionDirectory(activeImportStagingDirectory)
        activeImportStagingDirectory = nil
        cancellationMessage = "Canceled"
        if !reviewCards.isEmpty {
            hasReviewSession = true
            isReviewPresented = true
        }
        for taskID in taskIDs {
            Task {
                try? await ChekinanaScannerClient().cancel(taskID: taskID)
            }
        }
    }

    @MainActor
    private func startNativeScan(generation: UUID) async {
        defer {
            if processingGeneration == generation {
                isProcessing = false
                processingTask = nil
                activeScannerTaskIDs.removeAll()
            }
        }
        let dateBounds = scannerDateBounds
        guard !dateRecognitionEnabled || dateBounds != nil else {
            errorMessage = "日期范围无效，请重新选择。"
            return
        }
        let validIDs = patternIdols.map(\.id).filter(candidateSelection.selectedIDs.contains)
        func preparedCommand(direct: Bool) -> String? {
            let preparation = ChekinanaScannerConfiguration.prepareTypedCommands(
                ["scancheki"],
                baseURLResolution: nativeFixtureEnabled
                    ? .resolved(ChekinanaScannerConfiguration.productionBaseURL)
                    : ChekinanaScannerConfiguration.configuredBaseURL(),
                dateRecognitionEnabled: dateRecognitionEnabled,
                dateBounds: dateBounds,
                idolRecognitionEnabled: idolRecognitionEnabled,
                idolCandidateIDs: validIDs,
                includeUnassignedCandidate: includesUnassigned,
                idolSimilarityThreshold: Float(idolSimilarityThreshold),
                sleevesEnabled: sleevesEnabled,
                directInputEnabled: direct
            )
            guard case .ready(let commands) = preparation else {
                if case .rejected(let failure) = preparation {
                    errorMessage = failure.userMessage
                }
                return nil
            }
            return commands.first
        }
        guard let standardCommand = preparedCommand(direct: false),
              let directCommand = preparedCommand(direct: true) else { return }

        var sessionTemporaryIDs = Set<UUID>()
        do {
            let sessionInputs = scanInputs
            let sessionSources = sessionInputs.map(\.descriptor)
            let sessionRecognitionGate = ChekinanaDirectRecognitionGate()
            let sessionDateRequestGate = ChekinanaDirectDateRequestGate(limit: 8)
            let sessionBodyPoseLimiter = ChekinanaBodyPoseLimiter()
            reviewSourceRegistry = ChekinanaScanReviewSourceRegistry(sources: sessionSources)
            let hasGPUInput = sessionInputs.contains { !$0.isDirect }
            let hasDirectInput = sessionInputs.contains { $0.isDirect }
            let preflight: ChekinanaScanGPUPreflightDecision
            if !ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled {
                preflight = ChekinanaTemporaryGPUManagementPolicy.preflight(
                    hasGPUInput: hasGPUInput,
                    hasDirectInput: hasDirectInput
                )
            } else {
                // Camera and Photos use only the latest explicit/confirmed
                // runtime snapshot. Starting a scan never performs another GET.
                preflight = ChekinanaScanGPUPreflight.decision(
                    status: nativeFixtureEnabled
                        ? .localDebugReady
                        : runtimePresentation.status,
                    hasGPUInput: hasGPUInput,
                    hasDirectInput: hasDirectInput,
                    isControlInFlight: runtimePresentation.blocksGPUInput
                )
            }
            switch preflight {
            case .allowAll:
                break
            case .allowDirectOnly:
                break
            case .blockGPUOnly:
                errorMessage = ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled
                    ? "GPU is not ready. Tap Start, wait for Ready, then scan Camera or Photos."
                    : "Camera and Photos are temporarily unavailable. Use Import Cheki instead."
                return
            case .blockMixed:
                errorMessage = ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled
                    ? "GPU is not ready. Remove Camera/Photos inputs and scan Import Cheki alone, or tap Start and wait for Ready."
                    : "Camera and Photos are temporarily unavailable. Remove them and process Import Cheki alone."
                return
            }
            try Task.checkCancellation()
            guard processingGeneration == generation else { throw CancellationError() }
            var aggregatedCards: [ChekinanaChekiCard] = []
            var aggregateWarningCount = 0
            var lastFailureMessage: String?

            func protectReviewCards(
                in output: ChekinanaCommandResponse
            ) -> ChekinanaCommandResponse {
                guard case .chekiScannedCards(_, let warningCount, let cards) = output else {
                    return output
                }
                let hiddenCardIDs = ChekinanaHiddenTemporaryReviewPolicy.hiddenCardIDs(
                    cards,
                    hiddenIdolIDs: hiddenIdols.hiddenIDs,
                    idolIDs: { confirmationLedger.temporaryCheki($0)?.idolIDs }
                )
                for id in hiddenCardIDs {
                    _ = confirmationLedger.discardTemporaryCheki(id: id)
                }
                let visibleCards = cards.filter { !hiddenCardIDs.contains($0.id) }
                let ids = visibleCards.map(\.id)
                guard processingGeneration == generation, !Task.isCancelled else {
                    // The executor may finish ledger insertion after Cancel.
                    // Those late objects were never visible to the user and
                    // must not become protected, retained temporary results.
                    for id in ids {
                        _ = confirmationLedger.discardTemporaryCheki(id: id)
                    }
                    return .text("error: canceled")
                }
                confirmationLedger.protectTemporaryChekisForReview(ids)
                sessionTemporaryIDs.formUnion(ids)
                return .chekiScannedCards(
                    visibleCards.count,
                    warningCount: warningCount,
                    visibleCards
                )
            }

            func discardSessionTemporaries() {
                for id in sessionTemporaryIDs {
                    _ = confirmationLedger.discardTemporaryCheki(id: id)
                }
                sessionTemporaryIDs.removeAll()
            }

            func accumulate(_ output: ChekinanaCommandResponse, attemptedSources: Int) {
                switch output {
                case .chekiScannedCards(_, let warningCount, let cards):
                    let hiddenCardIDs = ChekinanaHiddenTemporaryReviewPolicy.hiddenCardIDs(
                        cards,
                        hiddenIdolIDs: hiddenIdols.hiddenIDs,
                        idolIDs: { confirmationLedger.temporaryCheki($0)?.idolIDs }
                    )
                    for id in hiddenCardIDs {
                        _ = confirmationLedger.discardTemporaryCheki(id: id)
                    }
                    aggregatedCards.append(contentsOf: cards.filter {
                        !hiddenCardIDs.contains($0.id)
                    })
                    aggregateWarningCount += warningCount
                    guard processingGeneration == generation else { return }
                    reviewCards = aggregatedCards
                    reviewWarningCount = aggregateWarningCount
                case .text(let text):
                    aggregateWarningCount += max(1, attemptedSources)
                    lastFailureMessage = text.replacingOccurrences(of: "error: ", with: "")
                default:
                    aggregateWarningCount += max(1, attemptedSources)
                    lastFailureMessage = "扫描服务返回了意外结果。"
                }
            }

            func runDirectImportPipeline() async throws {
                let stagingDirectory = try ChekinanaImportStaging.createSessionDirectory()
                activeImportStagingDirectory = stagingDirectory
                defer {
                    ChekinanaImportStaging.removeSessionDirectory(stagingDirectory)
                    if activeImportStagingDirectory == stagingDirectory {
                        activeImportStagingDirectory = nil
                    }
                }
                let coordinator = ChekinanaImportPipelineCoordinator()
                let commitGate = ChekinanaDirectCommitGate()
                var perItemProgress = Array(
                    repeating: ChekinanaScanTaskProgress(imageTotal: 1),
                    count: sessionInputs.count
                )
                let tasks = sessionInputs.enumerated().map { index, input in
                    Task { @MainActor in
                        defer {
                            Task {
                                await commitGate.skip(index: index)
                                await coordinator.markRecognized(index)
                            }
                        }
                        do {
                            try Task.checkCancellation()
                            let staged = try await stageImportInput(
                                input,
                                in: stagingDirectory
                            )
                            perItemProgress[index].imageCompleted = 1
                            taskProgress.imageCompleted = perItemProgress.reduce(0) {
                                $0 + $1.imageCompleted
                            }
                            let executor = nativeScanExecutor(
                                generation: generation,
                                directRecognitionGate: sessionRecognitionGate,
                                directDateRequestGate: sessionDateRequestGate,
                                bodyPoseLimiter: sessionBodyPoseLimiter,
                                directCommitGate: commitGate,
                                directCommitIndex: index,
                                scannerProcess: { _, _ in
                                    ChekinanaScannerProcessResult(
                                        images: [ChekinanaScannerResultImage(
                                            data: Data(),
                                            stagedFileURL: staged.fileURL,
                                            imagePixelWidth: staged.pixelWidth,
                                            imagePixelHeight: staged.pixelHeight,
                                            inferredChekiSize: staged.inferredSize
                                        )],
                                        warningCount: 0
                                    )
                                }
                            ) { progress in
                                guard processingGeneration == generation,
                                      !Task.isCancelled else { return }
                                let previous = perItemProgress[index]
                                perItemProgress[index] = ChekinanaScanTaskProgress(
                                    imageCompleted: max(
                                        previous.imageCompleted,
                                        progress.imageProcessedCount
                                    ),
                                    imageTotal: 1,
                                    dateCompleted: max(
                                        previous.dateCompleted,
                                        progress.dateCompletedCount
                                    ),
                                    dateTotal: max(previous.dateTotal, progress.dateTotalCount),
                                    idolCompleted: max(
                                        previous.idolCompleted,
                                        progress.idolCompletedCount
                                    ),
                                    idolTotal: max(previous.idolTotal, progress.idolTotalCount)
                                )
                                taskProgress = ChekinanaScanTaskProgress(
                                    imageCompleted: perItemProgress.reduce(0) {
                                        $0 + $1.imageCompleted
                                    },
                                    imageTotal: sessionInputs.count,
                                    dateCompleted: perItemProgress.reduce(0) {
                                        $0 + $1.dateCompleted
                                    },
                                    dateTotal: perItemProgress.reduce(0) {
                                        $0 + $1.dateTotal
                                    },
                                    idolCompleted: perItemProgress.reduce(0) {
                                        $0 + $1.idolCompleted
                                    },
                                    idolTotal: perItemProgress.reduce(0) {
                                        $0 + $1.idolTotal
                                    }
                                )
                            }
                            let output = protectReviewCards(in: await executeNativeScan(
                                using: executor,
                                directCommand,
                                pendingChekiImages: [ChekinanaPendingChekiImage(
                                    data: Data(),
                                    filenameExtension: "jpg",
                                    sourceID: staged.sourceID,
                                    sourceOrigin: staged.sourceOrigin
                                )],
                                direct: true
                            ))
                            try Task.checkCancellation()
                            guard processingGeneration == generation else {
                                throw CancellationError()
                            }
                            try await coordinator.waitUntilResultCanPublish(at: index)
                            accumulate(output, attemptedSources: 1)
                        } catch is CancellationError {
                            return
                        } catch {
                            perItemProgress[index].imageCompleted = 1
                            taskProgress.imageCompleted = perItemProgress.reduce(0) {
                                $0 + $1.imageCompleted
                            }
                            aggregateWarningCount += 1
                            lastFailureMessage = error.localizedDescription
                        }
                    }
                }
                await withTaskCancellationHandler {
                    for task in tasks { await task.value }
                } onCancel: {
                    tasks.forEach { $0.cancel() }
                }
                try Task.checkCancellation()
            }

#if DEBUG
            if !hasGPUInput && !nativeFixtureEnabled {
                try await runDirectImportPipeline()
            } else if ProcessInfo.processInfo.environment["CHEKINANA_NATIVE_SCAN_UI_STUB"] == "fixture" {
                let pending = ChekinanaMediaUITestFixture.pendingChekiImages()
                let executor = nativeScanExecutor(
                    generation: generation,
                    directRecognitionGate: sessionRecognitionGate,
                    directDateRequestGate: sessionDateRequestGate,
                    bodyPoseLimiter: sessionBodyPoseLimiter
                ) { progress in
                    updateTaskProgress(progress, generation: generation)
                }
                accumulate(
                    protectReviewCards(in: await executeNativeScan(
                        using: executor,
                        standardCommand,
                        pendingChekiImages: pending,
                        direct: false
                    )),
                    attemptedSources: pending.count
                )
            } else {
                var progressTranslator = ChekinanaBoundedScanProgressTranslator()
                let windows = try await ChekinanaBoundedScanPipeline.run(
                    inputs: sessionInputs,
                    load: { input, originalIndex in
                        do {
                            return try await ChekinanaProductMediaLoader.load(input)
                        } catch {
                            imageLoadFailureCount += 1
                            taskProgress.imageCompleted += 1
                            throw error
                        }
                    },
                    process: { loadedItems, _ in
                        var cards: [ChekinanaChekiCard] = []
                        var warnings = 0
                        var failure = "扫描服务没有返回结果。"
                        let groups = Dictionary(grouping: loadedItems) {
                            sessionInputs[$0.originalIndex].isDirect
                        }
                        for direct in [false, true] {
                            guard let group = groups[direct], !group.isEmpty else { continue }
                            let executor = nativeScanExecutor(
                                generation: generation,
                                directRecognitionGate: sessionRecognitionGate,
                                directDateRequestGate: sessionDateRequestGate,
                                bodyPoseLimiter: sessionBodyPoseLimiter
                            ) { progress in
                                let translated = progressTranslator.translate(
                                    progress,
                                    loadedItems: group,
                                    totalSourceCount: sessionInputs.count
                                )
                                updateTaskProgress(translated, generation: generation)
                            }
                            let output = protectReviewCards(in: await executeNativeScan(
                                using: executor,
                                direct ? directCommand : standardCommand,
                                pendingChekiImages: group.map(\.value),
                                direct: direct
                            ))
                            progressTranslator.completeWindow()
                            switch output {
                            case .chekiScannedCards(_, let warningCount, let resultCards):
                                cards.append(contentsOf: resultCards)
                                warnings += warningCount
                            case .text(let text):
                                warnings += 1
                                failure = text
                            default:
                                warnings += 1
                            }
                        }
                        return cards.isEmpty
                            ? ChekinanaCommandResponse.text(failure)
                            : ChekinanaCommandResponse.chekiScannedCards(
                                cards.count,
                                warningCount: warnings,
                                cards
                            )
                    }
                )
                for window in windows {
                    aggregateWarningCount += window.loadFailureCount
                    if let output = window.output {
                        accumulate(output, attemptedSources: window.sourceRange.count)
                    }
                }
            }
#else
            if !hasGPUInput {
                try await runDirectImportPipeline()
            } else {
            var progressTranslator = ChekinanaBoundedScanProgressTranslator()
            let windows = try await ChekinanaBoundedScanPipeline.run(
                inputs: sessionInputs,
                load: { input, originalIndex in
                    do {
                        return try await ChekinanaProductMediaLoader.load(input)
                    } catch {
                        imageLoadFailureCount += 1
                        taskProgress.imageCompleted += 1
                        throw error
                    }
                },
                process: { loadedItems, _ in
                    var cards: [ChekinanaChekiCard] = []
                    var warnings = 0
                    var failure = "扫描服务没有返回结果。"
                    let groups = Dictionary(grouping: loadedItems) {
                        sessionInputs[$0.originalIndex].isDirect
                    }
                    for direct in [false, true] {
                        guard let group = groups[direct], !group.isEmpty else { continue }
                        let executor = nativeScanExecutor(
                            generation: generation,
                            directRecognitionGate: sessionRecognitionGate,
                            directDateRequestGate: sessionDateRequestGate,
                            bodyPoseLimiter: sessionBodyPoseLimiter
                        ) { progress in
                            let translated = progressTranslator.translate(
                                progress,
                                loadedItems: group,
                                totalSourceCount: sessionInputs.count
                            )
                            updateTaskProgress(translated, generation: generation)
                        }
                        let output = protectReviewCards(in: await executeNativeScan(
                            using: executor,
                            direct ? directCommand : standardCommand,
                            pendingChekiImages: group.map(\.value),
                            direct: direct
                        ))
                        progressTranslator.completeWindow()
                        switch output {
                        case .chekiScannedCards(_, let warningCount, let resultCards):
                            cards.append(contentsOf: resultCards)
                            warnings += warningCount
                        case .text(let text):
                            warnings += 1
                            failure = text
                        default:
                            warnings += 1
                        }
                    }
                    return cards.isEmpty
                        ? ChekinanaCommandResponse.text(failure)
                        : ChekinanaCommandResponse.chekiScannedCards(
                            cards.count,
                            warningCount: warnings,
                            cards
                        )
                }
            )
            for window in windows {
                aggregateWarningCount += window.loadFailureCount
                if let output = window.output {
                    accumulate(output, attemptedSources: window.sourceRange.count)
                }
            }
            }
#endif

            aggregatedCards = ChekinanaScanReviewCardReconciler.existing(
                aggregatedCards,
                containsTemporaryCheki: confirmationLedger.containsTemporaryCheki
            )
            try Task.checkCancellation()
            guard processingGeneration == generation else { throw CancellationError() }
            if !aggregatedCards.isEmpty
                || sessionSources.contains(where: { $0.origin == .camera }) {
                reviewCards = aggregatedCards
                reviewSourceRegistry = ChekinanaScanReviewSourceRegistry(
                    sources: sessionSources
                )
                hasReviewSession = true
                reviewWarningCount = aggregateWarningCount
                isReviewPresented = true
            } else {
                discardSessionTemporaries()
                errorMessage = lastFailureMessage
                    ?? ChekinanaProductMediaError.unreadableImage.localizedDescription
            }
        } catch is CancellationError {
            // Cancel keeps results already inserted into the ledger. The
            // button itself decides whether those completed cards enter Review.
        } catch {
            for id in sessionTemporaryIDs {
                _ = confirmationLedger.discardTemporaryCheki(id: id)
            }
            if processingGeneration == generation {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func stageImportInput(
        _ input: ChekinanaNativeScanInput,
        in directory: URL
    ) async throws -> ChekinanaStagedImport {
        let loaded = try await ChekinanaProductMediaLoader.load(input)
        try Task.checkCancellation()
        let normalized = try await ChekinanaLocalImportChekiProcessor.normalize(
            loaded.data,
            appliesWhiteBalance: true
        )
        try Task.checkCancellation()
        let fileURL = try ChekinanaImportStaging.writeJPEG(
            normalized.data,
            in: directory
        )
        return ChekinanaStagedImport(
            fileURL: fileURL,
            sourceID: loaded.sourceID,
            sourceOrigin: loaded.sourceOrigin,
            inferredSize: normalized.inferredSize,
            pixelWidth: normalized.width,
            pixelHeight: normalized.height
        )
    }

    @MainActor
    private func executeNativeScan(
        using executor: ChekinanaCommandExecutor,
        _ command: String,
        pendingChekiImages: [ChekinanaPendingChekiImage],
        direct: Bool
    ) async -> ChekinanaCommandResponse {
        let output = await executor.execute(
            command,
            pendingChekiImages: pendingChekiImages
        )
        if !direct && !nativeFixtureEnabled {
            // Every completed GPU-backed request resets the same timer. The
            // last task confirms once after the Worker's 120-second idle delay
            // plus a 20-second shutdown buffer.
            runtimePresentation.scheduleLastScanConfirmation()
        }
        return output
    }

    @MainActor
    private func nativeScanExecutor(
        generation: UUID,
        directRecognitionGate: ChekinanaDirectRecognitionGate? = nil,
        directDateRequestGate: ChekinanaDirectDateRequestGate? = nil,
        bodyPoseLimiter: ChekinanaBodyPoseLimiter,
        directCommitGate: ChekinanaDirectCommitGate? = nil,
        directCommitIndex: Int? = nil,
        scannerProcess: ChekinanaCommandExecutor.ScannerProcess? = nil,
        progressObserver: @escaping ChekinanaCommandExecutor.ScanProgressObserver
    ) -> ChekinanaCommandExecutor {
#if DEBUG
        if scannerProcess == nil,
           ProcessInfo.processInfo.environment["CHEKINANA_NATIVE_SCAN_UI_STUB"] == "fixture" {
            let fallbackPattern = patternIdols.first?.recognitionPatterns.first
                ?? ChekinanaPresetIdolSeeder.prototypeVectors[0]
            return ChekinanaCommandExecutor(
                modelContext: modelContext,
                confirmationLedger: confirmationLedger,
                scannerProcess: { image, options in
                    let annotation: ChekinanaChekiDateAnnotationState
                    if options.requestsDateAnnotation,
                       let box = ChekinanaChekiDateBoundingBox(x1: 120, y1: 720, x2: 880, y2: 900),
                       let value = ChekinanaChekiDateAnnotation(
                        text: "2026.08.02",
                        precision: .fullDate,
                        boundingBox: box
                       ) {
                        annotation = .detected(value)
                    } else {
                        annotation = .notRequested
                    }
                    return ChekinanaScannerProcessResult(images: [
                        ChekinanaScannerResultImage(
                            data: image.data,
                            dateAnnotationState: annotation
                        ),
                    ], warningCount: 1)
                },
                patternEncode: { _ in fallbackPattern },
                userAppearsDetect: { _ in false },
                bodyPoseLimiter: bodyPoseLimiter,
                scanProgressObserver: progressObserver,
                scannerTaskObserver: { taskID, isActive in
                    guard processingGeneration == generation else { return }
                    if isActive {
                        activeScannerTaskIDs.insert(taskID)
                    } else {
                        activeScannerTaskIDs.remove(taskID)
                    }
                },
                directRecognitionGate: directRecognitionGate,
                directDateRequestGate: directDateRequestGate,
                directCommitGate: directCommitGate,
                directCommitIndex: directCommitIndex
            )
        }
#endif
        return ChekinanaCommandExecutor(
            modelContext: modelContext,
            confirmationLedger: confirmationLedger,
            scannerProcess: scannerProcess,
            bodyPoseLimiter: bodyPoseLimiter,
            scanProgressObserver: progressObserver,
            scannerTaskObserver: { taskID, isActive in
                guard processingGeneration == generation else { return }
                if isActive {
                    activeScannerTaskIDs.insert(taskID)
                } else {
                    activeScannerTaskIDs.remove(taskID)
                }
            },
            directRecognitionGate: directRecognitionGate,
            directDateRequestGate: directDateRequestGate,
            directCommitGate: directCommitGate,
            directCommitIndex: directCommitIndex,
            usesLocalDirectProcessing: true
        )
    }

    @MainActor
    private func updateTaskProgress(
        _ progress: ChekinanaScanProgress,
        generation: UUID
    ) {
        guard processingGeneration == generation, !Task.isCancelled else { return }
        taskProgress = ChekinanaScanTaskProgress(
            imageCompleted: progress.imageProcessedCount + imageLoadFailureCount,
            imageTotal: progress.imageProcessTotal,
            dateCompleted: progress.dateCompletedCount,
            dateTotal: progress.dateTotalCount,
            idolCompleted: progress.idolCompletedCount,
            idolTotal: progress.idolTotalCount
        )
    }

    private func scanProgressText(
        _ progress: ChekinanaScanProgress,
        directInputEnabled: Bool
    ) -> String {
        let source = "源图 \(progress.sourceIndex)/\(progress.sourceCount)"
        let totals = "累计已获得 \(progress.downloadedResultCount) 张 · 已准备 \(progress.preparedResultCount) 张"
        switch progress.stage {
        case .backend(let phase, let published, let downloaded, let expected):
            let phaseText = scannerPhaseText(
                phase,
                directInputEnabled: directInputEnabled
            )
            let publishedText = expected.map { "本图已发布 \(published)/\($0) 张" }
                ?? "本图已发布 \(published) 张"
            return "\(source) · \(phaseText)\n\(publishedText) · 已获取 \(downloaded) 张 · \(totals)"
        case .preparingResult(let index, let count, let recognizesIdol):
            let action = recognizesIdol
                ? "正在本机编码并识别 Idol \(index)/\(count)"
                : directInputEnabled
                    ? "正在准备 Cheki \(index)/\(count)"
                    : "正在准备拍立得 \(index)/\(count)"
            return "\(source) · \(action)\n\(totals)"
        case .generatingPreview:
            return "\(source) · 正在生成预览\n\(totals)"
        }
    }

    private func scannerPhaseText(
        _ phase: String?,
        directInputEnabled: Bool
    ) -> String {
        ChekinanaScannerPhasePresentation.text(
            phase,
            directInputEnabled: directInputEnabled
        )
    }
}

enum ChekinanaScannerPhasePresentation {
    static func text(
        _ phase: String?,
        directInputEnabled: Bool
    ) -> String {
        let normalized = phase?.lowercased() ?? ""
        if normalized == "runtime_offline" {
            return "正在启动后端"
        }
        if normalized == "runtime_starting" {
            return "后端正在启动"
        }
        if normalized == "runtime_ready" {
            return "后端已就绪"
        }
        if normalized == "runtime_failed" {
            return "后端启动失败"
        }
        if normalized == "waiting" || normalized == "queued" {
            return "等待后端队列"
        }
        if normalized == "loading" {
            return "后端读取源图"
        }
        if normalized == "direct_processing" {
            return "正在规范化整张 Cheki"
        }
        if normalized == "detecting" {
            return directInputEnabled ? "正在规范化整张 Cheki" : "SAM 检测拍立得"
        }
        if normalized == "extracting" {
            return directInputEnabled ? "正在处理整张 Cheki" : "逐张提取拍立得"
        }
        if normalized == "retrieving_results_with_date" {
            return "正在获取结果并识别日期"
        }
        if normalized == "retrieving_results" {
            return "正在获取结果"
        }
        if normalized.contains("download") || normalized.contains("result") {
            return "正在获取结果"
        }
        if normalized.contains("extract")
            || normalized.contains("segment")
            || normalized.contains("sam") {
            return "正在提取拍立得"
        }
        if ["completed", "complete", "done", "success", "finished"]
            .contains(normalized) {
            return "提取完成"
        }
        return "后端处理中"
    }
}

struct ChekinanaCapturedPhoto: Equatable, Sendable {
    let fileURL: URL
    let filenameExtension: String
}

struct ChekinanaNativeScanInput: Identifiable {
    enum Payload {
        case library(PhotosPickerItem)
        case camera(ChekinanaCapturedPhoto)
    }

    let id: UUID
    let payload: Payload
    let isDirect: Bool
    var rotationQuarterTurns: Int

    init(
        id: UUID,
        payload: Payload,
        isDirect: Bool = false,
        rotationQuarterTurns: Int = 0
    ) {
        self.id = id
        self.payload = payload
        self.isDirect = isDirect
        self.rotationQuarterTurns = Self.normalizedQuarterTurns(rotationQuarterTurns)
    }

    static func normalizedQuarterTurns(_ value: Int) -> Int {
        let remainder = value % 4
        return remainder >= 0 ? remainder : remainder + 4
    }

    var nextCounterclockwiseRotationQuarterTurns: Int {
        Self.normalizedQuarterTurns(rotationQuarterTurns + 1)
    }

    var descriptor: ChekinanaScanSourceDescriptor {
        ChekinanaScanSourceDescriptor(
            id: id,
            origin: origin
        )
    }

    var origin: ChekinanaScanSourceOrigin {
        switch payload {
        case .library: .library
        case .camera: .camera
        }
    }

    var libraryItem: PhotosPickerItem? {
        guard case .library(let item) = payload else { return nil }
        return item
    }

    var capturedPhoto: ChekinanaCapturedPhoto? {
        guard case .camera(let photo) = payload else { return nil }
        return photo
    }
}

struct ChekinanaNativeScanInputRotationRegistry: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let token: UUID
        let expectedQuarterTurns: Int
    }

    private(set) var entries: [UUID: Entry] = [:]

    var hasInFlightRotations: Bool { !entries.isEmpty }

    func isRotating(sourceID: UUID) -> Bool {
        entries[sourceID] != nil
    }

    func allowsInputMutation(
        isProcessing: Bool,
        hasReviewSession: Bool
    ) -> Bool {
        !isProcessing && !hasReviewSession && !hasInFlightRotations
    }

    mutating func begin(
        sourceID: UUID,
        expectedQuarterTurns: Int,
        token: UUID = UUID()
    ) -> UUID? {
        guard entries[sourceID] == nil else { return nil }
        entries[sourceID] = Entry(
            token: token,
            expectedQuarterTurns: ChekinanaNativeScanInput
                .normalizedQuarterTurns(expectedQuarterTurns)
        )
        return token
    }

    mutating func commit(
        sourceID: UUID,
        token: UUID,
        currentQuarterTurns: Int,
        newQuarterTurns: Int
    ) -> Bool {
        guard let entry = entries[sourceID],
              entry.token == token,
              entry.expectedQuarterTurns
                == ChekinanaNativeScanInput.normalizedQuarterTurns(currentQuarterTurns),
              ChekinanaNativeScanInput.normalizedQuarterTurns(newQuarterTurns)
                == ChekinanaNativeScanInput.normalizedQuarterTurns(currentQuarterTurns + 1)
        else { return false }
        entries[sourceID] = nil
        return true
    }

    mutating func fail(sourceID: UUID, token: UUID) -> Bool {
        guard entries[sourceID]?.token == token else { return false }
        entries[sourceID] = nil
        return true
    }
}

enum ChekinanaCapturedPhotoStore {
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekinanaCapturedScanSources", isDirectory: true)
    }

    static func save(
        _ data: Data,
        filenameExtension: String,
        id: UUID,
        directory: URL = directory
    ) throws -> ChekinanaCapturedPhoto {
        guard !data.isEmpty else { throw ChekinanaProductMediaError.unreadableImage }
        let ext = normalizedExtension(filenameExtension)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(
            "scan-camera-\(id.uuidString.lowercased()).\(ext)",
            isDirectory: false
        )
        guard fileURL.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL else {
            throw ChekinanaProductMediaError.unreadableImage
        }
        try data.write(to: fileURL, options: [.atomic])
        return ChekinanaCapturedPhoto(
            fileURL: fileURL,
            filenameExtension: ext
        )
    }

    static func load(
        _ photo: ChekinanaCapturedPhoto,
        directory: URL = directory
    ) throws -> Data {
        guard isManaged(photo.fileURL, directory: directory) else {
            throw ChekinanaProductMediaError.unreadableImage
        }
        let values = try photo.fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw ChekinanaProductMediaError.unreadableImage
        }
        let data = try Data(contentsOf: photo.fileURL, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw ChekinanaProductMediaError.unreadableImage }
        return data
    }

    static func remove(
        _ photo: ChekinanaCapturedPhoto,
        directory: URL = directory
    ) {
        guard isManaged(photo.fileURL, directory: directory) else { return }
        try? FileManager.default.removeItem(at: photo.fileURL)
    }

    static func cleanupStaleFiles(directory: URL = directory) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        for url in urls where isManaged(url, directory: directory) {
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func normalizedExtension(_ value: String) -> String {
        switch value.lowercased() {
        case "heic", "heif": "heic"
        case "png": "png"
        default: "jpg"
        }
    }

    private static func isManaged(_ url: URL, directory: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == directory.standardizedFileURL,
              standardized.lastPathComponent.range(
                of: #"^scan-camera-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(heic|jpg|png)$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else {
            return false
        }
        return true
    }
}

enum ChekinanaNativeScanInputReconciler {
    static func retainedInputs(
        existing: [ChekinanaNativeScanInput],
        retainedIDs: Set<UUID>,
        origin: ChekinanaScanSourceOrigin,
        isDirect: Bool
    ) -> [ChekinanaNativeScanInput] {
        existing.filter { input in
            input.origin != origin
                || input.isDirect != isDirect
                || retainedIDs.contains(input.id)
        }
    }
}

enum ChekinanaProductMediaLoader {
    static func load(
        _ input: ChekinanaNativeScanInput
    ) async throws -> ChekinanaPendingChekiImage {
        let original = try await loadUnrotated(input)
        return try await applyingCounterclockwiseRotation(
            to: original,
            quarterTurns: input.rotationQuarterTurns
        )
    }

    static func loadUnrotated(
        _ input: ChekinanaNativeScanInput
    ) async throws -> ChekinanaPendingChekiImage {
        switch input.payload {
        case .library(let item):
            return try await load(item, sourceID: input.id)
        case .camera(let photo):
            let data = try await Task.detached(priority: .userInitiated) {
                try ChekinanaCapturedPhotoStore.load(photo)
            }.value
            return ChekinanaPendingChekiImage(
                data: data,
                filenameExtension: photo.filenameExtension,
                sourceID: input.id,
                sourceOrigin: .camera
            )
        }
    }

    static func applyingCounterclockwiseRotation(
        to image: ChekinanaPendingChekiImage,
        quarterTurns: Int
    ) async throws -> ChekinanaPendingChekiImage {
        var rotated = image
        for _ in 0..<ChekinanaNativeScanInput.normalizedQuarterTurns(quarterTurns) {
            try Task.checkCancellation()
            rotated = try await ChekinanaScanCleanImageRotation.counterclockwise(rotated)
        }
        return rotated
    }

    static func rotatePreviewCounterclockwise(
        _ image: ChekinanaRenderedImage
    ) async throws -> ChekinanaRenderedImage {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let rotated = ChekinanaImageWorker.normalizedThumbnailOrientation(
                image.cgImage,
                exifOrientation: 8,
                maxDimension: max(image.cgImage.width, image.cgImage.height)
            ) else {
                throw ChekinanaProductMediaError.unreadableImage
            }
            try Task.checkCancellation()
            return ChekinanaRenderedImage(cgImage: rotated)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func load(
        _ item: PhotosPickerItem,
        sourceID: UUID? = nil
    ) async throws -> ChekinanaPendingChekiImage {
        let fileExtension = item.supportedContentTypes
            .compactMap(\.preferredFilenameExtension)
            .first ?? "jpg"
        if let image = try? await item.loadTransferable(type: ChekinanaTransferableImageData.self),
           !image.data.isEmpty {
            return ChekinanaPendingChekiImage(
                data: image.data,
                filenameExtension: fileExtension,
                sourceID: sourceID,
                sourceOrigin: .library
            )
        }
        if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
            return ChekinanaPendingChekiImage(
                data: data,
                filenameExtension: fileExtension,
                sourceID: sourceID,
                sourceOrigin: .library
            )
        }
        if let fallback = try? await item.loadTransferable(type: ChekinanaTransferableFallbackImageData.self),
           let jpeg = await ChekinanaImageWorker.reencodedJPEGData(from: fallback.data),
           !jpeg.isEmpty {
            return ChekinanaPendingChekiImage(
                data: jpeg,
                filenameExtension: "jpg",
                sourceID: sourceID,
                sourceOrigin: .library
            )
        }
        throw ChekinanaProductMediaError.unreadableImage
    }
}

enum ChekinanaProductMediaError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        "无法读取所选照片。"
    }
}

enum ChekinanaCameraPermission: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .restricted
        }
    }
}

enum ChekinanaCameraState: Equatable {
    case idle
    case requestingPermission
    case configuring
    case ready
    case capturing
    case interrupted(String)
    case unavailable(String)
    case failed(String)
}

enum ChekinanaCameraStateResolver {
    static func initial(
        permission: ChekinanaCameraPermission,
        hasBackCamera: Bool
    ) -> ChekinanaCameraState {
        switch permission {
        case .notDetermined:
            return .requestingPermission
        case .denied:
            return .unavailable("Camera access is denied. Enable it in Settings to take photos.")
        case .restricted:
            return .unavailable("Camera access is restricted on this device.")
        case .authorized:
            return hasBackCamera
                ? .configuring
                : .unavailable("No rear camera is available on this device.")
        }
    }

    static func captureResult(
        hasData: Bool,
        errorDescription: String? = nil
    ) -> ChekinanaCameraState {
        guard errorDescription == nil, hasData else {
            return .failed(errorDescription ?? "The camera did not return photo data.")
        }
        return .ready
    }

    static func interruption(reason: Int?) -> ChekinanaCameraState {
        let message: String
        switch reason {
        case AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient.rawValue:
            message = "Camera audio is in use by another app."
        case AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue:
            message = "The camera is in use by another app."
        case AVCaptureSession.InterruptionReason.videoDeviceNotAvailableWithMultipleForegroundApps.rawValue:
            message = "The camera is unavailable while multiple apps are in the foreground."
        case AVCaptureSession.InterruptionReason.videoDeviceNotAvailableDueToSystemPressure.rawValue:
            message = "The camera paused because of system pressure."
        default:
            message = "The camera session was interrupted."
        }
        return .interrupted(message)
    }

    static func runtimeError(code: Int, message: String) -> ChekinanaCameraState {
        if code == AVError.Code.mediaServicesWereReset.rawValue {
            return .configuring
        }
        return .failed("Camera runtime error: \(message)")
    }
}

enum ChekinanaCameraVideoRotation {
    static func angle(for orientation: UIInterfaceOrientation) -> CGFloat? {
        switch orientation {
        case .portrait: 90
        case .portraitUpsideDown: 270
        case .landscapeLeft: 180
        case .landscapeRight: 0
        case .unknown: nil
        @unknown default: nil
        }
    }
}

enum ChekinanaCameraCaptureControls {
    static func canDismiss(isCaptureInFlight: Bool) -> Bool {
        !isCaptureInFlight
    }

    static func canCapture(
        state: ChekinanaCameraState,
        isCaptureInFlight: Bool
    ) -> Bool {
        state == .ready && !isCaptureInFlight
    }
}

enum ChekinanaScanReviewLifecycle {
    static func shouldDiscardAfterDeletion(
        cardsAreEmpty: Bool,
        hasCapturedPhoto: Bool
    ) -> Bool {
        cardsAreEmpty && !hasCapturedPhoto
    }

    static func closeDiscardsReview(cardsAreEmpty: Bool) -> Bool {
        cardsAreEmpty
    }
}

enum ChekinanaScanReviewInteractionPolicy {
    static func allowsCardInteraction(
        isSaving: Bool,
        isRotating: Bool,
        isDownloading: Bool
    ) -> Bool {
        !isSaving && !isRotating && !isDownloading
    }

    static func allowsConfirmAll(
        isSaving: Bool,
        hasRotations: Bool,
        hasDownloads: Bool
    ) -> Bool {
        !isSaving && !hasRotations && !hasDownloads
    }
}

struct ChekinanaCameraFocusCapabilities: Equatable {
    let supportsFocusPoint: Bool
    let supportsAutoFocus: Bool
    let supportsContinuousAutoFocus: Bool
    let supportsExposurePoint: Bool
    let supportsAutoExposure: Bool
    let supportsContinuousAutoExposure: Bool
}

struct ChekinanaCameraFocusPlan: Equatable {
    let point: CGPoint
    let focusMode: AVCaptureDevice.FocusMode?
    let exposureMode: AVCaptureDevice.ExposureMode?
}

enum ChekinanaCameraFocusPlanner {
    static func plan(
        point: CGPoint,
        capabilities: ChekinanaCameraFocusCapabilities
    ) -> ChekinanaCameraFocusPlan {
        let normalizedPoint = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        let focusMode: AVCaptureDevice.FocusMode? = capabilities.supportsFocusPoint
            ? capabilities.supportsAutoFocus
                ? .autoFocus
                : capabilities.supportsContinuousAutoFocus ? .continuousAutoFocus : nil
            : nil
        let exposureMode: AVCaptureDevice.ExposureMode? = capabilities.supportsExposurePoint
            ? capabilities.supportsAutoExposure
                ? .autoExpose
                : capabilities.supportsContinuousAutoExposure ? .continuousAutoExposure : nil
            : nil
        return ChekinanaCameraFocusPlan(
            point: normalizedPoint,
            focusMode: focusMode,
            exposureMode: exposureMode
        )
    }
}

enum ChekinanaCameraPhotoQuality {
    static func largestDimensions(
        _ values: [CMVideoDimensions]
    ) -> CMVideoDimensions? {
        values
            .filter { $0.width > 0 && $0.height > 0 }
            .max { lhs, rhs in
                Int64(lhs.width) * Int64(lhs.height)
                    < Int64(rhs.width) * Int64(rhs.height)
            }
    }
}

#if DEBUG
struct ChekinanaCameraHardwareFixture {
    let permission: ChekinanaCameraPermission
    let hasBackCamera: Bool
    let captureDataAvailable: Bool
    let captureErrorDescription: String?
    let focusCapabilities: ChekinanaCameraFocusCapabilities

    var initialState: ChekinanaCameraState {
        ChekinanaCameraStateResolver.initial(
            permission: permission,
            hasBackCamera: hasBackCamera
        )
    }

    var captureState: ChekinanaCameraState {
        ChekinanaCameraStateResolver.captureResult(
            hasData: captureDataAvailable,
            errorDescription: captureErrorDescription
        )
    }

    func focusPlan(at point: CGPoint) -> ChekinanaCameraFocusPlan {
        ChekinanaCameraFocusPlanner.plan(
            point: point,
            capabilities: focusCapabilities
        )
    }
}
#endif

final class ChekinanaCameraController: NSObject, ObservableObject,
    AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    struct CapturedSource: Identifiable, Equatable {
        let id: UUID
        let photo: ChekinanaCapturedPhoto
    }

    @Published private(set) var state: ChekinanaCameraState = .idle
    @Published private(set) var latestCapture: CapturedSource?
    @Published private(set) var isCaptureInFlight = false

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(
        label: "top.chekinana.camera.session",
        qos: .userInitiated
    )
    private let photoOutput = AVCapturePhotoOutput()
    private var cameraDevice: AVCaptureDevice?
    private var maximumDimensions: CMVideoDimensions?
    private var configured = false
    private var captureInFlight = false
    private var captureID: UUID?
    private var captureExtension = "jpg"
    private var videoRotationAngle: CGFloat?
    private var isInterrupted = false
    private var notificationTokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.handleInterruptionEnded()
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                self?.handleRuntimeError(notification)
            },
        ]
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func prepare() {
        let permission = ChekinanaCameraPermission(
            AVCaptureDevice.authorizationStatus(for: .video)
        )
        switch permission {
        case .notDetermined:
            publish(.requestingPermission)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
                    self.publish(ChekinanaCameraStateResolver.initial(
                        permission: .denied,
                        hasBackCamera: false
                    ))
                }
            }
        case .authorized:
            configureAndStart()
        case .denied, .restricted:
            publish(ChekinanaCameraStateResolver.initial(
                permission: permission,
                hasBackCamera: false
            ))
        }
    }

    func resume() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.configured else {
                self.prepare()
                return
            }
            guard !self.isInterrupted else {
                self.publish(ChekinanaCameraStateResolver.interruption(reason: nil))
                return
            }
            guard !self.session.isRunning else {
                self.publish(.ready)
                return
            }
            self.session.startRunning()
            self.publish(
                self.session.isRunning
                    ? .ready
                    : .failed("The camera session could not resume.")
            )
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self,
                  self.configured,
                  self.session.isRunning,
                  !self.captureInFlight else { return }
            self.captureInFlight = true
            self.captureID = UUID()
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                ])
                self.captureExtension = "heic"
            } else {
                settings = AVCapturePhotoSettings()
                self.captureExtension = "jpg"
            }
            settings.photoQualityPrioritization = .quality
            if let maximumDimensions = self.maximumDimensions {
                settings.maxPhotoDimensions = maximumDimensions
            }
            self.publishCaptureInFlight(true, state: .capturing)
            self.applyPhotoRotationIfSupported()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func setVideoRotationAngle(_ angle: CGFloat?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoRotationAngle = angle
            guard !self.captureInFlight else { return }
            self.applyPhotoRotationIfSupported()
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.cameraDevice else { return }
            let capabilities = ChekinanaCameraFocusCapabilities(
                supportsFocusPoint: device.isFocusPointOfInterestSupported,
                supportsAutoFocus: device.isFocusModeSupported(.autoFocus),
                supportsContinuousAutoFocus: device.isFocusModeSupported(.continuousAutoFocus),
                supportsExposurePoint: device.isExposurePointOfInterestSupported,
                supportsAutoExposure: device.isExposureModeSupported(.autoExpose),
                supportsContinuousAutoExposure: device.isExposureModeSupported(.continuousAutoExposure)
            )
            let plan = ChekinanaCameraFocusPlanner.plan(
                point: devicePoint,
                capabilities: capabilities
            )
            guard plan.focusMode != nil || plan.exposureMode != nil else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if let focusMode = plan.focusMode {
                    device.focusPointOfInterest = plan.point
                    device.focusMode = focusMode
                }
                if let exposureMode = plan.exposureMode {
                    device.exposurePointOfInterest = plan.point
                    device.exposureMode = exposureMode
                }
            } catch {
                self?.publish(.failed("Unable to focus the camera: \(error.localizedDescription)"))
            }
        }
    }

    func consumeLatestCapture() {
        DispatchQueue.main.async { [weak self] in
            self?.latestCapture = nil
            self?.isCaptureInFlight = false
            self?.state = .ready
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let errorDescription = error?.localizedDescription
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureInFlight = false
            guard let captureID = self.captureID else {
                self.publishCaptureInFlight(false)
                self.publish(.failed("The camera capture identity was lost."))
                return
            }
            self.captureID = nil
            let nextState = ChekinanaCameraStateResolver.captureResult(
                hasData: data?.isEmpty == false,
                errorDescription: errorDescription
            )
            guard nextState == .ready, let data else {
                self.publishCaptureInFlight(false)
                self.publish(nextState)
                return
            }
            do {
                let stored = try ChekinanaCapturedPhotoStore.save(
                    data,
                    filenameExtension: self.captureExtension,
                    id: captureID
                )
                DispatchQueue.main.async { [weak self] in
                    self?.latestCapture = CapturedSource(id: captureID, photo: stored)
                    // Remain capture-locked until SwiftUI delivers the source
                    // to the Scan queue and calls `consumeLatestCapture()`.
                    self?.state = .capturing
                }
            } catch {
                self.publishCaptureInFlight(false)
                self.publish(.failed("Unable to keep the captured photo: \(error.localizedDescription)"))
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.configured {
                guard !self.isInterrupted else {
                    self.publish(ChekinanaCameraStateResolver.interruption(reason: nil))
                    return
                }
                if !self.session.isRunning { self.session.startRunning() }
                self.publish(
                    self.session.isRunning
                        ? .ready
                        : .failed("The camera session could not start.")
                )
                return
            }
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            )
            let initialState = ChekinanaCameraStateResolver.initial(
                permission: .authorized,
                hasBackCamera: device != nil
            )
            guard let device else {
                self.publish(initialState)
                return
            }
            self.publish(.configuring)
            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard self.session.canAddInput(input),
                      self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    self.publish(.unavailable("The rear camera cannot be configured for photos."))
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                let dimensions = ChekinanaCameraPhotoQuality.largestDimensions(
                    device.activeFormat.supportedMaxPhotoDimensions
                )
                if let dimensions {
                    self.photoOutput.maxPhotoDimensions = dimensions
                }
                self.session.commitConfiguration()
                self.cameraDevice = device
                self.maximumDimensions = dimensions
                self.configured = true
                self.session.startRunning()
                self.publish(
                    self.session.isRunning
                        ? .ready
                        : .failed("The camera session could not start.")
                )
            } catch {
                if self.session.isRunning { self.session.stopRunning() }
                self.publish(.failed("Unable to configure the camera: \(error.localizedDescription)"))
            }
        }
    }

    private func publish(_ value: ChekinanaCameraState) {
        DispatchQueue.main.async { [weak self] in
            self?.state = value
        }
    }

    private func publishCaptureInFlight(
        _ value: Bool,
        state: ChekinanaCameraState? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.isCaptureInFlight = value
            if let state { self?.state = state }
        }
    }

    private func applyPhotoRotationIfSupported() {
        guard let angle = videoRotationAngle,
              let connection = photoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func handleInterruption(_ notification: Notification) {
        let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isInterrupted = true
            self.publish(ChekinanaCameraStateResolver.interruption(reason: reason))
        }
    }

    private func handleInterruptionEnded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isInterrupted = false
            if !self.session.isRunning { self.session.startRunning() }
            self.publish(
                self.session.isRunning
                    ? .ready
                    : .failed("The camera remained unavailable after the interruption ended.")
            )
        }
    }

    private func handleRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let code = error?.code ?? -1
        let message = error?.localizedDescription ?? "Unknown runtime error"
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureInFlight = false
            self.captureID = nil
            self.publishCaptureInFlight(false)
            let state = ChekinanaCameraStateResolver.runtimeError(
                code: code,
                message: message
            )
            guard state == .configuring else {
                self.publishCaptureInFlight(false)
                self.publish(state)
                return
            }
            self.isInterrupted = false
            self.publish(.configuring)
            if !self.session.isRunning { self.session.startRunning() }
            self.publish(
                self.session.isRunning
                    ? .ready
                    : .failed("Camera media services reset and could not restart.")
            )
        }
    }
}

private final class ChekinanaCameraPreviewUIView: UIView {
    var onFocus: ((CGPoint) -> Void)?
    var onRotationAngle: ((CGFloat?) -> Void)?
    private var lastRotationAngle: CGFloat?

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(recognizer)
        isUserInteractionEnabled = true
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setSession(_ session: AVCaptureSession) {
        if previewLayer.session !== session { previewLayer.session = session }
        updateRotation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateRotation()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        showFocusFrame(at: location)
        onFocus?(devicePoint)
    }

    private func showFocusFrame(at point: CGPoint) {
        let frameView = UIView(frame: CGRect(x: 0, y: 0, width: 74, height: 74))
        frameView.center = point
        frameView.layer.borderColor = UIColor.systemYellow.cgColor
        frameView.layer.borderWidth = 2
        frameView.layer.cornerRadius = 8
        frameView.alpha = 0
        frameView.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        addSubview(frameView)
        UIView.animate(withDuration: 0.16, animations: {
            frameView.alpha = 1
            frameView.transform = .identity
        }) { _ in
            UIView.animate(
                withDuration: 0.28,
                delay: 0.65,
                options: [.curveEaseOut]
            ) {
                frameView.alpha = 0
            } completion: { _ in
                frameView.removeFromSuperview()
            }
        }
    }

    private func updateRotation() {
        guard let orientation = window?.windowScene?.interfaceOrientation,
              let angle = ChekinanaCameraVideoRotation.angle(for: orientation) else {
            return
        }
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        guard lastRotationAngle != angle else { return }
        lastRotationAngle = angle
        onRotationAngle?(angle)
    }
}

private struct ChekinanaCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint) -> Void
    let onRotationAngle: (CGFloat?) -> Void

    func makeUIView(context: Context) -> ChekinanaCameraPreviewUIView {
        let view = ChekinanaCameraPreviewUIView()
        view.onFocus = onFocus
        view.onRotationAngle = onRotationAngle
        view.setSession(session)
        return view
    }

    func updateUIView(_ uiView: ChekinanaCameraPreviewUIView, context: Context) {
        uiView.onFocus = onFocus
        uiView.onRotationAngle = onRotationAngle
        uiView.setSession(session)
    }
}

private struct ChekinanaCameraCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = ChekinanaCameraController()
    let onCaptured: (ChekinanaCameraController.CapturedSource) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ChekinanaCameraPreview(
                session: controller.session,
                onFocus: controller.focus,
                onRotationAngle: controller.setVideoRotationAngle
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button("Done") { dismiss() }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(.black.opacity(0.48))
                        .clipShape(Capsule())
                        .disabled(!ChekinanaCameraCaptureControls.canDismiss(
                            isCaptureInFlight: controller.isCaptureInFlight
                        ))
                        .opacity(controller.isCaptureInFlight ? 0.45 : 1)
                        .accessibilityIdentifier("chekinana.camera.done")
                    Spacer()
                }
                .padding()
                Spacer()
                cameraStatus
                Button(action: controller.capturePhoto) {
                    ZStack {
                        Circle().fill(.white).frame(width: 76, height: 76)
                        Circle().stroke(.black.opacity(0.72), lineWidth: 2).frame(width: 66, height: 66)
                    }
                }
                .disabled(!ChekinanaCameraCaptureControls.canCapture(
                    state: controller.state,
                    isCaptureInFlight: controller.isCaptureInFlight
                ))
                .opacity(ChekinanaCameraCaptureControls.canCapture(
                    state: controller.state,
                    isCaptureInFlight: controller.isCaptureInFlight
                ) ? 1 : 0.55)
                .padding(.bottom, 28)
                .accessibilityLabel("Take photo")
                .accessibilityIdentifier("chekinana.camera.shutter")
            }
        }
        .onAppear { controller.prepare() }
        .onDisappear { controller.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.resume()
            } else {
                controller.stop()
            }
        }
        .onChange(of: controller.latestCapture) { _, capture in
            guard let capture else { return }
            onCaptured(capture)
            controller.consumeLatestCapture()
        }
        .accessibilityIdentifier("chekinana.camera.page")
    }

    @ViewBuilder
    private var cameraStatus: some View {
        switch controller.state {
        case .requestingPermission, .configuring:
            ProgressView()
                .tint(.white)
                .padding(12)
                .background(.black.opacity(0.48))
                .clipShape(Circle())
                .padding(.bottom, 16)
        case .capturing:
            Text("Capturing full-resolution photo…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.48))
                .clipShape(Capsule())
                .padding(.bottom, 16)
        case .interrupted(let message):
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(14)
                .background(.black.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        case .unavailable(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(.black.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Retry") { controller.resume() }
                    .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(.black.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        case .idle, .ready:
            EmptyView()
        }
    }
}

private struct ChekinanaNativeTemporaryDraft: Identifiable {
    let id: UUID
    var idolIDs: Set<UUID>
    var hasDate: Bool
    var date: Date
    var eventID: UUID?
    var eventWasExplicitlyEdited: Bool
    var idxText: String
    var initialIdxText: String
    var existingChekiID: UUID?
    var existingSelectionIsManual: Bool
    var userAppears: Bool?
    var size: ChekiSize?
    var isFavorite: Bool
    var hasPostedToSNS: Bool
    var note: String
}

private struct ChekinanaNativeIdolSelectionDraft: Identifiable {
    let id: UUID
    let selectedIDs: Set<UUID>
}

private struct ChekinanaNativeDateSelectionDraft: Identifiable {
    let id: UUID
    let date: Date?
}

private struct ChekinanaNativeScanReview: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Idol.name) private var idols: [Idol]
    @Query(sort: \Event.date) private var events: [Event]
    @Query private var chekis: [Cheki]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    @Binding var cards: [ChekinanaChekiCard]
    @Binding var sourceRegistry: ChekinanaScanReviewSourceRegistry
    let warningCount: Int
    let ledger: ChekinanaConfirmationLedger
    let onDeleteSource: (UUID) -> Void
    let onSaved: ([UUID]) -> Void
    let onDiscarded: ([UUID]) -> Void
    let onClose: () -> Void

    @State private var editorDraft: ChekinanaNativeTemporaryDraft?
    @State private var idolSelectionDraft: ChekinanaNativeIdolSelectionDraft?
    @State private var dateSelectionDraft: ChekinanaNativeDateSelectionDraft?
    @State private var isSaving = false
    @State private var batchSaveProgress: ChekinanaTemporaryChekiBatchProgress?
    @State private var statusMessage: String?
    @State private var annotationVisibleIDs = Set<UUID>()
    @State private var rotatingIDs = Set<UUID>()
    @State private var downloadingIDs = Set<UUID>()
    @State private var isDiscardAlertPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if cards.isEmpty {
                    ChekinanaEmptyState(
                        title: "No temporary Cheki",
                        message: "所有临时结果已删除；没有内容写入存储。",
                        systemImage: "trash"
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            if warningCount > 0 {
                                Label(
                                    "已保留正常结果；有 \(warningCount) 项未完成，请检查自动识别属性",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .accessibilityIdentifier("chekinana.scan.review.warning")
                            }
                            LazyVGrid(
                                columns: reviewGridColumns,
                                alignment: .leading,
                                spacing: 12
                            ) {
                                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                                    temporaryCard(card, position: index + 1)
                                }
                            }
                        }
                        .padding(12)
                        .padding(.bottom, 90)
                    }
                }
            }
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle("Review \(cards.count) Cheki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { isDiscardAlertPresented = true }
                        .disabled(isSaving || !rotatingIDs.isEmpty || !downloadingIDs.isEmpty)
                        .accessibilityIdentifier("chekinana.scan.review.back")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !cards.isEmpty || sourceRegistry.hasCapturedPhoto {
                    VStack(spacing: 8) {
                        if sourceRegistry.hasCapturedPhoto {
                            Button(role: .destructive) {
                                deleteLatestCapturedPhoto()
                            } label: {
                                Label("Delete captured photo", systemImage: "camera.badge.ellipsis")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSaving || !rotatingIDs.isEmpty || !downloadingIDs.isEmpty)
                            .accessibilityHint("Deletes the latest remaining camera source and all Cheki extracted from it")
                            .accessibilityIdentifier("chekinana.scan.review.delete-captured")
                        }
                        if !cards.isEmpty {
                            Button {
                                Task { await confirmAll() }
                            } label: {
                                if isSaving {
                                    VStack(spacing: 5) {
                                        Text(batchSaveProgress?.stage.title ?? "Preparing images")
                                            .font(.headline)
                                        if let progress = batchSaveProgress {
                                            ProgressView(
                                                value: Double(progress.completed),
                                                total: Double(max(1, progress.total))
                                            )
                                            .tint(.white)
                                            Text("\(progress.completed)/\(progress.total)")
                                                .font(.caption.monospacedDigit())
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                } else {
                                    Label("Save all Cheki", systemImage: "checkmark.circle")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity, minHeight: 52)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ChekinanaProductTheme.accent)
                            .disabled(
                                !ChekinanaScanReviewInteractionPolicy.allowsConfirmAll(
                                    isSaving: isSaving,
                                    hasRotations: !rotatingIDs.isEmpty,
                                    hasDownloads: !downloadingIDs.isEmpty
                                )
                            )
                            .accessibilityIdentifier("chekinana.scan.review.confirm")
                        }
                        if cards.isEmpty, !sourceRegistry.sources.isEmpty {
                            Button("Discard review", role: .destructive) {
                                discardEmptyReview()
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSaving)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("chekinana.scan.review.discard")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
            .sheet(item: $editorDraft) { presentedDraft in
                ChekinanaNativeTemporaryEditor(
                    draft: Binding(
                        get: { editorDraft ?? presentedDraft },
                        set: { editorDraft = $0 }
                    ),
                    idols: visibleIdols,
                    events: events,
                    existingCandidates: editorExistingCandidates,
                    onSave: saveEditor,
                    onCancel: { editorDraft = nil },
                    onDelete: {
                        guard let id = editorDraft?.id else { return }
                        deleteTemporary(id: id)
                        editorDraft = nil
                    }
                )
            }
            .sheet(item: $idolSelectionDraft) { draft in
                ChekinanaNativeIdolSelectionView(
                    idols: visibleIdols,
                    initialSelectedIDs: draft.selectedIDs,
                    onSave: { selectedIDs in
                        let saved = saveIdolSelection(
                            id: draft.id,
                            selectedIDs: selectedIDs
                        )
                        if saved { idolSelectionDraft = nil }
                        return saved
                    }
                )
            }
            .sheet(item: $dateSelectionDraft) { draft in
                ChekinanaNativeDateSelectionView(
                    initialDate: draft.date,
                    onSave: { date in
                        let saved = saveDateSelection(id: draft.id, date: date)
                        if saved { dateSelectionDraft = nil }
                        return saved
                    }
                )
            }
            .alert("Scan review", isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )) {
                Button("OK", role: .cancel) { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "")
            }
            .alert("Discard unsaved results?", isPresented: $isDiscardAlertPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    discardEntireReview()
                }
            } message: {
                Text("This returns to Scan and removes every temporary result and pending input from this scan.")
            }
            .onChange(of: hiddenIdols.hiddenIDs) { _, _ in
                retireHiddenTemporaryCards()
            }
        }
        .chekinanaScreenMarker("chekinana.scan.review")
    }

    private var visibleIdols: [Idol] {
        ChekinanaVisibilityPolicy.visibleIdols(idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }

    private var reviewGridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
            GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
        ]
    }

    private var editorExistingCandidates: [Cheki] {
        guard let draft = editorDraft,
              draft.hasDate,
              let date = ChekinanaDateOnly.canonicalDate(
                  from: draft.date,
                  displayedIn: .current
              ) else { return [] }
        return availableExistingChekis(
            idolIDs: draft.idolIDs,
            date: date,
            excludingTemporaryID: draft.id
        )
    }

    private func matchingExistingChekis(
        idolIDs: Set<UUID>,
        date: Date?
    ) -> [Cheki] {
        guard let date else { return [] }
        return chekis.filter {
            ChekinanaNoMediaPolicy.hasNoImage($0.imageRef)
                && Set($0.idols.map(\.id)) == idolIDs
                && ChekinanaProductDate.isSameDay($0.date, date)
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func availableExistingChekis(
        idolIDs: Set<UUID>,
        date: Date?,
        excludingTemporaryID: UUID
    ) -> [Cheki] {
        let reservedIDs = Set(cards.compactMap { card -> UUID? in
            guard card.id != excludingTemporaryID else { return nil }
            return ledger.temporaryCheki(card.id)?.existingChekiID
        })
        return matchingExistingChekis(idolIDs: idolIDs, date: date).filter {
            !reservedIDs.contains($0.id)
        }
    }

    @ViewBuilder
    private func temporaryCard(
        _ card: ChekinanaChekiCard,
        position: Int
    ) -> some View {
        if let temporary = ledger.temporaryCheki(card.id) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    Button { beginEditing(temporary) } label: {
                        ChekinanaTemporaryImagePreview(
                            imageData: temporary.image.data,
                            annotationState: temporary.dateAnnotationState,
                            sourceAnnotation: temporary.sourceAnnotation,
                            showsSourceAnnotation: annotationVisibleIDs.contains(temporary.id),
                            cacheKey: "native-review-\(temporary.id.uuidString)-\(temporary.imageRotationQuarterTurns)"
                        )
                        .aspectRatio(
                            ChekinanaImagePixelGeometry.aspectRatio(
                                in: temporary.image.data
                            ) ?? ChekinanaChekiDisplayFramePolicy.aspectRatio,
                            contentMode: .fit
                        )
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!allowsCardInteraction(temporary.id))
                    .accessibilityLabel("Edit temporary Cheki")
                    .accessibilityIdentifier(
                        "chekinana.scan.review.image.\(temporary.id.uuidString.lowercased())"
                    )

                    if let userAppears = temporary.userAppears {
                        Button {
                            toggleUserAppears(temporary.id)
                        } label: {
                            Text(userAppears ? "2-shot" : "solo")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.72))
                                .clipShape(Capsule())
                                .frame(
                                    minWidth: 44,
                                    minHeight: 44,
                                    alignment: .topLeading
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!allowsCardInteraction(temporary.id))
                        .accessibilityLabel(ChekinanaProductCopy.text(
                            "scan.shot_type",
                            "Shot type"
                        ))
                        .accessibilityValue(userAppears ? "2-shot" : "solo")
                        .accessibilityHint(ChekinanaProductCopy.text(
                            "scan.shot_type.toggle_hint",
                            "Double-tap to switch between solo and 2-shot."
                        ))
                        .accessibilityIdentifier(
                            "chekinana.scan.review.user-appears.\(temporary.id.uuidString.lowercased())"
                        )
                        .padding(4)
                    }

                    Button {
                        rotate(temporary.id)
                    } label: {
                        Image(systemName: "rotate.left")
                            .font(.callout.weight(.semibold))
                            .frame(
                                width: ChekinanaAccessibilityMetrics.minimumTouchTarget,
                                height: ChekinanaAccessibilityMetrics.minimumTouchTarget
                            )
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.72))
                            .clipShape(Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!allowsCardInteraction(temporary.id))
                    .accessibilityLabel(
                        rotatingIDs.contains(temporary.id)
                            ? ChekinanaProductCopy.text("scan.rotating", "Rotating…")
                            : ChekinanaProductCopy.text(
                                "scan.rotate_counterclockwise",
                                "Rotate counterclockwise"
                            )
                    )
                    .accessibilityValue(ChekinanaProductCopy.format(
                        "scan.rotate_state",
                        "Counterclockwise turn %lld of 4",
                        Int64(temporary.imageRotationQuarterTurns)
                    ))
                    .accessibilityIdentifier(
                        "chekinana.scan.review.rotate.\(temporary.id.uuidString.lowercased())"
                    )
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(4)
                }

                temporaryMetadataRow(temporary, position: position)
                HStack(spacing: 8) {
                    Label(
                        temporary.existingChekiID.flatMap { id in
                            chekis.first(where: { $0.id == id }).map {
                                "Attach to existing\($0.idx.map { " #\($0)" } ?? "")"
                            }
                        } ?? "Create new Cheki\(temporary.idx.map { " #\($0)" } ?? "")",
                        systemImage: temporary.existingChekiID == nil
                            ? "plus.square" : "link"
                    )
                    Spacer(minLength: 4)
                    Label(
                        temporary.size?.rawValue ?? ChekinanaProductCopy.text(
                            "common.unknown",
                            "Unknown"
                        ),
                        systemImage: "aspectratio"
                    )
                    .accessibilityIdentifier(
                        "chekinana.scan.review.size.\(temporary.id.uuidString.lowercased())"
                    )
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(
                    temporary.existingChekiID == nil ? Color.secondary : Color.green
                )
                temporaryActionRow(card, temporary: temporary)

                if let eventID = temporary.eventID,
                   let event = events.first(where: { $0.id == eventID }) {
                    Label(event.name, systemImage: "ticket")
                        .font(.caption)
                        .lineLimit(1)
                    if temporary.eventWasAutoMatched {
                        Text("Auto matched from the recognized date")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("chekinana.scan.review.event-auto")
                    }
                }
            }
            .padding(8)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ChekinanaProductTheme.border, lineWidth: 0.75)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chekinana.scan.review.card.\(position)")
            .onAppear { reconcileExistingMatch(for: temporary.id) }
        }
    }

    private func temporaryMetadataRow(
        _ temporary: ChekinanaConfirmationLedger.TemporaryCheki,
        position: Int
    ) -> some View {
        let selectedIdols = orderedIdols.filter { temporary.idolIDs.contains($0.id) }
        let idolValue = selectedIdols.map(\.name).joined(separator: ", ").nonEmpty ?? "Unassigned"
        let dateValue = temporary.date.map(ChekinanaProductDate.displayString) ?? "日期未识别"
        return HStack(spacing: 8) {
            Button { beginSelectingIdols(temporary) } label: {
                compactAvatarStack(selectedIdols, position: position)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .buttonStyle(.plain)
            .disabled(!allowsCardInteraction(temporary.id))
            .accessibilityLabel("Idol")
            .accessibilityValue(idolValue)
            .accessibilityIdentifier("chekinana.scan.review.idol.\(position)")

            Button { beginSelectingDate(temporary) } label: {
                Text(dateValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(temporary.date == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .buttonStyle(.plain)
            .disabled(!allowsCardInteraction(temporary.id))
            .accessibilityLabel("Date")
            .accessibilityValue(dateValue)
            .accessibilityIdentifier("chekinana.scan.review.date.\(position)")
        }
        .overlay(alignment: .topLeading) {
            if selectedIdols.count > 1 {
                ChekinanaAccessibilityValueMarker(
                    identifier: "chekinana.scan.review.avatar-count.\(position)",
                    label: "Selected Idol avatar count",
                    value: selectedIdols.count.formatted()
                )
            }
        }
    }

    @ViewBuilder
    private func compactAvatarStack(_ selectedIdols: [Idol], position: Int) -> some View {
        if selectedIdols.isEmpty {
            ChekinanaNeutralIdolAvatar(size: 32)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(selectedIdols) { idol in
                        ChekinanaIdolAvatar(idol: idol, size: 32)
                    }
                }
            }
            .accessibilityIdentifier("chekinana.scan.review.avatar-strip.\(position)")
            .accessibilityValue(selectedIdols.count.formatted())
        }
    }

    private func temporaryActionRow(
        _ card: ChekinanaChekiCard,
        temporary: ChekinanaConfirmationLedger.TemporaryCheki
    ) -> some View {
        HStack(spacing: 4) {
            temporaryActionButton(
                "Download",
                systemImage: "square.and.arrow.down",
                identifier: "chekinana.scan.review.download.\(card.id.uuidString.lowercased())"
            ) { download(card) }
            .disabled(!allowsCardInteraction(card.id))
            temporaryActionButton(
                annotationVisibleIDs.contains(card.id) ? "View clean" : "View annotation",
                systemImage: annotationVisibleIDs.contains(card.id)
                    ? "photo" : "viewfinder",
                identifier: "chekinana.scan.review.annotation.\(card.id.uuidString.lowercased())"
            ) { toggleSourceAnnotation(card.id, available: temporary.sourceAnnotation != nil) }
            .disabled(temporary.sourceAnnotation == nil || isSaving)
        }
    }

    private func temporaryActionButton(
        _ title: String,
        systemImage: String,
        identifier: String,
        value: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(identifier)
    }

    private var orderedIdols: [Idol] {
        ChekinanaIdolOrdering.ordered(idols)
    }

    private func allowsCardInteraction(_ id: UUID) -> Bool {
        ChekinanaScanReviewInteractionPolicy.allowsCardInteraction(
            isSaving: isSaving,
            isRotating: rotatingIDs.contains(id),
            isDownloading: downloadingIDs.contains(id)
        )
    }

    private func beginSelectingIdols(
        _ temporary: ChekinanaConfirmationLedger.TemporaryCheki
    ) {
        guard allowsCardInteraction(temporary.id) else { return }
        idolSelectionDraft = .init(
            id: temporary.id,
            selectedIDs: Set(temporary.idolIDs)
        )
    }

    private func saveIdolSelection(id: UUID, selectedIDs: Set<UUID>) -> Bool {
        guard allowsCardInteraction(id),
              ledger.replaceTemporaryChekiIdols(
            id: id,
            idolIDs: orderedIdols.filter { selectedIDs.contains($0.id) }.map(\.id)
        ) else {
            return false
        }
        return reconcileThenRefresh(id)
    }

    private func beginSelectingDate(
        _ temporary: ChekinanaConfirmationLedger.TemporaryCheki
    ) {
        guard allowsCardInteraction(temporary.id) else { return }
        dateSelectionDraft = .init(id: temporary.id, date: temporary.date)
    }

    private func saveDateSelection(id: UUID, date: Date?) -> Bool {
        guard allowsCardInteraction(id),
              let temporary = ledger.temporaryCheki(id) else {
            return false
        }
        let automaticEventID = temporary.explicitlyEditedFields.contains(.event)
            ? temporary.eventID
            : ChekinanaChekiEventAutoAssociation.uniqueEventID(
                for: date,
                events: events.map { ($0.id, $0.date) }
            )
        guard ledger.updateTemporaryChekiDate(
            id: id,
            date: date,
            automaticEventID: automaticEventID
        ) else {
            return false
        }
        return reconcileThenRefresh(id)
    }

    private func toggleFavorite(_ id: UUID) {
        guard ledger.toggleTemporaryChekiFavorite(id: id) != nil else {
            statusMessage = "这张临时 Cheki 已失效或进入待确认状态。"
            return
        }
        refreshCard(id)
    }

    private func toggleUserAppears(_ id: UUID) {
        guard allowsCardInteraction(id),
              ledger.toggleTemporaryChekiUserAppears(id: id) != nil else {
            statusMessage = ChekinanaProductCopy.text(
                "scan.temporary_unavailable",
                "This temporary Cheki is no longer available."
            )
            return
        }
        refreshCard(id)
    }

    private func toggleSourceAnnotation(_ id: UUID, available: Bool) {
        guard !isSaving else { return }
        guard available else {
            annotationVisibleIDs.remove(id)
            return
        }
        if annotationVisibleIDs.contains(id) {
            annotationVisibleIDs.remove(id)
        } else {
            annotationVisibleIDs.insert(id)
        }
    }

    private func rotate(_ id: UUID) {
        guard allowsCardInteraction(id),
              let temporary = ledger.temporaryCheki(id) else { return }
        let expectedQuarterTurns = temporary.imageRotationQuarterTurns
        let sourceImage = temporary.image
        let sourceDateAnnotation = temporary.dateAnnotationState
        rotatingIDs.insert(id)
        Task {
            defer { rotatingIDs.remove(id) }
            do {
                let rotated = try await ChekinanaScanCleanImageRotation.counterclockwise(
                    sourceImage
                )
                let thumbnail = await ChekinanaImageWorker.thumbnailDataBatch(
                    from: [rotated.data]
                ).first ?? nil
                guard ledger.temporaryCheki(id)?.imageRotationQuarterTurns
                    == expectedQuarterTurns else { return }
                guard ledger.replaceTemporaryChekiImage(
                    id: id,
                    image: rotated,
                    thumbnailImageData: thumbnail,
                    dateAnnotationState: ChekinanaScanCleanImageRotation
                        .counterclockwiseDateAnnotation(sourceDateAnnotation)
                ) else {
                    statusMessage = ChekinanaProductCopy.text(
                        "scan.temporary_unavailable",
                        "This temporary Cheki is no longer available."
                    )
                    return
                }
                refreshCard(id)
            } catch {
                statusMessage = ChekinanaProductCopy.text(
                    "scan.rotate_failed",
                    "Couldn't rotate this Cheki. The original is unchanged."
                )
            }
        }
    }

    private func beginEditing(_ temporary: ChekinanaConfirmationLedger.TemporaryCheki) {
        guard allowsCardInteraction(temporary.id) else { return }
        reconcileExistingMatch(for: temporary.id)
        guard let temporary = ledger.temporaryCheki(temporary.id) else { return }
        editorDraft = .init(
            id: temporary.id,
            idolIDs: Set(temporary.idolIDs),
            hasDate: temporary.date != nil,
            date: temporary.date.flatMap {
                ChekinanaDateOnly.displayDate(from: $0, calendar: .current)
            } ?? Date(),
            eventID: temporary.eventID,
            eventWasExplicitlyEdited: temporary.explicitlyEditedFields.contains(.event),
            idxText: temporary.idx.map(String.init) ?? "",
            initialIdxText: temporary.idx.map(String.init) ?? "",
            existingChekiID: temporary.existingChekiID,
            existingSelectionIsManual: temporary.existingSelectionIsManual,
            userAppears: temporary.userAppears,
            size: temporary.size,
            isFavorite: temporary.isFavorite,
            hasPostedToSNS: temporary.hasPostedToSNS,
            note: temporary.note
        )
    }

    private func saveEditor() {
        guard let draft = editorDraft,
              allowsCardInteraction(draft.id) else { return }
        let date: Date?
        if draft.hasDate {
            guard let canonical = ChekinanaDateOnly.canonicalDate(
                from: draft.date,
                displayedIn: .current
            ) else {
                statusMessage = "Unable to normalize the selected date."
                return
            }
            date = canonical
        } else {
            date = nil
        }
        let normalizedIdxText = draft.idxText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let idx: Int?
        if normalizedIdxText.isEmpty {
            idx = nil
        } else if let parsed = Int(normalizedIdxText), parsed > 0 {
            idx = parsed
        } else {
            statusMessage = "Index must be empty or a positive integer."
            return
        }
        let group = ChekinanaChekiGroupKey(
            idolIDs: Array(draft.idolIDs),
            date: date
        )
        if idx != nil, group == nil {
            statusMessage = "A positive index requires both a date and at least one Idol."
            return
        }
        if normalizedIdxText != draft.initialIdxText,
           let idx, let group,
           chekis.contains(where: {
               $0.id != draft.existingChekiID
                   && ChekinanaChekiGroupKey(
                       idolIDs: $0.idols.map(\.id),
                       date: $0.date
                   ) == group
                   && $0.idx == idx
           }) {
            statusMessage = "Index #\(idx) is already used in this Idol/date group."
            return
        }
        let resolvedEventID: UUID?
        let eventWasAutoMatched: Bool
        if draft.eventWasExplicitlyEdited {
            resolvedEventID = draft.eventID
            eventWasAutoMatched = false
        } else {
            resolvedEventID = ChekinanaChekiEventAutoAssociation.uniqueEventID(
                for: date,
                events: events.map { ($0.id, $0.date) }
            )
            eventWasAutoMatched = resolvedEventID != nil
        }
        guard ledger.updateTemporaryCheki(
            id: draft.id,
            idolIDs: Array(draft.idolIDs),
            date: date,
            eventID: resolvedEventID,
            userAppears: draft.userAppears,
            size: draft.size,
            isFavorite: draft.isFavorite,
            hasPostedToSNS: draft.hasPostedToSNS,
            note: draft.note,
            idx: idx,
            idxWasManuallyEdited: normalizedIdxText != draft.initialIdxText,
            existingChekiID: draft.existingChekiID,
            existingSelectionIsManual: draft.existingSelectionIsManual,
            eventWasExplicitlyEdited: draft.eventWasExplicitlyEdited,
            eventWasAutoMatched: eventWasAutoMatched
        ) else {
            statusMessage = "这张临时 Cheki 已失效或进入待确认状态。"
            editorDraft = nil
            return
        }
        // The editor and Save all both read the ledger as their source of
        // truth. Rebuild the visible card unconditionally; existing-match
        // reconciliation may legitimately be a no-op and must not suppress UI.
        guard reconcileThenRefresh(draft.id) else {
            statusMessage = "这张临时 Cheki 已失效或进入待确认状态。"
            editorDraft = nil
            return
        }
        editorDraft = nil
    }

    @discardableResult
    private func reconcileExistingMatch(for id: UUID) -> Bool {
        guard let temporary = ledger.temporaryCheki(id) else { return false }
        let allCandidates = matchingExistingChekis(
            idolIDs: Set(temporary.idolIDs),
            date: temporary.date
        )
        let candidates = availableExistingChekis(
            idolIDs: Set(temporary.idolIDs),
            date: temporary.date,
            excludingTemporaryID: id
        )
        var targetID = temporary.existingChekiID
        var isManual = temporary.existingSelectionIsManual
        if isManual, let selectedTargetID = targetID,
           !candidates.contains(where: { $0.id == selectedTargetID }) {
            isManual = false
            targetID = nil
        }
        if !isManual {
            targetID = allCandidates.count == 1 && candidates.count == 1
                ? candidates[0].id : nil
        }
        let inheritedIdx = targetID.flatMap { targetID in
            candidates.first(where: { $0.id == targetID })?.idx
        }
        let inheritedUserAppears = targetID.flatMap { targetID in
            candidates.first(where: { $0.id == targetID })?.userAppears
        }
        let desiredIdx = temporary.explicitlyEditedFields.contains(.idx)
            ? temporary.idx : inheritedIdx
        let desiredUserAppears = temporary.explicitlyEditedFields.contains(.userAppears)
            ? temporary.userAppears
            : (inheritedUserAppears ?? temporary.inferredUserAppears)
        guard temporary.existingChekiID != targetID
                || temporary.existingSelectionIsManual != isManual
                || temporary.idx != desiredIdx
                || temporary.userAppears != desiredUserAppears else { return true }
        guard ledger.setTemporaryExistingCheki(
            id: id,
            existingChekiID: targetID,
            selectionIsManual: isManual,
            inheritedIdx: inheritedIdx,
            inheritedUserAppears: inheritedUserAppears
        ) else { return false }
        refreshCard(id)
        return true
    }

    private func reconcileThenRefresh(_ id: UUID) -> Bool {
        ChekinanaScanReviewReconciliationPolicy.reconcileThenRefresh(
            reconcile: { reconcileExistingMatch(for: id) },
            refresh: { refreshCard(id) }
        )
    }

    @discardableResult
    private func refreshCard(_ id: UUID) -> Bool {
        guard let temporary = ledger.temporaryCheki(id),
              let index = cards.firstIndex(where: { $0.id == id }) else { return false }
        cards[index] = ChekinanaChekiCard(
            id: temporary.id,
            imageRef: nil,
            createdAt: temporary.createdAt,
            confirmationCode: nil,
            thumbnailImageData: temporary.thumbnailImageData,
            idolNames: temporary.idolIDs.compactMap { id in
                idols.first { $0.id == id }?.name
            },
            eventName: temporary.eventID.flatMap { id in
                events.first { $0.id == id }?.name
            },
            eventDateText: temporary.date.map(ChekinanaProductDate.displayString),
            userAppears: temporary.userAppears,
            size: temporary.size,
            isFavorite: temporary.isFavorite,
            hasPostedToSNS: temporary.hasPostedToSNS,
            note: temporary.note,
            dateAnnotationState: temporary.dateAnnotationState
        )
        return true
    }

    private func delete(_ card: ChekinanaChekiCard) {
        deleteTemporary(id: card.id)
    }

    private func retireHiddenTemporaryCards() {
        let hiddenCardIDs = ChekinanaHiddenTemporaryReviewPolicy.hiddenCardIDs(
            cards,
            hiddenIdolIDs: hiddenIdols.hiddenIDs,
            idolIDs: { ledger.temporaryCheki($0)?.idolIDs }
        )
        guard !hiddenCardIDs.isEmpty else { return }
        if let id = editorDraft?.id, hiddenCardIDs.contains(id) { editorDraft = nil }
        if let id = idolSelectionDraft?.id, hiddenCardIDs.contains(id) {
            idolSelectionDraft = nil
        }
        if let id = dateSelectionDraft?.id, hiddenCardIDs.contains(id) {
            dateSelectionDraft = nil
        }
        annotationVisibleIDs.subtract(hiddenCardIDs)
        for id in hiddenCardIDs {
            _ = ledger.discardTemporaryCheki(id: id)
        }
        cards.removeAll { hiddenCardIDs.contains($0.id) }
    }

    private func deleteTemporary(id: UUID) {
        guard allowsCardInteraction(id),
              ledger.discardTemporaryCheki(id: id) else {
            statusMessage = "无法删除这张临时 Cheki。"
            return
        }
        annotationVisibleIDs.remove(id)
        rotatingIDs.remove(id)
        cards.removeAll { $0.id == id }
        if ChekinanaScanReviewLifecycle.shouldDiscardAfterDeletion(
            cardsAreEmpty: cards.isEmpty,
            hasCapturedPhoto: sourceRegistry.hasCapturedPhoto
        ) {
            discardEmptyReview()
        }
    }

    private func deleteLatestCapturedPhoto() {
        guard ChekinanaScanReviewInteractionPolicy.allowsConfirmAll(
            isSaving: isSaving,
            hasRotations: !rotatingIDs.isEmpty,
            hasDownloads: !downloadingIDs.isEmpty
        ) else { return }
        let result = sourceRegistry.removeLatestCapturedPhoto { sourceID in
            ledger.discardTemporaryChekis(sourceID: sourceID)
        }
        switch result {
        case .unavailable:
            return
        case .locked:
            statusMessage = "该相机源仍有结果处于保存确认中，未删除任何内容。"
        case .removed(let sourceID, let temporaryIDs):
            let removedIDs = Set(temporaryIDs)
            cards.removeAll { removedIDs.contains($0.id) }
            onDeleteSource(sourceID)
            if ChekinanaScanReviewLifecycle.shouldDiscardAfterDeletion(
                cardsAreEmpty: cards.isEmpty,
                hasCapturedPhoto: sourceRegistry.hasCapturedPhoto
            ) {
                discardEmptyReview()
            }
        }
    }

    private func discardEntireReview() {
        guard ChekinanaScanReviewInteractionPolicy.allowsConfirmAll(
            isSaving: isSaving,
            hasRotations: !rotatingIDs.isEmpty,
            hasDownloads: !downloadingIDs.isEmpty
        ) else { return }
        let sourceIDs = sourceRegistry.sourceIDs
        for sourceID in sourceIDs {
            _ = ledger.discardTemporaryChekis(sourceID: sourceID)
        }
        for card in cards {
            _ = ledger.discardTemporaryCheki(id: card.id)
        }
        annotationVisibleIDs.removeAll()
        rotatingIDs.removeAll()
        downloadingIDs.removeAll()
        cards = []
        sourceRegistry.removeSources(ids: Set(sourceIDs))
        onDiscarded(sourceIDs)
    }

    private func discardEmptyReview() {
        guard cards.isEmpty else { return }
        let sourceIDs = sourceRegistry.sourceIDs
        sourceRegistry.removeSources(ids: Set(sourceIDs))
        onDiscarded(sourceIDs)
    }

    private func download(_ card: ChekinanaChekiCard) {
        guard allowsCardInteraction(card.id) else { return }
        downloadingIDs.insert(card.id)
        Task {
            defer { downloadingIDs.remove(card.id) }
            let executor = ChekinanaCommandExecutor(
                modelContext: modelContext,
                confirmationLedger: ledger
            )
            let response = await executor.execute(
                "downloadtemporarycheki \(card.id.uuidString.lowercased())"
            )
            if case .text(let text) = response {
                statusMessage = text.replacingOccurrences(of: "error: ", with: "")
            }
        }
    }

    @MainActor
    private func confirmAll() async {
        guard ChekinanaScanReviewInteractionPolicy.allowsConfirmAll(
            isSaving: isSaving,
            hasRotations: !rotatingIDs.isEmpty,
            hasDownloads: !downloadingIDs.isEmpty
        ) else {
            statusMessage = "请等待旋转或下载完成后再保存。"
            return
        }
        isSaving = true
        batchSaveProgress = nil
        defer {
            batchSaveProgress = nil
            isSaving = false
        }
        for card in cards {
            guard let temporary = ledger.temporaryCheki(card.id),
                  !temporary.existingSelectionIsManual else { continue }
            _ = ledger.setTemporaryExistingCheki(
                id: card.id,
                existingChekiID: nil,
                selectionIsManual: false,
                inheritedIdx: nil
            )
        }
        for card in cards {
            reconcileExistingMatch(for: card.id)
        }
        let executor = ChekinanaCommandExecutor(
            modelContext: modelContext,
            confirmationLedger: ledger,
            batchSaveProgressObserver: { progress in
                batchSaveProgress = progress
            }
        )
        guard let selection = ChekinanaScanReviewSavePlan.selection(
            cardIDs: cards.map(\.id),
            containsTemporaryCheki: ledger.containsTemporaryCheki
        ) else {
            reconcileCardsWithLedger()
            statusMessage = "部分临时 Cheki 已失效；列表已刷新，请检查后重试。"
            return
        }
        let prepared = await executor.execute("addscancheki \(selection)")
        guard case .pendingChekiCards(_, let pendingCards, _) = prepared else {
            statusMessage = ChekinanaConfirmationResponseValidator.failureDescription(
                for: prepared,
                fallback: "无法准备保存临时 Cheki。"
            )
            return
        }
        let confirmationCodes = pendingCards.compactMap(\.confirmationCode)
        guard confirmationCodes.count == pendingCards.count else {
            ledger.cancelTemporaryChekiConfirmations(confirmationCodes)
            reconcileCardsWithLedger()
            statusMessage = "保存确认信息不完整；临时 Cheki 已解除锁定，可以修改后重试。"
            return
        }
        let result = await executor.confirmTemporaryChekiBatch(
            confirmationCodes: confirmationCodes
        )
        let expectedIDs = pendingCards.map(\.id)
        guard case .chekiCards(let savedCards) = result,
              savedCards.map(\.id) == expectedIDs else {
            ledger.cancelTemporaryChekiConfirmations(confirmationCodes)
            reconcileCardsWithLedger()
            statusMessage = ChekinanaConfirmationResponseValidator.failureDescription(
                for: result,
                fallback: "批量保存未返回可验证的完整结果；临时 Cheki 已保留。"
            )
            return
        }
        reconcileCardsWithLedger()
        guard cards.isEmpty else {
            statusMessage = "部分临时 Cheki 状态发生变化；未保存项目仍可重试。"
            return
        }
        onSaved(sourceRegistry.sourceIDs)
    }

    private func reconcileCardsWithLedger() {
        cards.removeAll { !ledger.containsTemporaryCheki($0.id) }
        for id in cards.map(\.id) {
            refreshCard(id)
        }
    }
}

private struct ChekinanaTemporaryImagePreview: View {
    let imageData: Data
    let annotationState: ChekinanaChekiDateAnnotationState
    let sourceAnnotation: ChekinanaScannerSourceAnnotation?
    let showsSourceAnnotation: Bool
    let cacheKey: String
    @State private var image: ChekinanaRenderedImage?
    @State private var requestedToken: String?

    private var usesSourceAnnotation: Bool {
        showsSourceAnnotation && sourceAnnotation?.isValid == true
    }

    private var displayedData: Data {
        ChekinanaScanAnnotationDisplayPolicy.displayedData(
            cleanImageData: imageData,
            sourceAnnotation: sourceAnnotation,
            showsSourceAnnotation: showsSourceAnnotation
        )
    }

    private var displayToken: String {
        "\(cacheKey)-\(usesSourceAnnotation ? "source" : "clean")"
    }

    var body: some View {
        GeometryReader { geometry in
            if let image {
                let imageSize = CGSize(width: image.cgImage.width, height: image.cgImage.height)
                let fitted = aspectFitRect(imageSize: imageSize, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    if !usesSourceAnnotation,
                       case .detected(let annotation) = annotationState {
                        let box = annotation.boundingBox
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.orange, lineWidth: 3)
                            .background(Color.orange.opacity(0.10))
                            .frame(
                                width: fitted.width * CGFloat(box.x2 - box.x1) / 1_000,
                                height: fitted.height * CGFloat(box.y2 - box.y1) / 1_000
                            )
                            .offset(
                                x: fitted.minX + fitted.width * CGFloat(box.x1) / 1_000,
                                y: fitted.minY + fitted.height * CGFloat(box.y1) / 1_000
                            )
                            .accessibilityHidden(true)
                    }
                }
            } else {
                Color.clear
            }
        }
        .task(id: displayToken) {
            let token = displayToken
            let data = displayedData
            requestedToken = token
            image = nil
            let loaded = await ChekinanaThumbnailCache.shared.thumbnailImage(
                from: data,
                key: token,
                maxDimension: 1_200
            )
            guard ChekinanaScanPreviewLoadPublicationPolicy.canPublish(
                completedToken: token,
                requestedToken: requestedToken,
                isCancelled: Task.isCancelled
            ) else { return }
            image = loaded
        }
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct ChekinanaNeutralIdolAvatar: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .tertiarySystemGroupedBackground))
            Image(systemName: "person.crop.circle")
                .font(.system(size: size * 0.58, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .overlay { Circle().stroke(Color.secondary.opacity(0.28), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

private struct ChekinanaNativeIdolSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let idols: [Idol]
    let onSave: (Set<UUID>) -> Bool
    @State private var selectedIDs: Set<UUID>
    @State private var errorMessage: String?

    init(
        idols: [Idol],
        initialSelectedIDs: Set<UUID>,
        onSave: @escaping (Set<UUID>) -> Bool
    ) {
        self.idols = idols
        self.onSave = onSave
        _selectedIDs = State(initialValue: initialSelectedIDs)
    }

    private var orderedIdols: [Idol] {
        ChekinanaIdolOrdering.ordered(idols)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 68, maximum: 82), spacing: 14)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    idolOption(idol: nil)
                    ForEach(orderedIdols) { idol in
                        idolOption(idol: idol)
                    }
                }
                .padding(16)
            }
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle("Select Idols")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("chekinana.scan.review.idol-picker.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                        .accessibilityIdentifier("chekinana.scan.review.idol-picker.done")
                }
            }
            .alert("Unable to update Idol", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .accessibilityIdentifier("chekinana.scan.review.idol-picker")
    }

    private func idolOption(idol: Idol?) -> some View {
        let isSelected = idol.map { selectedIDs.contains($0.id) } ?? selectedIDs.isEmpty
        let label = idol?.name ?? "Unassigned"
        let identifier = idol.map {
            "chekinana.scan.review.idol-option.\($0.id.uuidString.lowercased())"
        } ?? "chekinana.scan.review.idol-option.unassigned"
        return Button {
            if let idol {
                if selectedIDs.contains(idol.id) {
                    selectedIDs.remove(idol.id)
                } else {
                    selectedIDs.insert(idol.id)
                }
            } else {
                selectedIDs.removeAll()
            }
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    if let idol {
                        ChekinanaIdolAvatar(idol: idol, size: 62)
                    } else {
                        ChekinanaNeutralIdolAvatar(size: 62)
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, ChekinanaProductTheme.accent)
                            .background(Circle().fill(.white))
                            .offset(x: 4, y: -4)
                    }
                }
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .padding(.vertical, 6)
            .background(isSelected ? ChekinanaProductTheme.softAccent : ChekinanaProductTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func save() {
        guard onSave(selectedIDs) else {
            errorMessage = "这张临时 Cheki 已失效或进入待确认状态；当前选择仍保留。"
            return
        }
        dismiss()
    }
}

private struct ChekinanaNativeDateSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Date?) -> Bool
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var errorMessage: String?

    init(initialDate: Date?, onSave: @escaping (Date?) -> Bool) {
        self.onSave = onSave
        _hasDate = State(initialValue: initialDate != nil)
        _date = State(initialValue: initialDate.flatMap {
            ChekinanaDateOnly.displayDate(from: $0, calendar: .current)
        } ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use selected date", isOn: $hasDate)
                        .accessibilityIdentifier("chekinana.scan.review.date-picker.use-date")
                    if hasDate {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                            .accessibilityIdentifier("chekinana.scan.review.date-picker.value")
                    } else {
                        Text("日期未识别")
                            .foregroundStyle(.secondary)
                    }
                    Button("Clear date", role: .destructive) {
                        hasDate = false
                    }
                    .accessibilityIdentifier("chekinana.scan.review.date-picker.clear")
                } header: {
                    Text("Date")
                } footer: {
                    Text("清除后会保留原图和 Event，仅将日期恢复为未识别。")
                }
            }
            .navigationTitle("Select Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("chekinana.scan.review.date-picker.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                        .accessibilityIdentifier("chekinana.scan.review.date-picker.done")
                }
            }
            .alert("Unable to update date", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .accessibilityIdentifier("chekinana.scan.review.date-picker")
    }

    private func save() {
        let normalizedDate: Date?
        if hasDate {
            guard let normalized = ChekinanaDateOnly.canonicalDate(
                from: date,
                displayedIn: .current
            ) else {
                errorMessage = "无法规范化所选日期。"
                return
            }
            normalizedDate = normalized
        } else {
            normalizedDate = nil
        }
        guard onSave(normalizedDate) else {
            errorMessage = "这张临时 Cheki 已失效或进入待确认状态；当前日期仍保留。"
            return
        }
        dismiss()
    }
}

private struct ChekinanaNativeTemporaryEditor: View {
    @Binding var draft: ChekinanaNativeTemporaryDraft
    let idols: [Idol]
    let events: [Event]
    let existingCandidates: [Cheki]
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Idols") {
                    if idols.isEmpty { Text("No local Idols").foregroundStyle(.secondary) }
                    ForEach(idols) { idol in
                        Toggle(idol.name, isOn: Binding(
                            get: { draft.idolIDs.contains(idol.id) },
                            set: { selected in
                                if selected { draft.idolIDs.insert(idol.id) }
                                else { draft.idolIDs.remove(idol.id) }
                            }
                        ))
                    }
                }
                Section("Date") {
                    Toggle("Set date", isOn: $draft.hasDate)
                    if draft.hasDate {
                        DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    }
                }
                Section("Event") {
                    Picker("Event", selection: Binding(
                        get: { draft.eventID },
                        set: {
                            draft.eventID = $0
                            draft.eventWasExplicitlyEdited = true
                        }
                    )) {
                        Text("None").tag(UUID?.none)
                        ForEach(events) { event in
                            Text(event.name).tag(Optional(event.id))
                        }
                    }
                }
                Section("Save destination") {
                    if existingCandidates.isEmpty {
                        Label("Create new Cheki", systemImage: "plus.square")
                    } else {
                        Picker(
                            "Destination",
                            selection: Binding(
                                get: { draft.existingChekiID },
                                set: { selectedID in
                                    let indexWasManual = draft.idxText
                                        != draft.initialIdxText
                                    draft.existingChekiID = selectedID
                                    draft.existingSelectionIsManual = true
                                    if !indexWasManual {
                                        let inherited = selectedID.flatMap { id in
                                            existingCandidates.first(where: {
                                                $0.id == id
                                            })?.idx
                                        }
                                        draft.idxText = inherited.map(String.init) ?? ""
                                        draft.initialIdxText = draft.idxText
                                    }
                                }
                            )
                        ) {
                            Text("Create new Cheki").tag(UUID?.none)
                            ForEach(existingCandidates) { cheki in
                                Text(
                                    "Existing\(cheki.idx.map { " #\($0)" } ?? "") · \(String(cheki.id.uuidString.prefix(8)))"
                                ).tag(Optional(cheki.id))
                            }
                        }
                    }
                }
                Section("Other") {
                    TextField("Index (optional)", text: $draft.idxText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("chekinana.scan.review.editor.idx")
                    Text(
                        "Current index: \(draft.initialIdxText.isEmpty ? "None" : "#\(draft.initialIdxText)")"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Picker(
                        ChekinanaProductCopy.text("scan.shot_type", "Shot type"),
                        selection: $draft.userAppears
                    ) {
                        Text(ChekinanaProductCopy.text(
                            "scan.shot_type.unknown",
                            "Unknown"
                        )).tag(Bool?.none)
                        Text("solo").tag(Optional(false))
                        Text("2-shot").tag(Optional(true))
                    }
                    .accessibilityIdentifier("chekinana.scan.review.editor.user-appears")
                    .accessibilityValue(
                        draft.userAppears.map { $0 ? "2-shot" : "solo" }
                            ?? ChekinanaProductCopy.text(
                                "scan.shot_type.unknown",
                                "Unknown"
                            )
                    )
                    Picker("Size", selection: $draft.size) {
                        Text("Unset").tag(ChekiSize?.none)
                        ForEach(ChekiSize.allCases) { size in
                            Text(size.rawValue).tag(Optional(size))
                        }
                    }
                    .accessibilityIdentifier("chekinana.scan.review.editor.size")
                    .accessibilityValue(draft.size?.rawValue ?? "unset")
                    Toggle("Favorite", isOn: $draft.isFavorite)
                    Toggle("Posted to SNS", isOn: $draft.hasPostedToSNS)
                    TextField("Note", text: $draft.note, axis: .vertical)
                }
            }
            .navigationTitle("Edit temporary Cheki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("chekinana.scan.review.editor.cancel")
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                    .accessibilityLabel("Delete temporary Cheki")
                    .accessibilityIdentifier("chekinana.scan.review.editor.delete")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: onSave) }
            }
        }
        .accessibilityIdentifier("chekinana.scan.review.editor")
    }
}

private struct ChekinanaCandidatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let idols: [Idol]
    @Binding var selectedIDs: Set<UUID>
    @Binding var includesUnassigned: Bool
    @Binding var similarityThreshold: Double

    private var orderedIdols: [Idol] {
        ChekinanaIdolOrdering.ordered(idols.filter(\.hasRecognitionPatterns))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 82, maximum: 112), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("If the Idol may be outside the selected range, enable Unassigned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Unassigned", isOn: $includesUnassigned)
                        .accessibilityValue(includesUnassigned ? "Selected" : "Not selected")
                        .accessibilityIdentifier("chekinana.scan.candidate.unassigned")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Similarity threshold")
                            Spacer()
                            Text(similarityThreshold, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $similarityThreshold, in: 0.50...0.99, step: 0.01)
                            .accessibilityIdentifier("chekinana.scan.candidate.threshold")
                    }
                    Divider()
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(orderedIdols) { idol in
                            idolOption(idol)
                        }
                    }
                }
                .padding(16)
            }
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle("Candidates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("chekinana.scan.candidates.done")
                }
            }
        }
    }

    private func idolOption(_ idol: Idol) -> some View {
        let isSelected = selectedIDs.contains(idol.id)
        return Button {
            if selectedIDs.contains(idol.id) {
                selectedIDs.remove(idol.id)
            } else {
                selectedIDs.insert(idol.id)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                ChekinanaIdolAvatar(idol: idol, size: 62)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, ChekinanaProductTheme.accent)
                        .background(Circle().fill(.white))
                        .offset(x: 4, y: -4)
                }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(idol.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chekinana.scan.candidate.\(idol.id.uuidString.lowercased())")
    }
}

private struct ChekinanaSelectedPhotoThumbnail: View {
    let input: ChekinanaNativeScanInput
    let isRotationDisabled: Bool
    let isDeleteDisabled: Bool
    let isRotationInFlight: Bool
    let onRotationBegan: () -> UUID?
    let onRotationCompleted: (UUID, Int) -> Bool
    let onRotationFailed: (UUID, Bool) -> Void
    let onDelete: () -> Void
    @State private var image: ChekinanaRenderedImage?
    @State private var loadFailed = false
    @State private var loadGeneration = UUID()

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemGroupedBackground)
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 104, height: 142)
                    .clipped()
            } else if loadFailed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Photo preview unavailable")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 82, height: 82)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "chekinana.scan.input.image.\(input.id.uuidString.lowercased())"
        )
        .overlay(alignment: .topLeading) {
            Button {
                rotateCounterclockwise()
            } label: {
                Image(systemName: "rotate.left")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.72))
                    .clipShape(Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRotationDisabled || isRotationInFlight || image == nil)
            .opacity(isRotationDisabled ? 0.45 : 1)
            .accessibilityLabel(ChekinanaProductCopy.text(
                "scan.input.rotate_counterclockwise",
                "Rotate input photo counterclockwise"
            ))
            .accessibilityHint(ChekinanaProductCopy.text(
                "scan.input.rotate_hint",
                "Rotates only this input photo counterclockwise."
            ))
            .accessibilityValue(ChekinanaProductCopy.format(
                "scan.rotate_state",
                "Counterclockwise turn %lld of 4",
                Int64(input.rotationQuarterTurns)
            ))
            .accessibilityIdentifier(
                "chekinana.scan.input.rotate.\(input.id.uuidString.lowercased())"
            )
            .padding(2)
            .zIndex(3)
        }
        .overlay(alignment: .topTrailing) {
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.red)
                    .clipShape(Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDeleteDisabled || isRotationInFlight)
            .opacity(isDeleteDisabled ? 0.45 : 1)
            .zIndex(3)
            .accessibilityLabel(ChekinanaProductCopy.text(
                "scan.input.delete",
                "Delete input photo"
            ))
            .accessibilityHint(ChekinanaProductCopy.text(
                "scan.input.delete_hint",
                "Removes only this photo from the scan inputs."
            ))
            .accessibilityIdentifier(
                "chekinana.scan.input.delete.\(input.id.uuidString.lowercased())"
            )
            .padding(2)
        }
        .task(id: input.id) {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        let generation = UUID()
        loadGeneration = generation
        do {
            let original = try await ChekinanaProductMediaLoader.loadUnrotated(input)
            try Task.checkCancellation()
            guard var thumbnail = await ChekinanaImageWorker.thumbnailImage(
                from: original.data,
                maxDimension: 240
            ) else {
                throw ChekinanaProductMediaError.unreadableImage
            }
            for _ in 0..<input.rotationQuarterTurns {
                thumbnail = try await ChekinanaProductMediaLoader
                    .rotatePreviewCounterclockwise(
                    thumbnail
                )
            }
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            image = thumbnail
            loadFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation else { return }
            loadFailed = true
        }
    }

    private func rotateCounterclockwise() {
        guard !isRotationDisabled,
              !isRotationInFlight,
              let image,
              let token = onRotationBegan() else { return }
        let expectedQuarterTurns = input.rotationQuarterTurns
        let nextQuarterTurns = input.nextCounterclockwiseRotationQuarterTurns
        Task {
            do {
                let rotated = try await ChekinanaProductMediaLoader
                    .rotatePreviewCounterclockwise(image)
                try Task.checkCancellation()
                guard input.rotationQuarterTurns == expectedQuarterTurns,
                      onRotationCompleted(token, nextQuarterTurns) else {
                    onRotationFailed(token, false)
                    return
                }
                self.image = rotated
            } catch is CancellationError {
                onRotationFailed(token, false)
            } catch {
                onRotationFailed(token, true)
            }
        }
    }
}

private struct ChekinanaProductTransferableImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            ChekinanaProductTransferableImage(data: data)
        }
    }
}

private struct ChekinanaIdolsView: View {
    private static let dragRowStride: CGFloat = 98

    @Environment(\.modelContext) private var modelContext
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Query private var idols: [Idol]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let openMenu: () -> Void

    @State private var query = ""
    @State private var selectedIdol: Idol?
    @State private var isAddPresented = false
    @State private var draggingIdolID: UUID?
    @State private var dragStartOrderIDs: [UUID] = []
    @State private var dragPreviewOrderIDs: [UUID] = []
    @State private var dragResidualOffsetY: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    private var orderedIdols: [Idol] {
        let persisted = ChekinanaIdolOrdering.ordered(
            ChekinanaVisibilityPolicy.visibleIdols(
                idols,
                hiddenIDs: hiddenIdols.hiddenIDs
            )
        )
        guard !dragPreviewOrderIDs.isEmpty else { return persisted }
        let byID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        let previewed = dragPreviewOrderIDs.compactMap { byID[$0] }
        let previewedIDs = Set(previewed.map(\.id))
        return previewed + persisted.filter { !previewedIDs.contains($0.id) }
    }

    private var filteredIdols: [Idol] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return orderedIdols }
        return orderedIdols.filter {
            $0.name.localizedStandardContains(term)
                || ($0.group?.localizedStandardContains(term) ?? false)
                || $0.note.localizedStandardContains(term)
        }
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            Group {
                if orderedIdols.isEmpty {
                    ChekinanaEmptyState(
                        title: "No Idols yet",
                        message: "添加 Idol 后可关联 Cheki，并在存有 pattern 时用于本机识别。",
                        systemImage: "person.2",
                        actionTitle: "Add Idol",
                        action: { isAddPresented = true }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .chekinanaScreenMarker("chekinana.idols.empty")
                } else {
                    idolsContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle(ChekinanaProductTab.idols.title)
            .toolbar {
                ChekinanaPageToolbar(pageID: "idols", openMenu: openMenu)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAddPresented = true } label: {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("添加 Idol")
                    .accessibilityIdentifier("chekinana.idols.add")
                }
            }
            .sheet(isPresented: $isAddPresented) {
                ChekinanaIdolEditorView(idol: nil)
            }
            .sheet(item: $selectedIdol) { idol in
                ChekinanaIdolDetailView(
                    idol: idol,
                    preparedAvatarImage: nil
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.idols.page")
        .chekinanaScreenMarker("chekinana.idols.page")
    }

    private var idolsContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Idols", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($isSearchFocused)
                        .onSubmit { isSearchFocused = false }
                        .accessibilityLabel("Search Idols")
                        .accessibilityIdentifier("chekinana.idols.search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .chekinanaMinimumTouchTarget()
                        .accessibilityLabel("Clear search")
                        .accessibilityIdentifier("chekinana.idols.search.clear")
                    }
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 46)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(ChekinanaProductTheme.border, lineWidth: 0.5)
                }

                if filteredIdols.isEmpty {
                    ChekinanaEmptyState(
                        title: "No matches",
                        message: "Try another name, group, or note.",
                        systemImage: "magnifyingglass"
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                    .chekinanaScreenMarker("chekinana.idols.no-results")
                } else {
                    if isSearchActive {
                        Label("Clear search to reorder Idols.", systemImage: "line.3.horizontal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("chekinana.idols.reorder.search-disabled")
                    }
                    if isSearchActive {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredIdols) { idol in
                                idolRow(idol)
                            }
                        }
                    } else {
                        reorderableIdolStack
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 110)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var isSearchActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var reorderableIdolStack: some View {
        ZStack(alignment: .top) {
            ForEach(Array(orderedIdols.enumerated()), id: \.element.id) { index, idol in
                idolRow(idol)
                    .offset(y: CGFloat(index) * Self.dragRowStride)
                    .zIndex(draggingIdolID == idol.id ? 100_000 : 0)
                    .animation(
                        draggingIdolID == idol.id ? nil : .snappy(duration: 0.18),
                        value: index
                    )
            }
        }
        .frame(
            height: max(
                0,
                CGFloat(orderedIdols.count) * Self.dragRowStride - 12
            ),
            alignment: .top
        )
        .zIndex(draggingIdolID == nil ? 0 : 100_000)
    }

    @ViewBuilder
    private func idolRow(_ idol: Idol) -> some View {
        ChekinanaIdolRow(
            idol: idol,
            preparedAvatarImage: nil,
            reorderEnabled: !isSearchActive,
            open: { selectedIdol = idol },
            toggleFavorite: { toggleFavorite(idol) },
            isBeingDragged: draggingIdolID == idol.id,
            dragOffsetY: draggingIdolID == idol.id ? dragResidualOffsetY : 0,
            beginDrag: {
                beginDrag(idol.id)
            },
            updateDrag: { translationY in
                updateDrag(translationY: translationY)
            },
            commitDrag: {
                commitDrag()
            },
            cancelDrag: {
                cancelDrag()
            }
        )
        .zIndex(draggingIdolID == idol.id ? 10_000 : 0)
    }

    private func toggleFavorite(_ idol: Idol) {
        try? ChekinanaIdolFavoriteAction.toggle(
            idol,
            in: idols,
            modelContext: modelContext
        )
    }

    private func beginDrag(_ idolID: UUID) {
        guard draggingIdolID == nil else { return }
        guard !isSearchActive,
              idols.contains(where: { $0.id == idolID }) else { return }
        let order = ChekinanaIdolOrdering.ordered(idols).map(\.id)
        draggingIdolID = idolID
        dragStartOrderIDs = order
        dragPreviewOrderIDs = order
        dragResidualOffsetY = 0
    }

    private func updateDrag(translationY: CGFloat) {
        guard let sourceID = draggingIdolID,
              let source = idols.first(where: { $0.id == sourceID }),
              let sourceIndex = dragStartOrderIDs.firstIndex(of: sourceID) else { return }
        let favoriteByID = Dictionary(uniqueKeysWithValues: idols.map { ($0.id, $0.isFavorite) })
        let groupIndices = dragStartOrderIDs.indices.filter {
            favoriteByID[dragStartOrderIDs[$0]] == source.isFavorite
        }
        guard let minimumIndex = groupIndices.first,
              let maximumIndex = groupIndices.last else { return }
        let rowDelta = Int((translationY / Self.dragRowStride).rounded())
        let targetIndex = min(max(sourceIndex + rowDelta, minimumIndex), maximumIndex)
        let targetID = dragStartOrderIDs[targetIndex]
        let updated = ChekinanaIdolOrdering.previewMove(
            sourceID,
            onto: targetID,
            in: dragStartOrderIDs,
            favoriteByID: favoriteByID
        )
        let previewIndex = updated.firstIndex(of: sourceID) ?? sourceIndex
        let previewLayoutShift = CGFloat(previewIndex - sourceIndex) * Self.dragRowStride
        let residualOffsetY = translationY - previewLayoutShift
        if updated != dragPreviewOrderIDs {
            withAnimation(.snappy(duration: 0.16)) {
                dragPreviewOrderIDs = updated
                dragResidualOffsetY = residualOffsetY
            }
        } else {
            dragResidualOffsetY = residualOffsetY
        }
    }

    private func commitDrag() {
        defer { clearDragState() }
        guard let sourceID = draggingIdolID,
              dragPreviewOrderIDs != dragStartOrderIDs,
              let source = idols.first(where: { $0.id == sourceID }),
              ChekinanaIdolOrdering.applyPreviewOrder(
                dragPreviewOrderIDs,
                favorite: source.isFavorite,
                in: idols
              ) else {
            return
        }
        saveOrdering()
    }

    private func cancelDrag() {
        withAnimation(.snappy(duration: 0.16)) {
            clearDragState()
        }
    }

    private func clearDragState() {
        draggingIdolID = nil
        dragStartOrderIDs = []
        dragPreviewOrderIDs = []
        dragResidualOffsetY = 0
    }

    private func saveOrdering() {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
        }
    }
}

private enum ChekinanaIdolAvatarRepairError: LocalizedError {
    case missingCatalogueIdentity(String)

    var errorDescription: String? {
        switch self {
        case .missingCatalogueIdentity(let name):
            "\(name) has no valid managed avatar and no catalogue identity. Edit this Idol and choose a local reference photo, then retry."
        }
    }
}

private struct ChekinanaIdolRow: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let idol: Idol
    let preparedAvatarImage: ChekinanaRenderedImage?
    let reorderEnabled: Bool
    let open: () -> Void
    let toggleFavorite: () -> Void
    let isBeingDragged: Bool
    let dragOffsetY: CGFloat
    let beginDrag: () -> Void
    let updateDrag: (CGFloat) -> Void
    let commitDrag: () -> Void
    let cancelDrag: () -> Void
    @State private var avatarRepairRequest = 0
    @State private var avatarRepairState = ChekinanaIdolAvatarRepairState.idle

    var body: some View {
        let visibleChekiCount = idol.chekis.filter {
            ChekinanaVisibilityPolicy.includesRecord(
                idols: $0.idols,
                hiddenIDs: hiddenIdols.hiddenIDs
            )
        }.count
        let patternStatus = ChekinanaIdolPatternStatus.make(
            hasRecognitionPatterns: idol.hasRecognitionPatterns
        )
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 14) {
                    ChekinanaIdolAvatar(
                        idol: idol,
                        size: 58,
                        preparedImage: preparedAvatarImage
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(idol.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(idol.group?.nonEmpty ?? "Independent")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                ChekinanaMiniChekiIcon()
                                    .frame(
                                        width: ChekinanaMiniChekiIconMetrics.width,
                                        height: ChekinanaMiniChekiIconMetrics.height
                                    )
                                Text(ChekinanaChekiCountLabel.text(visibleChekiCount))
                            }
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Cheki count")
                            .accessibilityValue("\(visibleChekiCount)")
                            .accessibilityIdentifier(
                                "chekinana.idols.cheki-count.\(idol.id.uuidString.lowercased())"
                            )
                            Image(systemName: patternStatus.systemImageName)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(2)
                                .accessibilityHidden(true)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityIdentifier("chekinana.idols.card.\(idol.id.uuidString.lowercased())")
            .accessibilityValue(
                "\(idol.chekis.count) Cheki; \(patternStatus.accessibilityValue)"
            )
            .accessibilityHint(
                reorderEnabled
                    ? "Open Idol details. Use the drag handle to reorder within the favorite group."
                    : "Clear search before reordering."
            )
            Button(action: toggleFavorite) {
                Image(systemName: idol.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(idol.isFavorite ? .yellow : .secondary)
                    .frame(width: 38, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(idol.isFavorite ? "Remove \(idol.name) from favorites" : "Add \(idol.name) to favorites")
            .accessibilityIdentifier("chekinana.idols.favorite.\(idol.id.uuidString.lowercased())")
            dragHandle
        }
        .padding(14)
        .frame(height: 86)
        .background(ChekinanaProductTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(ChekinanaProductTheme.border, lineWidth: 0.5)
        }
        .scaleEffect(isBeingDragged ? 1.015 : 1)
        .opacity(1)
        .shadow(
            color: isBeingDragged ? Color.black.opacity(0.16) : .clear,
            radius: isBeingDragged ? 8 : 0,
            y: isBeingDragged ? 3 : 0
        )
        .zIndex(isBeingDragged ? 10_000 : 0)
        .offset(y: isBeingDragged ? dragOffsetY : 0)
        .transaction { transaction in
            if isBeingDragged { transaction.animation = nil }
        }
        .task(id: avatarRepairRequest) {
            await repairMissingAvatarIfNeeded()
        }
    }

    @ViewBuilder
    private var dragHandle: some View {
        if reorderEnabled {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 44)
                .contentShape(Rectangle())
                .highPriorityGesture(dragGesture)
                .accessibilityElement()
                .accessibilityLabel("Reorder \(idol.name)")
                .accessibilityHint("Long press and drag to reorder within the favorite group.")
                .accessibilityIdentifier(
                    "chekinana.idols.drag-handle.\(idol.id.uuidString.lowercased())"
                )
        } else {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 38, height: 44)
                .accessibilityElement()
                .accessibilityLabel("Reorder \(idol.name)")
                .accessibilityHint("Clear search before reordering.")
                .accessibilityIdentifier(
                    "chekinana.idols.drag-handle.\(idol.id.uuidString.lowercased())"
                )
        }
    }

    private var dragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 18)
            .sequenced(
                before: DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .global
                )
            )
            .onChanged { value in
                guard reorderEnabled else { return }
                switch value {
                case .first(true):
                    beginDrag()
                case .second(true, let drag):
                    beginDrag()
                    if let drag {
                        updateDrag(drag.translation.height)
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                guard reorderEnabled else {
                    cancelDrag()
                    return
                }
                if case .second(true, let drag) = value, let drag {
                    updateDrag(drag.translation.height)
                    commitDrag()
                } else {
                    cancelDrag()
                }
            }
    }

    @MainActor
    private func repairMissingAvatarIfNeeded() async {
        guard preparedAvatarImage == nil,
              avatarRepairState != .repairing else { return }
        guard idol.sourceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            avatarRepairState = .ready
            return
        }
        avatarRepairState = .repairing
        do {
            _ = try await ChekinanaIdolAvatarRepairCoordinator.repairIfNeeded(
                idol,
                in: modelContext
            )
            avatarRepairState = .ready
        } catch is CancellationError {
            avatarRepairState = .idle
        } catch {
            avatarRepairState = .failed
        }
    }
}

private struct ChekinanaIdolAvatar: View {
    @Environment(\.modelContext) private var modelContext
    let idol: Idol
    let size: CGFloat
    var preparedImage: ChekinanaRenderedImage? = nil
    var repairsMissingManagedAvatar = false
    @State private var repairRequest = 0
    @State private var repairState = ChekinanaIdolAvatarRepairState.idle

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ChekinanaIdolAvatarImage(
                name: idol.name,
                color: idol.color,
                imageRef: idol.avatarImageRef,
                cacheKey: "product-idol-\(idol.id.uuidString)",
                size: size,
                preparedImage: preparedImage,
                managedIdolID: idol.id
            )
            .id("\(idol.id.uuidString.lowercased())|\(idol.avatarImageRef ?? "none")")
            if repairsMissingManagedAvatar, repairState == .failed {
                Button {
                    repairRequest &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: max(9, size * 0.16), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: max(20, size * 0.34), height: max(20, size * 0.34))
                        .background(ChekinanaProductTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry avatar for \(idol.name)")
                .accessibilityIdentifier(
                    "chekinana.idols.avatar-retry.\(idol.id.uuidString.lowercased())"
                )
            }
        }
        .task(id: repairRequest) {
            await repairMissingAvatarIfNeeded()
        }
    }

    @MainActor
    private func repairMissingAvatarIfNeeded() async {
        guard repairsMissingManagedAvatar,
              preparedImage == nil,
              repairState != .repairing else { return }
        guard idol.sourceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            repairState = .ready
            return
        }
        repairState = .repairing
        do {
            _ = try await ChekinanaIdolAvatarRepairCoordinator.repairIfNeeded(
                idol,
                in: modelContext
            )
            repairState = .ready
        } catch is CancellationError {
            repairState = .idle
        } catch {
            repairState = .failed
        }
    }
}

private enum ChekinanaIdolAvatarRepairState: Equatable {
    case idle
    case repairing
    case ready
    case failed
}

private struct ChekinanaIdolAvatarImage: View {
    let name: String
    let color: String?
    let imageRef: String?
    let cacheKey: String
    let size: CGFloat
    var preparedImage: ChekinanaRenderedImage? = nil
    var managedIdolID: UUID? = nil
    @State private var localImage: ChekinanaRenderedImage?

    init(
        name: String,
        color: String?,
        imageRef: String?,
        cacheKey: String,
        size: CGFloat,
        preparedImage: ChekinanaRenderedImage? = nil,
        managedIdolID: UUID? = nil
    ) {
        self.name = name
        self.color = color
        self.imageRef = imageRef
        self.cacheKey = cacheKey
        self.size = size
        self.preparedImage = preparedImage
        self.managedIdolID = managedIdolID
        let immediate: ChekinanaRenderedImage?
        if preparedImage == nil,
           let managedIdolID,
           let url = try? ChekinanaIdolReferenceStore.managedAvatarURL(
                for: imageRef,
                idolID: managedIdolID
           ),
           let cgImage = UIImage(contentsOfFile: url.path)?.cgImage {
            immediate = ChekinanaRenderedImage(cgImage: cgImage)
        } else {
            immediate = nil
        }
        _localImage = State(initialValue: immediate)
    }

    var body: some View {
        ZStack {
            Circle().fill(ChekinanaProductColor.color(for: color).opacity(0.22))
            if let preparedImage {
                Image(decorative: preparedImage.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
                    .clipShape(Circle())
            } else if let localImage {
                Image(decorative: localImage.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
                    .clipShape(Circle())
            } else {
                placeholder
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().stroke(ChekinanaProductColor.color(for: color), lineWidth: 2) }
        .task(id: localLoadTaskID) {
            guard preparedImage == nil else { return }
            let loaded: ChekinanaRenderedImage?
            if let managedIdolID {
                loaded = await ChekinanaIdolReferenceStore.validatedManagedAvatar(
                    imageRef: imageRef,
                    idolID: managedIdolID
                )
            } else {
                loaded = await ChekinanaThumbnailCache.shared.thumbnailImage(
                    forManagedImageRef: imageRef,
                    key: localLoadID,
                    maxDimension: 256
                )
            }
            guard !Task.isCancelled else { return }
            if let loaded { localImage = loaded }
        }
    }

    private var localLoadID: String {
        "\(cacheKey)|\(managedIdolID?.uuidString.lowercased() ?? "unbound")|\(imageRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "<nil>")"
    }

    private var localLoadTaskID: String {
        "\(localLoadID)|prepared=\(preparedImage == nil ? 0 : 1)"
    }

    private var placeholder: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(ChekinanaProductColor.color(for: color))
    }
}

private struct ChekinanaIdolDetailView: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var idols: [Idol]
    @Query private var shames: [Shame]
    @Query private var dougas: [Douga]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let idol: Idol
    var preparedAvatarImage: ChekinanaRenderedImage? = nil
    @State private var isEditing = false
    @State private var selectedCheki: Cheki?
    @State private var showsLinkedEvents = false
    @State private var deleteMessage: String?
    @State private var pendingDeletedAvatarCleanup: ChekinanaIdolAvatarCleanupTarget?

    private var shameItems: [ChekinanaGalleryItem] { shames.filter { value in
        value.idols.contains { $0.id == idol.id }
            && ChekinanaVisibilityPolicy.includesRecord(idols: value.idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }.map(ChekinanaGalleryItem.shame) }
    private var dougaItems: [ChekinanaGalleryItem] { dougas.filter { value in
        value.idols.contains { $0.id == idol.id }
            && ChekinanaVisibilityPolicy.includesRecord(idols: value.idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }.map(ChekinanaGalleryItem.douga) }
    private var chekiItems: [ChekinanaGalleryItem] { idol.chekis.filter {
        ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }.map(ChekinanaGalleryItem.cheki) }
    private var linkedEvents: [Event] {
        var values: [UUID: Event] = [:]
        for event in chekiItems.compactMap(\.event) {
            values[event.id] = event
        }
        return values.values.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            if let selectedCheki {
                ChekinanaGalleryDetailView(
                    cheki: selectedCheki,
                    onClose: { self.selectedCheki = nil }
                )
            } else {
                ScrollView {
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        ChekinanaIdolAvatar(
                            idol: idol,
                            size: 76,
                            preparedImage: preparedAvatarImage
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(idol.name)
                                .font(.title2.weight(.bold))
                            if let group = idol.group?.nonEmpty {
                                Text(group)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ChekinanaSectionCard {
                        if let birthday = ChekinanaBirthdayValue.localizedDisplay(
                            idol.birthday
                        ) {
                            detailRow(
                                ChekinanaProductCopy.text(
                                    "idols.birthday",
                                    "Birthday"
                                ),
                                value: birthday,
                                image: "gift"
                            )
                        }
                        mediaSummaryRow(.cheki, image: "photo", items: chekiItems)
                        mediaSummaryRow(.shame, image: "photo.on.rectangle", items: shameItems)
                        mediaSummaryRow(.douga, image: "video", items: dougaItems)
                        Button {
                            showsLinkedEvents = true
                        } label: {
                            detailRow(
                                ChekinanaProductCopy.text(
                                    "events.title",
                                    "Events"
                                ),
                                value: linkedEvents.count.formatted(),
                                image: "music.note.house"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(linkedEvents.isEmpty)
                        .accessibilityIdentifier("chekinana.idols.detail.events")
                        detailRow(
                            ChekinanaProductCopy.text(
                                "idols.recognition",
                                "Recognition"
                            ),
                            value: ChekinanaPatternCountLabel.text(
                                idol.recognitionPatterns.count,
                                whenEmpty: ChekinanaProductCopy.text(
                                    "idols.no_pattern_stored",
                                    "No pattern stored"
                                )
                            ),
                            image: "waveform.path.ecg"
                        )
                    }
                    if !idol.note.isEmpty || idol.bio?.nonEmpty != nil {
                        ChekinanaSectionCard {
                            Text(idol.note.nonEmpty ?? idol.bio ?? "")
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(18)
            }
            .background(ChekinanaProductTheme.pageBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("chekinana.idols.detail.done")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button("Edit") { isEditing = true }
                            .accessibilityIdentifier("chekinana.idols.detail.edit")
                        Button(
                            ChekinanaProductCopy.text("idols.hide", "Hide Idol"),
                            role: .destructive,
                            action: hideIdol
                        )
                        .accessibilityIdentifier("chekinana.idols.detail.hide")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(ChekinanaProductCopy.text("common.actions", "Actions"))
                }
            }
            .sheet(isPresented: $isEditing) { ChekinanaIdolEditorView(idol: idol) }
            .sheet(isPresented: $showsLinkedEvents) {
                ChekinanaIdolLinkedEventsView(events: linkedEvents)
            }
            .navigationDestination(for: ChekinanaIdolMediaKind.self) { kind in
                ChekinanaIdolMediaDateView(idol: idol, kind: kind)
            }
            .alert("Idol", isPresented: Binding(
                get: { deleteMessage != nil },
                set: { if !$0 { deleteMessage = nil } }
            )) {
                if pendingDeletedAvatarCleanup != nil {
                    Button("Retry cleanup") { retryDeletedAvatarCleanup() }
                    Button("Close", role: .cancel) { dismiss() }
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { Text(deleteMessage ?? "") }
                .chekinanaScreenMarker("chekinana.idols.detail")
            }
        }
    }

    private func deleteIdol() {
        guard idol.chekis.isEmpty else {
            deleteMessage = "This Idol has \(idol.chekis.count) linked Cheki. Reassign them before deleting."
            return
        }
        do {
            let result = try ChekinanaIdolPersistence.delete(idol, from: modelContext)
            hiddenIdols.removeDeleted(idol.id)
            if let cleanup = result.pendingAvatarCleanup {
                pendingDeletedAvatarCleanup = cleanup
                deleteMessage = "The Idol was deleted, but its previous managed avatar could not be removed. Retry cleanup or close and leave the harmless orphaned file for later cleanup."
                return
            }
            dismiss()
        } catch {
            deleteMessage = error.localizedDescription
        }
    }

    private func hideIdol() {
        hiddenIdols.hide(idol.id)
        dismiss()
    }

    private func toggleFavorite() {
        do {
            try ChekinanaIdolFavoriteAction.toggle(
                idol,
                in: idols,
                modelContext: modelContext
            )
        } catch {
            deleteMessage = "Favorite status could not be saved: \(error.localizedDescription)"
        }
    }

    private func retryDeletedAvatarCleanup() {
        guard let pendingDeletedAvatarCleanup else { return }
        do {
            _ = try ChekinanaIdolReferenceStore.removeManagedAvatar(
                pendingDeletedAvatarCleanup.imageRef,
                idolID: pendingDeletedAvatarCleanup.idolID,
                directory: pendingDeletedAvatarCleanup.directory
            )
            self.pendingDeletedAvatarCleanup = nil
            dismiss()
        } catch {
            deleteMessage = "The Idol is deleted, but avatar cleanup still failed: \(error.localizedDescription)"
        }
    }

    private func detailRow(_ title: String, value: String, image: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: image).foregroundStyle(ChekinanaProductTheme.accent).frame(width: 26)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.body)
        .frame(minHeight: ChekinanaAccessibilityMetrics.minimumTouchTarget)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func mediaSummaryRow(_ kind: ChekinanaRecordKind, image: String, items: [ChekinanaGalleryItem]) -> some View {
        NavigationLink(value: kind) {
            detailRow(kind.title, value: kind.countLabel(items.count), image: image)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chekinana.idols.detail.type.\(kind.rawValue)")
    }

    private func mediaItems(for kind: ChekinanaIdolMediaKind) -> [ChekinanaGalleryItem] {
        switch kind { case .cheki: chekiItems; case .shame: shameItems; case .douga: dougaItems }
    }
}

private struct ChekinanaIdolLinkedEventsView: View {
    @Environment(\.dismiss) private var dismiss
    let events: [Event]
    @State private var selectedEvent: Event?

    var body: some View {
        NavigationStack {
            List(events) { event in
                Button {
                    selectedEvent = event
                } label: {
                    HStack(spacing: 10) {
                        ChekinanaEventAvatar(event: event, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(ChekinanaProductDate.displayString(event.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(
                            ChekinanaRecordKind.cheki.countLabel(
                                event.chekis.count
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: ChekinanaAccessibilityMetrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    "chekinana.idols.detail.event.\(event.id.uuidString.lowercased())"
                )
            }
            .listStyle(.plain)
            .navigationTitle(
                ChekinanaProductCopy.text("events.title", "Events")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaProductCopy.text("common.done", "Done")) {
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedEvent) {
                ChekinanaEventDetailView(event: $0)
            }
        }
        .accessibilityIdentifier("chekinana.idols.detail.events.page")
    }
}

private typealias ChekinanaIdolMediaKind = ChekinanaRecordKind

private enum ChekinanaIdolMediaDateGroupKey: Hashable {
    case dated(Date)
    case undated

    var title: String {
        switch self {
        case .dated(let date):
            ChekinanaProductDate.displayString(date)
        case .undated:
            ChekinanaProductCopy.text("common.no_date", "No date")
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.dated(let left), .dated(let right)): left < right
        case (.dated, .undated): true
        case (.undated, .dated), (.undated, .undated): false
        }
    }
}

private struct ChekinanaIdolMediaStrip: View {
    let items: [ChekinanaGalleryItem]
    var onSelect: ((ChekinanaGalleryItem) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(items) { item in
                    if let onSelect {
                        Button { onSelect(item) } label: {
                            ChekinanaGalleryCard(
                                item: item,
                                showsIdolAvatars: false
                            ).frame(width: 82)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("chekinana.idols.detail.media.\(item.id)")
                    } else {
                        ChekinanaGalleryCard(
                            item: item,
                            showsIdolAvatars: false
                        ).frame(width: 82)
                    }
                }
            }
        }
    }
}

private struct ChekinanaIdolMediaDateView: View {
    @Query private var chekis: [Cheki]
    @Query private var shames: [Shame]
    @Query private var dougas: [Douga]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let idol: Idol
    let kind: ChekinanaIdolMediaKind
    private var items: [ChekinanaGalleryItem] {
        switch kind {
        case .cheki:
            chekis.filter { $0.idols.contains { $0.id == idol.id } && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }.map(ChekinanaGalleryItem.cheki)
        case .shame:
            shames.filter { $0.idols.contains { $0.id == idol.id } && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }.map(ChekinanaGalleryItem.shame)
        case .douga:
            dougas.filter { $0.idols.contains { $0.id == idol.id } && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }.map(ChekinanaGalleryItem.douga)
        }
    }
    private var groups: [(key: ChekinanaIdolMediaDateGroupKey, values: [ChekinanaGalleryItem])] {
        let ordered = ChekinanaRecordOrdering.ordered(items, ascending: true)
        return Dictionary(grouping: ordered) { item in
            item.date
                .flatMap(ChekinanaDateOnly.canonicalized)
                .map(ChekinanaIdolMediaDateGroupKey.dated)
                ?? .undated
        }
        .map { (key: $0.key, values: $0.value) }
        .sorted { $0.key < $1.key }
    }
    var body: some View {
        List {
            ForEach(groups, id: \.key) { group in
                NavigationLink {
                    ChekinanaIdolMediaDateGroupView(
                        idol: idol,
                        kind: kind,
                        groupKey: group.key
                    )
                } label: {
                    HStack(spacing: 10) {
                        Text(group.key.title)
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 8)
                        Text(kind.countLabel(group.values.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: ChekinanaAccessibilityMetrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
                .listRowInsets(
                    EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16)
                )
                .accessibilityIdentifier(
                    "chekinana.idols.detail.date.\(kind.rawValue).\(group.key.stableID)"
                )
            }
        }
        .listStyle(.plain)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("chekinana.idols.detail.date-page.\(kind.rawValue)")
    }
}

private extension ChekinanaIdolMediaDateGroupKey {
    var stableID: String {
        switch self {
        case .dated(let date): ChekinanaDateOnly.string(date)
        case .undated: "undated"
        }
    }
}

struct ChekinanaIdolNoMediaChekiExactGroup: Hashable, Sendable {
    let idolIDs: Set<UUID>
    let canonicalDate: String?

    init(_ cheki: Cheki) {
        idolIDs = Set(cheki.idols.map(\.id))
        canonicalDate = cheki.date.map(ChekinanaDateOnly.string)
    }
}

struct ChekinanaIdolNoMediaChekiIdentity: Hashable, Sendable {
    let group: ChekinanaIdolNoMediaChekiExactGroup
    let note: String
    let eventID: UUID?
    let sizeRawValue: String?
    let userAppears: Bool?
    let isFavorite: Bool
    let hasPostedToSNS: Bool

    init?(_ cheki: Cheki) {
        guard ChekinanaNoMediaPolicy.hasNoImage(cheki.imageRef) else { return nil }
        group = ChekinanaIdolNoMediaChekiExactGroup(cheki)
        note = ChekinanaIdolNoMediaChekiGrouping.exactNoteKey(cheki.note)
        eventID = cheki.event?.id
        sizeRawValue = cheki.sizeRawValue
        userAppears = cheki.userAppears
        isFavorite = cheki.isFavorite
        hasPostedToSNS = cheki.hasPostedToSNS
    }
}

struct ChekinanaIdolNoMediaChekiFingerprint: Hashable, Sendable {
    let id: UUID
    let group: ChekinanaIdolNoMediaChekiExactGroup
    let updatedAt: Date
    let createdAt: Date
    let idx: Int?
    let imageRef: String?
    let note: String
    let eventID: UUID?
    let sizeRawValue: String?
    let userAppears: Bool?
    let isFavorite: Bool
    let hasPostedToSNS: Bool

    init(_ cheki: Cheki) {
        id = cheki.id
        group = ChekinanaIdolNoMediaChekiExactGroup(cheki)
        updatedAt = cheki.updatedAt
        createdAt = cheki.createdAt
        idx = cheki.idx
        imageRef = cheki.imageRef
        note = cheki.note
        eventID = cheki.event?.id
        sizeRawValue = cheki.sizeRawValue
        userAppears = cheki.userAppears
        isFavorite = cheki.isFavorite
        hasPostedToSNS = cheki.hasPostedToSNS
    }
}

struct ChekinanaIdolNoMediaChekiBatchDraft: Identifiable, Sendable {
    let selectedRecordIDs: [UUID]
    let identity: ChekinanaIdolNoMediaChekiIdentity
    let groupFingerprints: Set<ChekinanaIdolNoMediaChekiFingerprint>

    var id: String {
        selectedRecordIDs.map(\.uuidString).sorted().joined(separator: ",")
    }

    var quantity: Int { selectedRecordIDs.count }
    var note: String { identity.note }
}

enum ChekinanaIdolNoMediaChekiBatchError: LocalizedError, Equatable {
    case invalidQuantity
    case changedRecords
    case missingRelationships

    var errorDescription: String? {
        switch self {
        case .invalidQuantity:
            ChekinanaProductRecordCreationError.invalidBatchQuantity.localizedDescription
        case .changedRecords:
            ChekinanaProductCopy.text(
                "idols.no_media_group.changed",
                "This Cheki group changed. Reopen it and try again."
            )
        case .missingRelationships:
            ChekinanaProductRecordCreationError.modelContextMismatch.localizedDescription
        }
    }
}

@MainActor
enum ChekinanaIdolNoMediaChekiBatchWriter {
    static func draft(
        selectedRecordIDs: [UUID],
        allChekis: [Cheki]
    ) throws -> ChekinanaIdolNoMediaChekiBatchDraft {
        let requestedIDs = Set(selectedRecordIDs)
        guard !requestedIDs.isEmpty,
              requestedIDs.count == selectedRecordIDs.count else {
            throw ChekinanaIdolNoMediaChekiBatchError.changedRecords
        }
        let selected = allChekis.filter { requestedIDs.contains($0.id) }
        guard selected.count == requestedIDs.count,
              let first = selected.first,
              let identity = ChekinanaIdolNoMediaChekiIdentity(first),
              selected.allSatisfy({ ChekinanaIdolNoMediaChekiIdentity($0) == identity }) else {
            throw ChekinanaIdolNoMediaChekiBatchError.changedRecords
        }
        let matchingIDs = Set(allChekis.compactMap { cheki -> UUID? in
            ChekinanaIdolNoMediaChekiIdentity(cheki) == identity ? cheki.id : nil
        })
        guard matchingIDs == requestedIDs else {
            throw ChekinanaIdolNoMediaChekiBatchError.changedRecords
        }
        let groupFingerprints = Set(allChekis.compactMap { cheki in
            ChekinanaIdolNoMediaChekiExactGroup(cheki) == identity.group
                ? ChekinanaIdolNoMediaChekiFingerprint(cheki)
                : nil
        })
        return ChekinanaIdolNoMediaChekiBatchDraft(
            selectedRecordIDs: ordered(selected).map(\.id),
            identity: identity,
            groupFingerprints: groupFingerprints
        )
    }

    static func commit(
        _ draft: ChekinanaIdolNoMediaChekiBatchDraft,
        quantity: Int,
        note: String,
        in modelContext: ModelContext
    ) throws -> [UUID] {
        guard (1...100).contains(quantity) else {
            throw ChekinanaIdolNoMediaChekiBatchError.invalidQuantity
        }
        var resultIDs: [UUID] = []
        do {
            try modelContext.transaction {
                let allChekis = try modelContext.fetch(FetchDescriptor<Cheki>())
                let liveGroup = allChekis.filter {
                    ChekinanaIdolNoMediaChekiExactGroup($0) == draft.identity.group
                }
                guard Set(liveGroup.map(ChekinanaIdolNoMediaChekiFingerprint.init))
                        == draft.groupFingerprints else {
                    throw ChekinanaIdolNoMediaChekiBatchError.changedRecords
                }
                let liveByID = Dictionary(uniqueKeysWithValues: liveGroup.map { ($0.id, $0) })
                let selected = try draft.selectedRecordIDs.map { id -> Cheki in
                    guard let cheki = liveByID[id],
                          ChekinanaIdolNoMediaChekiIdentity(cheki) == draft.identity else {
                        throw ChekinanaIdolNoMediaChekiBatchError.changedRecords
                    }
                    return cheki
                }

                let requestedIdolIDs = draft.identity.group.idolIDs
                let idols = try modelContext.fetch(FetchDescriptor<Idol>()).filter {
                    requestedIdolIDs.contains($0.id)
                }
                guard Set(idols.map(\.id)) == requestedIdolIDs,
                      idols.allSatisfy({ $0.modelContext === modelContext }) else {
                    throw ChekinanaIdolNoMediaChekiBatchError.missingRelationships
                }
                let event: Event?
                if let eventID = draft.identity.eventID {
                    let matches = try modelContext.fetch(FetchDescriptor<Event>()).filter {
                        $0.id == eventID
                    }
                    guard matches.count == 1,
                          matches[0].modelContext === modelContext else {
                        throw ChekinanaIdolNoMediaChekiBatchError.missingRelationships
                    }
                    event = matches[0]
                } else {
                    event = nil
                }

                var retained = ordered(selected)
                if quantity < retained.count {
                    let removed = retained.suffix(retained.count - quantity)
                    retained.removeLast(retained.count - quantity)
                    for cheki in removed {
                        modelContext.delete(cheki)
                    }
                }
                let now = Date()
                for cheki in retained {
                    cheki.note = note
                    cheki.updatedAt = now
                }

                var inserted: [Cheki] = []
                if quantity > retained.count {
                    let date = draft.identity.group.canonicalDate
                        .flatMap(ChekinanaDateOnly.parse)
                    for _ in retained.count..<quantity {
                        let cheki = Cheki(
                            date: date,
                            userAppears: draft.identity.userAppears,
                            isFavorite: draft.identity.isFavorite,
                            hasPostedToSNS: draft.identity.hasPostedToSNS,
                            note: note,
                            createdAt: now,
                            updatedAt: now
                        )
                        modelContext.insert(cheki)
                        guard cheki.modelContext === modelContext else {
                            throw ChekinanaIdolNoMediaChekiBatchError.missingRelationships
                        }
                        cheki.sizeRawValue = draft.identity.sizeRawValue
                        cheki.idols = ChekinanaIdolOrdering.ordered(idols)
                        cheki.event = event
                        inserted.append(cheki)
                    }
                }

                let removedIDs = Set(selected.map(\.id)).subtracting(retained.map(\.id))
                var affected = liveGroup.filter { !removedIDs.contains($0.id) }
                affected.append(contentsOf: inserted)
                affected = ordered(affected)
                let isDatedGroup = draft.identity.group.canonicalDate != nil
                for (offset, cheki) in affected.enumerated() {
                    // `idx` only has ordering meaning inside a dated Cheki
                    // group. Legacy undated values are cleared across the
                    // whole exact Idol-set group, including media and other
                    // metadata blocks, so this batch cannot manufacture an
                    // invalid undated index.
                    cheki.idx = isDatedGroup ? offset + 1 : nil
                    if cheki.updatedAt != now { cheki.updatedAt = now }
                }
                guard let mergedIdentity = retained.first.flatMap(
                    ChekinanaIdolNoMediaChekiIdentity.init
                ) else {
                    throw ChekinanaIdolNoMediaChekiBatchError.changedRecords
                }
                // A Note edit can merge this block with a pre-existing block
                // whose remaining metadata is identical. Return that complete
                // post-save identity so the child view's count and any second
                // edit operate on the merged group instead of stale IDs.
                resultIDs = ordered(affected.filter {
                    ChekinanaIdolNoMediaChekiIdentity($0) == mergedIdentity
                }).map(\.id)
            }
            return resultIDs
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func ordered(_ values: [Cheki]) -> [Cheki] {
        values.sorted { lhs, rhs in
            if lhs.idx != rhs.idx { return (lhs.idx ?? Int.max) < (rhs.idx ?? Int.max) }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

private struct ChekinanaIdolChekiDisplayBlock: Identifiable {
    let id: String
    var chekis: [Cheki]
    let noMediaIdentity: ChekinanaIdolNoMediaChekiIdentity?

    var recordIDs: [UUID] { chekis.map(\.id) }
    var isMedia: Bool { noMediaIdentity == nil }
}

private struct ChekinanaIdolChekiGroupSection: Identifiable {
    let idolIDs: Set<UUID>
    let groupKey: ChekinanaChekiGroupKey?
    let title: String
    let blocks: [ChekinanaIdolChekiDisplayBlock]

    var id: String {
        idolIDs.map(\.uuidString).sorted().joined(separator: ",")
            + "|" + (groupKey?.date ?? "undated")
    }
}

private struct ChekinanaIdolMediaDateGroupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var chekis: [Cheki]
    @Query private var shames: [Shame]
    @Query private var dougas: [Douga]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let idol: Idol
    let kind: ChekinanaIdolMediaKind
    let groupKey: ChekinanaIdolMediaDateGroupKey
    @State private var selected: ChekinanaGalleryItem?
    @State private var selectedNoMediaRecord: ChekinanaCalendarNoMediaRecord?
    @State private var reorderError: String?

    private var items: [ChekinanaGalleryItem] {
        let candidates: [ChekinanaGalleryItem]
        switch kind {
        case .cheki:
            candidates = chekis
                .filter { $0.idols.contains { $0.id == idol.id } && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }
                .map(ChekinanaGalleryItem.cheki)
        case .shame:
            candidates = shames
                .filter { $0.idols.contains { $0.id == idol.id } && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }
                .map(ChekinanaGalleryItem.shame)
        case .douga:
            candidates = dougas
                .filter { $0.idols.contains { $0.id == idol.id } && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }
                .map(ChekinanaGalleryItem.douga)
        }
        return ChekinanaRecordOrdering.ordered(
            candidates.filter { key(for: $0.date) == groupKey },
            ascending: true
        )
    }

    private var chekiSections: [ChekinanaIdolChekiGroupSection] {
        let values = items.compactMap { item -> Cheki? in
            guard case .cheki(let cheki) = item else { return nil }
            return cheki
        }
        let grouped = Dictionary(grouping: values) { cheki in
            Set(cheki.idols.map(\.id))
        }
        return grouped.map { idolIDs, values in
            let ordered = ChekinanaRecordOrdering.orderedChekis(values)
            var blocks: [ChekinanaIdolChekiDisplayBlock] = []
            var noMediaBlockIndices: [ChekinanaIdolNoMediaChekiIdentity: Int] = [:]
            for cheki in ordered {
                if !ChekinanaNoMediaPolicy.hasNoImage(cheki.imageRef) {
                    blocks.append(.init(
                        id: "media-\(cheki.id.uuidString.lowercased())",
                        chekis: [cheki],
                        noMediaIdentity: nil
                    ))
                    continue
                }
                guard let identity = ChekinanaIdolNoMediaChekiIdentity(cheki) else {
                    continue
                }
                if let index = noMediaBlockIndices[identity] {
                    blocks[index].chekis.append(cheki)
                } else {
                    noMediaBlockIndices[identity] = blocks.count
                    blocks.append(.init(
                        id: "no-media-\(cheki.id.uuidString.lowercased())",
                        chekis: [cheki],
                        noMediaIdentity: identity
                    ))
                }
            }
            let names = values.first?.idols
                .sorted { lhs, rhs in
                    if lhs.name != rhs.name { return lhs.name < rhs.name }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                .map(\.name)
                .joined(separator: " · ")
                .nonEmpty
                ?? ChekinanaProductCopy.text("common.unassigned", "Unassigned")
            return ChekinanaIdolChekiGroupSection(
                idolIDs: idolIDs,
                groupKey: ChekinanaChekiGroupKey(
                    idolIDs: Array(idolIDs),
                    date: values.first?.date
                ),
                title: names,
                blocks: blocks
            )
        }
        .sorted { $0.id < $1.id }
    }

    var body: some View {
        List {
            if kind == .cheki {
                ForEach(chekiSections) { section in
                    Section {
                        if section.groupKey != nil {
                            ForEach(section.blocks) { block in
                                chekiBlockRow(block)
                            }
                            .onMove { offsets, destination in
                                reorder(
                                    section: section,
                                    fromOffsets: offsets,
                                    toOffset: destination
                                )
                            }
                        } else {
                            ForEach(section.blocks) { block in
                                chekiBlockRow(block)
                            }
                        }
                    } header: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            Text(
                                ChekinanaRecordKind.cheki.countLabel(
                                    section.blocks.reduce(0) { $0 + $1.chekis.count }
                                )
                            )
                        }
                    }
                }
            } else {
                let media = items.filter(\.hasMedia)
                if !media.isEmpty {
                    Section {
                        ChekinanaIdolMediaStrip(
                            items: media,
                            onSelect: { selected = $0 }
                        )
                    }
                }
                ForEach(items.filter { !$0.hasMedia }) { item in
                    Button {
                        selectedNoMediaRecord = noMediaRecord(for: item)
                    } label: {
                        compactNoMediaRow(
                            title: item.typeName,
                            note: item.note,
                            count: 1,
                            systemImage: kind == .douga ? "video" : "photo"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "chekinana.idols.detail.no-media.\(item.kind.rawValue).\(item.modelID.uuidString.lowercased())"
                    )
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(groupKey.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if kind == .cheki,
               chekiSections.contains(where: { $0.groupKey != nil }) {
                EditButton()
                    .accessibilityIdentifier("chekinana.idols.detail.cheki.reorder")
            }
        }
        .alert(
            ChekinanaProductCopy.text("idols.reorder_failed", "Unable to reorder"),
            isPresented: Binding(
                get: { reorderError != nil },
                set: { if !$0 { reorderError = nil } }
            )
        ) {
            Button(ChekinanaProductCopy.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(reorderError ?? "")
        }
        .fullScreenCover(item: $selected) { item in
            switch item {
            case .cheki(let value): ChekinanaGalleryDetailView(cheki: value)
            case .shame(let value): ChekinanaGalleryMediaDetailView(shame: value)
            case .douga(let value): ChekinanaGalleryMediaDetailView(douga: value)
            }
        }
        .sheet(item: $selectedNoMediaRecord) { record in
            ChekinanaCalendarNoMediaRecordEditor(record: record)
        }
        .accessibilityIdentifier(
            "chekinana.idols.detail.date-group.\(kind.rawValue).\(groupKey.stableID)"
        )
    }

    @ViewBuilder
    private func chekiBlockRow(
        _ block: ChekinanaIdolChekiDisplayBlock
    ) -> some View {
        if block.isMedia, let cheki = block.chekis.first {
            Button {
                selected = .cheki(cheki)
            } label: {
                HStack(spacing: 10) {
                    ChekinanaGalleryCard(
                        item: .cheki(cheki),
                        showsIdolAvatars: false
                    )
                    .frame(width: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            cheki.idx.map { "#\($0)" }
                                ?? ChekinanaRecordKind.cheki.title
                        )
                        .font(.subheadline.weight(.semibold))
                        Text(
                            cheki.note.nonEmpty
                                ?? ChekinanaProductCopy.text(
                                    "common.no_note",
                                    "No note"
                                )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                "chekinana.idols.detail.media.cheki-\(cheki.id.uuidString.lowercased())"
            )
        } else if block.noMediaIdentity != nil {
            NavigationLink {
                ChekinanaIdolNoMediaChekiGroupView(
                    recordIDs: block.recordIDs
                )
            } label: {
                compactNoMediaRow(
                    title: ChekinanaRecordKind.cheki.title,
                    note: block.noMediaIdentity?.note ?? "",
                    count: block.chekis.count,
                    systemImage: "photo"
                )
            }
            .accessibilityIdentifier(
                "chekinana.idols.detail.no-media.cheki-group.\(block.id)"
            )
        }
    }

    private func compactNoMediaRow(
        title: String,
        note: String,
        count: Int,
        systemImage: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(ChekinanaProductTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(
                    note.nonEmpty
                        ?? ChekinanaProductCopy.text(
                            "common.no_media",
                            "No media"
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ChekinanaRecordKind.cheki.countLabel(count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: ChekinanaAccessibilityMetrics.minimumTouchTarget)
        .contentShape(Rectangle())
    }

    private func reorder(
        section: ChekinanaIdolChekiGroupSection,
        fromOffsets: IndexSet,
        toOffset: Int
    ) {
        do {
            guard let groupKey = section.groupKey else {
                throw ChekinanaIdolChekiReorderError.mixedGroups
            }
            let moved = ChekinanaIdolChekiReorderPlan.movedBlocks(
                section.blocks.map(\.recordIDs),
                fromOffsets: fromOffsets,
                toOffset: toOffset
            )
            let liveValues = chekis.compactMap { cheki -> ChekinanaIdolChekiReorderSnapshot? in
                guard let key = ChekinanaChekiGroupKey(
                    idolIDs: cheki.idols.map(\.id),
                    date: cheki.date
                ), key == groupKey else { return nil }
                return .init(chekiID: cheki.id, group: key, idx: cheki.idx)
            }
            let assignments = try ChekinanaIdolChekiReorderPlan.assignments(
                for: moved,
                liveSnapshots: liveValues
            )
            let liveByID = Dictionary(uniqueKeysWithValues: chekis.map { ($0.id, $0) })
            guard assignments.keys.allSatisfy({ liveByID[$0] != nil }) else {
                throw ChekinanaIdolChekiReorderError.changedRecords
            }
            for (id, idx) in assignments {
                liveByID[id]?.idx = idx
                liveByID[id]?.updatedAt = Date()
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            reorderError = ChekinanaProductCopy.text(
                "idols.reorder_changed",
                "The Cheki list changed. Reopen this date and try again."
            )
        }
    }

    private func key(for date: Date?) -> ChekinanaIdolMediaDateGroupKey {
        date.flatMap(ChekinanaDateOnly.canonicalized)
            .map(ChekinanaIdolMediaDateGroupKey.dated)
            ?? .undated
    }

    private func noMediaRecord(
        for item: ChekinanaGalleryItem
    ) -> ChekinanaCalendarNoMediaRecord {
        switch item {
        case .cheki(let value): .cheki(value)
        case .shame(let value): .shame(value)
        case .douga(let value): .douga(value)
        }
    }
}

private struct ChekinanaIdolNoMediaChekiGroupView: View {
    @Query private var chekis: [Cheki]
    @State private var recordIDs: [UUID]
    @State private var selectedRecord: ChekinanaCalendarNoMediaRecord?
    @State private var batchDraft: ChekinanaIdolNoMediaChekiBatchDraft?
    @State private var errorMessage: String?

    init(recordIDs: [UUID]) {
        _recordIDs = State(initialValue: recordIDs)
    }

    private var records: [Cheki] {
        let ids = Set(recordIDs)
        return ChekinanaRecordOrdering.orderedChekis(
            chekis.filter {
                ids.contains($0.id)
                    && ChekinanaNoMediaPolicy.hasNoImage($0.imageRef)
            }
        )
    }

    var body: some View {
        List {
            if !records.isEmpty {
                Section {
                    Button {
                        prepareBatchEdit()
                    } label: {
                        HStack {
                            Label(
                                ChekinanaProductCopy.text(
                                    "idols.no_media_group.edit",
                                    "Edit group"
                                ),
                                systemImage: "square.and.pencil"
                            )
                            Spacer()
                            Text(ChekinanaRecordKind.cheki.countLabel(records.count))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: ChekinanaAccessibilityMetrics.minimumTouchTarget)
                    }
                    .accessibilityIdentifier(
                        "chekinana.idols.detail.no-media.cheki-group.edit"
                    )
                }

                Section {
                    ForEach(records) { cheki in
                        Button {
                            selectedRecord = .cheki(cheki)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "photo")
                                    .foregroundStyle(ChekinanaProductTheme.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(
                                        cheki.idx.map { "#\($0)" }
                                            ?? ChekinanaRecordKind.cheki.title
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    Text(
                                        cheki.note.nonEmpty
                                            ?? ChekinanaProductCopy.text(
                                                "common.no_note",
                                                "No note"
                                            )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: ChekinanaAccessibilityMetrics.minimumTouchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "chekinana.idols.detail.no-media.cheki.\(cheki.id.uuidString.lowercased())"
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(ChekinanaRecordKind.cheki.countLabel(records.count))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedRecord) {
            ChekinanaCalendarNoMediaRecordEditor(record: $0)
        }
        .sheet(item: $batchDraft) { draft in
            ChekinanaIdolNoMediaChekiBatchEditor(draft: draft) { ids in
                recordIDs = ids
                batchDraft = nil
            }
        }
        .alert(
            ChekinanaProductCopy.text("common.error", "Error"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(ChekinanaProductCopy.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func prepareBatchEdit() {
        do {
            let draft = try ChekinanaIdolNoMediaChekiBatchWriter.draft(
                selectedRecordIDs: recordIDs,
                allChekis: chekis
            )
            batchDraft = draft
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ChekinanaIdolNoMediaChekiBatchEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let draft: ChekinanaIdolNoMediaChekiBatchDraft
    let onSaved: ([UUID]) -> Void
    @State private var quantity: Int
    @State private var note: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        draft: ChekinanaIdolNoMediaChekiBatchDraft,
        onSaved: @escaping ([UUID]) -> Void
    ) {
        self.draft = draft
        self.onSaved = onSaved
        _quantity = State(initialValue: draft.quantity)
        _note = State(initialValue: draft.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(ChekinanaProductCopy.text("common.metadata", "Metadata")) {
                    Stepper(
                        ChekinanaProductCopy.format(
                            "calendar.quantity_value",
                            "Quantity: %lld",
                            Int64(quantity)
                        ),
                        value: $quantity,
                        in: 1...100
                    )
                    .accessibilityIdentifier(
                        "chekinana.idols.detail.no-media.cheki-group.quantity"
                    )
                    TextField(
                        ChekinanaProductCopy.text("common.note", "Note"),
                        text: $note,
                        axis: .vertical
                    )
                    .accessibilityIdentifier(
                        "chekinana.idols.detail.no-media.cheki-group.note"
                    )
                }
                if let errorMessage {
                    Section {
                        ChekinanaInlineStatus(message: errorMessage, kind: .error)
                    }
                }
            }
            .disabled(isSaving)
            .chekinanaGroupedPageBackground()
            .navigationTitle(
                ChekinanaProductCopy.text(
                    "idols.no_media_group.edit",
                    "Edit group"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaProductCopy.text("common.cancel", "Cancel")) {
                        dismiss()
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier(
                        "chekinana.idols.detail.no-media.cheki-group.cancel"
                    )
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChekinanaProductCopy.text("common.save", "Save")) {
                        save()
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier(
                        "chekinana.idols.detail.no-media.cheki-group.save"
                    )
                }
            }
            .interactiveDismissDisabled(isSaving)
            .accessibilityIdentifier(
                "chekinana.idols.detail.no-media.cheki-group.editor"
            )
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let ids = try ChekinanaIdolNoMediaChekiBatchWriter.commit(
                draft,
                quantity: quantity,
                note: note,
                in: modelContext
            )
            onSaved(ids)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum ChekinanaIdolEditorMode: String, CaseIterable, Identifiable {
    case catalogue = "Catalogue"
    case manual = "Manual"
    var id: String { rawValue }
}

enum ChekinanaManualIdolInputError: LocalizedError, Equatable {
    case nameRequired

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            "Name is required."
        }
    }
}

@MainActor
enum ChekinanaManualIdolInput {
    static func normalizedName(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ChekinanaManualIdolInputError.nameRequired
        }
        return value
    }

    static func makeNameOnlyIdol(name rawValue: String) throws -> Idol {
        Idol(name: try normalizedName(rawValue))
    }

    static func requiresManagedAvatar(sourceId: String?) -> Bool {
        sourceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct ChekinanaCatalogueIdolTarget {
    let idol: Idol
    let shouldInsert: Bool
}

@MainActor
enum ChekinanaCatalogueIdolUpsert {
    static func resolve(
        sourceId: String,
        fallbackName: String,
        in modelContext: ModelContext
    ) throws -> ChekinanaCatalogueIdolTarget {
        let normalizedSourceId = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        var descriptor = FetchDescriptor<Idol>(
            predicate: #Predicate { $0.sourceId == normalizedSourceId }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            return ChekinanaCatalogueIdolTarget(idol: existing, shouldInsert: false)
        }
        return ChekinanaCatalogueIdolTarget(
            idol: Idol(sourceId: normalizedSourceId, name: fallbackName),
            shouldInsert: true
        )
    }
}

private struct ChekinanaCatalogueIdolCard: View {
    let candidate: ChekinanaEnrichedIdol
    let index: Int

    private var details: [String] {
        [
            candidate.birthday?.nonEmpty.map {
                let value = candidate.birthdayIsInvalid
                    ? ChekinanaProductCopy.text("idols.birthday_invalid_value", "Invalid")
                    : (ChekinanaBirthdayValue.localizedDisplay($0)
                        ?? ChekinanaProductCopy.text("idols.birthday_invalid_value", "Invalid"))
                return "\(ChekinanaProductCopy.text("idols.birthday", "Birthday")) \(value)"
            },
            candidate.color?.nonEmpty.map { "Color \($0)" },
            candidate.verification?.nonEmpty,
            candidate.bio?.nonEmpty,
        ].compactMap { $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ChekinanaCatalogueIdolCardAvatar(
                candidate: candidate,
                index: index
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.idolName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(candidate.groupName?.nonEmpty ?? "Independent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(ChekinanaProductTheme.accent)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityValue(
            ChekinanaProductCopy.text(
                "idols.catalogue_autofill",
                "Auto-fills name, group, color, birthday, avatar, verification, and bio"
            )
        )
    }
}

enum ChekinanaCatalogueIdolCardAvatarPresentation {
    static func identity(for candidate: ChekinanaEnrichedIdol) -> String {
        if let strictIdentity = ChekinanaIdolAvatarIdentity.make(
            sourceID: candidate.sourceId,
            avatarURL: candidate.avatarUrl
        ) {
            return strictIdentity
        }
        let sourceID = candidate.sourceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        let avatarURL = candidate.avatarUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping ?? "<no-avatar>"
        return "\(sourceID)|\(avatarURL)"
    }

    static func preparedImage(
        from prepared: ChekinanaPreparedIdolCandidate,
        for candidate: ChekinanaEnrichedIdol,
        taskIdentity: String? = nil
    ) -> ChekinanaRenderedImage? {
        let currentIdentity = identity(for: candidate)
        guard taskIdentity == nil || taskIdentity == currentIdentity,
              prepared.candidate.sourceId == candidate.sourceId,
              prepared.avatarIdentity == ChekinanaIdolAvatarIdentity.make(
                  sourceID: candidate.sourceId,
                  avatarURL: candidate.avatarUrl
              ) else {
            return nil
        }
        return prepared.avatarThumbnailImage
    }
}

private struct ChekinanaCatalogueIdolCardAvatar: View {
    let candidate: ChekinanaEnrichedIdol
    let index: Int
    @State private var preparedImage: ChekinanaRenderedImage?

    var body: some View {
        ChekinanaIdolAvatarImage(
            name: candidate.idolName,
            color: candidate.color,
            imageRef: nil,
            cacheKey: "catalogue-result-\(candidate.sourceId)-\(index)",
            size: 58,
            preparedImage: preparedImage
        )
        .accessibilityLabel("Avatar for \(candidate.idolName)")
        .accessibilityValue(preparedImage == nil ? "Unavailable" : "Loaded")
        .accessibilityIdentifier("chekinana.idols.editor.catalogue-avatar.\(index)")
        .task(id: ChekinanaCatalogueIdolCardAvatarPresentation.identity(for: candidate)) {
            let taskIdentity = ChekinanaCatalogueIdolCardAvatarPresentation.identity(
                for: candidate
            )
            preparedImage = nil
            guard candidate.avatarUrl?.nonEmpty != nil else { return }
            guard let prepared = try? await ChekinanaCatalogueIdolAvatarResolver.prepare(candidate),
                  !Task.isCancelled else { return }
            preparedImage = ChekinanaCatalogueIdolCardAvatarPresentation.preparedImage(
                from: prepared,
                for: candidate,
                taskIdentity: taskIdentity
            )
        }
    }
}

private struct ChekinanaIndexedCatalogueIdolCandidate: Identifiable {
    let index: Int
    let candidate: ChekinanaEnrichedIdol

    var id: String {
        ChekinanaCatalogueIdolCardAvatarPresentation.identity(for: candidate)
    }
}

private struct ChekinanaIdolEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var storedIdols: [Idol]
    let idol: Idol?

    @State private var mode: ChekinanaIdolEditorMode
    @State private var query = ""
    @State private var candidates: [ChekinanaEnrichedIdol] = []
    @State private var selectedCatalogueCandidate: ChekinanaPreparedIdolCandidate?
    @State private var sourceId: String?
    @State private var name: String
    @State private var group: String
    @State private var color: String
    @State private var hasBirthday: Bool
    @State private var birthdayMode: ChekinanaBirthdayEditorMode
    @State private var birthdayDate: Date
    @State private var unknownBirthdayMonth: Int
    @State private var unknownBirthdayDay: Int
    @State private var fullBirthdayYearConfirmed: Bool
    @State private var birthdayWasEdited = false
    @State private var birthdaySourceValue: String?
    @State private var remoteAvatarRef: String?
    @State private var isFavorite: Bool
    @State private var verification: String
    @State private var bio: String
    @State private var note: String
    @State private var patterns: [[Float]]
    @State private var cataloguePatternSelection = ChekinanaCataloguePatternSelectionState()
    @State private var referenceItem: PhotosPickerItem?
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarPreview: ChekinanaRenderedImage?
    @State private var removesAvatar = false
    @State private var isSearching = false
    @State private var isPreparingCatalogueAvatar = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingAvatarCleanup: ChekinanaIdolAvatarCleanupTarget?
    @State private var pendingAvatarCleanupPurpose: ChekinanaIdolAvatarCleanupPurpose?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveGeneration = 0
    @State private var previewGeneration = 0

    init(idol: Idol?) {
        self.idol = idol
        _mode = State(initialValue: idol == nil ? .catalogue : .manual)
        _sourceId = State(initialValue: idol?.sourceId)
        _name = State(initialValue: idol?.name ?? "")
        _group = State(initialValue: idol?.group ?? "")
        _color = State(initialValue: idol?.color ?? "")
        let birthdaySemantic = ChekinanaBirthdayValue.semantic(idol?.birthday)
        let parsedBirthday = birthdaySemantic.flatMap {
            ChekinanaBirthdayValue.draftDisplayDate(for: $0, defaultYear: 2_000)
        }
        _hasBirthday = State(initialValue: birthdaySemantic != nil)
        _birthdayMode = State(
            initialValue: ChekinanaBirthdayEditorPolicy.initialMode(
                for: birthdaySemantic
            )
        )
        _birthdayDate = State(initialValue: parsedBirthday ?? Date())
        let today = Calendar.current.dateComponents([.month, .day], from: Date())
        let monthAndDay = birthdaySemantic?.monthAndDay
            ?? (month: today.month ?? 1, day: today.day ?? 1)
        _unknownBirthdayMonth = State(initialValue: monthAndDay.month)
        _unknownBirthdayDay = State(initialValue: monthAndDay.day)
        _fullBirthdayYearConfirmed = State(
            initialValue: birthdaySemantic?.hasKnownYear == true
        )
        _birthdaySourceValue = State(initialValue: idol?.birthday)
        _remoteAvatarRef = State(initialValue: idol?.avatarImageRef)
        _isFavorite = State(initialValue: idol?.isFavorite ?? false)
        _verification = State(initialValue: idol?.verification ?? "")
        _bio = State(initialValue: idol?.bio ?? "")
        _note = State(initialValue: idol?.note ?? "")
        _patterns = State(initialValue: idol?.recognitionPatterns ?? [])
    }

    var body: some View {
        // PhotosPicker's label is Sendable in the Swift 6 SDK. Capture the
        // state-derived title before constructing that closure.
        let avatarPickerTitle = avatarItem == nil ? "Choose avatar" : "Replace avatar"
        NavigationStack {
            Form {
                if sourceId != nil {
                    ChekinanaAccessibilityMarker(
                        identifier: "chekinana.idols.editor.catalogue-applied"
                    )
                }
                if idol == nil {
                    Section {
                        Picker("Source", selection: $mode) {
                            ForEach(ChekinanaIdolEditorMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if idol == nil, mode == .catalogue {
                    Section("Search catalogue") {
                        TextField("Idol name", text: $query)
                            .accessibilityIdentifier("chekinana.idols.editor.catalogue-query")
                        Button {
                            Task { await searchCatalogue() }
                        } label: {
                            if isSearching { ProgressView() }
                            else { Label("Search", systemImage: "magnifyingglass") }
                        }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                        .accessibilityIdentifier("chekinana.idols.editor.catalogue-search")
                        ForEach(indexedCandidates) { item in
                            Button {
                                Task { await select(item.candidate) }
                            } label: {
                                ChekinanaCatalogueIdolCard(
                                    candidate: item.candidate,
                                    index: item.index
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(item.candidate.birthdayIsInvalid)
                            .accessibilityLabel("Use \(item.candidate.idolName) catalogue information")
                            .accessibilityHint(
                                item.candidate.birthdayIsInvalid
                                    ? ChekinanaProductCopy.text(
                                        "idols.birthday_value_invalid",
                                        "Birthday must be a valid full date or month and day."
                                    )
                                    : ""
                            )
                            .accessibilityIdentifier("chekinana.idols.editor.catalogue-result.\(item.index)")
                        }
                    }
                }

                Section("Idol") {
                    HStack(spacing: 14) {
                        if !removesAvatar, let avatarPreview {
                            Image(decorative: avatarPreview.cgImage, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 62, height: 62)
                                .clipped()
                                .clipShape(Circle())
                                .overlay {
                                    Circle().stroke(
                                        ChekinanaProductTheme.border,
                                        lineWidth: 1
                                    )
                                }
                        }
                        else if removesAvatar { Image(systemName: "person.fill").frame(width: 62, height: 62).background(Color(uiColor: .tertiarySystemGroupedBackground)).clipShape(Circle()) }
                        else if let idol { ChekinanaIdolAvatar(idol: idol, size: 62) }
                        else { Image(systemName: "person.fill").frame(width: 62, height: 62).background(Color(uiColor: .tertiarySystemGroupedBackground)).clipShape(Circle()) }
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            Label(avatarPickerTitle, systemImage: "person.crop.circle.badge.plus")
                        }
                        if avatarItem != nil || avatarPreview != nil || selectedCatalogueCandidate?.avatarThumbnailImage != nil || idol?.avatarImageRef != nil { Button(role: .destructive) { let next = ChekinanaIdolAvatarSelectionPolicy.afterDelete(generation: previewGeneration); previewGeneration = next.generation; avatarItem = nil; avatarPreview = nil; removesAvatar = next.removesAvatar } label: { Image(systemName: "trash") } }
                    }
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("chekinana.idols.editor.name")
                    TextField("Group", text: $group)
                    TextField("Color", text: $color)
                    Toggle(
                        ChekinanaProductCopy.text(
                            "idols.include_birthday",
                            "Include birthday"
                        ),
                        isOn: Binding(
                            get: { hasBirthday },
                            set: { value in
                                hasBirthday = value
                                birthdayWasEdited = true
                            }
                        )
                    )
                    .accessibilityIdentifier("chekinana.idols.editor.birthday.include")
                    if hasBirthday {
                        Picker(
                            ChekinanaProductCopy.text(
                                "idols.birthday_precision",
                                "Birthday precision"
                            ),
                            selection: Binding(
                                get: { birthdayMode },
                                set: { value in
                                    guard value != birthdayMode else { return }
                                    birthdayMode = value
                                    birthdayWasEdited = true
                                    if value == .unknownYear {
                                        let components = Calendar.current.dateComponents(
                                            [.month, .day],
                                            from: birthdayDate
                                        )
                                        unknownBirthdayMonth = components.month ?? unknownBirthdayMonth
                                        unknownBirthdayDay = ChekinanaBirthdayEditorPolicy.clampedDay(
                                            components.day ?? unknownBirthdayDay,
                                            month: unknownBirthdayMonth
                                        )
                                    } else {
                                        birthdayDate = ChekinanaBirthdayValue.draftDisplayDate(
                                            for: .monthDay(
                                                month: unknownBirthdayMonth,
                                                day: unknownBirthdayDay
                                            ),
                                            defaultYear: 2_000
                                        ) ?? birthdayDate
                                        fullBirthdayYearConfirmed = false
                                    }
                                }
                            )
                        ) {
                            ForEach(ChekinanaBirthdayEditorMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("chekinana.idols.editor.birthday.mode")

                        if birthdayMode == .unknownYear {
                            HStack {
                                Picker(
                                    ChekinanaProductCopy.text("common.month", "Month"),
                                    selection: Binding(
                                        get: { unknownBirthdayMonth },
                                        set: { month in
                                            unknownBirthdayMonth = month
                                            unknownBirthdayDay = ChekinanaBirthdayEditorPolicy.clampedDay(
                                                unknownBirthdayDay,
                                                month: month
                                            )
                                            birthdayWasEdited = true
                                        }
                                    )
                                ) {
                                    ForEach(1...12, id: \.self) { month in
                                        Text(month.formatted()).tag(month)
                                    }
                                }
                                .accessibilityIdentifier("chekinana.idols.editor.birthday.month")
                                Picker(
                                    ChekinanaProductCopy.text("common.day", "Day"),
                                    selection: Binding(
                                        get: { unknownBirthdayDay },
                                        set: { day in
                                            unknownBirthdayDay = day
                                            birthdayWasEdited = true
                                        }
                                    )
                                ) {
                                    ForEach(
                                        ChekinanaBirthdayEditorPolicy.dayRange(
                                            month: unknownBirthdayMonth
                                        ),
                                        id: \.self
                                    ) { day in
                                        Text(day.formatted()).tag(day)
                                    }
                                }
                                .accessibilityIdentifier("chekinana.idols.editor.birthday.day")
                            }
                            Text(ChekinanaProductCopy.text(
                                "idols.birthday_year_unknown.detail",
                                "Only month and day are saved; no year is assumed."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            DatePicker(
                                ChekinanaProductCopy.text(
                                    "idols.birthday",
                                    "Birthday"
                                ),
                                selection: Binding(
                                    get: { birthdayDate },
                                    set: { value in
                                        birthdayDate = value
                                        birthdayWasEdited = true
                                        fullBirthdayYearConfirmed = true
                                    }
                                ),
                                displayedComponents: .date
                            )
                            .datePickerStyle(.compact)
                            .accessibilityIdentifier("chekinana.idols.editor.birthday.date")
                            if !fullBirthdayYearConfirmed {
                                Button(
                                    ChekinanaProductCopy.text(
                                        "idols.birthday_confirm_year",
                                        "Confirm selected year"
                                    )
                                ) {
                                    fullBirthdayYearConfirmed = true
                                    birthdayWasEdited = true
                                }
                                .accessibilityIdentifier(
                                    "chekinana.idols.editor.birthday.confirm-year"
                                )
                                Text(ChekinanaProductCopy.text(
                                    "idols.birthday_confirm_year.detail",
                                    "Confirm the year before saving a full birthday."
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    } else if idol?.birthday?.nonEmpty != nil,
                              ChekinanaBirthdayValue.parse(idol?.birthday) == nil,
                              !birthdayWasEdited {
                        Text(
                            ChekinanaProductCopy.text(
                                "idols.birthday_unrecognized",
                                "The stored birthday is unknown. It will be preserved until you choose a date."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    TextField("Verification", text: $verification)
                    TextField("Bio", text: $bio, axis: .vertical)
                    TextField("Note", text: $note, axis: .vertical)
                    Toggle("Favorite", isOn: $isFavorite)
                        .accessibilityIdentifier("chekinana.idols.editor.favorite")
                }

                Section("Reference Photo and Patterns") {
                    PhotosPicker(selection: $referenceItem, matching: .images) {
                        Label(
                            "Choose reference photo",
                            systemImage: "photo.badge.plus"
                        )
                    }
                    .accessibilityIdentifier("chekinana.idols.editor.reference")
                    if referenceItem != nil {
                        Text("The original photo will be encoded on this device. For a new Idol it also becomes the avatar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if patterns.isEmpty {
                        Text("No stored patterns")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(patterns.indices), id: \.self) { index in
                            HStack {
                                Label("Pattern \(index + 1) · 256D", systemImage: "waveform.path.ecg")
                                Spacer()
                                Button(role: .destructive) { patterns.remove(at: index) } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("Remove pattern \(index + 1)")
                                .accessibilityIdentifier("chekinana.idols.editor.pattern.remove.\(index)")
                            }
                        }
                    }
                    if pendingAvatarCleanup != nil {
                        Button(
                            pendingAvatarCleanupPurpose == .rollbackAfterFailedSave
                                ? "Retry staged avatar cleanup"
                                : "Retry old avatar cleanup"
                        ) {
                            retryAvatarCleanup()
                        }
                        .accessibilityIdentifier("chekinana.idols.editor.retry-avatar-cleanup")
                    }
                }
                .overlay(alignment: .topLeading) {
                    ChekinanaAccessibilityValueMarker(
                        identifier: "chekinana.idols.editor.pattern-count",
                        label: "Pattern count",
                        value: patterns.count.formatted()
                    )
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .disabled(isSaving)
            .navigationTitle(idol == nil ? "Add Idol" : "Edit Idol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestCancel() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("chekinana.idols.editor.cancel")
                        .accessibilityHint(
                            pendingAvatarCleanup == nil
                                ? "Close without saving"
                                : "Clean up the staged or previous avatar before closing"
                        )
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let generation = saveGeneration
                        saveTask = Task { await save(generation: generation) }
                    }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isSaving
                                || isPreparingCatalogueAvatar
                                || pendingAvatarCleanup != nil
                                || (hasBirthday
                                    && birthdayMode == .fullDate
                                    && !fullBirthdayYearConfirmed)
                        )
                        .accessibilityIdentifier("chekinana.idols.editor.save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving || pendingAvatarCleanup != nil)
        .onDisappear {
            saveGeneration &+= 1
            saveTask?.cancel()
            saveTask = nil
        }
        .onChange(of: mode) { _, selectedMode in
            guard idol == nil, selectedMode == .manual else { return }
            sourceId = nil
            cataloguePatternSelection.clear()
            patterns = []
            remoteAvatarRef = nil
            selectedCatalogueCandidate = nil
            isFavorite = false
            note = ""
            hasBirthday = false
            birthdayMode = .fullDate
            fullBirthdayYearConfirmed = false
            birthdaySourceValue = nil
            birthdayWasEdited = true
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            removesAvatar = false
            previewGeneration &+= 1
            let generation = previewGeneration
            let identity = String(describing: item)
            Task {
                guard let image = try? await ChekinanaProductMediaLoader.load(item) else { return }
                let preview = await ChekinanaImageWorker.thumbnailImage(from: image.data, maxDimension: 256)
                guard ChekinanaIdolAvatarSelectionPolicy.acceptsPreview(generation: generation, currentGeneration: previewGeneration, itemMatches: avatarItem.map({ String(describing: $0) }) == identity, removesAvatar: removesAvatar) else { return }
                avatarPreview = preview
            }
        }
        .accessibilityIdentifier("chekinana.idols.editor")
    }

    private var indexedCandidates: [ChekinanaIndexedCatalogueIdolCandidate] {
        candidates.enumerated().map {
            ChekinanaIndexedCatalogueIdolCandidate(
                index: $0.offset,
                candidate: $0.element
            )
        }
    }

    @MainActor
    private func searchCatalogue() async {
        isSearching = true
        defer { isSearching = false }
        do {
            var seenIdentities = Set<String>()
            candidates = try await ChekinanaIdolEnrichmentClient().search(for: query).filter {
                seenIdentities.insert(
                    ChekinanaCatalogueIdolCardAvatarPresentation.identity(for: $0)
                ).inserted
            }
            errorMessage = nil
        } catch {
            candidates = []
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func select(_ rawCandidate: ChekinanaEnrichedIdol) async {
        let candidate: ChekinanaEnrichedIdol
        do {
            candidate = try ChekinanaBirthdayValue.normalizedCatalogueCandidate(
                rawCandidate
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let candidateIdentity = candidate.sourceId
        previewGeneration &+= 1
        let generation = previewGeneration
        sourceId = candidate.sourceId
        selectedCatalogueCandidate = nil
        remoteAvatarRef = nil
        if avatarItem == nil { avatarPreview = nil }
        cataloguePatternSelection.select(sourceId: candidate.sourceId)
        patterns = cataloguePatternSelection.patterns
        name = candidate.idolName
        group = candidate.groupName ?? ""
        color = candidate.color ?? ""
        birthdaySourceValue = candidate.birthday
        if let semantic = ChekinanaBirthdayValue.semantic(candidate.birthday),
           let parsedBirthday = ChekinanaBirthdayValue.draftDisplayDate(
               for: semantic,
               defaultYear: 2_000
           ) {
            birthdayDate = parsedBirthday
            hasBirthday = true
            birthdayMode = ChekinanaBirthdayEditorPolicy.initialMode(for: semantic)
            let monthAndDay = semantic.monthAndDay
            unknownBirthdayMonth = monthAndDay.month
            unknownBirthdayDay = monthAndDay.day
            fullBirthdayYearConfirmed = semantic.hasKnownYear
        } else {
            hasBirthday = false
            birthdayMode = .fullDate
            fullBirthdayYearConfirmed = false
        }
        birthdayWasEdited = false
        verification = candidate.verification ?? ""
        bio = candidate.bio ?? ""
        if let existing = storedIdols.first(where: { $0.sourceId == candidate.sourceId }) {
            isFavorite = existing.isFavorite
            note = existing.note
        } else {
            isFavorite = false
            note = ""
        }
        isPreparingCatalogueAvatar = true
        errorMessage = nil
        do {
            let prepared = try await ChekinanaCatalogueIdolAvatarResolver.prepare(candidate)
            guard ChekinanaIdolAvatarSelectionPolicy.acceptsCataloguePreview(
                generation: generation,
                currentGeneration: previewGeneration,
                candidateMatches: sourceId == candidateIdentity,
                removesAvatar: removesAvatar,
                hasLocalItem: avatarItem != nil
            ) else { return }
            selectedCatalogueCandidate = prepared
            avatarPreview = prepared.avatarThumbnailImage
        } catch {
            guard generation == previewGeneration, sourceId == candidateIdentity else { return }
            errorMessage = "Catalogue avatar could not be prepared. Tap this result to retry: \(error.localizedDescription)"
        }
        if generation == previewGeneration, sourceId == candidateIdentity {
            isPreparingCatalogueAvatar = false
        }
    }

    @MainActor
    private func save(generation: Int) async {
        guard generation == saveGeneration, !Task.isCancelled else { return }
        isSaving = true
        defer { if generation == saveGeneration { isSaving = false; saveTask = nil } }
        do {
            let normalizedName = try ChekinanaManualIdolInput.normalizedName(name)
            let storedBirthday: String?
            if birthdayWasEdited {
                storedBirthday = try ChekinanaBirthdayEditorPolicy.storageValue(
                    hasBirthday: hasBirthday,
                    mode: birthdayMode,
                    fullDate: birthdayDate,
                    unknownMonth: unknownBirthdayMonth,
                    unknownDay: unknownBirthdayDay,
                    fullYearConfirmed: fullBirthdayYearConfirmed
                )
            } else if let birthdaySourceValue = birthdaySourceValue?.nonEmpty {
                do {
                    storedBirthday = try ChekinanaBirthdayValue.normalizedStorage(
                        birthdaySourceValue
                    )
                } catch {
                    guard idol != nil else { throw error }
                    // Unknown historical values remain byte-for-byte intact
                    // until the user explicitly replaces or clears them.
                    storedBirthday = birthdaySourceValue
                }
            } else {
                storedBirthday = nil
            }
            let isNewCatalogueSelection = idol == nil
                && mode == .catalogue
                && sourceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let resolution: ChekinanaCatalogueIdolTarget
            if let idol {
                resolution = ChekinanaCatalogueIdolTarget(idol: idol, shouldInsert: false)
            } else if isNewCatalogueSelection, let sourceId {
                resolution = try ChekinanaCatalogueIdolUpsert.resolve(
                    sourceId: sourceId,
                    fallbackName: normalizedName,
                    in: modelContext
                )
            } else {
                resolution = ChekinanaCatalogueIdolTarget(
                    idol: try ChekinanaManualIdolInput.makeNameOnlyIdol(
                        name: normalizedName
                    ),
                    shouldInsert: true
                )
            }
            let target = resolution.idol
            let previousAvatarRef = target.avatarImageRef
            let explicitlyRemovingAvatar = removesAvatar
            var avatarRef = explicitlyRemovingAvatar ? nil : previousAvatarRef
            var newPatterns: [[Float]]
            if isNewCatalogueSelection {
                newPatterns = ChekinanaLocalPatternRegistry.mergedPatterns([
                    target.recognitionPatterns,
                    patterns,
                    ChekinanaLocalPatternRegistry.patterns(for: sourceId),
                ])
            } else {
                // Editing an existing Idol is authoritative: patterns removed
                // in the editor must not be silently restored from the registry.
                newPatterns = ChekinanaLocalPatternRegistry.mergedPatterns([patterns])
            }
            var stagedAvatar: ChekinanaIdolReferenceStore.StoredAvatar?
            if !explicitlyRemovingAvatar, let avatarItem {
                let image = try await ChekinanaProductMediaLoader.load(avatarItem)
                guard generation == saveGeneration, !Task.isCancelled else { return }
                stagedAvatar = try await ChekinanaIdolReferenceStore.saveAvatar(image.data, idolID: target.id)
                avatarRef = stagedAvatar?.ref
            }
            if !explicitlyRemovingAvatar, let referenceItem {
                let image = try await ChekinanaProductMediaLoader.load(referenceItem)
                guard generation == saveGeneration, !Task.isCancelled else { return }
                let encoded = try await ChekinanaPatternEncoder.shared.encode(image.data)
                newPatterns = ChekinanaLocalPatternRegistry.mergedPatterns([
                    newPatterns,
                    [encoded],
                ])
                if sourceId == nil, stagedAvatar == nil {
                    stagedAvatar = try await ChekinanaIdolReferenceStore.saveAvatar(
                        image.data,
                        idolID: target.id
                    )
                    avatarRef = stagedAvatar?.ref
                }
            }
            if let sourceId, stagedAvatar == nil, !explicitlyRemovingAvatar {
                let prepared: ChekinanaPreparedIdolCandidate?
                if isNewCatalogueSelection,
                   let selectedCatalogueCandidate,
                   selectedCatalogueCandidate.candidate.sourceId == sourceId {
                    prepared = selectedCatalogueCandidate
                } else if ChekinanaIdolReferenceStore.hasManagedAvatarFile(
                    imageRef: previousAvatarRef,
                    idolID: target.id
                ) {
                    prepared = nil
                } else {
                    prepared = try await ChekinanaCatalogueIdolAvatarResolver.prepareExact(
                        sourceID: sourceId,
                        query: name
                    )
                }
                guard generation == saveGeneration, !Task.isCancelled else { return }
                if let prepared {
                    stagedAvatar = try await ChekinanaCatalogueIdolAvatarLocalizer.stage(
                        prepared,
                        idolID: target.id
                    )
                    avatarRef = stagedAvatar?.ref
                }
            } else if ChekinanaManualIdolInput.requiresManagedAvatar(sourceId: sourceId),
                      !explicitlyRemovingAvatar, stagedAvatar == nil,
                      !ChekinanaIdolReferenceStore.hasManagedAvatarFile(
                        imageRef: previousAvatarRef,
                        idolID: target.id
                      ) {
                throw ChekinanaCatalogueIdolAvatarLocalizerError.missingAvatar
            }
            guard generation == saveGeneration, !Task.isCancelled else { return }
            let result = try ChekinanaIdolPersistence.save(
                target,
                inserting: resolution.shouldInsert,
                previousAvatarRef: previousAvatarRef,
                stagedAvatar: stagedAvatar,
                in: modelContext
            ) { target in
                target.sourceId = isNewCatalogueSelection ? sourceId : idol?.sourceId
                target.name = normalizedName
                target.group = group.nonEmpty
                target.color = color.nonEmpty
                // A catalogue response with no birthday is absence of new
                // information, not an instruction to erase an existing value.
                if resolution.shouldInsert || birthdayWasEdited || storedBirthday != nil {
                    target.birthday = storedBirthday
                }
                target.avatarImageRef = avatarRef
                target.isFavorite = isFavorite
                target.verification = verification.nonEmpty
                target.bio = bio.nonEmpty
                target.note = note
                target.pattern = nil
                target.patterns = newPatterns.filter(ChekinanaPatternClassifier.isValidEmbedding)
                target.updatedAt = Date()
            }
            guard generation == saveGeneration, !Task.isCancelled else { return }
            referenceItem = nil
            avatarItem = nil
            remoteAvatarRef = target.avatarImageRef
            patterns = target.patterns
            if let cleanup = result.pendingAvatarCleanup {
                pendingAvatarCleanup = cleanup
                pendingAvatarCleanupPurpose = .afterSuccessfulSave
                errorMessage = "Idol was saved, but the previous managed avatar could not be removed. Retry cleanup before closing."
                return
            }
            dismiss()
        } catch {
            if let persistenceError = error as? ChekinanaIdolPersistenceError,
               let cleanup = persistenceError.pendingCleanupTarget {
                pendingAvatarCleanup = cleanup
                pendingAvatarCleanupPurpose = .rollbackAfterFailedSave
                errorMessage = persistenceError.localizedDescription
            } else if error is ChekinanaProductDateSelectionError
                        || error is ChekinanaManualIdolInputError {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "Reference photo could not be encoded or saved: \(error.localizedDescription)"
            }
        }
    }

    private func retryAvatarCleanup() {
        guard let pendingAvatarCleanup else { return }
        do {
            _ = try ChekinanaIdolReferenceStore.removeManagedAvatar(
                pendingAvatarCleanup.imageRef,
                idolID: pendingAvatarCleanup.idolID,
                directory: pendingAvatarCleanup.directory
            )
            self.pendingAvatarCleanup = nil
            let purpose = pendingAvatarCleanupPurpose
            pendingAvatarCleanupPurpose = nil
            if purpose == .afterSuccessfulSave {
                errorMessage = nil
                dismiss()
            } else {
                errorMessage = "The staged avatar was cleaned up. The database changes were not saved; review the form and tap Save again, or Cancel."
            }
        } catch {
            if pendingAvatarCleanupPurpose == .rollbackAfterFailedSave {
                errorMessage = "Database changes remain unsaved and the staged avatar still needs cleanup: \(error.localizedDescription)"
            } else {
                errorMessage = "Idol is saved, but old avatar cleanup still failed: \(error.localizedDescription)"
            }
        }
    }

    private func requestCancel() {
        guard pendingAvatarCleanup == nil else {
            errorMessage = pendingAvatarCleanupPurpose == .rollbackAfterFailedSave
                ? "The Idol was not saved, but its staged avatar still needs cleanup. Retry cleanup before closing."
                : "The Idol was saved, but its previous avatar still needs cleanup. Retry cleanup before closing."
            return
        }
        dismiss()
    }
}

struct ChekinanaIdolAvatarCleanupTarget: Equatable {
    let imageRef: String
    let idolID: UUID
    let directory: URL?
}

enum ChekinanaIdolAvatarSelectionPolicy {
    static func afterDelete(generation: Int) -> (generation: Int, removesAvatar: Bool) {
        (generation &+ 1, true)
    }
    static func acceptsPreview(generation: Int, currentGeneration: Int, itemMatches: Bool, removesAvatar: Bool) -> Bool {
        generation == currentGeneration && itemMatches && !removesAvatar
    }
    static func shouldReadExistingAvatar(explicitlyRemoving: Bool) -> Bool { !explicitlyRemoving }
    static func acceptsCataloguePreview(generation: Int, currentGeneration: Int, candidateMatches: Bool, removesAvatar: Bool, hasLocalItem: Bool) -> Bool {
        generation == currentGeneration && candidateMatches && !removesAvatar && !hasLocalItem
    }
}

enum ChekinanaIdolAvatarCleanupPurpose {
    case afterSuccessfulSave
    case rollbackAfterFailedSave
}

enum ChekinanaIdolPersistenceError: LocalizedError {
    case databaseSaveAndStagedAvatarCleanupFailed(
        save: String,
        cleanup: String,
        pendingCleanupTarget: ChekinanaIdolAvatarCleanupTarget
    )

    var pendingCleanupTarget: ChekinanaIdolAvatarCleanupTarget? {
        switch self {
        case .databaseSaveAndStagedAvatarCleanupFailed(_, _, let target):
            return target
        }
    }

    var errorDescription: String? {
        switch self {
        case .databaseSaveAndStagedAvatarCleanupFailed(let save, let cleanup, _):
            return "The database was not saved and the previous Idol/avatar reference remains unchanged. The new staged avatar still needs cleanup (save: \(save); cleanup: \(cleanup)). Retry cleanup before closing."
        }
    }
}

struct ChekinanaIdolPersistenceResult {
    let pendingAvatarCleanup: ChekinanaIdolAvatarCleanupTarget?
}

@MainActor
enum ChekinanaIdolPersistence {
    typealias SaveContext = (ModelContext) throws -> Void
    typealias RemoveStagedAvatar = (ChekinanaIdolReferenceStore.StoredAvatar) throws -> Void

    static func save(
        _ idol: Idol,
        inserting: Bool,
        previousAvatarRef: String?,
        stagedAvatar: ChekinanaIdolReferenceStore.StoredAvatar?,
        in modelContext: ModelContext,
        avatarDirectory: URL? = nil,
        saveContext: SaveContext = { try $0.save() },
        removeStagedAvatar: RemoveStagedAvatar = {
            try FileManager.default.removeItem(at: $0.url)
        },
        apply: (Idol) -> Void
    ) throws -> ChekinanaIdolPersistenceResult {
        if inserting {
            modelContext.insert(idol)
        }
        apply(idol)
        do {
            try saveContext(modelContext)
        } catch {
            let saveError = error
            if inserting {
                modelContext.delete(idol)
            }
            modelContext.rollback()
            if let stagedAvatar {
                do {
                    try removeStagedAvatar(stagedAvatar)
                } catch {
                    throw ChekinanaIdolPersistenceError.databaseSaveAndStagedAvatarCleanupFailed(
                        save: saveError.localizedDescription,
                        cleanup: error.localizedDescription,
                        pendingCleanupTarget: ChekinanaIdolAvatarCleanupTarget(
                            imageRef: stagedAvatar.ref,
                            idolID: idol.id,
                            directory: avatarDirectory
                                ?? stagedAvatar.url.deletingLastPathComponent()
                        )
                    )
                }
            }
            throw saveError
        }

        return cleanupResult(
            previousAvatarRef,
            replacingWith: idol.avatarImageRef,
            idolID: idol.id,
            directory: avatarDirectory
        )
    }

    static func delete(
        _ idol: Idol,
        from modelContext: ModelContext,
        avatarDirectory: URL? = nil,
        saveContext: SaveContext = { try $0.save() }
    ) throws -> ChekinanaIdolPersistenceResult {
        let avatarRef = idol.avatarImageRef
        let idolID = idol.id
        modelContext.delete(idol)
        do {
            try saveContext(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
        return cleanupResult(
            avatarRef,
            replacingWith: nil,
            idolID: idolID,
            directory: avatarDirectory
        )
    }

    private static func cleanupResult(
        _ previousAvatarRef: String?,
        replacingWith newAvatarRef: String?,
        idolID: UUID,
        directory: URL?
    ) -> ChekinanaIdolPersistenceResult {
        guard let previousAvatarRef,
              previousAvatarRef != newAvatarRef else {
            return ChekinanaIdolPersistenceResult(pendingAvatarCleanup: nil)
        }
        do {
            _ = try ChekinanaIdolReferenceStore.removeManagedAvatar(
                previousAvatarRef,
                idolID: idolID,
                directory: directory
            )
            return ChekinanaIdolPersistenceResult(pendingAvatarCleanup: nil)
        } catch {
            return ChekinanaIdolPersistenceResult(
                pendingAvatarCleanup: ChekinanaIdolAvatarCleanupTarget(
                    imageRef: previousAvatarRef,
                    idolID: idolID,
                    directory: directory
                )
            )
        }
    }
}

enum ChekinanaIdolReferenceStore {
    struct StoredAvatar: Equatable {
        let ref: String
        let url: URL
    }

    static func saveAvatar(
        _ originalData: Data,
        idolID: UUID,
        directory: URL? = nil
    ) async throws -> StoredAvatar {
        guard let jpeg = await ChekinanaImageWorker.reencodedJPEGData(from: originalData),
              !jpeg.isEmpty else {
            throw ChekinanaProductMediaError.unreadableImage
        }
        let resolvedDirectory = try directory ?? ChekiImageRefResolver.chekiImagesDirectory()
        try FileManager.default.createDirectory(
            at: resolvedDirectory,
            withIntermediateDirectories: true
        )
        let filename = managedFilename(idolID: idolID)
        let url = resolvedDirectory.appendingPathComponent(filename)
        try jpeg.write(to: url, options: .atomic)
        return StoredAvatar(ref: filename, url: url)
    }

    static func managedFilename(idolID: UUID, token: UUID = UUID()) -> String {
        "idol-avatar-\(idolID.uuidString.lowercased())-\(token.uuidString.lowercased()).jpg"
    }

    static func managedAvatarURL(
        for imageRef: String?,
        idolID: UUID,
        directory: URL? = nil
    ) throws -> URL? {
        guard let imageRef = imageRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imageRef.isEmpty,
              imageRef == URL(fileURLWithPath: imageRef).lastPathComponent else {
            return nil
        }
        let lowercasedRef = imageRef.lowercased()
        let legacyFilename = "idol-\(idolID.uuidString.lowercased()).jpg"
        if lowercasedRef != legacyFilename {
            let prefix = "idol-avatar-\(idolID.uuidString.lowercased())-"
            guard lowercasedRef.hasPrefix(prefix),
                  lowercasedRef.hasSuffix(".jpg") else {
                return nil
            }
            let tokenStart = lowercasedRef.index(
                lowercasedRef.startIndex,
                offsetBy: prefix.count
            )
            let tokenEnd = lowercasedRef.index(lowercasedRef.endIndex, offsetBy: -4)
            guard tokenStart < tokenEnd,
                  UUID(uuidString: String(lowercasedRef[tokenStart..<tokenEnd])) != nil else {
                return nil
            }
        }
        let resolvedDirectory = try directory ?? ChekiImageRefResolver.chekiImagesDirectory()
        return resolvedDirectory.appendingPathComponent(imageRef)
    }

    static func validatedManagedAvatar(
        imageRef: String?,
        idolID: UUID,
        directory: URL? = nil
    ) async -> ChekinanaRenderedImage? {
        guard let url = try? managedAvatarURL(
            for: imageRef,
            idolID: idolID,
            directory: directory
        ),
        FileManager.default.fileExists(atPath: url.path),
        let data = try? Data(contentsOf: url) else {
            return nil
        }
        return await ChekinanaImageWorker.thumbnailImage(
            from: data,
            maxDimension: 256
        )
    }

    static func hasManagedAvatarFile(
        imageRef: String?,
        idolID: UUID,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let url = try? managedAvatarURL(
            for: imageRef,
            idolID: idolID,
            directory: directory
        ),
        fileManager.fileExists(atPath: url.path),
        let attributes = try? fileManager.attributesOfItem(atPath: url.path),
        let fileSize = attributes[.size] as? NSNumber else {
            return false
        }
        return fileSize.int64Value > 0
    }

    @discardableResult
    static func removeManagedAvatar(
        _ imageRef: String?,
        idolID: UUID,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let url = try managedAvatarURL(
            for: imageRef,
            idolID: idolID,
            directory: directory
        ) else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        try fileManager.removeItem(at: url)
        return true
    }
}

enum ChekinanaCatalogueIdolAvatarLocalizerError: LocalizedError {
    case missingAvatar
    case identityMismatch
    case cleanupRequired

    var errorDescription: String? {
        switch self {
        case .missingAvatar:
            "The catalogue avatar is unavailable. Retry the same catalogue result before saving."
        case .identityMismatch:
            "The prepared avatar does not match this catalogue Idol. Search and select the Idol again."
        case .cleanupRequired:
            "The Idol was saved, but an old managed avatar still requires cleanup."
        }
    }
}

enum ChekinanaCatalogueIdolAvatarLocalizer {
    static func stage(
        _ prepared: ChekinanaPreparedIdolCandidate,
        idolID: UUID,
        directory: URL? = nil
    ) async throws -> ChekinanaIdolReferenceStore.StoredAvatar {
        guard let expectedIdentity = ChekinanaIdolAvatarIdentity.make(
            sourceID: prepared.candidate.sourceId,
            avatarURL: prepared.candidate.avatarUrl
        ) else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.missingAvatar
        }
        guard prepared.avatarIdentity == expectedIdentity else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.identityMismatch
        }
        guard let data = prepared.avatarThumbnailData, !data.isEmpty else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.missingAvatar
        }
        return try await ChekinanaIdolReferenceStore.saveAvatar(
            data,
            idolID: idolID,
            directory: directory
        )
    }
}

@MainActor
enum ChekinanaIdolAvatarRepairCoordinator {
    typealias PrepareExact = (String, String) async throws -> ChekinanaPreparedIdolCandidate
    typealias Stage = (
        ChekinanaPreparedIdolCandidate,
        UUID,
        URL?
    ) async throws -> ChekinanaIdolReferenceStore.StoredAvatar

    private struct FlightKey: Hashable {
        let modelContext: ObjectIdentifier
        let idolID: UUID
        let sourceID: String
        let directoryPath: String
    }

    private struct Flight {
        let token: UUID
        let task: Task<Bool, Error>
    }

    private static var flights: [FlightKey: Flight] = [:]

    @discardableResult
    static func repairIfNeeded(
        _ idol: Idol,
        in modelContext: ModelContext,
        directory: URL? = nil,
        prepareExact: @escaping PrepareExact = { sourceID, query in
            try await ChekinanaCatalogueIdolAvatarResolver.prepareExact(
                sourceID: sourceID,
                query: query
            )
        },
        stage: @escaping Stage = { prepared, idolID, directory in
            try await ChekinanaCatalogueIdolAvatarLocalizer.stage(
                prepared,
                idolID: idolID,
                directory: directory
            )
        }
    ) async throws -> Bool {
        let expectedIdolID = idol.id
        let expectedModelID = idol.persistentModelID
        let initialSourceID = idol.sourceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLive(
            idol,
            expectedIdolID: expectedIdolID,
            expectedModelID: expectedModelID,
            expectedSourceID: initialSourceID,
            in: modelContext
        ) else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.identityMismatch
        }
        if await ChekinanaIdolReferenceStore.validatedManagedAvatar(
            imageRef: idol.avatarImageRef,
            idolID: idol.id,
            directory: directory
        ) != nil {
            return false
        }
        guard isLive(
            idol,
            expectedIdolID: expectedIdolID,
            expectedModelID: expectedModelID,
            expectedSourceID: initialSourceID,
            in: modelContext
        ) else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.identityMismatch
        }
        let sourceID = initialSourceID
        guard let sourceID, !sourceID.isEmpty else {
            throw ChekinanaIdolAvatarRepairError.missingCatalogueIdentity(idol.name)
        }
        let key = FlightKey(
            modelContext: ObjectIdentifier(modelContext),
            idolID: idol.id,
            sourceID: sourceID,
            directoryPath: directory?.standardizedFileURL.path ?? "<managed-default>"
        )
        if let flight = flights[key] {
            return try await flight.task.value
        }
        let token = UUID()
        let task = Task { @MainActor in
            try await performRepair(
                idol,
                expectedModelID: expectedModelID,
                sourceID: sourceID,
                in: modelContext,
                directory: directory,
                prepareExact: prepareExact,
                stage: stage
            )
        }
        flights[key] = Flight(token: token, task: task)
        do {
            let result = try await task.value
            if flights[key]?.token == token {
                flights[key] = nil
            }
            return result
        } catch {
            if flights[key]?.token == token {
                flights[key] = nil
            }
            throw error
        }
    }

    private static func performRepair(
        _ idol: Idol,
        expectedModelID: PersistentIdentifier,
        sourceID: String,
        in modelContext: ModelContext,
        directory: URL?,
        prepareExact: PrepareExact,
        stage: Stage
    ) async throws -> Bool {
        let expectedIdolID = idol.id
        if await hasValidManagedAvatar(idol, directory: directory) {
            return false
        }
        guard isLive(
            idol,
            expectedIdolID: expectedIdolID,
            expectedModelID: expectedModelID,
            expectedSourceID: sourceID,
            in: modelContext
        ) else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.identityMismatch
        }
        let prepared = try await prepareExact(sourceID, idol.name)
        guard isLive(
                  idol,
                  expectedIdolID: expectedIdolID,
                  expectedModelID: expectedModelID,
                  expectedSourceID: sourceID,
                  in: modelContext
              ),
              prepared.candidate.sourceId == sourceID else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.identityMismatch
        }
        if await hasValidManagedAvatar(idol, directory: directory) {
            return false
        }
        guard isLive(
            idol,
            expectedIdolID: expectedIdolID,
            expectedModelID: expectedModelID,
            expectedSourceID: sourceID,
            in: modelContext
        ) else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.identityMismatch
        }
        let staged = try await stage(prepared, expectedIdolID, directory)
        guard isLive(
            idol,
            expectedIdolID: expectedIdolID,
            expectedModelID: expectedModelID,
            expectedSourceID: sourceID,
            in: modelContext
        ) else {
            try removeUnusedStagedAvatar(staged)
            throw ChekinanaCatalogueIdolAvatarLocalizerError.identityMismatch
        }
        if await hasValidManagedAvatar(idol, directory: directory) {
            try removeUnusedStagedAvatar(staged)
            return false
        }
        guard isLive(
            idol,
            expectedIdolID: expectedIdolID,
            expectedModelID: expectedModelID,
            expectedSourceID: sourceID,
            in: modelContext
        ) else {
            try removeUnusedStagedAvatar(staged)
            throw ChekinanaCatalogueIdolAvatarLocalizerError.identityMismatch
        }
        let previousAvatarRef = idol.avatarImageRef
        _ = try ChekinanaIdolPersistence.save(
            idol,
            inserting: false,
            previousAvatarRef: previousAvatarRef,
            stagedAvatar: staged,
            in: modelContext,
            avatarDirectory: directory
        ) { target in
            target.avatarImageRef = staged.ref
            target.updatedAt = Date()
        }
        return true
    }

    private static func hasValidManagedAvatar(
        _ idol: Idol,
        directory: URL?
    ) async -> Bool {
        await ChekinanaIdolReferenceStore.validatedManagedAvatar(
            imageRef: idol.avatarImageRef,
            idolID: idol.id,
            directory: directory
        ) != nil
    }

    private static func isLive(
        _ idol: Idol,
        expectedIdolID: UUID,
        expectedModelID: PersistentIdentifier,
        expectedSourceID: String?,
        in modelContext: ModelContext
    ) -> Bool {
        guard idol.modelContext === modelContext,
              idol.persistentModelID == expectedModelID,
              !modelContext.deletedModelsArray.contains(where: {
                  $0.persistentModelID == expectedModelID
              }) else {
            return false
        }
        return idol.id == expectedIdolID
            && idol.sourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
                == expectedSourceID
    }

    private static func removeUnusedStagedAvatar(
        _ staged: ChekinanaIdolReferenceStore.StoredAvatar
    ) throws {
        do {
            try FileManager.default.removeItem(at: staged.url)
        } catch {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.cleanupRequired
        }
    }
}

enum ChekinanaCatalogueIdolAvatarResolver {
    static func prepare(
        _ candidate: ChekinanaEnrichedIdol
    ) async throws -> ChekinanaPreparedIdolCandidate {
        let candidate = try ChekinanaBirthdayValue.normalizedCatalogueCandidate(
            candidate
        )
        guard let identity = ChekinanaIdolAvatarIdentity.make(
            sourceID: candidate.sourceId,
            avatarURL: candidate.avatarUrl
        ),
        let data = try await ChekinanaCatalogueAvatarThumbnailCache.shared
            .thumbnailData(for: candidate),
        !data.isEmpty,
        let image = await ChekinanaImageWorker.thumbnailImage(
            from: data,
            maxDimension: 256
        ) else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.missingAvatar
        }
        return ChekinanaPreparedIdolCandidate(
            candidate: candidate,
            avatarThumbnailData: data,
            avatarIdentity: identity,
            avatarThumbnailImage: image
        )
    }

    static func prepareExact(
        sourceID: String,
        query: String
    ) async throws -> ChekinanaPreparedIdolCandidate {
        let results = try await ChekinanaIdolEnrichmentClient().search(for: query)
        guard let exact = results.first(where: { $0.sourceId == sourceID }) else {
            throw ChekinanaCatalogueIdolAvatarLocalizerError.identityMismatch
        }
        return try await prepare(exact)
    }
}

private enum ChekinanaEventListPage: String, CaseIterable, Identifiable {
    case upcoming
    case past

    var id: String { rawValue }
    var title: String {
        switch self {
        case .upcoming: ChekinanaProductCopy.text("events.upcoming", "Upcoming")
        case .past: ChekinanaProductCopy.text("events.past", "Past")
        }
    }
}

enum ChekinanaEventRemoteImagePolicy {
    private static let trustedHosts = ["sinaimg.cn", "weibo.cn", "weibocdn.com"]

    static func trustedURL(_ rawURL: String) -> URL? {
        guard let url = URL(string: rawURL) else { return nil }
        return isTrusted(url) ? url : nil
    }

    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              trustedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }),
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return false
        }
        return true
    }
}

final class ChekinanaEventRemoteImageRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    typealias TrustEvaluator = @Sendable (URL) -> Bool
    private let trustEvaluator: TrustEvaluator

    init(trustEvaluator: @escaping TrustEvaluator = ChekinanaEventRemoteImagePolicy.isTrusted) {
        self.trustEvaluator = trustEvaluator
    }

    func trustedRedirectRequest(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, trustEvaluator(url) else { return nil }
        return request
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(trustedRedirectRequest(request))
    }
}

actor ChekinanaEventRemoteImageDownloader {
    static let shared = ChekinanaEventRemoteImageDownloader()
    static let maximumBodySize = 8 * 1_024 * 1_024

    typealias DownloadOperation = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    enum DownloadError: Error, Equatable {
        case untrustedURL
        case invalidResponse
        case invalidContentType
        case emptyBody
        case bodyTooLarge
    }

    private let download: DownloadOperation

    init(session: URLSession = ChekinanaEventRemoteImageDownloader.makeSession()) {
        download = { request in try await session.download(for: request) }
    }

    init(download: @escaping DownloadOperation) {
        self.download = download
    }

    func data(for url: URL) async throws -> Data {
        guard ChekinanaEventRemoteImagePolicy.isTrusted(url) else {
            throw DownloadError.untrustedURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.timeoutInterval = 12
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (temporaryURL, response) = try await download(request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let finalURL = response.url,
              ChekinanaEventRemoteImagePolicy.isTrusted(finalURL) else {
            throw DownloadError.invalidResponse
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard contentType?.hasPrefix("image/") == true else {
            throw DownloadError.invalidContentType
        }
        if response.expectedContentLength > Int64(Self.maximumBodySize) {
            throw DownloadError.bodyTooLarge
        }
        let fileSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let fileSize, fileSize > 0 else { throw DownloadError.emptyBody }
        guard fileSize <= Self.maximumBodySize else { throw DownloadError.bodyTooLarge }
        let data = try Data(contentsOf: temporaryURL)
        guard !data.isEmpty else { throw DownloadError.emptyBody }
        guard data.count <= Self.maximumBodySize else { throw DownloadError.bodyTooLarge }
        return data
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary =
            ChekinanaCatalogueNetworkPolicy.directConnectionProxyDictionary()
        return URLSession(
            configuration: configuration,
            delegate: ChekinanaEventRemoteImageRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

enum ChekinanaEventMediaJournal {
    private static let pendingKey = "chekinana.event-media.pending.v1"
    private static let deletionKey = "chekinana.event-media.deletion.v1"
    private static let lock = NSLock()

    static func recordPending(_ ref: String, defaults: UserDefaults = .standard) {
        update(key: pendingKey, adding: [ref], removing: [], defaults: defaults)
    }

    static func clearPending(_ refs: [String], defaults: UserDefaults = .standard) {
        update(key: pendingKey, adding: [], removing: refs, defaults: defaults)
    }

    static func queueDeletion(_ refs: [String], defaults: UserDefaults = .standard) {
        update(key: deletionKey, adding: refs, removing: [], defaults: defaults)
    }

    static func cancelDeletion(_ refs: [String], defaults: UserDefaults = .standard) {
        update(key: deletionKey, adding: [], removing: refs, defaults: defaults)
    }

    static func discardPending(
        _ refs: [String],
        directory: URL? = nil,
        defaults: UserDefaults = .standard,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        recoverQueue(
            key: pendingKey,
            referencedRefs: [],
            limitedTo: Set(refs),
            directory: directory,
            defaults: defaults,
            removeItem: removeItem
        )
    }

    static func recover(
        modelContext: ModelContext,
        directory: URL? = nil,
        defaults: UserDefaults = .standard,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        let eventRefs = try modelContext.fetch(FetchDescriptor<Event>())
            .compactMap(\.avatarImageRef)
        let imageRefs = try modelContext.fetch(FetchDescriptor<EventImage>())
            .map(\.imageRef)
        recover(
            referencedRefs: Set(eventRefs + imageRefs),
            directory: directory,
            defaults: defaults,
            removeItem: removeItem
        )
    }

    static func recover(
        referencedRefs: Set<String>,
        directory: URL? = nil,
        defaults: UserDefaults = .standard,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        recoverQueue(
            key: pendingKey,
            referencedRefs: referencedRefs,
            limitedTo: nil,
            directory: directory,
            defaults: defaults,
            removeItem: removeItem
        )
        recoverQueue(
            key: deletionKey,
            referencedRefs: referencedRefs,
            limitedTo: nil,
            directory: directory,
            defaults: defaults,
            removeItem: removeItem
        )
    }

    static func pendingRefs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: pendingKey) ?? [])
    }

    static func deletionRefs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: deletionKey) ?? [])
    }

    static func isManaged(_ ref: String) -> Bool {
        guard ref == URL(fileURLWithPath: ref).lastPathComponent else { return false }
        return [
            #"^event-avatar-[0-9a-f-]{36}-[0-9a-f-]{36}\.jpg$"#,
            #"^event-image-[0-9a-f-]{36}-[0-9a-f-]{36}\.jpg$"#,
        ].contains { ref.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static func update(
        key: String,
        adding: [String],
        removing: [String],
        defaults: UserDefaults
    ) {
        lock.lock()
        defer { lock.unlock() }
        var values = Set(defaults.stringArray(forKey: key) ?? [])
        values.formUnion(adding.filter(isManaged))
        values.subtract(removing)
        if values.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(values.sorted(), forKey: key)
        }
    }

    private static func recoverQueue(
        key: String,
        referencedRefs: Set<String>,
        limitedTo: Set<String>?,
        directory: URL?,
        defaults: UserDefaults,
        removeItem: (URL) throws -> Void
    ) {
        let resolvedDirectory: URL
        do {
            resolvedDirectory = try directory ?? ChekiImageRefResolver.chekiImagesDirectory()
        } catch {
            return
        }
        lock.lock()
        let queued = Set(defaults.stringArray(forKey: key) ?? [])
        lock.unlock()
        var remaining = queued
        for ref in queued where limitedTo?.contains(ref) ?? true {
            guard isManaged(ref) else {
                remaining.remove(ref)
                continue
            }
            guard !referencedRefs.contains(ref) else {
                remaining.remove(ref)
                continue
            }
            let url = resolvedDirectory.appendingPathComponent(ref)
            guard FileManager.default.fileExists(atPath: url.path) else {
                remaining.remove(ref)
                continue
            }
            guard ChekiImageRefResolver.isRegularReadableFile(url) else { continue }
            do {
                try removeItem(url)
                remaining.remove(ref)
            } catch {
                continue
            }
        }
        lock.lock()
        var current = Set(defaults.stringArray(forKey: key) ?? [])
        current.subtract(queued.subtracting(remaining))
        if current.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(current.sorted(), forKey: key)
        }
        lock.unlock()
    }
}

enum ChekinanaEventAvatarStore {

    static func save(_ data: Data, eventID: UUID) async throws -> String {
        let filename = "event-avatar-\(eventID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        ChekinanaEventMediaJournal.recordPending(filename)
        do {
            guard let jpeg = await ChekinanaImageWorker.downsampledJPEGData(
                from: data,
                maxDimension: 512,
                compressionQuality: 0.9
            ), !jpeg.isEmpty else {
                throw ChekinanaProductMediaError.unreadableImage
            }
            let directory = try ChekiImageRefResolver.chekiImagesDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: directory.appendingPathComponent(filename), options: .atomic)
            return filename
        } catch {
            ChekinanaEventMediaJournal.discardPending([filename])
            throw error
        }
    }

    static func downloadAndSave(_ rawURL: String, eventID: UUID) async throws -> String {
        guard let url = trustedRemoteURL(rawURL) else {
            throw ChekinanaProductMediaError.unreadableImage
        }
        let data = try await ChekinanaEventRemoteImageDownloader.shared.data(for: url)
        return try await save(data, eventID: eventID)
    }

#if DEBUG
    static func saveUIFixtureAvatar(eventID: UUID) async throws -> String {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 96, height: 96),
            format: format
        ).image { context in
            UIColor(red: 0.94, green: 0.92, blue: 0.97, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            UIColor(red: 0.31, green: 0.20, blue: 0.48, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 24, y: 18, width: 48, height: 48))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw ChekinanaProductMediaError.unreadableImage
        }
        return try await save(data, eventID: eventID)
    }
#endif

    static func trustedRemoteURL(_ rawURL: String) -> URL? {
        ChekinanaEventRemoteImagePolicy.trustedURL(rawURL)
    }

    static func image(for ref: String?) -> UIImage? {
        guard let ref, isManaged(ref),
              let url = ChekiImageRefResolver.managedLocalFileURL(for: ref) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func remove(_ ref: String?) {
        guard let ref, isManaged(ref) else { return }
        ChekinanaEventMediaJournal.discardPending([ref])
    }

    static func isManaged(_ ref: String) -> Bool {
        ref.lowercased().hasPrefix("event-avatar-")
            && ChekinanaEventMediaJournal.isManaged(ref)
    }
}

enum ChekinanaEventImageStore {
    static let maximumImageCount = 12
    static let maximumConcurrentDownloads = 3
    private static let maximumImageBytes = 8 * 1_024 * 1_024

    typealias RemoteFetcher = @Sendable (URL) async throws -> Data
    typealias StagedObserver = @Sendable (Int, String) async -> Void

    static func save(_ data: Data, eventID: UUID) async throws -> String {
        let filename = "event-image-\(eventID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        ChekinanaEventMediaJournal.recordPending(filename)
        do {
            guard data.count <= maximumImageBytes,
                  let jpeg = await ChekinanaImageWorker.downsampledJPEGData(
                    from: data,
                    maxDimension: 2_048,
                    compressionQuality: 0.9
                  ), !jpeg.isEmpty else {
                throw ChekinanaProductMediaError.unreadableImage
            }
            let directory = try ChekiImageRefResolver.chekiImagesDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: directory.appendingPathComponent(filename), options: .atomic)
            return filename
        } catch {
            ChekinanaEventMediaJournal.discardPending([filename])
            throw error
        }
    }

    static func stageRemoteImages(
        _ rawURLs: [String],
        eventID: UUID,
        fetch: @escaping RemoteFetcher = fetchRemoteImage,
        onStaged: @escaping StagedObserver = { _, _ in }
    ) async throws -> [String?] {
        let boundedURLs = Array(rawURLs.prefix(maximumImageCount))
        var orderedRefs = Array<String?>(repeating: nil, count: boundedURLs.count)
        do {
            for start in stride(
                from: 0,
                to: boundedURLs.count,
                by: maximumConcurrentDownloads
            ) {
                try Task.checkCancellation()
                let end = min(start + maximumConcurrentDownloads, boundedURLs.count)
                await withTaskGroup(of: (Int, String?).self) { group in
                    for index in start..<end {
                        guard let url = ChekinanaEventAvatarStore.trustedRemoteURL(
                            boundedURLs[index]
                        ) else { continue }
                        group.addTask {
                            do {
                                let data = try await fetch(url)
                                try Task.checkCancellation()
                                return (index, try await save(data, eventID: eventID))
                            } catch {
                                return (index, nil)
                            }
                        }
                    }
                    for await (index, ref) in group {
                        orderedRefs[index] = ref
                        if let ref { await onStaged(index, ref) }
                    }
                }
            }
            try Task.checkCancellation()
            return orderedRefs
        } catch {
            remove(orderedRefs.compactMap { $0 })
            throw error
        }
    }

    static func image(for ref: String) -> UIImage? {
        guard isManaged(ref),
              let url = ChekiImageRefResolver.managedLocalFileURL(for: ref) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func remove(_ refs: [String]) {
        ChekinanaEventMediaJournal.discardPending(refs.filter(isManaged))
    }

    static func isManaged(_ ref: String) -> Bool {
        ref == URL(fileURLWithPath: ref).lastPathComponent
            && ref.range(
                of: #"^event-image-[0-9a-f-]{36}-[0-9a-f-]{36}\.jpg$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
    }

    private static func fetchRemoteImage(_ url: URL) async throws -> Data {
        try await ChekinanaEventRemoteImageDownloader.shared.data(for: url)
    }
}

struct ChekinanaEventImageValue: Equatable, Sendable {
    let id: UUID?
    let imageRef: String
}

@MainActor
enum ChekinanaEventPersistence {
    enum PersistenceError: Error {
        case invalidImages
    }

    static func images(
        for eventID: UUID,
        in modelContext: ModelContext
    ) throws -> [EventImage] {
        try modelContext.fetch(FetchDescriptor<EventImage>(
            predicate: #Predicate { $0.eventID == eventID },
            sortBy: [SortDescriptor(\EventImage.sortOrder)]
        ))
    }

    static func save(
        _ event: Event,
        images values: [ChekinanaEventImageValue],
        previousAvatarRef: String?,
        in modelContext: ModelContext,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let refs = values.map(\.imageRef)
        guard values.count <= ChekinanaEventImageStore.maximumImageCount,
              Set(refs).count == refs.count,
              refs.allSatisfy(ChekinanaEventImageStore.isManaged) else {
            throw PersistenceError.invalidImages
        }
        let existing = try images(for: event.id, in: modelContext)
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var retainedIDs = Set<UUID>()
        for (sortOrder, value) in values.enumerated() {
            if let id = value.id,
               let record = existingByID[id],
               record.eventID == event.id {
                record.imageRef = value.imageRef
                record.sortOrder = sortOrder
                retainedIDs.insert(id)
            } else {
                let record = EventImage(
                    eventID: event.id,
                    imageRef: value.imageRef,
                    sortOrder: sortOrder
                )
                modelContext.insert(record)
                retainedIDs.insert(record.id)
            }
        }
        for record in existing where !retainedIDs.contains(record.id) {
            modelContext.delete(record)
        }

        let retainedRefs = Set(refs)
        var deletionRefs = existing.map(\.imageRef).filter { !retainedRefs.contains($0) }
        if let previousAvatarRef,
           previousAvatarRef != event.avatarImageRef,
           ChekinanaEventAvatarStore.isManaged(previousAvatarRef) {
            deletionRefs.append(previousAvatarRef)
        }
        ChekinanaEventMediaJournal.queueDeletion(deletionRefs)
        do {
            try saveContext(modelContext)
        } catch {
            modelContext.rollback()
            ChekinanaEventMediaJournal.cancelDeletion(deletionRefs)
            throw error
        }
        ChekinanaEventMediaJournal.clearPending(
            refs + [event.avatarImageRef].compactMap { $0 }
        )
        try? ChekinanaEventMediaJournal.recover(modelContext: modelContext)
    }

    static func delete(
        _ event: Event,
        from modelContext: ModelContext,
        saveContext: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let records = try images(for: event.id, in: modelContext)
        let deletionRefs = records.map(\.imageRef)
            + [event.avatarImageRef].compactMap { $0 }
        ChekinanaEventMediaJournal.queueDeletion(deletionRefs)
        records.forEach(modelContext.delete)
        modelContext.delete(event)
        do {
            try saveContext(modelContext)
        } catch {
            modelContext.rollback()
            ChekinanaEventMediaJournal.cancelDeletion(deletionRefs)
            throw error
        }
        try? ChekinanaEventMediaJournal.recover(modelContext: modelContext)
    }
}

private struct ChekinanaEventAvatar: View {
    let event: Event
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image = ChekinanaEventAvatarStore.image(for: event.avatarImageRef) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(ChekinanaProductTheme.softAccent)
                    if let initial = event.name.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).first {
                        Text(String(initial).uppercased())
                            .font(.system(size: size * 0.38, weight: .semibold))
                            .foregroundStyle(ChekinanaProductTheme.accent)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct ChekinanaEventRemoteAvatarPreview: View {
    let rawURL: String
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["CHEKINANA_EVENT_CANDIDATE_UI_STUB"]
            == "fixture" {
            ZStack {
                Circle().fill(ChekinanaProductTheme.softAccent)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(ChekinanaProductTheme.accent)
            }
        } else {
            remoteImage
        }
#else
        remoteImage
#endif
    }

    private var remoteImage: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if didFail {
                ZStack {
                    Circle().fill(ChekinanaProductTheme.softAccent)
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Circle().fill(ChekinanaProductTheme.softAccent)
                    ProgressView()
                }
            }
        }
        .task(id: rawURL) {
            image = nil
            didFail = false
            guard let url = ChekinanaEventAvatarStore.trustedRemoteURL(rawURL) else {
                didFail = true
                return
            }
            do {
                let data = try await ChekinanaEventRemoteImageDownloader.shared.data(for: url)
                guard !Task.isCancelled,
                      let jpeg = await ChekinanaImageWorker.downsampledJPEGData(
                        from: data,
                        maxDimension: 256,
                        compressionQuality: 0.85
                      ), let decoded = UIImage(data: jpeg) else {
                    didFail = true
                    return
                }
                image = decoded
            } catch is CancellationError {
                return
            } catch {
                didFail = true
            }
        }
    }
}

private struct ChekinanaEventsView: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Query(sort: \Event.date) private var events: [Event]
    let openMenu: () -> Void
    @State private var isAdding = false
    @State private var selectedEvent: Event?
    @State private var page = ChekinanaEventListPage.upcoming
    @State private var sortsAscending = true
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared

    private func visibleChekis(_ event: Event) -> [Cheki] {
        event.chekis.filter {
            ChekinanaVisibilityPolicy.includesRecord(
                idols: $0.idols,
                hiddenIDs: hiddenIdols.hiddenIDs
            )
        }
    }

    private func ordered(_ values: [Event]) -> [Event] {
        let dated = values.filter { $0.date != nil }.sorted { lhs, rhs in
            guard let left = lhs.date, let right = rhs.date else { return false }
            if left != right { return sortsAscending ? left < right : left > right }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return dated + values.filter { $0.date == nil }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private var future: [Event] {
        ordered(events.filter { ($0.date ?? .distantPast) >= ChekinanaProductDate.today })
    }
    private var past: [Event] {
        ordered(events.filter { $0.date != nil && ($0.date ?? .distantFuture) < ChekinanaProductDate.today })
    }
    private var undated: [Event] { ordered(events.filter { $0.date == nil }) }
    private var currentPageIsEmpty: Bool {
        switch page {
        case .upcoming:
            future.isEmpty
        case .past:
            past.isEmpty && undated.isEmpty
        }
    }

    private func count(for value: ChekinanaEventListPage) -> Int {
        switch value {
        case .upcoming: future.count
        case .past: past.count + undated.count
        }
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            VStack(spacing: 0) {
                Picker(ChekinanaProductCopy.text("events.title", "Events"), selection: $page) {
                    ForEach(ChekinanaEventListPage.allCases) { value in
                        Text(
                            ChekinanaProductCopy.format(
                                "events.segment_count",
                                "%1$@ %2$lld",
                                value.title,
                                Int64(count(for: value))
                            )
                        )
                            .tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("chekinana.events.page-picker")

                if currentPageIsEmpty {
                    ChekinanaEmptyState(
                        title: page == .upcoming
                            ? ChekinanaProductCopy.text("events.empty.upcoming", "No Upcoming Events")
                            : ChekinanaProductCopy.text("events.empty.past", "No Past Events"),
                        message: page == .upcoming
                            ? ChekinanaProductCopy.text("events.empty.upcoming.detail", "Paste a public Weibo link to fill details, or enter them manually.")
                            : ChekinanaProductCopy.text("events.empty.past.detail", "Past and legacy undated Events appear here."),
                        systemImage: "ticket",
                        actionTitle: ChekinanaProductCopy.text("events.add", "Add Event"),
                        action: { isAdding = true }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .chekinanaScreenMarker("chekinana.events.\(page.rawValue.lowercased()).empty")
                } else {
                    List {
                        if page == .upcoming {
                            eventSection(ChekinanaProductCopy.text("events.upcoming", "Upcoming"), events: future)
                        } else {
                            eventSection(ChekinanaProductCopy.text("events.past", "Past"), events: past)
                            eventSection(ChekinanaProductCopy.text("events.undated", "Undated"), events: undated)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .chekinanaGroupedPageBackground()
                }
            }
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle(ChekinanaProductCopy.text("events.title", "Events"))
            .toolbar {
                ChekinanaPageToolbar(pageID: "events", openMenu: openMenu)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sortsAscending.toggle() } label: { Image(systemName: sortsAscending ? "arrow.up" : "arrow.down") }
                        .frame(width: 44, height: 44)
                        .accessibilityLabel(
                            ChekinanaProductCopy.text("events.sort", "Sort Events")
                        )
                        .accessibilityValue(
                            sortsAscending
                                ? ChekinanaProductCopy.text(
                                    "events.sort.ascending",
                                    "Oldest first"
                                )
                                : ChekinanaProductCopy.text(
                                    "events.sort.descending",
                                    "Newest first"
                                )
                        )
                        .accessibilityIdentifier("chekinana.events.sort")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAdding = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                        .accessibilityLabel(ChekinanaProductCopy.text("events.add", "Add Event"))
                        .accessibilityIdentifier("chekinana.events.add")
                }
            }
            .sheet(isPresented: $isAdding) { ChekinanaEventEditorView(event: nil) }
            .sheet(item: $selectedEvent) { ChekinanaEventDetailView(event: $0) }
        }
        .accessibilityIdentifier("chekinana.events.page")
        .chekinanaScreenMarker("chekinana.events.page")
    }

    @ViewBuilder
    private func eventSection(_ title: String, events values: [Event]) -> some View {
        if !values.isEmpty {
            Section(title) {
                ForEach(values) { event in
                    Button { selectedEvent = event } label: {
                        HStack(spacing: 12) {
                            ChekinanaEventAvatar(event: event)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text([
                                    event.date.map(ChekinanaProductDate.displayString),
                                    event.city?.nonEmpty,
                                    event.resolvedLivehouse,
                                ].compactMap { $0 }.joined(separator: " · ").nonEmpty
                                    ?? ChekinanaProductCopy.text("events.no_date_venue", "No date or venue"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer()
                            Text(ChekinanaRecordKind.cheki.countLabel(visibleChekis(event).count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .frame(height: 68)
                        .padding(.horizontal, 12)
                        .background(ChekinanaDesignSystem.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: ChekinanaDesignSystem.compactRadius))
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: ChekinanaDesignSystem.compactRadius,
                                style: .continuous
                            )
                            .stroke(ChekinanaProductTheme.border, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("chekinana.events.card.\(event.id.uuidString.lowercased())")
                }
            }
        }
    }
}

private struct ChekinanaEventDetailView: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var eventImages: [EventImage]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let event: Event
    @State private var isEditing = false
    @State private var selectedChekiGroup: ChekinanaEventChekiOrdering.GroupKey?
    @State private var selectedCheki: Cheki?
    @State private var message: String?
    @State private var isEditingNote = false
    @State private var selectedEventImage: ChekinanaEventImageViewerSelection?
    @State private var noteDraft = ""
    @FocusState private var isNoteFocused: Bool

    init(event: Event) {
        self.event = event
        let eventID = event.id
        _eventImages = Query(
            filter: #Predicate<EventImage> { $0.eventID == eventID },
            sort: \EventImage.sortOrder
        )
    }

    private var visibleChekis: [Cheki] {
        ChekinanaEventChekiOrdering.ordered(
            event.chekis,
            hiddenIDs: hiddenIdols.hiddenIDs
        )
    }

    private var chekiGroups: [ChekinanaEventChekiOrdering.Group] {
        ChekinanaEventChekiOrdering.groups(
            event.chekis,
            hiddenIDs: hiddenIdols.hiddenIDs
        )
    }

    private var selectedGroup: ChekinanaEventChekiOrdering.Group? {
        guard let selectedChekiGroup else { return nil }
        return chekiGroups.first { $0.key == selectedChekiGroup }
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            if let selectedCheki {
                ChekinanaGalleryDetailView(
                    cheki: selectedCheki,
                    onClose: { self.selectedCheki = nil }
                )
            } else if let group = selectedGroup {
                ChekinanaEventChekiGroupView(
                    group: group,
                    selectCheki: { selectedCheki = $0 },
                    onBack: { selectedChekiGroup = nil }
                )
            } else {
                List {
                Section {
                    ChekinanaSectionCard {
                        HStack(spacing: 16) {
                            ChekinanaEventAvatar(event: event, size: 76)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(event.name)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.primary)
                                Text(ChekinanaProductDate.displayString(event.date))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(ChekinanaProductTheme.accent)
                                Text(
                                    [event.city?.nonEmpty, event.resolvedLivehouse]
                                        .compactMap { $0 }
                                        .joined(separator: " · ")
                                        .nonEmpty
                                        ?? ChekinanaProductCopy.text(
                                            "events.no_date_venue",
                                            "No date or venue"
                                        )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section(ChekinanaProductCopy.text("events.details", "Details")) {
                    if let city = event.city?.nonEmpty {
                        LabeledContent(
                            ChekinanaProductCopy.text("events.city", "City"),
                            value: city
                        )
                    }
                    if let livehouse = event.resolvedLivehouse {
                        LabeledContent(
                            ChekinanaProductCopy.text("events.livehouse", "Livehouse"),
                            value: livehouse
                        )
                    }
                    if let price = event.price?.nonEmpty {
                        LabeledContent(
                            ChekinanaProductCopy.text("events.price", "Price"),
                            value: price
                        )
                    }
                    if let url = event.weiboURL {
                        Link(
                            ChekinanaProductCopy.text("events.open_weibo", "Open Weibo"),
                            destination: url
                        )
                    }
                    if let url = event.ticketURL {
                        Link(
                            ChekinanaProductCopy.text(
                                "events.open_ticket",
                                "Open ticket page"
                            ),
                            destination: url
                        )
                    }
                    if isEditingNote {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ChekinanaProductCopy.text("common.note", "Note"))
                                .font(.subheadline.weight(.semibold))
                            TextEditor(text: $noteDraft)
                                .frame(minHeight: 86)
                                .focused($isNoteFocused)
                                .accessibilityIdentifier("chekinana.events.detail.note.editor")
                            HStack {
                                Button(ChekinanaProductCopy.text("common.cancel", "Cancel")) {
                                    isEditingNote = false
                                    isNoteFocused = false
                                }
                                Spacer()
                                Button(ChekinanaProductCopy.text("common.save", "Save")) {
                                    saveNote()
                                }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("chekinana.events.detail.note.save")
                            }
                        }
                    } else {
                        Button {
                            noteDraft = event.note
                            isEditingNote = true
                            isNoteFocused = true
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(ChekinanaProductCopy.text("common.note", "Note"))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 12)
                                Text(
                                    event.note.nonEmpty
                                        ?? ChekinanaProductCopy.text(
                                            "common.add_note",
                                            "Add note"
                                        )
                                )
                                    .foregroundStyle(event.note.isEmpty ? .blue : .primary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chekinana.events.detail.note")
                    }
                }
                if !eventImages.isEmpty {
                    Section(ChekinanaProductCopy.text("events.images", "Images")) {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(Array(eventImages.enumerated()), id: \.element.id) { index, record in
                                    Button {
                                        selectedEventImage = .init(id: record.id)
                                    } label: {
                                        ChekinanaEventImageThumbnail(record: record)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        ChekinanaProductCopy.format(
                                            "events.image_number",
                                            "Event image %lld",
                                            Int64(index + 1)
                                        )
                                    )
                                    .accessibilityHint(ChekinanaProductCopy.text(
                                        "events.image.open_hint",
                                        "Open this image full screen"
                                    ))
                                    .accessibilityIdentifier(
                                        "chekinana.events.detail.image.\(record.id.uuidString.lowercased())"
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollIndicators(.hidden)
                        Text(
                            ChekinanaProductCopy.text(
                                "events.images.edit_hint",
                                "Use Edit to add or remove Event images."
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section(ChekinanaRecordKind.cheki.countLabel(visibleChekis.count)) {
                    if visibleChekis.isEmpty {
                        Text(
                            ChekinanaProductCopy.text(
                                "events.no_linked_cheki",
                                "No linked Cheki"
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                    ForEach(chekiGroups) { group in
                        Button { selectedChekiGroup = group.key } label: {
                            HStack(spacing: 12) {
                                ChekinanaIdolAvatarRow(
                                    idols: group.idols,
                                    size: 36,
                                    showsNames: true
                                )
                                Spacer(minLength: 8)
                                Text(eventChekiGroupCount(group.chekis.count))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ChekinanaProductCopy.format(
                            "events.cheki_group_accessibility",
                            "%1$@, %2$@",
                            group.idols.map(\.name).joined(separator: " · ").nonEmpty
                                ?? ChekinanaProductCopy.text("common.unassigned", "Unassigned"),
                            eventChekiGroupCount(group.chekis.count)
                        ))
                        .accessibilityIdentifier(
                            "chekinana.events.detail.cheki-group.\(group.key.stableIdentifier)"
                        )
                    }
                }
            }
            .chekinanaGroupedPageBackground()
            .navigationTitle(ChekinanaProductCopy.text("events.event", "Event"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaProductCopy.text("common.done", "Done")) { dismiss() }
                        .accessibilityIdentifier("chekinana.events.detail.done")
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button(ChekinanaProductCopy.text("common.edit", "Edit")) { isEditing = true }
                        .accessibilityIdentifier("chekinana.events.detail.edit")
                    Button(role: .destructive) { deleteEvent() } label: { Image(systemName: "trash") }
                        .accessibilityIdentifier("chekinana.events.detail.delete")
                }
            }
            .sheet(isPresented: $isEditing) { ChekinanaEventEditorView(event: event) }
            .fullScreenCover(item: $selectedEventImage) { selection in
                ChekinanaEventImageViewer(
                    images: eventImages,
                    initialID: selection.id
                )
            }
            .alert(ChekinanaProductCopy.text("events.event", "Event"), isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button(ChekinanaProductCopy.text("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .chekinanaScreenMarker("chekinana.events.detail")
            .onChange(of: chekiGroups.map(\.key)) { _, keys in
                if let selectedChekiGroup, !keys.contains(selectedChekiGroup) {
                    self.selectedChekiGroup = nil
                }
                if let selectedCheki,
                   !visibleChekis.contains(where: { $0.id == selectedCheki.id }) {
                    self.selectedCheki = nil
                }
            }
        }
    }
    }

    private func eventChekiGroupCount(_ count: Int) -> String {
        ChekinanaProductCopy.quantity(
            "events.cheki_group_count",
            count: count,
            one: "%lld Cheki",
            other: "%lld chekis"
        )
    }

    private func deleteEvent() {
        guard event.chekis.isEmpty else {
            message = ChekinanaProductCopy.format(
                "events.delete_linked_error",
                "This Event has %lld linked Cheki. Reassign them before deleting.",
                Int64(event.chekis.count)
            )
            return
        }
        do {
            try ChekinanaEventPersistence.delete(event, from: modelContext)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveNote() {
        event.note = noteDraft
        event.updatedAt = Date()
        do {
            try modelContext.save()
            isEditingNote = false
            isNoteFocused = false
        } catch {
            modelContext.rollback()
            noteDraft = event.note
            message = error.localizedDescription
        }
    }
}

private struct ChekinanaEventChekiGroupView: View {
    let group: ChekinanaEventChekiOrdering.Group
    let selectCheki: (Cheki) -> Void
    let onBack: () -> Void

    private var title: String {
        group.idols.map(\.name).joined(separator: " · ").nonEmpty
            ?? ChekinanaProductCopy.text("common.unassigned", "Unassigned")
    }

    var body: some View {
        List {
            Section {
                ForEach(group.chekis) { cheki in
                    Button { selectCheki(cheki) } label: {
                        HStack(spacing: 12) {
                            ChekinanaCalendarThumbnail(cheki: cheki)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(
                                    "\(ChekinanaProductDate.displayString(cheki.date))"
                                        + (cheki.idx.map { " · #\($0)" } ?? "")
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "chekinana.events.detail.cheki.\(cheki.id.uuidString.lowercased())"
                    )
                }
            }
        }
        .chekinanaGroupedPageBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(ChekinanaProductCopy.text("common.back", "Back"), action: onBack)
                    .accessibilityIdentifier("chekinana.events.detail.cheki-group.back")
            }
        }
        .accessibilityIdentifier(
            "chekinana.events.detail.cheki-group.\(group.key.stableIdentifier).list"
        )
    }
}

private struct ChekinanaEventImageViewerSelection: Identifiable {
    let id: UUID
}

private struct ChekinanaEventImageThumbnail: View {
    let record: EventImage

    var body: some View {
        Group {
            if let image = ChekinanaEventImageStore.image(for: record.imageRef) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                    Text(ChekinanaProductCopy.text(
                        "events.image.unavailable",
                        "Image unavailable"
                    ))
                    .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.08))
            }
        }
        .frame(width: 220, height: 164)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct ChekinanaEventImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let images: [EventImage]
    @State private var selectedID: UUID

    init(images: [EventImage], initialID: UUID) {
        self.images = images
        _selectedID = State(initialValue: initialID)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if images.isEmpty {
                ChekinanaEmptyState(
                    title: ChekinanaProductCopy.text(
                        "events.image.unavailable",
                        "Image unavailable"
                    ),
                    message: "",
                    systemImage: "photo.badge.exclamationmark"
                )
            } else {
                TabView(selection: $selectedID) {
                    ForEach(images) { record in
                        ChekinanaEventZoomableImage(record: record)
                            .tag(record.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
                .accessibilityIdentifier("chekinana.events.image-viewer.pages")
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ChekinanaProductCopy.text("common.close", "Close"))
            .accessibilityIdentifier("chekinana.events.image-viewer.close")
            .padding(16)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 36).onEnded { value in
            guard abs(value.translation.height) > abs(value.translation.width),
                  value.translation.height > 100 else { return }
            dismiss()
        })
        .accessibilityIdentifier("chekinana.events.image-viewer")
    }
}

private struct ChekinanaEventZoomableImage: View {
    let record: EventImage
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1

    var body: some View {
        Group {
            if let image = ChekinanaEventImageStore.image(for: record.imageRef) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * gestureScale)
                    .gesture(MagnifyGesture()
                        .onChanged { value in
                            gestureScale = min(4 / scale, max(1 / scale, value.magnification))
                        }
                        .onEnded { value in
                            scale = min(4, max(1, scale * value.magnification))
                            gestureScale = 1
                        }
                    )
            } else {
                ContentUnavailableView(
                    ChekinanaProductCopy.text(
                        "events.image.unavailable",
                        "Image unavailable"
                    ),
                    systemImage: "photo.badge.exclamationmark"
                )
                .foregroundStyle(.white)
            }
        }
        .padding(12)
        .accessibilityIdentifier(
            "chekinana.events.image-viewer.image.\(record.id.uuidString.lowercased())"
        )
    }
}

private struct ChekinanaEventImageDraft: Identifiable, Equatable {
    enum Origin: Equatable {
        case existing(recordID: UUID)
        case parsed(generation: UInt64, index: Int)
        case photoLibrary
    }

    let id = UUID()
    let ref: String
    let origin: Origin

    var isNew: Bool {
        guard case .existing = origin else { return true }
        return false
    }

    var recordID: UUID? {
        guard case .existing(let recordID) = origin else { return nil }
        return recordID
    }

    var parsedMetadata: (generation: UInt64, index: Int)? {
        guard case .parsed(let generation, let index) = origin else { return nil }
        return (generation, index)
    }
}

struct ChekinanaEventSaveGate: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var inFlightToken: UInt64?

    var isInFlight: Bool { inFlightToken != nil }

    mutating func begin() -> UInt64? {
        guard inFlightToken == nil else { return nil }
        generation &+= 1
        inFlightToken = generation
        return generation
    }

    func accepts(_ token: UInt64, isCancelled: Bool = false) -> Bool {
        !isCancelled && inFlightToken == token && generation == token
    }

    @discardableResult
    mutating func finish(_ token: UInt64) -> Bool {
        guard accepts(token) else { return false }
        inFlightToken = nil
        return true
    }

    mutating func cancelIfIdle() -> Bool {
        guard inFlightToken == nil else { return false }
        generation &+= 1
        return true
    }
}

private struct ChekinanaEventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let event: Event?

    @State private var sourceURL = ""
    @State private var name: String
    @State private var date: Date
    @State private var city: String
    @State private var livehouse: String
    @State private var price: String
    @State private var weiboURL: String
    @State private var ticketURL: String
    @State private var note: String
    @State private var isExtracting = false
    @State private var saveGate = ChekinanaEventSaveGate()
    @State private var saveTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var extractionTask: Task<Void, Never>?
    @State private var extractionGate = ChekinanaEventCandidateExtractionGate()
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var avatarImportTask: Task<Void, Never>?
    @State private var isImportingAvatar = false
    @State private var selectedAvatarData: Data?
    @State private var parsedAvatarURL = ""
    @State private var clearsAvatar = false
    @State private var imageDrafts: [ChekinanaEventImageDraft]
    @State private var imagePickerItems: [PhotosPickerItem] = []
    @State private var imageImportTask: Task<Void, Never>?
    @State private var isImportingImages = false
    @State private var didLoadImages = false
    @State private var isLoadingImages = false
    @State private var didCommit = false
    private let draftEventID: UUID
    @FocusState private var focusedSource: SourceField?

    private enum SourceField: Hashable {
        case weiboURL
    }

    private var isSaving: Bool { saveGate.isInFlight }

    init(event: Event?) {
        self.event = event
        draftEventID = event?.id ?? UUID()
        _name = State(initialValue: event?.name ?? "")
        _date = State(initialValue: event?.date.flatMap {
            ChekinanaDateOnly.displayDate(from: $0, calendar: .current)
        } ?? Date())
        _city = State(initialValue: event?.city ?? "")
        _livehouse = State(initialValue: event?.resolvedLivehouse ?? "")
        _price = State(initialValue: event?.price ?? "")
        _weiboURL = State(initialValue: event?.weiboURL?.absoluteString ?? "")
        _ticketURL = State(initialValue: event?.ticketURL?.absoluteString ?? "")
        _note = State(initialValue: event?.note ?? "")
        _imageDrafts = State(initialValue: [])
    }

    var body: some View {
        NavigationStack {
            Form {
                if event == nil {
                    Section(
                        ChekinanaProductCopy.text(
                            "events.weibo_import",
                            "Fill from public Weibo"
                        )
                    ) {
                        ZStack(alignment: .leading) {
                            TextField("", text: $sourceURL)
                                .textInputAutocapitalization(.never).keyboardType(.URL)
                                .focused($focusedSource, equals: .weiboURL)
                                .disabled(isExtracting)
                                .accessibilityIdentifier("chekinana.events.editor.weibo-source")
                            if sourceURL.isEmpty {
                                Button(
                                    ChekinanaProductCopy.text(
                                        "events.paste_weibo",
                                        "Paste Weibo URL"
                                    )
                                ) {
                                    pasteWeiboURL()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                                .accessibilityIdentifier("chekinana.events.editor.weibo-paste")
                            }
                        }
                        Button { startExtraction() } label: {
                            if isExtracting {
                                Label(
                                    ChekinanaProductCopy.text(
                                        "events.parsing_weibo",
                                        "Parsing Weibo…"
                                    ),
                                    systemImage: "hourglass"
                                )
                            } else {
                                Label(
                                    ChekinanaProductCopy.text(
                                        "events.parse_weibo",
                                        "Parse Weibo URL"
                                    ),
                                    systemImage: "wand.and.stars"
                                )
                            }
                        }
                        .frame(minHeight: 44)
                        .disabled(sourceURL.isEmpty || isExtracting || isImportingImages)
                        .accessibilityIdentifier("chekinana.events.editor.extract")
                    }
                }
                Section(ChekinanaProductCopy.text("events.event", "Event")) {
                    HStack(spacing: 14) {
                        Group {
                            if let selectedAvatarData,
                               let image = UIImage(data: selectedAvatarData) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else if !clearsAvatar, !parsedAvatarURL.isEmpty {
                                ChekinanaEventRemoteAvatarPreview(
                                    rawURL: parsedAvatarURL
                                )
                            } else if !clearsAvatar,
                                      let event {
                                ChekinanaEventAvatar(event: event, size: 62)
                            } else {
                                Circle().fill(ChekinanaProductTheme.softAccent)
                            }
                        }
                        .frame(width: 62, height: 62)
                        .clipShape(Circle())
                        .accessibilityIdentifier("chekinana.events.editor.avatar-preview")
                        .accessibilityValue(
                            !parsedAvatarURL.isEmpty
                                ? ChekinanaProductCopy.text(
                                    "events.avatar.parsed",
                                    "Parsed Weibo author avatar"
                                )
                                : (selectedAvatarData != nil
                                    ? ChekinanaProductCopy.text(
                                        "events.avatar.selected",
                                        "Selected avatar"
                                    )
                                    : ChekinanaProductCopy.text(
                                        "events.avatar.none",
                                        "No parsed avatar"
                                    ))
                        )
                        PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                            Text(
                                ChekinanaProductCopy.text(
                                    "events.avatar.choose",
                                    "Choose or replace avatar"
                                )
                            )
                        }
                        Spacer()
                        if selectedAvatarData != nil || event?.avatarImageRef != nil || !parsedAvatarURL.isEmpty {
                            Button(
                                ChekinanaProductCopy.text("common.clear", "Clear"),
                                role: .destructive
                            ) {
                                selectedAvatarData = nil
                                parsedAvatarURL = ""
                                avatarPickerItem = nil
                                clearsAvatar = true
                            }
                        }
                    }
                    TextField(ChekinanaProductCopy.text("events.name", "Name"), text: $name)
                        .accessibilityIdentifier("chekinana.events.editor.name")
                    DatePicker(
                        ChekinanaProductCopy.text("common.date", "Date"),
                        selection: $date,
                        displayedComponents: .date
                    )
                        .accessibilityIdentifier("chekinana.events.editor.date")
                    TextField(ChekinanaProductCopy.text("events.city", "City"), text: $city)
                        .accessibilityIdentifier("chekinana.events.editor.city")
                    TextField(
                        ChekinanaProductCopy.text("events.livehouse", "Livehouse"),
                        text: $livehouse
                    )
                        .accessibilityIdentifier("chekinana.events.editor.livehouse")
                    TextField(ChekinanaProductCopy.text("events.price", "Price"), text: $price)
                        .accessibilityIdentifier("chekinana.events.editor.price")
                    TextField(
                        ChekinanaProductCopy.text("events.weibo_url", "Weibo URL"),
                        text: $weiboURL
                    )
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        .accessibilityIdentifier("chekinana.events.editor.weibo-url")
                    TextField(
                        ChekinanaProductCopy.text("events.ticket_url", "Ticket URL"),
                        text: $ticketURL
                    )
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        .accessibilityIdentifier("chekinana.events.editor.ticket-url")
                    TextField(
                        ChekinanaProductCopy.text("common.note", "Note"),
                        text: $note,
                        axis: .vertical
                    )
                        .accessibilityIdentifier("chekinana.events.editor.note")
                }
                Section(ChekinanaProductCopy.text("events.images", "Event images")) {
                    if imageDrafts.isEmpty {
                        Text(
                            ChekinanaProductCopy.text(
                                "events.images.empty",
                                "No Event images"
                            )
                        )
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chekinana.events.editor.images.empty")
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(Array(imageDrafts.enumerated()), id: \.element.id) { index, draft in
                                    if let image = ChekinanaEventImageStore.image(for: draft.ref) {
                                        ZStack(alignment: .topTrailing) {
                                            Image(uiImage: image)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 136, height: 102)
                                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                            Button(role: .destructive) {
                                                removeImage(draft)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, Color.black.opacity(0.65))
                                                    .font(.title3)
                                            }
                                            .accessibilityLabel(
                                                ChekinanaProductCopy.format(
                                                    "events.image_remove_number",
                                                    "Remove Event image %lld",
                                                    Int64(index + 1)
                                                )
                                            )
                                            .accessibilityIdentifier("chekinana.events.editor.image.remove.\(index)")
                                            .padding(6)
                                        }
                                        .accessibilityIdentifier("chekinana.events.editor.image.\(index)")
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollIndicators(.hidden)
                    }
                    PhotosPicker(
                        selection: $imagePickerItems,
                        maxSelectionCount: ChekinanaEventImageStore.maximumImageCount,
                        matching: .images
                    ) {
                        Label(
                            ChekinanaProductCopy.text(
                                "events.images.add_photos",
                                "Add from Photos"
                            ),
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }
                    .disabled(
                        isImportingImages
                            || isExtracting
                            || imageDrafts.count >= ChekinanaEventImageStore.maximumImageCount
                    )
                    .accessibilityIdentifier("chekinana.events.editor.images.add")
                }
                if isLoadingImages || isImportingImages || isImportingAvatar {
                    Section {
                        ChekinanaInlineStatus(
                            message: ChekinanaProductCopy.text(
                                "events.media_preparing",
                                "Preparing Event media…"
                            ),
                            kind: .loading
                        )
                    }
                }
                if let errorMessage {
                    Section { ChekinanaInlineStatus(message: errorMessage, kind: .error) }
                }
            }
            .disabled(isSaving)
            .chekinanaGroupedPageBackground()
            .navigationTitle(event == nil
                ? ChekinanaProductCopy.text("events.add", "Add Event")
                : ChekinanaProductCopy.text("events.edit", "Edit Event"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaProductCopy.text("common.cancel", "Cancel")) {
                        guard saveGate.cancelIfIdle() else { return }
                        cancelPendingWork()
                        discardUncommittedImages()
                        dismiss()
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("chekinana.events.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChekinanaProductCopy.text("common.save", "Save")) { startSave() }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isSaving
                                || isExtracting
                                || isImportingImages
                                || isImportingAvatar
                                || isLoadingImages
                        )
                        .accessibilityIdentifier("chekinana.events.editor.save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { loadExistingImagesIfNeeded() }
        .onChange(of: avatarPickerItem) { _, item in
            guard let item else { return }
            avatarImportTask?.cancel()
            isImportingAvatar = true
            avatarImportTask = Task { @MainActor in
                defer {
                    isImportingAvatar = false
                    avatarImportTask = nil
                }
                if let transfer = try? await item.loadTransferable(
                    type: ChekinanaProductTransferableImage.self
                ), !Task.isCancelled {
                    selectedAvatarData = transfer.data
                    parsedAvatarURL = ""
                    clearsAvatar = false
                }
            }
        }
        .onChange(of: imagePickerItems) { _, items in
            guard !items.isEmpty else { return }
            startPhotoImport(items)
        }
        .onDisappear {
            guard !isSaving else { return }
            _ = saveGate.cancelIfIdle()
            cancelPendingWork()
            if !didCommit { discardUncommittedImages() }
        }
        .accessibilityIdentifier("chekinana.events.editor")
    }

    @MainActor
    private func startExtraction() {
        cancelExtraction()
        focusedSource = nil
        let requestedURL = sourceURL
        let generation = extractionGate.begin()
        isExtracting = true
        errorMessage = nil
        extractionTask = Task { @MainActor in
            defer {
                if extractionGate.accepts(generation, isCancelled: false) {
                    isExtracting = false
                    extractionTask = nil
                }
            }
            do {
                let client = ChekinanaEventCandidateClient()
                let candidate = try await client.fetch(weiboURL: requestedURL)
                guard extractionGate.accepts(generation, isCancelled: Task.isCancelled),
                      sourceURL == requestedURL else {
                    return
                }
                apply(candidate)
                await stageParsedImages(candidate.imageUrls, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard extractionGate.accepts(generation, isCancelled: Task.isCancelled),
                      sourceURL == requestedURL else {
                    return
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func pasteWeiboURL() {
        if let pasted = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pasted.isEmpty {
            sourceURL = pasted
        }
        focusedSource = .weiboURL
    }

    @MainActor
    private func cancelExtraction() {
        extractionGate.invalidate()
        extractionTask?.cancel()
        extractionTask = nil
        isExtracting = false
    }

    @MainActor
    private func cancelPendingWork() {
        cancelExtraction()
        imageImportTask?.cancel()
        imageImportTask = nil
        isImportingImages = false
        avatarImportTask?.cancel()
        avatarImportTask = nil
        isImportingAvatar = false
    }

    private func apply(_ candidate: ChekinanaEventCandidateFields) {
        name = candidate.name
        city = candidate.city
        livehouse = candidate.livehouse
        price = candidate.price
        weiboURL = candidate.weiboURL
        ticketURL = candidate.ticketURL
        parsedAvatarURL = candidate.avatarURL
        if !parsedAvatarURL.isEmpty { clearsAvatar = false }
        if let parsed = ChekinanaDateOnly.parse(candidate.date),
           let displayed = ChekinanaDateOnly.displayDate(from: parsed, calendar: .current) {
            date = displayed
        }
    }

    @MainActor
    private func stageParsedImages(_ rawURLs: [String], generation: UInt64) async {
        let priorParsed = imageDrafts.filter { $0.parsedMetadata != nil }
        imageDrafts.removeAll { $0.parsedMetadata != nil }
        ChekinanaEventImageStore.remove(priorParsed.map(\.ref))
        guard !rawURLs.isEmpty else {
            errorMessage = nil
            return
        }
        do {
            let staged = try await ChekinanaEventImageStore.stageRemoteImages(
                rawURLs,
                eventID: draftEventID,
                onStaged: { index, ref in
                    await MainActor.run {
                        guard extractionGate.accepts(
                            generation,
                            isCancelled: Task.isCancelled
                        ), imageDrafts.count < ChekinanaEventImageStore.maximumImageCount else {
                            return
                        }
                        imageDrafts.append(.init(
                            ref: ref,
                            origin: .parsed(generation: generation, index: index)
                        ))
                        let otherDrafts = imageDrafts.filter {
                            $0.parsedMetadata?.generation != generation
                        }
                        let currentParsed = imageDrafts.filter {
                            $0.parsedMetadata?.generation == generation
                        }.sorted {
                            ($0.parsedMetadata?.index ?? 0) < ($1.parsedMetadata?.index ?? 0)
                        }
                        imageDrafts = otherDrafts + currentParsed
                    }
                }
            )
            let stagedRefs = staged.compactMap { $0 }
            guard extractionGate.accepts(generation, isCancelled: Task.isCancelled) else {
                ChekinanaEventImageStore.remove(stagedRefs)
                imageDrafts.removeAll { $0.parsedMetadata?.generation == generation }
                return
            }
            let acceptedRefs = Set(imageDrafts.compactMap { draft in
                draft.parsedMetadata?.generation == generation ? draft.ref : nil
            })
            ChekinanaEventImageStore.remove(stagedRefs.filter { !acceptedRefs.contains($0) })
            let failedCount = staged.count - acceptedRefs.count
            errorMessage = failedCount > 0
                ? ChekinanaProductCopy.format(
                    "events.images.partial",
                    "Loaded %1$lld Event images; %2$lld could not be loaded. You can still edit and save this Event.",
                    Int64(acceptedRefs.count),
                    Int64(failedCount)
                )
                : nil
        } catch is CancellationError {
            let cancelledRefs = imageDrafts.compactMap { draft in
                draft.parsedMetadata?.generation == generation ? draft.ref : nil
            }
            imageDrafts.removeAll { $0.parsedMetadata?.generation == generation }
            ChekinanaEventImageStore.remove(cancelledRefs)
            return
        } catch {
            let failedRefs = imageDrafts.compactMap { draft in
                draft.parsedMetadata?.generation == generation ? draft.ref : nil
            }
            imageDrafts.removeAll { $0.parsedMetadata?.generation == generation }
            ChekinanaEventImageStore.remove(failedRefs)
            errorMessage = ChekinanaProductCopy.text(
                "events.images.parse_failed",
                "Event fields were parsed, but images could not be loaded. You can still edit and save this Event."
            )
        }
    }

    @MainActor
    private func startPhotoImport(_ items: [PhotosPickerItem]) {
        imageImportTask?.cancel()
        isImportingImages = true
        let capacity = max(
            0,
            ChekinanaEventImageStore.maximumImageCount - imageDrafts.count
        )
        let acceptedItems = Array(items.prefix(capacity))
        imageImportTask = Task { @MainActor in
            var failureCount = items.count - acceptedItems.count
            defer {
                isImportingImages = false
                imageImportTask = nil
                imagePickerItems = []
            }
            for item in acceptedItems {
                guard !Task.isCancelled else { return }
                do {
                    guard let transfer = try await item.loadTransferable(
                        type: ChekinanaProductTransferableImage.self
                    ) else {
                        failureCount += 1
                        continue
                    }
                    let ref = try await ChekinanaEventImageStore.save(
                        transfer.data,
                        eventID: draftEventID
                    )
                    guard !Task.isCancelled else {
                        ChekinanaEventImageStore.remove([ref])
                        return
                    }
                    imageDrafts.append(.init(ref: ref, origin: .photoLibrary))
                } catch is CancellationError {
                    return
                } catch {
                    failureCount += 1
                }
            }
            if failureCount > 0 {
                errorMessage = ChekinanaProductCopy.text(
                    "events.images.selection_failed",
                    "Some selected images could not be added. Other images and Event fields were kept."
                )
            }
        }
    }

    @MainActor
    private func removeImage(_ draft: ChekinanaEventImageDraft) {
        imageDrafts.removeAll { $0.id == draft.id }
        if draft.isNew { ChekinanaEventImageStore.remove([draft.ref]) }
    }

    @MainActor
    private func discardUncommittedImages() {
        ChekinanaEventImageStore.remove(imageDrafts.filter(\.isNew).map(\.ref))
        imageDrafts.removeAll(keepingCapacity: false)
        if let event {
            imageDrafts = (try? ChekinanaEventPersistence.images(
                for: event.id,
                in: modelContext
            ))?.compactMap { record in
                guard ChekinanaEventImageStore.isManaged(record.imageRef) else { return nil }
                return .init(
                    ref: record.imageRef,
                    origin: .existing(recordID: record.id)
                )
            } ?? []
        }
    }

    @MainActor
    private func loadExistingImagesIfNeeded() {
        guard !didLoadImages else { return }
        didLoadImages = true
        guard let event else { return }
        isLoadingImages = true
        defer { isLoadingImages = false }
        do {
            imageDrafts = try ChekinanaEventPersistence.images(
                for: event.id,
                in: modelContext
            ).compactMap { record in
                guard ChekinanaEventImageStore.isManaged(record.imageRef) else { return nil }
                return .init(
                    ref: record.imageRef,
                    origin: .existing(recordID: record.id)
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func startSave() {
        guard let token = saveGate.begin() else { return }
        saveTask = Task { @MainActor in
            await save(token: token)
            if saveGate.finish(token) { saveTask = nil }
        }
    }

    @MainActor
    private func save(token: UInt64) async {
        guard saveGate.accepts(token, isCancelled: Task.isCancelled) else { return }
        guard let selectedDate = ChekinanaDateOnly.canonicalDate(
            from: date,
            displayedIn: .current
        ) else {
            errorMessage = ChekinanaProductCopy.text(
                "error.read_date",
                "Unable to read the selected date. Choose it again."
            )
            return
        }
        let dateText = ChekinanaDateOnly.string(selectedDate)
        let fields = ChekinanaEventCandidateFields(
            name: name,
            date: dateText,
            city: city,
            livehouse: livehouse,
            price: price,
            avatarURL: parsedAvatarURL,
            imageUrls: [],
            weiboURL: weiboURL,
            ticketURL: ticketURL,
            note: note
        )
        let blockers = ChekinanaEventCandidateValidator.blockers(for: fields).filter {
            !(weiboURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 == .invalidWeiboURL)
        }
        guard blockers.isEmpty else {
            errorMessage = blockers.map(\.message).joined(separator: "\n")
            return
        }
        let target = event ?? Event(id: draftEventID, name: name)
        let previousAvatarRef = target.avatarImageRef
        var stagedAvatarRef: String?
        do {
            if let selectedAvatarData {
                stagedAvatarRef = try await ChekinanaEventAvatarStore.save(
                    selectedAvatarData,
                    eventID: target.id
                )
            } else if event == nil, !parsedAvatarURL.isEmpty {
#if DEBUG
                if ProcessInfo.processInfo.environment["CHEKINANA_EVENT_CANDIDATE_UI_STUB"]
                    == "fixture" {
                    stagedAvatarRef = try await ChekinanaEventAvatarStore
                        .saveUIFixtureAvatar(eventID: target.id)
                } else {
                    stagedAvatarRef = try await ChekinanaEventAvatarStore.downloadAndSave(
                        parsedAvatarURL,
                        eventID: target.id
                    )
                }
#else
                stagedAvatarRef = try await ChekinanaEventAvatarStore.downloadAndSave(
                    parsedAvatarURL,
                    eventID: target.id
                )
#endif
            }
        } catch {
            discardUncommittedImages()
            errorMessage = ChekinanaProductCopy.format(
                "events.avatar.save_failed",
                "Unable to save Event avatar. %@",
                error.localizedDescription
            )
            return
        }
        guard saveGate.accepts(token, isCancelled: Task.isCancelled) else {
            ChekinanaEventAvatarStore.remove(stagedAvatarRef)
            discardUncommittedImages()
            return
        }
        if event == nil { modelContext.insert(target) }
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.date = selectedDate
        target.city = city.nonEmpty
        target.livehouse = livehouse.nonEmpty
        target.legacyVenue = nil
        target.price = price.nonEmpty
        if clearsAvatar {
            target.avatarImageRef = nil
        } else if let stagedAvatarRef {
            target.avatarImageRef = stagedAvatarRef
        }
        target.weiboURL = weiboURL.nonEmpty.flatMap(URL.init(string:))
        target.ticketURL = ticketURL.nonEmpty.flatMap(URL.init(string:))
        target.note = note
        target.updatedAt = Date()
        do {
            guard saveGate.accepts(token, isCancelled: Task.isCancelled) else {
                modelContext.rollback()
                ChekinanaEventAvatarStore.remove(stagedAvatarRef)
                discardUncommittedImages()
                return
            }
            try ChekinanaEventPersistence.save(
                target,
                images: imageDrafts.map {
                    ChekinanaEventImageValue(id: $0.recordID, imageRef: $0.ref)
                },
                previousAvatarRef: previousAvatarRef,
                in: modelContext
            )
            didCommit = true
            cancelExtraction()
            dismiss()
        } catch {
            modelContext.rollback()
            ChekinanaEventAvatarStore.remove(stagedAvatarRef)
            discardUncommittedImages()
            errorMessage = error.localizedDescription
        }
    }

}

enum ChekinanaGalleryMediaKind: String, Sendable {
    case shame
    case douga
}

enum ChekinanaGalleryMediaStoreError: LocalizedError {
    case invalidMedia
    case missingManagedFile
    case thumbnailFailed
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case .invalidMedia:
            "The selected media is unavailable or invalid."
        case .missingManagedFile:
            "The app-managed media file is unavailable."
        case .thumbnailFailed:
            "A stable video thumbnail could not be generated."
        case .fileOperation(let detail):
            "The managed media file could not be updated: \(detail)"
        }
    }
}

enum ChekinanaGalleryMediaStore {
    private static let maximumImageBytes = 64 * 1_024 * 1_024
    private static let maximumVideoBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let cleanupQueueKey = "ChekinanaGalleryCommittedDeletionQueue"
    private static let restoreQueueKey = "ChekinanaGalleryRestoreRecoveryQueue"
    private static let orphanQueueKey = "ChekinanaGalleryOrphanCleanupQueue"

    private struct RestoreEntry: Codable, Hashable {
        let original: String
        let quarantine: String
    }

    static func performFileIO<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: priority, operation: operation).value
    }

    static func saveImage(
        _ data: Data,
        id: UUID,
        filenameExtension: String,
        directory: URL? = nil
    ) throws -> String {
        guard !data.isEmpty,
              data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              ChekinanaImageSourceValidator.accepts(
                source: source,
                maxDimension: ChekinanaImageSourceValidator.maximumThumbnailDimension
              ) else {
            throw ChekinanaGalleryMediaStoreError.invalidMedia
        }
        let ext = normalizedImageExtension(filenameExtension)
        let filename = "shame-\(id.uuidString.lowercased()).\(ext)"
        let destination = try resolvedDirectory(directory)
            .appendingPathComponent(filename, isDirectory: false)
        do {
            try data.write(to: destination, options: [.atomic])
            return filename
        } catch {
            throw ChekinanaGalleryMediaStoreError.fileOperation(error.localizedDescription)
        }
    }

    static func makeStagedImageCopy(
        from data: Data,
        filenameExtension: String
    ) async throws -> URL {
        try await performFileIO {
            guard !data.isEmpty,
                  data.count <= maximumImageBytes,
                  let source = CGImageSourceCreateWithData(
                    data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                  ),
                  ChekinanaImageSourceValidator.accepts(
                    source: source,
                    maxDimension: ChekinanaImageSourceValidator.maximumThumbnailDimension
                  ) else {
                throw ChekinanaGalleryMediaStoreError.invalidMedia
            }
            let directory = try stagingDirectory()
            let ext = normalizedImageExtension(filenameExtension)
            let destination = directory.appendingPathComponent(
                "\(UUID().uuidString.lowercased()).\(ext)"
            )
            do {
                try data.write(to: destination, options: [.atomic])
                return destination
            } catch {
                throw ChekinanaGalleryMediaStoreError.fileOperation(
                    error.localizedDescription
                )
            }
        }
    }

    static func saveImage(
        from stagedURL: URL,
        id: UUID,
        filenameExtension: String,
        directory: URL? = nil
    ) async throws -> String {
        try await performFileIO {
            guard isOwnedStagedImport(stagedURL),
                  ChekiImageRefResolver.isRegularReadableFile(stagedURL),
                  let size = try? stagedURL.resourceValues(
                    forKeys: [.fileSizeKey]
                  ).fileSize,
                  size > 0,
                  size <= maximumImageBytes,
                  let source = CGImageSourceCreateWithURL(
                    stagedURL as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                  ),
                  ChekinanaImageSourceValidator.accepts(
                    source: source,
                    maxDimension: ChekinanaImageSourceValidator.maximumThumbnailDimension
                  ) else {
                throw ChekinanaGalleryMediaStoreError.invalidMedia
            }
            let ext = normalizedImageExtension(filenameExtension)
            let filename = "shame-\(id.uuidString.lowercased()).\(ext)"
            let destination = try resolvedDirectory(directory)
                .appendingPathComponent(filename, isDirectory: false)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: stagedURL, to: destination)
                return filename
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw ChekinanaGalleryMediaStoreError.fileOperation(
                    error.localizedDescription
                )
            }
        }
    }

    static func saveVideo(
        from stagedURL: URL,
        id: UUID,
        directory: URL? = nil
    ) async throws -> String {
        try await performFileIO {
            guard isOwnedStagedImport(stagedURL),
                  ChekiImageRefResolver.isRegularReadableFile(stagedURL),
                  let size = try? stagedURL.resourceValues(
                    forKeys: [.fileSizeKey]
                  ).fileSize,
                  size > 0,
                  Int64(size) <= maximumVideoBytes else {
                throw ChekinanaGalleryMediaStoreError.invalidMedia
            }
            let ext = normalizedVideoExtension(stagedURL.pathExtension)
            let resolvedDirectory = try resolvedDirectory(directory)
            let filename = "douga-\(id.uuidString.lowercased()).\(ext)"
            let destination = resolvedDirectory.appendingPathComponent(filename)
            let thumbnail = thumbnailURL(id: id, directory: resolvedDirectory)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: stagedURL, to: destination)
                guard let thumbnailData = videoThumbnailDataSynchronously(
                    at: destination
                ) else {
                    try? FileManager.default.removeItem(at: destination)
                    throw ChekinanaGalleryMediaStoreError.thumbnailFailed
                }
                try thumbnailData.write(to: thumbnail, options: [.atomic])
                return filename
            } catch let error as ChekinanaGalleryMediaStoreError {
                throw error
            } catch {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: thumbnail)
                throw ChekinanaGalleryMediaStoreError.fileOperation(
                    error.localizedDescription
                )
            }
        }
    }

    static func managedURL(
        for reference: String?,
        id: UUID,
        kind: ChekinanaGalleryMediaKind,
        directory: URL? = nil
    ) -> URL? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              reference == URL(fileURLWithPath: reference).lastPathComponent,
              reference != ".",
              reference != ".." else { return nil }
        let expectedStem = "\(kind.rawValue)-\(id.uuidString.lowercased())"
        guard URL(fileURLWithPath: reference).deletingPathExtension().lastPathComponent
            == expectedStem,
              let resolvedDirectory = try? resolvedDirectory(directory) else { return nil }
        let candidate = resolvedDirectory.appendingPathComponent(reference)
        return ChekiImageRefResolver.isRegularReadableFile(candidate) ? candidate : nil
    }

    static func thumbnailURL(
        id: UUID,
        directory: URL? = nil
    ) -> URL {
        let resolved = (try? resolvedDirectory(directory)) ?? directory
            ?? FileManager.default.temporaryDirectory
        return resolved.appendingPathComponent(
            "douga-thumb-\(id.uuidString.lowercased()).jpg"
        )
    }

    static func thumbnailReference(id: UUID, directory: URL? = nil) -> String? {
        let url = thumbnailURL(id: id, directory: directory)
        return ChekiImageRefResolver.isRegularReadableFile(url) ? url.lastPathComponent : nil
    }

    static func removeFiles(
        kind: ChekinanaGalleryMediaKind,
        id: UUID,
        reference: String?,
        directory: URL? = nil,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        let resolvedDirectory = try resolvedDirectory(directory)
        var urls: [URL] = []
        if let media = managedURL(
            for: reference,
            id: id,
            kind: kind,
            directory: resolvedDirectory
        ) {
            urls.append(media)
        }
        if kind == .douga {
            let thumbnail = thumbnailURL(id: id, directory: resolvedDirectory)
            if ChekiImageRefResolver.isRegularReadableFile(thumbnail) {
                urls.append(thumbnail)
            }
        }
        for url in urls {
            try removeItem(url)
        }
    }

    static func removeFilesInBackground(
        kind: ChekinanaGalleryMediaKind,
        id: UUID,
        reference: String?,
        directory: URL? = nil
    ) async throws {
        try await performFileIO(priority: .utility) {
            try removeFiles(
                kind: kind,
                id: id,
                reference: reference,
                directory: directory
            )
        }
    }

    static func removeAllManagedMediaFiles(directory: URL? = nil) throws {
        let resolvedDirectory = try resolvedDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(
            at: resolvedDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("shame-")
                    || name.hasPrefix("douga-")
                    || name.hasPrefix("douga-thumb-")
                    || name.hasPrefix(".delete-") else { continue }
            let values = try entry.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: entry)
        }
    }

    static func stageFilesForDeletion(
        kind: ChekinanaGalleryMediaKind,
        id: UUID,
        reference: String?,
        directory: URL? = nil
    ) throws -> [(original: URL, quarantine: URL)] {
        let resolvedDirectory = try resolvedDirectory(directory)
        var originals: [URL] = []
        if let media = managedURL(
            for: reference,
            id: id,
            kind: kind,
            directory: resolvedDirectory
        ) {
            originals.append(media)
        }
        if kind == .douga {
            let thumbnail = thumbnailURL(id: id, directory: resolvedDirectory)
            if ChekiImageRefResolver.isRegularReadableFile(thumbnail) {
                originals.append(thumbnail)
            }
        }
        var staged: [(URL, URL)] = []
        do {
            for original in originals {
                let quarantine = resolvedDirectory.appendingPathComponent(
                    ".delete-\(UUID().uuidString.lowercased())-\(original.lastPathComponent)"
                )
                try FileManager.default.moveItem(at: original, to: quarantine)
                staged.append((original, quarantine))
            }
            return staged
        } catch {
            for pair in staged.reversed() {
                try? FileManager.default.moveItem(at: pair.1, to: pair.0)
            }
            throw ChekinanaGalleryMediaStoreError.fileOperation(error.localizedDescription)
        }
    }

    static func restoreStagedFiles(
        _ files: [(original: URL, quarantine: URL)],
        moveItem: (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
    ) throws {
        for pair in files.reversed() where FileManager.default.fileExists(atPath: pair.quarantine.path) {
            try moveItem(pair.quarantine, pair.original)
        }
    }

    static func finalizeStagedDeletion(_ files: [(original: URL, quarantine: URL)]) throws {
        for pair in files where FileManager.default.fileExists(atPath: pair.quarantine.path) {
            try FileManager.default.removeItem(at: pair.quarantine)
        }
        removeCommittedDeletion(files)
    }

    static func recordCommittedDeletion(
        _ files: [(original: URL, quarantine: URL)],
        directory: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard let resolvedDirectory = try? resolvedDirectory(directory) else { return }
        let restoring = Set(restoreEntries(defaults: defaults).map(\.quarantine))
        let additions = files.compactMap { pair -> String? in
            guard pair.original.deletingLastPathComponent().standardizedFileURL == resolvedDirectory,
                  pair.quarantine.deletingLastPathComponent().standardizedFileURL == resolvedDirectory,
                  validRestoreEntry(
                    RestoreEntry(
                        original: pair.original.lastPathComponent,
                        quarantine: pair.quarantine.lastPathComponent
                    )
                  ),
                  !restoring.contains(pair.quarantine.lastPathComponent) else { return nil }
            return pair.quarantine.lastPathComponent
        }
        guard !additions.isEmpty else { return }
        let existing = defaults.stringArray(forKey: cleanupQueueKey) ?? []
        defaults.set(Array(Set(existing + additions)).sorted(), forKey: cleanupQueueKey)
    }

    static func recordRestoreRecovery(
        _ files: [(original: URL, quarantine: URL)],
        directory: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard let resolvedDirectory = try? resolvedDirectory(directory) else { return }
        let additions = files.compactMap { pair -> RestoreEntry? in
            guard pair.original.deletingLastPathComponent().standardizedFileURL == resolvedDirectory,
                  pair.quarantine.deletingLastPathComponent().standardizedFileURL == resolvedDirectory else {
                return nil
            }
            let entry = RestoreEntry(
                original: pair.original.lastPathComponent,
                quarantine: pair.quarantine.lastPathComponent
            )
            return validRestoreEntry(entry) ? entry : nil
        }
        guard !additions.isEmpty else { return }
        let merged = Array(Set(restoreEntries(defaults: defaults) + additions)).sorted {
            $0.quarantine < $1.quarantine
        }
        setRestoreEntries(merged, defaults: defaults)
        let restoring = Set(merged.map(\.quarantine))
        let committed = defaults.stringArray(forKey: cleanupQueueKey) ?? []
        defaults.set(committed.filter { !restoring.contains($0) }, forKey: cleanupQueueKey)
    }

    static func removeRestoreRecovery(
        _ files: [(original: URL, quarantine: URL)],
        defaults: UserDefaults = .standard
    ) {
        let removed = Set(files.map(\.quarantine.lastPathComponent))
        setRestoreEntries(
            restoreEntries(defaults: defaults).filter { !removed.contains($0.quarantine) },
            defaults: defaults
        )
    }

    @discardableResult
    static func cleanupRestoreRecoveries(
        directory: URL? = nil,
        defaults: UserDefaults = .standard,
        moveItem: (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
    ) -> Bool {
        guard let resolvedDirectory = try? resolvedDirectory(directory) else { return false }
        var remaining: [RestoreEntry] = []
        for entry in restoreEntries(defaults: defaults) where validRestoreEntry(entry) {
            let original = resolvedDirectory.appendingPathComponent(entry.original)
            let quarantine = resolvedDirectory.appendingPathComponent(entry.quarantine)
            let originalExists = FileManager.default.fileExists(atPath: original.path)
            let quarantineExists = FileManager.default.fileExists(atPath: quarantine.path)
            if originalExists, !quarantineExists,
               ChekiImageRefResolver.isRegularReadableFile(original) {
                continue
            }
            guard !originalExists, quarantineExists,
                  ChekiImageRefResolver.isRegularReadableFile(quarantine) else {
                remaining.append(entry)
                continue
            }
            do {
                try moveItem(quarantine, original)
                guard ChekiImageRefResolver.isRegularReadableFile(original) else {
                    remaining.append(entry)
                    continue
                }
            } catch {
                remaining.append(entry)
            }
        }
        setRestoreEntries(remaining, defaults: defaults)
        return remaining.isEmpty
    }

    static func restoreRecoveryFiles(
        kind: ChekinanaGalleryMediaKind,
        id: UUID,
        reference: String?,
        directory: URL? = nil,
        defaults: UserDefaults = .standard
    ) -> [(original: URL, quarantine: URL)] {
        guard let resolvedDirectory = try? resolvedDirectory(directory) else { return [] }
        let expected = Set(managedFilenames(kind: kind, id: id, reference: reference))
        return restoreEntries(defaults: defaults).compactMap { entry in
            guard validRestoreEntry(entry), expected.contains(entry.original) else { return nil }
            return (
                resolvedDirectory.appendingPathComponent(entry.original),
                resolvedDirectory.appendingPathComponent(entry.quarantine)
            )
        }
    }

    static func pendingRestoreRecoveryCount(defaults: UserDefaults = .standard) -> Int {
        restoreEntries(defaults: defaults).count
    }

    static func recordOrphanedImport(
        kind: ChekinanaGalleryMediaKind,
        id: UUID,
        reference: String?,
        defaults: UserDefaults = .standard
    ) {
        let additions = managedFilenames(kind: kind, id: id, reference: reference)
        guard !additions.isEmpty else { return }
        let existing = defaults.stringArray(forKey: orphanQueueKey) ?? []
        defaults.set(Array(Set(existing + additions)).sorted(), forKey: orphanQueueKey)
    }

    static func cleanupOrphanedImports(
        directory: URL? = nil,
        defaults: UserDefaults = .standard,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        guard let resolvedDirectory = try? resolvedDirectory(directory) else { return }
        let restoringOriginals = Set(restoreEntries(defaults: defaults).map(\.original))
        var remaining: [String] = []
        for filename in defaults.stringArray(forKey: orphanQueueKey) ?? [] {
            guard isManagedFilename(filename), !restoringOriginals.contains(filename) else {
                if restoringOriginals.contains(filename) { remaining.append(filename) }
                continue
            }
            let url = resolvedDirectory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard ChekiImageRefResolver.isRegularReadableFile(url) else { continue }
            do {
                try removeItem(url)
            } catch {
                remaining.append(filename)
            }
        }
        if remaining.isEmpty {
            defaults.removeObject(forKey: orphanQueueKey)
        } else {
            defaults.set(remaining, forKey: orphanQueueKey)
        }
    }

    static func pendingOrphanCleanupCount(defaults: UserDefaults = .standard) -> Int {
        defaults.stringArray(forKey: orphanQueueKey)?.count ?? 0
    }

    static func reconcileQueuesAfterFullClear(
        failedFilenames: Set<String>?,
        defaults: UserDefaults = .standard
    ) {
        let restores = restoreEntries(defaults: defaults)
        var committed = Set(defaults.stringArray(forKey: cleanupQueueKey) ?? [])
        var orphans = Set(defaults.stringArray(forKey: orphanQueueKey) ?? [])
        committed.formUnion(restores.map(\.quarantine))
        orphans.formUnion(restores.map(\.original))

        if let failedFilenames {
            committed = Set(committed.filter(failedFilenames.contains))
            orphans = Set(orphans.filter(failedFilenames.contains))
            for filename in failedFilenames {
                if isManagedFilename(filename) {
                    orphans.insert(filename)
                } else if validQuarantineFilename(filename) {
                    committed.insert(filename)
                }
            }
        }

        defaults.removeObject(forKey: restoreQueueKey)
        if committed.isEmpty {
            defaults.removeObject(forKey: cleanupQueueKey)
        } else {
            defaults.set(committed.sorted(), forKey: cleanupQueueKey)
        }
        if orphans.isEmpty {
            defaults.removeObject(forKey: orphanQueueKey)
        } else {
            defaults.set(orphans.sorted(), forKey: orphanQueueKey)
        }
    }

    static func cleanupCommittedDeletions(
        directory: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard let resolvedDirectory = try? resolvedDirectory(directory) else { return }
        let queued = defaults.stringArray(forKey: cleanupQueueKey) ?? []
        let restoring = Set(restoreEntries(defaults: defaults).map(\.quarantine))
        var remaining: [String] = []
        for filename in queued {
            guard filename.hasPrefix(".delete-"),
                  filename == URL(fileURLWithPath: filename).lastPathComponent,
                  !restoring.contains(filename) else {
                continue
            }
            let url = resolvedDirectory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    continue
                }
                try FileManager.default.removeItem(at: url)
            } catch {
                remaining.append(filename)
            }
        }
        if remaining.isEmpty {
            defaults.removeObject(forKey: cleanupQueueKey)
        } else {
            defaults.set(remaining, forKey: cleanupQueueKey)
        }
    }

    static func makeStagedVideoCopy(from source: URL) throws -> URL {
        try makeStagedVideoCopy(
            from: source,
            fileSize: {
                Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) }
        )
    }

    static func makeStagedVideoCopy(
        from source: URL,
        fileSize: (URL) throws -> Int64,
        copyItem: (URL, URL) throws -> Void
    ) throws -> URL {
        guard ChekiImageRefResolver.isRegularReadableFile(source) else {
            throw ChekinanaGalleryMediaStoreError.invalidMedia
        }
        let size = try fileSize(source)
        guard size > 0, size <= maximumVideoBytes else {
            throw ChekinanaGalleryMediaStoreError.invalidMedia
        }
        let stagingDirectory = try stagingDirectory()
        let ext = normalizedVideoExtension(source.pathExtension)
        let destination = stagingDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).\(ext)"
        )
        try copyItem(source, destination)
        return destination
    }

    static func discardStagedVideo(at url: URL?) {
        guard let url, isOwnedStagedImport(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func discardStagedImport(at url: URL?) async {
        try? await performFileIO(priority: .utility) {
            discardStagedVideo(at: url)
        }
    }

    static func cleanupStagedImports() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekinanaGalleryImports", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        for entry in entries {
            guard let values = try? entry.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func restoreEntries(defaults: UserDefaults) -> [RestoreEntry] {
        guard let data = defaults.data(forKey: restoreQueueKey),
              let decoded = try? JSONDecoder().decode([RestoreEntry].self, from: data) else {
            return []
        }
        return decoded.filter(validRestoreEntry)
    }

    private static func setRestoreEntries(
        _ entries: [RestoreEntry],
        defaults: UserDefaults
    ) {
        guard !entries.isEmpty,
              let data = try? JSONEncoder().encode(entries) else {
            defaults.removeObject(forKey: restoreQueueKey)
            return
        }
        defaults.set(data, forKey: restoreQueueKey)
    }

    private static func validRestoreEntry(_ entry: RestoreEntry) -> Bool {
        guard isManagedFilename(entry.original),
              entry.original == URL(fileURLWithPath: entry.original).lastPathComponent,
              entry.quarantine == URL(fileURLWithPath: entry.quarantine).lastPathComponent,
              entry.quarantine.hasPrefix(".delete-") else { return false }
        let suffix = "-\(entry.original)"
        guard entry.quarantine.hasSuffix(suffix) else { return false }
        let start = entry.quarantine.index(
            entry.quarantine.startIndex,
            offsetBy: ".delete-".count
        )
        let end = entry.quarantine.index(entry.quarantine.endIndex, offsetBy: -suffix.count)
        return start < end && UUID(uuidString: String(entry.quarantine[start..<end])) != nil
    }

    private static func validQuarantineFilename(_ filename: String) -> Bool {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasPrefix(".delete-") else { return false }
        let remainder = String(filename.dropFirst(".delete-".count))
        guard remainder.count > 37 else { return false }
        let uuidText = String(remainder.prefix(36))
        guard UUID(uuidString: uuidText) != nil,
              remainder[remainder.index(remainder.startIndex, offsetBy: 36)] == "-" else {
            return false
        }
        let original = String(remainder.dropFirst(37))
        return isManagedFilename(original)
    }

    private static func managedFilenames(
        kind: ChekinanaGalleryMediaKind,
        id: UUID,
        reference: String?
    ) -> [String] {
        var values: [String] = []
        if let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
           reference == URL(fileURLWithPath: reference).lastPathComponent,
           URL(fileURLWithPath: reference).deletingPathExtension().lastPathComponent
            == "\(kind.rawValue)-\(id.uuidString.lowercased())",
           isManagedFilename(reference) {
            values.append(reference)
        }
        if kind == .douga {
            values.append("douga-thumb-\(id.uuidString.lowercased()).jpg")
        }
        return values
    }

    private static func isManagedFilename(_ filename: String) -> Bool {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent else { return false }
        let lowercased = filename.lowercased()
        let patterns = [
            #"^shame-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|heic)$"#,
            #"^douga-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(mov|m4v|mp4)$"#,
            #"^douga-thumb-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$"#,
        ]
        return patterns.contains {
            lowercased.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func removeCommittedDeletion(
        _ files: [(original: URL, quarantine: URL)],
        defaults: UserDefaults = .standard
    ) {
        let removed = Set(files.map(\.quarantine.lastPathComponent))
        let existing = defaults.stringArray(forKey: cleanupQueueKey) ?? []
        let remaining = existing.filter { !removed.contains($0) }
        if remaining.isEmpty {
            defaults.removeObject(forKey: cleanupQueueKey)
        } else {
            defaults.set(remaining, forKey: cleanupQueueKey)
        }
    }

    private static func resolvedDirectory(_ directory: URL?) throws -> URL {
        let resolved = try directory ?? ChekiImageRefResolver.chekiImagesDirectory()
        try FileManager.default.createDirectory(
            at: resolved,
            withIntermediateDirectories: true
        )
        return resolved.standardizedFileURL
    }

    private static func normalizedImageExtension(_ value: String) -> String {
        switch value.lowercased() {
        case "png": "png"
        case "heic", "heif": "heic"
        default: "jpg"
        }
    }

    private static func normalizedVideoExtension(_ value: String) -> String {
        switch value.lowercased() {
        case "mov": "mov"
        case "m4v": "m4v"
        default: "mp4"
        }
    }

    private static func stagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekinanaGalleryImports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.standardizedFileURL
    }

    private static func isOwnedStagedImport(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().lastPathComponent
            == "ChekinanaGalleryImports"
    }

    private static func videoThumbnailDataSynchronously(at url: URL) -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_200, height: 1_200)
        guard let image = try? generator.copyCGImage(
            at: CMTime(seconds: 0, preferredTimescale: 600),
            actualTime: nil
        ) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
    }
}

private enum ChekinanaGalleryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    var id: String { rawValue }
}

enum ChekinanaGalleryShotTypeFilter: String, CaseIterable, Identifiable {
    case all
    case solo
    case twoShot = "two-shot"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: ChekinanaProductCopy.text("gallery.shot_filter.all", "All")
        case .solo: "solo"
        case .twoShot: "2-shot"
        }
    }

    func includes(_ userAppears: Bool?) -> Bool {
        switch self {
        case .all: true
        case .solo: userAppears == false
        case .twoShot: userAppears == true
        }
    }
}

enum ChekinanaGalleryItem: Identifiable {
    case cheki(Cheki)
    case shame(Shame)
    case douga(Douga)

    var id: String {
        "\(kind.rawValue)-\(modelID.uuidString.lowercased())"
    }

    var modelID: UUID {
        switch self {
        case .cheki(let value): value.id
        case .shame(let value): value.id
        case .douga(let value): value.id
        }
    }

    var typeName: String {
        kind.title
    }

    var kind: ChekinanaRecordKind {
        switch self {
        case .cheki: .cheki
        case .shame: .shame
        case .douga: .douga
        }
    }

    var date: Date? {
        switch self {
        case .cheki(let value): value.date
        case .shame(let value): value.date
        case .douga(let value): value.date
        }
    }

    var idols: [Idol] {
        switch self {
        case .cheki(let value): value.idols
        case .shame(let value): value.idols
        case .douga(let value): value.idols
        }
    }

    var event: Event? {
        switch self {
        case .cheki(let value): return value.event
        case .shame, .douga: return nil
        }
    }

    var note: String {
        switch self {
        case .cheki(let value): value.note
        case .shame(let value): value.note
        case .douga(let value): value.note
        }
    }

    var isFavoriteCheki: Bool {
        if case .cheki(let value) = self { return value.isFavorite }
        return false
    }

    var chekiUserAppears: Bool? {
        if case .cheki(let value) = self { return value.userAppears }
        return nil
    }

    var hasMedia: Bool {
        switch self {
        case .cheki(let value): value.imageRef?.nonEmpty != nil
        case .shame(let value): value.imageRef?.nonEmpty != nil
        case .douga(let value): value.videoRef?.nonEmpty != nil
        }
    }

    func matches(query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return note.localizedStandardContains(term)
            || idols.contains { $0.name.localizedStandardContains(term) }
            || (event?.name.localizedStandardContains(term) ?? false)
            || ChekinanaProductDate.displayString(date).localizedStandardContains(term)
            || date.map(ChekinanaDateOnly.string)?.localizedStandardContains(term) == true
            || typeName.localizedStandardContains(term)
    }

    static func ordered(_ values: [ChekinanaGalleryItem]) -> [ChekinanaGalleryItem] {
        ChekinanaRecordOrdering.ordered(values, ascending: true)
    }
}

enum ChekinanaGalleryMediaAspectRatio {
    static func value(for item: ChekinanaGalleryItem) -> CGFloat {
        switch item {
        case .cheki:
            ChekinanaChekiDisplayFramePolicy.aspectRatio
        case .shame:
            CGFloat(3) / 4
        case .douga:
            CGFloat(9) / 16
        }
    }
}

private enum ChekinanaGalleryImportPayload {
    case shame(stagedURL: URL, filenameExtension: String)
    case douga(stagedURL: URL)

    var stagedURL: URL {
        switch self {
        case .shame(let stagedURL, _), .douga(let stagedURL): stagedURL
        }
    }
}

private struct ChekinanaGalleryImportDraft: Identifiable {
    let id = UUID()
    let payload: ChekinanaGalleryImportPayload
}

enum ChekinanaProductRecordCreationError: LocalizedError, CaseIterable {
    case modelContextMismatch
    case indexOverflow
    case invalidIndex
    case indexCollision
    case invalidBatchQuantity

    var localizationKey: String {
        switch self {
        case .modelContextMismatch: "error.record_context_mismatch"
        case .indexOverflow: "error.index_overflow"
        case .invalidIndex: "error.invalid_index"
        case .indexCollision: "error.index_collision"
        case .invalidBatchQuantity: "error.record_quantity"
        }
    }

    var fallback: String {
        switch self {
        case .modelContextMismatch:
            "The selected relationships are no longer available in this library."
        case .indexOverflow:
            "This Cheki group cannot accept another index."
        case .invalidIndex:
            "Index must be empty or a positive integer."
        case .indexCollision:
            "One or more requested indices are already used in this Idol/date group."
        case .invalidBatchQuantity:
            "Quantity must be between 1 and 100."
        }
    }

    var errorDescription: String? {
        ChekinanaProductCopy.text(localizationKey, fallback)
    }
}

struct ChekinanaGalleryImportOnceGate {
    private var claimedIDs = Set<UUID>()

    mutating func claim(_ id: UUID) -> Bool {
        claimedIDs.insert(id).inserted
    }
}

struct ChekinanaGalleryImportRequestGate {
    private(set) var activeID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        activeID = id
        return id
    }

    func isCurrent(_ id: UUID) -> Bool {
        activeID == id
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}

enum ChekinanaGalleryImportEditorTeardownPolicy {
    static func shouldCancelImport(didFinish: Bool) -> Bool {
        !didFinish
    }
}

enum ChekinanaGalleryImportPreviewPolicy {
    static func shouldPrepare(
        preparedDraftID: UUID?,
        draftID: UUID
    ) -> Bool {
        preparedDraftID != draftID
    }
}

private struct ChekinanaGalleryVideoTransfer: Transferable {
    let stagedURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            ChekinanaGalleryVideoTransfer(
                stagedURL: try ChekinanaGalleryMediaStore.makeStagedVideoCopy(
                    from: received.file
                )
            )
        }
    }
}

private struct ChekinanaGalleryView: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Query private var chekis: [Cheki]
    @Query private var shames: [Shame]
    @Query private var dougas: [Douga]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let openMenu: () -> Void
    @State private var selectedType = ChekinanaRecordKind.cheki
    @State private var selectedIdolIDs: Set<UUID> = []
    @State private var isIdolFilterPresented = false
    @State private var favoritesOnly = false
    @State private var shotTypeFilter = ChekinanaGalleryShotTypeFilter.all
    @State private var sortsAscending = true
    @State private var selectedItem: ChekinanaGalleryItem?
    @State private var shamePickerItem: PhotosPickerItem?
    @State private var dougaPickerItem: PhotosPickerItem?
    @State private var isShamePickerPresented = false
    @State private var isDougaPickerPresented = false
    @State private var importDraft: ChekinanaGalleryImportDraft?
    @State private var importError: String?
    @State private var isLoadingImport = false
    @State private var importPreparationTask: Task<Void, Never>?
    @State private var importRequestGate = ChekinanaGalleryImportRequestGate()
    @State private var cleanupGate = ChekinanaGalleryImportOnceGate()

    private var allItems: [ChekinanaGalleryItem] {
        ChekinanaRecordOrdering.ordered(
            chekis.filter { ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }.map(ChekinanaGalleryItem.cheki)
                + shames.filter { ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }.map(ChekinanaGalleryItem.shame)
                + dougas.filter { ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }.map(ChekinanaGalleryItem.douga),
            ascending: sortsAscending
        ).filter { $0.hasMedia }
    }

    private var filteredItems: [ChekinanaGalleryItem] {
        currentTypeItems.filter { item in
            (selectedIdolIDs.isEmpty || item.idols.contains { selectedIdolIDs.contains($0.id) })
                && (selectedType != .cheki || !favoritesOnly || item.isFavoriteCheki)
                && (selectedType != .cheki || shotTypeFilter.includes(item.chekiUserAppears))
        }
    }

    private var currentTypeItems: [ChekinanaGalleryItem] {
        allItems.filter { $0.kind == selectedType }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4),
    ]

    private var uniqueGalleryIdols: [Idol] {
        var ids = Set<UUID>()
        return ChekinanaIdolOrdering.ordered(
            currentTypeItems.flatMap(\.idols).filter { ids.insert($0.id).inserted }
        )
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            Group {
                    ScrollView {
                        VStack(spacing: 12) {
                            Picker("Media type", selection: $selectedType) {
                                ForEach(ChekinanaRecordKind.allCases) { kind in
                                    Text(kind.title)
                                        .tag(kind)
                                        .accessibilityIdentifier("chekinana.gallery.type.\(kind.rawValue)")
                                }
                            }
                            .pickerStyle(.segmented)
                            .zIndex(1)
                            .accessibilityIdentifier("chekinana.gallery.type")

                            if selectedType == .cheki {
                                HStack {
                                    Picker(
                                        ChekinanaProductCopy.text(
                                            "scan.shot_type",
                                            "Shot type"
                                        ),
                                        selection: $shotTypeFilter
                                    ) {
                                        ForEach(ChekinanaGalleryShotTypeFilter.allCases) { filter in
                                            Text(filter.title)
                                                .tag(filter)
                                                .accessibilityIdentifier(
                                                    "chekinana.gallery.shot-type.\(filter.rawValue)"
                                                )
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: 260)
                                    .accessibilityIdentifier("chekinana.gallery.shot-type")
                                    Spacer(minLength: 0)
                                }
                            }

                            HStack(spacing: 10) {
                                Button {
                                    isIdolFilterPresented = true
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: selectedIdolIDs.isEmpty ? "person.2" : "person.2.fill")
                                        if !selectedIdolIDs.isEmpty {
                                            Text(selectedIdolIDs.count.formatted())
                                        }
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(selectedIdolIDs.isEmpty ? "Filter Idols: All" : "Filter Idols: \(selectedIdolIDs.count) selected")
                                .accessibilityIdentifier("chekinana.gallery.idol-filter")
                                if selectedType == .cheki {
                                    Button { favoritesOnly.toggle() } label: {
                                        Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .tint(favoritesOnly ? .yellow : ChekinanaProductTheme.accent)
                                    .accessibilityIdentifier("chekinana.gallery.favorite")
                                }
                                Spacer()
                                Button { sortsAscending.toggle() } label: {
                                    Image(systemName: sortsAscending ? "arrow.up" : "arrow.down")
                                }
                                .accessibilityLabel(sortsAscending ? "Oldest first" : "Newest first")
                                .accessibilityIdentifier("chekinana.gallery.sort")
                            }

                            if filteredItems.isEmpty {
                                ChekinanaEmptyState(
                                    title: "No matching media",
                                    message: "Add media for this type.",
                                    systemImage: "line.3.horizontal.decrease.circle"
                                )
                                .frame(maxWidth: .infinity, minHeight: 420)
                                .chekinanaScreenMarker("chekinana.gallery.empty")
                            } else {
                                LazyVGrid(columns: columns, spacing: 4) {
                                    ForEach(filteredItems) { item in
                                        Button { selectedItem = item } label: {
                                            ChekinanaGalleryCard(item: item)
                                        }
                                        .buttonStyle(.plain)
                                        .contentShape(Rectangle())
                                        .accessibilityIdentifier("chekinana.gallery.card.\(item.id)")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 110)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle(ChekinanaProductTab.gallery.title)
            .toolbar {
                ChekinanaPageToolbar(pageID: "gallery", openMenu: openMenu)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isShamePickerPresented = true
                        } label: {
                            Label("Add Shame photo", systemImage: "photo.badge.plus")
                        }
                        Button {
                            isDougaPickerPresented = true
                        } label: {
                            Label("Add Douga video", systemImage: "video.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Gallery media")
                    .accessibilityIdentifier("chekinana.gallery.add")
                }
            }
            .fullScreenCover(item: $selectedItem) { item in
                switch item {
                case .cheki(let cheki):
                    ChekinanaGalleryDetailView(cheki: cheki)
                case .shame(let shame):
                    ChekinanaGalleryMediaDetailView(shame: shame)
                case .douga(let douga):
                    ChekinanaGalleryMediaDetailView(douga: douga)
                }
            }
            .sheet(isPresented: $isIdolFilterPresented) {
                ChekinanaGalleryIdolFilterPicker(
                    idols: uniqueGalleryIdols,
                    selectedIDs: $selectedIdolIDs
                )
                .presentationDetents([.medium, .large])
            }
            .photosPicker(
                isPresented: $isShamePickerPresented,
                selection: $shamePickerItem,
                matching: .images,
                preferredItemEncoding: .current
            )
            .photosPicker(
                isPresented: $isDougaPickerPresented,
                selection: $dougaPickerItem,
                matching: .videos,
                preferredItemEncoding: .current
            )
            .fullScreenCover(item: $importDraft) { draft in
                ChekinanaGalleryImportEditor(
                    draft: draft,
                    onSaved: {
                        cleanupImportDraft(draft)
                        importDraft = nil
                    },
                    onCancel: {
                        cleanupImportDraft(draft)
                        importDraft = nil
                    }
                )
            }
            .onChange(of: shamePickerItem) { _, item in
                guard let item else { return }
                beginShameImport(item)
            }
            .onChange(of: selectedType) { _, _ in
                // Favorites are a Cheki property, never a Shame/Douga filter.
                if selectedType != .cheki { favoritesOnly = false }
                selectedIdolIDs.formIntersection(Set(uniqueGalleryIdols.map(\.id)))
            }
            .onChange(of: dougaPickerItem) { _, item in
                guard let item else { return }
                beginDougaImport(item)
            }
            .onDisappear { importPreparationTask?.cancel() }
            .overlay { if isLoadingImport { ProgressView("Preparing media…")
                .padding(22).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 16)) } }
            .alert("Unable to add media", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(importError ?? "") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.gallery.page")
        .chekinanaScreenMarker("chekinana.gallery.page")
    }

    @MainActor
    private func beginShameImport(_ item: PhotosPickerItem) {
        importPreparationTask?.cancel()
        dougaPickerItem = nil
        let requestID = importRequestGate.begin()
        isLoadingImport = true
        importPreparationTask = Task {
            await prepareShameImport(item, requestID: requestID)
        }
    }

    @MainActor
    private func prepareShameImport(
        _ item: PhotosPickerItem,
        requestID: UUID
    ) async {
        var stagedURL: URL?
        defer {
            if importRequestGate.finish(requestID) {
                isLoadingImport = false
                shamePickerItem = nil
                importPreparationTask = nil
            }
        }
        do {
            let image = try await ChekinanaProductMediaLoader.load(item)
            try Task.checkCancellation()
            stagedURL = try await ChekinanaGalleryMediaStore.makeStagedImageCopy(
                from: image.data,
                filenameExtension: image.filenameExtension
            )
            try Task.checkCancellation()
            guard importRequestGate.isCurrent(requestID), let readyURL = stagedURL else {
                throw CancellationError()
            }
            replaceImportDraft(with: ChekinanaGalleryImportDraft(
                payload: .shame(
                    stagedURL: readyURL,
                    filenameExtension: image.filenameExtension
                )
            ))
            stagedURL = nil
        } catch is CancellationError {
            await ChekinanaGalleryMediaStore.discardStagedImport(at: stagedURL)
        } catch {
            await ChekinanaGalleryMediaStore.discardStagedImport(at: stagedURL)
            if importRequestGate.isCurrent(requestID) {
                importError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func beginDougaImport(_ item: PhotosPickerItem) {
        importPreparationTask?.cancel()
        shamePickerItem = nil
        let requestID = importRequestGate.begin()
        isLoadingImport = true
        importPreparationTask = Task {
            await prepareDougaImport(item, requestID: requestID)
        }
    }

    @MainActor
    private func prepareDougaImport(
        _ item: PhotosPickerItem,
        requestID: UUID
    ) async {
        var stagedURL: URL?
        defer {
            if importRequestGate.finish(requestID) {
                isLoadingImport = false
                dougaPickerItem = nil
                importPreparationTask = nil
            }
        }
        do {
            guard let transfer = try await item.loadTransferable(
                type: ChekinanaGalleryVideoTransfer.self
            ) else {
                throw ChekinanaGalleryMediaStoreError.invalidMedia
            }
            stagedURL = transfer.stagedURL
            try Task.checkCancellation()
            guard importRequestGate.isCurrent(requestID), let readyURL = stagedURL else {
                throw CancellationError()
            }
            replaceImportDraft(with: ChekinanaGalleryImportDraft(
                payload: .douga(stagedURL: readyURL)
            ))
            stagedURL = nil
        } catch is CancellationError {
            await ChekinanaGalleryMediaStore.discardStagedImport(at: stagedURL)
        } catch {
            await ChekinanaGalleryMediaStore.discardStagedImport(at: stagedURL)
            if importRequestGate.isCurrent(requestID) {
                importError = error.localizedDescription
            }
        }
    }

    private func cleanupImportDraft(_ draft: ChekinanaGalleryImportDraft) {
        guard cleanupGate.claim(draft.id) else { return }
        let stagedURL = draft.payload.stagedURL
        Task { await ChekinanaGalleryMediaStore.discardStagedImport(at: stagedURL) }
    }

    private func replaceImportDraft(with newDraft: ChekinanaGalleryImportDraft) {
        if let importDraft {
            cleanupImportDraft(importDraft)
        }
        importDraft = newDraft
    }

}

private struct ChekinanaGalleryIdolFilterPicker: View {
    @Environment(\.dismiss) private var dismiss
    let idols: [Idol]
    @Binding var selectedIDs: Set<UUID>

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 82, maximum: 112), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(ChekinanaIdolOrdering.ordered(idols)) { idol in
                        idolOption(idol)
                    }
                }
                .padding(16)
            }
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle("Idols")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("chekinana.gallery.idol-filter.done")
                }
            }
        }
    }

    private func idolOption(_ idol: Idol) -> some View {
        let isSelected = selectedIDs.contains(idol.id)
        return Button {
            if isSelected {
                selectedIDs.remove(idol.id)
            } else {
                selectedIDs.insert(idol.id)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                ChekinanaIdolAvatar(idol: idol, size: 62)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, ChekinanaProductTheme.accent)
                        .background(Circle().fill(.white))
                        .offset(x: 4, y: -4)
                }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(idol.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chekinana.gallery.idol-filter.\(idol.id.uuidString.lowercased())")
    }
}

private struct ChekinanaGalleryCard: View {
    let item: ChekinanaGalleryItem
    let showsIdolAvatars: Bool
    @State private var image: ChekinanaRenderedImage?

    init(item: ChekinanaGalleryItem, showsIdolAvatars: Bool = true) {
        self.item = item
        self.showsIdolAvatars = showsIdolAvatars
    }

    init(cheki: Cheki) {
        item = .cheki(cheki)
        showsIdolAvatars = true
    }

    private var imageReference: String? {
        switch item {
        case .cheki(let value): value.imageRef
        case .shame(let value): value.imageRef
        case .douga(let value):
            ChekinanaGalleryMediaStore.thumbnailReference(id: value.id)
        }
    }

    private var aspectRatio: CGFloat {
        ChekinanaGalleryMediaAspectRatio.value(for: item)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .tertiarySystemGroupedBackground)
                if let image { Image(decorative: image.cgImage, scale: 1).resizable().scaledToFill() }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if showsIdolAvatars, !item.idols.isEmpty {
                    ChekinanaGalleryOverlayAvatars(idols: item.idols)
                        .padding(6)
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .task(id: imageReference) {
            image = await ChekinanaThumbnailCache.shared.thumbnailImage(
                forManagedImageRef: imageReference,
                key: "product-gallery-\(item.id)",
                maxDimension: 720
            )
        }
    }
}

private struct ChekinanaGalleryOverlayAvatars: View {
    let idols: [Idol]
    var body: some View {
        GeometryReader { proxy in
            let layout = ChekinanaGalleryAvatarLayout.make(
                availableWidth: proxy.size.width,
                count: idols.count
            )
            ZStack(alignment: .bottomLeading) {
                ForEach(Array(idols.enumerated()), id: \.element.id) { index, idol in
                    ChekinanaIdolAvatar(idol: idol, size: layout.diameter)
                        .offset(x: layout.x(for: index))
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .bottomLeading
            )
        }
        .accessibilityIdentifier("chekinana.gallery.card.avatar-overlay")
    }
}

struct ChekinanaGalleryAvatarLayout: Equatable {
    let diameter: CGFloat
    let step: CGFloat
    let count: Int
    static func make(availableWidth: CGFloat, count: Int) -> Self {
        let n = max(count, 1)
        let width = max(availableWidth, 1)
        let diameter = min(24, width)
        let step = n == 1 ? 0 : max(0, min(diameter, (width - diameter) / CGFloat(n - 1)))
        return .init(diameter: diameter, step: step, count: n)
    }
    func x(for index: Int) -> CGFloat { CGFloat(max(0, min(index, count - 1))) * step }
}

private struct ChekinanaIdolAvatarRow: View {
    let idols: [Idol]
    let size: CGFloat
    var showsNames = false

    var body: some View {
        if idols.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "person.slash")
                    .frame(width: size, height: size)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                    .clipShape(Circle())
                Text(ChekinanaProductCopy.text("common.unassigned", "Unassigned"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(idols) { idol in
                        HStack(spacing: 5) {
                            ChekinanaIdolAvatar(idol: idol, size: size)
                            if showsNames {
                                Text(idol.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(idol.name)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(minHeight: size + 6)
        }
    }
}

enum ChekinanaGalleryDeleteDismissPolicy {
    static func canDismiss(
        pendingConfirmationCode: String?,
        recoveryRequired: Bool
    ) -> Bool {
        pendingConfirmationCode == nil || !recoveryRequired
    }
}

private struct ChekinanaGalleryDetailView: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let cheki: Cheki
    let onClose: (() -> Void)?
    @State private var image: ChekinanaRenderedImage?
    @State private var isEditing = false
    @State private var message: String?
    @State private var confirmationLedger = ChekinanaConfirmationLedger()
    @State private var pendingDeleteConfirmationCode: String?

    init(cheki: Cheki, onClose: (() -> Void)? = nil) {
        self.cheki = cheki
        self.onClose = onClose
    }

    var body: some View {
        let _ = languageRevision
        ZStack {
            ChekinanaProductTheme.pageBackground.ignoresSafeArea()
            ChekinanaAccessibilityMarker(identifier: "chekinana.gallery.detail.light")
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        ChekinanaIdolAvatarRow(idols: cheki.idols, size: 36, showsNames: true)
                        Text("\(ChekinanaProductDate.displayString(cheki.date))\(cheki.idx.map { "  ·  #\($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if canDismiss {
                            closeDetail()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDismiss)
                    .accessibilityLabel("关闭预览")
                    .accessibilityHint(
                        canDismiss
                            ? "关闭 Cheki 详情"
                            : "必须先点 Delete 完成图片恢复或清理"
                    )
                    .accessibilityIdentifier("chekinana.gallery.detail.close")
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ZStack {
                    if let image {
                        Image(decorative: image.cgImage, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView().tint(ChekinanaProductTheme.accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)

                if let note = cheki.note.nonEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }

                if deleteRecoveryRequired {
                    Label(
                        "Deletion recovery is required. Tap Delete again to finish restoring or cleaning up the managed image before closing.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("chekinana.gallery.detail.delete-recovery-required")
                }

                HStack(spacing: 12) {
                    Button { isEditing = true } label: { Label("Edit", systemImage: "pencil") }
                        .accessibilityIdentifier("chekinana.gallery.detail.edit")
                    Button { exportImage() } label: { Label("Export", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("chekinana.gallery.detail.export")
                    Spacer()
                    Button(role: .destructive) { Task { await deleteCheki() } } label: {
                        Label(
                            deleteRecoveryRequired ? "Retry recovery" : "Delete",
                            systemImage: deleteRecoveryRequired ? "arrow.clockwise" : "trash"
                        )
                    }
                    .accessibilityIdentifier("chekinana.gallery.detail.delete")
                }
                .buttonStyle(.bordered)
                .tint(ChekinanaProductTheme.accent)
                .padding(16)
            }
        }
        .preferredColorScheme(.light)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(!canDismiss)
        .chekinanaScreenMarker("chekinana.gallery.detail")
        .task(id: cheki.imageRef) {
            image = await ChekinanaImageWorker.previewImage(fromImageRef: cheki.imageRef ?? "", maxDimension: 2400)
        }
        .sheet(isPresented: $isEditing) { ChekinanaChekiEditorView(cheki: cheki) }
        .alert(ChekinanaRecordKind.cheki.title, isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(message ?? "") }
    }

    private var deleteRecoveryRequired: Bool {
        guard let pendingDeleteConfirmationCode else { return false }
        return confirmationLedger.cancellationRequiresRecovery(pendingDeleteConfirmationCode)
    }

    private var canDismiss: Bool {
        ChekinanaGalleryDeleteDismissPolicy.canDismiss(
            pendingConfirmationCode: pendingDeleteConfirmationCode,
            recoveryRequired: deleteRecoveryRequired
        )
    }

    private func closeDetail() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func exportImage() {
        guard let url = ChekiImageRefResolver.localFileURL(for: cheki.imageRef) else {
            message = "The clean stored image is unavailable."
            return
        }
        Task {
            do {
                try await ChekinanaProductPhotoSaver.saveImage(at: url)
                message = "Saved the clean image without bbox to Photos."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    @MainActor
    private func deleteCheki() async {
        let executor = ChekinanaCommandExecutor(
            modelContext: modelContext,
            confirmationLedger: confirmationLedger
        )
        let code: String
        if let pendingDeleteConfirmationCode {
            code = pendingDeleteConfirmationCode
        } else {
            let prepared = await executor.execute("deletecheki \(cheki.id.uuidString.lowercased())")
            guard let preparedCode = ChekinanaConfirmationResponseValidator.deleteChekiConfirmationCode(
                from: prepared,
                expectedChekiID: cheki.id
            ) else {
                message = ChekinanaConfirmationResponseValidator.failureDescription(
                    for: prepared,
                    fallback: "无法准备删除这张 Cheki。"
                )
                return
            }
            pendingDeleteConfirmationCode = preparedCode
            code = preparedCode
        }
        let result = await executor.execute("confirm \(code)")
        guard ChekinanaConfirmationResponseValidator.isDeleteChekiSuccess(result) else {
            if confirmationLedger.entry(for: code) == nil {
                pendingDeleteConfirmationCode = nil
            }
            let reason = ChekinanaConfirmationResponseValidator.failureDescription(
                for: result,
                fallback: "删除确认未返回可验证的成功结果。"
            )
            if confirmationLedger.cancellationRequiresRecovery(code) {
                message = "\(reason) This deletion is in required image recovery/cleanup. You must tap Delete / Retry recovery until it completes; this view cannot close yet."
            } else {
                message = reason
            }
            return
        }
        pendingDeleteConfirmationCode = nil
        closeDetail()
    }
}

private enum ChekinanaGalleryEditableMedia {
    case shame(Shame)
    case douga(Douga)

    var id: UUID {
        switch self {
        case .shame(let value): value.id
        case .douga(let value): value.id
        }
    }

    var typeName: String {
        switch self {
        case .shame: ChekinanaRecordKind.shame.title
        case .douga: ChekinanaRecordKind.douga.title
        }
    }

    var idols: [Idol] {
        switch self {
        case .shame(let value): value.idols
        case .douga(let value): value.idols
        }
    }

    var date: Date? {
        switch self {
        case .shame(let value): value.date
        case .douga(let value): value.date
        }
    }

    var note: String {
        switch self {
        case .shame(let value): value.note
        case .douga(let value): value.note
        }
    }

    var managedURL: URL? {
        switch self {
        case .shame(let value):
            ChekinanaGalleryMediaStore.managedURL(
                for: value.imageRef,
                id: value.id,
                kind: .shame
            )
        case .douga(let value):
            ChekinanaGalleryMediaStore.managedURL(
                for: value.videoRef,
                id: value.id,
                kind: .douga
            )
        }
    }

    var mediaKind: ChekinanaGalleryMediaKind {
        switch self {
        case .shame: .shame
        case .douga: .douga
        }
    }

    var mediaReference: String? {
        switch self {
        case .shame(let value): value.imageRef
        case .douga(let value): value.videoRef
        }
    }
}

private struct ChekinanaGalleryEditableMediaSnapshot {
    let id: UUID
    let kind: ChekinanaGalleryMediaKind
    let typeName: String
    let idolIDs: Set<UUID>
    let date: Date?
    let note: String

    init(_ item: ChekinanaGalleryEditableMedia) {
        id = item.id
        kind = item.mediaKind
        typeName = item.typeName
        idolIDs = Set(item.idols.map(\.id))
        date = item.date
        note = item.note
    }
}

private struct ChekinanaGalleryMediaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: ChekinanaGalleryEditableMedia
    @State private var image: ChekinanaRenderedImage?
    @State private var player: AVPlayer?
    @State private var isEditing = false
    @State private var message: String?
    @State private var isDeleting = false
    @State private var pendingRestore: [(original: URL, quarantine: URL)] = []

    init(shame: Shame) {
        item = .shame(shame)
    }

    init(douga: Douga) {
        item = .douga(douga)
    }

    var body: some View {
        ZStack {
            ChekinanaProductTheme.pageBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.typeName).font(.headline)
                        ChekinanaIdolAvatarRow(
                            idols: item.idols,
                            size: 34,
                            showsNames: true
                        )
                        Text(ChekinanaProductDate.displayString(item.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!pendingRestore.isEmpty)
                    .accessibilityLabel("Close \(item.typeName) detail")
                    .accessibilityIdentifier("chekinana.gallery.media.detail.close")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Group {
                    switch item {
                    case .shame:
                        if let image {
                            Image(decorative: image.cgImage, scale: 1)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    case .douga:
                        if let player {
                            VideoPlayer(player: player)
                                .onDisappear { player.pause() }
                        } else {
                            ProgressView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 5) {
                    if let note = item.note.nonEmpty {
                        Text(note)
                    }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if !pendingRestore.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Media recovery is required before this item can be used or closed.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        Button("Retry recovery") { retryRecovery() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("chekinana.gallery.media.retry-recovery")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .accessibilityIdentifier("chekinana.gallery.media.recovery-required")
                }

                HStack(spacing: 12) {
                    Button { isEditing = true } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("chekinana.gallery.media.detail.edit")
                    .disabled(!pendingRestore.isEmpty)
                    Button { exportMedia() } label: {
                        Label("Export", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!pendingRestore.isEmpty)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await deleteMedia() }
                    } label: {
                        if isDeleting {
                            ProgressView()
                        } else {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .disabled(isDeleting || !pendingRestore.isEmpty)
                }
                .buttonStyle(.bordered)
                .tint(ChekinanaProductTheme.accent)
                .padding(16)
            }
        }
        .preferredColorScheme(.light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.gallery.media.detail.\(item.mediaKind.rawValue)")
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(!pendingRestore.isEmpty)
        .task(id: item.id) {
            pendingRestore = ChekinanaGalleryMediaStore.restoreRecoveryFiles(
                kind: item.mediaKind,
                id: item.id,
                reference: item.mediaReference
            )
            guard pendingRestore.isEmpty else { return }
            await loadMedia()
        }
        .sheet(isPresented: $isEditing) {
            ChekinanaGalleryMetadataEditor(
                item: ChekinanaGalleryEditableMediaSnapshot(item)
            )
        }
        .alert(item.typeName, isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(message ?? "") }
    }

    private func exportMedia() {
        guard let url = item.managedURL else {
            message = ChekinanaGalleryMediaStoreError.missingManagedFile.localizedDescription
            return
        }
        Task {
            do {
                switch item {
                case .shame:
                    try await ChekinanaProductPhotoSaver.saveImage(at: url)
                case .douga:
                    try await ChekinanaProductPhotoSaver.saveVideo(at: url)
                }
                message = "Saved \(item.typeName) to Photos."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    @MainActor
    private func deleteMedia() async {
        guard !isDeleting, pendingRestore.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        let staged: [(original: URL, quarantine: URL)]
        do {
            switch item {
            case .shame(let value):
                staged = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
                    kind: .shame,
                    id: value.id,
                    reference: value.imageRef
                )
                modelContext.delete(value)
            case .douga(let value):
                staged = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
                    kind: .douga,
                    id: value.id,
                    reference: value.videoRef
                )
                modelContext.delete(value)
            }
            do {
                try modelContext.save()
            } catch let databaseError {
                modelContext.rollback()
                ChekinanaGalleryMediaStore.recordRestoreRecovery(staged)
                do {
                    try ChekinanaGalleryMediaStore.restoreStagedFiles(staged)
                } catch let recoveryError {
                    pendingRestore = staged
                    image = nil
                    player?.pause()
                    player = nil
                    message = "The database delete failed and the managed media could not be restored. Retry recovery before closing: \(recoveryError.localizedDescription)"
                    return
                }
                ChekinanaGalleryMediaStore.removeRestoreRecovery(staged)
                throw databaseError
            }
            ChekinanaGalleryMediaStore.recordCommittedDeletion(staged)
            do {
                try ChekinanaGalleryMediaStore.finalizeStagedDeletion(staged)
            } catch {
                // The model is already deleted. Keep the committed quarantine
                // queued for launch/clear cleanup and close this stale detail.
                dismiss()
                return
            }
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func retryRecovery() {
        guard !pendingRestore.isEmpty else { return }
        do {
            try ChekinanaGalleryMediaStore.restoreStagedFiles(pendingRestore)
            ChekinanaGalleryMediaStore.removeRestoreRecovery(pendingRestore)
            pendingRestore = []
            message = "Managed media recovery completed."
            Task { await loadMedia() }
        } catch {
            message = "Recovery is still required: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadMedia() async {
        guard let url = item.managedURL else { return }
        switch item {
        case .shame:
            image = await ChekinanaImageWorker.previewImage(
                fromImageRef: url.lastPathComponent,
                maxDimension: 2_400
            )
        case .douga:
            player = AVPlayer(url: url)
        }
    }
}

private struct ChekinanaGalleryImportEditor: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Idol.name) private var idols: [Idol]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let draft: ChekinanaGalleryImportDraft
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var idolIDs = Set<UUID>()
    @State private var hasDate = false
    @State private var date = Date()
    @State private var note = ""
    @State private var isIdolSelectionPresented = false
    @State private var isSaving = false
    @State private var message: String?
    @State private var image: ChekinanaRenderedImage?
    @State private var player: AVPlayer?
    @State private var didFinish = false
    @State private var preparedDraftID: UUID?

    private var title: String {
        switch draft.payload {
        case .shame: "Add Shame"
        case .douga: "Add Douga"
        }
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            Form {
                Section("Preview") {
                    Group {
                        switch draft.payload {
                        case .shame:
                            if let image {
                                Image(decorative: image.cgImage, scale: 1)
                                    .resizable().scaledToFit()
                            } else {
                                ProgressView()
                            }
                        case .douga:
                            if let player {
                                VideoPlayer(player: player)
                                    .frame(minHeight: 240)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
                Section("Idols") {
                    ChekinanaIdolAvatarRow(
                        idols: visibleIdols.filter { idolIDs.contains($0.id) },
                        size: 38,
                        showsNames: true
                    )
                    Button("Choose Idols") { isIdolSelectionPresented = true }
                        .accessibilityIdentifier("chekinana.gallery.import.idols")
                }
                Section("Metadata") {
                    Toggle("Include date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                    }
                    TextField("Note", text: $note, axis: .vertical)
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .disabled(isSaving)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        finish(saved: false)
                    }
                        .disabled(isSaving)
                        .accessibilityIdentifier("chekinana.gallery.import.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                        .accessibilityIdentifier("chekinana.gallery.import.save")
                }
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $isIdolSelectionPresented) {
            ChekinanaIdolSelectionView(
                options: visibleIdols.map(ChekinanaIdolSelectionOption.init),
                selectedIDs: $idolIDs
            )
        }
        .task(id: draft.id) {
            guard ChekinanaGalleryImportPreviewPolicy.shouldPrepare(
                preparedDraftID: preparedDraftID,
                draftID: draft.id
            ) else { return }
            preparedDraftID = draft.id
            switch draft.payload {
            case .shame(let stagedURL, _):
                let preparedImage = await ChekinanaImageWorker.thumbnailImage(
                    fromFileAt: stagedURL,
                    maxDimension: 1_600
                )
                guard !didFinish else { return }
                image = preparedImage
            case .douga(let stagedURL):
                guard !didFinish, player == nil else { return }
                player = AVPlayer(url: stagedURL)
            }
        }
        .onDisappear {
            guard ChekinanaGalleryImportEditorTeardownPolicy.shouldCancelImport(
                didFinish: didFinish
            ) else { return }
            finish(saved: false)
        }
    }

    private var visibleIdols: [Idol] {
        ChekinanaVisibilityPolicy.visibleIdols(idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }

    @MainActor
    private func save() async {
        guard !isSaving, !didFinish else { return }
        isSaving = true
        defer { isSaving = false }
        let normalizedDate = hasDate
            ? ChekinanaDateOnly.canonicalDate(from: date, displayedIn: .current)
            : nil
        if hasDate, normalizedDate == nil {
            message = "Unable to normalize the selected date."
            return
        }
        let selectedIdolIDs = idolIDs
        let savedNote = note
        let id = UUID()
        do {
            switch draft.payload {
            case .shame(let stagedURL, let filenameExtension):
                let reference = try await ChekinanaGalleryMediaStore.saveImage(
                    from: stagedURL,
                    id: id,
                    filenameExtension: filenameExtension
                )
                do {
                    let selectedIdols = try ChekinanaModelContextResolver.idols(
                        idolIDs: selectedIdolIDs,
                        in: modelContext
                    )
                    let shame = Shame(
                        id: id,
                        imageRef: reference,
                        date: normalizedDate,
                        note: savedNote
                    )
                    modelContext.insert(shame)
                    guard shame.modelContext === modelContext,
                          selectedIdols.allSatisfy({
                              $0.modelContext === modelContext
                          }) else {
                        throw ChekinanaProductRecordCreationError.modelContextMismatch
                    }
                    shame.idols = selectedIdols
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    do {
                        try await ChekinanaGalleryMediaStore.removeFilesInBackground(
                            kind: .shame,
                            id: id,
                            reference: reference
                        )
                    } catch {
                        ChekinanaGalleryMediaStore.recordOrphanedImport(
                            kind: .shame,
                            id: id,
                            reference: reference
                        )
                    }
                    throw error
                }
            case .douga(let stagedURL):
                let reference = try await ChekinanaGalleryMediaStore.saveVideo(
                    from: stagedURL,
                    id: id
                )
                do {
                    let selectedIdols = try ChekinanaModelContextResolver.idols(
                        idolIDs: selectedIdolIDs,
                        in: modelContext
                    )
                    let douga = Douga(
                        id: id,
                        videoRef: reference,
                        date: normalizedDate,
                        note: savedNote
                    )
                    modelContext.insert(douga)
                    guard douga.modelContext === modelContext,
                          selectedIdols.allSatisfy({
                              $0.modelContext === modelContext
                          }) else {
                        throw ChekinanaProductRecordCreationError.modelContextMismatch
                    }
                    douga.idols = selectedIdols
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    do {
                        try await ChekinanaGalleryMediaStore.removeFilesInBackground(
                            kind: .douga,
                            id: id,
                            reference: reference
                        )
                    } catch {
                        ChekinanaGalleryMediaStore.recordOrphanedImport(
                            kind: .douga,
                            id: id,
                            reference: reference
                        )
                    }
                    throw error
                }
            }
            finish(saved: true)
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func finish(saved: Bool) {
        guard !didFinish else { return }
        didFinish = true
        isIdolSelectionPresented = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        image = nil
        if saved {
            onSaved()
        } else {
            onCancel()
        }
    }
}

private struct ChekinanaGalleryMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Idol.name) private var idols: [Idol]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let item: ChekinanaGalleryEditableMediaSnapshot

    @State private var idolIDs: Set<UUID>
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var note: String
    @State private var message: String?
    @State private var isIdolSelectionPresented = false

    init(item: ChekinanaGalleryEditableMediaSnapshot) {
        self.item = item
        _idolIDs = State(initialValue: item.idolIDs)
        _hasDate = State(initialValue: item.date != nil)
        _date = State(initialValue: item.date.flatMap {
            ChekinanaDateOnly.displayDate(from: $0, calendar: .current)
        } ?? Date())
        _note = State(initialValue: item.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Idols") {
                    ChekinanaIdolAvatarRow(
                        idols: visibleIdols.filter { idolIDs.contains($0.id) },
                        size: 38,
                        showsNames: true
                    )
                    Button("Change Idols") { isIdolSelectionPresented = true }
                        .accessibilityIdentifier("chekinana.gallery.media.editor.idols")
                }
                Section("Metadata") {
                    Toggle("Include date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                    }
                    TextField("Note", text: $note, axis: .vertical)
                }
                if let message { Section { Text(message).foregroundStyle(.red) } }
            }
            .navigationTitle("Edit \(item.typeName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .accessibilityIdentifier("chekinana.gallery.media.editor.save")
                }
            }
        }
        .sheet(isPresented: $isIdolSelectionPresented) {
            ChekinanaIdolSelectionView(
                options: visibleIdols.map(ChekinanaIdolSelectionOption.init),
                selectedIDs: $idolIDs
            )
        }
    }

    private var visibleIdols: [Idol] {
        ChekinanaVisibilityPolicy.visibleIdols(idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }

    private func save() {
        let normalizedDate = hasDate
            ? ChekinanaDateOnly.canonicalDate(from: date, displayedIn: .current)
            : nil
        if hasDate, normalizedDate == nil {
            message = "Unable to normalize the selected date."
            return
        }
        do {
            let selectedIdols = try ChekinanaModelContextResolver.idols(
                idolIDs: idolIDs,
                in: modelContext
            )
            switch item.kind {
            case .shame:
                let value = try ChekinanaModelContextResolver.shame(
                    id: item.id,
                    in: modelContext
                )
                value.idols = selectedIdols
                value.date = normalizedDate
                value.note = note
            case .douga:
                let value = try ChekinanaModelContextResolver.douga(
                    id: item.id,
                    in: modelContext
                )
                value.idols = selectedIdols
                value.date = normalizedDate
                value.note = note
            }
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            message = error.localizedDescription
        }
    }
}

private enum ChekinanaProductPhotoSaver {
    static func saveImage(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ChekinanaProductPhotoSaveError.notAuthorized
        }
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: error ?? ChekinanaProductPhotoSaveError.failed)
                }
            }
        }
    }

    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ChekinanaProductPhotoSaveError.notAuthorized
        }
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: error ?? ChekinanaProductPhotoSaveError.failed
                    )
                }
            }
        }
    }
}

private enum ChekinanaProductPhotoSaveError: LocalizedError {
    case notAuthorized
    case failed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Photos access is not authorized."
        case .failed: "The media could not be saved to Photos."
        }
    }
}

private struct ChekinanaIdolSelectionOption: Identifiable, Hashable {
    let id: UUID
    let name: String
    let group: String?
    let color: String?
    let avatarImageRef: String?

    init(_ idol: Idol) {
        id = idol.id
        name = idol.name
        group = idol.group
        color = idol.color
        avatarImageRef = idol.avatarImageRef
    }
}

private struct ChekinanaIdolSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let options: [ChekinanaIdolSelectionOption]
    @Binding var selectedIDs: Set<UUID>
    @State private var query = ""

    private var filteredIdols: [ChekinanaIdolSelectionOption] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return options }
        return options.filter {
            $0.name.localizedStandardContains(term)
                || ($0.group?.localizedStandardContains(term) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !selectedIDs.isEmpty {
                    Button(
                        ChekinanaProductCopy.text("common.clear_all", "Clear all"),
                        role: .destructive
                    ) { selectedIDs.removeAll() }
                        .accessibilityIdentifier("chekinana.gallery.editor.idols.clear")
                }
                ForEach(filteredIdols) { idol in
                    Button {
                        if selectedIDs.contains(idol.id) {
                            selectedIDs.remove(idol.id)
                        } else {
                            selectedIDs.insert(idol.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ChekinanaIdolAvatarImage(
                                name: idol.name,
                                color: idol.color,
                                imageRef: idol.avatarImageRef,
                                cacheKey: "idol-selection-\(idol.id.uuidString.lowercased())",
                                size: 42,
                                managedIdolID: idol.id
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(idol.name).foregroundStyle(.primary)
                                Text(
                                    idol.group?.nonEmpty
                                        ?? ChekinanaProductCopy.text(
                                            "common.independent",
                                            "Independent"
                                        )
                                )
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selectedIDs.contains(idol.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(idol.id) ? ChekinanaProductTheme.accent : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(
                        selectedIDs.contains(idol.id)
                            ? ChekinanaProductCopy.text("common.selected", "Selected")
                            : ChekinanaProductCopy.text(
                                "common.not_selected",
                                "Not selected"
                            )
                    )
                    .accessibilityIdentifier("chekinana.gallery.editor.idol.\(idol.id.uuidString.lowercased())")
                }
            }
            .searchable(
                text: $query,
                prompt: ChekinanaProductCopy.text("common.search_idols", "Search Idols")
            )
            .chekinanaGroupedPageBackground()
            .navigationTitle(
                ChekinanaProductCopy.text("common.select_idols", "Select Idols")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChekinanaProductCopy.text("common.done", "Done")) {
                        dismiss()
                    }
                        .accessibilityIdentifier("chekinana.gallery.editor.idols.done")
                }
            }
        }
        .accessibilityIdentifier("chekinana.gallery.editor.idol-selection")
    }
}

private struct ChekinanaChekiEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Idol.name) private var idols: [Idol]
    @Query(sort: \Event.date) private var events: [Event]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let cheki: Cheki
    var allowsDelete = false

    @State private var idolIDs: Set<UUID>
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var eventID: UUID?
    private let preservedUserAppears: Bool?
    private let initialIdxText: String
    @State private var idxText: String
    @State private var size: ChekiSize?
    @State private var isFavorite: Bool
    @State private var hasPostedToSNS: Bool
    @State private var note: String
    @State private var message: String?
    @State private var isIdolSelectionPresented = false

    init(cheki: Cheki, allowsDelete: Bool = false) {
        self.cheki = cheki
        self.allowsDelete = allowsDelete
        _idolIDs = State(initialValue: Set(cheki.idols.map(\.id)))
        _hasDate = State(initialValue: cheki.date != nil)
        _date = State(initialValue: cheki.date.flatMap {
            ChekinanaDateOnly.displayDate(from: $0, calendar: .current)
        } ?? Date())
        _eventID = State(initialValue: cheki.event?.id)
        preservedUserAppears = cheki.userAppears
        initialIdxText = cheki.idx.map(String.init) ?? ""
        _idxText = State(initialValue: cheki.idx.map(String.init) ?? "")
        _size = State(initialValue: cheki.size)
        _isFavorite = State(initialValue: cheki.isFavorite)
        _hasPostedToSNS = State(initialValue: cheki.hasPostedToSNS)
        _note = State(initialValue: cheki.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(ChekinanaProductCopy.text("common.idols", "Idols")) {
                    ChekinanaIdolAvatarRow(
                        idols: visibleIdols.filter { idolIDs.contains($0.id) },
                        size: 38,
                        showsNames: true
                    )
                    Button {
                        isIdolSelectionPresented = true
                    } label: {
                        Label(
                            ChekinanaProductCopy.text("common.change_idols", "Change Idols"),
                            systemImage: "person.2"
                        )
                    }
                    .accessibilityIdentifier("chekinana.gallery.editor.change-idols")
                }
                Section(ChekinanaProductCopy.text("common.identity", "Identity")) {
                    Toggle(
                        ChekinanaProductCopy.text("common.include_date", "Include date"),
                        isOn: $hasDate
                    )
                    if hasDate {
                        DatePicker(
                            ChekinanaProductCopy.text("common.date", "Date"),
                            selection: $date,
                            displayedComponents: .date
                        )
                    }
                    Picker(
                        ChekinanaProductCopy.text("events.event", "Event"),
                        selection: $eventID
                    ) {
                        Text(ChekinanaProductCopy.text("common.none", "None"))
                            .tag(UUID?.none)
                        ForEach(events) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField(
                        ChekinanaProductCopy.text(
                            "common.index_optional",
                            "Index (optional)"
                        ),
                        text: $idxText
                    )
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("chekinana.gallery.editor.idx")
                    Text(
                        ChekinanaProductCopy.format(
                            "common.current_index",
                            "Current index: %@",
                            cheki.idx.map { "#\($0)" }
                                ?? ChekinanaProductCopy.text("common.none", "None")
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(ChekinanaProductCopy.text("common.other", "Other")) {
                    Picker(
                        ChekinanaProductCopy.text("common.size", "Size"),
                        selection: $size
                    ) {
                        Text(ChekinanaProductCopy.text("common.unset", "Unset"))
                            .tag(ChekiSize?.none)
                        ForEach(ChekiSize.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    Toggle(
                        ChekinanaProductCopy.text("common.favorite", "Favorite"),
                        isOn: $isFavorite
                    )
                    Toggle(
                        ChekinanaProductCopy.text("common.posted_to_sns", "Posted to SNS"),
                        isOn: $hasPostedToSNS
                    )
                    TextField(
                        ChekinanaProductCopy.text("common.note", "Note"),
                        text: $note,
                        axis: .vertical
                    )
                }
                if let message {
                    Section { ChekinanaInlineStatus(message: message, kind: .error) }
                }
            }
            .chekinanaGroupedPageBackground()
            .navigationTitle(
                ChekinanaProductCopy.format(
                    "calendar.edit_record",
                    "Edit %@",
                    ChekinanaRecordKind.cheki.title
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaProductCopy.text("common.cancel", "Cancel")) {
                        dismiss()
                    }
                        .accessibilityIdentifier("chekinana.gallery.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        ChekinanaProductCopy.text("common.save", "Save"),
                        action: save
                    )
                        .accessibilityIdentifier("chekinana.gallery.editor.save")
                }
                if allowsDelete {
                    ToolbarItem(placement: .bottomBar) {
                        Button(
                            ChekinanaProductCopy.text("common.delete", "Delete"),
                            role: .destructive,
                            action: delete
                        )
                            .accessibilityIdentifier("chekinana.gallery.editor.delete")
                    }
                }
            }
        }
        .accessibilityIdentifier("chekinana.gallery.editor")
        .sheet(isPresented: $isIdolSelectionPresented) {
            ChekinanaIdolSelectionView(
                options: visibleIdols.map(ChekinanaIdolSelectionOption.init),
                selectedIDs: $idolIDs
            )
        }
    }

    private var visibleIdols: [Idol] {
        ChekinanaVisibilityPolicy.visibleIdols(idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }

    private func save() {
        let normalizedDate = hasDate
            ? ChekinanaDateOnly.canonicalDate(from: date, displayedIn: .current)
            : nil
        if hasDate, normalizedDate == nil {
            message = ChekinanaProductCopy.text(
                "error.normalize_date",
                "Unable to normalize the selected date."
            )
            return
        }
        let newIdolIDs = Array(idolIDs)
        let newGroup = ChekinanaChekiGroupKey(idolIDs: newIdolIDs, date: normalizedDate)
        let normalizedIdxText = idxText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedIdx: Int?
        if normalizedIdxText.isEmpty {
            requestedIdx = nil
        } else if let parsed = Int(normalizedIdxText), parsed > 0 {
            requestedIdx = parsed
        } else {
            message = ChekinanaProductCopy.text(
                "error.invalid_index",
                "Index must be empty or a positive integer."
            )
            return
        }
        let idxWasManuallyEdited = normalizedIdxText != initialIdxText
        do {
            let target = try ChekinanaModelContextResolver.cheki(
                id: cheki.id,
                in: modelContext
            )
            let relationships = try ChekinanaModelContextResolver.relationships(
                idolIDs: idolIDs,
                eventID: eventID,
                in: modelContext
            )
            let oldGroup = ChekinanaChekiGroupKey(
                idolIDs: target.idols.map(\.id),
                date: target.date
            )
            let all = try modelContext.fetch(FetchDescriptor<Cheki>())
            let snapshots = all.compactMap { value -> ChekinanaChekiIndexSnapshot? in
                    guard let group = ChekinanaChekiGroupKey(
                        idolIDs: value.idols.map(\.id),
                        date: value.date
                    ) else { return nil }
                    return .init(chekiID: value.id, group: group, idx: value.idx)
            }
            if idxWasManuallyEdited {
                if requestedIdx != nil, newGroup == nil {
                    message = "A positive index requires both a date and at least one Idol."
                    return
                }
                if let newGroup, let requestedIdx,
                   snapshots.contains(where: {
                       $0.chekiID != target.id
                           && $0.group == newGroup
                           && $0.idx == requestedIdx
                   }) {
                    message = "Index #\(requestedIdx) is already used in this Idol/date group."
                    return
                }
                target.idx = requestedIdx
            } else if let newGroup,
                      oldGroup != newGroup || (target.idx ?? 0) < 1 {
                target.idx = try ChekinanaChekiIndexing.nextIndex(
                    for: newGroup,
                    existing: snapshots,
                    excludingChekiID: target.id
                )
            } else if newGroup == nil {
                target.idx = nil
            }
            target.idols = relationships.idols
            target.date = normalizedDate
            target.event = relationships.event
            target.userAppears = preservedUserAppears
            target.size = size
            target.isFavorite = isFavorite
            target.hasPostedToSNS = hasPostedToSNS
            target.note = note
            target.updatedAt = Date()
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            message = error.localizedDescription
        }
    }

    private func delete() {
        do {
            let target = try ChekinanaModelContextResolver.cheki(
                id: cheki.id,
                in: modelContext
            )
            guard target.imageRef?.nonEmpty == nil else {
                message = "Delete media-backed Cheki from its media detail page."
                return
            }
            modelContext.delete(target)
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            message = error.localizedDescription
        }
    }
}

private struct ChekinanaCalendarView: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Query(sort: \Cheki.date) private var chekis: [Cheki]
    @Query private var shames: [Shame]
    @Query private var dougas: [Douga]
    @Query(sort: \Event.date) private var events: [Event]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let openMenu: () -> Void
    @Binding var navigationDate: Date?

    @State private var displayedMonth = ChekinanaProductDate.startOfMonth(containing: ChekinanaProductDate.fixtureAwareToday)
    @State private var selectedDate = ChekinanaProductDate.fixtureAwareToday
    @State private var selectedGroup: ChekinanaCalendarIdolGroup?
    @State private var selectedNoMediaRecord: ChekinanaCalendarNoMediaRecord?
    @State private var isAddingRecord = false
    @State private var isPickingMonth = false
    @State private var isUndatedUnassignedPresented = false

    private var cells: [ChekinanaCalendarCell] {
        ChekinanaProductDate.monthCells(for: displayedMonth)
    }

    private var selectedChekis: [Cheki] {
        ChekinanaRecordOrdering.orderedChekis(chekis.filter {
            ChekinanaProductDate.isSameDay($0.date, selectedDate)
                && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs)
        })
    }

    private var selectedEvents: [Event] {
        events.filter { ChekinanaProductDate.isSameDay($0.date, selectedDate) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private var selectedShames: [Shame] { shames.filter {
        ChekinanaProductDate.isSameDay($0.date, selectedDate)
            && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }.sorted { $0.id.uuidString < $1.id.uuidString } }
    private var selectedDougas: [Douga] { dougas.filter {
        ChekinanaProductDate.isSameDay($0.date, selectedDate)
            && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }.sorted { $0.id.uuidString < $1.id.uuidString } }

    private var selectedGroups: [ChekinanaCalendarIdolGroup] {
        ChekinanaCalendarIdolGroup.groups(for: selectedChekis)
    }

    private var undatedUnassignedCount: Int {
        chekis.filter {
            $0.imageRef?.nonEmpty == nil && $0.idols.isEmpty && $0.date == nil
                && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs)
        }.count + shames.filter {
            $0.imageRef?.nonEmpty == nil && $0.idols.isEmpty && $0.date == nil
        }.count + dougas.filter {
            $0.videoRef?.nonEmpty == nil && $0.idols.isEmpty && $0.date == nil
        }.count
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    calendarCard
                    if undatedUnassignedCount > 0 {
                        undatedUnassignedCard
                    }
                    selectedDayCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 110)
            }
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle(ChekinanaProductCopy.text("calendar.title", "Calendar"))
            .toolbar {
                ChekinanaPageToolbar(pageID: "calendar", openMenu: openMenu)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAddingRecord = true } label: {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(
                        ChekinanaProductCopy.text("calendar.add_record", "Add record")
                    )
                    .accessibilityIdentifier("chekinana.calendar.add")
                }
            }
            .sheet(item: $selectedGroup) { group in
                ChekinanaCalendarGroupSummary(group: group)
            }
            .sheet(item: $selectedNoMediaRecord) { record in
                ChekinanaCalendarNoMediaRecordEditor(record: record)
            }
            .sheet(isPresented: $isAddingRecord) { ChekinanaCalendarRecordEditor(initialDate: selectedDate) }
            .sheet(isPresented: $isPickingMonth) { ChekinanaMonthPicker(month: $displayedMonth, selectedDate: $selectedDate) }
            .sheet(isPresented: $isUndatedUnassignedPresented) {
                ChekinanaUndatedUnassignedRecordsView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.calendar.page")
        .chekinanaScreenMarker("chekinana.calendar.page")
        .onChange(of: navigationDate) { _, date in
            guard let date else { return }
            selectedDate = date
            displayedMonth = ChekinanaProductDate.startOfMonth(containing: date)
            navigationDate = nil
        }
    }

    private var undatedUnassignedCard: some View {
        ChekinanaSectionCard {
            Button {
                isUndatedUnassignedPresented = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tray.full")
                        .foregroundStyle(ChekinanaProductTheme.accent)
                        .frame(width: 34, height: 34)
                        .background(ChekinanaProductTheme.accent.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ChekinanaProductCopy.text("calendar.undated_unassigned", "Undated & Unassigned"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(ChekinanaProductCopy.format("common.records_count", "%lld records", Int64(undatedUnassignedCount)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chekinana.calendar.undated-unassigned")
        }
    }

    private var calendarCard: some View {
        ChekinanaSectionCard {
            VStack(spacing: 14) {
                HStack {
                    monthButton(systemImage: "chevron.left", offset: -1, id: "previous")
                    Spacer()
                    Button { isPickingMonth = true } label: { Text(ChekinanaProductDate.monthTitle(displayedMonth))
                        .font(.headline)
                        .accessibilityIdentifier("chekinana.calendar.month") }
                    Spacer()
                    monthButton(systemImage: "chevron.right", offset: 1, id: "next")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .background(ChekinanaDesignSystem.accent)
                .clipShape(RoundedRectangle(cornerRadius: ChekinanaDesignSystem.compactRadius))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 7) {
                    ForEach(ChekinanaProductDate.weekdaySymbols, id: \.self) { weekday in
                        Text(weekday)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(cells) { cell in
                        calendarDay(cell)
                    }
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            let offset = value.translation.width < 0 ? 1 : -1
            if let next = ChekinanaProductDate.calendar.date(byAdding: .month, value: offset, to: displayedMonth) { displayedMonth = next; selectedDate = next }
        })
    }

    private func monthButton(systemImage: String, offset: Int, id: String) -> some View {
        Button {
            guard let next = ChekinanaProductDate.calendar.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
            displayedMonth = next
            selectedDate = next
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.bold())
                .frame(width: 44, height: 44)
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.16))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chekinana.calendar.\(id)-month")
    }

    private func calendarDay(_ cell: ChekinanaCalendarCell) -> some View {
        let selected = ChekinanaProductDate.isSameDay(cell.date, selectedDate)
        let chekiCount = chekis.filter {
            ChekinanaProductDate.isSameDay($0.date, cell.date)
                && ChekinanaVisibilityPolicy.includesRecord(
                    idols: $0.idols,
                    hiddenIDs: hiddenIdols.hiddenIDs
                )
        }.count
        return Button {
            let selection = ChekinanaCalendarSelectionPolicy.selecting(
                cell.date,
                displayedMonth: displayedMonth
            )
            selectedDate = selection.selectedDate
            displayedMonth = selection.displayedMonth
        } label: {
            VStack(spacing: 6) {
                Text(ChekinanaProductDate.dayNumber(cell.date))
                    .font(.body.weight(selected ? .bold : .regular))
                    .accessibilityIdentifier(
                        "chekinana.calendar.day-number.\(ChekinanaProductDate.key(cell.date))"
                    )
                HStack(spacing: 3) {
                    if chekiCount > 0 {
                        Text(chekiCount.formatted())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(selected ? .white : ChekinanaProductTheme.accent)
                            .accessibilityIdentifier("chekinana.calendar.count.\(ChekinanaProductDate.key(cell.date))")
                    }
                }
                .frame(height: 10)
            }
            .foregroundStyle(selected ? Color.white : (cell.isInDisplayedMonth ? Color.primary : Color.secondary.opacity(0.55)))
            .frame(
                maxWidth: .infinity,
                minHeight: ChekinanaAccessibilityMetrics.minimumTouchTarget
            )
            .background(selected ? ChekinanaProductTheme.accent : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chekinanaMinimumTouchTarget()
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(ChekinanaProductDate.accessibilityDate(cell.date))
        .accessibilityValue(ChekinanaRecordKind.cheki.countLabel(chekiCount))
        .accessibilityIdentifier("chekinana.calendar.day.\(ChekinanaProductDate.key(cell.date))")
    }

    private var selectedDayCard: some View {
        ChekinanaSectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ChekinanaProductDate.longTitle(selectedDate))
                        .font(.headline)
                        .accessibilityIdentifier("chekinana.calendar.selected-date")
                        .accessibilityValue(ChekinanaProductDate.key(selectedDate))
                    Spacer()
                    Text(ChekinanaRecordKind.cheki.countLabel(selectedChekis.count))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if selectedEvents.isEmpty && selectedChekis.isEmpty && selectedShames.isEmpty && selectedDougas.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar")
                            .foregroundStyle(ChekinanaProductTheme.accent)
                        Text(ChekinanaProductCopy.text("calendar.no_records", "No records for this day"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                    .chekinanaScreenMarker("chekinana.calendar.empty-day")
                } else {
                    ForEach(selectedEvents) { event in
                        HStack(spacing: 12) {
                            Image(systemName: "music.note.house")
                                .foregroundStyle(ChekinanaProductTheme.accent)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.name).font(.subheadline.weight(.semibold))
                                Text(
                                    [event.city?.nonEmpty, event.resolvedLivehouse]
                                        .compactMap { $0 }
                                        .joined(separator: " · ")
                                        .nonEmpty
                                        ?? ChekinanaProductCopy.text("events.event", "Event")
                                )
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(ChekinanaProductTheme.softAccent.opacity(0.72))
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: ChekinanaProductTheme.compactRadius,
                                style: .continuous
                            )
                        )
                    }

                    ForEach(selectedGroups) { group in
                        Button { selectedGroup = group } label: {
                            GeometryReader { geometry in
                                HStack(spacing: 12) {
                                    if let idol = group.idol {
                                        ChekinanaIdolAvatar(idol: idol, size: 46)
                                    } else {
                                        Image(systemName: "person.slash")
                                            .frame(width: 46, height: 46)
                                            .background(Color(uiColor: .tertiarySystemGroupedBackground))
                                            .clipShape(Circle())
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(
                                            ChekinanaRecordKind.cheki.countLabel(
                                                group.chekis.count
                                            )
                                        )
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 6)
                                    let mediaChekis = group.chekis.filter {
                                        $0.imageRef?.nonEmpty != nil
                                    }
                                    if !mediaChekis.isEmpty {
                                        ChekinanaCalendarThumbnailStrip(chekis: mediaChekis)
                                            .frame(maxWidth: geometry.size.width * 0.5, alignment: .trailing)
                                    }
                                }
                            }
                            .frame(height: 62)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(group.name), \(ChekinanaRecordKind.cheki.countLabel(group.chekis.count))"
                        )
                        .accessibilityIdentifier("chekinana.calendar.group.\(group.id)")
                    }
                    ForEach(selectedShames) { item in
                        if item.imageRef?.nonEmpty == nil {
                            Button { selectedNoMediaRecord = .shame(item) } label: {
                                Label(
                                    "\(ChekinanaRecordKind.shame.title) · \(idolNames(item.idols))",
                                    systemImage: "photo"
                                )
                            }
                                .buttonStyle(.plain).accessibilityIdentifier("chekinana.calendar.shame.\(item.id.uuidString.lowercased())")
                        } else {
                            Label(
                                "\(ChekinanaRecordKind.shame.title) · \(idolNames(item.idols))",
                                systemImage: "photo"
                            )
                        }
                    }
                    ForEach(selectedDougas) { item in
                        if item.videoRef?.nonEmpty == nil {
                            Button { selectedNoMediaRecord = .douga(item) } label: {
                                Label(
                                    "\(ChekinanaRecordKind.douga.title) · \(idolNames(item.idols))",
                                    systemImage: "video"
                                )
                            }
                                .buttonStyle(.plain).accessibilityIdentifier("chekinana.calendar.douga.\(item.id.uuidString.lowercased())")
                        } else {
                            Label(
                                "\(ChekinanaRecordKind.douga.title) · \(idolNames(item.idols))",
                                systemImage: "video"
                            )
                        }
                    }
                }
            }
        }
        .chekinanaScreenMarker("chekinana.calendar.selected-day")
    }

    private func idolNames(_ values: [Idol]) -> String {
        values.map(\.name).joined(separator: ", ").nonEmpty
            ?? ChekinanaProductCopy.text("common.unassigned", "Unassigned")
    }
}

private enum ChekinanaCalendarNoMediaRecord: Identifiable {
    case cheki(Cheki)
    case shame(Shame)
    case douga(Douga)
    var id: UUID { switch self { case .cheki(let value): value.id; case .shame(let value): value.id; case .douga(let value): value.id } }
    var listID: String { "\(kind.rawValue)-\(id.uuidString.lowercased())" }
    var kind: ChekinanaRecordKind { switch self { case .cheki: .cheki; case .shame: .shame; case .douga: .douga } }
    var typeName: String { kind.title }
    var createdAt: Date? { switch self { case .cheki(let value): value.createdAt; case .shame, .douga: nil } }
    var date: Date? { switch self { case .cheki(let value): value.date; case .shame(let value): value.date; case .douga(let value): value.date } }
    var note: String { switch self { case .cheki(let value): value.note; case .shame(let value): value.note; case .douga(let value): value.note } }
    var idolIDs: Set<UUID> { switch self { case .cheki(let value): Set(value.idols.map(\.id)); case .shame(let value): Set(value.idols.map(\.id)); case .douga(let value): Set(value.idols.map(\.id)) } }
}

private struct ChekinanaUndatedUnassignedRecordsView: View {
    @Query private var chekis: [Cheki]
    @Query private var shames: [Shame]
    @Query private var dougas: [Douga]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    @State private var selectedRecord: ChekinanaCalendarNoMediaRecord?

    private var records: [ChekinanaCalendarNoMediaRecord] {
        let values = chekis.filter {
            $0.imageRef?.nonEmpty == nil && $0.idols.isEmpty && $0.date == nil
                && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs)
        }.map(ChekinanaCalendarNoMediaRecord.cheki) + shames.filter {
            $0.imageRef?.nonEmpty == nil && $0.idols.isEmpty && $0.date == nil
                && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs)
        }.map(ChekinanaCalendarNoMediaRecord.shame) + dougas.filter {
            $0.videoRef?.nonEmpty == nil && $0.idols.isEmpty && $0.date == nil
                && ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs)
        }.map(ChekinanaCalendarNoMediaRecord.douga)
        let typeOrder: [ChekinanaRecordKind: Int] = [.cheki: 0, .shame: 1, .douga: 2]
        return values.sorted { lhs, rhs in
            let lhsType = typeOrder[lhs.kind] ?? Int.max
            let rhsType = typeOrder[rhs.kind] ?? Int.max
            if lhsType != rhsType { return lhsType < rhsType }
            if lhs.createdAt != rhs.createdAt {
                return (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ChekinanaEmptyState(
                        title: ChekinanaProductCopy.text(
                            "calendar.undated_unassigned",
                            "Undated & Unassigned"
                        ),
                        message: ChekinanaProductCopy.text(
                            "calendar.undated_empty_detail",
                            "Records move out of this list after you add a date or Idol."
                        ),
                        systemImage: "tray"
                    )
                } else {
                    List {
                        ForEach(records, id: \.listID) { record in
                            Button {
                                selectedRecord = record
                            } label: {
                                HStack(spacing: 12) {
                                    Image(
                                        systemName: record.kind == .douga
                                            ? "video" : "photo"
                                    )
                                    .foregroundStyle(ChekinanaProductTheme.accent)
                                    .frame(width: 34, height: 40)
                                    .background(ChekinanaProductTheme.softAccent)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: 9,
                                            style: .continuous
                                        )
                                    )
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.typeName)
                                            .font(.subheadline.weight(.semibold))
                                        Text(
                                            record.note.nonEmpty
                                                ?? ChekinanaProductCopy.text(
                                                    "calendar.no_media_metadata",
                                                    "No media · No date · No Idols"
                                                )
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(
                                "chekinana.calendar.undated-unassigned.\(record.listID)"
                            )
                        }
                    }
                    .listStyle(.insetGrouped)
                    .chekinanaGroupedPageBackground()
                }
            }
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle(
                ChekinanaProductCopy.text(
                    "calendar.undated_unassigned",
                    "Undated & Unassigned"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $selectedRecord) { record in
            ChekinanaCalendarNoMediaRecordEditor(record: record)
        }
    }
}

private struct ChekinanaCalendarNoMediaRecordEditor: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var idols: [Idol]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let record: ChekinanaCalendarNoMediaRecord
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var note: String
    @State private var idolIDs: Set<UUID>
    @State private var choosingIdols = false
    @State private var errorMessage: String?
    init(record: ChekinanaCalendarNoMediaRecord) {
        self.record = record
        _hasDate = State(initialValue: record.date != nil)
        _date = State(initialValue: record.date ?? Date())
        _note = State(initialValue: record.note)
        _idolIDs = State(initialValue: record.idolIDs)
    }
    @ViewBuilder
    var body: some View {
        switch record {
        case .cheki(let value):
            ChekinanaChekiEditorView(cheki: value, allowsDelete: true)
        case .shame, .douga:
            NavigationStack {
                Form {
                    Section(ChekinanaProductCopy.text("common.idols", "Idols")) {
                        ChekinanaIdolAvatarRow(
                            idols: visibleIdols.filter { idolIDs.contains($0.id) },
                            size: 38,
                            showsNames: true
                        )
                        Button(
                            ChekinanaProductCopy.text(
                                "common.change_idols",
                                "Change Idols"
                            )
                        ) {
                            choosingIdols = true
                        }
                        .frame(minHeight: 44)
                    }
                    Section(ChekinanaProductCopy.text("common.metadata", "Metadata")) {
                        Toggle(
                            ChekinanaProductCopy.text(
                                "common.include_date",
                                "Include date"
                            ),
                            isOn: $hasDate
                        )
                        if hasDate {
                            DatePicker(
                                ChekinanaProductCopy.text("common.date", "Date"),
                                selection: $date,
                                displayedComponents: .date
                            )
                        }
                        TextField(
                            ChekinanaProductCopy.text("common.note", "Note"),
                            text: $note,
                            axis: .vertical
                        )
                    }
                    if let errorMessage {
                        Section {
                            ChekinanaInlineStatus(message: errorMessage, kind: .error)
                        }
                    }
                }
                .chekinanaGroupedPageBackground()
                .navigationTitle(
                    ChekinanaProductCopy.format(
                        "calendar.edit_record",
                        "Edit %@",
                        record.typeName
                    )
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(ChekinanaProductCopy.text("common.cancel", "Cancel")) {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(
                            ChekinanaProductCopy.text("common.save", "Save"),
                            action: save
                        )
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button(
                            ChekinanaProductCopy.text("common.delete", "Delete"),
                            role: .destructive,
                            action: delete
                        )
                        .accessibilityIdentifier("chekinana.calendar.no-media.delete")
                    }
                }
            }
            .sheet(isPresented: $choosingIdols) {
                ChekinanaIdolSelectionView(
                    options: visibleIdols.map(ChekinanaIdolSelectionOption.init),
                    selectedIDs: $idolIDs
                )
            }
        }
    }
    private var visibleIdols: [Idol] {
        ChekinanaVisibilityPolicy.visibleIdols(idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }
    private func save() {
        let normalized: Date?
        if hasDate {
            guard let canonical = ChekinanaDateOnly.canonicalDate(
                from: date,
                displayedIn: .current
            ) else {
                errorMessage = ChekinanaProductCopy.text(
                    "error.normalize_date",
                    "Unable to normalize the selected date."
                )
                return
            }
            normalized = canonical
        } else {
            normalized = nil
        }
        do {
            let selectedIdols = try ChekinanaModelContextResolver.idols(
                idolIDs: idolIDs,
                in: modelContext
            )
            switch record { case .cheki: return
            case .shame(let value): value.idols = selectedIdols; value.date = normalized; value.note = note
            case .douga(let value): value.idols = selectedIdols; value.date = normalized; value.note = note }
            try modelContext.save(); dismiss()
        } catch { modelContext.rollback(); errorMessage = error.localizedDescription }
    }
    private func delete() {
        do {
            switch record {
            case .cheki:
                return
            case .shame(let value):
                let target = try ChekinanaModelContextResolver.shame(
                    id: value.id,
                    in: modelContext
                )
                guard target.imageRef?.nonEmpty == nil else {
                    errorMessage = ChekinanaProductCopy.format(
                        "calendar.media_backed_delete",
                        "This %@ now has managed media. Delete it from its media detail page.",
                        ChekinanaRecordKind.shame.title
                    )
                    return
                }
                modelContext.delete(target)
            case .douga(let value):
                let target = try ChekinanaModelContextResolver.douga(
                    id: value.id,
                    in: modelContext
                )
                guard target.videoRef?.nonEmpty == nil else {
                    errorMessage = ChekinanaProductCopy.format(
                        "calendar.media_backed_delete",
                        "This %@ now has managed media. Delete it from its media detail page.",
                        ChekinanaRecordKind.douga.title
                    )
                    return
                }
                modelContext.delete(target)
            }
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct ChekinanaMonthPicker: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Environment(\.dismiss) private var dismiss
    @Binding var month: Date
    @Binding var selectedDate: Date
    @State private var draftDate: Date

    init(month: Binding<Date>, selectedDate: Binding<Date>) {
        _month = month
        _selectedDate = selectedDate
        _draftDate = State(initialValue: selectedDate.wrappedValue)
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        ChekinanaProductCopy.text(
                            "calendar.select_date",
                            "Select date"
                        ),
                        selection: $draftDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("chekinana.calendar.month-picker.date")
                }
            }
            .chekinanaGroupedPageBackground()
            .navigationTitle(
                ChekinanaProductCopy.text("calendar.select_date", "Select date")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaProductCopy.text("common.cancel", "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChekinanaProductCopy.text("common.done", "Done")) {
                        guard let canonical = ChekinanaDateOnly.canonicalDate(
                            from: draftDate,
                            displayedIn: .current
                        ) else { return }
                        month = ChekinanaProductDate.startOfMonth(
                            containing: canonical
                        )
                        selectedDate = canonical
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ChekinanaCalendarRecordBatchPlan: Sendable {
    let kind: ChekinanaRecordKind
    let idolIDs: [UUID]
    let date: Date
    let quantity: Int
    let manualStart: Int?
    let note: String
    let eventID: UUID?
}

enum ChekinanaCalendarRecordQuantityPolicy {
    static func normalized(_ quantity: Int, for kind: ChekinanaRecordKind) -> Int {
        kind == .cheki ? min(max(1, quantity), 100) : 1
    }

    static func accepts(_ quantity: Int, for kind: ChekinanaRecordKind) -> Bool {
        kind == .cheki && (1...100).contains(quantity)
    }
}

@MainActor
enum ChekinanaCalendarRecordBatchWriter {
    static func commit(
        _ plan: ChekinanaCalendarRecordBatchPlan,
        in modelContext: ModelContext
    ) throws -> [UUID] {
        if let mediaError = ChekinanaMediaBackedCreationError(kind: plan.kind) {
            throw mediaError
        }
        guard ChekinanaCalendarRecordQuantityPolicy.accepts(
            plan.quantity,
            for: plan.kind
        ) else {
            throw ChekinanaProductRecordCreationError.invalidBatchQuantity
        }
        let requestedIdolIDs = Set(plan.idolIDs)
        guard !requestedIdolIDs.isEmpty,
              requestedIdolIDs.count == plan.idolIDs.count else {
            throw ChekinanaProductRecordCreationError.modelContextMismatch
        }
        let requestedIDs = Array(requestedIdolIDs)
        let idolDescriptor = FetchDescriptor<Idol>(predicate: #Predicate { idol in
            requestedIDs.contains(idol.id)
        })
        let fetchedIdols = try modelContext.fetch(idolDescriptor)
        let relationships = ChekinanaIdolOrdering.ordered(fetchedIdols)
        guard Set(relationships.map(\.id)) == requestedIdolIDs,
              relationships.allSatisfy({ $0.modelContext === modelContext }) else {
            throw ChekinanaProductRecordCreationError.modelContextMismatch
        }
        let allEvents = try modelContext.fetch(FetchDescriptor<Event>())
        let eventID = plan.eventID ?? ChekinanaChekiEventAutoAssociation.uniqueEventID(
            for: plan.date,
            events: allEvents.map { ($0.id, $0.date) }
        )
        let event = eventID.flatMap { id in allEvents.first { $0.id == id } }

        var insertedIDs: [UUID] = []
        insertedIDs.reserveCapacity(plan.quantity)
        do {
            try modelContext.transaction {
                switch plan.kind {
                case .cheki:
                guard let group = ChekinanaChekiGroupKey(
                    idolIDs: plan.idolIDs,
                    date: plan.date
                ) else {
                    throw ChekinanaProductRecordCreationError.indexOverflow
                }
                let liveSnapshots = try ChekinanaChekiIndexing.snapshots(
                    forCanonicalDate: plan.date,
                    in: modelContext
                )
                let indices = try plannedIndices(
                    group: group,
                    quantity: plan.quantity,
                    manualStart: plan.manualStart,
                    existing: liveSnapshots
                )
                for idx in indices {
                    let cheki = Cheki(
                        date: plan.date,
                        idx: idx,
                        size: .mini,
                        note: plan.note
                    )
                    modelContext.insert(cheki)
                    guard cheki.modelContext === modelContext else {
                        throw ChekinanaProductRecordCreationError.modelContextMismatch
                    }
                    cheki.idols = relationships
                    cheki.event = event
                    insertedIDs.append(cheki.id)
                }
                case .shame:
                    throw ChekinanaMediaBackedCreationError.shameRequiresImage
                case .douga:
                    throw ChekinanaMediaBackedCreationError.dougaRequiresVideo
                }
            }
            return insertedIDs
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    static func plannedIndices(
        group: ChekinanaChekiGroupKey,
        quantity: Int,
        manualStart: Int?,
        existing: [ChekinanaChekiIndexSnapshot]
    ) throws -> [Int] {
        do {
            return try ChekinanaChekiIndexing.batchIndices(
                for: group,
                quantity: quantity,
                manualStart: manualStart,
                existing: existing
            )
        } catch ChekinanaChekiIndexingError.collision {
            throw ChekinanaProductRecordCreationError.indexCollision
        } catch ChekinanaChekiIndexingError.overflow {
            throw ChekinanaProductRecordCreationError.indexOverflow
        }
    }
}

private enum ChekinanaCalendarRecordSaveProgress: Equatable {
    case planning(total: Int)
    case saving(completed: Int, total: Int)

    var completed: Int {
        switch self {
        case .planning: 0
        case .saving(let completed, _): completed
        }
    }

    var total: Int {
        switch self {
        case .planning(let total), .saving(_, let total): total
        }
    }

    var title: String {
        switch self {
        case .planning:
            ChekinanaProductCopy.text("calendar.preparing_records", "Preparing records")
        case .saving(let completed, let total):
            ChekinanaProductCopy.format(
                "calendar.saving_records_progress",
                "Saving %lld/%lld",
                Int64(completed),
                Int64(total)
            )
        }
    }
}

private struct ChekinanaCalendarRecordEditor: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var idols: [Idol]
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    let initialDate: Date
    private let type = ChekinanaRecordKind.cheki
    @State private var date: Date
    @State private var idolID: UUID?
    @State private var quantity = 1
    @State private var idxText = ""
    @State private var note = ""
    @State private var error: String?
    @State private var saveProgress: ChekinanaCalendarRecordSaveProgress?

    private var isSaving: Bool { saveProgress != nil }

    init(initialDate: Date) {
        self.initialDate = initialDate
        _date = State(initialValue: initialDate)
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            Form {
                Section(ChekinanaProductCopy.text("common.metadata", "Metadata")) {
                    LabeledContent(
                        ChekinanaProductCopy.text("common.type", "Type")
                    ) {
                        Text(ChekinanaRecordKind.cheki.title)
                    }
                    .accessibilityIdentifier("chekinana.calendar.add_record.type")
                    DatePicker(
                        ChekinanaProductCopy.text("common.date", "Date"),
                        selection: $date,
                        displayedComponents: .date
                    )
                    Picker(
                        ChekinanaProductCopy.text("common.idol", "Idol"),
                        selection: $idolID
                    ) {
                        Text(
                            ChekinanaProductCopy.text(
                                "calendar.choose_idol",
                                "Choose an Idol"
                            )
                        )
                        .tag(UUID?.none)
                        ForEach(visibleIdols) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Stepper(
                        ChekinanaProductCopy.format(
                            "calendar.quantity_value",
                            "Quantity: %lld",
                            Int64(quantity)
                        ),
                        value: $quantity,
                        in: 1...100
                    )
                    TextField(
                        ChekinanaProductCopy.text(
                            "calendar.starting_index",
                            "Starting index (optional)"
                        ),
                        text: $idxText
                    )
                    .keyboardType(.numberPad)
                    TextField(
                        ChekinanaProductCopy.text("common.note", "Note"),
                        text: $note,
                        axis: .vertical
                    )
                }
                if let error {
                    Section {
                        ChekinanaInlineStatus(message: error, kind: .error)
                    }
                }
                if let saveProgress {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(saveProgress.title)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(saveProgress.completed)/\(saveProgress.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(
                                value: Double(saveProgress.completed),
                                total: Double(max(1, saveProgress.total))
                            )
                            .tint(ChekinanaProductTheme.accent)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("chekinana.calendar.add_record.progress")
                    }
                }
            }
            .chekinanaGroupedPageBackground()
            .navigationTitle(
                ChekinanaProductCopy.text("calendar.add_record", "Add record")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaProductCopy.text("common.cancel", "Cancel")) {
                        dismiss()
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("chekinana.calendar.add_record.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChekinanaProductCopy.text("common.save", "Save")) {
                        beginSave()
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("chekinana.calendar.add_record.save")
                }
            }
            .interactiveDismissDisabled(isSaving)
            .accessibilityIdentifier("chekinana.calendar.add_record.editor")
        }
    }

    private var visibleIdols: [Idol] {
        ChekinanaVisibilityPolicy.visibleIdols(idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }

    private func beginSave() {
        guard !isSaving, let plan = frozenPlan() else { return }
        error = nil
        saveProgress = .planning(total: plan.quantity)
        Task { @MainActor in
            await saveClaimed(plan)
        }
    }

    private func frozenPlan() -> ChekinanaCalendarRecordBatchPlan? {
        guard let selectedID = idolID else {
            error = ChekinanaProductCopy.text(
                "calendar.choose_idol_error",
                "Choose an Idol."
            )
            return nil
        }
        guard let canonical = ChekinanaDateOnly.canonicalDate(
            from: date,
            displayedIn: .current
        ) else {
            error = ChekinanaProductCopy.text(
                "error.normalize_date",
                "Unable to normalize the selected date."
            )
            return nil
        }
        let normalizedIdxText = idxText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let manualStart: Int?
        if type != .cheki || normalizedIdxText.isEmpty {
            manualStart = nil
        } else if let parsed = Int(normalizedIdxText), parsed > 0 {
            manualStart = parsed
        } else {
            error = ChekinanaProductRecordCreationError.invalidIndex.localizedDescription
            return nil
        }
        return ChekinanaCalendarRecordBatchPlan(
            kind: type,
            idolIDs: [selectedID],
            date: canonical,
            quantity: quantity,
            manualStart: manualStart,
            note: note,
            eventID: nil
        )
    }

    @MainActor
    private func saveClaimed(_ plan: ChekinanaCalendarRecordBatchPlan) async {
        defer { saveProgress = nil }
        do {
            if plan.kind == .cheki {
                guard let group = ChekinanaChekiGroupKey(
                    idolIDs: plan.idolIDs,
                    date: plan.date
                ) else {
                    throw ChekinanaProductRecordCreationError.indexOverflow
                }
                let container = modelContext.container
                let snapshotActor = await Task.detached(priority: .userInitiated) {
                    ChekinanaChekiIndexSnapshotActor(modelContainer: container)
                }.value
                let snapshots = try await snapshotActor.snapshots(
                    forCanonicalDate: plan.date
                )
                try Task.checkCancellation()
                _ = try ChekinanaCalendarRecordBatchWriter.plannedIndices(
                    group: group,
                    quantity: plan.quantity,
                    manualStart: plan.manualStart,
                    existing: snapshots
                )
            }
            try Task.checkCancellation()
            saveProgress = .saving(completed: 0, total: plan.quantity)
            _ = try ChekinanaCalendarRecordBatchWriter.commit(
                plan,
                in: modelContext
            )
            saveProgress = .saving(completed: plan.quantity, total: plan.quantity)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ChekinanaCalendarIdolGroup: Identifiable {
    let id: String
    let idol: Idol?
    var chekis: [Cheki]

    var name: String {
        idol?.name ?? ChekinanaProductCopy.text("common.unassigned", "Unassigned")
    }

    static func groups(for chekis: [Cheki]) -> [ChekinanaCalendarIdolGroup] {
        var result: [ChekinanaCalendarIdolGroup] = []
        for cheki in chekis {
            if cheki.idols.isEmpty {
                append(cheki, idol: nil, to: &result)
            } else {
                for idol in cheki.idols {
                    append(cheki, idol: idol, to: &result)
                }
            }
        }
        return result
            .map { group in
                var sorted = group
                sorted.chekis.sort { lhs, rhs in
                    if lhs.idx != rhs.idx { return (lhs.idx ?? Int.max) < (rhs.idx ?? Int.max) }
                    return lhs.createdAt < rhs.createdAt
                }
                return sorted
            }
            .sorted { lhs, rhs in
                if lhs.id == "unassigned" { return false }
                if rhs.id == "unassigned" { return true }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private static func append(
        _ cheki: Cheki,
        idol: Idol?,
        to groups: inout [ChekinanaCalendarIdolGroup]
    ) {
        let key = idol?.id.uuidString.lowercased() ?? "unassigned"
        if let index = groups.firstIndex(where: { $0.id == key }) {
            if !groups[index].chekis.contains(where: { $0.id == cheki.id }) {
                groups[index].chekis.append(cheki)
            }
        } else {
            groups.append(.init(id: key, idol: idol, chekis: [cheki]))
        }
    }
}

private struct ChekinanaCalendarThumbnailStrip: View {
    let chekis: [Cheki]

    var body: some View {
        HStack(spacing: -12) {
            ForEach(Array(chekis.prefix(5).reversed())) { cheki in
                ChekinanaCalendarThumbnail(cheki: cheki, width: 38, height: 50)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct ChekinanaCalendarThumbnail: View {
    let cheki: Cheki
    var width: CGFloat = 50
    var height: CGFloat = 62
    @State private var image: ChekinanaRenderedImage?

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemGroupedBackground)
            if let image {
                Image(decorative: image.cgImage, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: cheki.imageRef) {
            image = await ChekinanaThumbnailCache.shared.thumbnailImage(
                forManagedImageRef: cheki.imageRef,
                key: "product-calendar-\(cheki.id.uuidString)",
                maxDimension: 240
            )
        }
    }
}

private struct ChekinanaCalendarGroupSummary: View {
    @Environment(\.dismiss) private var dismiss
    let group: ChekinanaCalendarIdolGroup
    @State private var selectedChekiID: UUID
    @State private var selectedNoMediaRecord: ChekinanaCalendarNoMediaRecord?

    init(group: ChekinanaCalendarIdolGroup) {
        self.group = group
        _selectedChekiID = State(initialValue: group.chekis.first?.id ?? UUID())
    }

    private var selectedCheki: Cheki? {
        group.chekis.first { $0.id == selectedChekiID } ?? group.chekis.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let mediaChekis = group.chekis.filter {
                        $0.imageRef?.nonEmpty != nil
                    }
                    if !mediaChekis.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(mediaChekis) { cheki in
                                    Button { selectedChekiID = cheki.id } label: {
                                        ChekinanaGalleryCard(cheki: cheki)
                                            .frame(width: 168)
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                                    .stroke(
                                                        selectedChekiID == cheki.id
                                                            ? ChekinanaProductTheme.accent
                                                            : Color.clear,
                                                        lineWidth: 3
                                                    )
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        ChekinanaProductCopy.format(
                                            "calendar.view_cheki",
                                            "View %@",
                                            cheki.idx.map {
                                                "\(ChekinanaRecordKind.cheki.title) #\($0)"
                                            } ?? ChekinanaRecordKind.cheki.title
                                        )
                                    )
                                    .accessibilityIdentifier("chekinana.calendar.group.cheki.\(cheki.id.uuidString.lowercased())")
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .accessibilityIdentifier("chekinana.calendar.group.strip")
                    }
                    ForEach(group.chekis.filter { $0.imageRef?.nonEmpty == nil }) { cheki in
                        Button { selectedChekiID = cheki.id } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(ChekinanaRecordKind.cheki.title)\(cheki.idx.map { " #\($0)" } ?? "")")
                                        .font(.subheadline.weight(.semibold))
                                    Text(
                                        cheki.note.nonEmpty
                                            ?? ChekinanaProductCopy.text(
                                                "common.no_media",
                                                "No media"
                                            )
                                    )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "chekinana.calendar.group.no-media.\(cheki.id.uuidString.lowercased())"
                        )
                    }

                    if let cheki = selectedCheki {
                        ChekinanaSectionCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ChekinanaIdolAvatarRow(idols: cheki.idols, size: 36, showsNames: true)
                                Divider()
                                LabeledContent(
                                    ChekinanaProductCopy.text("common.date", "Date"),
                                    value: ChekinanaProductDate.displayString(cheki.date)
                                )
                                LabeledContent(
                                    ChekinanaProductCopy.text("common.index", "Index"),
                                    value: cheki.idx.map { "#\($0)" }
                                        ?? ChekinanaProductCopy.text(
                                            "common.no_index",
                                            "No index"
                                        )
                                )
                                if let event = cheki.event {
                                    LabeledContent(
                                        ChekinanaProductCopy.text("events.event", "Event"),
                                        value: event.name
                                    )
                                }
                                Text(
                                    cheki.note.nonEmpty
                                        ?? ChekinanaProductCopy.text(
                                            "common.no_note",
                                            "No note"
                                        )
                                )
                                    .foregroundStyle(cheki.note.isEmpty ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if cheki.imageRef?.nonEmpty == nil {
                                    Button(
                                        ChekinanaProductCopy.text(
                                            "calendar.edit_record_action",
                                            "Edit record"
                                        )
                                    ) {
                                        selectedNoMediaRecord = .cheki(cheki)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier(
                                        "chekinana.calendar.group.edit.\(cheki.id.uuidString.lowercased())"
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(ChekinanaProductTheme.pageBackground)
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChekinanaProductCopy.text("common.done", "Done")) {
                        dismiss()
                    }
                        .accessibilityIdentifier("chekinana.calendar.group.done")
                }
            }
        }
        .sheet(item: $selectedNoMediaRecord) { record in
            ChekinanaCalendarNoMediaRecordEditor(record: record)
        }
        .accessibilityIdentifier("chekinana.calendar.group-summary")
        .chekinanaScreenMarker("chekinana.calendar.cheki-summary")
    }
}

struct ChekinanaLocalDataClearResult: Equatable {
    let chekiCount: Int
    let shameCount: Int
    let dougaCount: Int
    let eventCount: Int
    let idolCount: Int
    let removedFileCount: Int
}

enum ChekinanaLocalDataClearError: LocalizedError {
    case database(String)
    case fileCleanup(ChekinanaLocalDataClearResult, [String])

    var errorDescription: String? {
        switch self {
        case .database(let detail):
            return ChekinanaProductCopy.format(
                "settings.clear_error.database",
                "No data was cleared because the local database could not be saved: %@",
                detail
            )
        case .fileCleanup(let result, let failures):
            return ChekinanaProductCopy.format(
                "settings.clear_error.files",
                "All local records were cleared, but %1$lld managed media file(s) could not be removed. Removed %2$lld file(s). %3$@",
                Int64(failures.count),
                Int64(result.removedFileCount),
                failures.joined(separator: "; ")
            )
        }
    }
}

@MainActor
enum ChekinanaLocalDataClearer {
    typealias SaveContext = (ModelContext) throws -> Void
    typealias RemoveFile = (URL) throws -> Void

    @discardableResult
    static func clear(
        modelContext: ModelContext,
        managedImagesDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        saveContext: SaveContext = { try $0.save() },
        removeFile: RemoveFile = { try FileManager.default.removeItem(at: $0) }
    ) throws -> ChekinanaLocalDataClearResult {
        let chekis: [Cheki]
        let shames: [Shame]
        let dougas: [Douga]
        let events: [Event]
        let eventImages: [EventImage]
        let idols: [Idol]
        var eventDeletionRefs: [String] = []
        do {
            chekis = try modelContext.fetch(FetchDescriptor<Cheki>())
            shames = try modelContext.fetch(FetchDescriptor<Shame>())
            dougas = try modelContext.fetch(FetchDescriptor<Douga>())
            events = try modelContext.fetch(FetchDescriptor<Event>())
            eventImages = try modelContext.fetch(FetchDescriptor<EventImage>())
            idols = try modelContext.fetch(FetchDescriptor<Idol>())
            eventDeletionRefs = eventImages.map(\.imageRef) + events.compactMap(\.avatarImageRef)
            ChekinanaEventMediaJournal.queueDeletion(
                eventDeletionRefs,
                defaults: defaults
            )
            chekis.forEach(modelContext.delete)
            shames.forEach(modelContext.delete)
            dougas.forEach(modelContext.delete)
            eventImages.forEach(modelContext.delete)
            events.forEach(modelContext.delete)
            idols.forEach(modelContext.delete)
            try saveContext(modelContext)
        } catch {
            modelContext.rollback()
            ChekinanaEventMediaJournal.cancelDeletion(
                eventDeletionRefs,
                defaults: defaults
            )
            throw ChekinanaLocalDataClearError.database(error.localizedDescription)
        }

        // This flag is deliberately written only after the database commit.
        // It remains enabled for a partial file-cleanup result so a restart
        // cannot silently repopulate an otherwise empty library.
        ChekinanaPresetSeedPolicy.suppress(defaults: defaults)
        ChekinanaHiddenIdolPersistence.save([], defaults: defaults)
        if defaults === UserDefaults.standard {
            ChekinanaHiddenIdolStore.shared.clear()
        }
        ChekinanaCapturedPhotoStore.cleanupStaleFiles()

        let directory: URL
        do {
            directory = try managedImagesDirectory
                ?? ChekiImageRefResolver.chekiImagesDirectory()
        } catch {
            ChekinanaGalleryMediaStore.reconcileQueuesAfterFullClear(
                failedFilenames: nil,
                defaults: defaults
            )
            let result = ChekinanaLocalDataClearResult(
                chekiCount: chekis.count,
                shameCount: shames.count,
                dougaCount: dougas.count,
                eventCount: events.count,
                idolCount: idols.count,
                removedFileCount: 0
            )
            throw ChekinanaLocalDataClearError.fileCleanup(result, [error.localizedDescription])
        }

        let canonicalDirectory = directory.standardizedFileURL
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: canonicalDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            ChekinanaGalleryMediaStore.reconcileQueuesAfterFullClear(
                failedFilenames: nil,
                defaults: defaults
            )
            let result = ChekinanaLocalDataClearResult(
                chekiCount: chekis.count,
                shameCount: shames.count,
                dougaCount: dougas.count,
                eventCount: events.count,
                idolCount: idols.count,
                removedFileCount: 0
            )
            throw ChekinanaLocalDataClearError.fileCleanup(result, [error.localizedDescription])
        }

        var removed = 0
        var failures: [String] = []
        var failedFilenames = Set<String>()
        for entry in entries {
            let canonicalEntry = entry.standardizedFileURL
            guard canonicalEntry.deletingLastPathComponent() == canonicalDirectory else {
                continue
            }
            do {
                let values = try canonicalEntry.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    continue
                }
                try removeFile(canonicalEntry)
                removed += 1
            } catch {
                failedFilenames.insert(entry.lastPathComponent)
                failures.append("\(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }

        ChekinanaGalleryMediaStore.reconcileQueuesAfterFullClear(
            failedFilenames: failedFilenames,
            defaults: defaults
        )

        let result = ChekinanaLocalDataClearResult(
            chekiCount: chekis.count,
            shameCount: shames.count,
            dougaCount: dougas.count,
            eventCount: events.count,
            idolCount: idols.count,
            removedFileCount: removed
        )
        if !failures.isEmpty {
            throw ChekinanaLocalDataClearError.fileCleanup(result, failures)
        }
        return result
    }
}

private struct ChekinanaSettingsView: View {
    @Environment(\.chekinanaLanguageRevision) private var languageRevision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var idols: [Idol]
    @Query private var events: [Event]
    @Query private var chekis: [Cheki]
    @Query private var shames: [Shame]
    @Query private var dougas: [Douga]
    @State private var isClearConfirmationPresented = false
    @State private var clearMessage: String?
    @State private var isClearing = false
    @ObservedObject private var languageStore = ChekinanaLanguageStore.shared
    @ObservedObject private var hiddenIdols = ChekinanaHiddenIdolStore.shared
    @StateObject private var runtimePresentation =
        ChekinanaScannerRuntimePresentationStore.shared

    private var endpointStatus: String {
        switch ChekinanaScannerConfiguration.configuredBaseURL() {
        case .resolved(let url):
            return ChekinanaScannerConfiguration.isProductionProxy(url)
                ? ChekinanaProductCopy.text(
                    "settings.endpoint.production",
                    "Production proxy"
                )
                : ChekinanaProductCopy.text(
                    "settings.endpoint.local",
                    "Local Scanner Debug"
                )
        case .invalid:
            return ChekinanaProductCopy.text(
                "settings.endpoint.invalid",
                "Invalid endpoint configuration"
            )
        }
    }

    private var scannerRuntimeValue: String {
        guard ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled else {
            return ChekinanaProductCopy.text(
                "settings.runtime.paused",
                "Management paused"
            )
        }
        if runtimePresentation.isShuttingDown {
            return ChekinanaProductCopy.text(
                "settings.runtime.shutting_down",
                "Shutting down"
            )
        }
        guard let state = runtimePresentation.status?.state else {
            return ChekinanaProductCopy.text("settings.runtime.unknown", "Unknown")
        }
        switch state {
        case .closed:
            return ChekinanaProductCopy.text("settings.runtime.closed", "Closed")
        case .preparing:
            return ChekinanaGPUStatusPresentation.preparingTitle(
                status: runtimePresentation.status
            )
        case .ready:
            return ChekinanaProductCopy.text("settings.runtime.ready", "Ready")
        }
    }

    var body: some View {
        let _ = languageRevision
        NavigationStack {
            List {
                Section(
                    ChekinanaProductCopy.text(
                        "settings.language",
                        "Language"
                    )
                ) {
                    Picker(
                        ChekinanaProductCopy.text(
                            "settings.language",
                            "Language"
                        ),
                        selection: $languageStore.language
                    ) {
                        ForEach(ChekinanaAppLanguage.allCases) { language in
                            Text(language.title)
                                .tag(language)
                                .accessibilityIdentifier(
                                    "chekinana.settings.language.option.\(language.rawValue)"
                                )
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityValue(languageStore.language.rawValue)
                    .accessibilityIdentifier("chekinana.settings.language.picker")
                }
                Section(ChekinanaProductCopy.text("settings.library", "Local library")) {
                    settingsRow(ChekinanaProductCopy.text("common.idols", "Idols"), value: visibleIdols.count.formatted(), image: "person.2")
                    settingsRow(
                        ChekinanaRecordKind.cheki.title,
                        value: ChekinanaRecordKind.cheki.countLabel(visibleChekis.count),
                        image: "photo.stack"
                    )
                    settingsRow(ChekinanaRecordKind.shame.title, value: visibleShames.count.formatted(), image: "photo")
                    settingsRow(ChekinanaRecordKind.douga.title, value: visibleDougas.count.formatted(), image: "video")
                    settingsRow(ChekinanaProductCopy.text("events.title", "Events"), value: events.count.formatted(), image: "ticket")
                }
                Section(ChekinanaProductCopy.text("settings.hidden_idols", "Hidden Idols")) {
                    if hiddenIdolModels.isEmpty {
                        Text(ChekinanaProductCopy.text("settings.hidden_idols.empty", "No hidden Idols"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(hiddenIdolModels) { idol in
                            HStack(spacing: 12) {
                                ChekinanaIdolAvatar(idol: idol, size: 38)
                                Text(idol.name)
                                Spacer()
                                Button(ChekinanaProductCopy.text("idols.unhide", "Unhide")) {
                                    hiddenIdols.unhide(idol.id)
                                }
                                .accessibilityIdentifier("chekinana.settings.hidden-idols.unhide.\(idol.id.uuidString.lowercased())")
                            }
                        }
                    }
                }
                .accessibilityIdentifier("chekinana.settings.hidden-idols")
                Section(ChekinanaProductCopy.text("settings.scanner", "Scanner")) {
                    settingsRow(ChekinanaProductCopy.text("settings.proxy", "Proxy"), value: endpointStatus, image: "network")
                    settingsRow(
                        ChekinanaProductCopy.text("settings.runtime", "Runtime"),
                        value: scannerRuntimeValue,
                        image: !runtimePresentation.isShuttingDown
                            && runtimePresentation.status?.state == .ready
                            ? "checkmark.circle"
                            : "server.rack"
                    )
                }
                Section {
                    Label(
                        ChekinanaProductCopy.text(
                            "settings.privacy.detail",
                            "Date and Idol recognition are on by default; the Unassigned candidate is off. Images are stored locally; detection overlays are never written into saved or downloaded images."
                        ),
                        systemImage: "hand.raised"
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(ChekinanaProductCopy.text("settings.privacy", "Privacy & behavior"))
                }
                Section {
                    LabeledContent(
                        ChekinanaProductCopy.text("settings.app", "App"),
                        value: "Chekinana"
                    )
                    LabeledContent(
                        ChekinanaProductCopy.text("settings.storage", "Storage"),
                        value: ChekinanaProductCopy.text(
                            "settings.storage.local",
                            "On this device"
                        )
                    )
                } footer: {
                    Text(
                        ChekinanaProductCopy.text(
                            "settings.account.footer",
                            "This screen does not provide an account, cloud sync, or social posting."
                        )
                    )
                }
                Section(ChekinanaProductCopy.text("settings.data", "Data management")) {
                    Button(role: .destructive) {
                        isClearConfirmationPresented = true
                    } label: {
                        if isClearing {
                            HStack {
                                ProgressView()
                                Text(
                                    ChekinanaProductCopy.text(
                                        "settings.clearing",
                                        "Clearing all data…"
                                    )
                                )
                            }
                        } else {
                            Label(
                                ChekinanaProductCopy.text(
                                    "settings.clear_all",
                                    "Clear all data"
                                ),
                                systemImage: "trash"
                            )
                        }
                    }
                    .disabled(isClearing)
                    .accessibilityIdentifier("chekinana.settings.clear-data")
                    .listRowBackground(Color.red.opacity(0.06))
                    Text(
                        ChekinanaProductCopy.text(
                            "settings.clear_scope",
                            "Deletes this app's local records and managed media. Photos, settings, and remote data are not changed."
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ChekinanaDesignSystem.pageBackground)
            .navigationTitle(ChekinanaProductCopy.text("settings.title", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChekinanaProductCopy.text("common.done", "Done")) { dismiss() }
                        .accessibilityIdentifier("chekinana.settings.done")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.settings.page")
        .chekinanaScreenMarker("chekinana.settings.page")
        .onAppear {
            hiddenIdols.prune(knownIdolIDs: Set(idols.map(\.id)))
        }
        .confirmationDialog(
            ChekinanaProductCopy.text(
                "settings.clear_confirm.title",
                "Clear all local data?"
            ),
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                ChekinanaProductCopy.text("settings.clear_all", "Clear all data"),
                role: .destructive
            ) { clearAllData() }
                .accessibilityIdentifier("chekinana.settings.clear-data.confirm")
            Button(ChekinanaProductCopy.text("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                ChekinanaProductCopy.text(
                    "settings.clear_confirm.message",
                    "This permanently removes every local record and app-managed media file. It does not affect Photos or remote services."
                )
            )
        }
        .alert(ChekinanaProductCopy.text("settings.local_data", "Local data"), isPresented: Binding(
            get: { clearMessage != nil },
            set: { if !$0 { clearMessage = nil } }
        )) {
            Button(ChekinanaProductCopy.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(clearMessage ?? "")
        }
    }

    private var visibleIdols: [Idol] {
        ChekinanaVisibilityPolicy.visibleIdols(idols, hiddenIDs: hiddenIdols.hiddenIDs)
    }

    private var hiddenIdolModels: [Idol] {
        ChekinanaIdolOrdering.ordered(idols.filter { hiddenIdols.hiddenIDs.contains($0.id) })
    }

    private var visibleChekis: [Cheki] {
        chekis.filter { ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }
    }

    private var visibleShames: [Shame] {
        shames.filter { ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }
    }

    private var visibleDougas: [Douga] {
        dougas.filter { ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIdols.hiddenIDs) }
    }

    private func settingsRow(_ title: String, value: String, image: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: image).foregroundStyle(ChekinanaProductTheme.accent).frame(width: 26)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .frame(minHeight: 44)
    }

    private func clearAllData() {
        isClearing = true
        defer { isClearing = false }
        do {
            let result = try ChekinanaLocalDataClearer.clear(modelContext: modelContext)
            clearMessage = ChekinanaProductCopy.format(
                "settings.clear_result",
                "Cleared %1$lld Cheki, %2$lld phone photos, %3$lld videos, %4$lld Events, %5$lld Idols, and %6$lld managed media files.",
                Int64(result.chekiCount),
                Int64(result.shameCount),
                Int64(result.dougaCount),
                Int64(result.eventCount),
                Int64(result.idolCount),
                Int64(result.removedFileCount)
            )
        } catch {
            clearMessage = error.localizedDescription
        }
    }
}

struct ChekinanaCalendarCell: Identifiable {
    let date: Date
    let isInDisplayedMonth: Bool
    var id: String { ChekinanaProductDate.key(date) }
}

enum ChekinanaProductDate {
    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 1
        return value
    }()

    static var weekdaySymbols: [String] {
        let formatter = DateFormatter()
        formatter.locale = ChekinanaLanguagePreference.displayLocale()
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter.shortStandaloneWeekdaySymbols
    }

    static var fixtureAwareToday: Date {
#if DEBUG
        if ProcessInfo.processInfo.environment["CHEKINANA_PRODUCT_UI_FIXTURE"] == "data" {
            return date(year: 2026, month: 8, day: 2)
        }
#endif
        return today
    }

    static var today: Date {
        ChekinanaDateOnly.canonicalDate(from: Date(), displayedIn: .current) ?? Date()
    }

    static func normalized(_ date: Date) -> Date {
        ChekinanaDateOnly.canonicalized(date) ?? date
    }

    static func date(year: Int, month: Int, day: Int) -> Date {
        ChekinanaDateOnly.canonicalDate(year: year, month: month, day: day)!
    }

    static func startOfMonth(containing date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? normalized(date)
    }

    static func monthCells(for month: Date) -> [ChekinanaCalendarCell] {
        let first = startOfMonth(containing: month)
        let weekday = calendar.component(.weekday, from: first)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -leadingDays, to: first) ?? first
        let daysInMonth = calendar.range(of: .day, in: .month, for: first)?.count ?? 31
        let weekCount = max(4, (leadingDays + daysInMonth + 6) / 7)
        return (0..<(weekCount * 7)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return ChekinanaCalendarCell(
                date: date,
                isInDisplayedMonth: calendar.isDate(date, equalTo: first, toGranularity: .month)
            )
        }
    }

    static func isSameDay(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else { return false }
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }

    static func key(_ date: Date) -> String {
        ChekinanaDateOnly.string(date)
    }

    static func string(_ date: Date?) -> String {
        guard let date else { return "" }
        return ChekinanaDateOnly.string(date)
    }

    static func displayString(_ date: Date?) -> String {
        guard let date else {
            return ChekinanaProductCopy.text("common.no_date", "No date")
        }
        return formatted(date, template: "yMMMd")
    }

    static func monthTitle(_ date: Date) -> String { formatted(date, template: "yMMMM") }
    static func longTitle(_ date: Date) -> String { formatted(date, template: "MMMMdEEEE") }
    static func accessibilityDate(_ date: Date) -> String { formatted(date, template: "yMMMMd") }
    static func dayNumber(
        _ date: Date,
        locale: Locale? = nil
    ) -> String {
        calendar.component(.day, from: date).formatted(
            .number
                .locale(locale ?? ChekinanaLanguagePreference.displayLocale())
                .grouping(.never)
        )
    }

    private static func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = ChekinanaLanguagePreference.displayLocale()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

private enum ChekinanaProductColor {
    static func color(for value: String?) -> Color {
        let normalized = value?.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        if let paletteName = ChekinanaIdolPalette.presetName(hex: normalized) {
            // Legacy RGB uses a fixed colour only when it is an exact source
            // preset; non-preset values remain their original sRGB colour.
            return color(for: paletteName)
        }
        if normalized.count == 7,
           normalized.first == "#",
           let raw = UInt32(normalized.dropFirst(), radix: 16) {
            return Color(red: Double((raw >> 16) & 0xFF) / 255, green: Double((raw >> 8) & 0xFF) / 255, blue: Double(raw & 0xFF) / 255)
        }
        switch normalized {
        case "紫", "紫色", "purple": return .purple
        case "粉", "粉色", "pink": return .pink
        case "红", "红色", "red": return .red
        case "蓝", "蓝色", "blue": return .blue
        case "水", "水色": return Color(red: 129 / 255, green: 212 / 255, blue: 250 / 255)
        case "绿", "绿色", "green": return .green
        case "橙", "橙色", "orange": return .orange
        case "黄", "黄色", "yellow": return .yellow
        case "白", "白色", "white": return Color(red: 224 / 255, green: 224 / 255, blue: 224 / 255)
        default: return ChekinanaProductTheme.accent
        }
    }
}

extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

#if DEBUG
@MainActor
enum ChekinanaProductUITestFixture {
    static func seedIfRequested(in container: ModelContainer) {
        guard let fixture = ProcessInfo.processInfo.environment["CHEKINANA_PRODUCT_UI_FIXTURE"],
              fixture == "data" || fixture == "mixed-media" else {
            return
        }
        let context = ModelContext(container)
        guard (try? context.fetchCount(FetchDescriptor<Idol>())) == 0,
              (try? context.fetchCount(FetchDescriptor<Cheki>())) == 0 else {
            return
        }

        let idol1 = Idol(name: "Airi", group: "Moonlight", color: "紫色", birthday: "03.14", note: "Soft vocals and violet light.")
        let idol2 = Idol(name: "Mina", group: "Moonlight", color: "粉色", birthday: "09.08", note: "Lives for the encore.")
        let idol3 = Idol(name: "Rin", group: "Satellite", color: "蓝色", note: "")
        idol1.avatarImageRef = makeFixtureAvatar(
            for: idol1.id,
            color: UIColor(red: 0.48, green: 0.27, blue: 0.66, alpha: 1)
        )
        idol2.avatarImageRef = makeFixtureAvatar(
            for: idol2.id,
            color: UIColor(red: 0.92, green: 0.42, blue: 0.62, alpha: 1)
        )
        idol3.avatarImageRef = makeFixtureAvatar(
            for: idol3.id,
            color: UIColor(red: 0.22, green: 0.62, blue: 0.72, alpha: 1)
        )
        idol2.patterns = [ChekinanaPresetIdolSeeder.prototypeVectors[0]]
        idol3.patterns = Array(ChekinanaPresetIdolSeeder.prototypeVectors.prefix(2))
        [idol1, idol2, idol3].forEach(context.insert)

        let event1 = Event(name: "Moonlight Summer Live", date: ChekinanaProductDate.date(year: 2026, month: 8, day: 2), city: "Shanghai", livehouse: "MAO Livehouse")
        let event2 = Event(name: "Satellite Mini Tour", date: ChekinanaProductDate.date(year: 2026, month: 8, day: 6), city: "Hangzhou", livehouse: "Echo Space")
        context.insert(event1)
        context.insert(event2)
        guard [idol1, idol2, idol3].allSatisfy({ $0.modelContext === context }),
              event1.modelContext === context,
              event2.modelContext === context else { return }

        let specs: [(Date, [Idol], Event?, Int, UIColor, Bool, String, Bool?)] = [
            (ChekinanaProductDate.date(year: 2026, month: 8, day: 2), [idol1], event1, 1, UIColor(red: 0.48, green: 0.27, blue: 0.66, alpha: 1), true, "First summer set", nil),
            (ChekinanaProductDate.date(year: 2026, month: 8, day: 2), [idol2], event1, 1, UIColor(red: 0.92, green: 0.42, blue: 0.62, alpha: 1), false, "Encore pose", false),
            (ChekinanaProductDate.date(year: 2026, month: 8, day: 6), [idol1, idol2], event2, 1, UIColor(red: 0.34, green: 0.55, blue: 0.82, alpha: 1), true, "Two-shot", true),
            (ChekinanaProductDate.date(year: 2026, month: 8, day: 1), [idol3], nil, 1, UIColor(red: 0.22, green: 0.62, blue: 0.72, alpha: 1), false, "", nil)
        ]

        for spec in specs {
            let cheki = Cheki(
                date: spec.0,
                idx: spec.3,
                userAppears: spec.7,
                size: .mini,
                isFavorite: spec.5,
                note: spec.6
            )
            if let ref = makeFixtureImage(for: cheki.id, color: spec.4) {
                cheki.imageRef = ref
            }
            context.insert(cheki)
            guard cheki.modelContext === context else { return }
            cheki.idols = spec.1
            cheki.event = spec.2
        }
        if fixture == "mixed-media" {
            let shameID = UUID()
            if let data = makeFixtureJPEGData(
                color: UIColor(red: 0.83, green: 0.38, blue: 0.48, alpha: 1)
            ), let reference = try? ChekinanaGalleryMediaStore.saveImage(
                data,
                id: shameID,
                filenameExtension: "jpg"
            ) {
                let shame = Shame(
                    id: shameID,
                    imageRef: reference,
                    date: specs[0].0,
                    note: "Fixture Shame"
                )
                context.insert(shame)
                guard shame.modelContext === context else { return }
                shame.idols = [idol1]
            }

            let dougaID = UUID()
            if let data = makeFixtureJPEGData(
                color: UIColor(red: 0.20, green: 0.55, blue: 0.82, alpha: 1)
            ) {
                let thumbnailURL = ChekinanaGalleryMediaStore.thumbnailURL(id: dougaID)
                try? FileManager.default.createDirectory(
                    at: thumbnailURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: thumbnailURL, options: .atomic)
            }
            let fixtureVideoReference = "douga-\(dougaID.uuidString.lowercased()).mp4"
            if let directory = try? ChekiImageRefResolver.chekiImagesDirectory() {
                // The mixed-media UI fixture exercises the video-backed card
                // canvas without invoking playback. Keep it media-backed with
                // an app-owned regular file and a separately valid thumbnail.
                try? Data("chekinana-ui-video-fixture".utf8).write(
                    to: directory.appendingPathComponent(fixtureVideoReference),
                    options: .atomic
                )
            }
            let douga = Douga(
                id: dougaID,
                videoRef: fixtureVideoReference,
                date: specs[2].0,
                note: "Fixture Douga"
            )
            context.insert(douga)
            guard douga.modelContext === context else { return }
            douga.idols = [idol2]
        }
        try? context.save()
    }

    private static func makeFixtureJPEGData(color: UIColor) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 540, height: 720),
            format: format
        )
        let image = renderer.image { context in
            UIColor(white: 0.96, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 540, height: 720))
            color.setFill()
            context.cgContext.fill(CGRect(x: 24, y: 24, width: 492, height: 620))
        }
        return image.jpegData(compressionQuality: 0.9)
    }

    private static func makeFixtureImage(for id: UUID, color: UIColor) -> String? {
        guard let directory = try? ChekiImageRefResolver.chekiImagesDirectory() else { return nil }
        let filename = "\(id.uuidString).jpg"
        let url = directory.appendingPathComponent(filename)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 540, height: 720), format: format)
        let image = renderer.image { context in
            UIColor(white: 0.97, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 540, height: 720))
            color.setFill()
            context.cgContext.fill(CGRect(x: 34, y: 34, width: 472, height: 570))
            UIColor.white.withAlphaComponent(0.18).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 130, y: 140, width: 280, height: 280))
            UIColor(white: 0.25, alpha: 0.75).setFill()
            let text = "CHEKINANA"
            text.draw(at: CGPoint(x: 34, y: 646), withAttributes: [
                .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: UIColor(white: 0.25, alpha: 0.75),
            ])
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    private static func makeFixtureAvatar(for id: UUID, color: UIColor) -> String? {
        guard let directory = try? ChekiImageRefResolver.chekiImagesDirectory() else { return nil }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let filename = "idol-\(id.uuidString.lowercased()).jpg"
        let url = directory.appendingPathComponent(filename)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 256, height: 256),
            format: format
        )
        let image = renderer.image { context in
            UIColor(white: 0.97, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 18, y: 18, width: 220, height: 220))
            UIColor.white.withAlphaComponent(0.7).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 80, y: 48, width: 96, height: 96))
            context.cgContext.fillEllipse(in: CGRect(x: 55, y: 140, width: 146, height: 100))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }
}
#endif

#Preview {
    ChekinanaProductShell()
        .modelContainer(
            for: [Idol.self, Event.self, EventImage.self, Cheki.self, Shame.self, Douga.self],
            inMemory: true
        )
}

import Foundation
import SwiftUI

enum ChekinanaHiddenIdolPersistence {
    static let defaultsKey = "chekinana.hidden-idol-ids.v1"

    static func load(defaults: UserDefaults = .standard) -> Set<UUID> {
        Set((defaults.array(forKey: defaultsKey) as? [String] ?? []).compactMap(UUID.init))
    }

    static func save(_ ids: Set<UUID>, defaults: UserDefaults = .standard) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: defaultsKey)
    }
}

enum ChekinanaVisibilityPolicy {
    static func includesIdol(_ id: UUID, hiddenIDs: Set<UUID>) -> Bool {
        !hiddenIDs.contains(id)
    }

    static func includesRecord(idolIDs: some Sequence<UUID>, hiddenIDs: Set<UUID>) -> Bool {
        idolIDs.allSatisfy { !hiddenIDs.contains($0) }
    }

    static func visibleIdols(_ idols: [Idol], hiddenIDs: Set<UUID>) -> [Idol] {
        idols.filter { includesIdol($0.id, hiddenIDs: hiddenIDs) }
    }

    static func includesRecord(idols: [Idol], hiddenIDs: Set<UUID>) -> Bool {
        includesRecord(idolIDs: idols.map(\.id), hiddenIDs: hiddenIDs)
    }
}

@MainActor
final class ChekinanaHiddenIdolStore: ObservableObject {
    static let shared = ChekinanaHiddenIdolStore()

    @Published private(set) var hiddenIDs: Set<UUID>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenIDs = ChekinanaHiddenIdolPersistence.load(defaults: defaults)
    }

    func hide(_ id: UUID) {
        guard hiddenIDs.insert(id).inserted else { return }
        persist()
    }

    func unhide(_ id: UUID) {
        guard hiddenIDs.remove(id) != nil else { return }
        persist()
    }

    func removeDeleted(_ id: UUID) { unhide(id) }

    func prune(knownIdolIDs: Set<UUID>) {
        let retained = hiddenIDs.intersection(knownIdolIDs)
        guard retained != hiddenIDs else { return }
        hiddenIDs = retained
        persist()
    }

    func clear() {
        guard !hiddenIDs.isEmpty else { return }
        hiddenIDs.removeAll()
        persist()
    }

    private func persist() {
        ChekinanaHiddenIdolPersistence.save(hiddenIDs, defaults: defaults)
    }
}

enum ChekinanaAppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    static func resolve(_ rawValue: String?) -> ChekinanaAppLanguage {
        rawValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    var title: String {
        switch self {
        case .system:
            ChekinanaProductCopy.text("settings.language.system", "Follow System")
        case .simplifiedChinese:
            ChekinanaProductCopy.text("settings.language.zh_hans", "简体中文")
        case .english:
            ChekinanaProductCopy.text("settings.language.en", "English")
        case .japanese:
            ChekinanaProductCopy.text("settings.language.ja", "日本語")
        }
    }
}

enum ChekinanaLanguagePreference {
    static let defaultsKey = "chekinana.app-language"

    static func language(defaults: UserDefaults = .standard) -> ChekinanaAppLanguage {
        ChekinanaAppLanguage.resolve(defaults.string(forKey: defaultsKey))
    }

    static func set(
        _ language: ChekinanaAppLanguage,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(language.rawValue, forKey: defaultsKey)
    }

    static func displayLocale(
        for language: ChekinanaAppLanguage? = nil,
        systemLocale: Locale = .current
    ) -> Locale {
        let resolved = language ?? self.language()
        return resolved == .system ? systemLocale : Locale(identifier: resolved.rawValue)
    }

    static func localizationBundle(
        for language: ChekinanaAppLanguage? = nil,
        candidates: [Bundle] = [Bundle.main]
    ) -> Bundle {
        let resolved = language ?? self.language()
        let fallback = candidates.first ?? .main
        guard resolved != .system else { return fallback }
        for candidate in candidates {
            guard let path = candidate.path(
                forResource: resolved.rawValue,
                ofType: "lproj"
            ), let bundle = Bundle(path: path) else { continue }
            return bundle
        }
        return fallback
    }
}

@MainActor
final class ChekinanaLanguageStore: ObservableObject {
    static let shared = ChekinanaLanguageStore()

    private var storedLanguage: ChekinanaAppLanguage
    private(set) var revision: UInt64 = 0

    var language: ChekinanaAppLanguage {
        get { storedLanguage }
        set {
            guard newValue != storedLanguage else { return }
            // ProductCopy resolves its bundle from the persisted preference.
            // Persist before publishing so this same render pass sees the new
            // bundle rather than requiring navigation or relaunch.
            ChekinanaLanguagePreference.set(newValue)
            objectWillChange.send()
            storedLanguage = newValue
            revision &+= 1
        }
    }

    var displayLocale: Locale {
        ChekinanaLanguagePreference.displayLocale(for: language)
    }

    private init() {
        storedLanguage = ChekinanaLanguagePreference.language()
    }
}

private struct ChekinanaLanguageRevisionKey: EnvironmentKey {
    static let defaultValue: UInt64 = 0
}

extension EnvironmentValues {
    var chekinanaLanguageRevision: UInt64 {
        get { self[ChekinanaLanguageRevisionKey.self] }
        set { self[ChekinanaLanguageRevisionKey.self] = newValue }
    }
}

enum ChekinanaL10n {
    static func text(_ key: String, fallback: String, bundle: Bundle? = nil) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: bundle ?? ChekinanaLanguagePreference.localizationBundle(),
            value: fallback,
            comment: ""
        )
    }

    static func format(
        _ key: String,
        fallback: String,
        bundle: Bundle? = nil,
        locale: Locale? = nil,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: text(key, fallback: fallback, bundle: bundle),
            locale: locale ?? ChekinanaLanguagePreference.displayLocale(),
            arguments: arguments
        )
    }

    /// The app currently ships English, Simplified Chinese, and Japanese. A
    /// compact one/other split keeps quantity copy grammatical without making
    /// business logic depend on a translated string.
    static func quantity(
        _ key: String,
        count: Int,
        one: String,
        other: String,
        bundle: Bundle? = nil,
        locale: Locale? = nil
    ) -> String {
        format(
            "\(key).\(count == 1 ? "one" : "other")",
            fallback: count == 1 ? one : other,
            bundle: bundle,
            locale: locale,
            Int64(count)
        )
    }
}

enum ChekinanaRecordKind: String, CaseIterable, Sendable, Identifiable, Hashable {
    case cheki
    case shame
    case douga

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cheki: ChekinanaL10n.text("record.cheki", fallback: "Cheki")
        case .shame: ChekinanaL10n.text("record.shame", fallback: "Phone Photo")
        case .douga: ChekinanaL10n.text("record.douga", fallback: "Video")
        }
    }

    func countLabel(
        _ count: Int,
        bundle: Bundle? = nil,
        locale: Locale? = nil
    ) -> String {
        switch self {
        case .cheki:
            return ChekinanaL10n.quantity(
                "record.kind_count.cheki",
                count: count,
                one: "%lld Cheki",
                other: "%lld chekis",
                bundle: bundle,
                locale: locale
            )
        case .shame:
            return ChekinanaL10n.quantity(
                "record.kind_count.shame",
                count: count,
                one: "%lld Phone Photo",
                other: "%lld Phone Photos",
                bundle: bundle,
                locale: locale
            )
        case .douga:
            return ChekinanaL10n.quantity(
                "record.kind_count.douga",
                count: count,
                one: "%lld Video",
                other: "%lld Videos",
                bundle: bundle,
                locale: locale
            )
        }
    }
}

enum ChekinanaMediaBackedCreationError: LocalizedError, Equatable {
    case shameRequiresImage
    case dougaRequiresVideo

    init?(kind: ChekinanaRecordKind) {
        switch kind {
        case .cheki: return nil
        case .shame: self = .shameRequiresImage
        case .douga: self = .dougaRequiresVideo
        }
    }

    var errorDescription: String? {
        switch self {
        case .shameRequiresImage:
            ChekinanaProductCopy.text(
                "error.shame_requires_image",
                "Phone Photo records require an image. Add them from Gallery."
            )
        case .dougaRequiresVideo:
            ChekinanaProductCopy.text(
                "error.douga_requires_video",
                "Video records require a video. Add them from Gallery."
            )
        }
    }
}

enum ChekinanaDisplayFormat {
    static func date(_ canonicalDate: Date, calendar: Calendar = .current) -> String {
        let displayedDate = ChekinanaDateOnly.displayDate(
            from: canonicalDate,
            calendar: calendar
        ) ?? canonicalDate
        let formatter = DateFormatter()
        formatter.locale = ChekinanaLanguagePreference.displayLocale()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: displayedDate)
    }

    static func date(_ canonicalValue: String, calendar: Calendar = .current) -> String {
        guard let date = ChekinanaDateOnly.parse(canonicalValue) else {
            return canonicalValue
        }
        return self.date(date, calendar: calendar)
    }
}

extension ChekinanaIdolPalette {
    static func localizedTitle(forStorageValue rawValue: String) -> String {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "绿色": ChekinanaL10n.text("idol.color.green", fallback: "Green")
        case "蓝色": ChekinanaL10n.text("idol.color.blue", fallback: "Blue")
        case "水色": ChekinanaL10n.text("idol.color.light_blue", fallback: "Light Blue")
        case "紫色": ChekinanaL10n.text("idol.color.purple", fallback: "Purple")
        case "粉色": ChekinanaL10n.text("idol.color.pink", fallback: "Pink")
        case "红色": ChekinanaL10n.text("idol.color.red", fallback: "Red")
        case "橙色": ChekinanaL10n.text("idol.color.orange", fallback: "Orange")
        case "黄色": ChekinanaL10n.text("idol.color.yellow", fallback: "Yellow")
        case "白色": ChekinanaL10n.text("idol.color.white", fallback: "White")
        default: rawValue
        }
    }

    static func storageValue(forLocalizedTitle rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixedValues = [
            ("绿色", ChekinanaL10n.text("idol.color.green", fallback: "Green")),
            ("蓝色", ChekinanaL10n.text("idol.color.blue", fallback: "Blue")),
            ("水色", ChekinanaL10n.text("idol.color.light_blue", fallback: "Light Blue")),
            ("紫色", ChekinanaL10n.text("idol.color.purple", fallback: "Purple")),
            ("粉色", ChekinanaL10n.text("idol.color.pink", fallback: "Pink")),
            ("红色", ChekinanaL10n.text("idol.color.red", fallback: "Red")),
            ("橙色", ChekinanaL10n.text("idol.color.orange", fallback: "Orange")),
            ("黄色", ChekinanaL10n.text("idol.color.yellow", fallback: "Yellow")),
            ("白色", ChekinanaL10n.text("idol.color.white", fallback: "White")),
        ]
        return fixedValues.first {
            $0.1.caseInsensitiveCompare(value) == .orderedSame
        }?.0 ?? rawValue
    }
}

enum ChekinanaDesignSystem {
    static let accent = Color(red: 0.31, green: 0.20, blue: 0.48)
    static let softAccent = Color(red: 0.94, green: 0.92, blue: 0.97)
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let border = Color(uiColor: .separator).opacity(0.22)
    static let cardRadius: CGFloat = 16
    static let compactRadius: CGFloat = 12
    static let pageSpacing: CGFloat = 16
}

enum ChekinanaProductCopy {
    static func text(
        _ key: String,
        _ fallback: String,
        bundle: Bundle? = nil
    ) -> String {
        ChekinanaL10n.text("product.\(key)", fallback: fallback, bundle: bundle)
    }

    static func format(
        _ key: String,
        _ fallback: String,
        bundle: Bundle? = nil,
        locale: Locale? = nil,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: text(key, fallback, bundle: bundle),
            locale: locale ?? ChekinanaLanguagePreference.displayLocale(),
            arguments: arguments
        )
    }

    static func quantity(
        _ key: String,
        count: Int,
        one: String,
        other: String,
        bundle: Bundle? = nil,
        locale: Locale? = nil
    ) -> String {
        format(
            "\(key).\(count == 1 ? "one" : "other")",
            count == 1 ? one : other,
            bundle: bundle,
            locale: locale,
            Int64(count)
        )
    }
}

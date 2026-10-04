import AVFoundation
import Foundation
import os
import SwiftUI
import SwiftData

enum ChekinanaMediaPlaybackAudioSession {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Chekinana",
        category: "media-playback-audio-session"
    )

    @discardableResult
    static func activate(mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions = []) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: mode, options: options)
            try session.setActive(true)
            return true
        } catch {
            logger.error(
                "Unable to activate media playback audio session: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

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

/// Display-only rules for Scan, Idols, Gallery and Calendar. Storage and
/// shared Event/command eligibility continue to use their original policies.
private struct ChekinanaDisplayHiddenIdolIDsKey: EnvironmentKey {
    static let defaultValue: Set<UUID> = []
}

extension EnvironmentValues {
    var chekinanaDisplayHiddenIdolIDs: Set<UUID> {
        get { self[ChekinanaDisplayHiddenIdolIDsKey.self] }
        set { self[ChekinanaDisplayHiddenIdolIDsKey.self] = newValue }
    }
}

enum ChekinanaFourPageVisibilityPolicy {
    static func includesRecord(idolIDs: some Sequence<UUID>, hiddenIDs: Set<UUID>) -> Bool {
        let ids = Set(idolIDs)
        return ids.isEmpty || !ids.isSubset(of: hiddenIDs)
    }

    static func includesRecord(idols: [Idol], hiddenIDs: Set<UUID>) -> Bool {
        includesRecord(idolIDs: idols.map(\.id), hiddenIDs: hiddenIDs)
    }

    static func visibleIdols(_ idols: [Idol], hiddenIDs: Set<UUID>) -> [Idol] {
        ChekinanaVisibilityPolicy.visibleIdols(idols, hiddenIDs: hiddenIDs)
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
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }

    static func resolve(_ rawValue: String?) -> ChekinanaAppLanguage {
        rawValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    static var settingsVisibleCases: [ChekinanaAppLanguage] { allCases }

    var title: String {
        switch self {
        case .system:
            ChekinanaProductCopy.text("settings.language.system", "Follow System")
        case .simplifiedChinese:
            "简体中文"
        case .traditionalChinese:
            "繁體中文"
        case .english:
            "English"
        case .japanese:
            "日本語"
        }
    }
}

enum ChekinanaAssistantReplyLanguage: Equatable, Sendable {
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case english
    case appLocalizationFallback

    var appLanguage: ChekinanaAppLanguage? {
        switch self {
        case .simplifiedChinese: .simplifiedChinese
        case .traditionalChinese: .traditionalChinese
        case .japanese: .japanese
        case .english: .english
        case .appLocalizationFallback: nil
        }
    }

    var locale: Locale {
        appLanguage.map { Locale(identifier: $0.rawValue) } ?? .current
    }

    var switchConfirmation: String {
        switch self {
        case .simplifiedChinese: "已切换为简体中文。"
        case .traditionalChinese: "已切換為繁體中文。"
        case .japanese: "日本語で返信します。"
        case .english: "I'll reply in English."
        case .appLocalizationFallback: ""
        }
    }

    static func interfaceFallback(
        configuredLanguage: ChekinanaAppLanguage = ChekinanaLanguagePreference.language(),
        preferredLocalizations: [String] = Bundle.main.preferredLocalizations,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Self {
        if let explicit = from(configuredLanguage) {
            return explicit
        }
        for identifier in preferredLocalizations + preferredLanguages {
            if let resolved = from(identifier: identifier) {
                return resolved
            }
        }
        return .appLocalizationFallback
    }

    static func from(_ language: ChekinanaAppLanguage) -> Self? {
        switch language {
        case .simplifiedChinese: .simplifiedChinese
        case .traditionalChinese: .traditionalChinese
        case .japanese: .japanese
        case .english: .english
        case .system: nil
        }
    }

    static func from(identifier: String) -> Self? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized == "zh-hans" || normalized.hasPrefix("zh-hans-")
            || normalized == "zh-cn" || normalized.hasPrefix("zh-cn-")
            || normalized == "zh-sg" || normalized.hasPrefix("zh-sg-") {
            return .simplifiedChinese
        }
        if normalized == "zh-hant" || normalized.hasPrefix("zh-hant-")
            || normalized == "zh-tw" || normalized.hasPrefix("zh-tw-")
            || normalized == "zh-hk" || normalized.hasPrefix("zh-hk-")
            || normalized == "zh-mo" || normalized.hasPrefix("zh-mo-") {
            return .traditionalChinese
        }
        if normalized == "ja" || normalized.hasPrefix("ja-") { return .japanese }
        if normalized == "en" || normalized.hasPrefix("en-") { return .english }
        return nil
    }

    func localized<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try ChekinanaAssistantReplyLocalization.$language.withValue(self, operation: operation)
    }

    @MainActor
    func localized<Result>(_ operation: @MainActor () async throws -> Result) async rethrows -> Result {
        try await ChekinanaAssistantReplyLocalization.$language.withValue(self, operation: operation)
    }

    func text(_ key: String, fallback: String) -> String {
        localized { ChekinanaL10n.text(key, fallback: fallback) }
    }

    func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        localized {
            String(
                format: ChekinanaL10n.text(key, fallback: fallback),
                locale: locale,
                arguments: arguments
            )
        }
    }

    func quantity(_ key: String, count: Int, one: String, other: String) -> String {
        localized {
            ChekinanaL10n.quantity(
                key,
                count: count,
                one: one,
                other: other
            )
        }
    }
}

enum ChekinanaAssistantReplyLocalization {
    @TaskLocal static var language: ChekinanaAssistantReplyLanguage?
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
        if language == nil, let replyLanguage = ChekinanaAssistantReplyLocalization.language {
            return replyLanguage.appLanguage.map { Locale(identifier: $0.rawValue) } ?? systemLocale
        }
        let resolved = language ?? self.language()
        return resolved == .system ? systemLocale : Locale(identifier: resolved.rawValue)
    }

    static func localizationBundle(
        for language: ChekinanaAppLanguage? = nil,
        candidates: [Bundle] = [Bundle.main]
    ) -> Bundle {
        if language == nil,
           let replyLanguage = ChekinanaAssistantReplyLocalization.language {
            guard let replyAppLanguage = replyLanguage.appLanguage else {
                return candidates.first ?? .main
            }
            return localizationBundle(for: replyAppLanguage, candidates: candidates)
        }
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

enum ChekinanaThemeOption: String, CaseIterable, Identifiable, Sendable {
    case green, blue, aqua, purple, pink, red, orange, yellow, gray

    var id: String { rawValue }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .purple
    }

    var title: String {
        ChekinanaL10n.text("settings.theme.\(rawValue)", fallback: fallbackTitle)
    }

    private var fallbackTitle: String {
        switch self {
        case .green: "Green"
        case .blue: "Blue"
        case .aqua: "Aqua"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .gray: "Gray"
        }
    }

    var hex: String {
        switch self {
        case .green: "#2E7D32"
        case .blue: "#1565C0"
        case .aqua: "#0277BD"
        case .purple: "#4F337A"
        case .pink: "#AD1457"
        case .red: "#C62828"
        case .orange: "#E65100"
        case .yellow: "#827717"
        case .gray: "#616161"
        }
    }

    var rgb: (red: Double, green: Double, blue: Double) {
        let raw = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (
            Double((raw >> 16) & 0xFF) / 255,
            Double((raw >> 8) & 0xFF) / 255,
            Double(raw & 0xFF) / 255
        )
    }

    var accent: Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// A theme-aware grouped-card tint made by blending 12% accent into white.
    var softAccent: Color {
        Color(
            red: 0.88 + rgb.red * 0.12,
            green: 0.88 + rgb.green * 0.12,
            blue: 0.88 + rgb.blue * 0.12
        )
    }
}

enum ChekinanaThemePreference {
    static let defaultsKey = "chekinana.app-theme.v1"

    static func theme(defaults: UserDefaults = .standard) -> ChekinanaThemeOption {
        ChekinanaThemeOption.resolve(defaults.string(forKey: defaultsKey))
    }

    static func set(
        _ theme: ChekinanaThemeOption,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(theme.rawValue, forKey: defaultsKey)
    }
}

final class ChekinanaThemeRenderState: Sendable {
    private let storage: OSAllocatedUnfairLock<ChekinanaThemeOption>

    init(_ theme: ChekinanaThemeOption) {
        storage = OSAllocatedUnfairLock(initialState: theme)
    }

    var theme: ChekinanaThemeOption {
        storage.withLock { $0 }
    }

    func update(_ theme: ChekinanaThemeOption) {
        storage.withLock { $0 = theme }
    }
}

@MainActor
final class ChekinanaThemeStore: ObservableObject {
    nonisolated private static let sharedRenderState = ChekinanaThemeRenderState(
        ChekinanaThemePreference.theme()
    )
    static let shared = ChekinanaThemeStore(
        defaults: .standard,
        renderState: sharedRenderState
    )

    nonisolated static var currentTheme: ChekinanaThemeOption {
        sharedRenderState.theme
    }

    private let defaults: UserDefaults
    private let renderState: ChekinanaThemeRenderState
    private(set) var revision: UInt64 = 0
    private var storedTheme: ChekinanaThemeOption

    var theme: ChekinanaThemeOption {
        get { storedTheme }
        set {
            guard newValue != storedTheme else { return }
            objectWillChange.send()
            storedTheme = newValue
            renderState.update(newValue)
            revision &+= 1
            ChekinanaThemePreference.set(newValue, defaults: defaults)
        }
    }

    var accent: Color { theme.accent }
    var softAccent: Color { theme.softAccent }

    convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, renderState: nil)
    }

    init(
        defaults: UserDefaults,
        renderState: ChekinanaThemeRenderState?
    ) {
        self.defaults = defaults
        let initialTheme = ChekinanaThemePreference.theme(defaults: defaults)
        storedTheme = initialTheme
        self.renderState = renderState ?? ChekinanaThemeRenderState(initialTheme)
        self.renderState.update(initialTheme)
    }
}

private struct ChekinanaLanguageRevisionKey: EnvironmentKey {
    static let defaultValue: UInt64 = 0
}

private struct ChekinanaThemeRevisionKey: EnvironmentKey {
    static let defaultValue: UInt64 = 0
}

extension EnvironmentValues {
    var chekinanaLanguageRevision: UInt64 {
        get { self[ChekinanaLanguageRevisionKey.self] }
        set { self[ChekinanaLanguageRevisionKey.self] = newValue }
    }

    var chekinanaThemeRevision: UInt64 {
        get { self[ChekinanaThemeRevisionKey.self] }
        set { self[ChekinanaThemeRevisionKey.self] = newValue }
    }
}

enum ChekinanaL10n {
    /// Localizes complete runtime messages while preserving native typed interpolation.
    static func message(
        _ value: String.LocalizationValue,
        bundle: Bundle? = nil,
        locale: Locale? = nil
    ) -> String {
        String(
            localized: value,
            bundle: bundle ?? ChekinanaLanguagePreference.localizationBundle(),
            locale: locale ?? ChekinanaLanguagePreference.displayLocale()
        )
    }

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

    /// The app ships English, Simplified/Traditional Chinese, and Japanese. A
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
    static func timestamp(_ date: Date, includesDate: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = ChekinanaLanguagePreference.displayLocale()
        formatter.dateStyle = includesDate ? .medium : .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

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

enum ChekinanaIdolColorInputError: LocalizedError, Equatable {
    case unrecognized

    var errorDescription: String? {
        ChekinanaL10n.text(
            "idol.color.invalid",
            fallback: "Color could not be recognized. Enter an RGB value (for example, #4CAF50)."
        )
    }
}

enum ChekinanaIdolColorInputPolicy {
    static func normalizedStorageValue(_ rawValue: String) throws -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let canonical = ChekinanaIdolPalette.canonicalPresetName(trimmed) {
            return canonical
        }
        if let localized = ChekinanaIdolPalette.presetStorageValues.first(where: {
            ChekinanaIdolPalette.localizedTitle(forStorageValue: $0)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return localized
        }
        guard trimmed.count == 7, trimmed.first == "#",
              UInt32(trimmed.dropFirst(), radix: 16) != nil else {
            throw ChekinanaIdolColorInputError.unrecognized
        }
        let normalizedHex = trimmed.uppercased()
        return ChekinanaIdolPalette.presetName(hex: normalizedHex) ?? normalizedHex
    }

    static func validationMessage(_ rawValue: String) -> String? {
        do {
            _ = try normalizedStorageValue(rawValue)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum ChekinanaIdolEditorColorPolicy {
    static func storageValue(_ rawValue: String) -> String? {
        do { return try ChekinanaIdolColorInputPolicy.normalizedStorageValue(rawValue) }
        catch {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func recognizedValue(_ rawValue: String?) -> String? {
        try? ChekinanaIdolColorInputPolicy.normalizedStorageValue(rawValue ?? "")
    }
}

enum ChekinanaDesignSystem {
    static var accent: Color { ChekinanaThemeStore.currentTheme.accent }
    static var softAccent: Color { ChekinanaThemeStore.currentTheme.softAccent }
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

struct ChekinanaMediaEditHooks: Sendable {
    var save: @MainActor @Sendable (ModelContext) throws -> Void = { try $0.save() }
    var didSave: @MainActor @Sendable (UUID) -> Void = { _ in }
}

private struct ChekinanaMediaEditHooksKey: EnvironmentKey {
    static let defaultValue = ChekinanaMediaEditHooks()
}

extension EnvironmentValues {
    var chekinanaMediaEditHooks: ChekinanaMediaEditHooks {
        get { self[ChekinanaMediaEditHooksKey.self] }
        set { self[ChekinanaMediaEditHooksKey.self] = newValue }
    }
}

/// Suppression exists only around this editor's actual synchronous save call.
/// A save from another context or outside that call keeps the normal refresh.
@MainActor
final class ChekinanaGalleryLocalEditRefreshGate {
    private var savingContext: ObjectIdentifier?
    private(set) var preservesCurrentResults = false
    private var editedIDs = Set<UUID>()

    func save(_ context: ModelContext) throws {
        let previous = savingContext
        savingContext = ObjectIdentifier(context)
        defer { savingContext = previous }
        try context.save()
    }

    func receiveSave(from context: ModelContext?) -> Bool {
        if let context, savingContext == ObjectIdentifier(context) {
            preservesCurrentResults = true
            return false
        }
        resumeNormalRefresh()
        return true
    }

    var pendingEditedIDs: Set<UUID> { editedIDs }
    func recordSuccessfulEdit(_ id: UUID) { editedIDs.insert(id) }
    func takeEditedIDs() -> Set<UUID> {
        defer { editedIDs.removeAll() }
        return editedIDs
    }
    func resumeNormalRefresh() { preservesCurrentResults = false }
}

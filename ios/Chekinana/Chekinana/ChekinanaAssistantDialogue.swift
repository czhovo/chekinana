import Foundation
import SwiftData

/// Match-only keys; never persist them or replace the user's original input.
enum ChekinanaLocalEntityMatch {
    static func key(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func equal(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return false }
        let leftKey = key(left)
        return !leftKey.isEmpty && leftKey == key(right)
    }

    static func contains(_ value: String, query: String) -> Bool {
        let queryKey = key(query)
        return !queryKey.isEmpty && key(value).contains(queryKey)
    }
}

/// Local, bounded expansion of existing names. New Idol names never enter this path.
enum ChekinanaAssistantMultiTarget {
    enum Failure: Error { case unclear, tooMany }

    static func names(_ raw: String, knownNames: [String]) throws -> [String] {
        guard raw.utf8.count <= 4_096 else { throw Failure.tooMany }
        let words = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard words.count <= 50 else { throw Failure.tooMany }
        guard words.count > 1 else { return [raw] }
        let known = knownNames.map(ChekinanaLocalEntityMatch.key)
        guard words.allSatisfy({ word in
            let key = ChekinanaLocalEntityMatch.key(word)
            return known.contains(where: { $0.contains(key) })
        }) else { throw Failure.unclear }
        return words
    }

    static func expand(
        _ operations: [ChekinanaNLOperation],
        utterance: String,
        idolNames: [String],
        eventNames: [String]
    ) throws -> [ChekinanaNLOperation] {
        guard operations.count <= 50 else { throw Failure.tooMany }
        let separateStatistics = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^(?:分别统计|分別統計|separately\s+(?:stats|statistics)|individual\s+statistics|(?:それぞれ|個別に)(?:統計|集計))"#,
                options: [.regularExpression, .caseInsensitive]) != nil
        var result: [ChekinanaNLOperation] = []
        for original in operations {
            var operation = original
            // Context and already bound references retain their existing lifecycle.
            if operation.intent == .addidol || operation.slots.contextRef != nil || operation.slots.isLocallyResolved {
                result.append(operation)
                continue
            }
            if let values = operation.slots.idols {
                operation.slots.idols = try values.flatMap { try names($0, knownNames: idolNames) }
                if operations.count == 1, let segment = explicitRecordIdolSegment(utterance, intent: operation.intent) {
                    let requested = try names(segment, knownNames: idolNames)
                    let requestedKeys = Set(requested.map(ChekinanaLocalEntityMatch.key))
                    guard operation.slots.idols!.allSatisfy({ requestedKeys.contains(ChekinanaLocalEntityMatch.key($0)) }) else {
                        throw Failure.unclear
                    }
                    operation.slots.idols = requested
                }
                guard operation.slots.idols!.count <= 50 else { throw Failure.tooMany }
            }
            if let values = operation.slots.candidateRefs {
                operation.slots.candidateRefs = try values.flatMap { try names($0, knownNames: idolNames) }
                guard operation.slots.candidateRefs!.count <= 50 else { throw Failure.tooMany }
            }
            if let idol = operation.slots.idol {
                let values = try names(idol, knownNames: idolNames)
                // A combined statistic and separate per-Idol statistics are not
                // interchangeable; preserve the existing single-Idol contract.
                if values.count > 1 {
                    guard operation.intent == .statscheki, separateStatistics else { throw Failure.unclear }
                    for name in values {
                        var individual = operation
                        individual.slots.idol = name
                        result.append(individual)
                    }
                    continue
                }
                operation.slots.idol = values[0]
            }
            let known: [String]
            switch operation.intent {
            case .showidol, .editidol, .deleteidol, .favoriteidol: known = idolNames
            case .showevent, .editevent, .deleteevent: known = eventNames
            default:
                result.append(operation)
                continue
            }
            guard let target = operation.slots.target else { result.append(operation); continue }
            let targets = try names(target, knownNames: known)
            for target in targets {
                var item = operation
                item.slots.target = target
                result.append(item)
            }
        }
        guard result.count <= 50 else { throw Failure.tooMany }
        // Verify a clearly delimited target segment against the whole plan, not
        // only its first operation. Never collect names from notes or the body.
        let usesOnlyUnboundNames = result.allSatisfy {
            $0.slots.contextRef == nil && !$0.slots.isLocallyResolved
        }
        if usesOnlyUnboundNames, let first = result.first,
           [.statscheki, .listcheki].contains(first.intent),
           let segment = explicitTargetSegment(utterance, intent: first.intent),
           let requested = try verifiedMultipleNames(
                statisticsTargetSegment(segment, operations: result),
                knownNames: idolNames, planned: result.compactMap(\.slots.idol)),
           requested.count > 1 {
            guard first.intent == .statscheki, separateStatistics,
                  result.allSatisfy({ $0.intent == .statscheki }) else { throw Failure.unclear }
            let planned = result.compactMap(\.slots.idol).map(ChekinanaLocalEntityMatch.key)
            let expected = requested.map(ChekinanaLocalEntityMatch.key)
            if planned != expected {
                guard result.count == 1, let only = first.slots.idol,
                      requested.contains(where: { ChekinanaLocalEntityMatch.equal($0, only) }) else {
                    throw Failure.unclear
                }
                result = requested.map { name in
                    var individual = first
                    individual.slots.idol = name
                    return individual
                }
            }
        }
        if usesOnlyUnboundNames, let first = result.first,
           ![.statscheki, .listcheki].contains(first.intent),
           result.allSatisfy({ $0.intent == first.intent }),
           let segment = explicitTargetSegment(utterance, intent: first.intent),
           let requested = try verifiedMultipleNames(segment,
                knownNames: [.showevent, .editevent, .deleteevent].contains(first.intent) ? eventNames : idolNames,
                planned: result.compactMap(\.slots.target)) {
            let planned = result.compactMap(\.slots.target)
            if requested.map(ChekinanaLocalEntityMatch.key) != planned.map(ChekinanaLocalEntityMatch.key) {
                guard operations.count == 1, planned.count == 1,
                      requested.contains(where: { ChekinanaLocalEntityMatch.equal($0, planned[0]) }) else {
                    throw Failure.unclear
                }
                result = requested.map { name in
                    var value = first
                    value.slots.target = name
                    return value
                }
            }
        }
        for operation in result where explicitTargetSegment(utterance, intent: operation.intent) == nil {
            let known: [String]
            switch operation.intent {
            case .showidol, .editidol, .deleteidol, .favoriteidol: known = idolNames
            case .showevent, .editevent, .deleteevent: known = eventNames
            default: continue
            }
            guard let target = operation.slots.target, !operation.slots.isLocallyResolved,
                  operation.slots.contextRef == nil else { continue }
            let planned = Set(result.filter { $0.intent == operation.intent }
                .compactMap(\.slots.target).map(ChekinanaLocalEntityMatch.key))
            let protectedValues = [operation.slots.note, operation.slots.name,
                operation.slots.bio, operation.slots.group, operation.slots.city,
                operation.slots.livehouse, operation.slots.event].compactMap { $0 }
            if hasUnrepresentedAdjacentNames(in: utterance, target: target, knownNames: known,
                planned: planned, excluding: protectedValues) { throw Failure.unclear }
        }
        guard result.count <= 50 else { throw Failure.tooMany }
        return result
    }

    static func statisticsTargetSegment(_ segment: String, operations: [ChekinanaNLOperation]) -> String {
        guard operations.contains(where: {
            $0.slots.date != nil || ($0.slots.dateFrom != nil && $0.slots.dateTo != nil)
        }) else { return segment }
        // Only strip a terminal time modifier when the service actually supplied
        // a date filter. Never tokenize this prose as additional Idol names.
        let relative = #"(?:本月|这个月|這個月|上个月|上個月|上月|下个月|下個月|本周|本週|这周|這週|上周|上週|下周|下週|今年|去年|明年|今天|今日|昨天|昨日|明天|明日|今月|先月|来月|今週|先週|来週|来年|(?:this|last|next)\s+(?:month|week|year)|today|yesterday|tomorrow)"#
        var patterns = [#"(?:\s+(?:for\s+|in\s+|during\s+)?|\s*(?:的|の))"# + relative + #"\s*$"#]
        for operation in operations {
            if let from = operation.slots.dateFrom, let to = operation.slots.dateTo {
                patterns.append(#"\s+(?:from\s+)?"# + NSRegularExpression.escapedPattern(for: from)
                    + #"\s*(?:to|through|至|到|〜|～|—|-)\s*"# + NSRegularExpression.escapedPattern(for: to) + #"\s*$"#)
            }
            if let date = operation.slots.date {
                patterns.append(#"\s+(?:on\s+)?"# + NSRegularExpression.escapedPattern(for: date) + #"\s*$"#)
            }
        }
        for pattern in patterns {
            let stripped = segment.replacingOccurrences(of: pattern, with: "",
                options: [.regularExpression, .caseInsensitive])
            if stripped != segment { return stripped }
        }
        return segment
    }

    static func verifiedMultipleNames(
        _ segment: String, knownNames: [String], planned: [String]
    ) throws -> [String]? {
        do {
            let parsed = try explicitNames(segment, knownNames: knownNames)
            // A single token may be ordinary prose ("this month", "her",
            // "Alice's profile"). It is not evidence of an omitted name.
            return parsed.count > 1 ? parsed : nil
        } catch Failure.tooMany { throw Failure.tooMany }
        catch {
            let candidateSegments = [segment, segment.replacingOccurrences(
                of: #"^(?:idols?|events?|for)\s+"#, with: "",
                options: [.regularExpression, .caseInsensitive])]
            // A known target followed by an otherwise bare unknown name must
            // not execute a partial plan. Common read-request suffixes remain
            // prose, not an additional target.
            let proseSuffixes: Set<String> = ["details", "profile", "information", "info", "please",
                "的资料", "的資料", "资料", "資料", "的信息", "信息", "について", "の情報"]
            for candidate in candidateSegments {
                let words = candidate.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                for boundary in 1..<max(1, words.count) {
                    let prefix = words.prefix(boundary).joined(separator: " ")
                    let suffix = words.dropFirst(boundary).joined(separator: " ")
                    if planned.contains(where: { ChekinanaLocalEntityMatch.equal($0, prefix) }),
                       !proseSuffixes.contains(suffix.lowercased()) {
                        throw Failure.unclear
                    }
                }
            }
            return nil
        }
    }

    static func explicitRecordIdolSegment(_ text: String, intent: ChekinanaNLIntent) -> String? {
        guard [.addrecord, .editrecord, .addcheki, .editcheki, .listrecord].contains(intent),
              text.utf8.count <= 4_096 else { return nil }
        let patterns = [
            #"^(?:please\s+)?(?:add|edit|list)\s+(?:cheki\s+)?records?\s+(?:for\s+)?(.+?)\s+(?:count|date|note|size|event)\s*(?:=|:).+$"#,
            #"^(?:请|請)?(?:给|給|为|為)(.+?)(?:添加|新增|记录|記錄)\s*\d+.*$"#,
        ]
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
               let range = Range(match.range(at: 1), in: raw) {
                return String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func explicitNames(_ segment: String, knownNames: [String]) throws -> [String] {
        do { return try names(segment, knownNames: knownNames) }
        catch Failure.tooMany { throw Failure.tooMany }
        catch {
            let stripped = segment.replacingOccurrences(of: #"^(?:idols?|events?|for)\s+"#,
                with: "", options: [.regularExpression, .caseInsensitive])
            guard stripped != segment else { throw error }
            return try names(stripped, knownNames: knownNames)
        }
    }

    static func hasUnrepresentedAdjacentNames(
        in text: String, target: String, knownNames: [String],
        planned: Set<String>, excluding payloads: [String]
    ) -> Bool {
        guard text.utf8.count <= 4_096 else { return true }
        let source = text as NSString
        let pieces = target.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return false }
        let pattern = #"(?<![\p{L}\p{N}])"# + pieces.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"\s*"#) + #"(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return true }
        var protectedRanges: [NSRange] = []
        for payload in payloads where !payload.isEmpty {
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                let range = source.range(of: payload, options: [.caseInsensitive], range: search)
                if range.location == NSNotFound { break }
                protectedRanges.append(range)
                search = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
            }
        }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let tail = source.substring(from: match.range.location)
            let words = tail.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            guard words.count > 1 else { continue }
            for end in 2...min(words.count, 16) {
                let candidate = words.prefix(end).joined(separator: " ")
                if let values = try? names(candidate, knownNames: knownNames), values.count > 1,
                   values.contains(where: { !planned.contains(ChekinanaLocalEntityMatch.key($0)) }) {
                    return true
                }
            }
        }
        return false
    }

    static func explicitTargetSegment(_ text: String, intent: ChekinanaNLIntent) -> String? {
        let verb: String
        switch intent {
        case .showidol, .showevent: verb = #"(?:show(?:\s+me)?|view|查看|显示|顯示|表示)"#
        case .deleteidol, .deleteevent: verb = #"(?:delete|remove|删除|刪除|削除)"#
        case .favoriteidol: verb = #"(?:favorite|unfavorite|收藏|取消收藏|お気に入り)"#
        case .statscheki: verb = #"(?:(?:separately\s+|individual\s+)?(?:stats|statistics)|(?:分别|分別)?(?:统计|統計)|(?:それぞれ|個別に)?(?:統計|集計))"#
        case .listcheki: verb = #"(?:list\s+cheki(?:s)?|列出拍立得|列出チェキ)"#
        case .editidol, .editevent: verb = #"(?:edit|update|修改|编辑|編輯|変更)"#
        default: return nil
        }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 4_096 else { return nil }
        let pattern: String
        if intent == .editidol || intent == .editevent {
            let chinese = #"^(?:请|請)?(?:修改|编辑|編輯|更改|把|将|將)\s*(.+?)(?:的)?(?:备注|備註|名字|名称|名稱|颜色|顏色|分组|分組|生日|简介|簡介|头像|頭像)(?:改为|改為|改成|设为|設為|设置为|設定為|为|為|:|：|=).+$"#
            if let regex = try? NSRegularExpression(pattern: chinese),
               let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
               let range = Range(match.range(at: 1), in: raw) {
                return String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Field markers delimit the target; their payload is never parsed as names.
            pattern = #"^(?:please\s+|请|請)?"# + verb + #"\s*(.+?)\s+(?:name|group|color|birthday|bio|note|city|livehouse|date|price|avatar|verification)\s*(?:=|:|to\s).+$"#
        } else {
            pattern = #"^(?:please\s+|请|請)?"# + verb + #"\s*(.+?)\s*[。.!！]?$"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        return String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ChekinanaAssistantScope {
    static let allowedIntents: Set<ChekinanaNLIntent> = [
        .addidol, .editidol, .deleteidol, .favoriteidol, .listidol, .showidol,
        .addevent, .editevent, .deleteevent, .listevent, .showevent,
        .listcheki, .showcheki, .editcheki, .deletecheki,
        .addrecord, .editrecord, .deleterecord, .showrecord, .listrecord, .statscheki,
    ]
    static func allows(_ operations: [ChekinanaNLOperation]) -> Bool {
        operations.allSatisfy { allowedIntents.contains($0.intent) && ($0.slots.recordType == nil || $0.slots.recordType == "cheki") }
    }
    static func allowsCommand(_ name: String?) -> Bool {
        guard let name else { return false }
        if ["confirm", "cancel", "selectidolcandidate", "confirmidolcandidate"].contains(name) { return true }
        guard let intent = ChekinanaNLIntent(rawValue: name) else { return false }
        return allowedIntents.contains(intent)
    }
}

struct ChekinanaNLContext: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case idol, event, cheki; case chekiRecord = "cheki_record" }
    struct Target: Codable, Equatable, Sendable { let kind: Kind; let name: String? }
    struct Statistics: Codable, Equatable, Sendable {
        var idol: String?
        var event: String?
        var dateFrom: String?
        var dateTo: String?
        enum CodingKeys: String, CodingKey {
            case idol, event
            case dateFrom = "date_from"
            case dateTo = "date_to"
        }
    }
    var lastTarget: Target? = nil
    var lastStatistics: Statistics? = nil
    enum CodingKeys: String, CodingKey {
        case lastTarget = "last_target"
        case lastStatistics = "last_statistics"
    }
    static func validate(_ result: ChekinanaNLInterpretation, using context: ChekinanaNLContext?) throws {
        let operations: [ChekinanaNLOperation]
        switch result {
        case .plan(let plan): operations = plan
        case .clarify(let draft, _): operations = [draft]
        case .reject: return
        }
        for operation in operations where operation.slots.contextRef != nil {
            guard let context else { throw ChekinanaNLClientError.invalidSchema }
            try context.validate(operation)
        }
    }
    static func supportsReference(_ intent: ChekinanaNLIntent) -> Bool {
        [.showidol, .editidol, .deleteidol, .favoriteidol, .showevent, .editevent, .deleteevent,
         .showcheki, .editcheki, .deletecheki, .showrecord, .editrecord, .deleterecord,
         .addrecord, .statscheki].contains(intent)
    }
    func validatePrivacy(activeConfirmationCodes: Set<String>) throws {
        for text in [lastTarget?.name, lastStatistics?.idol, lastStatistics?.event].compactMap({ $0 }) {
            guard text.utf16.count <= 200, !text.contains("://"),
                  ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(text, activeConfirmationCodes: activeConfirmationCodes) else {
                throw ChekinanaNLClientError.sensitiveInput
            }
        }
        if let stats = lastStatistics {
            guard (stats.dateFrom == nil) == (stats.dateTo == nil) else { throw ChekinanaNLClientError.invalidRequest }
            for date in [stats.dateFrom, stats.dateTo].compactMap({ $0 }) where !ChekinanaNLSchemaValidator.isCalendarDate(date) {
                throw ChekinanaNLClientError.invalidRequest
            }
            if let from = stats.dateFrom, let to = stats.dateTo, from > to { throw ChekinanaNLClientError.invalidRequest }
        }
    }
    func validate(_ operation: ChekinanaNLOperation) throws {
        let slots = operation.slots
        guard let ref = slots.contextRef else { return }
        guard slots.target == nil else { throw ChekinanaNLClientError.invalidSchema }
        if ref == "last_statistics" {
            guard operation.intent == .statscheki, lastStatistics != nil else { throw ChekinanaNLClientError.invalidSchema }
            return
        }
        guard ref == "last_target", let target = lastTarget else { throw ChekinanaNLClientError.invalidSchema }
        let allowed: Set<ChekinanaNLIntent>
        switch target.kind {
        case .idol: allowed = [.showidol, .editidol, .deleteidol, .favoriteidol, .statscheki, .addrecord]
        case .event: allowed = [.showevent, .editevent, .deleteevent]
        case .cheki: allowed = [.showcheki, .editcheki, .deletecheki]
        case .chekiRecord: allowed = [.showrecord, .editrecord, .deleterecord, .addrecord]
        }
        guard allowed.contains(operation.intent),
              operation.intent != .statscheki || slots.idol == nil,
              operation.intent != .addrecord || (slots.recordType == "cheki" && slots.idols == nil),
              target.kind != .chekiRecord || slots.recordType == "cheki" else { throw ChekinanaNLClientError.invalidSchema }
        if operation.intent == .addrecord, target.kind == .chekiRecord {
            guard slots.count != nil, slots.presentKeys.isSubset(of: ["record_type", "count", "context_ref"]) else { throw ChekinanaNLClientError.invalidSchema }
        }
    }
}

enum ChekinanaAssistantReferenceError: LocalizedError {
    case unclear
    var errorDescription: String? { ChekinanaL10n.text("assistant.dialog.unclear_reference", fallback: "I cannot tell which item you mean. Give its name or a result number. The pending preview is unchanged.") }
}

enum ChekinanaAssistantInput {
    enum Control: Equatable { case confirm, cancel, choose(Int), help, unsupportedReduction }

    static func isExactLocalConfirmationCommand(
        _ text: String,
        activeCodes: Set<String>
    ) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard parts.count == 2,
              ["confirm", "cancel"].contains(parts[0]) else {
            return false
        }
        return activeCodes.contains(parts[1])
    }

    static func control(_ text: String) -> Control? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？"))
        if ["确认", "確認", "确定", "確定", "好", "好的", "可以", "confirm", "yes", "ok", "はい", "保存して"].contains(value) { return .confirm }
        if ["取消", "算了", "cancel", "no", "キャンセル", "やめる"].contains(value) { return .cancel }
        if ["帮助", "幫助", "help", "你好", "hello", "こんにちは", "ヘルプ"].contains(value) { return .help }
        if value.range(of: #"(?:撤销|撤銷|减去|減去|少记|少記|undo|subtract|取り消)[^\n]*(?:张|張|枚|cheki|刚才|剛才)"#, options: [.regularExpression, .caseInsensitive]) != nil { return .unsupportedReduction }
        if let range = value.range(of: #"^(?:第|选|選|选择|選擇|choose\s*|number\s*)?\s*[0-9]+\s*(?:个|個|条|條|张|張|番|番目|枚目)?$"#, options: .regularExpression) {
            let digits = value[range].filter(\.isNumber)
            if let index = Int(digits), (1...100).contains(index) { return .choose(index - 1) }
        }
        return nil
    }
    static func usesTargetReference(_ text: String) -> Bool {
        text.range(of: #"(?:她|他|它|刚才那个|剛才那個|那[个個条條张張]|这[个個条條张張]|それ|その人|さっきの|\b(?:her|him|it|that one|the previous one)\b)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func sanitizedError(_ text: String, privateCodes: Set<String>) -> String {
        let hasPrivateIdentifier = text.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, options: .regularExpression) != nil
            || privateCodes.contains { !$0.isEmpty && text.contains($0) }
        guard hasPrivateIdentifier else { return text }
        return ChekinanaCommandCopy.errorDetail(ChekinanaL10n.text("assistant.dialog.target_changed", fallback: "The requested item changed or is unavailable. Ask to list the current items and prepare a new preview."))
    }
    static func ordinal(_ raw: String) -> Int? {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^(?:第|the\s+)?[0-9]+(?:st|nd|rd|th)?\s*(?:个|個|条|條|张|張|枚目|番目|番|cheki|record|item)?$"#, options: .regularExpression) != nil,
           let number = Int(value.filter(\.isNumber)), (1...100).contains(number) { return number - 1 }
        let words = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        if value.range(of: #"^(?:the )?(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?: (?:cheki|record|item|idol|event))?$"#, options: .regularExpression) != nil,
           let first = value.replacingOccurrences(of: "the ", with: "").split(separator: " ").first,
           let index = words.firstIndex(of: String(first)) { return index }
        let chinese = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        for (index, word) in chinese.enumerated() {
            if ["第\(word)个", "第\(word)個", "第\(word)条", "第\(word)條", "第\(word)张", "第\(word)張", "\(word)番目", "\(word)枚目"].contains(value) { return index }
        }
        return nil
    }
    static func isCorrection(_ text: String) -> Bool {
        text.range(of: #"(?:改成|改为|改為|改到|改一下|不是.+是|更正|訂正|修正|に変更|にして|に変えて|じゃなく|change (?:it|that|the)|make (?:it|that)|instead|日期(?:改)?(?:昨天|昨日)|数量(?:改)?[0-9]|數量(?:改)?[0-9])"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func explicitlyChangesTarget(_ text: String, from previous: String?, to next: String?, excluding fields: [String] = []) -> Bool {
        guard let next, !next.isEmpty else { return false }
        var value = text.precomposedStringWithCompatibilityMapping.lowercased()
        for field in fields where !field.isEmpty {
            value = value.replacingOccurrences(of: field.precomposedStringWithCompatibilityMapping.lowercased(), with: " ")
        }
        let newValue = next.precomposedStringWithCompatibilityMapping.lowercased()
        guard value.contains(newValue) else { return false }
        if value.range(of: #"(?:目标|目標|对象|對象|対象|\btarget\b).*(?:改|换|換|変更|変え|change|instead)"#, options: .regularExpression) != nil
            || value.range(of: #"(?:change|switch)\s+(?:the\s+)?target"#, options: .regularExpression) != nil { return true }
        guard let previous, value.contains(previous.precomposedStringWithCompatibilityMapping.lowercased()) else { return false }
        return value.range(of: #"(?:不是.+是|not.+but|じゃなく|ではなく)"#, options: .regularExpression) != nil
    }
    static func isExplicitRepeat(_ text: String, excluding values: [String] = []) -> Bool {
        func normalized(_ value: String) -> String {
            value.precomposedStringWithCompatibilityMapping.lowercased()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
        var actionText = normalized(text)
        for value in values where !value.isEmpty { actionText = actionText.replacingOccurrences(of: normalized(value), with: " ") }
        let pattern = #"^(?:(?:请|請|今天|昨天|今日|昨日|现在|現在)\s*)*(?:再(?:给|給).{0,30}(?:加|切|记|記)|再加|又加|再切|又切|另加|另外(?:加|记|記|切))|^(?:もう(?:一度)?|さらに|追加で).*(?:チェキ|枚|追加|撮)|^(?:please\s+)?(?:add|record|take|create)\b.{0,80}\b(?:more|another|again)\b"#
        return actionText.trimmingCharacters(in: .whitespacesAndNewlines).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum ChekinanaAssistantChoiceSource { case none, library, catalogue, clarification }

enum ChekinanaAssistantChoicePolicy {
    static func route(_ index: Int, source: ChekinanaAssistantChoiceSource, libraryCount: Int, catalogueCount: Int, clarificationCount: Int) -> ChekinanaAssistantChoiceSource {
        guard index >= 0 else { return .none }
        switch source {
        case .library: return index < libraryCount ? .library : .none
        case .catalogue: return index < catalogueCount ? .catalogue : .none
        case .clarification: return index < clarificationCount ? .clarification : .none
        case .none: return .none
        }
    }
}

struct ChekinanaAssistantConfirmationGroup {
    private(set) var pendingCodes: [String]
    init(_ codes: [String]) {
        var seen = Set<String>()
        pendingCodes = codes.filter { seen.insert($0).inserted }
    }
    var isComplete: Bool { pendingCodes.isEmpty }
    @discardableResult
    mutating func recordSuccess(_ code: String) -> Bool {
        guard pendingCodes.contains(code) else { return false }
        pendingCodes.removeAll { $0 == code }
        return true
    }
}

struct ChekinanaAssistantWriteHistory {
    private var texts = Set<String>()
    private var generation: UUID?
    private var initialized = false
    mutating func contains(_ text: String, generation: UUID?) -> Bool {
        align(generation)
        return texts.contains(text)
    }
    mutating func complete(_ text: String, generation: UUID?) {
        align(generation)
        if !text.isEmpty { texts.insert(text) }
    }
    private mutating func align(_ value: UUID?) {
        if !initialized || generation != value { texts.removeAll(); generation = value; initialized = true }
    }
}

struct ChekinanaAssistantTargetReference: Equatable, Sendable {
    let kind: ChekinanaNLContext.Kind
    let id: UUID
}

@MainActor
final class ChekinanaAssistantDialogue {
    struct Target: Equatable, Sendable {
        let reference: ChekinanaAssistantTargetReference
        let name: String?
        let fingerprint: Int
        let generation: UUID?
    }
    var target: Target?
    var choices: [Target] = []
    var choiceSource: ChekinanaAssistantChoiceSource = .none
    var statistics: ChekinanaNLContext.Statistics?
    var statisticsIdolID: UUID?
    var statisticsEventID: UUID?
    var statisticsGeneration: UUID?
    var interpretedTurns = Set<UUID>()
    var lastSubmittedText: String?
    var pendingUserText = ""
    var remainingUserText = ""
    var completedWrites = ChekinanaAssistantWriteHistory()
    var catalogueLookupHadNoResults = false
    var executingOperation: ChekinanaNLOperation?
    var executingTarget: Target?
    var pendingTarget: Target?
    var remainingTarget: Target?
    var pendingOperation: ChekinanaNLOperation?
    var pendingCodes: [String] = []
    var remainingCommands: [String] = []
    var remainingOperations: [ChekinanaNLOperation] = []
    var consumedConfirmationCodes = Set<String>()
    var localIdolDraft: (token: String, name: String, generation: UUID?)?

    func clearPlan() {
        localIdolDraft = nil
        pendingOperation = nil
        pendingCodes = []
        remainingCommands = []
        remainingOperations = []
        pendingTarget = nil
        remainingTarget = nil
        pendingUserText = ""
        remainingUserText = ""
    }
    func capture(_ ref: ChekinanaAssistantTargetReference, in context: ModelContext) -> Target? {
        let hidden = ChekinanaHiddenIdolPersistence.load()
        var hasher = Hasher()
        hasher.combine(ref.id)
        var name: String?
        switch ref.kind {
        case .idol:
            guard !hidden.contains(ref.id), let item = try? context.fetch(FetchDescriptor<Idol>()).first(where: { $0.id == ref.id }) else { return nil }
            name = item.name
            hasher.combine(item.updatedAt); hasher.combine(item.name); hasher.combine(item.note); hasher.combine(item.isFavorite)
            hasher.combine(item.group); hasher.combine(item.birthday); hasher.combine(item.color); hasher.combine(item.bio); hasher.combine(item.verification); hasher.combine(item.avatarImageRef)
        case .event:
            guard let item = try? context.fetch(FetchDescriptor<Event>()).first(where: { $0.id == ref.id }) else { return nil }
            name = item.name
            hasher.combine(item.updatedAt); hasher.combine(item.name); hasher.combine(item.date); hasher.combine(item.note)
            hasher.combine(item.city); hasher.combine(item.livehouse); hasher.combine(item.price); hasher.combine(item.weiboURL); hasher.combine(item.ticketURL); hasher.combine(item.avatarImageRef)
        case .cheki:
            guard let item = try? context.fetch(FetchDescriptor<MediaItem>()).first(where: { $0.id == ref.id && $0.kind == .cheki }),
                  ChekinanaVisibilityPolicy.includesRecord(idolIDs: item.idolIDs, hiddenIDs: hidden) else { return nil }
            hasher.combine(item.updatedAt); hasher.combine(item.idolIDs); hasher.combine(item.eventID); hasher.combine(item.date)
            hasher.combine(item.note); hasher.combine(item.imageRef); hasher.combine(item.idx); hasher.combine(item.sizeRawValue)
            hasher.combine(item.isFavorite); hasher.combine(item.userAppears); hasher.combine(item.hasPostedToSNS)
        case .chekiRecord:
            guard let item = try? context.fetch(FetchDescriptor<ChekiRecord>()).first(where: { $0.id == ref.id }),
                  ChekinanaChekiRecordReadPolicy.isVisible(item, hiddenIDs: hidden) else { return nil }
            hasher.combine(ChekinanaChekiRecordSnapshot(item))
        }
        let generation: UUID?
        do { generation = try ChekinanaLibraryGenerationStore.current(in: context) }
        catch { return nil }
        return Target(reference: ref, name: name, fingerprint: hasher.finalize(), generation: generation)
    }
    func validatedTarget(in context: ModelContext) -> Target? {
        guard let target, capture(target.reference, in: context) == target else {
            self.target = nil
            return nil
        }
        return target
    }
    func safeContext(in context: ModelContext, codes: Set<String>) -> ChekinanaNLContext? {
        let target = validatedTarget(in: context)
        let safeName = target?.name.flatMap { name -> String? in
            guard name.utf16.count <= 200, !name.contains("://"),
                  ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(name, activeConfirmationCodes: codes) else { return nil }
            return name
        }
        if statistics != nil {
            let generation = try? ChekinanaLibraryGenerationStore.current(in: context)
            if generation != statisticsGeneration
                || statisticsIdolID.map({ capture(.init(kind: .idol, id: $0), in: context)?.name != statistics?.idol }) == true
                || statisticsEventID.map({ capture(.init(kind: .event, id: $0), in: context)?.name != statistics?.event }) == true { statistics = nil }
        }
        var value = ChekinanaNLContext(lastTarget: target.map { .init(kind: $0.reference.kind, name: safeName) }, lastStatistics: statistics)
        if (try? value.validatePrivacy(activeConfirmationCodes: codes)) == nil { value.lastStatistics = nil }
        guard value.lastTarget != nil || value.lastStatistics != nil else { return nil }
        return value
    }
    func captureWriteTarget(_ command: String, in context: ModelContext) -> Target? {
        guard let parsed = try? ChekinanaCommandParser.parse(command) else { return nil }
        let kind: ChekinanaNLContext.Kind
        let token: String?
        switch parsed.name {
        case "editidol", "deleteidol", "favoriteidol": kind = .idol; token = parsed.target
        case "editevent", "deleteevent": kind = .event; token = parsed.target
        case "editcheki", "deletecheki": kind = .cheki; token = parsed.target
        case "editrecord", "deleterecord":
            guard parsed.target == "cheki" else { return nil }
            kind = .chekiRecord; token = parsed.arguments["target"]
        default: return nil
        }
        guard let token, let id = UUID(uuidString: token) else { return nil }
        return capture(.init(kind: kind, id: id), in: context)
    }

    func resolveCorrection(_ input: ChekinanaNLOperation, previous: ChekinanaNLOperation, allowsTargetChange: Bool = false, in context: ModelContext) throws -> ChekinanaNLOperation {
        func identity(_ value: String?) -> String? {
            value?.precomposedStringWithCompatibilityMapping.lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let sameOrdinal = input.slots.target.flatMap(ChekinanaAssistantInput.ordinal).map { value in
            value == previous.slots.target.flatMap(ChekinanaAssistantInput.ordinal)
        } ?? false
        let previousIdentity = identity(previous.slots.target)
        let inputIdentity = identity(input.slots.target)
        // Only locally resolved slots carry internal identifiers; user names are never
        // classified as IDs based on their spelling.
        let identifiesByID = input.slots.isLocallyResolved || previous.slots.isLocallyResolved
        let sameIdentity = identifiesByID
            ? inputIdentity == previousIdentity
            : ((inputIdentity == nil && previousIdentity == nil)
                || ChekinanaLocalEntityMatch.equal(inputIdentity, previousIdentity))
        let sameTarget = (sameIdentity || sameOrdinal)
            && input.slots.contextRef == previous.slots.contextRef
        guard input.intent == previous.intent else { throw ChekinanaAssistantReferenceError.unclear }
        if allowsTargetChange { return try resolve(input, in: context) }
        guard sameTarget else { throw ChekinanaAssistantReferenceError.unclear }
        if input.slots.contextRef == "last_target" { return try resolveBound(input, to: pendingTarget, in: context) }
        guard input.slots.target != nil else { return try resolve(input, in: context) }
        guard let pendingTarget, capture(pendingTarget.reference, in: context) == pendingTarget else { throw ChekinanaAssistantReferenceError.unclear }
        var result = input
        result.slots.target = pendingTarget.reference.id.uuidString.lowercased()
        result.slots.isLocallyResolved = true
        return result
    }

    func resolveBound(_ input: ChekinanaNLOperation, to snapshot: Target?, in context: ModelContext) throws -> ChekinanaNLOperation {
        guard input.slots.contextRef == "last_target" else { return try resolve(input, in: context) }
        guard let snapshot, capture(snapshot.reference, in: context) == snapshot else { throw ChekinanaAssistantReferenceError.unclear }
        let previous = target
        target = snapshot
        defer { target = previous }
        return try resolve(input, in: context)
    }
    func resolve(_ input: ChekinanaNLOperation, in context: ModelContext) throws -> ChekinanaNLOperation {
        if input.slots.contextRef == nil, let token = input.slots.target,
           !choices.contains(where: { ChekinanaLocalEntityMatch.equal($0.name, token) }),
           let index = ChekinanaAssistantInput.ordinal(token), choices.indices.contains(index) {
            let selected = choices[index]
            guard capture(selected.reference, in: context) == selected else { throw ChekinanaAssistantReferenceError.unclear }
            var result = input
            switch (input.intent, selected.reference.kind) {
            case (.showcheki, .chekiRecord): result = .init(intent: .showrecord, slots: input.slots); result.slots.recordType = "cheki"
            case (.editcheki, .chekiRecord), (.deletecheki, .chekiRecord):
                throw ChekinanaNLClientError.invalidSchema
            case (.showidol, .idol), (.editidol, .idol), (.deleteidol, .idol), (.favoriteidol, .idol),
                 (.showevent, .event), (.editevent, .event), (.deleteevent, .event),
                 (.showcheki, .cheki), (.editcheki, .cheki), (.deletecheki, .cheki),
                 (.showrecord, .chekiRecord), (.editrecord, .chekiRecord), (.deleterecord, .chekiRecord): break
            default: throw ChekinanaNLClientError.invalidSchema
            }
            result.slots.target = selected.reference.id.uuidString.lowercased()
            result.slots.isLocallyResolved = true
            return result
        }
        guard let reference = input.slots.contextRef else { return input }
        let safe = safeContext(in: context, codes: []) ?? .init()
        do { try safe.validate(input) } catch { throw ChekinanaAssistantReferenceError.unclear }
        var result = input
        result.slots.contextRef = nil
        if reference == "last_statistics" { return result } // Server returns the complete final filter.
        guard let target = validatedTarget(in: context) else { throw ChekinanaAssistantReferenceError.unclear }
        let token = target.reference.id.uuidString.lowercased()
        result.slots.isLocallyResolved = true
        if input.intent == .statscheki { result.slots.idol = token }
        else if input.intent == .addrecord {
            if target.reference.kind == .idol { result.slots.idols = [token] }
            else {
                guard let record = try context.fetch(FetchDescriptor<ChekiRecord>()).first(where: { $0.id == target.reference.id }) else { throw ChekinanaNLClientError.invalidSchema }
                result.slots.idols = record.idolIDs.isEmpty ? nil : record.idolIDs.map { $0.uuidString.lowercased() }
                result.slots.event = record.eventID.map { $0.uuidString.lowercased() }
                result.slots.date = record.date.map(ChekinanaDateOnly.string)
                result.slots.size = record.size?.rawValue
                result.slots.note = record.note.isEmpty ? nil : record.note
            }
        } else { result.slots.target = token }
        return result
    }
}

@MainActor
enum ChekinanaAssistantLibrary {
    enum ReadError: LocalizedError {
        case missing, ambiguous, invalidData
        var errorDescription: String? {
            switch self {
            case .missing: ChekinanaL10n.text("assistant.dialog.missing", fallback: "That item is no longer available. Ask to list the matching items again.")
            case .ambiguous: ChekinanaL10n.text("assistant.dialog.ambiguous", fallback: "More than one item matches. Ask to list them, then reply with its number.")
            case .invalidData: ChekinanaL10n.text("assistant.dialog.invalid_statistics", fallback: "Some stored records could not be counted safely. No data was changed.")
            }
        }
    }
    private static func unique<T>(_ values: [T], id: (T) -> UUID, name: (T) -> String, token: String) throws -> T {
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ReadError.missing }
        if let identifier = UUID(uuidString: key), let item = values.first(where: { id($0) == identifier }) { return item }
        let exact = values.filter { ChekinanaLocalEntityMatch.equal(name($0), key) }
        if exact.count == 1 { return exact[0] }
        if exact.isEmpty, key.range(of: #"^[a-fA-F0-9]{8,32}$"#, options: .regularExpression) != nil {
            let ids = values.filter { id($0).uuidString.lowercased().hasPrefix(key.lowercased()) }
            if ids.count == 1 { return ids[0] }
            if ids.count > 1 { throw ReadError.ambiguous }
        }
        let matches = exact.isEmpty ? values.filter { ChekinanaLocalEntityMatch.contains(name($0), query: key) } : exact
        guard matches.count == 1 else { throw matches.isEmpty ? ReadError.missing : ReadError.ambiguous }
        return matches[0]
    }
    static func read(_ command: ChekinanaParsedCommand, in context: ModelContext, dialogue: ChekinanaAssistantDialogue) throws -> String? {
        let isSimple = command.target == "cheki" || command.arguments["record_type"] == "cheki" || (command.name == "listrecord" && command.target == nil)
        guard ["statscheki", "listcheki", "listidol", "showidol", "listevent", "showevent"].contains(command.name)
                || (["listrecord", "showrecord"].contains(command.name) && isSimple) else { return nil }
        if ["listidol", "listevent"].contains(command.name) {
            guard command.target == nil, command.arguments.isEmpty else { throw ChekinanaNLClientError.invalidSchema }
        }
        if ["showidol", "showevent"].contains(command.name) {
            guard command.target?.isEmpty == false, command.arguments.isEmpty else { throw ChekinanaNLClientError.invalidSchema }
        }
        if ["statscheki", "listcheki"].contains(command.name), command.target != nil { throw ChekinanaNLClientError.invalidSchema }
        let snapshot = ModelContext(context.container)
        snapshot.autosaveEnabled = false
        let hidden = ChekinanaHiddenIdolPersistence.load()
        let idols = try snapshot.fetch(FetchDescriptor<Idol>()).filter { !hidden.contains($0.id) }
        let events = try snapshot.fetch(FetchDescriptor<Event>())
        let names = Dictionary(uniqueKeysWithValues: idols.map { ($0.id, $0.name) })
        let eventNames = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0.name) })
        func remember(_ refs: [ChekinanaAssistantTargetReference]) {
            dialogue.choiceSource = .library
            dialogue.choices = refs.compactMap { dialogue.capture($0, in: context) }
            dialogue.target = dialogue.choices.count == 1 ? dialogue.choices[0] : nil
        }
        func numbered(_ values: [String]) -> String {
            guard !values.isEmpty else { return ChekinanaL10n.text("assistant.dialog.no_matches", fallback: "No matching records.") }
            let lines = values.prefix(100).enumerated().map { "\($0.offset + 1). \($0.element)" }
            let hint = values.count > 1 ? "\n" + ChekinanaL10n.text("assistant.dialog.choose_number", fallback: "Reply with a number to select an item, then tell me what to change.") : ""
            let limit = values.count > 100 ? "\n" + ChekinanaL10n.format("assistant.dialog.list_limit", fallback: "Showing the first 100 of %lld records. Narrow your request to see the rest.", Int64(values.count)) : ""
            return lines.joined(separator: "\n") + limit + hint
        }
        switch command.name {
        case "listidol", "showidol":
            let values = command.name == "listidol" ? idols.sorted { $0.name < $1.name }
                : [try unique(idols, id: { $0.id }, name: { $0.name }, token: command.target ?? "")]
            remember(values.prefix(100).map { .init(kind: .idol, id: $0.id) })
            return numbered(values.map { item in
                [item.name, item.group, item.birthday, item.note.isEmpty ? nil : item.note].compactMap { $0 }.joined(separator: " · ")
            })
        case "listevent", "showevent":
            let values = command.name == "listevent" ? events.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                : [try unique(events, id: { $0.id }, name: { $0.name }, token: command.target ?? "")]
            remember(values.prefix(100).map { .init(kind: .event, id: $0.id) })
            return numbered(values.map { item in
                [item.name, item.date.map { ChekinanaDisplayFormat.date($0) }, item.city, item.resolvedLivehouse, item.price,
                 item.note.isEmpty ? nil : item.note].compactMap { $0 }.joined(separator: " · ")
            })
        default: break
        }
        let media = try snapshot.fetch(FetchDescriptor<MediaItem>()).filter { $0.kind == .cheki }
        let simple = try snapshot.fetch(FetchDescriptor<ChekiRecord>())
        let filterIdol = try command.arguments["idol"].map { try unique(idols, id: { $0.id }, name: { $0.name }, token: $0) }
        let filterIdolIDs: Set<UUID>? = try command.arguments["idols"].map { value in
            Set(try value.split(separator: ",").map { token in try unique(idols, id: { $0.id }, name: { $0.name }, token: String(token)).id })
        } ?? filterIdol.map { Set([$0.id]) }
        let filterEvent = try command.arguments["event"].map { try unique(events, id: { $0.id }, name: { $0.name }, token: $0) }
        var rows = media.map { ChekinanaAssistantStatistics.Row(source: .media, id: $0.id, idolIDs: Set($0.idolIDs), date: $0.date.map(ChekinanaDateOnly.string), eventID: $0.eventID) }
        rows += simple.map { .init(source: .simple, id: $0.id, idolIDs: Set($0.idolIDs), date: $0.date.map(ChekinanaDateOnly.string), eventID: $0.eventID, count: $0.count) }
        let from = command.arguments["date_from"] ?? command.arguments["date"]
        let to = command.arguments["date_to"] ?? command.arguments["date"]
        guard (from == nil) == (to == nil),
              [from, to].compactMap({ $0 }).allSatisfy(ChekinanaNLSchemaValidator.isCalendarDate),
              from == nil || from! <= to! else { throw ReadError.invalidData }
        let allowed: Set<String> = command.name == "showrecord" ? ["target"] : ["idol", "idols", "event", "date", "date_from", "date_to"]
        guard Set(command.arguments.keys).isSubset(of: allowed) else { throw ChekinanaNLClientError.invalidSchema }
        let query = ChekinanaAssistantStatistics.Query(idolIDs: filterIdolIDs, eventID: filterEvent?.id, dateFrom: from, dateTo: to)
        if command.name == "statscheki" {
            let result: ChekinanaAssistantStatistics.Result
            do { result = try ChekinanaAssistantStatistics.aggregate(rows: rows, hiddenIdolIDs: hidden, query: query) }
            catch { throw ReadError.invalidData }
            dialogue.statistics = .init(idol: filterIdol?.name, event: filterEvent?.name, dateFrom: from, dateTo: to)
            dialogue.statisticsIdolID = filterIdol?.id
            dialogue.statisticsEventID = filterEvent?.id
            dialogue.statisticsGeneration = try ChekinanaLibraryGenerationStore.current(in: snapshot)
            dialogue.target = nil
            dialogue.choiceSource = .none
            dialogue.choices = []
            let range = from.map { "\($0) – \(to ?? $0)" } ?? ChekinanaL10n.text("assistant.dialog.all_dates", fallback: "All dates")
            var lines = [[filterIdol?.name, filterEvent?.name, range].compactMap { $0 }.joined(separator: " · "), ChekinanaL10n.format("assistant.dialog.stats_total", fallback: "Total: %1$lld Cheki (%2$lld with photos, %3$lld without photos).", Int64(result.total), Int64(result.withImage), Int64(result.withoutImage))]
            for (id, count) in result.byIdol.filter({ filterIdol == nil || $0.key == filterIdol!.id }).sorted(by: { $0.value == $1.value ? (names[$0.key] ?? "") < (names[$1.key] ?? "") : $0.value > $1.value }) {
                lines.append(ChekinanaL10n.format("assistant.dialog.stats_idol", fallback: "%1$@: %2$lld Cheki", names[id] ?? ChekinanaL10n.text("assistant.dialog.unassigned", fallback: "Unassigned"), Int64(count)))
            }
            if result.unassociatedCount > 0 { lines.append(ChekinanaL10n.format("assistant.dialog.stats_unassigned", fallback: "Unassigned: %lld Cheki", Int64(result.unassociatedCount))) }
            if result.undatedCount > 0 { lines.append(ChekinanaL10n.format("assistant.dialog.stats_undated", fallback: "Includes %lld Cheki without a record date.", Int64(result.undatedCount))) }
            if result.excludedUndatedCount > 0 { lines.append(ChekinanaL10n.format("assistant.dialog.stats_excluded", fallback: "%lld undated Cheki were excluded from this date range.", Int64(result.excludedUndatedCount))) }
            lines.append(ChekinanaL10n.text("assistant.dialog.stats_basis", fallback: "Counts currently visible records only: 1 per photo and the saved quantity for records without photos. Date ranges use the record date and include both endpoints. Cheki shared by multiple Idols count for each Idol, but only once in the total."))
            return lines.joined(separator: "\n")
        }
        rows = rows.filter { row in
            row.idolIDs.isDisjoint(with: hidden)
                && (filterIdolIDs == nil || !row.idolIDs.isDisjoint(with: filterIdolIDs!))
                && (filterEvent == nil || row.eventID == filterEvent!.id)
                && (from == nil || (row.date != nil && row.date! >= from! && row.date! <= to!))
        }
        if command.name == "listrecord" || command.name == "showrecord" { rows = rows.filter { $0.source == .simple } }
        if command.name == "showrecord" {
            let token = command.arguments["target"] ?? ""
            rows = rows.filter { $0.id.uuidString.lowercased().hasPrefix(token.lowercased()) }
            guard rows.count == 1 else { throw rows.isEmpty ? ReadError.missing : ReadError.ambiguous }
        }
        rows.sort { ($0.date ?? "") == ($1.date ?? "") ? $0.id.uuidString < $1.id.uuidString : ($0.date ?? "") > ($1.date ?? "") }
        remember(rows.prefix(100).map { .init(kind: $0.source == .media ? .cheki : .chekiRecord, id: $0.id) })
        return numbered(rows.map { row in
            let people = row.idolIDs.compactMap { names[$0] }.sorted().joined(separator: ", ")
            let type = row.source == .media ? ChekinanaL10n.text("assistant.dialog.with_photo", fallback: "With photo") : ChekinanaL10n.text("assistant.dialog.without_photo", fallback: "Without photo")
            return [people.isEmpty ? ChekinanaL10n.text("assistant.dialog.unassigned", fallback: "Unassigned") : people,
                    row.date ?? ChekinanaL10n.text("assistant.dialog.no_date", fallback: "No record date"),
                    ChekinanaRecordKind.cheki.countLabel(row.source == .media ? 1 : row.count), type,
                    row.eventID.flatMap { eventNames[$0] }].compactMap { $0 }.joined(separator: " · ")
        })
    }
}

/// Shared by the live URL flow and host tests; fetching remains injected so
/// verification never contacts an extraction service or language model.
enum ChekinanaAssistantEventFlow {
    enum Step: Equatable {
        case missing([ChekinanaNLMissing])
        case city
        case invalid([ChekinanaEventCandidateBlocker])
        case ready
    }

    static func extractionURL(in operations: [ChekinanaNLOperation]) throws -> String? {
        let urls = operations.filter { $0.intent == .addevent }.compactMap { $0.slots.url }
        guard !urls.isEmpty else { return nil }
        guard operations.count == 1, urls.count == 1,
              let url = urls.first, ChekinanaEventSource.validatedURL(from: url) != nil else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return url
    }

    @MainActor
    static func extract(url: String, loader: @MainActor (String) async throws -> ChekinanaEventCandidateFields) async throws -> ChekinanaEventCandidateFields {
        guard ChekinanaEventSource.validatedURL(from: url) != nil else { throw ChekinanaNLClientError.invalidSchema }
        return try await loader(url)
    }

    static func merge(_ fields: ChekinanaEventCandidateFields, operation: ChekinanaNLOperation?) -> ChekinanaEventCandidateFields {
        guard let operation, operation.intent == .addevent else { return fields }
        let slots = operation.slots
        var result = fields
        if let value = slots.name { result.name = value }
        if let value = slots.date { result.date = value }
        if let value = slots.city { result.city = value }
        if let value = slots.livehouse { result.livehouse = value }
        if let value = slots.price { result.price = value }
        if let value = slots.ticketURL { result.ticketURL = value }
        if let value = slots.note { result.note = value }
        if let value = slots.url { result.weiboURL = value }
        return result
    }

    /// Returns a local continuation before the controller considers another URL extraction.
    /// A full pending-write correction must still arrive as a complete ready plan.
    static func continuedCandidate(
        for interpretation: ChekinanaNLInterpretation,
        retained fields: ChekinanaEventCandidateFields?,
        resolvedOperation operation: ChekinanaNLOperation?,
        isCorrection: Bool
    ) throws -> ChekinanaEventCandidateFields? {
        guard let fields, let operation, operation.intent == .addevent else { return nil }
        switch interpretation {
        case .plan: break
        case .clarify(let draft, let missing):
            guard !isCorrection, draft.intent == .addevent else { throw ChekinanaNLClientError.invalidSchema }
            try ChekinanaNLSchemaValidator.validateDraft(draft, missing: missing)
        case .reject: return nil
        }
        let merged = merge(fields, operation: operation)
        if isCorrection, nextStep(for: merged) != .ready { throw ChekinanaNLClientError.invalidSchema }
        return merged
    }

    static func operation(for fields: ChekinanaEventCandidateFields) -> ChekinanaNLOperation {
        func nonempty(_ value: String) -> String? { value.isEmpty ? nil : value }
        return .init(intent: .addevent, slots: .init(
            name: nonempty(fields.name), url: nonempty(fields.weiboURL), date: nonempty(fields.date),
            note: nonempty(fields.note), city: nonempty(fields.city), livehouse: nonempty(fields.livehouse),
            price: nonempty(fields.price), ticketURL: nonempty(fields.ticketURL)
        ))
    }

    static func previewCard(_ fields: ChekinanaEventCandidateFields, confirmationCode: String) -> ChekinanaEventCard {
        ChekinanaEventCard(id: UUID(), name: fields.name, date: fields.date, city: fields.city,
            livehouse: fields.livehouse, price: fields.price, weiboURL: fields.weiboURL,
            ticketURL: fields.ticketURL, openTime: fields.openTime, startTime: fields.startTime,
            note: fields.note, confirmationCode: confirmationCode)
    }

    static func nextStep(for fields: ChekinanaEventCandidateFields) -> Step {
        let missing = ChekinanaNLSchemaValidator.expectedMissing(for: operation(for: fields))
        if !missing.isEmpty { return .missing(missing) }
        if fields.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .city }
        let blockers = ChekinanaEventCandidateValidator.blockers(for: fields)
        return blockers.isEmpty ? .ready : .invalid(blockers)
    }
}

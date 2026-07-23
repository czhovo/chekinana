import Foundation

enum ChekinanaTranslationSource: String, Sendable {
    case passthrough
    case rule
    case none
}

enum ChekinanaTranslationDisposition: Sendable, Equatable {
    case localCommand
    case localClarification
    case remoteFallback
}

struct ChekinanaNaturalLanguageTranslation: Sendable, Equatable {
    let command: String?
    let additionalCommands: [String]
    let intent: String?
    let source: ChekinanaTranslationSource
    let disposition: ChekinanaTranslationDisposition
    let confidence: Double
    let needsClarification: Bool
    let message: String
    let candidates: [String]

    init(
        command: String?,
        additionalCommands: [String] = [],
        intent: String?,
        source: ChekinanaTranslationSource,
        disposition: ChekinanaTranslationDisposition = .localCommand,
        confidence: Double,
        needsClarification: Bool,
        message: String,
        candidates: [String]
    ) {
        self.command = command
        self.additionalCommands = additionalCommands
        self.intent = intent
        self.source = source
        self.disposition = disposition
        self.confidence = confidence
        self.needsClarification = needsClarification
        self.message = message
        self.candidates = candidates
    }

    var commands: [String] {
        guard let command else { return [] }
        return [command] + additionalCommands
    }

    var requiresLocalClarification: Bool {
        disposition == .localClarification
    }
}

struct ChekinanaLocalEventDraft: Equatable, Sendable {
    let operation: ChekinanaNLOperation
    let missing: [ChekinanaNLMissing]
}

enum ChekinanaLocalEventLanguage {
    static func draft(from input: String) -> ChekinanaLocalEventDraft? {
        guard let payload = firstCapture(
            #"^\s*(?:请|麻烦|帮我|现在请)?\s*(?:添加|新增|创建|录入)(?:一个)?\s*(?:event|活动|场次)\s+(.+?)\s*[。！!？?]*$"#,
            in: input
        ),
        let parts = captures(#"^(https?://\S+?)(?:\s+(.+))?$"#, in: payload),
        let rawURL = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
        ChekinanaNLSchemaValidator.isSafeHTTPURL(rawURL) else {
            return nil
        }

        let suffix = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        var name: String?
        var date: String?
        if let values = captures(
            #"^(?:名称|名字|name)\s+(.+?)\s+(?:日期|date)\s+(\d{4}-\d{2}-\d{2})$"#,
            in: suffix
        ) {
            name = nonempty(values[0])
            date = values[1]
        } else if let values = captures(
            #"^(?:日期|date)\s+(\d{4}-\d{2}-\d{2})\s+(?:名称|名字|name)\s+(.+)$"#,
            in: suffix
        ) {
            date = values[0]
            name = nonempty(values[1])
        } else if let value = firstCapture(#"^(?:名称|名字|name)\s+(.+)$"#, in: suffix) {
            name = nonempty(value)
        } else if let value = firstCapture(#"^(?:日期|date)\s+(\d{4}-\d{2}-\d{2})$"#, in: suffix) {
            date = value
        }

        let operation = ChekinanaNLOperation(
            intent: .addevent,
            slots: .init(name: name, url: rawURL, date: date)
        )
        return ChekinanaLocalEventDraft(
            operation: operation,
            missing: ChekinanaNLSchemaValidator.expectedMissing(for: operation)
        )
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.first
    }
}

/// Offline-only, Foundation-only translation from one user utterance to one
/// canonical Chekinana command. It validates syntax but never executes it.
enum ChekinanaNaturalLanguageTranslator {
    static let commandNames = [
        "help", "confirm", "cancel", "clear", "addidol", "listidol",
        "showidol", "editidol", "deleteidol", "scancheki",
        "addevent", "listevent", "showevent", "editevent", "deleteevent",
        "discardcheki", "addcheki", "addscancheki", "listcheki",
        "showcheki", "editcheki", "downloadcheki", "deletecheki",
    ]

    static func translate(_ input: String) -> ChekinanaNaturalLanguageTranslation {
        let normalized = normalize(input)
        guard !normalized.isEmpty else {
            return clarification("请输入一个需求")
        }

        let first = normalized.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).first.map(String.init)?.lowercased()
        let isDirectAddEvent = first == "addevent"
        if containsControlSyntax(normalized, allowingAmpersand: isDirectAddEvent) {
            if normalized.contains(";") && detectsMultipleIntents(normalized) {
                return clarification("一次只能转换一个操作，请拆开描述")
            }
            return clarification("输入包含换行或命令控制字符，已拒绝转换")
        }

        if first.map(commandNames.contains) == true || isCode(normalized) {
            let checked = validateCommand(normalized)
            if let command = checked.command {
                return .init(
                    command: command,
                    intent: checked.intent,
                    source: .passthrough,
                    confidence: 1,
                    needsClarification: false,
                    message: checked.message,
                    candidates: []
                )
            }
            return clarification(checked.message, intent: first.flatMap { commandNames.contains($0) ? $0 : nil })
        }

        var cleaned = replacing(#"^(?:请|麻烦|帮我|可以帮我|我想要|我想|我要|我需要|现在请)\s*"#, in: normalized, with: "")
        cleaned = replacing(#"\s*(?:吧|一下|一下吧|可以吗|谢谢|好吗|好么)[。！!？?]*$"#, in: cleaned, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains("\\") {
            return clarification("输入参数无法由 App parser 无损表示")
        }
        let withoutAssignmentQuotes = replacing(#"\b[A-Za-z_][A-Za-z0-9_]*=\"[^\"]*\""#, in: cleaned, with: "")
        if withoutAssignmentQuotes.contains("\"") {
            return clarification("输入参数无法由 App parser 无损表示")
        }
        if let commands = ruleAddMultipleIdols(cleaned), commands.count > 1 {
            return .init(
                command: commands[0],
                additionalCommands: Array(commands.dropFirst()),
                intent: "addidol",
                source: .rule,
                confidence: 0.97,
                needsClarification: false,
                message: "识别为批量添加 Idol",
                candidates: []
            )
        }
        if detectsMultipleIntents(cleaned) {
            return clarification("一次只能转换一个操作，请拆开描述")
        }

        let ruleResults = [
            ruleHelp(cleaned),
            ruleConfirmCancelClear(cleaned),
            ruleAddScanCheki(cleaned),
            ruleScanDiscard(cleaned),
            ruleAddAlbumCheki(cleaned),
            ruleEventCRUD(cleaned),
            ruleChekiShowEdit(cleaned),
            ruleChekiListDownloadDelete(cleaned),
            ruleEditIdol(cleaned),
            ruleDeleteIdol(cleaned),
            ruleAddIdol(cleaned),
            ruleIdolListShow(cleaned),
        ]
        for match in ruleResults.compactMap({ $0 }) {
            guard let command = match.command else {
                return clarification(match.message.isEmpty ? "缺少必要参数" : match.message, intent: match.intent)
            }
            return .init(
                command: command,
                intent: match.intent,
                source: .rule,
                confidence: match.confidence,
                needsClarification: false,
                message: match.message,
                candidates: []
            )
        }

        let candidates = scoredCandidates(cleaned).map(\.intent)
        return clarification(
            "离线规则无法确定唯一命令，请补充或改写需求",
            intent: candidates.count == 1 ? candidates[0] : nil,
            candidates: candidates,
            // Candidate scoring is diagnostic only. A product keyword is not
            // enough to turn an otherwise unparsed natural-language request
            // into a local clarification; the remote interpreter may still
            // be able to produce a complete structured operation.
            allowsRemoteFallback: true
        )
    }
}

enum ChekinanaASCIIScannerCommand {
    static let canonical = "scancheki"

    static func exactCanonical(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(trimmed.utf8)
        guard bytes.allSatisfy({ $0 < 128 }),
              asciiLowercased(bytes) == Array(canonical.utf8) else {
            return nil
        }
        return canonical
    }

    static func hasCaseInsensitivePrefix(_ input: String) -> Bool {
        let bytes = Array(input.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let prefix = Array(canonical.utf8)
        guard bytes.count >= prefix.count else { return false }
        return asciiLowercased(Array(bytes.prefix(prefix.count))) == prefix
    }

    private static func asciiLowercased(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { byte in
            (65...90).contains(byte) ? byte + 32 : byte
        }
    }
}

enum ChekinanaPromptRouting {
    static func localBareScannerCommand(from input: String) -> String? {
        ChekinanaASCIIScannerCommand.exactCanonical(from: input)
    }

    static func localStateCommand(from input: String) -> String? {
        let translation = ChekinanaNaturalLanguageTranslator.translate(input)
        guard translation.additionalCommands.isEmpty,
              !translation.needsClarification,
              let intent = translation.intent,
              ["confirm", "cancel", "clear"].contains(intent),
              let command = translation.command else {
            return nil
        }
        return command
    }
}

struct ChekinanaQuickActionDefinition: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case addIdol = "add-idol"
        case eventFromWeibo = "event-weibo"
        case scanPhotos = "scan-photos"
        case listCheki = "list-cheki"
    }

    let kind: Kind
    let label: String

    var id: String { kind.rawValue }

    func suggestedPrompt(hasSelectedPhotos: Bool) -> String {
        switch kind {
        case .addIdol:
            "添加 Idol "
        case .eventFromWeibo:
            "根据这条公开微博创建 Event："
        case .scanPhotos:
            hasSelectedPhotos ? "扫描已选择的照片" : "请先选择照片，再扫描这些照片"
        case .listCheki:
            "查看所有 Cheki"
        }
    }
}

enum ChekinanaQuickActions {
    static let all: [ChekinanaQuickActionDefinition] = [
        .init(kind: .addIdol, label: "添加 Idol"),
        .init(kind: .eventFromWeibo, label: "微博建 Event"),
        .init(kind: .scanPhotos, label: "扫描照片"),
        .init(kind: .listCheki, label: "查看 Cheki"),
    ]

    static func prefilledPrompt(
        currentPrompt: String,
        action: ChekinanaQuickActionDefinition,
        hasSelectedPhotos: Bool
    ) -> String {
        guard shouldApply(to: currentPrompt) else {
            return currentPrompt
        }
        return action.suggestedPrompt(hasSelectedPhotos: hasSelectedPhotos)
    }

    static func shouldApply(to currentPrompt: String) -> Bool {
        currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ChekinanaTranscriptEmptyStatePolicy {
    static func shouldShow(
        messageCount: Int,
        hasDraft: Bool,
        hasEventCandidatePanel: Bool
    ) -> Bool {
        messageCount == 0 && !hasDraft && !hasEventCandidatePanel
    }
}

private extension ChekinanaNaturalLanguageTranslator {
    struct RuleMatch {
        let command: String?
        let intent: String?
        let confidence: Double
        let message: String
    }

    struct Validation {
        let command: String?
        let intent: String?
        let message: String
    }

    struct CommandTokens {
        let positional: [String]
        let values: [(key: String, value: String)]
    }

    static func clarification(
        _ message: String,
        intent: String? = nil,
        candidates: [String] = [],
        allowsRemoteFallback: Bool = false
    ) -> ChekinanaNaturalLanguageTranslation {
        .init(
            command: nil,
            intent: intent,
            source: .none,
            disposition: allowsRemoteFallback ? .remoteFallback : .localClarification,
            confidence: 0,
            needsClarification: true,
            message: message,
            candidates: candidates
        )
    }

    static func normalize(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "＝", with: "=")
            .replacingOccurrences(of: "：", with: ":")
        return replacing(#"[\t\u3000 ]+"#, in: value, with: " ")
    }

    static func cleanPhrase(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = replacing(#"^(?:请|麻烦|帮我|可以帮我|我想要|我想|我要|我需要|现在请)\s*"#, in: value, with: "")
        value = replacing(#"\s*(?:吧|一下|一下吧|可以吗|谢谢|好吗|好么)[。！!？?]*$"#, in: value, with: "")
        value = replacing(#"[。！!？?，,：:]\s*$"#, in: value, with: "")
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " 的\t"))
    }

    static func containsControlSyntax(_ text: String, allowingAmpersand: Bool = false) -> Bool {
        regexContains(allowingAmpersand ? #"[\r\n;|`<>]|\$\("# : #"[\r\n;|&`<>]|\$\("#, in: text)
    }

    static func isCode(_ text: String) -> Bool {
        fullMatch(#"[0-9a-fA-F]{8}"#, text) != nil
    }

    static func quoteValue(_ value: String, positional: Bool = false, allowingAmpersand: Bool = false) throws -> String {
        guard !value.isEmpty else { throw TranslationError.invalidValue }
        guard !containsControlSyntax(value, allowingAmpersand: allowingAmpersand),
              !regexContains(#"[\"\\\x00-\x1f\x7f]"#, in: value),
              !(positional && value.contains("=")) else {
            throw TranslationError.invalidValue
        }
        return value.contains(where: \Character.isWhitespace) ? "\"\(value)\"" : value
    }

    enum TranslationError: Error {
        case invalidValue
        case invalidCommand(String)
    }

    static func tokenize(_ input: String) throws -> [String] {
        let isDirectAddEvent = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("addevent ")
        if containsControlSyntax(input, allowingAmpersand: isDirectAddEvent) {
            throw TranslationError.invalidCommand("输入包含换行或命令控制字符")
        }
        if input.contains("\\") {
            throw TranslationError.invalidCommand("反斜杠无法由 App parser 无损处理")
        }

        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        var justClosedQuote = false
        for character in input {
            if character == "\"" {
                if !isQuoted {
                    if !current.isEmpty && !current.hasSuffix("=") {
                        throw TranslationError.invalidCommand("双引号只能包围完整参数值")
                    }
                    if justClosedQuote {
                        throw TranslationError.invalidCommand("参数包含无法表示的双引号")
                    }
                    isQuoted = true
                } else {
                    isQuoted = false
                    justClosedQuote = true
                }
                continue
            }
            if character.isWhitespace && !isQuoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                justClosedQuote = false
                continue
            }
            if justClosedQuote && !character.isWhitespace {
                throw TranslationError.invalidCommand("结束引号后必须是参数分隔空白")
            }
            current.append(character)
        }
        if isQuoted {
            throw TranslationError.invalidCommand("命令引号不完整")
        }
        if !current.isEmpty { tokens.append(current) }
        if tokens.isEmpty { throw TranslationError.invalidCommand("输入为空") }
        return tokens
    }

    static func splitTokens(_ tokens: ArraySlice<String>, commandName: String) throws -> CommandTokens {
        var positional: [String] = []
        var values: [(String, String)] = []
        var keys: Set<String> = []
        for token in tokens {
            if commandName == "addevent",
               positional.isEmpty,
               token.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
                positional.append(token)
                continue
            }
            guard let index = token.firstIndex(of: "=") else {
                positional.append(token)
                continue
            }
            let key = String(token[..<index]).lowercased()
            let value = String(token[token.index(after: index)...])
            guard fullMatch(#"[a-zA-Z_][a-zA-Z0-9_]*"#, key) != nil, !value.isEmpty else {
                throw TranslationError.invalidCommand("字段必须使用 field=value，且 value 不能为空")
            }
            guard keys.insert(key).inserted else {
                throw TranslationError.invalidCommand("字段重复：\(key)")
            }
            values.append((key, value))
        }
        return .init(positional: positional, values: values)
    }

    static func validateCommand(_ raw: String) -> Validation {
        do {
            let tokens = try tokenize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            if tokens.count == 1, isCode(tokens[0]) {
                return .init(command: "confirm \(tokens[0].lowercased())", intent: "confirm", message: "八位确认码已规范化")
            }
            let name = tokens[0].lowercased()
            guard commandNames.contains(name) else {
                return .init(command: nil, intent: nil, message: "未注册命令：\(name)")
            }
            var split = try splitTokens(tokens.dropFirst(), commandName: name)
            let keys = Set(split.values.map(\.key))

            switch name {
            case "help", "clear", "listidol", "listevent":
                guard split.positional.isEmpty, split.values.isEmpty else {
                    throw TranslationError.invalidCommand("\(name) 不接受参数")
                }
            case "scancheki":
                let allowed: Set<String> = [
                    "pod", "expected", "scanner_size", "postprocess", "wb", "date_annotation",
                ]
                guard split.positional.count <= 1,
                      keys.isSubset(of: allowed),
                      !(split.positional.count == 1 && keys.contains("pod")),
                      split.positional.count == 1 || keys.contains("pod") else {
                    throw TranslationError.invalidCommand("scancheki 需要指定 Pod")
                }
            case "confirm":
                guard split.values.isEmpty, split.positional.count <= 1 else {
                    throw TranslationError.invalidCommand("confirm 只接受一个可选的八位确认码")
                }
                if let code = split.positional.first {
                    guard isCode(code) else { throw TranslationError.invalidCommand("确认码必须是八位十六进制字符") }
                    split = .init(positional: [code.lowercased()], values: split.values)
                }
            case "cancel":
                guard split.values.isEmpty, split.positional.count == 1 else {
                    throw TranslationError.invalidCommand("cancel 需要八位确认码或 all")
                }
                let value = split.positional[0]
                guard value.lowercased() == "all" || isCode(value) else {
                    throw TranslationError.invalidCommand("cancel 需要八位确认码或 all")
                }
                split = .init(positional: [value.lowercased()], values: split.values)
            case "addidol", "showidol", "deleteidol", "showevent", "deleteevent", "discardcheki", "showcheki", "downloadcheki", "deletecheki":
                guard split.values.isEmpty, split.positional.count == 1 else {
                    throw TranslationError.invalidCommand("\(name) 需要且只接受一个目标")
                }
            case "editidol":
                let allowed: Set<String> = ["name", "group", "birthday", "color", "verification", "bio", "avatar", "avatar_url"]
                guard split.positional.count == 1, !split.values.isEmpty else {
                    throw TranslationError.invalidCommand("editidol 需要目标和至少一个 field=value")
                }
                guard keys.isSubset(of: allowed) else {
                    throw TranslationError.invalidCommand("editidol 不支持字段")
                }
            case "addevent":
                guard split.positional.count == 1,
                      keys.isSubset(of: ["name", "date"]) else {
                    throw TranslationError.invalidCommand("addevent 需要名称和 date=YYYY-MM-DD；URL 可选")
                }
                if split.positional[0].range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    guard ChekinanaNLSchemaValidator.isSafeHTTPURL(split.positional[0]) else {
                        throw TranslationError.invalidCommand("Event URL 不能包含用户名或密码")
                    }
                    guard keys == Set(["name", "date"]) else {
                        throw TranslationError.invalidCommand("通过 URL 添加 Event 时必须同时提供 name 和 date")
                    }
                } else {
                    guard keys == Set(["date"]) else {
                        throw TranslationError.invalidCommand("通过名称添加 Event 时必须提供 date")
                    }
                }
            case "editevent":
                guard split.positional.count == 1,
                      !split.values.isEmpty,
                      keys.isSubset(of: ["name", "date", "url"]) else {
                    throw TranslationError.invalidCommand("editevent 需要目标和 name/date/url 字段")
                }
                if let url = split.values.first(where: { $0.key == "url" })?.value,
                   url != "-",
                   !ChekinanaNLSchemaValidator.isSafeHTTPURL(url) {
                    throw TranslationError.invalidCommand("Event URL 不能包含用户名或密码")
                }
            case "addcheki":
                let allowed: Set<String> = ["idol", "idols", "event", "date", "user", "userappears", "size", "note"]
                guard split.positional.count <= 1, keys.isSubset(of: allowed) else {
                    throw TranslationError.invalidCommand("addcheki 参数不符合注册表")
                }
                guard !(split.positional.count == 1 && !keys.intersection(["idol", "idols"]).isEmpty),
                      !keys.isSuperset(of: ["idol", "idols"]),
                      split.positional.count == 1 || !keys.intersection(["idol", "idols"]).isEmpty else {
                    throw TranslationError.invalidCommand("addcheki 缺少或重复 Idol")
                }
                let values = Dictionary(uniqueKeysWithValues: split.values)
                guard keys.intersection(["event", "date"]).count == 1 else {
                    throw TranslationError.invalidCommand("addcheki 必须且只能提供 event 或 date")
                }
                for key in ["user", "userappears"] {
                    if let value = values[key], !["true", "false", "?", "-"].contains(value.lowercased()) {
                        throw TranslationError.invalidCommand("user 必须是 true、false、? 或 -")
                    }
                }
                if let size = values["size"], !["mini", "wide", "else", "?", "-"].contains(size.lowercased()) {
                    throw TranslationError.invalidCommand("size 必须是 mini、wide、else、? 或 -")
                }
            case "addscancheki":
                let allowed: Set<String> = ["idol", "idols", "event", "date", "user", "userappears", "size", "note"]
                guard split.positional.count == 1,
                      keys.isSubset(of: allowed),
                      !keys.isSuperset(of: ["idol", "idols"]),
                      !keys.intersection(["idol", "idols"]).isEmpty,
                      keys.intersection(["event", "date"]).count == 1 else {
                    throw TranslationError.invalidCommand("addscancheki 需要临时 Cheki、idol，以及 event/date 二选一")
                }
            case "listcheki":
                guard split.positional.isEmpty, keys.isSubset(of: ["idol", "event", "date"]) else {
                    throw TranslationError.invalidCommand("listcheki 只接受 idol/event/date 字段")
                }
                guard !keys.isSuperset(of: ["event", "date"]) else {
                    throw TranslationError.invalidCommand("listcheki 的 event/date 不能同时提供")
                }
            case "editcheki":
                let allowed: Set<String> = ["idol", "idols", "event", "date", "user", "userappears", "size", "note"]
                guard split.positional.count == 1,
                      !split.values.isEmpty,
                      keys.isSubset(of: allowed),
                      !keys.isSuperset(of: ["idol", "idols"]),
                      !keys.isSuperset(of: ["user", "userappears"]),
                      !keys.isSuperset(of: ["event", "date"]) else {
                    throw TranslationError.invalidCommand("editcheki 需要目标和有效字段；event/date 不能同时提供")
                }
            default:
                throw TranslationError.invalidCommand("未注册命令：\(name)")
            }

            var parts = [name]
            parts += try split.positional.map {
                if name == "addevent", $0.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    return try quoteValue($0, allowingAmpersand: true)
                }
                return try quoteValue($0, positional: true)
            }
            parts += try split.values.map { "\($0.key)=\(try quoteValue($0.value))" }
            return .init(command: parts.joined(separator: " "), intent: name, message: "命令有效")
        } catch TranslationError.invalidCommand(let message) {
            return .init(command: nil, intent: nil, message: message)
        } catch {
            return .init(command: nil, intent: nil, message: "输入参数无法由 App parser 无损表示")
        }
    }

    static func resultFromCommand(_ command: String, intent: String, confidence: Double, message: String) -> RuleMatch {
        let checked = validateCommand(command)
        return .init(command: checked.command, intent: checked.intent ?? intent, confidence: checked.command == nil ? 0 : confidence, message: checked.command == nil ? checked.message : message)
    }

    static func ruleHelp(_ text: String) -> RuleMatch? {
        guard fullMatch(#"(?:帮助|显示帮助|打开帮助|使用说明|命令说明|有哪些命令|都有哪些命令|怎么用|如何使用)"#, text) != nil else { return nil }
        return resultFromCommand("help", intent: "help", confidence: 0.99, message: "识别为查看帮助")
    }

    static func ruleConfirmCancelClear(_ text: String) -> RuleMatch? {
        let compact = replacing(#"\s+"#, in: text, with: "")
        let code = firstCapture(#"(?<![0-9a-fA-F])([0-9a-fA-F]{8})(?![0-9a-fA-F])"#, in: text)
        if fullMatch(#"(?:确认|确认上一步|确认上一条|确认刚才的操作|执行刚才的操作|同意刚才的操作)"#, compact) != nil {
            return resultFromCommand("confirm", intent: "confirm", confidence: 0.99, message: "识别为确认最近操作")
        }
        if fullMatch(#"(?:(?:上一笔|上一步|上一条).*(?:落锤|执行)(?:了)?|(?:就按|按).*(?:刚才|上一笔|上一步|上一条).*(?:执行|操作))"#, compact) != nil {
            return resultFromCommand("confirm", intent: "confirm", confidence: 0.96, message: "识别为确认最近操作")
        }
        if fullMatch(#"(?:取消|撤销)(?:全部|所有)(?:待确认)?(?:操作)?"#, compact) != nil {
            return resultFromCommand("cancel all", intent: "cancel", confidence: 0.99, message: "识别为取消全部待确认操作")
        }
        if regexContains(#"(?:取消|撤销)"#, in: compact), let code {
            return resultFromCommand("cancel \(code)", intent: "cancel", confidence: 0.98, message: "识别为取消指定操作")
        }
        if regexContains(#"(?:确认|执行|同意).*(?:确认码|编号|操作)?"#, in: compact), let code {
            return resultFromCommand("confirm \(code)", intent: "confirm", confidence: 0.98, message: "识别为指定确认码")
        }
        if fullMatch(#"(?:清屏|清空屏幕|清空界面|清空输出|清空聊天|清空聊天记录|清除屏幕|清除显示记录)"#, compact) != nil ||
            fullMatch(#"(?:擦掉|清掉|清除)屏幕上的(?:对话|内容|记录)"#, compact) != nil {
            return resultFromCommand("clear", intent: "clear", confidence: 0.99, message: "识别为清空可见记录")
        }
        return nil
    }

    static func ruleIdolListShow(_ text: String) -> RuleMatch? {
        let compact = replacing(#"\s+"#, in: text, with: "")
        if fullMatch(#"列出(?:全部|所有|我的|已添加的|本地的)?(?:idol|偶像|爱豆)(?:列表|清单|名册)?"#, compact) != nil ||
            fullMatch(#"(?:显示|查看|打开)(?:(?:全部|所有|我的|已添加的|本地的)(?:idol|偶像|爱豆)(?:列表|清单|名册)?|(?:idol|偶像|爱豆)(?:列表|清单|名册))"#, compact) != nil ||
            fullMatch(#"(?:把)?(?:idol|偶像|爱豆)(?:花名册|清单|名册)(?:摊开|展示|打开)(?:给我看|看看|出来)?"#, compact) != nil {
            return resultFromCommand("listidol", intent: "listidol", confidence: 0.98, message: "识别为列出本地 Idol")
        }
        let patterns = [
            #"^(?:查看|显示|打开|查询|查一下)(?:idol|偶像|爱豆)(?:详情)?\s+(.+)$"#,
            #"^(?:查看|显示|打开|查询|查一下)\s*(.+?)\s*(?:这个|这位)?(?:idol|偶像|爱豆)(?:的)?(?:详情|资料)?$"#,
            #"^(.+?)(?:这个|这位)?(?:idol|偶像|爱豆)(?:的)?(?:详情|资料)$"#,
            #"^(?:让我)?看看\s*(.+?)的(?:个人)?(?:详情|资料)$"#,
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: text) {
                let target = cleanPhrase(value)
                if !target.isEmpty, let quoted = try? quoteValue(target) {
                    return resultFromCommand("showidol \(quoted)", intent: "showidol", confidence: 0.94, message: "识别为查看 Idol")
                }
            }
        }
        return nil
    }

    static func ruleAddIdol(_ text: String) -> RuleMatch? {
        let compact = replacing(#"\s+"#, in: text, with: "")
        if fullMatch(#"(?:添加|新增|加入|录入)(?:一个|一位)?(?:idol|偶像|爱豆)"#, compact) != nil {
            return .init(command: nil, intent: "addidol", confidence: 0, message: "请补充要添加的 Idol 名称。")
        }
        let patterns = [
            #"^(?:添加|新增|加入|录入)(?:一个|一位)?(?:名为|叫做?|名称(?:为|是))(.+?)(?:的)?(?:idol|偶像|爱豆)$"#,
            #"^(?:添加|新增|加入|录入)(?:一个|一位)?\s*(?:idol|偶像|爱豆)(?:名为|叫做?|名称(?:为|是))?\s*(.+)$"#,
            #"^(?:把|将)(.+?)(?:这个|这位)?(?:idol|偶像|爱豆)?(?:添加|加入|录入)(?:到|进)?(?:我的)?(?:列表|名册|数据库)?$"#,
            #"^(?:把)?(?:新来的)?(.+?)(?:登记|收录)(?:进|到)(?:idol|偶像|爱豆)(?:册|名册|列表)$"#,
            #"^(?:登记|收录)(?:idol|偶像|爱豆)\s*(.+)$"#,
        ]
        return targetRule(text, patterns: patterns, command: "addidol", confidence: 0.97, message: "识别为搜索并添加 Idol")
    }

    static func ruleAddMultipleIdols(_ text: String) -> [String]? {
        guard let raw = firstCapture(#"^(?:添加|新增|加入|录入)(?:多个|几位|一些)?\s*(?:idol|偶像|爱豆)\s+(.+)$"#, in: text) else {
            return nil
        }
        guard let regex = try? NSRegularExpression(pattern: #"\s*(?:、|，|,|和|以及)\s*"#) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        var names: [String] = []
        var start = raw.startIndex
        for match in regex.matches(in: raw, range: range) {
            guard let matchRange = Range(match.range, in: raw) else { continue }
            names.append(cleanPhrase(String(raw[start..<matchRange.lowerBound])))
            start = matchRange.upperBound
        }
        names.append(cleanPhrase(String(raw[start...])))
        names = names.filter { !$0.isEmpty }
        guard (2...5).contains(names.count) else { return nil }
        let commands = names.compactMap { name -> String? in
            guard let quoted = try? quoteValue(name) else { return nil }
            return validateCommand("addidol \(quoted)").command
        }
        return commands.count == names.count ? commands : nil
    }

    static func ruleDeleteIdol(_ text: String) -> RuleMatch? {
        targetRule(text, patterns: [
            #"^(?:删除|移除)(?:idol|偶像|爱豆)\s+(.+)$"#,
            #"^(?:删除|移除)\s*(.+?)(?:这个|这位)?(?:idol|偶像|爱豆)$"#,
            #"^(?:把|将)\s*(.+?)(?:这个|这位)?(?:idol|偶像|爱豆)(?:删除|移除)(?:掉)?$"#,
        ], command: "deleteidol", confidence: 0.97, message: "识别为删除 Idol；执行仍需确认")
    }

    static func targetRule(_ text: String, patterns: [String], command: String, confidence: Double, message: String) -> RuleMatch? {
        for pattern in patterns {
            if let value = firstCapture(pattern, in: text) {
                let target = cleanPhrase(value)
                if !target.isEmpty, let quoted = try? quoteValue(target) {
                    return resultFromCommand("\(command) \(quoted)", intent: command, confidence: confidence, message: message)
                }
            }
        }
        return nil
    }

    static func ruleEditIdol(_ text: String) -> RuleMatch? {
        if let groups = captures(#"^(?:把|将)?(?:idol|偶像|爱豆)?\s*(.+?)\s*的\s*(名字|名称|name|团体|组合|group|生日|birthday|颜色|color|认证|verification|简介|bio|头像|avatar)\s*(?:修改|改|更新|设置|设)?(?:成|为|成了|到)?\s*(.+)$"#, in: text), groups.count >= 3 {
            let aliases = ["名字": "name", "名称": "name", "name": "name", "团体": "group", "组合": "group", "group": "group", "生日": "birthday", "birthday": "birthday", "颜色": "color", "color": "color", "认证": "verification", "verification": "verification", "简介": "bio", "bio": "bio", "头像": "avatar", "avatar": "avatar"]
            let target = cleanPhrase(groups[0])
            let value = cleanPhrase(groups[2])
            if let field = aliases[groups[1].lowercased()], !target.isEmpty, !value.isEmpty,
               let quotedTarget = try? quoteValue(target), let quotedValue = try? quoteValue(value) {
                return resultFromCommand("editidol \(quotedTarget) \(field)=\(quotedValue)", intent: "editidol", confidence: 0.95, message: "识别为修改 Idol 字段；执行仍需确认")
            }
        }
        if let groups = captures(#"^(?:把|将)?(.+?)的(?:应援色|代表色)(?:修改|改|换|设置)?(?:成|为)\s*(.+)$"#, in: text), groups.count >= 2 {
            let target = cleanPhrase(groups[0])
            let value = cleanPhrase(groups[1])
            if let quotedTarget = try? quoteValue(target), let quotedValue = try? quoteValue(value) {
                return resultFromCommand("editidol \(quotedTarget) color=\(quotedValue)", intent: "editidol", confidence: 0.95, message: "识别为修改 Idol 颜色；执行仍需确认")
            }
        }
        if let groups = captures(#"^(?:修改|编辑|更新)(?:idol|偶像|爱豆)\s+([^ ]+)\s+(.+)$"#, in: text), groups.count >= 2,
           let target = try? quoteValue(cleanPhrase(groups[0])) {
            return resultFromCommand("editidol \(target) \(groups[1])", intent: "editidol", confidence: 0.93, message: "识别为修改 Idol 字段；执行仍需确认")
        }
        return nil
    }

    static func ruleScanDiscard(_ text: String) -> RuleMatch? {
        let compact = replacing(#"\s+"#, in: text, with: "")
        if let podID = firstCapture(
            #"^(?:使用|用)(?:runpod)?pod(?:id)?[：:=]?([a-zA-Z0-9_-]{6,})(?:来)?(?:扫描|扫描选中的照片|扫描已选照片|扫描这些切|扫描这些照片|识别选中的照片)$"#,
            in: compact
        ) {
            return resultFromCommand(
                "scancheki pod=\(podID)",
                intent: "scancheki",
                confidence: 0.99,
                message: "识别为使用指定 Pod 扫描已选照片；扫描结果仍需补充信息并确认"
            )
        }
        if fullMatch(#"(?:扫描|扫描选中的照片|扫描已选照片|扫描这些切|帮我扫描这些切|帮我记录这些切|记录这些切|创建临时cheki|创建扫描临时cheki|把选中照片变成临时cheki|识别选中的照片)"#, compact) != nil {
            return .init(
                command: nil,
                intent: "scancheki",
                confidence: 0,
                message: "请指定已启动的 Pod，例如“使用 Pod <pod_id> 扫描这些切”。Pod ID 只用于本次扫描，不会发送给自然语言服务。"
            )
        }
        let patterns = [
            #"^(?:丢弃|清除|移除|删除)(?:(?:扫描得到的|扫描的)(?:临时)?(?:cheki|切己)|临时(?:cheki|切己))\s*(.+)$"#,
            #"^(?:丢弃|清除|移除|删除)\s*(.+?)(?:这个|这些)?(?:临时cheki|扫描结果)$"#,
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: text) {
                var target = cleanPhrase(value)
                if ["全部", "所有", "全都"].contains(target) { target = "all" }
                if let quoted = try? quoteValue(target) {
                    return resultFromCommand("discardcheki \(quoted)", intent: "discardcheki", confidence: 0.96, message: "识别为丢弃临时 Cheki")
                }
            }
        }
        return nil
    }

    static func ruleAddScanCheki(_ text: String) -> RuleMatch? {
        if let groups = captures(
            #"^(?:把|将)?(?:全部|所有|这些)扫描结果(?:保存|添加|归到|归给)(?:给|到)?\s*(?:idol|偶像|爱豆)?\s*(.+?)[，,]?\s*(?:日期|拍摄日期)(?:是|为)?\s*(\d{4}-\d{2}-\d{2})$"#,
            in: text
        ), groups.count >= 2 {
            let idol = replacing(#"\s*[、，]\s*"#, in: cleanPhrase(groups[0]), with: ",")
            if let quotedIdol = try? quoteValue(idol) {
                return resultFromCommand(
                    "addscancheki all idol=\(quotedIdol) date=\(groups[1])",
                    intent: "addscancheki",
                    confidence: 0.97,
                    message: "识别为保存全部扫描结果；执行仍需确认"
                )
            }
        }

        let patterns = [
            #"^(?:把|将)?(?:扫描得到的|扫描的)?(?:临时)?(?:cheki|切己)\s*(.+?)\s*(?:添加|加入|保存)(?:给|到)\s*(?:idol|偶像|爱豆)?\s*(.+)$"#,
            #"^(?:添加|加入|保存)(?:临时cheki|扫描结果)\s*(.+?)\s*(?:给|到)\s*(?:idol|偶像|爱豆)?\s*(.+)$"#,
            #"^(?:把)?扫描留下的\s*(.+?)\s*(?:归到|归给|加入到)\s*(.+?)(?:名下)?$"#,
            #"^(?:把|将)?扫描临时(?:cheki|切己)\s*(.+?)\s*(?:[，,]?\s*(?:并|同时|然后|再|以及)?)?(?:添加|加入|保存)(?:给|到)\s*(?:idol|偶像|爱豆)?\s*(.+)$"#,
            #"^(?:把|将)?扫描临时(?:cheki|切己)\s*(.+?)\s*(?:[，,]?\s*(?:并|同时|然后|再|以及)?)?(?:绑定给|绑定到|归到|归给|挂到)\s*(?:idol|偶像|爱豆)?\s*(.+?)(?:名下)?$"#,
            #"^(?:把|将)?扫描临时(?:cheki|切己)\s*(.+?)\s*(?:[，,]?\s*(?:并|同时|然后|再|以及)?)?放到\s*(.+?)\s*名下$"#,
        ]
        for pattern in patterns {
            guard let groups = captures(pattern, in: text), groups.count >= 2 else { continue }
            var temporary = cleanPhrase(groups[0])
            var idol = cleanPhrase(groups[1])
            temporary = replacing(#"[，、]"#, in: temporary, with: ",")
            idol = replacing(#"[，、]"#, in: idol, with: ",")
            if ["全部", "所有", "全都"].contains(temporary) { temporary = "all" }
            if let qTemporary = try? quoteValue(temporary), let qIdol = try? quoteValue(idol) {
                return resultFromCommand("addscancheki \(qTemporary) idol=\(qIdol)", intent: "addscancheki", confidence: 0.96, message: "识别为把扫描临时对象添加给 Idol；执行仍需确认")
            }
        }
        return nil
    }

    static func extractInlineAssignments(_ text: String) -> (String, [(String, String)]) {
        let allowed: Set<String> = ["event", "date", "user", "userappears", "size", "note", "idol", "idols"]
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"]*\"|'[^']*'|[^\s，,]+)"#) else { return (text, []) }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var values: [(String, String)] = []
        var replacements: [(NSRange, String)] = []
        for match in regex.matches(in: text, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: text), let valueRange = Range(match.range(at: 2), in: text) else { continue }
            let key = String(text[keyRange]).lowercased()
            guard allowed.contains(key) else { continue }
            let value = String(text[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values.append((key, value))
            replacements.append((match.range, " "))
        }
        let mutable = NSMutableString(string: text)
        for replacement in replacements.reversed() { mutable.replaceCharacters(in: replacement.0, with: replacement.1) }
        let rest = replacing(#"\s+"#, in: mutable as String, with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ，,"))
        return (rest, values)
    }

    static func ruleAddAlbumCheki(_ text: String) -> RuleMatch? {
        let (rest, values) = extractInlineAssignments(text)
        let compact = replacing(#"\s+"#, in: rest, with: "")
        if fullMatch(#"(?:(?:从|用|打开)(?:手机)?相册(?:里|中)?)?(?:添加|新增|创建)(?:多张|一些)?(?:cheki|切己)"#, compact) != nil {
            return .init(
                command: nil,
                intent: "addcheki",
                confidence: 0,
                message: !values.contains(where: { $0.0 == "idol" || $0.0 == "idols" })
                    ? "还需要一个或多个 Idol，并选择 Event 或日期。"
                    : "还需要选择 Event 或日期。"
            )
        }
        let patterns = [
            #"^(?:从相册|用相册|打开相册)(?:中)?(?:给|为)\s*(?:(?:idol|偶像|爱豆)\s+)?(.+?)\s*(?:添加|新增|创建)(?:多张|一些)?\s*(?:cheki|切己)$"#,
            #"^(?:给|为)\s*(?:(?:idol|偶像|爱豆)\s+)?(.+?)\s*(?:从相册)?(?:添加|新增|创建)(?:多张|一些)?\s*(?:cheki|切己)$"#,
            #"^(?:添加|新增|创建)(?:相册)?\s*(?:cheki|切己)(?:给|到)\s*(?:(?:idol|偶像|爱豆)\s+)?(.+)$"#,
            #"^(?:从)?(?:手机)?相册(?:里|中)?(?:选择|挑)(?:几张|多张|一些)?(?:照片|图片)?(?:给|为)\s*(.+?)(?:做|制作|创建)(?:cheki|切己)$"#,
        ]
        for pattern in patterns {
            guard let raw = firstCapture(pattern, in: rest) else { continue }
            let idol = replacing(#"\s*[、，]\s*"#, in: cleanPhrase(raw), with: ",")
            guard let qIdol = try? quoteValue(idol) else { continue }
            var parts = ["addcheki", qIdol]
            for (key, value) in values where key != "idol" && key != "idols" {
                guard let quoted = try? quoteValue(value) else { return nil }
                parts.append("\(key)=\(quoted)")
            }
            return resultFromCommand(parts.joined(separator: " "), intent: "addcheki", confidence: 0.96, message: "识别为从相册为 Idol 添加 Cheki；执行仍需确认")
        }
        return nil
    }

    static func ruleEventCRUD(_ text: String) -> RuleMatch? {
        let compact = replacing(#"\s+"#, in: text, with: "")
        if fullMatch(#"(?:列出|显示|查看|打开)(?:全部|所有|我的|已添加的)?(?:event|活动|场次)(?:列表|清单)?"#, compact) != nil {
            return resultFromCommand("listevent", intent: "listevent", confidence: 0.98, message: "识别为列出 Event")
        }

        if fullMatch(#"(?:添加|新增|创建|录入)(?:一个)?(?:event|活动|场次)"#, compact) != nil {
            return .init(command: nil, intent: "addevent", confidence: 0, message: "还需要 Event 名称和日期；URL 可以稍后附加。")
        }

        if let eventDraft = ChekinanaLocalEventLanguage.draft(from: text) {
            let slots = eventDraft.operation.slots
            if eventDraft.missing.isEmpty,
               let url = slots.url,
               let name = slots.name,
               let date = slots.date,
               let quotedName = try? quoteValue(name) {
                return resultFromCommand(
                    "addevent \(url) name=\(quotedName) date=\(date)",
                    intent: "addevent",
                    confidence: 0.99,
                    message: "识别为添加带 URL 的 Event；执行仍需确认"
                )
            }
            let missingText = eventDraft.missing.map {
                switch $0 {
                case .eventName: return "名称"
                case .date: return "日期"
                default: return $0.rawValue
                }
            }.joined(separator: "和")
            return .init(
                command: nil,
                intent: "addevent",
                confidence: 0,
                message: "还需要 Event \(missingText)，已保留 URL。"
            )
        }

        if let value = firstCapture(#"^(?:添加|新增|创建|录入)(?:一个)?\s*(?:event|活动|场次)\s+(.+)$"#, in: text) {
            let target = cleanPhrase(value)
            if target.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return .init(command: nil, intent: "addevent", confidence: 0, message: "还需要 Event 名称和日期，已保留 URL。")
            }
            if let groups = captures(#"^(.+?)(?:\s+|，|,)\s*(\d{4}-\d{2}-\d{2})$"#, in: target), groups.count >= 2,
               let name = try? quoteValue(cleanPhrase(groups[0])) {
                return resultFromCommand("addevent \(name) date=\(groups[1])", intent: "addevent", confidence: 0.97, message: "识别为通过名称和日期添加 Event；执行仍需确认")
            }
            return .init(command: nil, intent: "addevent", confidence: 0, message: "通过名称添加 Event 时还需要 YYYY-MM-DD 日期。")
        }

        for (intent, pattern, message) in [
            ("showevent", #"^(?:查看|显示|打开|查询)\s*(?:event|活动|场次)\s+(.+)$"#, "识别为查看 Event"),
            ("deleteevent", #"^(?:删除|移除)\s*(?:event|活动|场次)\s+(.+)$"#, "识别为删除 Event；执行仍需确认"),
        ] {
            if let value = firstCapture(pattern, in: text), let target = try? quoteValue(cleanPhrase(value)) {
                return resultFromCommand("\(intent) \(target)", intent: intent, confidence: 0.97, message: message)
            }
        }

        if let groups = captures(#"^(?:把|将)?\s*(?:event|活动|场次)\s*(.+?)\s*的\s*(名字|名称|name|日期|date|链接|网址|url)\s*(?:修改|改|更新|设置|设)?(?:成|为|到)?\s*(.+)$"#, in: text), groups.count >= 3 {
            let aliases = ["名字": "name", "名称": "name", "name": "name", "日期": "date", "date": "date", "链接": "url", "网址": "url", "url": "url"]
            let target = cleanPhrase(groups[0])
            let value = cleanPhrase(groups[2])
            if let field = aliases[groups[1].lowercased()],
               let quotedTarget = try? quoteValue(target),
               let quotedValue = try? quoteValue(value, allowingAmpersand: field == "url") {
                return resultFromCommand("editevent \(quotedTarget) \(field)=\(quotedValue)", intent: "editevent", confidence: 0.95, message: "识别为修改 Event；执行仍需确认")
            }
        }
        if let groups = captures(#"^(?:修改|编辑|更新)\s*(?:event|活动|场次)\s+([^ ]+)\s+(.+)$"#, in: text), groups.count >= 2,
           let target = try? quoteValue(cleanPhrase(groups[0])) {
            return resultFromCommand("editevent \(target) \(groups[1])", intent: "editevent", confidence: 0.93, message: "识别为修改 Event；执行仍需确认")
        }
        return nil
    }

    static func ruleChekiShowEdit(_ text: String) -> RuleMatch? {
        if let value = firstCapture(#"^(?:查看|显示|打开|查询)\s*(?:cheki|切己|切)\s+(.+)$"#, in: text),
           let target = try? quoteValue(cleanPhrase(value)) {
            return resultFromCommand("showcheki \(target)", intent: "showcheki", confidence: 0.97, message: "识别为查看 Cheki")
        }
        if let groups = captures(#"^(?:把|将)?\s*(?:cheki|切己|切)\s*(.+?)\s*的\s*(idol|偶像|爱豆|event|活动|场次|日期|date|备注|note|用户|user|尺寸|size)\s*(?:修改|改|更新|设置|设)?(?:成|为|到)?\s*(.+)$"#, in: text), groups.count >= 3 {
            let aliases = ["idol": "idols", "偶像": "idols", "爱豆": "idols", "event": "event", "活动": "event", "场次": "event", "日期": "date", "date": "date", "备注": "note", "note": "note", "用户": "user", "user": "user", "尺寸": "size", "size": "size"]
            let target = cleanPhrase(groups[0])
            var value = cleanPhrase(groups[2])
            if aliases[groups[1].lowercased()] == "idols" {
                value = replacing(#"\s*[、，]\s*"#, in: value, with: ",")
            }
            if let field = aliases[groups[1].lowercased()],
               let quotedTarget = try? quoteValue(target),
               let quotedValue = try? quoteValue(value) {
                return resultFromCommand("editcheki \(quotedTarget) \(field)=\(quotedValue)", intent: "editcheki", confidence: 0.95, message: "识别为修改 Cheki；执行仍需确认")
            }
        }
        if let groups = captures(#"^(?:修改|编辑|更新)\s*(?:cheki|切己|切)\s+([^ ]+)\s+(.+)$"#, in: text), groups.count >= 2,
           let target = try? quoteValue(cleanPhrase(groups[0])) {
            return resultFromCommand("editcheki \(target) \(groups[1])", intent: "editcheki", confidence: 0.93, message: "识别为修改 Cheki；执行仍需确认")
        }
        return nil
    }

    static func ruleChekiListDownloadDelete(_ text: String) -> RuleMatch? {
        let rules = [
            ("downloadcheki", #"^(?:下载|保存到相册|存到相册)(?:cheki|切己)\s*(.+)$"#),
            ("deletecheki", #"^(?:删除|移除)\s*(?:cheki|切己)\s*(.+)$"#),
            ("deletecheki", #"^(?:把|将)\s*(.+?)(?:这个)?(?:cheki|切己)(?:删除|移除)(?:掉)?$"#),
        ]
        for (intent, pattern) in rules {
            if let value = firstCapture(pattern, in: text), let target = try? quoteValue(cleanPhrase(value)) {
                return resultFromCommand("\(intent) \(target)", intent: intent, confidence: 0.97, message: intent == "downloadcheki" ? "识别为下载 Cheki；执行仍需确认" : "识别为删除 Cheki；执行仍需确认")
            }
        }
        if let value = firstCapture(#"^(?:把)?(?:cheki|切己)?\s*(.+?)(?:这张)?(?:cheki|切己)?(?:保存|存)(?:进|到)(?:系统)?相册$"#, in: text), let target = try? quoteValue(cleanPhrase(value)) {
            return resultFromCommand("downloadcheki \(target)", intent: "downloadcheki", confidence: 0.96, message: "识别为下载 Cheki；执行仍需确认")
        }
        if let value = firstCapture(#"^(?:把)?(.+?)(?:这张)(?:cheki|切己)(?:不要了|删除掉|移除掉)$"#, in: text), let target = try? quoteValue(cleanPhrase(value)) {
            return resultFromCommand("deletecheki \(target)", intent: "deletecheki", confidence: 0.96, message: "识别为删除 Cheki；执行仍需确认")
        }
        let compact = replacing(#"\s+"#, in: text, with: "")
        if fullMatch(#"(?:列出|显示|查看|打开)(?:全部|所有|我的|已添加的)?(?:cheki|切己)(?:列表|清单)?"#, compact) != nil {
            return resultFromCommand("listcheki", intent: "listcheki", confidence: 0.98, message: "识别为列出 Cheki")
        }
        for pattern in [
            #"^(?:列出|显示|查看)\s*(?:(?:idol|偶像|爱豆)\s+)?(.+?)\s*的(?:全部|所有)?(?:cheki|切己)$"#,
            #"^(?:让我)?看看\s*(.+?)(?:拍过的|相关的)(?:cheki|切己)$"#,
        ] {
            if let value = firstCapture(pattern, in: text), let idol = try? quoteValue(cleanPhrase(value)) {
                return resultFromCommand("listcheki idol=\(idol)", intent: "listcheki", confidence: 0.95, message: "识别为按 Idol 筛选 Cheki")
            }
        }
        return nil
    }

    static func detectsMultipleIntents(_ text: String) -> Bool {
        let separatorPattern = #"(?:[，,；;、。.！!？?]|然后|接着|随后|同时|还是|或者|以及|并且|\b(?:and|then|or)\b|再(?=(?:帮我|给我|去|把|将)?(?:添加|新增|加入|录入|列出|查看|显示|查询|修改|编辑|更新|设置|删除|移除|确认|执行|取消|撤销|扫描|识别|丢弃|下载|保存|清空|清屏|擦掉|绑定|归到|归给|挂到|放到))|并(?=(?:帮我|给我|去|把|将)?(?:添加|新增|加入|录入|列出|查看|显示|查询|修改|编辑|更新|设置|删除|移除|确认|执行|取消|撤销|扫描|识别|丢弃|下载|保存|清空|清屏|擦掉|绑定|归到|归给|挂到|放到)))"#
        guard let regex = try? NSRegularExpression(pattern: separatorPattern, options: [.caseInsensitive]) else { return false }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var clauses: [String] = []
        var start = text.startIndex
        let punctuation = CharacterSet(charactersIn: "，,；;、。.！!？?")
        for match in matches {
            guard let separatorRange = Range(match.range, in: text) else { continue }
            let separator = String(text[separatorRange])
            let remainder = String(text[separatorRange.upperBound...])
            if separator.unicodeScalars.allSatisfy(punctuation.contains),
               fullMatch(#"\s*(?:请|帮我|给我|去|把|将)?(?:添加|新增|加入|录入|列出|查看|显示|查询|修改|编辑|更新|设置|删除|移除|确认|执行|取消|撤销|扫描|识别|丢弃|下载|保存|清空|清屏|擦掉|绑定|归到|归给|挂到|放到).*"#, remainder) == nil {
                continue
            }
            let part = String(text[start..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { clauses.append(part) }
            start = separatorRange.upperBound
        }
        let tail = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { clauses.append(tail) }

        var actions: [String] = []
        var index = 0
        while index < clauses.count {
            if index + 1 < clauses.count, isScannedTemporarySource(clauses[index]), isAttachToIdolClause(clauses[index + 1]) {
                actions.append("addscancheki")
                index += 2
                continue
            }
            actions += clauseActionIntents(clauses[index], context: text, allowGeneric: clauses.count > 1)
            index += 1
        }
        return actions.count >= 2
    }

    static func isScannedTemporarySource(_ text: String) -> Bool {
        regexContains(#"(?:扫描|临时)"#, in: text) && regexContains(#"(?:cheki|切己|对象|结果)"#, in: text)
    }

    static func isAttachToIdolClause(_ text: String) -> Bool {
        regexContains(#"(?:(?:添加|加入|保存)\s*(?:给|到)|归到|归给|归入|挂到|绑定给|绑定到|放到.+?名下)"#, in: text) &&
            regexContains(#"(?:idol|偶像|爱豆|名下)"#, in: text)
    }

    static func clauseActionIntents(_ clause: String, context: String, allowGeneric: Bool) -> [String] {
        let compact = replacing(#"\s+"#, in: clause, with: "").lowercased()
        let contextCompact = replacing(#"\s+"#, in: context, with: "").lowercased()
        guard !compact.isEmpty else { return [] }
        let hasIdol = regexContains(#"(?:idol|偶像|爱豆)"#, in: compact)
        let hasCheki = regexContains(#"(?:cheki|切己)"#, in: compact)
        let contextHasIdol = regexContains(#"(?:idol|偶像|爱豆)"#, in: contextCompact)
        let contextHasCheki = regexContains(#"(?:cheki|切己)"#, in: contextCompact)
        if isScannedTemporarySource(compact), isAttachToIdolClause(compact) { return ["addscancheki"] }
        if regexContains(#"(?:相册|album)"#, in: compact), regexContains(#"(?:添加|新增|创建|制作|做|选择|挑)"#, in: compact), hasCheki || contextHasCheki { return ["addcheki"] }

        var intents: [String] = []
        let cancel = regexContains(#"(?:取消|撤销|作废|别算)"#, in: compact)
        if !cancel, regexContains(#"(?:确认|同意|落锤|执行)"#, in: compact) { intents.append("confirm") }
        if cancel { intents.append("cancel") }
        if regexContains(#"(?:清屏|清空(?:屏幕|界面|输出|聊天|记录)|擦掉屏幕)"#, in: compact) { intents.append("clear") }
        let discard = regexContains(#"(?:丢弃|清除|删除|移除)"#, in: compact) && isScannedTemporarySource(compact)
        if discard { intents.append("discardcheki") }
        else if regexContains(#"(?:删除|移除|不要了)"#, in: compact) {
            if hasCheki || contextHasCheki { intents.append("deletecheki") }
            else if !hasIdol && !contextHasIdol && allowGeneric { intents.append("delete") }
        }
        if regexContains(#"(?:下载|保存到相册|保存进相册|存到相册|存进相册)"#, in: compact) { intents.append("downloadcheki") }
        if !discard, regexContains(#"(?:扫描|识别)"#, in: compact), hasCheki || regexContains(#"(?:照片|图片)"#, in: compact) { intents.append("scancheki") }
        if regexContains(#"(?:列出|查看|显示|查询|看看)"#, in: compact) {
            if hasCheki || contextHasCheki { intents.append("listcheki") }
            else if !hasIdol && !contextHasIdol && allowGeneric { intents.append("view") }
        }
        if !compact.contains("已添加"), regexContains(#"(?:添加|新增|加入|录入|登记|收录)"#, in: compact) {
            if hasIdol || contextHasIdol { intents.append("addidol") }
            else if allowGeneric { intents.append("add") }
        }
        if regexContains(#"(?:删除|移除)"#, in: compact), hasIdol || contextHasIdol { intents.append("deleteidol") }
        if regexContains(#"(?:修改|编辑|更新|设置|改成|换成|改为|换为)"#, in: compact), hasIdol || contextHasIdol || regexContains(#"(?:颜色|应援色|代表色|生日|团体|简介|认证|头像)"#, in: compact) { intents.append("editidol") }
        if !(hasCheki || contextHasCheki), regexContains(#"(?:列出|显示|查看|打开)"#, in: compact), hasIdol || contextHasIdol {
            if regexContains(#"(?:全部|所有|列表|清单|名册|花名册|列出)"#, in: compact) { intents.append("listidol") }
            else { intents.append("showidol") }
        }
        return Array(NSOrderedSet(array: intents)) as? [String] ?? intents
    }

    static func scoredCandidates(_ text: String) -> [(intent: String, score: Int)] {
        let terms: [(String, [(String, Int)])] = [
            ("help", [("帮助", 4), ("怎么用", 4), ("命令", 1)]),
            ("confirm", [("确认", 4), ("同意", 2), ("落锤", 4)]),
            ("cancel", [("取消", 4), ("撤销", 4), ("作废", 3), ("别算", 3)]),
            ("clear", [("清屏", 5), ("清空", 3), ("擦掉", 3), ("屏幕", 2)]),
            ("addidol", [("添加", 2), ("新增", 2), ("登记", 3), ("idol", 2), ("偶像", 2), ("爱豆", 2), ("名册", 1)]),
            ("listidol", [("列表", 2), ("清单", 3), ("列出", 2), ("花名册", 3), ("idol", 2), ("偶像", 2), ("爱豆", 2)]),
            ("showidol", [("详情", 3), ("资料", 2), ("查看", 1), ("idol", 2), ("偶像", 2)]),
            ("editidol", [("修改", 3), ("编辑", 3), ("改成", 2), ("换成", 3), ("应援色", 3), ("idol", 2), ("偶像", 2)]),
            ("deleteidol", [("删除", 3), ("移除", 3), ("idol", 2), ("偶像", 2), ("爱豆", 2)]),
            ("scancheki", [("扫描", 4), ("临时", 2), ("cheki", 2)]),
            ("discardcheki", [("丢弃", 4), ("清除", 2), ("临时", 2), ("cheki", 2)]),
            ("addcheki", [("相册", 4), ("添加", 2), ("cheki", 2), ("切己", 2)]),
            ("addscancheki", [("扫描结果", 4), ("扫描留下", 4), ("临时", 3), ("归到", 4), ("添加", 2), ("cheki", 2)]),
            ("listcheki", [("列出", 2), ("列表", 2), ("查看", 1), ("看看", 2), ("拍过", 3), ("cheki", 3), ("切己", 3)]),
            ("downloadcheki", [("下载", 4), ("保存到相册", 4), ("保存进相册", 4), ("存进系统相册", 5), ("cheki", 2), ("切己", 2)]),
            ("deletecheki", [("删除", 3), ("移除", 3), ("不要了", 4), ("cheki", 3), ("切己", 3)]),
        ]
        let lowered = text.lowercased()
        return terms.compactMap { intent, terms -> (String, Int)? in
            let score = terms.reduce(0) { $0 + (lowered.contains($1.0.lowercased()) ? $1.1 : 0) }
            return score >= 2 ? (intent, score) : nil
        }
        .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        .prefix(3)
        .map { $0 }
    }

    static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func regexContains(_ pattern: String, in text: String) -> Bool {
        guard let regex = regex(pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = regex(pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: replacement)
    }

    static func fullMatch(_ pattern: String, _ text: String) -> NSTextCheckingResult? {
        guard let regex = regex("^(?:\(pattern))$") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)
    }

    static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = regex(pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard match.range(at: index).location != NSNotFound, let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.first
    }
}

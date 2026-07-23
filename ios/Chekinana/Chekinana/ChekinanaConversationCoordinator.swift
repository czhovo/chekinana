import Foundation
import Network
import SwiftData

enum ChekinanaTypedCommandPreparation: Equatable, Sendable {
    case ready([String])
    case rejected(ChekinanaTypedCommandPreparationFailure)
}

enum ChekinanaTypedCommandPreparationFailure: Equatable, Sendable {
    case scannerNotConfigured
    case invalidScannerConfiguration
    case invalidScannerPlan

    var userMessage: String {
        switch self {
        case .scannerNotConfigured:
            "扫描服务尚未配置；未读取照片，也未发起扫描请求。"
        case .invalidScannerConfiguration:
            "扫描服务地址配置无效；未读取照片，也未发起扫描请求。"
        case .invalidScannerPlan:
            "扫描请求未通过本地安全校验；未读取照片，也未发起扫描请求。"
        }
    }
}

enum ChekinanaScannerBaseURLResolution: Equatable, Sendable {
    case resolved(URL)
    case invalid
}

enum ChekinanaScannerConfiguration {
    static let infoDictionaryKey = "ChekinanaScannerPodID"
    static let baseURLInfoDictionaryKey = "ChekinanaScannerBaseURL"
    static let productionBaseURL = URL(string: "https://api.chekinana.top")!

    static var currentBuildAllowsInsecureLocalHTTP: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func configuredPodID(bundle: Bundle = .main) -> String? {
        configuredPodID(infoDictionary: bundle.infoDictionary)
    }

    static func configuredPodID(infoDictionary: [String: Any]?) -> String? {
        guard let rawValue = infoDictionary?[infoDictionaryKey] as? String else {
            return nil
        }
        return normalizedPodID(rawValue)
    }

    static func configuredBaseURL(
        bundle: Bundle = .main
    ) -> ChekinanaScannerBaseURLResolution {
        configuredBaseURL(
            infoDictionary: bundle.infoDictionary,
            allowsInsecureLocalHTTP: currentBuildAllowsInsecureLocalHTTP
        )
    }

    static func configuredBaseURL(
        infoDictionary: [String: Any]?,
        allowsInsecureLocalHTTP: Bool
    ) -> ChekinanaScannerBaseURLResolution {
        let rawValue = infoDictionary?[baseURLInfoDictionaryKey] as? String
        return resolveBaseURL(
            rawValue,
            allowsInsecureLocalHTTP: allowsInsecureLocalHTTP
        )
    }

    static func resolveBaseURL(
        _ rawValue: String?,
        allowsInsecureLocalHTTP: Bool
    ) -> ChekinanaScannerBaseURLResolution {
        guard let rawValue else {
            return .resolved(productionBaseURL)
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isUnresolvedBuildSetting(value) else {
            return .resolved(productionBaseURL)
        }
        guard var components = URLComponents(string: value),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              scheme == "https"
                || (
                    scheme == "http"
                    && allowsInsecureLocalHTTP
                    && isPrivateLANHost(host)
                ) else {
            return .invalid
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.percentEncodedPath = ""
        guard let url = components.url else {
            return .invalid
        }
        return .resolved(url)
    }

    static func prepareTypedCommands(
        _ commands: [String],
        configuredPodID: String?,
        baseURLResolution: ChekinanaScannerBaseURLResolution = .resolved(productionBaseURL),
        dateAnnotationEnabled: Bool = false
    ) -> ChekinanaTypedCommandPreparation {
        var prepared: [String] = []
        prepared.reserveCapacity(commands.count)

        for command in commands {
            let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let commandName = normalized
                .split(whereSeparator: { $0.isWhitespace })
                .first?
                .lowercased()

            guard commandName == "scancheki" else {
                prepared.append(command)
                continue
            }
            guard normalized == "scancheki" else {
                return .rejected(.invalidScannerPlan)
            }
            guard case .resolved = baseURLResolution else {
                return .rejected(.invalidScannerConfiguration)
            }
            guard let podID = configuredPodID.flatMap(normalizedPodID) else {
                return .rejected(.scannerNotConfigured)
            }
            // `normalizedPodID` restricts this value to an unquoted parser-safe
            // token. This command is internal and is never echoed to the user.
            let annotationArgument = dateAnnotationEnabled
                ? " date_annotation=true"
                : ""
            prepared.append("scancheki pod=\(podID)\(annotationArgument)")
        }

        return .ready(prepared)
    }

    private static func isUnresolvedBuildSetting(_ value: String) -> Bool {
        value.hasPrefix("$(") && value.hasSuffix(")")
    }

    private static func isPrivateLANHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }

        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if let octets = strictIPv4Octets(host) {
            return octets[0] == 10
                || octets[0] == 127
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }
        if host.contains(":") {
            return isPrivateIPv6Literal(host)
        }

        guard !resemblesLegacyIPv4Address(host),
              isValidLocalHostname(host) else {
            return false
        }
        return (!host.contains(".") && host.contains(where: \.isLetter))
            || host.hasSuffix(".local")
    }

    private static func strictIPv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0",
                  let value = Int(part),
                  (0...255).contains(value) else {
                return nil
            }
            return value
        }
        return octets.count == 4 ? octets : nil
    }

    private static func isPrivateIPv6Literal(_ host: String) -> Bool {
        guard let address = IPv6Address(host) else {
            return false
        }
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 16 else {
            return false
        }

        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 }
            && bytes.last == 1
        let isUniqueLocal = bytes[0] & 0xfe == 0xfc
        let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        return isLoopback || isUniqueLocal || isLinkLocal
    }

    private static func resemblesLegacyIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        return parts.allSatisfy { part in
            let lowered = part.lowercased()
            if lowered.hasPrefix("0x") {
                let digits = lowered.dropFirst(2)
                return !digits.isEmpty && digits.allSatisfy(\.isHexDigit)
            }
            return lowered.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    private static func isValidLocalHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else {
            return false
        }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first?.isASCII == true,
                  label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isASCII == true,
                  label.last?.isLetter == true || label.last?.isNumber == true else {
                return false
            }
            return label.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
            }
        }
    }

    private static func normalizedPodID(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...128).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar.value == 45
                      || scalar.value == 95
              }) else {
            return nil
        }
        return value
    }
}

struct ChekinanaLocalChoice: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String?
}

struct ChekinanaConversationSelections: Equatable, Sendable {
    var selectedIdolIDs: [UUID] = []
    var selectedEventID: UUID?
    var selectedDate: String?
    var selectedTemporaryIDs: [UUID] = []
    var selectedChekiID: UUID?
    var usesAllTemporaryChekis = false
    var idolOverrides: [String: UUID] = [:]
    var eventOverrides: [String: UUID] = [:]
}

enum ChekinanaLocalChoiceKind: Equatable, Sendable {
    case idol(query: String)
    case event(query: String)
}

struct ChekinanaLocalChoiceRequest: Equatable, Sendable {
    let kind: ChekinanaLocalChoiceKind
    let options: [ChekinanaLocalChoice]
}

struct ChekinanaConversationDraftState: Equatable, Sendable {
    var operation: ChekinanaNLOperation
    var missing: [ChekinanaNLMissing]
    var selections = ChekinanaConversationSelections()
    var localChoice: ChekinanaLocalChoiceRequest?

    mutating func removeMissing(_ value: ChekinanaNLMissing) {
        missing.removeAll { $0 == value }
    }

    var requiresFreeTextIdolName: Bool {
        operation.intent == .addidol && missing.first == .idol
    }

    var hasLocalSelections: Bool {
        !selections.selectedIdolIDs.isEmpty ||
        selections.selectedEventID != nil ||
        selections.selectedDate != nil ||
        !selections.selectedTemporaryIDs.isEmpty ||
        selections.selectedChekiID != nil ||
        selections.usesAllTemporaryChekis ||
        !selections.idolOverrides.isEmpty ||
        !selections.eventOverrides.isEmpty ||
        localChoice != nil
    }
}

struct ChekinanaConversationState: Equatable, Sendable {
    var draft: ChekinanaConversationDraftState?

    mutating func clearDraft() {
        draft = nil
    }
}

enum ChekinanaConversationArbitration {
    /// A complete local product command starts a new operation and supersedes
    /// any unfinished remote draft. Local control commands (for example,
    /// confirm/cancel) remain independent from the draft.
    @discardableResult
    static func applyLocalCommand(
        _ translation: ChekinanaNaturalLanguageTranslation,
        to state: inout ChekinanaConversationState
    ) -> Bool {
        guard state.draft != nil,
              translation.command != nil,
              !translation.needsClarification,
              let intent = translation.intent,
              !["help", "confirm", "cancel", "clear"].contains(intent) else {
            return false
        }
        state.clearDraft()
        return true
    }
}

enum ChekinanaConversationMessage: Equatable, Sendable {
    case rejected
    case invalidPlan
    case idolNotFound
    case eventNotFound
    case localObjectChanged
    case networkUnavailable
    case cannotResolveHost
    case offline
    case requestTimedOut
    case connectionLost
    case serviceNotDeployed
    case serviceUnavailable
    case rateLimited
    case rateLimitUnavailable
    case upstreamTimedOut
    case upstreamUnavailable
    case invalidModelOutput
    case invalidServiceResponse
    case requestInvalid
    case privacyProtected

    var text: String {
        switch self {
        case .rejected:
            "这项请求暂不支持，请换一种自然语言描述。"
        case .invalidPlan:
            "没有得到可安全执行的操作，请补充对象或换一种描述。"
        case .idolNotFound:
            "本地没有匹配的 Idol。请先添加该 Idol，或改写名称。"
        case .eventNotFound:
            "本地没有匹配的 Event。请先添加该 Event，或改用日期。"
        case .localObjectChanged:
            "刚才选择的本地对象已变化，请重新选择。"
        case .networkUnavailable:
            "自然语言服务暂时不可用。已保留原输入；可以重试或取消。"
        case .cannotResolveHost:
            "无法解析自然语言服务域名（可能是 DNS 或代理/PAC 故障）。已保留原输入；请检查当前网络后重试。"
        case .offline:
            "当前无法连接网络。已保留原输入；联网后可重试。"
        case .requestTimedOut:
            "自然语言服务响应超时。已保留原输入；可以重试或取消。"
        case .connectionLost:
            "请求过程中网络连接中断。已保留原输入；网络稳定后可以重试。"
        case .serviceNotDeployed:
            "当前公开地址尚未提供自然语言解释服务。已保留原输入；请稍后重试。"
        case .serviceUnavailable:
            "自然语言服务暂时不可用。已保留原输入，请稍后重试。"
        case .rateLimited:
            "自然语言服务请求过于频繁。已保留原输入，请稍后重试。"
        case .rateLimitUnavailable:
            "自然语言服务暂时无法检查调用额度。已保留原输入，请稍后重试。"
        case .upstreamTimedOut:
            "自然语言模型响应超时。已保留原输入，请稍后重试。"
        case .upstreamUnavailable:
            "自然语言模型上游暂时不可用。已保留原输入，请稍后重试。"
        case .invalidModelOutput:
            "自然语言模型返回了无法安全执行的结果。已保留原输入；请改写需求。"
        case .invalidServiceResponse:
            "自然语言服务返回了无法安全解析的内容，未执行任何操作。已保留原输入；请改写需求或稍后重试。"
        case .requestInvalid:
            "输入不符合自然语言服务的安全限制，未发送或执行。请缩短或改写内容。"
        case .privacyProtected:
            "检测到可能的凭据或本地标识。为保护隐私，本次内容未发送；请移除敏感内容后重试。"
        }
    }

    static func forClientError(_ error: ChekinanaNLClientError) -> ChekinanaConversationMessage {
        switch error {
        case .sensitiveInput:
            return .privacyProtected
        case .cannotFindHost:
            return .cannotResolveHost
        case .notConnectedToInternet:
            return .offline
        case .timedOut:
            return .requestTimedOut
        case .networkConnectionLost:
            return .connectionLost
        case .invalidHTTPStatus(let status) where status == 401 || status == 404:
            return .serviceNotDeployed
        case .invalidHTTPStatus(405):
            return .serviceNotDeployed
        case .invalidHTTPStatus(400):
            return .requestInvalid
        case .invalidHTTPStatus(429):
            return .rateLimited
        case .serviceRejected(let code, _):
            switch code {
            case "method_not_allowed": return .serviceNotDeployed
            case "invalid_request": return .requestInvalid
            case "rate_limited": return .rateLimited
            case "rate_limit_unavailable": return .rateLimitUnavailable
            case "upstream_timeout": return .upstreamTimedOut
            case "upstream_unavailable": return .upstreamUnavailable
            case "invalid_model_output": return .invalidModelOutput
            case "service_unavailable": return .serviceUnavailable
            default: return .rejected
            }
        case .invalidSchema, .responseTooLarge:
            return .invalidServiceResponse
        case .invalidRequest:
            return .requestInvalid
        case .cancelled:
            return .networkUnavailable
        case .invalidHTTPStatus:
            return .networkUnavailable
        }
    }
}

enum ChekinanaConversationCompileResult: Equatable, Sendable {
    case commands([String])
    case eventCandidateURL(String)
    case clarification(ChekinanaConversationDraftState)
    case message(ChekinanaConversationMessage)
}

@MainActor
enum ChekinanaConversationCoordinator {
    static func compile(
        _ interpretation: ChekinanaNLInterpretation,
        continuingIntent: ChekinanaNLIntent? = nil,
        selections: ChekinanaConversationSelections = .init(),
        modelContext: ModelContext
    ) -> ChekinanaConversationCompileResult {
        guard continuationIntentMatches(interpretation, expected: continuingIntent) else {
            return .message(.invalidPlan)
        }
        if case .reject(let code) = interpretation,
           code != "unsupported_request" {
            return .message(.invalidPlan)
        }
        switch interpretation {
        case .plan(let operations):
            return compile(
                operations,
                continuingIntent: continuingIntent,
                selections: selections,
                modelContext: modelContext
            )
        case .clarify(let operation, let missing):
            do {
                try ChekinanaNLSchemaValidator.validateDraft(operation, missing: missing)
                try validateSelections(selections, for: operation, modelContext: modelContext)
                if let url = try eventCandidateURL(in: [operation]) {
                    return .eventCandidateURL(url)
                }
                return .clarification(.init(
                    operation: operation,
                    missing: missing,
                    selections: selections
                ))
            } catch {
                return .message(.invalidPlan)
            }
        case .reject:
            return .message(.rejected)
        }
    }

    static func compile(
        _ operations: [ChekinanaNLOperation],
        continuingIntent: ChekinanaNLIntent? = nil,
        selections: ChekinanaConversationSelections = .init(),
        modelContext: ModelContext
    ) -> ChekinanaConversationCompileResult {
        do {
            try ChekinanaNLSchemaValidator.validatePlan(operations)
            if let continuingIntent {
                guard operations.count == 1,
                      operations[0].intent == continuingIntent else {
                    throw ChekinanaNLClientError.invalidSchema
                }
            }
            if let url = try eventCandidateURL(in: operations) {
                return .eventCandidateURL(url)
            }
            if operations.count > 1, selections.hasLocalValues {
                throw ChekinanaNLClientError.invalidSchema
            }
            if let operation = operations.first {
                try validateSelections(selections, for: operation, modelContext: modelContext)
            }
            var commands: [String] = []
            for operation in operations {
                do {
                    commands.append(try compileOperation(
                        operation,
                        selections: selections,
                        modelContext: modelContext
                    ))
                } catch let error as ResolutionError {
                    var state = ChekinanaConversationDraftState(operation: operation, missing: [])
                    state.selections = selections
                    switch error {
                    case .ambiguousIdol(let query, let choices):
                        state.localChoice = .init(kind: .idol(query: query), options: choices)
                        return .clarification(state)
                    case .ambiguousEvent(let query, let choices):
                        state.localChoice = .init(kind: .event(query: query), options: choices)
                        return .clarification(state)
                    default:
                        return result(for: error)
                    }
                }
            }
            return .commands(commands)
        } catch {
            return .message(.invalidPlan)
        }
    }

    static func resume(
        _ state: ChekinanaConversationDraftState,
        modelContext: ModelContext
    ) -> ChekinanaConversationCompileResult {
        guard state.missing.isEmpty else {
            return .clarification(state)
        }
        do {
            let command = try compileOperation(
                state.operation,
                selections: state.selections,
                modelContext: modelContext
            )
            return .commands([command])
        } catch let error as ResolutionError {
            var updated = state
            switch error {
            case .ambiguousIdol(let query, let choices):
                updated.localChoice = .init(kind: .idol(query: query), options: choices)
                return .clarification(updated)
            case .ambiguousEvent(let query, let choices):
                updated.localChoice = .init(kind: .event(query: query), options: choices)
                return .clarification(updated)
            default:
                return result(for: error)
            }
        } catch {
            return .message(.invalidPlan)
        }
    }

    static func idolChoices(modelContext: ModelContext) -> [ChekinanaLocalChoice] {
        ((try? modelContext.fetch(FetchDescriptor<Idol>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))) ?? []).map(choice(for:))
    }

    static func eventChoices(modelContext: ModelContext) -> [ChekinanaLocalChoice] {
        ((try? modelContext.fetch(FetchDescriptor<Event>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))) ?? []).map(choice(for:))
    }

    static func explicitConfirmationCommands(for response: ChekinanaCommandResponse) -> [(confirm: String, cancel: String)] {
        confirmationCodes(in: response).map { code in
            (confirm: "confirm \(code)", cancel: "cancel \(code)")
        }
    }

    static func confirmationCodes(in response: ChekinanaCommandResponse) -> [String] {
        let rawCodes: [String]
        switch response {
        case .idolCard(let card):
            rawCodes = [card.confirmationCode].compactMap { $0 }
        case .idolCards(let cards):
            rawCodes = cards.compactMap(\.confirmationCode)
        case .eventCard(let card):
            rawCodes = [card.confirmationCode].compactMap { $0 }
        case .eventCards(let cards):
            rawCodes = cards.compactMap(\.confirmationCode)
        case .pendingChekiCards(_, let cards, _), .chekiCards(let cards):
            rawCodes = cards.compactMap(\.confirmationCode)
        case .confirmationText(_, let confirmationCode):
            rawCodes = [confirmationCode]
        case .text:
            rawCodes = []
        case .chekiAdded, .chekiScanned, .chekiScannedCards,
             .idolSections, .requestAddChekiPhoto, .clearTranscript:
            rawCodes = []
        }
        var seen = Set<String>()
        return rawCodes.compactMap { raw -> String? in
            let code = ChekinanaConfirmationLedger.normalizedCode(raw)
            guard ChekinanaConfirmationLedger.isCode(code), seen.insert(code).inserted else { return nil }
            return code
        }
    }

    static func responseStopsPlan(_ response: ChekinanaCommandResponse) -> Bool {
        if case .requestAddChekiPhoto = response { return true }
        if case .text(let text) = response, text.hasPrefix("error:") { return true }
        return false
    }
}

private extension ChekinanaConversationCoordinator {
    enum ResolutionError: Error {
        case idolNotFound
        case eventNotFound
        case staleLocalSelection
        case ambiguousIdol(String, [ChekinanaLocalChoice])
        case ambiguousEvent(String, [ChekinanaLocalChoice])
    }

    static func result(for error: ResolutionError) -> ChekinanaConversationCompileResult {
        switch error {
        case .idolNotFound:
            return .message(.idolNotFound)
        case .eventNotFound:
            return .message(.eventNotFound)
        case .staleLocalSelection:
            return .message(.localObjectChanged)
        case .ambiguousIdol, .ambiguousEvent:
            return .message(.invalidPlan)
        }
    }

    static func compileOperation(
        _ operation: ChekinanaNLOperation,
        selections: ChekinanaConversationSelections,
        modelContext: ModelContext
    ) throws -> String {
        try ChekinanaNLSchemaValidator.validateOperation(operation, allowingPartial: true)
        let slots = operation.slots
        var command: String

        switch operation.intent {
        case .addidol:
            command = "addidol \(try quote(required(slots.name)))"
        case .addevent:
            let eventDate = selections.selectedDate ?? slots.date
            let name = try required(slots.name)
            let date = try required(eventDate)
            if let url = slots.url {
                command = "addevent \(try quoteURL(url)) name=\(try quote(name)) date=\(try quote(date))"
            } else {
                command = "addevent \(try quote(name)) date=\(try quote(date))"
            }
        case .listidol:
            command = "listidol"
        case .listevent:
            command = "listevent"
        case .scancheki:
            command = "scancheki"
        case .addcheki, .addscancheki:
            let idolIDs = try resolvedIdolIDs(
                slots.idols,
                selections: selections,
                modelContext: modelContext
            )
            let idolValue = idolIDs.map(shortID).joined(separator: ",")
            if operation.intent == .addscancheki {
                command = "addscancheki \(try quote(temporarySelection(slots.temporary, selections: selections)))"
            } else {
                command = "addcheki"
            }
            command += " idols=\(idolValue)"
            if let eventID = try resolvedEventID(slots.event, selections: selections, modelContext: modelContext) {
                guard slots.date == nil, selections.selectedDate == nil else {
                    throw ChekinanaNLClientError.invalidSchema
                }
                command += " event=\(shortID(eventID))"
            } else if let date = selections.selectedDate ?? slots.date {
                guard ChekinanaNLSchemaValidator.isCalendarDate(date) else {
                    throw ChekinanaNLClientError.invalidSchema
                }
                command += " date=\(date)"
            } else {
                throw ChekinanaNLClientError.invalidSchema
            }
            if let user = slots.user { command += " user=\(user)" }
            if let size = slots.size { command += " size=\(size)" }
            if let note = slots.note { command += " note=\(try quote(note))" }
        case .listcheki:
            command = "listcheki"
            if let idol = slots.idol {
                let id = try resolveIdol(idol, overrides: selections.idolOverrides, modelContext: modelContext)
                command += " idol=\(shortID(id))"
            }
            if let event = slots.event {
                let id = try resolveEvent(event, overrides: selections.eventOverrides, modelContext: modelContext)
                command += " event=\(shortID(id))"
            }
            if let date = slots.date { command += " date=\(date)" }
        case .showidol:
            let id: UUID
            if let selected = selections.selectedIdolIDs.first {
                id = selected
            } else {
                id = try resolveIdol(required(slots.target), overrides: selections.idolOverrides, modelContext: modelContext)
            }
            command = "showidol \(shortID(id))"
        case .showevent:
            let id = try resolveEvent(required(slots.target), overrides: selections.eventOverrides, modelContext: modelContext)
            command = "showevent \(shortID(id))"
        case .showcheki:
            let target = try required(slots.target)
            if let selectedChekiID = selections.selectedChekiID,
               ChekinanaSelectedChekiLanguage.referencesSelectedCheki(target) {
                let available = Set(((try? modelContext.fetch(FetchDescriptor<Cheki>())) ?? []).map(\.id))
                guard available.contains(selectedChekiID) else {
                    throw ResolutionError.staleLocalSelection
                }
                command = "showcheki \(shortID(selectedChekiID))"
            } else {
                command = "showcheki \(try quote(target))"
            }
        }

        // The typed-plan schema has already validated that `scancheki` has no
        // slots. Its scanner credential is injected locally after compilation,
        // so the user-command translator must not require a Pod at this layer.
        if operation.intent == .scancheki {
            return command
        }
        let translation = ChekinanaNaturalLanguageTranslator.translate(command)
        guard !translation.needsClarification,
              translation.source == .passthrough,
              let canonical = translation.command else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return canonical
    }

    static func resolvedIdolIDs(
        _ rawValues: [String]?,
        selections: ChekinanaConversationSelections,
        modelContext: ModelContext
    ) throws -> [UUID] {
        let ids: [UUID]
        if !selections.selectedIdolIDs.isEmpty {
            let available = Set(((try? modelContext.fetch(FetchDescriptor<Idol>())) ?? []).map(\.id))
            guard selections.selectedIdolIDs.allSatisfy(available.contains) else {
                throw ResolutionError.staleLocalSelection
            }
            ids = selections.selectedIdolIDs
        } else {
            guard let rawValues, !rawValues.isEmpty else {
                throw ChekinanaNLClientError.invalidSchema
            }
            ids = try rawValues.map {
                try resolveIdol($0, overrides: selections.idolOverrides, modelContext: modelContext)
            }
        }
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { throw ChekinanaNLClientError.invalidSchema }
        return unique
    }

    static func resolvedEventID(
        _ rawValue: String?,
        selections: ChekinanaConversationSelections,
        modelContext: ModelContext
    ) throws -> UUID? {
        if let selectedEventID = selections.selectedEventID {
            let available = Set(((try? modelContext.fetch(FetchDescriptor<Event>())) ?? []).map(\.id))
            guard available.contains(selectedEventID) else {
                throw ResolutionError.staleLocalSelection
            }
            return selectedEventID
        }
        guard let rawValue else { return nil }
        return try resolveEvent(rawValue, overrides: selections.eventOverrides, modelContext: modelContext)
    }

    static func resolveIdol(
        _ query: String,
        overrides: [String: UUID],
        modelContext: ModelContext
    ) throws -> UUID {
        let values = try modelContext.fetch(FetchDescriptor<Idol>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))
        if let id = overrides[query] {
            guard values.contains(where: { $0.id == id }) else {
                throw ResolutionError.staleLocalSelection
            }
            return id
        }
        let matches = matches(query, in: values, id: \.id, name: \.name)
        guard !matches.isEmpty else { throw ResolutionError.idolNotFound }
        guard matches.count == 1, let match = matches.first else {
            throw ResolutionError.ambiguousIdol(query, matches.map(choice(for:)))
        }
        return match.id
    }

    static func resolveEvent(
        _ query: String,
        overrides: [String: UUID],
        modelContext: ModelContext
    ) throws -> UUID {
        let values = try modelContext.fetch(FetchDescriptor<Event>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))
        if let id = overrides[query] {
            guard values.contains(where: { $0.id == id }) else {
                throw ResolutionError.staleLocalSelection
            }
            return id
        }
        let matches = matches(query, in: values, id: \.id, name: \.name)
        guard !matches.isEmpty else { throw ResolutionError.eventNotFound }
        guard matches.count == 1, let match = matches.first else {
            throw ResolutionError.ambiguousEvent(query, matches.map(choice(for:)))
        }
        return match.id
    }

    static func matches<Value>(
        _ rawQuery: String,
        in values: [Value],
        id: KeyPath<Value, UUID>,
        name: KeyPath<Value, String>
    ) -> [Value] {
        let query = normalize(rawQuery)
        let idMatches = values.filter {
            $0[keyPath: id].uuidString.lowercased().hasPrefix(query)
        }
        if !idMatches.isEmpty { return idMatches }
        let exact = values.filter { normalize($0[keyPath: name]) == query }
        if !exact.isEmpty { return exact }
        return values.filter { normalize($0[keyPath: name]).contains(query) }
    }

    static func choice(for idol: Idol) -> ChekinanaLocalChoice {
        .init(id: idol.id, title: idol.name, subtitle: idol.group)
    }

    static func choice(for event: Event) -> ChekinanaLocalChoice {
        let date = event.date.map { ChekinanaNLInterpretClient.localDateString($0) }
        return .init(id: event.id, title: event.name, subtitle: date)
    }

    static func temporarySelection(
        _ rawValue: String?,
        selections: ChekinanaConversationSelections
    ) throws -> String {
        if selections.usesAllTemporaryChekis { return "all" }
        if !selections.selectedTemporaryIDs.isEmpty {
            return selections.selectedTemporaryIDs.map(shortID).joined(separator: ",")
        }
        let value = try required(rawValue)
        if ["这些", "全部", "所有", "all"].contains(value.lowercased()) { return "all" }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ ChekinanaConfirmationLedger.isCode($0) }) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return parts.map { $0.lowercased() }.joined(separator: ",")
    }

    static func required(_ value: String?) throws -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    static func quote(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.range(of: #"[\r\n;|&`<>\"\\]|\$\("#, options: .regularExpression) == nil,
              value.range(of: #"[\x00-\x1f\x7f]"#, options: .regularExpression) == nil else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
    }

    static func quoteURL(_ value: String) throws -> String {
        guard value.range(of: #"[\r\n;|`<>\"\\]|\$\("#, options: .regularExpression) == nil else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    static func continuationIntentMatches(
        _ interpretation: ChekinanaNLInterpretation,
        expected: ChekinanaNLIntent?
    ) -> Bool {
        guard let expected else { return true }
        switch interpretation {
        case .plan(let operations):
            return operations.count == 1 && operations[0].intent == expected
        case .clarify(let operation, _):
            return operation.intent == expected
        case .reject:
            return true
        }
    }

    static func validateSelections(
        _ selections: ChekinanaConversationSelections,
        for operation: ChekinanaNLOperation,
        modelContext: ModelContext
    ) throws {
        let slots = operation.slots
        let isChekiAdd = operation.intent == .addcheki || operation.intent == .addscancheki

        if !selections.selectedIdolIDs.isEmpty {
            guard isChekiAdd else { throw ChekinanaNLClientError.invalidSchema }
            if let rawIdols = slots.idols {
                let resolved = try rawIdols.map {
                    try resolveIdol(
                        $0,
                        overrides: selections.idolOverrides,
                        modelContext: modelContext
                    )
                }
                guard resolved.count == selections.selectedIdolIDs.count,
                      Set(resolved) == Set(selections.selectedIdolIDs) else {
                    throw ChekinanaNLClientError.invalidSchema
                }
            }
        }

        if let selectedEventID = selections.selectedEventID {
            guard isChekiAdd, slots.date == nil else {
                throw ChekinanaNLClientError.invalidSchema
            }
            if let rawEvent = slots.event {
                let resolved = try resolveEvent(
                    rawEvent,
                    overrides: selections.eventOverrides,
                    modelContext: modelContext
                )
                guard resolved == selectedEventID else {
                    throw ChekinanaNLClientError.invalidSchema
                }
            }
        }

        if let selectedDate = selections.selectedDate {
            guard isChekiAdd, slots.event == nil else {
                throw ChekinanaNLClientError.invalidSchema
            }
            if let date = slots.date, date != selectedDate {
                throw ChekinanaNLClientError.invalidSchema
            }
        }

        if !selections.selectedTemporaryIDs.isEmpty || selections.usesAllTemporaryChekis {
            guard operation.intent == .addscancheki else {
                throw ChekinanaNLClientError.invalidSchema
            }
            if let temporary = slots.temporary {
                let expected = try temporarySelection(nil, selections: selections)
                let normalized = ["这些", "全部", "所有"].contains(temporary) ? "all" : temporary.lowercased()
                guard normalized == expected else {
                    throw ChekinanaNLClientError.invalidSchema
                }
            }
        }
    }

    static func eventCandidateURL(in operations: [ChekinanaNLOperation]) throws -> String? {
        let eventURLs = operations.compactMap { operation -> String? in
            guard operation.intent == .addevent else { return nil }
            return operation.slots.url
        }
        let weiboURLs = eventURLs.filter { value in
            guard let host = URLComponents(string: value)?.host?.lowercased() else { return false }
            return host == "weibo.com" || host == "www.weibo.com"
        }
        guard !weiboURLs.isEmpty else { return nil }
        guard operations.count == 1,
              weiboURLs.count == 1,
              let url = weiboURLs.first,
              ChekinanaEventCandidateValidator.isPublicWeiboStatusURL(url) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return url
    }

}

private extension ChekinanaConversationSelections {
    var hasLocalValues: Bool {
        !selectedIdolIDs.isEmpty
            || selectedEventID != nil
            || selectedDate != nil
            || !selectedTemporaryIDs.isEmpty
            || selectedChekiID != nil
            || usesAllTemporaryChekis
            || !idolOverrides.isEmpty
            || !eventOverrides.isEmpty
    }
}

import Foundation
import SwiftData

enum ChekinanaTypedCommandPreparation: Equatable, Sendable {
    case ready([String])
    case rejected(ChekinanaTypedCommandPreparationFailure)
}

enum ChekinanaTypedCommandPreparationFailure: Equatable, Sendable {
    case invalidScannerConfiguration
    case invalidScannerPlan

    var userMessage: String {
        switch self {
        case .invalidScannerConfiguration:
            ChekinanaL10n.text(
                "assistant.scanner.invalid_configuration",
                fallback: "The scanner service address is invalid. No photos were read and no request was sent."
            )
        case .invalidScannerPlan:
            ChekinanaL10n.text(
                "assistant.scanner.invalid_plan",
                fallback: "The scan request failed local safety validation. No photos were read and no request was sent."
            )
        }
    }
}

enum ChekinanaScannerBaseURLResolution: Equatable, Sendable {
    case resolved(URL)
    case invalid
}

enum ChekinanaScannerConfiguration {
    // Production Scanner traffic is always routed through Cloudflare. Pod
    // identity and runtime credentials remain exclusively server-side.
    static let baseURLInfoDictionaryKey = "ChekinanaScannerBaseURL"
    static let productionBaseURL = URL(string: "https://api.chekinana.top")!

    static var currentBuildAllowsInsecureLocalHTTP: Bool {
        false
    }

    static func configuredBaseURL(
        bundle: Bundle = .main
    ) -> ChekinanaScannerBaseURLResolution {
        _ = bundle
        return .resolved(productionBaseURL)
    }

    static func configuredBaseURL(
        infoDictionary: [String: Any]?,
        allowsInsecureLocalHTTP: Bool
    ) -> ChekinanaScannerBaseURLResolution {
        _ = infoDictionary
        _ = allowsInsecureLocalHTTP
        return .resolved(productionBaseURL)
    }

    static func resolveBaseURL(
        _ rawValue: String?,
        allowsInsecureLocalHTTP: Bool
    ) -> ChekinanaScannerBaseURLResolution {
        _ = rawValue
        _ = allowsInsecureLocalHTTP
        return .resolved(productionBaseURL)
    }

    static func prepareTypedCommands(
        _ commands: [String],
        baseURLResolution: ChekinanaScannerBaseURLResolution = .resolved(productionBaseURL),
        dateRecognitionEnabled: Bool = false,
        dateBounds: ChekinanaScannerDateBounds? = nil,
        idolRecognitionEnabled: Bool = false,
        idolCandidateIDs: [UUID] = [],
        includeUnassignedCandidate: Bool = true,
        sleevesEnabled: Bool = false,
        directInputEnabled: Bool = false
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
            var arguments = ["scancheki"]
            if sleevesEnabled && !directInputEnabled {
                arguments.append("sleeves=true")
            }
            if directInputEnabled {
                arguments.append("direct=true")
                arguments.append("scanner_size=mini")
            }
            if dateRecognitionEnabled {
                guard let effectiveDateBounds = dateBounds
                    ?? ChekinanaScannerDateBounds.recent(relativeTo: Date()) else {
                    return .rejected(.invalidScannerPlan)
                }
                arguments.append("date_recognition=true")
                arguments.append("date_scope=\(effectiveDateBounds.scope.rawValue)")
                arguments.append(
                    "date_from=\(ChekinanaScannerDateBounds.commandDate(effectiveDateBounds.from))"
                )
                arguments.append(
                    "date_to=\(ChekinanaScannerDateBounds.commandDate(effectiveDateBounds.to))"
                )
            }
            if idolRecognitionEnabled {
                let candidateTokens = idolCandidateIDs.map {
                    $0.uuidString.lowercased()
                } + (includeUnassignedCandidate ? ["unassigned"] : [])
                guard !candidateTokens.isEmpty else {
                    return .rejected(.invalidScannerPlan)
                }
                arguments.append("idol_recognition=true")
                arguments.append("candidates=\(candidateTokens.joined(separator: ","))")
            }
            prepared.append(arguments.joined(separator: " "))
        }

        return .ready(prepared)
    }

    static func isProductionProxy(_ resolution: ChekinanaScannerBaseURLResolution) -> Bool {
        guard case .resolved(let url) = resolution else { return false }
        return isProductionProxy(url)
    }

    static func isProductionProxy(_ url: URL) -> Bool {
        guard let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let production = URLComponents(
                url: productionBaseURL,
                resolvingAgainstBaseURL: false
              ) else { return false }
        return actual.scheme?.lowercased() == production.scheme?.lowercased()
            && actual.host?.lowercased() == production.host?.lowercased()
            && actual.port == production.port
            && (actual.percentEncodedPath.isEmpty || actual.percentEncodedPath == "/")
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
            ChekinanaL10n.text("assistant.error.rejected", fallback: "This request is not supported yet. Try describing it another way.")
        case .invalidPlan:
            ChekinanaL10n.text("assistant.error.invalid_plan", fallback: "No safe operation was produced. Add the missing details or rephrase the request.")
        case .idolNotFound:
            ChekinanaL10n.text("assistant.error.idol_not_found", fallback: "No local Idol matched. Add the Idol first or try another name.")
        case .eventNotFound:
            ChekinanaL10n.text("assistant.error.event_not_found", fallback: "No local Event matched. Add the Event first or use a date.")
        case .localObjectChanged:
            ChekinanaL10n.text("assistant.error.local_changed", fallback: "The selected local item changed. Choose it again.")
        case .networkUnavailable:
            ChekinanaL10n.text("assistant.error.network", fallback: "The natural-language service is unavailable. Your input was preserved; retry or cancel.")
        case .cannotResolveHost:
            ChekinanaL10n.text("assistant.error.host", fallback: "The service host could not be resolved. Your input was preserved; check the network and retry.")
        case .offline:
            ChekinanaL10n.text("assistant.error.offline", fallback: "The device is offline. Your input was preserved; retry after reconnecting.")
        case .requestTimedOut:
            ChekinanaL10n.text("assistant.error.timeout", fallback: "The natural-language request timed out. Your input was preserved; retry or cancel.")
        case .connectionLost:
            ChekinanaL10n.text("assistant.error.connection_lost", fallback: "The connection was lost. Your input was preserved; retry when the network is stable.")
        case .serviceNotDeployed:
            ChekinanaL10n.text("assistant.error.not_deployed", fallback: "The natural-language service is not available at this address. Your input was preserved.")
        case .serviceUnavailable:
            ChekinanaL10n.text("assistant.error.service", fallback: "The natural-language service is temporarily unavailable. Your input was preserved.")
        case .rateLimited:
            ChekinanaL10n.text("assistant.error.rate_limited", fallback: "Too many requests. Your input was preserved; try again later.")
        case .rateLimitUnavailable:
            ChekinanaL10n.text("assistant.error.rate_check", fallback: "The request allowance cannot be checked right now. Your input was preserved.")
        case .upstreamTimedOut:
            ChekinanaL10n.text("assistant.error.upstream_timeout", fallback: "The language model timed out. Your input was preserved.")
        case .upstreamUnavailable:
            ChekinanaL10n.text("assistant.error.upstream", fallback: "The language model is temporarily unavailable. Your input was preserved.")
        case .invalidModelOutput:
            ChekinanaL10n.text("assistant.error.model_output", fallback: "The model returned a result that cannot be executed safely. Rephrase the request.")
        case .invalidServiceResponse:
            ChekinanaL10n.text("assistant.error.service_response", fallback: "The service response could not be parsed safely. Nothing was executed.")
        case .requestInvalid:
            ChekinanaL10n.text("assistant.error.request", fallback: "The input did not meet safety limits and was not sent. Shorten or rephrase it.")
        case .privacyProtected:
            ChekinanaL10n.text("assistant.error.privacy", fallback: "Possible credentials or local identifiers were detected. Remove sensitive content and retry.")
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
    case eventCandidateText
    case clarification(ChekinanaConversationDraftState)
    case message(ChekinanaConversationMessage)
}

enum ChekinanaEventCandidateConversationRoute: Equatable, Sendable {
    case weiboURL(String)
    case text(String)

    static func resolve(
        _ result: ChekinanaConversationCompileResult,
        originalUtterance: String?
    ) -> Self? {
        switch result {
        case .eventCandidateURL(let url):
            return .weiboURL(url)
        case .eventCandidateText:
            guard let originalUtterance,
                  !originalUtterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return .text(originalUtterance)
        default:
            return nil
        }
    }
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
                if operation.intent == .addevent {
                    if let url = try eventCandidateURL(in: [operation]) {
                        return .eventCandidateURL(url)
                    }
                    return .eventCandidateText
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
            let addEventCount = operations.filter { $0.intent == .addevent }.count
            if addEventCount > 0 {
                guard operations.count == 1, addEventCount == 1 else {
                    throw ChekinanaNLClientError.invalidSchema
                }
                if let url = try eventCandidateURL(in: operations) {
                    return .eventCandidateURL(url)
                }
                return .eventCandidateText
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
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        return ((try? modelContext.fetch(FetchDescriptor<Idol>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))) ?? []).filter {
            ChekinanaVisibilityPolicy.includesIdol($0.id, hiddenIDs: hiddenIDs)
        }.map(choice(for:))
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
        case .idolCardsWithNotice(let cards, _):
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
        case .chekiAdded, .chekiScanned, .chekiScannedCards, .shellAction,
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
        case .navigate:
            command = "navigate \(try quote(required(slots.destination)))"
            if let date = slots.date { command += " date=\(date)" }
        case .openScan:
            command = "openscan"
            if let value = slots.recognizeDate { command += " recognize_date=\(value)" }
            if let value = slots.recognizeIdol { command += " recognize_idol=\(value)" }
            if let value = slots.includesUnassigned { command += " includes_unassigned=\(value)" }
            if let values = slots.candidateRefs {
                let ids = try values.map {
                    try resolveIdol($0, overrides: selections.idolOverrides, modelContext: modelContext)
                }
                command += " candidate_refs=\(ids.map(shortID).joined(separator: ","))"
            }
            for (key, value) in [("fixed_date", slots.fixedDate), ("date_from", slots.dateFrom), ("date_to", slots.dateTo)] where value != nil { command += " \(key)=\(value!)" }
        case .addidol:
            command = "addidol \(try quote(required(slots.name)))"
        case .editidol:
            let idolID = try resolveIdol(
                required(slots.target),
                overrides: selections.idolOverrides,
                modelContext: modelContext
            )
            command = "editidol \(shortID(idolID))"
            let fields: [(String, String?)] = [
                ("name", slots.name),
                ("group", slots.group),
                ("birthday", slots.birthday),
                ("color", slots.color),
                ("verification", slots.verification),
                ("bio", slots.bio),
                ("avatar", slots.avatar),
            ]
            for (field, value) in fields {
                if let value {
                    command += " \(field)=\(try quote(value))"
                }
            }
            if let clear = slots.clearFields {
                command += " clear_fields=\(clear.joined(separator: ","))"
            }
        case .deleteidol, .favoriteidol:
            let idolID = try resolveIdol(required(slots.target), overrides: selections.idolOverrides, modelContext: modelContext)
            command = operation.intent == .deleteidol ? "deleteidol \(shortID(idolID))" : "favoriteidol \(shortID(idolID)) favorite=\(slots.favorite!)"
        case .addevent:
            let eventDate = selections.selectedDate ?? slots.date
            let name = try required(slots.name)
            let date = try required(eventDate)
            if let url = slots.url {
                command = "addevent \(try quoteURL(url)) name=\(try quote(name)) date=\(try quote(date))"
            } else {
                command = "addevent \(try quote(name)) date=\(try quote(date))"
            }
        case .editevent, .deleteevent:
            let eventID = try resolveEvent(required(slots.target), overrides: selections.eventOverrides, modelContext: modelContext)
            if operation.intent == .deleteevent { command = "deleteevent \(shortID(eventID))" }
            else {
                command = "editevent \(shortID(eventID))"
                for (key, value) in [("name", slots.name), ("date", slots.date), ("city", slots.city), ("livehouse", slots.livehouse), ("price", slots.price), ("url", slots.url), ("ticket_url", slots.ticketURL), ("note", slots.note)] where value != nil { command += " \(key)=\(try quote(value!))" }
                if let clear = slots.clearFields { command += " clear_fields=\(clear.joined(separator: ","))" }
            }
        case .listidol:
            command = "listidol"
        case .listevent:
            command = "listevent"
        case .scancheki:
            command = "scancheki"
        case .addcheki, .addscancheki:
            if operation.intent == .addscancheki {
                command = "addscancheki \(try quote(temporarySelection(slots.temporary, selections: selections)))"
            } else {
                command = "addcheki"
            }
            if slots.idols?.isEmpty == false
                || !selections.selectedIdolIDs.isEmpty {
                let idolIDs = try resolvedIdolIDs(
                    slots.idols,
                    selections: selections,
                    modelContext: modelContext
                )
                let idolValue = idolIDs.map(shortID).joined(separator: ",")
                command += " idols=\(idolValue)"
            }
            let eventID = try resolvedEventID(
                slots.event,
                selections: selections,
                modelContext: modelContext
            )
            if let eventID {
                command += " event=\(shortID(eventID))"
            }
            var requiredDate = selections.selectedDate ?? slots.date
            if requiredDate == nil, let eventID {
                let events = try modelContext.fetch(FetchDescriptor<Event>())
                requiredDate = events.first(where: { $0.id == eventID })?
                    .date
                    .map(calendarDateString)
            }
            if let date = requiredDate {
                guard ChekinanaNLSchemaValidator.isCalendarDate(date) else {
                    throw ChekinanaNLClientError.invalidSchema
                }
                command += " date=\(date)"
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
                let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
                let available = Set(((try? modelContext.fetch(FetchDescriptor<Cheki>())) ?? [])
                    .filter { ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIDs) }
                    .map(\.id))
                guard available.contains(selectedChekiID) else {
                    throw ResolutionError.staleLocalSelection
                }
                command = "showcheki \(shortID(selectedChekiID))"
            } else {
                command = "showcheki \(try quote(target))"
            }
        case .editcheki, .deletecheki:
            let rawTarget = try required(slots.target)
            let resolvedTarget: String
            if let selectedChekiID = selections.selectedChekiID,
               ChekinanaSelectedChekiLanguage.referencesSelectedCheki(rawTarget) {
                let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
                let available = Set(((try? modelContext.fetch(FetchDescriptor<Cheki>())) ?? [])
                    .filter { ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIDs) }
                    .map(\.id))
                guard available.contains(selectedChekiID) else {
                    throw ResolutionError.staleLocalSelection
                }
                resolvedTarget = shortID(selectedChekiID)
            } else {
                resolvedTarget = rawTarget
            }
            command = operation.intent == .deletecheki
                ? "deletecheki \(try quote(resolvedTarget))"
                : "editrecord cheki target=\(try quote(resolvedTarget))\(try recordPatchArguments(slots, selections: selections, modelContext: modelContext))"
        case .listrecord:
            command = "listrecord"
            if let type = slots.recordType { command += " \(type)" }
            command += try recordFilterArguments(slots, selections: selections, modelContext: modelContext)
        case .showrecord:
            let target = try resolvedRecordTarget(slots, selections: selections, modelContext: modelContext)
            command = "showrecord \(try quote(required(slots.recordType))) target=\(try quote(target))"
        case .addrecord:
            command = "addrecord \(try quote(required(slots.recordType)))\(try recordPatchArguments(slots, selections: selections, modelContext: modelContext))"
        case .editrecord:
            let target = try resolvedRecordTarget(slots, selections: selections, modelContext: modelContext)
            command = "editrecord \(try quote(required(slots.recordType))) target=\(try quote(target))\(try recordPatchArguments(slots, selections: selections, modelContext: modelContext))"
        case .deleterecord:
            let target = try resolvedRecordTarget(slots, selections: selections, modelContext: modelContext)
            command = "deleterecord \(try quote(required(slots.recordType))) target=\(try quote(target))"
        }

        // The typed-plan schema has already validated that `scancheki` has no
        // slots. Its scanner credential is injected locally after compilation,
        // so the user-command translator must not require a Pod at this layer.
        if operation.intent == .scancheki {
            return command
        }
        return command
    }

    static func recordPatchArguments(
        _ slots: ChekinanaNLSlots,
        selections: ChekinanaConversationSelections,
        modelContext: ModelContext
    ) throws -> String {
        var result = ""
        if let idols = slots.idols {
            let ids = try idols.map { try resolveIdol($0, overrides: selections.idolOverrides, modelContext: modelContext) }
            result += " idols=\(ids.map(shortID).joined(separator: ","))"
        }
        if let event = slots.event {
            let id = try resolveEvent(event, overrides: selections.eventOverrides, modelContext: modelContext)
            result += " event=\(shortID(id))"
        }
        for (key, value) in [("date", slots.date), ("note", slots.note), ("size", slots.size)] where value != nil { result += " \(key)=\(try quote(value!))" }
        if let user = slots.user { result += " user=\(user)" }
        if let idx = slots.idx { result += " idx=\(idx)" }
        if let favorite = slots.favorite { result += " favorite=\(favorite)" }
        if let clear = slots.clearFields { result += " clear_fields=\(try quote(clear.joined(separator: ",")))" }
        return result
    }

    static func recordFilterArguments(
        _ slots: ChekinanaNLSlots,
        selections: ChekinanaConversationSelections,
        modelContext: ModelContext
    ) throws -> String {
        var result = ""
        if let idols = slots.idols {
            let ids = try idols.map { try resolveIdol($0, overrides: selections.idolOverrides, modelContext: modelContext) }
            result += " idols=\(ids.map(shortID).joined(separator: ","))"
        }
        if let event = slots.event {
            let id = try resolveEvent(event, overrides: selections.eventOverrides, modelContext: modelContext)
            result += " event=\(shortID(id))"
        }
        for (key, value) in [("date", slots.date), ("size", slots.size)] where value != nil { result += " \(key)=\(try quote(value!))" }
        if let idx = slots.idx { result += " idx=\(idx)" }
        if let favorite = slots.favorite { result += " favorite=\(favorite)" }
        return result
    }

    static func resolvedRecordTarget(
        _ slots: ChekinanaNLSlots,
        selections: ChekinanaConversationSelections,
        modelContext: ModelContext
    ) throws -> String {
        let target = try required(slots.target)
        guard slots.recordType == "cheki",
              let selected = selections.selectedChekiID,
              ChekinanaSelectedChekiLanguage.referencesSelectedCheki(target) else {
            return target
        }
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        let available = Set(((try? modelContext.fetch(FetchDescriptor<Cheki>())) ?? [])
            .filter { ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIDs) }
            .map(\.id))
        guard available.contains(selected) else { throw ResolutionError.staleLocalSelection }
        return shortID(selected)
    }

    static func resolvedIdolIDs(
        _ rawValues: [String]?,
        selections: ChekinanaConversationSelections,
        modelContext: ModelContext
    ) throws -> [UUID] {
        let ids: [UUID]
        if !selections.selectedIdolIDs.isEmpty {
            let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
            let available = Set(((try? modelContext.fetch(FetchDescriptor<Idol>())) ?? [])
                .filter { ChekinanaVisibilityPolicy.includesIdol($0.id, hiddenIDs: hiddenIDs) }
                .map(\.id))
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

    static func calendarDateString(_ date: Date) -> String {
        ChekinanaDateOnly.string(date)
    }

    static func resolveIdol(
        _ query: String,
        overrides: [String: UUID],
        modelContext: ModelContext
    ) throws -> UUID {
        let values = try modelContext.fetch(FetchDescriptor<Idol>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )).filter {
            ChekinanaVisibilityPolicy.includesIdol(
                $0.id,
                hiddenIDs: ChekinanaHiddenIdolPersistence.load()
            )
        }
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
        let date = event.date.map(ChekinanaDateOnly.string)
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
        guard rawValue != nil else { return "all" }
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
            guard isChekiAdd else {
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
            guard isChekiAdd else {
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

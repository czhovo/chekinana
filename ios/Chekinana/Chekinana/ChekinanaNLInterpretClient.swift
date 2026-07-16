import Foundation

enum ChekinanaNLIntent: String, Codable, CaseIterable, Sendable {
    case addidol
    case addevent
    case listidol
    case listevent
    case scancheki
    case addcheki
    case addscancheki
    case listcheki
    case showidol
    case showevent
    case showcheki
}

enum ChekinanaNLMissing: String, Codable, CaseIterable, Sendable {
    case idol
    case eventOrDate = "event_or_date"
    case eventName = "event_name"
    case date
    case temporaryCheki = "temporary_cheki"
}

struct ChekinanaNLSlots: Codable, Equatable, Sendable {
    var name: String?
    var url: String?
    var date: String?
    var idols: [String]?
    var idol: String?
    var event: String?
    var user: String?
    var size: String?
    var note: String?
    var temporary: String?
    var target: String?

    init(
        name: String? = nil,
        url: String? = nil,
        date: String? = nil,
        idols: [String]? = nil,
        idol: String? = nil,
        event: String? = nil,
        user: String? = nil,
        size: String? = nil,
        note: String? = nil,
        temporary: String? = nil,
        target: String? = nil
    ) {
        self.name = name
        self.url = url
        self.date = date
        self.idols = idols
        self.idol = idol
        self.event = event
        self.user = user
        self.size = size
        self.note = note
        self.temporary = temporary
        self.target = target
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case url
        case date
        case idols
        case idol
        case event
        case user
        case size
        case note
        case temporary
        case target
    }

    init(from decoder: Decoder) throws {
        try ChekinanaNLStrictCoding.rejectUnknownKeys(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        idols = try container.decodeIfPresent([String].self, forKey: .idols)
        idol = try container.decodeIfPresent(String.self, forKey: .idol)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        size = try container.decodeIfPresent(String.self, forKey: .size)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        temporary = try container.decodeIfPresent(String.self, forKey: .temporary)
        target = try container.decodeIfPresent(String.self, forKey: .target)
    }

    var presentKeys: Set<String> {
        var result = Set<String>()
        if name != nil { result.insert("name") }
        if url != nil { result.insert("url") }
        if date != nil { result.insert("date") }
        if idols != nil { result.insert("idols") }
        if idol != nil { result.insert("idol") }
        if event != nil { result.insert("event") }
        if user != nil { result.insert("user") }
        if size != nil { result.insert("size") }
        if note != nil { result.insert("note") }
        if temporary != nil { result.insert("temporary") }
        if target != nil { result.insert("target") }
        return result
    }
}

struct ChekinanaNLOperation: Codable, Equatable, Sendable {
    let intent: ChekinanaNLIntent
    var slots: ChekinanaNLSlots

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case intent
        case slots
    }

    init(intent: ChekinanaNLIntent, slots: ChekinanaNLSlots = .init()) {
        self.intent = intent
        self.slots = slots
    }

    init(from decoder: Decoder) throws {
        try ChekinanaNLStrictCoding.rejectUnknownKeys(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intent = try container.decode(ChekinanaNLIntent.self, forKey: .intent)
        slots = try container.decode(ChekinanaNLSlots.self, forKey: .slots)
    }
}

struct ChekinanaNLRequestDraft: Codable, Equatable, Sendable {
    let intent: ChekinanaNLIntent
    let slots: ChekinanaNLSlots
    let missing: [ChekinanaNLMissing]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case intent
        case slots
        case missing
    }

    init(operation: ChekinanaNLOperation, missing: [ChekinanaNLMissing]) {
        intent = operation.intent
        slots = operation.slots
        self.missing = missing
    }

    init(from decoder: Decoder) throws {
        try ChekinanaNLStrictCoding.rejectUnknownKeys(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intent = try container.decode(ChekinanaNLIntent.self, forKey: .intent)
        slots = try container.decode(ChekinanaNLSlots.self, forKey: .slots)
        missing = try container.decode([ChekinanaNLMissing].self, forKey: .missing)
    }

    var operation: ChekinanaNLOperation {
        ChekinanaNLOperation(intent: intent, slots: slots)
    }
}

struct ChekinanaNLInterpretRequest: Codable, Equatable, Sendable {
    let version: Int
    let utterance: String
    let localDate: String
    let timezone: String
    let draft: ChekinanaNLRequestDraft?

    init(
        utterance: String,
        localDate: String,
        timezone: String,
        draft: ChekinanaNLRequestDraft? = nil
    ) {
        version = 1
        self.utterance = utterance
        self.localDate = localDate
        self.timezone = timezone
        self.draft = draft
    }
}

enum ChekinanaNLInterpretation: Equatable, Sendable {
    case plan([ChekinanaNLOperation])
    case clarify(draft: ChekinanaNLOperation, missing: [ChekinanaNLMissing])
    case reject(code: String)
}

private struct ChekinanaNLInterpretEnvelope: Decodable {
    let interpretation: ChekinanaNLInterpretation

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case kind
        case operations
        case draft
        case missing
        case code
    }

    private enum Kind: String, Decodable {
        case plan
        case clarify
        case reject
    }

    init(from decoder: Decoder) throws {
        try ChekinanaNLStrictCoding.rejectUnknownKeys(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw ChekinanaNLClientError.invalidSchema
        }
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .plan:
            guard container.contains(.operations),
                  !container.contains(.draft),
                  !container.contains(.missing),
                  !container.contains(.code) else {
                throw ChekinanaNLClientError.invalidSchema
            }
            let operations = try container.decode([ChekinanaNLOperation].self, forKey: .operations)
            try ChekinanaNLSchemaValidator.validatePlan(operations)
            interpretation = .plan(operations)
        case .clarify:
            guard !container.contains(.operations),
                  container.contains(.draft),
                  container.contains(.missing),
                  !container.contains(.code) else {
                throw ChekinanaNLClientError.invalidSchema
            }
            let draft = try container.decode(ChekinanaNLOperation.self, forKey: .draft)
            let missing = try container.decode([ChekinanaNLMissing].self, forKey: .missing)
            try ChekinanaNLSchemaValidator.validateDraft(draft, missing: missing)
            interpretation = .clarify(draft: draft, missing: missing)
        case .reject:
            guard !container.contains(.operations),
                  !container.contains(.draft),
                  !container.contains(.missing),
                  container.contains(.code) else {
                throw ChekinanaNLClientError.invalidSchema
            }
            let code = try container.decode(String.self, forKey: .code)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard ChekinanaNLSchemaValidator.isKnownRejectCode(code) else {
                throw ChekinanaNLClientError.invalidSchema
            }
            interpretation = .reject(code: code)
        }
    }
}

enum ChekinanaNLClientError: LocalizedError, Equatable {
    case invalidRequest
    case sensitiveInput
    case cannotFindHost
    case notConnectedToInternet
    case timedOut
    case networkConnectionLost
    case cancelled
    case invalidHTTPStatus(Int)
    case serviceRejected(code: String, status: Int)
    case responseTooLarge
    case invalidSchema

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "invalid natural-language request"
        case .sensitiveInput:
            "natural-language request contains sensitive input"
        case .cannotFindHost:
            "natural-language service host could not be resolved"
        case .notConnectedToInternet:
            "device is not connected to the internet"
        case .timedOut:
            "natural-language request timed out"
        case .networkConnectionLost:
            "natural-language network connection was lost"
        case .cancelled:
            "natural-language request was cancelled"
        case .invalidHTTPStatus(let status):
            "natural-language service returned HTTP \(status)"
        case .serviceRejected(let code, let status):
            "natural-language service rejected the request with \(code) (HTTP \(status))"
        case .responseTooLarge:
            "natural-language response exceeded the size limit"
        case .invalidSchema:
            "natural-language service returned an invalid schema"
        }
    }
}

enum ChekinanaNLPrivacyGuard {
    static func containsPodScanCredential(_ utterance: String) -> Bool {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if ChekinanaASCIIScannerCommand.hasCaseInsensitivePrefix(trimmed),
           ChekinanaASCIIScannerCommand.exactCanonical(from: trimmed) == nil {
            return true
        }
        let patterns = [
            #"(?i)(?:使用|用)\s*(?:runpod\s*)?pod(?:\s*id)?\s*[：:=]?\s*[a-z0-9_-]+\s*(?:来)?(?:扫描|识别)"#,
            #"(?i)(?:runpod\s*)?pod(?:\s*id)?\s*(?:为|是|[:：=])\s*[a-z0-9_-]{6,}(?![a-z0-9_-])[^\r\n]{0,40}(?:扫描|识别)"#,
        ]
        return patterns.contains {
            utterance.range(of: $0, options: .regularExpression) != nil
        }
    }

    static func containsCredentialedHTTPURL(_ utterance: String) -> Bool {
        utterance.range(
            of: #"(?i)\bhttps?://[^\s/@:]+(?::[^\s/@]*)?@"#,
            options: .regularExpression
        ) != nil
    }

    static func allowsRemoteInterpretation(
        _ utterance: String,
        activeConfirmationCodes: Set<String> = []
    ) -> Bool {
        let normalized = utterance.lowercased()
        if containsPodScanCredential(utterance) {
            return false
        }
        if activeConfirmationCodes.contains(where: {
            let code = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !code.isEmpty && normalized.contains(code)
        }) {
            return false
        }

        let forbiddenPatterns = [
            #"(?i)\b[0-9a-f]{8}\b"#,
            #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#,
            #"(?i)\bauthorization\s*:"#,
            #"(?i)\bcookie\s*[:=]\s*\S+"#,
            #"(?i)\bbearer\s+\S+"#,
            #"(?i)\bx-cheki-token\s*[:=]\s*\S+"#,
            #"(?i)\b(?:access|refresh)[\s_-]*token\s*[:=]\s*\S+"#,
            #"(?i)\btoken\s*[:=]\s*\S+"#,
            #"(?i)\b(?:runpod[\s_-]*)?pod[\s_-]+(?:id|token)\s*[:=]\s*\S+"#,
            #"(?i)\b(?:runpod|pod)[\s:=]+(?=[a-z0-9_-]{6,}\b)(?=[a-z0-9_-]*[0-9])[a-z0-9_-]+\b"#,
            #"(?i)\bhttps?://[a-z0-9-]+(?:\.[a-z0-9-]+)*\.proxy\.runpod\.net(?:[/:?#][^\s]*)?"#,
        ]
        return !containsCredentialedHTTPURL(utterance) && forbiddenPatterns.allSatisfy {
            normalized.range(of: $0, options: .regularExpression) == nil
        }
    }
}

struct ChekinanaNLRequestGenerationGate: Equatable, Sendable {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ candidate: UInt64, isCancelled: Bool) -> Bool {
        !isCancelled && candidate == generation
    }
}

struct ChekinanaNLInterpretClient: Sendable {
    static let productionEndpoint = URL(string: "https://api.chekinana.top/api/nl/interpret")!
    static let transportTimeout: TimeInterval = 12
    static let maximumRequestBytes = 16_384

    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL = productionEndpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.transportTimeout
            configuration.timeoutIntervalForResource = Self.transportTimeout
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func interpret(
        utterance: String,
        localDate: String,
        timezone: String,
        draft: ChekinanaNLRequestDraft? = nil,
        activeConfirmationCodes: Set<String> = []
    ) async throws -> ChekinanaNLInterpretation {
        let trimmedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUtterance.isEmpty,
              trimmedUtterance.utf16.count <= 1_000,
              !trimmedUtterance.unicodeScalars.contains(where: { scalar in
                  scalar.value <= 0x08
                      || (0x0B...0x0C).contains(scalar.value)
                      || (0x0E...0x1F).contains(scalar.value)
                      || scalar.value == 0x7F
              }),
              ChekinanaNLSchemaValidator.isCalendarDate(localDate),
              !timezone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              timezone.utf16.count <= 64 else {
            throw ChekinanaNLClientError.invalidRequest
        }
        guard ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(
            trimmedUtterance,
            activeConfirmationCodes: activeConfirmationCodes
        ) else {
            throw ChekinanaNLClientError.sensitiveInput
        }
        if let draft {
            try ChekinanaNLSchemaValidator.validateDraft(draft.operation, missing: draft.missing)
        }

#if DEBUG
        if let mode = ProcessInfo.processInfo.environment["CHEKINANA_NL_UI_STUB"],
           !mode.isEmpty {
            let interpretation = try await ChekinanaNLDebugStub.shared.interpret(
                mode: mode,
                utterance: trimmedUtterance,
                launchID: ProcessInfo.processInfo.environment["CHEKINANA_UI_LAUNCH_ID"]
            )
            try ChekinanaNLSchemaValidator.validateContinuation(
                interpretation,
                requestDraft: draft
            )
            try ChekinanaNLSchemaValidator.validateSuccessInterpretation(interpretation)
            return interpretation
        }
#endif

        let body = ChekinanaNLInterpretRequest(
            utterance: trimmedUtterance,
            localDate: localDate,
            timezone: timezone,
            draft: draft
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.transportTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let encodedBody = try JSONEncoder().encode(body)
        guard encodedBody.count <= Self.maximumRequestBytes else {
            throw ChekinanaNLClientError.invalidRequest
        }
        request.httpBody = encodedBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ChekinanaNLClientError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                throw ChekinanaNLClientError.cannotFindHost
            case .notConnectedToInternet, .cannotConnectToHost:
                throw ChekinanaNLClientError.notConnectedToInternet
            case .timedOut:
                throw ChekinanaNLClientError.timedOut
            case .networkConnectionLost:
                throw ChekinanaNLClientError.networkConnectionLost
            case .cancelled:
                throw ChekinanaNLClientError.cancelled
            default:
                throw error
            }
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChekinanaNLClientError.invalidSchema
        }
        guard data.count <= 256 * 1_024 else {
            throw ChekinanaNLClientError.responseTooLarge
        }
        guard httpResponse.statusCode == 200 else {
            if let envelope = try? JSONDecoder().decode(ChekinanaNLInterpretEnvelope.self, from: data),
               case .reject(let code) = envelope.interpretation {
                do {
                    try ChekinanaNLSchemaValidator.validateRejectHTTPPair(
                        code: code,
                        status: httpResponse.statusCode
                    )
                } catch {
                    throw ChekinanaNLClientError.invalidSchema
                }
                throw ChekinanaNLClientError.serviceRejected(
                    code: code,
                    status: httpResponse.statusCode
                )
            }
            throw ChekinanaNLClientError.invalidHTTPStatus(httpResponse.statusCode)
        }
        do {
            let interpretation = try JSONDecoder()
                .decode(ChekinanaNLInterpretEnvelope.self, from: data)
                .interpretation
            try ChekinanaNLSchemaValidator.validateContinuation(
                interpretation,
                requestDraft: draft
            )
            try ChekinanaNLSchemaValidator.validateSuccessInterpretation(interpretation)
            return interpretation
        } catch let error as ChekinanaNLClientError {
            throw error
        } catch {
            throw ChekinanaNLClientError.invalidSchema
        }
    }

    static func localDateString(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

#if DEBUG
private actor ChekinanaNLDebugStub {
    static let shared = ChekinanaNLDebugStub()
    private var requestCounts: [String: Int] = [:]
    private var currentLaunchID: String?

    func interpret(
        mode: String,
        utterance: String,
        launchID: String? = nil
    ) async throws -> ChekinanaNLInterpretation {
        if currentLaunchID != launchID {
            currentLaunchID = launchID
            requestCounts.removeAll()
        }
        requestCounts[mode, default: 0] += 1
        switch mode {
        case "cannot_find_host": throw ChekinanaNLClientError.cannotFindHost
        case "offline": throw ChekinanaNLClientError.notConnectedToInternet
        case "timeout": throw ChekinanaNLClientError.timedOut
        case "connection_lost": throw ChekinanaNLClientError.networkConnectionLost
        case "401": throw ChekinanaNLClientError.invalidHTTPStatus(401)
        case "404": throw ChekinanaNLClientError.invalidHTTPStatus(404)
        case "429": throw ChekinanaNLClientError.invalidHTTPStatus(429)
        case "rate_limit_unavailable": throw ChekinanaNLClientError.serviceRejected(code: mode, status: 503)
        case "upstream_timeout": throw ChekinanaNLClientError.serviceRejected(code: mode, status: 503)
        case "upstream_unavailable": throw ChekinanaNLClientError.serviceRejected(code: mode, status: 503)
        case "invalid_model_output": throw ChekinanaNLClientError.serviceRejected(code: mode, status: 422)
        case "invalid_schema": throw ChekinanaNLClientError.invalidSchema
        case "success":
            return .plan([ChekinanaNLOperation(intent: .listevent)])
        case "retry_success":
            if requestCounts[mode] == 1 {
                throw ChekinanaNLClientError.cannotFindHost
            }
            return .plan([ChekinanaNLOperation(intent: .listidol)])
        case "retry_add_event_success":
            if requestCounts[mode] == 1 {
                throw ChekinanaNLClientError.cannotFindHost
            }
            if requestCounts[mode, default: 0] > 2 {
                return uiRouterInterpretation(utterance: utterance)
            }
            return .plan([
                ChekinanaNLOperation(
                    intent: .addevent,
                    slots: .init(name: "Remote Retry", date: "2026-08-03")
                )
            ])
        case "event_candidate":
            guard let url = ChekinanaEventWeiboInput.extractedURL(from: utterance),
                  ChekinanaEventCandidateValidator.isPublicWeiboStatusURL(url) else {
                return uiRouterInterpretation(utterance: utterance)
            }
            return .clarify(
                draft: .init(intent: .addevent, slots: .init(url: url)),
                missing: [.eventName, .date]
            )
        case "event_candidate_then_cancel":
            if requestCounts[mode] == 1,
               let url = ChekinanaEventWeiboInput.extractedURL(from: utterance),
               ChekinanaEventCandidateValidator.isPublicWeiboStatusURL(url) {
                return .clarify(
                    draft: .init(intent: .addevent, slots: .init(url: url)),
                    missing: [.eventName, .date]
                )
            }
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                throw ChekinanaNLClientError.cancelled
            }
            return .reject(code: "unsupported_request")
        case "draft_retry_success":
            switch requestCounts[mode, default: 0] {
            case 1:
                return .clarify(
                    draft: .init(intent: .addevent, slots: .init(name: "Draft Event")),
                    missing: [.date]
                )
            case 2:
                throw ChekinanaNLClientError.cannotFindHost
            default:
                return .plan([.init(
                    intent: .addevent,
                    slots: .init(name: "Draft Event", date: "2026-08-09")
                )])
            }
        case "draft_then_cancel":
            if requestCounts[mode, default: 0] == 1 {
                return .clarify(
                    draft: .init(intent: .addevent, slots: .init(name: "Draft Event")),
                    missing: [.date]
                )
            }
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                throw ChekinanaNLClientError.cancelled
            }
            return .reject(code: "unsupported_request")
        case "ui_router":
            return uiRouterInterpretation(utterance: utterance)
        case "ambiguous_idol":
            return .plan([
                ChekinanaNLOperation(intent: .showidol, slots: .init(target: "Ali"))
            ])
        case "cancel":
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                throw ChekinanaNLClientError.cancelled
            }
            return .reject(code: "unsupported_request")
        default:
            return .reject(code: "unsupported_request")
        }
    }

    private func uiRouterInterpretation(utterance: String) -> ChekinanaNLInterpretation {
        let translation = ChekinanaNaturalLanguageTranslator.translate(utterance)
        if translation.commands.isEmpty {
            if translation.intent == "addidol" {
                return .clarify(draft: .init(intent: .addidol), missing: [.idol])
            }
            if translation.intent == "addevent",
               let draft = ChekinanaLocalEventLanguage.draft(from: utterance) {
                return .clarify(draft: draft.operation, missing: draft.missing)
            }
            return .reject(code: "unsupported_request")
        }
        do {
            return .plan(try translation.commands.map(uiRouterOperation))
        } catch {
            return .reject(code: "unsupported_request")
        }
    }

    private func uiRouterOperation(command: String) throws -> ChekinanaNLOperation {
        let parsed = try ChekinanaCommandParser.parse(command)
        let arguments = parsed.arguments
        switch parsed.name {
        case "addidol":
            return .init(intent: .addidol, slots: .init(name: parsed.target))
        case "addevent":
            let target = parsed.target
            let isURL = target?.range(
                of: #"^https?://"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            return .init(intent: .addevent, slots: .init(
                name: isURL ? arguments["name"] : target,
                url: isURL ? target : nil,
                date: arguments["date"]
            ))
        case "listidol": return .init(intent: .listidol)
        case "listevent": return .init(intent: .listevent)
        case "scancheki": return .init(intent: .scancheki)
        case "addcheki", "addscancheki":
            let rawIdols = arguments["idols"] ?? arguments["idol"] ?? (parsed.name == "addcheki" ? parsed.target : nil)
            let idols = rawIdols?.split(separator: ",").map(String.init)
            let slots = ChekinanaNLSlots(
                date: arguments["date"],
                idols: idols,
                event: arguments["event"],
                user: arguments["user"] ?? arguments["userappears"],
                size: arguments["size"],
                note: arguments["note"],
                temporary: parsed.name == "addscancheki" ? parsed.target : nil
            )
            return .init(intent: parsed.name == "addcheki" ? .addcheki : .addscancheki, slots: slots)
        case "listcheki":
            return .init(intent: .listcheki, slots: .init(
                date: arguments["date"],
                idol: arguments["idol"],
                event: arguments["event"]
            ))
        case "showidol": return .init(intent: .showidol, slots: .init(target: parsed.target))
        case "showevent": return .init(intent: .showevent, slots: .init(target: parsed.target))
        case "showcheki": return .init(intent: .showcheki, slots: .init(target: parsed.target))
        default:
            throw ChekinanaNLClientError.invalidSchema
        }
    }
}
#endif

enum ChekinanaNLSchemaValidator {
    private static let rejectHTTPStatuses: [String: Int] = [
        "method_not_allowed": 405,
        "invalid_request": 400,
        "rate_limited": 429,
        "invalid_model_output": 422,
        "service_unavailable": 503,
        "rate_limit_unavailable": 503,
        "upstream_timeout": 503,
        "upstream_unavailable": 503,
    ]

    static func isKnownRejectCode(_ code: String) -> Bool {
        code == "unsupported_request" || rejectHTTPStatuses[code] != nil
    }

    static func validateSuccessInterpretation(
        _ interpretation: ChekinanaNLInterpretation
    ) throws {
        if case .reject(let code) = interpretation,
           code != "unsupported_request" {
            throw ChekinanaNLClientError.invalidSchema
        }
    }

    static func validateRejectHTTPPair(code: String, status: Int) throws {
        guard rejectHTTPStatuses[code] == status else {
            throw ChekinanaNLClientError.invalidSchema
        }
    }

    static func validateContinuation(
        _ interpretation: ChekinanaNLInterpretation,
        requestDraft: ChekinanaNLRequestDraft?
    ) throws {
        guard let requestDraft else { return }
        switch interpretation {
        case .plan(let operations):
            guard operations.count == 1,
                  operations[0].intent == requestDraft.intent else {
                throw ChekinanaNLClientError.invalidSchema
            }
            try validateContinuationOperation(operations[0], requestDraft: requestDraft)
        case .clarify(let operation, _):
            guard operation.intent == requestDraft.intent else {
                throw ChekinanaNLClientError.invalidSchema
            }
            try validateContinuationOperation(operation, requestDraft: requestDraft)
        case .reject:
            break
        }
    }

    private static func validateContinuationOperation(
        _ operation: ChekinanaNLOperation,
        requestDraft: ChekinanaNLRequestDraft
    ) throws {
        let before = requestDraft.slots
        let after = operation.slots
        guard (before.name == nil || before.name == after.name),
              (before.url == nil || before.url == after.url),
              (before.date == nil || before.date == after.date),
              (before.idols == nil || before.idols == after.idols),
              (before.idol == nil || before.idol == after.idol),
              (before.event == nil || before.event == after.event),
              (before.user == nil || before.user == after.user),
              (before.size == nil || before.size == after.size),
              (before.note == nil || before.note == after.note),
              (before.temporary == nil || before.temporary == after.temporary),
              (before.target == nil || before.target == after.target) else {
            throw ChekinanaNLClientError.invalidSchema
        }

        var fillable = Set<String>()
        for missing in requestDraft.missing {
            switch missing {
            case .idol:
                fillable.insert(requestDraft.intent == .addidol ? "name" : "idols")
            case .eventOrDate:
                fillable.formUnion(["event", "date"])
            case .eventName:
                fillable.insert("name")
            case .date:
                fillable.insert("date")
            case .temporaryCheki:
                fillable.insert("temporary")
            }
        }
        let addedKeys = after.presentKeys.subtracting(before.presentKeys)
        guard addedKeys.isSubset(of: fillable) else {
            throw ChekinanaNLClientError.invalidSchema
        }
    }

    static func validatePlan(_ operations: [ChekinanaNLOperation]) throws {
        guard (1...5).contains(operations.count) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        if operations.count > 1 {
            let intents = Set(operations.map(\.intent))
            guard intents.count == 1,
                  intents.first == .addidol || intents.first == .addevent else {
                throw ChekinanaNLClientError.invalidSchema
            }
        }
        try operations.forEach { try validateOperation($0, allowingPartial: false) }
    }

    static func validateDraft(_ operation: ChekinanaNLOperation, missing: [ChekinanaNLMissing]) throws {
        try validateOperation(operation, allowingPartial: true)
        let expected = expectedMissing(for: operation)
        guard (1...5).contains(missing.count),
              missing.count == Set(missing).count,
              missing.count == expected.count,
              missing.allSatisfy(expected.contains) else {
            throw ChekinanaNLClientError.invalidSchema
        }
    }

    static func expectedMissing(for operation: ChekinanaNLOperation) -> [ChekinanaNLMissing] {
        let slots = operation.slots
        switch operation.intent {
        case .addidol:
            return slots.name == nil ? [.idol] : []
        case .addevent:
            var missing: [ChekinanaNLMissing] = []
            if slots.name == nil { missing.append(.eventName) }
            if slots.date == nil { missing.append(.date) }
            return missing
        case .addcheki:
            var missing: [ChekinanaNLMissing] = []
            if slots.idols?.isEmpty != false { missing.append(.idol) }
            if slots.event == nil, slots.date == nil { missing.append(.eventOrDate) }
            return missing
        case .addscancheki:
            var missing: [ChekinanaNLMissing] = []
            if slots.temporary == nil { missing.append(.temporaryCheki) }
            if slots.idols?.isEmpty != false { missing.append(.idol) }
            if slots.event == nil, slots.date == nil { missing.append(.eventOrDate) }
            return missing
        case .listidol, .listevent, .scancheki, .listcheki, .showidol, .showevent, .showcheki:
            return []
        }
    }

    static func validateOperation(_ operation: ChekinanaNLOperation, allowingPartial: Bool) throws {
        let slots = operation.slots
        let allowed: Set<String>
        switch operation.intent {
        case .addidol:
            allowed = ["name"]
        case .addevent:
            allowed = ["url", "name", "date"]
        case .listidol, .listevent, .scancheki:
            allowed = []
        case .addcheki:
            allowed = ["idols", "event", "date", "user", "size", "note"]
        case .addscancheki:
            allowed = ["temporary", "idols", "event", "date", "user", "size", "note"]
        case .listcheki:
            allowed = ["idol", "event", "date"]
        case .showidol, .showevent, .showcheki:
            allowed = ["target"]
        }
        guard slots.presentKeys.isSubset(of: allowed) else {
            throw ChekinanaNLClientError.invalidSchema
        }

        try validateStrings(slots, intent: operation.intent)
        if let date = slots.date, !isCalendarDate(date) {
            throw ChekinanaNLClientError.invalidSchema
        }
        if let url = slots.url, !isSafeHTTPURL(url) {
            throw ChekinanaNLClientError.invalidSchema
        }
        if operation.intent == .addevent,
           let name = slots.name,
           isSafeHTTPURL(name) {
            throw ChekinanaNLClientError.invalidSchema
        }
        if let user = slots.user, !["true", "false", "?"].contains(user) {
            throw ChekinanaNLClientError.invalidSchema
        }
        if let size = slots.size, !["mini", "wide", "else", "?"].contains(size) {
            throw ChekinanaNLClientError.invalidSchema
        }
        if slots.event != nil, slots.date != nil {
            throw ChekinanaNLClientError.invalidSchema
        }
        guard !allowingPartial else { return }

        switch operation.intent {
        case .addidol:
            try require(slots.name)
        case .addevent:
            try require(slots.name)
            try require(slots.date)
        case .addcheki:
            try requireNonempty(slots.idols)
            guard (slots.event != nil) != (slots.date != nil) else {
                throw ChekinanaNLClientError.invalidSchema
            }
        case .addscancheki:
            try require(slots.temporary)
            try requireNonempty(slots.idols)
            guard (slots.event != nil) != (slots.date != nil) else {
                throw ChekinanaNLClientError.invalidSchema
            }
        case .showidol, .showevent, .showcheki:
            try require(slots.target)
        case .listidol, .listevent, .scancheki, .listcheki:
            break
        }
    }

    static func isCalendarDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func isSafeHTTPURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return true
    }

    private static func validateStrings(
        _ slots: ChekinanaNLSlots,
        intent: ChekinanaNLIntent
    ) throws {
        if let name = slots.name {
            try validateString(name, maximum: intent == .addevent ? 300 : 200)
        }
        if let url = slots.url { try validateString(url, maximum: 1_000) }
        if let date = slots.date { try validateString(date, maximum: 10) }
        for value in [slots.idol, slots.event, slots.temporary, slots.target].compactMap({ $0 }) {
            try validateString(value, maximum: 200)
        }
        if let note = slots.note { try validateString(note, maximum: 500) }
        if let user = slots.user { try validateString(user, maximum: 5) }
        if let size = slots.size { try validateString(size, maximum: 4) }
        if let idols = slots.idols {
            guard (1...20).contains(idols.count) else {
                throw ChekinanaNLClientError.invalidSchema
            }
            try idols.forEach { try validateString($0, maximum: 200) }
            let normalized = idols.map(normalizedIdentity)
            guard Set(normalized).count == normalized.count else {
                throw ChekinanaNLClientError.invalidSchema
            }
        }
    }

    private static func validateString(_ value: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf16.count <= maximum,
              value.range(
                of: #"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"#,
                options: .regularExpression
              ) == nil else {
            throw ChekinanaNLClientError.invalidSchema
        }
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func require(_ value: String?) throws {
        guard value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ChekinanaNLClientError.invalidSchema
        }
    }

    private static func requireNonempty(_ values: [String]?) throws {
        guard let values, !values.isEmpty else {
            throw ChekinanaNLClientError.invalidSchema
        }
    }
}

private enum ChekinanaNLStrictCoding {
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw ChekinanaNLClientError.invalidSchema
        }
    }
}

import Foundation

struct ChekinanaEventCandidateFields: Equatable, Sendable {
    var name: String
    var date: String
    var city: String
    var livehouse: String
    var address: String
    var price: String
    var avatarURL: String
    var imageUrls: [String]
    var weiboURL: String
    var ticketURL: String
    // Local-only compatibility field. Model output is never copied into Event.note.
    var note: String

    static let keys: Set<String> = [
        "name", "date", "city", "livehouse", "address", "price", "avatar_url",
        "imageUrls", "weiboURL", "ticketURL",
    ]

    private static let priorKeys = keys.subtracting(["imageUrls"])

    init(
        name: String,
        date: String,
        city: String,
        livehouse: String,
        address: String = "",
        price: String = "",
        avatarURL: String = "",
        imageUrls: [String] = [],
        weiboURL: String,
        ticketURL: String,
        note: String = ""
    ) {
        self.name = name
        self.date = date
        self.city = city
        self.livehouse = livehouse
        self.address = address
        self.price = price
        self.avatarURL = avatarURL
        self.imageUrls = imageUrls
        self.weiboURL = weiboURL
        self.ticketURL = ticketURL
        self.note = note
    }

    init(strictDictionary: [String: Any]) throws {
        let responseKeys = Set(strictDictionary.keys)
        let legacyKeys = Set([
            "name", "date", "city", "livehouse", "weiboURL", "ticketURL", "note",
        ])
        guard responseKeys == Self.keys
                || responseKeys == Self.priorKeys
                || responseKeys == legacyKeys else {
            throw ChekinanaEventCandidateClientError.invalidResponse
        }
        func requiredString(_ key: String) throws -> String {
            guard let value = strictDictionary[key] as? String else {
                throw ChekinanaEventCandidateClientError.invalidResponse
            }
            return value
        }
        func requiredStringArray(_ key: String) throws -> [String] {
            guard let values = strictDictionary[key] as? [Any],
                  values.count <= 12,
                  values.allSatisfy({ $0 is String }) else {
                throw ChekinanaEventCandidateClientError.invalidResponse
            }
            return values.compactMap { $0 as? String }
        }
        let isModern = responseKeys == Self.keys || responseKeys == Self.priorKeys
        self.init(
            name: try requiredString("name"),
            date: try requiredString("date"),
            city: try requiredString("city"),
            livehouse: try requiredString("livehouse"),
            address: isModern ? try requiredString("address") : "",
            price: isModern ? try requiredString("price") : "",
            avatarURL: isModern ? try requiredString("avatar_url") : "",
            imageUrls: responseKeys == Self.keys ? try requiredStringArray("imageUrls") : [],
            weiboURL: try requiredString("weiboURL"),
            ticketURL: try requiredString("ticketURL"),
            note: ""
        )
        if responseKeys == legacyKeys {
            // Validate the legacy wire shape without ever importing model prose
            // into the user's editable Event.note.
            _ = try requiredString("note")
        }
    }
}

enum ChekinanaEventCandidateBlocker: Equatable, Sendable, Identifiable {
    case missingName
    case invalidDate
    case invalidWeiboURL
    case invalidTicketURL
    case livehouseLooksLikeAddress
    case fieldTooLong(String)

    var id: String {
        switch self {
        case .missingName: "missing-name"
        case .invalidDate: "invalid-date"
        case .invalidWeiboURL: "invalid-weibo-url"
        case .invalidTicketURL: "invalid-ticket-url"
        case .livehouseLooksLikeAddress: "livehouse-address"
        case .fieldTooLong(let field): "field-too-long-\(field)"
        }
    }

    var message: String {
        switch self {
        case .missingName:
            ChekinanaL10n.text("assistant.event.error.name", fallback: "The Event name is required.")
        case .invalidDate:
            ChekinanaL10n.text("assistant.event.error.date", fallback: "Use YYYY-MM-DD, or leave the date empty if it is undetermined.")
        case .invalidWeiboURL:
            ChekinanaL10n.text("assistant.event.error.weibo", fallback: "The Weibo URL must be a public HTTPS status URL on weibo.com.")
        case .invalidTicketURL:
            ChekinanaL10n.text("assistant.event.error.ticket", fallback: "Use an HTTPS URL on a trusted ticket site, or leave it empty.")
        case .livehouseLooksLikeAddress:
            ChekinanaL10n.text("assistant.event.error.livehouse", fallback: "The venue appears to include a street address. Keep only the venue name or clear it.")
        case .fieldTooLong(let field):
            ChekinanaL10n.format("assistant.event.error.too_long", fallback: "%@ is too long. Shorten it before confirming.", field)
        }
    }
}

enum ChekinanaEventCandidateValidator {
    private static let trustedTicketDomains: Set<String> = [
        "showstart.com", "damai.cn", "piaoxingqiu.com", "maoyan.com",
        "247tickets.com", "gewara.com", "motntickets.com", "cityline.com",
        "hkticketing.com",
    ]

    static func blockers(for fields: ChekinanaEventCandidateFields) -> [ChekinanaEventCandidateBlocker] {
        var blockers: [ChekinanaEventCandidateBlocker] = []
        if fields.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockers.append(.missingName)
        }
        let date = fields.date.trimmingCharacters(in: .whitespacesAndNewlines)
        if !date.isEmpty, !isCalendarDate(date) {
            blockers.append(.invalidDate)
        }
        let weiboURL = fields.weiboURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !weiboURL.isEmpty, !isPublicWeiboStatusURL(weiboURL) {
            blockers.append(.invalidWeiboURL)
        }
        let ticketURL = fields.ticketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ticketURL.isEmpty, !isTrustedTicketURL(ticketURL) {
            blockers.append(.invalidTicketURL)
        }
        if livehouseLooksLikeDetailedAddress(fields.livehouse) {
            blockers.append(.livehouseLooksLikeAddress)
        }
        for (field, value, limit) in [
            (ChekinanaL10n.text("assistant.event.field.name", fallback: "Name"), fields.name, 200),
            (ChekinanaL10n.text("assistant.event.field.city", fallback: "City"), fields.city, 100),
            (ChekinanaL10n.text("assistant.event.field.livehouse", fallback: "Livehouse"), fields.livehouse, 300),
            (ChekinanaL10n.text("assistant.event.field.address", fallback: "Address"), fields.address, 1_000),
            (ChekinanaL10n.text("assistant.event.field.price", fallback: "Price"), fields.price, 500),
            (ChekinanaL10n.text("assistant.event.field.avatar", fallback: "Avatar URL"), fields.avatarURL, 2_048),
            (ChekinanaL10n.text("assistant.event.field.weibo", fallback: "Weibo URL"), fields.weiboURL, 2_048),
            (ChekinanaL10n.text("assistant.event.field.ticket", fallback: "Ticket URL"), fields.ticketURL, 2_048),
            (ChekinanaL10n.text("assistant.note", fallback: "Note"), fields.note, 2_000),
        ] where value.utf8.count > limit {
            blockers.append(.fieldTooLong(field))
        }
        if fields.imageUrls.contains(where: { $0.utf8.count > 2_048 }) {
            blockers.append(.fieldTooLong(ChekinanaL10n.text(
                "assistant.event.field.images",
                fallback: "Event image URL"
            )))
        }
        return blockers
    }

    static func isPublicWeiboStatusURL(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedValue = value.lowercased()
        let authorities = ["https://weibo.com", "https://www.weibo.com"]
        guard value.utf8.count <= 2_048,
              let authority = authorities.first(where: {
                lowercasedValue.hasPrefix($0 + "/")
              }) else {
            return false
        }
        let rawPercentEncodedPath = value.dropFirst(authority.count)
        guard !rawPercentEncodedPath.contains("?"),
              !rawPercentEncodedPath.contains("#"),
              !rawPercentEncodedPath.contains("\\") else {
            return false
        }
        let segments = rawPercentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard segments.count == 3,
              segments[0].isEmpty,
              !segments[1].isEmpty,
              !segments[2].isEmpty,
              let user = String(segments[1]).removingPercentEncoding,
              let statusID = String(segments[2]).removingPercentEncoding else {
            return false
        }
        let userScalars = user.unicodeScalars
        guard (1...200).contains(userScalars.count),
              user != ".",
              user != "..",
              !userScalars.contains(where: { scalar in
                scalar.value <= 0x1F
                    || scalar.value == 0x7F
                    || scalar.value == 0x2F
                    || scalar.value == 0x3F
                    || scalar.value == 0x23
                    || scalar.value == 0x5C
              }),
              !statusID.isEmpty else {
            return false
        }
        return statusID.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
        }
    }

    static func isTrustedTicketURL(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2_048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.port == nil else {
            return false
        }
        return trustedTicketDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    static func isCalendarDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        guard let date = ChekinanaDateOnly.parse(value) else { return false }
        return ChekinanaDateOnly.string(date) == value
    }

    static func livehouseLooksLikeDetailedAddress(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let patterns = [
            #"(?:[0-9]+|[零〇一二两三四五六七八九十百千万]+)\s*号(?!馆|店|厅)"#,
            #"(?:[0-9]+|[零〇一二两三四五六七八九十百千万]+)\s*(?:弄|栋|幢|室|层|单元)"#,
            #"(?:路|街|道|巷|弄).{0,12}[0-9]+"#,
            #"(?:省|市|区|县).*(?:路|街|道|巷|弄)"#,
            #"(?:路|街|道|巷|弄)(?:东|西|南|北|中)?(?:段|侧|口|附近|交叉口|与)"#,
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}

enum ChekinanaEventWeiboInput {
    static func extractedURL(from rawInput: String) -> String? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return input
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*(?:(?:请|麻烦|帮我|现在请)?\s*(?:添加|新增|创建|录入)(?:一个)?\s*(?:event|活动|场次)|addevent)\s+(https?://\S+?)\s*[。！!？?]*$"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, range: range),
              let urlRange = Range(match.range(at: 1), in: input) else {
            return nil
        }
        return String(input[urlRange])
    }
}

struct ChekinanaEventCandidateStateMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case extracting(url: String)
        case editing(ChekinanaEventCandidateFields)
        case failed(url: String, message: String)
    }

    private(set) var generation: UInt64 = 0
    private(set) var phase: Phase = .idle

    mutating func begin(url: String) -> UInt64 {
        generation &+= 1
        phase = .extracting(url: url)
        return generation
    }

    func accepts(_ candidateGeneration: UInt64, isCancelled: Bool) -> Bool {
        guard !isCancelled,
              candidateGeneration == generation,
              case .extracting = phase else {
            return false
        }
        return true
    }

    @discardableResult
    mutating func complete(
        _ fields: ChekinanaEventCandidateFields,
        generation candidateGeneration: UInt64
    ) -> Bool {
        guard accepts(candidateGeneration, isCancelled: false) else { return false }
        phase = .editing(fields)
        return true
    }

    @discardableResult
    mutating func fail(
        url: String,
        message: String,
        generation candidateGeneration: UInt64
    ) -> Bool {
        guard accepts(candidateGeneration, isCancelled: false) else { return false }
        phase = .failed(url: url, message: message)
        return true
    }

    mutating func update(_ fields: ChekinanaEventCandidateFields) {
        guard case .editing = phase else { return }
        phase = .editing(fields)
    }

    mutating func invalidate() {
        generation &+= 1
        phase = .idle
    }
}

struct ChekinanaEventCandidateBusyOwner: Equatable, Sendable {
    private(set) var generation: UInt64?

    mutating func acquire(generation candidateGeneration: UInt64) -> Bool {
        guard generation == nil else { return false }
        generation = candidateGeneration
        return true
    }

    func owns(generation candidateGeneration: UInt64, isCancelled: Bool) -> Bool {
        !isCancelled && generation == candidateGeneration
    }

    @discardableResult
    mutating func release(generation candidateGeneration: UInt64) -> Bool {
        guard generation == candidateGeneration else { return false }
        generation = nil
        return true
    }
}

struct ChekinanaEventCandidateExtractionGate: Equatable, Sendable {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func accepts(_ candidateGeneration: UInt64, isCancelled: Bool) -> Bool {
        !isCancelled && candidateGeneration == generation
    }

    mutating func invalidate() {
        generation &+= 1
    }
}

enum ChekinanaEventCandidateClientError: LocalizedError, Equatable {
    case invalidURL
    case emptyText
    case invalidTextCharacters
    case textTooLarge
    case invalidServiceConfiguration
    case invalidResponse
    case responseTooLarge
    case timedOut
    case networkUnavailable
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            ChekinanaL10n.text("assistant.event.client.invalid_url", fallback: "Enter a public Weibo status URL.")
        case .emptyText:
            ChekinanaL10n.text("assistant.event.client.empty_text", fallback: "Enter the full Weibo post text.")
        case .invalidTextCharacters:
            ChekinanaL10n.text("assistant.event.client.characters", fallback: "The post contains unsupported control characters. Remove them and try again.")
        case .textTooLarge:
            ChekinanaL10n.text("assistant.event.client.text_large", fallback: "The post exceeds 32 KiB. Shorten it and try again.")
        case .invalidServiceConfiguration:
            ChekinanaL10n.text("assistant.event.client.configuration", fallback: "The Event extraction service address is invalid.")
        case .invalidResponse:
            ChekinanaL10n.text("assistant.event.client.response", fallback: "The Event extraction response could not be parsed safely.")
        case .responseTooLarge:
            ChekinanaL10n.text("assistant.event.client.response_large", fallback: "The Event extraction response was too large and was rejected.")
        case .timedOut:
            ChekinanaL10n.text("assistant.event.client.timeout", fallback: "Event extraction timed out. Try again later.")
        case .networkUnavailable:
            ChekinanaL10n.text("assistant.event.client.network", fallback: "The Event extraction service is unavailable. Check the network and try again.")
        case .rejected(let code):
            switch code {
            case "invalid_request", "invalid_weibo_url":
                ChekinanaL10n.text("assistant.event.reject.invalid_url", fallback: "This is not a supported public Weibo status URL.")
            case "status_unavailable", "not_found":
                ChekinanaL10n.text("assistant.event.reject.not_found", fallback: "This public Weibo status could not be read.")
            case "upstream_timeout":
                ChekinanaL10n.text("assistant.event.reject.upstream_timeout", fallback: "Reading the Weibo status timed out. Try again later.")
            case "weibo_timeout", "weibo_upstream_timeout":
                ChekinanaL10n.text("assistant.event.reject.weibo_timeout", fallback: "Reading the Weibo post timed out. Try again later or enter the Event fields manually.")
            case "weibo_upstream_unavailable":
                ChekinanaL10n.text("assistant.event.reject.weibo_unavailable", fallback: "The Weibo post is temporarily unavailable. Try again later or enter the Event fields manually.")
            case "service_unavailable":
                ChekinanaL10n.text("assistant.event.reject.service", fallback: "Event extraction is temporarily unavailable. Try again later or enter the fields manually.")
            case "model_timeout":
                ChekinanaL10n.text("assistant.event.reject.model_timeout", fallback: "The Event model timed out. Try again later.")
            case "model_rejected":
                ChekinanaL10n.text("assistant.event.reject.model_rejected", fallback: "The Event could not be parsed. Check the post or enter the fields manually.")
            case "model_unavailable", "invalid_model_response":
                ChekinanaL10n.text("assistant.event.reject.model_unavailable", fallback: "The Event model is temporarily unavailable. Try again later or enter the fields manually.")
            case "invalid_model_output":
                ChekinanaL10n.text("assistant.event.reject.model_output", fallback: "No safe Event details could be parsed. Check the post or enter the fields manually.")
            case "invalid_text", "text_too_large":
                ChekinanaL10n.text("assistant.event.reject.text", fallback: "The Weibo post is invalid or too long. Check it and try again.")
            case "rate_limited":
                ChekinanaL10n.text("assistant.event.reject.rate", fallback: "Too many requests. Try again later.")
            default:
                ChekinanaL10n.format("assistant.event.reject.default", fallback: "Event extraction failed (%@). Try again later.", code)
            }
        }
    }
}

struct ChekinanaEventCandidateClient {
    private static let maximumResponseBytes = 64 * 1_024
    static let maximumRequestBytes = 32 * 1_024
    static let maximumTextBytes = maximumRequestBytes
    static let requestTimeout: TimeInterval = 45
    private let endpointURL: URL?
    private let session: URLSession

    init(session: URLSession = Self.ephemeralSession()) {
        endpointURL = Self.endpoint(
            from: .resolved(ChekinanaScannerConfiguration.productionBaseURL)
        )
        self.session = session
    }

    init(baseURL: URL, session: URLSession = Self.ephemeralSession()) {
        endpointURL = Self.endpoint(from: .resolved(baseURL))
        self.session = session
    }

    init(endpointURL: URL, session: URLSession = Self.ephemeralSession()) {
        self.endpointURL = endpointURL
        self.session = session
    }

    func fetch(weiboURL: String) async throws -> ChekinanaEventCandidateFields {
        guard ChekinanaEventCandidateValidator.isPublicWeiboStatusURL(weiboURL) else {
            throw ChekinanaEventCandidateClientError.invalidURL
        }
        return try await perform(
            request: Self.makeRequest(endpointURL: try resolvedEndpoint(), weiboURL: weiboURL),
            expectedWeiboURL: weiboURL
        )
    }

    func parse(text: String) async throws -> ChekinanaEventCandidateFields {
        try Self.validateText(text)
        return try await perform(
            request: Self.makeTextRequest(endpointURL: try resolvedEndpoint(), text: text),
            expectedWeiboURL: nil
        )
    }

    private func resolvedEndpoint() throws -> URL {
        guard let endpointURL else {
            throw ChekinanaEventCandidateClientError.invalidServiceConfiguration
        }
        return endpointURL
    }

    private func perform(
        request: URLRequest,
        expectedWeiboURL: String?
    ) async throws -> ChekinanaEventCandidateFields {
#if DEBUG
        switch ProcessInfo.processInfo.environment["CHEKINANA_EVENT_CANDIDATE_UI_STUB"] {
        case "fixture":
            return .init(
                name: expectedWeiboURL == nil ? "Fixture Text Live" : "Fixture Live",
                date: expectedWeiboURL == nil ? "2026-08-03" : "",
                city: "上海",
                livehouse: "Fixture Livehouse 中大二号馆",
                avatarURL: expectedWeiboURL == nil
                    ? ""
                    : "https://wx1.sinaimg.cn/large/fixture-avatar.jpg",
                weiboURL: expectedWeiboURL ?? "",
                ticketURL: "https://showstart.com/event/fixture",
                note: expectedWeiboURL == nil ? "Parsed from pasted text" : ""
            )
        case "address_fixture":
            return .init(
                name: "Address Fixture",
                date: "2026-08-02",
                city: "北京",
                livehouse: "北京市朝阳区幸福路一百号",
                weiboURL: expectedWeiboURL ?? "",
                ticketURL: "",
                note: ""
            )
        case "hang":
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw ChekinanaEventCandidateClientError.timedOut
        case "reject":
            throw ChekinanaEventCandidateClientError.rejected("status_unavailable")
        default:
            break
        }
#endif
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ChekinanaEventCandidateClientError.invalidResponse
            }
            guard http.mimeType?.lowercased() == "application/json" else {
                throw ChekinanaEventCandidateClientError.invalidResponse
            }
            var data = Data()
            data.reserveCapacity(min(http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 0, Self.maximumResponseBytes))
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else {
                    throw ChekinanaEventCandidateClientError.responseTooLarge
                }
                data.append(byte)
            }
            if http.statusCode == 200 {
                let candidate = try Self.decodeSuccess(data)
                let matchesInputMode = expectedWeiboURL.map {
                    candidate.weiboURL == $0
                } ?? candidate.weiboURL.isEmpty
                guard matchesInputMode else {
                    throw ChekinanaEventCandidateClientError.invalidResponse
                }
                var normalized = candidate
                if expectedWeiboURL == nil {
                    normalized.avatarURL = ""
                }
                // Model/source prose must never become the user's Event note.
                normalized.note = ""
                return normalized
            }
            throw Self.decodeReject(data)
        } catch let error as ChekinanaEventCandidateClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ChekinanaEventCandidateClientError.timedOut
        } catch let error as NSError
            where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            throw CancellationError()
        } catch {
            throw ChekinanaEventCandidateClientError.networkUnavailable
        }
    }

    static func makeRequest(endpointURL: URL, weiboURL: String) throws -> URLRequest {
        guard ChekinanaEventCandidateValidator.isPublicWeiboStatusURL(weiboURL) else {
            throw ChekinanaEventCandidateClientError.invalidURL
        }
        return try makeRequest(endpointURL: endpointURL, key: "weiboURL", value: weiboURL)
    }

    static func makeTextRequest(endpointURL: URL, text: String) throws -> URLRequest {
        try validateText(text)
        let request = try makeRequest(endpointURL: endpointURL, key: "text", value: text)
        guard let body = request.httpBody,
              body.count <= maximumRequestBytes else {
            throw ChekinanaEventCandidateClientError.textTooLarge
        }
        return request
    }

    private static func makeRequest(
        endpointURL: URL,
        key: String,
        value: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            key: value,
        ])
        return request
    }

    static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChekinanaEventCandidateClientError.emptyText
        }
        guard text.utf8.count <= maximumTextBytes else {
            throw ChekinanaEventCandidateClientError.textTooLarge
        }
        let hasUnsupportedControl = text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                || (0x7F...0x9F).contains(value)
        }
        guard !hasUnsupportedControl else {
            throw ChekinanaEventCandidateClientError.invalidTextCharacters
        }
    }

    static func decodeSuccess(_ data: Data) throws -> ChekinanaEventCandidateFields {
        guard data.count <= maximumResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              Set(root.keys) == Set(["version", "kind", "candidate"]),
              root["version"] as? Int == 1,
              root["kind"] as? String == "candidate",
              let candidate = root["candidate"] as? [String: Any] else {
            throw ChekinanaEventCandidateClientError.invalidResponse
        }
        return try ChekinanaEventCandidateFields(strictDictionary: candidate)
    }

    static func decodeReject(_ data: Data) -> ChekinanaEventCandidateClientError {
        guard data.count <= maximumResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              Set(root.keys) == Set(["version", "kind", "code"]),
              root["version"] as? Int == 1,
              root["kind"] as? String == "reject",
              let rawCode = root["code"] as? String else {
            return .invalidResponse
        }
        let code = rawCode.lowercased()
        guard code.range(of: #"^[a-z0-9_]{1,64}$"#, options: .regularExpression) != nil else {
            return .invalidResponse
        }
        return .rejected(code)
    }

    private static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary =
            ChekinanaCatalogueNetworkPolicy.directConnectionProxyDictionary()
        return URLSession(configuration: configuration)
    }

    private static func endpoint(
        from resolution: ChekinanaScannerBaseURLResolution
    ) -> URL? {
        guard case .resolved(let baseURL) = resolution else { return nil }
        return baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("event")
            .appendingPathComponent("weibo-candidate")
    }
}

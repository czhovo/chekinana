import Foundation

struct ChekinanaEventCandidateFields: Equatable, Sendable {
    var name: String
    var date: String
    var city: String
    var livehouse: String
    var weiboURL: String
    var ticketURL: String
    var note: String

    static let keys: Set<String> = [
        "name", "date", "city", "livehouse", "weiboURL", "ticketURL", "note",
    ]

    init(
        name: String,
        date: String,
        city: String,
        livehouse: String,
        weiboURL: String,
        ticketURL: String,
        note: String
    ) {
        self.name = name
        self.date = date
        self.city = city
        self.livehouse = livehouse
        self.weiboURL = weiboURL
        self.ticketURL = ticketURL
        self.note = note
    }

    init(strictDictionary: [String: Any]) throws {
        guard Set(strictDictionary.keys) == Self.keys else {
            throw ChekinanaEventCandidateClientError.invalidResponse
        }
        func requiredString(_ key: String) throws -> String {
            guard let value = strictDictionary[key] as? String else {
                throw ChekinanaEventCandidateClientError.invalidResponse
            }
            return value
        }
        self.init(
            name: try requiredString("name"),
            date: try requiredString("date"),
            city: try requiredString("city"),
            livehouse: try requiredString("livehouse"),
            weiboURL: try requiredString("weiboURL"),
            ticketURL: try requiredString("ticketURL"),
            note: try requiredString("note")
        )
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
            "活动名称不能为空。"
        case .invalidDate:
            "日期请使用 YYYY-MM-DD，或留空表示未确定日期。"
        case .invalidWeiboURL:
            "微博链接必须是公开的 https://weibo.com 或 https://www.weibo.com 状态链接。"
        case .invalidTicketURL:
            "票务链接必须使用受信任票务域名的 HTTPS URL，或留空。"
        case .livehouseLooksLikeAddress:
            "场地疑似包含道路或门牌地址；请改成纯场地名称，或清空。"
        case .fieldTooLong(let field):
            "\(field) 内容过长，请缩短后再确认。"
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
        if !isPublicWeiboStatusURL(fields.weiboURL) {
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
            ("名称", fields.name, 200),
            ("城市", fields.city, 100),
            ("场地", fields.livehouse, 300),
            ("微博链接", fields.weiboURL, 2_048),
            ("票务链接", fields.ticketURL, 2_048),
            ("备注", fields.note, 2_000),
        ] where value.utf8.count > limit {
            blockers.append(.fieldTooLong(field))
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
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
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

enum ChekinanaEventCandidateClientError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case responseTooLarge
    case timedOut
    case networkUnavailable
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "请输入公开的 Weibo 状态链接。"
        case .invalidResponse:
            "Event 提取服务返回了无法安全解析的内容。"
        case .responseTooLarge:
            "Event 提取服务返回的数据过大，已拒绝处理。"
        case .timedOut:
            "Event 提取超时，请稍后手动重试。"
        case .networkUnavailable:
            "当前无法连接 Event 提取服务，请检查网络后重试。"
        case .rejected(let code):
            switch code {
            case "invalid_request", "invalid_weibo_url":
                "该链接不是可处理的公开 Weibo 状态链接。"
            case "status_unavailable", "not_found":
                "无法读取这条公开 Weibo 状态。"
            case "upstream_timeout":
                "读取 Weibo 状态超时，请稍后重试。"
            case "rate_limited":
                "请求过于频繁，请稍后重试。"
            default:
                "Event 提取失败（\(code)），请稍后重试。"
            }
        }
    }
}

struct ChekinanaEventCandidateClient {
    private static let endpoint = URL(string: "https://api.chekinana.top/api/event/weibo-candidate")!
    private static let maximumResponseBytes = 64 * 1_024
    private let session: URLSession

    init(session: URLSession = Self.ephemeralSession()) {
        self.session = session
    }

    func fetch(weiboURL: String) async throws -> ChekinanaEventCandidateFields {
        guard ChekinanaEventCandidateValidator.isPublicWeiboStatusURL(weiboURL) else {
            throw ChekinanaEventCandidateClientError.invalidURL
        }
#if DEBUG
        switch ProcessInfo.processInfo.environment["CHEKINANA_EVENT_CANDIDATE_UI_STUB"] {
        case "fixture":
            return .init(
                name: "Fixture Live",
                date: "",
                city: "上海",
                livehouse: "Fixture Livehouse 中大二号馆",
                weiboURL: weiboURL,
                ticketURL: "https://showstart.com/event/fixture",
                note: ""
            )
        case "address_fixture":
            return .init(
                name: "Address Fixture",
                date: "2026-08-02",
                city: "北京",
                livehouse: "北京市朝阳区幸福路一百号",
                weiboURL: weiboURL,
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
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "weiboURL": weiboURL,
        ])

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
                guard candidate.weiboURL == weiboURL else {
                    throw ChekinanaEventCandidateClientError.invalidResponse
                }
                return candidate
            }
            throw Self.decodeReject(data)
        } catch let error as ChekinanaEventCandidateClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ChekinanaEventCandidateClientError.timedOut
        } catch {
            throw ChekinanaEventCandidateClientError.networkUnavailable
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
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

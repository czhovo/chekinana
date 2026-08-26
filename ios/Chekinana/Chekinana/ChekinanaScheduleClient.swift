import Foundation

struct ChekinanaScheduleStop: Equatable, Sendable {
    let name: String
    let arrival: Date?
    let departure: Date?
    let arrivalTimeZone: TimeZone?
    let departureTimeZone: TimeZone?

    init(
        name: String,
        arrival: Date?,
        departure: Date?,
        arrivalTimeZone: TimeZone? = nil,
        departureTimeZone: TimeZone? = nil
    ) {
        self.name = name
        self.arrival = arrival
        self.departure = departure
        self.arrivalTimeZone = arrivalTimeZone
        self.departureTimeZone = departureTimeZone
    }
}

struct ChekinanaScheduleResult: Equatable, Sendable {
    let operatorCode: String
    let stops: [ChekinanaScheduleStop]
}

struct ChekinanaScheduleRequestSignature: Equatable, Hashable, Sendable {
    let mode: ChekinanaTravelMode
    let serviceNumber: String
    let dateString: String

    init(
        mode: ChekinanaTravelMode,
        serviceNumber: String,
        date: Date,
        timeZone: TimeZone = .current
    ) {
        self.mode = mode
        self.serviceNumber = Self.normalizedServiceNumber(serviceNumber)
        dateString = Self.dateString(date, timeZone: timeZone)
    }

    static func normalizedServiceNumber(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct ChekinanaScheduleHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

enum ChekinanaScheduleClientError: LocalizedError, Equatable {
    case missingQuery
    case invalidRequest
    case notFound
    case upstreamUnavailable
    case invalidSchedule
    case network

    var errorDescription: String? {
        switch self {
        case .missingQuery:
            ChekinanaProductCopy.text(
                "travel.schedule.error.missing_query",
                "Enter a date and service number before looking up the schedule."
            )
        case .invalidRequest:
            ChekinanaProductCopy.text(
                "travel.schedule.error.invalid_request",
                "That service number or date is not valid."
            )
        case .notFound:
            ChekinanaProductCopy.text(
                "travel.schedule.error.not_found",
                "No schedule was found. Check the service number and date, then try again."
            )
        case .upstreamUnavailable:
            ChekinanaProductCopy.text(
                "travel.schedule.error.unavailable",
                "Schedule lookup is temporarily unavailable. Please try again."
            )
        case .invalidSchedule:
            ChekinanaProductCopy.text(
                "travel.schedule.error.invalid_response",
                "The returned schedule is incomplete and cannot be used."
            )
        case .network:
            ChekinanaProductCopy.text(
                "travel.schedule.error.network",
                "The schedule could not be loaded. Check your connection and try again."
            )
        }
    }
}

actor ChekinanaScheduleClient {
    typealias Transport = @Sendable (URLRequest) async throws -> ChekinanaScheduleHTTPResponse

    private struct ResponseDTO: Decodable {
        struct StopDTO: Decodable {
            let name: String
            let arrival: String?
            let departure: String?
        }

        let `operator`: String
        let stops: [StopDTO]
    }

    private struct ErrorDTO: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }

    private let transport: Transport
    private var activeTask: Task<ChekinanaScheduleHTTPResponse, Error>?
    private var activeToken: UUID?

    init(transport: @escaping Transport = ChekinanaScheduleClient.liveTransport) {
        self.transport = transport
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeToken = nil
    }

    func schedule(
        mode: ChekinanaTravelMode,
        serviceNumber: String,
        date: Date,
        timeZone: TimeZone = .current
    ) async throws -> ChekinanaScheduleResult {
        let signature = ChekinanaScheduleRequestSignature(
            mode: mode,
            serviceNumber: serviceNumber,
            date: date,
            timeZone: timeZone
        )
        guard !signature.serviceNumber.isEmpty else {
            throw ChekinanaScheduleClientError.missingQuery
        }
        let request = try Self.request(for: signature)
        activeTask?.cancel()
        let token = UUID()
        let transport = transport
        let task = Task { try await transport(request) }
        activeTask = task
        activeToken = token
        defer {
            if activeToken == token {
                activeTask = nil
                activeToken = nil
            }
        }
        do {
            let response: ChekinanaScheduleHTTPResponse
            do {
                response = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch {
                guard activeToken == token else {
                    throw CancellationError()
                }
                throw error
            }
            guard activeToken == token else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return try Self.decode(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ChekinanaScheduleClientError {
            throw error
        } catch {
            throw ChekinanaScheduleClientError.network
        }
    }

    static func request(for signature: ChekinanaScheduleRequestSignature) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.chekinana.top"
        components.path = "/api/v1/schedule"
        components.queryItems = [
            URLQueryItem(name: "type", value: signature.mode.rawValue.lowercased()),
            URLQueryItem(name: "code", value: signature.serviceNumber),
            URLQueryItem(name: "date", value: signature.dateString),
        ]
        guard let url = components.url else {
            throw ChekinanaScheduleClientError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func decode(_ response: ChekinanaScheduleHTTPResponse) throws -> ChekinanaScheduleResult {
        guard response.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(ErrorDTO.self, from: response.data))?
                .error.code.lowercased()
            switch (response.statusCode, code) {
            case (400, _), (_, "invalid_request"), (_, "invalid_type"),
                 (_, "invalid_code"), (_, "invalid_date"):
                throw ChekinanaScheduleClientError.invalidRequest
            case (404, _), (_, "not_found"):
                throw ChekinanaScheduleClientError.notFound
            default:
                throw ChekinanaScheduleClientError.upstreamUnavailable
            }
        }
        guard let decoded = try? JSONDecoder().decode(ResponseDTO.self, from: response.data),
              decoded.stops.count >= 2 else {
            throw ChekinanaScheduleClientError.invalidSchedule
        }
        let stops = try decoded.stops.map { raw -> ChekinanaScheduleStop in
            guard let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
                throw ChekinanaScheduleClientError.invalidSchedule
            }
            let arrival = try Self.parseOptionalTimestamp(raw.arrival)
            let departure = try Self.parseOptionalTimestamp(raw.departure)
            if let arrival, let departure, departure.date < arrival.date {
                throw ChekinanaScheduleClientError.invalidSchedule
            }
            return ChekinanaScheduleStop(
                name: name,
                arrival: arrival?.date,
                departure: departure?.date,
                arrivalTimeZone: arrival?.timeZone,
                departureTimeZone: departure?.timeZone
            )
        }
        guard stops[0].departure != nil, stops[stops.count - 1].arrival != nil else {
            throw ChekinanaScheduleClientError.invalidSchedule
        }
        var previousBoundary: Date?
        for stop in stops {
            if let arrival = stop.arrival {
                if let previousBoundary, arrival < previousBoundary {
                    throw ChekinanaScheduleClientError.invalidSchedule
                }
                previousBoundary = arrival
            }
            if let departure = stop.departure {
                if let previousBoundary, departure < previousBoundary {
                    throw ChekinanaScheduleClientError.invalidSchedule
                }
                previousBoundary = departure
            }
        }
        return ChekinanaScheduleResult(
            operatorCode: decoded.operator.trimmingCharacters(in: .whitespacesAndNewlines),
            stops: stops
        )
    }

    private static func parseOptionalTimestamp(
        _ raw: String?
    ) throws -> (date: Date, timeZone: TimeZone)? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return (date, try timeZone(from: raw))
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) else {
            throw ChekinanaScheduleClientError.invalidSchedule
        }
        return (date, try timeZone(from: raw))
    }

    private static func timeZone(from raw: String) throws -> TimeZone {
        if raw.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0)! }
        let pattern = #"([+-])(\d{2}):(\d{2})$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: raw,
                  range: NSRange(raw.startIndex..., in: raw)
              ),
              let signRange = Range(match.range(at: 1), in: raw),
              let hourRange = Range(match.range(at: 2), in: raw),
              let minuteRange = Range(match.range(at: 3), in: raw),
              let hours = Int(raw[hourRange]),
              let minutes = Int(raw[minuteRange]),
              hours <= 23,
              minutes <= 59 else {
            throw ChekinanaScheduleClientError.invalidSchedule
        }
        let sign = raw[signRange] == "+" ? 1 : -1
        guard let zone = TimeZone(
            secondsFromGMT: sign * ((hours * 60 + minutes) * 60)
        ) else {
            throw ChekinanaScheduleClientError.invalidSchedule
        }
        return zone
    }

    private static let liveTransport: Transport = { request in
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ChekinanaScheduleClientError.network
            }
            return ChekinanaScheduleHTTPResponse(
                data: data,
                statusCode: http.statusCode
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChekinanaScheduleClientError.network
        }
    }
}

struct ChekinanaTravelResolvedRoute: Equatable, Sendable {
    let departureLocation: String
    let arrivalLocation: String
    let departureTime: Date
    let arrivalTime: Date
}

enum ChekinanaTravelRouteSelectionPolicy {
    static func automaticSelection(for result: ChekinanaScheduleResult) -> (Int, Int)? {
        result.stops.count == 2 ? (0, 1) : nil
    }

    static func resolvedRoute(
        result: ChekinanaScheduleResult,
        originIndex: Int?,
        destinationIndex: Int?
    ) -> ChekinanaTravelResolvedRoute? {
        guard let originIndex,
              let destinationIndex,
              result.stops.indices.contains(originIndex),
              result.stops.indices.contains(destinationIndex),
              destinationIndex > originIndex,
              let departure = result.stops[originIndex].departure,
              let arrival = result.stops[destinationIndex].arrival,
              arrival >= departure else {
            return nil
        }
        return ChekinanaTravelResolvedRoute(
            departureLocation: result.stops[originIndex].name,
            arrivalLocation: result.stops[destinationIndex].name,
            departureTime: departure,
            arrivalTime: arrival
        )
    }
}

struct ChekinanaTravelStopSelection: Equatable, Sendable {
    let originIndex: Int?
    let destinationIndex: Int?
}

enum ChekinanaTravelStopTapSelectionPolicy {
    static func isSelectable(
        _ index: Int,
        in result: ChekinanaScheduleResult,
        selection: ChekinanaTravelStopSelection
    ) -> Bool {
        guard result.stops.indices.contains(index),
              result.stops.count > 2 else { return false }
        if selection.originIndex == index || selection.destinationIndex == index {
            return true
        }
        if let first = selection.originIndex,
           selection.destinationIndex == nil {
            let lower = min(first, index)
            let upper = max(first, index)
            return result.stops[lower].departure != nil
                && result.stops[upper].arrival != nil
        }
        let canStart = result.stops[index].departure != nil
            && result.stops.indices.contains {
                $0 > index && result.stops[$0].arrival != nil
            }
        let canEnd = result.stops[index].arrival != nil
            && result.stops.indices.contains {
                $0 < index && result.stops[$0].departure != nil
            }
        return canStart || canEnd
    }

    static func selection(
        afterTapping index: Int,
        in result: ChekinanaScheduleResult,
        current: ChekinanaTravelStopSelection
    ) -> ChekinanaTravelStopSelection {
        guard isSelectable(index, in: result, selection: current) else {
            return current
        }
        if let origin = current.originIndex,
           let destination = current.destinationIndex {
            if index == origin {
                return .init(originIndex: destination, destinationIndex: nil)
            }
            if index == destination {
                return .init(originIndex: origin, destinationIndex: nil)
            }
            return .init(originIndex: index, destinationIndex: nil)
        }
        guard let first = current.originIndex else {
            return .init(originIndex: index, destinationIndex: nil)
        }
        guard index != first else {
            return .init(originIndex: nil, destinationIndex: nil)
        }
        return .init(
            originIndex: min(first, index),
            destinationIndex: max(first, index)
        )
    }
}

enum ChekinanaTravelIconPickerPolicy {
    static func selectedData(
        afterPickerResult candidate: Data?,
        current: Data?
    ) -> Data? {
        candidate ?? current
    }
}

enum ChekinanaTravelOperatorIcon {
    static let prefix = "asset://"
    static let airlineCodes = Set([
        "3U", "6J", "7G", "8L", "9C", "BC", "BR", "CA", "CI", "CX",
        "CZ", "EU", "FM", "GJ", "GK", "GS", "HB", "HD", "HO", "HU",
        "HX", "IJ", "JD", "JL", "JX", "KN", "MF", "MM", "MU", "NH",
        "NX", "PN", "SC", "UO", "ZH",
    ])
    static let trainCodes = Set(["CR", "JR"])

    static func assetName(forOperatorCode value: String) -> String? {
        let code = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
        guard airlineCodes.contains(code) || trainCodes.contains(code) else { return nil }
        return "TravelOperator\(code)"
    }

    static func assetReference(forOperatorCode value: String) -> String? {
        assetName(forOperatorCode: value).map { prefix + $0 }
    }

    static func assetName(from reference: String?) -> String? {
        guard let reference, reference.hasPrefix(prefix) else { return nil }
        let name = String(reference.dropFirst(prefix.count))
        let allowed = airlineCodes.union(trainCodes).map { "TravelOperator\($0)" }
        return Set(allowed).contains(name) ? name : nil
    }
}

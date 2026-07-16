import Foundation

enum ChekinanaIdolEnrichmentError: LocalizedError {
    case invalidEndpoint
    case network(String)
    case httpStatus(Int)
    case invalidResponse
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "idol lookup failed: invalid API endpoint"
        case .network(let detail):
            "idol lookup network error: \(detail)"
        case .httpStatus(let statusCode):
            "idol lookup failed: HTTP \(statusCode)"
        case .invalidResponse:
            "idol lookup failed: invalid JSON response"
        case .notFound(let name):
            "idol not found: \(name)"
        }
    }
}

struct ChekinanaEnrichedIdol: Decodable {
    let sourceId: String
    let idolName: String
    let groupName: String?
    let color: String?
    let birthday: String?
    let verification: String?
    let bio: String?
    let avatarUrl: String?

    private enum CodingKeys: String, CodingKey {
        case sourceId = "id"
        case idolName
        case groupName
        case color
        case birthday
        case verification
        case bio
        case avatarUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSourceId = try container.decode(String.self, forKey: .sourceId)
        let normalizedSourceId = rawSourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSourceId.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceId,
                in: container,
                debugDescription: "Idol catalogue id must not be empty"
            )
        }
        sourceId = normalizedSourceId
        idolName = try container.decode(String.self, forKey: .idolName)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        birthday = try container.decodeIfPresent(String.self, forKey: .birthday)
        verification = try container.decodeIfPresent(String.self, forKey: .verification)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        avatarUrl = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
    }

    init(
        sourceId: String,
        idolName: String,
        groupName: String?,
        color: String?,
        birthday: String?,
        verification: String?,
        bio: String?,
        avatarUrl: String?
    ) {
        self.sourceId = sourceId
        self.idolName = idolName
        self.groupName = groupName
        self.color = color
        self.birthday = birthday
        self.verification = verification
        self.bio = bio
        self.avatarUrl = avatarUrl
    }
}

struct ChekinanaIdolEnrichmentClient {
    func search(for rawName: String) async throws -> [ChekinanaEnrichedIdol] {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
#if DEBUG
        let fixtureMode = ProcessInfo.processInfo.environment["CHEKINANA_IDOL_UI_STUB"]
        if fixtureMode == "fixture" || fixtureMode == "multi_fixture" {
            let sourceSuffix = name.unicodeScalars
                .map { String(format: "%04x", $0.value) }
                .joined(separator: "-")
            let first = ChekinanaEnrichedIdol(
                    sourceId: "ui-fixture-\(sourceSuffix)",
                    idolName: name,
                    groupName: "UI Fixture",
                    color: "#3366CC",
                    birthday: "2000-01-01",
                    verification: nil,
                    bio: nil,
                    avatarUrl: nil
                )
            guard fixtureMode == "multi_fixture" else { return [first] }
            return [
                first,
                ChekinanaEnrichedIdol(
                    sourceId: "ui-fixture-second-\(sourceSuffix)",
                    idolName: "\(name) Second",
                    groupName: "UI Fixture Two",
                    color: "#CC6633",
                    birthday: "2001-02-02",
                    verification: "fixture",
                    bio: "Second deterministic UI candidate",
                    avatarUrl: nil
                ),
            ]
        }
#endif
        var components = URLComponents(string: "https://idol.chekinana.top/api/search/idol")
        components?.queryItems = [
            URLQueryItem(name: "idolName", value: name),
            URLQueryItem(name: "limit", value: "200"),
        ]

        guard let url = components?.url else {
            throw ChekinanaIdolEnrichmentError.invalidEndpoint
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw ChekinanaIdolEnrichmentError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChekinanaIdolEnrichmentError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ChekinanaIdolEnrichmentError.httpStatus(httpResponse.statusCode)
        }

        let searchResponse: SearchResponse

        do {
            searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw ChekinanaIdolEnrichmentError.invalidResponse
        }

        guard !searchResponse.items.isEmpty else {
            throw ChekinanaIdolEnrichmentError.notFound(name)
        }

        return searchResponse.items
    }

    private struct SearchResponse: Decodable {
        let count: Int
        let items: [ChekinanaEnrichedIdol]
    }
}

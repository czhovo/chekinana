import CoreGraphics
@preconcurrency import CoreML
import CryptoKit
import Foundation
import ImageIO
#if !CHEKINANA_DINO_HOST_TOOL
import SwiftData
#endif
#if canImport(UIKit)
import UIKit
#endif

enum ChekinanaPatternEncoderError: LocalizedError {
    case invalidImage
    case modelUnavailable
    case invalidModelInput
    case invalidModelOutput
    case noValidCandidates

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            ChekinanaL10n.message("The Cheki image could not be read for Idol recognition.")
        case .modelUnavailable:
            ChekinanaL10n.message("The on-device Idol encoder is unavailable.")
        case .invalidModelInput:
            ChekinanaL10n.message("The on-device Idol encoder input is invalid.")
        case .invalidModelOutput:
            ChekinanaL10n.message("The on-device Idol encoder returned an invalid embedding.")
        case .noValidCandidates:
            ChekinanaL10n.message("No valid 256-dimensional pattern embedding is available for the candidate Idols.")
        }
    }
}

struct ChekinanaPatternCandidateSet: Equatable, Sendable {
    let idolIDs: [UUID]
    let includesUnassigned: Bool

    init(
        idolIDs: [UUID],
        includesUnassigned: Bool
    ) {
        var seen = Set<UUID>()
        self.idolIDs = idolIDs.filter { seen.insert($0).inserted }
        self.includesUnassigned = includesUnassigned
    }
}

struct ChekinanaPatternClassification: Equatable, Sendable {
    let idolID: UUID?
    let similarity: Float?
}

enum ChekinanaPatternClassifier {
    static let unassignedThreshold: Double = 0.6184226274
    static let embeddingDimension = 256

    static func assignsCandidate(
        similarity: Double,
        includesUnassigned: Bool
    ) -> Bool {
        !includesUnassigned || similarity >= unassignedThreshold
    }

    static func isValidEmbedding(_ values: [Float]?) -> Bool {
        guard let values, values.count == embeddingDimension else {
            return false
        }
        return values.allSatisfy(\.isFinite)
            && values.reduce(Float.zero) { $0 + $1 * $1 } > 0
    }

    static func classify(
        embedding: [Float],
        candidatePatterns: [(id: UUID, patterns: [[Float]])],
        includesUnassigned: Bool
    ) throws -> ChekinanaPatternClassification {
        guard isValidEmbedding(embedding) else {
            throw ChekinanaPatternEncoderError.invalidModelOutput
        }

        let inputNorm = sqrt(embedding.reduce(Float.zero) { $0 + $1 * $1 })
        let scores = candidatePatterns.compactMap { candidate -> (UUID, Float)? in
            let patternScores = candidate.patterns.compactMap { pattern -> Float? in
                guard isValidEmbedding(pattern) else { return nil }
                var dot: Float = 0
                var patternNormSquared: Float = 0
                for index in 0..<embeddingDimension {
                    dot += embedding[index] * pattern[index]
                    patternNormSquared += pattern[index] * pattern[index]
                }
                let denominator = inputNorm * sqrt(patternNormSquared)
                guard denominator.isFinite, denominator > 0 else { return nil }
                let score = dot / denominator
                return score.isFinite ? score : nil
            }
            guard let bestPatternScore = patternScores.max() else { return nil }
            return (candidate.id, bestPatternScore)
        }

        guard let best = scores.max(by: { $0.1 < $1.1 }) else {
            if includesUnassigned {
                return ChekinanaPatternClassification(idolID: nil, similarity: nil)
            }
            throw ChekinanaPatternEncoderError.noValidCandidates
        }
        if !assignsCandidate(
            similarity: Double(best.1),
            includesUnassigned: includesUnassigned
        ) {
            return ChekinanaPatternClassification(idolID: nil, similarity: best.1)
        }
        return ChekinanaPatternClassification(idolID: best.0, similarity: best.1)
    }
}

enum ChekinanaPatternContract {
    static let encoderVersion = "pattern-6541-v1"
    static let resourceRevision = "catalogue-b462a208c0d75264"
    static let encoderCheckpointSHA256 =
        "fe5bcb95f15836ab8d664398ee7acede0fb700ce3ac85ffa0d60adf356a2fb01"
    static let prototypeFormat = "pattern_prototype_bank_v1"
    static let mappingFormat = "idol_pattern_map_v1"
    static let patternCount = 95
    static let embeddingDimension = 256
    static let manifestURL = URL(string:
        "https://idol.chekinana.top/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/manifest.json"
    )!
    static let prototypesURL = URL(string:
        "https://idol.chekinana.top/assets/pattern-recognition/v1/prototypes.json"
    )!
    static let idolPatternMapURL = URL(string:
        "https://idol.chekinana.top/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/idol-pattern-map.json"
    )!

    static func validatedResourceCacheDirectory(baseDirectory: URL) -> URL {
        baseDirectory
            .appendingPathComponent("Chekinana", isDirectory: true)
            .appendingPathComponent("PatternRecognition", isDirectory: true)
            .appendingPathComponent(encoderVersion, isDirectory: true)
            .appendingPathComponent(resourceRevision, isDirectory: true)
    }
}

enum ChekinanaPatternVectors {
    static func mergedPatterns(_ groups: [[[Float]]]) -> [[Float]] {
        var result: [[Float]] = []
        for pattern in groups.flatMap({ $0 })
        where ChekinanaPatternClassifier.isValidEmbedding(pattern) && !result.contains(pattern) {
            result.append(pattern)
        }
        return result
    }
}

struct ChekinanaPatternEncodingResult: Equatable, Sendable {
    let raw: [Float]
    let normalized: [Float]
}

#if DEBUG
enum ChekinanaDINOFloat32Encoding {
    static let dtype = "float32"
    static let byteOrder = "little-endian"

    static func data(_ values: [Float]) -> Data {
        var result = Data(capacity: values.count * MemoryLayout<UInt32>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
        }
        return result
    }
}
#endif

#if DEBUG && CHEKINANA_DINO_DEBUG_CAPTURE
private actor ChekinanaDINODebugCaptureStore {
    static let shared = ChekinanaDINODebugCaptureStore()

    private struct Manifest: Codable {
        let format: String
        let session: String
        let createdAt: String
        let encoderVersion: String
        let modelResource: String
        let computeUnits: String
        let vectorDType: String
        let vectorByteOrder: String
        var entries: [Entry]
    }

    private struct Entry: Codable {
        let sequence: Int
        let capturedAt: String
        let inputFile: String
        let inputFormat: String
        let inputWidth: Int?
        let inputHeight: Int?
        let rawVectorFile: String
        let normalizedVectorFile: String
        let dimension: Int
        let rawNorm: Float
        let normalizedNorm: Float
        let rawIsFinite: Bool
        let normalizedIsFinite: Bool
    }

    private let directory: URL?
    private var manifest: Manifest
    private var nextSequence = 1

    init(fileManager: FileManager = .default) {
        let timestamp = Self.timestamp(Date())
            .replacingOccurrences(of: ":", with: "-")
        let session = "session-\(timestamp)-\(UUID().uuidString.lowercased())"
        manifest = Manifest(
            format: "chekinana_dino_debug_capture_v1",
            session: session,
            createdAt: Self.timestamp(Date()),
            encoderVersion: ChekinanaPatternContract.encoderVersion,
            modelResource: "ChekiPatternEncoder.mlmodelc",
            computeUnits: "all",
            vectorDType: ChekinanaDINOFloat32Encoding.dtype,
            vectorByteOrder: ChekinanaDINOFloat32Encoding.byteOrder,
            entries: []
        )
        do {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base
                .appendingPathComponent("Chekinana", isDirectory: true)
                .appendingPathComponent("DINO-Debug-Capture", isDirectory: true)
                .appendingPathComponent(session, isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(resourceValues)
            self.directory = directory
        } catch {
            directory = nil
        }
    }

    func capture(
        imageData: Data,
        raw: [Float],
        normalized: [Float]
    ) {
        guard let directory else { return }
        let sequence = nextSequence
        nextSequence += 1
        let stem = String(format: "%06d", sequence)
        let imageMetadata = Self.imageMetadata(imageData)
        let inputFile = "\(stem)-input.\(imageMetadata.extension)"
        let rawFile = "\(stem)-raw.f32"
        let normalizedFile = "\(stem)-normalized.f32"
        do {
            try imageData.write(
                to: directory.appendingPathComponent(inputFile),
                options: .atomic
            )
            try ChekinanaDINOFloat32Encoding.data(raw).write(
                to: directory.appendingPathComponent(rawFile),
                options: .atomic
            )
            try ChekinanaDINOFloat32Encoding.data(normalized).write(
                to: directory.appendingPathComponent(normalizedFile),
                options: .atomic
            )
            manifest.entries.append(Entry(
                sequence: sequence,
                capturedAt: Self.timestamp(Date()),
                inputFile: inputFile,
                inputFormat: imageMetadata.format,
                inputWidth: imageMetadata.width,
                inputHeight: imageMetadata.height,
                rawVectorFile: rawFile,
                normalizedVectorFile: normalizedFile,
                dimension: raw.count,
                rawNorm: Self.norm(raw),
                normalizedNorm: Self.norm(normalized),
                rawIsFinite: raw.allSatisfy(\.isFinite),
                normalizedIsFinite: normalized.allSatisfy(\.isFinite)
            ))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: directory.appendingPathComponent("manifest.json"),
                options: .atomic
            )
        } catch {
            // Diagnostics must never affect classification or surface user UI.
        }
    }

    private static func imageMetadata(
        _ data: Data
    ) -> (format: String, extension: String, width: Int?, height: Int?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return ("application/octet-stream", "bin", nil, nil)
        }
        let format = (CGImageSourceGetType(source) as String?)
            ?? "application/octet-stream"
        let fileExtension: String
        if format.localizedCaseInsensitiveContains("jpeg") {
            fileExtension = "jpg"
        } else if format.localizedCaseInsensitiveContains("png") {
            fileExtension = "png"
        } else if format.localizedCaseInsensitiveContains("heic")
                    || format.localizedCaseInsensitiveContains("heif") {
            fileExtension = "heic"
        } else {
            fileExtension = "bin"
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        return (format, fileExtension, width, height)
    }

    private static func norm(_ values: [Float]) -> Float {
        sqrt(values.reduce(Float.zero) { $0 + $1 * $1 })
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
#endif

#if DEBUG
enum ChekinanaPatternDebugFixture {
    static func unitVector(_ index: Int) -> [Float] {
        var values = Array(
            repeating: Float.zero,
            count: ChekinanaPatternClassifier.embeddingDimension
        )
        values[max(0, min(index, values.count - 1))] = 1
        return values
    }
}
#endif

@MainActor
struct ChekinanaCataloguePatternSelectionState: Equatable {
    private(set) var sourceId: String?
    private(set) var patternIds: [String] = []
    private(set) var patterns: [[Float]] = []
    private(set) var isResolved = false

    mutating func select(
        sourceId: String,
        patternIds: [String],
        patterns: [[Float]]
    ) {
        self.sourceId = sourceId
        self.patternIds = patternIds
        self.patterns = patterns
        isResolved = true
    }

    mutating func clear() {
        sourceId = nil
        patternIds = []
        patterns = []
        isResolved = false
    }
}

enum ChekinanaPatternResourceError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case invalidManifest
    case invalidPrototypeBank
    case invalidIdolPatternMap
    case unknownPatternID(String)
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            ChekinanaL10n.message("Pattern resources returned an invalid response.")
        case .httpStatus(let status):
            ChekinanaL10n.message("Pattern resources returned HTTP \(status).")
        case .invalidManifest:
            ChekinanaL10n.message("Pattern resource manifest is incompatible with this app.")
        case .invalidPrototypeBank:
            ChekinanaL10n.message("Pattern prototype bank failed validation.")
        case .invalidIdolPatternMap:
            ChekinanaL10n.message("Idol pattern mapping failed validation.")
        case .unknownPatternID(let id):
            ChekinanaL10n.message("Unknown pattern ID: \(id)")
        case .cacheUnavailable:
            ChekinanaL10n.message("No validated pattern resource cache is available.")
        }
    }
}

enum ChekinanaPatternResourceIntegrity {
    static func normalizedSHA256(_ value: String) -> String? {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                    || (65...70).contains(byte)
                    || (97...102).contains(byte)
              }) else {
            return nil
        }
        return value.lowercased()
    }

    static func sha256Hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let digest = SHA256.hash(data: data)
        var bytes = [UInt8]()
        bytes.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func matches(_ data: Data, expectedSHA256: String) -> Bool {
        guard let expected = normalizedSHA256(expectedSHA256) else {
            return false
        }
        return sha256Hex(data) == expected
    }
}

struct ChekinanaPatternResourceEndpoints: Equatable, Sendable {
    let manifestURL: URL
    let prototypesURL: URL
    let idolPatternMapURL: URL

    static let production = ChekinanaPatternResourceEndpoints(
        manifestURL: ChekinanaPatternContract.manifestURL,
        prototypesURL: ChekinanaPatternContract.prototypesURL,
        idolPatternMapURL: ChekinanaPatternContract.idolPatternMapURL
    )
}

struct ChekinanaPatternResourceSnapshot: Sendable {
    let prototypesByID: [String: [Float]]
    let idolPatternIDs: [String: [String]]

    func patterns(for patternIDs: [String]) throws -> [[Float]] {
        var seen = Set<String>()
        return try patternIDs.map { rawID in
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  seen.insert(id).inserted,
                  let prototype = prototypesByID[id] else {
                throw ChekinanaPatternResourceError.unknownPatternID(rawID)
            }
            return prototype
        }
    }
}

private struct ChekinanaPatternResourceManifest: Decodable {
    struct ResourceDigest: Decodable {
        let sha256: String
    }

    let version: String
    let embeddingDimension: Int
    let patternCount: Int
    let encoderCheckpointSHA256: String
    let prototypesURL: URL
    let idolPatternMapURL: URL
    let prototypeBank: ResourceDigest
    let idolPatternMap: ResourceDigest

    private enum CodingKeys: String, CodingKey {
        case version
        case embeddingDimension
        case patternCount
        case encoderCheckpointSHA256
        case prototypesURL = "prototypesUrl"
        case idolPatternMapURL = "idolPatternMapUrl"
        case prototypeBank
        case idolPatternMap
    }
}

private struct ChekinanaPatternPrototypeBank: Decodable {
    let format: String
    let encoderCheckpointSHA256: String
    let embeddingDimension: Int
    let patternIDs: [String]
    let prototypes: [[Float]]

    private enum CodingKeys: String, CodingKey {
        case format
        case encoderCheckpointSHA256 = "encoder_checkpoint_sha256"
        case embeddingDimension = "embedding_dim"
        case patternIDs = "pattern_ids"
        case prototypes
    }
}

private struct ChekinanaIdolPatternMap: Decodable {
    let format: String
    let version: String
    let idolPatternIDs: [String: [String]]
}

actor ChekinanaRemotePatternResources {
    typealias CacheWriter = @Sendable (Data, URL) throws -> Void

    static let shared = ChekinanaRemotePatternResources()

    private let endpoints: ChekinanaPatternResourceEndpoints
    private let session: URLSession
    private let cacheDirectory: URL
    private let cacheWriter: CacheWriter
    private var loadedSnapshot: ChekinanaPatternResourceSnapshot?

    init(
        endpoints: ChekinanaPatternResourceEndpoints = .production,
        session: URLSession = .shared,
        cacheDirectory: URL? = nil,
        cacheWriter: @escaping CacheWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.endpoints = endpoints
        self.session = session
        self.cacheWriter = cacheWriter
        self.cacheDirectory = cacheDirectory
            ?? ChekinanaPatternContract.validatedResourceCacheDirectory(
                baseDirectory: FileManager.default
                    .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            )
    }

    /// Local startup/recognition must not initiate or wait for remote fetching.
    func cachedSnapshot() throws -> ChekinanaPatternResourceSnapshot {
        if let loadedSnapshot { return loadedSnapshot }
        let cached = try loadCachedSnapshot()
        loadedSnapshot = cached
        return cached
    }

    func snapshot() async throws -> ChekinanaPatternResourceSnapshot {
        if let loadedSnapshot { return loadedSnapshot }
        do {
            let loaded = try await loadNetworkSnapshot()
            try writeCache(loaded.rawData)
            loadedSnapshot = loaded.snapshot
            return loaded.snapshot
        } catch {
            let networkError = error
            do {
                let cached = try loadCachedSnapshot()
                loadedSnapshot = cached
                return cached
            } catch let cacheError as ChekinanaPatternResourceError {
                guard cacheError == .cacheUnavailable else {
                    throw cacheError
                }
                throw networkError
            }
        }
    }

    func patterns(for patternIDs: [String]) async throws -> [[Float]] {
        guard !patternIDs.isEmpty else { return [] }
        return try await snapshot().patterns(for: patternIDs)
    }

    private struct RawResourceData: Codable {
        let manifest: Data
        let prototypes: Data
        let idolPatternMap: Data
    }

    private struct LoadedResources {
        let snapshot: ChekinanaPatternResourceSnapshot
        let rawData: RawResourceData
    }

    private func loadNetworkSnapshot() async throws -> LoadedResources {
        let manifestData = try await fetch(endpoints.manifestURL)
        let manifest = try decodeManifest(manifestData)
        async let prototypesData = fetch(manifest.prototypesURL)
        async let idolPatternMapData = fetch(manifest.idolPatternMapURL)
        let raw = try await RawResourceData(
            manifest: manifestData,
            prototypes: prototypesData,
            idolPatternMap: idolPatternMapData
        )
        return try LoadedResources(
            snapshot: decodeSnapshot(
                manifest: manifest,
                prototypesData: raw.prototypes,
                idolPatternMapData: raw.idolPatternMap
            ),
            rawData: raw
        )
    }

    private func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw ChekinanaPatternResourceError.invalidManifest
        }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw ChekinanaPatternResourceError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw ChekinanaPatternResourceError.httpStatus(response.statusCode)
        }
        return data
    }

    private func decodeManifest(_ data: Data) throws -> ChekinanaPatternResourceManifest {
        guard let manifest = try? JSONDecoder().decode(
            ChekinanaPatternResourceManifest.self,
            from: data
        ), manifest.version == ChekinanaPatternContract.encoderVersion,
           manifest.embeddingDimension == ChekinanaPatternContract.embeddingDimension,
           manifest.patternCount == ChekinanaPatternContract.patternCount,
           manifest.encoderCheckpointSHA256.lowercased()
            == ChekinanaPatternContract.encoderCheckpointSHA256,
           manifest.prototypesURL.scheme?.lowercased() == "https",
           manifest.idolPatternMapURL.scheme?.lowercased() == "https",
           manifest.prototypesURL == endpoints.prototypesURL,
           manifest.idolPatternMapURL == endpoints.idolPatternMapURL,
           ChekinanaPatternResourceIntegrity.normalizedSHA256(
               manifest.prototypeBank.sha256
           ) != nil,
           ChekinanaPatternResourceIntegrity.normalizedSHA256(
               manifest.idolPatternMap.sha256
           ) != nil else {
            throw ChekinanaPatternResourceError.invalidManifest
        }
        return manifest
    }

    private func decodeSnapshot(
        manifest: ChekinanaPatternResourceManifest,
        prototypesData: Data,
        idolPatternMapData: Data
    ) throws -> ChekinanaPatternResourceSnapshot {
        guard ChekinanaPatternResourceIntegrity.matches(
            prototypesData,
            expectedSHA256: manifest.prototypeBank.sha256
        ) else {
            throw ChekinanaPatternResourceError.invalidPrototypeBank
        }
        guard ChekinanaPatternResourceIntegrity.matches(
            idolPatternMapData,
            expectedSHA256: manifest.idolPatternMap.sha256
        ) else {
            throw ChekinanaPatternResourceError.invalidIdolPatternMap
        }
        guard let bank = try? JSONDecoder().decode(
            ChekinanaPatternPrototypeBank.self,
            from: prototypesData
        ), bank.format == ChekinanaPatternContract.prototypeFormat,
           bank.encoderCheckpointSHA256.lowercased()
            == ChekinanaPatternContract.encoderCheckpointSHA256,
           bank.encoderCheckpointSHA256.lowercased()
            == manifest.encoderCheckpointSHA256.lowercased(),
           bank.embeddingDimension == ChekinanaPatternContract.embeddingDimension,
           bank.patternIDs.count == ChekinanaPatternContract.patternCount,
           bank.prototypes.count == ChekinanaPatternContract.patternCount else {
            throw ChekinanaPatternResourceError.invalidPrototypeBank
        }
        var prototypesByID: [String: [Float]] = [:]
        prototypesByID.reserveCapacity(bank.patternIDs.count)
        for (rawID, vector) in zip(bank.patternIDs, bank.prototypes) {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
            guard !id.isEmpty,
                  prototypesByID[id] == nil,
                  vector.count == ChekinanaPatternContract.embeddingDimension,
                  vector.allSatisfy(\.isFinite),
                  norm.isFinite,
                  abs(norm - 1) <= 0.002 else {
                throw ChekinanaPatternResourceError.invalidPrototypeBank
            }
            prototypesByID[id] = vector
        }
        guard prototypesByID.count == ChekinanaPatternContract.patternCount,
              let mapping = try? JSONDecoder().decode(
                ChekinanaIdolPatternMap.self,
                from: idolPatternMapData
              ), mapping.format == ChekinanaPatternContract.mappingFormat,
              mapping.version == ChekinanaPatternContract.encoderVersion else {
            throw ChekinanaPatternResourceError.invalidIdolPatternMap
        }
        var normalizedMapping: [String: [String]] = [:]
        for (rawSourceID, rawPatternIDs) in mapping.idolPatternIDs {
            let sourceID = rawSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
            var seen = Set<String>()
            let patternIDs = try rawPatternIDs.map { rawPatternID in
                let patternID = rawPatternID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !patternID.isEmpty,
                      seen.insert(patternID).inserted,
                      prototypesByID[patternID] != nil else {
                    throw ChekinanaPatternResourceError.invalidIdolPatternMap
                }
                return patternID
            }
            guard !sourceID.isEmpty, normalizedMapping[sourceID] == nil else {
                throw ChekinanaPatternResourceError.invalidIdolPatternMap
            }
            normalizedMapping[sourceID] = patternIDs
        }
        return ChekinanaPatternResourceSnapshot(
            prototypesByID: prototypesByID,
            idolPatternIDs: normalizedMapping
        )
    }

    private func writeCache(_ rawData: RawResourceData) throws {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try cacheWriter(
            JSONEncoder().encode(rawData),
            cacheDirectory.appendingPathComponent("validated-resources.json")
        )
    }

    private func loadCachedSnapshot() throws -> ChekinanaPatternResourceSnapshot {
        guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent(
                  "validated-resources.json"
              )),
              let rawData = try? JSONDecoder().decode(RawResourceData.self, from: data)
        else {
            throw ChekinanaPatternResourceError.cacheUnavailable
        }
        let manifest = try decodeManifest(rawData.manifest)
        return try decodeSnapshot(
            manifest: manifest,
            prototypesData: rawData.prototypes,
            idolPatternMapData: rawData.idolPatternMap
        )
    }
}

#if !CHEKINANA_DINO_HOST_TOOL
@MainActor
enum ChekinanaIdolPatternPersistence {
    static let pendingVersion = "pending-\(ChekinanaPatternContract.encoderVersion)"
    static let migrationDefaultsKey = "chekinana.pattern-encoder.version"

    static func state(
        for idolID: UUID,
        in context: ModelContext
    ) throws -> IdolPatternState? {
        let predicate = #Predicate<IdolPatternState> { $0.idolID == idolID }
        var descriptor = FetchDescriptor<IdolPatternState>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @discardableResult
    static func replaceCataloguePatterns(
        for idol: Idol,
        patternIDs: [String],
        prototypes: [[Float]],
        customPatterns: [[Float]],
        in context: ModelContext
    ) throws -> IdolPatternState {
        let normalizedPatternIDs = patternIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalizedPatternIDs.count == prototypes.count,
              normalizedPatternIDs.allSatisfy({ !$0.isEmpty }),
              Set(normalizedPatternIDs).count == normalizedPatternIDs.count,
              prototypes.allSatisfy(ChekinanaPatternClassifier.isValidEmbedding),
              customPatterns.allSatisfy(ChekinanaPatternClassifier.isValidEmbedding) else {
            throw ChekinanaPatternResourceError.invalidPrototypeBank
        }
        let record = try state(for: idol.id, in: context) ?? IdolPatternState(
            idolID: idol.id,
            encoderVersion: ChekinanaPatternContract.encoderVersion
        )
        if record.modelContext == nil { context.insert(record) }
        let uniqueCustomPatterns = ChekinanaPatternVectors
            .mergedPatterns([customPatterns])
            .filter { !prototypes.contains($0) }
        idol.pattern = nil
        // Keep one leading vector per cloud ID even if two IDs happen to have
        // identical prototypes; the persisted count/ID order must stay aligned.
        idol.patterns = prototypes + uniqueCustomPatterns
        record.encoderVersion = ChekinanaPatternContract.encoderVersion
        record.cataloguePatternIDs = normalizedPatternIDs
        record.cataloguePatternCount = prototypes.count
        return record
    }

    static func splitEditedPatterns(
        _ editedPatterns: [[Float]],
        for idol: Idol,
        state: IdolPatternState?
    ) -> (
        cataloguePatternIDs: [String],
        cataloguePatterns: [[Float]],
        customPatterns: [[Float]]
    ) {
        guard let state,
              state.encoderVersion == ChekinanaPatternContract.encoderVersion,
              state.cataloguePatternCount == state.cataloguePatternIDs.count,
              state.cataloguePatternCount <= idol.patterns.count else {
            return ([], [], ChekinanaPatternVectors.mergedPatterns([editedPatterns]))
        }
        let oldCataloguePatterns = Array(idol.patterns.prefix(
            state.cataloguePatternCount
        ))
        var remaining = ChekinanaPatternVectors.mergedPatterns([editedPatterns])
        var keptIDs: [String] = []
        var keptPatterns: [[Float]] = []
        for (patternID, prototype) in zip(
            state.cataloguePatternIDs,
            oldCataloguePatterns
        ) {
            guard let index = remaining.firstIndex(of: prototype) else { continue }
            keptIDs.append(patternID)
            keptPatterns.append(prototype)
            remaining.remove(at: index)
        }
        return (keptIDs, keptPatterns, remaining)
    }

    static func discardIncompatiblePatternsIfNeeded(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws {
        try ChekinanaPersistenceMutationCoordinator.withLock {
            let requiresFullMigration = defaults.string(forKey: migrationDefaultsKey)
                != ChekinanaPatternContract.encoderVersion
            let idols = try context.fetch(FetchDescriptor<Idol>())
            let states = try context.fetch(FetchDescriptor<IdolPatternState>())
            let statesByIdolID = Dictionary(uniqueKeysWithValues: states.map {
                ($0.idolID, $0)
            })
            for idol in idols {
                let existingState = statesByIdolID[idol.id]
                guard requiresFullMigration
                        || existingState?.encoderVersion
                            != ChekinanaPatternContract.encoderVersion else {
                    continue
                }
                idol.pattern = nil
                idol.patterns = []
                let record = existingState ?? IdolPatternState(
                    idolID: idol.id,
                    encoderVersion: pendingVersion
                )
                if record.modelContext == nil { context.insert(record) }
                record.cataloguePatternIDs = []
                record.cataloguePatternCount = 0
                record.encoderVersion = idol.sourceId?.nonEmpty == nil
                    ? ChekinanaPatternContract.encoderVersion
                    : pendingVersion
            }
            if context.hasChanges { try context.save() }
            defaults.set(
                ChekinanaPatternContract.encoderVersion,
                forKey: migrationDefaultsKey
            )
        }
    }

    typealias SnapshotLoader = () async throws -> ChekinanaPatternResourceSnapshot

    private struct PendingRefresh {
        struct FieldSnapshot: Equatable {
            let legacyPattern: [Float]?
            let patterns: [[Float]]
            let updatedAt: Date
            let cataloguePatternIDs: [String]
            let cataloguePatternCount: Int
        }

        let stateIdentity: PersistentIdentifier
        let idolIdentity: PersistentIdentifier
        let idolID: UUID
        let sourceID: String
        let expectedPendingVersion: String
        let expectedResourceVersion: String
        let libraryGeneration: UUID
        let fields: FieldSnapshot
    }

    static func refreshPendingCataloguePatterns(
        in context: ModelContext,
        resources: ChekinanaRemotePatternResources = .shared,
        loadSnapshot: SnapshotLoader? = nil
    ) async throws {
        let container = context.container
        let pending = try ChekinanaPersistenceMutationCoordinator.withLock {
            let captureContext = ModelContext(container)
            captureContext.autosaveEnabled = false
            let pendingStates = try captureContext
                .fetch(FetchDescriptor<IdolPatternState>())
                .filter {
                    $0.encoderVersion != ChekinanaPatternContract.encoderVersion
                }
            guard !pendingStates.isEmpty else { return [PendingRefresh]() }
            let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(
                in: captureContext
            )
            let idolsByID = Dictionary(uniqueKeysWithValues:
                try captureContext.fetch(FetchDescriptor<Idol>()).map { ($0.id, $0) }
            )
            return pendingStates.compactMap { record in
                guard let idol = idolsByID[record.idolID],
                      let sourceID = idol.sourceId?.nonEmpty else {
                    return nil
                }
                return PendingRefresh(
                    stateIdentity: record.persistentModelID,
                    idolIdentity: idol.persistentModelID,
                    idolID: idol.id,
                    sourceID: sourceID,
                    expectedPendingVersion: record.encoderVersion,
                    expectedResourceVersion: ChekinanaPatternContract.encoderVersion,
                    libraryGeneration: generation,
                    fields: PendingRefresh.FieldSnapshot(
                        legacyPattern: idol.pattern,
                        patterns: idol.patterns,
                        updatedAt: idol.updatedAt,
                        cataloguePatternIDs: record.cataloguePatternIDs,
                        cataloguePatternCount: record.cataloguePatternCount
                    )
                )
            }
        }
        guard !pending.isEmpty else { return }

        let snapshot: ChekinanaPatternResourceSnapshot
        if let loadSnapshot {
            snapshot = try await loadSnapshot()
        } else {
            snapshot = try await resources.cachedSnapshot()
        }

        struct CatalogueSelection {
            let patternIDs: [String]
            let patterns: [[Float]]
        }
        var catalogueBySourceID: [String: CatalogueSelection] = [:]
        for value in pending where catalogueBySourceID[value.sourceID] == nil {
            let mappedIDs = snapshot.idolPatternIDs[value.sourceID] ?? []
            let selectedIDs: [String]
            if value.fields.cataloguePatternIDs.isEmpty {
                selectedIDs = mappedIDs
            } else {
                let priorSelection = Set(value.fields.cataloguePatternIDs)
                selectedIDs = mappedIDs.filter(priorSelection.contains)
            }
            catalogueBySourceID[value.sourceID] = CatalogueSelection(
                patternIDs: selectedIDs,
                patterns: try snapshot.patterns(for: selectedIDs)
            )
        }

        try ChekinanaPersistenceMutationCoordinator.withLock {
            let mutationContext = ModelContext(container)
            mutationContext.autosaveEnabled = false
            do {
                guard let currentGeneration = try ChekinanaLibraryGenerationStore
                        .current(in: mutationContext) else {
                    return
                }
                let states = try mutationContext.fetch(FetchDescriptor<IdolPatternState>())
                let idols = try mutationContext.fetch(FetchDescriptor<Idol>())
                for expected in pending {
                    guard expected.libraryGeneration == currentGeneration,
                          expected.expectedResourceVersion
                            == ChekinanaPatternContract.encoderVersion,
                          let selection = catalogueBySourceID[expected.sourceID]
                    else {
                        continue
                    }
                    let matchingStates = states.filter { $0.idolID == expected.idolID }
                    let matchingIdols = idols.filter { $0.id == expected.idolID }
                    guard matchingStates.count == 1,
                          matchingIdols.count == 1 else {
                        continue
                    }
                    let record = matchingStates[0]
                    let idol = matchingIdols[0]
                    let currentFields = PendingRefresh.FieldSnapshot(
                        legacyPattern: idol.pattern,
                        patterns: idol.patterns,
                        updatedAt: idol.updatedAt,
                        cataloguePatternIDs: record.cataloguePatternIDs,
                        cataloguePatternCount: record.cataloguePatternCount
                    )
                    guard record.persistentModelID == expected.stateIdentity,
                          idol.persistentModelID == expected.idolIdentity,
                          record.encoderVersion == expected.expectedPendingVersion,
                          record.encoderVersion
                            != ChekinanaPatternContract.encoderVersion,
                          idol.sourceId?.nonEmpty == expected.sourceID,
                          currentFields == expected.fields,
                          record.cataloguePatternCount >= 0,
                          record.cataloguePatternCount
                            == record.cataloguePatternIDs.count,
                          record.cataloguePatternCount <= idol.patterns.count else {
                        continue
                    }
                    let customPatterns = Array(idol.patterns.dropFirst(
                        record.cataloguePatternCount
                    ))
                    _ = try replaceCataloguePatterns(
                        for: idol,
                        patternIDs: selection.patternIDs,
                        prototypes: selection.patterns,
                        customPatterns: customPatterns,
                        in: mutationContext
                    )
                }
                if mutationContext.hasChanges { try mutationContext.save() }
            } catch {
                mutationContext.rollback()
                throw error
            }
        }
    }
}
#endif

actor ChekinanaPatternEncoder {
    static let shared = ChekinanaPatternEncoder()

    private let model: MLModel?

    init(bundle: Bundle = .main) {
        guard let compiledURL = bundle.url(
            forResource: "ChekiPatternEncoder",
            withExtension: "mlmodelc"
        ) else {
            model = nil
            return
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: compiledURL, configuration: configuration)
    }

#if DEBUG
    init(compiledModelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(
            contentsOf: compiledModelURL,
            configuration: configuration
        )
    }
#endif

    func encode(_ imageData: Data) async throws -> [Float] {
        let result = try await encoding(imageData)
#if DEBUG && CHEKINANA_DINO_DEBUG_CAPTURE
        await ChekinanaDINODebugCaptureStore.shared.capture(
            imageData: imageData,
            raw: result.raw,
            normalized: result.normalized
        )
#endif
        return result.normalized
    }

    /// DEBUG comparison harness entry. It deliberately shares the exact model,
    /// preprocessing, output extraction, and normalization used by `encode`.
#if DEBUG
    func comparisonEncoding(_ imageData: Data) async throws
        -> ChekinanaPatternEncodingResult
    {
        try await encoding(imageData)
    }
#endif

    private func encoding(_ imageData: Data) async throws
        -> ChekinanaPatternEncodingResult
    {
        guard let model else {
            throw ChekinanaPatternEncoderError.modelUnavailable
        }
        let regions = try ChekinanaPatternImagePreprocessor.regions(from: imageData)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "regions": MLFeatureValue(multiArray: regions),
        ])
        let output = try await model.prediction(
            from: input,
            options: MLPredictionOptions()
        )
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue,
              array.count == ChekinanaPatternClassifier.embeddingDimension else {
            throw ChekinanaPatternEncoderError.invalidModelOutput
        }
        let values = (0..<array.count).map { array[$0].floatValue }
        guard ChekinanaPatternClassifier.isValidEmbedding(values) else {
            throw ChekinanaPatternEncoderError.invalidModelOutput
        }
        let norm = sqrt(values.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else {
            throw ChekinanaPatternEncoderError.invalidModelOutput
        }
        return ChekinanaPatternEncodingResult(
            raw: values,
            normalized: values.map { $0 / norm }
        )
    }
}

enum ChekinanaPatternImagePreprocessor {
    private static let imageSize = 224
    private static let sampleSize = 32
    private static let maximumInputBytes = 64 * 1_024 * 1_024
    private static let maximumDecodedDimension = 2_048
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let standardDeviation: [Float] = [0.229, 0.224, 0.225]

    static func regions(from imageData: Data) throws -> MLMultiArray {
        let image = try boundedOrientedCGImage(from: imageData)

        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let bottomTop = Int(
            (Double(image.height) * 0.55).rounded(.toNearestOrEven)
        )
        let bottom = CGRect(
            x: 0,
            y: bottomTop,
            width: image.width,
            height: max(1, image.height - bottomTop)
        )
        guard let fullRegion = image.cropping(to: full),
              let bottomRegion = image.cropping(to: bottom) else {
            throw ChekinanaPatternEncoderError.invalidImage
        }

        let array = try MLMultiArray(
            shape: [1, 2, 3, imageSize, imageSize] as [NSNumber],
            dataType: .float32
        )
        guard array.strides.map(\.intValue) == [
            301_056, 150_528, 50_176, 224, 1,
        ] else {
            throw ChekinanaPatternEncoderError.invalidModelInput
        }
        let output = array.dataPointer.bindMemory(
            to: Float32.self,
            capacity: array.count
        )
        for (regionIndex, region) in [fullRegion, bottomRegion].enumerated() {
            let rgb = try letterboxedRGB(region)
            for y in 0..<imageSize {
                for x in 0..<imageSize {
                    let pixelOffset = (y * imageSize + x) * 4
                    let spatialOffset = y * imageSize + x
                    for channel in 0..<3 {
                        let value = Float(rgb[pixelOffset + channel]) / 255
                        output[
                            regionIndex * 3 * imageSize * imageSize
                                + channel * imageSize * imageSize
                                + spatialOffset
                        ] = (value - mean[channel]) / standardDeviation[channel]
                    }
                }
            }
        }
        return array
    }

    private static func boundedOrientedCGImage(from imageData: Data) throws -> CGImage {
        guard !imageData.isEmpty,
              imageData.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(
                imageData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              ChekinanaImageSourceValidator.accepts(
                source: source,
                maxDimension: maximumDecodedDimension
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw ChekinanaPatternEncoderError.invalidImage
        }
        let orientation = ChekinanaImageSourceValidator.exifOrientation(source: source) ?? 1
        let image: CGImage?
        if max(width, height) <= maximumDecodedDimension, orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDecodedDimension,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false,
            ] as CFDictionary)
        }
        guard let image,
              image.width > 0,
              image.height > 0,
              max(image.width, image.height) <= maximumDecodedDimension + 1 else {
            throw ChekinanaPatternEncoderError.invalidImage
        }
        return image
    }

    private static func letterboxedRGB(_ image: CGImage) throws -> [UInt8] {
        let source = try renderedRGBA(
            image,
            width: image.width,
            height: image.height
        )
        let borderSample = pillowBicubicResize(
            source,
            sourceWidth: image.width,
            sourceHeight: image.height,
            destinationWidth: sampleSize,
            destinationHeight: sampleSize
        )
        let fill = borderMedian(borderSample, size: sampleSize)
        let scale = min(
            Double(imageSize) / Double(image.width),
            Double(imageSize) / Double(image.height)
        )
        let resizedWidth = max(
            1,
            Int((Double(image.width) * scale).rounded(.toNearestOrEven))
        )
        let resizedHeight = max(
            1,
            Int((Double(image.height) * scale).rounded(.toNearestOrEven))
        )
        let left = (imageSize - resizedWidth) / 2
        let top = (imageSize - resizedHeight) / 2
        let resized = pillowBicubicResize(
            source,
            sourceWidth: image.width,
            sourceHeight: image.height,
            destinationWidth: resizedWidth,
            destinationHeight: resizedHeight
        )
        var canvas = [UInt8](repeating: 255, count: imageSize * imageSize * 4)
        for y in 0..<imageSize {
            for x in 0..<imageSize {
                let offset = (y * imageSize + x) * 4
                canvas[offset] = fill.0
                canvas[offset + 1] = fill.1
                canvas[offset + 2] = fill.2
            }
        }
        for y in 0..<resizedHeight {
            let sourceOffset = y * resizedWidth * 4
            let destinationOffset = ((top + y) * imageSize + left) * 4
            canvas.replaceSubrange(
                destinationOffset..<(destinationOffset + resizedWidth * 4),
                with: resized[sourceOffset..<(sourceOffset + resizedWidth * 4)]
            )
        }
        return canvas
    }

    /// Mirrors Pillow/torchvision's RGB `Image.resize(..., BICUBIC)` path.
    /// Pillow widens the cubic support while downsampling; using Core Graphics
    /// `.high` here changes enough pixels to materially shift the embedding.
    private static func pillowBicubicResize(
        _ source: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) -> [UInt8] {
        let horizontal = pillowCoefficients(
            sourceSize: sourceWidth,
            destinationSize: destinationWidth
        )
        var intermediate = [UInt8](
            repeating: 255,
            count: destinationWidth * sourceHeight * 4
        )
        for y in 0..<sourceHeight {
            for x in 0..<destinationWidth {
                let coefficients = horizontal[x]
                let destinationOffset = (y * destinationWidth + x) * 4
                for channel in 0..<3 {
                    var value = 0.0
                    for sample in coefficients.samples {
                        value += Double(source[
                            (y * sourceWidth + sample.index) * 4 + channel
                        ]) * sample.weight
                    }
                    intermediate[destinationOffset + channel] = UInt8(
                        max(0, min(255, Int(value.rounded())))
                    )
                }
            }
        }

        let vertical = pillowCoefficients(
            sourceSize: sourceHeight,
            destinationSize: destinationHeight
        )
        var output = [UInt8](
            repeating: 255,
            count: destinationWidth * destinationHeight * 4
        )
        for y in 0..<destinationHeight {
            let coefficients = vertical[y]
            for x in 0..<destinationWidth {
                let destinationOffset = (y * destinationWidth + x) * 4
                for channel in 0..<3 {
                    var value = 0.0
                    for sample in coefficients.samples {
                        value += Double(intermediate[
                            (sample.index * destinationWidth + x) * 4 + channel
                        ]) * sample.weight
                    }
                    output[destinationOffset + channel] = UInt8(
                        max(0, min(255, Int(value.rounded())))
                    )
                }
            }
        }
        return output
    }

    private struct PillowCoefficient {
        let samples: [(index: Int, weight: Double)]
    }

    private static func pillowCoefficients(
        sourceSize: Int,
        destinationSize: Int
    ) -> [PillowCoefficient] {
        let scale = Double(sourceSize) / Double(destinationSize)
        let filterScale = max(1, scale)
        let support = 2 * filterScale
        return (0..<destinationSize).map { destinationIndex in
            let center = (Double(destinationIndex) + 0.5) * scale
            let first = max(0, Int((center - support + 0.5).rounded(.towardZero)))
            let last = min(
                sourceSize,
                Int((center + support + 0.5).rounded(.towardZero))
            )
            var raw: [(index: Int, weight: Double)] = []
            var sum = 0.0
            for sourceIndex in first..<last {
                let distance = (
                    Double(sourceIndex) - center + 0.5
                ) / filterScale
                let weight = pillowBicubicKernel(distance)
                raw.append((sourceIndex, weight))
                sum += weight
            }
            guard sum != 0 else { return PillowCoefficient(samples: []) }
            return PillowCoefficient(samples: raw.map {
                ($0.index, $0.weight / sum)
            })
        }
    }

    private static func pillowBicubicKernel(_ value: Double) -> Double {
        let x = abs(value)
        if x < 1 {
            return ((1.5 * x - 2.5) * x) * x + 1
        }
        if x < 2 {
            return ((-0.5 * x + 2.5) * x - 4) * x + 2
        }
        return 0
    }

    private static func renderedRGBA(
        _ image: CGImage,
        width: Int,
        height: Int,
        destination: CGRect? = nil,
        fill: (UInt8, UInt8, UInt8) = (0, 0, 0)
    ) throws -> [UInt8] {
        var bytes = Array(repeating: UInt8.zero, count: width * height * 4)
        let created = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                        CGBitmapInfo(
                            rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                        )
                    ).rawValue
                  ) else {
                return false
            }
            context.setFillColor(
                red: CGFloat(fill.0) / 255,
                green: CGFloat(fill.1) / 255,
                blue: CGFloat(fill.2) / 255,
                alpha: 1
            )
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            let target = destination ?? CGRect(x: 0, y: 0, width: width, height: height)
            context.draw(image, in: target)
            return true
        }
        guard created else {
            throw ChekinanaPatternEncoderError.invalidImage
        }
        return bytes
    }

    private static func borderMedian(
        _ bytes: [UInt8],
        size: Int
    ) -> (UInt8, UInt8, UInt8) {
        var channels = Array(repeating: [UInt8](), count: 3)
        channels.indices.forEach { channels[$0].reserveCapacity(size * 4) }
        func appendPixel(x: Int, y: Int) {
            let offset = (y * size + x) * 4
            for channel in 0..<3 {
                channels[channel].append(bytes[offset + channel])
            }
        }
        for x in 0..<size {
            appendPixel(x: x, y: 0)
            appendPixel(x: x, y: size - 1)
        }
        for y in 0..<size {
            appendPixel(x: 0, y: y)
            appendPixel(x: size - 1, y: y)
        }
        let values = channels.map { values -> UInt8 in
            let sorted = values.sorted()
            let upper = Int(sorted[sorted.count / 2])
            let lower = Int(sorted[sorted.count / 2 - 1])
            return UInt8((lower + upper) / 2)
        }
        return (values[0], values[1], values[2])
    }
}

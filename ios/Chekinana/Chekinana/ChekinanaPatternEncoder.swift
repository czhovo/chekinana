import CoreGraphics
@preconcurrency import CoreML
import Foundation
import ImageIO
import SwiftData
import UIKit

enum ChekinanaPatternEncoderError: LocalizedError {
    case invalidImage
    case modelUnavailable
    case invalidModelInput
    case invalidModelOutput
    case noValidCandidates

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "无法为 Idol 识别读取拍立得图片"
        case .modelUnavailable:
            "本机 Idol 编码器不可用"
        case .invalidModelInput:
            "本机 Idol 编码器输入无效"
        case .invalidModelOutput:
            "本机 Idol 编码器返回了无效编码"
        case .noValidCandidates:
            "候选 Idol 中没有可用的 256 维原型编码"
        }
    }
}

struct ChekinanaPatternCandidateSet: Equatable, Sendable {
    let idolIDs: [UUID]
    let includesUnassigned: Bool
    let threshold: Float

    init(
        idolIDs: [UUID],
        includesUnassigned: Bool,
        threshold: Float = ChekinanaPatternClassifier.unassignedThreshold
    ) {
        var seen = Set<UUID>()
        self.idolIDs = idolIDs.filter { seen.insert($0).inserted }
        self.includesUnassigned = includesUnassigned
        self.threshold = min(max(threshold, 0), 1)
    }
}

struct ChekinanaPatternClassification: Equatable, Sendable {
    let idolID: UUID?
    let similarity: Float?
}

enum ChekinanaPatternClassifier {
    static let unassignedThreshold: Float = 0.870
    static let embeddingDimension = 256

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
        includesUnassigned: Bool,
        threshold: Float = unassignedThreshold
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
        if includesUnassigned, best.1 < threshold {
            return ChekinanaPatternClassification(idolID: nil, similarity: best.1)
        }
        return ChekinanaPatternClassification(idolID: best.0, similarity: best.1)
    }
}

@MainActor
enum ChekinanaLocalPatternRegistry {
    struct Entry: Equatable {
        let sourceId: String
        let legacySourceId: String
        let displayName: String
        let aliases: Set<String>
        let prototypeIndexes: [Int]
    }

    static let entries: [Entry] = [
        .init(sourceId: "idol_002009", legacySourceId: "fixed-pattern-v1:aina", displayName: "aina", aliases: ["aina"], prototypeIndexes: [0]),
        .init(sourceId: "idol_000513", legacySourceId: "fixed-pattern-v1:utaka", displayName: "巫歌", aliases: ["巫歌", "utaka"], prototypeIndexes: [1]),
        .init(sourceId: "idol_001042", legacySourceId: "fixed-pattern-v1:koikoi", displayName: "恋恋", aliases: ["恋恋", "koikoi"], prototypeIndexes: [2]),
        .init(sourceId: "idol_001958", legacySourceId: "fixed-pattern-v1:mulan", displayName: "木兰", aliases: ["木兰", "mulan"], prototypeIndexes: [3]),
        .init(sourceId: "idol_001325", legacySourceId: "fixed-pattern-v1:aoyi", displayName: "aoyi", aliases: ["aoyi"], prototypeIndexes: [4]),
        .init(sourceId: "idol_002008", legacySourceId: "fixed-pattern-v1:eriko", displayName: "eriko", aliases: ["eriko"], prototypeIndexes: [5]),
        .init(sourceId: "idol_002004", legacySourceId: "fixed-pattern-v1:kotomi", displayName: "kotomi", aliases: ["kotomi"], prototypeIndexes: [6]),
        .init(sourceId: "idol_001326", legacySourceId: "fixed-pattern-v1:mina-midnight", displayName: "mina（凌晨12点）", aliases: ["mina（凌晨12点）", "mina", "mina_new"], prototypeIndexes: [7, 8]),
        .init(sourceId: "idol_000812", legacySourceId: "fixed-pattern-v1:niku", displayName: "niku", aliases: ["niku"], prototypeIndexes: [9]),
        .init(sourceId: "idol_002005", legacySourceId: "fixed-pattern-v1:ririsu", displayName: "ririsu", aliases: ["ririsu"], prototypeIndexes: [10]),
        .init(sourceId: "idol_001500", legacySourceId: "fixed-pattern-v1:yuko", displayName: "优子", aliases: ["优子", "yuko"], prototypeIndexes: [11]),
    ]

    static func patterns(for sourceId: String?) -> [[Float]] {
        guard let sourceId = sourceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let entry = entries.first(where: { $0.sourceId == sourceId }) else {
            return []
        }
        let prototypes = ChekinanaPresetIdolSeeder.prototypeVectors
        guard entry.prototypeIndexes.allSatisfy(prototypes.indices.contains) else { return [] }
        return entry.prototypeIndexes.map { prototypes[$0] }
    }

    static func mergedPatterns(_ groups: [[[Float]]]) -> [[Float]] {
        var result: [[Float]] = []
        for pattern in groups.flatMap({ $0 })
        where ChekinanaPatternClassifier.isValidEmbedding(pattern) && !result.contains(pattern) {
            result.append(pattern)
        }
        return result
    }

    static func validate() throws {
        let prototypes = ChekinanaPresetIdolSeeder.prototypeVectors
        let indexes = entries.flatMap(\.prototypeIndexes)
        guard entries.count == 11,
              Set(entries.map(\.sourceId)).count == entries.count,
              Set(entries.map(\.legacySourceId)).count == entries.count,
              indexes == Array(0..<12),
              prototypes.count == 12,
              prototypes.allSatisfy(ChekinanaPatternClassifier.isValidEmbedding),
              prototypes.allSatisfy({ vector in
                  vector.allSatisfy(\.isFinite)
                      && abs(sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 }) - 1) < 0.001
              }) else {
            throw ChekinanaPatternEncoderError.invalidModelOutput
        }
    }

    static func normalizedAlias(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

@MainActor
struct ChekinanaCataloguePatternSelectionState: Equatable {
    private(set) var sourceId: String?
    private(set) var patterns: [[Float]] = []

    mutating func select(sourceId: String) {
        self.sourceId = sourceId
        patterns = ChekinanaLocalPatternRegistry.patterns(for: sourceId)
    }

    mutating func clear() {
        sourceId = nil
        patterns = []
    }
}

@MainActor
enum ChekinanaPresetIdolSeeder {
    static let prototypeSourceSHA256 = "7512e1762a1744e3ad79abea92cc99c12d289b75451269d190c12fbb03d4ee82"
    struct SeedResult: Equatable {
        let insertedIdolCount: Int
        let appendedPatternCount: Int
        let migratedLegacyPatternCount: Int
    }

    static var prototypeOwnerNamesInOrder: [String] {
        ChekinanaLocalPatternRegistry.entries.flatMap { entry in
            entry.prototypeIndexes.map { _ in entry.displayName }
        }
    }

    // Exact normalized float32 prototype bytes exported from
    // fixed_pattern_prototypes_v1.pt. Storing bytes avoids decimal
    // re-rounding in generated source.
    private static let prototypeBytesBase64 = "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"

    static var prototypeVectors: [[Float]] {
        guard let bytes = Data(base64Encoded: prototypeBytesBase64),
              bytes.count == 12 * ChekinanaPatternClassifier.embeddingDimension * MemoryLayout<Float>.size else {
            return []
        }
        return (0..<12).map { prototypeIndex in
            (0..<ChekinanaPatternClassifier.embeddingDimension).map { valueIndex in
                let offset = (
                    prototypeIndex * ChekinanaPatternClassifier.embeddingDimension + valueIndex
                ) * MemoryLayout<UInt32>.size
                let bits = bytes.withUnsafeBytes { rawBytes in
                    UInt32(littleEndian: rawBytes.loadUnaligned(
                        fromByteOffset: offset,
                        as: UInt32.self
                    ))
                }
                return Float(bitPattern: bits)
            }
        }
    }

    @discardableResult
    static func ensureSeeds(in context: ModelContext) throws -> SeedResult {
        try ChekinanaLocalPatternRegistry.validate()

        let existing = try context.fetch(FetchDescriptor<Idol>())
        var inserted = 0
        var appended = 0
        var migrated = 0

        for idol in existing where idol.migrateLegacyPatternIfNeeded() {
            migrated += 1
        }

        for entry in ChekinanaLocalPatternRegistry.entries {
            let target: Idol
            let shouldInjectPresetPatterns: Bool
            if let current = existing.first(where: { $0.sourceId == entry.sourceId }) {
                // Once an Idol has the current catalogue identity, its stored
                // patterns are user-authored state. In particular, launch-time
                // seeding must not restore a registry pattern the user removed.
                target = current
                shouldInjectPresetPatterns = false
            } else if let legacy = existing.first(where: { $0.sourceId == entry.legacySourceId }) {
                target = legacy
                target.sourceId = entry.sourceId
                shouldInjectPresetPatterns = true
            } else if let alias = existing.first(where: {
                $0.sourceId == nil
                    && entry.aliases.contains(
                        ChekinanaLocalPatternRegistry.normalizedAlias($0.name)
                    )
            }) {
                target = alias
                target.sourceId = entry.sourceId
                shouldInjectPresetPatterns = true
            } else {
                target = Idol(sourceId: entry.sourceId, name: entry.displayName)
                context.insert(target)
                inserted += 1
                shouldInjectPresetPatterns = true
            }

            for prototype in ChekinanaLocalPatternRegistry.patterns(for: entry.sourceId)
            where shouldInjectPresetPatterns {
                guard !target.patterns.contains(prototype) else { continue }
                target.patterns.append(prototype)
                appended += 1
            }
        }
        if context.hasChanges {
            try context.save()
        }
        return SeedResult(
            insertedIdolCount: inserted,
            appendedPatternCount: appended,
            migratedLegacyPatternCount: migrated
        )
    }

}

enum ChekinanaPresetSeedPolicy {
    static let suppressionKey = "chekinana.preset-idols.suppressed.v1"

    static func isSuppressed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: suppressionKey)
    }

    static func suppress(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: suppressionKey)
    }

    static func resetForUITestingIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        guard environment["CHEKINANA_UI_RESET_STORE"] == "1" else { return }
        defaults.removeObject(forKey: suppressionKey)
    }

    static func shouldSeed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if environment["CHEKINANA_PRODUCT_UI_FIXTURE"] != nil
            || environment["CHEKINANA_UI_RESET_STORE"] == "1" {
            return true
        }
        return !isSuppressed(defaults: defaults)
    }
}


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

    func encode(_ imageData: Data) async throws -> [Float] {
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
        return values.map { $0 / norm }
    }
}

enum ChekinanaPatternImagePreprocessor {
    private static let imageSize = 256
    private static let sampleSize = 32
    private static let maximumInputBytes = 64 * 1_024 * 1_024
    private static let maximumDecodedDimension = 2_048
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let standardDeviation: [Float] = [0.229, 0.224, 0.225]

    static func regions(from imageData: Data) throws -> MLMultiArray {
        let image = try boundedOrientedCGImage(from: imageData)

        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let bottomTop = Int(
            (Double(image.height) * 0.60).rounded(.toNearestOrEven)
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
            393_216, 196_608, 65_536, 256, 1,
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
        let borderSample = try renderedRGBA(
            image,
            width: sampleSize,
            height: sampleSize
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
        return try renderedRGBA(
            image,
            width: imageSize,
            height: imageSize,
            destination: CGRect(
                x: left,
                y: top,
                width: resizedWidth,
                height: resizedHeight
            ),
            fill: fill
        )
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

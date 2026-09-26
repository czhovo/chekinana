import CoreGraphics
import CoreML
import Foundation
import ImageIO

// The app validator normally lives beside the scanner. The host target supplies
// the identical source-bound checks needed by the shared pattern preprocessor.
enum ChekinanaImageSourceValidator {
    static let maximumThumbnailDimension = 8_192
    static let maximumSourceDimension = 32_768
    static let maximumSourcePixelCount = 100_000_000.0

    static func accepts(source: CGImageSource, maxDimension: Int) -> Bool {
        guard (1...maximumThumbnailDimension).contains(maxDimension),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return false
        }
        return accepts(properties: properties)
    }

    static func accepts(properties: [CFString: Any]) -> Bool {
        guard let width = numericValue(properties[kCGImagePropertyPixelWidth]),
              let height = numericValue(properties[kCGImagePropertyPixelHeight]),
              width.isFinite,
              height.isFinite,
              width >= 1,
              height >= 1,
              width <= Double(maximumSourceDimension),
              height <= Double(maximumSourceDimension),
              width * height <= maximumSourcePixelCount else {
            return false
        }
        if let orientation = numericValue(properties[kCGImagePropertyOrientation]),
           (!orientation.isFinite
                || orientation.rounded() != orientation
                || orientation < 1
                || orientation > 8) {
            return false
        }
        return true
    }

    static func exifOrientation(source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
              let value = numericValue(properties[kCGImagePropertyOrientation]),
              value.isFinite,
              value.rounded() == value,
              (1...8).contains(value) else {
            return nil
        }
        return Int(value)
    }

    private static func numericValue(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

private struct CaptureManifest: Decodable {
    struct Entry: Decodable {
        let sequence: Int
        let inputFile: String
    }

    let entries: [Entry]
}

private struct ComparisonManifest: Encodable {
    struct Entry: Encodable {
        let sequence: Int
        let inputFile: String
        let rawVectorFile: String
        let normalizedVectorFile: String
        let dimension: Int
        let rawNorm: Float
        let normalizedNorm: Float
        let rawIsFinite: Bool
        let normalizedIsFinite: Bool
    }

    let format = "chekinana_dino_mac_comparison_v1"
    let encoderVersion = ChekinanaPatternContract.encoderVersion
    let modelResource: String
    let computeUnits = "all"
    let vectorDType = ChekinanaDINOFloat32Encoding.dtype
    let vectorByteOrder = ChekinanaDINOFloat32Encoding.byteOrder
    let sourceSessionDirectory: String
    let entries: [Entry]
}

enum DINOComparisonOutputWriter {
    static func writeNew(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw DINOComparisonRunnerError.outputAlreadyExists(url.path)
        }
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).temporary"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        do {
            // Creating the hard link is an atomic, no-replace publication step.
            try FileManager.default.linkItem(at: temporaryURL, to: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                throw DINOComparisonRunnerError.outputAlreadyExists(url.path)
            }
            throw error
        }
    }
}

enum DINOComparisonRunnerError: LocalizedError {
    case usage
    case invalidInputFile(String)
    case invalidOrDuplicateSequence(Int)
    case outputInsideCaptureSession
    case outputAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: dino-comparison <ChekiPatternEncoder.mlmodelc> "
                + "<capture-session-directory> <output-directory>"
        case .invalidInputFile(let file):
            "Capture manifest input is not a safe session-local basename: \(file)"
        case .invalidOrDuplicateSequence(let sequence):
            "Capture sequence must be positive and unique: \(sequence)"
        case .outputInsideCaptureSession:
            "Output directory must be outside the capture session directory."
        case .outputAlreadyExists(let path):
            "Refusing to overwrite existing output: \(path)"
        }
    }
}

#if !CHEKINANA_DINO_OUTPUT_WRITE_TEST
@main
private enum DINOComparisonRunner {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw DINOComparisonRunnerError.usage
        }
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let sessionURL = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true
        )
        let outputURL = URL(
            fileURLWithPath: CommandLine.arguments[3],
            isDirectory: true
        )
        let resolvedSessionURL = sessionURL.resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedOutputURL = outputURL.resolvingSymlinksInPath()
            .standardizedFileURL
        guard !isContained(resolvedOutputURL, in: resolvedSessionURL) else {
            throw DINOComparisonRunnerError.outputInsideCaptureSession
        }
        let captureData = try Data(
            contentsOf: resolvedSessionURL.appendingPathComponent("manifest.json")
        )
        let capture = try JSONDecoder().decode(CaptureManifest.self, from: captureData)
        var seenSequences = Set<Int>()
        let orderedEntries = try capture.entries.sorted(by: {
            $0.sequence < $1.sequence
        }).map { entry -> CaptureManifest.Entry in
            guard entry.sequence > 0,
                  seenSequences.insert(entry.sequence).inserted else {
                throw DINOComparisonRunnerError.invalidOrDuplicateSequence(
                    entry.sequence
                )
            }
            guard !entry.inputFile.isEmpty,
                  URL(fileURLWithPath: entry.inputFile).lastPathComponent
                    == entry.inputFile else {
                throw DINOComparisonRunnerError.invalidInputFile(entry.inputFile)
            }
            let resolvedInput = resolvedSessionURL
                .appendingPathComponent(entry.inputFile)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard isContained(resolvedInput, in: resolvedSessionURL),
                  FileManager.default.fileExists(atPath: resolvedInput.path) else {
                throw DINOComparisonRunnerError.invalidInputFile(entry.inputFile)
            }
            return entry
        }
        try FileManager.default.createDirectory(
            at: resolvedOutputURL,
            withIntermediateDirectories: true
        )
        let manifestOutputURL = resolvedOutputURL.appendingPathComponent(
            "manifest.json"
        )
        guard !FileManager.default.fileExists(atPath: manifestOutputURL.path) else {
            throw DINOComparisonRunnerError.outputAlreadyExists(
                manifestOutputURL.path
            )
        }
        let encoder = try ChekinanaPatternEncoder(compiledModelURL: modelURL)
        var outputEntries: [ComparisonManifest.Entry] = []
        for entry in orderedEntries {
            let inputURL = resolvedSessionURL.appendingPathComponent(entry.inputFile)
            let inputData = try Data(contentsOf: inputURL)
            let result = try await encoder.comparisonEncoding(inputData)
            let stem = String(format: "%06d", entry.sequence)
            let rawFile = "\(stem)-mac-raw.f32"
            let normalizedFile = "\(stem)-mac-normalized.f32"
            try DINOComparisonOutputWriter.writeNew(
                ChekinanaDINOFloat32Encoding.data(result.raw),
                to: resolvedOutputURL.appendingPathComponent(rawFile)
            )
            try DINOComparisonOutputWriter.writeNew(
                ChekinanaDINOFloat32Encoding.data(result.normalized),
                to: resolvedOutputURL.appendingPathComponent(normalizedFile)
            )
            outputEntries.append(.init(
                sequence: entry.sequence,
                inputFile: entry.inputFile,
                rawVectorFile: rawFile,
                normalizedVectorFile: normalizedFile,
                dimension: result.raw.count,
                rawNorm: norm(result.raw),
                normalizedNorm: norm(result.normalized),
                rawIsFinite: result.raw.allSatisfy(\.isFinite),
                normalizedIsFinite: result.normalized.allSatisfy(\.isFinite)
            ))
        }
        let output = ComparisonManifest(
            modelResource: modelURL.lastPathComponent,
            sourceSessionDirectory: sessionURL.lastPathComponent,
            entries: outputEntries
        )
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DINOComparisonOutputWriter.writeNew(
            jsonEncoder.encode(output),
            to: manifestOutputURL
        )
    }

    private static func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let root = directory.path.hasSuffix("/")
            ? directory.path
            : directory.path + "/"
        return candidate.path == directory.path || candidate.path.hasPrefix(root)
    }

    private static func norm(_ values: [Float]) -> Float {
        sqrt(values.reduce(Float.zero) { $0 + $1 * $1 })
    }

}
#endif

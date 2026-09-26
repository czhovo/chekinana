import Foundation

struct ChekinanaEdgeDetectorManifest: Decodable, Equatable, Sendable {
    let algorithmID: String
    let semver: String
    let build: String
    let outputSchemaVersion: String
    let assetVersion: String
}

struct ChekinanaScannerQuadrilateralPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct ChekinanaPendingChekiImage: Sendable {
    let data: Data
}

struct ChekinanaEdgeDetectorOutput: Sendable {
    let manifest: ChekinanaEdgeDetectorManifest
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let quadrilaterals: [[ChekinanaScannerQuadrilateralPoint]]
    let decodedSource: ChekinanaUprightRGBRaster?

    init(
        manifest: ChekinanaEdgeDetectorManifest,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilaterals: [[ChekinanaScannerQuadrilateralPoint]],
        decodedSource: ChekinanaUprightRGBRaster? = nil
    ) {
        self.manifest = manifest
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.quadrilaterals = quadrilaterals
        self.decodedSource = decodedSource
    }
}

protocol ChekinanaOnDeviceEdgeDetector: Sendable {
    func detect(
        _ image: ChekinanaPendingChekiImage
    ) async throws -> ChekinanaEdgeDetectorOutput
}

enum ChekinanaOnDeviceScannerError: Error {
    case invalidAssetManifest
    case modelUnavailable
    case modelOutputInvalid
    case detectorRuntimeFailure
    case invalidSourceImage
}

enum ChekinanaLiveScannerUploadPreparer {
    static let maximumInputBytes = 40 * 1_024 * 1_024
}

enum ChekinanaEdgeFitGeometry {
    static func sortedByCenter(
        _ quadrilaterals: [[ChekinanaScannerQuadrilateralPoint]]
    ) -> [[ChekinanaScannerQuadrilateralPoint]] {
        quadrilaterals.sorted { lhs, rhs in
            let left = center(lhs)
            let right = center(rhs)
            if left.x != right.x { return left.x < right.x }
            return left.y < right.y
        }
    }

    private static func center(
        _ points: [ChekinanaScannerQuadrilateralPoint]
    ) -> (x: Double, y: Double) {
        (
            points.reduce(0) { $0 + $1.x } / Double(points.count),
            points.reduce(0) { $0 + $1.y } / Double(points.count)
        )
    }
}

@main
struct EdgeFitProductionPipelineVerifier {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw VerificationError.invalidArguments
        }
        if CommandLine.arguments[1] == "--benchmark" {
            try await benchmark(
                bundlePath: CommandLine.arguments[2],
                imagePath: CommandLine.arguments[3]
            )
            return
        }
        if CommandLine.arguments[1] == "--inspect" {
            try await inspect(
                bundlePath: CommandLine.arguments[2],
                imagePath: CommandLine.arguments[3]
            )
            return
        }
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
            throw VerificationError.invalidBundle
        }
        let imageURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let expectedURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let expectedDocument = try JSONDecoder().decode(
            ExpectedDocument.self,
            from: Data(contentsOf: expectedURL)
        )
        let relativePath = "images/" + imageURL.lastPathComponent
        guard let expected = expectedDocument.records.first(where: {
            $0.path == relativePath
        }) else {
            throw VerificationError.missingExpectedRecord
        }

        let detector = try ChekinanaEdgeFitRTV2Detector(bundle: bundle)
#if EDGEFIT_HOST_E2E_FORCE_CANDIDATE
        ChekinanaEdgeFitHostCoverage.shared.reset()
#endif
        let output = try await detector.detect(
            ChekinanaPendingChekiImage(data: Data(contentsOf: imageURL))
        )
        guard output.sourcePixelWidth == expected.rawSize[0],
              output.sourcePixelHeight == expected.rawSize[1] else {
            throw VerificationError.sourceGeometryMismatch
        }
#if EDGEFIT_HOST_E2E_FORCE_CANDIDATE
        let coverage = ChekinanaEdgeFitHostCoverage.shared.snapshot
        guard coverage.modelPredictions == 3 else {
            throw VerificationError.modelCoverageMismatch(
                actual: coverage.modelPredictions,
                expected: 3
            )
        }
        guard coverage.fitAttempts == 1 else {
            throw VerificationError.fitCoverageMismatch(
                actual: coverage.fitAttempts,
                expected: 1
            )
        }
#else
        guard output.quadrilaterals.count
                == expected.groundTruthRawQuadrilaterals.count else {
            throw VerificationError.resultCountMismatch(
                actual: output.quadrilaterals.count,
                expected: expected.groundTruthRawQuadrilaterals.count
            )
        }
#endif

        var maximumCornerError = 0.0
        var totalCornerError = 0.0
        var cornerCount = 0
        for (actualQuad, expectedQuad) in zip(
            output.quadrilaterals,
            expected.groundTruthRawQuadrilaterals
        ) {
            guard actualQuad.count == 4, expectedQuad.count == 4 else {
                throw VerificationError.invalidQuadrilateral
            }
            for (actual, expectedPoint) in zip(actualQuad, expectedQuad) {
                let error = hypot(actual.x - expectedPoint[0], actual.y - expectedPoint[1])
                maximumCornerError = max(maximumCornerError, error)
                totalCornerError += error
                cornerCount += 1
            }
        }
        let meanCornerError = cornerCount > 0
            ? totalCornerError / Double(cornerCount)
            : 0
        var summary = "PASS fullPipelineModels=3 source=\(output.sourcePixelWidth)x"
            + "\(output.sourcePixelHeight) results=\(output.quadrilaterals.count) "
            + "meanCornerError=\(meanCornerError) "
            + "maxCornerError=\(maximumCornerError)"
#if EDGEFIT_HOST_E2E_FORCE_CANDIDATE
        summary += " forcedCandidate=true modelPredictions="
            + "\(coverage.modelPredictions) fitAttempts=\(coverage.fitAttempts)"
#endif
        print(summary)
    }

    private static func inspect(bundlePath: String, imagePath: String) async throws {
        guard let bundle = Bundle(path: bundlePath) else {
            throw VerificationError.invalidBundle
        }
        let imageURL = URL(fileURLWithPath: imagePath)
        let detector = try ChekinanaEdgeFitRTV2Detector(bundle: bundle)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let output = try await detector.detect(
            ChekinanaPendingChekiImage(data: Data(contentsOf: imageURL))
        )
        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000
        let quadrilaterals = output.quadrilaterals.map { quadrilateral in
            quadrilateral.map { ["x": $0.x, "y": $0.y] }
        }
        let document: [String: Any] = [
            "sourcePixelWidth": output.sourcePixelWidth,
            "sourcePixelHeight": output.sourcePixelHeight,
            "resultCount": output.quadrilaterals.count,
            "elapsedMilliseconds": elapsedMilliseconds,
            "quadrilaterals": quadrilaterals,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    private static func benchmark(bundlePath: String, imagePath: String) async throws {
        guard let bundle = Bundle(path: bundlePath) else {
            throw VerificationError.invalidBundle
        }
        let image = ChekinanaPendingChekiImage(
            data: try Data(contentsOf: URL(fileURLWithPath: imagePath))
        )
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let detector = try ChekinanaEdgeFitRTV2Detector(bundle: bundle)
        let loadMilliseconds = milliseconds(since: loadStart)
        var runs: [[String: Any]] = []
        for index in 0..<3 {
#if DEBUG
            ChekinanaEdgeFitRTV2Timing.reset()
#endif
            let started = DispatchTime.now().uptimeNanoseconds
            let output = try await detector.detect(image)
            let elapsed = milliseconds(since: started)
#if DEBUG
            let phaseSamples = ChekinanaEdgeFitRTV2Timing.snapshot().map {
                ["phase": $0.phase, "milliseconds": $0.milliseconds] as [String: Any]
            }
#else
            let phaseSamples: [[String: Any]] = []
#endif
            runs.append([
                "index": index,
                "milliseconds": elapsed,
                "resultCount": output.quadrilaterals.count,
                "phases": phaseSamples,
            ])
        }
        let document: [String: Any] = [
            "modelLoadMilliseconds": loadMilliseconds,
            "runs": runs,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private struct ExpectedDocument: Decodable {
        let records: [ExpectedRecord]
    }

    private struct ExpectedRecord: Decodable {
        let path: String
        let rawSize: [Int]
        let groundTruthRawQuadrilaterals: [[[Double]]]
    }

    private enum VerificationError: Error {
        case invalidArguments
        case invalidBundle
        case missingExpectedRecord
        case sourceGeometryMismatch
        case resultCountMismatch(actual: Int, expected: Int)
        case invalidQuadrilateral
#if EDGEFIT_HOST_E2E_FORCE_CANDIDATE
        case modelCoverageMismatch(actual: Int, expected: Int)
        case fitCoverageMismatch(actual: Int, expected: Int)
#endif
    }
}

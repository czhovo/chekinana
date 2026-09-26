import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ChekinanaProductCopy {
    static func text(_ key: String, _ fallback: String) -> String { fallback }
}

enum ChekinanaScanSourceOrigin: String, Sendable { case unspecified }
enum ChekiSize: String, Sendable { case mini }
enum ChekinanaChekiDateAnnotationState: Sendable { case notRequested }

struct ChekinanaScannerQuadrilateralPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct ChekinanaPendingChekiImage: Sendable {
    let data: Data
    let filenameExtension: String
    let sourceID: UUID?
    let sourceOrigin: ChekinanaScanSourceOrigin

    init(data: Data, filenameExtension: String) {
        self.data = data
        self.filenameExtension = filenameExtension
        sourceID = nil
        sourceOrigin = .unspecified
    }
}

struct ChekinanaScannerTaskProgress: Sendable {
    let phase: String?
    let publishedResultCount: Int
    let downloadedResultCount: Int
    let expectedPolaroids: Int?
    let extractionComplete: Bool
}

enum ChekinanaCommandExecutor {
    typealias ScannerStatusObserver = @Sendable (ChekinanaScannerTaskProgress) async -> Void
    typealias ScannerResultObserver = @Sendable (Int, ChekinanaScannerResultImage) async -> Void
}

struct ChekinanaScannerOptions: Sendable {
    let expectedPolaroids: Int?
    let whiteBalance: Bool
}

struct ChekinanaScannerSourceAnnotation: Sendable {
    let previewImageData: Data
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let quadrilateral: [ChekinanaScannerQuadrilateralPoint]

    var isValid: Bool {
        !previewImageData.isEmpty
            && sourcePixelWidth > 0
            && sourcePixelHeight > 0
            && quadrilateral.count == 4
            && quadrilateral.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
}

struct ChekinanaScannerResultImage: Sendable {
    let data: Data
    let imagePixelWidth: Int?
    let imagePixelHeight: Int?
    let filenameExtension: String
    let dateAnnotationState: ChekinanaChekiDateAnnotationState
    let sourceAnnotation: ChekinanaScannerSourceAnnotation?
    let inferredChekiSize: ChekiSize?

    init(
        data: Data,
        imagePixelWidth: Int?,
        imagePixelHeight: Int?,
        filenameExtension: String,
        dateAnnotationState: ChekinanaChekiDateAnnotationState,
        sourceAnnotation: ChekinanaScannerSourceAnnotation?,
        inferredChekiSize: ChekiSize?
    ) {
        self.data = data
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.filenameExtension = filenameExtension
        self.dateAnnotationState = dateAnnotationState
        self.sourceAnnotation = sourceAnnotation?.isValid == true ? sourceAnnotation : nil
        self.inferredChekiSize = inferredChekiSize
    }
}

struct ChekinanaScannerProcessResult: Sendable {
    let images: [ChekinanaScannerResultImage]
    let warningCount: Int
}

enum ChekinanaLiveScannerUploadPreparer {
    static let maximumInputBytes = 128 * 1_024 * 1_024
    static let maximumNormalizedDimension = 8_192
    static let maximumAnnotationPreviewDimension = 1_200
}

enum ChekinanaImageSourceValidator {
    static let maximumSourceDimension = 8_192
    static let maximumSourcePixelCount = 64_000_000.0

    static func accepts(source: CGImageSource, maxDimension: Int) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              max(width, height) <= maxDimension,
              Double(width) * Double(height) <= maximumSourcePixelCount else {
            return false
        }
        return true
    }
}

enum ChekinanaImageWorker {
    static func normalizedThumbnailOrientation(
        _ image: CGImage,
        exifOrientation: Int,
        maxDimension: Int
    ) -> CGImage? {
        guard exifOrientation == 1,
              max(image.width, image.height) <= maxDimension + 1 else { return nil }
        return image
    }
}

enum ChekinanaScannerAnnotationPreviewRenderer {
    enum Failure: String, Sendable { case invalidInput, renderFailed }
    struct Outcome: Sendable { let data: Data?; let failure: Failure? }

    static func renderOutcome(
        sourcePreviewData: Data,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint]
    ) -> Outcome {
        guard quadrilateral.count == 4,
              let source = CGImageSourceCreateWithData(sourcePreviewData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return Outcome(data: nil, failure: .invalidInput)
        }
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Outcome(data: nil, failure: .renderFailed) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let widthScale = Double(width) / Double(sourcePixelWidth)
        let heightScale = Double(height) / Double(sourcePixelHeight)
        let points: [CGPoint] = quadrilateral.map { point in
            let x = min(max(point.x * widthScale, 0), Double(width))
            let y = min(max(point.y * heightScale, 0), Double(height))
            return CGPoint(x: x, y: y)
        }
        context.setStrokeColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.setLineWidth(max(3, CGFloat(max(width, height)) / 400))
        context.move(to: points[0])
        for point in points.dropFirst() { context.addLine(to: point) }
        context.closePath()
        context.strokePath()
        guard let rendered = context.makeImage(),
              let data = encodedJPEG(rendered) else {
            return Outcome(data: nil, failure: .renderFailed)
        }
        return Outcome(data: data, failure: nil)
    }

    private static func encodedJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

private actor StaticDetector: ChekinanaOnDeviceEdgeDetector {
    let output: ChekinanaEdgeDetectorOutput
    init(output: ChekinanaEdgeDetectorOutput) { self.output = output }
    func detect(_ image: ChekinanaPendingChekiImage) async throws
        -> ChekinanaEdgeDetectorOutput { output }
}

@main
struct EdgeFitScannerChainVerifier {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            throw VerificationError.invalidArguments
        }
        let imageURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let imageData = try Data(contentsOf: imageURL)
        let image = ChekinanaPendingChekiImage(
            data: imageData,
            filenameExtension: imageURL.pathExtension
        )
        let detector = try ChekinanaEdgeFitRTV2Detector(bundle: bundle)
        let output = try await detector.detect(image)
        let client = ChekinanaOnDeviceScannerClient(
            detector: StaticDetector(output: output)
        )
        let result = try await client.process(
            image,
            options: ChekinanaScannerOptions(expectedPolaroids: nil, whiteBalance: true)
        )
        var whiteBalance: [Bool] = []
        for quadrilateral in output.quadrilaterals {
            let rectified = try await ChekinanaEdgeFitRectifier.rectify(
                sourceData: imageData,
                quadrilateral: quadrilateral,
                appliesWhiteBalance: true
            )
            whiteBalance.append(rectified.whiteBalanceApplied)
        }
        let document: [String: Any] = [
            "resultCount": result.images.count,
            "annotationCount": result.images.filter { $0.sourceAnnotation != nil }.count,
            "annotationBytes": result.images.map { $0.sourceAnnotation?.previewImageData.count ?? 0 },
            "whiteBalanceApplied": whiteBalance,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    enum VerificationError: Error { case invalidArguments }
}

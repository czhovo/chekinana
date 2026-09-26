import Foundation
@preconcurrency import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers


/// Version metadata is supplied by the bundled, delivered algorithm manifest.
struct ChekinanaEdgeDetectorManifest: Decodable, Equatable, Sendable {
    let algorithmID: String
    let semver: String
    let build: String
    let outputSchemaVersion: String
    let assetVersion: String
}

struct ChekinanaEdgeDetectorOutput: Equatable, Sendable {
    let manifest: ChekinanaEdgeDetectorManifest
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    /// EXIF-upright original-pixel coordinates ordered TL/TR/BR/BL.
    let quadrilaterals: [[ChekinanaScannerQuadrilateralPoint]]
    /// Production-only decoded source cache. Test detectors may omit this;
    /// equality deliberately covers the public detector contract only.
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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.manifest == rhs.manifest
            && lhs.sourcePixelWidth == rhs.sourcePixelWidth
            && lhs.sourcePixelHeight == rhs.sourcePixelHeight
            && lhs.quadrilaterals == rhs.quadrilaterals
    }
}

protocol ChekinanaOnDeviceEdgeDetector: Sendable {
    func detect(
        _ image: ChekinanaPendingChekiImage
    ) async throws -> ChekinanaEdgeDetectorOutput
}

enum ChekinanaOnDeviceScannerError: LocalizedError, Equatable {
    case assetUnavailable
    case adapterUnavailable(ChekinanaEdgeDetectorManifest)
    case invalidAssetManifest
    case modelUnavailable
    case modelOutputInvalid
    case detectorRuntimeFailure
    case invalidSourceImage
    case sourceGeometryMismatch
    case invalidQuadrilateral
    case rectificationFailed
    case noResults

    var errorDescription: String? {
        switch self {
        case .assetUnavailable:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_asset_unavailable",
                "The on-device Cheki scanner asset is not installed in this build."
            )
        case .adapterUnavailable:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_adapter_unavailable",
                "This Cheki scanner asset does not yet have a compatible on-device adapter."
            )
        case .invalidAssetManifest:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_manifest_invalid",
                "The installed Cheki scanner manifest is invalid."
            )
        case .modelUnavailable:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_model_unavailable",
                "A required on-device Cheki scanner model could not be loaded."
            )
        case .modelOutputInvalid:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_output_invalid",
                "The on-device Cheki scanner returned an invalid model output."
            )
        case .detectorRuntimeFailure:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_runtime_failed",
                "The on-device Cheki scanner could not process this image."
            )
        case .invalidSourceImage:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_invalid_source",
                "The selected scan image is invalid."
            )
        case .sourceGeometryMismatch:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_geometry_mismatch",
                "The scanner result does not match the selected image."
            )
        case .invalidQuadrilateral:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_invalid_quad",
                "The on-device scanner returned invalid Cheki corners."
            )
        case .rectificationFailed:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_rectification_failed",
                "The detected Cheki could not be extracted on this device."
            )
        case .noResults:
            return ChekinanaProductCopy.text(
                "assistant.executor.error.edge_detector_no_results",
                "No Cheki was detected in the selected image."
            )
        }
    }
}

/// Single production registration point for the frozen, versioned detector.
enum ChekinanaEdgeDetectorAssetRegistry {
    static func productionDetector() throws -> any ChekinanaOnDeviceEdgeDetector {
        try ChekinanaEdgeFitRTV2DetectorCache.shared.detector()
    }
}

enum ChekinanaDetectedChekiOrientation: Equatable, Sendable {
    case portrait
    case landscape
}

enum ChekinanaEdgeFitGeometry {
    private static let duplicateToleranceSquared = 0.000_001
    private static let minimumArea = 1.0

    static func validated(
        _ points: [ChekinanaScannerQuadrilateralPoint],
        sourcePixelWidth: Int,
        sourcePixelHeight: Int
    ) throws -> [ChekinanaScannerQuadrilateralPoint] {
        guard points.count == 4,
              sourcePixelWidth > 0,
              sourcePixelHeight > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ChekinanaOnDeviceScannerError.invalidQuadrilateral
        }
        for left in points.indices {
            for right in points.indices where right > left {
                guard squaredDistance(points[left], points[right])
                    > duplicateToleranceSquared else {
                    throw ChekinanaOnDeviceScannerError.invalidQuadrilateral
                }
            }
        }
        guard abs(signedArea(points)) >= minimumArea,
              !segmentsIntersect(points[0], points[1], points[2], points[3]),
              !segmentsIntersect(points[1], points[2], points[3], points[0]),
              isStrictlyConvex(points) else {
            throw ChekinanaOnDeviceScannerError.invalidQuadrilateral
        }
        return points
    }

    static func orientation(
        of points: [ChekinanaScannerQuadrilateralPoint]
    ) throws -> ChekinanaDetectedChekiOrientation {
        guard points.count == 4 else {
            throw ChekinanaOnDeviceScannerError.invalidQuadrilateral
        }
        let horizontalSpan = (
            distance(points[0], points[1]) + distance(points[3], points[2])
        ) / 2
        let verticalSpan = (
            distance(points[0], points[3]) + distance(points[1], points[2])
        ) / 2
        guard horizontalSpan.isFinite, verticalSpan.isFinite,
              horizontalSpan > 0, verticalSpan > 0 else {
            throw ChekinanaOnDeviceScannerError.invalidQuadrilateral
        }
        return horizontalSpan > verticalSpan ? .landscape : .portrait
    }

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
        guard !points.isEmpty else { return (.infinity, .infinity) }
        return (
            points.reduce(0) { $0 + $1.x } / Double(points.count),
            points.reduce(0) { $0 + $1.y } / Double(points.count)
        )
    }

    private static func squaredDistance(
        _ lhs: ChekinanaScannerQuadrilateralPoint,
        _ rhs: ChekinanaScannerQuadrilateralPoint
    ) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func distance(
        _ lhs: ChekinanaScannerQuadrilateralPoint,
        _ rhs: ChekinanaScannerQuadrilateralPoint
    ) -> Double {
        sqrt(squaredDistance(lhs, rhs))
    }

    private static func signedArea(
        _ points: [ChekinanaScannerQuadrilateralPoint]
    ) -> Double {
        zip(points, points.dropFirst() + points.prefix(1)).reduce(0) {
            $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y
        } / 2
    }

    private static func cross(
        _ a: ChekinanaScannerQuadrilateralPoint,
        _ b: ChekinanaScannerQuadrilateralPoint,
        _ c: ChekinanaScannerQuadrilateralPoint
    ) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func isStrictlyConvex(
        _ points: [ChekinanaScannerQuadrilateralPoint]
    ) -> Bool {
        let values = points.indices.map { index in
            cross(
                points[index],
                points[(index + 1) % 4],
                points[(index + 2) % 4]
            )
        }
        guard values.allSatisfy({ abs($0) > .ulpOfOne }) else { return false }
        return values.allSatisfy { $0 > 0 } || values.allSatisfy { $0 < 0 }
    }

    private static func segmentsIntersect(
        _ a: ChekinanaScannerQuadrilateralPoint,
        _ b: ChekinanaScannerQuadrilateralPoint,
        _ c: ChekinanaScannerQuadrilateralPoint,
        _ d: ChekinanaScannerQuadrilateralPoint
    ) -> Bool {
        let first = cross(a, b, c)
        let second = cross(a, b, d)
        let third = cross(c, d, a)
        let fourth = cross(c, d, b)
        return first * second <= 0 && third * fourth <= 0
    }
}

struct ChekinanaRectifiedCheki: Sendable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: ChekinanaDetectedChekiOrientation
    let whiteBalanceApplied: Bool
}

struct ChekinanaPreparedUprightSource: @unchecked Sendable {
    let raster: ChekinanaUprightRGBRaster
    let image: CGImage

    init(raster: ChekinanaUprightRGBRaster) throws {
        self.raster = raster
        image = try raster.makeCGImage()
    }
}

enum ChekinanaFixedBorderWhiteBalanceEstimator {
    static let minimumChannelValue = 140
    static let maximumAverageLinearVariance = 0.001
    static let blockSize = 12
    static let maximumReferenceBlockCount = 10
    static let minimumValidPixelRatioExclusive = 0.8
    private static let proxyShortEdge = 300
    private static let proxyLongEdge = 477
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    // WB statistics use this dedicated context so iOS and macOS use the same
    // high-quality downsampling policy without changing the main render pipeline.
    private static let proxyImageContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: outputColorSpace,
        .highQualityDownsample: true,
        .cacheIntermediates: false,
    ])
    private static let sRGBToLinearLUT: [Double] = (0...255).map {
        sRGBToLinear(Double($0) / 255)
    }

    struct ReferenceBlock: Equatable, Sendable {
        let mean: SIMD3<Double>
        let averageLinearVariance: Double
        let brightness: Double
        let x: Int
        let y: Int
        let validPixels: Int
    }

    struct Estimate: Equatable, Sendable {
        let gain: SIMD3<Double>
        let reference: SIMD3<Double>
        let candidateCount: Int
        let eligibleCount: Int
        let selectedBlocks: [ReferenceBlock]
    }

    static func estimate(
        from source: CIImage,
        orientation: ChekinanaDetectedChekiOrientation
    ) -> Estimate? {
        let width = orientation == .landscape ? proxyLongEdge : proxyShortEdge
        let height = orientation == .landscape ? proxyShortEdge : proxyLongEdge
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let proxy = source.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / source.extent.width,
            y: CGFloat(height) / source.extent.height
        )).cropped(to: rect)
        guard let proxyImage = proxyImageContext.createCGImage(
            proxy,
            from: rect,
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else {
            return nil
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        context.draw(proxyImage, in: rect)

        let analysis = analyze(
            pixels: pixels,
            width: width,
            height: height,
            orientation: orientation
        )
        let estimate = analysis.estimate
        guard let estimate else {
            return nil
        }
        return estimate
    }

    static func estimate(
        pixels: [UInt8],
        width: Int,
        height: Int,
        orientation: ChekinanaDetectedChekiOrientation
    ) -> Estimate? {
        analyze(
            pixels: pixels,
            width: width,
            height: height,
            orientation: orientation
        ).estimate
    }

    private static func analyze(
        pixels: [UInt8],
        width: Int,
        height: Int,
        orientation: ChekinanaDetectedChekiOrientation
    ) -> (estimate: Estimate?, candidateCount: Int, eligibleCount: Int) {
        let expectedWidth = orientation == .landscape ? proxyLongEdge : proxyShortEdge
        let expectedHeight = orientation == .landscape ? proxyShortEdge : proxyLongEdge
        guard width == expectedWidth,
              height == expectedHeight,
              pixels.count == width * height * 4 else { return (nil, 0, 0) }
        let brightThreshold = sRGBToLinearLUT[minimumChannelValue]
        let blockPixelCount = blockSize * blockSize
        var blocks: [ReferenceBlock] = []
        for y in stride(from: 0, through: height - blockSize, by: blockSize) {
            for x in stride(from: 0, through: width - blockSize, by: blockSize) {
                var count = 0
                var sum = SIMD3<Double>(repeating: 0)
                var squareSum = SIMD3<Double>(repeating: 0)
                for blockY in y..<(y + blockSize) {
                    for blockX in x..<(x + blockSize) {
                        guard isFixedWhiteBorder(
                            x: blockX,
                            y: blockY,
                            width: width,
                            height: height,
                            orientation: orientation
                        ) else { continue }
                        let offset = (blockY * width + blockX) * 4
                        let linear = SIMD3<Double>(
                            sRGBToLinearLUT[Int(pixels[offset])],
                            sRGBToLinearLUT[Int(pixels[offset + 1])],
                            sRGBToLinearLUT[Int(pixels[offset + 2])]
                        )
                        guard linear.x > brightThreshold,
                              linear.y > brightThreshold,
                              linear.z > brightThreshold else { continue }
                        count += 1
                        sum += linear
                        squareSum += linear * linear
                    }
                }
                guard Double(count) / Double(blockPixelCount)
                        > minimumValidPixelRatioExclusive else { continue }
                let divisor = Double(count)
                let mean = sum / divisor
                let channelVariances = squareSum / divisor - mean * mean
                let averageVariance = max(
                    0,
                    (channelVariances.x + channelVariances.y + channelVariances.z) / 3
                )
                blocks.append(ReferenceBlock(
                    mean: mean,
                    averageLinearVariance: averageVariance,
                    brightness: (mean.x + mean.y + mean.z) / 3,
                    x: x,
                    y: y,
                    validPixels: count
                ))
            }
        }
        return (
            estimate(referenceBlocks: blocks),
            blocks.count,
            blocks.filter {
                $0.averageLinearVariance <= maximumAverageLinearVariance
            }.count
        )
    }

    static func estimate(referenceBlocks: [ReferenceBlock]) -> Estimate? {
        let eligible = referenceBlocks.filter {
            $0.averageLinearVariance <= maximumAverageLinearVariance
        }
        let selected = Array(eligible.sorted {
            if $0.brightness != $1.brightness {
                return $0.brightness > $1.brightness
            }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.x < $1.x
        }.prefix(maximumReferenceBlockCount))
        guard !selected.isEmpty else { return nil }
        let reference = selected.reduce(SIMD3<Double>(repeating: 0)) {
            $0 + $1.mean
        } / Double(selected.count)
        let target = sRGBToLinear(240.0 / 255)
        return Estimate(
            gain: SIMD3<Double>(
                target / max(reference.x, 0.000_001),
                target / max(reference.y, 0.000_001),
                target / max(reference.z, 0.000_001)
            ),
            reference: reference,
            candidateCount: referenceBlocks.count,
            eligibleCount: eligible.count,
            selectedBlocks: selected
        )
    }

    private static func isFixedWhiteBorder(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        orientation: ChekinanaDetectedChekiOrientation
    ) -> Bool {
        let normalizedX = Double(x) / Double(width)
        let normalizedY = Double(y) / Double(height)
        let isInsideImageArea: Bool
        switch orientation {
        case .portrait:
            isInsideImageArea = normalizedX >= 82.0 / 1_200
                && normalizedX <= 1_118.0 / 1_200
                && normalizedY >= 150.0 / 1_908
                && normalizedY <= 1_533.0 / 1_908
        case .landscape:
            isInsideImageArea = normalizedX >= (1_908.0 - 1_533.0) / 1_908
                && normalizedX <= (1_908.0 - 150.0) / 1_908
                && normalizedY >= 82.0 / 1_200
                && normalizedY <= 1_118.0 / 1_200
        }
        return !isInsideImageArea
    }

    private static func sRGBToLinear(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped <= 0.04045
            ? clamped / 12.92
            : pow((clamped + 0.055) / 1.055, 2.4)
    }
}

enum ChekinanaRectificationPostprocessing: Equatable, Sendable {
    case standard
    case perspectiveOnly
}

enum ChekinanaEdgeFitRectifier {
    static let portraitWidth = 1_200
    static let portraitHeight = 1_908
    static let whiteBalanceMinimumChannelValue =
        ChekinanaFixedBorderWhiteBalanceEstimator.minimumChannelValue
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private static let imageContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: outputColorSpace,
        .cacheIntermediates: false,
    ])

    static func rectify(
        sourceData: Data,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint],
        size: ChekiSize = .mini,
        appliesWhiteBalance: Bool = true,
        postprocessing: ChekinanaRectificationPostprocessing = .standard
    ) async throws -> ChekinanaRectifiedCheki {
        let raster = try ChekinanaUprightRGBRaster.decode(sourceData)
        return try await rectify(
            source: ChekinanaPreparedUprightSource(raster: raster),
            quadrilateral: quadrilateral,
            size: size,
            appliesWhiteBalance: appliesWhiteBalance,
            postprocessing: postprocessing
        )
    }

    static func rectify(
        source: ChekinanaPreparedUprightSource,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint],
        size: ChekiSize = .mini,
        appliesWhiteBalance: Bool = true,
        postprocessing: ChekinanaRectificationPostprocessing = .standard
    ) async throws -> ChekinanaRectifiedCheki {
        let task = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Task.checkCancellation()
                let sourceImage = source.image
                let points = try ChekinanaEdgeFitGeometry.validated(
                    quadrilateral,
                    sourcePixelWidth: sourceImage.width,
                    sourcePixelHeight: sourceImage.height
                )
                let orientation = try ChekinanaEdgeFitGeometry.orientation(of: points)
                let target = ChekinanaImportedChekiCanvasPolicy.dimensions(
                    inferredSize: size,
                    isLandscape: orientation == .landscape
                )
                let sourceHeight = CGFloat(sourceImage.height)
                func ciPoint(_ point: ChekinanaScannerQuadrilateralPoint) -> CIVector {
                    CIVector(x: point.x, y: Double(sourceHeight) - point.y)
                }
                // The delivered schema permits corners outside the original
                // pixel extent. Clamp repeats the nearest edge pixel so every
                // out-of-bounds sample follows one deterministic policy rather
                // than becoming transparent/black.
                let input = CIImage(cgImage: sourceImage).clampedToExtent()
                guard let filter = CIFilter(
                    name: "CIPerspectiveCorrection",
                    parameters: [
                        "inputImage": input,
                        "inputTopLeft": ciPoint(points[0]),
                        "inputTopRight": ciPoint(points[1]),
                        "inputBottomRight": ciPoint(points[2]),
                        "inputBottomLeft": ciPoint(points[3]),
                    ]
                ), let corrected = filter.outputImage,
                   corrected.extent.width.isFinite,
                   corrected.extent.height.isFinite,
                   corrected.extent.width > 0,
                   corrected.extent.height > 0 else {
                    throw ChekinanaOnDeviceScannerError.rectificationFailed
                }
                let normalized = corrected.transformed(
                    by: CGAffineTransform(
                        translationX: -corrected.extent.minX,
                        y: -corrected.extent.minY
                    )
                )
                let scaled = normalized.transformed(
                    by: CGAffineTransform(
                        scaleX: CGFloat(target.width) / normalized.extent.width,
                        y: CGFloat(target.height) / normalized.extent.height
                    )
                ).cropped(to: CGRect(
                    x: 0,
                    y: 0,
                    width: target.width,
                    height: target.height
                ))
                let gains = appliesWhiteBalance && postprocessing == .standard
                    ? ChekinanaFixedBorderWhiteBalanceEstimator.estimate(
                        from: scaled,
                        orientation: orientation
                    )?.gain
                    : nil
                var rendered = scaled
                if let gains {
                    rendered = rendered.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: gains.x, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: gains.y, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: gains.z, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    ])
                }
                if postprocessing == .standard {
                    rendered = ChekinanaScannerPostprocessor
                        .applyingFixedDenoise(to: rendered)
                }
                guard let output = imageContext.createCGImage(
                    rendered,
                    from: scaled.extent,
                    format: .RGBA8,
                    colorSpace: outputColorSpace
                ), let data = jpegData(output) else {
                    throw ChekinanaOnDeviceScannerError.rectificationFailed
                }
                try Task.checkCancellation()
                return ChekinanaRectifiedCheki(
                    data: data,
                    pixelWidth: target.width,
                    pixelHeight: target.height,
                    orientation: orientation,
                    whiteBalanceApplied: gains != nil
                )
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Keeps the complete clean source for Review's final perspective pass.
    /// The quadrilateral is scaled into the source's upright coordinates; no
    /// crop, padding, annotation overlay, or provisional Mini pixels are
    /// retained.
    static func makeReviewRectificationSource(
        sourceData: Data,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint],
        appliesWhiteBalance: Bool
    ) async -> ChekinanaReviewRectificationSource? {
        await makeReviewRectificationSource(
            sourceImage: ChekinanaSharedReviewSourceImage(data: sourceData),
            sourcePixelWidth: sourcePixelWidth,
            sourcePixelHeight: sourcePixelHeight,
            quadrilateral: quadrilateral,
            appliesWhiteBalance: appliesWhiteBalance
        )
    }

    static func makeReviewRectificationSource(
        sourceImage: ChekinanaSharedReviewSourceImage,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint],
        appliesWhiteBalance: Bool
    ) async -> ChekinanaReviewRectificationSource? {
        let task = Task.detached(priority: .utility) { () -> ChekinanaReviewRectificationSource? in
            guard !Task.isCancelled,
                  sourcePixelWidth > 0,
                  sourcePixelHeight > 0,
                  quadrilateral.count == 4,
                  !sourceImage.data.isEmpty,
                  sourceImage.data.count
                    <= ChekinanaLiveScannerUploadPreparer.maximumInputBytes,
                  let dimensions = ChekinanaImagePixelGeometry.uprightDimensions(
                    in: sourceImage.data
                  ), !Task.isCancelled else { return nil }
            let scaleX = Double(dimensions.width) / Double(sourcePixelWidth)
            let scaleY = Double(dimensions.height) / Double(sourcePixelHeight)
            let source = ChekinanaReviewRectificationSource(
                sourceImage: sourceImage,
                sourcePixelWidth: dimensions.width,
                sourcePixelHeight: dimensions.height,
                quadrilateral: quadrilateral.map {
                    ChekinanaScannerQuadrilateralPoint(
                        x: $0.x * scaleX,
                        y: $0.y * scaleY
                    )
                },
                appliesWhiteBalance: appliesWhiteBalance
            )
            return source.isValid ? source : nil
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func makeReviewRectificationSource(
        sourceData: Data,
        source: ChekinanaPreparedUprightSource,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint],
        appliesWhiteBalance: Bool
    ) -> ChekinanaReviewRectificationSource? {
        guard quadrilateral.count == 4,
              !sourceData.isEmpty,
              sourceData.count <= ChekinanaLiveScannerUploadPreparer.maximumInputBytes else {
            return nil
        }
        let result = ChekinanaReviewRectificationSource(
            sourceImage: ChekinanaSharedReviewSourceImage(data: sourceData),
            sourcePixelWidth: source.raster.width,
            sourcePixelHeight: source.raster.height,
            quadrilateral: quadrilateral,
            appliesWhiteBalance: appliesWhiteBalance
        )
        return result.isValid ? result : nil
    }

    static func makeReviewRectificationSource(
        sourceImage: ChekinanaSharedReviewSourceImage,
        source: ChekinanaPreparedUprightSource,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint],
        appliesWhiteBalance: Bool
    ) -> ChekinanaReviewRectificationSource? {
        guard quadrilateral.count == 4,
              !sourceImage.data.isEmpty,
              sourceImage.data.count
                <= ChekinanaLiveScannerUploadPreparer.maximumInputBytes else {
            return nil
        }
        let result = ChekinanaReviewRectificationSource(
            sourceImage: sourceImage,
            sourcePixelWidth: source.raster.width,
            sourcePixelHeight: source.raster.height,
            quadrilateral: quadrilateral,
            appliesWhiteBalance: appliesWhiteBalance
        )
        return result.isValid ? result : nil
    }

    static func uprightPixelDimensions(
        in data: Data
    ) throws -> (width: Int, height: Int) {
        let image = try uprightImage(from: data)
        return (image.width, image.height)
    }

    static func annotationPreviewData(from sourceData: Data) async -> Data? {
        let task = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled else { return nil }
            guard let preview = try? uprightImage(
                from: sourceData,
                maximumPixelDimension: ChekinanaLiveScannerUploadPreparer
                    .maximumAnnotationPreviewDimension
            ), !Task.isCancelled else { return nil }
            // The source is photographic. JPEG avoids the large transient and
            // final buffers produced by PNG when several inputs complete at
            // once; the orange overlay is encoded separately after drawing.
            return jpegData(preview)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func annotationPreviewData(
        from source: ChekinanaPreparedUprightSource
    ) async -> Data? {
        let task = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled else { return nil }
            let maximum = ChekinanaLiveScannerUploadPreparer.maximumAnnotationPreviewDimension
            let scale = min(
                1,
                CGFloat(maximum) / CGFloat(max(source.image.width, source.image.height))
            )
            let width = max(1, Int((CGFloat(source.image.width) * scale).rounded()))
            let height = max(1, Int((CGFloat(source.image.height) * scale).rounded()))
            if width == source.image.width, height == source.image.height {
                return jpegData(source.image)
            }
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: outputColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(source.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard !Task.isCancelled, let image = context.makeImage() else { return nil }
            return jpegData(image)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func uprightImage(
        from data: Data,
        maximumPixelDimension: Int? = nil
    ) throws -> CGImage {
        guard !data.isEmpty,
              data.count <= ChekinanaLiveScannerUploadPreparer.maximumInputBytes,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              ChekinanaImageSourceValidator.accepts(
                source: source,
                maxDimension: ChekinanaLiveScannerUploadPreparer.maximumNormalizedDimension
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        let maximumDimension = min(
            max(width, height),
            maximumPixelDimension ?? max(width, height)
        )
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary), image.width > 0, image.height > 0 else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        return image
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        encodedData(image, type: UTType.jpeg.identifier, quality: 0.94)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        encodedData(image, type: UTType.png.identifier, quality: nil)
    }

    private static func encodedData(
        _ image: CGImage,
        type: String,
        quality: Double?
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type as CFString,
            1,
            nil
        ) else { return nil }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }
}

struct ChekinanaOnDeviceScannerClient: Sendable {
    typealias DetectorProvider = @Sendable () throws -> any ChekinanaOnDeviceEdgeDetector

    private let detectorProvider: DetectorProvider

    init(
        detectorProvider: @escaping DetectorProvider = {
            try ChekinanaEdgeDetectorAssetRegistry.productionDetector()
        }
    ) {
        self.detectorProvider = detectorProvider
    }

    init(detector: any ChekinanaOnDeviceEdgeDetector) {
        detectorProvider = { detector }
    }

    enum RefitResult: Sendable {
        case detectionCount(Int)
        case image(ChekinanaScannerResultImage)
    }

    /// Refit uses the published full-resolution clean image as a new source.
    /// Detection shares Scan's execution gate; no remote/OCR/Idol pipeline runs.
    func refit(
        _ image: ChekinanaPendingChekiImage,
        size: ChekiSize
    ) async throws -> RefitResult {
        try await ChekinanaOnDeviceScannerExecutionGate.shared.acquire()
        do {
            let result = try await refitExclusively(image, size: size)
            await ChekinanaOnDeviceScannerExecutionGate.shared.release()
            return result
        } catch {
            await ChekinanaOnDeviceScannerExecutionGate.shared.release()
            throw error
        }
    }

    private func refitExclusively(
        _ image: ChekinanaPendingChekiImage,
        size: ChekiSize
    ) async throws -> RefitResult {
        let detector = try detectorProvider()
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let detection = try await detector.detect(image)
            try Task.checkCancellation()
            guard detection.quadrilaterals.count == 1 else {
                if attempt == 1 {
                    return .detectionCount(detection.quadrilaterals.count)
                }
                // Leave this iteration's decoded raster behind before retrying
                // the same encoded input. A count mismatch alone is retryable.
                continue
            }
            return try await rectifyRefit(image, detection: detection, size: size)
        }
        throw ChekinanaOnDeviceScannerError.modelOutputInvalid
    }

    private func rectifyRefit(
        _ image: ChekinanaPendingChekiImage,
        detection: ChekinanaEdgeDetectorOutput,
        size: ChekiSize
    ) async throws -> RefitResult {
        let raster = try detection.decodedSource
            ?? ChekinanaUprightRGBRaster.decode(image.data)
        guard detection.sourcePixelWidth == raster.width,
              detection.sourcePixelHeight == raster.height else {
            throw ChekinanaOnDeviceScannerError.sourceGeometryMismatch
        }
        let quad = try ChekinanaEdgeFitGeometry.validated(
            detection.quadrilaterals[0],
            sourcePixelWidth: raster.width,
            sourcePixelHeight: raster.height
        )
        let source = try ChekinanaPreparedUprightSource(raster: raster)
        let rectified = try await ChekinanaEdgeFitRectifier.rectify(
            source: source,
            quadrilateral: quad,
            size: size,
            appliesWhiteBalance: false,
            postprocessing: .perspectiveOnly
        )
        try Task.checkCancellation()
        let reviewSource = ChekinanaReviewRectificationSource(
            imageData: image.data,
            sourcePixelWidth: raster.width,
            sourcePixelHeight: raster.height,
            quadrilateral: quad,
            appliesWhiteBalance: false,
            postprocessing: .perspectiveOnly
        )
        guard reviewSource.isValid else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        return .image(ChekinanaScannerResultImage(
            data: rectified.data,
            imagePixelWidth: rectified.pixelWidth,
            imagePixelHeight: rectified.pixelHeight,
            filenameExtension: "jpg",
            dateAnnotationState: .unavailable,
            sourceAnnotation: ChekinanaScannerSourceAnnotation(
                sourcePixelWidth: raster.width,
                sourcePixelHeight: raster.height,
                quadrilateral: quad
            ),
            reviewRectificationSource: reviewSource,
            inferredChekiSize: size
        ))
    }

    func process(
        _ image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions,
        progressObserver: ChekinanaCommandExecutor.ScannerStatusObserver? = nil,
        resultObserver: ChekinanaCommandExecutor.ScannerResultObserver? = nil
    ) async throws -> ChekinanaScannerProcessResult {
        try await ChekinanaOnDeviceScannerExecutionGate.shared.acquire()
        do {
            let result: ChekinanaScannerProcessResult
            do {
                result = try await processExclusively(
                    image,
                    options: options,
                    progressObserver: progressObserver,
                    resultObserver: resultObserver
                )
            } catch ChekinanaOnDeviceScannerError.noResults {
                // A zero-result Scan gets one quiet retry with the same input
                // and processing options. Other errors and Refit are separate.
                try Task.checkCancellation()
                result = try await processExclusively(
                    image,
                    options: options,
                    progressObserver: progressObserver,
                    resultObserver: resultObserver
                )
            }
            await ChekinanaOnDeviceScannerExecutionGate.shared.release()
            return result
        } catch {
            await ChekinanaOnDeviceScannerExecutionGate.shared.release()
            throw error
        }
    }

    private func processExclusively(
        _ image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions,
        progressObserver: ChekinanaCommandExecutor.ScannerStatusObserver?,
        resultObserver: ChekinanaCommandExecutor.ScannerResultObserver?
    ) async throws -> ChekinanaScannerProcessResult {
        let detector = try detectorProvider()
        await progressObserver?(ChekinanaScannerTaskProgress(
            phase: "detecting_on_device",
            publishedResultCount: 0,
            downloadedResultCount: 0,
            expectedPolaroids: options.expectedPolaroids,
            extractionComplete: false
        ))
        let detection = try await detector.detect(image)
        try Task.checkCancellation()
        let raster = try detection.decodedSource
            ?? ChekinanaUprightRGBRaster.decode(image.data)
        let preparedSource = try ChekinanaPreparedUprightSource(raster: raster)
        let dimensions = (width: raster.width, height: raster.height)
        guard detection.sourcePixelWidth == raster.width,
              detection.sourcePixelHeight == raster.height else {
            throw ChekinanaOnDeviceScannerError.sourceGeometryMismatch
        }
        let quads = try ChekinanaEdgeFitGeometry.sortedByCenter(
            detection.quadrilaterals.map {
                try ChekinanaEdgeFitGeometry.validated(
                    $0,
                    sourcePixelWidth: dimensions.width,
                    sourcePixelHeight: dimensions.height
                )
            }
        )
        guard !quads.isEmpty else { throw ChekinanaOnDeviceScannerError.noResults }
        try Task.checkCancellation()
        let sharedReviewSourceImage = ChekinanaSharedReviewSourceImage(data: image.data)
        var results: [ChekinanaScannerResultImage] = []
        results.reserveCapacity(quads.count)
        for (index, quad) in quads.enumerated() {
            try Task.checkCancellation()
            let rectified = try await ChekinanaEdgeFitRectifier.rectify(
                source: preparedSource,
                quadrilateral: quad,
                appliesWhiteBalance: options.whiteBalance
            )
            let reviewRectificationSource = ChekinanaEdgeFitRectifier
                .makeReviewRectificationSource(
                    sourceImage: sharedReviewSourceImage,
                    source: preparedSource,
                    quadrilateral: quad,
                    appliesWhiteBalance: options.whiteBalance
                )
            try Task.checkCancellation()
            let sourceAnnotation = ChekinanaScannerSourceAnnotation(
                sourcePixelWidth: dimensions.width,
                sourcePixelHeight: dimensions.height,
                quadrilateral: quad
            )
            let result = ChekinanaScannerResultImage(
                data: rectified.data,
                imagePixelWidth: rectified.pixelWidth,
                imagePixelHeight: rectified.pixelHeight,
                filenameExtension: "jpg",
                dateAnnotationState: .notRequested,
                sourceAnnotation: sourceAnnotation,
                reviewRectificationSource: reviewRectificationSource,
                inferredChekiSize: .mini
            )
            results.append(result)
            try Task.checkCancellation()
            await resultObserver?(index, result)
            await progressObserver?(ChekinanaScannerTaskProgress(
                phase: "extracting_on_device",
                publishedResultCount: quads.count,
                downloadedResultCount: results.count,
                expectedPolaroids: options.expectedPolaroids,
                extractionComplete: results.count == quads.count
            ))
        }
        let warningCount = options.expectedPolaroids.map { $0 == results.count ? 0 : 1 } ?? 0
        return ChekinanaScannerProcessResult(
            images: results,
            warningCount: warningCount
        )
    }
}

/// The frozen Core ML calls already serialize on their shared model instances.
/// Letting multiple source images simultaneously enter the large Swift
/// post-processing and Core Image rectification stages only multiplies peak
/// memory and oversubscribes the phone CPU. One local image therefore owns the
/// complete on-device pipeline at a time; each image still uses the detector's
/// bounded internal parallelism.
actor ChekinanaOnDeviceScannerExecutionGate {
    static let shared = ChekinanaOnDeviceScannerExecutionGate()

    private var isAcquired = false

    func acquire() async throws {
        while isAcquired {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        isAcquired = true
    }

    func release() {
        precondition(isAcquired)
        isAcquired = false
    }
}

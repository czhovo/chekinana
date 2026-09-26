import CoreGraphics
import CoreML
import Foundation
import ImageIO

enum ChekinanaEdgeFitRTV2Contract {
    static let displayName = "ChekiEdgeFit-RT v2"
    static let algorithmID = "ChekiEdgeFit-RT"
    static let semanticVersion = "2.0.0"
    static let detectorThreshold: Float = 0.9267578125
    static let modelResourceNames = [
        "CEFRT2Detector",
        "CEFRT2EdgeSAMEncoder",
        "CEFRT2EdgeSAMBoxDecoder",
    ]

    static func uprightPixelDimensions(in data: Data) throws -> (Int, Int) {
        let raster = try ChekinanaUprightRGBRaster.decode(data)
        return (raster.width, raster.height)
    }
}


/// One upright sRGB decode shared by RT-DETR, every EdgeSAM candidate, output
/// geometry, rectification, and annotation rendering.
struct ChekinanaUprightRGBRaster: @unchecked Sendable {
    let width: Int
    let height: Int
    let rgb: [UInt8]

    static func decode(
        _ data: Data
    ) throws -> ChekinanaUprightRGBRaster {
        // Only owned RGBA bytes and scalar dimensions leave this pool. The
        // ImageIO source, its CGImage backing and CGContext are gone before
        // the separate RGB output is allocated.
        let normalized = try autoreleasepool {
            try decodeUprightRGBA(data)
        }
        guard let rgbCount = try? RTV2WorkingSetBudget.validateRGBPacking(
            width: normalized.width,
            height: normalized.height,
            encodedByteCount: data.count,
            rgbaByteCount: normalized.rgba.count
        ) else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        let pixelCount = rgbCount / 3
        var rgb = Array(repeating: UInt8(0), count: rgbCount)
        normalized.rgba.withUnsafeBufferPointer { source in
            rgb.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                for pixel in 0..<pixelCount {
                    destinationBase[pixel * 3] = sourceBase[pixel * 4]
                    destinationBase[pixel * 3 + 1] = sourceBase[pixel * 4 + 1]
                    destinationBase[pixel * 3 + 2] = sourceBase[pixel * 4 + 2]
                }
            }
        }
        return ChekinanaUprightRGBRaster(
            width: normalized.width,
            height: normalized.height,
            rgb: rgb
        )
    }

    private static func decodeUprightRGBA(
        _ data: Data
    ) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        guard !data.isEmpty,
              data.count <= ChekinanaLiveScannerUploadPreparer.maximumInputBytes,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              rawWidth > 0, rawHeight > 0 else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        guard (try? RTV2WorkingSetBudget.validateDecodePreflight(
            width: rawWidth,
            height: rawHeight,
            encodedByteCount: data.count
        )) != nil else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(rawWidth, rawHeight),
            // Thumbnail's documented read options allow deferred decoding;
            // inspect its actual layout before allocating RGBA or rendering.
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary) else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        guard let layout = try? RTV2WorkingSetBudget.validateDecodeLayout(
            width: image.width,
            height: image.height,
            encodedByteCount: data.count,
            imageIOBytesPerRow: image.bytesPerRow,
            imageIOBitsPerPixel: image.bitsPerPixel
        ) else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        var rgba = Array(repeating: UInt8(0), count: layout.rgbaBytes)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rgba,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: layout.rgbaBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (width: image.width, height: image.height, rgba: rgba)
    }

    func makeCGImage() throws -> CGImage {
        let data = Data(rgb)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: width * 3,
                space: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ChekinanaOnDeviceScannerError.invalidSourceImage
        }
        return image
    }
}

final class ChekinanaEdgeFitRTV2Detector: ChekinanaOnDeviceEdgeDetector,
    @unchecked Sendable {
    private let manifest: ChekinanaEdgeDetectorManifest
    private let models: Models

    init(bundle: Bundle = .main) throws {
        guard let manifestURL = bundle.url(
            forResource: "ChekiEdgeFit-RT-v2.manifest",
            withExtension: "json"
        ), let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(
            ChekinanaEdgeDetectorManifest.self,
            from: data
           ), manifest.algorithmID == ChekinanaEdgeFitRTV2Contract.algorithmID,
           manifest.semver == ChekinanaEdgeFitRTV2Contract.semanticVersion,
           manifest.outputSchemaVersion == "1.0.0" else {
            throw ChekinanaOnDeviceScannerError.invalidAssetManifest
        }
        self.manifest = manifest
        models = try Models(bundle: bundle)
    }

    func detect(_ image: ChekinanaPendingChekiImage) async throws
        -> ChekinanaEdgeDetectorOutput {
        let models = models
        let manifest = manifest
        let work = Task.detached(priority: .userInitiated) {
            let source = try ChekinanaUprightRGBRaster.decode(
                image.data
            )
            try Task.checkCancellation()
            let quads = try RTV2Pipeline(models: models).detect(
                source, encodedByteCount: image.data.count
            )
            return ChekinanaEdgeDetectorOutput(
                manifest: manifest,
                sourcePixelWidth: source.width,
                sourcePixelHeight: source.height,
                quadrilaterals: quads,
                decodedSource: source
            )
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

final class ChekinanaEdgeFitRTV2DetectorCache: @unchecked Sendable {
    static let shared = ChekinanaEdgeFitRTV2DetectorCache()
    private let lock = NSLock()
    private var cached: Result<ChekinanaEdgeFitRTV2Detector, Error>?

    func detector() throws -> ChekinanaEdgeFitRTV2Detector {
        try lock.withLock {
            if let cached { return try cached.get() }
            let loaded = Result { try ChekinanaEdgeFitRTV2Detector() }
            cached = loaded
            return try loaded.get()
        }
    }
}

private extension ChekinanaEdgeFitRTV2Detector {
    struct Models: @unchecked Sendable {
        let detector: MLModel
        let edgeEncoder: MLModel
        let edgeDecoder: MLModel

        init(bundle: Bundle) throws {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            configuration.allowLowPrecisionAccumulationOnGPU = false
            detector = try Self.load(
                "CEFRT2Detector",
                bundle: bundle,
                configuration: configuration,
                inputs: ["image": [1, 3, 768, 768]],
                outputs: ["logits": [1, 300], "boxes_cxcywh": [1, 300, 4]]
            )
            edgeEncoder = try Self.load(
                "CEFRT2EdgeSAMEncoder",
                bundle: bundle,
                configuration: configuration,
                inputs: ["image": [1, 3, 1024, 1024]],
                outputs: ["image_embeddings": [1, 256, 64, 64]]
            )
            edgeDecoder = try Self.load(
                "CEFRT2EdgeSAMBoxDecoder",
                bundle: bundle,
                configuration: configuration,
                inputs: ["image_embeddings": [1, 256, 64, 64], "box": [1, 4]],
                outputs: ["mask_logits": [1, 1, 256, 256], "iou_prediction": [1, 1]]
            )
        }

        private static func load(
            _ name: String,
            bundle: Bundle,
            configuration: MLModelConfiguration,
            inputs: [String: [Int]],
            outputs: [String: [Int]]
        ) throws -> MLModel {
            guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
                throw ChekinanaOnDeviceScannerError.modelUnavailable
            }
            do {
                let model = try MLModel(contentsOf: url, configuration: configuration)
                try validate(model.modelDescription.inputDescriptionsByName, against: inputs)
                try validate(model.modelDescription.outputDescriptionsByName, against: outputs)
                return model
            } catch let error as ChekinanaOnDeviceScannerError {
                throw error
            } catch {
                throw ChekinanaOnDeviceScannerError.modelUnavailable
            }
        }

        private static func validate(
            _ descriptions: [String: MLFeatureDescription],
            against contract: [String: [Int]]
        ) throws {
            guard descriptions.count == contract.count else {
                throw ChekinanaOnDeviceScannerError.modelOutputInvalid
            }
            for (name, shape) in contract {
                guard let constraint = descriptions[name]?.multiArrayConstraint,
                      constraint.dataType == .float32,
                      constraint.shape.map(\.intValue) == shape else {
                    throw ChekinanaOnDeviceScannerError.modelOutputInvalid
                }
            }
        }
    }
}

enum RTV2MultiArray {
    static func make(shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: shape.map(NSNumber.init(value:)),
            dataType: .float32
        )
        guard isContiguous(array, shape: shape) else {
            throw ChekinanaOnDeviceScannerError.modelOutputInvalid
        }
        return array
    }

    static func validate(_ array: MLMultiArray, shape: [Int]) throws {
        guard array.dataType == .float32,
              array.shape.map(\.intValue) == shape else {
            throw ChekinanaOnDeviceScannerError.modelOutputInvalid
        }
    }

    static func isContiguous(_ array: MLMultiArray, shape: [Int]) -> Bool {
        var expectedStride = 1
        for dimension in shape.indices.reversed() {
            if shape[dimension] > 1,
               array.strides[dimension].intValue != expectedStride { return false }
            expectedStride *= shape[dimension]
        }
        return true
    }
}

struct RTV2ArrayView {
    let array: MLMultiArray
    let pointer: UnsafeMutablePointer<Float>
    let shape: [Int]
    let strides: [Int]

    init(_ array: MLMultiArray, shape: [Int]) throws {
        try RTV2MultiArray.validate(array, shape: shape)
        self.array = array
        pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        self.shape = shape
        strides = array.strides.map(\.intValue)
    }

    @inline(__always)
    func value(_ indices: Int...) -> Float {
        var offset = 0
        for index in indices.indices { offset += indices[index] * strides[index] }
        return pointer[offset]
    }

    func contiguousValues() -> [Float] {
        if RTV2MultiArray.isContiguous(array, shape: shape) {
            return Array(UnsafeBufferPointer(start: pointer, count: array.count))
        }
        var result = Array(repeating: Float(0), count: shape.reduce(1, *))
        var indices = Array(repeating: 0, count: shape.count)
        for flat in result.indices {
            var remainder = flat
            for dimension in shape.indices.reversed() {
                indices[dimension] = remainder % shape[dimension]
                remainder /= shape[dimension]
            }
            var offset = 0
            for dimension in shape.indices { offset += indices[dimension] * strides[dimension] }
            result[flat] = pointer[offset]
        }
        return result
    }
}

private enum RTV2ModelRunner {
    private static let predictionLock = NSLock()

    static func predict(_ model: MLModel, inputs: [String: MLMultiArray]) throws
        -> MLFeatureProvider {
        do {
            let values = inputs.mapValues(MLFeatureValue.init(multiArray:))
            let provider = try MLDictionaryFeatureProvider(dictionary: values)
            return try predictionLock.withLock {
                try model.prediction(from: provider, options: MLPredictionOptions())
            }
        } catch let error as ChekinanaOnDeviceScannerError {
            throw error
        } catch {
            throw ChekinanaOnDeviceScannerError.detectorRuntimeFailure
        }
    }

    static func output(
        _ provider: MLFeatureProvider,
        name: String,
        shape: [Int]
    ) throws -> MLMultiArray {
        guard let array = provider.featureValue(for: name)?.multiArrayValue else {
            throw ChekinanaOnDeviceScannerError.modelOutputInvalid
        }
        try RTV2MultiArray.validate(array, shape: shape)
        return array
    }
}

private struct RTV2Box: Sendable {
    let queryID: Int
    let score: Float
    let x1: Float
    let y1: Float
    let x2: Float
    let y2: Float
}

private struct RTV2Letterbox {
    let input: MLMultiArray
    let scale: Float
    let left: Float
    let top: Float
}

private struct RTV2Pipeline {
    let models: ChekinanaEdgeFitRTV2Detector.Models

    private static let detectorNormalizationLookup: [[Float]] = {
        let mean: [Float] = [0.485, 0.456, 0.406]
        let deviation: [Float] = [0.229, 0.224, 0.225]
        return (0..<3).map { channel in
            (0..<256).map { byte in
                (Float(byte) / 255 - mean[channel]) / deviation[channel]
            }
        }
    }()

    func detect(_ source: ChekinanaUprightRGBRaster, encodedByteCount: Int) throws
        -> [[ChekinanaScannerQuadrilateralPoint]] {
        try RTV2WorkingSetBudget.validateDetectorPreprocessing(
            width: source.width, height: source.height,
            encodedByteCount: encodedByteCount, sourceRGBStorageBytes: source.rgb.capacity
        )
        let prepared = try detectorInput(source)
        try Task.checkCancellation()
        let result = try RTV2ModelRunner.predict(models.detector, inputs: ["image": prepared.input])
        let logits = try RTV2ArrayView(
            RTV2ModelRunner.output(result, name: "logits", shape: [1, 300]),
            shape: [1, 300]
        )
        let boxes = try RTV2ArrayView(
            RTV2ModelRunner.output(result, name: "boxes_cxcywh", shape: [1, 300, 4]),
            shape: [1, 300, 4]
        )
        var candidates: [RTV2Box] = []
        candidates.reserveCapacity(8)
        for queryID in 0..<300 {
            let score = sigmoid(logits.value(0, queryID))
            guard score >= ChekinanaEdgeFitRTV2Contract.detectorThreshold else { continue }
            let centerX = boxes.value(0, queryID, 0) * Float(768)
            let centerY = boxes.value(0, queryID, 1) * Float(768)
            let width = boxes.value(0, queryID, 2) * Float(768)
            let height = boxes.value(0, queryID, 3) * Float(768)
            let candidate = RTV2Box(
                queryID: queryID,
                score: score,
                x1: (centerX - width * Float(0.5) - prepared.left) / prepared.scale,
                y1: (centerY - height * Float(0.5) - prepared.top) / prepared.scale,
                x2: (centerX + width * Float(0.5) - prepared.left) / prepared.scale,
                y2: (centerY + height * Float(0.5) - prepared.top) / prepared.scale
            )
            guard [candidate.x1, candidate.y1, candidate.x2, candidate.y2]
                .allSatisfy(\.isFinite) else {
                throw ChekinanaOnDeviceScannerError.modelOutputInvalid
            }
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else { return [] }
        // Candidate execution is deliberately serial. Core ML prediction is
        // synchronous, so these fully-overwritten input buffers can be reused
        // after each prediction returns instead of reallocating ~12 MiB per ROI.
        let encoderInput = try RTV2MultiArray.make(shape: [1, 3, 1024, 1024])
        let prompt = try RTV2MultiArray.make(shape: [1, 4])
        var output: [[ChekinanaScannerQuadrilateralPoint]] = []
        output.reserveCapacity(candidates.count)
        for candidate in candidates {
            try Task.checkCancellation()
            let quadrilateral = try autoreleasepool {
                try edgeQuadrilateral(
                    source: source,
                    box: candidate,
                    encoderInput: encoderInput,
                    prompt: prompt,
                    encodedByteCount: encodedByteCount
                )
            }
            if let quadrilateral { output.append(quadrilateral) }
        }
        return output
    }

    private func detectorInput(_ source: ChekinanaUprightRGBRaster) throws
        -> RTV2Letterbox {
        let resizeScale = min(
            Double(768) / Double(source.width),
            Double(768) / Double(source.height)
        )
        let scale = Float(resizeScale)
        let resizedWidth = max(1, Int((Double(source.width) * resizeScale).rounded(.toNearestOrEven)))
        let resizedHeight = max(1, Int((Double(source.height) * resizeScale).rounded(.toNearestOrEven)))
        let left = (768 - resizedWidth) / 2
        let top = (768 - resizedHeight) / 2
        let resized = ChekinanaEdgeFitRTV2ReferenceMath.openCVAreaResizeRGB(
            source.rgb,
            width: source.width,
            height: source.height,
            outputWidth: resizedWidth,
            outputHeight: resizedHeight
        )
        let input = try RTV2MultiArray.make(shape: [1, 3, 768, 768])
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        let lookup = Self.detectorNormalizationLookup
        for channel in 0..<3 {
            (pointer + channel * 768 * 768).initialize(
                repeating: lookup[channel][0],
                count: 768 * 768
            )
        }
        resized.withUnsafeBufferPointer { sourceBuffer in
            guard let sourceBase = sourceBuffer.baseAddress else { return }
            for y in 0..<resizedHeight {
                for x in 0..<resizedWidth {
                    let sourceOffset = (y * resizedWidth + x) * 3
                    let targetPixel = (y + top) * 768 + x + left
                    pointer[targetPixel] = lookup[0][Int(sourceBase[sourceOffset])]
                    pointer[768 * 768 + targetPixel] = lookup[1][Int(sourceBase[sourceOffset + 1])]
                    pointer[2 * 768 * 768 + targetPixel] = lookup[2][Int(sourceBase[sourceOffset + 2])]
                }
            }
        }
        return RTV2Letterbox(input: input, scale: scale, left: Float(left), top: Float(top))
    }

    private func edgeQuadrilateral(
        source: ChekinanaUprightRGBRaster,
        box: RTV2Box,
        encoderInput: MLMultiArray,
        prompt: MLMultiArray,
        encodedByteCount: Int
    ) throws -> [ChekinanaScannerQuadrilateralPoint]? {
        // Only scalar crop geometry leaves this scope; the streamed Float
        // output and its sampling scratch end before model/mask processing.
        let crop = try autoreleasepool {
            let resizedCrop = try ChekinanaEdgeFitRTV2ReferenceMath
                .streamingSquare20PillowResizeFP32(
                source.rgb,
                width: source.width,
                height: source.height,
                box: [box.x1, box.y1, box.x2, box.y2],
                borderRGB: [123.675, 116.28, 103.53],
                outputSide: 1024,
                encodedByteCount: encodedByteCount
            )
            let crop = resizedCrop.crop
            try writeEncoderInput(resizedCrop.pixels, to: encoderInput)
            return crop
        }
        let budget = try RTV2WorkingSetBudget.validateCandidate(
            sourceWidth: source.width, sourceHeight: source.height,
            cropSide: crop.side, encodedByteCount: encodedByteCount,
            sourceRGBStorageBytes: source.rgb.capacity
        )
        // Returned model values and 1024 mask interpolation scratch are local
        // to this scope. Fitting retains only the packed mask.
        let mask = try autoreleasepool {
            let encoderResult = try RTV2ModelRunner.predict(
                models.edgeEncoder,
                inputs: ["image": encoderInput]
            )
            let embedding = try RTV2ModelRunner.output(
                encoderResult,
                name: "image_embeddings",
                shape: [1, 256, 64, 64]
            )
            let promptPointer = prompt.dataPointer.assumingMemoryBound(to: Float.self)
            let transformedX1 = (box.x1 - crop.sourceMinimumX) * crop.forwardScaleX
            let transformedY1 = (box.y1 - crop.sourceMinimumY) * crop.forwardScaleY
            let transformedX2 = (box.x2 - crop.sourceMinimumX) * crop.forwardScaleX
            let transformedY2 = (box.y2 - crop.sourceMinimumY) * crop.forwardScaleY
            let promptScale = Float(1024) / Float(crop.side)
            promptPointer[0] = min(transformedX1, transformedX2) * promptScale
            promptPointer[1] = min(transformedY1, transformedY2) * promptScale
            promptPointer[2] = max(transformedX1, transformedX2) * promptScale
            promptPointer[3] = max(transformedY1, transformedY2) * promptScale
            let decoderResult = try RTV2ModelRunner.predict(
                models.edgeDecoder,
                inputs: ["image_embeddings": embedding, "box": prompt]
            )
            _ = try RTV2ModelRunner.output(
                decoderResult,
                name: "iou_prediction",
                shape: [1, 1]
            )
            let maskView = try RTV2ArrayView(
                RTV2ModelRunner.output(
                    decoderResult,
                    name: "mask_logits",
                    shape: [1, 1, 256, 256]
                ),
                shape: [1, 1, 256, 256]
            )
            return try restoreMask(maskView.contiguousValues(), outputSide: crop.side, capacityBudget: budget)
        }
        let cropQuad: [RTV2Point]
        do {
            cropQuad = try RTV2QuadrilateralFitter.fit(
                mask: mask, pointLimit: budget.contourPointLimit,
                queueCapacity: budget.traversalQueueCapacity, capacityBudget: budget
            )
        } catch {
            return nil
        }
        let mapped = ChekinanaEdgeFitRTV2ReferenceMath.restoreCropPointsFP64(
            cropQuad,
            crop: crop
        ).map { point -> RTV2Point in
            let x = point.x * 1_000_000
            let y = point.y * 1_000_000
            return RTV2Point(
                x: x.rounded() / 1_000_000,
                y: y.rounded() / 1_000_000
            )
        }
        guard let result = try? RTV2QuadrilateralCanonicalizer
            .canonicalTLTRBRBL(mapped).map({ point in
                ChekinanaScannerQuadrilateralPoint(x: point.x, y: point.y)
            }) else {
            return nil
        }
        return result
    }

    private func writeEncoderInput(
        _ resizedPixels: [Float],
        to input: MLMultiArray
    ) throws {
        try RTV2MultiArray.validate(input, shape: [1, 3, 1024, 1024])
        guard RTV2MultiArray.isContiguous(input, shape: [1, 3, 1024, 1024]) else {
            throw ChekinanaOnDeviceScannerError.modelOutputInvalid
        }
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        let mean: [Float] = [123.675, 116.28, 103.53]
        let deviation: [Float] = [58.395, 57.12, 57.375]
        let expectedCount = try RTV2WorkingSetBudget.checkedProduct([1024, 1024, 3])
        guard resizedPixels.count == expectedCount else {
            throw ChekinanaOnDeviceScannerError.modelOutputInvalid
        }
        resizedPixels.withUnsafeBufferPointer { values in
            guard let sourceBase = values.baseAddress else { return }
            for y in 0..<1024 {
                for x in 0..<1024 {
                    for channel in 0..<3 {
                        let total = sourceBase[(y * 1024 + x) * 3 + channel]
                        pointer[channel * 1024 * 1024 + y * 1024 + x]
                            = (total - mean[channel]) / deviation[channel]
                    }
                }
            }
        }
    }

    private func restoreMask(
        _ logits: [Float], outputSide: Int, capacityBudget: RTV2WorkingSetBudget.Estimate
    ) throws -> RTV2BinaryMask {
        let full = ChekinanaEdgeFitRTV2ReferenceMath.resizeAlignCornersFalse(
            logits,
            width: 256,
            height: 256,
            outputWidth: 1024,
            outputHeight: 1024
        )
        try RTV2WorkingSetBudget.validateFixedCapacity(
            count: full.count, capacity: full.capacity, stride: MemoryLayout<Float>.stride
        )
        return try ChekinanaEdgeFitRTV2ReferenceMath
            .resizeAlignCornersFalseAndThresholdMask(
            full,
            width: 1024,
            height: 1024,
            outputWidth: outputSide,
            outputHeight: outputSide,
            capacityBudget: capacityBudget
        )
    }

    @inline(__always)
    private func sigmoid(_ value: Float) -> Float {
        if value >= 0 {
            let z = exp(-value)
            return 1 / (1 + z)
        }
        let z = exp(value)
        return z / (1 + z)
    }
}

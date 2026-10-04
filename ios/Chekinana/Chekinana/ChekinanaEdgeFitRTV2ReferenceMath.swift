import Foundation

/// Deterministic, host-testable glue matching the frozen Pillow 12.2.0 and
/// NumPy 1.23.5 portions of the ChekiEdgeFit-RT v2 reference implementation.
enum ChekinanaEdgeFitRTV2ReferenceMath {
    private static let pillowPrecisionBits = 22
    private static let openCVResizeCoefficientBits = 11
    private static let openCVWarpInterpolationBits = 5
    private static let openCVWarpCoefficientBits = 15

    struct OpenCVSquareCrop: Sendable {
        let bytes: [UInt8]
        let side: Int
        let sourceMinimumX: Float
        let sourceMinimumY: Float
        let sourceWidth: Float
        let sourceHeight: Float
    }

    struct FP32SquareCrop: Sendable {
        let pixels: [Float]
        let side: Int
        let sourceMinimumX: Float
        let sourceMinimumY: Float
        let sourceWidth: Float
        let sourceHeight: Float
        let forwardScaleX: Float
        let forwardScaleY: Float
    }

    struct FP32SquareGeometry: Sendable {
        let side: Int
        let sourceMinimumX: Float
        let sourceMinimumY: Float
        let sourceWidth: Float
        let sourceHeight: Float
        let forwardScaleX: Float
        let forwardScaleY: Float
    }

    struct FP32SquareResize: Sendable {
        let pixels: [Float]
        let crop: FP32SquareGeometry
        let maximumCachedRows: Int
    }

    /// Pillow F-mode bilinear resize for one float channel. Unlike the RGB8
    /// helper below, no fixed-point coefficient quantization or UInt8 clipping
    /// is applied between the separable passes.
    @_optimize(speed)
    static func pillowBilinearResizeFloat(
        _ values: [Float],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> [Float] {
        precondition(values.count == width * height)
        let xKernels = pillowFloatBilinearCoefficients(
            inputSize: width,
            outputSize: outputWidth
        )
        let yKernels = pillowFloatBilinearCoefficients(
            inputSize: height,
            outputSize: outputHeight
        )
        var horizontal = Array(repeating: Float(0), count: height * outputWidth)
        values.withUnsafeBufferPointer { source in
            horizontal.withUnsafeMutableBufferPointer { target in
                guard let sourceBase = source.baseAddress,
                      let targetBase = target.baseAddress else { return }
                for y in 0..<height {
                    for x in 0..<outputWidth {
                        let kernel = xKernels[x]
                        var sum: Float = 0
                        for index in kernel.weights.indices {
                            sum += sourceBase[y * width + kernel.minimum + index]
                                * kernel.weights[index]
                        }
                        targetBase[y * outputWidth + x] = sum
                    }
                }
            }
        }
        var output = Array(repeating: Float(0), count: outputWidth * outputHeight)
        horizontal.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                guard let sourceBase = source.baseAddress,
                      let targetBase = target.baseAddress else { return }
                for y in 0..<outputHeight {
                    let kernel = yKernels[y]
                    for x in 0..<outputWidth {
                        var sum: Float = 0
                        for index in kernel.weights.indices {
                            sum += sourceBase[(kernel.minimum + index) * outputWidth + x]
                                * kernel.weights[index]
                        }
                        targetBase[y * outputWidth + x] = sum
                    }
                }
            }
        }
        return output
    }

    /// PyTorch FP32 bilinear interpolation with `align_corners=false`.
    @_optimize(speed)
    static func resizeAlignCornersFalse(
        _ values: [Float],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> [Float] {
        precondition(values.count == width * height)
        let xPlan = alignCornersFalsePlan(inputSize: width, outputSize: outputWidth)
        let yPlan = alignCornersFalsePlan(inputSize: height, outputSize: outputHeight)
        var output = Array(repeating: Float(0), count: outputWidth * outputHeight)
        values.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                guard let sourceBase = source.baseAddress,
                      let targetBase = target.baseAddress else { return }
                for y in 0..<outputHeight {
                    let yp = yPlan[y]
                    for x in 0..<outputWidth {
                        let xp = xPlan[x]
                        let top = sourceBase[yp.lower * width + xp.lower]
                            * (1 - xp.fraction)
                            + sourceBase[yp.lower * width + xp.upper] * xp.fraction
                        let bottom = sourceBase[yp.upper * width + xp.lower]
                            * (1 - xp.fraction)
                            + sourceBase[yp.upper * width + xp.upper] * xp.fraction
                        targetBase[y * outputWidth + x] = top * (1 - yp.fraction)
                            + bottom * yp.fraction
                    }
                }
            }
        }
        return output
    }

    /// Same interpolation, with the frozen `> 0` mask threshold fused into
    /// the final write so a second full-size Float buffer is not materialized.
    @_optimize(speed)
    static func resizeAlignCornersFalseAndThreshold(
        _ values: [Float],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> [Bool] {
        precondition(values.count == width * height)
        let xPlan = alignCornersFalsePlan(inputSize: width, outputSize: outputWidth)
        let yPlan = alignCornersFalsePlan(inputSize: height, outputSize: outputHeight)
        var output = Array(repeating: false, count: outputWidth * outputHeight)
        values.withUnsafeBufferPointer { source in
            guard let sourceBase = source.baseAddress else { return }
            for y in 0..<outputHeight {
                let yp = yPlan[y]
                for x in 0..<outputWidth {
                    let xp = xPlan[x]
                    let top = sourceBase[yp.lower * width + xp.lower]
                        * (1 - xp.fraction)
                        + sourceBase[yp.lower * width + xp.upper] * xp.fraction
                    let bottom = sourceBase[yp.upper * width + xp.lower]
                        * (1 - xp.fraction)
                        + sourceBase[yp.upper * width + xp.upper] * xp.fraction
                    output[y * outputWidth + x] = top * (1 - yp.fraction)
                        + bottom * yp.fraction > 0
                }
            }
        }
        return output
    }

    /// Packed equivalent of `resizeAlignCornersFalseAndThreshold`. Production
    /// uses this form so mask storage remains one bit per crop pixel.
    @_optimize(speed)
    static func resizeAlignCornersFalseAndThresholdMask(
        _ values: [Float],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int,
        capacityBudget: RTV2WorkingSetBudget.Estimate? = nil
    ) throws -> RTV2BinaryMask {
        let inputCount = try RTV2WorkingSetBudget.checkedProduct([width, height])
        let outputCount = try RTV2WorkingSetBudget.checkedProduct([
            outputWidth, outputHeight,
        ])
        guard width > 0, height > 0, outputWidth > 0, outputHeight > 0,
              values.count == inputCount else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        let xPlan = alignCornersFalsePlan(inputSize: width, outputSize: outputWidth)
        let yPlan = alignCornersFalsePlan(inputSize: height, outputSize: outputHeight)
        let wordCount = try RTV2WorkingSetBudget.checkedSum([outputCount, 63]) / 64
        var words = Array(repeating: UInt64(0), count: wordCount)
        if let capacityBudget {
            guard words.capacity >= wordCount else { throw RTV2ReferenceMathError.resourceBudgetExceeded }
            try capacityBudget.validateActualStorage(maskCapacity: words.capacity)
        } else {
            try RTV2WorkingSetBudget.validateFixedCapacity(
                count: wordCount, capacity: words.capacity, stride: MemoryLayout<UInt64>.stride
            )
        }
        values.withUnsafeBufferPointer { source in
            guard let sourceBase = source.baseAddress else { return }
            for y in 0..<outputHeight {
                let yp = yPlan[y]
                for x in 0..<outputWidth {
                    let xp = xPlan[x]
                    let top = sourceBase[yp.lower * width + xp.lower]
                        * (1 - xp.fraction)
                        + sourceBase[yp.lower * width + xp.upper] * xp.fraction
                    let bottom = sourceBase[yp.upper * width + xp.lower]
                        * (1 - xp.fraction)
                        + sourceBase[yp.upper * width + xp.upper] * xp.fraction
                    let index = y * outputWidth + x
                    if top * (1 - yp.fraction) + bottom * yp.fraction > 0 {
                        words[index >> 6] |= UInt64(1) << UInt64(index & 63)
                    }
                }
            }
        }
        return RTV2BinaryMask(
            width: outputWidth,
            height: outputHeight,
            packedWords: words
        )
    }

    /// FP32 square20 `warpPerspective` with OpenCV INTER_LINEAR's 1/32-pixel
    /// lookup coordinates and a constant FP32 RGB border. Forward geometry is
    /// deliberately kept in Float; only the later inverse-G mapping is Double.
    @_optimize(speed)
    static func openCVSquare20WarpFP32(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        box: [Float],
        borderRGB: [Float]
    ) throws -> FP32SquareCrop {
        let crop = try fp32Square20Geometry(
            width: width,
            height: height,
            box: box
        )
        let expectedSourceCount = try RTV2WorkingSetBudget.checkedProduct(
            [width, height, 3]
        )
        guard bytes.count == expectedSourceCount, borderRGB.count == 3,
              borderRGB.allSatisfy(\.isFinite) else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        let plans = try openCVSquare20WarpPlans(crop)
        let outputCount = try RTV2WorkingSetBudget.checkedProduct(
            [crop.side, crop.side, 3]
        )
        var output = Array(repeating: Float(0), count: outputCount)
        bytes.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                guard let sourceBase = source.baseAddress,
                      let targetBase = target.baseAddress else { return }
                for destinationY in 0..<crop.side {
                    let y = plans.y[destinationY]
                    for destinationX in 0..<crop.side {
                        let x = plans.x[destinationX]
                        let targetOffset = (destinationY * crop.side + destinationX) * 3
                        for channel in 0..<3 {
                            targetBase[targetOffset + channel] = square20Sample(
                                sourceBase: sourceBase,
                                width: width,
                                height: height,
                                x: x,
                                y: y,
                                channel: channel,
                                borderRGB: borderRGB
                            )
                        }
                    }
                }
            }
        }
        return FP32SquareCrop(
            pixels: output,
            side: crop.side,
            sourceMinimumX: crop.sourceMinimumX,
            sourceMinimumY: crop.sourceMinimumY,
            sourceWidth: crop.sourceWidth,
            sourceHeight: crop.sourceHeight,
            forwardScaleX: crop.forwardScaleX,
            forwardScaleY: crop.forwardScaleY
        )
    }

    static func fp32Square20Geometry(
        width: Int,
        height: Int,
        box: [Float]
    ) throws -> FP32SquareGeometry {
        guard width > 0, height > 0, box.count == 4,
              box.allSatisfy(\.isFinite) else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        let centerX = (box[0] + box[2]) * Float(0.5)
        let centerY = (box[1] + box[3]) * Float(0.5)
        let roiSide = max(box[2] - box[0], box[3] - box[1], Float(2))
            * Float(1.4)
        let minimumX = centerX - roiSide * Float(0.5)
        let minimumY = centerY - roiSide * Float(0.5)
        let maximumX = minimumX + roiSide
        let maximumY = minimumY + roiSide
        let sourceWidth = maximumX - minimumX
        let sourceHeight = maximumY - minimumY
        let roundedSide = Double(sourceWidth).rounded(.toNearestOrEven)
        guard centerX.isFinite, centerY.isFinite, roiSide.isFinite,
              minimumX.isFinite, minimumY.isFinite,
              sourceWidth.isFinite, sourceHeight.isFinite,
              sourceWidth > 0, sourceHeight > 0,
              roundedSide >= 0, let integerSide = Int(exactly: roundedSide) else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        let side = max(64, integerSide)
        let destinationExtent = Float(max(side - 1, 1))
        let scaleX = destinationExtent / sourceWidth
        let scaleY = destinationExtent / sourceHeight
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        return FP32SquareGeometry(
            side: side,
            sourceMinimumX: minimumX,
            sourceMinimumY: minimumY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            forwardScaleX: scaleX,
            forwardScaleY: scaleY
        )
    }

    /// Exact square20 -> Pillow F-mode bilinear composition without ever
    /// materializing the side x side x 3 crop. Horizontal rows needed by the
    /// current output row are cached, then evicted monotonically.
    @_optimize(speed)
    static func streamingSquare20PillowResizeFP32(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        box: [Float],
        borderRGB: [Float],
        outputSide: Int,
        encodedByteCount: Int = 0
    ) throws -> FP32SquareResize {
        let crop = try fp32Square20Geometry(width: width, height: height, box: box)
        try RTV2WorkingSetBudget.validateCandidate(
            sourceWidth: width,
            sourceHeight: height,
            cropSide: crop.side,
            encodedByteCount: encodedByteCount,
            sourceRGBStorageBytes: bytes.capacity,
            samplingOutputSide: outputSide
        )
        let sourceCount = try RTV2WorkingSetBudget.checkedProduct([width, height, 3])
        guard bytes.count == sourceCount, borderRGB.count == 3,
              borderRGB.allSatisfy(\.isFinite), outputSide > 0 else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        let outputCount = try RTV2WorkingSetBudget.checkedProduct(
            [outputSide, outputSide, 3]
        )
        let rowCount = try RTV2WorkingSetBudget.checkedProduct([outputSide, 3])
        let warpPlans = try openCVSquare20WarpPlans(crop)
        let xKernels = pillowFloatBilinearCoefficients(
            inputSize: crop.side,
            outputSize: outputSide
        )
        let yKernels = pillowFloatBilinearCoefficients(
            inputSize: crop.side,
            outputSize: outputSide
        )
        let maximumCachedRows = yKernels.map(\.weights.count).max() ?? 0
        _ = try RTV2WorkingSetBudget.checkedProduct([
            max(maximumCachedRows, 1), rowCount,
        ])
        var output = Array(repeating: Float(0), count: outputCount)
        try RTV2WorkingSetBudget.validateFixedCapacity(
            count: outputCount, capacity: output.capacity, stride: MemoryLayout<Float>.stride
        )
        var cachedRows: [Int: [Float]] = [:]
        cachedRows.reserveCapacity(maximumCachedRows)

        try bytes.withUnsafeBufferPointer { source in
            guard let sourceBase = source.baseAddress else {
                throw RTV2ReferenceMathError.invalidDimensions
            }
            for outputY in 0..<outputSide {
                let yKernel = yKernels[outputY]
                let firstNeededRow = yKernel.minimum
                let lastNeededRow = firstNeededRow + yKernel.weights.count
                cachedRows = cachedRows.filter {
                    $0.key >= firstNeededRow && $0.key < lastNeededRow
                }
                for cropY in firstNeededRow..<lastNeededRow
                    where cachedRows[cropY] == nil {
                    let warpY = warpPlans.y[cropY]
                    var row = Array(repeating: Float(0), count: rowCount)
                    row.withUnsafeMutableBufferPointer { target in
                        guard let targetBase = target.baseAddress else { return }
                        for outputX in 0..<outputSide {
                            let xKernel = xKernels[outputX]
                            let targetOffset = outputX * 3
                            for channel in 0..<3 {
                                var total: Float = 0
                                for offset in xKernel.weights.indices {
                                    let cropX = xKernel.minimum + offset
                                    total += square20Sample(
                                        sourceBase: sourceBase,
                                        width: width,
                                        height: height,
                                        x: warpPlans.x[cropX],
                                        y: warpY,
                                        channel: channel,
                                        borderRGB: borderRGB
                                    ) * xKernel.weights[offset]
                                }
                                targetBase[targetOffset + channel] = total
                            }
                        }
                    }
                    cachedRows[cropY] = row
                }
                let rows = (firstNeededRow..<lastNeededRow).compactMap { cachedRows[$0] }
                guard rows.count == yKernel.weights.count else {
                    throw RTV2ReferenceMathError.invalidDimensions
                }
                for outputX in 0..<outputSide {
                    for channel in 0..<3 {
                        var total: Float = 0
                        for offset in yKernel.weights.indices {
                            total += rows[offset][outputX * 3 + channel]
                                * yKernel.weights[offset]
                        }
                        output[(outputY * outputSide + outputX) * 3 + channel] = total
                    }
                }
            }
        }
        return FP32SquareResize(
            pixels: output,
            crop: crop,
            maximumCachedRows: maximumCachedRows
        )
    }

    /// Invert the frozen axis-aligned FP32 square20 homography in FP64.
    /// The returned values are deliberately not rounded so callers can apply
    /// the serialization contract only at the final boundary.
    static func restoreCropPointsFP64(
        _ points: [RTV2Point],
        crop: FP32SquareCrop
    ) -> [RTV2Point] {
        let inverseScaleX = 1 / Double(crop.forwardScaleX)
        let inverseScaleY = 1 / Double(crop.forwardScaleY)
        let translationX = Double(crop.sourceMinimumX)
        let translationY = Double(crop.sourceMinimumY)
        return points.map { point in
            RTV2Point(
                x: point.x * inverseScaleX + translationX,
                y: point.y * inverseScaleY + translationY
            )
        }
    }

    static func restoreCropPointsFP64(
        _ points: [RTV2Point],
        crop: FP32SquareGeometry
    ) -> [RTV2Point] {
        let inverseScaleX = 1 / Double(crop.forwardScaleX)
        let inverseScaleY = 1 / Double(crop.forwardScaleY)
        let translationX = Double(crop.sourceMinimumX)
        let translationY = Double(crop.sourceMinimumY)
        return points.map { point in
            RTV2Point(
                x: point.x * inverseScaleX + translationX,
                y: point.y * inverseScaleY + translationY
            )
        }
    }

    private struct OpenCVSquare20Coordinate {
        let low: Int
        let fraction: Float
    }

    private static func openCVSquare20WarpPlans(
        _ crop: FP32SquareGeometry
    ) throws -> (x: [OpenCVSquare20Coordinate], y: [OpenCVSquare20Coordinate]) {
        let interpolationScale = 1 << openCVWarpInterpolationBits
        func plan(
            minimum: Float,
            scale: Float
        ) throws -> [OpenCVSquare20Coordinate] {
            var output: [OpenCVSquare20Coordinate] = []
            output.reserveCapacity(crop.side)
            for destination in 0..<crop.side {
                let source = minimum + Float(destination) / scale
                let fixedValue = (Double(source) * Double(interpolationScale))
                    .rounded(.toNearestOrEven)
                guard fixedValue.isFinite,
                      fixedValue >= Double(Int.min),
                      fixedValue <= Double(Int.max) else {
                    throw RTV2ReferenceMathError.invalidDimensions
                }
                let fixed = Int(fixedValue)
                output.append(OpenCVSquare20Coordinate(
                    low: fixed >> openCVWarpInterpolationBits,
                    fraction: Float(fixed & (interpolationScale - 1))
                        / Float(interpolationScale)
                ))
            }
            return output
        }
        return (
            try plan(minimum: crop.sourceMinimumX, scale: crop.forwardScaleX),
            try plan(minimum: crop.sourceMinimumY, scale: crop.forwardScaleY)
        )
    }

    @inline(__always)
    private static func square20Sample(
        sourceBase: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        x: OpenCVSquare20Coordinate,
        y: OpenCVSquare20Coordinate,
        channel: Int,
        borderRGB: [Float]
    ) -> Float {
        @inline(__always) func value(_ sampleX: Int, _ sampleY: Int) -> Float {
            guard sampleX >= 0, sampleY >= 0,
                  sampleX < width, sampleY < height else {
                return borderRGB[channel]
            }
            return Float(sourceBase[(sampleY * width + sampleX) * 3 + channel])
        }
        let wx0 = 1 - x.fraction
        let wy0 = 1 - y.fraction
        let w00 = wx0 * wy0
        let w10 = x.fraction * wy0
        let w01 = wx0 * y.fraction
        let w11 = x.fraction * y.fraction
        return value(x.low, y.low) * w00
            + value(x.low + 1, y.low) * w10
            + value(x.low, y.low + 1) * w01
            + value(x.low + 1, y.low + 1) * w11
    }

    struct OpenCVSoftMaskSupport: Sendable {
        let x1: Int
        let y1: Int
        let x2: Int
        let y2: Int
        let values: [Float]
        let area: Float
    }

    private struct AreaContribution {
        let index: Int
        let weight: Double
    }

    /// Pillow 12.2.0 `Image.resize(..., Resampling.BILINEAR)` for an RGB image.
    /// Pillow widens the bilinear support while downsampling (antialiasing),
    /// quantizes coefficients to 22-bit integers, and clips after each of its
    /// two separable passes. Those details are intentionally preserved here.
    @_optimize(speed)
    static func pillowBilinearResizeRGB(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> [UInt8] {
        precondition(width > 0 && height > 0)
        precondition(outputWidth > 0 && outputHeight > 0)
        precondition(bytes.count == width * height * 3)

        let horizontallyResized: [UInt8]
        if width == outputWidth {
            horizontallyResized = bytes
        } else {
            let coefficients = pillowBilinearCoefficients(
                inputSize: width,
                outputSize: outputWidth
            )
            var output = Array(repeating: UInt8(0), count: outputWidth * height * 3)
            bytes.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    guard let sourceBase = source.baseAddress,
                          let destinationBase = destination.baseAddress else { return }
                    for y in 0..<height {
                        for x in 0..<outputWidth {
                            let kernel = coefficients[x]
                            kernel.weights.withUnsafeBufferPointer { weights in
                                guard let weightsBase = weights.baseAddress else { return }
                                for channel in 0..<3 {
                                    var sum = 1 << (pillowPrecisionBits - 1)
                                    var sourceOffset = (y * width + kernel.minimum) * 3 + channel
                                    for offset in 0..<weights.count {
                                        sum += Int(sourceBase[sourceOffset]) * weightsBase[offset]
                                        sourceOffset += 3
                                    }
                                    destinationBase[(y * outputWidth + x) * 3 + channel]
                                        = pillowClip(sum)
                                }
                            }
                        }
                    }
                }
            }
            horizontallyResized = output
        }

        guard height != outputHeight else { return horizontallyResized }
        let coefficients = pillowBilinearCoefficients(
            inputSize: height,
            outputSize: outputHeight
        )
        var output = Array(repeating: UInt8(0), count: outputWidth * outputHeight * 3)
        horizontallyResized.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                for y in 0..<outputHeight {
                    let kernel = coefficients[y]
                    kernel.weights.withUnsafeBufferPointer { weights in
                        guard let weightsBase = weights.baseAddress else { return }
                        for x in 0..<outputWidth {
                            for channel in 0..<3 {
                                var sum = 1 << (pillowPrecisionBits - 1)
                                var sourceOffset = (kernel.minimum * outputWidth + x) * 3
                                    + channel
                                for offset in 0..<weights.count {
                                    sum += Int(sourceBase[sourceOffset]) * weightsBase[offset]
                                    sourceOffset += outputWidth * 3
                                }
                                destinationBase[(y * outputWidth + x) * 3 + channel]
                                    = pillowClip(sum)
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    /// OpenCV 4.10 `cv2.resize(..., INTER_AREA)` for an interleaved RGB8 image.
    /// The detector always scales both axes in the same direction. The general
    /// area contribution form is retained for non-integer ratios and expansion.
    static func openCVAreaResizeRGB(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> [UInt8] {
        precondition(width > 0 && height > 0)
        precondition(outputWidth > 0 && outputHeight > 0)
        precondition(bytes.count == width * height * 3)
        if width == outputWidth, height == outputHeight { return bytes }

        let scaleX = Double(width) / Double(outputWidth)
        let scaleY = Double(height) / Double(outputHeight)
        let xPlan = areaContributions(
            inputSize: width,
            outputSize: outputWidth,
            scale: scaleX
        )
        let yPlan = areaContributions(
            inputSize: height,
            outputSize: outputHeight,
            scale: scaleY
        )
        var output = Array(repeating: UInt8(0), count: outputWidth * outputHeight * 3)
        for destinationY in 0..<outputHeight {
            for destinationX in 0..<outputWidth {
                var red = 0.0
                var green = 0.0
                var blue = 0.0
                var totalWeight = 0.0
                for y in yPlan[destinationY] {
                    for x in xPlan[destinationX] {
                        let weight = x.weight * y.weight
                        totalWeight += weight
                        let source = (y.index * width + x.index) * 3
                        red += Double(bytes[source]) * weight
                        green += Double(bytes[source + 1]) * weight
                        blue += Double(bytes[source + 2]) * weight
                    }
                }
                let divisor = max(totalWeight, .leastNonzeroMagnitude)
                let target = (destinationY * outputWidth + destinationX) * 3
                output[target] = UInt8(clamping: Int(floor(red / divisor + 0.5)))
                output[target + 1] = UInt8(clamping: Int(floor(green / divisor + 0.5)))
                output[target + 2] = UInt8(clamping: Int(floor(blue / divisor + 0.5)))
            }
        }
        return output
    }

    private static func areaContributions(
        inputSize: Int,
        outputSize: Int,
        scale: Double
    ) -> [[AreaContribution]] {
        (0..<outputSize).map { destination in
            let minimum = Double(destination) * scale
            let maximum = Double(destination + 1) * scale
            let first = max(0, Int(floor(minimum)))
            let last = min(inputSize, Int(ceil(maximum)))
            return (first..<last).map { source in
                AreaContribution(
                    index: source,
                    weight: max(
                        0,
                        min(maximum, Double(source + 1)) - max(minimum, Double(source))
                    )
                )
            }
        }
    }

    /// OpenCV 4.10 RGB8 `INTER_LINEAR` resize. OpenCV quantizes each separable
    /// resize coefficient to 11 bits before the final fixed-point cast.
    static func openCVLinearResizeRGB(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> [UInt8] {
        precondition(bytes.count == width * height * 3)
        let coefficientScale = 1 << openCVResizeCoefficientBits
        let x = openCVLinearCoordinates(inputSize: width, outputSize: outputWidth)
        let y = openCVLinearCoordinates(inputSize: height, outputSize: outputHeight)
        var horizontal = Array(repeating: 0, count: height * outputWidth * 3)
        for sourceY in 0..<height {
            for destinationX in 0..<outputWidth {
                let coordinate = x[destinationX]
                let alpha1 = Int(
                    (coordinate.fraction * Double(coefficientScale)).rounded(.toNearestOrEven)
                )
                let alpha0 = coefficientScale - alpha1
                for channel in 0..<3 {
                    let first = Int(bytes[(sourceY * width + coordinate.lower) * 3 + channel])
                    let second = Int(bytes[(sourceY * width + coordinate.upper) * 3 + channel])
                    horizontal[(sourceY * outputWidth + destinationX) * 3 + channel]
                        = first * alpha0 + second * alpha1
                }
            }
        }
        let rounding = 1 << (openCVResizeCoefficientBits * 2 - 1)
        var output = Array(repeating: UInt8(0), count: outputWidth * outputHeight * 3)
        for destinationY in 0..<outputHeight {
            let coordinate = y[destinationY]
            let beta1 = Int(
                (coordinate.fraction * Double(coefficientScale)).rounded(.toNearestOrEven)
            )
            let beta0 = coefficientScale - beta1
            for destinationX in 0..<outputWidth {
                for channel in 0..<3 {
                    let first = horizontal[
                        (coordinate.lower * outputWidth + destinationX) * 3 + channel
                    ]
                    let second = horizontal[
                        (coordinate.upper * outputWidth + destinationX) * 3 + channel
                    ]
                    let value = (first * beta0 + second * beta1 + rounding)
                        >> (openCVResizeCoefficientBits * 2)
                    output[(destinationY * outputWidth + destinationX) * 3 + channel]
                        = UInt8(clamping: value)
                }
            }
        }
        return output
    }

    /// OpenCV 4.10 Float32 `INTER_LINEAR` resize, evaluated as its separable
    /// horizontal and vertical passes to preserve operation order.
    @_optimize(speed)
    static func openCVLinearResizeFloat(
        _ values: [Float],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> [Float] {
        precondition(values.count == width * height)
        let x = openCVLinearCoordinates(inputSize: width, outputSize: outputWidth)
        let y = openCVLinearCoordinates(inputSize: height, outputSize: outputHeight)
        var horizontal = Array(repeating: Float(0), count: height * outputWidth)
        values.withUnsafeBufferPointer { source in
            horizontal.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                for sourceY in 0..<height {
                    let sourceRow = sourceBase + sourceY * width
                    let destinationRow = destinationBase + sourceY * outputWidth
                    for destinationX in 0..<outputWidth {
                        let coordinate = x[destinationX]
                        let alpha1 = Float(coordinate.fraction)
                        let alpha0: Float = 1 - alpha1
                        destinationRow[destinationX]
                            = sourceRow[coordinate.lower] * alpha0
                            + sourceRow[coordinate.upper] * alpha1
                    }
                }
            }
        }
        var output = Array(repeating: Float(0), count: outputWidth * outputHeight)
        horizontal.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                for destinationY in 0..<outputHeight {
                    let coordinate = y[destinationY]
                    let beta1 = Float(coordinate.fraction)
                    let beta0: Float = 1 - beta1
                    let firstRow = sourceBase + coordinate.lower * outputWidth
                    let secondRow = sourceBase + coordinate.upper * outputWidth
                    let destinationRow = destinationBase + destinationY * outputWidth
                    for destinationX in 0..<outputWidth {
                        destinationRow[destinationX]
                            = firstRow[destinationX] * beta0
                            + secondRow[destinationX] * beta1
                    }
                }
            }
        }
        return output
    }

    /// Returns one rectangular destination region from the exact same
    /// INTER_LINEAR resize as `openCVLinearResizeFloat`. The selector only
    /// consumes the portion clipped to its fixed canvas. Decoded proposals can
    /// extend far beyond that canvas, so materializing the full resized mask
    /// first creates image-dependent, sometimes enormous temporary buffers.
    /// Computing the clipped destination coordinates directly preserves the
    /// frozen interpolation coordinates and operation order without doing work
    /// that is immediately discarded.
    static func openCVLinearResizeFloatRegion(
        _ values: [Float],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int,
        destinationX: Range<Int>,
        destinationY: Range<Int>
    ) -> [Float] {
        precondition(values.count == width * height)
        precondition(outputWidth > 0 && outputHeight > 0)
        precondition(destinationX.lowerBound >= 0)
        precondition(destinationY.lowerBound >= 0)
        precondition(destinationX.upperBound <= outputWidth)
        precondition(destinationY.upperBound <= outputHeight)
        guard !destinationX.isEmpty, !destinationY.isEmpty else { return [] }

        let regionWidth = destinationX.count
        let x = destinationX.map {
            openCVLinearCoordinate(
                inputSize: width,
                outputSize: outputWidth,
                destination: $0
            )
        }
        let y = destinationY.map {
            openCVLinearCoordinate(
                inputSize: height,
                outputSize: outputHeight,
                destination: $0
            )
        }
        var horizontal = Array(repeating: Float(0), count: height * regionWidth)
        values.withUnsafeBufferPointer { source in
            horizontal.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                for sourceY in 0..<height {
                    let sourceRow = sourceBase + sourceY * width
                    let destinationRow = destinationBase + sourceY * regionWidth
                    for regionX in 0..<regionWidth {
                        let coordinate = x[regionX]
                        let alpha1 = Float(coordinate.fraction)
                        let alpha0: Float = 1 - alpha1
                        destinationRow[regionX]
                            = sourceRow[coordinate.lower] * alpha0
                            + sourceRow[coordinate.upper] * alpha1
                    }
                }
            }
        }
        var output = Array(
            repeating: Float(0),
            count: regionWidth * destinationY.count
        )
        horizontal.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                for regionY in y.indices {
                    let coordinate = y[regionY]
                    let beta1 = Float(coordinate.fraction)
                    let beta0: Float = 1 - beta1
                    let firstRow = sourceBase + coordinate.lower * regionWidth
                    let secondRow = sourceBase + coordinate.upper * regionWidth
                    let destinationRow = destinationBase + regionY * regionWidth
                    for regionX in 0..<regionWidth {
                        destinationRow[regionX]
                            = firstRow[regionX] * beta0
                            + secondRow[regionX] * beta1
                    }
                }
            }
        }
        return output
    }

    /// Selector pairwise soft-mask support. The frozen reference first resizes
    /// each 56×56 probability mask with OpenCV `INTER_LINEAR`, then clips the
    /// resized support against the 768×768 selector canvas.
    static func openCVSoftMaskSupport(
        probability: [Float],
        box: [Float],
        canvas: Int
    ) -> OpenCVSoftMaskSupport {
        precondition(probability.count == 56 * 56)
        precondition(box.count == 4)
        let left = Int(floor(box[0]))
        let top = Int(floor(box[1]))
        let right = Int(ceil(box[2]))
        let bottom = Int(ceil(box[3]))
        let targetWidth = max(right - left, 1)
        let targetHeight = max(bottom - top, 1)
        let x1 = max(left, 0)
        let y1 = max(top, 0)
        let x2 = min(right, canvas)
        let y2 = min(bottom, canvas)
        guard x2 > x1, y2 > y1 else {
            return OpenCVSoftMaskSupport(
                x1: 0, y1: 0, x2: 0, y2: 0, values: [], area: 0
            )
        }
        let values = openCVLinearResizeFloatRegion(
            probability,
            width: 56,
            height: 56,
            outputWidth: targetWidth,
            outputHeight: targetHeight,
            destinationX: (x1 - left)..<(x2 - left),
            destinationY: (y1 - top)..<(y2 - top)
        )
        var area: Float = 0
        values.withUnsafeBufferPointer { source in
            guard let sourceBase = source.baseAddress else { return }
            for index in 0..<source.count {
                area += sourceBase[index]
            }
        }
        return OpenCVSoftMaskSupport(
            x1: x1, y1: y1, x2: x2, y2: y2, values: values, area: area
        )
    }

    /// The axis-aligned square20 `getPerspectiveTransform` + `warpPerspective`
    /// path. Coordinates are quantized to OpenCV's 1/32-pixel interpolation
    /// table and RGB8 coefficients to 15-bit fixed point.
    static func openCVSquare20WarpRGB(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        box: [Float],
        borderRGB: [Double]
    ) -> OpenCVSquareCrop {
        precondition(bytes.count == width * height * 3)
        precondition(box.count == 4 && borderRGB.count == 3)
        let x1 = Double(box[0])
        let y1 = Double(box[1])
        let x2 = Double(box[2])
        let y2 = Double(box[3])
        let centerX = (x1 + x2) / 2
        let centerY = (y1 + y2) / 2
        let roiSide = max(max(x2 - x1, y2 - y1), 2) * 1.4
        let roiMinimumX = centerX - roiSide / 2
        let roiMinimumY = centerY - roiSide / 2
        let cropSide = max(64, Int(roiSide.rounded(.toNearestOrEven)))

        // `square_transform` explicitly casts the source corners to float32
        // before asking OpenCV for the homography.
        let sourceMinimumX = Float(roiMinimumX)
        let sourceMinimumY = Float(roiMinimumY)
        let sourceMaximumX = Float(roiMinimumX + roiSide)
        let sourceMaximumY = Float(roiMinimumY + roiSide)
        let sourceSideX = sourceMaximumX - sourceMinimumX
        let sourceSideY = sourceMaximumY - sourceMinimumY
        let interpolationScale = 1 << openCVWarpInterpolationBits
        let coefficientScale = 1 << openCVWarpCoefficientBits
        let border = borderRGB.map { UInt8(clamping: Int($0.rounded(.toNearestOrEven))) }
        var output = Array(repeating: UInt8(0), count: cropSide * cropSide * 3)
        for destinationY in 0..<cropSide {
            let sourceY = Double(sourceMinimumY)
                + Double(destinationY) * Double(sourceSideY) / Double(max(cropSide - 1, 1))
            let fixedY = Int(
                (sourceY * Double(interpolationScale)).rounded(.toNearestOrEven)
            )
            let lowerY = fixedY >> openCVWarpInterpolationBits
            let fractionY = fixedY & (interpolationScale - 1)
            for destinationX in 0..<cropSide {
                let sourceX = Double(sourceMinimumX)
                    + Double(destinationX) * Double(sourceSideX)
                        / Double(max(cropSide - 1, 1))
                let fixedX = Int(
                    (sourceX * Double(interpolationScale)).rounded(.toNearestOrEven)
                )
                let lowerX = fixedX >> openCVWarpInterpolationBits
                let fractionX = fixedX & (interpolationScale - 1)
                let fx = Double(fractionX) / Double(interpolationScale)
                let fy = Double(fractionY) / Double(interpolationScale)
                let weights = [
                    Int(((1 - fx) * (1 - fy) * Double(coefficientScale)).rounded(.toNearestOrEven)),
                    Int((fx * (1 - fy) * Double(coefficientScale)).rounded(.toNearestOrEven)),
                    Int(((1 - fx) * fy * Double(coefficientScale)).rounded(.toNearestOrEven)),
                    Int((fx * fy * Double(coefficientScale)).rounded(.toNearestOrEven)),
                ]
                for channel in 0..<3 {
                    func value(_ sourceX: Int, _ sourceY: Int) -> Int {
                        guard sourceX >= 0, sourceY >= 0,
                              sourceX < width, sourceY < height else {
                            return Int(border[channel])
                        }
                        return Int(bytes[(sourceY * width + sourceX) * 3 + channel])
                    }
                    let sum = value(lowerX, lowerY) * weights[0]
                        + value(lowerX + 1, lowerY) * weights[1]
                        + value(lowerX, lowerY + 1) * weights[2]
                        + value(lowerX + 1, lowerY + 1) * weights[3]
                    let result = (sum + (1 << (openCVWarpCoefficientBits - 1)))
                        >> openCVWarpCoefficientBits
                    output[(destinationY * cropSide + destinationX) * 3 + channel]
                        = UInt8(clamping: result)
                }
            }
        }
        return OpenCVSquareCrop(
            bytes: output,
            side: cropSide,
            sourceMinimumX: sourceMinimumX,
            sourceMinimumY: sourceMinimumY,
            sourceWidth: sourceSideX,
            sourceHeight: sourceSideY
        )
    }

    static func openCVPasteCoarseMask(
        probability: [Float],
        box: [Float],
        canvas: Int = 192
    ) -> [Bool] {
        precondition(probability.count == 56 * 56 && box.count == 4)
        let scale = Double(canvas) / 768
        let x1 = Double(box[0]) * scale
        let y1 = Double(box[1]) * scale
        let x2 = Double(box[2]) * scale
        let y2 = Double(box[3]) * scale
        let left = Int(floor(x1))
        let top = Int(floor(y1))
        let width = max(Int(ceil(x2)) - left, 1)
        let height = max(Int(ceil(y2)) - top, 1)
        var output = Array(repeating: false, count: canvas * canvas)
        let outputMinimumX = max(left, 0)
        let outputMinimumY = max(top, 0)
        let outputMaximumX = min(left + width, canvas)
        let outputMaximumY = min(top + height, canvas)
        guard outputMaximumX > outputMinimumX,
              outputMaximumY > outputMinimumY else { return output }
        let regionWidth = outputMaximumX - outputMinimumX
        let resized = openCVLinearResizeFloatRegion(
            probability,
            width: 56,
            height: 56,
            outputWidth: width,
            outputHeight: height,
            destinationX: (outputMinimumX - left)..<(outputMaximumX - left),
            destinationY: (outputMinimumY - top)..<(outputMaximumY - top)
        )
        for outputY in outputMinimumY..<outputMaximumY {
            for outputX in outputMinimumX..<outputMaximumX {
                let sourceX = outputX - outputMinimumX
                let sourceY = outputY - outputMinimumY
                output[outputY * canvas + outputX]
                    = resized[sourceY * regionWidth + sourceX] >= 0.5
            }
        }
        return output
    }

    /// Exact NumPy 1.23.5 `default_rng(42).choice(n, 5, replace=False)`.
    static func numpyChoiceSeed42(upperBound: Int, count: Int = 5) -> [Int] {
        var generator = NumPyPCG64Seed42()
        return generator.choiceWithoutReplacement(
            upperBound: upperBound,
            count: min(count, upperBound)
        )
    }

    static func numpyChoiceStreamSeed42(
        upperBound: Int,
        count: Int = 5,
        draws: Int
    ) -> [[Int]] {
        var generator = NumPyPCG64Seed42()
        return (0..<draws).map { _ in
            generator.choiceWithoutReplacement(
                upperBound: upperBound,
                count: min(count, upperBound)
            )
        }
    }

    private struct PillowKernel {
        let minimum: Int
        let weights: [Int]
    }

    private struct PillowFloatKernel {
        let minimum: Int
        let weights: [Float]
    }

    private struct AlignCornersFalseCoordinate {
        let lower: Int
        let upper: Int
        let fraction: Float
    }

    private static func alignCornersFalsePlan(
        inputSize: Int,
        outputSize: Int
    ) -> [AlignCornersFalseCoordinate] {
        let scale = Float(inputSize) / Float(outputSize)
        return (0..<outputSize).map { index in
            let position = (Float(index) + 0.5) * scale - 0.5
            let unclampedLower = Int(floor(position))
            let lower = min(max(unclampedLower, 0), inputSize - 1)
            let upper = min(max(unclampedLower + 1, 0), inputSize - 1)
            return AlignCornersFalseCoordinate(
                lower: lower,
                upper: upper,
                fraction: min(max(position - Float(unclampedLower), 0), 1)
            )
        }
    }

    private static func pillowFloatBilinearCoefficients(
        inputSize: Int,
        outputSize: Int
    ) -> [PillowFloatKernel] {
        let scale = Double(inputSize) / Double(outputSize)
        let filterScale = max(1, scale)
        let support = filterScale
        return (0..<outputSize).map { outputIndex in
            let center = (Double(outputIndex) + 0.5) * scale
            let minimum = max(0, Int(center - support + 0.5))
            let maximum = min(inputSize, Int(center + support + 0.5))
            var weights = (minimum..<maximum).map { inputIndex -> Double in
                let distance = abs(
                    (Double(inputIndex) - center + 0.5) / filterScale
                )
                return distance < 1 ? 1 - distance : 0
            }
            let total = weights.reduce(0, +)
            if total != 0 {
                for index in weights.indices { weights[index] /= total }
            }
            return PillowFloatKernel(
                minimum: minimum,
                weights: weights.map(Float.init)
            )
        }
    }

    private static func pillowBilinearCoefficients(
        inputSize: Int,
        outputSize: Int
    ) -> [PillowKernel] {
        let scale = Double(inputSize) / Double(outputSize)
        let filterScale = max(1, scale)
        let support = filterScale
        let coefficientScale = Double(1 << pillowPrecisionBits)
        return (0..<outputSize).map { outputIndex in
            let center = (Double(outputIndex) + 0.5) * scale
            let minimum = max(0, Int(center - support + 0.5))
            let maximum = min(inputSize, Int(center + support + 0.5))
            var weights = (minimum..<maximum).map { inputIndex -> Double in
                let distance = abs(
                    (Double(inputIndex) - center + 0.5) / filterScale
                )
                return distance < 1 ? 1 - distance : 0
            }
            let total = weights.reduce(0, +)
            if total != 0 {
                for index in weights.indices { weights[index] /= total }
            }
            return PillowKernel(
                minimum: minimum,
                weights: weights.map { Int($0 * coefficientScale + 0.5) }
            )
        }
    }

    private static func pillowClip(_ sum: Int) -> UInt8 {
        UInt8(clamping: sum >> pillowPrecisionBits)
    }

    private struct OpenCVLinearCoordinate {
        let lower: Int
        let upper: Int
        let fraction: Double
    }

    private static func openCVLinearCoordinates(
        inputSize: Int,
        outputSize: Int
    ) -> [OpenCVLinearCoordinate] {
        (0..<outputSize).map {
            openCVLinearCoordinate(
                inputSize: inputSize,
                outputSize: outputSize,
                destination: $0
            )
        }
    }

    @inline(__always)
    private static func openCVLinearCoordinate(
        inputSize: Int,
        outputSize: Int,
        destination: Int
    ) -> OpenCVLinearCoordinate {
        let scale = Double(inputSize) / Double(outputSize)
        var source = (Double(destination) + 0.5) * scale - 0.5
        var lower = Int(floor(source))
        source -= Double(lower)
        if lower < 0 {
            lower = 0
            source = 0
        }
        if lower >= inputSize - 1 {
            lower = inputSize - 1
            source = 0
        }
        return OpenCVLinearCoordinate(
            lower: lower,
            upper: min(lower + 1, inputSize - 1),
            fraction: source
        )
    }
}

/// NumPy 1.23.5 PCG64 state produced by `np.random.default_rng(42)`.
/// The reference creates a new generator for every fitted edge.
private struct NumPyPCG64Seed42 {
    private struct UInt128 {
        var high: UInt64
        var low: UInt64
    }

    private static let multiplier = UInt128(
        high: 2_549_297_995_355_413_924,
        low: 4_865_540_595_714_422_341
    )

    private var state = UInt128(
        high: 0xCEA4_4F67_9879_8F2A,
        low: 0xACBC_7C9D_6886_0AC8
    )
    private let increment = UInt128(
        high: 0xFA50_5436_C9A8_416E,
        low: 0x66CA_F2E2_8D25_ABFF
    )
    private var cachedUpper32: UInt32?

    mutating func choiceWithoutReplacement(
        upperBound: Int,
        count: Int
    ) -> [Int] {
        precondition(upperBound >= 0 && count >= 0 && count <= upperBound)
        guard count > 0 else { return [] }
        var selected = Set<Int>()
        var output: [Int] = []
        output.reserveCapacity(count)
        for value in (upperBound - count)..<upperBound {
            let candidate = Int(boundedInclusive(UInt32(value)))
            if selected.insert(candidate).inserted {
                output.append(candidate)
            } else {
                selected.insert(value)
                output.append(value)
            }
        }
        if output.count > 1 {
            for index in stride(from: output.count - 1, through: 1, by: -1) {
                let other = Int(boundedInclusive(UInt32(index)))
                output.swapAt(index, other)
            }
        }
        return output
    }

    private mutating func boundedInclusive(_ maximum: UInt32) -> UInt32 {
        guard maximum != 0 else { return 0 }
        let range = maximum &+ 1
        let threshold = (UInt32.max &- maximum) % range
        while true {
            let product = UInt64(next32()) * UInt64(range)
            if UInt32(truncatingIfNeeded: product) >= threshold {
                return UInt32(truncatingIfNeeded: product >> 32)
            }
        }
    }

    private mutating func next32() -> UInt32 {
        if let cachedUpper32 {
            self.cachedUpper32 = nil
            return cachedUpper32
        }
        let value = next64()
        cachedUpper32 = UInt32(truncatingIfNeeded: value >> 32)
        return UInt32(truncatingIfNeeded: value)
    }

    private mutating func next64() -> UInt64 {
        state = Self.add(Self.multiply(state, Self.multiplier), increment)
        return (state.high ^ state.low).rotatedRight(by: Int(state.high >> 58))
    }

    private static func add(_ lhs: UInt128, _ rhs: UInt128) -> UInt128 {
        let (low, overflow) = lhs.low.addingReportingOverflow(rhs.low)
        return UInt128(
            high: lhs.high &+ rhs.high &+ (overflow ? 1 : 0),
            low: low
        )
    }

    private static func multiply(_ lhs: UInt128, _ rhs: UInt128) -> UInt128 {
        let lowProduct = lhs.low.multipliedFullWidth(by: rhs.low)
        return UInt128(
            high: lowProduct.high &+ lhs.high &* rhs.low &+ lhs.low &* rhs.high,
            low: lowProduct.low
        )
    }
}

private extension UInt64 {
    func rotatedRight(by amount: Int) -> UInt64 {
        let rotation = amount & 63
        guard rotation != 0 else { return self }
        return (self >> rotation) | (self << (64 - rotation))
    }
}

enum RTV2WorkingSetBudget {
    // Known image buffers for one decode, including the measured CGImage
    // backing. Codec scratch, Core ML allocations and whole-process RSS are
    // separate from this budget.
    static let maximumDecodePeakBytes = 448 * 1_024 * 1_024
    static let maximumCandidatePeakBytes = 384 * 1_024 * 1_024
    // Kept for existing pure-numeric HostTools examples; never an input cap
    // or a production default. Production supplies the actual encoded length.
    static let maximumEncodedInputBytes = 40 * 1_024 * 1_024
    static let maximumSupportedEncodedInputBytes = 128 * 1_024 * 1_024
    static let maximumContourPoints = 1_048_576
    static let maximumTraversalQueueEntries = 1_048_576
    static let encoderSide = 1_024

    struct Estimate: Equatable, Sendable {
        let sourceRGBBytes: Int
        // Metadata-only lower bound; the actual CGImage layout must pass
        // validateDecodeLayout before RGBA allocation and rendering.
        let minimumDecodeBufferBytes: Int
        let streamedEncoderPixelsBytes: Int
        let maximumHorizontalCacheBytes: Int
        let packedMaskBytes: Int
        let contourVisitedBytes: Int
        let contourPointBudgetBytes: Int
        let traversalQueueBudgetBytes: Int
        let candidatePeakBytes: Int
        let samplingPeakBytes: Int
        let maskPeakBytes: Int
        let contourPeakBytes: Int
        let fittingPeakBytes: Int
        let contourPointLimit: Int
        let traversalQueueCapacity: Int

        /// Allocator size classes need not follow the estimate's power-of-two buckets.
        /// Charge only excess actual storage to every phase where that buffer is live.
        func validateActualStorage(
            maskCapacity: Int, visitedCapacity: Int? = nil, queueCapacity: Int? = nil
        ) throws {
            func excess(_ capacity: Int, stride: Int, reservation: Int) throws -> Int {
                guard capacity > 0 else { throw RTV2ReferenceMathError.invalidDimensions }
                let actual = try RTV2WorkingSetBudget.checkedSum([
                    RTV2WorkingSetBudget.checkedProduct([capacity, stride]),
                    RTV2WorkingSetBudget.storageAllowance,
                ])
                return max(0, actual - reservation)
            }
            let maskExcess = try excess(maskCapacity, stride: MemoryLayout<UInt64>.stride, reservation: packedMaskBytes)
            let visitedExcess = try visitedCapacity.map {
                try excess($0, stride: MemoryLayout<UInt64>.stride, reservation: contourVisitedBytes)
            } ?? 0
            let queueExcess = try queueCapacity.map {
                try excess($0, stride: MemoryLayout<Int>.stride, reservation: traversalQueueBudgetBytes)
            } ?? 0
            let actualMaskPeak = try RTV2WorkingSetBudget.checkedSum([maskPeakBytes, maskExcess])
            let actualContourPeak = try RTV2WorkingSetBudget.checkedSum([
                contourPeakBytes, maskExcess, visitedExcess, queueExcess,
            ])
            let actualFittingPeak = try RTV2WorkingSetBudget.checkedSum([fittingPeakBytes, maskExcess])
            guard max(samplingPeakBytes, actualMaskPeak, actualContourPeak, actualFittingPeak)
                    <= RTV2WorkingSetBudget.maximumCandidatePeakBytes else {
                throw RTV2ReferenceMathError.resourceBudgetExceeded
            }
        }
    }

    struct DecodeLayoutEstimate: Equatable, Sendable {
        let imageIOBackingBytes: Int
        let rgbaBytesPerRow: Int
        let rgbaBytes: Int
        let sourceRGBBytes: Int
        let normalizationPhaseBytes: Int
        let packingPhaseBytes: Int

        var peakBytes: Int { max(normalizationPhaseBytes, packingPhaseBytes) }
    }

    private struct DecodePackingEstimate {
        let rgbaBytesPerRow: Int
        let rgbaBytes: Int
        let sourceRGBBytes: Int
        let phaseBytes: Int
    }

    static func checkedProduct(_ factors: [Int]) throws -> Int {
        var result = 1
        for factor in factors {
            guard factor >= 0 else { throw RTV2ReferenceMathError.invalidDimensions }
            let next = result.multipliedReportingOverflow(by: factor)
            guard !next.overflow else { throw RTV2ReferenceMathError.sizeOverflow }
            result = next.partialValue
        }
        return result
    }

    static func checkedSum(_ values: [Int]) throws -> Int {
        var result = 0
        for value in values {
            guard value >= 0 else { throw RTV2ReferenceMathError.invalidDimensions }
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { throw RTV2ReferenceMathError.sizeOverflow }
            result = next.partialValue
        }
        return result
    }

    static func estimate(
        sourceWidth: Int,
        sourceHeight: Int,
        encodedByteCount: Int,
        cropSide: Int,
        sourceRGBStorageBytes: Int? = nil,
        samplingOutputSide: Int = encoderSide
    ) throws -> Estimate {
        let sourceBytes = try sourceStorageBytes(
            width: sourceWidth, height: sourceHeight,
            encodedByteCount: encodedByteCount,
            suppliedStorageBytes: sourceRGBStorageBytes
        )
        guard cropSide > 0, samplingOutputSide > 0 else { throw RTV2ReferenceMathError.invalidDimensions }
        let pixels = try checkedProduct([sourceWidth, sourceHeight])
        let maskPixels = try checkedProduct([cropSide, cropSide])
        let maskWords = try checkedSum([maskPixels, 63]) / 64
        let packedMaskBytes = try fixedArrayReservation(
            count: maskWords, stride: MemoryLayout<UInt64>.stride
        )
        let minimumDecodeBufferBytes = try checkedSum([
            encodedByteCount, try checkedProduct([pixels, 7]),
        ])
        let encoderPixelsBytes = try fixedArrayReservation(
            count: try checkedProduct([samplingOutputSide, samplingOutputSide, 3]), stride: 4
        )
        let support = min(cropSide, max(1, Int(ceil(
            max(1, Double(cropSide) / Double(samplingOutputSide)) * 2
        )) + 2))
        let rowBytes = try fixedArrayReservation(count: samplingOutputSide * 3, stride: 4)
        let maximumHorizontalCacheBytes = try checkedProduct([support, rowBytes])
        let warpBytes = try checkedProduct([
            2, fixedArrayReservation(count: cropSide, stride: 2 * MemoryLayout<Int>.stride),
        ])
        let kernelBytes = try checkedSum([
            try checkedProduct([2, fixedArrayReservation(
                count: samplingOutputSide, stride: MemoryLayout<Int>.stride + MemoryLayout<[Float]>.stride
            )]),
            try checkedProduct([2, samplingOutputSide, fixedArrayReservation(count: support, stride: 4)]),
            try fixedArrayReservation(count: support, stride: 8),
        ])
        let rowReferences = try fixedArrayReservation(
            count: support, stride: MemoryLayout<[Float]>.stride
        )
        // Old/new dictionary tables can overlap; their Float rows are aliases.
        let cacheTables = try checkedProduct([2, hashTableReservation(
            count: support, entryStride: MemoryLayout<Int>.stride + MemoryLayout<[Float]>.stride
        )])
        let base = try checkedSum([
            encodedByteCount, sourceBytes, retainedPipelineBufferBytes(),
        ])
        let samplingPeak = try checkedSum([
            base, encoderPixelsBytes, maximumHorizontalCacheBytes,
            warpBytes, kernelBytes, rowReferences, cacheTables,
            fixedArrayReservation(count: samplingOutputSide, stride: MemoryLayout<Int>.stride),
        ])
        let alignStride = 3 * MemoryLayout<Int>.stride
        let resizePlans = try checkedProduct([2, fixedArrayReservation(
            count: max(encoderSide, cropSide), stride: alignStride
        )])
        let maskPeak = try checkedSum([
            base, try checkedProduct([256, 64, 64, 4]),
            try checkedProduct([256, 256, 4]), 4,
            fixedArrayReservation(count: 256 * 256, stride: 4),
            fixedArrayReservation(count: encoderSide * encoderSide, stride: 4),
            resizePlans, packedMaskBytes,
        ])
        let queueCapacity = min(maximumTraversalQueueEntries, maskPixels)
        let queueBytes = try fixedArrayReservation(
            count: queueCapacity, stride: MemoryLayout<Int>.stride
        )
        var pointLimit = min(maximumContourPoints, max(8, try checkedProduct([maskPixels, 8])))
        var contourBytes = 0
        var contourPeak = 0
        var fittingPeak = 0
        while true {
            let bounds = try contourReservations(
                pointLimit: pointLimit, componentLimit: min(pointLimit, maskPixels)
            )
            contourBytes = bounds.gather
            contourPeak = try checkedSum([
                base, packedMaskBytes, packedMaskBytes, queueBytes, bounds.gather,
            ])
            fittingPeak = try checkedSum([base, packedMaskBytes, bounds.fitting])
            if max(contourPeak, fittingPeak) <= maximumCandidatePeakBytes || pointLimit == 8 {
                break
            }
            pointLimit = max(8, pointLimit / 2)
        }
        return Estimate(
            sourceRGBBytes: sourceBytes,
            minimumDecodeBufferBytes: minimumDecodeBufferBytes,
            streamedEncoderPixelsBytes: encoderPixelsBytes,
            maximumHorizontalCacheBytes: maximumHorizontalCacheBytes,
            packedMaskBytes: packedMaskBytes,
            contourVisitedBytes: packedMaskBytes,
            contourPointBudgetBytes: contourBytes,
            traversalQueueBudgetBytes: queueBytes,
            candidatePeakBytes: max(samplingPeak, maskPeak, contourPeak, fittingPeak),
            samplingPeakBytes: samplingPeak,
            maskPeakBytes: maskPeak,
            contourPeakBytes: contourPeak,
            fittingPeakBytes: fittingPeak,
            contourPointLimit: pointLimit,
            traversalQueueCapacity: queueCapacity
        )
    }

    /// Early rejection using only metadata. This excludes ImageIO backing and
    /// is not the full decode working-set validation.
    static func validateDecodePreflight(
        width: Int,
        height: Int,
        encodedByteCount: Int
    ) throws {
        let packing = try decodePackingEstimate(
            width: width, height: height, encodedByteCount: encodedByteCount
        )
        guard packing.phaseBytes <= maximumDecodePeakBytes else {
            throw RTV2ReferenceMathError.resourceBudgetExceeded
        }
    }

    /// The lazy CGImage supplies its real stride and pixel layout before draw.
    /// Its backing coexists with RGBA only; decode releases it before packing
    /// RGB, so the known peak is E + max(B + R, R + 3P).
    static func validateDecodeLayout(
        width: Int,
        height: Int,
        encodedByteCount: Int,
        imageIOBytesPerRow: Int,
        imageIOBitsPerPixel: Int
    ) throws -> DecodeLayoutEstimate {
        let packing = try decodePackingEstimate(
            width: width, height: height, encodedByteCount: encodedByteCount
        )
        guard imageIOBytesPerRow > 0, imageIOBitsPerPixel > 0 else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        let rowBits = try checkedProduct([width, imageIOBitsPerPixel])
        let minimumRowBytes = try checkedSum([rowBits, 7]) / 8
        guard imageIOBytesPerRow >= minimumRowBytes else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        let backingBytes = try checkedProduct([imageIOBytesPerRow, height])
        let normalizationBytes = try checkedSum([
            encodedByteCount, backingBytes, packing.rgbaBytes,
        ])
        let result = DecodeLayoutEstimate(
            imageIOBackingBytes: backingBytes,
            rgbaBytesPerRow: packing.rgbaBytesPerRow,
            rgbaBytes: packing.rgbaBytes,
            sourceRGBBytes: packing.sourceRGBBytes,
            normalizationPhaseBytes: normalizationBytes,
            packingPhaseBytes: packing.phaseBytes
        )
        guard result.peakBytes <= maximumDecodePeakBytes else {
            throw RTV2ReferenceMathError.resourceBudgetExceeded
        }
        return result
    }

    /// Called after ImageIO/CGContext ownership ends, before allocating RGB.
    static func validateRGBPacking(
        width: Int,
        height: Int,
        encodedByteCount: Int,
        rgbaByteCount: Int
    ) throws -> Int {
        let packing = try decodePackingEstimate(
            width: width, height: height, encodedByteCount: encodedByteCount
        )
        guard rgbaByteCount == packing.rgbaBytes else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        guard packing.phaseBytes <= maximumDecodePeakBytes else {
            throw RTV2ReferenceMathError.resourceBudgetExceeded
        }
        return packing.sourceRGBBytes
    }

    private static func decodePackingEstimate(
        width: Int,
        height: Int,
        encodedByteCount: Int
    ) throws -> DecodePackingEstimate {
        guard width > 0, height > 0, encodedByteCount >= 0 else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        let rgbaBytesPerRow = try checkedProduct([width, 4])
        let rgbaBytes = try checkedProduct([rgbaBytesPerRow, height])
        let rgbBytes = try checkedProduct([width, height, 3])
        return DecodePackingEstimate(
            rgbaBytesPerRow: rgbaBytesPerRow,
            rgbaBytes: rgbaBytes,
            sourceRGBBytes: rgbBytes,
            phaseBytes: try checkedSum([encodedByteCount, rgbaBytes, rgbBytes])
        )
    }

    @discardableResult
    static func validateCandidate(
        sourceWidth: Int,
        sourceHeight: Int,
        cropSide: Int,
        encodedByteCount: Int = 0,
        sourceRGBStorageBytes: Int? = nil,
        samplingOutputSide: Int = encoderSide
    ) throws -> Estimate {
        let estimate = try estimate(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            encodedByteCount: encodedByteCount, cropSide: cropSide,
            sourceRGBStorageBytes: sourceRGBStorageBytes,
            samplingOutputSide: samplingOutputSide
        )
        guard estimate.candidatePeakBytes <= maximumCandidatePeakBytes else {
            throw RTV2ReferenceMathError.resourceBudgetExceeded
        }
        return estimate
    }

    // Reservations cover current native collection capacity buckets and growth,
    // rather than equating capacity with count. Eight machine words allow for
    // small-storage headers/alignment. They are conservative app-buffer
    // reservations, not a guarantee about future allocators or whole-process RSS.
    private static let storageAllowance = 8 * MemoryLayout<Int>.stride

    static func fixedArrayReservation(count: Int, stride: Int) throws -> Int {
        guard count >= 0, stride > 0 else { throw RTV2ReferenceMathError.invalidDimensions }
        guard count > 0 else { return 0 }
        return try powerOfTwoCeiling(checkedSum([
            checkedProduct([count, stride]), storageAllowance,
        ]))
    }

    private static func powerOfTwoCeiling(_ value: Int) throws -> Int {
        guard value >= 0 else { throw RTV2ReferenceMathError.invalidDimensions }
        var result = 1
        while result < value {
            guard result <= Int.max / 2 else { throw RTV2ReferenceMathError.sizeOverflow }
            result *= 2
        }
        return result
    }

    private static func hashTableReservation(count: Int, entryStride: Int) throws -> Int {
        let buckets = try powerOfTwoCeiling(checkedProduct([max(1, count), 2]))
        return try checkedSum([
            checkedProduct([buckets, entryStride]),
            checkedProduct([checkedSum([buckets, 63]) / 64, MemoryLayout<UInt64>.stride]),
            storageAllowance,
        ])
    }

    private static func retainedPipelineBufferBytes() throws -> Int {
        // One reusable encoder input/prompt, detector input and known returned
        // logits/boxes; model weights and hidden prediction scratch are excluded.
        try checkedSum([
            checkedProduct([3, 768, 768, 4]),
            checkedProduct([3, encoderSide, encoderSide, 4]), 4 * 4,
            (300 + 300 * 4) * 4,
            // Boxes contain one Int and five Floats, rounded to Int alignment.
            checkedProduct([2, fixedArrayReservation(
                count: 300, stride: 4 * MemoryLayout<Int>.stride
            )]),
            checkedProduct([2, fixedArrayReservation(
                count: 300, stride: MemoryLayout<[RTV2Point]>.stride
            )]),
            checkedProduct([300, fixedArrayReservation(count: 4, stride: MemoryLayout<RTV2Point>.stride)]),
            checkedProduct([3, fixedArrayReservation(count: 256, stride: 4)]),
        ])
    }

    private static func sourceStorageBytes(
        width: Int, height: Int, encodedByteCount: Int, suppliedStorageBytes: Int?
    ) throws -> Int {
        guard width > 0, height > 0, encodedByteCount >= 0,
              encodedByteCount <= maximumSupportedEncodedInputBytes else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        let logical = try checkedProduct([width, height, 3])
        let storage = suppliedStorageBytes ?? logical
        guard storage >= logical else { throw RTV2ReferenceMathError.invalidDimensions }
        return storage
    }

    private static func contourReservations(
        pointLimit: Int, componentLimit: Int
    ) throws -> (gather: Int, fitting: Int) {
        let p = try fixedArrayReservation(count: pointLimit, stride: MemoryLayout<RTV2Point>.stride)
        let twoP = try fixedArrayReservation(count: checkedProduct([pointLimit, 2]), stride: MemoryLayout<RTV2Point>.stride)
        let doubles = try fixedArrayReservation(count: pointLimit, stride: MemoryLayout<Double>.stride)
        let outer = try fixedArrayReservation(count: componentLimit, stride: MemoryLayout<[RTV2Point]>.stride)
        // Sum of growing contour capacities: <=4*(payload + header allowance).
        // A next contour is traced before the aggregate limit is tested. During
        // growth its old/new buffer overlap is bounded separately (3*p).
        let contours = try checkedSum([
            checkedProduct([4, pointLimit, MemoryLayout<RTV2Point>.stride]),
            checkedProduct([4, componentLimit, storageAllowance]),
        ])
        let gather = try checkedSum([
            contours, max(checkedSum([checkedProduct([3, p]), checkedProduct([2, outer])]),
                          checkedProduct([3, outer])),
        ])
        let small = try fixedArrayReservation(count: 64, stride: 4 * MemoryLayout<Int>.stride)
        let sorting = try checkedSum([
            checkedProduct([7, p]), hashTableReservation(count: pointLimit, entryStride: MemoryLayout<RTV2Point>.stride), small,
        ])
        let hull = try checkedSum([checkedProduct([9, p]), twoP, small])
        // Four edge buckets partition exterior points; do not multiply their
        // maximum individual sizes by four. Fitting each edge is sequential.
        let edgeBuckets = try checkedSum([
            checkedProduct([4, pointLimit, MemoryLayout<RTV2Point>.stride]),
            checkedProduct([16, storageAllowance]),
        ])
        let edgeFit = try checkedSum([
            edgeBuckets, checkedProduct([2, p]),
            max(checkedProduct([3, p]), checkedSum([checkedProduct([2, p]), checkedProduct([2, doubles])])),
        ])
        let refine = try checkedSum([
            checkedProduct([4, p]), twoP,
            fixedArrayReservation(count: checkedProduct([pointLimit, 2]), stride: MemoryLayout<Double>.stride),
            max(checkedSum([edgeBuckets, p]), edgeFit), small,
        ])
        return (gather, max(sorting, hull, refine))
    }

    static func validateDetectorPreprocessing(
        width: Int, height: Int, encodedByteCount: Int, sourceRGBStorageBytes: Int
    ) throws {
        let sourceBytes = try sourceStorageBytes(
            width: width, height: height, encodedByteCount: encodedByteCount,
            suppliedStorageBytes: sourceRGBStorageBytes
        )
        let resized = try fixedArrayReservation(count: 3 * 768 * 768, stride: 1)
        let entries = try checkedSum([width, height, 4 * 768])
        let plans = try checkedSum([
            checkedProduct([2, entries, 2 * MemoryLayout<Int>.stride]),
            checkedProduct([4, 768, storageAllowance]),
            checkedProduct([2, fixedArrayReservation(count: 768, stride: MemoryLayout<[Int]>.stride)]),
        ])
        let peak = try checkedSum([
            encodedByteCount, sourceBytes, resized,
            max(plans, retainedPipelineBufferBytes()),
            checkedProduct([3, fixedArrayReservation(count: 256, stride: 4)]),
        ])
        guard peak <= maximumCandidatePeakBytes else {
            throw RTV2ReferenceMathError.resourceBudgetExceeded
        }
    }

    /// Actual allocator capacity is a charge against a phase's total budget,
    /// not a guarantee that malloc follows the reservation's size classes.
    static func actualFixedArrayStorage(count: Int, capacity: Int, stride: Int) throws -> Int {
        guard count >= 0, capacity >= count, stride > 0 else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        guard capacity > 0 else { return 0 }
        return try checkedSum([checkedProduct([capacity, stride]), storageAllowance])
    }

    static func validateFixedCapacity(count: Int, capacity: Int, stride: Int) throws {
        guard capacity >= count,
              try checkedProduct([capacity, stride]) <= fixedArrayReservation(count: count, stride: stride) else {
            throw RTV2ReferenceMathError.resourceBudgetExceeded
        }
    }

}

struct RTV2BinaryMask: Sendable {
    let width: Int
    let height: Int
    private let words: [UInt64]

    init(width: Int, height: Int, values: [Bool]) {
        self.width = width
        self.height = height
        let expected = (try? RTV2WorkingSetBudget.checkedProduct([width, height])) ?? -1
        guard expected >= 0, values.count == expected,
              let padded = try? RTV2WorkingSetBudget.checkedSum([expected, 63]) else {
            words = []
            return
        }
        var packed = Array(repeating: UInt64(0), count: padded / 64)
        for index in values.indices where values[index] {
            packed[index >> 6] |= UInt64(1) << UInt64(index & 63)
        }
        words = packed
    }

    init(width: Int, height: Int, packedWords: [UInt64]) {
        self.width = width
        self.height = height
        words = packedWords
    }

    var count: Int {
        (try? RTV2WorkingSetBudget.checkedProduct([width, height])) ?? 0
    }

    var storageCapacity: Int { words.capacity }

    @inline(__always)
    func value(at index: Int) -> Bool {
        guard index >= 0, index < count, (index >> 6) < words.count else { return false }
        return words[index >> 6] & (UInt64(1) << UInt64(index & 63)) != 0
    }
}

private struct RTV2MutableBitSet {
    private var words: [UInt64]
    let count: Int

    init(
        count: Int, capacityBudget: RTV2WorkingSetBudget.Estimate? = nil,
        maskCapacity: Int = 0
    ) throws {
        guard count >= 0 else { throw RTV2ReferenceMathError.invalidDimensions }
        let wordCount = try RTV2WorkingSetBudget.checkedSum([count, 63]) / 64
        words = Array(repeating: 0, count: wordCount)
        if let capacityBudget {
            guard words.capacity >= wordCount else { throw RTV2ReferenceMathError.resourceBudgetExceeded }
            try capacityBudget.validateActualStorage(maskCapacity: maskCapacity, visitedCapacity: words.capacity)
        } else {
            try RTV2WorkingSetBudget.validateFixedCapacity(
                count: wordCount, capacity: words.capacity, stride: MemoryLayout<UInt64>.stride
            )
        }
        self.count = count
    }

    var storageCapacity: Int { words.capacity }

    @inline(__always)
    func contains(_ index: Int) -> Bool {
        guard index >= 0, index < count else { return false }
        return words[index >> 6] & (UInt64(1) << UInt64(index & 63)) != 0
    }

    @inline(__always)
    mutating func insert(_ index: Int) {
        words[index >> 6] |= UInt64(1) << UInt64(index & 63)
    }
}

struct RTV2Point: Sendable, Equatable, Hashable {
    var x: Double
    var y: Double
}

/// One deterministic TL/TR/BR/BL contract shared by the fitter and the final
/// detector mapping. Coordinates use image space (y increases downward), so
/// TL -> TR -> BR -> BL has a positive signed area.
enum RTV2QuadrilateralCanonicalizer {
    private static let duplicateToleranceSquared = 0.000_001
    private static let minimumArea = 1.0

    static func canonicalTLTRBRBL(_ points: [RTV2Point]) throws -> [RTV2Point] {
        guard points.count == 4,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw RTV2ReferenceMathError.invalidQuadrilateral
        }
        for left in points.indices {
            for right in points.indices where right > left {
                guard squaredDistance(points[left], points[right])
                    > duplicateToleranceSquared else {
                    throw RTV2ReferenceMathError.invalidQuadrilateral
                }
            }
        }
        let center = RTV2Point(
            x: points.reduce(0) { $0 + $1.x / 4 },
            y: points.reduce(0) { $0 + $1.y / 4 }
        )
        guard center.x.isFinite, center.y.isFinite else {
            throw RTV2ReferenceMathError.invalidQuadrilateral
        }
        var ring = points.sorted { lhs, rhs in
            let lhsAngle = atan2(lhs.y - center.y, lhs.x - center.x)
            let rhsAngle = atan2(rhs.y - center.y, rhs.x - center.x)
            if lhsAngle != rhsAngle { return lhsAngle < rhsAngle }
            let lhsRadius = squaredDistance(lhs, center)
            let rhsRadius = squaredDistance(rhs, center)
            if lhsRadius != rhsRadius { return lhsRadius < rhsRadius }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }
        if signedArea(ring) < 0 {
            ring.reverse()
        }
        guard let anchor = ring.indices.min(by: {
            topLeftKey(ring[$0]) < topLeftKey(ring[$1])
        }) else {
            throw RTV2ReferenceMathError.invalidQuadrilateral
        }
        ring = Array(ring[anchor...]) + Array(ring[..<anchor])
        let area = signedArea(ring)
        let crosses = ring.indices.map { index in
            cross(ring[index], ring[(index + 1) % 4], ring[(index + 2) % 4])
        }
        guard area >= minimumArea,
              crosses.allSatisfy({ $0 > .ulpOfOne }),
              !segmentsIntersect(ring[0], ring[1], ring[2], ring[3]),
              !segmentsIntersect(ring[1], ring[2], ring[3], ring[0]) else {
            throw RTV2ReferenceMathError.invalidQuadrilateral
        }
        return ring
    }

    private static func topLeftKey(_ point: RTV2Point) -> (Double, Double, Double) {
        (point.x / 2 + point.y / 2, point.y, point.x)
    }

    private static func squaredDistance(_ lhs: RTV2Point, _ rhs: RTV2Point) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func signedArea(_ points: [RTV2Point]) -> Double {
        points.indices.reduce(0) { result, index in
            let next = points[(index + 1) % points.count]
            return result + points[index].x * next.y - next.x * points[index].y
        } / 2
    }

    private static func cross(_ a: RTV2Point, _ b: RTV2Point, _ c: RTV2Point) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func segmentsIntersect(
        _ a: RTV2Point,
        _ b: RTV2Point,
        _ c: RTV2Point,
        _ d: RTV2Point
    ) -> Bool {
        let first = cross(a, b, c)
        let second = cross(a, b, d)
        let third = cross(c, d, a)
        let fourth = cross(c, d, b)
        return first * second <= 0 && third * fourth <= 0
    }
}

struct RTV2TraversalQueue {
    private var values: [Int]
    private var readIndex = 0
    private var writeIndex = 0
    private(set) var count = 0

    init(
        capacity: Int, capacityBudget: RTV2WorkingSetBudget.Estimate? = nil,
        maskCapacity: Int = 0, visitedCapacity: Int = 0
    ) throws {
        guard (1...RTV2WorkingSetBudget.maximumTraversalQueueEntries).contains(capacity) else {
            throw RTV2ReferenceMathError.invalidDimensions
        }
        values = Array(repeating: 0, count: capacity)
        if let capacityBudget {
            guard values.capacity >= capacity else { throw RTV2ReferenceMathError.resourceBudgetExceeded }
            try capacityBudget.validateActualStorage(
                maskCapacity: maskCapacity, visitedCapacity: visitedCapacity, queueCapacity: values.capacity
            )
        } else {
            try RTV2WorkingSetBudget.validateFixedCapacity(
                count: capacity, capacity: values.capacity, stride: MemoryLayout<Int>.stride
            )
        }
    }

    var capacity: Int { values.count }
    var storageCapacity: Int { values.capacity }

    mutating func reset() {
        readIndex = 0
        writeIndex = 0
        count = 0
    }

    mutating func append(_ value: Int) throws {
        guard count < capacity else { throw RTV2ReferenceMathError.resourceBudgetExceeded }
        values[writeIndex] = value
        writeIndex = writeIndex + 1 == capacity ? 0 : writeIndex + 1
        count += 1
    }

    mutating func popFirst() -> Int? {
        guard count > 0 else { return nil }
        let result = values[readIndex]
        readIndex = readIndex + 1 == capacity ? 0 : readIndex + 1
        count -= 1
        return result
    }
}

enum RTV2QuadrilateralFitter {
    private enum LineOrientation { case horizontal, vertical }
    private struct Line {
        let orientation: LineOrientation
        let slope: Double
        let intercept: Double
    }

    static func fit(
        mask: RTV2BinaryMask,
        pointLimit: Int = RTV2WorkingSetBudget.maximumContourPoints,
        queueCapacity: Int? = nil,
        capacityBudget: RTV2WorkingSetBudget.Estimate? = nil
    ) throws -> [RTV2Point] {
        let points = try externalContourPoints(
            mask, pointLimit: pointLimit, queueCapacity: queueCapacity, capacityBudget: capacityBudget
        )
        guard points.count >= 8 else { throw RTV2ReferenceMathError.invalidMask }
        let hull = convexHull(points)
        guard hull.count >= 3 else { throw RTV2ReferenceMathError.invalidMask }
        var farthest = (first: 0, second: 0, distance: -Double.infinity)
        for first in hull.indices {
            for second in hull.indices where second > first {
                let dx = hull[second].x - hull[first].x
                let dy = hull[second].y - hull[first].y
                let value = dx * dx + dy * dy
                if value > farthest.distance {
                    farthest = (first, second, value)
                }
            }
        }
        let first = hull[farthest.first]
        let second = hull[farthest.second]
        let vx = second.x - first.x
        let vy = second.y - first.y
        let norm = sqrt(vx * vx + vy * vy)
        guard norm >= 1 else { throw RTV2ReferenceMathError.invalidMask }
        let signed = hull.map { point in
            (vx * (point.y - first.y) - vy * (point.x - first.x)) / norm
        }
        let maximumIndex = signed.indices.max(by: { signed[$0] < signed[$1] })!
        let minimumIndex = signed.indices.min(by: { signed[$0] < signed[$1] })!
        let approximate = angularOrder([
            first, second, hull[maximumIndex], hull[minimumIndex],
        ])
        let shrunk = shrink(approximate, factor: 0.03)
        var exterior = points.filter { !inside($0, quad: shrunk) }
        if exterior.count < 4 { exterior = points }
        let initial = angularOrder(minimumAreaRectangle(hull))
        return try RTV2QuadrilateralCanonicalizer.canonicalTLTRBRBL(
            refine(exterior: exterior, initial: initial)
        )
    }

    static func order(_ points: [RTV2Point]) throws -> [RTV2Point] {
        try RTV2QuadrilateralCanonicalizer.canonicalTLTRBRBL(points)
    }

    static func initialQuadrilateralForTesting(mask: RTV2BinaryMask) throws -> [RTV2Point] {
        let points = try externalContourPoints(mask)
        guard points.count >= 8 else { throw RTV2ReferenceMathError.invalidMask }
        return angularOrder(minimumAreaRectangle(convexHull(points)))
    }

    static func contourPointsForTesting(mask: RTV2BinaryMask) throws -> [RTV2Point] {
        try externalContourPoints(mask)
    }

    private static func externalContourPoints(
        _ mask: RTV2BinaryMask,
        pointLimit: Int = RTV2WorkingSetBudget.maximumContourPoints,
        queueCapacity: Int? = nil,
        capacityBudget: RTV2WorkingSetBudget.Estimate? = nil
    ) throws -> [RTV2Point] {
        let width = mask.width
        let height = mask.height
        let pixelCount = try RTV2WorkingSetBudget.checkedProduct([width, height])
        guard width > 0, height > 0, mask.count == pixelCount,
              (8...RTV2WorkingSetBudget.maximumContourPoints).contains(pointLimit) else {
            throw RTV2ReferenceMathError.invalidMask
        }
        let directions = [
            (0, -1), (-1, -1), (-1, 0), (-1, 1),
            (0, 1), (1, 1), (1, 0), (1, -1),
        ]
        func isForeground(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height
                && mask.value(at: y * width + x)
        }
        func directionIndex(dx: Int, dy: Int) -> Int? {
            directions.firstIndex { $0.0 == dx && $0.1 == dy }
        }
        func trace(startX: Int, startY: Int) throws -> [RTV2Point] {
            // OpenCV CHAIN_APPROX_NONE begins at the first foreground pixel
            // found by row scan and performs clockwise Moore-neighborhood
            // tracing with the west pixel as its initial backtrack point.
            var current = (x: startX, y: startY)
            var backtrack = (x: startX - 1, y: startY)
            var contour = [RTV2Point(x: Double(startX), y: Double(startY))]
            var firstSuccessor: (x: Int, y: Int)?
            var completed = false
            let maximumSteps = max(
                min(
                    try RTV2WorkingSetBudget.checkedProduct([pixelCount, 8]),
                    pointLimit
                ),
                8
            )
            for _ in 0..<maximumSteps {
                let relative = (
                    dx: backtrack.x - current.x,
                    dy: backtrack.y - current.y
                )
                let startDirection = directionIndex(dx: relative.dx, dy: relative.dy) ?? 2
                var successor: (x: Int, y: Int)?
                var predecessor = backtrack
                for step in 1...8 {
                    let index = (startDirection + step) & 7
                    let candidate = (
                        x: current.x + directions[index].0,
                        y: current.y + directions[index].1
                    )
                    if isForeground(candidate.x, candidate.y) {
                        successor = candidate
                        let previousIndex = (index + 7) & 7
                        predecessor = (
                            x: current.x + directions[previousIndex].0,
                            y: current.y + directions[previousIndex].1
                        )
                        break
                    }
                }
                guard let successor else {
                    completed = true
                    break
                }
                if firstSuccessor == nil { firstSuccessor = successor }
                if successor.x == startX,
                   successor.y == startY,
                   contour.count > 1 {
                    completed = true
                    break
                }
                if current.x == startX,
                   current.y == startY,
                   contour.count > 1,
                   successor.x == firstSuccessor?.x,
                   successor.y == firstSuccessor?.y {
                    completed = true
                    break
                }
                backtrack = predecessor
                current = successor
                guard contour.count < pointLimit else {
                    throw RTV2ReferenceMathError.resourceBudgetExceeded
                }
                contour.append(RTV2Point(x: Double(current.x), y: Double(current.y)))
            }
            guard completed else {
                throw RTV2ReferenceMathError.resourceBudgetExceeded
            }
            return contour
        }

        var componentVisited = try RTV2MutableBitSet(
            count: pixelCount, capacityBudget: capacityBudget, maskCapacity: mask.storageCapacity
        )
        // Allocate once; each component resets only the FIFO indices.
        var queue = try RTV2TraversalQueue(
            capacity: min(queueCapacity ?? RTV2WorkingSetBudget.maximumTraversalQueueEntries, pixelCount),
            capacityBudget: capacityBudget, maskCapacity: mask.storageCapacity,
            visitedCapacity: componentVisited.storageCapacity
        )
        var contours: [[RTV2Point]] = []
        var totalContourPoints = 0
        for y in 0..<height {
            for x in 0..<width where isForeground(x, y)
                && !componentVisited.contains(y * width + x) {
                let contour = try trace(startX: x, startY: y)
                totalContourPoints = try RTV2WorkingSetBudget.checkedSum([
                    totalContourPoints, contour.count,
                ])
                guard totalContourPoints <= pointLimit else {
                    throw RTV2ReferenceMathError.resourceBudgetExceeded
                }
                contours.append(contour)
                queue.reset()
                try queue.append(y * width + x)
                componentVisited.insert(y * width + x)
                while let point = queue.popFirst() {
                    let pointX = point % width
                    let pointY = point / width
                    for direction in directions {
                        let next = (x: pointX + direction.0, y: pointY + direction.1)
                        guard isForeground(next.x, next.y) else { continue }
                        let index = next.y * width + next.x
                        if !componentVisited.contains(index) {
                            componentVisited.insert(index)
                            try queue.append(index)
                        }
                    }
                }
            }
        }
        // OpenCV's contour scanner links newly discovered external contours
        // before older siblings, so RETR_EXTERNAL returns them in reverse scan
        // discovery order.
        return contours.reversed().flatMap { $0 }
    }

    private static func convexHull(_ points: [RTV2Point]) -> [RTV2Point] {
        let sorted = Array(Set(points)).sorted {
            $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        }
        guard sorted.count > 2 else { return sorted }
        func cross(_ origin: RTV2Point, _ first: RTV2Point, _ second: RTV2Point) -> Double {
            (first.x - origin.x) * (second.y - origin.y)
                - (first.y - origin.y) * (second.x - origin.x)
        }
        var lower: [RTV2Point] = []
        for point in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [RTV2Point] = []
        for point in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func minimumAreaRectangle(_ hull: [RTV2Point]) -> [RTV2Point] {
        var bestArea = Double.infinity
        var best: [RTV2Point] = []
        for index in hull.indices {
            let next = hull[(index + 1) % hull.count]
            let angle = atan2(next.y - hull[index].y, next.x - hull[index].x)
            let cosine = cos(angle)
            let sine = sin(angle)
            let rotated = hull.map { point in
                RTV2Point(
                    x: point.x * cosine + point.y * sine,
                    y: -point.x * sine + point.y * cosine
                )
            }
            let minimumX = rotated.map(\.x).min()!
            let maximumX = rotated.map(\.x).max()!
            let minimumY = rotated.map(\.y).min()!
            let maximumY = rotated.map(\.y).max()!
            let area = (maximumX - minimumX) * (maximumY - minimumY)
            if area < bestArea {
                bestArea = area
                best = [
                    RTV2Point(x: minimumX, y: minimumY),
                    RTV2Point(x: maximumX, y: minimumY),
                    RTV2Point(x: maximumX, y: maximumY),
                    RTV2Point(x: minimumX, y: maximumY),
                ].map { point in
                    RTV2Point(
                        x: point.x * cosine - point.y * sine,
                        y: point.x * sine + point.y * cosine
                    )
                }
            }
        }
        return best
    }

    private static func angularOrder(_ points: [RTV2Point]) -> [RTV2Point] {
        let center = RTV2Point(
            x: points.map(\.x).reduce(0, +) / Double(points.count),
            y: points.map(\.y).reduce(0, +) / Double(points.count)
        )
        return points.sorted {
            atan2($0.y - center.y, $0.x - center.x)
                < atan2($1.y - center.y, $1.x - center.x)
        }
    }

    private static func shrink(_ points: [RTV2Point], factor: Double) -> [RTV2Point] {
        let center = RTV2Point(
            x: points.map(\.x).reduce(0, +) / Double(points.count),
            y: points.map(\.y).reduce(0, +) / Double(points.count)
        )
        return points.map {
            RTV2Point(
                x: $0.x + factor * (center.x - $0.x),
                y: $0.y + factor * (center.y - $0.y)
            )
        }
    }

    private static func inside(_ point: RTV2Point, quad: [RTV2Point]) -> Bool {
        let signedArea = quad.indices.reduce(0.0) { total, index in
            let next = quad[(index + 1) % 4]
            return total + quad[index].x * next.y - next.x * quad[index].y
        }
        let clockwise = signedArea > 0
        return quad.indices.allSatisfy { index in
            let first = quad[index]
            let second = quad[(index + 1) % 4]
            let cross = (second.x - first.x) * (point.y - first.y)
                - (second.y - first.y) * (point.x - first.x)
            return clockwise ? cross >= 0 : cross <= 0
        }
    }

    private static func refine(exterior: [RTV2Point], initial: [RTV2Point]) -> [RTV2Point] {
        let initialLines = [
            line(initial[0], initial[1]), line(initial[1], initial[2]),
            line(initial[2], initial[3]), line(initial[3], initial[0]),
        ]
        var edgePoints = Array(repeating: [RTV2Point](), count: 4)
        for point in exterior {
            let index = initialLines.indices.min {
                distance(point, to: initialLines[$0]) < distance(point, to: initialLines[$1])
            }!
            edgePoints[index].append(point)
        }
        let refined = initialLines.indices.map {
            fitLine(points: edgePoints[$0], initial: initialLines[$0])
        }
        let pairs = [(0, 3), (0, 1), (2, 1), (2, 3)]
        return pairs.enumerated().map { index, pair in
            intersection(refined[pair.0], refined[pair.1]) ?? initial[index]
        }
    }

    private static func line(_ first: RTV2Point, _ second: RTV2Point) -> Line {
        let dx = second.x - first.x
        let dy = second.y - first.y
        if abs(dx) > abs(dy) {
            let slope = dy / (dx + 0.000_000_001)
            return Line(
                orientation: .horizontal,
                slope: slope,
                intercept: first.y - slope * first.x
            )
        }
        let slope = dx / (dy + 0.000_000_001)
        return Line(
            orientation: .vertical,
            slope: slope,
            intercept: first.x - slope * first.y
        )
    }

    private static func distance(_ point: RTV2Point, to line: Line) -> Double {
        switch line.orientation {
        case .horizontal:
            return abs(point.y - (line.slope * point.x + line.intercept))
        case .vertical:
            return abs(point.x - (line.slope * point.y + line.intercept))
        }
    }

    /// NumPy keeps x/y as float32 after fitting even though `lstsq` returns
    /// float64 coefficients. Re-entering float32 here preserves its inlier
    /// threshold decisions.
    private static func fittedDistance(_ point: RTV2Point, to line: Line) -> Double {
        let independent: Float
        let dependent: Float
        switch line.orientation {
        case .horizontal:
            independent = Float(point.x)
            dependent = Float(point.y)
        case .vertical:
            independent = Float(point.y)
            dependent = Float(point.x)
        }
        let prediction = Float(line.slope) * independent + Float(line.intercept)
        return Double(abs(dependent - prediction))
    }

    private static func fitLine(points raw: [RTV2Point], initial: Line) -> Line {
        guard raw.count >= 5 else { return initial }
        let points = raw.filter { distance($0, to: initial) < 80 }
        guard points.count >= 5 else { return initial }
        var random = NumPyPCG64Seed42()
        var bestInliers = 0
        var best = initial
        for _ in 0..<min(500, points.count * 10) {
            let sample = random.choiceWithoutReplacement(
                upperBound: points.count,
                count: 5
            ).map { points[$0] }
            guard let fitted = leastSquares(sample, orientation: initial.orientation) else {
                continue
            }
            let inliers = points.lazy.filter { fittedDistance($0, to: fitted) < 5 }.count
            if inliers > bestInliers {
                bestInliers = inliers
                best = fitted
            }
        }
        let inliers = points.filter { fittedDistance($0, to: best) < 5 }
        return inliers.count >= 3
            ? leastSquares(inliers, orientation: initial.orientation) ?? best
            : best
    }

    private static func leastSquares(
        _ points: [RTV2Point],
        orientation: LineOrientation
    ) -> Line? {
        // The Python input is explicitly float32 before hstack promotes the
        // two-column design matrix to float64.
        let xs = points.map {
            Double(Float(orientation == .horizontal ? $0.x : $0.y))
        }
        let ys = points.map {
            Double(Float(orientation == .horizontal ? $0.y : $0.x))
        }
        let count = Double(points.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = count * sumXX - sumX * sumX
        guard abs(denominator) > 1e-12 else { return nil }
        let slope = (count * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / count
        return Line(orientation: orientation, slope: slope, intercept: intercept)
    }

    private static func intersection(_ first: Line, _ second: Line) -> RTV2Point? {
        func standard(_ line: Line) -> (Double, Double, Double) {
            switch line.orientation {
            case .horizontal: return (-line.slope, 1, -line.intercept)
            case .vertical: return (1, -line.slope, -line.intercept)
            }
        }
        let firstStandard = standard(first)
        let secondStandard = standard(second)
        let denominator = firstStandard.0 * secondStandard.1
            - secondStandard.0 * firstStandard.1
        guard abs(denominator) >= 1e-9 else { return nil }
        return RTV2Point(
            x: (firstStandard.1 * secondStandard.2
                - secondStandard.1 * firstStandard.2) / denominator,
            y: (firstStandard.2 * secondStandard.0
                - secondStandard.2 * firstStandard.0) / denominator
        )
    }
}

enum RTV2ReferenceMathError: Error {
    case invalidMask
    case invalidQuadrilateral
    case invalidDimensions
    case sizeOverflow
    case resourceBudgetExceeded
}

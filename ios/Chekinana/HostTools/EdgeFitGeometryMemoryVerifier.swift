import Foundation

@main
struct EdgeFitGeometryMemoryVerifier {
    static func main() throws {
        if CommandLine.arguments.contains("--decode-budget-only") {
            try verifyDecodeLayoutBudget()
            print("PASS decode-budget=measured-layout phase-release=checked")
            return
        }
        try verifyCanonicalOrder()
        try verifyStreamingSquare20Equivalence()
        try verifyPackedMaskEquivalence()
        try verifyFortyEightMegapixelBudget()
        try verifyDecodeLayoutBudget()
        print("PASS geometry=canonical permutations=24 streaming=exact mask=exact budget=controlled")
    }

    private static func verifyCanonicalOrder() throws {
        let counterexample = [
            RTV2Point(x: 130, y: 15),
            RTV2Point(x: 190, y: 100),
            RTV2Point(x: 135, y: 215),
            RTV2Point(x: 65, y: 110),
        ]
        for permutation in permutations(counterexample) {
            let actual = try RTV2QuadrilateralCanonicalizer
                .canonicalTLTRBRBL(permutation)
            guard actual == counterexample, Set(actual) == Set(counterexample) else {
                throw VerificationError.canonicalizationMismatch
            }
        }

        let legalCases = [
            [
                RTV2Point(x: 100, y: 0), RTV2Point(x: 200, y: 100),
                RTV2Point(x: 100, y: 200), RTV2Point(x: 0, y: 100),
            ],
            [
                RTV2Point(x: 30, y: 20), RTV2Point(x: 180, y: 45),
                RTV2Point(x: 150, y: 170), RTV2Point(x: 50, y: 150),
            ],
            [
                RTV2Point(x: -40, y: -20), RTV2Point(x: 120, y: -10),
                RTV2Point(x: 130, y: 240), RTV2Point(x: -30, y: 230),
            ],
        ]
        for points in legalCases {
            let expected = try RTV2QuadrilateralCanonicalizer
                .canonicalTLTRBRBL(points)
            for permutation in permutations(points) {
                guard try RTV2QuadrilateralCanonicalizer
                    .canonicalTLTRBRBL(permutation) == expected else {
                    throw VerificationError.canonicalizationMismatch
                }
            }
        }

        let invalidCases = [
            [
                RTV2Point(x: .nan, y: 0), RTV2Point(x: 10, y: 0),
                RTV2Point(x: 10, y: 10), RTV2Point(x: 0, y: 10),
            ],
            [
                RTV2Point(x: 0, y: 0), RTV2Point(x: 0.000_5, y: 0),
                RTV2Point(x: 10, y: 10), RTV2Point(x: 0, y: 10),
            ],
            [
                RTV2Point(x: 0, y: 0), RTV2Point(x: 10, y: 0),
                RTV2Point(x: 20, y: 0), RTV2Point(x: 30, y: 0),
            ],
            [
                RTV2Point(x: 0, y: 0), RTV2Point(x: 20, y: 0),
                RTV2Point(x: 0, y: 20), RTV2Point(x: 2, y: 2),
            ],
        ]
        for points in invalidCases {
            do {
                _ = try RTV2QuadrilateralCanonicalizer.canonicalTLTRBRBL(points)
                throw VerificationError.invalidGeometryAccepted
            } catch RTV2ReferenceMathError.invalidQuadrilateral {
                // Expected.
            }
        }
    }

    private static func verifyStreamingSquare20Equivalence() throws {
        let width = 96
        let height = 83
        let source: [UInt8] = (0..<(width * height * 3)).map { index in
            UInt8(truncatingIfNeeded: index &* 37 &+ index / 7)
        }
        let cases: [[Float]] = [
            [12.25, 7.5, 59.0, 53.25],
            [-8.5, -4.25, 39.0, 42.0],
            [9.5, 4.5, 56.0, 50.5],
            [7.25, 3.75, 54.5, 51.25],
        ]
        for box in cases {
            let reference = try ChekinanaEdgeFitRTV2ReferenceMath
                .openCVSquare20WarpFP32(
                    source,
                    width: width,
                    height: height,
                    box: box,
                    borderRGB: [123.675, 116.28, 103.53]
                )
            let actual = try ChekinanaEdgeFitRTV2ReferenceMath
                .streamingSquare20PillowResizeFP32(
                    source,
                    width: width,
                    height: height,
                    box: box,
                    borderRGB: [123.675, 116.28, 103.53],
                    outputSide: 1_024
                )
            guard reference.side == actual.crop.side else {
                throw VerificationError.streamingMismatch
            }
            var expectedPlanes = Array(repeating: [Float](), count: 3)
            for channel in 0..<3 {
                expectedPlanes[channel].reserveCapacity(reference.side * reference.side)
            }
            for offset in stride(from: 0, to: reference.pixels.count, by: 3) {
                for channel in 0..<3 {
                    expectedPlanes[channel].append(reference.pixels[offset + channel])
                }
            }
            let resized = expectedPlanes.map {
                ChekinanaEdgeFitRTV2ReferenceMath.pillowBilinearResizeFloat(
                    $0,
                    width: reference.side,
                    height: reference.side,
                    outputWidth: 1_024,
                    outputHeight: 1_024
                )
            }
            for y in 0..<1_024 {
                for x in 0..<1_024 {
                    for channel in 0..<3 {
                        let expected = resized[channel][y * 1_024 + x]
                        let observed = actual.pixels[(y * 1_024 + x) * 3 + channel]
                        guard expected.bitPattern == observed.bitPattern else {
                            throw VerificationError.streamingMismatch
                        }
                    }
                }
            }
        }
    }

    private static func verifyPackedMaskEquivalence() throws {
        let logits: [Float] = (0..<(17 * 13)).map { index in
            Float(sin(Double(index) * 0.37))
        }
        for dimensions in [(31, 29), (32, 30), (43, 37)] {
            let expected = ChekinanaEdgeFitRTV2ReferenceMath
                .resizeAlignCornersFalseAndThreshold(
                    logits,
                    width: 17,
                    height: 13,
                    outputWidth: dimensions.0,
                    outputHeight: dimensions.1
                )
            let actual = try ChekinanaEdgeFitRTV2ReferenceMath
                .resizeAlignCornersFalseAndThresholdMask(
                    logits,
                    width: 17,
                    height: 13,
                    outputWidth: dimensions.0,
                    outputHeight: dimensions.1
                )
            guard expected.indices.allSatisfy({ actual.value(at: $0) == expected[$0] }) else {
                throw VerificationError.maskMismatch
            }
        }
    }

    private static func verifyFortyEightMegapixelBudget() throws {
        let side = 11_290
        let estimate = try RTV2WorkingSetBudget.estimate(
            sourceWidth: 8_000,
            sourceHeight: 6_000,
            encodedByteCount: RTV2WorkingSetBudget.maximumEncodedInputBytes,
            cropSide: side
        )
        let removedSquareAllocation = try RTV2WorkingSetBudget.checkedProduct([
            side, side, 3, MemoryLayout<Float>.size,
        ])
        guard removedSquareAllocation == 1_529_569_200,
              estimate.minimumDecodeBufferBytes <= RTV2WorkingSetBudget.maximumDecodePeakBytes,
              estimate.candidatePeakBytes <= RTV2WorkingSetBudget.maximumCandidatePeakBytes,
              estimate.maximumHorizontalCacheBytes < 1_024 * 1_024,
              estimate.packedMaskBytes < removedSquareAllocation / 64 else {
            throw VerificationError.budgetMismatch
        }
        do {
            _ = try RTV2WorkingSetBudget.checkedProduct([Int.max, 2])
            throw VerificationError.overflowAccepted
        } catch RTV2ReferenceMathError.sizeOverflow {
            // Expected.
        }
    }

    private static func verifyDecodeLayoutBudget() throws {
        let encoded = RTV2WorkingSetBudget.maximumEncodedInputBytes
        let limit = RTV2WorkingSetBudget.maximumDecodePeakBytes
        try RTV2WorkingSetBudget.validateDecodePreflight(
            width: 8_000, height: 6_000, encodedByteCount: encoded
        )
        // A synthetic 32-bit layout, not an assumption about ImageIO formats.
        let large = try RTV2WorkingSetBudget.validateDecodeLayout(
            width: 8_000, height: 6_000, encodedByteCount: encoded,
            imageIOBytesPerRow: 32_000, imageIOBitsPerPixel: 32
        )
        guard large.imageIOBackingBytes == 192_000_000,
              large.normalizationPhaseBytes == 425_943_040,
              large.packingPhaseBytes == 377_943_040,
              large.peakBytes == 425_943_040,
              large.normalizationPhaseBytes + large.sourceRGBBytes > limit else {
            throw VerificationError.budgetMismatch
        }
        let rotated = try RTV2WorkingSetBudget.validateDecodeLayout(
            width: 6_000, height: 8_000, encodedByteCount: encoded,
            imageIOBytesPerRow: 24_000, imageIOBitsPerPixel: 32
        )
        guard rotated.peakBytes == large.peakBytes else {
            throw VerificationError.budgetMismatch
        }
        let padded = try RTV2WorkingSetBudget.validateDecodeLayout(
            width: 3, height: 2, encodedByteCount: 10,
            imageIOBytesPerRow: 32, imageIOBitsPerPixel: 64
        )
        guard padded.imageIOBackingBytes == 64,
              padded.normalizationPhaseBytes == 98,
              padded.packingPhaseBytes == 52 else {
            throw VerificationError.budgetMismatch
        }
        for adjustment in [-1, 0] {
            let edge = try RTV2WorkingSetBudget.validateDecodeLayout(
                width: 1, height: 1, encodedByteCount: encoded,
                imageIOBytesPerRow: limit - encoded - 4 + adjustment,
                imageIOBitsPerPixel: 8
            )
            guard edge.peakBytes == limit + adjustment else {
                throw VerificationError.budgetMismatch
            }
        }
        try expectDecodeBudgetRejection {
            _ = try RTV2WorkingSetBudget.validateDecodeLayout(
                width: 1, height: 1, encodedByteCount: encoded,
                imageIOBytesPerRow: limit - encoded - 3,
                imageIOBitsPerPixel: 8
            )
        }
        // The old E+7P preflight passes, but the measured 64-bit backing does
        // not fit even after the ImageIO-to-RGB lifetime split.
        try expectDecodeBudgetRejection {
            _ = try RTV2WorkingSetBudget.validateDecodeLayout(
                width: 8_000, height: 6_000, encodedByteCount: encoded,
                imageIOBytesPerRow: 64_000, imageIOBitsPerPixel: 64
            )
        }
        guard try RTV2WorkingSetBudget.validateRGBPacking(
            width: 8_192, height: 8_192, encodedByteCount: 0,
            rgbaByteCount: 268_435_456
        ) == 201_326_592 else {
            throw VerificationError.budgetMismatch
        }
        try expectDecodeBudgetRejection {
            _ = try RTV2WorkingSetBudget.validateRGBPacking(
                width: 8_192, height: 8_192, encodedByteCount: 1,
                rgbaByteCount: 268_435_456
            )
        }
        do {
            _ = try RTV2WorkingSetBudget.validateDecodeLayout(
                width: 3, height: 2, encodedByteCount: 0,
                imageIOBytesPerRow: 23, imageIOBitsPerPixel: 64
            )
            throw VerificationError.budgetMismatch
        } catch RTV2ReferenceMathError.invalidDimensions {
            // A stride shorter than the declared layout cannot be trusted.
        }
        do {
            _ = try RTV2WorkingSetBudget.validateDecodeLayout(
                width: 1, height: 2, encodedByteCount: 0,
                imageIOBytesPerRow: Int.max, imageIOBitsPerPixel: 8
            )
            throw VerificationError.overflowAccepted
        } catch RTV2ReferenceMathError.sizeOverflow {
            // The backing product must reject overflow before allocation.
        }
    }

    private static func expectDecodeBudgetRejection(
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw VerificationError.budgetMismatch
        } catch RTV2ReferenceMathError.resourceBudgetExceeded {
            // Expected; no image or buffer has been allocated by this check.
        }
    }

    private static func permutations<T>(_ values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index in
            var remaining = values
            let value = remaining.remove(at: index)
            return permutations(remaining).map { [value] + $0 }
        }
    }

    private enum VerificationError: Error {
        case canonicalizationMismatch
        case invalidGeometryAccepted
        case streamingMismatch
        case maskMismatch
        case budgetMismatch
        case overflowAccepted
    }
}

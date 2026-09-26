import Foundation

@main
struct EdgeFitReferenceMathVerifier {
    static func main() throws {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
            throw VerificationError.missingFixture
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: fixtureURL)
        )

        let openCVSummary: OpenCVSummary?
        if CommandLine.arguments.count == 3 {
            let openCVFixture = try JSONDecoder().decode(
                OpenCVFixture.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            )
            openCVSummary = try verifyOpenCV(openCVFixture)
        } else {
            openCVSummary = nil
        }

        for sample in fixture.numpyChoice {
            let actual = ChekinanaEdgeFitRTV2ReferenceMath.numpyChoiceStreamSeed42(
                upperBound: sample.upperBound,
                count: sample.count,
                draws: sample.expected.count
            )
            guard actual == sample.expected else {
                throw VerificationError.choiceMismatch(
                    upperBound: sample.upperBound,
                    actual: actual,
                    expected: sample.expected
                )
            }
        }

        for sample in fixture.pillowBilinearRGB {
            guard let input = Data(base64Encoded: sample.inputBase64),
                  let expected = Data(base64Encoded: sample.expectedBase64) else {
                throw VerificationError.invalidFixture
            }
            let actual = ChekinanaEdgeFitRTV2ReferenceMath.pillowBilinearResizeRGB(
                Array(input),
                width: sample.width,
                height: sample.height,
                outputWidth: sample.outputWidth,
                outputHeight: sample.outputHeight
            )
            guard actual == Array(expected) else {
                let differences = zip(actual, expected).filter(!=).count
                throw VerificationError.resizeMismatch(
                    name: sample.name,
                    differences: differences,
                    total: expected.count
                )
            }
        }

        var maximumQuadrilateralError = 0.0
        for sample in fixture.ransacMasks {
            guard let maskData = Data(base64Encoded: sample.maskBase64) else {
                throw VerificationError.invalidFixture
            }
            let mask = RTV2BinaryMask(
                width: sample.width,
                height: sample.height,
                values: maskData.map { $0 != 0 }
            )
            let contour = try RTV2QuadrilateralFitter.contourPointsForTesting(mask: mask)
            let contourPairs = contour.map { [Int($0.x), Int($0.y)] }
            guard contourPairs == sample.contourPoints else {
                throw VerificationError.contourMismatch(
                    name: sample.name,
                    actualCount: contourPairs.count,
                    expectedCount: sample.contourPoints.count
                )
            }
            let initial = try RTV2QuadrilateralFitter.initialQuadrilateralForTesting(
                mask: mask
            )
            maximumQuadrilateralError = max(
                maximumQuadrilateralError,
                try compare(
                actual: initial,
                expected: sample.initialQuadrilateral,
                tolerance: sample.initialTolerance,
                name: sample.name + ".initial"
                )
            )
            let fitted = try RTV2QuadrilateralFitter.fit(mask: mask)
            maximumQuadrilateralError = max(
                maximumQuadrilateralError,
                try compare(
                actual: fitted,
                expected: sample.finalQuadrilateral,
                tolerance: sample.finalTolerance,
                name: sample.name + ".final"
                )
            )
        }

        var message = "PASS pillow=\(fixture.pillowBilinearRGB.count) "
                + "choice=\(fixture.numpyChoice.count) "
                + "ransac=\(fixture.ransacMasks.count) "
                + "maxQuadError=\(maximumQuadrilateralError)"
        if let openCVSummary {
            message += " opencvAreaMaxByteError=\(openCVSummary.areaMaximumError)"
                + " opencvLinearMaxByteError=\(openCVSummary.linearMaximumError)"
                + " opencvWarpMaxByteError=\(openCVSummary.warpMaximumError)"
                + " opencvCoarseMaskMismatch=\(openCVSummary.coarseMaskMismatches)"
                + " opencvSoftSupportMaxError=\(openCVSummary.softSupportMaximumError)"
                + " opencvSoftSupportAreaError=\(openCVSummary.softSupportAreaError)"
        }
        print(message)
    }

    private static func verifyOpenCV(_ fixture: OpenCVFixture) throws -> OpenCVSummary {
        var summary = OpenCVSummary()
        for sample in fixture.areaResizeRGB {
            let input = try bytes(sample.inputBase64)
            let expected = try bytes(sample.expectedBase64)
            let actual = ChekinanaEdgeFitRTV2ReferenceMath.openCVAreaResizeRGB(
                input,
                width: sample.width,
                height: sample.height,
                outputWidth: sample.outputWidth,
                outputHeight: sample.outputHeight
            )
            let error = try byteError(actual: actual, expected: expected, name: sample.name)
            summary.areaMaximumError = max(summary.areaMaximumError, error)
            guard error <= 1 else {
                throw VerificationError.openCVMismatch(name: "area." + sample.name, error: error)
            }
        }
        for sample in fixture.linearResizeRGB {
            let input = try bytes(sample.inputBase64)
            let expected = try bytes(sample.expectedBase64)
            let actual = ChekinanaEdgeFitRTV2ReferenceMath.openCVLinearResizeRGB(
                input,
                width: sample.width,
                height: sample.height,
                outputWidth: sample.outputWidth,
                outputHeight: sample.outputHeight
            )
            let error = try byteError(actual: actual, expected: expected, name: sample.name)
            summary.linearMaximumError = max(summary.linearMaximumError, error)
            guard error <= 1 else {
                throw VerificationError.openCVMismatch(name: "linear." + sample.name, error: error)
            }
        }
        for sample in fixture.square20WarpRGB {
            let input = try bytes(sample.inputBase64)
            let expected = try bytes(sample.expectedBase64)
            let crop = ChekinanaEdgeFitRTV2ReferenceMath.openCVSquare20WarpRGB(
                input,
                width: sample.width,
                height: sample.height,
                box: sample.box,
                borderRGB: sample.borderRGB
            )
            guard crop.side == sample.cropSide else {
                throw VerificationError.openCVMismatch(
                    name: "warp-side." + sample.name,
                    error: abs(crop.side - sample.cropSide)
                )
            }
            let error = try byteError(
                actual: crop.bytes,
                expected: expected,
                name: sample.name
            )
            summary.warpMaximumError = max(summary.warpMaximumError, error)
            guard error <= 1 else {
                throw VerificationError.openCVMismatch(name: "warp." + sample.name, error: error)
            }
        }
        for sample in fixture.coarseMasks {
            let logits = try floats(sample.logitsFloat32Base64)
            let expected = try bytes(sample.expectedMaskBase64).map { $0 != 0 }
            let probability = logits.map(sigmoid)
            let actual = ChekinanaEdgeFitRTV2ReferenceMath.openCVPasteCoarseMask(
                probability: probability,
                box: sample.box
            )
            guard actual.count == expected.count else {
                throw VerificationError.invalidFixture
            }
            let mismatches = zip(actual, expected).filter(!=).count
            summary.coarseMaskMismatches += mismatches
            guard mismatches == 0 else {
                throw VerificationError.openCVMismatch(
                    name: "coarse." + sample.name,
                    error: mismatches
                )
            }
        }
        for sample in fixture.softMaskSupports {
            let probability = try floats(sample.probabilityFloat32Base64)
            let expected = try floats(sample.expectedSupportFloat32Base64)
            let actual = ChekinanaEdgeFitRTV2ReferenceMath.openCVSoftMaskSupport(
                probability: probability,
                box: sample.box,
                canvas: sample.canvas
            )
            guard [actual.x1, actual.y1, actual.x2, actual.y2]
                    == sample.expectedBounds,
                  actual.values.count == expected.count else {
                throw VerificationError.invalidFixture
            }
            let valueError = zip(actual.values, expected).reduce(Float(0)) {
                max($0, abs($1.0 - $1.1))
            }
            let areaError = abs(actual.area - sample.expectedArea)
            summary.softSupportMaximumError = max(
                summary.softSupportMaximumError,
                valueError
            )
            summary.softSupportAreaError = max(summary.softSupportAreaError, areaError)
            guard valueError <= 0.000_001 else {
                throw VerificationError.openCVFloatMismatch(
                    name: "soft-support." + sample.name,
                    error: valueError,
                    tolerance: 0.000_001
                )
            }
            guard areaError <= 0.001 else {
                throw VerificationError.openCVFloatMismatch(
                    name: "soft-support-area." + sample.name,
                    error: areaError,
                    tolerance: 0.001
                )
            }
        }
        return summary
    }

    private static func bytes(_ encoded: String) throws -> [UInt8] {
        guard let data = Data(base64Encoded: encoded) else {
            throw VerificationError.invalidFixture
        }
        return Array(data)
    }

    private static func floats(_ encoded: String) throws -> [Float] {
        let data = try bytes(encoded)
        guard data.count.isMultiple(of: 4) else {
            throw VerificationError.invalidFixture
        }
        return stride(from: 0, to: data.count, by: 4).map { index in
            let bits = UInt32(data[index])
                | UInt32(data[index + 1]) << 8
                | UInt32(data[index + 2]) << 16
                | UInt32(data[index + 3]) << 24
            return Float(bitPattern: bits)
        }
    }

    private static func sigmoid(_ value: Float) -> Float {
        if value >= 0 {
            let z = exp(-value)
            return 1 / (1 + z)
        }
        let z = exp(value)
        return z / (1 + z)
    }

    private static func byteError(
        actual: [UInt8],
        expected: [UInt8],
        name: String
    ) throws -> Int {
        guard actual.count == expected.count else {
            throw VerificationError.openCVMismatch(
                name: name + ".count",
                error: abs(actual.count - expected.count)
            )
        }
        return zip(actual, expected).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
    }

    private static func compare(
        actual: [RTV2Point],
        expected: [[Double]],
        tolerance: Double,
        name: String
    ) throws -> Double {
        guard actual.count == expected.count else {
            throw VerificationError.invalidFixture
        }
        let maximumError = zip(actual, expected).reduce(0.0) { maximum, pair in
            max(
                maximum,
                abs(pair.0.x - pair.1[0]),
                abs(pair.0.y - pair.1[1])
            )
        }
        guard maximumError <= tolerance else {
            throw VerificationError.quadrilateralMismatch(
                name: name,
                maximumError: maximumError,
                tolerance: tolerance,
                actual: actual
            )
        }
        return maximumError
    }

    private struct Fixture: Decodable {
        let numpyChoice: [ChoiceSample]
        let pillowBilinearRGB: [ResizeSample]
        let ransacMasks: [RANSACSample]
    }

    private struct ChoiceSample: Decodable {
        let upperBound: Int
        let count: Int
        let expected: [[Int]]
    }

    private struct ResizeSample: Decodable {
        let name: String
        let width: Int
        let height: Int
        let outputWidth: Int
        let outputHeight: Int
        let inputBase64: String
        let expectedBase64: String
    }

    private struct RANSACSample: Decodable {
        let name: String
        let width: Int
        let height: Int
        let maskBase64: String
        let contourPoints: [[Int]]
        let initialQuadrilateral: [[Double]]
        let finalQuadrilateral: [[Double]]
        let initialTolerance: Double
        let finalTolerance: Double
    }

    private struct OpenCVFixture: Decodable {
        let areaResizeRGB: [OpenCVResizeSample]
        let linearResizeRGB: [OpenCVResizeSample]
        let square20WarpRGB: [OpenCVWarpSample]
        let coarseMasks: [OpenCVCoarseMaskSample]
        let softMaskSupports: [OpenCVSoftMaskSupportSample]
    }

    private struct OpenCVResizeSample: Decodable {
        let name: String
        let width: Int
        let height: Int
        let outputWidth: Int
        let outputHeight: Int
        let inputBase64: String
        let expectedBase64: String
    }

    private struct OpenCVWarpSample: Decodable {
        let name: String
        let width: Int
        let height: Int
        let box: [Float]
        let cropSide: Int
        let borderRGB: [Double]
        let inputBase64: String
        let expectedBase64: String
    }

    private struct OpenCVCoarseMaskSample: Decodable {
        let name: String
        let box: [Float]
        let logitsFloat32Base64: String
        let expectedMaskBase64: String
    }

    private struct OpenCVSoftMaskSupportSample: Decodable {
        let name: String
        let box: [Float]
        let canvas: Int
        let expectedBounds: [Int]
        let probabilityFloat32Base64: String
        let expectedSupportFloat32Base64: String
        let expectedArea: Float
    }

    private struct OpenCVSummary {
        var areaMaximumError = 0
        var linearMaximumError = 0
        var warpMaximumError = 0
        var coarseMaskMismatches = 0
        var softSupportMaximumError: Float = 0
        var softSupportAreaError: Float = 0
    }

    private enum VerificationError: Error {
        case missingFixture
        case invalidFixture
        case choiceMismatch(upperBound: Int, actual: [[Int]], expected: [[Int]])
        case resizeMismatch(name: String, differences: Int, total: Int)
        case contourMismatch(name: String, actualCount: Int, expectedCount: Int)
        case quadrilateralMismatch(
            name: String,
            maximumError: Double,
            tolerance: Double,
            actual: [RTV2Point]
        )
        case openCVMismatch(name: String, error: Int)
        case openCVFloatMismatch(name: String, error: Float, tolerance: Float)
    }
}

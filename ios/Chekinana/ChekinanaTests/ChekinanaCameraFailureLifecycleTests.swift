import Foundation
import XCTest
@testable import Chekinana

final class ChekinanaCameraFailureLifecycleTests: XCTestCase {
    func testProcessingFailureKeepsSessionCapabilityAndRequiresRetry() throws {
        var lifecycle = ChekinanaCameraCaptureLifecycle()
        lifecycle.beginNewSession()
        lifecycle.setCapability(.running)
        let captureID = UUID()
        XCTAssertTrue(lifecycle.register(systemID: 1, captureID: captureID, filenameExtension: "heic"))
        XCTAssertNotNil(lifecycle.beginProcessing(systemID: 1))
        XCTAssertTrue(lifecycle.completeProcessingWithFailure(systemID: 1, errorDescription: "processing"))
        XCTAssertEqual(lifecycle.capability, .running)
        XCTAssertEqual(lifecycle.captureFailure?.captureID, captureID)
        XCTAssertEqual(lifecycle.captureFailure?.generation, lifecycle.generation)
        XCTAssertEqual(lifecycle.state, .failed("processing"))
        XCTAssertFalse(lifecycle.isCaptureLocked)
        XCTAssertFalse(lifecycle.canBeginCapture)
        lifecycle.clearCaptureFailure()
        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertTrue(lifecycle.canBeginCapture)
    }

    func testRetriedRequestIgnoresEarlierFinalFailureThroughDelivery() throws {
        var lifecycle = ChekinanaCameraCaptureLifecycle()
        lifecycle.beginNewSession()
        lifecycle.setCapability(.running)
        let captureA = UUID()
        XCTAssertTrue(lifecycle.register(systemID: 1, captureID: captureA, filenameExtension: "heic"))
        XCTAssertNotNil(lifecycle.beginProcessing(systemID: 1))
        XCTAssertTrue(lifecycle.completeProcessingWithFailure(systemID: 1, errorDescription: "A processing"))
        lifecycle.clearCaptureFailure()
        let captureB = UUID()
        XCTAssertTrue(lifecycle.register(systemID: 2, captureID: captureB, filenameExtension: "jpg"))
        XCTAssertNotNil(lifecycle.beginProcessing(systemID: 2))
        XCTAssertEqual(lifecycle.completeProcessingWithDelivery(systemID: 2), .awaitingFinal)
        guard case .delivery(let delivery) = lifecycle.finishCapture(systemID: 2, hasError: false) else {
            return XCTFail("B must wait for and then own its delivery")
        }
        XCTAssertEqual(lifecycle.finishCapture(systemID: 1, hasError: true, errorDescription: "A final"),
                       .failed(discardCaptureID: captureA))
        XCTAssertEqual(lifecycle.delivery, delivery)
        XCTAssertNil(lifecycle.captureFailure)
        XCTAssertEqual(lifecycle.capability, .running)
        XCTAssertEqual(lifecycle.state, .capturing)
        XCTAssertTrue(lifecycle.consume(captureID: captureB, generation: delivery.generation))
        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(lifecycle.finishCapture(systemID: 1, hasError: true, errorDescription: "duplicate"), .ignored)
    }

    func testCaptureFailureCannotOverwriteInterruptionOrHardwareFailure() throws {
        var lifecycle = ChekinanaCameraCaptureLifecycle()
        lifecycle.beginNewSession()
        lifecycle.setCapability(.running)
        XCTAssertTrue(lifecycle.register(systemID: 1, captureID: UUID(), filenameExtension: "heic"))
        lifecycle.setCapability(.interrupted("interrupted"))
        XCTAssertNotNil(lifecycle.beginProcessing(systemID: 1))
        XCTAssertTrue(lifecycle.completeProcessingWithFailure(systemID: 1, errorDescription: "processing"))
        _ = lifecycle.finishCapture(systemID: 1, hasError: true, errorDescription: "final")
        XCTAssertEqual(lifecycle.capability, .interrupted("interrupted"))
        XCTAssertEqual(lifecycle.state, .interrupted("interrupted"))
        XCTAssertFalse(lifecycle.isCaptureLocked)
        lifecycle.clearCaptureFailure()
        lifecycle.setCapability(.running)
        XCTAssertEqual(lifecycle.state, .ready)
        lifecycle.setCapability(.failed("hardware"))
        lifecycle.clearCaptureFailure()
        XCTAssertEqual(lifecycle.state, .failed("hardware"))
        XCTAssertFalse(lifecycle.canBeginCapture)
    }

    func testNewSessionClearsOnlyOldRequestFailureAndKeepsNewRequestLocked() throws {
        var lifecycle = ChekinanaCameraCaptureLifecycle()
        lifecycle.beginNewSession()
        lifecycle.setCapability(.running)
        XCTAssertTrue(lifecycle.register(systemID: 1, captureID: UUID(), filenameExtension: "heic"))
        XCTAssertNotNil(lifecycle.beginProcessing(systemID: 1))
        XCTAssertTrue(lifecycle.completeProcessingWithFailure(systemID: 1, errorDescription: "old"))
        lifecycle.beginNewSession()
        lifecycle.setCapability(.running)
        XCTAssertNil(lifecycle.captureFailure)
        XCTAssertTrue(lifecycle.register(systemID: 2, captureID: UUID(), filenameExtension: "heic"))
        XCTAssertEqual(lifecycle.finishCapture(systemID: 1, hasError: true, errorDescription: "late"), .ignored)
        XCTAssertEqual(lifecycle.activeSystemID, 2)
        XCTAssertEqual(lifecycle.state, .capturing)
        XCTAssertFalse(lifecycle.canBeginCapture)
    }
}

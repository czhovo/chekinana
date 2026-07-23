import Foundation
import SwiftData
import UIKit
import XCTest
@testable import Chekinana

@MainActor
final class ChekinanaCommandExecutorTests: XCTestCase {
    private struct Fixture {
        let context: ModelContext
        let ledger: ChekinanaConfirmationLedger
        let executor: ChekinanaCommandExecutor
    }

#if DEBUG
    func testMediaUITestFixtureProvidesThreeSmallDistinctImages() {
        let images = ChekinanaMediaUITestFixture.pendingChekiImages()

        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(Set(images.map(\.data)).count, 3)
        XCTAssertTrue(images.allSatisfy { $0.filenameExtension == "png" })
        XCTAssertTrue(images.allSatisfy { !$0.data.isEmpty && $0.data.count < 4_096 })
        XCTAssertTrue(images.allSatisfy { UIImage(data: $0.data) != nil })
    }
#endif

    func testScannerDateAnnotationDefaultsOffAndOverlayGeometry() throws {
        XCTAssertFalse(ChekinanaScannerDateAnnotationDefaults.isEnabled)

        let edgeBox = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 0,
            y1: 0,
            x2: 1_000,
            y2: 1_000
        ))
        XCTAssertEqual(
            ChekinanaChekiDateOverlayGeometry.annotationRect(
                boundingBox: edgeBox,
                imageSize: CGSize(width: 100, height: 100),
                containerSize: CGSize(width: 100, height: 100)
            ),
            CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertEqual(
            ChekinanaChekiDateOverlayGeometry.annotationRect(
                boundingBox: edgeBox,
                imageSize: CGSize(width: 200, height: 100),
                containerSize: CGSize(width: 100, height: 100)
            ),
            CGRect(x: 0, y: 25, width: 100, height: 50)
        )
        XCTAssertEqual(
            ChekinanaChekiDateOverlayGeometry.annotationRect(
                boundingBox: edgeBox,
                imageSize: CGSize(width: 100, height: 200),
                containerSize: CGSize(width: 100, height: 100)
            ),
            CGRect(x: 25, y: 0, width: 50, height: 100)
        )
        let insetBox = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 100,
            y1: 200,
            x2: 900,
            y2: 800
        ))
        XCTAssertEqual(
            ChekinanaChekiDateOverlayGeometry.annotationRect(
                boundingBox: insetBox,
                imageSize: CGSize(width: 200, height: 100),
                containerSize: CGSize(width: 100, height: 100)
            ),
            CGRect(x: 10, y: 35, width: 80, height: 30)
        )
        XCTAssertNil(ChekinanaChekiDateOverlayGeometry.annotationRect(
            boundingBox: edgeBox,
            imageSize: .zero,
            containerSize: CGSize(width: 100, height: 100)
        ))
    }

    func testScannerDateAnnotationHeaderParserStrictStates() throws {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://api.chekinana.top/api/result/task/result")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        }

        let full = ChekinanaScannerDateAnnotationHeaderParser.parse(
            response: response([
                "x-cheki-date-status": "detected",
                "X-Cheki-Date-Text": "2026.07.04",
                "X-Cheki-Date-Precision": "full_date",
                "X-Cheki-Date-Bbox": "100,200,900,800",
            ]),
            isEnabled: true
        )
        guard case .detected(let fullAnnotation) = full else {
            return XCTFail("expected full-date annotation")
        }
        XCTAssertEqual(fullAnnotation.text, "2026.07.04")
        XCTAssertEqual(fullAnnotation.precision, .fullDate)
        XCTAssertEqual(fullAnnotation.boundingBox.x1, 100)

        let monthDay = ChekinanaScannerDateAnnotationHeaderParser.parse(
            response: response([
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "02.29",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "0,0,1000,1000",
            ]),
            isEnabled: true
        )
        guard case .detected(let monthDayAnnotation) = monthDay else {
            return XCTFail("expected month-day annotation")
        }
        XCTAssertEqual(monthDayAnnotation.text, "02.29")
        XCTAssertEqual(monthDayAnnotation.precision, .monthDay)

        XCTAssertEqual(
            ChekinanaScannerDateAnnotationHeaderParser.parse(
                response: response(["X-Cheki-Date-Status": "not_detected"]),
                isEnabled: true
            ),
            .notDetected
        )
        XCTAssertEqual(
            ChekinanaScannerDateAnnotationHeaderParser.parse(
                response: response([
                    "X-Cheki-Date-Status": "unavailable",
                    "X-Cheki-Date-Error": "upstream_unavailable",
                ]),
                isEnabled: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            ChekinanaScannerDateAnnotationHeaderParser.parse(
                response: response([
                    "X-Cheki-Date-Status": "detected",
                    "X-Cheki-Date-Text": "2026.07.04",
                    "X-Cheki-Date-Precision": "full_date",
                    "X-Cheki-Date-Bbox": "100,200,900,800",
                ]),
                isEnabled: false
            ),
            .notRequested
        )

        let malformedHeaders: [[String: String]] = [
            ["X-Cheki-Date-Status": "unknown"],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "2026.02.29",
                "X-Cheki-Date-Precision": "full_date",
                "X-Cheki-Date-Bbox": "100,200,900,800",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "full_date",
                "X-Cheki-Date-Bbox": "100,200,900,800",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "100.0,200,900,800",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "100,200,900",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "100,200,1001,800",
            ],
            [
                "X-Cheki-Date-Status": "detected",
                "X-Cheki-Date-Text": "07.04",
                "X-Cheki-Date-Precision": "month_day",
                "X-Cheki-Date-Bbox": "900,200,100,800",
            ],
            [
                "X-Cheki-Date-Status": "not_detected",
                "X-Cheki-Date-Bbox": "100,200,900,800",
            ],
        ]
        for headers in malformedHeaders {
            XCTAssertEqual(
                ChekinanaScannerDateAnnotationHeaderParser.parse(
                    response: response(headers),
                    isEnabled: true
                ),
                .unavailable,
                "\(headers)"
            )
        }
    }

    func testScannerResultDownloadToggleURLTokenFailOpenAndNoRetry() async throws {
        var requestCount = 0
        let imageData = scannerPNGData(color: .orange)
        ChekinanaScannerDateMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.chekinana.top/api/result/task-a/result-a"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Cheki-Token"),
                "scanner-test-token"
            )
            return (
                imageData,
                [
                    "X-Cheki-Date-Status": "detected",
                    "X-Cheki-Date-Text": "2026.07.04",
                    "X-Cheki-Date-Precision": "full_date",
                    "X-Cheki-Date-Bbox": "100,200,900,800",
                ]
            )
        }
        defer { ChekinanaScannerDateMockURLProtocol.handler = nil }
        let client = ChekinanaScannerClient(session: scannerDateMockSession())
        let off = try await client.downloadResult(
            taskID: "task-a",
            resultID: "result-a",
            options: scannerOptions(dateAnnotationEnabled: false)
        )
        XCTAssertEqual(off.data, imageData)
        XCTAssertEqual(off.dateAnnotationState, .notRequested)
        XCTAssertEqual(requestCount, 1)

        requestCount = 0
        ChekinanaScannerDateMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.chekinana.top/api/result/task-b/result-b?date_annotation=1"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Cheki-Token"),
                "scanner-test-token"
            )
            return (
                imageData,
                [
                    "X-Cheki-Date-Status": "detected",
                    "X-Cheki-Date-Text": "07.04",
                    "X-Cheki-Date-Precision": "month_day",
                    // Malformed bbox must fail open without a second request.
                    "X-Cheki-Date-Bbox": "100.0,200,900,800",
                ]
            )
        }
        let failOpen = try await client.downloadResult(
            taskID: "task-b",
            resultID: "result-b",
            options: scannerOptions(dateAnnotationEnabled: true)
        )
        XCTAssertEqual(failOpen.data, imageData)
        XCTAssertEqual(failOpen.dateAnnotationState, .unavailable)
        XCTAssertEqual(requestCount, 1)
    }

    func testScannerClientKeepsAnnotationWithMatchingResultID() async throws {
        let firstImage = scannerPNGData(color: .red)
        let secondImage = scannerPNGData(color: .blue)
        var resultRequests: [String] = []
        ChekinanaScannerDateMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/process":
                return (Data(#"{"task_id":"task-one"}"#.utf8), [:])
            case "/api/status/task-one":
                return (
                    Data(#"{"status":"completed","results":[{"id":"first","type":"polaroid"},{"id":"second","type":"polaroid"}]}"#.utf8),
                    [:]
                )
            case "/api/result/task-one/first":
                resultRequests.append("first")
                return (
                    firstImage,
                    [
                        "X-Cheki-Date-Status": "detected",
                        "X-Cheki-Date-Text": "2026.07.04",
                        "X-Cheki-Date-Precision": "full_date",
                        "X-Cheki-Date-Bbox": "100,200,900,800",
                    ]
                )
            case "/api/result/task-one/second":
                resultRequests.append("second")
                return (
                    secondImage,
                    ["X-Cheki-Date-Status": "not_detected"]
                )
            default:
                XCTFail("unexpected scanner URL: \(request.url?.absoluteString ?? "-")")
                return (Data(), [:])
            }
        }
        defer { ChekinanaScannerDateMockURLProtocol.handler = nil }

        let result = try await ChekinanaScannerClient(
            session: scannerDateMockSession()
        ).process(
            testImage(7),
            options: scannerOptions(dateAnnotationEnabled: true)
        )

        XCTAssertEqual(resultRequests, ["first", "second"])
        XCTAssertEqual(result.images.map(\.data), [firstImage, secondImage])
        guard case .detected(let annotation) = result.images[0].dateAnnotationState else {
            return XCTFail("first result lost its annotation")
        }
        XCTAssertEqual(annotation.text, "2026.07.04")
        XCTAssertEqual(result.images[1].dateAnnotationState, .notDetected)
    }

    func testScannerClientUsesInjectedLANBaseURLForEveryRouteAndKeepsDateQuery() async throws {
        let imageData = scannerPNGData(color: .cyan)
        var requestedURLs: [String] = []
        ChekinanaScannerDateMockURLProtocol.handler = { request in
            requestedURLs.append(try XCTUnwrap(request.url?.absoluteString))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Cheki-Token"),
                "scanner-test-token"
            )
            switch request.url?.path {
            case "/api/process":
                XCTAssertEqual(request.httpMethod, "POST")
                return (Data(#"{"task_id":"lan-task"}"#.utf8), [:])
            case "/api/status/lan-task":
                return (
                    Data(#"{"status":"completed","results":[{"id":"lan-result","type":"polaroid"}]}"#.utf8),
                    [:]
                )
            case "/api/result/lan-task/lan-result":
                XCTAssertEqual(request.url?.query, "date_annotation=1")
                return (imageData, ["X-Cheki-Date-Status": "not_detected"])
            default:
                XCTFail("unexpected scanner URL")
                return (Data(), [:])
            }
        }
        defer { ChekinanaScannerDateMockURLProtocol.handler = nil }

        let client = ChekinanaScannerClient(
            baseURL: try XCTUnwrap(URL(string: "http://192.168.50.20:8787")),
            session: scannerDateMockSession()
        )
        let result = try await client.process(
            testImage(4),
            options: scannerOptions(dateAnnotationEnabled: true)
        )

        XCTAssertEqual(requestedURLs, [
            "http://192.168.50.20:8787/api/process",
            "http://192.168.50.20:8787/api/status/lan-task",
            "http://192.168.50.20:8787/api/result/lan-task/lan-result?date_annotation=1",
        ])
        XCTAssertEqual(result.images.map(\.data), [imageData])
        XCTAssertEqual(result.images.first?.dateAnnotationState, .notDetected)
    }

    func testScannerClientInvalidConfiguredBaseURLFailsClosedBeforeRequest() async {
        var requestWasMade = false
        ChekinanaScannerDateMockURLProtocol.handler = { _ in
            requestWasMade = true
            return (Data(), [:])
        }
        defer { ChekinanaScannerDateMockURLProtocol.handler = nil }

        let client = ChekinanaScannerClient(
            infoDictionary: [
                ChekinanaScannerConfiguration.baseURLInfoDictionaryKey:
                    "http://example.com:8787",
            ],
            allowsInsecureLocalHTTP: true,
            session: scannerDateMockSession()
        )

        do {
            _ = try await client.downloadResult(
                taskID: "task",
                resultID: "result",
                options: scannerOptions(dateAnnotationEnabled: true)
            )
            XCTFail("invalid configured base URL should fail closed")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "scanner base URL configuration is invalid"
            )
        }
        XCTAssertFalse(requestWasMade)
    }

    func testChekiPreviewLoaderPriorityFallbackAndUnavailableOutcomes() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let rendered = ChekinanaRenderedImage(cgImage: try XCTUnwrap(image.cgImage))
        let embeddedData = try XCTUnwrap(image.pngData())

        func source(imageRef: String?, embeddedData: Data?) -> ChekinanaChekiPreviewSource {
            ChekinanaChekiPreviewSource(cheki: ChekinanaChekiCard(
                id: UUID(),
                imageRef: imageRef,
                createdAt: Date(),
                confirmationCode: nil,
                thumbnailImageData: embeddedData
            ))
        }

        var embeddedWasCalled = false
        let preferred = await ChekinanaChekiPreviewLoader(
            imageRefLoader: { _, maxDimension in
                XCTAssertEqual(maxDimension, 2_048)
                return rendered
            },
            embeddedLoader: { _, _ in
                embeddedWasCalled = true
                return rendered
            }
        ).load(source: source(imageRef: "saved.jpg", embeddedData: embeddedData))
        XCTAssertEqual(preferred.loadedSource, .imageRef)
        XCTAssertNotNil(preferred.image)
        XCTAssertFalse(embeddedWasCalled)

        var refWasCalled = false
        embeddedWasCalled = false
        let fallback = await ChekinanaChekiPreviewLoader(
            imageRefLoader: { _, _ in
                refWasCalled = true
                return nil
            },
            embeddedLoader: { data, maxDimension in
                embeddedWasCalled = true
                XCTAssertEqual(data, embeddedData)
                XCTAssertEqual(maxDimension, 2_048)
                return rendered
            }
        ).load(source: source(imageRef: "missing.jpg", embeddedData: embeddedData))
        XCTAssertTrue(refWasCalled)
        XCTAssertTrue(embeddedWasCalled)
        XCTAssertEqual(fallback.loadedSource, .embeddedThumbnail)
        XCTAssertNotNil(fallback.image)

        refWasCalled = false
        let embeddedOnly = await ChekinanaChekiPreviewLoader(
            imageRefLoader: { _, _ in
                refWasCalled = true
                return rendered
            },
            embeddedLoader: { _, _ in rendered }
        ).load(source: source(imageRef: nil, embeddedData: embeddedData))
        XCTAssertFalse(refWasCalled)
        XCTAssertEqual(embeddedOnly.loadedSource, .embeddedThumbnail)
        XCTAssertNotNil(embeddedOnly.image)

        refWasCalled = false
        embeddedWasCalled = false
        let unavailable = await ChekinanaChekiPreviewLoader(
            imageRefLoader: { _, _ in
                refWasCalled = true
                return rendered
            },
            embeddedLoader: { _, _ in
                embeddedWasCalled = true
                return rendered
            }
        ).load(source: source(imageRef: nil, embeddedData: nil))
        XCTAssertFalse(refWasCalled)
        XCTAssertFalse(embeddedWasCalled)
        XCTAssertNil(unavailable.loadedSource)
        XCTAssertNil(unavailable.image)
    }

    func testPendingAddConfirmOrderAssignsSequentialIndexes() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let idol = Idol(name: "A")
        let event = Event(name: "E")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        try fixture.context.save()

        let cards = try prepareAlbumChekis(
            count: 2,
            idol: idol,
            event: event,
            fixture: fixture
        )
        let secondCode = try XCTUnwrap(cards[1].confirmationCode)
        let firstCode = try XCTUnwrap(cards[0].confirmationCode)
        try requireSuccess(await fixture.executor.execute("confirm \(secondCode)"))
        try requireSuccess(await fixture.executor.execute("confirm \(firstCode)"))

        let saved = try fixture.context.fetch(FetchDescriptor<Cheki>())
        XCTAssertEqual(saved.first(where: { $0.id == cards[1].id })?.idx, 1)
        XCTAssertEqual(saved.first(where: { $0.id == cards[0].id })?.idx, 2)
    }

    func testEditChekiRegroupsThenMetadataEditPreservesIndex() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "A")
        let oldEvent = Event(name: "Old")
        let newEvent = Event(name: "New")
        fixture.context.insert(idol)
        fixture.context.insert(oldEvent)
        fixture.context.insert(newEvent)

        let occupied = Cheki(idx: 4)
        fixture.context.insert(occupied)
        occupied.idols = [idol]
        occupied.event = newEvent
        let edited = Cheki(idx: 7, note: "old")
        fixture.context.insert(edited)
        edited.idols = [idol]
        edited.event = oldEvent
        try fixture.context.save()

        _ = await fixture.executor.execute(
            "editcheki \(shortID(edited.id)) event=\(shortID(newEvent.id))"
        )
        try requireSuccess(await fixture.executor.execute("confirm"))
        XCTAssertEqual(edited.event?.id, newEvent.id)
        XCTAssertEqual(edited.idx, 5)

        _ = await fixture.executor.execute("editcheki \(shortID(edited.id)) note=changed")
        try requireSuccess(await fixture.executor.execute("confirm"))
        XCTAssertEqual(edited.note, "changed")
        XCTAssertEqual(edited.idx, 5)
    }

    func testStaleEventAndChekiEditsAreRejected() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "A")
        let event = Event(name: "Original")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        let cheki = Cheki(idx: 1, note: "original")
        fixture.context.insert(cheki)
        cheki.idols = [idol]
        cheki.event = event
        try fixture.context.save()

        _ = await fixture.executor.execute("editevent \(shortID(event.id)) name=stale")
        event.name = "fresh"
        event.updatedAt = event.updatedAt.addingTimeInterval(1)
        try fixture.context.save()
        let eventResponse = await fixture.executor.execute("confirm")
        XCTAssertTrue(text(from: eventResponse).contains("Run cancel"))
        XCTAssertTrue(text(from: eventResponse).contains("editevent again"))
        XCTAssertEqual(event.name, "fresh")

        _ = await fixture.executor.execute("editcheki \(shortID(cheki.id)) note=stale")
        cheki.note = "fresh"
        cheki.updatedAt = cheki.updatedAt.addingTimeInterval(1)
        try fixture.context.save()
        let chekiResponse = await fixture.executor.execute("confirm")
        XCTAssertTrue(text(from: chekiResponse).contains("Run cancel"))
        XCTAssertTrue(text(from: chekiResponse).contains("editcheki again"))
        XCTAssertEqual(cheki.note, "fresh")
        XCTAssertEqual(cheki.idx, 1)
    }

    func testEventDeleteRechecksReferencesAtConfirmation() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "A")
        let event = Event(name: "E")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        try fixture.context.save()

        _ = await fixture.executor.execute("deleteevent \(shortID(event.id))")
        let cheki = Cheki(idx: 1)
        fixture.context.insert(cheki)
        cheki.idols = [idol]
        cheki.event = event
        try fixture.context.save()

        let response = await fixture.executor.execute("confirm")
        XCTAssertTrue(text(from: response).contains("event now has 1 associated cheki"))
        XCTAssertNotNil(try fixture.context.fetch(FetchDescriptor<Event>()).first { $0.id == event.id })
    }

    func testScanTemporaryImageConsumptionAndFailureRetention() async throws {
        let fixture = try makeFixture()
        defer { cleanupManagedImages(in: fixture.context) }
        let idol = Idol(name: "A")
        let event = Event(name: "E")
        fixture.context.insert(idol)
        fixture.context.insert(event)
        try fixture.context.save()

        let successful = try fixture.ledger.insertTemporaryChekis(
            [testImage(1)],
            thumbnailImageData: [nil]
        ).inserted[0]
        _ = await fixture.executor.execute(
            "addscancheki \(shortID(successful.id)) idol=\(shortID(idol.id)) event=\(shortID(event.id))"
        )
        try requireSuccess(await fixture.executor.execute("confirm"))
        XCTAssertFalse(fixture.ledger.containsTemporaryCheki(successful.id))

        let retained = try fixture.ledger.insertTemporaryChekis(
            [testImage(2)],
            thumbnailImageData: [nil]
        ).inserted[0]
        _ = await fixture.executor.execute(
            "addscancheki \(shortID(retained.id)) idol=\(shortID(idol.id)) event=\(shortID(event.id))"
        )
        fixture.context.delete(event)
        try fixture.context.save()
        let failed = await fixture.executor.execute("confirm")
        XCTAssertTrue(text(from: failed).hasPrefix("error: confirmation failed"))
        XCTAssertTrue(fixture.ledger.containsTemporaryCheki(retained.id))
    }

    func testScanUsesScannerResultsForTemporaryChekisWithoutPersistence() async throws {
        var callIndex = 0
        var receivedSources: [Data] = []
        var receivedPodIDs: [String] = []
        let pngResult = scannerPNGData(color: .red)
        let jpegResult = scannerJPEGData(color: .green)
        let secondPNGResult = scannerPNGData(color: .blue)
        let scannerResults = [
            ChekinanaScannerProcessResult(images: [pngResult], warningCount: 1),
            ChekinanaScannerProcessResult(images: [jpegResult, secondPNGResult], warningCount: 2),
        ]
        let fixture = try makeFixture { image, options in
            receivedSources.append(image.data)
            receivedPodIDs.append(options.podID)
            defer { callIndex += 1 }
            return scannerResults[callIndex]
        }
        let sourceImages = [testImage(1), testImage(2)]

        let response = await fixture.executor.execute(
            "scancheki pod=testpod123",
            pendingChekiImages: sourceImages
        )

        guard case .chekiScannedCards(let count, let warningCount, let cards) = response else {
            return XCTFail("expected scanner result cards")
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(warningCount, 3)
        XCTAssertEqual(receivedSources, sourceImages.map(\.data))
        XCTAssertEqual(receivedPodIDs, ["testpod123", "testpod123"])
        let temporaryImages = try cards.map {
            try fixture.ledger.resolveTemporaryCheki(shortID($0.id)).image
        }
        XCTAssertTrue(temporaryImages.allSatisfy { $0.filenameExtension == "jpg" })
        XCTAssertTrue(temporaryImages.allSatisfy { UIImage(data: $0.data) != nil })
        XCTAssertTrue(temporaryImages.allSatisfy { !sourceImages.map(\.data).contains($0.data) })
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    func testScannerDateAnnotationPropagatesThroughConfirmationWithoutChangingImageOrGrouping() async throws {
        let sourceResult = scannerPNGData(color: .purple)
        let originalSourceResult = sourceResult
        let reencodedSourceResult = await ChekinanaImageWorker.reencodedJPEGData(
            from: sourceResult
        )
        let expectedSavedBytes = try XCTUnwrap(reencodedSourceResult)
        let boundingBox = try XCTUnwrap(ChekinanaChekiDateBoundingBox(
            x1: 120,
            y1: 650,
            x2: 880,
            y2: 920
        ))
        let annotation = try XCTUnwrap(ChekinanaChekiDateAnnotation(
            text: "07.04",
            precision: .monthDay,
            boundingBox: boundingBox
        ))
        let fixture = try makeFixture { _, options in
            XCTAssertTrue(options.dateAnnotationEnabled)
            return ChekinanaScannerProcessResult(
                images: [
                    ChekinanaScannerResultImage(
                        data: sourceResult,
                        dateAnnotationState: .detected(annotation)
                    ),
                ],
                warningCount: 0
            )
        }
        defer { cleanupManagedImages(in: fixture.context) }
        let idol = Idol(name: "A")
        let event = Event(name: "E", date: Date(timeIntervalSince1970: 1_700_000_000))
        fixture.context.insert(idol)
        fixture.context.insert(event)
        try fixture.context.save()

        let scanResponse = await fixture.executor.execute(
            "scancheki pod=testpod123 date_annotation=true",
            pendingChekiImages: [testImage(1)]
        )
        guard case .chekiScannedCards(_, _, let scannedCards) = scanResponse,
              let scannedCard = scannedCards.first else {
            return XCTFail("expected one temporary scanner card")
        }
        XCTAssertEqual(scannedCard.dateAnnotationState, .detected(annotation))
        let temporary = try fixture.ledger.resolveTemporaryCheki(shortID(scannedCard.id))
        XCTAssertEqual(temporary.dateAnnotationState, .detected(annotation))
        XCTAssertEqual(temporary.image.data, expectedSavedBytes)

        let pendingResponse = await fixture.executor.execute(
            "addscancheki \(shortID(temporary.id)) idol=\(shortID(idol.id)) event=\(shortID(event.id))"
        )
        guard case .pendingChekiCards(_, let pendingCards, _) = pendingResponse,
              let pendingCard = pendingCards.first,
              let confirmationCode = pendingCard.confirmationCode else {
            return XCTFail("expected pending annotated Cheki")
        }
        XCTAssertEqual(pendingCard.dateAnnotationState, .detected(annotation))
        try requireSuccess(await fixture.executor.execute("confirm \(confirmationCode)"))

        let saved = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<Cheki>()).first
        )
        XCTAssertEqual(saved.handwrittenDateText, "07.04")
        XCTAssertEqual(saved.handwrittenDateBboxX1, 120)
        XCTAssertEqual(saved.handwrittenDateBboxY1, 650)
        XCTAssertEqual(saved.handwrittenDateBboxX2, 880)
        XCTAssertEqual(saved.handwrittenDateBboxY2, 920)
        XCTAssertEqual(saved.handwrittenDateAnnotation, annotation)
        XCTAssertEqual(saved.event?.id, event.id)
        XCTAssertNil(saved.eventDate)
        XCTAssertEqual(saved.idx, 1)
        let savedURL = try XCTUnwrap(ChekiImageRefResolver.managedChekiFileURL(
            for: saved.imageRef,
            chekiID: saved.id
        ))
        XCTAssertEqual(try Data(contentsOf: savedURL), expectedSavedBytes)
        XCTAssertEqual(sourceResult, originalSourceResult)
    }

    func testNonDetectedAndUnavailableAnnotationsNeverPersistDateFields() async throws {
        for state in [
            ChekinanaChekiDateAnnotationState.notDetected,
            .unavailable,
        ] {
            let resultImage = scannerPNGData(color: .brown)
            let fixture = try makeFixture { _, _ in
                ChekinanaScannerProcessResult(
                    images: [
                        ChekinanaScannerResultImage(
                            data: resultImage,
                            dateAnnotationState: state
                        ),
                    ],
                    warningCount: 0
                )
            }
            let idol = Idol(name: "A")
            let event = Event(name: "E")
            fixture.context.insert(idol)
            fixture.context.insert(event)
            try fixture.context.save()

            let scanResponse = await fixture.executor.execute(
                "scancheki pod=testpod123 date_annotation=true",
                pendingChekiImages: [testImage(1)]
            )
            guard case .chekiScannedCards(_, _, let scanCards) = scanResponse,
                  let scanCard = scanCards.first else {
                return XCTFail("expected temporary scanner result")
            }
            XCTAssertEqual(scanCard.dateAnnotationState, state)
            let pendingResponse = await fixture.executor.execute(
                "addscancheki \(shortID(scanCard.id)) idol=\(shortID(idol.id)) event=\(shortID(event.id))"
            )
            guard case .pendingChekiCards(_, let pendingCards, _) = pendingResponse,
                  let code = pendingCards.first?.confirmationCode else {
                return XCTFail("expected pending Cheki")
            }
            try requireSuccess(await fixture.executor.execute("confirm \(code)"))
            let saved = try XCTUnwrap(
                fixture.context.fetch(FetchDescriptor<Cheki>()).first
            )
            XCTAssertNil(saved.handwrittenDateText)
            XCTAssertNil(saved.handwrittenDateBboxX1)
            XCTAssertNil(saved.handwrittenDateBboxY1)
            XCTAssertNil(saved.handwrittenDateBboxX2)
            XCTAssertNil(saved.handwrittenDateBboxY2)
            cleanupManagedImages(in: fixture.context)
        }
    }

    func testScanFailureDoesNotFallbackToSourcesOrInsertPartialResults() async throws {
        var callIndex = 0
        let validResult = scannerPNGData(color: .red)
        let fixture = try makeFixture { _, _ in
            defer { callIndex += 1 }
            if callIndex == 0 {
                return ChekinanaScannerProcessResult(
                    images: [validResult],
                    warningCount: 0
                )
            }
            throw ScannerMockError.failed
        }

        let response = await fixture.executor.execute(
            "scancheki pod=testpod123",
            pendingChekiImages: [testImage(1), testImage(2)]
        )

        XCTAssertTrue(text(from: response).contains("mock scanner failed"))
        XCTAssertTrue(fixture.ledger.availableTemporaryChekiChoices().isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    func testScanRejectsNonEmptyNonImageResultWithoutTemporaryWrite() async throws {
        let fixture = try makeFixture { _, _ in
            ChekinanaScannerProcessResult(
                images: [Data([0x01, 0x02, 0x03, 0x04])],
                warningCount: 0
            )
        }

        let response = await fixture.executor.execute(
            "scancheki pod=testpod123",
            pendingChekiImages: [testImage(1)]
        )

        XCTAssertTrue(text(from: response).contains("not a decodable image"))
        XCTAssertTrue(fixture.ledger.availableTemporaryChekiChoices().isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    func testCancelledScanIgnoresLateNonCooperativeScannerResult() async throws {
        let scannerStarted = expectation(description: "scanner started")
        let scannerRelease = ScannerReleaseGate()
        let validResult = scannerPNGData(color: .purple)
        let fixture = try makeFixture { _, _ in
            scannerStarted.fulfill()
            await scannerRelease.wait()
            return ChekinanaScannerProcessResult(images: [validResult], warningCount: 0)
        }

        let task = Task { @MainActor in
            await fixture.executor.execute(
                "scancheki pod=testpod123",
                pendingChekiImages: [testImage(1)]
            )
        }
        await fulfillment(of: [scannerStarted], timeout: 1)
        task.cancel()
        await scannerRelease.release()
        _ = await task.value

        XCTAssertTrue(fixture.ledger.availableTemporaryChekiChoices().isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Cheki>()).isEmpty)
    }

    func testScanWithoutPodFailsLocallyBeforeScannerOrTemporaryWrite() async throws {
        var scannerWasCalled = false
        let fixture = try makeFixture { _, _ in
            scannerWasCalled = true
            return ChekinanaScannerProcessResult(images: [Data([101])], warningCount: 0)
        }

        let response = await fixture.executor.execute(
            "scancheki",
            pendingChekiImages: [testImage(1)]
        )

        XCTAssertTrue(text(from: response).contains("pod is required"))
        XCTAssertFalse(scannerWasCalled)
        XCTAssertTrue(fixture.ledger.availableTemporaryChekiChoices().isEmpty)
    }

    func testCredentialedEventURLIsRejectedWithoutWriteLedgerEntryOrEcho() async throws {
        let fixture = try makeFixture()
        let response = await fixture.executor.execute(
            "addevent https://user:password@example.com/live"
        )

        let output = text(from: response)
        XCTAssertTrue(output.contains("invalid event url"))
        XCTAssertFalse(output.contains("user"))
        XCTAssertFalse(output.contains("password"))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
    }

    func testEventNameResolutionSupportsChekiAndDuplicateIsDistinctFromAmbiguity() async throws {
        let fixture = try makeFixture()
        let idol = Idol(name: "Alice")
        let exact = Event(name: "Summer")
        let longer = Event(name: "Summer Tour")
        fixture.context.insert(idol)
        fixture.context.insert(exact)
        fixture.context.insert(longer)
        try fixture.context.save()

        let request = await fixture.executor.execute(
            "addcheki idol=Alice event=Summer"
        )
        guard case .requestAddChekiPhoto = request else {
            return XCTFail("exact Event name should resolve for Cheki")
        }

        let ambiguous = await fixture.executor.execute("addcheki idol=Alice event=Summ")
        XCTAssertTrue(text(from: ambiguous).contains("ambiguous event"))

        let duplicate = await fixture.executor.execute("addevent Summer date=2026-08-01")
        guard case .confirmationText(_, let code) = duplicate else {
            return XCTFail("date makes this a distinct event")
        }
        _ = await fixture.executor.execute("confirm \(code)")
        let duplicateAgain = await fixture.executor.execute("addevent Summer date=2026-08-01")
        XCTAssertTrue(text(from: duplicateAgain).contains("same name, date, and url"))
    }

    func testIdolMultiResultPreservesAPIOrderFiltersAndConfirmsOnlySelection() async throws {
        let exact = enrichedIdol(sourceID: "catalogue-exact", name: "Aina", group: "空色轨迹")
        let fuzzy = enrichedIdol(sourceID: "catalogue-fuzzy", name: "Aina Related", group: "Other")
        let duplicate = enrichedIdol(sourceID: exact.sourceId, name: "Duplicate", group: nil)
        let alreadyAdded = enrichedIdol(sourceID: "catalogue-existing", name: "Existing", group: nil)
        let fixture = try makeFixture(idolSearch: { _ in
            [exact, fuzzy, duplicate, alreadyAdded]
        })
        fixture.context.insert(Idol(sourceId: alreadyAdded.sourceId, name: alreadyAdded.idolName))
        try fixture.context.save()

        let response = await fixture.executor.execute("addidol Aina")
        guard case .idolCards(let cards) = response else {
            return XCTFail("expected multiple selectable Idol cards")
        }
        XCTAssertEqual(cards.map(\.catalogueID), [exact.sourceId, fuzzy.sourceId])
        XCTAssertEqual(cards.map(\.name), [exact.idolName, fuzzy.idolName])
        XCTAssertTrue(cards.allSatisfy { $0.confirmationCode == nil && $0.selectionToken != nil })
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)

        let selectedToken = try XCTUnwrap(cards[1].selectionToken)
        let selection = await fixture.executor.execute("selectidolcandidate \(selectedToken)")
        guard case .idolCard(let preview) = selection else {
            return XCTFail("expected selected Idol confirmation preview")
        }
        XCTAssertEqual(preview.catalogueID, fuzzy.sourceId)
        XCTAssertNil(preview.selectionToken)
        let code = try XCTUnwrap(preview.confirmationCode)
        XCTAssertEqual(fixture.ledger.activeConfirmationCodes, Set([code]))

        let staleOther = await fixture.executor.execute(
            "selectidolcandidate \(try XCTUnwrap(cards[0].selectionToken))"
        )
        XCTAssertTrue(text(from: staleOther).contains("no longer available"))
        XCTAssertEqual(fixture.ledger.activeConfirmationCodes, Set([code]))

        _ = await fixture.executor.execute("confirm \(code)")
        let saved = try fixture.context.fetch(FetchDescriptor<Idol>())
        XCTAssertNotNil(saved.first { $0.sourceId == fuzzy.sourceId })
        XCTAssertNil(saved.first { $0.sourceId == exact.sourceId })
    }

    func testIdolCandidateTokenBecomesStaleAfterNewQueryAndInvalidTokenDoesNotWrite() async throws {
        let firstResults = [
            enrichedIdol(sourceID: "first-a", name: "First A", group: nil),
            enrichedIdol(sourceID: "first-b", name: "First B", group: nil),
        ]
        let secondResults = [
            enrichedIdol(sourceID: "second-a", name: "Second A", group: nil),
            enrichedIdol(sourceID: "second-b", name: "Second B", group: nil),
        ]
        let fixture = try makeFixture(idolSearch: { query in
            query == "first" ? firstResults : secondResults
        })
        guard case .idolCards(let firstCards) = await fixture.executor.execute("addidol first") else {
            return XCTFail("expected first candidates")
        }
        let staleToken = try XCTUnwrap(firstCards.first?.selectionToken)
        guard case .idolCards(let secondCards) = await fixture.executor.execute("addidol second") else {
            return XCTFail("expected second candidates")
        }
        let currentToken = try XCTUnwrap(secondCards.first?.selectionToken)

        let staleResponse = await fixture.executor.execute("selectidolcandidate \(staleToken)")
        XCTAssertTrue(text(from: staleResponse).contains("no longer available"))
        let invalidatedCurrentResponse = await fixture.executor.execute(
            "selectidolcandidate \(currentToken)"
        )
        XCTAssertTrue(text(from: invalidatedCurrentResponse).contains("no longer available"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)
    }

    func testInvalidIdolCandidateTokenInvalidatesCurrentBatch() async throws {
        let results = [
            enrichedIdol(sourceID: "invalid-a", name: "Invalid A", group: nil),
            enrichedIdol(sourceID: "invalid-b", name: "Invalid B", group: nil),
        ]
        let fixture = try makeFixture(idolSearch: { _ in results })
        guard case .idolCards(let cards) = await fixture.executor.execute("addidol Invalid") else {
            return XCTFail("expected candidates")
        }
        let currentToken = try XCTUnwrap(cards.first?.selectionToken)

        let invalidResponse = await fixture.executor.execute(
            "selectidolcandidate \(UUID().uuidString.lowercased())"
        )
        XCTAssertTrue(text(from: invalidResponse).contains("no longer available"))
        let currentResponse = await fixture.executor.execute(
            "selectidolcandidate \(currentToken)"
        )

        XCTAssertTrue(text(from: currentResponse).contains("no longer available"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)
    }

    func testLateOldIdolQueryCannotOverwriteNewCandidates() async throws {
        let oldResults = [
            enrichedIdol(sourceID: "late-old-a", name: "Late Old A", group: nil),
            enrichedIdol(sourceID: "late-old-b", name: "Late Old B", group: nil),
        ]
        let newResults = [
            enrichedIdol(sourceID: "current-a", name: "Current A", group: nil),
            enrichedIdol(sourceID: "current-b", name: "Current B", group: nil),
        ]
        let oldSearchStarted = expectation(description: "old Idol search started")
        let oldSearchRelease = ScannerReleaseGate()
        let fixture = try makeFixture(idolSearch: { query in
            if query == "old" {
                oldSearchStarted.fulfill()
                await oldSearchRelease.wait()
                return oldResults
            }
            return newResults
        })

        let oldTask = Task { @MainActor in
            await fixture.executor.execute("addidol old")
        }
        await fulfillment(of: [oldSearchStarted], timeout: 1)

        guard case .idolCards(let currentCards) = await fixture.executor.execute("addidol new") else {
            return XCTFail("expected current candidates")
        }
        let currentToken = try XCTUnwrap(currentCards.first?.selectionToken)
        await oldSearchRelease.release()
        let oldResponse = await oldTask.value

        XCTAssertTrue(text(from: oldResponse).contains("no longer active"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        let selection = await fixture.executor.execute("selectidolcandidate \(currentToken)")
        guard case .idolCard(let preview) = selection else {
            return XCTFail("current candidates must remain selectable")
        }
        XCTAssertEqual(preview.catalogueID, newResults[0].sourceId)
        let code = try XCTUnwrap(preview.confirmationCode)
        _ = await fixture.executor.execute("confirm \(code)")
        let saved = try fixture.context.fetch(FetchDescriptor<Idol>())
        XCTAssertEqual(saved.map(\.sourceId), [newResults[0].sourceId])
    }

    func testCancelledLateSingleIdolQueryDoesNotCreateHiddenConfirmation() async throws {
        let result = enrichedIdol(sourceID: "cancelled-single", name: "Cancelled", group: nil)
        let searchStarted = expectation(description: "single Idol search started")
        let searchRelease = ScannerReleaseGate()
        let fixture = try makeFixture(idolSearch: { _ in
            searchStarted.fulfill()
            await searchRelease.wait()
            return [result]
        })

        let task = Task { @MainActor in
            await fixture.executor.execute("addidol Cancelled")
        }
        await fulfillment(of: [searchStarted], timeout: 1)
        _ = await fixture.executor.execute("cancel all")
        task.cancel()
        await searchRelease.release()
        _ = await task.value

        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)
    }

    func testCancelledSelectionOwnerBeforeStartCreatesNoHiddenConfirmationAndAllowsRetry() async throws {
        let results = [
            enrichedIdol(sourceID: "owner-selection-a", name: "Owner A", group: nil),
            enrichedIdol(sourceID: "owner-selection-b", name: "Owner B", group: nil),
        ]
        let fixture = try makeFixture(idolSearch: { _ in results })
        guard case .idolCards = await fixture.executor.execute("addidol Owner") else {
            return XCTFail("expected initial candidates")
        }

        var cancelledGate = ChekinanaOwnedExecutionGate()
        let cancelledOwner = cancelledGate.begin()
        cancelledGate.invalidate()
        fixture.ledger.invalidateIdolCandidates()
        XCTAssertFalse(cancelledGate.accepts(cancelledOwner, isCancelled: true))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)

        guard case .idolCards(let retryCards) = await fixture.executor.execute("addidol Owner") else {
            return XCTFail("expected retry candidates")
        }
        let retryToken = try XCTUnwrap(retryCards.first?.selectionToken)
        var retryGate = ChekinanaOwnedExecutionGate()
        let retryOwner = retryGate.begin()
        XCTAssertTrue(retryGate.accepts(retryOwner, isCancelled: false))
        let retryResponse = await fixture.executor.execute("selectidolcandidate \(retryToken)")
        XCTAssertTrue(retryGate.finish(retryOwner))
        guard case .idolCard(let preview) = retryResponse else {
            return XCTFail("new owner should be able to select a candidate")
        }
        XCTAssertNotNil(preview.confirmationCode)
        XCTAssertEqual(fixture.ledger.activeConfirmationCodes.count, 1)
    }

    func testCancelledConfirmationOwnerBeforeStartDoesNotWriteAndAllowsRetry() async throws {
        let result = enrichedIdol(sourceID: "owner-confirm", name: "Owner Confirm", group: nil)
        let fixture = try makeFixture(idolSearch: { _ in [result] })
        guard case .idolCard(let preview) = await fixture.executor.execute("addidol \"Owner Confirm\""),
              let code = preview.confirmationCode else {
            return XCTFail("expected AddIdol confirmation")
        }

        var cancelledGate = ChekinanaOwnedExecutionGate()
        let cancelledOwner = cancelledGate.begin()
        cancelledGate.invalidate()
        XCTAssertFalse(cancelledGate.accepts(cancelledOwner, isCancelled: true))
        XCTAssertEqual(fixture.ledger.activeConfirmationCodes, Set([code]))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)

        var retryGate = ChekinanaOwnedExecutionGate()
        let retryOwner = retryGate.begin()
        XCTAssertTrue(retryGate.accepts(retryOwner, isCancelled: false))
        try requireSuccess(await fixture.executor.execute("confirm \(code)"))
        XCTAssertTrue(retryGate.finish(retryOwner))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<Idol>()).map(\.sourceId), [result.sourceId])
    }

    func testCancelAllInvalidatesUnconfirmedIdolCandidates() async throws {
        let results = [
            enrichedIdol(sourceID: "cancel-a", name: "Cancel A", group: nil),
            enrichedIdol(sourceID: "cancel-b", name: "Cancel B", group: nil),
        ]
        let fixture = try makeFixture(idolSearch: { _ in results })
        guard case .idolCards(let cards) = await fixture.executor.execute("addidol Cancel") else {
            return XCTFail("expected candidates")
        }
        let token = try XCTUnwrap(cards.first?.selectionToken)

        _ = await fixture.executor.execute("cancel all")
        let response = await fixture.executor.execute("selectidolcandidate \(token)")

        XCTAssertTrue(text(from: response).contains("no longer available"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Idol>()).isEmpty)
    }

    func testEventURLRequiresNameAndDateThenSavesCompleteFields() async throws {
        let fixture = try makeFixture()
        let url = "https://example.com/weibo/123"
        for command in [
            "addevent \(url)",
            "addevent \(url) name=ChekiDemo",
            "addevent \(url) date=2026-07-11",
        ] {
            let response = await fixture.executor.execute(command)
            XCTAssertTrue(text(from: response).contains("requires an explicit name and date"), command)
            XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty, command)
            XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty, command)
        }

        let complete = await fixture.executor.execute(
            "addevent \(url) name=\"Cheki Demo\" date=2026-07-11"
        )
        guard case .confirmationText(_, let code) = complete else {
            return XCTFail("expected complete Event confirmation")
        }
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)
        _ = await fixture.executor.execute("confirm \(code)")
        let saved = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<Event>()).first)
        XCTAssertEqual(saved.name, "Cheki Demo")
        XCTAssertEqual(saved.weiboURL?.absoluteString, url)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.day, from: try XCTUnwrap(saved.date)), 11)
    }

    func testEventConfirmationRechecksDuplicateBeforeFinalInsert() async throws {
        let fixture = try makeFixture()
        let cases = [
            (
                command: "addevent Duplicate date=2026-07-12",
                expectedURL: nil as String?
            ),
            (
                command: "addevent https://example.com/weibo/duplicate name=URLDuplicate date=2026-07-13",
                expectedURL: "https://example.com/weibo/duplicate" as String?
            ),
        ]

        for testCase in cases {
            guard case .confirmationText(_, let firstCode) = await fixture.executor.execute(testCase.command),
                  case .confirmationText(_, let secondCode) = await fixture.executor.execute(testCase.command) else {
                return XCTFail("expected two independently prepared Event confirmations")
            }

            try requireSuccess(await fixture.executor.execute("confirm \(firstCode)"))
            let duplicateResponse = await fixture.executor.execute("confirm \(secondCode)")
            XCTAssertTrue(text(from: duplicateResponse).contains("same name, date, and url"))
            XCTAssertTrue(fixture.ledger.activeConfirmationCodes.contains(secondCode))
        }

        let events = try fixture.context.fetch(FetchDescriptor<Event>())
        XCTAssertEqual(events.count, cases.count)
        XCTAssertEqual(
            events.compactMap { $0.weiboURL?.absoluteString },
            cases.compactMap(\.expectedURL)
        )
    }

    func testExtractedEventCandidateFreezesSevenFieldsAndConfirmsAtomicallyWithNilDate() async throws {
        let fixture = try makeFixture()
        let fields = ChekinanaEventCandidateFields(
            name: "Seven Field Live",
            date: "",
            city: "上海",
            livehouse: "新歌空间中大二号馆",
            weiboURL: "https://weibo.com/123456/AbC123",
            ticketURL: "https://tickets.showstart.com/event/42",
            note: "用户修订备注"
        )

        let prepared = fixture.executor.prepareEventCandidate(fields)
        guard case .eventCard(let card) = prepared,
              let code = card.confirmationCode else {
            return XCTFail("expected structured Event confirmation card")
        }
        XCTAssertEqual(card.date, "")
        XCTAssertEqual(card.city, fields.city)
        XCTAssertEqual(card.livehouse, fields.livehouse)
        XCTAssertEqual(card.ticketURL, fields.ticketURL)
        XCTAssertEqual(card.note, fields.note)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)

        try requireSuccess(await fixture.executor.execute("confirm \(code)"))
        let saved = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<Event>()).first)
        XCTAssertEqual(saved.name, fields.name)
        XCTAssertNil(saved.date)
        XCTAssertEqual(saved.city, fields.city)
        XCTAssertEqual(saved.livehouse, fields.livehouse)
        XCTAssertEqual(saved.weiboURL?.absoluteString, fields.weiboURL)
        XCTAssertEqual(saved.ticketURL?.absoluteString, fields.ticketURL)
        XCTAssertEqual(saved.note, fields.note)

        guard case .eventCards(let listed) = await fixture.executor.execute("listevent") else {
            return XCTFail("expected structured Event list")
        }
        XCTAssertEqual(listed.first?.city, fields.city)
        XCTAssertEqual(listed.first?.livehouse, fields.livehouse)
        XCTAssertEqual(listed.first?.ticketURL, fields.ticketURL)
    }

    func testEditEventPreservesExtractedFieldsItDoesNotEdit() async throws {
        let fixture = try makeFixture()
        let event = Event(
            name: "Before",
            date: nil,
            city: "上海",
            livehouse: "新歌空间中大二号馆",
            weiboURL: URL(string: "https://weibo.com/123/AbC"),
            ticketURL: URL(string: "https://showstart.com/event/1"),
            note: "keep"
        )
        fixture.context.insert(event)
        try fixture.context.save()

        let prepared = await fixture.executor.execute("editevent \(shortID(event.id)) name=After")
        guard case .confirmationText(_, let code) = prepared else {
            return XCTFail("expected edit confirmation")
        }
        try requireSuccess(await fixture.executor.execute("confirm \(code)"))
        XCTAssertEqual(event.name, "After")
        XCTAssertEqual(event.city, "上海")
        XCTAssertEqual(event.livehouse, "新歌空间中大二号馆")
        XCTAssertEqual(event.ticketURL?.absoluteString, "https://showstart.com/event/1")
        XCTAssertEqual(event.note, "keep")
    }

    func testEventCandidateBlockersAndCancellationCreateNoWrites() async throws {
        let fixture = try makeFixture()
        let base = ChekinanaEventCandidateFields(
            name: "Blocked",
            date: "2026-08-02",
            city: "北京",
            livehouse: "北京市朝阳区幸福路100号",
            weiboURL: "https://weibo.com/123/AbC",
            ticketURL: "https://evil.example/ticket",
            note: ""
        )
        let blocked = fixture.executor.prepareEventCandidate(base)
        XCTAssertTrue(text(from: blocked).contains("not ready"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)

        var valid = base
        valid.livehouse = "幸福Livehouse朝阳店"
        valid.ticketURL = ""
        guard case .eventCard(let card) = fixture.executor.prepareEventCandidate(valid),
              let code = card.confirmationCode else {
            return XCTFail("expected corrected Event candidate")
        }
        _ = await fixture.executor.execute("cancel \(code)")
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)
    }

    func testEventCandidateStrictEnvelopeInputAndGenerationGate() throws {
        let success = Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Live","date":"","city":"","livehouse":"中大二号馆","weiboURL":"https://weibo.com/123/AbC","ticketURL":"","note":""}}"#.utf8)
        let fields = try ChekinanaEventCandidateClient.decodeSuccess(success)
        XCTAssertEqual(fields.name, "Live")
        XCTAssertTrue(ChekinanaEventCandidateValidator.blockers(for: fields).isEmpty)
        XCTAssertNotNil(ChekinanaEventWeiboInput.extractedURL(from: fields.weiboURL))
        XCTAssertEqual(
            ChekinanaEventWeiboInput.extractedURL(from: "创建 Event \(fields.weiboURL)"),
            fields.weiboURL
        )
        XCTAssertEqual(
            ChekinanaEventWeiboInput.extractedURL(from: "addevent \(fields.weiboURL)"),
            fields.weiboURL
        )

        let extra = Data(#"{"version":1,"kind":"candidate","extra":true,"candidate":{"name":"Live","date":"","city":"","livehouse":"","weiboURL":"https://weibo.com/123/AbC","ticketURL":"","note":""}}"#.utf8)
        XCTAssertThrowsError(try ChekinanaEventCandidateClient.decodeSuccess(extra))
        XCTAssertEqual(
            ChekinanaEventCandidateClient.decodeReject(Data(#"{"version":1,"kind":"reject","code":"invalid_weibo_url"}"#.utf8)),
            .rejected("invalid_weibo_url")
        )

        var state = ChekinanaEventCandidateStateMachine()
        let staleGeneration = state.begin(url: fields.weiboURL)
        state.invalidate()
        XCTAssertFalse(state.complete(fields, generation: staleGeneration))
        XCTAssertEqual(state.phase, .idle)
        let currentGeneration = state.begin(url: fields.weiboURL)
        XCTAssertTrue(state.complete(fields, generation: currentGeneration))
        XCTAssertEqual(state.phase, .editing(fields))
        XCTAssertFalse(state.accepts(currentGeneration, isCancelled: false))

        var busyOwner = ChekinanaEventCandidateBusyOwner()
        XCTAssertTrue(busyOwner.acquire(generation: currentGeneration))
        XCTAssertFalse(busyOwner.acquire(generation: currentGeneration &+ 1))
        XCTAssertTrue(busyOwner.owns(generation: currentGeneration, isCancelled: false))
        XCTAssertFalse(busyOwner.release(generation: currentGeneration &+ 1))
        XCTAssertTrue(busyOwner.release(generation: currentGeneration))
        XCTAssertNil(busyOwner.generation)
    }

    func testEventCandidateWeiboURLShapeMatchesWorkerContract() throws {
        let accepted = [
            "https://weibo.com/123456/AbC123",
            "https://www.weibo.com/user_name/Z9",
            "https://weibo.com/%E5%81%B6%E5%83%8F/%41bC123",
            "https://weibo.com/\(String(repeating: "u", count: 200))/AbC123",
        ]
        let rejected = [
            "http://weibo.com/123456/AbC123",
            "https://user@weibo.com/123456/AbC123",
            "https://weibo.com:443/123456/AbC123",
            "https://weibo.com/123456/AbC123?source=app",
            "https://weibo.com/123456/AbC123#detail",
            "https://weibo.com/123456/AbC123/",
            "https://weibo.com//123456/AbC123",
            "https://weibo.com/123456/extra/AbC123",
            "https://weibo.com/123456/AbC-123",
            "https://weibo.com/foo%2Fbar/AbC123",
            "https://weibo.com/foo%3Fbar/AbC123",
            "https://weibo.com/foo%23bar/AbC123",
            "https://weibo.com/foo%00bar/AbC123",
            "https://weibo.com/foo%7Fbar/AbC123",
            "https://weibo.com/./AbC123",
            "https://weibo.com/../AbC123",
            "https://weibo.com/%2e%2e/AbC123",
            "https://weibo.com/foo\\bar/AbC123",
            "https://weibo.com/foo%5Cbar/AbC123",
            "https://weibo.com/foo%ZZ/AbC123",
            "https://weibo.com/foo%FF/AbC123",
            "https://weibo.com/123456/AbC%2F123",
            "https://weibo.com/\(String(repeating: "u", count: 201))/AbC123",
            "https://m.weibo.com/123456/AbC123",
        ]
        accepted.forEach {
            XCTAssertTrue(ChekinanaEventCandidateValidator.isPublicWeiboStatusURL($0), $0)
        }
        rejected.forEach {
            XCTAssertFalse(ChekinanaEventCandidateValidator.isPublicWeiboStatusURL($0), $0)
        }

        let fixture = try makeFixture()
        var fields = ChekinanaEventCandidateFields(
            name: "Strict URL",
            date: "",
            city: "",
            livehouse: "Fixture Livehouse 中大二号馆",
            weiboURL: accepted[0],
            ticketURL: "",
            note: ""
        )
        fields.weiboURL = rejected[3]
        XCTAssertTrue(text(from: fixture.executor.prepareEventCandidate(fields)).contains("not ready"))
        XCTAssertTrue(fixture.ledger.activeConfirmationCodes.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<Event>()).isEmpty)
    }

    func testEventCandidateConservativeLivehouseAddressBlocker() {
        let blocked = [
            "北京市朝阳区幸福路一百号",
            "北京市朝阳区幸福路东段",
            "幸福路东段",
            "上海市幸福路100号",
            "北京市朝阳区幸福路",
            "朝阳区幸福街",
        ]
        let allowed = [
            "Fixture Livehouse 中大二号馆",
            "幸福Livehouse朝阳店",
            "新歌空间中大二号馆",
            "MAO Livehouse 五棵松店",
        ]
        blocked.forEach {
            XCTAssertTrue(ChekinanaEventCandidateValidator.livehouseLooksLikeDetailedAddress($0), $0)
        }
        allowed.forEach {
            XCTAssertFalse(ChekinanaEventCandidateValidator.livehouseLooksLikeDetailedAddress($0), $0)
        }
    }

    func testEventCandidateClientPostsExactRequestAndDecodesSevenStrings() async throws {
        let url = "https://weibo.com/123/AbC"
        ChekinanaEventCandidateMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.chekinana.top/api/event/weibo-candidate")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["version", "weiboURL"]))
            XCTAssertEqual(object["version"] as? Int, 1)
            XCTAssertEqual(object["weiboURL"] as? String, url)
            return Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Live","date":"2026-08-02","city":"合肥","livehouse":"791Crow","weiboURL":"https://weibo.com/123/AbC","ticketURL":"","note":""}}"#.utf8)
        }
        defer { ChekinanaEventCandidateMockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaEventCandidateMockURLProtocol.self]
        let client = ChekinanaEventCandidateClient(session: URLSession(configuration: configuration))

        let fields = try await client.fetch(weiboURL: url)
        XCTAssertEqual(fields.name, "Live")
        XCTAssertEqual(fields.city, "合肥")
    }

    private func makeFixture(
        scannerProcess: ChekinanaCommandExecutor.ScannerProcess? = nil,
        idolSearch: ChekinanaCommandExecutor.IdolSearch? = nil
    ) throws -> Fixture {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let ledger = ChekinanaConfirmationLedger()
        let executor: ChekinanaCommandExecutor
        if let scannerProcess, let idolSearch {
            executor = ChekinanaCommandExecutor(
                modelContext: context,
                confirmationLedger: ledger,
                scannerProcess: scannerProcess,
                idolSearch: idolSearch
            )
        } else if let scannerProcess {
            executor = ChekinanaCommandExecutor(
                modelContext: context,
                confirmationLedger: ledger,
                scannerProcess: scannerProcess
            )
        } else if let idolSearch {
            executor = ChekinanaCommandExecutor(
                modelContext: context,
                confirmationLedger: ledger,
                idolSearch: idolSearch
            )
        } else {
            executor = ChekinanaCommandExecutor(
                modelContext: context,
                confirmationLedger: ledger
            )
        }
        return Fixture(context: context, ledger: ledger, executor: executor)
    }

    private func enrichedIdol(
        sourceID: String,
        name: String,
        group: String?
    ) -> ChekinanaEnrichedIdol {
        ChekinanaEnrichedIdol(
            sourceId: sourceID,
            idolName: name,
            groupName: group,
            color: "#3366CC",
            birthday: "2000-01-01",
            verification: "verified",
            bio: "catalogue bio",
            avatarUrl: nil
        )
    }

    private func prepareAlbumChekis(
        count: Int,
        idol: Idol,
        event: Event,
        fixture: Fixture
    ) throws -> [ChekinanaChekiCard] {
        let request = ChekinanaAlbumAddChekiRequest(arguments: [
            "idol": shortID(idol.id),
            "event": shortID(event.id),
        ])
        let prepared = (0..<count).map { index in
            ChekinanaPreparedAlbumCheki(
                request: request,
                image: testImage(UInt8(index + 1)),
                thumbnailImageData: nil
            )
        }
        let response = try fixture.executor.finalizeAlbumAddChekis(prepared, failedCount: 0)
        guard case .pendingChekiCards(_, let cards, _) = response else {
            XCTFail("expected pending Cheki cards")
            return []
        }
        return cards
    }

    private func requireSuccess(_ response: ChekinanaCommandResponse) throws {
        if case .text(let value) = response, value.hasPrefix("error:") {
            XCTFail(value)
            throw HarnessError.unexpectedResponse(value)
        }
    }

    private func text(from response: ChekinanaCommandResponse) -> String {
        guard case .text(let value) = response else { return "" }
        return value
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private func testImage(_ marker: UInt8) -> ChekinanaPendingChekiImage {
        ChekinanaPendingChekiImage(data: Data([marker]), filenameExtension: "png")
    }

    private func scannerOptions(
        dateAnnotationEnabled: Bool
    ) -> ChekinanaScannerOptions {
        ChekinanaScannerOptions(
            podID: "scanner-test-token",
            expectedPolaroids: nil,
            scannerSize: .auto,
            postprocessMode: .off,
            whiteBalance: true,
            dateAnnotationEnabled: dateAnnotationEnabled
        )
    }

    private func scannerDateMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaScannerDateMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func scannerPNGData(color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func scannerJPEGData(color: UIColor) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    private func cleanupManagedImages(in context: ModelContext) {
        guard let chekis = try? context.fetch(FetchDescriptor<Cheki>()) else { return }
        for cheki in chekis {
            guard let url = ChekiImageRefResolver.managedChekiFileURL(
                for: cheki.imageRef,
                chekiID: cheki.id
            ) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private enum HarnessError: Error {
        case unexpectedResponse(String)
    }

    private enum ScannerMockError: LocalizedError {
        case failed

        var errorDescription: String? {
            "mock scanner failed"
        }
    }

    private actor ScannerReleaseGate {
        private var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }
}

private final class ChekinanaEventCandidateMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let data = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ChekinanaScannerDateMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (data: Data, headers: [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: result.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

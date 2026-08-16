import Foundation
import CoreImage
import CoreML
import ImageIO
import OSLog
import Photos
import SwiftData
import UIKit
import Vision

struct ChekinanaIdolCard: Identifiable, Equatable {
    let id: UUID
    let catalogueID: String?
    let name: String
    let group: String?
    let color: String?
    let birthday: String?
    let verification: String?
    let bio: String?
    let avatarImageRef: String?
    let avatarThumbnailData: Data?
    let avatarIdentity: String?
    let avatarThumbnailImage: ChekinanaRenderedImage?
    let detail: ChekinanaIdolCardDetail
    let confirmationCode: String?
    let selectionToken: String?

    init(
        id: UUID,
        catalogueID: String?,
        name: String,
        group: String?,
        color: String?,
        birthday: String?,
        verification: String?,
        bio: String?,
        avatarImageRef: String?,
        avatarThumbnailData: Data?,
        avatarIdentity: String?,
        avatarThumbnailImage: ChekinanaRenderedImage? = nil,
        detail: ChekinanaIdolCardDetail,
        confirmationCode: String?,
        selectionToken: String?
    ) {
        self.id = id
        self.catalogueID = catalogueID
        self.name = name
        self.group = group
        self.color = color
        self.birthday = birthday
        self.verification = verification
        self.bio = bio
        self.avatarImageRef = avatarImageRef
        self.avatarThumbnailData = avatarThumbnailData
        self.avatarIdentity = avatarIdentity
        self.avatarThumbnailImage = avatarThumbnailImage
        self.detail = detail
        self.confirmationCode = confirmationCode
        self.selectionToken = selectionToken
    }
}

struct ChekinanaPreparedIdolCandidate: Equatable, Sendable {
    let candidate: ChekinanaEnrichedIdol
    let avatarThumbnailData: Data?
    let avatarIdentity: String?
    let avatarThumbnailImage: ChekinanaRenderedImage?

    init(
        candidate: ChekinanaEnrichedIdol,
        avatarThumbnailData: Data?,
        avatarIdentity: String?,
        avatarThumbnailImage: ChekinanaRenderedImage? = nil
    ) {
        self.candidate = candidate
        self.avatarThumbnailData = avatarThumbnailData
        self.avatarIdentity = avatarIdentity
        self.avatarThumbnailImage = avatarThumbnailImage
    }
}

#if DEBUG
private enum ChekinanaIdolPipelineTimingLog {
    private static let logger = Logger(
        subsystem: "app.chekinana.ios",
        category: "IdolPipelineTiming"
    )

    static func search(
        requestedCount: Int,
        completedCount: Int,
        candidateCount: Int,
        startedAt: UInt64
    ) {
        logger.debug(
            "search completed requested=\(requestedCount, privacy: .public) completed=\(completedCount, privacy: .public) candidates=\(candidateCount, privacy: .public) elapsed_ms=\(milliseconds(since: startedAt), privacy: .public)"
        )
    }

    static func avatars(requestedCount: Int, completedCount: Int, startedAt: UInt64) {
        logger.debug(
            "avatar prepare completed requested=\(requestedCount, privacy: .public) completed=\(completedCount, privacy: .public) elapsed_ms=\(milliseconds(since: startedAt), privacy: .public)"
        )
    }

    static func avatarBatchStarted(_ requestedCount: Int) {
        logger.debug("avatar prepare started requested=\(requestedCount, privacy: .public)")
    }

    static func avatarItemCompleted(index: Int, usedPlaceholder: Bool) {
        logger.debug(
            "avatar item completed index=\(index, privacy: .public) placeholder=\(usedPlaceholder, privacy: .public)"
        )
    }

    static func avatarBatchTimedOut(completedCount: Int, requestedCount: Int) {
        logger.debug(
            "avatar prepare timeout completed=\(completedCount, privacy: .public) requested=\(requestedCount, privacy: .public)"
        )
    }

    static func publishedCards(_ count: Int) {
        logger.debug("published candidate cards=\(count, privacy: .public)")
    }

    private static func milliseconds(since startedAt: UInt64) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    }
}
#endif

private final class ChekinanaAvatarBatchDeadline: @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(
        timeoutNanoseconds: UInt64,
        action: @escaping @Sendable () -> Void
    ) {
        workItem = DispatchWorkItem(block: action)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .nanoseconds(Int(clamping: timeoutNanoseconds)),
            execute: workItem
        )
    }

    func cancel() {
        workItem.cancel()
    }
}

enum ChekinanaIdolAvatarIdentity {
    static func make(sourceID: String, avatarURL: String?) -> String? {
        let normalizedSourceID = sourceID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        guard !normalizedSourceID.isEmpty,
              let rawURL = avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              ChekinanaNLSchemaValidator.isSafeHTTPURL(rawURL),
              let url = URL(string: rawURL) else {
            return nil
        }
        return "\(normalizedSourceID)|\(url.absoluteString)"
    }
}

struct ChekinanaEventCard: Identifiable, Equatable {
    let id: UUID
    let name: String
    let date: String
    let city: String
    let livehouse: String
    let price: String
    let weiboURL: String
    let ticketURL: String
    let note: String
    let confirmationCode: String?
}

enum ChekinanaIdolCardDetail: Equatable {
    case addCandidate
    case deleteCandidate
    case chekiCount(Int)
}

struct ChekinanaChekiCard: Identifiable, Equatable {
    let id: UUID
    let imageRef: String?
    let createdAt: Date
    let confirmationCode: String?
    let thumbnailImageData: Data?
    let idx: Int?
    let idolNames: [String]
    let eventName: String?
    let eventDateText: String?
    let userAppears: Bool?
    let size: ChekiSize?
    let isFavorite: Bool
    let hasPostedToSNS: Bool
    let note: String?
    let dateAnnotationState: ChekinanaChekiDateAnnotationState

    init(
        id: UUID,
        imageRef: String?,
        createdAt: Date,
        confirmationCode: String?,
        thumbnailImageData: Data?,
        idx: Int? = nil,
        idolNames: [String] = [],
        eventName: String? = nil,
        eventDateText: String? = nil,
        userAppears: Bool? = nil,
        size: ChekiSize? = nil,
        isFavorite: Bool = false,
        hasPostedToSNS: Bool = false,
        note: String? = nil,
        dateAnnotationState: ChekinanaChekiDateAnnotationState = .notRequested
    ) {
        self.id = id
        self.imageRef = imageRef
        self.createdAt = createdAt
        self.confirmationCode = confirmationCode
        self.thumbnailImageData = thumbnailImageData
        self.idx = idx
        self.idolNames = idolNames
        self.eventName = eventName
        self.eventDateText = eventDateText
        self.userAppears = userAppears
        self.size = size
        self.isFavorite = isFavorite
        self.hasPostedToSNS = hasPostedToSNS
        self.note = note
        self.dateAnnotationState = dateAnnotationState
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.imageRef == rhs.imageRef
            && lhs.createdAt == rhs.createdAt
            && lhs.confirmationCode == rhs.confirmationCode
            && lhs.idx == rhs.idx
            && lhs.idolNames == rhs.idolNames
            && lhs.eventName == rhs.eventName
            && lhs.eventDateText == rhs.eventDateText
            && lhs.userAppears == rhs.userAppears
            && lhs.size == rhs.size
            && lhs.isFavorite == rhs.isFavorite
            && lhs.hasPostedToSNS == rhs.hasPostedToSNS
            && lhs.note == rhs.note
            && lhs.dateAnnotationState == rhs.dateAnnotationState
    }
}

struct ChekinanaIdolSection: Identifiable, Equatable {
    let idol: ChekinanaIdolCard
    let chekis: [ChekinanaChekiCard]

    var id: UUID {
        idol.id
    }
}

enum ChekinanaScanSourceOrigin: String, Equatable, Sendable {
    case unspecified
    case library
    case camera
}

struct ChekinanaScanSourceDescriptor: Identifiable, Equatable, Sendable {
    let id: UUID
    let origin: ChekinanaScanSourceOrigin
}

struct ChekinanaScanReviewSourceRegistry: Equatable, Sendable {
    enum CapturedRemoval: Equatable, Sendable {
        case unavailable
        case locked(sourceID: UUID)
        case removed(sourceID: UUID, temporaryIDs: [UUID])
    }

    private(set) var sources: [ChekinanaScanSourceDescriptor]

    init(sources: [ChekinanaScanSourceDescriptor] = []) {
        self.sources = sources
    }

    var hasCapturedPhoto: Bool {
        sources.contains { $0.origin == .camera }
    }

    var sourceIDs: [UUID] {
        sources.map(\.id)
    }

    mutating func append(_ source: ChekinanaScanSourceDescriptor) {
        guard !sources.contains(where: { $0.id == source.id }) else { return }
        sources.append(source)
    }

    mutating func removeLatestCapturedPhoto(
        discardResults: (UUID) -> [UUID]?
    ) -> CapturedRemoval {
        guard let index = sources.lastIndex(where: { $0.origin == .camera }) else {
            return .unavailable
        }
        let sourceID = sources[index].id
        guard let temporaryIDs = discardResults(sourceID) else {
            return .locked(sourceID: sourceID)
        }
        sources.remove(at: index)
        return .removed(sourceID: sourceID, temporaryIDs: temporaryIDs)
    }

    mutating func removeSources(ids: Set<UUID>) {
        sources.removeAll { ids.contains($0.id) }
    }
}

enum ChekinanaScanReviewSavePlan {
    static func selection(
        cardIDs: [UUID],
        containsTemporaryCheki: (UUID) -> Bool
    ) -> String? {
        guard !cardIDs.isEmpty,
              cardIDs.allSatisfy(containsTemporaryCheki) else {
            return nil
        }
        return cardIDs.map(\.uuidString).joined(separator: ",")
    }
}

enum ChekinanaScanReviewCardReconciler {
    static func existing(
        _ cards: [ChekinanaChekiCard],
        containsTemporaryCheki: (UUID) -> Bool
    ) -> [ChekinanaChekiCard] {
        cards.filter { containsTemporaryCheki($0.id) }
    }
}

enum ChekinanaHiddenTemporaryReviewPolicy {
    static func hiddenCardIDs(
        _ cards: [ChekinanaChekiCard],
        hiddenIdolIDs: Set<UUID>,
        idolIDs: (UUID) -> [UUID]?
    ) -> Set<UUID> {
        Set(cards.compactMap { card in
            guard let ids = idolIDs(card.id),
                  !ChekinanaVisibilityPolicy.includesRecord(
                    idolIDs: ids,
                    hiddenIDs: hiddenIdolIDs
                  ) else { return nil }
            return card.id
        })
    }
}

enum ChekinanaScanReviewReconciliationPolicy {
    static func reconcileThenRefresh(
        reconcile: () -> Bool,
        refresh: () -> Bool
    ) -> Bool {
        guard reconcile() else { return false }
        return refresh()
    }
}

enum ChekinanaChekiEventAutoAssociation {
    static func uniqueEventID(
        for date: Date?,
        events: [(id: UUID, date: Date?)],
        calendar: Calendar = .current
    ) -> UUID? {
        guard let date else { return nil }
        let matches = events.filter { candidate in
            guard let candidateDate = candidate.date else { return false }
            return calendar.isDate(candidateDate, inSameDayAs: date)
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}

struct ChekinanaBoundedScanLoadedItem<Value> {
    let originalIndex: Int
    let value: Value
}

struct ChekinanaBoundedScanWindowResult<Output> {
    let sourceRange: Range<Int>
    let loadFailureCount: Int
    let output: Output?
}

@MainActor
enum ChekinanaBoundedScanPipeline {
    static let maximumWindowSize = 2

    static func run<Input, Loaded, Output>(
        inputs: [Input],
        windowSize: Int = maximumWindowSize,
        load: @MainActor (Input, Int) async throws -> Loaded,
        process: @MainActor ([ChekinanaBoundedScanLoadedItem<Loaded>], Range<Int>) async -> Output
    ) async throws -> [ChekinanaBoundedScanWindowResult<Output>] {
        precondition(windowSize > 0)
        var results: [ChekinanaBoundedScanWindowResult<Output>] = []
        for start in stride(from: 0, to: inputs.count, by: windowSize) {
            try Task.checkCancellation()
            let end = min(start + windowSize, inputs.count)
            let range = start..<end
            var loaded: [ChekinanaBoundedScanLoadedItem<Loaded>] = []
            var loadFailureCount = 0
            for originalIndex in range {
                do {
                    loaded.append(ChekinanaBoundedScanLoadedItem(
                        originalIndex: originalIndex,
                        value: try await load(inputs[originalIndex], originalIndex)
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    loadFailureCount += 1
                }
            }
            let output = loaded.isEmpty ? nil : await process(loaded, range)
            results.append(ChekinanaBoundedScanWindowResult(
                sourceRange: range,
                loadFailureCount: loadFailureCount,
                output: output
            ))
            // `loaded` is released before the next window so full-resolution
            // source Data never accumulates across the logical unlimited queue.
        }
        return results
    }
}

struct ChekinanaBoundedScanProgressTranslator {
    private var completedPublishedCount = 0
    private var completedDownloadedCount = 0
    private var completedPreparedCount = 0
    private var windowPublishedCount = 0
    private var windowDownloadedCount = 0
    private var windowPreparedCount = 0
    private var completedImageCount = 0
    private var completedDateCount = 0
    private var completedDateTotal = 0
    private var completedIdolCount = 0
    private var completedIdolTotal = 0
    private var windowImageCount = 0
    private var windowDateCount = 0
    private var windowDateTotal = 0
    private var windowIdolCount = 0
    private var windowIdolTotal = 0

    mutating func translate<Value>(
        _ progress: ChekinanaScanProgress,
        loadedItems: [ChekinanaBoundedScanLoadedItem<Value>],
        totalSourceCount: Int
    ) -> ChekinanaScanProgress {
        precondition(!loadedItems.isEmpty)
        let localIndex = min(max(progress.sourceIndex - 1, 0), loadedItems.count - 1)
        windowPublishedCount = max(windowPublishedCount, progress.publishedResultCount)
        windowDownloadedCount = max(windowDownloadedCount, progress.downloadedResultCount)
        windowPreparedCount = max(windowPreparedCount, progress.preparedResultCount)
        windowImageCount = max(windowImageCount, progress.imageProcessedCount)
        windowDateCount = max(windowDateCount, progress.dateCompletedCount)
        windowDateTotal = max(windowDateTotal, progress.dateTotalCount)
        windowIdolCount = max(windowIdolCount, progress.idolCompletedCount)
        windowIdolTotal = max(windowIdolTotal, progress.idolTotalCount)
        return ChekinanaScanProgress(
            sourceIndex: loadedItems[localIndex].originalIndex + 1,
            sourceCount: totalSourceCount,
            publishedResultCount: completedPublishedCount + windowPublishedCount,
            downloadedResultCount: completedDownloadedCount + windowDownloadedCount,
            preparedResultCount: completedPreparedCount + windowPreparedCount,
            stage: progress.stage,
            imageProcessedCount: completedImageCount + windowImageCount,
            imageProcessTotal: totalSourceCount,
            dateCompletedCount: completedDateCount + windowDateCount,
            dateTotalCount: completedDateTotal + windowDateTotal,
            idolCompletedCount: completedIdolCount + windowIdolCount,
            idolTotalCount: completedIdolTotal + windowIdolTotal
        )
    }

    mutating func completeWindow() {
        completedPublishedCount += windowPublishedCount
        completedDownloadedCount += windowDownloadedCount
        completedPreparedCount += windowPreparedCount
        completedImageCount += windowImageCount
        completedDateCount += windowDateCount
        completedDateTotal += windowDateTotal
        completedIdolCount += windowIdolCount
        completedIdolTotal += windowIdolTotal
        windowPublishedCount = 0
        windowDownloadedCount = 0
        windowPreparedCount = 0
        windowImageCount = 0
        windowDateCount = 0
        windowDateTotal = 0
        windowIdolCount = 0
        windowIdolTotal = 0
    }
}

struct ChekinanaPendingChekiImage: Equatable, Sendable {
    let data: Data
    let filenameExtension: String
    let sourceID: UUID?
    let sourceOrigin: ChekinanaScanSourceOrigin

    init(
        data: Data,
        filenameExtension: String,
        sourceID: UUID? = nil,
        sourceOrigin: ChekinanaScanSourceOrigin = .unspecified
    ) {
        self.data = data
        self.filenameExtension = filenameExtension
        self.sourceID = sourceID
        self.sourceOrigin = sourceOrigin
    }
}

struct ChekinanaAlbumAddChekiRequest: Equatable, Sendable {
    let arguments: [String: String]
}

struct ChekinanaPreparedAlbumCheki: Equatable, Sendable {
    let request: ChekinanaAlbumAddChekiRequest
    let image: ChekinanaPendingChekiImage
    let thumbnailImageData: Data?
}

struct ChekinanaTemporaryScannerMetadata: Equatable, Sendable {
    let matchedIdolID: UUID?
    let userAppears: Bool?

    static let none = ChekinanaTemporaryScannerMetadata(
        matchedIdolID: nil,
        userAppears: nil
    )

    init(matchedIdolID: UUID?, userAppears: Bool? = nil) {
        self.matchedIdolID = matchedIdolID
        self.userAppears = userAppears
    }
}

enum ChekinanaUserAppearsInference {
    static func value(observationCount: Int) -> Bool {
        observationCount >= 2
    }

    static func preserving(existing: Bool?, detected: Bool?) -> Bool? {
        detected ?? existing
    }
}

enum ChekinanaHumanBodyPoseDetector {
    enum DetectionError: Error {
        case invalidImage
    }

    struct PreparedImage {
        let cgImage: CGImage
        let orientation: CGImagePropertyOrientation
    }

    static let maximumInputBytes = 64 * 1_024 * 1_024
    static let maximumDecodedDimension = 2_048

    static func detect(in data: Data) async throws -> Bool {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let count = try observationCount(in: data)
            try Task.checkCancellation()
            return ChekinanaUserAppearsInference.value(
                observationCount: count
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func observationCount(in data: Data) throws -> Int {
        let prepared = try prepareImage(in: data)
        let request = VNDetectHumanBodyPoseRequest()
        request.revision = VNDetectHumanBodyPoseRequest.defaultRevision
        let handler = VNImageRequestHandler(
            cgImage: prepared.cgImage,
            orientation: prepared.orientation,
            options: [:]
        )
        try handler.perform([request])
        return request.results?.count ?? 0
    }

    static func prepareImage(in data: Data) throws -> PreparedImage {
        guard !data.isEmpty,
              data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              ChekinanaImageSourceValidator.accepts(
                source: source,
                maxDimension: maximumDecodedDimension
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw DetectionError.invalidImage
        }
        let rawOrientation = ChekinanaImageSourceValidator.exifOrientation(
            source: source
        ) ?? 1
        let orientation = CGImagePropertyOrientation(
            rawValue: UInt32(rawOrientation)
        ) ?? .up
        let image: CGImage?
        if max(width, height) <= maximumDecodedDimension {
            // Standardized 1200x1908 Cheki stays byte-for-pixel unchanged;
            // Vision receives its original EXIF orientation separately.
            image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false,
            ] as CFDictionary)
        } else {
            // ImageIO performs bounded decode/downsampling without ever
            // materializing an oversized full-resolution UIKit image.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maximumDecodedDimension,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false,
            ] as CFDictionary)
        }
        guard let image,
              image.width > 0,
              image.height > 0,
              max(image.width, image.height) <= maximumDecodedDimension + 1 else {
            throw DetectionError.invalidImage
        }
        return PreparedImage(cgImage: image, orientation: orientation)
    }
}

struct ChekinanaScannerQuadrilateralPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct ChekinanaScannerSourceAnnotation: Equatable, Sendable {
    let previewImageData: Data
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let quadrilateral: [ChekinanaScannerQuadrilateralPoint]

    var isValid: Bool {
        guard !previewImageData.isEmpty,
              sourcePixelWidth > 0,
              sourcePixelHeight > 0,
              quadrilateral.count == 4 else { return false }
        return quadrilateral.allSatisfy { point in
            point.x.isFinite && point.y.isFinite
                && point.x >= 0 && point.y >= 0
                && point.x <= Double(sourcePixelWidth)
                && point.y <= Double(sourcePixelHeight)
        }
    }
}

enum ChekinanaScannerAnnotationPreviewRenderer {
    static func render(
        sourcePreviewData: Data,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint]
    ) -> Data? {
        guard !sourcePreviewData.isEmpty,
              sourcePreviewData.count <= 8 * 1_024 * 1_024,
              sourcePixelWidth > 0,
              sourcePixelHeight > 0,
              quadrilateral.count == 4,
              let source = CGImageSourceCreateWithData(
                sourcePreviewData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              image.width > 0,
              image.height > 0,
              max(image.width, image.height)
                <= ChekinanaLiveScannerUploadPreparer.maximumAnnotationPreviewDimension + 1 else {
            return nil
        }
        let previewAspect = Double(image.width) / Double(image.height)
        let sourceAspect = Double(sourcePixelWidth) / Double(sourcePixelHeight)
        guard abs(previewAspect - sourceAspect) / max(sourceAspect, 0.000_001) <= 0.02 else {
            return nil
        }
        let points = quadrilateral.map { point in
            CGPoint(
                x: CGFloat(point.x / Double(sourcePixelWidth)) * CGFloat(image.width),
                y: CGFloat(point.y / Double(sourcePixelHeight)) * CGFloat(image.height)
            )
        }
        guard points.allSatisfy({ point in
            point.x.isFinite && point.y.isFinite
                && point.x >= 0 && point.y >= 0
                && point.x <= CGFloat(image.width)
                && point.y <= CGFloat(image.height)
        }) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: image.width, height: image.height),
            format: format
        ).image { _ in
            UIImage(cgImage: image).draw(
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            let path = UIBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach(path.addLine)
            path.close()
            path.lineWidth = max(3, CGFloat(max(image.width, image.height)) / 400)
            path.lineJoinStyle = .round
            UIColor.orange.setStroke()
            path.stroke()
        }
        guard let data = rendered.pngData(),
              !data.isEmpty,
              data.count <= 8 * 1_024 * 1_024 else { return nil }
        return data
    }
}

enum ChekinanaAssistantDestination: String, Equatable, Sendable {
    case scan, idols, calendar, events, gallery, settings
    case chekiRokuImport = "chekiroku_import"
}

struct ChekinanaAssistantOpenScanRequest: Equatable, Sendable {
    let recognizeDate: Bool
    let recognizeIdol: Bool
    let includesUnassigned: Bool
    let candidateIdolIDs: [UUID]
    let fixedDate: Date?
    let dateFrom: Date?
    let dateTo: Date?
}

enum ChekinanaAssistantShellAction: Equatable, Sendable {
    case navigate(destination: ChekinanaAssistantDestination, date: Date?)
    case openScan(ChekinanaAssistantOpenScanRequest)
}

enum ChekinanaCommandResponse: Equatable {
    case text(String)
    case confirmationText(String, confirmationCode: String)
    case chekiAdded(Int)
    case chekiScanned(Int, warningCount: Int)
    case chekiScannedCards(Int, warningCount: Int, [ChekinanaChekiCard])
    case pendingChekiCards(String, [ChekinanaChekiCard], consumesSelectedPhotos: Bool)
    case chekiCards([ChekinanaChekiCard])
    case idolCard(ChekinanaIdolCard)
    case idolCards([ChekinanaIdolCard])
    case idolCardsWithNotice([ChekinanaIdolCard], String)
    case idolSections([ChekinanaIdolSection])
    case eventCard(ChekinanaEventCard)
    case eventCards([ChekinanaEventCard])
    case requestAddChekiPhoto(ChekinanaAlbumAddChekiRequest)
    case shellAction(ChekinanaAssistantShellAction, message: String)
    case clearTranscript

    var consumesSelectedPhotos: Bool {
        if case .chekiAdded = self {
            return true
        }

        if case .chekiScanned = self {
            return true
        }

        if case .chekiScannedCards = self {
            return true
        }

        if case .pendingChekiCards(_, _, let consumesSelectedPhotos) = self {
            return consumesSelectedPhotos
        }

        return false
    }
}

private enum ChekinanaCommandCopy {
    private static let prefix = "assistant.executor."

    static func text(_ key: String, fallback: String) -> String {
        ChekinanaProductCopy.text(prefix + key, fallback)
    }

    static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        String(
            format: ChekinanaProductCopy.text(prefix + key, fallback),
            locale: ChekinanaLanguagePreference.displayLocale(),
            arguments: arguments
        )
    }

    static func quantity(
        _ key: String,
        count: Int,
        one: String,
        other: String
    ) -> String {
        ChekinanaProductCopy.quantity(
            prefix + key,
            count: count,
            one: one,
            other: other
        )
    }

    static func error(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        "error: " + String(
            format: ChekinanaProductCopy.text(prefix + key, fallback),
            locale: ChekinanaLanguagePreference.displayLocale(),
            arguments: arguments
        )
    }

    static func errorDetail(_ detail: String) -> String {
        error("error.detail", fallback: "%@", detail)
    }
}

@MainActor
enum ChekinanaConfirmationResponseValidator {
    static var chekiDeletionSuccessText: String {
        ChekinanaCommandCopy.text("cheki.deleted", fallback: "Deleted the Cheki.")
    }

    static func isAddScanChekiSuccess(
        _ response: ChekinanaCommandResponse,
        expectedChekiID: UUID
    ) -> Bool {
        guard case .chekiCards(let cards) = response,
              cards.count == 1,
              cards[0].id == expectedChekiID,
              cards[0].imageRef?.isEmpty == false else {
            return false
        }
        return true
    }

    static func deleteChekiConfirmationCode(
        from response: ChekinanaCommandResponse,
        expectedChekiID: UUID
    ) -> String? {
        guard case .pendingChekiCards(_, let cards, _) = response,
              cards.count == 1,
              cards[0].id == expectedChekiID,
              let code = cards[0].confirmationCode,
              ChekinanaConfirmationLedger.isCode(code) else {
            return nil
        }
        return code
    }

    static func isDeleteChekiSuccess(_ response: ChekinanaCommandResponse) -> Bool {
        response == .text(chekiDeletionSuccessText)
    }

    static func failureDescription(
        for response: ChekinanaCommandResponse,
        fallback: String
    ) -> String {
        guard case .text(let text) = response else { return fallback }
        if text.hasPrefix("error: ") {
            return String(text.dropFirst("error: ".count))
        }
        return text
    }
}

@MainActor
final class ChekinanaConfirmationLedger {
    struct AddChekiPayload {
        let id: UUID
        /// Present only for addscancheki. Album addcheki images never enter
        /// the scan session's temporary-image store.
        let temporaryChekiID: UUID?
        let image: ChekinanaPendingChekiImage
        let thumbnailImageData: Data?
        let idolIDs: [UUID]
        let eventID: UUID?
        let date: Date?
        let userAppears: Bool?
        let size: ChekiSize?
        let isFavorite: Bool
        let hasPostedToSNS: Bool
        let note: String
        let createdAt: Date
        let requestedIdx: Int?
        let existingChekiID: UUID?
        let existingChekiExpectedUpdatedAt: Date?
        let explicitlyEditedFields: Set<TemporaryChekiField>

        init(
            id: UUID,
            temporaryChekiID: UUID?,
            image: ChekinanaPendingChekiImage,
            thumbnailImageData: Data?,
            idolIDs: [UUID],
            eventID: UUID?,
            date: Date?,
            userAppears: Bool?,
            size: ChekiSize?,
            isFavorite: Bool,
            hasPostedToSNS: Bool,
            note: String,
            createdAt: Date,
            requestedIdx: Int?,
            existingChekiID: UUID?,
            existingChekiExpectedUpdatedAt: Date? = nil,
            explicitlyEditedFields: Set<TemporaryChekiField>
        ) {
            self.id = id
            self.temporaryChekiID = temporaryChekiID
            self.image = image
            self.thumbnailImageData = thumbnailImageData
            self.idolIDs = idolIDs
            self.eventID = eventID
            self.date = date
            self.userAppears = userAppears
            self.size = size
            self.isFavorite = isFavorite
            self.hasPostedToSNS = hasPostedToSNS
            self.note = note
            self.createdAt = createdAt
            self.requestedIdx = requestedIdx
            self.existingChekiID = existingChekiID
            self.existingChekiExpectedUpdatedAt = existingChekiExpectedUpdatedAt
            self.explicitlyEditedFields = explicitlyEditedFields
        }
    }

    struct AddEventPayload {
        let name: String
        let date: Date?
        let city: String?
        let livehouse: String?
        let avatarURL: String?
        let price: String?
        let weiboURL: URL?
        let ticketURL: URL?
        let note: String

        init(
            name: String,
            date: Date?,
            city: String? = nil,
            livehouse: String? = nil,
            avatarURL: String? = nil,
            price: String? = nil,
            weiboURL: URL? = nil,
            ticketURL: URL? = nil,
            note: String = ""
        ) {
            self.name = name
            self.date = date
            self.city = city
            self.livehouse = livehouse
            self.avatarURL = avatarURL
            self.price = price
            self.weiboURL = weiboURL
            self.ticketURL = ticketURL
            self.note = note
        }
    }

    struct EditEventPayload {
        let eventID: UUID
        let expectedUpdatedAt: Date
        let name: String
        let date: Date?
        let city: String?
        let livehouse: String?
        let price: String?
        let weiboURL: URL?
        let ticketURL: URL?
        let note: String
    }

    struct DeleteEventPayload {
        let eventID: UUID
        let expectedUpdatedAt: Date
    }

    struct EditChekiPayload {
        let chekiID: UUID
        let expectedUpdatedAt: Date
        let idolIDs: [UUID]
        let eventID: UUID?
        let date: Date?
        let userAppears: Bool?
        let size: ChekiSize?
        let isFavorite: Bool
        let hasPostedToSNS: Bool
        let note: String
    }

    struct EditIdolPayload {
        let idolID: UUID
        let expectedUpdatedAt: Date
        let values: [String: String]
        let clearFields: Set<String>
    }

    struct DeleteIdolPayload {
        let idolID: UUID
        let expectedUpdatedAt: Date
    }

    struct FavoriteIdolPayload {
        let idolID: UUID
        let expectedUpdatedAt: Date
        let favorite: Bool
    }

    struct DeleteChekiPayload {
        let chekiID: UUID
        let expectedUpdatedAt: Date?
        let phase: DeleteChekiPhase

        init(
            chekiID: UUID,
            expectedUpdatedAt: Date? = nil,
            phase: DeleteChekiPhase
        ) {
            self.chekiID = chekiID
            self.expectedUpdatedAt = expectedUpdatedAt
            self.phase = phase
        }
    }

    enum RecordKind: String { case cheki, shame, douga }
    enum RecordMutation { case add, edit(UUID), delete(UUID) }
    struct RecordPayload {
        let kind: RecordKind
        let mutation: RecordMutation
        let expectedFingerprint: String?
        let idolIDs: [UUID]
        let eventID: UUID?
        let date: Date?
        let idx: Int?
        let note: String
        let userAppears: Bool?
        let favorite: Bool
        let size: ChekiSize?
    }

    enum DeleteChekiPhase {
        case deleteModel
        case restoreThenDelete(originalURL: URL, quarantineURL: URL)
        case cleanupQuarantine(URL)
    }

    enum TemporaryChekiField: Hashable {
        case idols
        case date
        case event
        case userAppears
        case size
        case favorite
        case posted
        case note
        case idx
    }

    struct TemporaryCheki {
        let id: UUID
        var image: ChekinanaPendingChekiImage
        var thumbnailImageData: Data?
        let sourceID: UUID?
        let sourceOrigin: ChekinanaScanSourceOrigin
        var dateAnnotationState: ChekinanaChekiDateAnnotationState
        let sourceAnnotation: ChekinanaScannerSourceAnnotation?
        var imageRotationQuarterTurns: Int
        var idolIDs: [UUID]
        var date: Date?
        var eventID: UUID?
        var eventWasAutoMatched: Bool
        var idx: Int?
        var existingChekiID: UUID?
        var existingSelectionIsManual: Bool
        var explicitlyEditedFields: Set<TemporaryChekiField>
        let inferredUserAppears: Bool?
        var userAppears: Bool?
        var size: ChekiSize?
        var isFavorite: Bool
        var hasPostedToSNS: Bool
        var note: String
        let createdAt: Date
    }

    struct TemporaryChekiChoice: Identifiable, Equatable {
        let id: UUID
        let createdAt: Date
    }

    struct IdolCandidateChoice {
        let token: String
        let candidate: ChekinanaPreparedIdolCandidate
    }

    enum Action {
        case addIdol(ChekinanaPreparedIdolCandidate)
        case editIdol(EditIdolPayload)
        case deleteIdol(DeleteIdolPayload)
        case favoriteIdol(FavoriteIdolPayload)
        case addEvent(AddEventPayload)
        case editEvent(EditEventPayload)
        case deleteEvent(DeleteEventPayload)
        case addCheki(AddChekiPayload)
        case editCheki(EditChekiPayload)
        case deleteCheki(DeleteChekiPayload)
        case mutateRecord(RecordPayload)
        case downloadCheki(chekiID: UUID, imageURL: URL)
    }

    struct Entry {
        let code: String
        let batchID: UUID?
        let action: Action
    }

    fileprivate struct TemporaryChekiBatchReservationItem: Hashable, Sendable {
        let code: String
        let id: UUID
        let existingTargetID: UUID?
    }

    struct TemporaryChekiBatchReservation: Hashable, Sendable {
        fileprivate let token: UUID
        fileprivate let expected: [TemporaryChekiBatchReservationItem]
    }

    enum TemporaryChekiBatchFinalization: Equatable, Sendable {
        case finalized
        case alreadyFinalized
        case needsRecovery
    }

    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private var expiredCodes = Set<String>()
    private var temporaryChekis: [UUID: TemporaryCheki] = [:]
    private var reviewProtectedTemporaryChekiIDs = Set<UUID>()
    private var temporaryBatchReservations: [UUID: [TemporaryChekiBatchReservationItem]] = [:]
    private var reservedTemporaryConfirmationCodes = Set<String>()
    private var reservedTemporaryExistingChekiTargetIDs = Set<UUID>()
    private var finalizedTemporaryBatchReservationTokens = Set<UUID>()
    private var committedTemporaryBatchRecoveries: [UUID: [TemporaryChekiBatchReservationItem]] = [:]
    private var idolCandidates: [String: ChekinanaPreparedIdolCandidate] = [:]
    private var idolQueryGeneration: UInt64 = 0
    private var implicitConfirmationStartIndex = 0

    private let maximumTemporaryChekiBytes: Int
    private let temporaryChekiTTL: TimeInterval

    init(
        maximumTemporaryChekiBytes: Int = 100 * 1_024 * 1_024,
        temporaryChekiTTL: TimeInterval = 30 * 60
    ) {
        precondition(maximumTemporaryChekiBytes > 0)
        precondition(temporaryChekiTTL > 0)
        self.maximumTemporaryChekiBytes = maximumTemporaryChekiBytes
        self.temporaryChekiTTL = temporaryChekiTTL
    }

    func insert(_ action: Action, batchID: UUID? = nil) -> String {
        var code: String
        repeat {
            code = String(UUID().uuidString.prefix(8)).lowercased()
        } while entries[code] != nil || expiredCodes.contains(code)

        entries[code] = Entry(code: code, batchID: batchID, action: action)
        insertionOrder.append(code)
        expiredCodes.remove(code)
        return code
    }

    func beginIdolQuery() -> UInt64 {
        idolQueryGeneration &+= 1
        idolCandidates.removeAll()
        return idolQueryGeneration
    }

    func publishIdolConfirmation(
        _ candidate: ChekinanaPreparedIdolCandidate,
        generation: UInt64
    ) -> String? {
        guard generation == idolQueryGeneration,
              let candidate = try? normalizedPreparedIdolCandidate(candidate) else {
            return nil
        }
        return insert(.addIdol(candidate))
    }

    func replaceIdolCandidates(
        _ candidates: [ChekinanaPreparedIdolCandidate],
        generation: UInt64
    ) -> [IdolCandidateChoice]? {
        guard generation == idolQueryGeneration else { return nil }
        let normalized = candidates.compactMap { candidate in
            try? normalizedPreparedIdolCandidate(candidate)
        }
        idolCandidates.removeAll()
        return normalized.map { candidate in
            var token: String
            repeat { token = UUID().uuidString.lowercased() } while idolCandidates[token] != nil
            idolCandidates[token] = candidate
            return IdolCandidateChoice(token: token, candidate: candidate)
        }
    }

    private func normalizedPreparedIdolCandidate(
        _ prepared: ChekinanaPreparedIdolCandidate
    ) throws -> ChekinanaPreparedIdolCandidate {
        ChekinanaPreparedIdolCandidate(
            candidate: try ChekinanaBirthdayValue.normalizedCatalogueCandidate(
                prepared.candidate
            ),
            avatarThumbnailData: prepared.avatarThumbnailData,
            avatarIdentity: prepared.avatarIdentity,
            avatarThumbnailImage: prepared.avatarThumbnailImage
        )
    }

    func consumeIdolCandidate(_ rawToken: String) -> ChekinanaPreparedIdolCandidate? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return idolCandidates.removeValue(forKey: token)
    }

    func idolCandidate(_ rawToken: String) -> ChekinanaPreparedIdolCandidate? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return idolCandidates[token]
    }

    func invalidateIdolCandidates() {
        idolQueryGeneration &+= 1
        idolCandidates.removeAll()
    }

    func entry(for rawCode: String) -> Entry? {
        entries[Self.normalizedCode(rawCode)]
    }

    func isValidTemporaryChekiBatch(_ completedEntries: [Entry]) -> Bool {
        let expected = completedEntries.compactMap { entry -> (String, UUID)? in
            guard case .addCheki(let payload) = entry.action,
                  let temporaryID = payload.temporaryChekiID else { return nil }
            return (entry.code, temporaryID)
        }
        return expected.count == completedEntries.count
            && expected.allSatisfy({ code, temporaryID in
                  guard let current = entries[code],
                        case .addCheki(let payload) = current.action else { return false }
                  return payload.temporaryChekiID == temporaryID
                      && temporaryChekis[temporaryID] != nil
              })
    }

    func reserveTemporaryChekiBatch(
        _ completedEntries: [Entry]
    ) -> TemporaryChekiBatchReservation? {
        guard isValidTemporaryChekiBatch(completedEntries) else { return nil }
        let expected = completedEntries.compactMap { entry -> TemporaryChekiBatchReservationItem? in
            guard case .addCheki(let payload) = entry.action,
                  let temporaryID = payload.temporaryChekiID else { return nil }
            return .init(
                code: entry.code,
                id: temporaryID,
                existingTargetID: payload.existingChekiID
            )
        }
        let codes = Set(expected.map(\.code))
        let existingTargetIDs = Set(expected.compactMap(\.existingTargetID))
        guard codes.isDisjoint(with: reservedTemporaryConfirmationCodes),
              existingTargetIDs.isDisjoint(
                with: reservedTemporaryExistingChekiTargetIDs
              ) else {
            return nil
        }
        let reservation = TemporaryChekiBatchReservation(
            token: UUID(),
            expected: expected
        )
        temporaryBatchReservations[reservation.token] = expected
        reservedTemporaryConfirmationCodes.formUnion(codes)
        reservedTemporaryExistingChekiTargetIDs.formUnion(existingTargetIDs)
        return reservation
    }

    @discardableResult
    func releaseTemporaryChekiBatchReservation(
        _ reservation: TemporaryChekiBatchReservation
    ) -> Bool {
        guard let expected = temporaryBatchReservations.removeValue(
            forKey: reservation.token
        ) else { return false }
        reservedTemporaryConfirmationCodes.subtract(expected.map(\.code))
        reservedTemporaryExistingChekiTargetIDs.subtract(
            expected.compactMap(\.existingTargetID)
        )
        return true
    }

    func finalizeTemporaryChekiBatchReservation(
        _ reservation: TemporaryChekiBatchReservation,
        simulateInvariantFailure: Bool = false
    ) -> TemporaryChekiBatchFinalization {
        if finalizedTemporaryBatchReservationTokens.contains(reservation.token) {
            return .alreadyFinalized
        }
        let stored = temporaryBatchReservations.removeValue(forKey: reservation.token)
        let expected = stored ?? reservation.expected
        let requiresRecovery = simulateInvariantFailure || stored != reservation.expected
        reservedTemporaryConfirmationCodes.subtract(expected.map(\.code))
        reservedTemporaryExistingChekiTargetIDs.subtract(
            expected.compactMap(\.existingTargetID)
        )
        for item in expected {
            entries.removeValue(forKey: item.code)
            expiredCodes.insert(item.code)
            removeTemporaryChekiValue(item.id)
        }
        if requiresRecovery {
            // The database is already committed at this boundary. Retire the
            // retryable confirmation and retain a compact recovery record;
            // callers must never delete the now-referenced managed files.
            committedTemporaryBatchRecoveries[reservation.token] = expected
            return .needsRecovery
        }
        finalizedTemporaryBatchReservationTokens.insert(reservation.token)
        return .finalized
    }

    func hasCommittedTemporaryBatchRecovery(
        _ reservation: TemporaryChekiBatchReservation
    ) -> Bool {
        committedTemporaryBatchRecoveries[reservation.token] != nil
    }

    var committedTemporaryBatchRecoveryCount: Int {
        committedTemporaryBatchRecoveries.count
    }

    func isTemporaryChekiBatchReserved(_ rawCode: String) -> Bool {
        reservedTemporaryConfirmationCodes.contains(Self.normalizedCode(rawCode))
    }

    func isTemporaryExistingChekiTargetReserved(_ id: UUID) -> Bool {
        reservedTemporaryExistingChekiTargetIDs.contains(id)
    }

    var activeConfirmationCodes: Set<String> {
        Set(entries.keys)
    }

    func updateAddIdolCandidate(_ resolved: ChekinanaPreparedIdolCandidate, for rawCode: String) -> Bool {
        let code = Self.normalizedCode(rawCode)
        guard let entry = entries[code], case .addIdol = entry.action else {
            return false
        }
        entries[code] = Entry(code: entry.code, batchID: entry.batchID, action: .addIdol(resolved))
        // Keep the historical occurrence in place so a clear/reset boundary
        // remains stable, and append a new occurrence for this visible edit.
        insertionOrder.append(code)
        return true
    }

    enum ImplicitConfirmation {
        case none
        case code(String)
        case ambiguousAddIdol
    }

    func implicitConfirmation() -> ImplicitConfirmation {
        guard implicitConfirmationStartIndex < insertionOrder.count,
              let code = insertionOrder[implicitConfirmationStartIndex...].reversed().first(where: { entries[$0] != nil }),
              let entry = entries[code] else {
            return .none
        }
        if let batchID = entry.batchID,
           entries.values.filter({ $0.batchID == batchID }).count > 1,
           case .addIdol = entry.action {
            return .ambiguousAddIdol
        }
        return .code(code)
    }

    func resetImplicitConfirmationAnchor() {
        implicitConfirmationStartIndex = insertionOrder.count
    }

    func updateDeleteChekiPayload(_ payload: DeleteChekiPayload, for rawCode: String) {
        let code = Self.normalizedCode(rawCode)
        guard let entry = entries[code], case .deleteCheki = entry.action else { return }
        entries[code] = Entry(code: entry.code, batchID: entry.batchID, action: .deleteCheki(payload))
    }

    struct TemporaryChekiInsertion {
        let inserted: [TemporaryCheki]
        let evictedCount: Int
    }

    func insertTemporaryChekis(
        _ images: [ChekinanaPendingChekiImage],
        thumbnailImageData: [Data?],
        dateAnnotationStates: [ChekinanaChekiDateAnnotationState]? = nil,
        scannerMetadata: [ChekinanaTemporaryScannerMetadata]? = nil,
        sourceAnnotations: [ChekinanaScannerSourceAnnotation?]? = nil,
        dates: [Date?]? = nil,
        eventIDs: [UUID?]? = nil,
        eventAutoMatched: [Bool]? = nil,
        sizes: [ChekiSize?]? = nil
    ) throws -> TemporaryChekiInsertion {
        precondition(images.count == thumbnailImageData.count)
        let annotationStates = dateAnnotationStates
            ?? Array(repeating: .notRequested, count: images.count)
        let metadata = scannerMetadata
            ?? Array(repeating: .none, count: images.count)
        let resolvedSourceAnnotations = (
            sourceAnnotations ?? Array(repeating: nil, count: images.count)
        ).map { annotation in
            annotation?.isValid == true ? annotation : nil
        }
        let resolvedDates = dates ?? Array(repeating: nil, count: images.count)
        let resolvedEventIDs = eventIDs ?? Array(repeating: nil, count: images.count)
        let resolvedEventAutoMatched = eventAutoMatched
            ?? Array(repeating: false, count: images.count)
        // Existing scanner callers historically produce Mini unless they
        // supply a reliable result size. Direct Import always supplies its
        // explicit inference array, whose elements may intentionally be nil.
        let resolvedSizes = sizes ?? Array(repeating: .mini, count: images.count)
        precondition(images.count == annotationStates.count)
        precondition(images.count == metadata.count)
        precondition(images.count == resolvedSourceAnnotations.count)
        precondition(images.count == resolvedDates.count)
        precondition(images.count == resolvedEventIDs.count)
        precondition(images.count == resolvedEventAutoMatched.count)
        precondition(images.count == resolvedSizes.count)
        let initialIDs = Set(temporaryChekis.keys)
        let initialBytes = temporaryChekiBytes
        let incomingBytes = images.indices.reduce(0) { partial, index in
            let imageBytes = images[index].data.count
            let annotationBytes = resolvedSourceAnnotations[index]?.previewImageData.count ?? 0
            let itemBytes = imageBytes.addingReportingOverflow(annotationBytes)
            guard !itemBytes.overflow,
                  !partial.addingReportingOverflow(itemBytes.partialValue).overflow else {
                return Int.max
            }
            return partial + itemBytes.partialValue
        }
        guard incomingBytes <= maximumTemporaryChekiBytes else {
            throw ChekinanaTemporaryChekiError.capacityExceeded(
                bytes: temporaryChekiBytes
            )
        }

        // Plan the complete batch against a snapshot before mutating anything.
        // A rejected batch must leave every existing temporary image intact.
        let now = Date()
        let protectedIDs = evictionProtectedTemporaryChekiIDs
        let removable = temporaryChekis.values.filter { !protectedIDs.contains($0.id) }
        let expired = removable.filter {
            now.timeIntervalSince($0.createdAt) >= temporaryChekiTTL
        }
        let evictionCandidates = removable
            .filter { now.timeIntervalSince($0.createdAt) < temporaryChekiTTL }
            .sorted { $0.createdAt < $1.createdAt }
        var evictionIDs = expired.map(\.id)
        var plannedBytes = temporaryChekiBytes - expired.reduce(0) {
            $0 + temporaryStorageBytes($1)
        }
        var candidateIndex = 0
        while plannedBytes + incomingBytes > maximumTemporaryChekiBytes {
            guard candidateIndex < evictionCandidates.count else {
                assert(Set(temporaryChekis.keys) == initialIDs && temporaryChekiBytes == initialBytes)
                throw ChekinanaTemporaryChekiError.capacityExceeded(
                    bytes: temporaryChekiBytes
                )
            }
            let candidate = evictionCandidates[candidateIndex]
            evictionIDs.append(candidate.id)
            plannedBytes -= temporaryStorageBytes(candidate)
            candidateIndex += 1
        }

        for id in evictionIDs {
            removeTemporaryChekiValue(id)
        }

        let inserted = images.indices.map { index in
            let image = images[index]
            var id: UUID
            repeat { id = UUID() } while temporaryChekis[id] != nil
            let value = TemporaryCheki(
                id: id,
                image: image,
                thumbnailImageData: thumbnailImageData[index],
                sourceID: image.sourceID,
                sourceOrigin: image.sourceOrigin,
                dateAnnotationState: annotationStates[index],
                sourceAnnotation: resolvedSourceAnnotations[index],
                imageRotationQuarterTurns: 0,
                idolIDs: metadata[index].matchedIdolID.map { [$0] } ?? [],
                date: resolvedDates[index],
                eventID: resolvedEventIDs[index],
                eventWasAutoMatched: resolvedEventAutoMatched[index],
                idx: nil,
                existingChekiID: nil,
                existingSelectionIsManual: false,
                explicitlyEditedFields: [],
                inferredUserAppears: metadata[index].userAppears,
                userAppears: metadata[index].userAppears,
                size: resolvedSizes[index],
                isFavorite: false,
                hasPostedToSNS: false,
                note: "",
                createdAt: Date()
            )
            temporaryChekis[id] = value
            return value
        }
        assert(temporaryChekiBytes == plannedBytes + incomingBytes)
        assert(temporaryChekiBytes <= maximumTemporaryChekiBytes)
        assert(inserted.allSatisfy { temporaryChekis[$0.id] != nil })
        return TemporaryChekiInsertion(inserted: inserted, evictedCount: evictionIDs.count)
    }

    func resolveTemporaryCheki(_ rawToken: String) throws -> TemporaryCheki {
        _ = pruneExpiredTemporaryChekis()
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = temporaryChekis.values.filter { $0.id.uuidString.lowercased().hasPrefix(token) }
        guard !matches.isEmpty else { throw ChekinanaTemporaryChekiError.notFound(rawToken) }
        guard matches.count == 1, let value = matches.first else {
            throw ChekinanaTemporaryChekiError.ambiguous(rawToken)
        }
        return value
    }

    func resolveTemporaryChekis(_ rawSelection: String) throws -> [TemporaryCheki] {
        _ = pruneExpiredTemporaryChekis()
        let selection = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if selection.lowercased() == "all" {
            let protected = pendingTemporaryChekiIDs
            let values = temporaryChekis.values
                .filter { !protected.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
            guard !values.isEmpty else {
                throw ChekinanaTemporaryChekiError.notFound(selection)
            }
            return values
        }

        let tokens = selection.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty }) else {
            throw ChekinanaTemporaryChekiError.notFound(selection)
        }
        var seen = Set<UUID>()
        return try tokens.map { token in
            let value = try resolveTemporaryCheki(token)
            guard seen.insert(value.id).inserted else {
                throw ChekinanaTemporaryChekiError.ambiguous(token)
            }
            guard !pendingTemporaryChekiIDs.contains(value.id) else {
                throw ChekinanaTemporaryChekiError.referencedByPendingConfirmation(token)
            }
            return value
        }
    }

    func protectTemporaryChekisForReview(_ ids: [UUID]) {
        reviewProtectedTemporaryChekiIDs.formUnion(
            ids.filter { temporaryChekis[$0] != nil }
        )
    }

    func isTemporaryChekiProtectedForReview(_ id: UUID) -> Bool {
        reviewProtectedTemporaryChekiIDs.contains(id)
    }

    func consumeTemporaryCheki(_ id: UUID) {
        removeTemporaryChekiValue(id)
    }

    @discardableResult
    func discardTemporaryCheki(id: UUID) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              removeTemporaryChekiValue(id) != nil else {
            return false
        }
        return true
    }

    /// Atomically removes every unlocked temporary result produced by one
    /// source image. A pending confirmation rejects the whole operation so a
    /// captured source is never only partially deleted.
    func discardTemporaryChekis(sourceID: UUID) -> [UUID]? {
        let matchingIDs = temporaryChekis.values
            .filter { $0.sourceID == sourceID }
            .map(\.id)
        guard Set(matchingIDs).isDisjoint(with: pendingTemporaryChekiIDs) else {
            return nil
        }
        for id in matchingIDs {
            removeTemporaryChekiValue(id)
        }
        return matchingIDs
    }

    func containsTemporaryCheki(_ id: UUID) -> Bool {
        temporaryChekis[id] != nil
    }

    func temporaryCheki(_ id: UUID) -> TemporaryCheki? {
        _ = pruneExpiredTemporaryChekis()
        return temporaryChekis[id]
    }

    @discardableResult
    func replaceTemporaryChekiIdols(id: UUID, idolIDs: [UUID]) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var temporary = temporaryChekis[id] else {
            return false
        }
        temporary.idolIDs = Array(Set(idolIDs))
        temporary.explicitlyEditedFields.insert(.idols)
        temporaryChekis[id] = temporary
        return true
    }

    @discardableResult
    func updateTemporaryChekiDate(id: UUID, date: Date?) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var temporary = temporaryChekis[id] else {
            return false
        }
        temporary.date = date
        temporary.eventWasAutoMatched = false
        temporary.explicitlyEditedFields.insert(.date)
        temporaryChekis[id] = temporary
        return true
    }

    /// Applies a quick date edit and, unless the user explicitly selected or
    /// cleared Event, replaces the prior automatic match in the same ledger
    /// mutation. This prevents a card from retaining an Event from its old day.
    @discardableResult
    func updateTemporaryChekiDate(
        id: UUID,
        date: Date?,
        automaticEventID: UUID?
    ) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var temporary = temporaryChekis[id] else {
            return false
        }
        temporary.date = date
        temporary.explicitlyEditedFields.insert(.date)
        if !temporary.explicitlyEditedFields.contains(.event) {
            temporary.eventID = automaticEventID
            temporary.eventWasAutoMatched = automaticEventID != nil
        }
        temporaryChekis[id] = temporary
        return true
    }

    func replaceTemporaryChekiImage(
        id: UUID,
        image: ChekinanaPendingChekiImage,
        thumbnailImageData: Data?,
        dateAnnotationState: ChekinanaChekiDateAnnotationState
    ) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var value = temporaryChekis[id] else { return false }
        let replacementBytes = temporaryChekiBytes - value.image.data.count + image.data.count
        guard replacementBytes <= maximumTemporaryChekiBytes else { return false }
        value.image = image
        value.thumbnailImageData = thumbnailImageData
        value.dateAnnotationState = dateAnnotationState
        value.imageRotationQuarterTurns = (value.imageRotationQuarterTurns + 1) % 4
        temporaryChekis[id] = value
        return true
    }

    @discardableResult
    func toggleTemporaryChekiFavorite(id: UUID) -> Bool? {
        guard !pendingTemporaryChekiIDs.contains(id),
              var temporary = temporaryChekis[id] else {
            return nil
        }
        temporary.isFavorite.toggle()
        temporary.explicitlyEditedFields.insert(.favorite)
        temporaryChekis[id] = temporary
        return temporary.isFavorite
    }

    @discardableResult
    func toggleTemporaryChekiUserAppears(id: UUID) -> Bool? {
        guard !pendingTemporaryChekiIDs.contains(id),
              var temporary = temporaryChekis[id],
              let current = temporary.userAppears else {
            return nil
        }
        temporary.userAppears = !current
        temporary.explicitlyEditedFields.insert(.userAppears)
        temporaryChekis[id] = temporary
        return temporary.userAppears
    }

    @discardableResult
    func updateTemporaryCheki(
        id: UUID,
        idolIDs: [UUID],
        date: Date?,
        eventID: UUID?,
        userAppears: Bool?,
        size: ChekiSize?,
        isFavorite: Bool,
        hasPostedToSNS: Bool,
        note: String,
        idx: Int? = nil,
        idxWasManuallyEdited: Bool = false,
        existingChekiID: UUID? = nil,
        existingSelectionIsManual: Bool = false,
        eventWasExplicitlyEdited: Bool = true,
        eventWasAutoMatched: Bool = false
    ) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var temporary = temporaryChekis[id] else {
            return false
        }
        let normalizedIdolIDs = Array(Set(idolIDs))
        if Set(temporary.idolIDs) != Set(normalizedIdolIDs) {
            temporary.explicitlyEditedFields.insert(.idols)
        }
        if temporary.date != date { temporary.explicitlyEditedFields.insert(.date) }
        if eventWasExplicitlyEdited { temporary.explicitlyEditedFields.insert(.event) }
        if temporary.userAppears != userAppears { temporary.explicitlyEditedFields.insert(.userAppears) }
        if temporary.size != size { temporary.explicitlyEditedFields.insert(.size) }
        if temporary.isFavorite != isFavorite { temporary.explicitlyEditedFields.insert(.favorite) }
        if temporary.hasPostedToSNS != hasPostedToSNS { temporary.explicitlyEditedFields.insert(.posted) }
        if temporary.note != note { temporary.explicitlyEditedFields.insert(.note) }
        if idxWasManuallyEdited { temporary.explicitlyEditedFields.insert(.idx) }
        temporary.idolIDs = normalizedIdolIDs
        temporary.date = date
        temporary.eventID = eventID
        temporary.eventWasAutoMatched = eventWasAutoMatched
        temporary.userAppears = userAppears
        temporary.size = size
        temporary.isFavorite = isFavorite
        temporary.hasPostedToSNS = hasPostedToSNS
        temporary.note = note
        temporary.idx = idx
        temporary.existingChekiID = existingChekiID
        temporary.existingSelectionIsManual = existingSelectionIsManual
        temporaryChekis[id] = temporary
        return true
    }

    @discardableResult
    func setTemporaryExistingCheki(
        id: UUID,
        existingChekiID: UUID?,
        selectionIsManual: Bool,
        inheritedIdx: Int?,
        inheritedUserAppears: Bool? = nil
    ) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var temporary = temporaryChekis[id] else { return false }
        temporary.existingChekiID = existingChekiID
        temporary.existingSelectionIsManual = selectionIsManual
        if !temporary.explicitlyEditedFields.contains(.idx) {
            temporary.idx = inheritedIdx
        }
        if !temporary.explicitlyEditedFields.contains(.userAppears) {
            temporary.userAppears = inheritedUserAppears
                ?? temporary.inferredUserAppears
        }
        temporaryChekis[id] = temporary
        return true
    }

    func availableTemporaryChekiChoices() -> [TemporaryChekiChoice] {
        _ = pruneExpiredTemporaryChekis()
        let protectedIDs = pendingTemporaryChekiIDs
        return temporaryChekis.values
            .filter { !protectedIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
            .map { TemporaryChekiChoice(id: $0.id, createdAt: $0.createdAt) }
    }

    func discardTemporaryCheki(_ rawToken: String) throws -> String {
        _ = pruneExpiredTemporaryChekis()
        let value = try resolveTemporaryCheki(rawToken)
        guard !pendingTemporaryChekiIDs.contains(value.id) else {
            throw ChekinanaTemporaryChekiError.referencedByPendingConfirmation(rawToken)
        }
        removeTemporaryChekiValue(value.id)
        return String(value.id.uuidString.prefix(8)).lowercased()
    }

    func discardAllUnreferencedTemporaryChekis() -> (discarded: Int, retained: Int) {
        _ = pruneExpiredTemporaryChekis()
        let protectedIDs = pendingTemporaryChekiIDs
        let removableIDs = temporaryChekis.keys.filter { !protectedIDs.contains($0) }
        for id in removableIDs {
            removeTemporaryChekiValue(id)
        }
        return (removableIDs.count, temporaryChekis.count)
    }

    private var pendingTemporaryChekiIDs: Set<UUID> {
        Set(entries.values.compactMap { entry in
            guard case .addCheki(let payload) = entry.action else { return nil }
            return payload.temporaryChekiID
        })
    }

    private var evictionProtectedTemporaryChekiIDs: Set<UUID> {
        pendingTemporaryChekiIDs.union(reviewProtectedTemporaryChekiIDs)
    }

    private var temporaryChekiBytes: Int {
        temporaryChekis.values.reduce(0) { $0 + temporaryStorageBytes($1) }
    }

    private func temporaryStorageBytes(_ value: TemporaryCheki) -> Int {
        value.image.data.count + (value.sourceAnnotation?.previewImageData.count ?? 0)
    }

    @discardableResult
    private func pruneExpiredTemporaryChekis(now: Date = Date()) -> Int {
        let protectedIDs = evictionProtectedTemporaryChekiIDs
        let expiredIDs: [UUID] = temporaryChekis.values.compactMap { value -> UUID? in
            guard !protectedIDs.contains(value.id),
                  now.timeIntervalSince(value.createdAt) >= temporaryChekiTTL else { return nil }
            return value.id
        }
        for id in expiredIDs {
            removeTemporaryChekiValue(id)
        }
        return expiredIDs.count
    }

    @discardableResult
    private func removeTemporaryChekiValue(_ id: UUID) -> TemporaryCheki? {
        reviewProtectedTemporaryChekiIDs.remove(id)
        return temporaryChekis.removeValue(forKey: id)
    }

    func removeAfterSuccess(_ entry: Entry) {
        if let batchID = entry.batchID {
            let codes = entries.values.filter { $0.batchID == batchID }.map(\.code)
            for code in codes {
                entries.removeValue(forKey: code)
                expiredCodes.insert(code)
            }
        } else {
            entries.removeValue(forKey: entry.code)
            expiredCodes.insert(entry.code)
        }
    }

    func cancel(_ rawCode: String) -> Bool {
        let code = Self.normalizedCode(rawCode)
        guard !reservedTemporaryConfirmationCodes.contains(code),
              let entry = entries[code], !entry.requiresRecoveryConfirmation else {
            return false
        }
        entries.removeValue(forKey: code)
        expiredCodes.insert(code)
        return true
    }

    func cancellationRequiresRecovery(_ rawCode: String) -> Bool {
        entries[Self.normalizedCode(rawCode)]?.requiresRecoveryConfirmation == true
    }

    func cancelAll() -> (cancelled: Int, retainedForRecovery: Int) {
        invalidateIdolCandidates()
        let cancellableCodes = entries.values
            .filter {
                !$0.requiresRecoveryConfirmation
                    && !reservedTemporaryConfirmationCodes.contains($0.code)
            }
            .map(\.code)
        for code in cancellableCodes {
            entries.removeValue(forKey: code)
        }
        expiredCodes.formUnion(cancellableCodes)
        return (cancellableCodes.count, entries.count)
    }

    @discardableResult
    func cancelTemporaryChekiConfirmations(_ rawCodes: [String]) -> Int {
        let normalizedCodes = Set(rawCodes.map(Self.normalizedCode))
        var cancelledCodes = Set<String>()
        for code in normalizedCodes {
            guard let entry = entries[code],
                  !reservedTemporaryConfirmationCodes.contains(code),
                  case .addCheki(let payload) = entry.action,
                  payload.temporaryChekiID != nil else {
                continue
            }
            entries.removeValue(forKey: code)
            cancelledCodes.insert(code)
        }
        expiredCodes.formUnion(cancelledCodes)
        return cancelledCodes.count
    }

    func isExpired(_ rawCode: String) -> Bool {
        expiredCodes.contains(Self.normalizedCode(rawCode))
    }

    static func normalizedCode(_ rawCode: String) -> String {
        rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isCode(_ value: String) -> Bool {
        let normalized = normalizedCode(value)
        return normalized.count == 8 && normalized.allSatisfy { $0.isHexDigit }
    }
}

private extension ChekinanaConfirmationLedger.Entry {
    var requiresRecoveryConfirmation: Bool {
        guard case .deleteCheki(let payload) = action else { return false }
        switch payload.phase {
        case .deleteModel:
            return false
        case .restoreThenDelete, .cleanupQuarantine:
            return true
        }
    }
}

enum ChekinanaMonthDayDateInferrer {
    static func date(
        from text: String,
        within bounds: ChekinanaScannerDateBounds,
        calendar _: Calendar
    ) -> Date? {
        var carrierCalendar = Calendar(identifier: .gregorian)
        carrierCalendar.locale = Locale(identifier: "en_US_POSIX")
        carrierCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Scanner bounds already carry canonical Y/M/D values. Read those
        // components directly so an end-bound MM.DD keeps the same year.
        guard let candidate = mostRecentDate(
            from: text,
            relativeTo: bounds.to,
            calendar: carrierCalendar
        ),
        bounds.contains(candidate) else {
            return nil
        }
        return candidate
    }

    static func mostRecentDate(
        from text: String,
        relativeTo now: Date,
        calendar sourceCalendar: Calendar
    ) -> Date? {
        guard ChekinanaChekiDateAnnotation.isValid(
            text: text,
            precision: .monthDay
        ) else {
            return nil
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]) else {
            return nil
        }

        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.locale = Locale(identifier: "en_US_POSIX")
        localCalendar.timeZone = sourceCalendar.timeZone
        let today = localCalendar.startOfDay(for: now)
        guard let currentYear = localCalendar.dateComponents(
            [.year],
            from: today
        ).year else {
            return nil
        }

        for yearOffset in 0...400 {
            let year = currentYear - yearOffset
            var components = DateComponents()
            components.calendar = localCalendar
            components.timeZone = localCalendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            guard let candidate = localCalendar.date(from: components) else {
                continue
            }
            let resolved = localCalendar.dateComponents(
                [.year, .month, .day],
                from: candidate
            )
            guard resolved.year == year,
                  resolved.month == month,
                  resolved.day == day,
                  localCalendar.compare(
                    candidate,
                    to: today,
                    toGranularity: .day
                  ) != .orderedDescending else {
                continue
            }

            return ChekinanaDateOnly.canonicalDate(
                from: candidate,
                displayedIn: localCalendar
            )
        }
        return nil
    }
}

struct ChekinanaScannerTaskProgress: Sendable, Equatable {
    let phase: String?
    let publishedResultCount: Int
    let downloadedResultCount: Int
    let expectedPolaroids: Int?
    let extractionComplete: Bool
}

struct ChekinanaScanProgress: Sendable, Equatable {
    enum Stage: Sendable, Equatable {
        case backend(
            phase: String?,
            publishedForSource: Int,
            downloadedForSource: Int,
            expectedForSource: Int?
        )
        case preparingResult(index: Int, count: Int, recognizesIdol: Bool)
        case generatingPreview
    }

    let sourceIndex: Int
    let sourceCount: Int
    let publishedResultCount: Int
    let downloadedResultCount: Int
    let preparedResultCount: Int
    let stage: Stage
    let imageProcessedCount: Int
    let imageProcessTotal: Int
    let dateCompletedCount: Int
    let dateTotalCount: Int
    let idolCompletedCount: Int
    let idolTotalCount: Int

    init(
        sourceIndex: Int,
        sourceCount: Int,
        publishedResultCount: Int,
        downloadedResultCount: Int,
        preparedResultCount: Int,
        stage: Stage,
        imageProcessedCount: Int = 0,
        imageProcessTotal: Int? = nil,
        dateCompletedCount: Int = 0,
        dateTotalCount: Int = 0,
        idolCompletedCount: Int = 0,
        idolTotalCount: Int = 0
    ) {
        self.sourceIndex = sourceIndex
        self.sourceCount = sourceCount
        self.publishedResultCount = publishedResultCount
        self.downloadedResultCount = downloadedResultCount
        self.preparedResultCount = preparedResultCount
        self.stage = stage
        self.imageProcessedCount = imageProcessedCount
        self.imageProcessTotal = imageProcessTotal ?? sourceCount
        self.dateCompletedCount = dateCompletedCount
        self.dateTotalCount = dateTotalCount
        self.idolCompletedCount = idolCompletedCount
        self.idolTotalCount = idolTotalCount
    }
}

actor ChekinanaDirectRecognitionGate {
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
        isAcquired = false
    }
}

actor ChekinanaDirectDateRequestGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int = 8) {
        precondition(limit > 0)
        self.limit = limit
    }

    func perform<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // The permit may already have transferred. `perform` checks
            // cancellation and its defer returns that permit.
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            precondition(activeCount > 0)
            activeCount -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

actor ChekinanaDirectCommitGate {
    private var nextIndex = 0
    private var skipped = Set<Int>()

    func acquire(index: Int) async throws {
        while index != nextIndex {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
    }

    func release(index: Int) {
        guard index == nextIndex else { return }
        nextIndex += 1
        while skipped.remove(nextIndex) != nil {
            nextIndex += 1
        }
    }

    func skip(index: Int) {
        guard index >= nextIndex else { return }
        if index == nextIndex {
            release(index: index)
        } else {
            skipped.insert(index)
        }
    }
}

private final class ChekinanaScanProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true

    func performIfActive(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        operation()
    }

    func invalidate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }
}

enum ChekinanaTemporaryChekiBatchStage: String, Sendable {
    case preparingImages
    case savingRecords
    case finalizing

    var title: String {
        switch self {
        case .preparingImages: "Preparing images"
        case .savingRecords: "Saving records"
        case .finalizing: "Finalizing"
        }
    }
}

struct ChekinanaTemporaryChekiBatchProgress: Equatable, Sendable {
    let stage: ChekinanaTemporaryChekiBatchStage
    let completed: Int
    let total: Int
}

private struct ChekinanaBatchChekiSnapshot: Sendable {
    let id: UUID
    let idolIDs: [UUID]
    let date: Date?
    let idx: Int?
    let imageRef: String?
}

private struct ChekinanaBatchIndexKey: Hashable {
    let group: ChekinanaChekiGroupKey
    let idx: Int
}

private enum ChekinanaBatchIndexStrategy {
    case none
    case preserveExisting
    case automatic
    case explicit(Int?)
}

/// Reads only immutable scalar planning data on its private SwiftData executor.
/// Managed models never cross back to the Review's MainActor context.
@ModelActor
private actor ChekinanaBatchSnapshotActor {
    func chekiSnapshots() throws -> [ChekinanaBatchChekiSnapshot] {
        try modelContext.fetch(FetchDescriptor<Cheki>()).map { cheki in
            ChekinanaBatchChekiSnapshot(
                id: cheki.id,
                idolIDs: cheki.idols.map(\.id),
                date: cheki.date,
                idx: cheki.idx,
                imageRef: cheki.imageRef
            )
        }
    }
}

@MainActor
struct ChekinanaCommandExecutor {
    typealias ScannerProcess = (
        ChekinanaPendingChekiImage,
        ChekinanaScannerOptions
    ) async throws -> ChekinanaScannerProcessResult
    typealias ScannerStatusObserver = @MainActor (
        ChekinanaScannerTaskProgress
    ) -> Void
    typealias ScannerResultObserver = @MainActor (
        _ resultIndex: Int,
        _ image: ChekinanaScannerResultImage
    ) -> Void
    typealias ScannerProcessWithProgress = (
        ChekinanaPendingChekiImage,
        ChekinanaScannerOptions,
        ScannerStatusObserver?,
        ScannerResultObserver?
    ) async throws -> ChekinanaScannerProcessResult
    typealias ScanProgressObserver = (ChekinanaScanProgress) -> Void
    typealias ScannerTaskObserver = @MainActor (_ taskID: String, _ isActive: Bool) -> Void
    typealias PatternEncode = (Data) async throws -> [Float]
    typealias UserAppearsDetect = @Sendable (Data) async throws -> Bool
    typealias IdolSearch = @MainActor @Sendable (String) async throws -> [ChekinanaEnrichedIdol]
    typealias IdolAvatarPrepare = @Sendable (ChekinanaEnrichedIdol) async throws -> Data?
    typealias BatchSaveProgressObserver = @MainActor @Sendable (
        ChekinanaTemporaryChekiBatchProgress
    ) -> Void
    typealias BatchBeforeLiveIndexValidation = @MainActor @Sendable () throws -> Void

    private enum IdolRecognitionOutcome: Sendable {
        case notRequested
        case matched(UUID?)
        case failed
        case cancelled
    }

    private enum DateRecognitionOutcome: Sendable {
        case notRequested
        case completed(ChekinanaChekiDateAnnotationState)
        case cancelled
    }

    private enum UserAppearsRecognitionOutcome: Sendable {
        case completed(Bool)
        case unavailable
        case cancelled
    }

    private enum RecognitionProgressEvent: Sendable {
        case date(DateRecognitionOutcome)
        case idol(IdolRecognitionOutcome)
        case userAppears(UserAppearsRecognitionOutcome)
    }

    private struct RecognitionTaskKey: Hashable, Sendable {
        let sourceIndex: Int
        let resultIndex: Int
    }

    private struct RecognitionResolution: Sendable {
        let dateState: ChekinanaChekiDateAnnotationState
        let matchedIdolID: UUID?
        let userAppears: Bool?
        let warningCount: Int
        let isCancelled: Bool
    }

    private final class RecognitionTaskRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [
            RecognitionTaskKey: Task<RecognitionResolution, Never>
        ] = [:]
        private var isCancelled = false

        func task(for key: RecognitionTaskKey) -> Task<RecognitionResolution, Never>? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func insert(
            _ task: Task<RecognitionResolution, Never>,
            for key: RecognitionTaskKey
        ) {
            lock.lock()
            storage[key] = task
            let shouldCancel = isCancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func snapshot() -> [Task<RecognitionResolution, Never>] {
            lock.lock()
            defer { lock.unlock() }
            return Array(storage.values)
        }

        func cancelAll() {
            lock.lock()
            isCancelled = true
            let tasks = Array(storage.values)
            lock.unlock()
            tasks.forEach { $0.cancel() }
        }
    }

    private struct SearchedIdolCandidate: Sendable {
        let query: String
        let candidate: ChekinanaEnrichedIdol
    }

    private enum IdolSearchOutcome: Sendable {
        case success(Int, String, [ChekinanaEnrichedIdol])
        case failed(Int, String)
        case cancelled(Int, String)
    }

    private enum PreparedIdolCandidateOutcome: Sendable {
        case completed(Int, ChekinanaPreparedIdolCandidate, usedPlaceholder: Bool)
        case timedOut
    }

    private final class ScanProgressState {
        var preparedResultCount = 0
        var imageProcessedCount = 0
        var dateCompletedCount = 0
        var dateTotalCount = 0
        var idolCompletedCount = 0
        var idolTotalCount = 0
        private var publishedBySource: [Int: Int] = [:]
        private var downloadedBySource: [Int: Int] = [:]
        private var discoveredResultsBySource: [Int: Set<Int>] = [:]
        private var finishedImageSources = Set<Int>()

        var totalPublishedCount: Int {
            publishedBySource.values.reduce(0, +)
        }

        var totalDownloadedCount: Int {
            downloadedBySource.values.reduce(0, +)
        }

        func beginSource(_ sourceIndex: Int) {
            publishedBySource[sourceIndex] = 0
            downloadedBySource[sourceIndex] = 0
        }

        func update(
            sourceIndex: Int,
            progress: ChekinanaScannerTaskProgress
        ) {
            publishedBySource[sourceIndex] = max(
                publishedBySource[sourceIndex] ?? 0,
                progress.publishedResultCount
            )
            downloadedBySource[sourceIndex] = max(
                downloadedBySource[sourceIndex] ?? 0,
                progress.downloadedResultCount
            )
        }

        func recordFallbackResultCount(_ count: Int, sourceIndex: Int) {
            publishedBySource[sourceIndex] = max(
                publishedBySource[sourceIndex] ?? 0,
                count
            )
            downloadedBySource[sourceIndex] = max(
                downloadedBySource[sourceIndex] ?? 0,
                count
            )
        }

        func discoverResult(
            sourceIndex: Int,
            resultIndex: Int,
            options: ChekinanaScannerOptions
        ) {
            guard discoveredResultsBySource[sourceIndex, default: []]
                .insert(resultIndex).inserted else { return }
            if options.dateRecognitionEnabled {
                dateTotalCount += 1
                if options.usesFixedDate { dateCompletedCount += 1 }
            }
            if options.idolRecognitionCandidates != nil {
                idolTotalCount += 1
                if options.directIdolCandidateID != nil {
                    idolCompletedCount += 1
                }
            }
        }

        func finishImageSource(
            sourceIndex: Int,
            resultCount: Int,
            options: ChekinanaScannerOptions
        ) {
            guard finishedImageSources.insert(sourceIndex).inserted else { return }
            imageProcessedCount += 1
            for resultIndex in 0..<resultCount {
                discoverResult(
                    sourceIndex: sourceIndex,
                    resultIndex: resultIndex,
                    options: options
                )
            }
        }

        func publishedCount(for sourceIndex: Int) -> Int {
            publishedBySource[sourceIndex] ?? 0
        }

        func downloadedCount(for sourceIndex: Int) -> Int {
            downloadedBySource[sourceIndex] ?? 0
        }
    }

    private enum SourceScanOutcome: Sendable {
        case success(ChekinanaScannerProcessResult)
        case failed
        case cancelled
    }

    let modelContext: ModelContext
    let confirmationLedger: ChekinanaConfirmationLedger
    private let scannerProcessWithProgress: ScannerProcessWithProgress
    private let scanProgressObserver: ScanProgressObserver?
    private let patternEncode: PatternEncode
    private let userAppearsDetect: UserAppearsDetect
    private let bodyPoseLimiter: ChekinanaBodyPoseLimiter
    private let idolSearch: IdolSearch
    private let idolAvatarPrepare: IdolAvatarPrepare
    private let idolAvatarBatchTimeoutNanoseconds: UInt64
    private let now: () -> Date
    private let calendar: Calendar
    private let directRecognitionGate: ChekinanaDirectRecognitionGate?
    private let directDateRequestGate: ChekinanaDirectDateRequestGate?
    private let directCommitGate: ChekinanaDirectCommitGate?
    private let directCommitIndex: Int?
    private let batchImagePreparationLimiter: ChekinanaRemoteRequestLimiter
    private let batchSaveProgressObserver: BatchSaveProgressObserver?
    private let simulateBatchFinalizeInvariantFailure: Bool
    private let batchBeforeLiveIndexValidation: BatchBeforeLiveIndexValidation?

    init(
        modelContext: ModelContext,
        confirmationLedger: ChekinanaConfirmationLedger,
        scannerProcess: ScannerProcess? = nil,
        patternEncode: PatternEncode? = nil,
        userAppearsDetect: UserAppearsDetect? = nil,
        bodyPoseLimiter: ChekinanaBodyPoseLimiter = .init(),
        idolSearch: @escaping IdolSearch = { name in
            try await ChekinanaIdolEnrichmentClient().search(for: name)
        },
        idolAvatarPrepare: IdolAvatarPrepare? = nil,
        idolAvatarBatchTimeoutNanoseconds: UInt64 = 15_000_000_000,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        scanProgressObserver: ScanProgressObserver? = nil,
        scannerTaskObserver: ScannerTaskObserver? = nil,
        directRecognitionGate: ChekinanaDirectRecognitionGate? = nil,
        directDateRequestGate: ChekinanaDirectDateRequestGate? = nil,
        directCommitGate: ChekinanaDirectCommitGate? = nil,
        directCommitIndex: Int? = nil,
        batchImagePreparationLimiter: ChekinanaRemoteRequestLimiter = .init(limit: 4),
        batchSaveProgressObserver: BatchSaveProgressObserver? = nil,
        simulateBatchFinalizeInvariantFailure: Bool = false,
        batchBeforeLiveIndexValidation: BatchBeforeLiveIndexValidation? = nil,
        usesLocalDirectProcessing: Bool = false
    ) {
        self.modelContext = modelContext
        self.confirmationLedger = confirmationLedger
        if let scannerProcess {
            scannerProcessWithProgress = { image, options, _, _ in
                try await scannerProcess(image, options)
            }
        } else {
            scannerProcessWithProgress = { image, options, progressObserver, resultObserver in
                if usesLocalDirectProcessing && options.directInputEnabled {
                    return try await ChekinanaLocalImportChekiProcessor.process(
                        image,
                        options: options
                    )
                }
                return try await ChekinanaScannerClient().process(
                    image,
                    options: options,
                    progressObserver: progressObserver,
                    resultObserver: resultObserver,
                    taskIDObserver: scannerTaskObserver
                )
            }
        }
        self.scanProgressObserver = scanProgressObserver
        self.directRecognitionGate = directRecognitionGate
        self.directDateRequestGate = directDateRequestGate
        self.directCommitGate = directCommitGate
        self.directCommitIndex = directCommitIndex
        self.batchImagePreparationLimiter = batchImagePreparationLimiter
        self.batchSaveProgressObserver = batchSaveProgressObserver
        self.simulateBatchFinalizeInvariantFailure = simulateBatchFinalizeInvariantFailure
        self.batchBeforeLiveIndexValidation = batchBeforeLiveIndexValidation
        self.patternEncode = patternEncode ?? { imageData in
            try await ChekinanaPatternEncoder.shared.encode(imageData)
        }
        self.userAppearsDetect = userAppearsDetect ?? { imageData in
            try await ChekinanaHumanBodyPoseDetector.detect(in: imageData)
        }
        self.bodyPoseLimiter = bodyPoseLimiter
        self.idolSearch = idolSearch
        self.idolAvatarPrepare = idolAvatarPrepare ?? { candidate in
            try await ChekinanaCatalogueAvatarThumbnailCache.shared.thumbnailData(
                for: candidate
            )
        }
        self.idolAvatarBatchTimeoutNanoseconds = max(
            1_000_000,
            idolAvatarBatchTimeoutNanoseconds
        )
        self.now = now
        self.calendar = calendar
    }

    func execute(_ input: String, pendingChekiImages: [ChekinanaPendingChekiImage] = []) async -> ChekinanaCommandResponse {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let simpleTokens = trimmedInput.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        if simpleTokens.count == 1, ChekinanaConfirmationLedger.isCode(simpleTokens[0]) {
            return await confirm(simpleTokens[0])
        }

        if simpleTokens.count == 2, simpleTokens[0].lowercased() == "confirm" {
            return await confirm(simpleTokens[1])
        }

        if simpleTokens.count == 1, simpleTokens[0].lowercased() == "confirm" {
            switch confirmationLedger.implicitConfirmation() {
            case .none:
                return .text(ChekinanaCommandCopy.error(
                    "confirmation.none",
                    fallback: "There is no pending operation to confirm."
                ))
            case .ambiguousAddIdol:
                return .text(ChekinanaCommandCopy.error(
                    "confirmation.ambiguous_idol",
                    fallback: "The latest Idol search returned multiple candidates; choose one before confirming."
                ))
            case .code(let code):
                return await confirm(code)
            }
        }

        if simpleTokens.count == 2, simpleTokens[0].lowercased() == "cancel" {
            if simpleTokens[1].lowercased() == "all" {
                let result = confirmationLedger.cancelAll()
                if result.retainedForRecovery > 0 {
                    return .text(ChekinanaCommandCopy.format(
                        "confirmation.cancelled_all_recovery",
                        fallback: "Cancelled pending confirmations: %1$lld; retained for required file recovery or cleanup: %2$lld. Retry Confirm to finish safely.",
                        Int64(result.cancelled),
                        Int64(result.retainedForRecovery)
                    ))
                }
                return .text(ChekinanaCommandCopy.format(
                    "confirmation.cancelled_all",
                    fallback: "Cancelled pending confirmations: %lld.",
                    Int64(result.cancelled)
                ))
            }

            guard ChekinanaConfirmationLedger.isCode(simpleTokens[1]) else {
                return .text(invalidConfirmationCodeFormatText)
            }

            if confirmationLedger.cancel(simpleTokens[1]) {
                return .text(ChekinanaCommandCopy.format(
                    "confirmation.cancelled",
                    fallback: "Cancelled confirmation: %@.",
                    simpleTokens[1].lowercased()
                ))
            }

            if confirmationLedger.cancellationRequiresRecovery(simpleTokens[1]) {
                return .text(ChekinanaCommandCopy.error(
                    "confirmation.cancel_recovery_pending",
                    fallback: "This Cheki deletion cannot be cancelled while managed image recovery or cleanup is pending. Retry Confirm."
                ))
            }

            return invalidConfirmationCode(simpleTokens[1])
        }

        if let first = simpleTokens.first?.lowercased(), ["confirm", "cancel"].contains(first) {
            return invalidUsage(["confirm [8_hex_code]", "cancel <8_hex_code>", "cancel all"])
        }

        let command: ChekinanaParsedCommand

        do {
            command = try ChekinanaCommandParser.parse(input)
        } catch {
            if isCommand(input, named: "listidol"), let usage = commandUsages["listidol"] {
                return invalidUsage(usage)
            }

            if isCommand(input, named: "listcheki"), let usage = commandUsages["listcheki"] {
                return invalidUsage(usage)
            }

            if isCommand(input, named: "downloadcheki"), let usage = commandUsages["downloadcheki"] {
                return invalidUsage(usage)
            }

            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }

        return await execute(command, pendingChekiImages: pendingChekiImages)
    }

    /// Executes an App-created typed command without parsing any user text.
    func execute(_ command: ChekinanaParsedCommand, pendingChekiImages: [ChekinanaPendingChekiImage] = []) async -> ChekinanaCommandResponse {

        if command.name == "help" {
            return .text(helpText)
        }

        if command.name == "clear" {
            guard command.target == nil, command.arguments.isEmpty else {
                return invalidUsage(commandUsages["clear"] ?? ["clear"])
            }
            confirmationLedger.resetImplicitConfirmationAnchor()
            confirmationLedger.invalidateIdolCandidates()
            return .clearTranscript
        }

        guard let usage = commandUsages[command.name] else {
            return .text(ChekinanaCommandCopy.format(
                "command.unknown",
                fallback: "Unknown command: %@\n\n%@",
                command.name,
                helpText
            ))
        }

        if command.name == "addidol" {
            return await addIdol(command, usage: usage)
        }

        if command.name == "selectidolcandidate" {
            return selectIdolCandidate(command, usage: usage)
        }

        if command.name == "confirmidolcandidate" {
            return await confirmIdolCandidate(command, usage: usage)
        }

        if command.name == "listidol" {
            return listIdol(command, usage: usage)
        }

        if command.name == "editidol" {
            return editIdol(command, usage: usage)
        }


        if command.name == "deleteidol" {
            return deleteIdol(command, usage: usage)
        }

        if command.name == "favoriteidol" {
            return favoriteIdol(command, usage: usage)
        }

        if command.name == "showidol" {
            return showIdol(command, usage: usage)
        }

        if command.name == "addevent" {
            return addEvent(command, usage: usage)
        }

        if command.name == "listevent" {
            return listEvent(command, usage: usage)
        }

        if command.name == "showevent" {
            return showEvent(command, usage: usage)
        }

        if command.name == "editevent" {
            return editEvent(command, usage: usage)
        }

        if command.name == "deleteevent" {
            return deleteEvent(command, usage: usage)
        }

        if command.name == "addcheki" {
            return await addCheki(command, usage: usage)
        }

        if command.name == "addscancheki" {
            return addScanCheki(command, usage: usage)
        }

        if command.name == "deletecheki" {
            return deleteCheki(command, usage: usage)
        }

        if command.name == "listcheki" {
            return listCheki(command, usage: usage)
        }

        if command.name == "showcheki" {
            return showCheki(command, usage: usage)
        }

        if command.name == "editcheki" {
            return editCheki(command, usage: usage)
        }

        if command.name == "downloadcheki" {
            return await downloadCheki(command, usage: usage)
        }

        if command.name == "scancheki" {
            return await scanCheki(command, usage: usage, pendingImages: pendingChekiImages)
        }

        if command.name == "discardcheki" {
            return discardTemporaryCheki(command, usage: usage)
        }

        if ["listrecord", "showrecord", "addrecord", "editrecord", "deleterecord"].contains(command.name) {
            return recordCommand(command, usage: usage)
        }

        if command.name == "navigate" {
            return navigate(command, usage: usage)
        }

        if command.name == "openscan" {
            return openScan(command, usage: usage)
        }

        if command.name == "downloadtemporarycheki" {
            return await downloadTemporaryCheki(command, usage: usage)
        }

        return .text(ChekinanaCommandCopy.format(
            "command.not_implemented",
            fallback: "Command not implemented: %1$@\n\nUsage:\n%2$@",
            command.name,
            usage.joined(separator: "\n")
        ))
    }

    func prepareEventCandidate(_ rawFields: ChekinanaEventCandidateFields) -> ChekinanaCommandResponse {
        let fields = ChekinanaEventCandidateFields(
            name: rawFields.name.trimmingCharacters(in: .whitespacesAndNewlines),
            date: rawFields.date.trimmingCharacters(in: .whitespacesAndNewlines),
            city: rawFields.city.trimmingCharacters(in: .whitespacesAndNewlines),
            livehouse: rawFields.livehouse.trimmingCharacters(in: .whitespacesAndNewlines),
            address: rawFields.address.trimmingCharacters(in: .whitespacesAndNewlines),
            price: rawFields.price.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarURL: rawFields.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines),
            weiboURL: rawFields.weiboURL.trimmingCharacters(in: .whitespacesAndNewlines),
            ticketURL: rawFields.ticketURL.trimmingCharacters(in: .whitespacesAndNewlines),
            note: ""
        )
        let blockers = ChekinanaEventCandidateValidator.blockers(for: fields)
        guard blockers.isEmpty else {
            return .text(ChekinanaCommandCopy.error(
                "event.candidate_not_ready",
                fallback: "The Event candidate is not ready: %@",
                blockers.map(\.message).joined(separator: " ")
            ))
        }
        do {
            let date = fields.date.isEmpty ? nil : try parseCalendarDate(fields.date)
            let weiboURL = fields.weiboURL.isEmpty ? nil : URL(string: fields.weiboURL)
            if !fields.weiboURL.isEmpty, weiboURL == nil {
                throw ChekinanaEventError.invalidURL
            }
            let ticketURL = fields.ticketURL.isEmpty ? nil : URL(string: fields.ticketURL)
            if !fields.ticketURL.isEmpty, ticketURL == nil {
                throw ChekinanaEventError.invalidURL
            }
            try ensureEventIsNotDuplicate(name: fields.name, date: date, url: weiboURL)
            let code = confirmationLedger.insert(.addEvent(.init(
                name: fields.name,
                date: date,
                city: optionalNonempty(fields.city),
                livehouse: optionalNonempty(fields.livehouse),
                avatarURL: optionalNonempty(fields.avatarURL),
                price: optionalNonempty(fields.price),
                weiboURL: weiboURL,
                ticketURL: ticketURL,
                note: fields.note
            )))
            return .eventCard(eventCard(fields, confirmationCode: code))
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func isCommand(_ input: String, named name: String) -> Bool {
        guard let commandName = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first else {
            return false
        }

        return commandName.lowercased() == name
    }

    private func invalidUsage(_ usage: [String]) -> ChekinanaCommandResponse {
        .text(ChekinanaCommandCopy.error(
            "command.invalid_usage",
            fallback: "Invalid usage.\n\nUsage:\n%@",
            usage.joined(separator: "\n")
        ))
    }

    private var invalidConfirmationCodeFormatText: String {
        ChekinanaCommandCopy.error(
            "confirmation.code_format",
            fallback: "Confirmation code must be 8 lowercase hexadecimal characters."
        )
    }

    private func invalidConfirmationCode(_ code: String) -> ChekinanaCommandResponse {
        if confirmationLedger.isExpired(code) {
            return .text(ChekinanaCommandCopy.error(
                "confirmation.expired",
                fallback: "Confirmation code expired: %@.",
                ChekinanaConfirmationLedger.normalizedCode(code)
            ))
        }
        return .text(ChekinanaCommandCopy.error(
            "confirmation.invalid_or_expired",
            fallback: "Invalid or expired confirmation code: %@.",
            ChekinanaConfirmationLedger.normalizedCode(code)
        ))
    }

    private func confirm(_ rawCode: String) async -> ChekinanaCommandResponse {
        guard ChekinanaConfirmationLedger.isCode(rawCode) else {
            return .text(invalidConfirmationCodeFormatText)
        }

        guard let entry = confirmationLedger.entry(for: rawCode) else {
            return invalidConfirmationCode(rawCode)
        }
        guard !confirmationLedger.isTemporaryChekiBatchReserved(rawCode) else {
            return .text(ChekinanaCommandCopy.error(
                "cheki.batch_already_saving",
                fallback: "This temporary Cheki is already being saved in a batch."
            ))
        }

        do {
            let response: ChekinanaCommandResponse

            switch entry.action {
            case .addIdol(let resolved):
                if try hasIdol(sourceId: resolved.candidate.sourceId) {
                    // This candidate is no longer retryable. Expire its whole
                    // result batch so a second pending code cannot bypass the
                    // stable catalogue-ID check.
                    confirmationLedger.removeAfterSuccess(entry)
                    return .text(ChekinanaCommandCopy.error(
                        "idol.already_added",
                        fallback: "Idol already added: %@.",
                        resolved.candidate.sourceId
                    ))
                }
                let idol = try await persistCatalogueIdol(resolved)
                response = .idolCard(idolCard(idol, preparedCandidate: resolved))

            case .editIdol(let payload):
                let idol = try refetchIdolByID(payload.idolID)
                guard idol.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaNLClientError.invalidSchema
                }
                if payload.clearFields.contains("avatar") {
                    let previousAvatarRef = idol.avatarImageRef
                    let result = try ChekinanaIdolPersistence.save(
                        idol,
                        inserting: false,
                        previousAvatarRef: previousAvatarRef,
                        stagedAvatar: nil,
                        in: modelContext
                    ) { target in
                        applyIdolEdit(
                            payload.values,
                            clearFields: payload.clearFields,
                            to: target
                        )
                        target.updatedAt = Date()
                    }
                    let card = idolCard(idol)
                    if result.pendingAvatarCleanup != nil {
                        response = .idolCardsWithNotice(
                            [card],
                            ChekinanaCommandCopy.text(
                                "idol.avatar_cleanup_pending",
                                fallback: "The Idol was updated, but its previous managed avatar still needs cleanup."
                            )
                        )
                    } else {
                        response = .idolCard(card)
                    }
                } else {
                    applyIdolEdit(
                        payload.values,
                        clearFields: payload.clearFields,
                        to: idol
                    )
                    idol.updatedAt = Date()
                    do {
                        try modelContext.save()
                    } catch {
                        modelContext.rollback()
                        throw error
                    }
                    response = .idolCard(idolCard(idol))
                }

            case .deleteIdol(let payload):
                let idol = try refetchIdolByID(payload.idolID)
                guard idol.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaNLClientError.invalidSchema
                }
                let recordCount = try associatedRecordCount(for: idol.id)
                guard recordCount == 0 else {
                    throw ChekinanaDeleteError.idolHasChekis(recordCount)
                }
                modelContext.delete(idol)
                do { try modelContext.save() } catch {
                    modelContext.rollback()
                    throw error
                }
                response = .text(ChekinanaCommandCopy.text(
                    "idol.deleted",
                    fallback: "Deleted the Idol."
                ))

            case .favoriteIdol(let payload):
                let idol = try refetchIdolByID(payload.idolID)
                guard idol.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaNLClientError.invalidSchema
                }
                idol.isFavorite = payload.favorite
                idol.updatedAt = Date()
                do { try modelContext.save() } catch {
                    modelContext.rollback()
                    throw error
                }
                response = .idolCard(idolCard(idol))

            case .addEvent(let payload):
                try ensureEventIsNotDuplicate(
                    name: payload.name,
                    date: payload.date,
                    url: payload.weiboURL
                )
                let event = Event(
                    name: payload.name,
                    date: payload.date,
                    city: payload.city,
                    livehouse: payload.livehouse,
                    price: payload.price,
                    weiboURL: payload.weiboURL,
                    ticketURL: payload.ticketURL,
                    note: payload.note
                )
                if let avatarURL = payload.avatarURL {
                    event.avatarImageRef = try await ChekinanaEventAvatarStore.downloadAndSave(
                        avatarURL,
                        eventID: event.id
                    )
                }
                modelContext.insert(event)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.delete(event)
                    modelContext.rollback()
                    ChekinanaEventAvatarStore.remove(event.avatarImageRef)
                    throw error
                }
                ChekinanaEventMediaJournal.clearPending(
                    [event.avatarImageRef].compactMap { $0 }
                )
                response = .eventCard(eventCard(event))

            case .editEvent(let payload):
                let event = try refetchEventByRequiredID(payload.eventID)
                guard event.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaEditConflictError.staleEvent(entry.code)
                }
                event.name = payload.name
                event.date = payload.date
                event.city = payload.city
                event.livehouse = payload.livehouse
                event.price = payload.price
                event.weiboURL = payload.weiboURL
                event.ticketURL = payload.ticketURL
                event.note = payload.note
                event.updatedAt = Date()
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    throw error
                }
                response = .eventCard(eventCard(event))

            case .deleteEvent(let payload):
                let event = try refetchEventByRequiredID(payload.eventID)
                guard event.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaNLClientError.invalidSchema
                }
                let recordCount = event.chekis.count
                guard recordCount == 0 else {
                    throw ChekinanaDeleteError.eventHasChekis(recordCount)
                }
                try ChekinanaEventPersistence.delete(event, from: modelContext)
                response = .text(ChekinanaCommandCopy.text(
                    "event.deleted",
                    fallback: "Deleted the Event."
                ))

            case .addCheki(let payload):
                if let temporaryChekiID = payload.temporaryChekiID,
                   !confirmationLedger.containsTemporaryCheki(temporaryChekiID) {
                    throw ChekinanaTemporaryChekiError.alreadyConsumed(
                        String(temporaryChekiID.uuidString.prefix(8)).lowercased()
                    )
                }
                let idols = try refetchIdolsByIDs(payload.idolIDs)
                let explicitEvent = payload.explicitlyEditedFields.contains(.event)
                let existingEvent = try payload.existingChekiID
                    .map { try refetchChekiByID($0) }?.event
                let event: Event?
                if explicitEvent {
                    event = try refetchEventByID(payload.eventID)
                } else if let existingEvent {
                    event = existingEvent
                } else {
                    event = try uniqueEvent(for: payload.date)
                }
                try validateChekiAssociations(
                    idols: idols,
                    event: event,
                    eventDate: payload.date
                )
                if payload.existingChekiID != nil {
                    guard let reservation = confirmationLedger
                        .reserveTemporaryChekiBatch([entry]) else {
                        throw ChekinanaAddChekiError.duplicateCheki(payload.id.uuidString)
                    }
                    do {
                        response = try await attachImageToExistingCheki(
                            payload: payload,
                            idols: idols,
                            event: event
                        )
                        _ = confirmationLedger.finalizeTemporaryChekiBatchReservation(
                            reservation
                        )
                    } catch {
                        confirmationLedger.releaseTemporaryChekiBatchReservation(
                            reservation
                        )
                        throw error
                    }
                } else {
                    let idx: Int?
                    if payload.explicitlyEditedFields.contains(.idx) {
                        let group = ChekinanaChekiGroupKey(
                            idolIDs: idols.map(\.id),
                            date: payload.date
                        )
                        if payload.requestedIdx != nil, group == nil {
                            throw ChekinanaAddChekiError.indexOverflow
                        }
                        if let requestedIdx = payload.requestedIdx, let group {
                            let collision = try modelContext.fetch(FetchDescriptor<Cheki>())
                                .contains {
                                    ChekinanaChekiGroupKey(
                                        idolIDs: $0.idols.map(\.id),
                                        date: $0.date
                                    ) == group && $0.idx == requestedIdx
                                }
                            guard !collision else {
                                throw ChekinanaAddChekiError.duplicateIndex(requestedIdx)
                            }
                        }
                        idx = payload.requestedIdx
                    } else {
                        idx = try nextChekiIndex(
                            idolIDs: idols.map(\.id),
                            eventID: event?.id,
                            eventDate: payload.date,
                            excludingChekiID: nil
                        )
                    }
                    response = try await persistCheki(
                        id: payload.id,
                        image: payload.image,
                        thumbnailImageData: payload.thumbnailImageData,
                        idols: idols,
                        event: event,
                        eventDate: payload.date,
                        idx: idx,
                        userAppears: payload.userAppears,
                        size: payload.size,
                        isFavorite: payload.isFavorite,
                        hasPostedToSNS: payload.hasPostedToSNS,
                        note: payload.note,
                        createdAt: payload.createdAt
                    )
                    if let temporaryChekiID = payload.temporaryChekiID {
                        confirmationLedger.consumeTemporaryCheki(temporaryChekiID)
                    }
                }

            case .editCheki(let payload):
                let cheki = try refetchChekiByID(payload.chekiID)
                guard cheki.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaEditConflictError.staleCheki(entry.code)
                }
                let idols = try refetchIdolsByIDs(payload.idolIDs)
                let event = try refetchEventByID(payload.eventID)
                try validateChekiAssociations(idols: idols, event: event, eventDate: payload.date)
                let groupingChanged = !sameChekiGroup(
                    idolIDs: cheki.idols.map(\.id),
                    eventID: cheki.event?.id,
                    eventDate: cheki.date,
                    otherIdolIDs: idols.map(\.id),
                    otherEventID: event?.id,
                    otherEventDate: payload.date
                )
                let newGroup = ChekinanaChekiGroupKey(
                    idolIDs: idols.map(\.id),
                    date: payload.date
                )
                let requiresIndexAssignment = newGroup != nil
                    && (groupingChanged || (cheki.idx ?? 0) < 1)
                let idx = requiresIndexAssignment
                    ? try nextChekiIndex(
                        idolIDs: idols.map(\.id),
                        eventID: event?.id,
                        eventDate: payload.date,
                        excludingChekiID: cheki.id
                    )
                    : (newGroup == nil ? nil : cheki.idx)
                cheki.idols = idols
                cheki.event = event
                cheki.date = payload.date
                cheki.idx = idx
                cheki.userAppears = payload.userAppears
                cheki.size = payload.size
                cheki.isFavorite = payload.isFavorite
                cheki.hasPostedToSNS = payload.hasPostedToSNS
                cheki.note = payload.note
                cheki.updatedAt = Date()
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    throw error
                }
                response = .chekiCards([chekiCard(for: cheki)])

            case .deleteCheki(let payload):
                response = try confirmDeleteCheki(payload, confirmationCode: entry.code)

            case .mutateRecord(let payload):
                response = try confirmRecordMutation(payload)

            case .downloadCheki(let chekiID, let imageURL):
                _ = try refetchChekiByID(chekiID)
                try await ChekiPhotoLibrarySaver.saveImage(at: imageURL)
                response = .text(ChekinanaCommandCopy.text(
                    "cheki.photo_saved",
                    fallback: "Saved the Cheki to the photo library."
                ))
            }

            confirmationLedger.removeAfterSuccess(entry)
            return response
        } catch {
            return .text(ChekinanaCommandCopy.error(
                "confirmation.failed_retained",
                fallback: "Confirmation failed. This operation remains pending: %@",
                error.localizedDescription
            ))
        }
    }

    private func confirmRecordMutation(_ payload: ChekinanaConfirmationLedger.RecordPayload) throws -> ChekinanaCommandResponse {
        let idols = try refetchIdolsByIDs(payload.idolIDs)
        let event = payload.kind == .cheki
            ? try refetchEventByID(payload.eventID)
            : nil
        func validateChekiRecord(excluding id: UUID?) throws {
            try validateChekiAssociations(idols: idols, event: event, eventDate: payload.date)
            guard let idx = payload.idx else { return }
            guard idx > 0,
                  let group = ChekinanaChekiGroupKey(idolIDs: idols.map(\.id), date: payload.date) else {
                throw ChekinanaNLClientError.invalidSchema
            }
            let collision = try modelContext.fetch(FetchDescriptor<Cheki>()).contains {
                $0.id != id
                    && ChekinanaChekiGroupKey(idolIDs: $0.idols.map(\.id), date: $0.date) == group
                    && $0.idx == idx
            }
            guard !collision else { throw ChekinanaAddChekiError.duplicateIndex(idx) }
        }
        switch (payload.kind, payload.mutation) {
        case (.cheki, .add):
            try validateChekiRecord(excluding: nil)
            let record = Cheki(date: payload.date, idx: payload.idx, userAppears: payload.userAppears, size: payload.size, isFavorite: payload.favorite, note: payload.note)
            modelContext.insert(record); record.idols = idols; record.event = event
        case (.shame, .add):
            throw ChekinanaMediaBackedCreationError.shameRequiresImage
        case (.douga, .add):
            throw ChekinanaMediaBackedCreationError.dougaRequiresVideo
        case (.cheki, .edit(let id)):
            let record = try refetchChekiByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaEditConflictError.staleCheki("") }
            try validateChekiRecord(excluding: id)
            record.idols = idols; record.event = event; record.date = payload.date; record.idx = payload.idx; record.note = payload.note; record.userAppears = payload.userAppears; record.isFavorite = payload.favorite; record.size = payload.size; record.updatedAt = Date()
        case (.shame, .edit(let id)):
            let record = try refetchShameByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaNLClientError.invalidSchema }
            record.idols = idols; record.date = payload.date; record.note = payload.note
        case (.douga, .edit(let id)):
            let record = try refetchDougaByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaNLClientError.invalidSchema }
            record.idols = idols; record.date = payload.date; record.note = payload.note
        case (.cheki, .delete(let id)):
            let record = try refetchChekiByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint,
                  ChekinanaNoMediaPolicy.hasNoImage(record.imageRef) else {
                throw ChekinanaNLClientError.invalidSchema
            }
            modelContext.delete(record)
        case (.shame, .delete(let id)):
            let record = try refetchShameByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaNLClientError.invalidSchema }
            let staged = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
                kind: .shame,
                id: record.id,
                reference: record.imageRef
            )
            modelContext.delete(record)
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                try? ChekinanaGalleryMediaStore.restoreStagedFiles(staged)
                throw error
            }
            ChekinanaGalleryMediaStore.recordCommittedDeletion(staged)
            try? ChekinanaGalleryMediaStore.finalizeStagedDeletion(staged)
            return .text(ChekinanaCommandCopy.text(
                "record.completed",
                fallback: "Record operation completed."
            ))
        case (.douga, .delete(let id)):
            let record = try refetchDougaByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaNLClientError.invalidSchema }
            let staged = try ChekinanaGalleryMediaStore.stageFilesForDeletion(
                kind: .douga,
                id: record.id,
                reference: record.videoRef
            )
            modelContext.delete(record)
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                try? ChekinanaGalleryMediaStore.restoreStagedFiles(staged)
                throw error
            }
            ChekinanaGalleryMediaStore.recordCommittedDeletion(staged)
            try? ChekinanaGalleryMediaStore.finalizeStagedDeletion(staged)
            return .text(ChekinanaCommandCopy.text(
                "record.completed",
                fallback: "Record operation completed."
            ))
        }
        do { try modelContext.save() } catch { modelContext.rollback(); throw error }
        return .text(ChekinanaCommandCopy.text(
            "record.completed",
            fallback: "Record operation completed."
        ))
    }

    private func confirmDeleteCheki(
        _ payload: ChekinanaConfirmationLedger.DeleteChekiPayload,
        confirmationCode: String
    ) throws -> ChekinanaCommandResponse {
        let fileManager = FileManager.default
        switch payload.phase {
        case .cleanupQuarantine(let quarantineURL):
            if fileManager.fileExists(atPath: quarantineURL.path) {
                try fileManager.removeItem(at: quarantineURL)
            }
            return .text(ChekinanaConfirmationResponseValidator.chekiDeletionSuccessText)

        case .restoreThenDelete(let originalURL, let quarantineURL):
            do {
                if fileManager.fileExists(atPath: quarantineURL.path) {
                    try fileManager.moveItem(at: quarantineURL, to: originalURL)
                } else if !fileManager.fileExists(atPath: originalURL.path) {
                    throw ChekinanaDeleteError.managedImageRecoveryMissing
                }
            } catch {
                throw ChekinanaDeleteError.managedImageRestoreFailed(error.localizedDescription)
            }
            confirmationLedger.updateDeleteChekiPayload(
                .init(
                    chekiID: payload.chekiID,
                    expectedUpdatedAt: payload.expectedUpdatedAt,
                    phase: .deleteModel
                ),
                for: confirmationCode
            )

        case .deleteModel:
            break
        }

        let cheki = try refetchChekiByID(payload.chekiID)
        if let expectedUpdatedAt = payload.expectedUpdatedAt,
           cheki.updatedAt != expectedUpdatedAt {
            throw ChekinanaEditConflictError.staleCheki(confirmationCode)
        }
        let managedImageURL = ChekiImageRefResolver.managedChekiFileURL(
            for: cheki.imageRef,
            chekiID: cheki.id
        )
        var quarantineURL: URL?
        if let managedImageURL {
            let candidate = managedImageURL.deletingLastPathComponent().appendingPathComponent(
                ".delete-\(cheki.id.uuidString)-\(UUID().uuidString).quarantine"
            )
            try fileManager.moveItem(at: managedImageURL, to: candidate)
            quarantineURL = candidate
        }

        modelContext.delete(cheki)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            if let managedImageURL, let quarantineURL {
                do {
                    try fileManager.moveItem(at: quarantineURL, to: managedImageURL)
                } catch let restoreError {
                    confirmationLedger.updateDeleteChekiPayload(
                        .init(
                            chekiID: payload.chekiID,
                            expectedUpdatedAt: payload.expectedUpdatedAt,
                            phase: .restoreThenDelete(
                                originalURL: managedImageURL,
                                quarantineURL: quarantineURL
                            )
                        ),
                        for: confirmationCode
                    )
                    throw ChekinanaDeleteError.databaseSaveAndImageRestoreFailed(
                        save: error.localizedDescription,
                        restore: restoreError.localizedDescription
                    )
                }
            }
            throw error
        }

        if let quarantineURL {
            confirmationLedger.updateDeleteChekiPayload(
                .init(
                    chekiID: payload.chekiID,
                    expectedUpdatedAt: payload.expectedUpdatedAt,
                    phase: .cleanupQuarantine(quarantineURL)
                ),
                for: confirmationCode
            )
            do {
                try fileManager.removeItem(at: quarantineURL)
            } catch {
                throw ChekinanaDeleteError.managedImageCleanupFailed(error.localizedDescription)
            }
        }
        return .text(ChekinanaConfirmationResponseValidator.chekiDeletionSuccessText)
    }

    private func addIdol(_ command: ChekinanaParsedCommand, usage: [String]) async -> ChekinanaCommandResponse {
        guard let target = command.target,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.arguments.isEmpty else {
            return invalidUsage(usage)
        }

        return await addIdols(named: [target], publishesSingleConfirmation: true)
    }

    func addIdols(_ commands: [String]) async -> ChekinanaCommandResponse {
        var names: [String] = []
        for input in commands {
            guard let command = try? ChekinanaCommandParser.parse(input),
                  command.name == "addidol",
                  let target = command.target?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty,
                  command.arguments.isEmpty else {
                return .text(ChekinanaCommandCopy.error(
                    "idol.invalid_batch",
                    fallback: "Invalid Add Idol batch."
                ))
            }
            names.append(target)
        }
        guard !names.isEmpty else {
            return .text(ChekinanaCommandCopy.error(
                "idol.invalid_batch",
                fallback: "Invalid Add Idol batch."
            ))
        }
        return await addIdols(named: names, publishesSingleConfirmation: false)
    }

    private func addIdols(
        named names: [String],
        publishesSingleConfirmation: Bool
    ) async -> ChekinanaCommandResponse {
        let generation = confirmationLedger.beginIdolQuery()
        do {
#if DEBUG
            let searchStartedAt = DispatchTime.now().uptimeNanoseconds
#endif
            let searchOutcomes = await searchIdols(named: names)
#if DEBUG
            let searchedCandidateCount = searchOutcomes.reduce(into: 0) { count, outcome in
                if case .success(_, _, let candidates) = outcome {
                    count += candidates.count
                }
            }
            ChekinanaIdolPipelineTimingLog.search(
                requestedCount: names.count,
                completedCount: searchOutcomes.count,
                candidateCount: searchedCandidateCount,
                startedAt: searchStartedAt
            )
#endif
            try Task.checkCancellation()
            var seenSourceIDs = Set<String>()
            var searchedCandidates: [SearchedIdolCandidate] = []
            var failedNames: [String] = []
            for outcome in searchOutcomes {
                switch outcome {
                case .success(_, let name, let searchResults):
                    searchedCandidates.append(contentsOf: searchResults.compactMap { result in
                        guard !result.sourceId.isEmpty,
                              seenSourceIDs.insert(result.sourceId).inserted else {
                            return nil
                        }
                        return SearchedIdolCandidate(query: name, candidate: result)
                    })
                case .failed(_, let name):
                    failedNames.append(name)
                case .cancelled(_, let name):
                    failedNames.append(name)
                }
            }
            guard !searchedCandidates.isEmpty else {
                if !failedNames.isEmpty {
                    return .text(ChekinanaCommandCopy.error(
                        "idol.search_failed",
                        fallback: "Idol search failed. Try again: %@.",
                        localizedList(failedNames)
                    ))
                }
                return .text(ChekinanaCommandCopy.error(
                    "idol.no_addable_results",
                    fallback: "No Idol available to add was found."
                ))
            }
            let sourceIDs = Set(searchedCandidates.map(\.candidate.sourceId).filter { !$0.isEmpty })
            var existingSourceIDs = Set<String>()
            for sourceID in sourceIDs where try hasIdol(sourceId: sourceID) {
                existingSourceIDs.insert(sourceID)
            }
            let notAlreadyAdded = searchedCandidates.filter {
                !existingSourceIDs.contains($0.candidate.sourceId)
            }
            let invalidBirthdayNames = orderedUnique(notAlreadyAdded.compactMap { searched in
                searched.candidate.birthdayIsInvalid ? searched.candidate.idolName : nil
            })
            let addableSearchedCandidates: [SearchedIdolCandidate] =
                notAlreadyAdded.compactMap { searched -> SearchedIdolCandidate? in
                guard let candidate = try? ChekinanaBirthdayValue
                    .normalizedCatalogueCandidate(searched.candidate) else {
                    return nil
                }
                return SearchedIdolCandidate(
                    query: searched.query,
                    candidate: candidate
                )
            }
#if DEBUG
            let avatarStartedAt = DispatchTime.now().uptimeNanoseconds
#endif
            let prepared = await prepareIdolCandidates(addableSearchedCandidates)
#if DEBUG
            ChekinanaIdolPipelineTimingLog.avatars(
                requestedCount: addableSearchedCandidates.count,
                completedCount: prepared.candidates.count,
                startedAt: avatarStartedAt
            )
#endif
            try Task.checkCancellation()
            let addableResults = prepared.candidates
            failedNames = orderedUnique(failedNames)
            guard !addableResults.isEmpty else {
                if !invalidBirthdayNames.isEmpty {
                    return .text(ChekinanaCommandCopy.errorDetail(
                        "\(ChekinanaBirthdayValue.ValidationError.invalid.localizedDescription) \(localizedList(invalidBirthdayNames))"
                    ))
                }
                if !failedNames.isEmpty {
                    let existingNames = searchedCandidates
                        .filter { existingSourceIDs.contains($0.candidate.sourceId) }
                        .map(\.candidate.idolName)
                    if !existingNames.isEmpty {
                        return .text(ChekinanaCommandCopy.format(
                            "idol.existing_and_failed",
                            fallback: "Already added: %1$@. Search failed and can be retried later: %2$@.",
                            localizedList(existingNames),
                            localizedList(failedNames)
                        ))
                    }
                    return .text(ChekinanaCommandCopy.error(
                        "idol.search_failed",
                        fallback: "Idol search failed. Try again: %@.",
                        localizedList(failedNames)
                    ))
                }
                return .text(ChekinanaCommandCopy.format(
                    "idol.already_added_many",
                    fallback: "Idols already added: %@.",
                    searchedCandidates.map(\.candidate.sourceId).joined(separator: ", ")
                ))
            }
            if publishesSingleConfirmation,
               addableResults.count == 1,
               let resolved = addableResults.first {
                try Task.checkCancellation()
                guard let code = confirmationLedger.publishIdolConfirmation(
                    resolved,
                    generation: generation
                ) else {
                    return .text(inactiveIdolQueryText)
                }
#if DEBUG
                ChekinanaIdolPipelineTimingLog.publishedCards(1)
#endif
                return .idolCard(candidateCard(resolved, confirmationCode: code))
            }
            try Task.checkCancellation()
            guard let choices = confirmationLedger.replaceIdolCandidates(
                addableResults,
                generation: generation
            ) else {
                return .text(inactiveIdolQueryText)
            }
            let cards = choices.map { choice in
                candidateCard(
                    choice.candidate,
                    confirmationCode: nil,
                    selectionToken: choice.token
                )
            }
#if DEBUG
            ChekinanaIdolPipelineTimingLog.publishedCards(cards.count)
#endif
            if invalidBirthdayNames.isEmpty,
               failedNames.isEmpty,
               prepared.placeholderCount == 0 {
                return .idolCards(cards)
            }
            var notices: [String] = []
            if !invalidBirthdayNames.isEmpty {
                notices.append(
                    "\(ChekinanaBirthdayValue.ValidationError.invalid.localizedDescription) \(localizedList(invalidBirthdayNames))"
                )
            }
            if !failedNames.isEmpty {
                notices.append(ChekinanaCommandCopy.format(
                    "idol.search_failed_notice",
                    fallback: "Search failed and can be retried later: %@.",
                    localizedList(failedNames)
                ))
            }
            if prepared.placeholderCount > 0 {
                notices.append(ChekinanaCommandCopy.quantity(
                    "idol.avatar_placeholder",
                    count: prepared.placeholderCount,
                    one: "%lld candidate avatar failed to load or timed out; a placeholder is shown.",
                    other: "%lld candidate avatars failed to load or timed out; placeholders are shown."
                ))
            }
            return .idolCardsWithNotice(
                cards,
                notices.joined(separator: "\n")
            )
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private var inactiveIdolQueryText: String {
        ChekinanaCommandCopy.error(
            "idol.query_inactive",
            fallback: "This Idol query is no longer active. Run the Idol query again."
        )
    }

    private func localizedList(_ values: [String]) -> String {
        ListFormatter.localizedString(byJoining: values)
    }

    private func searchIdols(named names: [String]) async -> [IdolSearchOutcome] {
        let search = idolSearch
        return await withTaskGroup(of: IdolSearchOutcome.self) { group in
            for (index, name) in names.enumerated() {
                group.addTask {
                    do {
                        return try await ChekinanaRemoteRequestLimiter.shared.perform {
                            let results = try await search(name)
                            try Task.checkCancellation()
                            return .success(index, name, results)
                        }
                    } catch is CancellationError {
                        return Task.isCancelled
                            ? .cancelled(index, name)
                            : .failed(index, name)
                    } catch {
                        return .failed(index, name)
                    }
                }
            }

            var outcomes: [IdolSearchOutcome] = []
            outcomes.reserveCapacity(names.count)
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes.sorted { lhs, rhs in
                searchOutcomeIndex(lhs) < searchOutcomeIndex(rhs)
            }
        }
    }

    private func searchOutcomeIndex(_ outcome: IdolSearchOutcome) -> Int {
        switch outcome {
        case .success(let index, _, _), .failed(let index, _), .cancelled(let index, _): index
        }
    }

    private func prepareIdolCandidates(
        _ searchedCandidates: [SearchedIdolCandidate]
    ) async -> (candidates: [ChekinanaPreparedIdolCandidate], placeholderCount: Int) {
        guard !searchedCandidates.isEmpty else { return ([], 0) }
        let avatarPrepare = idolAvatarPrepare
        let timeoutNanoseconds = idolAvatarBatchTimeoutNanoseconds
#if DEBUG
        ChekinanaIdolPipelineTimingLog.avatarBatchStarted(searchedCandidates.count)
#endif
        let (outcomes, continuation) = AsyncStream<PreparedIdolCandidateOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(searchedCandidates.count + 1)
        )
        // This limiter is private to one publication batch. It prevents many
        // injected or future avatar preparations from synchronously blocking
        // every Swift cooperative-executor thread. Unlike the shared remote
        // limiter, a late holder cannot delay later searches or downloads.
        let preparationLimiter = ChekinanaRemoteRequestLimiter(limit: 2)
        // These handles are deliberately unstructured. A cancelled task group
        // waits for every child before leaving its scope, which means a
        // synchronous ImageIO decode can defeat a UI timeout. Closing the
        // stream below releases the caller immediately; cancelled work may
        // finish in the background, but can no longer publish a result.
        let avatarTasks: [Task<Void, Never>] = searchedCandidates.enumerated().map {
            index, searched in
            Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return }
                let outcome: PreparedIdolCandidateOutcome
                do {
                    outcome = try await preparationLimiter.perform {
                        await Self.preparedIdolCandidateOutcome(
                            index: index,
                            searched: searched,
                            avatarPrepare: avatarPrepare
                        )
                    }
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                continuation.yield(outcome)
            }
        }
        // Dispatch owns the deadline so a temporarily saturated Swift
        // cooperative executor cannot delay the publication boundary.
        let deadline = ChekinanaAvatarBatchDeadline(
            timeoutNanoseconds: timeoutNanoseconds
        ) {
            continuation.yield(.timedOut)
        }

        return await withTaskCancellationHandler {
            defer {
                avatarTasks.forEach { $0.cancel() }
                deadline.cancel()
                continuation.finish()
            }
            var completed: [Int: (ChekinanaPreparedIdolCandidate, Bool)] = [:]
            var didTimeOut = false
            for await outcome in outcomes {
                if Task.isCancelled { break }
                switch outcome {
                case .completed(let index, let candidate, let usedPlaceholder):
                    guard completed[index] == nil else { continue }
                    completed[index] = (candidate, usedPlaceholder)
#if DEBUG
                    ChekinanaIdolPipelineTimingLog.avatarItemCompleted(
                        index: index,
                        usedPlaceholder: usedPlaceholder
                    )
#endif
                case .timedOut:
                    didTimeOut = true
#if DEBUG
                    ChekinanaIdolPipelineTimingLog.avatarBatchTimedOut(
                        completedCount: completed.count,
                        requestedCount: searchedCandidates.count
                    )
#endif
                }
                if completed.count == searchedCandidates.count || didTimeOut {
                    break
                }
            }

            var candidates: [ChekinanaPreparedIdolCandidate] = []
            var placeholderCount = 0
            candidates.reserveCapacity(searchedCandidates.count)
            for (index, searched) in searchedCandidates.enumerated() {
                if let (candidate, usedPlaceholder) = completed[index] {
                    candidates.append(candidate)
                    if usedPlaceholder { placeholderCount += 1 }
                } else {
                    candidates.append(ChekinanaPreparedIdolCandidate(
                        candidate: searched.candidate,
                        avatarThumbnailData: nil,
                        avatarIdentity: nil
                    ))
                    placeholderCount += 1
                }
            }
            return (candidates, placeholderCount)
        } onCancel: {
            // `finish` wakes a suspended AsyncStream iterator synchronously.
            // No task handle is awaited here, so even a non-cooperative
            // synchronous decode cannot hold executeCommands/isSubmitting.
            avatarTasks.forEach { $0.cancel() }
            deadline.cancel()
            continuation.finish()
        }
    }

    private static func preparedIdolCandidateOutcome(
        index: Int,
        searched: SearchedIdolCandidate,
        avatarPrepare: IdolAvatarPrepare
    ) async -> PreparedIdolCandidateOutcome {
        guard let declaredAvatarURL = searched.candidate.avatarUrl else {
            return .completed(index, ChekinanaPreparedIdolCandidate(
                candidate: searched.candidate,
                avatarThumbnailData: nil,
                avatarIdentity: nil
            ), usedPlaceholder: false)
        }
        let avatarValue = declaredAvatarURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !avatarValue.isEmpty else {
            return .completed(index, ChekinanaPreparedIdolCandidate(
                candidate: searched.candidate,
                avatarThumbnailData: nil,
                avatarIdentity: nil
            ), usedPlaceholder: true)
        }
        guard let identity = ChekinanaIdolAvatarIdentity.make(
            sourceID: searched.candidate.sourceId,
            avatarURL: searched.candidate.avatarUrl
        ) else {
            return .completed(index, ChekinanaPreparedIdolCandidate(
                candidate: searched.candidate,
                avatarThumbnailData: nil,
                avatarIdentity: nil
            ), usedPlaceholder: true)
        }
        do {
            guard let data = try await avatarPrepare(searched.candidate),
                  !data.isEmpty else {
                return .completed(index, ChekinanaPreparedIdolCandidate(
                    candidate: searched.candidate,
                    avatarThumbnailData: nil,
                    avatarIdentity: nil
                ), usedPlaceholder: true)
            }
            let rendered = await ChekinanaImageWorker.thumbnailImage(
                from: data,
                maxDimension: 256
            )
            return .completed(index, ChekinanaPreparedIdolCandidate(
                candidate: searched.candidate,
                avatarThumbnailData: data,
                avatarIdentity: identity,
                avatarThumbnailImage: rendered
            ), usedPlaceholder: false)
        } catch {
            return .completed(index, ChekinanaPreparedIdolCandidate(
                candidate: searched.candidate,
                avatarThumbnailData: nil,
                avatarIdentity: nil
            ), usedPlaceholder: true)
        }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func confirmIdolCandidate(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) async -> ChekinanaCommandResponse {
        guard let token = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        guard let candidate = confirmationLedger.idolCandidate(token) else {
            return .text(ChekinanaCommandCopy.error(
                "idol.candidate_unavailable",
                fallback: "This Idol candidate is no longer available. Run the Idol query again."
            ))
        }
        do {
            guard try !hasIdol(sourceId: candidate.candidate.sourceId) else {
                _ = confirmationLedger.consumeIdolCandidate(token)
                return .text(ChekinanaCommandCopy.error(
                    "idol.already_added",
                    fallback: "Idol already added: %@.",
                    candidate.candidate.sourceId
                ))
            }
            try Task.checkCancellation()
            let idol = try await persistCatalogueIdol(candidate)
            _ = confirmationLedger.consumeIdolCandidate(token)
            return .idolCard(idolCard(idol, preparedCandidate: candidate))
        } catch is CancellationError {
            return .text(ChekinanaCommandCopy.error(
                "idol.confirmation_cancelled",
                fallback: "Idol confirmation was cancelled; the candidate remains available."
            ))
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func selectIdolCandidate(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) -> ChekinanaCommandResponse {
        guard let token = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        guard let candidate = confirmationLedger.consumeIdolCandidate(token) else {
            confirmationLedger.invalidateIdolCandidates()
            return .text(ChekinanaCommandCopy.error(
                "idol.candidate_unavailable",
                fallback: "This Idol candidate is no longer available. Run the Idol query again."
            ))
        }
        confirmationLedger.invalidateIdolCandidates()
        do {
            guard try !hasIdol(sourceId: candidate.candidate.sourceId) else {
                return .text(ChekinanaCommandCopy.error(
                    "idol.already_added",
                    fallback: "Idol already added: %@.",
                    candidate.candidate.sourceId
                ))
            }
            let code = confirmationLedger.insert(.addIdol(candidate))
            return .idolCard(candidateCard(candidate, confirmationCode: code))
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func editIdol(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        var values = command.arguments
        if let avatarAlias = values.removeValue(forKey: "avatar_url") {
            guard values["avatar"] == nil else {
                return .text(ChekinanaCommandCopy.error(
                    "idol.duplicate_avatar",
                    fallback: "Duplicate avatar field. Use avatar only."
                ))
            }
            values["avatar"] = avatarAlias
        }

        let rawClearFields = values.removeValue(forKey: "clear_fields")
        var clearFields = Set(
            rawClearFields?.split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init) ?? []
        )
        let clearableFields = Set(["group", "birthday", "color", "verification", "bio", "avatar"])
        guard clearFields.isSubset(of: clearableFields),
              rawClearFields == nil || !clearFields.isEmpty else {
            return invalidUsage(usage)
        }

        // Preserve direct-command compatibility, but normalize legacy clear
        // sentinels immediately. Typed plans compile only explicit clear_fields.
        for field in clearableFields where values[field] == "-" {
            values.removeValue(forKey: field)
            clearFields.insert(field)
        }

        let allowedFields = Set(["name", "group", "birthday", "color", "verification", "bio", "avatar"])
        guard let target = command.target,
              !values.isEmpty || !clearFields.isEmpty,
              clearFields.isDisjoint(with: values.keys) else {
            return invalidUsage(usage)
        }

        let unsupportedFields = values.keys.filter { !allowedFields.contains($0) }.sorted()
        guard unsupportedFields.isEmpty else {
            return .text(ChekinanaCommandCopy.error(
                "idol.unsupported_edit_fields",
                fallback: "Unsupported Edit Idol fields: %1$@.\n\nUsage:\n%2$@",
                unsupportedFields.joined(separator: ", "),
                usage.joined(separator: "\n")
            ))
        }

        for (field, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || (field == "name" && trimmed == "-") {
                return .text(ChekinanaCommandCopy.error(
                    "field.nonempty",
                    fallback: "%@ requires a non-empty value.",
                    field
                ))
            }

            if field == "avatar", isUnsafeLocalAvatarReference(trimmed) {
                return .text(ChekinanaCommandCopy.error(
                    "idol.avatar_reference",
                    fallback: "Avatar must be an HTTP(S) URL or a managed image reference, not a local file path."
                ))
            }
        }
        if let birthday = values["birthday"] {
            do {
                values["birthday"] = try ChekinanaBirthdayValue.normalizedStorage(
                    birthday
                )
            } catch {
                return .text(ChekinanaCommandCopy.errorDetail(
                    error.localizedDescription
                ))
            }
        }

        do {
            try ChekinanaNLSchemaValidator.validateOperation(
                .init(
                    intent: .editidol,
                    slots: .init(
                        name: values["name"],
                        target: target,
                        group: values["group"],
                        birthday: values["birthday"],
                        color: values["color"],
                        verification: values["verification"],
                        bio: values["bio"],
                        avatar: values["avatar"],
                        clearFields: clearFields.sorted()
                    )
                ),
                allowingPartial: false
            )
        } catch {
            return .text(ChekinanaCommandCopy.error(
                "idol.invalid_edit_value",
                fallback: "An Edit Idol field value is invalid or too long."
            ))
        }

        if let entry = confirmationLedger.entry(for: target), case .addIdol(let candidate) = entry.action {
            let editedCandidate = editedCandidate(
                candidate.candidate,
                values: values,
                clearFields: clearFields
            )
            let editedIdentity = ChekinanaIdolAvatarIdentity.make(
                sourceID: editedCandidate.sourceId,
                avatarURL: editedCandidate.avatarUrl
            )
            let edited = ChekinanaPreparedIdolCandidate(
                candidate: editedCandidate,
                avatarThumbnailData: editedIdentity == candidate.avatarIdentity
                    ? candidate.avatarThumbnailData
                    : nil,
                avatarIdentity: editedIdentity == candidate.avatarIdentity
                    ? candidate.avatarIdentity
                    : nil
            )
            guard confirmationLedger.updateAddIdolCandidate(edited, for: target) else {
                return .text(ChekinanaCommandCopy.error(
                    "idol.candidate_code_unavailable",
                    fallback: "Candidate is no longer available: %@.",
                    target
                ))
            }
            return .idolCard(candidateCard(edited, confirmationCode: entry.code))
        }

        do {
            let idol = try resolveUniqueIdol(target)
            let code = confirmationLedger.insert(
                .editIdol(.init(
                    idolID: idol.id,
                    expectedUpdatedAt: idol.updatedAt,
                    values: values,
                    clearFields: clearFields
                ))
            )
            return .idolCard(previewCard(
                for: idol,
                values: values,
                clearFields: clearFields,
                confirmationCode: code
            ))
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func deleteIdol(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            let idol = try resolveUniqueIdol(target)
            let recordCount = try associatedRecordCount(for: idol.id)
            guard recordCount == 0 else {
                return .text(ChekinanaCommandCopy.error(
                    "idol.has_records",
                    fallback: "This Idol has %lld associated records. Delete or reassign them before deleting the Idol.",
                    Int64(recordCount)
                ))
            }
            let code = confirmationLedger.insert(.deleteIdol(.init(
                idolID: idol.id,
                expectedUpdatedAt: idol.updatedAt
            )))
            let card = ChekinanaIdolCard(
                id: idol.id,
                catalogueID: idol.sourceId,
                name: idol.name,
                group: idol.group,
                color: idol.color,
                birthday: idol.birthday,
                verification: nil,
                bio: nil,
                avatarImageRef: idol.avatarImageRef,
                avatarThumbnailData: nil,
                avatarIdentity: nil,
                detail: .deleteCandidate,
                confirmationCode: code,
                selectionToken: nil
            )
            return .idolCard(card)
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func favoriteIdol(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target,
              Set(command.arguments.keys) == Set(["favorite"]),
              let rawFavorite = command.arguments["favorite"],
              let favorite = parseStrictBool(rawFavorite) else {
            return invalidUsage(usage)
        }
        do {
            let idol = try resolveUniqueIdol(target)
            let code = confirmationLedger.insert(.favoriteIdol(.init(
                idolID: idol.id,
                expectedUpdatedAt: idol.updatedAt,
                favorite: favorite
            )))
            return .confirmationText(
                ChekinanaCommandCopy.format(
                    favorite ? "idol.favorite_confirm" : "idol.unfavorite_confirm",
                    fallback: favorite ? "Favorite %@?" : "Unfavorite %@?",
                    idol.name
                ),
                confirmationCode: code
            )
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func editedCandidate(
        _ candidate: ChekinanaEnrichedIdol,
        values: [String: String],
        clearFields: Set<String> = []
    ) -> ChekinanaEnrichedIdol {
        ChekinanaEnrichedIdol(
            sourceId: candidate.sourceId,
            idolName: editedRequired(candidate.idolName, field: "name", values: values),
            groupName: editedOptional(candidate.groupName, field: "group", values: values, clearFields: clearFields),
            color: editedOptional(candidate.color, field: "color", values: values, clearFields: clearFields),
            birthday: editedOptional(candidate.birthday, field: "birthday", values: values, clearFields: clearFields),
            verification: editedOptional(candidate.verification, field: "verification", values: values, clearFields: clearFields),
            bio: editedOptional(candidate.bio, field: "bio", values: values, clearFields: clearFields),
            avatarUrl: editedOptional(candidate.avatarUrl, field: "avatar", values: values, clearFields: clearFields)
        )
    }

    private func candidateCard(
        _ prepared: ChekinanaPreparedIdolCandidate,
        confirmationCode: String?,
        selectionToken: String? = nil
    ) -> ChekinanaIdolCard {
        let candidate = prepared.candidate
        return ChekinanaIdolCard(
            id: UUID(),
            catalogueID: candidate.sourceId,
            name: candidate.idolName,
            group: candidate.groupName,
            color: candidate.color,
            birthday: candidate.birthday,
            verification: candidate.verification,
            bio: candidate.bio,
            avatarImageRef: candidate.avatarUrl,
            avatarThumbnailData: prepared.avatarThumbnailData,
            avatarIdentity: prepared.avatarIdentity,
            avatarThumbnailImage: prepared.avatarThumbnailImage,
            detail: .addCandidate,
            confirmationCode: confirmationCode,
            selectionToken: selectionToken
        )
    }

    private func catalogueIdol(from candidate: ChekinanaEnrichedIdol) throws -> Idol {
        let birthday = try ChekinanaBirthdayValue.normalizedStorage(
            candidate.birthday
        )
        return Idol(
            sourceId: candidate.sourceId,
            name: candidate.idolName,
            group: candidate.groupName,
            color: candidate.color,
            birthday: birthday,
            avatarImageRef: nil,
            verification: candidate.verification,
            bio: candidate.bio,
            patterns: ChekinanaLocalPatternRegistry.mergedPatterns([
                ChekinanaLocalPatternRegistry.patterns(for: candidate.sourceId),
            ])
        )
    }

    private func persistCatalogueIdol(
        _ prepared: ChekinanaPreparedIdolCandidate
    ) async throws -> Idol {
        let idol = try catalogueIdol(from: prepared.candidate)
        let stagedAvatar = try await ChekinanaCatalogueIdolAvatarLocalizer.stage(
            prepared,
            idolID: idol.id
        )
        let result = try ChekinanaIdolPersistence.save(
            idol,
            inserting: true,
            previousAvatarRef: nil,
            stagedAvatar: stagedAvatar,
            in: modelContext
        ) { target in
            target.avatarImageRef = stagedAvatar.ref
        }
        if let pendingCleanup = result.pendingAvatarCleanup {
            _ = pendingCleanup
            throw ChekinanaCatalogueIdolAvatarLocalizerError.cleanupRequired
        }
        return idol
    }

    private func previewCard(
        for idol: Idol,
        values: [String: String],
        clearFields: Set<String> = [],
        confirmationCode: String
    ) -> ChekinanaIdolCard {
        ChekinanaIdolCard(
            id: idol.id,
            catalogueID: idol.sourceId,
            name: editedRequired(idol.name, field: "name", values: values),
            group: editedOptional(idol.group, field: "group", values: values, clearFields: clearFields),
            color: editedOptional(idol.color, field: "color", values: values, clearFields: clearFields),
            birthday: editedOptional(idol.birthday, field: "birthday", values: values, clearFields: clearFields),
            verification: editedOptional(idol.verification, field: "verification", values: values, clearFields: clearFields),
            bio: editedOptional(idol.bio, field: "bio", values: values, clearFields: clearFields),
            avatarImageRef: editedOptional(idol.avatarImageRef, field: "avatar", values: values, clearFields: clearFields),
            avatarThumbnailData: nil,
            avatarIdentity: nil,
            detail: .chekiCount(idol.chekis.count),
            confirmationCode: confirmationCode,
            selectionToken: nil
        )
    }

    private func applyIdolEdit(
        _ values: [String: String],
        clearFields: Set<String> = [],
        to idol: Idol
    ) {
        idol.name = editedRequired(idol.name, field: "name", values: values)
        idol.group = editedOptional(idol.group, field: "group", values: values, clearFields: clearFields)
        idol.color = editedOptional(idol.color, field: "color", values: values, clearFields: clearFields)
        idol.birthday = editedOptional(idol.birthday, field: "birthday", values: values, clearFields: clearFields)
        idol.avatarImageRef = editedOptional(idol.avatarImageRef, field: "avatar", values: values, clearFields: clearFields)
        idol.verification = editedOptional(idol.verification, field: "verification", values: values, clearFields: clearFields)
        idol.bio = editedOptional(idol.bio, field: "bio", values: values, clearFields: clearFields)
    }

    private func isUnsafeLocalAvatarReference(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("~") || value.contains("\\") {
            return true
        }

        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return value.contains("/") || value == "." || value == ".."
        }

        guard ["http", "https"].contains(scheme) else {
            return true
        }
        return !ChekinanaNLSchemaValidator.isSafeHTTPURL(value)
    }

    private func editedRequired(_ current: String, field: String, values: [String: String]) -> String {
        values[field]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? current
    }

    private func editedOptional(
        _ current: String?,
        field: String,
        values: [String: String],
        clearFields: Set<String> = []
    ) -> String? {
        if clearFields.contains(field) { return nil }
        guard let rawValue = values[field] else {
            return current
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    private func listIdol(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard command.target == nil, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }

        do {
            let descriptor = FetchDescriptor<Idol>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
            let idols = try modelContext.fetch(descriptor).filter {
                ChekinanaVisibilityPolicy.includesIdol($0.id, hiddenIDs: hiddenIDs)
            }

            guard !idols.isEmpty else {
                return .text(ChekinanaCommandCopy.text(
                    "idol.none",
                    fallback: "No Idols have been added yet."
                ))
            }

            return .idolCards(idols.map { idolCard($0) })
        } catch {
            return .text(ChekinanaCommandCopy.error(
                "idol.fetch_failed",
                fallback: "Failed to fetch Idols: %@",
                error.localizedDescription
            ))
        }
    }

    private func showIdol(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }

        let normalizedTarget = target.lowercased()

        do {
            let descriptor = FetchDescriptor<Idol>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
            let idols = try modelContext.fetch(descriptor).filter {
                ChekinanaVisibilityPolicy.includesIdol($0.id, hiddenIDs: hiddenIDs)
            }
            let idMatches = idols.filter { idol in
                idol.id.uuidString.lowercased().hasPrefix(normalizedTarget)
            }

            if idMatches.count > 1 {
                return .text(ChekinanaCommandCopy.error(
                    "idol.ambiguous_id",
                    fallback: "Ambiguous Idol ID: %@.",
                    target
                ))
            }

            if let idol = idMatches.first {
                return showIdolResponse(for: [idol])
            }

            let nameMatches = idols.filter { idol in
                idol.name.range(of: target, options: [.caseInsensitive]) != nil
            }

            guard !nameMatches.isEmpty else {
                return .text(ChekinanaCommandCopy.error(
                    "idol.no_match",
                    fallback: "No Idol matches: %@.",
                    target
                ))
            }

            return showIdolResponse(for: nameMatches)
        } catch {
            return .text(ChekinanaCommandCopy.error(
                "idol.fetch_one_failed",
                fallback: "Failed to fetch Idol: %@",
                error.localizedDescription
            ))
        }
    }

    private func addEvent(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        let allowedFields = Set(["name", "date"])
        guard let target = command.target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty,
              command.arguments.keys.allSatisfy(allowedFields.contains) else {
            return invalidUsage(usage)
        }

        do {
            let targetURL = try optionalHTTPURL(target)
            let name: String
            let date: Date?
            if let targetURL {
                let explicitName = command.arguments["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawDate = command.arguments["date"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                var missingFields: [String] = []
                if explicitName == nil || explicitName?.isEmpty == true || explicitName == "-" {
                    missingFields.append("name")
                }
                if rawDate == nil || rawDate?.isEmpty == true {
                    missingFields.append("date")
                }
                guard missingFields.isEmpty else {
                    throw ChekinanaEventError.missingRequiredFields(missingFields)
                }
                guard let explicitName,
                      explicitName.range(
                        of: #"^https?://"#,
                        options: [.regularExpression, .caseInsensitive]
                      ) == nil else {
                    throw ChekinanaEventError.invalidName
                }
                name = explicitName
                date = try parseCalendarDate(rawDate ?? "")
                try ensureEventIsNotDuplicate(name: name, date: date, url: targetURL)
                let code = confirmationLedger.insert(
                    .addEvent(.init(
                        name: name,
                        date: date,
                        city: nil,
                        livehouse: nil,
                        weiboURL: targetURL,
                        ticketURL: nil,
                        note: ""
                    ))
                )
                return .confirmationText(eventPreviewDetails(
                    id: nil,
                    name: name,
                    date: date,
                    weiboURL: targetURL,
                    prefix: ChekinanaCommandCopy.text(
                        "event.prepared_add",
                        fallback: "Prepared Add Event"
                    ),
                    confirmationCode: code
                ), confirmationCode: code)
            }

            guard command.arguments["name"] == nil,
                  let rawDate = command.arguments["date"] else {
                return invalidUsage(usage)
            }
            name = target
            date = try parseCalendarDate(rawDate)
            try ensureEventIsNotDuplicate(name: name, date: date, url: nil)
            let code = confirmationLedger.insert(
                .addEvent(.init(
                    name: name,
                    date: date,
                    city: nil,
                    livehouse: nil,
                    weiboURL: nil,
                    ticketURL: nil,
                    note: ""
                ))
            )
            return .confirmationText(eventPreviewDetails(
                id: nil,
                name: name,
                date: date,
                weiboURL: nil,
                prefix: ChekinanaCommandCopy.text(
                    "event.prepared_add",
                    fallback: "Prepared Add Event"
                ),
                confirmationCode: code
            ), confirmationCode: code)
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func listEvent(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard command.target == nil, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            let events = try modelContext.fetch(FetchDescriptor<Event>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            ))
            guard !events.isEmpty else {
                return .text(ChekinanaCommandCopy.text(
                    "event.none",
                    fallback: "No Events have been added yet."
                ))
            }
            return .eventCards(events.map(eventCard))
        } catch {
            return .text(ChekinanaCommandCopy.error(
                "event.fetch_failed",
                fallback: "Failed to fetch Events: %@",
                error.localizedDescription
            ))
        }
    }

    private func showEvent(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            return .eventCard(eventCard(try resolveUniqueEvent(target)))
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func editEvent(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        let allowedFields = Set([
            "name", "date", "city", "livehouse", "price", "url",
            "ticket_url", "note", "clear_fields",
        ])
        guard let target = command.target,
              !command.arguments.isEmpty,
              command.arguments.keys.allSatisfy(allowedFields.contains) else {
            return invalidUsage(usage)
        }
        do {
            let event = try resolveUniqueEvent(target)
            var name = event.name
            var date = event.date
            var city = event.city
            var livehouse = event.livehouse
            var price = event.price
            var url = event.weiboURL
            var ticketURL = event.ticketURL
            var note = event.note

            let clearFields = Set(
                command.arguments["clear_fields"]?
                    .split(separator: ",")
                    .map(String.init) ?? []
            )
            let allowedClear = Set([
                "date", "city", "livehouse", "price", "url", "ticket_url", "note",
            ])
            guard clearFields.isSubset(of: allowedClear),
                  command.arguments.count > (command.arguments["clear_fields"] == nil ? 0 : 1)
                    || !clearFields.isEmpty else {
                throw ChekinanaNLClientError.invalidSchema
            }
            if clearFields.contains("date") { date = nil }
            if clearFields.contains("city") { city = nil }
            if clearFields.contains("livehouse") { livehouse = nil }
            if clearFields.contains("price") { price = nil }
            if clearFields.contains("url") { url = nil }
            if clearFields.contains("ticket_url") { ticketURL = nil }
            if clearFields.contains("note") { note = "" }

            if let value = command.arguments["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                guard !value.isEmpty, value != "-" else { throw ChekinanaEventError.invalidName }
                name = value
            }
            if let value = command.arguments["date"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                date = try parseCalendarDate(value)
            }
            if let value = command.arguments["city"] { city = value }
            if let value = command.arguments["livehouse"] { livehouse = value }
            if let value = command.arguments["price"] { price = value }
            if let value = command.arguments["url"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                url = try requireHTTPURL(value)
            }
            if let value = command.arguments["ticket_url"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                ticketURL = try requireHTTPURL(value)
            }
            if let value = command.arguments["note"] { note = value }

            let code = confirmationLedger.insert(.editEvent(.init(
                eventID: event.id,
                expectedUpdatedAt: event.updatedAt,
                name: name,
                date: date,
                city: city,
                livehouse: livehouse,
                price: price,
                weiboURL: url,
                ticketURL: ticketURL,
                note: note
            )))
            return .confirmationText(eventPreviewDetails(
                id: event.id,
                name: name,
                date: date,
                weiboURL: url,
                prefix: ChekinanaCommandCopy.text(
                    "event.prepared_edit",
                    fallback: "Prepared Edit Event"
                ),
                confirmationCode: code
            ), confirmationCode: code)
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func deleteEvent(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            let event = try resolveUniqueEvent(target)
            let recordCount = event.chekis.count
            guard recordCount == 0 else {
                return .text(ChekinanaCommandCopy.error(
                    "event.has_records",
                    fallback: "This Event has %lld associated records. Reassign or delete them before deleting the Event.",
                    Int64(recordCount)
                ))
            }
            let code = confirmationLedger.insert(.deleteEvent(.init(
                eventID: event.id,
                expectedUpdatedAt: event.updatedAt
            )))
            return .confirmationText(eventPreviewDetails(
                id: event.id,
                name: event.name,
                date: event.date,
                weiboURL: event.weiboURL,
                prefix: ChekinanaCommandCopy.text(
                    "event.prepared_delete",
                    fallback: "Prepared Delete Event"
                ),
                confirmationCode: code
            ), confirmationCode: code)
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func addCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) async -> ChekinanaCommandResponse {
        do {
            let arguments = try albumAddChekiArguments(command)
            let idolValue = arguments["idol"] ?? ""
            if command.target != nil,
               (try? confirmationLedger.resolveTemporaryCheki(idolValue)) != nil {
                return .text(ChekinanaCommandCopy.error(
                    "cheki.temporary_id_unsupported",
                    fallback: "Add Cheki no longer accepts temporary Cheki IDs. Use Add Scan Cheki for a temporary result."
                ))
            }
            _ = try resolvedAddChekiFields(arguments)
            return .requestAddChekiPhoto(.init(arguments: arguments))
        } catch ChekinanaAddChekiError.unsupportedArgument {
            return invalidUsage(usage)
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func albumAddChekiArguments(_ command: ChekinanaParsedCommand) throws -> [String: String] {
        let allowed = Set(["idol", "idols", "event", "date", "user", "userappears", "size", "note"])
        guard command.arguments.keys.allSatisfy(allowed.contains) else {
            throw ChekinanaAddChekiError.unsupportedArgument
        }
        var arguments = command.arguments
        let keyed = arguments.removeValue(forKey: "idol") ?? arguments.removeValue(forKey: "idols")
        if command.arguments["idol"] != nil && command.arguments["idols"] != nil {
            throw ChekinanaAddChekiError.duplicateArgument("idol")
        }
        guard !(command.target != nil && keyed != nil) else {
            throw ChekinanaAddChekiError.duplicateArgument("idol")
        }
        if let value = command.target ?? keyed,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments["idol"] = value
        }
        if let userAppears = arguments.removeValue(forKey: "userappears") {
            guard arguments["user"] == nil else {
                throw ChekinanaAddChekiError.duplicateArgument("user")
            }
            arguments["user"] = userAppears
        }
        return arguments
    }

    nonisolated static func prepareAlbumAddCheki(
        _ request: ChekinanaAlbumAddChekiRequest,
        image: ChekinanaPendingChekiImage
    ) async -> ChekinanaPreparedAlbumCheki {
        let thumbnail = await ChekinanaImageWorker.thumbnailData(from: image.data)
        return ChekinanaPreparedAlbumCheki(
            request: request,
            image: image,
            thumbnailImageData: thumbnail
        )
    }

    /// MainActor-only phase B. This function is intentionally synchronous:
    /// ContentView validates the picker session immediately before calling it,
    /// and no newer session can interleave before both ledger mutations finish.
    func finalizeAlbumAddChekis(
        _ prepared: [ChekinanaPreparedAlbumCheki],
        failedCount: Int
    ) throws -> ChekinanaCommandResponse {
        guard let request = prepared.first?.request else {
            throw ChekinanaAlbumPreparationError.noPreparedImage
        }
        // Re-resolve after the system picker closes; local data may have changed.
        let fields = try resolvedAddChekiFields(request.arguments)
        let idols = try refetchIdolsByIDs(fields.idolIDs)
        let eventWasExplicitlySpecified = request.arguments["event"] != nil
        let event = eventWasExplicitlySpecified
            ? try refetchEventByID(fields.eventID)
            : try uniqueEvent(for: fields.eventDate)
        var cards: [ChekinanaChekiCard] = []
        for item in prepared {
            let id = UUID()
            let createdAt = Date()
            let code = confirmationLedger.insert(.addCheki(.init(
                id: id,
                temporaryChekiID: nil,
                image: item.image,
                thumbnailImageData: item.thumbnailImageData,
                idolIDs: fields.idolIDs,
                eventID: event?.id,
                date: fields.eventDate,
                userAppears: fields.userAppears,
                size: fields.size,
                isFavorite: false,
                hasPostedToSNS: false,
                note: fields.note,
                createdAt: createdAt,
                requestedIdx: nil,
                existingChekiID: nil,
                explicitlyEditedFields: eventWasExplicitlySpecified ? [.event] : []
            )))
            cards.append(ChekinanaChekiCard(
                id: id,
                imageRef: nil,
                createdAt: createdAt,
                confirmationCode: code,
                thumbnailImageData: item.thumbnailImageData,
                idolNames: idols.map(\.name),
                eventName: event?.name,
                eventDateText: fields.eventDate.map(calendarDateString),
                note: fields.note,
                dateAnnotationState: .notRequested
            ))
        }
        let failureSuffix = failedCount == 0 ? "" : ChekinanaCommandCopy.quantity(
            "cheki.album_unreadable_suffix",
            count: failedCount,
            one: "; %lld other photo could not be read",
            other: "; %lld other photos could not be read"
        )
        return .pendingChekiCards(
            ChekinanaCommandCopy.quantity(
                "cheki.album_prepared",
                count: cards.count,
                one: "Prepared %lld Cheki from the photo library",
                other: "Prepared %lld chekis from the photo library"
            ) + failureSuffix + ".",
            cards,
            consumesSelectedPhotos: false
        )
    }

    func confirmTemporaryChekiBatch(
        confirmationCodes: [String]
    ) async -> ChekinanaCommandResponse {
        let normalizedCodes = confirmationCodes.map(
            ChekinanaConfirmationLedger.normalizedCode
        )
        guard !normalizedCodes.isEmpty,
              Set(normalizedCodes).count == normalizedCodes.count else {
            return .text(ChekinanaCommandCopy.error(
                "cheki.invalid_batch_confirmation",
                fallback: "Invalid or duplicate Cheki confirmation."
            ))
        }
        let entries = normalizedCodes.compactMap(confirmationLedger.entry(for:))
        guard entries.count == normalizedCodes.count,
              confirmationLedger.isValidTemporaryChekiBatch(entries) else {
            return .text(ChekinanaCommandCopy.error(
                "cheki.temporary_changed",
                fallback: "One or more temporary Cheki changed before saving."
            ))
        }
        guard let reservation = confirmationLedger.reserveTemporaryChekiBatch(entries) else {
            return .text(ChekinanaCommandCopy.error(
                "cheki.batch_already_saving",
                fallback: "This temporary Cheki batch is already being saved."
            ))
        }

        typealias BatchItem = (
            payload: ChekinanaConfirmationLedger.AddChekiPayload,
            imageStorageID: UUID,
            idx: Int?,
            indexStrategy: ChekinanaBatchIndexStrategy
        )
        var batch: [BatchItem] = []
        batch.reserveCapacity(entries.count)
        do {
            let snapshotActor = ChekinanaBatchSnapshotActor(
                modelContainer: modelContext.container
            )
            let snapshots = try await snapshotActor.chekiSnapshots()
            let existingByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
            let existingIDs = Set(existingByID.keys)
            var maximumByGroup: [ChekinanaChekiGroupKey: Int] = [:]
            var ownersByIndex: [ChekinanaBatchIndexKey: Set<UUID>] = [:]
            for snapshot in snapshots {
                guard let group = ChekinanaChekiGroupKey(
                    idolIDs: snapshot.idolIDs,
                    date: snapshot.date
                ), let idx = snapshot.idx else { continue }
                maximumByGroup[group] = max(maximumByGroup[group] ?? 0, idx)
                ownersByIndex[.init(group: group, idx: idx), default: []].insert(snapshot.id)
            }

            var newIDs = Set<UUID>()
            var matchedIDs = Set<UUID>()
            for entry in entries {
                guard case .addCheki(let payload) = entry.action,
                      payload.temporaryChekiID != nil else {
                    throw ChekinanaAddChekiError.duplicateCheki(entry.code)
                }
                let existing = payload.existingChekiID.flatMap { existingByID[$0] }
                if let existingChekiID = payload.existingChekiID {
                    guard existingChekiID == payload.id,
                          let existing,
                          ChekinanaNoMediaPolicy.hasNoImage(existing.imageRef),
                          matchedIDs.insert(existingChekiID).inserted,
                          let existingDate = existing.date,
                          let payloadDate = payload.date,
                          sameCalendarDate(existingDate, payloadDate),
                          Set(existing.idolIDs) == Set(payload.idolIDs) else {
                        throw ChekinanaAddChekiError.duplicateCheki(entry.code)
                    }
                } else {
                    guard !existingIDs.contains(payload.id),
                          newIDs.insert(payload.id).inserted else {
                        throw ChekinanaAddChekiError.duplicateCheki(entry.code)
                    }
                }

                let group = ChekinanaChekiGroupKey(
                    idolIDs: payload.idolIDs,
                    date: payload.date
                )
                let idx: Int?
                let indexStrategy: ChekinanaBatchIndexStrategy
                if payload.explicitlyEditedFields.contains(.idx) {
                    if payload.requestedIdx != nil, group == nil {
                        throw ChekinanaAddChekiError.indexOverflow
                    }
                    if let group, let requestedIdx = payload.requestedIdx {
                        let key = ChekinanaBatchIndexKey(group: group, idx: requestedIdx)
                        let allowedOwner = payload.existingChekiID
                        let owners = ownersByIndex[key, default: []]
                        let hasConflictingOwner = owners.contains { owner in
                            owner != allowedOwner
                        }
                        guard requestedIdx > 0,
                              !hasConflictingOwner,
                              owners.count <= (allowedOwner == nil ? 0 : 1) else {
                            throw ChekinanaAddChekiError.duplicateIndex(requestedIdx)
                        }
                        ownersByIndex[key, default: []].insert(payload.id)
                        maximumByGroup[group] = max(maximumByGroup[group] ?? 0, requestedIdx)
                    }
                    idx = payload.requestedIdx
                    indexStrategy = .explicit(payload.requestedIdx)
                } else if let existing {
                    idx = existing.idx
                    indexStrategy = .preserveExisting
                } else if let group {
                    let current = maximumByGroup[group] ?? 0
                    guard current < Int.max else { throw ChekinanaAddChekiError.indexOverflow }
                    let next = current + 1
                    maximumByGroup[group] = next
                    ownersByIndex[.init(group: group, idx: next), default: []].insert(payload.id)
                    idx = next
                    indexStrategy = .automatic
                } else {
                    idx = nil
                    indexStrategy = .none
                }
                batch.append((
                    payload,
                    // Managed Cheki files are resolved and ownership-checked
                    // by the record UUID for both new and attached records.
                    payload.id,
                    idx,
                    indexStrategy
                ))
            }
        } catch {
            confirmationLedger.releaseTemporaryChekiBatchReservation(reservation)
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }

        var lastProgress: ChekinanaTemporaryChekiBatchProgress?
        var lastProgressPublicationUptime: TimeInterval = 0
        func publish(_ stage: ChekinanaTemporaryChekiBatchStage, _ completed: Int) {
            let progress = ChekinanaTemporaryChekiBatchProgress(
                stage: stage,
                completed: completed,
                total: batch.count
            )
            guard progress != lastProgress else { return }
            let uptime = ProcessInfo.processInfo.systemUptime
            let mustPublish = lastProgress?.stage != stage
                || completed == 0
                || completed == batch.count
                || uptime - lastProgressPublicationUptime >= 0.05
            guard mustPublish else { return }
            lastProgress = progress
            lastProgressPublicationUptime = uptime
            batchSaveProgressObserver?(progress)
        }

        publish(.preparingImages, 0)
        var savedImages = Array<SavedChekiImage?>(repeating: nil, count: batch.count)
        var preparationFailures: [String] = []
        let preparationLimiter = batchImagePreparationLimiter
        await withTaskGroup(
            of: (Int, saved: SavedChekiImage?, failure: String?).self
        ) { group in
            for (index, item) in batch.enumerated() {
                let imageData = item.payload.image.data
                let imageID = item.imageStorageID
                let filenameExtension = item.payload.image.filenameExtension
                group.addTask {
                    do {
                        let saved = try await preparationLimiter.perform {
                            try await ChekinanaImageWorker.saveChekiImageData(
                                imageData,
                                id: imageID,
                                filenameExtension: filenameExtension
                            )
                        }
                        return (index, saved, nil)
                    } catch {
                        return (index, nil, error.localizedDescription)
                    }
                }
            }
            var completed = 0
            for await (index, saved, failure) in group {
                completed += 1
                if let saved { savedImages[index] = saved }
                if let failure { preparationFailures.append(failure) }
                publish(.preparingImages, completed)
            }
        }

        if Task.isCancelled || !preparationFailures.isEmpty
            || !confirmationLedger.isValidTemporaryChekiBatch(entries) {
            for image in savedImages.compactMap({ $0 }) {
                await ChekinanaImageWorker.removeItemIfPresent(at: image.url)
            }
            confirmationLedger.releaseTemporaryChekiBatchReservation(reservation)
            if Task.isCancelled {
                return .text(ChekinanaCommandCopy.error(
                    "operation.cancelled",
                    fallback: "Cancelled."
                ))
            }
            return .text(ChekinanaCommandCopy.error(
                "cheki.preparation_failed",
                fallback: "Cheki preparation failed: %@",
                preparationFailures.first ?? ChekinanaCommandCopy.text(
                    "cheki.temporary_changed_detail",
                    fallback: "A temporary Cheki changed before saving."
                )
            ))
        }

        publish(.savingRecords, 0)
        var savedModels: [Cheki] = []
        do {
            try batchBeforeLiveIndexValidation?()
            let requiredIdolIDs = Array(Set(batch.flatMap { $0.payload.idolIDs }))
            let idolDescriptor = FetchDescriptor<Idol>(predicate: #Predicate { idol in
                requiredIdolIDs.contains(idol.id)
            })
            let relationIdolModels = try modelContext.fetch(idolDescriptor)
            let idolsByID = Dictionary(
                uniqueKeysWithValues: relationIdolModels.map { ($0.id, $0) }
            )
            // Events are cheap local metadata. Fetch the complete current set
            // so unspecified associations can be resolved atomically at the
            // final target-context write boundary.
            let relationEventModels = try modelContext.fetch(FetchDescriptor<Event>())
            let eventsByID = Dictionary(
                uniqueKeysWithValues: relationEventModels.map { ($0.id, $0) }
            )
            let targetIDs = batch.compactMap { $0.payload.existingChekiID }
            let targetDescriptor = FetchDescriptor<Cheki>(predicate: #Predicate { cheki in
                targetIDs.contains(cheki.id)
            })
            let targets = try modelContext.fetch(targetDescriptor)
            let targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })

            // The background snapshot is only an early planning aid. Refresh
            // every involved canonical day immediately before the synchronous
            // MainActor mutation/save boundary so another completed save
            // cannot leave this batch with stale automatic or explicit idx.
            var relevantDatesByKey: [String: Date] = [:]
            for item in batch {
                guard ChekinanaChekiGroupKey(
                    idolIDs: item.payload.idolIDs,
                    date: item.payload.date
                ) != nil,
                    let date = normalizedCalendarDay(item.payload.date) else {
                    continue
                }
                relevantDatesByKey[ChekinanaDateOnly.string(date)] = date
            }
            var liveChekisByID: [UUID: Cheki] = [:]
            for canonicalDate in relevantDatesByKey.values {
                let rangeStart = canonicalDate
                let rangeEnd = canonicalDate.addingTimeInterval(24 * 60 * 60)
                let descriptor = FetchDescriptor<Cheki>(predicate: #Predicate { cheki in
                    if let storedDate = cheki.date {
                        storedDate >= rangeStart && storedDate < rangeEnd
                    } else {
                        false
                    }
                })
                for cheki in try modelContext.fetch(descriptor) {
                    // Keep the DateOnly group key authoritative even for
                    // legacy rows whose stored value is not canonical midnight.
                    guard let storedDate = cheki.date,
                          relevantDatesByKey[ChekinanaDateOnly.string(storedDate)] != nil else {
                        continue
                    }
                    liveChekisByID[cheki.id] = cheki
                }
            }
            var liveMaximumByGroup: [ChekinanaChekiGroupKey: Int] = [:]
            var liveOwnersByIndex: [ChekinanaBatchIndexKey: Set<UUID>] = [:]
            for cheki in liveChekisByID.values {
                guard let group = ChekinanaChekiGroupKey(
                    idolIDs: cheki.idols.map(\.id),
                    date: cheki.date
                ), let idx = cheki.idx else { continue }
                liveMaximumByGroup[group] = max(liveMaximumByGroup[group] ?? 0, idx)
                liveOwnersByIndex[.init(group: group, idx: idx), default: []]
                    .insert(cheki.id)
            }
            for index in batch.indices {
                let payload = batch[index].payload
                let group = ChekinanaChekiGroupKey(
                    idolIDs: payload.idolIDs,
                    date: payload.date
                )
                switch batch[index].indexStrategy {
                case .none:
                    batch[index].idx = nil
                case .preserveExisting:
                    guard let existingID = payload.existingChekiID,
                          let target = targetsByID[existingID] else {
                        throw ChekinanaAddChekiError.duplicateCheki(payload.id.uuidString)
                    }
                    batch[index].idx = target.idx
                case .explicit(let requestedIdx):
                    guard let requestedIdx else {
                        batch[index].idx = nil
                        continue
                    }
                    guard requestedIdx > 0, let group else {
                        throw ChekinanaAddChekiError.indexOverflow
                    }
                    let key = ChekinanaBatchIndexKey(group: group, idx: requestedIdx)
                    let allowedOwner = payload.existingChekiID
                    let owners = liveOwnersByIndex[key, default: []]
                    guard !owners.contains(where: { $0 != allowedOwner }),
                          owners.count <= (allowedOwner == nil ? 0 : 1) else {
                        throw ChekinanaAddChekiError.duplicateIndex(requestedIdx)
                    }
                    liveOwnersByIndex[key, default: []].insert(payload.id)
                    liveMaximumByGroup[group] = max(
                        liveMaximumByGroup[group] ?? 0,
                        requestedIdx
                    )
                    batch[index].idx = requestedIdx
                case .automatic:
                    guard let group else {
                        batch[index].idx = nil
                        continue
                    }
                    let current = liveMaximumByGroup[group] ?? 0
                    guard current < Int.max else {
                        throw ChekinanaAddChekiError.indexOverflow
                    }
                    let next = current + 1
                    liveMaximumByGroup[group] = next
                    liveOwnersByIndex[.init(group: group, idx: next), default: []]
                        .insert(payload.id)
                    batch[index].idx = next
                }
            }

            for (index, item) in batch.enumerated() {
                try Task.checkCancellation()
                guard let savedImage = savedImages[index] else {
                    throw ChekinanaScanChekiError.invalidResultImage
                }
                let idolIDs = Set(item.payload.idolIDs)
                let relationIdols = item.payload.idolIDs.compactMap { idolsByID[$0] }
                guard relationIdols.count == idolIDs.count else {
                    throw ChekinanaAddChekiError.modelContextMismatch
                }
                let explicitEvent = item.payload.explicitlyEditedFields.contains(.event)
                let existingEvent = item.payload.existingChekiID.flatMap {
                    targetsByID[$0]?.event
                }
                let autoEventID = ChekinanaChekiEventAutoAssociation.uniqueEventID(
                    for: item.payload.date,
                    events: relationEventModels.map { ($0.id, $0.date) },
                    calendar: calendar
                )
                let relationEvent = explicitEvent
                    ? item.payload.eventID.flatMap { eventsByID[$0] }
                    : (existingEvent ?? autoEventID.flatMap { eventsByID[$0] })
                guard !explicitEvent || item.payload.eventID == nil || relationEvent != nil else {
                    throw ChekinanaAddChekiError.modelContextMismatch
                }
                try validateChekiAssociations(
                    idols: relationIdols,
                    event: relationEvent,
                    eventDate: item.payload.date
                )

                if let existingChekiID = item.payload.existingChekiID {
                    guard let cheki = targetsByID[existingChekiID],
                          ChekinanaNoMediaPolicy.hasNoImage(cheki.imageRef),
                          let existingDate = cheki.date,
                          let selectedDate = item.payload.date,
                          sameCalendarDate(existingDate, selectedDate),
                          Set(cheki.idols.map(\.id)) == idolIDs,
                          cheki.modelContext === modelContext else {
                        throw ChekinanaAddChekiError.duplicateCheki(existingChekiID.uuidString)
                    }
                    cheki.imageRef = savedImage.ref
                    let edited = item.payload.explicitlyEditedFields
                    if edited.contains(.idols) { cheki.idols = relationIdols }
                    if edited.contains(.date) { cheki.date = normalizedCalendarDay(item.payload.date) }
                    if edited.contains(.event) || cheki.event == nil { cheki.event = relationEvent }
                    if edited.contains(.userAppears) || cheki.userAppears == nil {
                        cheki.userAppears = item.payload.userAppears
                    }
                    if edited.contains(.size) { cheki.size = item.payload.size }
                    if edited.contains(.favorite) { cheki.isFavorite = item.payload.isFavorite }
                    if edited.contains(.posted) { cheki.hasPostedToSNS = item.payload.hasPostedToSNS }
                    if edited.contains(.note) { cheki.note = item.payload.note }
                    if edited.contains(.idx) { cheki.idx = item.idx }
                    cheki.updatedAt = Date()
                    savedModels.append(cheki)
                } else {
                    let cheki = Cheki(
                        id: item.payload.id,
                        date: normalizedCalendarDay(item.payload.date),
                        idx: item.idx,
                        userAppears: item.payload.userAppears,
                        size: item.payload.size,
                        imageRef: savedImage.ref,
                        isFavorite: item.payload.isFavorite,
                        hasPostedToSNS: item.payload.hasPostedToSNS,
                        note: item.payload.note,
                        createdAt: item.payload.createdAt
                    )
                    modelContext.insert(cheki)
                    guard cheki.modelContext === modelContext,
                          relationIdols.allSatisfy({ $0.modelContext === modelContext }),
                          relationEvent.map({ $0.modelContext === modelContext }) ?? true else {
                        throw ChekinanaAddChekiError.modelContextMismatch
                    }
                    cheki.idols = relationIdols
                    cheki.event = relationEvent
                    savedModels.append(cheki)
                }
                publish(.savingRecords, index + 1)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            for image in savedImages.compactMap({ $0 }) {
                await ChekinanaImageWorker.removeItemIfPresent(at: image.url)
            }
            confirmationLedger.releaseTemporaryChekiBatchReservation(reservation)
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }

        // From this point onward the database references every prepared file.
        // Finalization is deliberately nonthrowing; even a recovery outcome is
        // a committed success and must never enter file cleanup/rollback.
        publish(.finalizing, 0)
        _ = confirmationLedger.finalizeTemporaryChekiBatchReservation(
            reservation,
            simulateInvariantFailure: simulateBatchFinalizeInvariantFailure
        )
        publish(.finalizing, batch.count)
        return .chekiCards(savedModels.enumerated().map { index, cheki in
            chekiCard(
                for: cheki,
                thumbnailImageData: batch[index].payload.thumbnailImageData
            )
        })
    }

    private func addScanCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) -> ChekinanaCommandResponse {
        let allowed = Set(["idol", "idols", "event", "date", "user", "userappears", "size", "note"])
        guard let target = command.target,
              command.arguments.keys.allSatisfy(allowed.contains),
              !(command.arguments["idol"] != nil && command.arguments["idols"] != nil) else {
            return invalidUsage(usage)
        }
        do {
            var arguments = command.arguments
            arguments.removeValue(forKey: "idols")
            if let idolValue = command.arguments["idol"] ?? command.arguments["idols"] {
                arguments["idol"] = idolValue
            }
            if let userAppears = arguments.removeValue(forKey: "userappears") {
                guard arguments["user"] == nil else {
                    throw ChekinanaAddChekiError.duplicateArgument("user")
                }
                arguments["user"] = userAppears
            }
            let temporaryValues = try confirmationLedger.resolveTemporaryChekis(target)
            let fields = try resolvedAddChekiFields(
                arguments,
                allowMissingAssociation: true,
                allowMissingIdols: true
            )
            let idolIDLists = temporaryValues.map { temporary -> [UUID] in
                if !fields.idolIDs.isEmpty {
                    return fields.idolIDs
                }
                return temporary.idolIDs
            }
            let idolsPerResult = try idolIDLists.map {
                try refetchIdolsByIDs($0)
            }
            let prepared = try temporaryValues.enumerated().map {
                index,
                temporary -> (
                    id: UUID,
                    createdAt: Date,
                    payload: ChekinanaConfirmationLedger.AddChekiPayload,
                    temporary: ChekinanaConfirmationLedger.TemporaryCheki,
                    idols: [Idol],
                    event: Event?,
                    date: Date?,
                    userAppears: Bool?,
                    size: ChekiSize?,
                    note: String
                ) in
                let id = temporary.existingChekiID ?? UUID()
                let existingTarget = try temporary.existingChekiID.map {
                    try refetchChekiByID($0)
                }
                let createdAt = Date()
                let date = fields.eventDate ?? temporary.date
                let eventID = fields.eventID ?? temporary.eventID
                let event = try refetchEventByID(eventID)
                let idols = idolsPerResult[index]
                let userAppears = fields.userAppears ?? temporary.userAppears
                let size = fields.size ?? temporary.size
                let note = fields.note.isEmpty ? temporary.note : fields.note
                let payload = ChekinanaConfirmationLedger.AddChekiPayload(
                    id: id,
                    temporaryChekiID: temporary.id,
                    image: temporary.image,
                    thumbnailImageData: temporary.thumbnailImageData,
                    idolIDs: idols.map(\.id),
                    eventID: eventID,
                    date: date,
                    userAppears: userAppears,
                    size: size,
                    isFavorite: temporary.isFavorite,
                    hasPostedToSNS: temporary.hasPostedToSNS,
                    note: note,
                    createdAt: createdAt,
                    requestedIdx: temporary.idx,
                    existingChekiID: temporary.existingChekiID,
                    existingChekiExpectedUpdatedAt: existingTarget?.updatedAt,
                    explicitlyEditedFields: temporary.explicitlyEditedFields
                )
                return (
                    id: id,
                    createdAt: createdAt,
                    payload: payload,
                    temporary: temporary,
                    idols: idols,
                    event: event,
                    date: date,
                    userAppears: userAppears,
                    size: size,
                    note: note
                )
            }

            // Preparing a batch is atomic: no confirmation may protect a
            // temporary image until every item has been fully validated.
            var cards: [ChekinanaChekiCard] = []
            cards.reserveCapacity(prepared.count)
            for item in prepared {
                let code = confirmationLedger.insert(.addCheki(item.payload))
                cards.append(.init(
                    id: item.id,
                    imageRef: nil,
                    createdAt: item.createdAt,
                    confirmationCode: code,
                    thumbnailImageData: item.temporary.thumbnailImageData,
                    idolNames: item.idols.map(\.name),
                    eventName: item.event?.name,
                    eventDateText: item.date.map(calendarDateString),
                    userAppears: item.userAppears,
                    size: item.size,
                    isFavorite: item.temporary.isFavorite,
                    hasPostedToSNS: item.temporary.hasPostedToSNS,
                    note: item.note,
                    dateAnnotationState: item.temporary.dateAnnotationState
                ))
            }
            return .pendingChekiCards(
                ChekinanaCommandCopy.quantity(
                    "cheki.scan_results_prepared",
                    count: cards.count,
                    one: "Prepared %lld scan result to save.",
                    other: "Prepared %lld scan results to save."
                ),
                cards,
                consumesSelectedPhotos: false
            )
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private struct ResolvedAddChekiFields {
        let idolIDs: [UUID]
        let eventID: UUID?
        let eventDate: Date?
        let userAppears: Bool?
        let size: ChekiSize?
        let note: String
    }

    private func resolvedAddChekiFields(
        _ arguments: [String: String],
        allowMissingAssociation: Bool = false,
        allowMissingIdols: Bool = false
    ) throws -> ResolvedAddChekiFields {
        let idols = try arguments["idol"].map { try resolveIdolList($0) } ?? []
        let rawEvent = arguments["event"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDate = arguments["date"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasEvent = rawEvent.map { !$0.isEmpty && $0 != "?" && $0 != "-" } ?? false
        let hasDate = rawDate.map { !$0.isEmpty && $0 != "?" && $0 != "-" } ?? false
        let event = hasEvent ? try resolveEvent(rawEvent) : nil
        let eventDate = hasDate ? try parseCalendarDate(rawDate ?? "") : nil
        let noteValue = arguments["note"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ResolvedAddChekiFields(
            idolIDs: idols.map(\.id),
            eventID: event?.id,
            eventDate: eventDate,
            userAppears: try parseOptionalBool(arguments["user"], argumentName: "user"),
            size: try parseOptionalChekiSize(arguments["size"]),
            note: noteValue == "-" ? "" : (noteValue ?? "")
        )
    }

    private func inferredCalendarDate(
        from state: ChekinanaChekiDateAnnotationState,
        bounds: ChekinanaScannerDateBounds?
    ) -> Date? {
        guard let bounds else { return nil }
        if let fixedDate = bounds.fixedDate { return fixedDate }
        guard case .detected(let annotation) = state else {
            return nil
        }

        let inferred: Date?
        switch annotation.precision {
        case .fullDate:
            inferred = try? parseCalendarDate(
                annotation.text.replacingOccurrences(of: ".", with: "-")
            )
        case .monthDay:
            inferred = ChekinanaMonthDayDateInferrer.date(
                from: annotation.text,
                within: bounds,
                calendar: calendar
            )
        }
        guard let inferred, bounds.contains(inferred) else { return nil }
        return inferred
    }

    private func uniqueEventID(
        for inferredDate: Date?,
        candidates: [ChekinanaEventDateCandidate]
    ) -> UUID? {
        guard let inferredDate else { return nil }
        let matches = candidates.filter { candidate in
            guard let candidateDate = candidate.date else { return false }
            return sameCalendarDate(candidateDate, inferredDate)
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    private func scanCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String],
        pendingImages: [ChekinanaPendingChekiImage]
    ) async -> ChekinanaCommandResponse {
        let allowedArguments = Set([
            "expected", "scanner_size", "postprocess", "wb", "sleeves", "direct",
            "date_recognition", "date_scope", "date_from", "date_to",
            "idol_recognition", "candidates", "idol_threshold",
        ])
        guard command.arguments.keys.allSatisfy(allowedArguments.contains),
              command.target == nil else {
            return invalidUsage(usage)
        }

        var holdsDirectCommitGate = false
        do {
            try Task.checkCancellation()
            let options = try scanChekiOptions(from: command)
            guard !pendingImages.isEmpty else {
                return .text(ChekinanaCommandCopy.error(
                    "scan.select_photos",
                    fallback: "Select one or more photos with the photo-library button before scanning."
                ))
            }

            var scannedImages: [ChekinanaPendingChekiImage] = []
            var dateAnnotationStates: [ChekinanaChekiDateAnnotationState] = []
            var scannerMetadata: [ChekinanaTemporaryScannerMetadata] = []
            var sourceAnnotations: [ChekinanaScannerSourceAnnotation?] = []
            var inferredSizes: [ChekiSize?] = []
            var warningCount = 0
            let progressState = ScanProgressState()
            let progressGate = ChekinanaScanProgressGate()
            func makeProgress(
                sourceIndex: Int,
                stage: ChekinanaScanProgress.Stage
            ) -> ChekinanaScanProgress {
                ChekinanaScanProgress(
                    sourceIndex: sourceIndex,
                    sourceCount: pendingImages.count,
                    publishedResultCount: progressState.totalPublishedCount,
                    downloadedResultCount: progressState.totalDownloadedCount,
                    preparedResultCount: progressState.preparedResultCount,
                    stage: stage,
                    imageProcessedCount: progressState.imageProcessedCount,
                    dateCompletedCount: progressState.dateCompletedCount,
                    dateTotalCount: progressState.dateTotalCount,
                    idolCompletedCount: progressState.idolCompletedCount,
                    idolTotalCount: progressState.idolTotalCount
                )
            }
            func emitProgress(
                _ progress: () -> ChekinanaScanProgress
            ) {
                guard !Task.isCancelled else { return }
                progressGate.performIfActive {
                    guard !Task.isCancelled else { return }
                    let value = progress()
                    scanProgressObserver?(value)
                }
            }
            let recognitionTasks = RecognitionTaskRegistry()
            func recognitionTask(
                sourceIndex: Int,
                resultIndex: Int,
                resultCount: Int,
                resultImage: ChekinanaScannerResultImage
            ) -> Task<RecognitionResolution, Never> {
                let key = RecognitionTaskKey(
                    sourceIndex: sourceIndex,
                    resultIndex: resultIndex
                )
                if let existing = recognitionTasks.task(for: key) { return existing }
                progressState.discoverResult(
                    sourceIndex: sourceIndex,
                    resultIndex: resultIndex,
                    options: options
                )
                emitProgress {
                    makeProgress(
                        sourceIndex: sourceIndex,
                        stage: .preparingResult(
                            index: resultIndex + 1,
                            count: max(resultCount, resultIndex + 1),
                            recognizesIdol: options.idolRecognitionCandidates != nil
                        )
                    )
                }
                let task = Task { @MainActor in
                    var annotationState = ChekinanaChekiDateAnnotationState.notRequested
                    var matchedIdolID: UUID?
                    var userAppears: Bool?
                    var recognitionWarnings = 0
                    var wasCancelled = false
                    await withTaskGroup(of: RecognitionProgressEvent.self) { group in
                        group.addTask {
                            .date(await dateRecognitionOutcome(
                                resultImage: resultImage,
                                bounds: options.dateBounds,
                                filenameExtension: options.directInputEnabled ? "jpg" : "png",
                                requestGate: directDateRequestGate
                            ))
                        }
                        group.addTask {
                            .idol(await idolRecognitionOutcome(
                                resultImage: resultImage,
                                candidates: options.idolRecognitionCandidates,
                                recognitionGate: directRecognitionGate
                            ))
                        }
                        group.addTask {
                            .userAppears(await userAppearsRecognitionOutcome(
                                resultImage: resultImage
                            ))
                        }
                        for await event in group {
                            if Task.isCancelled {
                                wasCancelled = true
                                group.cancelAll()
                                continue
                            }
                            switch event {
                            case .date(.notRequested):
                                break
                            case .date(.completed(let state)):
                                annotationState = state
                                if !options.usesFixedDate {
                                    progressState.dateCompletedCount += 1
                                }
                                if state == .unavailable { recognitionWarnings += 1 }
                            case .date(.cancelled), .idol(.cancelled),
                                    .userAppears(.cancelled):
                                wasCancelled = true
                                group.cancelAll()
                            case .idol(.notRequested):
                                break
                            case .idol(.matched(let idolID)):
                                matchedIdolID = idolID
                                if options.directIdolCandidateID == nil {
                                    progressState.idolCompletedCount += 1
                                }
                            case .idol(.failed):
                                recognitionWarnings += 1
                                progressState.idolCompletedCount += 1
                            case .userAppears(.completed(let value)):
                                userAppears = value
                            case .userAppears(.unavailable):
                                recognitionWarnings += 1
                            }
                            emitProgress {
                                makeProgress(
                                    sourceIndex: sourceIndex,
                                    stage: .preparingResult(
                                        index: resultIndex + 1,
                                        count: max(resultCount, resultIndex + 1),
                                        recognizesIdol: options.idolRecognitionCandidates != nil
                                    )
                                )
                            }
                        }
                    }
                    return RecognitionResolution(
                        dateState: annotationState,
                        matchedIdolID: matchedIdolID,
                        userAppears: userAppears,
                        warningCount: recognitionWarnings,
                        isCancelled: wasCancelled || Task.isCancelled
                    )
                }
                recognitionTasks.insert(task, for: key)
                return task
            }
            let sourceTasks = pendingImages.enumerated().map { sourceOffset, pendingImage in
                let sourceIndex = sourceOffset + 1
                return Task { @MainActor () -> SourceScanOutcome in
                    emitProgress {
                        progressState.beginSource(sourceIndex)
                        return makeProgress(
                            sourceIndex: sourceIndex,
                            stage: .backend(
                                phase: nil,
                                publishedForSource: 0,
                                downloadedForSource: 0,
                                expectedForSource: options.expectedPolaroids
                            )
                        )
                    }
                    do {
                        let result = try await scannerProcessWithProgress(
                            pendingImage,
                            options,
                            { progress in
                                emitProgress {
                                    progressState.update(
                                        sourceIndex: sourceIndex,
                                        progress: progress
                                    )
                                    return makeProgress(
                                        sourceIndex: sourceIndex,
                                        stage: .backend(
                                            phase: progress.phase,
                                            publishedForSource: progressState.publishedCount(
                                                for: sourceIndex
                                            ),
                                            downloadedForSource: progressState.downloadedCount(
                                                for: sourceIndex
                                            ),
                                            expectedForSource: progress.expectedPolaroids
                                        )
                                    )
                                }
                            },
                            { resultIndex, resultImage in
                                _ = recognitionTask(
                                    sourceIndex: sourceIndex,
                                    resultIndex: resultIndex,
                                    resultCount: resultIndex + 1,
                                    resultImage: resultImage
                                )
                            }
                        )
                        try Task.checkCancellation()
                        emitProgress {
                            progressState.recordFallbackResultCount(
                                result.images.count,
                                sourceIndex: sourceIndex
                            )
                            progressState.finishImageSource(
                                sourceIndex: sourceIndex,
                                resultCount: result.images.count,
                                options: options
                            )
                            return makeProgress(
                                sourceIndex: sourceIndex,
                                stage: .backend(
                                    phase: "complete",
                                    publishedForSource: progressState.publishedCount(
                                        for: sourceIndex
                                    ),
                                    downloadedForSource: progressState.downloadedCount(
                                        for: sourceIndex
                                    ),
                                    expectedForSource: options.expectedPolaroids
                                )
                            )
                        }
                        return SourceScanOutcome.success(result)
                    } catch is CancellationError {
                        return SourceScanOutcome.cancelled
                    } catch {
                        emitProgress {
                            progressState.finishImageSource(
                                sourceIndex: sourceIndex,
                                resultCount: 0,
                                options: options
                            )
                            return makeProgress(
                                sourceIndex: sourceIndex,
                                stage: .backend(
                                    phase: "failed",
                                    publishedForSource: progressState.publishedCount(for: sourceIndex),
                                    downloadedForSource: progressState.downloadedCount(for: sourceIndex),
                                    expectedForSource: options.expectedPolaroids
                                )
                            )
                        }
                        return Task.isCancelled
                            ? SourceScanOutcome.cancelled
                            : SourceScanOutcome.failed
                    }
                }
            }
            do {
                try await withTaskCancellationHandler {
                    var directOutcomes: [SourceScanOutcome] = []
                    if options.directInputEnabled {
                        for sourceTask in sourceTasks {
                            directOutcomes.append(await sourceTask.value)
                        }
                        try Task.checkCancellation()
                    }
                    for (sourceOffset, sourceTask) in sourceTasks.enumerated() {
                        let sourceIndex = sourceOffset + 1
                        let outcome = options.directInputEnabled
                            ? directOutcomes[sourceOffset]
                            : await sourceTask.value
                    try Task.checkCancellation()
                    let result: ChekinanaScannerProcessResult
                    switch outcome {
                    case .success(let scannerResult):
                        result = scannerResult
                    case .failed:
                        warningCount += 1
                        continue
                    case .cancelled:
                        throw CancellationError()
                    }
                    warningCount += result.warningCount

                    for (resultOffset, resultImage) in result.images.enumerated() {
                        try Task.checkCancellation()
                        let resultIndex = resultOffset + 1
                        emitProgress {
                            makeProgress(
                                sourceIndex: sourceIndex,
                                stage: .preparingResult(
                                    index: resultIndex,
                                    count: result.images.count,
                                    recognizesIdol: options.idolRecognitionCandidates != nil
                                )
                            )
                        }
                        let recognition = await recognitionTask(
                            sourceIndex: sourceIndex,
                            resultIndex: resultOffset,
                            resultCount: result.images.count,
                            resultImage: resultImage
                        ).value
                        if recognition.isCancelled { throw CancellationError() }
                        let annotationState = recognition.dateState
                        let matchedIdolID = recognition.matchedIdolID
                        let userAppears = recognition.userAppears
                        warningCount += recognition.warningCount
                        try Task.checkCancellation()
                        if let directCommitGate, let directCommitIndex,
                           !holdsDirectCommitGate {
                            try await directCommitGate.acquire(index: directCommitIndex)
                            holdsDirectCommitGate = true
                        }
                        let jpegResult = await persistentJPEGData(
                            resultImage,
                            alreadyJPEG: options.directInputEnabled
                        )
                        guard let jpegData = jpegResult, !jpegData.isEmpty else {
                            warningCount += 1
                            continue
                        }
                        scannedImages.append(ChekinanaPendingChekiImage(
                            data: jpegData,
                            filenameExtension: "jpg",
                            sourceID: pendingImages[sourceOffset].sourceID,
                            sourceOrigin: pendingImages[sourceOffset].sourceOrigin
                        ))
                        dateAnnotationStates.append(annotationState)
                        sourceAnnotations.append(resultImage.sourceAnnotation)
                        scannerMetadata.append(ChekinanaTemporaryScannerMetadata(
                            matchedIdolID: matchedIdolID,
                            userAppears: userAppears
                        ))
                        inferredSizes.append(
                            resultImage.inferredChekiSize
                                ?? (options.directInputEnabled ? nil : .mini)
                        )
                        emitProgress {
                            progressState.preparedResultCount += 1
                            return makeProgress(
                                sourceIndex: sourceIndex,
                                stage: .preparingResult(
                                    index: resultIndex,
                                    count: result.images.count,
                                    recognizesIdol: options.idolRecognitionCandidates != nil
                                )
                            )
                        }
                    }
                    }
                } onCancel: {
                    progressGate.invalidate()
                    sourceTasks.forEach { $0.cancel() }
                    recognitionTasks.cancelAll()
                }
            } catch {
                progressGate.invalidate()
                sourceTasks.forEach { $0.cancel() }
                recognitionTasks.cancelAll()
                for sourceTask in sourceTasks {
                    _ = await sourceTask.value
                }
                for recognitionTask in recognitionTasks.snapshot() {
                    _ = await recognitionTask.value
                }
                throw error
            }
            guard !scannedImages.isEmpty else {
                throw ChekinanaScanChekiError.noResultImages
            }

            try Task.checkCancellation()
            emitProgress {
                makeProgress(
                    sourceIndex: pendingImages.count,
                    stage: .generatingPreview
                )
            }
            let thumbnails = await ChekinanaImageWorker.thumbnailDataBatch(
                from: scannedImages.map(\.data)
            )
            try Task.checkCancellation()
            let eventCandidates = try modelContext.fetch(FetchDescriptor<Event>()).map {
                ChekinanaEventDateCandidate(id: $0.id, date: $0.date)
            }
            let inferredDates = dateAnnotationStates.map {
                inferredCalendarDate(from: $0, bounds: options.dateBounds)
            }
            let normalizedDateAnnotationStates = zip(dateAnnotationStates, inferredDates).map {
                state, inferredDate in
                if options.dateBounds?.scope == .fixed {
                    return ChekinanaChekiDateAnnotationState.notRequested
                }
                if case .detected = state, inferredDate == nil {
                    return ChekinanaChekiDateAnnotationState.notDetected
                }
                return state
            }
            let inferredEventIDs = inferredDates.map {
                uniqueEventID(for: $0, candidates: eventCandidates)
            }
            let insertion = try confirmationLedger.insertTemporaryChekis(
                scannedImages,
                thumbnailImageData: thumbnails,
                dateAnnotationStates: normalizedDateAnnotationStates,
                scannerMetadata: scannerMetadata,
                sourceAnnotations: sourceAnnotations,
                dates: inferredDates,
                eventIDs: inferredEventIDs,
                eventAutoMatched: inferredEventIDs.map { $0 != nil },
                sizes: inferredSizes
            )
            let cards = insertion.inserted.map { temporary in
                let idols = (try? refetchIdolsByIDs(temporary.idolIDs)) ?? []
                return ChekinanaChekiCard(
                    id: temporary.id,
                    imageRef: nil,
                    createdAt: temporary.createdAt,
                    confirmationCode: nil,
                    thumbnailImageData: temporary.thumbnailImageData,
                    idolNames: idols.map(\.name),
                    eventDateText: temporary.date.map(calendarDateString),
                    userAppears: temporary.userAppears,
                    size: temporary.size,
                    isFavorite: temporary.isFavorite,
                    dateAnnotationState: temporary.dateAnnotationState,
                )
            }
            if holdsDirectCommitGate, let directCommitIndex {
                await directCommitGate?.release(index: directCommitIndex)
                holdsDirectCommitGate = false
            }
            return .chekiScannedCards(
                cards.count,
                warningCount: warningCount + insertion.evictedCount,
                cards
            )
        } catch {
            if holdsDirectCommitGate, let directCommitIndex {
                await directCommitGate?.release(index: directCommitIndex)
            }
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func userAppearsRecognitionOutcome(
        resultImage: ChekinanaScannerResultImage
    ) async -> UserAppearsRecognitionOutcome {
        do {
            let imageData = try Self.scannerResultData(resultImage)
            let detector = userAppearsDetect
            let value = try await bodyPoseLimiter.perform {
                try await detector(imageData)
            }
            try Task.checkCancellation()
            return .completed(value)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return Task.isCancelled ? .cancelled : .unavailable
        }
    }

    private func idolRecognitionOutcome(
        resultImage: ChekinanaScannerResultImage,
        candidates: ChekinanaPatternCandidateSet?,
        recognitionGate: ChekinanaDirectRecognitionGate?
    ) async -> IdolRecognitionOutcome {
        guard let candidates else { return .notRequested }
        if !candidates.includesUnassigned, candidates.idolIDs.count == 1 {
            return .matched(candidates.idolIDs[0])
        }
        var holdsGate = false
        do {
            if let recognitionGate {
                try await recognitionGate.acquire()
                holdsGate = true
            }
            let imageData = try Self.scannerResultData(resultImage)
            let embedding = try await patternEncode(imageData)
            try Task.checkCancellation()
            let candidateIdols = try refetchIdolsByIDs(candidates.idolIDs)
            let classification = try ChekinanaPatternClassifier.classify(
                embedding: embedding,
                candidatePatterns: candidateIdols.map {
                    (id: $0.id, patterns: $0.recognitionPatterns)
                },
                includesUnassigned: candidates.includesUnassigned,
                threshold: candidates.threshold
            )
            if holdsGate { await recognitionGate?.release() }
            return .matched(classification.idolID)
        } catch is CancellationError {
            if holdsGate { await recognitionGate?.release() }
            return .cancelled
        } catch {
            if holdsGate { await recognitionGate?.release() }
            return Task.isCancelled ? .cancelled : .failed
        }
    }

    private func dateRecognitionOutcome(
        resultImage: ChekinanaScannerResultImage,
        bounds: ChekinanaScannerDateBounds?,
        filenameExtension: String,
        requestGate: ChekinanaDirectDateRequestGate?
    ) async -> DateRecognitionOutcome {
        guard let bounds else { return .notRequested }
        if bounds.scope == .fixed {
            return .completed(.notRequested)
        }
        do {
            let state: ChekinanaChekiDateAnnotationState
            if let requestGate {
                state = try await requestGate.perform {
                    let imageData = try Self.scannerResultData(resultImage)
                    let image = ChekinanaPendingChekiImage(
                        data: imageData,
                        filenameExtension: filenameExtension
                    )
                    return try await ChekinanaDirectDateAnnotationClient().annotate(image)
                }
            } else {
                let imageData = try Self.scannerResultData(resultImage)
                let image = ChekinanaPendingChekiImage(
                    data: imageData,
                    filenameExtension: filenameExtension
                )
                state = try await ChekinanaDirectDateAnnotationClient().annotate(image)
            }
            try Task.checkCancellation()
            return .completed(state)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return Task.isCancelled ? .cancelled : .completed(.unavailable)
        }
    }

    private func persistentJPEGData(
        _ resultImage: ChekinanaScannerResultImage,
        alreadyJPEG: Bool
    ) async -> Data? {
        guard let imageData = try? Self.scannerResultData(resultImage) else { return nil }
        if alreadyJPEG { return imageData.isEmpty ? nil : imageData }
        return await ChekinanaImageWorker.reencodedJPEGData(from: imageData)
    }

    nonisolated private static func scannerResultData(
        _ resultImage: ChekinanaScannerResultImage
    ) throws -> Data {
        let data: Data
        if let url = resultImage.stagedFileURL {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } else {
            data = resultImage.data
        }
        guard !data.isEmpty, data.count <= 32 * 1_024 * 1_024 else {
            throw ChekinanaScanChekiError.invalidResultImage
        }
        return data
    }

    private func discardTemporaryCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }

        if target.lowercased() == "all" {
            let result = confirmationLedger.discardAllUnreferencedTemporaryChekis()
            if result.retained > 0 {
                return .text(ChekinanaCommandCopy.format(
                    "cheki.temporary_discarded_retained",
                    fallback: "Discarded temporary Cheki: %1$lld; retained %2$lld referenced by pending confirmations. Confirm or cancel those operations first.",
                    Int64(result.discarded),
                    Int64(result.retained)
                ))
            }
            return .text(ChekinanaCommandCopy.format(
                "cheki.temporary_discarded_count",
                fallback: "Discarded temporary Cheki: %lld.",
                Int64(result.discarded)
            ))
        }

        do {
            let shortID = try confirmationLedger.discardTemporaryCheki(target)
            return .text(ChekinanaCommandCopy.format(
                "cheki.temporary_discarded_id",
                fallback: "Discarded temporary Cheki: %@.",
                shortID
            ))
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func downloadTemporaryCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) async -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            let temporary = try confirmationLedger.resolveTemporaryCheki(target)
            let fileExtension = temporary.image.filenameExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let safeExtension = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
                .contains(fileExtension) ? fileExtension : "jpg"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Chekinana-\(UUID().uuidString)")
                .appendingPathExtension(safeExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            let cleanData = temporary.image.data
            try await Task.detached(priority: .userInitiated) {
                try cleanData.write(to: url, options: [.atomic])
            }.value
            try await ChekiPhotoLibrarySaver.saveImage(at: url)
            return .text(ChekinanaCommandCopy.text(
                "cheki.raw_scan_saved",
                fallback: "Saved the original scan result without its bounding box to the photo library."
            ))
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func listCheki(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        let allowedArguments = Set(["idol", "event", "date"])

        guard command.target == nil,
              command.arguments.keys.allSatisfy({ allowedArguments.contains($0) }) else {
            return invalidUsage(usage)
        }

        guard listChekiFilterValuesAreNonEmpty(command.arguments) else {
            return invalidUsage(usage)
        }

        do {
            let idolFilter = try command.arguments["idol"].map { try resolveUniqueIdol($0) }
            let eventFilter = try chekiEventFilter(command.arguments["event"])
            let dateFilter = try command.arguments["date"].map { try parseCalendarDate($0) }
            let descriptor = FetchDescriptor<Cheki>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let chekis = try modelContext.fetch(descriptor)
                .filter { cheki in
                    if let idolFilter, !cheki.idols.contains(where: { $0.id == idolFilter.id }) {
                        return false
                    }

                    switch eventFilter {
                    case .none:
                        break
                    case .empty:
                        guard cheki.event == nil else { return false }
                    case .event(let event):
                        guard cheki.event?.id == event.id else { return false }
                    }

                    if let dateFilter {
                        guard let eventDate = cheki.date,
                              sameCalendarDate(eventDate, dateFilter) else { return false }
                    }
                    return true
                }

            guard !chekis.isEmpty else {
                return .text(ChekinanaCommandCopy.text(
                    "cheki.none",
                    fallback: "No Cheki have been saved yet."
                ))
            }

            return .chekiCards(chekis.map { chekiCard(for: $0) })
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func showCheki(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            return .chekiCards([chekiCard(for: try resolveUniqueCheki(target))])
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func editCheki(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        let allowed = Set(["idol", "idols", "event", "date", "user", "userappears", "size", "note"])
        guard let target = command.target,
              !command.arguments.isEmpty,
              command.arguments.keys.allSatisfy(allowed.contains),
              !(command.arguments["idol"] != nil && command.arguments["idols"] != nil),
              !(command.arguments["user"] != nil && command.arguments["userappears"] != nil) else {
            return invalidUsage(usage)
        }

        do {
            let cheki = try resolveUniqueCheki(target)
            let idolValue = command.arguments["idol"] ?? command.arguments["idols"]
            let idols: [Idol]
            if let idolValue {
                idols = idolValue.trimmingCharacters(in: .whitespacesAndNewlines) == "-"
                    ? []
                    : try resolveIdolList(idolValue)
            } else {
                idols = cheki.idols
            }

            let event: Event?
            let eventDate: Date?
            if let rawEvent = command.arguments["event"] {
                event = rawEvent.trimmingCharacters(in: .whitespacesAndNewlines) == "-"
                    ? nil
                    : try resolveEvent(rawEvent)
            } else {
                event = cheki.event
            }
            if let rawDate = command.arguments["date"] {
                eventDate = rawDate.trimmingCharacters(in: .whitespacesAndNewlines) == "-"
                    ? nil
                    : try parseCalendarDate(rawDate)
            } else {
                eventDate = cheki.date
            }
            try validateChekiAssociations(idols: idols, event: event, eventDate: eventDate)

            let userValue = command.arguments["user"] ?? command.arguments["userappears"]
            let userAppears = userValue == nil
                ? cheki.userAppears
                : try parseOptionalBool(userValue, argumentName: "user")
            let size = command.arguments["size"] == nil
                ? cheki.size
                : try parseOptionalChekiSize(command.arguments["size"])
            let note: String
            if let rawNote = command.arguments["note"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                note = rawNote == "-" ? "" : rawNote
            } else {
                note = cheki.note
            }

            let code = confirmationLedger.insert(.editCheki(.init(
                chekiID: cheki.id,
                expectedUpdatedAt: cheki.updatedAt,
                idolIDs: idols.map(\.id),
                eventID: event?.id,
                date: eventDate,
                userAppears: userAppears,
                size: size,
                isFavorite: cheki.isFavorite,
                hasPostedToSNS: cheki.hasPostedToSNS,
                note: note
            )))
            let keepsGroup = sameChekiGroup(
                idolIDs: cheki.idols.map(\.id),
                eventID: cheki.event?.id,
                eventDate: cheki.date,
                otherIdolIDs: idols.map(\.id),
                otherEventID: event?.id,
                otherEventDate: eventDate
            )
            let card = ChekinanaChekiCard(
                id: cheki.id,
                imageRef: cheki.imageRef,
                createdAt: cheki.createdAt,
                confirmationCode: code,
                thumbnailImageData: nil,
                idx: keepsGroup && (cheki.idx ?? 0) >= 1 ? cheki.idx : nil,
                idolNames: idols.map(\.name),
                eventName: event?.name,
                eventDateText: eventDate.map(calendarDateString),
                userAppears: userAppears,
                size: size,
                isFavorite: cheki.isFavorite,
                hasPostedToSNS: cheki.hasPostedToSNS,
                note: note,
                dateAnnotationState: .notRequested
            )
            return .pendingChekiCards(
                ChekinanaCommandCopy.text(
                    "cheki.prepared_edit",
                    fallback: "Prepared the Cheki edit."
                ),
                [card],
                consumesSelectedPhotos: false
            )
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func deleteCheki(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            let cheki = try resolveUniqueCheki(target)
            let code = confirmationLedger.insert(
                .deleteCheki(.init(
                    chekiID: cheki.id,
                    expectedUpdatedAt: cheki.updatedAt,
                    phase: .deleteModel
                ))
            )
            let card = chekiCard(for: cheki, confirmationCode: code)
            return .pendingChekiCards(
                ChekinanaCommandCopy.text(
                    "cheki.prepared_delete",
                    fallback: "Prepared the Cheki deletion."
                ),
                [card],
                consumesSelectedPhotos: false
            )
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func listChekiFilterValuesAreNonEmpty(_ arguments: [String: String]) -> Bool {
        for key in ["idol", "event", "date"] {
            if let value = arguments[key],
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }

        return true
    }

    private func downloadCheki(_ command: ChekinanaParsedCommand, usage: [String]) async -> ChekinanaCommandResponse {
        guard let target = command.target,
              command.arguments.isEmpty,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return invalidUsage(usage)
        }

        do {
            let cheki = try resolveUniqueCheki(target)
            guard let imageURL = ChekiImageRefResolver.localFileURL(for: cheki.imageRef) else {
                return .text(ChekinanaCommandCopy.text(
                    "cheki.no_local_image",
                    fallback: "This Cheki has no readable local image."
                ))
            }

            let code = confirmationLedger.insert(.downloadCheki(chekiID: cheki.id, imageURL: imageURL))
            let card = chekiCard(for: cheki, confirmationCode: code)
            return .pendingChekiCards(
                ChekinanaCommandCopy.text(
                    "cheki.prepared_download",
                    fallback: "Prepared to save the Cheki to the photo library."
                ),
                [card],
                consumesSelectedPhotos: false
            )
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func recordCommand(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) -> ChekinanaCommandResponse {
        do {
            guard let rawKind = command.target?.lowercased(),
                  let kind = ChekinanaConfirmationLedger.RecordKind(rawValue: rawKind) else {
                if command.name == "listrecord", command.target == nil {
                    return try listRecords(kind: nil, arguments: command.arguments)
                }
                return invalidUsage(usage)
            }
            switch command.name {
            case "listrecord":
                return try listRecords(kind: kind, arguments: command.arguments)
            case "showrecord":
                guard let target = command.arguments["target"],
                      Set(command.arguments.keys) == Set(["target"]) else {
                    return invalidUsage(usage)
                }
                return try showRecord(kind: kind, target: target)
            case "addrecord":
                return try prepareRecordMutation(kind: kind, mutation: .add, arguments: command.arguments)
            case "editrecord":
                guard let target = command.arguments["target"] else { return invalidUsage(usage) }
                var arguments = command.arguments
                arguments.removeValue(forKey: "target")
                let id = try resolveRecordID(kind: kind, token: target)
                return try prepareRecordMutation(kind: kind, mutation: .edit(id), arguments: arguments)
            case "deleterecord":
                guard let target = command.arguments["target"],
                      Set(command.arguments.keys) == Set(["target"]) else {
                    return invalidUsage(usage)
                }
                let id = try resolveRecordID(kind: kind, token: target)
                if kind == .cheki {
                    return deleteCheki(
                        .init(name: "deletecheki", target: String(id.uuidString.prefix(8)), arguments: [:]),
                        usage: usage
                    )
                }
                return try prepareRecordMutation(kind: kind, mutation: .delete(id), arguments: [:])
            default:
                return invalidUsage(usage)
            }
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func navigate(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) -> ChekinanaCommandResponse {
        guard let rawDestination = command.target,
              let destination = ChekinanaAssistantDestination(rawValue: rawDestination),
              Set(command.arguments.keys).isSubset(of: ["date"]),
              command.arguments["date"] == nil || destination == .calendar else {
            return invalidUsage(usage)
        }
        do {
            let date = try command.arguments["date"].map(parseCalendarDate)
            let title = destination.rawValue.replacingOccurrences(of: "_", with: " ")
            return .shellAction(
                .navigate(destination: destination, date: date),
                message: ChekinanaCommandCopy.format(
                    "navigation.opened",
                    fallback: "Opened %@.",
                    title
                )
            )
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func openScan(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) -> ChekinanaCommandResponse {
        let allowed = Set([
            "recognize_date", "recognize_idol", "includes_unassigned",
            "candidate_refs", "fixed_date", "date_from", "date_to",
        ])
        guard command.target == nil, Set(command.arguments.keys).isSubset(of: allowed) else {
            return invalidUsage(usage)
        }
        do {
            let hasDateFields = ["fixed_date", "date_from", "date_to"].contains {
                command.arguments[$0] != nil
            }
            let hasIdolFields = command.arguments["candidate_refs"] != nil
                || command.arguments["includes_unassigned"] != nil
            let recognizeDate = try command.arguments["recognize_date"]
                .map(requireStrictBool) ?? hasDateFields
            let recognizeIdol = try command.arguments["recognize_idol"]
                .map(requireStrictBool) ?? hasIdolFields
            guard recognizeDate || !hasDateFields, recognizeIdol || !hasIdolFields else {
                throw ChekinanaNLClientError.invalidSchema
            }
            let includesUnassigned = try command.arguments["includes_unassigned"]
                .map(requireStrictBool) ?? false
            let candidateIDs = try command.arguments["candidate_refs"]
                .map(resolveIdolList)?.map(\.id) ?? []
            let fixedDate = try command.arguments["fixed_date"].map(parseCalendarDate)
            let dateFrom = try command.arguments["date_from"].map(parseCalendarDate)
            let dateTo = try command.arguments["date_to"].map(parseCalendarDate)
            guard (dateFrom == nil) == (dateTo == nil),
                  !(fixedDate != nil && dateFrom != nil),
                  dateFrom == nil || dateTo == nil || dateFrom! <= dateTo! else {
                throw ChekinanaNLClientError.invalidSchema
            }
            return .shellAction(
                .openScan(.init(
                    recognizeDate: recognizeDate,
                    recognizeIdol: recognizeIdol,
                    includesUnassigned: includesUnassigned,
                    candidateIdolIDs: candidateIDs,
                    fixedDate: fixedDate,
                    dateFrom: dateFrom,
                    dateTo: dateTo
                )),
                message: ChekinanaCommandCopy.text(
                    "navigation.scan_opened",
                    fallback: "Opened Scan with the requested recognition settings."
                )
            )
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
    }

    private func listRecords(
        kind: ChekinanaConfirmationLedger.RecordKind?,
        arguments: [String: String]
    ) throws -> ChekinanaCommandResponse {
        let allowed = Set(["idols", "event", "date", "idx", "favorite", "size"])
        guard Set(arguments.keys).isSubset(of: allowed) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        if kind != .cheki,
           arguments["idx"] != nil || arguments["favorite"] != nil || arguments["size"] != nil {
            throw ChekinanaNLClientError.invalidSchema
        }
        if let kind, kind != .cheki, arguments["event"] != nil {
            throw ChekinanaNLClientError.invalidSchema
        }
        let requestedIdols = try arguments["idols"].map(resolveIdolList)
        let requestedIDs = requestedIdols.map { Set($0.map(\.id)) }
        let requestedEvent = try arguments["event"].map(resolveUniqueEvent)
        let requestedDate = try arguments["date"].map(parseCalendarDate)
        let requestedIndex = try arguments["idx"].map(parsePositiveIndex)
        let requestedFavorite = try arguments["favorite"].map(requireStrictBool)
        let requestedSize = try arguments["size"].map(requireRecordSize)
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()

        func matches(idols: [Idol], event: Event?, date: Date?) -> Bool {
            if let requestedIDs,
               !requestedIDs.isSubset(of: Set(idols.map(\.id))) { return false }
            if let requestedEvent, event?.id != requestedEvent.id { return false }
            if let requestedDate,
               date.map({ sameCalendarDate($0, requestedDate) }) != true { return false }
            return true
        }

        var lines: [String] = []
        if kind == nil || kind == .cheki {
            let values = try modelContext.fetch(FetchDescriptor<Cheki>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )).filter {
                ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIDs)
                    && matches(idols: $0.idols, event: $0.event, date: $0.date)
                    && (requestedIndex == nil || $0.idx == requestedIndex)
                    && (requestedFavorite == nil || $0.isFavorite == requestedFavorite)
                    && (requestedSize == nil || $0.size == requestedSize)
            }
            lines += values.map { recordSummary(kind: .cheki, id: $0.id, idols: $0.idols, event: $0.event, date: $0.date, note: $0.note) }
        }
        if kind == nil || kind == .shame {
            let values = try modelContext.fetch(FetchDescriptor<Shame>()).filter {
                ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIDs)
                    && matches(idols: $0.idols, event: nil, date: $0.date)
            }
            lines += values.map { recordSummary(kind: .shame, id: $0.id, idols: $0.idols, event: nil, date: $0.date, note: $0.note) }
        }
        if kind == nil || kind == .douga {
            let values = try modelContext.fetch(FetchDescriptor<Douga>()).filter {
                ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIDs)
                    && matches(idols: $0.idols, event: nil, date: $0.date)
            }
            lines += values.map { recordSummary(kind: .douga, id: $0.id, idols: $0.idols, event: nil, date: $0.date, note: $0.note) }
        }
        return .text(lines.isEmpty ? ChekinanaCommandCopy.text(
            "record.none",
            fallback: "No matching records."
        ) : lines.joined(separator: "\n"))
    }

    private func showRecord(
        kind: ChekinanaConfirmationLedger.RecordKind,
        target: String
    ) throws -> ChekinanaCommandResponse {
        switch kind {
        case .cheki:
            return .chekiCards([chekiCard(for: try resolveUniqueCheki(target))])
        case .shame:
            let value = try resolveUniqueShame(target)
            return .text(recordSummary(kind: kind, id: value.id, idols: value.idols, event: nil, date: value.date, note: value.note))
        case .douga:
            let value = try resolveUniqueDouga(target)
            return .text(recordSummary(kind: kind, id: value.id, idols: value.idols, event: nil, date: value.date, note: value.note))
        }
    }

    private func prepareRecordMutation(
        kind: ChekinanaConfirmationLedger.RecordKind,
        mutation: ChekinanaConfirmationLedger.RecordMutation,
        arguments: [String: String]
    ) throws -> ChekinanaCommandResponse {
        if case .add = mutation,
           let kind = ChekinanaRecordKind(rawValue: kind.rawValue),
           let mediaError = ChekinanaMediaBackedCreationError(kind: kind) {
            throw mediaError
        }
        let allowed = Set(["idols", "event", "date", "idx", "user", "note", "favorite", "size", "clear_fields"])
        guard Set(arguments.keys).isSubset(of: allowed),
              !(kind != .cheki && ["event", "idx", "favorite", "size"].contains(where: { arguments[$0] != nil })) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        if case .delete = mutation {
            guard arguments.isEmpty else { throw ChekinanaNLClientError.invalidSchema }
        }
        if case .edit = mutation, arguments.isEmpty {
            throw ChekinanaNLClientError.invalidSchema
        }
        if case .add = mutation, arguments["clear_fields"] != nil {
            throw ChekinanaNLClientError.invalidSchema
        }
        if case .add = mutation, arguments["user"] != nil {
            throw ChekinanaNLClientError.invalidSchema
        }
        let clearFields = Set(arguments["clear_fields"]?.split(separator: ",").map(String.init) ?? [])
        let permittedClear = kind == .cheki
            ? Set(["idols", "event", "date", "idx", "user", "note", "size"])
            : Set(["idols", "date", "note"])
        guard clearFields.isSubset(of: permittedClear),
              clearFields.isDisjoint(with: arguments.keys) else {
            throw ChekinanaNLClientError.invalidSchema
        }

        var idolIDs: [UUID] = []
        var eventID: UUID?
        var date: Date?
        var idx: Int?
        var note = ""
        var userAppears: Bool?
        var favorite = false
        var size: ChekiSize?
        var fingerprint: String?
        var originalIdolIDs: [UUID] = []
        var originalEventID: UUID?
        var originalDate: Date?

        switch (kind, mutation) {
        case (.cheki, .edit(let id)), (.cheki, .delete(let id)):
            let value = try refetchChekiByID(id)
            idolIDs = value.idols.map(\.id); eventID = value.event?.id; date = value.date
            idx = value.idx; note = value.note; favorite = value.isFavorite; size = value.size
            userAppears = value.userAppears
            fingerprint = recordFingerprint(value)
        case (.shame, .edit(let id)), (.shame, .delete(let id)):
            let value = try refetchShameByID(id)
            idolIDs = value.idols.map(\.id); date = value.date
            note = value.note; fingerprint = recordFingerprint(value)
        case (.douga, .edit(let id)), (.douga, .delete(let id)):
            let value = try refetchDougaByID(id)
            idolIDs = value.idols.map(\.id); date = value.date
            note = value.note; fingerprint = recordFingerprint(value)
        case (_, .add):
            break
        }
        originalIdolIDs = idolIDs
        originalEventID = eventID
        originalDate = date

        if clearFields.contains("idols") { idolIDs = [] }
        if clearFields.contains("event") { eventID = nil }
        if clearFields.contains("date") { date = nil }
        if clearFields.contains("idx") { idx = nil }
        if clearFields.contains("note") { note = "" }
        if clearFields.contains("user") { userAppears = nil }
        if clearFields.contains("size") { size = nil }
        if let value = arguments["idols"] { idolIDs = try resolveIdolList(value).map(\.id) }
        if let value = arguments["event"] { eventID = try resolveUniqueEvent(value).id }
        if let value = arguments["date"] { date = try parseCalendarDate(value) }
        if let value = arguments["idx"] { idx = try parsePositiveIndex(value) }
        if let value = arguments["note"] { note = value }
        if let value = arguments["user"] { userAppears = try parseOptionalBool(value, argumentName: "user") }
        if let value = arguments["favorite"] { favorite = try requireStrictBool(value) }
        if let value = arguments["size"] { size = try requireRecordSize(value) }

        if kind == .cheki {
            if case .add = mutation,
               arguments["event"] == nil,
               !clearFields.contains("event") {
                eventID = try uniqueEvent(for: date)?.id
            }
            if idolIDs.isEmpty || date == nil {
                guard idx == nil else { throw ChekinanaNLClientError.invalidSchema }
            } else if idx == nil, case .add = mutation {
                idx = try nextChekiIndex(idolIDs: idolIDs, eventID: eventID, eventDate: date, excludingChekiID: nil)
            } else if case .edit(let id) = mutation,
                      arguments["idx"] == nil,
                      !clearFields.contains("idx"),
                      !sameChekiGroup(
                        idolIDs: originalIdolIDs,
                        eventID: originalEventID,
                        eventDate: originalDate,
                        otherIdolIDs: idolIDs,
                        otherEventID: eventID,
                        otherEventDate: date
                      ) {
                idx = try nextChekiIndex(
                    idolIDs: idolIDs,
                    eventID: eventID,
                    eventDate: date,
                    excludingChekiID: id
                )
            }
        }
        let payload = ChekinanaConfirmationLedger.RecordPayload(
            kind: kind,
            mutation: mutation,
            expectedFingerprint: fingerprint,
            idolIDs: idolIDs,
            eventID: eventID,
            date: normalizedCalendarDay(date),
            idx: idx,
            note: note,
            userAppears: userAppears,
            favorite: favorite,
            size: size
        )
        let code = confirmationLedger.insert(.mutateRecord(payload))
        return .confirmationText(
            ChekinanaCommandCopy.format(
                "record.confirmation",
                fallback: "Prepared %@ operation. Confirm to continue.",
                ChekinanaRecordKind(rawValue: kind.rawValue)?.title ?? kind.rawValue
            ),
            confirmationCode: code
        )
    }

    private func resolveRecordID(
        kind: ChekinanaConfirmationLedger.RecordKind,
        token: String
    ) throws -> UUID {
        switch kind {
        case .cheki: try resolveUniqueCheki(token).id
        case .shame: try resolveUniqueShame(token).id
        case .douga: try resolveUniqueDouga(token).id
        }
    }

    private func resolveUniqueShame(_ token: String) throws -> Shame {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = try modelContext.fetch(FetchDescriptor<Shame>()).filter {
            $0.id.uuidString.lowercased().hasPrefix(normalized)
                && ChekinanaVisibilityPolicy.includesRecord(
                    idols: $0.idols,
                    hiddenIDs: ChekinanaHiddenIdolPersistence.load()
                )
        }
        guard matches.count == 1, let value = matches.first else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    private func resolveUniqueDouga(_ token: String) throws -> Douga {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = try modelContext.fetch(FetchDescriptor<Douga>()).filter {
            $0.id.uuidString.lowercased().hasPrefix(normalized)
                && ChekinanaVisibilityPolicy.includesRecord(
                    idols: $0.idols,
                    hiddenIDs: ChekinanaHiddenIdolPersistence.load()
                )
        }
        guard matches.count == 1, let value = matches.first else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    private func recordSummary(
        kind: ChekinanaConfirmationLedger.RecordKind,
        id: UUID,
        idols: [Idol],
        event: Event?,
        date: Date?,
        note: String
    ) -> String {
        let people = idols.map(\.name).joined(separator: ", ")
        let day = date.map(calendarDateString) ?? "—"
        let eventName = event?.name ?? "—"
        let suffix = note.isEmpty ? "" : " · \(note)"
        let typeName = ChekinanaRecordKind(rawValue: kind.rawValue)?.title ?? kind.rawValue
        return "[\(String(id.uuidString.prefix(8)).lowercased())] \(typeName) · \(people.isEmpty ? "—" : people) · \(eventName) · \(day)\(suffix)"
    }

    private func parsePositiveIndex(_ raw: String) throws -> Int {
        guard let value = Int(raw), value > 0 else { throw ChekinanaNLClientError.invalidSchema }
        return value
    }

    private func requireStrictBool(_ raw: String) throws -> Bool {
        guard let value = parseStrictBool(raw) else { throw ChekinanaNLClientError.invalidSchema }
        return value
    }

    private func parseStrictBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private func requireRecordSize(_ raw: String) throws -> ChekiSize {
        guard ["mini", "wide"].contains(raw), let value = ChekiSize(rawValue: raw) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    private func resolveUniqueCheki(_ token: String) throws -> Cheki {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let descriptor = FetchDescriptor<Cheki>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        let chekis = try modelContext.fetch(descriptor).filter {
            ChekinanaVisibilityPolicy.includesRecord(idols: $0.idols, hiddenIDs: hiddenIDs)
        }
        let matches = chekis.filter { cheki in
            cheki.id.uuidString.lowercased().hasPrefix(normalizedToken)
        }

        guard !matches.isEmpty else {
            throw ChekinanaDownloadChekiError.noCheki(token)
        }

        guard matches.count == 1, let cheki = matches.first else {
            throw ChekinanaDownloadChekiError.ambiguousCheki(token)
        }

        return cheki
    }

    private func shortChekiID(_ cheki: Cheki) -> String {
        String(cheki.id.uuidString.prefix(8)).lowercased()
    }

    private func scanChekiOptions(from command: ChekinanaParsedCommand) throws -> ChekinanaScannerOptions {
        let scannerSize = try parseScannerSize(command.arguments["scanner_size"])
        let postprocessMode = try parseScannerPostprocessMode(command.arguments["postprocess"])
        let expected = try parseScannerExpected(command.arguments["expected"])
        let whiteBalance = try parseScannerBool(command.arguments["wb"], defaultValue: true, argumentName: "wb")
        let sleevesEnabled = try parseScannerBool(
            command.arguments["sleeves"],
            defaultValue: false,
            argumentName: "sleeves"
        )
        let directInputEnabled = try parseScannerBool(
            command.arguments["direct"],
            defaultValue: false,
            argumentName: "direct"
        )
        let dateRecognitionEnabled = try parseScannerBool(
            command.arguments["date_recognition"],
            defaultValue: false,
            argumentName: "date_recognition"
        )
        let hasDateDeclaration = ["date_scope", "date_from", "date_to"].contains {
            command.arguments[$0] != nil
        }
        guard dateRecognitionEnabled || !hasDateDeclaration else {
            throw ChekinanaScanChekiError.invalidArgumentValue(
                "date_scope",
                command.arguments["date_scope"] ?? ""
            )
        }
        let dateBounds = dateRecognitionEnabled
            ? try parseScannerDateBounds(command.arguments)
            : nil
        let idolRecognitionEnabled = try parseScannerBool(
            command.arguments["idol_recognition"],
            defaultValue: false,
            argumentName: "idol_recognition"
        )
        guard idolRecognitionEnabled || command.arguments["candidates"] == nil else {
            throw ChekinanaScanChekiError.invalidArgumentValue(
                "candidates",
                command.arguments["candidates"] ?? ""
            )
        }
        guard idolRecognitionEnabled || command.arguments["idol_threshold"] == nil else {
            throw ChekinanaScanChekiError.invalidArgumentValue(
                "idol_threshold",
                command.arguments["idol_threshold"] ?? ""
            )
        }
        let threshold = try parsePatternThreshold(command.arguments["idol_threshold"])
        let candidates = idolRecognitionEnabled
            ? try parsePatternCandidates(
                command.arguments["candidates"],
                threshold: threshold
            )
            : nil

        return ChekinanaScannerOptions(
            expectedPolaroids: expected,
            scannerSize: scannerSize,
            postprocessMode: postprocessMode,
            whiteBalance: whiteBalance,
            sleevesEnabled: sleevesEnabled,
            directInputEnabled: directInputEnabled,
            dateRecognitionEnabled: dateRecognitionEnabled,
            dateBounds: dateBounds,
            idolRecognitionCandidates: candidates
        )
    }

    private func parseScannerDateBounds(
        _ arguments: [String: String]
    ) throws -> ChekinanaScannerDateBounds {
        let rawScope = arguments["date_scope"]?.lowercased() ?? ChekinanaScannerDateScope.recent.rawValue
        guard let scope = ChekinanaScannerDateScope(rawValue: rawScope) else {
            throw ChekinanaScanChekiError.invalidArgumentValue("date_scope", rawScope)
        }
        let from = try arguments["date_from"].map(parseCalendarDate)
        let to = try arguments["date_to"].map(parseCalendarDate)
        let bounds: ChekinanaScannerDateBounds?
        switch scope {
        case .fixed:
            guard let from else {
                throw ChekinanaScanChekiError.invalidArgumentValue(
                    "date_from",
                    arguments["date_from"] ?? ""
                )
            }
            if let to, !sameCalendarDate(from, to) {
                throw ChekinanaScanChekiError.invalidArgumentValue(
                    "date_to",
                    arguments["date_to"] ?? ""
                )
            }
            bounds = ChekinanaScannerDateBounds.fixedCanonicalDate(from)
        case .range:
            guard let from, let to else {
                throw ChekinanaScanChekiError.invalidArgumentValue(
                    "date_from",
                    arguments["date_from"] ?? ""
                )
            }
            bounds = ChekinanaScannerDateBounds.canonicalRange(from: from, to: to)
        case .recent:
            if let from, let to {
                bounds = ChekinanaScannerDateBounds.canonicalRange(from: from, to: to)
                    .map { .init(scope: .recent, from: $0.from, to: $0.to) }
            } else if from == nil, to == nil {
                bounds = ChekinanaScannerDateBounds.recent(relativeTo: now(), calendar: calendar)
            } else {
                bounds = nil
            }
        }
        guard let bounds else {
            throw ChekinanaScanChekiError.invalidArgumentValue(
                "date_to",
                arguments["date_to"] ?? ""
            )
        }
        return bounds
    }

    private func parsePatternCandidates(
        _ value: String?,
        threshold: Float = ChekinanaPatternClassifier.unassignedThreshold
    ) throws -> ChekinanaPatternCandidateSet {
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        let idols = try modelContext.fetch(FetchDescriptor<Idol>()).filter {
            ChekinanaVisibilityPolicy.includesIdol($0.id, hiddenIDs: hiddenIDs)
        }
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return ChekinanaPatternCandidateSet(
                idolIDs: idols
                    .filter(\.hasRecognitionPatterns)
                    .map(\.id),
                includesUnassigned: true,
                threshold: threshold
            )
        }
        let tokens = rawValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty }) else {
            throw ChekinanaScanChekiError.invalidArgumentValue("candidates", rawValue)
        }
        var includesUnassigned = false
        var ids: [UUID] = []
        for token in tokens {
            if token.lowercased() == "unassigned" {
                guard !includesUnassigned else {
                    throw ChekinanaScanChekiError.invalidArgumentValue("candidates", rawValue)
                }
                includesUnassigned = true
                continue
            }
            guard let id = UUID(uuidString: token),
                  idols.contains(where: { $0.id == id }),
                  !ids.contains(id) else {
                throw ChekinanaScanChekiError.invalidArgumentValue("candidates", rawValue)
            }
            ids.append(id)
        }
        guard !ids.isEmpty || includesUnassigned else {
            throw ChekinanaScanChekiError.invalidArgumentValue("candidates", rawValue)
        }
        return ChekinanaPatternCandidateSet(
            idolIDs: ids,
            includesUnassigned: includesUnassigned,
            threshold: threshold
        )
    }

    private func parsePatternThreshold(_ value: String?) throws -> Float {
        guard let value else { return ChekinanaPatternClassifier.unassignedThreshold }
        guard let threshold = Float(value), threshold.isFinite,
              (0...1).contains(threshold) else {
            throw ChekinanaScanChekiError.invalidArgumentValue("idol_threshold", value)
        }
        return threshold
    }

    private func parseScannerExpected(_ value: String?) throws -> Int? {
        guard let value else {
            return nil
        }

        guard let parsed = Int(value), parsed > 0 else {
            throw ChekinanaScanChekiError.invalidArgumentValue("expected", value)
        }

        return parsed
    }

    private func parseScannerSize(_ value: String?) throws -> ChekinanaScannerSize {
        guard let value else {
            return .auto
        }

        guard let parsed = ChekinanaScannerSize(rawValue: value.lowercased()) else {
            throw ChekinanaScanChekiError.invalidArgumentValue("scanner_size", value)
        }

        return parsed
    }

    private func parseScannerPostprocessMode(_ value: String?) throws -> ChekinanaScannerPostprocessMode {
        guard let value else {
            return .off
        }

        guard let parsed = ChekinanaScannerPostprocessMode(rawValue: value.lowercased()) else {
            throw ChekinanaScanChekiError.invalidArgumentValue("postprocess", value)
        }

        return parsed
    }

    private func parseScannerBool(_ value: String?, defaultValue: Bool, argumentName: String) throws -> Bool {
        guard let value else {
            return defaultValue
        }

        switch value.lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            throw ChekinanaScanChekiError.invalidArgumentValue(argumentName, value)
        }
    }

    private func idolCard(
        _ idol: Idol,
        detail: ChekinanaIdolCardDetail? = nil,
        preparedCandidate: ChekinanaPreparedIdolCandidate? = nil
    ) -> ChekinanaIdolCard {
        ChekinanaIdolCard(
            id: idol.id,
            catalogueID: idol.sourceId,
            name: idol.name,
            group: idol.group,
            color: idol.color,
            birthday: idol.birthday,
            verification: idol.verification,
            bio: idol.bio,
            avatarImageRef: idol.avatarImageRef,
            avatarThumbnailData: preparedCandidate?.avatarThumbnailData,
            avatarIdentity: preparedCandidate?.avatarIdentity,
            avatarThumbnailImage: preparedCandidate?.avatarThumbnailImage,
            detail: detail ?? .chekiCount(idol.chekis.count),
            confirmationCode: nil,
            selectionToken: nil
        )
    }

    private func showIdolResponse(for idols: [Idol]) -> ChekinanaCommandResponse {
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        let sections = idols.filter {
            ChekinanaVisibilityPolicy.includesIdol($0.id, hiddenIDs: hiddenIDs)
        }.map { idol in
            ChekinanaIdolSection(
                idol: idolCard(idol),
                chekis: chekiCards(for: idol)
            )
        }

        if sections.count == 1, let section = sections.first, section.chekis.isEmpty {
            return .idolCard(section.idol)
        }

        return .idolSections(sections)
    }

    private func refetchIdolByID(_ id: UUID) throws -> Idol {
        var descriptor = FetchDescriptor<Idol>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let idol = try modelContext.fetch(descriptor).first,
              ChekinanaVisibilityPolicy.includesIdol(
                idol.id,
                hiddenIDs: ChekinanaHiddenIdolPersistence.load()
              ) else {
            throw ChekinanaAddChekiError.noIdol(id.uuidString)
        }
        return idol
    }

    private func associatedRecordCount(for idolID: UUID) throws -> Int {
        let chekiCount = try modelContext.fetch(FetchDescriptor<Cheki>()).reduce(into: 0) {
            if $1.idols.contains(where: { $0.id == idolID }) { $0 += 1 }
        }
        let shameCount = try modelContext.fetch(FetchDescriptor<Shame>()).reduce(into: 0) {
            if $1.idols.contains(where: { $0.id == idolID }) { $0 += 1 }
        }
        let dougaCount = try modelContext.fetch(FetchDescriptor<Douga>()).reduce(into: 0) {
            if $1.idols.contains(where: { $0.id == idolID }) { $0 += 1 }
        }
        return chekiCount + shameCount + dougaCount
    }

    private func hasIdol(sourceId: String) throws -> Bool {
        var descriptor = FetchDescriptor<Idol>(predicate: #Predicate { $0.sourceId == sourceId })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func chekiCards(for idol: Idol) -> [ChekinanaChekiCard] {
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        return idol.chekis
            .filter {
                ChekinanaVisibilityPolicy.includesRecord(
                    idolIDs: $0.idols.map(\.id),
                    hiddenIDs: hiddenIDs
                )
            }
            .sorted { lhs, rhs in
                lhs.createdAt < rhs.createdAt
            }
            .map { chekiCard(for: $0) }
    }

    private func chekiCard(
        for cheki: Cheki,
        confirmationCode: String? = nil,
        thumbnailImageData: Data? = nil
    ) -> ChekinanaChekiCard {
        ChekinanaChekiCard(
            id: cheki.id,
            imageRef: cheki.imageRef,
            createdAt: cheki.createdAt,
            confirmationCode: confirmationCode,
            thumbnailImageData: thumbnailImageData,
            idx: cheki.idx,
            idolNames: cheki.idols.map(\.name),
            eventName: cheki.event?.name,
            eventDateText: cheki.date.map(calendarDateString),
            userAppears: cheki.userAppears,
            size: cheki.size,
            isFavorite: cheki.isFavorite,
            hasPostedToSNS: cheki.hasPostedToSNS,
            note: cheki.note,
            dateAnnotationState: .notRequested
        )
    }

    private func attachImageToExistingCheki(
        payload: ChekinanaConfirmationLedger.AddChekiPayload,
        idols: [Idol],
        event: Event?
    ) async throws -> ChekinanaCommandResponse {
        // Reject a stale/media-backed target before performing any file I/O.
        _ = try validatedExistingAttachTarget(payload)
        var ownedImageURLs: [URL] = []
        do {
            let stagedImage = try await ChekinanaImageWorker.saveChekiImageData(
                payload.image.data,
                id: UUID(),
                filenameExtension: payload.image.filenameExtension
            )
            ownedImageURLs.append(stagedImage.url)
            try Task.checkCancellation()

            // The image preparation await can interleave with another local
            // edit. Revalidate before claiming the record-owned filename.
            _ = try validatedExistingAttachTarget(payload)
            let savedImage = try await ChekinanaImageWorker.promoteChekiImage(
                stagedImage,
                to: payload.id
            )
            ownedImageURLs.append(savedImage.url)
            try Task.checkCancellation()

            // Revalidate once more after the atomic file move and immediately
            // before the synchronous MainActor mutation/save boundary.
            let cheki = try validatedExistingAttachTarget(payload)
            let edited = payload.explicitlyEditedFields
            if edited.contains(.idx) {
                if let requestedIdx = payload.requestedIdx {
                    guard requestedIdx > 0,
                          let group = ChekinanaChekiGroupKey(
                            idolIDs: payload.idolIDs,
                            date: payload.date
                          ) else {
                        throw ChekinanaAddChekiError.indexOverflow
                    }
                    let collision = try modelContext.fetch(FetchDescriptor<Cheki>())
                        .contains { candidate in
                            candidate.id != cheki.id
                                && ChekinanaChekiGroupKey(
                                    idolIDs: candidate.idols.map(\.id),
                                    date: candidate.date
                                ) == group
                                && candidate.idx == requestedIdx
                        }
                    guard !collision else {
                        throw ChekinanaAddChekiError.duplicateIndex(requestedIdx)
                    }
                }
                cheki.idx = payload.requestedIdx
            }
            cheki.imageRef = savedImage.ref
            if edited.contains(.idols) { cheki.idols = idols }
            if edited.contains(.date) {
                cheki.date = normalizedCalendarDay(payload.date)
            }
            if edited.contains(.event) { cheki.event = event }
            if edited.contains(.userAppears) || cheki.userAppears == nil {
                cheki.userAppears = payload.userAppears
            }
            if edited.contains(.size) { cheki.size = payload.size }
            if edited.contains(.favorite) { cheki.isFavorite = payload.isFavorite }
            if edited.contains(.posted) {
                cheki.hasPostedToSNS = payload.hasPostedToSNS
            }
            if edited.contains(.note) { cheki.note = payload.note }
            cheki.updatedAt = Date()
            try modelContext.save()
            return .chekiCards([chekiCard(
                for: cheki,
                thumbnailImageData: payload.thumbnailImageData
            )])
        } catch {
            modelContext.rollback()
            for url in ownedImageURLs {
                await ChekinanaImageWorker.removeItemIfPresent(at: url)
            }
            throw error
        }
    }

    private func validatedExistingAttachTarget(
        _ payload: ChekinanaConfirmationLedger.AddChekiPayload
    ) throws -> Cheki {
        guard let targetID = payload.existingChekiID,
              targetID == payload.id,
              let expectedUpdatedAt = payload.existingChekiExpectedUpdatedAt else {
            throw ChekinanaAddChekiError.duplicateCheki(payload.id.uuidString)
        }
        let cheki = try refetchChekiByID(targetID)
        guard cheki.updatedAt == expectedUpdatedAt else {
            throw ChekinanaEditConflictError.staleCheki(
                String(targetID.uuidString.prefix(8)).lowercased()
            )
        }
        guard ChekinanaNoMediaPolicy.hasNoImage(cheki.imageRef),
              let existingDate = cheki.date,
              let selectedDate = payload.date,
              sameCalendarDate(existingDate, selectedDate),
              Set(cheki.idols.map(\.id)) == Set(payload.idolIDs),
              cheki.modelContext === modelContext else {
            throw ChekinanaAddChekiError.duplicateCheki(targetID.uuidString)
        }
        return cheki
    }

    private func persistCheki(
        id: UUID,
        image: ChekinanaPendingChekiImage,
        thumbnailImageData: Data?,
        idols: [Idol],
        event: Event?,
        eventDate: Date?,
        idx: Int?,
        userAppears: Bool?,
        size: ChekiSize?,
        isFavorite: Bool,
        hasPostedToSNS: Bool,
        note: String,
        createdAt: Date
    ) async throws -> ChekinanaCommandResponse {
        var savedImageURL: URL?

        do {
            var duplicateDescriptor = FetchDescriptor<Cheki>(predicate: #Predicate { $0.id == id })
            duplicateDescriptor.fetchLimit = 1
            guard try modelContext.fetch(duplicateDescriptor).isEmpty else {
                throw ChekinanaAddChekiError.duplicateCheki(id.uuidString)
            }

            let savedImage = try await ChekinanaImageWorker.saveChekiImageData(
                image.data,
                id: id,
                filenameExtension: image.filenameExtension
            )
            savedImageURL = savedImage.url
            let cheki = Cheki(
                id: id,
                date: normalizedCalendarDay(eventDate),
                idx: idx,
                userAppears: userAppears,
                size: size,
                imageRef: savedImage.ref,
                isFavorite: isFavorite,
                hasPostedToSNS: hasPostedToSNS,
                note: note,
                createdAt: createdAt
            )

            // On iOS 17 SwiftData must attach a new model to the destination
            // context before it establishes relationships with fetched models.
            // Assigning `idols` or `event` in Cheki.init creates those
            // relationships while `cheki` is still context-free and can raise
            // an uncaught NSInvalidArgumentException on a real device.
            modelContext.insert(cheki)
            guard cheki.modelContext === modelContext,
                  idols.allSatisfy({ $0.modelContext === modelContext }),
                  event.map({ $0.modelContext === modelContext }) ?? true else {
                throw ChekinanaAddChekiError.modelContextMismatch
            }
            cheki.idols = idols
            cheki.event = event
            try modelContext.save()
            return .chekiCards([chekiCard(
                for: cheki,
                thumbnailImageData: thumbnailImageData
            )])
        } catch {
            modelContext.rollback()
            if let savedImageURL {
                await ChekinanaImageWorker.removeItemIfPresent(at: savedImageURL)
            }
            throw error
        }
    }

    private func refetchIdolsByIDs(_ ids: [UUID]) throws -> [Idol] {
        guard !ids.isEmpty else {
            return []
        }
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        return try ids.map { id in
            var descriptor = FetchDescriptor<Idol>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 2
            let matches = try modelContext.fetch(descriptor)
            guard !matches.isEmpty else {
                throw ChekinanaAddChekiError.noIdol(id.uuidString)
            }
            guard matches.count == 1, let idol = matches.first else {
                throw ChekinanaAddChekiError.duplicateIdol(id.uuidString)
            }
            guard ChekinanaVisibilityPolicy.includesIdol(idol.id, hiddenIDs: hiddenIDs) else {
                throw ChekinanaAddChekiError.noIdol(id.uuidString)
            }
            return idol
        }
    }

    private func refetchEventByID(_ id: UUID?) throws -> Event? {
        guard let id else {
            return nil
        }
        var descriptor = FetchDescriptor<Event>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let event = try modelContext.fetch(descriptor).first else {
            throw ChekinanaAddChekiError.noEvent(id.uuidString)
        }
        return event
    }

    private func refetchEventByRequiredID(_ id: UUID) throws -> Event {
        guard let event = try refetchEventByID(id) else {
            throw ChekinanaAddChekiError.noEvent(id.uuidString)
        }
        return event
    }

    private func uniqueEvent(for date: Date?) throws -> Event? {
        let events = try modelContext.fetch(FetchDescriptor<Event>())
        guard let id = ChekinanaChekiEventAutoAssociation.uniqueEventID(
            for: date,
            events: events.map { ($0.id, $0.date) },
            calendar: calendar
        ) else { return nil }
        return events.first { $0.id == id }
    }

    private func refetchChekiByID(_ id: UUID) throws -> Cheki {
        var descriptor = FetchDescriptor<Cheki>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let cheki = try modelContext.fetch(descriptor).first,
              ChekinanaVisibilityPolicy.includesRecord(
                idolIDs: cheki.idols.map(\.id),
                hiddenIDs: ChekinanaHiddenIdolPersistence.load()
              ) else {
            throw ChekinanaDownloadChekiError.noCheki(id.uuidString)
        }
        return cheki
    }

    private func refetchShameByID(_ id: UUID) throws -> Shame {
        var descriptor = FetchDescriptor<Shame>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 2
        let values = try modelContext.fetch(descriptor)
        guard values.count == 1, let value = values.first,
              ChekinanaVisibilityPolicy.includesRecord(
                idolIDs: value.idols.map(\.id),
                hiddenIDs: ChekinanaHiddenIdolPersistence.load()
              ) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    private func refetchDougaByID(_ id: UUID) throws -> Douga {
        var descriptor = FetchDescriptor<Douga>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 2
        let values = try modelContext.fetch(descriptor)
        guard values.count == 1, let value = values.first,
              ChekinanaVisibilityPolicy.includesRecord(
                idolIDs: value.idols.map(\.id),
                hiddenIDs: ChekinanaHiddenIdolPersistence.load()
              ) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    private func recordFingerprint(_ value: Cheki) -> String {
        [
            value.id.uuidString,
            value.idols.map(\.id.uuidString).sorted().joined(separator: ","),
            value.event?.id.uuidString ?? "",
            value.date.map(ChekinanaDateOnly.string) ?? "",
            value.idx.map(String.init) ?? "",
            value.note,
            value.isFavorite ? "1" : "0",
            value.size?.rawValue ?? "",
            value.imageRef ?? "",
            String(value.updatedAt.timeIntervalSince1970.bitPattern),
        ].joined(separator: "\u{1f}")
    }

    private func recordFingerprint(_ value: Shame) -> String {
        [
            value.id.uuidString,
            value.idols.map(\.id.uuidString).sorted().joined(separator: ","),
            value.date.map(ChekinanaDateOnly.string) ?? "",
            value.note,
            value.imageRef ?? "",
        ].joined(separator: "\u{1f}")
    }

    private func recordFingerprint(_ value: Douga) -> String {
        [
            value.id.uuidString,
            value.idols.map(\.id.uuidString).sorted().joined(separator: ","),
            value.date.map(ChekinanaDateOnly.string) ?? "",
            value.note,
            value.videoRef ?? "",
        ].joined(separator: "\u{1f}")
    }

    private func resolveIdolList(_ value: String) throws -> [Idol] {
        let tokens = value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            throw ChekinanaAddChekiError.invalidIdolList
        }

        var resolved: [Idol] = []
        var seenIDs = Set<UUID>()

        for token in tokens {
            let idol = try resolveUniqueIdol(token)
            if seenIDs.insert(idol.id).inserted {
                resolved.append(idol)
            }
        }

        return resolved
    }

    private func resolveUniqueIdol(_ token: String) throws -> Idol {
        let normalizedToken = token.lowercased()
        let descriptor = FetchDescriptor<Idol>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        let idols = try modelContext.fetch(descriptor).filter {
            ChekinanaVisibilityPolicy.includesIdol($0.id, hiddenIDs: hiddenIDs)
        }
        let idMatches = idols.filter { idol in
            idol.id.uuidString.lowercased().hasPrefix(normalizedToken)
        }

        if idMatches.count > 1 {
            throw ChekinanaAddChekiError.ambiguousIdol(token)
        }

        if let idol = idMatches.first {
            return idol
        }

        let nameMatches = idols.filter { idol in
            idol.name.range(of: token, options: [.caseInsensitive]) != nil
        }

        guard !nameMatches.isEmpty else {
            throw ChekinanaAddChekiError.noIdol(token)
        }

        guard nameMatches.count == 1, let idol = nameMatches.first else {
            throw ChekinanaAddChekiError.ambiguousIdol(token)
        }

        return idol
    }

    private func resolveUniqueEvent(_ token: String) throws -> Event {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let events = try modelContext.fetch(FetchDescriptor<Event>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))
        let idMatches = events.filter { $0.id.uuidString.lowercased().hasPrefix(normalizedToken) }
        if idMatches.count > 1 { throw ChekinanaEventError.ambiguous(token) }
        if let event = idMatches.first { return event }

        let exactNameMatches = events.filter {
            $0.name.compare(token, options: [.caseInsensitive]) == .orderedSame
        }
        if exactNameMatches.count > 1 { throw ChekinanaEventError.ambiguous(token) }
        if let event = exactNameMatches.first { return event }

        let nameMatches = events.filter {
            $0.name.range(of: token, options: [.caseInsensitive]) != nil
        }
        guard !nameMatches.isEmpty else { throw ChekinanaEventError.notFound(token) }
        guard nameMatches.count == 1, let event = nameMatches.first else {
            throw ChekinanaEventError.ambiguous(token)
        }
        return event
    }

    private func resolveEvent(_ value: String?) throws -> Event? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              rawValue != "?",
              rawValue != "-" else {
            return nil
        }

        let normalizedValue = rawValue.lowercased()
        let descriptor = FetchDescriptor<Event>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let events = try modelContext.fetch(descriptor)
        let idMatches = events.filter { event in
            event.id.uuidString.lowercased().hasPrefix(normalizedValue)
        }
        if idMatches.count > 1 {
            throw ChekinanaAddChekiError.ambiguousEvent(rawValue)
        }
        if let event = idMatches.first { return event }

        let exactNameMatches = events.filter {
            $0.name.compare(rawValue, options: [.caseInsensitive]) == .orderedSame
        }
        if exactNameMatches.count > 1 {
            throw ChekinanaAddChekiError.ambiguousEvent(rawValue)
        }
        if let event = exactNameMatches.first { return event }

        let nameMatches = events.filter {
            $0.name.range(of: rawValue, options: [.caseInsensitive]) != nil
        }
        guard !nameMatches.isEmpty else {
            throw ChekinanaAddChekiError.noEvent(rawValue)
        }
        guard nameMatches.count == 1, let event = nameMatches.first else {
            throw ChekinanaAddChekiError.ambiguousEvent(rawValue)
        }

        return event
    }

    private func ensureEventIsNotDuplicate(name: String, date: Date?, url: URL?) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let events = try modelContext.fetch(FetchDescriptor<Event>())
        let duplicate = events.contains { event in
            let sameName = event.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
            let sameDate: Bool
            switch (event.date, date) {
            case (nil, nil): sameDate = true
            case let (lhs?, rhs?): sameDate = sameCalendarDate(lhs, rhs)
            default: sameDate = false
            }
            return sameName && sameDate && event.weiboURL?.absoluteString == url?.absoluteString
        }
        if duplicate { throw ChekinanaEventError.duplicate }
    }

    private func chekiEventFilter(_ value: String?) throws -> ChekiEventFilter {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return .none
        }

        if rawValue == "?" {
            return .empty
        }

        guard let event = try resolveEvent(rawValue) else {
            throw ChekinanaAddChekiError.noEvent(rawValue)
        }

        return .event(event)
    }

    private func validateChekiAssociations(
        idols: [Idol],
        event: Event?,
        eventDate: Date?,
        allowEmptyIdols: Bool = false,
        allowMissingOccasion: Bool = false
    ) throws {
        // Media is the only required Cheki field. Associations remain optional
        // and can be filled later by scan review or the editor.
        _ = (idols, event, eventDate, allowEmptyIdols, allowMissingOccasion)
    }

    private func sameChekiGroup(
        idolIDs: [UUID],
        eventID: UUID?,
        eventDate: Date?,
        otherIdolIDs: [UUID],
        otherEventID: UUID?,
        otherEventDate: Date?
    ) -> Bool {
        ChekinanaChekiGroupKey(idolIDs: idolIDs, date: eventDate)
            == ChekinanaChekiGroupKey(
                idolIDs: otherIdolIDs,
                date: otherEventDate
            )
    }

    private func nextChekiIndex(
        idolIDs: [UUID],
        eventID: UUID?,
        eventDate: Date?,
        excludingChekiID: UUID?
    ) throws -> Int? {
        guard let group = ChekinanaChekiGroupKey(idolIDs: idolIDs, date: eventDate) else {
            return nil
        }
        let chekis = try modelContext.fetch(FetchDescriptor<Cheki>())
        let snapshots = chekis.compactMap { cheki -> ChekinanaChekiIndexSnapshot? in
            guard let chekiGroup = ChekinanaChekiGroupKey(
                idolIDs: cheki.idols.map(\.id),
                date: cheki.date
            ) else {
                return nil
            }
            return .init(chekiID: cheki.id, group: chekiGroup, idx: cheki.idx)
        }
        do {
            return try ChekinanaChekiIndexing.nextIndex(
                for: group,
                existing: snapshots,
                excludingChekiID: excludingChekiID
            )
        } catch ChekinanaChekiIndexingError.overflow {
            throw ChekinanaAddChekiError.indexOverflow
        }
    }

    private func parseOptionalBool(_ value: String?, argumentName: String) throws -> Bool? {
        guard let value else {
            return nil
        }

        switch value.lowercased() {
        case "?", "-":
            return nil
        case "true":
            return true
        case "false":
            return false
        default:
            throw ChekinanaAddChekiError.invalidArgumentValue(argumentName, value)
        }
    }

    private func parseOptionalChekiSize(_ value: String?) throws -> ChekiSize? {
        guard let value else {
            return nil
        }

        if value == "?" || value == "-" {
            return nil
        }

        guard let size = ChekiSize(rawValue: value.lowercased()) else {
            throw ChekinanaAddChekiError.invalidArgumentValue("size", value)
        }

        return size
    }

    private func parseCalendarDate(_ value: String) throws -> Date {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 10,
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)] == "-",
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)] == "-",
              trimmed.enumerated().allSatisfy({ offset, character in
                  offset == 4 || offset == 7 ? character == "-" : character.isNumber
              }) else {
            throw ChekinanaAddChekiError.invalidArgumentValue("date", value)
        }
        guard let date = ChekinanaDateOnly.parse(trimmed),
              ChekinanaDateOnly.string(date) == trimmed else {
            throw ChekinanaAddChekiError.invalidArgumentValue("date", value)
        }
        return date
    }

    private func calendarDateString(_ date: Date) -> String {
        ChekinanaDateOnly.string(date)
    }

    private func normalizedCalendarDay(_ date: Date?) -> Date? {
        guard let date else { return nil }
        return ChekinanaDateOnly.canonicalized(date)
    }

    private func sameCalendarDate(_ lhs: Date, _ rhs: Date) -> Bool {
        ChekinanaDateOnly.sameDay(lhs, rhs)
    }

    private func optionalHTTPURL(_ value: String) throws -> URL? {
        let normalized = value.lowercased()
        guard normalized.hasPrefix("http://") || normalized.hasPrefix("https://") else {
            return nil
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased() else {
            throw ChekinanaEventError.invalidURL
        }
        guard ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            throw ChekinanaEventError.invalidURL
        }
        return url
    }

    private func requireHTTPURL(_ value: String) throws -> URL {
        guard let url = try optionalHTTPURL(value) else {
            throw ChekinanaEventError.invalidURL
        }
        return url
    }

    private func optionalNonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shortEventID(_ event: Event) -> String {
        String(event.id.uuidString.prefix(8)).lowercased()
    }

    private func eventCard(_ event: Event) -> ChekinanaEventCard {
        ChekinanaEventCard(
            id: event.id,
            name: event.name,
            date: event.date.map(calendarDateString) ?? "",
            city: event.city ?? "",
            livehouse: event.resolvedLivehouse ?? "",
            price: event.price ?? "",
            weiboURL: event.weiboURL?.absoluteString ?? "",
            ticketURL: event.ticketURL?.absoluteString ?? "",
            note: event.note,
            confirmationCode: nil
        )
    }

    private func eventCard(
        _ fields: ChekinanaEventCandidateFields,
        confirmationCode: String
    ) -> ChekinanaEventCard {
        ChekinanaEventCard(
            id: UUID(),
            name: fields.name,
            date: fields.date,
            city: fields.city,
            livehouse: fields.livehouse,
            price: fields.price,
            weiboURL: fields.weiboURL,
            ticketURL: fields.ticketURL,
            note: fields.note,
            confirmationCode: confirmationCode
        )
    }

    private func eventDetails(_ event: Event, prefix: String? = nil) -> String {
        var parts: [String] = []
        if let prefix { parts.append(prefix) }
        let unset = ChekinanaCommandCopy.text("value.unset", fallback: "Not set")
        parts.append(ChekinanaCommandCopy.format("field.name", fallback: "Name: %@", event.name))
        parts.append(ChekinanaCommandCopy.format(
            "field.date",
            fallback: "Date: %@",
            event.date.map(calendarDateString)
                ?? ChekinanaCommandCopy.text("value.date_undetermined", fallback: "Date not determined")
        ))
        parts.append(ChekinanaCommandCopy.format("field.city", fallback: "City: %@", event.city ?? unset))
        parts.append(ChekinanaCommandCopy.format("field.livehouse", fallback: "Livehouse: %@", event.resolvedLivehouse ?? unset))
        parts.append(ChekinanaCommandCopy.format("field.weibo", fallback: "Weibo: %@", event.weiboURL?.absoluteString ?? unset))
        parts.append(ChekinanaCommandCopy.format("field.ticket", fallback: "Ticket: %@", event.ticketURL?.absoluteString ?? unset))
        parts.append(ChekinanaCommandCopy.format("field.note", fallback: "Note: %@", event.note.isEmpty ? unset : event.note))
        return parts.joined(separator: " · ")
    }

    private func eventPreviewDetails(
        id: UUID?,
        name: String,
        date: Date?,
        weiboURL: URL?,
        prefix: String?,
        confirmationCode: String?
    ) -> String {
        _ = id
        _ = confirmationCode
        var parts: [String] = []
        if let prefix { parts.append(prefix) }
        let unset = ChekinanaCommandCopy.text("value.unset", fallback: "Not set")
        parts.append(ChekinanaCommandCopy.format("field.name", fallback: "Name: %@", name))
        parts.append(ChekinanaCommandCopy.format("field.date", fallback: "Date: %@", date.map(calendarDateString) ?? unset))
        parts.append(ChekinanaCommandCopy.format("field.link", fallback: "Link: %@", weiboURL?.absoluteString ?? unset))
        return parts.joined(separator: " · ")
    }

    private func chekiDetails(_ cheki: Cheki, prefix: String? = nil) -> String {
        chekiPreviewDetails(
            id: cheki.id,
            idols: cheki.idols,
            event: cheki.event,
            eventDate: cheki.date,
            imageRef: cheki.imageRef,
            createdAt: cheki.createdAt,
            idx: cheki.idx,
            userAppears: cheki.userAppears,
            size: cheki.size,
            note: cheki.note,
            prefix: prefix,
            confirmationCode: nil
        )
    }

    private func chekiPreviewDetails(
        id: UUID,
        idols: [Idol],
        event: Event?,
        eventDate: Date?,
        imageRef: String?,
        createdAt: Date,
        idx: Int?,
        userAppears: Bool?,
        size: ChekiSize?,
        note: String,
        prefix: String?,
        confirmationCode: String?
    ) -> String {
        var lines: [String] = []
        if let prefix { lines.append(prefix) }
        lines.append("id=\(id.uuidString.lowercased())")
        let idolText = idols
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.name)[\(String($0.id.uuidString.prefix(8)).lowercased())]" }
            .joined(separator: ", ")
        lines.append("idols=\(idolText.isEmpty ? "-" : idolText)")
        if let event {
            lines.append("event=\(event.name)[\(shortEventID(event))]")
        } else if let eventDate {
            lines.append("date=\(calendarDateString(eventDate))")
        } else {
            lines.append("event=-")
            lines.append("date=-")
        }
        lines.append("image=\(imageRef ?? "-")")
        lines.append("createdAt=\(ISO8601DateFormatter().string(from: createdAt))")
        lines.append("idx=\(idx.map(String.init) ?? "pending/missing")")
        lines.append("user=\(userAppears.map(String.init) ?? "?")")
        lines.append("size=\(size?.rawValue ?? "?")")
        lines.append("note=\(note.isEmpty ? "-" : note)")
        if let confirmationCode { lines.append("confirm=\(confirmationCode)") }
        return lines.joined(separator: " | ")
    }

    private var helpText: String {
        ChekinanaCommandCopy.text(
            "help",
            fallback: """
            Tell me what you want to do; you do not need to remember commands or IDs.

            For example:
            · Add Idol Alice
            · Add Event Summer Live on 2026-08-01
            · Show all Idols or Events
            · Rename Alice to AlicePrime
            · Scan these Cheki
            · Show Cheki taken with Alice

            Selected photo-library images can be added directly. Idol, Event, date, and other metadata can be filled later.

            Before adding, editing, or deleting, I will show a preview. Use the Confirm or Cancel button.
            To show, edit, or delete a Cheki, select its card first and then describe the action.
            """
        )
    }

    private var commandHelpLines: [String] {
        [
            "help",
            "clear  (clears visible command history only)",
            "confirm [8_hex_code] (no code confirms the latest unambiguous operation)",
            "cancel <8_hex_code>",
            "cancel all",
            "addidol <idol_name>",
            "listidol",
            "showidol <idol_id|name>",
            "editidol <candidate_code|idol_id> <field>=<value> [...]  fields: name, group, birthday, color, verification, bio, avatar; use - to clear optional fields",
            "deleteidol <idol_id>",
            "addevent <url> name=<name> date=YYYY-MM-DD | addevent <name> date=YYYY-MM-DD",
            "listevent",
            "showevent <event_id|name>",
            "editevent <event_id|name> [name=<name>] [date=YYYY-MM-DD|-] [url=<url>|-]",
            "deleteevent <event_id|name>",
            "scancheki  (starts the managed backend when needed, then processes selected photos into temporary Cheki)",
            "discardcheki <temporary_cheki_id|all>",
            "addcheki [idol=<idol_id_or_name[,idol_id_or_name...]>] [event=<event_id>] [date=YYYY-MM-DD] [user=true|false|?] [size=mini|wide|else|?] [note=<text>]  (uses selected album photos; metadata is optional; idx is assigned once idol and date exist)",
            "addscancheki <temporary_cheki_id[,temporary_cheki_id...]|all> [idol=<idol_id_or_name[,idol_id_or_name...]>] [date=YYYY-MM-DD] [event=<event_id>] [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
            "listcheki [idol=<idol_id_or_name>] [event=<event_id|?>] [date=YYYY-MM-DD]",
            "showcheki <cheki_id>",
            "editcheki <cheki_id> [idol=<idol[,idol...]>|-] [date=YYYY-MM-DD|-] [event=<event_id>|-] [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
            "downloadcheki <cheki_id>",
            "deletecheki <cheki_id>",
        ]
    }

    private var commandUsages: [String: [String]] {
        [
            "clear": [
                "clear",
            ],
            "addidol": [
                "addidol <idol_name>",
            ],
            "selectidolcandidate": [
                "selectidolcandidate <selection_token>",
            ],
            "confirmidolcandidate": [
                "confirmidolcandidate <selection_token>",
            ],
            "listidol": [
                "listidol",
            ],
            "showidol": [
                "showidol <idol_id|name>",
            ],
            "editidol": [
                "editidol <candidate_code|idol_id> <field>=<value> [...]",
                "fields: name, group, birthday, color, verification, bio, avatar (avatar_url is accepted as an alias)",
                "use - to clear an optional field; quote values containing spaces",
            ],
            "deleteidol": [
                "deleteidol <idol_id>",
            ],
            "favoriteidol": [
                "favoriteidol <idol_id|name> favorite=true|false",
            ],
            "navigate": [
                "navigate <scan|idols|calendar|events|gallery|settings|chekiroku_import> [date=YYYY-MM-DD]",
            ],
            "openscan": [
                "openscan [recognize_date=true|false] [recognize_idol=true|false] [includes_unassigned=true|false] [candidate_refs=<refs>] [fixed_date=YYYY-MM-DD] [date_from=YYYY-MM-DD date_to=YYYY-MM-DD]",
            ],
            "addevent": [
                "addevent <url> name=<name> date=YYYY-MM-DD",
                "addevent <name> date=YYYY-MM-DD",
                "creating an Event requires confirmation",
            ],
            "listevent": [
                "listevent",
            ],
            "showevent": [
                "showevent <event_id|name>",
            ],
            "editevent": [
                "editevent <event_id|name> [name=<name>] [date=YYYY-MM-DD|-] [url=<http(s)_url>|-]",
                "provide at least one field; use - to clear optional date/url",
            ],
            "deleteevent": [
                "deleteevent <event_id|name>",
                "an Event referenced by Cheki cannot be deleted",
            ],
            "addcheki": [
                "addcheki [idol=<idol_id_or_name[,idol_id_or_name...]>] [event=<event_id>] [date=YYYY-MM-DD] [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
                "uses selected album photos; idol, event, date, and other metadata are optional; this command never uses scancheki temporary objects",
                "idx is assigned only after both idol and date exist",
            ],
            "addscancheki": [
                "addscancheki <temporary_cheki_id[,temporary_cheki_id...]|all> [idol=<idol_id_or_name[,idol_id_or_name...]>] [date=YYYY-MM-DD] [event=<event_id>] [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
                "temporary objects are consumed only after successful confirmation; idx is assigned on confirm",
            ],
            "scancheki": [
                "scancheki [expected=<positive_int>] [scanner_size=auto|mini|wide] [postprocess=off|denoise|sharpen] [wb=true|false] [sleeves=true|false] [direct=true|false]",
                "select one or more photos first; scanner results remain temporary until addscancheki is confirmed",
            ],
            "discardcheki": [
                "discardcheki <temporary_cheki_id|all>",
                "temporary images referenced by pending addscancheki confirmations are retained; confirm or cancel first",
            ],
            "downloadtemporarycheki": [
                "downloadtemporarycheki <temporary_cheki_id>",
                "saves the clean temporary image without a bbox overlay",
            ],
            "listcheki": [
                "listcheki [idol=<idol_id_or_name>] [event=<event_id|?>] [date=YYYY-MM-DD]",
            ],
            "showcheki": [
                "showcheki <cheki_id>",
            ],
            "editcheki": [
                "editcheki <cheki_id> [idol=<idol_id_or_name[,idol_id_or_name...]>|-] [date=YYYY-MM-DD|-] [event=<event_id>|-] [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
                "provide at least one field; changing Idol/Event/date assigns the next group idx on confirm",
                "use ? or - to clear user/size and - to clear note",
            ],
            "downloadcheki": [
                "downloadcheki <cheki_id>",
            ],
            "deletecheki": [
                "deletecheki <cheki_id>",
            ],
            "listrecord": [
                "listrecord [cheki|shame|douga] [idols=<refs>] [date=YYYY-MM-DD] [event=<ref> for Cheki only] [idx=<positive_int> for Cheki only] [favorite=true|false] [size=mini|wide]",
            ],
            "showrecord": [
                "showrecord <cheki|shame|douga> target=<record_ref>",
            ],
            "addrecord": [
                "addrecord cheki [idols=<refs>] [date=YYYY-MM-DD] [note=<text>]",
                "Cheki only: [event=<ref>] [idx=<positive_int>] [favorite=true|false] [size=mini|wide]",
            ],
            "editrecord": [
                "editrecord <cheki|shame|douga> target=<record_ref> [patch fields] [clear_fields=<fields>]",
                "Event is a Cheki-only field.",
            ],
            "deleterecord": [
                "deleterecord <cheki|shame|douga> target=<record_ref>",
            ],
        ]
    }
}

private struct SavedChekiImage: Sendable {
    let ref: String
    let url: URL
}

struct ChekinanaRenderedImage: @unchecked Sendable, Equatable {
    let cgImage: CGImage

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cgImage === rhs.cgImage
    }
}

actor ChekinanaRemoteRequestLimiter {
    static let shared = ChekinanaRemoteRequestLimiter(limit: 4)

    struct Snapshot: Equatable, Sendable {
        let activeCount: Int
        let waitingCount: Int
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func perform<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        // Cancellation can race with a waiter being granted the permit. The
        // permit is already owned here, so the defer must release/transfer it.
        try Task.checkCancellation()
        return try await operation()
    }

    func snapshot() -> Snapshot {
        Snapshot(activeCount: active, waitingCount: waiters.count)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // The waiter may already own a transferred permit. `perform`
            // checks cancellation before operation and releases that permit.
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        precondition(active > 0)
        if waiters.isEmpty {
            active -= 1
        } else {
            // `active` remains unchanged: ownership moves directly from the
            // finishing request to this FIFO waiter.
            waiters.removeFirst().continuation.resume()
        }
    }
}

/// Per-Scan-session concurrency boundary for Apple Vision Body Pose work.
/// It is deliberately independent from Date networking and the Idol encoder.
actor ChekinanaBodyPoseLimiter {
    static let defaultLimit = 4

    private let limiter: ChekinanaRemoteRequestLimiter

    init(limit: Int = defaultLimit) {
        limiter = ChekinanaRemoteRequestLimiter(limit: limit)
    }

    func perform<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await limiter.perform(operation)
    }

    func snapshot() async -> ChekinanaRemoteRequestLimiter.Snapshot {
        await limiter.snapshot()
    }
}

actor ChekinanaBoundedRemoteImageDownloader {
    static let shared = ChekinanaBoundedRemoteImageDownloader()

    typealias DownloadOperation = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    enum DownloadError: Error, Equatable {
        case invalidResponse
        case invalidContentType
        case emptyBody
        case bodyTooLarge
    }

    static let maximumBodySize = 8 * 1_024 * 1_024
    private let download: DownloadOperation

    init(
        session: URLSession = ChekinanaBoundedRemoteImageDownloader.makeSession()
    ) {
        download = { request in
            try await session.download(for: request)
        }
    }

    init(download: @escaping DownloadOperation) {
        self.download = download
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary =
            ChekinanaCatalogueNetworkPolicy.directConnectionProxyDictionary()
        return URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (temporaryURL, response) = try await download(request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else {
            throw DownloadError.invalidResponse
        }
        let normalizedContentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedContentType,
              normalizedContentType.hasPrefix("image/"),
              normalizedContentType.count > "image/".count else {
            throw DownloadError.invalidContentType
        }
        if response.expectedContentLength > Int64(Self.maximumBodySize) {
            throw DownloadError.bodyTooLarge
        }
        let fileSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let fileSize, fileSize > 0 else {
            throw DownloadError.emptyBody
        }
        guard fileSize <= Self.maximumBodySize else {
            throw DownloadError.bodyTooLarge
        }
        let data = try Data(contentsOf: temporaryURL)
        try Task.checkCancellation()
        guard !data.isEmpty else {
            throw DownloadError.emptyBody
        }
        guard data.count <= Self.maximumBodySize else {
            throw DownloadError.bodyTooLarge
        }
        return data
    }
}

actor ChekinanaRemoteImageCache {
    static let shared = ChekinanaRemoteImageCache()

    private var entries: [String: ChekinanaRenderedImage] = [:]
    private var accessOrder: [String] = []
    private var inFlight: [String: Task<ChekinanaRenderedImage?, Never>] = [:]
    private var failedUntil: [String: Date] = [:]
    private let maximumEntryCount = 80

    func cachedImage(for url: URL, maxDimension: Int) -> ChekinanaRenderedImage? {
        let key = "\(url.absoluteString)|\(maxDimension)"
        guard let cached = entries[key] else { return nil }
        touch(key)
        return cached
    }

    func image(for url: URL, maxDimension: Int) async -> ChekinanaRenderedImage? {
        let key = "\(url.absoluteString)|\(maxDimension)"
        if let cached = entries[key] {
            touch(key)
            return cached
        }
        if let retryDate = failedUntil[key], retryDate > Date() {
            return nil
        }
        failedUntil[key] = nil
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<ChekinanaRenderedImage?, Never> {
            let request: URLRequest = {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                return request
            }()
            let data: Data
            do {
                data = try await ChekinanaRemoteRequestLimiter.shared.perform {
                    let data = try await ChekinanaBoundedRemoteImageDownloader.shared.data(
                        for: request
                    )
                    try Task.checkCancellation()
                    return data
                }
            } catch {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            return await ChekinanaImageWorker.thumbnailImage(
                from: data,
                maxDimension: maxDimension
            )
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            entries[key] = image
            failedUntil[key] = nil
            touch(key)
            while accessOrder.count > maximumEntryCount, let oldest = accessOrder.first {
                accessOrder.removeFirst()
                entries[oldest] = nil
                failedUntil[oldest] = nil
            }
        } else {
            // A broken URL, offline proxy, or DNS failure should not trigger a
            // new PAC/DNS request every time SwiftUI recomputes or scrolls.
            failedUntil[key] = Date().addingTimeInterval(60)
            if failedUntil.count > maximumEntryCount {
                failedUntil = failedUntil.filter { $0.value > Date() }
            }
        }
        return image
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

enum ChekinanaCatalogueAvatarError: LocalizedError {
    case invalidReference
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidReference:
            ChekinanaCommandCopy.text("error.avatar_reference_invalid", fallback: "Catalogue avatar reference is invalid.")
        case .unavailable:
            ChekinanaCommandCopy.text("error.avatar_unavailable", fallback: "Catalogue avatar is temporarily unavailable.")
        }
    }
}

actor ChekinanaCatalogueAvatarThumbnailCache {
    static let shared = ChekinanaCatalogueAvatarThumbnailCache()

    private var entries: [String: Data] = [:]
    private var accessOrder: [String] = []
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let maximumEntryCount = 120

    func thumbnailData(for candidate: ChekinanaEnrichedIdol) async throws -> Data? {
        guard let rawURL = candidate.avatarUrl else { return nil }
        guard let identity = ChekinanaIdolAvatarIdentity.make(
            sourceID: candidate.sourceId,
            avatarURL: rawURL
        ), let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ChekinanaCatalogueAvatarError.invalidReference
        }
        if let data = entries[identity] {
            touch(identity)
            return data
        }
        if let task = inFlight[identity] {
            guard let data = await task.value else {
                throw ChekinanaCatalogueAvatarError.unavailable
            }
            return data
        }

        let task = Task<Data?, Never> {
            let request: URLRequest = {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                return request
            }()
            var downloaded: Data?
            for attempt in 0..<2 {
                guard !Task.isCancelled else { return nil }
                do {
                    downloaded = try await ChekinanaRemoteRequestLimiter.shared.perform {
                        let data = try await ChekinanaBoundedRemoteImageDownloader.shared.data(
                            for: request
                        )
                        try Task.checkCancellation()
                        return data
                    }
                    break
                } catch is CancellationError {
                    return nil
                } catch {
                    if attempt == 0 { continue }
                    return nil
                }
            }
            guard !Task.isCancelled, let downloaded else { return nil }
            // The shared permit protects only network pressure. ImageIO can be
            // synchronously non-cooperative, so decoding while holding a
            // permit would block future catalogue searches/downloads after the
            // candidate batch has already timed out.
            guard let thumbnail = await ChekinanaImageWorker.thumbnailData(
                    from: downloaded,
                    maxDimension: 256
                  ),
                  !thumbnail.isEmpty,
                  !Task.isCancelled else {
                return nil
            }
            return thumbnail
        }
        inFlight[identity] = task
        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight[identity] = nil
        try Task.checkCancellation()
        guard let data else {
            throw ChekinanaCatalogueAvatarError.unavailable
        }
        entries[identity] = data
        touch(identity)
        while accessOrder.count > maximumEntryCount, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            entries[oldest] = nil
        }
        return data
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

actor ChekinanaThumbnailCache {
    static let shared = ChekinanaThumbnailCache()

    private var entries: [String: ChekinanaRenderedImage] = [:]
    private var accessOrder: [String] = []
    private var inFlight: [String: Task<ChekinanaRenderedImage?, Never>] = [:]
    private let maximumEntryCount = 80

    func thumbnailImage(
        from data: Data,
        key sourceKey: String,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        let key = "data|\(sourceKey)|\(maxDimension)"
        return await cachedImage(for: key) {
            await ChekinanaImageWorker.thumbnailImage(from: data, maxDimension: maxDimension)
        }
    }

    func thumbnailImage(
        forImageRef imageRef: String?,
        key sourceKey: String,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        let key = Self.referenceCacheKey(
            kind: "ref",
            imageRef: imageRef,
            sourceKey: sourceKey,
            maxDimension: maxDimension
        )
        return await cachedImage(for: key) {
            await ChekinanaImageWorker.thumbnailImage(
                fromImageRef: imageRef,
                maxDimension: maxDimension
            )
        }
    }

    func thumbnailImage(
        forManagedImageRef imageRef: String?,
        key sourceKey: String,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        let key = Self.referenceCacheKey(
            kind: "managed-ref",
            imageRef: imageRef,
            sourceKey: sourceKey,
            maxDimension: maxDimension
        )
        return await cachedImage(for: key) {
            await ChekinanaImageWorker.thumbnailImage(
                fromManagedImageRef: imageRef,
                maxDimension: maxDimension
            )
        }
    }

    static func referenceCacheKey(
        kind: String,
        imageRef: String?,
        sourceKey: String,
        maxDimension: Int
    ) -> String {
        let normalizedRef = imageRef?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyValue ?? "<nil>"
        return "\(kind)|\(sourceKey)|\(normalizedRef)|\(maxDimension)"
    }

    private func cachedImage(
        for key: String,
        loader: @escaping @Sendable () async -> ChekinanaRenderedImage?
    ) async -> ChekinanaRenderedImage? {
        if let cached = entries[key] {
            touch(key)
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<ChekinanaRenderedImage?, Never> { await loader() }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            entries[key] = image
            touch(key)
            while accessOrder.count > maximumEntryCount, let oldest = accessOrder.first {
                accessOrder.removeFirst()
                entries[oldest] = nil
            }
        }
        return image
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

private extension String {
    var nonEmptyValue: String? { isEmpty ? nil : self }
}

enum ChekinanaImageSourceValidator {
    static let maximumThumbnailDimension = 8_192
    static let maximumSourceDimension = 32_768
    static let maximumSourcePixelCount = 100_000_000.0

    static func accepts(source: CGImageSource, maxDimension: Int) -> Bool {
        guard (1...maximumThumbnailDimension).contains(maxDimension),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              accepts(properties: properties) else {
            return false
        }
        return true
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

    private static func numericValue(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    static func exifOrientation(source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
              let value = numericValue(properties[kCGImagePropertyOrientation]),
              value.isFinite,
              value.rounded() == value,
              value >= 1,
              value <= 8 else {
            return nil
        }
        return Int(value)
    }

    /// ImageIO may omit the default orientation tag when writing an upright
    /// JPEG. Missing and explicit `1` are the same normalized pixel contract.
    static func effectiveExifOrientation(source: CGImageSource) -> Int {
        exifOrientation(source: source) ?? 1
    }
}

enum ChekinanaImageWorker {
    private final class DecodeRequestState<Result: Sendable>: @unchecked Sendable {
        typealias Operation = @Sendable () -> Result?

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result?, Never>?
        private var operation: Operation?
        private var resolved = false

        init(operation: @escaping Operation) {
            self.operation = operation
        }

        /// Installs the waiter before the lightweight queue item is submitted.
        /// If cancellation won before installation, the new waiter is resumed
        /// immediately and no queue item is required.
        func install(_ continuation: CheckedContinuation<Result?, Never>) -> Bool {
            lock.lock()
            if resolved {
                lock.unlock()
                continuation.resume(returning: nil)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func cancel() {
            let continuationToResume: CheckedContinuation<Result?, Never>?
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return
            }
            resolved = true
            operation = nil
            continuationToResume = continuation
            continuation = nil
            lock.unlock()
            continuationToResume?.resume(returning: nil)
        }

        /// Removes the potentially large closure from the state before running
        /// it. Cancellation while queued clears it instead, so the queue item
        /// itself never retains image Data or caller captures.
        func claimOperation() -> Operation? {
            lock.lock()
            defer { lock.unlock() }
            guard !resolved else { return nil }
            let claimed = operation
            operation = nil
            return claimed
        }

        func complete(with result: Result?) {
            let continuationToResume: CheckedContinuation<Result?, Never>?
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return
            }
            resolved = true
            operation = nil
            continuationToResume = continuation
            continuation = nil
            lock.unlock()
            continuationToResume?.resume(returning: result)
        }
    }

    private static let maximumInMemorySourceBytes = 128 * 1_024 * 1_024
    private static let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.chekinana.image-decode"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func previewImage(
        from imageData: Data,
        maxDimension: Int
    ) async -> ChekinanaRenderedImage? {
        await performDecode {
            guard let source = makeImageSource(from: imageData),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension),
                  !Task.isCancelled else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }
    }

    static func previewImage(
        fromImageRef imageRef: String,
        maxDimension: Int
    ) async -> ChekinanaRenderedImage? {
        await performDecode {
            guard let url = ChekiImageRefResolver.localFileURL(for: imageRef),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [
                      kCGImageSourceShouldCache: false,
                  ] as CFDictionary),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension),
                  !Task.isCancelled else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }
    }

    static func thumbnailImage(
        from imageData: Data,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        await performDecode {
            guard let source = makeImageSource(from: imageData),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension) else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }
    }

    static func thumbnailImage(
        fromImageRef imageRef: String?,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        await performDecode {
            guard let url = ChekiImageRefResolver.localFileURL(for: imageRef),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [
                    kCGImageSourceShouldCache: false,
                  ] as CFDictionary),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension) else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }
    }

    static func thumbnailImage(
        fromManagedImageRef imageRef: String?,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        await performDecode {
            guard let url = ChekiImageRefResolver.managedLocalFileURL(for: imageRef),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [
                    kCGImageSourceShouldCache: false,
                  ] as CFDictionary),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension) else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }
    }

    static func thumbnailImage(
        fromFileAt url: URL,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        await performDecode {
            guard ChekiImageRefResolver.isRegularReadableFile(url),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [
                    kCGImageSourceShouldCache: false,
                  ] as CFDictionary),
                  let image = makeThumbnailImage(
                    from: source,
                    maxDimension: maxDimension
                  ) else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }
    }

    static func thumbnailData(from imageData: Data, maxDimension: Int = 512) async -> Data? {
        await performDecode {
            makeThumbnailData(from: imageData, maxDimension: maxDimension)
        }
    }

    static func thumbnailDataBatch(from images: [Data], maxDimension: Int = 512) async -> [Data?] {
        await performDecode {
            var thumbnails: [Data?] = []
            thumbnails.reserveCapacity(images.count)
            for image in images {
                guard !Task.isCancelled else { return nil }
                thumbnails.append(makeThumbnailData(from: image, maxDimension: maxDimension))
            }
            return thumbnails
        } ?? Array(repeating: nil, count: images.count)
    }

    static func thumbnailData(fromFileAt url: URL, maxDimension: Int = 512) async -> Data? {
        await performDecode {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary) else {
                return nil
            }
            return makeThumbnailData(from: source, maxDimension: maxDimension)
        }
    }

    static func reencodedJPEGData(from imageData: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else {
                return nil
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                "public.jpeg" as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }.value
    }

    static func downsampledJPEGData(
        from imageData: Data,
        maxDimension: Int,
        compressionQuality: Double = 0.9
    ) async -> Data? {
        await performDecode {
            guard compressionQuality.isFinite,
                  (0...1).contains(compressionQuality),
                  let source = makeImageSource(from: imageData),
                  let thumbnail = makeThumbnailImage(
                    from: source,
                    maxDimension: maxDimension
                  ) else {
                return nil
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                "public.jpeg" as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(
                destination,
                thumbnail,
                [kCGImageDestinationLossyCompressionQuality: compressionQuality]
                    as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }

    fileprivate static func saveChekiImageData(
        _ data: Data,
        id: UUID,
        filenameExtension: String
    ) async throws -> SavedChekiImage {
        try await Task.detached(priority: .userInitiated) {
            let isValidImage = autoreleasepool {
                guard let source = makeImageSource(from: data) else { return false }
                // Decode only a bounded verification thumbnail. This rejects
                // truncated/invalid bytes without allocating the full source
                // image and keeps the valid standardized-image fast path.
                return makeThumbnailImage(from: source, maxDimension: 64) != nil
            }
            guard isValidImage else {
                throw ChekinanaScanChekiError.invalidResultImage
            }
            let directory = try ChekiImageRefResolver.chekiImagesDirectory()
            let normalizedExtension = normalizedImageExtension(filenameExtension)
            let url = directory.appendingPathComponent("\(id.uuidString).\(normalizedExtension)")
            try data.write(to: url, options: [.atomic])
            return SavedChekiImage(ref: url.lastPathComponent, url: url)
        }.value
    }

    fileprivate static func promoteChekiImage(
        _ staged: SavedChekiImage,
        to id: UUID
    ) async throws -> SavedChekiImage {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let destination = staged.url.deletingLastPathComponent()
                .appendingPathComponent("\(id.uuidString).\(staged.url.pathExtension)")
            guard destination != staged.url,
                  !FileManager.default.fileExists(atPath: destination.path) else {
                throw ChekinanaAddChekiError.duplicateCheki(id.uuidString)
            }
            // Same-directory rename is atomic and never overwrites a file
            // another save already claimed for this record.
            try FileManager.default.moveItem(at: staged.url, to: destination)
            return SavedChekiImage(
                ref: destination.lastPathComponent,
                url: destination
            )
        }.value
    }

    static func removeItemIfPresent(at url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    private static func makeThumbnailData(from data: Data, maxDimension: Int) -> Data? {
        guard let source = makeImageSource(from: data) else {
            return nil
        }
        return makeThumbnailData(from: source, maxDimension: maxDimension)
    }

    private static func makeThumbnailData(from source: CGImageSource, maxDimension: Int) -> Data? {
        guard let thumbnail = makeThumbnailImage(from: source, maxDimension: maxDimension) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private static func makeThumbnailImage(from source: CGImageSource, maxDimension: Int) -> CGImage? {
        guard ChekinanaImageSourceValidator.accepts(
            source: source,
            maxDimension: maxDimension
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // ImageIO's metadata transform was the CoreGraphics NaN source
            // for malformed catalogue avatars. Decode first, then apply only
            // the validated EXIF orientation using finite pixel dimensions.
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let decodedImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ),
        decodedImage.width > 0,
        decodedImage.height > 0,
        max(decodedImage.width, decodedImage.height) <= maxDimension + 1 else {
            return nil
        }
        let orientation = ChekinanaImageSourceValidator.exifOrientation(source: source) ?? 1
        return normalizedThumbnailOrientation(
            decodedImage,
            exifOrientation: orientation,
            maxDimension: maxDimension
        )
    }

    static func normalizedThumbnailOrientation(
        _ image: CGImage,
        exifOrientation: Int,
        maxDimension: Int
    ) -> CGImage? {
        guard (1...8).contains(exifOrientation) else { return nil }
        if exifOrientation == 1 { return image }

        let orientation: UIImage.Orientation
        switch exifOrientation {
        case 2: orientation = .upMirrored
        case 3: orientation = .down
        case 4: orientation = .downMirrored
        case 5: orientation = .leftMirrored
        case 6: orientation = .right
        case 7: orientation = .rightMirrored
        case 8: orientation = .left
        default: orientation = .up
        }
        let swapsDimensions = (5...8).contains(exifOrientation)
        let width = swapsDimensions ? image.height : image.width
        let height = swapsDimensions ? image.width : image.height
        guard width > 0,
              height > 0,
              max(width, height) <= maxDimension + 1 else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: CGFloat(width), height: CGFloat(height)),
            format: format
        ).image { _ in
            UIImage(cgImage: image, scale: 1, orientation: orientation).draw(
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            )
        }
        return rendered.cgImage
    }

    private static func makeImageSource(from data: Data) -> CGImageSource? {
        guard !data.isEmpty, data.count <= maximumInMemorySourceBytes else {
            return nil
        }
        return CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary)
    }

    private static func performDecode<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result?
    ) async -> Result? {
        let state = DecodeRequestState(operation: operation)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else { return }
                decodeQueue.addOperation {
                    guard let operation = state.claimOperation() else { return }
                    let result = autoreleasepool(invoking: operation)
                    state.complete(with: result)
                }
            }
        } onCancel: {
            // This resumes a queued or running caller immediately. A running
            // synchronous decode may finish naturally, but loses the
            // exactly-once race and cannot resume or publish again.
            state.cancel()
        }
    }

#if DEBUG
    static func testingPerformDecode<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result?
    ) async -> Result? {
        await performDecode(operation)
    }

    static var testingDecodeOperationCount: Int {
        decodeQueue.operationCount
    }
#endif

    private static func normalizedImageExtension(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp":
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        default:
            return "jpg"
        }
    }
}

enum ChekiImageRefResolver {
    static func managedChekiFileURL(for imageRef: String?, chekiID: UUID) -> URL? {
        guard let imageRef = imageRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imageRef.isEmpty,
              imageRef == URL(fileURLWithPath: imageRef).lastPathComponent,
              URL(fileURLWithPath: imageRef).deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(chekiID.uuidString) == .orderedSame,
              let directory = try? chekiImagesDirectory() else {
            return nil
        }

        let candidate = directory.appendingPathComponent(imageRef)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    static func managedLocalFileURL(for imageRef: String?) -> URL? {
        guard let imageRef = imageRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imageRef.isEmpty,
              imageRef == URL(fileURLWithPath: imageRef).lastPathComponent,
              imageRef != ".",
              imageRef != "..",
              let directory = try? chekiImagesDirectory() else {
            return nil
        }

        let candidate = directory.appendingPathComponent(imageRef)
        return isRegularReadableFile(candidate) ? candidate : nil
    }

    static func localFileURL(for imageRef: String?) -> URL? {
        guard let imageRef = imageRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imageRef.isEmpty else {
            return nil
        }

        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let url = URL(string: imageRef), url.isFileURL {
            candidates.append(url)
        }

        if imageRef.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: imageRef))
        }

        if let directory = try? chekiImagesDirectory(),
           let filename = filename(from: imageRef) {
            candidates.append(directory.appendingPathComponent(filename))
        }

        return candidates.first { isRegularReadableFile($0, fileManager: fileManager) }
    }

    static func chekiImagesDirectory() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryName: String
#if DEBUG
        directoryName = ProcessInfo.processInfo.environment["CHEKINANA_UI_TEST_STORE"] == "1"
            ? "ChekinanaUITests"
            : "Chekinana"
#else
        directoryName = "Chekinana"
#endif
        let directory = appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("ChekiImages", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func isRegularReadableFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.isFileURL else {
            return false
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path) else {
            return false
        }

        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }

        return values.isRegularFile == true
    }

    private static func filename(from imageRef: String) -> String? {
        if let url = URL(string: imageRef), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }

        let pathComponent = URL(fileURLWithPath: imageRef).lastPathComponent
        return pathComponent.isEmpty ? nil : pathComponent
    }
}

private enum ChekiPhotoLibrarySaver {
    static func saveImage(at imageURL: URL) async throws {
        guard ChekiImageRefResolver.isRegularReadableFile(imageURL),
              UIImage(contentsOfFile: imageURL.path) != nil else {
            throw ChekinanaDownloadChekiError.unreadableLocalImage
        }

        let status = await addOnlyAuthorizationStatus()

        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted:
            throw ChekinanaDownloadChekiError.photoLibraryPermissionDenied
        case .notDetermined:
            throw ChekinanaDownloadChekiError.photoLibraryPermissionDenied
        @unknown default:
            throw ChekinanaDownloadChekiError.photoLibraryPermissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let assetCreationState = ChekiPhotoAssetCreationState()

            PHPhotoLibrary.shared().performChanges {
                if PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: imageURL) != nil {
                    assetCreationState.markCreated()
                }
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard assetCreationState.didCreate else {
                    continuation.resume(throwing: ChekinanaDownloadChekiError.invalidPhotoAsset)
                    return
                }

                guard success else {
                    continuation.resume(throwing: ChekinanaDownloadChekiError.photoLibrarySaveFailed)
                    return
                }

                continuation.resume(returning: ())
            }
        }
    }

    private static func addOnlyAuthorizationStatus() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        guard status == .notDetermined else {
            return status
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private final class ChekiPhotoAssetCreationState: @unchecked Sendable {
    private let lock = NSLock()
    private var created = false

    var didCreate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return created
    }

    func markCreated() {
        lock.lock()
        created = true
        lock.unlock()
    }
}

private enum ChekiEventFilter {
    case none
    case empty
    case event(Event)
}

enum ChekinanaScannerSize: String, Sendable {
    case auto
    case mini
    case wide
}

enum ChekinanaScannerPostprocessMode: String, Sendable {
    case off
    case denoise
    case sharpen
}

enum ChekinanaScannerDateScope: String, Sendable, CaseIterable {
    case fixed
    case range
    case recent
}

struct ChekinanaScannerDateBounds: Sendable, Equatable {
    let scope: ChekinanaScannerDateScope
    let from: Date
    let to: Date

    var requestsDateAnnotation: Bool { scope != .fixed }
    var fixedDate: Date? { scope == .fixed ? from : nil }

    static func fixed(
        _ date: Date,
        calendar: Calendar = .current
    ) -> Self? {
        guard let normalized = ChekinanaDateOnly.canonicalDate(
            from: date,
            displayedIn: calendar
        ) else { return nil }
        return Self(scope: .fixed, from: normalized, to: normalized)
    }

    static func fixedCanonicalDate(_ date: Date) -> Self? {
        guard let canonical = ChekinanaDateOnly.canonicalized(date) else { return nil }
        return Self(scope: .fixed, from: canonical, to: canonical)
    }

    static func range(
        from: Date,
        to: Date,
        calendar: Calendar = .current
    ) -> Self? {
        guard let normalizedFrom = ChekinanaDateOnly.canonicalDate(
            from: from,
            displayedIn: calendar
        ),
        let normalizedTo = ChekinanaDateOnly.canonicalDate(
            from: to,
            displayedIn: calendar
        ),
        normalizedFrom <= normalizedTo else {
            return nil
        }
        return Self(scope: .range, from: normalizedFrom, to: normalizedTo)
    }

    static func canonicalRange(from: Date, to: Date) -> Self? {
        guard let canonicalFrom = ChekinanaDateOnly.canonicalized(from),
              let canonicalTo = ChekinanaDateOnly.canonicalized(to),
              canonicalFrom <= canonicalTo else { return nil }
        return Self(scope: .range, from: canonicalFrom, to: canonicalTo)
    }

    static func recent(
        relativeTo referenceDate: Date,
        calendar: Calendar = .current
    ) -> Self? {
        guard let lowerDate = calendar.date(
            byAdding: .year,
            value: -1,
            to: referenceDate
        ),
        let bounds = range(from: lowerDate, to: referenceDate, calendar: calendar) else {
            return nil
        }
        return Self(scope: .recent, from: bounds.from, to: bounds.to)
    }

    func contains(_ date: Date) -> Bool {
        guard let canonical = ChekinanaDateOnly.canonicalized(date) else { return false }
        return from <= canonical && canonical <= to
    }

    static func commandDate(_ date: Date) -> String {
        ChekinanaDateOnly.string(date)
    }
}

struct ChekinanaScannerOptions: Sendable {
    let expectedPolaroids: Int?
    let scannerSize: ChekinanaScannerSize
    let postprocessMode: ChekinanaScannerPostprocessMode
    let whiteBalance: Bool
    let sleevesEnabled: Bool
    let directInputEnabled: Bool
    let dateBounds: ChekinanaScannerDateBounds?
    let idolRecognitionCandidates: ChekinanaPatternCandidateSet?

    var dateRecognitionEnabled: Bool { dateBounds != nil }
    var requestsDateAnnotation: Bool { dateBounds?.requestsDateAnnotation == true }
    var usesFixedDate: Bool { dateBounds?.scope == .fixed }
    var directIdolCandidateID: UUID? {
        guard let candidates = idolRecognitionCandidates,
              !candidates.includesUnassigned,
              candidates.idolIDs.count == 1 else { return nil }
        return candidates.idolIDs[0]
    }

    init(
        expectedPolaroids: Int?,
        scannerSize: ChekinanaScannerSize,
        postprocessMode: ChekinanaScannerPostprocessMode,
        whiteBalance: Bool,
        sleevesEnabled: Bool = false,
        directInputEnabled: Bool = false,
        dateRecognitionEnabled: Bool = false,
        dateBounds: ChekinanaScannerDateBounds? = nil,
        idolRecognitionCandidates: ChekinanaPatternCandidateSet? = nil
    ) {
        self.expectedPolaroids = expectedPolaroids
        self.scannerSize = scannerSize
        self.postprocessMode = postprocessMode
        self.whiteBalance = whiteBalance
        self.sleevesEnabled = sleevesEnabled
        self.directInputEnabled = directInputEnabled
        self.dateBounds = dateBounds ?? (
            dateRecognitionEnabled
                ? ChekinanaScannerDateBounds.recent(relativeTo: Date())
                : nil
        )
        self.idolRecognitionCandidates = idolRecognitionCandidates
    }
}

struct ChekinanaScannerResultImage: Sendable {
    let data: Data
    let stagedFileURL: URL?
    let imagePixelWidth: Int?
    let imagePixelHeight: Int?
    let dateAnnotationState: ChekinanaChekiDateAnnotationState
    let sourceAnnotation: ChekinanaScannerSourceAnnotation?
    let inferredChekiSize: ChekiSize?

    init(
        data: Data,
        stagedFileURL: URL? = nil,
        imagePixelWidth: Int? = nil,
        imagePixelHeight: Int? = nil,
        dateAnnotationState: ChekinanaChekiDateAnnotationState = .notRequested,
        sourceAnnotation: ChekinanaScannerSourceAnnotation? = nil,
        inferredChekiSize: ChekiSize? = nil
    ) {
        self.data = data
        self.stagedFileURL = stagedFileURL
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.dateAnnotationState = dateAnnotationState
        self.sourceAnnotation = sourceAnnotation?.isValid == true ? sourceAnnotation : nil
        self.inferredChekiSize = inferredChekiSize
    }
}

struct ChekinanaScannerProcessResult: Sendable {
    let images: [ChekinanaScannerResultImage]
    let warningCount: Int

    init(images: [Data], warningCount: Int) {
        self.images = images.map {
            ChekinanaScannerResultImage(
                data: $0,
                dateAnnotationState: .notRequested
            )
        }
        self.warningCount = warningCount
    }

    init(images: [ChekinanaScannerResultImage], warningCount: Int) {
        self.images = images
        self.warningCount = warningCount
    }
}

private struct ChekinanaScannerResultItem: Decodable, Sendable {
    let id: String
    let type: String
    let label: String?
    let quadrilateral: [ChekinanaScannerQuadrilateralPoint]?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case label
        case quadrilateral
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeSafeNumericResultID(forKey: .id)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        label = try? container.decode(String.self, forKey: .label)
        quadrilateral = try? container.decode(
            [ChekinanaScannerQuadrilateralPointPayload].self,
            forKey: .quadrilateral
        ).map(\.value)
    }
}

private struct ChekinanaScannerQuadrilateralPointPayload: Decodable, Sendable {
    let value: ChekinanaScannerQuadrilateralPoint

    init(from decoder: Decoder) throws {
        if var values = try? decoder.unkeyedContainer() {
            let x = try values.decode(Double.self)
            let y = try values.decode(Double.self)
            guard values.isAtEnd else {
                throw DecodingError.dataCorruptedError(
                    in: values,
                    debugDescription: "Quadrilateral points must contain exactly x and y"
                )
            }
            value = .init(x: x, y: y)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = .init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    private enum CodingKeys: String, CodingKey { case x, y }
}

private struct ChekinanaScannerSourceImagePayload: Decodable, Sendable {
    let width: Int
    let height: Int
}

private struct ChekinanaScannerCoordinateSystemPayload: Decodable, Sendable {
    let space: String
    let origin: String
    let xAxis: String
    let yAxis: String
    let quadOrder: [String]

    var isSupported: Bool {
        space == "exif_transposed_original_pixels"
            && origin == "top_left"
            && xAxis == "right"
            && yAxis == "down"
            && quadOrder == ["top_left", "top_right", "bottom_right", "bottom_left"]
    }

    private enum CodingKeys: String, CodingKey {
        case space
        case origin
        case xAxis = "x_axis"
        case yAxis = "y_axis"
        case quadOrder = "quad_order"
    }
}

private struct ChekinanaScannerUploadResponse: Decodable {
    let taskID: String?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case taskId = "taskId"
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = (try? container.decodeFlexibleString(forKey: .taskID))
            ?? (try? container.decodeFlexibleString(forKey: .taskId))
        status = try? container.decode(String.self, forKey: .status)
    }
}

private struct ChekinanaScannerStatusResponse: Decodable, Sendable {
    let status: String?
    let phase: String?
    let results: [ChekinanaScannerResultItem]
    let resultsCount: Int?
    let expectedPolaroids: Int?
    let extractionComplete: Bool
    let warning: String?
    let error: String?
    let message: String?
    let sourceImage: ChekinanaScannerSourceImagePayload?
    let coordinateSystem: ChekinanaScannerCoordinateSystemPayload?

    private enum CodingKeys: String, CodingKey {
        case status
        case phase
        case results
        case resultsCount = "results_count"
        case expectedPolaroids = "expected_polaroids"
        case extractionComplete = "extraction_complete"
        case warning
        case error
        case message
        case sourceImage = "source_image"
        case coordinateSystem = "coordinate_system"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try? container.decode(String.self, forKey: .status)
        phase = try? container.decode(String.self, forKey: .phase)
        results = (try? container.decode([ChekinanaScannerResultItem].self, forKey: .results)) ?? []
        resultsCount = try? container.decodeFlexibleInt(forKey: .resultsCount)
        expectedPolaroids = try? container.decodeFlexibleInt(forKey: .expectedPolaroids)
        extractionComplete = (try? container.decodeFlexibleBool(
            forKey: .extractionComplete
        )) ?? false
        warning = try? container.decodeFlexibleString(forKey: .warning)
        error = try? container.decode(String.self, forKey: .error)
        message = try? container.decode(String.self, forKey: .message)
        sourceImage = try? container.decode(
            ChekinanaScannerSourceImagePayload.self,
            forKey: .sourceImage
        )
        coordinateSystem = try? container.decode(
            ChekinanaScannerCoordinateSystemPayload.self,
            forKey: .coordinateSystem
        )
    }
}

enum ChekinanaScannerDateAnnotationHeaderParser {
    private static let statusHeader = "X-Cheki-Date-Status"
    private static let textHeader = "X-Cheki-Date-Text"
    private static let precisionHeader = "X-Cheki-Date-Precision"
    private static let boundingBoxHeader = "X-Cheki-Date-Bbox"
    private static let errorHeader = "X-Cheki-Date-Error"

    static func parse(
        response: HTTPURLResponse,
        isEnabled: Bool
    ) -> ChekinanaChekiDateAnnotationState {
        guard isEnabled else {
            return .notRequested
        }

        let status = response.value(forHTTPHeaderField: statusHeader)
        let text = response.value(forHTTPHeaderField: textHeader)
        let precisionText = response.value(forHTTPHeaderField: precisionHeader)
        let boundingBoxText = response.value(forHTTPHeaderField: boundingBoxHeader)
        let error = response.value(forHTTPHeaderField: errorHeader)

        switch status {
        case "detected":
            guard error == nil,
                  let text,
                  let precisionText,
                  let precision = ChekinanaChekiDateAnnotation.Precision(
                    rawValue: precisionText
                  ),
                  let boundingBoxText,
                  let boundingBox = parseBoundingBox(boundingBoxText),
                  let annotation = ChekinanaChekiDateAnnotation(
                    text: text,
                    precision: precision,
                    boundingBox: boundingBox
                  ) else {
                return .unavailable
            }
            return .detected(annotation)
        case "not_detected":
            guard text == nil,
                  precisionText == nil,
                  boundingBoxText == nil,
                  error == nil else {
                return .unavailable
            }
            return .notDetected
        case "unavailable":
            guard text == nil,
                  precisionText == nil,
                  boundingBoxText == nil else {
                return .unavailable
            }
            // The fixed backend error value is intentionally not exposed to
            // UI or persisted data.
            _ = error
            return .unavailable
        default:
            return .unavailable
        }
    }

    private static func parseBoundingBox(
        _ value: String
    ) -> ChekinanaChekiDateBoundingBox? {
        guard value.range(
            of: #"^\d{1,4},\d{1,4},\d{1,4},\d{1,4}$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let x1 = Int(parts[0]),
              let y1 = Int(parts[1]),
              let x2 = Int(parts[2]),
              let y2 = Int(parts[3]) else {
            return nil
        }
        return ChekinanaChekiDateBoundingBox(x1: x1, y1: y1, x2: x2, y2: y2)
    }
}

enum ChekinanaLocalImportChekiError: LocalizedError {
    case invalidImage
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            ChekinanaCommandCopy.text("error.import_image_invalid", fallback: "The imported Cheki image is invalid.")
        case .renderFailed:
            ChekinanaCommandCopy.text("error.import_render_failed", fallback: "The imported Cheki could not be prepared on this device.")
        }
    }
}

struct ChekinanaLocalImportChekiOutput: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let whiteBalanceApplied: Bool
    let inferredSize: ChekiSize?
}

enum ChekinanaImportedChekiSizePolicy {
    /// Geometry comes from the existing scanner contract: Mini 1200×1908
    /// (100:159) and Wide 2400×1908 (200:159). Orientation is deliberately
    /// ignored. Images not exactly proportional to either template stay nil.
    static func inferredSize(width: Int, height: Int) -> ChekiSize? {
        guard width > 0, height > 0 else { return nil }
        let long = max(width, height)
        let short = min(width, height)
        if long.multipliedReportingOverflow(by: 100).overflow == false,
           short.multipliedReportingOverflow(by: 159).overflow == false,
           long * 100 == short * 159 {
            return .mini
        }
        if long.multipliedReportingOverflow(by: 159).overflow == false,
           short.multipliedReportingOverflow(by: 200).overflow == false,
           long * 159 == short * 200 {
            return .wide
        }
        return nil
    }
}

enum ChekinanaImportedChekiCanvasPolicy {
    static let miniShortEdge = 1_200
    static let miniLongEdge = 1_908
    static let wideShortEdge = 1_908
    static let wideLongEdge = 2_400

    static func dimensions(
        inferredSize: ChekiSize?,
        isLandscape: Bool
    ) -> (width: Int, height: Int) {
        let shortEdge: Int
        let longEdge: Int
        switch inferredSize {
        case .wide:
            shortEdge = wideShortEdge
            longEdge = wideLongEdge
        case .mini, .other, nil:
            // Unknown/ambiguous inputs preserve orientation on the existing
            // Mini canvas, but remain nil in the ledger rather than being
            // mislabeled as Mini.
            shortEdge = miniShortEdge
            longEdge = miniLongEdge
        }
        return isLandscape
            ? (longEdge, shortEdge)
            : (shortEdge, longEdge)
    }
}

enum ChekinanaImagePixelGeometry {
    static func uprightDimensions(in data: Data) -> (width: Int, height: Int)? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              ChekinanaImageSourceValidator.accepts(
                source: source,
                maxDimension: ChekinanaImageSourceValidator.maximumThumbnailDimension
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = ChekinanaImageSourceValidator.exifOrientation(source: source) ?? 1
        return (5...8).contains(orientation)
            ? (height, width)
            : (width, height)
    }

    static func aspectRatio(in data: Data) -> CGFloat? {
        guard let dimensions = uprightDimensions(in: data) else { return nil }
        return CGFloat(dimensions.width) / CGFloat(dimensions.height)
    }
}

enum ChekinanaLocalImportRenderGeometry {
    static func fittedRect(
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> CGRect? {
        guard sourceWidth > 0, sourceHeight > 0,
              outputWidth > 0, outputHeight > 0 else { return nil }
        let scale = min(
            CGFloat(outputWidth) / CGFloat(sourceWidth),
            CGFloat(outputHeight) / CGFloat(sourceHeight)
        )
        let width = CGFloat(sourceWidth) * scale
        let height = CGFloat(sourceHeight) * scale
        return CGRect(
            x: (CGFloat(outputWidth) - width) / 2,
            y: (CGFloat(outputHeight) - height) / 2,
            width: width,
            height: height
        )
    }
}

enum ChekinanaLocalImportChekiProcessor {
    static let outputWidth = 1_200
    static let outputHeight = 1_908
    static let wideOutputWidth = 2_400
    static let wideOutputHeight = 1_908
    static let imageAreaX = 82...1_118
    static let imageAreaY = 150...1_533
    static let whiteBalanceBlockSize = 48
    private static let proxyWidth = 300
    private static let proxyHeight = 477
    private static let proxyBlockSize = 12
    private static let sRGBToLinearLUT: [Double] = (0...255).map {
        srgbToLinear(Double($0) / 255.0)
    }
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private static let imageContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: outputColorSpace,
        .cacheIntermediates: false,
    ])

    typealias DateAnnotate = @Sendable (
        ChekinanaPendingChekiImage
    ) async throws -> ChekinanaChekiDateAnnotationState

    static func process(
        _ image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions,
        dateAnnotate: @escaping DateAnnotate = { image in
            try await ChekinanaDirectDateAnnotationClient().annotate(image)
        }
    ) async throws -> ChekinanaScannerProcessResult {
        let output = try await normalize(
            image.data,
            appliesWhiteBalance: options.whiteBalance
        )
        return ChekinanaScannerProcessResult(
            images: [ChekinanaScannerResultImage(
                data: output.data,
                imagePixelWidth: output.width,
                imagePixelHeight: output.height,
                dateAnnotationState: .notRequested,
                inferredChekiSize: output.inferredSize
            )],
            warningCount: 0
        )
    }

    static func normalize(
        _ imageData: Data,
        appliesWhiteBalance: Bool
    ) async throws -> ChekinanaLocalImportChekiOutput {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard !imageData.isEmpty,
                      imageData.count <= 128 * 1_024 * 1_024 else {
                    throw ChekinanaLocalImportChekiError.invalidImage
                }
                let decoded = try downsampledImage(from: imageData)
                let source = decoded.image
                let inferredSize = ChekinanaImportedChekiSizePolicy.inferredSize(
                    width: decoded.uprightWidth,
                    height: decoded.uprightHeight
                )
                let isLandscape = source.width > source.height
                let target = ChekinanaImportedChekiCanvasPolicy.dimensions(
                    inferredSize: inferredSize,
                    isLandscape: isLandscape
                )
                let targetWidth = target.width
                let targetHeight = target.height
                try Task.checkCancellation()
                let gains = appliesWhiteBalance
                    ? fixedBorderWhiteBalanceGains(from: source)
                    : nil
                try Task.checkCancellation()
                guard let outputImage = renderedOutputImage(
                    source,
                    gains: gains,
                    outputWidth: targetWidth,
                    outputHeight: targetHeight
                ) else {
                    throw ChekinanaLocalImportChekiError.renderFailed
                }
                try Task.checkCancellation()
                let outputData = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    outputData,
                    "public.jpeg" as CFString,
                    1,
                    nil
                ) else {
                    throw ChekinanaLocalImportChekiError.renderFailed
                }
                CGImageDestinationAddImage(destination, outputImage, [
                    kCGImageDestinationLossyCompressionQuality: 0.92,
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw ChekinanaLocalImportChekiError.renderFailed
                }
                guard outputData.length > 0,
                      outputData.length <= 32 * 1_024 * 1_024 else {
                    throw ChekinanaLocalImportChekiError.renderFailed
                }
                return ChekinanaLocalImportChekiOutput(
                    data: outputData as Data,
                    width: targetWidth,
                    height: targetHeight,
                    whiteBalanceApplied: gains != nil,
                    inferredSize: inferredSize
                )
            }
        }.value
    }

    private struct DecodedImportSource {
        let image: CGImage
        let uprightWidth: Int
        let uprightHeight: Int
    }

    private static func downsampledImage(from imageData: Data) throws -> DecodedImportSource {
        guard let source = CGImageSourceCreateWithData(
            imageData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        ChekinanaImageSourceValidator.accepts(
            source: source,
            maxDimension: outputHeight
        ), let uprightDimensions = ChekinanaImagePixelGeometry.uprightDimensions(
            in: imageData
        ) else {
            throw ChekinanaLocalImportChekiError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize:
                ChekinanaImportedChekiCanvasPolicy.wideLongEdge,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let decodedImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ),
        decodedImage.width > 0,
        decodedImage.height > 0,
        max(decodedImage.width, decodedImage.height)
            <= ChekinanaImportedChekiCanvasPolicy.wideLongEdge + 1 else {
            throw ChekinanaLocalImportChekiError.invalidImage
        }
        return DecodedImportSource(
            image: decodedImage,
            uprightWidth: uprightDimensions.width,
            uprightHeight: uprightDimensions.height
        )
    }

    private struct WhiteReferenceBlock {
        let mean: SIMD3<Double>
        let variance: Double
    }

    private static func fixedBorderWhiteBalanceGains(
        from source: CGImage
    ) -> SIMD3<Double>? {
        var pixels = [UInt8](repeating: 255, count: proxyWidth * proxyHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: proxyWidth,
            height: proxyHeight,
            bitsPerComponent: 8,
            bytesPerRow: proxyWidth * 4,
            space: outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: proxyWidth, height: proxyHeight))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: proxyWidth, height: proxyHeight))

        let brightThreshold = sRGBToLinearLUT[170]
        let neutralThreshold = 25.0 / 255.0
        let blockPixelCount = proxyBlockSize * proxyBlockSize
        var blocks: [WhiteReferenceBlock] = []

        for y in stride(
            from: 0,
            to: proxyHeight - proxyBlockSize,
            by: proxyBlockSize
        ) {
            for x in stride(
                from: 0,
                to: proxyWidth - proxyBlockSize,
                by: proxyBlockSize
            ) {
                var count = 0
                var sum = SIMD3<Double>(repeating: 0)
                var squareSum = SIMD3<Double>(repeating: 0)
                for blockY in y..<(y + proxyBlockSize) {
                    for blockX in x..<(x + proxyBlockSize) {
                        guard !isInsideProxyImageArea(x: blockX, y: blockY) else { continue }
                        let offset = (blockY * proxyWidth + blockX) * 4
                        let linear = SIMD3<Double>(
                            sRGBToLinearLUT[Int(pixels[offset])],
                            sRGBToLinearLUT[Int(pixels[offset + 1])],
                            sRGBToLinearLUT[Int(pixels[offset + 2])]
                        )
                        guard linear.x > brightThreshold,
                              linear.y > brightThreshold,
                              linear.z > brightThreshold else { continue }
                        let channelMean = (linear.x + linear.y + linear.z) / 3
                        let channelVariance = (
                            (linear.x - channelMean) * (linear.x - channelMean)
                                + (linear.y - channelMean) * (linear.y - channelMean)
                                + (linear.z - channelMean) * (linear.z - channelMean)
                        ) / 3
                        guard channelVariance < neutralThreshold * neutralThreshold else { continue }
                        count += 1
                        sum += linear
                        squareSum += linear * linear
                    }
                }
                guard Double(count) / Double(blockPixelCount) > 0.8 else { continue }
                let divisor = Double(count)
                let mean = sum / divisor
                let channelVariances = squareSum / divisor - mean * mean
                blocks.append(WhiteReferenceBlock(
                    mean: mean,
                    variance: max(
                        0,
                        (channelVariances.x + channelVariances.y + channelVariances.z) / 3
                    )
                ))
            }
        }

        guard !blocks.isEmpty else { return nil }
        let best = blocks.sorted { $0.variance < $1.variance }.prefix(10)
        let reference = best.reduce(SIMD3<Double>(repeating: 0)) {
            $0 + $1.mean
        } / Double(best.count)
        let target = srgbToLinear(240.0 / 255.0)
        return SIMD3<Double>(
            target / max(reference.x, 0.000_001),
            target / max(reference.y, 0.000_001),
            target / max(reference.z, 0.000_001)
        )
    }

    private static func renderedOutputImage(
        _ source: CGImage,
        gains: SIMD3<Double>?,
        outputWidth: Int,
        outputHeight: Int
    ) -> CGImage? {
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        guard let fitted = ChekinanaLocalImportRenderGeometry.fittedRect(
            sourceWidth: source.width,
            sourceHeight: source.height,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        ) else { return nil }
        let scale = fitted.width / CGFloat(source.width)
        let transform = CGAffineTransform(
            translationX: fitted.minX,
            y: fitted.minY
        ).scaledBy(x: scale, y: scale)
        let white = CIImage(color: CIColor.white).cropped(to: outputRect)
        var image = CIImage(cgImage: source)
            .transformed(by: transform)
            .cropped(to: outputRect)
            .composited(over: white)
        if let gains {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gains.x, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gains.y, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gains.z, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        return imageContext.createCGImage(
            image,
            from: outputRect,
            format: .RGBA8,
            colorSpace: outputColorSpace
        )
    }

    private static func isInsideProxyImageArea(x: Int, y: Int) -> Bool {
        let outputX = x * outputWidth / proxyWidth
        let outputY = y * outputHeight / proxyHeight
        return imageAreaX.contains(outputX) && imageAreaY.contains(outputY)
    }

    private static func srgbToLinear(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped <= 0.04045
            ? clamped / 12.92
            : pow((clamped + 0.055) / 1.055, 2.4)
    }

}

enum ChekinanaScanCleanImageRotation {
    static func counterclockwise(
        _ image: ChekinanaPendingChekiImage
    ) async throws -> ChekinanaPendingChekiImage {
        let task = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Task.checkCancellation()
                guard !image.data.isEmpty,
                      image.data.count <= 64 * 1_024 * 1_024,
                      let source = CGImageSourceCreateWithData(
                        image.data as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary
                      ),
                      ChekinanaImageSourceValidator.accepts(
                        source: source,
                        maxDimension: ChekinanaImageSourceValidator.maximumThumbnailDimension
                      ),
                      let decoded = CGImageSourceCreateImageAtIndex(
                        source,
                        0,
                        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                      ),
                      let upright = ChekinanaImageWorker.normalizedThumbnailOrientation(
                        decoded,
                        exifOrientation: ChekinanaImageSourceValidator.exifOrientation(
                            source: source
                        ) ?? 1,
                        maxDimension: max(decoded.width, decoded.height)
                      ),
                      let rotated = ChekinanaImageWorker.normalizedThumbnailOrientation(
                        upright,
                        exifOrientation: 8,
                        maxDimension: max(upright.width, upright.height)
                      ) else {
                    throw ChekinanaScanChekiError.invalidResultImage
                }
                try Task.checkCancellation()
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output,
                    "public.jpeg" as CFString,
                    1,
                    nil
                ) else { throw ChekinanaScanChekiError.invalidResultImage }
                CGImageDestinationAddImage(
                    destination,
                    rotated,
                    [
                        kCGImageDestinationLossyCompressionQuality: 0.94,
                        // Pixels are already upright and counterclockwise-
                        // rotated. Never carry the source EXIF transform into
                        // the new JPEG or downstream ImageIO will rotate twice.
                        kCGImagePropertyOrientation: 1,
                    ] as CFDictionary
                )
                guard CGImageDestinationFinalize(destination) else {
                    throw ChekinanaScanChekiError.invalidResultImage
                }
                try Task.checkCancellation()
                return ChekinanaPendingChekiImage(
                    data: output as Data,
                    filenameExtension: "jpg",
                    sourceID: image.sourceID,
                    sourceOrigin: image.sourceOrigin
                )
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func counterclockwiseDateAnnotation(
        _ state: ChekinanaChekiDateAnnotationState
    ) -> ChekinanaChekiDateAnnotationState {
        guard case .detected(let annotation) = state else { return state }
        let box = annotation.boundingBox
        guard let rotatedBox = ChekinanaChekiDateBoundingBox(
            x1: box.y1,
            y1: 1_000 - box.x2,
            x2: box.y2,
            y2: 1_000 - box.x1
        ), let rotated = ChekinanaChekiDateAnnotation(
            text: annotation.text,
            precision: annotation.precision,
            boundingBox: rotatedBox
        ) else { return .unavailable }
        return .detected(rotated)
    }
}

struct ChekinanaDirectDateAnnotationClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = ChekinanaScannerConfiguration.productionBaseURL,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.session = session ?? Self.productionSession()
    }

    func annotate(
        _ image: ChekinanaPendingChekiImage
    ) async throws -> ChekinanaChekiDateAnnotationState {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("cheki")
            .appendingPathComponent("date-annotation")
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 110
        )
        request.httpMethod = "POST"
        let contentType = ["jpg", "jpeg"].contains(image.filenameExtension.lowercased())
            ? "image/jpeg"
            : "image/png"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = image.data
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              data.count <= 64 * 1_024 else {
            throw ChekinanaScanChekiError.invalidHTTPResponse
        }
        return Self.decode(data)
    }

    static func decode(_ data: Data) -> ChekinanaChekiDateAnnotationState {
        guard let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data) else {
            return .unavailable
        }
        let value = envelope.annotation ?? envelope.payload
        switch value.status.lowercased() {
        case "detected":
            guard let text = value.text,
                  let precisionText = value.precision,
                  let precision = ChekinanaChekiDateAnnotation.Precision(
                    rawValue: precisionText
                  ),
                  let box = value.bbox?.normalized,
                  let annotation = ChekinanaChekiDateAnnotation(
                    text: text,
                    precision: precision,
                    boundingBox: box
                  ) else {
                return .unavailable
            }
            return .detected(annotation)
        case "not_detected":
            return .notDetected
        case "unavailable":
            return .unavailable
        default:
            return .unavailable
        }
    }

    private static func productionSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary =
            ChekinanaCatalogueNetworkPolicy.directConnectionProxyDictionary()
        return URLSession(configuration: configuration)
    }

    private struct ResponseEnvelope: Decodable {
        let payload: Payload
        let annotation: Payload?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            annotation = try? container.decode(Payload.self, forKey: .annotation)
            payload = try Payload(from: decoder)
        }

        private enum CodingKeys: String, CodingKey {
            case annotation
        }
    }

    private struct Payload: Decodable {
        let status: String
        let text: String?
        let precision: String?
        let bbox: FlexibleBoundingBox?

        private enum CodingKeys: String, CodingKey {
            case status
            case text
            case precision
            case bbox
            case boundingBox = "bounding_box"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = (try? container.decode(String.self, forKey: .status)) ?? "unavailable"
            text = try? container.decode(String.self, forKey: .text)
            precision = try? container.decode(String.self, forKey: .precision)
            bbox = (try? container.decode(FlexibleBoundingBox.self, forKey: .bbox))
                ?? (try? container.decode(FlexibleBoundingBox.self, forKey: .boundingBox))
        }
    }

    private struct FlexibleBoundingBox: Decodable {
        let values: [Int]

        var normalized: ChekinanaChekiDateBoundingBox? {
            guard values.count == 4 else { return nil }
            return ChekinanaChekiDateBoundingBox(
                x1: values[0],
                y1: values[1],
                x2: values[2],
                y2: values[3]
            )
        }

        init(from decoder: Decoder) throws {
            if var array = try? decoder.unkeyedContainer() {
                var result: [Int] = []
                while !array.isAtEnd { result.append(try array.decode(Int.self)) }
                values = result
                return
            }
            if let keyed = try? decoder.container(keyedBy: Keys.self) {
                values = [
                    try keyed.decode(Int.self, forKey: .x1),
                    try keyed.decode(Int.self, forKey: .y1),
                    try keyed.decode(Int.self, forKey: .x2),
                    try keyed.decode(Int.self, forKey: .y2),
                ]
                return
            }
            let single = try decoder.singleValueContainer()
            let string = try single.decode(String.self)
            values = string.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
        }

        private enum Keys: String, CodingKey {
            case x1, y1, x2, y2
        }
    }
}

enum ChekinanaScannerRuntimeState: String, Decodable, Sendable {
    case closed
    case preparing
    case ready
}

struct ChekinanaScannerRuntimeStatus: Decodable, Equatable, Sendable {
    struct Progress: Decodable, Equatable, Sendable {
        let current: Int
        let total: Int
    }

    let ok: Bool
    let state: ChekinanaScannerRuntimeState
    let phase: String
    let message: String?
    let error: String?
    let retryAllowed: Bool
    let canStart: Bool
    let canTerminate: Bool
    let updatedAt: String?
    let progress: Progress?

    private enum CodingKeys: String, CodingKey {
        case ok, state, phase, message, error, retryAllowed, canStart, canTerminate, updatedAt
        case progress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(ChekinanaScannerRuntimeState.self, forKey: .state)
        self.ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        self.state = state
        self.phase = try container.decodeIfPresent(String.self, forKey: .phase)
            ?? state.rawValue
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.retryAllowed = try container.decodeIfPresent(Bool.self, forKey: .retryAllowed)
            ?? (state == .closed)
        self.canStart = try container.decodeIfPresent(Bool.self, forKey: .canStart)
            ?? false
        self.canTerminate = try container.decodeIfPresent(Bool.self, forKey: .canTerminate)
            ?? false
        self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        let decodedProgress: Progress?
        do {
            decodedProgress = try container.decodeIfPresent(Progress.self, forKey: .progress)
        } catch {
            // Progress is optional and was added after the original runtime
            // contract. A malformed optional object must not hide the
            // authoritative runtime state from older/newer Workers.
            decodedProgress = nil
        }
        self.progress = Self.validatedProgress(decodedProgress, state: state)
    }

    init(
        ok: Bool = true,
        state: ChekinanaScannerRuntimeState,
        phase: String,
        message: String? = nil,
        error: String? = nil,
        retryAllowed: Bool,
        canStart: Bool? = nil,
        canTerminate: Bool? = nil,
        updatedAt: String? = nil,
        progress: Progress? = nil
    ) {
        self.ok = ok
        self.state = state
        self.phase = phase
        self.message = message
        self.error = error
        self.retryAllowed = retryAllowed
        self.canStart = canStart ?? (state == .closed)
        self.canTerminate = canTerminate ?? (state == .ready)
        self.updatedAt = updatedAt
        self.progress = Self.validatedProgress(progress, state: state)
    }

    private static func validatedProgress(
        _ progress: Progress?,
        state: ChekinanaScannerRuntimeState
    ) -> Progress? {
        guard state == .preparing,
              let progress,
              progress.total == 3,
              (1...progress.total).contains(progress.current) else { return nil }
        return progress
    }

    static let localDebugReady = Self(
        state: .ready,
        phase: "ready",
        retryAllowed: false,
        canStart: false,
        canTerminate: true
    )

    static func clientUnavailable(message: String) -> Self {
        Self(
            ok: false,
            state: .closed,
            phase: "closed",
            message: message,
            retryAllowed: true,
            canStart: false,
            canTerminate: false
        )
    }
}

enum ChekinanaScannerRuntimeError: LocalizedError, Equatable {
    case invalidBaseURLConfiguration
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidResponse
    case failed(String?)
    case timedOut
    case clientUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURLConfiguration:
            ChekinanaCommandCopy.text("error.runtime_proxy", fallback: "Scanner proxy configuration is invalid.")
        case .invalidHTTPResponse:
            ChekinanaCommandCopy.text("error.runtime_http_response", fallback: "Backend status returned an invalid response.")
        case .httpStatus(let statusCode):
            ChekinanaCommandCopy.format("error.runtime_http_status", fallback: "Backend status request failed with HTTP %lld.", Int64(statusCode))
        case .invalidResponse:
            ChekinanaCommandCopy.text("error.runtime_response", fallback: "Backend status response is invalid.")
        case .failed(let message):
            message ?? ChekinanaCommandCopy.text("error.runtime_start", fallback: "Backend failed to start. Please try again later.")
        case .timedOut:
            ChekinanaCommandCopy.text("error.runtime_timeout", fallback: "Backend request timed out. You can retry immediately.")
        case .clientUnavailable(let message):
            message
        }
    }
}

enum ChekinanaTemporaryGPUManagementPolicy {
    // Temporary product gate. Keep every iOS GPU runtime call site behind this
    // single switch so restoring remote management is deliberate and auditable.
    static let runtimeRequestsEnabled = true
    static let pausedMessage = "GPU management is temporarily paused. Import Cheki remains available."

    static func preflight(
        hasGPUInput: Bool,
        hasDirectInput: Bool
    ) -> ChekinanaScanGPUPreflightDecision {
        if hasGPUInput && hasDirectInput { return .blockMixed }
        if hasGPUInput { return .blockGPUOnly }
        return .allowDirectOnly
    }
}

protocol ChekinanaScannerRuntimeStartSocket: Sendable {
    func receive() async throws -> Data
    func cancel()
}

private final class ChekinanaURLSessionRuntimeStartSocket:
    ChekinanaScannerRuntimeStartSocket,
    @unchecked Sendable
{
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            throw ChekinanaScannerRuntimeError.invalidResponse
        }
    }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

struct ChekinanaScannerRuntimeClient: Sendable {
    static let statusRequestTimeout: TimeInterval = 7
    static let stopRequestTimeout: TimeInterval = 25

    typealias StartSocketFactory = @Sendable (URLRequest) async throws
        -> any ChekinanaScannerRuntimeStartSocket
    typealias StartStatusHandler = @Sendable (
        ChekinanaScannerRuntimeStatus
    ) async -> Void

    private let baseURLResolution: ChekinanaScannerBaseURLResolution
    private let session: URLSession
    private let usesProductionProxy: Bool
    private let statusWallClockTimeout: TimeInterval
    private let startSocketFactory: StartSocketFactory
#if DEBUG
    private let debugStubMode: String?
#endif

    init(session: URLSession? = nil) {
        let resolution = ChekinanaScannerConfiguration.configuredBaseURL()
        baseURLResolution = resolution
        let resolvedSession = session ?? Self.productionSession()
        self.session = resolvedSession
        usesProductionProxy = ChekinanaScannerConfiguration.isProductionProxy(resolution)
        statusWallClockTimeout = Self.statusRequestTimeout
        startSocketFactory = Self.makeStartSocketFactory(session: resolvedSession)
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        debugStubMode = environment["CHEKINANA_SCANNER_RUNTIME_UI_STUB"]
            ?? (environment["CHEKINANA_UI_TEST_STORE"] == "1" ? "ready" : nil)
#endif
    }

    init(
        baseURL: URL,
        session: URLSession = .shared,
        statusWallClockTimeout: TimeInterval = Self.statusRequestTimeout,
        startSocketFactory: StartSocketFactory? = nil
    ) {
        precondition(statusWallClockTimeout > 0)
        baseURLResolution = .resolved(baseURL)
        self.session = session
        usesProductionProxy = ChekinanaScannerConfiguration.isProductionProxy(baseURL)
        self.statusWallClockTimeout = statusWallClockTimeout
        self.startSocketFactory = startSocketFactory
            ?? Self.makeStartSocketFactory(session: session)
#if DEBUG
        debugStubMode = nil
#endif
    }

    var isManagedProductionRuntime: Bool { usesProductionProxy }

    private static func productionSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary =
            ChekinanaCatalogueNetworkPolicy.directConnectionProxyDictionary()
        return URLSession(configuration: configuration)
    }

    private static func makeStartSocketFactory(
        session: URLSession
    ) -> StartSocketFactory {
        { request in
            let task = session.webSocketTask(with: request)
            task.resume()
            return ChekinanaURLSessionRuntimeStartSocket(task: task)
        }
    }

    func status() async throws -> ChekinanaScannerRuntimeStatus {
        guard usesProductionProxy else { return .localDebugReady }
        return try await Self.withWallClockDeadline(
            seconds: statusWallClockTimeout
        ) {
#if DEBUG
            if let debugStubMode {
                return await ChekinanaScannerRuntimeUIStub.shared.status(mode: debugStubMode)
            }
#endif
            return try await request(
                method: "GET",
                path: "runtime",
                timeoutInterval: Self.statusRequestTimeout
            )
        }
    }

    func start(
        onStatus: @escaping StartStatusHandler = { _ in }
    ) async throws -> ChekinanaScannerRuntimeStatus {
        guard usesProductionProxy else { return .localDebugReady }
#if DEBUG
        if let debugStubMode {
            return await ChekinanaScannerRuntimeUIStub.shared.start(mode: debugStubMode)
        }
#endif
        let request = try runtimeRequest(
            method: "GET",
            path: "runtime/start",
            timeoutInterval: 16 * 60,
            usesWebSocketScheme: true
        )
        let socket = try await startSocketFactory(request)
        return try await withTaskCancellationHandler {
            do {
                while true {
                    let data = try await socket.receive()
                    guard let status = try? JSONDecoder().decode(
                        ChekinanaScannerRuntimeStatus.self,
                        from: data
                    ) else {
                        throw ChekinanaScannerRuntimeError.invalidResponse
                    }
                    await onStatus(status)
                    // The Worker first sends its read-only snapshot, which can
                    // legitimately still be `closed`. It closes only after a
                    // `ready` result or an explicit fixed failure (`ok=false`).
                    if status.state == .ready || !status.ok {
                        socket.cancel()
                        return status
                    }
                }
            } catch {
                socket.cancel()
                if Task.isCancelled { throw CancellationError() }
                if let runtimeError = error as? ChekinanaScannerRuntimeError {
                    throw runtimeError
                }
                if let urlError = error as? URLError, urlError.code == .timedOut {
                    throw ChekinanaScannerRuntimeError.timedOut
                }
                throw ChekinanaScannerRuntimeError.clientUnavailable(
                    "Backend startup connection was interrupted. You can retry immediately."
                )
            }
        } onCancel: {
            socket.cancel()
        }
    }

    func stop() async throws -> ChekinanaScannerRuntimeStatus {
        guard usesProductionProxy else {
            return .init(state: .closed, phase: "closed", retryAllowed: true)
        }
#if DEBUG
        if let debugStubMode {
            return await ChekinanaScannerRuntimeUIStub.shared.stop(mode: debugStubMode)
        }
#endif
        return try await request(
            method: "POST",
            path: "runtime/stop",
            timeoutInterval: Self.stopRequestTimeout
        )
    }

    private func request(
        method: String,
        path: String,
        timeoutInterval: TimeInterval
    ) async throws -> ChekinanaScannerRuntimeStatus {
        let request = try runtimeRequest(
            method: method,
            path: path,
            timeoutInterval: timeoutInterval
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw ChekinanaScannerRuntimeError.timedOut
            }
            throw ChekinanaScannerRuntimeError.clientUnavailable(
                "Backend is unavailable from this device. You can retry immediately."
            )
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChekinanaScannerRuntimeError.invalidHTTPResponse
        }
        if let status = try? JSONDecoder().decode(
            ChekinanaScannerRuntimeStatus.self,
            from: data
        ) {
            // Runtime state is authoritative even for non-2xx control
            // responses such as stop=409 while a scan is still active.
            return status
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ChekinanaScannerRuntimeError.httpStatus(httpResponse.statusCode)
        }
        throw ChekinanaScannerRuntimeError.invalidResponse
    }

    private func runtimeRequest(
        method: String,
        path: String,
        timeoutInterval: TimeInterval,
        usesWebSocketScheme: Bool = false
    ) throws -> URLRequest {
        guard case .resolved(let baseURL) = baseURLResolution else {
            throw ChekinanaScannerRuntimeError.invalidBaseURLConfiguration
        }
        let httpURL = path.split(separator: "/").reduce(
            baseURL.appendingPathComponent("api").appendingPathComponent("scanner")
        ) { partial, component in
            partial.appendingPathComponent(String(component))
        }
        let url: URL
        if usesWebSocketScheme {
            guard var components = URLComponents(
                url: httpURL,
                resolvingAgainstBaseURL: false
            ) else {
                throw ChekinanaScannerRuntimeError.invalidBaseURLConfiguration
            }
            switch components.scheme?.lowercased() {
            case "https": components.scheme = "wss"
            case "http": components.scheme = "ws"
            default:
                throw ChekinanaScannerRuntimeError.invalidBaseURLConfiguration
            }
            guard let webSocketURL = components.url else {
                throw ChekinanaScannerRuntimeError.invalidBaseURLConfiguration
            }
            url = webSocketURL
        } else {
            url = httpURL
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeoutInterval
        )
        request.httpMethod = method
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private static func withWallClockDeadline<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
        let stream = AsyncThrowingStream<Value, Error> { continuation in
            let operationTask = Task {
                do {
                    continuation.yield(try await operation())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let deadlineTask = Task {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    continuation.finish(
                        throwing: ChekinanaScannerRuntimeError.timedOut
                    )
                } catch {
                    // Stream termination cancels the losing deadline task.
                }
            }
            continuation.onTermination = { @Sendable _ in
                operationTask.cancel()
                deadlineTask.cancel()
            }
        }
        var iterator = stream.makeAsyncIterator()
        if let value = try await iterator.next() {
            return value
        }
        if Task.isCancelled { throw CancellationError() }
        throw ChekinanaScannerRuntimeError.timedOut
    }
}

#if DEBUG
private actor ChekinanaScannerRuntimeUIStub {
    static let shared = ChekinanaScannerRuntimeUIStub()
    private var startCount = 0

    func status(mode: String) async -> ChekinanaScannerRuntimeStatus {
        if mode == "hang" {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return failedStatus()
        }
        switch mode {
        case "closed":
            return failedStatus()
        case "offline-ready":
            return startCount == 0
                ? .init(state: .closed, phase: "closed", retryAllowed: true)
                : .init(state: .ready, phase: "ui_test_ready", retryAllowed: false)
        default:
            return .init(state: .ready, phase: "ui_test_ready", retryAllowed: false)
        }
    }

    func start(mode: String) -> ChekinanaScannerRuntimeStatus {
        startCount += 1
        switch mode {
        case "closed":
            return failedStatus()
        case "offline-ready":
            return .init(state: .preparing, phase: "preparing", retryAllowed: false)
        default:
            return .init(state: .ready, phase: "ui_test_ready", retryAllowed: false)
        }
    }

    func stop(mode: String) -> ChekinanaScannerRuntimeStatus {
        startCount = 0
        return .init(state: .closed, phase: "closed", retryAllowed: true)
    }

    private func failedStatus() -> ChekinanaScannerRuntimeStatus {
        .init(
            state: .closed,
            phase: "closed",
            message: "No GPU is currently available. Please try again later.",
            retryAllowed: true,
            updatedAt: "2026-08-04T12:00:00Z"
        )
    }
}
#endif

struct ChekinanaPreparedScannerUpload: Sendable {
    let image: ChekinanaPendingChekiImage
    let annotationPreviewImageData: Data
    let annotationPreviewPixelWidth: Int
    let annotationPreviewPixelHeight: Int
}

private enum ChekinanaScannerSourceAnnotationBuilder {
    static func make(
        preview: ChekinanaPreparedScannerUpload,
        sourceImage: ChekinanaScannerSourceImagePayload?,
        coordinateSystem: ChekinanaScannerCoordinateSystemPayload?,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint]?
    ) async -> ChekinanaScannerSourceAnnotation? {
        await Task.detached(priority: .utility) {
            makeSynchronously(
                preview: preview,
                sourceImage: sourceImage,
                coordinateSystem: coordinateSystem,
                quadrilateral: quadrilateral
            )
        }.value
    }

    private static func makeSynchronously(
        preview: ChekinanaPreparedScannerUpload,
        sourceImage: ChekinanaScannerSourceImagePayload?,
        coordinateSystem: ChekinanaScannerCoordinateSystemPayload?,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint]?
    ) -> ChekinanaScannerSourceAnnotation? {
        guard let sourceImage,
              let coordinateSystem,
              coordinateSystem.isSupported,
              (1...ChekinanaImageSourceValidator.maximumSourceDimension).contains(sourceImage.width),
              (1...ChekinanaImageSourceValidator.maximumSourceDimension).contains(sourceImage.height),
              Double(sourceImage.width) * Double(sourceImage.height)
                <= ChekinanaImageSourceValidator.maximumSourcePixelCount,
              let quadrilateral,
              quadrilateral.count == 4 else { return nil }
        let sourceAspect = Double(sourceImage.width) / Double(sourceImage.height)
        let previewAspect = Double(preview.annotationPreviewPixelWidth)
            / Double(preview.annotationPreviewPixelHeight)
        guard sourceAspect.isFinite,
              previewAspect.isFinite,
              abs(sourceAspect - previewAspect) / max(sourceAspect, 0.000_001) <= 0.02 else {
            return nil
        }
        guard let renderedPreview = ChekinanaScannerAnnotationPreviewRenderer.render(
            sourcePreviewData: preview.annotationPreviewImageData,
            sourcePixelWidth: sourceImage.width,
            sourcePixelHeight: sourceImage.height,
            quadrilateral: quadrilateral
        ) else { return nil }
        let annotation = ChekinanaScannerSourceAnnotation(
            previewImageData: renderedPreview,
            sourcePixelWidth: sourceImage.width,
            sourcePixelHeight: sourceImage.height,
            quadrilateral: quadrilateral
        )
        return annotation.isValid ? annotation : nil
    }
}

enum ChekinanaLiveScannerUploadPreparer {
    static let maximumInputBytes = 128 * 1_024 * 1_024
    static let maximumUploadBytes = 30 * 1_024 * 1_024
    static let maximumNormalizedDimension = 8_192
    static let maximumAnnotationPreviewDimension = 1_200

    static func fileFitsBackendLimit(_ byteCount: Int) -> Bool {
        (1...maximumUploadBytes).contains(byteCount)
    }

    static func prepare(
        _ image: ChekinanaPendingChekiImage
    ) async throws -> ChekinanaPreparedScannerUpload {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool { try prepareSynchronously(image) }
        }.value
    }

    private static func prepareSynchronously(
        _ image: ChekinanaPendingChekiImage
    ) throws -> ChekinanaPreparedScannerUpload {
        guard !image.data.isEmpty,
              image.data.count <= maximumInputBytes,
              let originalSource = makeSource(image.data),
              ChekinanaImageSourceValidator.accepts(
                source: originalSource,
                maxDimension: maximumNormalizedDimension
              ) else {
            throw ChekinanaScanChekiError.invalidUploadImage
        }

        let uploadImage: ChekinanaPendingChekiImage
        if let sourceType = CGImageSourceGetType(originalSource) as String?,
           let supportedExtension = backendExtension(for: sourceType),
           fileFitsBackendLimit(image.data.count) {
            uploadImage = ChekinanaPendingChekiImage(
                data: image.data,
                filenameExtension: supportedExtension,
                sourceID: image.sourceID,
                sourceOrigin: image.sourceOrigin
            )
        } else {
            let normalized = try normalizedJPEG(from: originalSource)
            uploadImage = ChekinanaPendingChekiImage(
                data: normalized,
                filenameExtension: "jpg",
                sourceID: image.sourceID,
                sourceOrigin: image.sourceOrigin
            )
        }

        guard let uploadSource = makeSource(uploadImage.data),
              let previewImage = thumbnail(
                source: uploadSource,
                maximumDimension: maximumAnnotationPreviewDimension
              ),
              let previewData = encoded(previewImage, type: "public.png", quality: nil),
              !previewData.isEmpty,
              previewData.count <= 8 * 1_024 * 1_024 else {
            throw ChekinanaScanChekiError.invalidUploadImage
        }
        return ChekinanaPreparedScannerUpload(
            image: uploadImage,
            annotationPreviewImageData: previewData,
            annotationPreviewPixelWidth: previewImage.width,
            annotationPreviewPixelHeight: previewImage.height
        )
    }

    private static func normalizedJPEG(from source: CGImageSource) throws -> Data {
        let dimensions = [8_192, 6_144, 4_096]
        let qualities: [Double] = [0.90, 0.82, 0.72]
        for maximumDimension in dimensions {
            guard let image = thumbnail(source: source, maximumDimension: maximumDimension) else {
                continue
            }
            for quality in qualities {
                if let data = encoded(image, type: "public.jpeg", quality: quality),
                   fileFitsBackendLimit(data.count) {
                    return data
                }
            }
        }
        throw ChekinanaScanChekiError.uploadTooLarge
    }

    private static func makeSource(_ data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        )
    }

    private static func thumbnail(
        source: CGImageSource,
        maximumDimension: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ), image.width > 0, image.height > 0,
           max(image.width, image.height) <= maximumDimension + 1 else {
            return nil
        }
        return image
    }

    private static func encoded(
        _ image: CGImage,
        type: String,
        quality: Double?
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type as CFString,
            1,
            nil
        ) else { return nil }
        let properties = quality.map {
            [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func backendExtension(for sourceType: String) -> String? {
        switch sourceType.lowercased() {
        case "public.jpeg": "jpg"
        case "public.png": "png"
        case "com.microsoft.bmp": "bmp"
        case "public.tiff": "tiff"
        case "org.webmproject.webp", "public.webp": "webp"
        default: nil
        }
    }
}

struct ChekinanaScannerClient {
    static let productionBaseURL = ChekinanaScannerConfiguration.productionBaseURL
    static let defaultStatusPollIntervalNanoseconds: UInt64 = 250_000_000
    static let defaultMaximumStatusPollAttempts = 480

    private let baseURLResolution: ChekinanaScannerBaseURLResolution
    private let session: URLSession
    private let runtimeClient: ChekinanaScannerRuntimeClient
    private let decoder = JSONDecoder()
    private let statusPollIntervalNanoseconds: UInt64
    private let maximumStatusPollAttempts: Int

    private struct PollResult: Sendable {
        let images: [ChekinanaScannerResultImage]
        let warningCount: Int
        let hasIncompleteResultWarning: Bool
    }

    private struct CapturedFailure: LocalizedError, Sendable {
        let message: String

        init(_ error: Error) {
            message = error.localizedDescription
        }

        var errorDescription: String? { message }
    }

    private enum ProcessEvent: Sendable {
        case status(ChekinanaScannerStatusResponse)
        case statusFailed(CapturedFailure)
        case downloaded(index: Int, image: ChekinanaScannerResultImage)
        case downloadFailed(index: Int, failure: CapturedFailure)
    }

    init(
        session: URLSession? = nil,
        statusPollIntervalNanoseconds: UInt64 = Self.defaultStatusPollIntervalNanoseconds,
        maximumStatusPollAttempts: Int = Self.defaultMaximumStatusPollAttempts
    ) {
        precondition(maximumStatusPollAttempts > 0)
        let resolution = ChekinanaScannerConfiguration.configuredBaseURL()
        baseURLResolution = resolution
        let productionSession = session ?? Self.productionSession()
        self.session = productionSession
        runtimeClient = ChekinanaScannerRuntimeClient(session: productionSession)
        self.statusPollIntervalNanoseconds = statusPollIntervalNanoseconds
        self.maximumStatusPollAttempts = maximumStatusPollAttempts
    }

    private static func productionSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary =
            ChekinanaCatalogueNetworkPolicy.directConnectionProxyDictionary()
        return URLSession(configuration: configuration)
    }

    init(
        baseURL: URL,
        session: URLSession = .shared,
        statusPollIntervalNanoseconds: UInt64 = Self.defaultStatusPollIntervalNanoseconds,
        maximumStatusPollAttempts: Int = Self.defaultMaximumStatusPollAttempts
    ) {
        precondition(maximumStatusPollAttempts > 0)
        baseURLResolution = .resolved(baseURL)
        self.session = session
        runtimeClient = ChekinanaScannerRuntimeClient(baseURL: baseURL, session: session)
        self.statusPollIntervalNanoseconds = statusPollIntervalNanoseconds
        self.maximumStatusPollAttempts = maximumStatusPollAttempts
    }

    init(
        infoDictionary: [String: Any]?,
        allowsInsecureLocalHTTP: Bool,
        session: URLSession = .shared,
        statusPollIntervalNanoseconds: UInt64 = Self.defaultStatusPollIntervalNanoseconds,
        maximumStatusPollAttempts: Int = Self.defaultMaximumStatusPollAttempts
    ) {
        precondition(maximumStatusPollAttempts > 0)
        let resolution = ChekinanaScannerConfiguration.configuredBaseURL(
            infoDictionary: infoDictionary,
            allowsInsecureLocalHTTP: allowsInsecureLocalHTTP
        )
        baseURLResolution = resolution
        self.session = session
        let runtimeBaseURL: URL
        if case .resolved(let url) = resolution {
            runtimeBaseURL = url
        } else {
            runtimeBaseURL = ChekinanaScannerConfiguration.productionBaseURL
        }
        runtimeClient = ChekinanaScannerRuntimeClient(
            baseURL: runtimeBaseURL,
            session: session
        )
        self.statusPollIntervalNanoseconds = statusPollIntervalNanoseconds
        self.maximumStatusPollAttempts = maximumStatusPollAttempts
    }

    func process(
        _ image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions,
        progressObserver: ChekinanaCommandExecutor.ScannerStatusObserver? = nil,
        resultObserver: ChekinanaCommandExecutor.ScannerResultObserver? = nil,
        taskIDObserver: ChekinanaCommandExecutor.ScannerTaskObserver? = nil
    ) async throws -> ChekinanaScannerProcessResult {
        _ = try baseURL()
        if runtimeClient.isManagedProductionRuntime {
            guard ChekinanaTemporaryGPUManagementPolicy.runtimeRequestsEnabled else {
                throw ChekinanaScannerRuntimeError.failed(
                    ChekinanaTemporaryGPUManagementPolicy.pausedMessage
                )
            }
        }
        let preparedUpload = try await ChekinanaLiveScannerUploadPreparer.prepare(image)
        let taskID = try await upload(preparedUpload.image, options: options)
        try Task.checkCancellation()
        await taskIDObserver?(taskID, true)
        let pollResult: PollResult
        do {
            pollResult = try await pollAndDownloadResults(
                taskID: taskID,
                options: options,
                preparedUpload: preparedUpload,
                progressObserver: progressObserver,
                resultObserver: resultObserver
            )
            await taskIDObserver?(taskID, false)
        } catch {
            await taskIDObserver?(taskID, false)
            throw error
        }

        var warningCount = pollResult.warningCount
        if let expected = options.expectedPolaroids,
           expected != pollResult.images.count,
           !pollResult.hasIncompleteResultWarning {
            warningCount += 1
        }

        return ChekinanaScannerProcessResult(
            images: pollResult.images,
            warningCount: warningCount
        )
    }

    func cancel(taskID: String) async throws {
        let baseURL = try baseURL()
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("cancel")
            .appendingPathComponent(taskID)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
    }

    private func pollAndDownloadResults(
        taskID: String,
        options: ChekinanaScannerOptions,
        preparedUpload: ChekinanaPreparedScannerUpload,
        progressObserver: ChekinanaCommandExecutor.ScannerStatusObserver?,
        resultObserver: ChekinanaCommandExecutor.ScannerResultObserver?
    ) async throws -> PollResult {
        return try await withThrowingTaskGroup(
            of: ProcessEvent.self
        ) { group in
            group.addTask {
                do {
                    return .status(try await fetchStatus(
                        taskID: taskID,
                        options: options
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    return .statusFailed(CapturedFailure(error))
                }
            }

            var pollCount = 0
            var reachedCompletionBoundary = false
            var seenResultIDs = Set<String>()
            var orderedImages: [ChekinanaScannerResultImage?] = []
            var completedDownloadCount = 0
            var successfulDownloadCount = 0
            var warningCount = 0
            var hasCountedBackendWarning = false
            var hasIncompleteResultWarning = false
            var terminalFailure: CapturedFailure?
            var firstDownloadFailure: CapturedFailure?
            var latestPublishedCount = 0
            var latestExpectedPolaroids = options.expectedPolaroids
            var latestExtractionComplete = false

            do {
                while let event = try await group.next() {
                    try Task.checkCancellation()
                    switch event {
                    case .status(let statusResponse):
                        pollCount += 1
                        let normalizedStatus = statusResponse.status?.lowercased()
                        let polaroidResults = statusResponse.results.filter {
                            $0.type == "polaroid"
                        }
                        let publishedCount = max(
                            statusResponse.resultsCount ?? 0,
                            polaroidResults.count
                        )
                        latestPublishedCount = max(latestPublishedCount, publishedCount)
                        latestExpectedPolaroids = statusResponse.expectedPolaroids
                            ?? latestExpectedPolaroids
                        latestExtractionComplete = statusResponse.extractionComplete
                        if !hasCountedBackendWarning,
                           let backendWarning = statusResponse.warning?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !backendWarning.isEmpty {
                            hasCountedBackendWarning = true
                            hasIncompleteResultWarning = true
                            warningCount += 1
                        }
                        await progressObserver?(ChekinanaScannerTaskProgress(
                            phase: statusResponse.phase ?? statusResponse.status,
                            publishedResultCount: latestPublishedCount,
                            downloadedResultCount: successfulDownloadCount,
                            expectedPolaroids: latestExpectedPolaroids,
                            extractionComplete: statusResponse.extractionComplete
                        ))

                        let isFailure = normalizedStatus.map {
                            ["failed", "failure", "error", "canceled", "cancelled"]
                                .contains($0)
                        } ?? false
                        let isTerminalSuccess = normalizedStatus.map {
                            ["completed", "complete", "done", "success", "finished"]
                                .contains($0)
                        } ?? false
                        if isFailure {
                            reachedCompletionBoundary = true
                            warningCount += 1
                            hasIncompleteResultWarning = true
                            terminalFailure = CapturedFailure(
                                ChekinanaScanChekiError.backendFailure(
                                    statusResponse.error ?? statusResponse.message
                                )
                            )
                        } else {
                            reachedCompletionBoundary = statusResponse.extractionComplete
                                || isTerminalSuccess
                                || (normalizedStatus == nil && !statusResponse.results.isEmpty)
                        }

                        // API 1.2 publishes the complete result list only at the
                        // terminal boundary. Never expose a partial in-flight list.
                        if reachedCompletionBoundary {
                            for result in polaroidResults
                            where seenResultIDs.insert(result.id).inserted {
                                let index = orderedImages.count
                                orderedImages.append(nil)
                                let resultID = result.id
                                let sourceImage = statusResponse.sourceImage
                                let coordinateSystem = statusResponse.coordinateSystem
                                let quadrilateral = result.quadrilateral
                                group.addTask {
                                    do {
                                        try Task.checkCancellation()
                                        async let cleanImage = downloadResult(
                                            taskID: taskID,
                                            resultID: resultID,
                                            options: options
                                        )
                                        async let sourceAnnotation =
                                            ChekinanaScannerSourceAnnotationBuilder.make(
                                                preview: preparedUpload,
                                                sourceImage: sourceImage,
                                                coordinateSystem: coordinateSystem,
                                                quadrilateral: quadrilateral
                                            )
                                        let (downloaded, renderedAnnotation) = try await (
                                            cleanImage,
                                            sourceAnnotation
                                        )
                                        let image = ChekinanaScannerResultImage(
                                            data: downloaded.data,
                                            imagePixelWidth: downloaded.imagePixelWidth,
                                            imagePixelHeight: downloaded.imagePixelHeight,
                                            dateAnnotationState: downloaded.dateAnnotationState,
                                            sourceAnnotation: renderedAnnotation
                                        )
                                        return .downloaded(index: index, image: image)
                                    } catch is CancellationError {
                                        throw CancellationError()
                                    } catch {
                                        try Task.checkCancellation()
                                        return .downloadFailed(
                                            index: index,
                                            failure: CapturedFailure(error)
                                        )
                                    }
                                }
                            }
                        }

                        if !reachedCompletionBoundary {
                            if pollCount >= maximumStatusPollAttempts {
                                reachedCompletionBoundary = true
                                warningCount += 1
                                hasIncompleteResultWarning = true
                                terminalFailure = CapturedFailure(
                                    ChekinanaScanChekiError.pollTimedOut
                                )
                                break
                            }
                            let interval = statusPollIntervalNanoseconds
                            group.addTask {
                                do {
                                    try Task.checkCancellation()
                                    if interval > 0 {
                                        try await Task.sleep(nanoseconds: interval)
                                    }
                                    return .status(try await fetchStatus(
                                        taskID: taskID,
                                        options: options
                                    ))
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    try Task.checkCancellation()
                                    return .statusFailed(CapturedFailure(error))
                                }
                            }
                        }

                    case .statusFailed(let failure):
                        pollCount += 1
                        reachedCompletionBoundary = true
                        warningCount += 1
                        hasIncompleteResultWarning = true
                        terminalFailure = failure

                    case .downloaded(let index, let image):
                        guard orderedImages.indices.contains(index),
                              orderedImages[index] == nil else {
                            throw ChekinanaScanChekiError.invalidResultContract
                        }
                        orderedImages[index] = image
                        completedDownloadCount += 1
                        successfulDownloadCount += 1
                        await resultObserver?(index, image)
                        await progressObserver?(ChekinanaScannerTaskProgress(
                            phase: options.requestsDateAnnotation
                                ? "retrieving_results_with_date"
                                : "retrieving_results",
                            publishedResultCount: latestPublishedCount,
                            downloadedResultCount: successfulDownloadCount,
                            expectedPolaroids: latestExpectedPolaroids,
                            extractionComplete: latestExtractionComplete
                        ))

                    case .downloadFailed(let index, let failure):
                        guard orderedImages.indices.contains(index),
                              orderedImages[index] == nil else {
                            throw ChekinanaScanChekiError.invalidResultContract
                        }
                        completedDownloadCount += 1
                        warningCount += 1
                        hasIncompleteResultWarning = true
                        if firstDownloadFailure == nil {
                            firstDownloadFailure = failure
                        }
                        await progressObserver?(ChekinanaScannerTaskProgress(
                            phase: options.requestsDateAnnotation
                                ? "retrieving_results_with_date"
                                : "retrieving_results",
                            publishedResultCount: latestPublishedCount,
                            downloadedResultCount: successfulDownloadCount,
                            expectedPolaroids: latestExpectedPolaroids,
                            extractionComplete: latestExtractionComplete
                        ))
                    }

                    if reachedCompletionBoundary,
                       completedDownloadCount == orderedImages.count {
                        break
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }

            guard reachedCompletionBoundary else {
                group.cancelAll()
                throw ChekinanaScanChekiError.pollTimedOut
            }
            group.cancelAll()
            let images = orderedImages.compactMap { $0 }
            guard !images.isEmpty else {
                if let terminalFailure {
                    throw terminalFailure
                }
                if let firstDownloadFailure {
                    throw firstDownloadFailure
                }
                throw ChekinanaScanChekiError.noResultImages
            }
            return PollResult(
                images: images,
                warningCount: warningCount,
                hasIncompleteResultWarning: hasIncompleteResultWarning
            )
        }
    }

    private func upload(
        _ image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions
    ) async throws -> String {
        let baseURL = try baseURL()
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("process")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(for: image, options: options, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        let uploadResponse = try decoder.decode(ChekinanaScannerUploadResponse.self, from: data)
        guard let taskID = uploadResponse.taskID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !taskID.isEmpty else {
            throw ChekinanaScanChekiError.missingTaskID
        }

        return taskID
    }

    private func fetchStatus(
        taskID: String,
        options: ChekinanaScannerOptions
    ) async throws -> ChekinanaScannerStatusResponse {
        let baseURL = try baseURL()
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("status")
            .appendingPathComponent(taskID)

        try Task.checkCancellation()
        let request = URLRequest(url: url)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
        return try decoder.decode(ChekinanaScannerStatusResponse.self, from: data)
    }

    func downloadResult(
        taskID: String,
        resultID: String,
        options: ChekinanaScannerOptions,
        sourceAnnotation: ChekinanaScannerSourceAnnotation? = nil
    ) async throws -> ChekinanaScannerResultImage {
        let result = try await downloadResultData(
            taskID: taskID,
            resultID: resultID,
            options: options
        )
        return ChekinanaScannerResultImage(
            data: result.data,
            imagePixelWidth: result.width,
            imagePixelHeight: result.height,
            dateAnnotationState: result.dateAnnotationState,
            sourceAnnotation: sourceAnnotation
        )
    }

    private func downloadResultData(
        taskID: String,
        resultID: String,
        options: ChekinanaScannerOptions
    ) async throws -> (
        data: Data,
        width: Int,
        height: Int,
        dateAnnotationState: ChekinanaChekiDateAnnotationState
    ) {
        let baseURL = try baseURL()
        let cleanURL = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("result")
            .appendingPathComponent(taskID)
            .appendingPathComponent(resultID)
        let request = URLRequest(url: cleanURL)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        guard !data.isEmpty else {
            throw ChekinanaScanChekiError.emptyResultImage
        }
        guard data.count <= 32 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...1_000_000).contains(width),
              (1...1_000_000).contains(height) else {
            throw ChekinanaScanChekiError.invalidResultImage
        }
        guard response is HTTPURLResponse else {
            throw ChekinanaScanChekiError.invalidHTTPResponse
        }
        return (
            data,
            width,
            height,
            .notRequested
        )
    }

    private func baseURL() throws -> URL {
        guard case .resolved(let url) = baseURLResolution else {
            throw ChekinanaScanChekiError.invalidBaseURLConfiguration
        }
        return url
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChekinanaScanChekiError.invalidHTTPResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ChekinanaScanChekiError.httpStatus(httpResponse.statusCode)
        }
    }

    func multipartBody(
        for image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions,
        boundary: String
    ) -> Data {
        var body = Data()
        let postprocessFields: (denoise: String, sharpen: String)
        switch options.postprocessMode {
        case .off:
            postprocessFields = ("0", "0")
        case .denoise:
            postprocessFields = ("1", "0")
        case .sharpen:
            postprocessFields = ("1", "1")
        }
        let fields: [(String, String)] = [
            ("sleeve", options.sleevesEnabled ? "1" : "0"),
            ("wb", options.whiteBalance ? "1" : "0"),
            ("denoise", postprocessFields.denoise),
            ("sharpen", postprocessFields.sharpen),
        ]
        for field in fields {
            body.appendMultipartField(name: field.0, value: field.1, boundary: boundary)
        }

        let filenameExtension = normalizedUploadExtension(image.filenameExtension)
        body.appendMultipartFile(
            name: "file",
            filename: "source.\(filenameExtension)",
            contentType: contentType(for: filenameExtension),
            data: image.data,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")

        return body
    }

    private func normalizedUploadExtension(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "jpg", "jpeg":
            return "jpg"
        case "png":
            return "png"
        case "bmp":
            return "bmp"
        case "tif", "tiff":
            return "tiff"
        case "webp":
            return "webp"
        default:
            return "jpg"
        }
    }

    private func contentType(for filenameExtension: String) -> String {
        switch filenameExtension {
        case "png":
            return "image/png"
        case "bmp":
            return "image/bmp"
        case "tiff":
            return "image/tiff"
        case "webp":
            return "image/webp"
        default:
            return "image/jpeg"
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt(forKey key: Key) throws -> Int {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key),
           let integer = Int(value) {
            return integer
        }
        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected integer-compatible value"
            )
        )
    }

    func decodeFlexibleBool(forKey key: Key) throws -> Bool {
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decode(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: break
            }
        }
        throw DecodingError.typeMismatch(
            Bool.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected boolean-compatible value"
            )
        )
    }

    func decodeFlexibleString(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }

        if let int = try? decode(Int.self, forKey: key) {
            return String(int)
        }

        if let double = try? decode(Double.self, forKey: key) {
            return String(double)
        }

        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected string-compatible value")
        )
    }

    func decodeSafeNumericResultID(forKey key: Key) throws -> String {
        let value: String
        if let integer = try? decode(Int.self, forKey: key), integer > 0 {
            value = String(integer)
        } else {
            value = try decode(String.self, forKey: key)
        }
        guard !value.isEmpty,
              value.count <= 32,
              value.first != "0",
              value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Result IDs must be non-empty numeric values"
            )
        }
        return value
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(contentType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }

    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }
}

private enum ChekinanaAddChekiError: LocalizedError {
    case invalidIdolList
    case noIdol(String)
    case duplicateIdol(String)
    case ambiguousIdol(String)
    case noEvent(String)
    case ambiguousEvent(String)
    case duplicateCheki(String)
    case duplicateIndex(Int)
    case indexOverflow
    case modelContextMismatch
    case invalidArgumentValue(String, String)
    case duplicateArgument(String)
    case systemManagedArgument(String)
    case unsupportedArgument

    var errorDescription: String? {
        switch self {
        case .invalidIdolList:
            ChekinanaCommandCopy.text("error.idol_list_empty", fallback: "Idol list cannot be empty when Idol metadata is supplied.")
        case .noIdol(let token):
            ChekinanaCommandCopy.format("error.no_idol", fallback: "No Idol matches: %@.", token)
        case .duplicateIdol(let token):
            ChekinanaCommandCopy.format("error.duplicate_idol", fallback: "Duplicate Idol records match: %@.", token)
        case .ambiguousIdol(let token):
            ChekinanaCommandCopy.format("error.ambiguous_idol", fallback: "Ambiguous Idol: %@. Use a longer Idol ID or exact name.", token)
        case .noEvent(let token):
            ChekinanaCommandCopy.format("error.no_event", fallback: "No Event matches: %@.", token)
        case .ambiguousEvent(let token):
            ChekinanaCommandCopy.format("error.ambiguous_event_id", fallback: "Ambiguous Event ID: %@.", token)
        case .duplicateCheki(let token):
            ChekinanaCommandCopy.format("error.cheki_exists", fallback: "Cheki already exists: %@.", token)
        case .duplicateIndex(let idx):
            ChekinanaCommandCopy.format("error.cheki_index_used", fallback: "Cheki index #%lld is already used in this Idol/date group.", Int64(idx))
        case .indexOverflow:
            ChekinanaCommandCopy.text("error.cheki_index_overflow", fallback: "Cheki index cannot be incremented for this Idol/date group.")
        case .modelContextMismatch:
            ChekinanaCommandCopy.text("error.context_mismatch", fallback: "Cheki relationships could not be attached to the current data context.")
        case .invalidArgumentValue(let argumentName, let value):
            ChekinanaCommandCopy.format("error.invalid_argument", fallback: "Invalid %1$@: %2$@.", argumentName, value)
        case .duplicateArgument(let argumentName):
            ChekinanaCommandCopy.format("error.duplicate_argument", fallback: "Duplicate %@ field.", argumentName)
        case .systemManagedArgument(let argumentName):
            ChekinanaCommandCopy.format("error.system_managed_argument", fallback: "%@ cannot be set.", argumentName)
        case .unsupportedArgument:
            ChekinanaCommandCopy.text("error.unsupported_addcheki", fallback: "Unsupported Add Cheki field.")
        }
    }
}

private enum ChekinanaEventError: LocalizedError {
    case invalidName
    case invalidURL
    case missingRequiredFields([String])
    case notFound(String)
    case ambiguous(String)
    case duplicate

    var errorDescription: String? {
        switch self {
        case .invalidName:
            ChekinanaCommandCopy.text("error.event_name_empty", fallback: "Event name must be non-empty.")
        case .invalidURL:
            ChekinanaCommandCopy.text("error.event_url", fallback: "Invalid Event URL.")
        case .missingRequiredFields(let fields):
            ChekinanaCommandCopy.format("error.event_missing_fields", fallback: "Event URL requires an explicit name and date. Missing: %@.", fields.joined(separator: ", "))
        case .notFound(let token):
            ChekinanaCommandCopy.format("error.no_event", fallback: "No Event matches: %@.", token)
        case .ambiguous(let token):
            ChekinanaCommandCopy.format("error.ambiguous_event", fallback: "Ambiguous Event: %@. Use a longer Event ID or exact name.", token)
        case .duplicate:
            ChekinanaCommandCopy.text("error.event_duplicate", fallback: "An Event with the same name, date, and URL already exists.")
        }
    }
}

private enum ChekinanaEditConflictError: LocalizedError {
    case staleEvent(String)
    case staleCheki(String)

    var errorDescription: String? {
        switch self {
        case .staleEvent(let code):
            ChekinanaCommandCopy.format("error.event_stale", fallback: "The Event changed after this edit was prepared. Cancel %@ and prepare the edit again.", code)
        case .staleCheki(let code):
            ChekinanaCommandCopy.format("error.cheki_stale", fallback: "The Cheki changed after this edit was prepared. Cancel %@ and prepare the edit again.", code)
        }
    }
}

private enum ChekinanaTemporaryChekiError: LocalizedError {
    case notFound(String)
    case ambiguous(String)
    case alreadyConsumed(String)
    case referencedByPendingConfirmation(String)
    case capacityExceeded(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .notFound(let token):
            ChekinanaCommandCopy.format("error.no_temporary_cheki", fallback: "No temporary Cheki matches: %@. Scan first.", token)
        case .ambiguous(let token):
            ChekinanaCommandCopy.format("error.ambiguous_temporary_cheki", fallback: "Ambiguous temporary Cheki ID: %@. Use a longer ID.", token)
        case .alreadyConsumed(let token):
            ChekinanaCommandCopy.format("error.temporary_cheki_consumed", fallback: "Temporary Cheki was already added: %@.", token)
        case .referencedByPendingConfirmation(let token):
            ChekinanaCommandCopy.format("error.temporary_cheki_pending", fallback: "Temporary Cheki is referenced by a pending confirmation: %@. Confirm or cancel that operation first.", token)
        case .capacityExceeded(let bytes):
            ChekinanaCommandCopy.format("error.temporary_storage", fallback: "Temporary Cheki storage limit reached (%lld/100 MB). Discard temporary Cheki first; images referenced by pending confirmations cannot be evicted.", Int64(bytes / 1_024 / 1_024))
        }
    }
}

private enum ChekinanaAlbumPreparationError: LocalizedError {
    case noPreparedImage

    var errorDescription: String? {
        ChekinanaCommandCopy.text("error.photo_prepare", fallback: "Selected photo could not be prepared.")
    }
}

private enum ChekinanaDeleteError: LocalizedError {
    case idolHasChekis(Int)
    case eventHasChekis(Int)
    case managedImageRecoveryMissing
    case managedImageRestoreFailed(String)
    case databaseSaveAndImageRestoreFailed(save: String, restore: String)
    case managedImageCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .idolHasChekis(let count):
            ChekinanaCommandCopy.format("error.idol_delete_records", fallback: "The Idol now has %lld associated records; deletion was not performed.", Int64(count))
        case .eventHasChekis(let count):
            ChekinanaCommandCopy.format("error.event_delete_records", fallback: "The Event now has %lld associated records; deletion was not performed.", Int64(count))
        case .managedImageRecoveryMissing:
            ChekinanaCommandCopy.text("error.image_recovery_missing", fallback: "The managed Cheki image is missing from both its original and recovery locations; deletion was not retried.")
        case .managedImageRestoreFailed(let detail):
            ChekinanaCommandCopy.format("error.image_restore_failed", fallback: "Managed Cheki image recovery failed. Retry Confirm after resolving file access: %@", detail)
        case .databaseSaveAndImageRestoreFailed(let save, let restore):
            ChekinanaCommandCopy.format("error.database_and_restore_failed", fallback: "Database deletion failed (%1$@); managed image recovery also failed (%2$@). The confirmation remains pending and will retry recovery first.", save, restore)
        case .managedImageCleanupFailed(let detail):
            ChekinanaCommandCopy.format("error.image_cleanup_failed", fallback: "Cheki data was deleted, but managed image cleanup failed: %@. The confirmation remains pending; retry Confirm to finish cleanup.", detail)
        }
    }
}

private enum ChekinanaDownloadChekiError: LocalizedError {
    case noCheki(String)
    case ambiguousCheki(String)
    case unreadableLocalImage
    case invalidPhotoAsset
    case photoLibraryPermissionDenied
    case photoLibrarySaveFailed

    var errorDescription: String? {
        switch self {
        case .noCheki(let token):
            return ChekinanaCommandCopy.format("error.no_cheki", fallback: "No Cheki matches: %@.", token)
        case .ambiguousCheki(let token):
            return ChekinanaCommandCopy.format("error.ambiguous_cheki", fallback: "Ambiguous Cheki ID: %@.", token)
        case .unreadableLocalImage:
            return ChekinanaCommandCopy.text("error.cheki_image_unreadable", fallback: "Cheki image file is missing, unreadable, or not a valid image.")
        case .invalidPhotoAsset:
            return ChekinanaCommandCopy.text("error.photo_asset", fallback: "Photo library could not create an image asset from this Cheki file.")
        case .photoLibraryPermissionDenied:
            return ChekinanaCommandCopy.text("error.photo_permission", fallback: "Photo library add permission was denied or restricted.")
        case .photoLibrarySaveFailed:
            return ChekinanaCommandCopy.text("error.photo_save", fallback: "Failed to save Cheki to the photo library.")
        }
    }
}

private enum ChekinanaScanChekiError: LocalizedError {
    case invalidBaseURLConfiguration
    case invalidArgumentValue(String, String)
    case missingTaskID
    case backendFailure(String?)
    case pollTimedOut
    case emptyResultImage
    case invalidResultImage
    case invalidResultContract
    case invalidUploadImage
    case uploadTooLarge
    case noResultImages
    case invalidHTTPResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURLConfiguration:
            return ChekinanaCommandCopy.text("error.scan_base_url", fallback: "Scanner base URL configuration is invalid.")
        case .invalidArgumentValue(let argumentName, let value):
            return ChekinanaCommandCopy.format("error.invalid_argument", fallback: "Invalid %1$@: %2$@.", argumentName, value)
        case .missingTaskID:
            return ChekinanaCommandCopy.text("error.scan_task_id", fallback: "Scanner did not return a task ID.")
        case .backendFailure:
            return ChekinanaCommandCopy.text("error.scan_failed", fallback: "Scanner failed.")
        case .pollTimedOut:
            return ChekinanaCommandCopy.text("error.scan_timeout", fallback: "Scanner timed out before results were ready.")
        case .emptyResultImage:
            return ChekinanaCommandCopy.text("error.scan_empty_image", fallback: "Scanner returned an empty result image.")
        case .invalidResultImage:
            return ChekinanaCommandCopy.text("error.scan_invalid_image", fallback: "Scanner returned data that is not a decodable image; no temporary results were created.")
        case .invalidResultContract:
            return ChekinanaCommandCopy.text("error.scan_invalid_contract", fallback: "Scanner returned inconsistent result metadata; no temporary results were created.")
        case .invalidUploadImage:
            return ChekinanaCommandCopy.text("error.scan_upload_image", fallback: "Selected source image could not be prepared for the scanner.")
        case .uploadTooLarge:
            return ChekinanaCommandCopy.text("error.scan_upload_large", fallback: "Selected source image exceeds the scanner upload limit after normalization.")
        case .noResultImages:
            return ChekinanaCommandCopy.text("error.scan_no_results", fallback: "Scanner returned no Cheki images; no temporary results were created.")
        case .invalidHTTPResponse:
            return ChekinanaCommandCopy.text("error.scan_http_response", fallback: "Scanner returned an invalid HTTP response.")
        case .httpStatus(let statusCode):
            return ChekinanaCommandCopy.format("error.scan_http_status", fallback: "Scanner request failed with HTTP %lld.", Int64(statusCode))
        }
    }
}

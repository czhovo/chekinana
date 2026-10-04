import Foundation
import Combine
import CoreImage
import CoreML
import ImageIO
import Network
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
    let openTime: String?
    let startTime: String?
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

enum ChekinanaChekiRecordConsumptionPolicy {
    /// `nil` means the no-media record is fully consumed and must be deleted.
    nonisolated static func remainingCount(
        currentCount: Int,
        consumedCount: Int
    ) -> Int? {
        guard currentCount > 0 else { return nil }
        let remaining = currentCount - min(max(0, consumedCount), currentCount)
        return remaining > 0 ? remaining : nil
    }

    /// Consumes media quantities while preserving the matched record's day.
    /// Other business fields remain owned by the surrounding transaction; in
    /// particular, valid same-day Event propagation must not be undone here.
    @MainActor
    static func consume(
        _ consumedCount: Int,
        from record: ChekiRecord,
        preserving snapshot: ChekinanaChekiRecordSnapshot,
        in modelContext: ModelContext
    ) {
        guard let remaining = remainingCount(
            currentCount: record.count,
            consumedCount: consumedCount
        ) else {
            modelContext.delete(record)
            return
        }
        record.date = snapshot.identity.canonicalDate
        record.count = remaining
    }
}

enum ChekinanaChekiRecordAllocationPolicy {
    struct MediaContext {
        let date: Date?
        let idolIDs: [UUID]
        let eventID: UUID?
        let size: ChekiSize
    }

    struct Candidate {
        let id: UUID
        let date: Date?
        let idolIDs: [UUID]
        let eventID: UUID?
        let size: ChekiSize?
        let count: Int
    }

    nonisolated static func matches(
        _ candidate: Candidate,
        media: MediaContext,
        calendar: Calendar
    ) -> Bool {
        guard candidate.count > 0,
              let candidateDate = candidate.date,
              let mediaDate = media.date,
              calendar.isDate(candidateDate, inSameDayAs: mediaDate),
              Set(candidate.idolIDs) == Set(media.idolIDs),
              candidate.size == nil || candidate.size == media.size else {
            return false
        }
        if media.eventID == nil {
            return candidate.eventID == nil
        }
        return candidate.eventID == nil || candidate.eventID == media.eventID
    }

    nonisolated static func allocationIDs(
        media: [MediaContext],
        candidates: [Candidate],
        calendar: Calendar
    ) -> [UUID?] {
        let priority = candidates.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var remaining = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.id, max(0, $0.count)) }
        )
        return media.map { item in
            let selected = priority.first { candidate in
                    matches(candidate, media: item, calendar: calendar)
                        && remaining[candidate.id, default: 0] > 0
                }
            guard let selected else { return nil }
            remaining[selected.id, default: 0] -= 1
            return selected.id
        }
    }
}

extension ChekinanaChekiCard {
    func replacingIdolNames(_ names: [String]) -> ChekinanaChekiCard {
        ChekinanaChekiCard(
            id: id,
            imageRef: imageRef,
            createdAt: createdAt,
            confirmationCode: confirmationCode,
            thumbnailImageData: thumbnailImageData,
            idx: idx,
            idolNames: names,
            eventName: eventName,
            eventDateText: eventDateText,
            userAppears: userAppears,
            size: size,
            isFavorite: isFavorite,
            hasPostedToSNS: hasPostedToSNS,
            note: note,
            dateAnnotationState: dateAnnotationState
        )
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

enum ChekinanaScanReviewInputHandoffPolicy {
    struct Plan: Equatable, Sendable {
        let reviewSources: [ChekinanaScanSourceDescriptor]
        let retainedInputSources: [ChekinanaScanSourceDescriptor]

        var claimedSourceIDs: Set<UUID> {
            Set(reviewSources.map(\.id))
        }
    }

    /// Review claims only inputs that still own at least one visible temporary
    /// Cheki. Inputs that produced no result remain in Scan with their original
    /// order and per-input rotation state so they can be retried unchanged.
    static func plan(
        inputSources: [ChekinanaScanSourceDescriptor],
        temporarySourceIDs: [UUID?]
    ) -> Plan {
        let successfulIDs = Set(temporarySourceIDs.compactMap { $0 })
        return Plan(
            reviewSources: inputSources.filter { successfulIDs.contains($0.id) },
            retainedInputSources: inputSources.filter { !successfulIDs.contains($0.id) }
        )
    }
}

/// Records results at the same boundary at which their ledger objects become
/// Review-protected. Direct-import recognition may complete out of order, so
/// batches are keyed by their original input position and flattened in source
/// order when cancellation publishes a partial Review.
struct ChekinanaScanSessionResultTracker {
    private var batches: [Int: [ChekinanaChekiCard]] = [:]

    var cards: [ChekinanaChekiCard] {
        batches.keys.sorted().flatMap { batches[$0] ?? [] }
    }

    var temporaryIDs: Set<UUID> {
        Set(cards.map(\.id))
    }

    var isEmpty: Bool { batches.isEmpty }

    mutating func record(_ cards: [ChekinanaChekiCard], at inputIndex: Int) {
        guard !cards.isEmpty else { return }
        batches[inputIndex] = cards
    }

    mutating func removeAll() {
        batches.removeAll(keepingCapacity: false)
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
                  !ChekinanaFourPageVisibilityPolicy.includesRecord(
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
            // Standardized 1200x1908 MediaItem stays byte-for-pixel unchanged;
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
    /// Legacy remote-scanner artifact. Active on-device Scan leaves this nil;
    /// Review renders from `ChekinanaReviewRectificationSource` on demand.
    let previewImageData: Data?
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let quadrilateral: [ChekinanaScannerQuadrilateralPoint]

    init(
        previewImageData: Data? = nil,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint]
    ) {
        self.previewImageData = previewImageData
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.quadrilateral = quadrilateral
    }

    var isValid: Bool {
        guard sourcePixelWidth > 0,
              sourcePixelHeight > 0,
              quadrilateral.count == 4 else { return false }
        return quadrilateral.allSatisfy { point in
            point.x.isFinite && point.y.isFinite
        }
    }
}

/// One immutable source image shared by every temporary Cheki extracted from
/// the same Scan input. Identity is intentionally independent of `sourceID`:
/// inputs without a source ID still share within one scanner invocation, while
/// unrelated inputs can never be coalesced accidentally.
final class ChekinanaSharedReviewSourceImage: @unchecked Sendable, Equatable {
    let identity: UUID
    let data: Data

    init(data: Data) {
        self.identity = UUID()
        self.data = data
    }

    static func == (
        lhs: ChekinanaSharedReviewSourceImage,
        rhs: ChekinanaSharedReviewSourceImage
    ) -> Bool {
        lhs === rhs
    }
}

/// The clean, EXIF-upright source and quadrilateral retained only while Scan
/// Review is open. Unlike the rendered annotation preview, this contains no
/// overlay and can rebuild the final Mini/Wide pixels without reusing the
/// provisional Mini rectification.
struct ChekinanaReviewRectificationSource: Equatable, Sendable {
    let sourceImage: ChekinanaSharedReviewSourceImage
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let quadrilateral: [ChekinanaScannerQuadrilateralPoint]
    let appliesWhiteBalance: Bool
    let postprocessing: ChekinanaRectificationPostprocessing

    var imageData: Data { sourceImage.data }
    var sourceIdentity: UUID { sourceImage.identity }

    init(
        imageData: Data,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint],
        appliesWhiteBalance: Bool,
        postprocessing: ChekinanaRectificationPostprocessing = .standard
    ) {
        self.init(
            sourceImage: ChekinanaSharedReviewSourceImage(data: imageData),
            sourcePixelWidth: sourcePixelWidth,
            sourcePixelHeight: sourcePixelHeight,
            quadrilateral: quadrilateral,
            appliesWhiteBalance: appliesWhiteBalance,
            postprocessing: postprocessing
        )
    }

    init(
        sourceImage: ChekinanaSharedReviewSourceImage,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint],
        appliesWhiteBalance: Bool,
        postprocessing: ChekinanaRectificationPostprocessing = .standard
    ) {
        self.sourceImage = sourceImage
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.quadrilateral = quadrilateral
        self.appliesWhiteBalance = appliesWhiteBalance
        self.postprocessing = postprocessing
    }

    var isValid: Bool {
        guard !imageData.isEmpty,
              sourcePixelWidth > 0,
              sourcePixelHeight > 0,
              quadrilateral.count == 4 else { return false }
        return quadrilateral.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
}

enum ChekinanaScannerAnnotationPreviewRenderer {
    enum Failure: String, Equatable, Sendable {
        case emptySource
        case sourceTooLarge
        case invalidGeometry
        case decodeFailed
        case previewTooLarge
        case aspectMismatch
        case invalidQuadrilateral
        case encodeFailed
    }

    struct Outcome: Sendable {
        let data: Data?
        let failure: Failure?
    }

    static func render(
        sourcePreviewData: Data,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint]
    ) -> Data? {
        renderOutcome(
            sourcePreviewData: sourcePreviewData,
            sourcePixelWidth: sourcePixelWidth,
            sourcePixelHeight: sourcePixelHeight,
            quadrilateral: quadrilateral
        ).data
    }

    static func renderOutcome(
        sourcePreviewData: Data,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        quadrilateral: [ChekinanaScannerQuadrilateralPoint]
    ) -> Outcome {
        guard !sourcePreviewData.isEmpty else {
            return Outcome(data: nil, failure: .emptySource)
        }
        guard sourcePreviewData.count <= 8 * 1_024 * 1_024 else {
            return Outcome(data: nil, failure: .sourceTooLarge)
        }
        guard sourcePixelWidth > 0,
              sourcePixelHeight > 0,
              quadrilateral.count == 4 else {
            return Outcome(data: nil, failure: .invalidGeometry)
        }
        guard let source = CGImageSourceCreateWithData(
                sourcePreviewData as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              image.width > 0,
              image.height > 0 else {
            return Outcome(data: nil, failure: .decodeFailed)
        }
        guard max(image.width, image.height)
                <= ChekinanaLiveScannerUploadPreparer.maximumAnnotationPreviewDimension + 1 else {
            return Outcome(data: nil, failure: .previewTooLarge)
        }
        let previewAspect = Double(image.width) / Double(image.height)
        let sourceAspect = Double(sourcePixelWidth) / Double(sourcePixelHeight)
        guard abs(previewAspect - sourceAspect) / max(sourceAspect, 0.000_001) <= 0.02 else {
            return Outcome(data: nil, failure: .aspectMismatch)
        }
        guard quadrilateral.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return Outcome(data: nil, failure: .invalidQuadrilateral)
        }
        // EdgeFit intentionally allows a fitted corner to extend outside the
        // source image; rectification samples those locations by clamping to
        // the source edge. Clamp only this display copy so the annotation can
        // still be drawn without changing the quadrilateral used by detection
        // or rectification.
        let points = quadrilateral.map { point in
            CGPoint(
                x: min(
                    max(
                        CGFloat(point.x / Double(sourcePixelWidth))
                            * CGFloat(image.width),
                        0
                    ),
                    CGFloat(image.width)
                ),
                y: min(
                    max(
                        CGFloat(point.y / Double(sourcePixelHeight))
                            * CGFloat(image.height),
                        0
                    ),
                    CGFloat(image.height)
                )
            )
        }

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
        // A photographic preview encoded as PNG can briefly require tens of
        // megabytes per concurrent Scan input. That memory spike previously
        // made annotation generation fail nondeterministically while the
        // extracted Cheki itself still succeeded. The overlay is a display
        // artifact, so bounded high-quality JPEG is the appropriate format.
        guard let data = rendered.jpegData(compressionQuality: 0.90),
              !data.isEmpty,
              data.count <= 8 * 1_024 * 1_024 else {
            return Outcome(data: nil, failure: .encodeFailed)
        }
        return Outcome(data: data, failure: nil)
    }

    /// Builds the display-only annotation lazily. Both source downsampling and
    /// overlay rendering run away from the main actor; callers may keep the
    /// returned JPEG only for their current UI session.
    static func renderFromSource(
        _ source: ChekinanaReviewRectificationSource
    ) async -> Outcome {
        guard !Task.isCancelled else {
            return Outcome(data: nil, failure: nil)
        }
        guard let previewData = await ChekinanaEdgeFitRectifier.annotationPreviewData(
            from: source.imageData
        ), !Task.isCancelled else {
            return Outcome(data: nil, failure: .decodeFailed)
        }
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                return Outcome(data: nil, failure: nil)
            }
            return renderOutcome(
                sourcePreviewData: previewData,
                sourcePixelWidth: source.sourcePixelWidth,
                sourcePixelHeight: source.sourcePixelHeight,
                quadrilateral: source.quadrilateral
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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

enum ChekinanaCommandCopy {
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

    static func displayText(_ text: String) -> String {
        guard text.hasPrefix("error: ") else { return text }
        return ChekinanaL10n.format(
            "assistant.error.detail", fallback: "Error: %@",
            String(text.dropFirst("error: ".count))
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
        let reviewRectificationSource: ChekinanaReviewRectificationSource?
        let reviewRotationQuarterTurns: Int
        let reviewTransformGeneration: UInt64
        let reviewTransformSourceVersion: UInt64
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
        let existingChekiRecordSnapshot: ChekinanaChekiRecordSnapshot?
        let usesScanReviewRecordMatching: Bool
        let explicitlyEditedFields: Set<TemporaryChekiField>

        init(
            id: UUID,
            temporaryChekiID: UUID?,
            image: ChekinanaPendingChekiImage,
            thumbnailImageData: Data?,
            reviewRectificationSource: ChekinanaReviewRectificationSource? = nil,
            reviewRotationQuarterTurns: Int = 0,
            reviewTransformGeneration: UInt64 = 0,
            reviewTransformSourceVersion: UInt64 = 1,
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
            existingChekiRecordSnapshot: ChekinanaChekiRecordSnapshot? = nil,
            usesScanReviewRecordMatching: Bool = false,
            explicitlyEditedFields: Set<TemporaryChekiField>
        ) {
            self.id = id
            self.temporaryChekiID = temporaryChekiID
            self.image = image
            self.thumbnailImageData = thumbnailImageData
            self.reviewRectificationSource = reviewRectificationSource?.isValid == true
                ? reviewRectificationSource : nil
            let rotationRemainder = reviewRotationQuarterTurns % 4
            self.reviewRotationQuarterTurns = rotationRemainder >= 0
                ? rotationRemainder : rotationRemainder + 4
            self.reviewTransformGeneration = reviewTransformGeneration
            self.reviewTransformSourceVersion = reviewTransformSourceVersion
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
            self.existingChekiRecordSnapshot = existingChekiRecordSnapshot
            self.usesScanReviewRecordMatching = usesScanReviewRecordMatching
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
        let openTime: String?
        let startTime: String?
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
            openTime: String? = nil,
            startTime: String? = nil,
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
            self.openTime = ChekinanaEventTime.normalized(openTime)
            self.startTime = ChekinanaEventTime.normalized(startTime)
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
        let openTime: String?
        let startTime: String?
        let note: String
    }

    struct DeleteEventPayload {
        let eventID: UUID
        let expectedUpdatedAt: Date
    }

    struct EditChekiPayload {
        let chekiID: UUID
        let expectedUpdatedAt: Date
        let authorization: ChekinanaChekiEditAuthorization
        let explicitlyEditedFields: Set<ChekinanaChekiEditableField>
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
        var cascadeAuthorization: ChekinanaIdolCascadeAuthorization? = nil
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
        let count: Int
        let expectedChekiRecordSnapshot: ChekinanaChekiRecordSnapshot?
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

    struct TemporaryChekiTransformIntent: Equatable, Sendable {
        let size: ChekiSize
        let rotationQuarterTurns: Int
        let sourceVersion: UInt64
        let generation: UInt64
    }

    struct TemporaryChekiTransformSnapshot: Equatable, Sendable {
        let id: UUID
        let intent: TemporaryChekiTransformIntent
        let sourceImage: ChekinanaPendingChekiImage
        let reviewRectificationSource: ChekinanaReviewRectificationSource?
        let sourceDateAnnotationState: ChekinanaChekiDateAnnotationState
    }

    enum TemporaryChekiTransformPublication: Equatable, Sendable {
        case published
        case stale
        case unavailable
        case capacityExceeded
    }

    /// One reversible image edit; never snapshots user-entered record fields.
    struct TemporaryChekiImageState {
        let image: ChekinanaPendingChekiImage
        let thumbnailImageData: Data?
        let reviewRectificationSource: ChekinanaReviewRectificationSource?
        let dateAnnotationState: ChekinanaChekiDateAnnotationState
        let sourceAnnotation: ChekinanaScannerSourceAnnotation?
        let imageRotationQuarterTurns: Int
        let transformFallbackSourceImage: ChekinanaPendingChekiImage
        let transformSourceIsPublishedImage: Bool
        let transformSourceDateAnnotationState: ChekinanaChekiDateAnnotationState
        let size: ChekiSize?
        let sizeWasExplicitlyEdited: Bool

        init(_ value: TemporaryCheki) {
            image = value.image
            thumbnailImageData = value.thumbnailImageData
            reviewRectificationSource = value.reviewRectificationSource
            dateAnnotationState = value.dateAnnotationState
            sourceAnnotation = value.sourceAnnotation
            imageRotationQuarterTurns = value.imageRotationQuarterTurns
            transformFallbackSourceImage = value.transformFallbackSourceImage
            transformSourceIsPublishedImage = value.transformSourceIsPublishedImage
            transformSourceDateAnnotationState = value.transformSourceDateAnnotationState
            size = value.size
            sizeWasExplicitlyEdited = value.explicitlyEditedFields.contains(.size)
        }
    }

    struct TemporaryCheki {
        let id: UUID
        var image: ChekinanaPendingChekiImage
        var thumbnailImageData: Data?
        var reviewRectificationSource: ChekinanaReviewRectificationSource?
        var refitOriginalSource: ChekinanaReviewRectificationSource? = nil
        let sourceID: UUID?
        let sourceOrigin: ChekinanaScanSourceOrigin
        var dateAnnotationState: ChekinanaChekiDateAnnotationState
        var sourceAnnotation: ChekinanaScannerSourceAnnotation?
        var imageRotationQuarterTurns: Int
        /// Stable input for rebuilding any requested size/rotation. New scan
        /// results normally retain a rectification source; legacy results use
        /// this immutable clean fallback instead of chaining JPEG transforms.
        var transformFallbackSourceImage: ChekinanaPendingChekiImage
        var transformSourceIsPublishedImage: Bool
        var transformSourceDateAnnotationState: ChekinanaChekiDateAnnotationState
        var desiredTransformSize: ChekiSize
        var desiredTransformRotationQuarterTurns: Int
        var transformSourceVersion: UInt64
        var transformGeneration: UInt64
        var isTransformInFlight: Bool
        var isRefitInFlight = false
        var refitUndo: TemporaryChekiImageState? = nil
        // Failure is presentation-only: the original pixels stay owned here,
        // but cannot be saved until the user restores their visible result.
        var isRefitFailed = false
        var hasRefitUndo: Bool { isRefitFailed || refitUndo != nil }
        var idolIDs: [UUID]
        var date: Date?
        var eventID: UUID?
        var eventWasAutoMatched: Bool
        var idx: Int?
        var existingChekiID: UUID?
        var existingSelectionIsManual: Bool
        var hasScanReviewRecordInheritance = false
        var scanReviewRecordSnapshot: ChekinanaChekiRecordSnapshot? = nil
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
    private var finalizedTemporaryBatchReservationTokens = Set<UUID>()
    private var committedTemporaryBatchRecoveries: [UUID: [TemporaryChekiBatchReservationItem]] = [:]
    private var idolCandidates: [String: ChekinanaPreparedIdolCandidate] = [:]
    private var idolQueryGeneration: UInt64 = 0
    private var implicitConfirmationStartIndex = 0

    private let maximumTemporaryChekiBytes: Int
    private let temporaryChekiTTL: TimeInterval

    init(
        maximumTemporaryChekiBytes: Int = 400 * 1_024 * 1_024,
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
                        case .addCheki(let payload) = current.action,
                        let temporary = temporaryChekis[temporaryID] else { return false }
                  return payload.temporaryChekiID == temporaryID
                      && !temporary.isTransformInFlight
                      && !temporary.isRefitFailed
                      && payload.reviewTransformGeneration
                        == temporary.transformGeneration
                      && payload.reviewTransformSourceVersion
                        == temporary.transformSourceVersion
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
                id: temporaryID
            )
        }
        let codes = Set(expected.map(\.code))
        guard codes.isDisjoint(with: reservedTemporaryConfirmationCodes) else {
            return nil
        }
        let reservation = TemporaryChekiBatchReservation(
            token: UUID(),
            expected: expected
        )
        temporaryBatchReservations[reservation.token] = expected
        reservedTemporaryConfirmationCodes.formUnion(codes)
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
        reviewRectificationSources: [ChekinanaReviewRectificationSource?]? = nil,
        refitOriginalSources: [ChekinanaReviewRectificationSource?]? = nil,
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
        let resolvedReviewRectificationSources = (
            reviewRectificationSources ?? Array(repeating: nil, count: images.count)
        ).map { source in
            source?.isValid == true ? source : nil
        }
        let resolvedRefitOriginalSources = refitOriginalSources ?? Array(repeating: nil, count: images.count)
        precondition(images.count == resolvedRefitOriginalSources.count)
        let resolvedDates = dates ?? Array(repeating: nil, count: images.count)
        let resolvedEventIDs = eventIDs ?? Array(repeating: nil, count: images.count)
        let resolvedEventAutoMatched = eventAutoMatched
            ?? Array(repeating: false, count: images.count)
        // Review always starts from a concrete Mini metadata value. Callers
        // may still omit the array (or contain legacy nil elements), but a new
        // temporary Cheki must never surface with an unknown size.
        let resolvedSizes = (
            sizes ?? Array(repeating: .mini, count: images.count)
        ).map { $0 ?? .mini }
        precondition(images.count == annotationStates.count)
        precondition(images.count == metadata.count)
        precondition(images.count == resolvedSourceAnnotations.count)
        precondition(images.count == resolvedReviewRectificationSources.count)
        precondition(images.count == resolvedDates.count)
        precondition(images.count == resolvedEventIDs.count)
        precondition(images.count == resolvedEventAutoMatched.count)
        precondition(images.count == resolvedSizes.count)
        let initialIDs = Set(temporaryChekis.keys)
        let initialBytes = temporaryChekiBytes
        let now = Date()
        var allocatedIDs = initialIDs
        let inserted = images.indices.map { index in
            let image = images[index]
            var id: UUID
            repeat { id = UUID() } while !allocatedIDs.insert(id).inserted
            return TemporaryCheki(
                id: id,
                image: image,
                thumbnailImageData: thumbnailImageData[index],
                reviewRectificationSource: resolvedReviewRectificationSources[index],
                refitOriginalSource: resolvedRefitOriginalSources[index],
                sourceID: image.sourceID,
                sourceOrigin: image.sourceOrigin,
                dateAnnotationState: annotationStates[index],
                sourceAnnotation: resolvedSourceAnnotations[index],
                imageRotationQuarterTurns: 0,
                transformFallbackSourceImage: image,
                transformSourceIsPublishedImage: true,
                transformSourceDateAnnotationState: annotationStates[index],
                desiredTransformSize: resolvedSizes[index],
                desiredTransformRotationQuarterTurns: 0,
                transformSourceVersion: 1,
                transformGeneration: 0,
                isTransformInFlight: false,
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
                createdAt: now
            )
        }
        let incomingBytes = temporaryStorageBytes(inserted)
        guard incomingBytes <= maximumTemporaryChekiBytes else {
            throw ChekinanaTemporaryChekiError.capacityExceeded(
                bytes: temporaryChekiBytes
            )
        }

        // Plan the complete batch against a snapshot before mutating anything.
        // A rejected batch must leave every existing temporary image intact.
        let protectedIDs = evictionProtectedTemporaryChekiIDs
        let removable = temporaryChekis.values.filter { !protectedIDs.contains($0.id) }
        let expired = removable.filter {
            now.timeIntervalSince($0.createdAt) >= temporaryChekiTTL
        }
        let evictionCandidates = removable
            .filter { now.timeIntervalSince($0.createdAt) < temporaryChekiTTL }
            .sorted { $0.createdAt < $1.createdAt }
        var evictionIDs = expired.map(\.id)
        let initiallyEvictedIDs = Set(evictionIDs)
        var plannedValues = temporaryChekis.values.filter {
            !initiallyEvictedIDs.contains($0.id)
        }
        var candidateIndex = 0
        while temporaryStorageBytes(plannedValues + inserted)
                > maximumTemporaryChekiBytes {
            guard candidateIndex < evictionCandidates.count else {
                assert(Set(temporaryChekis.keys) == initialIDs && temporaryChekiBytes == initialBytes)
                throw ChekinanaTemporaryChekiError.capacityExceeded(
                    bytes: temporaryChekiBytes
                )
            }
            let candidate = evictionCandidates[candidateIndex]
            evictionIDs.append(candidate.id)
            plannedValues.removeAll { $0.id == candidate.id }
            candidateIndex += 1
        }

        for id in evictionIDs {
            removeTemporaryChekiValue(id)
        }

        for value in inserted {
            temporaryChekis[value.id] = value
        }
        let plannedBytes = temporaryStorageBytes(plannedValues + inserted)
        assert(temporaryChekiBytes == plannedBytes)
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
        guard !value.isTransformInFlight, !value.isRefitFailed else {
            throw ChekinanaTemporaryChekiError.transformInProgress(rawToken)
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
            guard values.allSatisfy({ !$0.isTransformInFlight && !$0.isRefitFailed }) else {
                throw ChekinanaTemporaryChekiError.transformInProgress(selection)
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

    /// One expiry/protection pass for a single Review render snapshot.
    func temporaryChekiSnapshot(_ ids: [UUID]) -> [UUID: TemporaryCheki] {
        _ = pruneExpiredTemporaryChekis()
        var result: [UUID: TemporaryCheki] = [:]
        for id in ids { result[id] = temporaryChekis[id] }
        return result
    }

    func areTemporaryChekiTransformsSettled(_ ids: [UUID]) -> Bool {
        ids.allSatisfy { id in
            guard let value = temporaryChekis[id] else { return false }
            return !value.isTransformInFlight
                && !value.isRefitFailed
                && value.size == value.desiredTransformSize
                && value.imageRotationQuarterTurns
                    == value.desiredTransformRotationQuarterTurns
        }
    }

    /// Records the complete latest transform intent before any asynchronous
    /// rendering starts. A later request always builds from this desired state,
    /// never from whichever JPEG happened to finish last.
    func beginTemporaryChekiTransform(
        id: UUID,
        desiredSize: ChekiSize? = nil,
        counterclockwiseQuarterTurns: Int = 0
    ) -> TemporaryChekiTransformSnapshot? {
        guard !pendingTemporaryChekiIDs.contains(id),
              var value = temporaryChekis[id],
              !value.isRefitInFlight, !value.isRefitFailed else { return nil }
        let nextSize = desiredSize ?? value.desiredTransformSize
        let rotationRemainder = (
            value.desiredTransformRotationQuarterTurns
                + counterclockwiseQuarterTurns
        ) % 4
        let nextRotation = rotationRemainder >= 0
            ? rotationRemainder : rotationRemainder + 4
        guard nextSize != value.desiredTransformSize
                || nextRotation != value.desiredTransformRotationQuarterTurns
                || value.isTransformInFlight else {
            return nil
        }
        value.desiredTransformSize = nextSize
        value.desiredTransformRotationQuarterTurns = nextRotation
        value.transformGeneration &+= 1
        value.isTransformInFlight = true
        temporaryChekis[id] = value
        return TemporaryChekiTransformSnapshot(
            id: id,
            intent: TemporaryChekiTransformIntent(
                size: nextSize,
                rotationQuarterTurns: nextRotation,
                sourceVersion: value.transformSourceVersion,
                generation: value.transformGeneration
            ),
            sourceImage: value.transformFallbackSourceImage,
            reviewRectificationSource: value.reviewRectificationSource,
            sourceDateAnnotationState: value.transformSourceDateAnnotationState
        )
    }

    /// Invalidates outstanding work at lifecycle boundaries. The last fully
    /// published pixels/metadata remain authoritative and the desired state is
    /// rolled back to that same version.
    @discardableResult
    func invalidateTemporaryChekiTransform(id: UUID) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var value = temporaryChekis[id] else { return false }
        value.transformGeneration &+= 1
        value.transformSourceVersion &+= 1
        value.desiredTransformSize = value.size ?? .mini
        value.desiredTransformRotationQuarterTurns = value.imageRotationQuarterTurns
        value.isTransformInFlight = false
        value.isRefitInFlight = false
        temporaryChekis[id] = value
        return true
    }

    @discardableResult
    func failTemporaryChekiTransform(
        id: UUID,
        intent: TemporaryChekiTransformIntent
    ) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var value = temporaryChekis[id],
              value.transformGeneration == intent.generation,
              value.transformSourceVersion == intent.sourceVersion else {
            return false
        }
        value.desiredTransformSize = value.size ?? .mini
        value.desiredTransformRotationQuarterTurns = value.imageRotationQuarterTurns
        value.isTransformInFlight = false
        value.isRefitInFlight = false
        temporaryChekis[id] = value
        return true
    }

    /// The only transform publication point. Pixels, thumbnail, size, angle
    /// and normalized date-annotation geometry advance as one ledger mutation.
    func publishTemporaryChekiTransform(
        id: UUID,
        intent: TemporaryChekiTransformIntent,
        image: ChekinanaPendingChekiImage,
        thumbnailImageData: Data?,
        dateAnnotationState: ChekinanaChekiDateAnnotationState
    ) -> TemporaryChekiTransformPublication {
        guard !pendingTemporaryChekiIDs.contains(id),
              var value = temporaryChekis[id] else { return .unavailable }
        guard value.isTransformInFlight,
              !value.isRefitInFlight,
              value.transformGeneration == intent.generation,
              value.transformSourceVersion == intent.sourceVersion,
              value.desiredTransformSize == intent.size,
              value.desiredTransformRotationQuarterTurns
                == intent.rotationQuarterTurns else { return .stale }
        var replacement = value
        replacement.image = image
        replacement.transformSourceIsPublishedImage = false
        replacement.thumbnailImageData = thumbnailImageData
        replacement.size = intent.size
        replacement.imageRotationQuarterTurns = intent.rotationQuarterTurns
        replacement.dateAnnotationState = dateAnnotationState
        replacement.isTransformInFlight = false
        if value.size != intent.size {
            replacement.explicitlyEditedFields.insert(.size)
        }
        let replacementBytes = temporaryStorageBytes(replacing: id, with: replacement)
        guard replacementBytes <= maximumTemporaryChekiBytes else {
            value.desiredTransformSize = value.size ?? .mini
            value.desiredTransformRotationQuarterTurns = value.imageRotationQuarterTurns
            value.isTransformInFlight = false
            value.isRefitInFlight = false
            temporaryChekis[id] = value
            return .capacityExceeded
        }
        temporaryChekis[id] = replacement
        return .published
    }

    func beginTemporaryChekiRefit(id: UUID) -> TemporaryChekiTransformSnapshot? {
        guard !pendingTemporaryChekiIDs.contains(id),
              var value = temporaryChekis[id],
              !value.isTransformInFlight,
              !value.hasRefitUndo else { return nil }
        value.transformGeneration &+= 1
        value.isTransformInFlight = true
        value.isRefitInFlight = true
        temporaryChekis[id] = value
        return TemporaryChekiTransformSnapshot(
            id: id,
            intent: TemporaryChekiTransformIntent(
                size: value.size ?? .mini,
                rotationQuarterTurns: value.imageRotationQuarterTurns,
                sourceVersion: value.transformSourceVersion,
                generation: value.transformGeneration
            ),
            sourceImage: value.image,
            reviewRectificationSource: value.reviewRectificationSource ?? value.refitOriginalSource,
            sourceDateAnnotationState: value.dateAnnotationState
        )
    }

    func publishTemporaryChekiRefit(
        id: UUID,
        intent: TemporaryChekiTransformIntent,
        image: ChekinanaPendingChekiImage,
        thumbnailImageData: Data?,
        reviewSource: ChekinanaReviewRectificationSource,
        sourceAnnotation: ChekinanaScannerSourceAnnotation?,
        rotationQuarterTurns: Int = 0
    ) -> TemporaryChekiTransformPublication {
        guard !pendingTemporaryChekiIDs.contains(id),
              let value = temporaryChekis[id] else { return .unavailable }
        guard value.isRefitInFlight, value.isTransformInFlight,
              value.transformGeneration == intent.generation,
              value.transformSourceVersion == intent.sourceVersion else { return .stale }
        guard reviewSource.isValid,
              reviewSource.postprocessing == .perspectiveOnly else {
            _ = failTemporaryChekiTransform(id: id, intent: intent)
            return .unavailable
        }
        var replacement = value
        replacement.refitUndo = TemporaryChekiImageState(value)
        replacement.image = image
        replacement.thumbnailImageData = thumbnailImageData
        replacement.reviewRectificationSource = reviewSource
        replacement.transformFallbackSourceImage = image
        replacement.transformSourceIsPublishedImage = true
        replacement.sourceAnnotation = sourceAnnotation
        // Refit preserves the displayed date box at its original coordinates.
        // Subsequent transforms start from these same coordinates on the new image.
        replacement.dateAnnotationState = value.dateAnnotationState
        var unrotatedAnnotation = value.dateAnnotationState
        let normalizedTurns = ((rotationQuarterTurns % 4) + 4) % 4
        for _ in 0..<((4 - normalizedTurns) % 4) {
            unrotatedAnnotation = ChekinanaScanCleanImageRotation
                .counterclockwiseDateAnnotation(unrotatedAnnotation)
        }
        replacement.transformSourceDateAnnotationState = unrotatedAnnotation
        replacement.imageRotationQuarterTurns = rotationQuarterTurns
        replacement.desiredTransformRotationQuarterTurns = rotationQuarterTurns
        replacement.desiredTransformSize = value.size ?? .mini
        replacement.transformSourceVersion &+= 1
        replacement.transformGeneration &+= 1
        replacement.isTransformInFlight = false
        replacement.isRefitInFlight = false
        guard temporaryStorageBytes(replacing: id, with: replacement)
                <= maximumTemporaryChekiBytes else {
            _ = failTemporaryChekiTransform(id: id, intent: intent)
            return .capacityExceeded
        }
        temporaryChekis[id] = replacement
        return .published
    }

    /// Two non-unique detections never replace pixels or allocate another
    /// copy. The user must undo the failure presentation before saving.
    func publishTemporaryChekiRefitFailure(
        id: UUID,
        intent: TemporaryChekiTransformIntent
    ) -> TemporaryChekiTransformPublication {
        guard !pendingTemporaryChekiIDs.contains(id),
              var value = temporaryChekis[id] else { return .unavailable }
        guard value.isRefitInFlight, value.isTransformInFlight,
              value.transformGeneration == intent.generation,
              value.transformSourceVersion == intent.sourceVersion else { return .stale }
        value.isRefitFailed = true
        value.isRefitInFlight = false
        value.isTransformInFlight = false
        value.desiredTransformSize = value.size ?? .mini
        value.desiredTransformRotationQuarterTurns = value.imageRotationQuarterTurns
        value.transformSourceVersion &+= 1
        value.transformGeneration &+= 1
        temporaryChekis[id] = value
        return .published
    }

    @discardableResult
    func undoTemporaryChekiRefit(id: UUID) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var value = temporaryChekis[id],
              !value.isTransformInFlight else { return false }
        if value.isRefitFailed {
            value.isRefitFailed = false
            value.transformSourceVersion &+= 1
            value.transformGeneration &+= 1
            temporaryChekis[id] = value
            return true
        }
        guard let previous = value.refitUndo else { return false }
        value.image = previous.image
        value.thumbnailImageData = previous.thumbnailImageData
        value.reviewRectificationSource = previous.reviewRectificationSource
        value.dateAnnotationState = previous.dateAnnotationState
        value.sourceAnnotation = previous.sourceAnnotation
        value.imageRotationQuarterTurns = previous.imageRotationQuarterTurns
        value.transformFallbackSourceImage = previous.transformFallbackSourceImage
        value.transformSourceIsPublishedImage = previous.transformSourceIsPublishedImage
        value.transformSourceDateAnnotationState = previous.transformSourceDateAnnotationState
        value.size = previous.size
        value.desiredTransformSize = previous.size ?? .mini
        value.desiredTransformRotationQuarterTurns = previous.imageRotationQuarterTurns
        if previous.sizeWasExplicitlyEdited {
            value.explicitlyEditedFields.insert(.size)
        } else {
            value.explicitlyEditedFields.remove(.size)
        }
        value.transformSourceVersion &+= 1
        value.transformGeneration &+= 1
        value.isTransformInFlight = false
        value.isRefitInFlight = false
        value.refitUndo = nil
        temporaryChekis[id] = value
        return true
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

    /// Applies an explicit Review Event choice as one ledger mutation. A
    /// non-empty choice also fills otherwise-empty sibling cards from the same
    /// canonical day and complete Idol combination. Existing Event choices and
    /// cards that are pending confirmation or image transformation are left
    /// untouched.
    func updateTemporaryChekiEventAndMatchingBlanks(
        id: UUID,
        eventID: UUID?,
        allowedIDs: Set<UUID>
    ) -> [UUID]? {
        guard allowedIDs.contains(id),
              let source = temporaryChekis[id],
              !pendingTemporaryChekiIDs.contains(id),
              !source.isTransformInFlight else {
            return nil
        }

        let sourceIdolIDs = Set(source.idolIDs)
        let sourceDate = source.date.flatMap(ChekinanaDateOnly.canonicalized)
        var affected = [source.id]
        if eventID != nil {
            let siblings = temporaryChekis.values.filter { candidate in
                candidate.id != source.id
                    && allowedIDs.contains(candidate.id)
                    && !pendingTemporaryChekiIDs.contains(candidate.id)
                    && !candidate.isTransformInFlight
                    && candidate.eventID == nil
                    && !candidate.explicitlyEditedFields.contains(.event)
                    && Set(candidate.idolIDs) == sourceIdolIDs
                    && candidate.date.flatMap(ChekinanaDateOnly.canonicalized)
                        == sourceDate
            }.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            affected.append(contentsOf: siblings.map(\.id))
        }

        // Every target was resolved from the same actor-isolated snapshot, so
        // no mutation occurs until the complete update set has been validated.
        guard affected.allSatisfy({ targetID in
            temporaryChekis[targetID] != nil
                && !pendingTemporaryChekiIDs.contains(targetID)
                && temporaryChekis[targetID]?.isTransformInFlight == false
        }) else {
            return nil
        }
        var replacements: [UUID: TemporaryCheki] = [:]
        for targetID in affected {
            guard var target = temporaryChekis[targetID] else { return nil }
            target.eventID = eventID
            target.eventWasAutoMatched = false
            target.explicitlyEditedFields.insert(.event)
            replacements[targetID] = target
        }
        guard replacements.count == affected.count else { return nil }
        for (targetID, replacement) in replacements {
            temporaryChekis[targetID] = replacement
        }
        return affected
    }

    @discardableResult
    func updateTemporaryChekiSize(id: UUID, size: ChekiSize?) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var temporary = temporaryChekis[id] else {
            return false
        }
        temporary.size = size
        temporary.desiredTransformSize = size ?? .mini
        temporary.isTransformInFlight = false
        temporary.explicitlyEditedFields.insert(.size)
        temporaryChekis[id] = temporary
        return true
    }

    /// Publishes a Review size change only after its source + quadrilateral
    /// preview has finished rendering. Metadata and pixels change together,
    /// while a concurrent rotation makes the stale render ineligible.
    @discardableResult
    func replaceTemporaryChekiSizePreview(
        id: UUID,
        size: ChekiSize,
        image: ChekinanaPendingChekiImage,
        thumbnailImageData: Data?,
        expectedRotationQuarterTurns: Int
    ) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id),
              var temporary = temporaryChekis[id],
              temporary.imageRotationQuarterTurns == expectedRotationQuarterTurns else {
            return false
        }
        var replacement = temporary
        replacement.size = size
        replacement.image = image
        replacement.transformSourceIsPublishedImage = false
        replacement.thumbnailImageData = thumbnailImageData
        replacement.desiredTransformSize = size
        replacement.desiredTransformRotationQuarterTurns = expectedRotationQuarterTurns
        replacement.isTransformInFlight = false
        replacement.explicitlyEditedFields.insert(.size)
        let replacementBytes = temporaryStorageBytes(replacing: id, with: replacement)
        guard replacementBytes <= maximumTemporaryChekiBytes else { return false }
        temporary = replacement
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
              let value = temporaryChekis[id] else { return false }
        var replacement = value
        replacement.image = image
        replacement.transformSourceIsPublishedImage = false
        replacement.thumbnailImageData = thumbnailImageData
        replacement.dateAnnotationState = dateAnnotationState
        replacement.imageRotationQuarterTurns = (replacement.imageRotationQuarterTurns + 1) % 4
        replacement.desiredTransformSize = replacement.size ?? .mini
        replacement.desiredTransformRotationQuarterTurns = replacement.imageRotationQuarterTurns
        replacement.isTransformInFlight = false
        let replacementBytes = temporaryStorageBytes(replacing: id, with: replacement)
        guard replacementBytes <= maximumTemporaryChekiBytes else { return false }
        temporaryChekis[id] = replacement
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
        else { temporary.explicitlyEditedFields.remove(.idx) }
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
    func reconcileScanReviewRecord(id: UUID, recordID: UUID?, eventID: UUID?, note: String?, snapshot: ChekinanaChekiRecordSnapshot? = nil) -> Bool {
        guard !pendingTemporaryChekiIDs.contains(id), var temporary = temporaryChekis[id] else { return false }
        let hadInheritance = temporary.hasScanReviewRecordInheritance
        temporary.existingChekiID = recordID
        temporary.existingSelectionIsManual = false
        if recordID != nil || hadInheritance {
            if !temporary.explicitlyEditedFields.contains(.event) {
                temporary.eventID = recordID == nil ? nil : eventID
                temporary.eventWasAutoMatched = false
            }
            if !temporary.explicitlyEditedFields.contains(.note) {
                temporary.note = recordID == nil ? "" : (note ?? "")
            }
        }
        temporary.hasScanReviewRecordInheritance = recordID != nil
        temporary.scanReviewRecordSnapshot = snapshot
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
        temporaryStorageBytes(Array(temporaryChekis.values))
    }

    var temporaryStorageByteCount: Int { temporaryChekiBytes }
    var temporaryStorageCapacityBytes: Int { maximumTemporaryChekiBytes }

    private func temporaryStorageBytes(
        replacing id: UUID,
        with replacement: TemporaryCheki
    ) -> Int {
        temporaryStorageBytes(
            temporaryChekis.values.map { $0.id == id ? replacement : $0 }
        )
    }

    /// Counts the immutable source image once per explicit shared identity,
    /// regardless of how many quadrilaterals from that input are in Review.
    /// Saturating arithmetic keeps malformed/oversized batches rejectable.
    private func temporaryStorageBytes(_ values: [TemporaryCheki]) -> Int {
        var total = 0
        var countedSourceIdentities = Set<UUID>()
        func add(_ bytes: Int) {
            guard total != Int.max else { return }
            let result = total.addingReportingOverflow(bytes)
            total = result.overflow ? Int.max : result.partialValue
        }
        for value in values {
            add(value.image.data.count)
            if !value.transformSourceIsPublishedImage {
                add(value.transformFallbackSourceImage.data.count)
            }
            if let previous = value.refitUndo {
                add(previous.image.data.count)
                add(previous.thumbnailImageData?.count ?? 0)
                if !previous.transformSourceIsPublishedImage {
                    add(previous.transformFallbackSourceImage.data.count)
                }
                if let source = previous.reviewRectificationSource,
                   countedSourceIdentities.insert(source.sourceIdentity).inserted {
                    add(source.imageData.count)
                }
            }
            if let source = value.refitOriginalSource,
               countedSourceIdentities.insert(source.sourceIdentity).inserted {
                add(source.imageData.count)
            }
            if let source = value.reviewRectificationSource,
               countedSourceIdentities.insert(source.sourceIdentity).inserted {
                add(source.imageData.count)
            }
        }
        return total
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
    static let defaultLimit = 16

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int = defaultLimit) {
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

private final class ChekinanaScannerResultPublicationState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func recordPublication() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var hasPublishedResults: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }
}

@MainActor
enum ChekinanaScannerRouter {
    typealias DirectProcess = (
        ChekinanaPendingChekiImage,
        ChekinanaScannerOptions
    ) async throws -> ChekinanaScannerProcessResult
    typealias RemoteProcess = (
        ChekinanaPendingChekiImage,
        ChekinanaScannerOptions,
        ChekinanaCommandExecutor.ScannerStatusObserver?,
        ChekinanaCommandExecutor.ScannerResultObserver?,
        ChekinanaCommandExecutor.ScannerTaskObserver?
    ) async throws -> ChekinanaScannerProcessResult
    typealias LocalProcess = (
        ChekinanaPendingChekiImage,
        ChekinanaScannerOptions,
        ChekinanaCommandExecutor.ScannerStatusObserver?,
        ChekinanaCommandExecutor.ScannerResultObserver?
    ) async throws -> ChekinanaScannerProcessResult

    struct Processes {
        let direct: DirectProcess
        let remote: RemoteProcess
        let local: LocalProcess
    }

    static func process(
        _ image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions,
        usesLocalDirectProcessing: Bool,
        usesRemoteScanner: Bool,
        progressObserver: ChekinanaCommandExecutor.ScannerStatusObserver?,
        resultObserver: ChekinanaCommandExecutor.ScannerResultObserver?,
        taskIDObserver: ChekinanaCommandExecutor.ScannerTaskObserver?
    ) async throws -> ChekinanaScannerProcessResult {
        try await process(
            image,
            options: options,
            usesLocalDirectProcessing: usesLocalDirectProcessing,
            usesRemoteScanner: usesRemoteScanner,
            progressObserver: progressObserver,
            resultObserver: resultObserver,
            taskIDObserver: taskIDObserver,
            processes: liveProcesses()
        )
    }

    static func process(
        _ image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions,
        usesLocalDirectProcessing: Bool,
        usesRemoteScanner: Bool,
        progressObserver: ChekinanaCommandExecutor.ScannerStatusObserver?,
        resultObserver: ChekinanaCommandExecutor.ScannerResultObserver?,
        taskIDObserver: ChekinanaCommandExecutor.ScannerTaskObserver?,
        processes: Processes
    ) async throws -> ChekinanaScannerProcessResult {
        if usesLocalDirectProcessing && options.directInputEnabled {
            return try await processes.direct(image, options)
        }
        if usesRemoteScanner {
            let publicationState = ChekinanaScannerResultPublicationState()
            let forwardingObserver: ChekinanaCommandExecutor.ScannerResultObserver?
            if let resultObserver {
                forwardingObserver = { resultIndex, resultImage in
                    publicationState.recordPublication()
                    resultObserver(resultIndex, resultImage)
                }
            } else {
                forwardingObserver = nil
            }
            do {
                let result = try await processes.remote(
                    image,
                    options,
                    progressObserver,
                    forwardingObserver,
                    taskIDObserver
                )
                return result
            } catch {
                if Task.isCancelled || error is CancellationError
                    || publicationState.hasPublishedResults {
                    throw error
                }
            }
        }
        return try await processes.local(image, options, progressObserver, resultObserver)
    }

    private static func liveProcesses() -> Processes {
        Processes(
            direct: { image, options in
                try await ChekinanaLocalImportChekiProcessor.process(
                    image,
                    options: options
                )
            },
            remote: { image, options, progressObserver, resultObserver, taskIDObserver in
                try await ChekinanaScannerClient().process(
                    image,
                    options: options,
                    progressObserver: progressObserver,
                    resultObserver: resultObserver,
                    taskIDObserver: taskIDObserver
                )
            },
            local: { image, options, progressObserver, resultObserver in
                try await ChekinanaOnDeviceScannerClient().process(
                    image,
                    options: options,
                    progressObserver: progressObserver,
                    resultObserver: resultObserver
                )
            }
        )
    }
}

enum ChekinanaTemporaryChekiBatchStage: String, Sendable {
    case preparingImages
    case savingRecords
    case finalizing

    var title: String {
        switch self {
        case .preparingImages:
            ChekinanaProductCopy.text("scan.review.stage.preparing_images", "Preparing images")
        case .savingRecords:
            ChekinanaProductCopy.text("scan.review.stage.saving_records", "Saving records")
        case .finalizing:
            ChekinanaProductCopy.text("scan.review.stage.finalizing", "Finalizing")
        }
    }
}

struct ChekinanaTemporaryChekiBatchProgress: Equatable, Sendable {
    let stage: ChekinanaTemporaryChekiBatchStage
    let completed: Int
    let total: Int
}

private struct ChekinanaBatchChekiSnapshot: Sendable {
    let size: ChekiSize?
    let id: UUID
    let idolIDs: [UUID]
    let date: Date?
    let idx: Int?
    let isFavorite: Bool
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
        try modelContext.fetch(FetchDescriptor<MediaItem>()).filter {
            $0.kind == .cheki
        }.map { cheki in
            ChekinanaBatchChekiSnapshot(
                size: cheki.size,
                id: cheki.id,
                idolIDs: cheki.idolIDs,
                date: cheki.date,
                idx: cheki.idx,
                isFavorite: cheki.isFavorite,
                imageRef: cheki.imageRef
            )
        }
    }
}

@MainActor
enum ChekinanaStreamingScanScheduler {
    static let maximumConcurrentSourceProcessing = 2

    /// A source holds its image slot only until image processing finishes.
    /// Recognition/ordered publication continue in tracked tasks, all drained
    /// before returning so their staged files remain alive through cancellation.
    static func runOverlappingRecognition(
        sourceCount: Int,
        operation: @escaping @MainActor @Sendable (
            Int, @escaping @MainActor @Sendable () -> Void
        ) async -> Void
    ) async {
        let registry = SourceTasks()
        await withTaskCancellationHandler {
            let tasks = await run(sourceCount: sourceCount) { index in
                let phase = ImagePhase()
                let task = Task { @MainActor in
                    defer { phase.finish() }
                    guard !Task.isCancelled else { return }
                    await operation(index, { phase.finish() })
                }
                registry.insert(task)
                await phase.wait()
                return task
            }
            for task in tasks { await task.value }
        } onCancel: {
            Task { @MainActor in registry.cancelAll() }
        }
    }

    @MainActor
    private final class ImagePhase {
        private var finished = false
        private var waiter: CheckedContinuation<Void, Never>?

        func finish() {
            guard !finished else { return }
            finished = true
            waiter?.resume()
            waiter = nil
        }

        func wait() async {
            guard !finished else { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    @MainActor
    private final class SourceTasks {
        private var tasks: [Task<Void, Never>] = []
        private var isCancelled = false

        func insert(_ task: Task<Void, Never>) {
            tasks.append(task)
            if isCancelled { task.cancel() }
        }

        func cancelAll() {
            isCancelled = true
            tasks.forEach { $0.cancel() }
        }
    }

    static func run<Output: Sendable>(
        sourceCount: Int,
        limit: Int = maximumConcurrentSourceProcessing,
        operation: @escaping @MainActor @Sendable (Int) async -> Output
    ) async -> [Output] {
        precondition(sourceCount >= 0)
        precondition(limit > 0)
        guard sourceCount > 0 else { return [] }

        return await withTaskGroup(of: (Int, Output).self) { group in
            var ordered = Array<Output?>(repeating: nil, count: sourceCount)
            let initialWorkerCount = min(limit, sourceCount)
            var nextSourceIndex = initialWorkerCount

            for sourceIndex in 0..<initialWorkerCount {
                group.addTask {
                    (sourceIndex, await operation(sourceIndex))
                }
            }

            while let (sourceIndex, output) = await group.next() {
                ordered[sourceIndex] = output
                if Task.isCancelled {
                    group.cancelAll()
                } else if nextSourceIndex < sourceCount {
                    let queuedSourceIndex = nextSourceIndex
                    nextSourceIndex += 1
                    group.addTask {
                        (queuedSourceIndex, await operation(queuedSourceIndex))
                    }
                }
            }
            return ordered.compactMap { $0 }
        }
    }
}

/// Session-local opt-out. Freezes every result before cancelling any request;
/// this never cancels image processing, body-pose detection, or ledger commit.
@MainActor
final class ChekinanaScanRecognitionSkipControl {
    typealias Cancellation = @MainActor () -> Void
    private var registrations: [UUID: @MainActor () -> [Cancellation]] = [:]
    private(set) var didSkip = false

    func register(_ freeze: @escaping @MainActor () -> [Cancellation]) -> UUID {
        let id = UUID()
        if didSkip {
            freeze().forEach { $0() }
        } else {
            registrations[id] = freeze
        }
        return id
    }

    func unregister(_ id: UUID) { registrations[id] = nil }

    func skipRemainingRecognition() {
        guard !didSkip else { return }
        didSkip = true
        let callbacks = Array(registrations.values)
        registrations.removeAll()
        let cancellations = callbacks.flatMap { $0() }
        cancellations.forEach { $0() }
    }
}

/// A result may become consumable before cancelled OCR/Idol tasks drain. Its
/// scalar metadata freezes exactly once, so late results never touch Review.
@MainActor
final class ChekinanaScanRecognitionWork<Value: Sendable> {
    enum Component: CaseIterable { case date, idol, userAppears }
    private var pending = Set(Component.allCases)
    private var result: Value
    private var cancellations: [Component: ChekinanaScanRecognitionSkipControl.Cancellation] = [:]
    private var waiters: [CheckedContinuation<Value, Never>] = []

    init(_ initial: Value) { result = initial }
    var snapshot: Value { result }

    func isPending(_ component: Component) -> Bool { pending.contains(component) }

    func installCancellation(
        for component: Component,
        _ cancel: @escaping ChekinanaScanRecognitionSkipControl.Cancellation
    ) {
        if pending.contains(component) { cancellations[component] = cancel }
        else { cancel() }
    }

    @discardableResult
    func complete(_ component: Component, update: (inout Value) -> Void) -> Bool {
        guard pending.remove(component) != nil else { return false }
        cancellations[component] = nil
        update(&result)
        resumeIfComplete()
        return true
    }

    func freezeAutomaticRecognition() -> [ChekinanaScanRecognitionSkipControl.Cancellation] {
        var actions: [ChekinanaScanRecognitionSkipControl.Cancellation] = []
        for component in [Component.date, .idol] where pending.remove(component) != nil {
            if let cancel = cancellations.removeValue(forKey: component) { actions.append(cancel) }
        }
        resumeIfComplete()
        return actions
    }

    func cancel(update: (inout Value) -> Void) {
        guard !pending.isEmpty else { return }
        pending.removeAll()
        update(&result)
        let actions = Array(cancellations.values)
        cancellations.removeAll()
        resumeIfComplete()
        actions.forEach { $0() }
    }

    var value: Value {
        get async {
            if pending.isEmpty { return result }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func resumeIfComplete() {
        guard pending.isEmpty else { return }
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume(returning: result) }
    }
}

@MainActor
struct ChekinanaCommandExecutor {
    var assistantDialogue: ChekinanaAssistantDialogue? = nil
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
    typealias PendingImageLoader = @MainActor @Sendable (
        _ sourceIndex: Int
    ) async throws -> ChekinanaPendingChekiImage
    typealias ScannerTaskObserver = @MainActor (_ taskID: String, _ isActive: Bool) -> Void
    typealias PatternEncode = (Data) async throws -> [Float]
    typealias PatternResolve = @Sendable ([String]) async throws -> [[Float]]
    typealias UserAppearsDetect = @Sendable (Data) async throws -> Bool
    typealias DateAnnotate = @Sendable (
        ChekinanaPendingChekiImage
    ) async throws -> ChekinanaChekiDateAnnotationState
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
        var dateState: ChekinanaChekiDateAnnotationState
        var matchedIdolID: UUID?
        var userAppears: Bool?
        var warningCount: Int
        var isCancelled: Bool
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
        case success(
            ChekinanaScannerProcessResult,
            sourceID: UUID?,
            sourceOrigin: ChekinanaScanSourceOrigin
        )
        case failed
        case cancelled
    }

    let modelContext: ModelContext
    let confirmationLedger: ChekinanaConfirmationLedger
    private let scanTightBoundaries: Bool?
    private let scannerProcessWithProgress: ScannerProcessWithProgress
    private let scanProgressObserver: ScanProgressObserver?
    private let recognitionSkipControl: ChekinanaScanRecognitionSkipControl?
    private let patternEncode: PatternEncode
    private let patternResolve: PatternResolve
    private let userAppearsDetect: UserAppearsDetect
    private let dateAnnotate: DateAnnotate
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
        patternResolve: PatternResolve? = nil,
        userAppearsDetect: UserAppearsDetect? = nil,
        dateAnnotate: DateAnnotate? = nil,
        bodyPoseLimiter: ChekinanaBodyPoseLimiter = .init(),
        idolSearch: @escaping IdolSearch = { name in
            try await ChekinanaIdolEnrichmentClient().search(for: name)
        },
        idolAvatarPrepare: IdolAvatarPrepare? = nil,
        idolAvatarBatchTimeoutNanoseconds: UInt64 = 15_000_000_000,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        scanProgressObserver: ScanProgressObserver? = nil,
        recognitionSkipControl: ChekinanaScanRecognitionSkipControl? = nil,
        scannerTaskObserver: ScannerTaskObserver? = nil,
        directRecognitionGate: ChekinanaDirectRecognitionGate? = nil,
        directDateRequestGate: ChekinanaDirectDateRequestGate? = nil,
        directCommitGate: ChekinanaDirectCommitGate? = nil,
        directCommitIndex: Int? = nil,
        batchImagePreparationLimiter: ChekinanaRemoteRequestLimiter = .init(limit: 4),
        batchSaveProgressObserver: BatchSaveProgressObserver? = nil,
        simulateBatchFinalizeInvariantFailure: Bool = false,
        batchBeforeLiveIndexValidation: BatchBeforeLiveIndexValidation? = nil,
        usesLocalDirectProcessing: Bool = false,
        usesRemoteScanner: Bool = false,
        scanTightBoundaries: Bool? = nil
    ) {
        self.scanTightBoundaries = scanTightBoundaries
        self.modelContext = modelContext
        self.confirmationLedger = confirmationLedger
        if let scannerProcess {
            scannerProcessWithProgress = { image, options, _, _ in
                try await scannerProcess(image, options)
            }
        } else {
            scannerProcessWithProgress = { image, options, progressObserver, resultObserver in
                try await ChekinanaScannerRouter.process(
                    image,
                    options: options,
                    usesLocalDirectProcessing: usesLocalDirectProcessing,
                    usesRemoteScanner: usesRemoteScanner,
                    progressObserver: progressObserver,
                    resultObserver: resultObserver,
                    taskIDObserver: scannerTaskObserver
                )
            }
        }
        self.scanProgressObserver = scanProgressObserver
        self.recognitionSkipControl = recognitionSkipControl
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
        self.patternResolve = patternResolve ?? { patternIDs in
            try await ChekinanaRemotePatternResources.shared.patterns(
                for: patternIDs
            )
        }
        self.userAppearsDetect = userAppearsDetect ?? { imageData in
            try await ChekinanaHumanBodyPoseDetector.detect(in: imageData)
        }
        self.dateAnnotate = dateAnnotate ?? { image in
            try await ChekinanaDirectDateAnnotationClient().annotate(image)
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

    /// Executes one app-created Scan session while loading and processing only
    /// a bounded number of full-resolution sources at a time. Recognition is
    /// started by each scanner result observer and is deliberately not part of
    /// the source-processing permit.
    func executeStreamingScan(
        _ input: String,
        sourceCount: Int,
        maximumConcurrentSourceProcessing: Int =
            ChekinanaStreamingScanScheduler.maximumConcurrentSourceProcessing,
        load: @escaping PendingImageLoader
    ) async -> ChekinanaCommandResponse {
        let command: ChekinanaParsedCommand
        do {
            command = try ChekinanaCommandParser.parse(input)
        } catch {
            return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription))
        }
        guard command.name == "scancheki",
              let usage = commandUsages[command.name] else {
            return invalidUsage(commandUsages["scancheki"] ?? ["scancheki"])
        }
        return await scanCheki(
            command,
            usage: usage,
            sourceCount: sourceCount,
            maximumConcurrentSourceProcessing: maximumConcurrentSourceProcessing,
            loadPendingImage: load
        )
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

        if command.name == "statscheki" || assistantDialogue != nil {
            do {
                if let reply = try ChekinanaAssistantLibrary.read(command, in: modelContext, dialogue: assistantDialogue ?? ChekinanaAssistantDialogue()) {
                    return .text(reply)
                }
            } catch { return .text(ChekinanaCommandCopy.errorDetail(error.localizedDescription)) }
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
            return await editCheki(command, usage: usage)
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
            openTime: ChekinanaEventTime.normalized(rawFields.openTime),
            startTime: ChekinanaEventTime.normalized(rawFields.startTime),
            note: rawFields.note.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if !fields.weiboURL.isEmpty,
               ChekinanaEventSource.validatedURL(from: fields.weiboURL) == nil {
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
                openTime: fields.openTime,
                startTime: fields.startTime,
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
                    let result = try ChekinanaLibraryMutationProtocol
                        .withExclusiveOperationSync {
                            try ChekinanaLibraryMutationPreflight.requireImportConvergedExclusively(in: modelContext)
                            return try ChekinanaPersistenceMutationCoordinator.withLock {
                                let libraryGeneration = try ChekinanaLibraryGenerationStore
                                    .ensureCurrent(in: modelContext)
                                _ = try ChekinanaIdolAvatarStatePersistence.record(
                                    idolID: idol.id,
                                    source: .none,
                                    intent: .explicitlyRemoved,
                                    in: modelContext
                                )
                                return try ChekinanaIdolPersistence.save(
                                    idol,
                                    inserting: false,
                                    previousAvatarRef: previousAvatarRef,
                                    stagedAvatar: nil,
                                    in: modelContext,
                                    libraryGeneration: libraryGeneration
                                ) { target in
                                    applyIdolEdit(
                                        payload.values,
                                        clearFields: payload.clearFields,
                                        to: target
                                    )
                                    target.updatedAt = Date()
                                }
                            }
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
                    do {
                        try ChekinanaPersistenceMutationCoordinator.withLock {
                            applyIdolEdit(
                                payload.values,
                                clearFields: payload.clearFields,
                                to: idol
                            )
                            if payload.values["avatar"] != nil {
                                _ = try ChekinanaIdolAvatarStatePersistence.record(
                                    idolID: idol.id,
                                    source: .custom,
                                    intent: .userSelected,
                                    in: modelContext
                                )
                            }
                            idol.updatedAt = Date()
                            try modelContext.save()
                        }
                    } catch {
                        modelContext.rollback()
                        throw error
                    }
                    response = .idolCard(idolCard(idol))
                }

            case .deleteIdol(let payload):
                let idol: Idol
                do { idol = try refetchIdolByID(payload.idolID) }
                catch { throw ChekinanaIdolCascadeError.changedAssociations }
                guard idol.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaNLClientError.invalidSchema
                }
                let result = try ChekinanaIdolPersistence.delete(
                    idol,
                    from: modelContext,
                    cascadeAuthorization: payload.cascadeAuthorization
                )
                response = .text(result.pendingAssociatedMediaCleanup || result.pendingAvatarCleanup != nil
                    ? ChekinanaCommandCopy.text("idol.deleted_cleanup_pending",
                        fallback: "Deleted the selected Idols and exclusive records; shared records were kept and unlinked. Some media cleanup is pending and will be retried safely.")
                    : ChekinanaCommandCopy.text("idol.deleted_batch",
                        fallback: "Deleted the selected Idols. Shared records and their media were kept and unlinked."))

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
                let validatedSocialLink = payload.weiboURL.flatMap {
                    ChekinanaEventSource.validatedURL(from: $0.absoluteString)
                }
                if payload.weiboURL != nil, validatedSocialLink == nil {
                    throw ChekinanaEventError.invalidURL
                }
                try ensureEventIsNotDuplicate(
                    name: payload.name,
                    date: payload.date,
                    url: payload.weiboURL
                )
                guard let expectedGeneration = ChekinanaEventTravelMediaOwnership
                    .currentGeneration(in: modelContext) else {
                    throw ChekinanaEventTravelMediaOwnership
                        .SaveAuthorizationError.generationChanged
                }
                let mediaOwnerID = UUID()
                ChekinanaEventTravelMediaOwnership.beginSaveTask(
                    ownerID: mediaOwnerID,
                    generation: expectedGeneration,
                    references: []
                )
                let event = Event(
                    name: payload.name,
                    date: payload.date,
                    city: payload.city.map(ChekinanaEventCity.normalized),
                    livehouse: payload.livehouse,
                    price: payload.price,
                    weiboURL: payload.weiboURL,
                    ticketURL: payload.ticketURL,
                    note: payload.note
                )
                do {
                    if let avatarURL = payload.avatarURL {
                        event.avatarImageRef = try await ChekinanaEventAvatarStore.downloadAndSave(
                            avatarURL,
                            eventID: event.id,
                            ownerID: mediaOwnerID,
                            generation: expectedGeneration
                        )
                    }
                    try Task.checkCancellation()
                    let mediaOwnerReferences = [event.avatarImageRef].compactMap { $0 }
                    try ChekinanaEventTravelMediaOwnership.validateSaveAuthorization(
                        ownerID: mediaOwnerID,
                        expectedGeneration: expectedGeneration,
                        ownedReferences: mediaOwnerReferences,
                        in: modelContext
                    )
                    try ChekinanaEventPersistence.save(
                        event,
                        inserting: true,
                        images: [],
                        schedule: ChekinanaEventScheduleValue(
                            openTime: payload.openTime,
                            startTime: payload.startTime
                        ),
                        source: validatedSocialLink?.source,
                        previousAvatarRef: nil,
                        in: modelContext,
                        validateManagedFiles: true,
                        expectedGeneration: expectedGeneration,
                        mediaOwnerID: mediaOwnerID,
                        mediaOwnerReferences: mediaOwnerReferences
                    )
                } catch {
                    ChekinanaEventAvatarStore.remove(event.avatarImageRef)
                    ChekinanaEventTravelMediaOwnership.release(ownerID: mediaOwnerID)
                    throw error
                }
                response = .eventCard(eventCard(event))

            case .editEvent(let payload):
                let event = try refetchEventByRequiredID(payload.eventID)
                guard event.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaEditConflictError.staleEvent(entry.code)
                }
                let updatedEvent: Event
                do {
                    let validatedSocialLink = payload.weiboURL.flatMap {
                        ChekinanaEventSource.validatedURL(from: $0.absoluteString)
                    }
                    if payload.weiboURL != nil, validatedSocialLink == nil {
                        throw ChekinanaEventError.invalidURL
                    }
                    updatedEvent = try ChekinanaEventPersistence.update(
                        eventID: event.id,
                        expectedUpdatedAt: payload.expectedUpdatedAt,
                        schedule: ChekinanaEventScheduleValue(
                            openTime: payload.openTime,
                            startTime: payload.startTime
                        ),
                        sourceUpdate: .some(validatedSocialLink?.source),
                        in: modelContext
                    ) { liveEvent in
                        liveEvent.name = payload.name
                        liveEvent.date = payload.date
                        liveEvent.city = payload.city.map(ChekinanaEventCity.normalized)
                        liveEvent.livehouse = payload.livehouse
                        liveEvent.price = payload.price
                        liveEvent.weiboURL = payload.weiboURL
                        liveEvent.ticketURL = payload.ticketURL
                        liveEvent.note = payload.note
                        liveEvent.updatedAt = Date()
                    }
                } catch is ChekinanaEventMutationError {
                    throw ChekinanaEditConflictError.staleEvent(entry.code)
                } catch {
                    throw error
                }
                response = .eventCard(eventCard(updatedEvent))

            case .deleteEvent(let payload):
                let event = try refetchEventByRequiredID(payload.eventID)
                guard event.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaNLClientError.invalidSchema
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
                    .map { try refetchChekiRecordByID($0) }?.event
                let event: Event?
                if explicitEvent {
                    event = try refetchEventByID(payload.eventID)
                } else {
                    let eligibleExistingEvent = existingEvent.flatMap { candidate in
                        ChekinanaChekiEventSelectionPolicy.includes(
                            recordDate: payload.date,
                            eventDate: candidate.date
                        ) ? candidate : nil
                    }
                    if let eligibleExistingEvent {
                        event = eligibleExistingEvent
                    } else {
                        event = try uniqueEvent(for: payload.date)
                    }
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

                        idx = try nextChekiIndex(
                            idolIDs: idols.map(\.id),
                            eventID: event?.id,
                            eventDate: payload.date,
                            isFavorite: payload.isFavorite,
                            excludingChekiID: nil
                        )

                    response = try await persistCheki(
                        id: payload.id,
                        image: payload.image,
                        thumbnailImageData: payload.thumbnailImageData,
                        reviewRectificationSource: payload.reviewRectificationSource,
                        reviewRotationQuarterTurns: payload.reviewRotationQuarterTurns,
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
                guard payload.authorization.record.id == payload.chekiID,
                      payload.authorization.record.updatedAt
                        == payload.expectedUpdatedAt else {
                    throw ChekinanaEditConflictError.staleCheki(entry.code)
                }
                let originalImageRef = payload.authorization.record.mediaRef
                let effectiveSize = payload.size ?? .mini
                var imageReplacement: ChekinanaChekiImageReplacementTransaction?
                if payload.explicitlyEditedFields.contains(.size),
                   effectiveSize.rawValue != payload.authorization.record.sizeRawValue {
                    imageReplacement = try await ChekinanaChekiImageReplacementTransaction
                        .stage(
                            currentImageRef: payload.authorization.record.mediaRef,
                            mediaOwnerID: payload.authorization.record.mediaOwnerID,
                            size: effectiveSize
                        )
                }
                let cheki = try await ChekinanaChekiEditCommitter.commit(
                    authorization: payload.authorization,
                    imageReplacement: imageReplacement,
                    in: modelContext
                ) { target in
                    let edited = payload.explicitlyEditedFields
                    let targetIdolIDs = edited.contains(.idols)
                        ? payload.idolIDs : target.idolIDs
                    let targetEventID = edited.contains(.event)
                        ? payload.eventID : target.eventID
                    let targetDate = edited.contains(.date)
                        ? payload.date : target.date
                    let idols = try refetchIdolsByIDs(targetIdolIDs)
                    let event = try refetchEventByID(targetEventID)
                    try validateChekiAssociations(
                        idols: idols,
                        event: event,
                        eventDate: targetDate
                    )

                    if edited.contains(.idols) { target.idols = idols }
                    if edited.contains(.event) { target.event = event }
                    if edited.contains(.date) { target.date = targetDate }
                    if edited.contains(.userAppears) {
                        target.userAppears = payload.userAppears ?? false
                    }
                    if edited.contains(.size) { target.size = effectiveSize }
                    if edited.contains(.favorite) {
                        target.isFavorite = payload.isFavorite
                    }
                    if edited.contains(.posted) {
                        target.hasPostedToSNS = payload.hasPostedToSNS
                    }
                    if edited.contains(.note) { target.note = payload.note }
                    return !edited.isDisjoint(with: [.idols, .event, .date])
                }
                await ChekinanaThumbnailCache.shared.invalidate(imageRef: originalImageRef)
                await ChekinanaThumbnailCache.shared.invalidate(
                    imageRef: imageReplacement?.imageRef
                )
                response = .chekiCards([chekiCard(for: cheki)])

            case .deleteCheki(let payload):
                response = try confirmDeleteCheki(payload, confirmationCode: entry.code)

            case .mutateRecord(let payload):
                response = try await confirmRecordMutation(payload)

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

    private func confirmRecordMutation(_ payload: ChekinanaConfirmationLedger.RecordPayload) async throws -> ChekinanaCommandResponse {
        let idols = try refetchIdolsByIDs(payload.idolIDs)
        let event = try refetchEventByID(payload.eventID)
        func validateChekiRecord() throws {
            try validateChekiAssociations(idols: idols, event: event, eventDate: payload.date)
        }
        switch (payload.kind, payload.mutation) {
        case (.cheki, .add):
            try validateChekiRecord()
            let saved = try ChekinanaChekiRecordStore.upsert(
                idols: idols,
                event: event,
                date: payload.date,
                size: payload.size,
                note: payload.note,
                adding: payload.count,
                in: modelContext
            )
            if let assistantDialogue {
                assistantDialogue.target = assistantDialogue.capture(.init(kind: .chekiRecord, id: saved.id), in: modelContext)
                assistantDialogue.choices = assistantDialogue.target.map { [$0] } ?? []
                return .text(ChekinanaL10n.format("assistant.dialog.saved_quantity", fallback: "Added %1$lld Cheki. This record now contains %2$lld.", Int64(payload.count), Int64(saved.count)))
            }
        case (.shame, .add):
            throw ChekinanaMediaBackedCreationError.shameRequiresImage
        case (.douga, .add):
            throw ChekinanaMediaBackedCreationError.dougaRequiresVideo
        case (.cheki, .edit(let id)):
            let record = try refetchChekiRecordByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaEditConflictError.staleCheki("") }
            try validateChekiRecord()
            let saved = try ChekinanaChekiRecordStore.update(
                record,
                idols: idols,
                event: event,
                date: payload.date,
                size: payload.size,
                note: payload.note,
                count: payload.count,
                expected: payload.expectedChekiRecordSnapshot,
                in: modelContext
            )
            if let assistantDialogue {
                assistantDialogue.target = saved.flatMap { assistantDialogue.capture(.init(kind: .chekiRecord, id: $0.id), in: modelContext) }
                assistantDialogue.choices = assistantDialogue.target.map { [$0] } ?? []
                return .text(ChekinanaL10n.format("assistant.dialog.updated_quantity", fallback: "Saved. This record now contains %lld Cheki.", Int64(saved?.count ?? 0)))
            }
        case (.shame, .edit(let id)):
            let record = try refetchShameByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaNLClientError.invalidSchema }
            try validateChekiRecord()
            record.idols = idols
            record.eventID = event?.id
            record.date = payload.date
            record.note = payload.note
            record.updatedAt = Date()
            try ChekinanaEventAssociationPropagation.propagate(
                from: record,
                in: modelContext
            )
        case (.douga, .edit(let id)):
            let record = try refetchDougaByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaNLClientError.invalidSchema }
            try validateChekiRecord()
            record.idols = idols
            record.eventID = event?.id
            record.date = payload.date
            record.note = payload.note
            record.updatedAt = Date()
            try ChekinanaEventAssociationPropagation.propagate(
                from: record,
                in: modelContext
            )
        case (.cheki, .delete(let id)):
            let record = try refetchChekiRecordByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else {
                throw ChekinanaNLClientError.invalidSchema
            }
            try ChekinanaChekiRecordStore.delete(
                record,
                expected: payload.expectedChekiRecordSnapshot,
                in: modelContext
            )
        case (.shame, .delete(let id)):
            let record = try refetchShameByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaNLClientError.invalidSchema }
            try await ChekinanaGalleryDeletionCoordinator.delete(
                kind: .shame,
                mediaOwnerID: record.mediaOwnerID,
                reference: record.imageRef,
                in: modelContext,
                validateModel: {
                    let current = try self.refetchShameByID(id)
                    guard self.recordFingerprint(current)
                            == payload.expectedFingerprint,
                          current.mediaOwnerID == record.mediaOwnerID,
                          current.imageRef == record.imageRef else {
                        throw ChekinanaNLClientError.invalidSchema
                    }
                },
                deleteModel: {
                    self.modelContext.delete(try self.refetchShameByID(id))
                }
            )
            return .text(ChekinanaCommandCopy.text(
                "record.completed",
                fallback: "Record operation completed."
            ))
        case (.douga, .delete(let id)):
            let record = try refetchDougaByID(id)
            guard recordFingerprint(record) == payload.expectedFingerprint else { throw ChekinanaNLClientError.invalidSchema }
            try await ChekinanaGalleryDeletionCoordinator.delete(
                kind: .douga,
                mediaOwnerID: record.mediaOwnerID,
                reference: record.videoRef,
                in: modelContext,
                validateModel: {
                    let current = try self.refetchDougaByID(id)
                    guard self.recordFingerprint(current)
                            == payload.expectedFingerprint,
                          current.mediaOwnerID == record.mediaOwnerID,
                          current.videoRef == record.videoRef else {
                        throw ChekinanaNLClientError.invalidSchema
                    }
                },
                deleteModel: {
                    self.modelContext.delete(try self.refetchDougaByID(id))
                }
            )
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
        let alreadyCommitted: Bool
        if case .cleanupQuarantine = payload.phase {
            alreadyCommitted = true
        } else {
            alreadyCommitted = false
        }
        do {
            try ChekinanaChekiDeletionCoordinator.delete(
                chekiID: payload.chekiID,
                expectedUpdatedAt: payload.expectedUpdatedAt,
                alreadyCommitted: alreadyCommitted,
                in: modelContext,
                onDatabaseCommitted: { quarantineURL in
                    confirmationLedger.updateDeleteChekiPayload(
                        .init(
                            chekiID: payload.chekiID,
                            expectedUpdatedAt: payload.expectedUpdatedAt,
                            phase: .cleanupQuarantine(quarantineURL)
                        ),
                        for: confirmationCode
                    )
                }
            )
        } catch ChekinanaChekiDeletionError.changedRecord {
            throw ChekinanaEditConflictError.staleCheki(confirmationCode)
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
                assistantDialogue?.catalogueLookupHadNoResults = true
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
        let formatter = ListFormatter()
        formatter.locale = ChekinanaLanguagePreference.displayLocale()
        return formatter.string(from: values) ?? values.joined(separator: ", ")
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
            let tokens = target.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let selected: [Idol]
            if tokens.count > 1, tokens.count <= 50, tokens.allSatisfy({ UUID(uuidString: $0) != nil }) {
                var seen = Set<UUID>()
                selected = try tokens.compactMap { token in
                    guard let id = UUID(uuidString: token), seen.insert(id).inserted else { return nil }
                    return try refetchIdolByID(id)
                }
            } else { selected = [try resolveUniqueIdol(target)] }
            guard let idol = selected.first else { return invalidUsage(usage) }
            let authorization = try ChekinanaIdolCascadeAuthorization.capture(
                idolIDs: Set(selected.map(\.id)), in: modelContext)
            let deletedQuantity = try ChekinanaIdolCascadeAuthorization.quantityCount(authorization.deletedQuantities)
            let retainedQuantity = try ChekinanaIdolCascadeAuthorization.quantityCount(authorization.retainedQuantities)
            let summary = ChekinanaCommandCopy.format("idol.delete_associated_confirm",
                fallback: "Delete %@?\nDelete: Cheki %lld, photos %lld, videos %lld; quantity records %lld (%lld Cheki); memories %lld, attachments %lld.\nKeep and unlink: Cheki %lld, photos %lld, videos %lld; quantity records %lld (%lld Cheki); memories %lld, attachments %lld.\nDeletion cannot be undone.",
                selected.map(\.name).joined(separator: ", "),
                Int64(authorization.deletedMedia.filter { $0.kind == MediaItemKind.cheki.rawValue }.count),
                Int64(authorization.deletedMedia.filter { $0.kind == MediaItemKind.shame.rawValue }.count),
                Int64(authorization.deletedMedia.filter { $0.kind == MediaItemKind.douga.rawValue }.count),
                Int64(authorization.deletedQuantities.count), Int64(deletedQuantity),
                Int64(authorization.deletedMemories.count), Int64(authorization.deletedAttachments.count),
                Int64(authorization.retainedMedia.filter { $0.kind == MediaItemKind.cheki.rawValue }.count),
                Int64(authorization.retainedMedia.filter { $0.kind == MediaItemKind.shame.rawValue }.count),
                Int64(authorization.retainedMedia.filter { $0.kind == MediaItemKind.douga.rawValue }.count),
                Int64(authorization.retainedQuantities.count), Int64(retainedQuantity),
                Int64(authorization.retainedMemories.count), Int64(authorization.retainedAttachmentCount))
            let code = confirmationLedger.insert(.deleteIdol(.init(
                idolID: idol.id,
                expectedUpdatedAt: idol.updatedAt,
                cascadeAuthorization: authorization
            )))
            return .confirmationText(summary, confirmationCode: code)
        } catch {
            let internalTargets = target.split(separator: ",", omittingEmptySubsequences: false)
            let message = internalTargets.allSatisfy { UUID(uuidString: String($0)) != nil }
                ? ChekinanaIdolCascadeError.changedAssociations.localizedDescription : error.localizedDescription
            return .text(ChekinanaCommandCopy.errorDetail(message))
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
            avatarUrl: editedOptional(candidate.avatarUrl, field: "avatar", values: values, clearFields: clearFields),
            patternIds: candidate.patternIds
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

    private func catalogueIdol(
        from candidate: ChekinanaEnrichedIdol,
        patterns: [[Float]]
    ) throws -> Idol {
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
            patterns: patterns
        )
    }

    private func persistCatalogueIdol(
        _ prepared: ChekinanaPreparedIdolCandidate
    ) async throws -> Idol {
        let patterns = try await patternResolve(prepared.candidate.patternIds)
        let idol = try catalogueIdol(
            from: prepared.candidate,
            patterns: patterns
        )
        return try await ChekinanaLibraryMutationProtocol.withExclusiveOperation {
            try ChekinanaLibraryMutationPreflight.requireImportConvergedExclusively(in: modelContext)
            let transaction = try ChekinanaIdolAvatarStagingTransaction(
                in: modelContext
            )
            do {
                let stagedAvatar = try await transaction.stage(
                    prepared,
                    idolID: idol.id
                )
                let result = try ChekinanaPersistenceMutationCoordinator.withLock {
                    modelContext.insert(IdolPatternState(
                        idolID: idol.id,
                        encoderVersion: ChekinanaPatternContract.encoderVersion,
                        cataloguePatternIDs: prepared.candidate.patternIds,
                        cataloguePatternCount: patterns.count
                    ))
                    _ = try ChekinanaIdolAvatarStatePersistence.record(
                        idolID: idol.id,
                        source: .catalogue,
                        intent: .userSelected,
                        in: modelContext
                    )
                    return try ChekinanaIdolPersistence.save(
                        idol,
                        inserting: true,
                        previousAvatarRef: nil,
                        stagedAvatar: stagedAvatar,
                        in: modelContext,
                        libraryGeneration: transaction.libraryGeneration
                    ) { target in
                        target.avatarImageRef = stagedAvatar.ref
                    }
                }
                let stagedCleanupPending = transaction.commit(
                    referencedImageRef: idol.avatarImageRef
                ) != nil
                let replacedCleanupPending = result.pendingAvatarCleanup.map { cleanup in
                    cleanup.operationID.map {
                        ChekinanaIdolAvatarCleanupQueue.contains(operationID: $0)
                    } ?? true
                } ?? false
                if stagedCleanupPending || replacedCleanupPending {
                    throw ChekinanaCatalogueIdolAvatarLocalizerError.cleanupRequired
                }
                return idol
            } catch {
                if transaction.rollback() != nil {
                    throw ChekinanaCatalogueIdolAvatarLocalizerError.cleanupRequired
                }
                throw error
            }
        }
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
            detail: .chekiCount(mediaItemCount(kind: .cheki, idolID: idol.id)),
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

        guard !ChekinanaLocalEntityMatch.key(target).isEmpty else { return invalidUsage(usage) }
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
                ChekinanaLocalEntityMatch.contains(idol.name, query: target)
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
        let allowedFields = Set(["name", "date", "city", "livehouse", "price", "ticket_url", "note"])
        guard let target = command.target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty,
              command.arguments.keys.allSatisfy(allowedFields.contains) else {
            return invalidUsage(usage)
        }

        do {
            let city = command.arguments["city"].flatMap(optionalNonempty)
            let livehouse = command.arguments["livehouse"].flatMap(optionalNonempty)
            let price = command.arguments["price"].flatMap(optionalNonempty)
            let note = command.arguments["note"] ?? ""
            let ticketURL = try command.arguments["ticket_url"].flatMap(optionalHTTPURL)
            guard (city?.count ?? 0) <= 200, (livehouse?.count ?? 0) <= 300, (price?.count ?? 0) <= 300, note.count <= 500 else { throw ChekinanaNLClientError.invalidSchema }
            let targetURL = try optionalHTTPURL(target)
            let name: String
            let date: Date?
            if let targetURL {
                guard ChekinanaEventSource.validatedURL(
                    from: targetURL.absoluteString
                ) != nil else {
                    throw ChekinanaEventError.invalidURL
                }
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
                        city: city,
                        livehouse: livehouse,
                        price: price,
                        weiboURL: targetURL,
                        ticketURL: ticketURL,
                        note: note
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
                ) + "\n" + eventMetadataPreview(city: city, livehouse: livehouse, price: price, ticketURL: ticketURL, note: note), confirmationCode: code)
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
                    city: city,
                    livehouse: livehouse,
                        price: price,
                    weiboURL: nil,
                    ticketURL: ticketURL,
                    note: note
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
            ) + "\n" + eventMetadataPreview(city: city, livehouse: livehouse, price: price, ticketURL: ticketURL, note: note), confirmationCode: code)
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
            let schedule = try ChekinanaEventSchedulePersistence.value(
                for: event.id,
                in: modelContext
            )
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
                let parsed = try requireHTTPURL(value)
                guard ChekinanaEventSource.infer(from: parsed) != nil else {
                    throw ChekinanaEventError.invalidURL
                }
                url = parsed
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
                openTime: schedule.openTime,
                startTime: schedule.startTime,
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
            ) + "\n" + eventMetadataPreview(city: city, livehouse: livehouse, price: price, ticketURL: ticketURL, note: note), confirmationCode: code)
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
            ) + "\n" + ChekinanaL10n.text("assistant.dialog.delete_event_scope", fallback: "Deleting an Event keeps its Cheki and removes their Event link, along with the Event’s own data."), confirmationCode: code)
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
            var minimumByGroup: [ChekinanaChekiGroupKey: Int] = [:]
            var ownersByIndex: [ChekinanaBatchIndexKey: Set<UUID>] = [:]
            for snapshot in snapshots {
                guard let group = ChekinanaChekiGroupKey(
                    idolIDs: snapshot.idolIDs,
                    date: snapshot.date), let idx = snapshot.idx else { continue }
                if idx > 0 {
                    maximumByGroup[group] = max(maximumByGroup[group] ?? 0, idx)
                } else if idx < 0 {
                    minimumByGroup[group] = min(minimumByGroup[group] ?? 0, idx)
                }
                ownersByIndex[.init(group: group, idx: idx), default: []].insert(snapshot.id)
            }

            var newIDs = Set<UUID>()
            for entry in entries {
                guard case .addCheki(let payload) = entry.action,
                      payload.temporaryChekiID != nil else {
                    throw ChekinanaAddChekiError.duplicateCheki(entry.code)
                }
                guard !existingIDs.contains(payload.id),
                      newIDs.insert(payload.id).inserted else {
                    throw ChekinanaAddChekiError.duplicateCheki(entry.code)
                }
                let group = ChekinanaChekiGroupKey(
                    idolIDs: payload.idolIDs,
                    date: payload.date)
                let idx: Int?
                let indexStrategy: ChekinanaBatchIndexStrategy
                if let group {
                    let next: Int

                        let current = maximumByGroup[group] ?? 0
                        guard current < Int.max else {
                            throw ChekinanaAddChekiError.indexOverflow
                        }
                        next = current + 1
                        maximumByGroup[group] = next

                    ownersByIndex[.init(group: group, idx: next), default: []].insert(payload.id)
                    idx = next
                    indexStrategy = .automatic
                } else {
                    throw ChekinanaAddChekiError.indexOverflow
                }
                batch.append((
                    payload,
                    // The new MediaItem owns a new file. The selected
                    // ChekiRecord remains a separate quantity source.
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
        var savedThumbnails = Array<Data?>(repeating: nil, count: batch.count)
        var preparationFailures: [String] = []
        let preparationLimiter = batchImagePreparationLimiter
        await withTaskGroup(
            of: (
                Int,
                saved: SavedChekiImage?,
                thumbnail: Data?,
                failure: String?
            ).self
        ) { group in
            for (index, item) in batch.enumerated() {
                let pendingImage = item.payload.image
                let imageID = item.imageStorageID
                let effectiveSize = item.payload.size ?? .mini
                group.addTask {
                    do {
                        let prepared = try await preparationLimiter.perform {
                            try await ChekinanaReviewChekiImagePreparer
                                .standardizedForSave(
                                    fallbackImage: pendingImage,
                                    reviewSource: item.payload.reviewRectificationSource,
                                    rotationQuarterTurns:
                                        item.payload.reviewRotationQuarterTurns,
                                    size: effectiveSize
                                )
                        }
                        let saved = try await preparationLimiter.perform {
                            try await ChekinanaImageWorker.saveChekiImageData(
                                prepared.data,
                                id: imageID,
                                filenameExtension: "jpg"
                            )
                        }
                        let thumbnail = await ChekinanaImageWorker.thumbnailData(
                            from: prepared.data
                        )
                        return (index, saved, thumbnail, nil)
                    } catch {
                        return (index, nil, nil, error.localizedDescription)
                    }
                }
            }
            var completed = 0
            for await (index, saved, thumbnail, failure) in group {
                completed += 1
                if let saved { savedImages[index] = saved }
                savedThumbnails[index] = thumbnail
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
        var savedModels: [MediaItem] = []
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
            // so explicit payload associations can be resolved atomically at
            // the final target-context write boundary.
            let relationEventModels = try modelContext.fetch(FetchDescriptor<Event>())
            let eventsByID = Dictionary(
                uniqueKeysWithValues: relationEventModels.map { ($0.id, $0) }
            )
            let recordModels = try modelContext.fetch(FetchDescriptor<ChekiRecord>())
            let recordsByID = Dictionary(uniqueKeysWithValues: recordModels.map { ($0.id, $0) })
            var remainingRecordCounts = Dictionary(
                uniqueKeysWithValues: recordModels.map { ($0.id, max(0, $0.count)) }
            )
            var recordConsumptionCounts: [UUID: Int] = [:]
            let recordSnapshots = Dictionary(
                uniqueKeysWithValues: recordModels.map {
                    ($0.id, ChekinanaChekiRecordSnapshot($0))
                }
            )

            // The background snapshot is only an early planning aid. Refresh
            // the complete live Cheki set at the final write boundary. Undated
            // groups are first-class, so a date-bounded fetch is insufficient.
            let liveChekisByID = Dictionary(uniqueKeysWithValues:
                try modelContext.fetch(FetchDescriptor<MediaItem>())
                    .filter { $0.kind == .cheki }
                    .map { ($0.id, $0) }
            )
            var liveMaximumByGroup: [ChekinanaChekiGroupKey: Int] = [:]
            var liveMinimumByGroup: [ChekinanaChekiGroupKey: Int] = [:]
            var liveOwnersByIndex: [ChekinanaBatchIndexKey: Set<UUID>] = [:]
            for cheki in liveChekisByID.values {
                guard let group = ChekinanaChekiGroupKey(
                    idolIDs: cheki.idols.map(\.id),
                    date: cheki.date), let idx = cheki.idx else { continue }
                if idx > 0 {
                    liveMaximumByGroup[group] = max(liveMaximumByGroup[group] ?? 0, idx)
                } else if idx < 0 {
                    liveMinimumByGroup[group] = min(liveMinimumByGroup[group] ?? 0, idx)
                }
                liveOwnersByIndex[.init(group: group, idx: idx), default: []]
                    .insert(cheki.id)
            }
            for index in batch.indices {
                let payload = batch[index].payload
                let group = ChekinanaChekiGroupKey(
                    idolIDs: payload.idolIDs,
                    date: payload.date)
                switch batch[index].indexStrategy {
                case .none, .preserveExisting, .automatic:
                    guard let group else {
                        throw ChekinanaAddChekiError.indexOverflow
                    }
                    let next: Int

                        let current = liveMaximumByGroup[group] ?? 0
                        guard current < Int.max else {
                            throw ChekinanaAddChekiError.indexOverflow
                        }
                        next = current + 1
                        liveMaximumByGroup[group] = next

                    liveOwnersByIndex[.init(group: group, idx: next), default: []]
                        .insert(payload.id)
                    batch[index].idx = next
                case .explicit(let requestedIdx):
                    guard let requestedIdx else {
                        batch[index].indexStrategy = .automatic
                        guard let group else {
                            throw ChekinanaAddChekiError.indexOverflow
                        }
                        let next: Int

                            let current = liveMaximumByGroup[group] ?? 0
                            guard current < Int.max else {
                                throw ChekinanaAddChekiError.indexOverflow
                            }
                            next = current + 1
                            liveMaximumByGroup[group] = next

                        liveOwnersByIndex[.init(group: group, idx: next), default: []]
                            .insert(payload.id)
                        batch[index].idx = next
                        continue
                    }
                    guard ChekinanaChekiIndexing.isValid(
                        requestedIdx,
                        isFavorite: payload.isFavorite
                    ), let group else {
                        throw ChekinanaAddChekiError.indexOverflow
                    }
                    let key = ChekinanaBatchIndexKey(group: group, idx: requestedIdx)
                    let allowedOwner: UUID? = nil
                    let owners = liveOwnersByIndex[key, default: []]
                    guard !owners.contains(where: { $0 != allowedOwner }),
                          owners.count <= (allowedOwner == nil ? 0 : 1) else {
                        throw ChekinanaAddChekiError.duplicateIndex(requestedIdx)
                    }
                    liveOwnersByIndex[key, default: []].insert(payload.id)
                    if requestedIdx > 0 {
                        liveMaximumByGroup[group] = max(
                            liveMaximumByGroup[group] ?? 0,
                            requestedIdx
                        )
                    } else {
                        liveMinimumByGroup[group] = min(
                            liveMinimumByGroup[group] ?? 0,
                            requestedIdx
                        )
                    }
                    batch[index].idx = requestedIdx
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
                // A nil event is a complete, valid final value. UI-level
                // automatic association may populate the payload beforehand,
                // but the persistence boundary never invents an Event.
                let relationEvent = item.payload.eventID.flatMap { eventsByID[$0] }
                guard !(explicitEvent || item.payload.usesScanReviewRecordMatching)
                        || item.payload.eventID == nil || relationEvent != nil else {
                    throw ChekinanaAddChekiError.modelContextMismatch
                }
                try validateChekiAssociations(
                    idols: relationIdols,
                    event: relationEvent,
                    eventDate: item.payload.date
                )
                let effectiveSize = item.payload.size ?? .mini
                let mediaContext = ChekinanaChekiRecordAllocationPolicy.MediaContext(
                    date: normalizedCalendarDay(item.payload.date),
                    idolIDs: item.payload.idolIDs,
                    eventID: relationEvent?.id,
                    size: effectiveSize
                )
                let candidates = recordModels.map { record in
                    ChekinanaChekiRecordAllocationPolicy.Candidate(
                        id: record.id,
                        date: record.date,
                        idolIDs: record.idolIDs,
                        eventID: record.eventID,
                        size: record.size,
                        count: remainingRecordCounts[record.id, default: 0] > 0
                            ? record.count : 0
                    )
                }
                let matchedRecordID: UUID?
                if item.payload.usesScanReviewRecordMatching {
                    matchedRecordID = item.payload.existingChekiID
                    if let matchedRecordID {
                        guard let record = recordsByID[matchedRecordID],
                              let expected = item.payload.existingChekiRecordSnapshot,
                              ChekinanaChekiRecordSnapshot(record) == expected,
                              ChekinanaScanReviewRecordMatchPolicy.matches(
                                .init(id: record.id, date: record.date, idolIDs: record.idolIDs,
                                      eventID: record.eventID, size: record.size, count: record.count),
                                media: mediaContext, calendar: calendar
                              ) else { throw ChekinanaNLClientError.invalidSchema }
                    }
                } else {
                    matchedRecordID = ChekinanaChekiRecordAllocationPolicy.allocationIDs(
                        media: [mediaContext], candidates: candidates, calendar: calendar
                    )[0]
                }
                let matchedRecord = matchedRecordID.flatMap { recordsByID[$0] }
                if let matchedRecordID {
                    remainingRecordCounts[matchedRecordID, default: 0] = max(
                        0, remainingRecordCounts[matchedRecordID, default: 0] - 1
                    )
                    recordConsumptionCounts[matchedRecordID, default: 0] += 1
                }
                let effectiveNote = item.payload.usesScanReviewRecordMatching
                    || item.payload.explicitlyEditedFields.contains(.note)
                    ? item.payload.note
                    : (matchedRecord?.note ?? item.payload.note)
                let persistedDate = try ChekinanaPersistedContentDatePolicy
                    .validatedCanonical(normalizedCalendarDay(item.payload.date))
                guard ChekinanaChekiIndexing.isValid(
                    item.idx,
                    isFavorite: item.payload.isFavorite
                ) else {
                    throw ChekinanaAddChekiError.indexOverflow
                }
                let cheki = MediaItem(
                    id: item.payload.id,
                    mediaOwnerID: item.payload.id,
                    idols: relationIdols,
                    event: relationEvent,
                    date: persistedDate,
                    idx: item.idx,
                    userAppears: item.payload.userAppears,
                    size: effectiveSize,
                    imageRef: savedImage.ref,
                    isFavorite: item.payload.isFavorite,
                    hasPostedToSNS: item.payload.hasPostedToSNS,
                    note: effectiveNote,
                    createdAt: item.payload.createdAt
                )
                modelContext.insert(cheki)
                savedModels.append(cheki)
                publish(.savingRecords, index + 1)
            }
            let reviewMatchedRecordIDs = Set(batch.compactMap {
                $0.payload.usesScanReviewRecordMatching ? $0.payload.existingChekiID : nil
            })
            for (index, source) in savedModels.enumerated() {
                let eventID = batch[index].payload.usesScanReviewRecordMatching
                    ? batch[index].payload.eventID : source.eventID
                try ChekinanaEventAssociationPropagation.propagate(
                    idolIDs: source.idolIDs, eventID: eventID, date: source.date,
                    protectingRecordIDs: reviewMatchedRecordIDs,
                    in: modelContext
                )
            }
            // Propagation may fill a sibling's intentionally empty Event.
            // Review's displayed final association remains authoritative.
            for (index, source) in savedModels.enumerated()
                where batch[index].payload.usesScanReviewRecordMatching {
                source.eventID = batch[index].payload.eventID
            }
            // Consume only after propagation. Restore the matched canonical
            // date if SwiftData invalidated it during this mixed insert/update
            // transaction, but keep any valid Event propagation intact.
            for (targetID, consumedCount) in recordConsumptionCounts {
                guard let record = recordsByID[targetID],
                      let snapshot = recordSnapshots[targetID] else { continue }
                ChekinanaChekiRecordConsumptionPolicy.consume(
                    consumedCount,
                    from: record,
                    preserving: snapshot,
                    in: modelContext
                )
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
                thumbnailImageData: savedThumbnails[index]
                    ?? batch[index].payload.thumbnailImageData
            )
        })
    }

    /// Review preserves existing hidden associations of shared temporary cards.
    /// No caller-supplied Idol IDs or command fields enter this UI-only path.
    func prepareScanReviewConfirmation(selection: String) -> ChekinanaCommandResponse {
        addScanCheki(
            .init(name: "addscancheki", target: selection, arguments: [:]),
            usage: commandUsages["addscancheki"] ?? ["addscancheki"],
            preservesReviewAssociations: true
        )
    }

    private func addScanCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String],
        preservesReviewAssociations: Bool = false
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
            let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
            let idolsPerResult = try idolIDLists.enumerated().map { index, ids in
                let preservedHiddenIDs: Set<UUID>
                if preservesReviewAssociations {
                    guard command.arguments.isEmpty,
                          Set(ids) == Set(temporaryValues[index].idolIDs),
                          ChekinanaFourPageVisibilityPolicy.includesRecord(
                            idolIDs: ids, hiddenIDs: hiddenIDs
                          ) else {
                        throw ChekinanaNLClientError.invalidSchema
                    }
                    preservedHiddenIDs = Set(temporaryValues[index].idolIDs)
                        .intersection(hiddenIDs)
                } else {
                    preservedHiddenIDs = []
                }
                return try refetchIdolsByIDs(
                    ids, preservingHiddenIDs: preservedHiddenIDs
                )
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
                let id = UUID()
                let existingTarget = try temporary.existingChekiID.map {
                    try refetchChekiRecordByID(
                        $0, allowsSharedHiddenAssociations: preservesReviewAssociations
                    )
                }
                if preservesReviewAssociations,
                   existingTarget.map(ChekinanaChekiRecordSnapshot.init) != temporary.scanReviewRecordSnapshot {
                    throw ChekinanaNLClientError.invalidSchema
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
                    reviewRectificationSource: temporary.reviewRectificationSource,
                    reviewRotationQuarterTurns: temporary.imageRotationQuarterTurns,
                    reviewTransformGeneration: temporary.transformGeneration,
                    reviewTransformSourceVersion: temporary.transformSourceVersion,
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
                    existingChekiRecordSnapshot: preservesReviewAssociations
                        ? temporary.scanReviewRecordSnapshot
                        : existingTarget.map(ChekinanaChekiRecordSnapshot.init),
                    usesScanReviewRecordMatching: preservesReviewAssociations,
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
                    idolNames: item.idols.filter {
                        !preservesReviewAssociations || !hiddenIDs.contains($0.id)
                    }.map(\.name),
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
        guard let inferred else { return nil }
        // A full date already supplies its year. The recent window only
        // disambiguates a month/day result; it must not discard a valid year.
        if annotation.precision == .fullDate, bounds.scope == .recent {
            return inferred
        }
        guard bounds.contains(inferred) else { return nil }
        return inferred
    }

    private func uniqueEventID(
        for inferredDate: Date?,
        candidates: [ChekinanaEventDateCandidate]
    ) -> UUID? {
        ChekinanaChekiEventAutoAssociation.uniqueEventID(
            for: inferredDate,
            events: candidates.map { ($0.id, $0.date) },
            calendar: calendar
        )
    }

    private func scanCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String],
        pendingImages: [ChekinanaPendingChekiImage]
    ) async -> ChekinanaCommandResponse {
        await scanCheki(
            command,
            usage: usage,
            sourceCount: pendingImages.count,
            maximumConcurrentSourceProcessing:
                ChekinanaStreamingScanScheduler.maximumConcurrentSourceProcessing,
            loadPendingImage: { sourceIndex in pendingImages[sourceIndex] }
        )
    }

    private func scanCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String],
        sourceCount: Int,
        maximumConcurrentSourceProcessing: Int,
        loadPendingImage: @escaping PendingImageLoader
    ) async -> ChekinanaCommandResponse {
        let allowedArguments = Set([
            "expected", "scanner_size", "wb", "sleeves", "direct",
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
            guard sourceCount > 0 else {
                return .text(ChekinanaCommandCopy.error(
                    "scan.select_photos",
                    fallback: "Select one or more photos with the photo-library button before scanning."
                ))
            }

            var scannedImages: [ChekinanaPendingChekiImage] = []
            var dateAnnotationStates: [ChekinanaChekiDateAnnotationState] = []
            var scannerMetadata: [ChekinanaTemporaryScannerMetadata] = []
            var sourceAnnotations: [ChekinanaScannerSourceAnnotation?] = []
            var reviewRectificationSources: [ChekinanaReviewRectificationSource?] = []
            var refitOriginalSources: [ChekinanaReviewRectificationSource?] = []
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
                    sourceCount: sourceCount,
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
            var recognitionWork: [RecognitionTaskKey: ChekinanaScanRecognitionWork<RecognitionResolution>] = [:]
            var skipRegistrations: [UUID] = []
            defer { skipRegistrations.forEach { recognitionSkipControl?.unregister($0) } }
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
                let work = ChekinanaScanRecognitionWork(RecognitionResolution(
                    dateState: .notRequested,
                    matchedIdolID: options.directIdolCandidateID,
                    userAppears: nil,
                    warningCount: 0,
                    isCancelled: false
                ))
                recognitionWork[key] = work
                // These values are specified/known without asynchronous work.
                if options.usesFixedDate { work.complete(.date) { _ in } }
                if options.directIdolCandidateID != nil { work.complete(.idol) { _ in } }
                if let recognitionSkipControl {
                    skipRegistrations.append(recognitionSkipControl.register {
                        work.freezeAutomaticRecognition()
                    })
                }
                let task = Task { @MainActor in
                    let dateTask = Task { @MainActor in
                        await dateRecognitionOutcome(
                            resultImage: resultImage,
                            bounds: options.dateBounds,
                            requestGate: directDateRequestGate
                        )
                    }
                    let idolTask = Task { @MainActor in
                        await idolRecognitionOutcome(
                            resultImage: resultImage,
                            candidates: options.idolRecognitionCandidates,
                            recognitionGate: directRecognitionGate
                        )
                    }
                    let bodyPoseTask = Task { @MainActor in
                        await userAppearsRecognitionOutcome(resultImage: resultImage)
                    }
                    work.installCancellation(for: .date) { dateTask.cancel() }
                    work.installCancellation(for: .idol) { idolTask.cancel() }
                    work.installCancellation(for: .userAppears) { bodyPoseTask.cancel() }
                    await withTaskCancellationHandler {
                        await withTaskGroup(of: RecognitionProgressEvent.self) { group in
                            group.addTask { .date(await dateTask.value) }
                            group.addTask { .idol(await idolTask.value) }
                            group.addTask { .userAppears(await bodyPoseTask.value) }
                            for await event in group {
                                if Task.isCancelled {
                                    work.cancel { $0.isCancelled = true }
                                    group.cancelAll()
                                    continue
                                }
                                let component: ChekinanaScanRecognitionWork<RecognitionResolution>.Component
                                switch event {
                                case .date: component = .date
                                case .idol: component = .idol
                                case .userAppears: component = .userAppears
                                }
                                // Skip already froze the partial result. A late
                                // event cannot advance progress or fill metadata.
                                guard work.isPending(component) else { continue }
                                switch event {
                                case .date(.cancelled), .idol(.cancelled), .userAppears(.cancelled):
                                    work.cancel { $0.isCancelled = true }
                                    group.cancelAll()
                                default:
                                    work.complete(component) { resolution in
                                        switch event {
                                        case .date(.notRequested), .idol(.notRequested):
                                            break
                                        case .date(.completed(let state)):
                                            resolution.dateState = state
                                            if !options.usesFixedDate { progressState.dateCompletedCount += 1 }
                                            if state == .unavailable { resolution.warningCount += 1 }
                                        case .idol(.matched(let idolID)):
                                            resolution.matchedIdolID = idolID
                                            if options.directIdolCandidateID == nil { progressState.idolCompletedCount += 1 }
                                        case .idol(.failed):
                                            resolution.warningCount += 1
                                            progressState.idolCompletedCount += 1
                                        case .userAppears(.completed(let value)):
                                            resolution.userAppears = value
                                        case .userAppears(.unavailable):
                                            resolution.warningCount += 1
                                        case .date(.cancelled), .idol(.cancelled), .userAppears(.cancelled):
                                            break
                                        }
                                    }
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
                    } onCancel: {
                        dateTask.cancel()
                        idolTask.cancel()
                        bodyPoseTask.cancel()
                        Task { @MainActor in work.cancel { $0.isCancelled = true } }
                    }
                    if Task.isCancelled { work.cancel { $0.isCancelled = true } }
                    return work.snapshot
                }
                recognitionTasks.insert(task, for: key)
                return task
            }
            let sourceOutcomes = await withTaskCancellationHandler {
                await ChekinanaStreamingScanScheduler.run(
                    sourceCount: sourceCount,
                    limit: maximumConcurrentSourceProcessing
                ) { sourceOffset in
                    let sourceIndex = sourceOffset + 1
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
                        let pendingImage = try await loadPendingImage(sourceOffset)
                        try Task.checkCancellation()
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
                        // Remote scanners may publish results incrementally via
                        // the observer above. Local/fallback scanners can only
                        // return their result array at completion, so start the
                        // same recognition tasks here before releasing this
                        // source-processing slot.
                        for (resultIndex, resultImage) in result.images.enumerated() {
                            _ = recognitionTask(
                                sourceIndex: sourceIndex,
                                resultIndex: resultIndex,
                                resultCount: result.images.count,
                                resultImage: resultImage
                            )
                        }
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
                        return SourceScanOutcome.success(
                            result,
                            sourceID: pendingImage.sourceID,
                            sourceOrigin: pendingImage.sourceOrigin
                        )
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
            } onCancel: {
                progressGate.invalidate()
                recognitionTasks.cancelAll()
            }
            do {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    for (sourceOffset, outcome) in sourceOutcomes.enumerated() {
                        let sourceIndex = sourceOffset + 1
                        try Task.checkCancellation()
                        let result: ChekinanaScannerProcessResult
                        let sourceID: UUID?
                        let sourceOrigin: ChekinanaScanSourceOrigin
                        switch outcome {
                        case .success(
                            let scannerResult,
                            sourceID: let resolvedSourceID,
                            sourceOrigin: let resolvedSourceOrigin
                        ):
                            result = scannerResult
                            sourceID = resolvedSourceID
                            sourceOrigin = resolvedSourceOrigin
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
                            _ = recognitionTask(
                                sourceIndex: sourceIndex,
                                resultIndex: resultOffset,
                                resultCount: result.images.count,
                                resultImage: resultImage
                            )
                            let key = RecognitionTaskKey(sourceIndex: sourceIndex, resultIndex: resultOffset)
                            guard let work = recognitionWork[key] else {
                                throw ChekinanaScanChekiError.noResultImages
                            }
                            let recognition = await work.value
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
                                sourceID: sourceID,
                                sourceOrigin: sourceOrigin
                            ))
                            dateAnnotationStates.append(annotationState)
                            sourceAnnotations.append(resultImage.sourceAnnotation)
                            refitOriginalSources.append(resultImage.refitOriginalSource)
                            reviewRectificationSources.append(
                                resultImage.reviewRectificationSource
                            )
                            scannerMetadata.append(ChekinanaTemporaryScannerMetadata(
                                matchedIdolID: matchedIdolID,
                                userAppears: userAppears
                            ))
                            // ChekiEdgeFit-RT v2 intentionally performs no size
                            // classification. Every newly scanned/imported item is
                            // persisted as Mini regardless of source aspect ratio.
                            inferredSizes.append(.mini)
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
                    recognitionTasks.cancelAll()
                }
            } catch {
                progressGate.invalidate()
                recognitionTasks.cancelAll()
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
                    sourceIndex: sourceCount,
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
                reviewRectificationSources: reviewRectificationSources,
                refitOriginalSources: refitOriginalSources,
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
            try Task.checkCancellation()
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
            try Task.checkCancellation()
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
                includesUnassigned: candidates.includesUnassigned
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
        requestGate: ChekinanaDirectDateRequestGate?
    ) async -> DateRecognitionOutcome {
        guard let bounds else { return .notRequested }
        if bounds.scope == .fixed {
            return .completed(.notRequested)
        }
        do {
            try Task.checkCancellation()
            let state: ChekinanaChekiDateAnnotationState
            if let requestGate {
                state = try await requestGate.perform {
                    let imageData = try Self.scannerResultData(resultImage)
                    let image = ChekinanaPendingChekiImage(
                        data: imageData,
                        filenameExtension: resultImage.filenameExtension
                    )
                    return try await dateAnnotate(image)
                }
            } else {
                let imageData = try Self.scannerResultData(resultImage)
                let image = ChekinanaPendingChekiImage(
                    data: imageData,
                    filenameExtension: resultImage.filenameExtension
                )
                state = try await dateAnnotate(image)
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
            let descriptor = FetchDescriptor<MediaItem>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let chekis = try modelContext.fetch(descriptor)
                .filter { cheki in
                    guard cheki.kind == .cheki else { return false }
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

    private func editCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) async -> ChekinanaCommandResponse {
        let allowed = Set(["idol", "idols", "event", "date", "user", "userappears", "size", "note", "favorite"])
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

            let eventDate: Date?
            if let rawDate = command.arguments["date"] {
                eventDate = rawDate.trimmingCharacters(in: .whitespacesAndNewlines) == "-"
                    ? nil
                    : try parseCalendarDate(rawDate)
            } else {
                eventDate = cheki.date
            }
            let event: Event?
            if let rawEvent = command.arguments["event"] {
                event = rawEvent.trimmingCharacters(in: .whitespacesAndNewlines) == "-"
                    ? nil
                    : try resolveEvent(rawEvent)
            } else {
                event = cheki.event.flatMap { candidate in
                    ChekinanaChekiEventSelectionPolicy.includes(
                        recordDate: eventDate,
                        eventDate: candidate.date
                    ) ? candidate : nil
                }
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

            let favorite = try command.arguments["favorite"].map(requireStrictBool) ?? cheki.isFavorite
            var explicitlyEditedFields = Set<ChekinanaChekiEditableField>()
            if command.arguments["favorite"] != nil { explicitlyEditedFields.insert(.favorite) }
            if idolValue != nil { explicitlyEditedFields.insert(.idols) }
            if command.arguments["date"] != nil { explicitlyEditedFields.insert(.date) }
            if command.arguments["event"] != nil || event?.id != cheki.eventID {
                explicitlyEditedFields.insert(.event)
            }
            if userValue != nil { explicitlyEditedFields.insert(.userAppears) }
            if command.arguments["size"] != nil { explicitlyEditedFields.insert(.size) }
            if command.arguments["note"] != nil { explicitlyEditedFields.insert(.note) }
            let expectedSnapshot = ChekinanaChekiEditRecordSnapshot(cheki)
            let authorization = try await ChekinanaChekiEditCommitter.authorize(
                expected: expectedSnapshot,
                in: modelContext
            )

            let code = confirmationLedger.insert(.editCheki(.init(
                chekiID: cheki.id,
                expectedUpdatedAt: cheki.updatedAt,
                authorization: authorization,
                explicitlyEditedFields: explicitlyEditedFields,
                idolIDs: idols.map(\.id),
                eventID: event?.id,
                date: eventDate,
                userAppears: userAppears,
                size: size,
                isFavorite: favorite,
                hasPostedToSNS: cheki.hasPostedToSNS,
                note: note
            )))
            let keepsGroup = sameChekiGroup(
                idolIDs: cheki.idols.map(\.id),
                eventID: cheki.event?.id,
                eventDate: cheki.date,
                otherIdolIDs: idols.map(\.id),
                otherEventID: event?.id,
                otherEventDate: eventDate)
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
        let allowed = Set(["idols", "event", "date", "size"])
        guard Set(arguments.keys).isSubset(of: allowed) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        if kind != .cheki, arguments["size"] != nil {
            throw ChekinanaNLClientError.invalidSchema
        }
        if let kind, kind != .cheki, arguments["event"] != nil {
            throw ChekinanaNLClientError.invalidSchema
        }
        let requestedIdols = try arguments["idols"].map(resolveIdolList)
        let requestedIDs = requestedIdols.map { Set($0.map(\.id)) }
        let requestedEvent = try arguments["event"].map(resolveUniqueEvent)
        let requestedDate = try arguments["date"].map(parseCalendarDate)
        let requestedSize = try arguments["size"].map(requireRecordSize)
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()

        func matches(idolIDs: [UUID], eventID: UUID?, date: Date?) -> Bool {
            if let requestedIDs,
               !requestedIDs.isSubset(of: Set(idolIDs)) { return false }
            if let requestedEvent, eventID != requestedEvent.id { return false }
            if let requestedDate,
               date.map({ sameCalendarDate($0, requestedDate) }) != true { return false }
            return true
        }

        var lines: [String] = []
        if kind == nil || kind == .cheki {
            let values = try modelContext.fetch(
                FetchDescriptor<ChekiRecord>()
            ).filter {
                ChekinanaChekiRecordReadPolicy.isVisible(
                    $0,
                    hiddenIDs: hiddenIDs
                )
                    && matches(
                        idolIDs: $0.idolIDs,
                        eventID: $0.eventID,
                        date: $0.date
                    )
                    && (requestedSize == nil || $0.size == requestedSize)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            let relationshipIndex = ChekinanaChekiRecordRelationshipIndex(
                idols: try modelContext.fetch(FetchDescriptor<Idol>()),
                events: try modelContext.fetch(FetchDescriptor<Event>())
            )
            lines += values.map {
                recordSummary(
                    kind: .cheki,
                    id: $0.id,
                    idols: relationshipIndex.idols(for: $0),
                    event: relationshipIndex.event(for: $0),
                    date: $0.date,
                    size: $0.size,
                    note: $0.note,
                    count: $0.count
                )
            }
        }
        if kind == nil || kind == .shame {
            let values = try modelContext.fetch(FetchDescriptor<MediaItem>()).filter {
                $0.kind == .shame
                    && ChekinanaVisibilityPolicy.includesRecord(
                        idolIDs: $0.idolIDs,
                        hiddenIDs: hiddenIDs
                    )
                    && matches(
                        idolIDs: $0.idolIDs,
                        eventID: $0.eventID,
                        date: $0.date
                    )
            }
            let relationshipIndex = ChekinanaChekiRecordRelationshipIndex(
                idols: try modelContext.fetch(FetchDescriptor<Idol>()),
                events: try modelContext.fetch(FetchDescriptor<Event>())
            )
            lines += values.map {
                recordSummary(
                    kind: .shame,
                    id: $0.id,
                    idols: relationshipIndex.idols(for: $0),
                    event: relationshipIndex.event(for: $0),
                    date: $0.date,
                    note: $0.note
                )
            }
        }
        if kind == nil || kind == .douga {
            let values = try modelContext.fetch(FetchDescriptor<MediaItem>()).filter {
                $0.kind == .douga
                    && ChekinanaVisibilityPolicy.includesRecord(
                        idolIDs: $0.idolIDs,
                        hiddenIDs: hiddenIDs
                    )
                    && matches(
                        idolIDs: $0.idolIDs,
                        eventID: $0.eventID,
                        date: $0.date
                    )
            }
            let relationshipIndex = ChekinanaChekiRecordRelationshipIndex(
                idols: try modelContext.fetch(FetchDescriptor<Idol>()),
                events: try modelContext.fetch(FetchDescriptor<Event>())
            )
            lines += values.map {
                recordSummary(
                    kind: .douga,
                    id: $0.id,
                    idols: relationshipIndex.idols(for: $0),
                    event: relationshipIndex.event(for: $0),
                    date: $0.date,
                    note: $0.note
                )
            }
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
            let value = try resolveUniqueChekiRecord(target)
            return .text(recordSummary(
                kind: kind,
                id: value.id,
                idols: try refetchIdolsByIDs(value.idolIDs),
                event: try refetchEventByID(value.eventID),
                date: value.date,
                size: value.size,
                note: value.note,
                count: value.count
            ))
        case .shame:
            let value = try resolveUniqueShame(target)
            return .text(recordSummary(
                kind: kind,
                id: value.id,
                idols: try refetchIdolsByIDs(value.idolIDs),
                event: try refetchEventByID(value.eventID),
                date: value.date,
                note: value.note
            ))
        case .douga:
            let value = try resolveUniqueDouga(target)
            return .text(recordSummary(
                kind: kind,
                id: value.id,
                idols: try refetchIdolsByIDs(value.idolIDs),
                event: try refetchEventByID(value.eventID),
                date: value.date,
                note: value.note
            ))
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
        let allowed = Set(["idols", "event", "date", "note", "size", "count", "clear_fields"])
        guard Set(arguments.keys).isSubset(of: allowed),
              !(kind != .cheki && ["size", "count"].contains(where: { arguments[$0] != nil })) else {
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
        let clearFields = Set(arguments["clear_fields"]?.split(separator: ",").map(String.init) ?? [])
        let permittedClear = kind == .cheki
            ? Set(["idols", "event", "date", "note"])
            : Set(["idols", "event", "date", "note"])
        guard clearFields.isSubset(of: permittedClear),
              clearFields.isDisjoint(with: arguments.keys) else {
            throw ChekinanaNLClientError.invalidSchema
        }

        var idolIDs: [UUID] = []
        var eventID: UUID?
        var date: Date?
        var note = ""
        var size: ChekiSize?
        var count = 1
        var fingerprint: String?
        var chekiRecordSnapshot: ChekinanaChekiRecordSnapshot?

        switch (kind, mutation) {
        case (.cheki, .edit(let id)), (.cheki, .delete(let id)):
            let value = try refetchChekiRecordByID(id)
            idolIDs = value.idolIDs; eventID = value.eventID; date = value.date
            note = value.note; size = value.size; count = max(1, value.count)
            fingerprint = recordFingerprint(value)
            chekiRecordSnapshot = ChekinanaChekiRecordSnapshot(value)
        case (.shame, .edit(let id)), (.shame, .delete(let id)):
            let value = try refetchShameByID(id)
            idolIDs = value.idolIDs; eventID = value.eventID; date = value.date
            note = value.note; fingerprint = recordFingerprint(value)
        case (.douga, .edit(let id)), (.douga, .delete(let id)):
            let value = try refetchDougaByID(id)
            idolIDs = value.idolIDs; eventID = value.eventID; date = value.date
            note = value.note; fingerprint = recordFingerprint(value)
        case (_, .add):
            break
        }
        if clearFields.contains("idols") { idolIDs = [] }
        if clearFields.contains("event") { eventID = nil }
        if clearFields.contains("date") { date = nil }
        if clearFields.contains("note") { note = "" }
        if let value = arguments["idols"] { idolIDs = try resolveIdolList(value).map(\.id) }
        if let value = arguments["event"] { eventID = try resolveUniqueEvent(value).id }
        if let value = arguments["date"] { date = try parseCalendarDate(value) }
        if let value = arguments["note"] { note = value }
        if let value = arguments["size"] { size = try requireRecordSize(value) }
        if let value = arguments["count"] {
            guard let parsed = Int(value), (0...100).contains(parsed) else {
                throw ChekinanaNLClientError.invalidSchema
            }
            if case .add = mutation, parsed > 100 {
                throw ChekinanaNLClientError.invalidSchema
            }
            count = parsed
        }
        if case .add = mutation, count == 0 {
            throw ChekinanaNLClientError.invalidSchema
        }

        if kind == .cheki {
            if case .add = mutation,
               arguments["event"] == nil,
               !clearFields.contains("event"),
               !(assistantDialogue?.executingOperation?.slots.contextRef == "last_target" && assistantDialogue?.executingTarget?.reference.kind == .chekiRecord) {
                eventID = try uniqueEvent(for: date)?.id
            } else if arguments["event"] == nil,
                      !clearFields.contains("event"),
                      let currentEvent = try refetchEventByID(eventID),
                      !ChekinanaChekiEventSelectionPolicy.includes(
                          recordDate: date,
                          eventDate: currentEvent.date
                      ) {
                eventID = nil
            }
            if let selectedEvent = try refetchEventByID(eventID),
               !ChekinanaChekiEventSelectionPolicy.includes(
                   recordDate: date,
                   eventDate: selectedEvent.date
               ) {
                throw ChekinanaAddChekiError.eventOutsideDateWindow
            }
        }
        let payload = ChekinanaConfirmationLedger.RecordPayload(
            kind: kind,
            mutation: mutation,
            expectedFingerprint: fingerprint,
            idolIDs: idolIDs,
            eventID: eventID,
            date: normalizedCalendarDay(date),
            idx: nil,
            note: note,
            userAppears: nil,
            favorite: false,
            size: size,
            count: count,
            expectedChekiRecordSnapshot: chekiRecordSnapshot
        )
        let code = confirmationLedger.insert(.mutateRecord(payload))
        if assistantDialogue != nil, kind == .cheki {
            let people = try refetchIdolsByIDs(idolIDs).map(\.name).joined(separator: ", ")
            let day = date.map(ChekinanaDateOnly.string) ?? ChekinanaL10n.text("assistant.dialog.no_date", fallback: "No record date")
            let verb: String
            switch mutation {
            case .add: verb = ChekinanaL10n.format("assistant.dialog.preview_add", fallback: "Add %lld Cheki", Int64(count))
            case .edit: verb = ChekinanaL10n.format("assistant.dialog.preview_set_from", fallback: "Change this record from %1$lld to %2$lld Cheki", Int64(chekiRecordSnapshot?.count ?? count), Int64(count))
            case .delete: verb = ChekinanaL10n.format("assistant.dialog.preview_delete", fallback: "Delete this record and its %lld Cheki", Int64(count))
            }
            let details = [people, day, (try refetchEventByID(eventID))?.name, size?.rawValue, note.isEmpty ? nil : note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return .confirmationText(verb + "\n" + details, confirmationCode: code)
        }
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
        case .cheki: try resolveUniqueChekiRecord(token).id
        case .shame: try resolveUniqueShame(token).id
        case .douga: try resolveUniqueDouga(token).id
        }
    }

    private func resolveUniqueChekiRecord(
        _ token: String
    ) throws -> ChekiRecord {
        let normalized = token.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        let matches = try modelContext.fetch(FetchDescriptor<ChekiRecord>())
            .filter {
                $0.id.uuidString.lowercased().hasPrefix(normalized)
                    && ChekinanaChekiRecordReadPolicy.isVisible(
                        $0,
                        hiddenIDs: hiddenIDs
                    )
            }
        guard matches.count == 1, let value = matches.first else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    private func resolveUniqueShame(_ token: String) throws -> MediaItem {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = try modelContext.fetch(FetchDescriptor<MediaItem>()).filter {
            $0.kind == .shame
                && $0.id.uuidString.lowercased().hasPrefix(normalized)
                && ChekinanaVisibilityPolicy.includesRecord(
                    idolIDs: $0.idolIDs,
                    hiddenIDs: ChekinanaHiddenIdolPersistence.load()
                )
        }
        guard matches.count == 1, let value = matches.first else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    private func resolveUniqueDouga(_ token: String) throws -> MediaItem {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = try modelContext.fetch(FetchDescriptor<MediaItem>()).filter {
            $0.kind == .douga
                && $0.id.uuidString.lowercased().hasPrefix(normalized)
                && ChekinanaVisibilityPolicy.includesRecord(
                    idolIDs: $0.idolIDs,
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
        size: ChekiSize? = nil,
        note: String,
        count: Int? = nil
    ) -> String {
        let people = idols.map(\.name).joined(separator: ", ")
        let day = date.map(calendarDateString) ?? "—"
        let eventName = event?.name ?? "—"
        let sizeText = size.map { " · \($0.rawValue)" } ?? ""
        let quantity = count.map { " · ×\(max(1, $0))" } ?? ""
        let suffix = note.isEmpty ? "" : " · \(note)"
        let typeName = ChekinanaRecordKind(rawValue: kind.rawValue)?.title ?? kind.rawValue
        return "[\(String(id.uuidString.prefix(8)).lowercased())] \(typeName) · \(people.isEmpty ? "—" : people) · \(eventName) · \(day)\(sizeText)\(quantity)\(suffix)"
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

    private func resolveUniqueCheki(_ token: String) throws -> MediaItem {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let descriptor = FetchDescriptor<MediaItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        let chekis = try modelContext.fetch(descriptor).filter {
            $0.kind == .cheki
                && ChekinanaVisibilityPolicy.includesRecord(
                    idols: $0.idols,
                    hiddenIDs: hiddenIDs
                )
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

    private func shortChekiID(_ cheki: MediaItem) -> String {
        String(cheki.id.uuidString.prefix(8)).lowercased()
    }

    private func scanChekiOptions(from command: ChekinanaParsedCommand) throws -> ChekinanaScannerOptions {
        let scannerSize = try parseScannerSize(command.arguments["scanner_size"])
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
        try validateLegacyPatternThreshold(command.arguments["idol_threshold"])
        let candidates = idolRecognitionEnabled
            ? try parsePatternCandidates(command.arguments["candidates"])
            : nil

        return ChekinanaScannerOptions(
            expectedPolaroids: expected,
            scannerSize: scannerSize,
            postprocessMode: ChekinanaScannerPostprocessor.fixedMode,
            whiteBalance: whiteBalance,
            tightBoundaries: scanTightBoundaries ?? UserDefaults.standard.bool(forKey: ChekinanaScanBoundaryPreference.defaultsKey),
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
        _ value: String?
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
                includesUnassigned: true
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
            includesUnassigned: includesUnassigned
        )
    }

    private func validateLegacyPatternThreshold(_ value: String?) throws {
        guard let value else { return }
        guard let threshold = Double(value), threshold.isFinite,
              (0...1).contains(threshold) else {
            throw ChekinanaScanChekiError.invalidArgumentValue("idol_threshold", value)
        }
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
            detail: detail ?? .chekiCount(mediaItemCount(kind: .cheki, idolID: idol.id)),
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
        let mediaCount = try modelContext.fetch(FetchDescriptor<MediaItem>()).reduce(into: 0) {
            if $1.idolIDs.contains(idolID) { $0 += 1 }
        }
        let simpleRecordCount = try modelContext.fetch(
            FetchDescriptor<ChekiRecord>()
        ).reduce(into: 0) {
            if ChekinanaChekiRecordReadPolicy.containsIdol($1, idolID: idolID) {
                $0 += 1
            }
        }
        return mediaCount + simpleRecordCount
    }

    private func hasIdol(sourceId: String) throws -> Bool {
        var descriptor = FetchDescriptor<Idol>(predicate: #Predicate { $0.sourceId == sourceId })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func chekiCards(for idol: Idol) -> [ChekinanaChekiCard] {
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        return ((try? modelContext.fetch(FetchDescriptor<MediaItem>())) ?? [])
            .filter {
                $0.kind == .cheki
                    && $0.idolIDs.contains(idol.id)
                    &&
                ChekinanaVisibilityPolicy.includesRecord(
                    idolIDs: $0.idolIDs,
                    hiddenIDs: hiddenIDs
                )
            }
            .sorted { lhs, rhs in
                lhs.createdAt < rhs.createdAt
            }
            .map { chekiCard(for: $0) }
    }

    private func mediaItemCount(kind: MediaItemKind, idolID: UUID) -> Int {
        ((try? modelContext.fetch(FetchDescriptor<MediaItem>())) ?? []).reduce(into: 0) {
            if $1.kind == kind, $1.idolIDs.contains(idolID) { $0 += 1 }
        }
    }

    private func chekiCard(
        for cheki: MediaItem,
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
        // Reject a stale no-media record before performing any file I/O.
        let initialRecord = try validatedExistingAttachTarget(payload)
        let initialSize = payload.explicitlyEditedFields.contains(.size)
            ? (payload.size ?? .mini)
            : (initialRecord.size ?? .mini)
        var savedImageURL: URL?
        do {
            let prepared = try await ChekinanaReviewChekiImagePreparer.standardizedForSave(
                fallbackImage: payload.image,
                reviewSource: payload.reviewRectificationSource,
                rotationQuarterTurns: payload.reviewRotationQuarterTurns,
                size: initialSize
            )
            let savedImage = try await ChekinanaImageWorker.saveChekiImageData(
                prepared.data,
                id: payload.id,
                filenameExtension: "jpg"
            )
            savedImageURL = savedImage.url
            try Task.checkCancellation()

            // Image preparation can interleave with another local edit. The
            // record snapshot is revalidated immediately before the one save
            // that creates media and consumes exactly one quantity.
            let record = try validatedExistingAttachTarget(payload)
            let edited = payload.explicitlyEditedFields
            let effectiveIdols = edited.contains(.idols)
                ? idols : try refetchIdolsByIDs(record.idolIDs)
            let effectiveDate = edited.contains(.date)
                ? normalizedCalendarDay(payload.date) : record.date
            let effectiveEvent = (edited.contains(.event) || edited.contains(.date))
                ? event : record.event
            let effectiveSize = edited.contains(.size) ? payload.size : record.size
            let effectiveNote = edited.contains(.note) ? payload.note : record.note
            let persistedDate = try ChekinanaPersistedContentDatePolicy
                .validatedCanonical(effectiveDate)
            let effectiveIdx: Int?

                effectiveIdx = try nextChekiIndex(
                    idolIDs: effectiveIdols.map(\.id),
                    eventID: effectiveEvent?.id,
                    eventDate: effectiveDate,
                    isFavorite: payload.isFavorite,
                    excludingChekiID: nil
                )

            guard ChekinanaChekiIndexing.isValid(
                effectiveIdx,
                isFavorite: payload.isFavorite
            ) else {
                throw ChekinanaAddChekiError.indexOverflow
            }
            let cheki = MediaItem(
                id: payload.id,
                mediaOwnerID: payload.id,
                idols: effectiveIdols,
                event: effectiveEvent,
                date: persistedDate,
                idx: effectiveIdx,
                userAppears: payload.userAppears,
                size: effectiveSize,
                imageRef: savedImage.ref,
                isFavorite: payload.isFavorite,
                hasPostedToSNS: payload.hasPostedToSNS,
                note: effectiveNote,
                createdAt: payload.createdAt
            )
            modelContext.insert(cheki)
            try ChekinanaEventAssociationPropagation.propagate(
                from: cheki,
                in: modelContext
            )
            if let snapshot = payload.existingChekiRecordSnapshot {
                ChekinanaChekiRecordConsumptionPolicy.consume(
                    1,
                    from: record,
                    preserving: snapshot,
                    in: modelContext
                )
            }
            try modelContext.save()
            let preparedThumbnail = await ChekinanaImageWorker.thumbnailData(
                from: prepared.data
            )
            return .chekiCards([chekiCard(
                for: cheki,
                thumbnailImageData: preparedThumbnail ?? payload.thumbnailImageData
            )])
        } catch {
            modelContext.rollback()
            if let savedImageURL {
                await ChekinanaImageWorker.removeItemIfPresent(at: savedImageURL)
            }
            throw error
        }
    }

    private func validatedExistingAttachTarget(
        _ payload: ChekinanaConfirmationLedger.AddChekiPayload
    ) throws -> ChekiRecord {
        guard let targetID = payload.existingChekiID,
              let expectedSnapshot = payload.existingChekiRecordSnapshot,
              expectedSnapshot.id == targetID else {
            throw ChekinanaAddChekiError.duplicateCheki(payload.id.uuidString)
        }
        let record = try refetchChekiRecordByID(targetID)
        guard ChekinanaChekiRecordSnapshot(record) == expectedSnapshot else {
            throw ChekinanaEditConflictError.staleCheki(
                String(targetID.uuidString.prefix(8)).lowercased()
            )
        }
        guard record.count > 0,
              let existingDate = record.date,
              let selectedDate = payload.date,
              sameCalendarDate(existingDate, selectedDate),
              Set(record.idolIDs) == Set(payload.idolIDs),
              record.modelContext === modelContext else {
            throw ChekinanaAddChekiError.duplicateCheki(targetID.uuidString)
        }
        return record
    }

    private func persistCheki(
        id: UUID,
        image: ChekinanaPendingChekiImage,
        thumbnailImageData: Data?,
        reviewRectificationSource: ChekinanaReviewRectificationSource? = nil,
        reviewRotationQuarterTurns: Int = 0,
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
            guard ChekinanaChekiIndexing.isValid(idx, isFavorite: isFavorite) else {
                throw ChekinanaAddChekiError.indexOverflow
            }
            var duplicateDescriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })
            duplicateDescriptor.fetchLimit = 1
            guard try modelContext.fetch(duplicateDescriptor).isEmpty else {
                throw ChekinanaAddChekiError.duplicateCheki(id.uuidString)
            }

            let effectiveSize = size ?? .mini
            let prepared = try await ChekinanaReviewChekiImagePreparer.standardizedForSave(
                fallbackImage: image,
                reviewSource: reviewRectificationSource,
                rotationQuarterTurns: reviewRotationQuarterTurns,
                size: effectiveSize
            )
            let savedImage = try await ChekinanaImageWorker.saveChekiImageData(
                prepared.data,
                id: id,
                filenameExtension: "jpg"
            )
            savedImageURL = savedImage.url
            let persistedDate = try ChekinanaPersistedContentDatePolicy
                .validatedCanonical(normalizedCalendarDay(eventDate))
            let cheki = MediaItem(
                id: id,
                date: persistedDate,
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
            // Assigning `idols` or `event` in MediaItem.init creates those
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
            try ChekinanaEventAssociationPropagation.propagate(
                from: cheki,
                in: modelContext
            )
            try modelContext.save()
            let preparedThumbnail = await ChekinanaImageWorker.thumbnailData(
                from: prepared.data
            )
            return .chekiCards([chekiCard(
                for: cheki,
                thumbnailImageData: preparedThumbnail ?? thumbnailImageData
            )])
        } catch {
            modelContext.rollback()
            if let savedImageURL {
                await ChekinanaImageWorker.removeItemIfPresent(at: savedImageURL)
            }
            throw error
        }
    }

    private func refetchIdolsByIDs(
        _ ids: [UUID],
        preservingHiddenIDs: Set<UUID> = []
    ) throws -> [Idol] {
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
            guard preservingHiddenIDs.contains(idol.id)
                    || ChekinanaVisibilityPolicy.includesIdol(idol.id, hiddenIDs: hiddenIDs) else {
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

    private func refetchChekiByID(_ id: UUID) throws -> MediaItem {
        var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let cheki = try modelContext.fetch(descriptor).first,
              cheki.kind == .cheki,
              ChekinanaVisibilityPolicy.includesRecord(
                idolIDs: cheki.idols.map(\.id),
                hiddenIDs: ChekinanaHiddenIdolPersistence.load()
              ) else {
            throw ChekinanaDownloadChekiError.noCheki(id.uuidString)
        }
        return cheki
    }

    private func refetchChekiRecordByID(
        _ id: UUID,
        allowsSharedHiddenAssociations: Bool = false
    ) throws -> ChekiRecord {
        var descriptor = FetchDescriptor<ChekiRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first,
              (allowsSharedHiddenAssociations
                ? ChekinanaFourPageVisibilityPolicy.includesRecord(
                    idolIDs: record.idolIDs,
                    hiddenIDs: ChekinanaHiddenIdolPersistence.load()
                  )
                : ChekinanaChekiRecordReadPolicy.isVisible(
                    record,
                    hiddenIDs: ChekinanaHiddenIdolPersistence.load()
                  )) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return record
    }

    private func refetchShameByID(_ id: UUID) throws -> MediaItem {
        var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 2
        let values = try modelContext.fetch(descriptor)
        guard values.count == 1, let value = values.first,
              value.kind == .shame,
              ChekinanaVisibilityPolicy.includesRecord(
                idolIDs: value.idols.map(\.id),
                hiddenIDs: ChekinanaHiddenIdolPersistence.load()
              ) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    private func refetchDougaByID(_ id: UUID) throws -> MediaItem {
        var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 2
        let values = try modelContext.fetch(descriptor)
        guard values.count == 1, let value = values.first,
              value.kind == .douga,
              ChekinanaVisibilityPolicy.includesRecord(
                idolIDs: value.idols.map(\.id),
                hiddenIDs: ChekinanaHiddenIdolPersistence.load()
              ) else {
            throw ChekinanaNLClientError.invalidSchema
        }
        return value
    }

    private func recordFingerprint(_ value: MediaItem) -> String {
        [
            value.id.uuidString,
            value.kind.rawValue,
            value.idolIDs.map(\.uuidString).sorted().joined(separator: ","),
            value.eventID?.uuidString ?? "",
            value.date.map(ChekinanaDateOnly.string) ?? "",
            value.idx.map(String.init) ?? "",
            value.note,
            value.userAppears ? "1" : "0",
            value.isFavorite ? "1" : "0",
            value.hasPostedToSNS ? "1" : "0",
            value.size?.rawValue ?? "",
            value.mediaRef,
            String(value.updatedAt.timeIntervalSince1970.bitPattern),
        ].joined(separator: "\u{1f}")
    }

    private func recordFingerprint(_ value: ChekiRecord) -> String {
        [
            value.id.uuidString,
            value.idolIDs.map(\.uuidString).sorted().joined(separator: ","),
            value.eventID?.uuidString ?? "",
            value.date.map(ChekinanaDateOnly.string) ?? "",
            value.note,
            value.size?.rawValue ?? "",
            String(max(1, value.count)),
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
        guard !ChekinanaLocalEntityMatch.key(token).isEmpty else { throw ChekinanaAddChekiError.noIdol(token) }
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
            ChekinanaLocalEntityMatch.contains(idol.name, query: token)
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
        guard !ChekinanaLocalEntityMatch.key(token).isEmpty else { throw ChekinanaEventError.notFound(token) }
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let events = try modelContext.fetch(FetchDescriptor<Event>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        ))
        let idMatches = events.filter { $0.id.uuidString.lowercased().hasPrefix(normalizedToken) }
        if idMatches.count > 1 { throw ChekinanaEventError.ambiguous(token) }
        if let event = idMatches.first { return event }

        let exactNameMatches = events.filter {
            ChekinanaLocalEntityMatch.equal($0.name, token)
        }
        if exactNameMatches.count > 1 { throw ChekinanaEventError.ambiguous(token) }
        if let event = exactNameMatches.first { return event }

        let nameMatches = events.filter {
            ChekinanaLocalEntityMatch.contains($0.name, query: token)
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
            ChekinanaLocalEntityMatch.equal($0.name, rawValue)
        }
        if exactNameMatches.count > 1 {
            throw ChekinanaAddChekiError.ambiguousEvent(rawValue)
        }
        if let event = exactNameMatches.first { return event }

        let nameMatches = events.filter {
            ChekinanaLocalEntityMatch.contains($0.name, query: rawValue)
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
        let normalizedName = ChekinanaLocalEntityMatch.key(name)
        let events = try modelContext.fetch(FetchDescriptor<Event>())
        let duplicate = events.contains { event in
            let sameName = !normalizedName.isEmpty && ChekinanaLocalEntityMatch.key(event.name) == normalizedName
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
        // Media is the only required MediaItem field. Associations remain optional
        // and can be filled later by scan review or the editor.
        _ = (idols, allowEmptyIdols, allowMissingOccasion)
        if let event,
           !ChekinanaChekiEventSelectionPolicy.includes(
               recordDate: eventDate,
               eventDate: event.date
           ) {
            throw ChekinanaAddChekiError.eventOutsideDateWindow
        }
    }

    private func sameChekiGroup(
        idolIDs: [UUID],
        eventID: UUID?,
        eventDate: Date?,
        otherIdolIDs: [UUID],
        otherEventID: UUID?,
        otherEventDate: Date?) -> Bool {
        ChekinanaChekiGroupKey(idolIDs: idolIDs, date: eventDate)
            == ChekinanaChekiGroupKey(
                idolIDs: otherIdolIDs,
                date: otherEventDate)
    }

    private func nextChekiIndex(
        idolIDs: [UUID],
        eventID: UUID?,
        eventDate: Date?,
        isFavorite: Bool,
        excludingChekiID: UUID?
    ) throws -> Int? {
        guard let group = ChekinanaChekiGroupKey(idolIDs: idolIDs, date: eventDate) else {
            throw ChekinanaAddChekiError.indexOverflow
        }
        let chekis = try modelContext.fetch(FetchDescriptor<MediaItem>()).filter {
            $0.kind == .cheki
        }
        let snapshots = chekis.compactMap { cheki -> ChekinanaChekiIndexSnapshot? in
            guard let chekiGroup = ChekinanaChekiGroupKey(
                idolIDs: cheki.idolIDs,
                date: cheki.date) else {
                return nil
            }
            return .init(
                chekiID: cheki.id,
                group: chekiGroup,
                idx: cheki.idx,
                isFavorite: cheki.isFavorite,
                createdAt: cheki.createdAt
            )
        }
        do {
            return try ChekinanaChekiIndexing.nextIndex(
                for: group,
                isFavorite: isFavorite,
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

        let normalized = value.lowercased()
        guard [ChekiSize.mini.rawValue, ChekiSize.wide.rawValue].contains(normalized),
              let size = ChekiSize(rawValue: normalized) else {
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
        let schedule = (try? ChekinanaEventSchedulePersistence.value(
            for: event.id,
            in: modelContext
        )) ?? .empty
        return ChekinanaEventCard(
            id: event.id,
            name: event.name,
            date: event.date.map(calendarDateString) ?? "",
            city: event.city ?? "",
            livehouse: event.resolvedLivehouse ?? "",
            price: event.price ?? "",
            weiboURL: event.weiboURL?.absoluteString ?? "",
            ticketURL: event.ticketURL?.absoluteString ?? "",
            openTime: schedule.openTime,
            startTime: schedule.startTime,
            note: event.note,
            confirmationCode: nil
        )
    }

    private func eventCard(_ fields: ChekinanaEventCandidateFields, confirmationCode: String) -> ChekinanaEventCard {
        ChekinanaAssistantEventFlow.previewCard(fields, confirmationCode: confirmationCode)
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
        parts.append(ChekinanaCommandCopy.format("field.city", fallback: "City: %@", ChekinanaEventCity.displayed(event.city) ?? unset))
        parts.append(ChekinanaCommandCopy.format("field.livehouse", fallback: "Livehouse: %@", event.resolvedLivehouse ?? unset))
        let schedule = try? ChekinanaEventSchedulePersistence.value(
            for: event.id,
            in: modelContext
        )
        if let timeSummary = ChekinanaEventTime.summary(
            openTime: schedule?.openTime,
            startTime: schedule?.startTime
        ) {
            parts.append(timeSummary)
        }
        parts.append(ChekinanaCommandCopy.format("field.weibo", fallback: "Weibo: %@", event.weiboURL?.absoluteString ?? unset))
        parts.append(ChekinanaCommandCopy.format("field.ticket", fallback: "Ticket: %@", event.ticketURL?.absoluteString ?? unset))
        parts.append(ChekinanaCommandCopy.format("field.note", fallback: "Note: %@", event.note.isEmpty ? unset : event.note))
        return parts.joined(separator: " · ")
    }

    private func eventMetadataPreview(city: String?, livehouse: String?, price: String?, ticketURL: URL?, note: String) -> String {
        let unset = ChekinanaCommandCopy.text("value.unset", fallback: "Not set")
        return [
            ChekinanaCommandCopy.format("field.city", fallback: "City: %@", ChekinanaEventCity.displayed(city) ?? unset),
            ChekinanaCommandCopy.format("field.livehouse", fallback: "Venue: %@", livehouse ?? unset),
            ChekinanaCommandCopy.format("field.price", fallback: "Price: %@", price ?? unset),
            ChekinanaCommandCopy.format("field.ticket", fallback: "Ticket: %@", ticketURL?.absoluteString ?? unset),
            ChekinanaCommandCopy.format("field.note", fallback: "Note: %@", note.isEmpty ? unset : note),
        ].joined(separator: "\n")
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

    private func chekiDetails(_ cheki: MediaItem, prefix: String? = nil) -> String {
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
            "clear  " + ChekinanaL10n.message("(clears visible command history only)"),
            "confirm [8_hex_code] " + ChekinanaL10n.message("(no code confirms the latest unambiguous operation)"),
            "cancel <8_hex_code>",
            "cancel all",
            "addidol <idol_name>",
            "listidol",
            "showidol <idol_id|name>",
            "editidol <candidate_code|idol_id> <field>=<value> [...]  " + ChekinanaL10n.message("fields: name, group, birthday, color, verification, bio, avatar; use - to clear optional fields"),
            "deleteidol <idol_id>",
            "addevent <url> name=<name> date=YYYY-MM-DD | addevent <name> date=YYYY-MM-DD",
            "listevent",
            "showevent <event_id|name>",
            "editevent <event_id|name> [name=<name>] [date=YYYY-MM-DD|-] [url=<url>|-]",
            "deleteevent <event_id|name>",
            "scancheki  " + ChekinanaL10n.message("(starts the managed backend when needed, then processes selected photos into temporary Cheki)"),
            "discardcheki <temporary_cheki_id|all>",
            "addcheki [idol=<idol_id_or_name[,idol_id_or_name...]>] [event=<event_id>] [date=YYYY-MM-DD] [user=true|false|?] [size=mini|wide|?] [note=<text>]  " + ChekinanaL10n.message("(uses selected album photos; metadata is optional; idx is assigned once idol and date exist)"),
            "addscancheki <temporary_cheki_id[,temporary_cheki_id...]|all> [idol=<idol_id_or_name[,idol_id_or_name...]>] [date=YYYY-MM-DD] [event=<event_id>] [user=true|false|?] [size=mini|wide|?] [note=<text>]",
            "listcheki [idol=<idol_id_or_name>] [event=<event_id|?>] [date=YYYY-MM-DD]",
            "showcheki <cheki_id>",
            "editcheki <cheki_id> [idol=<idol[,idol...]>|-] [date=YYYY-MM-DD|-] [event=<event_id>|-] [user=true|false|?] [size=mini|wide|?] [note=<text>]",
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
                ChekinanaL10n.message("fields: name, group, birthday, color, verification, bio, avatar (avatar_url is accepted as an alias)"),
                ChekinanaL10n.message("use - to clear an optional field; quote values containing spaces"),
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
                ChekinanaL10n.message("creating an Event requires confirmation"),
            ],
            "listevent": [
                "listevent",
            ],
            "showevent": [
                "showevent <event_id|name>",
            ],
            "editevent": [
                "editevent <event_id|name> [name=<name>] [date=YYYY-MM-DD|-] [url=<http(s)_url>|-]",
                ChekinanaL10n.message("provide at least one field; use - to clear optional date/url"),
            ],
            "deleteevent": [
                "deleteevent <event_id|name>",
                ChekinanaL10n.text("assistant.dialog.delete_event_scope", fallback: "Deleting an Event keeps its Cheki and removes their Event link, along with the Event’s own data."),
            ],
            "addcheki": [
                "addcheki [idol=<idol_id_or_name[,idol_id_or_name...]>] [event=<event_id>] [date=YYYY-MM-DD] [user=true|false|?] [size=mini|wide|?] [note=<text>]",
                ChekinanaL10n.message("uses selected album photos; idol, event, date, and other metadata are optional; this command never uses scancheki temporary objects"),
                ChekinanaL10n.message("idx is assigned only after both idol and date exist"),
            ],
            "addscancheki": [
                "addscancheki <temporary_cheki_id[,temporary_cheki_id...]|all> [idol=<idol_id_or_name[,idol_id_or_name...]>] [date=YYYY-MM-DD] [event=<event_id>] [user=true|false|?] [size=mini|wide|?] [note=<text>]",
                ChekinanaL10n.message("temporary objects are consumed only after successful confirmation; idx is assigned on confirm"),
            ],
            "scancheki": [
                "scancheki [expected=<positive_int>] [scanner_size=auto|mini|wide] [wb=true|false] [sleeves=true|false] [direct=true|false]",
                ChekinanaL10n.message("select one or more photos first; scanner results remain temporary until addscancheki is confirmed"),
            ],
            "discardcheki": [
                "discardcheki <temporary_cheki_id|all>",
                ChekinanaL10n.message("temporary images referenced by pending addscancheki confirmations are retained; confirm or cancel first"),
            ],
            "downloadtemporarycheki": [
                "downloadtemporarycheki <temporary_cheki_id>",
                ChekinanaL10n.message("saves the clean temporary image without a bbox overlay"),
            ],
            "listcheki": [
                "listcheki [idol=<idol_id_or_name>] [event=<event_id|?>] [date=YYYY-MM-DD]",
            ],
            "showcheki": [
                "showcheki <cheki_id>",
            ],
            "editcheki": [
                "editcheki <cheki_id> [idol=<idol_id_or_name[,idol_id_or_name...]>|-] [date=YYYY-MM-DD|-] [event=<event_id>|-] [user=true|false|?] [size=mini|wide|?] [note=<text>]",
                ChekinanaL10n.message("provide at least one field; changing Idol/Event/date assigns the next group idx on confirm"),
                ChekinanaL10n.message("use ? or - to clear user/size and - to clear note"),
            ],
            "downloadcheki": [
                "downloadcheki <cheki_id>",
            ],
            "deletecheki": [
                "deletecheki <cheki_id>",
            ],
            "listrecord": [
                "listrecord [cheki|shame|douga] [idols=<refs>] [date=YYYY-MM-DD] [event=<ref> for Cheki only] [size=mini|wide for Cheki only]",
            ],
            "showrecord": [
                "showrecord <cheki|shame|douga> target=<record_ref>",
            ],
            "addrecord": [
                "addrecord cheki [idols=<refs>] [date=YYYY-MM-DD] [event=<ref>] [size=mini|wide] [note=<text>] [count=1..100]",
            ],
            "editrecord": [
                "editrecord cheki target=<record_ref> [idols=<refs>] [date=YYYY-MM-DD] [event=<ref>] [size=mini|wide] [note=<text>] [count=<nonnegative_integer>] [clear_fields=idols,event,date,size,note]",
                ChekinanaL10n.message("setting count=0 deletes the simple Cheki record"),
                ChekinanaL10n.message("Shame and Douga retain only their existing idols/date/note edit support."),
            ],
            "deleterecord": [
                "deleterecord <cheki|shame|douga> target=<record_ref>",
            ],
        ]
    }
}

struct SavedChekiImage: Sendable {
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
        session: URLSession = ChekinanaBoundedRemoteImageDownloader.makeSession(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        download = { request in
            do {
                return try await ChekinanaBoundedImageDownload.download(
                    for: request, session: session, maximumByteCount: Self.maximumBodySize,
                    temporaryDirectory: temporaryDirectory,
                    validateResponse: Self.validateResponse
                )
            } catch ChekinanaBoundedImageDownload.DownloadError.bodyTooLarge {
                throw DownloadError.bodyTooLarge
            }
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

    private static func validateResponse(_ response: URLResponse) throws {
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
    }

    func data(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (temporaryURL, response) = try await download(request)
        defer {
            if !ChekinanaBoundedImageDownload.removeTemporaryFileIfOwned(temporaryURL) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        try Task.checkCancellation()
        try Self.validateResponse(response)
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

struct ChekinanaThumbnailLoadIdentity: Hashable, Sendable {
    let sourceKey: String
    let imageReference: String
    let revision: UInt64
}

@MainActor
final class ChekinanaThumbnailRevisionStore: ObservableObject {
    static let shared = ChekinanaThumbnailRevisionStore()

    @Published private(set) var changeCount: UInt64 = 0
    private var revisions: [String: UInt64] = [:]

    func identity(
        imageRef: String?,
        sourceKey: String
    ) -> ChekinanaThumbnailLoadIdentity {
        let normalizedRef = Self.normalizedReference(imageRef)
        return ChekinanaThumbnailLoadIdentity(
            sourceKey: sourceKey,
            imageReference: normalizedRef,
            revision: revisions[normalizedRef, default: 0]
        )
    }

    func invalidate(imageRef: String?) {
        let normalizedRef = Self.normalizedReference(imageRef)
        guard normalizedRef != "<nil>" else { return }
        revisions[normalizedRef, default: 0] &+= 1
        changeCount &+= 1
    }

    private static func normalizedReference(_ imageRef: String?) -> String {
        imageRef?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyValue ?? "<nil>"
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

    func thumbnailImage(
        forEventAvatarRef imageRef: String?,
        key sourceKey: String,
        maxDimension: Int = 256
    ) async -> ChekinanaRenderedImage? {
        // Event references are validated without trimming; do not alias an
        // invalid padded reference to a previously cached valid filename.
        let key = "event-avatar|\(sourceKey)|\(imageRef ?? "<nil>")|\(maxDimension)"
        return await cachedImage(for: key) {
            await ChekinanaImageWorker.thumbnailImage(
                fromEventAvatarRef: imageRef, maxDimension: maxDimension
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

    func invalidate(sourceKey: String) {
        let marker = "|\(sourceKey)|"
        let matchingKeys = entries.keys.filter { $0.contains(marker) }
        for key in matchingKeys {
            entries[key] = nil
            accessOrder.removeAll { $0 == key }
        }
        let matchingTasks = inFlight.keys.filter { $0.contains(marker) }
        for key in matchingTasks {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
    }

    func invalidate(imageRef: String?) async {
        guard let imageRef = imageRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imageRef.isEmpty else { return }
        let marker = "|\(imageRef)|"
        let matchingKeys = entries.keys.filter { $0.contains(marker) }
        for key in matchingKeys {
            entries[key] = nil
            accessOrder.removeAll { $0 == key }
        }
        let matchingTasks = inFlight.keys.filter { $0.contains(marker) }
        for key in matchingTasks {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
        await ChekinanaThumbnailRevisionStore.shared.invalidate(imageRef: imageRef)
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

    static func accepts(source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return false
        }
        return accepts(properties: properties)
    }

    static func accepts(source: CGImageSource, maxDimension: Int) -> Bool {
        guard (1...maximumThumbnailDimension).contains(maxDimension),
              accepts(source: source) else {
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
        fromEventAvatarRef imageRef: String?,
        maxDimension: Int = 256
    ) async -> ChekinanaRenderedImage? {
        await performDecode {
            guard let imageRef, ChekinanaEventAvatarStore.isManaged(imageRef),
                  let directory = try? ChekiImageRefResolver.chekiImagesDirectory(),
                  let url = ChekinanaEventMediaReference.localFileURL(
                    for: imageRef, directory: directory
                  ),
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
            guard let source = makeImageSource(from: imageData),
                  ChekinanaImageSourceValidator.accepts(source: source) else {
                return nil
            }
            let exifOrientation = ChekinanaImageSourceValidator
                .effectiveExifOrientation(source: source)
            guard let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary),
                  let image = normalizedImageOrientation(
                    decodedImage,
                    exifOrientation: exifOrientation
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
                image,
                [
                    kCGImageDestinationLossyCompressionQuality: 0.92,
                    kCGImagePropertyOrientation: 1,
                ] as CFDictionary
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

    static func saveChekiImageData(
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
        let swapsDimensions = (5...8).contains(exifOrientation)
        let width = swapsDimensions ? image.height : image.width
        let height = swapsDimensions ? image.width : image.height
        guard width > 0,
              height > 0,
              max(width, height) <= maxDimension + 1 else {
            return nil
        }
        return normalizedImageOrientation(
            image,
            exifOrientation: exifOrientation
        )
    }

    static func normalizedImageOrientation(
        _ image: CGImage,
        exifOrientation: Int
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
        guard width > 0, height > 0 else { return nil }

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

enum ChekinanaChekiDeletionError: LocalizedError, Equatable {
    case changedRecord
    case recoveryRequired
    case invalidJournal
    case databaseCommitNotObserved
    case legacyEvidenceUnavailable

    var errorDescription: String? {
        switch self {
        case .changedRecord:
            ChekinanaL10n.message("The Cheki changed. Reopen it and try deleting again.")
        case .recoveryRequired, .invalidJournal:
            ChekinanaL10n.message("Cheki deletion recovery is incomplete. Retry recovery before changing the library.")
        case .databaseCommitNotObserved:
            ChekinanaL10n.message("The Cheki deletion was not saved. Its previous media was restored.")
        case .legacyEvidenceUnavailable:
            ChekinanaL10n.message("The Cheki was deleted, but an older media recovery file is still protected because its ownership cannot be confirmed.")
        }
    }
}

struct ChekinanaChekiDeletionJournal: Codable, Equatable, Sendable {
    let formatVersion: Int
    let operationID: UUID
    let libraryGeneration: UUID
    let recordBefore: ChekinanaChekiEditRecordSnapshot
    let originalFilename: String?
    let quarantineFilename: String
    // nil means the operation owns no file (missing, unmanaged, or shared).
    let identity: ChekinanaImportFileIdentity?
    let restorationOnly: Bool

    var isValid: Bool {
        guard formatVersion == 1,
              let parsed = Self.parseQuarantine(quarantineFilename),
              parsed.recordID == recordBefore.id,
              parsed.operationID == operationID,
              originalFilename == Self.managedFilename(for: recordBefore),
              identity?.isValid != false else { return false }
        return identity == nil || originalFilename != nil
    }

    static func managedFilename(for record: ChekinanaChekiEditRecordSnapshot) -> String? {
        let value = record.mediaRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value == URL(fileURLWithPath: value).lastPathComponent,
              URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(record.mediaOwnerID.uuidString) == .orderedSame else {
            return nil
        }
        return value
    }

    static func parseQuarantine(_ filename: String) -> (recordID: UUID, operationID: UUID)? {
        let prefix = ".delete-", suffix = ".quarantine"
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        let body = String(filename.dropFirst(prefix.count).dropLast(suffix.count))
        guard body.count == 73 else { return nil }
        let separator = body.index(body.startIndex, offsetBy: 36)
        guard body[separator] == "-",
              let recordID = UUID(uuidString: String(body.prefix(36))),
              let operationID = UUID(uuidString: String(body.suffix(36))) else { return nil }
        return (recordID, operationID)
    }
}

enum ChekinanaChekiDeletionJournalStore {
    static let filenamePrefix = ".cheki-delete-intent-"
    static let filenameSuffix = ".json"

    private static func validateDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ChekinanaChekiDeletionError.invalidJournal
        }
    }

    static func journalURL(operationID: UUID, in directory: URL) -> URL {
        directory.standardizedFileURL.appendingPathComponent(
            filenamePrefix + operationID.uuidString.lowercased() + filenameSuffix
        )
    }

    static func persist(_ journal: ChekinanaChekiDeletionJournal, in directory: URL) throws {
        guard journal.isValid else { throw ChekinanaChekiDeletionError.invalidJournal }
        try validateDirectory(directory)
        let url = journalURL(operationID: journal.operationID, in: directory)
        guard try identity(at: url, in: directory) == nil else {
            throw ChekinanaChekiDeletionError.invalidJournal
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: url, options: [.atomic])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        guard try load(from: url, in: directory) == journal else {
            throw ChekinanaChekiDeletionError.invalidJournal
        }
    }

    static func discover(in directory: URL) throws -> [ChekinanaChekiDeletionJournal] {
        try validateDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        var result: [ChekinanaChekiDeletionJournal] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(filenamePrefix) {
            let name = entry.lastPathComponent
            guard name.hasSuffix(filenameSuffix),
                  let operationID = UUID(uuidString: String(
                    name.dropFirst(filenamePrefix.count).dropLast(filenameSuffix.count)
                  )), journalURL(operationID: operationID, in: directory).lastPathComponent == name else {
                throw ChekinanaChekiDeletionError.invalidJournal
            }
            result.append(try load(from: entry, in: directory))
        }
        guard Set(result.map(\.recordBefore.id)).count == result.count else {
            throw ChekinanaChekiDeletionError.invalidJournal
        }
        return result.sorted { $0.operationID.uuidString < $1.operationID.uuidString }
    }

    static func load(from url: URL, in directory: URL) throws -> ChekinanaChekiDeletionJournal {
        guard try identity(at: url, in: directory) != nil else {
            throw ChekinanaChekiDeletionError.invalidJournal
        }
        let journal = try JSONDecoder().decode(ChekinanaChekiDeletionJournal.self,
            from: Data(contentsOf: url))
        guard journal.isValid,
              journalURL(operationID: journal.operationID, in: directory).standardizedFileURL
                == url.standardizedFileURL else { throw ChekinanaChekiDeletionError.invalidJournal }
        return journal
    }

    static func discard(_ journal: ChekinanaChekiDeletionJournal, in directory: URL,
        removeItem: (URL) throws -> Void) throws {
        let url = journalURL(operationID: journal.operationID, in: directory)
        guard try load(from: url, in: directory) == journal else {
            throw ChekinanaChekiDeletionError.invalidJournal
        }
        try removeItem(url)
        guard try identity(at: url, in: directory) == nil else {
            throw ChekinanaChekiDeletionError.recoveryRequired
        }
    }

    static func identity(at url: URL, in directory: URL) throws -> ChekinanaImportFileIdentity? {
        try validateDirectory(directory)
        guard url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else {
            throw ChekinanaChekiDeletionError.invalidJournal
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ChekinanaChekiDeletionError.recoveryRequired
        }
        return try ChekinanaImportFileIdentity.inspect(url)
    }
}

@MainActor
enum ChekinanaChekiDeletionRecovery {
    enum Direction: Equatable { case restoreRecord, completeDeletion }
    struct Report {
        var completedRecordIDs: Set<UUID> = []
        var restoredRecordIDs: Set<UUID> = []
        var protectedLegacyRecordIDs: Set<UUID> = []
        var protectedLegacyFileCount = 0
    }

    @discardableResult
    static func recoverUnfinishedDeletion(in context: ModelContext, directory: URL? = nil) throws -> Report {
        try ChekinanaPersistenceMutationCoordinator.withLock {
            try recoverExclusively(in: context, directory: directory)
        }
    }

    @discardableResult
    static func recoverExclusively(in context: ModelContext, directory: URL? = nil,
        moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws -> Report {
        let directory = try directory ?? ChekiImageRefResolver.chekiImagesDirectory()
        var report = Report()
        for journal in try ChekinanaChekiDeletionJournalStore.discover(in: directory) {
            switch try recover(journal, in: context, directory: directory,
                moveItem: moveItem, removeItem: removeItem) {
            case .restoreRecord: report.restoredRecordIDs.insert(journal.recordBefore.id)
            case .completeDeletion: report.completedRecordIDs.insert(journal.recordBefore.id)
            }
        }
        try recoverLegacy(in: context, directory: directory, report: &report,
            moveItem: moveItem, removeItem: removeItem)
        return report
    }

    static func direction(for journal: ChekinanaChekiDeletionJournal,
        in context: ModelContext, directory: URL) throws -> Direction {
        let fresh = ModelContext(context.container)
        guard try ChekinanaLibraryGenerationStore.current(in: fresh) == journal.libraryGeneration else {
            throw ChekinanaChekiDeletionError.recoveryRequired
        }
        let matches = try fresh.fetch(FetchDescriptor<MediaItem>()).filter { $0.id == journal.recordBefore.id }
        guard matches.count <= 1 else { throw ChekinanaChekiDeletionError.recoveryRequired }
        if let record = matches.first {
            guard record.kind == .cheki,
                  ChekinanaChekiEditRecordSnapshot(record) == journal.recordBefore else {
                throw ChekinanaChekiDeletionError.recoveryRequired
            }
            return .restoreRecord
        }
        guard !journal.restorationOnly else { throw ChekinanaChekiDeletionError.recoveryRequired }
        if journal.identity != nil {
            let current = try ChekinanaLibraryFileReferenceSnapshot.capture(in: fresh, directory: directory)
            guard !current.referencedFilenames.contains(journal.quarantineFilename),
                  !(journal.originalFilename.map(current.referencedFilenames.contains) ?? false) else {
                throw ChekinanaChekiDeletionError.recoveryRequired
            }
        }
        return .completeDeletion
    }

    @discardableResult
    static func recover(_ journal: ChekinanaChekiDeletionJournal, in context: ModelContext,
        directory: URL, moveItem: (URL, URL) throws -> Void,
        removeItem: (URL) throws -> Void) throws -> Direction {
        let result = try direction(for: journal, in: context, directory: directory)
        if result == .restoreRecord { context.rollback() }
        let quarantine = directory.appendingPathComponent(journal.quarantineFilename)
        let quarantineIdentity = try ChekinanaChekiDeletionJournalStore.identity(at: quarantine, in: directory)
        if let expected = journal.identity, let filename = journal.originalFilename {
            let original = directory.appendingPathComponent(filename)
            let originalIdentity = try ChekinanaChekiDeletionJournalStore.identity(at: original, in: directory)
            guard (originalIdentity == nil || originalIdentity == expected),
                  (quarantineIdentity == nil || quarantineIdentity == expected) else {
                throw ChekinanaChekiDeletionError.recoveryRequired
            }
            switch result {
            case .restoreRecord:
                guard originalIdentity != nil || quarantineIdentity != nil else {
                    throw ChekinanaChekiDeletionError.recoveryRequired
                }
                if originalIdentity == nil {
                    guard try direction(for: journal, in: context, directory: directory) == .restoreRecord else {
                        throw ChekinanaChekiDeletionError.recoveryRequired
                    }
                    try moveItem(quarantine, original)
                    guard try ChekinanaChekiDeletionJournalStore.identity(at: original, in: directory) == expected else {
                        throw ChekinanaChekiDeletionError.recoveryRequired
                    }
                }
                if try ChekinanaChekiDeletionJournalStore.identity(at: quarantine, in: directory) == expected {
                    guard try direction(for: journal, in: context, directory: directory) == .restoreRecord,
                          try ChekinanaChekiDeletionJournalStore.identity(at: original, in: directory) == expected else {
                        throw ChekinanaChekiDeletionError.recoveryRequired
                    }
                    try removeItem(quarantine)
                    guard try ChekinanaChekiDeletionJournalStore.identity(at: quarantine, in: directory) == nil else {
                        throw ChekinanaChekiDeletionError.recoveryRequired
                    }
                }
            case .completeDeletion:
                for url in [original, quarantine] {
                    if let identity = try ChekinanaChekiDeletionJournalStore.identity(at: url, in: directory) {
                        guard identity == expected,
                              try direction(for: journal, in: context, directory: directory) == .completeDeletion else {
                            throw ChekinanaChekiDeletionError.recoveryRequired
                        }
                        try removeItem(url)
                        guard try ChekinanaChekiDeletionJournalStore.identity(at: url, in: directory) == nil else {
                            throw ChekinanaChekiDeletionError.recoveryRequired
                        }
                    }
                }
            }
        } else {
            guard quarantineIdentity == nil else { throw ChekinanaChekiDeletionError.recoveryRequired }
        }
        try ChekinanaChekiDeletionJournalStore.discard(journal, in: directory, removeItem: removeItem)
        return result
    }

    private static func recoverLegacy(in context: ModelContext, directory: URL, report: inout Report,
        moveItem: (URL, URL) throws -> Void, removeItem: (URL) throws -> Void) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let candidates = files.compactMap { url -> (URL, UUID, UUID)? in
            guard let parsed = ChekinanaChekiDeletionJournal.parseQuarantine(url.lastPathComponent) else { return nil }
            return (url, parsed.recordID, parsed.operationID)
        }
        for (recordID, group) in Dictionary(grouping: candidates, by: { $0.1 }) {
            let fresh = ModelContext(context.container)
            let records = try fresh.fetch(FetchDescriptor<MediaItem>()).filter { $0.id == recordID && $0.kind == .cheki }
            guard records.count == 1 else {
                report.protectedLegacyRecordIDs.insert(recordID)
                report.protectedLegacyFileCount += group.count
                continue
            }
            let record = ChekinanaChekiEditRecordSnapshot(records[0])
            guard let originalName = ChekinanaChekiDeletionJournal.managedFilename(for: record) else {
                report.protectedLegacyRecordIDs.insert(recordID)
                report.protectedLegacyFileCount += group.count
                continue
            }
            let original = directory.appendingPathComponent(originalName)
            let originalIdentity = try ChekinanaChekiDeletionJournalStore.identity(at: original, in: directory)
            guard group.count == 1 else {
                if originalIdentity == nil { throw ChekinanaChekiDeletionError.recoveryRequired }
                report.protectedLegacyRecordIDs.insert(recordID)
                report.protectedLegacyFileCount += group.count
                continue
            }
            let candidate = group[0]
            let identity: ChekinanaImportFileIdentity
            do {
                guard let value = try ChekinanaChekiDeletionJournalStore.identity(at: candidate.0, in: directory) else {
                    throw ChekinanaChekiDeletionError.recoveryRequired
                }
                identity = value
            } catch {
                if originalIdentity == nil { throw error }
                report.protectedLegacyRecordIDs.insert(recordID)
                report.protectedLegacyFileCount += 1
                continue
            }
            guard originalIdentity == nil || originalIdentity == identity else {
                report.protectedLegacyRecordIDs.insert(recordID)
                report.protectedLegacyFileCount += 1
                continue
            }
            let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(in: fresh)
            let current = try ChekinanaLibraryFileReferenceSnapshot.capture(in: fresh, directory: directory)
            guard !current.referencedFilenames.contains(candidate.0.lastPathComponent) else {
                throw ChekinanaChekiDeletionError.recoveryRequired
            }
            let adopted = ChekinanaChekiDeletionJournal(formatVersion: 1, operationID: candidate.2,
                libraryGeneration: generation, recordBefore: record, originalFilename: originalName,
                quarantineFilename: candidate.0.lastPathComponent, identity: identity, restorationOnly: true)
            try ChekinanaChekiDeletionJournalStore.persist(adopted, in: directory)
            _ = try recover(adopted, in: context, directory: directory,
                moveItem: moveItem, removeItem: removeItem)
            report.restoredRecordIDs.insert(recordID)
        }
    }
}

@MainActor
enum ChekinanaChekiDeletionCoordinator {
    static func delete(chekiID: UUID, expectedUpdatedAt: Date?, alreadyCommitted: Bool = false,
        in context: ModelContext, directory: URL? = nil,
        saveContext: (ModelContext) throws -> Void = { try $0.save() },
        moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        journalPersisted: (ChekinanaChekiDeletionJournal) throws -> Void = { _ in },
        onDatabaseCommitted: (URL) -> Void = { _ in }
    ) throws {
        try ChekinanaLibraryMutationProtocol.withExclusiveOperationSync {
            let directory = try directory ?? ChekiImageRefResolver.chekiImagesDirectory()
            try ChekinanaLibraryMutationPreflight.requireImportConvergedExclusively(
                in: context, directory: directory, includingChekiDeletions: false)
            try ChekinanaPersistenceMutationCoordinator.withLock {
                try ChekinanaChekiEditRecovery.requireConvergedExclusively(in: context, directory: directory)
                let recovered = try ChekinanaChekiDeletionRecovery.recoverExclusively(
                    in: context, directory: directory, moveItem: moveItem, removeItem: removeItem)
                let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(in: context)
                let fresh = ModelContext(context.container)
                let records = try fresh.fetch(FetchDescriptor<MediaItem>()).filter { $0.id == chekiID && $0.kind == .cheki }
                if records.isEmpty && (alreadyCommitted || recovered.completedRecordIDs.contains(chekiID)) {
                    guard !recovered.protectedLegacyRecordIDs.contains(chekiID) else {
                        throw ChekinanaChekiDeletionError.legacyEvidenceUnavailable
                    }
                    return
                }
                guard records.count == 1 else { throw ChekinanaChekiDeletionError.changedRecord }
                let before = ChekinanaChekiEditRecordSnapshot(records[0])
                guard expectedUpdatedAt == nil || before.updatedAt == expectedUpdatedAt else {
                    throw ChekinanaChekiDeletionError.changedRecord
                }
                let target = try ChekinanaModelContextResolver.cheki(id: chekiID, in: context)
                guard ChekinanaChekiEditRecordSnapshot(target) == before else {
                    throw ChekinanaChekiDeletionError.changedRecord
                }
                let originalName = ChekinanaChekiDeletionJournal.managedFilename(for: before)
                let otherReferences = try ChekinanaLibraryFileReferenceSnapshot.capture(
                    in: fresh, directory: directory, excludingMediaItemID: chekiID)
                let identity: ChekinanaImportFileIdentity?
                if let originalName, !otherReferences.referencedFilenames.contains(originalName) {
                    identity = try ChekinanaChekiDeletionJournalStore.identity(
                        at: directory.appendingPathComponent(originalName), in: directory)
                } else { identity = nil }
                let operationID = UUID()
                let quarantineName = ".delete-\(chekiID.uuidString)-\(operationID.uuidString).quarantine"
                let quarantine = directory.appendingPathComponent(quarantineName)
                guard try ChekinanaChekiDeletionJournalStore.identity(at: quarantine, in: directory) == nil else {
                    throw ChekinanaChekiDeletionError.recoveryRequired
                }
                let journal = ChekinanaChekiDeletionJournal(formatVersion: 1, operationID: operationID,
                    libraryGeneration: generation, recordBefore: before, originalFilename: originalName,
                    quarantineFilename: quarantineName, identity: identity, restorationOnly: false)
                try ChekinanaChekiDeletionJournalStore.persist(journal, in: directory)
                var operationError: Error?
                do {
                    try journalPersisted(journal)
                    if let identity, let originalName {
                        let original = directory.appendingPathComponent(originalName)
                        try moveItem(original, quarantine)
                        guard try ChekinanaChekiDeletionJournalStore.identity(at: original, in: directory) == nil,
                              try ChekinanaChekiDeletionJournalStore.identity(at: quarantine, in: directory) == identity else {
                            throw ChekinanaChekiDeletionError.recoveryRequired
                        }
                    }
                    context.delete(target)
                    try saveContext(context)
                } catch { operationError = error }
                let direction = try ChekinanaChekiDeletionRecovery.direction(for: journal, in: context, directory: directory)
                if direction == .completeDeletion { onDatabaseCommitted(quarantine) }
                _ = try ChekinanaChekiDeletionRecovery.recover(journal, in: context, directory: directory,
                    moveItem: moveItem, removeItem: removeItem)
                if direction == .restoreRecord {
                    if let operationError { throw operationError }
                    throw ChekinanaChekiDeletionError.databaseCommitNotObserved
                }
            }
        }
    }
}

struct ChekinanaChekiEditRecordSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let mediaOwnerID: UUID
    let idolIDs: [UUID]
    let eventID: UUID?
    let date: Date?
    let userAppears: Bool
    let isFavorite: Bool
    let hasPostedToSNS: Bool
    let note: String
    let mediaRef: String
    let sizeRawValue: String?
    let idx: Int?
    let createdAt: Date
    let updatedAt: Date

    init(_ item: MediaItem) {
        id = item.id
        mediaOwnerID = item.mediaOwnerID
        idolIDs = item.idolIDs
        eventID = item.eventID
        date = item.date
        userAppears = item.userAppears
        isFavorite = item.isFavorite
        hasPostedToSNS = item.hasPostedToSNS
        note = item.note
        mediaRef = item.mediaRef
        sizeRawValue = item.sizeRawValue
        idx = item.idx
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }
}

struct ChekinanaChekiEditAuthorization: Equatable, Sendable {
    let libraryGeneration: UUID
    let record: ChekinanaChekiEditRecordSnapshot
    let mediaSourceIdentity: ChekinanaImportFileIdentity?
}

enum ChekinanaChekiEditableField: Hashable, Sendable {
    case idols
    case event
    case date
    case userAppears
    case size
    case favorite
    case posted
    case note
}

enum ChekinanaChekiEditCommitError: LocalizedError, Equatable {
    case changedLibrary
    case changedRecord
    case changedMediaSource
    case indexOverflow
    case databaseCommitNotObserved
    case fileRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .changedLibrary:
            ChekinanaL10n.message("The library was replaced after this edit began. Reopen the Cheki and try again.")
        case .changedRecord:
            ChekinanaL10n.message("The Cheki changed after this edit began. Reopen it and try again.")
        case .changedMediaSource:
            ChekinanaL10n.message("The stored Cheki image changed after this edit began. Reopen it and try again.")
        case .indexOverflow:
            ChekinanaL10n.message("The target Cheki group has no available index.")
        case .databaseCommitNotObserved:
            ChekinanaL10n.message("The Cheki database update was not committed. Its previous image was restored.")
        case .fileRecoveryFailed:
            ChekinanaL10n.message("Cheki media recovery is incomplete. Retry recovery before editing or replacing the library.")
        }
    }
}

struct ChekinanaChekiEditPublicationJournal: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case intentPersisted
        case backupReady
        case filePublished
        case databaseCommitted
    }

    let formatVersion: Int
    let transactionID: UUID
    let libraryGeneration: UUID
    let mediaItemID: UUID
    let mediaOwnerID: UUID
    let sourceImageRef: String
    let sourceFilename: String
    let targetImageRef: String
    let targetFilename: String
    let stagedFilename: String
    let backupFilename: String
    let sourceIdentity: ChekinanaImportFileIdentity
    let targetIdentityBefore: ChekinanaImportFileIdentity?
    let preparedIdentity: ChekinanaImportFileIdentity
    let databaseBefore: ChekinanaChekiEditRecordSnapshot
    let databaseAfter: ChekinanaChekiEditRecordSnapshot
    var phase: Phase
}

struct ChekinanaChekiEditPublicationHandle: Sendable {
    static let journalFilenamePrefix = ".cheki-edit-intent-"
    static let journalFilenameSuffix = ".json"

    let directory: URL
    let transactionID: UUID

    private var journalURL: URL {
        directory.appendingPathComponent(Self.journalFilename(for: transactionID))
    }

    static func create(
        journal: ChekinanaChekiEditPublicationJournal,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        guard try discover(in: directory, fileManager: fileManager).isEmpty else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        let handle = Self(
            directory: directory.standardizedFileURL,
            transactionID: journal.transactionID
        )
        guard !fileManager.fileExists(atPath: handle.journalURL.path) else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        try handle.write(journal)
        return handle
    }

    static func discover(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> [Self] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        return try entries.compactMap { entry in
            guard entry.lastPathComponent.hasPrefix(journalFilenamePrefix) else {
                return nil
            }
            guard let transactionID = transactionID(
                fromJournalFilename: entry.lastPathComponent
            ) else {
                throw ChekinanaChekiEditCommitError.fileRecoveryFailed
            }
            let values = try entry.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ChekinanaChekiEditCommitError.fileRecoveryFailed
            }
            return Self(
                directory: directory.standardizedFileURL,
                transactionID: transactionID
            )
        }.sorted {
            $0.transactionID.uuidString < $1.transactionID.uuidString
        }
    }

    func load() throws -> ChekinanaChekiEditPublicationJournal {
        let journal: ChekinanaChekiEditPublicationJournal
        do {
            journal = try JSONDecoder().decode(
                ChekinanaChekiEditPublicationJournal.self,
                from: Data(contentsOf: journalURL, options: [.mappedIfSafe])
            )
        } catch {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        guard journal.formatVersion == 1,
              journal.transactionID == transactionID,
              journal.mediaItemID == journal.databaseBefore.id,
              journal.mediaItemID == journal.databaseAfter.id,
              journal.mediaOwnerID == journal.databaseBefore.mediaOwnerID,
              journal.mediaOwnerID == journal.databaseAfter.mediaOwnerID,
              journal.sourceImageRef == journal.databaseBefore.mediaRef,
              journal.targetImageRef == journal.databaseAfter.mediaRef,
              journal.targetImageRef == journal.targetFilename,
              journal.targetFilename
                == "\(journal.mediaOwnerID.uuidString).jpg",
              Self.validFilename(journal.sourceFilename),
              Self.validFilename(journal.targetFilename),
              Self.validFilename(journal.stagedFilename),
              Self.validFilename(journal.backupFilename),
              journal.stagedFilename.hasPrefix(
                ChekinanaChekiImageReplacementTransaction.stagingFilenamePrefix
              ),
              journal.backupFilename
                == "\(ChekinanaChekiImageReplacementTransaction.backupFilenamePrefix)\(transactionID.uuidString.lowercased())",
              journal.sourceIdentity.isValid,
              journal.targetIdentityBefore?.isValid != false,
              journal.preparedIdentity.isValid,
              journal.databaseBefore != journal.databaseAfter,
              journal.databaseBefore.createdAt == journal.databaseAfter.createdAt else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        guard journal.sourceImageRef == journal.sourceFilename,
              URL(fileURLWithPath: journal.sourceFilename)
                .deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(journal.mediaOwnerID.uuidString)
                    == .orderedSame,
              journal.sourceFilename != journal.stagedFilename,
        journal.sourceFilename != journal.backupFilename,
        journal.targetFilename != journal.stagedFilename,
        journal.targetFilename != journal.backupFilename else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        if journal.sourceFilename == journal.targetFilename {
            guard journal.targetIdentityBefore == journal.sourceIdentity else {
                throw ChekinanaChekiEditCommitError.fileRecoveryFailed
            }
        }
        return journal
    }

    func updatePhase(_ phase: ChekinanaChekiEditPublicationJournal.Phase) throws {
        var journal = try load()
        journal.phase = phase
        try write(journal)
    }

    func restoreDatabaseBefore(fileManager: FileManager = .default) throws {
        let journal = try load()
        let targetURL = directory.appendingPathComponent(journal.targetFilename)
        let sourceURL = directory.appendingPathComponent(journal.sourceFilename)
        let stagedURL = directory.appendingPathComponent(journal.stagedFilename)
        let backupURL = directory.appendingPathComponent(journal.backupFilename)
        let currentTarget = try Self.identityIfPresent(targetURL, fileManager: fileManager)
        let currentStage = try Self.identityIfPresent(stagedURL, fileManager: fileManager)
        let currentBackup = try Self.identityIfPresent(backupURL, fileManager: fileManager)

        guard currentTarget == journal.targetIdentityBefore
                || currentTarget == journal.preparedIdentity,
              currentStage == nil || currentStage == journal.preparedIdentity,
              currentBackup == nil || currentBackup == journal.targetIdentityBefore else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        if sourceURL.standardizedFileURL != targetURL.standardizedFileURL {
            guard try Self.identityIfPresent(sourceURL, fileManager: fileManager)
                    == journal.sourceIdentity else {
                throw ChekinanaChekiEditCommitError.fileRecoveryFailed
            }
        }
        if currentTarget == journal.preparedIdentity,
           journal.preparedIdentity != journal.targetIdentityBefore {
            if let targetIdentity = journal.targetIdentityBefore {
                guard currentBackup == targetIdentity else {
                    throw ChekinanaChekiEditCommitError.fileRecoveryFailed
                }
                let backupData = try Data(contentsOf: backupURL, options: [.mappedIfSafe])
                guard ChekinanaImportFileIdentity(backupData) == targetIdentity else {
                    throw ChekinanaChekiEditCommitError.fileRecoveryFailed
                }
                try backupData.write(to: targetURL, options: [.atomic])
            } else {
                try fileManager.removeItem(at: targetURL)
            }
        }
        guard try Self.identityIfPresent(targetURL, fileManager: fileManager)
                == journal.targetIdentityBefore else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        try Self.removeOwnedFile(
            stagedURL,
            expectedIdentity: journal.preparedIdentity,
            fileManager: fileManager
        )
        try Self.removeOwnedFile(
            backupURL,
            expectedIdentity: journal.targetIdentityBefore,
            fileManager: fileManager
        )
        try discardJournal(fileManager: fileManager)
    }

    func validateDatabaseAfterFiles(
        fileManager: FileManager = .default
    ) throws {
        let journal = try load()
        let targetURL = directory.appendingPathComponent(journal.targetFilename)
        let sourceURL = directory.appendingPathComponent(journal.sourceFilename)
        let stagedURL = directory.appendingPathComponent(journal.stagedFilename)
        let backupURL = directory.appendingPathComponent(journal.backupFilename)
        guard try Self.identityIfPresent(targetURL, fileManager: fileManager)
                == journal.preparedIdentity,
              [nil, journal.preparedIdentity].contains(
                try Self.identityIfPresent(stagedURL, fileManager: fileManager)
              ),
              [nil, journal.targetIdentityBefore].contains(
                try Self.identityIfPresent(backupURL, fileManager: fileManager)
              ) else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        if sourceURL.standardizedFileURL != targetURL.standardizedFileURL {
            let currentSource = try Self.identityIfPresent(sourceURL, fileManager: fileManager)
            guard currentSource == nil || currentSource == journal.sourceIdentity else {
                throw ChekinanaChekiEditCommitError.fileRecoveryFailed
            }
        }
    }

    func completeDatabaseAfter(fileManager: FileManager = .default) throws {
        let journal = try load()
        try validateDatabaseAfterFiles(fileManager: fileManager)
        let targetURL = directory.appendingPathComponent(journal.targetFilename)
        let sourceURL = directory.appendingPathComponent(journal.sourceFilename)
        let stagedURL = directory.appendingPathComponent(journal.stagedFilename)
        let backupURL = directory.appendingPathComponent(journal.backupFilename)
        try updatePhase(.databaseCommitted)
        if sourceURL.standardizedFileURL != targetURL.standardizedFileURL {
            try Self.removeOwnedFile(
                sourceURL,
                expectedIdentity: journal.sourceIdentity,
                fileManager: fileManager
            )
        }
        try Self.removeOwnedFile(
            stagedURL,
            expectedIdentity: journal.preparedIdentity,
            fileManager: fileManager
        )
        try Self.removeOwnedFile(
            backupURL,
            expectedIdentity: journal.targetIdentityBefore,
            fileManager: fileManager
        )
        try discardJournal(fileManager: fileManager)
    }

    private func write(_ journal: ChekinanaChekiEditPublicationJournal) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(journal)
            try data.write(to: journalURL, options: [.atomic])
            let handle = try FileHandle(forWritingTo: journalURL)
            try handle.synchronize()
            try handle.close()
        } catch {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
    }

    private func discardJournal(fileManager: FileManager) throws {
        let values = try journalURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        try fileManager.removeItem(at: journalURL)
        guard !fileManager.fileExists(atPath: journalURL.path) else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
    }

    private static func identityIfPresent(
        _ url: URL,
        fileManager: FileManager
    ) throws -> ChekinanaImportFileIdentity? {
        try ChekinanaChekiImageReplacementTransaction.fileIdentityIfPresent(
            url,
            fileManager: fileManager
        )
    }

    private static func removeOwnedFile(
        _ url: URL,
        expectedIdentity: ChekinanaImportFileIdentity?,
        fileManager: FileManager
    ) throws {
        guard let expectedIdentity else {
            guard try identityIfPresent(url, fileManager: fileManager) == nil else {
                throw ChekinanaChekiEditCommitError.fileRecoveryFailed
            }
            return
        }
        guard let current = try identityIfPresent(url, fileManager: fileManager) else {
            return
        }
        guard current == expectedIdentity else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        try fileManager.removeItem(at: url)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
    }

    private static func journalFilename(for transactionID: UUID) -> String {
        "\(journalFilenamePrefix)\(transactionID.uuidString.lowercased())\(journalFilenameSuffix)"
    }

    private static func transactionID(fromJournalFilename filename: String) -> UUID? {
        guard filename.hasPrefix(journalFilenamePrefix),
              filename.hasSuffix(journalFilenameSuffix) else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: journalFilenamePrefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -journalFilenameSuffix.count)
        guard start < end else { return nil }
        return UUID(uuidString: String(filename[start..<end]))
    }

    private static func validFilename(_ value: String) -> Bool {
        value == URL(fileURLWithPath: value).lastPathComponent
            && value != "." && value != ".." && !value.isEmpty
    }
}

enum ChekinanaChekiEditRecovery {
    enum Direction: Equatable {
        case restoreDatabaseBefore
        case completeDatabaseAfter
    }

    static func recoverUnfinishedEdit(
        in modelContext: ModelContext,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        try ChekinanaPersistenceMutationCoordinator.withLock {
            try requireConvergedExclusively(
                in: modelContext,
                directory: directory,
                fileManager: fileManager
            )
        }
    }

    static func recoverExclusively(
        in modelContext: ModelContext,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        try requireConvergedExclusively(
            in: modelContext,
            directory: directory,
            fileManager: fileManager
        )
    }

    /// The caller already owns the relevant LibraryMutationProtocol authority
    /// and persistence lock. This never reacquires the library gate.
    static func requireConvergedExclusively(
        in modelContext: ModelContext,
        directory suppliedDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let directory = try suppliedDirectory
            ?? ChekiImageRefResolver.chekiImagesDirectory()
        let handles = try ChekinanaChekiEditPublicationHandle.discover(
            in: directory,
            fileManager: fileManager
        )
        guard handles.count <= 1 else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        guard let handle = handles.first else { return }
        switch try direction(for: handle, in: modelContext) {
        case .restoreDatabaseBefore:
            try handle.restoreDatabaseBefore(fileManager: fileManager)
        case .completeDatabaseAfter:
            try handle.completeDatabaseAfter(fileManager: fileManager)
        }
        guard try ChekinanaChekiEditPublicationHandle.discover(
            in: directory,
            fileManager: fileManager
        ).isEmpty else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
    }

    static func direction(
        for handle: ChekinanaChekiEditPublicationHandle,
        in modelContext: ModelContext
    ) throws -> Direction {
        let journal = try handle.load()
        let witnessContext = ModelContext(modelContext.container)
        guard try currentGeneration(in: witnessContext)
                == journal.libraryGeneration else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        let target: MediaItem
        do {
            target = try ChekinanaModelContextResolver.cheki(
                id: journal.mediaItemID,
                in: witnessContext
            )
        } catch {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        let snapshot = ChekinanaChekiEditRecordSnapshot(target)
        if snapshot == journal.databaseBefore { return .restoreDatabaseBefore }
        if snapshot == journal.databaseAfter { return .completeDatabaseAfter }
        throw ChekinanaChekiEditCommitError.fileRecoveryFailed
    }

    /// Recovery is also used by the background ChekiRoku record importer.
    /// Read the reserved generation row directly so the witness check remains
    /// on the caller's ModelContext executor instead of hopping to MainActor.
    private static func currentGeneration(
        in modelContext: ModelContext
    ) throws -> UUID? {
        let markers = try modelContext.fetch(FetchDescriptor<CalendarGroupOrder>())
            .filter { $0.dateKey == ChekinanaLibraryGenerationStore.markerDateKey }
        guard markers.count <= 1 else {
            throw ChekinanaImportTransactionError.indeterminate
        }
        guard let marker = markers.first else { return nil }
        guard marker.id == CalendarGroupOrder.key(
                dateKey: ChekinanaLibraryGenerationStore.markerDateKey,
                groupKey: marker.groupKey
              ),
              marker.sortOrder == 0,
              let generation = UUID(uuidString: marker.groupKey) else {
            throw ChekinanaImportTransactionError.indeterminate
        }
        return generation
    }
}

@MainActor
enum ChekinanaChekiEditCommitter {
    typealias Apply = (MediaItem) throws -> Bool
    typealias SaveContext = (ModelContext) throws -> Void

    static func authorize(
        expected: ChekinanaChekiEditRecordSnapshot,
        in modelContext: ModelContext
    ) async throws -> ChekinanaChekiEditAuthorization {
        try await ChekinanaLibraryMutationProtocol.withExclusiveOperation {
            try ChekinanaLibraryMutationPreflight.requireImportConvergedExclusively(in: modelContext)
            return try ChekinanaPersistenceMutationCoordinator.withLock {
                try Task.checkCancellation()
                try ChekinanaChekiEditRecovery.recoverExclusively(in: modelContext)
                let generation = try ChekinanaLibraryGenerationStore.ensureCurrent(
                    in: modelContext
                )
                let target = try ChekinanaModelContextResolver.cheki(
                    id: expected.id,
                    in: modelContext
                )
                guard ChekinanaChekiEditRecordSnapshot(target) == expected else {
                    throw ChekinanaChekiEditCommitError.changedRecord
                }
                return ChekinanaChekiEditAuthorization(
                    libraryGeneration: generation,
                    record: expected,
                    mediaSourceIdentity: mediaSourceIdentity(for: target)
                )
            }
        }
    }

    @discardableResult
    static func commit(
        authorization: ChekinanaChekiEditAuthorization,
        imageReplacement: ChekinanaChekiImageReplacementTransaction?,
        in modelContext: ModelContext,
        saveContext: SaveContext = { try $0.save() },
        apply: Apply
    ) async throws -> MediaItem {
        do {
            return try await ChekinanaLibraryMutationProtocol.withExclusiveOperation {
                try ChekinanaLibraryMutationPreflight.requireImportConvergedExclusively(in: modelContext)
                return try ChekinanaPersistenceMutationCoordinator.withLock {
                    try Task.checkCancellation()
                    try ChekinanaChekiEditRecovery.recoverExclusively(
                        in: modelContext
                    )
                    guard try ChekinanaLibraryGenerationStore.current(
                        in: modelContext
                    ) == authorization.libraryGeneration else {
                        throw ChekinanaChekiEditCommitError.changedLibrary
                    }
                    let target = try ChekinanaModelContextResolver.cheki(
                        id: authorization.record.id,
                        in: modelContext
                    )
                    guard ChekinanaChekiEditRecordSnapshot(target)
                            == authorization.record else {
                        throw ChekinanaChekiEditCommitError.changedRecord
                    }
                    guard mediaSourceIdentity(for: target)
                            == authorization.mediaSourceIdentity else {
                        throw ChekinanaChekiEditCommitError.changedMediaSource
                    }
                    try imageReplacement?.validateSource(
                        mediaOwnerID: target.mediaOwnerID,
                        imageRef: target.imageRef,
                        expectedSourceIdentity: authorization.mediaSourceIdentity
                    )

                    var publication: ChekinanaChekiImageReplacementPublication?
                    do {
                        let propagatesEventAssociation = try apply(target)
                        try reassignIndexIfGroupChanged(
                            target,
                            previous: authorization.record,
                            in: modelContext
                        )
                        if let imageReplacement {
                            target.imageRef = imageReplacement.imageRef
                        }
                        target.updatedAt = Date()
                        if propagatesEventAssociation {
                            try ChekinanaEventAssociationPropagation.propagate(
                                from: target,
                                in: modelContext
                            )
                        }
                        if let imageReplacement {
                            let createdPublication = try imageReplacement
                                .beginDurablePublication(
                                    libraryGeneration: authorization.libraryGeneration,
                                    databaseBefore: authorization.record,
                                    databaseAfter: ChekinanaChekiEditRecordSnapshot(target)
                                )
                            publication = createdPublication
                            try createdPublication.publishPreparedFile()
                        }
                    } catch {
                        let commitError = error
                        if let publication {
                            do {
                                try publication.rollback()
                            } catch {
                                modelContext.rollback()
                                throw ChekinanaChekiEditCommitError.fileRecoveryFailed
                            }
                        }
                        modelContext.rollback()
                        imageReplacement?.discardPreparedFile()
                        throw commitError
                    }

                    do {
                        try saveContext(modelContext)
                    } catch {
                        let databaseError = error
                        guard let publication else {
                            modelContext.rollback()
                            imageReplacement?.discardPreparedFile()
                            throw databaseError
                        }
                        let direction: ChekinanaChekiEditRecovery.Direction
                        do {
                            direction = try ChekinanaChekiEditRecovery.direction(
                                for: publication.handle,
                                in: modelContext
                            )
                        } catch {
                            modelContext.rollback()
                            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
                        }
                        switch direction {
                        case .restoreDatabaseBefore:
                            do {
                                try publication.rollback()
                            } catch {
                                modelContext.rollback()
                                throw ChekinanaChekiEditCommitError.fileRecoveryFailed
                            }
                            modelContext.rollback()
                            throw databaseError
                        case .completeDatabaseAfter:
                            try publication.validateCommittedFiles()
                            publication.finishCommit()
                            imageReplacement?.discardPreparedFile()
                            return target
                        }
                    }

                    if let publication {
                        do {
                            switch try ChekinanaChekiEditRecovery.direction(
                                for: publication.handle,
                                in: modelContext
                            ) {
                            case .restoreDatabaseBefore:
                                try publication.rollback()
                                modelContext.rollback()
                                throw ChekinanaChekiEditCommitError
                                    .databaseCommitNotObserved
                            case .completeDatabaseAfter:
                                try publication.validateCommittedFiles()
                                publication.finishCommit()
                            }
                        } catch let error as ChekinanaChekiEditCommitError {
                            throw error
                        } catch {
                            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
                        }
                    }
                    imageReplacement?.discardPreparedFile()
                    return target
                }
            }
        } catch {
            imageReplacement?.discardPreparedFile()
            throw error
        }
    }

    private static func mediaSourceIdentity(
        for target: MediaItem
    ) -> ChekinanaImportFileIdentity? {
        guard let sourceURL = ChekiImageRefResolver.managedChekiFileURL(
            for: target.imageRef,
            chekiID: target.mediaOwnerID
        ) else { return nil }
        return try? ChekinanaImportFileIdentity.inspect(sourceURL)
    }

    /// Runs after the caller has applied its scalar relationship edits and
    /// while the library mutation authority and persistence lock are still
    /// held. Only date + the complete Idol set define index identity.
    private static func reassignIndexIfGroupChanged(
        _ target: MediaItem,
        previous: ChekinanaChekiEditRecordSnapshot,
        in modelContext: ModelContext
    ) throws {
        let previousGroup = ChekinanaChekiGroupKey(
            idolIDs: previous.idolIDs,
            date: previous.date)
        let targetGroup = ChekinanaChekiGroupKey(
            idolIDs: target.idolIDs,
            date: target.date)
        // Read every group through a fresh context before checking index validity.
        let indexContext = ModelContext(modelContext.container)
        let existing = try ChekinanaChekiIndexing.snapshots(in: indexContext)
        do {
            target.idx = try ChekinanaChekiIndexing.reassignedIndex(
                currentIndex: target.idx,
                previousGroup: previousGroup,
                targetGroup: targetGroup,
                previousFavorite: previous.isFavorite,
                targetFavorite: target.isFavorite,
                chekiID: target.id,
                existing: existing
            )
        } catch ChekinanaChekiIndexingError.overflow {
            throw ChekinanaChekiEditCommitError.indexOverflow
        }
    }
}

struct ChekinanaChekiImageReplacementTransaction: Sendable {
    static let stagingFilenamePrefix = ".cheki-size-stage-"
    static let backupFilenamePrefix = ".cheki-size-backup-"

    let imageRef: String
    private let targetURL: URL
    private let originalURL: URL
    private let originalImageRef: String
    private let stagedURL: URL
    private let sourceIdentity: ChekinanaImportFileIdentity
    private let targetIdentity: ChekinanaImportFileIdentity?
    private let preparedIdentity: ChekinanaImportFileIdentity

    static func stage(
        currentImageRef: String?,
        mediaOwnerID: UUID,
        size: ChekiSize
    ) async throws -> Self {
        guard let originalImageRef = currentImageRef?.nonEmpty else {
            throw ChekinanaDownloadChekiError.unreadableLocalImage
        }
        guard let originalURL = ChekiImageRefResolver.managedChekiFileURL(
            for: originalImageRef,
            chekiID: mediaOwnerID
        ) else {
            throw ChekinanaDownloadChekiError.unreadableLocalImage
        }
        let originalData = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: originalURL, options: [.mappedIfSafe])
        }.value
        let sourceIdentity = ChekinanaImportFileIdentity(originalData)
        let prepared = try await ChekinanaLocalImportChekiProcessor
            .standardizedForSave(originalData, size: size)
        try Task.checkCancellation()
        let transaction = try await Task.detached(priority: .userInitiated) {
            let directory = try ChekiImageRefResolver.chekiImagesDirectory()
            let targetURL = directory.appendingPathComponent(
                "\(mediaOwnerID.uuidString).jpg"
            )
            let fileManager = FileManager.default
            let targetIdentity = try fileIdentityIfPresent(
                targetURL,
                fileManager: fileManager
            )
            let stagedURL = directory.appendingPathComponent(
                "\(stagingFilenamePrefix)\(UUID().uuidString.lowercased()).jpg"
            )
            do {
                try prepared.data.write(to: stagedURL, options: [.atomic])
            } catch {
                try? fileManager.removeItem(at: stagedURL)
                throw error
            }
            return Self(
                imageRef: targetURL.lastPathComponent,
                targetURL: targetURL,
                originalURL: originalURL,
                originalImageRef: originalImageRef,
                stagedURL: stagedURL,
                sourceIdentity: sourceIdentity,
                targetIdentity: targetIdentity,
                preparedIdentity: ChekinanaImportFileIdentity(prepared.data)
            )
        }.value
        do {
            try Task.checkCancellation()
            return transaction
        } catch {
            transaction.discardPreparedFile()
            throw error
        }
    }

    func validateSource(
        mediaOwnerID: UUID,
        imageRef: String?,
        expectedSourceIdentity: ChekinanaImportFileIdentity?
    ) throws {
        guard targetURL.lastPathComponent == "\(mediaOwnerID.uuidString).jpg",
              imageRef == originalImageRef,
              sourceIdentity == expectedSourceIdentity,
              ChekiImageRefResolver.managedChekiFileURL(
                for: imageRef,
                chekiID: mediaOwnerID
              )?.standardizedFileURL == originalURL.standardizedFileURL,
              try Self.fileIdentityIfPresent(originalURL) == sourceIdentity,
              try Self.fileIdentityIfPresent(targetURL) == targetIdentity else {
            throw ChekinanaChekiEditCommitError.changedMediaSource
        }
    }

    func beginDurablePublication(
        libraryGeneration: UUID,
        databaseBefore: ChekinanaChekiEditRecordSnapshot,
        databaseAfter: ChekinanaChekiEditRecordSnapshot
    ) throws -> ChekinanaChekiImageReplacementPublication {
        let fileManager = FileManager.default
        guard try Self.fileIdentityIfPresent(stagedURL, fileManager: fileManager)
                == preparedIdentity,
              try Self.fileIdentityIfPresent(targetURL, fileManager: fileManager)
                == targetIdentity,
              databaseBefore.id == databaseAfter.id,
              databaseBefore.mediaOwnerID == databaseAfter.mediaOwnerID,
              databaseBefore.mediaRef == originalImageRef,
              databaseAfter.mediaRef == imageRef,
              databaseAfter.mediaOwnerID.uuidString + ".jpg"
                == targetURL.lastPathComponent else {
            throw ChekinanaChekiEditCommitError.changedMediaSource
        }
        let transactionID = UUID()
        let journal = ChekinanaChekiEditPublicationJournal(
            formatVersion: 1,
            transactionID: transactionID,
            libraryGeneration: libraryGeneration,
            mediaItemID: databaseBefore.id,
            mediaOwnerID: databaseBefore.mediaOwnerID,
            sourceImageRef: originalImageRef,
            sourceFilename: originalURL.lastPathComponent,
            targetImageRef: imageRef,
            targetFilename: targetURL.lastPathComponent,
            stagedFilename: stagedURL.lastPathComponent,
            backupFilename: "\(Self.backupFilenamePrefix)\(transactionID.uuidString.lowercased())",
            sourceIdentity: sourceIdentity,
            targetIdentityBefore: targetIdentity,
            preparedIdentity: preparedIdentity,
            databaseBefore: databaseBefore,
            databaseAfter: databaseAfter,
            phase: .intentPersisted
        )
        let handle = try ChekinanaChekiEditPublicationHandle.create(
            journal: journal,
            in: targetURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        return ChekinanaChekiImageReplacementPublication(handle: handle)
    }

    func discardPreparedFile() {
        let directory = stagedURL.deletingLastPathComponent()
        let handles: [ChekinanaChekiEditPublicationHandle]
        do {
            handles = try ChekinanaChekiEditPublicationHandle.discover(in: directory)
        } catch {
            // A malformed or unreadable intent is authoritative recovery
            // evidence; never erase a possibly referenced prepared file.
            return
        }
        if handles.contains(where: { handle in
            (try? handle.load().stagedFilename) == stagedURL.lastPathComponent
        }) { return }
        try? FileManager.default.removeItem(at: stagedURL)
    }

    fileprivate static func fileIdentityIfPresent(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws -> ChekinanaImportFileIdentity? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        return try ChekinanaImportFileIdentity.inspect(url)
    }
}

struct ChekinanaChekiImageReplacementPublication {
    let handle: ChekinanaChekiEditPublicationHandle

    func publishPreparedFile(fileManager: FileManager = .default) throws {
        let journal = try handle.load()
        guard journal.phase == .intentPersisted else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        let targetURL = handle.directory.appendingPathComponent(journal.targetFilename)
        let sourceURL = handle.directory.appendingPathComponent(journal.sourceFilename)
        let stagedURL = handle.directory.appendingPathComponent(journal.stagedFilename)
        let backupURL = handle.directory.appendingPathComponent(journal.backupFilename)
        guard try ChekinanaChekiImageReplacementTransaction.fileIdentityIfPresent(
            targetURL,
            fileManager: fileManager
        ) == journal.targetIdentityBefore,
        try ChekinanaChekiImageReplacementTransaction.fileIdentityIfPresent(
            stagedURL,
            fileManager: fileManager
        ) == journal.preparedIdentity,
        try ChekinanaChekiImageReplacementTransaction.fileIdentityIfPresent(
            backupURL,
            fileManager: fileManager
        ) == nil else {
            throw ChekinanaChekiEditCommitError.changedMediaSource
        }
        if sourceURL.standardizedFileURL != targetURL.standardizedFileURL {
            guard try ChekinanaChekiImageReplacementTransaction.fileIdentityIfPresent(
                sourceURL,
                fileManager: fileManager
            ) == journal.sourceIdentity else {
                throw ChekinanaChekiEditCommitError.changedMediaSource
            }
        }
        if journal.targetIdentityBefore != nil {
            try fileManager.copyItem(at: targetURL, to: backupURL)
            guard try ChekinanaChekiImageReplacementTransaction.fileIdentityIfPresent(
                backupURL,
                fileManager: fileManager
            ) == journal.targetIdentityBefore else {
                throw ChekinanaChekiEditCommitError.fileRecoveryFailed
            }
        }
        try handle.updatePhase(.backupReady)

        guard try ChekinanaChekiImageReplacementTransaction.fileIdentityIfPresent(
            targetURL,
            fileManager: fileManager
        ) == journal.targetIdentityBefore,
        try ChekinanaChekiImageReplacementTransaction.fileIdentityIfPresent(
            stagedURL,
            fileManager: fileManager
        ) == journal.preparedIdentity else {
            throw ChekinanaChekiEditCommitError.changedMediaSource
        }
        let preparedData = try Data(contentsOf: stagedURL, options: [.mappedIfSafe])
        guard ChekinanaImportFileIdentity(preparedData) == journal.preparedIdentity else {
            throw ChekinanaChekiEditCommitError.changedMediaSource
        }
        try preparedData.write(to: targetURL, options: [.atomic])
        guard try ChekinanaChekiImageReplacementTransaction.fileIdentityIfPresent(
            targetURL,
            fileManager: fileManager
        ) == journal.preparedIdentity else {
            throw ChekinanaChekiEditCommitError.fileRecoveryFailed
        }
        try handle.updatePhase(.filePublished)
    }

    func rollback() throws {
        try handle.restoreDatabaseBefore()
    }

    func validateCommittedFiles() throws {
        try handle.validateDatabaseAfterFiles()
    }

    func finishCommit() {
        // The database witness already selects the new side. Cleanup failure
        // leaves the durable journal intact for startup replay and never rolls
        // back committed bytes or fields.
        try? handle.completeDatabaseAfter()
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

enum ChekinanaScannerPostprocessMode: String, Equatable, Sendable {
    case off
    case denoise
    case sharpen
}

enum ChekinanaScannerPostprocessor {
    static let fixedMode = ChekinanaScannerPostprocessMode.denoise
    static let noiseLevel = 0.02
    static let sharpness = 0.0

    static func applyingFixedDenoise(to image: CIImage) -> CIImage {
        image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": noiseLevel,
            "inputSharpness": sharpness,
        ])
    }
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
    let tightBoundaries: Bool
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
        postprocessMode _: ChekinanaScannerPostprocessMode,
        whiteBalance: Bool,
        tightBoundaries: Bool = false,
        sleevesEnabled: Bool = false,
        directInputEnabled: Bool = false,
        dateRecognitionEnabled: Bool = false,
        dateBounds: ChekinanaScannerDateBounds? = nil,
        idolRecognitionCandidates: ChekinanaPatternCandidateSet? = nil
    ) {
        self.expectedPolaroids = expectedPolaroids
        self.scannerSize = scannerSize
        self.postprocessMode = ChekinanaScannerPostprocessor.fixedMode
        self.tightBoundaries = tightBoundaries
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
    let filenameExtension: String
    let dateAnnotationState: ChekinanaChekiDateAnnotationState
    let sourceAnnotation: ChekinanaScannerSourceAnnotation?
    let reviewRectificationSource: ChekinanaReviewRectificationSource?
    let refitOriginalSource: ChekinanaReviewRectificationSource?
    let inferredChekiSize: ChekiSize?

    init(
        data: Data,
        stagedFileURL: URL? = nil,
        imagePixelWidth: Int? = nil,
        imagePixelHeight: Int? = nil,
        filenameExtension: String = "png",
        dateAnnotationState: ChekinanaChekiDateAnnotationState = .notRequested,
        sourceAnnotation: ChekinanaScannerSourceAnnotation? = nil,
        reviewRectificationSource: ChekinanaReviewRectificationSource? = nil,
        refitOriginalSource: ChekinanaReviewRectificationSource? = nil,
        inferredChekiSize: ChekiSize? = nil
    ) {
        self.data = data
        self.stagedFileURL = stagedFileURL
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.filenameExtension = filenameExtension
        self.dateAnnotationState = dateAnnotationState
        self.sourceAnnotation = sourceAnnotation?.isValid == true ? sourceAnnotation : nil
        self.reviewRectificationSource = reviewRectificationSource?.isValid == true
            ? reviewRectificationSource : nil
        self.refitOriginalSource = refitOriginalSource
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
    /// ignored. A five-percent relative aspect-ratio tolerance admits ordinary
    /// edge crops while keeping 4:3 and square images outside both templates.
    static let maximumRelativeError = 0.05
    static let miniAspectRatio = 159.0 / 100.0
    static let wideAspectRatio = 200.0 / 159.0

    static func inferredSize(width: Int, height: Int) -> ChekiSize? {
        guard width > 0, height > 0 else { return nil }
        let aspectRatio = Double(max(width, height)) / Double(min(width, height))
        let candidates: [(size: ChekiSize, ratio: Double)] = [
            (.mini, miniAspectRatio),
            (.wide, wideAspectRatio),
        ]
        guard let closest = candidates.min(by: {
            relativeError(aspectRatio, target: $0.ratio)
                < relativeError(aspectRatio, target: $1.ratio)
        }) else { return .mini }
        return relativeError(aspectRatio, target: closest.ratio) <= maximumRelativeError
            ? closest.size
            : .mini
    }

    private static func relativeError(_ value: Double, target: Double) -> Double {
        abs(value - target) / target
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
        if let custom = inferredSize?.customPixelDimensions {
            return custom
        }
        let shortEdge: Int
        let longEdge: Int
        switch inferredSize {
        case .wide:
            shortEdge = wideShortEdge
            longEdge = wideLongEdge
        case .mini, nil:
            shortEdge = miniShortEdge
            longEdge = miniLongEdge
        default:
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
    static func fittedDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        boundingWidth: Int,
        boundingHeight: Int
    ) -> (width: Int, height: Int)? {
        guard sourceWidth > 0, sourceHeight > 0,
              boundingWidth > 0, boundingHeight > 0 else { return nil }
        let scale = min(
            CGFloat(boundingWidth) / CGFloat(sourceWidth),
            CGFloat(boundingHeight) / CGFloat(sourceHeight)
        )
        return (
            min(boundingWidth, max(1, Int((CGFloat(sourceWidth) * scale).rounded()))),
            min(boundingHeight, max(1, Int((CGFloat(sourceHeight) * scale).rounded())))
        )
    }

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

    static func aspectFillRect(
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> CGRect? {
        guard sourceWidth > 0, sourceHeight > 0,
              outputWidth > 0, outputHeight > 0 else { return nil }
        let scale = max(
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
    static let whiteBalanceBlockSize = 48
    static let whiteBalanceMinimumChannelValue =
        ChekinanaFixedBorderWhiteBalanceEstimator.minimumChannelValue
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
        let refitSource = makeRefitOriginalSource(image.data)
        return ChekinanaScannerProcessResult(
            images: [ChekinanaScannerResultImage(
                data: output.data,
                imagePixelWidth: output.width,
                imagePixelHeight: output.height,
                filenameExtension: "jpg",
                dateAnnotationState: .notRequested,
                refitOriginalSource: refitSource,
                inferredChekiSize: output.inferredSize
            )],
            warningCount: 0
        )
    }

    static func makeRefitOriginalSource(_ data: Data) -> ChekinanaReviewRectificationSource? {
        let dimensions = ChekinanaImagePixelGeometry.uprightDimensions(in: data)
        return dimensions.map { size in
            ChekinanaReviewRectificationSource(
                imageData: data, sourcePixelWidth: size.width, sourcePixelHeight: size.height,
                quadrilateral: [.init(x: 0, y: 0), .init(x: Double(size.width), y: 0),
                    .init(x: Double(size.width), y: Double(size.height)), .init(x: 0, y: Double(size.height))],
                appliesWhiteBalance: false, postprocessing: .perspectiveOnly
            )
        }
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
                let inferredSize = ChekiSize.mini
                let isLandscape = source.width > source.height
                let target = ChekinanaImportedChekiCanvasPolicy.dimensions(
                    inferredSize: .mini,
                    isLandscape: isLandscape
                )
                guard let outputDimensions = ChekinanaLocalImportRenderGeometry
                    .fittedDimensions(
                        sourceWidth: source.width,
                        sourceHeight: source.height,
                        boundingWidth: target.width,
                        boundingHeight: target.height
                    ) else {
                    throw ChekinanaLocalImportChekiError.invalidImage
                }
                let targetWidth = outputDimensions.width
                let targetHeight = outputDimensions.height
                try Task.checkCancellation()
                let gains = appliesWhiteBalance
                    ? ChekinanaFixedBorderWhiteBalanceEstimator.estimate(
                        from: CIImage(cgImage: source),
                        orientation: isLandscape ? .landscape : .portrait
                    )?.gain
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

    /// Resamples an already-extracted Cheki to the final metadata size. The
    /// complete source rectangle maps to the complete target rectangle, so a
    /// legacy Mini/Wide correction never crops an edge or adds padding.
    static func standardizedForSave(
        _ imageData: Data,
        size: ChekiSize
    ) async throws -> ChekinanaLocalImportChekiOutput {
        return try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard !imageData.isEmpty,
                      imageData.count <= 128 * 1_024 * 1_024 else {
                    throw ChekinanaLocalImportChekiError.invalidImage
                }
                let source = try downsampledImage(from: imageData).image
                let target = ChekinanaImportedChekiCanvasPolicy.dimensions(
                    inferredSize: size,
                    isLandscape: source.width > source.height
                )
                try Task.checkCancellation()
                guard let outputImage = renderedOutputImage(
                    source,
                    gains: nil,
                    outputWidth: target.width,
                    outputHeight: target.height
                ) else {
                    throw ChekinanaLocalImportChekiError.renderFailed
                }
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
                guard CGImageDestinationFinalize(destination),
                      outputData.length > 0,
                      outputData.length <= 32 * 1_024 * 1_024 else {
                    throw ChekinanaLocalImportChekiError.renderFailed
                }
                return ChekinanaLocalImportChekiOutput(
                    data: outputData as Data,
                    width: target.width,
                    height: target.height,
                    whiteBalanceApplied: false,
                    inferredSize: size
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

    private static func renderedOutputImage(
        _ source: CGImage,
        gains: SIMD3<Double>?,
        outputWidth: Int,
        outputHeight: Int,
        usesAspectFill: Bool = false
    ) -> CGImage? {
        guard source.width > 0, source.height > 0,
              outputWidth > 0, outputHeight > 0 else { return nil }
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let drawRect: CGRect
        if usesAspectFill {
            guard let filled = ChekinanaLocalImportRenderGeometry.aspectFillRect(
                sourceWidth: source.width,
                sourceHeight: source.height,
                outputWidth: outputWidth,
                outputHeight: outputHeight
            ) else { return nil }
            drawRect = filled
        } else {
            drawRect = outputRect
        }
        let scale = CGAffineTransform(
            scaleX: drawRect.width / CGFloat(source.width),
            y: drawRect.height / CGFloat(source.height)
        )
        let translation = CGAffineTransform(
            translationX: drawRect.minX,
            y: drawRect.minY
        )
        var image = CIImage(cgImage: source)
            .transformed(by: scale)
            .transformed(by: translation)
            .cropped(to: outputRect)
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

/// Prepares the final Review image from the retained clean source and detected
/// quadrilateral. The provisional Review JPEG is only a fallback for legacy
/// temporary items that predate source retention.
enum ChekinanaReviewChekiImagePreparer {
    static func standardizedForSave(
        fallbackImage: ChekinanaPendingChekiImage,
        reviewSource: ChekinanaReviewRectificationSource?,
        rotationQuarterTurns: Int,
        size: ChekiSize
    ) async throws -> ChekinanaLocalImportChekiOutput {
        guard let reviewSource,
              reviewSource.isValid else {
            return try await ChekinanaLocalImportChekiProcessor
                .standardizedForSave(fallbackImage.data, size: size)
        }

        let rectified = try await ChekinanaEdgeFitRectifier.rectify(
            sourceData: reviewSource.imageData,
            quadrilateral: reviewSource.quadrilateral,
            size: size,
            appliesWhiteBalance: reviewSource.appliesWhiteBalance,
            postprocessing: reviewSource.postprocessing
        )
        var preparedImage = ChekinanaPendingChekiImage(
            data: rectified.data,
            filenameExtension: "jpg",
            sourceID: fallbackImage.sourceID,
            sourceOrigin: fallbackImage.sourceOrigin
        )
        let rotationRemainder = rotationQuarterTurns % 4
        let normalizedRotation = rotationRemainder >= 0
            ? rotationRemainder : rotationRemainder + 4
        for _ in 0..<normalizedRotation {
            try Task.checkCancellation()
            preparedImage = try await ChekinanaScanCleanImageRotation
                .counterclockwise(preparedImage)
        }
        guard let dimensions = ChekinanaImagePixelGeometry.uprightDimensions(
            in: preparedImage.data
        ) else {
            throw ChekinanaLocalImportChekiError.invalidImage
        }
        return ChekinanaLocalImportChekiOutput(
            data: preparedImage.data,
            width: dimensions.width,
            height: dimensions.height,
            whiteBalanceApplied: rectified.whiteBalanceApplied,
            inferredSize: size
        )
    }
}

/// Rebuilds a Review preview from its retained stable source and one complete
/// desired transform. Unlike `standardizedForSave`, the legacy fallback here
/// is known to be unrotated source data, so the requested cumulative rotation
/// is applied after sizing instead of being inferred from the current preview.
enum ChekinanaReviewChekiTransformRenderer {
    static func render(
        sourceImage: ChekinanaPendingChekiImage,
        reviewSource: ChekinanaReviewRectificationSource?,
        intent: ChekinanaConfirmationLedger.TemporaryChekiTransformIntent
    ) async throws -> ChekinanaLocalImportChekiOutput {
        if reviewSource?.isValid == true {
            return try await ChekinanaReviewChekiImagePreparer.standardizedForSave(
                fallbackImage: sourceImage,
                reviewSource: reviewSource,
                rotationQuarterTurns: intent.rotationQuarterTurns,
                size: intent.size
            )
        }

        let standardized = try await ChekinanaLocalImportChekiProcessor
            .standardizedForSave(sourceImage.data, size: intent.size)
        var preparedImage = ChekinanaPendingChekiImage(
            data: standardized.data,
            filenameExtension: "jpg",
            sourceID: sourceImage.sourceID,
            sourceOrigin: sourceImage.sourceOrigin
        )
        for _ in 0..<intent.rotationQuarterTurns {
            try Task.checkCancellation()
            preparedImage = try await ChekinanaScanCleanImageRotation
                .counterclockwise(preparedImage)
        }
        guard let dimensions = ChekinanaImagePixelGeometry.uprightDimensions(
            in: preparedImage.data
        ) else {
            throw ChekinanaLocalImportChekiError.invalidImage
        }
        return ChekinanaLocalImportChekiOutput(
            data: preparedImage.data,
            width: dimensions.width,
            height: dimensions.height,
            whiteBalanceApplied: standardized.whiteBalanceApplied,
            inferredSize: intent.size
        )
    }

    static func dateAnnotation(
        _ source: ChekinanaChekiDateAnnotationState,
        rotationQuarterTurns: Int
    ) -> ChekinanaChekiDateAnnotationState {
        var result = source
        for _ in 0..<rotationQuarterTurns {
            result = ChekinanaScanCleanImageRotation
                .counterclockwiseDateAnnotation(result)
        }
        return result
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

enum ChekinanaScannerRuntimeCopy {
    /// Only known server-owned diagnostics are localized. Unknown external text is preserved.
    static func message(errorCode: String? = nil, message: String?) -> String? {
        let knownMessages: [String: String] = [
            "未找到已配置的 RunPod Pod。请更新 Worker 的 RunPod Pod 配置。": "pod_not_found",
            "已配置的 RunPod Pod 已被终止。请更新 Worker 的 RunPod Pod 配置。": "pod_terminated",
            "暂时无法确认 RunPod 后端状态，请重试。": "status_unconfirmed",
            "Worker 的 RunPod 状态查询配置缺失，请检查服务端配置。": "runpod_configuration_missing",
            "RunPod 状态查询鉴权失败，请检查服务端 API Key。": "runpod_authorization_failed",
            "RunPod 状态查询暂时受到限流，请稍后重试。": "runpod_rate_limited",
            "RunPod 状态查询超时，请稍后重试。": "runpod_status_timeout",
            "RunPod 状态服务暂时不可用，请稍后重试。": "runpod_status_unavailable",
            "RunPod 状态响应无法识别，请检查服务端 API 合同。": "runpod_invalid_response",
            "RunPod 已运行，后端仍在准备。": "backend_preparing",
            "RunPod 后端启动失败，请稍后重试。": "runpod_start_failed",
            "临时 RunPod 的模板或网络卷配置缺失，请检查 Worker 配置。": "temporary_configuration_missing",
            "临时 RunPod 恢复匹配不唯一，已停止自动控制。": "temporary_pod_correlation_ambiguous",
            "临时 RunPod 未能保持运行，请重试启动。": "temporary_pod_exited",
            "RunPod 后端启动等待超时，请重试。": "startup_timeout",
            "启动连接已断开，已停止继续启动 RunPod。": "startup_disconnected",
            "关闭 RunPod 后端失败，请稍后重试。": "runpod_stop_failed",
            "扫描请求或任务仍在进行，完成后才能关闭后端。": "scanner_backend_busy",
            "RunPod GPU 将在 20 秒后关闭。": "stop_scheduled",
            "本地 Scanner 进程需要在 Windows 主机上手动关闭。": "local_scanner_stop_unavailable",
            "暂时无法读取 RunPod 后端状态，请重试。": "status_unreadable",
        ]
        let code = message.flatMap { knownMessages[$0] } ?? errorCode
        switch code {
        case "temporary_pod_create_failed":
            return ChekinanaL10n.message("GPU out of capacity, try later")
        case "pod_not_found":
            return ChekinanaL10n.message("The configured RunPod instance was not found. Update the server configuration.")
        case "pod_terminated":
            return ChekinanaL10n.message("The configured RunPod instance was terminated. Update the server configuration.")
        case "status_unconfirmed":
            return ChekinanaL10n.message("The RunPod backend status could not be confirmed. Try again.")
        case "runpod_configuration_missing":
            return ChekinanaL10n.message("RunPod status configuration is missing. Check the server configuration.")
        case "runpod_authorization_failed":
            return ChekinanaL10n.message("RunPod status authorization failed. Check the server API key configuration.")
        case "runpod_rate_limited":
            return ChekinanaL10n.message("RunPod status requests are temporarily rate limited. Try again later.")
        case "runpod_status_timeout":
            return ChekinanaL10n.message("The RunPod status request timed out. Try again later.")
        case "runpod_status_unavailable":
            return ChekinanaL10n.message("The RunPod status service is temporarily unavailable. Try again later.")
        case "runpod_invalid_response":
            return ChekinanaL10n.message("The RunPod status response is invalid. Check the server API configuration.")
        case "backend_preparing":
            return ChekinanaL10n.message("RunPod is running and the backend is still preparing.")
        case "runpod_start_failed":
            return ChekinanaL10n.message("The RunPod backend failed to start. Try again later.")
        case "temporary_configuration_missing":
            return ChekinanaL10n.message("The temporary RunPod template or network volume configuration is missing. Check the server configuration.")
        case "temporary_pod_correlation_ambiguous":
            return ChekinanaL10n.message("Temporary RunPod recovery found multiple matches. Automatic control has stopped.")
        case "temporary_pod_exited", "temporary_pod_missing", "temporary_pod_terminated":
            return ChekinanaL10n.message("The temporary RunPod instance stopped running. Try starting it again.")
        case "startup_timeout":
            return ChekinanaL10n.message("The RunPod backend startup timed out. Try again.")
        case "startup_disconnected":
            return ChekinanaL10n.message("The startup connection was closed. RunPod startup has stopped.")
        case "runpod_stop_failed":
            return ChekinanaL10n.message("The RunPod backend could not be shut down. Try again later.")
        case "scanner_backend_busy":
            return ChekinanaL10n.message("A scan is still running. Wait for it to finish before shutting down the backend.")
        case "stop_scheduled":
            return ChekinanaL10n.message("The RunPod GPU will shut down in 20 seconds.")
        case "local_scanner_stop_unavailable":
            return ChekinanaL10n.message("Close the local scanner manually on the Windows computer.")
        case "status_unreadable":
            return ChekinanaL10n.message("The RunPod backend status could not be read. Try again.")
        default:
            return message
        }
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
            ChekinanaScannerRuntimeCopy.message(message: message) ?? ChekinanaCommandCopy.text("error.runtime_start", fallback: "Backend failed to start. Please try again later.")
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
    static var pausedMessage: String {
        ChekinanaL10n.message("GPU management is temporarily paused. Import Cheki remains available.")
    }

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

enum ChekinanaScannerNetworkPolicy {
    /// Scanner status, control, upload, polling, and download must follow the
    /// device's normal system/VPN proxy route. Some VPNs intentionally return
    /// a TUN fake-IP from DNS; forcing a direct socket to that address makes an
    /// otherwise healthy Cloudflare endpoint appear unavailable.
    static func productionSessionConfiguration() -> URLSessionConfiguration {
        // Use the ordinary system-backed configuration. In particular, do not
        // create an isolated ephemeral route here: iOS VPN/TUN clients may need
        // the system URL loading stack to turn a DNS fake-IP back into the
        // corresponding proxied request.
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        return configuration
    }
}

#if DEBUG
private enum ChekinanaScannerNetworkDiagnostics {
    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(
            label: "Chekinana.Scanner.NetworkDiagnostics",
            qos: .utility
        ))
        return monitor
    }()

    static func pathSummary() -> String {
        let path = monitor.currentPath
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requires-connection"
        @unknown default: status = "unknown"
        }
        let interface: String
        if path.usesInterfaceType(.wifi) {
            interface = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            interface = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = "wired"
        } else {
            interface = "other"
        }
        return "status=\(status) interface=\(interface) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
    }
}
#endif

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
    /// The Worker runtime snapshot can legitimately wait on its Durable Object
    /// for up to 16 seconds. Keep the client deadline above that server-side
    /// bound so a healthy request is not cancelled first.
    static let statusRequestTimeout: TimeInterval = 25
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
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Chekinana",
        category: "ScannerRuntime"
    )
#endif
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
        URLSession(configuration:
            ChekinanaScannerNetworkPolicy.productionSessionConfiguration()
        )
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
#if DEBUG
        // Start path observation before opening the socket so a later failure
        // reports a settled device route rather than a freshly-created monitor.
        _ = ChekinanaScannerNetworkDiagnostics.pathSummary()
#endif
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
#if DEBUG
                if let urlError = error as? URLError {
                    Self.logger.error(
                        "runtime start transport failed code=\(urlError.errorCode, privacy: .public) \(ChekinanaScannerNetworkDiagnostics.pathSummary(), privacy: .public)"
                    )
                } else {
                    Self.logger.error(
                        "runtime start transport failed kind=non-url \(ChekinanaScannerNetworkDiagnostics.pathSummary(), privacy: .public)"
                    )
                }
#endif
                if let urlError = error as? URLError, urlError.code == .timedOut {
                    throw ChekinanaScannerRuntimeError.timedOut
                }
                throw ChekinanaScannerRuntimeError.clientUnavailable(
                    ChekinanaL10n.message("Backend startup connection was interrupted. You can retry immediately.")
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
        let requestStartedAt = DispatchTime.now().uptimeNanoseconds
#if DEBUG
        // Let the path monitor observe while URLSession is waiting/connecting.
        _ = ChekinanaScannerNetworkDiagnostics.pathSummary()
#endif
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw ChekinanaScannerRuntimeError.timedOut
            }
#if DEBUG
            if let urlError = error as? URLError {
                Self.logger.error(
                    "runtime transport failed code=\(urlError.errorCode, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: requestStartedAt), privacy: .public) \(ChekinanaScannerNetworkDiagnostics.pathSummary(), privacy: .public)"
                )
            } else {
                Self.logger.error(
                    "runtime transport failed kind=non-url elapsed_ms=\(Self.elapsedMilliseconds(since: requestStartedAt), privacy: .public) \(ChekinanaScannerNetworkDiagnostics.pathSummary(), privacy: .public)"
                )
            }
#endif
            throw ChekinanaScannerRuntimeError.clientUnavailable(
                ChekinanaL10n.message("Backend is unavailable from this device. You can retry immediately.")
            )
        }
        guard let httpResponse = response as? HTTPURLResponse else {
#if DEBUG
            Self.logger.error("runtime response kind=non-http")
#endif
            throw ChekinanaScannerRuntimeError.invalidHTTPResponse
        }
        do {
            let status = try JSONDecoder().decode(
                ChekinanaScannerRuntimeStatus.self,
                from: data
            )
#if DEBUG
            Self.logger.notice(
                "runtime response status=\(httpResponse.statusCode, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: requestStartedAt), privacy: .public) decoded=true"
            )
#endif
            // Runtime state is authoritative even for non-2xx control
            // responses such as stop=409 while a scan is still active.
            return status
        } catch {
#if DEBUG
            Self.logger.error(
                "runtime response status=\(httpResponse.statusCode, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: requestStartedAt), privacy: .public) decode_error=\(String(describing: type(of: error)), privacy: .public)"
            )
#endif
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ChekinanaScannerRuntimeError.httpStatus(httpResponse.statusCode)
        }
        throw ChekinanaScannerRuntimeError.invalidResponse
    }

#if DEBUG
    private static func elapsedMilliseconds(since startedAt: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    }
#endif

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
            message: ChekinanaL10n.message("No GPU is currently available. Please try again later."),
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
        URLSession(configuration:
            ChekinanaScannerNetworkPolicy.productionSessionConfiguration()
        )
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
                                        async let reviewRectificationSource =
                                            ChekinanaEdgeFitRectifier.makeReviewRectificationSource(
                                                sourceData: preparedUpload.image.data,
                                                sourcePixelWidth: sourceImage?.width ?? 0,
                                                sourcePixelHeight: sourceImage?.height ?? 0,
                                                quadrilateral: quadrilateral ?? [],
                                                appliesWhiteBalance: options.whiteBalance
                                            )
                                        let (downloaded, renderedAnnotation, reviewSource) = try await (
                                            cleanImage,
                                            sourceAnnotation,
                                            reviewRectificationSource
                                        )
                                        let image = ChekinanaScannerResultImage(
                                            data: downloaded.data,
                                            imagePixelWidth: downloaded.imagePixelWidth,
                                            imagePixelHeight: downloaded.imagePixelHeight,
                                            dateAnnotationState: downloaded.dateAnnotationState,
                                            sourceAnnotation: renderedAnnotation,
                                            reviewRectificationSource: reviewSource
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
        let fields: [(String, String)] = [
            ("sleeve", options.sleevesEnabled ? "1" : "0"),
            ("wb", options.whiteBalance ? "1" : "0"),
            ("denoise", "1"),
            ("sharpen", "0"),
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
    case eventOutsideDateWindow
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
        case .eventOutsideDateWindow:
            ChekinanaCommandCopy.text(
                "error.cheki_event_window",
                fallback: "The Event must be dated within one day of the Cheki."
            )
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
    case transformInProgress(String)
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
        case .transformInProgress(let token):
            ChekinanaCommandCopy.format(
                "error.temporary_cheki_transform_in_progress",
                fallback: "Temporary Cheki %@ is still applying its latest size or rotation. Wait for it to finish and try again.",
                token
            )
        case .capacityExceeded(let bytes):
            ChekinanaCommandCopy.format("error.temporary_storage", fallback: "Temporary Cheki storage limit reached (%lld/400 MiB). Discard temporary Cheki first; images referenced by pending confirmations cannot be evicted.", Int64(bytes / 1_024 / 1_024))
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

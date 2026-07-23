import Foundation
import ImageIO
import Photos
import SwiftData
import UIKit

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
    let detail: ChekinanaIdolCardDetail
    let confirmationCode: String?
    let selectionToken: String?
}

struct ChekinanaEventCard: Identifiable, Equatable {
    let id: UUID
    let name: String
    let date: String
    let city: String
    let livehouse: String
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

struct ChekinanaPendingChekiImage: Equatable, Sendable {
    let data: Data
    let filenameExtension: String
}

struct ChekinanaAlbumAddChekiRequest: Equatable, Sendable {
    let arguments: [String: String]
}

struct ChekinanaPreparedAlbumCheki: Equatable, Sendable {
    let request: ChekinanaAlbumAddChekiRequest
    let image: ChekinanaPendingChekiImage
    let thumbnailImageData: Data?
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
    case idolSections([ChekinanaIdolSection])
    case eventCard(ChekinanaEventCard)
    case eventCards([ChekinanaEventCard])
    case requestAddChekiPhoto(ChekinanaAlbumAddChekiRequest)
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
        let eventDate: Date?
        let userAppears: Bool?
        let size: ChekiSize?
        let note: String
        let dateAnnotationState: ChekinanaChekiDateAnnotationState
        let createdAt: Date
    }

    struct AddEventPayload {
        let name: String
        let date: Date?
        let city: String?
        let livehouse: String?
        let weiboURL: URL?
        let ticketURL: URL?
        let note: String

        init(
            name: String,
            date: Date?,
            city: String? = nil,
            livehouse: String? = nil,
            weiboURL: URL? = nil,
            ticketURL: URL? = nil,
            note: String = ""
        ) {
            self.name = name
            self.date = date
            self.city = city
            self.livehouse = livehouse
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
        let weiboURL: URL?
        let ticketURL: URL?
        let note: String
    }

    struct DeleteEventPayload {
        let eventID: UUID
    }

    struct EditChekiPayload {
        let chekiID: UUID
        let expectedUpdatedAt: Date
        let idolIDs: [UUID]
        let eventID: UUID?
        let eventDate: Date?
        let userAppears: Bool?
        let size: ChekiSize?
        let note: String
    }

    struct EditIdolPayload {
        let idolID: UUID
        let values: [String: String]
    }

    struct DeleteIdolPayload {
        let idolID: UUID
    }

    struct DeleteChekiPayload {
        let chekiID: UUID
        let phase: DeleteChekiPhase
    }

    enum DeleteChekiPhase {
        case deleteModel
        case restoreThenDelete(originalURL: URL, quarantineURL: URL)
        case cleanupQuarantine(URL)
    }

    struct TemporaryCheki {
        let id: UUID
        let image: ChekinanaPendingChekiImage
        let thumbnailImageData: Data?
        let dateAnnotationState: ChekinanaChekiDateAnnotationState
        let createdAt: Date
    }

    struct TemporaryChekiChoice: Identifiable, Equatable {
        let id: UUID
        let createdAt: Date
    }

    struct IdolCandidateChoice {
        let token: String
        let candidate: ChekinanaEnrichedIdol
    }

    enum Action {
        case addIdol(ChekinanaEnrichedIdol)
        case editIdol(EditIdolPayload)
        case deleteIdol(DeleteIdolPayload)
        case addEvent(AddEventPayload)
        case editEvent(EditEventPayload)
        case deleteEvent(DeleteEventPayload)
        case addCheki(AddChekiPayload)
        case editCheki(EditChekiPayload)
        case deleteCheki(DeleteChekiPayload)
        case downloadCheki(chekiID: UUID, imageURL: URL)
    }

    struct Entry {
        let code: String
        let batchID: UUID?
        let action: Action
    }

    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private var expiredCodes = Set<String>()
    private var temporaryChekis: [UUID: TemporaryCheki] = [:]
    private var idolCandidates: [String: ChekinanaEnrichedIdol] = [:]
    private var idolQueryGeneration: UInt64 = 0
    private var implicitConfirmationStartIndex = 0

    private let maximumTemporaryChekiCount = 20
    private let maximumTemporaryChekiBytes = 100 * 1_024 * 1_024
    private let temporaryChekiTTL: TimeInterval = 30 * 60

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
        _ candidate: ChekinanaEnrichedIdol,
        generation: UInt64
    ) -> String? {
        guard generation == idolQueryGeneration else { return nil }
        return insert(.addIdol(candidate))
    }

    func replaceIdolCandidates(
        _ candidates: [ChekinanaEnrichedIdol],
        generation: UInt64
    ) -> [IdolCandidateChoice]? {
        guard generation == idolQueryGeneration else { return nil }
        idolCandidates.removeAll()
        return candidates.map { candidate in
            var token: String
            repeat { token = UUID().uuidString.lowercased() } while idolCandidates[token] != nil
            idolCandidates[token] = candidate
            return IdolCandidateChoice(token: token, candidate: candidate)
        }
    }

    func consumeIdolCandidate(_ rawToken: String) -> ChekinanaEnrichedIdol? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = idolCandidates[token]
        invalidateIdolCandidates()
        return candidate
    }

    func invalidateIdolCandidates() {
        idolQueryGeneration &+= 1
        idolCandidates.removeAll()
    }

    func entry(for rawCode: String) -> Entry? {
        entries[Self.normalizedCode(rawCode)]
    }

    var activeConfirmationCodes: Set<String> {
        Set(entries.keys)
    }

    func updateAddIdolCandidate(_ resolved: ChekinanaEnrichedIdol, for rawCode: String) -> Bool {
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
        dateAnnotationStates: [ChekinanaChekiDateAnnotationState]? = nil
    ) throws -> TemporaryChekiInsertion {
        precondition(images.count == thumbnailImageData.count)
        let annotationStates = dateAnnotationStates
            ?? Array(repeating: .notRequested, count: images.count)
        precondition(images.count == annotationStates.count)
        let initialIDs = Set(temporaryChekis.keys)
        let initialBytes = temporaryChekiBytes
        let incomingBytes = images.reduce(0) { partial, image in
            partial.addingReportingOverflow(image.data.count).overflow ? Int.max : partial + image.data.count
        }
        guard images.count <= maximumTemporaryChekiCount,
              incomingBytes <= maximumTemporaryChekiBytes else {
            throw ChekinanaTemporaryChekiError.capacityExceeded(
                count: temporaryChekis.count,
                bytes: temporaryChekiBytes
            )
        }

        // Plan the complete batch against a snapshot before mutating anything.
        // A rejected batch must leave every existing temporary image intact.
        let now = Date()
        let protectedIDs = pendingTemporaryChekiIDs
        let removable = temporaryChekis.values.filter { !protectedIDs.contains($0.id) }
        let expired = removable.filter {
            now.timeIntervalSince($0.createdAt) >= temporaryChekiTTL
        }
        let evictionCandidates = removable
            .filter { now.timeIntervalSince($0.createdAt) < temporaryChekiTTL }
            .sorted { $0.createdAt < $1.createdAt }
        var evictionIDs = expired.map(\.id)
        var plannedCount = temporaryChekis.count - expired.count
        var plannedBytes = temporaryChekiBytes - expired.reduce(0) { $0 + $1.image.data.count }
        var candidateIndex = 0
        while plannedCount + images.count > maximumTemporaryChekiCount
                || plannedBytes + incomingBytes > maximumTemporaryChekiBytes {
            guard candidateIndex < evictionCandidates.count else {
                assert(Set(temporaryChekis.keys) == initialIDs && temporaryChekiBytes == initialBytes)
                throw ChekinanaTemporaryChekiError.capacityExceeded(
                    count: temporaryChekis.count,
                    bytes: temporaryChekiBytes
                )
            }
            let candidate = evictionCandidates[candidateIndex]
            evictionIDs.append(candidate.id)
            plannedCount -= 1
            plannedBytes -= candidate.image.data.count
            candidateIndex += 1
        }

        for id in evictionIDs {
            temporaryChekis.removeValue(forKey: id)
        }

        let inserted = images.indices.map { index in
            let image = images[index]
            var id: UUID
            repeat { id = UUID() } while temporaryChekis[id] != nil
            let value = TemporaryCheki(
                id: id,
                image: image,
                thumbnailImageData: thumbnailImageData[index],
                dateAnnotationState: annotationStates[index],
                createdAt: Date()
            )
            temporaryChekis[id] = value
            return value
        }
        assert(temporaryChekis.count == plannedCount + images.count)
        assert(temporaryChekiBytes == plannedBytes + incomingBytes)
        assert(temporaryChekis.count <= maximumTemporaryChekiCount)
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

    func consumeTemporaryCheki(_ id: UUID) {
        temporaryChekis.removeValue(forKey: id)
    }

    func discardTemporaryCheki(id: UUID) {
        guard !pendingTemporaryChekiIDs.contains(id) else { return }
        temporaryChekis.removeValue(forKey: id)
    }

    func containsTemporaryCheki(_ id: UUID) -> Bool {
        temporaryChekis[id] != nil
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
        temporaryChekis.removeValue(forKey: value.id)
        return String(value.id.uuidString.prefix(8)).lowercased()
    }

    func discardAllUnreferencedTemporaryChekis() -> (discarded: Int, retained: Int) {
        _ = pruneExpiredTemporaryChekis()
        let protectedIDs = pendingTemporaryChekiIDs
        let removableIDs = temporaryChekis.keys.filter { !protectedIDs.contains($0) }
        for id in removableIDs {
            temporaryChekis.removeValue(forKey: id)
        }
        return (removableIDs.count, temporaryChekis.count)
    }

    private var pendingTemporaryChekiIDs: Set<UUID> {
        Set(entries.values.compactMap { entry in
            guard case .addCheki(let payload) = entry.action else { return nil }
            return payload.temporaryChekiID
        })
    }

    private var temporaryChekiBytes: Int {
        temporaryChekis.values.reduce(0) { $0 + $1.image.data.count }
    }

    @discardableResult
    private func pruneExpiredTemporaryChekis(now: Date = Date()) -> Int {
        let protectedIDs = pendingTemporaryChekiIDs
        let expiredIDs: [UUID] = temporaryChekis.values.compactMap { value -> UUID? in
            guard !protectedIDs.contains(value.id),
                  now.timeIntervalSince(value.createdAt) >= temporaryChekiTTL else { return nil }
            return value.id
        }
        for id in expiredIDs {
            temporaryChekis.removeValue(forKey: id)
        }
        return expiredIDs.count
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
        guard let entry = entries[code], !entry.requiresRecoveryConfirmation else {
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
            .filter { !$0.requiresRecoveryConfirmation }
            .map(\.code)
        for code in cancellableCodes {
            entries.removeValue(forKey: code)
        }
        expiredCodes.formUnion(cancellableCodes)
        return (cancellableCodes.count, entries.count)
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

@MainActor
struct ChekinanaCommandExecutor {
    typealias ScannerProcess = (
        ChekinanaPendingChekiImage,
        ChekinanaScannerOptions
    ) async throws -> ChekinanaScannerProcessResult
    typealias IdolSearch = (String) async throws -> [ChekinanaEnrichedIdol]

    let modelContext: ModelContext
    let confirmationLedger: ChekinanaConfirmationLedger
    private let scannerProcess: ScannerProcess
    private let idolSearch: IdolSearch

    init(
        modelContext: ModelContext,
        confirmationLedger: ChekinanaConfirmationLedger,
        scannerProcess: @escaping ScannerProcess = { image, options in
            try await ChekinanaScannerClient().process(image, options: options)
        },
        idolSearch: @escaping IdolSearch = { name in
            try await ChekinanaIdolEnrichmentClient().search(for: name)
        }
    ) {
        self.modelContext = modelContext
        self.confirmationLedger = confirmationLedger
        self.scannerProcess = scannerProcess
        self.idolSearch = idolSearch
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
                return .text("error: there is no pending operation to confirm")
            case .ambiguousAddIdol:
                return .text("error: the latest addidol returned multiple candidates; use confirm <8_hex_code> to choose one")
            case .code(let code):
                return await confirm(code)
            }
        }

        if simpleTokens.count == 2, simpleTokens[0].lowercased() == "cancel" {
            if simpleTokens[1].lowercased() == "all" {
                let result = confirmationLedger.cancelAll()
                if result.retainedForRecovery > 0 {
                    return .text("cancelled pending confirmations: \(result.cancelled); retained for required file recovery/cleanup: \(result.retainedForRecovery). Retry confirm to finish safely")
                }
                return .text("cancelled pending confirmations: \(result.cancelled)")
            }

            guard ChekinanaConfirmationLedger.isCode(simpleTokens[1]) else {
                return .text("error: confirmation code must be 8 lowercase hexadecimal characters")
            }

            if confirmationLedger.cancel(simpleTokens[1]) {
                return .text("cancelled confirmation: \(simpleTokens[1].lowercased())")
            }

            if confirmationLedger.cancellationRequiresRecovery(simpleTokens[1]) {
                return .text("error: this deletecheki confirmation cannot be cancelled while managed image recovery or cleanup is pending; retry confirm")
            }

            return invalidConfirmationCode(simpleTokens[1])
        }

        if let first = simpleTokens.first?.lowercased(), ["confirm", "cancel"].contains(first) {
            return .text("error: invalid usage\n\nusage:\nconfirm [8_hex_code]\ncancel <8_hex_code>\ncancel all")
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

            return .text("error: \(error.localizedDescription)")
        }

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
            return .text("unknown command: \(command.name)\n\n\(helpText)")
        }

        if command.name == "addidol" {
            return await addIdol(command, usage: usage)
        }

        if command.name == "selectidolcandidate" {
            return selectIdolCandidate(command, usage: usage)
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

        return .text("""
        command not implemented: \(command.name)

        usage:
        \(usage.joined(separator: "\n"))
        """)
    }

    func prepareEventCandidate(_ rawFields: ChekinanaEventCandidateFields) -> ChekinanaCommandResponse {
        let fields = ChekinanaEventCandidateFields(
            name: rawFields.name.trimmingCharacters(in: .whitespacesAndNewlines),
            date: rawFields.date.trimmingCharacters(in: .whitespacesAndNewlines),
            city: rawFields.city.trimmingCharacters(in: .whitespacesAndNewlines),
            livehouse: rawFields.livehouse.trimmingCharacters(in: .whitespacesAndNewlines),
            weiboURL: rawFields.weiboURL.trimmingCharacters(in: .whitespacesAndNewlines),
            ticketURL: rawFields.ticketURL.trimmingCharacters(in: .whitespacesAndNewlines),
            note: rawFields.note
        )
        let blockers = ChekinanaEventCandidateValidator.blockers(for: fields)
        guard blockers.isEmpty else {
            return .text("error: Event candidate is not ready: \(blockers.map(\.message).joined(separator: " "))")
        }
        do {
            let date = fields.date.isEmpty ? nil : try parseCalendarDate(fields.date)
            guard let weiboURL = URL(string: fields.weiboURL) else {
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
                weiboURL: weiboURL,
                ticketURL: ticketURL,
                note: fields.note
            )))
            return .eventCard(eventCard(fields, confirmationCode: code))
        } catch {
            return .text("error: \(error.localizedDescription)")
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
        .text("""
        error: invalid usage

        usage:
        \(usage.joined(separator: "\n"))
        """)
    }

    private func invalidConfirmationCode(_ code: String) -> ChekinanaCommandResponse {
        if confirmationLedger.isExpired(code) {
            return .text("error: confirmation code expired: \(ChekinanaConfirmationLedger.normalizedCode(code))")
        }
        return .text("error: invalid or expired confirmation code: \(ChekinanaConfirmationLedger.normalizedCode(code))")
    }

    private func confirm(_ rawCode: String) async -> ChekinanaCommandResponse {
        guard ChekinanaConfirmationLedger.isCode(rawCode) else {
            return .text("error: confirmation code must be 8 lowercase hexadecimal characters")
        }

        guard let entry = confirmationLedger.entry(for: rawCode) else {
            return invalidConfirmationCode(rawCode)
        }

        do {
            let response: ChekinanaCommandResponse

            switch entry.action {
            case .addIdol(let resolved):
                if try hasIdol(sourceId: resolved.sourceId) {
                    // This candidate is no longer retryable. Expire its whole
                    // result batch so a second pending code cannot bypass the
                    // stable catalogue-ID check.
                    confirmationLedger.removeAfterSuccess(entry)
                    return .text("error: idol already added: \(resolved.sourceId)")
                }
                let idol = Idol(
                    sourceId: resolved.sourceId,
                    name: resolved.idolName,
                    group: resolved.groupName,
                    color: resolved.color,
                    birthday: resolved.birthday,
                    avatarImageRef: resolved.avatarUrl
                )
                modelContext.insert(idol)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.delete(idol)
                    modelContext.rollback()
                    throw error
                }
                response = .idolCard(idolCard(idol))

            case .editIdol(let payload):
                let idol = try refetchIdolByID(payload.idolID)
                applyIdolEdit(payload.values, to: idol)
                idol.updatedAt = Date()
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    throw error
                }
                response = .idolCard(idolCard(idol))

            case .deleteIdol(let payload):
                let idol = try refetchIdolByID(payload.idolID)
                guard idol.chekis.isEmpty else {
                    throw ChekinanaDeleteError.idolHasChekis(idol.chekis.count)
                }
                modelContext.delete(idol)
                do { try modelContext.save() } catch {
                    modelContext.rollback()
                    throw error
                }
                response = .text("已删除 Idol。")

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
                    weiboURL: payload.weiboURL,
                    ticketURL: payload.ticketURL,
                    note: payload.note
                )
                modelContext.insert(event)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.delete(event)
                    modelContext.rollback()
                    throw error
                }
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
                guard event.chekis.isEmpty else {
                    throw ChekinanaDeleteError.eventHasChekis(event.chekis.count)
                }
                modelContext.delete(event)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    throw error
                }
                response = .text("已删除 Event。")

            case .addCheki(let payload):
                if let temporaryChekiID = payload.temporaryChekiID,
                   !confirmationLedger.containsTemporaryCheki(temporaryChekiID) {
                    throw ChekinanaTemporaryChekiError.alreadyConsumed(
                        String(temporaryChekiID.uuidString.prefix(8)).lowercased()
                    )
                }
                let idols = try refetchIdolsByIDs(payload.idolIDs)
                let event = try refetchEventByID(payload.eventID)
                try validateChekiAssociations(idols: idols, event: event, eventDate: payload.eventDate)
                let idx = try nextChekiIndex(
                    idolIDs: idols.map(\.id),
                    eventID: event?.id,
                    eventDate: payload.eventDate,
                    excludingChekiID: nil
                )
                response = try await persistCheki(
                    id: payload.id,
                    image: payload.image,
                    thumbnailImageData: payload.thumbnailImageData,
                    idols: idols,
                    event: event,
                    eventDate: payload.eventDate,
                    idx: idx,
                    userAppears: payload.userAppears,
                    size: payload.size,
                    note: payload.note,
                    dateAnnotationState: payload.dateAnnotationState,
                    createdAt: payload.createdAt
                )
                if let temporaryChekiID = payload.temporaryChekiID {
                    confirmationLedger.consumeTemporaryCheki(temporaryChekiID)
                }

            case .editCheki(let payload):
                let cheki = try refetchChekiByID(payload.chekiID)
                guard cheki.updatedAt == payload.expectedUpdatedAt else {
                    throw ChekinanaEditConflictError.staleCheki(entry.code)
                }
                let idols = try refetchIdolsByIDs(payload.idolIDs)
                let event = try refetchEventByID(payload.eventID)
                try validateChekiAssociations(idols: idols, event: event, eventDate: payload.eventDate)
                let groupingChanged = !sameChekiGroup(
                    idolIDs: cheki.idols.map(\.id),
                    eventID: cheki.event?.id,
                    eventDate: cheki.eventDate,
                    otherIdolIDs: idols.map(\.id),
                    otherEventID: event?.id,
                    otherEventDate: payload.eventDate
                )
                let requiresIndexAssignment = groupingChanged || (cheki.idx ?? 0) < 1
                let idx = requiresIndexAssignment
                    ? try nextChekiIndex(
                        idolIDs: idols.map(\.id),
                        eventID: event?.id,
                        eventDate: payload.eventDate,
                        excludingChekiID: cheki.id
                    )
                    : cheki.idx
                cheki.idols = idols
                cheki.event = event
                cheki.eventDate = payload.eventDate
                cheki.idx = idx
                cheki.userAppears = payload.userAppears
                cheki.size = payload.size
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

            case .downloadCheki(let chekiID, let imageURL):
                _ = try refetchChekiByID(chekiID)
                try await ChekiPhotoLibrarySaver.saveImage(at: imageURL)
                response = .text("已把这张切保存到系统相册。")
            }

            confirmationLedger.removeAfterSuccess(entry)
            return response
        } catch {
            return .text("确认失败，这项操作仍然保留在待确认列表中。\(error.localizedDescription)")
        }
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
            return .text("已删除这张切。")

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
                .init(chekiID: payload.chekiID, phase: .deleteModel),
                for: confirmationCode
            )

        case .deleteModel:
            break
        }

        let cheki = try refetchChekiByID(payload.chekiID)
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
                .init(chekiID: payload.chekiID, phase: .cleanupQuarantine(quarantineURL)),
                for: confirmationCode
            )
            do {
                try fileManager.removeItem(at: quarantineURL)
            } catch {
                throw ChekinanaDeleteError.managedImageCleanupFailed(error.localizedDescription)
            }
        }
        return .text("已删除这张切。")
    }

    private func addIdol(_ command: ChekinanaParsedCommand, usage: [String]) async -> ChekinanaCommandResponse {
        guard let target = command.target,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.arguments.isEmpty else {
            return .text("""
            error: invalid usage

            usage:
            \(usage.joined(separator: "\n"))
            """)
        }

        let generation = confirmationLedger.beginIdolQuery()
        do {
            let searchResults = try await idolSearch(target)
            try Task.checkCancellation()
            var seenSourceIDs = Set<String>()
            let results = searchResults.filter { result in
                !result.sourceId.isEmpty && seenSourceIDs.insert(result.sourceId).inserted
            }
            let sourceIDs = Set(results.map(\.sourceId).filter { !$0.isEmpty })
            var existingSourceIDs = Set<String>()
            for sourceID in sourceIDs where try hasIdol(sourceId: sourceID) {
                existingSourceIDs.insert(sourceID)
            }
            let addableResults = results.filter { !existingSourceIDs.contains($0.sourceId) }
            guard !addableResults.isEmpty else {
                return .text("idol already added: \(results.map(\.sourceId).joined(separator: ", "))")
            }
            if addableResults.count == 1, let resolved = addableResults.first {
                try Task.checkCancellation()
                guard let code = confirmationLedger.publishIdolConfirmation(
                    resolved,
                    generation: generation
                ) else {
                    return .text("error: this Idol query is no longer active; run the Idol query again")
                }
                return .idolCard(candidateCard(resolved, confirmationCode: code))
            }

            try Task.checkCancellation()
            guard let choices = confirmationLedger.replaceIdolCandidates(
                addableResults,
                generation: generation
            ) else {
                return .text("error: this Idol query is no longer active; run the Idol query again")
            }
            let cards = choices.map { choice in
                candidateCard(
                    choice.candidate,
                    confirmationCode: nil,
                    selectionToken: choice.token
                )
            }
            return .idolCards(cards)
        } catch {
            return .text("error: \(error.localizedDescription)")
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
            return .text("error: this Idol candidate is no longer available; run the Idol query again")
        }
        do {
            guard try !hasIdol(sourceId: candidate.sourceId) else {
                return .text("error: idol already added: \(candidate.sourceId)")
            }
            let code = confirmationLedger.insert(.addIdol(candidate))
            return .idolCard(candidateCard(candidate, confirmationCode: code))
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func editIdol(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        var values = command.arguments
        if let avatarAlias = values.removeValue(forKey: "avatar_url") {
            guard values["avatar"] == nil else {
                return .text("error: duplicate avatar field; use avatar only")
            }
            values["avatar"] = avatarAlias
        }

        let allowedFields = Set(["name", "group", "birthday", "color", "avatar"])
        guard let target = command.target,
              !values.isEmpty else {
            return invalidUsage(usage)
        }

        let unsupportedFields = values.keys.filter { !allowedFields.contains($0) }.sorted()
        guard unsupportedFields.isEmpty else {
            return .text("""
            error: unsupported editidol field(s): \(unsupportedFields.joined(separator: ", "))

            usage:
            \(usage.joined(separator: "\n"))
            """)
        }

        for (field, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || (field == "name" && trimmed == "-") {
                return .text("error: \(field) requires a non-empty value; use - only to clear optional fields")
            }

            if field == "avatar", trimmed != "-", isUnsafeLocalAvatarReference(trimmed) {
                return .text("error: avatar must be an http(s) URL or a managed image reference, not a local file path")
            }
        }

        if let entry = confirmationLedger.entry(for: target), case .addIdol(let candidate) = entry.action {
            let edited = editedCandidate(candidate, values: values)
            guard confirmationLedger.updateAddIdolCandidate(edited, for: target) else {
                return .text("error: candidate is no longer available: \(target)")
            }
            return .idolCard(candidateCard(edited, confirmationCode: entry.code))
        }

        do {
            let idol = try resolveUniqueIdol(target)
            let code = confirmationLedger.insert(
                .editIdol(.init(idolID: idol.id, values: values))
            )
            return .idolCard(previewCard(for: idol, values: values, confirmationCode: code))
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func deleteIdol(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            let idol = try resolveUniqueIdol(target)
            guard idol.chekis.isEmpty else {
                return .text("error: idol has \(idol.chekis.count) associated cheki; delete or reassign them before deleting the idol")
            }
            let code = confirmationLedger.insert(.deleteIdol(.init(idolID: idol.id)))
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
                detail: .deleteCandidate,
                confirmationCode: code,
                selectionToken: nil
            )
            return .idolCard(card)
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func editedCandidate(
        _ candidate: ChekinanaEnrichedIdol,
        values: [String: String]
    ) -> ChekinanaEnrichedIdol {
        ChekinanaEnrichedIdol(
            sourceId: candidate.sourceId,
            idolName: editedRequired(candidate.idolName, field: "name", values: values),
            groupName: editedOptional(candidate.groupName, field: "group", values: values),
            color: editedOptional(candidate.color, field: "color", values: values),
            birthday: editedOptional(candidate.birthday, field: "birthday", values: values),
            verification: candidate.verification,
            bio: candidate.bio,
            avatarUrl: editedOptional(candidate.avatarUrl, field: "avatar", values: values)
        )
    }

    private func candidateCard(
        _ candidate: ChekinanaEnrichedIdol,
        confirmationCode: String?,
        selectionToken: String? = nil
    ) -> ChekinanaIdolCard {
        ChekinanaIdolCard(
            id: UUID(),
            catalogueID: candidate.sourceId,
            name: candidate.idolName,
            group: candidate.groupName,
            color: candidate.color,
            birthday: candidate.birthday,
            verification: candidate.verification,
            bio: candidate.bio,
            avatarImageRef: candidate.avatarUrl,
            detail: .addCandidate,
            confirmationCode: confirmationCode,
            selectionToken: selectionToken
        )
    }

    private func previewCard(
        for idol: Idol,
        values: [String: String],
        confirmationCode: String
    ) -> ChekinanaIdolCard {
        ChekinanaIdolCard(
            id: idol.id,
            catalogueID: idol.sourceId,
            name: editedRequired(idol.name, field: "name", values: values),
            group: editedOptional(idol.group, field: "group", values: values),
            color: editedOptional(idol.color, field: "color", values: values),
            birthday: editedOptional(idol.birthday, field: "birthday", values: values),
            verification: nil,
            bio: nil,
            avatarImageRef: editedOptional(idol.avatarImageRef, field: "avatar", values: values),
            detail: .chekiCount(idol.chekis.count),
            confirmationCode: confirmationCode,
            selectionToken: nil
        )
    }

    private func applyIdolEdit(_ values: [String: String], to idol: Idol) {
        idol.name = editedRequired(idol.name, field: "name", values: values)
        idol.group = editedOptional(idol.group, field: "group", values: values)
        idol.color = editedOptional(idol.color, field: "color", values: values)
        idol.birthday = editedOptional(idol.birthday, field: "birthday", values: values)
        idol.avatarImageRef = editedOptional(idol.avatarImageRef, field: "avatar", values: values)
    }

    private func isUnsafeLocalAvatarReference(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("~") || value.contains("\\") {
            return true
        }

        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return value.contains("/") || value == "." || value == ".."
        }

        return !["http", "https"].contains(scheme)
    }

    private func editedRequired(_ current: String, field: String, values: [String: String]) -> String {
        values[field]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? current
    }

    private func editedOptional(_ current: String?, field: String, values: [String: String]) -> String? {
        guard let rawValue = values[field] else {
            return current
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "-" ? nil : trimmed
    }

    private func listIdol(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard command.target == nil, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }

        do {
            let descriptor = FetchDescriptor<Idol>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let idols = try modelContext.fetch(descriptor)

            guard !idols.isEmpty else {
                return .text("还没有添加 Idol。")
            }

            return .idolCards(idols.map { idolCard($0) })
        } catch {
            return .text("error: failed to fetch idols: \(error.localizedDescription)")
        }
    }

    private func showIdol(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return .text("""
            error: invalid usage

            usage:
            \(usage.joined(separator: "\n"))
            """)
        }

        let normalizedTarget = target.lowercased()

        do {
            let descriptor = FetchDescriptor<Idol>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let idols = try modelContext.fetch(descriptor)
            let idMatches = idols.filter { idol in
                idol.id.uuidString.lowercased().hasPrefix(normalizedTarget)
            }

            if idMatches.count > 1 {
                return .text("error: ambiguous idol id: \(target)")
            }

            if let idol = idMatches.first {
                return showIdolResponse(for: [idol])
            }

            let nameMatches = idols.filter { idol in
                idol.name.range(of: target, options: [.caseInsensitive]) != nil
            }

            guard !nameMatches.isEmpty else {
                return .text("error: no idol matches: \(target)")
            }

            return showIdolResponse(for: nameMatches)
        } catch {
            return .text("error: failed to fetch idol: \(error.localizedDescription)")
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
                    prefix: "prepared add event",
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
                prefix: "prepared add event",
                confirmationCode: code
            ), confirmationCode: code)
        } catch {
            return .text("error: \(error.localizedDescription)")
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
            guard !events.isEmpty else { return .text("还没有添加 Event。") }
            return .eventCards(events.map(eventCard))
        } catch {
            return .text("error: failed to fetch events: \(error.localizedDescription)")
        }
    }

    private func showEvent(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            return .eventCard(eventCard(try resolveUniqueEvent(target)))
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func editEvent(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        let allowedFields = Set(["name", "date", "url"])
        guard let target = command.target,
              !command.arguments.isEmpty,
              command.arguments.keys.allSatisfy(allowedFields.contains) else {
            return invalidUsage(usage)
        }
        do {
            let event = try resolveUniqueEvent(target)
            var name = event.name
            var date = event.date
            var url = event.weiboURL

            if let value = command.arguments["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                guard !value.isEmpty, value != "-" else { throw ChekinanaEventError.invalidName }
                name = value
            }
            if let value = command.arguments["date"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                date = value == "-" ? nil : try parseCalendarDate(value)
            }
            if let value = command.arguments["url"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                url = value == "-" ? nil : try requireHTTPURL(value)
            }

            let code = confirmationLedger.insert(.editEvent(.init(
                eventID: event.id,
                expectedUpdatedAt: event.updatedAt,
                name: name,
                date: date,
                city: event.city,
                livehouse: event.livehouse,
                weiboURL: url,
                ticketURL: event.ticketURL,
                note: event.note
            )))
            return .confirmationText(eventPreviewDetails(
                id: event.id,
                name: name,
                date: date,
                weiboURL: url,
                prefix: "prepared edit event",
                confirmationCode: code
            ), confirmationCode: code)
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func deleteEvent(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            let event = try resolveUniqueEvent(target)
            guard event.chekis.isEmpty else {
                return .text("error: event has \(event.chekis.count) associated cheki; reassign or delete them before deleting the event")
            }
            let code = confirmationLedger.insert(.deleteEvent(.init(eventID: event.id)))
            return .confirmationText(eventPreviewDetails(
                id: event.id,
                name: event.name,
                date: event.date,
                weiboURL: event.weiboURL,
                prefix: "prepared delete event",
                confirmationCode: code
            ), confirmationCode: code)
        } catch {
            return .text("error: \(error.localizedDescription)")
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
                return .text("error: addcheki no longer accepts temporary Cheki IDs. Use addscancheki <temporary_cheki_id> idol=<idol_id_or_name> event=<event_id> or date=YYYY-MM-DD")
            }
            _ = try resolvedAddChekiFields(arguments)
            return .requestAddChekiPhoto(.init(arguments: arguments))
        } catch {
            return .text("error: \(error.localizedDescription)")
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
        guard !(command.target != nil && keyed != nil),
              let value = command.target ?? keyed,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChekinanaAddChekiError.invalidIdolList
        }
        if let userAppears = arguments.removeValue(forKey: "userappears") {
            guard arguments["user"] == nil else {
                throw ChekinanaAddChekiError.duplicateArgument("user")
            }
            arguments["user"] = userAppears
        }
        arguments["idol"] = value
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
        let event = try refetchEventByID(fields.eventID)
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
                eventID: fields.eventID,
                eventDate: fields.eventDate,
                userAppears: fields.userAppears,
                size: fields.size,
                note: fields.note,
                dateAnnotationState: .notRequested,
                createdAt: createdAt
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
        let failureSuffix = failedCount == 0 ? "" : "；另有 \(failedCount) 张照片无法读取"
        return .pendingChekiCards(
            "已从相册准备 \(cards.count) 张切\(failureSuffix)。",
            cards,
            consumesSelectedPhotos: false
        )
    }

    private func addScanCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String]
    ) -> ChekinanaCommandResponse {
        let allowed = Set(["idol", "idols", "event", "date", "user", "userappears", "size", "note"])
        guard let target = command.target,
              command.arguments.keys.allSatisfy(allowed.contains),
              let idolValue = command.arguments["idol"] ?? command.arguments["idols"],
              !(command.arguments["idol"] != nil && command.arguments["idols"] != nil) else {
            return invalidUsage(usage)
        }
        do {
            var arguments = command.arguments
            arguments.removeValue(forKey: "idols")
            arguments["idol"] = idolValue
            if let userAppears = arguments.removeValue(forKey: "userappears") {
                guard arguments["user"] == nil else {
                    throw ChekinanaAddChekiError.duplicateArgument("user")
                }
                arguments["user"] = userAppears
            }
            let fields = try resolvedAddChekiFields(arguments)
            let idols = try refetchIdolsByIDs(fields.idolIDs)
            let event = try refetchEventByID(fields.eventID)
            let temporaryValues = try confirmationLedger.resolveTemporaryChekis(target)
            var cards: [ChekinanaChekiCard] = []
            for temporary in temporaryValues {
                let id = UUID()
                let createdAt = Date()
                let code = confirmationLedger.insert(.addCheki(.init(
                    id: id,
                    temporaryChekiID: temporary.id,
                    image: temporary.image,
                    thumbnailImageData: temporary.thumbnailImageData,
                    idolIDs: fields.idolIDs,
                    eventID: fields.eventID,
                    eventDate: fields.eventDate,
                    userAppears: fields.userAppears,
                    size: fields.size,
                    note: fields.note,
                    dateAnnotationState: temporary.dateAnnotationState,
                    createdAt: createdAt
                )))
                cards.append(.init(
                    id: id,
                    imageRef: nil,
                    createdAt: createdAt,
                    confirmationCode: code,
                    thumbnailImageData: temporary.thumbnailImageData,
                    idolNames: idols.map(\.name),
                    eventName: event?.name,
                    eventDateText: fields.eventDate.map(calendarDateString),
                    note: fields.note,
                    dateAnnotationState: temporary.dateAnnotationState
                ))
            }
            return .pendingChekiCards(
                "已准备保存 \(cards.count) 张扫描结果。",
                cards,
                consumesSelectedPhotos: false
            )
        } catch {
            return .text("error: \(error.localizedDescription)")
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

    private func resolvedAddChekiFields(_ arguments: [String: String]) throws -> ResolvedAddChekiFields {
        let idols = try arguments["idol"].map { try resolveIdolList($0) } ?? []
        guard !idols.isEmpty else { throw ChekinanaAddChekiError.invalidIdolList }
        let rawEvent = arguments["event"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDate = arguments["date"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasEvent = rawEvent.map { !$0.isEmpty && $0 != "?" && $0 != "-" } ?? false
        let hasDate = rawDate.map { !$0.isEmpty && $0 != "?" && $0 != "-" } ?? false
        guard hasEvent != hasDate else {
            throw ChekinanaAddChekiError.eventOrDateRequired
        }
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

    private func scanCheki(
        _ command: ChekinanaParsedCommand,
        usage: [String],
        pendingImages: [ChekinanaPendingChekiImage]
    ) async -> ChekinanaCommandResponse {
        let allowedArguments = Set([
            "pod", "expected", "scanner_size", "postprocess", "wb", "date_annotation",
        ])
        guard command.arguments.keys.allSatisfy(allowedArguments.contains),
              !(command.target != nil && command.arguments["pod"] != nil) else {
            return invalidUsage(usage)
        }

        do {
            try Task.checkCancellation()
            let options = try scanChekiOptions(from: command)
            guard !pendingImages.isEmpty else {
                return .text("error: select one or more photos with the album button before running scancheki")
            }

            var scannedImages: [ChekinanaPendingChekiImage] = []
            var dateAnnotationStates: [ChekinanaChekiDateAnnotationState] = []
            var warningCount = 0
            for pendingImage in pendingImages {
                try Task.checkCancellation()
                let result = try await scannerProcess(pendingImage, options)
                try Task.checkCancellation()
                for resultImage in result.images {
                    try Task.checkCancellation()
                    guard let jpegData = await ChekinanaImageWorker.reencodedJPEGData(
                        from: resultImage.data
                    ),
                          !jpegData.isEmpty else {
                        throw ChekinanaScanChekiError.invalidResultImage
                    }
                    try Task.checkCancellation()
                    scannedImages.append(ChekinanaPendingChekiImage(
                        data: jpegData,
                        filenameExtension: "jpg"
                    ))
                    dateAnnotationStates.append(resultImage.dateAnnotationState)
                }
                warningCount += result.warningCount
            }
            guard !scannedImages.isEmpty else {
                throw ChekinanaScanChekiError.noResultImages
            }

            try Task.checkCancellation()
            let thumbnails = await ChekinanaImageWorker.thumbnailDataBatch(
                from: scannedImages.map(\.data)
            )
            try Task.checkCancellation()
            let insertion = try confirmationLedger.insertTemporaryChekis(
                scannedImages,
                thumbnailImageData: thumbnails,
                dateAnnotationStates: dateAnnotationStates
            )
            let cards = insertion.inserted.map { temporary in
                ChekinanaChekiCard(
                    id: temporary.id,
                    imageRef: nil,
                    createdAt: temporary.createdAt,
                    confirmationCode: nil,
                    thumbnailImageData: temporary.thumbnailImageData,
                    dateAnnotationState: temporary.dateAnnotationState
                )
            }
            return .chekiScannedCards(
                cards.count,
                warningCount: warningCount + insertion.evictedCount,
                cards
            )
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
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
                return .text(
                    "discarded temporary cheki: \(result.discarded); retained \(result.retained) referenced by pending addscancheki confirmation. Confirm or cancel those operations first"
                )
            }
            return .text("discarded temporary cheki: \(result.discarded)")
        }

        do {
            let shortID = try confirmationLedger.discardTemporaryCheki(target)
            return .text("discarded temporary cheki: \(shortID)")
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func listCheki(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        let allowedArguments = Set(["idol", "event", "date"])

        guard command.target == nil,
              command.arguments.keys.allSatisfy({ allowedArguments.contains($0) }),
              !(command.arguments["event"] != nil && command.arguments["date"] != nil) else {
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
                        guard let eventDate = cheki.eventDate,
                              sameCalendarDate(eventDate, dateFilter) else { return false }
                    }
                    return true
                }

            guard !chekis.isEmpty else {
                return .text("还没有保存的切。")
            }

            return .chekiCards(chekis.map { chekiCard(for: $0) })
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func showCheki(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            return .chekiCards([chekiCard(for: try resolveUniqueCheki(target))])
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func editCheki(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        let allowed = Set(["idol", "idols", "event", "date", "user", "userappears", "size", "note"])
        guard let target = command.target,
              !command.arguments.isEmpty,
              command.arguments.keys.allSatisfy(allowed.contains),
              !(command.arguments["idol"] != nil && command.arguments["idols"] != nil),
              !(command.arguments["user"] != nil && command.arguments["userappears"] != nil),
              !(command.arguments["event"] != nil && command.arguments["date"] != nil) else {
            return invalidUsage(usage)
        }

        do {
            let cheki = try resolveUniqueCheki(target)
            let idolValue = command.arguments["idol"] ?? command.arguments["idols"]
            let idols = try idolValue.map { try resolveIdolList($0) } ?? cheki.idols

            let event: Event?
            let eventDate: Date?
            if let rawEvent = command.arguments["event"] {
                guard let resolved = try resolveEvent(rawEvent) else {
                    throw ChekinanaAddChekiError.eventOrDateRequired
                }
                event = resolved
                eventDate = nil
            } else if let rawDate = command.arguments["date"] {
                event = nil
                eventDate = try parseCalendarDate(rawDate)
            } else {
                event = cheki.event
                eventDate = cheki.eventDate
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
                eventDate: eventDate,
                userAppears: userAppears,
                size: size,
                note: note
            )))
            let keepsGroup = sameChekiGroup(
                idolIDs: cheki.idols.map(\.id),
                eventID: cheki.event?.id,
                eventDate: cheki.eventDate,
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
                note: note,
                dateAnnotationState: cheki.handwrittenDateAnnotation.map {
                    .detected($0)
                } ?? .notRequested
            )
            return .pendingChekiCards(
                "已准备修改这张切。",
                [card],
                consumesSelectedPhotos: false
            )
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func deleteCheki(_ command: ChekinanaParsedCommand, usage: [String]) -> ChekinanaCommandResponse {
        guard let target = command.target, command.arguments.isEmpty else {
            return invalidUsage(usage)
        }
        do {
            let cheki = try resolveUniqueCheki(target)
            let code = confirmationLedger.insert(
                .deleteCheki(.init(chekiID: cheki.id, phase: .deleteModel))
            )
            let card = chekiCard(for: cheki, confirmationCode: code)
            return .pendingChekiCards("已准备删除这张切。", [card], consumesSelectedPhotos: false)
        } catch {
            return .text("error: \(error.localizedDescription)")
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
                return .text("这张切没有可读取的本地图片。")
            }

            let code = confirmationLedger.insert(.downloadCheki(chekiID: cheki.id, imageURL: imageURL))
            let card = chekiCard(for: cheki, confirmationCode: code)
            return .pendingChekiCards(
                "已准备把这张切保存到系统相册。",
                [card],
                consumesSelectedPhotos: false
            )
        } catch {
            return .text("error: \(error.localizedDescription)")
        }
    }

    private func resolveUniqueCheki(_ token: String) throws -> Cheki {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let descriptor = FetchDescriptor<Cheki>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let chekis = try modelContext.fetch(descriptor)
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
        guard let rawPodID = command.target ?? command.arguments["pod"] else {
            throw ChekinanaScanChekiError.missingPod
        }
        let podID = rawPodID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !podID.isEmpty else { throw ChekinanaScanChekiError.missingPod }

        let scannerSize = try parseScannerSize(command.arguments["scanner_size"])
        let postprocessMode = try parseScannerPostprocessMode(command.arguments["postprocess"])
        let expected = try parseScannerExpected(command.arguments["expected"])
        let whiteBalance = try parseScannerBool(command.arguments["wb"], defaultValue: true, argumentName: "wb")
        let dateAnnotationEnabled = try parseScannerBool(
            command.arguments["date_annotation"],
            defaultValue: false,
            argumentName: "date_annotation"
        )

        return ChekinanaScannerOptions(
            podID: podID,
            expectedPolaroids: expected,
            scannerSize: scannerSize,
            postprocessMode: postprocessMode,
            whiteBalance: whiteBalance,
            dateAnnotationEnabled: dateAnnotationEnabled
        )
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
        detail: ChekinanaIdolCardDetail? = nil
    ) -> ChekinanaIdolCard {
        ChekinanaIdolCard(
            id: idol.id,
            catalogueID: idol.sourceId,
            name: idol.name,
            group: idol.group,
            color: idol.color,
            birthday: idol.birthday,
            verification: nil,
            bio: nil,
            avatarImageRef: idol.avatarImageRef,
            detail: detail ?? .chekiCount(idol.chekis.count),
            confirmationCode: nil,
            selectionToken: nil
        )
    }

    private func showIdolResponse(for idols: [Idol]) -> ChekinanaCommandResponse {
        let sections = idols.map { idol in
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
        guard let idol = try modelContext.fetch(descriptor).first else {
            throw ChekinanaAddChekiError.noIdol(id.uuidString)
        }
        return idol
    }

    private func hasIdol(sourceId: String) throws -> Bool {
        var descriptor = FetchDescriptor<Idol>(predicate: #Predicate { $0.sourceId == sourceId })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func chekiCards(for idol: Idol) -> [ChekinanaChekiCard] {
        idol.chekis
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
            eventDateText: cheki.eventDate.map(calendarDateString),
            note: cheki.note,
            dateAnnotationState: cheki.handwrittenDateAnnotation.map {
                .detected($0)
            } ?? .notRequested
        )
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
        note: String,
        dateAnnotationState: ChekinanaChekiDateAnnotationState,
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
                eventDate: eventDate,
                idx: idx,
                userAppears: userAppears,
                size: size,
                imageRef: savedImage.ref,
                handwrittenDateAnnotation: {
                    guard case .detected(let annotation) = dateAnnotationState else {
                        return nil
                    }
                    return annotation
                }(),
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

    private func refetchChekiByID(_ id: UUID) throws -> Cheki {
        var descriptor = FetchDescriptor<Cheki>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let cheki = try modelContext.fetch(descriptor).first else {
            throw ChekinanaDownloadChekiError.noCheki(id.uuidString)
        }
        return cheki
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
        let idols = try modelContext.fetch(descriptor)
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

    private func validateChekiAssociations(idols: [Idol], event: Event?, eventDate: Date?) throws {
        guard !idols.isEmpty else { throw ChekinanaAddChekiError.invalidIdolList }
        guard (event != nil) != (eventDate != nil) else {
            throw ChekinanaAddChekiError.eventOrDateRequired
        }
    }

    private func sameChekiGroup(
        idolIDs: [UUID],
        eventID: UUID?,
        eventDate: Date?,
        otherIdolIDs: [UUID],
        otherEventID: UUID?,
        otherEventDate: Date?
    ) -> Bool {
        ChekinanaChekiGroupKey(idolIDs: idolIDs, eventID: eventID, eventDate: eventDate)
            == ChekinanaChekiGroupKey(
                idolIDs: otherIdolIDs,
                eventID: otherEventID,
                eventDate: otherEventDate
            )
    }

    private func nextChekiIndex(
        idolIDs: [UUID],
        eventID: UUID?,
        eventDate: Date?,
        excludingChekiID: UUID?
    ) throws -> Int {
        guard let group = ChekinanaChekiGroupKey(
            idolIDs: idolIDs,
            eventID: eventID,
            eventDate: eventDate
        ) else {
            throw ChekinanaAddChekiError.eventOrDateRequired
        }
        let chekis = try modelContext.fetch(FetchDescriptor<Cheki>())
        let snapshots = chekis.compactMap { cheki -> ChekinanaChekiIndexSnapshot? in
            guard let chekiGroup = ChekinanaChekiGroupKey(
                idolIDs: cheki.idols.map(\.id),
                eventID: cheki.event?.id,
                eventDate: cheki.eventDate
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
        let formatter = calendarDateFormatter
        guard let date = formatter.date(from: trimmed), formatter.string(from: date) == trimmed else {
            throw ChekinanaAddChekiError.invalidArgumentValue("date", value)
        }
        return date
    }

    private var calendarDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private func calendarDateString(_ date: Date) -> String {
        calendarDateFormatter.string(from: date)
    }

    private func sameCalendarDate(_ lhs: Date, _ rhs: Date) -> Bool {
        calendarDateString(lhs) == calendarDateString(rhs)
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
            livehouse: event.livehouse ?? "",
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
            weiboURL: fields.weiboURL,
            ticketURL: fields.ticketURL,
            note: fields.note,
            confirmationCode: confirmationCode
        )
    }

    private func eventDetails(_ event: Event, prefix: String? = nil) -> String {
        var parts: [String] = []
        if let prefix { parts.append(prefix) }
        parts.append("名称：\(event.name)")
        parts.append("日期：\(event.date.map(calendarDateString) ?? "未确定日期")")
        parts.append("城市：\(event.city ?? "未设置")")
        parts.append("场地：\(event.livehouse ?? "未设置")")
        parts.append("微博：\(event.weiboURL?.absoluteString ?? "未设置")")
        parts.append("票务：\(event.ticketURL?.absoluteString ?? "未设置")")
        parts.append("备注：\(event.note.isEmpty ? "未设置" : event.note)")
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
        parts.append("名称：\(name)")
        parts.append("日期：\(date.map(calendarDateString) ?? "未设置")")
        parts.append("链接：\(weiboURL?.absoluteString ?? "未设置")")
        return parts.joined(separator: " · ")
    }

    private func chekiDetails(_ cheki: Cheki, prefix: String? = nil) -> String {
        chekiPreviewDetails(
            id: cheki.id,
            idols: cheki.idols,
            event: cheki.event,
            eventDate: cheki.eventDate,
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
            lines.append("event/date=-")
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
        """
        直接告诉我你想做什么即可，不需要记命令或编号。

        例如：
        · 添加偶像 Alice
        · 添加活动 Summer Live 2026-08-01
        · 显示所有偶像或所有活动
        · 把 Alice 的名字改成 AlicePrime
        · 使用 Pod <pod_id> 扫描这些切
        · 显示 Alice 拍过的切

        添加、修改或删除前，我会先展示预览。请使用界面中的“确认”或“取消”按钮。
        要查看、修改或删除某张切，请先在切的卡片上选择它，然后说“查看这张切”“把这张切的备注改成……”或“删除这张切”。
        """
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
            "editidol <candidate_code|idol_id> <field>=<value> [...]  fields: name, group, birthday, color, avatar; use - to clear optional fields",
            "deleteidol <idol_id>",
            "addevent <url> name=<name> date=YYYY-MM-DD | addevent <name> date=YYYY-MM-DD",
            "listevent",
            "showevent <event_id|name>",
            "editevent <event_id|name> [name=<name>] [date=YYYY-MM-DD|-] [url=<url>|-]",
            "deleteevent <event_id|name>",
            "scancheki pod=<pod_id>  (processes selected photos and creates image-only temporary Cheki from scanner results)",
            "discardcheki <temporary_cheki_id|all>",
            "addcheki <idol_id_or_name[,idol_id_or_name...]> (event=<event_id>|date=YYYY-MM-DD) [user=true|false|?] [size=mini|wide|else|?] [note=<text>]  (idx is assigned on confirm)",
            "addscancheki <temporary_cheki_id[,temporary_cheki_id...]|all> idol=<idol_id_or_name[,idol_id_or_name...]> (event=<event_id>|date=YYYY-MM-DD) [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
            "listcheki [idol=<idol_id_or_name>] [event=<event_id|?>] [date=YYYY-MM-DD]",
            "showcheki <cheki_id>",
            "editcheki <cheki_id> [idol=<idol[,idol...]>] [event=<event_id>|date=YYYY-MM-DD] [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
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
            "listidol": [
                "listidol",
            ],
            "showidol": [
                "showidol <idol_id|name>",
            ],
            "editidol": [
                "editidol <candidate_code|idol_id> <field>=<value> [...]",
                "fields: name, group, birthday, color, avatar (avatar_url is accepted as an alias)",
                "use - to clear an optional field; quote values containing spaces",
            ],
            "deleteidol": [
                "deleteidol <idol_id>",
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
                "addcheki <idol_id_or_name[,idol_id_or_name...]> (event=<event_id>|date=YYYY-MM-DD) [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
                "addcheki idol=<idol_id_or_name[,idol_id_or_name...]> (event=<event_id>|date=YYYY-MM-DD) [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
                "select one or more album photos; this command never uses scancheki temporary objects",
                "idx is assigned automatically when each confirmation is persisted",
            ],
            "addscancheki": [
                "addscancheki <temporary_cheki_id[,temporary_cheki_id...]|all> idol=<idol_id_or_name[,idol_id_or_name...]> (event=<event_id>|date=YYYY-MM-DD) [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
                "temporary objects are consumed only after successful confirmation; idx is assigned on confirm",
            ],
            "scancheki": [
                "scancheki pod=<pod_id> [expected=<positive_int>] [scanner_size=auto|mini|wide] [postprocess=off|denoise|sharpen] [wb=true|false]",
                "scancheki <pod_id> [expected=<positive_int>] [scanner_size=auto|mini|wide] [postprocess=off|denoise|sharpen] [wb=true|false]",
                "select one or more photos first; scanner results remain temporary until addscancheki is confirmed",
            ],
            "discardcheki": [
                "discardcheki <temporary_cheki_id|all>",
                "temporary images referenced by pending addscancheki confirmations are retained; confirm or cancel first",
            ],
            "listcheki": [
                "listcheki [idol=<idol_id_or_name>] [event=<event_id|?>] [date=YYYY-MM-DD]",
            ],
            "showcheki": [
                "showcheki <cheki_id>",
            ],
            "editcheki": [
                "editcheki <cheki_id> [idol=<idol_id_or_name[,idol_id_or_name...]>] [event=<event_id>|date=YYYY-MM-DD] [user=true|false|?] [size=mini|wide|else|?] [note=<text>]",
                "provide at least one field; changing Idol/Event/date assigns the next group idx on confirm",
                "use ? or - to clear user/size and - to clear note",
            ],
            "downloadcheki": [
                "downloadcheki <cheki_id>",
            ],
            "deletecheki": [
                "deletecheki <cheki_id>",
            ],
        ]
    }
}

private struct SavedChekiImage: Sendable {
    let ref: String
    let url: URL
}

struct ChekinanaRenderedImage: @unchecked Sendable {
    let cgImage: CGImage
}

actor ChekinanaRemoteRequestLimiter {
    static let shared = ChekinanaRemoteRequestLimiter(limit: 4)

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private final class ChekinanaBoundedRemoteImageDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ChekinanaBoundedRemoteImageDownloader()

    private final class RequestState: @unchecked Sendable {
        let continuation: CheckedContinuation<Data, any Error>
        var data = Data()

        init(continuation: CheckedContinuation<Data, any Error>) {
            self.continuation = continuation
        }
    }

    private final class CancellationHandle: @unchecked Sendable {
        private let lock = NSLock()
        private let finishCancellation: @Sendable (Int) -> Void
        private var task: URLSessionDataTask?
        private var isCancelled = false

        init(finishCancellation: @escaping @Sendable (Int) -> Void) {
            self.finishCancellation = finishCancellation
        }

        func install(_ task: URLSessionDataTask) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isCancelled else { return false }
            self.task = task
            return true
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
            if let task {
                finishCancellation(task.taskIdentifier)
            }
        }
    }

    private enum DownloadError: Error {
        case invalidResponse
        case invalidContentType
        case emptyBody
        case bodyTooLarge
    }

    private static let maximumBodySize = 8 * 1_024 * 1_024
    private let lock = NSLock()
    private var states: [Int: RequestState] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.chekinana.remote-image-downloads"
        delegateQueue.qualityOfService = .utility
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    func data(for request: URLRequest) async throws -> Data {
        let cancellationHandle = CancellationHandle { [weak self] taskIdentifier in
            self?.finish(taskIdentifier: taskIdentifier, result: .failure(CancellationError()))
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = RequestState(continuation: continuation)
                lock.lock()
                states[task.taskIdentifier] = state
                lock.unlock()

                guard cancellationHandle.install(task) else {
                    finish(taskIdentifier: task.taskIdentifier, result: .failure(CancellationError()))
                    task.cancel()
                    return
                }
                task.resume()
            }
        } onCancel: {
            cancellationHandle.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else {
            completionHandler(.cancel)
            finish(taskIdentifier: dataTask.taskIdentifier, result: .failure(DownloadError.invalidResponse))
            return
        }

        let normalizedContentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedContentType,
              normalizedContentType.hasPrefix("image/"),
              normalizedContentType.count > "image/".count else {
            completionHandler(.cancel)
            finish(taskIdentifier: dataTask.taskIdentifier, result: .failure(DownloadError.invalidContentType))
            return
        }

        guard response.expectedContentLength <= Int64(Self.maximumBodySize) else {
            completionHandler(.cancel)
            finish(taskIdentifier: dataTask.taskIdentifier, result: .failure(DownloadError.bodyTooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var exceededLimit = false
        lock.lock()
        if let state = states[dataTask.taskIdentifier] {
            if data.count > Self.maximumBodySize - state.data.count {
                exceededLimit = true
            } else {
                state.data.append(data)
            }
        }
        lock.unlock()

        if exceededLimit {
            dataTask.cancel()
            finish(taskIdentifier: dataTask.taskIdentifier, result: .failure(DownloadError.bodyTooLarge))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(taskIdentifier: task.taskIdentifier, result: .failure(error))
            return
        }

        lock.lock()
        let data = states[task.taskIdentifier]?.data
        lock.unlock()
        guard let data, !data.isEmpty else {
            finish(taskIdentifier: task.taskIdentifier, result: .failure(DownloadError.emptyBody))
            return
        }
        finish(taskIdentifier: task.taskIdentifier, result: .success(data))
    }

    private func finish(taskIdentifier: Int, result: Result<Data, any Error>) {
        lock.lock()
        let state = states.removeValue(forKey: taskIdentifier)
        lock.unlock()
        guard let state else { return }
        state.continuation.resume(with: result)
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
            await ChekinanaRemoteRequestLimiter.shared.perform {
                guard !Task.isCancelled else { return nil }
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                do {
                    let data = try await ChekinanaBoundedRemoteImageDownloader.shared.data(for: request)
                    guard !Task.isCancelled else { return nil }
                    return await ChekinanaImageWorker.thumbnailImage(
                        from: data,
                        maxDimension: maxDimension
                    )
                } catch {
                    return nil
                }
            }
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
        let key = "ref|\(sourceKey)|\(maxDimension)"
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
        let key = "managed-ref|\(sourceKey)|\(maxDimension)"
        return await cachedImage(for: key) {
            await ChekinanaImageWorker.thumbnailImage(
                fromManagedImageRef: imageRef,
                maxDimension: maxDimension
            )
        }
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

enum ChekinanaImageWorker {
    static func previewImage(
        from imageData: Data,
        maxDimension: Int
    ) async -> ChekinanaRenderedImage? {
        let decodeTask: Task<ChekinanaRenderedImage?, Never> = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(imageData as CFData, [
                      kCGImageSourceShouldCache: false,
                  ] as CFDictionary),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension),
                  !Task.isCancelled else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    static func previewImage(
        fromImageRef imageRef: String,
        maxDimension: Int
    ) async -> ChekinanaRenderedImage? {
        let decodeTask: Task<ChekinanaRenderedImage?, Never> = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let url = ChekiImageRefResolver.localFileURL(for: imageRef),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [
                      kCGImageSourceShouldCache: false,
                  ] as CFDictionary),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension),
                  !Task.isCancelled else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }
        return await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    static func thumbnailImage(
        from imageData: Data,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension) else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }.value
    }

    static func thumbnailImage(
        fromImageRef imageRef: String?,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        await Task.detached(priority: .userInitiated) {
            guard let url = ChekiImageRefResolver.localFileURL(for: imageRef),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [
                    kCGImageSourceShouldCache: false,
                  ] as CFDictionary),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension) else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }.value
    }

    static func thumbnailImage(
        fromManagedImageRef imageRef: String?,
        maxDimension: Int = 512
    ) async -> ChekinanaRenderedImage? {
        await Task.detached(priority: .userInitiated) {
            guard let url = ChekiImageRefResolver.managedLocalFileURL(for: imageRef),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [
                    kCGImageSourceShouldCache: false,
                  ] as CFDictionary),
                  let image = makeThumbnailImage(from: source, maxDimension: maxDimension) else {
                return nil
            }
            return ChekinanaRenderedImage(cgImage: image)
        }.value
    }

    static func thumbnailData(from imageData: Data, maxDimension: Int = 512) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            makeThumbnailData(from: imageData, maxDimension: maxDimension)
        }.value
    }

    static func thumbnailDataBatch(from images: [Data], maxDimension: Int = 512) async -> [Data?] {
        await Task.detached(priority: .userInitiated) {
            images.map { makeThumbnailData(from: $0, maxDimension: maxDimension) }
        }.value
    }

    static func thumbnailData(fromFileAt url: URL, maxDimension: Int = 512) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary) else {
                return nil
            }
            return makeThumbnailData(from: source, maxDimension: maxDimension)
        }.value
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

    fileprivate static func saveChekiImageData(
        _ data: Data,
        id: UUID,
        filenameExtension: String
    ) async throws -> SavedChekiImage {
        try await Task.detached(priority: .userInitiated) {
            let directory = try ChekiImageRefResolver.chekiImagesDirectory()
            let normalizedExtension = normalizedImageExtension(filenameExtension)
            let url = directory.appendingPathComponent("\(id.uuidString).\(normalizedExtension)")
            try data.write(to: url, options: [.atomic])
            return SavedChekiImage(ref: url.lastPathComponent, url: url)
        }.value
    }

    static func removeItemIfPresent(at url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    private static func makeThumbnailData(from data: Data, maxDimension: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
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
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

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

enum ChekinanaScannerSize: String {
    case auto
    case mini
    case wide
}

enum ChekinanaScannerPostprocessMode: String {
    case off
    case denoise
    case sharpen
}

struct ChekinanaScannerOptions {
    let podID: String
    let expectedPolaroids: Int?
    let scannerSize: ChekinanaScannerSize
    let postprocessMode: ChekinanaScannerPostprocessMode
    let whiteBalance: Bool
    let dateAnnotationEnabled: Bool
}

struct ChekinanaScannerResultImage {
    let data: Data
    let dateAnnotationState: ChekinanaChekiDateAnnotationState
}

struct ChekinanaScannerProcessResult {
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

private struct ChekinanaScannerResultItem: Decodable {
    let id: String
    let type: String
    let label: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        label = try? container.decode(String.self, forKey: .label)
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

private struct ChekinanaScannerStatusResponse: Decodable {
    let status: String?
    let results: [ChekinanaScannerResultItem]
    let error: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case results
        case error
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try? container.decode(String.self, forKey: .status)
        results = (try? container.decode([ChekinanaScannerResultItem].self, forKey: .results)) ?? []
        error = try? container.decode(String.self, forKey: .error)
        message = try? container.decode(String.self, forKey: .message)
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

struct ChekinanaScannerClient {
    static let productionBaseURL = ChekinanaScannerConfiguration.productionBaseURL

    private let baseURLResolution: ChekinanaScannerBaseURLResolution
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(
        session: URLSession = .shared
    ) {
        baseURLResolution = ChekinanaScannerConfiguration.configuredBaseURL()
        self.session = session
    }

    init(
        baseURL: URL,
        session: URLSession = .shared
    ) {
        baseURLResolution = .resolved(baseURL)
        self.session = session
    }

    init(
        infoDictionary: [String: Any]?,
        allowsInsecureLocalHTTP: Bool,
        session: URLSession = .shared
    ) {
        baseURLResolution = ChekinanaScannerConfiguration.configuredBaseURL(
            infoDictionary: infoDictionary,
            allowsInsecureLocalHTTP: allowsInsecureLocalHTTP
        )
        self.session = session
    }

    func process(
        _ image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions
    ) async throws -> ChekinanaScannerProcessResult {
        _ = try baseURL()
        let taskID = try await upload(image, options: options)
        let status = try await pollStatus(taskID: taskID, options: options)
        let polaroids = status.results.filter { $0.type == "polaroid" }
        var images: [ChekinanaScannerResultImage] = []

        for polaroid in polaroids {
            let image = try await downloadResult(
                taskID: taskID,
                resultID: polaroid.id,
                options: options
            )
            images.append(image)
        }

        var warningCount = 0
        if let expected = options.expectedPolaroids, expected != polaroids.count {
            warningCount += 1
        }

        return ChekinanaScannerProcessResult(images: images, warningCount: warningCount)
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
        request.setValue(options.podID, forHTTPHeaderField: "X-Cheki-Token")
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

    private func pollStatus(
        taskID: String,
        options: ChekinanaScannerOptions
    ) async throws -> ChekinanaScannerStatusResponse {
        let baseURL = try baseURL()
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("status")
            .appendingPathComponent(taskID)

        for _ in 0..<120 {
            var request = URLRequest(url: url)
            request.setValue(options.podID, forHTTPHeaderField: "X-Cheki-Token")

            let (data, response) = try await session.data(for: request)
            try validateHTTPResponse(response)

            let statusResponse = try decoder.decode(ChekinanaScannerStatusResponse.self, from: data)
            let normalizedStatus = statusResponse.status?.lowercased()

            if let normalizedStatus {
                if ["failed", "failure", "error"].contains(normalizedStatus) {
                    throw ChekinanaScanChekiError.backendFailure(statusResponse.error ?? statusResponse.message)
                }

                if ["completed", "complete", "done", "success", "finished"].contains(normalizedStatus) {
                    return statusResponse
                }
            }

            if normalizedStatus == nil, !statusResponse.results.isEmpty {
                return statusResponse
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw ChekinanaScanChekiError.pollTimedOut
    }

    func downloadResult(
        taskID: String,
        resultID: String,
        options: ChekinanaScannerOptions
    ) async throws -> ChekinanaScannerResultImage {
        let baseURL = try baseURL()
        let baseResultURL = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("result")
            .appendingPathComponent(taskID)
            .appendingPathComponent(resultID)
        let url: URL
        if options.dateAnnotationEnabled {
            var components = URLComponents(
                url: baseResultURL,
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "date_annotation", value: "1")]
            url = components?.url ?? baseResultURL
        } else {
            // Preserve the pre-annotation result URL byte-for-byte when the
            // user-facing switch is disabled.
            url = baseResultURL
        }
        var request = URLRequest(url: url)
        request.setValue(options.podID, forHTTPHeaderField: "X-Cheki-Token")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        guard !data.isEmpty else {
            throw ChekinanaScanChekiError.emptyResultImage
        }

        let annotationState: ChekinanaChekiDateAnnotationState
        if let httpResponse = response as? HTTPURLResponse {
            annotationState = ChekinanaScannerDateAnnotationHeaderParser.parse(
                response: httpResponse,
                isEnabled: options.dateAnnotationEnabled
            )
        } else {
            annotationState = options.dateAnnotationEnabled ? .unavailable : .notRequested
        }
        return ChekinanaScannerResultImage(
            data: data,
            dateAnnotationState: annotationState
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

    private func multipartBody(
        for image: ChekinanaPendingChekiImage,
        options: ChekinanaScannerOptions,
        boundary: String
    ) -> Data {
        var body = Data()
        let fields: [(String, String)] = [
            ("token", options.podID),
            ("wb", options.whiteBalance ? "1" : "0"),
            ("denoise", "0"),
            ("postprocess_mode", options.postprocessMode.rawValue),
            ("rotation_degrees", "0"),
            ("polaroid_size", options.scannerSize.rawValue),
            ("upload_attempt_id", UUID().uuidString),
        ]

        for field in fields {
            body.appendMultipartField(name: field.0, value: field.1, boundary: boundary)
        }

        if let expectedPolaroids = options.expectedPolaroids {
            let value = String(expectedPolaroids)
            body.appendMultipartField(name: "expected_polaroids", value: value, boundary: boundary)
            body.appendMultipartField(name: "polaroid_count", value: value, boundary: boundary)
        }

        let filenameExtension = normalizedUploadExtension(image.filenameExtension)
        body.appendMultipartFile(
            name: "image",
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
        case "heic", "heif":
            return "heic"
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
        case "heic":
            return "image/heic"
        case "webp":
            return "image/webp"
        default:
            return "image/jpeg"
        }
    }
}

private extension KeyedDecodingContainer {
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
    case eventOrDateRequired
    case duplicateCheki(String)
    case indexOverflow
    case modelContextMismatch
    case invalidArgumentValue(String, String)
    case duplicateArgument(String)
    case systemManagedArgument(String)
    case unsupportedArgument

    var errorDescription: String? {
        switch self {
        case .invalidIdolList:
            "idol is required"
        case .noIdol(let token):
            "no idol matches: \(token)"
        case .duplicateIdol(let token):
            "duplicate idol records match: \(token)"
        case .ambiguousIdol(let token):
            "ambiguous idol: \(token). Use a longer idol id or exact name"
        case .noEvent(let token):
            "no event matches: \(token)"
        case .ambiguousEvent(let token):
            "ambiguous event id: \(token)"
        case .eventOrDateRequired:
            "exactly one of event=<event_id> or date=YYYY-MM-DD is required"
        case .duplicateCheki(let token):
            "cheki already exists: \(token)"
        case .indexOverflow:
            "cheki idx cannot be incremented for this Idol/Event group"
        case .modelContextMismatch:
            "cheki relationships could not be attached to the current data context"
        case .invalidArgumentValue(let argumentName, let value):
            "invalid \(argumentName): \(value)"
        case .duplicateArgument(let argumentName):
            "duplicate \(argumentName) field"
        case .systemManagedArgument(let argumentName):
            "\(argumentName) cannot be set"
        case .unsupportedArgument:
            "unsupported addcheki field"
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
            "event name must be non-empty"
        case .invalidURL:
            "invalid event url"
        case .missingRequiredFields(let fields):
            "event URL requires an explicit name and date; missing: \(fields.joined(separator: ", "))"
        case .notFound(let token):
            "no event matches: \(token)"
        case .ambiguous(let token):
            "ambiguous event: \(token). Use a longer event id or exact name"
        case .duplicate:
            "an event with the same name, date, and url already exists"
        }
    }
}

private enum ChekinanaEditConflictError: LocalizedError {
    case staleEvent(String)
    case staleCheki(String)

    var errorDescription: String? {
        switch self {
        case .staleEvent(let code):
            "event changed after this edit was prepared. Run cancel \(code) and execute editevent again"
        case .staleCheki(let code):
            "cheki changed after this edit was prepared. Run cancel \(code) and execute editcheki again"
        }
    }
}

private enum ChekinanaTemporaryChekiError: LocalizedError {
    case notFound(String)
    case ambiguous(String)
    case alreadyConsumed(String)
    case referencedByPendingConfirmation(String)
    case capacityExceeded(count: Int, bytes: Int)

    var errorDescription: String? {
        switch self {
        case .notFound(let token):
            "no temporary cheki matches: \(token). Run scancheki first"
        case .ambiguous(let token):
            "ambiguous temporary cheki id: \(token). Use a longer id"
        case .alreadyConsumed(let token):
            "temporary cheki was already added: \(token)"
        case .referencedByPendingConfirmation(let token):
            "temporary cheki is referenced by a pending addscancheki confirmation: \(token). Confirm or cancel that operation first"
        case .capacityExceeded(let count, let bytes):
            "temporary cheki storage limit reached (\(count)/20 images, \(bytes / 1_024 / 1_024)/100 MB). Run discardcheki <temporary_id|all>; pending addscancheki images cannot be evicted"
        }
    }
}

private enum ChekinanaAlbumPreparationError: LocalizedError {
    case noPreparedImage

    var errorDescription: String? {
        "selected photo could not be prepared"
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
            "idol now has \(count) associated cheki; deletion was not performed"
        case .eventHasChekis(let count):
            "event now has \(count) associated cheki; deletion was not performed"
        case .managedImageRecoveryMissing:
            "the managed cheki image is missing from both its original and recovery locations; deletion was not retried"
        case .managedImageRestoreFailed(let detail):
            "managed cheki image recovery failed; retry confirm after resolving file access: \(detail)"
        case .databaseSaveAndImageRestoreFailed(let save, let restore):
            "database deletion failed (\(save)); managed image recovery also failed (\(restore)). The confirmation remains pending and will retry recovery first"
        case .managedImageCleanupFailed(let detail):
            "cheki data was deleted, but managed image cleanup failed: \(detail). The confirmation remains pending; retry confirm to finish cleanup"
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
            return "no cheki matches: \(token)"
        case .ambiguousCheki(let token):
            return "ambiguous cheki id: \(token)"
        case .unreadableLocalImage:
            return "cheki image file is missing, unreadable, or not a valid image"
        case .invalidPhotoAsset:
            return "photo library could not create an image asset from this cheki file"
        case .photoLibraryPermissionDenied:
            return "photo library add permission was denied or restricted"
        case .photoLibrarySaveFailed:
            return "failed to save cheki to photo library"
        }
    }
}

private enum ChekinanaScanChekiError: LocalizedError {
    case missingPod
    case invalidBaseURLConfiguration
    case invalidArgumentValue(String, String)
    case missingTaskID
    case backendFailure(String?)
    case pollTimedOut
    case emptyResultImage
    case invalidResultImage
    case noResultImages
    case invalidHTTPResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingPod:
            return "pod is required. Use scancheki pod=<pod_id> or scancheki <pod_id> after selecting photos"
        case .invalidBaseURLConfiguration:
            return "scanner base URL configuration is invalid"
        case .invalidArgumentValue(let argumentName, let value):
            return "invalid \(argumentName): \(value)"
        case .missingTaskID:
            return "scanner did not return a task id"
        case .backendFailure:
            return "scanner failed"
        case .pollTimedOut:
            return "scanner timed out before results were ready"
        case .emptyResultImage:
            return "scanner returned an empty result image"
        case .invalidResultImage:
            return "scanner returned data that is not a decodable image; no temporary results were created"
        case .noResultImages:
            return "scanner returned no Cheki images; no temporary results were created"
        case .invalidHTTPResponse:
            return "scanner returned an invalid HTTP response"
        case .httpStatus(let statusCode):
            return "scanner request failed with HTTP \(statusCode)"
        }
    }
}

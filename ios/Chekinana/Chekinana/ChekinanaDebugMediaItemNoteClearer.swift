import Foundation
import SwiftData

#if DEBUG
@MainActor
enum ChekinanaDebugMediaItemNoteClearer {
    static let environmentKey = "CHEKINANA_DEBUG_CLEAR_MEDIAITEM_NOTES_ONCE"
    static let recordEnvironmentKey = "CHEKINANA_DEBUG_CLEAR_CHEKIRECORD_NOTES_ONCE"
    static let preservedRecordIDsEnvironmentKey = "CHEKINANA_DEBUG_PRESERVE_CHEKIRECORD_NOTE_IDS"

    enum ClearError: LocalizedError {
        case conflictingRequests
        case invalidPreservedIDs
        case missingPreservedRecords

        var errorDescription: String? {
            switch self {
            case .conflictingRequests: "Only one note cleanup may be requested per launch."
            case .invalidPreservedIDs: "ChekiRecord cleanup requires exactly six distinct UUIDs to preserve."
            case .missingPreservedRecords: "ChekiRecord cleanup stopped because a preserved record is missing."
            }
        }
    }

    @discardableResult
    static func clearRecordNotesIfRequested(
        in container: ModelContainer,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        guard environment[recordEnvironmentKey] == "1" else { return 0 }
        guard environment[environmentKey] != "1" else { throw ClearError.conflictingRequests }
        let values = (environment[preservedRecordIDsEnvironmentKey] ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let ids = values.compactMap(UUID.init(uuidString:))
        let preservedIDs = Set(ids)
        guard values.count == 6, ids.count == 6, preservedIDs.count == 6 else {
            throw ClearError.invalidPreservedIDs
        }

        // A separate context cannot save unrelated pending edits from launch/UI.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let records = try context.fetch(FetchDescriptor<ChekiRecord>())
        guard preservedIDs.isSubset(of: Set(records.map(\.id))) else {
            throw ClearError.missingPreservedRecords
        }
        let targets = records.filter { !preservedIDs.contains($0.id) && !$0.note.isEmpty }
        guard !targets.isEmpty else { return 0 }
        for record in targets {
            record.note = ""
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return targets.count
    }

    @discardableResult
    static func clearIfRequested(
        in modelContext: ModelContext,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        guard environment[environmentKey] == "1" else { return 0 }
        guard environment[recordEnvironmentKey] != "1" else { throw ClearError.conflictingRequests }

        let items = try modelContext.fetch(FetchDescriptor<MediaItem>())
        let itemsWithNotes = items.filter { !$0.note.isEmpty }
        guard !itemsWithNotes.isEmpty else { return 0 }

        for item in itemsWithNotes {
            item.note = ""
        }
        try modelContext.save()
        return itemsWithNotes.count
    }
}
#endif

import Foundation
import SwiftData

#if DEBUG
@MainActor
enum ChekinanaDebugMediaItemNoteClearer {
    static let idolNameSpacesEnvironmentKey = "CHEKINANA_DEBUG_REMOVE_IDOL_NAME_SPACES_ONCE"
    static let idolNameSpacesPayloadEnvironmentKey = "CHEKINANA_DEBUG_IDOL_NAME_SPACES_JSON"

    private struct IdolNameSpacesInput: Decodable {
        let id: UUID
        let expectedName: String
    }

    enum IdolNameSpacesError: LocalizedError {
        case invalidInput, targetMismatch, conflictingRequests

        var errorDescription: String? {
            switch self {
            case .invalidInput: "Idol name cleanup requires a nonempty JSON array of distinct UUIDs and expected names."
            case .targetMismatch: "Idol name cleanup stopped because a target is missing, duplicated, or its name changed."
            case .conflictingRequests: "Idol name cleanup cannot run with another debug data mutation request."
            }
        }
    }

    @discardableResult
    static func removeIdolNameSpacesIfRequested(
        in container: ModelContainer,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        guard environment[idolNameSpacesEnvironmentKey] == "1" else { return 0 }
        guard [environmentKey, recordEnvironmentKey, eventCityEnvironmentKey,
               eventInsertEnvironmentKey, eventDateRepairEnvironmentKey,
               "CHEKINANA_UI_RESET_STORE", "CHEKINANA_UI_TEST_STORE"].allSatisfy({ environment[$0] != "1" }) else {
            throw IdolNameSpacesError.conflictingRequests
        }
        guard let raw = environment[idolNameSpacesPayloadEnvironmentKey],
              let inputs = try? JSONDecoder().decode([IdolNameSpacesInput].self, from: Data(raw.utf8)),
              !inputs.isEmpty, Set(inputs.map(\.id)).count == inputs.count else {
            throw IdolNameSpacesError.invalidInput
        }
        let expected = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.expectedName) })
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let targets = try context.fetch(FetchDescriptor<Idol>()).filter { expected[$0.id] != nil }
        guard targets.count == expected.count,
              Set(targets.map(\.id)).count == expected.count,
              targets.allSatisfy({ $0.name == expected[$0.id] }) else {
            throw IdolNameSpacesError.targetMismatch
        }
        // Preflight every target before assigning only its name field.
        let changes = targets.filter { $0.name.contains(" ") }
        guard !changes.isEmpty else { return 0 }
        for idol in changes { idol.name = expected[idol.id]!.replacingOccurrences(of: " ", with: "") }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return changes.count
    }

    static let environmentKey = "CHEKINANA_DEBUG_CLEAR_MEDIAITEM_NOTES_ONCE"
    static let recordEnvironmentKey = "CHEKINANA_DEBUG_CLEAR_CHEKIRECORD_NOTES_ONCE"
    static let preservedRecordIDsEnvironmentKey = "CHEKINANA_DEBUG_PRESERVE_CHEKIRECORD_NOTE_IDS"
    static let eventCityEnvironmentKey = "CHEKINANA_DEBUG_TRIM_EVENT_CITY_ONCE"
    static let eventCityTargetsEnvironmentKey = "CHEKINANA_DEBUG_EVENT_CITY_TARGETS"

    static let eventInsertEnvironmentKey = "CHEKINANA_DEBUG_INSERT_EVENTS_ONCE"
    static let eventInsertPayloadEnvironmentKey = "CHEKINANA_DEBUG_INSERT_EVENTS_JSON"

    static let eventDateRepairEnvironmentKey = "CHEKINANA_DEBUG_REPAIR_EVENT_DATES_ONCE"
    static let eventDateRepairPayloadEnvironmentKey = "CHEKINANA_DEBUG_REPAIR_EVENT_DATES_JSON"

    private struct EventDateRepairInput: Decodable {
        let id: UUID
        let date: String
        let expectedOldReferenceSeconds: Double
    }

    enum EventDateRepairError: LocalizedError {
        case invalidInput
        case targetMismatch
        case conflictingRequests

        var errorDescription: String? {
            switch self {
            case .invalidInput: "Event date repair requires distinct UUIDs, exact YYYY-MM-DD dates, and finite prior timestamps."
            case .targetMismatch: "Event date repair stopped because a target is missing, duplicated, or its date changed."
            case .conflictingRequests: "Event date repair cannot run with another debug data mutation request."
            }
        }
    }

    @discardableResult
    static func repairEventDatesIfRequested(
        in container: ModelContainer,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        guard environment[eventDateRepairEnvironmentKey] == "1" else { return 0 }
        guard [environmentKey, recordEnvironmentKey, eventCityEnvironmentKey, eventInsertEnvironmentKey,
               "CHEKINANA_UI_RESET_STORE", "CHEKINANA_UI_TEST_STORE"].allSatisfy({ environment[$0] != "1" }) else {
            throw EventDateRepairError.conflictingRequests
        }
        guard let raw = environment[eventDateRepairPayloadEnvironmentKey],
              let inputs = try? JSONDecoder().decode([EventDateRepairInput].self, from: Data(raw.utf8)),
              !inputs.isEmpty, Set(inputs.map(\.id)).count == inputs.count else {
            throw EventDateRepairError.invalidInput
        }
        var expected: [UUID: (old: Double, target: Date)] = [:]
        for input in inputs {
            guard input.expectedOldReferenceSeconds.isFinite,
                  input.date.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
                  let date = ChekinanaDateOnly.parse(input.date),
                  ChekinanaDateOnly.string(date) == input.date else {
                throw EventDateRepairError.invalidInput
            }
            expected[input.id] = (input.expectedOldReferenceSeconds, date)
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let targets = try context.fetch(FetchDescriptor<Event>()).filter { expected[$0.id] != nil }
        guard targets.count == expected.count,
              Set(targets.map(\.id)).count == expected.count,
              targets.allSatisfy({ event in
                  guard let date = event.date, let value = expected[event.id] else { return false }
                  return date.timeIntervalSinceReferenceDate == value.old || date == value.target
              }) else {
            throw EventDateRepairError.targetMismatch
        }
        // Validate the entire batch first; only the date column is assigned.
        let changes = targets.filter { $0.date != expected[$0.id]!.target }
        guard !changes.isEmpty else { return 0 }
        for event in changes { event.date = expected[event.id]!.target }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return changes.count
    }

    private struct EventInsertInput: Decodable {
        let id: UUID
        let name: String
        let date: String
        let city: String
        let livehouse: String
    }

    enum EventInsertError: LocalizedError {
        case invalidInput
        case existingID
        case conflictingRequests

        var errorDescription: String? {
            switch self {
            case .invalidInput: "Event insertion requires a nonempty valid JSON array with distinct UUIDs and exact YYYY-MM-DD dates."
            case .existingID: "Event insertion stopped because a requested UUID already exists."
            case .conflictingRequests: "Event insertion cannot run with another debug data mutation request."
            }
        }
    }

    @discardableResult
    static func insertEventsIfRequested(
        in container: ModelContainer,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        guard environment[eventInsertEnvironmentKey] == "1" else { return 0 }
        guard [environmentKey, recordEnvironmentKey, eventCityEnvironmentKey,
               "CHEKINANA_UI_RESET_STORE", "CHEKINANA_UI_TEST_STORE"].allSatisfy({ environment[$0] != "1" }) else {
            throw EventInsertError.conflictingRequests
        }
        guard let raw = environment[eventInsertPayloadEnvironmentKey],
              let inputs = try? JSONDecoder().decode([EventInsertInput].self, from: Data(raw.utf8)),
              !inputs.isEmpty,
              Set(inputs.map(\.id)).count == inputs.count else {
            throw EventInsertError.invalidInput
        }
        let datedInputs = try inputs.map { input -> (EventInsertInput, Date) in
            guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !input.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !input.livehouse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  input.date.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
                  let date = ChekinanaDateOnly.parse(input.date),
                  ChekinanaDateOnly.string(date) == input.date else {
                throw EventInsertError.invalidInput
            }
            return (input, date)
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let existingIDs = Set(try context.fetch(FetchDescriptor<Event>()).map(\.id))
        guard existingIDs.isDisjoint(with: inputs.map(\.id)) else {
            throw EventInsertError.existingID
        }
        // Preflight the entire batch before inserting; never upsert or deduplicate by title/date.
        for (input, date) in datedInputs {
            context.insert(Event(id: input.id, name: input.name, date: date,
                                 city: input.city, livehouse: input.livehouse))
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return inputs.count
    }

    enum EventCityError: LocalizedError {
        case invalidTargets
        case targetMismatch
        case conflictingRequests

        var errorDescription: String? {
            switch self {
            case .invalidTargets: "Event city update requires a nonempty UUID-to-city JSON object with cities ending in 市."
            case .targetMismatch: "Event city update stopped because a target is missing, duplicated, or its city changed."
            case .conflictingRequests: "Event city update cannot run with a note cleanup request."
            }
        }
    }

    @discardableResult
    static func trimEventCitiesIfRequested(
        in container: ModelContainer,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        guard environment[eventCityEnvironmentKey] == "1" else { return 0 }
        guard environment[environmentKey] != "1", environment[recordEnvironmentKey] != "1" else {
            throw EventCityError.conflictingRequests
        }
        guard let raw = environment[eventCityTargetsEnvironmentKey],
              let values = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)),
              !values.isEmpty else { throw EventCityError.invalidTargets }
        var expected: [UUID: String] = [:]
        for (key, city) in values {
            guard let id = UUID(uuidString: key), expected[id] == nil, city.hasSuffix("市") else {
                throw EventCityError.invalidTargets
            }
            expected[id] = city
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let events = try context.fetch(FetchDescriptor<Event>())
        let targets = events.filter { expected[$0.id] != nil }
        guard targets.count == expected.count,
              Set(targets.map(\.id)).count == expected.count,
              targets.allSatisfy({ $0.city == expected[$0.id] }) else {
            throw EventCityError.targetMismatch
        }
        // Validate the complete target set before changing any persisted field.
        for event in targets {
            event.city = String(expected[event.id]!.dropLast())
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return targets.count
    }

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

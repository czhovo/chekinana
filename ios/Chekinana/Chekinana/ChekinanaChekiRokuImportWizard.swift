import SwiftData
import SwiftUI
import UIKit

/// Deliberately local-only ChekiRoku import UI.  It never calls the idol catalogue.
struct ChekinanaChekiRokuImportWizard: View {
    let archive: ChekinanaChekiRokuImport.Archive
    let onClose: () -> Void
    @Binding var isExternallyBusy: Bool
    @Environment(\.modelContext) private var modelContext
    @Query private var localIdols: [Idol]
    @State private var step = 1
    @State private var drafts: [ChekiRokuIdolDraft] = []
    @State private var memberMap: [Int: UUID] = [:]
    @State private var isSaving = false
    @State private var isPlanning = false
    @State private var isMatching = false
    @State private var cachedPlan: ChekiRokuRecordPlan?
    @State private var recordImporter: ChekiRokuRecordImportActor?
    @State private var progress = ""
    @State private var progressCompleted = 0
    @State private var progressTotal = 0
    @State private var selectedSourceRowCount = 0
    @State private var activeRecordCommitID: UUID?
    @State private var message: String?
    @State private var completed = false
    @FocusState private var isDraftFieldFocused: Bool

    private var selectedDraftCount: Int { drafts.lazy.filter(\.isSelected).count }
    private var draftControlsEnabled: Bool {
        ChekiRokuMemberSelectionPolicy.controlsEnabled(
            isSaving: isSaving,
            isMatching: isMatching
        )
    }
    private var selectedSourceRecords: [ChekinanaChekiRokuImport.SourceRecord] {
        ChekiRokuMemberSelectionPolicy.selectedRecords(archive.records, drafts: drafts)
    }

    var body: some View {
        Group {
            if completed { completion }
            else if step == 1 { idolStep }
            else { recordStep }
        }
        .navigationTitle(ChekinanaL10n.text("import.title", fallback: "Import from ChekiRoku"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ChekinanaL10n.text("action.cancel", fallback: "Cancel")) { finish() }.disabled(isSaving || isPlanning || isMatching).accessibilityIdentifier("chekinana.import.wizard.cancel") } }
        .tint(ChekinanaDesignSystem.accent)
        .background(ChekinanaDesignSystem.pageBackground)
        .navigationBarBackButtonHidden(isSaving || isPlanning || isMatching)
        .interactiveDismissDisabled(isSaving || isPlanning || isMatching)
        .onChange(of: isSaving || isPlanning || isMatching) { _, busy in isExternallyBusy = busy }
        .onAppear { if drafts.isEmpty && !isMatching { prepareDrafts() } }
        .onDisappear { if !completed { ChekinanaChekiRokuImport.cleanup(archive) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.import.wizard")
    }

    private var idolStep: some View {
        List {
            Section {
                ChekiRokuStepHeader(step: 1, title: ChekinanaL10n.text("import.step1", fallback: "Step 1 of 2 · Add Idols"))
                Text(ChekinanaL10n.text("import.review", fallback: "Review each source Idol. Existing local Idols are skipped; ambiguous matches require a choice."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(ChekinanaL10n.format(
                    "import.selected_count",
                    fallback: "Selected %1$lld of %2$lld",
                    Int64(selectedDraftCount),
                    Int64(drafts.count)
                ))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityValue("\(selectedDraftCount)/\(drafts.count)")
                    .accessibilityIdentifier("chekinana.import.step1.selection-count")
                HStack {
                    Button(ChekinanaL10n.text("import.select_all", fallback: "Select All")) {
                        ChekiRokuMemberSelectionPolicy.setAll(true, drafts: &drafts)
                    }
                        .disabled(!draftControlsEnabled)
                        .accessibilityIdentifier("chekinana.import.step1.select-all")
                    Spacer()
                    Button(ChekinanaL10n.text("import.deselect_all", fallback: "Deselect All")) {
                        ChekiRokuMemberSelectionPolicy.setAll(false, drafts: &drafts)
                    }
                        .disabled(!draftControlsEnabled)
                        .accessibilityIdentifier("chekinana.import.step1.deselect-all")
                }
            }
            ForEach($drafts) { $draft in
                Section {
                    Toggle(
                        ChekinanaL10n.format(
                            "import.include_member",
                            fallback: "Include source Idol #%lld",
                            Int64(draft.memberID)
                        ),
                        isOn: $draft.isSelected
                    )
                        .disabled(!draftControlsEnabled)
                        .accessibilityValue(
                            draft.isSelected
                                ? ChekinanaProductCopy.text("common.selected", "Selected")
                                : ChekinanaProductCopy.text(
                                    "common.not_selected",
                                    "Not selected"
                                )
                        )
                        .accessibilityIdentifier(
                            "chekinana.import.step1.member.\(draft.memberID).selected"
                        )
                    HStack {
                        avatar(draft.avatarPreview)
                        VStack(alignment: .leading) {
                            TextField(ChekinanaL10n.text("import.name", fallback: "Name"), text: $draft.name)
                                .focused($isDraftFieldFocused)
                            TextField(ChekinanaL10n.text("import.group", fallback: "Group"), text: $draft.group)
                                .focused($isDraftFieldFocused)
                                .foregroundStyle(.secondary)
                            if draft.isSelected && ChekinanaChekiRokuImport.normalized(draft.name).isEmpty {
                                Text(ChekinanaL10n.format("import.source_name_required", fallback: "Source Idol #%lld: enter a name to import its records.", Int64(draft.memberID)))
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                        }
                    }
                    .disabled(!draftControlsEnabled || !draft.isSelected)
                    .opacity(draft.isSelected ? 1 : 0.55)
                    TextField(
                        ChekinanaL10n.text("import.color", fallback: "Color"),
                        text: localizedColorBinding($draft.color)
                    )
                    .focused($isDraftFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!draftControlsEnabled || !draft.isSelected)
                    .opacity(draft.isSelected ? 1 : 0.55)
                    if !draft.isSelected {
                        Text(ChekinanaL10n.text(
                            "import.member_excluded",
                            fallback: "Not selected — this Idol and its records will be excluded."
                        ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if draft.matchCandidates.count > 1 {
                        Picker(ChekinanaL10n.text("import.use_local", fallback: "Use local Idol"), selection: $draft.choice) {
                            Text(ChekinanaL10n.text(
                                "import.choose_match",
                                fallback: "Choose…"
                            )).tag(ChekiRokuIdolChoice.unresolved)
                            Text(ChekinanaL10n.text("import.create_new", fallback: "Create New")).tag(ChekiRokuIdolChoice.create)
                            ForEach(draft.matchCandidates, id: \.id) { idol in
                                ChekiRokuExistingIdolOption(idol: idol)
                                    .tag(ChekiRokuIdolChoice.existing(idol.id))
                            }
                        }
                        .accessibilityIdentifier(
                            "chekinana.import.step1.member.\(draft.memberID).match"
                        )
                        .disabled(!draftControlsEnabled)
                        if !draft.choice.isResolved {
                            Text(ChekinanaL10n.text(
                                "import.match_required",
                                fallback: "Choose Create New or an existing local Idol."
                            ))
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text(draft.choice.isExisting
                            ? ChekinanaL10n.text("import.existing_skip", fallback: "Existing Idol — will skip")
                            : ChekinanaL10n.text("import.new_create", fallback: "New Idol — will create"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text(ChekinanaL10n.format("import.source_idol", fallback: "Source Idol #%lld", Int64(draft.memberID))) }
            }
            if !progress.isEmpty { Section { importProgress } }
            if let message { Section { Text(message).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(ChekinanaDesignSystem.pageBackground)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(ChekinanaL10n.text("action.done", fallback: "Done")) {
                    isDraftFieldFocused = false
                }
                .disabled(!draftControlsEnabled)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(ChekinanaL10n.text("import.action.continue", fallback: "Continue to Records")) { saveIdols() }
                .buttonStyle(.borderedProminent).padding()
                .disabled(isSaving || !ChekiRokuMemberSelectionPolicy.canAdvance(drafts))
                .accessibilityIdentifier("chekinana.import.step1.continue")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.import.step1")
    }

    private var recordStep: some View {
        List {
            Section {
                ChekiRokuStepHeader(step: 2, title: ChekinanaL10n.text("import.step2", fallback: "Step 2 of 2 · Add Records"))
                Text(ChekinanaL10n.text("import.only_missing", fallback: "Only missing quantities are added. Existing records count whether or not they have media."))
                Text(ChekinanaL10n.format(
                    "import.record_summary",
                    fallback: "Source rows: %1$lld · Records to add: %2$lld",
                    Int64(selectedSourceRowCount),
                    Int64(recordPlan.newCount)
                ))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(recordPlan.summaries, id: \.idolID) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.idolName)
                    Text(item.label).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !progress.isEmpty { Section { importProgress } }
            if let message { Section { Text(message).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .background(ChekinanaDesignSystem.pageBackground)
        .safeAreaInset(edge: .bottom) {
            ViewThatFits(in: .horizontal) {
                HStack { recordBackButton; Spacer(); recordImportButton }
                VStack(spacing: 8) { recordImportButton; recordBackButton }
            }
            .padding()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.import.step2")
    }

    private var completion: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(ChekinanaDesignSystem.accent)
            Text(message ?? ChekinanaL10n.text("import.complete", fallback: "Import complete"))
            Button(ChekinanaL10n.text("action.done", fallback: "Done")) { finish() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("chekinana.import.completion.done")
        }
        .padding(24)
        .background(ChekinanaDesignSystem.softAccent)
        .clipShape(
            RoundedRectangle(
                cornerRadius: ChekinanaDesignSystem.cardRadius,
                style: .continuous
            )
        )
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.import.completion")
    }

    private var recordBackButton: some View {
        Button(ChekinanaL10n.text("action.back", fallback: "Back")) {
            cachedPlan = nil
            recordImporter = nil
            step = 1
        }
        .disabled(isSaving || isPlanning)
        .accessibilityIdentifier("chekinana.import.step2.back")
    }

    private var recordImportButton: some View {
        Button(ChekinanaL10n.quantity(
            "import.action.records",
            count: recordPlan.newCount,
            one: "Import %lld Record",
            other: "Import %lld Records"
        )) {
            Task { await saveRecords() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSaving || isPlanning || cachedPlan == nil || recordImporter == nil)
        .accessibilityIdentifier("chekinana.import.step2.import")
    }

    @ViewBuilder private var importProgress: some View {
        if progressTotal > 0 { ProgressView(progress, value: Double(progressCompleted), total: Double(progressTotal)) }
        else { ProgressView(progress) }
    }

    private func avatar(_ preview: ChekinanaRenderedImage?) -> some View {
        Group {
            if let preview {
                Image(decorative: preview.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private func localizedColorBinding(_ storage: Binding<String>) -> Binding<String> {
        Binding(
            get: { ChekinanaIdolPalette.localizedTitle(forStorageValue: storage.wrappedValue) },
            set: { storage.wrappedValue = ChekinanaIdolPalette.storageValue(forLocalizedTitle: $0) }
        )
    }

    private func prepareDrafts() {
        isMatching = true; progress = ChekinanaL10n.text("import.stage.matching", fallback: "Matching Idols")
        let source = archive.idols.map(ChekiRokuPreparedSourceIdol.init)
        let avatarData = archive.imageData
        let local = localIdols.map(ChekiRokuLocalIdol.init)
        let idolsByID = Dictionary(uniqueKeysWithValues: localIdols.map { ($0.id, $0) })
        Task { @MainActor in
            async let matchingResults = Task.detached {
                source.map { sourceIdol in
                    ChekiRokuMatchResult(
                        source: sourceIdol,
                        candidates: local.filter { $0.matches(sourceIdol) }
                    )
                }
            }.value
            async let previewResults = ChekiRokuAvatarPreviewer.makePreviews(avatarData)
            let (results, previews) = await (matchingResults, previewResults)
            drafts = results.map { result in
                let candidates = result.candidates.compactMap { idolsByID[$0.id] }
                let exact = result.candidates.filter { $0.exact(result.source) }
                let resolved = exact.count == 1 ? exact.first?.id : (candidates.count == 1 ? candidates.first?.id : nil)
                let sourceIdol = result.source.source
                return ChekiRokuIdolDraft(
                    memberID: sourceIdol.id,
                    name: sourceIdol.name,
                    group: sourceIdol.group,
                    color: sourceIdol.color,
                    avatarData: sourceIdol.avatarName.flatMap { avatarData[$0] },
                    avatarPreview: sourceIdol.avatarName.flatMap { previews[$0] },
                    matchCandidates: candidates,
                    choice: resolved.map { .existing($0) }
                        ?? (candidates.count > 1 ? .unresolved : .create)
                )
            }
            isMatching = false; progress = ""
        }
    }

    private func saveIdols() {
        guard !isSaving, ChekiRokuMemberSelectionPolicy.canAdvance(drafts) else { return }
        let selectedIDs = ChekiRokuMemberSelectionPolicy.selectedMemberIDs(drafts)
        let selectedDrafts = drafts.filter(\.isSelected)
        selectedSourceRowCount = selectedSourceRecords.count
        memberMap = memberMap.filter { selectedIDs.contains($0.key) }
        isDraftFieldFocused = false; isSaving = true; progressTotal = selectedDrafts.count; progressCompleted = 0; progress = ChekinanaL10n.format("import.progress.idol", fallback: "Adding Idol %lld/%lld", 0, Int64(selectedDrafts.count)); message = nil
        Task { @MainActor in
            var created: [Idol] = []; var staged: [(Idol, ChekinanaIdolReferenceStore.StoredAvatar)] = []
            do {
                for (offset, draft) in selectedDrafts.enumerated() {
                    progress = ChekinanaL10n.format("import.progress.idol_name", fallback: "Adding Idol %1$lld/%2$lld · %3$@", Int64(offset + 1), Int64(selectedDrafts.count), draft.name)
                    await Task.yield()
                    guard !ChekinanaChekiRokuImport.normalized(draft.name).isEmpty else { throw ChekiRokuImportUIError.invalidName }
                    switch draft.choice {
                    case .unresolved:
                        throw ChekiRokuImportUIError.unresolvedMember(draft.memberID)
                    case .existing(let id):
                        guard localIdols.contains(where: { $0.id == id }) else { throw ChekiRokuImportUIError.missingIdol(draft.memberID) }
                        memberMap[draft.memberID] = id
                    case .create:
                        let idol = Idol(name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), group: draft.group.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, color: draft.color.nilIfEmpty)
                        if let data = draft.avatarData {
                            guard let safeAvatar = await safeAvatarData(data) else { throw ChekiRokuImportUIError.invalidAvatar }
                            let saved = try await ChekinanaIdolReferenceStore.saveAvatar(safeAvatar, idolID: idol.id); idol.avatarImageRef = saved.ref; staged.append((idol, saved))
                        }
                        modelContext.insert(idol); created.append(idol); memberMap[draft.memberID] = idol.id
                    }
                    progressCompleted = offset + 1
                }
                try modelContext.save()
                for index in drafts.indices where drafts[index].isSelected {
                    if let id = memberMap[drafts[index].memberID] {
                        drafts[index].choice = .existing(id)
                    }
                }
                step = 2; progress = ""; progressCompleted = 0; progressTotal = 0; cachedPlan = nil; recordImporter = nil; planRecords()
            } catch {
                modelContext.rollback(); for (_, saved) in staged { try? FileManager.default.removeItem(at: saved.url) }; created.forEach { modelContext.delete($0) }
                message = error.localizedDescription; progress = ""
            }
            isSaving = false
        }
    }
    private func safeAvatarData(_ data: Data) async -> Data? {
        // The image worker performs bounded ImageIO metadata validation before
        // decoding, so neither validation nor decompression runs in View.body or
        // on the main executor.
        await ChekinanaImageWorker.downsampledJPEGData(from: data, maxDimension: 512)
    }

    private var recordPlan: ChekiRokuRecordPlan { cachedPlan ?? .init(items: []) }
    private func planRecords() {
        guard !isPlanning else { return }
        isPlanning = true; progressTotal = 0; progressCompleted = 0; progress = ChekinanaL10n.text("import.stage.planning", fallback: "Planning records")
        let members = memberMap
        // Only scalar data leaves the main SwiftData context.  Passing a
        // managed Idol through the planner later caused cross-context
        // relationships when the import runs in a transaction context.
        var namesByID = Dictionary(uniqueKeysWithValues: localIdols.map { ($0.id, $0.name) })
        for draft in drafts where draft.isSelected {
            if let id = memberMap[draft.memberID] { namesByID[id] = draft.name }
        }
        let records = selectedSourceRecords
        let container = modelContext.container
        Task { @MainActor in
            do {
                // @ModelActor creates its ModelContext on the executor where it is
                // initialized. Build it from a detached task so the import context
                // is not accidentally bound to the main executor.
                let planner = await Task.detached(priority: .userInitiated) {
                    ChekiRokuRecordImportActor(modelContainer: container)
                }.value
                let planned = try await planner.plan(records: records, memberMap: members)
                guard planned.allSatisfy({ namesByID[$0.idolID] != nil }) else { throw ChekiRokuImportUIError.unmappedRecord }
                cachedPlan = .init(
                    items: planned.map { value in
                    .init(
                        idolID: value.idolID,
                        idolName: namesByID[value.idolID]!,
                        day: value.day,
                        type: .cheki,
                        memoRuns: value.memoRuns,
                        nextIndex: value.nextIndex
                    )
                    },
                    sourceRecords: records,
                    memberMap: members,
                    idolNames: namesByID
                )
                // Planning fetches all relevant local record relationships. Use a
                // fresh actor for commit so those registered objects can be
                // released before thousands of new models are inserted.
                recordImporter = await Task.detached(priority: .userInitiated) {
                    ChekiRokuRecordImportActor(modelContainer: container)
                }.value
            } catch {
                cachedPlan = nil
                recordImporter = nil
                message = error.localizedDescription
            }
            isPlanning = false; progress = ""
        }
    }
    private func saveRecords() async {
        guard !isSaving, let recordImporter, let cachedPlan else { return }; isSaving = true; progressTotal = cachedPlan.newCount; progressCompleted = 0; progress = ChekinanaL10n.text("import.stage.adding_records", fallback: "Adding records…"); message = nil
        let commitID = UUID()
        activeRecordCommitID = commitID
        do {
            let inserted = try await recordImporter.save(
                commitID: commitID,
                records: cachedPlan.sourceRecords,
                memberMap: cachedPlan.memberMap,
                idolNames: cachedPlan.idolNames
            ) { update in
                guard ChekiRokuRecordProgressPolicy.shouldAccept(
                    activeCommitID: activeRecordCommitID,
                    update: update,
                    currentCompleted: progressCompleted,
                    importCompleted: completed
                ) else { return }
                progressCompleted = update.completed
                progressTotal = update.total
                progress = ChekinanaL10n.format(
                    "import.progress.records",
                    fallback: "Adding records · %1$@ · %2$lld/%3$lld",
                    update.idolName,
                    Int64(update.completed),
                    Int64(update.total)
                )
            }
            activeRecordCommitID = nil
            progressCompleted = inserted
            completed = true
            message = ChekinanaL10n.quantity(
                "import.imported",
                count: inserted,
                one: "Imported %lld missing record.",
                other: "Imported %lld missing records."
            )
            progress = ""
            self.cachedPlan = nil
            self.recordImporter = nil
        } catch {
            activeRecordCommitID = nil
            message = error.localizedDescription
            progress = ""
            progressCompleted = 0
        }
        isSaving = false
    }
    private func finish() {
        guard !isSaving, !isPlanning, !isMatching else { return }
        ChekinanaChekiRokuImport.cleanup(archive)
        onClose()
    }
}

private struct ChekiRokuStepHeader: View {
    let step: Int
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(step)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(ChekinanaDesignSystem.accent)
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text(title).font(.headline).foregroundStyle(.primary)
            Spacer()
            Text("\(step)/2")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(ChekinanaDesignSystem.softAccent)
        .clipShape(RoundedRectangle(cornerRadius: ChekinanaDesignSystem.compactRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

enum ChekiRokuImportUIError: LocalizedError {
    case invalidName, invalidAvatar, unresolvedMember(Int), missingIdol(Int), missingDestinationIdol, unmappedRecord, indexOverflow
    case commitInProgress

    var errorDescription: String? {
        switch self {
        case .invalidName:
            ChekinanaL10n.text("import.error.name", fallback: "Every Idol needs a name.")
        case .invalidAvatar:
            ChekinanaL10n.text("import.error.avatar", fallback: "An imported avatar is not a safe image.")
        case .unresolvedMember(let member):
            ChekinanaL10n.format(
                "import.error.unresolved_member",
                fallback: "Source Idol #%lld still needs a match choice.",
                Int64(member)
            )
        case .missingIdol(let member):
            ChekinanaL10n.format("import.error.missing_idol", fallback: "Source Idol #%lld is no longer available locally.", Int64(member))
        case .missingDestinationIdol:
            ChekinanaL10n.text("import.error.destination_idol", fallback: "A mapped Idol is unavailable in this import context. No records were imported.")
        case .unmappedRecord:
            ChekinanaL10n.text("import.error.unmapped_record", fallback: "A source record has no resolved Idol mapping.")
        case .indexOverflow:
            ChekinanaL10n.text("import.error.objects", fallback: "A Cheki index is too large to import safely. No records were imported.")
        case .commitInProgress:
            ChekinanaL10n.text(
                "import.error.commit_in_progress",
                fallback: "A record import is already in progress."
            )
        }
    }
}
enum ChekiRokuIdolChoice: Hashable {
    case unresolved
    case create
    case existing(UUID)

    var isExisting: Bool {
        if case .existing = self { return true }
        return false
    }

    var isResolved: Bool { self != .unresolved }
}
private struct ChekiRokuPreparedSourceIdol: Sendable {
    let source: ChekinanaChekiRokuImport.SourceIdol
    let normalizedName: String
    let normalizedGroup: String

    init(_ source: ChekinanaChekiRokuImport.SourceIdol) {
        self.source = source
        normalizedName = ChekinanaChekiRokuImport.normalized(source.name)
        normalizedGroup = ChekinanaChekiRokuImport.normalized(source.group)
    }
}
private struct ChekiRokuLocalIdol: Sendable {
    let id: UUID
    let normalizedName: String
    let normalizedGroup: String

    init(_ idol: Idol) {
        id = idol.id
        normalizedName = ChekinanaChekiRokuImport.normalized(idol.name)
        normalizedGroup = ChekinanaChekiRokuImport.normalized(idol.group)
    }

    func matches(_ source: ChekiRokuPreparedSourceIdol) -> Bool {
        Self.fieldsMatch(source.normalizedName, normalizedName, isName: true)
            && Self.fieldsMatch(source.normalizedGroup, normalizedGroup, isName: false)
    }

    func exact(_ source: ChekiRokuPreparedSourceIdol) -> Bool {
        source.normalizedName == normalizedName && source.normalizedGroup == normalizedGroup
    }

    private static func fieldsMatch(_ first: String, _ second: String, isName: Bool) -> Bool {
        if first.isEmpty || second.isEmpty {
            return !isName && first.isEmpty && second.isEmpty
        }
        return first == second || first.contains(second) || second.contains(first)
    }
}
private struct ChekiRokuMatchResult: Sendable { let source: ChekiRokuPreparedSourceIdol; let candidates: [ChekiRokuLocalIdol] }
struct ChekiRokuIdolDraft: Identifiable {
    let id = UUID()
    let memberID: Int
    var name, group, color: String
    let avatarData: Data?
    let avatarPreview: ChekinanaRenderedImage?
    let matchCandidates: [Idol]
    var choice: ChekiRokuIdolChoice
    var isSelected: Bool = true
}

enum ChekiRokuMemberSelectionPolicy {
    static func controlsEnabled(isSaving: Bool, isMatching: Bool) -> Bool {
        !isSaving && !isMatching
    }

    static func setAll(_ selected: Bool, drafts: inout [ChekiRokuIdolDraft]) {
        for index in drafts.indices { drafts[index].isSelected = selected }
    }

    static func selectedMemberIDs(_ drafts: [ChekiRokuIdolDraft]) -> Set<Int> {
        Set(drafts.lazy.filter(\.isSelected).map(\.memberID))
    }

    static func canAdvance(_ drafts: [ChekiRokuIdolDraft]) -> Bool {
        drafts.lazy.filter(\.isSelected).allSatisfy {
            !ChekinanaChekiRokuImport.normalized($0.name).isEmpty
                && $0.choice.isResolved
        }
    }

    static func selectedRecords(
        _ records: [ChekinanaChekiRokuImport.SourceRecord],
        drafts: [ChekiRokuIdolDraft]
    ) -> [ChekinanaChekiRokuImport.SourceRecord] {
        let selected = selectedMemberIDs(drafts)
        return records.filter {
            $0.category == 1 && selected.contains($0.memberID)
        }
    }
}

enum ChekiRokuAvatarPreviewer {
    static func makePreviews(_ images: [String: Data]) async -> [String: ChekinanaRenderedImage] {
        var previews: [String: ChekinanaRenderedImage] = [:]
        previews.reserveCapacity(images.count)
        for name in images.keys.sorted() {
            guard !Task.isCancelled, let data = images[name] else { break }
            if let preview = await ChekinanaImageWorker.previewImage(from: data, maxDimension: 88) {
                previews[name] = preview
            }
        }
        return previews
    }
}

private struct ChekiRokuExistingIdolOption: View {
    let idol: Idol
    @State private var avatar: ChekinanaRenderedImage?

    private var shortID: String { String(idol.id.uuidString.prefix(8)).lowercased() }
    private var avatarLoadID: String { "\(idol.id.uuidString)|\(idol.avatarImageRef ?? "")" }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let avatar {
                    Image(decorative: avatar.cgImage, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            .accessibilityHidden(true)

            Text(ChekinanaL10n.format(
                "import.local_identity",
                fallback: "%1$@ · %2$@ · ID %3$@",
                idol.name,
                idol.group?.nilIfEmpty ?? ChekinanaL10n.text("import.no_group", fallback: "No group"),
                shortID
            ))
        }
        .accessibilityElement(children: .combine)
        .task(id: avatarLoadID) {
            avatar = await ChekinanaThumbnailCache.shared.thumbnailImage(
                forManagedImageRef: idol.avatarImageRef,
                key: avatarLoadID,
                maxDimension: 64
            )
        }
    }
}
enum ChekiRokuIdolMatcher { static func exact(source: ChekinanaChekiRokuImport.SourceIdol, local: Idol) -> Bool { ChekinanaChekiRokuImport.normalized(source.name) == ChekinanaChekiRokuImport.normalized(local.name) && ChekinanaChekiRokuImport.normalized(source.group) == ChekinanaChekiRokuImport.normalized(local.group) }; static func matches(source: ChekinanaChekiRokuImport.SourceIdol, local: Idol) -> Bool { ChekinanaChekiRokuImport.fieldsMatch(source.name, local.name, isName: true) && ChekinanaChekiRokuImport.fieldsMatch(source.group, local.group) } }
extension ChekinanaChekiRokuImport.Archive: Identifiable { var id: URL { temporaryDirectory } }
enum ChekiRokuType: Sendable, Hashable {
    case cheki

    var kind: ChekinanaRecordKind { .cheki }
    var title: String { kind.title }
}
struct ChekiRokuPlanItem: Sendable {
    let idolID: UUID
    let idolName: String
    let day: Date?
    let type: ChekiRokuType
    let memoRuns: [ChekiRokuRecordImportPlanner.MemoRun]
    let nextIndex: Int
    let count: Int

    init(
        idolID: UUID,
        idolName: String,
        day: Date?,
        type: ChekiRokuType,
        memoRuns: [ChekiRokuRecordImportPlanner.MemoRun],
        nextIndex: Int
    ) {
        self.idolID = idolID
        self.idolName = idolName
        self.day = day
        self.type = type
        self.memoRuns = memoRuns
        self.nextIndex = nextIndex
        self.count = memoRuns.reduce(0) { $0 + $1.count }
    }
}
private struct ChekiRokuRecordPlan {
 let items: [ChekiRokuPlanItem]
 let summaries: [Summary]
 let newCount: Int
 let sourceRecords: [ChekinanaChekiRokuImport.SourceRecord]
 let memberMap: [Int: UUID]
 let idolNames: [UUID: String]
 struct Summary { let idolID: UUID; let idolName: String; let cheki: Int
     var label: String { ChekinanaRecordKind.cheki.countLabel(cheki) }
 }
 /// UI summary only: one deterministic row per idol, never one row per date/object.
 init(
    items: [ChekiRokuPlanItem],
    sourceRecords: [ChekinanaChekiRokuImport.SourceRecord] = [],
    memberMap: [Int: UUID] = [:],
    idolNames: [UUID: String] = [:]
 ) {
    self.items = items
    self.sourceRecords = sourceRecords
    self.memberMap = memberMap
    self.idolNames = idolNames
    self.newCount = items.reduce(0) { $0 + $1.count }
    var buckets: [UUID: (String, Int)] = [:]
    for item in items {
        var value = buckets[item.idolID] ?? (item.idolName, 0)
        value.1 += item.count
        buckets[item.idolID] = value
    }
    self.summaries = buckets.map {
        Summary(idolID: $0.key, idolName: $0.value.0, cheki: $0.value.1)
    }.sorted {
        $0.idolName.localizedCaseInsensitiveCompare($1.idolName) == .orderedAscending
    }
 }
 }

/// Pure, background-safe Step 2 planner shared by the wizard and focused tests.
struct ChekiRokuRecordImportPlanner {
    struct Existing: Sendable { let idolID: UUID; let day: Date?; let category: Int; let index: Int? }
    struct MemoRun: Sendable, Equatable { let memo: String; let count: Int }
    struct Item: Sendable { let idolID: UUID; let day: Date?; let category: Int; let memoRuns: [MemoRun]; let nextIndex: Int; var count: Int { memoRuns.reduce(0) { $0 + $1.count } } }
    private struct Key: Hashable { let idolID: UUID; let day: Date?; let category: Int }
    static func make(records: [ChekinanaChekiRokuImport.SourceRecord], memberMap: [Int: UUID], existing: [Existing]) throws -> [Item] {
        var rows: [Key: [ChekinanaChekiRokuImport.SourceRecord]] = [:]
        for record in records {
            guard record.category == 1,
                  let idolID = memberMap[record.memberID],
                  record.count > 0 else { continue }
            let key = Key(
                idolID: idolID,
                day: record.date.flatMap(ChekinanaDateOnly.canonicalized),
                category: 1
            )
            rows[key, default: []].append(record)
        }
        var existingByKey: [Key: (count: Int, maxIndex: Int)] = [:]
        for value in existing {
            guard value.category == 1 else { continue }
            let key = Key(idolID: value.idolID, day: value.day.flatMap(ChekinanaDateOnly.canonicalized), category: value.category)
            var bucket = existingByKey[key, default: (0, 0)]
            bucket.count += 1; bucket.maxIndex = max(bucket.maxIndex, value.index ?? 0)
            existingByKey[key] = bucket
        }
        var items: [Item] = []
        for key in rows.keys.sorted(by: { "\($0.idolID)-\($0.day?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude)-\($0.category)" < "\($1.idolID)-\($1.day?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude)-\($1.category)" }) {
            let bucket = existingByKey[key] ?? (0, 0)
            let skip = bucket.count
            var ignored = skip; var memoRuns: [MemoRun] = []
            for row in rows[key] ?? [] {
                let skipped = min(ignored, row.count)
                ignored -= skipped
                let remaining = row.count - skipped
                guard remaining > 0 else { continue }
                if let last = memoRuns.last, last.memo == row.memo {
                    memoRuns[memoRuns.count - 1] = MemoRun(memo: last.memo, count: last.count + remaining)
                } else {
                    memoRuns.append(MemoRun(memo: row.memo, count: remaining))
                }
            }
            if !memoRuns.isEmpty {
                let next: Int
                let result = bucket.maxIndex.addingReportingOverflow(1)
                guard !result.overflow else { throw ChekiRokuImportUIError.indexOverflow }
                next = result.partialValue
                items.append(Item(idolID: key.idolID, day: key.day, category: key.category, memoRuns: memoRuns, nextIndex: next))
            }
        }
        return items
    }
}

struct ChekiRokuRecordImportProgress: Sendable, Equatable {
    let commitID: UUID
    let completed: Int
    let total: Int
    let idolName: String
}

enum ChekiRokuRecordProgressPolicy {
    static func shouldAccept(
        activeCommitID: UUID?,
        update: ChekiRokuRecordImportProgress,
        currentCompleted: Int,
        importCompleted: Bool
    ) -> Bool {
        !importCompleted
            && activeCommitID == update.commitID
            && update.completed >= currentCompleted
    }
}

/// Owns the Step 2 SwiftData context. The actor must be initialized away from
/// MainActor so its generated ModelContext uses the background serial executor.
@ModelActor
actor ChekiRokuRecordImportActor {
    typealias ProgressHandler = @MainActor @Sendable (ChekiRokuRecordImportProgress) -> Void
    private var activeCommitID: UUID?

    func plan(
        records: [ChekinanaChekiRokuImport.SourceRecord],
        memberMap: [Int: UUID]
    ) throws -> [ChekiRokuRecordImportPlanner.Item] {
        try ChekiRokuRecordImportPlanner.make(
            records: records,
            memberMap: memberMap,
            existing: liveExistingRecords()
        )
    }

    private func liveExistingRecords() throws -> [ChekiRokuRecordImportPlanner.Existing] {
        let chekis = try modelContext.fetch(FetchDescriptor<Cheki>())
        return chekis.compactMap { value -> ChekiRokuRecordImportPlanner.Existing? in
            guard value.idols.count == 1,
                  let idolID = value.idols.first?.id else { return nil }
            return .init(idolID: idolID, day: value.date, category: 1, index: value.idx)
        }
    }

    func save(
        commitID: UUID = UUID(),
        records: [ChekinanaChekiRokuImport.SourceRecord],
        memberMap: [Int: UUID],
        idolNames: [UUID: String],
        beforePersistForTesting: (@Sendable () -> Void)? = nil,
        progress: @escaping ProgressHandler
    ) throws -> Int {
        guard activeCommitID == nil else {
            throw ChekiRokuImportUIError.commitInProgress
        }
        activeCommitID = commitID
        defer { activeCommitID = nil }
        modelContext.autosaveEnabled = false
        let chekiRecords = records.filter { $0.category == 1 }
        let requiredIDs = Set(chekiRecords.compactMap { memberMap[$0.memberID] })
        let hiddenIDs = ChekinanaHiddenIdolPersistence.load()
        guard requiredIDs.isDisjoint(with: hiddenIDs) else {
            throw ChekiRokuImportUIError.missingDestinationIdol
        }
        let fetched = try modelContext.fetch(FetchDescriptor<Idol>())
        let matchesByID = Dictionary(
            grouping: fetched.filter { requiredIDs.contains($0.id) },
            by: \.id
        )
        guard requiredIDs.allSatisfy({ matchesByID[$0]?.count == 1 }) else {
            throw ChekiRokuImportUIError.missingDestinationIdol
        }
        let destinationIdols = matchesByID.mapValues { $0[0] }
        let fetchedEvents = try modelContext.fetch(FetchDescriptor<Event>())
        let eventsByID = Dictionary(uniqueKeysWithValues: fetchedEvents.map { ($0.id, $0) })

        // Preview is advisory. Re-fetch and rebuild the deficit/idx plan in this
        // exact committing context immediately before any insert so a record
        // added after preview cannot be duplicated or reuse an occupied index.
        let liveExisting = try liveExistingRecords()
        let liveItems = try ChekiRokuRecordImportPlanner.make(
            records: chekiRecords,
            memberMap: memberMap,
            existing: liveExisting
        )
        guard liveItems.allSatisfy({ idolNames[$0.idolID] != nil }) else {
            throw ChekiRokuImportUIError.unmappedRecord
        }
        let items = liveItems.map { item in
            ChekiRokuPlanItem(
                idolID: item.idolID,
                idolName: idolNames[item.idolID]!,
                day: item.day,
                type: .cheki,
                memoRuns: item.memoRuns,
                nextIndex: item.nextIndex
            )
        }
        let total = items.reduce(0) { $0 + $1.count }

        var inserted = 0
        var lastPublished = -64
        var publishedIdolID: UUID?
        do {
            for item in items {
                try Task.checkCancellation()
                guard let idol = destinationIdols[item.idolID] else {
                    throw ChekiRokuImportUIError.missingDestinationIdol
                }
                if publishedIdolID != item.idolID || inserted - lastPublished >= 64 {
                    publishProgress(
                        .init(commitID: commitID, completed: inserted, total: total, idolName: item.idolName),
                        to: progress
                    )
                    publishedIdolID = item.idolID
                    lastPublished = inserted
                }

                var itemOffset = 0
                for run in item.memoRuns {
                    for _ in 0..<run.count {
                        try Task.checkCancellation()
                        if inserted - lastPublished >= 64 {
                            publishProgress(
                                .init(commitID: commitID, completed: inserted, total: total, idolName: item.idolName),
                                to: progress
                            )
                            lastPublished = inserted
                        }

                        // New @Model instances begin in a temporary context. Insert
                        // first, then attach only objects fetched by this actor.
                        let (idx, overflow) = item.nextIndex.addingReportingOverflow(itemOffset)
                        guard !overflow else { throw ChekiRokuImportUIError.indexOverflow }
                        let record = Cheki(
                            date: item.day,
                            idx: idx,
                            size: .mini,
                            note: run.memo
                        )
                        modelContext.insert(record)
                        record.idols = [idol]
                        if let eventID = ChekinanaChekiEventAutoAssociation.uniqueEventID(
                            for: item.day,
                            events: fetchedEvents.map { ($0.id, $0.date) }
                        ) {
                            record.event = eventsByID[eventID]
                        }
                        inserted += 1
                        itemOffset += 1
                    }
                }
            }
            beforePersistForTesting?()
            try Task.checkCancellation()
            try modelContext.save()
            return inserted
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func publishProgress(
        _ update: ChekiRokuRecordImportProgress,
        to progress: @escaping ProgressHandler
    ) {
        Task { @MainActor in
            progress(update)
        }
    }

}
private extension String { var nilIfEmpty: String? { let value=trimmingCharacters(in:.whitespacesAndNewlines); return value.isEmpty ? nil : value } }

/// A full-page, local-only import entry. Reading is explicitly user initiated so
/// iOS does not request pasteboard access merely by opening the page.
struct ChekinanaChekiRokuClipboardImportView: View {
    let onClose: () -> Void
    @State private var archive: ChekinanaChekiRokuImport.Archive?
    @State private var stage = ""
    @State private var error: String?
    @State private var isReading = false
    @State private var wizardBusy = false
    @State private var readGeneration = 0
    @State private var readTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let archive {
                    ChekinanaChekiRokuImportWizard(archive: archive, onClose: {
                        ChekinanaChekiRokuImport.cleanup(archive)
                        self.archive = nil
                    }, isExternallyBusy: $wizardBusy)
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.accentColor)
                        Text(ChekinanaL10n.text("import.title", fallback: "Import from ChekiRoku")).font(.title2.weight(.semibold))
                        Text(ChekinanaL10n.text("import.intro", fallback: "Copy one .chekiroku backup in Files, then read it here. Your clipboard is never changed."))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 28)
                        if !stage.isEmpty { ProgressView(stage).padding(.top, 4) }
                        if let error { Text(error).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.red).padding(.horizontal, 24) }
                        Button(ChekinanaL10n.text("import.action.read", fallback: "Read ChekiRoku from Clipboard")) { readClipboard() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isReading)
                            .accessibilityIdentifier("chekinana.import.read")
                    }
                }
            }
            .navigationTitle(ChekinanaL10n.text("import.title", fallback: "ChekiRoku Import"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaL10n.text("action.back", fallback: "Back")) { close() }
                        .disabled(isReading || wizardBusy)
                        .accessibilityIdentifier("chekinana.import.back")
                }
            }
            .tint(ChekinanaDesignSystem.accent)
            .background(ChekinanaDesignSystem.pageBackground)
            .navigationBarBackButtonHidden(isReading || wizardBusy)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chekinana.import.page")
        }
        .onAppear { installUITestFixtureIfRequested() }
        .onDisappear { readGeneration += 1; readTask?.cancel(); if let archive, !wizardBusy { ChekinanaChekiRokuImport.cleanup(archive) } }
    }

    private func readClipboard() {
        guard !isReading else { return }
        isReading = true; error = nil; stage = ChekinanaL10n.text("import.stage.reading", fallback: "Reading clipboard"); readGeneration += 1
        let generation = readGeneration
        readTask = Task { @MainActor in
            do {
                let temporaryURL = try await ChekinanaChekiRokuClipboardReader.copySingleArchiveFromPasteboard()
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard !Task.isCancelled, generation == readGeneration else { return }
                stage = ChekinanaL10n.text("import.stage.parsing", fallback: "Parsing archive")
                let result = await Task.detached { Result { try ChekinanaChekiRokuImport.read(temporaryURL) } }.value
                guard !Task.isCancelled, generation == readGeneration else { if case .success(let parsed) = result { ChekinanaChekiRokuImport.cleanup(parsed) }; return }
                switch result {
                case .success(let parsed):
                    stage = ChekinanaL10n.text("import.stage.matching", fallback: "Matching Idols")
                    await Task.yield()
                    archive = parsed
                    stage = ""
                case .failure(let parseError): throw parseError
                }
            } catch {
                stage = ""
                self.error = error.localizedDescription
            }
            if generation == readGeneration { isReading = false; readTask = nil }
        }
    }
    private func close() { readGeneration += 1; readTask?.cancel(); onClose() }

    private func installUITestFixtureIfRequested() {
#if DEBUG
        guard archive == nil,
              ProcessInfo.processInfo.environment["CHEKINANA_CHEKIROKU_UI_STUB"] == "fixture"
        else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekinanaChekiRokuUITest", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            archive = ChekinanaChekiRokuImport.Archive(
                idols: [
                    .init(
                        id: 1,
                        name: "Fixture Idol",
                        group: "Fixture Group",
                        color: "紫色",
                        avatarName: nil
                    )
                ],
                records: [
                    .init(
                        memberID: 1,
                        date: Calendar.current.startOfDay(for: Date()),
                        count: 1,
                        category: 1,
                        memo: ""
                    )
                ],
                imageData: [:],
                temporaryDirectory: directory
            )
        } catch {
            self.error = error.localizedDescription
        }
#endif
    }
}

private enum ChekinanaChekiRokuClipboardReader {
    private static let supportedTypes = ["com.chekiroku.backup", "public.zip-archive", "public.data", "public.file-url"]
    private static let plainTextTypes = ["public.utf8-plain-text", "public.plain-text"]

    @MainActor static func copySingleArchiveFromPasteboard() async throws -> URL {
        let providers = UIPasteboard.general.itemProviders
        guard providers.count == 1, let provider = providers.first else {
            throw ChekinanaChekiRokuClipboardError.ambiguousClipboard
        }
        let destination = try temporaryArchiveURL()
        do {
            if let type = supportedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
                do {
                    try await copyFileRepresentation(provider, type: type, to: destination)
                    return destination
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    guard plainTextTypes.contains(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { throw error }
                }
            }

            guard let textType = plainTextTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
                throw ChekinanaChekiRokuClipboardError.unsupportedClipboard
            }
            try await copyPlainTextFilePath(provider, type: textType, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func temporaryArchiveURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChekinanaChekiRokuClipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("chekiroku")
    }

    @MainActor private static func copyFileRepresentation(_ provider: NSItemProvider, type: String, to destination: URL) async throws {
        do {
            try await copyLoadedFileRepresentation(provider, type: type, inPlace: true, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            try await copyLoadedFileRepresentation(provider, type: type, inPlace: false, to: destination)
        }
    }

    @MainActor private static func copyLoadedFileRepresentation(_ provider: NSItemProvider, type: String, inPlace: Bool, to destination: URL) async throws {
        let box = ChekinanaItemProviderBox(provider)
        let gate = ChekinanaClipboardCompletionGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled, gate.claimTimeout() { continuation.resume(throwing: ChekinanaChekiRokuClipboardError.timedOut) }
            }
            let completion: @Sendable (URL?, Error?) -> Void = { url, error in
                guard gate.claimCopy() else { return }
                timeout.cancel()
                guard let url else {
                    if gate.finish() { continuation.resume(throwing: error ?? ChekinanaChekiRokuClipboardError.unreadable) }
                    return
                }
                copy(url, to: destination, gate: gate, continuation: continuation)
            }
            if inPlace {
                box.provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, _, error in
                    completion(url, error)
                }
            } else {
                box.provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    completion(url, error)
                }
            }
        }
    }

    /// Finder and the macOS shared pasteboard can expose a copied file only as
    /// text. Accept only an existing local `.chekiroku` file path, never the
    /// backup contents as ordinary plain text.
    @MainActor private static func copyPlainTextFilePath(_ provider: NSItemProvider, type: String, to destination: URL) async throws {
        let box = ChekinanaItemProviderBox(provider)
        let gate = ChekinanaClipboardCompletionGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled, gate.claimTimeout() { continuation.resume(throwing: ChekinanaChekiRokuClipboardError.timedOut) }
            }
            box.provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                guard gate.claimCopy() else { return }
                timeout.cancel()
                do {
                    guard let data, let text = String(data: data, encoding: .utf8), let source = archiveFileURL(from: text) else {
                        throw ChekinanaChekiRokuClipboardError.unsupportedClipboard
                    }
                    try copyArchiveFile(source, to: destination)
                    if gate.finish() { continuation.resume() }
                } catch {
                    if gate.finish() { continuation.resume(throwing: error) }
                }
            }
        }
    }

    private static func archiveFileURL(from plainText: String) -> URL? {
        let candidate = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if let fileURL = URL(string: candidate), fileURL.isFileURL {
            url = fileURL
        } else if candidate.hasPrefix("/") {
            url = URL(fileURLWithPath: candidate)
        } else {
            url = nil
        }
        guard let url,
              url.pathExtension.caseInsensitiveCompare("chekiroku") == .orderedSame,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private static func copy(_ source: URL, to destination: URL, gate: ChekinanaClipboardCompletionGate, continuation: CheckedContinuation<Void, Error>) {
        do {
            try copyArchiveFile(source, to: destination)
            if gate.finish() { continuation.resume() }
        } catch { if gate.finish() { continuation.resume(throwing: error) } }
    }

    private static func copyArchiveFile(_ source: URL, to destination: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 32 * 1_024 * 1_024 else {
            throw ChekinanaChekiRokuClipboardError.notZIP
        }
        try FileManager.default.copyItem(at: source, to: destination)
        let prefix = try Data(contentsOf: destination, options: [.mappedIfSafe]).prefix(2)
        guard prefix.elementsEqual([0x50, 0x4B]) else {
            try? FileManager.default.removeItem(at: destination)
            throw ChekinanaChekiRokuClipboardError.notZIP
        }
    }
}

private final class ChekinanaItemProviderBox: @unchecked Sendable { let provider: NSItemProvider; init(_ provider: NSItemProvider) { self.provider = provider } }
private final class ChekinanaClipboardCompletionGate: @unchecked Sendable {
    private let lock = NSLock(); private var state = 0
    func claimCopy() -> Bool { lock.lock(); defer { lock.unlock() }; guard state == 0 else { return false }; state = 1; return true }
    func claimTimeout() -> Bool { lock.lock(); defer { lock.unlock() }; guard state == 0 else { return false }; state = 2; return true }
    func finish() -> Bool { lock.lock(); defer { lock.unlock() }; guard state == 1 else { return false }; state = 2; return true }
}

private enum ChekinanaChekiRokuClipboardError: LocalizedError {
    case ambiguousClipboard, unsupportedClipboard, notZIP, unreadable, timedOut
    var errorDescription: String? {
        switch self {
        case .ambiguousClipboard: return ChekinanaL10n.text("import.error.clipboard_ambiguous", fallback: "Copy exactly one ChekiRoku backup before importing.")
        case .unsupportedClipboard: return ChekinanaL10n.text("import.error.clipboard_unsupported", fallback: "The clipboard does not contain a ChekiRoku backup file. Plain text is not supported.")
        case .notZIP: return ChekinanaL10n.text("import.error.not_zip", fallback: "The copied file is not a valid ZIP-based ChekiRoku backup.")
        case .unreadable: return ChekinanaL10n.text("import.error.unreadable", fallback: "The copied ChekiRoku backup could not be read.")
        case .timedOut: return ChekinanaL10n.text("import.error.timeout", fallback: "Reading the copied ChekiRoku backup timed out. Try copying the file again.")
        }
    }
}

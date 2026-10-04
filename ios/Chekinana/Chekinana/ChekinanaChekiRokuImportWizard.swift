import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// ChekiRoku identities are reviewed against the catalogue before any writes.
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
    @State private var matchingTask: Task<Void, Never>?
    @State private var matchingGeneration: UUID?
    @State private var cachedPlan: ChekiRokuRecordPlan?
    @State private var selectedRecordRowIDs = Set<Int>()
    @State private var ignoresRecordNotes = false
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
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChekinanaChekiRokuNavigationTitle()
            }
            ToolbarItem(placement: .cancellationAction) { Button(ChekinanaL10n.text("action.back", fallback: "Back")) { finish() }.disabled(isSaving || isPlanning).accessibilityIdentifier("chekinana.import.wizard.cancel") }
        }
        .tint(ChekinanaDesignSystem.accent)
        .background(ChekinanaDesignSystem.pageBackground)
        .navigationBarBackButtonHidden(isSaving || isPlanning)
        .interactiveDismissDisabled(isSaving || isPlanning)
        .onChange(of: isSaving || isPlanning || isMatching) { _, busy in isExternallyBusy = busy }
        .onAppear { if drafts.isEmpty && !isMatching { prepareDrafts() } }
        .onDisappear { cancelMatching(); if !completed { ChekinanaChekiRokuImport.cleanup(archive) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.import.wizard")
    }

    private var idolStep: some View {
        List {
            Section {
                ChekiRokuStepHeader(step: 1, title: ChekinanaL10n.text("import.step1", fallback: "Step 1 of 2 · Add Idols"))
                Text(ChekinanaL10n.text("import.review", fallback: "Review the local Idol matches. New Idols use a unique name-and-group catalogue match, or the backup profile if the search fails."))
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
                        matchDrafts()
                    }
                        .buttonStyle(.borderless)
                        .disabled(!draftControlsEnabled)
                        .accessibilityIdentifier("chekinana.import.step1.select-all")
                    Spacer()
                    Button(ChekinanaL10n.text("import.deselect_all", fallback: "Deselect All")) {
                        ChekiRokuMemberSelectionPolicy.setAll(false, drafts: &drafts)
                    }
                        .buttonStyle(.borderless)
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
                        isOn: Binding(
                            get: { draft.isSelected },
                            set: { selected in
                                draft.isSelected = selected
                                if selected { matchDrafts(memberIDs: [draft.memberID]) }
                            }
                        )
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
                            if draft.choice == .create, draft.catalogueSearchName != nil {
                                HStack {
                                    TextField(
                                        ChekinanaL10n.text("import.catalogue.search_name", fallback: "Temporary search name"),
                                        text: Binding(
                                            get: { draft.catalogueSearchName ?? draft.name },
                                            set: { draft.updateCatalogueSearchName($0) }
                                        )
                                    )
                                    .focused($isDraftFieldFocused)
                                    .submitLabel(.search)
                                    .onSubmit { retryCatalogueSearch(memberID: draft.memberID) }
                                    Button(ChekinanaL10n.text("import.catalogue.search_one", fallback: "Search")) {
                                        retryCatalogueSearch(memberID: draft.memberID)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("chekinana.import.step1.member.\(draft.memberID).search")
                                }
                            } else {
                                TextField(ChekinanaL10n.text("import.name", fallback: "Name"), text: $draft.name)
                                    .focused($isDraftFieldFocused)
                            }
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
                    .onChange(of: draft.query) { _, _ in invalidateMatch(memberID: draft.memberID) }
                    if draft.choice != .create || draft.catalogueCandidate == nil {
                    TextField(
                        ChekinanaL10n.text("import.color", fallback: "Color"),
                        text: localizedColorBinding($draft.color)
                    )
                    .focused($isDraftFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!draftControlsEnabled || !draft.isSelected)
                    .opacity(draft.isSelected ? 1 : 0.55)
                    if draft.isSelected,
                       draft.choice == .create,
                       let colorError = ChekinanaIdolColorInputPolicy
                        .validationMessage(draft.color) {
                        Text(colorError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    }
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
                    }
                    if draft.isSelected && draft.choice == .create {
                        Text(catalogueSummary(draft))
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if draft.isSelected && draft.matchCandidates.count <= 1 {
                        Text(ChekinanaL10n.text("import.existing_skip", fallback: "Existing Idol — will skip"))
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
                .disabled(isSaving || isMatching || !ChekiRokuMemberSelectionPolicy.canAdvance(drafts))
                .accessibilityIdentifier("chekinana.import.step1.continue")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chekinana.import.step1")
    }

    private var recordStep: some View {
        let selectedCount = selectedRecordCount
        return List {
            Section {
                ChekiRokuStepHeader(step: 2, title: ChekinanaL10n.text("import.step2", fallback: "Step 2 of 2 · Add Records"))
                Text(ChekinanaL10n.text("import.only_missing", fallback: "Only missing quantities are added. Existing records count whether or not they have media."))
                Text(ChekinanaL10n.format(
                    "import.record_summary",
                    fallback: "Source rows: %1$lld · Records to add: %2$lld",
                    Int64(selectedSourceRowCount),
                    Int64(selectedCount)
                ))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(ChekinanaL10n.text("import.select_all", fallback: "Select All")) {
                        selectedRecordRowIDs = Set(recordPlan.rows.map(\.sourceIndex))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("chekinana.import.step2.select-all")
                    Spacer()
                    Button(ChekinanaL10n.text("import.deselect_all", fallback: "Deselect All")) {
                        selectedRecordRowIDs.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("chekinana.import.step2.deselect-all")
                }
                Toggle(ChekinanaL10n.text("import.records.ignore_notes", fallback: "Ignore notes"), isOn: $ignoresRecordNotes)
                    .accessibilityIdentifier("chekinana.import.step2.ignore-notes")
            }
            .disabled(isSaving || isPlanning)
            ForEach(recordPlan.rows) { row in
                Toggle(isOn: Binding(
                    get: { selectedRecordRowIDs.contains(row.sourceIndex) },
                    set: { selected in
                        if selected { selectedRecordRowIDs.insert(row.sourceIndex) }
                        else { selectedRecordRowIDs.remove(row.sourceIndex) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recordPlan.idolNames[row.idolID] ?? "")
                        Text(row.day.map(ChekinanaDateOnly.string)
                             ?? ChekinanaProductCopy.text("common.no_date", "No date"))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(ChekinanaL10n.format(
                            "import.records.row_quantity",
                            fallback: "Source quantity: %1$lld · To add: %2$lld",
                            Int64(recordPlan.sourceRecords[row.sourceIndex].count), Int64(row.count)
                        ))
                        .font(.footnote).foregroundStyle(.secondary)
                        if !ignoresRecordNotes && !row.memo.isEmpty {
                            Text(row.memo).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isSaving || isPlanning)
                .accessibilityIdentifier("chekinana.import.step2.row.\(row.sourceIndex)")
            }
            if !progress.isEmpty { Section { importProgress } }
            if let message { Section { Text(message).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .background(ChekinanaDesignSystem.pageBackground)
        .safeAreaInset(edge: .bottom) {
            ViewThatFits(in: .horizontal) {
                HStack { recordBackButton; Spacer(); recordImportButton(selectedCount: selectedCount) }
                VStack(spacing: 8) { recordImportButton(selectedCount: selectedCount); recordBackButton }
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

    private func recordImportButton(selectedCount: Int) -> some View {
        Button(ChekinanaL10n.quantity(
            "import.action.records",
            count: selectedCount,
            one: "Import %lld Record",
            other: "Import %lld Records"
        )) {
            Task { await saveRecords() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSaving || isPlanning || cachedPlan == nil || recordImporter == nil || selectedCount == 0)
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
                    .frame(width: 44, height: 44)
                    .background(Color.white)
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
        cancelMatching()
        let generation = UUID()
        matchingGeneration = generation
        isMatching = true; progress = ChekinanaL10n.text("import.stage.matching", fallback: "Matching Idols")
        let source = archive.idols.map(ChekiRokuPreparedSourceIdol.init)
        let avatarData = archive.imageData
        let local = localIdols.map(ChekiRokuLocalIdol.init)
        let idolsByID = Dictionary(uniqueKeysWithValues: localIdols.map { ($0.id, $0) })
        matchingTask = Task { @MainActor in
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
            guard !Task.isCancelled, matchingGeneration == generation else { return }
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
                        ?? (candidates.count > 1 ? .unresolved : .create),
                    isSelected: false
                )
            }
            matchingGeneration = nil; matchingTask = nil; isMatching = false; progress = ""
        }
    }

    private func matchDrafts(memberIDs: Set<Int>? = nil) {
        guard !isSaving, !isMatching else { return }
        let generation = UUID()
        matchingGeneration = generation
        isMatching = true
        message = nil
        progress = ChekinanaL10n.text("import.stage.matching", fallback: "Searching Idol catalogue…")
        matchingTask = Task { @MainActor in await resolveDrafts(generation: generation, memberIDs: memberIDs) }
    }

    @MainActor
    private func resolveDrafts(generation: UUID, memberIDs: Set<Int>?) async {
        defer {
            if matchingGeneration == generation {
                matchingGeneration = nil; matchingTask = nil; isMatching = false; progress = ""
            }
        }
        let queries = ChekiRokuMemberSelectionPolicy.catalogueQueries(drafts, memberIDs: memberIDs)
        let revisions = Dictionary(uniqueKeysWithValues: drafts.map { ($0.memberID, $0.catalogueSearchRevision) })
        do {
            let results = try await ChekiRokuCatalogueMatching.resolve(queries)
            try Task.checkCancellation()
            guard matchingGeneration == generation else { return }
            for index in drafts.indices {
                guard drafts[index].isSelected, drafts[index].choice == .create,
                      memberIDs?.contains(drafts[index].memberID) ?? true,
                      let revision = revisions[drafts[index].memberID],
                      let resolution = results[drafts[index].query] else { continue }
                drafts[index].applyCatalogueResolution(resolution, revision: revision)
            }
        } catch is CancellationError {
            // Closing this wizard is never permission to create fallback Idols.
        } catch {
            guard matchingGeneration == generation else { return }
            message = error.localizedDescription
        }
    }

    private func cancelMatching() {
        matchingGeneration = nil; matchingTask?.cancel(); matchingTask = nil
        isMatching = false; progress = ""
    }

    private func retryCatalogueSearch(memberID: Int) {
        guard draftControlsEnabled,
              let index = drafts.firstIndex(where: { $0.memberID == memberID }),
              drafts[index].isSelected, drafts[index].choice == .create else { return }
        isDraftFieldFocused = false
        drafts[index].invalidateCatalogueSearch()
        matchDrafts(memberIDs: [memberID])
    }

    private func invalidateMatch(memberID: Int) {
        guard let index = drafts.firstIndex(where: { $0.memberID == memberID }),
              !drafts[index].hasCurrentResolution else { return }
        drafts[index].invalidateCatalogueSearch()
    }

    private func catalogueSummary(_ draft: ChekiRokuIdolDraft) -> String {
        guard let resolution = draft.resolution, resolution.query == draft.query else {
            return ChekinanaL10n.text("import.catalogue.pending", fallback: "Search the current name and group before continuing.")
        }
        switch resolution.outcome {
        case .matched(let candidate):
            return ChekinanaL10n.format("import.catalogue.matched", fallback: "Catalogue match: %1$@ · %2$@", candidate.idolName, candidate.groupName ?? "")
        case .fallback(let reason):
            let reasonText: String
            switch reason {
            case .missingGroup: reasonText = ChekinanaL10n.text("import.catalogue.missing_group", fallback: "Group is missing and cannot be verified.")
            case .notFound: reasonText = ChekinanaL10n.text("import.catalogue.not_found", fallback: "No exact name match was found.")
            case .groupMismatch: reasonText = ChekinanaL10n.text("import.catalogue.group_mismatch", fallback: "The group does not match.")
            case .ambiguous: reasonText = ChekinanaL10n.text("import.catalogue.ambiguous", fallback: "More than one catalogue match was found.")
            case .unavailable: reasonText = ChekinanaL10n.text("import.catalogue.unavailable", fallback: "The catalogue search failed.")
            case .incomplete: reasonText = ChekinanaL10n.text("import.catalogue.incomplete", fallback: "Search results may be incomplete.")
            case .invalidMetadata: reasonText = ChekinanaL10n.text("import.catalogue.invalid", fallback: "The catalogue profile contains invalid data.")
            }
            return ChekinanaL10n.format("import.catalogue.fallback", fallback: "%@ Using the backup profile.", reasonText)
        }
    }

    private func saveIdols() {
        guard !isSaving, !isMatching, ChekiRokuMemberSelectionPolicy.canAdvance(drafts) else { return }
        let selectedIDs = ChekiRokuMemberSelectionPolicy.selectedMemberIDs(drafts)
        let selectedDrafts = drafts.filter(\.isSelected)
        let previousMap = memberMap
        selectedSourceRowCount = selectedSourceRecords.count
        memberMap = memberMap.filter { selectedIDs.contains($0.key) }
        isDraftFieldFocused = false; isSaving = true; progressTotal = selectedDrafts.count; progressCompleted = 0
        progress = ChekinanaL10n.format("import.progress.idol", fallback: "Adding Idol %lld/%lld", 0, Int64(selectedDrafts.count)); message = nil
        Task { @MainActor in
            do {
                try await ChekinanaLibraryMutationProtocol.withExclusiveOperation {
                    try ChekinanaLibraryMutationPreflight.requireImportConvergedExclusively(in: modelContext)
                    let previousAutosave = modelContext.autosaveEnabled
                    modelContext.autosaveEnabled = false
                    defer { modelContext.autosaveEnabled = previousAutosave }
                    var transactions: [(ChekinanaIdolAvatarStagingTransaction, Idol)] = []
                    do {
                        for (offset, draft) in selectedDrafts.enumerated() {
                            try Task.checkCancellation()
                            guard !ChekinanaChekiRokuImport.normalized(draft.name).isEmpty else { throw ChekiRokuImportUIError.invalidName }
                            progress = ChekinanaL10n.format("import.progress.idol_name", fallback: "Adding Idol %1$lld/%2$lld · %3$@", Int64(offset + 1), Int64(selectedDrafts.count), draft.name)
                            switch draft.choice {
                            case .unresolved: throw ChekiRokuImportUIError.unresolvedMember(draft.memberID)
                            case .existing(let id):
                                guard localIdols.contains(where: { $0.id == id }) else { throw ChekiRokuImportUIError.missingIdol(draft.memberID) }
                                memberMap[draft.memberID] = id
                            case .create:
                                guard draft.hasCurrentResolution else { throw ChekiRokuImportUIError.unresolvedMember(draft.memberID) }
                                let idol: Idol
                                if let candidate = draft.catalogueCandidate {
                                    let candidate = try ChekinanaBirthdayValue.normalizedCatalogueCandidate(candidate)
                                    let patterns = try await ChekinanaRemotePatternResources.shared.patterns(for: candidate.patternIds)
                                    let prepared = try await ChekinanaCatalogueIdolAvatarResolver.prepare(candidate)
                                    try Task.checkCancellation()
                                    idol = Idol(sourceId: candidate.sourceId, name: candidate.idolName, group: candidate.groupName,
                                                color: candidate.color, birthday: candidate.birthday, verification: candidate.verification,
                                                bio: candidate.bio, patterns: patterns)
                                    let transaction = try ChekinanaIdolAvatarStagingTransaction(in: modelContext)
                                    transactions.append((transaction, idol))
                                    idol.avatarImageRef = try await transaction.stage(prepared, idolID: idol.id).ref
                                    modelContext.insert(IdolPatternState(idolID: idol.id, encoderVersion: ChekinanaPatternContract.encoderVersion,
                                                                         cataloguePatternIDs: candidate.patternIds, cataloguePatternCount: patterns.count))
                                    _ = try ChekinanaIdolAvatarStatePersistence.record(idolID: idol.id, source: .catalogue, intent: .userSelected, in: modelContext)
                                } else {
                                    idol = Idol(name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                group: draft.group.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                                                color: try ChekinanaIdolColorInputPolicy.normalizedStorageValue(draft.color))
                                    if let data = draft.avatarData {
                                        guard let safeAvatar = await safeAvatarData(data) else { throw ChekiRokuImportUIError.invalidAvatar }
                                        try Task.checkCancellation()
                                        let transaction = try ChekinanaIdolAvatarStagingTransaction(in: modelContext)
                                        transactions.append((transaction, idol))
                                        idol.avatarImageRef = try await transaction.stage(safeAvatar, idolID: idol.id).ref
                                        _ = try ChekinanaIdolAvatarStatePersistence.record(idolID: idol.id, source: .custom, intent: .userSelected, in: modelContext)
                                    }
                                }
                                modelContext.insert(idol); memberMap[draft.memberID] = idol.id
                            }
                            progressCompleted = offset + 1
                        }
                        try Task.checkCancellation()
                        try modelContext.save()
                    } catch {
                        modelContext.rollback()
                        memberMap = previousMap
                        let pendingCleanup = transactions.reduce(false) { pending, entry in
                            let failed = entry.0.rollback() != nil
                            return pending || failed
                        }
                        if pendingCleanup { throw ChekinanaCatalogueIdolAvatarLocalizerError.cleanupRequired }
                        throw error
                    }
                    for (transaction, idol) in transactions { transaction.commit(referencedImageRef: idol.avatarImageRef) }
                }
                for index in drafts.indices where drafts[index].isSelected {
                    if let id = memberMap[drafts[index].memberID] { drafts[index].choice = .existing(id) }
                }
                step = 2; progress = ""; progressCompleted = 0; progressTotal = 0; cachedPlan = nil; recordImporter = nil; planRecords()
            } catch {
                memberMap = previousMap; message = error.localizedDescription; progress = ""
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
    private var recordSelection: ChekiRokuRecordImportPlanner.Selection {
        .init(quantities: Dictionary(uniqueKeysWithValues: recordPlan.rows.compactMap {
            selectedRecordRowIDs.contains($0.sourceIndex) ? ($0.sourceIndex, $0.count) : nil
        }), ignoresNotes: ignoresRecordNotes)
    }
    private var selectedRecordCount: Int {
        recordPlan.rows.reduce(0) { total, row in
            selectedRecordRowIDs.contains(row.sourceIndex) ? total + row.count : total
        }
    }
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
                let plannedRows = try await planner.planRows(records: records, memberMap: members)
                let planned = try ChekiRokuRecordImportPlanner.makeItems(from: plannedRows)
                guard planned.allSatisfy({ namesByID[$0.idolID] != nil }) else { throw ChekiRokuImportUIError.unmappedRecord }
                cachedPlan = .init(
                    items: planned.map { value in
                    .init(
                        idolID: value.idolID,
                        idolName: namesByID[value.idolID]!,
                        day: value.day,
                        type: .cheki,
                        memoRuns: value.memoRuns
                    )
                    },
                    rows: plannedRows,
                    sourceRecords: records,
                    memberMap: members,
                    idolNames: namesByID
                )
                selectedRecordRowIDs = Set(plannedRows.map(\.sourceIndex))
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
        guard !isSaving, !isPlanning, let recordImporter, let cachedPlan,
              selectedRecordCount > 0 else { return }
        let selection = recordSelection
        isSaving = true; progressTotal = selectedRecordCount; progressCompleted = 0; progress = ChekinanaL10n.text("import.stage.adding_records", fallback: "Adding records…"); message = nil
        let commitID = UUID()
        activeRecordCommitID = commitID
        do {
            let inserted = try await recordImporter.save(
                commitID: commitID,
                records: cachedPlan.sourceRecords,
                memberMap: cachedPlan.memberMap,
                idolNames: cachedPlan.idolNames,
                selection: selection
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
        guard !isSaving, !isPlanning else { return }
        cancelMatching()
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
    case invalidName, invalidAvatar, unresolvedMember(Int), missingIdol(Int), missingDestinationIdol, unmappedRecord
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
    var resolution: ChekiRokuCatalogueMatching.Resolution? = nil
    var catalogueSearchName: String? = nil
    private(set) var catalogueSearchRevision = UUID()

    var query: ChekiRokuCatalogueMatching.Query {
        .init(name: catalogueSearchName ?? name, group: group)
    }

    mutating func updateCatalogueSearchName(_ value: String) {
        guard catalogueSearchName != value else { return }
        catalogueSearchName = value
        invalidateCatalogueSearch()
    }

    mutating func invalidateCatalogueSearch() {
        resolution = nil
        catalogueSearchRevision = UUID()
    }

    mutating func applyCatalogueResolution(
        _ value: ChekiRokuCatalogueMatching.Resolution,
        revision: UUID
    ) {
        guard isSelected, choice == .create,
              catalogueSearchRevision == revision, value.query == query else { return }
        resolution = value
        if case .fallback = value.outcome, catalogueSearchName == nil {
            catalogueSearchName = name
        }
    }
    var hasCurrentResolution: Bool { resolution?.query == query }
    var catalogueCandidate: ChekinanaEnrichedIdol? {
        guard let resolution, resolution.query == query,
              case .matched(let candidate) = resolution.outcome else { return nil }
        return candidate
    }
}

enum ChekiRokuMemberSelectionPolicy {
    static func catalogueQueries(_ drafts: [ChekiRokuIdolDraft], memberIDs: Set<Int>? = nil) -> [ChekiRokuCatalogueMatching.Query] {
        drafts.filter {
            $0.isSelected && $0.choice == .create && !$0.hasCurrentResolution
                && (memberIDs?.contains($0.memberID) ?? true)
        }.map(\.query)
    }

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
                && $0.choice.isResolved && ($0.choice != .create || $0.hasCurrentResolution)
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
                        .frame(width: 28, height: 28)
                        .background(Color.white)
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
    let count: Int

    init(
        idolID: UUID,
        idolName: String,
        day: Date?,
        type: ChekiRokuType,
        memoRuns: [ChekiRokuRecordImportPlanner.MemoRun]
    ) {
        self.idolID = idolID
        self.idolName = idolName
        self.day = day
        self.type = type
        self.memoRuns = memoRuns
        self.count = memoRuns.reduce(0) { $0 + $1.count }
    }
}
private struct ChekiRokuRecordPlan {
 let items: [ChekiRokuPlanItem]
 let rows: [ChekiRokuRecordImportPlanner.Row]
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
    rows: [ChekiRokuRecordImportPlanner.Row] = [],
    sourceRecords: [ChekinanaChekiRokuImport.SourceRecord] = [],
    memberMap: [Int: UUID] = [:],
    idolNames: [UUID: String] = [:]
 ) {
    self.items = items
    self.rows = rows
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
    struct Existing: Sendable {
        let idolID: UUID
        let day: Date?
        let category: Int
        let count: Int

        init(idolID: UUID, day: Date?, category: Int, count: Int = 1) {
            self.idolID = idolID
            self.day = day
            self.category = category
            self.count = max(1, count)
        }
    }
    struct MemoRun: Sendable, Equatable { let memo: String; let count: Int }
    struct Item: Sendable { let idolID: UUID; let day: Date?; let category: Int; let memoRuns: [MemoRun]; var count: Int { memoRuns.reduce(0) { $0 + $1.count } } }
    struct Row: Identifiable, Sendable {
        let sourceIndex: Int
        let idolID: UUID
        let day: Date?
        let memo: String
        let count: Int
        var id: Int { sourceIndex }
    }
    struct Selection: Sendable {
        let quantities: [Int: Int]
        let ignoresNotes: Bool
    }
    private struct Key: Hashable { let idolID: UUID; let day: Date?; let category: Int }

    static func make(records: [ChekinanaChekiRokuImport.SourceRecord], memberMap: [Int: UUID], existing: [Existing]) throws -> [Item] {
        try makeItems(from: makeRows(records: records, memberMap: memberMap, existing: existing))
    }

    // Preserve each source position until live quota deduction and user authorization
    // are both complete. Identical dates and notes do not collapse selection identity.
    static func makeRows(
        records: [ChekinanaChekiRokuImport.SourceRecord],
        memberMap: [Int: UUID],
        existing: [Existing]
    ) throws -> [Row] {
        var rows: [Key: [(index: Int, record: ChekinanaChekiRokuImport.SourceRecord)]] = [:]
        for (index, record) in records.enumerated() {
            guard record.category == 1,
                  let idolID = memberMap[record.memberID],
                  record.count > 0 else { continue }
            let key = Key(idolID: idolID, day: record.date.flatMap(ChekinanaDateOnly.canonicalized), category: 1)
            rows[key, default: []].append((index, record))
        }
        var existingByKey: [Key: [Int]] = [:]
        for value in existing {
            guard value.category == 1 else { continue }
            let key = Key(idolID: value.idolID, day: value.day.flatMap(ChekinanaDateOnly.canonicalized), category: value.category)
            guard rows[key] != nil else { continue }
            existingByKey[key, default: []].append(value.count)
        }
        var result: [Row] = []
        for key in rows.keys.sorted(by: { "\($0.idolID)-\($0.day?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude)-\($0.category)" < "\($1.idolID)-\($1.day?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude)-\($1.category)" }) {
            let quotas = existingByKey[key] ?? []
            var quotaIndex = 0
            var availableQuota = 0
            for entry in rows[key] ?? [] {
                var remaining = entry.record.count
                while remaining > 0 {
                    if availableQuota == 0 {
                        guard quotaIndex < quotas.count else { break }
                        availableQuota = quotas[quotaIndex]
                        quotaIndex += 1
                    }
                    let skipped = min(availableQuota, remaining)
                    availableQuota -= skipped
                    remaining -= skipped
                }
                guard remaining > 0 else { continue }
                result.append(Row(sourceIndex: entry.index, idolID: key.idolID,
                                  day: key.day, memo: entry.record.memo, count: remaining))
            }
        }
        _ = try result.reduce(0) { try ChekinanaChekiRecordStore.checkedCountSum($0, $1.count) }
        return result
    }

    static func makeItems(from rows: [Row], selection: Selection? = nil) throws -> [Item] {
        var runsByKey: [Key: [MemoRun]] = [:]
        var orderedKeys: [Key] = []
        for row in rows {
            let count = selection.map { min(row.count, max(0, $0.quantities[row.sourceIndex] ?? 0)) } ?? row.count
            guard count > 0 else { continue }
            let key = Key(idolID: row.idolID, day: row.day, category: 1)
            if runsByKey[key] == nil { orderedKeys.append(key) }
            let memo = selection?.ignoresNotes == true ? "" : row.memo
            var runs = runsByKey[key] ?? []
            if let last = runs.last, last.memo == memo {
                runs[runs.count - 1] = MemoRun(memo: memo, count: try ChekinanaChekiRecordStore.checkedCountSum(last.count, count))
            } else {
                runs.append(MemoRun(memo: memo, count: count))
            }
            runsByKey[key] = runs
        }
        let items = orderedKeys.map { Item(idolID: $0.idolID, day: $0.day, category: 1, memoRuns: runsByKey[$0] ?? []) }
        _ = try items.reduce(0) { try ChekinanaChekiRecordStore.checkedCountSum($0, $1.count) }
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

    func planRows(
        records: [ChekinanaChekiRokuImport.SourceRecord],
        memberMap: [Int: UUID]
    ) throws -> [ChekiRokuRecordImportPlanner.Row] {
        try ChekiRokuRecordImportPlanner.makeRows(records: records, memberMap: memberMap, existing: liveExistingRecords())
    }

    private func liveExistingRecords() throws -> [ChekiRokuRecordImportPlanner.Existing] {
        let chekis = try modelContext.fetch(FetchDescriptor<MediaItem>()).filter {
            $0.kind == .cheki
        }
        let mediaRecords = chekis.compactMap { value -> ChekiRokuRecordImportPlanner.Existing? in
            guard value.idolIDs.count == 1,
                  let idolID = value.idolIDs.first else { return nil }
            return .init(idolID: idolID, day: value.date, category: 1)
        }
        let simpleRecords = try modelContext.fetch(FetchDescriptor<ChekiRecord>())
            .compactMap { value -> ChekiRokuRecordImportPlanner.Existing? in
                guard let idolID = ChekinanaChekiRecordReadPolicy.singleIdolID(
                    value
                ) else { return nil }
                return .init(
                    idolID: idolID,
                    day: value.date,
                    category: 1,
                    count: value.count
                )
            }
        return mediaRecords + simpleRecords
    }

    func save(
        commitID: UUID = UUID(),
        records: [ChekinanaChekiRokuImport.SourceRecord],
        memberMap: [Int: UUID],
        idolNames: [UUID: String],
        selection: ChekiRokuRecordImportPlanner.Selection? = nil,
        beforePersistForTesting: (@Sendable () -> Void)? = nil,
        progress: @escaping ProgressHandler
    ) throws -> Int {
        guard activeCommitID == nil else {
            throw ChekiRokuImportUIError.commitInProgress
        }
        activeCommitID = commitID
        defer { activeCommitID = nil }
        if selection?.quantities.isEmpty == true { return 0 }
        return try ChekinanaChekiRecordStore.withMutationLock {
            modelContext.autosaveEnabled = false
            do {
        // Keep original source indexes even when non-Cheki rows are interleaved.
        let liveRows = try ChekiRokuRecordImportPlanner.makeRows(
            records: records, memberMap: memberMap, existing: liveExistingRecords()
        )
        let liveItems = try ChekiRokuRecordImportPlanner.makeItems(from: liveRows, selection: selection)
        if selection != nil && liveItems.isEmpty { return 0 }
        let requiredIDs = selection == nil
            ? Set(records.filter { $0.category == 1 }.compactMap { memberMap[$0.memberID] })
            : Set(liveItems.map(\.idolID))
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
        let existingSimpleRecords = try modelContext.fetch(
            FetchDescriptor<ChekiRecord>()
        ).sorted { $0.id.uuidString < $1.id.uuidString }
        let selectedIdentities: Set<ChekinanaChekiRecordIdentity>? = selection.map { _ in
            Set(liveItems.flatMap { item in
                let eventID = ChekinanaChekiEventAutoAssociation.uniqueEventID(
                    for: item.day, events: fetchedEvents.map { ($0.id, $0.date) }
                )
                return item.memoRuns.map { run in
                    ChekinanaChekiRecordIdentity(idolIDs: [item.idolID], date: item.day,
                        eventID: eventID, sizeRawValue: ChekiSize.mini.rawValue, note: run.memo)
                }
            })
        }
        var recordsByIdentity: [ChekinanaChekiRecordIdentity: ChekiRecord] = [:]
        for record in existingSimpleRecords {
            let identity = ChekinanaChekiRecordIdentity(record)
            if let selectedIdentities, !selectedIdentities.contains(identity) { continue }
            record.date = identity.canonicalDate
            if let retained = recordsByIdentity[identity] {
                retained.count = try ChekinanaChekiRecordStore.checkedCountSum(
                    retained.count,
                    max(1, record.count)
                )
                modelContext.delete(record)
            } else {
                record.count = max(1, record.count)
                recordsByIdentity[identity] = record
            }
        }

        guard liveItems.allSatisfy({ idolNames[$0.idolID] != nil }) else {
            throw ChekiRokuImportUIError.unmappedRecord
        }
        let items = liveItems.map { item in
            ChekiRokuPlanItem(
                idolID: item.idolID,
                idolName: idolNames[item.idolID]!,
                day: item.day,
                type: .cheki,
                memoRuns: item.memoRuns
            )
        }
        let total = try items.reduce(0) { partialResult, item in
            try ChekinanaChekiRecordStore.checkedCountSum(
                partialResult,
                item.count
            )
        }

        var inserted = 0
        var lastPublished = -64
        var publishedIdolID: UUID?
        var eventPropagationSources: [UUID: ChekiRecord] = [:]
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

                for run in item.memoRuns {
                    try Task.checkCancellation()
                    let event = ChekinanaChekiEventAutoAssociation.uniqueEventID(
                        for: item.day,
                        events: fetchedEvents.map { ($0.id, $0.date) }
                    ).flatMap { eventsByID[$0] }
                    let identity = ChekinanaChekiRecordIdentity(
                        idolIDs: [idol.id],
                        date: item.day,
                        eventID: event?.id,
                        sizeRawValue: ChekiSize.mini.rawValue,
                        note: run.memo
                    )
                    if let record = recordsByIdentity[identity] {
                        record.count = try ChekinanaChekiRecordStore.checkedCountSum(
                            record.count,
                            run.count
                        )
                        if record.eventID != nil {
                            eventPropagationSources[record.id] = record
                        }
                    } else {
                        let record = ChekiRecord(
                            idols: [idol],
                            event: event,
                            date: item.day,
                            size: .mini,
                            note: run.memo,
                            count: run.count
                        )
                        modelContext.insert(record)
                        recordsByIdentity[identity] = record
                        if record.eventID != nil {
                            eventPropagationSources[record.id] = record
                        }
                    }
                    inserted = try ChekinanaChekiRecordStore.checkedCountSum(
                        inserted,
                        run.count
                    )
                    if inserted - lastPublished >= 64 {
                        publishProgress(
                            .init(commitID: commitID, completed: inserted, total: total, idolName: item.idolName),
                            to: progress
                        )
                        lastPublished = inserted
                    }
                }
            }
            for source in eventPropagationSources.values {
                try ChekinanaEventAssociationPropagation.propagate(
                    from: source,
                    in: modelContext
                )
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

/// A full-page, local-only import entry. The selected Files document is copied
/// into app-owned temporary storage before the existing archive parser runs.
struct ChekinanaChekiRokuClipboardImportView: View {
    let onClose: () -> Void
    @State private var archive: ChekinanaChekiRokuImport.Archive?
    @State private var stage = ""
    @State private var error: String?
    @State private var isReading = false
    @State private var wizardBusy = false
    @State private var readGeneration = 0
    @State private var readTask: Task<Void, Never>?
    @State private var isFileImporterPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if let archive {
                    ChekinanaChekiRokuImportWizard(archive: archive, onClose: {
                        ChekinanaChekiRokuImport.cleanup(archive)
                        self.archive = nil
                    }, isExternallyBusy: $wizardBusy)
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            VStack(spacing: 18) {
                                Image(systemName: "square.and.arrow.down.on.square")
                                    .font(.system(size: 34, weight: .medium))
                                    .foregroundStyle(ChekinanaDesignSystem.accent)
                                    .frame(width: 64, height: 64)
                                    .background(ChekinanaDesignSystem.softAccent)
                                    .clipShape(Circle())

                                Text(ChekinanaL10n.text(
                                    "import.export_steps",
                                    fallback: "ChekiRoku → Settings → Backup & Restore → Local Backup → Save to Files"
                                ))
                                    .font(.body)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)

                                Button {
                                    error = nil
                                    isFileImporterPresented = true
                                } label: {
                                    Label(
                                        ChekinanaL10n.text(
                                            "import.action.read",
                                            fallback: "Open File Browser"
                                        ),
                                        systemImage: "folder"
                                    )
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isReading)
                                .accessibilityIdentifier("chekinana.import.read")
                            }
                            .padding(22)
                            .background(ChekinanaDesignSystem.cardBackground)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: ChekinanaDesignSystem.cardRadius,
                                    style: .continuous
                                )
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: ChekinanaDesignSystem.cardRadius,
                                    style: .continuous
                                )
                                .stroke(ChekinanaDesignSystem.border, lineWidth: 0.5)
                            }

                            if !stage.isEmpty {
                                ProgressView(stage)
                                    .padding(.top, 4)
                            }
                            if let error {
                                Text(error)
                                    .font(.footnote)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 24)
                            }
                        }
                        .padding(16)
                    }
                    .background(ChekinanaDesignSystem.pageBackground)
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ChekinanaChekiRokuNavigationTitle()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChekinanaL10n.text("action.cancel", fallback: "Cancel")) { close() }
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
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item]
        ) { result in
            switch result {
            case .success(let selectedURL):
                readSelectedFile(selectedURL)
            case .failure(let selectionError):
                guard !Self.isUserCancellation(selectionError) else { return }
                error = selectionError.localizedDescription
            }
        }
        .onAppear { installUITestFixtureIfRequested() }
        .onDisappear { readGeneration += 1; readTask?.cancel(); if let archive, !wizardBusy { ChekinanaChekiRokuImport.cleanup(archive) } }
    }

    private func readSelectedFile(_ selectedURL: URL) {
        guard !isReading else { return }
        isReading = true; error = nil; stage = ChekinanaL10n.text("import.stage.reading", fallback: "Reading selected file"); readGeneration += 1
        let generation = readGeneration
        readTask = Task { @MainActor in
            do {
                let temporaryURL = try await Task.detached(priority: .userInitiated) {
                    try ChekinanaChekiRokuSelectedFileReader.copyToTemporaryStorage(selectedURL)
                }.value
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard !Task.isCancelled, generation == readGeneration else { return }
                stage = ChekinanaL10n.text("import.stage.parsing", fallback: "Parsing archive")
                let parsed = try await ChekinanaChekiRokuImport.readDetached(temporaryURL)
                guard !Task.isCancelled, generation == readGeneration else {
                    ChekinanaChekiRokuImport.cleanup(parsed)
                    return
                }
                stage = ChekinanaL10n.text("import.stage.matching", fallback: "Matching Idols")
                await Task.yield()
                guard ChekinanaChekiRokuImportPublicationPolicy.shouldPublish(
                    isCancelled: Task.isCancelled,
                    generation: generation,
                    currentGeneration: readGeneration
                ) else {
                    ChekinanaChekiRokuImport.cleanup(parsed)
                    return
                }
                archive = parsed
                stage = ""
            } catch {
                stage = ""
                if !Self.isUserCancellation(error), generation == readGeneration {
                    self.error = error.localizedDescription
                }
            }
            if generation == readGeneration { isReading = false; readTask = nil }
        }
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
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

private struct ChekinanaChekiRokuNavigationTitle: View {
    var body: some View {
        Text(ChekinanaL10n.text("import.title", fallback: "Import from ChekiRoku"))
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .allowsTightening(true)
            .accessibilityIdentifier("chekinana.import.navigation-title")
    }
}

enum ChekinanaChekiRokuImportPublicationPolicy {
    static func shouldPublish(
        isCancelled: Bool,
        generation: Int,
        currentGeneration: Int
    ) -> Bool {
        !isCancelled && generation == currentGeneration
    }
}

enum ChekinanaChekiRokuSelectedFileReader {
    static let maximumArchiveSize = 32 * 1_024 * 1_024

    static func copyToTemporaryStorage(_ source: URL) throws -> URL {
        guard source.pathExtension.caseInsensitiveCompare("chekiroku") == .orderedSame else {
            throw ChekinanaChekiRokuSelectedFileError.invalidFile
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 2,
              fileSize <= maximumArchiveSize else {
            throw ChekinanaChekiRokuSelectedFileError.invalidFile
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekinanaChekiRokuFileImport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("chekiroku")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 2) ?? Data()
            guard prefix.elementsEqual([0x50, 0x4B]) else {
                throw ChekinanaChekiRokuSelectedFileError.notZIP
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

enum ChekinanaChekiRokuSelectedFileError: LocalizedError, Equatable {
    case invalidFile, notZIP

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return ChekinanaL10n.text("import.error.file", fallback: "Import file is too large or invalid.")
        case .notZIP:
            return ChekinanaL10n.text("import.error.not_zip", fallback: "The selected file is not a valid ZIP-based ChekiRoku backup.")
        }
    }
}

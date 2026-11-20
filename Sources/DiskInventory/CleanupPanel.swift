import AppKit
import InventoryCore
import SwiftUI

@MainActor @Observable final class CleanupModel {
    typealias Apply = @MainActor (_ removed: [URL], _ refreshed: [URL]) async -> ScanSummary?

    struct TrashPlan {
        let revision: UUID
        let items: [CleanupSelection.Item]
        let targets: [AdviceTrash.Target]
        let missing: [String]

        var size: Int64 { items.reduce(0) { $0 + $1.size } }
    }

    private(set) var snapshot: ScanSummary
    private let apply: Apply
    var scanIsIdle: () -> Bool = { true }
    var reveal: ((String) -> Void)?
    var quickLook: ((String) -> Void)?
    var candidatesChanged: (() -> Void)?
    var scanHome: (() -> Void)?
    private(set) var advice: AdviceSheet?
    private(set) var groups: [CleanupGroup] = []
    private(set) var stale: [StaleFile] = []
    private(set) var analyzing = false
    private(set) var analyzed = false
    private(set) var working: String?
    private(set) var failures: [String] = []
    var showingFailures = false
    var adviceSelected: Set<UUID> = []
    var selected: Set<Int> = []
    var staleSelected: Set<Int> = []
    var days = 180
    var minimum: Int64 = 100 << 20
    var sortStaleByDate = false
    let destinations = CloudOffload.destinations()
    var destination: CloudDestination?
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    private var revision = UUID()
    private var staleRevision = UUID()
    private var analysis: Task<Void, Never>?
    private(set) var selection = CleanupSelection(kept: [])

    init(snapshot: ScanSummary, apply: @escaping Apply) {
        self.snapshot = snapshot
        self.apply = apply
        destination = destinations.first
        reloadAdvice()
    }

    var coversHome: Bool {
        snapshot.locate(home) != nil || snapshot.displayPath(of: 0).hasPrefix(home + "/")
    }

    var pendingAdvice: [AdviceItem] { advice?.items.filter(\.isRemovable) ?? [] }
    var removable: [CleanupItem] { groups.filter { $0.category != CleanupCategories.trash }.flatMap(\.items) }
    var chosen: [CleanupSelection.Item] {
        let advice = pendingAdvice.filter { adviceSelected.contains($0.id) }.map {
            CleanupSelection.Item(path: canonicalPath($0.path), size: $0.size)
        }
        let rules = removable.filter { selected.contains($0.node) }.map {
            CleanupSelection.Item(path: path(of: $0.node), size: $0.size)
        }
        return selection.collapse(rules + advice)
    }
    var canWork: Bool { !analyzing && working == nil && scanIsIdle() }
    var chosenLocal: [StaleFile] { stale.filter { staleSelected.contains($0.node) && !$0.isInICloud && !selection.protects($0.path) } }
    var chosenInICloud: [StaleFile] { stale.filter { staleSelected.contains($0.node) && $0.isInICloud && !selection.protects($0.path) } }
    var sortedStale: [StaleFile] {
        sortStaleByDate ? stale.sorted { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) } : stale
    }

    var candidateIDs: Set<Int> {
        var ids = Set(removable.lazy.filter { !self.selection.protects(self.path(of: $0.node)) }.map(\.node))
        for item in pendingAdvice where !selection.protects(canonicalPath(item.path)) {
            if let id = snapshot.locate(item.path) { ids.insert(id) }
        }
        return ids
    }

    func total(_ safety: CleanupSafety) -> Int64 {
        groups.filter { $0.category.safety == safety }.reduce(0) { $0 + $1.size }
    }

    func display(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    func path(of node: Int) -> String { snapshot.displayPath(of: node) }

    func canonicalPath(_ path: String) -> String {
        let path = AdviceGuard.normalize(path)
        return snapshot.locate(path).map { self.path(of: $0) } ?? path
    }

    func update(snapshot: ScanSummary) {
        analysis?.cancel()
        self.snapshot = snapshot
        revision = UUID()
        groups = []
        stale = []
        selected = []
        staleSelected = []
        analyzing = true
        analyzed = false
        refreshProtection()
        candidatesChanged?()
        analysis = Task { await analyze() }
    }

    func reloadAdvice() {
        let previous = Set(pendingAdvice.map(\.id))
        advice = AdviceStore.load()
        let pending = Set(pendingAdvice.map(\.id))
        adviceSelected.formIntersection(pending)
        for item in pendingAdvice where item.verdict == .safe && !previous.contains(item.id) { adviceSelected.insert(item.id) }
        refreshProtection()
        candidatesChanged?()
    }

    private func refreshProtection() {
        let kept = advice?.items.filter { !$0.isAction && !$0.path.isEmpty && ($0.status == .kept || $0.verdict == .keep) } ?? []
        selection = CleanupSelection(kept: Set(kept.map { canonicalPath($0.path) }))
    }

    func analyze() async {
        guard !Task.isCancelled else { return }
        analyzing = true
        let snapshot = snapshot
        let revision = revision
        async let refreshStale: Void = findStale()
        let groups = await Task.detached(priority: .userInitiated) { CleanupAnalyzer.analyze(snapshot) }.value
        await refreshStale
        guard revision == self.revision, !Task.isCancelled else { return }
        self.groups = groups
        selected = Set(self.groups.filter { $0.category.safety == .safe && $0.category != CleanupCategories.trash }
            .flatMap { $0.items.lazy.filter { !self.selection.protects(self.path(of: $0.node)) }.map(\.node) })
        analyzing = false
        analyzed = true
        reloadAdvice()
    }

    func findStale() async {
        guard !Task.isCancelled else { return }
        let revision = revision
        let request = UUID()
        staleRevision = request
        let snapshot = snapshot
        let days = Double(days)
        let minimum = minimum
        let files = await Task.detached(priority: .userInitiated) {
            CloudOffload.staleFiles(in: snapshot, minSize: minimum, olderThanDays: days)
        }.value
        guard revision == self.revision, request == staleRevision, !Task.isCancelled else { return }
        stale = files
        staleSelected = []
    }

    func keep(_ item: AdviceItem) {
        do {
            try AdviceStore.mark([item.id], as: .kept)
            reloadAdvice()
        } catch {
            failures = [error.localizedDescription]
        }
    }

    func prepareTrash(_ items: [CleanupSelection.Item]) -> TrashPlan {
        var targets: [AdviceTrash.Target] = []
        var missing: [String] = []
        for item in items {
            if let id = snapshot.locate(item.path) {
                targets.append(AdviceTrash.Target(url: snapshot.url(for: id), node: snapshot.nodes[id]))
            } else if let target = AdviceTrash.Target(url: URL(filePath: item.path)) {
                targets.append(target)
            } else {
                missing.append("\(item.path): This item is no longer on disk.")
            }
        }
        return TrashPlan(revision: revision, items: items, targets: targets, missing: missing)
    }

    func trashChosen(_ plan: TrashPlan) async {
        reloadAdvice()
        guard canWork, revision == plan.revision, chosen == plan.items else { return }
        let advised = pendingAdvice.map { ($0.id, canonicalPath($0.path)) }
        working = "Moving \(plan.targets.count) items to the Trash…"
        let outcome = await Task.detached(priority: .userInitiated) { AdviceTrash.move(plan.targets) }.value
        let trashed = outcome.done.map { AdviceGuard.normalize($0.source.path) }
        try? AdviceStore.mark(Set(advised.filter { _, path in
            trashed.contains { CleanupSelection.contains($0, path) }
        }.map(\.0)), as: .trashed)
        let refreshed = outcome.done.map { $0.destination?.deletingLastPathComponent() ?? snapshot.root }
        await finish(removed: outcome.done.map(\.source), refreshed: refreshed, errors: plan.missing + outcome.errors)
    }

    func run(_ item: AdviceItem) async {
        guard canWork, let action = item.action,
              advice?.items.contains(where: { $0.id == item.id && $0.isRunnable }) == true else { return }
        working = "Running \(item.title)…"
        let argument = item.argument
        let result = await Task.detached(priority: .userInitiated) { AdviceActions.perform(action, argument: argument) }.value
        try? AdviceStore.mark([item.id], as: result.ok ? .done : .failed, output: result.output)
        let affected = action == "empty-trash" ? home + "/.Trash" : item.path
        await finish(removed: [], refreshed: affected.isEmpty ? [] : [URL(filePath: affected)], errors: [])
    }

    func moveChosen() async {
        guard canWork, let destination else { return }
        let urls = chosenLocal.map { URL(filePath: $0.path) }
        working = "Moving \(urls.count) files to \(destination.title)…"
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([URL], [String]) in
            var done: [URL] = []
            var errors: [String] = []
            for url in urls {
                do {
                    try CloudOffload.move(url, to: destination)
                    done.append(url)
                } catch {
                    errors.append("\(url.path): \(error.localizedDescription)")
                }
            }
            return (done, errors)
        }.value
        let refreshed = snapshot.locate(destination.root.path) == nil ? [] : [destination.root]
        await finish(removed: outcome.0, refreshed: refreshed, errors: outcome.1)
    }

    func removeDownloads() async {
        guard canWork else { return }
        let urls = chosenInICloud.map { URL(filePath: $0.path) }
        working = "Removing \(urls.count) downloads…"
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([URL], [String]) in
            var done: [URL] = []
            var errors: [String] = []
            for url in urls {
                do {
                    try CloudOffload.removeLocalCopy(url)
                    done.append(url)
                } catch {
                    errors.append("\(url.path): \(error.localizedDescription)")
                }
            }
            return (done, errors)
        }.value
        await finish(removed: [], refreshed: outcome.0, errors: outcome.1)
    }

    private func finish(removed: [URL], refreshed: [URL], errors: [String]) async {
        working = "Updating the scan…"
        if let updated = await apply(removed, refreshed) { update(snapshot: updated) }
        working = nil
        failures = errors
        reloadAdvice()
    }
}

private struct VerdictLabel: View {
    let verdict: AdviceVerdict

    var body: some View {
        switch verdict {
        case .safe: Label("Safe to remove", systemImage: "checkmark.shield")
        case .regenerable: Label("Rebuilt on demand", systemImage: "arrow.triangle.2.circlepath")
        case .review: Label("Worth a look", systemImage: "eye")
        case .keep: Label("Keep", systemImage: "lock")
        }
    }
}

struct CleanupPanel: View {
    @Bindable var model: CleanupModel
    @State private var focus: String?
    @State private var trashPlan: CleanupModel.TrashPlan?
    @State private var confirmMove = false
    @State private var confirmRun: AdviceItem?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $focus) {
                adviceSection
                if !model.coversHome {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Clean-up rules look in your home folder, which isn’t part of this scan.")
                                .foregroundStyle(.secondary)
                            Button("Scan Home Folder") { model.scanHome?() }
                        }
                        .padding(.vertical, 4)
                    }
                }
                ForEach(CleanupSafety.allCases, id: \.self) { safety in
                    let groups = model.groups.filter { $0.category.safety == safety }
                    if !groups.isEmpty {
                        Section {
                            ForEach(groups, id: \.category.id) { group in
                                CategoryRow(model: model, group: group)
                            }
                        } header: {
                            HStack {
                                Text(safety.title)
                                Spacer()
                                Text(formatSize(model.total(safety))).monospacedDigit()
                            }
                        }
                    }
                }
                if model.coversHome { staleSection }
            }
            .listStyle(.inset)
            .onChange(of: focus) { _, path in if let path { model.reveal?(path) } }
            .onKeyPress(.space) {
                guard let focus else { return .ignored }
                model.quickLook?(focus)
                return .handled
            }
            .overlay {
                if model.analyzing && !model.analyzed { ProgressView("Looking for things to clean up") }
            }
            Divider()
            footer.padding(12)
        }
        .confirmationDialog("Move \(trashPlan?.items.count ?? 0) items to the Trash?",
                            isPresented: Binding { trashPlan != nil } set: { if !$0 { trashPlan = nil } },
                            presenting: trashPlan) { plan in
            Button("Move to Trash", role: .destructive) { Task { await model.trashChosen(plan) } }
        } message: { plan in
            Text("Estimated space after emptying the Trash: \(formatSize(plan.size)). Items in the Trash can be put back.")
        }
        .confirmationDialog("Move \(model.chosenLocal.count) files to \(model.destination?.title ?? "the cloud")?", isPresented: $confirmMove) {
            Button("Move") { Task { await model.moveChosen() } }
        } message: {
            Text("They go to “\(CloudOffload.archiveFolder)” and keep their folder structure. The space comes back after they finish uploading and you remove the local copies.")
        }
        .confirmationDialog(confirmRun?.title ?? "", isPresented: Binding { confirmRun != nil } set: { if !$0 { confirmRun = nil } },
                            presenting: confirmRun) { item in
            Button(item.action == "empty-trash" ? "Empty Trash" : "Run", role: .destructive) { Task { await model.run(item) } }
        } message: { item in
            let definition = item.action.flatMap(AdviceActions.definition)
            Text([definition?.explanation, definition?.commandLine(item.argument), item.size > 0 ? "Frees about \(formatSize(item.size))." : nil]
                .compactMap { $0 }.joined(separator: "\n\n"))
        }
        .sheet(isPresented: $model.showingFailures) { failureSheet }
    }

    @ViewBuilder private var adviceSection: some View {
        if let advice = model.advice {
            Section {
                if !advice.summary.isEmpty {
                    Text(advice.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                }
                ForEach(advice.items.filter { $0.status == .pending } + advice.items.filter { $0.status != .pending }) { item in
                    AdviceRow(model: model, item: item) { confirmRun = $0 }.tag(item.path.isEmpty ? nil : item.path)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(advice.title)
                    Text("From \(advice.author) · \(advice.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            Section("Claude’s Analysis") {
                Text("Ask Claude what fills the disk. Its findings appear here with a reason for each item, and nothing is removed until you confirm.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
        }
    }

    private var staleSection: some View {
        Section {
            HStack {
                Picker("Unopened for", selection: $model.days) {
                    Text("3 months").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                    Text("2 years").tag(730)
                }
                Picker("Larger than", selection: $model.minimum) {
                    Text("50 MB").tag(Int64(50 << 20))
                    Text("100 MB").tag(Int64(100 << 20))
                    Text("500 MB").tag(Int64(500 << 20))
                    Text("1 GB").tag(Int64(1 << 30))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            if model.stale.isEmpty {
                Text("Nothing this large went unopened that long in Desktop, Documents, Downloads, Movies, Music, Pictures or iCloud Drive.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.sortedStale, id: \.node) { file in
                StaleRow(model: model, file: file).tag(file.path)
            }
            if !model.chosenLocal.isEmpty || !model.chosenInICloud.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.chosenLocal.isEmpty, !model.destinations.isEmpty {
                        Picker("Move to", selection: $model.destination) {
                            ForEach(model.destinations, id: \.self) { Text($0.title).tag(Optional($0)) }
                        }
                        .controlSize(.small)
                        Button("Move \(model.chosenLocal.count) to \(model.destination?.title ?? "Cloud")…") { confirmMove = true }
                            .disabled(model.working != nil)
                    }
                    if !model.chosenInICloud.isEmpty {
                        Button("Remove \(model.chosenInICloud.count) Downloads") { Task { await model.removeDownloads() } }
                            .disabled(model.working != nil)
                        Text("The files stay in iCloud Drive and download again when opened.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text("Not Opened Lately")
                Spacer()
                Menu {
                    Picker("Sort", selection: $model.sortStaleByDate) {
                        Text("By Size").tag(false)
                        Text("Oldest First").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort")
            }
        }
        .onChange(of: model.days) { Task { await model.findStale() } }
        .onChange(of: model.minimum) { Task { await model.findStale() } }
    }

    @ViewBuilder private var footer: some View {
        let chosen = model.chosen
        VStack(alignment: .leading, spacing: 8) {
            if let working = model.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working).foregroundStyle(.secondary)
                }
            } else if !model.failures.isEmpty {
                HStack {
                    Label("\(model.failures.count) items couldn’t be moved", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Details…") { model.showingFailures = true }.controlSize(.small)
                }
            }
            HStack {
                Text("\(chosen.count) selected · \(formatSize(chosen.reduce(0) { $0 + $1.size }))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Move to Trash…", role: .destructive) { trashPlan = model.prepareTrash(chosen) }
                    .disabled(chosen.isEmpty || !model.canWork)
            }
        }
    }

    private var failureSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.failures.count) items couldn’t be moved").font(.headline)
            List(model.failures, id: \.self) { line in
                Text(line).font(.callout).textSelection(.enabled)
            }
            .frame(minWidth: 460, minHeight: 220)
            HStack {
                Spacer()
                Button("Done") { model.showingFailures = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

private struct ItemMenu: View {
    let model: CleanupModel
    let path: String

    var body: some View {
        Button("Open") { NSWorkspace.shared.open(URL(filePath: path)) }
        Button("Quick Look") { model.quickLook?(path) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
        Button("Show in Map") { model.reveal?(path) }
    }
}

private struct AdviceRow: View {
    @Bindable var model: CleanupModel
    let item: AdviceItem
    let run: (AdviceItem) -> Void

    private var location: String {
        if item.path.isEmpty { return item.action.flatMap { AdviceActions.definition($0)?.commandLine(item.argument) } ?? "" }
        return model.display(item.isAction ? item.path : URL(filePath: item.path).deletingLastPathComponent().path)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if item.isAction {
                Image(systemName: item.status == .done ? "checkmark" : item.status == .failed ? "exclamationmark.triangle" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            } else if item.status == .pending && item.verdict != .keep {
                let protected = model.selection.protects(model.canonicalPath(item.path))
                Toggle(model.display(item.path), isOn: Binding {
                    !protected && model.adviceSelected.contains(item.id)
                } set: { on in
                    if on { model.adviceSelected.insert(item.id) } else { model.adviceSelected.remove(item.id) }
                })
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(protected)
            } else {
                Image(systemName: item.verdict == .keep ? "lock" : "checkmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .strikethrough(item.status == .trashed || item.status == .missing || item.status == .done)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                VerdictLabel(verdict: item.verdict)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !item.reason.isEmpty {
                    Text(item.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch item.status {
                case .trashed: Text("Moved to the Trash").font(.caption).foregroundStyle(.tertiary)
                case .kept: Text("You kept this").font(.caption).foregroundStyle(.tertiary)
                case .missing: Text("No longer on disk").font(.caption).foregroundStyle(.tertiary)
                case .done: Text("Done").font(.caption).foregroundStyle(.tertiary)
                case .failed:
                    Text(item.output.map { String($0.suffix(600)) } ?? "Failed")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                case .pending:
                    if item.isRunnable {
                        Button(item.action == "empty-trash" ? "Empty Trash…" : "Run…") { run(item) }
                            .controlSize(.small)
                            .disabled(!model.canWork)
                            .padding(.top, 2)
                    }
                }
            }
            Spacer(minLength: 4)
            Text(formatSize(item.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contextMenu {
            if !item.path.isEmpty { ItemMenu(model: model, path: item.path) }
            if item.status == .pending, item.verdict != .keep {
                Divider()
                Button("Keep") { model.keep(item) }
            }
        }
    }
}

private struct CategoryRow: View {
    @Bindable var model: CleanupModel
    let group: CleanupGroup
    @State private var showAll = false

    private var isTrash: Bool { group.category == CleanupCategories.trash }

    private var allSelected: Binding<Bool> {
        let eligible = group.items.lazy.map(\.node).filter { !model.selection.protects(model.path(of: $0)) }
        return Binding {
            !eligible.isEmpty && eligible.allSatisfy(model.selected.contains)
        } set: { on in
            if on { model.selected.formUnion(eligible) } else { model.selected.subtract(eligible) }
        }
    }

    var body: some View {
        DisclosureGroup {
            ForEach(group.items.prefix(showAll ? group.items.count : 300), id: \.node) { item in
                let path = model.path(of: item.node)
                let protected = model.selection.protects(path)
                HStack {
                    if !isTrash {
                        Toggle(model.display(path), isOn: Binding {
                            !protected && model.selected.contains(item.node)
                        } set: { on in
                            if on { model.selected.insert(item.node) } else { model.selected.remove(item.node) }
                        })
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(protected)
                    }
                    Text(model.display(path)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(formatSize(item.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .tag(path)
                .contextMenu { ItemMenu(model: model, path: path) }
            }
            if !showAll, group.items.count > 300 {
                Button("Show all \(group.items.count.formatted()) items") { showAll = true }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isTrash {
                    Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 14)
                } else {
                    Toggle(group.category.title, isOn: allSelected).toggleStyle(.checkbox).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.category.title)
                    Text(isTrash ? "Empty the Trash in Finder to get this space back" : group.category.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(formatSize(group.size)).monospacedDigit()
            }
            .padding(.vertical, 2)
        }
    }
}

private struct StaleRow: View {
    @Bindable var model: CleanupModel
    let file: StaleFile

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(file.path, isOn: Binding {
                model.staleSelected.contains(file.node)
            } set: { on in
                if on { model.staleSelected.insert(file.node) } else { model.staleSelected.remove(file.node) }
            })
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(URL(filePath: file.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    if file.isInICloud {
                        Image(systemName: "icloud").foregroundStyle(.secondary).help("In iCloud Drive")
                    }
                }
                Text(model.display(URL(filePath: file.path).deletingLastPathComponent().path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let activity = file.lastActivity {
                    Text("\(file.lastUsed == nil ? "Modified" : "Opened") \(activity.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(formatSize(file.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contextMenu { ItemMenu(model: model, path: file.path) }
    }
}

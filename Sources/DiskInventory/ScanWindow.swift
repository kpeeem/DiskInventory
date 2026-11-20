import AppKit
import Darwin
import InventoryCore
import Quartz
import SwiftUI

@MainActor func formatSize(_ size: Int64) -> String {
    size.formatted(.byteCount(style: .file, spellsOutZero: false, includesActualByteCount: false))
}

@MainActor final class ScanWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation, @preconcurrency QLPreviewPanelDataSource {
    private struct ScanResult: Sendable {
        let snapshot: ScanSummary
        let zoom: Int
        let stack: [Int]
        let selected: Int?
    }

    private let location: URL
    private(set) var snapshot: ScanSummary?
    private var options = Settings.options
    private var ignoreCreator = Settings.bool("ignoreCreator", default: true)
    private var zoom = 0
    private var stack: [Int] = []
    private var selected: Int?
    private var whileScanning: Task<Void, Never>?
    private var scanWorker: Task<ScanResult, Error>?
    private var mapWorker: Task<[MapTile], Error>?
    private var mapUpdate: Task<Void, Never>?
    private var totalsWorker: Task<[KindTotal], Error>?
    private var totalsUpdate: Task<Void, Never>?
    private var searchWorker: Task<[Int], Error>?
    private var searchUpdate: Task<Void, Never>?
    private var generation = UUID()
    private let documentColors = KindColors()
    private var palette = Settings.treemapPalette
    private var shareColors = Settings.bool("shareColors", default: true)
    private var totals: [KindTotal]?
    private var colors: [NSColor] = []
    private let files = FileOutline()
    private let map = TreemapView(frame: .zero)
    private let details = Details()
    private let panes = InventorySplitViewController()
    private let fileAndMap = InventorySplitViewController()
    private var didSetUpDividers = false
    private var detailPane: NSSplitViewItem!
    private let pathControl = NSPathControl()
    private let info = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let meter = NSProgressIndicator()
    private var expectedBytes: Int64?
    private var stallTimer: Timer?
    private var lastProgress = (entries: 0, at: ContinuousClock.now, path: "")
    private var accessPromptShown = false
    private var pathIDs: [Int] = []
    private var infoPanel: InfoPanelController?
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let issues = NSButton(title: "Scan Issues", target: nil, action: nil)
    private var rescanningSelection: URL?
    private var isTrashing = false
    private var cleanupModel: CleanupModel?
    private var cleanupNeedsUpdate = false
    private var previewOverride: URL?
    private var placeholderAction: (() -> Void)?
    private var displayName: String {
        location.path == "/System/Volumes/Data" ? Self.bootVolumeName : location.lastPathComponent
    }
    static let bootVolumeName = (try? URL(filePath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    private var deferredSettings = false
    private var closed = false
    var onClose: ((ScanWindow) -> Void)?
    var canShowScan: Bool { scanWorker != nil || snapshot != nil }
    var testReady: Bool { scanWorker == nil && snapshot != nil && map.hasTiles }

    func exerciseWorkflow() async -> Bool {
        func fail(_ stage: String) -> Bool {
            print("Workflow check failed at \(stage).")
            return false
        }

        guard let snapshot else { return fail("scan") }
        let pair = snapshot.children(of: 0).lazy.compactMap { folder -> (Int, Int)? in
            guard snapshot.isExpandable(folder, options: self.options),
                  let file = snapshot.children(of: folder).first(where: { !snapshot.nodes[$0].isDirectory }) else {
                return nil
            }
            return (folder, file)
        }.first
        guard let (folder, file) = pair else { return fail("selecting a file in a folder from the test dataset") }
        select(file)
        guard await waitUntil({ self.map.selection == file && self.files.selectedID == file }) else {
            return fail("selection sync")
        }
        zoomTo(id: folder)
        guard zoom == folder, pathIDs.last == folder else { return fail("zoom in") }
        zoomOut()
        guard zoom == 0 else { return fail("zoom out") }
        details.showList(query: snapshot.nodes[file].name)
        let searchDeadline = ContinuousClock.now + .seconds(10)
        while !details.containsResult(file), ContinuousClock.now < searchDeadline {
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard details.containsResult(file) else { return fail("name search") }
        select(file)
        refreshSelection()
        let refreshDeadline = ContinuousClock.now + .seconds(10)
        while scanWorker != nil, ContinuousClock.now < refreshDeadline {
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard scanWorker == nil && selectedURL?.path == snapshot.url(for: file).path else { return fail("refresh") }
        return true
    }

    func exerciseLayout() async -> Bool {
        guard await waitUntil({ self.testReady }), let snapshot else { return false }
        guard LayoutDiagnostics.exerciseDivider(fileAndMap.splitView),
              LayoutDiagnostics.exerciseDivider(panes.splitView) else {
            print("Split divider dragging failed.")
            return false
        }
        let positions = layoutSignature
        showWindow(nil)
        guard layoutSignature == positions else {
            print("Showing the window again reset the layout.")
            return false
        }
        guard LayoutDiagnostics.exerciseColumns(files.view),
              LayoutDiagnostics.exerciseColumns(details.table) else { return false }
        let kindsColumns = signature(for: details.table)
        guard let total = totals?.first else { return false }
        details.showList(kind: total.kind, query: "")
        guard LayoutDiagnostics.exerciseColumns(details.table) else { return false }
        let resultColumns = signature(for: details.table)
        details.toggleList()
        guard signature(for: details.table) == kindsColumns else { return false }
        details.toggleList()
        guard signature(for: details.table) == resultColumns, details.kind == total.kind else { return false }
        findFiles()
        guard details.kind == total.kind else { return false }
        let folder = snapshot.children(of: 0).first { snapshot.isExpandable($0, options: options) }
        if let folder, let window {
            select(folder)
            guard let key = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ) else { return false }
            files.view.keyDown(with: key)
            guard zoom == folder else { return false }
            zoomRoot()
            select(folder)
            files.view.deselectAll(nil)
            guard files.selectedID == nil, selected == nil else { return false }
        }
        refreshAll()
        return await waitUntil { self.testReady && self.details.kind != nil && self.details.hasMatches }
    }

    var layoutSignature: [String] {
        [panes.splitView, fileAndMap.splitView].map {
            "\(Int(($0.subviews.first?.frame.width ?? 0).rounded()))"
        } + signature(for: files.view) + signature(for: details.table)
    }

    private func signature(for table: NSTableView) -> [String] {
        table.tableColumns.map { "\($0.identifier.rawValue):\(Int($0.width.rounded()))" }
    }

    func exerciseVisualSettings() async -> Bool {
        guard await waitUntil({ self.testReady }), let snapshot,
              let id = snapshot.children(of: 0).first(where: { !snapshot.nodes[$0].isDirectory }) else { return false }
        select(id)
        let token = generation
        let expectedSelection = selected
        let store = Settings.store

        for alternative in TreemapPalette.allCases {
            store.set(alternative.rawValue, forKey: "treemapPalette")
            let expected = alternative.swatches.map(TreemapPalette.color)
            guard await waitUntil({
                self.palette == alternative && self.map.usesAnySwatch(from: expected)
            }) else { return false }
        }

        store.set(false, forKey: "treemapLabels")
        store.set(true, forKey: "treemapFolderBorders")
        store.set(true, forKey: "smallFont")
        store.set(true, forKey: "vertical")
        guard await waitUntil({
            self.map.mapAppearance == MapAppearance(labels: false, folderBorders: true)
                && !self.fileAndMap.splitView.isVertical && self.files.isCompact
        }) else { return false }
        return generation == token && selected == expectedSelection && scanWorker == nil
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(16))
        }
        return condition()
    }

    func exerciseTrash(in fixture: URL) async throws -> Duration {
        let deadline = ContinuousClock.now + .seconds(15)
        while !testReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard testReady, await exerciseWorkflow() else { throw CocoaError(.fileReadUnknown) }
        var longest = Duration.zero
        let ticker = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                let now = ContinuousClock.now
                longest = max(longest, previous.duration(to: now))
                previous = now
            }
        }
        defer { ticker.cancel() }
        let paths = [
            fixture.appending(path: "Dense/item-29999.txt", directoryHint: .notDirectory),
            fixture.appending(path: "Dense", directoryHint: .isDirectory)
        ]
        for url in paths {
            guard let snapshot, let id = snapshot.find(url) else { throw CocoaError(.fileReadNoSuchFile) }
            let node = snapshot.nodes[id]
            let parent = snapshot.url(for: Int(node.parent))
            select(id)
            guard await waitUntil({ self.files.selectedID == id }),
                  let task = trash(url, parent: parent, node: node, id: id) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard let resultingURL = try await task.value.destination else { throw CocoaError(.fileWriteUnknown) }
            let updated = await waitUntil {
                !self.isTrashing && self.scanWorker == nil && self.snapshot?.find(url) == nil && self.map.hasTiles
            }
            let moved = await Task.detached {
                let manager = FileManager.default
                let verified = !manager.fileExists(atPath: url.path) && manager.fileExists(atPath: resultingURL.path)
                if verified { try? manager.removeItem(at: resultingURL) }
                return verified
            }.value
            guard updated, moved else { throw CocoaError(.fileWriteUnknown) }
        }
        return longest
    }

    init(location: URL) {
        self.location = location
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1190, height: 755),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = location.lastPathComponent.isEmpty ? "Disk Inventory" : displayName
        window.subtitle = "Disk Inventory"
        window.representedURL = location.path == "/System/Volumes/Data" ? URL(filePath: "/") : location
        window.minSize = NSSize(width: 815, height: 565)
        window.isReleasedWhenClosed = false
        window.delegate = self
        setup(window)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didSetUpDividers, let content = window?.contentView else { return }
        didSetUpDividers = true
        content.layoutSubtreeIfNeeded()
        let split = panes.splitView
        split.setPosition(split.bounds.width - 315, ofDividerAt: 0)
        split.autosaveName = Settings.layoutName("Panes")
        content.layoutSubtreeIfNeeded()
        configureFileSplit()
    }

    private func configureFileSplit() {
        let vertical = !Settings.bool("vertical")
        let split = fileAndMap.splitView
        if split.isVertical != vertical { split.autosaveName = nil }
        split.isVertical = vertical
        fileAndMap.splitViewItems[0].minimumThickness = vertical ? 156 : 130
        fileAndMap.splitViewItems[1].minimumThickness = vertical ? 176 : 130
        if didSetUpDividers {
            split.adjustSubviews()
            let extent = vertical ? split.bounds.width : split.bounds.height
            split.setPosition(min(290, extent * 0.44), ofDividerAt: 0)
            split.autosaveName = Settings.layoutName(vertical ? "SideBySide" : "Stacked")
        }
    }

    private func controller(_ view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    private func setup(_ window: NSWindow) {
        let filePane = NSSplitViewItem(viewController: controller(files.scroll))
        filePane.preferredThicknessFraction = 0.31
        map.mapAppearance = Settings.mapAppearance
        let mapPane = NSSplitViewItem(viewController: controller(map))
        fileAndMap.splitView.isVertical = !Settings.bool("vertical")
        fileAndMap.addSplitViewItem(filePane)
        fileAndMap.addSplitViewItem(mapPane)
        configureFileSplit()
        panes.splitView.isVertical = true
        panes.addSplitViewItem(NSSplitViewItem(viewController: fileAndMap))
        detailPane = NSSplitViewItem(viewController: controller(details.root))
        detailPane.minimumThickness = 240
        detailPane.preferredThicknessFraction = 0.28
        detailPane.canCollapse = true
        panes.addSplitViewItem(detailPane)

        pathControl.pathStyle = .standard
        pathControl.target = self
        pathControl.action = #selector(breadcrumb)
        updatePath()
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 12)
        info.lineBreakMode = .byTruncatingMiddle
        info.maximumNumberOfLines = 1
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        meter.style = .bar
        meter.isIndeterminate = false
        meter.controlSize = .small
        meter.minValue = 0
        meter.maxValue = 1
        meter.isHidden = true
        meter.widthAnchor.constraint(equalToConstant: 120).isActive = true
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.target = self
        cancel.action = #selector(cancelScan)
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        cancel.isHidden = true
        issues.bezelStyle = .rounded
        issues.controlSize = .small
        issues.target = self
        issues.action = #selector(showIssues)
        issues.isHidden = true

        let header = NSStackView(views: [pathControl])
        header.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [progress, info, space, status, meter, issues, cancel])
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        footer.spacing = 8
        footer.alignment = .centerY
        let top = NSBox()
        top.boxType = .separator
        let bottom = NSBox()
        bottom.boxType = .separator
        let shell = ContentSurface(frame: NSRect(x: 0, y: 0, width: 1190, height: 720))
        let paneView = panes.view
        for view in [header, top, paneView, bottom, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            shell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            header.topAnchor.constraint(equalTo: shell.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),
            top.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            top.topAnchor.constraint(equalTo: header.bottomAnchor),
            paneView.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: top.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: paneView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            footer.topAnchor.constraint(equalTo: bottom.bottomAnchor),
            footer.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 34)
        ])
        let root = controller(shell)
        root.addChild(panes)
        window.contentViewController = root
        window.initialFirstResponder = files.view
        window.setContentSize(NSSize(width: 1190, height: 720))
        let toolbar = NSToolbar(identifier: "ScanToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.center()
        window.setFrameAutosaveName(Settings.layoutName("ScanWindow"))

        map.resized = { [weak self] in self?.renderMap(debounce: true) }
        map.choose = { [weak self] id, double in
            self?.select(id)
            if double { self?.openItem(id) }
        }
        map.quickLook = { [weak self] in self?.toggleQuickLook() }
        map.zoomOutRequest = { [weak self] in self?.zoomOut() }
        map.placeholderAction = { [weak self] in self?.placeholderAction?() }
        map.zoomAggregate = { [weak self] id, child in
            guard let self else { return }
            if id != zoom {
                zoomTo(id: id)
            } else {
                fileAndMap.splitViewItems.first?.isCollapsed = false
                if let child { select(child) }
                self.window?.makeFirstResponder(files.view)
            }
        }
        map.hover = { [weak self] id in self?.showInfo(id ?? self?.selected) }
        map.context = { [weak self] id in self?.contextMenu(id) }
        files.didSelect = { [weak self] id in self?.select(id, reveal: false) }
        files.didOpen = { [weak self] id in self?.openItem(id) }
        files.menuForRow = { [weak self] id in self?.contextMenu(id) }
        files.quickLook = { [weak self] in self?.toggleQuickLook() }
        details.quickLook = { [weak self] in self?.toggleQuickLook() }
        details.didSelect = { [weak self] id in self?.select(id, fromSearch: true) }
        details.didOpen = { [weak self] id in self?.openItem(id) }
        details.menuForRow = { [weak self] id in self?.contextMenu(id) }
        details.updateSearch = { [weak self] in self?.search() }
        details.tabChanged = { [weak self] in self?.tabChanged() }
        details.kindSelected = { [weak self] _ in self?.updateMapEmphasis() }
    }

    private func tabChanged() {
        if details.cleaning { prepareCleanup() }
        updateMapEmphasis()
    }

    private func prepareCleanup() {
        guard let snapshot else { return }
        if let cleanupModel {
            if cleanupNeedsUpdate || (!cleanupModel.analyzed && !cleanupModel.analyzing) {
                cleanupNeedsUpdate = false
                cleanupModel.update(snapshot: snapshot)
            }
            return
        }
        let model = CleanupModel(snapshot: snapshot) { [weak self] removed, refreshed in
            await self?.applyCleanup(removed: removed, refreshed: refreshed)
        }
        model.scanIsIdle = { [weak self] in
            guard let self else { return false }
            return scanWorker == nil && !isTrashing && !closed
        }
        model.reveal = { [weak self] path in self?.revealPath(path) }
        model.quickLook = { [weak self] path in self?.preview(path) }
        model.candidatesChanged = { [weak self] in self?.updateMapEmphasis() }
        model.scanHome = { NSApp.sendAction(#selector(ApplicationController.scanHome), to: nil, from: nil) }
        cleanupModel = model
        details.showCleanup(AnyView(CleanupPanel(model: model)))
        model.update(snapshot: snapshot)
    }

    func reloadAdvice() {
        cleanupModel?.reloadAdvice()
    }

    private func updateMapEmphasis() {
        if details.cleaning, let cleanupModel {
            let candidates = cleanupModel.candidateIDs
            map.highlightKind = nil
            map.highlightNodes = candidates.isEmpty ? nil : candidates
        } else if details.searching, details.hasMatches, !details.query.isEmpty || details.kind != nil {
            map.highlightKind = nil
            map.highlightNodes = Set(details.matchIDs)
        } else if let kind = details.selectedKind {
            map.highlightNodes = nil
            map.highlightKind = Int32(kind)
        } else {
            map.highlightKind = nil
            map.highlightNodes = nil
        }
    }

    private func revealPath(_ path: String) {
        guard let snapshot, let id = snapshot.locate(path) else { return }
        select(id, fromSearch: true)
    }

    private func preview(_ path: String) {
        previewOverride = URL(filePath: path)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    private var isVolumeScan: Bool {
        location.path == "/System/Volumes/Data" || (try? location.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    private static var hasFullDiskAccess: Bool {
        let descriptor = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard descriptor >= 0 else { return false }
        Darwin.close(descriptor)
        return true
    }

    private static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func askForAccess(then proceed: @escaping () -> Void) -> Bool {
        guard !accessPromptShown, isVolumeScan, !Self.hasFullDiskAccess, !Settings.bool("skipAccessPrompt"), let window else { return false }
        accessPromptShown = true
        let alert = NSAlert()
        alert.messageText = "Allow Full Disk Access for a complete scan"
        alert.informativeText = "Without it macOS hides Mail, Messages, Safari and parts of Library from Disk Inventory, and may ask about Documents and Desktop in the middle of the scan. Turn on Disk Inventory in Privacy & Security → Full Disk Access, then reopen the app."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Scan Anyway")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.beginSheetModal(for: window) { response in
            if alert.suppressionButton?.state == .on { Settings.store.set(true, forKey: "skipAccessPrompt") }
            if response == .alertFirstButtonReturn { Self.openPrivacySettings() }
            proceed()
        }
        return true
    }

    private func stopScanIndicators() {
        progress.stopAnimation(nil)
        cancel.isHidden = true
        meter.isHidden = true
        stallTimer?.invalidate()
        stallTimer = nil
    }

    private func checkStall() {
        guard scanWorker != nil, started(ago: 8) else { return }
        let parts = lastProgress.path.split(separator: "/")
        let folder = parts.count > 2 && lastProgress.path.hasPrefix(NSHomeDirectory()) ? String(parts[2]) : String(parts.last ?? "")
        status.stringValue = "Waiting for access to “\(folder)”"
        map.placeholder = MapPlaceholder(
            title: "Waiting for macOS", symbol: "hourglass",
            detail: "Reading “\(folder)” has not answered for a while. macOS may be asking for permission to access it; answer the prompt or cancel the scan.",
            busy: true)
    }

    private func started(ago seconds: Int) -> Bool {
        lastProgress.at.duration(to: .now) > .seconds(seconds)
    }

    func scan(restore: Bool = true, refreshing id: Int? = nil, trashMove: AdviceTrash.Move? = nil) {
        guard !closed, !isTrashing, cleanupModel?.working == nil else { return }
        let afterTrash = trashMove != nil
        if id == nil, !afterTrash, askForAccess(then: { [weak self] in self?.scan(restore: restore) }) { return }
        let oldSnapshot = snapshot
        let selectedURL = rescanningSelection ?? selected.flatMap { $0 >= 0 ? oldSnapshot?.url(for: $0) : nil }
        let zoomURL = oldSnapshot?.url(for: zoom)
        let oldStack = stack.compactMap { oldSnapshot?.url(for: $0) }
        rescanningSelection = nil
        scanWorker?.cancel()
        whileScanning?.cancel()
        generation = UUID()
        let token = generation
        let started = ContinuousClock.now
        let location = location
        let ignoreCreator = ignoreCreator
        progress.startAnimation(nil)
        cancel.isEnabled = true
        cancel.isHidden = afterTrash
        issues.isHidden = true
        status.stringValue = afterTrash ? "Updating after move…" : "Scanning…"
        expectedBytes = id == nil && isVolumeScan ? VolumeUsage.read(location).map { max(1, $0.capacity - $0.free) } : nil
        lastProgress = (0, .now, location.path)
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStall() }
        }
        info.stringValue = location.path
        map.placeholder = MapPlaceholder(title: "Scanning \(displayName)", symbol: "magnifyingglass", busy: true)
        let (updates, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            let summary: ScanSummary
            if let id, let oldSnapshot {
                summary = if let trashMove {
                    try InventoryScanner.updating(oldSnapshot, removed: [trashMove.source],
                        refreshing: [trashMove.destination?.deletingLastPathComponent() ?? oldSnapshot.root])
                } else {
                    try InventoryScanner.refresh(id, in: oldSnapshot) { continuation.yield($0) }
                }
            } else {
                summary = try InventoryScanner.scan(location, ignoreCreatorCode: ignoreCreator) { continuation.yield($0) }
            }
            return ScanResult(
                snapshot: summary,
                zoom: restore ? (zoomURL.flatMap(summary.find) ?? 0) : 0,
                stack: restore ? oldStack.compactMap(summary.find) : [],
                selected: restore ? selectedURL.flatMap(summary.find) : nil
            )
        }
        scanWorker = worker
        whileScanning = Task { [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                if worker.isCancelled { continue }
                let seconds = Int(started.duration(to: .now).components.seconds)
                let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
                let elapsed = Duration.seconds(seconds).formatted(.time(pattern: pattern))
                self.map.placeholder = MapPlaceholder(
                    title: update.finishing ? "Calculating Totals" : "Scanning \(self.displayName)", symbol: "magnifyingglass",
                    detail: "\(update.entries.formatted()) items · \(elapsed)", busy: true)
                let traversal = update.traversal == .bulk ? "APFS" : "Compatible"
                if update.entries != self.lastProgress.entries {
                    self.lastProgress = (update.entries, .now, update.path)
                }
                if let expected = self.expectedBytes, !update.finishing {
                    let fraction = min(0.99, Double(update.bytes) / Double(expected))
                    self.meter.isHidden = false
                    self.meter.doubleValue = fraction
                    self.status.stringValue = "\(fraction.formatted(.percent.precision(.fractionLength(0)))) · \(update.entries.formatted()) items · \(elapsed)"
                } else {
                    self.status.stringValue = "\(update.entries.formatted()) items · \(elapsed)"
                }
                self.info.stringValue = "\(traversal) · \(update.path)"
            }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.scanWorker = nil
            self.stopScanIndicators()
            defer { self.applyDeferredSettings() }
            do {
                let result = try await worker.value
                self.snapshot = result.snapshot
                self.zoom = result.zoom
                self.stack = result.stack
                self.selected = result.selected
                self.renderAll(reusePalette: afterTrash)
                if self.details.cleaning {
                    if self.cleanupModel == nil {
                        self.prepareCleanup()
                    } else if let snapshot = self.snapshot {
                        self.cleanupModel?.update(snapshot: snapshot)
                    }
                    self.updateMapEmphasis()
                } else {
                    self.cleanupNeedsUpdate = true
                }
            } catch is CancellationError {
                self.updateStatus()
                self.showPlaceholder(MapPlaceholder(title: "Scan Canceled", symbol: "xmark.circle", action: "Scan Again")) { [weak self] in self?.scan() }
                if self.snapshot == nil { self.status.stringValue = "Canceled" }
            } catch {
                self.updateStatus()
                self.showPlaceholder(MapPlaceholder(
                    title: "Couldn’t Scan This Location", symbol: "exclamationmark.triangle",
                    detail: error.localizedDescription, action: "Choose Another Folder")) {
                    NSApp.sendAction(#selector(ApplicationController.chooseFolder), to: nil, from: nil)
                }
            }
        }
    }

    private func showPlaceholder(_ placeholder: MapPlaceholder, action: @escaping () -> Void) {
        placeholderAction = action
        map.placeholder = placeholder
    }

    @objc func quickLook(_ sender: Any?) { toggleQuickLook() }

    private func toggleQuickLook() {
        previewOverride = nil
        guard selectedURL != nil, let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { (previewOverride ?? selectedURL) == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        (previewOverride ?? selectedURL) as NSURL?
    }

    @objc func cancelScan() {
        guard !cancel.isHidden, let scanWorker else { return }
        scanWorker.cancel()
        whileScanning?.cancel()
        generation = UUID()
        self.scanWorker = nil
        stopScanIndicators()
        if snapshot != nil {
            renderAll(reusePalette: true)
        } else {
            updateStatus()
            status.stringValue = "Canceled"
            showPlaceholder(MapPlaceholder(title: "Scan Canceled", symbol: "xmark.circle", action: "Scan Again")) { [weak self] in self?.scan() }
        }
    }

    private func applyDeferredSettings() {
        guard deferredSettings else { return }
        deferredSettings = false
        applySettings()
    }

    func applySettings() {
        map.mapAppearance = Settings.mapAppearance
        files.setCompactText(Settings.bool("smallFont"))
        let vertical = !Settings.bool("vertical")
        if fileAndMap.splitView.isVertical != vertical { configureFileSplit() }
        let newPalette = Settings.treemapPalette
        let newShareColors = Settings.bool("shareColors", default: true)
        if palette != newPalette || shareColors != newShareColors {
            palette = newPalette
            shareColors = newShareColors
            if let snapshot, let totals {
                applyPalette(snapshot: snapshot, totals: totals)
                details.recolor(colors)
            }
        }

        let newOptions = Settings.options
        let ignore = Settings.bool("ignoreCreator", default: true)
        guard options != newOptions || ignoreCreator != ignore else { return }
        if isTrashing {
            deferredSettings = true
            return
        }
        options = newOptions
        if let snapshot, !snapshot.isExpandable(zoom, options: options) {
            zoom = snapshot.lineage(of: zoom).reversed().first { snapshot.isExpandable($0, options: options) } ?? 0
            stack.removeAll { !snapshot.isExpandable($0, options: options) }
        }
        if let snapshot, let id = selected, id >= 0, !options.packages,
           let package = snapshot.lineage(of: id).first(where: { snapshot.kinds[Int(snapshot.nodes[$0].kind)].isPackage && $0 != 0 }) {
            selected = package
        }
        if ignoreCreator != ignore {
            ignoreCreator = ignore
            scan()
        } else {
            renderAll()
        }
    }

    private func applyPalette(snapshot: ScanSummary, totals: [KindTotal]) {
        let assignments = shareColors ? KindColors.shared : documentColors
        colors = assignments.colors(for: snapshot, totals: totals, palette: palette)
        map.recolor(colors)
    }

    private func renderAll(reusePalette: Bool = false) {
        mapWorker?.cancel()
        mapUpdate?.cancel()
        mapUpdate = nil
        totals = nil
        if !reusePalette { colors = [] }
        updatePath()
        files.display(snapshot, root: zoom, options: options)
        files.reveal(selected)
        searchWorker?.cancel()
        searchUpdate?.cancel()
        details.display(snapshot: snapshot, totals: nil, colors: [], options: options)
        updateStatus()
        map.clear()
        map.selection = selected
        map.placeholder = MapPlaceholder(title: "Drawing Treemap", symbol: "square.grid.3x3", busy: true)
        if reusePalette { renderMap() }
        renderTotals(reusingPalette: reusePalette)
    }

    private func renderTotals(reusingPalette: Bool) {
        totalsWorker?.cancel()
        totalsUpdate?.cancel()
        guard let snapshot else { return }
        let options = options
        let worker = Task.detached(priority: .userInitiated) { try snapshot.kindTotals(options: options) }
        totalsWorker = worker
        totalsUpdate = Task { [weak self] in
            guard let data = try? await worker.value, let self, !Task.isCancelled else { return }
            self.totals = data
            self.applyPalette(snapshot: snapshot, totals: data)
            self.details.display(snapshot: snapshot, totals: data, colors: self.colors, options: options)
            self.details.sync(self.selected)
            if !reusingPalette || self.mapUpdate == nil { self.renderMap() }
            self.search()
        }
    }

    private func renderMap(animate: Bool = false, debounce: Bool = false) {
        mapWorker?.cancel()
        mapUpdate?.cancel()
        mapUpdate = nil
        guard let snapshot, colors.count == snapshot.kinds.count else { return }
        let size = map.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let options = options
        let zoom = zoom
        mapUpdate = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(80)) }
            guard let self, !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try TreemapLayout.make(snapshot: snapshot, focus: zoom, size: size, options: options)
            }
            self.mapWorker = worker
            guard let tiles = try? await worker.value, !Task.isCancelled else { return }
            if tiles.isEmpty {
                self.map.placeholder = MapPlaceholder(title: "Nothing to Show", symbol: "square.dashed", detail: "No items in this folder take up space")
            }
            self.map.show(tiles, snapshot: snapshot, colors: self.colors, size: size, options: options,
                          animate: animate && Settings.bool("animate", default: true) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    private func search() {
        searchWorker?.cancel()
        searchUpdate?.cancel()
        guard details.searching, let snapshot else { return }
        let query = details.query
        let field = details.field
        let kind = details.kind
        let options = options
        details.searchStarted()
        searchUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try snapshot.search(query, field: field, kind: kind, options: options)
            }
            self.searchWorker = worker
            guard let matches = try? await worker.value, !Task.isCancelled else { return }
            self.details.showMatches(matches)
        }
    }

    private func updateStatus() {
        guard let snapshot else {
            status.stringValue = ""
            info.stringValue = location.path
            return
        }
        let node = snapshot.nodes[zoom]
        if !isTrashing, scanWorker == nil {
            status.stringValue = "\(node.fileCount.formatted()) files · \(formatSize(node.size(options.mode)))"
        }
        issues.isHidden = snapshot.issueCount == 0
        issues.title = "\(snapshot.issueCount.formatted()) skipped"
        showInfo(selected)
    }

    private func showInfo(_ id: Int?) {
        guard !isTrashing, scanWorker == nil, let snapshot else { return }
        guard let id else {
            info.stringValue = snapshot.url(for: zoom).path
            return
        }
        if id < 0 {
            info.stringValue = "\(id == -1 ? "Free Space" : "Other Space") · \(formatSize(snapshot.size(of: id, options: options)))"
        } else {
            info.stringValue = "\(formatSize(snapshot.size(of: id, options: options))) · \(snapshot.displayPath(of: id))"
        }
        info.toolTip = info.stringValue
    }

    private func select(_ id: Int?, reveal: Bool = true, fromSearch: Bool = false) {
        guard let snapshot else { return }
        if let id, id >= 0, fromSearch, !snapshot.lineage(of: id).contains(zoom) {
            zoomTo(id: Int(snapshot.nodes[id].parent), selectAfter: id)
            return
        }
        selected = id
        map.selection = id
        if reveal { files.reveal(id) }
        if !fromSearch { details.sync(id) }
        showInfo(id)
        if previewOverride == nil, QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
        updateInfoPanel()
        if let id, id >= 0, Settings.bool("syncFinder") { revealInFinder() }
    }

    private func zoomTo(id: Int, selectAfter: Int? = nil, record: Bool = true) {
        guard let snapshot, id >= 0, snapshot.isExpandable(id, options: options) else { return }
        if record, id != zoom { stack.append(zoom) }
        if zoom != id { map.acceptsTileActions = false }
        zoom = id
        selected = selectAfter ?? id
        updatePath()
        files.display(snapshot, root: id, options: options)
        files.reveal(selected)
        map.selection = selected
        details.sync(selected)
        renderMap(animate: true)
        updateStatus()
    }

    private func updatePath() {
        let ids = snapshot?.lineage(of: zoom) ?? [0]
        pathIDs = ids
        pathControl.pathItems = ids.map { id in
            let item = NSPathControlItem()
            let url = snapshot?.url(for: id) ?? location
            item.title = id == 0 ? displayName : snapshot?.nodes[id].name ?? url.lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: id == 0 && location.path == "/System/Volumes/Data" ? "/" : url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            return item
        }
    }

    @objc private func breadcrumb() {
        guard let clicked = pathControl.clickedPathItem,
              let index = pathControl.pathItems.firstIndex(of: clicked), pathIDs.indices.contains(index) else { return }
        zoomTo(id: pathIDs[index])
    }

    @objc func zoomIn() {
        guard let snapshot, let selected, selected >= 0 else { return }
        let id = snapshot.isExpandable(selected, options: options) ? selected : Int(snapshot.nodes[selected].parent)
        zoomTo(id: id, selectAfter: id == selected ? nil : selected)
    }

    @objc func zoomOut() {
        guard let snapshot, zoom != 0 else { return }
        let old = zoom
        let previous = stack.popLast() ?? Int(snapshot.nodes[zoom].parent)
        let selectAfter = snapshot.lineage(of: old).contains(previous) ? old : nil
        zoomTo(id: previous, selectAfter: selectAfter, record: false)
    }

    @objc func zoomRoot() {
        stack = []
        zoomTo(id: 0, record: false)
    }

    private func openItem(_ id: Int) {
        guard let snapshot, id >= 0 else { return }
        if snapshot.isExpandable(id, options: options) { zoomTo(id: id) }
        else { NSWorkspace.shared.open(snapshot.url(for: id)) }
    }

    @objc func openSelected() {
        if let url = selectedURL { NSWorkspace.shared.open(url) }
    }

    @objc func revealInFinder() {
        if let url = selectedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private var selectedURL: URL? {
        guard let selected, selected >= 0 else { return nil }
        return snapshot?.url(for: selected)
    }

    @objc func refreshSelection() {
        guard let selected, selected >= 0 else { return }
        rescanningSelection = selectedURL
        scan(refreshing: selected)
    }

    @objc func refreshAll() { scan() }

    @objc func findFiles() {
        detailPane.isCollapsed = false
        details.openSearch(focus: true)
    }

    @objc func findNext() {
        guard details.hasMatches else { return }
        detailPane.isCollapsed = false
        details.next()
    }
    @objc func scrollToSelection() { files.reveal(selected) }

    @objc func toggleList() {
        detailPane.isCollapsed = false
        details.toggleList()
    }

    @objc func toggleDetails() { detailPane.animator().isCollapsed.toggle() }

    @objc func copy(_ sender: Any?) { copySelection() }

    @objc func copySelection() {
        guard let url = selectedURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    @objc func copyPath() {
        guard let url = selectedURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func findSelection() {
        guard let snapshot, let selected, selected >= 0 else { return }
        detailPane.isCollapsed = false
        details.showList(query: snapshot.nodes[selected].name, focus: true)
    }

    @objc func inspect() {
        if infoPanel == nil { infoPanel = InfoPanelController() }
        infoPanel?.showWindow(nil)
        updateInfoPanel()
    }

    private func updateInfoPanel() {
        guard let infoPanel, infoPanel.window?.isVisible == true else { return }
        guard let snapshot, let selected, selected >= 0 else {
            infoPanel.show(nil)
            return
        }
        let item = snapshot.nodes[selected]
        let url = URL(filePath: snapshot.displayPath(of: selected))
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        infoPanel.show(ItemInfo(
            name: item.name, path: url.path, kind: snapshot.kinds[Int(item.kind)].title,
            allocated: item.allocated, logical: item.logical, files: item.isDirectory ? item.fileCount : nil,
            created: values?.creationDate, modified: values?.contentModificationDate,
            icon: NSWorkspace.shared.icon(forFile: url.path)))
    }

    @objc func showIssues() {
        guard let snapshot, let window else { return }
        let alert = NSAlert()
        alert.messageText = "\(snapshot.issueCount.formatted()) locations couldn’t be read"
        let reasons = Dictionary(grouping: snapshot.issues, by: \.message)
            .map { (reason: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        let permission = reasons.contains { $0.reason.contains("not permitted") || $0.reason.contains("Permission denied") }
        var text = reasons.map { "\($0.reason): \($0.count.formatted())" }.joined(separator: "\n")
        if snapshot.issueCount > snapshot.issues.count { text += "\n(the first \(snapshot.issues.count) are listed)" }
        text += "\n\nThe treemap and totals include only what macOS allowed Disk Inventory to read."
        if permission { text += " Most of these need Full Disk Access." }
        alert.informativeText = text
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 565, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let list = NSTextView(frame: scroll.bounds)
        list.isEditable = false
        list.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        list.string = snapshot.issues.map { "\($0.path) — \($0.message)" }.joined(separator: "\n")
        scroll.documentView = list
        alert.accessoryView = scroll
        if permission { alert.addButton(withTitle: "Open Privacy Settings") }
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { response in
            if permission, response == .alertFirstButtonReturn { Self.openPrivacySettings() }
        }
    }

    @objc func moveToTrash() {
        guard let snapshot, let id = selected, id > 0, let window, !isTrashing, scanWorker == nil,
              cleanupModel?.working == nil else { return }
        let node = snapshot.nodes[id]
        let url = snapshot.url(for: id)
        let parent = snapshot.url(for: Int(node.parent))
        if !Settings.bool("confirmTrash", default: true) {
            trash(url, parent: parent, node: node, id: id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to Trash?"
        alert.informativeText = url.path
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.trash(url, parent: parent, node: node, id: id) }
        }
    }

    @objc func cleanUp() {
        detailPane.isCollapsed = false
        details.selectTab(2)
    }

    private func applyCleanup(removed: [URL], refreshed: [URL]) async -> ScanSummary? {
        guard let current = snapshot, scanWorker == nil, !isTrashing, !closed else { return snapshot }
        let zoomURL = current.url(for: zoom)
        let stackURLs = stack.map { current.url(for: $0) }
        let selectedURL = selected.flatMap { $0 >= 0 ? current.url(for: $0) : nil }
        isTrashing = true
        status.stringValue = "Updating after cleanup…"
        progress.startAnimation(nil)
        window?.toolbar?.validateVisibleItems()
        let result = await Task.detached(priority: .userInitiated) { () throws -> ScanSummary in
            try InventoryScanner.updating(current, removed: removed, refreshing: refreshed)
        }.result
        isTrashing = false
        progress.stopAnimation(nil)
        window?.toolbar?.validateVisibleItems()
        guard !closed else { return nil }
        defer { applyDeferredSettings() }
        switch result {
        case let .success(summary):
            snapshot = summary
            zoom = summary.find(zoomURL) ?? 0
            stack = stackURLs.compactMap(summary.find)
            selected = selectedURL.flatMap(summary.find)
            renderAll(reusePalette: true)
            return summary
        case let .failure(error):
            updateStatus()
            present(error)
            return snapshot
        }
    }

    @discardableResult
    private func trash(_ url: URL, parent: URL, node: FileNode, id: Int) -> Task<AdviceTrash.Move, Error>? {
        guard !closed, !isTrashing, scanWorker == nil, cleanupModel?.working == nil else { return nil }
        guard let snapshot, snapshot.nodes.indices.contains(id),
              snapshot.nodes[id].inode == node.inode, snapshot.nodes[id].device == node.device,
              snapshot.url(for: id).path == url.path else {
            present(CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The scan changed. Select the item again."]))
            return nil
        }
        isTrashing = true
        status.stringValue = "Moving to Trash…"
        info.stringValue = url.path
        progress.startAnimation(nil)
        window?.toolbar?.validateVisibleItems()

        let worker = Task.detached(priority: .userInitiated) {
            try AdviceTrash.move(AdviceTrash.Target(url: url, node: node))
        }
        Task { [weak self] in
            let result = await worker.result
            guard let self, !closed else { return }
            isTrashing = false
            window?.toolbar?.validateVisibleItems()
            switch result {
            case let .success(move):
                rescanningSelection = parent
                scan(refreshing: id, trashMove: move)
            case let .failure(error):
                progress.stopAnimation(nil)
                updateStatus()
                present(error)
                applyDeferredSettings()
            }
        }
        return worker
    }

    private func present(_ error: any Error) {
        if let window { NSAlert(error: error).beginSheetModal(for: window) }
    }

    private func contextMenu(_ id: Int) -> NSMenu? {
        guard id >= 0 else { return nil }
        select(id)
        let menu = NSMenu()
        let groups: [[(String, String, Selector)]] = [
            [("Open", "arrow.up.forward.app", #selector(openSelected)), ("Quick Look", "eye", #selector(quickLook(_:))),
             ("Reveal in Finder", "folder", #selector(revealInFinder))],
            [("Get Info", "info.circle", #selector(inspect)), ("Copy Path", "doc.on.doc", #selector(copyPath))],
            [("Zoom In", "plus.magnifyingglass", #selector(zoomIn)), ("Zoom Out", "minus.magnifyingglass", #selector(zoomOut)),
             ("Rescan Selection", "arrow.clockwise", #selector(refreshSelection))],
            [("Move to Trash…", "trash", #selector(moveToTrash))]
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for (title, symbol, action) in group {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.target = self
                menu.addItem(item)
            }
        }
        return menu
    }

    func captureWindow(to url: URL) -> Bool {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let window, let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage"),
              let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    func captureContent(to url: URL) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleDetails) {
            menuItem.title = detailPane.isCollapsed ? "Show Inspector" : "Hide Inspector"
        } else if menuItem.action == #selector(toggleList) {
            menuItem.title = details.searching ? "Show Kinds" : "Show Largest Files"
        }
        return menuItem.action.map(canPerformAction) ?? false
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.action.map(canPerformAction) ?? false
    }

    private func canPerformAction(_ action: Selector) -> Bool {
        switch action {
        case #selector(zoomOut), #selector(zoomRoot): return zoom != 0
        case #selector(zoomIn), #selector(openSelected), #selector(revealInFinder),
             #selector(inspect), #selector(copyPath), #selector(copySelection), #selector(copy(_:)), #selector(findSelection):
            return selectedURL != nil
        case #selector(refreshSelection): return selectedURL != nil && scanWorker == nil && !isTrashing
        case #selector(quickLook(_:)): return selectedURL != nil
        case #selector(refreshAll): return scanWorker == nil && !isTrashing
        case #selector(moveToTrash): return (selected ?? 0) > 0 && scanWorker == nil && !isTrashing
        case #selector(cleanUp): return snapshot != nil
        case #selector(findFiles), #selector(toggleList): return snapshot != nil
        case #selector(findNext): return details.hasMatches
        case #selector(scrollToSelection): return selected != nil
        default: return true
        }
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        files.cancelSorting()
        scanWorker?.cancel()
        whileScanning?.cancel()
        mapWorker?.cancel()
        mapUpdate?.cancel()
        totalsWorker?.cancel()
        totalsUpdate?.cancel()
        searchWorker?.cancel()
        searchUpdate?.cancel()
        onClose?(self)
    }

    private static let toolbarItems: [(String, String, String, Selector)] = [
        ("zoomOut", "Zoom Out", "minus.magnifyingglass", #selector(zoomOut)),
        ("zoomIn", "Zoom In", "plus.magnifyingglass", #selector(zoomIn)),
        ("refresh", "Rescan", "arrow.clockwise", #selector(refreshAll)),
        ("reveal", "Reveal in Finder", "folder", #selector(revealInFinder)),
        ("info", "Get Info", "info.circle", #selector(inspect)),
        ("search", "Find", "magnifyingglass", #selector(findFiles)),
        ("details", "Inspector", "sidebar.right", #selector(toggleDetails)),
        ("trash", "Move to Trash", "trash", #selector(moveToTrash)),
        ("cleanup", "Clean Up", "checklist", #selector(cleanUp))
    ]

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarItems.map { .init($0.0) } + [.flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["zoomOut", "zoomIn", "refresh", "reveal", "info", "cleanup"].map { .init($0) } + [.flexibleSpace, .init("search"), .init("details")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id.rawValue == "search" {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Search"
            item.preferredWidthForSearchField = 200
            details.adopt(searchField: item.searchField)
            return item
        }
        guard let definition = Self.toolbarItems.first(where: { $0.0 == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = definition.1
        item.paletteLabel = definition.1
        item.toolTip = definition.1
        item.image = NSImage(systemSymbolName: definition.2, accessibilityDescription: definition.1)
        item.target = self
        item.action = definition.3
        return item
    }
}

@MainActor private final class ContentSurface: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

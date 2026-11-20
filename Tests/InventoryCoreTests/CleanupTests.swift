import Foundation
import Testing
@testable import InventoryCore

private func makeFile(_ url: URL, bytes: Int = 16_384, age days: Double? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
    if let days {
        let date = Date(timeIntervalSinceNow: -days * 86_400)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }
}

private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appending(path: "cleanup-" + UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home.resolvingSymlinksInPath()
}

@Test func cleanupFindsRegenerableAndSafeItems() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try makeFile(home.appending(path: "Library/Caches/com.example.app/blob"))
    try makeFile(home.appending(path: "Library/Application Support/Tool/package.json"))
    try makeFile(home.appending(path: "Library/Application Support/Tool/node_modules/dep/index.js"))
    try makeFile(home.appending(path: "Dev/web/package.json"))
    try makeFile(home.appending(path: "Dev/web/node_modules/dep/index.js"))
    try makeFile(home.appending(path: "Dev/web/node_modules/dep/node_modules/inner/index.js"))
    try makeFile(home.appending(path: "Dev/loose/node_modules/dep/index.js"))
    try makeFile(home.appending(path: "Dev/crate/Cargo.toml"))
    try makeFile(home.appending(path: "Dev/crate/target/debug/app"))
    try makeFile(home.appending(path: "Documents/DerivedData/family.txt"))
    try makeFile(home.appending(path: "Library/Developer/Xcode/DerivedData/Project/index"))
    try makeFile(home.appending(path: ".vscode/extensions/ext/package.json"))
    try makeFile(home.appending(path: ".vscode/extensions/ext/node_modules/dep/index.js"))
    try makeFile(home.appending(path: "Downloads/Installer.dmg"))
    try makeFile(home.appending(path: "Downloads/notes.txt"))

    let snapshot = try InventoryScanner.scan(home)
    let groups = CleanupAnalyzer.analyze(snapshot, home: home)
    let found = Dictionary(uniqueKeysWithValues: groups.map { group in
        (group.category.id, Set(group.items.map { snapshot.url(for: $0.node).path.replacingOccurrences(of: home.path + "/", with: "") }))
    })

    #expect(found["caches"] == ["Library/Caches/com.example.app"])
    #expect(found["build-artifacts"] == ["Dev/web/node_modules", "Dev/crate/target"])
    #expect(found["derived-data"] == ["Library/Developer/Xcode/DerivedData/Project"])
    #expect(found["installers"] == ["Downloads/Installer.dmg"])
    #expect(groups.first?.category.safety == .safe)
    let project = try InventoryScanner.scan(home.appending(path: "Dev"))
    let inside = CleanupAnalyzer.analyze(project, home: home).flatMap(\.items).map { project.url(for: $0.node).lastPathComponent }
    #expect(Set(inside) == ["node_modules", "target"])
    let artifacts = try #require(groups.first { $0.category.id == "build-artifacts" })
    let web = try #require(snapshot.find(home.appending(path: "Dev/web/node_modules")))
    #expect(artifacts.items.first { $0.node == web }?.size == snapshot.nodes[web].allocated)
}

@Test func staleFilesUseTheLatestKnownActivity() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try makeFile(home.appending(path: "Movies/old.mov"), bytes: 65_536, age: 400)
    try makeFile(home.appending(path: "Movies/recent.mov"), bytes: 65_536, age: 3)
    try makeFile(home.appending(path: "Movies/tiny-old.mov"), bytes: 4_096, age: 400)
    try makeFile(home.appending(path: "Pictures/Library.photoslibrary/database.db"), bytes: 65_536, age: 400)
    try makeFile(home.appending(path: "Dev/old-build.bin"), bytes: 65_536, age: 400)
    let download = home.appending(path: "Downloads/archive/old.zip")
    try makeFile(download, bytes: 65_536, age: 500)

    let snapshot = try InventoryScanner.scan(home)
    let stale = CloudOffload.staleFiles(in: snapshot, minSize: 32_768, olderThanDays: 180, home: home)
    #expect(Set(stale.map { URL(filePath: $0.path).lastPathComponent }) == ["old.mov", "old.zip"])
    #expect(try #require(stale.first?.lastActivity) < Date(timeIntervalSinceNow: -300 * 86_400))
    let archive = try InventoryScanner.scan(download.deletingLastPathComponent())
    #expect(CloudOffload.staleFiles(in: archive, minSize: 32_768, olderThanDays: 180, home: home).map(\.path) == [download.path])
}

@Test func cleanupCollapsesOverlapsAndRespectsKeep() {
    let parent = CleanupSelection.Item(path: "/test/cache", size: 12)
    let advised = CleanupSelection.Item(path: "/test/cache/data", size: 8)
    let other = CleanupSelection.Item(path: "/test/cache-old", size: 5)
    #expect(CleanupSelection(kept: []).collapse([advised, parent, advised, other]) == [parent, other])
    #expect(CleanupSelection(kept: [advised.path]).collapse([advised, parent, advised, other]) == [other])
    #expect(CleanupSelection(kept: [parent.path]).collapse([advised, other]) == [other])
}

@Test func cleanupRefusesAReplacementAtTheScannedPath() throws {
    let root = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let item = root.appending(path: "cache")
    try makeFile(item)
    let snapshot = try InventoryScanner.scan(root)
    let node = snapshot.nodes[try #require(snapshot.find(item))]
    try FileManager.default.moveItem(at: item, to: root.appending(path: "old-cache"))
    try makeFile(item)
    let target = AdviceTrash.Target(url: item, node: node)
    #expect(throws: CocoaError.self) { try AdviceTrash.move(target) }
    #expect(FileManager.default.fileExists(atPath: item.path))
}

@Test func cleanupDoesNotCountHardLinksOutsideTheScan() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let cache = home.appending(path: "Library/Caches/app")
    let file = cache.appending(path: "blob")
    try makeFile(file, bytes: 4 << 20)
    try FileManager.default.linkItem(at: file, to: home.appending(path: "second-link"))
    for preferBulk in [true, false] {
        let snapshot = try InventoryScanner.scan(cache, preferBulk: preferBulk)
        #expect(snapshot.nodes[0].allocated == 4 << 20)
        #expect(snapshot.reclaimable(0, held: snapshot.heldByClones()) == 0)
    }
    let whole = try InventoryScanner.scan(home)
    #expect(whole.reclaimable(0, held: whole.heldByClones()) == 4 << 20)
    #expect(InventoryScanner.reclaimableSize(at: file) == 0)
}

@Test func cloudDestinationsAndMoves() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    let drive = home.appending(path: "Library/CloudStorage/GoogleDrive-me@example.com/My Drive", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: iCloud, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)

    let destinations = CloudOffload.destinations(home: home)
    #expect(destinations.map(\.service) == [.iCloudDrive, .googleDrive])
    #expect(destinations.last?.title == "Google Drive (me@example.com)")
    #expect(destinations.last?.root.path == drive.path)

    let file = home.appending(path: "Movies/Trip/clip.mov")
    try makeFile(file)
    let googleDrive = try #require(destinations.last)
    let expected = drive.appending(path: "Archived from Mac/Movies/Trip/clip.mov")
    #expect(CloudOffload.target(for: file, in: googleDrive, home: home).path == expected.path)
    let moved = try CloudOffload.move(file, to: googleDrive, home: home)
    #expect(moved.path == expected.path)
    #expect(FileManager.default.fileExists(atPath: expected.path))
    #expect(!FileManager.default.fileExists(atPath: file.path))

    try makeFile(file)
    let second = try CloudOffload.move(file, to: googleDrive, home: home)
    #expect(second.lastPathComponent == "clip 2.mov")
}

@Test func adviceGuardKeepsSystemAreasOut() throws {
    let scratch = URL(filePath: "/private/tmp/advice-guard-" + UUID().uuidString)
    try makeFile(scratch.appending(path: "blob"))
    defer { try? FileManager.default.removeItem(at: scratch) }

    #expect(AdviceGuard.normalize("/tmp/x") == "/private/tmp/x")
    #expect(AdviceGuard.normalize("/System/Volumes/Data/Library/Caches") == "/Library/Caches")
    #expect(AdviceGuard.refusal(for: scratch.path, verdict: .safe) == nil)
    #expect(AdviceGuard.refusal(for: "/Library/Caches", verdict: .safe) != nil)
    #expect(AdviceGuard.refusal(for: "/usr/bin/true", verdict: .review) != nil)
    #expect(AdviceGuard.refusal(for: "/System/Library", verdict: .review) != nil)
    #expect(AdviceGuard.refusal(for: "/Library/Preferences", verdict: .review) != nil)
    #expect(AdviceGuard.refusal(for: "/Applications", verdict: .review) != nil)
    if let app = try FileManager.default.contentsOfDirectory(atPath: "/Applications").first(where: { $0.hasSuffix(".app") }) {
        #expect(AdviceGuard.refusal(for: "/Applications/" + app, verdict: .review) == nil)
        #expect(AdviceGuard.refusal(for: "/Applications/" + app, verdict: .safe) != nil)
    }
    #expect(AdviceGuard.refusal(for: "/usr/bin/true", verdict: .keep) == nil)
}

@Test func adviceActionsOnlyRunFromTheAllowlist() {
    #expect(AdviceActions.refusal("rm-rf", argument: "/") != nil)
    #expect(AdviceActions.refusal("simctl-delete-device", argument: nil) != nil)
    #expect(AdviceActions.refusal("simctl-delete-device", argument: "not-a-simulator") == "invalid simulator UUID")
    #expect(AdviceActions.refusal("brew-uninstall-cask", argument: "x; rm -rf ~") != nil)
    #expect(AdviceActions.refusal("empty-trash", argument: nil) == nil)
    #expect(AdviceActions.definition("simctl-delete-device")?.commandLine("ABC") == "/usr/bin/xcrun simctl delete ABC")
    #expect(AdviceActions.parseSize("34.6MB") == 34_600_000)
    #expect(AdviceActions.parseSize("1.2GB (40%)") == 1_200_000_000)

    var item = AdviceItem(path: "", size: 0, verdict: .regenerable, reason: "", action: "empty-trash")
    #expect(item.isRunnable && !item.isRemovable)
    item.status = .done
    #expect(!item.isRunnable)
}

@Test func commandsHaveBoundedTimeAndOutput() {
    let ordinary = AdviceActions.run("/usr/bin/printf", ["sample"])
    #expect(ordinary.status == 0 && ordinary.output == "sample")
    let deadline = ContinuousClock.now
    let slow = AdviceActions.run("/bin/sleep", ["10"], timeout: 0.05)
    #expect(slow.status != 0 && slow.output.contains("timed out"))
    #expect(deadline.duration(to: .now) < .seconds(2))
    let tooMuch = AdviceActions.run("/usr/bin/printf", ["123456"], outputLimit: 5)
    #expect(tooMuch.status != 0 && tooMuch.output.contains("output limit"))
}

@Test func vendorFoldersInLibraryAreReviewOnly() throws {
    guard let vendor = try FileManager.default.contentsOfDirectory(atPath: "/Library").first(where: { ["Google", "Microsoft", "Parallels", "Arturia"].contains($0) }) else { return }
    #expect(AdviceGuard.refusal(for: "/Library/" + vendor, verdict: .review) == nil)
    #expect(AdviceGuard.refusal(for: "/Library/" + vendor, verdict: .safe) != nil)
    #expect(AdviceGuard.refusal(for: "/Library/Fonts", verdict: .review) != nil)
    #expect(AdviceGuard.refusal(for: "/Library/Application Support", verdict: .review) != nil)
}

@Test func clonesCountOnceAndFreeSpaceOnlyWithEveryCopy() throws {
    let root = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appending(path: "a/original.bin")
    try makeFile(original, bytes: 4 << 20)
    for copy in ["b/copy.bin", "c/copy.bin"] {
        let target = root.appending(path: copy)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(clonefile(original.path, target.path, 0) == 0)
    }
    try makeFile(root.appending(path: "solo.bin"), bytes: 1 << 20)

    let snapshot = try InventoryScanner.scan(root)
    let total = snapshot.nodes[0].allocated
    #expect(total >= 5 << 20 && total < 6 << 20)
    let held = snapshot.heldByClones()
    #expect(snapshot.reclaimable(0, held: held) == total)
    for folder in ["a", "b", "c"] {
        let id = try #require(snapshot.locate(root.appending(path: folder).path))
        #expect(snapshot.reclaimable(id, held: held) == 0)
    }

    let owner = try #require(["a/original.bin", "b/copy.bin", "c/copy.bin"]
        .compactMap { snapshot.locate(root.appending(path: $0).path) }
        .first { snapshot.nodes[$0].allocated > 0 })
    let after = try InventoryScanner.removing(owner, from: snapshot)
    #expect(after.nodes[0].allocated == total)

    let unchanged = try InventoryScanner.refresh(owner, in: snapshot)
    #expect(unchanged.nodes[0].allocated == total)
}

@Test func movingInsideScanUpdatesTheSourceAndDestination() throws {
    let root = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "file")
    let unrelated = root.appending(path: "extra")
    let folder = root.appending(path: ".Trash")
    let dest = folder.appending(path: "file")
    try makeFile(file, bytes: 4 << 20)
    try makeFile(unrelated)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let initial = try InventoryScanner.scan(root)
    try FileManager.default.moveItem(at: file, to: dest)
    try FileManager.default.removeItem(at: unrelated)
    let updated = try InventoryScanner.updating(initial, removed: [file, unrelated], refreshing: [folder])
    let full = try InventoryScanner.scan(root)
    #expect(updated.find(file) == nil && updated.find(unrelated) == nil)
    #expect(updated.find(dest) != nil)
    #expect(updated.nodes[0].allocated == full.nodes[0].allocated)
    #expect(updated.nodes[0].fileCount == full.nodes[0].fileCount)
}

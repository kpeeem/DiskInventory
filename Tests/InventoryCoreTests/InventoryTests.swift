import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import InventoryCore

@Test func sizesAndLinks() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dir = root.appending(path: "Package.app")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "file.txt")
    try Data(repeating: 42, count: 8192).write(to: file)
    let hardLink = root.appending(path: ".hidden.txt")
    try FileManager.default.linkItem(at: file, to: hardLink)
    let symlink = root.appending(path: "cycle")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
    let snapshot = try InventoryScanner.scan(root)
    let fileID = try #require(snapshot.find(file))
    let linkID = try #require(snapshot.find(hardLink))
    let symlinkID = try #require(snapshot.find(symlink))
    let dirID = try #require(snapshot.find(dir))
    #expect(snapshot.nodes.count == 5)
    #expect(snapshot.nodes[0].fileCount == 3)
    #expect(snapshot.nodes[0].logical == 16_384 + snapshot.nodes[symlinkID].logical)
    #expect(snapshot.nodes[fileID].allocated + snapshot.nodes[linkID].allocated == 8192)
    #expect(snapshot.kinds[Int(snapshot.nodes[dirID].kind)].isPackage)
    #expect(snapshot.children(of: symlinkID).isEmpty)
    #expect(snapshot.url(for: fileID).path == file.path)
}

@Test func treemapSearchAndPartialRefresh() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? fm.removeItem(at: root) }
    let directory = root.appending(path: "A")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = directory.appending(path: "image.jpg")
    let second = root.appending(path: "video.mov")
    try Data(repeating: 40, count: 8192).write(to: first)
    try Data(repeating: 41, count: 24_576).write(to: second)

    let before = try InventoryScanner.scan(root)
    var options = ViewOptions()
    options.mode = .logical
    let firstID = try #require(before.find(first))
    let secondID = try #require(before.find(second))
    #expect(try before.search("image", field: .name, kind: nil, options: options) == [firstID])
    #expect(try before.kindTotals(options: options).reduce(0) { $0 + $1.size } == 32_768)
    let tiles = try TreemapLayout.make(snapshot: before, focus: 0, size: CGSize(width: 800, height: 500), options: options)
    let tile = try #require(tiles.first { $0.id == secondID })
    #expect(abs(tile.rect.width * tile.rect.height - 300_000) < 0.1)

    let newLink = directory.appending(path: "copy.mov")
    try fm.linkItem(at: second, to: newLink)
    try Data(repeating: 45, count: 12_288).write(to: first)
    let increment = try InventoryScanner.refresh(try #require(before.find(directory)), in: before)
    let full = try InventoryScanner.scan(root)
    #expect(increment.find(newLink) != nil)
    #expect(increment.nodes[0].logical == full.nodes[0].logical)
    #expect(increment.nodes[0].allocated == full.nodes[0].allocated)
    #expect(increment.nodes[0].fileCount == full.nodes[0].fileCount)
    try fm.removeItem(at: newLink)
    let deleted = try InventoryScanner.refresh(try #require(increment.find(newLink)), in: increment)
    #expect(deleted.find(newLink) == nil)
    #expect(deleted.nodes[0].fileCount == 2)
}

@Test func pathLookupUsesTheVolumesCaseRules() throws {
    let base = ProcessInfo.processInfo.environment["DISK_INVENTORY_TEST_VOLUME"]
        .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? FileManager.default.temporaryDirectory
    let root = base.appending(path: "Lookup-" + UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appending(path: "folder/Nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appending(path: "sample")
    try Data([1]).write(to: file)
    let alternate = root.appending(path: "Folder/nested/Sample")
    let snapshot = try InventoryScanner.scan(root)
    let id = try #require(snapshot.find(file))
    let supportsCase = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
    #expect(snapshot.find(alternate) == (supportsCase == true ? nil : id))
}

@Test func limitedResultsPreserveFullOrderingAndCounts() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<17 {
        try Data(repeating: 42, count: index % 4 * 1000 + 1).write(to: root.appending(path: "item-\(index).bin"))
    }
    let directory = root.appending(path: "Outer Folder/deep", directoryHint: .isDirectory)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let inside = directory.appending(path: "file % café.bin")
    try Data([3]).write(to: inside)
    try Data([3]).write(to: root.appending(path: "outside.bin"))
    let snapshot = try InventoryScanner.scan(root)
    var options = ViewOptions()
    options.mode = .logical
    let children = snapshot.children(of: 0).sorted { snapshot.nodes[$0].logical > snapshot.nodes[$1].logical }
    let all = try snapshot.search(".bin", field: .name, kind: nil, options: options)
    for limit in [1, 2, 5, 50] {
        let leading = snapshot.largestChildren(of: 0, mode: .logical, limit: limit)
        let matches = try snapshot.search(".bin", field: .name, kind: nil, options: options, limit: limit)
        #expect(leading.count == children.count && leading.ids == Array(children.prefix(limit)))
        #expect(matches.count == all.count && matches.ids == Array(all.prefix(limit)))
    }
    let id = try #require(snapshot.find(inside))
    #expect(try snapshot.search("Folder/deep/file % cafe", field: .path, kind: nil, options: options) == [id])
    #expect(try snapshot.search("Folder/deep/file % cafe", field: .all, kind: nil, options: options) == [id])
}

@Test func bulkMetadataMatchesFTS() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: root) }
    let subfolder = root.appending(path: "Набор.app")
    try fm.createDirectory(at: subfolder, withIntermediateDirectories: true)
    try fm.createDirectory(at: subfolder.appending(path: "Empty"), withIntermediateDirectories: false)
    let file = subfolder.appending(path: "資料.txt")
    let alias = root.appending(path: ".another-link.txt")
    try Data(repeating: 17, count: 8192).write(to: file)
    try fm.linkItem(at: file, to: alias)
    try fm.createSymbolicLink(at: root.appending(path: "Loop"), withDestinationURL: root)
    let sparse = root.appending(path: "large-image.raw")
    try Data([7]).write(to: sparse)
    let handle = try FileHandle(forWritingTo: sparse)
    try handle.truncate(atOffset: 4 * 1024 * 1024)
    try handle.close()

    let fast = try InventoryScanner.scan(root)
    let reference = try InventoryScanner.scan(root, preferBulk: false)
    let format = try root.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription
    if format?.localizedCaseInsensitiveContains("APFS") == true {
        #expect(fast.traversal == .bulk)
    }
    #expect(fast.nodes.count == reference.nodes.count)
    #expect(fast.nodes[0].fileCount == reference.nodes[0].fileCount)
    #expect(fast.nodes[0].logical == reference.nodes[0].logical)
    #expect(fast.nodes[0].allocated == reference.nodes[0].allocated)
    #expect(fast.issueCount == reference.issueCount)
    for id in reference.nodes.indices {
        let otherID = try #require(fast.find(reference.url(for: id)))
        let expected = reference.nodes[id]
        let actual = fast.nodes[otherID]
        #expect(actual.inode == expected.inode)
        #expect(actual.device == expected.device)
        #expect(actual.isDirectory == expected.isDirectory)
        #expect(fast.kinds[Int(actual.kind)] == reference.kinds[Int(expected.kind)])
        if !actual.isDirectory {
            #expect(actual.logical == expected.logical)
            #expect(actual.rawAllocated == expected.rawAllocated)
        }
    }
}

@Test func removingScannedItemRecountsAncestorsAndRetainedLinks() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? manager.removeItem(at: root) }
    let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "File")
    let source = folder.appending(path: "Linked")
    let link = root.appending(path: "Retained")
    try Data(repeating: 17, count: 8192).write(to: file)
    try Data(repeating: 40, count: 16384).write(to: source)
    try manager.linkItem(at: source, to: link)
    let original = try InventoryScanner.scan(root)
    let fileID = try #require(original.find(file))
    let folderID = try #require(original.find(folder))
    let updated = try InventoryScanner.removing(fileID, from: original)
    #expect(updated.find(file) == nil)
    #expect(updated.find(folder) == folderID)
    #expect(updated.nodes[0].fileCount == 2)
    #expect(updated.nodes[folderID].logical == 16384)
    #expect(updated.nodes[0].allocated == original.nodes[0].allocated - original.nodes[fileID].allocated)
    let removedFolder = try InventoryScanner.removing(folderID, from: updated)
    #expect(removedFolder.find(folder) == nil)
    let retained = try #require(removedFolder.find(link))
    #expect(removedFolder.nodes[retained].allocated == removedFolder.nodes[0].allocated)
    #expect(removedFolder.nodes[0].allocated > 0)
    #expect(removedFolder.nodes[0].fileCount == 1)
}


@Test func finderNamesUseTheAPFSScannerAndReuseLookups() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? fm.removeItem(at: root) }
    let folder = root.appending(path: "Library.app", directoryHint: .isDirectory)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let first = folder.appending(path: "first.txt")
    let second = folder.appending(path: "second.TXT")
    let alias = root.appending(path: "link")
    let finderAlias = folder.appending(path: "Tagged Alias.txt")
    try Data(repeating: 1, count: 8192).write(to: first)
    try Data(repeating: 2, count: 16384).write(to: second)
    try fm.createSymbolicLink(at: alias, withDestinationURL: root)
    try Data([3]).write(to: finderAlias)
    var info = [UInt8](repeating: 0, count: 32)
    info[8] = 0x80
    let tagged = finderAlias.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return info.withUnsafeBytes { bytes in
            setxattr(path, "com.apple.FinderInfo", bytes.baseAddress, bytes.count, 0, 0)
        }
    }
    try #require(tagged == 0)
    let detail = try InventoryScanner.scan(root, ignoreCreatorCode: false)
    let compatible = try InventoryScanner.scan(root, ignoreCreatorCode: false, preferBulk: false)
    let basic = try InventoryScanner.scan(root)
    #expect(detail.traversal == basic.traversal)
    #expect(detail.ignoreCreatorCode == false)
    #expect(detail.nodes[0].logical == basic.nodes[0].logical)
    #expect(detail.nodes[0].allocated == basic.nodes[0].allocated)
    #expect(detail.nodes.count == basic.nodes.count)
    #expect(detail.issueCount == basic.issueCount)
    for url in [folder, first, second, alias, finderAlias] {
        let id = try #require(detail.find(url))
        let other = try #require(compatible.find(url))
        #expect(detail.kinds[Int(detail.nodes[id].kind)] == compatible.kinds[Int(compatible.nodes[other].kind)])
    }

    let taggedID = try #require(detail.find(finderAlias))
    #expect(detail.kinds[Int(detail.nodes[taggedID].kind)].identifier == "com.apple.alias-file")

    var catalog = KindCatalog()
    var requests = 0
    func lookupPath() -> String {
        requests += 1
        return first.path
    }
    let firstKind = catalog.finderKind(name: "first.txt", directory: false, mode: 0, info: FinderInfo(), path: lookupPath())
    let secondKind = catalog.finderKind(name: "second.TXT", directory: false, mode: 0, info: FinderInfo(), path: lookupPath())
    var legacy = FinderInfo()
    legacy.typeAndCreator = 0x5445585474747874
    _ = catalog.finderKind(name: "legacy.txt", directory: false, mode: 0, info: legacy, path: lookupPath())
    #expect(firstKind == secondKind)
    #expect(requests == 2)
}

@Test func bulkWorkersPreserveKindsAcrossManySubtrees() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? fm.removeItem(at: root) }
    var files: [URL] = []
    for index in 0..<96 {
        let folder = root.appending(path: "folder-\(index)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["document.txt", "source.swift", "unique.sampletype\(index)"] {
            let url = folder.appending(path: name)
            try Data([1]).write(to: url)
            files.append(url)
        }
    }

    let bulk = try InventoryScanner.scan(root)
    let sequential = try InventoryScanner.scan(root, preferBulk: false)
    for url in files {
        let parallelID = try #require(bulk.find(url))
        let sequentialID = try #require(sequential.find(url))
        #expect(bulk.kinds[Int(bulk.nodes[parallelID].kind)] == sequential.kinds[Int(sequential.nodes[sequentialID].kind)])
    }
}

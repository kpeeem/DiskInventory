import Dispatch
import Foundation
import InventoryCore
import Testing
@testable import inventorymcp

@Test func refreshSkipsAnOlderBasicScanAfterADetailedScanFinishes() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let firstRead = DispatchSemaphore(value: 0)
    let allowFirstToFinish = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    let store = ScanStore { url, finderKinds in
        let snapshot = try InventoryScanner.scan(url, ignoreCreatorCode: !finderKinds)
        if !finderKinds && snapshot.nodes.count == 1 {
            firstRead.signal()
            try #require(allowFirstToFinish.wait(timeout: .now() + 30) == .success)
        }
        return snapshot
    }

    DispatchQueue.global().async {
        defer { firstFinished.signal() }
        do {
            let first = try store.scan(path: root.path, finderKinds: false, refresh: true, maxAge: 0, timeout: 30)
            #expect(first.snapshot.nodes.count == 1)
            #expect(!first.cached)
        } catch {
            Issue.record(error)
        }
    }
    defer {
        allowFirstToFinish.signal()
        #expect(firstFinished.wait(timeout: .now() + 5) == .success)
        #expect(store.recent().map { $0.snapshot.nodes.count } == [3])
    }
    try #require(firstRead.wait(timeout: .now() + 5) == .success)

    try Data([1]).write(to: root.appending(path: "after-first"))
    let detailed = try store.scan(path: root.path, finderKinds: true, refresh: true, maxAge: 0, timeout: 5)
    #expect(detailed.snapshot.nodes.count == 2)

    try Data([2]).write(to: root.appending(path: "after-detailed"))
    let refreshed = try store.scan(path: root.path, finderKinds: false, refresh: true, maxAge: 0, timeout: 5)
    #expect(refreshed.snapshot.nodes.count == 3)
}

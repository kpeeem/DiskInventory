import Darwin
import Foundation
import Synchronization

enum BulkScan {
    private struct Metadata {
        let device: Int32
        let inode: UInt64
        let directory: Bool
        let symlink: Bool
        let regular: Bool
        let shared: UInt64
        let references: UInt32
        let hardLinks: UInt16
        let logical: Int64
        let allocated: Int64

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            let type = info.st_mode & S_IFMT
            directory = type == S_IFDIR
            symlink = type == S_IFLNK
            regular = type == S_IFREG
            shared = regular && info.st_nlink > 1 ? info.st_ino : 0
            references = 0
            hardLinks = regular && info.st_nlink > 1 ? info.st_nlink : 0
            logical = directory ? 0 : max(0, info.st_size)
            allocated = directory ? 0 : max(0, info.st_blocks) * 512
        }

        init(device: Int32, inode: UInt64, type: UInt32, links: UInt32, logical: Int64, allocated: Int64,
             clone: UInt64 = 0, cloneReferences: UInt32 = 0) {
            self.device = device
            self.inode = inode
            directory = type == VDIR.rawValue
            symlink = type == VLNK.rawValue
            regular = type == VREG.rawValue
            let cloned = regular && cloneReferences > 1 && clone != 0
            shared = cloned ? clone | 1 << 63 : regular && links > 1 ? inode : 0
            references = cloned ? cloneReferences : 0
            hardLinks = regular && links > 1 ? UInt16(clamping: links) : 0
            self.logical = max(0, logical)
            self.allocated = max(0, allocated)
        }
    }

    private enum BatchError: Error { case unsupported }

    private struct Record {
        let bytes: UnsafeRawBufferPointer
        var offset = 0

        mutating func take<T>(_ type: T.Type) throws -> T {
            guard offset <= bytes.count - MemoryLayout<T>.size else { throw BatchError.unsupported }
            let value = bytes.loadUnaligned(fromByteOffset: offset, as: type)
            offset += MemoryLayout<T>.size
            return value
        }
    }

    static func cloneInfo(at url: URL) -> (shared: UInt64, references: UInt32)? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = ATTR_CMN_RETURNED_ATTRS
        let requested = UInt32(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
        attributes.forkattr = requested
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        return withUnsafeTemporaryAllocation(byteCount: 64, alignment: 8) { buffer in
            let status = url.withUnsafeFileSystemRepresentation { path in
                path.map { getattrlist($0, &attributes, buffer.baseAddress, buffer.count, options) } ?? -1
            }
            guard status == 0 else { return nil }
            var record = Record(bytes: UnsafeRawBufferPointer(buffer), offset: MemoryLayout<UInt32>.size)
            guard let returned = try? record.take(attribute_set_t.self), returned.forkattr & requested == requested,
                  let clone = try? record.take(UInt64.self), clone != 0,
                  let references = try? record.take(UInt32.self), references > 1 else { return nil }
            return (clone | 1 << 63, references)
        }
    }

    private struct Unit {
        let path: String
        let name: String
        let device: Int32
        let inode: UInt64
        let parentUnit: Int
        let parentNode: Int
    }

    private struct Partial {
        var nodes: [FileNode]
        var kinds: [FileKind]
        var issues: [ScanIssue]
        var issueCount: Int
    }

    private final class Coordinator: @unchecked Sendable {
        private let condition = NSCondition()
        private let progress: (ScanProgress) -> Void
        private var units: [Unit]
        private var partials: [Partial?] = [nil]
        private var pending = [0]
        private var active = 0
        private var failure: Error?
        private var entries = 0
        private var bytes: Int64 = 0
        private var nextProgress = ContinuousClock.now
        private let backlog = Atomic<Int>(1)
        private let stopped = Atomic<Bool>(false)
        let workers: Int

        init(root: Unit, workers: Int, progress: @escaping (ScanProgress) -> Void) {
            units = [root]
            self.workers = workers
            self.progress = progress
        }

        func unit(_ index: Int) -> Unit {
            condition.withLock { units[index] }
        }

        func next() -> Int? {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if failure == nil, Task.isCancelled { stop(CancellationError()) }
                if failure != nil {
                    condition.broadcast()
                    return nil
                }
                if let index = pending.popLast() {
                    backlog.store(pending.count, ordering: .relaxed)
                    active += 1
                    return index
                }
                if active == 0 {
                    condition.broadcast()
                    return nil
                }
                condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        private func stop(_ error: Error) {
            if failure == nil { failure = error }
            stopped.store(true, ordering: .relaxed)
        }

        func offer(_ unit: Unit) -> Bool {
            guard backlog.load(ordering: .relaxed) < workers else { return false }
            condition.lock()
            defer { condition.unlock() }
            guard failure == nil, pending.count < workers else { return false }
            units.append(unit)
            partials.append(nil)
            pending.append(units.count - 1)
            backlog.store(pending.count, ordering: .relaxed)
            condition.signal()
            return true
        }

        func finish(_ index: Int, with outcome: Result<Partial, Error>) {
            condition.lock()
            defer { condition.unlock() }
            switch outcome {
            case let .success(partial): partials[index] = partial
            case let .failure(error): stop(error)
            }
            active -= 1
            if failure != nil || (pending.isEmpty && active == 0) { condition.broadcast() }
        }

        func checkCancellation() throws {
            if Task.isCancelled, !stopped.load(ordering: .relaxed) {
                condition.withLock { stop(CancellationError()) }
            }
            if stopped.load(ordering: .relaxed) { throw CancellationError() }
        }

        func counted(_ added: Int, bytes addedBytes: Int64, path: @autoclosure () -> String) {
            condition.lock()
            defer { condition.unlock() }
            entries += added
            bytes += addedBytes
            guard ContinuousClock.now >= nextProgress else { return }
            nextProgress = .now + .milliseconds(125)
            progress(ScanProgress(entries: entries, path: path(), traversal: .bulk, bytes: bytes))
        }

        func outcome(finishing path: String) throws -> (units: [Unit], partials: [Partial]) {
            condition.lock()
            defer { condition.unlock() }
            if let failure { throw failure }
            progress(ScanProgress(entries: entries, path: path, traversal: .bulk, finishing: true, bytes: bytes))
            let finished = partials.map { $0! }
            partials = []
            return (units, finished)
        }
    }

    private static let descriptorLimit: Void = {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(limit.rlim_max, rlim_t(OPEN_MAX))
        if limit.rlim_cur < wanted {
            limit.rlim_cur = wanted
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }()

    static func scan(
        root: URL, rootInfo: stat, ignoreCreatorCode: Bool, progress: (ScanProgress) -> Void
    ) throws -> ScanSummary? {
        do {
            return try withoutActuallyEscaping(progress) { progress in
                try scanAPFS(root: root, rootInfo: rootInfo, ignoreCreatorCode: ignoreCreatorCode, progress: progress)
            }
        } catch BatchError.unsupported {
            return nil
        }
    }

    private static func scanAPFS(
        root: URL, rootInfo: stat, ignoreCreatorCode: Bool, progress: @escaping (ScanProgress) -> Void
    ) throws -> ScanSummary {
        descriptorLimit
        let rootPath = root.path
        let descriptor = rootPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw ScanError.filesystem(rootPath, errno) }
        var actualRoot = stat()
        var fs = statfs()
        let usable = fstat(descriptor, &actualRoot) == 0
            && actualRoot.st_dev == rootInfo.st_dev && actualRoot.st_ino == rootInfo.st_ino
            && fstatfs(descriptor, &fs) == 0
            && withUnsafeBytes(of: fs.f_fstypename, { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }) == "apfs"
        close(descriptor)
        guard usable else { throw BatchError.unsupported }

        let rootName = root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent
        let coordinator = Coordinator(
            root: Unit(path: rootPath, name: rootName, device: rootInfo.st_dev, inode: rootInfo.st_ino, parentUnit: -1, parentNode: -1),
            workers: max(2, ProcessInfo.processInfo.activeProcessorCount),
            progress: progress
        )
        DispatchQueue.concurrentPerform(iterations: coordinator.workers) { _ in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 8)
            defer { buffer.deallocate() }
            var catalog = KindCatalog()
            while let index = coordinator.next() {
                coordinator.finish(index, with: Result {
                    try scanUnit(index, coordinator: coordinator, device: rootInfo.st_dev,
                                 ignoreCreatorCode: ignoreCreatorCode, buffer: buffer, catalog: &catalog)
                })
            }
        }
        var (units, partials) = try coordinator.outcome(finishing: rootPath)
        return try merge(root: root, units: &units, partials: &partials, ignoreCreatorCode: ignoreCreatorCode)
    }

    private static func scanUnit(
        _ index: Int, coordinator: Coordinator, device rootDevice: Int32, ignoreCreatorCode: Bool,
        buffer: UnsafeMutableRawBufferPointer, catalog: inout KindCatalog
    ) throws -> Partial {
        let unit = coordinator.unit(index)
        var issues: [ScanIssue] = []
        var issueCount = 0
        var dataless = Set<Int>()
        let unitKind = index == 0 ? catalog.kind(name: unit.name, directory: true, symlink: false, alias: false) : 0
        var nodes = [FileNode(
            name: unit.name, parent: -1, kind: unitKind, device: unit.device, inode: unit.inode,
            isDirectory: true, logical: 0, allocated: 0, rawAllocated: 0, shared: 0
        )]

        func report(_ path: @autoclosure () -> String, _ code: Int32) {
            issueCount += 1
            if issues.count < 250 {
                issues.append(ScanIssue(path: path(), message: String(cString: strerror(code))))
            }
        }

        func path(for id: Int) -> String {
            var parts: [String] = []
            var current = id
            while current > 0 {
                parts.append(nodes[current].name)
                current = Int(nodes[current].parent)
            }
            return id == 0 ? unit.path : (unit.path == "/" ? unit.path : unit.path + "/") + parts.reversed().joined(separator: "/")
        }

        func partial() -> Partial {
            Partial(nodes: nodes, kinds: catalog.kinds, issues: issues, issueCount: issueCount)
        }

        let descriptor = unit.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            let code = errno
            if index == 0 { throw ScanError.filesystem(unit.path, code) }
            if code == EMFILE || code == ENFILE || code == ENAMETOOLONG { throw BatchError.unsupported }
            report(unit.path, code)
            return partial()
        }
        defer { close(descriptor) }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0, identity.st_dev == unit.device, identity.st_ino == unit.inode else {
            report(unit.path, ESTALE)
            return partial()
        }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        let common = UInt32(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID | ATTR_CMN_DEVID | ATTR_CMN_FLAGS)
        let file = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
        attributes.commonattr = common | UInt32(ATTR_CMN_ERROR) | ATTR_CMN_RETURNED_ATTRS
        if !ignoreCreatorCode {
            attributes.commonattr |= UInt32(ATTR_CMN_FNDRINFO | ATTR_CMN_ACCESSMASK)
        }
        attributes.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        attributes.fileattr = file
        attributes.forkattr = UInt32(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
        var options = UInt64(FSOPT_RETURN_REALDEV | FSOPT_ATTR_CMN_EXTENDED)

        func enumerate(_ fd: Int32, parent: Int) throws {
            while true {
                try coordinator.checkCancellation()
                let before = nodes.count
                var batchBytes: Int64 = 0
                let count = getattrlistbulk(fd, &attributes, buffer.baseAddress, buffer.count, options)
                if count == 0 { return }
                if count < 0 {
                    let code = errno
                    if code == EINVAL, attributes.forkattr != 0 {
                        attributes.forkattr = 0
                        options = UInt64(FSOPT_RETURN_REALDEV)
                        continue
                    }
                    if code == EACCES || code == EPERM {
                        if index == 0, parent == 0 { throw ScanError.filesystem(unit.path, code) }
                        report(path(for: parent), code)
                        return
                    }
                    throw BatchError.unsupported
                }

                var position = 0
                for _ in 0..<count {
                    guard position <= buffer.count - MemoryLayout<UInt32>.size else { throw BatchError.unsupported }
                    let size = Int(buffer.loadUnaligned(fromByteOffset: position, as: UInt32.self))
                    guard size >= 24, size <= buffer.count - position else { throw BatchError.unsupported }
                    let bytes = UnsafeRawBufferPointer(rebasing: buffer[position..<(position + size)])
                    position += size
                    var record = Record(bytes: bytes, offset: MemoryLayout<UInt32>.size)
                    let returned = try record.take(attribute_set_t.self)
                    let errorCode = returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0
                        ? Int32(bitPattern: try record.take(UInt32.self)) : 0
                    guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { throw BatchError.unsupported }
                    let nameReferenceOffset = record.offset
                    let reference = try record.take(attrreference_t.self)
                    let start = nameReferenceOffset + Int(reference.attr_dataoffset)
                    let length = Int(reference.attr_length)
                    guard start >= record.offset, length > 0, start <= size - length,
                          bytes[start + length - 1] == 0 else { throw BatchError.unsupported }
                    let namePointer = buffer.baseAddress!.advanced(by: position - size + start).assumingMemoryBound(to: CChar.self)
                    guard let name = String(validatingCString: namePointer) else {
                        report(path(for: parent), EILSEQ)
                        continue
                    }
                    let device = returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0 ? try record.take(Int32.self) : -1
                    let type = returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 ? try record.take(UInt32.self) : 0
                    var finder = FinderInfo()
                    if returned.commonattr & UInt32(ATTR_CMN_FNDRINFO) != 0 {
                        guard record.offset <= bytes.count - 32 else { throw BatchError.unsupported }
                        finder = FinderInfo(bytes: UnsafeRawBufferPointer(rebasing: bytes[record.offset..<(record.offset + 32)]))
                        record.offset += 32
                    }
                    var mode = returned.commonattr & UInt32(ATTR_CMN_ACCESSMASK) != 0 ? try record.take(UInt32.self) : 0
                    let flags = returned.commonattr & UInt32(ATTR_CMN_FLAGS) != 0 ? try record.take(UInt32.self) : 0
                    let inode = returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 ? try record.take(UInt64.self) : 0
                    let mount = returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 ? try record.take(UInt32.self) : 0
                    let metadata: Metadata
                    var entryFlags = flags
                    if errorCode == 0, returned.commonattr & common == common, device != -1,
                       flags & UInt32(SF_FIRMLINK) == 0, mount & UInt32(DIR_MNTSTATUS_MNTPOINT) == 0,
                       (type == VDIR.rawValue && returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0)
                       || (type == VREG.rawValue && returned.fileattr & file == file) {
                        if type == VDIR.rawValue {
                            metadata = Metadata(device: device, inode: inode, type: type, links: 0, logical: 0, allocated: 0)
                        } else {
                            let links = try record.take(UInt32.self)
                            let allocated = try record.take(Int64.self)
                            let logical = try record.take(Int64.self)
                            let clone = returned.forkattr & UInt32(ATTR_CMNEXT_CLONEID) != 0 ? try record.take(UInt64.self) : 0
                            let cloneReferences = returned.forkattr & UInt32(ATTR_CMNEXT_CLONE_REFCNT) != 0 ? try record.take(UInt32.self) : 0
                            metadata = Metadata(device: device, inode: inode, type: type, links: links, logical: logical, allocated: allocated,
                                                clone: clone, cloneReferences: cloneReferences)
                        }
                    } else {
                        var info = stat()
                        guard fstatat(fd, namePointer, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                            report(path(for: parent) + "/" + name, errno)
                            continue
                        }
                        metadata = Metadata(info)
                        mode = UInt32(info.st_mode)
                        entryFlags = info.st_flags
                    }
                    guard metadata.device == rootDevice else { continue }
                    guard nodes.count < Int32.max else { throw ScanError.tooManyEntries }
                    let id = nodes.count
                    let kind: Int32
                    if !ignoreCreatorCode, !metadata.symlink {
                        kind = catalog.finderKind(name: name, directory: metadata.directory, mode: mode, info: finder,
                                                  path: (parent == 0 && unit.path == "/" ? "" : path(for: parent)) + "/" + name)
                    } else {
                        kind = catalog.kind(name: name, directory: metadata.directory, symlink: metadata.symlink,
                                            alias: metadata.regular && name.hasSuffix(".alias"))
                    }
                    nodes.append(FileNode(
                        name: name, parent: Int32(parent), kind: kind, device: metadata.device, references: metadata.references, inode: metadata.inode,
                        isDirectory: metadata.directory, hardLinks: metadata.hardLinks, nextSibling: nodes[parent].firstChild,
                        logical: metadata.logical, allocated: metadata.allocated,
                        rawAllocated: metadata.allocated, shared: metadata.shared, fileCount: metadata.directory ? 0 : 1
                    ))
                    nodes[parent].firstChild = Int32(id)
                    batchBytes += metadata.allocated
                    if metadata.directory, entryFlags & UInt32(SF_DATALESS) != 0 { dataless.insert(id) }
                }
                coordinator.counted(nodes.count - before, bytes: batchBytes, path: path(for: parent))
            }
        }

        struct Frame {
            let fd: Int32
            var child: Int32
        }
        try enumerate(descriptor, parent: 0)
        var frames = [Frame(fd: descriptor, child: nodes[0].firstChild)]
        defer {
            for frame in frames.dropFirst() where frame.fd >= 0 { close(frame.fd) }
        }
        while let frame = frames.last {
            if frame.child < 0 {
                if frames.count > 1, frame.fd >= 0 { close(frame.fd) }
                frames.removeLast()
                continue
            }
            let id = Int(frame.child)
            let node = nodes[id]
            frames[frames.count - 1].child = node.nextSibling
            guard node.isDirectory, !dataless.contains(id) else { continue }
            if coordinator.offer(Unit(path: path(for: id), name: node.name, device: node.device, inode: node.inode,
                                      parentUnit: index, parentNode: id)) {
                continue
            }
            let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            let fd = frame.fd >= 0
                ? node.name.withCString { openat(frame.fd, $0, flags) }
                : path(for: id).withCString { open($0, flags) }
            guard fd >= 0 else {
                let code = errno
                if code == EMFILE || code == ENFILE || code == ENAMETOOLONG { throw BatchError.unsupported }
                report(path(for: id), code)
                continue
            }
            var identity = stat()
            guard fstat(fd, &identity) == 0, identity.st_dev == node.device, identity.st_ino == node.inode else {
                close(fd)
                report(path(for: id), ESTALE)
                continue
            }
            do {
                try enumerate(fd, parent: id)
            } catch {
                close(fd)
                throw error
            }
            if frames.count < 16 {
                frames.append(Frame(fd: fd, child: nodes[id].firstChild))
            } else {
                close(fd)
                frames.append(Frame(fd: -1, child: nodes[id].firstChild))
            }
        }
        return partial()
    }

    private static func merge(root: URL, units: inout [Unit], partials: inout [Partial], ignoreCreatorCode: Bool) throws -> ScanSummary {
        let total = partials.reduce(1) { $0 + $1.nodes.count - 1 }
        guard total < Int32.max else { throw ScanError.tooManyEntries }
        var kinds: [FileKind] = []
        var kindIndex: [FileKind: Int32] = [:]
        var nodes: [FileNode] = []
        nodes.reserveCapacity(total)
        var roots = [Int](repeating: 0, count: units.count)
        var bases = [Int](repeating: 0, count: units.count)
        var seenLinks = Set<Inode>()
        var issues: [ScanIssue] = []
        var issueCount = 0

        for index in partials.indices {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let partial = partials[index]
            partials[index] = Partial(nodes: [], kinds: [], issues: [], issueCount: 0)
            let kindMap = partial.kinds.map { kind -> Int32 in
                if let existing = kindIndex[kind] { return existing }
                let id = Int32(kinds.count)
                kinds.append(kind)
                kindIndex[kind] = id
                return id
            }
            if index == 0 {
                var rootNode = partial.nodes[0]
                rootNode.kind = kindMap[Int(rootNode.kind)]
                nodes.append(rootNode)
            } else {
                let unit = units[index]
                roots[index] = unit.parentNode == 0 ? roots[unit.parentUnit] : bases[unit.parentUnit] + unit.parentNode - 1
            }
            let base = nodes.count
            bases[index] = base
            let rootID = roots[index]
            func global(_ local: Int32) -> Int32 {
                local < 0 ? -1 : local == 0 ? Int32(rootID) : Int32(base + Int(local) - 1)
            }
            nodes[rootID].firstChild = global(partial.nodes[0].firstChild)
            for local in partial.nodes.indices.dropFirst() {
                var node = partial.nodes[local]
                node.parent = global(node.parent)
                node.firstChild = global(node.firstChild)
                node.nextSibling = global(node.nextSibling)
                node.kind = kindMap[Int(node.kind)]
                if node.isShared, !seenLinks.insert(Inode(device: node.device, number: node.shared)).inserted {
                    node.allocated = 0
                }
                nodes.append(node)
            }
            issueCount += partial.issueCount
            if issues.count < 250 { issues.append(contentsOf: partial.issues.prefix(250 - issues.count)) }
        }

        for id in nodes.indices.reversed() where id > 0 {
            if id.isMultiple(of: 1024) { try Task.checkCancellation() }
            let parent = Int(nodes[id].parent)
            nodes[parent].logical += nodes[id].logical
            nodes[parent].allocated += nodes[id].allocated
            nodes[parent].fileCount += nodes[id].fileCount
        }
        let volume = (try? root.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true ? VolumeUsage.read(root) : nil
        return ScanSummary(root: root, nodes: nodes, kinds: kinds, issues: issues, issueCount: issueCount,
                           volume: volume, ignoreCreatorCode: ignoreCreatorCode, traversal: .bulk)
    }
}

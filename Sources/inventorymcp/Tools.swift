import Foundation
import InventoryCore

func syncTool(_ name: String, _ description: String, _ schema: [String: Any], _ body: @escaping (Params) throws -> Any) -> Tool {
    Tool(name: name, description: description, schema: schema) { params, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                completion(.success(try body(params)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

private let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
}()

func human(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }

func percent(_ part: Int64, of total: Int64) -> Any {
    total > 0 ? (Double(part) / Double(total) * 1000).rounded() / 10 : NSNull()
}

func resolvePath(_ raw: String) -> String {
    let url = URL(filePath: (raw as NSString).expandingTildeInPath).standardizedFileURL
    return url.path.isEmpty ? "/" : url.path
}

func sizeArgument(_ params: Params, _ key: String, fallback: Int64) throws -> Int64 {
    guard let text = params.string(key) else { return fallback }
    let normalized = text.uppercased().replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
    let units: [(String, Int64)] = [
        ("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10),
        ("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10), ("B", 1),
    ]
    let unit = units.first { normalized.hasSuffix($0.0) }
    let digits = normalized.dropLast(unit?.0.count ?? 0)
    let factor = unit?.1 ?? 1
    if let integer = Int64(digits), integer >= 0 {
        let (bytes, overflow) = integer.multipliedReportingOverflow(by: factor)
        if !overflow { return bytes }
    }
    guard let value = Double(digits), value >= 0,
          let bytes = Int64(exactly: (value * Double(factor)).rounded(.towardZero)) else {
        throw ToolFailure("\(key) must be a size in range; use bytes or a suffix such as 500M or 2G")
    }
    return bytes
}

func hasFullDiskAccess() -> Bool {
    let descriptor = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
    guard descriptor >= 0 else { return false }
    close(descriptor)
    return true
}

struct StoredScan {
    let snapshot: ScanSummary
    let path: String
    let finderKinds: Bool
    let seconds: Double
    let finishedAt: Date
    let held: [Int: Int64]
    var cached = false

    func isFresh(at date: Date, maxAge: Double) -> Bool {
        date.timeIntervalSince(finishedAt) <= maxAge
    }

    var summary: [String: Any] {
        let root = snapshot.nodes[0]
        return [
            "path": path,
            "entries": snapshot.nodes.count,
            "files": root.fileCount,
            "allocated": root.allocated,
            "allocated_h": human(root.allocated),
            "logical": root.logical,
            "logical_h": human(root.logical),
            "skipped": snapshot.issueCount,
            "traversal": snapshot.traversal.rawValue,
            "finder_kinds": finderKinds,
            "cached": cached,
            "scanned_in_seconds": (seconds * 10).rounded() / 10,
            "finished_at": finishedAt,
        ]
    }
}

final class ScanStore {
    static let defaultMaxAge: Double = 1800
    static let retention: Double = 86_400

    private struct Key: Hashable {
        let path: String
        let finderKinds: Bool
    }

    private final class Job {
        let finished = DispatchGroup()
        let started = ContinuousClock.now
        var superseded = false
        var task: Task<Void, Never>?
        var result: Result<StoredScan, Error>?
        var waiters = 0

        init() { finished.enter() }
    }

    private let lock = NSLock()
    private var scans: [Key: StoredScan] = [:]
    private var jobs: [Key: Job] = [:]
    private let snapshotLimit = 4
    private let nodeLimit = 4_000_000
    private let eviction = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

    init() {
        eviction.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60))
        eviction.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.prune(at: .now) }
        }
        eviction.resume()
    }

    deinit { eviction.cancel() }

    func scan(path: String, finderKinds: Bool, refresh: Bool, maxAge: Double, timeout: Double) throws -> StoredScan {
        let key = Key(path: path, finderKinds: finderKinds)
        let detailed = Key(path: path, finderKinds: true)
        let deadline = DispatchTime.now() + timeout
        let (cached, job): (StoredScan?, Job?) = lock.withLock {
            let now = Date()
            prune(at: now)
            if !refresh,
               let cached = [scans[key], scans[detailed]].compactMap({ $0 })
                   .filter({ $0.isFresh(at: now, maxAge: maxAge) }).max(by: { $0.finishedAt < $1.finishedAt }) {
                return (cached, nil)
            }
            if let job = jobs[key] ?? jobs[detailed] {
                guard job.waiters > 0 else { return (nil, nil) }
                job.waiters += 1
                return (nil, job)
            }
            let job = Job()
            job.waiters = 1
            jobs[key] = job
            job.task = Task.detached(priority: .userInitiated) {
                let started = ContinuousClock.now
                let result = Result {
                    let snapshot = try InventoryScanner.scan(URL(filePath: path, directoryHint: .isDirectory),
                                                             ignoreCreatorCode: !finderKinds)
                    let held = snapshot.heldByClones()
                    let duration = started.duration(to: .now).components
                    return StoredScan(snapshot: snapshot, path: path, finderKinds: finderKinds,
                                      seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                                      finishedAt: .now, held: held)
                }
                self.lock.withLock {
                    if job.waiters > 0, !job.superseded, case var .success(scan) = result {
                        for (otherKey, other) in self.jobs where otherKey.path == key.path && other.started < job.started {
                            other.superseded = true
                        }
                        scan.cached = self.cache(scan, for: key)
                        job.result = .success(scan)
                    } else {
                        job.result = result
                    }
                    job.task = nil
                    self.jobs.removeValue(forKey: key)
                    job.finished.leave()
                }
            }
            return (nil, job)
        }
        if let cached { return cached }
        guard let job else { throw ToolFailure("the previous scan of \(path) is still stopping; retry shortly") }
        let completed = job.finished.wait(timeout: deadline) == .success
        return try lock.withLock {
            job.waiters -= 1
            if completed, let result = job.result { return try result.get() }
            if job.waiters == 0 { job.task?.cancel() }
            throw ToolFailure("the scan of \(path) was still running after \(timeout) s; raise max_seconds or scan a smaller folder")
        }
    }

    private func prune(at date: Date) {
        scans = scans.filter { $0.value.isFresh(at: date, maxAge: Self.retention) }
    }

    private func cache(_ scan: StoredScan, for key: Key) -> Bool {
        scans = scans.filter { $0.key.path != key.path }
        guard scan.snapshot.nodes.count <= nodeLimit else { return false }
        prune(at: scan.finishedAt)
        var retained = scan
        retained.cached = true
        scans[key] = retained
        var nodes = scans.values.reduce(0) { $0 + $1.snapshot.nodes.count }
        for (oldest, value) in scans.sorted(by: { $0.value.finishedAt < $1.value.finishedAt }) {
            if scans.count <= snapshotLimit, nodes <= nodeLimit { break }
            scans.removeValue(forKey: oldest)
            nodes -= value.snapshot.nodes.count
        }
        return scans[key] != nil
    }

    func recent(maxAge: Double = retention) -> [StoredScan] {
        lock.withLock {
            let now = Date()
            prune(at: now)
            return scans.values.filter { $0.isFresh(at: now, maxAge: maxAge) }.sorted { $0.finishedAt > $1.finishedAt }
        }
    }
}

func scanArguments(_ params: Params, store: ScanStore, defaultPath: String = "~") throws -> StoredScan {
    let path = resolvePath(params.string("path") ?? defaultPath)
    let finderKinds = try params.flag("finder_kinds", fallback: false)
    let maxAge = try params.seconds("max_age_seconds", fallback: ScanStore.defaultMaxAge, limit: ScanStore.retention)
    let refresh = try params.flag("refresh", fallback: false)
    let maxSeconds = try params.seconds("max_seconds", fallback: 120, limit: 1800)
    return try store.scan(path: path, finderKinds: finderKinds, refresh: refresh, maxAge: maxAge, timeout: maxSeconds)
}

let scanProperties: [String: Any] = [
    "path": Schema.text("folder or volume to scan (default ~); the boot volume is /System/Volumes/Data"),
    "finder_kinds": Schema.boolean("name file kinds the way Finder does (slower)"),
    "refresh": Schema.boolean("scan again instead of reusing the scan this server holds"),
    "max_age_seconds": Schema.number("reuse a scan younger than this (default 1800)"),
    "max_seconds": Schema.number("give up on a new scan after this many seconds (default 120, max 1800)"),
]

func withScanProperties(_ properties: [String: Any]) -> [String: Any] {
    properties.merging(scanProperties) { own, _ in own }
}

func sizeMode(_ params: Params) throws -> SizeMode {
    try params.choice("mode", options: ["allocated", "logical"], fallback: "allocated") == "logical" ? .logical : .allocated
}

func focus(_ params: Params, in scan: StoredScan) throws -> Int {
    guard let under = params.string("under") else { return 0 }
    let absolute = under.hasPrefix("/") || under.hasPrefix("~") ? resolvePath(under) : scan.path + "/" + under
    guard let id = scan.snapshot.locate(absolute) else { throw ToolFailure("\(under) is not inside the scan of \(scan.path)") }
    return id
}

func entryJSON(_ scan: StoredScan, _ id: Int, mode: SizeMode, total: Int64) -> [String: Any] {
    let snapshot = scan.snapshot
    let node = snapshot.nodes[id]
    let size = node.size(mode)
    var json: [String: Any] = [
        "path": snapshot.displayPath(of: id),
        "size": size,
        "size_h": human(size),
        "kind": snapshot.kinds[Int(node.kind)].title,
        "share_percent": percent(size, of: total),
    ]
    if node.isDirectory { json["files"] = node.fileCount }
    if mode == .allocated, let held = scan.held[id], held > 0 {
        json["frees_if_deleted"] = snapshot.reclaimable(id, held: scan.held)
        json["frees_if_deleted_h"] = human(snapshot.reclaimable(id, held: scan.held))
    }
    return json
}

func subtree(_ snapshot: ScanSummary, from root: Int, _ visit: (Int) -> Void) {
    var stack = [root]
    while let id = stack.popLast() {
        var child = snapshot.nodes[id].firstChild
        while child >= 0 {
            visit(Int(child))
            if snapshot.nodes[Int(child)].isDirectory { stack.append(Int(child)) }
            child = snapshot.nodes[Int(child)].nextSibling
        }
    }
}

func largest(_ snapshot: ScanSummary, from root: Int, limit: Int, mode: SizeMode, where include: (FileNode) -> Bool) -> [Int] {
    var best: [(size: Int64, id: Int)] = []
    subtree(snapshot, from: root) { id in
        let node = snapshot.nodes[id]
        guard include(node) else { return }
        let size = node.size(mode)
        if best.count == limit, let last = best.last, size <= last.size { return }
        let position = best.firstIndex { size > $0.size } ?? best.count
        best.insert((size, id), at: position)
        if best.count > limit { best.removeLast() }
    }
    return best.map(\.id)
}

private let formatterISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
}()


func adviceSize(_ path: String, store: ScanStore) -> Int64 {
    for scan in store.recent(maxAge: ScanStore.defaultMaxAge) {
        if let id = scan.snapshot.locate(path) { return scan.snapshot.reclaimable(id, held: scan.held) }
    }
    return InventoryScanner.reclaimableSize(at: URL(filePath: path))
}

func adviceJSON(_ sheet: AdviceSheet?) -> [String: Any] {
    guard let sheet else { return ["advice": NSNull()] }
    let pending = sheet.items.filter { $0.status == .pending }
    return [
        "title": sheet.title,
        "summary": sheet.summary,
        "updated_at": sheet.updatedAt,
        "pending_size_h": human(pending.filter { $0.verdict != .keep }.reduce(0) { $0 + $1.size }),
        "items": sheet.items.map { item in
            [
                "id": item.id.uuidString,
                "path": item.path,
                "size": item.size,
                "size_h": human(item.size),
                "verdict": item.verdict.rawValue,
                "reason": item.reason,
                "status": item.status.rawValue,
                "status_at": item.statusAt as Any,
                "title": item.title,
                "action": item.action as Any,
                "argument": item.argument as Any,
                "command": item.action.flatMap { AdviceActions.definition($0)?.commandLine(item.argument) } as Any,
                "output": item.output.map { String($0.suffix(2000)) } as Any,
            ] as [String: Any]
        },
    ]
}

func showCleanupInApp() -> String {
    AdviceStore.post(AdviceStore.showNotification)
    let executable = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().appending(path: "Disk Inventory.app", directoryHint: .isDirectory)
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/open")
    process.arguments = FileManager.default.fileExists(atPath: bundle.path)
        ? ["-a", bundle.path, "--args", "--cleanup"] : ["-b", "local.diskinventory.app", "--args", "--cleanup"]
    try? process.run()
    process.waitUntilExit()
    return FileManager.default.fileExists(atPath: bundle.path) ? bundle.path : "local.diskinventory.app"
}

private let verdictDescription = "safe: apps recreate it on their own; regenerable: rebuilt or downloaded again on demand; review: probably unneeded but the user should look; keep: explain why it must stay"

func makeTools(_ store: ScanStore) -> [Tool] {
    [
        syncTool(
            "inventory_status",
            "Whether this server can read protected folders, which cloud folders (iCloud Drive, Google Drive, OneDrive, Dropbox) are set up on this Mac, and the scans it holds.",
            Schema.object([:])
        ) { _ in
            [
                "full_disk_access": hasFullDiskAccess(),
                "cloud_destinations": CloudOffload.destinations().map { ["service": $0.service.rawValue, "title": $0.title, "root": $0.root.path] },
                "scans_in_memory": store.recent().map(\.summary),
            ]
        },

        syncTool(
            "inventory_scan",
            "Scan a folder or volume the way Disk Inventory does: every file and folder is kept, read in parallel with getattrlistbulk on APFS. Returns totals and the biggest top-level items; the other inventory_* tools reuse this scan.",
            Schema.object(withScanProperties([
                "limit": Schema.integer("top-level items to list (default 12)"),
            ]))
        ) { params in
            let limit = try params.count("limit", fallback: 12, limit: 100)
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let total = snapshot.nodes[0].allocated
            let children = snapshot.largestChildren(of: 0, mode: .allocated, limit: limit)
            return [
                "scan": scan.summary,
                "top": children.ids.map { entryJSON(scan, $0, mode: .allocated, total: total) },
                "skipped_examples": snapshot.issues.prefix(15).map { ["path": $0.path, "reason": $0.message] },
            ]
        },

        syncTool(
            "inventory_children",
            "The items directly inside one folder of a scan, biggest first — for walking the tree level by level.",
            Schema.object(withScanProperties([
                "under": Schema.text("folder inside the scan, absolute or relative to its root (default the root)"),
                "limit": Schema.integer("items to return (default 25, max 500)"),
                "mode": Schema.choice("size on disk or logical size (default allocated)", ["allocated", "logical"]),
            ]))
        ) { params in
            let limit = try params.count("limit", fallback: 25, limit: 500)
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let id = try focus(params, in: scan)
            let mode = try sizeMode(params)
            let total = snapshot.nodes[id].size(mode)
            let children = snapshot.largestChildren(of: id, mode: mode, limit: limit)
            return [
                "folder": entryJSON(scan, id, mode: mode, total: total),
                "count": children.count,
                "items": children.ids.map { entryJSON(scan, $0, mode: mode, total: total) },
            ]
        },

        syncTool(
            "inventory_top",
            "The biggest files or folders anywhere under a folder of the scan. Every file is in the scan, so a single huge file deep inside shows up by name.",
            Schema.object(withScanProperties([
                "under": Schema.text("folder inside the scan (default the root)"),
                "kind": Schema.choice("files, folders or both (default files)", ["files", "folders", "both"]),
                "limit": Schema.integer("items to return (default 25, max 500)"),
                "mode": Schema.choice("size on disk or logical size (default allocated)", ["allocated", "logical"]),
            ]))
        ) { params in
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let id = try focus(params, in: scan)
            let mode = try sizeMode(params)
            let kind = try params.choice("kind", options: ["files", "folders", "both"], fallback: "files")
            let limit = try params.count("limit", fallback: 25, limit: 500)
            let ids = largest(snapshot, from: id, limit: limit, mode: mode) { node in
                kind == "both" || (kind == "folders") == node.isDirectory
            }
            let total = snapshot.nodes[id].size(mode)
            return ["under": snapshot.displayPath(of: id), "kind": kind, "items": ids.map { entryJSON(scan, $0, mode: mode, total: total) }]
        },

        syncTool(
            "inventory_kinds",
            "Space by file kind (video, disk images, Swift source, …) under a folder of the scan, like the Kinds panel of Disk Inventory, with the biggest file of each kind.",
            Schema.object(withScanProperties([
                "under": Schema.text("folder inside the scan (default the root)"),
                "limit": Schema.integer("kinds to return (default 20, max 200)"),
                "mode": Schema.choice("size on disk or logical size (default allocated)", ["allocated", "logical"]),
            ]))
        ) { params in
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let id = try focus(params, in: scan)
            let mode = try sizeMode(params)
            let limit = try params.count("limit", fallback: 20, limit: 200)
            var totals: [Int: (size: Int64, count: Int, biggest: Int)] = [:]
            subtree(snapshot, from: id) { child in
                let node = snapshot.nodes[child]
                guard !node.isDirectory else { return }
                let kind = Int(node.kind)
                var entry = totals[kind] ?? (0, 0, child)
                entry.size += node.size(mode)
                entry.count += 1
                if node.size(mode) > snapshot.nodes[entry.biggest].size(mode) { entry.biggest = child }
                totals[kind] = entry
            }
            let total = snapshot.nodes[id].size(mode)
            return [
                "under": snapshot.displayPath(of: id),
                "kinds": totals.sorted { $0.value.size > $1.value.size }.prefix(limit).map { kind, entry in
                    [
                        "kind": snapshot.kinds[kind].title,
                        "size": entry.size,
                        "size_h": human(entry.size),
                        "files": entry.count,
                        "share_percent": percent(entry.size, of: total),
                        "biggest": entryJSON(scan, entry.biggest, mode: mode, total: total),
                    ]
                },
            ]
        },

        syncTool(
            "inventory_search",
            "Find files in the scan by name, kind or path fragment, biggest first.",
            Schema.object(withScanProperties([
                "query": Schema.text("text to look for"),
                "field": Schema.choice("where to look (default all)", ["all", "name", "kind", "path"]),
                "packages": Schema.boolean("search inside app bundles and other packages (default true)"),
                "limit": Schema.integer("matches to return (default 30, max 500)"),
                "mode": Schema.choice("size on disk or logical size (default allocated)", ["allocated", "logical"]),
            ]), required: ["query"])
        ) { params in
            let limit = try params.count("limit", fallback: 30, limit: 500)
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let query = try params.requiredString("query")
            let field: SearchField = switch try params.choice("field", options: ["all", "name", "kind", "path"], fallback: "all") {
            case "name": .name
            case "kind": .kind
            case "path": .path
            default: .all
            }
            var options = ViewOptions()
            options.mode = try sizeMode(params)
            options.packages = try params.flag("packages", fallback: true)
            let matches = try snapshot.search(query, field: field, kind: nil, options: options, limit: limit)
            let total = snapshot.nodes[0].size(options.mode)
            return ["found": matches.count, "items": matches.ids.map { entryJSON(scan, $0, mode: options.mode, total: total) }]
        },

        syncTool(
            "inventory_cleanup",
            "What can be removed, sorted by how safe it is: safe (caches, logs, Trash — apps recreate them), regenerable (build artifacts, package caches, Xcode data — rebuilt or downloaded again) and review (installers, local AI models, device backups, simulators — needs a look). Read-only: nothing is deleted.",
            Schema.object(withScanProperties([
                "safety": ["type": "array", "items": ["type": "string", "enum": ["safe", "regenerable", "review"]],
                           "description": "levels to include (default all)"],
                "limit": Schema.integer("items to list per category (default 8, max 200)"),
            ]))
        ) { params in
            let scan = try scanArguments(params, store: store)
            let snapshot = scan.snapshot
            let wanted = Set(params.list("safety"))
            let limit = try params.count("limit", fallback: 8, limit: 200)
            let groups = CleanupAnalyzer.analyze(snapshot).filter { wanted.isEmpty || wanted.contains($0.category.safety.rawValue) }
            var totals: [String: Int64] = [:]
            for group in groups { totals[group.category.safety.rawValue, default: 0] += group.size }
            return [
                "scan": scan.summary,
                "totals": totals.mapValues { ["size": $0, "size_h": human($0)] },
                "categories": groups.map { group in
                    [
                        "id": group.category.id,
                        "title": group.category.title,
                        "safety": group.category.safety.rawValue,
                        "why": group.category.explanation,
                        "size": group.size,
                        "size_h": human(group.size),
                        "items_count": group.items.count,
                        "items": group.items.prefix(limit).map { item in
                            ["path": snapshot.displayPath(of: item.node), "size": item.size, "size_h": human(item.size)]
                        },
                    ] as [String: Any]
                },
            ]
        },

        syncTool(
            "inventory_stale",
            "Big files in Desktop, Documents, Downloads, Movies, Music and Pictures that have not been opened or changed for a long time — candidates to move to iCloud Drive or Google Drive. The date is the latest of last opened (Spotlight), modified and added. Lists the cloud folders set up on this Mac. Read-only.",
            Schema.object(withScanProperties([
                "days": Schema.number("not touched for at least this many days (default 180)"),
                "min_size": Schema.size("smallest file to report (default 100M)"),
                "limit": Schema.integer("files to return (default 30, max 500)"),
            ]))
        ) { params in
            let days = min(max(try params.number("days") ?? 180, 1), 3650)
            let minSize = try sizeArgument(params, "min_size", fallback: 100 << 20)
            let limit = try params.count("limit", fallback: 30, limit: 500)
            let scan = try scanArguments(params, store: store)
            let stale = CloudOffload.staleFiles(in: scan.snapshot, minSize: minSize, olderThanDays: days)
            let total = stale.reduce(Int64(0)) { $0 + $1.size }
            let inICloud = stale.filter(\.isInICloud).reduce(Int64(0)) { $0 + $1.size }
            return [
                "days": days,
                "min_size": minSize,
                "found": stale.count,
                "total_size": total,
                "total_size_h": human(total),
                "already_in_icloud_size_h": human(inICloud),
                "cloud_destinations": CloudOffload.destinations().map { ["service": $0.service.rawValue, "title": $0.title, "root": $0.root.path] },
                "files": stale.prefix(limit).map { file in
                    [
                        "path": file.path,
                        "size": file.size,
                        "size_h": human(file.size),
                        "last_activity": file.lastActivity.map { formatterISO.string(from: $0) } as Any,
                        "last_opened": file.lastUsed.map { formatterISO.string(from: $0) } as Any,
                        "in_icloud": file.isInICloud,
                    ]
                },
            ]
        },

        syncTool(
            "inventory_advise",
            "Send your cleanup analysis to the Disk Inventory app: each item appears in the Clean Up tab with its size, your verdict and your reason, and the user decides there. Nothing is deleted or run by this tool. An item is either a path, which the user can move to the Trash, or an action from the allowlist in inventory_system (Homebrew cleanup, simulator and runtime deletion, Docker prune, emptying the Trash), which the user can run with one click after seeing the exact command. Whole top-level folders such as ~/Library or ~/Documents are refused; outside the home folder caches, logs and temporary files (/Library/Caches, /Library/Logs, /private/tmp, /private/var/folders of this user, /Users/Shared) take any verdict, apps in /Applications and vendor folders in /Library only review, and /System, /usr, /opt/homebrew and system configuration are refused. Opens the app on the Clean Up tab unless show is false.",
            Schema.object([
                "title": Schema.text("heading shown above your advice, e.g. what the user asked"),
                "summary": Schema.text("two or three sentences: what fills the disk and what is safe to remove"),
                "items": [
                    "type": "array",
                    "description": "one entry per file or folder",
                    "items": [
                        "type": "object",
                        "properties": [
                            "path": Schema.text("absolute path or ~/…; for an action, optionally the folder it frees space in"),
                            "action": Schema.choice("instead of a path: an allowlisted command the user can run from the app", AdviceActions.all.map(\.id)),
                            "argument": Schema.text("the action's argument: cask name, simulator UDID or runtime identifier"),
                            "title": Schema.text("short name shown in bold, in the user's language; defaults to the file name or the action's English title"),
                            "verdict": Schema.choice(verdictDescription, AdviceVerdict.allCases.map(\.rawValue)),
                            "reason": Schema.text("why, in the user's language: what it is, what happens after removal, how to get it back"),
                        ],
                        "required": ["verdict", "reason"],
                        "additionalProperties": false,
                    ],
                ],
                "append": Schema.boolean("add to the advice already shown instead of replacing it"),
                "show": Schema.boolean("bring the app forward on the Clean Up tab (default true)"),
            ], required: ["items"])
        ) { params in
            let raw = params.raw["items"] as? [[String: Any]] ?? []
            guard !raw.isEmpty else { throw ToolFailure("items is required") }
            var accepted: [AdviceItem] = []
            var refused: [[String: Any]] = []
            for entry in raw {
                guard let verdict = (entry["verdict"] as? String).flatMap(AdviceVerdict.init(rawValue:)) else {
                    refused.append(["item": String(describing: entry), "why": "a valid verdict is required"])
                    continue
                }
                if let action = entry["action"] as? String {
                    let argument = entry["argument"] as? String
                    if let refusal = AdviceActions.refusal(action, argument: argument) {
                        refused.append(["action": action, "why": refusal])
                        continue
                    }
                    let path = (entry["path"] as? String).map(AdviceGuard.normalize) ?? ""
                    var item = AdviceItem(path: path, size: AdviceActions.estimate(action, argument: argument), verdict: verdict,
                                          reason: (entry["reason"] as? String) ?? "", action: action, argument: argument,
                                          label: entry["title"] as? String)
                    if item.size == 0, !path.isEmpty { item.size = adviceSize(path, store: store) }
                    accepted.append(item)
                    continue
                }
                guard let given = entry["path"] as? String else {
                    refused.append(["item": String(describing: entry), "why": "a path or an action is required"])
                    continue
                }
                let path = AdviceGuard.normalize(given)
                if let refusal = AdviceGuard.refusal(for: path, verdict: verdict) {
                    refused.append(["path": path, "why": "\(path) \(refusal)"])
                    continue
                }
                let url = URL(filePath: path)
                let identity = AdviceTrash.Identity(url: url)
                let size = adviceSize(path, store: store)
                guard verdict == .keep || (identity != nil && AdviceTrash.Identity(url: url) == identity) else {
                    refused.append(["path": path, "why": "the item changed while the advice was being prepared"])
                    continue
                }
                accepted.append(AdviceItem(path: path, size: size, verdict: verdict,
                                           reason: (entry["reason"] as? String) ?? "", label: entry["title"] as? String,
                                           fileIdentity: identity))
            }
            let append = try params.flag("append", fallback: false)
            let sheet = try AdviceStore.update { sheet in
                var items = append ? sheet?.items ?? [] : []
                var index: [String: Int] = [:]
                for (offset, item) in items.enumerated() where index[item.key] == nil { index[item.key] = offset }
                for item in accepted {
                    if let offset = index[item.key] {
                        let prior = items[offset]
                        if prior.isRemovable, item.fileIdentity != nil, prior.fileIdentity != item.fileIdentity {
                            items[offset] = item
                        }
                    } else {
                        index[item.key] = items.count
                        items.append(item)
                    }
                }
                sheet = AdviceSheet(
                    title: params.string("title") ?? sheet?.title ?? "Cleanup advice",
                    summary: params.string("summary") ?? (append ? sheet?.summary ?? "" : ""),
                    author: "Claude", items: items)
            }
            let opened = try params.flag("show", fallback: true) ? showCleanupInApp() : nil
            return [
                "accepted": accepted.count,
                "accepted_size_h": human(accepted.filter { $0.verdict != .keep }.reduce(0) { $0 + $1.size }),
                "refused": refused,
                "opened": opened as Any,
                "advice": adviceJSON(sheet),
            ]
        },

        syncTool(
            "inventory_advice",
            "The advice currently shown in the app and what the user did with each item: pending, trashed (moved to the Trash from the app), kept (the user chose to keep it), missing (gone from disk), done or failed (an action the user ran, with its output).",
            Schema.object([:])
        ) { _ in
            let sheet = try AdviceStore.update { sheet in
                guard var current = sheet else { return }
                for index in current.items.indices where current.items[index].isRemovable
                    && !FileManager.default.fileExists(atPath: current.items[index].path) {
                    current.items[index].status = .missing
                    current.items[index].statusAt = .now
                }
                sheet = current
            }
            return adviceJSON(sheet)
        },

        syncTool(
            "inventory_advice_clear",
            "Remove the advice from the app: everything, or only items the user already handled.",
            Schema.object(["handled_only": Schema.boolean("keep pending items and drop trashed, kept and missing ones")])
        ) { params in
            let handledOnly = try params.flag("handled_only", fallback: false)
            let sheet = try AdviceStore.update { sheet in
                guard handledOnly, var current = sheet else {
                    sheet = nil
                    return
                }
                current.items.removeAll { $0.status != .pending }
                sheet = current.items.isEmpty ? nil : current
            }
            return adviceJSON(sheet)
        },

        syncTool(
            "inventory_system",
            "What takes space outside the home folder, measured exactly: /Library/Caches, /Library/Logs, simulator caches, this user's temporary and cache folders in /private/var/folders, /private/tmp, /Users/Shared, the Trash, simulator runtimes and simulators with the ones that use each runtime, Homebrew (cleanup estimate, biggest casks), Docker, local Time Machine snapshots, and the 60 biggest apps with the days since each was last launched. Also lists the actions inventory_advise accepts. Read-only; takes a minute or two.",
            Schema.object([:])
        ) { _ in
            SystemSurvey.report { adviceSize($0, store: store) }
        },

        syncTool(
            "inventory_show_cleanup",
            "Bring Disk Inventory forward on the Clean Up tab, launching it if needed.",
            Schema.object([:])
        ) { _ in
            ["opened": showCleanupInApp()]
        },
    ]
}

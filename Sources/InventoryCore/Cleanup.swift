import CoreServices
import Darwin
import Foundation

public enum CleanupSafety: String, CaseIterable, Sendable {
    case safe, regenerable, review

    public var title: String {
        switch self {
        case .safe: "Safe to Remove"
        case .regenerable: "Rebuilt on Demand"
        case .review: "Worth a Look"
        }
    }
}

public struct CleanupCategory: Hashable, Sendable {
    public let id: String
    public let title: String
    public let explanation: String
    public let safety: CleanupSafety
}

public struct CleanupItem: Sendable {
    public let node: Int
    public let category: CleanupCategory
    public let size: Int64
}

public struct CleanupGroup: Sendable {
    public let category: CleanupCategory
    public let items: [CleanupItem]

    public var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct CleanupSelection {
    public struct Item: Equatable, Sendable {
        public let path: String
        public let size: Int64
        public let node: Int?
        public let fileIdentity: AdviceTrash.Identity?

        public init(path: String, size: Int64, node: Int? = nil, fileIdentity: AdviceTrash.Identity? = nil) {
            self.path = path
            self.size = size
            self.node = node
            self.fileIdentity = fileIdentity
        }
    }

    private let kept: Set<String>
    private let containsKept: Set<String>

    public init(kept: Set<String>) {
        self.kept = kept
        containsKept = Set(kept.flatMap(Self.ancestors))
    }

    public func protects(_ path: String) -> Bool {
        !kept.isEmpty && (kept.contains(path) || containsKept.contains(path) || Self.ancestors(path).contains(where: kept.contains))
    }

    public func collapse(_ items: [Item]) -> [Item] {
        let eligible = items.filter { !protects($0.path) }
        let paths = Set(eligible.map(\.path))
        var seen = Set<String>()
        return eligible.filter { item in
            seen.insert(item.path).inserted && !Self.ancestors(item.path).contains(where: paths.contains)
        }
    }

    public static func contains(_ ancestor: String, _ path: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    private static func ancestors(_ path: String) -> [String] {
        guard path != "/" else { return [] }
        var parents: [String] = []
        var rest = path[...]
        while let slash = rest.lastIndex(of: "/") {
            rest = rest[..<slash]
            parents.append(rest.isEmpty ? "/" : String(rest))
        }
        return parents
    }
}

public enum CleanupCategories {
    public static let trash = CleanupCategory(
        id: "trash", title: "Trash",
        explanation: "Already thrown away; the space comes back only when the Trash is emptied.", safety: .safe)
    public static let caches = CleanupCategory(
        id: "caches", title: "App Caches",
        explanation: "Apps recreate their caches; the first launch afterwards may be slower.", safety: .safe)
    public static let logs = CleanupCategory(
        id: "logs", title: "App Logs",
        explanation: "Only needed to investigate crashes; apps start new ones.", safety: .safe)
    public static let simulatorCaches = CleanupCategory(
        id: "simulator-caches", title: "Simulator Caches",
        explanation: "Xcode rebuilds them the next time a simulator starts.", safety: .safe)
    public static let systemCaches = CleanupCategory(
        id: "system-caches", title: "System Caches and Logs",
        explanation: "Shared caches and logs in /Library, rebuilt by the apps that wrote them. Items you lack permission to move stay in place.", safety: .regenerable)
    public static let derivedData = CleanupCategory(
        id: "derived-data", title: "Xcode DerivedData",
        explanation: "Intermediate build files; Xcode builds the project again, which takes time.", safety: .regenerable)
    public static let deviceSupport = CleanupCategory(
        id: "device-support", title: "Device Support Files",
        explanation: "Xcode copies them again when a device with that OS version is connected.", safety: .regenerable)
    public static let toolCaches = CleanupCategory(
        id: "tool-caches", title: "Package Manager Caches",
        explanation: "npm, uv, pip, Gradle, Cargo and others download packages again on the next build.", safety: .regenerable)
    public static let buildArtifacts = CleanupCategory(
        id: "build-artifacts", title: "Project Build Artifacts",
        explanation: "node_modules, .build, target, virtual environments: the project's install or build command recreates them.", safety: .regenerable)
    public static let models = CleanupCategory(
        id: "models", title: "Local AI Models",
        explanation: "They can be downloaded again, but that is gigabytes of traffic; remove the ones you no longer use.", safety: .review)
    public static let installers = CleanupCategory(
        id: "installers", title: "Installers and Disk Images",
        explanation: "The app is usually installed already, and the installer can be downloaded again.", safety: .review)
    public static let archives = CleanupCategory(
        id: "xcode-archives", title: "Xcode Archives",
        explanation: "Needed to symbolicate crash reports of shipped builds; old ones can go.", safety: .review)
    public static let simulators = CleanupCategory(
        id: "simulators", title: "Simulator Devices",
        explanation: "Apps and data installed in simulators; remove unused devices in Xcode's Devices window.", safety: .review)
    public static let deviceBackups = CleanupCategory(
        id: "device-backups", title: "iPhone and iPad Backups",
        explanation: "Remove only backups of devices you no longer have or that are backed up to iCloud.", safety: .review)
}

public enum CleanupAnalyzer {
    private enum Pick { case itself, children }

    private struct PathRule {
        let path: String
        let pick: Pick
        let category: CleanupCategory
    }

    private struct NameRule {
        let name: String
        let siblings: [String]
        let inside: [String]
        let category: CleanupCategory
    }

    private static let pathRules: [PathRule] = [
        PathRule(path: ".Trash", pick: .itself, category: CleanupCategories.trash),
        PathRule(path: "Library/Caches", pick: .children, category: CleanupCategories.caches),
        PathRule(path: "Library/Logs", pick: .children, category: CleanupCategories.logs),
        PathRule(path: "Library/Developer/CoreSimulator/Caches", pick: .itself, category: CleanupCategories.simulatorCaches),
        PathRule(path: "Library/Developer/Xcode/DerivedData", pick: .children, category: CleanupCategories.derivedData),
        PathRule(path: "Library/Developer/Xcode/iOS DeviceSupport", pick: .children, category: CleanupCategories.deviceSupport),
        PathRule(path: "Library/Developer/Xcode/watchOS DeviceSupport", pick: .children, category: CleanupCategories.deviceSupport),
        PathRule(path: "Library/Developer/Xcode/Archives", pick: .children, category: CleanupCategories.archives),
        PathRule(path: "Library/Developer/CoreSimulator/Devices", pick: .children, category: CleanupCategories.simulators),
        PathRule(path: "Library/Application Support/MobileSync/Backup", pick: .children, category: CleanupCategories.deviceBackups),
        PathRule(path: ".npm/_cacache", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".cache", pick: .children, category: CleanupCategories.toolCaches),
        PathRule(path: ".gradle/caches", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".m2/repository", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".cargo/registry", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: "go/pkg/mod", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".pub-cache", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".bun/install/cache", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: "Library/pnpm/store", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: "/Library/Caches", pick: .children, category: CleanupCategories.systemCaches),
        PathRule(path: "/Library/Logs", pick: .children, category: CleanupCategories.systemCaches),
        PathRule(path: "/Library/Developer/CoreSimulator/Caches", pick: .itself, category: CleanupCategories.systemCaches),
        PathRule(path: ".ollama/models", pick: .itself, category: CleanupCategories.models),
        PathRule(path: ".lmstudio/models", pick: .itself, category: CleanupCategories.models),
    ]

    private static let modelCaches: Set<String> = ["huggingface", "lm-studio", "torch", "whisper"]

    private static let nameRules: [NameRule] = [
        NameRule(name: "node_modules", siblings: ["package.json"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".build", siblings: ["Package.swift"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: "target", siblings: ["Cargo.toml"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: "Pods", siblings: ["Podfile"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".gradle", siblings: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".next", siblings: ["package.json"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".turbo", siblings: ["package.json"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".parcel-cache", siblings: ["package.json"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: "__pycache__", siblings: [], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".venv", siblings: [], inside: ["pyvenv.cfg"], category: CleanupCategories.buildArtifacts),
        NameRule(name: "venv", siblings: [], inside: ["pyvenv.cfg"], category: CleanupCategories.buildArtifacts),
    ]

    private static let installerSuffixes: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]

    public static func analyze(_ snapshot: ScanSummary, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CleanupGroup] {
        guard !Task.isCancelled else { return [] }
        let held = snapshot.heldByClones()
        let size: (Int) -> Int64 = { snapshot.reclaimable($0, held: held) }
        var claimed = Set<Int>()
        var items: [CleanupItem] = []

        func claim(_ id: Int, _ category: CleanupCategory) {
            guard size(id) > 0, claimed.insert(id).inserted else { return }
            items.append(CleanupItem(node: id, category: category, size: size(id)))
        }

        let homePath = home.standardizedFileURL.path
        for rule in pathRules {
            if Task.isCancelled { return [] }
            let path = rule.path.hasPrefix("/") ? rule.path : homePath + "/" + rule.path
            guard let id = snapshot.locate(path), snapshot.nodes[id].isDirectory else { continue }
            switch rule.pick {
            case .itself:
                claim(id, rule.category)
            case .children:
                for child in snapshot.children(of: id) {
                    let name = snapshot.nodes[child].name
                    guard !name.hasPrefix("."), !(rule.path.hasPrefix("/") && name.hasPrefix("com.apple.")) else { continue }
                    let category = rule.path == ".cache" && modelCaches.contains(name)
                        ? CleanupCategories.models : rule.category
                    claim(child, category)
                }
            }
        }

        let rulesByName = Dictionary(grouping: nameRules, by: \.name)

        func expandable(_ id: Int) -> Bool {
            let node = snapshot.nodes[id]
            return node.isDirectory && !claimed.contains(id) && !snapshot.kinds[Int(node.kind)].isPackage
        }

        var stack: [Int]
        if let homeID = snapshot.locate(homePath) {
            let library = snapshot.locate(homePath + "/Library")
            stack = snapshot.children(of: homeID).filter { id in
                id != library && !snapshot.nodes[id].name.hasPrefix(".") && expandable(id)
            }
        } else {
            let rootPath = snapshot.displayPath(of: 0)
            guard rootPath.hasPrefix(homePath + "/") else { return group(items) }
            let top = rootPath.dropFirst(homePath.count + 1).split(separator: "/").first.map(String.init) ?? ""
            guard top != "Library", !top.hasPrefix(".") else { return group(items) }
            stack = expandable(0) ? [0] : []
        }
        while let id = stack.popLast() {
            if Task.isCancelled { return [] }
            let children = snapshot.children(of: id)
            var names: Set<String>?
            for child in children where expandable(child) {
                if let rules = rulesByName[snapshot.nodes[child].name] {
                    let siblings = names ?? Set(children.map { snapshot.nodes[$0].name })
                    names = siblings
                    let rule = rules.first { rule in
                        (rule.siblings.isEmpty || !siblings.isDisjoint(with: rule.siblings))
                            && (rule.inside.isEmpty || !Set(snapshot.children(of: child).map { snapshot.nodes[$0].name }).isDisjoint(with: rule.inside))
                    }
                    if let rule {
                        claim(child, rule.category)
                        continue
                    }
                }
                stack.append(child)
            }
        }

        for folder in ["Downloads", "Desktop"] {
            guard let folderID = snapshot.locate(homePath + "/" + folder) else { continue }
            var pending = [folderID]
            while let id = pending.popLast() {
                if Task.isCancelled { return [] }
                for child in snapshot.children(of: id) {
                    let node = snapshot.nodes[child]
                    if node.isDirectory {
                        if expandable(child) { pending.append(child) }
                    } else if installerSuffixes.contains(node.name.pathSuffix) {
                        claim(child, CleanupCategories.installers)
                    }
                }
            }
        }
        return group(items)
    }

    private static func group(_ items: [CleanupItem]) -> [CleanupGroup] {
        Dictionary(grouping: items, by: \.category)
            .map { CleanupGroup(category: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { lhs, rhs in
                let order = CleanupSafety.allCases
                let left = order.firstIndex(of: lhs.category.safety)!
                let right = order.firstIndex(of: rhs.category.safety)!
                return left == right ? lhs.size > rhs.size : left < right
            }
    }
}

public struct StaleFile: Sendable {
    public let node: Int
    public let path: String
    public let size: Int64
    public let lastUsed: Date?
    public let modified: Date?
    public let added: Date?
    public let isInICloud: Bool

    public var lastActivity: Date? { [lastUsed, modified, added].compactMap { $0 }.max() }
}

public struct CloudDestination: Hashable, Sendable {
    public enum Service: String, Sendable {
        case iCloudDrive, googleDrive, oneDrive, dropbox, box, other
    }

    public let service: Service
    public let title: String
    public let root: URL
}

public enum CloudOffload {
    public static let folders = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
        "Library/Mobile Documents/com~apple~CloudDocs",
    ]
    public static let archiveFolder = "Archived from Mac"

    public static func staleFiles(
        in snapshot: ScanSummary, minSize: Int64, olderThanDays days: Double,
        home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now
    ) -> [StaleFile] {
        let cutoff = now.addingTimeInterval(-days * 86_400)
        let homePath = home.standardizedFileURL.path
        var result: [StaleFile] = []
        for folder in folders {
            if Task.isCancelled { return [] }
            let folderPath = homePath + "/" + folder
            let rootPath = snapshot.displayPath(of: 0)
            let scope: String
            let folderID: Int
            if let id = snapshot.locate(folderPath) {
                scope = folderPath
                folderID = id
            } else if rootPath.hasPrefix(folderPath + "/") {
                let relative = rootPath.dropFirst(folderPath.count + 1)
                var ancestor = URL(filePath: folderPath, directoryHint: .isDirectory)
                var catalog = KindCatalog()
                let permitted = relative.split(separator: "/").allSatisfy { component in
                    let name = String(component)
                    guard !name.hasPrefix(".") else { return false }
                    ancestor.append(path: name, directoryHint: .isDirectory)
                    let kind = catalog.kind(name: name, directory: true, symlink: false, alias: false)
                    return !catalog.kinds[Int(kind)].isPackage
                        && (try? ancestor.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
                }
                guard permitted, !snapshot.kinds[Int(snapshot.nodes[0].kind)].isPackage else { continue }
                scope = rootPath
                folderID = 0
            } else {
                continue
            }
            var files: [Int] = []
            var stack = [folderID]
            while let id = stack.popLast() {
                if Task.isCancelled { return [] }
                for child in snapshot.children(of: id) {
                    let node = snapshot.nodes[child]
                    if node.isDirectory {
                        if !snapshot.kinds[Int(node.kind)].isPackage, !node.name.hasPrefix(".") { stack.append(child) }
                    } else if node.allocated >= minSize {
                        files.append(child)
                    }
                }
            }
            guard !files.isEmpty else { continue }
            let indexed = spotlightDates(in: scope, minSize: minSize)
            for id in files {
                if Task.isCancelled { return [] }
                let path = snapshot.displayPath(of: id)
                let dates = indexed[path] ?? fileDates(path)
                let file = StaleFile(
                    node: id, path: path, size: snapshot.nodes[id].allocated,
                    lastUsed: dates.lastUsed, modified: dates.modified, added: dates.added,
                    isInICloud: (try? URL(filePath: path).resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
                )
                guard let activity = file.lastActivity, activity < cutoff else { continue }
                result.append(file)
            }
        }
        return result.sorted { $0.size > $1.size }
    }

    public static func destinations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CloudDestination] {
        let fm = FileManager.default
        var result: [CloudDestination] = []
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        if fm.fileExists(atPath: iCloud.path) {
            result.append(CloudDestination(service: .iCloudDrive, title: "iCloud Drive", root: iCloud))
        }
        let storage = home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let names = (try? fm.contentsOfDirectory(atPath: storage.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            let provider = storage.appending(path: name, directoryHint: .isDirectory)
            if name.hasPrefix("GoogleDrive") {
                let drive = ["My Drive", "Мой диск"].map { provider.appending(path: $0, directoryHint: .isDirectory) }
                    .first { fm.fileExists(atPath: $0.path) } ?? provider
                let account = name.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
                result.append(CloudDestination(service: .googleDrive, title: account.map { "Google Drive (\($0))" } ?? "Google Drive", root: drive))
            } else if name.hasPrefix("OneDrive") {
                result.append(CloudDestination(service: .oneDrive, title: "OneDrive", root: provider))
            } else if name.hasPrefix("Dropbox") {
                result.append(CloudDestination(service: .dropbox, title: "Dropbox", root: provider))
            } else if name.hasPrefix("Box") {
                result.append(CloudDestination(service: .box, title: "Box", root: provider))
            } else {
                result.append(CloudDestination(service: .other, title: name, root: provider))
            }
        }
        return result
    }

    public static func target(for file: URL, in destination: CloudDestination,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let homeComponents = home.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        let relative = fileComponents.starts(with: homeComponents)
            ? Array(fileComponents.dropFirst(homeComponents.count)) : [file.lastPathComponent]
        return relative.reduce(destination.root.appending(path: archiveFolder, directoryHint: .isDirectory)) {
            $0.appending(path: $1)
        }
    }

    @discardableResult
    public static func move(_ file: URL, to destination: CloudDestination,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let fm = FileManager.default
        var target = target(for: file, in: destination, home: home)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stem = target.deletingPathExtension().lastPathComponent
        let suffix = target.pathExtension
        var attempt = 2
        while fm.fileExists(atPath: target.path) {
            let name = suffix.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(suffix)"
            target = target.deletingLastPathComponent().appending(path: name)
            attempt += 1
        }
        try fm.moveItem(at: file, to: target)
        return target
    }

    public static func removeLocalCopy(_ file: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: file)
    }

    private struct Dates {
        var lastUsed: Date?
        var modified: Date?
        var added: Date?
    }

    private static func fileDates(_ path: String) -> Dates {
        var info = stat()
        guard lstat(path, &info) == 0 else { return Dates() }
        func date(_ spec: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1e9)
        }
        return Dates(lastUsed: nil, modified: date(info.st_mtimespec), added: date(info.st_birthtimespec))
    }

    private static func spotlightDates(in scope: String, minSize: Int64) -> [String: Dates] {
        let attributes = ["kMDItemLastUsedDate", "kMDItemContentModificationDate", "kMDItemDateAdded"] as [CFString]
        let text = "kMDItemPhysicalSize >= \(minSize)" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, attributes as CFArray, nil) else { return [:] }
        MDQuerySetSearchScope(query, [scope] as CFArray, 0)
        guard !Task.isCancelled, MDQueryExecute(query, 0) else { return [:] }
        defer { MDQueryStop(query) }
        // Spotlight delivers results on this thread's run loop. Keep cancellation observable while gathering.
        while !MDQueryIsGatheringComplete(query) {
            guard !Task.isCancelled else { return [:] }
            let state = CFRunLoopRunInMode(.defaultMode, 0.05, true)
            if state == .finished && !MDQueryIsGatheringComplete(query) { return [:] }
        }
        var result: [String: Dates] = [:]
        for index in 0..<MDQueryGetResultCount(query) {
            if Task.isCancelled { return [:] }
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            func value(_ attribute: CFString) -> Date? {
                MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index)
                    .map { Unmanaged<CFDate>.fromOpaque($0).takeUnretainedValue() as Date }
            }
            result[path] = Dates(lastUsed: value(attributes[0]), modified: value(attributes[1]), added: value(attributes[2]))
        }
        return result
    }
}

public extension ScanSummary {
    func locate(_ path: String) -> Int? {
        if let id = find(URL(filePath: path)) { return id }
        let data = "/System/Volumes/Data"
        guard root.path == data || root.path.hasPrefix(data + "/"), !path.hasPrefix(data) else { return nil }
        return find(URL(filePath: data + path))
    }

    func heldByClones() -> [Int: Int64] {
        var families: [Inode: [Int]] = [:]
        for id in nodes.indices {
            if id.isMultiple(of: 1024), Task.isCancelled { return [:] }
            guard nodes[id].isShared else { continue }
            families[Inode(device: nodes[id].device, number: nodes[id].shared), default: []].append(id)
        }
        var held: [Int: Int64] = [:]
        for members in families.values {
            guard let owner = members.first(where: { nodes[$0].allocated > 0 }) else { continue }
            let copies = Dictionary(grouping: members, by: { nodes[$0].inode })
            let allCopies = copies.count >= Int(nodes[owner].references)
            let allLinks = copies.values.allSatisfy { ids in
                ids.count >= Int(ids.map { nodes[$0].hardLinks }.max() ?? 0)
            }
            let stop = allCopies && allLinks ? commonAncestor(of: members) : -1
            var node = owner
            while node >= 0, node != stop {
                held[node, default: 0] += nodes[owner].allocated
                node = Int(nodes[node].parent)
            }
        }
        return held
    }

    func reclaimable(_ id: Int, held: [Int: Int64]) -> Int64 {
        nodes[id].allocated - held[id, default: 0]
    }

    private func commonAncestor(of members: [Int]) -> Int {
        var path: [Int] = []
        var node = members[0]
        while node >= 0 {
            path.append(node)
            node = Int(nodes[node].parent)
        }
        let position = Dictionary(uniqueKeysWithValues: path.enumerated().map { ($1, $0) })
        var highest = 0
        for member in members.dropFirst() {
            var node = member
            while node >= 0, position[node] == nil { node = Int(nodes[node].parent) }
            guard node >= 0, let index = position[node] else { return -1 }
            highest = max(highest, index)
        }
        return path[highest]
    }

    func displayPath(of id: Int) -> String {
        let path = url(for: id).path
        let data = "/System/Volumes/Data"
        guard path.hasPrefix(data + "/") else { return path }
        return String(path.dropFirst(data.count))
    }
}

extension String {
    var pathSuffix: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return "" }
        return self[index(after: dot)...].lowercased()
    }
}

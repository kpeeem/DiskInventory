import CoreServices
import Darwin
import Foundation

public enum AdviceVerdict: String, Codable, CaseIterable, Sendable {
    case safe, regenerable, review, keep
}

public enum AdviceStatus: String, Codable, Sendable {
    case pending, trashed, kept, missing, done, failed
}

public struct AdviceItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    public var size: Int64
    public var verdict: AdviceVerdict
    public var reason: String
    public var status: AdviceStatus
    public var createdAt: Date
    public var statusAt: Date?
    public var action: String?
    public var argument: String?
    public var output: String?
    public var label: String?
    public var fileIdentity: AdviceTrash.Identity?

    public init(path: String, size: Int64, verdict: AdviceVerdict, reason: String, action: String? = nil, argument: String? = nil, label: String? = nil,
                fileIdentity: AdviceTrash.Identity? = nil) {
        id = UUID()
        self.path = path
        self.size = size
        self.verdict = verdict
        self.reason = reason
        status = .pending
        createdAt = .now
        self.action = action
        self.argument = argument
        self.label = label ?? action.flatMap { AdviceActions.definition($0)?.title(argument) }
        self.fileIdentity = fileIdentity
    }

    public var isAction: Bool { action != nil }
    public var key: String { action.map { "\($0) \(argument ?? "")" } ?? path }
    public var isRemovable: Bool { status == .pending && verdict != .keep && action == nil && !path.isEmpty }
    public var isRunnable: Bool { status == .pending && verdict != .keep && action != nil }

    public var title: String { label ?? URL(filePath: path).lastPathComponent }
}

public struct AdviceSheet: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var author: String
    public var updatedAt: Date
    public var items: [AdviceItem]

    public init(title: String, summary: String, author: String, items: [AdviceItem]) {
        self.title = title
        self.summary = summary
        self.author = author
        updatedAt = .now
        self.items = items
    }
}

public enum AdviceStore {
    public static let changedNotification = "dev.kpeeem.disk-advice.changed"
    public static let showNotification = "dev.kpeeem.disk-advice.show"

    public static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/DiskAdvice", directoryHint: .isDirectory)

    public static var file: URL { directory.appending(path: "advice.json") }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func load() -> AdviceSheet? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(AdviceSheet.self, from: data)
    }

    @discardableResult
    public static func update(_ change: (inout AdviceSheet?) throws -> Void) throws -> AdviceSheet? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appending(path: ".lock").path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        flock(lock, LOCK_EX)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        let previous = load()
        var sheet = previous
        try change(&sheet)
        guard sheet != previous else { return previous }
        if var updated = sheet {
            updated.updatedAt = .now
            try encoder.encode(updated).write(to: file, options: .atomic)
            sheet = updated
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        post(changedNotification)
        return sheet
    }

    public static func mark(_ ids: Set<UUID>, as status: AdviceStatus, output: String? = nil) throws {
        guard !ids.isEmpty else { return }
        try update { sheet in
            guard var current = sheet else { return }
            for index in current.items.indices where ids.contains(current.items[index].id) {
                current.items[index].status = status
                current.items[index].statusAt = .now
                if let output { current.items[index].output = output }
            }
            sheet = current
        }
    }

    public static func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

public enum AdviceGuard {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    private static let protectedInHome: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications", "Dev",
        "Library/Mobile Documents", "Library/CloudStorage", "Library/Application Support", "Library/Containers",
        "Library/Group Containers", "Library/Preferences", "Library/Keychains", "Library/Mail", "Library/Messages",
        "Library/Photos", "Library/Caches", "Library/Developer",
    ]
    private static let systemAreas = [
        "/private/tmp/", "/private/var/folders/", "/Library/Caches/", "/Library/Logs/",
        "/Library/Developer/CoreSimulator/Caches", "/Users/Shared/", "/cores/", "/.adobeTemp",
    ]
    private static let standardInLibrary: Set<String> = [
        "Apple", "AppStore", "Application Support", "Audio", "AutoBugCapture", "Automator", "Bluetooth", "Bundles", "Caches",
        "Catacomb", "ColorPickers", "ColorSync", "Components", "Compositions", "Contextual Menu Items", "CoreAnalytics",
        "CoreMediaIO", "Desktop Pictures", "Developer", "Dictionaries", "DirectoryServices", "Documentation", "DriverExtensions",
        "Extensions", "Filesystems", "Fonts", "Frameworks", "GPUBundles", "Graphics", "Image Capture", "Input Methods",
        "InstallerSandboxes", "Internet Plug-Ins", "Java", "KernelCollections", "Keyboard Layouts", "Keychains", "LaunchAgents",
        "LaunchDaemons", "Logs", "Mail", "Managed Preferences", "Messages", "Modem Scripts", "OSAnalytics", "OpenDirectory",
        "PDF Services", "Perl", "Plug-Ins", "PreferencePanes", "Preferences", "Printers", "PrivilegedHelperTools", "QuickLook",
        "Receipts", "Ringtones", "Ruby", "Sandbox", "Screen Savers", "ScriptingAdditions", "Scripts", "Security", "Services",
        "Sounds", "Speech", "Spelling", "Spotlight", "StagedDriverExtensions", "StagedExtensions", "StartupItems",
        "SystemExtensions", "SystemMigration", "SystemProfiler", "Trial", "Updates", "User Pictures", "User Template", "Video",
        "WebServer", "Widgets",
    ]
    private static let reviewAreas = ["/Library/Application Support/", "/Library/Audio/", "/Library/Frameworks/", "/Library/Java/", "/usr/local/"]
    private static let neverInLibrary = [
        "/Library/Preferences", "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/Extensions", "/Library/Keychains",
        "/Library/Security", "/Library/PrivilegedHelperTools", "/Library/SystemExtensions", "/Library/Filesystems",
        "/Library/StartupItems", "/Library/Apple", "/Library/Updates", "/Library/Developer/CommandLineTools",
    ]

    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(filePath: expanded).standardizedFileURL.path
        let data = "/System/Volumes/Data"
        if standardized.hasPrefix(data + "/") { standardized = String(standardized.dropFirst(data.count)) }
        for (alias, real) in [("/tmp/", "/private/tmp/"), ("/var/", "/private/var/")] where standardized.hasPrefix(alias) {
            standardized = real + standardized.dropFirst(alias.count)
        }
        return standardized
    }

    public static func refusal(for path: String, verdict: AdviceVerdict) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "does not exist" }
        guard verdict != .keep else { return nil }
        if path.hasPrefix(home + "/") {
            let relative = String(path.dropFirst(home.count + 1))
            if protectedInHome.contains(relative) { return "is a top-level folder that apps and the system rely on; point at something inside it" }
            if relative.hasPrefix("Library/Keychains") || relative.hasPrefix("Library/Mail") || relative.hasPrefix("Library/Messages") {
                return "holds keychains or mail and is never suggested for removal"
            }
            return nil
        }
        if neverInLibrary.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "belongs to system or installed software and is never removed by hand"
        }
        if path.hasPrefix("/private/var/folders/"), info.st_uid != getuid() {
            return "belongs to another user or the system"
        }
        if systemAreas.contains(where: { path.hasPrefix($0) && path.count > $0.count }) { return nil }
        if verdict == .review {
            if path.hasPrefix("/Applications/"), !path.dropFirst("/Applications/".count).contains("/") || path.hasSuffix(".app") {
                return nil
            }
            if reviewAreas.contains(where: { path.hasPrefix($0) && path.dropFirst($0.count).contains(where: { $0 != "/" }) }) { return nil }
            let parts = path.split(separator: "/")
            if path.hasPrefix("/Library/"), parts.count >= 3 || !standardInLibrary.contains(String(parts[1])) { return nil }
            return "is outside the areas that can be suggested"
        }
        return "outside the home folder only caches, logs and temporary files can be marked safe or regenerable; use review for software"
    }
}

public struct AdviceActionDefinition: Sendable {
    public let id: String
    public let needsArgument: Bool
    public let title: @Sendable (String?) -> String
    public let explanation: String
    let command: @Sendable (String?) -> (tool: String, arguments: [String])?
    let validate: @Sendable (String?) -> String?
    let estimate: @Sendable (String?) -> Int64

    public func commandLine(_ argument: String?) -> String? {
        command(argument).map { ([$0.tool] + $0.arguments).joined(separator: " ") }
    }
}

public enum AdviceActions {
    static let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static let docker = ["/usr/local/bin/docker", FileManager.default.homeDirectoryForCurrentUser.path + "/.orbstack/bin/docker"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    static let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash", directoryHint: .isDirectory)

    public static let all: [AdviceActionDefinition] = [
        AdviceActionDefinition(
            id: "brew-cleanup", needsArgument: false,
            title: { _ in "Homebrew: remove old versions and downloads" },
            explanation: "brew cleanup --prune=all removes outdated versions and cached downloads; installed formulae and casks stay.",
            command: { _ in brew.map { ($0, ["cleanup", "--prune=all"]) } },
            validate: { _ in brew == nil ? "Homebrew is not installed" : nil },
            estimate: { _ in
                guard let brew, let text = run(brew, ["cleanup", "-n", "--prune=all"]).output.components(separatedBy: "approximately ").last else { return 0 }
                return parseSize(text)
            }),
        AdviceActionDefinition(
            id: "brew-uninstall-cask", needsArgument: true,
            title: { "Uninstall \($0 ?? "cask") with Homebrew" },
            explanation: "brew uninstall --cask removes the app and the files Homebrew installed for it.",
            command: { argument in brew.flatMap { brew in argument.map { (brew, ["uninstall", "--cask", $0]) } } },
            validate: { argument in
                guard let brew else { return "Homebrew is not installed" }
                guard let argument, argument.range(of: "^[a-z0-9@._+-]+$", options: .regularExpression) != nil else { return "invalid cask name" }
                let installed = run(brew, ["list", "--cask"]).output.split(whereSeparator: \.isWhitespace).map(String.init)
                return installed.contains(argument) ? nil : "\(argument) is not an installed cask"
            },
            estimate: { argument in
                guard let argument, let brew else { return 0 }
                let caskroom = "/opt/homebrew/Caskroom/" + argument
                var paths = [caskroom]
                if let data = run(brew, ["info", "--cask", "--json=v2", argument]).output.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let casks = json["casks"] as? [[String: Any]], let artifacts = casks.first?["artifacts"] as? [[String: Any]] {
                    for artifact in artifacts {
                        paths += (artifact["app"] as? [Any] ?? []).compactMap { $0 as? String }.map { "/Applications/" + $0 }
                        for step in artifact["uninstall"] as? [[String: Any]] ?? [] {
                            paths += step["delete"] as? [String] ?? (step["delete"] as? String).map { [$0] } ?? []
                        }
                    }
                }
                let distinct = Set(paths).filter { path in path == caskroom || !path.hasPrefix(caskroom + "/") }
                return distinct.reduce(0) { $0 + folderSize(URL(filePath: $1)) }
            }),
        AdviceActionDefinition(
            id: "simctl-delete-unavailable", needsArgument: false,
            title: { _ in "Delete simulators whose runtime is gone" },
            explanation: "xcrun simctl delete unavailable removes simulators that can no longer start.",
            command: { _ in ("/usr/bin/xcrun", ["simctl", "delete", "unavailable"]) },
            validate: { _ in nil },
            estimate: { _ in simulators().filter { !$0.available }.reduce(0) { $0 + folderSize(simulatorFolder($1.udid)) } }),
        AdviceActionDefinition(
            id: "simctl-delete-device", needsArgument: true,
            title: { argument in "Delete simulator \(simulators().first { $0.udid == argument }?.name ?? argument ?? "")" },
            explanation: "xcrun simctl delete removes the simulator and the apps installed in it.",
            command: { argument in argument.map { ("/usr/bin/xcrun", ["simctl", "delete", $0]) } },
            validate: { argument in
                guard let argument, UUID(uuidString: argument) != nil else { return "invalid simulator UUID" }
                guard simulators().contains(where: { $0.udid == argument }) else { return "no such simulator" }
                return nil
            },
            estimate: { argument in argument.map { folderSize(simulatorFolder($0)) } ?? 0 }),
        AdviceActionDefinition(
            id: "simctl-runtime-delete", needsArgument: true,
            title: { argument in "Delete simulator runtime \(runtimes().first { $0.identifier == argument }.map { "iOS \($0.version)" } ?? argument ?? "")" },
            explanation: "xcrun simctl runtime delete removes a downloaded simulator runtime; simulators that use it stop working.",
            command: { argument in argument.map { ("/usr/bin/xcrun", ["simctl", "runtime", "delete", $0]) } },
            validate: { argument in
                guard let runtime = runtimes().first(where: { $0.identifier == argument }) else { return "no such runtime" }
                return runtime.deletable ? nil : "this runtime cannot be deleted"
            },
            estimate: { argument in runtimes().first { $0.identifier == argument }?.size ?? 0 }),
        AdviceActionDefinition(
            id: "docker-prune", needsArgument: false,
            title: { _ in "Docker: remove unused images, containers and build cache" },
            explanation: "docker system prune -af removes stopped containers, unused images, networks and build cache; volumes stay.",
            command: { _ in docker.map { ($0, ["system", "prune", "-af"]) } },
            validate: { _ in
                guard let docker else { return "Docker is not installed" }
                return run(docker, ["info", "--format", "{{.ServerVersion}}"]).status == 0 ? nil : "Docker or OrbStack is not running"
            },
            estimate: { _ in
                guard let docker else { return 0 }
                return run(docker, ["system", "df", "--format", "{{.Reclaimable}}"]).output
                    .split(separator: "\n").reduce(0) { $0 + parseSize(String($1)) }
            }),
        AdviceActionDefinition(
            id: "empty-trash", needsArgument: false,
            title: { _ in "Empty the Trash" },
            explanation: "Permanently deletes everything in the Trash. This cannot be undone.",
            command: { _ in nil },
            validate: { _ in nil },
            estimate: { _ in folderSize(trash) }),
    ]

    public static func definition(_ id: String) -> AdviceActionDefinition? {
        all.first { $0.id == id }
    }

    public static func refusal(_ id: String, argument: String?) -> String? {
        guard let definition = definition(id) else { return "unknown action \(id); known: " + all.map(\.id).joined(separator: ", ") }
        if definition.needsArgument, argument?.isEmpty ?? true { return "\(id) needs an argument" }
        return definition.validate(argument)
    }

    public static func estimate(_ id: String, argument: String?) -> Int64 {
        definition(id)?.estimate(argument) ?? 0
    }

    public static func perform(_ id: String, argument: String?) -> (ok: Bool, output: String) {
        guard let definition = definition(id) else { return (false, "unknown action") }
        if let refusal = refusal(id, argument: argument) { return (false, refusal) }
        if id == "empty-trash" {
            let failure = AdviceTrash.emptyTrash()
            return (failure == nil, failure ?? "The Trash is empty")
        }
        guard let command = definition.command(argument) else { return (false, "the tool is not available") }
        let result = run(command.tool, command.arguments, timeout: 300)
        return (result.status == 0, result.output)
    }

    public static func run(
        _ tool: String, _ arguments: [String], timeout: Double = 30, outputLimit: Int = 8 << 20
    ) -> (status: Int32, output: String) {
        guard timeout.isFinite, timeout > 0, timeout <= 3600, outputLimit > 0 else {
            return (-1, "Invalid command limits")
        }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return (-1, String(cString: strerror(errno))) }
        let reader = descriptors[0]
        let writer = descriptors[1]
        defer { close(reader) }
        guard fcntl(reader, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writer, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else {
            let error = errno
            close(writer)
            return (-1, String(cString: strerror(error)))
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionError = posix_spawn_file_actions_init(&actions)
        defer { if actions != nil { posix_spawn_file_actions_destroy(&actions) } }
        let attrError = posix_spawnattr_init(&attributes)
        defer { if attributes != nil { posix_spawnattr_destroy(&attributes) } }
        guard actionError == 0, attrError == 0 else {
            close(writer)
            return (-1, String(cString: strerror(actionError == 0 ? attrError : actionError)))
        }
        let setupError = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            posix_spawnattr_setpgroup(&attributes, 0),
        ].first { $0 != 0 }
        if let setupError {
            close(writer)
            return (-1, String(cString: strerror(setupError)))
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        var argv = ([tool] + arguments).map { strdup($0) } + [nil]
        var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            env.forEach { free($0) }
        }
        guard !argv.dropLast().contains(nil), !env.dropLast().contains(nil) else {
            close(writer)
            return (-1, String(cString: strerror(ENOMEM)))
        }
        var pid: pid_t = 0
        let launched = posix_spawn(&pid, tool, &actions, &attributes, &argv, &env)
        close(writer)
        guard launched == 0 else { return (-1, String(cString: strerror(launched))) }

        let deadline = ContinuousClock.now + .seconds(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        var status: Int32 = 0
        var exited = false
        defer {
            if !exited {
                kill(-pid, SIGKILL)
                let child = pid
                let waited = waitpid(child, &status, WNOHANG)
                if waited == 0 || (waited < 0 && errno == EINTR) {
                    DispatchQueue.global(qos: .utility).async {
                        var status: Int32 = 0
                        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                    }
                }
            }
        }
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let count = read(reader, &buffer, buffer.count)
            if count > 0 {
                guard count <= outputLimit - data.count else {
                    return (-1, "Command exceeded its output limit")
                }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { return (-1, String(cString: strerror(errno))) }
            }
            if exited {
                let code = status & 0x7f == 0 ? (status >> 8) & 0xff : -1
                return (code, String(decoding: data, as: UTF8.self))
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited < 0 && errno != EINTR { return (-1, String(cString: strerror(errno))) }
            if waited == pid {
                // The child can write to the pipe between the read and waitpid.
                exited = true
                continue
            }
            if count == 0 {
                usleep(10_000)
            } else {
                var ready = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                poll(&ready, 1, 10)
            }
        }
        return (-1, Task.isCancelled ? "Command cancelled" : "Command timed out after \(timeout) s")
    }

    public struct Simulator: Sendable {
        public let udid: String
        public let name: String
        public let runtime: String
        public let state: String
        public let available: Bool
    }

    public struct Runtime: Sendable {
        public let identifier: String
        public let version: String
        public let size: Int64
        public let lastUsed: String?
        public let deletable: Bool
    }

    public static func simulators() -> [Simulator] {
        guard let data = run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"]).output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.flatMap { runtime, list in
            list.compactMap { device in
                guard let udid = device["udid"] as? String else { return nil }
                return Simulator(udid: udid, name: device["name"] as? String ?? udid,
                                 runtime: runtime.components(separatedBy: ".").last ?? runtime,
                                 state: device["state"] as? String ?? "", available: device["isAvailable"] as? Bool ?? true)
            }
        }
    }

    public static func runtimes() -> [Runtime] {
        guard let data = run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]).output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return json.values.compactMap { entry in
            guard let identifier = entry["identifier"] as? String else { return nil }
            return Runtime(identifier: identifier, version: entry["version"] as? String ?? "",
                           size: (entry["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                           lastUsed: entry["lastUsedAt"] as? String, deletable: entry["deletable"] as? Bool ?? false)
        }
    }

    public static func simulatorFolder(_ udid: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/CoreSimulator/Devices/" + udid, directoryHint: .isDirectory)
    }

    public static func folderSize(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        var total = Int64(info.st_blocks) * 512
        guard info.st_mode & S_IFMT == S_IFDIR, let walk = FileManager.default.enumerator(atPath: url.path) else { return total }
        var linked = Set<UInt64>()
        while let relative = walk.nextObject() as? String {
            guard lstat(url.path + "/" + relative, &info) == 0 else { continue }
            if info.st_nlink > 1, info.st_mode & S_IFMT != S_IFDIR, !linked.insert(info.st_ino).inserted { continue }
            total += Int64(info.st_blocks) * 512
        }
        return total
    }

    static func parseSize(_ text: String) -> Int64 {
        let scanner = Scanner(string: text.trimmingCharacters(in: .whitespaces))
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = (scanner.scanCharacters(from: .letters) ?? "B").uppercased()
        let factor: Double = switch unit.first {
        case "K": 1e3
        case "M": 1e6
        case "G": 1e9
        case "T": 1e12
        default: 1
        }
        guard value >= 0 else { return 0 }
        return Int64(exactly: (value * factor).rounded(.towardZero)) ?? 0
    }
}

public enum AdviceTrash {
    public struct Identity: Codable, Hashable, Sendable {
        let device: Int32
        let inode: UInt64

        public init?(url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }

        public init(node: FileNode) {
            device = node.device
            inode = node.inode
        }
    }

    public struct Target: Sendable {
        public let url: URL
        let identity: Identity

        public init(url: URL, identity: Identity) {
            self.url = url
            self.identity = identity
        }

        public init(url: URL, node: FileNode) {
            self.init(url: url, identity: Identity(node: node))
        }
    }

    public struct Move: Sendable {
        public let source: URL
        public let destination: URL?
    }

    public static func move(_ target: Target) throws -> Move {
        let url = target.url
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard Identity(url: url) == target.identity,
              parent.resolvingSymlinksInPath().pathComponents == parent.pathComponents else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "This item changed since it was selected. Refresh before moving it to Trash."
            ])
        }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return Move(source: url, destination: resultingURL as URL?)
    }

    public static func move(_ targets: [Target]) -> (done: [Move], errors: [String]) {
        var done: [Move] = []
        var errors: [String] = []
        for target in targets {
            do {
                done.append(try move(target))
            } catch {
                errors.append("\(target.url.path): \(error.localizedDescription)")
            }
        }
        return (done, errors)
    }

    public static func emptyTrash() -> String? {
        finder("empty trash")
    }

    private static func finder(_ command: String) -> String? {
        let run: @Sendable () -> String? = {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to \(command)")?.executeAndReturnError(&error)
            guard let error else { return nil }
            return error[NSAppleScript.errorMessage] as? String ?? "Finder refused"
        }
        return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
    }
}

public enum SystemSurvey {
    public struct App: Sendable {
        public let path: String
        public let size: Int64
        public let lastLaunch: Date?
    }

    public static func applications(size: (String) -> Int64) -> [App] {
        var bundles: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [] where !name.hasPrefix(".") {
            let path = "/Applications/" + name
            if name.hasSuffix(".app") {
                bundles.append(path)
            } else if let inner = try? FileManager.default.contentsOfDirectory(atPath: path) {
                bundles += inner.filter { $0.hasSuffix(".app") }.map { path + "/" + $0 }
            }
        }
        return bundles.map { App(path: $0, size: size($0), lastLaunch: lastLaunch(of: $0)) }
    }

    public static func lastLaunch(of bundle: String) -> Date? {
        var dates: [Date] = []
        if let executable = Bundle(path: bundle)?.executablePath {
            var info = stat()
            if lstat(executable, &info) == 0 {
                dates.append(Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec)))
            }
        }
        if let item = MDItemCreate(kCFAllocatorDefault, bundle as CFString),
           let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date, used > Date(timeIntervalSince1970: 1_262_304_000) {
            dates.append(used)
        }
        return dates.max()
    }

    public static func report(size: (String) -> Int64) -> [String: Any] {
        func top(_ path: String, limit: Int = 8) -> [[String: Any]] {
            let children = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).map { path + "/" + $0 }
            return children.map { ($0, size($0)) }.sorted { $0.1 > $1.1 }.prefix(limit).map { ["path": $0.0, "size": $0.1] }
        }
        let userRoot = AdviceGuard.normalize((NSTemporaryDirectory() as NSString).deletingLastPathComponent)
        let now = Date()
        let simulators = AdviceActions.simulators().map { ($0, size(AdviceActions.simulatorFolder($0.udid).path)) }
        let casks = AdviceActions.brew.map { AdviceActions.run($0, ["list", "--cask"]).output.split(whereSeparator: \.isWhitespace).map(String.init) } ?? []
        return [
            "library_caches": top("/Library/Caches"),
            "library_logs": size("/Library/Logs"),
            "simulator_caches": size("/Library/Developer/CoreSimulator/Caches"),
            "user_temp_and_caches": top(userRoot, limit: 4) + top(userRoot + "/C") + top(userRoot + "/X", limit: 4),
            "private_tmp": top("/private/tmp", limit: 12),
            "users_shared": top("/Users/Shared", limit: 6),
            "trash": size(AdviceActions.trash.path),
            "simulator_runtimes": AdviceActions.runtimes().map { runtime in
                ["identifier": runtime.identifier, "version": runtime.version, "size": runtime.size, "last_used": runtime.lastUsed as Any,
                 "deletable": runtime.deletable,
                 "used_by": simulators.filter { $0.0.runtime.hasSuffix(runtime.version.replacingOccurrences(of: ".", with: "-")) }.map(\.0.name)] as [String: Any]
            },
            "simulators": simulators.filter { $0.1 > 50_000_000 || !$0.0.available }.sorted { $0.1 > $1.1 }.map { simulator, bytes in
                ["udid": simulator.udid, "name": simulator.name, "runtime": simulator.runtime, "state": simulator.state,
                 "available": simulator.available, "size": bytes] as [String: Any]
            },
            "homebrew_cleanup_estimate": AdviceActions.estimate("brew-cleanup", argument: nil),
            "homebrew_casks": casks.map { ["cask": $0, "caskroom_size": size("/opt/homebrew/Caskroom/" + $0)] as [String: Any] }
                .sorted { ($0["caskroom_size"] as? Int64 ?? 0) > ($1["caskroom_size"] as? Int64 ?? 0) }.prefix(15).map { $0 },
            "docker": AdviceActions.refusal("docker-prune", argument: nil) ?? "running, reclaimable \(AdviceActions.estimate("docker-prune", argument: nil)) bytes",
            "local_snapshots": AdviceActions.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output
                .split(separator: "\n").filter { $0.contains("com.apple") }.map(String.init),
            "applications": applications(size: size).sorted { $0.size > $1.size }.prefix(60).map { app in
                ["path": app.path, "size": app.size, "last_launch": app.lastLaunch as Any,
                 "days_since_launch": app.lastLaunch.map { Int(now.timeIntervalSince($0) / 86_400) } as Any] as [String: Any]
            },
            "actions": AdviceActions.all.map { ["id": $0.id, "needs_argument": $0.needsArgument, "what": $0.explanation] },
        ]
    }
}

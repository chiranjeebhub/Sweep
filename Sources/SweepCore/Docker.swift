import Foundation

/// What Docker reports about its own storage, read through the docker command.
///
/// Sweep never touches Docker's disk image directly. Everything goes through docker's own commands,
/// each shown to the user before it runs. Volumes are listed but never removed, and nothing uses --force.
public struct DockerSnapshot: Sendable {
    public enum Status: Sendable, Equatable {
        case notInstalled
        case notRunning(engine: String)
        case running(engine: String, version: String)
    }

    public struct Usage: Identifiable, Sendable {
        public var id: String { type }
        public let type: String
        public let count: Int
        public let active: Int
        public let size: Int64
        public let reclaimable: Int64
    }

    public struct Container: Identifiable, Sendable, Hashable {
        public let id: String
        public let name: String
        public let image: String
        public let state: String
        public let status: String
        public let created: String
        public var isRunning: Bool { state == "running" || state == "restarting" || state == "paused" }
    }

    public struct Image: Identifiable, Sendable, Hashable {
        public let id: String
        public let repository: String
        public let tag: String
        public let size: Int64
        public let created: String
        public let inUse: Bool
        public var isDangling: Bool { repository == "<none>" }
        public var name: String { isDangling ? id : "\(repository):\(tag)" }
    }

    public struct Volume: Identifiable, Sendable, Hashable {
        public var id: String { name }
        public let name: String
        public let driver: String
        public let inUse: Bool
    }

    public let status: Status
    public let usage: [Usage]
    public let containers: [Container]
    public let images: [Image]
    public let volumes: [Volume]
    /// Docker Desktop's virtual disk: space it takes on the Mac, and the most it may grow to.
    public let diskImage: (path: String, allocated: Int64, maximum: Int64)?

    public func usage(_ type: String) -> Usage? { usage.first { $0.type == type } }
    public var stoppedContainers: [Container] { containers.filter { !$0.isRunning } }
    public var danglingImages: [Image] { images.filter(\.isDangling) }
    public var unusedImages: [Image] { images.filter { !$0.inUse } }
}

/// A docker command Sweep offers, with exactly what it runs.
public struct DockerAction: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let explanation: String
    public let arguments: [String]
    public let estimate: Int64?
    /// Prune commands ask for confirmation; Sweep answers it instead of passing --force.
    let answersYes: Bool

    public var command: String { (["docker"] + arguments).joined(separator: " ") }

    public static func pruneContainers(_ snapshot: DockerSnapshot) -> DockerAction {
        DockerAction(id: "containers", title: "Remove stopped containers",
                     explanation: "\(snapshot.stoppedContainers.count) containers that aren't running. Their volumes are kept.",
                     arguments: ["container", "prune"], estimate: snapshot.usage("Containers")?.reclaimable, answersYes: true)
    }

    public static func pruneDanglingImages(_ snapshot: DockerSnapshot) -> DockerAction {
        DockerAction(id: "dangling", title: "Remove untagged images",
                     explanation: "\(snapshot.danglingImages.count) image layers left behind when a newer build took the tag.",
                     arguments: ["image", "prune"], estimate: snapshot.danglingImages.reduce(0) { $0 + $1.size }, answersYes: true)
    }

    public static func pruneUnusedImages(_ snapshot: DockerSnapshot) -> DockerAction {
        DockerAction(id: "unused", title: "Remove all unused images",
                     explanation: "\(snapshot.unusedImages.count) images no container uses. They download again on the next pull or run.",
                     arguments: ["image", "prune", "-a"], estimate: snapshot.usage("Images")?.reclaimable, answersYes: true)
    }

    public static func pruneBuildCache(_ snapshot: DockerSnapshot) -> DockerAction {
        DockerAction(id: "buildcache", title: "Clear the build cache",
                     explanation: "Layers BuildKit kept to speed up builds. The next build of each image is slower.",
                     arguments: ["builder", "prune"], estimate: snapshot.usage("Build Cache")?.reclaimable, answersYes: true)
    }

    public static func removeContainer(_ container: DockerSnapshot.Container) -> DockerAction {
        DockerAction(id: "rm:" + container.id, title: "Remove container \(container.name)", explanation: "Removes this stopped container.",
                     arguments: ["rm", container.id], estimate: nil, answersYes: false)
    }

    public static func removeImage(_ image: DockerSnapshot.Image) -> DockerAction {
        DockerAction(id: "rmi:" + image.id, title: "Remove image \(image.name)", explanation: "Docker refuses if a container uses it.",
                     arguments: ["rmi", image.isDangling ? image.id : image.name], estimate: image.size, answersYes: false)
    }
}

public struct DockerClient: Sendable {
    let home: String

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = home }

    public var executable: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.docker/bin/docker", home + "/.orbstack/bin/docker",
         "/Applications/Docker.app/Contents/Resources/bin/docker", "/Applications/OrbStack.app/Contents/MacOS/xbin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var engineName: String {
        if FileManager.default.fileExists(atPath: "/Applications/OrbStack.app") { return "OrbStack" }
        if FileManager.default.fileExists(atPath: home + "/.colima") { return "Colima" }
        return "Docker Desktop"
    }

    func run(_ arguments: [String], input: String? = nil) -> Shell.Output? {
        guard let executable else { return nil }
        return Shell.run(executable, arguments, input: input)
    }

    /// JSON objects printed one per line by `--format '{{json .}}'`.
    func lines(_ arguments: [String]) -> [[String: Any]] {
        guard let output = run(arguments + ["--format", "{{json .}}"]), output.status == 0 else { return [] }
        return output.text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    public func snapshot() -> DockerSnapshot {
        let disk = diskImage()
        guard executable != nil else {
            return DockerSnapshot(status: .notInstalled, usage: [], containers: [], images: [], volumes: [], diskImage: disk)
        }
        guard let info = run(["version", "--format", "{{.Server.Version}}"]), info.status == 0 else {
            return DockerSnapshot(status: .notRunning(engine: engineName), usage: [], containers: [], images: [], volumes: [], diskImage: disk)
        }
        let version = info.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let usage = lines(["system", "df"]).map { row in
            DockerSnapshot.Usage(type: row["Type"] as? String ?? "", count: Int(row["TotalCount"] as? String ?? "") ?? 0,
                                 active: Int(row["Active"] as? String ?? "") ?? 0, size: Self.bytes(row["Size"] as? String),
                                 reclaimable: Self.bytes(row["Reclaimable"] as? String))
        }
        let containers = lines(["ps", "-a"]).map { row in
            DockerSnapshot.Container(id: row["ID"] as? String ?? "", name: row["Names"] as? String ?? "", image: row["Image"] as? String ?? "",
                                     state: (row["State"] as? String ?? "").lowercased(), status: row["Status"] as? String ?? "",
                                     created: row["RunningFor"] as? String ?? "")
        }
        let usedImages = Set(containers.map(\.image))
        let images = lines(["images"]).map { row -> DockerSnapshot.Image in
            let repository = row["Repository"] as? String ?? "<none>"
            let tag = row["Tag"] as? String ?? "<none>"
            let id = row["ID"] as? String ?? ""
            let inUse = usedImages.contains(id) || usedImages.contains("\(repository):\(tag)")
                || (tag == "latest" && usedImages.contains(repository))
            return DockerSnapshot.Image(id: id, repository: repository, tag: tag, size: Self.bytes(row["Size"] as? String),
                                        created: row["CreatedSince"] as? String ?? "", inUse: inUse)
        }
        let dangling = Set((run(["volume", "ls", "-q", "--filter", "dangling=true"])?.text ?? "").split(separator: "\n").map(String.init))
        let volumes = lines(["volume", "ls"]).map { row in
            let name = row["Name"] as? String ?? ""
            return DockerSnapshot.Volume(name: name, driver: row["Driver"] as? String ?? "", inUse: !dangling.contains(name))
        }
        return DockerSnapshot(status: .running(engine: engineName, version: version), usage: usage, containers: containers,
                              images: images.sorted { $0.size > $1.size }, volumes: volumes, diskImage: disk)
    }

    /// Runs one action and records it in History.
    public func perform(_ action: DockerAction) -> (succeeded: Bool, output: String) {
        guard let output = run(action.arguments, input: action.answersYes ? "y\n" : nil) else { return (false, "Docker isn't installed.") }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded = output.status == 0
        var freed: Int64 = action.estimate ?? 0
        if let range = text.range(of: #"Total reclaimed space:\s*([0-9.]+\s*[kKMGT]?B)"#, options: .regularExpression) {
            let value = text[range].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
            freed = Self.bytes(value)
        }
        HistoryStore.shared.append(HistoryEntry(source: "Docker", operation: action.command,
                                                items: [CleanupItemResult(path: action.title, bytes: succeeded ? freed : 0,
                                                                          error: succeeded ? nil : text)]))
        return (succeeded, text)
    }

    func diskImage() -> (path: String, allocated: Int64, maximum: Int64)? {
        let candidates = [home + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
                          home + "/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return (path, Int64(values?.totalFileAllocatedSize ?? 0), Int64(values?.fileSize ?? 0))
    }

    /// Docker prints sizes in decimal units: "1.2GB", "512MB", "12.5kB", "0B", "1.2GB (50%)".
    public static func bytes(_ text: String?) -> Int64 {
        guard let text else { return 0 }
        let first = text.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, multiplier) in units where first.hasSuffix(unit) {
            guard let number = Double(first.dropLast(unit.count)) else { return 0 }
            return Int64(number * multiplier)
        }
        return 0
    }
}

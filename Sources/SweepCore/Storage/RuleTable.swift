import Foundation

/// The classification rules and their cleanup policies, as plain data so they can be read line by line.
///
/// Order matters: when several rules match a folder, the earliest wins, so specific rules come
/// before broad ones. Size never decides a tier, and a rule without a policy never produces a suggestion.
public enum RuleTable {
    public static let all: [Rule] = build()

    struct FileKind: Sendable {
        let extensions: Set<String>
        let category: Category
        let label: String
    }

    static let fileKinds: [FileKind] = [
        FileKind(extensions: ["log"], category: .logs, label: "Log file"),
        FileKind(extensions: ["dmg", "iso", "img", "sparseimage", "sparsebundle"], category: .binaryData, label: "Disk image"),
        FileKind(extensions: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "pkg", "xip"], category: .binaryData, label: "Archive or installer"),
        FileKind(extensions: ["vmdk", "vdi", "qcow2", "hdd", "raw", "utm"], category: .binaryData, label: "Virtual machine disk"),
        FileKind(extensions: ["gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "mlmodel", "bin"], category: .binaryData, label: "Machine-learning model"),
        FileKind(extensions: ["parquet", "csv", "sqlite", "db", "h5", "npy", "npz", "arrow"], category: .binaryData, label: "Dataset or database"),
        FileKind(extensions: ["mov", "mp4", "m4v", "mkv", "avi", "wav", "aiff", "flac", "mp3", "heic", "jpg", "jpeg", "png", "raw", "cr2", "nef", "arw"], category: .userData, label: "Media"),
        FileKind(extensions: ["pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx"], category: .userData, label: "Document"),
    ]

    // swiftlint:disable:next function_body_length
    private static func build() -> [Rule] {
        var rules: [Rule] = []
        func add(_ id: String, _ matcher: Matcher, leaf: Bool, _ category: Category, _ confidence: Confidence,
                 _ label: String, _ explanation: String, _ policy: Policy?) {
            rules.append(Rule(id: id, matcher: matcher, isLeaf: leaf, category: category, confidence: confidence,
                              label: label, explanation: explanation, policy: policy, order: rules.count))
        }
        func leaf(_ id: String, _ matcher: Matcher, _ category: Category, _ confidence: Confidence,
                  _ label: String, _ explanation: String, _ policy: Policy? = nil) {
            add(id, matcher, leaf: true, category, confidence, label, explanation, policy)
        }
        func area(_ id: String, _ matcher: Matcher, _ category: Category, _ confidence: Confidence,
                  _ label: String, _ explanation: String, _ policy: Policy? = nil) {
            add(id, matcher, leaf: false, category, confidence, label, explanation, policy)
        }
        func home(_ path: String) -> Matcher { .home(path.split(separator: "/").map(String.init)) }

        // MARK: Containers and virtual machines

        leaf("docker.desktop", home("Library/Containers/com.docker.docker"), .dockerStorage, .high, "Docker Desktop data",
             "Docker Desktop's Linux virtual machine disk. Every image, container, volume and build cache lives inside it.",
             Policy(.keep, safe: "", risks: "Volumes can hold databases and other data that exists nowhere else.",
                    action: "Manage it in Docker, or from Sweep's Docker screen", command: "docker system df"))
        leaf("docker.group", home("Library/Group Containers/group.com.docker"), .dockerStorage, .high, "Docker Desktop shared data",
             "Settings and state shared between Docker Desktop's parts.")
        leaf("docker.orbstack", home(".orbstack"), .dockerStorage, .high, "OrbStack data",
             "OrbStack's container and machine storage.",
             Policy(.keep, safe: "", risks: "Holds containers and volumes.", action: "Manage it in OrbStack or with the docker command"))
        leaf("docker.colima", home(".colima"), .dockerStorage, .high, "Colima data",
             "Colima's virtual machine disks with container images and volumes.",
             Policy(.keep, safe: "", risks: "Holds containers and volumes.", action: "Manage it with colima or docker"))
        leaf("docker.cli", home(".docker"), .dockerStorage, .high, "Docker command-line settings",
             "Contexts, plugins and sign-in settings for the docker command.")
        leaf("podman.storage", home(".local/share/containers"), .dockerStorage, .high, "Podman data",
             "Podman's machines, images and volumes.",
             Policy(.keep, safe: "", risks: "Volumes can hold databases.", action: "Manage it with Podman", command: "podman system prune"))
        leaf("minikube.cache", home(".minikube/cache"), .cache, .high, "Minikube downloads",
             "Machine images and Kubernetes binaries Minikube downloaded.",
             Policy(.likelySafe, safe: "Minikube downloads them again when a cluster next starts.",
                    risks: "Starting a cluster is slower and needs the network.", action: "Clear Minikube's download cache"))
        area("minikube.home", home(".minikube"), .developerTools, .high, "Minikube data",
             "Minikube clusters, certificates and downloads.")
        leaf("utm.vms", home("Library/Containers/com.utmapp.UTM"), .binaryData, .high, "UTM virtual machines",
             "Virtual machines made with UTM. Each one is a full disk.",
             Policy(.keep, safe: "", risks: "A virtual machine may hold work that exists nowhere else.", action: "Delete machines you no longer need in UTM"))
        leaf("parallels.vms", home("Parallels"), .binaryData, .high, "Parallels virtual machines",
             "Virtual machines made with Parallels Desktop.",
             Policy(.keep, safe: "", risks: "A virtual machine may hold work that exists nowhere else.", action: "Delete machines you no longer need in Parallels"))

        // MARK: Xcode and Apple devices

        leaf("xcode.derived", home("Library/Developer/Xcode/DerivedData"), .buildArtifacts, .high, "Xcode DerivedData",
             "Build products and indexes Xcode keeps for every project you have opened.",
             Policy(.likelySafe, safe: "Xcode rebuilds it on the next build. Nothing you wrote is inside.",
                    risks: "The first build of each project afterwards is slower and indexing starts over.",
                    action: "Remove DerivedData", before: "Quit Xcode first."))
        leaf("xcode.archives", home("Library/Developer/Xcode/Archives"), .developerTools, .high, "Xcode archives",
             "Archived builds you made for distribution, including their debug symbols.",
             Policy(.keep, safe: "", risks: "The debug symbols are needed to read crash reports from builds you shipped.",
                    action: "Delete old archives in Xcode's Organizer"))
        leaf("devices.backups", home("Library/Application Support/MobileSync/Backup"), .userData, .high, "iPhone and iPad backups",
             "Local backups made by Finder, one folder per device backup.",
             Policy(.reviewFirst, methods: [.trash], safe: "Old backups of devices you no longer have, or that also back up to iCloud, are rarely needed.",
                    risks: "A backup may be the only copy of a device's photos and messages.",
                    action: "Remove this backup", expansion: .children, minimumSize: 100_000_000,
                    before: "Check the device also backs up to iCloud, or that you no longer need it."))
        leaf("xcode.device-support", home("Library/Developer/Xcode/iOS DeviceSupport"), .developerTools, .high, "iOS device support",
             "Debug symbols Xcode copied from connected devices, one folder per iOS version.",
             Policy(.reviewFirst, safe: "Xcode copies them again the next time a device on that version connects.",
                    risks: "Debugging on that iOS version is slow to start once while Xcode copies them back.",
                    action: "Remove support files for this iOS version", expansion: .children, minimumSize: 100_000_000))
        leaf("xcode.watch-device-support", home("Library/Developer/Xcode/watchOS DeviceSupport"), .developerTools, .high, "watchOS device support",
             "Debug symbols Xcode copied from connected watches.",
             Policy(.reviewFirst, safe: "Xcode copies them again when a watch on that version connects.",
                    risks: "Debugging on that watchOS version starts slowly once.", action: "Remove support files for this version",
                    expansion: .children, minimumSize: 100_000_000))
        leaf("xcode.simulators", home("Library/Developer/CoreSimulator"), .developerTools, .high, "Simulators",
             "Simulator devices with their installed apps and data, plus simulator runtimes.",
             Policy(.reviewFirst, methods: [], safe: "Simulators that are no longer available can be removed with Xcode's own tool.",
                    risks: "A simulator can hold test data you want to keep.", action: "Delete unavailable simulators",
                    command: "xcrun simctl delete unavailable", minimumSize: 500_000_000))
        leaf("xcode.caches", home("Library/Caches/com.apple.dt.Xcode"), .cache, .high, "Xcode cache",
             "Downloaded documentation and other data Xcode can fetch again.",
             Policy(.likelySafe, safe: "Xcode rebuilds its cache when needed.", risks: "Quit Xcode first.", action: "Clear Xcode's cache"))
        area("apple.developer", home("Library/Developer"), .developerTools, .medium, "Apple developer data",
             "Data made by Xcode and Apple's developer tools.")

        // MARK: Package managers and toolchains

        leaf("npm.cache", home(".npm"), .cache, .high, "npm cache",
             "Packages npm downloaded, kept so installs are faster.",
             Policy(.likelySafe, safe: "npm downloads packages again when it needs them.",
                    risks: "Installs need the network until the cache fills up again.", action: "Clear the npm cache",
                    command: "npm cache clean --force"))
        leaf("pnpm.store", home("Library/pnpm"), .developerTools, .high, "pnpm store",
             "pnpm's shared package store. Projects link their packages from here.",
             Policy(.reviewFirst, methods: [], safe: "pnpm can drop packages no project uses any more.",
                    risks: "Removing the store by hand breaks every project installed with pnpm until it is reinstalled.",
                    action: "Prune unused packages", command: "pnpm store prune"))
        leaf("pnpm.store-home", home(".pnpm-store"), .developerTools, .high, "pnpm store",
             "pnpm's shared package store. Projects link their packages from here.",
             Policy(.reviewFirst, methods: [], safe: "pnpm can drop packages no project uses any more.",
                    risks: "Removing the store by hand breaks projects installed with pnpm.", action: "Prune unused packages",
                    command: "pnpm store prune"))
        leaf("pnpm.store-xdg", home(".local/share/pnpm"), .developerTools, .high, "pnpm store and global packages",
             "pnpm's package store and globally installed tools.")
        leaf("yarn.cache", home("Library/Caches/Yarn"), .cache, .high, "Yarn cache",
             "Packages Yarn downloaded.",
             Policy(.likelySafe, safe: "Yarn downloads packages again on the next install.", risks: "Offline installs stop working until it refills.",
                    action: "Clear the Yarn cache", command: "yarn cache clean"))
        leaf("yarn.berry", home(".yarn/berry/cache"), .cache, .high, "Yarn cache",
             "Yarn 2 and later's shared package cache.",
             Policy(.likelySafe, safe: "Yarn downloads packages again on the next install.", risks: "Offline installs stop working until it refills.",
                    action: "Clear the Yarn cache", command: "yarn cache clean --mirror"))
        leaf("bun.cache", home(".bun/install/cache"), .cache, .high, "Bun cache",
             "Packages Bun downloaded.",
             Policy(.likelySafe, safe: "Bun downloads packages again on the next install.", risks: "Installs need the network until it refills.",
                    action: "Clear the Bun cache", command: "bun pm cache rm"))
        leaf("deno.cache", home("Library/Caches/deno"), .cache, .high, "Deno cache",
             "Modules and compiled code Deno downloaded.",
             Policy(.likelySafe, safe: "Deno downloads and compiles them again when needed.", risks: "The next run needs the network.",
                    action: "Clear the Deno cache"))
        leaf("nvm.versions", home(".nvm/versions"), .developerTools, .high, "Node.js versions (nvm)",
             "Node.js versions installed with nvm.",
             Policy(.reviewFirst, safe: "Versions you no longer use can be reinstalled with nvm in a minute.",
                    risks: "A project pinned to that version with .nvmrc needs it reinstalled.", action: "Remove this Node.js version",
                    command: "nvm uninstall <version>", expansion: .childrenOf("node"), minimumSize: 30_000_000))
        area("nvm.home", home(".nvm"), .developerTools, .high, "nvm", "The nvm installation and the Node.js versions it manages.")
        leaf("cargo.registry", home(".cargo/registry"), .cache, .high, "Cargo registry cache",
             "Crate sources and the index Cargo downloaded.",
             Policy(.likelySafe, safe: "Cargo downloads crates again when a project builds.", risks: "The next build is slower and needs the network.",
                    action: "Clear the Cargo registry cache"))
        leaf("cargo.git", home(".cargo/git"), .cache, .high, "Cargo git checkouts",
             "Git dependencies Cargo checked out.",
             Policy(.likelySafe, safe: "Cargo checks them out again when a project builds.", risks: "The next build needs the network.",
                    action: "Clear Cargo's git checkouts"))
        leaf("rustup.toolchains", home(".rustup/toolchains"), .developerTools, .high, "Rust toolchains",
             "Rust compilers installed with rustup.",
             Policy(.reviewFirst, methods: [], safe: "Toolchains you no longer use can be removed with rustup.",
                    risks: "Projects pinned to that toolchain need it reinstalled.", action: "Uninstall unused toolchains",
                    command: "rustup toolchain uninstall <toolchain>", expansion: .children, minimumSize: 100_000_000))
        area("cargo.home", home(".cargo"), .developerTools, .high, "Cargo", "Cargo's installed tools, registry cache and git checkouts.")
        area("rustup.home", home(".rustup"), .developerTools, .high, "rustup", "Rust toolchains and components.")
        leaf("gradle.caches", home(".gradle/caches"), .cache, .high, "Gradle caches",
             "Dependencies and build caches Gradle downloaded.",
             Policy(.likelySafe, safe: "Gradle downloads dependencies again on the next build.",
                    risks: "The next build is slow and needs the network.", action: "Clear Gradle's caches",
                    command: "gradle --stop", before: "Stop Gradle daemons first (gradle --stop)."))
        leaf("gradle.wrapper", home(".gradle/wrapper/dists"), .developerTools, .high, "Gradle versions",
             "Gradle versions downloaded by projects' Gradle wrapper.",
             Policy(.reviewFirst, safe: "A project downloads its Gradle version again when it next builds.",
                    risks: "The next build of a project on that version downloads it again.", action: "Remove this Gradle version",
                    expansion: .children, minimumSize: 50_000_000))
        area("gradle.home", home(".gradle"), .developerTools, .high, "Gradle", "Gradle's caches, downloaded versions and daemon data.")
        leaf("maven.repo", home(".m2/repository"), .cache, .high, "Maven repository",
             "Java dependencies Maven downloaded.",
             Policy(.likelySafe, safe: "Maven downloads them again on the next build.", risks: "The next build is slow and needs the network.",
                    action: "Clear the Maven repository"))
        leaf("go.modcache", home("go/pkg/mod"), .cache, .high, "Go module cache",
             "Go modules downloaded for your projects.",
             Policy(.likelySafe, methods: [], safe: "Go downloads modules again when a project builds.",
                    risks: "Files here are read-only, so Go's own command is the way to clear it.", action: "Clear the Go module cache",
                    command: "go clean -modcache"))
        leaf("go.buildcache", home("Library/Caches/go-build"), .cache, .high, "Go build cache",
             "Compiled packages Go keeps to speed up builds.",
             Policy(.likelySafe, safe: "Go rebuilds what it needs.", risks: "The next build is slower.", action: "Clear the Go build cache",
                    command: "go clean -cache"))
        leaf("cocoapods.cache", home("Library/Caches/CocoaPods"), .cache, .high, "CocoaPods cache",
             "Pods CocoaPods downloaded.",
             Policy(.likelySafe, safe: "CocoaPods downloads pods again on the next install.", risks: "The next pod install is slower.",
                    action: "Clear the CocoaPods cache", command: "pod cache clean --all"))
        leaf("carthage.cache", home("Library/Caches/org.carthage.CarthageKit"), .cache, .high, "Carthage cache",
             "Dependencies Carthage downloaded.",
             Policy(.likelySafe, safe: "Carthage downloads them again.", risks: "The next build is slower.", action: "Clear the Carthage cache"))
        leaf("spm.cache", home("Library/Caches/org.swift.swiftpm"), .cache, .high, "Swift Package Manager cache",
             "Packages Swift Package Manager downloaded.",
             Policy(.likelySafe, safe: "SwiftPM downloads packages again when it resolves them.", risks: "The next resolve needs the network.",
                    action: "Clear the SwiftPM cache"))
        leaf("homebrew.cache", home("Library/Caches/Homebrew"), .cache, .high, "Homebrew downloads",
             "Bottles and source archives Homebrew downloaded.",
             Policy(.likelySafe, safe: "Homebrew downloads them again if it needs them.", risks: "Reinstalling a package needs the network.",
                    action: "Clear Homebrew's downloads", command: "brew cleanup --prune=all"))
        leaf("pip.cache", home("Library/Caches/pip"), .cache, .high, "pip cache",
             "Python packages pip downloaded.",
             Policy(.likelySafe, safe: "pip downloads packages again when needed.", risks: "Installs need the network.",
                    action: "Clear the pip cache", command: "pip cache purge"))
        leaf("poetry.cache", home("Library/Caches/pypoetry"), .cache, .high, "Poetry cache",
             "Packages and virtual environments Poetry keeps.",
             Policy(.likelySafe, safe: "Poetry downloads packages again when needed.", risks: "Environments Poetry made here need recreating.",
                    action: "Clear the Poetry cache", command: "poetry cache clear --all ."))
        leaf("uv.cache", home(".cache/uv"), .cache, .high, "uv cache",
             "Python packages uv downloaded and built.",
             Policy(.likelySafe, safe: "uv downloads packages again when needed.", risks: "Installs need the network.",
                    action: "Clear the uv cache", command: "uv cache clean"))
        leaf("huggingface.hub", home(".cache/huggingface"), .binaryData, .high, "Hugging Face models",
             "Models and datasets downloaded from Hugging Face.",
             Policy(.reviewFirst, safe: "Models download again when code asks for them.", risks: "Large models take a long time to download again.",
                    action: "Remove this model", expansion: .childrenOf("hub"), minimumSize: 100_000_000))
        leaf("ollama.models", home(".ollama/models"), .binaryData, .high, "Ollama models",
             "Local language models pulled with Ollama.",
             Policy(.keep, safe: "", risks: "Models are large to download again.", action: "Remove models you no longer use", command: "ollama rm <model>"))
        leaf("lmstudio.models", home(".lmstudio/models"), .binaryData, .high, "LM Studio models",
             "Local language models downloaded in LM Studio.",
             Policy(.keep, safe: "", risks: "Models are large to download again.", action: "Remove models you no longer use in LM Studio"))
        leaf("android.avd", home(".android/avd"), .developerTools, .high, "Android emulators",
             "Android virtual devices and their disks.",
             Policy(.reviewFirst, safe: "Emulators you no longer use can be recreated in Android Studio.",
                    risks: "An emulator can hold app data you set up for testing.", action: "Remove this emulator",
                    expansion: .children, minimumSize: 200_000_000))
        area("android.home", home(".android"), .developerTools, .medium, "Android tools data",
             "Emulator images, the debug signing key and adb settings.")
        leaf("android.sdk", home("Library/Android/sdk"), .developerTools, .high, "Android SDK",
             "Android SDK platforms, build tools and system images.")
        leaf("flutter.pub", home(".pub-cache/hosted"), .cache, .high, "Dart and Flutter packages",
             "Packages fetched with flutter pub get.",
             Policy(.likelySafe, safe: "They download again when a project fetches its packages.", risks: "The next fetch needs the network.",
                    action: "Clear the pub cache", command: "flutter pub cache clean"))
        area("flutter.pub-home", home(".pub-cache"), .developerTools, .high, "Dart and Flutter pub cache",
             "Downloaded packages and globally activated Dart tools.")
        leaf("jetbrains.caches", home("Library/Caches/JetBrains"), .cache, .high, "JetBrains IDE caches",
             "Indexes and caches for IntelliJ IDEA, PyCharm, WebStorm and other JetBrains IDEs, one folder per version.",
             Policy(.likelySafe, safe: "The IDE rebuilds its indexes when it opens a project.",
                    risks: "The first open of each project afterwards reindexes. Folders for versions you upgraded from are pure leftovers.",
                    action: "Clear this IDE's cache", expansion: .children, minimumSize: 100_000_000,
                    before: "Quit the JetBrains IDE first."))
        leaf("jetbrains.logs", home("Library/Logs/JetBrains"), .logs, .high, "JetBrains IDE logs",
             "Logs written by JetBrains IDEs.",
             Policy(.likelySafe, safe: "Logs are only read when troubleshooting.", risks: "None in normal use.",
                    action: "Remove these logs", minimumSize: 20_000_000))
        leaf("unreal.ddc", home("Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache"), .buildArtifacts, .high,
             "Unreal Engine shared cache", "Compiled shaders and cooked assets shared by all Unreal projects.",
             Policy(.reviewFirst, safe: "Unreal rebuilds the cache when needed.", risks: "Rebuilding can take a long time.",
                    action: "Clear the shared cache"))

        // MARK: AI coding tools and editors

        leaf("ai.claude-code-versions", home(".local/share/claude"), .developerTools, .high, "Claude Code installs",
             "Installed versions of the Claude Code command-line tool.")
        area("ai.claude-code", home(".claude"), .developerTools, .high, "Claude Code data",
             "Claude Code settings, conversation transcripts and per-project memory. Conversation history exists only here.")
        area("ai.codex", home(".codex"), .developerTools, .high, "Codex data", "Codex CLI settings, sessions and logs.")
        area("ai.gemini", home(".gemini"), .developerTools, .high, "Gemini CLI data", "Gemini CLI settings and session data.")
        area("xdg.cache", home(".cache"), .cache, .medium, "Command-line tool caches",
             "A cache folder shared by many command-line tools. Some keep large downloads here.",
             Policy(.reviewFirst, safe: "Tools rebuild their caches.", risks: "Some tools keep slow-to-download files here, such as models.",
                    action: "Clear this tool's cache", expansion: .children, minimumSize: 100_000_000))
        for editor in [("cursor", "Cursor"), ("vscode", "Code"), ("windsurf", "Windsurf")] {
            let (id, folder) = editor
            let name = folder == "Code" ? "VS Code" : folder
            for cache in ["Cache", "CachedData", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "CachedExtensionVSIXs", "CachedProfilesData", "Service Worker"] {
                leaf("\(id).cache.\(cache)", home("Library/Application Support/\(folder)/\(cache)"), .cache, .high, "\(name) cache",
                     "A cache \(name) rebuilds by itself.",
                     Policy(.likelySafe, safe: "\(name) rebuilds it automatically.", risks: "Quit \(name) first.",
                            action: "Clear \(name)'s \(cache) folder", minimumSize: 20_000_000, before: "Quit \(name) first."))
            }
            leaf("\(id).logs", home("Library/Application Support/\(folder)/logs"), .logs, .high, "\(name) logs",
                 "Logs \(name) writes, one folder per session.",
                 Policy(.likelySafe, safe: "Logs are only read when troubleshooting.", risks: "None in normal use.",
                        action: "Remove \(name)'s logs", minimumSize: 20_000_000))
            leaf("\(id).workspaces", home("Library/Application Support/\(folder)/User/workspaceStorage"), .applicationData, .high,
                 "\(name) workspace storage", "Per-project state, including chat and agent history for each workspace.")
            area("\(id).app", home("Library/Application Support/\(folder)"), .applicationData, .high, "\(name) app data",
                 "\(name)'s settings, workspace storage, logs and caches.")
        }
        leaf("cursor.extensions", home(".cursor/extensions"), .developerTools, .high, "Cursor extensions", "Installed Cursor extensions.")
        leaf("vscode.extensions", home(".vscode/extensions"), .developerTools, .high, "VS Code extensions", "Installed VS Code extensions.")
        leaf("windsurf.extensions", home(".windsurf/extensions"), .developerTools, .high, "Windsurf extensions", "Installed Windsurf extensions.")

        // MARK: The user's Library

        leaf("trash", home(".Trash"), .userData, .high, "Trash",
             "Items you moved to the Trash. They take up space until the Trash is emptied.")
        area("library.caches", home("Library/Caches"), .cache, .high, "App caches",
             "Data apps keep to work faster. Apps recreate it when it is missing.",
             Policy(.likelySafe, safe: "macOS sets this folder aside for data apps can recreate.",
                    risks: "An app may be slower once, or download offline content again.", action: "Clear this app's cache",
                    expansion: .children, minimumSize: 50_000_000, before: "Quit the app first for the best result."))
        area("library.logs", home("Library/Logs"), .logs, .high, "App logs",
             "Logs written by apps and macOS. Useful when something goes wrong, rarely otherwise.",
             Policy(.reviewFirst, safe: "Logs are only read when troubleshooting.", risks: "You lose history you might want for a bug report.",
                    action: "Remove these logs", expansion: .children, minimumSize: 20_000_000))
        leaf("library.mail", home("Library/Mail"), .userData, .high, "Mail", "Mail messages and attachments stored on this Mac.",
             Policy(.keep, safe: "", risks: "Your mail.", action: "Manage it in Mail"))
        leaf("library.messages", home("Library/Messages"), .userData, .high, "Messages", "Messages history and attachments.",
             Policy(.keep, safe: "", risks: "Your conversations.", action: "Remove large attachments in Settings > General > Storage"))
        leaf("library.icloud", home("Library/Mobile Documents"), .userData, .high, "iCloud Drive",
             "Local copies of iCloud Drive files. Deleting files here deletes them from iCloud as well.",
             Policy(.keep, safe: "", risks: "Deleting here deletes from iCloud.", action: "Turn on Optimise Mac Storage in iCloud settings"))
        leaf("library.cloud", home("Library/CloudStorage"), .userData, .high, "Cloud storage",
             "Local copies of Dropbox, Google Drive, OneDrive and similar folders. Deleting here deletes in the cloud too.")
        leaf("library.photos", home("Pictures/Photos Library.photoslibrary"), .userData, .high, "Photos library",
             "Your Photos library.",
             Policy(.keep, safe: "", risks: "Your photos.", action: "Turn on Optimise Mac Storage in Photos settings"))
        area("library.app-support", home("Library/Application Support"), .applicationData, .medium, "App support data",
             "Data apps need to run: databases, settings and downloaded content.")
        area("library.containers", home("Library/Containers"), .applicationData, .medium, "Sandboxed app data",
             "Private folders of sandboxed apps, mostly from the App Store.")
        area("library.group-containers", home("Library/Group Containers"), .applicationData, .medium, "Shared app data",
             "Data shared between related apps from the same developer.")
        area("library", home("Library"), .applicationData, .low, "Your Library", "Settings and app data managed by macOS and apps.")

        // MARK: Home folders

        area("home.downloads", home("Downloads"), .downloads, .high, "Downloads",
             "Files you downloaded. Installers and archives are often no longer needed, but this can be the only copy of a file.")
        area("home.documents", home("Documents"), .userData, .high, "Documents", "Your Documents folder.")
        area("home.desktop", home("Desktop"), .userData, .high, "Desktop", "Files on your desktop.")
        area("home.pictures", home("Pictures"), .userData, .high, "Pictures", "Your pictures.")
        area("home.movies", home("Movies"), .userData, .high, "Movies", "Your videos and video projects.")
        area("home.music", home("Music"), .userData, .high, "Music", "Your music library and audio projects.")

        // MARK: Outside the home folder

        leaf("system.var-folders", .absolute("/private/var/folders"), .cache, .medium, "Temporary files",
             "Per-user temporary and cache folders macOS manages and cleans by itself.")
        leaf("system.system", .absolute("/System"), .systemFiles, .high, "macOS", "The read-only macOS system volume.")
        leaf("system.usr", .absolute("/usr"), .systemFiles, .high, "Unix system files", "Core Unix programs and libraries.")
        area("system.private", .absolute("/private"), .systemFiles, .high, "System data", "System settings, databases and swap files.")
        leaf("homebrew.prefix", .absolute("/opt/homebrew"), .developerTools, .high, "Homebrew",
             "Packages installed with Homebrew.",
             Policy(.reviewFirst, methods: [], safe: "Homebrew removes old versions and downloads itself.",
                    risks: "None: Homebrew keeps the versions you use.", action: "Remove old versions", command: "brew cleanup"))
        area("system.applications", .absolute("/Applications"), .applicationData, .high, "Applications", "Installed applications.")
        area("system.library", .absolute("/Library"), .systemFiles, .medium, "System library", "Settings, fonts, drivers and data for all users.")

        // MARK: Project folders, anywhere

        leaf("node.modules", .name(["node_modules"]), .developerTools, .high, "Node.js dependencies",
             "Packages npm, pnpm or Yarn installed for a project.",
             Policy(.reviewFirst, safe: "The project's install command brings them back, as long as its lockfile is intact.",
                    risks: "The project won't run until you install again.", action: "Remove node_modules",
                    command: "npm install", minimumSize: 50_000_000))
        leaf("node.next", .nameBeside([".next"], ["package.json"]), .buildArtifacts, .high, "Next.js build output",
             "Output and cache from next build and next dev.",
             Policy(.likelySafe, safe: "Next.js recreates it on the next build.", risks: "The next build is slower.",
                    action: "Remove .next", minimumSize: 20_000_000))
        leaf("node.framework-cache", .nameBeside([".turbo", ".parcel-cache", ".svelte-kit", ".nuxt", ".angular", ".vite", ".cache"], ["package.json"]),
             .buildArtifacts, .high, "JavaScript build cache", "Cache from a JavaScript framework or bundler.",
             Policy(.likelySafe, safe: "The bundler recreates it on the next build.", risks: "The next build is slower.",
                    action: "Remove this cache", minimumSize: 20_000_000))
        leaf("flutter.dart-tool", .nameBeside([".dart_tool"], ["pubspec.yaml"]), .buildArtifacts, .high, "Dart tool cache",
             "Package settings and build cache for a Dart or Flutter project.",
             Policy(.likelySafe, safe: "flutter pub get recreates it.", risks: "The next build is slower.", action: "Remove .dart_tool",
                    minimumSize: 20_000_000))
        leaf("flutter.build", .nameBeside(["build"], ["pubspec.yaml"]), .buildArtifacts, .high, "Flutter build output",
             "Compiled builds of a Flutter app.",
             Policy(.likelySafe, safe: "Flutter rebuilds it.", risks: "The next build is slower.", action: "Remove the build folder",
                    command: "flutter clean", minimumSize: 50_000_000))
        leaf("unity.library", .nameBeside(["Library"], ["ProjectSettings"]), .buildArtifacts, .high, "Unity project cache",
             "Imported assets and caches for a Unity project.",
             Policy(.likelySafe, safe: "Unity rebuilds it by reimporting the project.", risks: "Reimporting a large project takes a while.",
                    action: "Remove the Library folder", minimumSize: 100_000_000, before: "Close the project in Unity first."))
        leaf("unreal.project-ddc", .nameBeside(["DerivedDataCache", "Intermediate"], ["Config"]), .buildArtifacts, .medium, "Unreal project cache",
             "Compiled shaders and intermediate files for an Unreal project.",
             Policy(.reviewFirst, safe: "Unreal rebuilds them when the project opens.", risks: "Rebuilding can take a long time.",
                    action: "Remove this cache", minimumSize: 100_000_000))
        leaf("node.dist", .nameBeside(["dist", "build", "out"], ["package.json"]), .buildArtifacts, .medium, "Project build output",
             "Guessed from the folder name next to a package.json. Usually made by the build.",
             Policy(.reviewFirst, safe: "The project's build command recreates it.", risks: "Some projects keep hand-edited files here. Check first.",
                    action: "Remove the build output", minimumSize: 50_000_000))
        leaf("rust.target", .nameBeside(["target"], ["Cargo.toml"]), .buildArtifacts, .high, "Rust build output",
             "Everything Cargo compiled for a project.",
             Policy(.likelySafe, safe: "Cargo rebuilds it on the next build.", risks: "The next build is slower.",
                    action: "Remove target", command: "cargo clean", minimumSize: 50_000_000))
        leaf("swift.build", .nameBeside([".build"], ["Package.swift"]), .buildArtifacts, .high, "Swift package build output",
             "Everything Swift Package Manager built for a package.",
             Policy(.likelySafe, safe: "swift build recreates it.", risks: "The next build is slower.",
                    action: "Remove .build", command: "swift package clean", minimumSize: 50_000_000))
        leaf("java.target", .nameBeside(["target"], ["pom.xml"]), .buildArtifacts, .high, "Maven build output",
             "Classes and packages Maven built for a project.",
             Policy(.likelySafe, safe: "Maven rebuilds it.", risks: "The next build is slower.", action: "Remove target",
                    command: "mvn clean", minimumSize: 50_000_000))
        leaf("gradle.build", .nameBeside(["build"], ["build.gradle", "build.gradle.kts"]), .buildArtifacts, .high, "Gradle build output",
             "Everything Gradle built for a project.",
             Policy(.likelySafe, safe: "Gradle rebuilds it.", risks: "The next build is slower.", action: "Remove build",
                    command: "gradle clean", minimumSize: 50_000_000))
        leaf("python.venv", .nameBeside([".venv", "venv", "env"], ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock"]),
             .developerTools, .high, "Python virtual environment", "Python packages installed for a project.",
             Policy(.reviewFirst, safe: "It can be recreated from the project's dependency files.",
                    risks: "Packages installed by hand and not listed in those files are lost.", action: "Remove the virtual environment",
                    minimumSize: 50_000_000))
        leaf("python.pycache", .name(["__pycache__"]), .buildArtifacts, .high, "Python bytecode cache",
             "Compiled Python files. Python makes them again automatically.")
        leaf("python.tox", .nameBeside([".tox", ".nox", ".pytest_cache", ".mypy_cache", ".ruff_cache"], ["pyproject.toml", "setup.py", "tox.ini", "noxfile.py", "setup.cfg"]),
             .buildArtifacts, .high, "Python tool cache", "Test environments and caches made by Python tools.",
             Policy(.likelySafe, safe: "The tool recreates it on its next run.", risks: "The next run is slower.",
                    action: "Remove this cache", minimumSize: 20_000_000))
        leaf("cocoapods.pods", .nameBeside(["Pods"], ["Podfile"]), .developerTools, .high, "CocoaPods dependencies",
             "Dependencies installed by pod install.",
             Policy(.reviewFirst, safe: "pod install brings them back.", risks: "The project won't build until you install again.",
                    action: "Remove Pods", command: "pod install", minimumSize: 50_000_000))
        leaf("gradle.project", .nameBeside([".gradle"], ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]),
             .buildArtifacts, .high, "Gradle project cache", "Per-project Gradle cache.",
             Policy(.likelySafe, safe: "Gradle recreates it on the next build.", risks: "The next build is slower.",
                    action: "Remove .gradle", minimumSize: 20_000_000))
        leaf("xcode.local-derived", .name(["DerivedData"]), .buildArtifacts, .medium, "Xcode DerivedData",
             "A DerivedData folder, usually made by Xcode or xcodebuild with a custom build location.",
             Policy(.likelySafe, safe: "It is build output Xcode recreates.", risks: "Found by name only; check it belongs to a build.",
                    action: "Remove this DerivedData folder"))
        leaf("terraform.plugins", .name([".terraform"]), .buildArtifacts, .high, "Terraform providers",
             "Providers and modules terraform init downloaded.",
             Policy(.likelySafe, safe: "terraform init downloads them again.", risks: "The next init needs the network.",
                    action: "Remove .terraform", minimumSize: 50_000_000))
        leaf("git.data", .name([".git"]), .developerTools, .high, "Git history",
             "A repository's full history. Unpushed branches, stashes and commits exist only here.")
        area("project.code", .containing([".git"]), .userData, .medium, "Code project",
             "A folder under version control. Project sources are your work.")

        return rules
    }
}

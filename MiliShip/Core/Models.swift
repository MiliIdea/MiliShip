import Foundation

// MARK: - Helpers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

func expandPath(_ path: String, directory: Bool = false) -> URL {
    URL(fileURLWithPath: (path.trimmed as NSString).expandingTildeInPath, isDirectory: directory)
}

func abbreviatePath(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}

struct MiliShipError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func requireFile(_ path: String, _ label: String) throws -> URL {
    guard !path.trimmed.isEmpty else { throw MiliShipError(message: "\(label) is not set.") }
    let url = expandPath(path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw MiliShipError(message: "\(label) not found at \(url.path)")
    }
    return url
}

func requireValue(_ value: String, _ label: String) throws -> String {
    let result = value.trimmed
    guard !result.isEmpty else { throw MiliShipError(message: "\(label) is not set.") }
    return result
}

// MARK: - Enums

enum AppFramework: String, Codable, CaseIterable, Identifiable {
    case flutter, reactNative

    var id: String { rawValue }
    var title: String { self == .flutter ? "Flutter" : "React Native" }
    /// Where the version a release tag is compared against lives.
    var versionSource: String { self == .flutter ? "pubspec.yaml" : "the native projects" }
}

enum BuildTool: String, Codable, CaseIterable, Identifiable {
    case flutter, shorebird

    var id: String { rawValue }
    var title: String { self == .flutter ? "Flutter" : "Shorebird" }
    var detail: String {
        switch self {
        case .flutter:
            return "flutter build appbundle / flutter build ipa. Every release tag becomes a store build."
        case .shorebird:
            return "shorebird release for store builds, and shorebird patch for over-the-air Dart fixes (patch tags)."
        }
    }
}

enum ReleaseMode: String, Codable {
    case release, patch
    var title: String { rawValue.capitalized }
}

enum TargetPlatform: String, Codable, CaseIterable, Identifiable {
    case android, ios

    var id: String { rawValue }
    var title: String { self == .android ? "Android" : "iOS" }
    var storeTitle: String { self == .android ? "Google Play" : "App Store Connect" }
}

enum VersionStrategy: String, Codable, CaseIterable, Identifiable {
    case pubspecMatchesTag, tag, storeIncrement, pubspec

    var id: String { rawValue }

    func title(for framework: AppFramework) -> String {
        let source = framework == .flutter ? "pubspec.yaml" : "the project"
        switch self {
        case .pubspecMatchesTag: return "Tag must match \(source)"
        case .tag: return "Take the version from the tag"
        case .storeIncrement: return "Auto-increment the build number"
        case .pubspec: return "Use \(source) as-is"
        }
    }

    func detail(for framework: AppFramework) -> String {
        switch (self, framework) {
        case (.pubspecMatchesTag, .flutter):
            return "release/1.2.0+45 only builds if pubspec.yaml says version: 1.2.0+45. Safest: the version is reviewed in git."
        case (.pubspecMatchesTag, .reactNative):
            return "release/1.2.0+45 only builds if android/app/build.gradle has versionName \"1.2.0\" and versionCode 45 (iOS: MARKETING_VERSION / CURRENT_PROJECT_VERSION when there's no Android app)."
        case (.tag, .flutter):
            return "release/1.2.0+45 builds with --build-name 1.2.0 --build-number 45, whatever pubspec.yaml says."
        case (.tag, .reactNative):
            return "release/1.2.0+45 sets versionName/versionCode in build.gradle for the build and passes MARKETING_VERSION / CURRENT_PROJECT_VERSION to xcodebuild."
        case (.storeIncrement, _):
            return "Version name from the tag (or \(framework.versionSource)); build number = highest build on Google Play / App Store Connect + 1."
        case (.pubspec, _):
            return "Builds whatever version \(framework.versionSource) contain\(framework == .flutter ? "s" : ""). The tag is only the trigger."
        }
    }
}

enum PlayReleaseStatus: String, Codable, CaseIterable, Identifiable {
    case completed, inProgress, draft

    var id: String { rawValue }
    var title: String {
        switch self {
        case .completed: return "Roll out to the track"
        case .inProgress: return "Staged rollout"
        case .draft: return "Draft (finish in Play Console)"
        }
    }
}

enum AndroidSigning: String, Codable, CaseIterable, Identifiable {
    /// Google holds the app signing key; the bundle is signed with an upload key that can be reset in Play Console.
    case playAppSigning
    /// The bundle is signed with the app signing key itself (opted out of Play App Signing, or distributed elsewhere).
    case ownKey
    /// Nothing is written; android/app/build.gradle signs the bundle on its own.
    case gradle

    var id: String { rawValue }
    var title: String {
        switch self {
        case .playAppSigning: return "Google Play App Signing (upload key)"
        case .ownKey: return "My own app signing key"
        case .gradle: return "Handled by the project's Gradle config"
        }
    }
    var writesKeyProperties: Bool { self != .gradle }
}

enum IOSSigning: String, Codable, CaseIterable, Identifiable {
    case automatic, exportOptionsFile

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic (Xcode + API key)"
        case .exportOptionsFile: return "ExportOptions.plist from the repository"
        }
    }
}

// MARK: - Application configuration

/// owner/name of a repository hosted on github.com, parsed from any clone URL form.
struct GitHubRepo: Hashable {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }
    var webURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
    var actionsURL: URL { webURL.appendingPathComponent("actions") }

    init?(remote: String) {
        var text = remote.trimmed
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let path: Substring
        if let range = text.range(of: "github.com:") {        // git@github.com:owner/name
            path = text[range.upperBound...]
        } else if let range = text.range(of: "github.com/") { // https://, ssh://git@github.com/
            path = text[range.upperBound...]
        } else {
            return nil
        }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }
}

/// Deployments run as GitHub Actions jobs on a self-hosted runner that Mili Ship installs and manages.
struct GitHubActionsConfig: Codable, Equatable {
    var enabled = false
    /// Set once the runner is registered with GitHub.
    var runnerName = ""
    /// Unique label the workflow targets (`runs-on: [self-hosted, <label>]`).
    var runnerLabel = ""
    var runnerID: Int?
    /// Self-hosted runners on public repositories need workflow approval for outside contributors.
    var repositoryIsPublic = false
    var workflowFile = "miliship.yml"
    var timeoutMinutes = 180

    var isConnected: Bool { enabled && !runnerName.isEmpty && !runnerLabel.isEmpty }
    var workflowPath: String { ".github/workflows/\(workflowFile.trimmed.isEmpty ? "miliship.yml" : workflowFile.trimmed)" }
}

struct FileInjection: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Local file on this Mac.
    var source = ""
    /// Destination relative to the repository root.
    var destination = ""
}

struct ShorebirdConfig: Codable, Equatable {
    var allowNativeDiffs = false
    var allowAssetDiffs = false
    var flutterVersion = ""
}

struct ReactNativeConfig: Codable, Equatable {
    /// Runs `expo prebuild` after installing dependencies (Expo apps without committed android/ and ios/ folders).
    var expoPrebuild = false
    /// Empty skips CocoaPods. Runs in the ios/ folder.
    var podInstallCommand = "pod install"
    /// Relative to the app folder. Empty = the only .xcworkspace in ios/.
    var iosWorkspace = ""
    /// Empty = the workspace name.
    var iosScheme = ""
    var iosConfiguration = "Release"
    /// Empty = bundle<Flavor>Release.
    var androidGradleTask = ""
    var extraGradleArgs = ""
    var extraXcodebuildArgs = ""
}

struct AndroidConfig: Codable, Equatable {
    var enabled = true
    // Signing
    var signing: AndroidSigning = .playAppSigning
    /// Legacy flag from before `signing` existed; `false` in older configs means the Gradle config signs.
    var writeKeyProperties = true
    var keystorePath = ""
    var keyAlias = ""
    var keyPropertiesPath = "android/key.properties"
    // Google Play
    var upload = true
    var packageName = ""
    var serviceAccountPath = ""
    var track = "internal"
    var releaseStatus: PlayReleaseStatus = .completed
    var rolloutPercent = 10.0
    var changesNotSentForReview = false
    var releaseNotesLanguage = "en-US"
    var releaseNotes = ""

    var effectiveSigning: AndroidSigning { writeKeyProperties ? signing : .gradle }
    var writesKeyProperties: Bool { effectiveSigning.writesKeyProperties }
}

struct IOSConfig: Codable, Equatable {
    var enabled = true
    var bundleID = ""
    var teamID = ""
    var ascKeyID = ""
    var ascIssuerID = ""
    var ascKeyPath = ""
    var signing: IOSSigning = .automatic
    var exportOptionsPath = ""
    var upload = true
}

struct AppConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""

    // Repository
    var repoURL = ""
    var workspacePath = ""

    // Project
    var framework: AppFramework = .flutter
    var appPath = "."
    var flutterCommand = "flutter"
    var bootstrapCommand = "flutter pub get"
    var flavor = ""
    var target = ""
    var dartDefineFile = ""
    var extraBuildArgs = ""
    var reactNative = ReactNativeConfig()

    // Prepare
    var fileInjections: [FileInjection] = []
    var preBuildCommands = ""

    // Build & versioning
    var buildTool: BuildTool = .flutter
    var shorebird = ShorebirdConfig()
    var releaseTagPrefix = "release/"
    var patchTagPrefix = "patch/"
    var versionStrategy: VersionStrategy = .pubspecMatchesTag
    var watchTags = false
    var pollMinutes = 5
    var autoBuild = true

    // GitHub Actions
    var githubActions = GitHubActionsConfig()

    // Stores
    var android = AndroidConfig()
    var ios = IOSConfig()

    var displayName: String { name.trimmed.isEmpty ? "Untitled app" : name.trimmed }
    var githubRepo: GitHubRepo? { GitHubRepo(remote: repoURL) }
    /// GitHub triggers deployments for connected apps; Mili Ship's own tag watcher only lists tags then.
    var deploysThroughActions: Bool { githubActions.isConnected && githubRepo != nil }

    var workspaceURL: URL {
        workspacePath.trimmed.isEmpty ? AppPaths.defaultWorkspace(for: self) : expandPath(workspacePath, directory: true)
    }

    var enabledPlatforms: [TargetPlatform] {
        var result: [TargetPlatform] = []
        if android.enabled { result.append(.android) }
        if ios.enabled { result.append(.ios) }
        return result
    }

    /// Shorebird only exists for Flutter; the setting is ignored for other frameworks.
    var usesShorebird: Bool { framework == .flutter && buildTool == .shorebird }
    var supportsPatches: Bool { usesShorebird && !patchTagPrefix.isEmpty }
    var buildToolTitle: String { framework == .flutter ? buildTool.title : framework.title }

    /// Gradle task for React Native builds: the configured one, or bundle<Flavor>Release.
    var reactNativeGradleTask: String {
        let custom = reactNative.androidGradleTask.trimmed
        if !custom.isEmpty { return custom }
        let flavor = self.flavor.trimmed
        return "bundle\(flavor.prefix(1).uppercased() + flavor.dropFirst())Release"
    }

    func releaseTag(named tagName: String) -> ReleaseTag? {
        var prefixes: [(String, ReleaseMode)] = []
        if !releaseTagPrefix.isEmpty { prefixes.append((releaseTagPrefix, .release)) }
        if supportsPatches { prefixes.append((patchTagPrefix, .patch)) }
        for (prefix, mode) in prefixes.sorted(by: { $0.0.count > $1.0.count })
        where tagName.hasPrefix(prefix) && tagName.count > prefix.count {
            return ReleaseTag(name: tagName, mode: mode, suffix: String(tagName.dropFirst(prefix.count)))
        }
        return nil
    }

    /// Applies values detected by `ProjectScanner` (only fills blanks for identifiers).
    mutating func apply(_ project: DetectedProject, from scan: RepoScan) {
        appPath = project.appPath
        framework = project.framework
        if name.trimmed.isEmpty { name = project.packageName }
        switch project.framework {
        case .flutter:
            flutterCommand = scan.usesFVM ? "fvm flutter" : "flutter"
            bootstrapCommand = scan.usesMelos ? "melos bootstrap" : "\(flutterCommand) pub get"
            if project.usesShorebird { buildTool = .shorebird }
            if dartDefineFile.trimmed.isEmpty, let first = project.dartDefineFiles.first { dartDefineFile = first }
        case .reactNative:
            if let rn = project.reactNative {
                bootstrapCommand = rn.installCommand
                reactNative.expoPrebuild = rn.needsPrebuild
                reactNative.podInstallCommand = rn.podInstallCommand
                reactNative.iosWorkspace = rn.iosWorkspace ?? ""
                reactNative.iosScheme = rn.iosScheme ?? ""
            }
        }
        android.enabled = project.hasAndroid
        ios.enabled = project.hasIOS
        if android.packageName.trimmed.isEmpty, let id = project.androidApplicationID { android.packageName = id }
        if ios.bundleID.trimmed.isEmpty, let id = project.iosBundleID { ios.bundleID = id }
        if ios.teamID.trimmed.isEmpty, let team = project.iosTeamID { ios.teamID = team }
    }

    /// Things that will make a deployment fail. Shown on the review step and the app page.
    func setupWarnings(hasSecret: (SecretKey) -> Bool) -> [String] {
        var warnings: [String] = []
        if repoURL.trimmed.isEmpty { warnings.append("Repository URL is missing.") }
        if enabledPlatforms.isEmpty { warnings.append("Enable Android and/or iOS.") }
        if releaseTagPrefix.isEmpty { warnings.append("Release tag prefix is empty.") }
        if githubActions.enabled {
            if githubRepo == nil {
                warnings.append("GitHub Actions: the repository isn't on github.com.")
            } else if !hasSecret(.githubToken) {
                warnings.append("GitHub Actions: add a GitHub token.")
            } else if !githubActions.isConnected {
                warnings.append("GitHub Actions: connect the runner.")
            }
        }
        if usesShorebird && !hasSecret(.shorebirdToken) {
            warnings.append("No Shorebird token: builds rely on `shorebird login` on this Mac.")
        }
        if android.enabled {
            if android.writesKeyProperties {
                if android.keystorePath.trimmed.isEmpty { warnings.append(android.signing == .ownKey ? "Android: choose the signing keystore." : "Android: choose or generate the upload keystore.") }
                if android.keyAlias.trimmed.isEmpty { warnings.append("Android: key alias is missing.") }
                if !hasSecret(.androidKeystorePassword) { warnings.append("Android: keystore password is missing.") }
            }
            if android.upload {
                if android.packageName.trimmed.isEmpty { warnings.append("Google Play: package name is missing.") }
                if android.serviceAccountPath.trimmed.isEmpty { warnings.append("Google Play: service account JSON is missing.") }
            }
        }
        if ios.enabled {
            let needsKey = ios.signing == .automatic || ios.upload
            if needsKey && (ios.ascKeyID.trimmed.isEmpty || ios.ascIssuerID.trimmed.isEmpty || ios.ascKeyPath.trimmed.isEmpty) {
                warnings.append("App Store: API key (Key ID, Issuer ID, .p8) is incomplete.")
            }
            if ios.signing == .automatic && ios.teamID.trimmed.isEmpty {
                warnings.append("App Store: Apple team ID is required for automatic signing.")
            }
            if ios.signing == .exportOptionsFile && ios.exportOptionsPath.trimmed.isEmpty {
                warnings.append("App Store: choose the ExportOptions.plist.")
            }
        }
        if versionStrategy == .storeIncrement {
            let playReady = android.enabled && android.upload && !android.serviceAccountPath.trimmed.isEmpty
            let ascReady = ios.enabled && !ios.ascKeyPath.trimmed.isEmpty && !ios.bundleID.trimmed.isEmpty
            if !playReady && !ascReady {
                warnings.append("Auto-increment needs Google Play or App Store Connect API access to read the last build number.")
            }
        }
        return warnings
    }
}

struct GlobalSettings: Codable, Equatable {
    var extraPATH = ""
    var notifications = true
    /// Closing the window keeps Mili Ship in the menu bar (no Dock icon) so it goes on watching tags.
    var runInBackground = true
}

// MARK: - Tags & versions

struct VersionParts: Hashable {
    let name: String
    let number: String?

    var full: String { number.map { "\(name)+\($0)" } ?? name }
    var pretty: String { number.map { "\(name) (\($0))" } ?? name }

    private static let regex = try! NSRegularExpression(pattern: #"^v?(\d+(?:\.\d+){0,3})(?:\+(\d+))?$"#)

    init(name: String, number: String?) {
        self.name = name
        self.number = number
    }

    init?(parsing raw: String) {
        let text = raw.trimmed
        guard let match = Self.regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text)
        else { return nil }
        name = String(text[nameRange])
        number = Range(match.range(at: 2), in: text).map { String(text[$0]) }
    }
}

struct ReleaseTag: Hashable {
    let name: String
    let mode: ReleaseMode
    /// Everything after the prefix, e.g. "1.2.0+45".
    let suffix: String

    var version: VersionParts? { VersionParts(parsing: suffix) }
}

struct TagEntry: Identifiable, Hashable {
    let tag: ReleaseTag
    let commit: String
    let date: Date?

    var id: String { tag.name }
}

struct SeenTags: Codable {
    var initialized = false
    var names: Set<String> = []
}

// MARK: - Builds

enum RunStatus: String, Codable {
    case queued, running, succeeded, failed, cancelled, skipped

    var isFinished: Bool { self != .queued && self != .running }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .running: return "hammer"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        case .skipped: return "minus.circle"
        }
    }
}

struct StepRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    let name: String
    var status: RunStatus
    var startedAt: Date?
    var finishedAt: Date?
}

struct BuildRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let appID: UUID
    var appName: String
    let tagName: String
    let mode: ReleaseMode
    let platforms: [TargetPlatform]
    var trigger: String
    var status: RunStatus
    var queuedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var commit: String?
    var version: String?
    var steps: [StepRecord]
    /// Keyed by `TargetPlatform.rawValue`.
    var platformStatus: [String: RunStatus]
    var results: [String]
    var failureReason: String?
    /// The GitHub Actions run this deployment belongs to.
    var actionsRunURL: String?

    init(app: AppConfig, tag: ReleaseTag, platforms: [TargetPlatform], trigger: String) {
        id = UUID()
        appID = app.id
        appName = app.displayName
        tagName = tag.name
        mode = tag.mode
        self.platforms = platforms
        self.trigger = trigger
        status = .queued
        queuedAt = Date()
        steps = []
        platformStatus = Dictionary(uniqueKeysWithValues: platforms.map { ($0.rawValue, RunStatus.queued) })
        results = []
    }

    var logFileName: String { "\(id.uuidString).log" }

    func status(of platform: TargetPlatform) -> RunStatus {
        platformStatus[platform.rawValue] ?? .queued
    }
}

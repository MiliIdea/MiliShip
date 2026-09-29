import AppKit
import Combine
import Foundation
import UserNotifications

enum SidebarItem: Hashable {
    case welcome
    case app(UUID)
    case build(UUID)
}

@MainActor
final class AppModel: ObservableObject {
    struct RefreshState {
        var isRefreshing = false
        var lastRefresh: Date?
        var lastAttempt: Date?
        var error: String?
    }

    struct WizardRequest: Identifiable {
        let id = UUID()
        let app: AppConfig
        let isNew: Bool
        var step: WizardStep = .repository
        /// Open on the Review step and run the pre-flight check right away.
        var runCheck = false
    }

    struct ToolStatus: Identifiable, Hashable {
        let name: String
        let purpose: String
        let optional: Bool
        let path: String?

        var id: String { name }
        var found: Bool { path != nil }
    }

    static let toolCatalog: [(name: String, purpose: String, optional: Bool)] = [
        ("git", "Clone repositories and fetch tags", false),
        ("flutter", "Flutter builds", true),
        ("node", "React Native builds", true),
        ("xcodebuild", "iOS builds and App Store uploads", false),
        ("shorebird", "Shorebird releases and patches", true),
        ("fvm", "FVM-managed Flutter versions", true),
        ("melos", "melos monorepos", true),
        ("pod", "CocoaPods for iOS plugins", true),
        ("java", "Android Gradle builds", true),
    ]

    @Published private(set) var apps: [AppConfig]
    @Published var global: GlobalSettings {
        didSet {
            BackgroundMode.enabled = global.runInBackground
            if global != oldValue { Persistence.save(global, to: AppPaths.globalFile) }
        }
    }
    @Published private(set) var tagsByApp: [UUID: [TagEntry]] = [:]
    @Published private(set) var refreshStates: [UUID: RefreshState] = [:]
    @Published private(set) var history: [BuildRecord]
    @Published private(set) var activeBuildID: UUID?
    @Published var selection: SidebarItem?
    @Published var wizard: WizardRequest?
    @Published private(set) var tools: [ToolStatus] = []
    @Published private(set) var checkingTools = false

    let liveLog = LiveLog()
    let runners = RunnerManager()
    /// Deploy requests sent to GitHub Actions that haven't reached the runner yet ("<app id>|<tag>").
    @Published private(set) var pendingDispatches: Set<String> = []

    private var bridge: ActionsBridge?
    private var runnerObserver: AnyCancellable?
    private var cancelReasons: [UUID: String] = [:]
    private var appsFileDate: Date?
    private var fileWatch: Timer?

    private var seen: [String: SeenTags]
    private var storedSecretKeys: [UUID: (stored: Set<SecretKey>, blocked: [SecretKey], checked: Date)] = [:]
    private var pollTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    private var pipeline: BuildPipeline?
    private var sleepActivity: NSObjectProtocol?
    private let historyLimit = 300

    init() {
        apps = Persistence.loadApps()
        appsFileDate = Self.modificationDate(AppPaths.appsFile)
        let settings = Persistence.loadMerged(GlobalSettings(), from: AppPaths.globalFile)
        global = settings
        BackgroundMode.enabled = settings.runInBackground
        seen = Persistence.load([String: SeenTags].self, from: AppPaths.seenTagsFile) ?? [:]

        var loaded = Persistence.load([BuildRecord].self, from: AppPaths.historyFile) ?? []
        for index in loaded.indices where loaded[index].status == .running {
            loaded[index].status = .failed
            loaded[index].failureReason = "Interrupted — Mili Ship quit while this build was running."
            loaded[index].finishedAt = Date()
        }
        history = loaded
        selection = apps.first.map { .app($0.id) } ?? .welcome

        requestNotificationPermission()
        startPolling()
        let unwatched = apps.filter { !$0.watchTags }.map(\.id)
        Task {
            for id in unwatched { await refreshTags(for: id) }
        }
        processQueue()

        BackgroundMode.busyDescription = { [weak self] in
            guard let self else { return nil }
            if let record = self.activeRecord { return "\(record.appName) \(record.tagName) is still deploying." }
            let queued = self.queuedCount
            return queued > 0 ? "\(queued) deployment\(queued == 1 ? " is" : "s are") waiting in the queue." : nil
        }
        BackgroundMode.willTerminate = { [weak self] in self?.runners.stopAll() }

        runnerObserver = runners.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        fileWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadAppsIfChangedOnDisk() }
        }
        bridge = ActionsBridge(model: self)
        reconcileRunners()
    }

    // MARK: - GitHub Actions

    func runnerState(for appID: UUID) -> RunnerState { runners.state(for: appID) }

    private func reconcileRunners() {
        runners.reconcile(apps: apps, environment: Toolchain.environment(global: global))
    }

    func restartRunner(_ appID: UUID) {
        guard let app = self.app(appID) else { return }
        runners.restart(app, environment: Toolchain.environment(global: global))
    }

    /// Wizard: registers the runner for the draft. `token` falls back to the one in the Keychain.
    /// Tries the token typed in the wizard, then the saved one, then the GitHub CLI login, and returns the first
    /// that can see the repository. Fine-grained tokens often can't see organization repositories (404).
    func workingGitHubToken(for draft: AppConfig, typed: String?, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> (token: String, source: String) {
        guard let repo = draft.githubRepo else { throw MiliShipError(message: "The repository isn't on github.com.") }
        var candidates: [(token: String, source: String)] = []
        if let typed = typed?.trimmed, !typed.isEmpty { candidates.append((typed, "the token you entered")) }
        if let saved = Keychain.get(.githubToken, app: draft.id), !saved.isEmpty { candidates.append((saved, "the saved token")) }
        if let cli = try? await githubCLIToken() {
            candidates.append((cli.token, cli.login.isEmpty ? "your GitHub CLI login" : "your GitHub CLI login (@\(cli.login))"))
        }
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.token).inserted }
        guard !candidates.isEmpty else {
            throw MiliShipError(message: "No GitHub token. Paste one, or sign in to the GitHub CLI with “gh auth login” and try again.")
        }
        var refused: [String] = []
        for candidate in candidates {
            do {
                _ = try await GitHubClient(token: candidate.token, repo: repo).repository()
                if !refused.isEmpty { log("Using \(candidate.source)\n") }
                return candidate
            } catch let error as GitHubClient.APIError where [401, 403, 404].contains(error.status) {
                refused.append(candidate.source)
                log("\(candidate.source.prefix(1).uppercased() + candidate.source.dropFirst()) can't access \(repo.fullName); trying the next one…\n")
            }
        }
        throw MiliShipError(message: "None of the available tokens can access \(repo.fullName) (tried \(refused.joined(separator: ", "))). Fine-grained tokens need the organization as their owner; the GitHub CLI login (“gh auth login”) usually works.")
    }

    func connectActions(_ draft: AppConfig, token: String?, log: @escaping @Sendable (String) -> Void) async throws -> (config: GitHubActionsConfig, token: String) {
        let credential = try await workingGitHubToken(for: draft, typed: token, log: log)
        let config = try await runners.connect(draft, token: credential.token, environment: Toolchain.environment(global: global), log: log)
        // Saved apps: keep the stored configuration and token in step so the runner starts right away.
        if let index = apps.firstIndex(where: { $0.id == draft.id }) {
            apps[index].githubActions = config
            Keychain.set(credential.token, for: .githubToken, app: draft.id)
            storedSecretKeys[draft.id] = nil
            persistApps()
            reconcileRunners()
        }
        return (config, credential.token)
    }

    func disconnectActions(_ draft: AppConfig, token: String?) async -> GitHubActionsConfig {
        let token = token.flatMap { $0.isEmpty ? nil : $0 } ?? Keychain.get(.githubToken, app: draft.id)
        await runners.disconnect(draft, token: token, environment: Toolchain.environment(global: global))
        var config = draft.githubActions
        config.runnerName = ""
        config.runnerLabel = ""
        config.runnerID = nil
        if let index = apps.firstIndex(where: { $0.id == draft.id }) {
            apps[index].githubActions = config
            persistApps()
        }
        return config
    }

    /// Commits the workflow (or opens a pull request) and describes what happened.
    func installWorkflow(_ draft: AppConfig, token: String?) async throws -> (message: String, url: URL?) {
        guard let repo = draft.githubRepo else { throw MiliShipError(message: "The repository isn't on github.com.") }
        let client = GitHubClient(token: try await workingGitHubToken(for: draft, typed: token).token, repo: repo)
        let repository = try await client.repository()
        let path = draft.githubActions.workflowPath
        switch try await client.installWorkflow(path: path, content: ActionsWorkflow.yaml(for: draft), defaultBranch: repository.defaultBranch) {
        case .unchanged:
            return ("\(path) is already up to date on \(repository.defaultBranch).", repo.webURL.appendingPathComponent("blob/\(repository.defaultBranch)/\(path)"))
        case .committed(let branch):
            return ("Committed \(path) to \(branch). Tags created from now on deploy through GitHub Actions.", repo.webURL.appendingPathComponent("blob/\(branch)/\(path)"))
        case .pullRequest(let url):
            return ("\(repository.defaultBranch) is protected, so a pull request was opened. Merge it, then tag as usual.", url)
        }
    }

    /// Called by the bridge for every job the runner hands over.
    func acceptActionsJob(_ request: ActionsBridge.Request) -> Result<BuildRecord, MiliShipError> {
        guard let id = UUID(uuidString: request["app"]), let app = self.app(id) else {
            return .failure(MiliShipError(message: "This runner belongs to an application that no longer exists in Mili Ship."))
        }
        guard request["ref"].hasPrefix("refs/tags/") else {
            return .failure(MiliShipError(message: "Mili Ship deploys tags. Run the workflow on a tag (Use workflow from → Tags)."))
        }
        guard let tag = app.releaseTag(named: request["tag"]) else {
            var prefixes = [app.releaseTagPrefix]
            if app.supportsPatches { prefixes.append(app.patchTagPrefix) }
            return .failure(MiliShipError(message: "\(request["tag"]) doesn't start with \(prefixes.joined(separator: " or ")), so \(app.displayName) doesn't deploy it."))
        }
        let requested = request["platforms"]
        let platforms = app.enabledPlatforms.filter { requested.isEmpty || requested == "all" || $0.rawValue == requested }
        guard !platforms.isEmpty else {
            return .failure(MiliShipError(message: "\(requested) isn't enabled for \(app.displayName)."))
        }
        pendingDispatches.remove("\(app.id)|\(tag.name)")

        let actor = request["actor"]
        let trigger = "GitHub Actions" + (actor.isEmpty ? "" : " · \(actor)")
        let recordID = history.first { $0.appID == app.id && $0.tagName == tag.name && !$0.status.isFinished }?.id
            ?? enqueue(appID: app.id, tag: tag, platforms: platforms, trigger: trigger, select: false)
        guard let recordID else { return .failure(MiliShipError(message: "Mili Ship couldn't queue \(tag.name).")) }
        let runURL = request["run_url"]
        update(recordID) { if $0.actionsRunURL == nil, !runURL.isEmpty { $0.actionsRunURL = runURL } }
        guard let record = history.first(where: { $0.id == recordID }) else {
            return .failure(MiliShipError(message: "Mili Ship couldn't queue \(tag.name)."))
        }
        return .success(record)
    }

    /// Deploys through GitHub Actions for connected apps (so the run shows up there), otherwise locally.
    func deploy(appID: UUID, tag: ReleaseTag, platforms: [TargetPlatform], trigger: String = "manual") {
        guard let app = self.app(appID), !platforms.isEmpty, !isBusy(appID: appID, tagName: tag.name) else { return }
        guard app.deploysThroughActions, runners.state(for: appID).isHealthy,
              let token = Keychain.get(.githubToken, app: appID), let repo = app.githubRepo
        else {
            enqueue(appID: appID, tag: tag, platforms: platforms, trigger: trigger)
            return
        }
        let key = "\(appID)|\(tag.name)"
        pendingDispatches.insert(key)
        let inputs = ["platforms": platforms.count == app.enabledPlatforms.count ? "all" : platforms[0].rawValue]
        let workflow = app.githubActions.workflowFile.trimmed.isEmpty ? "miliship.yml" : app.githubActions.workflowFile.trimmed
        Task {
            do {
                try await GitHubClient(token: token, repo: repo).dispatch(workflowFile: workflow, ref: tag.name, inputs: inputs)
                // The run reaches the runner within seconds; stop waiting after a minute.
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                pendingDispatches.remove(key)
            } catch {
                pendingDispatches.remove(key)
                // Typically: the tag predates the workflow file. Build here instead.
                enqueue(appID: appID, tag: tag, platforms: platforms, trigger: "\(trigger) · ran locally")
                if let id = history.first(where: { $0.appID == appID && $0.tagName == tag.name })?.id {
                    update(id) { $0.results.append("Not in GitHub Actions: \(describe(error))") }
                }
            }
        }
    }

    // MARK: - Lookups

    func app(_ id: UUID) -> AppConfig? { apps.first { $0.id == id } }

    func tags(for id: UUID) -> [TagEntry] { tagsByApp[id] ?? [] }

    func refreshState(for id: UUID) -> RefreshState { refreshStates[id] ?? RefreshState() }

    var activeRecord: BuildRecord? {
        guard let id = activeBuildID else { return nil }
        return history.first { $0.id == id }
    }

    var queuedCount: Int { history.filter { $0.status == .queued }.count }

    var statusLine: String {
        if let record = activeRecord {
            return "\(record.appName): \(record.steps.last?.name ?? "Starting") (\(record.tagName))"
        }
        if queuedCount > 0 { return "\(queuedCount) deployment\(queuedCount == 1 ? "" : "s") queued" }
        if refreshStates.values.contains(where: \.isRefreshing) { return "Checking GitHub…" }
        let watching = apps.filter(\.watchTags).count
        return watching > 0 ? "Watching \(watching) app\(watching == 1 ? "" : "s")" : "Nothing running"
    }

    enum ActivityKind { case building, queued, checking, watching }

    /// What the toolbar shows; nil when nothing is going on.
    var activity: (kind: ActivityKind, text: String)? {
        if let record = activeRecord {
            return (.building, "\(record.appName) · \(record.steps.last?.name ?? "Starting")")
        }
        if queuedCount > 0 { return (.queued, "\(queuedCount) queued") }
        if refreshStates.values.contains(where: \.isRefreshing) { return (.checking, "Checking GitHub…") }
        let watching = apps.filter(\.watchTags).count
        return watching > 0 ? (.watching, "Watching \(watching) app\(watching == 1 ? "" : "s")") : nil
    }

    var menuBarSymbol: String {
        if activeBuildID != nil { return "hammer.circle.fill" }
        return apps.contains(where: \.watchTags) ? "shippingbox.circle" : "shippingbox"
    }

    func latestBuild(appID: UUID, tagName: String) -> BuildRecord? {
        history.first { $0.appID == appID && $0.tagName == tagName }
    }

    func builds(for appID: UUID) -> [BuildRecord] {
        history.filter { $0.appID == appID }
    }

    func isBusy(appID: UUID, tagName: String) -> Bool {
        pendingDispatches.contains("\(appID)|\(tagName)")
            || history.contains { $0.appID == appID && $0.tagName == tagName && !$0.status.isFinished }
    }

    func logURL(for record: BuildRecord) -> URL {
        AppPaths.logs.appendingPathComponent(record.logFileName)
    }

    /// Keychain lookups are cached briefly: views ask on every render, but a stale "missing" must not stick.
    func warnings(for app: AppConfig) -> [String] {
        let state: (stored: Set<SecretKey>, blocked: [SecretKey])
        if let cached = storedSecretKeys[app.id], Date().timeIntervalSince(cached.checked) < 15 {
            state = (cached.stored, cached.blocked)
        } else {
            var stored: Set<SecretKey> = []
            var blocked: [SecretKey] = []
            for key in SecretKey.allCases {
                switch Keychain.availability(key, app: app.id) {
                case .readable: stored.insert(key)
                case .blocked: stored.insert(key); blocked.append(key)
                case .missing: break
                }
            }
            storedSecretKeys[app.id] = (stored, blocked, Date())
            state = (stored, blocked)
        }
        var warnings = app.setupWarnings { state.stored.contains($0) }
        if !state.blocked.isEmpty {
            let names = state.blocked.map { $0.title.lowercased() }.joined(separator: ", ")
            warnings.insert("Keychain: Mili Ship needs your permission to read the saved \(names).", at: 0)
        }
        return warnings
    }

    /// Asks macOS once for access to secrets saved by another tool or build, then re-saves them as this app.
    func repairKeychain(for appID: UUID) -> String? {
        let failed = Keychain.repair(app: appID)
        storedSecretKeys[appID] = nil
        objectWillChange.send()
        return failed.isEmpty ? nil : "Still can't read: \(failed.map(\.title).joined(separator: ", ")). Enter them again in Configure."
    }

    /// Pre-flight check of the wizard's draft; `unsaved` are secrets typed in the wizard but not saved yet.
    func checkProject(_ draft: AppConfig, unsaved: [SecretKey: String], progress: @escaping @Sendable (String) -> Void) async -> [DoctorFinding] {
        var secrets = Keychain.all(for: draft.id)
        for (key, value) in unsaved where !value.isEmpty { secrets[key] = value }
        let githubToken = draft.githubActions.isConnected
            ? try? await workingGitHubToken(for: draft, typed: unsaved[.githubToken]).token : nil
        let doctor = ProjectDoctor(app: draft, secrets: secrets, global: global, githubToken: githubToken)
        return await Task.detached { await doctor.run(progress: progress) }.value
    }

    /// The fixes that change Mili Ship-wide settings (the rest edit the wizard's draft).
    func applyGlobalFix(_ fix: DoctorFinding.Fix) {
        switch fix {
        case .addToPATH(let folder):
            let entries = global.extraPATH.split(whereSeparator: { $0 == ":" || $0.isNewline }).map { String($0).trimmed }
            if !entries.contains(folder) {
                global.extraPATH = (entries.filter { !$0.isEmpty } + [folder]).joined(separator: "\n")
            }
        case .setEnvironment(let key, let value):
            global.extraEnvironment[key] = value
        default:
            break
        }
    }

    /// The token of the GitHub CLI (`gh`) this Mac is signed in to, and the account it belongs to.
    func githubCLIToken() async throws -> (token: String, login: String) {
        let env = Toolchain.environment(global: global)
        return try await Task.detached { () async throws -> (String, String) in
            let shell = ShellRunner()
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let token: String
            do {
                token = try await shell.run("gh auth token", cwd: home, env: env, log: { _ in }).trimmed
            } catch {
                throw MiliShipError(message: "The GitHub CLI isn't signed in. Run “gh auth login” in Terminal (or install it with “brew install gh”), then try again.")
            }
            guard !token.isEmpty, !token.contains(" ") else { throw MiliShipError(message: "The GitHub CLI didn't return a token.") }
            let login = (try? await shell.run("gh api user --jq .login", cwd: home, env: env, log: { _ in }).trimmed) ?? ""
            return (token, login)
        }.value
    }

    // MARK: - Applications

    func beginAddApp() {
        wizard = WizardRequest(app: AppConfig(), isNew: true)
    }

    func beginEdit(_ id: UUID, step: WizardStep = .repository) {
        guard let app = self.app(id) else { return }
        wizard = WizardRequest(app: app, isNew: false, step: step)
    }

    func beginCheck(_ id: UUID) {
        guard let app = self.app(id) else { return }
        wizard = WizardRequest(app: app, isNew: false, step: .review, runCheck: true)
    }

    /// The wizard step where a setup warning can be fixed.
    func wizardStep(for warning: String) -> WizardStep {
        if warning.hasPrefix("Android") || warning.hasPrefix("Google Play") { return .googlePlay }
        if warning.hasPrefix("App Store") { return .appStore }
        if warning.hasPrefix("GitHub Actions") { return .github }
        if warning.hasPrefix("Repository") { return .repository }
        return .build
    }

    /// App of the current sidebar selection (also for a selected deployment).
    var selectedAppID: UUID? {
        switch selection {
        case .app(let id): return id
        case .build(let id): return history.first { $0.id == id }?.appID
        default: return nil
        }
    }

    func latestReleaseTag(for appID: UUID) -> ReleaseTag? {
        tags(for: appID).first { $0.tag.mode == .release }?.tag
    }

    func lastDeployment(for appID: UUID) -> BuildRecord? {
        history.first { $0.appID == appID }
    }

    func deployLatest(_ appID: UUID) {
        guard let app = self.app(appID), let tag = latestReleaseTag(for: appID) else { return }
        deploy(appID: appID, tag: tag, platforms: app.enabledPlatforms)
    }

    func revealWorkspace(_ appID: UUID) {
        guard let app = self.app(appID) else { return }
        let url = app.workspaceURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func openInTerminal(_ appID: UUID) {
        guard let app = self.app(appID),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return }
        let path = app.appPath.trimmed
        let folder = path.isEmpty || path == "." ? app.workspaceURL : app.workspaceURL.appendingPathComponent(path)
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func checkTools() async {
        guard !checkingTools else { return }
        checkingTools = true
        let global = self.global
        let script = Self.toolCatalog
            .map { "printf '%s\\t%s\\n' \($0.name) \"$(command -v \($0.name) 2>/dev/null)\"" }
            .joined(separator: "\n")
        let output = (try? await Task.detached { () async throws -> String in
            try await ShellRunner().run(
                script,
                cwd: URL(fileURLWithPath: NSHomeDirectory()),
                env: Toolchain.environment(global: global),
                log: { _ in }
            )
        }.value) ?? ""

        var found: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty {
                found[String(parts[0])] = String(parts[1])
            }
        }
        tools = Self.toolCatalog.map {
            ToolStatus(name: $0.name, purpose: $0.purpose, optional: $0.optional, path: found[$0.name])
        }
        checkingTools = false
    }

    func saveApp(_ config: AppConfig, secrets: SecretStore) {
        var app = config
        if app.workspacePath.trimmed.isEmpty { app.workspacePath = abbreviatePath(app.workspaceURL) }

        for key in secrets.removed where (secrets.new[key] ?? "").isEmpty {
            Keychain.set("", for: key, app: app.id)
        }
        for (key, value) in secrets.new where !value.isEmpty {
            Keychain.set(value, for: key, app: app.id)
        }

        storedSecretKeys[app.id] = nil
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index] = app
        } else {
            apps.append(app)
        }
        persistApps()
        reconcileRunners()
        selection = .app(app.id)
        Task { await refreshTags(for: app.id) }
    }

    func setWatching(_ id: UUID, _ watching: Bool) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].watchTags = watching
        persistApps()
        if watching { Task { await refreshTags(for: id) } }
    }

    func removeApp(_ id: UUID) {
        if let app = self.app(id), app.githubActions.isConnected {
            let token = Keychain.get(.githubToken, app: id)
            let environment = Toolchain.environment(global: global)
            Task { await runners.disconnect(app, token: token, environment: environment) }
        }
        apps.removeAll { $0.id == id }
        Keychain.removeAll(for: id)
        storedSecretKeys[id] = nil
        seen.removeValue(forKey: id.uuidString)
        tagsByApp.removeValue(forKey: id)
        refreshStates.removeValue(forKey: id)
        for record in history where record.appID == id && record.status == .queued { cancel(record.id) }
        persistApps()
        Persistence.save(seen, to: AppPaths.seenTagsFile)
        selection = apps.first.map { .app($0.id) } ?? .welcome
    }

    /// Wizard: clone (or update) the repo and detect Flutter and React Native apps in it.
    func scanRepository(for app: AppConfig) async throws -> RepoScan {
        let global = self.global
        return try await Task.detached { () async throws -> RepoScan in
            let env = Toolchain.environment(global: global)
            try await Git(app: app).checkoutDefaultBranch(shell: ShellRunner(), env: env, log: { _ in })
            return ProjectScanner.scan(repo: app.workspaceURL)
        }.value
    }

    func testGooglePlay(_ android: AndroidConfig) async -> (ok: Bool, message: String) {
        do {
            let message = try await Task.detached { () async throws -> String in
                let client = try GooglePlayClient(
                    serviceAccountURL: requireFile(android.serviceAccountPath, "Service account JSON"),
                    packageName: requireValue(android.packageName, "Package name")
                )
                return try await client.testConnection()
            }.value
            return (true, message)
        } catch {
            return (false, describe(error))
        }
    }

    func testAppStore(_ ios: IOSConfig) async -> (ok: Bool, message: String) {
        do {
            let message = try await Task.detached { () async throws -> String in
                try await AppStoreConnectClient(config: ios).testConnection(bundleID: ios.bundleID)
            }.value
            return (true, message)
        } catch {
            return (false, describe(error))
        }
    }

    // MARK: - Tag watching

    func refreshAll() async {
        for app in apps { await refreshTags(for: app.id) }
    }

    func refreshTags(for appID: UUID) async {
        guard let app = self.app(appID), refreshStates[appID]?.isRefreshing != true else { return }
        guard !app.repoURL.trimmed.isEmpty else {
            refreshStates[appID, default: RefreshState()].error = "Repository URL is not set."
            return
        }
        refreshStates[appID, default: RefreshState()].isRefreshing = true
        refreshStates[appID, default: RefreshState()].lastAttempt = Date()

        let global = self.global
        do {
            let entries = try await Task.detached { () async throws -> [TagEntry] in
                try await Git(app: app).fetchTags(
                    for: app, shell: ShellRunner(), env: Toolchain.environment(global: global), log: { _ in }
                )
            }.value
            tagsByApp[appID] = entries
            refreshStates[appID, default: RefreshState()].lastRefresh = Date()
            refreshStates[appID, default: RefreshState()].error = nil
            handleNewTags(entries, appID: appID)
        } catch {
            refreshStates[appID, default: RefreshState()].error = describe(error)
        }
        refreshStates[appID, default: RefreshState()].isRefreshing = false
    }

    private func handleNewTags(_ entries: [TagEntry], appID: UUID) {
        let key = appID.uuidString
        let names = Set(entries.map(\.tag.name))
        var state = seen[key] ?? SeenTags()

        guard state.initialized else {
            // First sync: remember existing tags so they aren't deployed retroactively.
            seen[key] = SeenTags(initialized: true, names: names)
            Persistence.save(seen, to: AppPaths.seenTagsFile)
            return
        }

        let fresh = entries.filter { !state.names.contains($0.tag.name) }
        state.names.formUnion(names)
        seen[key] = state
        Persistence.save(seen, to: AppPaths.seenTagsFile)

        guard !fresh.isEmpty, let app = self.app(appID), app.watchTags else { return }
        notify(title: "\(app.displayName): new tag\(fresh.count > 1 ? "s" : "")", body: fresh.map(\.tag.name).joined(separator: ", "))
        // Connected apps are deployed by GitHub Actions the moment the tag is pushed.
        guard app.autoBuild, !app.deploysThroughActions else { return }
        for entry in fresh.reversed() { // oldest first
            enqueue(appID: appID, tag: entry.tag, platforms: app.enabledPlatforms, trigger: "auto")
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDueApps()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func pollDueApps() async {
        let now = Date()
        for app in apps where app.watchTags {
            let last = refreshStates[app.id]?.lastAttempt ?? .distantPast
            if now.timeIntervalSince(last) >= Double(max(1, app.pollMinutes) * 60) {
                await refreshTags(for: app.id)
            }
        }
    }

    // MARK: - Build queue

    @discardableResult
    func enqueue(appID: UUID, tag: ReleaseTag, platforms: [TargetPlatform], trigger: String, select: Bool = true) -> UUID? {
        let running = history.contains { $0.appID == appID && $0.tagName == tag.name && !$0.status.isFinished }
        guard let app = self.app(appID), !platforms.isEmpty, !running else { return nil }
        let record = BuildRecord(app: app, tag: tag, platforms: platforms, trigger: trigger)
        history.insert(record, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        persistHistory()
        if select && trigger != "auto" { selection = .build(record.id) }
        processQueue()
        return record.id
    }

    func retry(_ record: BuildRecord) {
        guard let app = self.app(record.appID), let tag = app.releaseTag(named: record.tagName) else { return }
        deploy(appID: app.id, tag: tag, platforms: record.platforms, trigger: "retry")
    }

    func cancel(_ id: UUID, reason: String = "Cancelled by user") {
        cancelReasons[id] = reason
        if id == activeBuildID {
            liveLog.append("\n■ Cancelling — \(reason)\n")
            buildTask?.cancel()
            pipeline?.cancel()
            return
        }
        update(id) { record in
            guard record.status == .queued else { return }
            record.status = .cancelled
            record.finishedAt = Date()
            record.failureReason = reason
            for key in record.platformStatus.keys { record.platformStatus[key] = .cancelled }
        }
    }

    func clearFinished() {
        for record in history where record.status.isFinished {
            try? FileManager.default.removeItem(at: logURL(for: record))
        }
        history.removeAll { $0.status.isFinished }
        if case .build(let id) = selection, !history.contains(where: { $0.id == id }) {
            selection = apps.first.map { .app($0.id) } ?? .welcome
        }
        persistHistory()
    }

    private func processQueue() {
        guard activeBuildID == nil,
              let index = history.lastIndex(where: { $0.status == .queued })
        else { return }

        let record = history[index]
        guard let app = self.app(record.appID), let tag = app.releaseTag(named: record.tagName) else {
            update(record.id) {
                $0.status = .failed
                $0.failureReason = "The application was removed or its tag prefixes no longer match \(record.tagName)."
                $0.finishedAt = Date()
            }
            processQueue()
            return
        }

        let id = record.id
        update(id) { $0.status = .running; $0.startedAt = Date(); $0.appName = app.displayName }
        activeBuildID = id
        liveLog.reset(for: id)
        beginPreventingSleep()

        let secrets = Keychain.all(for: app.id)
        let liveLog = self.liveLog
        let sink = LogSink(fileURL: logURL(for: record), masks: Array(secrets.values)) { chunk in
            liveLog.appendIfCurrent(chunk, buildID: id)
        }
        sink.write("Started \(Date().formatted(date: .abbreviated, time: .standard))\n")

        let hooks = PipelineHooks(
            log: { sink.write($0) },
            stepStarted: { [weak self] name in
                self?.update(id) { $0.steps.append(StepRecord(name: name, status: .running, startedAt: Date())) }
            },
            stepFinished: { [weak self] name, status in
                self?.update(id) { record in
                    guard let i = record.steps.lastIndex(where: { $0.name == name && $0.status == .running }) else { return }
                    record.steps[i].status = status
                    record.steps[i].finishedAt = Date()
                }
            },
            platformStarted: { [weak self] platform in
                self?.update(id) { $0.platformStatus[platform.rawValue] = .running }
            },
            platformFinished: { [weak self] platform, status in
                self?.update(id) { $0.platformStatus[platform.rawValue] = status }
            },
            commitResolved: { [weak self] commit in
                self?.update(id) { $0.commit = commit }
            },
            versionResolved: { [weak self] version in
                self?.update(id) { $0.version = version }
            },
            result: { [weak self] line in
                self?.update(id) { $0.results.append(line) }
            }
        )

        let pipeline = BuildPipeline(app: app, tag: tag, platforms: record.platforms,
                                     secrets: secrets, global: global, hooks: hooks)
        self.pipeline = pipeline

        buildTask = Task.detached { [weak self] in
            var status = RunStatus.succeeded
            var reason: String?
            do {
                try await pipeline.run()
            } catch is CancellationError {
                status = .cancelled
                reason = "Cancelled by user"
            } catch {
                status = .failed
                reason = describe(error)
            }
            sink.write("\n=== \(status.title.uppercased()) ===\n\(reason.map { "\($0)\n" } ?? "")")
            sink.close()
            await self?.finish(id: id, status: status, reason: reason)
        }
    }

    private func finish(id: UUID, status: RunStatus, reason: String?) {
        let reason = status == .cancelled ? (cancelReasons[id] ?? reason) : reason
        cancelReasons[id] = nil
        update(id) { record in
            record.status = status
            record.finishedAt = Date()
            record.failureReason = reason
            for i in record.steps.indices where record.steps[i].status == .running {
                record.steps[i].status = status == .cancelled ? .cancelled : .failed
                record.steps[i].finishedAt = Date()
            }
            for (key, value) in record.platformStatus where !value.isFinished {
                record.platformStatus[key] = status == .cancelled ? .cancelled : .skipped
            }
        }

        if let record = history.first(where: { $0.id == id }) {
            switch status {
            case .succeeded:
                notify(title: "✅ \(record.appName) \(record.version ?? record.tagName) deployed",
                       body: record.results.joined(separator: "\n"))
            case .failed:
                notify(title: "❌ \(record.appName) \(record.tagName) failed", body: reason ?? "See the build log.")
            default:
                break
            }
        }

        activeBuildID = nil
        pipeline = nil
        buildTask = nil
        endPreventingSleep()
        processQueue()
    }

    private func update(_ id: UUID, _ change: (inout BuildRecord) -> Void) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        change(&history[index])
        persistHistory()
    }

    private func persistHistory() { Persistence.save(history, to: AppPaths.historyFile) }
    private func persistApps() {
        Persistence.save(apps, to: AppPaths.appsFile)
        appsFileDate = Self.modificationDate(AppPaths.appsFile)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// apps.json changed on disk without us (edited by hand, restored from a backup…): load it instead of
    /// overwriting it with the copy in memory on the next save. Waits while the wizard is open.
    private func reloadAppsIfChangedOnDisk() {
        guard wizard == nil, let date = Self.modificationDate(AppPaths.appsFile), date != appsFileDate else { return }
        appsFileDate = date
        let loaded = Persistence.loadApps()
        guard loaded != apps else { return }
        apps = loaded
        storedSecretKeys = [:]
        reconcileRunners()
    }

    // MARK: - Toolchain helpers

    func importShellPath() async -> String? {
        let global = self.global
        let output = try? await Task.detached { () async throws -> String in
            try await ShellRunner().run(
                "print -r -- \"__MILISHIP_PATH__=$PATH\"",
                cwd: URL(fileURLWithPath: NSHomeDirectory()),
                env: Toolchain.environment(global: global),
                interactive: true,
                log: { _ in }
            )
        }.value
        guard let line = output?
            .split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix("__MILISHIP_PATH__=") })
        else { return nil }
        return String(line.dropFirst("__MILISHIP_PATH__=".count))
    }

    func runPreflight() async -> String {
        let global = self.global
        do {
            return try await Task.detached { () async throws -> String in
                try await ShellRunner().run(
                    Toolchain.preflightScript,
                    cwd: URL(fileURLWithPath: NSHomeDirectory()),
                    env: Toolchain.environment(global: global),
                    log: { _ in }
                )
            }.value
        } catch {
            return describe(error)
        }
    }

    // MARK: - System integration

    private func beginPreventingSleep() {
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Building and deploying an app"
        )
    }

    private func endPreventingSleep() {
        if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity) }
        sleepActivity = nil
    }

    /// Notifications need a real .app bundle (always the case for the Xcode target).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && global.notifications }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

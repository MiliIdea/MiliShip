import AppKit
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
        didSet { if global != oldValue { Persistence.save(global, to: AppPaths.globalFile) } }
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

    private var seen: [String: SeenTags]
    private var storedSecretKeys: [UUID: Set<SecretKey>] = [:]
    private var pollTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    private var pipeline: BuildPipeline?
    private var sleepActivity: NSObjectProtocol?
    private let historyLimit = 300

    init() {
        apps = Persistence.loadApps()
        global = Persistence.loadMerged(GlobalSettings(), from: AppPaths.globalFile)
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
        history.contains { $0.appID == appID && $0.tagName == tagName && !$0.status.isFinished }
    }

    func logURL(for record: BuildRecord) -> URL {
        AppPaths.logs.appendingPathComponent(record.logFileName)
    }

    func warnings(for app: AppConfig) -> [String] {
        let stored = storedSecretKeys[app.id] ?? Set(Keychain.all(for: app.id).keys)
        storedSecretKeys[app.id] = stored
        return app.setupWarnings { stored.contains($0) }
    }

    // MARK: - Applications

    func beginAddApp() {
        wizard = WizardRequest(app: AppConfig(), isNew: true)
    }

    func beginEdit(_ id: UUID, step: WizardStep = .repository) {
        guard let app = self.app(id) else { return }
        wizard = WizardRequest(app: app, isNew: false, step: step)
    }

    /// The wizard step where a setup warning can be fixed.
    func wizardStep(for warning: String) -> WizardStep {
        if warning.hasPrefix("Android") || warning.hasPrefix("Google Play") { return .googlePlay }
        if warning.hasPrefix("App Store") { return .appStore }
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
        enqueue(appID: appID, tag: tag, platforms: app.enabledPlatforms, trigger: "manual")
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
        guard app.autoBuild else { return }
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

    func enqueue(appID: UUID, tag: ReleaseTag, platforms: [TargetPlatform], trigger: String) {
        guard let app = self.app(appID), !platforms.isEmpty, !isBusy(appID: appID, tagName: tag.name) else { return }
        let record = BuildRecord(app: app, tag: tag, platforms: platforms, trigger: trigger)
        history.insert(record, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        persistHistory()
        if trigger != "auto" { selection = .build(record.id) }
        processQueue()
    }

    func retry(_ record: BuildRecord) {
        guard let app = self.app(record.appID), let tag = app.releaseTag(named: record.tagName) else { return }
        enqueue(appID: app.id, tag: tag, platforms: record.platforms, trigger: "retry")
    }

    func cancel(_ id: UUID) {
        if id == activeBuildID {
            liveLog.append("\n■ Cancelling…\n")
            buildTask?.cancel()
            pipeline?.cancel()
            return
        }
        update(id) { record in
            guard record.status == .queued else { return }
            record.status = .cancelled
            record.finishedAt = Date()
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
    private func persistApps() { Persistence.save(apps, to: AppPaths.appsFile) }

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

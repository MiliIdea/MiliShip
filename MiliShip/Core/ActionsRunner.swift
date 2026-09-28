import Foundation

/// What a Mili Ship–managed GitHub Actions runner is doing.
enum RunnerState: Equatable {
    case stopped
    case starting
    case online
    case busy(job: String)
    case updating
    /// Lost the connection; retries by itself.
    case reconnecting(String)
    /// GitHub no longer knows this runner: connect again in the app's settings.
    case needsReconnect(String)

    var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .online: return "Online"
        case .busy: return "Running a job"
        case .updating: return "Updating"
        case .reconnecting: return "Reconnecting"
        case .needsReconnect: return "Disconnected"
        }
    }

    var detail: String? {
        switch self {
        case .busy(let job): return job
        case .reconnecting(let reason), .needsReconnect(let reason): return reason
        default: return nil
        }
    }

    var isHealthy: Bool {
        switch self {
        case .online, .busy, .updating: return true
        default: return false
        }
    }
}

/// Installs, registers and supervises one GitHub Actions runner per connected application.
/// Runners live in ~/.miliship/runner/apps/<app id> and run as child processes of Mili Ship.
@MainActor
final class RunnerManager: ObservableObject {
    @Published private(set) var states: [UUID: RunnerState] = [:]
    private var processes: [UUID: RunnerProcess] = [:]

    init() {
        Self.killOrphans()
    }

    func state(for appID: UUID) -> RunnerState { states[appID] ?? .stopped }

    /// Starts runners for connected apps and stops the rest.
    func reconcile(apps: [AppConfig], environment: [String: String]) {
        let wanted = apps.filter { $0.deploysThroughActions && Self.isConfigured(AppPaths.runnerDirectory(for: $0.id)) }
        let wantedIDs = Set(wanted.map(\.id))
        for id in processes.keys where !wantedIDs.contains(id) { stop(id) }
        for app in wanted where processes[app.id] == nil {
            start(app, environment: environment)
        }
        // Registrations of removed apps: GitHub drops offline runners after 14 days; tidy the disk now.
        let known = Set(apps.map(\.id.uuidString))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.runnersRoot.path)) ?? [] where !known.contains(name) {
            try? FileManager.default.removeItem(at: AppPaths.runnersRoot.appendingPathComponent(name))
        }
    }

    func restart(_ app: AppConfig, environment: [String: String]) {
        stop(app.id)
        start(app, environment: environment)
    }

    func stopAll() {
        for id in processes.keys { stop(id) }
    }

    private func start(_ app: AppConfig, environment: [String: String]) {
        let directory = AppPaths.runnerDirectory(for: app.id)
        var env = environment
        env["MILISHIP_JOB"] = AppPaths.jobScript.path
        env["MILISHIP_SPOOL"] = AppPaths.jobs.path
        env["MILISHIP_APP_ID"] = app.id.uuidString
        env["RUNNER_ALLOW_RUNASROOT"] = nil
        Self.writeRunnerEnvironment(env, to: directory)

        let id = app.id
        let process = RunnerProcess(directory: directory, environment: env) { [weak self] state in
            Task { @MainActor in self?.states[id] = state }
        }
        processes[id] = process
        states[id] = .starting
        process.start()
    }

    private func stop(_ id: UUID) {
        processes.removeValue(forKey: id)?.stop()
        states[id] = .stopped
    }

    // MARK: Registration

    /// Downloads the runner if needed and registers it for the app's repository.
    func connect(_ app: AppConfig, token: String, environment: [String: String],
                 log: @escaping @Sendable (String) -> Void) async throws -> GitHubActionsConfig {
        guard let repo = app.githubRepo else { throw MiliShipError(message: "The repository URL isn't a github.com repository.") }
        let client = GitHubClient(token: token, repo: repo)
        log("Checking access to \(repo.fullName)…\n")
        let repository = try await client.repository()
        if repository.canAdminister == false {
            throw MiliShipError(message: "The token can't administer \(repo.fullName). Registering a runner needs admin access to the repository.")
        }

        if !repository.isPrivate {
            log("⚠︎ \(repo.fullName) is public: in its Settings → Actions → General, require approval for workflows from outside collaborators.\n")
        }
        let distribution = try await RunnerDistribution.ensureLatest(log: log)
        let directory = AppPaths.runnerDirectory(for: app.id)
        stop(app.id)
        if Self.isConfigured(directory) {
            log("Removing the previous registration…\n")
            try? await Self.unregister(directory: directory, client: client, runnerID: app.githubActions.runnerID, environment: environment)
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // APFS clone: instant, and takes no extra space until the runner updates itself.
        try await ShellRunner().run("cp -Rc \(shq(distribution.path)) \(shq(directory.path))",
                                    cwd: AppPaths.actionsHome, env: environment, log: { _ in })

        let slug = Self.slug(app.displayName)
        let suffix = app.id.uuidString.prefix(6).lowercased()
        // No computer name: runner names are visible to everyone with access to the repository.
        let name = String("miliship-\(slug)-\(suffix)".prefix(64))
        let label = "miliship-\(slug)-\(suffix)"

        log("Registering runner \(name)…\n")
        var env = environment
        env["MILISHIP_REGISTRATION_TOKEN"] = try await client.runnerRegistrationToken()
        try await ShellRunner().run(
            """
            ./config.sh --unattended --replace \
              --url \(shq(repo.webURL.absoluteString)) \
              --token "$MILISHIP_REGISTRATION_TOKEN" \
              --name \(shq(name)) \
              --labels \(shq("miliship,\(label)")) \
              --work _work
            """,
            cwd: directory, env: env, log: log
        )
        let runnerID = try? await client.runners().first { $0.name == name }?.id
        log("Connected to GitHub Actions as \(name) (label \(label))\n")

        var config = app.githubActions
        config.enabled = true
        config.runnerName = name
        config.runnerLabel = label
        config.runnerID = runnerID
        config.repositoryIsPublic = !repository.isPrivate
        return config
    }

    /// Unregisters from GitHub and removes the runner from this Mac.
    func disconnect(_ app: AppConfig, token: String?, environment: [String: String]) async {
        stop(app.id)
        let directory = AppPaths.runnerDirectory(for: app.id)
        if let token, let repo = app.githubRepo {
            try? await Self.unregister(directory: directory, client: GitHubClient(token: token, repo: repo),
                                       runnerID: app.githubActions.runnerID, environment: environment)
        }
        try? FileManager.default.removeItem(at: directory)
        states[app.id] = nil
    }

    private static func unregister(directory: URL, client: GitHubClient, runnerID: Int?, environment: [String: String]) async throws {
        var env = environment
        env["MILISHIP_REMOVAL_TOKEN"] = try await client.runnerRemovalToken()
        do {
            try await ShellRunner().run(#"./config.sh remove --token "$MILISHIP_REMOVAL_TOKEN""#, cwd: directory, env: env, log: { _ in })
        } catch {
            if let runnerID { try await client.deleteRunner(id: runnerID) } else { throw error }
        }
    }

    // MARK: Helpers

    static func isConfigured(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".runner").path)
    }

    /// The runner reads .env and .path at startup and hands them to every job.
    private static func writeRunnerEnvironment(_ env: [String: String], to directory: URL) {
        let keys = ["MILISHIP_JOB", "MILISHIP_SPOOL", "MILISHIP_APP_ID", "LANG", "LC_ALL", "HOME", "ANDROID_HOME", "JAVA_HOME"]
        let lines = keys.compactMap { key in env[key].map { "\(key)=\($0)" } }
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        if let path = env["PATH"] {
            try? path.write(to: directory.appendingPathComponent(".path"), atomically: true, encoding: .utf8)
        }
    }

    private static func slug(_ text: String) -> String {
        let lowered = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
        let parts = lowered.split(separator: "-")
        return parts.isEmpty ? "app" : String(parts.joined(separator: "-").prefix(24))
    }

    /// Runners left behind by a crash of a previous Mili Ship would hold the GitHub session.
    private static func killOrphans() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "\(AppPaths.actionsHome.path)/runner/apps/"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }
}

/// One `run.sh` process, restarted with backoff when it exits unexpectedly.
final class RunnerProcess: @unchecked Sendable {
    private let directory: URL
    private let environment: [String: String]
    private let report: (RunnerState) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var stopping = false
    private var failures = 0
    private var buffer = ""
    private var gone = false
    private let logURL: URL

    init(directory: URL, environment: [String: String], report: @escaping (RunnerState) -> Void) {
        self.directory = directory
        self.environment = environment
        self.report = report
        logURL = directory.appendingPathComponent("_diag/miliship-runner.log")
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [directory.appendingPathComponent("run.sh").path]
        process.currentDirectoryURL = directory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consume(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] finished in
            self?.exited(status: finished.terminationStatus)
        }
        do {
            try process.run()
            self.process = process
        } catch {
            report(.reconnecting("Couldn't start the runner: \(error.localizedDescription)"))
            scheduleRestart()
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        // Runner.Listener is a grandchild of run.sh; interrupt the whole tree so it signs off from GitHub.
        let root = process.processIdentifier
        for pid in ShellRunner.descendants(of: root).reversed() { kill(pid, SIGINT) }
        kill(root, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            guard process.isRunning else { return }
            for pid in ShellRunner.descendants(of: root) { kill(pid, SIGKILL) }
            kill(root, SIGKILL)
        }
    }

    private func consume(_ text: String) {
        appendToLog(text)
        lock.lock()
        buffer += text
        var lines = buffer.components(separatedBy: "\n")
        buffer = lines.removeLast()
        lock.unlock()
        for line in lines { interpret(line.trimmed) }
    }

    private func interpret(_ line: String) {
        guard !line.isEmpty else { return }
        let lower = line.lowercased()
        if lower.contains("registration has been deleted") || lower.contains("registration was not found")
            || lower.contains("runner registration") && lower.contains("deleted") {
            lock.lock(); gone = true; lock.unlock()
            report(.needsReconnect("GitHub removed this runner. Connect it again in the app's GitHub Actions settings."))
        } else if lower.contains("a session for this runner already exists") {
            report(.reconnecting("Another copy of this runner is connected; retrying…"))
        } else if lower.hasPrefix("running job:") {
            report(.busy(job: String(line.dropFirst("Running job:".count)).trimmed))
        } else if lower.contains("listening for jobs") || (lower.contains("completed with result") && lower.contains("job")) {
            lock.lock(); failures = 0; lock.unlock()
            report(.online)
        } else if lower.contains("runner update") || lower.contains("downloading") && lower.contains("runner") {
            report(.updating)
        } else if lower.contains("failed to connect") || lower.contains("could not connect") || lower.contains("connection refused") {
            report(.reconnecting("Can't reach GitHub; retrying…"))
        }
    }

    private func exited(status: Int32) {
        lock.lock()
        process = nil
        let stopped = stopping
        let removed = gone
        lock.unlock()
        guard !stopped, !removed else { return }
        report(.reconnecting("The runner stopped (exit \(status)); restarting…"))
        scheduleRestart()
    }

    private func scheduleRestart() {
        lock.lock()
        failures += 1
        let delay = min(60.0, 5.0 * Double(failures))
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    /// Keeps the last ~1 MB of runner output for troubleshooting.
    private func appendToLog(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int), size > 1_000_000 {
            try? fm.removeItem(at: logURL)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        }
    }
}

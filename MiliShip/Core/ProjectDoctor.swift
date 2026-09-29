import Foundation

/// One result of a pre-flight check, with a one-click fix when Mili Ship can apply one.
struct DoctorFinding: Identifiable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case error = 0, warning = 1, ok = 2
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    enum Area: String, Sendable {
        case repository = "Repository", project = "Project", toolchain = "Toolchain", shorebird = "Shorebird"
        case android = "Android", ios = "iOS", githubActions = "GitHub Actions"
    }

    /// Where a fix leads when it can't be applied automatically.
    enum Place: Sendable { case project, prepare, build, github, googlePlay, appStore }

    enum Fix: Sendable {
        case addPreBuildCommand(String)
        case setDartDefinesFile(String)
        case addToPATH(String)
        case setEnvironment(key: String, value: String)
        case addWorkflow
        case copy(String)
        case open(URL, then: Place?)
        case edit(Place)
    }

    let id = UUID()
    let severity: Severity
    let area: Area
    let title: String
    var detail: String?
    var fix: Fix?
    var fixTitle: String?
}

/// Pre-flight checks on Mili Ship's own clone of the default branch — what a build would see — so problems
/// show up before a tag is pushed instead of halfway through a deployment.
struct ProjectDoctor: Sendable {
    let app: AppConfig
    let secrets: [SecretKey: String]
    let global: GlobalSettings
    let githubToken: String?

    private var env: [String: String] {
        var env = Toolchain.environment(global: global)
        if let token = secrets[.shorebirdToken], !token.isEmpty { env["SHOREBIRD_TOKEN"] = token }
        return env
    }

    private var repoDir: URL { app.workspaceURL }
    private var appDir: URL {
        let path = app.appPath.trimmed
        return path.isEmpty || path == "." ? repoDir : repoDir.appendingPathComponent(path, isDirectory: true)
    }

    func run(progress: @escaping @Sendable (String) -> Void) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        progress("Updating the clone…")
        do {
            try await Git(app: app).checkoutDefaultBranch(shell: ShellRunner(), env: env, log: { _ in })
        } catch {
            return [DoctorFinding(severity: .error, area: .repository, title: "Couldn't clone or update the repository",
                                  detail: describe(error), fix: .edit(.project), fixTitle: "Check the Git URL")]
        }
        let manifest = app.framework == .flutter ? "pubspec.yaml" : "package.json"
        guard exists(manifest) else {
            return [DoctorFinding(severity: .error, area: .project, title: "No \(manifest) at “\(app.appPath)”",
                                  detail: "Check the app path in the Project step.", fix: .edit(.project), fixTitle: "Open Project")]
        }

        progress("Checking tools…")
        findings += await toolchain()
        progress("Looking for files the build needs…")
        findings += await ignoredFiles()
        if app.framework == .flutter {
            findings += dartDefines()
        }
        if app.usesShorebird {
            progress("Checking Shorebird…")
            findings += await shorebird()
        }
        if app.android.enabled {
            progress("Checking Android signing…")
            findings += await android()
        }
        if app.ios.enabled {
            progress("Checking iOS…")
            findings += await ios()
        }
        if app.githubActions.isConnected {
            progress("Checking the GitHub Actions workflow…")
            findings += await githubActions()
        }
        return findings.sorted { $0.severity < $1.severity }
    }

    // MARK: Toolchain

    private func toolchain() async -> [DoctorFinding] {
        var tools: [String] = []
        if app.framework == .flutter {
            tools.append(first(app.flutterCommand) ?? "flutter")
            if app.usesShorebird { tools.append("shorebird") }
        } else {
            tools.append("node")
        }
        if let bootstrap = first(app.bootstrapCommand) { tools.append(bootstrap) }
        if app.ios.enabled { tools.append("xcodebuild") }
        if app.android.enabled && app.android.writesKeyProperties { tools.append("keytool") }

        var findings: [DoctorFinding] = []
        var missing = false
        for tool in Array(NSOrderedSet(array: tools)).compactMap({ $0 as? String }) {
            if await succeeds("command -v \(shq(tool))") { continue }
            missing = true
            // The user's own terminal loads ~/.zshrc; builds don't.
            let path = (try? await ShellRunner().run("command -v \(shq(tool))", cwd: home, env: ProcessInfo.processInfo.environment,
                                                     interactive: true, log: { _ in }))?.trimmed
            if let path, path.hasPrefix("/") {
                let folder = (path as NSString).deletingLastPathComponent
                findings.append(DoctorFinding(severity: .error, area: .toolchain, title: "Builds can't find \(tool)",
                    detail: "Your Terminal finds it at \(path), but builds don't read ~/.zshrc.",
                    fix: .addToPATH(folder), fixTitle: "Add \(folder) to the build PATH"))
            } else {
                findings.append(DoctorFinding(severity: .error, area: .toolchain, title: "\(tool) isn't installed",
                    detail: "Install it, or add its folder in Settings → Shell PATH."))
            }
        }
        if !missing { findings.append(DoctorFinding(severity: .ok, area: .toolchain, title: "All build tools found")) }

        // Cache locations set in ~/.zshrc: without them builds download everything again, or can't see
        // globally activated tools.
        for key in ["PUB_CACHE", "GRADLE_USER_HOME", "CP_HOME_DIR"] where global.extraEnvironment[key] == nil {
            let value = (try? await ShellRunner().run("print -r -- \"${\(key):-}\"", cwd: home, env: ProcessInfo.processInfo.environment,
                                                      interactive: true, log: { _ in }))?
                .split(whereSeparator: \.isNewline).last.map { String($0).trimmed } ?? ""
            guard !value.isEmpty, env[key] != value else { continue }
            findings.append(DoctorFinding(severity: .warning, area: .toolchain, title: "Builds don't use your \(key)",
                detail: "Your shell sets \(key)=\(value); builds use the default location instead.",
                fix: .setEnvironment(key: key, value: value), fixTitle: "Use it for builds"))
        }
        return findings
    }

    // MARK: Git-ignored files

    /// `lib/app/config/app_config.example.dart` next to a git-ignored, missing `app_config.dart`: the classic
    /// "works on my machine" file. The fix copies the example before each build, like most CI setups do.
    private func ignoredFiles() async -> [DoctorFinding] {
        let fm = FileManager.default
        var findings: [DoctorFinding] = []
        let markers = [".example", ".sample", ".template", ".dist"]
        let skipped: Set<String> = ["build", "node_modules", "Pods", ".dart_tool", ".git", "DerivedData", ".gradle", "ios/build"]
        guard let enumerator = fm.enumerator(at: appDir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        let depth = appDir.pathComponents.count
        for case let url as URL in enumerator {
            if skipped.contains(url.lastPathComponent) || url.pathComponents.count - depth > 6 { enumerator.skipDescendants(); continue }
            let name = url.lastPathComponent
            guard let marker = markers.first(where: { name.contains($0) }) else { continue }
            let target = url.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: marker, with: ""))
            guard target.lastPathComponent != name, !fm.fileExists(atPath: target.path) else { continue }
            let relative = String(target.path.dropFirst(appDir.path.count + 1))
            let source = String(url.path.dropFirst(appDir.path.count + 1))
            guard await succeeds("git check-ignore -q \(shq(target.path))", in: repoDir) else { continue }
            let handled = app.preBuildCommands.contains(relative)
                || app.fileInjections.contains { $0.destination.hasSuffix(relative) }
            guard !handled else { continue }
            let isSecret = name.lowercased().contains("env") || name.lowercased().contains("secret") || name.lowercased().contains("key")
            findings.append(DoctorFinding(
                severity: isSecret ? .warning : .error, area: .project,
                title: "\(relative) is git-ignored, so builds don't have it",
                detail: isSecret
                    ? "Copying \(source) gives builds the example values. If they need real ones, add your file in Prepare instead."
                    : "Only \(source) is in the repository. Builds fail if the code imports \(target.lastPathComponent).",
                fix: .addPreBuildCommand("cp \(shq(source)) \(shq(relative))"),
                fixTitle: "Copy \(url.lastPathComponent) before each build"))
        }
        if findings.isEmpty {
            findings.append(DoctorFinding(severity: .ok, area: .project, title: "No missing git-ignored files"))
        }
        return findings
    }

    // MARK: Dart defines

    private func dartDefines() -> [DoctorFinding] {
        let file = app.dartDefineFile.trimmed
        guard !file.isEmpty else { return [] }
        guard exists(file) else {
            return [DoctorFinding(severity: .error, area: .project, title: "\(file) isn't in the repository",
                                  detail: "It may be git-ignored. Add it in Prepare, or pick another file.", fix: .edit(.project), fixTitle: "Open Project")]
        }
        let lower = (file as NSString).lastPathComponent.lowercased()
        guard ["emulator", "local", "dev", "debug", "test", "mock"].contains(where: lower.contains) else {
            return [DoctorFinding(severity: .ok, area: .project, title: "Dart defines: \(file)")]
        }
        let folder = (file as NSString).deletingLastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: appDir.appendingPathComponent(folder).path)) ?? []
        let production = siblings.first { name in ["prod", "production", "release"].contains { name.lowercased().contains($0) } }
        var finding = DoctorFinding(severity: .warning, area: .project, title: "Store builds use \(file)",
                                    detail: "That looks like a development configuration; it's what the published app would use.")
        if let production {
            let path = folder.isEmpty ? production : "\(folder)/\(production)"
            finding.fix = .setDartDefinesFile(path)
            finding.fixTitle = "Use \(path)"
        } else {
            finding.fix = .edit(.project)
            finding.fixTitle = "Choose another file"
        }
        return [finding]
    }

    // MARK: Shorebird

    private func shorebird() async -> [DoctorFinding] {
        guard let yaml = try? String(contentsOf: appDir.appendingPathComponent("shorebird.yaml"), encoding: .utf8) else {
            return [DoctorFinding(severity: .error, area: .shorebird, title: "shorebird.yaml is missing",
                                  detail: "Run “shorebird init” in \(app.appPath) with the Shorebird account for this app, then commit shorebird.yaml.",
                                  fix: .copy("shorebird init"), fixTitle: "Copy command")]
        }
        var findings: [DoctorFinding] = []
        let pubspec = (try? String(contentsOf: appDir.appendingPathComponent("pubspec.yaml"), encoding: .utf8)) ?? ""
        if pubspec.range(of: #"(?m)^\s*-\s*["']?shorebird\.yaml["']?\s*$"#, options: .regularExpression) == nil {
            findings.append(DoctorFinding(severity: .error, area: .shorebird, title: "pubspec.yaml doesn't list shorebird.yaml as an asset",
                detail: "Shorebird refuses to build without it. Add it under flutter → assets in pubspec.yaml and commit.",
                fix: .copy("flutter:\n  assets:\n    - shorebird.yaml\n"), fixTitle: "Copy the pubspec.yaml lines"))
        }

        let appID = ProjectScanner.firstMatch(#"(?m)^app_id:\s*["']?([A-Za-z0-9-]+)"#, in: yaml) ?? "?"
        let token = secrets[.shorebirdToken] ?? ""
        let usingKey = !token.isEmpty
        if usingKey && !token.hasPrefix("sb_api_") {
            findings.append(DoctorFinding(severity: .warning, area: .shorebird, title: "The Shorebird token is a legacy CI token",
                detail: "Shorebird is phasing those out. Create an API key (sb_api_…) at console.shorebird.dev and paste it instead.",
                fix: .open(URL(string: "https://console.shorebird.dev")!, then: .build), fixTitle: "Open Shorebird Console"))
        }

        let result = await capture("shorebird releases list", in: appDir)
        let output = result.output
        let who = usingKey ? "This app's Shorebird API key" : "This Mac's Shorebird login"
        let consoleFix = DoctorFinding.Fix.open(URL(string: "https://console.shorebird.dev")!, then: .build)
        if result.ok {
            let count = output.split(whereSeparator: \.isNewline).filter { $0.contains("+") || $0.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) != nil }.count
            var ok = DoctorFinding(severity: .ok, area: .shorebird, title: "\(who) can access Shorebird app \(appID)")
            if !usingKey {
                ok = DoctorFinding(severity: .warning, area: .shorebird, title: "Builds use this Mac's Shorebird login",
                    detail: "It works now, but with several Shorebird accounts the Mac's login may belong to another app's account — and logins expire. Save an API key for this app.",
                    fix: consoleFix, fixTitle: "Create an API key")
            }
            findings.append(ok)
            if count == 0 && app.supportsPatches {
                findings.append(DoctorFinding(severity: .warning, area: .shorebird, title: "No Shorebird releases yet",
                    detail: "Patch tags only work after a release tag (shorebird release) has shipped."))
            }
        } else if output.contains("Insufficient permissions") || output.contains("Could not find app") || output.contains("may not have permission") {
            findings.append(DoctorFinding(severity: .error, area: .shorebird, title: "\(who) can't access Shorebird app \(appID)",
                detail: "The app belongs to another Shorebird account. In Shorebird Console, sign in with the account that owns it, create an API key, and paste it as this app's Shorebird token.",
                fix: consoleFix, fixTitle: "Open Shorebird Console"))
        } else if output.contains("refresh credentials") || output.contains("not logged in") || output.contains("login") {
            findings.append(DoctorFinding(severity: .error, area: .shorebird, title: usingKey ? "Shorebird rejected this app's API key" : "This Mac isn't signed in to Shorebird",
                detail: "Save an API key from console.shorebird.dev (created with the account that owns this app) as this app's Shorebird token.",
                fix: consoleFix, fixTitle: "Open Shorebird Console"))
        } else {
            findings.append(DoctorFinding(severity: .warning, area: .shorebird, title: "Couldn't check Shorebird access",
                                          detail: lastLines(output)))
        }
        return findings
    }

    // MARK: Android

    private func android() async -> [DoctorFinding] {
        guard app.android.writesKeyProperties else {
            return [DoctorFinding(severity: .ok, area: .android, title: "Signing is left to the project's Gradle config")]
        }
        var findings: [DoctorFinding] = []
        let path = expandPath(app.android.keystorePath)
        guard !app.android.keystorePath.trimmed.isEmpty, FileManager.default.fileExists(atPath: path.path) else {
            return [DoctorFinding(severity: .error, area: .android, title: "The keystore file isn't there",
                                  detail: app.android.keystorePath, fix: .edit(.googlePlay), fixTitle: "Open Google Play")]
        }
        if let password = secrets[.androidKeystorePassword], !password.isEmpty {
            var env = self.env
            env["MILISHIP_STOREPASS"] = password
            let alias = app.android.keyAlias.trimmed
            do {
                _ = try await ShellRunner().run(
                    "keytool -list -keystore \(shq(path.path)) -storepass:env MILISHIP_STOREPASS -alias \(shq(alias))",
                    cwd: home, env: env, log: { _ in })
                findings.append(DoctorFinding(severity: .ok, area: .android, title: "Keystore opens with the saved password and alias “\(alias)”"))
            } catch {
                let text = describe(error)
                findings.append(DoctorFinding(severity: .error, area: .android,
                    title: text.contains("does not exist") ? "The keystore has no key called “\(alias)”" : "The saved keystore password doesn't open the keystore",
                    fix: .edit(.googlePlay), fixTitle: "Open Google Play"))
            }
        }
        if app.framework == .flutter, let gradle = ["android/app/build.gradle.kts", "android/app/build.gradle"]
            .compactMap({ try? String(contentsOf: appDir.appendingPathComponent($0), encoding: .utf8) }).first,
           !gradle.contains("key.properties") {
            findings.append(DoctorFinding(severity: .error, area: .android, title: "android/app/build.gradle doesn't read key.properties",
                detail: "Mili Ship writes key.properties for signing, but this project never loads it, so the bundle would be signed with the debug key and Google Play rejects it. Add the key.properties signing setup from docs.flutter.dev/deployment/android, or choose “Handled by the project's Gradle config”.",
                fix: .open(URL(string: "https://docs.flutter.dev/deployment/android#configure-signing-in-gradle")!, then: .googlePlay),
                fixTitle: "Open Flutter's signing guide"))
        }
        return findings
    }

    // MARK: iOS

    private func ios() async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        guard exists("ios/Podfile") || app.framework == .reactNative else { return [] }
        let pod = await capture("pod --version", in: home)
        if pod.ok {
            findings.append(DoctorFinding(severity: .ok, area: .ios, title: "CocoaPods \(pod.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "") works for builds"))
        } else {
            let path = (try? await ShellRunner().run("command -v pod", cwd: home, env: ProcessInfo.processInfo.environment,
                                                     interactive: true, log: { _ in }))?.trimmed ?? ""
            let terminalWorks = (try? await ShellRunner().run("pod --version", cwd: home, env: ProcessInfo.processInfo.environment,
                                                              interactive: true, log: { _ in })) != nil
            if terminalWorks, path.hasPrefix("/") {
                let folder = (path as NSString).deletingLastPathComponent
                findings.append(DoctorFinding(severity: .error, area: .ios, title: "CocoaPods is broken in builds but works in your Terminal",
                    detail: "Builds find a different pod or Ruby than your shell (\(path)).",
                    fix: .addToPATH(folder), fixTitle: "Add \(folder) to the build PATH"))
            } else {
                findings.append(DoctorFinding(severity: .error, area: .ios, title: "CocoaPods isn't working",
                    detail: lastLines(pod.output) + "\nReinstall it, e.g. brew install cocoapods.",
                    fix: .copy("brew install cocoapods"), fixTitle: "Copy command"))
            }
        }
        return findings
    }

    // MARK: GitHub Actions

    private func githubActions() async -> [DoctorFinding] {
        guard let repo = app.githubRepo, let githubToken else {
            return [DoctorFinding(severity: .warning, area: .githubActions, title: "No GitHub token to check the workflow",
                                  fix: .edit(.github), fixTitle: "Open GitHub Actions")]
        }
        let client = GitHubClient(token: githubToken, repo: repo)
        do {
            let repository = try await client.repository()
            let current = try await client.fileContent(path: app.githubActions.workflowPath, ref: repository.defaultBranch)
            let expected = ActionsWorkflow.yaml(for: app)
            if current == nil {
                return [DoctorFinding(severity: .error, area: .githubActions, title: "\(app.githubActions.workflowPath) isn't on \(repository.defaultBranch)",
                    detail: "Without it, tags don't start GitHub Actions runs.", fix: .addWorkflow, fixTitle: "Add workflow")]
            }
            if current != expected {
                return [DoctorFinding(severity: .warning, area: .githubActions, title: "The workflow is out of date",
                    detail: "Tag prefixes, platforms or the runner changed since it was added.", fix: .addWorkflow, fixTitle: "Update workflow")]
            }
            return [DoctorFinding(severity: .ok, area: .githubActions, title: "Workflow is up to date on \(repository.defaultBranch)")]
        } catch {
            return [DoctorFinding(severity: .warning, area: .githubActions, title: "Couldn't check the workflow", detail: describe(error))]
        }
    }

    // MARK: Helpers

    private var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: appDir.appendingPathComponent(relative).path)
    }

    private func first(_ command: String) -> String? {
        command.trimmed.split(separator: " ").first.map(String.init)
    }

    private func succeeds(_ command: String, in directory: URL? = nil) async -> Bool {
        (try? await ShellRunner().run(command, cwd: directory ?? home, env: env, log: { _ in })) != nil
    }

    private func capture(_ command: String, in directory: URL) async -> (ok: Bool, output: String) {
        let collector = Collector()
        do {
            _ = try await ShellRunner().run(command, cwd: directory, env: env, log: { collector.append($0) })
            return (true, collector.text)
        } catch {
            return (false, collector.text + "\n" + describe(error))
        }
    }

    private func lastLines(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
    }
}

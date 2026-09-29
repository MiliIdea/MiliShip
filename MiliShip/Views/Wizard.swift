import AppKit
import SwiftUI

/// Secrets typed in the wizard; written to the Keychain only when the user saves.
struct SecretStore {
    var new: [SecretKey: String] = [:]
    var removed: Set<SecretKey> = []
    var stored: Set<SecretKey> = []

    func has(_ key: SecretKey) -> Bool {
        !(new[key] ?? "").isEmpty || (stored.contains(key) && !removed.contains(key))
    }
}

enum WizardStep: Int, CaseIterable, Identifiable {
    case repository, project, prepare, build, github, googlePlay, appStore, review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .repository: return "Repository"
        case .project: return "Project"
        case .prepare: return "Prepare"
        case .build: return "Build & versioning"
        case .github: return "GitHub Actions"
        case .googlePlay: return "Google Play"
        case .appStore: return "App Store"
        case .review: return "Review"
        }
    }

    var subtitle: String {
        switch self {
        case .repository: return "Git URL & local clone"
        case .project: return "App, framework, options"
        case .prepare: return "Secret files & scripts"
        case .build: return "Tool, tags, versions"
        case .github: return "Runner & workflow"
        case .googlePlay: return "Signing & publishing"
        case .appStore: return "API key, signing, upload"
        case .review: return "Check & save"
        }
    }

    var explanation: String {
        switch self {
        case .repository: return "Where Mili Ship fetches your code and release tags from."
        case .project: return "Which Flutter or React Native app in the repository to build, and how."
        case .prepare: return "Files and commands a build needs that aren't committed to git."
        case .build: return "How the app is built, which tags trigger a deployment, and how version numbers are chosen."
        case .github: return "Optional: run deployments as GitHub Actions jobs on this Mac — free, instant, with live logs in GitHub."
        case .googlePlay: return "Sign the Android App Bundle and publish it to a Google Play track."
        case .appStore: return "Sign the iOS build and upload it to App Store Connect / TestFlight."
        case .review: return "Everything at a glance. You can change any of this later."
        }
    }

    var symbol: String {
        switch self {
        case .repository: return "arrow.triangle.branch"
        case .project: return "folder"
        case .prepare: return "wrench.and.screwdriver"
        case .build: return "hammer"
        case .github: return "arrow.triangle.2.circlepath.circle"
        case .googlePlay: return "play.rectangle"
        case .appStore: return "applelogo"
        case .review: return "checkmark.seal"
        }
    }
}

struct AppWizardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: AppModel.WizardRequest

    @State private var draft: AppConfig
    @State private var secrets: SecretStore
    @State private var step: WizardStep = .repository
    @State private var visited: Set<WizardStep>
    @State private var scan: RepoScan?
    @State private var scanning = false
    @State private var scanError: String?

    init(request: AppModel.WizardRequest) {
        self.request = request
        _draft = State(initialValue: request.app)
        var store = SecretStore()
        // Only checks which secrets exist, so opening the wizard never triggers a Keychain prompt.
        if !request.isNew { store.stored = Set(SecretKey.allCases.filter { Keychain.availability($0, app: request.app.id) != .missing }) }
        _secrets = State(initialValue: store)
        _step = State(initialValue: request.step)
        _visited = State(initialValue: request.isNew ? [request.step] : Set(WizardStep.allCases))
    }

    var body: some View {
        HStack(spacing: 0) {
            stepList
                .frame(width: 230)
                .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title).font(.title2.bold())
                    Text(step.explanation).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 4)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                footer.padding(14)
            }
        }
        .frame(width: 960, height: 700)
        .onChange(of: step) { newStep in
            visited.insert(newStep)
            if newStep == .project, scan == nil, !scanning, !draft.repoURL.trimmed.isEmpty { runScan() }
        }
    }

    // MARK: Step list

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.isNew ? "Add application" : request.app.displayName)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)

            ForEach(WizardStep.allCases) { item in
                Button { step = item } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.15))
                                .frame(width: 28, height: 28)
                            if item != step && isComplete(item) {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundColor(.green)
                            } else {
                                Image(systemName: item.symbol)
                                    .font(.caption)
                                    .foregroundColor(item == step ? Color.white : Color.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).fontWeight(item == step ? .semibold : .regular)
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(item == step ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canJump(to: item))
            }
            Spacer()
        }
        .padding(14)
    }

    private func isComplete(_ item: WizardStep) -> Bool {
        guard visited.contains(item), blockingIssue(for: item) == nil else { return false }
        switch item {
        case .googlePlay: return !draft.android.enabled || stepWarnings(prefix: ["Android", "Google Play"]).isEmpty
        case .appStore: return !draft.ios.enabled || stepWarnings(prefix: ["App Store"]).isEmpty
        case .github: return !draft.githubActions.enabled || stepWarnings(prefix: ["GitHub Actions"]).isEmpty
        default: return true
        }
    }

    private func stepWarnings(prefix: [String]) -> [String] {
        warnings.filter { warning in prefix.contains { warning.hasPrefix($0) } }
    }

    private func canJump(to item: WizardStep) -> Bool {
        if !request.isNew || visited.contains(item) { return true }
        // New apps: the repository basics must be filled before moving on.
        return blockingIssue(for: .repository) == nil && item.rawValue <= (visited.map(\.rawValue).max() ?? 0) + 1
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .repository:
            RepositoryStep(draft: $draft, scan: scan, scanning: scanning, scanError: scanError, onScan: runScan)
        case .project:
            ProjectStep(draft: $draft, scan: scan, scanning: scanning, scanError: scanError, onScan: runScan)
        case .prepare:
            PrepareStep(draft: $draft)
        case .build:
            BuildStep(draft: $draft, secrets: $secrets)
        case .github:
            GitHubActionsStep(draft: $draft, secrets: $secrets)
        case .googlePlay:
            GooglePlayStep(draft: $draft, secrets: $secrets)
        case .appStore:
            AppStoreStep(draft: $draft, exportOptionsSuggestions: selectedProject?.exportOptionsFiles ?? [])
        case .review:
            ReviewStep(draft: $draft, secrets: $secrets, warnings: warnings, runCheck: request.runCheck) { step = $0 }
        }
    }

    private var selectedProject: DetectedProject? {
        scan?.projects.first { $0.appPath == draft.appPath }
    }

    private var warnings: [String] {
        draft.setupWarnings { secrets.has($0) }
    }

    // MARK: Footer & navigation

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let issue = blockingIssue(for: step) {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let previous = WizardStep(rawValue: step.rawValue - 1) {
                Button("Back") { step = previous }
            }
            if let next = WizardStep(rawValue: step.rawValue + 1) {
                Button("Next") { step = next }
                    .keyboardShortcut(.defaultAction)
                    .disabled(blockingIssue(for: step) != nil)
            } else {
                Button(request.isNew ? "Add Application" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(blockingIssue(for: .review) != nil)
            }
        }
    }

    private func blockingIssue(for item: WizardStep) -> String? {
        switch item {
        case .repository:
            if draft.name.trimmed.isEmpty { return "Enter a name" }
            if draft.repoURL.trimmed.isEmpty { return "Enter the Git URL" }
        case .project:
            if draft.appPath.trimmed.isEmpty { return "Enter the app path (\".\" for the repository root)" }
        case .build:
            if draft.releaseTagPrefix.isEmpty { return "The release tag prefix can't be empty" }
            if draft.supportsPatches && draft.patchTagPrefix == draft.releaseTagPrefix { return "Release and patch prefixes must differ" }
        case .review:
            if let issue = blockingIssue(for: .repository) { return issue }
            if let issue = blockingIssue(for: .build) { return issue }
            if draft.enabledPlatforms.isEmpty { return "Enable Android or iOS" }
        default:
            break
        }
        return nil
    }

    @MainActor
    private func save() {
        model.saveApp(draft, secrets: secrets)
        dismiss()
    }

    @MainActor
    private func runScan() {
        guard !scanning, !draft.repoURL.trimmed.isEmpty else { return }
        // Freeze the clone location so renaming the app later doesn't re-clone.
        if draft.workspacePath.trimmed.isEmpty { draft.workspacePath = abbreviatePath(draft.workspaceURL) }
        scanning = true
        scanError = nil
        let snapshot = draft
        Task {
            do {
                let result = try await model.scanRepository(for: snapshot)
                scan = result
                if result.projects.isEmpty {
                    scanError = "No app found: neither a Flutter app (pubspec.yaml with android/ or ios/) nor a React Native app (package.json with react-native and android/, ios/ or Expo)."
                } else if request.isNew, result.projects.count == 1 {
                    draft.apply(result.projects[0], from: result)
                }
            } catch {
                scanError = describe(error)
            }
            scanning = false
        }
    }
}

// MARK: - 1 · Repository

private struct RepositoryStep: View {
    @Binding var draft: AppConfig
    let scan: RepoScan?
    let scanning: Bool
    let scanError: String?
    let onScan: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("My App"))
                TextField("Git URL", text: $draft.repoURL, prompt: Text("git@github.com:company/app.git"))
            } header: {
                Text("Repository")
            } footer: {
                Text("SSH URLs use your ssh-agent / ~/.ssh keys. HTTPS URLs use git's credential helper (e.g. a GitHub token saved in the macOS keychain). The same access your terminal has.")
            }

            Section {
                PathField(title: "Clone folder", path: $draft.workspacePath, directory: true, prompt: abbreviatePath(draft.workspaceURL))
            } header: {
                Text("Local clone")
            } footer: {
                Text("Mili Ship keeps its own clone here and checks out tags in it, so your working copy is never touched. Leave empty for the default.")
            }

            Section("Clone & detect") {
                HStack {
                    Button(scanning ? "Cloning…" : (scan == nil ? "Clone & scan repository" : "Update & rescan"), action: onScan)
                        .disabled(scanning || draft.repoURL.trimmed.isEmpty)
                    if scanning { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let scanError {
                    Text(scanError)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let scan, !scan.projects.isEmpty {
                    Label(scanSummary(scan), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text("Optional here: the next step scans automatically.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func scanSummary(_ scan: RepoScan) -> String {
        var parts = ["Found \(scan.projects.count) app\(scan.projects.count == 1 ? "" : "s")"]
        let frameworks = Set(scan.projects.map(\.framework))
        parts.append(AppFramework.allCases.filter(frameworks.contains).map(\.title).joined(separator: " + "))
        if scan.usesMelos { parts.append("melos workspace") }
        if scan.usesFVM { parts.append("FVM") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 2 · Project

private struct ProjectStep: View {
    @Binding var draft: AppConfig
    let scan: RepoScan?
    let scanning: Bool
    let scanError: String?
    let onScan: () -> Void

    private var selected: DetectedProject? { scan?.projects.first { $0.appPath == draft.appPath } }

    var body: some View {
        Form {
            Section {
                if let scan, !scan.projects.isEmpty {
                    ForEach(scan.projects) { project in
                        ProjectCandidateRow(project: project, selected: draft.appPath == project.appPath) {
                            draft.apply(project, from: scan)
                        }
                    }
                } else if scanning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Cloning and scanning the repository…")
                    }
                } else {
                    Text(scanError ?? "Scan the repository to detect Flutter and React Native apps, or type the path below.")
                        .foregroundStyle(scanError == nil ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                    Button("Scan repository", action: onScan).disabled(draft.repoURL.trimmed.isEmpty)
                }
                TextField("App path", text: $draft.appPath, prompt: Text("."))
                Picker("Framework", selection: Binding(get: { draft.framework }, set: switchFramework)) {
                    ForEach(AppFramework.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("App")
            } footer: {
                Text("Relative to the repository root, e.g. apps/my_app in a monorepo or . for a single app. Picking a detected app fills in the framework and the identifiers for the store steps.")
            }

            switch draft.framework {
            case .flutter: flutterSections
            case .reactNative: reactNativeSections
            }
        }
        .formStyle(.grouped)
    }

    /// Swaps the dependency command when it's still the other framework's default.
    private func switchFramework(_ framework: AppFramework) {
        guard framework != draft.framework else { return }
        let command = draft.bootstrapCommand.trimmed
        let flutterDefault = command.isEmpty || command.hasSuffix("pub get") || command == "melos bootstrap"
        let nodeDefault = ["npm", "yarn", "pnpm", "bun"].contains { command.hasPrefix($0 + " ") }
        if framework == .reactNative && flutterDefault { draft.bootstrapCommand = "npm ci" }
        if framework == .flutter && (nodeDefault || command.isEmpty) { draft.bootstrapCommand = "\(draft.flutterCommand.trimmed.isEmpty ? "flutter" : draft.flutterCommand) pub get" }
        draft.framework = framework
    }

    @ViewBuilder
    private var reactNativeSections: some View {
        Section {
            TextField("Install dependencies", text: $draft.bootstrapCommand, prompt: Text("npm ci"))
            Toggle("Run Expo prebuild (generates android/ and ios/)", isOn: $draft.reactNative.expoPrebuild)
            TextField("CocoaPods", text: $draft.reactNative.podInstallCommand, prompt: Text("empty = skip"))
        } header: {
            Text("Toolchain")
        } footer: {
            Text("Commands run in the app folder (CocoaPods in ios/). Use yarn, pnpm or bun if the repository does; turn on Expo prebuild for Expo apps that don't commit their native folders. Node is found through nvm, Volta, Homebrew or Settings → Shell PATH.")
        }

        Section {
            TextField("Product flavor", text: $draft.flavor, prompt: Text("none"))
            TextField("Gradle task", text: $draft.reactNative.androidGradleTask, prompt: Text(draft.reactNativeGradleTask))
            TextField("Extra Gradle arguments", text: $draft.reactNative.extraGradleArgs, prompt: Text("--no-daemon"))
        } header: {
            Text("Android")
        } footer: {
            Text("Runs ./gradlew \(draft.reactNativeGradleTask) in android/. The task follows the flavor unless you set one.")
        }

        Section {
            ComboField(title: "Workspace", text: $draft.reactNative.iosWorkspace, prompt: selected?.reactNative?.iosWorkspace ?? "auto-detect in ios/",
                       suggestions: selected?.reactNative?.iosWorkspace.map { [$0] } ?? [])
            TextField("Scheme", text: $draft.reactNative.iosScheme, prompt: Text(selected?.reactNative?.iosScheme ?? "workspace name"))
            TextField("Configuration", text: $draft.reactNative.iosConfiguration, prompt: Text("Release"))
            TextField("Extra xcodebuild arguments", text: $draft.reactNative.extraXcodebuildArgs, prompt: Text("SWIFT_ACTIVE_COMPILATION_CONDITIONS=PROD"))
        } header: {
            Text("iOS")
        } footer: {
            Text("Runs xcodebuild archive. Leave the workspace and scheme empty to use the one in ios/ (also after Expo prebuild). Environment files such as .env can be added in the Prepare step.")
        }
    }

    @ViewBuilder
    private var flutterSections: some View {
        Section {
            TextField("Flutter command", text: $draft.flutterCommand, prompt: Text("flutter"))
            TextField("Install dependencies", text: $draft.bootstrapCommand, prompt: Text("flutter pub get"))
        } header: {
            Text("Toolchain")
        } footer: {
            Text("Use “fvm flutter” for FVM projects and “melos bootstrap” for melos monorepos. Commands run in the app folder; Shorebird builds use Shorebird's own Flutter.")
        }

        Section {
            TextField("Flavor", text: $draft.flavor, prompt: Text("none"))
            ComboField(title: "Entry point (--target)", text: $draft.target, prompt: "lib/main.dart", suggestions: selected?.entryPoints ?? [])
            ComboField(title: "Dart defines file", text: $draft.dartDefineFile, prompt: "config/dart_defines.json", suggestions: selected?.dartDefineFiles ?? [])
            TextField("Extra build arguments", text: $draft.extraBuildArgs, prompt: Text("--obfuscate --split-debug-info=build/symbols"))
        } header: {
            Text("Build options")
        } footer: {
            Text("Paths are relative to the app folder. The dart defines file is passed as --dart-define-from-file.")
        }
    }
}

private struct ProjectCandidateRow: View {
    let project: DetectedProject
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(project.packageName).bold()
                        Text(project.appPath).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Chip(symbol: project.framework == .flutter ? "bird.fill" : "atom", text: project.framework.title)
                        if project.usesShorebird { Chip(symbol: "bird", text: "Shorebird") }
                        if project.reactNative?.usesExpo == true { Chip(symbol: "shippingbox", text: "Expo") }
                    }
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var details: String {
        var parts: [String] = []
        if let version = project.version { parts.append("version \(version)") }
        if project.hasAndroid { parts.append("Android \(project.androidApplicationID ?? "")".trimmed) }
        if project.hasIOS { parts.append("iOS \(project.iosBundleID ?? "")".trimmed) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 3 · Prepare

private struct PrepareStep: View {
    @Binding var draft: AppConfig

    var body: some View {
        Form {
            Section {
                if draft.fileInjections.isEmpty {
                    Text("No files. Add google-services.json, GoogleService-Info.plist, .env or config files that are git-ignored.")
                        .foregroundStyle(.secondary)
                }
                ForEach($draft.fileInjections) { $injection in
                    HStack {
                        PathField(title: "Local file", path: $injection.source)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Destination", text: $injection.destination, prompt: Text("android/app/google-services.json"))
                        Button {
                            draft.fileInjections.removeAll { $0.id == injection.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    draft.fileInjections.append(FileInjection())
                } label: {
                    Label("Add file", systemImage: "plus")
                }
            } header: {
                Text("Copy local files into the checkout")
            } footer: {
                Text("Copied after every checkout. The destination is relative to the repository root.")
            }

            Section {
                TextEditor(text: $draft.preBuildCommands)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
            } header: {
                Text("Pre-build commands")
            } footer: {
                Text("One shell command per line, run in the app folder after dependencies are installed. Lines starting with # are ignored.\nExamples:  cp lib/config.example.dart lib/config.dart   ·   dart run build_runner build -d   ·   cp .env.production .env")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 4 · Build & versioning

private struct BuildStep: View {
    @Binding var draft: AppConfig
    @Binding var secrets: SecretStore

    var body: some View {
        Form {
            if draft.framework == .reactNative {
                Section("Build tool") {
                    LabeledContent("Build with", value: "Gradle + xcodebuild")
                    Text("Android: ./gradlew \(draft.reactNativeGradleTask). iOS: CocoaPods, then xcodebuild archive. Every release tag becomes a store build; over-the-air updates aren't supported for React Native yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Build tool") {
                    Picker("Build with", selection: $draft.buildTool) {
                        ForEach(BuildTool.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(draft.buildTool.detail).font(.caption).foregroundStyle(.secondary)

                    if draft.buildTool == .shorebird {
                        SecretField(title: "Shorebird API key", key: .shorebirdToken, store: $secrets,
                                    help: "An API key (sb_api_…) from the Shorebird account that owns this app. Each app can use a different Shorebird account. Without one, builds use this Mac's “shorebird login”.")
                        Link("Create an API key in Shorebird Console…", destination: URL(string: "https://console.shorebird.dev")!)
                            .font(.callout)
                        Toggle("Allow native code changes in patches (--allow-native-diffs)", isOn: $draft.shorebird.allowNativeDiffs)
                        Toggle("Allow asset changes in patches (--allow-asset-diffs)", isOn: $draft.shorebird.allowAssetDiffs)
                        TextField("Flutter version for releases", text: $draft.shorebird.flutterVersion, prompt: Text("Shorebird default"))
                    }
                }
            }

            Section {
                TextField("Release tag prefix", text: $draft.releaseTagPrefix, prompt: Text("release/"))
                if draft.usesShorebird {
                    TextField("Patch tag prefix", text: $draft.patchTagPrefix, prompt: Text("patch/ (empty = no patches)"))
                }
            } header: {
                Text("Tags that trigger a deployment")
            } footer: {
                Text(tagExamples)
            }

            Section("Versioning") {
                Picker("Version", selection: $draft.versionStrategy) {
                    ForEach(VersionStrategy.allCases) { strategy in
                        Text(strategy.title(for: draft.framework)).tag(strategy)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(draft.versionStrategy.detail(for: draft.framework)).font(.caption).foregroundStyle(.secondary)
                if draft.supportsPatches {
                    Text("Patches: \(draft.patchTagPrefix)1.2.0+45 patches release 1.2.0+45. Without a full version the newest release is patched.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Automation") {
                Toggle("Watch GitHub for new tags", isOn: $draft.watchTags)
                Stepper("Check every \(draft.pollMinutes) min", value: $draft.pollMinutes, in: 1...120)
                    .disabled(!draft.watchTags)
                Toggle("Deploy new tags automatically", isOn: $draft.autoBuild)
                    .disabled(!draft.watchTags)
                Text(draft.githubActions.enabled
                     ? "With GitHub Actions on, GitHub starts deployments the moment a tag is pushed; watching only keeps the tag list fresh."
                     : "Tags that already exist the first time Mili Ship syncs are never deployed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var tagExamples: String {
        var text = "\(draft.releaseTagPrefix)1.2.0+45 → store release"
        if draft.supportsPatches { text += "   ·   \(draft.patchTagPrefix)1.2.0+45 → Shorebird patch" }
        return text
    }
}

// MARK: - 5 · GitHub Actions

private struct GitHubActionsStep: View {
    @EnvironmentObject private var model: AppModel
    @Binding var draft: AppConfig
    @Binding var secrets: SecretStore

    @State private var working: String?
    @State private var progress = ""
    @State private var result: (ok: Bool, message: String, url: URL?)?
    @State private var showWorkflow = false
    @State private var cliAccount: String?

    private var repo: GitHubRepo? { draft.githubRepo }
    private var token: String? { secrets.new[.githubToken] }
    private var hasToken: Bool { secrets.has(.githubToken) }
    private var state: RunnerState { model.runnerState(for: draft.id) }

    var body: some View {
        Form {
            Section {
                Toggle("Run deployments in GitHub Actions", isOn: $draft.githubActions.enabled)
            } footer: {
                Text("Mili Ship installs GitHub's official runner on this Mac. A pushed tag starts a GitHub Actions job right away; the job hands the tag to Mili Ship, and the full log streams to the run in GitHub. It runs on your Mac, so it costs no Actions minutes — even for private repositories.")
            }

            if draft.githubActions.enabled {
                if let repo {
                    tokenSection(repo)
                    runnerSection(repo)
                    workflowSection(repo)
                } else {
                    Section {
                        Label("GitHub Actions needs a repository on github.com. The Git URL is \(draft.repoURL.isEmpty ? "empty" : draft.repoURL).",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Sections

    private func tokenSection(_ repo: GitHubRepo) -> some View {
        Section {
            SecretField(title: "GitHub token", key: .githubToken, store: $secrets)
            HStack(spacing: 14) {
                Button(working == "gh" ? "Reading…" : "Use GitHub CLI Login") { useGitHubCLI() }
                    .disabled(working != nil)
                    .help("Uses the token of the GitHub CLI (gh) you're signed in to on this Mac")
                if working == "gh" { ProgressView().controlSize(.small) }
                Link("Create a fine-grained token…", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                Spacer()
            }
            if let cliAccount {
                Label("Using the GitHub CLI token of @\(cliAccount). Save to keep it in the Keychain.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            DisclosureGroup("Which permissions?") {
                Text("""
                Repository access: only \(repo.fullName).
                Repository permissions, Read and write: Administration (registers the runner), Actions (starts runs), Contents and Workflows (adds the workflow file), Pull requests (only if the default branch is protected).
                A classic token with the repo and workflow scopes works too.
                """)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Step 1 · Access to \(repo.fullName)")
        } footer: {
            Text("Stored in the macOS Keychain. Used to register the runner, add the workflow and start runs from Mili Ship's Deploy buttons.")
        }
    }

    private func runnerSection(_ repo: GitHubRepo) -> some View {
        Section {
            if draft.githubActions.isConnected {
                LabeledContent("Runner") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(draft.githubActions.runnerName).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text("label \(draft.githubActions.runnerLabel)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.app(draft.id) != nil {
                    LabeledContent("Status") { RunnerStatusLabel(state: state) }
                } else {
                    Text("Starts when you add the application.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(draft.githubActions.isConnected ? "Reconnect Runner" : "Connect Runner") { connect() }
                    .disabled(working != nil)
                if draft.githubActions.isConnected {
                    Button("Disconnect", role: .destructive) { disconnect() }
                        .disabled(working != nil)
                }
                if working == "runner" { ProgressView().controlSize(.small) }
                Spacer()
            }
            if working == "runner", !progress.isEmpty {
                Text(progress).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            if draft.githubActions.isConnected && draft.githubActions.repositoryIsPublic {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(repo.fullName) is public. A self-hosted runner runs whatever a workflow asks, so require approval for workflows from outside collaborators.")
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Open Actions settings", destination: repo.webURL.appendingPathComponent("settings/actions"))
                    }
                }
                .font(.callout)
            }
        } header: {
            Text("Step 2 · Runner on this Mac")
        } footer: {
            Text("Downloads GitHub's runner (about 100 MB, once) into ~/.miliship and registers it for \(repo.fullName) only. It runs while Mili Ship runs — keep \"Keep running in the menu bar\" and \"Open at login\" on. While the Mac sleeps, GitHub keeps new jobs queued for up to 24 hours.")
        }
    }

    private func workflowSection(_ repo: GitHubRepo) -> some View {
        Section {
            TextField("Workflow file", text: $draft.githubActions.workflowFile, prompt: Text("miliship.yml"))
            Stepper("Time limit: \(draft.githubActions.timeoutMinutes) min", value: $draft.githubActions.timeoutMinutes, in: 10...360, step: 10)
            HStack {
                Button("Add Workflow to Repository") { installWorkflow() }
                    .disabled(working != nil || !draft.githubActions.isConnected)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ActionsWorkflow.yaml(for: draft), forType: .string)
                }
                .disabled(!draft.githubActions.isConnected)
                Button(showWorkflow ? "Hide" : "Preview") { showWorkflow.toggle() }
                if working == "workflow" { ProgressView().controlSize(.small) }
                Spacer()
            }
            if showWorkflow {
                ScrollView(.horizontal) {
                    Text(ActionsWorkflow.yaml(for: draft))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if let result {
                HStack(alignment: .top) {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundColor(result.ok ? .green : .red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let url = result.url { Link("Open", destination: url) }
                }
            }
        } header: {
            Text("Step 3 · Workflow")
        } footer: {
            Text("Adds \(draft.githubActions.workflowPath): tags matching \(draft.releaseTagPrefix)…\(draft.supportsPatches ? " and \(draft.patchTagPrefix)…" : "") run on this Mac's runner. GitHub reads the workflow from the tagged commit, so it applies to tags created after it's merged; older tags still deploy locally. Update it after changing tag prefixes or platforms.")
        }
    }

    // MARK: Actions

    @MainActor
    private func useGitHubCLI() {
        working = "gh"
        result = nil
        Task {
            do {
                let cli = try await model.githubCLIToken()
                secrets.new[.githubToken] = cli.token
                secrets.removed.remove(.githubToken)
                cliAccount = cli.login.isEmpty ? "your account" : cli.login
            } catch {
                result = (false, describe(error), nil)
            }
            working = nil
        }
    }

    @MainActor
    private func connect() {
        working = "runner"
        progress = ""
        result = nil
        let snapshot = draft
        let token = self.token
        Task {
            do {
                let connected = try await model.connectActions(snapshot, token: token) { line in
                    let text = line.trimmed
                    guard !text.isEmpty else { return }
                    Task { @MainActor in progress = text }
                }
                draft.githubActions = connected.config
                // Keep whichever token worked (it may be the GitHub CLI login) for Save.
                if connected.token != token {
                    secrets.new[.githubToken] = connected.token
                    secrets.removed.remove(.githubToken)
                }
                result = (true, "Runner connected. Add the workflow next.", nil)
            } catch {
                result = (false, describe(error), nil)
            }
            working = nil
        }
    }

    @MainActor
    private func disconnect() {
        working = "runner"
        let snapshot = draft
        let token = self.token
        Task {
            draft.githubActions = await model.disconnectActions(snapshot, token: token)
            result = (true, "Runner removed from this Mac and from GitHub.", nil)
            working = nil
        }
    }

    @MainActor
    private func installWorkflow() {
        working = "workflow"
        result = nil
        let snapshot = draft
        let token = self.token
        Task {
            do {
                let outcome = try await model.installWorkflow(snapshot, token: token)
                result = (true, outcome.message, outcome.url)
            } catch {
                result = (false, describe(error), nil)
            }
            working = nil
        }
    }
}

/// Coloured dot and text for a runner's state.
struct RunnerStatusLabel: View {
    let state: RunnerState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.title)
            if let detail = state.detail {
                Text("· \(detail)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .help(state.detail ?? state.title)
    }

    private var color: Color {
        switch state {
        case .online: return .green
        case .busy, .updating, .starting: return .blue
        case .reconnecting: return .orange
        case .needsReconnect: return .red
        case .stopped: return .secondary
        }
    }
}

// MARK: - 6 · Google Play

private struct GooglePlayStep: View {
    @EnvironmentObject private var model: AppModel
    @Binding var draft: AppConfig
    @Binding var secrets: SecretStore

    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var keyResult: (ok: Bool, message: String)?

    private var signingFooter: String {
        let handoff = draft.framework == .flutter
            ? "key.properties is written before the build and removed afterwards (docs.flutter.dev/deployment/android)."
            : "The keystore is passed to Gradle as android.injected.signing properties, so nothing is written and the project's signingConfig is bypassed."
        switch draft.android.effectiveSigning {
        case .playAppSigning:
            return "Recommended. Google Play keeps the real app signing key and re-signs every release; you only sign uploads with an upload key (Play still rejects unsigned bundles). A lost upload key can be reset in Play Console → Setup → App signing. New app? Enter an alias and password, then generate a key and register it on first upload. " + handoff
        case .ownKey:
            return "For apps opted out of Play App Signing or distributed outside Play: the bundle is signed with your app signing key. Keep a backup — a lost key means you can't update the app. " + handoff
        case .gradle:
            return "Nothing is written. android/app/build.gradle must sign the release bundle itself (e.g. from environment variables or a committed key.properties)."
        }
    }

    /// Creates a new upload keystore with keytool, using the alias and password entered above.
    private func generateUploadKey() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "upload-keystore.jks"
        panel.message = "Store the upload keystore outside the repository and back it up."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let password = secrets.new[.androidKeystorePassword] ?? ""
        let alias = draft.android.keyAlias.trimmed
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/keytool")
        process.arguments = ["-genkeypair", "-v", "-keystore", url.path, "-storetype", "JKS",
                             "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000", "-alias", alias,
                             "-storepass:env", "MILISHIP_STOREPASS", "-keypass:env", "MILISHIP_STOREPASS",
                             "-dname", "CN=\(draft.name.isEmpty ? alias : draft.name)"]
        var env = ProcessInfo.processInfo.environment
        env["MILISHIP_STOREPASS"] = password
        process.environment = env
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do {
            try? FileManager.default.removeItem(at: url)
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                draft.android.keystorePath = url.path
                secrets.new[.androidKeyPassword] = ""
                keyResult = (true, "Created \(url.lastPathComponent)")
            } else {
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmed ?? ""
                keyResult = (false, message.isEmpty ? "keytool failed (is a JDK installed?)" : message)
            }
        } catch {
            keyResult = (false, "keytool not found — install a JDK or Android Studio.")
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Build and deploy the Android app", isOn: $draft.android.enabled)
            }

            if draft.android.enabled {
                Section {
                    Picker("Signing", selection: Binding(
                        get: { draft.android.effectiveSigning },
                        set: { draft.android.signing = $0; draft.android.writeKeyProperties = true }
                    )) {
                        ForEach(AndroidSigning.allCases) { Text($0.title).tag($0) }
                    }
                    if draft.android.writesKeyProperties {
                        PathField(title: draft.android.signing == .ownKey ? "Signing keystore" : "Upload keystore",
                                  path: $draft.android.keystorePath, prompt: "upload-keystore.jks")
                        TextField("Key alias", text: $draft.android.keyAlias, prompt: Text("upload"))
                        SecretField(title: "Keystore password", key: .androidKeystorePassword, store: $secrets)
                        SecretField(title: "Key password", key: .androidKeyPassword, store: $secrets,
                                    help: "Leave empty if it's the same as the keystore password.")
                        if draft.framework == .flutter {
                            TextField("key.properties location", text: $draft.android.keyPropertiesPath, prompt: Text("android/key.properties"))
                        }
                        if draft.android.signing == .playAppSigning {
                            HStack {
                                Button("Generate new upload key…") { generateUploadKey() }
                                    .disabled(draft.android.keyAlias.trimmed.isEmpty || (secrets.new[.androidKeystorePassword] ?? "").count < 6)
                                if let keyResult {
                                    Label(keyResult.message, systemImage: keyResult.ok ? "checkmark.circle" : "xmark.octagon")
                                        .foregroundStyle(keyResult.ok ? .green : .red)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Step 1 · Signing")
                } footer: {
                    Text(signingFooter)
                }

                Section {
                    Toggle("Publish release builds to Google Play", isOn: $draft.android.upload)
                    if draft.android.upload {
                        TextField("Package name", text: $draft.android.packageName, prompt: Text("com.company.app"))
                        PathField(title: "Service account JSON", path: $draft.android.serviceAccountPath, prompt: "play-service-account.json")
                        DisclosureGroup("How do I get a service account key?") {
                            Text("""
                            1. Google Cloud Console → pick a project → enable “Google Play Android Developer API”.
                            2. IAM & Admin → Service accounts → Create service account → Keys → Add key → JSON. Download it.
                            3. Play Console → Users and permissions → Invite new users → paste the service account e-mail, add this app, and grant the release permissions (testing tracks and/or production).
                            4. Choose the JSON file above and press Test connection.
                            """)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    Text("Step 2 · Google Play API access")
                } footer: {
                    Text("Mili Ship talks to the Google Play Developer API directly; fastlane isn't needed.")
                }

                if draft.android.upload {
                    Section {
                        ComboField(title: "Track", text: $draft.android.track, prompt: "internal",
                                   suggestions: ["internal", "alpha", "beta", "production"])
                        Picker("Release", selection: $draft.android.releaseStatus) {
                            ForEach(PlayReleaseStatus.allCases) { Text($0.title).tag($0) }
                        }
                        if draft.android.releaseStatus == .inProgress {
                            HStack {
                                Slider(value: $draft.android.rolloutPercent, in: 1...99, step: 1) { Text("Rollout") }
                                Text("\(Int(draft.android.rolloutPercent)) %").monospacedDigit().frame(width: 44)
                            }
                        }
                        Toggle("Don't send changes for review automatically", isOn: $draft.android.changesNotSentForReview)
                        TextField("Release notes language", text: $draft.android.releaseNotesLanguage, prompt: Text("en-US"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Release notes (optional, max 500 characters)").font(.callout)
                            TextEditor(text: $draft.android.releaseNotes)
                                .font(.body)
                                .frame(minHeight: 60)
                        }
                    } header: {
                        Text("Step 3 · Release")
                    } footer: {
                        Text("Use “Draft” while the app has never been published — Google Play rejects other statuses for draft apps. The very first build of a new app must be uploaded manually in Play Console.")
                    }

                    Section("Step 4 · Test") {
                        HStack {
                            Button(testing ? "Testing…" : "Test Google Play connection") { test() }
                                .disabled(testing || draft.android.serviceAccountPath.trimmed.isEmpty || draft.android.packageName.trimmed.isEmpty)
                            if testing { ProgressView().controlSize(.small) }
                            Spacer()
                        }
                        if let testResult {
                            Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundColor(testResult.ok ? Color.green : Color.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @MainActor
    private func test() {
        testing = true
        testResult = nil
        let android = draft.android
        Task {
            testResult = await model.testGooglePlay(android)
            testing = false
        }
    }
}

// MARK: - 7 · App Store

private struct AppStoreStep: View {
    @EnvironmentObject private var model: AppModel
    @Binding var draft: AppConfig
    let exportOptionsSuggestions: [String]

    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?

    var body: some View {
        Form {
            Section {
                Toggle("Build and deploy the iOS app", isOn: $draft.ios.enabled)
            }

            if draft.ios.enabled {
                Section {
                    TextField("Key ID", text: $draft.ios.ascKeyID, prompt: Text("ABC123DEF4"))
                    TextField("Issuer ID", text: $draft.ios.ascIssuerID, prompt: Text("69a6de7a-…"))
                    PathField(title: "Private key (.p8)", path: $draft.ios.ascKeyPath, prompt: "AuthKey_ABC123DEF4.p8")
                    DisclosureGroup("How do I create an API key?") {
                        Text("""
                        1. App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys.
                        2. Generate API Key with the App Manager (or Admin) role.
                        3. Download the .p8 file (only possible once) and note the Key ID and the Issuer ID shown above the list.
                        4. Keep the .p8 somewhere safe, e.g. ~/.private_keys, and choose it above.
                        """)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Step 1 · App Store Connect API key")
                } footer: {
                    Text("Used for automatic signing (xcodebuild -allowProvisioningUpdates), for uploading and for reading build numbers.")
                }

                Section {
                    TextField("Bundle ID", text: $draft.ios.bundleID, prompt: Text("com.company.app"))
                    TextField("Team ID", text: $draft.ios.teamID, prompt: Text("ABCDE12345"))
                } header: {
                    Text("Step 2 · App")
                } footer: {
                    Text("The app record must already exist in App Store Connect (My Apps → +).")
                }

                Section {
                    Picker("Signing", selection: $draft.ios.signing) {
                        ForEach(IOSSigning.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    if draft.ios.signing == .exportOptionsFile {
                        ComboField(title: "ExportOptions.plist", text: $draft.ios.exportOptionsPath,
                                   prompt: "ios/ExportOptions.plist", suggestions: exportOptionsSuggestions)
                    }
                } header: {
                    Text("Step 3 · Signing")
                } footer: {
                    Text(draft.ios.signing == .automatic
                         ? "Xcode creates or downloads the distribution certificate and provisioning profiles with the API key. Signing in to Xcode (Settings → Accounts) on this Mac also works."
                         : "Path relative to the app folder. Certificates and profiles it references must be installed on this Mac.")
                }

                Section {
                    Toggle("Upload release builds to App Store Connect", isOn: $draft.ios.upload)
                } header: {
                    Text("Step 4 · Upload")
                } footer: {
                    Text("Uploads with xcodebuild -exportArchive (destination: upload). Builds show up in TestFlight after Apple finishes processing.")
                }

                Section("Step 5 · Test") {
                    HStack {
                        Button(testing ? "Testing…" : "Test App Store Connect connection") { test() }
                            .disabled(testing || draft.ios.ascKeyPath.trimmed.isEmpty || draft.ios.ascKeyID.trimmed.isEmpty || draft.ios.ascIssuerID.trimmed.isEmpty)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let testResult {
                        Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundColor(testResult.ok ? Color.green : Color.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @MainActor
    private func test() {
        testing = true
        testResult = nil
        let ios = draft.ios
        Task {
            testResult = await model.testAppStore(ios)
            testing = false
        }
    }
}

// MARK: - 8 · Review

private struct ReviewStep: View {
    @Binding var draft: AppConfig
    @Binding var secrets: SecretStore
    let warnings: [String]
    var runCheck = false
    let onEdit: (WizardStep) -> Void

    var body: some View {
        Form {
            PreflightSection(draft: $draft, secrets: $secrets, autoRun: runCheck, onEdit: onEdit)
            Section {
                if warnings.isEmpty {
                    Label("Everything needed for a deployment is configured.", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                } else {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    Text("You can save now and finish these later — deployments of the affected platform will fail until then.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Checks")
            }
            AppSummarySections(app: draft, onEdit: onEdit)
        }
        .formStyle(.grouped)
    }
}

/// Runs `ProjectDoctor` on Mili Ship's clone and lists the problems a build would hit, with fixes.
private struct PreflightSection: View {
    @EnvironmentObject private var model: AppModel
    @Binding var draft: AppConfig
    @Binding var secrets: SecretStore
    let autoRun: Bool
    let onEdit: (WizardStep) -> Void

    @State private var findings: [DoctorFinding]?
    @State private var running = false
    @State private var progress = ""
    @State private var fixed: Set<UUID> = []
    @State private var fixMessage: [UUID: String] = [:]
    @State private var didAutoRun = false

    private var problems: Int { findings?.filter { $0.severity != .ok && !fixed.contains($0.id) }.count ?? 0 }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Button(running ? "Checking…" : (findings == nil ? "Check Project" : "Check Again")) { run() }
                    .disabled(running || draft.repoURL.trimmed.isEmpty)
                if running {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                } else if let findings {
                    Label(problems == 0 ? "Ready to deploy" : "\(problems) problem\(problems == 1 ? "" : "s") to fix",
                          systemImage: problems == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(problems == 0 ? .green : .orange)
                    if !fixed.isEmpty {
                        Text("· \(fixed.count) fixed — save to keep").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(findings.filter { $0.severity == .ok }.count) passed").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let findings {
                ForEach(findings) { finding in row(finding) }
            }
        } header: {
            Text("Pre-flight check")
        } footer: {
            Text("Builds the way a deployment would see it: Mili Ship's own clone of the default branch, the build environment and your saved secrets. Run it before you tag a release.")
        }
        .task {
            guard autoRun, !didAutoRun else { return }
            didAutoRun = true
            run()
        }
    }

    @ViewBuilder
    private func row(_ finding: DoctorFinding) -> some View {
        let done = fixed.contains(finding.id)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : icon(finding.severity))
                .foregroundStyle(done ? .green : color(finding.severity))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.area.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(finding.title).font(.callout.weight(finding.severity == .ok ? .regular : .medium))
                }
                if let detail = finding.detail, finding.severity != .ok {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = fixMessage[finding.id] {
                    Text(message).font(.caption).foregroundStyle(done ? .green : .red).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let fix = finding.fix, let title = finding.fixTitle, finding.severity != .ok, !done {
                Button(title) { apply(fix, to: finding) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(_ severity: DoctorFinding.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .ok: return "checkmark.circle"
        }
    }

    private func color(_ severity: DoctorFinding.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .ok: return .green
        }
    }

    private func step(for place: DoctorFinding.Place) -> WizardStep {
        switch place {
        case .project: return .project
        case .prepare: return .prepare
        case .build: return .build
        case .github: return .github
        case .googlePlay: return .googlePlay
        case .appStore: return .appStore
        }
    }

    @MainActor
    private func run() {
        running = true
        fixed = []
        fixMessage = [:]
        progress = "Starting…"
        let snapshot = draft
        let unsaved = secrets.new.filter { !$0.value.isEmpty }
        Task {
            findings = await model.checkProject(snapshot, unsaved: unsaved) { text in
                Task { @MainActor in progress = text }
            }
            running = false
        }
    }

    @MainActor
    private func apply(_ fix: DoctorFinding.Fix, to finding: DoctorFinding) {
        switch fix {
        case .addPreBuildCommand(let command):
            let current = draft.preBuildCommands.trimmingCharacters(in: .newlines)
            draft.preBuildCommands = current.isEmpty ? command : current + "\n" + command
            fixed.insert(finding.id)
            fixMessage[finding.id] = "Added to Prepare → Pre-build commands."
        case .setDartDefinesFile(let path):
            draft.dartDefineFile = path
            fixed.insert(finding.id)
            fixMessage[finding.id] = "Dart defines file set to \(path)."
        case .addToPATH, .setEnvironment:
            model.applyGlobalFix(fix)
            fixed.insert(finding.id)
            fixMessage[finding.id] = "Saved in Settings for every build."
        case .addWorkflow:
            let snapshot = draft
            let token = secrets.new[.githubToken]
            fixMessage[finding.id] = "Adding the workflow…"
            Task {
                do {
                    let outcome = try await model.installWorkflow(snapshot, token: token)
                    fixed.insert(finding.id)
                    fixMessage[finding.id] = outcome.message
                } catch {
                    fixMessage[finding.id] = describe(error)
                }
            }
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            fixMessage[finding.id] = "Copied. This one needs a change in the repository — commit it, then check again."
        case .open(let url, let then):
            NSWorkspace.shared.open(url)
            if let then { onEdit(step(for: then)) }
        case .edit(let place):
            onEdit(step(for: place))
        }
    }
}

// MARK: - Shared fields

struct SecretField: View {
    let title: String
    let key: SecretKey
    @Binding var store: SecretStore
    var help: String?

    private var isStored: Bool { store.stored.contains(key) && !store.removed.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(title, text: Binding(
                    get: { store.new[key] ?? "" },
                    set: { value in
                        store.new[key] = value
                        if !value.isEmpty { store.removed.remove(key) }
                    }
                ), prompt: Text(isStored ? "•••••• saved in Keychain" : "not set"))
                if isStored {
                    Button("Clear") {
                        store.removed.insert(key)
                        store.new[key] = ""
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PathField: View {
    let title: String
    @Binding var path: String
    var directory = false
    var prompt: String?

    var body: some View {
        HStack {
            TextField(title, text: $path, prompt: prompt.map { Text($0) })
            Button("Choose…") { choose() }
        }
    }

    @MainActor
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.canCreateDirectories = directory
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if !path.trimmed.isEmpty {
            let current = expandPath(path)
            panel.directoryURL = directory ? current : current.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = abbreviatePath(url)
        }
    }
}

struct ComboField: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    let suggestions: [String]

    var body: some View {
        HStack {
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { text = suggestion }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Suggestions")
            }
        }
    }
}

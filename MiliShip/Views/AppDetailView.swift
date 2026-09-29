import AppKit
import SwiftUI

struct AppDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case tags = "Tags"
        case deployments = "Deployments"
        case configuration = "Configuration"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @State private var tab: Tab = .tags
    @State private var search = ""
    @State private var keychainError: String?
    let app: AppConfig

    init(app: AppConfig) {
        self.app = app
    }

    private var refresh: AppModel.RefreshState { model.refreshState(for: app.id) }
    private var tags: [TagEntry] { model.tags(for: app.id) }
    private var deployments: [BuildRecord] { model.builds(for: app.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                stats
                warnings
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(title(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            switch tab {
            case .tags: tagsTab
            case .deployments: deploymentsTab
            case .configuration: configurationTab
            }
        }
        .navigationTitle(app.displayName)
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .tags: return tags.isEmpty ? "Tags" : "Tags (\(tags.count))"
        case .deployments: return deployments.isEmpty ? "Deployments" : "Deployments (\(deployments.count))"
        case .configuration: return "Configuration"
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AppGlyph(app: app, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName).font(.title2.bold())
                HStack(spacing: 6) {
                    if let url = repositoryWebURL(app.repoURL) {
                        Link(destination: url) {
                            Text(app.repoURL).font(.system(.callout, design: .monospaced))
                        }
                        .help("Open repository in the browser")
                    } else {
                        Text(app.repoURL).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if app.appPath != "." {
                        Text("· \(app.appPath)").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()

            if app.githubActions.enabled { actionsMenu }

            Toggle(isOn: Binding(get: { app.watchTags }, set: { model.setWatching(app.id, $0) })) {
                Text("Watch")
            }
            .toggleStyle(.switch)
            .help(app.deploysThroughActions
                  ? "Check GitHub every \(app.pollMinutes) min for new tags (GitHub Actions deploys them)"
                  : app.autoBuild
                  ? "Check GitHub every \(app.pollMinutes) min and deploy new tags"
                  : "Check GitHub every \(app.pollMinutes) min (auto-deploy is off)")

            Button {
                Task { await model.refreshTags(for: app.id) }
            } label: {
                if refresh.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Fetch tags from GitHub (⌘R)")
            .disabled(refresh.isRefreshing)

            Menu {
                Button("Show Clone in Finder") { model.revealWorkspace(app.id) }
                Button("Check Project…") { model.beginCheck(app.id) }
                Divider()
                Button("Open in Terminal") { model.openInTerminal(app.id) }
                if let url = repositoryWebURL(app.repoURL) {
                    Button("Open Repository in Browser") { NSWorkspace.shared.open(url) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More")

            Button { model.beginEdit(app.id) } label: {
                Label("Configure", systemImage: "slider.horizontal.3")
            }
            .help("Edit the configuration (⌘E)")

            if let latest = model.latestReleaseTag(for: app.id) {
                Button { model.deployLatest(app.id) } label: {
                    Label("Deploy \(latest.suffix)", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy(appID: app.id, tagName: latest.name) || app.enabledPlatforms.isEmpty)
                .help("Deploy \(latest.name) to \(app.enabledPlatforms.map(\.storeTitle).joined(separator: " and ")) (⌘D)")
            }
        }
    }

    private var actionsMenu: some View {
        let state = model.runnerState(for: app.id)
        return Menu {
            if app.githubActions.isConnected {
                Text("Runner \(app.githubActions.runnerName)")
                if let repo = app.githubRepo {
                    Button("Open Runs in GitHub") { NSWorkspace.shared.open(repo.actionsURL) }
                    Button("Open Runner Settings in GitHub") {
                        NSWorkspace.shared.open(repo.webURL.appendingPathComponent("settings/actions/runners"))
                    }
                }
                Button("Restart Runner") { model.restartRunner(app.id) }
                Button("Show Runner Log") {
                    let log = AppPaths.runnerDirectory(for: app.id).appendingPathComponent("_diag/miliship-runner.log")
                    NSWorkspace.shared.activateFileViewerSelecting([log])
                }
                Divider()
            }
            Button("GitHub Actions Settings…") { model.beginEdit(app.id, step: .github) }
        } label: {
            if app.githubActions.isConnected {
                RunnerStatusLabel(state: state)
            } else {
                Label("Actions not connected", systemImage: "exclamationmark.triangle")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .help("GitHub Actions runner")
    }

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 10) {
            let last = deployments.first
            StatCard(
                title: "Latest tag",
                value: tags.first?.tag.name ?? "—",
                detail: tags.first?.date.map { $0.formatted(.relative(presentation: .named)) }
                    ?? (refresh.lastRefresh == nil ? "not fetched yet" : "no matching tags"),
                symbol: "tag",
                action: { tab = .tags }
            )
            StatCard(
                title: "Last deployment",
                value: last.map { "\($0.tagName)" } ?? "—",
                detail: last.map { "\($0.status.title) · \($0.queuedAt.formatted(.relative(presentation: .named)))" },
                symbol: last?.status.symbol ?? "clock",
                tint: last?.status.color ?? .secondary,
                action: last == nil ? nil : { openLastDeployment() }
            )
            StatCard(
                title: "Android",
                value: app.android.enabled ? (app.android.upload ? "Play · \(app.android.track)" : "Build only") : "Off",
                detail: app.android.enabled ? app.android.packageName : nil,
                symbol: "play.rectangle",
                tint: app.android.enabled ? .green : .secondary,
                action: { model.beginEdit(app.id, step: .googlePlay) }
            )
            StatCard(
                title: "iOS",
                value: app.ios.enabled ? (app.ios.upload ? "TestFlight" : "Build only") : "Off",
                detail: app.ios.enabled ? app.ios.bundleID : nil,
                symbol: "applelogo",
                tint: app.ios.enabled ? .blue : .secondary,
                action: { model.beginEdit(app.id, step: .appStore) }
            )
        }
    }

    private func openLastDeployment() {
        if let record = deployments.first { model.selection = .build(record.id) }
    }

    // MARK: Warnings

    @ViewBuilder
    private var warnings: some View {
        let problems = model.warnings(for: app)
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(problems, id: \.self) { problem in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(problem).font(.callout)
                        Spacer()
                        if problem.hasPrefix("Keychain:") {
                            Button("Allow Access…") { keychainError = model.repairKeychain(for: app.id) }
                                .buttonStyle(.link)
                                .help("macOS asks once; choose Always Allow. Mili Ship then saves the secrets again itself.")
                        } else {
                            Button("Fix…") { model.beginEdit(app.id, step: model.wizardStep(for: problem)) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        if let keychainError {
            Banner(symbol: "key.slash", color: .red, text: keychainError, actionTitle: "Configure") {
                model.beginEdit(app.id)
            }
        }
        if let error = refresh.error {
            Banner(symbol: "wifi.exclamationmark", color: .red, text: error, actionTitle: "Retry") {
                Task { await model.refreshTags(for: app.id) }
            }
        }
    }

    // MARK: Tags

    private var filteredTags: [TagEntry] {
        let query = search.trimmed.lowercased()
        guard !query.isEmpty else { return tags }
        return tags.filter { $0.tag.name.lowercased().contains(query) || $0.commit.lowercased().hasPrefix(query) }
    }

    @ViewBuilder
    private var tagsTab: some View {
        if tags.isEmpty {
            EmptyState(
                symbol: refresh.isRefreshing ? "arrow.triangle.2.circlepath" : "tag",
                title: refresh.isRefreshing ? "Fetching tags…" : "No release tags yet",
                message: "Tags starting with \(app.releaseTagPrefix)\(app.supportsPatches ? " or \(app.patchTagPrefix)" : "") show up here. Create one to deploy:"
            ) {
                let command = "git tag \(app.releaseTagPrefix)1.0.0+1 && git push origin \(app.releaseTagPrefix)1.0.0+1"
                HStack {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    CopyButton(text: command)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter tags or commits", text: $search)
                        .textFieldStyle(.plain)
                    if let date = refresh.lastRefresh {
                        Text("Updated \(date.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider()
                tagTable
            }
        }
    }

    private var tagTable: some View {
        Table(filteredTags) {
            TableColumn("Tag") { entry in
                HStack(spacing: 6) {
                    ModeBadge(mode: entry.tag.mode)
                    Text(entry.tag.name).font(.system(.body, design: .monospaced))
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Version") { entry in
                Text(entry.tag.version?.pretty ?? entry.tag.suffix)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(entry.tag.version == nil ? Color.secondary : Color.primary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Commit") { entry in
                HStack(spacing: 4) {
                    Text(entry.commit).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    CopyButton(text: entry.commit)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("Created") { entry in
                Text(entry.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn("Last deployment") { entry in
                if let record = model.latestBuild(appID: app.id, tagName: entry.tag.name) {
                    Button { model.selection = .build(record.id) } label: {
                        StatusPill(status: record.status)
                    }
                    .buttonStyle(.plain)
                    .help("Open deployment")
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn("") { entry in
                DeployMenu(model: model, app: app, tag: entry.tag)
            }
            .width(110)
        }
    }

    // MARK: Deployments

    @ViewBuilder
    private var deploymentsTab: some View {
        if deployments.isEmpty {
            EmptyState(
                symbol: "shippingbox",
                title: "No deployments yet",
                message: "Deploy a tag from the Tags tab, or turn on Watch to deploy new tags automatically."
            )
        } else {
            List(deployments) { record in
                Button { model.selection = .build(record.id) } label: {
                    HStack(spacing: 12) {
                        StatusIcon(status: record.status)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                ModeBadge(mode: record.mode)
                                Text(record.tagName).font(.system(.body, design: .monospaced))
                                if let version = record.version {
                                    Text(version).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(record.results.first ?? record.failureReason?.split(separator: "\n").first.map { String($0) } ?? record.status.title)
                                .font(.caption)
                                .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(record.queuedAt.formatted(date: .abbreviated, time: .shortened))
                            if let start = record.startedAt, let end = record.finishedAt {
                                Text(formatDuration(end.timeIntervalSince(start))).monospacedDigit()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
    }

    // MARK: Configuration

    private var configurationTab: some View {
        Form {
            AppSummarySections(app: app) { step in
                model.beginEdit(app.id, step: step)
            }
        }
        .formStyle(.grouped)
    }
}

/// Takes the model explicitly: Table cells can be created without the environment objects of the view
/// that owns the table (e.g. while scrolling), which crashes @EnvironmentObject lookups.
struct DeployMenu: View {
    @ObservedObject var model: AppModel
    let app: AppConfig
    let tag: ReleaseTag

    var body: some View {
        let platforms = app.enabledPlatforms
        Menu(tag.mode == .release ? "Deploy" : "Patch") {
            if platforms.count > 1 {
                Button("Android + iOS") { model.deploy(appID: app.id, tag: tag, platforms: platforms) }
                Divider()
            }
            ForEach(platforms) { platform in
                Button(platforms.count > 1 ? "\(platform.title) only" : platform.title) {
                    model.deploy(appID: app.id, tag: tag, platforms: [platform])
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(platforms.isEmpty || model.isBusy(appID: app.id, tagName: tag.name))
    }
}

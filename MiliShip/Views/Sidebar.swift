import AppKit
import SwiftUI

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingRemoval: AppConfig?

    var body: some View {
        List(selection: $model.selection) {
            Section("Applications") {
                if model.apps.isEmpty {
                    Button { model.beginAddApp() } label: {
                        Label("Add your first app", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                ForEach(model.apps) { app in
                    AppRow(app: app)
                        .tag(SidebarItem.app(app.id))
                        .contextMenu { contextMenu(for: app) }
                }
            }

            if !model.history.isEmpty {
                Section("Deployments") {
                    ForEach(model.history.prefix(40)) { record in
                        BuildRow(record: record, showApp: true)
                            .tag(SidebarItem.build(record.id))
                            .contextMenu {
                                if record.status.isFinished {
                                    Button("Run Again") { model.retry(record) }
                                } else {
                                    Button("Cancel") { model.cancel(record.id) }
                                }
                                Button("Show Log in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([model.logURL(for: record)])
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Button { model.beginAddApp() } label: {
                        Label("Add Application", systemImage: "plus")
                    }
                    Spacer()
                    if model.history.contains(where: { $0.status.isFinished }) {
                        Button { model.clearFinished() } label: {
                            Image(systemName: "trash")
                        }
                        .help("Clear finished deployments")
                    }
                    Button { openSettingsWindow() } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings (⌘,)")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "application")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { app in
            Button("Remove \(app.displayName)", role: .destructive) { model.removeApp(app.id) }
        } message: { _ in
            Text("Its configuration and Keychain secrets are removed. The local clone and deployment logs stay on disk.")
        }
    }

    @ViewBuilder
    private func contextMenu(for app: AppConfig) -> some View {
        Button("Deploy Latest Tag") { model.deployLatest(app.id) }
            .disabled(model.latestReleaseTag(for: app.id) == nil)
        Button("Check GitHub") { Task { await model.refreshTags(for: app.id) } }
        Divider()
        Button("Configure…") { model.beginEdit(app.id) }
        Button(app.watchTags ? "Stop Watching Tags" : "Watch Tags") { model.setWatching(app.id, !app.watchTags) }
        Divider()
        Button("Show Clone in Finder") { model.revealWorkspace(app.id) }
        Button("Open in Terminal") { model.openInTerminal(app.id) }
        if let url = repositoryWebURL(app.repoURL) {
            Button("Open Repository in Browser") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Remove…", role: .destructive) { pendingRemoval = app }
    }
}

struct AppRow: View {
    @EnvironmentObject private var model: AppModel
    let app: AppConfig

    init(app: AppConfig) {
        self.app = app
    }

    private var isBuilding: Bool { model.activeRecord?.appID == app.id }
    private var queued: Int { model.history.filter { $0.appID == app.id && $0.status == .queued }.count }
    private var last: BuildRecord? { model.lastDeployment(for: app.id) }

    var body: some View {
        HStack(spacing: 10) {
            AppGlyph(app: app)
                .overlay(alignment: .bottomTrailing) {
                    if let last, !isBuilding {
                        Circle()
                            .fill(last.status.color)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isBuilding {
                ProgressView().controlSize(.small)
            } else if queued > 0 {
                Text("\(queued)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
                    .help("\(queued) queued")
            }
            if app.watchTags {
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Watching GitHub every \(app.pollMinutes) min")
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if isBuilding, let step = model.activeRecord?.steps.last?.name { return step }
        let platforms = app.enabledPlatforms.map(\.title).joined(separator: " + ")
        return [app.buildToolTitle, platforms].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

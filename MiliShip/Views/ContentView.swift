import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            detail
        }
        .sheet(item: $model.wizard) { request in
            AppWizardView(request: request)
                .environmentObject(model)
        }
        .toolbar {
            if let activity = model.activity {
                ToolbarItem(placement: .status) {
                    ActivityChip(kind: activity.kind, text: activity.text)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refreshAll() } } label: {
                    Label("Check GitHub", systemImage: "arrow.clockwise")
                }
                .help("Fetch tags for all applications (⇧⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.beginAddApp() } label: {
                    Label("Add Application", systemImage: "plus")
                }
                .help("Add an application (⌘N)")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .welcome {
        case .app(let id):
            if let app = model.app(id) {
                AppDetailView(app: app).id(app.id)
            } else {
                WelcomeView()
            }
        case .build(let id):
            if let record = model.history.first(where: { $0.id == id }) {
                BuildDetailView(record: record).id(record.id)
            } else {
                WelcomeView()
            }
        case .welcome:
            WelcomeView()
        }
    }
}

/// Compact toolbar status: a coloured indicator and a short label, only shown while something happens.
private struct ActivityChip: View {
    let kind: AppModel.ActivityKind
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .building, .checking:
                ProgressView().controlSize(.mini)
            case .queued:
                Image(systemName: "clock").foregroundStyle(.orange)
            case .watching:
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(kind == .watching ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .fixedSize()
        .help(text)
    }
}

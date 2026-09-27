import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep watching repositories from the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MiliShipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mili Ship", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.liveLog)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Application…") { model.beginAddApp() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Deploy") {
                Button("Deploy Latest Tag") {
                    if let id = model.selectedAppID { model.deployLatest(id) }
                }
                .keyboardShortcut("d")
                .disabled(model.selectedAppID.flatMap { model.latestReleaseTag(for: $0) } == nil)

                Button("Configure Application…") {
                    if let id = model.selectedAppID { model.beginEdit(id) }
                }
                .keyboardShortcut("e")
                .disabled(model.selectedAppID == nil)

                Divider()

                Button("Check GitHub for This App") {
                    if let id = model.selectedAppID { Task { await model.refreshTags(for: id) } }
                }
                .keyboardShortcut("r")
                .disabled(model.selectedAppID == nil)

                Button("Check GitHub for All Apps") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Cancel Running Deployment") {
                    if let id = model.activeBuildID { model.cancel(id) }
                }
                .keyboardShortcut(".")
                .disabled(model.activeBuildID == nil)

                Button("Clear Finished Deployments") { model.clearFinished() }
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(model)
                .frame(width: 640, height: 620)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)
        if let record = model.activeRecord {
            Button("Cancel \(record.appName) \(record.tagName)") { model.cancel(record.id) }
        }
        Divider()

        ForEach(model.apps) { app in
            Menu(menuTitle(for: app)) {
                if let tag = model.latestReleaseTag(for: app.id) {
                    Button("Deploy \(tag.name)") { model.deployLatest(app.id) }
                        .disabled(model.isBusy(appID: app.id, tagName: tag.name))
                } else {
                    Text("No release tags")
                }
                Button("Check GitHub") { Task { await model.refreshTags(for: app.id) } }
                Button(app.watchTags ? "Stop Watching" : "Watch Tags") { model.setWatching(app.id, !app.watchTags) }
                Divider()
                Button("Open in Mili Ship") { show(.app(app.id)) }
            }
        }
        if !model.apps.isEmpty { Divider() }

        Button("Check GitHub for All Apps") { Task { await model.refreshAll() } }
        Button("Open Mili Ship") { show(nil) }
        Button("Settings…") { openSettingsWindow() }
        Divider()
        Button("Quit Mili Ship") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func menuTitle(for app: AppConfig) -> String {
        guard let last = model.lastDeployment(for: app.id) else { return app.displayName }
        let mark: String
        switch last.status {
        case .succeeded: mark = "✓"
        case .failed: mark = "✗"
        case .running: mark = "⋯"
        case .queued: mark = "◷"
        default: mark = "–"
        }
        return "\(mark)  \(app.displayName)"
    }

    private func show(_ item: SidebarItem?) {
        if let item { model.selection = item }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

func openSettingsWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if #available(macOS 14, *) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

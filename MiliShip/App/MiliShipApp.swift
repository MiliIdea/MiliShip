import AppKit
import SwiftUI

/// Read by the app delegate, which can't reach the model; kept in sync with `GlobalSettings.runInBackground`.
@MainActor
enum BackgroundMode {
    static var enabled = true
    /// Set while a deployment runs or waits, so Quit can warn before stopping it.
    static var busyDescription: (() -> String?)?
    /// Stops the GitHub Actions runners so they sign off from GitHub.
    static var willTerminate: (() -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false
    private var observers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opened by "Open at login": start quietly in the menu bar.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, Self.isMainWindow(window) else { return }
            MainActor.assumeIsolated { Self.showInDock() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, Self.isMainWindow(window) else { return }
            // The closing window still counts as visible here; check once it's gone.
            DispatchQueue.main.async { MainActor.assumeIsolated { Self.hideFromDockIfNoWindows() } }
        })

        if launchedAtLogin && BackgroundMode.enabled {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                for window in NSApp.windows where Self.isMainWindow(window) { window.close() }
            }
        } else {
            Self.showInDock()
        }
    }

    /// Keep watching repositories from the menu bar after the window is closed (unless turned off in Settings).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !BackgroundMode.enabled }
    }

    /// Clicking the app in Finder / Launchpad while it runs in the background brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Self.showInDock() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { BackgroundMode.willTerminate?() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let busy = BackgroundMode.busyDescription?() else { return .terminateNow }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit Mili Ship?"
            alert.informativeText = "\(busy) Quitting stops it, and new tags aren't watched until you open Mili Ship again."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    /// The main app window; the menu bar extra, Settings and alerts don't count.
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    @MainActor
    private static func showInDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private static func hideFromDockIfNoWindows() {
        guard BackgroundMode.enabled else { return }
        let stillOpen = NSApp.windows.contains { $0.isVisible && ($0.styleMask.contains(.titled)) && !($0 is NSPanel) }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
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

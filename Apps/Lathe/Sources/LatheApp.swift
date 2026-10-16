import AppKit
import LatheLocalization
import SwiftUI

@main
struct LatheApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @StateObject private var model = LatheAppModel()
    @StateObject private var languages = AppLanguageSettings()

    var body: some Scene {
        WindowGroup("Lathe", id: "workspace") {
            LatheWorkspaceScene(model: model, lifecycle: lifecycle, languages: languages)
                .environmentObject(languages)
                .environment(\.locale, languages.interfaceLocale)
                .frame(minWidth: 820, minHeight: 580)
        }
        .defaultSize(width: 1180, height: 790)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("app.menu.about", table: "AppMessages")) { NSApp.orderFrontStandardAboutPanel(nil) }
            }
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(L10n.text("app.menu.settings", table: "AppMessages")) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button(L10n.text("app.menu.quit", table: "AppMessages")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("action.newSession")) { model.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.acceptsUserActions || !model.isConnected || model.isCreatingSession)
                Button(L10n.text("action.chooseProject")) { model.chooseProject() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!model.acceptsUserActions || !model.isConnected || model.isCreatingSession)
            }
            CommandMenu(L10n.text("engine.title")) {
                Button(L10n.text("action.reconnect")) { Task { await model.connect() } }
                    .disabled(!model.acceptsUserActions || model.isConnecting)
                Button(L10n.text("action.stopCurrentRun")) { model.stopRun() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.acceptsUserActions || model.selectedSession?.activeRun == nil || !model.isConnected)
            }
        }
        Settings {
            EngineSettingsView(model: model, languages: languages)
                .environment(\.locale, languages.interfaceLocale)
        }
    }
}

private struct LatheWorkspaceScene: View {
    @ObservedObject var model: LatheAppModel
    let lifecycle: AppLifecycleDelegate
    @ObservedObject var languages: AppLanguageSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WorkspaceView(model: model)
            .background(WorkspaceWindowRegistration(lifecycle: lifecycle).frame(width: 0, height: 0))
            .onAppear { lifecycle.configure(model: model, languages: languages) { openWindow(id: "workspace") } }
            .task { await model.ensureConnected() }
    }
}

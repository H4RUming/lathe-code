import AppKit
import LatheLocalization
import SwiftUI

@main
struct LatheApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @StateObject private var model = LatheAppModel()

    var body: some Scene {
        WindowGroup("Lathe", id: "workspace") {
            LatheWorkspaceScene(model: model, lifecycle: lifecycle)
                .frame(minWidth: 820, minHeight: 580)
        }
        .defaultSize(width: 1180, height: 790)
        .commands {
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
            EngineSettingsView(model: model)
        }
    }
}

private struct LatheWorkspaceScene: View {
    @ObservedObject var model: LatheAppModel
    let lifecycle: AppLifecycleDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WorkspaceView(model: model)
            .background(WorkspaceWindowRegistration(lifecycle: lifecycle).frame(width: 0, height: 0))
            .onAppear { lifecycle.configure(model: model) { openWindow(id: "workspace") } }
            .task { await model.ensureConnected() }
    }
}

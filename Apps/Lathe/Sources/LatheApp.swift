import AppKit
import SwiftUI

@main
struct LatheApp: App {
    @StateObject private var model = LatheAppModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .frame(minWidth: 820, minHeight: 580)
                .task { await model.ensureConnected() }
        }
        .defaultSize(width: 1180, height: 790)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 세션") { model.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.isConnected || model.isCreatingSession)
                Button("프로젝트 열기…") { model.chooseProject() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!model.isConnected || model.isCreatingSession)
            }
            CommandMenu("엔진") {
                Button("다시 연결") { Task { await model.connect() } }
                    .disabled(model.isConnecting)
                Button("현재 실행 중단") { model.stopRun() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.selectedSession?.activeRun == nil || !model.isConnected)
            }
        }
        Settings {
            EngineSettingsView(model: model)
        }
    }
}

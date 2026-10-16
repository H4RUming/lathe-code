import AppKit
import LatheLocalization
import LatheDomain
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    @ObservedObject var model: LatheAppModel

    var body: some View {
        let _ = languages.preferences
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedSessionID }, set: { model.selectSession($0) })) {
                    Section(L10n.text("sidebar.sessions.title")) {
                        ForEach(model.sessions) { session in
                            SessionRow(session: session).tag(session.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if model.sessions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.title2).foregroundStyle(.tertiary)
                            Text(L10n.text("sidebar.sessions.empty")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.isConnected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(model.connectionLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.isConnecting { ProgressView().controlSize(.mini) }
                    else {
                        Button { Task { await model.connect() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).help(L10n.text("engine.reconnect"))
                            .accessibilityLabel(L10n.text("engine.reconnect"))
                            .disabled(!model.acceptsUserActions)
                    }
                }
                .padding(14)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            .toolbar {
                ToolbarItem {
                    Button { model.chooseProject() } label: { Label(L10n.text("action.openProject"), systemImage: "folder.badge.plus") }
                        .disabled(!model.acceptsUserActions || !model.isConnected || model.isCreatingSession)
                }
                ToolbarItem {
                    Button { model.newSession() } label: { Label(L10n.text("action.newSession"), systemImage: "square.and.pencil") }
                        .disabled(!model.acceptsUserActions || !model.isConnected || model.isCreatingSession)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage { ErrorBanner(message: error) { model.errorMessage = nil } }
                if let session = model.selectedSession {
                    ConversationView(model: model, session: session)
                } else if model.selectedSessionID != nil {
                    ProgressView(L10n.text("session.loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WelcomeView(model: model)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(model.selectedSession?.title ?? "Lathe")
        }
    }
}

private struct SessionRow: View {
    let session: SessionSnapshot
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.system(.body, weight: .medium)).lineLimit(1)
                Text(session.workspacePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if session.activeRunID != nil { ProgressView().controlSize(.mini) }
        }.padding(.vertical, 5)
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    @ObservedObject var model: LatheAppModel
    var body: some View {
        let _ = languages.preferences
        VStack(spacing: 22) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text(L10n.text("welcome.title")).font(.system(size: 27, weight: .semibold))
                Text(L10n.text("welcome.description"))
                    .font(.body).foregroundStyle(.secondary)
            }
            Button(L10n.text("action.chooseProject")) { model.chooseProject() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.acceptsUserActions || !model.isConnected || model.isCreatingSession)
            VStack(spacing: 7) {
                Text(L10n.text("welcome.connectProvider"))
                Text(L10n.text("welcome.toolAccess"))
                SettingsLink { Label(L10n.text("settings.openConnections"), systemImage: "gearshape") }
            }.font(.caption).foregroundStyle(.secondary)
            if !model.isConnected {
                Button(L10n.text("engine.reconnect")) { Task { await model.connect() } }.disabled(!model.acceptsUserActions || model.isConnecting)
            }
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversationView: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    @ObservedObject var model: LatheAppModel
    let session: SessionSnapshot
    @State private var followsTail = true

    var body: some View {
        let _ = languages.preferences
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(session.workspacePath, systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                if let profile = session.activeRun?.configuration?.profile ?? model.selectedProfile {
                    Label(profile.name, systemImage: "network").font(.caption).foregroundStyle(.secondary)
                } else { MockBadge() }
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if model.earlierCursor != nil {
                            Button {
                                followsTail = false
                                model.loadEarlierRuns()
                            } label: {
                                HStack {
                                    if model.isLoadingEarlier { ProgressView().controlSize(.small) }
                                    Text(L10n.text("conversation.loadEarlier"))
                                }.frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isLoadingEarlier || !model.isConnected)
                        }
                        if session.runs.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L10n.text("conversation.empty.title")).font(.title2.weight(.semibold))
                                Text(L10n.text("conversation.empty.description"))
                                    .foregroundStyle(.secondary)
                            }.padding(.top, 34)
                        }
                        ForEach(session.runs) { run in RunView(model: model, run: run) }
                        Color.clear.frame(height: 1).id("transcript-bottom")
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(.horizontal, 30).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 100
                } action: { _, nearBottom in followsTail = nearBottom }
                .onChange(of: session.runs.last?.response) {
                    if followsTail { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
                }
                .onChange(of: session.runs.last?.id) {
                    followsTail = true
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
                .onChange(of: session.id, initial: true) {
                    followsTail = true
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
            ComposerView(model: model)
        }
    }
}

private struct RunView: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    @ObservedObject var model: LatheAppModel
    let run: RunSnapshot
    var body: some View {
        let _ = languages.preferences
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.text("conversation.userRole")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(run.prompt).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                    Text("Lathe").font(.caption.weight(.semibold))
                    Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                    if run.state == .running { ProgressView().controlSize(.mini) }
                }
                if run.response.isEmpty {
                    Text(run.state == .running ? L10n.text("run.response.preparing") : L10n.text("run.response.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(run.response).textSelection(.enabled).lineSpacing(5)
                }
            }
            if let profile = run.configuration?.profile {
                Text(L10n.format("run.profile", profile.name, profile.model)).font(.caption2).foregroundStyle(.secondary)
            }
            if let invocations = model.toolInvocations[run.id], !invocations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("run.tools.recent")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(invocations) { invocation in
                        ToolInvocationView(model: model, invocation: invocation, runIsActive: run.state == .running)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateLabel: String {
        switch run.state {
        case .running: L10n.text("run.state.running")
        case .completed: run.configuration?.profile == nil ? L10n.text("run.state.completedMock") : L10n.text("run.state.completed")
        case .cancelled: L10n.text("run.state.cancelled")
        case .interrupted: L10n.text("run.state.interrupted")
        case .failed: L10n.text("run.state.failed")
        }
    }
}

private struct ComposerView: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    @ObservedObject var model: LatheAppModel
    var body: some View {
        let _ = languages.preferences
        VStack(spacing: 10) {
            HStack {
                Picker(L10n.text("composer.model.label"), selection: $model.selectedProfileID) {
                    Text(L10n.text("model.mock.label")).tag(UUID?.none)
                    ForEach(model.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }.frame(maxWidth: 330)
                Picker(L10n.text("composer.permissions.label"), selection: $model.permissionMode) {
                    ForEach(PermissionMode.allCases, id: \.rawValue) { mode in
                        Text(permissionTitle(mode)).tag(mode)
                    }
                }.disabled(model.selectedProfile == nil)
                SettingsLink { Image(systemName: "gearshape") }.help(L10n.text("settings.openConnections"))
            }.disabled(!model.canChangeRunConfiguration)
            if model.selectedProfile != nil {
                Text(permissionDescription).font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $model.draft)
                    .font(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 130)
                    .accessibilityLabel(L10n.text("composer.input.accessibility"))
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text(L10n.text("composer.input.placeholder")).foregroundStyle(.tertiary)
                                .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                        }
                    }
                if model.isDraftOverLimit {
                    Text(L10n.errorFormat("composer.input.tooLong", Int64(LatheAppModel.promptByteLimit / 1_024)))
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text(L10n.text("composer.keyboardHelp")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(L10n.format("composer.byteCount", model.draftByteCount.formatted(), LatheAppModel.promptByteLimit.formatted()))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if model.selectedSession?.activeRun != nil {
                        Button { model.stopRun() } label: { Label(L10n.text("action.stopRun"), systemImage: "stop.fill") }
                            .disabled(!model.isConnected || model.isCancelling)
                    } else {
                        Button { model.sendPrompt() } label: { Label(L10n.text("action.send"), systemImage: "arrow.up") }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                            .disabled(!model.canSubmit)
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 1) }
            if model.selectedProfile == nil {
                Text(L10n.text("model.mock.description"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 820).padding(.horizontal, 30).padding(.bottom, 20).padding(.top, 8)
    }

    private var permissionDescription: String {
        switch model.permissionMode {
        case .fullAccess: L10n.text("permission.fullAccess.description")
        case .autoApprove: L10n.text("permission.autoApprove.description")
        case .acceptEdits: L10n.text("permission.acceptEdits.description")
        case .requestApproval: L10n.text("permission.requestApproval.description")
        }
    }

    private func permissionTitle(_ mode: PermissionMode) -> String {
        switch mode {
        case .fullAccess: L10n.text("permission.fullAccess.title")
        case .autoApprove: L10n.text("permission.autoApprove.title")
        case .acceptEdits: L10n.text("permission.acceptEdits.title")
        case .requestApproval: L10n.text("permission.requestApproval.title")
        }
    }
}

private struct ToolInvocationView: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    @ObservedObject var model: LatheAppModel
    let invocation: ToolInvocationSnapshot
    let runIsActive: Bool

    var body: some View {
        let _ = languages.preferences
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(invocation.name, systemImage: invocation.name == "run_command" ? "terminal" :
                    invocation.name == "fetch_url" ? "globe" : "doc.text")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Text(invocation.summary).font(.caption).textSelection(.enabled)
            if invocation.name == "edit_file" {
                if let preview = FileEditPreview(invocation: invocation) {
                    FileEditPreviewView(preview: preview)
                } else {
                    Text(L10n.errorText("editPreview.unavailable")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if invocation.name == "run_command" {
                Text(L10n.text("tool.command.unsandboxed"))
                    .font(.caption).foregroundStyle(.orange)
            }
            if invocation.state == .pendingApproval {
                Text(L10n.text("tool.approval.arguments")).font(.caption.weight(.medium))
                ScrollView {
                    Text(invocation.arguments).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 180)
                HStack {
                    Spacer()
                    Button(L10n.text("tool.approval.deny")) { model.decideApproval(invocation, approved: false) }
                    Button(L10n.text("tool.approval.allowOnce")) { model.decideApproval(invocation, approved: true) }
                        .buttonStyle(.borderedProminent)
                }.disabled(!model.acceptsUserActions || !model.isConnected || !runIsActive || model.decidingApprovals.contains(invocation.id))
            } else {
                DisclosureGroup(L10n.text("tool.arguments.title")) {
                    Text(invocation.arguments).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let output = invocation.output, !output.isEmpty {
                DisclosureGroup(L10n.text("tool.output.title")) {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var status: String {
        switch invocation.state {
        case .pendingApproval: L10n.text("tool.state.pendingApproval")
        case .approved: L10n.text("tool.state.approved")
        case .executing: L10n.text("tool.state.executing")
        case .completed: L10n.text("tool.state.completed")
        case .denied: L10n.text("tool.state.denied")
        case .failed: L10n.text("tool.state.failed")
        case .cancelled: L10n.text("tool.state.cancelled")
        case .unknown: L10n.text("tool.state.unknown")
        }
    }
}

private struct MockBadge: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    var body: some View {
        let _ = languages.preferences
        Label(L10n.text("model.mock.label"), systemImage: "testtube.2")
            .font(.caption.weight(.medium)).foregroundStyle(.orange)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.orange.opacity(0.09), in: Capsule())
    }
}

private struct ErrorBanner: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    let message: String
    let dismiss: () -> Void
    var body: some View {
        let _ = languages.preferences
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("error.dismiss.accessibility"))
        }.padding(14).background(.orange.opacity(0.08))
    }
}

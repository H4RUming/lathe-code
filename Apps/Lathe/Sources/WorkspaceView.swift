import AppKit
import LatheDomain
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: LatheAppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedSessionID }, set: { model.selectSession($0) })) {
                    Section("세션") {
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
                            Text("아직 세션이 없습니다").font(.callout).foregroundStyle(.secondary)
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
                            .buttonStyle(.plain).help("엔진에 다시 연결")
                            .accessibilityLabel("엔진에 다시 연결")
                    }
                }
                .padding(14)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            .toolbar {
                ToolbarItem {
                    Button { model.chooseProject() } label: { Label("프로젝트 열기", systemImage: "folder.badge.plus") }
                        .disabled(!model.isConnected || model.isCreatingSession)
                }
                ToolbarItem {
                    Button { model.newSession() } label: { Label("새 세션", systemImage: "square.and.pencil") }
                        .disabled(!model.isConnected || model.isCreatingSession)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage { ErrorBanner(message: error) { model.errorMessage = nil } }
                if let session = model.selectedSession {
                    ConversationView(model: model, session: session)
                } else if model.selectedSessionID != nil {
                    ProgressView("세션을 읽는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @ObservedObject var model: LatheAppModel
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text("작업을 시작할 공간").font(.system(size: 27, weight: .semibold))
                Text("프로젝트를 열고 공유 엔진과 대화해 보세요.")
                    .font(.body).foregroundStyle(.secondary)
            }
            Button("프로젝트 열기…") { model.chooseProject() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.isConnected || model.isCreatingSession)
            VStack(spacing: 7) {
                MockBadge()
                Text("현재는 세션 저장·스트리밍·중단을 확인하는 모의 모델입니다.")
                Text("프로젝트 파일을 읽거나 수정하지 않으며 외부 API를 호출하지 않습니다.")
            }.font(.caption).foregroundStyle(.secondary)
            if !model.isConnected {
                Button("엔진에 다시 연결") { Task { await model.connect() } }.disabled(model.isConnecting)
            }
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversationView: View {
    @ObservedObject var model: LatheAppModel
    let session: SessionSnapshot
    @State private var followsTail = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(session.workspacePath, systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                MockBadge()
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
                                    Text("이전 대화 불러오기")
                                }.frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isLoadingEarlier || !model.isConnected)
                        }
                        if session.runs.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("첫 메시지를 보내 보세요").font(.title2.weight(.semibold))
                                Text("응답은 모의 데이터입니다. 이 세션은 GUI와 CLI에서 이어서 열 수 있습니다.")
                                    .foregroundStyle(.secondary)
                            }.padding(.top, 34)
                        }
                        ForEach(session.runs) { run in RunView(run: run) }
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
    let run: RunSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("나").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                    Text(run.state == .running ? "모의 응답을 준비하고 있습니다…" : "응답 내용이 없습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(run.response).textSelection(.enabled).lineSpacing(5)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateLabel: String {
        switch run.state {
        case .running: "응답 중"
        case .completed: "완료 · 모의 응답"
        case .cancelled: "사용자가 중단함"
        case .interrupted: "엔진 종료로 중단됨"
        }
    }
}

private struct ComposerView: View {
    @ObservedObject var model: LatheAppModel
    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $model.draft)
                    .font(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 130)
                    .accessibilityLabel("메시지 입력")
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text("메시지를 입력하세요…").foregroundStyle(.tertiary)
                                .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                        }
                    }
                if model.isDraftOverLimit {
                    Text("입력은 UTF-8 기준 32KiB 이하여야 합니다. 내용을 줄인 뒤 전송하세요.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("⌘ Return 전송 · Return 줄바꿈").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.draftByteCount.formatted()) / 32,768 bytes")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if model.selectedSession?.activeRun != nil {
                        Button { model.stopRun() } label: { Label("중단", systemImage: "stop.fill") }
                            .disabled(!model.isConnected || model.isCancelling)
                    } else {
                        Button { model.sendPrompt() } label: { Label("보내기", systemImage: "arrow.up") }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                            .disabled(!model.canSubmit)
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 1) }
            Text("모의 모델 · 파일 변경이나 외부 API 호출 없이 연결을 시험합니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 820).padding(.horizontal, 30).padding(.bottom, 20).padding(.top, 8)
    }
}

private struct MockBadge: View {
    var body: some View {
        Label("모의 모델 · 연결 시험", systemImage: "testtube.2")
            .font(.caption.weight(.medium)).foregroundStyle(.orange)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.orange.opacity(0.09), in: Capsule())
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("오류 메시지 닫기")
        }.padding(14).background(.orange.opacity(0.08))
    }
}

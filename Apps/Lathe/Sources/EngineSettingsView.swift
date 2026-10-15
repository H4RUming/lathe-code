import AppKit
import LatheDomain
import SwiftUI

struct EngineSettingsView: View {
    @ObservedObject var model: LatheAppModel
    @State private var editingID: UUID?
    @State private var newProfileID = UUID()
    @State private var name = ""
    @State private var api: ProviderAPI = .openAIResponses
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var modelName = ""
    @State private var reasoningEffort = ""
    @State private var allowInsecureHTTP = false
    @State private var apiKey = ""
    @State private var clearCredential = false
    @State private var savedMessage: String?

    var body: some View {
        TabView {
            connectionForm.tabItem { Label("모델 연결", systemImage: "network") }
            engineForm.tabItem { Label("엔진과 데이터", systemImage: "externaldrive") }
        }
        .padding(14).frame(width: 660, height: 680)
        .task { await model.ensureConnected() }
    }

    private var connectionForm: some View {
        Form {
            Section("연결 설정") {
                Picker("저장된 연결", selection: $editingID) {
                    Text("새 연결").tag(UUID?.none)
                    ForEach(model.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }.onChange(of: editingID) { loadSelection() }
                TextField("이름", text: $name)
                Picker("API 형식", selection: $api) {
                    Text("OpenAI Responses").tag(ProviderAPI.openAIResponses)
                    Text("OpenAI 호환 Chat Completions").tag(ProviderAPI.openAIChat)
                }
                TextField("Base URL", text: $baseURL).textContentType(.URL)
                TextField("모델 ID", text: $modelName)
                TextField("Reasoning effort (선택)", text: $reasoningEffort)
                Text("추론 옵션은 서버가 지원하는 값을 그대로 보냅니다. 로컬 Off/On/Ultra는 아직 제공하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("이 연결의 암호화되지 않은 HTTP 허용", isOn: $allowInsecureHTTP)
                if allowInsecureHTTP {
                    Text("HTTP에서는 API 키와 대화가 네트워크에 암호화되지 않고 전송됩니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("인증") {
                SecureField("새 API 키 (빈 값은 기존 키 유지)", text: $apiKey).disabled(clearCredential)
                Toggle("저장된 API 키 삭제", isOn: $clearCredential).disabled(!apiKey.isEmpty)
                Text("키는 macOS Keychain에 저장합니다. 저장된 키는 앱에 표시하지 않습니다. 인증이 없는 개인 서버는 키 없이 연결할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    if let savedMessage { Text(savedMessage).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("새 연결") { editingID = nil; newProfileID = UUID(); loadSelection() }
                    Button("저장") { save() }.buttonStyle(.borderedProminent)
                        .disabled(!model.isConnected || model.isSavingProfile || name.isEmpty || modelName.isEmpty)
                }
                if model.isSavingProfile { ProgressView("연결을 저장하는 중…") }
                Text("vLLM·Ollama·개인 서버는 OpenAI 호환 API 주소를 사용하세요. 모델 서버 주소와 로컬 코드 실행 위치는 별개입니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("현재 Google AI Studio·Vertex·Claude 전용 API 어댑터는 지원하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }

    private var engineForm: some View {
        Form {
            Section("엔진") {
                LabeledContent("상태", value: model.connectionLabel)
                if let info = model.engineInfo {
                    LabeledContent("프로세스", value: String(info.processID))
                    LabeledContent("프로토콜", value: String(info.protocolVersion))
                }
                Button("엔진에 다시 연결") { Task { await model.connect() } }.disabled(model.isConnecting)
            }
            Section("로컬 데이터") {
                if let directory = model.dataDirectory {
                    Text(directory.path).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Finder에서 보기") { NSWorkspace.shared.open(directory) }
                }
                Text("세션·도구 승인·실행 결과는 로컬에 보관됩니다. 창이나 앱을 닫아도 별도 엔진의 실행은 계속됩니다. 중단 버튼으로 실행을 취소하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func loadSelection() {
        let profile = model.profiles.first { $0.id == editingID }
        name = profile?.name ?? ""
        api = profile?.api ?? .openAIResponses
        baseURL = profile?.baseURL ?? "https://api.openai.com/v1"
        modelName = profile?.model ?? ""
        reasoningEffort = profile?.reasoningEffort ?? ""
        allowInsecureHTTP = profile?.allowInsecureHTTP ?? false
        apiKey = ""
        clearCredential = false
        savedMessage = nil
    }

    private func save() {
        let effort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ProviderProfile(id: editingID ?? newProfileID, name: name, api: api, baseURL: baseURL,
                                      model: modelName, allowInsecureHTTP: allowInsecureHTTP,
                                      reasoningEffort: effort.isEmpty ? nil : effort)
        let key = apiKey.isEmpty ? nil : apiKey
        let clear = clearCredential
        Task {
            if await model.saveProfile(profile, apiKey: key, clearCredential: clear) {
                editingID = profile.id
                apiKey = ""
                clearCredential = false
                savedMessage = "저장됨 · 다음 실행부터 적용"
            }
        }
    }
}

import AppKit
import LatheLocalization
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
            connectionForm.tabItem { Label(L10n.text("settings.tab.connections"), systemImage: "network") }
            engineForm.tabItem { Label(L10n.text("settings.tab.engine"), systemImage: "externaldrive") }
        }
        .padding(14).frame(width: 660, height: 680)
        .task { await model.ensureConnected() }
    }

    private var connectionForm: some View {
        Form {
            Section(L10n.text("settings.connection.section")) {
                Picker(L10n.text("settings.connection.saved"), selection: $editingID) {
                    Text(L10n.text("settings.connection.new")).tag(UUID?.none)
                    ForEach(model.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }.onChange(of: editingID) { loadSelection() }
                TextField(L10n.text("settings.connection.name"), text: $name)
                Picker(L10n.text("settings.connection.api"), selection: $api) {
                    Text(L10n.text("settings.api.responses")).tag(ProviderAPI.openAIResponses)
                    Text(L10n.text("settings.api.chat")).tag(ProviderAPI.openAIChat)
                }
                TextField(L10n.text("settings.connection.baseURL"), text: $baseURL).textContentType(.URL)
                TextField(L10n.text("settings.connection.model"), text: $modelName)
                TextField(L10n.text("settings.connection.reasoningEffort"), text: $reasoningEffort)
                Text(L10n.text("settings.connection.reasoningHelp"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("settings.connection.allowHTTP"), isOn: $allowInsecureHTTP)
                if allowInsecureHTTP {
                    Text(L10n.text("settings.connection.httpWarning"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section(L10n.text("settings.credentials.section")) {
                SecureField(L10n.text("settings.credentials.newKey"), text: $apiKey).disabled(clearCredential)
                Toggle(L10n.text("settings.credentials.deleteKey"), isOn: $clearCredential).disabled(!apiKey.isEmpty)
                Text(L10n.text("settings.credentials.help"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    if let savedMessage { Text(savedMessage).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(L10n.text("settings.connection.new")) { editingID = nil; newProfileID = UUID(); loadSelection() }
                    Button(L10n.text("action.save")) { save() }.buttonStyle(.borderedProminent)
                        .disabled(!model.acceptsUserActions || !model.isConnected || model.isSavingProfile || name.isEmpty || modelName.isEmpty)
                }
                if model.isSavingProfile { ProgressView(L10n.text("settings.connection.saving")) }
                Text(L10n.text("settings.connection.compatibleHelp"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("settings.connection.unsupportedProviders"))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }

    private var engineForm: some View {
        Form {
            Section(L10n.text("engine.title")) {
                LabeledContent(L10n.text("settings.engine.status"), value: model.connectionLabel)
                if let info = model.engineInfo {
                    LabeledContent(L10n.text("settings.engine.process"), value: String(info.processID))
                    LabeledContent(L10n.text("settings.engine.protocol"), value: String(info.protocolVersion))
                }
                Button(L10n.text("engine.reconnect")) { Task { await model.connect() } }.disabled(!model.acceptsUserActions || model.isConnecting)
            }
            Section(L10n.text("settings.data.section")) {
                if let directory = model.dataDirectory {
                    Text(directory.path).font(.caption.monospaced()).textSelection(.enabled)
                    Button(L10n.text("settings.data.showInFinder")) { NSWorkspace.shared.open(directory) }
                }
                Text(L10n.text("settings.data.lifecycleHelp"))
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
                savedMessage = L10n.text("settings.connection.savedMessage")
            }
        }
    }
}

import AppKit
import SwiftUI

struct EngineSettingsView: View {
    @ObservedObject var model: LatheAppModel
    var body: some View {
        Form {
            Section("연결 시험") {
                LabeledContent("모델", value: "모의 모델")
                LabeledContent("엔진", value: model.connectionLabel)
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
                } else {
                    Text("엔진 연결 후 데이터 위치를 확인할 수 있습니다.").foregroundStyle(.secondary)
                }
                Text("세션과 실행 기록은 로컬에 보관됩니다. 창을 닫거나 앱을 종료해도 별도 엔진의 실행은 계속됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("M0 실행 기반 · 실제 모델 연결과 파일 도구는 아직 제공하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(10).frame(width: 480, height: 400)
    }
}

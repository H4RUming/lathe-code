import LatheLocalization
import SwiftUI

struct FileEditPreviewView: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    let preview: FileEditPreview
    @State private var showWhitespace = true

    var body: some View {
        let _ = languages.preferences
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.text("editPreview.title"), systemImage: "doc.badge.gearshape")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(statusLabel).font(.caption).foregroundStyle(statusColor)
            }
            Text(verbatim: preview.path).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
            Text(L10n.text("editPreview.proposalExplanation"))
                .font(.caption).foregroundStyle(.secondary)
            if preview.status == .applied {
                Text(L10n.text("editPreview.appliedExplanation")).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent(L10n.text("editPreview.expectedDigest")) {
                Text(verbatim: preview.expectedSHA256).font(.caption2.monospaced()).lineLimit(1)
                    .truncationMode(.middle).textSelection(.enabled)
            }.font(.caption)
            Toggle(L10n.text("editPreview.whitespace"), isOn: $showWhitespace).toggleStyle(.checkbox).font(.caption)
            HStack(alignment: .top, spacing: 12) {
                FileEditSnippetView(snippet: preview.removal, isRemoval: true, showWhitespace: showWhitespace)
                FileEditSnippetView(snippet: preview.addition, isRemoval: false, showWhitespace: showWhitespace)
            }
            if showWhitespace {
                Text(L10n.text("editPreview.whitespaceLegend")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private var statusLabel: String {
        switch preview.status {
        case .proposal: L10n.text("editPreview.status.proposal")
        case .applying: L10n.text("editPreview.status.applying")
        case .applied: L10n.text("editPreview.status.applied")
        case .notConfirmed: L10n.text("editPreview.status.notConfirmed")
        case .unknown: L10n.text("editPreview.status.unknown")
        }
    }

    private var statusColor: Color { preview.status == .applied ? .green : .secondary }
}

private struct FileEditSnippetView: View {
    @EnvironmentObject private var languages: AppLanguageSettings
    let snippet: FileEditSnippet
    let isRemoval: Bool
    let showWhitespace: Bool

    var body: some View {
        let _ = languages.preferences
        VStack(alignment: .leading, spacing: 6) {
            Label(isRemoval ? L10n.text("editPreview.removal") : L10n.text("editPreview.addition"),
                  systemImage: isRemoval ? "minus.circle" : "plus.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(isRemoval ? Color.red : Color.green)
            ScrollView([.horizontal, .vertical]) {
                if snippet.isEmpty {
                    Text(L10n.text("editPreview.emptyText")).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else {
                    Text(verbatim: snippet.rendered(showWhitespace: showWhitespace))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 160, alignment: .topLeading)
            .padding(8)
            .background((isRemoval ? Color.red : Color.green).opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            Text(L10n.format("editPreview.byteCount", Int64(snippet.displayedByteCount), Int64(snippet.originalByteCount)))
                .font(.caption2).foregroundStyle(.secondary)
            if snippet.isTruncated {
                Text(L10n.text("editPreview.truncated")).font(.caption2).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

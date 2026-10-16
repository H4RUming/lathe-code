import Foundation
import LatheDomain
@testable import LatheLocalization
import LathePersistence
import LatheProviders
import LatheProtocol
import Testing

struct MixedLanguageErrorTests {
    @Test(arguments: [AppLanguage.ko, .en])
    func actualErrorsAndInterfaceCopyUseIndependentLanguages(appLanguage: AppLanguage) throws {
        let errorLanguage: ErrorLanguage = appLanguage == .ko ? .en : .ko
        let preferences = LocalizationPreferences(appLanguage: appLanguage, errorLanguage: errorLanguage)
        try L10n.$preferencesOverride.withValue(preferences) {
            #expect(L10n.text("action.save") == (appLanguage == .ko ? "저장" : "Save"))
            let errorLocale = Locale(identifier: errorLanguage.rawValue)
            #expect(LatheError.incompatibleVersion(9001).localizedDescription == L10n.errorFormat(
                "domain.protocol.unsupported", table: "DomainErrors", locale: errorLocale, "9001"))
            #expect(ProviderError.httpStatus(429).localizedDescription == (errorLanguage == .en
                ? "The model server returned HTTP 429." : "모델 서버가 HTTP 429를 반환했습니다."))
            #expect(SocketTransportError.disconnected.localizedDescription == L10n.errorText(
                "protocol.socket.disconnected", table: "ProtocolErrors", locale: errorLocale))
            do {
                _ = try BlobStore(root: URL(fileURLWithPath: "/private/tmp/unused"), maxBytes: 0)
                Issue.record("Invalid blob limit was accepted")
            } catch {
                #expect(error.localizedDescription == L10n.errorText("storage.blob.invalidConfiguration", table: "StorageErrors", locale: errorLocale))
            }
            // Localize both the app wrapper and its own nested provider error.
            let rawDetail = "server %@ 100% /모델"
            let nested = ProviderError.invalidStream(rawDetail).localizedDescription
            let rendered = L10n.errorFormat("app.error.connectionFailed", table: "AppMessages", nested)
            #expect(rendered == L10n.errorFormat("app.error.connectionFailed", table: "AppMessages", locale: errorLocale,
                L10n.errorFormat("provider.error.invalidStream", table: "ProviderErrors", locale: errorLocale, rawDetail)))
            #expect(rendered.contains(rawDetail))
        }
    }
}

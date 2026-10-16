import Foundation
@testable import LatheLocalization
import Testing
@testable import LatheAppSupport

@MainActor
struct AppLanguageSettingsTests {
    @Test func choicesPersistIndependentlyAndReloadWithoutAnotherWrite() {
        let store = AppLanguagePreferenceFixture(LocalizationPreferences(appLanguage: .en, errorLanguage: .ko))
        let settings = store.makeSettings()
        #expect(settings.preferences.appLanguage == .en)
        #expect(settings.interfaceLocale.language.languageCode?.identifier == "en")

        settings.setAppLanguage(.ko)
        #expect(store.load() == LocalizationPreferences(appLanguage: .ko, errorLanguage: .ko))
        #expect(settings.interfaceLocale.language.languageCode?.identifier == "ko")
        settings.setErrorLanguage(.en)
        #expect(store.load() == LocalizationPreferences(appLanguage: .ko, errorLanguage: .en))
        #expect(settings.interfaceLocale.language.languageCode?.identifier == "ko")

        let reloaded = store.makeSettings()
        #expect(reloaded.preferences == settings.preferences)
        reloaded.setAppLanguage(.ko)
        reloaded.setErrorLanguage(.en)
        #expect(store.writeCount == 2)
    }

    @Test func backgroundPreferenceNotificationRefreshesTheExistingBridge() async throws {
        let store = AppLanguagePreferenceFixture()
        let notifications = NotificationCenter()
        let settings = store.makeSettings(notifications: notifications)
        let expected = LocalizationPreferences(appLanguage: .en, errorLanguage: .system)
        await Task.detached {
            store.save(expected)
            notifications.post(name: L10n.preferencesDidChange, object: nil)
        }.value
        for _ in 0..<100 where settings.preferences != expected {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(settings.preferences == expected)
        #expect(settings.interfaceLocale.language.languageCode?.identifier == "en")
        #expect(store.writeCount == 1)
    }

    @Test func changingOneChoicePreservesAnExternalChangeToTheOtherChoice() {
        let store = AppLanguagePreferenceFixture()
        let firstWindow = store.makeSettings()
        let secondWindow = store.makeSettings()
        firstWindow.setAppLanguage(.ko)
        // The second view has not received its notification yet.
        #expect(secondWindow.preferences.appLanguage == .system)
        secondWindow.setErrorLanguage(.en)
        #expect(store.load() == LocalizationPreferences(appLanguage: .ko, errorLanguage: .en))
        #expect(secondWindow.preferences == store.load())
    }
}

final class AppLanguagePreferenceFixture: LocalizationPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: LocalizationPreferences
    private var writes = 0

    init(_ preferences: LocalizationPreferences = LocalizationPreferences()) { self.preferences = preferences }
    func load() -> LocalizationPreferences { lock.withLock { preferences } }
    func save(_ preferences: LocalizationPreferences) { lock.withLock { self.preferences = preferences; writes += 1 } }
    var writeCount: Int { lock.withLock { writes } }

    @MainActor
    func makeSettings(notifications: NotificationCenter = NotificationCenter()) -> AppLanguageSettings {
        AppLanguageSettings(readPreferences: { self.load() }, writePreferences: { self.save($0) },
            readLocale: { L10n.$preferencesOverride.withValue(self.load()) { L10n.interfaceLocale } },
            notifications: notifications)
    }
}

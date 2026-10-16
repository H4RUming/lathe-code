import Foundation
@testable import LatheLocalization
import Testing

private final class LocalizationMemoryStore: LocalizationPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value = LocalizationPreferences()
    func load() -> LocalizationPreferences { lock.withLock { value } }
    func save(_ preferences: LocalizationPreferences) { lock.withLock { value = preferences } }
}

private final class PreferenceFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    func record() { lock.withLock { failures += 1 } }
    var count: Int { lock.withLock { failures } }
}

private final class ChangingLocalizationStore: LocalizationPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LocalizationPreferences] = [
        .init(appLanguage: .ko, errorLanguage: .en),
        .init(appLanguage: .en, errorLanguage: .ko),
    ]
    private var loads = 0
    func load() -> LocalizationPreferences {
        lock.withLock {
            let value = values[loads % values.count]
            loads += 1
            return value
        }
    }
    func save(_ preferences: LocalizationPreferences) { lock.withLock { values = [preferences] } }
    var loadCount: Int { lock.withLock { loads } }
}

struct LocalizationPreferenceTests {
    @Test func defaultsAreSystemAndFollowAppAndPersistencePublishesOneValidatedRecord() throws {
        #expect(AppLanguage.allCases == [.system, .ko, .en])
        #expect(ErrorLanguage.allCases == [.followApp, .system, .ko, .en])
        let suite = "dev.lathe.tests.localization.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsLocalizationPreferenceStore(defaults: defaults)
        #expect(store.load() == LocalizationPreferences())
        let selected = LocalizationPreferences(appLanguage: .en, errorLanguage: .ko)
        store.save(selected)
        let reopened = UserDefaultsLocalizationPreferenceStore(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.load() == selected)
        #expect(Set((defaults.persistentDomain(forName: suite) ?? [:]).keys) == [UserDefaultsLocalizationPreferenceStore.storageKey])
        #expect(defaults.dictionary(forKey: UserDefaultsLocalizationPreferenceStore.storageKey) as? [String: String]
            == ["appLanguage": "en", "errorLanguage": "ko"])
        // Invalid or partial stored records never produce a partially accepted pair.
        defaults.set(["appLanguage": "en", "errorLanguage": "unknown"], forKey: UserDefaultsLocalizationPreferenceStore.storageKey)
        #expect(reopened.load() == LocalizationPreferences())
        defaults.set(["appLanguage": "ko"], forKey: UserDefaultsLocalizationPreferenceStore.storageKey)
        #expect(reopened.load() == LocalizationPreferences())
    }

    @Test(arguments: [AppLanguage.ko, .en])
    func interfaceAndErrorsChooseIndependentLanguagesWithoutInferringFromTableNames(appLanguage: AppLanguage) {
        let koreanApp = appLanguage == .ko
        let selected = LocalizationPreferences(appLanguage: appLanguage, errorLanguage: koreanApp ? .en : .ko)
        L10n.$preferencesOverride.withValue(selected) {
            // Both channels read the same table/key; only the selected API differs.
            #expect(L10n.text("localization.language", table: "Localization") == (koreanApp ? "한국어" : "English"))
            #expect(L10n.errorText("localization.language", table: "Localization") == (koreanApp ? "English" : "한국어"))
            #expect(L10n.format("localization.format", table: "Localization", "Fixture", 2)
                == (koreanApp ? "Fixture에 작업 2개가 있습니다." : "Fixture has 2 tasks."))
            #expect(L10n.errorFormat("localization.format", table: "Localization", "Fixture", 2)
                == (koreanApp ? "Fixture has 2 tasks." : "Fixture에 작업 2개가 있습니다."))
            #expect(L10n.preferredLanguage == (koreanApp ? "ko" : "en"))
            #expect(L10n.preferredErrorLanguage == (koreanApp ? "en" : "ko"))
            #expect(L10n.interfaceLocale.language.languageCode?.identifier == appLanguage.rawValue)
        }
    }

    @Test func followAppTracksTheInterfaceWhileSystemErrorsRemainIndependent() {
        for app in [AppLanguage.ko, .en] {
            L10n.$preferencesOverride.withValue(.init(appLanguage: app, errorLanguage: .followApp)) {
                #expect(L10n.preferredErrorLanguage == L10n.preferredLanguage)
                #expect(L10n.errorText("localization.language", table: "Localization") == (app == .ko ? "한국어" : "English"))
            }
        }
        let system = L10n.resourceBundle.localizedString(forKey: "localization.language", value: nil, table: "Localization")
        let opposite: AppLanguage = system == "한국어" ? .en : .ko
        L10n.$preferencesOverride.withValue(.init(appLanguage: opposite, errorLanguage: .system)) {
            #expect(L10n.errorText("localization.language", table: "Localization") == system)
            #expect(L10n.text("localization.language", table: "Localization") != system)
        }
    }

    @Test func explicitLocaleAndTaskOverridesTakePrecedenceForBothChannels() {
        L10n.$preferencesOverride.withValue(.init(appLanguage: .ko, errorLanguage: .en)) {
            L10n.$localeOverride.withValue(Locale(identifier: "en")) {
                #expect(L10n.preferredLanguage == "en" && L10n.preferredErrorLanguage == "en")
                #expect(L10n.text("localization.language", table: "Localization") == "English")
                #expect(L10n.errorText("localization.language", table: "Localization") == "English")
                #expect(L10n.errorText("localization.language", table: "Localization", locale: Locale(identifier: "ko")) == "한국어")
                #expect(L10n.errorFormat("localization.format", table: "Localization", locale: Locale(identifier: "ko"), "Fixture", 2) == "Fixture에 작업 2개가 있습니다.")
            }
            L10n.$localeOverride.withValue(Locale(identifier: "fr")) {
                #expect(L10n.preferredLanguage == "ko" && L10n.preferredErrorLanguage == "ko")
                #expect(L10n.interfaceLocale.language.languageCode?.identifier == "ko")
            }
            #expect(L10n.preferredLanguage == "ko" && L10n.preferredErrorLanguage == "en")
        }
    }

    @Test func helperEnvironmentCarriesSeparateLanguagesAndRetainsDisplayOnlyCompatibility() {
        L10n.$preferencesOverride.withValue(.init(appLanguage: .en, errorLanguage: .en)) {
            L10n.$environmentOverride.withValue(["LATHE_DISPLAY_LANGUAGE": "ko", "LATHE_ERROR_LANGUAGE": "en"]) {
                #expect(L10n.preferredLanguage == "ko" && L10n.preferredErrorLanguage == "en")
                #expect(L10n.errorText("localization.language", table: "Localization") == "English")
            }
            L10n.$environmentOverride.withValue(["LATHE_DISPLAY_LANGUAGE": "ko"]) {
                #expect(L10n.preferredLanguage == "ko" && L10n.preferredErrorLanguage == "ko")
            }
            L10n.$environmentOverride.withValue(["LATHE_ERROR_LANGUAGE": "ko"]) {
                #expect(L10n.preferredLanguage == "en" && L10n.preferredErrorLanguage == "ko")
            }
        }
    }

    @Test func helperEnvironmentCapturesOnePreferenceRevisionAndPreservesOverridePrecedence() {
        let store = ChangingLocalizationStore()
        L10n.$preferenceStoreOverride.withValue(store) {
            #expect(L10n.helperEnvironment == ["LATHE_DISPLAY_LANGUAGE": "ko", "LATHE_ERROR_LANGUAGE": "en"])
            #expect(store.loadCount == 1)
            #expect(L10n.helperEnvironment == ["LATHE_DISPLAY_LANGUAGE": "en", "LATHE_ERROR_LANGUAGE": "ko"])
            #expect(store.loadCount == 2)
            L10n.$environmentOverride.withValue(["LATHE_DISPLAY_LANGUAGE": "en", "LATHE_ERROR_LANGUAGE": "ko"]) {
                #expect(L10n.helperEnvironment == ["LATHE_DISPLAY_LANGUAGE": "en", "LATHE_ERROR_LANGUAGE": "ko"])
                L10n.$localeOverride.withValue(Locale(identifier: "ko")) {
                    #expect(L10n.helperEnvironment == ["LATHE_DISPLAY_LANGUAGE": "ko", "LATHE_ERROR_LANGUAGE": "ko"])
                }
            }
        }
    }

    @Test func injectedPreferenceStoreIsVisibleToConcurrentTasksWithoutTouchingUserDefaults() async {
        let store = LocalizationMemoryStore()
        await L10n.$preferenceStoreOverride.withValue(store) {
            L10n.setPreferences(.init(appLanguage: .ko, errorLanguage: .en))
            #expect(store.load() == .init(appLanguage: .ko, errorLanguage: .en))
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        #expect(L10n.preferences == .init(appLanguage: .ko, errorLanguage: .en))
                        #expect(L10n.text("localization.language", table: "Localization") == "한국어")
                        #expect(L10n.errorText("localization.language", table: "Localization") == "English")
                    }
                }
            }
            L10n.setPreferences(.init(appLanguage: .en, errorLanguage: .followApp))
            #expect(L10n.preferredLanguage == "en" && L10n.preferredErrorLanguage == "en")
        }
    }

    @Test func concurrentUserDefaultsAccessNeverExposesMixedPreferencePairs() throws {
        let suite = "dev.lathe.tests.localization.concurrent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsLocalizationPreferenceStore(defaults: defaults)
        let first = LocalizationPreferences(appLanguage: .ko, errorLanguage: .en)
        let second = LocalizationPreferences(appLanguage: .en, errorLanguage: .ko)
        let failures = PreferenceFailureCounter()
        store.save(first)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            for _ in 0..<50 {
                store.save(index.isMultiple(of: 2) ? first : second)
                let snapshot = store.load()
                if snapshot != first && snapshot != second { failures.record() }
            }
        }
        #expect(failures.count == 0)
    }
}

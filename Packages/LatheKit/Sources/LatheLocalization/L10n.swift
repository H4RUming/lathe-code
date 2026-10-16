import Foundation

/// All fixed application copy lives in localized resource tables. Provider
/// responses, protocol payloads and original diagnostic logs are not translated.
public enum L10n {
    static let resourceBundle: Bundle = {
        // The helper lives in Contents/Helpers, while the single shared resource
        // bundle belongs to Contents/Resources. SwiftPM's generated accessor does
        // not search that sibling directory for a command-line executable.
        if let executable = Bundle.main.executableURL {
            let directory = executable.deletingLastPathComponent()
            if directory.lastPathComponent == "Helpers",
               directory.deletingLastPathComponent().lastPathComponent == "Contents",
               let bundle = Bundle(url: directory.deletingLastPathComponent()
                .appendingPathComponent("Resources/LatheKit_LatheLocalization.bundle")) {
                return bundle
            }
        }
        return Bundle.module
    }()
    private static let fallbackLanguage = "ko"
    // Task-scoped overrides make locale checks independent, including parallel
    // async tests, without mutating process-wide AppleLanguages preferences.
    @TaskLocal static var localeOverride: Locale?
    @TaskLocal static var preferencesOverride: LocalizationPreferences?
    @TaskLocal static var preferenceStoreOverride: (any LocalizationPreferenceStore)?
    @TaskLocal static var environmentOverride: [String: String]?
    private static let preferenceStore = UserDefaultsLocalizationPreferenceStore()
    private static let preferenceMutationLock = NSLock()
    private static let inheritedEnvironment = ProcessInfo.processInfo.environment

    /// Sent after a changed pair has been saved. Observers should read preferences
    /// again and hop to their UI actor; the notification uses the caller's thread.
    public static let preferencesDidChange = Notification.Name("dev.lathe.localization.preferencesDidChange")

    public static var preferences: LocalizationPreferences {
        preferencesOverride ?? (preferenceStoreOverride ?? preferenceStore).load()
    }

    public static func setPreferences(_ preferences: LocalizationPreferences) {
        let store = preferenceStoreOverride ?? preferenceStore
        let changed = preferenceMutationLock.withLock {
            guard store.load() != preferences else { return false }
            store.save(preferences)
            return true
        }
        if changed { NotificationCenter.default.post(name: preferencesDidChange, object: nil) }
    }

    /// Carry the app's selected language into its helper's otherwise clean environment.
    public static var preferredLanguage: String { language(for: .interface) }
    public static var preferredErrorLanguage: String { language(for: .error) }
    public static var interfaceLocale: Locale { Locale(identifier: preferredLanguage) }

    /// Resolve both channels from one preference snapshot so an intervening
    /// settings change cannot give a helper languages from different revisions.
    public static var helperEnvironment: [String: String] {
        let preferences = preferences
        let environment = environment
        let override = localeOverride
        return [
            "LATHE_DISPLAY_LANGUAGE": resolvedLanguage(locale: selectedLocale(for: .interface,
                preferences: preferences, environment: environment, override: override)),
            "LATHE_ERROR_LANGUAGE": resolvedLanguage(locale: selectedLocale(for: .error,
                preferences: preferences, environment: environment, override: override)),
        ]
    }

    /// Without an override, Foundation uses the app's preferred localization.
    /// An explicit unsupported language falls back to Korean, as do missing
    /// translations. A key missing from every table is returned for diagnosis.
    public static func text(_ key: String, table: String = "Interface", locale: Locale? = nil) -> String {
        localizedText(key, table: table, locale: locale ?? selectedLocale(for: .interface))
    }

    /// Call sites explicitly select the error channel; table names do not infer it.
    public static func errorText(_ key: String, table: String = "Interface", locale: Locale? = nil) -> String {
        localizedText(key, table: table, locale: locale ?? selectedLocale(for: .error))
    }

    /// Translate the complete sentence, including positional format specifiers,
    /// rather than joining translated fragments around dynamic values.
    public static func format(_ key: String, table: String = "Interface", _ arguments: CVarArg...) -> String {
        let locale = selectedLocale(for: .interface)
        return String(format: localizedText(key, table: table, locale: locale), locale: locale ?? Locale.current, arguments: arguments)
    }

    /// Explicit language selection for previews and deterministic locale tests.
    public static func format(_ key: String, table: String = "Interface", locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: text(key, table: table, locale: locale), locale: locale, arguments: arguments)
    }

    public static func errorFormat(_ key: String, table: String = "Interface", _ arguments: CVarArg...) -> String {
        let locale = selectedLocale(for: .error)
        return String(format: localizedText(key, table: table, locale: locale), locale: locale ?? Locale.current, arguments: arguments)
    }

    public static func errorFormat(_ key: String, table: String = "Interface", locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: errorText(key, table: table, locale: locale), locale: locale, arguments: arguments)
    }

    private enum Channel { case interface, error }

    private static var environment: [String: String] {
        if let environmentOverride { return environmentOverride }
        // Deterministic test stores/preferences must not inherit the test process'
        // language flags. Environment propagation has its own explicit override.
        if preferencesOverride != nil || preferenceStoreOverride != nil { return [:] }
        return inheritedEnvironment
    }

    private static func selectedLocale(for channel: Channel) -> Locale? {
        selectedLocale(for: channel, preferences: preferences, environment: environment, override: localeOverride)
    }

    private static func selectedLocale(for channel: Channel, preferences: LocalizationPreferences,
        environment values: [String: String], override: Locale?) -> Locale? {
        if let override { return override }
        if channel == .error, let value = values["LATHE_ERROR_LANGUAGE"] { return Locale(identifier: value) }
        if let value = values["LATHE_DISPLAY_LANGUAGE"] { return Locale(identifier: value) }
        if channel == .error {
            switch preferences.errorLanguage {
            case .ko: return Locale(identifier: "ko")
            case .en: return Locale(identifier: "en")
            case .system: return nil
            case .followApp: break
            }
        }
        switch preferences.appLanguage {
        case .system: return nil
        case .ko: return Locale(identifier: "ko")
        case .en: return Locale(identifier: "en")
        }
    }

    private static func language(for channel: Channel) -> String {
        resolvedLanguage(locale: selectedLocale(for: channel))
    }

    private static func resolvedLanguage(locale: Locale?) -> String {
        let selected = locale.map(bundle(for:)) ?? resourceBundle
        if selected.bundleURL.pathExtension == "lproj" { return selected.bundleURL.deletingPathExtension().lastPathComponent }
        return selected.preferredLocalizations.first ?? fallbackLanguage
    }

    private static func localizedText(_ key: String, table: String, locale: Locale?) -> String {
        let bundle = locale.map(bundle(for:)) ?? resourceBundle
        let missing = "\u{001F}missing-localization:\(key)"
        let value = bundle.localizedString(forKey: key, value: missing, table: table)
        if value != missing { return value }
        return fallbackBundle.localizedString(forKey: key, value: key, table: table)
    }

    private static var fallbackBundle: Bundle {
        localizedBundle(named: fallbackLanguage) ?? resourceBundle
    }

    private static func bundle(for locale: Locale) -> Bundle {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        if let exact = resourceBundle.localizations.first(where: { $0.caseInsensitiveCompare(identifier) == .orderedSame }),
           let bundle = localizedBundle(named: exact) { return bundle }
        guard let language = locale.language.languageCode?.identifier else { return fallbackBundle }
        let matching = resourceBundle.localizations.filter {
            $0.split(separator: "-").first?.lowercased() == language.lowercased()
        }
        // Foundation may return its own default even for an empty list.
        guard !matching.isEmpty else { return fallbackBundle }
        if let selected = Bundle.preferredLocalizations(from: matching, forPreferences: [identifier]).first,
           let bundle = localizedBundle(named: selected) { return bundle }
        return fallbackBundle
    }

    private static func localizedBundle(named language: String) -> Bundle? {
        guard let path = resourceBundle.path(forResource: language, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}

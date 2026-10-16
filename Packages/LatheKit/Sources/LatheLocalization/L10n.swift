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
    private static let inheritedLocale: Locale? = ProcessInfo.processInfo.environment["LATHE_DISPLAY_LANGUAGE"]
        .map { Locale(identifier: $0) }

    /// Carry the app's selected language into its helper's otherwise clean environment.
    public static var preferredLanguage: String {
        let selected = (localeOverride ?? inheritedLocale).map(bundle(for:)) ?? resourceBundle
        if selected.bundleURL.pathExtension == "lproj" {
            return selected.bundleURL.deletingPathExtension().lastPathComponent
        }
        return selected.preferredLocalizations.first ?? fallbackLanguage
    }

    /// Without an override, Foundation uses the app's preferred localization.
    /// An explicit unsupported language falls back to Korean, as do missing
    /// translations. A key missing from every table is returned for diagnosis.
    public static func text(_ key: String, table: String = "Interface", locale: Locale? = nil) -> String {
        let bundle = (locale ?? localeOverride ?? inheritedLocale).map(bundle(for:)) ?? resourceBundle
        let missing = "\u{001F}missing-localization:\(key)"
        let value = bundle.localizedString(forKey: key, value: missing, table: table)
        if value != missing { return value }
        return fallbackBundle.localizedString(forKey: key, value: key, table: table)
    }

    /// Translate the complete sentence, including positional format specifiers,
    /// rather than joining translated fragments around dynamic values.
    public static func format(_ key: String, table: String = "Interface", _ arguments: CVarArg...) -> String {
        String(format: text(key, table: table), locale: localeOverride ?? inheritedLocale ?? Locale.current, arguments: arguments)
    }

    /// Explicit language selection for previews and deterministic locale tests.
    public static func format(_ key: String, table: String = "Interface", locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: text(key, table: table, locale: locale), locale: locale, arguments: arguments)
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

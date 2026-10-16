import Foundation

/// All fixed application copy lives in localized resource tables. Provider
/// responses, protocol payloads and original diagnostic logs are not translated.
public enum L10n {
    static var resourceBundle: Bundle { Bundle.module }
    private static let fallbackLanguage = "ko"

    /// Without an override, Foundation uses the app's preferred localization.
    /// An explicit unsupported language falls back to Korean, as do missing
    /// translations. A key missing from every table is returned for diagnosis.
    public static func text(_ key: String, table: String = "Interface", locale: Locale? = nil) -> String {
        let bundle = locale.map(bundle(for:)) ?? resourceBundle
        let missing = "\u{001F}missing-localization:\(key)"
        let value = bundle.localizedString(forKey: key, value: missing, table: table)
        if value != missing { return value }
        return fallbackBundle.localizedString(forKey: key, value: key, table: table)
    }

    /// Translate the complete sentence, including positional format specifiers,
    /// rather than joining translated fragments around dynamic values.
    public static func format(_ key: String, table: String = "Interface", _ arguments: CVarArg...) -> String {
        String(format: text(key, table: table), locale: Locale.current, arguments: arguments)
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

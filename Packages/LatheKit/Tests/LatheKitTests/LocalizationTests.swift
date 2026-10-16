import Foundation
@testable import LatheLocalization
import Testing

struct LocalizationTests {
    @Test func selectsKoreanEnglishAndRegionalLanguageVariants() {
        for identifier in ["ko", "ko_KR"] {
            #expect(L10n.text("localization.language", table: "Localization", locale: Locale(identifier: identifier)) == "한국어")
        }
        for identifier in ["en", "en_US", "en-GB", "en_US_POSIX"] {
            #expect(L10n.text("localization.language", table: "Localization", locale: Locale(identifier: identifier)) == "English")
        }
        #expect(Set(L10n.resourceBundle.localizations).isSuperset(of: ["ko", "en"]))
    }

    @Test func unsupportedLanguagesFallBackToKoreanAndMissingKeysRemainDiagnosable() {
        for identifier in ["fr_FR", "ja_JP", "und"] {
            #expect(L10n.text("localization.language", table: "Localization", locale: Locale(identifier: identifier)) == "한국어")
        }
        #expect(L10n.text("fixture.missing", table: "Localization", locale: Locale(identifier: "en")) == "fixture.missing")
        #expect(L10n.text("fixture.missing", table: "UnknownTable", locale: Locale(identifier: "ko")) == "fixture.missing")
    }

    @Test func defaultSelectionUsesTheResourceBundlePreferredLanguage() {
        let expected = L10n.resourceBundle.localizedString(forKey: "localization.language", value: nil, table: "Localization")
        #expect(L10n.text("localization.language", table: "Localization") == expected)
        #expect(["한국어", "English"].contains(expected))
    }

    @Test func wholeSentenceFormattingSupportsReorderedArgumentsAndLiteralPercentValues() {
        let korean = Locale(identifier: "ko"), english = Locale(identifier: "en")
        #expect(L10n.format("localization.format", table: "Localization", locale: korean, "프로젝트", 3) == "프로젝트에 작업 3개가 있습니다.")
        #expect(L10n.format("localization.format", table: "Localization", locale: english, "Project", 3) == "Project has 3 tasks.")
        #expect(L10n.format("localization.reorderedFormat", table: "Localization", locale: korean, 4, "100% ready") == "100% ready · 4개")
        #expect(L10n.format("localization.reorderedFormat", table: "Localization", locale: english, 4, "100% ready") == "4 items · 100% ready")
        let format = L10n.text("localization.format", table: "Localization")
        #expect(L10n.format("localization.format", table: "Localization", "Workspace", 2) == String(format: format, locale: Locale.current, arguments: ["Workspace", 2]))
    }
}

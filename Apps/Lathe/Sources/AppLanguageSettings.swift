import Combine
import Foundation
import LatheLocalization

/// Keeps the existing scenes alive while shared language preferences change.
/// Persistence belongs to LatheLocalization so helpers use the same settings.
@MainActor
final class AppLanguageSettings: ObservableObject {
    @Published private(set) var preferences: LocalizationPreferences
    @Published private(set) var interfaceLocale: Locale

    private let readPreferences: () -> LocalizationPreferences
    private let writePreferences: (LocalizationPreferences) -> Void
    private let readLocale: () -> Locale
    private var observations: Set<AnyCancellable> = []

    init(readPreferences: @escaping () -> LocalizationPreferences = { L10n.preferences },
         writePreferences: @escaping (LocalizationPreferences) -> Void = { L10n.setPreferences($0) },
         readLocale: @escaping () -> Locale = { L10n.interfaceLocale },
         notifications: NotificationCenter = .default) {
        self.readPreferences = readPreferences
        self.writePreferences = writePreferences
        self.readLocale = readLocale
        preferences = readPreferences()
        interfaceLocale = readLocale()
        for name in [L10n.preferencesDidChange, NSLocale.currentLocaleDidChangeNotification] {
            notifications.publisher(for: name).sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }.store(in: &observations)
        }
    }

    func setAppLanguage(_ language: AppLanguage) {
        var updated = readPreferences()
        updated.appLanguage = language
        save(updated)
    }

    func setErrorLanguage(_ language: ErrorLanguage) {
        var updated = readPreferences()
        updated.errorLanguage = language
        save(updated)
    }

    private func save(_ updated: LocalizationPreferences) {
        guard updated != readPreferences() else { refresh(); return }
        writePreferences(updated)
        // Update before the picker action returns. The notification also keeps
        // other settings windows synchronized with changes made elsewhere.
        refresh()
    }

    private func refresh() {
        let updated = readPreferences()
        let locale = readLocale()
        if preferences != updated { preferences = updated }
        if interfaceLocale != locale { interfaceLocale = locale }
    }
}

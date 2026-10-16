import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system, ko, en
}

public enum ErrorLanguage: String, Codable, CaseIterable, Sendable {
    case followApp, system, ko, en
}

public struct LocalizationPreferences: Codable, Equatable, Sendable {
    public var appLanguage: AppLanguage
    public var errorLanguage: ErrorLanguage

    public init(appLanguage: AppLanguage = .system, errorLanguage: ErrorLanguage = .followApp) {
        self.appLanguage = appLanguage
        self.errorLanguage = errorLanguage
    }
}

/// Synchronous access is required by errors created on runtime/runner threads.
/// Implementations must publish each preference pair as one coherent snapshot.
public protocol LocalizationPreferenceStore: Sendable {
    func load() -> LocalizationPreferences
    func save(_ preferences: LocalizationPreferences)
}

/// One UserDefaults record prevents readers from observing a partially updated
/// app/error language pair. An injected suite keeps tests out of user settings.
public final class UserDefaultsLocalizationPreferenceStore: LocalizationPreferenceStore, @unchecked Sendable {
    static let storageKey = "dev.lathe.localization.preferences"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> LocalizationPreferences {
        lock.withLock {
            guard let record = defaults.dictionary(forKey: Self.storageKey),
                  let appValue = record["appLanguage"] as? String,
                  let errorValue = record["errorLanguage"] as? String,
                  let app = AppLanguage(rawValue: appValue),
                  let error = ErrorLanguage(rawValue: errorValue) else { return LocalizationPreferences() }
            return LocalizationPreferences(appLanguage: app, errorLanguage: error)
        }
    }

    public func save(_ preferences: LocalizationPreferences) {
        lock.withLock {
            defaults.set(["appLanguage": preferences.appLanguage.rawValue,
                          "errorLanguage": preferences.errorLanguage.rawValue], forKey: Self.storageKey)
        }
    }
}

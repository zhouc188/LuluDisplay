import Foundation

@MainActor final class PreferencesStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    func get<T: Codable>(_ key: String, _ fallback: T) -> T {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }
    func set<T: Codable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

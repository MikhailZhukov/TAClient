import Foundation

@Observable
final class SponsorBlockSettings {
    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    private var categoryStates: [SponsorCategory: Bool]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Master toggle defaults to true
        if defaults.object(forKey: Keys.enabled) == nil {
            defaults.set(true, forKey: Keys.enabled)
        }
        self.isEnabled = defaults.bool(forKey: Keys.enabled)

        // Per-category defaults to true
        var states: [SponsorCategory: Bool] = [:]
        for category in SponsorCategory.allCases {
            let key = Keys.category(category)
            if defaults.object(forKey: key) == nil {
                defaults.set(true, forKey: key)
            }
            states[category] = defaults.bool(forKey: key)
        }
        self.categoryStates = states

        // Player gestures
        if defaults.object(forKey: Keys.doubleTapToSeek) == nil {
            defaults.set(true, forKey: Keys.doubleTapToSeek)
        }
        self.doubleTapToSeek = defaults.bool(forKey: Keys.doubleTapToSeek)

        if defaults.object(forKey: Keys.seekInterval) == nil {
            defaults.set(10, forKey: Keys.seekInterval)
        }
        self.seekInterval = defaults.integer(forKey: Keys.seekInterval)
    }

    func isCategoryEnabled(_ category: SponsorCategory) -> Bool {
        categoryStates[category] ?? true
    }

    func setCategoryEnabled(_ category: SponsorCategory, enabled: Bool) {
        categoryStates[category] = enabled
        defaults.set(enabled, forKey: Keys.category(category))
    }

    func enabledCategories() -> Set<SponsorCategory> {
        guard isEnabled else { return [] }
        return Set(SponsorCategory.allCases.filter { isCategoryEnabled($0) })
    }

    // MARK: - Player Gestures

    var doubleTapToSeek: Bool {
        didSet { defaults.set(doubleTapToSeek, forKey: Keys.doubleTapToSeek) }
    }

    var seekInterval: Int {
        didSet { defaults.set(seekInterval, forKey: Keys.seekInterval) }
    }

    static let seekIntervalOptions = [5, 10, 15, 30]

    private enum Keys {
        static let enabled = "sb_enabled"
        static let doubleTapToSeek = "gesture_double_tap_seek"
        static let seekInterval = "gesture_seek_interval"
        static func category(_ cat: SponsorCategory) -> String {
            "sb_\(cat.rawValue)"
        }
    }
}

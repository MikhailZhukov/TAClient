import Foundation
import Testing
@testable import TAClient

struct SponsorBlockSettingsTests {

    private func makeSettings() -> SponsorBlockSettings {
        let defaults = UserDefaults(suiteName: "test-sb-\(UUID().uuidString)")!
        return SponsorBlockSettings(defaults: defaults)
    }

    // MARK: - Defaults

    @Test func defaultsToEnabled() {
        let settings = makeSettings()
        #expect(settings.isEnabled == true)
    }

    @Test func allCategoriesEnabledByDefault() {
        let settings = makeSettings()
        for category in SponsorCategory.allCases {
            #expect(settings.isCategoryEnabled(category) == true)
        }
    }

    @Test func enabledCategories_returnsAllWhenEnabled() {
        let settings = makeSettings()
        let enabled = settings.enabledCategories()
        #expect(enabled.count == 8)
        for category in SponsorCategory.allCases {
            #expect(enabled.contains(category))
        }
    }

    // MARK: - Master Toggle

    @Test func disableMaster_enabledCategoriesEmpty() {
        let settings = makeSettings()
        settings.isEnabled = false

        let enabled = settings.enabledCategories()
        #expect(enabled.isEmpty)
    }

    @Test func masterTogglePersists() {
        let suiteName = "test-sb-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let settings1 = SponsorBlockSettings(defaults: defaults)
        settings1.isEnabled = false

        let settings2 = SponsorBlockSettings(defaults: defaults)
        #expect(settings2.isEnabled == false)

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Per-Category Toggle

    @Test func disableCategory_filteredFromEnabledCategories() {
        let settings = makeSettings()
        settings.setCategoryEnabled(.sponsor, enabled: false)

        #expect(settings.isCategoryEnabled(.sponsor) == false)
        #expect(settings.isCategoryEnabled(.intro) == true)

        let enabled = settings.enabledCategories()
        #expect(enabled.count == 7)
        #expect(!enabled.contains(.sponsor))
    }

    @Test func disableMultipleCategories() {
        let settings = makeSettings()
        settings.setCategoryEnabled(.sponsor, enabled: false)
        settings.setCategoryEnabled(.selfpromo, enabled: false)
        settings.setCategoryEnabled(.filler, enabled: false)

        let enabled = settings.enabledCategories()
        #expect(enabled.count == 5)
        #expect(!enabled.contains(.sponsor))
        #expect(!enabled.contains(.selfpromo))
        #expect(!enabled.contains(.filler))
        #expect(enabled.contains(.intro))
        #expect(enabled.contains(.outro))
    }

    @Test func reEnableCategory() {
        let settings = makeSettings()
        settings.setCategoryEnabled(.sponsor, enabled: false)
        #expect(settings.isCategoryEnabled(.sponsor) == false)

        settings.setCategoryEnabled(.sponsor, enabled: true)
        #expect(settings.isCategoryEnabled(.sponsor) == true)
    }

    @Test func categoryTogglePersists() {
        let suiteName = "test-sb-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let settings1 = SponsorBlockSettings(defaults: defaults)
        settings1.setCategoryEnabled(.intro, enabled: false)

        let settings2 = SponsorBlockSettings(defaults: defaults)
        #expect(settings2.isCategoryEnabled(.intro) == false)
        #expect(settings2.isCategoryEnabled(.sponsor) == true)

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Disable All Categories

    @Test func disableAllCategories_enabledCategoriesEmpty() {
        let settings = makeSettings()
        for category in SponsorCategory.allCases {
            settings.setCategoryEnabled(category, enabled: false)
        }

        let enabled = settings.enabledCategories()
        #expect(enabled.isEmpty)
    }

    // MARK: - Master Off + Category Off Interaction

    @Test func masterOff_categoriesIrrelevant() {
        let settings = makeSettings()
        settings.isEnabled = false

        // Categories still report their individual state
        #expect(settings.isCategoryEnabled(.sponsor) == true)
        // But enabledCategories returns empty
        #expect(settings.enabledCategories().isEmpty)
    }

    @Test func masterOn_respectsCategoryState() {
        let settings = makeSettings()
        settings.isEnabled = false
        settings.setCategoryEnabled(.sponsor, enabled: false)

        settings.isEnabled = true
        let enabled = settings.enabledCategories()
        #expect(enabled.count == 7)
        #expect(!enabled.contains(.sponsor))
    }
}

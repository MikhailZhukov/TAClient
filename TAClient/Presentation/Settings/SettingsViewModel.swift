import SwiftUI

@Observable
final class SettingsViewModel {
    let settings: SponsorBlockSettings

    init(settings: SponsorBlockSettings) {
        self.settings = settings
    }

    var isSponsorBlockEnabled: Bool {
        settings.isEnabled
    }

    var sponsorBlockEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.isEnabled },
            set: { self.settings.isEnabled = $0 }
        )
    }

    func binding(for category: SponsorCategory) -> Binding<Bool> {
        Binding(
            get: { self.settings.isCategoryEnabled(category) },
            set: { self.settings.setCategoryEnabled(category, enabled: $0) }
        )
    }

    // MARK: - Player Gestures

    var isDoubleTapToSeekEnabled: Bool {
        settings.doubleTapToSeek
    }

    var doubleTapToSeekBinding: Binding<Bool> {
        Binding(
            get: { self.settings.doubleTapToSeek },
            set: { self.settings.doubleTapToSeek = $0 }
        )
    }

    var seekIntervalBinding: Binding<Int> {
        Binding(
            get: { self.settings.seekInterval },
            set: { self.settings.seekInterval = $0 }
        )
    }
}

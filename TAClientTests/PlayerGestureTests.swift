import Foundation
import Testing
@testable import TAClient

struct PlayerGestureSettingsTests {

    private func makeSettings() -> SponsorBlockSettings {
        let defaults = UserDefaults(suiteName: "test-gesture-\(UUID().uuidString)")!
        return SponsorBlockSettings(defaults: defaults)
    }

    // MARK: - Defaults

    @Test func doubleTapToSeek_defaultsToTrue() {
        let settings = makeSettings()
        #expect(settings.doubleTapToSeek == true)
    }

    @Test func seekInterval_defaultsTo10() {
        let settings = makeSettings()
        #expect(settings.seekInterval == 10)
    }

    // MARK: - Toggle

    @Test func doubleTapToSeek_togglePersists() {
        let suiteName = "test-gesture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let settings1 = SponsorBlockSettings(defaults: defaults)
        settings1.doubleTapToSeek = false

        let settings2 = SponsorBlockSettings(defaults: defaults)
        #expect(settings2.doubleTapToSeek == false)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func seekInterval_changePersists() {
        let suiteName = "test-gesture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let settings1 = SponsorBlockSettings(defaults: defaults)
        settings1.seekInterval = 30

        let settings2 = SponsorBlockSettings(defaults: defaults)
        #expect(settings2.seekInterval == 30)

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Options

    @Test func seekIntervalOptions_contains_5_10_15_30() {
        #expect(SponsorBlockSettings.seekIntervalOptions == [5, 10, 15, 30])
    }

    // MARK: - ViewModel exposure

    @Test func viewModel_exposesDoubleTapToSeek() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video() }

        let defaults = UserDefaults(suiteName: "test-gesture-\(UUID().uuidString)")!
        let settings = SponsorBlockSettings(defaults: defaults)
        settings.doubleTapToSeek = false
        settings.seekInterval = 15

        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = VideoDetailViewModel(
            videoId: "test",
            videoRepository: repo,
            authState: authState,
            router: router,
            sponsorBlockSettings: settings
        )

        #expect(vm.doubleTapToSeek == false)
        #expect(vm.seekInterval == 15)
    }
}

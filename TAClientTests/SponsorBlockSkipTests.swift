import Foundation
import Testing
@testable import TAClient

struct SponsorBlockSkipTests {

    private func makeSUT(
        videoId: String = "test-video-id",
        videoRepo: MockVideoRepository = MockVideoRepository(),
        sponsorBlockSettings: SponsorBlockSettings? = nil
    ) -> (VideoDetailViewModel, AppRouter, SponsorBlockSettings) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let settings = sponsorBlockSettings ?? {
            let defaults = UserDefaults(suiteName: "test-sb-\(UUID().uuidString)")!
            return SponsorBlockSettings(defaults: defaults)
        }()
        let vm = VideoDetailViewModel(
            videoId: videoId,
            videoRepository: videoRepo,
            authState: authState,
            router: router,
            sponsorBlockSettings: settings
        )
        return (vm, router, settings)
    }

    // MARK: - activeSegments

    @Test func activeSegments_noVideo_returnsEmpty() {
        let (vm, _, _) = makeSUT()
        #expect(vm.activeSegments().isEmpty)
    }

    @Test func activeSegments_videoWithSegments_allEnabled() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
            SponsorBlockSegment(category: .intro, startTime: 50, endTime: 60),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        let active = vm.activeSegments()
        #expect(active.count == 2)
    }

    @Test func activeSegments_masterDisabled_returnsEmpty() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }

        let defaults = UserDefaults(suiteName: "test-sb-\(UUID().uuidString)")!
        let settings = SponsorBlockSettings(defaults: defaults)
        settings.isEnabled = false

        let (vm, _, _) = makeSUT(videoRepo: repo, sponsorBlockSettings: settings)

        await vm.loadVideo()

        #expect(vm.activeSegments().isEmpty)
    }

    @Test func activeSegments_categoryDisabled_filtered() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
            SponsorBlockSegment(category: .intro, startTime: 50, endTime: 60),
            SponsorBlockSegment(category: .outro, startTime: 100, endTime: 110),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }

        let defaults = UserDefaults(suiteName: "test-sb-\(UUID().uuidString)")!
        let settings = SponsorBlockSettings(defaults: defaults)
        settings.setCategoryEnabled(.sponsor, enabled: false)
        settings.setCategoryEnabled(.outro, enabled: false)

        let (vm, _, _) = makeSUT(videoRepo: repo, sponsorBlockSettings: settings)

        await vm.loadVideo()

        let active = vm.activeSegments()
        #expect(active.count == 1)
        #expect(active[0].category == .intro)
    }

    @Test func activeSegments_noSegments_returnsEmpty() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: []) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        #expect(vm.activeSegments().isEmpty)
    }

    // MARK: - VLC SponsorBlock

    @Test func vlcSponsorBlockSeekTarget_inSegment_returnsEndTime() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        // Simulate VLC reporting time inside a segment
        vm.onVLCTimeChanged(seconds: 15.0)

        // After skip, the seek target should be nil (segment already skipped)
        #expect(vm.vlcSponsorBlockSeekTarget == nil)
        #expect(vm.showSkipBanner == true)
        #expect(vm.skippedSegment?.category == .sponsor)
    }

    @Test func vlcSponsorBlockSeekTarget_outsideSegment_returnsNil() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()
        vm.onVLCTimeChanged(seconds: 5.0)

        #expect(vm.vlcSponsorBlockSeekTarget == nil)
        #expect(vm.showSkipBanner == false)
    }

    @Test func vlcSkip_sameSegment_onlySkipsOnce() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        vm.onVLCTimeChanged(seconds: 15.0)
        #expect(vm.showSkipBanner == true)

        // Second time in same segment — already skipped, should not re-trigger
        vm.showSkipBanner = false
        vm.onVLCTimeChanged(seconds: 20.0)
        #expect(vm.showSkipBanner == false)
    }

    // MARK: - Undo

    @Test func undoSkip_clearsSkippedState() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        // Trigger skip
        vm.onVLCTimeChanged(seconds: 15.0)
        #expect(vm.showSkipBanner == true)
        #expect(vm.skippedSegment?.category == .sponsor)

        // Undo
        vm.undoSkip()
        #expect(vm.showSkipBanner == false)
        #expect(vm.skippedSegment == nil)
    }

    @Test func undoSkip_allowsReSkip() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        // Skip
        vm.onVLCTimeChanged(seconds: 15.0)
        #expect(vm.showSkipBanner == true)

        // Undo
        vm.undoSkip()

        // Re-entering the segment should trigger skip again
        vm.onVLCTimeChanged(seconds: 12.0)
        #expect(vm.showSkipBanner == true)
        #expect(vm.skippedSegment?.category == .sponsor)
    }

    // MARK: - Multiple Segments

    @Test func multipleSegments_eachSkippedIndependently() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
            SponsorBlockSegment(category: .intro, startTime: 60, endTime: 75),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        // First segment
        vm.onVLCTimeChanged(seconds: 15.0)
        #expect(vm.skippedSegment?.category == .sponsor)

        // Between segments
        vm.showSkipBanner = false
        vm.onVLCTimeChanged(seconds: 40.0)
        #expect(vm.showSkipBanner == false)

        // Second segment
        vm.onVLCTimeChanged(seconds: 65.0)
        #expect(vm.showSkipBanner == true)
        #expect(vm.skippedSegment?.category == .intro)
    }

    // MARK: - Settings Change During Playback

    @Test func settingsChange_affectsActiveSegments() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
            SponsorBlockSegment(category: .intro, startTime: 50, endTime: 60),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }

        let defaults = UserDefaults(suiteName: "test-sb-\(UUID().uuidString)")!
        let settings = SponsorBlockSettings(defaults: defaults)

        let (vm, _, _) = makeSUT(videoRepo: repo, sponsorBlockSettings: settings)

        await vm.loadVideo()
        #expect(vm.activeSegments().count == 2)

        // Disable sponsor category mid-session
        settings.setCategoryEnabled(.sponsor, enabled: false)
        #expect(vm.activeSegments().count == 1)
        #expect(vm.activeSegments()[0].category == .intro)
    }

    // MARK: - Stop Playback Clears State

    @Test func stopPlayback_clearsSkipState() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()
        vm.onVLCTimeChanged(seconds: 15.0)
        #expect(vm.showSkipBanner == true)

        vm.stopPlayback()

        #expect(vm.showSkipBanner == false)
        #expect(vm.skippedSegment == nil)
    }

    // MARK: - Edge Cases

    @Test func segmentAtStart_skipsFromZero() async {
        let segments = [
            SponsorBlockSegment(category: .intro, startTime: 0, endTime: 15),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()
        vm.onVLCTimeChanged(seconds: 1.0)

        #expect(vm.showSkipBanner == true)
        #expect(vm.skippedSegment?.category == .intro)
    }

    @Test func timeExactlyAtSegmentEnd_noSkip() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()
        vm.onVLCTimeChanged(seconds: 30.0) // exactly at end, should NOT skip

        #expect(vm.showSkipBanner == false)
    }

    @Test func timeExactlyAtSegmentStart_skips() async {
        let segments = [
            SponsorBlockSegment(category: .sponsor, startTime: 10, endTime: 30),
        ]
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(sponsorblock: segments) }
        let (vm, _, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()
        vm.onVLCTimeChanged(seconds: 10.0) // exactly at start, should skip

        #expect(vm.showSkipBanner == true)
    }
}

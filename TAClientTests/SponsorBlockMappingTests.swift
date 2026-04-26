import Foundation
import Testing
@testable import TAClient

struct SponsorBlockMappingTests {
    private let serverURL = "https://ta.example.com"

    // MARK: - SponsorBlock DTO → Model Mapping

    @Test func enabledSponsorBlock_mapsSegments() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: 1700000000,
            hasUnlocked: false,
            segments: [
                SponsorBlockSegmentDTO(
                    actionType: "skip",
                    videoDuration: 600,
                    segment: [10.0, 30.0],
                    votes: 5,
                    category: "sponsor",
                    UUID: "uuid-1",
                    locked: 0
                ),
                SponsorBlockSegmentDTO(
                    actionType: "skip",
                    videoDuration: 600,
                    segment: [120.0, 135.5],
                    votes: 3,
                    category: "intro",
                    UUID: "uuid-2",
                    locked: 1
                ),
            ]
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video != nil)
        #expect(video?.sponsorblock.count == 2)
        #expect(video?.sponsorblock[0].category == .sponsor)
        #expect(video?.sponsorblock[0].startTime == 10.0)
        #expect(video?.sponsorblock[0].endTime == 30.0)
        #expect(video?.sponsorblock[1].category == .intro)
        #expect(video?.sponsorblock[1].startTime == 120.0)
        #expect(video?.sponsorblock[1].endTime == 135.5)
    }

    @Test func disabledSponsorBlock_returnsEmpty() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: false,
            lastRefresh: 1700000000,
            hasUnlocked: nil,
            segments: [
                SponsorBlockSegmentDTO(
                    actionType: "skip",
                    videoDuration: 600,
                    segment: [10.0, 30.0],
                    votes: 5,
                    category: "sponsor",
                    UUID: "uuid-1",
                    locked: 0
                ),
            ]
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video != nil)
        #expect(video?.sponsorblock.isEmpty == true)
    }

    @Test func nullSponsorBlock_returnsEmpty() {
        let dto = makeVideoDTO(sponsorblock: nil)

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video != nil)
        #expect(video?.sponsorblock.isEmpty == true)
    }

    @Test func nonSkipActionType_filtered() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: 1700000000,
            hasUnlocked: nil,
            segments: [
                SponsorBlockSegmentDTO(
                    actionType: "mute",
                    videoDuration: 600,
                    segment: [10.0, 30.0],
                    votes: 5,
                    category: "sponsor",
                    UUID: "uuid-1",
                    locked: 0
                ),
            ]
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video?.sponsorblock.isEmpty == true)
    }

    @Test func unknownCategory_filtered() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: nil,
            hasUnlocked: nil,
            segments: [
                SponsorBlockSegmentDTO(
                    actionType: "skip",
                    videoDuration: 600,
                    segment: [10.0, 30.0],
                    votes: 0,
                    category: "unknown_category",
                    UUID: "uuid-1",
                    locked: 0
                ),
            ]
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video?.sponsorblock.isEmpty == true)
    }

    @Test func invalidSegmentTimes_filtered() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: nil,
            hasUnlocked: nil,
            segments: [
                // start > end
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: [30.0, 10.0], votes: 0, category: "sponsor", UUID: "u1", locked: 0),
                // negative start
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: [-5.0, 10.0], votes: 0, category: "sponsor", UUID: "u2", locked: 0),
                // empty segment array
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: [], votes: 0, category: "sponsor", UUID: "u3", locked: 0),
                // nil segment
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: nil, votes: 0, category: "sponsor", UUID: "u4", locked: 0),
                // single element
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: [10.0], votes: 0, category: "sponsor", UUID: "u5", locked: 0),
            ]
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video?.sponsorblock.isEmpty == true)
    }

    @Test func equalStartAndEnd_filtered() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: nil,
            hasUnlocked: nil,
            segments: [
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: [10.0, 10.0], votes: 0, category: "sponsor", UUID: "u1", locked: 0),
            ]
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video?.sponsorblock.isEmpty == true)
    }

    @Test func allCategoriesMapped() {
        let categories = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "hook", "filler"]
        let segments = categories.enumerated().map { index, cat in
            SponsorBlockSegmentDTO(
                actionType: "skip",
                videoDuration: 600,
                segment: [Double(index * 10), Double(index * 10 + 5)],
                votes: 0,
                category: cat,
                UUID: "uuid-\(index)",
                locked: 0
            )
        }

        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: nil,
            hasUnlocked: nil,
            segments: segments
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video?.sponsorblock.count == 8)
        let mappedCategories = video?.sponsorblock.map(\.category.rawValue) ?? []
        #expect(mappedCategories == categories)
    }

    @Test func missingFields_filtered() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: nil,
            hasUnlocked: nil,
            segments: [
                // missing category
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: [10.0, 20.0], votes: 0, category: nil, UUID: "u1", locked: 0),
                // missing actionType
                SponsorBlockSegmentDTO(actionType: nil, videoDuration: 600, segment: [10.0, 20.0], votes: 0, category: "sponsor", UUID: "u2", locked: 0),
            ]
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video?.sponsorblock.isEmpty == true)
    }

    @Test func emptySegmentsArray_returnsEmpty() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: nil,
            hasUnlocked: nil,
            segments: []
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video?.sponsorblock.isEmpty == true)
    }

    @Test func nullSegmentsArray_returnsEmpty() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: nil,
            hasUnlocked: nil,
            segments: nil
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video?.sponsorblock.isEmpty == true)
    }

    @Test func mixedValidAndInvalid_onlyValidMapped() {
        let dto = makeVideoDTO(sponsorblock: SponsorBlockDTO(
            isEnabled: true,
            lastRefresh: nil,
            hasUnlocked: nil,
            segments: [
                // valid
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: [10.0, 30.0], votes: 5, category: "sponsor", UUID: "u1", locked: 0),
                // invalid category
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: [50.0, 60.0], votes: 0, category: "badcat", UUID: "u2", locked: 0),
                // valid
                SponsorBlockSegmentDTO(actionType: "skip", videoDuration: 600, segment: [100.0, 120.0], votes: 2, category: "outro", UUID: "u3", locked: 0),
                // mute action
                SponsorBlockSegmentDTO(actionType: "mute", videoDuration: 600, segment: [200.0, 210.0], votes: 0, category: "sponsor", UUID: "u4", locked: 0),
            ]
        ))

        let video = VideoMapper.map(dto, serverURL: serverURL)

        #expect(video?.sponsorblock.count == 2)
        #expect(video?.sponsorblock[0].category == .sponsor)
        #expect(video?.sponsorblock[1].category == .outro)
    }

    // MARK: - JSON Decoding

    @Test func jsonDecoding_sponsorBlockDTO() throws {
        let json = """
        {
            "is_enabled": true,
            "last_refresh": 1700000000,
            "has_unlocked": false,
            "segments": [
                {
                    "actionType": "skip",
                    "videoDuration": 600.0,
                    "segment": [10.5, 30.2],
                    "votes": 5,
                    "category": "sponsor",
                    "UUID": "abc-123",
                    "locked": 0
                }
            ]
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(SponsorBlockDTO.self, from: json)

        #expect(dto.isEnabled == true)
        #expect(dto.lastRefresh == 1700000000)
        #expect(dto.hasUnlocked == false)
        #expect(dto.segments?.count == 1)
        #expect(dto.segments?[0].actionType == "skip")
        #expect(dto.segments?[0].segment == [10.5, 30.2])
        #expect(dto.segments?[0].category == "sponsor")
        #expect(dto.segments?[0].UUID == "abc-123")
    }

    @Test func jsonDecoding_videoDTO_withSponsorBlock() throws {
        let json = """
        {
            "youtube_id": "test123",
            "title": "Test Video",
            "sponsorblock": {
                "is_enabled": true,
                "last_refresh": 1700000000,
                "segments": [
                    {
                        "actionType": "skip",
                        "videoDuration": 300.0,
                        "segment": [5.0, 15.0],
                        "votes": 10,
                        "category": "intro",
                        "UUID": "xyz",
                        "locked": 1
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(VideoDTO.self, from: json)

        #expect(dto.youtubeId == "test123")
        #expect(dto.sponsorblock?.isEnabled == true)
        #expect(dto.sponsorblock?.segments?.count == 1)
        #expect(dto.sponsorblock?.segments?[0].category == "intro")
    }

    @Test func jsonDecoding_videoDTO_withoutSponsorBlock() throws {
        let json = """
        {
            "youtube_id": "test456",
            "title": "Test Video 2"
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(VideoDTO.self, from: json)

        #expect(dto.youtubeId == "test456")
        #expect(dto.sponsorblock == nil)
    }

    @Test func jsonDecoding_videoDTO_nullSponsorBlock() throws {
        let json = """
        {
            "youtube_id": "test789",
            "title": "Test Video 3",
            "sponsorblock": null
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(VideoDTO.self, from: json)

        #expect(dto.youtubeId == "test789")
        #expect(dto.sponsorblock == nil)
    }

    // MARK: - SponsorCategory

    @Test func sponsorCategoryRawValues() {
        #expect(SponsorCategory(rawValue: "sponsor") == .sponsor)
        #expect(SponsorCategory(rawValue: "selfpromo") == .selfpromo)
        #expect(SponsorCategory(rawValue: "interaction") == .interaction)
        #expect(SponsorCategory(rawValue: "intro") == .intro)
        #expect(SponsorCategory(rawValue: "outro") == .outro)
        #expect(SponsorCategory(rawValue: "preview") == .preview)
        #expect(SponsorCategory(rawValue: "hook") == .hook)
        #expect(SponsorCategory(rawValue: "filler") == .filler)
        #expect(SponsorCategory(rawValue: "invalid") == nil)
    }

    @Test func sponsorCategoryAllCases_has8() {
        #expect(SponsorCategory.allCases.count == 8)
    }

    // MARK: - Helpers

    private func makeVideoDTO(sponsorblock: SponsorBlockDTO?) -> VideoDTO {
        VideoDTO(
            youtubeId: "test-vid",
            title: "Test",
            description: nil,
            published: nil,
            dateDownloaded: nil,
            active: true,
            channel: nil,
            vidThumbUrl: "/thumb.jpg",
            mediaUrl: "/media.mp4",
            mediaSize: 1000,
            player: nil,
            stats: nil,
            vidType: "videos",
            category: nil,
            tags: nil,
            streams: nil,
            sponsorblock: sponsorblock,
            playlist: nil
        )
    }
}

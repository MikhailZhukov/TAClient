import Foundation
import Testing
@testable import TAClient

struct PlaylistMappingTests {
    private let serverURL = "https://ta.example.com"

    // MARK: - PlaylistMapper

    @Test func minimalValidDTO_returnsPlaylist() {
        let dto = PlaylistDTO(
            playlistId: "pl1", playlistName: "My Playlist",
            playlistChannel: nil, playlistChannelId: nil,
            playlistType: nil, playlistSubscribed: nil,
            playlistThumbnail: nil, playlistDescription: nil,
            playlistEntries: nil
        )
        let playlist = PlaylistMapper.map(dto, serverURL: serverURL)
        #expect(playlist != nil)
        #expect(playlist?.playlistId == "pl1")
        #expect(playlist?.playlistName == "My Playlist")
        #expect(playlist?.playlistType == .regular)
        #expect(playlist?.playlistSubscribed == false)
        #expect(playlist?.playlistEntries.isEmpty == true)
    }

    @Test func missingId_returnsNil() {
        let dto = PlaylistDTO(
            playlistId: nil, playlistName: "Test",
            playlistChannel: nil, playlistChannelId: nil,
            playlistType: nil, playlistSubscribed: nil,
            playlistThumbnail: nil, playlistDescription: nil,
            playlistEntries: nil
        )
        #expect(PlaylistMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func missingName_returnsNil() {
        let dto = PlaylistDTO(
            playlistId: "pl1", playlistName: nil,
            playlistChannel: nil, playlistChannelId: nil,
            playlistType: nil, playlistSubscribed: nil,
            playlistThumbnail: nil, playlistDescription: nil,
            playlistEntries: nil
        )
        #expect(PlaylistMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func fullDTO_allFieldsMapped() {
        let entries = [
            PlaylistEntryDTO(youtubeId: "vid1", title: "Video 1", uploader: "Creator", idx: 0, downloaded: true),
            PlaylistEntryDTO(youtubeId: "vid2", title: "Video 2", uploader: nil, idx: 1, downloaded: false),
        ]
        let dto = PlaylistDTO(
            playlistId: "pl1", playlistName: "Full Playlist",
            playlistChannel: "Channel Name", playlistChannelId: "ch1",
            playlistType: "custom", playlistSubscribed: true,
            playlistThumbnail: "/cache/pl-thumb.jpg",
            playlistDescription: "A nice playlist",
            playlistEntries: entries
        )

        let playlist = PlaylistMapper.map(dto, serverURL: serverURL)!
        #expect(playlist.playlistId == "pl1")
        #expect(playlist.playlistName == "Full Playlist")
        #expect(playlist.playlistChannel == "Channel Name")
        #expect(playlist.playlistChannelId == "ch1")
        #expect(playlist.playlistType == .custom)
        #expect(playlist.playlistSubscribed == true)
        #expect(playlist.playlistThumbnail == "\(serverURL)/cache/pl-thumb.jpg")
        #expect(playlist.playlistDescription == "A nice playlist")
        #expect(playlist.playlistEntries.count == 2)
        #expect(playlist.playlistEntries[0].youtubeId == "vid1")
        #expect(playlist.playlistEntries[0].downloaded == true)
        #expect(playlist.playlistEntries[1].uploader == nil)
    }

    @Test func relativeThumbnail_prependsServerURL() {
        let dto = PlaylistDTO(
            playlistId: "pl1", playlistName: "Test",
            playlistChannel: nil, playlistChannelId: nil,
            playlistType: nil, playlistSubscribed: nil,
            playlistThumbnail: "/cache/thumb.jpg",
            playlistDescription: nil, playlistEntries: nil
        )
        let playlist = PlaylistMapper.map(dto, serverURL: serverURL)
        #expect(playlist?.playlistThumbnail == "\(serverURL)/cache/thumb.jpg")
    }

    @Test func absoluteThumbnail_keptAsIs() {
        let dto = PlaylistDTO(
            playlistId: "pl1", playlistName: "Test",
            playlistChannel: nil, playlistChannelId: nil,
            playlistType: nil, playlistSubscribed: nil,
            playlistThumbnail: "https://cdn.example.com/thumb.jpg",
            playlistDescription: nil, playlistEntries: nil
        )
        let playlist = PlaylistMapper.map(dto, serverURL: serverURL)
        #expect(playlist?.playlistThumbnail == "https://cdn.example.com/thumb.jpg")
    }

    @Test func customType_mappedCorrectly() {
        let dto = PlaylistDTO(
            playlistId: "pl1", playlistName: "Test",
            playlistChannel: nil, playlistChannelId: nil,
            playlistType: "custom", playlistSubscribed: nil,
            playlistThumbnail: nil, playlistDescription: nil,
            playlistEntries: nil
        )
        #expect(PlaylistMapper.map(dto, serverURL: serverURL)?.playlistType == .custom)
    }

    @Test func unknownType_defaultsToRegular() {
        let dto = PlaylistDTO(
            playlistId: "pl1", playlistName: "Test",
            playlistChannel: nil, playlistChannelId: nil,
            playlistType: "unknown", playlistSubscribed: nil,
            playlistThumbnail: nil, playlistDescription: nil,
            playlistEntries: nil
        )
        #expect(PlaylistMapper.map(dto, serverURL: serverURL)?.playlistType == .regular)
    }

    // MARK: - Entry Mapping

    @Test func entry_missingId_filtered() {
        let entry = PlaylistEntryDTO(youtubeId: nil, title: "Test", uploader: nil, idx: 0, downloaded: true)
        #expect(PlaylistMapper.mapEntry(entry) == nil)
    }

    @Test func entry_missingTitle_filtered() {
        let entry = PlaylistEntryDTO(youtubeId: "vid1", title: nil, uploader: nil, idx: 0, downloaded: true)
        #expect(PlaylistMapper.mapEntry(entry) == nil)
    }

    @Test func entry_minimalValid() {
        let entry = PlaylistEntryDTO(youtubeId: "vid1", title: "Video", uploader: nil, idx: nil, downloaded: nil)
        let mapped = PlaylistMapper.mapEntry(entry)
        #expect(mapped != nil)
        #expect(mapped?.youtubeId == "vid1")
        #expect(mapped?.idx == 0)
        #expect(mapped?.downloaded == false)
    }

    // MARK: - JSON Decoding

    @Test func jsonDecoding_playlistDTO() throws {
        let json = """
        {
            "playlist_id": "pl123",
            "playlist_name": "My Playlist",
            "playlist_channel": "Creator",
            "playlist_channel_id": "ch1",
            "playlist_type": "regular",
            "playlist_subscribed": true,
            "playlist_thumbnail": "/thumb.jpg",
            "playlist_description": "desc",
            "playlist_entries": [
                {"youtube_id": "v1", "title": "Vid 1", "uploader": "A", "idx": 0, "downloaded": true}
            ]
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(PlaylistDTO.self, from: json)
        #expect(dto.playlistId == "pl123")
        #expect(dto.playlistName == "My Playlist")
        #expect(dto.playlistType == "regular")
        #expect(dto.playlistSubscribed == true)
        #expect(dto.playlistEntries?.count == 1)
    }

    @Test func jsonDecoding_playlistListResponse() throws {
        let json = """
        {
            "data": [
                {"playlist_id": "pl1", "playlist_name": "P1"},
                {"playlist_id": "pl2", "playlist_name": "P2"}
            ],
            "paginate": {"current_page": 1, "last_page": 3}
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(PlaylistListResponseDTO.self, from: json)
        #expect(response.data?.count == 2)
        #expect(response.paginate?.currentPage == 1)
        #expect(response.paginate?.lastPage == 3)
    }

    // MARK: - Request DTOs

    @Test func createCustomPlaylistDTO_encoding() throws {
        let dto = CreateCustomPlaylistDTO(playlistName: "My Custom")
        let data = try JSONEncoder().encode(dto)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["playlist_name"] as? String == "My Custom")
    }

    @Test func playlistCustomActionDTO_encoding() throws {
        let dto = PlaylistCustomActionDTO(action: "create", videoId: "vid1")
        let data = try JSONEncoder().encode(dto)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["action"] as? String == "create")
        #expect(json?["video_id"] as? String == "vid1")
    }
}

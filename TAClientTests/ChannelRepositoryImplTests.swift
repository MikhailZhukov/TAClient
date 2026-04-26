import Testing
import Foundation
@testable import TAClient

extension DataLayerSuite {
@Suite(.serialized) struct ChannelRepositoryImplTests {

    init() {
        MockResponse.tearDown()
    }

    private func makeRepo() -> (ChannelRepositoryImpl, AuthState) {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = ChannelRepositoryImpl(apiClient: client, authState: authState)
        return (repo, authState)
    }

    // MARK: - getChannel

    @Test func getChannel_success_mapsAllFields() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "channel_id": "UCxyz",
            "channel_name": "Test Channel",
            "channel_thumb_url": "/cache/ch-thumb.jpg",
            "channel_banner_url": "/cache/ch-banner.jpg",
            "channel_description": "A great channel",
            "channel_subscribed": true,
            "channel_subs": 5000
        ] as [String: Any])

        let channel = try await repo.getChannel(id: "UCxyz")
        #expect(channel.channelId == "UCxyz")
        #expect(channel.channelName == "Test Channel")
        #expect(channel.channelThumbUrl == "https://ta.example.com/cache/ch-thumb.jpg")
        #expect(channel.channelBannerUrl == "https://ta.example.com/cache/ch-banner.jpg")
        #expect(channel.channelDescription == "A great channel")
        #expect(channel.channelSubscribed == true)
        #expect(channel.channelSubs == 5000)
        authState.handleUnauthorized()
    }

    @Test func getChannel_missingRequiredFields_throwsDecoding() async {
        let (repo, authState) = makeRepo()
        // Missing channel_id and channel_name → mapper returns nil → repo throws .decoding
        MockResponse.setUp(json: ["channel_description": "no id"] as [String: Any])

        do {
            _ = try await repo.getChannel(id: "UCxyz")
            Issue.record("Expected AppError.decoding")
        } catch let error as AppError {
            if case .decoding = error {} else {
                Issue.record("Expected .decoding, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        authState.handleUnauthorized()
    }

    @Test func setSubscribed_sendsPostWithBody() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.setSubscribed(channelId: "UCxyz", subscribed: false)

        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/channel/UCxyz") == true)
        authState.handleUnauthorized()
    }

    @Test func getChannel_404_throwsServerError() async {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 404, json: ["detail": "Not found"])

        do {
            _ = try await repo.getChannel(id: "UCxyz")
            Issue.record("Expected AppError.serverError")
        } catch let error as AppError {
            if case .serverError(let code, _) = error {
                #expect(code == 404)
            } else {
                Issue.record("Expected .serverError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        authState.handleUnauthorized()
    }
}
}

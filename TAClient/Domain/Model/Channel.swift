import Foundation

struct Channel: Identifiable, Hashable {
    var id: String { channelId }

    let channelId: String
    let channelName: String
    let channelThumbUrl: String?
    let channelBannerUrl: String?
    let channelDescription: String?
    var channelSubscribed: Bool
    let channelSubs: Int
}

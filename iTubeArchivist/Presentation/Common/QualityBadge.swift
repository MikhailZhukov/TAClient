import SwiftUI

struct QualityBadge: View {
    let streams: [StreamInfo]

    var body: some View {
        if let label = qualityLabel {
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var qualityLabel: String? {
        guard let videoStream = streams.first(where: { $0.type == "video" }),
              let height = videoStream.height else {
            return nil
        }

        switch height {
        case 2160...: return "4K"
        case 1440...: return "1440p"
        case 1080...: return "1080p"
        case 720...: return "720p"
        case 480...: return "480p"
        case 360...: return "360p"
        default: return "\(height)p"
        }
    }
}

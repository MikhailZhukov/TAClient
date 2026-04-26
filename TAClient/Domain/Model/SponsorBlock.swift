import Foundation

struct SponsorBlockSegment: Hashable {
    let category: SponsorCategory
    let startTime: Double
    let endTime: Double
}

enum SponsorCategory: String, CaseIterable, Identifiable {
    case sponsor
    case selfpromo
    case interaction
    case intro
    case outro
    case preview
    case hook
    case filler

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sponsor: String(localized: "sb_sponsor")
        case .selfpromo: String(localized: "sb_selfpromo")
        case .interaction: String(localized: "sb_interaction")
        case .intro: String(localized: "sb_intro")
        case .outro: String(localized: "sb_outro")
        case .preview: String(localized: "sb_preview")
        case .hook: String(localized: "sb_hook")
        case .filler: String(localized: "sb_filler")
        }
    }
}

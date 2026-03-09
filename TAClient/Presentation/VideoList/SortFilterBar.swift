import SwiftUI

enum SortOption: String, CaseIterable {
    case downloaded
    case published
    case views
    case likes
    case duration
    case mediasize

    var label: String {
        switch self {
        case .downloaded: return String(localized: "sort_downloaded")
        case .published: return String(localized: "sort_published")
        case .views: return String(localized: "sort_views")
        case .likes: return String(localized: "sort_likes")
        case .duration: return String(localized: "sort_duration")
        case .mediasize: return String(localized: "sort_mediasize")
        }
    }
}

enum WatchFilter: String, CaseIterable {
    case all
    case unwatched
    case watched
    case `continue`

    var label: String {
        switch self {
        case .all: return String(localized: "filter_all")
        case .unwatched: return String(localized: "filter_unwatched")
        case .watched: return String(localized: "filter_watched")
        case .continue: return String(localized: "filter_continue")
        }
    }

    var queryValue: String? {
        switch self {
        case .all: return nil
        case .unwatched: return "unwatched"
        case .watched: return "watched"
        case .continue: return "continue"
        }
    }
}

enum VidTypeFilter: String, CaseIterable {
    case all
    case videos
    case shorts
    case streams

    var label: String {
        switch self {
        case .all: return String(localized: "vid_type_all")
        case .videos: return String(localized: "vid_type_videos")
        case .shorts: return String(localized: "vid_type_shorts")
        case .streams: return String(localized: "vid_type_streams")
        }
    }

    var queryValue: String? {
        switch self {
        case .all: return nil
        case .videos: return "videos"
        case .shorts: return "shorts"
        case .streams: return "streams"
        }
    }
}

struct SortFilterMenu: View {
    @Binding var sortOption: SortOption
    @Binding var sortAscending: Bool
    @Binding var watchFilter: WatchFilter

    var body: some View {
        Menu {
            // Sort section
            Section(String(localized: "sort_section_title")) {
                Picker(selection: $sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Text(String(localized: "sort_section_title"))
                }

                Button {
                    sortAscending.toggle()
                } label: {
                    Label(
                        String(localized: sortAscending ? "sort_ascending" : "sort_descending"),
                        systemImage: sortAscending ? "arrow.up" : "arrow.down"
                    )
                }
            }

            // Filter section
            Section(String(localized: "filter_section_title")) {
                Picker(selection: $watchFilter) {
                    ForEach(WatchFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                } label: {
                    Text(String(localized: "filter_section_title"))
                }
            }
        } label: {
            Image(systemName: hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(String(localized: "sort_filter_button"))
    }

    private var hasActiveFilters: Bool {
        sortOption != .downloaded || sortAscending || watchFilter != .unwatched
    }
}

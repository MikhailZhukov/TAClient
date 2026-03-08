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

struct SortFilterBar: View {
    @Binding var sortOption: SortOption
    @Binding var sortAscending: Bool
    @Binding var watchFilter: WatchFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Sort dropdown
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button {
                            sortOption = option
                        } label: {
                            HStack {
                                Text(option.label)
                                if sortOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(sortOption.label)
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
                }

                // Sort order toggle
                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.subheadline)
                        .padding(8)
                        .background(.fill.tertiary)
                        .clipShape(Circle())
                }
                .accessibilityLabel(String(localized: sortAscending ? "sort_ascending" : "sort_descending"))

                Divider()
                    .frame(height: 24)

                // Watch filter chips
                ForEach(WatchFilter.allCases, id: \.self) { filter in
                    Button {
                        watchFilter = filter
                    } label: {
                        Text(filter.label)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(watchFilter == filter ? Color.accentColor : Color(.systemFill))
                            .foregroundStyle(watchFilter == filter ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

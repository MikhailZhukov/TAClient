import SwiftUI

struct AddToPlaylistSheet: View {
    let viewModel: VideoDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCreateAlert = false
    @State private var newPlaylistName = ""

    private var regularPlaylists: [Playlist] {
        viewModel.allPlaylists.filter { $0.playlistType == .regular }
    }

    private var customPlaylists: [Playlist] {
        viewModel.allPlaylists.filter { $0.playlistType == .custom }
    }

    private var memberRegularPlaylists: [Playlist] {
        regularPlaylists.filter { viewModel.isVideoInPlaylist($0.playlistId) }
    }

    private var hasContent: Bool {
        !customPlaylists.isEmpty || !memberRegularPlaylists.isEmpty
    }

    var body: some View {
        NavigationStack {
            playlistContent
                .navigationTitle(String(localized: "video_add_to_playlist"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showCreateAlert = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(String(localized: "playlist_create"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "done")) {
                            dismiss()
                        }
                    }
                }
                .alert(String(localized: "playlist_create"), isPresented: $showCreateAlert) {
                    TextField(String(localized: "playlist_name_placeholder"), text: $newPlaylistName)
                    Button(String(localized: "cancel"), role: .cancel) {
                        newPlaylistName = ""
                    }
                    Button(String(localized: "playlist_create_confirm")) {
                        let name = newPlaylistName
                        newPlaylistName = ""
                        Task { await viewModel.createPlaylistAndAddVideo(name: name) }
                    }
                }
        }
        .task {
            await viewModel.loadPlaylists()
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var playlistContent: some View {
        if !hasContent {
            VStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "playlist_no_custom"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !customPlaylists.isEmpty {
                    Section(String(localized: "playlist_filter_custom")) {
                        ForEach(customPlaylists) { playlist in
                            customPlaylistRow(playlist)
                        }
                    }
                }

                if !memberRegularPlaylists.isEmpty {
                    Section(String(localized: "playlist_filter_regular")) {
                        ForEach(memberRegularPlaylists) { playlist in
                            regularPlaylistRow(playlist)
                        }
                    }
                }
            }
        }
    }

    private func customPlaylistRow(_ playlist: Playlist) -> some View {
        let inPlaylist = viewModel.isVideoInPlaylist(playlist.playlistId)
        return Button {
            Task { await viewModel.toggleVideoInPlaylist(playlist.playlistId) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.playlistName)
                        .font(.body)
                    Text(String(localized: "playlist_entry_count \(playlist.playlistEntries.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: inPlaylist ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(inPlaylist ? Color.accentColor : Color(.tertiaryLabel))
            }
        }
        .accessibilityLabel("\(playlist.playlistName), \(inPlaylist ? String(localized: "playlist_video_added") : String(localized: "playlist_video_not_added"))")
    }

    private func regularPlaylistRow(_ playlist: Playlist) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.playlistName)
                    .font(.body)
                if !playlist.playlistChannel.isEmpty {
                    Text(playlist.playlistChannel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .accessibilityLabel("\(playlist.playlistName), \(String(localized: "playlist_video_added"))")
    }
}

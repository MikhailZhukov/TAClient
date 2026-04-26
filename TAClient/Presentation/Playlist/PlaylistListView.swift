import SwiftUI

struct PlaylistListView: View {
    @State var viewModel: PlaylistListViewModel

    var body: some View {
        @Bindable var viewModel = viewModel

        Group {
            if viewModel.isLoading && viewModel.playlists.isEmpty {
                LoadingView()
            } else if let error = viewModel.errorMessage, viewModel.playlists.isEmpty {
                ErrorView(message: error) {
                    Task { await viewModel.loadPlaylists() }
                }
            } else if viewModel.playlists.isEmpty {
                Text(String(localized: "playlist_list_empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.playlists) { playlist in
                            Button {
                                viewModel.navigateToPlaylist(playlist.playlistId)
                            } label: {
                                PlaylistRow(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { await viewModel.deletePlaylist(playlist.playlistId, deleteVideos: false) }
                                } label: {
                                    Label(String(localized: "playlist_delete"), systemImage: "trash")
                                }
                            }
                        }

                        if viewModel.isLoadingMore {
                            ProgressView()
                                .padding()
                        }

                        Color.clear.frame(height: 1)
                            .onAppear {
                                Task { await viewModel.loadMoreIfNeeded() }
                            }
                    }
                    .padding()
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationTitle(String(localized: "playlist_list_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Menu {
                        ForEach(PlaylistTypeFilter.allCases, id: \.self) { filter in
                            Button {
                                viewModel.typeFilter = filter
                                viewModel.onFilterChanged()
                            } label: {
                                if viewModel.typeFilter == filter {
                                    Label(filter.label, systemImage: "checkmark")
                                } else {
                                    Text(filter.label)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(String(localized: "playlist_filter_title"))

                    Button {
                        viewModel.showCreateDialog = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "playlist_create"))
                }
            }
        }
        .alert(String(localized: "playlist_create"), isPresented: $viewModel.showCreateDialog) {
            TextField(String(localized: "playlist_name_placeholder"), text: $viewModel.newPlaylistName)
            Button(String(localized: "cancel"), role: .cancel) {
                viewModel.newPlaylistName = ""
            }
            Button(String(localized: "playlist_create_confirm")) {
                Task { await viewModel.createCustomPlaylist() }
            }
        }
        .task {
            if viewModel.playlists.isEmpty {
                await viewModel.loadPlaylists()
            }
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedAsyncImage(url: playlist.playlistThumbnail)
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
                .frame(width: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.playlistName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                if !playlist.playlistChannel.isEmpty {
                    Text(playlist.playlistChannel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(playlist.playlistType == .custom
                         ? String(localized: "playlist_type_custom")
                         : String(localized: "playlist_type_regular"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(String(localized: "playlist_entry_count \(playlist.playlistEntries.count)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.playlistName), \(playlist.playlistChannel)")
    }
}

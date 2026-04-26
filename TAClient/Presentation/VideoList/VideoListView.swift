import SwiftUI

struct VideoListView: View {
    @State var viewModel: VideoListViewModel
    @Environment(AuthState.self) private var authState
    @State private var showLogoutConfirmation = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        @Bindable var viewModel = viewModel

        Group {
            if viewModel.isLoading && viewModel.videos.isEmpty {
                LoadingView()
            } else if let error = viewModel.errorMessage, viewModel.videos.isEmpty {
                ErrorView(message: error) {
                    Task { await viewModel.refresh() }
                }
            } else if viewModel.videos.isEmpty {
                Text(String(localized: "video_list_empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        AdaptiveVideoGrid(
                            videos: viewModel.videos,
                            onVideoTap: { videoId in
                                viewModel.navigateToVideo(videoId)
                            },
                            onChannelTap: { channelId in
                                viewModel.navigateToChannel(channelId)
                            },
                            onToggleWatched: { videoId in
                                Task { await viewModel.toggleWatched(videoId: videoId) }
                            },
                            onNearEnd: {
                                Task { await viewModel.loadMoreIfNeeded() }
                            },
                            isSelecting: viewModel.isSelecting,
                            selectedIds: viewModel.selectedVideoIds,
                            onEnterSelection: { videoId in
                                viewModel.enterSelectionMode(videoId: videoId)
                            },
                            onToggleSelection: { videoId in
                                viewModel.toggleSelection(videoId: videoId)
                            }
                        )
                        .id(viewModel.refreshCount)

                        if viewModel.isLoadingMore {
                            ProgressView()
                                .padding()
                        }
                    }
                    .padding(.vertical)
                }
                .geometryGroup()
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.isSelecting {
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "selection_count \(viewModel.selectedVideoIds.count)"))
                        .font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if viewModel.showMarkWatched {
                            Button {
                                Task { await viewModel.batchSetWatched(true) }
                            } label: {
                                Image(systemName: "eye")
                            }
                            .accessibilityLabel(String(localized: "video_mark_watched"))
                        }

                        if viewModel.showMarkUnwatched {
                            Button {
                                Task { await viewModel.batchSetWatched(false) }
                            } label: {
                                Image(systemName: "eye.slash")
                            }
                            .accessibilityLabel(String(localized: "video_mark_unwatched"))
                        }

                        if authState.isPrivileged {
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel(String(localized: "selection_delete"))
                        }

                        Button {
                            viewModel.selectAll()
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .accessibilityLabel(String(localized: "selection_select_all"))

                        Button(String(localized: "cancel")) {
                            viewModel.cancelSelection()
                        }
                    }
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(VidTypeFilter.allCases, id: \.self) { type in
                            Button {
                                viewModel.setVidType(type)
                            } label: {
                                if viewModel.vidTypeFilter == type {
                                    Label(type.label, systemImage: "checkmark")
                                } else {
                                    Text(type.label)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(viewModel.vidTypeFilter == .all
                                 ? String(localized: "video_list_title")
                                 : viewModel.vidTypeFilter.label)
                                .font(.title2)
                                .fontWeight(.bold)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .fixedSize()
                    }
                    .accessibilityLabel(String(localized: "vid_type_section_title"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        SortFilterMenu(
                            sortOption: $viewModel.sortOption,
                            sortAscending: $viewModel.sortAscending,
                            watchFilter: $viewModel.watchFilter
                        )

                        Button {
                            viewModel.navigateToPlaylists()
                        } label: {
                            Image(systemName: "music.note.list")
                        }
                        .accessibilityLabel(String(localized: "playlist_list_title"))

                        Button {
                            viewModel.navigateToDownloadQueue()
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .overlay(alignment: .topTrailing) {
                                    if viewModel.hasActiveDownloads {
                                        Circle()
                                            .fill(Color.blue)
                                            .frame(width: 8, height: 8)
                                            .offset(x: 2, y: -2)
                                    }
                                }
                        }
                        .accessibilityLabel(String(localized: "download_queue_title"))

                        Button {
                            viewModel.navigateToSearch()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel(String(localized: "search_hint"))

                        Button {
                            viewModel.navigateToSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel(String(localized: "settings_title"))

                        Button {
                            showLogoutConfirmation = true
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        .accessibilityLabel(String(localized: "video_list_logout"))
                    }
                }
            }
        }
        .task {
            if viewModel.videos.isEmpty {
                await viewModel.loadVideos()
            }
            await viewModel.checkActiveDownloads()
        }
        .onChange(of: viewModel.sortOption) {
            Task { await viewModel.onSortOrFilterChanged() }
        }
        .onChange(of: viewModel.sortAscending) {
            Task { await viewModel.onSortOrFilterChanged() }
        }
        .onChange(of: viewModel.watchFilter) {
            Task { await viewModel.onSortOrFilterChanged() }
        }
        .onChange(of: viewModel.router.deletedVideoIds) {
            viewModel.removeDeletedVideos()
        }
        .onChange(of: viewModel.router.watchedChanges) {
            viewModel.applyWatchedChanges()
        }
        .confirmationDialog(
            String(localized: "video_list_logout"),
            isPresented: $showLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "video_list_logout"), role: .destructive) {
                viewModel.logout()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "selection_delete_confirm \(viewModel.selectedVideoIds.count)"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "video_detail_delete"), role: .destructive) {
                Task { await viewModel.batchDelete() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }
}

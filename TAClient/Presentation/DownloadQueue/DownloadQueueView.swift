import SwiftUI

struct DownloadQueueView: View {
    @State var viewModel: DownloadQueueViewModel
    @Environment(AuthState.self) private var authState

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.downloadProgress.isEmpty {
                VStack(spacing: 6) {
                    ForEach(viewModel.downloadProgress, id: \.id) { info in
                        TaskNotificationBanner(info: info)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            if let error = viewModel.errorMessage, !viewModel.items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                    Spacer()
                    Button {
                        viewModel.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(String(localized: "dismiss"))
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.fill.tertiary)
            }

            if viewModel.isLoading && viewModel.items.isEmpty {
                LoadingView()
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                ErrorView(message: error) {
                    Task { await viewModel.refresh() }
                }
            } else if viewModel.items.isEmpty && !viewModel.isLoading && viewModel.downloadProgress.isEmpty {
                Text(String(localized: "download_queue_empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.items, id: \.id) { item in
                        DownloadItemRow(item: item)
                            .onAppear {
                                if let index = viewModel.items.firstIndex(where: { $0.id == item.id }),
                                   index >= viewModel.items.count - 5 {
                                    Task { await viewModel.loadMoreIfNeeded() }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteItem(videoId: item.youtubeId) }
                                } label: {
                                    Label(String(localized: "download_action_delete"), systemImage: "trash")
                                }

                                if viewModel.filter == "pending" {
                                    Button {
                                        Task { await viewModel.updateStatus(videoId: item.youtubeId, status: "ignore") }
                                    } label: {
                                        Label(String(localized: "download_action_ignore"), systemImage: "eye.slash")
                                    }
                                    .tint(.orange)
                                } else {
                                    Button {
                                        Task { await viewModel.updateStatus(videoId: item.youtubeId, status: "pending") }
                                    } label: {
                                        Label(String(localized: "download_action_pending"), systemImage: "arrow.down.circle")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { await viewModel.downloadItem(videoId: item.youtubeId) }
                                } label: {
                                    Label(String(localized: "download_action_download"), systemImage: "arrow.down.circle.fill")
                                }
                                .tint(.green)
                            }
                    }
                    if viewModel.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .listStyle(.plain)
                .animation(.default, value: viewModel.items)
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        // Animate the progress block's appearance/disappearance only on batch
        // start/finish. The block stays fully absent (no reserved empty space) when
        // idle because it renders only when `downloadProgress` is non-empty.
        .animation(.default, value: viewModel.downloadProgress.isEmpty)
        .geometryGroup()
        .safeAreaInset(edge: .top) {
            if authState.isPrivileged {
            HStack(spacing: 8) {
                TextField(String(localized: "download_add_placeholder"), text: Bindable(viewModel).addInput)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        Task { await viewModel.addToQueue() }
                    }

                Button {
                    Task { await viewModel.addToQueue() }
                } label: {
                    if viewModel.isAdding {
                        ProgressView()
                    } else {
                        Text(String(localized: "download_add_button"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.addInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isAdding)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            }
        }
        .navigationTitle(String(localized: "download_queue_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if viewModel.downloadProgress.contains(where: { $0.canStop }) {
                    Button {
                        Task { await viewModel.stopCurrentDownload() }
                    } label: {
                        Label(String(localized: "download_stop_button"), systemImage: "stop.fill")
                    }
                    .tint(.red)
                } else {
                    Button {
                        Task { await viewModel.startDownload() }
                    } label: {
                        if viewModel.isStartingDownload {
                            ProgressView()
                        } else {
                            Label(String(localized: "download_start_button"), systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .disabled(viewModel.isStartingDownload || viewModel.filter != "pending" || viewModel.items.isEmpty)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if authState.isPrivileged {
                    Button {
                        Task { await viewModel.rescanSubscriptions() }
                    } label: {
                        if viewModel.isRescanningSubscriptions {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(viewModel.isRescanningSubscriptions)
                    .accessibilityLabel(String(localized: "download_rescan_button"))
                }

                Picker(String(localized: "download_queue_title"), selection: Bindable(viewModel).filter) {
                    Text(String(localized: "download_filter_pending")).tag("pending")
                    Text(String(localized: "download_filter_ignore")).tag("ignore")
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.loadDownloads()
            }
            await viewModel.checkNotifications()
        }
        .onDisappear {
            viewModel.stopPolling()
        }
        .onChange(of: viewModel.filter) {
            Task { await viewModel.onFilterChanged() }
        }
    }
}

private struct DownloadItemRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedAsyncImage(url: item.thumbUrl)
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Text(item.channelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if !item.duration.isEmpty {
                        Text(item.duration)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !item.published.isEmpty {
                        Text(item.published)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = item.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TaskNotificationBanner: View {
    let info: TaskNotification

    // Non-breaking space placeholder keeps the message row's height reserved (at the
    // same `.caption` text style) when there is no message to show.
    private var messageText: String {
        if let last = info.messages.last, !last.isEmpty {
            return last
        }
        return "\u{00A0}"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if info.isError {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(info.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                if !info.isError {
                    Text("\(Int(info.progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // Always render the message row (using a non-breaking space placeholder
            // when empty) so the banner keeps a constant height tick-to-tick as
            // messages change. lineLimit(1) caps it to a single line.
            Text(messageText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Always reserve the progress-bar row's vertical space. On error the bar
            // is hidden (but its space is kept) so toggling error state does not resize.
            ProgressView(value: info.isError ? 0 : info.progress)
                .tint(.blue)
                .opacity(info.isError ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }
}

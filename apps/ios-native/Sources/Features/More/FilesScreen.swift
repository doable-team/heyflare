import SwiftUI

// The attachment library: everything anyone has ever sent, in one list, searchable and
// filterable by type. Mirrors src/web/pages/Files.tsx, with one deliberate difference —
// the web draws a grid of thumbnails, and a phone draws rows. A grid of 4:3 tiles on a
// 390pt screen fits two columns of unreadable filenames; a row can say the filename, the
// size, who sent it and what it was about, which is what you are actually scanning for.

// MARK: - Endpoint

// MARK: - Kinds

// MARK: - Store

// MARK: - Screen

/// Every attachment, newest first. There is no `ContentCache` key for this list, so it is
/// the one library screen that can still open on a spinner; see the note in the report.
struct FilesScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Navigator.self) private var nav
    @State private var store = FilesStore()

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            TopBar(title: "Files", titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            LibrarySearchField(text: $store.query, placeholder: "Search files and subjects")
            filters

            ScrollView {
                LazyVStack(spacing: 0) {
                    content
                }
                .padding(.bottom, 24)
            }
            .refreshable { await store.refresh() }
            .overlay(alignment: .top) {
                if store.loading && store.files.isEmpty {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .task { await store.firstLoad() }
        .onChange(of: store.query) { _, _ in store.scheduleSearch() }
    }

    // MARK: Filters

    /// Eight chips on one scrolling line. A `Picker` cannot hold eight named options on a
    /// phone without truncating every one of them to three letters, and the set is worth
    /// reading: "Sheets" and "Archives" are the two people come here looking for.
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FileFilter.allCases) { option in
                    let selected = option == store.filter
                    Button {
                        guard store.filter != option else { return }
                        store.filter = option
                        Haptics.select()
                    } label: {
                        Text(option.title)
                            .font(selected ? Theme.Typography.small.weight(.semibold) : Theme.Typography.small)
                            .foregroundStyle(selected ? Theme.Colors.background : Theme.Colors.mutedForeground)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: Theme.Metrics.minTouchTarget)
                            .background(selected ? Theme.Colors.foreground : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                    .strokeBorder(selected ? Color.clear : Theme.Colors.border, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(option.title.lowercased())")
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
        }
        .padding(.bottom, 8)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        let list = store.visible

        if let error = store.error, store.files.isEmpty {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.refresh() }
            }
        } else if list.isEmpty && !store.loading && !store.hasMore {
            EmptyState(icon: "paperclip", message: emptyMessage)
        } else {
            if !list.isEmpty { summary }

            ForEach(list) { file in
                FileRow(file: file) { threadID in nav.push(.thread(threadID)) }
                    .hairline()
            }

            // Drawn whenever another page exists, even while the filter is hiding
            // everything fetched so far — that is what keeps "Sheets" paging down to the
            // one spreadsheet on page four instead of stopping at an empty screen.
            if store.hasMore {
                ProgressView()
                    .tint(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .onAppear { Task { await store.loadMore() } }
            }
        }
    }

    /// How much is here, in the same place the web puts it. Counts what has been fetched,
    /// which is why it says "so far" rather than claiming to be the whole library.
    private var summary: some View {
        Text("\(store.files.count) file\(store.files.count == 1 ? "" : "s") so far · \(ByteCountFormatter.string(fromByteCount: Int64(store.totalBytes), countStyle: .file))")
            .font(Theme.Typography.micro)
            .monospacedDigit()
            .foregroundStyle(Theme.Colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.bottom, 8)
    }

    private var emptyMessage: String {
        if !store.query.isEmpty { return "Nothing matches “\(store.query)”." }
        if store.filter != .all { return "No \(store.filter.title.lowercased()) here. Try another type." }
        return "No files yet. Attachments collect here as your mail syncs."
    }
}

// MARK: - Row

/// One file: type icon, name, size, and who sent it about what.
///
/// Two sibling buttons rather than one: the row downloads, and the 44pt button on the end
/// opens the message it came from. Nesting them would make a single tap ambiguous, and
/// dropping the second would strand the file's context — the sender and subject are
/// printed right there, and a line you can read but not follow reads as broken.
struct FileRow: View {
    let file: Attachment
    /// Called with the thread id when there is one to open.
    var onOpenThread: ((String) -> Void)?

    @State private var downloading = false
    @State private var fileURL: URL?
    @State private var sharing = false
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        HStack(spacing: 0) {
            Button {
                Task { await download() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: FileKind.of(mimeType: file.mimeType, filename: file.filename).icon)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename.isEmpty ? "attachment" : file.filename)
                            .font(Theme.Typography.bodyMedium)
                            .foregroundStyle(Theme.Colors.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(byteText)
                            .font(Theme.Typography.micro)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.mutedForeground)

                        if !provenance.isEmpty {
                            Text(provenance)
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.mutedForeground)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if downloading {
                        ProgressView().tint(Theme.Colors.mutedForeground)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                }
                .padding(.leading, Theme.Metrics.hPadding)
                .padding(.vertical, 10)
                .frame(minHeight: Theme.Metrics.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .disabled(downloading)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Downloads and shares this file")

            if let threadID = file.threadID, let onOpenThread {
                Button {
                    onOpenThread(threadID)
                } label: {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableRowStyle())
                .accessibilityLabel("Open the message this came from")
                .padding(.trailing, 4)
            }
        }
        .sheet(isPresented: $sharing) {
            if let fileURL { ShareSheet(items: [fileURL]) }
        }
    }

    private var byteText: String {
        ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
    }

    /// Sender and subject on one line, either alone if that is all there is.
    private var provenance: String {
        var parts: [String] = []
        if let from = file.from { parts.append(from.display) }
        if let subject = file.threadSubject, !subject.isEmpty { parts.append(subject) }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [file.filename.isEmpty ? "attachment" : file.filename, byteText]
        if !provenance.isEmpty { parts.append(provenance) }
        return parts.joined(separator: ", ")
    }

    /// Same route the thread view's `AttachmentRow` takes: pull the bytes through the
    /// session-carrying client, write them under the real filename, and hand the file to
    /// a share sheet, which is how anything leaves an app on iOS.
    private func download() async {
        downloading = true
        defer { downloading = false }
        do {
            let data = try await APIClient.shared.data(
                path: "/api/messages/\(file.messageID)/attachments/\(file.id)",
                query: file.accountID.map { ["account": $0] } ?? [:]
            )
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attachments", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.filename.isEmpty ? "attachment" : file.filename)
            try data.write(to: url, options: .atomic)
            fileURL = url
            sharing = true
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Could not download that file.")
        }
    }
}

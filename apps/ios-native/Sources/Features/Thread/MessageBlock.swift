import SwiftUI

/// One message inside a thread. Collapsed it is a 56pt row; expanded it shows the body.
/// A single-message thread is always expanded, because collapsing it would leave a
/// screen with nothing on it.
struct MessageBlock: View {
    let message: Message
    let expanded: Bool
    let isOnly: Bool
    let onToggle: () -> Void
    let onLink: (URL) -> Void
    let onReply: () -> Void
    let onForward: () -> Void
    /// Opens the clip sheet for this message. See `ThreadClipSheet` for why a clip starts
    /// from the whole message here rather than from a selection inside it.
    let onClip: () -> Void

    /// Seeded rather than a sliver: a `WKWebView` needs a box with height to lay out in
    /// before it can report the height it wanted, and if a measurement never arrives this
    /// is what the message is left at — a readable screenful beats a 1pt line.
    /// Starts at nothing on purpose. A web view's scroll view never reports a content
    /// size smaller than its own bounds, so seeding a comfortable height would pin the
    /// measurement to that seed and leave a short message floating in empty space.
    @State private var bodyHeight: CGFloat = 0
    @State private var showQuoted = false
    @State private var showRemoteImages = false
    @State private var showingMenu = false

    private var isOpen: Bool { expanded || isOnly }

    /// Remote images are held back by default: loading them tells the sender the mail
    /// was opened, which is the same signal the worker already strips pixels for.
    private var blockingImages: Bool { ReadingPrefs.blockRemoteImages && !showRemoteImages }

    /// The reply split from the quoted history under it.
    ///
    /// Held in state rather than recomputed: flattening the HTML is six full-string regex
    /// passes and `splitQuoted` two more per line, while `body` re-evaluates many times per
    /// message — the web view's height probe alone fires several times, and every images or
    /// quoted-text toggle adds another. Recomputing it there put that work on the main
    /// thread on every redraw, which a 300KB marketing mail turns into a visible stall.
    @State private var split: (body: String, quoted: String?) = ("", nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if isOpen { expandedBody }
        }
        .padding(.vertical, isOpen ? 12 : 0)
        .task(id: message.id) {
            // An HTML message with a snippet reads neither half of the split, so it is
            // not worth flattening one.
            guard message.htmlBody.isEmpty || message.snippet.isEmpty else { return }
            split = HTMLText.splitQuoted(
                message.textBody.isEmpty ? HTMLText.plain(from: message.htmlBody) : message.textBody
            )
        }
    }

    // MARK: Header

    private var headerRow: some View {
        Button {
            guard !isOnly else { return }
            onToggle()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                AvatarView(address: message.from, size: Theme.Metrics.smallAvatar, emphasised: message.unread)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(message.isFromMe ? "You" : message.from.display)
                            .font(Theme.Typography.bodyMedium)
                            .foregroundStyle(Theme.Colors.foreground)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(RelativeTime.short(message.sentAt))
                            .font(Theme.Typography.small)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }

                    if isOpen {
                        Text(recipientLine)
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(1)
                    } else {
                        Text(message.snippet.isEmpty ? split.body : message.snippet)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .accessibilityLabel("\(message.isFromMe ? "You" : message.from.display), \(RelativeTime.long(message.sentAt))")
        .accessibilityHint(isOnly ? "" : (isOpen ? "Collapses this message" : "Expands this message"))
    }

    private var recipientLine: String {
        let names = message.to.map(\.display)
        var line = names.isEmpty ? RelativeTime.long(message.sentAt) : "To " + names.prefix(3).joined(separator: ", ")
        if names.count > 3 { line += " and \(names.count - 3) more" }
        if !message.cc.isEmpty { line += " · Cc \(message.cc.count)" }
        return line
    }

    // MARK: Body

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if blockingImages && mentionsRemoteImages {
                imageNotice
            }

            if !message.htmlBody.isEmpty {
                MessageWebView(
                    html: message.htmlBody,
                    blockRemoteImages: blockingImages,
                    height: $bodyHeight,
                    onLink: onLink
                )
                .frame(height: max(bodyHeight, 1))
                .padding(.horizontal, Theme.Metrics.hPadding)
            } else {
                Text(split.body)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Metrics.hPadding)
            }

            // The cheap test first: quoted text is only ever folded away for the plain-text
            // body, and `&&` still evaluates its left side for every HTML message.
            if message.htmlBody.isEmpty, let quoted = split.quoted {
                quotedBlock(quoted)
            }

            if !message.visibleAttachments.isEmpty { attachments }

            if !message.trackers.isEmpty { trackerNotice }

            footer
        }
        .padding(.top, 8)
    }

    /// Cheap check: only offer the "load images" affordance when there is something to load.
    private var mentionsRemoteImages: Bool {
        message.htmlBody.range(of: "<img[^>]+src=[\"']?https?:", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var imageNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").font(.system(size: 12))
            Text("Images are blocked")
                .font(Theme.Typography.small)
            Spacer(minLength: 8)
            Button("Load") { withAnimation(Theme.Motion.quick) { showRemoteImages = true } }
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Theme.Colors.mutedForeground)
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.minTouchTarget)
        .background(Theme.Colors.muted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
        .padding(.horizontal, Theme.Metrics.hPadding)
    }

    private func quotedBlock(_ quoted: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Theme.Motion.quick) { showQuoted.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                    Text(showQuoted ? "Hide quoted text" : "Show quoted text")
                        .font(Theme.Typography.micro)
                }
                .foregroundStyle(Theme.Colors.mutedForeground)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if showQuoted {
                Text(quoted)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
    }

    private var attachments: some View {
        VStack(spacing: 6) {
            ForEach(message.visibleAttachments) { attachment in
                AttachmentRow(attachment: attachment, accountID: message.accountID)
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
    }

    private var trackerNotice: some View {
        Text("Blocked \(message.trackers.count) tracker\(message.trackers.count == 1 ? "" : "s") · \(message.trackers.prefix(2).joined(separator: ", "))")
            .font(Theme.Typography.micro)
            .foregroundStyle(Theme.Colors.mutedForeground)
            .padding(.horizontal, Theme.Metrics.hPadding)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onReply) {
                SwiftUI.Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SmallActionStyle())

            Button(action: onForward) {
                SwiftUI.Label("Forward", systemImage: "arrowshape.turn.up.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SmallActionStyle())

            // Icon only: with Reply, Forward and an unsubscribe link already in this row,
            // a third worded button pushes the row past the width of a small phone.
            Button(action: onClip) {
                Image(systemName: "scissors")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SmallActionStyle())
            .accessibilityLabel("Save a clip")

            Spacer()

            if !message.listUnsubscribe.isEmpty {
                Button("Unsubscribe") { unsubscribe() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(height: Theme.Metrics.minTouchTarget)
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
    }

    /// `List-Unsubscribe` carries either a mailto: or an https: target, sometimes both.
    /// The link is handed to the app's own link handling rather than followed silently.
    private func unsubscribe() {
        let candidates = message.listUnsubscribe
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
        guard let target = candidates.first(where: { $0.hasPrefix("https://") }) ?? candidates.first,
              let url = URL(string: target) else { return }
        onLink(url)
    }
}

/// A 34pt pill inside a 44pt target: the pill is the size the row wants to look, and the
/// padding under `contentShape` is the size a thumb needs. Hit testing follows the shape,
/// not the drawing, so both are true at once.
private struct SmallActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.Colors.foreground)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(configuration.isPressed ? Theme.Colors.accent : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
            .padding(.vertical, (Theme.Metrics.minTouchTarget - 34) / 2)
            .contentShape(Rectangle())
    }
}

/// One attachment. Tapping downloads it through the session-carrying client and hands
/// it to a share sheet, which is how a file leaves the app on iOS.
struct AttachmentRow: View {
    let attachment: Attachment
    let accountID: String?

    @State private var downloading = false
    @State private var fileURL: URL?
    @State private var sharing = false
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        Button {
            Task { await download() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.foreground)
                        .lineLimit(1)
                    Text(byteText)
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }

                Spacer(minLength: 8)

                if downloading {
                    ProgressView().tint(Theme.Colors.mutedForeground)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloading)
        .sheet(isPresented: $sharing) {
            if let fileURL { ShareSheet(items: [fileURL]) }
        }
        .accessibilityLabel("\(attachment.filename), \(byteText)")
    }

    private var byteText: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)
    }

    private var icon: String {
        if attachment.isImage { return "photo" }
        if attachment.mimeType.contains("pdf") { return "doc.richtext" }
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
        if attachment.mimeType.contains("zip") || attachment.mimeType.contains("compressed") { return "doc.zipper" }
        return "doc"
    }

    private func download() async {
        downloading = true
        defer { downloading = false }
        do {
            let data = try await APIClient.shared.data(
                path: "/api/messages/\(attachment.messageID)/attachments/\(attachment.id)",
                query: accountID.map { ["account": $0] } ?? [:]
            )
            // Written under the real filename so the share sheet and Files show it correctly.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attachments", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(attachment.filename.isEmpty ? "attachment" : attachment.filename)
            try data.write(to: url, options: .atomic)
            fileURL = url
            sharing = true
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Could not download that file.")
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

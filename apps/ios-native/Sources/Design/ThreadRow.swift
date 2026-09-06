import SwiftUI

/// The list row: 38pt avatar, sender, time, subject, snippet. Weight carries unread,
/// not colour. Height is free rather than fixed so a long subject wraps to two lines
/// instead of truncating mid-word.
struct ThreadRow: View {
    let thread: ThreadSummary
    var glyph: String?
    var showsSnippet: Bool = true

    private var unread: Bool { !thread.seen || thread.unread }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(address: thread.lastFrom, emphasised: unread)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if unread { UnreadDot() }
                    Text(thread.lastFrom.display)
                        .font(unread ? Theme.Typography.bodyStrong : Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Colors.foreground)
                        .lineLimit(1)

                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(Theme.Typography.micro)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                    if let glyph {
                        Text(glyph)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }

                    Spacer(minLength: 4)

                    Text(RelativeTime.short(thread.lastDate))
                        .font(Theme.Typography.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .layoutPriority(1)
                }

                Text(thread.displaySubject)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)

                if showsSnippet && !thread.snippet.isEmpty {
                    Text(thread.snippet)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .lineLimit(1)
                }

                if !markers.isEmpty || !thread.labels.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(markers, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.mutedForeground)
                        }
                        ForEach(thread.labels.prefix(2)) { label in
                            Text(label.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Colors.mutedForeground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                                )
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Attachment, note, tracker and tray marks, in a stable order.
    private var markers: [String] {
        var out: [String] = []
        if thread.hasAttachments { out.append("paperclip") }
        if !thread.note.isEmpty { out.append("note.text") }
        if thread.trackersBlocked > 0 { out.append("eye.slash") }
        if thread.replyLater { out.append("arrowshape.turn.up.left") }
        if thread.setAside { out.append("tray.and.arrow.down") }
        if thread.bubbleUpAt != nil { out.append("arrow.up.circle") }
        return out
    }

    private var accessibilityText: String {
        var parts = [thread.lastFrom.display, thread.displaySubject]
        if unread { parts.insert("Unread", at: 0) }
        parts.append(RelativeTime.short(thread.lastDate))
        return parts.joined(separator: ", ")
    }
}

/// A bundled sender standing in for all of their threads.
struct BundleRow: View {
    let bundle: MailBundle
    var glyph: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(address: bundle.address, emphasised: bundle.isOpen)
                // The stack mark: a second card peeking out behind the avatar.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.Colors.background)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Image(systemName: "square.stack")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    )
                    .offset(x: 4, y: 4)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if bundle.isOpen { UnreadDot() }
                    Text(bundle.address.display)
                        .font(bundle.isOpen ? Theme.Typography.bodyStrong : Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Colors.foreground)
                        .lineLimit(1)
                    if let glyph {
                        Text(glyph).font(.system(size: 9)).foregroundStyle(Theme.Colors.mutedForeground)
                    }
                    Spacer(minLength: 4)
                    Text(RelativeTime.short(bundle.lastDate))
                        .font(Theme.Typography.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }

                Text("\(bundle.threadCount) \(bundle.threadCount == 1 ? "thread" : "threads")")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)

                Text(bundle.latest.displaySubject)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// The little fanned stack on a tray pill: a few cards behind, the most recent sender's
/// face on top.
///
/// The web build draws exactly this, and it is what makes the pill read as "a pile of
/// things" rather than as a plain button. The cards behind carry no photo — they are
/// depth, not information — so only the front one shows a face.
struct ThreadPile: View {
    let threads: [ThreadSummary]
    var size: CGFloat = 24

    /// Front to back. Three is enough to read as a stack and few enough to stay legible.
    private var stack: [ThreadSummary] { Array(threads.prefix(3)) }

    /// How far behind the front card the deepest one is offset. The frame is grown by
    /// exactly this and no more: reserving room for three cards when there is only one
    /// leaves dead space above and to the right of the avatar, which reads as the avatar
    /// sitting low and far from the label it is next to.
    private var fan: CGFloat { CGFloat(max(stack.count - 1, 0)) * 2.5 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(stack.enumerated()).reversed(), id: \.element.id) { index, thread in
                let depth = CGFloat(index)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.Colors.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                    .overlay {
                        if index == 0 {
                            AvatarView(address: thread.lastFrom, size: size - 8)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                    }
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(depth == 1 ? -6 : depth == 2 ? 5 : 0), anchor: .bottomLeading)
                    .offset(x: depth * 2.5, y: -depth * 2.5)
                    .opacity(1 - depth * 0.25)
                    .zIndex(Double(10 - index))
            }
        }
        .frame(width: size + fan, height: size + fan, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }
}

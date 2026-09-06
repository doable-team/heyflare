import SwiftUI

/// One thread, full screen. Opening it marks it seen and read server-side unless it was
/// opened as a peek, which is why there is no separate "mark read" call here.
struct ThreadView: View {
    let threadID: String
    /// Opens the thread without marking it seen, matching the web client's `?peek=1`.
    /// Defaults to off so every existing call site behaves exactly as it did.
    var peek: Bool = false

    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var store = ThreadStore()
    @State private var offset: CGFloat = 0
    @State private var showingMore = false
    @State private var showingBubbleUp = false
    @State private var pendingLink: URL?
    @State private var sheet: ThreadSheet?
    @State private var pendingClipRemoval: Clip?
    /// An event being made from this thread. The editor needs a calendar store for its
    /// picker and timezone; this one is built lazily, the first time the action is used.
    @State private var eventDraft: EventDraft?
    @State private var calendarStore = CalendarStore()
    @State private var draftingEvent = false

    private var detail: ThreadDetail? { store.detail }
    private var compactTitle: Bool { offset < -40 }

    /// Which editing sheet is up. One value rather than a boolean each, so two sheets can
    /// never race each other into the same slot.
    private enum ThreadSheet: Identifiable {
        case note
        case rename
        case labels
        case aiReply
        case clip(Message)

        var id: String {
            switch self {
            case .note: return "note"
            case .rename: return "rename"
            case .labels: return "labels"
            case .aiReply: return "ai-reply"
            case .clip(let message): return "clip-\(message.id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: detail?.summary.displaySubject ?? "", titleVisible: compactTitle) {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                if detail != nil {
                    BarButton(icon: "ellipsis", label: "More actions") { showingMore = true }
                }
            }

            if let detail {
                RefreshableScroll(onRefresh: reload, offset: $offset) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header(detail)
                        if store.summary.isVisible {
                            ThreadSummaryPanel(
                                state: store.summary,
                                onRetry: { Task { await store.summarise(threadID) } },
                                onDismiss: { withAnimation(Theme.Motion.quick) { store.dismissSummary() } }
                            )
                        }
                        ForEach(detail.messages) { message in
                            MessageBlock(
                                message: message,
                                expanded: store.expanded.contains(message.id),
                                isOnly: detail.messages.count == 1,
                                onToggle: { store.toggle(message.id) },
                                onLink: { pendingLink = $0 },
                                onReply: { reply(to: message, all: false) },
                                onForward: { forward(message) },
                                onClip: { sheet = .clip(message) }
                            )
                            .hairline()
                        }
                        Color.clear.frame(height: 88)
                    }
                }
            } else if store.loading {
                ProgressView().tint(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.error {
                InlineError(message: error) { Task { await store.load(threadID, peek: peek) } }
                    .padding(.top, 24)
                Spacer()
            }
        }
        .screenBackground()
        .safeAreaInset(edge: .bottom) {
            if detail != nil { actionBar }
        }
        .task {
            await store.load(threadID, peek: peek)
            // Opening a thread is itself a write: the worker marks it seen and read. The
            // list this was opened from is drawing it bold, and has to hear about that.
            if !peek, store.detail != nil { app.didMutate() }
        }
        .confirmationDialog("More", isPresented: $showingMore, titleVisibility: .hidden) { moreActions }
        .confirmationDialog("Bubble up", isPresented: $showingBubbleUp, titleVisibility: .visible) { bubbleUpOptions }
        .confirmationDialog(
            "Remove this clip?",
            isPresented: Binding(get: { pendingClipRemoval != nil }, set: { if !$0 { pendingClipRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove clip", role: .destructive) {
                if let clip = pendingClipRemoval { removeClip(clip) }
                pendingClipRemoval = nil
            }
            Button("Keep", role: .cancel) { pendingClipRemoval = nil }
        }
        .confirmationDialog(
            pendingLink?.absoluteString ?? "",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            titleVisibility: .visible
        ) {
            // Mail links go to Safari rather than opening inside the message view,
            // so a message can never navigate the app somewhere.
            if let url = pendingLink {
                Button("Open in Safari") { openURL(url) }
                Button("Copy link") { UIPasteboard.general.string = url.absoluteString }
            }
            Button("Cancel", role: .cancel) { pendingLink = nil }
        }
        .sheet(item: $sheet) { which in
            sheetContent(which)
        }
        .sheet(item: $eventDraft) { draft in
            EventEditor(target: .draft(draft), store: calendarStore)
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ which: ThreadSheet) -> some View {
        switch which {
        case .note:
            ThreadNoteSheet(
                note: detail?.summary.note ?? "",
                onSave: { run(.note($0), message: $0.isEmpty ? "Note removed" : "Note saved") },
                onClear: { run(.note(""), message: "Note removed") }
            )
        case .rename:
            ThreadRenameSheet(
                subject: detail?.summary.subject ?? "",
                originalSubject: detail?.summary.originalSubject ?? "",
                onSave: { run(.rename($0)) },
                onReset: { run(.rename(nil), message: "Name restored") }
            )
        case .labels:
            ThreadLabelsSheet(
                applied: Set(detail?.summary.labels.map(\.id) ?? []),
                toggle: { label, on in await setLabel(label, on: on) }
            )
        case .aiReply:
            ThreadAiReplySheet(threadID: threadID, onDraft: openDraft)
        case .clip(let message):
            ThreadClipSheet(source: Self.clipText(from: message)) { text in
                saveClip(text, on: message)
            }
        }
    }

    // MARK: Header

    private func header(_ detail: ThreadDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.summary.displaySubject)
                .font(Theme.Typography.threadSubject)
                .tracking(-0.3)
                .foregroundStyle(Theme.Colors.foreground)
                .fixedSize(horizontal: false, vertical: true)

            // Now that the subject can be renamed from here, the name it arrived under has
            // to stay visible — otherwise a renamed thread quietly loses what the sender
            // actually called it.
            if renamed(detail) {
                Text("originally “\(detail.summary.originalSubject)”")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text(participantLine(detail))
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
                if let glyph = app.glyph(for: detail.summary.accountID) {
                    Text(glyph).font(.system(size: 9)).foregroundStyle(Theme.Colors.mutedForeground)
                }
            }

            // Tapping the note opens it for editing, which is how the web behaves and is
            // the only affordance a written note needs.
            if !detail.summary.note.isEmpty {
                Button { sheet = .note } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "pin")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .padding(.top, 1)
                        Text(detail.summary.note)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget, alignment: .leading)
                    .background(Theme.Colors.muted)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Note: \(detail.summary.note)")
                .accessibilityHint("Edits this note")
            }

            if !stateChips(detail).isEmpty {
                HStack(spacing: 6) {
                    ForEach(stateChips(detail), id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
                            )
                    }
                }
            }

            if !detail.clips.isEmpty { clipChips(detail.clips) }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// A saved clip, and the way to take it back off. A clip you cannot remove is worse
    /// than one you never see, which is the same trap the read-only note fell into.
    private func clipChips(_ clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(clips) { clip in
                Button { pendingClipRemoval = clip } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "scissors")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .padding(.top, 2)
                        Text(clip.text)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.foreground)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget, alignment: .leading)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clip: \(clip.text)")
                .accessibilityHint("Removes this clip")
            }
        }
        .padding(.top, 2)
    }

    private func renamed(_ detail: ThreadDetail) -> Bool {
        !detail.summary.subject.isEmpty
            && !detail.summary.originalSubject.isEmpty
            && detail.summary.subject != detail.summary.originalSubject
    }

    private func participantLine(_ detail: ThreadDetail) -> String {
        let names = detail.summary.participants.map(\.display)
        if names.isEmpty { return detail.summary.lastFrom.display }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) others"
    }

    private func stateChips(_ detail: ThreadDetail) -> [String] {
        var out: [String] = []
        if detail.summary.replyLater { out.append("Reply Later") }
        if detail.summary.setAside { out.append("Set Aside") }
        if detail.summary.bubbleUpAt != nil { out.append("Bubbling up") }
        if detail.senderBundled { out.append("Bundled") }
        if detail.summary.trackersBlocked > 0 {
            out.append("Blocked \(detail.summary.trackersBlocked) tracker\(detail.summary.trackersBlocked == 1 ? "" : "s")")
        }
        out.append(contentsOf: detail.summary.labels.map(\.name))
        return out
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            action("arrowshape.turn.up.left", "Reply") {
                if let message = detail?.messages.last { reply(to: message, all: false) }
            }
            action(
                "clock",
                "Reply later",
                on: detail?.summary.replyLater == true
            ) {
                run(.replyLater(!(detail?.summary.replyLater ?? false)))
            }
            action(
                "tray.and.arrow.down",
                "Set aside",
                on: detail?.summary.setAside == true
            ) {
                run(.setAside(!(detail?.summary.setAside ?? false)))
            }
            action("arrow.up.circle", "Bubble up", on: detail?.summary.bubbleUpAt != nil) {
                if detail?.summary.bubbleUpAt != nil { run(.bubbleUp(nil)) } else { showingBubbleUp = true }
            }
            action("trash", "Trash") { run(.move(.trash), thenLeave: true) }
        }
        .frame(height: 56)
        .background(Theme.Colors.chrome)
        .background(.ultraThinMaterial)
        .hairline(.top)
    }

    private func action(_ icon: String, _ label: String, on: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: on ? icon + ".fill" : icon)
                    .font(.system(size: 17, weight: on ? .semibold : .regular))
                    .symbolRenderingMode(.monochrome)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Colors.foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Everything the five-slot bar has no room for.
    ///
    /// Ordered by how often a thumb reaches for it rather than by kind: answering the
    /// thread, then understanding it, then filing it, then the two that end it. The three
    /// buckets are filtered against where the thread already is, because "Move to Imbox"
    /// on a thread in the Imbox is a line of text that can only disappoint.
    @ViewBuilder
    private var moreActions: some View {
        if let message = detail?.messages.last {
            Button("Reply all") { reply(to: message, all: true) }
            Button("Forward") { forward(message) }
        }
        Button("Reply with AI") { sheet = .aiReply }
        Button("Summarise with AI") { Task { await store.summarise(threadID) } }
        Button(detail?.summary.note.isEmpty == false ? "Edit note" : "Stick a note on it") { sheet = .note }
        Button("Labels") { sheet = .labels }
        Button("Rename subject") { sheet = .rename }
        Button("Create event") { createEvent() }
        Button(detail?.summary.unread == true ? "Mark read" : "Mark unread") {
            run(detail?.summary.unread == true ? .markRead : .markUnread)
        }
        ForEach(moveTargets, id: \.self) { bucket in
            Button("Move to \(bucket.title)") { run(.move(bucket), thenLeave: true) }
        }
        // Bundling files everything from this sender together from now on, which only
        // means anything for the two buckets bundles are drawn in.
        if let detail, detail.summary.bucket == .imbox || detail.summary.bucket == .paperTrail {
            Button(detail.senderBundled ? "Unbundle sender" : "Bundle up sender") {
                bundle(!detail.senderBundled)
            }
        }
        Button("Screen out sender") { screenOut() }
        Button("Cancel", role: .cancel) {}
    }

    private var moveTargets: [Bucket] {
        [.imbox, .feed, .paperTrail].filter { $0 != detail?.summary.bucket }
    }

    @ViewBuilder
    private var bubbleUpOptions: some View {
        // The presets the web client offers, resolved against the current clock.
        Button("In 3 hours") { run(.bubbleUp(Date().addingTimeInterval(3 * 3600))) }
        // Offered only while this evening is still ahead. Sliding it silently to tomorrow
        // would make the label a lie for anyone filing mail after six.
        if let evening = Self.laterToday(hour: 18) {
            Button("This evening") { run(.bubbleUp(evening)) }
        }
        Button("Tomorrow morning") { run(.bubbleUp(Self.tomorrow(hour: 8))) }
        Button("Next week") { run(.bubbleUp(Self.nextWeek())) }
        Button("Cancel", role: .cancel) {}
    }

    /// Today at `hour`, or `nil` when that moment has already gone by. The caller decides
    /// what to do about it rather than being handed a different day under the same name.
    private static func laterToday(hour: Int, now: Date = Date()) -> Date? {
        let cal = Calendar.current
        guard let today = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now), today > now else { return nil }
        return today
    }

    /// Tomorrow at `hour`, always — never today. "Tomorrow morning" tapped at 06:30 meant
    /// 08:00 the same day, which bubbled the thread back up ninety minutes later.
    private static func tomorrow(hour: Int, now: Date = Date()) -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(24 * 3600)
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    private static func nextWeek() -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: base) ?? base
    }

    /// What a clip starts from: the message's readable text, quoted history dropped.
    /// See `ThreadClipSheet` for why this is the whole message rather than a selection.
    private static func clipText(from message: Message) -> String {
        let text = message.textBody.isEmpty ? HTMLText.plain(from: message.htmlBody) : message.textBody
        return HTMLText.splitQuoted(text).body
    }

    // MARK: Behaviour

    private func reload() async {
        // Always a peek: a pull-to-refresh is a redraw, not a second act of reading.
        do {
            store.apply(try await APIClient.shared.thread(threadID, peek: true))
        } catch {
            // A pull that fails silently reads as a pull that found nothing new.
            toasts.error((error as? APIError)?.errorDescription ?? "Could not refresh this thread.")
        }
    }

    private func reply(to message: Message, all: Bool) {
        guard let detail else { return }
        let mine = app.accounts.map(\.email)
        nav.composing = .reply(to: message, in: detail, me: mine, all: all)
    }

    private func forward(_ message: Message) {
        guard let detail else { return }
        nav.composing = .forward(message, in: detail)
    }

    /// Opens an AI-written reply in the composer, prefilled and unsent.
    ///
    /// The draft names the message it answered — the last one that was not from you — so
    /// the composer quotes and threads against that rather than against your own last
    /// send, which is what `messages.last` would have picked.
    private func openDraft(_ draft: ThreadAiReply) {
        guard let detail else { return }
        let target = detail.messages.first { $0.id == draft.replyToMessageID }
            ?? detail.messages.last { !$0.isFromMe }
            ?? detail.messages.last
        guard let target else { return }
        var intent = ComposeIntent.reply(to: target, in: detail, me: app.accounts.map(\.email), all: false)
        intent.body = draft.bodyText
        nav.composing = intent
    }

    /// Runs an action against this thread. `thenLeave` pops the screen for actions
    /// that take the thread out of the list it came from. `message` overrides the toast
    /// for the cases where one action name covers two outcomes — saving a note and
    /// clearing one are both `note`.
    private func run(_ action: ThreadAction, thenLeave: Bool = false, message: String? = nil) {
        Haptics.select()
        Task {
            do {
                let updated = try await APIClient.shared.act(threadID, action)
                store.apply(updated)
                app.didMutate()
                toasts.show(message ?? action.confirmation)
                if thenLeave { dismiss() }
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? "That did not go through.")
            }
        }
    }

    /// Toggles one label. Awaited rather than fired, because the sheet has already moved
    /// the tick and needs to know whether to move it back.
    private func setLabel(_ label: MailLabel, on: Bool) async -> Bool {
        do {
            let updated = try await APIClient.shared.act(
                threadID,
                .labels(add: on ? [label.id] : [], remove: on ? [] : [label.id])
            )
            store.apply(updated)
            app.didMutate()
            return true
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "That did not go through.")
            return false
        }
    }

    private func bundle(_ on: Bool) {
        Haptics.select()
        Task {
            do {
                let updated = try await APIClient.shared.bundleSender(threadID, on: on)
                store.apply(updated)
                // Bundling reshapes the lists this thread appears in, so they are stale.
                app.didMutate()
                toasts.show(on ? "Bundled up sender" : "Unbundled sender")
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? "That did not go through.")
            }
        }
    }

    private func saveClip(_ text: String, on message: Message) {
        Task {
            do {
                let clip = try await APIClient.shared.createClip(threadID: threadID, messageID: message.id, text: text)
                store.addClip(clip)
                Haptics.success()
                toasts.show("Clip saved")
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? "Could not save that clip.")
            }
        }
    }

    private func removeClip(_ clip: Clip) {
        Task {
            do {
                try await APIClient.shared.deleteClip(clip.id)
                store.removeClip(clip.id)
                toasts.show("Clip removed")
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? "That did not go through.")
            }
        }
    }

    /// Asks the worker for an event prefilled from this thread — subject, first line and
    /// the people on it — then opens the editor on it. Nothing is saved until Save.
    private func createEvent() {
        guard !draftingEvent else { return }
        draftingEvent = true
        Task {
            defer { draftingEvent = false }
            do {
                await calendarStore.loadPrefs()
                eventDraft = try await CalendarAPI.eventDraft(threadID: threadID)
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? "Could not start an event from this thread.")
            }
        }
    }

    private func screenOut() {
        guard let contactEmail = detail?.summary.lastFrom.email, !contactEmail.isEmpty else { return }
        Task {
            // The screener works on contact ids, so the sender is looked up first.
            guard let match = try? await APIClient.shared.contacts(query: contactEmail)
                .first(where: { $0.email.caseInsensitiveCompare(contactEmail) == .orderedSame }) else {
                toasts.error("Could not find that sender.")
                return
            }
            do {
                try await APIClient.shared.decide(contactID: match.id, decision: .screenedOut)
                app.didMutate()
                toasts.show("Screened out \(match.address.display)")
                dismiss()
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? "That did not go through.")
            }
        }
    }
}

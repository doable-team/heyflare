import SwiftUI

// The composer: a full-screen sheet over whatever tab started it. Everything it needs
// arrives as a `ComposeIntent`, so a reply from a thread, a forward and a blank message
// are the same screen with different prefills.

// MARK: - Store

// MARK: - Undo send

// MARK: - Screen

/// Cancel · title · Send, then the addressing rows, the subject, the body, and a bar that
/// rides above the keyboard. DESIGN.md §8.
struct ComposeView: View {
    let intent: ComposeIntent

    @Environment(AppState.self) private var app
    @Environment(ToastCenter.self) private var toasts
    @Environment(Navigator.self) private var nav
    @Environment(\.dismiss) private var dismiss

    @State private var store = ComposeStore()
    @State private var sheet: ComposeSheet?
    @State private var confirmingDiscard = false
    @State private var confirmingSubjectless = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case subject, body }

    private enum ComposeSheet: String, Identifiable {
        case from, later
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if app.accounts.count > 1 {
                        fromRow
                        Divider().overlay(Theme.Colors.border)
                    }

                    HStack(alignment: .top, spacing: 0) {
                        RecipientField(
                            label: "To",
                            addresses: $store.to,
                            suggestions: contacts,
                            focusOnAppear: intent.to.isEmpty
                        )
                        if !store.showsCarbon {
                            Button("Cc/Bcc") {
                                withAnimation(Theme.Motion.quick) { store.showsCarbon = true }
                            }
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .frame(width: 64, height: Theme.Metrics.minTouchTarget)
                            .padding(.trailing, 4)
                        }
                    }
                    Divider().overlay(Theme.Colors.border)

                    if store.showsCarbon {
                        RecipientField(label: "Cc", addresses: $store.cc, suggestions: contacts)
                        Divider().overlay(Theme.Colors.border)
                        RecipientField(label: "Bcc", addresses: $store.bcc, suggestions: contacts)
                        Divider().overlay(Theme.Colors.border)
                    }

                    subjectRow
                    Divider().overlay(Theme.Colors.border)

                    if let failure = store.failure {
                        failureNote(failure)
                    }

                    bodyEditor

                    if !store.quoted.isEmpty {
                        quotedBlock
                    }

                    if !store.attachments.isEmpty {
                        AttachmentTray(
                            attachments: store.attachments,
                            scheduled: store.inheritedSchedule != nil
                        ) { attachment in
                            withAnimation(Theme.Motion.quick) {
                                store.attachments.removeAll { $0.id == attachment.id }
                            }
                            store.failure = nil
                        }
                    }

                    Color.clear.frame(height: 40)
                }
            }
            .scrollDismissesKeyboard(.interactively)

            actionBar
        }
        .screenBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task {
            store.prepare(intent, fallbackAccountID: app.scopedAccount?.id ?? app.accounts.first?.id)
            store.primeSignature(signatureText, existingDraft: intent.draftID != nil)
            guard !intent.to.isEmpty else { return }   // otherwise the To field takes focus
            try? await Task.sleep(for: .milliseconds(350))
            focus = .body
        }
        // The From account can also arrive late on a cold start, which is the other reason
        // this watches the signature text rather than the account id.
        .onChange(of: signatureText) { _, next in store.changeSignature(to: next) }
        .onChange(of: store.snapshot) { _, _ in store.noteEdit() }
        // A swipe down is a close, and a close keeps the draft — the same as Cancel. Nothing
        // needs to be blocked any more, because nothing is thrown away by leaving.
        .onDisappear { closeSavingDraft() }
        .confirmationDialog("Discard this message?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            // Named, not tinted: `role: .destructive` would paint this red, and nothing in
            // this app carries colour.
            Button("Discard draft") { discard() }
            Button("Keep writing", role: .cancel) {}
        } message: {
            Text("The draft is deleted and the text is gone.")
        }
        .confirmationDialog("Send without a subject?", isPresented: $confirmingSubjectless, titleVisibility: .visible) {
            Button("Send") { startSend(skippingSubjectCheck: true) }
            Button("Add a subject", role: .cancel) { focus = .subject }
        } message: {
            Text("The recipient will see “(no subject)”.")
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .from: accountPicker
            case .later: sendLaterPicker
            }
        }
    }

    // MARK: Bars

    private var topBar: some View {
        TopBar(title: intent.title) {
            Button("Cancel") { cancel() }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .frame(minWidth: Theme.Metrics.minTouchTarget, minHeight: Theme.Metrics.minTouchTarget)
        } trailing: {
            Button {
                startSend()
            } label: {
                if store.sending {
                    ProgressView().tint(Theme.Colors.mutedForeground)
                } else {
                    Text("Send").font(Theme.Typography.bodyStrong)
                }
            }
            .foregroundStyle(Theme.Colors.foreground)
            .frame(minWidth: Theme.Metrics.minTouchTarget, minHeight: Theme.Metrics.minTouchTarget)
            .disabled(!store.canSend)
            .opacity(store.canSend ? 1 : 0.35)
        }
    }

    /// The bar DESIGN.md parks above the keyboard. It carries the controls this composer can
    /// honour: rich formatting is deliberately absent rather than present and dead — the body
    /// is sent as escaped plain text through `HTMLText.htmlBody`, and a button that silently
    /// does nothing is worse than one that was never drawn.
    private var actionBar: some View {
        @Bindable var store = store

        return HStack(spacing: 2) {
            AttachmentButton(attachments: $store.attachments) { problem in
                store.failure = problem
            }

            if !store.quoted.isEmpty {
                Button {
                    withAnimation(Theme.Motion.quick) { store.quoteExpanded.toggle() }
                } label: {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(store.quoteExpanded ? Theme.Colors.foreground : Theme.Colors.mutedForeground)
                        .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(store.quoteExpanded ? "Hide quoted text" : "Show quoted text")
            }

            if !store.showsCarbon {
                Button("Cc/Bcc") {
                    withAnimation(Theme.Motion.quick) { store.showsCarbon = true }
                }
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .frame(height: Theme.Metrics.minTouchTarget)
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            Menu {
                // `POST /api/send` refuses a scheduled send that carries files
                // (`scheduled_send_no_attachments`), so the option is disabled and the
                // header says why, rather than the tap ending in a server error.
                Section {
                    Button("Send later…") { sheet = .later }
                        .disabled(!store.attachments.isEmpty)
                    if app.accounts.count > 1 {
                        Button("Change account…") { sheet = .from }
                    }
                    Button("Discard draft") { attemptDiscard() }
                } header: {
                    if !store.attachments.isEmpty {
                        Text("Scheduled mail cannot carry attachments")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.Colors.foreground)
                    .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More compose options")
        }
        .padding(.horizontal, 6)
        .frame(height: Theme.Metrics.tabBarHeight)
        .background(Theme.Colors.chrome)
        .background(.ultraThinMaterial)
        .hairline(.top)
    }

    // MARK: Rows

    private var fromRow: some View {
        Button {
            sheet = .from
        } label: {
            HStack(spacing: 8) {
                Text("From")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 34, alignment: .leading)
                Text(sender?.email ?? "No account")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(height: Theme.Metrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .accessibilityLabel("From \(sender?.email ?? "no account")")
    }

    private var subjectRow: some View {
        @Bindable var store = store

        return HStack(spacing: 8) {
            Text("Subject")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
            TextField("", text: $store.subject)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .submitLabel(.next)
                .focused($focus, equals: .subject)
                .onSubmit { focus = .body }
                .accessibilityLabel("Subject")
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .frame(height: Theme.Metrics.minTouchTarget)
    }

    private var bodyEditor: some View {
        @Bindable var store = store

        // `scrollDisabled` turns the editor into a block that grows with its text, so the one
        // scroll view on the screen is the outer one. Two nested scrollers would fight over
        // the drag and strand the cursor under the keyboard.
        return TextEditor(text: $store.body)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.foreground)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(minHeight: 180)
            .padding(.horizontal, Theme.Metrics.hPadding - 5)   // TextEditor insets its own text
            .padding(.top, 6)
            .focused($focus, equals: .body)
            .overlay(alignment: .topLeading) {
                if store.body.isEmpty {
                    Text("Write something")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .padding(.horizontal, Theme.Metrics.hPadding)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Message body")
    }

    private var quotedBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.Motion.quick) { store.quoteExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.quoteExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text(store.quoteExpanded ? "Quoted text" : firstQuotedLine)
                        .font(Theme.Typography.small)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.Colors.mutedForeground)
                .padding(.horizontal, Theme.Metrics.hPadding)
                .frame(height: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.quoteExpanded ? "Collapse quoted text" : "Expand quoted text")

            if store.quoteExpanded {
                Text(store.quoted)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 2)
                .padding(.leading, 6)
        }
    }

    private func failureNote(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(Theme.Typography.small)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Colors.foreground)
        .padding(12)
        .background(Theme.Colors.muted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 10)
    }

    // MARK: Sheets

    private var accountPicker: some View {
        VStack(spacing: 0) {
            Text("Send from")
                .font(Theme.Typography.compactTitle)
                .foregroundStyle(Theme.Colors.foreground)
                .frame(height: Theme.Metrics.minTouchTarget)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(app.accounts.enumerated()), id: \.element.id) { index, account in
                        Button {
                            store.accountID = account.id
                            sheet = nil
                            Haptics.select()
                        } label: {
                            HStack(spacing: 10) {
                                Text(Theme.glyph(forAccountIndex: index))
                                    .font(Theme.Typography.small)
                                    .foregroundStyle(Theme.Colors.mutedForeground)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.email)
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Colors.foreground)
                                        .lineLimit(1)
                                    if !account.displayName.isEmpty {
                                        Text(account.displayName)
                                            .font(Theme.Typography.micro)
                                            .foregroundStyle(Theme.Colors.mutedForeground)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if account.id == store.accountID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.Colors.foreground)
                                }
                            }
                            .padding(.horizontal, Theme.Metrics.hPadding)
                            .frame(height: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRowStyle())
                        .hairline(.bottom)
                    }
                }
            }
        }
        .screenBackground()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .tint(Theme.Colors.foreground)
    }

    private var sendLaterPicker: some View {
        SendLaterSheet { date in
            sheet = nil
            Task { await performSend(at: date) }
        }
    }

    // MARK: Actions

    private var sender: Account? {
        app.account(store.accountID) ?? app.scopedAccount ?? app.accounts.first
    }

    /// The From account's signature as plain text. The account stores it as the fragment of
    /// HTML the web editor writes; this composer's body is plain text end to end, so it is
    /// flattened once here rather than half-escaped into the message on send.
    private var signatureText: String {
        HTMLText.plain(from: sender?.signature ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isReply: Bool { intent.threadID != nil }

    private var firstQuotedLine: String {
        store.quoted.split(separator: "\n").first.map(String.init) ?? "Quoted text"
    }

    private func contacts(_ query: String) async -> [Address] {
        await ContactSuggestions.lookup(query)
    }

    // MARK: Leaving

    /// Cancel. The web client's mobile composer saves and closes with no question asked
    /// (`ComposeContext.tsx:101-104` → `Composer.tsx:326-338`), and so does this: a draft
    /// nobody asked to destroy is a draft worth keeping.
    private func cancel() {
        closeSavingDraft()
        dismiss()
    }

    /// Shared by Cancel and by a swipe down, which mean the same thing. The confirmation
    /// that used to live here is gone: there is nothing to confirm when nothing is lost.
    private func closeSavingDraft() {
        guard !store.resolved else { return }
        store.resolved = true
        store.cancelAutosave()

        guard store.hasContent else {
            // Nothing was ever typed — an autosave may still have written a row for
            // recipients that were then removed, so it goes with the composer.
            store.discardStoredDraft()
            return
        }

        // The save outlives this view deliberately: the sheet leaves at the speed of the
        // tap, and the request finishes behind it. `store` is a class, so the task keeps
        // hold of everything it needs after the view is gone.
        let store = self.store
        let toasts = self.toasts
        Task {
            if await store.saveDraft() {
                // Once, on close, rather than on every autosave: the Drafts list is the
                // only screen that cares, and it cannot be showing while this sheet is.
                MailBus.shared.changed()
                toasts.show("Saved as a draft")
            } else {
                toasts.error("Could not save that draft.")
            }
        }
    }

    private func attemptDiscard() {
        if store.hasContent { confirmingDiscard = true } else { discard() }
    }

    /// The one path that still destroys something, so it is the one path that still asks.
    private func discard() {
        store.resolved = true
        store.discardStoredDraft()
        MailBus.shared.changed()
        dismiss()
    }

    // MARK: Sending

    /// Send, honouring the owner's undo window.
    ///
    /// The default is ten seconds, not zero (`ComposeContext.tsx:64-82` uses the same
    /// number). A person who has never opened the setting has not asked for irreversible
    /// sends, and on a phone — one thumb, a moving train — that is exactly who needs the
    /// window most. Reading a missing setting as zero turned every mistap into sent mail.
    private func startSend(skippingSubjectCheck: Bool = false) {
        guard store.canSend else { return }

        // The web client asks the same question, and only for a message that is not a reply
        // (`Composer.tsx:288-299`): a reply inherits its subject and never needs one typed.
        if !skippingSubjectCheck, !isReply,
           store.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            confirmingSubjectless = true
            return
        }

        if let refusal = attachmentRefusal() {
            store.failure = refusal
            Haptics.warning()
            return
        }

        let window = app.user?.settings.undoSendSeconds ?? 10
        store.cancelAutosave()
        store.resolved = true

        guard window > 0 else {
            Task { await performSend() }
            return
        }

        // Written to disk, and mirrored to the server as a draft, *before* the timer starts:
        // from here on the message survives the app being killed mid-window.
        let record = PendingSendCenter.shared.arm(store.payload(), window: window, subject: store.subject)
        let draft = store.restored(from: intent)
        let heldBcc = store.bccForCarryOver
        let heldAttachments = store.attachmentsForCarryOver
        // Both of these are read now rather than inside the closure: by the time Undo runs,
        // this view is gone and its environment is no longer safe to touch.
        let navigator = nav
        Haptics.success()
        dismiss()
        SendQueue.shared.queue(record, toasts: toasts) { rebuilt in
            // Only an actual undo fills the carry-over slots, and the reopened composer
            // empties them.
            ComposeCarryOver.bcc = heldBcc
            ComposeCarryOver.attachments = heldAttachments
            var reopened = draft
            // The composer's own copy of the draft is richer than one rebuilt from HTML;
            // all that is taken from the record is the row the mirror created for it.
            reopened.draftID = rebuilt.draftID ?? draft.draftID
            navigator.composing = reopened
        }
    }

    private func performSend(at date: Date? = nil) async {
        guard store.hasRecipients else { return }
        if let refusal = attachmentRefusal(scheduledFor: date) {
            store.failure = refusal
            Haptics.warning()
            return
        }
        store.cancelAutosave()
        store.resolved = true
        store.failure = nil
        store.sending = true
        defer { store.sending = false }
        do {
            _ = try await APIClient.shared.send(store.payload(sendAt: date))
            Haptics.success()
            dismiss()
            if let date {
                toasts.show("Scheduled for \(RelativeTime.long(date))")
            } else {
                toasts.show("Message sent")
            }
        } catch let error as APIError {
            // The message is still on screen, so it is still recoverable: let it be saved
            // again rather than leaving it stranded by the flag that was set optimistically.
            store.resolved = false
            store.failure = error.errorDescription ?? "Could not send that."
            Haptics.warning()
        } catch {
            store.resolved = false
            store.failure = error.localizedDescription
            Haptics.warning()
        }
    }

    /// The caps, checked once more at the point of no return. `AttachmentButton` refuses a
    /// file that would break them, but a draft can also be reopened, and the scheduling rule
    /// only becomes true when a time is chosen.
    private func attachmentRefusal(scheduledFor date: Date? = nil) -> String? {
        guard !store.attachments.isEmpty else { return nil }
        if date != nil || store.inheritedSchedule != nil {
            return "Scheduled mail cannot carry attachments. Remove them, or send now."
        }
        if store.attachments.count > AttachmentLimits.count {
            return "Ten files is the limit for one message."
        }
        if AttachmentLimits.total(store.attachments) > AttachmentLimits.totalBytes {
            return "Attachments are capped at \(AttachmentLimits.describe(AttachmentLimits.totalBytes)) in total."
        }
        return nil
    }
}

// MARK: - Send later

/// Presets first, because "tomorrow morning" is what people actually mean, with a real
/// picker underneath for the times they do not.
private struct SendLaterSheet: View {
    let onPick: (Date) -> Void

    @State private var custom = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(spacing: 0) {
            Text("Send later")
                .font(Theme.Typography.compactTitle)
                .foregroundStyle(Theme.Colors.foreground)
                .frame(height: Theme.Metrics.minTouchTarget)

            ForEach(Self.presets(), id: \.title) { preset in
                Button {
                    onPick(preset.date)
                } label: {
                    HStack {
                        Text(preset.title)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.foreground)
                        Spacer(minLength: 0)
                        Text(RelativeTime.long(preset.date))
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableRowStyle())
                .hairline(.bottom)
            }

            DatePicker("Custom", selection: $custom, in: Date()...)
                .font(Theme.Typography.body)
                .padding(.horizontal, Theme.Metrics.hPadding)
                .frame(height: 56)

            Button("Schedule") { onPick(custom) }
                .buttonStyle(FilledButtonStyle())
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .screenBackground()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .tint(Theme.Colors.foreground)
    }

    private struct Preset {
        let title: String
        let date: Date
    }

    /// The web client's three headline choices, computed against the device's calendar so
    /// "morning" means the reader's morning.
    private static func presets(now: Date = Date(), calendar: Calendar = .current) -> [Preset] {
        var out: [Preset] = []

        let hour = calendar.component(.hour, from: now)
        if let laterToday = calendar.date(bySettingHour: min(hour + 3, 22), minute: 0, second: 0, of: now),
           laterToday > now.addingTimeInterval(15 * 60) {
            out.append(Preset(title: "Later today", date: laterToday))
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) {
            out.append(Preset(title: "Tomorrow morning", date: morning))
        }

        // The next Monday, and never today even if today is a Monday.
        let weekday = calendar.component(.weekday, from: now)          // 1 = Sunday
        let daysToMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        if let nextWeek = calendar.date(byAdding: .day, value: daysToMonday, to: now),
           let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: nextWeek) {
            out.append(Preset(title: "Next week", date: morning))
        }

        return out
    }
}

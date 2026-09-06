import SwiftUI

// The four read-only library screens behind More: Contacts, Clips, Collections, Labels.
// They share a shape — fetch once, draw a flat list, push a thread — so they share a file
// rather than four near-identical ones. Everything that is only theirs (their stores, their
// row chrome, the two endpoints the shared `APIClient` does not carry yet) lives here.

// MARK: - Endpoints

// MARK: - Contacts

/// Everyone this mailbox has heard from, searchable, with their screen decision on the row.
/// A tap opens the person in a sheet rather than pushing: their threads are context for the
/// list you are already in, so the list should still be there when the sheet closes.
struct ContactsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = ContactsStore()
    @State private var selected: Contact?

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            TopBar(title: "Contacts", titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            LibrarySearchField(text: $store.query, placeholder: "Search people")

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = store.error {
                        EmptyState(icon: "exclamationmark.triangle", message: error)
                    } else if store.contacts.isEmpty && !store.loading {
                        EmptyState(
                            icon: "person.2",
                            message: store.query.isEmpty ? "No one here yet." : "No one matches “\(store.query)”."
                        )
                    } else {
                        ForEach(store.contacts) { contact in
                            ContactRow(contact: contact) { selected = contact }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .overlay(alignment: .top) {
                if store.loading && store.contacts.isEmpty {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .task { await store.load() }
        .onChange(of: store.query) { _, _ in store.scheduleSearch() }
        .sheet(item: $selected) { contact in
            // The row behind the sheet shows this person's screen status, so it has to
            // learn about a decision made inside it — otherwise closing the sheet reveals
            // the answer the reader has just changed.
            ContactSheet(contact: contact) { updated in
                if let index = store.contacts.firstIndex(where: { $0.id == updated.id }) {
                    store.contacts[index] = updated
                }
            }
        }
    }
}

/// 56pt: avatar, name over email, screen status on the right. The status is the only thing
/// this row is really for — it is how you check where someone lands without opening them.
private struct ContactRow: View {
    let contact: Contact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(address: contact.address, size: Theme.Metrics.smallAvatar + 4)

                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.address.display)
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Colors.foreground)
                        .lineLimit(1)
                    Text(contact.email)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(statusText)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(height: Theme.Metrics.denseRowHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .hairline()
        .accessibilityLabel("\(contact.address.display), \(contact.email), \(statusText)")
    }

    /// `mixed` means the connected accounts disagree about this person; saying so is more
    /// honest than picking one of the two answers and drawing it as if it were settled.
    private var statusText: String {
        contact.mixed == true ? "\(contact.screenStatus.title) · mixed" : contact.screenStatus.title
    }
}

/// The person, everything they are part of, and the two decisions you can change about
/// them from a phone.
///
/// Read-only until now. The web's contact page edits name, notes, screen status, scope and
/// the bundled flag; the two that matter in a pocket are the last two — where their mail
/// lands, and whether it arrives as one row or twenty — because those are the ones you
/// want to change the moment their mail annoys you. Name and notes are here too, saved on
/// blur, because the fields were already drawn and a phone is where you learn who someone
/// actually is.
///
/// Opening a thread pushes it onto the stack underneath before the sheet closes, so the
/// two movements read as one.
struct ContactSheet: View {
    let contact: Contact
    /// Called with the settled contact after any change, so a list behind the sheet can
    /// drop a row that no longer belongs to it.
    var onChange: ((Contact) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts
    @State private var store = ContactDetailStore()

    @State private var name = ""
    @State private var notes = ""
    /// Whether a change applies to every mailbox or only the one this row belongs to.
    /// "All" is the worker's own default and the right answer for one person, one decision.
    @State private var appliesToAll = true
    @State private var pickingStatus = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case name, notes }

    /// The freshest version of this person: the fetched one once it lands, the row that
    /// opened the sheet until then.
    private var person: Contact { store.detail?.contact ?? contact }

    /// Bundling only means something where mail is delivered as a list — the Feed is
    /// already a stream and screened-out mail never arrives at all.
    private var bundlingApplies: Bool { person.screenStatus == .imbox || person.screenStatus == .paperTrail }

    private static let statuses: [ScreenStatus] = [.imbox, .feed, .paperTrail, .screenedOut]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    editor

                    SectionHeader(title: "Conversations", trailing: store.detail.map { "\($0.threads.count)" })

                    if let error = store.error {
                        EmptyState(icon: "exclamationmark.triangle", message: error)
                    } else if let threads = store.detail?.threads, !threads.isEmpty {
                        ForEach(threads) { thread in
                            Button {
                                nav.push(.thread(thread.id))
                                dismiss()
                            } label: {
                                ThreadRow(thread: thread, glyph: app.glyph(for: thread.accountID), showsSnippet: app.showsPreviews)
                            }
                            .buttonStyle(PressableRowStyle())
                            .hairline()
                        }
                    } else if !store.loading {
                        EmptyState(icon: "tray", message: "No threads with \(person.address.display).")
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .top) {
                if store.loading {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await store.load(id: contact.id)
            // Seeded after the fetch rather than before it: the row that opened the sheet
            // can be an older copy, and overwriting a field the reader is editing with a
            // stale value is worse than showing it a beat late.
            if name.isEmpty { name = person.name }
            if notes.isEmpty { notes = person.notes }
        }
        // A sheet can be swiped away with the keyboard still up, which never fires the
        // focus change that would otherwise save. Losing a note somebody just typed
        // because they dismissed the wrong way is not an acceptable way to lose it.
        .onDisappear {
            commitName()
            commitNotes()
        }
        .confirmationDialog("Where should their mail go?", isPresented: $pickingStatus, titleVisibility: .visible) {
            ForEach(Self.statuses, id: \.self) { status in
                Button(status.title) { apply(screenStatus: status) }
            }
            Button("Leave it", role: .cancel) {}
        } message: {
            Text(blurb(for: person.screenStatus))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(address: person.address, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                // A name field rather than a label. Placeholder is the local part, which is
                // what the row falls back to anyway, so an empty field is never a mystery.
                TextField(person.email.split(separator: "@").first.map(String.init) ?? person.email, text: $name)
                    .font(Theme.Typography.section)
                    .foregroundStyle(Theme.Colors.foreground)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused, equals: .name)
                    .onSubmit { commitName() }
                    .frame(minHeight: Theme.Metrics.minTouchTarget, alignment: .leading)
                    .accessibilityLabel("Name")

                Text(person.email)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                nav.composing = ComposeIntent(kind: .new, to: [person.address])
                dismiss()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.Colors.foreground)
                    .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .accessibilityLabel("Write to \(person.address.display)")
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .hairline()
        .onChange(of: focused) { previous, _ in
            // Saved when the field is left rather than on every keystroke: a name is one
            // decision, not thirty, and the worker rewrites the row on every call.
            if previous == .name { commitName() }
            if previous == .notes { commitNotes() }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if person.messageCount > 0 {
            parts.append("\(person.messageCount) \(person.messageCount == 1 ? "message" : "messages")")
        }
        if person.lastSeenAt > 0 {
            parts.append("last seen \(RelativeTime.short(Date(timeIntervalSince1970: person.lastSeenAt / 1000)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Mail from them")

            // Status is a row that opens a sheet rather than four buttons in a line: the
            // four names do not fit across a phone without being shortened into guesses,
            // and this is a change worth reading a sentence about before making.
            Button {
                pickingStatus = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Goes to")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.foreground)
                        Text(blurb(for: person.screenStatus))
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text(statusValue)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.mutedForeground.opacity(0.6))
                }
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.vertical, 10)
                .frame(minHeight: Theme.Metrics.denseRowHeight)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .disabled(store.saving)
            .hairline()
            .accessibilityLabel("Mail from \(person.address.display) goes to \(statusValue)")
            .accessibilityHint("Choose a different destination")

            bundleToggle

            if app.showsAccountGlyphs { scopePicker }

            notesField
        }
    }

    private var statusValue: String {
        person.mixed == true ? "\(person.screenStatus.title) · mixed" : person.screenStatus.title
    }

    private var bundleToggle: some View {
        Toggle(isOn: Binding(get: { person.bundled }, set: { apply(bundled: $0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Bundle their mail")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                Text(bundlingApplies
                     ? "Everything they send shows as one row in the \(person.screenStatus == .imbox ? "Imbox" : "Paper Trail")."
                     : "Bundles only work for senders delivered to the Imbox or the Paper Trail.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.Colors.foreground)
        .disabled(!bundlingApplies || store.saving)
        .opacity(bundlingApplies ? 1 : 0.6)
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.vertical, 10)
        .frame(minHeight: Theme.Metrics.denseRowHeight)
        .hairline()
    }

    /// Only drawn where there is more than one mailbox to disagree — with a single account
    /// connected, "all accounts" and "this account" are the same sentence twice.
    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Applies to")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)

            HStack(spacing: 0) {
                ForEach([true, false], id: \.self) { all in
                    let selected = appliesToAll == all
                    Button {
                        guard appliesToAll != all else { return }
                        appliesToAll = all
                        Haptics.select()
                    } label: {
                        Text(all ? "All mailboxes" : "Just \(scopedEmail)")
                            .font(selected ? Theme.Typography.small.weight(.semibold) : Theme.Typography.small)
                            .foregroundStyle(selected ? Theme.Colors.background : Theme.Colors.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metrics.minTouchTarget)
                            .background(selected ? Theme.Colors.foreground : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)

                    if all {
                        Rectangle().fill(Theme.Colors.border).frame(width: 1)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.vertical, 10)
        .hairline()
    }

    private var scopedEmail: String {
        app.account(person.accountID)?.email ?? "this mailbox"
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)

            TextField("Met at the conference. Owes me a coffee.", text: $notes, axis: .vertical)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .lineLimit(2...6)
                .focused($focused, equals: .notes)
                .padding(10)
                .frame(minHeight: 64, alignment: .topLeading)
                .background(Theme.Colors.muted)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                .accessibilityLabel("Notes about \(person.address.display)")
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.vertical, 10)
    }

    // MARK: Copy

    /// What the current setting actually means for their mail, in the reader's words.
    private func blurb(for status: ScreenStatus) -> String {
        switch status {
        case .pending: return "Still waiting at the door — decide in the Screener, or pick a place here."
        case .imbox: return "Their mail lands in your Imbox, front and centre."
        case .feed: return "Their mail goes to The Feed, to browse when you feel like it."
        case .paperTrail: return "Their mail files itself into the Paper Trail."
        case .screenedOut: return "Their mail never reaches you. They will not know."
        }
    }

    // MARK: Saving

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != person.name else { return }
        write(name: trimmed, confirmation: trimmed.isEmpty ? "Name cleared" : "Renamed to \(trimmed)")
    }

    private func commitNotes() {
        guard notes != person.notes else { return }
        write(notes: notes, confirmation: "Note saved")
    }

    private func apply(screenStatus: ScreenStatus) {
        guard screenStatus != person.screenStatus || person.mixed == true else { return }
        write(screenStatus: screenStatus, confirmation: "\(person.address.display) → \(screenStatus.title)")
    }

    private func apply(bundled: Bool) {
        guard bundled != person.bundled else { return }
        write(bundled: bundled, confirmation: bundled ? "Bundled up" : "No longer bundled")
    }

    private func write(name: String? = nil,
                       notes: String? = nil,
                       screenStatus: ScreenStatus? = nil,
                       bundled: Bool? = nil,
                       confirmation: String) {
        let scope = appliesToAll ? "all" : "account"
        Task {
            let failure = await store.save(
                id: contact.id, name: name, notes: notes,
                screenStatus: screenStatus, bundled: bundled, scope: scope
            )
            if let failure {
                toasts.error(failure)
                // Put the fields back to what the server still believes, so the sheet is
                // never showing an edit that did not land.
                self.name = person.name
                self.notes = person.notes
            } else {
                Haptics.select()
                if screenStatus != nil { app.didMutate() }
                onChange?(person)
                toasts.show(confirmation)
            }
        }
    }
}

// MARK: - Clips

/// Saved passages. A clip is a quotation, so it is drawn as one — a rule down the left,
/// the text at reading size, and the thread it came from underneath in muted type.
struct ClipsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Navigator.self) private var nav
    @State private var store = ClipsStore()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Clips", titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            ScrollView {
                LazyVStack(spacing: 10) {
                    if let error = store.error {
                        EmptyState(icon: "exclamationmark.triangle", message: error)
                    } else if store.clips.isEmpty && !store.loading {
                        EmptyState(icon: "scissors", message: "Nothing clipped yet. Select text in a message to keep it.")
                    } else {
                        ForEach(store.clips) { clip in
                            Button {
                                nav.push(.thread(clip.threadID))
                            } label: {
                                ClipCard(clip: clip)
                            }
                            .buttonStyle(PressableRowStyle())
                        }
                    }
                }
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .overlay(alignment: .top) {
                if store.loading && store.clips.isEmpty {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .task { await store.load() }
    }
}

private struct ClipCard: View {
    let clip: Clip

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The quotation rule. Grayscale, and the only ornament on the card.
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(clip.text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(clip.threadSubject?.isEmpty == false ? clip.threadSubject! : "(no subject)")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(RelativeTime.short(Date(timeIntervalSince1970: clip.createdAt / 1000)))
                        .font(Theme.Typography.micro)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .layoutPriority(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Collections

/// A value pushed onto the enclosing stack for one collection. `Route` cannot grow a case
/// for it without touching shared state, and `NavigationPath` takes any `Hashable`, so the
/// destination is registered locally — the same arrangement `LabelThreadsRoute` uses below.
private struct CollectionRoute: Hashable {
    let id: String
    let name: String
}

/// Named piles of threads and files. Every row opens its collection: a pile you can see
/// the size of but not look inside is a filing cabinet with the drawers welded shut.
struct CollectionsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = CollectionsStore()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Collections", titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = store.error {
                        EmptyState(icon: "exclamationmark.triangle", message: error)
                    } else if store.collections.isEmpty && !store.loading {
                        EmptyState(icon: "folder", message: "No collections yet.")
                    } else {
                        ForEach(store.collections) { collection in
                            NavigationLink(value: CollectionRoute(id: collection.id, name: collection.name)) {
                                CollectionRow(collection: collection)
                            }
                            .buttonStyle(PressableRowStyle())
                            .hairline()
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .overlay(alignment: .top) {
                if store.loading && store.collections.isEmpty {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .navigationDestination(for: CollectionRoute.self) { route in
            CollectionDetailScreen(collectionID: route.id, name: route.name)
                .navigationBarHidden(true)
        }
        .task { await store.load() }
    }
}

private struct CollectionRow: View {
    let collection: MailCollection

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 17))
                .foregroundStyle(Theme.Colors.mutedForeground)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(collection.name)
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)
                Text(collection.description.isEmpty ? counts : "\(collection.description) · \(counts)")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.mutedForeground.opacity(0.5))
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .frame(minHeight: Theme.Metrics.denseRowHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(collection.name), \(counts)")
    }

    private var counts: String {
        let threads = "\(collection.threadCount) \(collection.threadCount == 1 ? "thread" : "threads")"
        let files = "\(collection.fileCount) \(collection.fileCount == 1 ? "file" : "files")"
        return "\(threads) · \(files)"
    }
}

/// What is in one collection: its threads, then its files.
///
/// Both in one scroll rather than behind a segmented control, because a collection is
/// usually small and made by hand — the whole point of having made it is seeing all of it
/// at once. The files come second because the threads are what was collected; the
/// attachments are what happened to be stapled to them.
private struct CollectionDetailScreen: View {
    let collectionID: String
    let name: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @State private var store = CollectionDetailStore()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: name, titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let description = store.detail?.collection.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Metrics.hPadding)
                            .padding(.top, 10)
                    }

                    content
                }
                .padding(.bottom, 24)
            }
            .refreshable { await store.load(id: collectionID) }
            .overlay(alignment: .top) {
                if store.loading && store.detail == nil {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .task { await store.load(id: collectionID) }
        .syncsWithMail { await store.load(id: collectionID) }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.detail == nil {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.load(id: collectionID) }
            }
        } else if let detail = store.detail {
            if detail.threads.isEmpty && detail.files.isEmpty {
                EmptyState(icon: "folder", message: "Nothing has been filed here yet.")
            }

            if !detail.threads.isEmpty {
                SectionHeader(title: "Threads", trailing: "\(detail.threads.count)")
                ForEach(detail.threads) { thread in
                    Button {
                        nav.push(.thread(thread.id))
                    } label: {
                        ThreadRow(thread: thread, glyph: app.glyph(for: thread.accountID), showsSnippet: app.showsPreviews)
                    }
                    .buttonStyle(PressableRowStyle())
                    .hairline()
                }
            }

            if !detail.files.isEmpty {
                SectionHeader(title: "Files", trailing: "\(detail.files.count)")
                ForEach(detail.files) { file in
                    FileRow(file: file) { threadID in nav.push(.thread(threadID)) }
                        .hairline()
                }
            }
        }
    }
}

// MARK: - Labels

/// A value pushed onto the enclosing stack for one label's threads. `Route` cannot grow a
/// case for it without touching shared state, and `NavigationPath` takes any `Hashable`,
/// so the destination is registered locally instead.
private struct LabelThreadsRoute: Hashable {
    let id: String
    let name: String
}

struct LabelsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = LabelsStore()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Labels", titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = store.error {
                        EmptyState(icon: "exclamationmark.triangle", message: error)
                    } else if store.labels.isEmpty && !store.loading {
                        EmptyState(icon: "tag", message: "No labels yet.")
                    } else {
                        ForEach(store.labels) { item in
                            NavigationLink(value: LabelThreadsRoute(id: item.id, name: item.name)) {
                                LabelRow(name: item.name, count: store.counts[item.id])
                            }
                            .buttonStyle(PressableRowStyle())
                            .hairline()
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .overlay(alignment: .top) {
                if store.loading && store.labels.isEmpty {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .navigationDestination(for: LabelThreadsRoute.self) { route in
            LabelThreadsScreen(labelID: route.id, name: route.name)
                .navigationBarHidden(true)
        }
        .task { await store.load() }
    }
}

private struct LabelRow: View {
    let name: String
    /// Nil until the count for this label has come back.
    let count: Int?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "tag")
                .font(.system(size: 17))
                .foregroundStyle(Theme.Colors.mutedForeground)
                .frame(width: 22)

            Text(name)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let count { CountBadge(count: count) }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.mutedForeground.opacity(0.5))
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel(count.map { "\(name), \($0) threads" } ?? name)
    }
}

/// One label's threads. Deliberately plain: `ThreadListScreen` owns the full list
/// behaviour (paging, swipes, selection), and duplicating any of it here would mean two
/// places to fix it. This is the label's contents and nothing more.
private struct LabelThreadsScreen: View {
    let labelID: String
    let name: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @State private var store = LabelThreadsStore()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: name, titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = store.error {
                        EmptyState(icon: "exclamationmark.triangle", message: error)
                    } else if store.threads.isEmpty && !store.loading {
                        EmptyState(icon: "tag", message: "Nothing carries this label.")
                    } else {
                        ForEach(store.threads) { thread in
                            Button {
                                nav.push(.thread(thread.id))
                            } label: {
                                ThreadRow(thread: thread, glyph: app.glyph(for: thread.accountID), showsSnippet: app.showsPreviews)
                            }
                            .buttonStyle(PressableRowStyle())
                            .hairline()
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .overlay(alignment: .top) {
                if store.loading && store.threads.isEmpty {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .task { await store.load(id: labelID) }
        .syncsWithMail { await store.load(id: labelID) }
    }
}

// MARK: - Shared chrome

/// A 44pt search field drawn in the content rather than in the bar, because these screens
/// hide the system navigation bar and `.searchable` has nowhere to live without one.
/// Shared with `FilesScreen`, which searches on the same terms.
struct LibrarySearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Colors.mutedForeground)

            TextField(placeholder, text: $text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, text.isEmpty ? 12 : 0)
        .frame(height: Theme.Metrics.minTouchTarget)
        .background(Theme.Colors.muted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.vertical, 8)
    }
}

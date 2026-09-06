import SwiftUI
import AppKit

let statusMeta: [ScreenStatus: (label: String, icon: String)] = [
    .pending: ("In Screener", "shield"), .imbox: ("Imbox", "inbox"), .feed: ("The Feed", "rss"), .paperTrail: ("Paper Trail", "fileText"), .screenedOut: ("Screened out", "shieldOff"),
]

/// `Contacts.tsx`: a table of everyone who has written, and where their mail goes.
struct ContactsPage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var store = ContactsStore()

    var body: some View {
        @Bindable var store = store
        let list = store.contacts
        let screened = list.filter { $0.screenStatus != .pending }
        let pending = list.filter { $0.screenStatus == .pending }
        PageColumn {
            PageHeader(title: "Contacts", subtitle: "Everyone who's written to you, and where their mail goes.") {
                HStack(spacing: 8) {
                    Icon("search", size: 14).foregroundStyle(W.mutedForeground)
                    WTextFieldPlain(placeholder: "Search people…", text: $store.query)
                }
                .padding(.horizontal, 10).frame(width: 224, height: 32).background(W.input).rounded(W.radiusMd)
            }
            .padding(.horizontal, -8)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            else if store.loading && list.isEmpty { SkeletonRows(rows: 8, compact: true) }
            else if list.isEmpty { EmptyStateView(icon: "shield", title: store.query.isEmpty ? "No one's written yet." : "Nobody by that name.", body: store.query.isEmpty ? "People show up here as their mail arrives, along with where you've decided it goes." : "Try a different spelling, or just part of the address.") }
            if !screened.isEmpty {
                SectionTitle("People", count: screened.count)
                ContactsTable(list: screened)
            }
            if !pending.isEmpty {
                SectionTitle("Waiting in the Screener", count: pending.count).padding(.top, screened.isEmpty ? 0 : 32)
                ContactsTable(list: pending)
            }
        }
        .task { await store.load() }
        .onChange(of: store.query) { _, _ in store.scheduleSearch() }
    }
}

private struct ContactsTable: View {
    let list: [Contact]
    @Environment(Router.self) private var router
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name").frame(width: 200, alignment: .leading).padding(.leading, 8)
                Text("Email").frame(maxWidth: .infinity, alignment: .leading)
                Text("Goes to").frame(width: 180, alignment: .leading)
                Text("Last").frame(width: 80, alignment: .trailing).padding(.trailing, 8)
            }
            .font(W.xs).foregroundStyle(W.mutedForeground).frame(height: 28)
            ForEach(list) { c in ContactRow(contact: c) }
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    @Environment(Router.self) private var router
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 0) {
            Button { router.go(.contact(contact.id)) } label: {
                HStack(spacing: 10) {
                    WAvatar(contact.address, size: 20)
                    Text(contact.name.isEmpty ? String(contact.email.split(separator: "@").first ?? "") : contact.name).font(W.font(14, 500)).lineLimit(1)
                    if contact.messageCount > 0 { Text("\(contact.messageCount)").font(W.xs).monospacedDigit().foregroundStyle(W.tertiary) }
                }
                .frame(width: 200, alignment: .leading).padding(.leading, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { router.go(.contact(contact.id)) } label: { Text(contact.email).font(W.sm).foregroundStyle(W.mutedForeground).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
            HStack(spacing: 6) {
                StatusSelect(contact: contact)
                if contact.mixed == true { WBadge("Mixed", variant: .outline, muted: true) }
            }
            .frame(width: 180, alignment: .leading)
            Text(Fmt.time(contact.lastSeenAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).frame(width: 80, alignment: .trailing).padding(.trailing, 8)
        }
        .frame(height: 40)
        .background(hovering ? W.muted : Color.clear)
        .rounded(W.radiusMd)
        .onHover { hovering = $0 }
    }
}

/// Inline "where their mail goes" property: a quiet select that mutates on change.
struct StatusSelect: View {
    let contact: Contact
    @Environment(PopLayerState.self) private var pops
    @Environment(Router.self) private var router
    @State private var hovering = false

    var body: some View {
        let m = statusMeta[contact.screenStatus] ?? ("", "")
        if contact.screenStatus == .pending {
            Button { router.go(.screener) } label: { WBadge("In Screener", icon: "shield", variant: .secondary, muted: true, small: true) }.buttonStyle(.plain)
        } else {
            let id = "status-\(contact.id)"
            Button {
                pops.toggle(id, side: .bottom, align: .end) {
                    PopCard(width: 176) {
                        ForEach([ScreenStatus.imbox, .feed, .paperTrail, .screenedOut], id: \.self) { s in
                            MenuItem(statusMeta[s]!.label, icon: statusMeta[s]!.icon, checked: s == contact.screenStatus) { update(s) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Icon(m.icon, size: 14)
                    Text(m.label).font(W.s13)
                    Icon("chevronDown", size: 12).opacity(hovering ? 1 : 0)
                }
                .foregroundStyle(hovering || pops.isOpen(id) ? W.foreground : W.mutedForeground)
                .padding(.horizontal, 6).frame(height: 28)
                .background(hovering || pops.isOpen(id) ? W.muted : Color.clear)
                .rounded(W.radiusMd)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popAnchor(id)
            .onHover { hovering = $0 }
        }
    }

    private func update(_ s: ScreenStatus) {
        Task {
            do { _ = try await APIClient.shared.updateContact(contact.id, screenStatus: s); Mail.invalidate() }
            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
}

/// `/contacts/email/:email` → the contact's page.
struct ContactByEmailPage: View {
    let email: String
    @Environment(Router.self) private var router
    @State private var error: String?
    var body: some View {
        Group {
            if let error { ErrorStateView(message: error) }
            else { Text("Opening contact…").font(W.sm).foregroundStyle(W.mutedForeground).padding(24) }
        }
        .task {
            do {
                struct R: Decodable { let id: String }
                let r = try await APIClient.shared.get("/api/contacts/by-email", query: ["email": email], as: R.self)
                router.replace(.contact(r.id))
            } catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
        }
    }
}

/// `ContactDetail.tsx`.
struct ContactDetailPage: View {
    let contactID: String
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var store = ContactDetailStore()
    @State private var name = ""
    @State private var notes = ""
    @State private var saveState = "idle"
    @State private var loaded = false
    @State private var autosave: Task<Void, Never>?

    private let blurb: [ScreenStatus: String] = [
        .pending: "Still waiting at the door. Decide in the Screener, or pick a place here.",
        .imbox: "Their mail lands in your Imbox, front and centre.",
        .feed: "Their mail goes to The Feed — browse it when you feel like it.",
        .paperTrail: "Their mail files itself into the Paper Trail.",
        .screenedOut: "Their mail never reaches you. They won't know.",
    ]

    var body: some View {
        if let error = store.error, store.detail == nil { ErrorStateView(message: error) { Task { await store.load(id: contactID) } } }
        else if let d = store.detail {
            let c = d.contact
            let status = c.screenStatus
            PageColumn {
                WButton("Back", icon: "arrowLeft", variant: .ghost, size: .sm, muted: true, kbd: "esc") { router.back() }.padding(.bottom, 16)
                HStack(alignment: .top, spacing: 16) {
                    WAvatar(c.address, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(String(c.email.split(separator: "@").first ?? ""), text: $name)
                            .textFieldStyle(.plain).font(W.font(24, 600)).tracking(-0.48).foregroundStyle(W.foreground)
                            .onSubmit { commitName(c) }
                        HStack(spacing: 8) {
                            Text(c.email).font(W.sm).foregroundStyle(W.mutedForeground)
                            WBadge(String(c.email.split(separator: "@").last ?? ""), variant: .outline, muted: true)
                            if app.accounts.count > 1 { HStack(spacing: 4) { AccountGlyph(glyph: app.glyph(for: c.accountID)); Text(app.account(c.accountID)?.email ?? "") }.font(W.xs).foregroundStyle(W.mutedForeground) }
                        }
                    }
                    Spacer()
                    WButton("Write", icon: "penSquare", variant: .outline, size: .sm) { Compose.open(ComposerInitial(to: [c.address])) }
                }
                .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 4) {
                    property("Messages") { Text("\(c.messageCount) · first seen \(Fmt.date(c.firstSeenAt)) · last \(Fmt.relative(c.lastSeenAt))").font(W.sm).monospacedDigit().padding(.top, 6) }
                    property("Mail goes to") {
                        VStack(alignment: .leading, spacing: 6) {
                            WToggleGroup(options: [ScreenStatus.imbox, .feed, .paperTrail, .screenedOut].map { ToggleOption(id: $0.rawValue, label: statusMeta[$0]!.label, icon: statusMeta[$0]!.icon) },
                                         value: Binding(get: { status == .pending ? "" : status.rawValue }, set: { v in Task { if let e = await store.save(id: contactID, screenStatus: ScreenStatus(rawValue: v)) { Toasts.shared.error(e) } else { Mail.invalidate() } } }))
                            Text(blurb[status] ?? "").font(W.s13).foregroundStyle(W.mutedForeground)
                        }
                    }
                    property("Bundled up") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                WSwitch(on: Binding(get: { c.bundled }, set: { on in Task { if let e = await store.save(id: contactID, bundled: on) { Toasts.shared.error(e) } else { Mail.invalidate() } } }))
                                    .disabled(status != .imbox && status != .paperTrail)
                                HStack(spacing: 6) { Icon("layers", size: 14).foregroundStyle(W.mutedForeground); Text(c.bundled ? "Bundled up" : "Not bundled").font(W.sm) }
                            }
                            .opacity(status == .imbox || status == .paperTrail ? 1 : 0.6)
                            .padding(.top, 6)
                            Text(status == .imbox || status == .paperTrail ? "All their mail shows as one row in the \(status == .imbox ? "Imbox" : "Paper Trail"), no matter how much they send." : "Bundles work for senders delivered to the Imbox or the Paper Trail.").font(W.s13).foregroundStyle(W.mutedForeground)
                        }
                    }
                    property("Notes") {
                        ZStack(alignment: .topTrailing) {
                            WTextArea(placeholder: "Met at the conference. Owes me a coffee.", text: $notes, minHeight: 72)
                            HStack(spacing: 4) {
                                if saveState == "saving" { Text("Saving…") } else if saveState == "saved" { Icon("check", size: 11); Text("Saved") }
                            }
                            .font(W.font(11)).foregroundStyle(W.mutedForeground).padding(8).opacity(saveState == "idle" ? 0 : 1)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 24).padding(.bottom, 16)
                .edgeLine(.bottom)

                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle("Conversations", count: d.threads.count)
                    ThreadListView(sections: [ListSection(threads: d.threads, emptyTitle: "Nothing between you two yet.", emptyBody: "Threads with this person will collect here.")], showBucket: true)
                }
                .padding(.top, 24)
            }
            .onAppear { if !loaded { loaded = true; name = c.name; notes = c.notes } }
            .onChange(of: notes) { _, n in
                guard loaded, n != c.notes else { return }
                saveState = "saving"
                autosave?.cancel()
                autosave = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    if await store.save(id: contactID, notes: n) == nil { saveState = "saved"; try? await Task.sleep(for: .seconds(2)); if saveState == "saved" { saveState = "idle" } } else { saveState = "idle" }
                }
            }
            .onKeys(["Escape": { router.back() }])
        } else {
            PageColumn { SkeletonBlock(width: 80, height: 24).padding(.bottom, 24); HStack(spacing: 16) { SkeletonBlock(width: 40, height: 40, radius: 4); VStack(alignment: .leading, spacing: 12) { SkeletonBlock(width: 280, height: 28); SkeletonBlock(width: 200, height: 16) } } }
                .task { await store.load(id: contactID) }
        }
    }

    private func property<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(W.s13).foregroundStyle(W.mutedForeground).frame(width: 112, alignment: .leading).padding(.top, 6)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
    }

    private func commitName(_ c: Contact) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n != c.name else { return }
        Task { if let e = await store.save(id: contactID, name: n) { Toasts.shared.error(e) } }
    }
}

// MARK: - Clips

struct ClipsPage: View {
    @Environment(Router.self) private var router
    @State private var store = ClipsStore()
    @State private var cursor = -1

    var body: some View {
        let list = store.clips
        PageColumn {
            PageHeader(title: "Clips", subtitle: "Bits of text you saved. Codes, addresses, the good sentence.").padding(.horizontal, -8)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            else if store.loading && list.isEmpty { SkeletonRows(rows: 5) }
            else if list.isEmpty { EmptyStateView(icon: "scissors", title: "Nothing clipped yet.", body: "Select any text inside an email and hit Save clip. It'll wait here so you never dig for it again.") }
            VStack(spacing: 2) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, c in ClipRow(clip: c, focused: cursor == i) { Task { await store.load() } } }
            }
        }
        .task { await store.load() }
        .syncsWithMail { await store.load() }
        .onKeys(["j": { cursor = min(cursor + 1, list.count - 1) }, "k": { cursor = max(cursor - 1, 0) }, "ArrowDown": { cursor = min(cursor + 1, list.count - 1) }, "ArrowUp": { cursor = max(cursor - 1, 0) },
                 "Enter": { if list.indices.contains(cursor) { router.go(.thread(list[cursor].threadID, peek: false)) } }])
    }
}

private struct ClipRow: View {
    let clip: Clip
    var focused = false
    var onDeleted: () -> Void
    @Environment(Router.self) private var router
    @State private var hovering = false
    @State private var copied = false
    @State private var leaving = false

    var body: some View {
        let text = clip.text
        let codeLike = text.count < 80 && text.trimmingCharacters(in: .whitespaces).range(of: #"^[A-Z0-9\-]{4,24}$"#, options: .regularExpression) != nil
        VStack(alignment: .leading, spacing: 6) {
            if codeLike {
                Text(text.trimmingCharacters(in: .whitespaces)).font(W.mono(16)).tracking(1).textSelection(.enabled).padding(.vertical, 4)
            } else {
                Text(text).font(W.sm).lineSpacing(5).lineLimit(6).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button { router.go(.thread(clip.threadID, peek: false)) } label: {
                    HStack(spacing: 6) { Icon("messageSquare", size: 12); Text(clip.threadSubject ?? "Open thread").lineLimit(1).frame(maxWidth: 280, alignment: .leading) }
                }
                .buttonStyle(.plain)
                Text("·").foregroundStyle(W.tertiary)
                Text(Fmt.date(clip.createdAt)).monospacedDigit()
                Spacer()
                HStack(spacing: 0) {
                    WButton(icon: copied ? "check" : "copy", variant: .ghost, size: .iconXs, muted: true, help: copied ? "Copied" : "Copy") {
                        Platform.copy(text); copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                    }
                    WButton(icon: "trash2", variant: .ghost, size: .iconXs, muted: true, help: "Delete") {
                        leaving = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Task { do { try await APIClient.shared.deleteClip(clip.id); onDeleted() } catch { leaving = false; Toasts.shared.error(error.localizedDescription) } } }
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
            .font(W.xs).foregroundStyle(W.mutedForeground)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? W.muted : Color.clear)
        .overlay { if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.ring, lineWidth: 1) } }
        .rounded(W.radiusMd)
        .opacity(leaving ? 0 : 1)
        .onHover { hovering = $0 }
    }
}

// MARK: - Collections

struct CollectionsPage: View {
    @Environment(Router.self) private var router
    @Environment(DialogState.self) private var dialogs
    @State private var store = CollectionsStore()
    @State private var cursor = -1

    var body: some View {
        let list = store.collections
        PageColumn {
            PageHeader(title: "Collections", subtitle: "Bundle related threads and files into one tidy place.") {
                WButton("New", icon: "plus", variant: .ghost, size: .sm, muted: true) { newCollection() }
            }
            .padding(.horizontal, -8)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            else if store.loading && list.isEmpty { SkeletonRows(rows: 4, compact: true) }
            else if list.isEmpty { EmptyStateView(icon: "folderOpen", title: "No collections yet.", body: "Gather every thread and attachment about one thing, so you stop hunting across your mail.") { WButton("Start one", icon: "plus", variant: .outline, size: .sm) { newCollection() } } }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                CollectionRow(collection: c, focused: cursor == i)
            }
        }
        .task { await store.load() }
        .onKeys(["j": { cursor = min(cursor + 1, list.count - 1) }, "k": { cursor = max(cursor - 1, 0) }, "ArrowDown": { cursor = min(cursor + 1, list.count - 1) }, "ArrowUp": { cursor = max(cursor - 1, 0) },
                 "Enter": { if list.indices.contains(cursor) { router.go(.collection(list[cursor].id)) } }])
    }

    private func newCollection() {
        dialogs.present("new-collection", width: 448) {
            CollectionForm(title: "New collection", description: "A project, a trip, a house move — anything with a lot of email around it.", submit: "Create") { name, desc in
                do {
                    _ = try await APIClient.shared.post("/api/collections", body: ["name": name, "description": desc], as: MailCollection.self)
                    await store.load()
                    dialogs.dismiss("new-collection")
                } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
            } onCancel: { dialogs.dismiss("new-collection") }
        }
    }
}

struct CollectionForm: View {
    let title: String
    var description: String? = nil
    var submit: String
    var initialName = ""
    var initialDesc = ""
    var onSubmit: (String, String) async -> Void
    var onCancel: () -> Void
    @State private var name = ""
    @State private var desc = ""
    @State private var busy = false

    var body: some View {
        FormDialog(title: title, description: description) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) { FieldLabel("Name"); WTextField(placeholder: "Kitchen renovation", text: $name, autofocus: true) }
                VStack(alignment: .leading, spacing: 6) { FieldLabel("What's it for?"); WTextArea(placeholder: "Quotes, contractor threads, the permit saga…", text: $desc, minHeight: 72); Text("Optional.").font(W.xs).foregroundStyle(W.mutedForeground) }
            }
        } footer: {
            WButton("Cancel", variant: .ghost, action: onCancel)
            WButton(submit) { busy = true; Task { await onSubmit(name.trimmingCharacters(in: .whitespaces), desc.trimmingCharacters(in: .whitespaces)); busy = false } }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
        .onAppear { name = initialName; desc = initialDesc }
    }
}

private struct CollectionRow: View {
    let collection: MailCollection
    var focused = false
    @Environment(Router.self) private var router
    @State private var hovering = false
    var body: some View {
        Button { router.go(.collection(collection.id)) } label: {
            HStack(spacing: 12) {
                Icon("folderOpen", size: 16).foregroundStyle(W.mutedForeground).frame(width: 20)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(collection.name).font(W.font(14, 500)).lineLimit(1)
                    if !collection.description.isEmpty { Text(collection.description).font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1) }
                }
                Spacer()
                HStack(spacing: 12) {
                    HStack(spacing: 4) { Icon("messagesSquare", size: 12); Text("\(collection.threadCount)") }
                    HStack(spacing: 4) { Icon("paperclip", size: 12); Text("\(collection.fileCount)") }
                }
                .font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
            }
            .padding(.horizontal, 8).frame(height: 44)
            .background(focused || hovering ? W.muted : Color.clear)
            .rounded(W.radiusMd)
            .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct CollectionDetailPage: View {
    let collectionID: String
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @Environment(DialogState.self) private var dialogs
    @State private var store = CollectionDetailStore()

    var body: some View {
        if let error = store.error, store.detail == nil { ErrorStateView(message: error) { Task { await store.load(id: collectionID) } } }
        else if let d = store.detail {
            let c = d.collection
            PageColumn {
                WButton("Collections", icon: "arrowLeft", variant: .ghost, size: .sm, muted: true) { router.go(.collections) }.padding(.bottom, 16)
                HStack(alignment: .top, spacing: 12) {
                    Icon("folderOpen", size: 22).foregroundStyle(W.mutedForeground).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.name).font(W.font(24, 600)).tracking(-0.48)
                        if !c.description.isEmpty { Text(c.description).font(W.sm).foregroundStyle(W.mutedForeground) }
                        HStack(spacing: 8) {
                            WBadge("\(d.threads.count) thread\(d.threads.count == 1 ? "" : "s")", icon: "messagesSquare", variant: .secondary, muted: true)
                            WBadge("\(d.files.count) file\(d.files.count == 1 ? "" : "s")", icon: "paperclip", variant: .secondary, muted: true)
                        }
                        .padding(.top, 4)
                    }
                    Spacer()
                    WButton(icon: "moreHorizontal", variant: .ghost, size: .iconSm, muted: true, expanded: pops.isOpen("col-more"), help: "More") {
                        pops.toggle("col-more", side: .bottom, align: .end) {
                            PopCard(width: 192) {
                                MenuItem("Rename & describe", icon: "pencil") {
                                    dialogs.present("edit-collection", width: 448) {
                                        CollectionForm(title: "Edit collection", submit: "Save", initialName: c.name, initialDesc: c.description) { name, desc in
                                            do { _ = try await APIClient.shared.patch("/api/collections/\(c.id)", body: ["name": name, "description": desc], as: MailCollection.self); await store.load(id: collectionID); dialogs.dismiss("edit-collection") }
                                            catch { Toasts.shared.error(error.localizedDescription) }
                                        } onCancel: { dialogs.dismiss("edit-collection") }
                                    }
                                }
                                MenuSeparator()
                                MenuItem("Delete collection", icon: "trash2") {
                                    dialogs.confirm(title: "Delete this collection?", description: "Threads and files stay where they are; only the grouping goes away.", action: "Delete") {
                                        Task { try? await APIClient.shared.delete("/api/collections/\(c.id)"); router.go(.collections) }
                                    }
                                }
                            }
                        }
                    }
                    .popAnchor("col-more")
                }
                .padding(.horizontal, 8).padding(.bottom, 24)

                SectionTitle("Threads", count: d.threads.count)
                ThreadListView(sections: [ListSection(threads: d.threads, emptyTitle: "Nothing in here yet.", emptyBody: "Add threads from any thread's More menu, or select a few and use the bulk bar.")], showBucket: true)
                if !d.threads.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(d.threads) { t in
                            Button { Mail.rawBulk([t.id], ["action": "collections", "remove": [c.id]], toast: "Removed “\(t.displaySubject)”"); Task { try? await Task.sleep(for: .milliseconds(400)); await store.load(id: collectionID) } } label: {
                                HStack(spacing: 4) { Text(t.displaySubject).lineLimit(1).frame(maxWidth: 260); Icon("x", size: 12) }
                                    .font(W.xs).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).frame(height: 20).overlay(Capsule().strokeBorder(W.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain).help("Remove from collection")
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                }
                SectionTitle("Files", count: d.files.count).padding(.top, 32)
                if d.files.isEmpty { Text("No attachments in these threads.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 12) }
                else { FileGrid(files: d.files, cursor: -1) }
            }
        } else {
            PageColumn { SkeletonBlock(width: 96, height: 24).padding(.bottom, 24); SkeletonBlock(width: 320, height: 32).padding(.bottom, 12); SkeletonBlock(width: 200, height: 16) }
                .task { await store.load(id: collectionID) }
        }
    }
}

// MARK: - Files

struct FilesPage: View {
    @State private var store = FilesStore()
    @State private var cursor = -1

    var body: some View {
        @Bindable var store = store
        let all = store.files
        let list = store.visible
        PageColumn {
            PageHeader(title: "Files", subtitle: "Every attachment anyone has ever sent you, in one place.") {
                if !all.isEmpty { Text("\(all.count) files · \(Fmt.size(store.totalBytes))").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground) }
            }
            .padding(.horizontal, -8)
            WToggleGroup(options: FileFilter.allCases.map { ToggleOption(id: $0.rawValue, label: $0.title) }, value: Binding(get: { store.filter.rawValue }, set: { store.filter = FileFilter(rawValue: $0) ?? .all }))
                .padding(.horizontal, 8).padding(.bottom, 16)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.refresh() } } }
            else if store.loading && all.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) { ForEach(0..<8, id: \.self) { _ in SkeletonBlock(height: 180) } }.padding(.horizontal, 8)
            } else if list.isEmpty {
                EmptyStateView(icon: "file", title: store.filter == .all ? "No files yet." : "No \(store.filter.title.lowercased()) here.", body: store.filter == .all ? "Attachments show up here as your mail syncs." : "Try another type, or clear the filter.")
            }
            FileGrid(files: list, cursor: cursor)
            LoadMore(hasMore: store.hasMore, loading: store.loadingMore) { Task { await store.loadMore() } }
        }
        .task { await store.firstLoad() }
        .onKeys(["j": { cursor = min(cursor + 1, list.count - 1) }, "k": { cursor = max(cursor - 1, 0) }, "ArrowDown": { cursor = min(cursor + 1, list.count - 1) }, "ArrowUp": { cursor = max(cursor - 1, 0) }])
    }
}

struct FileGrid: View {
    let files: [Attachment]
    var cursor: Int
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 4), alignment: .leading, spacing: 20) {
            ForEach(Array(files.enumerated()), id: \.element.id) { i, f in FileTile(file: f, focused: cursor == i) }
        }
        .padding(.horizontal, 8)
    }
}

struct FileTile: View {
    let file: Attachment
    var focused = false
    @Environment(Router.self) private var router
    @State private var hovering = false
    @State private var image: PlatformImage?

    private var kind: FileKind { FileKind.of(mimeType: file.mimeType, filename: file.filename) }
    private var ext: String { (file.filename as NSString).pathExtension.uppercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                W.muted
                if let image { Image(platformImage: image).resizable().scaledToFill() }
                else {
                    VStack(spacing: 6) {
                        Icon(kind.icon, size: 24)
                        if !ext.isEmpty { Text(ext).font(W.font(11)).tracking(0.5) }
                    }
                    .foregroundStyle(W.mutedForeground)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .rounded(W.radiusMd)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { save() } label: { Icon("download", size: 14).foregroundStyle(W.mutedForeground).frame(width: 28, height: 28).background(W.background.opacity(0.9)).rounded(W.radiusMd) }
                        .buttonStyle(.plain).padding(6).help("Download")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { save() }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename.isEmpty ? "attachment" : file.filename).font(W.font(13, 500)).lineLimit(1).help(file.filename)
                Text("\(Fmt.size(file.size)) · \(Fmt.date(file.createdAt))").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).lineLimit(1)
                if file.from != nil || file.threadSubject != nil, let tid = file.threadID {
                    Button { router.go(.thread(tid, peek: false)) } label: {
                        HStack(spacing: 4) { Icon("messageSquare", size: 11); Text([file.from?.display, file.threadSubject].compactMap { $0 }.joined(separator: " · ")).lineLimit(1) }
                            .font(W.xs).foregroundStyle(W.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2).padding(.top, 8)
        }
        .overlay { if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.ring, lineWidth: 1) } }
        .onHover { hovering = $0 }
        .task {
            guard kind == .image, let url = ServerConfig.shared.baseURL?.appendingPathComponent("/api/messages/\(file.messageID)/attachments/\(file.id)") else { return }
            if let data = try? await APIClient.shared.data(path: "/api/messages/\(file.messageID)/attachments/\(file.id)", query: file.accountID.map { ["account_id": $0] } ?? [:]) { image = PlatformImage(data: data) }
            _ = url
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.filename
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task {
            do {
                let data = try await APIClient.shared.data(path: "/api/messages/\(file.messageID)/attachments/\(file.id)", query: file.accountID.map { ["account_id": $0] } ?? [:])
                try data.write(to: target, options: .atomic)
                Toasts.shared.show("Saved \(file.filename)")
            } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? "Couldn't download that.") }
        }
    }
}

// MARK: - Labels

struct LabelsPage: View {
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var store = LabelsStore()
    @State private var name = ""
    @State private var color = labelShades[0]
    @State private var cursor = -1

    var body: some View {
        let list = store.labels
        PageColumn {
            PageHeader(title: "Labels", subtitle: "Light-touch tags for cross-cutting stuff. Press b on any thread to add one.").padding(.horizontal, -8)
            HStack(spacing: 12) {
                ShadeButton(id: "new-label-shade", color: $color)
                WTextFieldPlain(placeholder: "New label…", text: $name).onSubmit { create() }
                WButton("Add", icon: "plus", variant: .ghost, size: .sm, muted: true) { create() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 8).frame(height: 40).background(W.muted40).rounded(W.radiusMd).padding(.bottom, 16)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            else if store.loading && list.isEmpty { SkeletonRows(rows: 4, compact: true) }
            else if list.isEmpty { EmptyStateView(icon: "tag", title: "No labels yet.", body: "Make one above.", compact: true) }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, l in LabelRow(label: l, focused: cursor == i) { Task { await store.load() } } }
        }
        .task { await store.load() }
        .onKeys(["j": { cursor = min(cursor + 1, list.count - 1) }, "k": { cursor = max(cursor - 1, 0) }, "Enter": { if list.indices.contains(cursor) { router.go(.label(list[cursor].id)) } }])
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task {
            do {
                _ = try await APIClient.shared.post("/api/labels", body: ["name": n, "color": color], as: MailLabel.self)
                name = ""; color = labelShades[(store.labels.count + 1) % labelShades.count]
                await store.load()
            } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
}

struct ShadeButton: View {
    let id: String
    @Binding var color: String
    @Environment(PopLayerState.self) private var pops
    var body: some View {
        Button {
            pops.toggle(id, side: .bottom, align: .start) {
                PopCard(padding: 8) {
                    HStack(spacing: 6) {
                        ForEach(labelShades, id: \.self) { c in
                            Button { color = c; pops.closeAll() } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(colorFromHex(c))
                                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(W.foreground.opacity(0.15), lineWidth: 1)
                                    if color == c { Icon("check", size: 12, strokeWidth: 3).foregroundStyle(.white).blendMode(.difference) }
                                }
                                .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(colorFromHex(color)).overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.15), lineWidth: 1)).frame(width: 14, height: 14)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popAnchor(id)
        .help("Shade")
    }
}

private struct LabelRow: View {
    let label: MailLabel
    var focused = false
    var onChanged: () -> Void
    @Environment(Router.self) private var router
    @Environment(DialogState.self) private var dialogs
    @State private var name = ""
    @State private var color = ""
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ShadeButton(id: "shade-\(label.id)", color: $color).onChange(of: color) { _, c in if !c.isEmpty, c != label.color { patch(["color": c]) } }
            TextField("Label name", text: $name).textFieldStyle(.plain).font(W.font(14, 500)).foregroundStyle(W.foreground).onSubmit { commit() }
            Button { router.go(.label(label.id)) } label: { HStack(spacing: 4) { Text("Threads"); Icon("arrowRight", size: 12) }.font(W.s13).foregroundStyle(W.mutedForeground) }.buttonStyle(.plain)
            WButton(icon: "trash2", variant: .ghost, size: .iconXs, muted: true, help: "Delete") {
                dialogs.confirm(title: "Delete “\(label.name)”?", description: "It comes off every thread. The threads themselves stay put.", action: "Delete label") {
                    Task { try? await APIClient.shared.delete("/api/labels/\(label.id)"); onChanged() }
                }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8).frame(height: 40)
        .background(focused || hovering ? W.muted : Color.clear)
        .rounded(W.radiusMd)
        .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
        .onHover { hovering = $0 }
        .onAppear { name = label.name; color = label.color }
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { name = label.name; return }
        if n != label.name { patch(["name": n]) }
    }
    private func patch(_ body: [String: Any]) {
        Task { do { _ = try await APIClient.shared.patch("/api/labels/\(label.id)", body: body, as: MailLabel.self); onChanged() } catch { Toasts.shared.error(error.localizedDescription) } }
    }
}

struct LabelThreadsPage: View {
    let labelID: String
    @Environment(Router.self) private var router
    @State private var labels = LabelsStore()
    @State private var store = LabelThreadsStore()

    var body: some View {
        let label = labels.labels.first { $0.id == labelID }
        let n = store.threads.count
        PageColumn {
            PageHeader(title: label?.name ?? "Label", subtitle: n > 0 ? "\(n) \(n == 1 ? "thread" : "threads") with this label." : "A label.", titleIcon: "tag") {
                WButton("All labels", variant: .ghost, size: .sm, muted: true) { router.go(.labels) }
            }
            ThreadListView(sections: [ListSection(threads: store.threads, emptyTitle: "Nothing wears this label yet.", emptyBody: "Select a thread and press b to tag it.")], loading: store.loading && store.threads.isEmpty, error: store.error, onRetry: { Task { await store.load(id: labelID) } }, showBucket: true, emptyIcon: "tag")
        }
        .task { await labels.load(); await store.load(id: labelID) }
        .syncsWithMail { await store.load(id: labelID) }
    }
}

// MARK: - Drafts

struct DraftsPage: View {
    let scheduled: Bool
    @Environment(AppState.self) private var app
    @Environment(DialogState.self) private var dialogs
    @State private var drafts = DraftsStore()
    @State private var queue = ScheduledStore()
    @State private var cursor = -1

    private var list: [Draft] { scheduled ? queue.queued : drafts.unsent }
    private var loading: Bool { scheduled ? queue.loading : drafts.loading }

    var body: some View {
        PageColumn {
            PageHeader(title: scheduled ? "Scheduled" : "Drafts", subtitle: scheduled ? "Going out later, automatically." : "Half-written thoughts, waiting.") {
                if !scheduled { WButton("New message", icon: "penSquare", variant: .ghost, size: .sm) { Compose.open() } }
            }
            if let error = (scheduled ? queue.error : drafts.error) { ErrorStateView(message: error) { Task { await reload() } } }
            else if loading && list.isEmpty { SkeletonRows(rows: 4) }
            else if list.isEmpty {
                EmptyStateView(icon: scheduled ? "calendarClock" : "penSquare", title: scheduled ? "Nothing scheduled." : "No drafts.", body: scheduled ? "Use the arrow next to Send to pick a time." : "Press c to start one. We'll keep it here until you send it.") {
                    if !scheduled { WButton("Start writing", variant: .ghost, size: .sm) { Compose.open() } }
                }
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, d in
                DraftRow(draft: d, scheduled: scheduled, focused: cursor == i, onOpen: { open(d) },
                         onCancel: { Task { if let e = await queue.cancel(d) { Toasts.shared.error(e) } else { Mail.invalidate(); await reload() } } },
                         onDelete: { dialogs.confirm(title: "Delete this draft?", description: "It's gone for good — there's no undo for drafts.", cancel: "Keep it", action: "Delete") { Task { _ = scheduled ? await queue.delete(d) : await drafts.delete(d); await reload() } } })
            }
        }
        .task { await reload() }
        .syncsWithMail { await reload() }
        .onKeys(["j": { cursor = min(cursor + 1, list.count - 1) }, "k": { cursor = max(cursor - 1, 0) }, "Enter": { if list.indices.contains(cursor) { open(list[cursor]) } }])
    }

    private func reload() async { if scheduled { await queue.load() } else { await drafts.load() } }

    private func open(_ d: Draft) {
        Compose.open(ComposerInitial(draftID: d.id, accountID: d.accountID, threadID: d.threadID, replyToMessageID: d.replyToMessageID, to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, bodyHTML: d.bodyHTML, title: d.status == "draft" ? "Draft" : "Scheduled message"))
    }
}

private struct DraftRow: View {
    let draft: Draft
    let scheduled: Bool
    var focused = false
    var onOpen: () -> Void
    var onCancel: () -> Void
    var onDelete: () -> Void
    @Environment(AppState.self) private var app
    @State private var hovering = false

    private var preview: String {
        var s = draft.bodyHTML
        s = s.replacingOccurrences(of: #"<div class="hey-signature">[\s\S]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<div class="hey-quote">[\s\S]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return String(HTMLText.plain(from: s).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(120))
    }

    var body: some View {
        let people = draft.to.isEmpty ? draft.cc : draft.to
        HStack(spacing: 10) {
            ZStack {
                if people.count > 1 { WAvatarStack(people: people, size: 20, max: 2) } else if let p = people.first { WAvatar(p, size: 20) } else { Icon("penSquare", size: 14).foregroundStyle(W.mutedForeground) }
            }
            .frame(width: 20, height: 20)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if people.isEmpty { Text("No recipients yet").font(W.font(13, 500)).foregroundStyle(W.mutedForeground) }
                        else { Text(people.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", ")).font(W.font(13, 500)).lineLimit(1) }
                        if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: draft.accountID)) }
                        if draft.status == "failed" { WBadge("Failed", variant: .outline, muted: true, small: true) }
                        if draft.status == "sending" { WBadge("Sending", variant: .outline, muted: true, small: true) }
                    }
                    HStack(spacing: 6) {
                        Text(draft.subject.isEmpty ? "(no subject)" : draft.subject).font(W.s13).foregroundStyle(W.foreground80).lineLimit(1).layoutPriority(1)
                        if !preview.isEmpty { Text("— \(preview)").font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hovering || focused {
                if draft.status == "scheduled" { WButton("Cancel", icon: "x", variant: .ghost, size: .xs, action: onCancel) }
                else { WButton(icon: "trash2", variant: .ghost, size: .iconXs, help: "Delete draft", action: onDelete) }
            } else if scheduled, let at = draft.sendAt {
                WBadge(Fmt.full(at), icon: "calendarClock", variant: .secondary, muted: true)
            } else {
                Text(Fmt.time(draft.updatedAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
            }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(focused || hovering ? W.muted : Color.clear)
        .rounded(W.radiusMd)
        .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
        .onHover { hovering = $0 }
    }
}

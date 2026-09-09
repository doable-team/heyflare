import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// `ComposerInitial`: everything the composer needs to prefill itself.
struct ComposerInitial {
    var draftID: String? = nil
    var accountID: String? = nil
    var threadID: String? = nil
    var replyToMessageID: String? = nil
    var to: [Address] = []
    var cc: [Address] = []
    var bcc: [Address] = []
    var subject = ""
    var bodyHTML = ""
    var quotedHTML = ""
    var title: String? = nil
    /// Files carried over from an unsent message, so undo/edit keeps them.
    var attachments: [ComposeAttachmentFile] = []
    /// A reopened message already carries its signature (the HTML round-trip drops the
    /// marker class), so it must not get another.
    var skipSignature = false
}

/// `ComposeContext`: opens the composer in the right-hand sheet, and runs the undo-send
/// window with its toast.
@MainActor
enum Compose {
    static weak var current: ComposerModel?
    private static var pending: (payload: [String: Any], toast: Int, task: Task<Void, Never>)?

    static func open(_ initial: ComposerInitial = ComposerInitial()) {
        // ⌘N or the palette over an open composer: what was typed is kept, not replaced.
        if let existing = current, SheetState.shared.isOpen { Task { await existing.saveAndClose(); open(initial) }; return }
        let model = ComposerModel(initial: initial)
        model.onDone = { close() }
        model.onCancel = { close() }
        current = model
        let title = initial.title ?? (initial.threadID != nil ? "Reply" : "New message")
        SheetState.shared.present(title: title, width: 600, onRequestClose: { Task { await model.saveAndClose() } }) {
            ComposerView(model: model, inline: false)
        }
    }

    static func close() {
        SheetState.shared.dismiss()
        current = nil
    }

    static func sendShortcut() {
        current?.send()
    }

    /// `ComposeContext.tsx`: something is still inside its undo window.
    static var hasPendingSend: Bool { pending != nil }

    /// The web's `beforeunload` beacon: on quit, a queued message goes out now rather than
    /// being dropped with the process.
    static func flushPendingSend() async {
        guard let p = pending else { return }
        p.task.cancel()
        pending = nil
        _ = try? await APIClient.shared.send(p.payload)
    }

    static func queueSend(_ payload: [String: Any], undoSeconds: Int) {
        // `ComposeContext.tsx`: a second send inside the undo window clears the timer and
        // replaces the pending message — the first one is never sent, and its toast runs
        // out on its own.
        if let p = pending {
            p.task.cancel()
            pending = nil
        }
        let secs = max(0, undoSeconds)
        if secs <= 0 { Task { await fire(payload) }; return }
        let toastID = Toasts.shared.show("Sending…", description: "Press q to undo within \(secs)s.", duration: Double(secs), action: ("Undo", { undoSend() }))
        let task = Task {
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled else { return }
            pending = nil
            await fire(payload)
        }
        pending = (payload, toastID, task)
    }

    static func undoSend() {
        guard let p = pending else { return }
        p.task.cancel()
        Toasts.shared.dismiss(p.toast)
        pending = nil
        open(initial(from: p.payload, title: "Unsent message"))
    }

    private static func fire(_ payload: [String: Any]) async {
        do {
            _ = try await APIClient.shared.send(payload)
            Toasts.shared.success("Sent")
            Mail.invalidate()
        } catch {
            Toasts.shared.show("Couldn't send", description: (error as? APIError)?.errorDescription ?? error.localizedDescription, kind: .error, duration: 10,
                               action: ("Edit", { open(initial(from: payload, title: "Unsent message")) }))
        }
    }

    static func initial(from payload: [String: Any], title: String) -> ComposerInitial {
        func addresses(_ v: Any?) -> [Address] {
            (v as? [[String: Any]])?.compactMap { d in (d["email"] as? String).map { Address(email: $0, name: d["name"] as? String ?? "") } } ?? []
        }
        let files = (payload["attachments"] as? [[String: Any]])?.compactMap { d -> ComposeAttachmentFile? in
            guard let name = d["filename"] as? String, let b64 = d["data_base64"] as? String, let data = Data(base64Encoded: b64) else { return nil }
            return ComposeAttachmentFile(filename: name, mimeType: d["mime_type"] as? String ?? "application/octet-stream", data: data)
        } ?? []
        return ComposerInitial(draftID: payload["draft_id"] as? String, accountID: payload["account_id"] as? String, threadID: payload["thread_id"] as? String, replyToMessageID: payload["reply_to_message_id"] as? String,
                               to: addresses(payload["to"]), cc: addresses(payload["cc"]), bcc: addresses(payload["bcc"]), subject: payload["subject"] as? String ?? "", bodyHTML: payload["body_html"] as? String ?? "", title: title,
                               attachments: files, skipSignature: true)
    }
}

struct ComposeAttachmentFile: Identifiable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data
    var size: Int { data.count }
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// The composer's state and behaviour, shared between the sheet and the inline reply.
@MainActor
@Observable
final class ComposerModel {
    let initial: ComposerInitial
    var accountID: String
    var to: [Address]
    var cc: [Address]
    var bcc: [Address]
    var showCc: Bool
    var showBcc: Bool
    var subject: String
    var attachments: [ComposeAttachmentFile] = []
    var includeQuote = true
    var showQuote = false
    var draftID: String?
    var busy = false
    var saveState: SaveState = .idle
    var dragging = false
    let editor = RichTextController()
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private var dirty = false
    private var autosave: Task<Void, Never>?
    private var signatureApplied = false

    enum SaveState: Equatable { case idle, saving, saved(Date), error(String) }

    init(initial: ComposerInitial) {
        self.initial = initial
        accountID = initial.accountID ?? ""
        to = initial.to; cc = initial.cc; bcc = initial.bcc
        showCc = !initial.cc.isEmpty; showBcc = !initial.bcc.isEmpty
        subject = initial.subject
        draftID = initial.draftID
        attachments = initial.attachments
        // `text-[15px] leading-[1.6]`: a 24pt line box.
        editor.fontSize = 15
        editor.lineHeight = 24
    }

    var isReply: Bool { initial.threadID != nil }

    func account(in app: AppState) -> Account? {
        app.accounts.first { $0.id == accountID } ?? app.scopedAccount ?? app.accounts.first
    }

    /// The default account can arrive after the composer opened; the signature goes in once.
    func prepare(app: AppState) {
        if accountID.isEmpty, let a = app.scopedAccount ?? app.accounts.first { accountID = a.id }
        guard !signatureApplied else { return }
        let wantsSignature = initial.draftID == nil && !initial.skipSignature
        let acct = account(in: app)
        if acct != nil || !wantsSignature { signatureApplied = true }
        // The body goes in straight away; if accounts are still loading the signature
        // follows once they arrive, unless typing has started by then.
        if bodySeeded && (dirty || !signatureApplied) { return }
        var html = initial.bodyHTML
        if wantsSignature, let sig = acct?.signature, !sig.isEmpty, !html.contains("hey-signature") {
            html += "<br><br><div class=\"hey-signature\">\(sig)</div>"
        }
        bodySeeded = true
        editor.setHTML(html)
        // Seeding is not an edit: nothing gets autosaved until the person types.
        dirty = false
        autosave?.cancel()
    }
    private var bodySeeded = false
    private var resaveNeeded = false

    func markDirty() {
        dirty = true
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, let self, self.dirty, !self.busy else { return }
            // From here the save must finish even if typing resumes; a cancelled request
            // can leave a draft on the server the client never hears about.
            self.autosave = nil
            _ = await self.saveDraft()
        }
    }

    /// Lets a save that is already on the wire finish before the payload is read.
    private func settleSave() async {
        while saveState == .saving { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func isEmpty(app: AppState) -> Bool {
        let txt = editor.plainText().trimmingCharacters(in: .whitespacesAndNewlines)
        let sig = HTMLText.plain(from: account(in: app)?.signature ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyEmpty = txt.isEmpty || txt == sig
        return bodyEmpty && subject.trimmingCharacters(in: .whitespaces).isEmpty && to.isEmpty && cc.isEmpty && bcc.isEmpty && attachments.isEmpty
    }

    func bodyHTML() -> String {
        var html = editor.html()
        if includeQuote, !initial.quotedHTML.isEmpty {
            html += "<br><br><div class=\"hey-quote\"><blockquote style=\"border-left:2px solid #d3d1cb;margin:0;padding-left:1em;color:#787774\">\(initial.quotedHTML)</blockquote></div>"
        }
        return html
    }

    private func addressList(_ a: [Address]) -> [[String: String]] { a.map { ["email": $0.email, "name": $0.name] } }

    func draftBody() -> [String: Any] {
        ["account_id": accountID, "thread_id": initial.threadID as Any, "reply_to_message_id": initial.replyToMessageID as Any,
         "to": addressList(to), "cc": addressList(cc), "bcc": addressList(bcc), "subject": subject, "body_html": bodyHTML()]
    }

    func payload(sendAt: Double? = nil) -> [String: Any] {
        var p = draftBody()
        p["draft_id"] = draftID as Any
        p["send_at"] = sendAt as Any
        p["attachments"] = attachments.map { ["filename": $0.filename, "mime_type": $0.mimeType, "data_base64": $0.data.base64EncodedString()] }
        return p
    }

    @discardableResult
    func saveDraft(quiet: Bool = true) async -> String? {
        guard let app = Mail.app, !isEmpty(app: app) else { return nil }
        // One request at a time: a save landing while another is out re-runs afterwards
        // instead of racing it (which is how duplicate drafts appear).
        if saveState == .saving { resaveNeeded = true; await settleSave(); return draftID }
        saveState = .saving
        var result: String?
        do {
            if let id = draftID {
                _ = try await APIClient.shared.updateDraft(id, body: draftBody())
            } else {
                draftID = try await APIClient.shared.createDraft(draftBody()).id
            }
            dirty = false
            saveState = .saved(Date())
            if !quiet { Toasts.shared.success("Draft saved") }
            result = draftID
        } catch {
            let msg = (error as? APIError)?.errorDescription ?? error.localizedDescription
            saveState = .error(msg)
            if !quiet { Toasts.shared.error(msg) }
        }
        if resaveNeeded { resaveNeeded = false; return await saveDraft(quiet: quiet) }
        return result
    }

    private func validate(app: AppState) -> Bool {
        if to.isEmpty && cc.isEmpty && bcc.isEmpty { Toasts.shared.error("Add at least one recipient."); return false }
        if account(in: app) == nil { Toasts.shared.error("Connect an account first."); return false }
        return true
    }

    /// `doSend`. ⌘↵ and the button both come here; neither does anything while a
    /// scheduled send is still on the wire (`!busy`).
    func send(skipSubjectCheck: Bool = false) {
        guard !busy, let app = Mail.app, validate(app: app) else { return }
        if !skipSubjectCheck, subject.trimmingCharacters(in: .whitespaces).isEmpty, !isReply {
            DialogState.shared.present("subject") {
                AlertDialogView(title: "Send without a subject?", description: "The recipient will see “(no subject)”.", cancel: "Add a subject", action: "Send",
                                onConfirm: { DialogState.shared.dismiss("subject"); self.send(skipSubjectCheck: true) },
                                onCancel: { DialogState.shared.dismiss("subject") })
            }
            return
        }
        let undo = app.user?.settings.undoSendSeconds ?? 10
        dirty = false
        autosave?.cancel()
        // The body is read now, while the editor is still on screen; a draft save still on
        // the wire only has to land before the send so it carries the draft's id.
        var p = payload()
        Task {
            await settleSave()
            p["draft_id"] = draftID as Any
            Compose.queueSend(p, undoSeconds: undo)
        }
        onDone?()
    }

    func sendLater(at: Date) async {
        guard let app = Mail.app, validate(app: app) else { return }
        busy = true
        defer { busy = false }
        await settleSave()
        do {
            _ = try await APIClient.shared.send(payload(sendAt: at.timeIntervalSince1970 * 1000))
            dirty = false
            Toasts.shared.success("Scheduled for \(ComposerModel.scheduledLabel(at))")
            Mail.invalidate()
            onDone?()
        } catch {
            Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// `toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })`:
    /// "Sep 12, 9:00 AM" — no year.
    private static let monthDay: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d"); return f }()
    static func scheduledLabel(_ d: Date) -> String { "\(monthDay.string(from: d)), \(Fmt.clock(d))" }

    func reallyDiscard() {
        dirty = false
        autosave?.cancel()
        if let id = draftID { Task { try? await APIClient.shared.deleteDraft(id); Mail.invalidate() } }
        onCancel?()
    }

    func discard() {
        guard let app = Mail.app else { return }
        if isEmpty(app: app) { reallyDiscard(); return }
        DialogState.shared.present("discard") {
            AlertDialogView(title: "Discard this message?", description: "The draft is deleted and the text is gone.", cancel: "Keep writing", action: "Discard",
                            onConfirm: { DialogState.shared.dismiss("discard"); self.reallyDiscard() },
                            onCancel: { DialogState.shared.dismiss("discard") })
        }
    }

    /// Save a draft if there is anything worth saving, then close.
    func saveAndClose() async {
        guard let app = Mail.app else { onCancel?(); return }
        if isEmpty(app: app) {
            if let id = draftID { try? await APIClient.shared.deleteDraft(id) }
        } else if dirty || draftID == nil {
            if await saveDraft() != nil { Toasts.shared.show("Saved as a draft", duration: 3); Mail.invalidate() }
        }
        onCancel?()
    }

    func addFiles(_ urls: [URL]) {
        var files: [ComposeAttachmentFile] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            files.append(ComposeAttachmentFile(filename: url.lastPathComponent, mimeType: mime, data: data))
        }
        add(files)
    }

    /// Pasted images and dropped files alike: the 20 MB cap, and the worker's ten-file limit
    /// said out loud rather than silently applied.
    func add(_ files: [ComposeAttachmentFile]) {
        let cap = 20 * 1024 * 1024
        var total = attachments.reduce(0) { $0 + $1.size }
        for f in files {
            if attachments.count >= 10 { Toasts.shared.error("Up to 10 attachments per message."); break }
            if total + f.size > cap { Toasts.shared.error("Attachments are capped at 20 MB total."); break }
            total += f.size
            attachments.append(f)
        }
        markDirty()
    }

    var statusLabel: String {
        switch saveState {
        case .saving: return "Saving…"
        case .error: return "Couldn't save draft"
        case .saved(let at):
            let secs = Int(Date().timeIntervalSince(at).rounded())
            if secs < 8 { return "Saved" }
            if secs < 60 { return "Saved \(secs)s ago" }
            return "Saved \(secs / 60)m ago"
        case .idle: return ""
        }
    }
}

// MARK: - View

struct ComposerView: View {
    @Bindable var model: ComposerModel
    var inline = false
    /// `/compose?to=…`: the recipient is known, so the caret starts in the body.
    var autoFocusBody = false

    @Environment(AppState.self) private var app
    @Environment(PopLayerState.self) private var pops
    @State private var editorHeight: CGFloat = 96
    @State private var tick = 0
    @State private var importing = false

    private var account: Account? { model.account(in: app) }
    private var multi: Bool { app.accounts.count > 1 }
    /// The sheet's new message gets the big subject; replies and the in-page composer keep 14.
    private var bigSubject: Bool { !model.isReply && !inline }
    private var minBody: CGFloat { inline ? 96 : 192 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        fromRow
                        AddressInput(label: "To", value: $model.to, autoFocus: !model.isReply && model.to.isEmpty, onChange: { model.markDirty() }) {
                            if !model.showCc { WButton("Cc", variant: .ghost, size: .xs, muted: true) { model.showCc = true } }
                            if !model.showBcc { WButton("Bcc", variant: .ghost, size: .xs, muted: true) { model.showBcc = true } }
                        }
                        .zIndex(3)
                        if model.showCc { AddressInput(label: "Cc", value: $model.cc, autoFocus: model.cc.isEmpty, onChange: { model.markDirty() }) { EmptyView() }.zIndex(2) }
                        if model.showBcc { AddressInput(label: "Bcc", value: $model.bcc, autoFocus: model.bcc.isEmpty, onChange: { model.markDirty() }) { EmptyView() }.zIndex(1) }
                        HStack(alignment: .center, spacing: 12) {
                            rowLabel("Subject")
                            TextField("", text: $model.subject, prompt: Text(model.isReply ? "" : "Subject").foregroundStyle(W.tertiary))
                                .textFieldStyle(.plain)
                                .font(bigSubject ? W.font(16, 600) : W.font(14))
                                .tracking(bigSubject ? -0.16 : 0)
                                .foregroundStyle(W.foreground)
                                .padding(.vertical, 2)
                                .onChange(of: model.subject) { _, _ in model.markDirty() }
                                // Enter moves on to the body.
                                .onSubmit { model.editor.focus() }
                        }
                        .padding(.vertical, 6)
                        .edgeLine(.bottom)
                    }
                    .padding(.top, inline ? 2 : 4)

                    VStack(alignment: .leading, spacing: 0) {
                        RichTextEditor(controller: model.editor, height: $editorHeight, placeholder: model.isReply ? "Write your reply…" : "Write something…", autoFocus: model.isReply || autoFocusBody,
                                       onEdit: { model.markDirty() },
                                       onPasteFiles: { urls, images in
                                           if !urls.isEmpty { model.addFiles(urls) }
                                           if !images.isEmpty { model.add(images) }
                                       })
                            .frame(minHeight: minBody)
                            .frame(height: max(editorHeight, minBody))

                        if !model.initial.quotedHTML.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 12) {
                                    Button { model.showQuote.toggle() } label: {
                                        HStack(spacing: 4) {
                                            Icon("chevronDown", size: 12).rotationEffect(.degrees(model.showQuote ? 180 : 0))
                                            Text("\(model.showQuote ? "Hide" : "Show") quoted text")
                                        }
                                    }
                                    .buttonStyle(.web(.ghost, .xs, muted: true))
                                    .animation(.easeOut(duration: 0.15), value: model.showQuote)
                                    HStack(spacing: 8) {
                                        SmallSwitch(on: Binding(get: { model.includeQuote }, set: { model.includeQuote = $0; model.markDirty() }))
                                        Text("Include when sending").font(W.xs).foregroundStyle(W.mutedForeground)
                                    }
                                }
                                if model.showQuote {
                                    // `mt-2 border-l-2 border-border pl-3 text-muted-foreground text-[13px] max-h-64 overflow-y-auto`
                                    ScrollView(.vertical) {
                                        HtmlBodyView(html: model.initial.quotedHTML, collapseQuotes: false, fontSize: 13, muted: true)
                                            .padding(.leading, 12)
                                    }
                                    .frame(maxHeight: 256)
                                    .overlay(alignment: .leading) { Rectangle().fill(W.border).frame(width: 2) }
                                    .padding(.top, 8)
                                }
                            }
                            .padding(.top, 12)
                        }

                        if !model.attachments.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                                ForEach(model.attachments) { a in
                                    AttachmentItemView(filename: a.filename, mimeType: a.mimeType, size: a.size, imageData: a.isImage ? a.data : nil) {
                                        model.attachments.removeAll { $0.id == a.id }
                                        model.markDirty()
                                    }
                                }
                            }
                            .padding(.top, 16)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: inline ? nil : .infinity)

            toolbar
        }
        .overlay {
            if model.dragging {
                HStack(spacing: 0) {
                    Icon("paperclip", size: 14).padding(.trailing, 8)
                    Text("Drop to attach")
                }
                .font(W.sm).foregroundStyle(W.mutedForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(W.background.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.ring, style: StrokeStyle(lineWidth: 1, dash: [4])))
                .rounded(W.radiusLg)
                .padding(4)
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { model.dragging }, set: { model.dragging = $0 })) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                model.addFiles(urls)
            }
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addFiles(urls) }
        }
        .onAppear { model.prepare(app: app) }
        .onChange(of: app.accounts.map(\.id)) { _, _ in model.prepare(app: app) }
        .task {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); tick += 1 }
        }
        // `setReply(null)`: Escape just closes an inline reply — no draft is written for it.
        .onKeys(["Escape": { model.onCancel?() }], enabled: inline, priority: 20)
    }

    private func rowLabel(_ t: String) -> some View {
        Text(t).font(W.s13).foregroundStyle(W.mutedForeground).frame(width: 56, alignment: .leading)
    }

    private var fromRow: some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel("From")
            if app.accounts.isEmpty {
                Text("No account connected").font(W.s13).foregroundStyle(W.mutedForeground)
            } else {
                Button {
                    let minWidth = PopLayerState.shared.frames["compose-from"]?.width ?? 0
                    pops.toggle("compose-from", side: .bottom, align: .start) {
                        PopCard {
                            VStack(spacing: 0) {
                                ForEach(app.accounts) { a in
                                    FromMenuRow(account: a, label: fromLabel(a), glyph: multi ? app.glyph(for: a.id) : nil, checked: a.id == model.accountID) {
                                        pops.closeAll(); model.accountID = a.id; model.markDirty()
                                    }
                                }
                            }
                            .frame(minWidth: max(0, minWidth - 8))
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if let a = account {
                            WAvatar(email: a.email, name: fromLabel(a), src: a.avatarURL, size: 16)
                            Text(fromLabel(a)).font(W.s13).foregroundStyle(W.foreground).lineLimit(1)
                            Text(a.email).font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1)
                            if multi { AccountGlyph(glyph: app.glyph(for: a.id), label: a.email) }
                        }
                        Icon("chevronDown", size: 14).foregroundStyle(W.mutedForeground)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .background(pops.isOpen("compose-from") ? W.muted : Color.clear)
                    .rounded(W.radiusMd)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popAnchor("compose-from")
                .padding(.leading, -6)
            }
        }
        .padding(.vertical, 6)
        .edgeLine(.bottom)
    }

    private func fromLabel(_ a: Account) -> String {
        a.displayName.isEmpty ? (app.user?.name.isEmpty == false ? app.user!.name : a.email) : a.displayName
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            tool("bold", "Bold  ⌘B") { model.editor.toggleBold() }
            tool("italic", "Italic  ⌘I") { model.editor.toggleItalic() }
            tool("underline", "Underline  ⌘U") { model.editor.toggleUnderline() }
            WButton(icon: "link2", variant: .ghost, size: .iconSm, muted: true, expanded: pops.isOpen("compose-link"), help: "Link") {
                pops.toggle("compose-link", side: .top, align: .start) { LinkPopover { url in pops.closeAll(); model.editor.insertLink(url); model.markDirty() } }
            }
            .popAnchor("compose-link")
            tool("list", "Bulleted list") { model.editor.bulletList() }
            tool("listOrdered", "Numbered list") { model.editor.numberedList() }
            tool("quote", "Quote") { model.editor.quote() }
            tool("removeFormatting", "Clear formatting") { model.editor.clearFormatting() }
            tool("paperclip", "Attach files") { importing = true }
            Spacer()
            if !model.statusLabel.isEmpty {
                Text(model.statusLabel).font(W.xs).monospacedDigit().foregroundStyle(W.tertiary).padding(.trailing, 4).id(tick)
            }
            WButton(icon: "trash2", variant: .ghost, size: .iconSm, muted: true, help: model.isEmpty(app: app) ? "Close" : "Discard") { model.discard() }
            ButtonGroup {
                WButton("Send", icon: "send", help: "Send (⌘↵)") { model.send() }
                    .disabled(model.busy || account == nil)
                Button {
                    pops.toggle("compose-later", side: .top, align: .end) {
                        PopCard {
                            Text("Send later").font(W.font(12, 500)).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).frame(height: 28)
                            DateTimePicker(verb: "Schedule", embedded: true) { at in pops.closeAll(); Task { await model.sendLater(at: at) } }
                        }
                    }
                } label: { Icon("chevronDown", size: 16) }
                .buttonStyle(.web(.default, .icon))
                .frame(width: 28)
                .help("Send later")
                .popAnchor("compose-later")
                .disabled(model.busy || account == nil)
            }
            .padding(.leading, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .edgeLine(.top)
        .background(W.background)
    }

    private func tool(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        WButton(icon: icon, variant: .ghost, size: .iconSm, muted: true, help: help) { action(); model.markDirty() }
    }
}

/// `SelectItem` in the From menu: py-1.5 pr-8 pl-2 gap-2 text-sm, avatar, email, the
/// provider in xs muted, the account glyph when there are several, a check at `right-2`.
private struct FromMenuRow: View {
    let account: Account
    let label: String
    var glyph: String?
    let checked: Bool
    var action: () -> Void
    @State private var hovering = false

    private var provider: String {
        switch account.provider {
        case "domain": return "Domain"
        case "outlook": return "Outlook"
        case "imap": return "IMAP"
        default: return "Gmail"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                WAvatar(email: account.email, name: label, src: account.avatarURL, size: 16)
                Text(account.email).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                Text(provider).font(W.xs).foregroundStyle(W.mutedForeground)
                if let glyph { AccountGlyph(glyph: glyph) }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 32)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { Icon("check", size: 16).opacity(checked ? 1 : 0).padding(.trailing, 8) }
            .background(hovering ? W.accent : Color.clear)
            .rounded(W.radiusSm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// shadcn `Switch size="sm"`: 24×14, thumb 12.
private struct SmallSwitch: View {
    @Binding var on: Bool
    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { on.toggle() }
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? W.primary : W.input).frame(width: 24, height: 14)
                Circle().fill(on ? W.primaryForeground : W.foreground).frame(width: 12, height: 12).padding(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LinkPopover: View {
    var onAdd: (String) -> Void
    @State private var url = ""
    var body: some View {
        PopCard(width: 288, padding: 6) {
            HStack(spacing: 6) {
                WTextField(placeholder: "https://", text: $url, height: 28, fontSize: 13, onSubmit: { if !url.isEmpty { onAdd(url) } }, autofocus: true)
                WButton("Add", icon: "check", size: .sm) { onAdd(url) }.disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// `AttachmentItem` (`Item variant="muted" size="xs"`) in the composer and in the thread:
/// a bare 16px icon or a 24px thumbnail, the name at 13/500, the size in xs; the action
/// button shows on hover. The thread's item is a link, so it also gets `hover:bg-muted`.
struct AttachmentItemView: View {
    let filename: String
    let mimeType: String
    let size: Int
    var imageData: Data? = nil
    /// An `image/*` attachment on the server, shown as its own thumbnail.
    var thumbnailURL: URL? = nil
    var onRemove: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    @State private var hovering = false
    @State private var remote: NSImage?
    @State private var broken = false

    private var thumbnail: NSImage? {
        if let imageData, let img = NSImage(data: imageData) { return img }
        return remote
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let img = thumbnail, !broken {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: 24, height: 24).clipped().rounded(W.radiusSm)
                } else {
                    Icon(fileIcon(mimeType, filename), size: 16).foregroundStyle(W.mutedForeground)
                }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(filename.isEmpty ? "attachment" : filename).font(W.font(13, 500)).webLine(13, 17.875, weight: 500).foregroundStyle(W.foreground).lineLimit(1)
                Text(Fmt.size(size)).font(W.xs).monospacedDigit().webLine(12, 18).foregroundStyle(W.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, onRemove != nil || onDownload != nil ? 32 : 0)
        }
        .overlay(alignment: .trailing) {
            if let onRemove { WButton(icon: "x", variant: .ghost, size: .iconXs, muted: true, help: "Remove attachment", action: onRemove).opacity(hovering ? 1 : 0) }
            if let onDownload { WButton(icon: "download", variant: .ghost, size: .iconXs, muted: true, help: "Download", action: onDownload).opacity(hovering ? 1 : 0) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(onOpen != nil && hovering ? W.muted : W.muted50)
        .rounded(W.radiusLg)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen?() }
        .task(id: thumbnailURL) {
            guard let thumbnailURL, mimeType.hasPrefix("image/") else { return }
            remote = await ImageCache.shared.image(for: thumbnailURL, maxPixel: 96)
            if remote == nil { broken = true }
        }
    }
}

func fileIcon(_ mime: String, _ name: String = "") -> String {
    if mime.hasPrefix("image/") { return "fileImage" }
    if mime.range(of: "zip|rar|7z|tar|gzip", options: .regularExpression) != nil || name.range(of: "\\.(zip|rar|7z|tgz)$", options: [.regularExpression, .caseInsensitive]) != nil { return "fileArchive" }
    if mime.range(of: "pdf|text|word|document|sheet|presentation|csv", options: .regularExpression) != nil { return "fileText" }
    return "file"
}

// MARK: - Address input

/// Recipient chips with contact autocomplete, one borderless row of the compose header.
struct AddressInput<Trailing: View>: View {
    let label: String
    @Binding var value: [Address]
    var autoFocus = false
    var placeholder = "Add people…"
    var onChange: () -> Void = {}
    @ViewBuilder var trailing: () -> Trailing

    @State private var text = ""
    @State private var suggestions: [Address] = []
    @State private var open = false
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var showMenu: Bool { open && !text.trimmingCharacters(in: .whitespaces).isEmpty && !suggestions.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(W.s13).foregroundStyle(W.mutedForeground).frame(width: 56, alignment: .leading).padding(.top, 4)
            FlowLayout(spacing: 4) {
                ForEach(value) { a in
                    AddressChip(address: a) { value.removeAll { $0.email == a.email }; onChange() }
                }
                TextField("", text: $text, prompt: Text(value.isEmpty ? placeholder : "").foregroundStyle(W.tertiary))
                    .textFieldStyle(.plain)
                    .font(W.font(14))
                    .foregroundStyle(W.foreground)
                    .focused($focused)
                    .frame(minWidth: 144, minHeight: 24)
                    .onSubmit { commit() }
                    .onChange(of: text) { _, v in
                        if v.hasSuffix(",") || v.hasSuffix(";") { text = String(v.dropLast()); commit(); return }
                        open = true
                        Task { await suggest(v) }
                    }
                    .onChange(of: focused) { _, f in if f { open = true } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { commitText(); open = false } } }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(suggestions.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.tab) { if !text.isEmpty { commit(); return .handled }; return .ignored }
                    .onKeyPress(.escape) { open = false; return .handled }
                    .onKeyPress(.delete) { if text.isEmpty, !value.isEmpty { value.removeLast(); onChange(); return .handled }; return .ignored }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { trailing() }.padding(.top, 2)
        }
        .padding(.vertical, 6)
        .edgeLine(.bottom)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // `absolute left-[68px] top-full mt-1 w-72`: the list hangs 4px under the row,
        // aligned with the chips.
        .overlay(alignment: .bottomLeading) {
            if showMenu {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.prefix(8).enumerated()), id: \.element.id) { i, c in
                        Button { commit(c) } label: {
                            HStack(spacing: 8) {
                                WAvatar(c, size: 20)
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(c.name.isEmpty ? c.email : c.name).font(W.s13).foregroundStyle(W.foreground).lineLimit(1)
                                    if !c.name.isEmpty { Text(c.email).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6).frame(height: 32)
                            .background(i == highlighted ? W.accent : Color.clear)
                            .rounded(W.radiusMd)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { highlighted = i } }
                    }
                }
                .padding(4)
                .frame(width: 288)
                .background(W.popover)
                .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.popoverRing, lineWidth: 1))
                .rounded(W.radiusLg)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .alignmentGuide(.bottom) { d in d[.top] - 4 }
                .padding(.leading, 68)
            }
        }
        .zIndex(showMenu ? 10 : 0)
        .onAppear { if autoFocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } } }
    }

    private func suggest(_ v: String) async {
        let q = v.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { suggestions = []; return }
        let found = await ContactSuggestions.lookup(q)
        guard text.trimmingCharacters(in: .whitespaces) == q else { return }
        suggestions = found.filter { c in !value.contains { $0.email == c.email } }
        highlighted = 0
    }

    private func commit(_ a: Address) {
        if !value.contains(where: { $0.email == a.email }) { value.append(a); onChange() }
        text = ""; suggestions = []; open = false
    }

    private func commit() {
        if open, suggestions.indices.contains(highlighted), !text.trimmingCharacters(in: .whitespaces).isEmpty { commit(suggestions[highlighted]); return }
        commitText()
    }

    private func commitText() {
        let parsed = AddressInput.parse(text)
        guard !parsed.isEmpty else { return }
        for p in parsed where !value.contains(where: { $0.email == p.email }) { value.append(p) }
        text = ""; open = false; onChange()
    }

    static func parse(_ s: String) -> [Address] {
        var out: [Address] = []
        for part in s.split(whereSeparator: { ",;\n".contains($0) }) {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if let open = p.firstIndex(of: "<"), let close = p.firstIndex(of: ">"), open < close {
                let name = String(p[p.startIndex..<open]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                out.append(Address(email: String(p[p.index(after: open)..<close]).lowercased(), name: name))
            } else if p.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil {
                out.append(Address(email: p.lowercased(), name: ""))
            }
        }
        return out
    }
}

/// A recipient chip: h-6 rounded-md bg-muted, avatar 16, the name capped at `max-w-56`,
/// and a 16pt remove button that washes on hover.
private struct AddressChip: View {
    let address: Address
    var onRemove: () -> Void
    @State private var hoverX = false

    var body: some View {
        HStack(spacing: 6) {
            WAvatar(address, size: 16)
            Text(address.name.isEmpty ? address.email : address.name).font(W.s13).foregroundStyle(W.foreground).lineLimit(1).truncationMode(.tail).frame(maxWidth: 224)
            Button(action: onRemove) {
                Icon("x", size: 11).foregroundStyle(hoverX ? W.foreground : W.mutedForeground)
                    .frame(width: 16, height: 16)
                    .background(hoverX ? W.accent : Color.clear)
                    .rounded(W.radiusSm)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverX = $0 }
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(W.muted)
        .rounded(W.radiusMd)
        .help(address.email)
    }
}

/// Wraps chips onto new lines, like `flex-wrap`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.init(width: width, height: nil))
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.init(width: bounds.width, height: nil))
            if x + size.width > bounds.width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: .init(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Rich text

/// The contenteditable's stand-in: an NSTextView with bold/italic/underline/links, real
/// lists and quotes (a paragraph carries an `NSTextList` or the quote mark, exactly as the
/// web's `<ul>/<ol>/<blockquote>` do), exported to that markup on send.
@MainActor
final class RichTextController {
    weak var textView: NSTextView?
    /// The composer writes at 15 on a 24pt line; the journal at 13 with the web's 1.7 line height.
    var fontSize: CGFloat = 14
    var lineHeightMultiple: CGFloat = 1
    /// A fixed line box (`leading-[1.6]` at 15px is 24), which beats the multiple when set.
    var lineHeight: CGFloat? = nil
    var baseFont: NSFont { Geist.nsFont(size: fontSize, weight: 400) }
    /// Fired by the editor as the selection moves: the selected range's first rectangle, in
    /// the editor's own coordinates, or nil when nothing is selected.
    var onSelection: ((CGRect?) -> Void)?

    /// Marks every run of a `<blockquote>` paragraph; the view draws the left bar from it.
    static let quoteKey = NSAttributedString.Key("hfQuote")
    /// `pl-5` on the web's lists, `border-l-2 pl-3` on its quotes.
    static let listIndent: CGFloat = 20
    static let quoteIndent: CGFloat = 14

    enum ListKind: Equatable { case bullet, number }

    func paragraphStyle(list: ListKind? = nil, quote: Bool = false) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeightMultiple
        if let lineHeight { p.minimumLineHeight = lineHeight; p.maximumLineHeight = lineHeight }
        let indent: CGFloat = quote ? Self.quoteIndent : 0
        if let list {
            p.textLists = [NSTextList(markerFormat: list == .bullet ? .disc : .decimal, options: 0)]
            p.tabStops = [NSTextTab(textAlignment: .left, location: indent + Self.listIndent)]
            p.defaultTabInterval = 28
            p.headIndent = indent + Self.listIndent
            p.firstLineHeadIndent = indent
        } else {
            p.headIndent = indent
            p.firstLineHeadIndent = indent
        }
        return p
    }
    var baseParagraph: NSParagraphStyle { paragraphStyle() }

    private var inkColor: NSColor { NSColor(W.foreground) }
    private var quoteColor: NSColor { NSColor(W.mutedForeground) }

    func setHTML(_ html: String) {
        guard let tv = textView else { pendingHTML = html; return }
        tv.textStorage?.setAttributedString(attributed(from: html))
        // Not `didChangeText()`: seeding the body is not an edit and must not autosave.
        tv.needsDisplay = true
        onContentSet?()
    }
    var pendingHTML: String?
    /// The editor re-measures its height after the content is replaced programmatically.
    var onContentSet: (() -> Void)?

    /// Puts the cursor in the editor. The view can be asked before it has a window (the
    /// editor is made, then placed, in separate passes), so the request waits for one.
    func focus(attempt: Int = 0) {
        guard let tv = textView else { return }
        guard let window = tv.window else {
            if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focus(attempt: attempt + 1) } }
            return
        }
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: Paragraph model

    private static func isBulletFormat(_ f: NSTextList.MarkerFormat) -> Bool {
        [NSTextList.MarkerFormat.disc, .circle, .square, .hyphen, .check, .box, .diamond].contains(f)
    }

    private func paragraphs(of storage: NSAttributedString, in range: NSRange) -> [NSRange] {
        let ns = storage.string as NSString
        var out: [NSRange] = []
        var pos = range.location
        let end = max(range.location + range.length, range.location)
        repeat {
            let r = ns.paragraphRange(for: NSRange(location: min(pos, ns.length), length: 0))
            if out.last != r { out.append(r) }
            if r.length == 0 { break }
            pos = r.location + r.length
        } while pos < end || (pos == end && range.length > 0 && pos < ns.length && out.last.map { $0.location + $0.length } ?? 0 < end)
        return out
    }

    private func style(at paragraph: NSRange, in storage: NSAttributedString) -> NSParagraphStyle? {
        guard paragraph.length > 0, paragraph.location < storage.length else { return textView?.typingAttributes[.paragraphStyle] as? NSParagraphStyle }
        return storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
    }

    func listKind(of paragraph: NSRange, in storage: NSAttributedString) -> ListKind? {
        guard let list = style(at: paragraph, in: storage)?.textLists.first else { return nil }
        return Self.isBulletFormat(list.markerFormat) ? .bullet : .number
    }

    func isQuote(_ paragraph: NSRange, in storage: NSAttributedString) -> Bool {
        guard paragraph.length > 0, paragraph.location < storage.length else { return textView?.typingAttributes[Self.quoteKey] != nil }
        return storage.attribute(Self.quoteKey, at: paragraph.location, effectiveRange: nil) != nil
    }

    /// "•\t" / "3.\t" at the start of a list paragraph: its length, or 0.
    func markerLength(of paragraph: NSRange, in storage: NSAttributedString) -> Int {
        guard listKind(of: paragraph, in: storage) != nil, paragraph.length > 0 else { return 0 }
        let text = (storage.string as NSString).substring(with: paragraph) as NSString
        let tab = text.range(of: "\t")
        guard tab.location != NSNotFound else { return 0 }
        // Only a short lead counts as a marker, so a tab inside real text is left alone.
        return tab.location <= 4 ? tab.location + 1 : 0
    }

    /// Rewrites one paragraph as a list item, a quote, both, or plain text, keeping its
    /// inline formatting.
    private func setParagraph(_ paragraph: NSRange, list: ListKind?, quote: Bool, number: Int = 1, in storage: NSMutableAttributedString) {
        let mlen = markerLength(of: paragraph, in: storage)
        let contentRange = NSRange(location: paragraph.location + mlen, length: paragraph.length - mlen)
        let content = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: contentRange))
        let style = paragraphStyle(list: list, quote: quote)
        let full = NSRange(location: 0, length: content.length)
        content.addAttribute(.paragraphStyle, value: style, range: full)
        if quote {
            content.addAttribute(Self.quoteKey, value: true, range: full)
            content.addAttribute(.foregroundColor, value: quoteColor, range: full)
        } else {
            content.removeAttribute(Self.quoteKey, range: full)
            content.addAttribute(.foregroundColor, value: inkColor, range: full)
        }
        if let list {
            var attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: quote ? quoteColor : inkColor, .paragraphStyle: style]
            if quote { attrs[Self.quoteKey] = true }
            content.insert(NSAttributedString(string: (list == .bullet ? "•" : "\(number).") + "\t", attributes: attrs), at: 0)
        }
        storage.replaceCharacters(in: paragraph, with: content)
    }

    /// Numbered items count from the start of their run; markers are rewritten to match.
    private func renumber(_ storage: NSMutableAttributedString) {
        let ns = storage.string as NSString
        var edits: [(NSRange, String)] = []
        var pos = 0
        var run = 0
        var previousKind: ListKind? = nil
        while pos < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: pos, length: 0))
            if r.length == 0 { break }
            pos = r.location + r.length
            let kind = listKind(of: r, in: storage)
            run = kind != nil && kind == previousKind ? run + 1 : 1
            previousKind = kind
            guard kind == .number else { continue }
            let mlen = markerLength(of: r, in: storage)
            let want = "\(run).\t"
            let have = mlen > 0 ? ns.substring(with: NSRange(location: r.location, length: mlen)) : ""
            if have != want { edits.append((NSRange(location: r.location, length: mlen), want)) }
        }
        for (range, text) in edits.reversed() {
            var attrs = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : [:]
            if attrs[.font] == nil { attrs[.font] = baseFont }
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
        }
    }

    private func itemNumber(of paragraph: NSRange, in storage: NSAttributedString) -> Int {
        guard let kind = listKind(of: paragraph, in: storage) else { return 0 }
        let ns = storage.string as NSString
        var n = 1
        var loc = paragraph.location
        while loc > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            guard listKind(of: prev, in: storage) == kind else { break }
            n += 1
            loc = prev.location
        }
        return n
    }

    private func toggleBlock(list: ListKind?, quote: Bool?) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let paras = paragraphs(of: storage, in: sel)
        let allList = list != nil && paras.allSatisfy { listKind(of: $0, in: storage) == list }
        let allQuote = quote == true && paras.allSatisfy { isQuote($0, in: storage) }
        storage.beginEditing()
        for r in paras.reversed() {
            let nextList: ListKind? = list != nil ? (allList ? nil : list) : listKind(of: r, in: storage)
            let nextQuote = quote != nil ? !allQuote : isQuote(r, in: storage)
            if r.length == 0 {
                // The empty paragraph at the very end of the text: give it a marker to type after.
                let style = paragraphStyle(list: nextList, quote: nextQuote)
                var attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: nextQuote ? quoteColor : inkColor, .paragraphStyle: style]
                if nextQuote { attrs[Self.quoteKey] = true }
                if let nextList { storage.append(NSAttributedString(string: (nextList == .bullet ? "•" : "1.") + "\t", attributes: attrs)) }
                tv.typingAttributes = attrs
            } else {
                setParagraph(r, list: nextList, quote: nextQuote, in: storage)
            }
        }
        renumber(storage)
        storage.endEditing()
        // The caret lands at the end of the last touched paragraph's text.
        if let last = paras.last {
            let ns = storage.string as NSString
            let r = ns.paragraphRange(for: NSRange(location: min(last.location, ns.length), length: 0))
            var end = r.location + r.length
            if end > r.location, ns.substring(with: NSRange(location: end - 1, length: 1)) == "\n" { end -= 1 }
            tv.setSelectedRange(NSRange(location: min(end, ns.length), length: 0))
            if r.length > 0, r.location < ns.length {
                var t = storage.attributes(at: r.location, effectiveRange: nil)
                t[.font] = t[.font] ?? baseFont
                tv.typingAttributes = t
            }
        }
        tv.didChangeText()
        tv.needsDisplay = true
    }

    /// `insertUnorderedList` / `insertOrderedList`: toggles the list on the selected paragraphs.
    func bulletList() { toggleBlock(list: .bullet, quote: nil) }
    func numberedList() { toggleBlock(list: .number, quote: nil) }
    /// `formatBlock blockquote`.
    func quote() { toggleBlock(list: nil, quote: true) }

    /// Return inside a list item: a new item with the next marker, or — on an empty item — the
    /// end of the list, as a contenteditable does it.
    func handleNewline() -> Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        let ns = storage.string as NSString
        let para = ns.paragraphRange(for: sel)
        guard let kind = listKind(of: para, in: storage), para.length > 0 else { return false }
        let mlen = markerLength(of: para, in: storage)
        var text = ns.substring(with: NSRange(location: para.location + mlen, length: para.length - mlen))
        if text.hasSuffix("\n") { text.removeLast() }
        let quote = isQuote(para, in: storage)
        if text.isEmpty {
            storage.beginEditing()
            setParagraph(para, list: nil, quote: quote, in: storage)
            renumber(storage)
            storage.endEditing()
            tv.setSelectedRange(NSRange(location: para.location, length: 0))
            var t = tv.typingAttributes
            t[.paragraphStyle] = paragraphStyle(list: nil, quote: quote)
            tv.typingAttributes = t
            tv.didChangeText()
            return true
        }
        let style = style(at: para, in: storage) ?? paragraphStyle(list: kind, quote: quote)
        var attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: quote ? quoteColor : inkColor, .paragraphStyle: style]
        if quote { attrs[Self.quoteKey] = true }
        let marker = (kind == .bullet ? "•" : "\(itemNumber(of: para, in: storage) + 1).") + "\t"
        let at = max(sel.location, para.location + mlen)
        tv.insertText(NSAttributedString(string: "\n" + marker, attributes: attrs), replacementRange: NSRange(location: at, length: sel.length))
        storage.beginEditing(); renumber(storage); storage.endEditing()
        return true
    }

    /// Backspace right after a marker takes the paragraph out of the list.
    func handleDeleteBackward() -> Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let para = (storage.string as NSString).paragraphRange(for: sel)
        let mlen = markerLength(of: para, in: storage)
        guard mlen > 0, sel.location == para.location + mlen else { return false }
        let quote = isQuote(para, in: storage)
        storage.beginEditing()
        setParagraph(para, list: nil, quote: quote, in: storage)
        renumber(storage)
        storage.endEditing()
        tv.setSelectedRange(NSRange(location: para.location, length: 0))
        var t = tv.typingAttributes
        t[.paragraphStyle] = paragraphStyle(list: nil, quote: quote)
        tv.typingAttributes = t
        tv.didChangeText()
        return true
    }

    // MARK: HTML in

    func attributed(from html: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !html.isEmpty, let data = html.data(using: .utf8),
           let parsed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            out.append(parsed)
        }
        out.beginEditing()
        // Every paragraph is a list item, a quote, or plain; the importer says which through
        // the paragraph style it produced (`NSTextList` for lists, a 40pt indent for
        // `<blockquote>`).
        let ns = out.string as NSString
        var paras: [(range: NSRange, list: ListKind?, quote: Bool)] = []
        var pos = 0
        while pos < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: pos, length: 0))
            if r.length == 0 { break }
            pos = r.location + r.length
            let p = out.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
            var kind: ListKind? = nil
            if let l = p?.textLists.first { kind = Self.isBulletFormat(l.markerFormat) ? .bullet : .number }
            let quote = kind == nil && (p?.headIndent ?? 0) >= 40 && (p?.textBlocks.isEmpty ?? true)
            paras.append((r, kind, quote))
        }
        // Normalise every run onto Geist, keeping only bold/italic/underline/link.
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttributes(in: full) { attrs, range, _ in
            var next: [NSAttributedString.Key: Any] = [:]
            var weight: CGFloat = 400
            var italic = false
            if let f = attrs[.font] as? NSFont {
                let traits = f.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { weight = 700 }
                if traits.contains(.italic) { italic = true }
            }
            // A heading (h1–h3) keeps its weight and one extra point, as the journal draws it.
            let heading = (attrs[.font] as? NSFont).map { $0.pointSize > 16 } ?? false
            var font = Geist.nsFont(size: heading ? fontSize + 1 : fontSize, weight: heading ? max(weight, 600) : weight)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            next[.font] = font
            next[.foregroundColor] = inkColor
            if let u = attrs[.underlineStyle] { next[.underlineStyle] = u }
            if let l = attrs[.link] { next[.link] = l }
            next[.paragraphStyle] = baseParagraph
            out.setAttributes(next, range: range)
        }
        for p in paras.reversed() {
            let style = paragraphStyle(list: p.list, quote: p.quote)
            out.addAttribute(.paragraphStyle, value: style, range: p.range)
            if p.quote {
                out.addAttribute(Self.quoteKey, value: true, range: p.range)
                out.addAttribute(.foregroundColor, value: quoteColor, range: p.range)
            }
            guard let kind = p.list else { continue }
            // The importer writes "\t•\t" / "\t1\t"; ours is "•\t" / "1.\t".
            let text = (out.string as NSString).substring(with: p.range) as NSString
            var lead = NSRange(location: p.range.location, length: 0)
            if text.hasPrefix("\t") {
                let second = text.range(of: "\t", options: [], range: NSRange(location: 1, length: text.length - 1))
                if second.location != NSNotFound, second.location <= 6 { lead.length = second.location + 1 }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: p.quote ? quoteColor : inkColor, .paragraphStyle: style]
            if p.quote { attrs[Self.quoteKey] = true }
            out.replaceCharacters(in: lead, with: NSAttributedString(string: (kind == .bullet ? "•" : "1.") + "\t", attributes: attrs))
        }
        renumber(out)
        out.endEditing()
        return out
    }

    func plainText() -> String { textView?.string ?? "" }

    // MARK: HTML out

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func inlineHTML(_ storage: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let ns = storage.string as NSString
        var s = ""
        storage.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            var t = Self.escape(ns.substring(with: r))
            t = t.replacingOccurrences(of: "\u{2028}", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
            if let f = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: f)
                if traits.contains(.boldFontMask) { t = "<b>\(t)</b>" }
                if traits.contains(.italicFontMask) { t = "<i>\(t)</i>" }
            }
            // A link is underlined by the importer; the markup carries that itself.
            if (attrs[.underlineStyle] as? Int ?? 0) != 0, attrs[.link] == nil { t = "<u>\(t)</u>" }
            if let link = attrs[.link] {
                let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !href.isEmpty { t = "<a href=\"\(Self.escape(href))\">\(t)</a>" }
            }
            s += t
        }
        return s
    }

    /// The body as the markup the web's contenteditable would hold: `<div>` per paragraph,
    /// `<ul>/<ol>` with `<li>` for lists, `<blockquote>` around quoted paragraphs, `<h2>` for
    /// the journal's headings, and `<b>/<i>/<u>/<a>` inline.
    func html() -> String {
        guard let storage = textView?.textStorage, storage.length > 0 else { return "" }
        let ns = storage.string as NSString
        var out = ""
        var openList: ListKind? = nil
        var inQuote = false
        func closeList() { if let o = openList { out += o == .bullet ? "</ul>" : "</ol>"; openList = nil } }
        var pos = 0
        while pos < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: pos, length: 0))
            if para.length == 0 { break }
            pos = para.location + para.length
            let kind = listKind(of: para, in: storage)
            let quote = isQuote(para, in: storage)
            if quote != inQuote {
                closeList()
                out += quote ? "<blockquote>" : "</blockquote>"
                inQuote = quote
            }
            if kind != openList { closeList(); if let k = kind { out += k == .bullet ? "<ul>" : "<ol>"; openList = k } }
            let mlen = markerLength(of: para, in: storage)
            var content = NSRange(location: para.location + mlen, length: para.length - mlen)
            if content.length > 0, ns.substring(with: NSRange(location: content.location + content.length - 1, length: 1)) == "\n" { content.length -= 1 }
            let inner = inlineHTML(storage, content)
            let heading = content.length > 0 && ((storage.attribute(.font, at: content.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0) > fontSize
            if kind != nil { out += "<li>\(inner)</li>" }
            else if heading { out += "<h2>\(inner)</h2>" }
            else { out += "<div>\(inner.isEmpty ? "<br>" : inner)</div>" }
        }
        closeList()
        if inQuote { out += "</blockquote>" }
        return out
    }

    // MARK: Inline formatting

    private func apply(_ edit: (NSMutableAttributedString, NSRange) -> Void, typing: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var t = tv.typingAttributes
            typing(&t)
            tv.typingAttributes = t
            return
        }
        storage.beginEditing()
        edit(storage, range)
        storage.endEditing()
        tv.didChangeText()
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        apply({ storage, range in
            let has = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont).map { fm.traits(of: $0).contains(trait) } ?? false
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                let f = (value as? NSFont) ?? self.baseFont
                let next = has ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
                storage.addAttribute(.font, value: next, range: r)
            }
        }, typing: { t in
            let f = (t[.font] as? NSFont) ?? self.baseFont
            let has = fm.traits(of: f).contains(trait)
            t[.font] = has ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
        })
    }

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    /// What the selection (or the typing point) carries, for a toolbar's pressed state.
    func marks() -> (bold: Bool, italic: Bool, heading: Bool) {
        guard let tv = textView else { return (false, false, false) }
        let range = tv.selectedRange()
        let font: NSFont?
        if range.length > 0, let s = tv.textStorage, range.location < s.length { font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont }
        else { font = tv.typingAttributes[.font] as? NSFont }
        guard let font else { return (false, false, false) }
        let traits = NSFontManager.shared.traits(of: font)
        return (traits.contains(.boldFontMask), traits.contains(.italicFontMask), font.pointSize > fontSize)
    }

    /// `formatBlock h2`: the paragraph under the selection becomes a heading, or stops being one.
    func toggleHeading() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
        let on = marks().heading
        let font = Geist.nsFont(size: on ? fontSize : fontSize + 1, weight: on ? 400 : 600)
        if range.length > 0 { storage.addAttribute(.font, value: font, range: range); tv.didChangeText() }
        tv.typingAttributes[.font] = font
    }
    func toggleUnderline() {
        apply({ storage, range in
            let has = (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
            if has { storage.removeAttribute(.underlineStyle, range: range) } else { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }, typing: { t in
            let has = (t[.underlineStyle] as? Int ?? 0) != 0
            if has { t[.underlineStyle] = nil } else { t[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        })
    }

    func insertLink(_ raw: String) {
        var url = raw.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        if url.range(of: "^[a-z]+:", options: [.regularExpression, .caseInsensitive]) == nil { url = "https://" + url }
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.font] = attrs[.font] ?? baseFont
            attrs[.foregroundColor] = attrs[.foregroundColor] ?? inkColor
            attrs[.link] = url
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            tv.insertText(NSAttributedString(string: url, attributes: attrs), replacementRange: range)
        } else {
            storage.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            tv.didChangeText()
        }
    }

    /// `removeFormat`: inline formatting goes; the paragraph (list, quote) stays.
    func clearFormatting() {
        apply({ storage, range in
            storage.enumerateAttributes(in: range) { attrs, r, _ in
                var next: [NSAttributedString.Key: Any] = [.font: self.baseFont, .foregroundColor: attrs[Self.quoteKey] != nil ? self.quoteColor : self.inkColor]
                if let p = attrs[.paragraphStyle] { next[.paragraphStyle] = p }
                if let q = attrs[Self.quoteKey] { next[Self.quoteKey] = q }
                storage.setAttributes(next, range: r)
            }
        }, typing: { t in
            var next: [NSAttributedString.Key: Any] = [.font: self.baseFont, .foregroundColor: t[Self.quoteKey] != nil ? self.quoteColor : self.inkColor]
            if let p = t[.paragraphStyle] { next[.paragraphStyle] = p }
            if let q = t[Self.quoteKey] { next[Self.quoteKey] = q }
            t = next
        })
    }
}

struct RichTextEditor: NSViewRepresentable {
    let controller: RichTextController
    @Binding var height: CGFloat
    var placeholder = ""
    var autoFocus = false
    var onEdit: () -> Void
    /// `onPaste` with `clipboardData.files`: files and images on the clipboard become attachments.
    var onPasteFiles: (([URL], [ComposeAttachmentFile]) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = PlaceholderTextView()
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.font = controller.baseFont
        tv.textColor = NSColor(W.foreground)
        tv.insertionPointColor = NSColor(W.foreground)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.placeholder = placeholder
        tv.typingAttributes = [.font: controller.baseFont, .foregroundColor: NSColor(W.foreground), .paragraphStyle: controller.baseParagraph]
        tv.defaultParagraphStyle = controller.baseParagraph
        let controller = self.controller
        tv.onFormat = { [weak controller] which in
            switch which {
            case "bold": controller?.toggleBold()
            case "italic": controller?.toggleItalic()
            default: controller?.toggleUnderline()
            }
        }
        tv.onNewline = { [weak controller] in controller?.handleNewline() ?? false }
        tv.onDeleteBackward = { [weak controller] in controller?.handleDeleteBackward() ?? false }
        tv.onPasteFiles = onPasteFiles
        scroll.documentView = tv
        controller.textView = tv
        let coordinator = context.coordinator
        controller.onContentSet = { [weak tv] in
            guard let tv else { return }
            DispatchQueue.main.async { coordinator.measure(tv) }
        }
        if let pending = controller.pendingHTML { controller.pendingHTML = nil; controller.setHTML(pending) }
        DispatchQueue.main.async {
            coordinator.measure(tv)
            // Replies land in the body, as on the web; a new message starts in "To".
            if autoFocus { controller.focus() }
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = view.documentView as? PlaceholderTextView {
            tv.placeholder = placeholder
            tv.onPasteFiles = onPasteFiles
            context.coordinator.measure(tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onEdit()
            measure(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, let cb = parent.controller.onSelection else { return }
            let range = tv.selectedRange()
            guard range.length > 0, let lm = tv.layoutManager, let tc = tv.textContainer else { cb(nil); return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            rect.origin.x += tv.textContainerInset.width; rect.origin.y += tv.textContainerInset.height
            cb(rect)
        }

        func measure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height) + 8
            if abs(h - parent.height) > 1 { DispatchQueue.main.async { self.parent.height = h } }
        }
    }
}

/// An NSTextView that draws a placeholder while empty, the quote bar beside quoted
/// paragraphs, and answers ⌘B/⌘I/⌘U, Return and Backspace inside lists, and file pastes.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    var onFormat: ((String) -> Void)?
    var onNewline: (() -> Bool)?
    var onDeleteBackward: (() -> Bool)?
    var onPasteFiles: (([URL], [ComposeAttachmentFile]) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            // `empty:before:text-tertiary`.
            let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(W.tertiary)]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
        }
        // `[&_blockquote]:border-l-2 [&_blockquote]:border-border`.
        guard let storage = textStorage, storage.length > 0, let lm = layoutManager, let tc = textContainer else { return }
        storage.enumerateAttribute(RichTextController.quoteKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            NSColor(W.border).setFill()
            NSRect(x: textContainerInset.width, y: rect.minY + textContainerInset.height, width: 2, height: rect.height).fill()
        }
    }

    override func didChangeText() { super.didChangeText(); needsDisplay = true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "b": onFormat?("bold"); return true
            case "i": onFormat?("italic"); return true
            case "u": onFormat?("underline"); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if onNewline?() == true { return }
        super.insertNewline(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if onDeleteBackward?() == true { return }
        super.deleteBackward(sender)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let onPasteFiles {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                onPasteFiles(urls, [])
                return
            }
            let types = pb.types ?? []
            if types.contains(.png) || types.contains(.tiff) {
                let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff)
                if let raw, let rep = NSBitmapImageRep(data: raw), let png = rep.representation(using: .png, properties: [:]) {
                    onPasteFiles([], [ComposeAttachmentFile(filename: "image.png", mimeType: "image/png", data: png)])
                    return
                }
            }
        }
        super.paste(sender)
    }
}

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

    static func queueSend(_ payload: [String: Any], undoSeconds: Int) {
        // A second send inside the undo window fires the first one now; nothing is dropped.
        if let p = pending {
            p.task.cancel(); Toasts.shared.dismiss(p.toast); pending = nil
            Task { await fire(p.payload) }
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

    func send(skipSubjectCheck: Bool = false) {
        guard let app = Mail.app, validate(app: app) else { return }
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
            Toasts.shared.success("Scheduled for \(Fmt.full(at.timeIntervalSince1970 * 1000))")
            Mail.invalidate()
            onDone?()
        } catch {
            Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

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

    /// `setReply(null)`: an inline reply that was never typed into just goes away — the
    /// prefilled recipient and quote are not a draft worth keeping. Typed text is saved.
    func closeInline() async {
        guard let app = Mail.app else { onCancel?(); return }
        if dirty, !isEmpty(app: app) {
            if await saveDraft() != nil { Toasts.shared.show("Saved as a draft", duration: 3); Mail.invalidate() }
        } else if let id = draftID, isEmpty(app: app) {
            try? await APIClient.shared.deleteDraft(id)
        }
        onCancel?()
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
        let cap = 20 * 1024 * 1024
        var total = attachments.reduce(0) { $0 + $1.size }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            // The worker keeps the first ten silently; say so here instead.
            if attachments.count >= 10 { Toasts.shared.error("Up to 10 attachments per message."); break }
            if total + data.count > cap { Toasts.shared.error("Attachments are capped at 20 MB total."); break }
            total += data.count
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(ComposeAttachmentFile(filename: url.lastPathComponent, mimeType: mime, data: data))
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

    @Environment(AppState.self) private var app
    @Environment(PopLayerState.self) private var pops
    @State private var editorHeight: CGFloat = 120
    @State private var tick = 0
    @State private var importing = false

    private var account: Account? { model.account(in: app) }
    private var multi: Bool { app.accounts.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    fromRow
                    AddressInput(label: "To", value: $model.to, autoFocus: !model.isReply, onChange: { model.markDirty() }) {
                        if !model.showCc { WButton("Cc", variant: .ghost, size: .xs, muted: true) { model.showCc = true } }
                        if !model.showBcc { WButton("Bcc", variant: .ghost, size: .xs, muted: true) { model.showBcc = true } }
                    }
                    if model.showCc { AddressInput(label: "Cc", value: $model.cc, onChange: { model.markDirty() }) { EmptyView() } }
                    if model.showBcc { AddressInput(label: "Bcc", value: $model.bcc, onChange: { model.markDirty() }) { EmptyView() } }
                    HStack(alignment: .center, spacing: 12) {
                        rowLabel("Subject")
                        TextField("Subject", text: $model.subject)
                            .textFieldStyle(.plain)
                            .font(W.font(14))
                            .foregroundStyle(W.foreground)
                            .onChange(of: model.subject) { _, _ in model.markDirty() }
                    }
                    .padding(.vertical, 6)
                    .edgeLine(.bottom)

                    RichTextEditor(controller: model.editor, height: $editorHeight, placeholder: "Write something…", autoFocus: model.isReply, onEdit: { model.markDirty() })
                        .frame(minHeight: inline ? 120 : 200)
                        .frame(height: max(editorHeight, inline ? 120 : 200))
                        .padding(.top, 12)

                    if !model.initial.quotedHTML.isEmpty {
                        HStack(spacing: 8) {
                            WButton(model.showQuote ? "Hide quoted text" : "Show quoted text", icon: "chevronDown", variant: .ghost, size: .xs, muted: true) { model.showQuote.toggle() }
                            Spacer()
                            HStack(spacing: 8) {
                                Text("Include when sending").font(W.xs).foregroundStyle(W.mutedForeground)
                                WSwitch(on: $model.includeQuote)
                            }
                        }
                        .padding(.top, 8)
                        if model.showQuote {
                            HtmlBodyView(html: model.initial.quotedHTML, collapseQuotes: false)
                                .padding(.leading, 12)
                                .overlay(alignment: .leading) { Rectangle().fill(W.border).frame(width: 2) }
                                .padding(.top, 8)
                                .opacity(model.includeQuote ? 1 : 0.5)
                        }
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
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, inline ? 2 : 4)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: inline ? nil : .infinity)

            toolbar
        }
        .overlay {
            if model.dragging {
                Text("Drop to attach").font(W.sm).foregroundStyle(W.mutedForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(W.background.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.ring, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .padding(4)
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
        .onKeys(["Escape": { Task { await model.closeInline() } }], enabled: inline, priority: 20)
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
                    pops.toggle("compose-from", side: .bottom, align: .start) {
                        PopCard(width: 320) {
                            ForEach(app.accounts) { a in
                                MenuItem("\(fromLabel(a))  \(a.email)", checked: a.id == model.accountID) { model.accountID = a.id; model.markDirty() }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if let a = account {
                            WAvatar(email: a.email, name: fromLabel(a), src: a.avatarURL, size: 16)
                            Text(fromLabel(a)).font(W.s13).foregroundStyle(W.foreground).lineLimit(1)
                            Text(a.email).font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1)
                            if multi { AccountGlyph(glyph: app.glyph(for: a.id)) }
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

/// `AttachmentItem` in the composer and in the thread: icon or thumbnail, name, size.
struct AttachmentItemView: View {
    let filename: String
    let mimeType: String
    let size: Int
    var imageData: Data? = nil
    var onRemove: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let imageData, let img = NSImage(data: imageData) {
                Image(nsImage: img).resizable().scaledToFill().frame(width: 32, height: 32).rounded(2)
            } else {
                Icon(fileIcon(mimeType, filename), size: 16).foregroundStyle(W.mutedForeground).frame(width: 32, height: 32).background(W.muted).rounded(W.radiusMd)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(filename.isEmpty ? "attachment" : filename).font(W.font(13, 500)).foregroundStyle(W.foreground).lineLimit(1)
                Text(Fmt.size(size)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
            }
            Spacer(minLength: 0)
            if let onRemove { WButton(icon: "x", variant: .ghost, size: .iconXs, muted: true, help: "Remove attachment", action: onRemove).opacity(hovering ? 1 : 0) }
            if let onDownload { WButton(icon: "download", variant: .ghost, size: .iconXs, muted: true, help: "Download", action: onDownload).opacity(hovering ? 1 : 0) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(W.muted50)
        .rounded(W.radiusLg)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen?() }
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(W.s13).foregroundStyle(W.mutedForeground).frame(width: 56, alignment: .leading).padding(.top, 4)
            ZStack(alignment: .topLeading) {
                FlowLayout(spacing: 4) {
                    ForEach(value) { a in
                        HStack(spacing: 6) {
                            WAvatar(a, size: 16)
                            Text(a.name.isEmpty ? a.email : a.name).font(W.s13).foregroundStyle(W.foreground).lineLimit(1)
                            Button { value.removeAll { $0.email == a.email }; onChange() } label: {
                                Icon("x", size: 11).foregroundStyle(W.mutedForeground).frame(width: 16, height: 16).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 4)
                        .frame(height: 24)
                        .background(W.muted)
                        .rounded(W.radiusMd)
                        .help(a.email)
                    }
                    TextField(value.isEmpty ? placeholder : "", text: $text)
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
                        .onChange(of: focused) { _, f in if !f { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { commitText(); open = false } } }
                        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(suggestions.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                        .onKeyPress(.tab) { if !text.isEmpty { commit(); return .handled }; return .ignored }
                        .onKeyPress(.escape) { open = false; return .handled }
                        .onKeyPress(.delete) { if text.isEmpty, !value.isEmpty { value.removeLast(); onChange(); return .handled }; return .ignored }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if open && !text.trimmingCharacters(in: .whitespaces).isEmpty && !suggestions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.prefix(8).enumerated()), id: \.element.id) { i, c in
                            Button { commit(c) } label: {
                                HStack(spacing: 8) {
                                    WAvatar(c, size: 20)
                                    Text(c.name.isEmpty ? c.email : c.name).font(W.s13).foregroundStyle(W.foreground).lineLimit(1)
                                    if !c.name.isEmpty { Text(c.email).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1) }
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
                    .offset(y: 32)
                    .zIndex(10)
                }
            }
            HStack(spacing: 8) { trailing() }.padding(.top, 2)
        }
        .padding(.vertical, 6)
        .edgeLine(.bottom)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
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

/// The contenteditable's stand-in: an NSTextView with bold/italic/underline/links/lists,
/// exported to HTML on send.
@MainActor
final class RichTextController {
    weak var textView: NSTextView?
    var baseFont: NSFont { Geist.nsFont(size: 14, weight: 400) }

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

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func attributed(from html: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !html.isEmpty, let data = html.data(using: .utf8),
           let parsed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            out.append(parsed)
        }
        // Normalise every run onto Geist, keeping only bold/italic.
        out.beginEditing()
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
            var font = Geist.nsFont(size: 14, weight: weight)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            next[.font] = font
            next[.foregroundColor] = NSColor(W.foreground)
            if let u = attrs[.underlineStyle] { next[.underlineStyle] = u }
            if let l = attrs[.link] { next[.link] = l }
            if let p = attrs[.paragraphStyle] as? NSParagraphStyle { next[.paragraphStyle] = p }
            out.setAttributes(next, range: range)
        }
        out.endEditing()
        return out
    }

    func plainText() -> String { textView?.string ?? "" }

    func html() -> String {
        guard let storage = textView?.textStorage, storage.length > 0 else { return "" }
        let attrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .excludedElements: ["XML", "DOCTYPE", "html", "head", "meta", "title", "style", "span", "font", "body", "p"],
        ]
        guard let data = try? storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: attrs), var s = String(data: data, encoding: .utf8) else { return HTMLText.htmlBody(from: plainText()) }
        s = s.replacingOccurrences(of: "\n", with: "")
        return s
    }

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
            let s = NSAttributedString(string: url, attributes: [.font: baseFont, .foregroundColor: NSColor(W.foreground), .link: url, .underlineStyle: NSUnderlineStyle.single.rawValue])
            tv.insertText(s, replacementRange: range)
        } else {
            storage.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            tv.didChangeText()
        }
    }

    private func prefixParagraphs(_ prefix: (Int) -> String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let paragraphRange = (storage.string as NSString).paragraphRange(for: sel)
        let text = (storage.string as NSString).substring(with: paragraphRange)
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1 && line.isEmpty { out.append(line); continue }
            out.append(prefix(i) + line)
        }
        let replacement = NSAttributedString(string: out.joined(separator: "\n"), attributes: [.font: baseFont, .foregroundColor: NSColor(W.foreground)])
        tv.insertText(replacement, replacementRange: paragraphRange)
    }

    func bulletList() { prefixParagraphs { _ in "• " } }
    func numberedList() { prefixParagraphs { "\($0 + 1). " } }

    func quote() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
        let style = NSMutableParagraphStyle()
        style.headIndent = 16; style.firstLineHeadIndent = 16
        storage.addAttributes([.paragraphStyle: style, .foregroundColor: NSColor(W.mutedForeground)], range: range)
        tv.didChangeText()
    }

    func clearFormatting() {
        apply({ storage, range in
            storage.setAttributes([.font: self.baseFont, .foregroundColor: NSColor(W.foreground)], range: range)
        }, typing: { t in
            t = [.font: self.baseFont, .foregroundColor: NSColor(W.foreground)]
        })
    }
}

struct RichTextEditor: NSViewRepresentable {
    let controller: RichTextController
    @Binding var height: CGFloat
    var placeholder = ""
    var autoFocus = false
    var onEdit: () -> Void

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
        tv.typingAttributes = [.font: controller.baseFont, .foregroundColor: NSColor(W.foreground)]
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
        if let tv = view.documentView as? NSTextView { context.coordinator.measure(tv) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onEdit()
            measure(tv)
        }

        func measure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height) + 8
            if abs(h - parent.height) > 1 { DispatchQueue.main.async { self.parent.height = h } }
        }
    }
}

/// An NSTextView that draws a placeholder while empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(W.mutedForeground)]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
        }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
}

import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// One file waiting to go out.
///
/// The bytes are held in memory rather than as a file URL. `POST /api/send` takes the
/// content inline as base64, so the bytes have to be resident at send time anyway, and a
/// URL would go stale the moment the picker's security-scoped access is released.
struct ComposeAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    var filename: String
    var mimeType: String
    var data: Data

    init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    var size: Int { data.count }
    var isImage: Bool { mimeType.hasPrefix("image/") }

    /// One element of the send endpoint's `attachments` array.
    var payload: [String: String] {
        ["filename": filename, "mime_type": mimeType, "data_base64": data.base64EncodedString()]
    }

    /// A paperclip says "file" and nothing else; these say what kind, the way the web
    /// client's `fileIcon` does.
    var icon: String {
        if isImage { return "photo" }
        if mimeType.contains("pdf") { return "doc.richtext" }
        if mimeType.hasPrefix("text/") || mimeType.contains("word") || mimeType.contains("document") { return "doc.text" }
        if mimeType.contains("zip") || mimeType.contains("compressed") || mimeType.contains("tar") { return "doc.zipper" }
        return "doc"
    }
}

/// The two caps, and the sentences said when one is hit.
///
/// Both are enforced here, before the file is added, rather than left to the worker. The
/// worker quietly keeps the first ten attachments and drops the rest, and a 20 MB body is
/// a long upload to fail at the end of — so the honest place to refuse is at the moment
/// of the tap, while the person can still choose a different file.
enum AttachmentLimits {
    /// 20 MB across all files, matching the web client (`Composer.tsx:340-352`).
    static let totalBytes = 20 * 1024 * 1024
    /// `POST /api/send` takes the first ten and silently discards the rest (API.md §errors).
    static let count = 10

    /// Why this file cannot join the ones already attached, or nil when it can.
    static func refusal(adding size: Int, to current: [ComposeAttachment]) -> String? {
        if current.count >= count {
            return "Ten files is the limit for one message."
        }
        let used = current.reduce(0) { $0 + $1.size }
        if used + size > totalBytes {
            return "Attachments are capped at \(describe(totalBytes)) in total."
        }
        return nil
    }

    static func describe(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func total(_ attachments: [ComposeAttachment]) -> Int {
        attachments.reduce(0) { $0 + $1.size }
    }
}

/// The draft on screen, and the things only it can answer: whether there is anything worth
/// keeping, what the send endpoint should be handed, and what a draft save should carry.
///
/// A separate object rather than a pile of `@State` because the send payload is built from
/// eight fields at once — keeping them together means the payload is derived, never
/// assembled by hand at each of the call sites (send now, send after the undo window, send
/// later, autosave, save on close).
@MainActor
@Observable
final class ComposeStore {
    var accountID: String = ""
    var to: [Address] = []
    var cc: [Address] = []
    var bcc: [Address] = []
    var subject: String = ""
    var body: String = ""
    var attachments: [ComposeAttachment] = []
    /// The history quoted under a reply. Read-only in the composer: it is shown so the person
    /// can see what is being sent, not so they can edit someone else's words.
    var quoted: String = ""

    var showsCarbon = false
    var quoteExpanded = false
    var sending = false
    /// A failed send stays on screen next to the draft that caused it.
    var failure: String?

    /// Set the moment the draft's fate is decided — sent, scheduled, discarded, or saved on
    /// the way out. Leaving the screen after that must not save it a second time.
    var resolved = false

    /// The stored draft this composer is editing. Not private: the autosave gives one to a
    /// composer that started without one, and the send payload quotes it back so the worker
    /// consumes the row rather than leaving a copy of a message that already went out.
    private(set) var draftID: String?

    private var threadID: String?
    private var replyToMessageID: String?
    /// A schedule inherited from a stored draft, kept so reopening one does not drop it.
    private(set) var inheritedSchedule: Date?
    private var prepared = false

    // Autosave state. `savedSnapshot` is what the server is believed to hold; an edit that
    // brings the draft back to it — typing a word and deleting it — is not a reason to save.
    private var autosaveTask: Task<Void, Never>?
    private var savedSnapshot: DraftSnapshot?

    /// The web client's debounce (`Composer.tsx:253-260`). Long enough that a sentence is
    /// one request rather than thirty, short enough that putting the phone down mid-thought
    /// still leaves the thought on the server.
    private static let autosaveDelay: Duration = .milliseconds(1800)

    /// What separates the typed message from the signature under it.
    private static let signatureGap = "\n\n"

    /// The signature block this composer put at the foot of the body, exactly as it was
    /// written there. Knowing the text is what makes swapping accounts safe: the old block
    /// can be found and replaced instead of a second one being appended.
    private(set) var appliedSignature = ""
    /// Set once the block goes missing, which can only mean the person edited or deleted it.
    /// From then on the composer stops managing signatures: the body is theirs.
    private var signatureDisowned = false

    /// Copies the intent in once. `.task` can run again after a backgrounding, and re-priming
    /// would wipe whatever had been typed by then.
    func prepare(_ intent: ComposeIntent, fallbackAccountID: String?) {
        guard !prepared else { return }
        prepared = true
        accountID = intent.accountID ?? fallbackAccountID ?? ""
        to = intent.to
        cc = intent.cc
        bcc = ComposeCarryOver.take()
        subject = intent.subject
        body = intent.body
        quoted = intent.quoted
        attachments = ComposeCarryOver.takeAttachments()
        threadID = intent.threadID
        replyToMessageID = intent.replyToMessageID
        draftID = intent.draftID
        inheritedSchedule = intent.scheduledAt
        showsCarbon = !cc.isEmpty || !bcc.isEmpty
        // What arrived is not an edit, so it is not something to save back.
        savedSnapshot = snapshot
    }

    var hasRecipients: Bool { !to.isEmpty || !cc.isEmpty || !bcc.isEmpty }
    var canSend: Bool { hasRecipients && !sending }

    /// The body without the signature this composer appended — what the person actually
    /// typed. An untouched composer holds a signature and nothing else, and that is empty.
    var typedBody: String {
        let block = Self.signatureGap + appliedSignature
        guard !appliedSignature.isEmpty, body.hasSuffix(block) else { return body }
        return String(body.dropLast(block.count))
    }

    /// Whether there is anything worth keeping. The quote does not count: it was never
    /// typed by the person sitting here, and neither did the signature.
    var hasContent: Bool {
        hasRecipients
            || !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !typedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    /// The reply and the history it answers, as one plain-text document. `HTMLText.htmlBody`
    /// escapes and wraps it, so the quote travels as text rather than as re-injected markup.
    /// The signature rides inside `body`, which puts it under the reply and above the quote.
    var composedText: String {
        guard !quoted.isEmpty else { return body }
        return body + "\n\n" + quoted
    }

    /// The `POST /api/send` body. `send_at` is only present for a scheduled send; the worker
    /// stores anything in the future as a scheduled draft and its cron does the sending.
    func payload(sendAt: Date? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "account_id": accountID,
            "draft_id": Self.orNull(draftID),
            "thread_id": Self.orNull(threadID),
            "reply_to_message_id": Self.orNull(replyToMessageID),
            "to": Self.encode(to),
            "cc": Self.encode(cc),
            "bcc": Self.encode(bcc),
            "subject": subject,
            "body_html": HTMLText.htmlBody(from: composedText),
        ]
        // An explicit choice wins; otherwise a reopened scheduled draft keeps its slot.
        if let when = sendAt ?? inheritedSchedule, when > Date() {
            out["send_at"] = when.timeIntervalSince1970 * 1000
        }
        // Omitted rather than sent empty: the key exists for the files, and a scheduled
        // send is refused outright by the worker if it carries one.
        if !attachments.isEmpty {
            out["attachments"] = attachments.map(\.payload)
        }
        return out
    }

    /// The `POST /api/drafts` / `PATCH /api/drafts/:id` body. A subset of the send payload:
    /// the drafts table has no column for attachments or for a schedule set by hand.
    func draftPayload() -> [String: Any] {
        PendingSendCenter.draftBody(from: payload())
    }

    /// The draft as an intent, so an undone send can reopen the composer exactly as it was.
    func restored(from intent: ComposeIntent) -> ComposeIntent {
        var next = intent          // keeps `kind`, so a reply stays attached to its thread
        next.accountID = accountID
        next.to = to
        next.cc = cc
        next.subject = subject
        next.body = body
        next.quoted = quoted
        next.draftID = draftID
        next.scheduledAt = inheritedSchedule
        return next
    }

    /// Hands the Bcc list and the attachments to the carry-over slot. Deliberately separate
    /// from `restored`: building the undo snapshot must have no side effects, because it
    /// happens on every send, while the slot may only be filled when a send is actually
    /// being undone. Filling it eagerly left the last Bcc recipient sitting in the next
    /// blank composer.
    var bccForCarryOver: [Address] { bcc }
    var attachmentsForCarryOver: [ComposeAttachment] { attachments }

    // MARK: Signature

    /// Drops the account's signature under the body the first time the composer settles.
    ///
    /// Web does this at mount (`Composer.tsx:160-174`) for everything except a reopened
    /// draft, whose body already carries whatever was saved. A reopened draft that ends with
    /// the current signature is *adopted* rather than left unmanaged, so changing the From
    /// account afterwards still swaps it rather than stacking a second one underneath.
    func primeSignature(_ signature: String, existingDraft: Bool) {
        guard prepared, !signatureDisowned, appliedSignature.isEmpty else { return }
        let text = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if body.hasSuffix(text) {
            appliedSignature = text
        } else if !existingDraft {
            body += Self.signatureGap + text
            appliedSignature = text
        } else {
            return
        }
        // The signature arriving is not typing, so autosave must not read it as a first edit.
        savedSnapshot = snapshot
    }

    /// The From account changed, so the signature under the message has to change with it.
    ///
    /// The old block is found by its exact text and replaced. If it is not there any more the
    /// person has edited or deleted it, and the composer backs off permanently rather than
    /// appending a second signature or cutting into a sentence.
    func changeSignature(to signature: String) {
        guard prepared, !signatureDisowned else { return }
        let text = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != appliedSignature else { return }

        if !appliedSignature.isEmpty {
            let block = Self.signatureGap + appliedSignature
            guard body.hasSuffix(block) else {
                signatureDisowned = true
                appliedSignature = ""
                return
            }
            body.removeLast(block.count)
        }
        if !text.isEmpty { body += Self.signatureGap + text }
        appliedSignature = text
    }

    // MARK: Autosave

    /// Everything a draft save would carry, compared as a value so an edit that changes
    /// nothing does not cost a request. Attachments are absent on purpose: the drafts
    /// endpoint cannot store them, so adding one is not something a save could record.
    struct DraftSnapshot: Equatable {
        var accountID: String
        var to: [String]
        var cc: [String]
        var bcc: [String]
        var subject: String
        var body: String
    }

    var snapshot: DraftSnapshot {
        DraftSnapshot(
            accountID: accountID,
            to: to.map(\.email),
            cc: cc.map(\.email),
            bcc: bcc.map(\.email),
            subject: subject,
            body: body
        )
    }

    /// Called on every change to the draft. Restarts the debounce, so a burst of typing is
    /// one save at the end of it rather than one per keystroke.
    func noteEdit() {
        autosaveTask?.cancel()
        guard prepared, !resolved, hasContent, snapshot != savedSnapshot else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            _ = await self?.saveDraft()
        }
    }

    /// Stops a save that has not fired yet. Called the moment the message is actually sent:
    /// the draft is about to be consumed by the send, and writing it again afterwards would
    /// recreate the row the worker just deleted.
    func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// Writes the draft to the server, creating it the first time and patching it after.
    /// Returns false when there was nothing to save or the request failed.
    @discardableResult
    func saveDraft() async -> Bool {
        guard hasContent, !sending else { return false }
        let pending = snapshot
        let fields = draftPayload()

        do {
            let draft: Draft
            if let id = draftID {
                do {
                    draft = try await APIClient.shared.updateDraft(id, body: fields)
                } catch let error as APIError where Self.isMissingDraft(error) {
                    // Deleted from the Drafts screen, or on another device, while this
                    // composer was open. The words are still here, so they get a new row.
                    draftID = nil
                    draft = try await APIClient.shared.createDraft(fields)
                }
            } else {
                draft = try await APIClient.shared.createDraft(fields)
            }
            draftID = draft.id
            savedSnapshot = pending
            return true
        } catch {
            return false
        }
    }

    /// Throws the stored row away, for the two paths that mean "there is nothing to keep":
    /// an explicit discard, and closing a composer that was left empty.
    func discardStoredDraft() {
        cancelAutosave()
        guard let id = draftID else { return }
        draftID = nil
        // Detached from any view: the sheet is already on its way out.
        Task { try? await APIClient.shared.deleteDraft(id) }
    }

    /// A draft that is no longer there. Spelled as a `where` clause rather than a literal
    /// pattern because `APIError.server` carries the worker's code beside an HTTP status,
    /// and only the code says which of the 404s this is.
    private static func isMissingDraft(_ error: APIError) -> Bool {
        if case .server(let code, _) = error { return code == "not_found" }
        return false
    }

    private static func encode(_ addresses: [Address]) -> [[String: String]] {
        addresses.map { ["email": $0.email, "name": $0.name] }
    }

    /// `JSONSerialization` will not encode a Swift `nil`, and the worker wants an explicit
    /// null for "this is not a reply".
    private static func orNull(_ value: String?) -> Any { value ?? NSNull() }
}

/// `ComposeIntent` is a fixed contract with no Bcc or attachment fields, and it is not this
/// feature's to change. These slots carry both across the only moment a composer is rebuilt
/// from a draft that already left the screen — an undone send — and are emptied as soon as
/// they are read.
@MainActor
enum ComposeCarryOver {
    static var bcc: [Address] = []
    static var attachments: [ComposeAttachment] = []

    static func take() -> [Address] {
        defer { bcc = [] }
        return bcc
    }

    static func takeAttachments() -> [ComposeAttachment] {
        defer { attachments = [] }
        return attachments
    }
}

/// Holds a sent message back for the number of seconds the owner asked for.
///
/// This lives outside the view on purpose. The composer dismisses the instant Send is
/// tapped — that is the whole point of undo send, the screen gets out of the way — so the
/// waiting task cannot belong to a view that no longer exists. A single shared queue also
/// gives Undo something to cancel: cancelling the task is the cancellation, since the
/// request is only built after the sleep returns normally.
///
/// The payload itself is not held here. `PendingSendCenter` has it, on disk, from before
/// the timer started — so what this class owns is the timer and the toast, both of which
/// are allowed to die with the process.
@MainActor
final class SendQueue {
    static let shared = SendQueue()

    /// One held message. A reference type so the undo closure can look at the live
    /// `committed` flag rather than a copy of it taken when the toast was armed.
    private final class Slot {
        let id: UUID
        var task: Task<Void, Never>?
        /// Set the moment the send is past the point of no return.
        var committed = false

        init(id: UUID) { self.id = id }
    }

    private var slots: [UUID: Slot] = [:]

    /// Starts the undo window for a send that was just armed.
    ///
    /// `restore` puts the draft back on screen if the person changes their mind first. It is
    /// handed the record rebuilt as an intent, which the composer uses only for the draft id
    /// the server mirror may have assigned after the sheet closed.
    func queue(_ record: PendingSend, toasts: ToastCenter?, restore: @escaping @MainActor (ComposeIntent) -> Void) {
        start(record, toasts: toasts, restore: restore)
    }

    /// Re-arms a send that was already promised in an earlier run of the app. Identical
    /// mechanics; the name exists so the launch path reads as what it is.
    func resume(_ record: PendingSend, toasts: ToastCenter?, restore: @escaping @MainActor (ComposeIntent) -> Void) {
        guard slots[record.id] == nil else { return }
        start(record, toasts: toasts, restore: restore)
    }

    /// Each call gets its own slot. An earlier design kept a single pending task and
    /// cancelled it here, which meant sending a second message inside the undo window
    /// silently destroyed the first one — no toast, no draft, no error.
    private func start(_ record: PendingSend, toasts: ToastCenter?, restore: @escaping @MainActor (ComposeIntent) -> Void) {
        let slot = Slot(id: record.id)
        slots[record.id] = slot

        slot.task = Task { @MainActor in
            // `ToastCenter` retires a toast after four seconds, so a ten-second undo window
            // would lose its Undo button two thirds of the way through. Re-arming the toast
            // in slices keeps the affordance alive for exactly as long as the promise holds.
            var remaining = Int(record.remaining.rounded())
            while remaining > 0 {
                let slice = min(3, remaining)
                self.arm(slot: slot, toasts: toasts, restore: restore)
                do { try await Task.sleep(for: .seconds(slice)) } catch {
                    self.slots[slot.id] = nil
                    return
                }
                guard !Task.isCancelled else {
                    self.slots[slot.id] = nil
                    return
                }
                remaining -= slice
            }

            // The window has closed. The last toast can outlive it by up to three seconds,
            // so the flag is set and the toast retired together — otherwise Undo stays on
            // screen, does nothing, and the person sends the same mail a second time.
            slot.committed = true
            toasts?.dismiss()

            defer { self.slots[slot.id] = nil }
            // Read now rather than at arming time: the draft mirror may have added a
            // `draft_id` while the window was open, and sending without it would leave the
            // message sitting in Drafts as a copy of one that has already gone out.
            let payload = PendingSendCenter.shared.payload(for: slot.id) ?? record.payload
            do {
                _ = try await APIClient.shared.send(payload)
                PendingSendCenter.shared.retire(slot.id)
                Haptics.success()
                // Sent is a list, and a reply changes the thread it answered; both are
                // on screens that have no other way of hearing this.
                MailBus.shared.changed()
                toasts?.show("Message sent")
            } catch let error as APIError {
                // The composer is long gone by now, so the failure has to be said out loud.
                // The record stays: the message is in Drafts, and the next launch retries
                // anything the network merely failed to deliver.
                if case .transport = error {
                    toasts?.error("Still offline. That message will go out when the app can reach the server.")
                } else {
                    PendingSendCenter.shared.retire(slot.id)
                    toasts?.error(error.errorDescription ?? "Could not send that. It is in Drafts.")
                }
            } catch {
                toasts?.error(error.localizedDescription)
            }
        }
    }

    private func arm(slot: Slot, toasts: ToastCenter?, restore: @escaping @MainActor (ComposeIntent) -> Void) {
        guard let toasts else { return }
        toasts.show("Sending…") { [weak self, weak slot] in
            guard let self, let slot, !slot.committed else { return }
            slot.task?.cancel()
            self.slots[slot.id] = nil
            // The intent is rebuilt from the record so the draft id the mirror assigned
            // travels back to the composer; the record itself is forgotten, but the draft
            // it wrote to the server is left for the reopened composer to keep patching.
            let reopened = PendingSendCenter.shared.intent(for: slot.id)
            PendingSendCenter.shared.retire(slot.id)
            if let reopened { restore(reopened) }
        }
    }
}

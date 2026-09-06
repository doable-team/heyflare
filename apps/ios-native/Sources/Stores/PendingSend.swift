import Foundation

// Undo send, made survivable.
//
// The promise the composer makes when it dismisses is that the message *will* go out. On
// the web that promise is kept by `sendBeacon` on unload (`ComposeContext.tsx:84-94`): the
// tab is closing, so hand the payload to the browser and let it finish the request. A phone
// has no unload. iOS suspends the app when it is backgrounded and kills it whenever it
// likes afterwards, taking every in-flight `Task` with it and saying nothing — so a message
// held in an undo window is a message that can quietly cease to exist.
//
// This is the fix: before the timer starts, the send is written down twice. Once on the
// server, as a draft, so the words survive even the phone being lost; and once here, on
// disk, with the payload and the instant it is due, so the app can finish the job on the
// next launch. Nothing is ever *only* in memory.

// MARK: - Record

/// A send that has been promised but not yet made.
struct PendingSend: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// The server this was armed against. A record is only ever replayed to the host that
    /// created it — pointing the app at a different heyflare must not post someone's mail
    /// to a stranger's worker.
    var host: String
    /// The `POST /api/send` body verbatim, already serialised. Kept as bytes rather than
    /// as typed fields so this file never has to be taught about a payload key it does not
    /// understand: whatever the composer built is what eventually goes out.
    var body: Data
    var dueAt: Date
    /// The draft written to the server while the window was open, so an undo can reopen the
    /// same row and a failure leaves something in Drafts rather than nothing anywhere.
    var draftID: String?
    /// Only for what the app says out loud on recovery.
    var subject: String

    var payload: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    /// Seconds still owed to the undo window, floored at zero.
    var remaining: TimeInterval { max(0, dueAt.timeIntervalSinceNow) }

    /// The composer, rebuilt from the payload, for the Undo on a re-armed send. Same
    /// reconstruction `DraftsScreen` does for a stored draft: the body is flattened HTML,
    /// and the quote is split back off the bottom of it.
    func composeIntent() -> ComposeIntent {
        let fields = payload
        let cc = Self.addresses(fields["cc"])
        let threadID = fields["thread_id"] as? String
        let replyTo = fields["reply_to_message_id"] as? String
        let split = HTMLText.splitQuoted(HTMLText.plain(from: fields["body_html"] as? String ?? ""))

        let kind: ComposeIntent.Kind
        if let threadID, let replyTo {
            kind = .reply(threadID: threadID, messageID: replyTo, all: !cc.isEmpty)
        } else {
            kind = .new
        }

        var intent = ComposeIntent(
            kind: kind,
            accountID: fields["account_id"] as? String,
            to: Self.addresses(fields["to"]),
            cc: cc,
            subject: fields["subject"] as? String ?? "",
            body: split.body,
            quoted: split.quoted ?? ""
        )
        intent.draftID = draftID ?? fields["draft_id"] as? String
        return intent
    }

    /// Bcc has no home on `ComposeIntent`; the composer's carry-over slot is where it goes.
    var bcc: [Address] { Self.addresses(payload["bcc"]) }

    private static func addresses(_ raw: Any?) -> [Address] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let email = entry["email"] as? String, !email.isEmpty else { return nil }
            return Address(email: email, name: entry["name"] as? String ?? "")
        }
    }
}

// MARK: - Store

/// The pending sends on this device, and the one thing that has to happen at launch.
///
/// A class with a shared instance rather than a free function, because the arming path and
/// the recovery path have to agree on the same on-disk list, and because `SendQueue` asks
/// it for the live payload at the moment a timer fires — the draft mirror may have added a
/// `draft_id` after the composer closed, and sending the stale copy would leave a duplicate
/// draft behind.
@MainActor
final class PendingSendCenter {
    static let shared = PendingSendCenter()

    /// Records older than this are dropped unread. Anything that has sat here for a week
    /// has already been mirrored into Drafts, and firing a week-old message at somebody
    /// because the phone was in a drawer is worse than not firing it at all.
    private static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    private var records: [PendingSend] = []
    private let file: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heyflare", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Application Support, not Caches: the system empties Caches under disk pressure,
        // and a message the person was told had been sent is not a cache.
        file = base.appendingPathComponent("pending-sends.json")
        load()
    }

    // MARK: Arming

    /// Writes the send down, then hands back the record the timer should be built on.
    ///
    /// The disk write is synchronous and deliberately so: it has to have happened before
    /// the composer dismisses, because everything after that point is a race against an
    /// arbitrary kill. It is a few kilobytes for an ordinary message; a message carrying
    /// the full 20 MB of attachments pays a visible fraction of a second here, which is
    /// the correct trade for not losing the attachments.
    func arm(_ payload: [String: Any], window seconds: Int, subject: String) -> PendingSend {
        let record = PendingSend(
            id: UUID(),
            host: Self.currentHost,
            body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(),
            dueAt: Date().addingTimeInterval(TimeInterval(max(0, seconds))),
            draftID: payload["draft_id"] as? String,
            subject: subject
        )
        records.append(record)
        persist()
        // The server copy can take its time: the local record already guarantees the send.
        Task { await self.mirror(record.id) }
        return record
    }

    /// The payload as it stands now, including any `draft_id` the mirror has since learned.
    func payload(for id: UUID) -> [String: Any]? {
        records.first { $0.id == id }?.payload
    }

    func draftID(for id: UUID) -> String? {
        records.first { $0.id == id }?.draftID
    }

    /// The record as a composer, for the Undo affordance. Read before retiring, because
    /// retiring is what forgets the draft id the mirror assigned.
    func intent(for id: UUID) -> ComposeIntent? {
        records.first { $0.id == id }?.composeIntent()
    }

    /// Forgets the record locally. The server draft is left where it is on purpose: an
    /// undone send reopens the composer holding that draft's id, so the next save patches
    /// the row rather than making a second one, and the eventual send consumes it.
    func retire(_ id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        persist()
    }

    // MARK: Recovery

    /// **The startup entry point.** Call once from `AppState.start()`, after the session is
    /// known: `await PendingSendCenter.shared.recoverOnLaunch()`.
    ///
    /// Anything whose window elapsed while the app was gone is sent now — the person was
    /// told it would be. Anything still inside its window is re-armed, so an app that was
    /// killed and relaunched inside ten seconds still honours the Undo it promised.
    ///
    /// Both arguments are optional so the call site does not have to reach for anything it
    /// does not already hold. Without a `ToastCenter` the work still happens, silently;
    /// without a `Navigator` a re-armed send has no Undo to offer, because there would be
    /// no composer to put back.
    func recoverOnLaunch(toasts: ToastCenter? = nil, navigator: Navigator? = nil) async {
        let now = Date()
        let overdue = records.filter { $0.dueAt <= now }
        let live = records.filter { $0.dueAt > now }

        for record in live {
            SendQueue.shared.resume(record, toasts: toasts) { reopened in
                guard let navigator else { return }
                ComposeCarryOver.bcc = record.bcc
                navigator.composing = reopened
            }
        }

        for record in overdue {
            await flush(record, toasts: toasts)
        }
    }

    /// Sends one overdue record.
    ///
    /// A transport failure keeps the record: the phone is simply offline, and the next
    /// launch should try again. Anything the server actually answered — a rejected
    /// account, an expired session, a refused message — retires it instead, because
    /// retrying a refusal forever only turns one problem into a loop. The draft mirror is
    /// what the message falls back to in that case, so it is made certain first.
    private func flush(_ record: PendingSend, toasts: ToastCenter?) async {
        guard let payload = payload(for: record.id) else { return }
        do {
            _ = try await APIClient.shared.send(payload)
            retire(record.id)
            MailBus.shared.changed()
            toasts?.show(record.subject.isEmpty ? "Sent a message that was still waiting" : "Sent “\(record.subject)”")
        } catch let error as APIError {
            if case .transport = error { return }
            await mirror(record.id)
            retire(record.id)
            toasts?.error("Could not send “\(record.subject)”. It is in Drafts.")
        } catch {
            return
        }
    }

    // MARK: Server mirror

    /// Writes the pending send to the server as a draft, and remembers its id.
    ///
    /// This is the half of the promise that survives the device itself. It also makes the
    /// undo path cheap: the reopened composer already has a row to patch.
    private func mirror(_ id: UUID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[index]
        let body = Self.draftBody(from: record.payload)

        if let draftID = record.draftID {
            _ = try? await APIClient.shared.updateDraft(draftID, body: body)
            return
        }
        guard let draft = try? await APIClient.shared.createDraft(body) else { return }

        // The record may have been retired (sent, or undone) while the request was out.
        guard let live = records.firstIndex(where: { $0.id == id }) else { return }
        var updated = records[live]
        updated.draftID = draft.id
        var payload = updated.payload
        // Quoting the draft back on send is what makes the worker consume the row instead
        // of leaving it in Drafts as a copy of a message that already went out.
        payload["draft_id"] = draft.id
        updated.body = (try? JSONSerialization.data(withJSONObject: payload)) ?? updated.body
        records[live] = updated
        persist()
    }

    /// The `POST /api/drafts` body is a subset of the send body, so it is taken from it
    /// key by key rather than rebuilt — one shape to be wrong about instead of two.
    /// Attachments are not among the keys: the drafts table has nowhere to put them.
    static func draftBody(from payload: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["account_id", "thread_id", "reply_to_message_id", "to", "cc", "bcc", "subject", "body_html"] {
            if let value = payload[key] { out[key] = value }
        }
        return out
    }

    // MARK: Disk

    private static var currentHost: String { ServerConfig.shared.baseURL?.host ?? "" }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([PendingSend].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        let host = Self.currentHost
        records = stored.filter { $0.host == host && $0.dueAt > cutoff }
        if records.count != stored.count { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

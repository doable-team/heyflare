import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// `PATCH /api/me` answers with the whole user, which is what lets the theme change land
/// in `AppState` without a second `GET /api/me`.
struct MeUpdateResponse: Codable, Sendable {
    var user: User
}

extension APIClient {
    /// The worker merges `settings` over what it already has, so a caller may send one key
    /// without first reading the rest back.
    func updateMe(settings: [String: Any]) async throws -> User {
        try await patch("/api/me", body: ["settings": settings], as: MeUpdateResponse.self, scoped: false).user
    }

    /// The owner's own name — who heyflare thinks you are, not the name on outgoing mail.
    /// That one is per mailbox and lives on `PATCH /api/accounts/:id`.
    func updateMe(name: String) async throws -> User {
        try await patch("/api/me", body: ["name": name], as: MeUpdateResponse.self, scoped: false).user
    }

    /// `PATCH /api/accounts/:id` — the sender name and the signature this mailbox signs
    /// with. Answers with the whole account, though the caller refreshes the list anyway so
    /// that every screen showing this mailbox agrees at once.
    @discardableResult
    func updateAccount(_ id: String, displayName: String, signature: String) async throws -> Account {
        try await patch(
            "/api/accounts/\(id)",
            body: ["display_name": displayName, "signature": signature],
            as: Account.self
        )
    }
}

/// Whether messages may pull images from the network.
///
/// This one lives on the device rather than in user settings on purpose: it is a privacy
/// switch about *this phone's* network, it has to be readable synchronously while a
/// message body is being built, and it must have a safe answer before the session exists.
/// The thread view reads `blockRemoteImages` directly.
enum ReadingPrefs {
    private static let blockRemoteImagesKey = "hey.blockRemoteImages"

    /// Defaults to blocking: an unset preference should be the private one, and the
    /// absence of a stored value is indistinguishable from a first launch.
    static var blockRemoteImages: Bool {
        get { UserDefaults.standard.object(forKey: blockRemoteImagesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: blockRemoteImagesKey) }
    }
}

@MainActor
@Observable
final class SettingsStore {
    /// How much the offline copy takes up, phrased for the row that clears it.
    private(set) var cacheSizeLabel = "Mail kept on this phone so screens open instantly"

    func measureCache() async {
        let bytes = await ContentCache.shared.diskSize()
        cacheSizeLabel = bytes < 32_000
            ? "Mail kept on this phone so screens open instantly"
            : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " kept on this phone"
    }

    /// Accounts with a sync in flight, so their row can say so and refuse a second tap.
    var syncing: Set<String> = []
    var savingTheme = false
    /// Any of the owner-level preferences being written. One flag rather than one per row:
    /// they all go through the same `PATCH /api/me`, and two in flight would race.
    var savingPreference = false
    var clearingCache = false
}

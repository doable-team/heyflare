import Foundation

/// Everything the app has already seen, kept so a screen never opens empty.
///
/// The rule this enforces is simple: **draw what we had, then correct it.** A list opens
/// with the rows from last time on the very first frame, the request goes out behind it,
/// and the rows are replaced when the answer lands. A spinner only ever appears when
/// there is genuinely nothing to show — a screen visited for the first time, on a fresh
/// install.
///
/// Reads are synchronous on purpose. An actor would force every call site to `await`,
/// which pushes the first paint past the frame we are trying to fill, so the hot layer is
/// a main-actor dictionary and only the disk writes go elsewhere. The dictionary is
/// filled from disk once at launch, before the first screen asks for anything.
@MainActor
final class ContentCache {
    static let shared = ContentCache()

    /// Bumped when a stored shape changes in a way old data cannot satisfy. Everything
    /// written by an older version is then ignored rather than decoded into nonsense.
    private static let version = 1

    private var memory: [String: Data] = [:]
    /// Keys whose disk copy is behind memory, coalesced into one write pass.
    private var dirty: Set<String> = []
    private var flushTask: Task<Void, Never>?

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Roughly a couple of thousand threads' worth. Past this the least recently written
    /// entries go, so a long-lived install cannot grow without bound.
    nonisolated private static let maxBytesOnDisk = 32 * 1024 * 1024

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("content/v\(Self.version)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Keys

    /// A cache key. Most content differs per mailbox scope, so the scope is part of the
    /// identity: switching from one account to "all" must not show the other's rows.
    enum Key {
        case imbox
        case counts
        case accounts
        case user
        case feed
        case screener
        case list(ThreadListKind)
        case thread(String)
        case contacts
        case files
        case collection(String)
        case labels
        case collections
        case clips
        case drafts
        case calendarMonth(String)
        case calendarSettings
        case calendarSources
        case calendarHabits
        case calendarJournal
        case labelThreads(String)
        case contact(String)
        case aiConversations

        /// Content that belongs to the owner rather than to a mailbox is not scoped —
        /// the calendar and the assistant are the same whichever inbox you are looking at.
        var isScoped: Bool {
            switch self {
            case .accounts, .user, .calendarMonth, .calendarSettings, .calendarSources,
                 .calendarHabits, .calendarJournal, .aiConversations, .thread,
                 .labelThreads, .contact, .collection: return false
            default: return true
            }
        }

        var raw: String {
            switch self {
            case .imbox: return "imbox"
            case .counts: return "counts"
            case .accounts: return "accounts"
            case .user: return "user"
            case .feed: return "feed"
            case .screener: return "screener"
            case .list(let kind): return "list.\(kind.rawValue)"
            case .thread(let id): return "thread.\(id)"
            case .contacts: return "contacts"
            case .files: return "files"
            case .collection(let id): return "collection.\(id)"
            case .labels: return "labels"
            case .collections: return "collections"
            case .clips: return "clips"
            case .drafts: return "drafts"
            case .calendarMonth(let month): return "cal.\(month)"
            case .calendarSettings: return "cal.settings"
            case .calendarSources: return "cal.sources"
            case .calendarHabits: return "cal.habits"
            case .calendarJournal: return "cal.journal"
            case .labelThreads(let id): return "label.\(id)"
            case .contact(let id): return "contact.\(id)"
            case .aiConversations: return "ai.conversations"
            }
        }

        /// A thread's own id already identifies it, so thread entries survive a scope
        /// change — opening the same thread from a different scope should still be instant.
        func identifier(scope: String) -> String {
            isScoped ? "\(raw)@\(scope)" : raw
        }
    }

    // MARK: - Reading

    /// The cached value, or nil when this screen has never been loaded. Synchronous, so a
    /// view can seed its state during `init` and paint on the first frame.
    func value<T: Decodable>(_ type: T.Type, for key: Key) -> T? {
        guard let data = memory[key.identifier(scope: ServerConfig.shared.scope)] else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - Writing

    func store<T: Encodable>(_ value: T, for key: Key) {
        guard let data = try? encoder.encode(value) else { return }
        let id = key.identifier(scope: ServerConfig.shared.scope)
        // Skip a write that changes nothing: most refreshes return what we already hold.
        guard memory[id] != data else { return }
        memory[id] = data
        dirty.insert(id)
        scheduleFlush()
    }

    /// Batches disk writes. A screen can store several things in quick succession — the
    /// list, then its counts — and this makes that one pass rather than three.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        let pending = dirty
        dirty.removeAll()
        guard !pending.isEmpty else { return }
        let payload = pending.compactMap { id -> (String, Data)? in
            guard let data = memory[id] else { return nil }
            return (id, data)
        }
        let folder = directory
        Task.detached(priority: .utility) {
            for (id, data) in payload {
                try? data.write(to: folder.appendingPathComponent(Self.filename(id)), options: .atomic)
            }
            await Self.prune(folder)
        }
    }

    /// Writes everything still pending, for the moment the app goes to the background.
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        flush()
    }

    // MARK: - Lifecycle

    /// Loads the whole cache into memory. Called once at launch, before the first screen
    /// is drawn, so that reads afterwards are a dictionary lookup.
    func preload() async {
        let folder = directory
        let loaded: [String: Data] = await Task.detached(priority: .userInitiated) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [:] }
            var out: [String: Data] = [:]
            for file in files {
                guard let data = try? Data(contentsOf: file), let id = Self.identifier(file.lastPathComponent) else { continue }
                out[id] = data
            }
            return out
        }.value
        // Anything written while the disk was being read wins: it is newer.
        memory.merge(loaded) { current, _ in current }
    }

    /// Signing out, or pointing the app at a different server, makes every stored row
    /// meaningless and potentially another person's. It all goes.
    func clear() {
        memory.removeAll()
        dirty.removeAll()
        flushTask?.cancel()
        flushTask = nil
        let folder = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Approximate size on disk, for the Settings row that offers to clear it.
    func diskSize() async -> Int {
        let folder = directory
        return await Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }.value
    }

    // MARK: - Disk naming

    /// Keys contain characters a filename cannot, so they are encoded rather than escaped.
    nonisolated private static func filename(_ id: String) -> String {
        Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    nonisolated private static func identifier(_ filename: String) -> String? {
        let base64 = filename
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Drops the oldest entries once the folder passes its ceiling. Thread bodies are the
    /// bulk of it and the least missed, since they are also the cheapest to refetch.
    nonisolated private static func prune(_ folder: URL) async {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > maxBytesOnDisk else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) {
            guard total > maxBytesOnDisk else { break }
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

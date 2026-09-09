import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// `GET /api/files?page=&q=` — every non-inline attachment across the mailboxes in scope,
/// newest first, one page at a time. Declared here because this is the only screen that
/// asks the worker for files as a list rather than as part of a message.
struct FilePage: Codable, Sendable {
    var files: [Attachment]
    var nextPage: Int?

    enum CodingKeys: String, CodingKey {
        case files
        case nextPage = "next_page"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = (try? c.decode([Attachment].self, forKey: .files)) ?? []
        nextPage = try? c.decodeIfPresent(Int.self, forKey: .nextPage)
    }
}

extension APIClient {
    func files(page: Int = 0, query: String = "") async throws -> FilePage {
        try await get(
            "/api/files",
            query: ["page": String(page), "q": query.isEmpty ? nil : query],
            as: FilePage.self
        )
    }
}

/// What a file *is*, decided from its MIME type and, when that is the useless
/// `application/octet-stream` a lot of mailers send, from its extension. Mirrors
/// `kindOf` in Files.tsx line for line so the two clients sort the same file the same way.
enum FileKind {
    case image, pdf, document, slides, spreadsheet, archive, video, audio, other

    static func of(mimeType: String, filename: String) -> FileKind {
        let n = filename.lowercased()
        let m = mimeType.lowercased()
        func hasSuffix(_ list: [String]) -> Bool { list.contains { n.hasSuffix(".\($0)") } }

        if m.hasPrefix("image/") { return .image }
        if m == "application/pdf" || n.hasSuffix(".pdf") { return .pdf }
        if m.contains("presentation") || m.contains("powerpoint") || hasSuffix(["ppt", "pptx", "key"]) { return .slides }
        if m.contains("spreadsheet") || m.contains("excel") || m == "text/csv" || hasSuffix(["xls", "xlsx", "csv", "numbers"]) { return .spreadsheet }
        if m.contains("word") || m.contains("document") || m.hasPrefix("text/") || m.contains("rtf") || hasSuffix(["doc", "docx", "txt", "md", "rtf", "pages"]) { return .document }
        if m.contains("zip") || m.contains("compressed") || m.contains("tar") || hasSuffix(["zip", "rar", "7z", "tar", "gz", "tgz"]) { return .archive }
        if m.hasPrefix("video/") { return .video }
        if m.hasPrefix("audio/") { return .audio }
        return .other
    }

    /// `KIND_ICON` in Files.tsx: the Lucide glyph the web draws on a tile without a preview.
    var lucide: String {
        switch self {
        case .image: return "fileImage"
        case .pdf, .document: return "fileText"
        case .slides: return "presentation"
        case .spreadsheet: return "fileSpreadsheet"
        case .archive: return "fileArchive"
        case .video: return "film"
        case .audio: return "music"
        case .other: return "file"
        }
    }

    /// The SF Symbol the iOS screen draws for the same kind.
    var icon: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .slides: return "rectangle.on.rectangle"
        case .spreadsheet: return "tablecells"
        case .archive: return "doc.zipper"
        case .video: return "film"
        case .audio: return "waveform"
        case .other: return "doc"
        }
    }
}

/// The eight filters the web offers. Two of them are unions rather than kinds — "Docs"
/// covers slides as well as documents, and "Media" covers video and audio — because
/// nobody looking for the deck they were sent thinks of it as a different category.
enum FileFilter: String, CaseIterable, Identifiable {
    case all, image, pdf, document, spreadsheet, archive, media, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .image: return "Images"
        case .pdf: return "PDFs"
        case .document: return "Docs"
        case .spreadsheet: return "Sheets"
        case .archive: return "Archives"
        case .media: return "Media"
        case .other: return "Other"
        }
    }

    func matches(_ kind: FileKind) -> Bool {
        switch self {
        case .all: return true
        case .media:
            if case .video = kind { return true }
            if case .audio = kind { return true }
            return false
        case .document:
            if case .document = kind { return true }
            if case .slides = kind { return true }
            return false
        case .image: if case .image = kind { return true }; return false
        case .pdf: if case .pdf = kind { return true }; return false
        case .spreadsheet: if case .spreadsheet = kind { return true }; return false
        case .archive: if case .archive = kind { return true }; return false
        case .other: if case .other = kind { return true }; return false
        }
    }
}

@MainActor
@Observable
final class FilesStore {
    var query = ""
    var filter: FileFilter = .all
    private(set) var files: [Attachment] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var error: String?

    private var nextPage: Int? = 0
    private var started = false

    /// Not observed: a pending debounce is bookkeeping, and redrawing on it would re-run
    /// the very `onChange` that scheduled it.
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var hasMore: Bool { nextPage != nil && nextPage != 0 }

    /// The filter runs over what has been fetched, not over the whole library — the same
    /// bargain the web makes. That is only honest because paging continues underneath a
    /// filter that is hiding everything, which `FilesScreen` makes sure of.
    var visible: [Attachment] {
        guard filter != .all else { return files }
        return files.filter { filter.matches(FileKind.of(mimeType: $0.mimeType, filename: $0.filename)) }
    }

    var totalBytes: Int { files.reduce(0) { $0 + $1.size } }

    func firstLoad() async {
        guard !started else { return }
        started = true
        loading = files.isEmpty
        await load(page: 0, replacing: true)
        loading = false
    }

    func refresh() async {
        started = true
        await load(page: 0, replacing: true)
    }

    func loadMore() async {
        guard let page = nextPage, page > 0, !loadingMore, !loading else { return }
        loadingMore = true
        await load(page: page, replacing: false)
        loadingMore = false
    }

    /// The worker searches filenames and thread subjects server-side, so every keystroke
    /// would otherwise be a round trip. 250ms matches the Contacts search.
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.searchNow()
        }
    }

    private func searchNow() async {
        loading = files.isEmpty
        await load(page: 0, replacing: true)
        loading = false
    }

    private func load(page: Int, replacing: Bool) async {
        do {
            let result = try await APIClient.shared.files(page: page, query: query)
            if replacing {
                files = result.files
            } else {
                // Paging is positional, so a file whose thread moved between requests can
                // arrive twice. Identity wins over arrival order.
                let known = Set(files.map(\.id))
                files.append(contentsOf: result.files.filter { !known.contains($0.id) })
            }
            nextPage = result.nextPage
            error = nil
        } catch is CancellationError {
            // A screen popped mid-request is not a failure.
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

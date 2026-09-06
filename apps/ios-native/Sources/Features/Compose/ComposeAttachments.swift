import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// Files going out with a message: what one is, what the limits are, the control that adds
// them and the tray that lists them. One file, because the caps are the only interesting
// thing here and every piece has to agree on them.

// MARK: - Model

// MARK: - Limits

// MARK: - Adding

/// The paperclip. Photos and files are two different system pickers, so the button is a
/// menu rather than one control that has to guess which was meant.
struct AttachmentButton: View {
    @Binding var attachments: [ComposeAttachment]
    /// Said out loud by the composer, which owns the one place failures are shown.
    let onProblem: (String) -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var browsingFiles = false

    var body: some View {
        Menu {
            Button("Photo library") { choosingPhotos = true }
            Button("Files") { browsingFiles = true }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(attachments.isEmpty ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(attachments.isEmpty ? "Attach a file" : "Attach a file, \(attachments.count) attached")
        // Images only: the cap is 20 MB for the whole message, and a phone video clears
        // that on its own, so offering one would be offering a refusal.
        .photosPicker(
            isPresented: $choosingPhotos,
            selection: $photoItems,
            maxSelectionCount: AttachmentLimits.count,
            matching: .images
        )
        .fileImporter(
            isPresented: $browsingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): absorb(urls)
            case .failure(let error): onProblem(error.localizedDescription)
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await absorb(items) }
        }
    }

    /// Files chosen through the document browser. Each URL is security-scoped and only
    /// readable between the start/stop pair, which is the other reason the bytes are copied
    /// in rather than referenced.
    private func absorb(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                onProblem("Could not read \(url.lastPathComponent).")
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)
            guard add(ComposeAttachment(
                filename: url.lastPathComponent,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                data: data
            )) else { return }
        }
    }

    /// Photos. `PhotosPickerItem` carries no filename — the picker hands over an asset, not
    /// a file — so one is made from the item's content type. A recipient sees a name that
    /// matches the bytes, which is the part that actually matters.
    private func absorb(_ items: [PhotosPickerItem]) async {
        defer { photoItems = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                onProblem("Could not read that photo.")
                continue
            }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            guard add(ComposeAttachment(
                filename: "photo-\(attachments.count + 1).\(ext)",
                mimeType: type?.preferredMIMEType ?? "image/jpeg",
                data: data
            )) else { return }
        }
    }

    /// False when the caps stopped it, which also stops the rest of the batch: once the
    /// budget is spent, adding the next file can only fail the same way.
    @discardableResult
    private func add(_ attachment: ComposeAttachment) -> Bool {
        if let refusal = AttachmentLimits.refusal(adding: attachment.size, to: attachments) {
            onProblem(refusal)
            Haptics.warning()
            return false
        }
        attachments.append(attachment)
        Haptics.select()
        return true
    }
}

// MARK: - Listing

/// What is attached, with a named remove control on each row.
///
/// Drawn as rows rather than the web client's two-column grid: on a phone the filename is
/// the thing that identifies a file and a column halves the room it has to be read in.
struct AttachmentTray: View {
    let attachments: [ComposeAttachment]
    /// Scheduled mail cannot carry files, so the tray says so where the files are rather
    /// than waiting for the send to be refused.
    var scheduled: Bool = false
    let onRemove: (ComposeAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(attachments.count) \(attachments.count == 1 ? "file" : "files")")
                Text("·")
                Text("\(AttachmentLimits.describe(AttachmentLimits.total(attachments))) of \(AttachmentLimits.describe(AttachmentLimits.totalBytes))")
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(Theme.Typography.micro)
            .foregroundStyle(Theme.Colors.mutedForeground)

            ForEach(attachments) { attachment in
                row(attachment)
            }

            if scheduled {
                Text("Scheduled mail cannot carry attachments. Remove them, or send now.")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 10)
    }

    private func row(_ attachment: ComposeAttachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.Colors.mutedForeground)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(AttachmentLimits.describe(attachment.size))
                    .font(Theme.Typography.micro)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }

            Spacer(minLength: 0)

            Button {
                onRemove(attachment)
                Haptics.select()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: Theme.Metrics.minTouchTarget, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.leading, 10)
        .frame(minHeight: 44)
        .background(Theme.Colors.muted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
    }
}

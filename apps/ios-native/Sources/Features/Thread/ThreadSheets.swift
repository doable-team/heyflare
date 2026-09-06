import SwiftUI

// The thread screen's editing sheets. Each one is a dumb view over a callback: the
// screen owns the request, the toast and the refreshed thread, so a sheet never has to
// know what an action costs or how it failed.

// MARK: - Shared chrome

/// Grabber, title, one line of explanation. The subtitle is where the sheets say who
/// can see the thing being edited, because a note and a rename are both private and
/// nothing else on screen says so.
struct ThreadSheetHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 3) {
            SheetGrabber()
            Text(title)
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Colors.foreground)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 14)
    }
}

/// A text box that looks like the rest of the app: `TextEditor` draws its own background
/// and insets its text by 5pt, so both are corrected here rather than at every call site.
private struct SheetTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 120

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.foreground)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(Theme.Colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Said the same way the Assistant tab says it, because it is the same fact: the keys
/// live encrypted on the Worker and can only be entered there.
struct ThreadAiNotConfigured: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No provider yet")
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Colors.foreground)
            Text("Add a model provider and key in the web app under Settings, AI. Keys are stored encrypted on your Worker, so they cannot be entered here.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }
}

// MARK: - Note

/// Writes, replaces or clears the thread's private note.
///
/// The thread header has drawn a note since this screen existed but offered no way to
/// write one, so a note could only ever arrive from the web client. This is that half.
struct ThreadNoteSheet: View {
    let note: String
    let onSave: (String) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var confirmingClear = false
    @FocusState private var focused: Bool

    init(note: String, onSave: @escaping (String) -> Void, onClear: @escaping () -> Void) {
        self.note = note
        self.onSave = onSave
        self.onClear = onClear
        _text = State(initialValue: note)
    }

    var body: some View {
        VStack(spacing: 12) {
            ThreadSheetHeader(title: note.isEmpty ? "Stick a note on it" : "Note", subtitle: "A private note, just for you.")

            SheetTextEditor(text: $text, placeholder: "Phone numbers, reminders, context…")
                .focused($focused)

            HStack(spacing: 10) {
                // Only offered when there is something to lose. Clearing is destructive, so
                // it is named for what it does and confirmed — never coloured.
                if !note.isEmpty {
                    Button("Clear note") { confirmingClear = true }
                        .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))
                        .frame(maxWidth: 140)
                }
                Button("Save note") {
                    onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 16)
        .screenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Theme.Colors.foreground)
        .task {
            // A beat after the sheet settles, or the keyboard fights the presentation.
            try? await Task.sleep(nanoseconds: 250_000_000)
            focused = true
        }
        .confirmationDialog("Clear this note?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear note", role: .destructive) { onClear(); dismiss() }
            Button("Keep", role: .cancel) {}
        }
    }
}

// MARK: - Rename

/// Renames the thread for you alone. The original subject is kept by the server, so
/// "Use original subject" is a real undo rather than retyping what it used to say.
struct ThreadRenameSheet: View {
    let subject: String
    let originalSubject: String
    let onSave: (String) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(subject: String, originalSubject: String, onSave: @escaping (String) -> Void, onReset: @escaping () -> Void) {
        self.subject = subject
        self.originalSubject = originalSubject
        self.onSave = onSave
        self.onReset = onReset
        _text = State(initialValue: subject)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Restoring is only on offer when there is a different name to restore to.
    private var canReset: Bool { !originalSubject.isEmpty && originalSubject != subject }

    var body: some View {
        VStack(spacing: 12) {
            ThreadSheetHeader(title: "Rename subject", subtitle: "Only you see this name.")

            TextField(originalSubject.isEmpty ? "Subject" : originalSubject, text: $text, axis: .vertical)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.done)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .background(Theme.Colors.muted)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                .accessibilityLabel("Subject")

            Button("Save") {
                // An empty field means "no custom name", which is the same request the
                // reset button makes — so it is sent as one rather than saving a blank.
                if trimmed.isEmpty || trimmed == originalSubject { onReset() } else { onSave(trimmed) }
                dismiss()
            }
            .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))

            if canReset {
                Button("Use original subject") { onReset(); dismiss() }
                    .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 16)
        .screenBackground()
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .tint(Theme.Colors.foreground)
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            focused = true
        }
    }
}

// MARK: - Labels

/// Every label the account has, ticked where it is already on this thread.
///
/// The tick moves before the server answers and moves back if the call fails: a label
/// toggle is one round trip, and waiting for it makes the list feel broken.
struct ThreadLabelsSheet: View {
    let applied: Set<String>
    /// Returns whether the change stuck, so a refused toggle can put the tick back.
    let toggle: (MailLabel, Bool) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var labels: [MailLabel] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ThreadSheetHeader(title: "Labels", subtitle: "Tap to put one on, tap again to take it off.")

            if let error {
                InlineError(message: error) { Task { await load() } }
            } else if loading {
                ProgressView().tint(Theme.Colors.mutedForeground).padding(.vertical, 32)
            } else if labels.isEmpty {
                EmptyState(icon: "tag", message: "No labels yet. Make them in the web app and they turn up here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(labels) { label in
                            row(label)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
        .screenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task {
            selected = applied
            await load()
        }
    }

    private func row(_ label: MailLabel) -> some View {
        let on = selected.contains(label.id)
        return Button {
            Haptics.select()
            selected.formSymmetricDifference([label.id])
            Task {
                if await toggle(label, !on) == false {
                    selected.formSymmetricDifference([label.id])
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tag")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 20)
                Text(label.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.foreground)
                }
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .hairline()
        .accessibilityLabel(label.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func load() async {
        error = nil
        loading = labels.isEmpty
        defer { loading = false }
        do {
            labels = try await APIClient.shared.labels()
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Could not load your labels."
        }
    }
}

// MARK: - Reply with AI

/// A one-line brief and a tone, which is all the web asks for too. The draft it comes
/// back with opens in the composer; nothing is ever sent from here.
struct ThreadAiReplySheet: View {
    let threadID: String
    let onDraft: (ThreadAiReply) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var brief = ""
    @State private var tone: ThreadAiTone = .match
    @State private var working = false
    @State private var error: String?
    /// nil until `/api/ai/settings` answers. Asked before the request rather than after a
    /// failure, so "no provider" reads as an explanation instead of an error.
    @State private var configured: Bool?
    @FocusState private var focused: Bool

    private var canWrite: Bool {
        !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThreadSheetHeader(title: "Reply with AI")

            if configured == false {
                ThreadAiNotConfigured()
            } else {
                SheetTextEditor(
                    text: $brief,
                    placeholder: "What do you want to say? e.g. “Yes, Tuesday at 3 works — ask them to send the agenda.”",
                    minHeight: 96
                )
                .focused($focused)

                // Scrolls rather than compresses: at the largest text sizes four pills do
                // not fit across a small phone, and a squeezed tone name is unreadable.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ThreadAiTone.allCases) { option in
                            tonePill(option)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .frame(height: Theme.Metrics.minTouchTarget)

                if let error {
                    Text(error)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.foreground)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Colors.muted)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                }

                Button {
                    Task { await write() }
                } label: {
                    HStack(spacing: 8) {
                        if working { ProgressView().tint(Theme.Colors.background) }
                        Text(working ? "Writing…" : "Write reply")
                    }
                }
                .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
                .disabled(!canWrite)
                .opacity(canWrite ? 1 : 0.5)

                Text("Reads the whole thread and what the assistant knows about how you write. It opens in the composer — you send it.")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 16)
        .screenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Theme.Colors.foreground)
        .task {
            configured = (try? await APIClient.shared.aiSettings())?.configured ?? true
            guard configured == true else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            focused = true
        }
    }

    private func tonePill(_ option: ThreadAiTone) -> some View {
        let on = tone == option
        return Button {
            tone = option
        } label: {
            Text(option.title)
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.Colors.background : Theme.Colors.foreground)
                .padding(.horizontal, 14)
                .frame(height: Theme.Metrics.minTouchTarget)
                .background(on ? Theme.Colors.foreground : Color.clear)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: on ? 0 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func write() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let draft = try await APIClient.shared.aiReply(
                threadID: threadID,
                brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
                tone: tone
            )
            Haptics.success()
            onDraft(draft)
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "The assistant could not write that."
        }
    }
}

// MARK: - Clip

/// Trims a passage out of a message before keeping it.
///
/// The web clips whatever you selected inside the message body. That selection lives
/// inside a `WKWebView` here, and reaching into it means injecting script into untrusted
/// mail HTML and round-tripping the result — so this starts from the message's whole
/// readable text and lets you cut it down instead. Less precise, honestly named, and it
/// makes the Clips library's "select text in a message to keep it" true on this client.
struct ThreadClipSheet: View {
    let source: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    /// What the server stores. Anything past this is dropped there, so it is dropped here
    /// where the counter can show it happening.
    private static let limit = 5000

    init(source: String, onSave: @escaping (String) -> Void) {
        self.source = source
        self.onSave = onSave
        _text = State(initialValue: String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.limit)))
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 12) {
            ThreadSheetHeader(title: "Save a clip", subtitle: "Cut this down to the part worth keeping.")

            SheetTextEditor(text: $text, placeholder: "Nothing to clip", minHeight: 180)
                .focused($focused)
                .onChange(of: text) { _, new in
                    if new.count > Self.limit { text = String(new.prefix(Self.limit)) }
                }

            HStack {
                Text("\(trimmed.count) of \(Self.limit) characters")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .monospacedDigit()
                Spacer()
            }

            Button("Save clip") {
                onSave(trimmed)
                dismiss()
            }
            .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
            .disabled(trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.5 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 16)
        .screenBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(Theme.Colors.foreground)
    }
}

// MARK: - Summary panel

/// The AI summary, above the messages, foldable and dismissible.
///
/// It sits inside the scroll rather than pinned: on a phone a permanent panel would eat
/// the top third of the screen, and the summary is a thing you read once.
struct ThreadSummaryPanel: View {
    let state: ThreadSummaryState
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(Theme.Motion.quick) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                        Text("Summary")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Colors.foreground)
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Collapse summary" : "Expand summary")

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Hide summary")
            }

            if open { content }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, open ? 10 : 0)
        .background(Theme.Colors.muted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().tint(Theme.Colors.mutedForeground)
                Text("Reading the thread…")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            .padding(.bottom, 4)
        case .ready(let summary):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Self.bullets(summary).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                        Text(line)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
        case .unconfigured:
            ThreadAiNotConfigured()
                .padding(.bottom, 2)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: onRetry)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.foreground)
                    .frame(height: Theme.Metrics.minTouchTarget)
            }
        }
    }

    /// The model is asked for "- " bullets but is not held to it, so the markers are
    /// stripped and the blank lines dropped rather than drawn as empty rows.
    private static func bullets(_ summary: String) -> [String] {
        summary
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                while let first = text.first, "-*•".contains(first) {
                    text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return text
            }
            .filter { !$0.isEmpty }
    }
}

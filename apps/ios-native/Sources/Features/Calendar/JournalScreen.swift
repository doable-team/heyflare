import SwiftUI

// The journal, ported from `src/web/pages/Journal.tsx`: an index of every day that has an
// entry, and a per-date editor that saves itself.

/// One entry a day. Nobody reads it but you.
///
/// The index is the whole screen — there is no filtering and no search, because the list is
/// short by construction and the thing you actually want is nearly always today's, which is
/// what the button in the bar is for.
struct JournalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var entries: [CalDay] = []
    @State private var loading = false
    @State private var editing: JournalDay?

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    if entries.isEmpty {
                        if loading {
                            ProgressView()
                                .tint(Theme.Colors.mutedForeground)
                                .padding(.vertical, 56)
                        } else {
                            EmptyState(
                                icon: "book.closed",
                                message: "Nothing written down yet.\nA line about the day is enough.",
                                actionTitle: "Write today's",
                                action: { editing = JournalDay(date: CalDate.todayKey) }
                            )
                        }
                    } else {
                        ForEach(entries, id: \.date) { entry in
                            row(entry)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable { await load() }
        }
        .screenBackground()
        .task { await load() }
        .sheet(item: $editing) { day in
            JournalEntrySheet(date: day.date)
        }
        // A sheet that saved something changes the index behind it, so it is reloaded on the
        // way back rather than left stale until the next visit.
        .onChange(of: editing) { previous, current in
            if previous != nil && current == nil { Task { await load() } }
        }
    }

    private var bar: some View {
        TopBar(title: "Journal") {
            BarButton(icon: "chevron.left", label: "Back") { dismiss() }
        } trailing: {
            Button("Today") { editing = JournalDay(date: CalDate.todayKey) }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .frame(height: Theme.Metrics.minTouchTarget)
                .padding(.horizontal, 8)
                .accessibilityLabel("Write today's entry")
        }
    }

    private var header: some View {
        Text("One entry a day. Nobody reads it but you.")
            .font(Theme.Typography.small)
            .foregroundStyle(Theme.Colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.top, 12)
            .padding(.bottom, 16)
    }

    private func row(_ entry: CalDay) -> some View {
        let day = CalDate.date(fromKey: entry.date) ?? Date()
        return Button {
            editing = JournalDay(date: entry.date)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(CalDate.dayLabel(day))
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Colors.foreground)
                    if !entry.label.isEmpty {
                        Text(entry.label)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let relative = CalDate.relativeDay(day) {
                        Text(relative)
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                }
                if let excerpt = entry.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minTouchTarget, alignment: .leading)
            .contentShape(Rectangle())
            .hairline(.bottom)
        }
        .buttonStyle(PressableRowStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(CalDate.spokenDate(day)). \(entry.excerpt ?? "")")
    }

    private func load() async {
        loading = entries.isEmpty
        defer { loading = false }
        do {
            entries = try await CalendarAPI.journalIndex()
        } catch {
            guard !(error is CancellationError) else { return }
            toasts.error((error as? APIError)?.errorDescription ?? "Couldn't load the journal.")
        }
    }
}

// MARK: - One day's entry

/// The editor for a single day, which saves itself and never asks.
///
/// The API field is HTML, so the text is converted on the way in and out with `HTMLText`.
/// Plain text is the whole native format: the web's toolbar is bold, italic, a heading, a list
/// and a link, and none of those survive a thumb well enough to justify a rich-text control
/// here. Nothing is lost by reading an entry written on the desktop — the tags come off for
/// editing — but saving one *does* flatten its formatting, so the screen says so.
struct JournalEntrySheet: View {
    let date: String

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var text = ""
    @State private var loaded = false
    /// What the server last confirmed it holds. The debounce compares against this so an
    /// autosave that changes nothing never goes out.
    @State private var saved = ""
    @State private var hadMarkup = false
    @State private var status = ""
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var writing: Bool

    /// The web debounces at 900ms (`Journal.tsx:16`); the same number here means the same
    /// feel, and it is long enough that a sentence is one write rather than forty.
    private static let debounce: Duration = .milliseconds(900)

    private var day: Date { CalDate.date(fromKey: date) ?? Date() }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: CalDate.dayLabel(day)) {
                Button("Done") {
                    // Leaving commits whatever the debounce has not yet sent, so closing the
                    // sheet is never the thing that loses a sentence.
                    saveTask?.cancel()
                    Task { await save() }
                    dismiss()
                }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .frame(height: Theme.Metrics.minTouchTarget)
                .padding(.horizontal, 8)
            } trailing: {
                Text(status)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .padding(.horizontal, 8)
                    .accessibilityHidden(status.isEmpty)
            }

            if hadMarkup {
                Text("This entry was written with formatting. Editing it here keeps the words and drops the styling.")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.vertical, 8)
                    .background(Theme.Colors.muted)
            }

            TextEditor(text: $text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .focused($writing)
                .accessibilityLabel("Journal entry for \(CalDate.spokenDate(day))")
                .onChange(of: text) { _, _ in schedule() }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && loaded {
                        Text("How was today?")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .padding(.horizontal, 17)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .screenBackground()
        .tint(Theme.Colors.foreground)
        .task { await load() }
        .onDisappear { saveTask?.cancel() }
    }

    private func load() async {
        do {
            let entry = try await CalendarAPI.journal(date: date)
            let html = entry.journalHTML ?? ""
            hadMarkup = html.range(of: "<[a-zA-Z][^>]*>", options: .regularExpression) != nil
                && HTMLText.plain(from: html) != html
            text = HTMLText.plain(from: html)
            saved = text
            loaded = true
            // A blank day opens with the keyboard up: there is nothing to read, only to write.
            if text.isEmpty { writing = true }
        } catch {
            guard !(error is CancellationError) else { return }
            loaded = true
            toasts.error((error as? APIError)?.errorDescription ?? "Couldn't open that entry.")
        }
    }

    private func schedule() {
        guard loaded else { return }
        status = ""
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        guard loaded, text != saved else { return }
        let outgoing = text
        do {
            // An emptied entry is sent as an empty string rather than as `<p></p>`: the worker
            // treats a blank `journal_html` as "no entry", which is what clearing one means.
            let html = outgoing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : HTMLText.htmlBody(from: outgoing)
            _ = try await CalendarAPI.saveJournal(date: date, html: html)
            saved = outgoing
            status = "Saved"
            hadMarkup = false
        } catch {
            guard !(error is CancellationError) else { return }
            status = "Not saved"
        }
    }
}

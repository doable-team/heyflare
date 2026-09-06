import SwiftUI

/// What the assistant remembers about you, grouped the way the web groups it. Every
/// entry can be corrected or removed, because a memory you cannot see or fix is a
/// memory you cannot trust.
struct AiMemoryScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var entries: [AiMemoryEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var addKind: AiMemoryKind = .preference
    @State private var draft = ""
    @State private var editing: AiMemoryEntry?
    @State private var pendingDelete: AiMemoryEntry?
    @FocusState private var adding: Bool

    private var grouped: [(AiMemoryKind, [AiMemoryEntry])] {
        AiMemoryKind.allCases.compactMap { kind in
            let rows = entries.filter { $0.kind == kind }
            return rows.isEmpty ? nil : (kind, rows)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Memory") {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                EmptyView()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Read into every conversation. Edit anything that is wrong; delete anything that is not yours to keep.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Metrics.hPadding)
                        .padding(.top, 12)

                    if loading && entries.isEmpty {
                        ProgressView().tint(Theme.Colors.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                    } else if let error, entries.isEmpty {
                        EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                            Task { await load() }
                        }
                    } else if entries.isEmpty {
                        EmptyState(icon: "brain", message: "Nothing remembered yet. Add something below, or let it learn from your mail.")
                    } else {
                        ForEach(grouped, id: \.0) { kind, rows in
                            SectionHeader(title: kind.label, trailing: "\(rows.count)")
                            ForEach(rows) { entry in
                                SwipeRow(
                                    trailing: .init(icon: "trash", label: "Delete", resets: true) {
                                        pendingDelete = entry
                                    }
                                ) {
                                    Button { editing = entry } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(entry.content)
                                                .font(Theme.Typography.body)
                                                .foregroundStyle(Theme.Colors.foreground)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 8)
                                            Text(entry.source == "user" ? "You" : entry.source == "learned" ? "Learned" : "Assistant")
                                                .font(Theme.Typography.micro)
                                                .foregroundStyle(Theme.Colors.mutedForeground)
                                        }
                                        .padding(.horizontal, Theme.Metrics.hPadding)
                                        .padding(.vertical, 12)
                                        .frame(minHeight: Theme.Metrics.minTouchTarget)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PressableRowStyle())
                                }
                                .hairline()
                            }
                        }
                    }

                    addRow
                }
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
            .scrollDismissesKeyboard(.interactively)
        }
        .screenBackground()
        .tint(Theme.Colors.foreground)
        .task { await load() }
        .sheet(item: $editing) { entry in
            MemoryEditSheet(entry: entry) { text in
                await update(entry, content: text)
            }
        }
        .confirmationDialog(
            "Delete this memory?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) { Task { await remove(entry) } }
            Button("Keep", role: .cancel) {}
        } message: { entry in
            Text(entry.content)
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Add")
            HStack(spacing: 8) {
                Menu {
                    ForEach(AiMemoryKind.allCases, id: \.self) { kind in
                        Button(kind.label) { addKind = kind }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(addKind.label)
                            .font(Theme.Typography.small)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Colors.foreground)
                    .padding(.horizontal, 10)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .background(Theme.Colors.muted)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                }

                TextField("Something to remember…", text: $draft, axis: .vertical)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1...4)
                    .focused($adding)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
                    .background(Theme.Colors.muted)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))

                Button("Add") { Task { await add() } }
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
        }
    }

    // MARK: Mutations

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await APIClient.shared.aiMemory()
            error = nil
        } catch {
            guard !(error is CancellationError) else { return }
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func add() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let entry = try await APIClient.shared.addAiMemory(kind: addKind, content: text)
            entries.insert(entry, at: 0)
            draft = ""
            Haptics.success()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func update(_ entry: AiMemoryEntry, content: String) async {
        do {
            let fresh = try await APIClient.shared.updateAiMemory(entry.id, content: content)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = fresh }
            Haptics.select()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func remove(_ entry: AiMemoryEntry) async {
        let index = entries.firstIndex { $0.id == entry.id }
        withAnimation(Theme.Motion.rowExit) { entries.removeAll { $0.id == entry.id } }
        do {
            try await APIClient.shared.deleteAiMemory(entry.id)
            Haptics.select()
        } catch {
            if let index { withAnimation(Theme.Motion.rowExit) { entries.insert(entry, at: min(index, entries.count)) } }
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

private struct MemoryEditSheet: View {
    let entry: AiMemoryEntry
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(entry: AiMemoryEntry, onSave: @escaping (String) async -> Void) {
        self.entry = entry
        self.onSave = onSave
        _text = State(initialValue: entry.content)
    }

    var body: some View {
        VStack(spacing: 12) {
            ThreadSheetHeader(title: entry.kind.label, subtitle: "Correct it, and the assistant reads the corrected version from now on.")
            TextField("", text: $text, axis: .vertical)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .lineLimit(3...10)
                .focused($focused)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Theme.Colors.muted)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
            Button("Save") {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                Task { await onSave(value) }
                dismiss()
            }
            .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 16)
        .screenBackground()
        .presentationDetents([.medium])
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            focused = true
        }
    }
}

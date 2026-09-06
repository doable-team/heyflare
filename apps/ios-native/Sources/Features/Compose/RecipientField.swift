import SwiftUI

// The To / Cc / Bcc input. One file, because the chip row, its wrapping layout and the
// address syntax it enforces are the same idea seen from three angles.

// MARK: - Address syntax

/// What counts as an address the composer will accept. Deliberately shape-only: the
/// worker is the authority on deliverability, so this side rejects the typos a person
/// can see (no `@`, no dot in the domain, a stray space) and lets everything else through.
enum EmailSyntax {
    static func isValid(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty else { return false }
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return false }
        return true
    }

    /// Accepts both what a person types (`someone@example.com`) and what a person pastes
    /// out of another mail client (`Someone <someone@example.com>`).
    static func parse(_ raw: String) -> Address? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var name = ""
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            name = String(text[text.startIndex..<open])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            text = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        guard isValid(text) else { return nil }
        return Address(email: text, name: name)
    }
}

// MARK: - Flow layout

/// Packs chips left to right and wraps them onto a new line when the next one will not fit.
///
/// This is a `Layout` rather than a stack of hard-coded `HStack` rows because the number of
/// rows is not knowable up front: it depends on the container width, the length of every
/// address, and the reader's Dynamic Type size — all of which the layout engine already
/// measures for us. Pre-slicing the chips into rows in the view body would mean guessing at
/// text widths and re-guessing on every rotation and font change. `Layout` asks each subview
/// what it wants instead, so the wrapping is always correct and the view body stays a flat
/// `ForEach` plus the field.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let limit = proposal.width ?? .infinity
        let lines = lines(maxWidth: limit, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        // Claim the offered width so the field lines up with the rows above and below it.
        let width = proposal.width ?? (lines.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for line in lines(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (slot, index) in line.indices.enumerated() {
                let width = line.widths[slot]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: line.height)
                )
                x += width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var widths: [CGFloat] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()

        for index in subviews.indices {
            // Measure against the container, never against infinity: an address longer than
            // the screen must be clamped and truncated rather than pushing the row off-screen.
            let ideal = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let width = min(ideal.width, maxWidth)
            let projected = line.indices.isEmpty ? width : line.width + spacing + width

            if !line.indices.isEmpty, projected > maxWidth {
                lines.append(line)
                line = Line(indices: [index], widths: [width], width: width, height: ideal.height)
            } else {
                line.indices.append(index)
                line.widths.append(width)
                line.width = projected
                line.height = max(line.height, ideal.height)
            }
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

// MARK: - Field

/// One addressing row: a label, the committed addresses as removable chips, a text field
/// that wraps in beside them, and the contact matches for whatever is being typed.
///
/// The field owns nothing but its own draft text — every committed address goes straight
/// into the binding, so the composer never has to ask this view what it is holding.
struct RecipientField: View {
    let label: String
    @Binding var addresses: [Address]
    /// Contacts for a partial query. Non-throwing on purpose: a failed lookup is a silent
    /// absence of suggestions, never an error the person composing has to deal with.
    let suggestions: (String) async -> [Address]
    var focusOnAppear: Bool = false

    /// An invisible character parked at the head of the field.
    ///
    /// SwiftUI's `TextField` reports text, not keystrokes, so there is no `didDeleteBackward`
    /// to hook. Keeping one zero-width space in front of the draft turns backspace-on-empty
    /// into something observable: the text stops starting with the sentinel, which can only
    /// happen when delete was pressed with nothing else left to remove.
    private static let sentinel = "\u{200B}"

    @State private var raw = RecipientField.sentinel
    @State private var matches: [Address] = []
    @State private var lookup: Task<Void, Never>?
    @State private var rejected = false
    @FocusState private var focused: Bool

    private var typed: String {
        raw.hasPrefix(Self.sentinel) ? String(raw.dropFirst()) : raw
    }

    private var placeholder: String {
        addresses.isEmpty ? "Add someone" : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 34, height: Theme.Metrics.minTouchTarget, alignment: .leading)

                ChipFlowLayout {
                    ForEach(addresses) { address in
                        chip(address)
                    }
                    field
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if rejected, !typed.isEmpty {
                Text("That is not an email address yet.")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.leading, 42)
                    .padding(.bottom, 6)
            }

            if focused, !matches.isEmpty {
                suggestionList
            }
        }
        .onChange(of: raw) { _, next in handle(next) }
        .onChange(of: focused) { _, isFocused in
            // Leaving the field is a commit: an address typed but never separated should
            // not quietly vanish when the person taps the next row.
            if !isFocused {
                if !typed.trimmingCharacters(in: .whitespaces).isEmpty { _ = commit(typed) }
                matches = []
            }
        }
        .task {
            guard focusOnAppear else { return }
            // The sheet is still animating in on the first frame; focusing into it too early
            // is dropped, so wait for the presentation to settle.
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
        .onDisappear { lookup?.cancel() }
    }

    // MARK: Pieces

    private func chip(_ address: Address) -> some View {
        Button {
            remove(address)
        } label: {
            HStack(spacing: 5) {
                Text(address.display)
                    .font(Theme.Typography.small)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            .foregroundStyle(Theme.Colors.foreground)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Theme.Colors.muted)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 0.5))
            // The pill reads at 32pt; the tap target around it clears the 44pt minimum.
            .frame(height: Theme.Metrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(address.display)")
    }

    private var field: some View {
        TextField(placeholder, text: $raw)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.foreground)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .submitLabel(.next)
            .focused($focused)
            .onSubmit { _ = commit(typed) }
            .frame(width: fieldWidth, height: Theme.Metrics.minTouchTarget)
            .accessibilityLabel("\(label) recipients")
    }

    /// A `TextField` is infinitely flexible, so inside a flow it would always claim a whole
    /// line. Measuring the draft text gives the field an intrinsic width instead, which lets
    /// it sit beside the chips until the text genuinely needs the room.
    private var fieldWidth: CGFloat {
        let probe = typed.isEmpty ? placeholder : typed
        let measured = (probe as NSString)
            .size(withAttributes: [.font: UIFont.systemFont(ofSize: 15)])
            .width
        return min(max(96, measured + 26), 320)
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(matches) { address in
                Button {
                    _ = commit(address)
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(address: address, size: Theme.Metrics.smallAvatar)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(address.display)
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.foreground)
                                .lineLimit(1)
                            Text(address.email)
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.Colors.mutedForeground)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .frame(height: Theme.Metrics.minTouchTarget, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableRowStyle())
            }
        }
        .background(Theme.Colors.muted.opacity(0.6))
        .transition(.opacity)
    }

    // MARK: Editing

    /// Everything the field does in response to typing, in one place, because the sentinel
    /// makes the text and the chip list a single piece of state.
    private func handle(_ next: String) {
        guard next.hasPrefix(Self.sentinel) else {
            // The sentinel is gone: delete was pressed on an empty field.
            raw = Self.sentinel
            if !addresses.isEmpty {
                addresses.removeLast()
                Haptics.select()
            }
            matches = []
            return
        }

        let text = String(next.dropFirst())
        if let cut = text.firstIndex(where: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" }) {
            let candidate = String(text[..<cut]).trimmingCharacters(in: .whitespaces)
            let rest = String(text[text.index(after: cut)...])
            if candidate.isEmpty {
                raw = Self.sentinel + rest
            } else if commit(candidate) {
                raw = Self.sentinel + rest
            } else {
                // Keep what was typed, drop only the separator, and say why nothing happened.
                raw = Self.sentinel + candidate + rest
                rejected = true
                Haptics.warning()
            }
            return
        }

        rejected = false
        scheduleLookup(text)
    }

    @discardableResult
    private func commit(_ text: String) -> Bool {
        guard let address = EmailSyntax.parse(text) else { return false }
        return commit(address)
    }

    @discardableResult
    private func commit(_ address: Address) -> Bool {
        let key = address.email.lowercased()
        if !addresses.contains(where: { $0.email.lowercased() == key }) {
            addresses.append(address)
            Haptics.select()
        }
        raw = Self.sentinel
        matches = []
        rejected = false
        return true
    }

    private func remove(_ address: Address) {
        addresses.removeAll { $0.email.lowercased() == address.email.lowercased() }
        Haptics.select()
    }

    /// Debounced so a fast typist makes one request, not one per keystroke. Each new
    /// keystroke cancels the previous wait, which also cancels its in-flight lookup.
    private func scheduleLookup(_ query: String) {
        lookup?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            matches = []
            return
        }
        lookup = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await suggestions(trimmed)
            guard !Task.isCancelled else { return }
            // Already-chosen addresses are dropped, and so are repeats: the same person can
            // exist as a contact on two connected mailboxes, and `Address` is identified by
            // its email, which a `ForEach` will not tolerate twice.
            var seen = Set(addresses.map { $0.email.lowercased() })
            var unique: [Address] = []
            for address in found {
                let key = address.email.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                unique.append(address)
                if unique.count == 6 { break }
            }
            withAnimation(Theme.Motion.quick) { matches = unique }
        }
    }
}

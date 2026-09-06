import SwiftUI
import UIKit

// The calendar's one editor, ported from `src/web/calendar/EventSheet.tsx`.
//
// The web client already mounts that sheet on a phone — `MobileCalendar.tsx:171` and
// `MobileDay.tsx:166` — so the question of whether a full event editor belongs on a 390pt
// screen is settled by the product, and the job here is to match it rather than to trim it.
// What is deliberately *not* ported: guests (the address field is a screen of its own), the
// countdown and circled switches, and day photos. None of those are dropped on save — the
// worker's `readEventInput` leaves absent fields alone, so an omitted field is untouched
// rather than cleared, which is exactly what makes a partial editor safe.

// MARK: - Recurrence

/// The presets the web offers, in its order. `EventSheet.tsx:53`.
enum RepeatKind: String, CaseIterable, Hashable {
    case never, daily, weekdays, weekly, biweekly, monthly, yearly, custom

    /// The five real presets, without the two ends of the menu.
    static let presets: [RepeatKind] = [.daily, .weekdays, .weekly, .biweekly, .monthly, .yearly]
}

enum RepeatEnd: String, CaseIterable, Hashable {
    case never, until, count

    var title: String {
        switch self {
        case .never: return "Ends never"
        case .until: return "Ends on…"
        case .count: return "Ends after…"
        }
    }
}

/// RRULE reading and writing, ported one-for-one from `EventSheet.tsx`. The point of the
/// fidelity is the round trip: an edit that never touches the repeat field must send back the
/// same rule it was given, or a weekly meeting quietly becomes something else.
enum RRule {
    private static let byDay = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    private static func ordinal(_ n: Int) -> String {
        let rest = n % 100
        if rest >= 11 && rest <= 13 { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    /// The rule body for one of the offered cases, anchored on the event's start day.
    static func base(_ kind: RepeatKind, startKey: String) -> String {
        let cal = CalDate.cal
        let day = CalDate.date(fromKey: startKey, in: cal) ?? Date()
        switch kind {
        case .daily: return "FREQ=DAILY"
        case .weekdays: return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .weekly: return "FREQ=WEEKLY;BYDAY=\(byDay[cal.component(.weekday, from: day) - 1])"
        case .biweekly: return "FREQ=WEEKLY;INTERVAL=2;BYDAY=\(byDay[cal.component(.weekday, from: day) - 1])"
        case .monthly: return "FREQ=MONTHLY;BYMONTHDAY=\(cal.component(.day, from: day))"
        default: return "FREQ=YEARLY"
        }
    }

    static func label(_ kind: RepeatKind, startKey: String) -> String {
        let cal = CalDate.cal
        let day = CalDate.date(fromKey: startKey, in: cal) ?? Date()
        switch kind {
        case .never: return "Does not repeat"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly:
            let name = cal.standaloneWeekdaySymbols[cal.component(.weekday, from: day) - 1]
            return "Weekly on \(name)"
        case .biweekly: return "Every two weeks"
        case .monthly: return "Monthly on the \(ordinal(cal.component(.day, from: day)))"
        case .yearly: return "Every year"
        case .custom: return "Custom…"
        }
    }

    /// `FREQ=DAILY;COUNT=5` → `["FREQ": "DAILY", "COUNT": "5"]`, upper-cased, `RRULE:` tolerated.
    static func parts(_ rrule: String) -> [String: String] {
        var out: [String: String] = [:]
        let body = rrule.replacingOccurrences(of: "^RRULE:", with: "", options: [.regularExpression, .caseInsensitive])
        for part in body.split(separator: ";") {
            guard let split = part.firstIndex(of: "=") else { continue }
            let key = part[part.startIndex..<split].trimmingCharacters(in: .whitespaces).uppercased()
            let value = part[part.index(after: split)...].trimmingCharacters(in: .whitespaces).uppercased()
            out[key] = value
        }
        return out
    }

    /// The rule without its ending clause — the ending lives in its own controls.
    static func stripEnd(_ rrule: String) -> String {
        rrule
            .replacingOccurrences(of: "^RRULE:", with: "", options: [.regularExpression, .caseInsensitive])
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.uppercased().hasPrefix("UNTIL=") && !$0.uppercased().hasPrefix("COUNT=") }
            .joined(separator: ";")
    }

    /// A comparable form of a rule body, so two rules that mean the same thing compare equal:
    /// parts sorted, `INTERVAL=1` (the default) dropped, `BYDAY` order ignored, `WKST` ignored.
    /// Without this, `FREQ=WEEKLY;BYDAY=MO;WKST=SU` from Google would never match our
    /// `FREQ=WEEKLY;BYDAY=MO` and every synced weekly event would show as "Custom".
    static func canon(_ rrule: String) -> String {
        var m = parts(stripEnd(rrule))
        m["WKST"] = nil
        if m["INTERVAL"] == "1" { m["INTERVAL"] = nil }
        if let byday = m["BYDAY"] {
            m["BYDAY"] = byday.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.sorted().joined(separator: ",")
        }
        return m.keys.sorted().map { "\($0)=\(m[$0] ?? "")" }.joined(separator: ";")
    }

    private static let utcStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// `UNTIL` is an instant, not a date: RFC 5545 writes it in UTC. Reading it back through
    /// the local clock is what makes "ends on the 5th" still say the 5th after a round trip,
    /// because that is exactly how `stamp` wrote it.
    static func untilKey(_ raw: String) -> String {
        let pattern = "^(\\d{4})(\\d{2})(\\d{2})(?:T(\\d{2})(\\d{2})(\\d{2})(Z)?)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else {
            return CalDate.todayKey
        }
        func group(_ i: Int) -> String {
            guard match.numberOfRanges > i, let r = Range(match.range(at: i), in: raw) else { return "" }
            return String(raw[r])
        }
        guard !group(7).isEmpty else { return "\(group(1))-\(group(2))-\(group(3))" }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let comps = DateComponents(year: Int(group(1)), month: Int(group(2)), day: Int(group(3)),
                                   hour: Int(group(4)), minute: Int(group(5)), second: Int(group(6)))
        guard let instant = utc.date(from: comps) else { return CalDate.todayKey }
        return CalDate.key(instant)
    }

    /// The last minute of `key` in local time, as a UTC stamp: `20260905T225900Z`.
    static func stamp(_ key: String) -> String {
        utcStamp.string(from: Date(timeIntervalSince1970: CalDate.ms(key, minutes: 24 * 60 - 1) / 1000))
    }

    struct Recognised {
        var kind: RepeatKind
        /// Only meaningful for `custom`: the rule body, ending clause removed.
        var text: String
        var end: RepeatEnd
        var until: String
        var count: Int
    }

    /// Recognise a stored RRULE as one of the offered cases so the menu shows a real label.
    /// Anything we don't know falls through to "custom" with the rule intact — nothing is ever
    /// silently rewritten, which matters because the round trip has to survive an edit that
    /// never touches the repeat field.
    static func recognise(_ rrule: String?, startKey: String) -> Recognised {
        let blank = Recognised(kind: .never, text: "", end: .never, until: startKey, count: 10)
        guard let rrule, !rrule.trimmingCharacters(in: .whitespaces).isEmpty else { return blank }
        let m = parts(rrule)
        let untilRaw = m["UNTIL"]
        let countRaw = m["COUNT"]
        let end: RepeatEnd = untilRaw != nil ? .until : (countRaw != nil ? .count : .never)
        let until = untilRaw.map { untilKey($0) } ?? startKey
        let count = countRaw.flatMap { Int($0) }.map { max(1, $0) } ?? 10

        let body = canon(rrule)
        for kind in RepeatKind.presets where canon(base(kind, startKey: startKey)) == body {
            return Recognised(kind: kind, text: "", end: end, until: until, count: count)
        }
        return Recognised(kind: .custom, text: stripEnd(rrule), end: end, until: until, count: count)
    }
}

// MARK: - Reminders

/// 120 → "2 hours"; 45 → "45 minutes". The biggest unit that divides evenly wins.
enum ReminderUnit: String, CaseIterable, Hashable {
    case minutes, hours, days

    var scale: Int {
        switch self {
        case .minutes: return 1
        case .hours: return 60
        case .days: return 1440
        }
    }

    static func split(_ minutes: Int) -> (amount: Int, unit: ReminderUnit) {
        if minutes > 0 && minutes % 1440 == 0 { return (minutes / 1440, .days) }
        if minutes > 0 && minutes % 60 == 0 { return (minutes / 60, .hours) }
        return (minutes, .minutes)
    }
}

// MARK: - What the sheet was opened for

/// A create with its slot already chosen, or an existing event.
enum EventEditorTarget: Identifiable, Hashable {
    /// A new event on `day`, running `startMinutes` to `endMinutes` past local midnight.
    case create(day: String, startMinutes: Int, endMinutes: Int, allDay: Bool)
    case edit(CalEventFull)
    /// A new event prefilled from a mail thread: its subject, its first line and its people.
    case draft(EventDraft)

    /// Identity has to change when the *slot* changes, not just when the case does: a second
    /// press-and-hold two hours down the timeline must build a fresh form, not reuse the last.
    var id: String {
        switch self {
        case .create(let day, let from, let to, let allDay): return "new:\(day):\(from):\(to):\(allDay ? 1 : 0)"
        case .edit(let event): return "edit:\(event.id)"
        case .draft(let draft): return "draft:\(draft.threadID)"
        }
    }

    static func create(on day: String) -> EventEditorTarget {
        .create(day: day, startMinutes: 9 * 60, endMinutes: 10 * 60, allDay: false)
    }
}

// MARK: - Form

/// The editable shape of an event. Compared against the copy taken when the sheet opened,
/// which is the whole of "are there unsaved changes".
private struct EventForm: Equatable {
    var calendarID = ""
    var title = ""
    var emoji = ""
    var allDay = false
    var startDate = ""
    /// Minutes past local midnight. Ignored while `allDay`.
    var startMin = 9 * 60
    /// While `allDay` this is the *inclusive* last day; otherwise the day the event stops on.
    var endDate = ""
    var endMin = 10 * 60
    var repeatKind = RepeatKind.never
    var rruleText = ""
    var repeatEnd = RepeatEnd.never
    var until = ""
    var count = 10
    var location = ""
    var notes = ""
    var conferenceURL = ""
    var link = ""
    var reminders: [CalReminder] = []
    /// Guests, carried only by a draft from mail. This editor does not show them; they ride
    /// along so an event made from a thread invites the people who were on it.
    var attendees: [Address] = []

    init(_ target: EventEditorTarget, defaultCalendar: String) {
        switch target {
        case .create(let day, let from, let to, let allDay):
            calendarID = defaultCalendar
            self.allDay = allDay
            startDate = day
            endDate = day
            startMin = from
            endMin = to
            until = day
        case .draft(let draft):
            calendarID = defaultCalendar
            title = draft.title
            notes = draft.description
            startDate = draft.dayKey
            endDate = draft.dayKey
            startMin = draft.startMinutes
            endMin = max(draft.endMinutes, draft.startMinutes + 15)
            until = draft.dayKey
            attendees = draft.attendees
        case .edit(let event):
            let startKey = (event.allDay ? event.startDate : nil) ?? CalDate.key(event.start)
            calendarID = event.calendarID
            title = event.title
            emoji = event.emoji
            allDay = event.allDay
            startDate = startKey
            // All-day rows carry their own inclusive dates; timed rows only carry instants.
            endDate = event.allDay ? (event.endDate ?? startKey) : CalDate.key(event.end)
            startMin = CalDate.minutesOfDay(event.startsAt)
            endMin = event.allDay ? min(CalDate.minutesOfDay(event.startsAt) + 60, 24 * 60 - 15)
                                  : CalDate.minutesOfDay(event.endsAt)
            location = event.location
            notes = event.description
            conferenceURL = event.conferenceURL
            link = event.url
            reminders = event.reminders
            let repeats = RRule.recognise(event.rrule, startKey: startKey)
            repeatKind = repeats.kind
            rruleText = repeats.text
            repeatEnd = repeats.end
            until = repeats.until
            count = repeats.count
        }
    }

    var rrule: String? {
        guard repeatKind != .never else { return nil }
        // Custom rules are taken as typed, minus any ending the user wrote — the ending
        // controls own that half, and they were seeded from the same rule, so nothing is lost.
        var rule = repeatKind == .custom ? RRule.stripEnd(rruleText) : RRule.base(repeatKind, startKey: startDate)
        guard !rule.isEmpty else { return nil }
        if repeatEnd == .until, !until.isEmpty { rule += ";UNTIL=\(RRule.stamp(until))" }
        else if repeatEnd == .count { rule += ";COUNT=\(min(max(count, 1), 999))" }
        return rule
    }

    /// The body of the write. `attendees`, `countdown` and `circled` are deliberately absent:
    /// this editor does not show them, and an absent field is left alone by the worker.
    func input(timezone: String) -> EventInput {
        var input = EventInput()
        input.calendarID = calendarID
        input.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        input.description = notes
        input.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        input.emoji = emoji
        input.rrule = .some(rrule)
        input.conferenceURL = conferenceURL.trimmingCharacters(in: .whitespaces)
        input.url = link.trimmingCharacters(in: .whitespaces)
        input.reminders = reminders.map(\.minutes)
        input.timezone = timezone
        input.allDay = allDay
        // Only ever set from a draft. An absent key leaves an existing event's guests alone.
        if !attendees.isEmpty {
            input.attendees = attendees.map { ["email": $0.email, "name": $0.name] }
        }
        if allDay {
            // `end_date` is inclusive, so the instant the day *stops* is midnight of the day
            // after it.
            input.startDate = .some(startDate)
            input.endDate = .some(endDate)
            input.startsAt = CalDate.ms(startDate, minutes: 0)
            input.endsAt = CalDate.ms(CalDate.addingDays(1, toKey: endDate), minutes: 0)
        } else {
            input.startDate = .some(nil)
            input.endDate = .some(nil)
            input.startsAt = CalDate.ms(startDate, minutes: startMin)
            input.endsAt = CalDate.ms(endDate, minutes: endMin)
        }
        return input
    }
}

// MARK: - Sheet

/// The editor. Everything that writes to the calendar goes through here.
struct EventEditor: View {
    let target: EventEditorTarget
    /// The calendars the picker offers and the timezone a write is stamped with.
    let store: CalendarStore

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    @State private var form: EventForm
    @State private var baseline: EventForm
    @State private var event: CalEventFull?
    @State private var busy = false
    @State private var error: String?
    @State private var ask: Ask?
    @State private var showEmoji = false
    @State private var shareFile: ShareFile?

    /// Which question is on screen. `EventSheet.tsx:404`.
    private enum Ask: String, Identifiable {
        case discard, delete, deleteScope, saveScope
        var id: String { rawValue }
    }

    init(target: EventEditorTarget, store: CalendarStore) {
        self.target = target
        self.store = store
        let start = EventForm(target, defaultCalendar: store.defaultCalendarID)
        _form = State(initialValue: start)
        // A draft arrives already filled in, and saving it as it stands is the whole point;
        // measured against a blank form it counts as changed, so Save is live at once.
        if case .draft(let draft) = target {
            _baseline = State(initialValue: EventForm(.create(on: draft.dayKey), defaultCalendar: store.defaultCalendarID))
        } else {
            _baseline = State(initialValue: start)
        }
        if case .edit(let existing) = target { _event = State(initialValue: existing) }
        else { _event = State(initialValue: nil) }
    }

    /// An ICS subscription is a mirror of somebody else's calendar: readable, never writable.
    private var readOnly: Bool {
        if let event, !event.writable { return true }
        return store.calendars.first { $0.id == form.calendarID }.map { !$0.writable } ?? false
    }

    private var dirty: Bool { form != baseline }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollView {
                VStack(spacing: 0) {
                    titleRow
                    allDayRow
                    startRow
                    endRow
                    repeatRow
                    locationRow
                    calendarRow
                    notesRow
                    linkRows
                    remindersRow
                    if readOnly { readOnlyNote }
                    if let event { existingEventActions(event) }
                }
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.bottom, 32)
            }
            footer
        }
        .screenBackground()
        // One tint for the whole sheet so every system control it contains — the switches, the
        // date wheels, the confirmation buttons — comes out grayscale rather than system blue.
        .tint(Theme.Colors.foreground)
        .environment(\.locale, CalDate.clockLocale)
        .sheet(isPresented: $showEmoji) {
            EmojiPicker(selected: form.emoji) { form.emoji = $0 }
                .presentationDetents([.height(300)])
        }
        .sheet(item: $shareFile) { file in
            // `ShareSheet` already exists for mail attachments; an .ics is the same gesture.
            ShareSheet(items: [file.url])
        }
        .confirmationDialog(askTitle, isPresented: askBinding, titleVisibility: .visible) {
            askButtons
        } message: {
            Text(askMessage)
        }
        .interactiveDismissDisabled(dirty && !readOnly)
        .task {
            // The calendar list can arrive after the sheet is already open. Filling the blank
            // has to move the baseline with it, or an untouched form would count as dirty and
            // a cancel would ask about changes nobody made.
            guard form.calendarID.isEmpty else { return }
            await store.loadPrefs()
            let picked = store.defaultCalendarID
            guard !picked.isEmpty else { return }
            form.calendarID = picked
            baseline.calendarID = picked
        }
    }

    // MARK: Chrome

    private var bar: some View {
        TopBar(title: event == nil ? "New event" : "Event") {
            Button(readOnly ? "Close" : "Cancel") { requestClose() }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .frame(height: Theme.Metrics.minTouchTarget)
                .padding(.horizontal, 8)
                .disabled(busy)
        } trailing: {
            if readOnly {
                EmptyView()
            } else {
                Button(event == nil ? "Create" : "Save") { requestSave() }
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(busy ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .padding(.horizontal, 8)
                    .disabled(busy)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let error {
                // A failed save stays on screen next to the button — a toast would take the
                // reason with it.
                Text(error)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.vertical, 10)
                    .background(Theme.Colors.muted)
                    .accessibilityAddTraits(.isStaticText)
            }
            if let event, !readOnly {
                HStack(spacing: 8) {
                    Button("Delete event") { ask = event.recurring ? .deleteScope : .delete }
                        .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))
                        .disabled(busy)
                    Button("Duplicate") { Task { await duplicate(event) } }
                        .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))
                        .disabled(busy)
                }
                .padding(Theme.Metrics.hPadding)
                .hairline(.top)
            }
        }
        .background(Theme.Colors.background)
    }

    // MARK: Rows

    private var titleRow: some View {
        HStack(spacing: 10) {
            Button { showEmoji = true } label: {
                Group {
                    if form.emoji.isEmpty {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    } else {
                        Text(form.emoji).font(.system(size: 20))
                    }
                }
                .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(form.emoji.isEmpty ? "Add an emoji" : "Emoji, \(form.emoji)")
            .disabled(readOnly)

            TextField("Untitled event", text: $form.title)
                .font(Theme.Typography.section)
                .foregroundStyle(Theme.Colors.foreground)
                .textInputAutocapitalization(.sentences)
                .disabled(readOnly)
                .accessibilityLabel("Title")
        }
        .frame(minHeight: Theme.Metrics.minTouchTarget)
        .padding(.vertical, 6)
        .hairline(.bottom)
    }

    private var allDayRow: some View {
        EditorRow(label: "All day") {
            Toggle(isOn: Binding(get: { form.allDay }, set: { setAllDay($0) })) {
                Text(form.allDay ? "Takes the whole day" : "Has a start and an end")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            .disabled(readOnly)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
        }
    }

    private var startRow: some View {
        EditorRow(label: "Starts") {
            HStack(spacing: 8) {
                DatePicker("", selection: startDateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("Start date")
                if !form.allDay {
                    DatePicker("", selection: startTimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel("Start time")
                }
                Spacer(minLength: 0)
            }
            .disabled(readOnly)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
        }
    }

    private var endRow: some View {
        EditorRow(label: "Ends") {
            HStack(spacing: 8) {
                DatePicker("", selection: endDateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("End date")
                if !form.allDay {
                    DatePicker("", selection: endTimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel("End time")
                }
                Spacer(minLength: 0)
            }
            .disabled(readOnly)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
        }
    }

    private var repeatRow: some View {
        EditorRow(label: "Repeat") {
            VStack(alignment: .leading, spacing: 8) {
                MenuField(title: RRule.label(form.repeatKind, startKey: form.startDate), enabled: !readOnly) {
                    Button(RRule.label(.never, startKey: form.startDate)) { form.repeatKind = .never }
                    ForEach(RepeatKind.presets, id: \.self) { kind in
                        Button(RRule.label(kind, startKey: form.startDate)) { form.repeatKind = kind }
                    }
                    Button("Custom…") { form.repeatKind = .custom }
                }

                if form.repeatKind == .custom {
                    TextField("FREQ=WEEKLY;INTERVAL=3;BYDAY=TU,TH", text: $form.rruleText)
                        .font(Theme.Typography.mono)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .disabled(readOnly)
                        .frame(minHeight: Theme.Metrics.minTouchTarget)
                        .accessibilityLabel("Recurrence rule")
                    Text("An iCalendar RRULE, without the ending — that's set below.")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }

                if form.repeatKind != .never {
                    MenuField(title: form.repeatEnd.title, enabled: !readOnly) {
                        ForEach(RepeatEnd.allCases, id: \.self) { end in
                            Button(end.title) { form.repeatEnd = end }
                        }
                    }
                    if form.repeatEnd == .until {
                        DatePicker("", selection: untilBinding, displayedComponents: .date)
                            .labelsHidden()
                            .disabled(readOnly)
                            .accessibilityLabel("Repeats until")
                    }
                    if form.repeatEnd == .count {
                        HStack(spacing: 8) {
                            Stepper(value: $form.count, in: 1...999) {
                                Text("\(form.count) times")
                                    .font(Theme.Typography.small)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Colors.foreground)
                            }
                            .disabled(readOnly)
                        }
                        .frame(minHeight: Theme.Metrics.minTouchTarget)
                    }
                }

                // A Google-expanded occurrence repeats but carries no rule, so the menu above
                // honestly says "does not repeat" — this says the rest of the truth.
                if let event, event.recurring, event.series {
                    Text("Repeats. This copy came from Google, which sends one row per occurrence, so a save only ever changes this one.")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var locationRow: some View {
        EditorRow(label: "Location") {
            TextField("Somewhere, or a room", text: $form.location)
                .font(Theme.Typography.body)
                .disabled(readOnly)
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .accessibilityLabel("Location")
        }
    }

    private var calendarRow: some View {
        EditorRow(label: "Calendar") {
            MenuField(title: currentCalendarName, enabled: !readOnly) {
                ForEach(store.writableCalendars(including: form.calendarID)) { source in
                    Button(source.name) { form.calendarID = source.id }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var notesRow: some View {
        EditorRow(label: "Notes") {
            TextEditor(text: $form.notes)
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.foreground)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72)
                .disabled(readOnly)
                .accessibilityLabel("Notes")
        }
    }

    private var linkRows: some View {
        Group {
            EditorRow(label: "Call link") {
                TextField("https://", text: $form.conferenceURL)
                    .font(Theme.Typography.body)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(readOnly)
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
                    .accessibilityLabel("Conference link")
            }
            EditorRow(label: "Link") {
                TextField("https://", text: $form.link)
                    .font(Theme.Typography.body)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(readOnly)
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
                    .accessibilityLabel("Link")
            }
        }
    }

    private var remindersRow: some View {
        EditorRow(label: "Reminders") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(form.reminders.enumerated()), id: \.element.id) { index, reminder in
                    ReminderRow(
                        minutes: Binding(
                            get: { form.reminders.indices.contains(index) ? form.reminders[index].minutes : 0 },
                            set: { if form.reminders.indices.contains(index) { form.reminders[index].minutes = $0 } }
                        ),
                        readOnly: readOnly,
                        remove: { form.reminders.removeAll { $0.id == reminder.id } }
                    )
                }
                if readOnly && form.reminders.isEmpty {
                    Text("None")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                } else if !readOnly {
                    Button {
                        form.reminders.append(CalReminder(minutes: 10))
                    } label: {
                        Label("Add a reminder", systemImage: "plus")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .frame(height: Theme.Metrics.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var readOnlyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.mutedForeground)
            Text("This comes from a subscribed calendar\(currentCalendarName.isEmpty ? "" : " (\(currentCalendarName))") and can't be edited here.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
        }
        .padding(.top, 16)
        .accessibilityElement(children: .combine)
    }

    // MARK: The things only an existing event can do

    @ViewBuilder
    private func existingEventActions(_ event: CalEventFull) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if myInvitation(event) != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Going?")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                    HStack(spacing: 8) {
                        ForEach([CalRsvp.accepted, .tentative, .declined], id: \.self) { answer in
                            Button {
                                Task { await answerRSVP(event, answer) }
                            } label: {
                                HStack(spacing: 4) {
                                    if event.rsvp == answer {
                                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    }
                                    Text(answer.title)
                                }
                                .font(Theme.Typography.small)
                                .foregroundStyle(event.rsvp == answer ? Theme.Colors.background : Theme.Colors.foreground)
                                .padding(.horizontal, 14)
                                .frame(height: Theme.Metrics.minTouchTarget)
                                .background {
                                    RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                        .fill(event.rsvp == answer ? Theme.Colors.foreground : Color.clear)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                        .strokeBorder(Theme.Colors.border, lineWidth: event.rsvp == answer ? 0 : 1)
                                }
                            }
                            .disabled(busy)
                            .accessibilityLabel("Reply \(answer.title)")
                            .accessibilityAddTraits(event.rsvp == answer ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                if let url = URL(string: event.conferenceURL), !event.conferenceURL.isEmpty {
                    Link(destination: url) {
                        Label("Join", systemImage: "video")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.foreground)
                            .padding(.horizontal, 14)
                            .frame(height: Theme.Metrics.minTouchTarget)
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
                            }
                    }
                }
                if event.isTodo && !readOnly {
                    Button {
                        Task { await toggleDone(event) }
                    } label: {
                        Label(event.done ? "Mark not done" : "Mark done", systemImage: "checkmark")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.foreground)
                            .padding(.horizontal, 14)
                            .frame(height: Theme.Metrics.minTouchTarget)
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
                            }
                    }
                    .disabled(busy)
                }
                Button {
                    Task { await exportICS(event) }
                } label: {
                    Label("Export .ics", systemImage: "square.and.arrow.up")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .disabled(busy)
                Spacer(minLength: 0)
            }

            Text(provenance(event))
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.Colors.mutedForeground)
        }
        .padding(.top, 20)
    }

    /// The invitation addressed to this person, which is the only reason an RSVP control
    /// appears at all. `EventSheet.tsx:849-865`.
    private func myInvitation(_ event: CalEventFull) -> CalAttendee? {
        var mine = Set(app.accounts.map { $0.email.lowercased() })
        if let email = app.user?.email { mine.insert(email.lowercased()) }
        return event.attendees.first { mine.contains($0.email.lowercased()) }
    }

    private func provenance(_ event: CalEventFull) -> String {
        var parts: [String] = []
        if !event.calendarName.isEmpty { parts.append(event.calendarName) }
        if event.createdAt > 0 {
            parts.append("added " + CalDate.shortDayLabel(Date(timeIntervalSince1970: event.createdAt / 1000)))
        }
        if event.updatedAt > 0, event.updatedAt != event.createdAt {
            parts.append("edited " + CalDate.shortDayLabel(Date(timeIntervalSince1970: event.updatedAt / 1000)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Bindings

    private var currentCalendarName: String {
        store.calendars.first { $0.id == form.calendarID }?.name ?? (form.calendarID.isEmpty ? "Pick a calendar" : "")
    }

    /// A `DatePicker` speaks `Date`; the form speaks day keys and minutes. These translate,
    /// and every write goes through `moveStart`/`moveEnd` so the two ends stay consistent.
    private var startDateBinding: Binding<Date> {
        Binding(
            get: { CalDate.date(fromKey: form.startDate) ?? Date() },
            set: { moveStart(date: CalDate.key($0)) }
        )
    }

    private var startTimeBinding: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: CalDate.ms(form.startDate, minutes: form.startMin) / 1000) },
            set: { moveStart(minutes: CalDate.minutesOfDay($0.timeIntervalSince1970 * 1000)) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { CalDate.date(fromKey: form.endDate) ?? Date() },
            set: { moveEnd(date: CalDate.key($0)) }
        )
    }

    private var endTimeBinding: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: CalDate.ms(form.endDate, minutes: form.endMin) / 1000) },
            set: { moveEnd(minutes: CalDate.minutesOfDay($0.timeIntervalSince1970 * 1000)) }
        )
    }

    private var untilBinding: Binding<Date> {
        Binding(
            get: { CalDate.date(fromKey: form.until) ?? Date() },
            set: { form.until = CalDate.key($0) }
        )
    }

    // MARK: Time arithmetic

    /// Moving the start drags the end along, keeping the duration, the way every calendar does.
    private func moveStart(date: String? = nil, minutes: Int? = nil) {
        let startDate = date ?? form.startDate
        if form.allDay {
            let cal = CalDate.cal
            let from = CalDate.date(fromKey: form.startDate, in: cal) ?? Date()
            let to = CalDate.date(fromKey: form.endDate, in: cal) ?? from
            let span = max(0, cal.dateComponents([.day], from: from, to: to).day ?? 0)
            form.startDate = startDate
            form.endDate = CalDate.addingDays(span, toKey: startDate, in: cal)
            return
        }
        let startMin = minutes ?? form.startMin
        let keep = max(0, CalDate.ms(form.endDate, minutes: form.endMin) - CalDate.ms(form.startDate, minutes: form.startMin))
        let end = CalDate.ms(startDate, minutes: startMin) + keep
        form.startDate = startDate
        form.startMin = startMin
        form.endDate = CalDate.key(Date(timeIntervalSince1970: end / 1000))
        form.endMin = CalDate.minutesOfDay(end)
    }

    /// An end before the start is corrected, not rejected: it snaps to the first legal slot.
    private func moveEnd(date: String? = nil, minutes: Int? = nil) {
        if form.allDay {
            let endDate = date ?? form.endDate
            form.endDate = endDate < form.startDate ? form.startDate : endDate
            return
        }
        let start = CalDate.ms(form.startDate, minutes: form.startMin)
        var end = CalDate.ms(date ?? form.endDate, minutes: minutes ?? form.endMin)
        if end <= start { end = start + 15 * 60_000 }
        form.endDate = CalDate.key(Date(timeIntervalSince1970: end / 1000))
        form.endMin = CalDate.minutesOfDay(end)
    }

    /// All-day and timed are two different shapes, not a flag on one shape, so the toggle
    /// converts. Timed → all-day: `end_date` is *inclusive*, so an event that stops at midnight
    /// belongs to the day before the instant it ends on — otherwise a 9pm–midnight meeting
    /// would grow a second day. All-day → timed: the inclusive end day becomes the day the
    /// event stops on, at a sane hour.
    private func setAllDay(_ on: Bool) {
        guard on != form.allDay else { return }
        if on {
            var endDate = form.endDate
            if form.endMin == 0 && endDate > form.startDate { endDate = CalDate.addingDays(-1, toKey: endDate) }
            if endDate < form.startDate { endDate = form.startDate }
            form.allDay = true
            form.endDate = endDate
            return
        }
        let startMin = form.startMin == 0 ? 9 * 60 : form.startMin
        form.allDay = false
        form.startMin = startMin
        form.endMin = min(startMin + 60, 24 * 60 - 15)
    }

    // MARK: Questions

    private var askBinding: Binding<Bool> {
        Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })
    }

    private var askTitle: String {
        switch ask {
        case .delete: return "Delete this event?"
        case .discard: return "Discard your changes?"
        case .deleteScope: return "Delete which events?"
        case .saveScope: return "Save to which events?"
        case nil: return ""
        }
    }

    private var askMessage: String {
        switch ask {
        case .delete: return "It disappears from the calendar for everyone it was shared with."
        case .discard: return "The edits you made to this event are lost."
        case .deleteScope, .saveScope:
            let name = form.title.trimmingCharacters(in: .whitespaces)
            return "“\(name.isEmpty ? "This event" : name)” repeats. Choose how far the change reaches."
        case nil: return ""
        }
    }

    @ViewBuilder
    private var askButtons: some View {
        switch ask {
        case .delete:
            // Named, never tinted: the button says what it does rather than turning red.
            Button("Delete") { ask = nil; Task { await performDelete(scope: nil) } }
            Button("Keep it", role: .cancel) { ask = nil }
        case .discard:
            Button("Discard") { ask = nil; dismiss() }
            Button("Keep editing", role: .cancel) { ask = nil }
        case .deleteScope:
            ForEach(EventScope.allCases, id: \.self) { scope in
                Button(scope.title) { ask = nil; Task { await performDelete(scope: scope) } }
            }
            Button("Cancel", role: .cancel) { ask = nil }
        case .saveScope:
            ForEach(EventScope.allCases, id: \.self) { scope in
                Button(scope.title) { ask = nil; Task { await performSave(scope: scope) } }
            }
            Button("Cancel", role: .cancel) { ask = nil }
        case nil:
            EmptyView()
        }
    }

    // MARK: Writes

    private func requestClose() {
        if dirty && !readOnly { ask = .discard } else { dismiss() }
    }

    /// Recurring writes always ask which occurrences they mean, and the answer rides as
    /// `scope`. Not for a Google-expanded series though: those rows carry no RRULE, so there is
    /// nothing to narrow a save to and every scope would mean the same thing. Editing one edits
    /// that occurrence, which is what Google itself does with an instance. Deleting still asks —
    /// a delete can reach the siblings by id even without a rule tying them together.
    /// `EventSheet.tsx:545-556`.
    private func requestSave() {
        guard !readOnly, !busy else { return }
        if let event, event.recurring, !event.series { ask = .saveScope }
        else { Task { await performSave(scope: nil) } }
    }

    private func performSave(scope: EventScope?) async {
        error = nil
        guard !form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Give the event a title."
            return
        }
        guard !form.calendarID.isEmpty else {
            error = "Pick a calendar to put this on."
            return
        }
        busy = true
        defer { busy = false }
        // The zone the times mean. The owner's setting when there is one, because that is what
        // the desk client stamps its events with; the phone's own otherwise.
        let timezone = store.prefs.timezone.isEmpty ? TimeZone.current.identifier : store.prefs.timezone
        let input = form.input(timezone: timezone)
        do {
            if let event {
                _ = try await CalendarAPI.updateEvent(id: event.id, scope: scope, input: input)
            } else {
                _ = try await CalendarAPI.createEvent(input)
            }
            Haptics.success()
            CalendarBus.shared.changed()
            dismiss()
        } catch {
            self.error = message(error, fallback: "Couldn't save this event.")
        }
    }

    private func performDelete(scope: EventScope?) async {
        guard let event else { return }
        error = nil
        busy = true
        defer { busy = false }
        do {
            try await CalendarAPI.deleteEvent(id: event.id, scope: scope)
            Haptics.success()
            CalendarBus.shared.changed()
            dismiss()
        } catch {
            self.error = message(error, fallback: "Couldn't delete this event.")
        }
    }

    /// Open the copy straight away: you duplicate something in order to change it.
    private func duplicate(_ event: CalEventFull) async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            let copy = try await CalendarAPI.duplicateEvent(id: event.id)
            CalendarBus.shared.changed()
            let next = EventForm(.edit(copy), defaultCalendar: store.defaultCalendarID)
            self.event = copy
            form = next
            baseline = next
        } catch {
            self.error = message(error, fallback: "Couldn't duplicate that.")
        }
    }

    private func answerRSVP(_ event: CalEventFull, _ answer: CalRsvp) async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            self.event = try await CalendarAPI.rsvp(id: event.id, answer)
            Haptics.select()
            CalendarBus.shared.changed()
        } catch {
            self.error = message(error, fallback: "Couldn't send that reply.")
        }
    }

    private func toggleDone(_ event: CalEventFull) async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            // A repeating todo is ticked off for one day, so the occurrence has to be named.
            self.event = try await CalendarAPI.setDone(id: event.id, done: !event.done, date: event.occurrenceDate)
            Haptics.success()
            CalendarBus.shared.changed()
        } catch {
            self.error = message(error, fallback: "Couldn't change that.")
        }
    }

    private func exportICS(_ event: CalEventFull) async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            // Fetched rather than linked: the download needs the session cookie, and the file
            // is then handed to the system share sheet rather than saved anywhere of our own.
            shareFile = ShareFile(url: try await CalendarAPI.exportICS(id: event.id, title: event.title))
        } catch {
            self.error = message(error, fallback: "Couldn't export that event.")
        }
    }

    private func message(_ error: Error, fallback: String) -> String {
        if error is CancellationError { return fallback }
        return (error as? APIError)?.errorDescription ?? fallback
    }
}

// MARK: - Small parts

/// One labelled row of the editor: a 96pt caption column and the control beside it, which is
/// the same shape `EventSheet`'s `Row` draws on the web.
private struct EditorRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .frame(width: 88, alignment: .leading)
                .padding(.top, 12)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .hairline(.bottom)
    }
}

/// A menu that looks like a field rather than a link: bordered, left-aligned, 44pt tall.
private struct MenuField<Content: View>: View {
    let title: String
    var enabled: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                Text(title.isEmpty ? "—" : title)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.Metrics.minTouchTarget)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
    }
}

/// One reminder: an amount, a unit, and a way to take it off again.
private struct ReminderRow: View {
    @Binding var minutes: Int
    let readOnly: Bool
    let remove: () -> Void

    @State private var amount: String = ""
    @State private var unit: ReminderUnit = .minutes

    var body: some View {
        HStack(spacing: 8) {
            TextField("0", text: $amount)
                .font(Theme.Typography.small)
                .monospacedDigit()
                .keyboardType(.numberPad)
                .frame(width: 52, height: Theme.Metrics.minTouchTarget)
                .padding(.horizontal, 8)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                }
                .disabled(readOnly)
                .accessibilityLabel("Reminder amount")
                .onChange(of: amount) { _, value in write(value, unit) }

            MenuField(title: unit.rawValue, enabled: !readOnly) {
                ForEach(ReminderUnit.allCases, id: \.self) { option in
                    Button(option.rawValue) {
                        unit = option
                        write(amount, option)
                    }
                }
            }
            .frame(width: 116)

            Text("before")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)

            Spacer(minLength: 0)

            if !readOnly {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove reminder")
            }
        }
        .onAppear {
            let split = ReminderUnit.split(minutes)
            amount = String(split.amount)
            unit = split.unit
        }
    }

    private func write(_ text: String, _ unit: ReminderUnit) {
        // The worker caps a reminder at four weeks; anything past that is clamped here rather
        // than rejected at the far end of a save the user has already committed to.
        let n = max(0, min(Int(text.filter(\.isNumber)) ?? 0, 40320))
        minutes = min(n * unit.scale, 40320)
    }
}

/// The same set the web offers. `EventSheet.tsx:296`.
private struct EmojiPicker: View {
    let selected: String
    let pick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private static let choices = ["📅", "🎉", "🎂", "✈️", "🍽️", "☕️", "🏃", "💼", "📞", "🎬", "🩺", "🏖️",
                                  "💪", "📚", "🎓", "🎵", "🛠️", "❤️", "⭐️", "🔥", "🧘", "🚗", "🏡", "💡"]

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Emoji") {
                Button("Close") { dismiss() }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .padding(.horizontal, 8)
            } trailing: {
                if selected.isEmpty {
                    EmptyView()
                } else {
                    Button("Remove") { pick(""); dismiss() }
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.foreground)
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .padding(.horizontal, 8)
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                    ForEach(Self.choices, id: \.self) { emoji in
                        Button {
                            pick(emoji)
                            dismiss()
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .frame(height: Theme.Metrics.minTouchTarget)
                                .frame(maxWidth: .infinity)
                                .background {
                                    if emoji == selected {
                                        RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                            .fill(Theme.Colors.muted)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(emoji)
                    }
                }
                .padding(Theme.Metrics.hPadding)
            }
        }
        .screenBackground()
    }
}

/// A file on its way to the share sheet. An `.ics` is something the OS knows what to do with —
/// add it to Apple Calendar, mail it on — so it is handed over rather than rendered here.
struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}


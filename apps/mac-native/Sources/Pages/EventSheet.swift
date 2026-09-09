import SwiftUI
import AppKit

// `src/web/calendar/EventSheet.tsx`, ported literally: the calendar's one editor, in the
// right-hand sheet. Every helper above the view mirrors the function of the same name there.

// MARK: - Time

private let STEP = 15
private let DAY_MIN = 24 * 60
/// Every 15-minute slot of a day, as minutes past local midnight.
private let SLOTS: [Int] = Array(stride(from: 0, to: DAY_MIN, by: STEP))

// MARK: - Repeat

private enum RepeatKind: String, CaseIterable { case never, daily, weekdays, weekly, biweekly, monthly, yearly, custom }
private enum RepeatEnd: String, CaseIterable { case never, until, count }

private let REPEAT_KINDS: [RepeatKind] = [.daily, .weekdays, .weekly, .biweekly, .monthly, .yearly]
private let BYDAY = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

private enum Rrule {
    static func ordinal(_ n: Int) -> String {
        let rest = n % 100
        if rest >= 11 && rest <= 13 { return "\(n)th" }
        let suffix = ["th", "st", "nd", "rd"]
        return "\(n)\(n % 10 < suffix.count ? suffix[n % 10] : "th")"
    }

    private static let weekdayName: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("EEEE"); return f
    }()

    /// The rule body for one of the cases HEY offers, anchored on the event's start day.
    static func baseRule(_ kind: RepeatKind, _ startKey: String, _ cal: Calendar) -> String {
        let d = CalDate.date(fromKey: startKey, in: cal) ?? Date()
        let weekday = cal.component(.weekday, from: d) - 1
        let day = cal.component(.day, from: d)
        switch kind {
        case .daily: return "FREQ=DAILY"
        case .weekdays: return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .weekly: return "FREQ=WEEKLY;BYDAY=\(BYDAY[weekday])"
        case .biweekly: return "FREQ=WEEKLY;INTERVAL=2;BYDAY=\(BYDAY[weekday])"
        case .monthly: return "FREQ=MONTHLY;BYMONTHDAY=\(day)"
        default: return "FREQ=YEARLY"
        }
    }

    static func label(_ kind: RepeatKind, _ startKey: String, _ cal: Calendar) -> String {
        let d = CalDate.date(fromKey: startKey, in: cal) ?? Date()
        switch kind {
        case .never: return "Does not repeat"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly: return "Weekly on \(weekdayName.string(from: d))"
        case .biweekly: return "Every two weeks"
        case .monthly: return "Monthly on the \(ordinal(cal.component(.day, from: d)))"
        case .yearly: return "Every year"
        case .custom: return "Custom…"
        }
    }

    private static func dropPrefix(_ rrule: String) -> String {
        rrule.range(of: "^RRULE:", options: [.regularExpression, .caseInsensitive]).map { String(rrule[$0.upperBound...]) } ?? rrule
    }

    /// `FREQ=DAILY;COUNT=5` → `[FREQ: DAILY, COUNT: 5]`, upper-cased, `RRULE:` prefix tolerated.
    static func parts(_ rrule: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in dropPrefix(rrule).split(separator: ";") {
            guard let i = part.firstIndex(of: "=") else { continue }
            out[part[..<i].trimmingCharacters(in: .whitespaces).uppercased()] = part[part.index(after: i)...].trimmingCharacters(in: .whitespaces).uppercased()
        }
        return out
    }

    /// The rule without its ending clause — the ending lives in its own controls.
    static func stripEnd(_ rrule: String) -> String {
        dropPrefix(rrule).split(separator: ";").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.range(of: "^(UNTIL|COUNT)\\s*=", options: [.regularExpression, .caseInsensitive]) == nil }
            .joined(separator: ";")
    }

    /// A comparable form of a rule body: parts sorted, `INTERVAL=1` dropped, `BYDAY` order
    /// ignored, `WKST` ignored — so Google's `FREQ=WEEKLY;BYDAY=MO;WKST=SU` matches ours.
    static func canon(_ rrule: String) -> String {
        var m = parts(stripEnd(rrule))
        m["WKST"] = nil
        if m["INTERVAL"] == "1" { m["INTERVAL"] = nil }
        if let byday = m["BYDAY"] { m["BYDAY"] = byday.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.sorted().joined(separator: ",") }
        return m.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    /// `UNTIL` is an instant written in UTC; read back through the local clock so "ends on the
    /// 5th" still says the 5th after a round trip.
    static func untilKey(_ raw: String, _ cal: Calendar) -> String {
        guard let re = try? NSRegularExpression(pattern: "^(\\d{4})(\\d{2})(\\d{2})(?:T(\\d{2})(\\d{2})(\\d{2})(Z)?)?$"),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return CalDate.key(Date(), in: cal) }
        func g(_ i: Int) -> String? { let r = m.range(at: i); return r.location == NSNotFound ? nil : String(raw[Range(r, in: raw)!]) }
        if g(7) != nil {
            var c = DateComponents()
            c.year = Int(g(1)!); c.month = Int(g(2)!); c.day = Int(g(3)!); c.hour = Int(g(4)!); c.minute = Int(g(5)!); c.second = Int(g(6)!)
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
            return CalDate.key(utc.date(from: c) ?? Date(), in: cal)
        }
        return "\(g(1)!)-\(g(2)!)-\(g(3)!)"
    }

    /// The last minute of `key` in local time, as a UTC stamp: `20260905T225900Z`.
    static func untilStamp(_ key: String, _ cal: Calendar) -> String {
        let d = Date(timeIntervalSince1970: CalDate.ms(key, minutes: DAY_MIN - 1, in: cal) / 1000)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    struct Parsed { var repeat_: RepeatKind; var rruleText: String; var repeatEnd: RepeatEnd; var until: String; var count: Int }

    /// Recognise a stored RRULE as one of the offered cases; anything unknown is "custom" with
    /// the rule intact, so nothing is silently rewritten on a save that never touched it.
    static func parse(_ rrule: String?, _ startKey: String, _ cal: Calendar) -> Parsed {
        let blank = Parsed(repeat_: .never, rruleText: "", repeatEnd: .never, until: startKey, count: 10)
        guard let rrule, !rrule.trimmingCharacters(in: .whitespaces).isEmpty else { return blank }
        let p = parts(rrule)
        let untilRaw = p["UNTIL"], countRaw = p["COUNT"]
        let repeatEnd: RepeatEnd = untilRaw != nil ? .until : countRaw != nil ? .count : .never
        let until = untilRaw.map { untilKey($0, cal) } ?? startKey
        let count = countRaw.map { max(1, Int($0) ?? 1) } ?? 10
        let body = canon(rrule)
        for kind in REPEAT_KINDS where canon(baseRule(kind, startKey, cal)) == body {
            return Parsed(repeat_: kind, rruleText: "", repeatEnd: repeatEnd, until: until, count: count)
        }
        return Parsed(repeat_: .custom, rruleText: stripEnd(rrule), repeatEnd: repeatEnd, until: until, count: count)
    }
}

// MARK: - Reminders

private enum ReminderUnit: String, CaseIterable {
    case minutes, hours, days
    var factor: Int { switch self { case .minutes: return 1; case .hours: return 60; case .days: return 1440 } }
}

/// 120 → "2 hours"; 45 → "45 minutes". The biggest unit that divides evenly wins.
private func splitReminder(_ minutes: Int) -> (n: Int, unit: ReminderUnit) {
    if minutes > 0 && minutes % 1440 == 0 { return (minutes / 1440, .days) }
    if minutes > 0 && minutes % 60 == 0 { return (minutes / 60, .hours) }
    return (minutes, .minutes)
}

// MARK: - Form

/// An attendee as the form holds it: `AddressInput` speaks `Address`, but a guest also carries an
/// RSVP that must not be thrown away on edit.
private struct Guest: Equatable {
    var email: String
    var name: String
    var rsvp: CalRsvp = .none
    var optional = false
    var organizer = false

    var payload: [String: Any] {
        var d: [String: Any] = ["email": email, "name": name]
        if rsvp != .none { d["rsvp"] = rsvp.rawValue }
        if optional { d["optional"] = true }
        if organizer { d["organizer"] = true }
        return d
    }
}

private struct EventForm: Equatable {
    var calendarID = ""
    var title = ""
    var emoji = ""
    var allDay = false
    var startDate = ""
    /// Minutes past local midnight. Ignored while `allDay`.
    var startMin = 0
    /// While `allDay` this is the *inclusive* last day; otherwise the day the event stops on.
    var endDate = ""
    var endMin = 0
    var repeat_: RepeatKind = .never
    var rruleText = ""
    var repeatEnd: RepeatEnd = .never
    var until = ""
    var count = 10
    var location = ""
    var description = ""
    var guests: [Guest] = []
    var url = ""
    var reminders: [Int] = []
    var countdown = false
    var circled = false
}

private let RSVP_LABEL: [CalRsvp: String] = [.accepted: "Yes", .declined: "No", .tentative: "Maybe", .needsAction: "No reply"]

// MARK: - Sheet

/// `EventSheet`: the event editor in the right-hand sheet.
struct EventSheet: View {
    let store: CalendarStore
    let target: MacEventTarget
    var draft: EventDraft? = nil

    @Environment(SheetState.self) private var sheet
    @Environment(DialogState.self) private var dialogs
    @Environment(PopLayerState.self) private var pops
    @Environment(Router.self) private var router
    @Environment(AppState.self) private var app
    @State private var form = EventForm()
    /// The form as it was opened. Anything different from this is an unsaved change.
    @State private var baseline = EventForm()
    @State private var seeded = false
    @State private var busy = false
    @State private var rsvpBusy = false
    @State private var doneBusy = false
    @State private var error: String?
    /// The event as last returned by the worker, so RSVP and done answers redraw at once.
    @State private var current: CalEventFull?
    @State private var keyMonitor: Any?
    @FocusState private var titleFocused: Bool

    private var cal: Calendar { store.calendar }
    private var ev: CalEventFull? { current ?? { if case .edit(let e) = target { return e }; return nil }() }
    private var calendarRow: CalSource? { store.calendars.first { $0.id == form.calendarID } }
    /// An ICS subscription is a mirror of somebody else's calendar: readable, never writable.
    private var readOnly: Bool { (ev.map { !$0.writable } ?? false) || (calendarRow.map { !$0.writable } ?? false) }
    private var dirty: Bool { form != baseline }
    private var writableCalendars: [CalSource] { store.writableCalendars(including: form.calendarID) }

    private var mine: Set<String> {
        var s: Set<String> = []
        if let e = app.user?.email { s.insert(e.lowercased()) }
        for a in app.accounts { s.insert(a.email.lowercased()) }
        return s
    }
    private var myInvite: CalAttendee? { ev?.attendees.first { mine.contains($0.email.lowercased()) } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleRow
                    row("All day") {
                        HStack(spacing: 8) {
                            WSwitch(on: Binding(get: { form.allDay }, set: { setAllDay($0) })).disabled(readOnly).opacity(readOnly ? 0.5 : 1)
                            Text(form.allDay ? "Takes the whole day" : "Has a start and an end").font(W.s13).foregroundStyle(W.mutedForeground)
                        }
                        .frame(height: 28)
                    }
                    row("Starts", icon: "calendarDays") {
                        HStack(spacing: 6) {
                            DateField(id: "ev-start-date", value: form.startDate, disabled: readOnly) { moveStart(date: $0) }
                            if !form.allDay { TimeField(id: "ev-start-time", day: form.startDate, minutes: form.startMin, disabled: readOnly) { moveStart(min: $0) } }
                        }
                    }
                    row("Ends") {
                        HStack(spacing: 6) {
                            DateField(id: "ev-end-date", value: form.endDate, disabled: readOnly) { moveEnd(date: $0) }
                            if !form.allDay { TimeField(id: "ev-end-time", day: form.endDate, minutes: form.endMin, disabled: readOnly) { moveEnd(min: $0) } }
                        }
                    }
                    row("Repeat", icon: "repeat") { repeatField }
                    row("Location", icon: "mapPin") {
                        WTextField(placeholder: "Somewhere, or a room", text: $form.location, height: 28).disabled(readOnly).opacity(readOnly ? 0.5 : 1)
                    }
                    row("Calendar") { calendarField }
                    row("Notes") {
                        WTextArea(placeholder: "Anything worth remembering", text: $form.description, minHeight: 64, fontSize: 13).disabled(readOnly).opacity(readOnly ? 0.5 : 1)
                    }
                    guestsRow
                    row("Link", icon: "link2") {
                        WTextField(placeholder: "https://", text: $form.url, height: 28).disabled(readOnly).opacity(readOnly ? 0.5 : 1)
                    }
                    row("Reminders", icon: "bell") { remindersField }
                    row("Extras") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { WSwitch(on: $form.countdown).disabled(readOnly).opacity(readOnly ? 0.5 : 1); Text("Show a countdown").font(W.s13).foregroundStyle(W.mutedForeground) }
                            HStack(spacing: 8) { WSwitch(on: $form.circled).disabled(readOnly).opacity(readOnly ? 0.5 : 1); Text("Circle this day").font(W.s13).foregroundStyle(W.mutedForeground) }
                        }
                        .padding(.top, 2)
                    }
                    if readOnly {
                        HStack(alignment: .top, spacing: 8) {
                            Icon("lock", size: 14).foregroundStyle(W.tertiary).padding(.top, 2)
                            Text("This comes from a subscribed calendar\(calendarRow.map { " (\($0.name))" } ?? "") and can't be edited here.")
                                .font(W.s13).foregroundStyle(W.mutedForeground).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 12)
                    }
                    if let e = ev { extras(e) }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            footer
        }
        .onAppear {
            if !seeded { seed(); seeded = true }
            // The call site presents the sheet; its width and close rule are the editor's own
            // (`maxWidth: 540`, `requestClose` in EventSheet.tsx).
            sheet.width = 540
            sheet.onRequestClose = { requestClose() }
            installKeys()
            if case .create = target { DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { titleFocused = true } }
        }
        .onDisappear { removeKeys() }
        // The calendar list can arrive after mount; filling the blank must not make the form dirty.
        .onChange(of: store.calendars) { _, list in
            guard form.calendarID.isEmpty, !list.isEmpty else { return }
            let id = store.defaultCalendarID
            guard !id.isEmpty else { return }
            form.calendarID = id
            baseline = form
        }
    }

    // MARK: Rows

    /// `Row`: `w-24` label with an optional 14pt tertiary icon, `border-b`, `py-2`.
    private func row<Content: View>(_ label: String, icon: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 14).foregroundStyle(W.tertiary) }
                Text(label).font(W.s13).foregroundStyle(W.mutedForeground)
            }
            .frame(width: 96, alignment: .leading)
            .padding(.top, 6)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .edgeLine(.bottom)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            EmojiButton(value: $form.emoji, disabled: readOnly)
            TextField("Untitled event", text: $form.title)
                .textFieldStyle(.plain)
                .font(W.font(16, 600)).tracking(-0.16)
                .foregroundStyle(W.foreground)
                .focused($titleFocused)
                .disabled(readOnly)
                .opacity(readOnly ? 0.7 : 1)
        }
        .padding(.vertical, 8)
        .edgeLine(.bottom)
    }

    private var repeatField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectTrigger(id: "ev-repeat", label: Rrule.label(form.repeat_, form.startDate, cal), maxWidth: 256, disabled: readOnly) {
                PopCard(width: 256) {
                    ForEach([RepeatKind.never] + REPEAT_KINDS + [.custom], id: \.self) { k in
                        SelectRow(Rrule.label(k, form.startDate, cal), checked: form.repeat_ == k) { form.repeat_ = k }
                    }
                }
            }
            if form.repeat_ == .custom {
                WTextField(placeholder: "FREQ=WEEKLY;INTERVAL=3;BYDAY=TU,TH", text: $form.rruleText, mono: true, height: 28, fontSize: 12).disabled(readOnly).opacity(readOnly ? 0.5 : 1)
                Text("An iCalendar RRULE, without the ending — that's set below.").font(W.xs).foregroundStyle(W.tertiary)
            }
            if form.repeat_ != .never {
                HStack(spacing: 6) {
                    SelectTrigger(id: "ev-repeat-end", label: endLabel(form.repeatEnd), width: 144, disabled: readOnly) {
                        PopCard(width: 144) {
                            ForEach(RepeatEnd.allCases, id: \.self) { e in SelectRow(endLabel(e), checked: form.repeatEnd == e) { form.repeatEnd = e } }
                        }
                    }
                    if form.repeatEnd == .until { DateField(id: "ev-until", value: form.until, disabled: readOnly) { form.until = $0 } }
                    if form.repeatEnd == .count {
                        HStack(spacing: 6) {
                            NumberField(value: Binding(get: { form.count }, set: { form.count = max(1, min(999, $0)) }), width: 64).disabled(readOnly).opacity(readOnly ? 0.5 : 1)
                            Text("times").font(W.s13).foregroundStyle(W.mutedForeground)
                        }
                    }
                }
            }
        }
    }

    private func endLabel(_ e: RepeatEnd) -> String {
        switch e { case .never: return "Ends never"; case .until: return "Ends on…"; case .count: return "Ends after…" }
    }

    private var calendarField: some View {
        SelectTrigger(id: "ev-cal", label: calendarRow?.name ?? "Pick a calendar", placeholder: calendarRow == nil, dot: calendarRow.map { Color(hex: $0.color) }, maxWidth: 256, disabled: readOnly) {
            PopCard(width: 256) {
                ForEach(writableCalendars) { c in
                    SelectRow(c.name, checked: form.calendarID == c.id, dot: c.color.isEmpty ? W.foreground : Color(hex: c.color)) { form.calendarID = c.id }
                }
            }
        }
    }

    private var guestsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            AddressInput(label: "Guests", value: guestAddresses, placeholder: readOnly ? "" : "Invite people…") { EmptyView() }
                .disabled(readOnly)
            let replied = form.guests.filter { $0.rsvp != .none && $0.rsvp != .needsAction }
            if !replied.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(replied, id: \.email) { g in
                        HStack(spacing: 6) {
                            Text(g.name.isEmpty ? g.email : g.name).font(W.xs).foregroundStyle(W.mutedForeground).truncate()
                            Text("· \(RSVP_LABEL[g.rsvp] ?? g.rsvp.rawValue)").font(W.xs).foregroundStyle(W.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4).padding(.leading, 68)
            }
        }
        .padding(.vertical, 4)
        .edgeLine(.bottom)
    }

    /// `AddressInput` speaks `Address`; a guest that was already on the event keeps its RSVP.
    private var guestAddresses: Binding<[Address]> {
        Binding(
            get: { form.guests.map { Address(email: $0.email, name: $0.name) } },
            set: { next in
                form.guests = next.map { a in
                    if var had = form.guests.first(where: { $0.email.lowercased() == a.email.lowercased() }) {
                        if !a.name.isEmpty { had.name = a.name }
                        return had
                    }
                    return Guest(email: a.email, name: a.name)
                }
            }
        )
    }

    private var remindersField: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(form.reminders.enumerated()), id: \.offset) { i, minutes in
                let split = splitReminder(minutes)
                HStack(spacing: 6) {
                    NumberField(value: Binding(get: { split.n }, set: { writeReminder(i, max(0, $0), split.unit) }), width: 64).disabled(readOnly).opacity(readOnly ? 0.5 : 1)
                    SelectTrigger(id: "ev-rem-unit-\(i)", label: split.unit.rawValue, width: 112, disabled: readOnly) {
                        PopCard(width: 144) {
                            ForEach(ReminderUnit.allCases, id: \.self) { u in SelectRow(u.rawValue, checked: split.unit == u) { writeReminder(i, split.n, u) } }
                        }
                    }
                    Text("before").font(W.s13).foregroundStyle(W.mutedForeground)
                    if !readOnly {
                        WButton(icon: "x", variant: .ghost, size: .iconXs, muted: true, help: "Remove reminder") { form.reminders.remove(at: i) }
                    }
                }
            }
            if !readOnly {
                WButton("Add a reminder", icon: "plus", variant: .ghost, size: .xs, muted: true) { form.reminders.append(10) }
            }
            if form.reminders.isEmpty && readOnly { Text("None").font(W.s13).foregroundStyle(W.tertiary) }
        }
    }

    private func writeReminder(_ i: Int, _ n: Int, _ unit: ReminderUnit) {
        guard form.reminders.indices.contains(i) else { return }
        form.reminders[i] = n * unit.factor
    }

    /// The block under the fields for an existing event: RSVP, Join, done, the thread, `.ics`, meta.
    private func extras(_ e: CalEventFull) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if myInvite != nil {
                HStack(spacing: 6) {
                    Text("Going?").font(W.s13).foregroundStyle(W.mutedForeground)
                    ForEach([CalRsvp.accepted, .tentative, .declined], id: \.self) { r in
                        WButton(RSVP_LABEL[r] ?? "", icon: e.rsvp == r ? "check" : nil, variant: e.rsvp == r ? .secondary : .outline, size: .sm) { answer(e, r) }
                            .disabled(rsvpBusy)
                    }
                }
            }
            HStack(spacing: 6) {
                if !e.conferenceURL.isEmpty, let url = URL(string: e.conferenceURL) {
                    // Native shells never navigate away from the server: hand the link to the OS.
                    WButton("Join", icon: "video", variant: .outline, size: .sm) { NSWorkspace.shared.open(url) }
                }
                if e.isTodo && !readOnly {
                    WButton(e.done ? "Mark not done" : "Mark done", icon: "check", variant: .outline, size: .sm) { toggleDone(e) }.disabled(doneBusy)
                }
                if let tid = e.threadID, !tid.isEmpty {
                    WButton("The email this came from", icon: "mail", variant: .outline, size: .sm) { sheet.dismiss(); router.go(.thread(tid, peek: false)) }
                }
                WButton("Download .ics", icon: "download", variant: .ghost, size: .sm, muted: true) { downloadICS(e) }
            }
            Text(meta(e)).font(W.xs).foregroundStyle(W.tertiary)
        }
        .padding(.top, 16)
    }

    private static let metaDate: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("d MMM yyyy"); return f
    }()

    private func meta(_ e: CalEventFull) -> String {
        var s = e.calendarName
        if e.createdAt > 0 { s += " · added \(Self.metaDate.string(from: Date(timeIntervalSince1970: e.createdAt / 1000)))" }
        if e.updatedAt > 0 && e.updatedAt != e.createdAt { s += " · edited \(Self.metaDate.string(from: Date(timeIntervalSince1970: e.updatedAt / 1000)))" }
        return s
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let e = ev, !readOnly {
                WButton(icon: "trash2", variant: .ghost, size: .iconSm, muted: true, help: "Delete event") { requestDelete(e) }.disabled(busy)
                WButton(icon: "copyPlus", variant: .ghost, size: .iconSm, muted: true, help: "Duplicate") { duplicate(e) }.disabled(busy)
            }
            if let error {
                Text(error).font(W.s13).foregroundStyle(W.foreground).truncate().frame(maxWidth: .infinity, alignment: .leading).help(error)
            } else {
                Spacer()
            }
            WButton(readOnly ? "Close" : "Cancel", variant: .ghost) { requestClose() }.disabled(busy)
            if !readOnly {
                WButton(ev == nil ? "Create" : "Save", help: "Save (⌘↵)") { requestSave() }.disabled(busy)
            }
        }
        .padding(12).edgeLine(.top)
    }

    // MARK: Times

    private func msAt(_ key: String, _ minutes: Int) -> Double { CalDate.ms(key, minutes: minutes, in: cal) }
    private func dateKey(_ ms: Double) -> String { CalDate.key(Date(timeIntervalSince1970: ms / 1000), in: cal) }
    private func minutesOfDay(_ ms: Double) -> Int { CalDate.minutesOfDay(ms, in: cal) }
    private func addDays(_ key: String, _ n: Int) -> String { CalDate.addingDays(n, toKey: key, in: cal) }
    private func daysBetween(_ a: String, _ b: String) -> Int {
        guard let da = CalDate.date(fromKey: a, in: cal), let db = CalDate.date(fromKey: b, in: cal) else { return 0 }
        return cal.dateComponents([.day], from: cal.startOfDay(for: da), to: cal.startOfDay(for: db)).day ?? 0
    }

    /// Moving the start drags the end along, keeping the duration, the way every calendar does.
    private func moveStart(date: String? = nil, min: Int? = nil) {
        var f = form
        let startDate = date ?? f.startDate
        if f.allDay {
            let span = Swift.max(0, daysBetween(f.startDate, f.endDate))
            f.startDate = startDate; f.endDate = addDays(startDate, span)
            form = f; return
        }
        let startMin = min ?? f.startMin
        let keep = Swift.max(0, msAt(f.endDate, f.endMin) - msAt(f.startDate, f.startMin))
        let end = msAt(startDate, startMin) + keep
        f.startDate = startDate; f.startMin = startMin; f.endDate = dateKey(end); f.endMin = minutesOfDay(end)
        form = f
    }

    /// An end before the start is corrected, not rejected: it snaps to the first legal slot.
    private func moveEnd(date: String? = nil, min: Int? = nil) {
        var f = form
        if f.allDay {
            let endDate = date ?? f.endDate
            f.endDate = endDate < f.startDate ? f.startDate : endDate
            form = f; return
        }
        let start = msAt(f.startDate, f.startMin)
        var end = msAt(date ?? f.endDate, min ?? f.endMin)
        if end <= start { end = start + Double(STEP) * 60_000 }
        f.endDate = dateKey(end); f.endMin = minutesOfDay(end)
        form = f
    }

    /// All-day and timed are two different shapes, so the toggle converts. Timed → all-day: an
    /// event that stops at midnight belongs to the day before. All-day → timed: 9:00 for an hour.
    private func setAllDay(_ on: Bool) {
        var f = form
        guard on != f.allDay else { return }
        if on {
            var endDate = f.endDate
            if f.endMin == 0 && endDate > f.startDate { endDate = addDays(endDate, -1) }
            if endDate < f.startDate { endDate = f.startDate }
            f.allDay = true; f.endDate = endDate
        } else {
            let startMin = f.startMin == 0 ? 9 * 60 : f.startMin
            f.allDay = false; f.startMin = startMin; f.endMin = Swift.min(startMin + 60, DAY_MIN - STEP)
        }
        form = f
    }

    // MARK: Seeding and the body a write sends

    /// `makeForm`: all-day rows carry their own inclusive dates; timed rows only carry instants.
    private func seed() {
        var f = EventForm()
        var allDay = false
        var starts = Date().timeIntervalSince1970 * 1000
        var ends: Double? = nil
        var startDateRaw: String? = nil, endDateRaw: String? = nil
        var rrule: String? = nil
        switch target {
        case .create(let day, let from, let to, let isAllDay):
            allDay = isAllDay
            starts = msAt(day, from); ends = msAt(day, to)
            f.calendarID = store.defaultCalendarID
            if let draft {
                f.title = draft.title; f.description = draft.description
                starts = draft.startsAt; ends = draft.endsAt
                f.guests = draft.attendees.map { Guest(email: $0.email, name: $0.name) }
            }
        case .edit(let e):
            allDay = e.allDay; starts = e.startsAt; ends = e.endsAt
            startDateRaw = e.startDate; endDateRaw = e.endDate; rrule = e.rrule
            f.calendarID = e.calendarID; f.title = e.title; f.emoji = e.emoji
            f.location = e.location; f.description = e.description; f.url = e.url
            f.guests = e.attendees.map { Guest(email: $0.email, name: $0.name, rsvp: $0.rsvp, optional: $0.optional, organizer: $0.organizer) }
            f.reminders = e.reminders.map(\.minutes)
            f.countdown = e.countdown; f.circled = e.circled
        }
        let endsAt = ends ?? starts + 60 * 60_000
        f.allDay = allDay
        f.startDate = (allDay ? startDateRaw : nil) ?? dateKey(starts)
        f.endDate = allDay ? (endDateRaw ?? f.startDate) : dateKey(endsAt)
        f.startMin = minutesOfDay(starts)
        f.endMin = allDay ? Swift.min(f.startMin + 60, DAY_MIN - STEP) : minutesOfDay(endsAt)
        let r = Rrule.parse(rrule, f.startDate, cal)
        f.repeat_ = r.repeat_; f.rruleText = r.rruleText; f.repeatEnd = r.repeatEnd; f.until = r.until; f.count = r.count
        form = f
        baseline = f
    }

    private func buildRrule() -> String? {
        let f = form
        if f.repeat_ == .never { return nil }
        var rule = f.repeat_ == .custom ? Rrule.stripEnd(f.rruleText) : Rrule.baseRule(f.repeat_, f.startDate, cal)
        if rule.isEmpty { return nil }
        if f.repeatEnd == .until && !f.until.isEmpty { rule += ";UNTIL=\(Rrule.untilStamp(f.until, cal))" }
        else if f.repeatEnd == .count { rule += ";COUNT=\(Swift.max(1, Swift.min(f.count == 0 ? 1 : f.count, 999)))" }
        return rule
    }

    /// `toInput`: every field, every time.
    private func toInput() -> EventInput {
        let f = form
        var input = EventInput()
        input.calendarID = f.calendarID
        input.title = f.title.trimmingCharacters(in: .whitespaces)
        input.description = f.description
        input.location = f.location.trimmingCharacters(in: .whitespaces)
        input.emoji = f.emoji
        input.rrule = .some(buildRrule())
        input.attendees = f.guests.map(\.payload)
        input.url = f.url.trimmingCharacters(in: .whitespaces)
        input.reminders = f.reminders
        input.countdown = f.countdown
        input.circled = f.circled
        input.timezone = store.prefs.timezone.isEmpty ? TimeZone.current.identifier : store.prefs.timezone
        input.allDay = f.allDay
        if f.allDay {
            // `end_date` is inclusive, so the instant the day *stops* is midnight of the day after it.
            input.startDate = .some(f.startDate); input.endDate = .some(f.endDate)
            input.startsAt = msAt(f.startDate, 0); input.endsAt = msAt(addDays(f.endDate, 1), 0)
        } else {
            input.startDate = .some(nil); input.endDate = .some(nil)
            input.startsAt = msAt(f.startDate, f.startMin); input.endsAt = msAt(f.endDate, f.endMin)
        }
        return input
    }

    // MARK: Mutations

    private func doSave(scope: EventScope?) async {
        error = nil
        if form.title.trimmingCharacters(in: .whitespaces).isEmpty { error = "Give the event a title."; titleFocused = true; return }
        if form.calendarID.isEmpty { error = "Pick a calendar to put this on."; return }
        busy = true; defer { busy = false }
        let body = toInput()
        do {
            if let e = ev { _ = try await CalendarAPI.updateEvent(id: e.id, scope: scope, input: body) } else { _ = try await CalendarAPI.createEvent(body) }
            CalendarBus.shared.changed()
            sheet.dismiss()
        } catch {
            // A failed save stays on screen next to the button — a toast would take the reason with it.
            self.error = (error as? APIError)?.errorDescription ?? "Couldn't save this event."
        }
    }

    private func doDelete(_ e: CalEventFull, scope: EventScope?) async {
        error = nil
        busy = true; defer { busy = false }
        do { try await CalendarAPI.deleteEvent(id: e.id, scope: scope); CalendarBus.shared.changed(); sheet.dismiss() }
        catch { self.error = (error as? APIError)?.errorDescription ?? "Couldn't delete this event." }
    }

    /// Recurring writes ask which occurrences they mean. Not a Google-expanded series though:
    /// those rows carry no RRULE, so every scope would mean the same thing. Deleting still asks.
    private func requestSave() {
        guard !readOnly, !busy else { return }
        if let e = ev, e.recurring, !e.series { askScope(delete: false) { scope in Task { await doSave(scope: scope) } } }
        else { Task { await doSave(scope: nil) } }
    }

    private func requestDelete(_ e: CalEventFull) {
        guard !readOnly, !busy else { return }
        if e.recurring { askScope(delete: true) { scope in Task { await doDelete(e, scope: scope) } } }
        else {
            dialogs.confirm(title: "Delete this event?", description: "It disappears from the calendar for everyone it was shared with.", cancel: "Keep it", action: "Delete") {
                Task { await doDelete(e, scope: nil) }
            }
        }
    }

    private func requestClose() {
        if dirty && !readOnly {
            dialogs.confirm(title: "Discard your changes?", description: "The edits you made to this event are lost.", cancel: "Keep editing", action: "Discard") { sheet.dismiss() }
        } else {
            sheet.dismiss()
        }
    }

    private func askScope(delete: Bool, then: @escaping (EventScope) -> Void) {
        let id = "event-scope"
        let name = form.title.trimmingCharacters(in: .whitespaces)
        dialogs.present(id) {
            VStack(alignment: .leading, spacing: 8) {
                Text(delete ? "Delete which events?" : "Save to which events?").font(W.font(16, 500)).webLine(16, weight: 500).foregroundStyle(W.foreground)
                Text("“\(name.isEmpty ? "This event" : name)” repeats. Choose how far the change reaches.")
                    .font(W.sm).foregroundStyle(W.mutedForeground).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    ForEach(EventScope.allCases, id: \.self) { scope in
                        WButton(scope.title, variant: .outline, fullWidth: true) { dialogs.dismiss(id); then(scope) }
                    }
                }
                .padding(.top, 8)
                HStack { Spacer(); WButton("Cancel", variant: .outline) { dialogs.dismiss(id) } }.padding(.top, 8)
            }
            .padding(16)
        }
    }

    private func answer(_ e: CalEventFull, _ r: CalRsvp) {
        guard !rsvpBusy else { return }
        rsvpBusy = true
        Task {
            defer { rsvpBusy = false }
            do { current = try await CalendarAPI.rsvp(id: e.id, r); CalendarBus.shared.changed() }
            catch { self.error = (error as? APIError)?.errorDescription ?? "Couldn't send your reply." }
        }
    }

    private func toggleDone(_ e: CalEventFull) {
        guard !doneBusy else { return }
        doneBusy = true
        Task {
            defer { doneBusy = false }
            do { current = try await CalendarAPI.setDone(id: e.id, done: !e.done, date: e.occurrenceDate); CalendarBus.shared.changed() }
            catch { self.error = (error as? APIError)?.errorDescription ?? "Couldn't change that." }
        }
    }

    /// Open the copy straight away: you duplicate something in order to change it.
    private func duplicate(_ e: CalEventFull) {
        error = nil
        Task {
            do {
                let copy = try await CalendarAPI.duplicateEvent(id: e.id)
                CalendarBus.shared.changed()
                let store = store
                sheet.present(title: "Event", width: 540) { EventSheet(store: store, target: .edit(copy)) }
            } catch { self.error = (error as? APIError)?.errorDescription ?? "Couldn't duplicate that." }
        }
    }

    /// `<a download>`: the file is fetched with the session cookie, then saved where the person says.
    private func downloadICS(_ e: CalEventFull) {
        Task {
            do {
                let tmp = try await CalendarAPI.exportICS(id: e.id, title: e.title)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = tmp.lastPathComponent
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let dest = panel.url else { return }
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: tmp, to: dest)
            } catch { self.error = (error as? APIError)?.errorDescription ?? "Couldn't download the .ics." }
        }
    }

    // MARK: ⌘↵

    /// ⌘/Ctrl + Enter saves from anywhere in the sheet. `KeyBus` hands ⌘ keys to the menu bar,
    /// so the sheet listens on its own while it is up.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 36 || event.keyCode == 76 else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.command) || mods.contains(.control) else { return event }
            guard !DialogState.shared.isOpen else { return event }
            requestSave()
            return nil
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Small parts

private let EMOJI = ["📅", "🎉", "🎂", "✈️", "🍽️", "☕️", "🏃", "💼", "📞", "🎬", "🩺", "🏖️", "💪", "📚", "🎓", "🎵", "🛠️", "❤️", "⭐️", "🔥", "🧘", "🚗", "🏡", "💡"]

/// `EmojiButton`: a ghost icon button; the popover is an 8-wide grid, then Remove.
private struct EmojiButton: View {
    @Binding var value: String
    var disabled = false
    @Environment(PopLayerState.self) private var pops
    private let id = "ev-emoji"

    var body: some View {
        Button {
            pops.toggle(id, side: .bottom, align: .start) {
                PopCard(width: 256, padding: 6) {
                    VStack(spacing: 4) {
                        let cols = Array(repeating: GridItem(.fixed(28), spacing: 2), count: 8)
                        LazyVGrid(columns: cols, spacing: 2) {
                            ForEach(EMOJI, id: \.self) { e in
                                EmojiCell(emoji: e) { value = e; pops.close(id) }
                            }
                        }
                        if !value.isEmpty {
                            WButton("Remove", variant: .ghost, size: .xs, muted: true, fullWidth: true) { value = ""; pops.close(id) }
                        }
                    }
                }
            }
        } label: {
            Group {
                if value.isEmpty { Icon("smile", size: 16) } else { Text(value).font(.system(size: 15)) }
            }
        }
        .buttonStyle(.web(.ghost, .iconSm, muted: true, expanded: pops.isOpen(id)))
        .help("Emoji")
        .disabled(disabled)
        .popAnchor(id)
    }
}

private struct EmojiCell: View {
    let emoji: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(emoji).font(.system(size: 15)).frame(width: 28, height: 28)
                .background(hovering ? W.muted : Color.clear).rounded(W.radiusMd).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// shadcn `SelectTrigger size="sm"`: h-7, rounded-md, `border-input`, pl-2.5 pr-2, text-sm, chevron.
private struct SelectTrigger<Content: View>: View {
    let id: String
    let label: String
    var placeholder = false
    var dot: Color? = nil
    var width: CGFloat? = nil
    var maxWidth: CGFloat? = nil
    var disabled = false
    @ViewBuilder var content: () -> Content
    @Environment(PopLayerState.self) private var pops

    var body: some View {
        Button {
            pops.toggle(id, side: .bottom, align: .start, content: content)
        } label: {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(label).font(W.sm).foregroundStyle(placeholder ? W.mutedForeground : W.foreground).truncate()
                Spacer(minLength: 0)
                Icon("chevronDown", size: 16).foregroundStyle(W.mutedForeground)
            }
            .padding(.leading, 10).padding(.trailing, 8)
            .frame(height: 28)
            .frame(width: width)
            .frame(maxWidth: maxWidth ?? (width == nil ? CGFloat.infinity : nil))
            .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.input, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .popAnchor(id)
    }
}

/// shadcn `SelectItem`: 28pt, rounded-md, pl-1.5 pr-8, text-sm, the tick on the right.
private struct SelectRow: View {
    let label: String
    var checked = false
    var dot: Color? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(PopLayerState.self) private var pops

    init(_ label: String, checked: Bool = false, dot: Color? = nil, action: @escaping () -> Void) {
        self.label = label; self.checked = checked; self.dot = dot; self.action = action
    }

    var body: some View {
        Button {
            pops.closeAll()
            action()
        } label: {
            HStack(spacing: 8) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(label).font(W.sm).foregroundStyle(W.foreground).truncate()
                Spacer(minLength: 8)
                Icon("check", size: 16).opacity(checked ? 1 : 0)
            }
            .padding(.leading, 6).padding(.trailing, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? W.accent : Color.clear)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The date half of a start/end row — the same calendar the rest of the app picks dates with.
private struct DateField: View {
    let id: String
    let value: String
    var disabled = false
    let onChange: (String) -> Void
    @Environment(PopLayerState.self) private var pops

    var body: some View {
        let date = CalDate.date(fromKey: value) ?? Date()
        Button {
            pops.toggle(id, side: .bottom, align: .start) {
                PopCard(width: nil) {
                    DateFieldPop(initial: date) { picked in onChange(CalDate.key(picked)); pops.close(id) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Icon("calendarDays", size: 14).foregroundStyle(W.mutedForeground)
                Text(CalDate.shortDayLabel(date)).monospacedDigit()
            }
            .font(W.font(12.8))   // `font-normal`
        }
        .buttonStyle(.web(.outline, .sm))
        .help(CalDate.dayLabel(date))
        .disabled(disabled)
        .popAnchor(id)
    }
}

private struct DateFieldPop: View {
    let initial: Date
    let onPick: (Date) -> Void
    @State private var month: Date
    @State private var selected: Date

    init(initial: Date, onPick: @escaping (Date) -> Void) {
        self.initial = initial; self.onPick = onPick
        _month = State(initialValue: initial); _selected = State(initialValue: initial)
    }

    var body: some View {
        MiniCalendar(month: $month, selected: $selected)
            .padding(4)
            .onChange(of: selected) { _, d in onPick(d) }
    }
}

/// Plain 15-minute select. An off-grid time (a synced 09:07 meeting) keeps its own slot.
private struct TimeField: View {
    let id: String
    let day: String
    let minutes: Int
    var disabled = false
    let onChange: (Int) -> Void
    @Environment(PopLayerState.self) private var pops

    private var options: [Int] { SLOTS.contains(minutes) ? SLOTS : (SLOTS + [minutes]).sorted() }
    private var dayDate: Date { CalDate.date(fromKey: day) ?? Date() }

    var body: some View {
        SelectTrigger(id: id, label: CalDate.time(minutes: minutes, on: dayDate), width: 112, disabled: disabled) {
            PopCard(width: 144) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(options, id: \.self) { m in
                                SelectRow(CalDate.time(minutes: m, on: dayDate), checked: m == minutes) { onChange(m) }.id(m)
                            }
                        }
                    }
                    .frame(height: 288)
                    .onAppear { proxy.scrollTo(minutes, anchor: .center) }
                }
            }
        }
    }
}

/// `<Input type="number">` at `h-7`, digits kept tabular.
private struct NumberField: View {
    @Binding var value: Int
    var width: CGFloat = 64
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(W.sm).monospacedDigit()
            .foregroundStyle(W.foreground)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(focused ? W.background : W.input)
            .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(focused ? W.ring : Color.clear, lineWidth: 1))
            .rounded(W.radiusMd)
            .onAppear { text = String(value) }
            .onChange(of: value) { _, v in if Int(text) != v { text = String(v) } }
            .onChange(of: text) { _, t in
                let digits = t.filter(\.isNumber)
                if digits != t { text = digits; return }
                let n = Int(digits) ?? 0
                if n != value { value = n }
            }
            .onChange(of: focused) { _, f in if !f { text = String(value) } }
    }
}

import Foundation
import Observation

// MARK: - Date arithmetic

/// Every date calculation the calendar makes, in one place.
///
/// Two calendars are in play and it matters which is which. The worker speaks
/// `YYYY-MM-DD` in the proleptic Gregorian calendar, so grid and key maths run on an
/// explicitly Gregorian `Calendar` — a device set to the Buddhist or Japanese calendar
/// would otherwise send the worker a year it has never heard of. Everything the user can
/// *see* still comes from their own locale: the weekday and month names come from
/// `Locale.current`, while the first day of the week and the 12/24-hour clock come from the
/// owner's calendar preferences when the server has told us what they are, and from the
/// device only until then.
enum CalDate {
    /// The owner's preferences, as last read from `GET /api/calendar/settings`.
    ///
    /// A mutable global rather than something threaded through every call site, because the
    /// alternative is passing a `CalPrefs` into `key`, `monthGrid` and `time` — forty call
    /// sites, all of which would be passing the same value. It is written once per launch by
    /// `CalendarStore.loadPrefs()` and read everywhere; views observe the copy the store keeps
    /// so that a late answer still redraws the grid.
    nonisolated(unsafe) static var prefs: CalPrefs = .deviceDefaults

    /// Gregorian for the maths, wearing the user's timezone and the owner's first weekday.
    ///
    /// The timezone stays the *device's*, not `prefs.timezone`: the phone is where the person
    /// actually is, and a meeting belongs to the day they see on their own clock. The setting
    /// is used when writing an event, where the worker needs to know the zone the times mean.
    static var cal: Calendar { calendar(prefs) }

    static func calendar(_ prefs: CalPrefs) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        let current = Calendar.current
        c.timeZone = current.timeZone
        c.locale = current.locale ?? .current
        // `week_start` is 0-based from Sunday; `Calendar.firstWeekday` is 1-based. A negative
        // value means the preferences have not landed yet, so the device keeps its own answer.
        c.firstWeekday = prefs.weekStart >= 0 ? (prefs.weekStart % 7) + 1 : current.firstWeekday
        return c
    }

    // MARK: Keys

    /// The `YYYY-MM-DD` the API indexes days by. Built from components rather than a
    /// `DateFormatter` so a timezone change mid-session cannot leave a stale formatter behind.
    static func key(_ date: Date, in cal: Calendar = CalDate.cal) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func monthKey(_ date: Date, in cal: Calendar = CalDate.cal) -> String {
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func date(fromKey key: String, in cal: Calendar = CalDate.cal) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return cal.date(from: DateComponents(year: y, month: m, day: d))
    }

    static var todayKey: String { key(Date()) }

    /// The instant `minutes` past local midnight on `key`, in epoch milliseconds — the worker's
    /// unit. `msAt` in `src/web/lib/caldate.ts`.
    static func ms(_ key: String, minutes: Int, in cal: Calendar = CalDate.cal) -> Double {
        guard let day = date(fromKey: key, in: cal) else { return 0 }
        return day.timeIntervalSince1970 * 1000 + Double(minutes) * 60_000
    }

    static func ms(_ day: Date, minutes: Int, in cal: Calendar = CalDate.cal) -> Double {
        cal.startOfDay(for: day).timeIntervalSince1970 * 1000 + Double(minutes) * 60_000
    }

    /// Minutes past local midnight of an epoch-millisecond instant.
    static func minutesOfDay(_ millis: Double, in cal: Calendar = CalDate.cal) -> Int {
        let date = Date(timeIntervalSince1970: millis / 1000)
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: Stepping

    static func startOfMonth(_ date: Date, in cal: Calendar = CalDate.cal) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    static func addingDays(_ days: Int, to date: Date, in cal: Calendar = CalDate.cal) -> Date {
        cal.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// The same, on a `YYYY-MM-DD` key.
    static func addingDays(_ days: Int, toKey key: String, in cal: Calendar = CalDate.cal) -> String {
        guard let day = date(fromKey: key, in: cal) else { return key }
        return CalDate.key(addingDays(days, to: day, in: cal), in: cal)
    }

    /// Steps a month while keeping the day of the month where it exists, so walking from
    /// 31 January lands on 28 February and not on 3 March.
    static func addingMonths(_ months: Int, to date: Date, in cal: Calendar = CalDate.cal) -> Date {
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        guard let shifted = cal.date(byAdding: .month, value: months, to: startOfMonth(date, in: cal)),
              let range = cal.range(of: .day, in: .month, for: shifted) else { return date }
        var target = cal.dateComponents([.year, .month], from: shifted)
        target.day = min(parts.day ?? 1, range.count)
        return cal.date(from: target) ?? date
    }

    /// The 42 cells of a month view: six full weeks starting on the user's first weekday,
    /// which is what keeps the grid a constant height as the months change under it.
    static func monthGrid(for month: Date, in cal: Calendar = CalDate.cal) -> [Date] {
        let first = startOfMonth(month, in: cal)
        var lead = cal.component(.weekday, from: first) - cal.firstWeekday
        if lead < 0 { lead += 7 }
        let start = addingDays(-lead, to: first, in: cal)
        return (0..<42).map { addingDays($0, to: start, in: cal) }
    }

    // MARK: Display

    /// Weekday initials in the user's own order, taken from the locale's standalone names
    /// so they read correctly in languages where the abbreviated form is inflected.
    static func weekdaySymbols(in cal: Calendar = CalDate.cal) -> [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let offset = cal.firstWeekday - 1
        return (0..<7).map { symbols[($0 + offset) % 7] }
    }

    private static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()

    private static let shortDayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        return f
    }()

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    /// The owner's clock.
    ///
    /// `time_format` is the one preference a phone can get visibly wrong: somebody who chose
    /// 24-hour in the browser should not be reading "9:30 PM" here. Rather than hard-code
    /// `HH:mm` — which would also hard-code Western digits onto a Persian or Arabic locale —
    /// the *hour cycle* is overridden on the user's own locale and the rest of the formatting
    /// is left to it. The same locale is handed to every `DatePicker` in the editor, so the
    /// wheels agree with the labels.
    static var clockLocale: Locale {
        let base = Locale.current
        guard prefs.timeFormat == "12" || prefs.timeFormat == "24" else { return base }
        var components = Locale.Components(locale: base)
        components.hourCycle = prefs.timeFormat == "24" ? .zeroToTwentyThree : .oneToTwelve
        return Locale(components: components)
    }

    /// One cached formatter, rebuilt only when the preference behind it changes. An agenda
    /// draws dozens of stamps a frame and `DateFormatter` construction is not cheap.
    private nonisolated(unsafe) static var clockCache: (key: String, formatter: DateFormatter)?

    private static var clock: DateFormatter {
        let key = prefs.timeFormat
        if let cached = clockCache, cached.key == key { return cached.formatter }
        let f = DateFormatter()
        f.locale = clockLocale
        f.setLocalizedDateFormatFromTemplate("jm")   // 09:30 or 9:30 AM, per the cycle above
        clockCache = (key, f)
        return f
    }

    static func monthLabel(_ date: Date) -> String { monthTitle.string(from: date) }
    static func dayLabel(_ date: Date) -> String { dayTitle.string(from: date) }
    static func shortDayLabel(_ date: Date) -> String { shortDayTitle.string(from: date) }
    /// Spoken form, for the day cells' accessibility labels.
    static func spokenDate(_ date: Date) -> String { fullDate.string(from: date) }

    static func time(_ date: Date) -> String { clock.string(from: date) }

    static func time(minutes: Int, on day: Date) -> String {
        time(Date(timeIntervalSince1970: ms(day, minutes: minutes) / 1000))
    }

    /// The hour ticks down the day timeline: "09" on a 24-hour clock, "9am" on a 12-hour one.
    static func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        if is24Hour { return String(format: "%02d", h) }
        let display = h % 12 == 0 ? 12 : h % 12
        return "\(display)\(h < 12 ? "am" : "pm")"
    }

    /// Whether the clock above ended up with an am/pm marker, which is what the hour ticks
    /// down the timeline have to agree with.
    static var is24Hour: Bool { !(clock.dateFormat ?? "").contains("a") }

    /// "09:30 – 10:30", the stamp a timeline block carries.
    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    /// "Today" / "Tomorrow" / "Yesterday", or nothing when the day is far enough away that
    /// the date itself is the clearer label.
    static func relativeDay(_ date: Date, in cal: Calendar = CalDate.cal) -> String? {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return nil
    }
}

// MARK: - Store

/// The loaded slice of the calendar, indexed by day.
///
/// The endpoint is a range query, so the store's unit is a month-sized window and the cache
/// key is the month it was fetched for. Paging back and forth over months already seen is
/// then free — the whole point of caching here, since a month step is a swipe and a swipe is
/// cheap enough that a user will do it a dozen times in a row. Windows overlap by a week at
/// each end (the grid's leading and trailing days belong to the neighbouring months), so the
/// day index de-duplicates by event id rather than trusting the windows to be disjoint.
@MainActor
@Observable
final class CalendarStore {

    /// A day's events, already split the way the grid and the agenda both want them.
    struct DayEvents {
        var allDay: [CalEventFull] = []
        var timed: [CalEventFull] = []

        var isEmpty: Bool { allDay.isEmpty && timed.isEmpty }
        var count: Int { allDay.count + timed.count }
        var ordered: [CalEventFull] { allDay + timed }
    }

    /// Day key → what happens that day.
    private(set) var index: [String: DayEvents] = [:]
    /// Day keys that carry a journal entry, so the grid can mark them.
    private(set) var journalDays: Set<String> = []
    /// True only while the month actually on screen is in flight, so a background prefetch
    /// of the next month never puts a spinner over content that is already drawn.
    private(set) var loading = false
    private(set) var error: String?
    /// The owner's preferences. Views read this rather than `CalDate.prefs` so that the answer
    /// landing after the first paint actually redraws the grid.
    private(set) var prefs: CalPrefs = CalDate.prefs
    /// The calendars an event can be filed on, for the editor's picker.
    private(set) var calendars: [CalSource] = []
    private var prefsLoaded = false

    /// Month key → the events its window returned.
    private var windows: [String: [CalEventFull]] = [:]
    /// Month key → the days its window described.
    private var dayRows: [String: [CalDay]] = [:]
    /// Month keys in use order; the oldest are dropped so a long session cannot grow forever.
    private var recent: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Roughly a year either side of wherever the user settled. Beyond that a refetch is
    /// cheaper than the memory.
    private let keepMonths = 9
    /// Days of slack either side of the 42-cell grid, so a month that starts on the first
    /// weekday still carries context for the row above and below it.
    private let padDays = 7


    var calendar: Calendar { CalDate.calendar(prefs) }

    // MARK: Reading

    func events(on day: Date) -> DayEvents {
        index[CalDate.key(day, in: calendar)] ?? DayEvents()
    }

    func events(onKey key: String) -> DayEvents {
        index[key] ?? DayEvents()
    }

    func isLoaded(month: Date) -> Bool {
        windows[CalDate.monthKey(month, in: calendar)] != nil
    }

    /// The calendars an event can actually be written to, plus whichever one it is already on
    /// so an event living on a read-only calendar still names it.
    func writableCalendars(including current: String) -> [CalSource] {
        calendars.filter { $0.writable || $0.id == current }
    }

    var defaultCalendarID: String {
        let writable = calendars.filter(\.writable)
        return (writable.first(where: \.isDefault) ?? writable.first)?.id ?? ""
    }

    // MARK: Preferences

    /// Reads the owner's preferences and the calendar list once, seeding both from disk so a
    /// relaunch does not draw a Sunday-start month for somebody who chose Monday and then
    /// reshuffle it a second later. Once per store, because `.task` runs again on every
    /// re-appearance and neither answer changes while the app is open.
    func loadPrefs() async {
        guard !prefsLoaded else { return }
        prefsLoaded = true
        if let cached = ContentCache.shared.value(CalPrefs.self, for: .calendarSettings) {
            apply(cached)
        }
        if let cached = ContentCache.shared.value([CalSource].self, for: .calendarSources) {
            calendars = cached
        }
        if let fresh = try? await CalendarAPI.settings() {
            apply(fresh)
            ContentCache.shared.store(fresh, for: .calendarSettings)
        }
        if let list = try? await CalendarAPI.sources() {
            calendars = list
            ContentCache.shared.store(list, for: .calendarSources)
        }
    }

    private func apply(_ next: CalPrefs) {
        let declinedChanged = next.showDeclined != prefs.showDeclined
        prefs = next
        CalDate.prefs = next
        // `show_declined` is enforced server-side, but a window cached from before the setting
        // was changed still holds the declined rows it was sent; rebuilding drops them.
        if declinedChanged { rebuild() }
    }

    // MARK: Loading

    /// Loads the month if it is not already held, then quietly warms the two months either
    /// side so the next swipe lands on content instead of on a spinner.
    func ensure(month: Date) async {
        await load(month: month, force: false, visible: true)
        let cal = calendar
        for step in [-1, 1] {
            let neighbour = CalDate.addingMonths(step, to: CalDate.startOfMonth(month, in: cal), in: cal)
            guard windows[CalDate.monthKey(neighbour, in: cal)] == nil else { continue }
            Task { [weak self] in await self?.load(month: neighbour, force: false, visible: false) }
        }
    }

    /// Pull to refresh: the visible month and its neighbours are dropped and fetched again.
    /// Everything else in the cache stays, because it is still as fresh as it ever was.
    func refresh(month: Date) async {
        let cal = calendar
        let base = CalDate.startOfMonth(month, in: cal)
        for step in [-1, 0, 1] {
            let key = CalDate.monthKey(CalDate.addingMonths(step, to: base, in: cal), in: cal)
            tasks[key]?.cancel()
            tasks[key] = nil
            windows[key] = nil
        }
        rebuild()
        await load(month: month, force: true, visible: true)
        for step in [-1, 1] {
            let neighbour = CalDate.addingMonths(step, to: base, in: cal)
            Task { [weak self] in await self?.load(month: neighbour, force: false, visible: false) }
        }
    }

    /// After a write. Everything held is thrown away rather than only the month on screen: a
    /// `scope=all` edit reaches occurrences in months this store is still holding, and a stale
    /// December is worse than a refetched one.
    func invalidate(around month: Date) async {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        windows.removeAll()
        dayRows.removeAll()
        recent.removeAll()
        await load(month: month, force: true, visible: true)
        rebuild()
    }

    private func load(month: Date, force: Bool, visible: Bool) async {
        let cal = calendar
        let key = CalDate.monthKey(month, in: cal)

        if !force, windows[key] != nil {
            // Re-reading a cached month can still push the oldest one out of the cache,
            // which means the day index is now describing days nothing holds any more.
            if touch(key) { rebuild() }
            return
        }
        if let existing = tasks[key] {
            await existing.value
            return
        }

        // The disk layer under the in-memory window. The month cache above is per-session
        // and a swipe back to March after a relaunch would otherwise land on a spinner, so
        // last time's answer for this month is drawn while the range query runs. It is a
        // seed, never the answer: the request below still goes out and overwrites it.
        if !force, windows[key] == nil,
           let cached = ContentCache.shared.value([CalEventFull].self, for: .calendarMonth(key)) {
            windows[key] = cached
            touch(key)
            rebuild()
        }

        let grid = CalDate.monthGrid(for: month, in: cal)
        guard let first = grid.first, let last = grid.last else { return }
        let from = CalDate.key(CalDate.addingDays(-padDays, to: first, in: cal), in: cal)
        let to = CalDate.key(CalDate.addingDays(padDays, to: last, in: cal), in: cal)

        if visible { loading = true }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let range = try await CalendarAPI.range(from: from, to: to)
                guard !Task.isCancelled else { return }
                self.windows[key] = range.events
                self.dayRows[key] = range.days
                ContentCache.shared.store(range.events, for: .calendarMonth(key))
                self.touch(key)
                self.rebuild()
                self.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A failed prefetch is silent: the user never asked for that month, and a
                // banner about a month they cannot see is noise.
                if visible {
                    self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        tasks[key] = task
        await task.value
        if tasks[key] == task { tasks[key] = nil }
        if visible { loading = false }
    }

    // MARK: Indexing

    /// Marks a month as most recently used. Returns true when that pushed another month out,
    /// which is the only case where the day index has to be built again.
    @discardableResult
    private func touch(_ key: String) -> Bool {
        recent.removeAll { $0 == key }
        recent.append(key)
        var evicted = false
        while recent.count > keepMonths {
            let dropped = recent.removeFirst()
            windows[dropped] = nil
            dayRows[dropped] = nil
            evicted = true
        }
        return evicted
    }

    /// One pass over everything held, bucketed by day, so drawing a cell is a dictionary hit.
    private func rebuild() {
        let cal = calendar
        var next: [String: DayEvents] = [:]
        var seen: [String: Set<String>] = [:]

        for events in windows.values {
            for event in events {
                // The worker already filters declined events out of a range unless the owner
                // asked to see them; this catches a window cached before that setting changed.
                if event.isDeclined && !prefs.showDeclined { continue }
                for day in days(for: event, cal: cal) {
                    if seen[day, default: []].contains(event.id) { continue }
                    seen[day, default: []].insert(event.id)
                    if event.allDay {
                        next[day, default: DayEvents()].allDay.append(event)
                    } else {
                        next[day, default: DayEvents()].timed.append(event)
                    }
                }
            }
        }

        for key in Array(next.keys) {
            // All-day items read as a header for the day, so they keep a stable alphabetical
            // order; timed items are the day itself and go in clock order.
            next[key]?.allDay.sort { ($0.title, $0.id) < ($1.title, $1.id) }
            next[key]?.timed.sort { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
        }
        index = next

        var written: Set<String> = []
        for rows in dayRows.values {
            for row in rows where row.hasJournal { written.insert(row.date) }
        }
        journalDays = written
    }

    /// Every day key an event should appear under. A multi-day trip belongs on all of its
    /// days, and a meeting that runs past midnight belongs on both sides of it.
    private func days(for event: CalEventFull, cal: Calendar) -> [String] {
        // All-day items are date-string data, not instants. Deriving the first day from
        // `start_date` but the last from `ends_at` mixed two frames of reference — a UTC
        // midnight read through the device's timezone — so a three-day trip drew as two days
        // west of UTC and four east of it. Both ends now come from the strings, and no
        // timezone enters the span at all.
        if event.allDay, let raw = event.startDate, let startDay = CalDate.date(fromKey: raw, in: cal) {
            // `end_date` is the INCLUSIVE last day from every source the worker writes:
            // heyflare's own rows keep what the client sent (src/worker/calendar/store.ts),
            // the ICS importer converts DTEND — which *is* exclusive — back a day
            // (src/worker/calendar/ical.ts), and the Google importer likewise stores
            // `shiftDate(exclusiveEnd, -1)` while keeping the exclusive midnight only in
            // `ends_at` (src/worker/calendar/google.ts). So no per-source branch is needed;
            // one is what would break Google multi-day events by dropping their last day.
            let endDay = event.endDate.flatMap { CalDate.date(fromKey: $0, in: cal) } ?? startDay
            // Missing `end_date` means a single day. Falling back to the epoch here is what
            // caused the bug in the first place, and a lone day is the honest reading.
            let raw = cal.dateComponents([.day], from: startDay, to: endDay).day ?? 0
            let span = min(max(raw, 0), 400)
            return (0...span).map { CalDate.key(CalDate.addingDays($0, to: startDay, in: cal), in: cal) }
        }

        // Timed events are instants, and the device's timezone is exactly the right frame for
        // them: a meeting belongs to the day the user sees on the clock.
        let startDay = cal.startOfDay(for: event.start)
        // The end instant is exclusive, so a 09:00–10:00 meeting must not spill into the next
        // day when it happens to end at midnight.
        let endMillis = max(event.endsAt - 1, event.startsAt)
        let endDay = cal.startOfDay(for: Date(timeIntervalSince1970: endMillis / 1000))
        let raw = cal.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        let span = min(max(raw, 0), 14)

        return (0...span).map { CalDate.key(CalDate.addingDays($0, to: startDay, in: cal), in: cal) }
    }
}

// MARK: - Grayscale identity

extension CalEventFull {
    /// The gray step a calendar's events are drawn at.
    ///
    /// The desktop uses the calendar's own colour here, and `calendar_color` is on the wire,
    /// but this app is grayscale end to end and a single hue would be the only one on the
    /// phone. So the colour is read and ignored: identity is carried by a stable gray step
    /// derived from the *calendar id* — not from the hex, so recolouring a calendar in Google
    /// does not reshuffle the phone — and by shape, since an all-day item is a bar, a timed
    /// one a dot, and a todo a hollow circle. The same stable-hash trick the image cache uses.
    var calendarTone: Double {
        var hash: UInt64 = 5381
        for byte in calendarID.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return [1.0, 0.62, 0.34][Int(hash % 3)]
    }

    /// What the title reads as, emoji included, with the web's placeholder for an untitled one.
    var displayTitle: String {
        let name = title.isEmpty ? "(no title)" : title
        return emoji.isEmpty ? name : "\(emoji) \(name)"
    }
}

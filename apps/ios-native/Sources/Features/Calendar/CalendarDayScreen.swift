import SwiftUI
import PhotosUI

// One day, full screen — the route the phone web client has at `/calendar/:date`
// (`src/web/mobile/MobileDay.tsx`) and native did not have at all.

// MARK: - Geometry

/// The piecewise minute-to-point mapping the timeline is drawn against.
///
/// Two ideas, both taken from `src/web/calendar/scale.ts`. First, the day is *fitted*: the
/// scale covers the hours the day's events actually occupy, padded, so a day that runs
/// 08:00–19:00 fills the screen instead of floating in the middle of a 24-hour chart. Second,
/// what falls outside that window collapses into a thin band you can tap open — so the mapping
/// is piecewise across up to three segments, and every block, rule and now-line reads it from
/// here rather than computing its own.
struct DayScale {
    struct Segment {
        let from: Int
        let to: Int
        let y: CGFloat
        let height: CGFloat
        /// True for the collapsed early/late bands.
        let band: Bool
    }

    /// Nothing shorter than this reads as a block.
    static let minEventHeight: CGFloat = 30
    /// Height of a collapsed band, whole segment.
    static let bandHeight: CGFloat = 30
    /// An hour is drawn this tall. The web fits the scale to the viewport; a phone scrolls
    /// instead, so a fixed rate keeps the same event the same size on every day you open.
    static let pointsPerHour: CGFloat = 56

    let segments: [Segment]
    let height: CGFloat
    let hours: [(hour: Int, y: CGFloat)]

    /// The window worth drawing for a set of events: the span they cover, padded, widened to a
    /// decent working day so an empty calendar still looks like a day, and snapped to hours.
    static func fitWindow(_ events: [CalEventFull]) -> (from: Int, to: Int) {
        var lo = 9 * 60
        var hi = 18 * 60
        for event in events where !event.allDay {
            let s = CalDate.minutesOfDay(event.startsAt)
            let t = CalDate.minutesOfDay(event.endsAt - 1)
            if s < lo { lo = s }
            // An event running past midnight reports a smaller end than start; let it push the
            // day open rather than fold back on itself.
            if t > hi || t < s { hi = t < s ? 1440 : t }
        }
        let from = max(0, ((lo - 45) / 60) * 60)
        let to = min(1440, Int((Double(hi + 45) / 60).rounded(.up)) * 60)
        return (from, max(to, from + 6 * 60))
    }

    init(from: Int, to: Int, collapse: Bool) {
        let lo = collapse ? max(0, min(1380, from)) : 0
        let hi = collapse ? min(1440, max(lo + 60, to)) : 1440
        let perMinute = Self.pointsPerHour / 60

        // 0 → lo → hi → 1440, with any zero-length step dropped: a window that already starts
        // at midnight has no leading band, and one that runs to midnight has no trailing one.
        var bounds: [Int] = []
        for value in [0, lo, hi, 1440] where bounds.isEmpty || value > bounds[bounds.count - 1] {
            bounds.append(value)
        }

        var built: [Segment] = []
        var y: CGFloat = 0
        for i in 0..<(bounds.count - 1) {
            let a = bounds[i]
            let b = bounds[i + 1]
            let band = b <= lo || a >= hi
            let h = band ? Self.bandHeight : CGFloat(b - a) * perMinute
            built.append(Segment(from: a, to: b, y: y, height: h, band: band))
            y += h
        }
        segments = built
        height = y

        // Label only the hours inside the open window; a collapsed band gets one glyph instead.
        var ticks: [(hour: Int, y: CGFloat)] = []
        let first = Int((Double(lo) / 60).rounded(.up))
        var hour = first
        while hour * 60 <= hi {
            ticks.append((hour, Self.offset(of: hour * 60, in: built, height: y)))
            hour += 1
        }
        hours = ticks
    }

    private static func offset(of minutes: Int, in segments: [Segment], height: CGFloat) -> CGFloat {
        let m = max(0, min(1440, minutes))
        for s in segments where m <= s.to {
            return s.y + (CGFloat(m - s.from) / CGFloat(s.to - s.from)) * s.height
        }
        return height
    }

    func y(_ minutes: Int) -> CGFloat { Self.offset(of: minutes, in: segments, height: height) }

    /// The inverse, for press-and-hold to create.
    func minutes(_ point: CGFloat) -> Int {
        let p = max(0, min(height, point))
        for s in segments where p <= s.y + s.height {
            guard s.height > 0 else { continue }
            return s.from + Int((p - s.y) / s.height * CGFloat(s.to - s.from))
        }
        return 1440
    }

    /// Snap a minute to the nearest quarter hour, which is the finest slot the web offers and
    /// the finest a thumb can honestly aim at.
    static func snap(_ minutes: Int, step: Int = 15) -> Int {
        Int((Double(minutes) / Double(step)).rounded()) * step
    }
}

/// Where each overlapping event sits across the width of the timeline.
/// `layoutColumns` in `src/web/lib/caldate.ts`.
func layoutColumns(_ events: [CalEventFull], minimumMillis: Double) -> [(column: Int, columns: Int)] {
    var out = events.map { _ in (column: 0, columns: 1) }
    guard !events.isEmpty else { return out }

    let floorMillis = max(minimumMillis, 0)
    var items = events.enumerated().map { index, event in
        (index: index, start: event.startsAt, end: max(event.endsAt, event.startsAt + floorMillis))
    }
    items.sort { a, b in
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end > b.end }
        return a.index < b.index
    }

    // Members of the cluster currently being built, and when each column last freed up.
    var cluster: [Int] = []
    var columnEnds: [Double] = []
    var clusterEnd = -Double.greatestFiniteMagnitude

    func flush() {
        let n = max(columnEnds.count, 1)
        for index in cluster { out[index].columns = n }
        cluster = []
        columnEnds = []
        clusterEnd = -Double.greatestFiniteMagnitude
    }

    for item in items {
        // Nothing in the open cluster is still running: start a fresh one.
        if item.start >= clusterEnd { flush() }
        if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
            columnEnds[free] = item.end
            out[item.index].column = free
        } else {
            out[item.index].column = columnEnds.count
            columnEnds.append(item.end)
        }
        cluster.append(item.index)
        clusterEnd = max(clusterEnd, item.end)
    }
    flush()
    return out
}

// MARK: - Screen

/// A day in full: the day's label, its habits, its journal, the all-day items banded at the
/// top, then the timeline with everything drawn to scale.
///
/// It holds its own `CalendarStore` rather than sharing the month screen's, because a pushed
/// screen cannot reach the one the tab root made. That is cheap: the window it needs is nearly
/// always already on disk from the month behind it, so this opens on content and corrects it.
/// `CalendarBus` is what keeps the two in step after a write.
struct CalendarDayScreen: View {
    /// A `yyyy-MM-dd` day. The route carries the string rather than a `Date` so a push can be
    /// built from anywhere without agreeing on a timezone first.
    let date: String

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var store = CalendarStore()
    @State private var cursor: String
    @State private var habits: [CalHabit] = []
    @State private var day: CalDay?
    @State private var editing: EventEditorTarget?
    @State private var journalling: JournalDay?
    @State private var nightOpen = false
    @State private var swipeOffset: CGFloat = 0
    @State private var naming = false
    @State private var nameDraft = ""
    @State private var pickingCover = false
    @State private var pickedCover: PhotosPickerItem?
    @State private var uploadingCover = false

    init(date: String) {
        self.date = date
        // The route seeds the cursor; stepping days after that is local state rather than a
        // stack of pushed screens, so walking a week does not leave seven of them behind.
        _cursor = State(initialValue: date)
    }

    private var cal: Calendar { store.calendar }
    private var dayDate: Date { CalDate.date(fromKey: cursor, in: cal) ?? Date() }
    private var events: CalendarStore.DayEvents { store.events(onKey: cursor) }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    cover
                    if let label = day?.label, !label.isEmpty {
                        Button {
                            nameDraft = label
                            naming = true
                        } label: {
                            Text(label)
                                .font(Theme.Typography.bodyMedium)
                                .foregroundStyle(Theme.Colors.foreground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Metrics.hPadding)
                                .padding(.top, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Renames this day")
                    }
                    habitStrip
                    journalRow
                    allDayBand
                    timeline
                    Text("Press and hold the timeline to add an event.")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                }
                .offset(x: swipeOffset)
                // A UIKit pan rather than a `DragGesture` on the scroll view: even as a
                // simultaneous gesture the SwiftUI drag took every touch that moved, and
                // the day could not be scrolled at all.
                .background(HorizontalPan(onChange: dayMoved(to:), onEnd: dayReleased(at:cancelled:)))
            }
            .refreshable {
                try? await CalendarAPI.syncSources()
                await reload(force: true)
            }
        }
        .screenBackground()
        .task(id: cursor) { await reload(force: false) }
        .task { await store.loadPrefs() }
        // Nothing injects `CalendarBus` into the environment — `RootView` is not this feature's
        // to edit — so the shared instance is read directly. Reading `revision` here is still
        // what registers the dependency, which is all observation needs.
        .onChange(of: CalendarBus.shared.revision) { _, _ in
            Task { await reload(force: true) }
        }
        .onChange(of: store.error) { _, message in
            if let message { toasts.error(message) }
        }
        .sheet(item: $editing) { target in
            EventEditor(target: target, store: store)
        }
        .sheet(item: $journalling) { entry in
            JournalEntrySheet(date: entry.date)
        }
        .alert("Name this day", isPresented: $naming) {
            TextField("Trip, birthday, deadline…", text: $nameDraft)
            Button("Save") { Task { await saveLabel(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)) } }
            if day?.label.isEmpty == false {
                Button("Remove name", role: .destructive) { Task { await saveLabel("") } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A short label shown at the top of the day and on the month.")
        }
        .photosPicker(isPresented: $pickingCover, selection: $pickedCover, matching: .images)
        .onChange(of: pickedCover) { _, item in
            guard let item else { return }
            pickedCover = nil
            Task { await setCover(from: item) }
        }
    }

    // MARK: Cover and name

    /// The day's photo, if one was set, the way the web draws it: a short band across the
    /// top, cropped to the position chosen there.
    @ViewBuilder
    private var cover: some View {
        if let url = day?.coverImageURL {
            CoverBand(url: url, position: day?.coverPosition ?? "")
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if uploadingCover {
                        ProgressView().tint(Theme.Colors.foreground).padding(10)
                    }
                }
        } else if uploadingCover {
            HStack(spacing: 8) {
                ProgressView().tint(Theme.Colors.mutedForeground)
                Text("Uploading photo…")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.top, 10)
        }
    }

    private func saveLabel(_ label: String) async {
        do {
            day = try await CalendarAPI.updateDay(cursor, label: label)
            Haptics.select()
            CalendarBus.shared.changed()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Couldn't name this day.")
        }
    }

    /// Downscales on the phone so the worker only ever stores a screen-sized copy, then
    /// attaches the stored photo to the day.
    private func setCover(from item: PhotosPickerItem) async {
        uploadingCover = true
        defer { uploadingCover = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.downscaled(maxPixel: 1600).jpegData(compressionQuality: 0.85) else {
                toasts.error("That photo could not be read.")
                return
            }
            let size = image.downscaled(maxPixel: 1600).size
            let stored = try await CalendarAPI.uploadCover(jpeg, mime: "image/jpeg", width: Int(size.width), height: Int(size.height), name: "day-\(cursor).jpg")
            day = try await CalendarAPI.updateDay(cursor, coverID: .some(stored.id))
            Haptics.success()
            CalendarBus.shared.changed()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Couldn't set that photo.")
        }
    }

    private func removeCover() async {
        do {
            day = try await CalendarAPI.updateDay(cursor, coverID: .some(nil), coverURL: "")
            Haptics.select()
            CalendarBus.shared.changed()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Couldn't remove the photo.")
        }
    }

    // MARK: Chrome

    private var bar: some View {
        TopBar(title: CalDate.dayLabel(dayDate)) {
            BarButton(icon: "chevron.left", label: "Back") { dismiss() }
        } trailing: {
            HStack(spacing: 0) {
                BarButton(icon: "chevron.up", label: "Previous day") { step(-1) }
                BarButton(icon: "chevron.down", label: "Next day") { step(1) }
                BarButton(icon: "plus", label: "New event on \(CalDate.spokenDate(dayDate))") {
                    // A tapped "new" lands at nine, which is where the web's own button puts it.
                    editing = .create(day: cursor, startMinutes: 9 * 60, endMinutes: 10 * 60, allDay: false)
                }
                Menu {
                    Button {
                        nameDraft = day?.label ?? ""
                        naming = true
                    } label: {
                        SwiftUI.Label(day?.label.isEmpty == false ? "Rename this day" : "Name this day", systemImage: "textformat")
                    }
                    Button {
                        pickingCover = true
                    } label: {
                        SwiftUI.Label(day?.coverImageURL == nil ? "Set a photo" : "Change the photo", systemImage: "photo")
                    }
                    if day?.coverImageURL != nil {
                        Button(role: .destructive) {
                            Task { await removeCover() }
                        } label: {
                            SwiftUI.Label("Remove the photo", systemImage: "photo.badge.minus")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.Colors.foreground)
                        .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More")
            }
        }
    }

    /// Days step sideways, the way they do on the web. The threshold is the same 72pt.
    private func dayMoved(to translation: CGFloat) {
        swipeOffset = translation
    }

    private func dayReleased(at translation: CGFloat, cancelled: Bool) {
        if !cancelled, swipeOffset != 0, abs(translation) >= 72 {
            step(translation < 0 ? 1 : -1, haptic: false)
        }
        swipeOffset = 0
    }

    private func step(_ delta: Int, haptic: Bool = true) {
        if haptic { Haptics.select() }
        cursor = CalDate.addingDays(delta, toKey: cursor, in: cal)
    }

    // MARK: Habits

    /// Only the habits actually expected today, which is what makes this a to-do list for the
    /// day rather than a wall of every habit the owner has ever kept.
    private var todaysHabits: [CalHabit] {
        let weekday = cal.component(.weekday, from: dayDate) - 1
        return habits.filter { !$0.archived && $0.expectedDays.contains(weekday) }
    }

    @ViewBuilder
    private var habitStrip: some View {
        if !todaysHabits.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(todaysHabits) { habit in
                        HabitChip(habit: habit, date: cursor) { await toggle(habit) }
                    }
                }
                .padding(.horizontal, Theme.Metrics.hPadding)
            }
            .padding(.top, 12)
        }
    }

    private func toggle(_ habit: CalHabit) async {
        do {
            let updated = try await CalendarAPI.toggleHabit(id: habit.id, date: cursor, from: cursor, to: cursor)
            Haptics.select()
            if let index = habits.firstIndex(where: { $0.id == habit.id }) { habits[index] = updated }
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Couldn't change that habit.")
        }
    }

    // MARK: Journal

    private var journalRow: some View {
        Button {
            journalling = JournalDay(date: cursor)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Journal")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.foreground)
                    if let excerpt = day?.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Text(day?.hasJournal == true ? "Written" : "Empty")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
            .background(Theme.Colors.muted.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 12)
        .accessibilityLabel("Journal for \(CalDate.spokenDate(dayDate)), \(day?.hasJournal == true ? "written" : "empty")")
    }

    // MARK: All-day

    @ViewBuilder
    private var allDayBand: some View {
        if !events.allDay.isEmpty {
            VStack(spacing: 4) {
                ForEach(events.allDay) { event in
                    Button {
                        editing = .edit(event)
                    } label: {
                        HStack(spacing: 8) {
                            if !event.emoji.isEmpty { Text(event.emoji).font(Theme.Typography.small) }
                            Text(event.title.isEmpty ? "(no title)" : event.title)
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.foreground)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("All day")
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.Colors.mutedForeground)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .background(Theme.Colors.muted.opacity(event.isTentative ? 0 : 0.7))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                        .overlay {
                            // A tentative item is an outline rather than a fill: the monochrome
                            // reading of the web's dashed border.
                            if event.isTentative {
                                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                    .strokeBorder(Theme.Colors.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                        }
                        .opacity(event.isDeclined ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(spoken(event, when: "All day"))
                }
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.top, 12)
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        let window = DayScale.fitWindow(events.timed)
        let scale = DayScale(from: window.from, to: window.to,
                             collapse: store.prefs.collapseNight && !nightOpen)
        return DayTimeline(
            scale: scale,
            day: cursor,
            events: events.timed,
            isToday: cal.isDateInToday(dayDate),
            onOpen: { editing = .edit($0) },
            onCreate: { from, to in
                Haptics.threshold()
                editing = .create(day: cursor, startMinutes: from, endMinutes: to, allDay: false)
            },
            onToggleBand: { nightOpen.toggle() }
        )
        .padding(.top, 12)
    }

    private func spoken(_ event: CalEventFull, when: String) -> String {
        var parts = [CalDate.spokenDate(dayDate), when, event.displayTitle]
        if !event.location.isEmpty { parts.append(event.location) }
        if event.isDeclined { parts.append("Declined") }
        if event.isCancelled { parts.append("Cancelled") }
        return parts.joined(separator: ", ")
    }

    // MARK: Loading

    private func reload(force: Bool) async {
        if force { await store.invalidate(around: dayDate) } else { await store.ensure(month: dayDate) }
        // The habits and the day row are day-sized questions, so they are asked directly rather
        // than dug back out of a month-wide range payload.
        async let habitList = try? await CalendarAPI.habits(from: cursor, to: cursor)
        async let dayRow = try? await CalendarAPI.journal(date: cursor)
        habits = await habitList ?? []
        day = await dayRow
    }
}

// MARK: - Habit chip

private struct HabitChip: View {
    let habit: CalHabit
    let date: String
    let toggle: () async -> Void

    private var done: Bool { habit.completions.contains(date) }

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(habit.icon.isEmpty ? String(habit.name.prefix(1)).uppercased() : habit.icon)
                    .font(Theme.Typography.small)
                Text(habit.name)
                    .font(Theme.Typography.small)
                    .lineLimit(1)
                if habit.streak > 0 {
                    Text("\(habit.streak)")
                        .font(Theme.Typography.micro)
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
            .foregroundStyle(done ? Theme.Colors.background : Theme.Colors.mutedForeground)
            .padding(.horizontal, 14)
            .frame(height: Theme.Metrics.minTouchTarget)
            .background {
                Capsule().fill(done ? Theme.Colors.foreground : Color.clear)
            }
            .overlay {
                Capsule().strokeBorder(Theme.Colors.border, lineWidth: done ? 0 : 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(habit.name), \(done ? "done" : "not done")")
        .accessibilityAddTraits(done ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - The timeline itself

/// The hour gutter, the rules, the day's events laid into columns, the now line, and
/// press-and-hold to create.
private struct DayTimeline: View {
    let scale: DayScale
    let day: String
    let events: [CalEventFull]
    let isToday: Bool
    let onOpen: (CalEventFull) -> Void
    let onCreate: (Int, Int) -> Void
    let onToggleBand: () -> Void

    /// How long a finger has to rest before the timeline takes the gesture off the page.
    /// The web uses 400ms (`MobileDay.tsx:20`) and a thumb has no idea which client it is on.
    private static let holdSeconds = 0.4

    @State private var draft: (from: Int, to: Int)?
    @State private var anchor = 0
    /// The last place a finger was seen, in the timeline's own space. A `LongPressGesture`
    /// carries no location, so it is recorded by a simultaneous drag and read when the press
    /// finally fires — the long press is what takes the gesture away from the scroll view,
    /// which a bare drag on a scrollable page cannot do.
    @State private var touch: CGFloat = 0
    @State private var now = Date()

    private static let space = "calendar.timeline"

    private var columns: [(column: Int, columns: Int)] {
        // `minEventHeight` is the shortest a block is drawn; at this scale that is how much
        // time it visually claims, and the columns have to reserve the same.
        layoutColumns(events, minimumMillis: Double(DayScale.minEventHeight / DayScale.pointsPerHour) * 3_600_000)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    bands
                    rules
                    blocks(width: geo.size.width)
                    if let draft { draftBlock(draft) }
                    if isToday { nowLine }
                }
                .frame(width: geo.size.width, height: scale.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .coordinateSpace(name: Self.space)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { touch = $0.location.y }
                )
                .gesture(hold)
            }
            .frame(height: scale.height)
            .hairline(.top)
        }
        .padding(.horizontal, 12)
        // A minute is the finest the now line moves, and redrawing it more often than that
        // would be a timer running for nothing.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var gutter: some View {
        ZStack(alignment: .topLeading) {
            ForEach(scale.hours, id: \.hour) { tick in
                Text(CalDate.hourLabel(tick.hour))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 34, alignment: .trailing)
                    .offset(y: tick.y - 6)
            }
        }
        .frame(width: 40, height: scale.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var bands: some View {
        ForEach(scale.segments.filter(\.band), id: \.from) { segment in
            Button(action: onToggleBand) {
                Rectangle()
                    .fill(Theme.Colors.muted.opacity(0.6))
                    .frame(height: segment.height)
                    .overlay {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(y: segment.y)
            .accessibilityLabel("Expand the collapsed night hours")
        }
    }

    private var rules: some View {
        ForEach(scale.hours, id: \.hour) { tick in
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(height: 1 / UIScreen.main.scale)
                .offset(y: tick.y)
                .allowsHitTesting(false)
        }
    }

    private func blocks(width: CGFloat) -> some View {
        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
            let slot = index < columns.count ? columns[index] : (column: 0, columns: 1)
            let top = scale.y(CalDate.minutesOfDay(max(event.startsAt, CalDate.ms(day, minutes: 0))))
            let bottom = scale.y(CalDate.minutesOfDay(min(event.endsAt, CalDate.ms(day, minutes: 1439))))
            let columnWidth = max(width / CGFloat(slot.columns), 24)
            EventBlock(event: event, height: max(bottom - top, DayScale.minEventHeight), day: day)
                .frame(width: columnWidth - 2, alignment: .topLeading)
                .offset(x: columnWidth * CGFloat(slot.column) + 1, y: top)
                .onTapGesture { onOpen(event) }
        }
    }

    private func draftBlock(_ draft: (from: Int, to: Int)) -> some View {
        let top = scale.y(draft.from)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Theme.Colors.foreground.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .background(Theme.Colors.foreground.opacity(0.05))
            .frame(height: max(scale.y(draft.to) - top, 18))
            .overlay(alignment: .topLeading) {
                Text(CalDate.time(minutes: draft.from, on: CalDate.date(fromKey: day) ?? Date())
                     + " – "
                     + CalDate.time(minutes: draft.to, on: CalDate.date(fromKey: day) ?? Date()))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
            .offset(y: top)
            .allowsHitTesting(false)
    }

    private var nowLine: some View {
        // Every other calendar draws this in red; this app has no colour to spend, so the line
        // is the one full-strength rule on the page and carries a knob at its left end.
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Colors.foreground)
                .frame(height: 1.5)
        }
        .overlay(alignment: .leading) {
            Circle()
                .fill(Theme.Colors.foreground)
                .frame(width: 7, height: 7)
                .offset(x: -3)
        }
        .offset(y: scale.y(CalDate.minutesOfDay(now.timeIntervalSince1970 * 1000)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Press and hold on empty time, then drag to set how long. 400ms, thirty minutes by
    /// default, never shorter than fifteen — `MobileDay.tsx:287-332`.
    private var hold: some Gesture {
        LongPressGesture(minimumDuration: Self.holdSeconds)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                switch value {
                case .first:
                    arm()
                case .second(_, let drag):
                    if draft == nil { arm() }
                    guard let drag else { return }
                    let current = DayScale.snap(scale.minutes(drag.location.y))
                    let a = min(anchor, current)
                    let b = max(anchor, current)
                    draft = (from: a, to: max(b, a + 15))
                }
            }
            .onEnded { _ in
                guard let draft else { return }
                self.draft = nil
                onCreate(draft.from, max(draft.to, draft.from + 15))
            }
    }

    private func arm() {
        guard draft == nil else { return }
        let at = DayScale.snap(scale.minutes(touch))
        anchor = at
        draft = (from: at, to: at + 30)
        Haptics.select()
    }
}

/// One event on the timeline. Its height *is* its duration, which is the whole point of
/// drawing a day to scale rather than listing it.
private struct EventBlock: View {
    let event: CalEventFull
    let height: CGFloat
    let day: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.foreground)
                .strikethrough(event.isCancelled || (event.isTodo && event.done), color: Theme.Colors.mutedForeground)
                .lineLimit(height > 44 ? 2 : 1)
            if height > 30 {
                Text(CalDate.timeRange(event.start, event.end))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        .background(Theme.Colors.muted.opacity(event.isCancelled ? 0 : 0.85))
        .overlay(alignment: .leading) {
            // The calendar's grayscale step, as a rule down the leading edge — the same
            // hueless identity the month grid uses.
            Rectangle()
                .fill(Theme.Colors.foreground.opacity(event.calendarTone))
                .frame(width: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Theme.Colors.border,
                              style: StrokeStyle(lineWidth: 1, dash: event.isTentative ? [3, 3] : []))
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .opacity(event.isDeclined || event.isCancelled ? 0.5 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    private var label: String {
        var parts = [CalDate.spokenDate(CalDate.date(fromKey: day) ?? event.start),
                     CalDate.timeRange(event.start, event.end),
                     event.displayTitle]
        if !event.location.isEmpty { parts.append(event.location) }
        if event.isDeclined { parts.append("Declined") }
        if event.isCancelled { parts.append("Cancelled") }
        if event.isTodo { parts.append(event.done ? "Done" : "To do") }
        return parts.joined(separator: ", ")
    }
}

/// A day key on its way into a sheet. `.sheet(item:)` wants something `Identifiable`, and
/// conforming `String` itself would be a retroactive conformance the whole app would inherit.
struct JournalDay: Identifiable, Hashable {
    let date: String
    var id: String { date }
}

// MARK: - Cover band

/// A wide crop of the day's photo. `CachedImage` is square by design, so this draws the
/// same cached bitmap at the band's own shape, honouring the vertical position the web
/// stored ("50% 30%" means the top third is what matters).
private struct CoverBand: View {
    let url: URL
    let position: String

    @State private var image: UIImage?

    private var anchor: UnitPoint {
        let parts = position.split(separator: " ").compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        guard parts.count == 2 else { return .center }
        return UnitPoint(x: min(max(parts[0] / 100, 0), 1), y: min(max(parts[1] / 100, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: Alignment(horizontal: .center, vertical: anchor.y < 0.34 ? .top : anchor.y > 0.66 ? .bottom : .center))
                        .clipped()
                } else {
                    Theme.Colors.muted
                }
            }
        }
        .task(id: url) {
            image = await ImageCache.shared.image(for: url, maxPixel: 1400)
        }
        .accessibilityHidden(true)
    }
}

private extension UIImage {
    /// The image no larger than `maxPixel` on its long side, redrawn without orientation
    /// metadata so the worker stores it the way up it was taken.
    func downscaled(maxPixel: CGFloat) -> UIImage {
        let longest = max(size.width, size.height) * scale
        let factor = min(1, maxPixel / max(longest, 1))
        let target = CGSize(width: (size.width * scale * factor).rounded(), height: (size.height * scale * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

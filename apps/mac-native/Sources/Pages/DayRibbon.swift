import SwiftUI
import AppKit

/// `DayRibbon.tsx`: the day view, drawn the way HEY draws it — time runs sideways. An event is
/// a full-height bar as wide as it is long, filled solid in its calendar's colour, its title
/// turned to read bottom-to-top. The strip is one continuous ribbon that runs through midnight
/// with the night squeezed, and free time is drawn to scale and stamped with its length.
struct DayRibbonView: View {
    let store: CalendarStore
    let cursor: String
    var reveal = 0
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void

    @Environment(Router.self) private var router
    @State private var nightOpen = false
    @State private var live: EventPreview?
    @State private var pending: EventPreview?
    @State private var sketch: (from: Double, to: Double)?
    @State private var now = Date()
    @State private var labelDraft = ""
    @State private var editingLabel = false
    @FocusState private var labelFocused: Bool

    /// Measured off 37signals' own screenshot: dead linear, bars at full track height.
    private let pxPerHour: CGFloat = 42.7
    private let minBar: CGFloat = 26
    private let timeOnBar: CGFloat = 84
    private let minStamp: CGFloat = 34
    private let captionH: CGFloat = 19
    private let hoursH: CGFloat = 17
    private var trackTop: CGFloat { captionH + hoursH }

    private var cal: Calendar { store.calendar }
    private var fromKey: String { CalDate.addingDays(-1, toKey: cursor, in: cal) }
    private var toKey: String { CalDate.addingDays(3, toKey: cursor, in: cal) }
    private var winFrom: Double { CalDate.ms(fromKey, minutes: 0, in: cal) }
    private var winTo: Double { CalDate.ms(toKey, minutes: 0, in: cal) }
    private var ribbon: CalRibbon {
        CalRibbon(from: winFrom, to: winTo, pxPerHour: pxPerHour, nightStart: store.prefs.nightStart, nightEnd: store.prefs.nightEnd, collapseNight: store.prefs.collapseNight && !nightOpen, in: cal)
    }
    private var preview: EventPreview? { live ?? pending }
    private var timed: [CalEventFull] {
        let all = store.timedEvents(from: winFrom, to: winTo)
        guard let p = preview else { return all }
        return all.map { $0.id == p.id ? p.shown : $0 }
    }
    private var day: CalDay? { store.day(forKey: cursor) }
    private var allDay: [CalEventFull] { store.events(onKey: cursor).allDay }

    var body: some View {
        VStack(spacing: 0) {
            header
            strip
            if !allDay.isEmpty { allDayRow }
            countdownsRow
        }
        .background(W.background)
        .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1))
        .rounded(W.radiusMd)
        .task {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); now = Date() }
        }
        .onChange(of: store.calendar.firstWeekday) { _, _ in }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    Text(longLabel).font(W.font(14, 600)).lineLimit(1)
                    if let rel = CalDate.relativeDay(CalDate.date(fromKey: cursor, in: cal) ?? Date(), in: cal) {
                        Text(rel).font(W.font(11)).foregroundStyle(W.mutedForeground)
                    }
                    if editingLabel {
                        TextField("", text: $labelDraft).textFieldStyle(.plain).font(W.font(12)).multilineTextAlignment(.center)
                            .focused($labelFocused)
                            .onSubmit { commitLabel() }
                            .onChange(of: labelFocused) { _, f in if !f && editingLabel { commitLabel() } }
                            .onKeys(["Escape": { labelDraft = day?.label ?? ""; editingLabel = false }], priority: 10, whileTyping: true)
                            .frame(height: 20).padding(.top, 4)
                            .onAppear { labelFocused = true }
                    } else {
                        Button { labelDraft = day?.label ?? ""; editingLabel = true } label: {
                            Text((day?.label.isEmpty == false) ? day!.label : "Name this day")
                                .font(W.font(12)).foregroundStyle((day?.label.isEmpty == false) ? W.mutedForeground : W.tertiary.opacity(0.7))
                                .lineLimit(1).frame(height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(.top, 2)
                    }
                }
                .padding(.horizontal, 64)
                .frame(maxWidth: .infinity)
                HStack(spacing: 4) {
                    WButton(icon: "bookOpen", variant: .ghost, size: .iconSm, muted: true, help: "Journal") { router.go(.journal(cursor)) }
                    WButton(icon: "plus", variant: .ghost, size: .iconSm, muted: true, help: "New event") { onCreate(CalDate.ms(cursor, minutes: 9 * 60, in: cal), CalDate.ms(cursor, minutes: 10 * 60, in: cal)) }
                }
            }
            let habits = store.habits(onKey: cursor)
            if !habits.isEmpty {
                HStack(spacing: 6) {
                    ForEach(habits) { h in
                        let done = h.completions.contains(cursor)
                        Button { toggle(h) } label: {
                            Text(h.icon.isEmpty ? String(h.name.prefix(1)).uppercased() : h.icon).font(W.font(13))
                                .foregroundStyle(done ? .white : W.mutedForeground)
                                .frame(width: 28, height: 28)
                                .background(done ? colorFromHex(h.color.isEmpty ? "#37352f" : h.color) : Color.clear)
                                .overlay(Circle().strokeBorder(done ? Color.clear : W.border, lineWidth: 1))
                                .clipShape(Circle()).contentShape(Circle())
                        }
                        .buttonStyle(.plain).help("\(h.name)\(done ? " · done" : "")")
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .edgeLine(.bottom)
    }

    private var longLabel: String {
        guard let d = CalDate.date(fromKey: cursor, in: cal) else { return cursor }
        let f = DateFormatter(); f.calendar = cal; f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE, d MMMM yyyy"
        return f.string(from: d)
    }

    private func commitLabel() {
        editingLabel = false
        let next = labelDraft.trimmingCharacters(in: .whitespaces)
        guard next != (day?.label ?? "") else { return }
        Task {
            do { store.adopt(day: try await CalendarAPI.updateDay(date: cursor, label: next)) }
            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    private func toggle(_ h: CalHabit) {
        Task {
            do { store.adopt(habit: try await CalendarAPI.toggleHabit(id: h.id, date: cursor, from: CalDate.addingDays(-83, toKey: cursor, in: cal), to: cursor)) }
            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    // MARK: Strip

    private var strip: some View {
        let ribbon = ribbon
        let timed = timed
        let layout = CalDate.layoutColumns(timed, floorMs: Double(minBar / pxPerHour) * 3_600_000)
        let gaps = CalRibbon.freeGaps(timed, from: winFrom, to: winTo)
        let hourStep = ribbon.pxPerHour >= 40 ? 1 : 2
        let nowMs = now.timeIntervalSince1970 * 1000
        return GeometryReader { g in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: max(ribbon.length, 1), height: g.size.height)
                        // Which day you are scrolled into: over its daylight, not its midnight.
                        ForEach(dayMarks(ribbon), id: \.key) { m in
                            Text("\(weekday(m.key)) \(dayNumber(m.key))")
                                .font(W.font(10.5, CalDate.todayKey == m.key ? 600 : 400))
                                .foregroundStyle(CalDate.todayKey == m.key ? W.foreground : W.mutedForeground)
                                .fixedSize().frame(height: captionH)
                                .alignmentGuide(.leading) { d in d.width / 2 - m.pos }
                        }
                        ForEach(ribbon.hours.filter { $0.hour % hourStep == 0 }, id: \.ms) { h in
                            Text(heyTime(h.ms)).font(W.font(11)).monospacedDigit().foregroundStyle(W.mutedForeground).fixedSize()
                                .offset(x: h.pos + 3, y: captionH)
                        }
                        // The anchor "Today" and the cursor scroll to: the middle of the day's waking hours.
                        HStack(spacing: 0) { Color.clear.frame(width: max(0, middle(ribbon) - 0.5), height: 1); Color.clear.frame(width: 1, height: 1).id("anchor") }
                        track(ribbon: ribbon, timed: timed, layout: layout, gaps: gaps, hourStep: hourStep, nowMs: nowMs, height: g.size.height - trackTop)
                            .offset(y: trackTop)
                    }
                    .frame(width: max(ribbon.length, 1), height: g.size.height, alignment: .topLeading)
                }
                .scrollIndicators(.never)
                // The strip is laid out a beat after it appears; asking once more then lands it.
                .onAppear { proxy.scrollTo("anchor", anchor: .center); DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { proxy.scrollTo("anchor", anchor: .center) } }
                .onChange(of: ribbon.length) { _, _ in DispatchQueue.main.async { proxy.scrollTo("anchor", anchor: .center) } }
                .onChange(of: cursor) { _, _ in proxy.scrollTo("anchor", anchor: .center) }
                .onChange(of: reveal) { _, _ in withAnimation { proxy.scrollTo("anchor", anchor: .center) } }
                .onChange(of: nightOpen) { _, _ in proxy.scrollTo("anchor", anchor: .center) }
            }
            // The strip runs on forever; fading the last few points reads as "there is more".
            .overlay(alignment: .leading) { LinearGradient(colors: [W.background, W.background.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(width: 24).allowsHitTesting(false) }
            .overlay(alignment: .trailing) { LinearGradient(colors: [W.background.opacity(0), W.background], startPoint: .leading, endPoint: .trailing).frame(width: 24).allowsHitTesting(false) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func track(ribbon: CalRibbon, timed: [CalEventFull], layout: [(column: Int, columns: Int)], gaps: [(from: Double, to: Double)], hourStep: Int, nowMs: Double, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Free time, drawn to scale and stamped — the thesis of the whole view.
            ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                let left = ribbon.pos(gap.from)
                let width = ribbon.pos(gap.to) - left
                if width >= 1 {
                    ZStack(alignment: .bottomLeading) {
                        W.muted60
                        if width >= minStamp, let stamp = ribbon.stampPos(from: gap.from, to: gap.to) {
                            Text(CalRibbon.spanLabel(gap.to - gap.from)).font(W.font(9.5)).foregroundStyle(W.tertiary).fixedSize()
                                .alignmentGuide(.leading) { d in d.width / 2 - (stamp - left) }
                                .padding(.bottom, 4)
                        }
                    }
                    .frame(width: width, height: height)
                    .offset(x: left)
                    .allowsHitTesting(false)
                }
            }
            // The only ruling: a near-invisible hairline under each hour label.
            ForEach(ribbon.hours.filter { $0.hour % hourStep == 0 }, id: \.ms) { h in
                Rectangle().fill(W.border.opacity(0.4)).frame(width: 1, height: height + hoursH - 2).offset(x: h.pos, y: -(hoursH - 2)).allowsHitTesting(false)
            }
            ForEach(ribbon.runs.filter(\.night), id: \.from) { run in
                NightBlock(run: run, ribbon: ribbon, height: height) { nightOpen.toggle() }
            }
            ForEach(Array(timed.enumerated()), id: \.element.id) { i, e in
                Spine(event: e, ribbon: ribbon, slot: layout[i], height: height, timeFormat: store.prefs.timeFormat, dragging: preview?.id == e.id, minBar: minBar, timeOnBar: timeOnBar,
                      onTap: { onEvent(e) },
                      onDrag: { mode, x0, x1, ended in drag(e, mode: mode, x0: x0, x1: x1, ended: ended, ribbon: ribbon) })
            }
            if let sketch {
                let a = ribbon.pos(min(sketch.from, sketch.to)), b = ribbon.pos(max(sketch.from, sketch.to))
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(W.foreground.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .frame(width: max(b - a, 6), height: height - 8).offset(x: a, y: 4).allowsHitTesting(false)
            }
            if nowMs >= winFrom && nowMs <= winTo {
                let x = ribbon.pos(nowMs)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.red).frame(width: 1, height: height)
                    Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: -3, y: -3)
                    Text(heyTime(nowMs)).font(W.font(9.5, 500)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Color.red)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 2))
                        .fixedSize()
                }
                .offset(x: x).allowsHitTesting(false)
            }
            if timed.isEmpty {
                Text("Nothing scheduled. Drag across the strip to make something.").font(W.font(12)).foregroundStyle(W.tertiary).fixedSize()
                    .frame(height: height).offset(x: ribbon.pos(CalDate.ms(cursor, minutes: 10 * 60, in: cal))).allowsHitTesting(false)
            }
        }
        .frame(width: max(ribbon.length, 1), height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        // Drag across the strip to draw out a new event; a plain click makes a half hour.
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let from = sketch?.from ?? snapMs(ribbon.at(v.startLocation.x))
            sketch = (from, snapMs(ribbon.at(v.location.x)))
        }.onEnded { v in
            guard let s = sketch else { return }
            sketch = nil
            let a = min(s.from, s.to), b = max(s.from, s.to)
            onCreate(a, b == a ? a + 30 * 60_000 : b)
        })
    }

    private func snapMs(_ ms: Double) -> Double { EventDrag.snap(ms) }

    private func drag(_ e: CalEventFull, mode: EventDrag.Mode, x0: CGFloat, x1: CGFloat, ended: Bool, ribbon: CalRibbon) {
        let delta = ribbon.at(x1) - ribbon.at(x0)
        let span = EventDrag.span(e, mode: mode, deltaMs: delta, in: cal)
        if !ended { live = EventPreview(event: e, span: span); return }
        live = nil
        guard EventDrag.moved(e, span) else { return }
        let p = EventPreview(event: e, span: span)
        pending = p
        DragCommit.commit(p, store: store, month: CalDate.date(fromKey: cursor, in: cal) ?? Date()) { if pending == p { pending = nil } }
    }

    private func middle(_ ribbon: CalRibbon) -> CGFloat {
        let dayStart = CalDate.ms(cursor, minutes: 0, in: cal)
        let ns = store.prefs.nightStart, ne = store.prefs.nightEnd
        let wakeFrom = dayStart + Double(ne) * 3_600_000
        let wakeTo = ns > ne ? dayStart + Double(ns) * 3_600_000 : dayStart + 24 * 3_600_000
        return (ribbon.pos(wakeFrom) + ribbon.pos(wakeTo)) / 2
    }

    private func dayMarks(_ ribbon: CalRibbon) -> [(key: String, pos: CGFloat)] {
        var out: [(key: String, pos: CGFloat)] = []
        var key = fromKey
        while key < toKey {
            let base = CalDate.ms(key, minutes: 0, in: cal)
            let a = ribbon.pos(base + Double(store.prefs.nightEnd) * 3_600_000)
            let b = ribbon.pos(base + Double(min(store.prefs.nightStart, 24)) * 3_600_000)
            let pos = (a + b) / 2
            if b - a > 40, pos > 2, pos < ribbon.length - 2 { out.append((key, pos)) }
            key = CalDate.addingDays(1, toKey: key, in: cal)
        }
        return out
    }

    private func weekday(_ key: String) -> String {
        guard let d = CalDate.date(fromKey: key, in: cal) else { return "" }
        let f = DateFormatter(); f.calendar = cal; f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEE"
        return f.string(from: d).uppercased()
    }
    private func dayNumber(_ key: String) -> String { String(Int(key.suffix(2)) ?? 0) }

    private func heyTime(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        if store.prefs.timeFormat == "24" { return String(format: "%02d:%02d", h, m) }
        let hh = h % 12 == 0 ? 12 : h % 12
        let ap = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(hh)\(ap)" : "\(hh):\(String(format: "%02d", m))\(ap)"
    }

    // MARK: Floor

    /// HEY pins all-day items to the bottom of the day, as fully-rounded pills.
    private var allDayRow: some View {
        HStack(spacing: 6) {
            ForEach(allDay) { e in
                let s = EventSurface(e)
                Button { onEvent(e) } label: {
                    Text((e.emoji.isEmpty ? "" : "\(e.emoji) ") + (e.title.isEmpty ? "(no title)" : e.title))
                        .font(W.font(11.5, 500)).foregroundStyle(s.ink).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 3).frame(maxWidth: 240).background(s.fill).clipShape(Capsule())
                        .strikethrough(e.isDeclined).opacity(e.isDeclined ? 0.45 : 1)
                }
                .buttonStyle(.plain).help(e.title.isEmpty ? "(no title)" : e.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .edgeLine(.top)
    }

    @ViewBuilder
    private var countdownsRow: some View {
        let today = CalDate.todayKey
        let countdowns = store.timedEvents(from: 0, to: .greatestFiniteMagnitude).filter { $0.countdown && ($0.startDate ?? "") >= today }
            .sorted { ($0.startDate ?? "") < ($1.startDate ?? "") }.prefix(8)
        if !countdowns.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(countdowns.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Text("·").foregroundStyle(W.tertiary) }
                        let d = max(0, daysUntil(e.startDate ?? today))
                        Button { onEvent(e) } label: {
                            Text(d == 0 ? "Today — \(e.emoji) \(e.title)" : "\(d) \(d == 1 ? "day" : "days") until \(e.emoji) \(e.title)").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(W.font(11)).foregroundStyle(W.mutedForeground)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .edgeLine(.top)
        }
    }

    private func daysUntil(_ key: String) -> Int {
        guard let a = CalDate.date(fromKey: CalDate.todayKey, in: cal), let b = CalDate.date(fromKey: key, in: cal) else { return 0 }
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }
}

/// One event, as the spine of a book on a shelf: as wide as the meeting is long, as tall as
/// the track, the title on its side. Overlapping events split the height instead of the width.
private struct Spine: View {
    let event: CalEventFull
    let ribbon: CalRibbon
    let slot: (column: Int, columns: Int)
    let height: CGFloat
    let timeFormat: String
    let dragging: Bool
    let minBar: CGFloat
    let timeOnBar: CGFloat
    var onTap: () -> Void
    /// (mode, x at press, x now, ended)
    var onDrag: (EventDrag.Mode, CGFloat, CGFloat, Bool) -> Void
    @State private var mode: EventDrag.Mode?

    var body: some View {
        let s = EventSurface(event)
        let left = ribbon.pos(event.startsAt)
        let width = max(ribbon.pos(event.endsAt) - left, minBar)
        let wide = width >= timeOnBar || dragging
        let share = (height - 4) / CGFloat(max(slot.columns, 1))
        let top = CGFloat(slot.column) * share + 2
        let barH = max(share - 4, 8)
        let grab = EventDrag.handle(width)
        ZStack(alignment: .topLeading) {
            s.fill
            if wide {
                Text("\(heyTime(event.start))- \(heyTime(event.end))").font(W.font(10)).monospacedDigit().opacity(0.7).lineLimit(1)
                    .padding(.horizontal, 6).padding(.top, 3).frame(width: width, alignment: .leading)
            }
            Text((event.emoji.isEmpty ? "" : "\(event.emoji) ") + (event.title.isEmpty ? "(no title)" : event.title))
                .font(W.font(12, 600)).lineLimit(1)
                .frame(width: max(barH - (wide ? 12 : 0) - 4, 8))
                .rotationEffect(.degrees(-90))
                .frame(width: width, height: barH - (wide ? 12 : 0))
                .offset(y: wide ? 12 : 0)
        }
        .foregroundStyle(s.ink)
        .frame(width: width, height: barH)
        .clipped()
        .rounded(3)
        .opacity(event.isDeclined ? 0.4 : (event.isTentative ? 0.7 : 1))
        .overlay { if dragging { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.4), lineWidth: 1) } }
        .shadow(color: .black.opacity(dragging ? 0.2 : 0), radius: 8, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(DragGesture(minimumDistance: EventDrag.slop, coordinateSpace: .named("ribbon")).onChanged { v in
            guard event.writable else { return }
            if mode == nil {
                let x = v.startLocation.x - left
                mode = x < grab ? .start : (x > width - grab ? .end : .move)
            }
            onDrag(mode!, v.startLocation.x, v.location.x, false)
        }.onEnded { v in
            guard let m = mode else { return }
            mode = nil
            onDrag(m, v.startLocation.x, v.location.x, true)
        })
        .offset(x: left, y: top)
        .zIndex(dragging ? 35 : 20)
        .help("\(event.title.isEmpty ? "(no title)" : event.title) · \(heyTime(event.start))- \(heyTime(event.end))")
    }

    private func heyTime(_ d: Date) -> String {
        let cal = CalDate.cal
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        if timeFormat == "24" { return String(format: "%02d:%02d", h, m) }
        let hh = h % 12 == 0 ? 12 : h % 12
        let ap = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(hh)\(ap)" : "\(hh):\(String(format: "%02d", m))\(ap)"
    }
}

/// The quiet hours, squeezed rather than cut out: dark, faintly starred, torn along both
/// edges so it reads as a piece removed from the day. Click it to see the hours at scale.
private struct NightBlock: View {
    let run: CalRibbon.Run
    let ribbon: CalRibbon
    let height: CGFloat
    var onClick: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dots = stars(seed: run.from, count: max(5, min(26, Int((run.size / 4).rounded()))))
        let cal = CalDate.cal
        let d = Date(timeIntervalSince1970: run.from / 1000)
        let base = cal.startOfDay(for: d)
        let midnight = (cal.component(.hour, from: d) >= 12 ? cal.date(byAdding: .day, value: 1, to: base) : base).map { $0.timeIntervalSince1970 * 1000 } ?? 0
        let midPos: CGFloat? = midnight > run.from && midnight < run.to ? ribbon.pos(midnight) - run.pos : nil
        Button(action: onClick) {
            ZStack(alignment: .topLeading) {
                Color(hex: scheme == .dark ? "#2c2c3b" : "#1c1c24")
                ForEach(Array(dots.enumerated()), id: \.offset) { _, s in
                    Circle().fill(Color.white.opacity(s.o)).frame(width: s.big ? 2 : 1, height: s.big ? 2 : 1)
                        .offset(x: s.x * run.size, y: s.y * height)
                }
                if let midPos { Rectangle().fill(Color.black).frame(width: 1, height: height).offset(x: midPos) }
                Text("Nighttime").font(W.font(9.5)).tracking(0.5).foregroundStyle(Color.white.opacity(0.45)).fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: run.size, height: height)
            }
            .frame(width: run.size, height: height)
            .mask(TornEdges(saw: 5).fill(style: FillStyle(eoFill: false)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nighttime — click to open the quiet hours")
        .offset(x: run.pos)
        .zIndex(10)
    }

    /// Stars placed from the run's own start instant, so they never jitter between draws.
    private func stars(seed: Double, count: Int) -> [(x: CGFloat, y: CGFloat, o: Double, big: Bool)] {
        var s = UInt32(truncatingIfNeeded: Int(seed / 60_000)) ^ 0x9e37_79b9
        func next() -> Double { s = s &* 1_664_525 &+ 1_013_904_223; return Double(s) / 4_294_967_296 }
        return (0..<count).map { _ in
            let x = 0.05 + next() * 0.9, y = 0.06 + next() * 0.88, r = next()
            return (CGFloat(x), CGFloat(y), 0.2 + r * 0.55, r > 0.78)
        }
    }
}

/// Torn paper down the left and right edges: a saw-tooth comb tiled up each side.
private struct TornEdges: Shape {
    let saw: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: saw, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - saw, y: rect.minY))
        var y = rect.minY
        var out = true
        while y < rect.maxY {
            let ny = min(y + saw, rect.maxY)
            p.addLine(to: CGPoint(x: out ? rect.maxX : rect.maxX - saw, y: ny))
            y = ny; out.toggle()
        }
        p.addLine(to: CGPoint(x: saw, y: rect.maxY))
        y = rect.maxY
        out = true
        while y > rect.minY {
            let ny = max(y - saw, rect.minY)
            p.addLine(to: CGPoint(x: out ? rect.minX : saw, y: ny))
            y = ny; out.toggle()
        }
        p.closeSubpath()
        return p
    }
}

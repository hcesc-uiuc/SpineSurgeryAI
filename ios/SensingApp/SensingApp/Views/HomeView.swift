//
//  HomeView.swift
//  SensingApp
//
//  Home tab. Extracted from MainAppView.swift (was MainAppView.HomeView).
//

import SwiftUI
import HealthKit
internal import Combine   // .receive(on:) on the NSCalendarDayChanged publisher

struct HomeView: View {
    let accentColor: Color
    let onLogout: () -> Void
    @ObservedObject var appState: AppState
    @Binding var isSurveyPresented: Bool

    @AppStorage("journey_first_open_date") private var firstOpenTimestamp: Double = 0
    @Environment(\.scenePhase) private var scenePhase

    /// Midnight of the current day, held as state rather than read from `Date()`
    /// inside the body. Everything date-dependent on this screen (the Day pill,
    /// the "Today" column, which circles are in the future) derives from it, so
    /// refreshing this one value rolls the whole screen over — and because the
    /// body READS it, SwiftUI is guaranteed to re-render. Computing from
    /// `Date()` directly looked identical but only updated when something else
    /// happened to invalidate the view, so an app left open past midnight kept
    /// yesterday's day number and labelled yesterday "Today".
    @State private var todayStart = Calendar.current.startOfDay(for: Date())

    private var currentDay: Int {
        guard firstOpenTimestamp != 0 else { return 1 }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: firstOpenTimestamp))
        return max(1, (cal.dateComponents([.day], from: start, to: todayStart).day ?? 0) + 1)
    }

    private var checkInComplete: Bool { appState.isCompletedToday }

    @State private var appeared = false
    @State private var showSettings = false
    @State private var todaySteps: Int? = nil
    @State private var todayDistanceMeters: Double? = nil
    @State private var latestHeartRate: Int? = nil
    @State private var lastNightSleepHours: Double? = nil
    @State private var todayActiveEnergy: Int? = nil
    @State private var todayFlights: Int? = nil
    // Per-tile provenance note ("heartrate", "heartrate · Jul 22"), set by
    // applySensorStore(). Absent when the reading is live and from today.
    @State private var statCaptions: [SensorKind: String] = [:]
    @State private var weeklyProgress: [Date: Bool] = [:]

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.95, blue: 0.91),
                        Color(red: 0.95, green: 0.91, blue: 0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(greetingText)
                                    .font(.journey(.subheadline, weight: .medium))
                                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                Text("Hi there!")
                                    .font(.journey(.title, weight: .bold))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            }
                            Spacer(minLength: 8)
                            dayPill
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.easeOut(duration: 0.45).delay(0.05), value: appeared)

                        // The welcome block is a day-one-only moment. From day 2 on
                        // the day number lives in the pill beside the greeting, so
                        // the card would just repeat it and push everything down.
                        if currentDay == 1 {
                            recoveryDayCard
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 16)
                                .animation(.easeOut(duration: 0.45).delay(0.15), value: appeared)
                        }

                        // ── Weekly survey strip ──────────────
                        weeklyStripCard
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)
                            .animation(.easeOut(duration: 0.45).delay(0.20), value: appeared)

                        Button(action: { isSurveyPresented = true }) {
                            dailyCheckInCard
                        }
                        .buttonStyle(.plain)
                        .disabled(checkInComplete)
                        .accessibilityLabel(checkInComplete
                                            ? "Daily check-in complete"
                                            : "Daily check-in due")
                        .accessibilityHint(checkInComplete
                                           ? ""
                                           : "Opens today's check-in. Takes about two minutes.")
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(.easeOut(duration: 0.45).delay(0.25), value: appeared)

                        quickStatsRow
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)
                            .animation(.easeOut(duration: 0.45).delay(0.35), value: appeared)

                        Spacer().frame(height: 20)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.clear, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "person.fill")
                            .font(.system(.callout).weight(.semibold))
                            .foregroundStyle(accentColor)
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(accentColor: Color(red: 0.58, green: 0.48, blue: 0.72), onLogout: onLogout)
            }
        }
        .onAppear {
            appeared = true
            if firstOpenTimestamp == 0 { firstOpenTimestamp = Date().timeIntervalSince1970 }
            rollDayIfNeeded()
            loadTodayHealthStats()
            loadWeeklyProgress()
        }
        // onAppear does not fire on background→foreground, so stats went stale
        // when the app was reopened. Reload whenever the scene becomes active.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                rollDayIfNeeded()
                loadTodayHealthStats()
                loadWeeklyProgress()
            }
        }
        // Covers the app being left open across midnight, when neither onAppear
        // nor scenePhase fires. iOS posts this on a day change and on timezone
        // changes; RunLoop.main because @State must only be touched on main.
        .onReceive(
            NotificationCenter.default
                .publisher(for: .NSCalendarDayChanged)
                .receive(on: RunLoop.main)
        ) { _ in
            rollDayIfNeeded()
        }
    }

    /// Re-anchors the screen on the current day. No-op when the day has not
    /// changed, so it is safe to call on every appear and foreground.
    private func rollDayIfNeeded() {
        let start = calendar.startOfDay(for: Date())
        guard start != todayStart else { return }
        todayStart = start
        // The visible week may have rolled too (Sat → Sun), so the completion
        // map has to be rebuilt for the new set of days. `start` is passed
        // explicitly rather than relying on the @State write above being
        // readable again this same tick.
        loadWeeklyProgress(anchor: start)
    }

    // ── Weekly strip card ─────────────────────
    private var weeklyStripCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This week")
                .font(.journey(.footnote, weight: .semibold))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))

            HStack(spacing: 0) {
                ForEach(currentWeekDays(), id: \.self) { date in
                    let isToday    = calendar.isDate(date, inSameDayAs: todayStart)
                    let isFuture   = date > todayStart
                    let completed  = weeklyProgress[calendar.startOfDay(for: date)] ?? false
                    let dayLetter  = shortDayLetter(for: date)
                    let dayNum     = calendar.component(.day, from: date)

                    VStack(spacing: 6) {
                        // Today reads "Today" rather than its weekday letter — it is
                        // the one column people look for. lineLimit/minimumScaleFactor
                        // keep it inside the ~34pt column on the smallest phones.
                        Text(isToday ? "Today" : dayLetter)
                            .font(.journey(.caption2, weight: isToday ? .semibold : .medium))
                            .foregroundStyle(isToday
                                ? Color(red: 0.22, green: 0.48, blue: 0.40)
                                : Color(red: 0.55, green: 0.47, blue: 0.44))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        ZStack {
                            Circle()
                                .fill(isFuture
                                    ? Color.clear
                                    : completed
                                        ? Color(red: 0.22, green: 0.60, blue: 0.45)
                                        : Color(red: 0.55, green: 0.48, blue: 0.44).opacity(0.85))
                                .frame(width: 34, height: 34)

                            if isToday && !completed {
                                Circle()
                                    .strokeBorder(Color(red: 0.42, green: 0.62, blue: 0.55), lineWidth: 2)
                                    .frame(width: 34, height: 34)
                            }

                            if !isFuture {
                                if completed {
                                    Image(systemName: "checkmark")
                                        .font(.system(.footnote).weight(.bold))
                                        .foregroundStyle(.white)
                                } else {
                                    Text("\(dayNum)")
                                        .font(.journey(.footnote, weight: isToday ? .bold : .regular))
                                        .foregroundStyle(.white)
                                }
                            } else {
                                Text("\(dayNum)")
                                    .font(.journey(.footnote))
                                    .foregroundStyle(Color(red: 0.70, green: 0.65, blue: 0.62).opacity(0.4))
                            }
                        }
                        .opacity(isFuture ? 0.4 : 1.0)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(weekDayAccessibilityLabel(for: date,
                                                                 isToday: isToday,
                                                                 isFuture: isFuture,
                                                                 completed: completed))
                }
            }
            // Seven columns of ~34pt cannot absorb accessibility text sizes.
            .journeyDenseLayout()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
        )
        .padding(.horizontal, 24)
    }

    /// Rolling 7-day window ending today, so today is always the last
    /// (rightmost) entry and the whole strip shifts left as new days arrive.
    ///
    /// Anchored on `todayStart` rather than a fresh `Date()` so the midnight
    /// rollover works: the body reads that @State, which is what guarantees a
    /// re-render when the day changes. `rollDayIfNeeded` passes the new day in
    /// explicitly rather than relying on the just-written @State being visible
    /// in the same tick.
    private func currentWeekDays(anchor: Date? = nil) -> [Date] {
        let today = anchor ?? todayStart
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: -(6 - offset), to: today)
        }
    }

    /// VoiceOver reads each column as one sentence. Without this the strip is
    /// announced as a stream of orphaned letters and numbers ("Mo", "11",
    /// "Tu", "12") with no indication of which days were completed.
    private func weekDayAccessibilityLabel(for date: Date,
                                           isToday: Bool,
                                           isFuture: Bool,
                                           completed: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        let day = isToday ? "Today" : formatter.string(from: date)
        if isFuture { return day }
        return "\(day), check-in \(completed ? "completed" : "not completed")"
    }

    private func shortDayLetter(for date: Date) -> String {
        let symbols = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        let weekday = calendar.component(.weekday, from: date) - 1
        return symbols[weekday]
    }

    private func loadWeeklyProgress(anchor: Date? = nil) {
        let days = currentWeekDays(anchor: anchor)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let months = Set(days.map { $0.startOfMonth() })
        var result: [Date: Bool] = [:]

        // Load from SQLite if available
        for month in months {
            for record in SQLiteSaver.shared.fetchSurveys(forMonth: month) {
                guard let date = formatter.date(from: record.dateString) else { continue }
                result[calendar.startOfDay(for: date)] = record.completed
            }
        }

        // Fall back to UserDefaults if SQLite returned nothing
        if result.isEmpty {
            let completedDates = UserDefaults.standard.stringArray(forKey: "completedSurveyDates_default_user") ?? []
            for dateString in completedDates {
                guard let date = formatter.date(from: dateString) else { continue }
                result[calendar.startOfDay(for: date)] = true
            }
        }

        weeklyProgress = result
    }

    // Home tiles read from SensorStatusStore, which resolves every metric in one
    // place: an imported file wins, else the live HealthKit stamp, else nothing.
    // The six HealthKit queries that used to live here were a second, duplicate
    // source of truth for the same six numbers.
    private func loadTodayHealthStats() {
        applySensorStore()                                   // cached stamps + imports, instantly
        Task {
            // Pick up anything dropped into the Documents folder since we were
            // last on screen. Blocking file I/O, so it runs off the main actor;
            // captures nothing, so it is safe to detach.
            await Task.detached { _ = SensorFileImporter.autoIngestInbox() }.value
            applySensorStore()
            SensorStatusStore.shared.refreshHealthKitSamples {   // then the live samples
                applySensorStore()
            }
        }
    }

    /// Pull each tile's value and caption out of the store. A caption appears
    /// only when the reading is noteworthy — imported, or not from today. (The
    /// DEBUG sample table is never surfaced on Home; see
    /// SensorStatusStore.homeTile.)
    ///
    /// Every tile is assigned on every pass, INCLUDING the nil case. Skipping the
    /// nil case left the last known value on screen forever: deleting an import,
    /// or clearing them all, kept showing the imported number because nothing
    /// ever wrote over it.
    private func applySensorStore() {
        let store = SensorStatusStore.shared
        var captions: [SensorKind: String] = [:]

        func tile(_ kind: SensorKind, _ assign: (Double?) -> Void) {
            let resolved = store.homeTile(for: kind)
            assign(resolved?.value)
            captions[kind] = resolved?.caption
        }

        tile(.steps)        { todaySteps = $0.map { Int($0) } }
        tile(.distance)     { todayDistanceMeters = $0.map { $0 * 1000 } }   // series is stored in km
        tile(.heartRate)    { latestHeartRate = $0.map { Int($0) } }
        tile(.activeEnergy) { todayActiveEnergy = $0.map { Int($0) } }
        tile(.flights)      { todayFlights = $0.map { Int($0) } }
        tile(.sleep)        { lastNightSleepHours = $0 }

        statCaptions = captions
    }

    /// Compact day counter that sits beside the greeting. It is the permanent
    /// home of the day number from day 2 on, and it absorbs the milestone
    /// callout (🎉 Day 7) rather than adding a second element to the row.
    private var dayPill: some View {
        HStack(spacing: 5) {
            if currentMilestone != nil {
                Text("🎉")
                    .font(.system(.footnote))
            }
            Text("Day")
                .font(.journey(.footnote, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text("\(currentDay)")
                .font(.journey(.body, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: accentColor.opacity(0.30), radius: 8, y: 3)
        )
        // .fixedSize() means the pill never truncates, so at accessibility text
        // sizes it would take the whole row and squeeze the greeting out.
        .journeyDenseLayout()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(currentMilestone ?? "Day \(currentDay) of your recovery journey")
    }

    private var recoveryDayCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: accentColor.opacity(0.35), radius: 16, y: 8)
            VStack(spacing: 2) {
                Text("Day")
                    .font(.journey(.footnote, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text("\(currentDay)")
                    .font(.journey(.largeTitle, weight: .bold))
                    .foregroundStyle(.white)
                Text("Welcome to your recovery journey!")
                    .font(.journey(.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                // No milestone capsule here: this card only renders on day 1,
                // which is never a milestone day. Milestones live in dayPill.
            }
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 24)
    }

    private var dailyCheckInCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(checkInComplete
                          ? Color(red: 0.42, green: 0.62, blue: 0.55).opacity(0.15)
                          : Color(red: 0.80, green: 0.55, blue: 0.45).opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: checkInComplete ? "checkmark.circle.fill" : "pencil.and.list.clipboard")
                    .font(.system(.title))
                    .foregroundStyle(checkInComplete
                                     ? Color(red: 0.42, green: 0.62, blue: 0.55)
                                     : Color(red: 0.80, green: 0.55, blue: 0.45))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(checkInComplete ? "Check-in complete!" : "Daily check-in due")
                    .font(.journey(.callout, weight: .semibold))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text(checkInComplete
                     ? "Great work today. See you tomorrow."
                     : "Takes about 2 minutes to complete.")
                    .font(.journey(.footnote))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
            }
            Spacer()
            if !checkInComplete {
                Image(systemName: "chevron.right")
                    .font(.system(.subheadline).weight(.semibold))
                    .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
        )
        .padding(.horizontal, 24)
    }

    private let statColumns = [GridItem(.flexible(), spacing: 10),
                               GridItem(.flexible(), spacing: 10),
                               GridItem(.flexible(), spacing: 10)]

    private var quickStatsRow: some View {
        LazyVGrid(columns: statColumns, spacing: 10) {
            statCard(icon: "figure.walk",        value: todaySteps.map { formatSteps($0) } ?? "—",                        label: "Steps",       color: Color(red: 0.42, green: 0.62, blue: 0.55), caption: statCaptions[.steps])
            statCard(icon: "figure.walk.motion", value: todayDistanceMeters.map { formatDistance($0) } ?? "—",            label: "Distance",    color: Color(red: 0.38, green: 0.55, blue: 0.75), caption: statCaptions[.distance])
            statCard(icon: "heart.fill",         value: latestHeartRate.map { "\($0)" } ?? "—",                           label: "Heart rate",  color: Color(red: 0.80, green: 0.55, blue: 0.45), caption: statCaptions[.heartRate])
            statCard(icon: "flame.fill",         value: todayActiveEnergy.map { "\($0)" } ?? "—",                         label: "Active kcal", color: Color(red: 0.85, green: 0.50, blue: 0.35), caption: statCaptions[.activeEnergy])
            statCard(icon: "figure.stairs",      value: todayFlights.map { "\($0)" } ?? "—",                              label: "Flights",     color: Color(red: 0.50, green: 0.60, blue: 0.45), caption: statCaptions[.flights])
            statCard(icon: "bed.double.fill",    value: lastNightSleepHours.map { String(format: "%.1f hr", $0) } ?? "—", label: "Sleep",       color: Color(red: 0.58, green: 0.48, blue: 0.72), caption: statCaptions[.sleep])
        }
        .padding(.horizontal, 24)
        // Three tiles per row is already tight; let the text grow a long way
        // but stop before the values start truncating to nothing.
        .journeyDenseLayout()
    }

    private func formatSteps(_ steps: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: steps)) ?? "\(steps)"
    }

    private func formatDistance(_ meters: Double) -> String {
        let km = meters / 1000.0
        return String(format: "%.1f km", km)
    }

    private func statCard(icon: String, value: String, label: String, color: Color, caption: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(.title3))
                .foregroundStyle(color)
            Text(value)
                .font(.journey(.callout, weight: .bold))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Text(label)
                .font(.journey(.caption2, weight: .medium))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                .multilineTextAlignment(.center)
            // Only present when the reading is imported or not from today — so a
            // stale value can't pass for a fresh one.
            if let caption {
                Text(caption)
                    .font(.journey(.caption2, weight: .medium))
                    .foregroundStyle(Color(red: 0.68, green: 0.60, blue: 0.57))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 8, y: 3)
        )
        // Read as one tile ("Steps, 8,420") rather than three loose fragments
        // in icon-value-label order, which is how VoiceOver took it before.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statAccessibilityLabel(value: value, label: label, caption: caption))
    }

    private func statAccessibilityLabel(value: String, label: String, caption: String?) -> String {
        guard value != "—" else { return "\(label), no data yet" }
        return [label, value, caption].compactMap { $0 }.joined(separator: ", ")
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    private var currentMilestone: String? {
        switch currentDay {
        case 7:  return "1 week milestone!"
        case 14: return "2 week milestone!"
        case 30: return "1 month milestone!"
        case 90: return "3 month milestone!"
        default: return nil
        }
    }
}

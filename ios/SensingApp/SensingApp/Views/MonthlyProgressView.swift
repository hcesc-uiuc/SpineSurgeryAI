//
//  MonthlyProgressView.swift
//  SensingApp / Journey
//

import SwiftUI

// ─────────────────────────────────────────────
// MARK: - Model
// ─────────────────────────────────────────────

struct DayProgress: Identifiable {
    let id = UUID()
    let date: Date
    var surveyCompleted: Bool
    var painScore: Int?         // from surveys table

    var tier: DayTier {
        switch (surveyCompleted, painScore != nil) {
        case (true, true):  return .surveyAndScore
        case (true, false): return .surveyOnly
        default:            return .none
        }
    }
}

enum DayTier {
    case none, surveyOnly, surveyAndScore
}

// ─────────────────────────────────────────────
// MARK: - Top-level view
// ─────────────────────────────────────────────

struct MonthlyProgressView: View {
    var body: some View {
        NavigationStack {
            MonthlyCalendarView()
                .navigationTitle("Calendar")
                .navigationBarTitleDisplayMode(.large)
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Calendar view
// ─────────────────────────────────────────────

struct MonthlyCalendarView: View {

    @State private var displayedMonth: Date = Date().startOfMonth()
    @State private var selectedDay: DayProgress?
    @State private var showDetail = false
    @State private var progressData: [Date: DayProgress] = [:]

    // The day this participant started using the app. Days before it are
    // outside the study and must not be drawn as missed check-ins — a patient
    // enrolled on the 10th was opening this screen to nine "failures" they
    // could not possibly have completed. Same anchor HomeView counts Day N from.
    @AppStorage("journey_first_open_date") private var firstOpenTimestamp: Double = 0

    private var enrollmentDay: Date? {
        guard firstOpenTimestamp != 0 else { return nil }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: firstOpenTimestamp))
    }

    private func isBeforeEnrollment(_ date: Date) -> Bool {
        guard let enrollmentDay else { return false }
        return calendar.startOfDay(for: date) < enrollmentDay
    }

    private let calendar = Calendar.current
    private let columns  = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    private let daySymbols = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    var body: some View {
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
                    monthNavigationHeader
                    legendRow
                    dayOfWeekHeader
                    calendarGrid
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        .onAppear { loadData() }
        .onChange(of: displayedMonth) { _, _ in loadData() }
        .sheet(isPresented: $showDetail) {
            if let day = selectedDay {
                DayDetailSheet(day: day)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // ── Load from SQLite ─────────────────────
    private func loadData() {
        let records = SQLiteSaver.shared.fetchSurveys(forMonth: displayedMonth)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var result: [Date: DayProgress] = [:]

        // Load from SQLite if available
        for record in records {
            guard let date = formatter.date(from: record.dateString) else { continue }
            let normalised = calendar.startOfDay(for: date)
            result[normalised] = DayProgress(
                date: normalised,
                surveyCompleted: record.completed,
                painScore: record.painScore
            )
        }

        // Fall back to UserDefaults if SQLite returned nothing
        if result.isEmpty {
            let completedDates = UserDefaults.standard.stringArray(forKey: "completedSurveyDates_default_user") ?? []
            for dateString in completedDates {
                guard let date = formatter.date(from: dateString) else { continue }
                let normalised = calendar.startOfDay(for: date)
                // Only include dates in the displayed month
                if calendar.isDate(normalised, equalTo: displayedMonth, toGranularity: .month) {
                    result[normalised] = DayProgress(
                        date: normalised,
                        surveyCompleted: true,
                        painScore: nil
                    )
                }
            }
        }

        progressData = result
    }

    // ── Month navigation ─────────────────────
    private var monthNavigationHeader: some View {
        HStack {
            Button(action: goToPreviousMonth) {
                Image(systemName: "chevron.left")
                    .font(.system(.subheadline).weight(.medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                    .padding(10)
                    .background(Color.white.opacity(0.7))
                    .clipShape(Circle())
            }
            Spacer()
            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(.journey(.title3, weight: .bold))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Spacer()
            Button(action: goToNextMonth) {
                Image(systemName: "chevron.right")
                    .font(.system(.subheadline).weight(.medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                    .padding(10)
                    .background(Color.white.opacity(0.7))
                    .clipShape(Circle())
            }
            // goToNextMonth() silently refuses to go past the current month, so
            // at the newest month the button looked live but did nothing. Say so.
            .disabled(!canGoToNextMonth)
            .opacity(canGoToNextMonth ? 1 : 0.35)
            .accessibilityLabel("Next month")
        }
    }

    private var canGoToNextMonth: Bool {
        displayedMonth < Date().startOfMonth()
    }

    // ── Legend ───────────────────────────────
    private var legendRow: some View {
        HStack(spacing: 14) {
            legendItem(color: Color(red: 0.22, green: 0.60, blue: 0.45), label: "Completed")
            legendItem(color: Color(red: 0.55, green: 0.48, blue: 0.44), label: "Not completed")
            Spacer()
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.journey(.caption2, weight: .medium))
                .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
        }
    }

    // ── Day-of-week header ───────────────────
    private var dayOfWeekHeader: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(daySymbols, id: \.self) { sym in
                Text(sym)
                    .font(.journey(.caption, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                    .frame(maxWidth: .infinity)
            }
        }
        .journeyDenseLayout()
    }

    // ── Calendar grid ────────────────────────
    private var calendarGrid: some View {
        let cells = buildCells()
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(cells) { cell in
                if let day = cell.day {
                    let outsideStudy = isBeforeEnrollment(day.date)
                    CalendarDayCell(
                        day: day,
                        isToday: calendar.isDateInToday(day.date),
                        isFuture: day.date > Date(),
                        isBeforeEnrollment: outsideStudy
                    )
                    .onTapGesture {
                        guard day.date <= Date(), !outsideStudy else { return }
                        selectedDay = day
                        showDetail = true
                    }
                } else {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
            }
        }
        // Seven columns of day circles; text scales but must not overflow them.
        .journeyDenseLayout()
    }

    // ─────────────────────────────────────────
    // MARK: - Helpers
    // ─────────────────────────────────────────

    private struct CalendarCell: Identifiable {
        let id = UUID()
        let day: DayProgress?
    }

    private func buildCells() -> [CalendarCell] {
        let firstWeekday = calendar.component(.weekday, from: displayedMonth) - 1
        let daysCount    = daysInMonth(displayedMonth)
        var cells: [CalendarCell] = (0..<firstWeekday).map { _ in CalendarCell(day: nil) }

        for d in 1...daysCount {
            let date       = calendar.date(byAdding: .day, value: d - 1, to: displayedMonth)!
            let normalised = calendar.startOfDay(for: date)
            let progress   = progressData[normalised] ?? DayProgress(
                date: normalised,
                surveyCompleted: false,
                painScore: nil
            )
            cells.append(CalendarCell(day: progress))
        }
        return cells
    }

    private func daysInMonth(_ date: Date) -> Int {
        calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    private func goToPreviousMonth() {
        displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
    }

    private func goToNextMonth() {
        let next = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
        if next <= Date().startOfMonth() { displayedMonth = next }
    }
}

// ─────────────────────────────────────────────
// MARK: - Day cell  (green = done, gray = not done)
// ─────────────────────────────────────────────

struct CalendarDayCell: View {
    let day: DayProgress
    let isToday: Bool
    let isFuture: Bool
    /// Before the participant joined the study. Rendered exactly like a future
    /// day — faint and un-tappable — because both mean "no check-in was ever
    /// expected here", as opposed to "one was expected and missed".
    var isBeforeEnrollment: Bool = false

    private var isOutsideStudy: Bool { isFuture || isBeforeEnrollment }

    // Days outside the study get a very light, faint gray — clearly lighter
    // than "Not completed".
    private var fillColor: Color {
        if isOutsideStudy {
            return Color(red: 0.90, green: 0.87, blue: 0.84) // very light gray
        }
        return day.surveyCompleted
            ? Color(red: 0.22, green: 0.60, blue: 0.45)          // solid green
            : Color(red: 0.55, green: 0.48, blue: 0.44).opacity(0.85) // "Not completed" gray-brown
    }

    private var textColor: Color {
        if isOutsideStudy {
            return Color(red: 0.60, green: 0.55, blue: 0.51) // muted, readable on light fill
        }
        return .white
    }

    private var accessibilityText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        let date = formatter.string(from: day.date)
        if isOutsideStudy { return date }
        return "\(date), check-in \(day.surveyCompleted ? "completed" : "not completed")"
    }

    var body: some View {
        let dayNum = Calendar.current.component(.day, from: day.date)
        ZStack {
            Circle().fill(fillColor)
            if isToday && !day.surveyCompleted {
                Circle().strokeBorder(Color(red: 0.42, green: 0.62, blue: 0.55), lineWidth: 2)
            }
            Text("\(dayNum)")
                .font(.journey(.subheadline, weight: .semibold))
                .foregroundStyle(textColor)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

// ─────────────────────────────────────────────
// MARK: - Day detail sheet
// ─────────────────────────────────────────────

struct DayDetailSheet: View {
    let day: DayProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No hand-drawn grabber here: the sheet is presented with
            // .presentationDragIndicator(.visible), so drawing one as well
            // stacked two pills on top of each other.
            Text(day.date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.journey(.title2, weight: .bold))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                .padding(.horizontal, 24)
                .padding(.top, 36)      // clears the system drag indicator
                .padding(.bottom, 20)

            VStack(spacing: 0) {
                detailRow(
                    icon: "checkmark.circle.fill",
                    iconColor: day.surveyCompleted
                        ? Color(red: 0.22, green: 0.60, blue: 0.45)
                        : Color(red: 0.70, green: 0.60, blue: 0.55),
                    label: "Survey",
                    value: day.surveyCompleted ? "Completed" : "Not recorded"
                )

                if let score = day.painScore {
                    Divider().padding(.leading, 56)
                    detailRow(
                        icon: "heart.fill",
                        iconColor: Color(red: 0.80, green: 0.35, blue: 0.38),
                        label: "Pain score",
                        value: "\(score) / 10"
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
            )
            .padding(.horizontal, 20)

            Spacer()
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.95, blue: 0.91),
                         Color(red: 0.95, green: 0.91, blue: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private func detailRow(icon: String, iconColor: Color, label: String, value: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(.title3))
                .foregroundStyle(iconColor)
                .frame(width: 28)
            Text(label)
                .font(.journey(.subheadline))
                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
            Spacer()
            Text(value)
                .font(.journey(.subheadline, weight: .semibold))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// ─────────────────────────────────────────────
// MARK: - Date helper
// ─────────────────────────────────────────────

extension Date {
    func startOfMonth() -> Date {
        let cal   = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: self)
        return cal.date(from: comps) ?? self
    }
}

// ─────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────

#Preview {
    MonthlyProgressView()
}

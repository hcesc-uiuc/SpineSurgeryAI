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
                    surveysCompletedCard
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                    .padding(10)
                    .background(Color.white.opacity(0.7))
                    .clipShape(Circle())
            }
            Spacer()
            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Spacer()
            Button(action: goToNextMonth) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                    .padding(10)
                    .background(Color.white.opacity(0.7))
                    .clipShape(Circle())
            }
        }
    }

    // ── Surveys completed count card ─────────
    private var surveysCompletedCard: some View {
        let surveysCompleted = progressData.values.filter(\.surveyCompleted).count
        let pastDays         = pastDaysCount()

        return HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color(red: 0.22, green: 0.48, blue: 0.40))
            Text("\(surveysCompleted) of \(pastDays) surveys completed this month")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(red: 0.80, green: 0.65, blue: 0.58).opacity(0.25), lineWidth: 1)
                )
        )
    }

    // ── Legend ───────────────────────────────
    private var legendRow: some View {
        HStack(spacing: 14) {
            legendItem(color: Color(red: 0.22, green: 0.60, blue: 0.45), label: "Completed")
            legendItem(color: Color(red: 0.80, green: 0.75, blue: 0.72), label: "Not completed")
            Spacer()
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
        }
    }

    // ── Day-of-week header ───────────────────
    private var dayOfWeekHeader: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(daySymbols, id: \.self) { sym in
                Text(sym)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // ── Calendar grid ────────────────────────
    private var calendarGrid: some View {
        let cells = buildCells()
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(cells) { cell in
                if let day = cell.day {
                    CalendarDayCell(
                        day: day,
                        isToday: calendar.isDateInToday(day.date),
                        isFuture: day.date > Date()
                    )
                    .onTapGesture {
                        guard day.date <= Date() else { return }
                        selectedDay = day
                        showDetail = true
                    }
                } else {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
            }
        }
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

    private func pastDaysCount() -> Int {
        let today = calendar.startOfDay(for: Date())
        guard calendar.isDate(today, equalTo: displayedMonth, toGranularity: .month) else {
            return daysInMonth(displayedMonth)
        }
        return calendar.component(.day, from: today)
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

    private var fillColor: Color {
        if isFuture { return Color.clear }
        return day.surveyCompleted
            ? Color(red: 0.22, green: 0.60, blue: 0.45)          // solid green
            : Color(red: 0.80, green: 0.75, blue: 0.72).opacity(0.45) // soft gray
    }

    private var textColor: Color {
        if isFuture {
            return Color(red: 0.70, green: 0.65, blue: 0.62).opacity(0.4)
        }
        return day.surveyCompleted
            ? .white
            : Color(red: 0.40, green: 0.32, blue: 0.29)
    }

    var body: some View {
        let dayNum = Calendar.current.component(.day, from: day.date)
        ZStack {
            Circle().fill(fillColor)
            if isToday && !day.surveyCompleted {
                Circle().strokeBorder(Color(red: 0.42, green: 0.62, blue: 0.55), lineWidth: 2)
            }
            Text("\(dayNum)")
                .font(.system(size: 14, weight: isToday ? .bold : .regular, design: .rounded))
                .foregroundStyle(textColor)
        }
        .aspectRatio(1, contentMode: .fit)
        .opacity(isFuture ? 0.35 : 1.0)
    }
}

// ─────────────────────────────────────────────
// MARK: - Day detail sheet
// ─────────────────────────────────────────────

struct DayDetailSheet: View {
    let day: DayProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 0.75, green: 0.68, blue: 0.65))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 20)

            Text(day.date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                .padding(.horizontal, 24)
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
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 28)
            Text(label)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
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

//
//  HomeView.swift
//  SensingApp
//
//  Home tab. Extracted from MainAppView.swift (was MainAppView.HomeView).
//

import SwiftUI
import HealthKit

struct HomeView: View {
    let accentColor: Color
    let onLogout: () -> Void
    @ObservedObject var appState: AppState
    @Binding var isSurveyPresented: Bool

    @AppStorage("journey_first_open_date") private var firstOpenTimestamp: Double = 0

    private var currentDay: Int {
        guard firstOpenTimestamp != 0 else { return 1 }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: firstOpenTimestamp))
        let today = cal.startOfDay(for: Date())
        return max(1, (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1)
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(greetingText)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                            Text("Hi there 👋")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.easeOut(duration: 0.45).delay(0.05), value: appeared)

                        recoveryDayCard
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)
                            .animation(.easeOut(duration: 0.45).delay(0.15), value: appeared)

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
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(accentColor)
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(accentColor: Color(red: 0.58, green: 0.48, blue: 0.72), onLogout: onLogout)
            }
        }
        .onAppear {
            appeared = true
            if firstOpenTimestamp == 0 { firstOpenTimestamp = Date().timeIntervalSince1970 }
            loadTodayHealthStats()
            loadWeeklyProgress()
        }
    }

    // ── Weekly strip card ─────────────────────
    private var weeklyStripCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This week")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))

            HStack(spacing: 0) {
                ForEach(currentWeekDays(), id: \.self) { date in
                    let isToday    = calendar.isDateInToday(date)
                    let isFuture   = date > Date()
                    let completed  = weeklyProgress[calendar.startOfDay(for: date)] ?? false
                    let dayLetter  = shortDayLetter(for: date)
                    let dayNum     = calendar.component(.day, from: date)

                    VStack(spacing: 6) {
                        Text(dayLetter)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(isToday
                                ? Color(red: 0.22, green: 0.48, blue: 0.40)
                                : Color(red: 0.55, green: 0.47, blue: 0.44))

                        ZStack {
                            Circle()
                                .fill(isFuture
                                    ? Color.clear
                                    : completed
                                        ? Color(red: 0.22, green: 0.60, blue: 0.45)
                                        : Color(red: 0.80, green: 0.75, blue: 0.72).opacity(0.5))
                                .frame(width: 34, height: 34)

                            if isToday && !completed {
                                Circle()
                                    .strokeBorder(Color(red: 0.42, green: 0.62, blue: 0.55), lineWidth: 2)
                                    .frame(width: 34, height: 34)
                            }

                            if !isFuture {
                                if completed {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                } else {
                                    Text("\(dayNum)")
                                        .font(.system(size: 13, weight: isToday ? .bold : .regular, design: .rounded))
                                        .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                }
                            } else {
                                Text("\(dayNum)")
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundStyle(Color(red: 0.70, green: 0.65, blue: 0.62).opacity(0.4))
                            }
                        }
                        .opacity(isFuture ? 0.4 : 1.0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
        )
        .padding(.horizontal, 24)
    }

    private func currentWeekDays() -> [Date] {
        let today       = calendar.startOfDay(for: Date())
        let weekday     = calendar.component(.weekday, from: today) // 1=Sun
        let startOfWeek = calendar.date(byAdding: .day, value: -(weekday - 1), to: today)!
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: startOfWeek) }
    }

    private func shortDayLetter(for date: Date) -> String {
        let symbols = ["S", "M", "T", "W", "T", "F", "S"]
        let weekday = calendar.component(.weekday, from: date) - 1
        return symbols[weekday]
    }

    private func loadWeeklyProgress() {
        let days = currentWeekDays()
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

    private func loadTodayHealthStats() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let store = HKHealthStore()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)

        // Steps query
        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let stepsQuery = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                DispatchQueue.main.async {
                    todaySteps = result?.sumQuantity().map { Int($0.doubleValue(for: .count())) }
                }
            }
            store.execute(stepsQuery)
        }

        // Distance query
        if let distType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            let distQuery = HKStatisticsQuery(
                quantityType: distType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                DispatchQueue.main.async {
                    todayDistanceMeters = result?.sumQuantity().map { $0.doubleValue(for: .meter()) }
                }
            }
            store.execute(distQuery)
        }

        // Active energy query
        if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            let energyQuery = HKStatisticsQuery(
                quantityType: energyType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                DispatchQueue.main.async {
                    todayActiveEnergy = result?.sumQuantity().map { Int($0.doubleValue(for: .kilocalorie())) }
                }
            }
            store.execute(energyQuery)
        }

        // Flights climbed query
        if let flightsType = HKQuantityType.quantityType(forIdentifier: .flightsClimbed) {
            let flightsQuery = HKStatisticsQuery(
                quantityType: flightsType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                DispatchQueue.main.async {
                    todayFlights = result?.sumQuantity().map { Int($0.doubleValue(for: .count())) }
                }
            }
            store.execute(flightsQuery)
        }

        // Heart rate query — latest sample today
        if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            let hrQuery = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                DispatchQueue.main.async {
                    if let sample = samples?.first as? HKQuantitySample {
                        latestHeartRate = Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
                    }
                }
            }
            store.execute(hrQuery)
        }

        // Sleep query — last night (yesterday 18:00 to now)
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            let sleepStart = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: yesterday)!
            let sleepPredicate = HKQuery.predicateForSamples(withStart: sleepStart, end: Date(), options: .strictStartDate)
            let sleepQuery = HKSampleQuery(
                sampleType: sleepType,
                predicate: sleepPredicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                DispatchQueue.main.async {
                    let asleepValues: Set<Int> = [
                        HKCategoryValueSleepAnalysis.asleep.rawValue,
                        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                    ]
                    let totalSeconds = (samples as? [HKCategorySample])?.reduce(0.0) { acc, s in
                        asleepValues.contains(s.value) ? acc + s.endDate.timeIntervalSince(s.startDate) : acc
                    } ?? 0.0
                    let hours = totalSeconds / 3600.0
                    lastNightSleepHours = hours > 0 ? hours : nil
                }
            }
            store.execute(sleepQuery)
        }
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
            VStack(spacing: 6) {
                Text("Day")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Text("\(currentDay)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(currentDay == 1 ? "Welcome to your recovery journey!" : "of your recovery journey")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                if let milestone = currentMilestone {
                    Text(milestone)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.9))
                        .clipShape(Capsule())
                        .padding(.top, 6)
                }
            }
            .padding(.vertical, 32)
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
                    .font(.system(size: 24))
                    .foregroundStyle(checkInComplete
                                     ? Color(red: 0.42, green: 0.62, blue: 0.55)
                                     : Color(red: 0.80, green: 0.55, blue: 0.45))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(checkInComplete ? "Check-in complete!" : "Daily check-in due")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text(checkInComplete
                     ? "Great work today. See you tomorrow."
                     : "Takes about 2 minutes to complete.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
            }
            Spacer()
            if !checkInComplete {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
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
            statCard(icon: "figure.walk",        value: todaySteps.map { formatSteps($0) } ?? "—",                        label: "Steps",       color: Color(red: 0.42, green: 0.62, blue: 0.55))
            statCard(icon: "figure.walk.motion", value: todayDistanceMeters.map { formatDistance($0) } ?? "—",            label: "Distance",    color: Color(red: 0.38, green: 0.55, blue: 0.75))
            statCard(icon: "heart.fill",         value: latestHeartRate.map { "\($0)" } ?? "—",                           label: "Heart rate",  color: Color(red: 0.80, green: 0.55, blue: 0.45))
            statCard(icon: "flame.fill",         value: todayActiveEnergy.map { "\($0)" } ?? "—",                         label: "Active kcal", color: Color(red: 0.85, green: 0.50, blue: 0.35))
            statCard(icon: "figure.stairs",      value: todayFlights.map { "\($0)" } ?? "—",                              label: "Flights",     color: Color(red: 0.50, green: 0.60, blue: 0.45))
            statCard(icon: "bed.double.fill",    value: lastNightSleepHours.map { String(format: "%.1f hr", $0) } ?? "—", label: "Sleep",       color: Color(red: 0.58, green: 0.48, blue: 0.72))
        }
        .padding(.horizontal, 24)
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

    private func statCard(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 8, y: 3)
        )
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
        case 7:  return "🎉 1 week milestone!"
        case 14: return "🎉 2 week milestone!"
        case 30: return "🎉 1 month milestone!"
        case 90: return "🎉 3 month milestone!"
        default: return nil
        }
    }
}

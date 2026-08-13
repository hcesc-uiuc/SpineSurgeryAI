//
//  SurgerySurveyView.swift
//

import SwiftUI

// MARK: - Models

struct MedicationEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var medicationName: String
    var doseMg: String
    var dosesToday: String
    var route: MedicationRoute
    var carriedOverFromPreviousDay: Bool = false
    var skippedToday: Bool = false

    init(
        medicationName: String = "",
        doseMg: String = "",
        dosesToday: String = "",
        route: MedicationRoute = .oral,
        carriedOverFromPreviousDay: Bool = false,
        skippedToday: Bool = false
    ) {
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.dosesToday = dosesToday
        self.route = route
        self.carriedOverFromPreviousDay = carriedOverFromPreviousDay
        self.skippedToday = skippedToday
    }

    var isEmpty: Bool {
        medicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        doseMg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        dosesToday.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum MedicationRoute: String, CaseIterable, Identifiable, Codable {
    case oral  = "oral"
    case patch = "patch"
    case other = "other"

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

struct WeekDayStatus: Identifiable {
    let id = UUID()
    let date: Date
    let isCompleted: Bool
    let isToday: Bool

    var dayNumber: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    var shortWeekday: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }

    var accessibilityDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter.string(from: date)
    }
}

// MARK: - Local Store

final class SurveyLocalStore {
    static let shared = SurveyLocalStore()
    private init() {}

    private let lastMedsKeyPrefix             = "lastMeds_"
    private let completedSurveyDatesKeyPrefix = "completedSurveyDates_"

    func saveLastMedications(_ medications: [MedicationEntry], for userID: String) {
        do {
            let cleaned = medications.map {
                MedicationEntry(
                    medicationName: $0.medicationName,
                    doseMg: $0.doseMg,
                    dosesToday: $0.dosesToday,
                    route: $0.route,
                    carriedOverFromPreviousDay: false,
                    skippedToday: false
                )
            }
            let data = try JSONEncoder().encode(cleaned)
            UserDefaults.standard.set(data, forKey: lastMedsKeyPrefix + userID)
        } catch {
            print("Failed to save medications:", error.localizedDescription)
        }
    }

    func loadLastMedications(for userID: String) -> [MedicationEntry] {
        guard let data = UserDefaults.standard.data(forKey: lastMedsKeyPrefix + userID) else {
            return []
        }
        do {
            return try JSONDecoder().decode([MedicationEntry].self, from: data)
        } catch {
            print("Failed to load medications:", error.localizedDescription)
            return []
        }
    }

    func markSurveyCompleted(on date: Date, for userID: String) {
        let key = completedSurveyDatesKeyPrefix + userID
        let existing = completedSurveyDateStrings(for: userID)
        let dateString = Self.dayFormatter.string(from: date)
        if !existing.contains(dateString) {
            UserDefaults.standard.set(existing + [dateString], forKey: key)
        }
    }

    func completedSurveyDateStrings(for userID: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: completedSurveyDatesKeyPrefix + userID) ?? []
    }

    func completedSurveyDates(for userID: String) -> Set<String> {
        Set(completedSurveyDateStrings(for: userID))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale   = Locale.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Small UI Helpers

struct CheckboxRow: View {
    let title: String
    @Binding var isChecked: Bool

    var body: some View {
        Button {
            isChecked.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))
                    .font(.system(size: 20, design: .rounded))

                Text(title)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main View

struct SurgerySurveyView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authManager: SecureAuthManager   // ← add this
    @Environment(\.dismiss) private var dismiss

    private var currentUserID: String { "default_user" }

    @State private var startUnix  = Int(Date().timeIntervalSince1970)
    @State private var finishUnix = 0

    @State private var painNRS:         Int?  = nil
    @State private var functionCheckIn: Int?  = nil
    @State private var sleepQuality:    Int?  = nil

    @State private var tookPainMedicationToday: Bool? = nil
    @State private var medications: [MedicationEntry] = []

    @State private var hadFallsSinceYesterday:    Bool? = nil
    @State private var fallInjured                      = false
    @State private var fallSoughtMedicalAttention       = false

    @State private var isSubmitting = false
    @State private var submitError: String?

    @State private var selectedCalendarDate = Date()
    @State private var completedSurveyDates: Set<String> = []

    // Blocks re-submission when the survey has already been completed today,
    // regardless of which button/entry point presented this view.
    @State private var showAlreadyCompletedAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Warm cream gradient background — matches the app's design system
                LinearGradient(
                    colors: [Color(red: 0.98, green: 0.95, blue: 0.91), Color(red: 0.95, green: 0.91, blue: 0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerSection

                        sectionCard(title: "Pain Numeric Rating Scale (NRS)") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("How would you rate your overall pain right now?")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                                nrs0to10Row(selection: $painNRS)

                                Button("Clear selection") { painNRS = nil }
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))

                                Text("0 = No pain • 10 = Worst possible pain")
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                            }
                        }

                        sectionCard(title: "Brief Function Check-In") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Compared to yesterday, my ability to get around is:")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                                singleChoiceList(
                                    choices: [
                                        (1, "Much better"),
                                        (2, "Somewhat better"),
                                        (3, "About the same"),
                                        (4, "Somewhat worse"),
                                        (5, "Much worse")
                                    ],
                                    selection: $functionCheckIn
                                )
                            }
                        }

                        sectionCard(title: "Pain Medication Intake") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Did you take any pain medication today, prescribed or over-the-counter?")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                                yesNoChoice(selection: $tookPainMedicationToday)

                                if tookPainMedicationToday == true {
                                    medicationTodaySection
                                }
                            }
                        }

                        sectionCard(title: "Sleep Quality") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("How would you rate your sleep last night?")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                                singleChoiceList(
                                    choices: [
                                        (1, "Very good"),
                                        (2, "Good"),
                                        (3, "Fair"),
                                        (4, "Poor"),
                                        (5, "Very poor")
                                    ],
                                    selection: $sleepQuality,
                                    allowClear: true,
                                    clearLabel: "Skip this question"
                                )
                            }
                        }

                        sectionCard(title: "Falls Screen") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Have you had any falls since yesterday?")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                                yesNoChoice(selection: $hadFallsSinceYesterday)

                                if hadFallsSinceYesterday == true {
                                    VStack(alignment: .leading, spacing: 8) {
                                        CheckboxRow(
                                            title: "Were you injured?",
                                            isChecked: $fallInjured
                                        )
                                        CheckboxRow(
                                            title: "Did you seek medical attention?",
                                            isChecked: $fallSoughtMedicalAttention
                                        )
                                        // Safety note — static informational text, no logic
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "cross.case.fill")
                                                .font(.system(size: 13, design: .rounded))
                                            Text("If you've been hurt in a fall, please contact your care team. If this is an emergency, call 911.")
                                                .font(.system(size: 13, design: .rounded))
                                        }
                                        .foregroundStyle(Color(red: 0.75, green: 0.25, blue: 0.22))
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color(red: 0.75, green: 0.25, blue: 0.22).opacity(0.08))
                                        )
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }

                        Text("You may skip any question that causes emotional discomfort. Skipped responses will be treated as missing data.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                            .italic()

                        submitButton

                        if let submitError {
                            Text(submitError)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Color(red: 0.75, green: 0.25, blue: 0.22))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Progress Survey")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadPersistedSurveyData()
                if appState.isCompletedToday {
                    showAlreadyCompletedAlert = true
                }
            }
            .alert("Already Completed", isPresented: $showAlreadyCompletedAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("You have already completed the survey for today. Come back tomorrow!")
            }
            .preferredColorScheme(.light)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Progress Survey")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                Text("Track your weekly survey completion and fill out today's check-in.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
            }

            weeklyCalendarSection
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
        )
    }

    private var weeklyCalendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(weekRangeTitle(for: selectedCalendarDate))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        selectedCalendarDate = Calendar.current.date(
                            byAdding: .weekOfYear, value: -1, to: selectedCalendarDate
                        ) ?? selectedCalendarDate
                    } label: {
                        Image(systemName: "chevron.left")
                    }

                    Button {
                        selectedCalendarDate = Date()
                    } label: {
                        Text("Today").font(.system(size: 13, design: .rounded))
                    }

                    Button {
                        selectedCalendarDate = Calendar.current.date(
                            byAdding: .weekOfYear, value: 1, to: selectedCalendarDate
                        ) ?? selectedCalendarDate
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.bordered)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7),
                spacing: 8
            ) {
                ForEach(weekDays(for: selectedCalendarDate)) { day in
                    Button {
                        selectedCalendarDate = day.date
                    } label: {
                        VStack(spacing: 6) {
                            Text(day.shortWeekday)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))

                            Text(day.dayNumber)
                                .font(.system(size: 16, weight: day.isToday ? .bold : .regular, design: .rounded))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                            if day.isCompleted {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundStyle(Color(red: 0.42, green: 0.62, blue: 0.55))
                            } else {
                                Spacer().frame(height: 12)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 78)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(backgroundColor(for: day))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(borderColor(for: day), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(day.accessibilityDate), \(day.isCompleted ? "completed" : "not completed")"
                    )
                }
            }
        }
    }

    private func backgroundColor(for day: WeekDayStatus) -> Color {
        if Calendar.current.isDate(day.date, inSameDayAs: selectedCalendarDate) {
            return Color(red: 0.80, green: 0.55, blue: 0.45).opacity(0.12)
        } else if day.isToday {
            return Color(red: 0.38, green: 0.55, blue: 0.75).opacity(0.08)
        } else {
            return .white
        }
    }

    private func borderColor(for day: WeekDayStatus) -> Color {
        if Calendar.current.isDate(day.date, inSameDayAs: selectedCalendarDate) {
            return Color(red: 0.80, green: 0.55, blue: 0.45)
        } else if day.isToday {
            return Color(red: 0.38, green: 0.55, blue: 0.75).opacity(0.6)
        } else {
            return Color(red: 0.80, green: 0.65, blue: 0.58).opacity(0.30)
        }
    }

    // MARK: - Section Card

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
        )
    }

    // MARK: - NRS

    private func nrs0to10Row(selection: Binding<Int?>) -> some View {
        HStack(spacing: 4) {
            ForEach(0...10, id: \.self) { value in
                Button {
                    selection.wrappedValue = value
                } label: {
                    Text("\(value)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    selection.wrappedValue == value
                                    ? Color(red: 0.80, green: 0.55, blue: 0.45).opacity(0.22)
                                    : .white
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    selection.wrappedValue == value
                                    ? Color(red: 0.80, green: 0.55, blue: 0.45) : Color(red: 0.80, green: 0.65, blue: 0.58).opacity(0.30),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Choice UI

    private func yesNoChoice(selection: Binding<Bool?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            radioRow(title: "No",  isSelected: selection.wrappedValue == false) {
                selection.wrappedValue = false
            }
            radioRow(title: "Yes", isSelected: selection.wrappedValue == true) {
                selection.wrappedValue = true
            }
        }
    }

    private func singleChoiceList(
        choices: [(Int, String)],
        selection: Binding<Int?>,
        allowClear: Bool = false,
        clearLabel: String = "Clear"
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(choices, id: \.0) { value, label in
                radioRow(title: label, isSelected: selection.wrappedValue == value) {
                    selection.wrappedValue = value
                }
            }

            if allowClear {
                Button(clearLabel) { selection.wrappedValue = nil }
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))
                    .padding(.top, 2)
            }
        }
    }

    private func radioRow(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))

                Text(title)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Medications

    private var medicationTodaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Medications for today")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

            Text("Yesterday's medications appear first. For those, you can update the dose or number of doses for today, or mark them as skipped if you did not take them.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))

            ForEach(medications.indices, id: \.self) { index in
                medicationEntryCard(
                    entry: $medications[index],
                    onDelete: {
                        medications.remove(at: index)
                        if medications.isEmpty {
                            medications.append(MedicationEntry())
                        }
                    }
                )
            }

            Button {
                medications.append(
                    MedicationEntry(
                        medicationName: "",
                        doseMg: "",
                        dosesToday: "",
                        route: .oral,
                        carriedOverFromPreviousDay: false,
                        skippedToday: false
                    )
                )
            } label: {
                Label("Add medication", systemImage: "plus.circle")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))
            }

            scoringNote
        }
    }

    private func medicationEntryCard(
        entry: Binding<MedicationEntry>,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        let isCarriedOver = entry.wrappedValue.carriedOverFromPreviousDay
        let isSkipped     = entry.wrappedValue.skippedToday

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCarriedOver ? "From yesterday" : "New medication")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                    if isCarriedOver {
                        Text("Edit dose or number of doses for today, or mark skipped if not taken.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                    }
                }

                Spacer()

                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 13, design: .rounded))
                    }
                }
            }

            if isCarriedOver {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Medication name")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))

                    Text(entry.wrappedValue.medicationName)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.80, green: 0.65, blue: 0.58).opacity(0.12))
                        )
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Medication name")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))

                    TextField("Enter medication name", text: entry.medicationName)
                        .font(.system(size: 15, design: .rounded))
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dose (mg)")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))

                    TextField("mg", text: entry.doseMg)
                        .font(.system(size: 15, design: .rounded))
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSkipped)
                        .opacity(isSkipped ? 0.55 : 1.0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Number of doses")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))

                    TextField("Enter number", text: entry.dosesToday)
                        .font(.system(size: 15, design: .rounded))
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSkipped)
                        .opacity(isSkipped ? 0.55 : 1.0)
                }
            }

            if isCarriedOver {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Route")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))

                    Text(entry.wrappedValue.route.displayName)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.80, green: 0.65, blue: 0.58).opacity(0.12))
                        )
                }

                Button {
                    entry.wrappedValue.skippedToday.toggle()
                    if entry.wrappedValue.skippedToday {
                        entry.wrappedValue.dosesToday = ""
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: entry.wrappedValue.skippedToday ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))

                        Text("Skipped medication")
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))
                            .fontWeight(entry.wrappedValue.skippedToday ? .semibold : .regular)

                        Spacer()
                    }
                    .padding(.top, 2)
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Route")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))

                    Picker("Route", selection: entry.route) {
                        ForEach(MedicationRoute.allCases) { route in
                            Text(route.displayName).tag(route)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.80, green: 0.65, blue: 0.58).opacity(0.30), lineWidth: 1)
        )
    }

    private var scoringNote: some View {
        Text("Opioid intake is auto-converted to morphine milligram equivalents (MME/day) using CDC conversion tables embedded in the app. Baseline MME is established during the preoperative period.")
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.92, green: 0.82, blue: 0.55).opacity(0.25))
            )
    }

    // MARK: - Submit

    private var submitButton: some View {
        Button {
            submitSurvey()
        } label: {
            HStack {
                Spacer()
                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Submit Survey")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.80, green: 0.55, blue: 0.45))
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    private func submitSurvey() {
        // Guard against double-submission even if this view was somehow
        // presented after the survey was already completed today.
        guard !appState.isCompletedToday else {
            showAlreadyCompletedAlert = true
            return
        }

        submitError  = nil
        isSubmitting = true

        Task {
            finishUnix = Int(Date().timeIntervalSince1970)
            let surveyJSON = buildSurveyJSON()

            do {
                try await SurveyUploader.shared.uploadSurvey(surveyJSON)

                let validMeds: [MedicationEntry] = {
                    guard tookPainMedicationToday == true else { return [] }
                    return medications.filter { !$0.isEmpty && !$0.skippedToday }.uniqueByContent()
                }()

                SurveyLocalStore.shared.saveLastMedications(validMeds, for: currentUserID)
                SurveyLocalStore.shared.markSurveyCompleted(on: Date(), for: currentUserID)
                completedSurveyDates = SurveyLocalStore.shared.completedSurveyDates(for: currentUserID)

                // Persist to SQLite so the Calendar tab and the Home weekly strip
                // (both read SQLiteSaver.fetchSurveys) reflect this completion.
                _ = SQLiteSaver.shared.insertSurvey(painScore: painNRS)

                SensorStatusStore.shared.record(.survey)

                appState.markCompletedToday()
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                submitError = "Upload failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Load Persisted Data

    private func loadPersistedSurveyData() {
        completedSurveyDates = SurveyLocalStore.shared.completedSurveyDates(for: currentUserID)

        let lastMeds = SurveyLocalStore.shared
            .loadLastMedications(for: currentUserID)
            .filter { !$0.isEmpty }

        if !lastMeds.isEmpty {
            medications = lastMeds.map {
                MedicationEntry(
                    medicationName: $0.medicationName,
                    doseMg: $0.doseMg,
                    dosesToday: $0.dosesToday,
                    route: $0.route,
                    carriedOverFromPreviousDay: true,
                    skippedToday: false
                )
            }
        } else {
            medications = [MedicationEntry()]
        }
    }

    // MARK: - JSON

    private func buildSurveyJSON() -> [String: Any] {
        let localFormatter = DateFormatter()
        localFormatter.dateStyle = .medium
        localFormatter.timeStyle  = .medium

        let medsToSend: [[String: Any]] = {
            guard tookPainMedicationToday == true else { return [] }
            return medications
                .filter { !$0.isEmpty && !$0.skippedToday }
                .uniqueByContent()
                .map { med in
                    [
                        "medication_name": med.medicationName,
                        "dose_mg":         med.doseMg,
                        "doses_today":     med.dosesToday,
                        "route":           med.route.rawValue
                    ] as [String: Any]
                }
        }()

        let skippedMedsToSend: [[String: Any]] = {
            guard tookPainMedicationToday == true else { return [] }
            return medications
                .filter {
                    $0.carriedOverFromPreviousDay && $0.skippedToday &&
                    !$0.medicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .map { med in
                    [
                        "medication_name": med.medicationName,
                        "route":           med.route.rawValue,
                        "skipped_today":   true
                    ] as [String: Any]
                }
        }()

        let questions: [String: Any] = [
            "pain_nrs_0to10":                 painNRS as Any,
            "function_checkin_1to5":           functionCheckIn as Any,
            "took_pain_medication_today":      tookPainMedicationToday as Any,
            "medications_today":               medsToSend,
            "skipped_medications_today":       skippedMedsToSend,
            "sleep_quality_1to5_optional":     sleepQuality as Any,
            "falls_since_yesterday":           hadFallsSinceYesterday as Any,
            "fall_injured_if_yes":             (hadFallsSinceYesterday == true ? fallInjured : NSNull()) as Any,
            "sought_medical_attention_if_yes": (hadFallsSinceYesterday == true ? fallSoughtMedicalAttention : NSNull()) as Any
        ]

        return [
            "survey_title":       "Progress Survey",
            "survey_start_unix":  startUnix,
            "survey_finish_unix": finishUnix,
            "survey_local_time":  localFormatter.string(from: Date()),
            "questions":          questions
        ]
    }

    // MARK: - Calendar Helpers

    private func weekDays(for anchorDate: Date) -> [WeekDayStatus] {
        let calendar = Calendar.current
        let today    = Date()
        guard let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: anchorDate)?.start else {
            return []
        }

        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startOfWeek) else {
                return nil
            }
            return WeekDayStatus(
                date:        date,
                isCompleted: completedSurveyDates.contains(dayKey(for: date)),
                isToday:     calendar.isDate(date, inSameDayAs: today)
            )
        }
    }

    private func weekRangeTitle(for date: Date) -> String {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return "This Week"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let endDate = calendar.date(byAdding: .day, value: 6, to: interval.start) ?? interval.start
        return "\(formatter.string(from: interval.start)) – \(formatter.string(from: endDate))"
    }

    private func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar   = Calendar.current
        formatter.locale     = Locale.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Deduping Helper

private extension Array where Element == MedicationEntry {
    func uniqueByContent() -> [MedicationEntry] {
        var seen = Set<String>()
        return self.filter { med in
            let key = [
                med.medicationName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                med.doseMg.trimmingCharacters(in: .whitespacesAndNewlines),
                med.dosesToday.trimmingCharacters(in: .whitespacesAndNewlines),
                med.route.rawValue
            ].joined(separator: "|")
            if seen.contains(key) { return false }
            seen.insert(key); return true
        }
    }
}

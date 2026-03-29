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

    init(
        medicationName: String = "",
        doseMg: String = "",
        dosesToday: String = "",
        route: MedicationRoute = .oral,
        carriedOverFromPreviousDay: Bool = false
    ) {
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.dosesToday = dosesToday
        self.route = route
        self.carriedOverFromPreviousDay = carriedOverFromPreviousDay
    }

    var isEmpty: Bool {
        medicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        doseMg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        dosesToday.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum MedicationRoute: String, CaseIterable, Identifiable, Codable {
    case oral = "oral"
    case patch = "patch"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

struct MedicationHistoryEntry: Identifiable, Codable {
    var id = UUID()
    var dateKey: String
    var medications: [MedicationEntry]
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

    private let lastMedsKeyPrefix = "lastMeds_"
    private let completedSurveyDatesKeyPrefix = "completedSurveyDates_"
    private let medicationHistoryKeyPrefix = "medicationHistory_"

    func saveLastMedications(_ medications: [MedicationEntry], for userID: String) {
        do {
            let cleaned = medications.map {
                MedicationEntry(
                    medicationName: $0.medicationName,
                    doseMg: $0.doseMg,
                    dosesToday: $0.dosesToday,
                    route: $0.route,
                    carriedOverFromPreviousDay: false
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

    func appendMedicationHistory(date: Date, medications: [MedicationEntry], for userID: String) {
        let key = medicationHistoryKeyPrefix + userID
        let dateKey = Self.dayFormatter.string(from: date)

        let cleaned = medications.map {
            MedicationEntry(
                medicationName: $0.medicationName,
                doseMg: $0.doseMg,
                dosesToday: $0.dosesToday,
                route: $0.route,
                carriedOverFromPreviousDay: false
            )
        }

        var history = loadMedicationHistory(for: userID)
        history.removeAll { $0.dateKey == dateKey }
        history.insert(
            MedicationHistoryEntry(dateKey: dateKey, medications: cleaned),
            at: 0
        )

        do {
            let data = try JSONEncoder().encode(Array(history.prefix(14)))
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("Failed to save medication history:", error.localizedDescription)
        }
    }

    func loadMedicationHistory(for userID: String) -> [MedicationHistoryEntry] {
        let key = medicationHistoryKeyPrefix + userID
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }

        do {
            return try JSONDecoder().decode([MedicationHistoryEntry].self, from: data)
        } catch {
            print("Failed to load medication history:", error.localizedDescription)
            return []
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale.current
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
                    .foregroundColor(.blue)
                    .font(.title3)

                Text(title)
                    .foregroundColor(.primary)

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
    @Environment(\.dismiss) private var dismiss

    private var currentUserID: String {
        "default_user"
    }

    @State private var startUnix = Int(Date().timeIntervalSince1970)
    @State private var finishUnix = 0

    @State private var painNRS: Int? = nil
    @State private var functionCheckIn: Int? = nil
    @State private var sleepQuality: Int? = nil

    @State private var tookPainMedicationToday: Bool? = nil
    @State private var medications: [MedicationEntry] = []
    @State private var medicationHistory: [MedicationHistoryEntry] = []

    @State private var hadFallsSinceYesterday: Bool? = nil
    @State private var fallInjured = false
    @State private var fallSoughtMedicalAttention = false

    @State private var isSubmitting = false
    @State private var submitError: String?

    @State private var selectedCalendarDate = Date()
    @State private var completedSurveyDates: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection

                    sectionCard(title: "Pain Numeric Rating Scale (NRS)") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("How would you rate your overall pain right now?")
                                .font(.subheadline)

                            nrs0to10Row(selection: $painNRS)

                            Button("Clear selection") {
                                painNRS = nil
                            }
                            .font(.footnote)

                            Text("0 = No pain • 10 = Worst possible pain")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }

                    sectionCard(title: "Brief Function Check-In") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Compared to yesterday, my ability to get around is:")
                                .font(.subheadline)

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
                                .font(.subheadline)

                            yesNoChoice(selection: $tookPainMedicationToday)

                            if tookPainMedicationToday == true {
                                medicationTodaySection
                            }
                        }
                    }

                    sectionCard(title: "Sleep Quality") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("How would you rate your sleep last night?")
                                .font(.subheadline)

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
                                .font(.subheadline)

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
                                }
                                .padding(.top, 4)
                            }
                        }
                    }

                    Text("You may skip any question that causes emotional discomfort. Skipped responses will be treated as missing data.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .italic()

                    submitButton

                    if let submitError {
                        Text(submitError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Progress Survey")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadPersistedSurveyData()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Progress Survey")
                    .font(.title3)
                    .fontWeight(.bold)

                Text("Track your weekly survey completion and fill out today’s check-in.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            weeklyCalendarSection
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var weeklyCalendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(weekRangeTitle(for: selectedCalendarDate))
                    .font(.headline)

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        selectedCalendarDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: selectedCalendarDate) ?? selectedCalendarDate
                    } label: {
                        Image(systemName: "chevron.left")
                    }

                    Button {
                        selectedCalendarDate = Date()
                    } label: {
                        Text("Today")
                            .font(.footnote)
                    }

                    Button {
                        selectedCalendarDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: selectedCalendarDate) ?? selectedCalendarDate
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.bordered)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                ForEach(weekDays(for: selectedCalendarDate)) { day in
                    Button {
                        selectedCalendarDate = day.date
                    } label: {
                        VStack(spacing: 6) {
                            Text(day.shortWeekday)
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            Text(day.dayNumber)
                                .font(.headline)
                                .fontWeight(day.isToday ? .bold : .regular)
                                .foregroundColor(.primary)

                            if day.isCompleted {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else {
                                Spacer()
                                    .frame(height: 12)
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
                    .accessibilityLabel("\(day.accessibilityDate), \(day.isCompleted ? "completed" : "not completed")")
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Completed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func backgroundColor(for day: WeekDayStatus) -> Color {
        if Calendar.current.isDate(day.date, inSameDayAs: selectedCalendarDate) {
            return Color.accentColor.opacity(0.12)
        } else if day.isToday {
            return Color.blue.opacity(0.08)
        } else {
            return Color(.systemBackground)
        }
    }

    private func borderColor(for day: WeekDayStatus) -> Color {
        if Calendar.current.isDate(day.date, inSameDayAs: selectedCalendarDate) {
            return .accentColor
        } else if day.isToday {
            return .blue.opacity(0.6)
        } else {
            return Color(.separator)
        }
    }

    // MARK: - Section Card

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
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
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    selection.wrappedValue == value
                                    ? Color.accentColor.opacity(0.22)
                                    : Color(.systemBackground)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    selection.wrappedValue == value ? Color.accentColor : Color(.separator),
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
            radioRow(title: "No", isSelected: selection.wrappedValue == false) {
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
                Button(clearLabel) {
                    selection.wrappedValue = nil
                }
                .font(.footnote)
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
                    .foregroundColor(.accentColor)

                Text(title)
                    .foregroundColor(.primary)

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
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Yesterday’s medications appear first. For those, you can update the dose or number of doses for today, or delete them if you did not take them.")
                .font(.footnote)
                .foregroundColor(.secondary)

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
                        carriedOverFromPreviousDay: false
                    )
                )
            } label: {
                Label("Add medication", systemImage: "plus.circle")
            }

            if !medicationHistory.isEmpty {
                medicationHistorySection
            }

            scoringNote
        }
    }

    private func medicationEntryCard(
        entry: Binding<MedicationEntry>,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        let isCarriedOver = entry.wrappedValue.carriedOverFromPreviousDay

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCarriedOver ? "From yesterday" : "New medication")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    if isCarriedOver {
                        Text("Edit dose or number of doses for today, or delete if not taken.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                            .font(.footnote)
                    }
                }
            }

            if isCarriedOver {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Medication name")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(entry.wrappedValue.medicationName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.tertiarySystemFill))
                        )
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Medication name")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("Enter medication name", text: entry.medicationName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dose (mg)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("mg", text: entry.doseMg)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Number of doses")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("Enter number", text: entry.dosesToday)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if isCarriedOver {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Route")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(entry.wrappedValue.route.displayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.tertiarySystemFill))
                        )
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Route")
                        .font(.caption)
                        .foregroundColor(.secondary)

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
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }

    private var medicationHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent medication history")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(medicationHistory.prefix(7)) { day in
                VStack(alignment: .leading, spacing: 6) {
                    Text(day.dateKey)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if day.medications.isEmpty {
                        Text("No medications recorded")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(day.medications) { med in
                            Text("\(med.medicationName) • \(med.doseMg) mg • \(med.dosesToday) dose(s)")
                                .font(.footnote)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemBackground))
                )
            }
        }
    }

    private var scoringNote: some View {
        Text("Opioid intake is auto-converted to morphine milligram equivalents (MME/day) using CDC conversion tables embedded in the app. Baseline MME is established during the preoperative period.")
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.yellow.opacity(0.18))
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
                } else {
                    Text("Submit Survey")
                        .fontWeight(.semibold)
                }
                Spacer()
            }
            .frame(height: 48)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSubmitting)
    }

    private func submitSurvey() {
        submitError = nil
        isSubmitting = true

        Task {
            finishUnix = Int(Date().timeIntervalSince1970)
            let surveyJSON = buildSurveyJSON()

            do {
                try await SurveyUploader.shared.uploadSurvey(surveyJSON)

                let validMeds: [MedicationEntry]
                if tookPainMedicationToday == true {
                    validMeds = medications
                        .filter { !$0.isEmpty }
                        .uniqueByContent()
                } else {
                    validMeds = []
                }

                SurveyLocalStore.shared.saveLastMedications(validMeds, for: currentUserID)
                SurveyLocalStore.shared.appendMedicationHistory(date: Date(), medications: validMeds, for: currentUserID)
                SurveyLocalStore.shared.markSurveyCompleted(on: Date(), for: currentUserID)

                completedSurveyDates = SurveyLocalStore.shared.completedSurveyDates(for: currentUserID)
                medicationHistory = SurveyLocalStore.shared.loadMedicationHistory(for: currentUserID)

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
        medicationHistory = SurveyLocalStore.shared.loadMedicationHistory(for: currentUserID)

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
                    carriedOverFromPreviousDay: true
                )
            }
        } else {
            medications = [
                MedicationEntry(
                    medicationName: "",
                    doseMg: "",
                    dosesToday: "",
                    route: .oral,
                    carriedOverFromPreviousDay: false
                )
            ]
        }
    }

    // MARK: - JSON

    private func buildSurveyJSON() -> [String: Any] {
        let localFormatter = DateFormatter()
        localFormatter.dateStyle = .medium
        localFormatter.timeStyle = .medium

        let medsToSend: [[String: Any]] = {
            guard tookPainMedicationToday == true else { return [] }

            let allMeds = medications
                .filter { !$0.isEmpty }
                .uniqueByContent()

            return allMeds.map { med in
                [
                    "medication_name": med.medicationName,
                    "dose_mg": med.doseMg,
                    "doses_today": med.dosesToday,
                    "route": med.route.rawValue
                ] as [String: Any]
            }
        }()

        let questions: [String: Any] = [
            "pain_nrs_0to10": painNRS as Any,
            "function_checkin_1to5": functionCheckIn as Any,
            "took_pain_medication_today": tookPainMedicationToday as Any,
            "medications_today": medsToSend,
            "sleep_quality_1to5_optional": sleepQuality as Any,
            "falls_since_yesterday": hadFallsSinceYesterday as Any,
            "fall_injured_if_yes": (hadFallsSinceYesterday == true ? fallInjured : NSNull()) as Any,
            "sought_medical_attention_if_yes": (hadFallsSinceYesterday == true ? fallSoughtMedicalAttention : NSNull()) as Any
        ]

        return [
            "survey_title": "Progress Survey",
            "survey_start_unix": startUnix,
            "survey_finish_unix": finishUnix,
            "survey_local_time": localFormatter.string(from: Date()),
            "questions": questions
        ]
    }

    // MARK: - Calendar Helpers

    private func weekDays(for anchorDate: Date) -> [WeekDayStatus] {
        let calendar = Calendar.current
        let today = Date()
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: anchorDate)

        guard let startOfWeek = weekInterval?.start else { return [] }

        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startOfWeek) else {
                return nil
            }

            let key = dayKey(for: date)

            return WeekDayStatus(
                date: date,
                isCompleted: completedSurveyDates.contains(key),
                isToday: calendar.isDate(date, inSameDayAs: today)
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
        formatter.calendar = Calendar.current
        formatter.locale = Locale.current
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

            if seen.contains(key) {
                return false
            } else {
                seen.insert(key)
                return true
            }
        }
    }
}

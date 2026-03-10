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

    init(
        medicationName: String = "",
        doseMg: String = "",
        dosesToday: String = "",
        route: MedicationRoute = .oral
    ) {
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.dosesToday = dosesToday
        self.route = route
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

// MARK: - Local Store

final class SurveyLocalStore {
    static let shared = SurveyLocalStore()
    private init() {}

    private let surveyCountKeyPrefix = "surveyCount_"
    private let lastMedsKeyPrefix = "lastMeds_"

    func surveyCount(for userID: String) -> Int {
        UserDefaults.standard.integer(forKey: surveyCountKeyPrefix + userID)
    }

    func incrementSurveyCount(for userID: String) {
        let count = surveyCount(for: userID) + 1
        UserDefaults.standard.set(count, forKey: surveyCountKeyPrefix + userID)
    }

    func saveLastMedications(_ medications: [MedicationEntry], for userID: String) {
        do {
            let data = try JSONEncoder().encode(medications)
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
}

// MARK: - Main View

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

struct SurgerySurveyView: View {

    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // Replace with real auth user id later if you have one.
    // This avoids the currentUserID compile error.
    private var currentUserID: String {
        "default_user"
    }

    // MARK: Survey timing
    @State private var startUnix = Int(Date().timeIntervalSince1970)
    @State private var finishUnix = 0

    // MARK: Auto-calculated count
    @State private var surveysFiledCount: Int = 0

    // MARK: Survey answers
    @State private var painNRS: Int = 0
    @State private var functionCheckIn: Int? = nil
    @State private var sleepQuality: Int? = nil

    @State private var tookPainMedicationToday: Bool? = nil
    @State private var medications: [MedicationEntry] = [
        MedicationEntry(),
        MedicationEntry(),
        MedicationEntry()
    ]

    @State private var previousMedicationEntries: [MedicationEntry] = []

    @State private var hadFallsSinceYesterday: Bool? = nil
    @State private var fallInjured = false
    @State private var fallSoughtMedicalAttention = false

    @State private var isSubmitting = false
    @State private var submitError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection

                    Divider()

                    sectionCard(title: "Pain Numeric Rating Scale (NRS)") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("How would you rate your overall pain right now?")
                                .font(.subheadline)

                            nrs0to10Row(selection: $painNRS)

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

                            if !previousMedicationEntries.isEmpty {
                                previousMedicationSection
                            }

                            if tookPainMedicationToday == true {
                                Text("Enter today’s medications below:")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)

                                VStack(spacing: 10) {
                                    ForEach(medications.indices, id: \.self) { index in
                                        medicationEntryCard(entry: $medications[index])
                                    }
                                }

                                Button {
                                    medications.append(MedicationEntry())
                                } label: {
                                    Label("Add medication", systemImage: "plus.circle")
                                }
                                .padding(.top, 4)

                                scoringNote
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
            .navigationTitle("Daily ePRO")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadPersistedSurveyData()
            }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily Electronic Patient-Reported Outcomes (ePRO)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                headerLine("Cohort", "All cohorts")
                headerLine("Administration", "Daily via study app, postoperative days 1–30")
                headerLine("Estimated completion time", "30–60 seconds")
                headerLine("Delivery", "Push notification from study app; participant opens app, answers questions, closes app")
            }
            .font(.footnote)
            .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Surveys submitted")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Spacer()

                    Text("\(surveysFiledCount)")
                        .font(.title3)
                        .fontWeight(.bold)
                }

                ProgressView(value: Double(surveysFiledCount), total: 30)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func headerLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(label):")
                .fontWeight(.semibold)
            Text(value)
        }
    }

    // MARK: Cards

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

    // MARK: NRS

    private func nrs0to10Row(selection: Binding<Int>) -> some View {
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

    // MARK: Choice UI

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

    // MARK: Previous Medications

    private var previousMedicationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Previous medications")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("These were carried forward from your last submitted survey.")
                .font(.footnote)
                .foregroundColor(.secondary)

            ForEach(previousMedicationEntries) { med in
                VStack(alignment: .leading, spacing: 4) {
                    Text(med.medicationName.isEmpty ? "Unnamed medication" : med.medicationName)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text("Dose: \(med.doseMg.isEmpty ? "—" : med.doseMg) mg")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Text("Previous doses: \(med.dosesToday.isEmpty ? "—" : med.dosesToday)")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Text("Route: \(med.route.displayName)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.separator), lineWidth: 1)
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemBackground))
        )
    }

    // MARK: Medication Card

    private func medicationEntryCard(entry: Binding<MedicationEntry>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Medication name")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("Enter medication name", text: entry.medicationName)
                    .textFieldStyle(.roundedBorder)
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

    // MARK: Submit

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

    // MARK: Load persisted data

    private func loadPersistedSurveyData() {
        surveysFiledCount = SurveyLocalStore.shared.surveyCount(for: currentUserID)

        let lastMeds = SurveyLocalStore.shared
            .loadLastMedications(for: currentUserID)
            .filter { !$0.isEmpty }

        previousMedicationEntries = lastMeds

        if !lastMeds.isEmpty {
            medications = lastMeds.map {
                MedicationEntry(
                    medicationName: $0.medicationName,
                    doseMg: $0.doseMg,
                    dosesToday: "",
                    route: $0.route
                )
            }
        } else {
            medications = [
                MedicationEntry(),
                MedicationEntry(),
                MedicationEntry()
            ]
        }
    }

    // MARK: Submit logic

    private func submitSurvey() {
        submitError = nil
        isSubmitting = true

        Task {
            finishUnix = Int(Date().timeIntervalSince1970)
            let surveyJSON = buildSurveyJSON()

            do {
                try await SurveyUploader.shared.uploadSurvey(surveyJSON)

                let validMeds = medications.filter { !$0.isEmpty }
                SurveyLocalStore.shared.saveLastMedications(validMeds, for: currentUserID)
                SurveyLocalStore.shared.incrementSurveyCount(for: currentUserID)
                surveysFiledCount = SurveyLocalStore.shared.surveyCount(for: currentUserID)

                appState.markCompletedToday()
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                submitError = "Upload failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: JSON

    private func buildSurveyJSON() -> [String: Any] {
        let localFormatter = DateFormatter()
        localFormatter.dateStyle = .medium
        localFormatter.timeStyle = .medium

        let medsToSend: [[String: Any]] = {
            guard tookPainMedicationToday == true else { return [] }

            return medications
                .filter { !$0.isEmpty }
                .map { med in
                    [
                        "medication_name": med.medicationName,
                        "dose_mg": med.doseMg,
                        "doses_today": med.dosesToday,
                        "route": med.route.rawValue
                    ]
                }
        }()

        let previousMedsJSON: [[String: Any]] = previousMedicationEntries.map { med in
            [
                "medication_name": med.medicationName,
                "dose_mg": med.doseMg,
                "doses_today": med.dosesToday,
                "route": med.route.rawValue
            ]
        }

        return [
            "survey_start_unix": startUnix,
            "survey_finish_unix": finishUnix,
            "survey_local_time": localFormatter.string(from: Date()),
            "survey_count_completed": surveysFiledCount + 1,
            "questions": [
                "pain_nrs_0to10": painNRS,
                "function_checkin_1to5": functionCheckIn ?? NSNull(),
                "took_pain_medication_today": tookPainMedicationToday ?? NSNull(),
                "previous_day_medications": previousMedsJSON,
                "medications_today": medsToSend,
                "sleep_quality_1to5_optional": sleepQuality ?? NSNull(),
                "falls_since_yesterday": hadFallsSinceYesterday ?? NSNull(),
                "fall_injured_if_yes": hadFallsSinceYesterday == true ? fallInjured : NSNull(),
                "sought_medical_attention_if_yes": hadFallsSinceYesterday == true ? fallSoughtMedicalAttention : NSNull()
            ]
        ]
    }
}

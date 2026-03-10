//
//  SurgerySurveyView.swift
//  SensingApp
//

import SwiftUI

struct SurgerySurveyView: View {

    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // MARK: - Survey State

    @State private var painScore: Double = 0
    @State private var mobilityScore: Double = 0
    @State private var sleepQuality: Double = 0
    @State private var tookMedication: Bool = false
    @State private var walkedOutside: String = "No"

    @State private var numbnessSelections: [String: Bool] = [
        "Lower Back": false,
        "Glutes / Hip Region": false,
        "Right Leg": false,
        "Left Leg": false,
        "Both Legs": false
    ]

    @State private var symptomSelections: [String: Bool] = [
        "Headache": false,
        "Dizziness": false,
        "Leg Tingling": false,
        "Back Stiffness": false,
        "Fatigue": false
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    sliderCard(
                        question: "What is your pain level today?",
                        value: $painScore
                    )

                    sliderCard(
                        question: "How difficult was mobility today?",
                        value: $mobilityScore
                    )

                    sliderCard(
                        question: "How was your sleep last night?",
                        value: $sleepQuality
                    )

                    toggleCard(
                        question: "Did you need extra pain medication?",
                        isOn: $tookMedication
                    )

                    pickerCard(
                        question: "Did you walk outside today?",
                        selection: $walkedOutside,
                        options: [
                            ("No", "No"),
                            ("Yes, under 10 minutes", "under10"),
                            ("Yes, 10–30 minutes", "10to30"),
                            ("Yes, over 30 minutes", "over30")
                        ]
                    )

                    multiSelectCard(
                        question: "Where did you feel numbness or tingling?",
                        selections: $numbnessSelections
                    )

                    multiSelectCard(
                        question: "Symptoms experienced today",
                        selections: $symptomSelections
                    )

                    Button(action: submitSurvey) {
                        Text("Submit Survey")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                }
                .padding()
            }
            .navigationTitle("Daily Recovery")
        }
    }

    // MARK: - Card Builders

    private func sliderCard(question: String,
                            value: Binding<Double>) -> some View {

        VStack(alignment: .leading, spacing: 12) {

            Text(question)
                .bold()

            Slider(value: value, in: 0...10, step: 1)

            Text("\(Int(value.wrappedValue))")
                .foregroundColor(.secondary)
        }
        .modifier(CardStyle())
    }

    private func toggleCard(question: String,
                            isOn: Binding<Bool>) -> some View {

        VStack(alignment: .leading) {

            Toggle(question, isOn: isOn)
                .bold()
        }
        .modifier(CardStyle())
    }

    private func pickerCard(question: String,
                            selection: Binding<String>,
                            options: [(String, String)]) -> some View {

        VStack(alignment: .leading, spacing: 12) {

            Text(question)
                .bold()

            Picker("", selection: selection) {
                ForEach(options, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .pickerStyle(.menu)
        }
        .modifier(CardStyle())
    }

    private func multiSelectCard(question: String,
                                 selections: Binding<[String: Bool]>) -> some View {

        VStack(alignment: .leading, spacing: 12) {

            Text(question)
                .bold()

            ForEach(selections.wrappedValue.keys.sorted(), id: \.self) { key in
                Button {
                    selections.wrappedValue[key]?.toggle()
                } label: {
                    HStack {
                        Text(key)
                        Spacer()
                        if selections.wrappedValue[key] == true {
                            Image(systemName: "checkmark.square.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(CardStyle())
    }

    // MARK: - Submit

    private func submitSurvey() {

        Task {
            let payload = buildSurveyJSON()

            do {
                try await SurveyUploader.shared.uploadSurvey(payload)

                appState.markCompletedToday()
                appState.clearMissedDays()

                // Cancel reminder after successful completion
                NotificationManager.shared.cancelReminder()

                dismiss()

            } catch {
                print("❌ Upload failed:", error.localizedDescription)
            }
        }
    }

    // MARK: - JSON

    private func buildSurveyJSON() -> [String: Any] {

        return [
            "user_id": "samir",
            "date": appState.todayString,
            "timestamp_unix": Int(Date().timeIntervalSince1970),

            "painScore": Int(painScore),
            "mobilityScore": Int(mobilityScore),
            "sleepQuality": Int(sleepQuality),
            "tookMedication": tookMedication,

            "walkedOutside": walkedOutside,

            "numbnessLocations": numbnessSelections
                .filter { $0.value }
                .map { $0.key },

            "symptoms": symptomSelections
                .filter { $0.value }
                .map { $0.key },

            "missedDays": appState.missedDays
        ]
    }
}

// MARK: - Card Style Modifier

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(radius: 2)
            )
    }
}

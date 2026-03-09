//
//  SurgerySurveyView.swift
//  SensingApp
//
//  Created by Samir Kurudi on 11/20/25.
//

import SwiftUI

struct SurgerySurveyView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var painScore: Double = 0
    @State private var mobilityScore: Double = 0
    @State private var sleepQuality: Double = 0
    @State private var tookMedication: Bool = false
    @State private var walkedOutside: String = "No"
    @State private var numbnessLocation: String = "none"

    // ⭐ NEW MULTI-SELECT QUESTION
    @State private var symptomSelections: [String: Bool] = [
        "Headache": false,
        "Dizziness": false,
        "Leg tingling": false,
        "Back stiffness": false,
        "Fatigue": false
    ]

    var body: some View {
        NavigationStack {
            Form {

                // ---- Pain ----
                Section("Pain Today") {
                    Text("Rate your pain (0 = none, 10 = worst)")
                    Slider(value: $painScore, in: 0...10, step: 1)
                    Text("Pain: \(Int(painScore))")
                }

                // ---- Mobility ----
                Section("Mobility") {
                    Text("Difficulty walking or moving today?")
                    Slider(value: $mobilityScore, in: 0...10, step: 1)
                    Text("Mobility Difficulty: \(Int(mobilityScore))")
                }

                // ---- Sleep ----
                Section("Sleep Quality") {
                    Text("How was your sleep last night?")
                    Slider(value: $sleepQuality, in: 0...10, step: 1)
                    Text("Sleep Quality: \(Int(sleepQuality))")
                }

                // ---- Medication ----
                Section("Medication") {
                    Toggle("Needed extra pain medication today", isOn: $tookMedication)
                }

                // ---- Daily Activity ----
                Section("Daily Activity") {
                    Picker("Did you walk outside today?", selection: $walkedOutside) {
                        Text("No").tag("No")
                        Text("Yes, under 10 minutes").tag("under10")
                        Text("Yes, 10–30 minutes").tag("10to30")
                        Text("Yes, over 30 minutes").tag("over30")
                    }
                }

                // ---- Numbness ----
                Section("Numbness / Tingling") {
                    Picker("Where did you feel it?", selection: $numbnessLocation) {
                        Text("None").tag("none")
                        Text("Lower Back").tag("lower_back")
                        Text("Glutes / Hip Region").tag("hip_glute")
                        Text("Right Leg").tag("right_leg")
                        Text("Left Leg").tag("left_leg")
                        Text("Both Legs").tag("both_legs")
                    }
                }

                // ⭐ ---- MULTI-SELECT SYMPTOMS ----
                Section("Symptoms Experienced Today (Select all that apply)") {
                    ForEach(symptomSelections.keys.sorted(), id: \.self) { symptom in
                        Toggle(symptom, isOn: Binding(
                            get: { symptomSelections[symptom] ?? false },
                            set: { symptomSelections[symptom] = $0 }
                        ))
                    }
                }

                // ---- Submit ----
                Button("Submit Survey") {
                    Task {
                        let survey = buildSurveyJSON()
                        do {
                            let fileURL = try SurveyUploader.shared.writeSurveyToFile(survey)
                            try await SurveyUploader.shared.uploadFile(fileURL)

                            appState.markCompletedToday()
                            appState.clearMissedDays()
                            dismiss()

                        } catch {
                            print("Upload failed:", error.localizedDescription)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Daily Recovery Survey")
        }
    }

    // ⭐ INCLUDE MULTI-SELECT IN JSON PAYLOAD
    private func buildSurveyJSON() -> [String: Any] {
        return [
            "user_id": "samir",
            "date": appState.todayString,
            "timestamp": Int(Date().timeIntervalSince1970),

            "painScore": Int(painScore),
            "mobilityScore": Int(mobilityScore),
            "sleepQuality": Int(sleepQuality),
            "tookMedication": tookMedication,

            "walkedOutside": walkedOutside,
            "numbnessLocation": numbnessLocation,

            "symptoms": symptomSelections
                .filter { $0.value }
                .map { $0.key },

            "missedDays": appState.missedDays
        ]
    }
}

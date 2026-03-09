//
//  ContentView.swift
//

import SwiftUI
import CoreMotion

struct ContentView: View {

    // MARK: - State
    @StateObject private var motionManager = MotionManager()
    @StateObject private var appState = AppState()

    @State private var isSurveyPresented = false
    @State private var showDeniedAlert = false

    @Environment(\.scenePhase) private var scenePhase
    let motionActivityManager = CMMotionActivityManager()

    // MARK: - Body
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    accelerometerView
                    gyroscopeView

                    Divider()

                    actionButtons
                }
                .padding()
            }
            .navigationTitle("Motion Dashboard")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundColor(.illiniOrange)
                }
            }
            .alert(
                "Motion Access Denied",
                isPresented: $showDeniedAlert,
                actions: {},
                message: {
                    Text("Enable Motion & Fitness access in Settings.")
                }
            )
            .onAppear {
                checkMotionAndFitnessAuthorization()

                // Request notification permission
                NotificationManager.shared.requestPermission()

                // Schedule daily reminder (8PM)
                NotificationManager.shared.scheduleDailyReminder(
                    hour: 20,
                    minute: 0,
                    appState: appState
                )
            }
        }
    }

    // MARK: - Accelerometer Card
    private var accelerometerView: some View {
        SensorCard(
            title: "Accelerometer",
            systemImage: "arrow.up.and.down.and.arrow.left.and.right"
        ) {
            if let d = motionManager.accelerometerData {
                valueRow("X", d.acceleration.x)
                valueRow("Y", d.acceleration.y)
                valueRow("Z", d.acceleration.z)
            } else {
                statusText("No motion detected", color: .illiniOrange)
            }
        }
    }

    // MARK: - Gyroscope Card
    private var gyroscopeView: some View {
        SensorCard(
            title: "Gyroscope",
            systemImage: "gyroscope"
        ) {
            if let g = motionManager.gyroscopeData {
                valueRow("X", g.rotationRate.x)
                valueRow("Y", g.rotationRate.y)
                valueRow("Z", g.rotationRate.z)
            } else {
                statusText("No gyro detected", color: .illiniOrange)
            }
        }
    }

    // MARK: - Buttons
    private var actionButtons: some View {
        VStack(spacing: 14) {

            Button {
                Task { await fetchRecordedData() }
            } label: {
                Label("Fetch Recorded Data", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.illiniBlue)

            Button {
                isSurveyPresented = true
            } label: {
                Label("Start Survey", systemImage: "doc.text")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.illiniOrange)
            .disabled(appState.isCompletedToday)
            .sheet(isPresented: $isSurveyPresented) {
                SurgerySurveyView(appState: appState)
            }

            // 🧪 TEST NOTIFICATION BUTTON
            Button {
                NotificationManager.shared.sendTestNotification()
            } label: {
                Label("Test Notification", systemImage: "bell.badge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.gray)
        }
    }

    // MARK: - Helpers
    private func valueRow(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
                .fontWeight(.semibold)
                .foregroundColor(.illiniBlue)

            Spacer()

            Text(String(format: "%.3f", value))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(color)
    }

    private func fetchRecordedData() async {
        AcclerometerRecorder.shared.fetchRecordedData1Min()
    }

    private func checkMotionAndFitnessAuthorization() {
        let status = CMMotionActivityManager.authorizationStatus()
        if status == .denied {
            showDeniedAlert = true
        }
    }
}

//
// MARK: - Reusable Sensor Card
//
struct SensorCard<Content: View>: View {

    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundColor(.illiniBlue)

            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.illiniBlue.opacity(0.25), lineWidth: 1)
                )
        )
        .shadow(radius: 2)
    }
}

//
// MARK: - UIUC Brand Colors
//
extension Color {
    static let illiniBlue   = Color(red: 0.07, green: 0.16, blue: 0.29)
    static let illiniOrange = Color(red: 0.91, green: 0.33, blue: 0.10)
}

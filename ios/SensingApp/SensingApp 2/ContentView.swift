//
//  ContentView.swift
//

import SwiftUI
import CoreMotion

struct ContentView: View {

    @StateObject private var motionManager = MotionManager()
    @StateObject private var appState = AppState()
    @State private var isSurveyPresented = false
    @State private var showDeniedAlert = false

    @Environment(\.scenePhase) var scenePhase
    let motionActivityManager = CMMotionActivityManager()

    var body: some View {

        VStack {
            Text("Motion Dashboard")
                .font(.title2)
                .padding()

            accelerometerView
            gyroscopeView

            Button("Fetch Recorded Data") {
                Task { await fetchRecordedData() }
            }
            .padding(.top, 20)

            Button("Start Survey") {
                isSurveyPresented = true
            }
            .disabled(appState.isCompletedToday)
            .sheet(isPresented: $isSurveyPresented) {
                SurgerySurveyView(appState: appState)
            }
        }
        .padding()
        .alert("Motion Access Denied",
               isPresented: $showDeniedAlert,
               actions: {},
               message: { Text("Enable Motion & Fitness in Settings.") }
        )
        .onLoad { checkMotionAndFitnessAuthorization() }
    }

    private var accelerometerView: some View {
        VStack {
            Text("Accelerometer")
            if let d = motionManager.accelerometerData {
                Text("x: \(d.acceleration.x)")
                Text("y: \(d.acceleration.y)")
                Text("z: \(d.acceleration.z)")
            } else {
                Text("No motion").foregroundColor(.red)
            }
        }
        .padding(.top)
    }

    private var gyroscopeView: some View {
        VStack {
            Text("Gyroscope")
            if let g = motionManager.gyroscopeData {
                Text("x: \(g.rotationRate.x)")
                Text("y: \(g.rotationRate.y)")
                Text("z: \(g.rotationRate.z)")
            } else {
                Text("No gyro").foregroundColor(.red)
            }
        }
        .padding(.top)
    }

    private func fetchRecordedData() async {
        AcclerometerRecorder.shared.fetchRecordedData1Min()
    }

    private func checkMotionAndFitnessAuthorization() {
        let status = CMMotionActivityManager.authorizationStatus()
        if status == .denied { showDeniedAlert = true }
    }
}

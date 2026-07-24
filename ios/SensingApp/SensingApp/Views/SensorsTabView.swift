//
//  SensorsTabView.swift
//  SensingApp
//
//  Sensors tab ("What We Collect"). Extracted from MainAppView.swift (was the SensorView property).
//
//  Each row shows a "Last recorded: …" freshness line from SensorStatusStore —
//  real recorder/HealthKit stamps when available, obvious "(sample)" fallback
//  otherwise. Refreshed on appear and whenever the app returns to foreground.
//

import SwiftUI

struct SensorsTabView: View {
    @Environment(\.scenePhase) private var scenePhase

    // Freshness + source lines per sensor, rebuilt by refreshStatus().
    @State private var statusLines: [SensorKind: SensorDisplay] = [:]

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
                    VStack(spacing: 24) {
                        // MOTION & ACTIVITY
                        let sage = Color(red: 0.42, green: 0.62, blue: 0.55)
                        sensorSection(title: "MOTION & ACTIVITY") {
                            sensorRow(icon: "move.3d",    color: sage, name: "Accelerometer", detail: "Movement and orientation of your phone.", kind: .accelerometer)
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "gyroscope",  color: sage, name: "Gyroscope",     detail: "Rotation and turning of your phone.", kind: .gyroscope)
                        }

                        // LOCATION
                        let warmBlue = Color(red: 0.38, green: 0.55, blue: 0.75)
                        sensorSection(title: "LOCATION") {
                            sensorRow(icon: "location.fill", color: warmBlue, name: "Location", detail: "Approximate location, including in the background.", kind: .location)
                        }

                        // APPLE HEALTH
                        let terracotta = Color(red: 0.80, green: 0.55, blue: 0.45)
                        sensorSection(title: "APPLE HEALTH") {
                            sensorRow(icon: "heart.fill",           color: terracotta, name: "Heart Rate",           detail: "Beats per minute over time.", kind: .heartRate)
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "waveform.path.ecg",    color: terracotta, name: "Heart Rate Variability", detail: "Variation between heartbeats.", kind: .heartRateVariability)
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "figure.walk",          color: terracotta, name: "Steps & Walking",      detail: "Steps, walking speed, asymmetry, and steadiness.", kind: .steps)
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "lungs.fill",           color: terracotta, name: "Blood Oxygen",         detail: "Oxygen saturation when available.", kind: .bloodOxygen)
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "flame.fill",           color: terracotta, name: "Active Energy",        detail: "Calories burned during activity.", kind: .activeEnergy)
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "bed.double.fill",      color: terracotta, name: "Sleep",                detail: "Time asleep and sleep stages.", kind: .sleep)
                        }

                        // APPLE WATCH
                        let purple = Color(red: 0.58, green: 0.48, blue: 0.72)
                        sensorSection(title: "APPLE WATCH") {
                            sensorRow(icon: "applewatch",                   color: purple, name: "Watch Accelerometer", detail: "High-rate motion from your Apple Watch.",   kind: .watchAccelerometer, badge: "Active")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "heart.fill",                   color: purple, name: "Watch Heart & PPG",   detail: "Heart rate and optical (PPG) signals.",       kind: .watchHeartPPG, badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "waveform.path.ecg.rectangle",  color: purple, name: "ECG",                 detail: "Electrocardiogram readings.",                 kind: .ecg, badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "thermometer.medium",           color: purple, name: "Wrist Temperature",   detail: "Skin temperature at the wrist.",              kind: .wristTemperature, badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "sun.max.fill",                 color: purple, name: "Ambient Light",       detail: "Surrounding light levels.",                   kind: .ambientLight, badge: "When available")
                        }

                        // DAILY SURVEY
                        sensorSection(title: "DAILY SURVEY") {
                            sensorRow(icon: "list.clipboard.fill", color: terracotta, name: "Recovery Check-in", detail: "Pain, function, medications, sleep, and falls.", kind: .survey)
                        }

                        Spacer().frame(height: 90)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("What We Collect")
        }
        .onAppear { refreshStatus() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refreshStatus() }
        }
    }

    // Rebuild every row's freshness line from the store, then ask HealthKit for
    // the genuine latest samples and rebuild again once those land.
    private func refreshStatus() {
        rebuildStatusLines()
        SensorStatusStore.shared.refreshHealthKitSamples {
            rebuildStatusLines()
        }
    }

    private func rebuildStatusLines() {
        var lines: [SensorKind: SensorDisplay] = [:]
        for kind in SensorKind.allCases {
            lines[kind] = SensorDataStore.shared.display(for: kind)
        }
        statusLines = lines
    }

    // Sensor section: uppercase header + rounded card around rows
    private func sensorSection(title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                rows()
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                    .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
            )
        }
    }

    // Sensor row: icon chip + name/detail/last-recorded + optional badge
    private func sensorRow(icon: String, color: Color, name: String, detail: String, kind: SensorKind, badge: String? = nil) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text(detail)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                if let status = statusLines[kind] {
                    Text(status.valueLine)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(color.opacity(0.9))
                        .padding(.top, 1)
                    // Where the value came from — an imported file, Apple Health,
                    // or the sample table. Never let a reading go unattributed.
                    if let source = status.sourceLine {
                        Text(source)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color(red: 0.62, green: 0.55, blue: 0.52))
                    }
                }
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

//
//  SensorsTabView.swift
//  SensingApp
//
//  Sensors tab ("What We Collect"). Read-only: no switches, because the live
//  values here are a preview and pausing them would not pause data collection.
//
//  All data comes from SensorFeed. This file is layout only.
//

import SwiftUI

struct SensorsTabView: View {

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var feed = SensorFeed.shared

    @State private var currentDay = 1

    // The TabView keeps every tab alive, so this view still receives scene-phase
    // changes while the patient is on Home. Without this guard, foregrounding
    // from any tab would switch the sensors back on.
    @State private var isVisible = false

    private let sage        = Color(red: 0.42, green: 0.62, blue: 0.55)
    private let warmBlue    = Color(red: 0.38, green: 0.55, blue: 0.75)
    private let terracotta  = Color(red: 0.80, green: 0.55, blue: 0.45)
    private let purple      = Color(red: 0.58, green: 0.48, blue: 0.72)

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

                        sensorSection("MOTION & ACTIVITY", color: sage, rows: [
                            Row(.accelerometer, "move.3d", "Movement and orientation of your phone."),
                            Row(.gyroscope, "gyroscope", "Rotation and turning of your phone.")
                        ])

                        sensorSection("LOCATION", color: warmBlue, rows: [
                            Row(.location, "location.fill", "Approximate location, including in the background.")
                        ])

                        sensorSection("PHONE USE & SURROUNDINGS", color: warmBlue, rows: [
                            // Hidden until Rabbi confirms we collect device usage.
                            // Row(.deviceUsage, "iphone", "Screen wakes, unlocks, and time in apps."),
                            Row(.phoneUsage, "phone.fill", "Number and length of calls, never their content."),
                            Row(.messagesUsage, "message.fill", "Number of messages, never their content."),
                            Row(.keyboard, "keyboard", "Typing speed and word counts, never the text."),
                            Row(.ambientLight, "sun.max.fill", "Light levels around your phone."),
                            Row(.pressure, "barometer", "Air pressure, used to estimate elevation.")
                        ])

                        sensorSection("FROM THE APPLE HEALTH APP", color: terracotta, rows: [
                            Row(.heartRate, "heart.fill", "Beats per minute over time."),
                            Row(.heartRateVariability, "waveform.path.ecg", "Variation between heartbeats."),
                            Row(.steps, "figure.walk", "Steps, walking speed, asymmetry, and steadiness."),
                            Row(.bloodOxygen, "lungs.fill", "Oxygen saturation when available."),
                            Row(.activeEnergy, "flame.fill", "Calories burned during activity."),
                            Row(.sleep, "bed.double.fill", "Time asleep and sleep stages.")
                        ])

                        sensorSection("APPLE WATCH", color: purple, rows: [
                            Row(.watchAccelerometer, "applewatch", "Movement of your wrist."),
                            Row(.watchHeartRate, "heart.fill", "Heart rate measured by the watch."),
                            Row(.watchPPG, "waveform.path", "Optical heart signal (PPG)."),
                            Row(.wristTemperature, "thermometer.medium", "Skin temperature at the wrist during sleep."),
                            Row(.wristDetection, "applewatch.radiowaves.left.and.right", "Whether the watch is being worn."),
                            Row(.watchSleep, "moon.zzz.fill", "Sleep sessions detected by the watch.")
                        ])

                        sensorSection("DAILY SURVEY", color: terracotta, rows: [
                            Row(.survey, "list.clipboard.fill", "Pain, function, medications, sleep, and falls.")
                        ])

                        dayFooter

                        Spacer().frame(height: 90)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("What We Collect")
            .onAppear {
                print("SensorsTab: appeared")
                Logger.shared.append("SensorsTab: appeared")
                isVisible = true
                currentDay = RecoveryDay.day(asOf: Date())
                // onAppear also fires while the app is restored in the background.
                if scenePhase == .active { feed.start() }
            }
            .onDisappear {
                print("SensorsTab: disappeared")
                Logger.shared.append("SensorsTab: disappeared")
                isVisible = false
                feed.stop()
            }
            .onChange(of: scenePhase) { _, newPhase in
                print("SensorsTab: app is now \(newPhase) (tab visible: \(isVisible))")
                Logger.shared.append("SensorsTab: app is now \(newPhase) (tab visible: \(isVisible))")
                if newPhase == .active {
                    currentDay = RecoveryDay.day(asOf: Date())
                    if isVisible { feed.start() }
                } else {
                    // Backgrounding does not fire .onDisappear.
                    feed.stop()
                }
            }
        }
    }

    // MARK: - Day Footer

    private var dayFooter: some View {
        Text("Day \(currentDay) of your recovery journey")
            .font(.journey(.footnote, weight: .medium))
            .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    // MARK: - Section / Row Builders

    /// One row per SensorKind: name, one-line description, live or stored value,
    /// and "Last recorded".
    private struct Row: Identifiable {
        let kind: SensorKind
        let icon: String
        let detail: String
        var id: SensorKind { kind }
        init(_ kind: SensorKind, _ icon: String, _ detail: String) {
            self.kind = kind; self.icon = icon; self.detail = detail
        }
    }

    private func sensorSection(_ title: String, color: Color, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.journey(.caption, weight: .semibold))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    if row.kind != rows.first?.kind { Divider().padding(.leading, 64) }
                    sensorRow(row, color: color)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                    .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
            )
        }
    }

    private func sensorRow(_ row: Row, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: row.icon)
                    .font(.system(.callout))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.kind.displayName)
                    .font(.journey(.callout, weight: .semibold))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text(row.detail)
                    .font(.journey(.footnote))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                if let value = feed.valueText(for: row.kind) {
                    Text(value)
                        .font(.journeyMono(.footnote))
                        .foregroundStyle(color)
                        .lineLimit(2)
                }
                Text(feed.lastRecordedText(for: row.kind))
                    .font(.journey(.caption))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
            }
            Spacer()
            if let badge = badge(for: row.kind) {
                Text(badge)
                    .font(.journey(.caption2, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func badge(for kind: SensorKind) -> String? {
        switch kind {
        case .accelerometer where !feed.isAccelerometerAvailable,
             .gyroscope where !feed.isGyroscopeAvailable:
            return "No hardware (Simulator)"
        default:
            return nil
        }
    }
}

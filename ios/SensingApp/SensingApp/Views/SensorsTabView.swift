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
    @StateObject private var feed = SensorFeed.shared

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

                        sensorSection(title: "MOTION & ACTIVITY") {
                            sensorRow(
                                icon: "move.3d", color: sage, name: "Accelerometer",
                                detail: "Movement and orientation of your phone.",
                                liveValue: feed.accelerometer,
                                badge: feed.motion.isAccelerometerAvailable ? nil : "No hardware (Simulator)"
                            )
                            Divider().padding(.leading, 64)
                            sensorRow(
                                icon: "gyroscope", color: sage, name: "Gyroscope",
                                detail: "Rotation and turning of your phone.",
                                liveValue: feed.gyroscope,
                                badge: feed.motion.isGyroscopeAvailable ? nil : "No hardware (Simulator)"
                            )
                        }

                        sensorSection(title: "LOCATION") {
                            sensorRow(
                                icon: "location.fill", color: warmBlue, name: "Location",
                                detail: "Approximate location, including in the background.",
                                liveValue: feed.location
                            )
                        }

                        sensorSection(
                            title: "FROM THE APPLE HEALTH APP",
                            trailing: {
                                Button {
                                    feed.refreshHealth()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(.caption).weight(.semibold))
                                        .foregroundStyle(terracotta)
                                }
                                .accessibilityLabel("Refresh Apple Health data")
                            }
                        ) {
                            healthRow(.heartRate, icon: "heart.fill",
                                      name: "Heart Rate",
                                      detail: "Beats per minute over time.")
                            Divider().padding(.leading, 64)
                            healthRow(.heartRateVariability, icon: "waveform.path.ecg",
                                      name: "Heart Rate Variability",
                                      detail: "Variation between heartbeats.")
                            Divider().padding(.leading, 64)
                            healthRow(.steps, icon: "figure.walk",
                                      name: "Steps & Walking",
                                      detail: "Steps, walking speed, asymmetry, and steadiness.")
                            Divider().padding(.leading, 64)
                            healthRow(.bloodOxygen, icon: "lungs.fill",
                                      name: "Blood Oxygen",
                                      detail: "Oxygen saturation when available.")
                            Divider().padding(.leading, 64)
                            healthRow(.activeEnergy, icon: "flame.fill",
                                      name: "Active Energy",
                                      detail: "Calories burned during activity.")
                            Divider().padding(.leading, 64)
                            healthRow(.sleep, icon: "bed.double.fill",
                                      name: "Sleep",
                                      detail: "Time asleep and sleep stages.")
                        }

                        // No watch-connectivity code exists yet, so these stay
                        // informational rather than faking live data.
                        sensorSection(title: "APPLE WATCH (Coming Soon)") {
                            sensorRow(icon: "applewatch", color: purple, name: "Watch Accelerometer",
                                      detail: "High-rate motion from your Apple Watch.",
                                      badge: "Not connected")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "heart.fill", color: purple, name: "Watch Heart & PPG",
                                      detail: "Heart rate and optical (PPG) signals.",
                                      badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "waveform.path.ecg.rectangle", color: purple, name: "ECG",
                                      detail: "Electrocardiogram readings.",
                                      badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "thermometer.medium", color: purple, name: "Wrist Temperature",
                                      detail: "Skin temperature at the wrist.",
                                      badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "sun.max.fill", color: purple, name: "Ambient Light",
                                      detail: "Surrounding light levels.",
                                      badge: "When available")
                        }

                        sensorSection(title: "DAILY SURVEY") {
                            sensorRow(icon: "list.clipboard.fill", color: terracotta,
                                      name: "Recovery Check-in",
                                      detail: "Pain, function, medications, sleep, and falls.")
                        }

                        dayFooter

                        Spacer().frame(height: 90)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("What We Collect")
            .onAppear {
                isVisible = true
                currentDay = RecoveryDay.day(asOf: Date())
                // onAppear also fires while the app is restored in the background.
                if scenePhase == .active { feed.start() }
            }
            .onDisappear {
                isVisible = false
                feed.stop()
            }
            .onChange(of: scenePhase) { _, newPhase in
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

    private func sensorSection<TrailingContent: View>(
        title: String,
        @ViewBuilder trailing: () -> TrailingContent = { EmptyView() },
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.journey(.caption, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                    .padding(.leading, 4)
                Spacer()
                trailing()
            }
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

    private func sensorRow(
        icon: String, color: Color, name: String, detail: String,
        liveValue: String? = nil,
        badge: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(.callout))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.journey(.callout, weight: .semibold))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text(detail)
                    .font(.journey(.footnote))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                if let liveValue {
                    Text(liveValue)
                        .font(.journeyMono(.footnote))
                        .foregroundStyle(color)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let badge {
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

    /// `name` is passed explicitly rather than taken from the enum: the raw
    /// values are internal shorthand and this list is read by older patients.
    private func healthRow(_ kind: SensorKind, icon: String, name: String, detail: String) -> some View {
        sensorRow(icon: icon, color: terracotta, name: name, detail: detail,
                  liveValue: feed.health[kind],
                  badge: feed.health[kind] == nil ? "No data" : nil)
    }
}

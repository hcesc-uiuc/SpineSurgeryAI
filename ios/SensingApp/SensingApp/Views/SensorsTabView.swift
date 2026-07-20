//
//  SensorsTabView.swift
//  SensingApp
//
//  Sensors tab ("What We Collect"). Now shows live values and lets the
//  patient toggle individual sensors on/off, instead of a static list.
//
//  DATA SOURCES:
//    Accelerometer / Gyroscope — MotionManager (CoreMotion, live @Published)
//    Location                  — LiveLocationManager (new, CoreLocation live @Published)
//    Apple Health metrics      — HealthKitManager.trialData (background-observer driven)
//    SensorKit                 — SensorKitManager (authorization only — no live
//                                 value shown here because SensorKitAccelerometerFetcher's
//                                 code wasn't available to wire up a live reading)
//    Apple Watch                — left informational-only; no watch connectivity
//                                 code exists yet in this project to source real values
//

import SwiftUI
import CoreMotion
import CoreLocation

struct SensorsTabView: View {

    @StateObject private var motionManager   = MotionManager()
    @StateObject private var healthManager   = HealthKitManager()
    @StateObject private var sensorKitManager = SensorKitManager()
    @StateObject private var locationManager  = LiveLocationManager.shared

    private let sage        = Color(red: 0.42, green: 0.62, blue: 0.55)
    private let warmBlue    = Color(red: 0.38, green: 0.55, blue: 0.75)
    private let terracotta  = Color(red: 0.80, green: 0.55, blue: 0.45)
    private let purple      = Color(red: 0.58, green: 0.48, blue: 0.72)

    // Master switch reflects motion + location only (Health/SensorKit are
    // permission-gated and can't be silently toggled without a system prompt).
    // Only counts sensors that actually exist on this device/simulator, so it
    // isn't permanently stuck "off" when running somewhere without real
    // accelerometer/gyroscope hardware (e.g. the Simulator).
    private var allCoreSensorsOn: Bool {
        let accelOK = !motionManager.isAccelerometerAvailable || motionManager.isAccelerometerActive
        let gyroOK  = !motionManager.isGyroscopeAvailable || motionManager.isGyroscopeActive
        return accelOK && gyroOK && locationManager.isTracking
    }

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

                        masterControlCard

                        // MOTION & ACTIVITY
                        sensorSection(title: "MOTION & ACTIVITY") {
                            if motionManager.isAccelerometerAvailable {
                                sensorRow(
                                    icon: "move.3d", color: sage, name: "Accelerometer",
                                    detail: "Movement and orientation of your phone.",
                                    liveValue: accelerometerText,
                                    isOn: Binding(
                                        get: { motionManager.isAccelerometerActive },
                                        set: { motionManager.setAccelerometerEnabled($0) }
                                    )
                                )
                            } else {
                                sensorRow(
                                    icon: "move.3d", color: sage, name: "Accelerometer",
                                    detail: "Movement and orientation of your phone.",
                                    badge: "No hardware (Simulator)"
                                )
                            }
                            Divider().padding(.leading, 64)
                            if motionManager.isGyroscopeAvailable {
                                sensorRow(
                                    icon: "gyroscope", color: sage, name: "Gyroscope",
                                    detail: "Rotation and turning of your phone.",
                                    liveValue: gyroscopeText,
                                    isOn: Binding(
                                        get: { motionManager.isGyroscopeActive },
                                        set: { motionManager.setGyroscopeEnabled($0) }
                                    )
                                )
                            } else {
                                sensorRow(
                                    icon: "gyroscope", color: sage, name: "Gyroscope",
                                    detail: "Rotation and turning of your phone.",
                                    badge: "No hardware (Simulator)"
                                )
                            }
                        }

                        // LOCATION
                        sensorSection(title: "LOCATION") {
                            sensorRow(
                                icon: "location.fill", color: warmBlue, name: "Location",
                                detail: "Approximate location, including in the background.",
                                liveValue: locationText,
                                isOn: Binding(
                                    get: { locationManager.isTracking },
                                    set: { locationManager.setTracking($0) }
                                )
                            )
                        }

                        // APPLE HEALTH
                        sensorSection(
                            title: "APPLE HEALTH",
                            trailing: {
                                AnyView(
                                    Button {
                                        healthManager.refreshWithNewRange(days: 1) { _ in }
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(terracotta)
                                    }
                                )
                            }
                        ) {
                            healthRow(.heartRate, icon: "heart.fill", detail: "Beats per minute over time.")
                            Divider().padding(.leading, 64)
                            healthRow(.hrv, icon: "waveform.path.ecg", detail: "Variation between heartbeats.")
                            Divider().padding(.leading, 64)
                            healthRow(.steps, icon: "figure.walk", detail: "Steps recorded today.")
                            Divider().padding(.leading, 64)
                            healthRow(.oxygen, icon: "lungs.fill", detail: "Oxygen saturation when available.")
                            Divider().padding(.leading, 64)
                            healthRow(.calories, icon: "flame.fill", detail: "Calories burned during activity.")
                            Divider().padding(.leading, 64)
                            sleepRow
                        }

                        // APPLE WATCH — no watch-connectivity code exists yet in the
                        // project, so this stays informational rather than faking live data.
                        sensorSection(title: "APPLE WATCH") {
                            sensorRow(icon: "applewatch", color: purple, name: "Watch Accelerometer", detail: "High-rate motion from your Apple Watch.", badge: "Not connected")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "heart.fill", color: purple, name: "Watch Heart & PPG", detail: "Heart rate and optical (PPG) signals.", badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "waveform.path.ecg.rectangle", color: purple, name: "ECG", detail: "Electrocardiogram readings.", badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "thermometer.medium", color: purple, name: "Wrist Temperature", detail: "Skin temperature at the wrist.", badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "sun.max.fill", color: purple, name: "Ambient Light", detail: "Surrounding light levels.", badge: "When available")
                        }

                        // SENSORKIT
                        sensorSection(title: "DEVICE SENSORS") {
                            sensorRow(
                                icon: "iphone.radiowaves.left.and.right", color: warmBlue,
                                name: "SensorKit Accelerometer",
                                detail: "Background device motion signals.",
                                badge: sensorKitManager.isAuthorized ? "Authorized" : "Not authorized"
                            )
                            .onTapGesture {
                                if !sensorKitManager.isAuthorized {
                                    sensorKitManager.requestAuthorization()
                                }
                            }
                        }

                        // DAILY SURVEY
                        sensorSection(title: "DAILY SURVEY") {
                            sensorRow(icon: "list.clipboard.fill", color: terracotta, name: "Recovery Check-in", detail: "Pain, function, medications, sleep, and falls.")
                        }

                        Spacer().frame(height: 90)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("What We Collect")
            .onAppear {
                locationManager.start()
                healthManager.refreshWithNewRange(days: 1) { _ in }
            }
        }
    }

    // MARK: - Master Control Card

    private var masterControlCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(sage.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: allCoreSensorsOn ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .foregroundStyle(sage)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(allCoreSensorsOn ? "All sensors active" : "Some sensors paused")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text("Motion, gyroscope, and location tracking")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { allCoreSensorsOn },
                set: { newValue in
                    motionManager.setAccelerometerEnabled(newValue)
                    motionManager.setGyroscopeEnabled(newValue)
                    locationManager.setTracking(newValue)
                }
            ))
            .labelsHidden()
            .tint(sage)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
        )
    }

    // MARK: - Live Value Formatting

    private var accelerometerText: String? {
        guard let a = motionManager.accelerometerData?.acceleration else { return nil }
        return String(format: "x: %.2f  y: %.2f  z: %.2f g", a.x, a.y, a.z)
    }

    private var gyroscopeText: String? {
        guard let r = motionManager.gyroscopeData?.rotationRate else { return nil }
        return String(format: "x: %.2f  y: %.2f  z: %.2f rad/s", r.x, r.y, r.z)
    }

    private var locationText: String? {
        guard let c = locationManager.coordinate else { return nil }
        let acc = locationManager.horizontalAccuracy.map { String(format: " (±%.0fm)", $0) } ?? ""
        return String(format: "%.4f, %.4f%@", c.latitude, c.longitude, acc)
    }

    private func latestHealthPoint(_ metric: SupportedMetric) -> HealthKitManager.RawDataPoint? {
        healthManager.trialData.first { $0.type == metric.rawValue }
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
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
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

    // Generic sensor row: icon chip + name/detail + live value / toggle / badge
    private func sensorRow(
        icon: String, color: Color, name: String, detail: String,
        liveValue: String? = nil,
        isOn: Binding<Bool>? = nil,
        badge: String? = nil
    ) -> some View {
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
                Text(liveValue ?? detail)
                    .font(.system(size: 13, design: liveValue != nil ? .monospaced : .rounded))
                    .foregroundStyle(liveValue != nil ? color : Color(red: 0.50, green: 0.42, blue: 0.39))
                    .lineLimit(1)
            }
            Spacer()
            if let isOn {
                Toggle("", isOn: isOn).labelsHidden().tint(color)
            } else if let badge {
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
        .contentShape(Rectangle())
    }

    // Health row backed by the most recent HealthKit sample for that metric
    private func healthRow(_ metric: SupportedMetric, icon: String, detail: String) -> some View {
        let point = latestHealthPoint(metric)
        let isFresh = point.map { Date().timeIntervalSince($0.startDate) < 300 } ?? false
        let valueText: String? = point.map { p in
            String(format: "%.1f %@", p.value ?? 0, p.unit)
        }

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(terracotta.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(terracotta)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.rawValue)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text(valueText ?? detail)
                    .font(.system(size: 13, design: valueText != nil ? .monospaced : .rounded))
                    .foregroundStyle(valueText != nil ? terracotta : Color(red: 0.50, green: 0.42, blue: 0.39))
                    .lineLimit(1)
            }
            Spacer()
            if valueText != nil {
                HStack(spacing: 4) {
                    Circle()
                        .fill(isFresh ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(isFresh ? "Recent" : "Older")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(isFresh ? .green : .orange)
                }
            } else {
                Text("No data")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // Sleep is summarized from full nights rather than a single sample
    private var sleepRow: some View {
        let summary = healthManager.nightSummaries.first
        let valueText = summary.map { String(format: "%.1f hrs asleep", $0.totalAsleepSeconds / 3600) }

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(terracotta.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(terracotta)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Sleep")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text(valueText ?? "Time asleep and sleep stages.")
                    .font(.system(size: 13, design: valueText != nil ? .monospaced : .rounded))
                    .foregroundStyle(valueText != nil ? terracotta : Color(red: 0.50, green: 0.42, blue: 0.39))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

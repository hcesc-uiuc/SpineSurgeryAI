//
//  SensorsTabView.swift
//  SensingApp
//
//  Sensors tab ("What We Collect"). Shows live values, lets the patient toggle
//  individual sensors on/off, AND reports when each sensor last produced data
//  and where that reading came from.
//
//  The two halves answer different questions and are deliberately both shown:
//    "live value"     — what the sensor is reading RIGHT NOW (streaming).
//    "Last recorded"  — when data last landed, and its provenance (an imported
//                       file, Apple Health, or the DEBUG sample table). A live
//                       reading says nothing about whether anything was stored.
//
//  DATA SOURCES:
//    Accelerometer / Gyroscope — MotionManager (CoreMotion, live @Published)
//    Location                  — LiveLocationManager (CoreLocation, live @Published)
//    Apple Health metrics      — HealthKitManager.trialData (background-observer driven)
//    SensorKit                 — SensorKitManager (authorization only)
//    Apple Watch               — informational only; no watch connectivity yet
//    "Last recorded" lines     — SensorStatusStore (recorder/HealthKit stamps,
//                                imported files, DEBUG sample fallback)
//

import SwiftUI
import CoreMotion
import CoreLocation

struct SensorsTabView: View {

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var motionManager    = MotionManager()
    @StateObject private var healthManager    = HealthKitManager()
    @StateObject private var sensorKitManager = SensorKitManager()
    @StateObject private var locationManager  = LiveLocationManager.shared

    // Freshness + source lines per sensor, rebuilt by refreshStatus().
    @State private var statusLines: [SensorKind: SensorDisplay] = [:]

    // Live-preview power management. These streams cost real battery - 10 Hz
    // accelerometer + 10 Hz gyro delivered onto the main queue, and continuous
    // GPS at kCLLocationAccuracyBest - so they must not run while nobody is
    // looking at them. Left running they also pin the whole process at best
    // accuracy, which defeats AdaptiveLocationManager's power tuning (it drops
    // to kCLLocationAccuracyKilometer when the patient is stationary).
    //
    // `isVisible` gates the scenePhase resume: this view stays alive inside the
    // TabView while other tabs are shown, so foregrounding the app must not
    // restart the sensors unless the Sensors tab is the one actually on screen.
    @State private var isVisible = false
    @State private var isSuspended = false
    @State private var resumeAccelerometer = false
    @State private var resumeGyroscope = false

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
                                    kind: .accelerometer,
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
                                    kind: .accelerometer,
                                    badge: "No hardware (Simulator)"
                                )
                            }
                            Divider().padding(.leading, 64)
                            if motionManager.isGyroscopeAvailable {
                                sensorRow(
                                    icon: "gyroscope", color: sage, name: "Gyroscope",
                                    detail: "Rotation and turning of your phone.",
                                    kind: .gyroscope,
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
                                    kind: .gyroscope,
                                    badge: "No hardware (Simulator)"
                                )
                            }
                        }

                        // LOCATION
                        sensorSection(title: "LOCATION") {
                            sensorRow(
                                icon: "location.fill", color: warmBlue, name: "Location",
                                detail: "Approximate location, including in the background.",
                                kind: .location,
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
                                Button {
                                    healthManager.refreshWithNewRange(days: 1) { _ in }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(terracotta)
                                }
                            }
                        ) {
                            healthRow(.heartRate, icon: "heart.fill", kind: .heartRate,
                                      name: "Heart Rate",
                                      detail: "Beats per minute over time.")
                            Divider().padding(.leading, 64)
                            healthRow(.hrv, icon: "waveform.path.ecg", kind: .heartRateVariability,
                                      name: "Heart Rate Variability",
                                      detail: "Variation between heartbeats.")
                            Divider().padding(.leading, 64)
                            healthRow(.steps, icon: "figure.walk", kind: .steps,
                                      name: "Steps & Walking",
                                      detail: "Steps, walking speed, asymmetry, and steadiness.")
                            Divider().padding(.leading, 64)
                            healthRow(.oxygen, icon: "lungs.fill", kind: .bloodOxygen,
                                      name: "Blood Oxygen",
                                      detail: "Oxygen saturation when available.")
                            Divider().padding(.leading, 64)
                            healthRow(.calories, icon: "flame.fill", kind: .activeEnergy,
                                      name: "Active Energy",
                                      detail: "Calories burned during activity.")
                            Divider().padding(.leading, 64)
                            sleepRow
                        }

                        // APPLE WATCH — no watch-connectivity code exists yet in the
                        // project, so this stays informational rather than faking live data.
                        sensorSection(title: "APPLE WATCH") {
                            sensorRow(icon: "applewatch", color: purple, name: "Watch Accelerometer",
                                      detail: "High-rate motion from your Apple Watch.",
                                      kind: .watchAccelerometer, badge: "Not connected")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "heart.fill", color: purple, name: "Watch Heart & PPG",
                                      detail: "Heart rate and optical (PPG) signals.",
                                      kind: .watchHeartPPG, badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "waveform.path.ecg.rectangle", color: purple, name: "ECG",
                                      detail: "Electrocardiogram readings.",
                                      kind: .ecg, badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "thermometer.medium", color: purple, name: "Wrist Temperature",
                                      detail: "Skin temperature at the wrist.",
                                      kind: .wristTemperature, badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "sun.max.fill", color: purple, name: "Ambient Light",
                                      detail: "Surrounding light levels.",
                                      kind: .ambientLight, badge: "When available")
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
                            sensorRow(icon: "list.clipboard.fill", color: terracotta,
                                      name: "Recovery Check-in",
                                      detail: "Pain, function, medications, sleep, and falls.",
                                      kind: .survey)
                        }

                        Spacer().frame(height: 90)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("What We Collect")
            .onAppear {
                isVisible = true
                resumeLivePreview()
                healthManager.refreshWithNewRange(days: 1) { _ in }
                refreshStatus()
            }
            .onDisappear {
                isVisible = false
                suspendLivePreview()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    refreshStatus()
                    if isVisible { resumeLivePreview() }
                } else {
                    // Backgrounding does not fire .onDisappear, so without this
                    // the streams keep running with the phone in a pocket.
                    suspendLivePreview()
                }
            }
        }
    }

    // MARK: - Live Preview Power Management

    // Stop the streaming sensors while the tab is off screen or the app is
    // backgrounded. Which motion streams were running is remembered so that
    // resuming restores exactly that set, rather than forcing both back on and
    // silently overriding a toggle the patient had switched off.
    private func suspendLivePreview() {
        guard !isSuspended else { return }
        isSuspended = true
        resumeAccelerometer = motionManager.isAccelerometerActive
        resumeGyroscope     = motionManager.isGyroscopeActive
        motionManager.setAccelerometerEnabled(false)
        motionManager.setGyroscopeEnabled(false)
        locationManager.stop()
    }

    // Restore whatever was suspended. On the very first appear nothing has been
    // suspended yet and MotionManager's initialiser has already started both
    // streams, so only location needs starting - which is exactly what this view
    // did before, leaving the toggles' own behaviour unchanged.
    private func resumeLivePreview() {
        if isSuspended {
            isSuspended = false
            if resumeAccelerometer { motionManager.setAccelerometerEnabled(true) }
            if resumeGyroscope     { motionManager.setGyroscopeEnabled(true) }
        }
        locationManager.start()
    }

    // MARK: - Freshness / Provenance

    // Show what the store already knows, then catch up on both live sources:
    // any data file dropped into the Documents folder since we were last here,
    // and the genuine latest HealthKit samples. Each rebuilds the rows as it
    // lands, so the tab is never blank waiting on I/O.
    private func refreshStatus() {
        rebuildStatusLines()
        Task {
            // Blocking file I/O — keep it off the main actor. Captures nothing,
            // so it is safe to detach.
            await Task.detached { _ = SensorFileImporter.autoIngestInbox() }.value
            rebuildStatusLines()
            SensorStatusStore.shared.refreshHealthKitSamples {
                rebuildStatusLines()
            }
        }
    }

    private func rebuildStatusLines() {
        var lines: [SensorKind: SensorDisplay] = [:]
        for kind in SensorKind.allCases {
            lines[kind] = SensorStatusStore.shared.display(for: kind)
        }
        statusLines = lines
    }

    // The "Last recorded: …" pair shown under every row that maps to a
    // SensorKind. Split out so the generic row, the health rows and the sleep
    // row all render provenance identically.
    @ViewBuilder
    private func statusLines(for kind: SensorKind?, accent: Color) -> some View {
        if let kind, let status = statusLines[kind] {
            Text(status.valueLine)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(accent.opacity(0.9))
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

    // Generic sensor row: icon chip + name/detail, optional live value, the
    // last-recorded pair, and a trailing toggle or badge.
    private func sensorRow(
        icon: String, color: Color, name: String, detail: String,
        kind: SensorKind? = nil,
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
                Text(detail)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                if let liveValue {
                    Text(liveValue)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(color)
                        .lineLimit(1)
                }
                statusLines(for: kind, accent: color)
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

    // Health row backed by the most recent HealthKit sample for that metric.
    // The Recent/Older pip describes the LIVE sample; the "Last recorded" pair
    // below describes what the store actually holds, which may be an import.
    //
    // `name` is passed explicitly rather than taken from `metric.rawValue`:
    // the raw values are internal shorthand ("HRV", "Oxygen", "Calories") and
    // this list is read by older post-surgery patients.
    private func healthRow(_ metric: SupportedMetric, icon: String, kind: SensorKind, name: String, detail: String) -> some View {
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
                Text(name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text(detail)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                if let valueText {
                    Text(valueText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(terracotta)
                        .lineLimit(1)
                }
                statusLines(for: kind, accent: terracotta)
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
                Text("Time asleep and sleep stages.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                if let valueText {
                    Text(valueText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(terracotta)
                        .lineLimit(1)
                }
                statusLines(for: .sleep, accent: terracotta)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

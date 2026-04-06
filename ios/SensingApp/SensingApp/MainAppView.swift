//
//  MainAppView.swift
//
//  Merged: polished Journey UI (local) + full sensor/data logic (GitHub)
//  All original functionality preserved. UI upgraded with tab structure,
//  HomeView, SettingsView, and placeholder tabs from the local build.
//

import SwiftUI
import CoreMotion
import CoreLocation

// ============================================================
// MARK: - Tab Definition
// ============================================================
//
// Centralizes all tab metadata — icon, label, accent color.
// Add new tabs here and route them in MainAppView.tabContent().
//
enum JourneyTab: CaseIterable {
    case home, sensors, surveys, progress, debug, settings

    var icon: String {
        switch self {
        case .home:     return "house.fill"
        case .sensors:  return "waveform"
        case .surveys:  return "list.clipboard.fill"
        case .progress: return "chart.line.uptrend.xyaxis"
        case .debug:    return "ant.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var label: String {
        switch self {
        case .home:     return "Home"
        case .sensors:  return "Sensors"
        case .surveys:  return "Surveys"
        case .progress: return "Progress"
        case .debug:    return "Debug"
        case .settings: return "Settings"
        }
    }

    var accentColor: Color {
        switch self {
        case .home:     return Color(red: 0.42, green: 0.62, blue: 0.55) // sage green
        case .sensors:  return Color(red: 0.38, green: 0.55, blue: 0.75) // warm blue
        case .surveys:  return Color(red: 0.80, green: 0.55, blue: 0.45) // terracotta
        case .progress: return Color(red: 0.38, green: 0.55, blue: 0.75) // warm blue
        case .debug:    return Color(red: 0.55, green: 0.47, blue: 0.44) // muted brown
        case .settings: return Color(red: 0.58, green: 0.48, blue: 0.72) // muted purple
        }
    }
}

// ============================================================
// MARK: - MainAppView
// ============================================================
//
// Root view shown after successful login + permissions grant.
// Hosts a TabView — each tab has its own accent color.
// All sensor, HealthKit, location, and background task logic
// from the original GitHub version is fully preserved here.
//
struct MainAppView: View {

    // Injected from AuthLoginView — triggers logout + returns to login screen
    var onLogout: () -> Void

    // ── GitHub: all original state preserved ──────────────────
    @StateObject private var motionManager = MotionManager()
    @StateObject private var appState = AppState()
    @State private var isSurveyPresented = false
    @State private var showDeniedAlert = false
    @State private var showSettingsAlert = false
    @StateObject var HKManager = HealthKitManager()
    @Environment(\.scenePhase) var scenePhase
    let motionActivityManager = CMMotionActivityManager()

    // ── Local: tab selection state ────────────────────────────
    @State private var selectedTab: JourneyTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(JourneyTab.allCases, id: \.self) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.label, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        // Accent color updates as selected tab changes
        .tint(selectedTab.accentColor)
        // ── GitHub: scene phase handling (background tasks, logging) ──
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                print("App moved to background")
                BackgroundScheduler.shared.scheduleAppRefresh()
                BackgroundScheduler.shared.scheduleBGProcessingTask()
                Logger.shared.append("App moved to background")
            } else if newPhase == .active {
                print("App moved to foreground")
                Logger.shared.append("App moved to foreground")
            } else if newPhase == .inactive {
                print("App is inactive")
                Logger.shared.append("App moved to inactive")
            }
        }
    }

    // ============================================================
    // MARK: - Tab Content Router
    // ============================================================
    //
    // Routes each tab to its view.
    // Replace placeholder views here as screens get built out.
    //
    @ViewBuilder
    private func tabContent(for tab: JourneyTab) -> some View {
        switch tab {
        case .home:
            HomeView(accentColor: tab.accentColor)
        case .sensors:
            SensorView
        case .surveys:
            SurveysView(accentColor: tab.accentColor, appState: appState, isSurveyPresented: $isSurveyPresented)
        case .progress:
            ProgressPlaceholderView(accentColor: tab.accentColor)
        case .debug:
            DebugView
        case .settings:
            SettingsView(accentColor: tab.accentColor, onLogout: onLogout)
        }
    }

    // ============================================================
    // MARK: - Sensor Tab (GitHub — fully preserved)
    // ============================================================

    private var SensorView: some View {
        NavigationStack {
            VStack {
                Text("Sensor view")
                    .font(.title2)
                    .padding()

                accelerometerView
                gyroscopeView
            }
            .navigationTitle("Sensors")
        }
    }

    // ============================================================
    // MARK: - Debug Tab (GitHub — fully preserved)
    // ============================================================

    private var DebugView: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Debug Screen")
                    .font(.title2)
                    .padding()

                Button("Fetch Recorded Data") {
                    Task { await fetchRecordedData() }
                }

                Button("Fetch data") {
                    Task { await self.fetchRecordedData() }
                }

                Button("Print schedule bg task") {
                    Task { BackgroundScheduler.shared.printScheduledBackgroundTasks() }
                }

                Button("Upload File") {
                    Task {
                        print("Upload function called")
                        let filename = "log_2026-02-19.txt"
                        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        let fileURL = dir.appendingPathComponent(filename)
                        Uploader.shared.uploadFile(fileURL: fileURL)
                    }
                }

                Button("Upload All Files") {
                    Task { Uploader.shared.uploadFolder() }
                }

                Button("Print log data") {
                    Task { self.printCurrentLogFile() }
                }

                Button("Get HealthKit data") {
                    Task { self.getHealthKitData() }
                }

                if CLLocationManager().authorizationStatus != .authorizedAlways {
                    Button("Always allow location") {
                        Task { showSettingsAlert = true }
                    }
                }

                if CLLocationManager().authorizationStatus == .authorizedAlways {
                    Text("Always allow location granted")
                }
            }
            .padding()
            .navigationTitle("Debug")
            .alert("Motion Access Denied",
                   isPresented: $showDeniedAlert,
                   actions: {},
                   message: { Text("Enable Motion & Fitness in Settings.") }
            )
            .alert("Location Access Required", isPresented: $showSettingsAlert) {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                Button("Not Now", role: .cancel) { }
            } message: {
                Text("Please open Settings and set location access to Always Allow so we can track your location in the background.")
            }
            .onLoad {
                checkMotionAndFitnessAuthorization()
                checkLocationAuthorization()
            }
        }
    }

    // ============================================================
    // MARK: - Sensor Subviews (GitHub — fully preserved)
    // ============================================================

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

    // ============================================================
    // MARK: - GitHub Data + Permission Functions (fully preserved)
    // ============================================================

    private func getHealthKitData() {
        print("Requesting: HKManager.refreshWithNewRange")
        HKManager.refreshWithNewRange(days: 7)
        print("Requesting: HKManager.trialData. Len:\(HKManager.trialData.count)")
        for (index, point) in HKManager.trialData.enumerated() {
            let hkDataPointString = formatRawString(
                point,
                unixStartStr: String(Int(point.startDate.timeIntervalSince1970)),
                unixEndStr: String(Int(point.endDate.timeIntervalSince1970))
            )
            print("\(index) - \(hkDataPointString)")
        }
    }

    func formatRawString(_ p: HealthKitManager.RawDataPoint, unixStartStr: String, unixEndStr: String) -> String {
        let dateStr = p.startDate.formatted(.dateTime.month().day().hour().minute().second())
        let metaStr = p.metadata.map { "\($0.key):\($0.value)" }.joined(separator: "|")
        return "[\(dateStr)] TYPE:\(p.type) | VAL:\(p.value)\(p.unit) | UNIX_START:\(unixStartStr) | UNIX_END:\(unixEndStr) | DUR:\(Float(unixEndStr)!-Float(unixStartStr)!)ms | SRC:\(p.sourceName) | BID:\(p.bundleID) | DEV:\(p.deviceName ?? "NA") | MOD:\(p.deviceModel ?? "NA") | SW:\(p.softwareVer ?? "NA") | ID:\(p.id.uuidString) | META:{\(metaStr)}"
    }

    private func fetchRecordedData() async {
        AcclerometerRecorder.shared.fetchRecordedData1Min()
    }

    private func checkLocationAuthorization() {
        let status = CLLocationManager().authorizationStatus
        if status == .denied || status == .restricted {
            showSettingsAlert = true
        }
        if status == .authorizedWhenInUse {
            showSettingsAlert = true
        }
        if status == .notDetermined {
            AdaptiveLocationManager.shared.requestPermission()
        }
    }

    private func checkMotionAndFitnessAuthorization() {
        let status = CMMotionActivityManager.authorizationStatus()
        switch status {
        case .notDetermined:
            print("Motion & Fitness permission is not determined.")
            requestMotionPermission()
        case .authorized:
            print("Motion & Fitness permission is authorized. Started recording.")
            AcclerometerRecorder.shared.startRecording()
        case .denied:
            print("Motion & Fitness permission is denied.")
            showPermissionDeniedAlert()
        case .restricted:
            print("Motion & Fitness permission is restricted.")
        @unknown default:
            print("Unknown authorization status")
        }
    }

    func requestMotionPermission() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionActivityManager.queryActivityStarting(from: Date(), to: Date(), to: .main) { _, error in
            print("Motion permission requested.")
            DispatchQueue.main.async {
                let status = CMMotionActivityManager.authorizationStatus()
                switch status {
                case .authorized:
                    print("✅ Motion permission granted")
                    AcclerometerRecorder.shared.startRecording()
                case .denied, .restricted:
                    print("❌ Motion permission denied/restricted")
                case .notDetermined:
                    print("⏳ Motion permission not determined yet")
                @unknown default:
                    print("Default")
                }
            }
        }
    }

    func showPermissionDeniedAlert() {
        showDeniedAlert = true
    }

    func printCurrentLogFile() {
        print("Current log file:", Logger.shared.currentLogFilePath())
        if let logs = Logger.shared.readAll() {
            print(logs)
        }
    }

    func startBackgroundRecordingTask() {
        if CMSensorRecorder.isAccelerometerRecordingAvailable() {
            BackgroundScheduler.shared.scheduleBGProcessingTask()
        } else {
            print("Accelerometer recording not available on this device.")
        }
    }
}

// ============================================================
// MARK: - Home View (Local — polished UI)
// ============================================================
//
// Main landing screen after login.
// TODO: Replace hardcoded values with real patient data from server.
//
struct HomeView: View {
    let accentColor: Color

    private let daysSinceSurgery = 14
    private let patientFirstName = "Username"
    private let checkInComplete  = false

    @State private var appeared = false

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
                    VStack(spacing: 20) {
                        // ── Greeting ──────────────────────────────
                        VStack(alignment: .leading, spacing: 4) {
                            Text(greetingText)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                            Text("Hi, \(patientFirstName) 👋")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.easeOut(duration: 0.45).delay(0.05), value: appeared)

                        recoveryDayCard
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)
                            .animation(.easeOut(duration: 0.45).delay(0.15), value: appeared)

                        dailyCheckInCard
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)
                            .animation(.easeOut(duration: 0.45).delay(0.25), value: appeared)

                        quickStatsRow
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)
                            .animation(.easeOut(duration: 0.45).delay(0.35), value: appeared)

                        Spacer().frame(height: 20)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.clear, for: .navigationBar)
        }
        .onAppear { appeared = true }
    }

    private var recoveryDayCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: accentColor.opacity(0.35), radius: 16, y: 8)
            VStack(spacing: 6) {
                Text("Day")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Text("\(daysSinceSurgery)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("of your recovery journey")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                if let milestone = currentMilestone {
                    Text(milestone)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.9))
                        .clipShape(Capsule())
                        .padding(.top, 6)
                }
            }
            .padding(.vertical, 32)
        }
        .padding(.horizontal, 24)
    }

    private var dailyCheckInCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(checkInComplete
                          ? Color(red: 0.42, green: 0.62, blue: 0.55).opacity(0.15)
                          : Color(red: 0.80, green: 0.55, blue: 0.45).opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: checkInComplete ? "checkmark.circle.fill" : "pencil.and.list.clipboard")
                    .font(.system(size: 24))
                    .foregroundStyle(checkInComplete
                                     ? Color(red: 0.42, green: 0.62, blue: 0.55)
                                     : Color(red: 0.80, green: 0.55, blue: 0.45))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(checkInComplete ? "Check-in complete!" : "Daily check-in due")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                Text(checkInComplete
                     ? "Great work today. See you tomorrow."
                     : "Takes about 2 minutes to complete.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
            }
            Spacer()
            if !checkInComplete {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
        )
        .padding(.horizontal, 24)
    }

    private var quickStatsRow: some View {
        HStack(spacing: 12) {
            statCard(icon: "figure.walk",          value: "2,840", label: "Steps today", color: Color(red: 0.42, green: 0.62, blue: 0.55))
            statCard(icon: "waveform.path.ecg",    value: "3/10",  label: "Pain level",  color: Color(red: 0.80, green: 0.55, blue: 0.45))
            statCard(icon: "calendar",             value: "3d",    label: "Next survey", color: Color(red: 0.38, green: 0.55, blue: 0.75))
        }
        .padding(.horizontal, 24)
    }

    private func statCard(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 8, y: 3)
        )
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var currentMilestone: String? {
        switch daysSinceSurgery {
        case 7:  return "🎉 1 week milestone!"
        case 14: return "🎉 2 week milestone!"
        case 30: return "🎉 1 month milestone!"
        case 90: return "🎉 3 month milestone!"
        default: return nil
        }
    }
}

// ============================================================
// MARK: - Surveys View (GitHub survey logic + polished shell)
// ============================================================
//
// Wraps the original SurgerySurveyView sheet into a proper tab.
// The survey button and appState logic are fully preserved.
//
struct SurveysView: View {
    let accentColor: Color
    @ObservedObject var appState: AppState
    @Binding var isSurveyPresented: Bool

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

                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(0.12))
                            .frame(width: 90, height: 90)
                        Image(systemName: "list.clipboard.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(accentColor)
                    }

                    Text(appState.isCompletedToday ? "Survey complete for today!" : "Daily Survey Ready")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                    Text(appState.isCompletedToday
                         ? "Great job! Come back tomorrow for your next check-in."
                         : "Tap below to complete your daily recovery survey.")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Button(action: { isSurveyPresented = true }) {
                        Text("Start Survey")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(appState.isCompletedToday ? Color.gray : accentColor)
                            )
                    }
                    .disabled(appState.isCompletedToday)
                    .padding(.horizontal, 40)
                    .sheet(isPresented: $isSurveyPresented) {
                        SurgerySurveyView(appState: appState)
                    }

                    Spacer()
                }
                .padding(.top, 40)
            }
            .navigationTitle("Surveys")
        }
    }
}

// ============================================================
// MARK: - Progress Placeholder (Local)
// ============================================================

struct ProgressPlaceholderView: View {
    let accentColor: Color
    var body: some View {
        NavigationStack {
            placeholderContent(
                icon:        "chart.line.uptrend.xyaxis",
                title:       "Progress",
                description: "Your recovery timeline and activity trends will appear here.",
                accentColor: accentColor
            )
            .navigationTitle("Progress")
        }
    }
}

// ============================================================
// MARK: - Settings View (Local — with logout)
// ============================================================

struct SettingsView: View {
    let accentColor: Color
    var onLogout: () -> Void
    @State private var showingLogoutAlert = false

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

                VStack(spacing: 16) {
                    // ── Profile Row ───────────────────────────────
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(accentColor.opacity(0.15))
                                .frame(width: 60, height: 60)
                            Image(systemName: "person.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(accentColor)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Patient")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            Text("Journey Study Participant")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                        }
                        Spacer()
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                            .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
                    )

                    // ── Settings Rows ─────────────────────────────
                    VStack(spacing: 0) {
                        settingsRow(icon: "bell.fill",               label: "Notifications", color: Color(red: 0.55, green: 0.48, blue: 0.75))
                        Divider().padding(.leading, 56)
                        settingsRow(icon: "lock.fill",               label: "Privacy",       color: Color(red: 0.38, green: 0.55, blue: 0.75))
                        Divider().padding(.leading, 56)
                        settingsRow(icon: "questionmark.circle.fill", label: "Help & Support", color: Color(red: 0.42, green: 0.62, blue: 0.55))
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                            .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
                    )

                    // ── Logout Button ─────────────────────────────
                    Button(action: { showingLogoutAlert = true }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Log Out")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(Color(red: 0.75, green: 0.25, blue: 0.22))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(red: 0.75, green: 0.25, blue: 0.22).opacity(0.10))
                        )
                    }

                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Settings")
            .alert("Log Out", isPresented: $showingLogoutAlert) {
                Button("Log Out", role: .destructive) { onLogout() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to log out of Journey?")
            }
        }
    }

    private func settingsRow(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
            }
            Text(label)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.75, green: 0.65, blue: 0.62))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// ============================================================
// MARK: - Shared Placeholder Helper
// ============================================================

private func placeholderContent(
    icon: String,
    title: String,
    description: String,
    accentColor: Color
) -> some View {
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
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 90, height: 90)
                Image(systemName: icon)
                    .font(.system(size: 36))
                    .foregroundStyle(accentColor)
            }
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Text(description)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// ============================================================
// MARK: - Preview
// ============================================================

#Preview {
    MainAppView(onLogout: {})
}

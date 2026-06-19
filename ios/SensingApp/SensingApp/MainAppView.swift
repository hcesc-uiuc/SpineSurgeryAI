//
//  ContentView.swift
//  SensingApp
//

import SwiftUI
import CoreMotion
import CoreLocation
import HealthKit
import UserNotifications
import SensorKit

// ============================================================
// MARK: - Tab Definition
// ============================================================

enum JourneyTab: CaseIterable {
    case home, sensors, progress
#if DEBUG
    case debug
#endif
    
    var icon: String {
        switch self {
        case .home:     return "house.fill"
        case .sensors:  return "waveform"
        case .progress: return "calendar"
#if DEBUG
        case .debug:    return "ant.fill"
#endif
        }
    }
    
    var label: String {
        switch self {
        case .home:     return "Home"
        case .sensors:  return "Sensors"
        case .progress: return "Calendar"
#if DEBUG
        case .debug:    return "Debug"
#endif
        }
    }
    
    var accentColor: Color {
        switch self {
        case .home:     return Color(red: 0.42, green: 0.62, blue: 0.55) // sage green
        case .sensors:  return Color(red: 0.38, green: 0.55, blue: 0.75) // warm blue
        case .progress: return Color(red: 0.38, green: 0.55, blue: 0.75) // warm blue
#if DEBUG
        case .debug:    return Color(red: 0.55, green: 0.47, blue: 0.44) // muted brown
#endif
        }
    }
}

// ============================================================
// MARK: - MainAppView
// ============================================================

struct MainAppView: View {
    
    @EnvironmentObject private var authManager: SecureAuthManager
    
    // Observed here so scenePhase audit can reset it and trigger
    // navigation back to PermissionsFlowView automatically
    @AppStorage("permissionsComplete") private var permissionsComplete = false
    
    @StateObject private var appState         = AppState()
    @StateObject private var sensorKitManager = SensorKitManager()
    @StateObject var HKManager                = HealthKitManager()
    
    @State private var isSurveyPresented = false
    @State private var showDeniedAlert   = false
    @State private var showSettingsAlert = false
    
    @Environment(\.scenePhase) var scenePhase
    let motionActivityManager = CMMotionActivityManager()
    
    @State private var selectedTab: JourneyTab = .home
    @State private var hasStartedCollection = false
    
    // MARK: - Body
    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(JourneyTab.home.label, systemImage: JourneyTab.home.icon, value: JourneyTab.home) {
                HomeView(accentColor: JourneyTab.home.accentColor, onLogout: { authManager.logout() }, appState: appState, isSurveyPresented: $isSurveyPresented)
            }
            Tab(JourneyTab.sensors.label, systemImage: JourneyTab.sensors.icon, value: JourneyTab.sensors) {
                SensorView
            }
            Tab(JourneyTab.progress.label, systemImage: JourneyTab.progress.icon, value: JourneyTab.progress) {
                MonthlyProgressView()
            }
#if DEBUG
            Tab(JourneyTab.debug.label, systemImage: JourneyTab.debug.icon, value: JourneyTab.debug) {
                DebugView
            }
#endif
        }
        .tint(selectedTab.accentColor)
        .overlay(alignment: .bottomTrailing) {
            if showSurveyButton { surveyButton }
        }
        .sheet(isPresented: $isSurveyPresented) {
            SurgerySurveyView(appState: appState, authManager: authManager)
        }
        .onAppear {
            guard !hasStartedCollection else { return }
            hasStartedCollection = true
            // All permissions have been granted — begin data collection.
            AcclerometerRecorder.shared.startRecording()
            // HealthkitRecorder.shared.getHealthKitData()
            // #if !targetEnvironment(simulator)
            // // SensorKitAccelerometerFetcher.shared.startRecording()
            // #endif
            BackgroundScheduler.shared.scheduleAppRefresh()
            BackgroundScheduler.shared.scheduleBGProcessingTask()
            BackgroundScheduler.shared.scheduleUploadBGTask()
            BackgroundScheduler.shared.scheduleBackgroundSensorkitFetch()
            BackgroundScheduler.shared.scheduleHealthResearchBGProcessingTask()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                print("App moved to background")
                BackgroundScheduler.shared.scheduleAppRefresh()
                BackgroundScheduler.shared.scheduleBGProcessingTask()
                BackgroundScheduler.shared.scheduleUploadBGTask()
                BackgroundScheduler.shared.scheduleBackgroundSensorkitFetch()
                BackgroundScheduler.shared.scheduleHealthResearchBGProcessingTask()
                Logger.shared.append("App moved to background")
                
            } else if newPhase == .active {
                print("App moved to foreground")
                Logger.shared.append("App moved to foreground")
                // Re-audit permissions every time app returns to foreground.
                // If user revoked a permission in Settings while backgrounded,
                // this immediately resets permissionsComplete and routes them
                // back through PermissionsFlowView before any data is missed.
                auditPermissionsOnForeground()
                
            } else if newPhase == .inactive {
                print("App is inactive")
                Logger.shared.append("App moved to inactive")
            }
        }
    }
    
    // ============================================================
    // MARK: - Survey FAB
    // ============================================================
    
    private var surveyButton: some View {
        Button(action: { isSurveyPresented = true }) {
            Image(systemName: appState.isCompletedToday ? "checkmark" : "list.clipboard.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .glassEffect(
                    .regular
                        .tint(Color(red: 0.80, green: 0.55, blue: 0.45)) // terracotta
                        .interactive(),
                    in: .circle
                )
        }
        .buttonStyle(.plain)
        .disabled(appState.isCompletedToday)
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }
    
    private var showSurveyButton: Bool {
#if DEBUG
        return selectedTab != .debug
#else
        return true
#endif
    }
    
    // ============================================================
    // MARK: - Foreground Permission Audit
    // ============================================================
    //
    // Called every time the app returns to foreground via scenePhase.
    // Checks all 5 required permissions. If any are missing, resets
    // permissionsComplete = false which causes AuthLoginView to route
    // the patient back through PermissionsFlowView immediately.
    //
    // SENSORKIT: Skipped on simulator — cannot be authorized there.
    private func auditPermissionsOnForeground() {
        // Sync checks
        // Motion: if hardware unavailable (simulator), treat as granted — mirrors requestMotion().
        let motionOK   = !CMMotionActivityManager.isActivityAvailable() ||
        CMMotionActivityManager.authorizationStatus() == .authorized
        let locationOK = CLLocationManager().authorizationStatus == .authorizedAlways
        
        // Health — check actual authorization status, not just device availability
        var healthOK = false
        if HKHealthStore.isHealthDataAvailable() {
            let store    = HKHealthStore()
            let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)!
            healthOK     = store.authorizationStatus(for: stepType) != .notDetermined
        }
        
        if !motionOK || !locationOK || !healthOK {
            permissionsComplete = false
            // Don't return — the Task below must always run to keep the
            // notifications flag in sync so PermissionsFlowView skips
            // already-granted cards correctly.
        }
        
        // Async checks — SensorKit and Notifications
        Task {
            // SensorKit — not available on simulator, skip gracefully
#if targetEnvironment(simulator)
            let sensorKitOK = true
#else
            let sensorReader = SRSensorReader(sensor: .ambientLightSensor)
            let sensorKitOK  = sensorReader.authorizationStatus == .authorized
#endif
            
            // Notifications — sync the UserDefaults flag so PermissionsFlowView
            // only shows the notifications card when it's actually revoked.
            let settings        = await UNUserNotificationCenter.current().notificationSettings()
            let notificationsOK = settings.authorizationStatus == .authorized
            UserDefaults.standard.set(notificationsOK, forKey: "journey_notifications_authorized")
            
            if !sensorKitOK || !notificationsOK {
                await MainActor.run { permissionsComplete = false }
            }
        }
    }
    
    // ============================================================
    // MARK: - Sensor Tab
    // ============================================================
    
    private var SensorView: some View {
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
                            sensorRow(icon: "move.3d",    color: sage, name: "Accelerometer", detail: "Movement and orientation of your phone.")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "gyroscope",  color: sage, name: "Gyroscope",     detail: "Rotation and turning of your phone.")
                        }
                        
                        // LOCATION
                        let warmBlue = Color(red: 0.38, green: 0.55, blue: 0.75)
                        sensorSection(title: "LOCATION") {
                            sensorRow(icon: "location.fill", color: warmBlue, name: "Location", detail: "Approximate location, including in the background.")
                        }
                        
                        // APPLE HEALTH
                        let terracotta = Color(red: 0.80, green: 0.55, blue: 0.45)
                        sensorSection(title: "APPLE HEALTH") {
                            sensorRow(icon: "heart.fill",           color: terracotta, name: "Heart Rate",           detail: "Beats per minute over time.")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "waveform.path.ecg",    color: terracotta, name: "Heart Rate Variability", detail: "Variation between heartbeats.")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "figure.walk",          color: terracotta, name: "Steps & Walking",      detail: "Steps, walking speed, asymmetry, and steadiness.")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "lungs.fill",           color: terracotta, name: "Blood Oxygen",         detail: "Oxygen saturation when available.")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "flame.fill",           color: terracotta, name: "Active Energy",        detail: "Calories burned during activity.")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "bed.double.fill",      color: terracotta, name: "Sleep",                detail: "Time asleep and sleep stages.")
                        }
                        
                        // APPLE WATCH
                        let purple = Color(red: 0.58, green: 0.48, blue: 0.72)
                        sensorSection(title: "APPLE WATCH") {
                            sensorRow(icon: "applewatch",                   color: purple, name: "Watch Accelerometer", detail: "High-rate motion from your Apple Watch.",   badge: "Active")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "heart.fill",                   color: purple, name: "Watch Heart & PPG",   detail: "Heart rate and optical (PPG) signals.",       badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "waveform.path.ecg.rectangle",  color: purple, name: "ECG",                 detail: "Electrocardiogram readings.",                 badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "thermometer.medium",           color: purple, name: "Wrist Temperature",   detail: "Skin temperature at the wrist.",              badge: "When available")
                            Divider().padding(.leading, 64)
                            sensorRow(icon: "sun.max.fill",                 color: purple, name: "Ambient Light",       detail: "Surrounding light levels.",                   badge: "When available")
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
        }
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
    
    // Sensor row: icon chip + name/detail + optional badge
    private func sensorRow(icon: String, color: Color, name: String, detail: String, badge: String? = nil) -> some View {
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
    
    // ============================================================
    // MARK: - Debug Tab
    // ============================================================
    
    private var DebugView: some View {
        VStack {
            Text("Journey app")
                .font(.title2)
                .padding()
            
            Button("Fetch Recorded Data") {
                Task { await fetchRecordedData() }
            }
            .padding(.top, 10)
            
            //            Button("Start Survey") {
            //                isSurveyPresented = true
            //            }
            //            .disabled(appState.isCompletedToday)
            //            .sheet(isPresented: $isSurveyPresented) {
            //                SurgerySurveyView(appState: appState, authManager: authManager)
            //            }
            
            //            Button("Fetch data") {
            //                Task { await self.fetchRecordedData() }
            //            }.padding(.top, 30)
            
            Button("Store Sensorkit Data") {
                Task {
                    print("SensorKit fetcher is called")
                    SensorKitAccelerometerFetcher.shared.fetchLatestData()
                }
            }.padding(.top, 20)
            
            Button("Insert 1hr Accel to sqlite/csv") {
                AcclerometerRecorder.shared.simulateAccelerometerDataStroage()
            }.padding(.top, 20)
            
            Button("Insert into SQLite db") {
                Task {
                    //Task will happen asynchronously
                    let N = 50
                    for i in 0..<N {
                        
                        let unixTime = Date().timeIntervalSince1970 * 1000
                        
                        // random size of 2-4 with random content
                        let size  = Int.random(in: 2...4)
                        let bytes = (0..<size).map { _ in UInt8.random(in: 0...255) }
                        
                        //database writes
                        SQLiteSaver.shared.addRow(
                            timestamp: unixTime,
                            dataType: DataType.dummy,
                            blob: bytes,
                            counter: i
                        )
                    }
                    
                    // For the demo we are forcing a new file.
                    // This does not work as the consumer is thread.
                    // This is called before consumer finishes processing,
                    // unless we wait 2 seconds.
                    //
                    // DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    //     SQLiteSaver.shared.flushDataToDb(forceNewFile: true)
                    // }
                }
            }.padding(.top, 20)
            Button("Flush and create new file") {
                Task {
                    SQLiteSaver.shared.flushDataToDb(forceNewFile: true)
                }
            }.padding(.top, 10)
            
            Button("Print schedule bg task") {
                Task { BackgroundScheduler.shared.printScheduledBackgroundTasks() }
            }.padding(.top, 20)
            
            Button("Upload All Files") {
                Task {
                    await Uploader.shared.uploadFolder()
                }
            }.padding(.top, 20)
            
            Button("Print log data") {
                Task { self.printCurrentLogFile() }
            }.padding(.top, 20)
            
            Button("Get HealthKit data") {
                Task {
                    HealthkitRecorder.shared.getHealthKitData()
                }
            }.padding(.top, 20)
            
            if CLLocationManager().authorizationStatus != .authorizedAlways {
                Button("Always allow location") {
                    Task { showSettingsAlert = true }
                }.padding(.top, 10)
            }
            
            if CLLocationManager().authorizationStatus == .authorizedAlways {
                Text("Always allow location granted")
                    .padding(.top, 10)
            }
            
            Button("Log Out") {
                authManager.logout()
            }.padding(.top, 20)
        }
        .padding()
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
    // MARK: - Home View
    // ============================================================
    
    struct HomeView: View {
        let accentColor: Color
        let onLogout: () -> Void
        @ObservedObject var appState: AppState
        @Binding var isSurveyPresented: Bool
        
        @EnvironmentObject private var authManager: SecureAuthManager
        
        @AppStorage("journey_first_open_date") private var firstOpenTimestamp: Double = 0
        @AppStorage("journey_display_name") private var storedDisplayName: String = ""
        
        private var currentDay: Int {
            guard firstOpenTimestamp != 0 else { return 1 }
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date(timeIntervalSince1970: firstOpenTimestamp))
            let today = cal.startOfDay(for: Date())
            return max(1, (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1)
        }
        
        private var patientFirstName: String? {
            guard !storedDisplayName.isEmpty else { return nil }
            return storedDisplayName.components(separatedBy: .whitespaces).first
        }
        
        private var checkInComplete: Bool { appState.isCompletedToday }
        
        @State private var appeared = false
        @State private var showSettings = false
        @State private var todaySteps: Int? = nil
        @State private var todayDistanceMeters: Double? = nil
        @State private var latestHeartRate: Int? = nil
        @State private var lastNightSleepHours: Double? = nil
        @State private var todayActiveEnergy: Int? = nil
        @State private var todayFlights: Int? = nil
        
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text(greetingText)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                Text(patientFirstName.map { "Hi, \($0) 👋" } ?? "Hi there 👋")
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 12)
                            .animation(.easeOut(duration: 0.45).delay(0.05), value: appeared)
                            
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
                                                // Greeting
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
                                                
                                                // Recovery day card
                                                recoveryDayCard
                                                    .opacity(appeared ? 1 : 0)
                                                    .offset(y: appeared ? 0 : 16)
                                                    .animation(.easeOut(duration: 0.45).delay(0.15), value: appeared)
                                                
                                                // ── Weekly survey strip ──────────────
                                                weeklyStripCard
                                                    .opacity(appeared ? 1 : 0)
                                                    .offset(y: appeared ? 0 : 16)
                                                    .animation(.easeOut(duration: 0.45).delay(0.22), value: appeared)
                                                
                                                // ── Survey CTA ───────────────────────
                                                Button(action: { isSurveyPresented = true }) {
                                                    surveyCard
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(checkInComplete)
                                                .opacity(appeared ? 1 : 0)
                                                .offset(y: appeared ? 0 : 16)
                                                .animation(.easeOut(duration: 0.45).delay(0.30), value: appeared)
                                                
                                                // Quick stats
                                                quickStatsRow
                                                    .opacity(appeared ? 1 : 0)
                                                    .offset(y: appeared ? 0 : 16)
                                                    .animation(.easeOut(duration: 0.45).delay(0.38), value: appeared)
                                                
                                                Spacer().frame(height: 20)
                                            }
                                            .padding(.top, 8)
                                        }
                                    }
                                    .navigationTitle("Journey")
                                    .navigationBarTitleDisplayMode(.inline)
                                    .toolbarBackground(Color.clear, for: .navigationBar)
                                    .toolbar {
                                        ToolbarItem(placement: .topBarTrailing) {
                                            Button(action: { showSettings = true }) {
                                                Image(systemName: "person.fill")
                                                    .font(.system(size: 16, weight: .semibold))
                                                    .foregroundStyle(accentColor)
                                                    .frame(width: 36, height: 36)
                                                    .glassEffect(.regular.interactive(), in: .circle)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .sheet(isPresented: $showSettings) {
                                        SettingsView(accentColor: Color(red: 0.58, green: 0.48, blue: 0.72), onLogout: onLogout)
                                    }
                                }
                                .onAppear {
                                    appeared = true
                                    loadWeeklyProgress()
                                }
                            }
                            
                            // ── Weekly strip card ─────────────────────
                            private var weeklyStripCard: some View {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("This week")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                    
                                    HStack(spacing: 0) {
                                        ForEach(currentWeekDays(), id: \.self) { date in
                                            let isToday    = calendar.isDateInToday(date)
                                            let isFuture   = date > Date()
                                            let completed  = weeklyProgress[calendar.startOfDay(for: date)] ?? false
                                            let dayLetter  = shortDayLetter(for: date)
                                            let dayNum     = calendar.component(.day, from: date)
                                            
                                            VStack(spacing: 6) {
                                                Text(dayLetter)
                                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                                    .foregroundStyle(isToday
                                                                     ? Color(red: 0.22, green: 0.48, blue: 0.40)
                                                                     : Color(red: 0.55, green: 0.47, blue: 0.44))
                                                
                                                ZStack {
                                                    Circle()
                                                        .fill(isFuture
                                                              ? Color.clear
                                                              : completed
                                                              ? Color(red: 0.22, green: 0.60, blue: 0.45)
                                                              : Color(red: 0.80, green: 0.75, blue: 0.72).opacity(0.5))
                                                        .frame(width: 34, height: 34)
                                                    
                                                    if isToday && !completed {
                                                        Circle()
                                                            .strokeBorder(Color(red: 0.42, green: 0.62, blue: 0.55), lineWidth: 2)
                                                            .frame(width: 34, height: 34)
                                                    }
                                                    
                                                    if !isFuture {
                                                        if completed {
                                                            Image(systemName: "checkmark")
                                                                .font(.system(size: 13, weight: .bold))
                                                                .foregroundStyle(.white)
                                                        } else {
                                                            Text("\(dayNum)")
                                                                .font(.system(size: 13, weight: isToday ? .bold : .regular, design: .rounded))
                                                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                                        }
                                                    } else {
                                                        Text("\(dayNum)")
                                                            .font(.system(size: 13, design: .rounded))
                                                            .foregroundStyle(Color(red: 0.70, green: 0.65, blue: 0.62).opacity(0.4))
                                                    }
                                                }
                                                .opacity(isFuture ? 0.4 : 1.0)
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                                .padding(18)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                        .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
                                )
                                .padding(.horizontal, 24)
                            }
                            .onAppear {
                                appeared = true
                                if firstOpenTimestamp == 0 { firstOpenTimestamp = Date().timeIntervalSince1970 }
                                loadTodayHealthStats()
                                Task { await authManager.refreshPatientProfileCache() }
                            }
                        }
                        
                        private func loadTodayHealthStats() {
                            guard HKHealthStore.isHealthDataAvailable() else { return }
                            let store = HKHealthStore()
                            let calendar = Calendar.current
                            let startOfDay = calendar.startOfDay(for: Date())
                            let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)
                            
                            // Steps query
                            if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
                                let stepsQuery = HKStatisticsQuery(
                                    quantityType: stepType,
                                    quantitySamplePredicate: predicate,
                                    options: .cumulativeSum
                                ) { _, result, _ in
                                    DispatchQueue.main.async {
                                        todaySteps = result?.sumQuantity().map { Int($0.doubleValue(for: .count())) }
                                    }
                                }
                                store.execute(stepsQuery)
                            }
                            
                            // Distance query
                            if let distType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
                                let distQuery = HKStatisticsQuery(
                                    quantityType: distType,
                                    quantitySamplePredicate: predicate,
                                    options: .cumulativeSum
                                ) { _, result, _ in
                                    DispatchQueue.main.async {
                                        todayDistanceMeters = result?.sumQuantity().map { $0.doubleValue(for: .meter()) }
                                    }
                                }
                                store.execute(distQuery)
                            }
                            
                            // Active energy query
                            if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                                let energyQuery = HKStatisticsQuery(
                                    quantityType: energyType,
                                    quantitySamplePredicate: predicate,
                                    options: .cumulativeSum
                                ) { _, result, _ in
                                    DispatchQueue.main.async {
                                        todayActiveEnergy = result?.sumQuantity().map { Int($0.doubleValue(for: .kilocalorie())) }
                                    }
                                }
                                store.execute(energyQuery)
                            }
                            
                            // Flights climbed query
                            if let flightsType = HKQuantityType.quantityType(forIdentifier: .flightsClimbed) {
                                let flightsQuery = HKStatisticsQuery(
                                    quantityType: flightsType,
                                    quantitySamplePredicate: predicate,
                                    options: .cumulativeSum
                                ) { _, result, _ in
                                    DispatchQueue.main.async {
                                        todayFlights = result?.sumQuantity().map { Int($0.doubleValue(for: .count())) }
                                    }
                                }
                                store.execute(flightsQuery)
                            }
                            
                            // Heart rate query — latest sample today
                            if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
                                let hrQuery = HKSampleQuery(
                                    sampleType: hrType,
                                    predicate: predicate,
                                    limit: 1,
                                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
                                ) { _, samples, _ in
                                    DispatchQueue.main.async {
                                        if let sample = samples?.first as? HKQuantitySample {
                                            latestHeartRate = Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
                                        }
                                    }
                                }
                                store.execute(hrQuery)
                            }
                            
                            // Sleep query — last night (yesterday 18:00 to now)
                            if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                                let sleepStart = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: yesterday)!
                                let sleepPredicate = HKQuery.predicateForSamples(withStart: sleepStart, end: Date(), options: .strictStartDate)
                                let sleepQuery = HKSampleQuery(
                                    sampleType: sleepType,
                                    predicate: sleepPredicate,
                                    limit: HKObjectQueryNoLimit,
                                    sortDescriptors: nil
                                ) { _, samples, _ in
                                    DispatchQueue.main.async {
                                        let asleepValues: Set<Int> = [
                                            HKCategoryValueSleepAnalysis.asleep.rawValue,
                                            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                                            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                                        ]
                                        let totalSeconds = (samples as? [HKCategorySample])?.reduce(0.0) { acc, s in
                                            asleepValues.contains(s.value) ? acc + s.endDate.timeIntervalSince(s.startDate) : acc
                                        } ?? 0.0
                                        let hours = totalSeconds / 3600.0
                                        lastNightSleepHours = hours > 0 ? hours : nil
                                    }
                                }
                                store.execute(sleepQuery)
                            }
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
                                    Text("\(currentDay)")
                                        .font(.system(size: 72, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text(currentDay == 1 ? "Welcome to your recovery journey!" : "of your recovery journey")
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
                            
                            private var quickStatsRow: some View {
                                HStack(spacing: 12) {
                                    statCard(icon: "figure.walk",       value: "2,840", label: "Steps today", color: Color(red: 0.42, green: 0.62, blue: 0.55))
                                    statCard(icon: "waveform.path.ecg", value: "3/10",  label: "Pain level",  color: Color(red: 0.80, green: 0.55, blue: 0.45))
                                    statCard(icon: "calendar",          value: "3d",    label: "Next survey", color: Color(red: 0.38, green: 0.55, blue: 0.75))
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
                            
                            private let statColumns = [GridItem(.flexible(), spacing: 10),
                                                       GridItem(.flexible(), spacing: 10),
                                                       GridItem(.flexible(), spacing: 10)]
                            
                            private var quickStatsRow: some View {
                                LazyVGrid(columns: statColumns, spacing: 10) {
                                    statCard(icon: "figure.walk",        value: todaySteps.map { formatSteps($0) } ?? "—",                        label: "Steps",       color: Color(red: 0.42, green: 0.62, blue: 0.55))
                                    statCard(icon: "figure.walk.motion", value: todayDistanceMeters.map { formatDistance($0) } ?? "—",            label: "Distance",    color: Color(red: 0.38, green: 0.55, blue: 0.75))
                                    statCard(icon: "heart.fill",         value: latestHeartRate.map { "\($0)" } ?? "—",                           label: "Heart rate",  color: Color(red: 0.80, green: 0.55, blue: 0.45))
                                    statCard(icon: "flame.fill",         value: todayActiveEnergy.map { "\($0)" } ?? "—",                         label: "Active kcal", color: Color(red: 0.85, green: 0.50, blue: 0.35))
                                    statCard(icon: "figure.stairs",      value: todayFlights.map { "\($0)" } ?? "—",                              label: "Flights",     color: Color(red: 0.50, green: 0.60, blue: 0.45))
                                    statCard(icon: "bed.double.fill",    value: lastNightSleepHours.map { String(format: "%.1f hr", $0) } ?? "—", label: "Sleep",       color: Color(red: 0.58, green: 0.48, blue: 0.72))
                                }
                                
                                private func formatSteps(_ steps: Int) -> String {
                                    let formatter = NumberFormatter()
                                    formatter.numberStyle = .decimal
                                    return formatter.string(from: NSNumber(value: steps)) ?? "\(steps)"
                                }
                                
                                private func formatDistance(_ meters: Double) -> String {
                                    let km = meters / 1000.0
                                    return String(format: "%.1f km", km)
                                }
                                
                                private func statCard(icon: String, value: String, label: String, color: Color) -> some View {
                                    VStack(spacing: 6) {
                                        Image(systemName: icon)
                                            .font(.system(size: 18))
                                            .foregroundStyle(color)
                                        Text(value)
                                            .font(.system(size: 16, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                        Text(label)
                                            .font(.system(size: 10, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                            .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 8, y: 3)
                                    )
                                }
                                
                                private func loadWeeklyProgress() {
                                    let days   = currentWeekDays()
                                    let month  = days.first ?? Date()
                                    let records = SQLiteSaver.shared.fetchSurveys(forMonth: month)
                                    let formatter = DateFormatter()
                                    formatter.dateFormat = "yyyy-MM-dd"
                                    
                                    var result: [Date: Bool] = [:]
                                    for record in records {
                                        guard let date = formatter.date(from: record.dateString) else { continue }
                                        result[calendar.startOfDay(for: date)] = record.completed
                                    }
                                    weeklyProgress = result
                                }
                                
                                private var currentMilestone: String? {
                                    switch currentDay {
                                    case 7:  return "🎉 1 week milestone!"
                                    case 14: return "🎉 2 week milestone!"
                                    case 30: return "🎉 1 month milestone!"
                                    case 90: return "🎉 3 month milestone!"
                                    default: return nil
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
                                // MARK: - Settings View
                                // ============================================================
                                
                                struct SettingsView: View {
                                    let accentColor: Color
                                    var onLogout: () -> Void
                                    @State private var showingLogoutAlert = false
                                    @State private var showingPrivacySheet = false
                                    @State private var showingHelpSheet = false
                                    @AppStorage("journey_display_name") private var storedDisplayName: String = ""
                                    
                                    private var displayName: String {
                                        storedDisplayName.isEmpty ? "Patient" : storedDisplayName
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
                                                
                                                VStack(spacing: 16) {
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
                                                            Text(displayName)
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
                                                    
                                                    VStack(spacing: 0) {
                                                        Button {
                                                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                                                UIApplication.shared.open(url)
                                                            }
                                                        } label: {
                                                            settingsRow(icon: "bell.fill", label: "Notifications", color: Color(red: 0.55, green: 0.48, blue: 0.75))
                                                        }
                                                        .buttonStyle(.plain)
                                                        Divider().padding(.leading, 56)
                                                        Button { showingPrivacySheet = true } label: {
                                                            settingsRow(icon: "lock.fill", label: "Privacy", color: Color(red: 0.38, green: 0.55, blue: 0.75))
                                                        }
                                                        .buttonStyle(.plain)
                                                        Divider().padding(.leading, 56)
                                                        Button { showingHelpSheet = true } label: {
                                                            settingsRow(icon: "questionmark.circle.fill", label: "Help & Support", color: Color(red: 0.42, green: 0.62, blue: 0.55))
                                                        }
                                                        .buttonStyle(.plain)
                                                    }
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 20)
                                                            .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                                            .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
                                                    )
                                                    
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
                                            .sheet(isPresented: $showingPrivacySheet) {
                                                privacySheet
                                            }
                                            .sheet(isPresented: $showingHelpSheet) {
                                                helpSheet
                                            }
                                        }
                                    }
                                    
                                    private var privacySheet: some View {
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
                                                    VStack(alignment: .leading, spacing: 16) {
                                                        VStack(alignment: .leading, spacing: 8) {
                                                            Text("About This Study")
                                                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                                            Text("Journey is a multi-institution research study of recovery after spine surgery. Your phone and watch help your care team understand how you're healing day to day.")
                                                                .font(.system(size: 15, design: .rounded))
                                                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                                                .lineSpacing(3)
                                                        }
                                                        .padding(16)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 16)
                                                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                                                        )
                                                        VStack(alignment: .leading, spacing: 8) {
                                                            Text("What We Collect")
                                                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                                            ForEach(["Motion & activity", "Location", "Health metrics (steps, heart rate, sleep)", "Daily check-in answers"], id: \.self) { item in
                                                                HStack(spacing: 8) {
                                                                    Circle()
                                                                        .fill(Color(red: 0.42, green: 0.62, blue: 0.55))
                                                                        .frame(width: 6, height: 6)
                                                                    Text(item)
                                                                        .font(.system(size: 15, design: .rounded))
                                                                        .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                                                }
                                                            }
                                                        }
                                                        .padding(16)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 16)
                                                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                                                        )
                                                        VStack(alignment: .leading, spacing: 8) {
                                                            Text("Your Data")
                                                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                                            Text("Your data is used for research purposes only and is never sold or shared outside the study. You may withdraw at any time by contacting your study coordinator.")
                                                                .font(.system(size: 15, design: .rounded))
                                                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                                                .lineSpacing(3)
                                                        }
                                                        .padding(16)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 16)
                                                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                                                        )
                                                    }
                                                    .padding(20)
                                                }
                                            }
                                            .navigationTitle("About This Study")
                                            .navigationBarTitleDisplayMode(.inline)
                                            .toolbar {
                                                ToolbarItem(placement: .topBarTrailing) {
                                                    Button("Done") { showingPrivacySheet = false }
                                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                                }
                                            }
                                        }
                                        .preferredColorScheme(.light)
                                    }
                                    
                                    private var helpSheet: some View {
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
                                                    VStack(alignment: .leading, spacing: 16) {
                                                        VStack(alignment: .leading, spacing: 8) {
                                                            Text("Questions about the study or the app? Your study coordinator is happy to help.")
                                                                .font(.system(size: 15, design: .rounded))
                                                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                                                .lineSpacing(3)
                                                        }
                                                        .padding(16)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 16)
                                                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                                                        )
                                                        VStack(spacing: 0) {
                                                            HStack {
                                                                VStack(alignment: .leading, spacing: 2) {
                                                                    Text("Study coordinator")
                                                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                                                    Text("Contact details provided by your care team")
                                                                        .font(.system(size: 13, design: .rounded))
                                                                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                                                }
                                                                Spacer()
                                                            }
                                                            .padding(16)
                                                            Divider().padding(.leading, 16)
                                                            HStack {
                                                                Text("App version")
                                                                    .font(.system(size: 15, design: .rounded))
                                                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                                                Spacer()
                                                                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                                                                    .font(.system(size: 15, design: .rounded))
                                                                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                                            }
                                                            .padding(16)
                                                        }
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 16)
                                                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                                                        )
                                                    }
                                                    .padding(20)
                                                }
                                            }
                                            .navigationTitle("Help & Support")
                                            .navigationBarTitleDisplayMode(.inline)
                                            .toolbar {
                                                ToolbarItem(placement: .topBarTrailing) {
                                                    Button("Done") { showingHelpSheet = false }
                                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                                }
                                            }
                                        }
                                        .preferredColorScheme(.light)
                                    }
                                    
                                    private func settingsRow(icon: String, label: String, color: Color, trailingValue: String? = nil) -> some View {
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
                                            if let trailingValue {
                                                Text(trailingValue)
                                                    .font(.system(size: 14, design: .rounded))
                                                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                            }
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(Color(red: 0.75, green: 0.65, blue: 0.62))
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 13)
                                    }
                                }
                                
                                // ============================================================
                                // MARK: - HealthKit
                                // ============================================================
                                
                                func formatRawString(_ p: HealthKitManager.RawDataPoint, unixStartStr: String, unixEndStr: String) -> String {
                                    let dateStr      = p.startDate.formatted(.dateTime.month().day().hour().minute().second())
                                    let displayValue = p.value ?? 0.0
                                    let metaStr: String = {
                                        guard let md = p.metadata as? [AnyHashable: Any] else { return "" }
                                        return md.map { key, value in
                                            "\(String(describing: key)):\(String(describing: value))"
                                        }
                                        .sorted()
                                        .joined(separator: "|")
                                    }()
                                    let durationMs = Int(p.duration * 1000)
                                    return "[\(dateStr)] |ID:\(p.id.uuidString)| TYPE:\(p.type) | VAL:\(displayValue) \(p.unit) | UNIX_START:\(unixStartStr) | UNIX_END:\(unixEndStr) | DUR:\(durationMs)ms | SRC:\(p.sourceName) | BID:\(p.bundleID) | DEV:\(p.deviceName ?? "NA") | MOD:\(p.deviceModel ?? "NA") | SW:\(p.softwareVer ?? "NA") | ID:\(p.id.uuidString) | META:{\(metaStr)}"
                                }
                                
                                // ============================================================
                                // MARK: - Helpers (preserved from GitHub)
                                // ============================================================
                                
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
                                    motionActivityManager.queryActivityStarting(from: Date(), to: Date(), to: .main) { _, _ in
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
                            // MARK: - Preview
                            // ============================================================
                            
                            #Preview {
                                MainAppView()
                                    .environmentObject(SecureAuthManager())
                            }

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
// MARK: - MainAppView
// ============================================================

struct MainAppView: View {
    
    @EnvironmentObject private var authManager: SecureAuthManager
    
    // Observed here so scenePhase audit can reset it and trigger
    // navigation back to PermissionsFlowView automatically
    @AppStorage("permissionsComplete") private var permissionsComplete = false
    
    @StateObject private var appState         = AppState()
    @StateObject private var sensorKitManager = SensorKitManager()

    // Server-authoritative survey schedule + study id live here; observed so
    // the check-in tab icon updates once the schedule is pulled on login.
    @ObservedObject private var profileStore  = ProfileStore.shared
    
    @State private var isSurveyPresented = false
    
    @Environment(\.scenePhase) var scenePhase
    
    @State private var selectedTab: JourneyTab = .home
    @State private var lastNonSurveyTab: JourneyTab = .home
    @State private var hasStartedCollection = false
    
    // MARK: - Body
    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(JourneyTab.home.label, systemImage: JourneyTab.home.icon, value: JourneyTab.home) {
                HomeView(accentColor: JourneyTab.home.accentColor, onLogout: { authManager.logout() }, appState: appState, isSurveyPresented: $isSurveyPresented)
            }
            Tab(JourneyTab.sensors.label, systemImage: JourneyTab.sensors.icon, value: JourneyTab.sensors) {
                SensorsTabView()
            }
            Tab(JourneyTab.progress.label, systemImage: JourneyTab.progress.icon, value: JourneyTab.progress) {
                MonthlyProgressView()
            }
#if DEBUG
            Tab(JourneyTab.debug.label, systemImage: JourneyTab.debug.icon, value: JourneyTab.debug) {
                DebugTabView(onLogout: { authManager.logout() })
            }
#endif
            // Apple Health-style separated "search" slot, repurposed as the daily
            // check-in button. role: .search makes iOS shift the main tab capsule
            // left and render this as a detached button on the trailing side. It
            // only triggers the survey sheet (see .onChange / .sheet below); the
            // placeholder view is never really shown. Icon swaps to a checkmark
            // once today's check-in is done.
            Tab("Check-in",
                systemImage: surveyTabIcon,
                value: JourneyTab.survey,
                role: .search) {
                Color.clear
            }
        }
        .tint(selectedTab.accentColor)
        .onChange(of: selectedTab) { _, newValue in
            // Tapping the separated check-in slot opens the survey instead of
            // navigating; remember the previous tab so we can restore it on dismiss.
            if newValue == .survey {
                isSurveyPresented = true
            } else {
                lastNonSurveyTab = newValue
            }
        }
        .sheet(isPresented: $isSurveyPresented, onDismiss: {
            if selectedTab == .survey { selectedTab = lastNonSurveyTab }
        }) {
            SurgerySurveyView(appState: appState, authManager: authManager)
        }
        .onAppear {
            guard !hasStartedCollection else { return }
            hasStartedCollection = true
            // Load the synced user profile — or restore it from the study
            // server on a fresh device (day count, calendar history,
            // check-in state). Local copy wins when one exists.
            Task { await ProfileStore.shared.bootstrap(authManager: authManager, appState: appState) }
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
    
    // Icon for the daily check-in slot. The system tab bar owns the color, so
    // state is conveyed by SHAPE alone:
    //   completed today        -> filled checkmark (clearly "done")
    //   scheduled & still due   -> filled clipboard (weighted, draws the eye)
    //   nothing scheduled today -> outline clipboard (quiet/inactive)
    private var surveyTabIcon: String {
        if appState.isCompletedToday { return "checkmark.circle.fill" }
        if profileStore.isCheckInDueToday() { return "list.clipboard.fill" }
        return "list.clipboard"
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
}

// ============================================================
// MARK: - Preview
// ============================================================

#Preview {
    MainAppView()
        .environmentObject(SecureAuthManager())
}

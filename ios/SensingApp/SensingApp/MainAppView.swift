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
    
    @State private var isSurveyPresented = false
    
    @Environment(\.scenePhase) var scenePhase
    
    @State private var selectedTab: JourneyTab = .home
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
    
    // Three-state status of the daily check-in, surfaced as the FAB's ring color.
    private enum SurveyFABState { case unavailable, due, completed }

    private var surveyFABState: SurveyFABState {
        guard appState.isSurveyScheduledToday else { return .unavailable }
        return appState.isCompletedToday ? .completed : .due
    }

    private var surveyButton: some View {
        let state = surveyFABState
        let ringColor: Color = {
            switch state {
            case .due:         return Color(red: 0.85, green: 0.35, blue: 0.19) // amber red — needs completing today
            case .completed:   return Color(red: 0.22, green: 0.60, blue: 0.45) // green — done (matches weekly strip)
            case .unavailable: return Color(red: 0.62, green: 0.58, blue: 0.55) // gray — none scheduled today
            }
        }()
        let icon = state == .completed ? "checkmark" : "list.clipboard.fill"

        return Button(action: { if surveyFABState == .due { isSurveyPresented = true } }) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(ringColor)                                  // tinted icon, legible on glass
                .frame(width: 60, height: 60)
                // Apple Liquid Glass; interactive only when actionable.
                .glassEffect(state == .due ? .regular.interactive() : .regular, in: .circle)
                .overlay { Circle().strokeBorder(ringColor, lineWidth: 3) }   // status ring
        }
        .buttonStyle(.plain)
        .allowsHitTesting(state == .due)              // only the "due" state is tappable
        .opacity(state == .unavailable ? 0.5 : 1)     // visibly dimmed when none scheduled
        .padding(.trailing, 20)
        .padding(.bottom, 24)
        .accessibilityLabel(
            state == .completed ? "Daily check-in complete"
            : state == .due     ? "Start daily check-in"
            :                     "No check-in scheduled today"
        )
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
}

// ============================================================
// MARK: - Preview
// ============================================================

#Preview {
    MainAppView()
        .environmentObject(SecureAuthManager())
}

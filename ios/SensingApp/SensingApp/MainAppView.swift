//
//  ContentView.swift
//  SensingApp
//

import SwiftUI

// ============================================================
// MARK: - MainAppView
// ============================================================

struct MainAppView: View {
    
    @EnvironmentObject private var authManager: SecureAuthManager
    
    // Observed here so scenePhase audit can reset it and trigger
    // navigation back to PermissionsFlowView automatically
    @AppStorage("permissionsComplete") private var permissionsComplete = false
    
    @EnvironmentObject private var appState: AppState   // SensingAppApp's instance
    
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
            //
            // The slot used to open the survey unconditionally, so a patient who
            // had already checked in today got the sheet anyway and was met with
            // an "Already Completed" alert the moment it appeared — while Home's
            // own check-in card was correctly disabled. Same rule both places
            // now: if there is nothing to fill in, the slot just bounces back to
            // the tab you were on. The icon is already a checkmark, so the state
            // is visible without the detour through a modal.
            if newValue == .survey {
                if canOpenCheckIn {
                    isSurveyPresented = true
                } else {
                    selectedTab = lastNonSurveyTab
                }
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
    /// Whether there is a check-in to fill in right now. Mirrors the condition
    /// HomeView uses to enable its check-in card, so the two entry points can
    /// never disagree about whether the survey is open for business.
    private var canOpenCheckIn: Bool {
        !appState.isCompletedToday && appState.isSurveyScheduledToday
    }

    private var surveyTabIcon: String {
        if appState.isCompletedToday { return "checkmark.circle.fill" }
        if appState.isSurveyScheduledToday { return "list.clipboard.fill" }
        return "list.clipboard"
    }

    // ============================================================
    // MARK: - Foreground Permission Audit
    // ============================================================
    //
    // Called every time the app returns to foreground via scenePhase. Anything
    // turned off (PermissionAudit) resets permissionsComplete, which routes the
    // patient back to that card in PermissionsFlowView.
    private func auditPermissionsOnForeground() {
        PermissionAudit.audit { permissionsComplete = false }
    }
}

// ============================================================
// MARK: - Preview
// ============================================================

#Preview {
    MainAppView()
        .environmentObject(SecureAuthManager())
        .environmentObject(AppState())
}

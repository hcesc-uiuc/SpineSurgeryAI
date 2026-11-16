//
//  PermissionsFlowView.swift
//  SensingApp
//

import SwiftUI
import CoreMotion
import CoreLocation
import HealthKit
import UserNotifications
import SensorKit

// ============================================================
// MARK: - PermissionsFlowView Documentation
// ============================================================
//
// PURPOSE:
// Presents a sequential, full-screen onboarding flow requesting
// all permissions required by the Journey app. Shown whenever
// permissionsComplete == false, which happens on:
//   1. First ever install
//   2. Reinstall (Keychain sentinel cleared)
//   3. Permission revoked (auditPermissions() in AuthLoginView detected it)
//   4. User returns from background with a revoked permission
//      (scenePhase observer in MainAppView resets permissionsComplete)
//
// PERMISSION ORDER (5 steps):
//   1. Motion & Activity  — CMMotionActivityManager
//   2. Location           — CLLocationManager (ALWAYS required, not WhenInUse)
//   3. SensorKit          — SRSensorReader (screen time, keyboard, accelerometer)
//   4. Notifications      — UNUserNotificationCenter
//   5. Health Data        — HKHealthStore (moved to last — triggers large system sheet)
//
// WHY HEALTH IS LAST:
//   Apple's HealthKit permission sheet is a large multi-item picker showing
//   every data type we request. It is more overwhelming than other prompts.
//   Placing it last means patients have already committed to the flow before
//   seeing it, improving completion rate.
//
// DARK MODE FIX:
//   All colors in this view are hardcoded warm tones that look correct in
//   light mode only. .preferredColorScheme(.light) is applied to the root
//   ZStack to force light mode regardless of device setting. This prevents
//   white text appearing on a white/warm background in dark mode.
//
// NOTIFICATIONS FIX:
//   AppDelegate.registerForPushNotifications() was calling
//   UNUserNotificationCenter.requestAuthorization() at launch, which caused
//   iOS to silently skip our prompt here (iOS only shows it once per install).
//   That call has been removed from AppDelegate — this view now owns the
//   notification prompt entirely.
//
// PERMISSION PERSISTENCE:
//   permissionsComplete is AppStorage (UserDefaults). On reinstall it may
//   survive — see AuthLoginView.detectReinstall() for Keychain sentinel fix.
//   The flow always shows only cards for permissions that are not currently
//   granted; a genuinely fresh device (all five notDetermined) shows all 5.
//   If all permissions are already granted on entry, completes immediately.
//   Issue #83: "granted" comes from PermissionAudit, and a card never lets the
//   patient past while its permission is off. The SensorKit card lists each
//   sensor that is turned off; cards re-check when the app returns from Settings.
//
// SIMULATOR NOTE:
//   SensorKit cannot be authorized on the iOS simulator — there is no
//   Settings entry and no system prompt. All SensorKit checks are guarded
//   with #if targetEnvironment(simulator) and return true automatically
//   so the flow is not blocked during development.
//
// ============================================================

// MARK: - Permission Model

enum JourneyPermission: CaseIterable, Identifiable {
    
    //disable sensorkit for now
    case motion, location, sensorKit, notifications, health
    // case motion, location, notifications, health
    
    var id: Self { self }

    var icon: String {
        switch self {
        case .motion:        return "figure.walk.motion"
        case .location:      return "location.fill"
        case .sensorKit:     return "iphone.radiowaves.left.and.right"
        case .notifications: return "bell.fill"
        case .health:        return "heart.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .motion:        return Color(red: 0.80, green: 0.65, blue: 0.58)
        case .location:      return Color(red: 0.42, green: 0.62, blue: 0.55)
        case .sensorKit:     return Color(red: 0.38, green: 0.55, blue: 0.75)
        case .notifications: return Color(red: 0.55, green: 0.48, blue: 0.75)
        case .health:        return Color(red: 0.80, green: 0.35, blue: 0.38)
        }
    }

    var title: String {
        switch self {
        case .motion:        return "Motion & Activity"
        case .location:      return "Location Access"
        case .sensorKit:     return "Device Sensors"
        case .notifications: return "Reminders"
        case .health:        return "Health Data"
        }
    }

    var headline: String {
        switch self {
            case .motion:        return "Track your movement patterns"
            case .location:      return "Understand your daily activity"
            case .sensorKit:     return "Capture device signals"
            case .notifications: return "Stay on top of your recovery"
            case .health:        return "Connect with your health metrics"
        }
    }

    var explanation: String {
        switch self {
        case .motion:
            return "Your phone's motion sensors help us track walking patterns and physical activity during your recovery, giving your care team valuable insight into your progress."
        case .location:
            return "Location data helps us understand how much you're moving around day-to-day. This is used only for research purposes and is never shared outside the study."
        
        case .sensorKit:
            return "Your iPhone and Apple Watch sensors show how you move, sleep and use your phone as you recover, including typing, messaging and call activity. We only collect counts and timing, never what you type, say or read. Please allow every sensor on the next screen; the study needs all of them."
        
        case .notifications:
            return "We'll send gentle daily reminders for check-ins and surveys so you are always aware of what to expect."
        case .health:
            return "Connecting to Apple Health lets us read step counts, heart rate, sleep and other metrics that paint a fuller picture of your recovery journey. Please turn on every category; the study needs all of them. You can review this anytime in Settings › Health access."
        }
    }

    var buttonLabel: String { "Allow Access" }
}

// MARK: - Permissions Flow Coordinator

struct PermissionsFlowView: View {

    @AppStorage("permissionsComplete") private var permissionsComplete = false

    @State private var currentIndex         = 0
    @State private var showingDeniedAlert   = false
    @State private var deniedPermissionName = ""
    @State private var cardAppeared         = false

    // Location Always-On state
    @State private var showingAlwaysLocationPrompt = false
    @State private var locationRequester: LocationPermissionRequester?

    @State private var permissions: [JourneyPermission] = []
    private let healthStore     = HKHealthStore()

    @Environment(\.scenePhase) private var scenePhase
    @State private var requestInFlight     = false   // a system prompt is up; don't re-check
    @State private var sensorsOff: [SRSensor] = []   // SensorKit card: sensors to turn on in Settings
    @State private var stillOff            = false
    @State private var showingContactAlert = false

    var onComplete: () -> Void

    #if DEBUG
    /// Previews only: pins the flow to the SensorKit card with these sensors off
    /// ([] = the first-ask card). SensorKit can't run in the simulator.
    var previewSensorsOff: [SRSensor]? = nil
    #endif

    var body: some View {
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

            VStack(spacing: 0) {
                progressDots
                    // A single dot carries no information — hide it when only
                    // one card is shown, keeping opacity so layout doesn't shift.
                    .opacity(permissions.count > 1 ? 1 : 0)
                    .padding(.top, 60)
                    .padding(.bottom, 32)

                if currentIndex < permissions.count {
                    // Scrolls: the SensorKit list can outgrow the screen at large text sizes.
                    ScrollView {
                        permissionCard(for: permissions[currentIndex])
                            .id(currentIndex)
                            .opacity(cardAppeared ? 1 : 0)
                            .offset(y: cardAppeared ? 0 : 30)
                            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: cardAppeared)
                            .padding(.bottom, 24)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }

                Spacer()
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            // Build the filtered list: only permissions that are not currently granted.
            // A genuinely fresh device will have all 5; a returning user with some revoked
            // will see only the cards they still need to grant.
            permissions = JourneyPermission.allCases.filter { !isAlreadyGranted($0) }
            #if DEBUG
            if previewSensorsOff != nil { permissions = [.sensorKit] }
            #endif
            if permissions.isEmpty {
                permissionsComplete = true
                onComplete()
                return
            }
            currentIndex = 0
            triggerCardAppear()
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings: advance if the permission is on again.
            if phase == .active { recheckCurrentCard() }
        }
        .alert("Permission Required", isPresented: $showingDeniedAlert) {
            Button("Open Settings") { openAppSettings(for: permissions[currentIndex]) }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("Journey needs \(deniedPermissionName) access to continue. Please enable it in Settings, then return to the app.")
        }
        .sheet(isPresented: $showingAlwaysLocationPrompt) {
            AlwaysLocationPromptView(
                onOpenSettings: {
                    // Don't dismiss — sheet stays open so "I've updated it" is still visible
                    // when the user returns from the Settings app.
                    openAppSettings()
                },
                onCheckAgain: {
                    if CLLocationManager().authorizationStatus == .authorizedAlways {
                        showingAlwaysLocationPrompt = false
                        advanceToNext()
                    }
                    // Not Always yet — do nothing; sheet remains for another attempt.
                }
            )
            .presentationDetents([.large])
            .presentationCornerRadius(28)
            .interactiveDismissDisabled(true)
            .preferredColorScheme(.light)
        }
    }

    // MARK: - Progress Dots
    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<permissions.count, id: \.self) { i in
                Capsule()
                    .fill(i <= currentIndex
                          ? Color(red: 0.42, green: 0.62, blue: 0.55)
                          : Color(red: 0.80, green: 0.70, blue: 0.66).opacity(0.4))
                    .frame(width: i == currentIndex ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentIndex)
            }
        }
    }

    // MARK: - Permission Card
    private func permissionCard(for permission: JourneyPermission) -> some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(permission.iconColor.opacity(0.15))
                    .frame(width: 100, height: 100)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [permission.iconColor, permission.iconColor.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 76, height: 76)
                    .shadow(color: permission.iconColor.opacity(0.4), radius: 14, y: 6)
                Image(systemName: permission.icon)
                    .font(.system(.largeTitle).weight(.medium))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 10) {
                // Hide the step counter when only a single card is shown
                // (e.g. one revoked permission) — "Step 1 of 1" is noise.
                if permissions.count > 1 {
                    Text("Step \(currentIndex + 1) of \(permissions.count)")
                        .font(.journey(.caption, weight: .semibold))
                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                        .tracking(1.2)
                        .textCase(.uppercase)
                }

                Text(permission.title)
                    .font(.journey(.title, weight: .bold))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                    .multilineTextAlignment(.center)

                Text(headline(for: permission))
                    .font(.journey(.body, weight: .medium))
                    .foregroundStyle(Color(red: 0.42, green: 0.62, blue: 0.55))
                    .multilineTextAlignment(.center)

                if showsSensorList(permission) {
                    sensorsOffList
                } else {
                    Text(permission.explanation)
                        .font(.journey(.subheadline))
                        .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29).opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
            }

            VStack(spacing: 14) {
                if showsSensorList(permission) {
                    primaryButton("Open Settings", color: permission.iconColor) { openAppSettings() }
                    Button("I've turned them on") { recheckCurrentCard(userTapped: true) }
                        .font(.journey(.callout, weight: .semibold))
                        .foregroundStyle(permission.iconColor)
                } else {
                    primaryButton(permission.buttonLabel, color: permission.iconColor,
                                  action: requestCurrentPermission)
                }

                Button("Contact study team") { showingContactAlert = true }
                    .font(.journey(.footnote, weight: .medium))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                    .alert("Contact your study team", isPresented: $showingContactAlert) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text(StudyContact.message)
                    }
            }
            .padding(.top, 4)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95).opacity(0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.12), radius: 24, y: 10)
        )
        .padding(.horizontal, 24)
    }

    private func primaryButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.journey(.body, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [color, color.opacity(0.80)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: color.opacity(0.35), radius: 10, y: 5)
        }
    }

    // MARK: - SensorKit "turned off" list

    /// The SensorKit card switches to a list once the system sheet can no longer
    /// be shown, i.e. every remaining sensor was turned off rather than undecided.
    private func showsSensorList(_ permission: JourneyPermission) -> Bool {
        permission == .sensorKit && !sensorsOff.isEmpty
    }

    private func headline(for permission: JourneyPermission) -> String {
        guard showsSensorList(permission) else { return permission.headline }
        return sensorsOff.count == 1 ? "1 sensor is turned off" : "\(sensorsOff.count) sensors are turned off"
    }

    private var sensorsOffList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sensorsOff.sorted { $0.consentName < $1.consentName }, id: \.rawValue) { sensor in
                VStack(alignment: .leading, spacing: 2) {
                    Text(sensor.consentName)
                        .font(.journey(.subheadline, weight: .semibold))
                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                    Text(sensor.consentDetail)
                        .font(.journey(.footnote))
                        .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29).opacity(0.85))
                }
                .accessibilityElement(children: .combine)
            }

            Text("The study needs every sensor on. To turn them back on, open Settings › Privacy & Security › Research Sensor & Usage Data › Journey.")
                .font(.journey(.footnote))
                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                .lineSpacing(3)
                .padding(.top, 4)

            if stillOff {
                Text("Some sensors are still off. Check each switch, then come back.")
                    .font(.journey(.footnote, weight: .semibold))
                    .foregroundStyle(Color(red: 0.75, green: 0.25, blue: 0.22))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func refreshSensorKitState() {
        #if DEBUG
        if let previewSensorsOff { sensorsOff = previewSensorsOff; return }
        #endif
        sensorsOff = SensorKitRegistry.hasUndecidedSensors ? [] : SensorKitRegistry.missingSensors
    }

    // MARK: - isAlreadyGranted
    private func isAlreadyGranted(_ permission: JourneyPermission) -> Bool {
        PermissionAudit.isGranted(permission)
    }

    /// Re-checks the card on screen (back from Settings, or "I've turned them on").
    private func recheckCurrentCard(userTapped: Bool = false) {
        guard currentIndex < permissions.count, cardAppeared, !requestInFlight else { return }
        let permission = permissions[currentIndex]
        #if DEBUG
        // The simulator reports SensorKit as granted; a preview must stay on the card.
        if previewSensorsOff != nil { stillOff = userTapped; return }
        #endif
        Task {
            if permission == .notifications { await PermissionAudit.syncNotificationsFlag() }
            guard currentIndex < permissions.count, permissions[currentIndex] == permission else { return }
            if isAlreadyGranted(permission) {
                showingDeniedAlert = false
                showingAlwaysLocationPrompt = false
                advanceToNext()
            } else if permission == .sensorKit {
                refreshSensorKitState()
                stillOff = userTapped
            }
        }
    }

    // MARK: - Request Coordinator
    private func requestCurrentPermission() {
        guard currentIndex < permissions.count else { return }
        let permission = permissions[currentIndex]

        if isAlreadyGranted(permission) {
            advanceToNext()
            return
        }

        // If location is WhenInUse (granted but not Always), skip the system dialog
        // and jump straight to the upgrade-to-Always sheet.
        if permission == .location && CLLocationManager().authorizationStatus == .authorizedWhenInUse {
            showingAlwaysLocationPrompt = true
            return
        }

        requestInFlight = true
        Task {
            let granted: Bool
            switch permission {
                case .motion:        granted = await requestMotion()
                case .location:      granted = await requestLocation()
                case .sensorKit:     granted = await requestSensorKit()
                case .notifications: granted = await requestNotifications()
                case .health:        granted = await requestHealth()
            }
            await MainActor.run {
                requestInFlight = false
                if granted {
                    advanceToNext()
                } else if permission == .location &&
                          CLLocationManager().authorizationStatus == .authorizedWhenInUse {
                    // User tapped "Allow While Using App" — upgrade prompt needed.
                    // Setting state here (on the main actor) is reliable.
                    showingAlwaysLocationPrompt = true
                } else if permission == .sensorKit && !SensorKitRegistry.hasUndecidedSensors {
                    // Some sensors were switched off in the sheet: show which ones.
                    refreshSensorKitState()
                } else {
                    deniedPermissionName = permission.title
                    showingDeniedAlert = true
                }
            }
        }
    }

    // MARK: - Advance Logic
    private func advanceToNext() {
        // Only reached once the current permission is on.
        if currentIndex < permissions.count, permissions[currentIndex] == .sensorKit {
            PermissionAudit.sensorKitDidBecomeGranted()
        }
        cardAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            var next = currentIndex + 1
            // Safety skip: if a permission became granted mid-flow (e.g. the user
            // already granted it in another path), skip it so we don't show a
            // redundant card.
            while next < permissions.count && isAlreadyGranted(permissions[next]) {
                next += 1
            }
            if next >= permissions.count {
                permissionsComplete = true
                onComplete()
            } else {
                currentIndex = next
                triggerCardAppear()
            }
        }
    }

    private func triggerCardAppear() {
        stillOff = false
        if currentIndex < permissions.count, permissions[currentIndex] == .sensorKit {
            refreshSensorKitState()
        }
        cardAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            cardAppeared = true
        }
    }

    // MARK: - Permission Handlers

    /// Motion — triggers system dialog via startActivityUpdates.
    /// Simulator has no motion hardware — returns true gracefully.
    private func requestMotion() async -> Bool {
        await withCheckedContinuation { continuation in
            guard CMMotionActivityManager.isActivityAvailable() else {
                continuation.resume(returning: true)
                return
            }
            let manager = CMMotionActivityManager()
            manager.startActivityUpdates(to: .main) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                manager.stopActivityUpdates()
                let status = CMMotionActivityManager.authorizationStatus()
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Location — requires authorizedAlways (not WhenInUse).
    /// For .notDetermined status, requests WhenInUse (NOT Always) so that iOS
    /// reports a truthful status after the dialog: the user always lands in
    /// WhenInUse, which triggers AlwaysLocationPromptView in requestCurrentPermission().
    /// Requesting Always from .notDetermined yields provisional Always — iOS reports
    /// .authorizedAlways even when the user picked "While Using App" — which previously
    /// caused the upgrade sheet to be skipped entirely.
    /// Denied is handled by requestCurrentPermission() after this returns false.
    private func requestLocation() async -> Bool {
        let status = CLLocationManager().authorizationStatus
        if status == .authorizedAlways  { return true  }
        if status != .notDetermined     { return false } // denied/restricted/WhenInUse

        // .notDetermined — trigger the iOS dialog and wait for the response.
        return await withCheckedContinuation { cont in
            let requester = LocationPermissionRequester { _ in
                self.locationRequester = nil
                // Resume based on the actual status now that the dialog was answered.
                cont.resume(returning: CLLocationManager().authorizationStatus == .authorizedAlways)
            }
            locationRequester = requester
            requester.request()
        }
    }

    /// SensorKit — requests every required sensor (SensorKitRegistry).
    /// Skipped entirely on simulator (no hardware, no Settings entry).
    /// NOTE: Requires com.apple.developer.sensorkit.reader entitlement.
    /// Granted means every required sensor is on; a partial grant returns false
    /// and the card switches to its "turned off" list.
    private func requestSensorKit() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return await withCheckedContinuation { continuation in
            SensorKitRegistry.requestAuthorization { error in
                DispatchQueue.main.async {
                    // 8201 = nothing left to ask; not a failure.
                    let nsError = error as NSError?
                    let answered = error == nil || (nsError?.domain == "SRErrorDomain" && nsError?.code == 8201)
                    if let error, !answered {
                        print("SensorKit auth error: \(error)")
                        Logger.shared.append("SensorKit auth error: \(error)")
                    }
                    // Mash's standalone readers gate on this flag.
                    let status: SRAuthorizationStatus = answered ? .authorized : .denied
                    UserDefaults.standard.set(status.rawValue, forKey: PermissionAudit.sensorKitFlagKey)

                    let granted = SensorKitRegistry.missingSensors.isEmpty
                    // Record what was allowed while the card waits for the rest.
                    if !granted { SensorKitRegistry.startAllRecording(checkAuthorization: true) }
                    continuation.resume(returning: granted)
                }
            }
        }
        #endif
    }

    /// Notifications — requests alert, sound, badge.
    /// If already authorized, advances without re-prompting.
    /// If denied, shows the denied alert with Settings deeplink.
    private func requestNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional:
            UserDefaults.standard.set(true, forKey: "journey_notifications_authorized")
            return true
        case .denied:
            return false
        default:
            return await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted {
                        DispatchQueue.main.async {
                            UIApplication.shared.registerForRemoteNotifications()
                            UserDefaults.standard.set(true, forKey: "journey_notifications_authorized")
                        }
                    }
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Health — triggers Apple's HealthKit permission sheet.
    /// Placed last — it's the most overwhelming prompt.
    /// HealthKit always calls completion with success=true from app's perspective.
    private func requestHealth() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }

        let readTypes: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .flightsClimbed)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        ]

        return await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, error in
                if let error = error {
                    print("HealthKit auth error: \(error)")
                }
                continuation.resume(returning: success)
            }
        }
    }

    private func openAppSettings(for permission: JourneyPermission? = nil) {
        let urlString: String
        if #available(iOS 16.0, *), permission == .notifications {
            urlString = UIApplication.openNotificationSettingsURLString
        } else {
            urlString = UIApplication.openSettingsURLString
        }
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

#if DEBUG
#Preview("SensorKit – first ask") {
    PermissionsFlowView(onComplete: {}, previewSensorsOff: [])
}

#Preview("SensorKit – sensors turned off") {
    PermissionsFlowView(onComplete: {},
                        previewSensorsOff: [.keyboardMetrics, .messagesUsageReport, .heartRate])
}

#Preview("Full flow (simulator skips SensorKit)") {
    PermissionsFlowView(onComplete: {})
}
#endif

// MARK: - Always Location Prompt View

struct AlwaysLocationPromptView: View {
    var onOpenSettings: () -> Void
    var onCheckAgain:   () -> Void

    var body: some View {
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

            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.42, green: 0.62, blue: 0.55).opacity(0.15))
                        .frame(width: 90, height: 90)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.42, green: 0.62, blue: 0.55),
                                    Color(red: 0.34, green: 0.54, blue: 0.48)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)
                        .shadow(color: Color(red: 0.42, green: 0.62, blue: 0.55).opacity(0.4), radius: 12, y: 5)
                    Image(systemName: "location.fill")
                        .font(.system(.title).weight(.medium))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 10) {
                    Text("One more step")
                        .font(.journey(.title, weight: .bold))
                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                    Text("Always On location is required")
                        .font(.journey(.callout, weight: .medium))
                        .foregroundStyle(Color(red: 0.42, green: 0.62, blue: 0.55))
                    Text("To accurately track your recovery, Journey needs location access even when the app is in the background. Please update this setting now — it only takes a few seconds.")
                        .font(.journey(.subheadline))
                        .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29).opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 8)
                }

                VStack(alignment: .leading, spacing: 10) {
                    instructionStep(number: "1", text: "Tap \"Open Settings\" below")
                    instructionStep(number: "2", text: "Tap \"Location\"")
                    instructionStep(number: "3", text: "Select \"Always\"")
                    instructionStep(number: "4", text: "Come back and tap \"I've updated it\"")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.6)))

                VStack(spacing: 10) {
                    Button(action: onOpenSettings) {
                        Text("Open Settings")
                            .font(.journey(.body, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.42, green: 0.62, blue: 0.55),
                                        Color(red: 0.34, green: 0.54, blue: 0.48)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color(red: 0.42, green: 0.62, blue: 0.55).opacity(0.35), radius: 10, y: 5)
                    }

                    Button(action: onCheckAgain) {
                        Text("I've updated it")
                            .font(.journey(.callout, weight: .medium))
                            .foregroundStyle(Color(red: 0.42, green: 0.62, blue: 0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color(red: 0.42, green: 0.62, blue: 0.55).opacity(0.10))
                            )
                    }
                }
            }
            .padding(28)
        }
        .preferredColorScheme(.light)
    }

    private func instructionStep(number: String, text: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.42, green: 0.62, blue: 0.55))
                    .frame(width: 26, height: 26)
                Text(number)
                    .font(.journey(.footnote, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(text)
                .font(.journey(.subheadline))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Spacer()
        }
    }
}

// MARK: - Location Permission Requester

class LocationPermissionRequester: NSObject, CLLocationManagerDelegate {
    private let manager:    CLLocationManager
    private var completion: ((Bool) -> Void)?
    private var resumed   = false

    init(completion: @escaping (Bool) -> Void) {
        self.manager    = CLLocationManager()
        self.completion = completion
        super.init()
        self.manager.delegate = self
    }

    func request() {
        DispatchQueue.main.async {
            let status = self.manager.authorizationStatus
            switch status {
            case .authorizedAlways:
                self.resume(true)
            case .authorizedWhenInUse:
                self.resume(true)
            case .denied, .restricted:
                self.resume(false)
            case .notDetermined:
                // Request WhenInUse (not Always) so iOS reports a truthful status.
                // Requesting Always from .notDetermined yields provisional Always —
                // authorizationStatus reports .authorizedAlways even when the user
                // picked "Allow While Using App" — which skipped AlwaysLocationPromptView.
                // With WhenInUse, the user always lands in .authorizedWhenInUse, which
                // requestCurrentPermission() detects and routes through the upgrade sheet.
                // The sheet's "I've updated it" check (== .authorizedAlways) is then only
                // satisfied by a real Settings change.
                self.manager.requestWhenInUseAuthorization()
            @unknown default:
                self.resume(false)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            let status = manager.authorizationStatus
            guard status != .notDetermined else { return }
            self.resume(status == .authorizedWhenInUse || status == .authorizedAlways)
        }
    }

    private func resume(_ granted: Bool) {
        guard !resumed else { return }
        resumed = true
        completion?(granted)
        completion = nil
    }
}

// MARK: - Study contact

/// Shown by every card's "Contact study team". The coordinator's real details
/// are still a placeholder (same as Settings › Help & Support).
enum StudyContact {
    static let message = "Questions about the data we collect, or don't want to share it? Your study coordinator can help. Their contact details were provided by your care team."
}

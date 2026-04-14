
//
//  PermissionsFlowView.swift
//  SpineSurgeryUI
//
//  Created by UIUCSpineSurgey on 3/9/26.
//
import SwiftUI
import CoreMotion
import CoreLocation
import HealthKit
import UserNotifications
// ============================================================
// MARK: - PermissionsFlowView Documentation
// ============================================================
//
// PURPOSE:
// Presents a sequential, full-screen onboarding flow requesting
// all permissions required by the Journey app. This screen appears
// once per device, immediately after the patient's first successful
// login. Once all permissions are granted, the flag
// "permissionsComplete" is persisted via AppStorage and this flow
// is never shown again — even across logout/login cycles.
//
// REQUIRED PERMISSIONS (in order):
//   1. Motion & Activity  — CMMotionActivityManager (CoreMotion)
//   2. Location           — CLLocationManager (CoreLocation)
//                           NOTE: Requires "Always" access, not just
//                           "While Using App". iOS forces a two-step
//                           process — see LOCATION SPECIAL CASE below.
//   3. Health Data        — HKHealthStore (HealthKit)
//   4. Notifications      — UNUserNotificationCenter (UserNotifications)
//
// CALL SEQUENCE:
//   1. AuthLoginView detects isAuthenticated == true
//   2. AuthLoginView checks AppStorage["permissionsComplete"]
//        → false: presents PermissionsFlowView
//        → true:  presents MainAppView (skips this flow entirely)
//   3. onAppear fires → triggerCardAppear() animates first card in
//   4. Patient taps "Allow Access" on current card
//        → requestCurrentPermission() called
//        → isAlreadyGranted() checked first (skips prompt if already authorized)
//        → iOS system permission dialog shown
//   5. On grant → advanceToNext()
//        → animates to next card
//   6. On deny → showingDeniedAlert = true
//        → patient shown "Open Settings" / "Try Again" options
//        → flow does not advance — app remains on current permission card
//        → next app launch re-shows the SAME card (see RE-PROMPT BEHAVIOR)
//   7. After all 4 permissions granted:
//        → permissionsComplete = true (AppStorage)
//        → onComplete() called
//        → AuthLoginView transitions to MainAppView
//
// LOCATION SPECIAL CASE (iOS restriction):
//   iOS does not allow apps to request "Always" access directly on
//   the first prompt — it only shows "Allow Once", "While Using App",
//   and "Don't Allow". To work around this:
//   1. requestLocation() triggers the iOS prompt normally
//   2. If user grants "While Using App", a custom sheet
//      (AlwaysLocationPromptView) slides up immediately
//   3. That sheet guides the patient to Settings → Location → Always
//   4. Patient returns and taps "I've updated it"
//   5. App checks CLLocationManager.authorizationStatus
//        → .authorizedAlways: advances to next permission
//        → anything else: sheet re-appears until corrected
//
// RE-PROMPT BEHAVIOR (addresses comment):
//   If a patient DENIES a permission and closes the app:
//   → On next launch, permissionsComplete is still false
//   → PermissionsFlowView is shown again from the beginning
//   → They will see the same permission card they previously denied
//   → They must either grant the permission OR go to Settings manually
//   There is NO way to re-trigger the iOS system dialog once denied —
//   this is an iOS restriction. The "Open Settings" button in the
//   denial alert deep-links to the app's Settings page where they
//   can manually enable the permission.
//
//   NOTE: Currently there is no savedIndex persistence, so if a patient
//   denies step 2 (Location) and relaunches, they start from step 1
//   again. Consider adding @AppStorage("permissionsLastIndex") if
//   this becomes a UX concern.
//
// ADDING A NEW PERMISSION:
//   1. Add a new case to the JourneyPermission enum
//   2. Implement all computed properties (icon, title, headline, etc.)
//   3. Add a handler function (e.g. requestNewPermission() async -> Bool)
//   4. Add the case to the switch in requestCurrentPermission()
//   5. Add the case to isAlreadyGranted()
//   6. Add the relevant Usage Description key to Info.plist
//
// AUTHOR NOTES (re: MashToDo comment):
//   Sequence documented above. Re-prompt behavior clarified.
//   Location "Always" workaround documented under LOCATION SPECIAL CASE.
// ============================================================
// MARK: - Permission Model
//
// Defines each permission as an enum case with all associated UI
// metadata (icon, color, text) and step labels computed from position.
// Adding a new permission only requires adding a case here and wiring
// it up in PermissionsFlowView — the UI renders automatically.
enum JourneyPermission: CaseIterable, Identifiable {
    case motion, location, health, notifications
    var id: Self { self }
    /// SF Symbol name used in the permission card icon circle
    var icon: String {
        switch self {
        case .motion:        return "figure.walk.motion"
        case .location:      return "location.fill"
        case .health:        return "heart.fill"
        case .notifications: return "bell.fill"
        }
    }
    /// Accent color for this permission's icon and button.
    /// Each permission has a distinct color for visual differentiation.
    var iconColor: Color {
        switch self {
        case .motion:        return Color(red: 0.80, green: 0.65, blue: 0.58) // warm terracotta
        case .location:      return Color(red: 0.42, green: 0.62, blue: 0.55) // sage green
        case .health:        return Color(red: 0.80, green: 0.35, blue: 0.38) // soft red
        case .notifications: return Color(red: 0.55, green: 0.48, blue: 0.75) // muted purple
        }
    }
    /// Large bold title shown on the permission card
    var title: String {
        switch self {
        case .motion:        return "Motion & Activity"
        case .location:      return "Location Access"
        case .health:        return "Health Data"
        case .notifications: return "Reminders"
        }
    }
    /// Shorter subtitle shown below the title in the accent color
    var headline: String {
        switch self {
        case .motion:        return "Track your movement patterns"
        case .location:      return "Understand your daily activity"
        case .health:        return "Connect with your health metrics"
        case .notifications: return "Stay on top of your recovery"
        }
    }
    /// Longer patient-friendly explanation of why this permission is needed.
    /// Shown in body text on the permission card before the iOS dialog appears.
    var explanation: String {
        switch self {
        case .motion:
            return "Your phone's motion sensors help us track walking patterns and physical activity during your recovery — giving your care team valuable insight into your progress."
        case .location:
            return "Location data helps us understand how much you're moving around day-to-day. This is used only for research purposes and is never shared outside the study."
        case .health:
            return "Connecting to Apple Health lets us read step counts, heart rate, and other metrics that paint a fuller picture of your recovery journey."
        case .notifications:
            return "We'll send gentle daily reminders for check-ins and surveys so nothing slips through the cracks. You can adjust notification timing in Settings."
        }
    }
    /// Label on the primary action button — same for all permissions
    var buttonLabel: String { "Allow Access" }
    /// Step indicator shown above the title (e.g. "STEP 1 OF 4")
    /// Derived from allCases index so it stays accurate if order changes
    var stepLabel: String {
        switch self {
        case .motion:        return "Step 1 of 4"
        case .location:      return "Step 2 of 4"
        case .health:        return "Step 3 of 4"
        case .notifications: return "Step 4 of 4"
        }
    }
}
// MARK: - Permissions Flow Coordinator
//
// The main view that manages the full permissions onboarding sequence.
// Renders one permission card at a time, tracks progress via currentIndex,
// and coordinates between iOS system dialogs and custom UI prompts.
struct PermissionsFlowView: View {
    // MARK: - Persistent State
    //
    // permissionsComplete — stored in UserDefaults via AppStorage.
    // Survives app restarts and logout/login cycles.
    // When true, AuthLoginView skips this flow entirely.
    @AppStorage("permissionsComplete") private var permissionsComplete = false
    // MARK: - Transient UI State
    //
    // These reset every time the view appears — they are not persisted.
    // currentIndex    — which permission card is currently shown (0–3)
    // showingDeniedAlert — true when a permission was denied, shows alert
    // deniedPermissionName — name injected into the denial alert message
    // cardAppeared    — drives the card fade+slide-in animation
    @State private var currentIndex = 0
    @State private var showingDeniedAlert = false
    @State private var deniedPermissionName = ""
    @State private var cardAppeared = false
    // MARK: - Location Always-On State
    //
    // showingAlwaysLocationPrompt — controls the upgrade sheet visibility.
    //   Set to true when user grants "While Using App" instead of "Always".
    //
    // locationContinuation — stores the async continuation from requestLocation()
    //   so it can be resumed AFTER the user acts on the upgrade sheet.
    //   This is necessary because the sheet interaction happens outside
    //   the normal async/await flow — see requestLocation() for full details.
    //
    // locationRequester — holds a strong reference to the CLLocationManager
    //   delegate wrapper so it isn't deallocated before the callback fires.
    @State private var showingAlwaysLocationPrompt = false
    @State private var locationContinuation: CheckedContinuation<Bool, Never>?
    @State private var locationRequester: LocationPermissionRequester?
    // MARK: - Services
    //
    // locationManager — used only for reading authorizationStatus synchronously
    //   in isAlreadyGranted(). Actual permission requests go through
    //   LocationPermissionRequester to avoid delegate lifecycle issues.
    //
    // healthStore — used for HealthKit authorization requests
    private let permissions = JourneyPermission.allCases
    private let locationManager = CLLocationManager()
    private let healthStore = HKHealthStore()
    // Called by AuthLoginView when all permissions are complete.
    // Triggers the transition to MainAppView.
    var onComplete: () -> Void
    // MARK: - Body
    var body: some View {
        ZStack {
            // Warm gradient background — consistent with login screen aesthetic
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
                // Step progress indicator at the top
                progressDots
                    .padding(.top, 60)
                    .padding(.bottom, 32)
                // Current permission card.
                // .id(currentIndex) forces SwiftUI to fully re-render
                // the card when the index changes, which re-triggers
                // the opacity/offset animation for each new card.
                if currentIndex < permissions.count {
                    permissionCard(for: permissions[currentIndex])
                        .id(currentIndex)
                        .opacity(cardAppeared ? 1 : 0)
                        .offset(y: cardAppeared ? 0 : 30)
                        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: cardAppeared)
                }
                Spacer()
            }
        }
        // Animate the first card in when the view appears
        .onAppear { triggerCardAppear() }
        // Denial alert — shown when any permission is denied.
        // "Open Settings" deep-links to this app's iOS Settings page.
        // "Try Again" re-calls requestCurrentPermission() in case
        // the patient just went to Settings and enabled it manually.
        .alert("Permission Required", isPresented: $showingDeniedAlert) {
            Button("Open Settings") { openAppSettings() }
            Button("Try Again") { requestCurrentPermission() }
        } message: {
            Text("Journey needs \(deniedPermissionName) access to continue. Please allow it in Settings.")
        }
        // Location Always-On upgrade sheet.
        // Appears after user grants "While Using App" instead of "Always".
        // interactiveDismissDisabled prevents swipe-to-dismiss —
        // Always access is required and cannot be skipped.
        // See LOCATION SPECIAL CASE in the file header for full context.
        .sheet(isPresented: $showingAlwaysLocationPrompt) {
            AlwaysLocationPromptView(
                onOpenSettings: {
                    // Dismiss sheet, open Settings, then check status after
                    // a short delay to give the patient time to make the change
                    showingAlwaysLocationPrompt = false
                    openAppSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let status = CLLocationManager().authorizationStatus
                        locationContinuation?.resume(returning: status == .authorizedAlways)
                        locationContinuation = nil
                    }
                },
                onCheckAgain: {
                    // Patient tapped "I've updated it" — check current status
                    showingAlwaysLocationPrompt = false
                    let status = CLLocationManager().authorizationStatus
                    if status == .authorizedAlways {
                        // Successfully upgraded — resume continuation with true
                        locationContinuation?.resume(returning: true)
                        locationContinuation = nil
                    } else {
                        // Not yet updated — resume with false then re-show sheet
                        locationContinuation?.resume(returning: false)
                        locationContinuation = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showingAlwaysLocationPrompt = true
                        }
                    }
                }
            )
            .presentationDetents([.medium])
            .presentationCornerRadius(28)
            .interactiveDismissDisabled(true)
        }
    }
    // MARK: - Progress Dots
    //
    // Renders a row of capsule indicators at the top of the screen.
    // The current step's capsule is wider and filled with the accent color.
    // Completed steps stay filled; upcoming steps are faded.
    // Width and color animate smoothly as currentIndex changes.
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
    //
    // Builds the card UI for a given JourneyPermission.
    // All visual properties (color, icon, text) come from the enum —
    // this function is purely layout and doesn't need to change when
    // new permissions are added.
    private func permissionCard(for permission: JourneyPermission) -> some View {
        VStack(spacing: 28) {
            // Double-circle icon — outer ring is a soft tinted halo,
            // inner circle has a gradient fill with a drop shadow
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
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }
            // Text stack — step label, title, headline, explanation
            VStack(spacing: 10) {
                // Uppercase step counter (e.g. "STEP 1 OF 4")
                Text(permission.stepLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                    .tracking(1.2)
                    .textCase(.uppercase)
                // Permission name — large and bold
                Text(permission.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                // Short subtitle in accent color
                Text(permission.headline)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.62, blue: 0.55))
                // Longer patient-friendly explanation
                Text(permission.explanation)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29).opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
            // Primary action button — triggers requestCurrentPermission()
            // Uses the permission's accent color for the gradient background
            Button(action: requestCurrentPermission) {
                Text(permission.buttonLabel)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [permission.iconColor, permission.iconColor.opacity(0.80)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: permission.iconColor.opacity(0.35), radius: 10, y: 5)
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
    // MARK: - Permission Gate
    //
    // isAlreadyGranted() — called before showing the iOS dialog.
    // If the patient already granted a permission (e.g. on a previous
    // attempt), we skip the dialog and advance directly.
    // This handles the case where a patient denied one permission,
    // went to Settings to fix it, and relaunched the app.
    //
    // NOTE: location requires authorizedAlways specifically —
    // authorizedWhenInUse alone is not sufficient for this study.
    private func isAlreadyGranted(_ permission: JourneyPermission) -> Bool {
        switch permission {
        case .motion:
            return CMMotionActivityManager.authorizationStatus() == .authorized
        case .location:
            // WhenInUse is NOT enough — must be Always for background tracking
            let status = locationManager.authorizationStatus
            return status == .authorizedWhenInUse || status == .authorizedAlways
        case .health:
            // HealthKit always returns "authorized" from the app's perspective
            // even if the user denied individual data types — so we always proceed
            return true
        case .notifications:
            // Cannot check synchronously — always show the prompt
            // UNUserNotificationCenter.getNotificationSettings() is async
            return false
        }
    }
    // MARK: - Request Coordinator
    //
    // Entry point when patient taps "Allow Access".
    // Checks isAlreadyGranted first to avoid redundant prompts,
    // then dispatches to the appropriate async handler.
    // On grant → advances to next card.
    // On deny  → shows the denial alert with Settings deeplink.
    private func requestCurrentPermission() {
        guard currentIndex < permissions.count else { return }
        let permission = permissions[currentIndex]
        // Skip the dialog if already authorized — advance directly
        if isAlreadyGranted(permission) {
            advanceToNext()
            return
        }
        Task {
            let granted: Bool
            switch permission {
            case .motion:        granted = await requestMotion()
            case .location:      granted = await requestLocation()
            case .health:        granted = await requestHealth()
            case .notifications: granted = await requestNotifications()
            }
            await MainActor.run {
                if granted {
                    advanceToNext()
                } else {
                    // Show blocking alert — patient must grant all permissions
                    deniedPermissionName = permission.title
                    showingDeniedAlert = true
                }
            }
        }
    }
    // MARK: - Advance Logic
    //
    // Called after each successful permission grant.
    // Fades out the current card, increments the index,
    // then fades in the next card with a slight delay.
    // On the final permission, sets permissionsComplete = true
    // and calls onComplete() to transition to MainAppView.
    private func advanceToNext() {
        cardAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if currentIndex + 1 >= permissions.count {
                // All permissions granted — mark complete and exit flow
                permissionsComplete = true
                onComplete()
            } else {
                currentIndex += 1
                triggerCardAppear()
            }
        }
    }
    /// Triggers the card fade+slide-in animation.
    /// The brief delay ensures SwiftUI has finished re-rendering
    /// the new card before the animation starts.
    private func triggerCardAppear() {
        cardAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            cardAppeared = true
        }
    }
    // MARK: - Individual Permission Handlers
    //
    // Each handler is responsible for:
    //   1. Triggering the iOS system permission dialog
    //   2. Waiting for the patient's response
    //   3. Returning true (granted) or false (denied)
    //
    // All handlers use withCheckedContinuation to bridge the
    // callback-based iOS permission APIs into Swift async/await.
    /// Motion permission handler.
    /// Uses startActivityUpdates() rather than a one-off query because
    /// it more reliably triggers the iOS permission dialog.
    /// Falls back to true on simulator where motion is unavailable.
    private func requestMotion() async -> Bool {
        await withCheckedContinuation { continuation in
            guard CMMotionActivityManager.isActivityAvailable() else {
                // Simulator doesn't have motion hardware — skip gracefully
                continuation.resume(returning: true)
                return
            }
            let manager = CMMotionActivityManager()
            // startActivityUpdates triggers the permission dialog
            manager.startActivityUpdates(to: .main) { _ in }
            // After 1 second, check the resulting authorization status.
            // The delay gives iOS time to process the patient's response.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                manager.stopActivityUpdates()
                let status = CMMotionActivityManager.authorizationStatus()
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    /// Location permission handler.
    /// This is the most complex handler due to iOS's two-step Always process.
    ///
    /// Flow:
    ///   1. LocationPermissionRequester triggers requestAlwaysAuthorization()
    ///   2. iOS shows "Allow Once / While Using / Don't Allow" (Always not shown)
    ///   3. If denied → continuation resumes with false immediately
    ///   4. If granted (WhenInUse) → continuation is NOT resumed yet.
    ///      Instead, locationContinuation stores it and the upgrade sheet appears.
    ///   5. AlwaysLocationPromptView guides patient to Settings → Always
    ///   6. Patient returns and taps "I've updated it"
    ///   7. sheet callbacks in body resume locationContinuation with true/false
    ///
    /// The continuation must be stored as @State because it needs to survive
    /// across the async gap while the sheet is visible.
    private func requestLocation() async -> Bool {
        await withCheckedContinuation { continuation in
            let requester = LocationPermissionRequester { granted in
                self.locationRequester = nil
                if granted {
                    let status = CLLocationManager().authorizationStatus
                    if status == .authorizedAlways {
                        // Already Always (e.g. on retry) — advance immediately
                        continuation.resume(returning: true)
                    } else {
                        // WhenInUse granted — store continuation and show upgrade sheet
                        // Continuation will be resumed by the sheet's button callbacks
                        self.locationContinuation = continuation
                        DispatchQueue.main.async {
                            self.showingAlwaysLocationPrompt = true
                        }
                    }
                } else {
                    // Denied outright — resume immediately with false
                    continuation.resume(returning: false)
                }
            }
            // Store strong reference — prevents deallocation before callback fires
            self.locationRequester = requester
            requester.request()
        }
    }
    /// Health permission handler.
    /// Requests read access to step count and heart rate.
    /// HealthKit's requestAuthorization always calls the completion
    /// with success=true from the app's perspective — the patient's
    /// individual data type choices are not exposed to the app.
    /// Returns false only if HealthKit is unavailable on the device.
    private func requestHealth() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let types: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!
        ]
        return await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: nil, read: types) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
    /// Notification permission handler.
    /// Requests alert, sound, and badge permissions.
    /// Returns true if granted, false if denied.
    private func requestNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
    /// Opens this app's page in iOS Settings.
    /// Used by the denial alert and the Always Location upgrade sheet.
    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
// MARK: - Always Location Prompt View
//
// A non-dismissable sheet shown immediately after the patient grants
// "While Using App" location access. iOS does not allow apps to show
// the "Always Allow" option on the first prompt (iOS 13+ restriction),
// so this sheet bridges the gap by guiding the patient to Settings.
//
// CANNOT be swiped away — .interactiveDismissDisabled(true) is set
// by the parent. Always access is required to continue the flow.
//
// BUTTON BEHAVIOR:
//   "Open Settings"   → opens iOS Settings deep link, then after 1 second
//                        checks if status changed to Always and resumes continuation
//   "I've updated it" → immediately checks status:
//                        → Always: resumes continuation with true → flow advances
//                        → Not Always: resumes with false → sheet re-appears
struct AlwaysLocationPromptView: View {
    var onOpenSettings: () -> Void
    var onCheckAgain: () -> Void
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
                // Location icon — sage green to match the location permission card
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
                        .shadow(
                            color: Color(red: 0.42, green: 0.62, blue: 0.55).opacity(0.4),
                            radius: 12, y: 5
                        )
                    Image(systemName: "location.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                }
                // Explanatory text
                VStack(spacing: 10) {
                    Text("One more step")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                    Text("Always On location is required")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.42, green: 0.62, blue: 0.55))
                    Text("To accurately track your recovery, Journey needs location access even when the app is in the background. Please update this setting now — it only takes a few seconds.")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29).opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 8)
                }
                // Numbered step-by-step instructions
                VStack(alignment: .leading, spacing: 10) {
                    instructionStep(number: "1", text: "Tap \"Open Settings\" below")
                    instructionStep(number: "2", text: "Tap \"Location\"")
                    instructionStep(number: "3", text: "Select \"Always\"")
                    instructionStep(number: "4", text: "Come back and tap \"I've updated it\"")
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.6))
                )
                // Action buttons
                VStack(spacing: 10) {
                    // Primary — opens iOS Settings deep link
                    Button(action: onOpenSettings) {
                        Text("Open Settings")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
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
                            .shadow(
                                color: Color(red: 0.42, green: 0.62, blue: 0.55).opacity(0.35),
                                radius: 10, y: 5
                            )
                    }
                    // Secondary — checks if patient already made the change
                    Button(action: onCheckAgain) {
                        Text("I've updated it")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
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
    }
    /// Renders a single numbered instruction row with a filled circle number badge
    private func instructionStep(number: String, text: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.42, green: 0.62, blue: 0.55))
                    .frame(width: 26, height: 26)
                Text(number)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text(text)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Spacer()
        }
    }
}
// MARK: - Location Permission Requester
//
// A helper class that wraps CLLocationManager's delegate pattern
// into a simple callback interface used by requestLocation().
//
// WHY A SEPARATE CLASS:
// CLLocationManager requires a delegate object to receive authorization
// callbacks. SwiftUI views can't be delegates directly. This class
// owns the CLLocationManager instance, sets itself as delegate, and
// converts the delegate callback into a simple (Bool) -> Void closure.
//
// MEMORY MANAGEMENT:
// The instance is stored in PermissionsFlowView's @State locationRequester
// property to keep it alive for the duration of the authorization request.
// It is set to nil in the completion callback once it has fired.
//
// DOUBLE-RESUME PROTECTION:
// The resumed flag ensures the completion is called at most once,
// guarding against edge cases where the delegate fires multiple times.
class LocationPermissionRequester: NSObject, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var completion: ((Bool) -> Void)?
    private var resumed = false
    init(completion: @escaping (Bool) -> Void) {
        self.manager = CLLocationManager()
        self.completion = completion
        super.init()
        self.manager.delegate = self
    }
    /// Checks current status and either resolves immediately or
    /// triggers the iOS authorization dialog for undetermined status.
    func request() {
        DispatchQueue.main.async {
            let status = self.manager.authorizationStatus
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                // Already authorized — resolve immediately without showing dialog
                self.resume(true)
            case .denied, .restricted:
                // Previously denied — resolve with false, alert will handle it
                self.resume(false)
            case .notDetermined:
                // First time asking — trigger the iOS system dialog
                // Note: requestAlwaysAuthorization() shows "While Using / Don't Allow"
                // on first prompt. "Always" requires a second step via Settings.
                self.manager.requestAlwaysAuthorization()
            @unknown default:
                self.resume(false)
            }
        }
    }
    /// Called by iOS when the patient responds to the permission dialog
    /// or when authorization status changes (e.g. changed in Settings)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            let status = manager.authorizationStatus
            // Ignore notDetermined — wait for an actual decision
            guard status != .notDetermined else { return }
            self.resume(status == .authorizedWhenInUse || status == .authorizedAlways)
        }
    }
    /// Thread-safe single-fire completion resolver.
    /// Sets resumed = true on first call to prevent double-resuming
    /// the async continuation, which would cause a runtime crash.
    private func resume(_ granted: Bool) {
        guard !resumed else { return }
        resumed = true
        completion?(granted)
        completion = nil
    }
}



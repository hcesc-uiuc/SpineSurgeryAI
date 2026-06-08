//
//  PermissionsFlowView.swift
//  SensingApp
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
// all permissions required by the Journey app.
//
// This view is shown whenever permissionsComplete == false, which
// can happen in three situations:
//   1. First ever install — user has never granted permissions
//   2. Reinstall — detectReinstall() in AuthLoginView cleared the flag
//   3. Permission revoked — auditPermissions() in AuthLoginView detected
//      a missing permission and reset the flag
//
// In all cases, the flow starts from the FIRST permission that is
// not yet in the required state (via computeStartIndex()), so users
// who already granted some permissions don't see redundant prompts.
//
// REQUIRED PERMISSIONS (in order):
//   1. Motion & Activity  — CMMotionActivityManager (CoreMotion)
//   2. Location           — CLLocationManager — requires ALWAYS (not WhenInUse)
//   3. Health Data        — HKHealthStore (HealthKit)
//   4. Notifications      — UNUserNotificationCenter
//
// LOCATION SPECIAL CASE:
//   iOS forces a two-step process for "Always" location access.
//   Step 1: requestAlwaysAuthorization() shows "While Using / Don't Allow"
//   Step 2: AlwaysLocationPromptView guides user to Settings → Always
//   The flow does not advance until authorizedAlways is confirmed.
//
// PERMISSION PERSISTENCE:
//   iOS permissions are system-level and survive app reinstall.
//   permissionsComplete (AppStorage/UserDefaults) does NOT reliably
//   survive reinstall — see AuthLoginView.detectReinstall() for how
//   we handle that using a Keychain sentinel instead.
//
// ============================================================

// MARK: - Permission Model

enum JourneyPermission: CaseIterable, Identifiable {
    case motion, location, health, notifications

    var id: Self { self }

    var icon: String {
        switch self {
        case .motion:        return "figure.walk.motion"
        case .location:      return "location.fill"
        case .health:        return "heart.fill"
        case .notifications: return "bell.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .motion:        return Color(red: 0.80, green: 0.65, blue: 0.58)
        case .location:      return Color(red: 0.42, green: 0.62, blue: 0.55)
        case .health:        return Color(red: 0.80, green: 0.35, blue: 0.38)
        case .notifications: return Color(red: 0.55, green: 0.48, blue: 0.75)
        }
    }

    var title: String {
        switch self {
        case .motion:        return "Motion & Activity"
        case .location:      return "Location Access"
        case .health:        return "Health Data"
        case .notifications: return "Reminders"
        }
    }

    var headline: String {
        switch self {
        case .motion:        return "Track your movement patterns"
        case .location:      return "Understand your daily activity"
        case .health:        return "Connect with your health metrics"
        case .notifications: return "Stay on top of your recovery"
        }
    }

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

    var buttonLabel: String { "Allow Access" }

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

struct PermissionsFlowView: View {

    @AppStorage("permissionsComplete") private var permissionsComplete = false

    @State private var currentIndex = 0
    @State private var showingDeniedAlert = false
    @State private var deniedPermissionName = ""
    @State private var cardAppeared = false

    // Location Always-On state
    @State private var showingAlwaysLocationPrompt = false
    @State private var locationContinuation: CheckedContinuation<Bool, Never>?
    @State private var locationRequester: LocationPermissionRequester?

    private let permissions = JourneyPermission.allCases
    private let locationManager = CLLocationManager()
    private let healthStore = HKHealthStore()

    var onComplete: () -> Void

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
                    .padding(.top, 60)
                    .padding(.bottom, 32)

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
        .onAppear {
            // Start from the first permission that isn't yet satisfied
            // so users who already granted some don't repeat them
            currentIndex = computeStartIndex()
            triggerCardAppear()
        }
        .alert("Permission Required", isPresented: $showingDeniedAlert) {
            Button("Open Settings") { openAppSettings() }
            Button("Try Again")     { requestCurrentPermission() }
        } message: {
            Text("Journey needs \(deniedPermissionName) access to continue. Please allow it in Settings.")
        }
        .sheet(isPresented: $showingAlwaysLocationPrompt) {
            AlwaysLocationPromptView(
                onOpenSettings: {
                    showingAlwaysLocationPrompt = false
                    openAppSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let status = CLLocationManager().authorizationStatus
                        locationContinuation?.resume(returning: status == .authorizedAlways)
                        locationContinuation = nil
                    }
                },
                onCheckAgain: {
                    showingAlwaysLocationPrompt = false
                    let status = CLLocationManager().authorizationStatus
                    if status == .authorizedAlways {
                        locationContinuation?.resume(returning: true)
                        locationContinuation = nil
                    } else {
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

    // MARK: - Compute Start Index
    //
    // Finds the first permission not yet in the required state.
    // Called on .onAppear so the flow resumes from where the user left off
    // rather than always starting from step 1.
    //
    // This handles the case where auditPermissions() detected a single
    // revoked permission (e.g. notifications) — we jump straight to that card.
    private func computeStartIndex() -> Int {
        for (index, permission) in permissions.enumerated() {
            if !isAlreadyGranted(permission) {
                return index
            }
        }
        // All granted — shouldn't normally reach here since AuthLoginView
        // would have set permissionsComplete = true, but handle gracefully
        return permissions.count - 1
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
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 10) {
                Text(permission.stepLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                    .tracking(1.2)
                    .textCase(.uppercase)

                Text(permission.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                Text(permission.headline)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.62, blue: 0.55))

                Text(permission.explanation)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29).opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }

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

    // MARK: - isAlreadyGranted
    //
    // Returns true only when the permission is in the FULLY required state.
    // Used by both computeStartIndex() and requestCurrentPermission().
    //
    // IMPORTANT — Location:
    //   authorizedWhenInUse is NOT accepted. Must be authorizedAlways.
    //   This was a bug in the previous version that allowed users to
    //   slip through with only "While Using" access.
    //
    // IMPORTANT — Notifications:
    //   .provisional counts as not granted — we need explicit .authorized.
    //   This is checked asynchronously; the sync version here is conservative
    //   (returns false unless we already know it's authorized).
    private func isAlreadyGranted(_ permission: JourneyPermission) -> Bool {
        switch permission {
        case .motion:
            return CMMotionActivityManager.authorizationStatus() == .authorized

        case .location:
            // ← Fixed: WhenInUse is no longer accepted here
            return locationManager.authorizationStatus == .authorizedAlways

        case .health:
            // HealthKit doesn't expose per-type status to the app.
            // isHealthDataAvailable() confirms the device supports HealthKit.
            // We treat this as granted if available — same as requestHealth() logic.
            return HKHealthStore.isHealthDataAvailable()

        case .notifications:
            // UNUserNotificationCenter.getNotificationSettings() is async —
            // we can't call it synchronously here. Return false to always
            // show the card; requestNotifications() handles the already-granted case
            // gracefully (iOS won't re-prompt, it just calls the completion immediately).
            return false
        }
    }

    // MARK: - Request Coordinator
    //
    // Entry point when patient taps "Allow Access".
    // If already granted → advance directly without showing a dialog.
    // Otherwise → call the appropriate async permission handler.
    private func requestCurrentPermission() {
        guard currentIndex < permissions.count else { return }
        let permission = permissions[currentIndex]

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
                    deniedPermissionName = permission.title
                    showingDeniedAlert = true
                }
            }
        }
    }

    // MARK: - Advance Logic
    private func advanceToNext() {
        cardAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if currentIndex + 1 >= permissions.count {
                permissionsComplete = true
                onComplete()
            } else {
                currentIndex += 1
                triggerCardAppear()
            }
        }
    }

    private func triggerCardAppear() {
        cardAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            cardAppeared = true
        }
    }

    // MARK: - Permission Handlers

    /// Motion — triggers system dialog via startActivityUpdates.
    /// Returns true if authorized, true on simulator (no hardware).
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

    /// Location — requires authorizedAlways.
    /// Two-step: system dialog → AlwaysLocationPromptView → Settings.
    /// The continuation is held in @State until the sheet resolves it.
    private func requestLocation() async -> Bool {
        await withCheckedContinuation { continuation in
            let requester = LocationPermissionRequester { granted in
                self.locationRequester = nil
                if granted {
                    let status = CLLocationManager().authorizationStatus
                    if status == .authorizedAlways {
                        continuation.resume(returning: true)
                    } else {
                        // WhenInUse granted — store continuation, show upgrade sheet
                        self.locationContinuation = continuation
                        DispatchQueue.main.async {
                            self.showingAlwaysLocationPrompt = true
                        }
                    }
                } else {
                    continuation.resume(returning: false)
                }
            }
            self.locationRequester = requester
            requester.request()
        }
    }

    /// Health — requestAuthorization always calls completion with success=true
    /// from the app's side. Returns false only if HealthKit unavailable.
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

    /// Notifications — requests alert, sound, badge.
    /// If already authorized, iOS calls completion immediately with granted=true
    /// without showing a dialog — safe to call even on re-prompt.
    private func requestNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()

        // Check current status first — if already authorized, advance without dialog
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized {
            return true
        }

        // Not yet authorized (or denied) — request or direct to Settings
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Always Location Prompt View
//
// Non-dismissable sheet guiding the user to Settings → Location → Always.
// Shown after user grants "While Using App" on the first location prompt.
// iOS 13+ restriction prevents showing "Always" on the initial dialog.

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
// Wraps CLLocationManager's delegate pattern into a simple callback.
// Stored in @State to keep it alive during the async authorization wait.
// Double-resume protection via the resumed flag.

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

    func request() {
        DispatchQueue.main.async {
            let status = self.manager.authorizationStatus
            switch status {
            case .authorizedAlways:
                self.resume(true)
            case .authorizedWhenInUse:
                // Has WhenInUse — will need the upgrade sheet, treat as "granted" here
                // so requestLocation() can detect it and show AlwaysLocationPromptView
                self.resume(true)
            case .denied, .restricted:
                self.resume(false)
            case .notDetermined:
                self.manager.requestAlwaysAuthorization()
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

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
    //case motion, location, sensorKit, notifications, health
    case motion, location, notifications, health
    
    var id: Self { self }

    var icon: String {
        switch self {
        case .motion:        return "figure.walk.motion"
        case .location:      return "location.fill"
        // case .sensorKit:     return "iphone.radiowaves.left.and.right"
        case .notifications: return "bell.fill"
        case .health:        return "heart.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .motion:        return Color(red: 0.80, green: 0.65, blue: 0.58)
        case .location:      return Color(red: 0.42, green: 0.62, blue: 0.55)
        // case .sensorKit:     return Color(red: 0.38, green: 0.55, blue: 0.75)
        case .notifications: return Color(red: 0.55, green: 0.48, blue: 0.75)
        case .health:        return Color(red: 0.80, green: 0.35, blue: 0.38)
        }
    }

    var title: String {
        switch self {
        case .motion:        return "Motion & Activity"
        case .location:      return "Location Access"
        // case .sensorKit:     return "Device Sensors"
        case .notifications: return "Reminders"
        case .health:        return "Health Data"
        }
    }

    var headline: String {
        switch self {
        case .motion:        return "Track your movement patterns"
        case .location:      return "Understand your daily activity"
        // case .sensorKit:     return "Capture device signals"
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
        /*
        case .sensorKit:
            return "Device usage patterns, motion and activity sensors, and health and biometric sensors help us detect subtle behavioral changes that may reflect your recovery progress. All data is anonymized and used for research only."
        */
        case .notifications:
            return "We'll send gentle daily reminders for check-ins and surveys so you are always aware of what to expect."
        case .health:
            return "Connecting to Apple Health lets us read step counts, heart rate, and other metrics that paint a fuller picture of your recovery journey. You'll choose exactly which data types to share."
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
    private let locationManager = CLLocationManager()
    private let healthStore     = HKHealthStore()

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
                    // A single dot carries no information — hide it when only
                    // one card is shown, keeping opacity so layout doesn't shift.
                    .opacity(permissions.count > 1 ? 1 : 0)
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
        .preferredColorScheme(.light)
        .onAppear {
            // Build the filtered list: only permissions that are not currently granted.
            // A genuinely fresh device will have all 5; a returning user with some revoked
            // will see only the cards they still need to grant.
            permissions = JourneyPermission.allCases.filter { !isAlreadyGranted($0) }
            if permissions.isEmpty {
                permissionsComplete = true
                onComplete()
                return
            }
            currentIndex = 0
            triggerCardAppear()
        }
        .alert("Permission Required", isPresented: $showingDeniedAlert) {
            Button("Open Settings") { openAppSettings(for: permissions[currentIndex]) }
            Button("Try Again")     { requestCurrentPermission() }
        } message: {
            Text("Journey needs \(deniedPermissionName) access to continue. Please allow it in Settings.")
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
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 10) {
                // Hide the step counter when only a single card is shown
                // (e.g. one revoked permission) — "Step 1 of 1" is noise.
                if permissions.count > 1 {
                    Text("Step \(currentIndex + 1) of \(permissions.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                        .tracking(1.2)
                        .textCase(.uppercase)
                }

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
    private func isAlreadyGranted(_ permission: JourneyPermission) -> Bool {
        switch permission {
        case .motion:
            // Mirror requestMotion(): if hardware is unavailable (simulator), treat as granted.
            guard CMMotionActivityManager.isActivityAvailable() else { return true }
            return CMMotionActivityManager.authorizationStatus() == .authorized

        case .location:
            return locationManager.authorizationStatus == .authorizedAlways
        
        /*
        case .sensorKit:
            // SensorKit cannot be authorized on the simulator — always skip
            #if targetEnvironment(simulator)
            return true
            #else
            let reader = SRSensorReader(sensor: .ambientLightSensor)
            return reader.authorizationStatus == .authorized
            #endif
         */
            
        case .notifications:
            return UserDefaults.standard.bool(forKey: "journey_notifications_authorized")

        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)!
            let status = healthStore.authorizationStatus(for: stepType)
            return status != .notDetermined
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

        Task {
            let granted: Bool
            switch permission {
            case .motion:        granted = await requestMotion()
            case .location:      granted = await requestLocation()
            // case .sensorKit:     granted = await requestSensorKit()
            case .notifications: granted = await requestNotifications()
            case .health:        granted = await requestHealth()
            }
            await MainActor.run {
                if granted {
                    advanceToNext()
                } else if permission == .location &&
                          CLLocationManager().authorizationStatus == .authorizedWhenInUse {
                    // User tapped "Allow While Using App" — upgrade prompt needed.
                    // Setting state here (on the main actor) is reliable.
                    showingAlwaysLocationPrompt = true
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

    /// SensorKit — requests authorization for all relevant sensor types.
    /// Skipped entirely on simulator (no hardware, no Settings entry).
    /// NOTE: Requires com.apple.developer.sensorkit.reader entitlement.
    private func requestSensorKit() async -> Bool {
        #if targetEnvironment(simulator)
        // SensorKit cannot be authorized on simulator — skip silently
        return true
        #else
        return await withCheckedContinuation { continuation in
            let sensors: Set<SRSensor> = [
                .ambientLightSensor,
                .accelerometer,
                .keyboardMetrics,
                .deviceUsageReport
            ]

            let readers = sensors.map { SRSensorReader(sensor: $0) }

            guard let primaryReader = readers.first else {
                continuation.resume(returning: false)
                return
            }

            primaryReader.delegate = SensorKitAuthDelegate(
                onAuthorized: { continuation.resume(returning: true) },
                onDenied:     { continuation.resume(returning: false) }
            )

            //            SRSensorReader.requestAuthorization(sensors: sensors) { error in
            //                if let error = error {
            //                    print("SensorKit auth error: \(error)")
            //                    continuation.resume(returning: false)
            //                }
            //                // Actual result comes via delegate — don't resume here
            //            }
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

// MARK: - SensorKit Auth Delegate
//
// Bridges SensorKit's delegate pattern into async/await.
// Only used on real devices — simulator path returns true immediately.
private class SensorKitAuthDelegate: NSObject, SRSensorReaderDelegate {
    private var onAuthorized: (() -> Void)?
    private var onDenied:     (() -> Void)?
    private var resolved = false

    init(onAuthorized: @escaping () -> Void, onDenied: @escaping () -> Void) {
        self.onAuthorized = onAuthorized
        self.onDenied     = onDenied
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        guard !resolved else { return }
        resolved = true
        DispatchQueue.main.async {
            if authorizationStatus == .authorized {
                self.onAuthorized?()
            } else {
                self.onDenied?()
            }
            self.onAuthorized = nil
            self.onDenied     = nil
        }
    }
}

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
                            .shadow(color: Color(red: 0.42, green: 0.62, blue: 0.55).opacity(0.35), radius: 10, y: 5)
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
        .preferredColorScheme(.light)
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

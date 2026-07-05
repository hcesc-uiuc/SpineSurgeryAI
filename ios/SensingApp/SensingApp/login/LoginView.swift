//
//  LoginView.swift
//  SensingApp
//

import SwiftUI
import AuthenticationServices
import CoreMotion
import CoreLocation
import UserNotifications
import HealthKit
import SensorKit

// ============================================================
// MARK: - AuthLoginView Documentation
// ============================================================
//
// PURPOSE:
// The root authentication view for the Journey app. Handles:
//   1. Detecting fresh installs and resetting permissions state
//   2. Auditing all 5 required permissions on every launch
//   3. Showing the login screen when not authenticated
//   4. Routing to PermissionsFlowView if any permission is missing
//   5. Routing to MainAppView once authenticated and all permissions granted
//
// NAVIGATION FLOW:
//
//   App Launch
//       └── AuthLoginView.onAppear
//             ├── detectReinstall()   — clears stale UserDefaults on fresh install
//             └── auditPermissions()  — re-checks all 5 permissions every launch
//                   └── if any missing → permissionsComplete = false
//
//       └── AuthLoginView body
//             ├── isAuthenticated = false → loginScreen
//             └── isAuthenticated = true
//                   ├── permissionsComplete = false → PermissionsFlowView
//                   └── permissionsComplete = true  → MainAppView
//
// REINSTALL DETECTION:
//   UserDefaults (AppStorage) can survive app deletion on some devices.
//   Keychain IS reliably cleared on uninstall — we use a Keychain sentinel
//   to detect fresh installs and reset permissionsComplete accordingly.
//
// PERMISSION AUDIT:
//   Checks all 5 permissions: Motion, Location (Always), SensorKit,
//   Notifications, Health. If any are missing → permissionsComplete = false.
//   Real-time mid-session revocation is handled by MainAppView via scenePhase.
//
// NOTIFICATION CONFLICT:
//   AppDelegate.registerForPushNotifications() must NOT call
//   UNUserNotificationCenter.requestAuthorization() — doing so causes
//   iOS to silently skip the prompt in PermissionsFlowView.
//   Remove that call from AppDelegate, keep only registerForRemoteNotifications().
//
// SIMULATOR NOTE:
//   SensorKit cannot be authorized on the iOS simulator. All SensorKit
//   checks are guarded with #if targetEnvironment(simulator) and return
//   true automatically so the audit does not block the flow on simulator.
//
// ============================================================

struct AuthLoginView: View {

    // MARK: - Auth Manager
    // Injected from SensingAppApp — do NOT declare @StateObject here
    @EnvironmentObject private var authManager: SecureAuthManager

    // MARK: - UI State
    @State private var isWorking = false
    @State private var appeared  = false

    // MARK: - Error State
    @State private var errorMessage: String?

    // MARK: - Enrollment Code State
    //
    // First sign-in on a device requires a coordinator-issued 6-digit study
    // code (EnrollmentGate) so random App Store users can't join the study.
    // Apple Sign In completes first; if no enrolled profile exists for that
    // Apple ID we hold the credential here and ask for the code before
    // finishing login. Returning users on this device skip the prompt.
    private struct PendingAppleCredential {
        let identityToken: String
        let fullName: String?
        let appleUserID: String
    }
    @State private var pendingCredential: PendingAppleCredential?
    @State private var showEnrollmentSheet = false
    @State private var enrollmentCodeInput = ""
    @State private var enrollmentError: String?
    @State private var isJoining = false

    // MARK: - Permissions State
    @AppStorage("permissionsComplete") private var permissionsComplete = false

    // MARK: - Logo Assets
    private let logos   = ["uiuclogo", "uiclogo", "upennlogo", "osflogo"]
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    private let installSentinelKey = "journey_install_sentinel"

    // MARK: - Body
    var body: some View {
        if authManager.isAuthenticated {
            if permissionsComplete {
                MainAppView()
            } else {
                PermissionsFlowView(onComplete: {})
            }
        } else {
            loginScreen
        }
    }

    // MARK: - Login Screen UI
    private var loginScreen: some View {
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
                VStack(spacing: 0) {

                    // ── Header ──────────────────────────────────────
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.80, green: 0.65, blue: 0.58),
                                            Color(red: 0.72, green: 0.55, blue: 0.50)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 72, height: 72)
                                .shadow(
                                    color: Color(red: 0.72, green: 0.55, blue: 0.50).opacity(0.35),
                                    radius: 12, y: 6
                                )
                            Image(systemName: "figure.walk.motion")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.bottom, 4)

                        Text("Journey")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                        Text("Your recovery, one day at a time.")
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 60)
                    .padding(.bottom, 36)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : -16)
                    .animation(.easeOut(duration: 0.55).delay(0.1), value: appeared)

                    // ── Sign In Card ─────────────────────────────────
                    VStack(spacing: 16) {

                        Text("Sign in securely with your Apple ID to access your recovery data.")
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(Color(red: 0.45, green: 0.37, blue: 0.34))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)

                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                        } onCompletion: { result in
                            Task { await handleAppleSignIn(result: result) }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .disabled(isWorking)
                        .opacity(isWorking ? 0.6 : 1.0)
                        .overlay {
                            if isWorking {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.black.opacity(0.45))
                                ProgressView().tint(.white)
                            }
                        }

                        if let errorMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 13))
                                Text(errorMessage)
                                    .font(.system(size: 13, design: .rounded))
                            }
                            .foregroundStyle(Color(red: 0.75, green: 0.25, blue: 0.22))
                            .padding(.horizontal, 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        #if DEBUG
                        Button("Skip Sign In (Debug)") {
                            Task {
                                try? await authManager.login(
                                    identityToken: "debug_token",
                                    fullName:      "Test User",
                                    appleUserID:   "debug_apple_user"
                                )
                            }
                        }
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44).opacity(0.7))
                        .padding(.top, 4)
                        #endif
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(Color(red: 0.99, green: 0.97, blue: 0.95).opacity(0.9))
                            .shadow(
                                color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.12),
                                radius: 20, y: 8
                            )
                    )
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                    .animation(.easeOut(duration: 0.55).delay(0.25), value: appeared)

                    Spacer().frame(height: 40)

                    // ── Institution Logos ────────────────────────────
                    VStack(spacing: 12) {
                        Text("A multi-institution research study")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))

                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(logos, id: \.self) { logo in
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.white)
                                        .shadow(
                                            color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08),
                                            radius: 6, y: 2
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14)
                                                .strokeBorder(
                                                    Color(red: 0.80, green: 0.70, blue: 0.66).opacity(0.35),
                                                    lineWidth: 0.5
                                                )
                                        )
                                    Image(logo)
                                        .resizable()
                                        .scaledToFit()
                                        .padding(6)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 64)
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.55).delay(0.4), value: appeared)

                    Spacer().frame(height: 40)
                }
            }
        }
        .onAppear {
            appeared = true
            detectReinstall()     // must run before auditPermissions
            auditPermissions()
        }
        .animation(.default, value: errorMessage)
        .sheet(isPresented: $showEnrollmentSheet, onDismiss: {
            // Cancelled without joining — drop the held credential.
            if !authManager.isAuthenticated { pendingCredential = nil }
            enrollmentCodeInput = ""
            enrollmentError = nil
        }) {
            enrollmentCodeSheet
        }
    }

    // MARK: - Enrollment Code Sheet
    private var enrollmentCodeSheet: some View {
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
                        .fill(Color(red: 0.80, green: 0.55, blue: 0.45).opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "key.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color(red: 0.80, green: 0.55, blue: 0.45))
                }
                .padding(.top, 32)

                VStack(spacing: 8) {
                    Text("Enter Your Study Code")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                    Text("To join the study, enter the 6-digit code given to you by your study coordinator.")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(Color(red: 0.50, green: 0.42, blue: 0.39))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                TextField("6-digit code", text: $enrollmentCodeInput)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white)
                            .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 8, y: 3)
                    )
                    .padding(.horizontal, 40)
                    .onChange(of: enrollmentCodeInput) { _, newValue in
                        // Digits only, max 6
                        let filtered = String(newValue.filter(\.isNumber).prefix(6))
                        if filtered != newValue { enrollmentCodeInput = filtered }
                        enrollmentError = nil
                    }

                if let enrollmentError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 13))
                        Text(enrollmentError)
                            .font(.system(size: 13, design: .rounded))
                    }
                    .foregroundStyle(Color(red: 0.75, green: 0.25, blue: 0.22))
                    .padding(.horizontal, 32)
                }

                Button {
                    Task { await completeEnrollment() }
                } label: {
                    HStack {
                        Spacer()
                        if isJoining {
                            ProgressView().tint(.white)
                        } else {
                            Text("Join Study")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(red: 0.80, green: 0.55, blue: 0.45))
                            .opacity(enrollmentCodeInput.count == 6 ? 1.0 : 0.4)
                    )
                }
                .buttonStyle(.plain)
                .disabled(enrollmentCodeInput.count != 6 || isJoining)
                .padding(.horizontal, 40)

                Button("Cancel") {
                    showEnrollmentSheet = false
                }
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                .disabled(isJoining)

                Spacer()
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isJoining)
        .preferredColorScheme(.light)
    }

    // Validate the code, then finish the login that was held pending it.
    private func completeEnrollment() async {
        guard let credential = pendingCredential else {
            showEnrollmentSheet = false
            return
        }

        guard EnrollmentGate.validate(enrollmentCodeInput) else {
            enrollmentError = "That code wasn't recognized. Please check with your study coordinator."
            return
        }

        isJoining = true
        defer { isJoining = false }

        do {
            try await authManager.login(
                identityToken:  credential.identityToken,
                fullName:       credential.fullName,
                appleUserID:    credential.appleUserID,
                enrollmentCode: enrollmentCodeInput
            )
            // Park the accepted code; ProfileStore.bootstrap folds it into
            // the profile (after attempting a server restore) on first launch.
            ProfileStore.shared.recordEnrollment(
                code: enrollmentCodeInput,
                participantId: ParticipantID.hash(credential.appleUserID)
            )
            pendingCredential = nil
            showEnrollmentSheet = false
        } catch let error as AuthError {
            enrollmentError = error.errorDescription
        } catch {
            enrollmentError = "Something went wrong. Please try again."
        }
    }

    // MARK: - Reinstall Detection
    private func detectReinstall() {
        let sentinel = KeychainManager.shared.read(key: installSentinelKey)
        if sentinel == nil {
            permissionsComplete = false
            KeychainManager.shared.save(
                key:  installSentinelKey,
                data: Data("installed".utf8)
            )
        }
    }

    // MARK: - Permission Audit
    //
    // Checks all 5 required permissions on every launch.
    // Any missing permission resets permissionsComplete = false.
    //
    // HEALTH FIX: Uses actual authorizationStatus for stepCount rather than
    // isHealthDataAvailable() which is always true on a real device.
    //
    // SENSORKIT: Skipped on simulator — cannot be authorized there.
    private func auditPermissions() {
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

    // MARK: - Apple Sign In Handler
    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        isWorking    = true
        defer { isWorking = false }

        switch result {
        case .failure(let error):
            let asError = error as? ASAuthorizationError
            if asError?.code != .canceled {
                errorMessage = "Sign in failed. Please try again."
            }
            return

        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Sign in failed. Please try again."
                return
            }

            guard
                let tokenData     = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                errorMessage = "Sign in failed. Could not read Apple token."
                return
            }

            let fullNameString = [
                credential.fullName?.givenName,
                credential.fullName?.familyName
            ].compactMap { $0 }.joined(separator: " ")
            let fullName: String? = fullNameString.isEmpty ? nil : fullNameString

            let appleUserID = credential.user

            // First sign-in on this device → ask for the coordinator-issued
            // study code before completing login (EnrollmentGate). Returning
            // users already have an enrolled profile and go straight through.
            let participantId = ParticipantID.hash(appleUserID)
            guard ProfileStore.shared.isEnrolled(participantId: participantId) else {
                pendingCredential = PendingAppleCredential(
                    identityToken: identityToken,
                    fullName:      fullName,
                    appleUserID:   appleUserID
                )
                showEnrollmentSheet = true
                return
            }

            do {
                try await authManager.login(
                    identityToken: identityToken,
                    fullName:      fullName,
                    appleUserID:   appleUserID
                )
            } catch let error as AuthError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = "Something went wrong. Please try again."
            }
        }
    }
}

#Preview {
    AuthLoginView()
        .environmentObject(SecureAuthManager())
}

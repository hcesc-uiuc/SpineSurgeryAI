//
//  AuthLoginView.swift
//  SensingApp
//

import SwiftUI
import AuthenticationServices
import CoreMotion
import CoreLocation
import UserNotifications
import HealthKit

// ============================================================
// MARK: - AuthLoginView Documentation
// ============================================================
//
// PURPOSE:
// The root authentication view for the Journey app. Handles:
//   1. Detecting fresh installs and resetting permissions state
//   2. Auditing required permissions on every launch
//   3. Showing the login screen when not authenticated
//   4. Routing to PermissionsFlowView if any permission is missing
//   5. Routing to MainAppView once authenticated and all permissions granted
//
// NAVIGATION FLOW:
//
//   App Launch
//       └── AuthLoginView.onAppear
//             ├── detectReinstall()       — clears stale UserDefaults on fresh install
//             └── auditPermissions()      — re-checks all permissions every launch
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
//   This means permissionsComplete could be true on a fresh install,
//   skipping the permissions flow entirely — users would never be prompted.
//
//   Fix: on first launch after install, we check for a Keychain sentinel key.
//   Keychain IS reliably cleared on uninstall (unlike UserDefaults).
//   If the sentinel is missing → fresh install → clear permissionsComplete.
//   Then we write the sentinel so subsequent launches don't reset.
//
// PERMISSION AUDIT:
//   Even after onboarding, users can revoke permissions in iOS Settings.
//   On every launch, we silently check all required permissions.
//   If any is missing → permissionsComplete = false → PermissionsFlowView shown.
//   This ensures data collection is never silently broken.
//
// ============================================================

struct AuthLoginView: View {

    // MARK: - Auth Manager
    @StateObject private var authManager = SecureAuthManager()

    // MARK: - UI State
    @State private var isWorking = false
    @State private var appeared  = false

    // MARK: - Error State
    @State private var errorMessage: String?

    // MARK: - Permissions State
    //
    // permissionsComplete — AppStorage (UserDefaults).
    // Reset to false by detectReinstall() or auditPermissions() when needed.
    // Only set to true by PermissionsFlowView after all permissions granted.
    @AppStorage("permissionsComplete") private var permissionsComplete = false

    // MARK: - Logo Assets
    private let logos   = ["uiuclogo", "uiclogo", "upennlogo", "osflogo"]
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    // Sentinel key stored in Keychain to detect reinstalls.
    // Keychain is reliably cleared on uninstall; UserDefaults is not.
    private let installSentinelKey = "journey_install_sentinel"

    // MARK: - Body
    var body: some View {
        if authManager.isAuthenticated {
            if permissionsComplete {
                MainAppView(onLogout: { authManager.logout() })
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

                        // MARK: - Sign in with Apple Button
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
                        // ↓ PASTE THIS BLOCK RIGHT HERE ↓
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
                                Image(logo)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 44)
                                    .opacity(0.8)
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
            detectReinstall()       // must run before auditPermissions
            auditPermissions()
        }
        .animation(.default, value: errorMessage)
    }

    // MARK: - Reinstall Detection
    //
    // Checks for the Keychain sentinel written on the previous install.
    // If missing → this is a fresh install → clear permissionsComplete
    // so the user is walked through the permissions flow again.
    //
    // Keychain is cleared on app uninstall; UserDefaults is not.
    // This is the only reliable way to detect a reinstall on iOS.
    private func detectReinstall() {
        let sentinel = KeychainManager.shared.read(key: installSentinelKey)
        if sentinel == nil {
            // Fresh install — reset any stale UserDefaults permissions flag
            permissionsComplete = false
            // Write sentinel so we don't reset again on next launch
            KeychainManager.shared.save(
                key: installSentinelKey,
                data: Data("installed".utf8)
            )
        }
    }

    // MARK: - Permission Audit
    //
    // Called on every app launch after detectReinstall().
    // Checks each required permission synchronously (except notifications,
    // which requires an async call — handled separately).
    //
    // If ANY permission is not in the required state → permissionsComplete = false
    // → body re-evaluates → PermissionsFlowView is shown, focused on the
    //   missing permission card.
    //
    // This catches:
    //   • Users who revoked a permission in iOS Settings after onboarding
    //   • Users who granted "While Using" for location instead of "Always"
    //   • Any edge case where permissionsComplete was set prematurely
    private func auditPermissions() {
        // Motion
        let motionOK = CMMotionActivityManager.authorizationStatus() == .authorized

        // Location — must be Always, not just WhenInUse
        let locationStatus = CLLocationManager().authorizationStatus
        let locationOK = locationStatus == .authorizedAlways

        // Health — HealthKit always reports authorized from app side;
        // we check availability as a proxy (same logic as PermissionsFlowView)
        let healthOK = HKHealthStore.isHealthDataAvailable()

        // All sync checks — if any fail, kick back to permissions flow
        if !motionOK || !locationOK || !healthOK {
            permissionsComplete = false
            return
        }

        // Notifications — async, run in background, update if needed
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let notificationsOK = settings.authorizationStatus == .authorized
            if !notificationsOK {
                await MainActor.run { permissionsComplete = false }
            }
        }
    }

    // MARK: - Apple Sign In Handler
    //
    // Handles the result from SignInWithAppleButton.
    // Extracts identity token, full name (nil after first login), and
    // Apple's stable user ID, then calls authManager.login().
    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        isWorking    = true
        defer { isWorking = false }

        switch result {
        case .failure(let error):
            // ASAuthorizationError.canceled (1001) = user dismissed sheet — no error shown
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

            // Full name — only present on very first Apple login ever.
            // Pass nil when empty — backend only needs it once.
            let fullNameString = [
                credential.fullName?.givenName,
                credential.fullName?.familyName
            ].compactMap { $0 }.joined(separator: " ")
            let fullName: String? = fullNameString.isEmpty ? nil : fullNameString

            let appleUserID = credential.user

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
}

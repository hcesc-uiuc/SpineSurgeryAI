
import SwiftUI
// ============================================================
// MARK: - AuthLoginView Documentation
// ============================================================
//
// PURPOSE:
// The root authentication view for the Journey app. Handles
// three responsibilities:
//   1. Showing the login screen when the patient is not authenticated
//   2. Routing to PermissionsFlowView after first login (if permissions
//      not yet granted)
//   3. Routing to MainAppView once authenticated and permissions complete
//
// NAVIGATION FLOW:
//
//   App Launch
//       └── AuthLoginView
//             ├── isAuthenticated = false
//             │     └── loginScreen (this view)
//             │
//             └── isAuthenticated = true
//                   ├── permissionsComplete = false
//                   │     └── PermissionsFlowView
//                   │           └── onComplete → sets permissionsComplete = true
//                   │                 └── MainAppView
//                   │
//                   └── permissionsComplete = true
//                         └── MainAppView
//
// AUTHENTICATION:
//   Managed by SecureAuthManager (@StateObject).
//   Login hashes the password locally via SHA256 + salt, then sends
//   { userID, passwordHash } to the REST API. On success, access +
//   refresh tokens are stored in Keychain. See SecureAuthManager.swift.
//
// PERSISTENCE:
//   isAuthenticated — managed by SecureAuthManager via Keychain tokens
//   permissionsComplete — persisted via @AppStorage (UserDefaults)
//   Both survive app restarts and are only cleared on explicit logout.
//
// DEMO MODE:
//   While the real server is not yet connected, SecureAuthManager has
//   a demoMode flag that accepts hardcoded test credentials:
//     Patient ID : demo_patient
//     Password   : journey2026
//   Set demoMode = false in SecureAuthManager.swift when the real
//   server endpoint is ready.
// ============================================================
struct AuthLoginView: View {
    // MARK: - Auth Manager
    //
    // SecureAuthManager is the single source of truth for auth state.
    // @StateObject ensures it persists for the lifetime of this view
    // and is not re-created on re-renders.
    // Publishes isAuthenticated which drives the body routing logic.
    @StateObject private var authManager = SecureAuthManager()
    // MARK: - Form State
    //
    // patientID — bound to the User ID text field
    // password  — bound to the password SecureField
    // isWorking — true while the login network request is in flight.
    //             Disables the button and shows a ProgressView spinner.
    // appeared  — drives the staggered fade-in animations on first render
    @State private var patientID: String = ""
    @State private var password: String = ""
    @State private var isWorking = false
    @State private var appeared = false
    // MARK: - Error State
    //
    // errorMessage — shown below the form fields when login fails.
    // Possible values come from AuthError.errorDescription:
    //   • "Incorrect Patient ID or password." — 401 from server
    //   • "Network error: ..."               — no connection / timeout
    //   • "Your session has expired..."      — token refresh failed
    //   • "Server error (500)..."            — unexpected server response
    //   • "Something went wrong..."          — unknown non-AuthError
    // Set to nil at the start of each login attempt to clear old errors.
    // Animates in/out via .animation(.default, value: errorMessage).
    @State private var errorMessage: String?
    // MARK: - Permissions State
    //
    // Mirrors the AppStorage value set by PermissionsFlowView.
    // Read here to decide whether to show PermissionsFlowView or
    // MainAppView after a successful login.
    // Written by PermissionsFlowView — never written here directly.
    @AppStorage("permissionsComplete") private var permissionsComplete = false
    // MARK: - Logo Assets
    //
    // Institution logos displayed at the bottom of the login screen.
    // Image names must match assets added to the Xcode asset catalog.
    // Add or remove logo names here to update the grid.
    private let logos   = ["uiuclogo", "uiclogo", "upennlogo", "osflogo"]
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    // MARK: - Body
    //
    // Routes to one of three views based on auth + permissions state.
    // No animations here — transitions are handled within each child view.
    var body: some View {
        if authManager.isAuthenticated {
            if permissionsComplete {
                // Fully onboarded — show main app
                // onLogout clears Keychain tokens and flips isAuthenticated
                // which causes this body to re-evaluate and show loginScreen
                MainAppView(onLogout: { authManager.logout() })
            } else {
                // Authenticated but permissions not yet granted.
                // onComplete is intentionally empty — PermissionsFlowView
                // sets permissionsComplete = true via AppStorage, which
                // triggers this body to re-evaluate and route to MainAppView.
                PermissionsFlowView(onComplete: {})
            }
        } else {
            // Not authenticated — show the login screen
            loginScreen
        }
    }
    // MARK: - Login Screen UI
    //
    // Full login screen layout — gradient background, app header,
    // form card with fields + error + button, institution logos.
    // Staggered fade-in animations play once on first appear.
    private var loginScreen: some View {
        ZStack {
            // Warm gradient background — consistent across all app screens
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
                    // App icon, name, and tagline.
                    // Fades in first (delay 0.1s) sliding down from above.
                    VStack(spacing: 8) {
                        // Circular icon with walking figure
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
                                .shadow(color: Color(red: 0.72, green: 0.55, blue: 0.50).opacity(0.35), radius: 12, y: 6)
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
                    // ── Form Card ───────────────────────────────────
                    // Floating card containing input fields, error message,
                    // and sign in button. Fades in second (delay 0.25s)
                    // sliding up from below.
                    VStack(spacing: 16) {
                        // User ID input field
                        // textInputAutocapitalization + autocorrectionDisabled
                        // prevent iOS from modifying the patient's typed ID
                        VStack(alignment: .leading, spacing: 6) {
                            Text("User ID")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                .padding(.leading, 4)
                            TextField("Enter your User ID", text: $patientID)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.system(size: 16, design: .rounded))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.white.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color(red: 0.80, green: 0.65, blue: 0.58).opacity(0.4), lineWidth: 1.5)
                                )
                        }
                        // Password input field
                        // SecureField masks input — iOS autofill compatible
                        // via .textContentType(.password)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                .padding(.leading, 4)
                            SecureField("Enter your password", text: $password)
                                .textContentType(.password)
                                .font(.system(size: 16, design: .rounded))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.white.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color(red: 0.80, green: 0.65, blue: 0.58).opacity(0.4), lineWidth: 1.5)
                                )
                        }
                        // MARK: Error Message
                        //
                        // Conditionally shown when errorMessage is non-nil.
                        // Populated by attemptLogin() on any login failure.
                        //
                        // Possible error messages (from AuthError.errorDescription):
                        //   • "Incorrect Patient ID or password."
                        //     → Server returned 401 — wrong credentials
                        //   • "Network error: <detail>"
                        //     → URLSession failed — no connection or timeout
                        //   • "Your session has expired. Please log in again."
                        //     → Token refresh failed on app relaunch
                        //   • "Server error (500). Please try again."
                        //     → Unexpected HTTP status from server
                        //   • "Something went wrong. Please try again."
                        //     → Non-AuthError thrown — unexpected failure
                        //
                        // Cleared to nil at the start of each new login attempt.
                        // Animates in with opacity + slide via
                        // .animation(.default, value: errorMessage) on the ZStack.
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
                        // Sign In button
                        // Disabled when: request in flight OR either field is empty
                        // Shows ProgressView spinner while isWorking = true
                        // opacity reduced to 0.6 when disabled for visual feedback
                        Button(action: { Task { await attemptLogin() } }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16)
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
                                    .frame(height: 54)
                                    .shadow(color: Color(red: 0.34, green: 0.54, blue: 0.48).opacity(0.35), radius: 10, y: 5)
                                if isWorking {
                                    // Spinner shown while network request is in flight
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("Sign In")
                                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .disabled(isWorking || password.isEmpty || patientID.isEmpty)
                        .opacity((isWorking || password.isEmpty || patientID.isEmpty) ? 0.6 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: password.isEmpty || patientID.isEmpty)
                        .padding(.top, 4)
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(Color(red: 0.99, green: 0.97, blue: 0.95).opacity(0.9))
                            .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.12), radius: 20, y: 8)
                    )
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                    .animation(.easeOut(duration: 0.55).delay(0.25), value: appeared)
                    Spacer().frame(height: 40)
                    // ── Institution Logos ───────────────────────────
                    // Displayed at the bottom as trust indicators for patients.
                    // Fades in last (delay 0.4s).
                    // To add/remove logos: update the logos array above.
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
        // Trigger staggered animations when the login screen first appears
        .onAppear { appeared = true }
        // Animate error message appearing/disappearing smoothly
        .animation(.default, value: errorMessage)
    }
    // MARK: - Login Logic
    //
    // Called when the patient taps "Sign In".
    // Runs as an async Task to avoid blocking the main thread.
    //
    // SEQUENCE:
    //   1. Clear any previous error message
    //   2. Set isWorking = true (shows spinner, disables button)
    //   3. Call authManager.login(userID:password:)
    //        → Hashes password locally
    //        → POSTs { user_id, password_hash } to /auth/login
    //        → On success: stores tokens in Keychain, sets isAuthenticated = true
    //        → On failure: throws AuthError
    //   4. defer ensures isWorking = false regardless of outcome
    //   5. On AuthError: sets errorMessage to the patient-friendly description
    //   6. On unknown error: sets a generic fallback message
    //
    // On success, authManager.isAuthenticated flips to true which causes
    // body to re-evaluate and route away from loginScreen automatically.
    private func attemptLogin() async {
        errorMessage = nil  // clear previous error before each attempt
        isWorking    = true
        defer { isWorking = false } // always runs when function exits
        do {
            try await authManager.login(userID: patientID, password: password)
            // On success — body re-evaluates automatically via @Published isAuthenticated
        } catch let error as AuthError {
            // Known auth failure — show typed error message to patient
            errorMessage = error.errorDescription
        } catch {
            // Unexpected error type — show generic fallback
            errorMessage = "Something went wrong. Please try again."
        }
    }
}
#Preview {
    AuthLoginView()
}



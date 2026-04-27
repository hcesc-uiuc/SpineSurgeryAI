//
//import SwiftUI
//
//struct AuthLoginView: View {
//
//    // MARK: - State & Auth Manager
//    @StateObject private var authManager = SecureAuthManager()
//    @State private var userid: String = ""        // Keep for future multi-user support
//    @State private var password: String = ""
//    @State private var isWorking = false
//    @State private var errorMessage: String?
//
//    // MARK: - Logos
//    private let logos = ["uiuclogo", "uiclogo", "upennlogo", "osflogo"]
//    private let columns = [
//        GridItem(.flexible()),
//        GridItem(.flexible())
//    ]
//
//    // MARK: - Body
//    var body: some View {
//        // Show main app if authenticated, otherwise show login screen
//        if authManager.isAuthenticated {
//            MainAppView(onLogout: {
//                authManager.logout() // clears memory + persisted login
//            })
//        } else {
//            loginScreen
//        }
//    }
//
//    // MARK: - Login Screen UI
//    private var loginScreen: some View {
//        NavigationStack {
//            VStack(spacing: 24) {
//
//                // Title
//                Text("Journey")
//                    .font(.largeTitle)
//                    .bold()
//
//                Text("Login")
//                    .font(.title)
//
//                // Input Fields
//                VStack(spacing: 12) {
//                    TextField("User ID", text: $userid)
//                        .textContentType(.username)
//                        .disableAutocorrection(true)
//                        .padding()
//                        .background(.thinMaterial)
//                        .clipShape(RoundedRectangle(cornerRadius: 12))
//
//                    SecureField("Password", text: $password)
//                        .textContentType(.password)
//                        .padding()
//                        .background(.thinMaterial)
//                        .clipShape(RoundedRectangle(cornerRadius: 12))
//                }
//
//                // Error Message
//                if let errorMessage {
//                    Text(errorMessage)
//                        .foregroundColor(.red)
//                        .font(.footnote)
//                }
//
//                // Login Button
//                Button(action: { Task { await attemptLogin() } }) {
//                    if isWorking {
//                        ProgressView()
//                            .tint(.white)
//                            .frame(maxWidth: .infinity)
//                            .padding()
//                            .background(.blue)
//                            .clipShape(RoundedRectangle(cornerRadius: 12))
//                    } else {
//                        Text("Log In")
//                            .foregroundColor(.white)
//                            .frame(maxWidth: .infinity)
//                            .padding()
//                            .background(.blue)
//                            .clipShape(RoundedRectangle(cornerRadius: 12))
//                    }
//                }
//                .disabled(isWorking || password.isEmpty)
//
//                Spacer()
//
//
//                LazyVGrid(columns: columns, spacing: 20) {
//                    ForEach(logos, id: \.self) { logo in
//                        Image(logo)
//                            .resizable()
//                            .scaledToFit()
//                            .frame(height: 60)
//                    }
//                }
//                .padding(.horizontal)
//            }
//            .padding()
//            .navigationTitle("Welcome")
//        }
//    }
//
//    // MARK: - Login Logic
//    private func attemptLogin() async {
//        errorMessage = nil
//        isWorking = true
//        defer { isWorking = false }
//
//        // Simulate a slight delay for UX
//        try? await Task.sleep(nanoseconds: 400_000_000)
//
//        if password.isEmpty {
//            errorMessage = "Please enter a password."
//        } else {
//            authManager.login(password: password)
//
//            if !authManager.isAuthenticated {
//                errorMessage = "Invalid password. Please try again."
//            }
//        }
//    }
//}
//
//#Preview {
//    AuthLoginView()
//}

// MashTodo: Akarsh, remove unused code if you are not using. If you need this code, move it in the end of the file.



import SwiftUI

struct AuthLoginView: View {
    
    @StateObject private var authManager = SecureAuthManager()
    @State private var patientID: String = ""
    @State private var password: String = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var appeared = false
    @AppStorage("permissionsComplete") private var permissionsComplete = false
    
    
    private let logos = ["uiuclogo", "uiclogo", "upennlogo", "osflogo"]
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    
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
    
    private var loginScreen: some View {
        ZStack {
            // Warm gradient background
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
                        // Soft icon mark
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
                    VStack(spacing: 16) {
                        
                        // Patient ID field
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Patient ID")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                .padding(.leading, 4)
                            
                            TextField("Enter your patient ID", text: $patientID)
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
                        
                        // Password field
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
                        
                        // Error message
                        // MashToDo: A line is needed for what the error message is
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
                        
                        // Login button
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
        .onAppear { appeared = true }
        .animation(.default, value: errorMessage)
    }
    
    private func attemptLogin() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }

        try? await Task.sleep(nanoseconds: 400_000_000)

        if password.isEmpty || patientID.isEmpty {
            errorMessage = "Please enter your Patient ID and password."
            return
        }

        do {
            // In demo mode, identityToken/fullName/appleUserID are ignored —
            // SecureAuthManager flips isAuthenticated = true immediately.
            try await authManager.login(
                identityToken: patientID,
                fullName: nil,
                appleUserID: patientID
            )
        } catch {
            errorMessage = "Sign in failed. Please try again."
        }
    }
}

#Preview {
    AuthLoginView()
}

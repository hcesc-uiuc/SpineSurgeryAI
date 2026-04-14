import Foundation
import CryptoKit
import SwiftUI
internal import Combine
// ============================================================
// MARK: - SecureAuthManager Overview
// ============================================================
//
// PURPOSE:
// Manages all authentication state and network auth calls for
// the Journey app. Handles login, logout, token storage, silent
// token refresh, and authenticated API requests.
//
// ARCHITECTURE:
// This class follows a token-based auth pattern using two tokens:
//
//   ACCESS TOKEN  — short-lived (typically 15min–1hr)
//                   attached to every API request as a Bearer token
//                   stored in Keychain
//
//   REFRESH TOKEN — long-lived (days/weeks)
//                   used only to silently obtain a new access token
//                   when the current one expires
//                   stored in Keychain
//
// FLOW:
//   1. Patient enters userID + password
//   2. App hashes password locally using SHA256 + salt
//   3. App sends { user_id, password_hash } to POST /auth/login
//   4. Server verifies and returns { access_token, refresh_token }
//   5. Both tokens stored securely in iOS Keychain
//   6. Every subsequent API call uses access token as Bearer header
//   7. On app relaunch, silentRefresh() is called automatically
//      to restore session without requiring re-login
//   8. If access token expires mid-session, authenticatedRequest()
//      retries once after silently refreshing
//   9. Logout clears all tokens from Keychain
//
// SECURITY NOTES:
//   - Passwords are NEVER sent in plaintext — always SHA256 hashed
//   - Tokens are stored in iOS Keychain, not UserDefaults
//   - Salt is constant for now — consider per-user salt in v2
//   - Hash is returned as hex string for safe JSON transport
//
// TESTING:
//   See MockURLProtocol.swift for local mock server setup.
//   Swap baseURL to "mock://journey" to run without a real server.
//
// TODO:
//   - Replace baseURL placeholder with real endpoint when ready
//   - Consider per-user salt stored server-side for stronger hashing
//   - Add biometric (FaceID) re-auth for sensitive actions
// ============================================================
// MARK: - Demo Mode
//
// TEMPORARY — for simulator testing only while server is not yet ready.
// Set to false before shipping to production or connecting a real server.
// When true, any login attempt with these exact credentials will succeed
// locally without making any network calls.
//
// Demo credentials:
//   Patient ID : demo_patient
//   Password   : journey2026

private let demoMode = true
private let demoID       = "demo_patient"
private let demoPassword = "journey2026"
// MARK: - Token Response Model
//
// Maps the JSON response from POST /auth/login and POST /auth/refresh
// to a Swift struct. CodingKeys handle snake_case → camelCase conversion.
//
// Expected server JSON:
// {
//   "access_token":  "eyJhbGci...",
//   "refresh_token": "dGhpcyBp..."
// }
struct AuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String
    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
    }
}
// MARK: - Auth Error
//
// Typed error enum covering all failure states in the auth flow.
// Each case maps to a patient-friendly error message shown in the UI.
// Using LocalizedError allows these to be caught and displayed directly.
enum AuthError: LocalizedError {
    case invalidCredentials  // 401 from server — wrong ID or password
    case networkError(String)// URLSession failure — no connection etc.
    case tokenExpired        // Access token expired and refresh failed
    case noRefreshToken      // No stored session — must log in fresh
    case serverError(Int)    // Unexpected HTTP status code from server
    case decodingError       // Server returned unexpected JSON shape
    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Incorrect Patient ID or password."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .tokenExpired:
            return "Your session has expired. Please log in again."
        case .noRefreshToken:
            return "No session found. Please log in again."
        case .serverError(let code):
            return "Server error (\(code)). Please try again."
        case .decodingError:
            return "Unexpected server response. Please try again."
        }
    }
}
// MARK: - Secure Auth Manager
/// Central authentication manager for the Journey app.
/// Marked @MainActor so all @Published property updates
/// happen on the main thread, keeping the UI in sync.
@MainActor
class SecureAuthManager: ObservableObject {
    // MARK: - Published State
    //
    // These drive the UI directly via SwiftUI's observation system.
    // isAuthenticated → controls whether login or main app is shown
    // isRefreshing    → can be used to show a loading state on launch
    @Published var isAuthenticated = false
    @Published var isRefreshing    = false
    
    // MARK: - Keychain Keys
    //
    // String keys used to store/retrieve each value from iOS Keychain.
    // Kept private — nothing outside this class should read tokens directly.
    // All sensitive data access goes through this class's methods.
    private let accessTokenKey  = "journey_access_token"
    private let refreshTokenKey = "journey_refresh_token"
    private let userIDKey       = "journey_user_id"
    // MARK: - Password Hashing Config
    //
    // Salt is appended to the password before hashing to prevent
    // rainbow table attacks. Currently a constant — ideally this
    // would be a per-user salt stored server-side in production.
    private let salt = "study_app_salt_2026"
    // MARK: - API Configuration
    //
    // Base URL for all auth endpoints. Swap this string when the
    // real backend is ready — nothing else needs to change.
    //
    // For local mock testing, this is overridden by MockURLProtocol.
    // See MockURLProtocol.swift for setup instructions.
    var baseURL = "https://placeholder.journeyapi.com"
    // URLSession used for all network calls. Exposed as a var so
    // tests can inject a mock session (see MockURLProtocol.swift).
    var session: URLSession = .shared
    // MARK: - Initializer
    //
    // On launch, checks if a refresh token exists in Keychain.
    // If yes → silently attempts to restore the session.
    // If no  → stays logged out, login screen is shown.
    //
    // This is what keeps patients logged in between app launches
    // without requiring them to re-enter their password every time.
    init() {
        if KeychainManager.shared.read(key: refreshTokenKey) != nil {
            // Refresh token found — attempt silent session restore
            Task { await silentRefresh() }
        }
        // No refresh token → isAuthenticated stays false → login shown
    }
    // MARK: - Login
    //
    // Called when the patient taps "Sign In" on the login screen.
    //
    // Steps:
    //   1. Hash the password locally (never sent as plaintext)
    //   2. Build a POST request with { user_id, password_hash }
    //   3. Send to /auth/login
    //   4. On 200 → decode tokens → store in Keychain → set authenticated
    //   5. On 401 → throw invalidCredentials (wrong ID or password)
    //   6. On other → throw serverError
    //
    // Throws: AuthError — caught in AuthLoginView.attemptLogin()
    func login(userID: String, password: String) async throws {
        
        // Demo mode — bypass network entirely for simulator testing
            // Remove this block when real server is connected
           
   // TEMPORARY DEMO MODE — comment out when running      tests or connecting real server
        
        if demoMode {
                if userID == demoID && password == demoPassword {
                    isAuthenticated = true
                    return
                } else {
                    throw AuthError.invalidCredentials
                }
            }
             
        // Step 1: Hash password — result is a hex string safe for JSON
        let passwordHash = hashPassword(password)
        // Step 2: Build the login request
        guard let url = URL(string: "\(baseURL)/auth/login") else { return }
        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15 // fail fast on no connection
        // Encode request body as JSON
        let body: [String: String] = [
            "user_id":       userID,
            "password_hash": passwordHash
        ]
        request.httpBody = try JSONEncoder().encode(body)
        // Step 3: Fire the request
        let (data, response) = try await session.data(for: request)
        // Step 4: Validate HTTP response
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.networkError("No response from server.")
        }
        switch http.statusCode {
        case 200:
            // Success — decode the token pair from response body
            guard let tokens = try? JSONDecoder().decode(
                AuthTokenResponse.self, from: data
            ) else {
                throw AuthError.decodingError
            }
            // Persist tokens to Keychain and flip auth state
            storeTokens(
                access:  tokens.accessToken,
                refresh: tokens.refreshToken,
                userID:  userID
            )
            isAuthenticated = true
        case 401:
            // Server rejected credentials
            throw AuthError.invalidCredentials
        default:
            // Unexpected status code
            throw AuthError.serverError(http.statusCode)
        }
    }
    // MARK: - Silent Refresh
    //
    // Silently exchanges the stored refresh token for a new access token.
    // Called automatically on app launch (in init) and when a 401 is
    // received mid-session inside authenticatedRequest().
    //
    // If refresh fails for any reason (expired, revoked, network error),
    // all tokens are cleared and the patient is sent back to login.
    // This is intentional — a failed refresh means the session is invalid.
    func silentRefresh() async {
        // Read stored refresh token — if missing, nothing to refresh
        guard let refreshToken = readToken(key: refreshTokenKey) else {
            isAuthenticated = false
            return
        }
        isRefreshing = true
        defer { isRefreshing = false } // always runs when function exits
        // Build refresh request — only sends the refresh token
        guard let url = URL(string: "\(baseURL)/auth/refresh") else { return }
        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let body = ["refresh_token": refreshToken]
        request.httpBody = try? JSONEncoder().encode(body)
        // Attempt the refresh — if anything fails, force re-login
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200,
            let tokens = try? JSONDecoder().decode(AuthTokenResponse.self, from: data)
        else {
            // Refresh failed — wipe tokens and force patient to log in again
            clearTokens()
            isAuthenticated = false
            return
        }
        // Store the new access token
        // Note: some servers also rotate the refresh token on each refresh —
        // we update both here to handle either case
        KeychainManager.shared.save(
            key: accessTokenKey,
            data: Data(tokens.accessToken.utf8)
        )
        KeychainManager.shared.save(
            key: refreshTokenKey,
            data: Data(tokens.refreshToken.utf8)
        )
        isAuthenticated = true
    }
    // MARK: - Authenticated Request Helper
    //
    // Use this for EVERY API call after login — do not use URLSession directly.
    // Automatically attaches the Bearer token to each request.
    // Handles token expiry transparently — if a 401 is received:
    //   1. Silently refreshes the access token
    //   2. Retries the original request once with the new token
    //   3. If refresh also fails → throws tokenExpired
    //
    // Parameters:
    //   endpoint — path after baseURL, e.g. "/surveys/pending"
    //   method   — HTTP method, defaults to "GET"
    //   body     — optional dictionary encoded as JSON request body
    //
    // Returns: raw Data from server response (caller decodes as needed)
    // Throws:  AuthError
    func authenticatedRequest(
        endpoint: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> Data {
        // Retrieve current access token — if missing, session is invalid
        guard let accessToken = readToken(key: accessTokenKey) else {
            throw AuthError.tokenExpired
        }
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw AuthError.networkError("Invalid URL.")
        }
        // Build request with Bearer auth header
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        // Encode body if provided (for POST/PUT requests)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.networkError("No response.")
        }
        switch http.statusCode {
        case 200...299:
            // Success — return raw data for caller to decode
            return data
        case 401:
            // Access token expired — attempt silent refresh then retry once
            await silentRefresh()
            guard isAuthenticated else { throw AuthError.tokenExpired }
            // Recursive retry with fresh token (will not recurse again
            // because silentRefresh sets isAuthenticated = false on failure)
            return try await authenticatedRequest(
                endpoint: endpoint,
                method: method,
                body: body
            )
        default:
            throw AuthError.serverError(http.statusCode)
        }
    }
    // MARK: - Logout
    //
    // Clears all tokens from Keychain and flips auth state to false.
    // AuthLoginView observes isAuthenticated and shows login screen.
    // Note: ideally also call POST /auth/logout on the server to
    // invalidate the refresh token server-side — add when endpoint ready.
    func logout() {
        clearTokens()
        isAuthenticated = false
    }
    // MARK: - Private Helpers
    /// Hashes a password string using SHA256 + constant salt.
    /// Returns a lowercase hex string safe for JSON transport.
    /// Example: "password123" + salt → "a3f9c2..."
    private func hashPassword(_ password: String) -> String {
        let combined = password + salt
        let hashed   = SHA256.hash(data: Data(combined.utf8))
        // Convert each byte to 2-digit hex and join into one string
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
    /// Saves all three auth values to Keychain atomically.
    /// Called immediately after a successful login response.
    private func storeTokens(access: String, refresh: String, userID: String) {
        KeychainManager.shared.save(key: accessTokenKey,  data: Data(access.utf8))
        KeychainManager.shared.save(key: refreshTokenKey, data: Data(refresh.utf8))
        KeychainManager.shared.save(key: userIDKey,       data: Data(userID.utf8))
    }
    /// Removes all auth tokens from Keychain.
    /// Called on logout and when silent refresh fails.
    private func clearTokens() {
        KeychainManager.shared.delete(key: accessTokenKey)
        KeychainManager.shared.delete(key: refreshTokenKey)
        KeychainManager.shared.delete(key: userIDKey)
    }
    /// Reads a token string from Keychain by key.
    /// Returns nil if the key doesn't exist or data is unreadable.
    private func readToken(key: String) -> String? {
        guard let data = KeychainManager.shared.read(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}



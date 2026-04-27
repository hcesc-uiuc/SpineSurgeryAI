//  SecureAuthManager.swift
//  SensingApp
//

import Foundation
import SwiftUI
internal import Combine

// ============================================================
// MARK: - SecureAuthManager Overview
// ============================================================
//
// PURPOSE:
// Manages all authentication state and network auth calls for
// the Journey app. Handles Apple Sign In login, logout, token
// storage, silent token refresh, and authenticated API requests.
//
// ARCHITECTURE:
// Token-based auth using two JWTs issued by the Journey backend
// after it verifies Apple's identity token:
//
//   ACCESS TOKEN  — short-lived (15 min)
//                   attached to every API request as a Bearer token
//                   stored in Keychain
//
//   REFRESH TOKEN — long-lived (365 days)
//                   used only to silently obtain a new access token
//                   stored in Keychain
//
// FLOW:
//   1. Patient taps "Sign in with Apple"
//   2. Apple returns a one-time identity token (JWT) + optional full name
//   3. App sends { identity_token, full_name? } to POST /auth/login
//   4. Backend verifies Apple's JWT and returns { access_token, refresh_token }
//   5. Both tokens stored securely in iOS Keychain
//   6. Every subsequent API call uses access token as Bearer header
//   7. On app relaunch, silentRefresh() restores session automatically
//   8. On 401 from any API call → refresh access token → retry once
//   9. If refresh returns 401 invalid_grant → fully expired → force login
//  10. Logout calls POST /auth/logout (invalidates refresh token server-side)
//      then clears all tokens from Keychain
//
// IMPORTANT — FULL NAME:
//   Apple only provides the user's full name on the very first login ever.
//   It is nil on all subsequent logins. Send it when present — backend
//   discards it if the user already exists.
//
// ============================================================

// ============================================================
// MARK: - ⚠️ DEMO MODE
// ============================================================
// TEMPORARY — for simulator/testing use only while server is not ready.
//
// When true: Apple Sign In still fires on-device but the backend
// call is bypassed — isAuthenticated flips to true immediately.
// No tokens are stored in Keychain during demo mode.
//
// TO REMOVE FOR PRODUCTION (3 steps):
//   1. Delete the three lines below (demoMode declaration)
//   2. Delete the demo block inside login(identityToken:fullName:appleUserID:)
//   3. Delete the demo guard inside logout()
private let demoMode = true
// ============================================================

// MARK: - Backend Error Response
//
// The backend returns { "error": "some_code" } on all auth failures.
// We decode this to distinguish invalid_grant (session dead) from
// token_expired (just needs refresh).
private struct BackendErrorResponse: Decodable {
    let error: String
}

// MARK: - Token Response Models

struct AuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String
    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
    }
}

// Refresh only returns a new access token — refresh token is unchanged
private struct RefreshTokenResponse: Decodable {
    let accessToken: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

// MARK: - Auth Error

enum AuthError: LocalizedError {
    case invalidToken            // Apple identity token rejected by backend (400/401)
    case networkError(String)    // URLSession failure — no connection etc.
    case tokenExpired            // Access token expired and refresh failed
    case noRefreshToken          // No stored session — must log in fresh
    case serverError(Int)        // Unexpected HTTP status from server
    case decodingError           // Server returned unexpected JSON shape

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Sign in failed. Please try again."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .tokenExpired:
            return "Your session has expired. Please sign in again."
        case .noRefreshToken:
            return "No session found. Please sign in again."
        case .serverError(let code):
            return "Server error (\(code)). Please try again."
        case .decodingError:
            return "Unexpected server response. Please try again."
        }
    }
}

// MARK: - Secure Auth Manager

/// Central authentication manager for the Journey app.
/// @MainActor ensures all @Published updates happen on the main thread.
@MainActor
class SecureAuthManager: ObservableObject {

    // MARK: - Published State
    @Published var isAuthenticated = false
    @Published var isRefreshing    = false

    // MARK: - Keychain Keys
    private let accessTokenKey  = "journey_access_token"
    private let refreshTokenKey = "journey_refresh_token"
    private let appleUserIDKey  = "journey_apple_user_id"

    // MARK: - API Configuration
    //
    // Swap this string when the backend URL is confirmed.
    // Nothing else needs to change — all endpoints build from this.
    var baseURL = "http://18.116.67.186"

    var session: URLSession = .shared

    // MARK: - Init
    init() {
        if KeychainManager.shared.read(key: refreshTokenKey) != nil {
            Task { await silentRefresh() }
        }
    }

    // MARK: - Login (Apple Sign In)
    //
    // Called after a successful Apple Sign In authorization.
    //
    // Parameters:
    //   identityToken — one-time JWT from Apple (credential.identityToken)
    //   fullName      — user's name; only present on very first Apple login.
    //                   Pass nil when empty — backend only needs it once.
    //   appleUserID   — Apple's stable per-user identifier (credential.user)
    //
    // Throws: AuthError
    func login(identityToken: String, fullName: String?, appleUserID: String) async throws {

        // ── ⚠️ DEMO MODE BLOCK — DELETE BEFORE SHIPPING ─────────────
        if demoMode {
            isAuthenticated = true
            return
        }
       // ── END DEMO MODE BLOCK ──────────────────────────────────────

        guard let url = URL(string: "\(baseURL)/auth/login") else { return }
        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // Only include full_name when Apple actually provided it.
        // Backend ignores it for existing users; stores it for new ones.
        var body: [String: String] = ["identity_token": identityToken]
        if let name = fullName { body["full_name"] = name }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.networkError("No response from server.")
        }

        switch http.statusCode {
        case 200:
            guard let tokens = try? JSONDecoder().decode(AuthTokenResponse.self, from: data) else {
                throw AuthError.decodingError
            }
            storeTokens(
                access:      tokens.accessToken,
                refresh:     tokens.refreshToken,
                appleUserID: appleUserID
            )
            isAuthenticated = true

        case 400, 401:
            throw AuthError.invalidToken

        default:
            throw AuthError.serverError(http.statusCode)
        }
    }

    // MARK: - Silent Refresh
    //
    // Exchanges the stored refresh token for a new access token.
    // Called on app launch (init) and on 401 inside authenticatedRequest().
    //
    // 401 → session fully dead → clear tokens, force login
    // Any other failure → same result (conservative — avoids stale state)
    //
    // Note: per the backend spec, only the access token is rotated on refresh.
    // The refresh token stays the same until logout or expiry (365 days).
    func silentRefresh() async {
        guard let refreshToken = readToken(key: refreshTokenKey) else {
            isAuthenticated = false
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        guard let url = URL(string: "\(baseURL)/auth/refresh") else { return }
        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONEncoder().encode(["refresh_token": refreshToken])

        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else {
            clearTokens()
            isAuthenticated = false
            return
        }

        switch http.statusCode {
        case 200:
            guard let refreshed = try? JSONDecoder().decode(RefreshTokenResponse.self, from: data) else {
                clearTokens()
                isAuthenticated = false
                return
            }
            // Only replace the access token — refresh token is unchanged
            KeychainManager.shared.save(key: accessTokenKey, data: Data(refreshed.accessToken.utf8))
            isAuthenticated = true

        default:
            // 401 invalid_grant or any other failure — session is dead
            clearTokens()
            isAuthenticated = false
        }
    }

    // MARK: - Authenticated Request Helper
    //
    // Use this for EVERY API call after login.
    // Attaches the Bearer token and handles 401 → refresh → retry once.
    //
    // On 401 from an API call:
    //   - Decodes the backend error code from the response body
    //   - invalid_grant → session dead, clear tokens, throw immediately
    //   - token_expired / invalid_token → silentRefresh() then retry once
    //   - If refresh also fails → throws tokenExpired
    //
    // Parameters:
    //   endpoint — path after baseURL, e.g. "/api/surveys/pending"
    //   method   — HTTP method, defaults to "GET"
    //   body     — optional dictionary encoded as JSON (for POST/PUT)
    //
    // Returns: raw Data (caller decodes)
    // Throws:  AuthError
    func authenticatedRequest(
        endpoint: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> Data {

        // ── ⚠️ DEMO MODE: skip auth, send request without Bearer token ──
        if demoMode {
            guard let url = URL(string: "\(baseURL)\(endpoint)") else {
                throw AuthError.networkError("Invalid URL.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, _) = try await session.data(for: request)
            return data
        }
        // ── END DEMO MODE ────────────────────────────────────────────────

        guard let accessToken = readToken(key: accessTokenKey) else {
            throw AuthError.tokenExpired
        }
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw AuthError.networkError("Invalid URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.networkError("No response.")
        }

        switch http.statusCode {
        case 200...299:
            return data

        case 401:
            let errorCode = (try? JSONDecoder().decode(BackendErrorResponse.self, from: data))?.error
            if errorCode == "invalid_grant" {
                clearTokens()
                isAuthenticated = false
                throw AuthError.tokenExpired
            }
            await silentRefresh()
            guard isAuthenticated else { throw AuthError.tokenExpired }
            return try await authenticatedRequest(endpoint: endpoint, method: method, body: body)

        default:
            throw AuthError.serverError(http.statusCode)
        }
    }

    // MARK: - Logout
    //
    // Calls POST /auth/logout to invalidate the refresh token server-side,
    // then clears all tokens from Keychain regardless of server response.
    func logout() {
        // ── ⚠️ DEMO MODE: skip network call ─────────────────────────
        if !demoMode {
        // ── END DEMO MODE GUARD ─────────────────────────────────────
            Task {
                guard
                    let refreshToken = readToken(key: refreshTokenKey),
                    let url = URL(string: "\(baseURL)/auth/logout")
                else { return }

                var request        = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONEncoder().encode(["refresh_token": refreshToken])
                _ = try? await session.data(for: request)
            }
        // ── ⚠️ DEMO MODE closing brace ──────────────────────────────
        }
        // ── END DEMO MODE GUARD ─────────────────────────────────────

        clearTokens()
        isAuthenticated = false
    }

    // MARK: - Private Helpers

    private func storeTokens(access: String, refresh: String, appleUserID: String) {
        KeychainManager.shared.save(key: accessTokenKey,  data: Data(access.utf8))
        KeychainManager.shared.save(key: refreshTokenKey, data: Data(refresh.utf8))
        KeychainManager.shared.save(key: appleUserIDKey,  data: Data(appleUserID.utf8))
    }

    private func clearTokens() {
        KeychainManager.shared.delete(key: accessTokenKey)
        KeychainManager.shared.delete(key: refreshTokenKey)
        KeychainManager.shared.delete(key: appleUserIDKey)
    }

    private func readToken(key: String) -> String? {
        guard let data = KeychainManager.shared.read(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

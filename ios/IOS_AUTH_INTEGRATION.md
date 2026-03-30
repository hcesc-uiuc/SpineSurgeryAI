# iOS Auth Integration Guide

## Overview

The backend uses Apple Sign In (native iOS flow). The iOS app handles the Apple authentication on-device and sends the resulting `identity_token` to the Flask backend. The backend verifies it and issues its own short-lived access tokens and long-lived refresh tokens.

---

## Token Lifecycle

```
iOS                          Flask Backend                Apple
 |                               |                          |
 |-- POST /auth/login ---------->|                          |
 |   { identity_token,           |-- verify token -------->|
 |     full_name? }              |<-- user identity --------|
 |                               |  upsert user in DB       |
 |                               |  issue access token      |
 |                               |  issue refresh token     |
 |<-- access + refresh tokens ---|                          |
 |  store in Keychain            |                          |
 |                               |                          |
 |-- GET /api/* + Bearer ------->|                          |
 |                               |  validate JWT            |
 |<-- 200 data ------------------|                          |
 |                               |                          |
 |  (token expires after 15min)  |                          |
 |<-- 401 Unauthorized-----------|                          |
 |-- POST /auth/refresh -------->|                          |
 |   { refresh_token }           |  hash + lookup in DB     |
 |<-- new access_token-----------|                          |
 |  retry original request       |                          |
 |                               |                          |
 |-- POST /auth/logout --------->|                          |
 |   { refresh_token }           |  mark token revoked      |
 |  clear Keychain               |                          |
```

---

## Apple Developer Setup

Complete this before any end-to-end testing.

1. In Xcode → select your app target → **Signing & Capabilities** → click **+** → add **Sign in with Apple**
2. In [Apple Developer Portal](https://developer.apple.com) → **Certificates, Identifiers & Profiles** → your App ID → enable **Sign in with Apple**
3. Provide the backend developer with your **Bundle ID** (e.g. `com.yourcompany.yourapp`) so it can be set as `APPLE_BUNDLE_ID` on the server
4. No redirect URI is needed — this is a native iOS flow, not a web redirect

---

## Endpoints

Base URL: provided separately per environment (dev / prod).

### POST `/auth/login`

Call immediately after a successful Apple Sign In on-device.

**Request body:**
```json
{
  "identity_token": "<base64 JWT from Apple>",
  "full_name": "Jane Smith"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `identity_token` | String | Yes | `String(data: credential.identityToken!, encoding: .utf8)` |
| `full_name` | String | No | Only sent on first login — Apple does not provide it again |

**Response 200:**
```json
{
  "access_token": "eyJhbGci...",
  "refresh_token": "abc123xyz..."
}
```

Store both values in **Keychain** — never `UserDefaults`.

---

### GET/POST `/api/*` — Authenticated requests

Attach the access token to every API request:

```
Authorization: Bearer <access_token>
```

If the server returns **401**, proceed to the refresh flow below.

---

### POST `/auth/refresh`

Call this automatically whenever any API request returns 401. Do not send the user to the login screen until refresh also fails.

**Request body:**
```json
{
  "refresh_token": "<stored refresh token>"
}
```

**Response 200:**
```json
{
  "access_token": "eyJhbGci..."
}
```

Replace the stored `access_token` in Keychain, then retry the original request.

If this endpoint returns **401** (`invalid_grant`), the session is fully expired. Clear Keychain and redirect the user to the login screen.

---

### POST `/auth/logout`

Call when the user explicitly logs out.

**Request body:**
```json
{
  "refresh_token": "<stored refresh token>"
}
```

**Response 200:**
```json
{
  "ok": true
}
```

After a successful response (or even on failure), clear both tokens from Keychain and return the user to the login screen.

---

## Error Reference

All auth errors return JSON with a single `error` field.

```json
{ "error": "token_expired" }
```

| HTTP Status | `error` value | Meaning | Action |
|---|---|---|---|
| 400 | `missing_identity_token` | Login request missing token | Bug — check request construction |
| 400 | `missing_refresh_token` | Refresh request missing token | Bug — check Keychain retrieval |
| 401 | `invalid_identity_token` | Apple token verification failed | Re-prompt Apple Sign In |
| 401 | `token_expired` | Access token expired | Call `/auth/refresh` |
| 401 | `invalid_token` | Access token malformed | Call `/auth/refresh` |
| 401 | `invalid_grant` | Refresh token invalid or expired | Clear Keychain, redirect to login |

---

## Swift Implementation Guide

### 1. Sign In with Apple

```swift
import AuthenticationServices

class AuthViewModel: NSObject, ASAuthorizationControllerDelegate {

    func signInWithApple() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.performRequests()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let identityToken = String(data: tokenData, encoding: .utf8)
        else { return }

        // Only present on very first Apple Sign In for this user
        let fullName = [
            credential.fullName?.givenName,
            credential.fullName?.familyName
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        Task {
            await AuthService.shared.login(
                identityToken: identityToken,
                fullName: fullName.isEmpty ? nil : fullName
            )
        }
    }
}
```

### 2. Auth Service

```swift
import Foundation
import Security

actor AuthService {
    static let shared = AuthService()

    private let baseURL = URL(string: "https://your-backend-url.com")!

    // MARK: - Login

    func login(identityToken: String, fullName: String?) async throws {
        var body: [String: String] = ["identity_token": identityToken]
        if let name = fullName { body["full_name"] = name }

        let response: LoginResponse = try await post("/auth/login", body: body, authenticated: false)
        Keychain.set(response.accessToken,  forKey: "access_token")
        Keychain.set(response.refreshToken, forKey: "refresh_token")
    }

    // MARK: - Logout

    func logout() async {
        let refreshToken = Keychain.get("refresh_token") ?? ""
        _ = try? await post("/auth/logout", body: ["refresh_token": refreshToken], authenticated: false)
        Keychain.delete("access_token")
        Keychain.delete("refresh_token")
    }

    // MARK: - Refresh

    func refresh() async throws {
        guard let refreshToken = Keychain.get("refresh_token") else {
            throw AuthError.notAuthenticated
        }
        let response: RefreshResponse = try await post(
            "/auth/refresh",
            body: ["refresh_token": refreshToken],
            authenticated: false
        )
        Keychain.set(response.accessToken, forKey: "access_token")
    }

    // MARK: - Authenticated request with auto-refresh

    func request<T: Decodable>(_ path: String, method: String = "GET") async throws -> T {
        do {
            return try await authenticatedRequest(path, method: method)
        } catch AuthError.tokenExpired {
            try await refresh()
            return try await authenticatedRequest(path, method: method)
        }
    }

    // MARK: - Internals

    private func authenticatedRequest<T: Decodable>(_ path: String, method: String) async throws -> T {
        guard let token = Keychain.get("access_token") else { throw AuthError.notAuthenticated }

        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse

        if http.statusCode == 401 {
            let error = try? JSONDecoder().decode(AuthErrorResponse.self, from: data)
            if error?.error == "invalid_grant" { throw AuthError.sessionExpired }
            throw AuthError.tokenExpired
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: String], authenticated: Bool) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Models

struct LoginResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct RefreshResponse: Decodable {
    let accessToken: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

struct AuthErrorResponse: Decodable {
    let error: String
}

enum AuthError: Error {
    case notAuthenticated
    case tokenExpired
    case sessionExpired  // refresh also failed — send to login screen
}
```

### 3. Keychain Helper (minimal)

```swift
enum Keychain {
    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrAccount:     key,
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

---

## Token Details

| Token | Lifetime | Storage | Used for |
|---|---|---|---|
| `access_token` | 15 minutes | Keychain | `Authorization: Bearer` header on every API call |
| `refresh_token` | 365 days | Keychain | Obtaining a new access token on 401 |

---

## Key Rules

- **Never** store tokens in `UserDefaults` — Keychain only
- **Never** show the login screen on a 401 without first attempting `/auth/refresh`
- `full_name` is only available from Apple on the **very first** Sign In — send it every time you have it, the backend discards it if the user already exists
- If both access token and refresh token are missing from Keychain, the user needs to log in again

///
//  SurveyUploader.swift
//  SensingApp
//

import Foundation
import UIKit

// ============================================================
// MARK: - SurveyUploader Documentation
// ============================================================
//
// PURPOSE:
// Handles all survey data uploads to the Journey backend.
// Wraps raw survey responses in a standardized envelope
// (metadata + payload) and submits via SecureAuthManager's
// authenticatedRequest() — meaning every upload automatically:
//   • Attaches the patient's Bearer access token
//   • Silently refreshes the token if it has expired
//   • Retries the upload once with the new token
//   • Forces logout if the refresh token is also dead
//
// SETUP — call once at app launch (in SensingAppApp or AuthLoginView):
//   SurveyUploader.shared.configure(authManager: authManager)
//
// USAGE — identical to before, no call sites need to change:
//   try await SurveyUploader.shared.uploadSurvey(surveyData)
//
// ENDPOINT:
//   POST /api/uploadjson/survey
//   Authorization: Bearer <access_token>  ← handled automatically
//
// PAYLOAD SHAPE (unchanged from original):
//   {
//     "metadata": {
//       "user_id":        "apple_user_id_string",
//       "timestamp_utc":  "2026-04-27T12:00:00Z",
//       "timestamp_unix": 1745755200
//     },
//     "payload": {
//       "study_id": "spine_recovery_v1",
//       "survey":   { ...raw survey responses... },
//       "device_metadata": {
//         "platform":     "iOS",
//         "device_model": "iPhone",
//         "os_version":   "18.0",
//         "app_version":  "1.0"
//       }
//     }
//   }
//
// ============================================================

final class SurveyUploader {

    // MARK: - Singleton
    static let shared = SurveyUploader()
    private init() {}

    // MARK: - Auth Manager
    //
    // Injected once via configure() at app launch.
    // If not configured, uploadSurvey falls back to the
    // unauthenticated path so existing behaviour is preserved.
    private weak var authManager: SecureAuthManager?

    /// Call this once after authManager is available — e.g. in
    /// SensingAppApp or immediately after login succeeds.
    func configure(authManager: SecureAuthManager) {
        self.authManager = authManager
    }

    // MARK: - Upload Error
    //
    // Identical to original — no call sites need to change.
    enum UploadError: LocalizedError {
        case invalidURL
        case badServerResponse
        case serverError(Int, String)
        case serializationError

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL."
            case .badServerResponse:
                return "Invalid server response."
            case .serverError(let code, let message):
                return "Server error (\(code)): \(message)"
            case .serializationError:
                return "Failed to encode survey payload."
            }
        }
    }

    // MARK: - Upload Survey
    //
    // Signature is IDENTICAL to the original — no call sites need to change.
    //
    // If authManager is configured → uses authenticatedRequest() with
    //   Bearer token, auto-refresh, and retry on 401.
    // If authManager is not configured → falls back to direct URLSession
    //   (preserves original behaviour during transition).
    func uploadSurvey(_ surveyData: [String: Any]) async throws {

        print("🚀 Preparing survey upload...")

        // MARK: Build Metadata
        let now           = Date()
        let isoFormatter  = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestampUTC  = isoFormatter.string(from: now)
        let timestampUnix = Int(now.timeIntervalSince1970)
        let userID        = surveyData["user_id"] as? String ?? "unknown"

        // MARK: Build Wrapped Payload (identical to original)
        let wrappedPayload: [String: Any] = [
            "metadata": [
                "user_id":        userID,
                "timestamp_utc":  timestampUTC,
                "timestamp_unix": timestampUnix
            ],
            "payload": [
                "study_id": "spine_recovery_v1",
                "survey":   surveyData,
                "device_metadata": [
                    "platform":     "iOS",
                    "device_model": UIDevice.current.model,
                    "os_version":   UIDevice.current.systemVersion,
                    "app_version":  Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                ]
            ]
        ]

        guard JSONSerialization.isValidJSONObject(wrappedPayload) else {
            throw UploadError.serializationError
        }

        // MARK: - Route through SecureAuthManager if available
        //
        // This is the only behaviour change from the original.
        // authenticatedRequest() handles Bearer token, refresh, and retry.
        if let authManager = authManager {
            let responseData = try await authManager.authenticatedRequest(
                endpoint: "/api/uploadjson/survey",
                method:   "POST",
                body:     wrappedPayload
            )
            let responseString = String(data: responseData, encoding: .utf8) ?? "No response body"
            print("📡 Server response:", responseString)
            print("✅ Survey upload successful.")
            return
        }

        // MARK: - Fallback — direct URLSession (original behaviour)
        //
        // Reached only if configure(authManager:) was never called.
        // Preserves original behaviour so nothing breaks during transition.
        // ⚠️ Remove this fallback once configure() is wired up at launch.
        print("⚠️ SurveyUploader: authManager not configured — using unauthenticated fallback.")

        guard let url = URL(string: "http://18.116.67.186/api/uploadjson/survey") else {
            throw UploadError.invalidURL
        }

        let jsonData = try JSONSerialization.data(withJSONObject: wrappedPayload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.badServerResponse
        }

        print("📡 HTTP Status:", httpResponse.statusCode)

        let responseString = String(data: data, encoding: .utf8) ?? "No response body"
        print("📨 Server Response:", responseString)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UploadError.serverError(httpResponse.statusCode, responseString)
        }

        print("✅ Survey upload successful.")
    }
}

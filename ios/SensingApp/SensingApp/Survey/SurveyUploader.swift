//
//  SurveyUploader.swift
//

import Foundation
import UIKit

final class SurveyUploader {

    static let shared = SurveyUploader()
    private init() {}

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

    func uploadSurvey(_ surveyData: [String: Any], authManager: SecureAuthManager) async throws {
        print("🚀 Preparing survey upload...")

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let userID = surveyData["user_id"] as? String ?? "unknown"

        let wrappedPayload: [String: Any] = [
            "metadata": [
                "user_id":        userID,
                "timestamp_utc":  isoFormatter.string(from: now),
                "timestamp_unix": Int(now.timeIntervalSince1970)
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

        // Uses SecureAuthManager so the Bearer token is attached automatically.
        // Also handles 401 → silent refresh → retry under the hood.
        _ = try await authManager.authenticatedRequest(
            endpoint: "/api/uploadjson/survey",
            method:   "POST",
            body:     wrappedPayload
        )

        print("✅ Survey upload successful.")
    }
}

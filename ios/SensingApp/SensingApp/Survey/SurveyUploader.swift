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

    func uploadSurvey(_ surveyData: [String: Any]) async throws {

        // ⚠️ Use HTTPS in production
        guard let url = URL(string: "http://18.116.67.186/api/uploadjson/survey") else {
            throw UploadError.invalidURL
        }

        print("🚀 Preparing survey upload...")

        // MARK: - Timestamp Data
        let now = Date()

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let timestampUTC = isoFormatter.string(from: now)
        let timestampUnix = Int(now.timeIntervalSince1970)

        let userID = surveyData["user_id"] as? String ?? "unknown"

        // MARK: - Wrapped Payload
        let wrappedPayload: [String: Any] = [
            "metadata": [
                "user_id": userID,
                "timestamp_utc": timestampUTC,
                "timestamp_unix": timestampUnix
            ],
            "payload": [
                "study_id": "spine_recovery_v1",
                "survey": surveyData,
                "device_metadata": [
                    "platform": "iOS",
                    "device_model": UIDevice.current.model,
                    "os_version": UIDevice.current.systemVersion,
                    "app_version":
                        Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                        as? String ?? "1.0"
                ]
            ]
        ]

        // MARK: - JSON Encoding
        guard JSONSerialization.isValidJSONObject(wrappedPayload) else {
            throw UploadError.serializationError
        }

        let jsonData = try JSONSerialization.data(withJSONObject: wrappedPayload)

        // MARK: - Request Setup
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        // MARK: - Network Call
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

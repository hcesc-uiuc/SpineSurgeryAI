//
//  SurveyUploader.swift
//
//
//  Created by Samir Kurudi on 2/13/26.
//

import Foundation
import UIKit

final class SurveyUploader {

    static let shared = SurveyUploader()
    private init() {}

    func uploadSurvey(_ surveyData: [String: Any]) async throws {

        guard let url = URL(string: "http://18.116.67.186/api/uploadjson/survey") else {
            print("❌ Invalid URL")
            return
        }

        let now = Date()

        // ISO8601 UTC (no fractional seconds for backend compatibility)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestampUTC = isoFormatter.string(from: now)

        let timestampUnix = Int(now.timeIntervalSince1970)

        let userID = surveyData["user_id"] as? String ?? "unknown"

        // Backend-aligned payload with UNIX time added
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
                    "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                ]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: wrappedPayload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (responseData, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            print("📡 Status Code:", http.statusCode)
        }

        if let responseString = String(data: responseData, encoding: .utf8) {
            print("📨 Server Response:", responseString)
        }
    }
}

//
//  Networking.swift
//  SensingApp
//
//  Created by Samir Kurudi on 11/14/25.
//

import Foundation

func uploadSurveyResults(payload: [String: Any]) async {

    // This endpoint EXISTS on your backend
    guard let url = URL(string: "http://18.116.67.186/api/uploadfile") else {
        print("❌ Invalid URL")
        return
    }

    // Convert dictionary → JSON body
    guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
        print("❌ Could not serialize JSON")
        return
    }

    // Build request
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = jsonData

    do {
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            print("📡 STATUS CODE:", http.statusCode)

            if http.statusCode != 200 {
                print("❗ SERVER REJECTED REQUEST")
                print("📨 Server said:", String(data: data, encoding: .utf8) ?? "No body")
            } else {
                print("✅ Upload success")
                print("📨 Server response:", String(data: data, encoding: .utf8) ?? "No body")
            }
        }
    } catch {
        print("❌ Upload failed:", error.localizedDescription)
    }
}

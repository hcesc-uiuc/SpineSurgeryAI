//
//  Uploader.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 11/5/25.
//

import Foundation


struct Uploader {
    
    static let shared = Uploader()
    static let UploadURL = "http://18.116.67.186/api/uploadfile"
    
    
    func uploadFile(fileURL: URL) {
        let boundary = "Boundary-\(UUID().uuidString)"
        guard let url = URL(string: Uploader.UploadURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build the multipart form body
        var body = Data()
        let filename = fileURL.lastPathComponent
        let mimetype = "application/octet-stream"

        // --- file data part ---
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimetype)\r\n\r\n".data(using: .utf8)!)
        if let fileData = try? Data(contentsOf: fileURL) {
            body.append(fileData)
        }
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // ✅ Use uploadTask(from:) instead of setting httpBody
        let task = URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
            if let error = error {
                print("Upload error: \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                print("Status code: \(httpResponse.statusCode)")
            }

            if let data = data,
               let responseString = String(data: data, encoding: .utf8) {
                print("Response: \(responseString)")
            }
        }

        task.resume()
    }
    
    
    ///
    /// Coded taken from Sami'r code.
    ///
    func uploadSurveyResults(payload: [String: Any]) async {

        guard let url = URL(string: Uploader.UploadURL) else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: jsonData)
            print("Upload success: \(response)")
        } catch {
            print("Upload error: \(error.localizedDescription)")
        }
    }
    
    
}

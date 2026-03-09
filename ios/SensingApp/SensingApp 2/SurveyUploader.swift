//
//  SurveyUploader.swift
//  SensingApp
//
//  Created by Samir Kurudi on 11/20/25.
//

//
//  SurveyUploader.swift
//

import Foundation

class SurveyUploader {

    static let shared = SurveyUploader()

    private init() {}

    // MARK: - Write JSON to File
    func writeSurveyToFile(_ payload: [String: Any]) throws -> URL {

        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])

        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NSError(domain: "JSONEncoding", code: -1)
        }

        let fileName = "survey_\(Int(Date().timeIntervalSince1970)).json"
        let fileURL = getDocumentsDirectory().appendingPathComponent(fileName)

        try jsonString.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }


    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Upload File
    func uploadFile(_ fileURL: URL) async throws {

        let uploadURL = URL(string: "http://18.116.67.186/api/uploadfilesurvey")!

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)

        print("📤 Uploaded survey file:", fileURL.lastPathComponent)
        print("📡 Response:", response)
        print("📨 Server:", String(data: responseData, encoding: .utf8) ?? "")
    }

}

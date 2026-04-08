//
//  UploadToServer.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 10/17/25.
//

import Foundation

///
/// The goal of this class is to create wrapper singleton class
/// to upload data/strings to sever.
///

class UploadToServer {
    static let shared = UploadToServer()
    
    
    func uploadDeviceTokenToServer(deviceToken: String) async -> String{
        var linkToPost: String = "http://ec2-18-219-220-161.us-east-2.compute.amazonaws.com:5000/uploadDeviceToken"
        let body : [String: Any] = [
            "title": "Upload device token",
            "deviceToken": deviceToken,
            "userId": "sub0x"
        ]
        
        let responseMessage: String = await self.sendPostRequest(linktoPost: linkToPost, postBody: body)
        
        return responseMessage
    }
    
    func sendPostRequest(linktoPost: String, postBody: [String: Any]) async -> String {
        var responseMessage = ""
        
        // "https://jsonplaceholder.typicode.com/posts"
        guard let url = URL(string: linktoPost) else {
            responseMessage = "Invalid URL"
            return responseMessage
        }
        
        let body = postBody
        //        : [String: Any] = [
        //            "title": "SwiftUI POST",
        //            "body": "This is a test message.",
        //            "userId": 1
        //        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                responseMessage = "Response: \(decoded)"
            } else {
                responseMessage = "Failed to decode response"
            }
            
        } catch {
            responseMessage = "Error: \(error.localizedDescription)"
        }
        return responseMessage
    }
}

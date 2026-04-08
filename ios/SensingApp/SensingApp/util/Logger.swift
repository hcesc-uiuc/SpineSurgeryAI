//
//  Logger.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 10/19/25.
//
import Foundation
import UIKit

final class Logger {
    static let shared = Logger()
    private init() {}
    
    /// Get current log file URL with date
    private var logFileURL: URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let filename = "log_\(dateString).txt"
        
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("logs").appendingPathComponent(filename)
    }
    
    func append(_ message: String) {
        let fullMessage = "[\(timestamp())] \(message)\n"
        let data = fullMessage.data(using: .utf8)!
        
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logFileURL)
            }
        } catch {
            print("❌ Logger error:", error)
        }
    }
    
    func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
    
    //
    //    private var logFileURL: URL
    //    private let queue = DispatchQueue(label: "edu.uiuc.cs.hcesc.sensingapp.queue", qos: .background)
    //    private let dateFormatter: DateFormatter
    //    private let dateTimezoneFormatter: DateFormatter
    //
    //    private init() {
    //        self.dateFormatter = DateFormatter()
    //        self.dateFormatter.dateFormat = "yyyy-MM-dd"
    //
    //        self.dateTimezoneFormatter = DateFormatter()
    //        self.dateTimezoneFormatter.timeZone = .current
    //        self.dateTimezoneFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    //
    //        // Create today's log file
    //        self.logFileURL = Logger.createLogFileURL(for: Date())
    //        Logger.ensureFileExists(at: logFileURL)
    //    }
        

    
    //
    //    private static func createLogFileURL(for date: Date) -> URL {
    //        let dateString = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
    //        let cleanDate = dateString.replacingOccurrences(of: "/", with: "-")
    //        let fileManager = FileManager.default
    //        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    //        return documentsURL.appendingPathComponent("log_\(cleanDate).txt")
    //    }
    //
    //    private static func ensureFileExists(at url: URL) {
    //        let fileManager = FileManager.default
    //        if !fileManager.fileExists(atPath: url.path) {
    //            fileManager.createFile(atPath: url.path, contents: nil, attributes: nil)
    //        }
    //    }
    //
    //    private func updateLogFileIfNeeded() {
    //        //Here we are creating a new log file if necessary
    //        let todayFile = Logger.createLogFileURL(for: Date())
    //        if todayFile != logFileURL {
    //            logFileURL = todayFile
    //            Logger.ensureFileExists(at: logFileURL)
    //        }
    //    }
    //
    

    
    //    func append(_ message: String) {
    //        queue.async {
    //            self.updateLogFileIfNeeded()
    //
    //            let timestamp = self.dateTimezoneFormatter.string(from: Date())
    //            let logEntry = "[\(timestamp)] \(message)\n"
    //
    //            if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
    //                handle.seekToEndOfFile()
    //                if let data = logEntry.data(using: .utf8) {
    //                    handle.write(data)
    //                }
    //                handle.closeFile()
    //            } else {
    //                try? logEntry.write(to: self.logFileURL, atomically: true, encoding: .utf8)
    //            }
    //        }
    //    }
    //
    func readAll() -> String? {
        try? String(contentsOf: logFileURL, encoding: .utf8)
    }
    //
    //    func clear() {
    //        queue.async {
    //            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
    //        }
    //    }
    //
    func currentLogFilePath() -> URL {
        return logFileURL
    }
    
    func getBatteryStatus() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel

        let state = UIDevice.current.batteryState
        var chargingState = ""
        switch state {
            case .charging:
                chargingState = "Charging"
            case .full:
                chargingState = "Full"
            case .unplugged:
                chargingState = "On battery power"
            default:
                chargingState = "Unknown"
        }
        
        let battryLevelString = String(format: "%.2f", level * 100) + "%" + ", " + chargingState
        
        return battryLevelString
    }
    
    /// Returns current timestamp string
    
    
    
}

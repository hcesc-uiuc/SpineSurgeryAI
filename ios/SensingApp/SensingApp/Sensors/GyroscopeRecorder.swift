//
//  MotionRecorder.swift
//  SensingTrialApp
//
//  Created by Mashfiqui Rabbi on 10/7/25.
//

import CoreMotion
import BackgroundTasks


///
///
/// There is no sensor recorder like the CMSensorRecorder
///
///

class GyroscopeRecorder {
    static let shared = GyroscopeRecorder()
    private let recorder = CMSensorRecorder()
    
    private init() {}
    
    func checkAccelerometerAuthorizationStatus() -> Bool{
        let status = CMMotionActivityManager.authorizationStatus()
        if status == .authorized {
            return true
        }else {
            return false
        }
    }
    
    func startRecording() {
        if CMSensorRecorder.isAccelerometerRecordingAvailable() {
            //Multiple calls to this function will extend the recording time.
            //The sampling rate is 50Hz.
            recorder.recordAccelerometer(forDuration: 12 * 60 * 60) // 12h max
            print("Recording accelerometer for 12 hours...")
            Logger.shared.append("Recording accelerometer for 12 hours...")
        }
    }
    
    func fetchAndSaveRecordedAcclerometerData() {
        let now = Date()
        let key = "lastAccelerometerSaveDate"
        
        //Here if the
        var past = now.addingTimeInterval(-3600) // last hour
        if let savedDate = UserDefaults.standard.object(forKey: key) as? Date {
            // Use stored value
            past = savedDate
        }
        if isWithinPastThreeDays(past) == false {
            past = Calendar.current.date(byAdding: .day, value: -2, to: Date())! //record only last 2 days of data.
        }
        
        let writer = PreallocatedCSVBuffer(filename: "accelerometer_\(currentTimestampString()).csv", capacity: 100000)
        if let dataList = recorder.accelerometerData(from: past, to: now) {
            for case let data as CMRecordedAccelerometerData in dataList {
                let accel = data.acceleration
                let unixTime = Int64(data.startDate.timeIntervalSince1970 * 1000)
                //print("\(unixTime),\(accel.x),\(accel.y),\(accel.z)")
                writer.addRowStr(rowOfData: "\(unixTime),\(accel.x),\(accel.y),\(accel.z)")
            }
        }
        writer.flush()
        writer.closeFile()
        
        //save last save date
        UserDefaults.standard.set(now, forKey: key)
        
        print("Writing accelerometer data for 1 hour...")
        
        let diffInSeconds = now.timeIntervalSince(past)
        let diffInMinutes = Int(diffInSeconds / 60)
        Logger.shared.append("Writing accelerometer data for \(diffInMinutes) minutes")
        Logger.shared.append("Start time: \(dateToString(past))")
        Logger.shared.append("End time: \(dateToString(now))")
        
        //\(ISO8601DateFormatter().string(from: now)),\(ISO8601DateFormatter().string(from: past))")
    }
    
    func isWithinPastThreeDays(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        
        guard let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now) else {
            return false
        }
        
        return (threeDaysAgo ... now).contains(date)
    }
    
    
    
    ///
    /// The following function prints the last minute of accelerometer data.
    ///
    func fetchRecordedData1Min() {
        let now = Date()
        let past = now.addingTimeInterval(-60) // last hour
        var count = 0
        if let dataList = recorder.accelerometerData(from: past, to: now) {
            for case let data as CMRecordedAccelerometerData in dataList {
                let accel = data.acceleration
                print("\(count), x:\(accel.x) y:\(accel.y) z:\(accel.z) at \(data.startDate)")
                count+=1;
            }
        } else {
            print("No recorded accelerometer data available.")
        }
        //fetchRecordedData()
        print("Writing accelerometer data for 1 minute...")
    }
    
    
    //=============================================
    //
    // Internal
    //
    //=============================================
    
    func currentTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.timeZone = TimeZone.current
        //formatter.timeZone = TimeZone(abbreviation: "UTC")
        return formatter.string(from: Date())
    }
    
    func dateToString(_ date: Date?, format: String = "yyyy-MM-dd HH:mm:ss") -> String {
        guard let date = date else {
            return "Invalid Date"
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = .current       // user’s current timezone
        formatter.locale = .current         // user’s locale (e.g., 12/24h preference)
        return formatter.string(from: date)
    }
}



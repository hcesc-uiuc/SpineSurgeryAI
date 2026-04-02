//
//  MotionRecorder.swift
//  SensingTrialApp
//
//  Created by Mashfiqui Rabbi on 10/7/25.
//

import CoreMotion
import BackgroundTasks

class AcclerometerRecorder {
    static let shared = AcclerometerRecorder()
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
        
        
        //saving data to a csv folder
        //let writer = PreallocatedCSVBuffer(filename: "accelerometer_\(currentTimestampString()).csv", capacity: 100000)
        
        SQLiteSaver.shared.open()
        if let dataList = recorder.accelerometerData(from: past, to: now) {
            for case let data as CMRecordedAccelerometerData in dataList {
                let accel = data.acceleration
                let unixTime = data.startDate.timeIntervalSince1970 * 1000
                //print("\(unixTime),\(accel.x),\(accel.y),\(accel.z)")
                // writer.addRowStr(rowOfData: "\(unixTime),\(accel.x),\(accel.y),\(accel.z)")
                
                //database writes
                SQLiteSaver.shared.addRow(
                    timestamp: unixTime,
                    dataType: SQLiteSaver.DataType.accelerometer,
                    blob: accelToBlob(x: accel.x, y: accel.y, z: accel.z)
                )
            }
        }
        SQLiteSaver.shared.close()
        // writer.flush()
        // writer.closeFile()
        
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
        let past = now.addingTimeInterval(-180) // last 3 minutes
        var count = 0
        
        let writer = PreallocatedCSVBuffer(filename: "accelerometer_1min_\(currentTimestampString()).csv", capacity: 500)
        if let dataList = recorder.accelerometerData(from: past, to: now) {
            for case let data as CMRecordedAccelerometerData in dataList {
                let accel = data.acceleration
                let unixTime = Int64(data.startDate.timeIntervalSince1970 * 1000)
                print("\(count), x:\(accel.x) y:\(accel.y) z:\(accel.z) at \(data.startDate)")
                writer.addRowStr(rowOfData: "\(unixTime),\(accel.x),\(accel.y),\(accel.z)")
                count+=1;
            }
        } else {
            print("No recorded accelerometer data available.")
        }
        writer.flush()
        writer.closeFile()
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
    
    func accelToBlob(x: Double, y: Double, z: Double) -> Data {
        var values: [Float32] = [Float32(x), Float32(y), Float32(z)]
        return Data(bytes: &values, count: values.count * MemoryLayout<Float32>.size)
    }
}



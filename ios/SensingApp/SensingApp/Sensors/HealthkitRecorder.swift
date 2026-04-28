//
//  HealthkitRecorder.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 4/15/26.
//

import BackgroundTasks

class HealthkitRecorder {
    static let shared = HealthkitRecorder()
    let HKManager = HealthKitManager()
    
    //
    private init() {}
    
    func getHealthKitData() {
        let daysRequested = 1
        //let metricsRequested: Set<SupportedMetric> = [.steps] // Empty = All
        let metricsRequested: Set<SupportedMetric> = [] // Empty = All
        
        print("Requesting: HKManager.refreshWithNewRange")
        
        HKManager.refreshWithNewRange(days: 1, types:metricsRequested) { data in
            
            print("Success! Data received. Len: \(data.count), Days:\(daysRequested), Types:\(metricsRequested)")
                
                //here I need to open a file
                //This will create a file for the current day
                
                let hkDataLogger = HKDataLogger()
                let isFileOpenSuccesful = hkDataLogger.open()
                if isFileOpenSuccesful == true {
                    for (index, point) in data.enumerated() {
                        let hkDataPointString = self.formatRawString(
                            point,
                            unixStartStr: String(Int(point.startDate.timeIntervalSince1970)),
                            unixEndStr: String(Int(point.endDate.timeIntervalSince1970))
                        )
                        print("\(index) - \(hkDataPointString)")
                        print("")
                        
                        hkDataLogger.writeLine(hkDataPointString)
                    }
                    hkDataLogger.close()
                }
                
                
                //close a file here
        }
    }
    
    // Serializes a single HealthKit raw data point into a JSON string for logging or upload.
    // Parameters:
    //   p            - the raw data point containing the sensor reading and its metadata
    //   unixStartStr - pre-formatted Unix timestamp string for the sample's start time
    //   unixEndStr   - pre-formatted Unix timestamp string for the sample's end time
    func formatRawString(_ p: HealthKitManager.RawDataPoint, unixStartStr: String, unixEndStr: String) -> String {
        // Format the sample's start date as a human-readable string (month/day hour:minute:second)
        let dateStr = p.startDate.formatted(.dateTime.month().day().hour().minute().second())
        
        // Fall back to 0.0 if the sample has no numeric value (e.g. category-type samples)
        let displayValue = p.value ?? 0.0
        
        // Flatten the sample's HKMetadata dictionary into a single "key:value|key:value" string.
        // Sorting entries ensures a deterministic order across recordings.
        let metaStr: String = {
            guard let md = p.metadata as? [AnyHashable: Any] else { return "" }
            return md.map { key, value in
                let k = String(describing: key)
                let v = String(describing: value)
                return "\(k):\(v)"
            }
            .sorted() // stable order for logs
            .joined(separator: "|")
        }()
        
        // Convert duration from seconds to milliseconds for the JSON payload
        let durationMs = Int(p.duration * 1000)
        
        // Build the JSON payload as a dictionary.
        // Optional device fields fall back to "NA" when the device info is unavailable.
        let json: [String: Any?] = [
            "date": dateStr,
            "id": p.id.uuidString,
            "type": p.type,
            "value": displayValue,
            "unit": p.unit,
            "unix_start": unixStartStr,
            "unix_end": unixEndStr,
            "duration_ms": durationMs,
            "source_name": p.sourceName,
            "bundle_id": p.bundleID,
            "device_name": p.deviceName ?? "NA",
            "device_model": p.deviceModel ?? "NA",
            "software_version": p.softwareVer ?? "NA",
            "meta": metaStr
        ]
        
        // Strip nil values with compactMapValues, serialize to JSON bytes, then decode as UTF-8.
        // Returns "null" if serialization fails.
        let jsonData = try? JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return jsonString
        
        // Legacy flat-string format (kept for reference):
//        return "[\(dateStr)] |ID:\(p.id.uuidString)| TYPE:\(p.type) | VAL:\(displayValue) \(p.unit) | UNIX_START:\(unixStartStr) | UNIX_END:\(unixEndStr) | DUR:\(durationMs)ms | SRC:\(p.sourceName) | BID:\(p.bundleID) | DEV:\(p.deviceName ?? "NA") | MOD:\(p.deviceModel ?? "NA") | SW:\(p.softwareVer ?? "NA") | ID:\(p.id.uuidString) | META:{\(metaStr)}"
    }
}

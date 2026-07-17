//
//  SensorKit_PhoneUsage.swift
//  SensingApp
//
//  SensorKit phone usage report (iPhone). Writes sensorkit_phoneusage_phone_*.csv.
//  One report per fetch result (call counts/durations for the report window).
//

import SensorKit

final class SensorKitPhoneUsageFetcher: SensorKitFetcher {
    static let shared = SensorKitPhoneUsageFetcher()

    init() {
        super.init(
            sensor: .phoneUsageReport,
            filePrefix: "sensorkit_phoneusage_phone",
            csvHeader: "timestamp_unix,duration_s,incoming_calls,outgoing_calls,call_duration_s,unique_contacts",
            devicePreference: .iPhone,
            logTag: "SK-PhoneUsage",
            fileIndexKey: "sk_phoneusage_csv_file_index",
            lastFetchEndKey: "sk_phoneusage_last_fetch_end",
            maxFileSizeMB: 5
        )
    }

    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let r = result.sample as? SRPhoneUsageReport else { return [] }
        let t = Date(timeIntervalSinceReferenceDate: result.timestamp.toCFAbsoluteTime())
            .timeIntervalSince1970
        return ["\(String(format: "%.6f", t)),\(r.duration),"
              + "\(r.totalIncomingCalls),\(r.totalOutgoingCalls),"
              + "\(r.totalPhoneCallDuration),\(r.totalUniqueContacts)"]
    }
}

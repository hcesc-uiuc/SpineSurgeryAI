//
//  SensorKit_MessagesUsage.swift
//  SensingApp
//
//  SensorKit messages usage report (iPhone). Writes sensorkit_messages_phone_*.csv.
//  One report per fetch result (message counts for the report window; content
//  is never accessed).
//

import SensorKit

final class SensorKitMessagesUsageFetcher: SensorKitFetcher {
    static let shared = SensorKitMessagesUsageFetcher()

    init() {
        super.init(
            sensor: .messagesUsageReport,
            filePrefix: "sensorkit_messages_phone",
            csvHeader: "timestamp_unix,duration_s,outgoing_messages,incoming_messages,unique_contacts",
            devicePreference: .iPhone,
            logTag: "SK-Messages",
            fileIndexKey: "sk_messages_csv_file_index",
            lastFetchEndKey: "sk_messages_last_fetch_end",
            maxFileSizeMB: 5
        )
    }

    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let r = result.sample as? SRMessagesUsageReport else { return [] }
        let t = Date(timeIntervalSinceReferenceDate: result.timestamp.toCFAbsoluteTime())
            .timeIntervalSince1970
        return ["\(String(format: "%.6f", t)),\(r.duration),"
              + "\(r.totalOutgoingMessages),\(r.totalIncomingMessages),"
              + "\(r.totalUniqueContacts)"]
    }
}

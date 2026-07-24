//
//  SensorStatusStore.swift
//  SensingApp
//
//  "Last recorded" freshness store backing the Sensors tab ("What We Collect").
//
//  Every row on the Sensors tab shows a "Last recorded: …" line sourced from here.
//  Real data flows in from two places:
//    1. Recorders stamp the store the moment they save data
//       (AcclerometerRecorder, AdaptiveLocationManager, SensorKit watch fetcher,
//        survey submit).
//    2. refreshHealthKitSamples() queries HealthKit for the genuine latest sample
//       of each Apple Health row and stamps the result.
//  When no real stamp exists for a sensor yet (fresh install, simulator, no watch),
//  the row falls back to the SAMPLE DATA table below, always suffixed "(sample)"
//  so it can never be mistaken for real data.
//
//  Storage is UserDefaults: two keys per sensor —
//    sensorLast_<kind>_value  (String, optional — e.g. "72 bpm")
//    sensorLast_<kind>_date   (Date)
//

import Foundation
import HealthKit

/// One case per row on the Sensors tab.
nonisolated enum SensorKind: String, CaseIterable {
    // Motion & activity
    case accelerometer
    case gyroscope
    // Location
    case location
    // Apple Health
    case heartRate
    case heartRateVariability
    case steps
    // distance & flights have no Sensors-tab row of their own — they exist so the
    // Home stat tiles that show them can be driven by the same store.
    case distance
    case flights
    case bloodOxygen
    case activeEnergy
    case sleep
    // Apple Watch (SensorKit)
    case watchAccelerometer
    case watchHeartPPG
    case ecg
    case wristTemperature
    case ambientLight
    // Daily survey
    case survey
}

nonisolated struct SensorStatusEntry {
    let value: String?      // nil = timestamp-only sensor (motion, location, watch)
    let date: Date
    let isSample: Bool
}

nonisolated final class SensorStatusStore: @unchecked Sendable {
    static let shared = SensorStatusStore()
    private init() {}

    private let defaults = UserDefaults.standard

    // ══════════════════════════════════════════════════════════════════
    //  SAMPLE DATA — EDIT THIS TABLE TO TEST HOW THE SENSORS TAB LOOKS.
    //
    //  Shown only when a sensor has no real recorded stamp yet, and always
    //  rendered with a "(sample)" suffix. `value` is the reading shown
    //  (nil = timestamp-only); `minutesAgo` positions the fake timestamp
    //  relative to now. Values are deliberately absurd (999 bpm) so real
    //  and sample data can never be confused.
    // ══════════════════════════════════════════════════════════════════
    static let sampleData: [SensorKind: (value: String?, minutesAgo: Double)] = [
        .accelerometer:        (nil,            45),
        .gyroscope:            (nil,            45),
        .location:             (nil,            12),
        .heartRate:            ("999 bpm",       5),
        .heartRateVariability: ("999 ms",       60),
        .steps:                ("99,999 steps", 30),
        .distance:             ("99.9 km",      30),
        .flights:              ("999 flights",  30),
        .bloodOxygen:          ("99%",          90),
        .activeEnergy:         ("9,999 kcal",   30),
        .sleep:                ("9.9 hr",      600),
        .watchAccelerometer:   (nil,           120),
        .watchHeartPPG:        (nil,           180),
        .ecg:                  (nil,          1440),
        .wristTemperature:     (nil,           480),
        .ambientLight:         (nil,           300),
        .survey:               (nil,          1440),
    ]

    private func valueKey(_ kind: SensorKind) -> String { "sensorLast_\(kind.rawValue)_value" }
    private func dateKey(_ kind: SensorKind)  -> String { "sensorLast_\(kind.rawValue)_date" }

    /// Stamp a sensor as recorded. Safe to call from any thread (UserDefaults
    /// is thread-safe). Keeps only the newest stamp — older dates are ignored,
    /// so out-of-order batches (e.g. SensorKit) can stamp freely.
    func record(_ kind: SensorKind, value: String? = nil, at date: Date = Date()) {
        if let existing = defaults.object(forKey: dateKey(kind)) as? Date, existing > date { return }
        defaults.set(date, forKey: dateKey(kind))
        if let value {
            defaults.set(value, forKey: valueKey(kind))
        } else {
            defaults.removeObject(forKey: valueKey(kind))
        }
    }

    /// Real stamp if one exists, else the sample-table fallback, else nil.
    func entry(for kind: SensorKind) -> SensorStatusEntry? {
        if let date = defaults.object(forKey: dateKey(kind)) as? Date {
            return SensorStatusEntry(value: defaults.string(forKey: valueKey(kind)), date: date, isSample: false)
        }
        if let sample = Self.sampleData[kind] {
            return SensorStatusEntry(value: sample.value,
                                     date: Date().addingTimeInterval(-sample.minutesAgo * 60),
                                     isSample: true)
        }
        return nil
    }

    /// The full display line for a row, e.g.
    ///   "Last recorded: 72 bpm · Today at 3:45 PM"
    ///   "Last recorded: Yesterday at 9:12 PM"
    ///   "Last recorded: 999 bpm · Today at 3:45 PM (sample)"
    ///   "No data recorded yet"
    func displayLine(for kind: SensorKind) -> String {
        guard let entry = entry(for: kind) else { return "No data recorded yet" }
        let when = Self.timestampFormatter.string(from: entry.date)
        var line = entry.value.map { "Last recorded: \($0) · \(when)" } ?? "Last recorded: \(when)"
        if entry.isSample { line += " (sample)" }
        return line
    }

    // Absolute time with natural day phrasing: "Today at 3:45 PM",
    // "Yesterday at 9:12 PM", "Jul 12, 2026 at 3:45 PM".
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

// MARK: - HealthKit latest-sample refresh

extension SensorStatusStore {

    /// Queries HealthKit for the genuine latest reading of each Apple Health row
    /// and stamps the store. Read-only; sensors the user hasn't authorized simply
    /// return no samples and keep their previous stamp (or sample fallback).
    /// `completion` fires on the main queue after all queries finish.
    func refreshHealthKitSamples(completion: (() -> Void)? = nil) {
        guard HKHealthStore.isHealthDataAvailable() else {
            DispatchQueue.main.async { completion?() }
            return
        }
        let store = HKHealthStore()
        let group = DispatchGroup()

        /// Latest single sample of a quantity type → stamp with a formatted value.
        func stampLatestSample(_ identifier: HKQuantityTypeIdentifier,
                               kind: SensorKind,
                               format: @escaping (HKQuantitySample) -> String) {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return }
            group.enter()
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                if let sample = samples?.first as? HKQuantitySample {
                    self.record(kind, value: format(sample), at: sample.endDate)
                }
                group.leave()
            }
            store.execute(query)
        }

        /// Cumulative types (steps, active energy): value = total for the day of
        /// the latest sample, timestamp = that sample's end. Two chained queries.
        func stampDailyTotal(_ identifier: HKQuantityTypeIdentifier,
                             kind: SensorKind,
                             unit: HKUnit,
                             format: @escaping (Double) -> String) {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return }
            group.enter()
            let latestQuery = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                guard let latest = samples?.first as? HKQuantitySample else {
                    group.leave()
                    return
                }
                let day = Calendar.current.startOfDay(for: latest.endDate)
                let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                let predicate = HKQuery.predicateForSamples(withStart: day, end: dayEnd, options: .strictStartDate)
                let sumQuery = HKStatisticsQuery(
                    quantityType: type,
                    quantitySamplePredicate: predicate,
                    options: .cumulativeSum
                ) { _, result, _ in
                    if let total = result?.sumQuantity()?.doubleValue(for: unit) {
                        self.record(kind, value: format(total), at: latest.endDate)
                    }
                    group.leave()
                }
                store.execute(sumQuery)
            }
            store.execute(latestQuery)
        }

        stampLatestSample(.heartRate, kind: .heartRate) { sample in
            "\(Int(sample.quantity.doubleValue(for: .count().unitDivided(by: .minute())))) bpm"
        }
        stampLatestSample(.heartRateVariabilitySDNN, kind: .heartRateVariability) { sample in
            "\(Int(sample.quantity.doubleValue(for: .secondUnit(with: .milli)))) ms"
        }
        stampLatestSample(.oxygenSaturation, kind: .bloodOxygen) { sample in
            "\(Int(sample.quantity.doubleValue(for: .percent()) * 100))%"
        }

        stampDailyTotal(.stepCount, kind: .steps, unit: .count()) { total in
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let text = formatter.string(from: NSNumber(value: Int(total))) ?? "\(Int(total))"
            return "\(text) steps"
        }
        stampDailyTotal(.activeEnergyBurned, kind: .activeEnergy, unit: .kilocalorie()) { total in
            "\(Int(total)) kcal"
        }
        stampDailyTotal(.distanceWalkingRunning, kind: .distance, unit: .meter()) { total in
            String(format: "%.1f km", total / 1000.0)
        }
        stampDailyTotal(.flightsClimbed, kind: .flights, unit: .count()) { total in
            "\(Int(total)) flights"
        }

        // Sleep: total asleep-stage time over the last night-and-a-bit (30 h),
        // stamped at the latest sample's end. Older stamps persist unchanged.
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            group.enter()
            let start = Date().addingTimeInterval(-30 * 3600)
            let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
            let sleepQuery = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                defer { group.leave() }
                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                ]
                let asleep = (samples as? [HKCategorySample])?.filter { asleepValues.contains($0.value) } ?? []
                let totalSeconds = asleep.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                guard totalSeconds > 0, let latestEnd = asleep.map(\.endDate).max() else { return }
                self.record(.sleep, value: String(format: "%.1f hr", totalSeconds / 3600.0), at: latestEnd)
            }
            store.execute(sleepQuery)
        }

        group.notify(queue: .main) { completion?() }
    }
}

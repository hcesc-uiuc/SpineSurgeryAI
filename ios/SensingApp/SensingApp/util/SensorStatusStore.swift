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
//  DEBUG builds fall back to the SAMPLE DATA table below, always suffixed
//  "(sample)". RELEASE builds have no fallback at all — the row reads "No data
//  recorded yet". The Sensors tab is NOT behind #if DEBUG, so it ships to
//  patients; a patient without an Apple Watch must never be shown an invented
//  "999 bpm", however it is labelled.
//
//  Storage is UserDefaults: three keys per sensor —
//    sensorLast_<kind>_value    (String, optional — the rendered line, "72 bpm")
//    sensorLast_<kind>_numeric  (Double, optional — the same reading as a number)
//    sensorLast_<kind>_date     (Date)
//
//  `numeric` exists because Home tiles need a NUMBER. Recovering one by parsing
//  the display string back apart is locale-dependent — NumberFormatter renders
//  8420 as "8.420" in de_DE, which parses back as 8.42 — so the raw value is
//  stored alongside the text rather than reconstructed from it.
//
//  CONTRACT: `numeric` is always expressed in the sensor's own unit
//  (SensorKind.unit) — km for distance, percent for blood oxygen, hours for
//  sleep — so it is directly comparable with an imported series.
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
    /// The same reading as a number, in SensorKind.unit. nil for timestamp-only
    /// sensors and for stamps written by builds before this field existed.
    let numeric: Double?
    let date: Date
    let isSample: Bool
}

nonisolated final class SensorStatusStore: @unchecked Sendable {
    static let shared = SensorStatusStore()
    private init() {}

    private let defaults = UserDefaults.standard

#if DEBUG
    // ══════════════════════════════════════════════════════════════════
    //  SAMPLE DATA — EDIT THIS TABLE TO TEST HOW THE SENSORS TAB LOOKS.
    //
    //  DEBUG ONLY. Shown when a sensor has no real recorded stamp yet, and
    //  always rendered with a "(sample)" suffix. `value` is the reading shown
    //  (nil = timestamp-only); `minutesAgo` positions the fake timestamp
    //  relative to now. Values are deliberately absurd (999 bpm) so real
    //  and sample data can never be confused.
    //
    //  Deliberately compiled out of Release: the Sensors tab ships to patients,
    //  and five of these rows (gyroscope, watch PPG, ECG, wrist temperature,
    //  ambient light) have no fetcher at all, so in Release they would have
    //  shown sample data permanently, to everyone.
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
#endif

    private func valueKey(_ kind: SensorKind) -> String { "sensorLast_\(kind.rawValue)_value" }
    private func numericKey(_ kind: SensorKind) -> String { "sensorLast_\(kind.rawValue)_numeric" }
    private func dateKey(_ kind: SensorKind)  -> String { "sensorLast_\(kind.rawValue)_date" }

    /// Stamp a sensor as recorded. Safe to call from any thread (UserDefaults
    /// is thread-safe). Keeps only the newest stamp — older dates are ignored,
    /// so out-of-order batches (e.g. SensorKit) can stamp freely.
    ///
    /// `numeric` is the same reading as a plain number, in SensorKind.unit. Pass
    /// it whenever a number is available; Home tiles read it directly instead of
    /// parsing `value` back apart, which is locale-dependent.
    func record(_ kind: SensorKind, value: String? = nil, numeric: Double? = nil, at date: Date = Date()) {
        if let existing = defaults.object(forKey: dateKey(kind)) as? Date, existing > date { return }
        defaults.set(date, forKey: dateKey(kind))
        if let value {
            defaults.set(value, forKey: valueKey(kind))
        } else {
            defaults.removeObject(forKey: valueKey(kind))
        }
        if let numeric {
            defaults.set(numeric, forKey: numericKey(kind))
        } else {
            defaults.removeObject(forKey: numericKey(kind))
        }
    }

    /// Real stamp if one exists, else (DEBUG only) the sample-table fallback,
    /// else nil. Release has no fallback — see the file header.
    func entry(for kind: SensorKind) -> SensorStatusEntry? {
        if let date = defaults.object(forKey: dateKey(kind)) as? Date {
            return SensorStatusEntry(value: defaults.string(forKey: valueKey(kind)),
                                     numeric: defaults.object(forKey: numericKey(kind)) as? Double,
                                     date: date,
                                     isSample: false)
        }
#if DEBUG
        if let sample = Self.sampleData[kind] {
            return SensorStatusEntry(value: sample.value,
                                     numeric: nil,
                                     date: Date().addingTimeInterval(-sample.minutesAgo * 60),
                                     isSample: true)
        }
#endif
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

        // Both helpers below reduce a sample to ONE number expressed in
        // SensorKind.unit — `reading = doubleValue(for: unit) * scale` — and use
        // that same number for the stored numeric and for the display text, so
        // the two can never disagree.

        /// Latest single sample of a quantity type → stamp value + number.
        func stampLatestSample(_ identifier: HKQuantityTypeIdentifier,
                               kind: SensorKind,
                               unit: HKUnit,
                               scale: Double = 1,
                               format: @escaping (Double) -> String) {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return }
            group.enter()
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                if let sample = samples?.first as? HKQuantitySample {
                    let reading = sample.quantity.doubleValue(for: unit) * scale
                    self.record(kind, value: format(reading), numeric: reading, at: sample.endDate)
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
                             scale: Double = 1,
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
                    if let raw = result?.sumQuantity()?.doubleValue(for: unit) {
                        let total = raw * scale
                        self.record(kind, value: format(total), numeric: total, at: latest.endDate)
                    }
                    group.leave()
                }
                store.execute(sumQuery)
            }
            store.execute(latestQuery)
        }

        stampLatestSample(.heartRate, kind: .heartRate,
                          unit: .count().unitDivided(by: .minute())) { "\(Int($0)) bpm" }
        stampLatestSample(.heartRateVariabilitySDNN, kind: .heartRateVariability,
                          unit: .secondUnit(with: .milli)) { "\(Int($0)) ms" }
        // HealthKit reports saturation as a 0–1 fraction; the sensor's unit is %.
        stampLatestSample(.oxygenSaturation, kind: .bloodOxygen,
                          unit: .percent(), scale: 100) { "\(Int($0))%" }

        stampDailyTotal(.stepCount, kind: .steps, unit: .count()) { total in
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let text = formatter.string(from: NSNumber(value: Int(total))) ?? "\(Int(total))"
            return "\(text) steps"
        }
        stampDailyTotal(.activeEnergyBurned, kind: .activeEnergy, unit: .kilocalorie()) { "\(Int($0)) kcal" }
        // Queried in metres; the sensor's unit is km.
        stampDailyTotal(.distanceWalkingRunning, kind: .distance,
                        unit: .meter(), scale: 1.0 / 1000.0) { String(format: "%.1f km", $0) }
        stampDailyTotal(.flightsClimbed, kind: .flights, unit: .count()) { "\(Int($0)) flights" }

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
                let hours = totalSeconds / 3600.0
                self.record(.sleep, value: String(format: "%.1f hr", hours), numeric: hours, at: latestEnd)
            }
            store.execute(sleepQuery)
        }

        group.notify(queue: .main) { completion?() }
    }
}

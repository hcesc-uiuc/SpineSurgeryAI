//
//  SensorStatusStore.swift
//  SensingApp
//
//  The ONE store behind every sensor reading the app displays — the Sensors tab
//  ("What We Collect") and the Home stat tiles.
//
//  Storage is UserDefaults. Nothing else. There is no sensor database.
//
//  ── Where a displayed reading comes from ────────────────────────────────────
//  Three sources, in strict precedence order:
//
//    1. AN IMPORTED FILE — a dev dropped a data file into the app's Documents
//       folder (visible in Files / Finder) or picked one in the Debug tab.
//       An import WINS until it is cleared, so a demo value cannot be silently
//       overwritten by a live HealthKit refresh two seconds later.
//    2. A REAL STAMP — recorders stamp the store as they save data
//       (AcclerometerRecorder, AdaptiveLocationManager, the SensorKit watch
//       fetcher, survey submit), and refreshHealthKitSamples() stamps the
//       genuine latest sample for each Apple Health row.
//
//  ── Keys, per sensor ────────────────────────────────────────────────────────
//    sensorLast_<kind>_value    String?  the rendered reading, "72 bpm"
//    sensorLast_<kind>_numeric  Double?  the same reading as a number
//    sensorLast_<kind>_date     Date     when it was recorded
//    sensorLast_<kind>_source   String?  "import" — absent means a live stamp
//    sensorImport_<kind>        Data?    JSON metadata about the imported file
//
//  `numeric` exists because Home tiles need a NUMBER. Recovering one by parsing
//  the display string back apart is locale-dependent — NumberFormatter renders
//  8420 as "8.420" in de_DE, which parses back as 8.42 — so the raw value is
//  stored alongside the text rather than reconstructed from it.
//
//  CONTRACT: `numeric` is always expressed in the sensor's own unit
//  (SensorKind.unit) — km for distance, percent for blood oxygen, hours for
//  sleep — so a live stamp and an imported file are directly comparable.
//

import Foundation
import HealthKit

// MARK: - Sensors

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

// MARK: - Per-sensor metadata

nonisolated extension SensorKind {

    /// Human name used in the import picker and the loaded-sensor list.
    var displayName: String {
        switch self {
        case .accelerometer:        return "Accelerometer"
        case .gyroscope:            return "Gyroscope"
        case .location:             return "Location"
        case .heartRate:            return "Heart Rate"
        case .heartRateVariability: return "Heart Rate Variability"
        case .steps:                return "Steps"
        case .distance:             return "Walking Distance"
        case .bloodOxygen:          return "Blood Oxygen"
        case .activeEnergy:         return "Active Energy"
        case .flights:              return "Flights Climbed"
        case .sleep:                return "Sleep"
        case .watchAccelerometer:   return "Watch Accelerometer"
        case .watchHeartPPG:        return "Watch Heart & PPG"
        case .ecg:                  return "ECG"
        case .wristTemperature:     return "Wrist Temperature"
        case .ambientLight:         return "Ambient Light"
        case .survey:               return "Recovery Check-in"
        }
    }

    /// Unit appended to a bare imported number ("72" → "72 bpm").
    /// nil = timestamp-only sensor: the file's value column is ignored and the
    /// row shows only when it was recorded.
    var unit: String? {
        switch self {
        case .heartRate:            return "bpm"
        case .heartRateVariability: return "ms"
        case .steps:                return "steps"
        case .distance:             return "km"
        case .bloodOxygen:          return "%"
        case .activeEnergy:         return "kcal"
        case .flights:              return "flights"
        case .sleep:                return "hr"
        default:                    return nil
        }
    }

    /// True when the sensor carries a numeric reading worth displaying.
    var isNumeric: Bool { unit != nil }

    /// True when the reading accumulates over a day, so the meaningful figure is
    /// a DAILY TOTAL rather than the most recent single measurement.
    ///
    /// This is what keeps the two sources honest. For the live path,
    /// stampDailyTotal below already stores a day total. An imported file holding
    /// one row per hour would otherwise contribute only its LAST row, so the same
    /// "Steps" label would silently mean "today so far" from Apple Health and
    /// "the last hour" from a file. Imported cumulative series are therefore
    /// summed over the day of their newest row — which also leaves a file that
    /// already holds daily totals correct, since that day has one row.
    ///
    /// Sleep is NOT cumulative: it is already stored as a per-night aggregate.
    var isCumulative: Bool {
        switch self {
        case .steps, .distance, .activeEnergy, .flights: return true
        default: return false
        }
    }

    /// Where a non-imported reading for this sensor genuinely comes from.
    var realSource: SensorSource {
        switch self {
        case .heartRate, .heartRateVariability, .steps, .distance,
             .bloodOxygen, .activeEnergy, .flights, .sleep:
            return .healthKit
        case .survey:
            return .checkIn
        default:
            return .recorder
        }
    }

    /// Render a raw number the way this sensor should read.
    func formatted(_ value: Double) -> String {
        guard let unit else { return "" }
        switch self {
        case .steps:
            let f = NumberFormatter()
            f.numberStyle = .decimal
            let n = f.string(from: NSNumber(value: Int(value))) ?? "\(Int(value))"
            return "\(n) \(unit)"
        case .distance, .sleep:
            return String(format: "%.1f %@", value, unit)
        case .bloodOxygen:
            return "\(Int(value))\(unit)"          // no space before %
        default:
            return "\(Int(value)) \(unit)"
        }
    }
}

// MARK: - Model

/// Where a displayed value came from. Drives the source line under every row.
nonisolated enum SensorSource {
    case healthKit
    case recorder
    case checkIn
    case imported(String)

    var label: String {
        switch self {
        case .healthKit:          return "Apple Health"
        case .recorder:           return "this iPhone"
        case .checkIn:            return "your check-ins"
        case .imported(let name): return name
        }
    }
}

nonisolated struct SensorStatusEntry {
    let value: String?      // nil = timestamp-only sensor (motion, location, watch)
    /// The same reading as a number, in SensorKind.unit. nil for timestamp-only
    /// sensors and for stamps written by builds before this field existed.
    let numeric: Double?
    let date: Date
    let source: SensorSource
}

/// What a file contributed, kept so the Debug tab can list what is loaded and
/// offer to clear it. Small enough to live in UserDefaults as JSON.
nonisolated struct SensorImportInfo: Codable, Identifiable {
    let kindRaw: String
    let filename: String
    let rowCount: Int
    let skippedRows: Int
    let dateMin: Date?
    let dateMax: Date?
    let importedAt: Date

    var id: String { kindRaw }
    var kind: SensorKind? { SensorKind(rawValue: kindRaw) }
}

// MARK: - Store

nonisolated final class SensorStatusStore: @unchecked Sendable {
    static let shared = SensorStatusStore()
    private init() {}

    private let defaults = UserDefaults.standard

    private func valueKey(_ kind: SensorKind)   -> String { "sensorLast_\(kind.rawValue)_value" }
    private func numericKey(_ kind: SensorKind) -> String { "sensorLast_\(kind.rawValue)_numeric" }
    private func dateKey(_ kind: SensorKind)    -> String { "sensorLast_\(kind.rawValue)_date" }
    private func sourceKey(_ kind: SensorKind)  -> String { "sensorLast_\(kind.rawValue)_source" }
    private func importKey(_ kind: SensorKind)  -> String { "sensorImport_\(kind.rawValue)" }

    private static let importedMarker = "import"

    /// True when the stored reading came from a file rather than a live stamp.
    func isImported(_ kind: SensorKind) -> Bool {
        defaults.string(forKey: sourceKey(kind)) == Self.importedMarker
    }

    // MARK: Writing — live stamps

    /// Stamp a sensor as recorded. Safe to call from any thread (UserDefaults
    /// is thread-safe). Keeps only the newest stamp — older dates are ignored,
    /// so out-of-order batches (e.g. SensorKit) can stamp freely.
    ///
    /// `numeric` is the same reading as a plain number, in SensorKind.unit. Pass
    /// it whenever a number is available; Home tiles read it directly instead of
    /// parsing `value` back apart, which is locale-dependent.
    ///
    /// NO-OP while an import is loaded for this sensor. That is the whole point
    /// of an import: a dev drops a file, and the value stays put until they
    /// clear it, instead of being overwritten by the next HealthKit refresh.
    func record(_ kind: SensorKind, value: String? = nil, numeric: Double? = nil, at date: Date = Date()) {
        guard !isImported(kind) else { return }
        if let existing = defaults.object(forKey: dateKey(kind)) as? Date, existing > date { return }
        write(kind, value: value, numeric: numeric, date: date)
        defaults.removeObject(forKey: sourceKey(kind))
    }

    // MARK: Writing — imports

    /// Store the one reading a file boils down to, and mark the sensor imported.
    ///
    /// Deliberately skips the newest-wins guard that `record` applies: an
    /// imported file is frequently OLDER than the live stamp it is replacing
    /// (that is normal for test data), and it must still take effect.
    func recordImport(_ kind: SensorKind,
                      value: String?,
                      numeric: Double?,
                      at date: Date,
                      info: SensorImportInfo) {
        write(kind, value: value, numeric: numeric, date: date)
        defaults.set(Self.importedMarker, forKey: sourceKey(kind))
        if let data = try? JSONEncoder().encode(info) {
            defaults.set(data, forKey: importKey(kind))
        }
    }

    private func write(_ kind: SensorKind, value: String?, numeric: Double?, date: Date) {
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

    /// Forget an imported reading entirely. The row falls back to whatever the
    /// live sources next produce — for Apple Health rows that is the very next
    /// refresh; for recorder rows, the next time that recorder runs.
    func clearImport(_ kind: SensorKind) {
        guard isImported(kind) else { return }
        defaults.removeObject(forKey: valueKey(kind))
        defaults.removeObject(forKey: numericKey(kind))
        defaults.removeObject(forKey: dateKey(kind))
        defaults.removeObject(forKey: sourceKey(kind))
        defaults.removeObject(forKey: importKey(kind))
    }

    func clearAllImports() {
        for kind in SensorKind.allCases { clearImport(kind) }
    }

    /// Metadata for every sensor currently showing imported data.
    func loadedImports() -> [SensorImportInfo] {
        SensorKind.allCases.compactMap { importInfo(for: $0) }
            .sorted { $0.importedAt > $1.importedAt }
    }

    func importInfo(for kind: SensorKind) -> SensorImportInfo? {
        guard isImported(kind), let data = defaults.data(forKey: importKey(kind)) else { return nil }
        return try? JSONDecoder().decode(SensorImportInfo.self, from: data)
    }

    // MARK: Reading

    /// Imported reading if one is loaded, else the real stamp, else (DEBUG only)
    /// the sample-table fallback, else nil. Release has no sample fallback — see
    /// the file header.
    func entry(for kind: SensorKind) -> SensorStatusEntry? {
        if let date = defaults.object(forKey: dateKey(kind)) as? Date {
            let source: SensorSource
            if isImported(kind) {
                source = .imported(importInfo(for: kind)?.filename ?? "an imported file")
            } else {
                source = kind.realSource
            }
            return SensorStatusEntry(value: defaults.string(forKey: valueKey(kind)),
                                     numeric: defaults.object(forKey: numericKey(kind)) as? Double,
                                     date: date,
                                     source: source)
        }
        return nil
    }

    /// Value + caption for a Home stat tile. The caption appears only when the
    /// reading is noteworthy — imported, or simply not from today — so live
    /// same-day HealthKit data keeps the clean, caption-free look and a stale
    /// import is impossible to mistake for a fresh one.
    ///
    /// The hardcoded sample table is deliberately NOT surfaced here. Unlike the
    /// Sensors tab, Home is not behind #if DEBUG — it ships. A patient whose
    /// HealthKit simply has no data must see "—", not "99,999 steps" with a
    /// small caption. Home therefore shows real or imported readings only.
    func homeTile(for kind: SensorKind) -> (value: Double, caption: String?)? {
        guard let entry = entry(for: kind) else { return nil }
        guard let value = entry.numeric ?? entry.value.flatMap(Self.numericValue(from:)) else { return nil }

        let isToday = Calendar.current.isDateInToday(entry.date)
        var caption: String?
        switch entry.source {
        case .imported(let name):
            caption = isToday ? shortName(name) : "\(shortName(name)) · \(Self.shortDayFormatter.string(from: entry.date))"
        case .healthKit, .recorder, .checkIn:
            caption = isToday ? nil : Self.shortDayFormatter.string(from: entry.date)
        }
        return (value, caption)
    }

    /// Tiles are narrow — keep the filename readable rather than complete.
    private func shortName(_ filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return stem.count > 14 ? String(stem.prefix(13)) + "…" : stem
    }

    /// Pulls the number back out of a display string ("72 bpm" → 72).
    ///
    /// LEGACY FALLBACK ONLY — `SensorStatusEntry.numeric` is the real path.
    /// This assumes "," grouping and "." decimals, so it is wrong on a device
    /// whose locale reverses them (de_DE renders 8420 as "8.420", which lands
    /// here as 8.42). It survives only to read stamps written by builds that
    /// predate `numeric`, and to give the DEBUG sample table a value.
    private static func numericValue(from text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        var digits = ""
        for ch in cleaned {
            if ch.isNumber || ch == "." { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return Double(digits)
    }

    // "Jul 22" — compact enough for a stat tile caption.
    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}

// MARK: - HealthKit latest-sample refresh

extension SensorStatusStore {

    /// Queries HealthKit for the genuine latest reading of each Apple Health row
    /// and stamps the store. Read-only; sensors the user hasn't authorized simply
    /// return no samples and keep their previous stamp (or sample fallback).
    /// Sensors currently showing an imported file are left alone by `record`.
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
                               scale: Double = 1) {
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
                    self.record(kind, value: kind.formatted(reading), numeric: reading, at: sample.endDate)
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
                             scale: Double = 1) {
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
                        self.record(kind, value: kind.formatted(total), numeric: total, at: latest.endDate)
                    }
                    group.leave()
                }
                store.execute(sumQuery)
            }
            store.execute(latestQuery)
        }

        stampLatestSample(.heartRate, kind: .heartRate,
                          unit: .count().unitDivided(by: .minute()))
        stampLatestSample(.heartRateVariabilitySDNN, kind: .heartRateVariability,
                          unit: .secondUnit(with: .milli))
        // HealthKit reports saturation as a 0–1 fraction; the sensor's unit is %.
        stampLatestSample(.oxygenSaturation, kind: .bloodOxygen,
                          unit: .percent(), scale: 100)

        stampDailyTotal(.stepCount, kind: .steps, unit: .count())
        stampDailyTotal(.activeEnergyBurned, kind: .activeEnergy, unit: .kilocalorie())
        // Queried in metres; the sensor's unit is km.
        stampDailyTotal(.distanceWalkingRunning, kind: .distance,
                        unit: .meter(), scale: 1.0 / 1000.0)
        stampDailyTotal(.flightsClimbed, kind: .flights, unit: .count())

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
                self.record(.sleep, value: SensorKind.sleep.formatted(hours), numeric: hours, at: latestEnd)
            }
            store.execute(sleepQuery)
        }

        group.notify(queue: .main) { completion?() }
    }
}

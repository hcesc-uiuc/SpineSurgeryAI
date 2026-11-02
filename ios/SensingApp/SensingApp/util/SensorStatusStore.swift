//
//  SensorStatusStore.swift
//  SensingApp
//
//  The one store behind every sensor reading the app shows (Sensors tab, Home tiles).
//  Every data type follows the same three steps:
//
//    1. RECORD   a recorder gets data and calls
//                SensorStatusStore.shared.record(kind, value:, numeric:, at: <newest sample time>)
//                SensorKit readers do it through SensorKitStamp at the end of each fetch.
//    2. STORE    one SensorLog per kind, all in UserDefaults "sensorLogs":
//                the latest reading plus the 10 before it. Every change is logged.
//    3. DISPLAY  SensorFeed (Sensors tab) and HomeView read latest(for:) / homeTile(for:).
//
//  Testing: a file dropped into Documents/ (or picked in Debug) goes through
//  recordImport and shows on the same screens. It stays there until cleared;
//  live readings that arrive meanwhile go into the history.
//
//  `numeric` is always in SensorKind.unit, so live and imported readings compare directly.
//

import Foundation
import HealthKit
import SensorKit
import UIKit

// MARK: - Sensors

/// One case per data type the app collects.
nonisolated enum SensorKind: String, CaseIterable {
    // Phone motion & location
    case accelerometer, gyroscope, location
    // Phone use & surroundings (SensorKit)
    case deviceUsage, phoneUsage, messagesUsage, keyboard, ambientLight, pressure
    // Apple Health (distance and flights feed Home tiles only)
    case heartRate, heartRateVariability, steps, distance, flights, bloodOxygen, activeEnergy, sleep
    // Apple Watch (SensorKit)
    case watchAccelerometer, watchHeartRate, watchPPG, wristTemperature, wristDetection, watchSleep
    // Daily check-in
    case survey
}

// MARK: - Per-sensor metadata

nonisolated extension SensorKind {

    var displayName: String {
        switch self {
        case .accelerometer:        return "Accelerometer"
        case .gyroscope:            return "Gyroscope"
        case .location:             return "Location"
        case .deviceUsage:          return "Phone Use"
        case .phoneUsage:           return "Calls"
        case .messagesUsage:        return "Messages"
        case .keyboard:             return "Typing"
        case .ambientLight:         return "Ambient Light"
        case .pressure:             return "Air Pressure"
        case .heartRate:            return "Heart Rate"
        case .heartRateVariability: return "Heart Rate Variability"
        case .steps:                return "Steps"
        case .distance:             return "Walking Distance"
        case .flights:              return "Flights Climbed"
        case .bloodOxygen:          return "Blood Oxygen"
        case .activeEnergy:         return "Active Energy"
        case .sleep:                return "Sleep"
        case .watchAccelerometer:   return "Watch Accelerometer"
        case .watchHeartRate:       return "Watch Heart Rate"
        case .watchPPG:             return "Watch PPG"
        case .wristTemperature:     return "Wrist Temperature"
        case .wristDetection:       return "Watch Worn"
        case .watchSleep:           return "Watch Sleep"
        case .survey:               return "Recovery Check-in"
        }
    }

    /// Unit appended to a bare imported number ("72" → "72 bpm").
    /// nil = timestamp-only sensor: the row shows only when it was recorded.
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

    var isNumeric: Bool { unit != nil }

    /// Readings that add up over a day, so the figure shown is the day total.
    /// Sleep is not: it is already stored per night.
    var isCumulative: Bool {
        switch self {
        case .steps, .distance, .activeEnergy, .flights: return true
        default: return false
        }
    }

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

nonisolated struct SensorReading: Codable, Equatable, CustomStringConvertible {
    var value: String?          // "72 bpm"; nil for timestamp-only sensors
    var numeric: Double?        // the same number, in SensorKind.unit
    var date: Date              // newest sample time
    var importedFrom: String?   // file name, when it came from an import

    var description: String {
        "\(value ?? "recorded") @ \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

nonisolated struct SensorLog: Codable {
    var latest: SensorReading?
    var previous: [SensorReading] = []   // newest first, at most 10
    var importInfo: SensorImportInfo?    // set while an imported file is on screen

    /// Makes `reading` the latest; the old latest moves into the history.
    mutating func push(_ reading: SensorReading) {
        if let latest { addToHistory(latest) }
        latest = reading
    }

    mutating func addToHistory(_ reading: SensorReading) {
        previous = Array(([reading] + previous).prefix(10))
    }
}

/// What an imported file contributed. Shown in the Debug import list.
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
    private init() {
        // Returning to the app always re-queries Health; the 15-min rule is for tab switches.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastHealthQuery = nil
            self?.logLine("Store: app back from background, next refresh re-queries Apple Health")
        }
    }

    private let defaults = UserDefaults.standard
    private let key = "sensorLogs"
    private let lock = NSLock()           // recorders write from background threads
    private var lastHealthQuery: Date?    // main thread only (see refresh)

    // MARK: Step 3 — reading

    func log(for kind: SensorKind) -> SensorLog? { loadAll()[kind.rawValue] }

    func latest(for kind: SensorKind) -> SensorReading? { log(for: kind)?.latest }

    func allLatest() -> [SensorKind: SensorReading] {
        var result: [SensorKind: SensorReading] = [:]
        for (raw, log) in loadAll() {
            if let kind = SensorKind(rawValue: raw), let latest = log.latest { result[kind] = latest }
        }
        return result
    }

    func loadedImports() -> [SensorImportInfo] {
        loadAll().values.compactMap(\.importInfo).sorted { $0.importedAt > $1.importedAt }
    }

    /// Value + caption for a Home tile. The caption appears only when the reading is
    /// imported or not from today, so a stale value can't pass for a fresh one.
    func homeTile(for kind: SensorKind) -> (value: Double, caption: String?)? {
        guard let reading = latest(for: kind), let value = reading.numeric else { return nil }
        let day = Calendar.current.isDateInToday(reading.date)
            ? nil : Self.shortDayFormatter.string(from: reading.date)
        let file = reading.importedFrom.map(shortName)
        let caption = [file, day].compactMap { $0 }.joined(separator: " · ")
        return (value, caption.isEmpty ? nil : caption)
    }

    // MARK: Step 1 — writing

    /// A live reading. Ignored if it is older than, or the same as, the latest.
    /// While an import is on screen it goes into the history instead.
    func record(_ kind: SensorKind, value: String? = nil, numeric: Double? = nil, at date: Date = Date()) {
        let reading = SensorReading(value: value, numeric: numeric, date: date)
        update(kind) { log in
            if log.importInfo != nil {
                guard !log.previous.contains(reading) else { return nil }
                log.addToHistory(reading)
                return "← \(reading) (history only, an import is on screen)"
            }
            if let latest = log.latest, latest == reading || latest.date > date { return nil }
            let was = log.latest
            log.push(reading)
            return "← \(reading) (was \(was?.description ?? "empty"))"
        }
    }

    /// An imported file's reading. Always shown, even if older than the live one.
    func recordImport(_ kind: SensorKind, value: String?, numeric: Double?, at date: Date, info: SensorImportInfo) {
        let reading = SensorReading(value: value, numeric: numeric, date: date, importedFrom: info.filename)
        update(kind) { log in
            log.push(reading)
            log.importInfo = info
            return "← \(reading) (imported from \(info.filename))"
        }
    }

    /// Takes an import off screen; the newest live reading in the history comes back.
    func clearImport(_ kind: SensorKind) {
        update(kind) { log in
            guard log.importInfo != nil else { return nil }
            log.importInfo = nil
            let live = log.previous.firstIndex { $0.importedFrom == nil }.map { log.previous.remove(at: $0) }
            if let imported = log.latest { log.addToHistory(imported) }
            log.latest = live
            return "import cleared, showing \(live?.description ?? "nothing")"
        }
    }

    func clearAllImports() {
        for kind in SensorKind.allCases { clearImport(kind) }
    }

    // MARK: Step 2 — storage

    private func loadAll() -> [String: SensorLog] {
        guard let data = defaults.data(forKey: key),
              let all = try? JSONDecoder().decode([String: SensorLog].self, from: data) else { return [:] }
        return all
    }

    /// Read-modify-write of one sensor's log. `change` returns a note for the
    /// log file, or nil when nothing changed.
    private func update(_ kind: SensorKind, _ change: (inout SensorLog) -> String?) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadAll()
        var log = all[kind.rawValue] ?? SensorLog()
        guard let note = change(&log) else { return }
        all[kind.rawValue] = log
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }

        logLine("Store: \(kind.rawValue) \(note)")
    }

    private func logLine(_ line: String) {
        print(line)
        DispatchQueue.main.async { Logger.shared.append(line) }
    }

    // MARK: Refresh (Home + Sensors tab)

    /// Step 1 for dropped files and Apple Health: loads any new file in Documents/,
    /// then re-queries Health if the last query was 15+ minutes ago, `force`, or the
    /// app has come back from the background since.
    /// Call from the main thread; `completion` runs on main.
    func refresh(force: Bool = false, completion: @escaping () -> Void) {
        let healthDue = force || lastHealthQuery.map { Date().timeIntervalSince($0) >= 15 * 60 } ?? true
        if healthDue { lastHealthQuery = Date() }
        logLine(healthDue ? "Store: querying Apple Health" : "Store: Apple Health queried < 15 min ago, skipping")

        DispatchQueue.global(qos: .userInitiated).async {
            SensorFileImporter.autoIngestInbox()
            if healthDue {
                self.refreshHealthKitSamples(completion: completion)
            } else {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    // MARK: Formatting

    /// Tiles are narrow: keep the file name readable rather than complete.
    private func shortName(_ filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return stem.count > 14 ? String(stem.prefix(13)) + "…" : stem
    }

    private static let shortDayFormatter: DateFormatter = {   // "Jul 22"
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}

// MARK: - SensorKit → store

/// Each SensorKit reader keeps one: `saw(result)` in didFetchResult and `save()`
/// in didCompleteFetch, which records the newest sample time of that fetch.
nonisolated struct SensorKitStamp {
    let kind: SensorKind
    private var newest: Date?

    init(_ kind: SensorKind) { self.kind = kind }

    mutating func saw(_ result: SRFetchResult<AnyObject>) {
        let date = Date(timeIntervalSinceReferenceDate: result.timestamp.toCFAbsoluteTime())
        newest = max(newest ?? date, date)
    }

    mutating func save() {
        if let newest { SensorStatusStore.shared.record(kind, at: newest) }
        newest = nil
    }
}

// MARK: - HealthKit latest-sample refresh

extension SensorStatusStore {

    /// One-shot queries for the latest reading of each Apple Health row. Types the
    /// user hasn't authorized return nothing and keep their previous reading.
    /// `completion` fires on the main queue after all queries finish.
    fileprivate func refreshHealthKitSamples(completion: (() -> Void)? = nil) {
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

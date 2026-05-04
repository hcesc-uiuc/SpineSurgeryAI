import Foundation
import HealthKit
internal import Combine

// MARK: - Supported Metrics Gatekeeper
enum SupportedMetric: String, CaseIterable {
    case heartRate         = "Heart Rate"
    case steps             = "Steps"
    case hrv               = "HRV"
    case oxygen            = "Oxygen"
    case calories          = "Calories"
    case standTime         = "Stand Time"
    case walkingSpeed      = "Walking Speed"
    case walkingAsymmetry  = "Walking Asymmetry"
    case walkingSteadiness = "Walking Steadiness"
    case sleep             = "Sleep"

    /// Maps our clean label to the official HealthKit Sample Type
    var hkType: HKSampleType? {
        switch self {
        case .sleep:
            return HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)
        case .heartRate: return HKQuantityType.quantityType(forIdentifier: .heartRate)
        case .steps:     return HKQuantityType.quantityType(forIdentifier: .stepCount)
        case .hrv:       return HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        case .oxygen:    return HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)
        case .calories:  return HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
        case .standTime: return HKQuantityType.quantityType(forIdentifier: .appleStandTime)
        case .walkingSpeed: return HKQuantityType.quantityType(forIdentifier: .walkingSpeed)
        case .walkingAsymmetry: return HKQuantityType.quantityType(forIdentifier: .walkingAsymmetryPercentage)
        case .walkingSteadiness: return HKQuantityType.quantityType(forIdentifier: .appleWalkingSteadiness)
        }
    }
    
    var unit: HKUnit? {
        switch self {
        case .heartRate: return HKUnit.count().unitDivided(by: .minute())
        case .hrv:       return .secondUnit(with: .milli)
        case .steps, .standTime: return .count()
        case .calories:  return .kilocalorie()
        case .oxygen, .walkingAsymmetry, .walkingSteadiness: return .percent()
        case .walkingSpeed: return HKUnit.meter().unitDivided(by: .second())
        case .sleep:     return nil
        }
    }
}

// MARK: - HealthKit Manager
class HealthKitManager: ObservableObject {
    let healthStore = HKHealthStore()
 
    @Published var trialData: [RawDataPoint] = []
    @Published var sleepData: [SleepDataPoint] = []
    
    @Published var deepFetchDaysBack: Int = 1
    @Published var selectedSleepDaysBack: Int = 7
 
    // MARK: - Data Models
    
    struct RawDataPoint: Identifiable {
        let id: UUID
        let type: String
        let value: Double?
        let unit: String
        let startDate: Date
        let endDate: Date
        let startUnix: Double
        let endUnix: Double
        let duration: TimeInterval
        let sourceName: String
        let bundleID: String
        let deviceName: String?
        let metadata: [String: Any]?
    }
    
    struct SleepDataPoint: Identifiable {
        let id: UUID
        let sleepStage: String
        let sleepStageRaw: Int
        let startDate: Date
        let endDate: Date
        let startUnix: Double
        let endUnix: Double
        let duration: TimeInterval
        let sourceName: String
        let bundleID: String
        let metadata: [String: Any]
    }
    
    struct NightSummary: Identifiable {
        let id = UUID()
        let nightDate: Date
        let bedtime: Date
        let wakeTime: Date
        let totalInBedSeconds: Double
        let totalAsleepSeconds: Double
        let totalCoreSeconds: Double
        let totalDeepSeconds: Double
        let totalREMSeconds: Double
        let totalAwakeSeconds: Double
        let sampleCount: Int
        let primarySource: String
    }
    
    var nightSummaries: [NightSummary] {
        buildNightSummaries(from: sleepData)
    }
 
    init() {
        if HKHealthStore.isHealthDataAvailable() {
            requestPermissions()
        }
    }
    
    // MARK: - Permissions & Background
    func requestPermissions() {
        let typesToRead = Set(SupportedMetric.allCases.compactMap { $0.hkType })
        
        healthStore.requestAuthorization(toShare: nil, read: typesToRead) { success, _ in
            if success {
                for type in typesToRead {
                    if let sampleType = type as? HKSampleType {
                        self.setupBackgroundObserver(for: sampleType)
                    }
                }
            }
        }
    }

    private func setupBackgroundObserver(for type: HKSampleType) {
        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
            guard error == nil else { completion(); return }
            
            if let metric = SupportedMetric.allCases.first(where: { $0.hkType?.identifier == type.identifier }) {
                // Background triggers are NEVER historical. They use and update the anchor.
                if metric == .sleep {
                    self?.fetchSleepData(daysBack: 1, isHistorical: false) { completion() }
                } else {
                    self?.fetchDeepData(for: metric, daysBack: 1, isHistorical: false) { _ in completion() }
                }
            } else {
                completion()
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Public Fetch Interface (Historical)
    func refreshWithNewRange(days: Int, types: Set<SupportedMetric> = [], completion: @escaping ([RawDataPoint]) -> Void) {
        let metricsToFetch = types.isEmpty ? Set(SupportedMetric.allCases) : types
        let group = DispatchGroup()
        let internalQueue = DispatchQueue(label: "healthkit.data.accumulation")
        var accumulatedData: [RawDataPoint] = []

        for metric in metricsToFetch {
            group.enter()
            // UI requests are ALWAYS historical. They ignore the anchor to get full date ranges.
            if metric == .sleep {
                fetchSleepData(daysBack: days, isHistorical: true) { group.leave() }
            } else {
                fetchDeepData(for: metric, daysBack: days, isHistorical: true) { newPoints in
                    internalQueue.async {
                        accumulatedData.append(contentsOf: newPoints)
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            self.trialData = accumulatedData.sorted { $0.startDate > $1.startDate }
            completion(self.trialData)
        }
    }

    // MARK: - Private Query Logic
    
    private func fetchDeepData(for metric: SupportedMetric, daysBack: Int, isHistorical: Bool = false, completion: @escaping ([RawDataPoint]) -> Void) {
        guard let type = metric.hkType as? HKQuantityType, let unit = metric.unit else { completion([]); return }
        
        let anchorKey = "anchor_\(metric.rawValue)"
        let anchorToUse = isHistorical ? nil : getAnchor(for: anchorKey)
        
        let startDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchorToUse, limit: HKObjectQueryNoLimit) { [weak self] _, samples, deleted, newAnchor, error in
            
            guard let samples = samples as? [HKQuantitySample] else { completion([]); return }
            
            let points = samples.map { sample in
                RawDataPoint(
                    id: sample.uuid, type: metric.rawValue, value: sample.quantity.doubleValue(for: unit), unit: unit.unitString,
                    startDate: sample.startDate, endDate: sample.endDate, startUnix: sample.startDate.timeIntervalSince1970,
                    endUnix: sample.endDate.timeIntervalSince1970, duration: sample.endDate.timeIntervalSince(sample.startDate),
                    sourceName: sample.sourceRevision.source.name, bundleID: sample.sourceRevision.source.bundleIdentifier,
                    deviceName: sample.device?.name, metadata: sample.metadata
                )
            }
            
            if !isHistorical {
                self?.saveAnchor(newAnchor, for: anchorKey)
                // Insert External DB Sync Call Here (passing 'points' and 'deleted')
            }
            
            completion(points)
        }
        healthStore.execute(query)
    }

    private func fetchSleepData(daysBack: Int, isHistorical: Bool = false, completion: @escaping () -> Void) {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { completion(); return }
        
        let anchorKey = "anchor_sleep"
        let anchorToUse = isHistorical ? nil : getAnchor(for: anchorKey)
        
        let startDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let query = HKAnchoredObjectQuery(type: sleepType, predicate: predicate, anchor: anchorToUse, limit: HKObjectQueryNoLimit) { [weak self] _, samples, deleted, newAnchor, error in
            guard let samples = samples as? [HKCategorySample] else { completion(); return }
            
            DispatchQueue.main.async {
                let newPoints = samples.map { sample in
                    SleepDataPoint(
                        id: sample.uuid, sleepStage: Self.stageName(for: sample.value), sleepStageRaw: sample.value,
                        startDate: sample.startDate, endDate: sample.endDate, startUnix: sample.startDate.timeIntervalSince1970,
                        endUnix: sample.endDate.timeIntervalSince1970, duration: sample.endDate.timeIntervalSince(sample.startDate),
                        sourceName: sample.sourceRevision.source.name, bundleID: sample.sourceRevision.source.bundleIdentifier,
                        metadata: sample.metadata ?? [:]
                    )
                }
                
                if isHistorical {
                    self?.sleepData = newPoints.sorted { $0.startDate > $1.startDate }
                } else {
                    self?.sleepData = (newPoints + (self?.sleepData ?? [])).prefix(2000).sorted { $0.startDate > $1.startDate }
                    self?.saveAnchor(newAnchor, for: anchorKey)
                    // Insert External DB Sync Call Here
                }
                completion()
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Sleep Helpers & Summarization
    static func stageName(for value: Int) -> String {
        guard let stage = HKCategoryValueSleepAnalysis(rawValue: value) else { return "Unknown" }
        switch stage {
        case .inBed: return "InBed"
        case .asleepUnspecified: return "Asleep"
        case .asleepCore: return "Core"
        case .asleepDeep: return "Deep"
        case .asleepREM: return "REM"
        case .awake: return "Awake"
        @unknown default: return "Unknown"
        }
    }
    
    private func buildNightSummaries(from points: [SleepDataPoint]) -> [NightSummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: points) { point -> Date in
            let hour = calendar.component(.hour, from: point.startDate)
            let date = hour >= 18 ? calendar.date(byAdding: .day, value: 1, to: point.startDate)! : point.startDate
            return calendar.startOfDay(for: date)
        }
        
        return grouped.map { (nightDate, samples) in
            let bedtime = samples.map(\.startDate).min() ?? nightDate
            let wakeTime = samples.map(\.endDate).max() ?? nightDate
            let source = Dictionary(grouping: samples, by: \.sourceName).max(by: { $0.value.count < $1.value.count })?.key ?? "Unknown"
            
            return NightSummary(
                nightDate: nightDate, bedtime: bedtime, wakeTime: wakeTime,
                totalInBedSeconds: samples.filter { $0.sleepStage == "InBed" }.reduce(0) { $0 + $1.duration },
                totalAsleepSeconds: samples.filter { ["Asleep", "Core", "Deep", "REM"].contains($0.sleepStage) }.reduce(0) { $0 + $1.duration },
                totalCoreSeconds: samples.filter { $0.sleepStage == "Core" }.reduce(0) { $0 + $1.duration },
                totalDeepSeconds: samples.filter { $0.sleepStage == "Deep" }.reduce(0) { $0 + $1.duration },
                totalREMSeconds: samples.filter { $0.sleepStage == "REM" }.reduce(0) { $0 + $1.duration },
                totalAwakeSeconds: samples.filter { $0.sleepStage == "Awake" }.reduce(0) { $0 + $1.duration },
                sampleCount: samples.count, primarySource: source
            )
        }.sorted { $0.nightDate > $1.nightDate }
    }
    
    // MARK: - CSV Exports
    
    /// Exports non-sleep quantity data (Steps, HR, etc.) from trialData
    func exportRawDataCSV() -> String {
        var csv = "type,value,unit,start_date,end_date,start_unix,end_unix,duration_ms,source,bundle_id,device,metadata\n"
        for p in trialData.sorted(by: { $0.startDate < $1.startDate }) {
            let meta = (p.metadata ?? [:]).map { "\($0.key):\($0.value)" }
                .joined(separator: "|")
                .replacingOccurrences(of: ",", with: ";")
            
            let row = [
                p.type, "\(p.value ?? 0)", p.unit,
                ISO8601DateFormatter().string(from: p.startDate),
                ISO8601DateFormatter().string(from: p.endDate),
                "\(Int(p.startUnix))", "\(Int(p.endUnix))", "\(Int(p.duration * 1000))",
                p.sourceName.replacingOccurrences(of: ",", with: ";"),
                p.bundleID, (p.deviceName ?? "NA").replacingOccurrences(of: ",", with: ";"),
                "{\(meta)}"
            ].joined(separator: ",")
            csv += row + "\n"
        }
        return csv
    }

    /// Exports individual sleep stage samples (Core, Deep, REM, etc.)
    func exportSleepCSV() -> String {
        var csv = "id,stage,stage_raw,start_date,end_date,start_unix,end_unix,duration_sec,source,bundle_id,metadata\n"
        for p in sleepData.sorted(by: { $0.startDate < $1.startDate }) {
            let meta = p.metadata.map { "\($0.key):\($0.value)" }
                .joined(separator: "|")
                .replacingOccurrences(of: ",", with: ";")

            let row = [
                p.id.uuidString, p.sleepStage, "\(p.sleepStageRaw)",
                ISO8601DateFormatter().string(from: p.startDate),
                ISO8601DateFormatter().string(from: p.endDate),
                "\(Int(p.startUnix))", "\(Int(p.endUnix))", "\(Int(p.duration))",
                p.sourceName.replacingOccurrences(of: ",", with: ";"),
                p.bundleID, "{\(meta)}"
            ].joined(separator: ",")
            csv += row + "\n"
        }
        return csv
    }
    
    /// Exports aggregated nights (One row per night)
    func exportNightSummariesCSV() -> String {
        let fmt = ISO8601DateFormatter()
        var csv = "night_date,bedtime,wake_time,in_bed_min,asleep_min,core_min,deep_min,rem_min,awake_min,sample_count,source\n"
        
        for n in nightSummaries.sorted(by: { $0.nightDate < $1.nightDate }) {
            let row = [
                fmt.string(from: n.nightDate),
                fmt.string(from: n.bedtime),
                fmt.string(from: n.wakeTime),
                String(format: "%.1f", n.totalInBedSeconds / 60),
                String(format: "%.1f", n.totalAsleepSeconds / 60),
                String(format: "%.1f", n.totalCoreSeconds / 60),
                String(format: "%.1f", n.totalDeepSeconds / 60),
                String(format: "%.1f", n.totalREMSeconds / 60),
                String(format: "%.1f", n.totalAwakeSeconds / 60),
                "\(n.sampleCount)",
                n.primarySource.replacingOccurrences(of: ",", with: ";")
            ].joined(separator: ",")
            csv += row + "\n"
        }
        return csv
    }
    
    // MARK: - Anchor Persistence
    private func saveAnchor(_ anchor: HKQueryAnchor?, for key: String) {
        guard let anchor = anchor else { return }
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func getAnchor(for key: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}

import Foundation
import HealthKit
internal import Combine

// MARK: - Supported Metrics Gatekeeper
enum SupportedMetric: String, CaseIterable {
    case heartRate = "Heart Rate"
    case steps     = "Steps"
    case hrv       = "HRV"
    case oxygen    = "Oxygen"
    case calories  = "Calories"
    case standTime     = "Stand Time"

    /// Maps our clean label to the official HealthKit Identifier
    var hkIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .heartRate: return .heartRate
        case .steps:     return .stepCount
        case .hrv:       return .heartRateVariabilitySDNN
        case .oxygen:    return .oxygenSaturation
        case .calories:  return .activeEnergyBurned
        case .standTime:     return .appleStandTime
        }
    }
    
    /// Maps the metric to its biological measurement unit
    var unit: HKUnit {
        switch self {
        case .heartRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .hrv:
            return .secondUnit(with: .milli)
        case .steps, .standTime:
            return .count()
        case .calories:
            return .kilocalorie()
        case .oxygen:
            return .percent()
        }
    }
}

// MARK: - HealthKit Manager
class HealthKitManager: ObservableObject {
    let healthStore = HKHealthStore()

    @Published var trialData: [RawDataPoint] = []
    @Published var deepFetchDaysBack: Int = 1

    // Data structure for export and UI
    struct RawDataPoint: Identifiable {
        let id: UUID
        let type: String            // Enum label
        let value: Double?
        let unit: String
        
        let startDate: Date
        let endDate: Date
        let startUnix: Double
        let endUnix: Double
        let duration: TimeInterval
        let fetchedAt: Date
        
        let sourceName: String
        let bundleID: String
        let deviceName: String?
        let deviceModel: String?
        let softwareVer: String?
        let metadata: [String: Any]?
    }

    init() {
        if HKHealthStore.isHealthDataAvailable() {
            requestPermissions()
        }
    }

    // MARK: - Permissions & Background
    func requestPermissions() {
        let typesToRead = Set(SupportedMetric.allCases.compactMap {
            HKQuantityType.quantityType(forIdentifier: $0.hkIdentifier)
        })
        
        healthStore.requestAuthorization(toShare: nil, read: typesToRead) { success, _ in
            if success {
                for type in typesToRead {
                    self.setupBackgroundObserver(for: type)
                }
            }
        }
    }

    private func setupBackgroundObserver(for type: HKQuantityType) {
        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
            guard error == nil else {
                completion()
                return
            }
            
            // Map the trigger back to our Enum to perform the fetch
            if let metric = SupportedMetric.allCases.first(where: { $0.hkIdentifier.rawValue == type.identifier }) {
                self?.fetchDeepData(for: metric, daysBack: self?.deepFetchDaysBack ?? 1) { _ in
                    completion()
                }
            } else {
                completion()
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Public Fetch Interface
    
    /// Fetches data for specified metrics. If 'types' is empty, it fetches all supported metrics.
    func refreshWithNewRange(
        days: Int,
        types: Set<SupportedMetric> = [],
        completion: @escaping ([RawDataPoint]) -> Void
    ) {
        let metricsToFetch = types.isEmpty ? Set(SupportedMetric.allCases) : types
        let group = DispatchGroup()
        var accumulatedData: [RawDataPoint] = []

        for metric in metricsToFetch {
            group.enter()
            fetchDeepData(for: metric, daysBack: days) { newPoints in
                accumulatedData.append(contentsOf: newPoints)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let sortedData = accumulatedData.sorted { $0.startDate > $1.startDate }
            self.trialData = sortedData
            completion(sortedData)
        }
    }

    // MARK: - Private Query Logic
    private func fetchDeepData(for metric: SupportedMetric, daysBack: Int, completion: @escaping ([RawDataPoint]) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: metric.hkIdentifier) else {
            completion([])
            return
        }
        
        let startDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { _, samples, _, _, _ in
            
            guard let samples = samples as? [HKQuantitySample] else {
                completion([])
                return
            }
            
            let points = samples.map { sample in
                return RawDataPoint(
                    id: sample.uuid,
                    type: metric.rawValue,
                    value: sample.quantity.doubleValue(for: metric.unit),
                    unit: metric.unit.unitString,
                    startDate: sample.startDate,
                    endDate: sample.endDate,
                    startUnix: sample.startDate.timeIntervalSince1970,
                    endUnix: sample.endDate.timeIntervalSince1970,
                    duration: sample.endDate.timeIntervalSince(sample.startDate),
                    fetchedAt: Date(),
                    sourceName: sample.sourceRevision.source.name,
                    bundleID: sample.sourceRevision.source.bundleIdentifier,
                    deviceName: sample.device?.name,
                    deviceModel: sample.device?.model,
                    softwareVer: sample.device?.softwareVersion,
                    metadata: sample.metadata
                )
            }
            completion(points)
        }
        healthStore.execute(query)
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

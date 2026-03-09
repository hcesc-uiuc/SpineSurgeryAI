import Foundation
import HealthKit
import Combine

class HealthManager: ObservableObject {
    let healthStore = HKHealthStore()

    // Internal storage to keep UI fast
    private var internalData: [RawDataPoint] = []
    
    @Published var selectedDaysBack: Int = 1
    @Published var isProcessing: Bool = false
    
    // Automatically triggers console print when you tap the UI filter
    @Published var activeFilter: DataFilter = .all {
        didSet {
            printFilteredData()
        }
    }
    
    enum DataFilter: String, CaseIterable {
        case all = "All Data"
        case heartRate = "Heart Rate"
        case stepCount = "Steps"
    }

    struct RawDataPoint: Identifiable {
        let id: UUID
        let type: String
        let value: Double
        let unit: String
        let startDate: Date
        let endDate: Date
        let startUnix: Double
        let endUnix: Double
        let duration: TimeInterval
        let sourceName: String
        let bundleID: String
        let deviceName: String?
        let deviceModel: String?
        let softwareVer: String?
        let metadata: [String: Any]
    }

    init() {
        if HKHealthStore.isHealthDataAvailable() {
            requestPermissions()
        }
    }

    // MARK: - Permissions
    func requestPermissions() {
        let types: Set = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .stepCount)!
        ]
        
        healthStore.requestAuthorization(toShare: nil, read: types) { success, _ in
            if success {
                for type in types {
                    self.setupBackgroundObserver(for: type)
                }
            }
        }
    }

    private func setupBackgroundObserver(for type: HKQuantityType) {
        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
            self?.refreshWithNewRange(days: self?.selectedDaysBack ?? 1)
            completion()
        }
        healthStore.execute(query)
    }

    // MARK: - Orchestration
    func refreshWithNewRange(days: Int) {
        DispatchQueue.main.async {
            self.selectedDaysBack = days
            self.internalData = []
            self.isProcessing = true
        }
        
        let group = DispatchGroup()
        
        // --- DATA TYPE REGISTRY ---
        group.enter()
        fetchHeartRate(daysBack: days) { group.leave() }
        
        group.enter()
        fetchStepCount(daysBack: days) { group.leave() }
        // ---------------------------
        
        group.notify(queue: .main) {
            self.printFilteredData()
            self.isProcessing = false
        }
    }

    // MARK: - Specific Fetchers
    private func fetchHeartRate(daysBack: Int, completion: @escaping () -> Void) {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let unit = HKUnit.count().unitDivided(by: .minute())
        performQuery(for: type, unit: unit, label: "HEART_RATE", daysBack: daysBack, completion: completion)
    }

    private func fetchStepCount(daysBack: Int, completion: @escaping () -> Void) {
        let type = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let unit = HKUnit.count()
        performQuery(for: type, unit: unit, label: "STEP_COUNT", daysBack: daysBack, completion: completion)
    }

    // MARK: - Generic Query Engine
    private func performQuery(for type: HKQuantityType, unit: HKUnit, label: String, daysBack: Int, completion: @escaping () -> Void) {
        let startDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, _ in
            guard let samples = samples as? [HKQuantitySample] else {
                completion()
                return
            }
            
            let points = samples.map { sample in
                RawDataPoint(
                    id: sample.uuid,
                    type: label,
                    value: sample.quantity.doubleValue(for: unit),
                    unit: unit.unitString,
                    startDate: sample.startDate,
                    endDate: sample.endDate,
                    startUnix: sample.startDate.timeIntervalSince1970,
                    endUnix: sample.endDate.timeIntervalSince1970,
                    duration: sample.endDate.timeIntervalSince(sample.startDate),
                    sourceName: sample.sourceRevision.source.name,
                    bundleID: sample.sourceRevision.source.bundleIdentifier,
                    deviceName: sample.device?.name,
                    deviceModel: sample.device?.model,
                    softwareVer: sample.device?.softwareVersion,
                    metadata: sample.metadata ?? [:]
                )
            }
            
            self?.internalData.append(contentsOf: points)
            completion()
        }
        healthStore.execute(query)
    }

    // MARK: - Console Output
    private func printFilteredData() {
        let currentFilter = self.activeFilter
        let rawData = self.internalData
        
        guard !rawData.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let filteredData: [RawDataPoint]
            switch currentFilter {
            case .all: filteredData = rawData
            case .heartRate: filteredData = rawData.filter { $0.type == "HEART_RATE" }
            case .stepCount: filteredData = rawData.filter { $0.type == "STEP_COUNT" }
            }
            
            print("\n--- 🔍 CONSOLE DUMP [Filter: \(currentFilter.rawValue)] ---")
            
            for p in filteredData.sorted(by: { $0.startDate > $1.startDate }) {
                let dateStr = p.startDate.formatted(.dateTime.month().day().hour().minute().second())
                let meta = p.metadata.map { "\($0.key):\($0.value)" }.joined(separator: "|")
                
                print("[\(dateStr)] \(p.type) | \(String(format: "%.2f", p.value))\(p.unit) | START:\(Int(p.startUnix)) | END:\(Int(p.endUnix)) | DUR:\(Int(p.duration * 1000))ms | BID:\(p.bundleID) | META:{\(meta)}")
            }
            
            print("--- ✅ DONE (Count: \(filteredData.count)) ---\n")
        }
    }
}

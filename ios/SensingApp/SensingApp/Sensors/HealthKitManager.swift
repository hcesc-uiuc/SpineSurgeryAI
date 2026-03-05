import Foundation
import HealthKit
internal import Combine

class HealthKitManager: ObservableObject {
    let healthStore = HKHealthStore()

    @Published var trialData: [RawDataPoint] = []
    @Published var selectedDaysBack: Int = 1
    
    // These are the rows in the list view
    struct RawDataPoint: Identifiable {
        let id: UUID                // Permanent HealthKit UUID
        let type: String            // HR or Step Count
        let value: Double           // Numeric value
        let unit: String            // Unit string (BPM, count, etc)
        
        let startDate: Date         // Precise start
        let endDate: Date           // Precise end
        let startUnix: Double       
        let endUnix: Double
        let duration: TimeInterval  // Total sensor time
        
        let sourceName: String      // App/Source name
        let bundleID: String        // Bundle ID of the source
        let deviceName: String?     // e.g., "Apple Watch Ultra 2"
        let deviceModel: String?    // Hardware model (e.g., "Watch7,5")
        let softwareVer: String?    // OS Version
        
        let metadata: [String: Any] // Catch-all for extra clinical keys
    }

    init() {
        if HKHealthStore.isHealthDataAvailable() {
            requestPermissions()
        }
    }

    // Permission & Background Setup
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

    // Background Delivery
    private func setupBackgroundObserver(for type: HKQuantityType) {
        // Frequency .immediate is best for research (iOS usually wakes app every ~15 min)
        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { success, _ in }
        
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
            if error == nil {
                // When woken up, perform the deep fetch
                self?.fetchDeepData(for: type, daysBack: self?.selectedDaysBack ?? 1) {
                    completion() // Crucial: Tell iOS we are done so it can sleep
                }
            } else {
                completion()
            }
        }
        healthStore.execute(query)
    }

    // Anchored Object Query
    private func fetchDeepData(for type: HKQuantityType, daysBack: Int, completion: @escaping () -> Void) {
        print("Requesting: fetchDeepData for \(type.identifier)")
        
        // 1. If we are changing the time window, we need to clear current data and anchors
        // to force a fresh pull of the new range.
        let anchorKey = "Anchor_\(type.identifier)"
        
        // 2. Create the dynamic predicate based on the dropdown
        let startDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        
        // For a clean "Time Window" shift, we use a nil anchor to get everything in that range
        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: predicate,
            anchor: nil, // Set to nil to ensure we get the full window selected
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            
            guard let samples = samples as? [HKQuantitySample] else {
                completion()
                return
            }
            
            DispatchQueue.main.async {
                let newPoints = samples.map { sample in
                    let unit = (type.identifier == HKQuantityTypeIdentifier.heartRate.rawValue)
                        ? HKUnit.count().unitDivided(by: .minute())
                        : HKUnit.count()
                    
                    return RawDataPoint(
                        id: sample.uuid,
                        type: type.identifier == HKQuantityTypeIdentifier.heartRate.rawValue ? "HR" : "STEPS",
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
                
                // Filter out any duplicates and merge
                self?.trialData = newPoints.sorted { $0.startDate > $1.startDate }
                completion()
            }
        }
        healthStore.execute(query)
    }

    // Helper to trigger a fresh fetch from the UI
    func refreshWithNewRange(days: Int) {
        self.selectedDaysBack = days
        self.trialData = [] // Clear the list for the new range
        let types: Set = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .stepCount)!
        ]
        for type in types {
            fetchDeepData(for: type, daysBack: days) { }
        }
    }

    // Anchor Persistence Helpers
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

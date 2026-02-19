import Foundation
import HealthKit
import WatchConnectivity // <--- NEW: Import Connectivity
import Combine

class WatchWorkoutManager: NSObject, ObservableObject {
    let healthStore = HKHealthStore()
    var session: HKWorkoutSession?
    var builder: HKLiveWorkoutBuilder?
    
    // Live data published to your Watch screen
    @Published var heartRate: Double = 0
    @Published var active = false
    
    override init() {
        super.init()
        // 1. Activate the Connection Session
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }
    
    func startWorkout() {
        // ... (This logic remains the same as before)
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .mindAndBody
        configuration.locationType = .indoor
        
        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            builder = session?.associatedWorkoutBuilder()
            builder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session?.delegate = self
            builder?.delegate = self
            
            session?.startActivity(with: Date())
            builder?.beginCollection(withStart: Date()) { (success, error) in
                if success {
                    DispatchQueue.main.async { self.active = true }
                }
            }
        } catch {
            print("Failed to start workout: \(error)")
        }
    }
    
    func stopWorkout() {
        session?.end()
        builder?.endCollection(withEnd: Date()) { (success, error) in
            self.builder?.finishWorkout { (workout, error) in
                DispatchQueue.main.async { self.active = false }
            }
        }
    }
}

// MARK: - Delegate Methods
extension WatchWorkoutManager: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, WCSessionDelegate {
    
    // Required Stubs
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {}
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {} // Connectivity Stub
    
    // THE DATA STREAM
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        
        if collectedTypes.contains(heartRateType) {
            if let statistics = workoutBuilder.statistics(for: heartRateType) {
                let value = statistics.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) ?? 0
                
                // Update Watch UI
                DispatchQueue.main.async { self.heartRate = value }
                
                // SEND TO PHONE INSTANTLY
                if WCSession.default.isReachable {
                    // We wrap the data in a dictionary ["hr": 75]
                    WCSession.default.sendMessage(["hr": value], replyHandler: nil) { error in
                        print("Error sending data: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

import SwiftUI
import HealthKit

struct ContentView: View {
    @StateObject var manager = WatchWorkoutManager()
    
    var body: some View {
        VStack {
            Text(manager.active ? "Recording..." : "Ready")
                .foregroundColor(manager.active ? .green : .white)
            
            Text("\(Int(manager.heartRate)) BPM")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.red)
                .padding()
            
            if manager.active {
                Button("Stop Recording") {
                    manager.stopWorkout()
                }
                .tint(.red)
            } else {
                Button("Start Trial") {
                    manager.startWorkout()
                }
                .tint(.green)
            }
        }
        .onAppear {
            // Request permissions ON THE WATCH SEPARATELY
            let types: Set = [HKQuantityType.quantityType(forIdentifier: .heartRate)!]
            manager.healthStore.requestAuthorization(toShare: types, read: types) { _, _ in }
        }
    }
}

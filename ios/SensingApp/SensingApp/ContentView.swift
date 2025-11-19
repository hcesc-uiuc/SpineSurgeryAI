//
//  ContentView.swift
//  SensingTrialApp
//
//  Created by Mashfiqui Rabbi on 10/4/25.
//

import SwiftUI
import CoreMotion
internal import Combine
import BackgroundTasks
import ResearchKitSwiftUI

///
///
///
struct ContentView: View {
    @StateObject private var motionManager = MotionManager()
    @State var showDeniedAlert = false
    @Environment(\.scenePhase) var scenePhase
    let motionActivityManager = CMMotionActivityManager()
    //let recorder = CMSensorRecorder()
    
    
//    var survey: ResearchForm = ResearchForm(
//        id: "SurveyTask",
//        steps: {
//            ResearchFormStep(
//                title: "Demographics",
//                subtitle: "Tell us about yourself",
//                content: {
//                    TextQuestion(
//                        id: "textQuestion",
//                        title: "What is your name?",
//                        prompt: "Enter your name here",
//                        lineLimit: .singleLine,
//                        characterLimit: 0
//                    )
//                    .questionRequired(true)
//                }
//            )
//        },
//        onResearchFormCompletion: { completion in
//            switch completion {
//            case .completed(let results):
//                print(results)
//            case .discarded:
//                print("cancelled")
//            default:
//                print("cancelled")
//            }
//        }
//    )

    @State private var isPresented = false
    @Environment(\.dismiss) var dismiss
    var body: some View {
        
        
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            
            Text("\nAccelerometer")
            if let data = motionManager.accelerometerData {
                Text("x: \(data.acceleration.x, specifier: "%.4f")")
                Text("y: \(data.acceleration.y, specifier: "%.4f")")
                Text("z: \(data.acceleration.z, specifier: "%.4f")")
            } else {
                Text("No motion found").foregroundStyle(Color.red)
            }
            
            Text("\nGyroscope")
            if let gyroData = motionManager.gyroscopeData {
                Text("x: \(gyroData.rotationRate.x, specifier: "%.4f")")
                Text("y: \(gyroData.rotationRate.y, specifier: "%.4f")")
                Text("z: \(gyroData.rotationRate.z, specifier: "%.4f")")
            } else {
                Text("Gyro not found").foregroundStyle(Color.red)
            }
            Button("Fetch data"){
                Task{
                    await self.fetchRecordedData()
                }
            }.padding(.top, 30)
            Button("Print schedule bg task"){
                Task{
                    BackgroundScheduler.shared.printScheduledBackgroundTasks()
                }
            }.padding(.top, 30)
            Button("Upload File"){
                Task{
                    let filename = "accelerometer_2025-11-05_13-34-16.csv"
                    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let fileURL = dir.appendingPathComponent(filename)
                    Uploader.shared.uploadFile(fileURL: fileURL)
                }
            }.padding(.top, 30)
            Button("Print log data"){
                Task{
                    self.printCurrentLogFile()
                }
            }.padding(.top, 30)
            VStack {
                Button("Start Survey") {
                    isPresented = true
                }
                //https://swiftpackageindex.com/stanfordbdhg/researchkit/4.0.0-beta.2/documentation/researchkitswiftui
                //https://github.com/ResearchKit/ResearchKit/issues/1573
                .sheet(isPresented: $isPresented) {
                    ResearchForm(
                        id: "SurveyTask",
                        steps: {
                            ResearchFormStep(
                                title: "Demographics",
                                subtitle: "Tell us about yourself",
                                content: {
                                    TextQuestion(
                                        id: "Q1",
                                        title: "What is your name?",
                                        prompt: "Enter your name here",
                                        lineLimit: .singleLine,
                                        characterLimit: 0
                                    )
                                    .questionRequired(true)
                                }
                            )
                            ResearchFormStep(
                                title: "Yes or no question",
                                subtitle: "Tell us about yourself",
                                content: {
                                    MultipleChoiceQuestion(
                                        id: "Q2",
                                        title: "What is your name?",
                                        choices: [
                                            TextChoice(
                                                id: "Q21",
                                                choiceText: "Yes",
                                                value: 1
                                            ),
                                            TextChoice(
                                                id: "Q22",
                                                choiceText: "No",
                                                value: 0
                                            )
                                        ], choiceSelectionLimit: .single
                                    )
                                    .questionRequired(true)
                                }
                            )
                        },
                        onResearchFormCompletion: { completion in
                            switch completion {
                                case .completed(let results):
                                    let resultsAsText = results.compactMap { result in
                                        "\(result.identifier): \(getAnswerValue(answer: result.answer))"
                                    }
                                    print(resultsAsText)
                                    self.isPresented = false
                                case .discarded:
                                    print("cancelled")
                                default:
                                    print("cancelled")
                            }
                        }
                    )
                }
            }
            
        }
        .padding(50)
        .alert(isPresented: $showDeniedAlert) {
            //We are doing this, if the user denied access then we will
            //ask users to enable it.	
            Alert(
                title: Text("Motion Access Denied"),
                message: Text("Please go to Settings > Privacy & Security > " +
                              "Motion & Fitness to enable access for this app.")
            )
        }.onLoad {
            print("Calling onLoad")
            //After the application loads, we ask/check for permission.
            checkMotionAndFitnessAuthorization()
            //registerBackgroundTasks()
        }.onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                print("App moved to background")
                BackgroundScheduler.shared.scheduleAppRefresh()
                startBackgroundRecordingTask()
                Logger.shared.append("App moved to background")
                // Perform actions when the app enters the background
            } else if newPhase == .active {
                print("App moved to foreground")
                Logger.shared.append("App moved to foreground")
                // Perform actions when the app enters the foreground
            } else if newPhase == .inactive {
                print("App is inactive")
                Logger.shared.append("App moved to inactive")
                // Perform actions when the app becomes inactive (e.g., during a phone call)
            }
        }
        
        //
        // I can pretty much consider that I am here, view already loaded
        // There is not onViewLoad in swiftUI anymore
        // https://stackoverflow.com/questions/56496359/swiftui-view-viewdidload
        //
        //
        //        Button("Permit accelerometer\nbackground recording") {
        //            // This closure contains the code that executes when the button is tapped.
        //            requestMotionPermission()
        //            // You can perform any action here, such as updating state, navigating, etc.
        //        }
        //

    }
    
    func checkMotionAndFitnessAuthorization() {
        let status = CMMotionActivityManager.authorizationStatus()
        
        switch status {
            case .notDetermined:
                print("Motion & Fitness permission is not determined.")
                requestMotionPermission()
            case .authorized:
                print("Motion & Fitness permission is authorized. Started recording.")
                // Proceed with your motion-related tasks
                // startAccelerometerUpdates()
                //No need to start as we have already started it
                //startBackgroundRecordingTask()
            case .denied:
                print("Motion & Fitness permission is denied.")
                // Guide the user to re-enable in Settings
                showPermissionDeniedAlert()
            case .restricted:
                print("Motion & Fitness permission is restricted.")
            @unknown default:
                print("Unknown authorization status")
        }
    }
    
    
//================================================================================================================
//
//  Internal
//
//================================================================================================================
    
    func resultForStep<Result>(answerFormat: AnswerFormat) -> Result? {
        switch answerFormat {
        case let .text(answer):
            return answer as? Result
        case .numeric(let decimal):
            return decimal as? Result
        case .date(let date):
            return date as? Result
        case .height(let height):
            return height as? Result
        case .weight(let weight):
            return weight as? Result
        case .image(let image):
            return image as? Result
        case .multipleChoice(let multipleChoice):
            return multipleChoice as? Result
        case .scale(let double):
            return double as? Result
        default:
            return nil
        }
    }
    
    func getAnswerValue(answer: AnswerFormat) -> String{
        //see how the handle AnswerFormat
        //https://chatgpt.com/share/69165514-aa20-8008-b3ad-ed2372d08ef5
        switch answer {
            case .text(let value):
                return value ?? "nil"
            case .numeric(let value):
                return String(value ?? -1)
            case .multipleChoice(let values):
                //separate this out as a function
                if let vals = values {
                    var choices: [String] = []
                    for val in vals {
                        switch val {
                            case .int(let value):
                                choices.append(String(value))
                            case .string(let value):
                                choices.append(value)
                            case .date(let value):
                                choices.append(dateToString(value))
                            default:
                                return "nil"
                        }
                    }
                    return choices.joined(separator: ", ") // Access elements safely
                } else {
                    return "Multiple choice is nil."
                }
            case .scale(let value):
                return String(value ?? -1)
            case .date(let value):
                return dateToString(value ?? Date())
            default:
                return "nil"
            
            
//            case .image(let values):
//                print("Image answers:", values ?? [])
//            case .date(let value):
//                return String(value ?? Date())
//            case .weight(let value):
//                print("Weight answer:", value ?? 0)
//            case .height(let value):
//                print("Height answer:", value ?? 0)
                
        }
    }
    
    // Ask for motion authorization (needed for CMSensorRecorder)
    func requestMotionPermission() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionActivityManager.queryActivityStarting(from: Date(), to: Date(), to: .main) { _, error in
            // This call is just to trigger the permission dialog
            print("Motion permission requested.")
            DispatchQueue.main.async {
                let status = CMMotionActivityManager.authorizationStatus()
                switch status {
                case .authorized:
                    print("✅ Motion permission granted")
                    AcclerometerRecorder.shared.startRecording()
                    //completion(true)
                case .denied, .restricted:
                    print("❌ Motion permission denied/restricted")
                    //completion(false)
                case .notDetermined:
                    print("⏳ Motion permission not determined yet")
                    //completion(false)
                @unknown default:
                    print("Default")
                }
            }
        }
    }
    
    func startBackgroundRecordingTask() {
        if CMSensorRecorder.isAccelerometerRecordingAvailable() {
            // Record accelerometer data for 12 hours (max allowed)
            //Note we already registered at the SensingAppApp task.
            BackgroundScheduler.shared.scheduleBGProcessingTask()
            //print("Started accelerometer recording.")
        } else {
            print("Accelerometer recording not available on this device.")
        }
    }
    func showPermissionDeniedAlert() {
        showDeniedAlert = true
    }
    func fetchRecordedData() async {
        AcclerometerRecorder.shared.fetchRecordedData1Min()
    }
    
    func printCurrentLogFile(){
        print("Current log file:", Logger.shared.currentLogFilePath())
        if let logs = Logger.shared.readAll() {
            print(logs)
        }
    }
    
    func dateToString(_ date: Date?, format: String = "yyyy-MM-dd HH:mm:ss") -> String {
        guard let date = date else {
            return "Invalid Date"
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = .current       // user’s current timezone
        formatter.locale = .current         // user’s locale (e.g., 12/24h preference)
        return formatter.string(from: date)
    }
    
    

    
    
}

#Preview {
    ContentView()
}




///
/// This observable is for showing data in the UI
///
class MotionManager: ObservableObject {
    
    private let motion = CMMotionManager() // Core motion manager instance
    @Published var accelerometerData: CMAccelerometerData? // Published data for SwiftUI updates
    @Published var gyroscopeData: CMGyroData? // Published gyroscope data for SwiftUI updates
    
    init() {
        startAcceleromoterUpdates() // Start accelerometer updates
        startGyroscopeUpdates() // Start gyroscope updates
    }

    // Function to start accelerometer updates
    func startAcceleromoterUpdates() {
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.1 // Updates every 0.1 seconds
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                if let data = data {
                    self?.accelerometerData = data // Update accelerometer data
                }
            }
        }
    }

    // Function to start gyroscope updates
    func startGyroscopeUpdates() {
        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = 0.1 // Updates every 0.1 seconds
            motion.startGyroUpdates(to: .main) { [weak self] data, error in
                if let data = data {
                    self?.gyroscopeData = data // Update gyroscope data
                }
            }
        }
    }
}

struct ViewDidLoadModifier: ViewModifier {
    @State private var didLoad = false
    private let action: (() -> Void)?

    init(perform action: (() -> Void)? = nil) {
        self.action = action
    }
    func body(content: Content) -> some View {
        content.onAppear {
            if didLoad == false {
                didLoad = true
                action?()
            }
        }
    }
}

extension View {
    func onLoad(perform action: (() -> Void)? = nil) -> some View {
        modifier(ViewDidLoadModifier(perform: action))
    }
}

extension CMSensorDataList: @retroactive Sequence {
    public typealias Iterator = NSFastEnumerationIterator
    public func makeIterator() -> NSFastEnumerationIterator {
        return NSFastEnumerationIterator(self)
    }
}



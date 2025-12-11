//
//  ContentView.swift
//

import SwiftUI
import CoreMotion

struct ContentView: View {

    @StateObject private var motionManager = MotionManager()
    @StateObject private var appState = AppState()
    @State private var isSurveyPresented = false
    @State private var showDeniedAlert = false

    @Environment(\.scenePhase) var scenePhase
    let motionActivityManager = CMMotionActivityManager()

    var body: some View {

        VStack {
            Text("Motion Dashboard")
                .font(.title2)
                .padding()

            accelerometerView
            gyroscopeView

            Button("Fetch Recorded Data") {
                Task { await fetchRecordedData() }
            }
            .padding(.top, 20)

            Button("Start Survey") {
                isSurveyPresented = true
            }
            .disabled(appState.isCompletedToday)
            .sheet(isPresented: $isSurveyPresented) {
                SurgerySurveyView(appState: appState)
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
            Button("Upload All Files"){
                Task{
                    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    Uploader.shared.uploadFolder()
                }
            }.padding(.top, 30)
            Button("Print log data"){
                Task{
                    self.printCurrentLogFile()
                }
            }.padding(.top, 30)
        }
        .padding()
        .alert("Motion Access Denied",
               isPresented: $showDeniedAlert,
               actions: {},
               message: { Text("Enable Motion & Fitness in Settings.") }
        )
        .onLoad {
            checkMotionAndFitnessAuthorization()
        }.onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                print("App moved to background")
                BackgroundScheduler.shared.scheduleAppRefresh()
                BackgroundScheduler.shared.scheduleBGProcessingTask()
                //startBackgroundRecordingTask()
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
    }

    private var accelerometerView: some View {
        VStack {
            Text("Accelerometer")
            if let d = motionManager.accelerometerData {
                Text("x: \(d.acceleration.x)")
                Text("y: \(d.acceleration.y)")
                Text("z: \(d.acceleration.z)")
            } else {
                Text("No motion").foregroundColor(.red)
            }
        }
        .padding(.top)
    }

    private var gyroscopeView: some View {
        VStack {
            Text("Gyroscope")
            if let g = motionManager.gyroscopeData {
                Text("x: \(g.rotationRate.x)")
                Text("y: \(g.rotationRate.y)")
                Text("z: \(g.rotationRate.z)")
            } else {
                Text("No gyro").foregroundColor(.red)
            }
        }
        .padding(.top)
    }

    private func fetchRecordedData() async {
        AcclerometerRecorder.shared.fetchRecordedData1Min()
    }

    ///
    /// We check the authorization status.
    /// If the authorization request does not exist, then we will request authorization
    /// If the persmission denied, show the alert
    /// We are not starting the background task why, if authorized??
    ///
    private func checkMotionAndFitnessAuthorization() {
        let status = CMMotionActivityManager.authorizationStatus()
        
        switch status {
            case .notDetermined:
                print("Motion & Fitness permission is not determined.")
                requestMotionPermission()
            case .authorized:
                print("Motion & Fitness permission is authorized. Started recording.")
                //reset the clock for the last 12 hours.
                //recording doesn't automatically start when we schedule the background tasks.
                AcclerometerRecorder.shared.startRecording()
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
    
    ///
    /// Requests the authorization. If the authorization is provided then we start recording?? Why not adding the background task??
    ///
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
                    AcclerometerRecorder.shared.startRecording() //
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
    
    func showPermissionDeniedAlert() {
        showDeniedAlert = true
    }
    
    //============================
    // Internal
    //============================
    func printCurrentLogFile(){
        print("Current log file:", Logger.shared.currentLogFilePath())
        if let logs = Logger.shared.readAll() {
            print(logs)
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
    
}


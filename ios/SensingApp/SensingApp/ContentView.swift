//
//  ContentView.swift
//

import SwiftUI
import CoreMotion
import CoreLocation

struct ContentView: View {

    @StateObject private var motionManager = MotionManager()
    @StateObject private var appState = AppState()
    @State private var isSurveyPresented = false
    @State private var showDeniedAlert = false
    @State private var showSettingsAlert = false
    @StateObject var HKManager = HealthKitManager()
    
    @Environment(\.scenePhase) var scenePhase
    let motionActivityManager = CMMotionActivityManager()
    var body: some View {
        TabView {
            // Tab 1
            MainView
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            // Tab 2
            SensorView
                .tabItem {
                    Label("Sensors", systemImage: "waveform")
                }

            // Tab 3
            DebugView
                .tabItem {
                    Label("Debug", systemImage: "ant.fill")
                }
        }
    }
    
    private var SensorView: some View {
        VStack {
            Text("Sensor view")
                .font(.title2)
                .padding()
            
            accelerometerView
            gyroscopeView
        }
    }


    private var DebugView: some View {
        Text("Debug Screen")
    }

    
    private var MainView: some View {

        VStack {
            Text("Journey app")
                .font(.title2)
                .padding()

            

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
                    print("Upload function called")
                    //let filename = "accelerometer_2025-11-05_13-34-16.csv"
                    let filename = "log_2026-02-19.txt"
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
            Button("Get HealthKit data"){
                Task{
                    self.getHealthKitData()
                }
            }.padding(.top, 30)
            if CLLocationManager().authorizationStatus  != .authorizedAlways {
                Button("Always allow location"){
                    Task{
                        showSettingsAlert = true
                    }
                }.padding(.top, 30)
            }
            if CLLocationManager().authorizationStatus  == .authorizedAlways {
                Text("Always allow location granted")
                .padding(.top, 30)
            }
        }
        .padding()
        .alert("Motion Access Denied",
               isPresented: $showDeniedAlert,
               actions: {},
               message: { Text("Enable Motion & Fitness in Settings.") }
        )
        .alert("Location Access Required", isPresented: $showSettingsAlert) {

            // YES — deep link directly to this app's page in Settings.
            // The user can change location permission to Always Allow from there.
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }

            // NO — dismiss the alert and stay in the app.
            // showSettingsAlert resets to false automatically when any button is tapped.
            Button("Not Now", role: .cancel) { }

        } message: {
            Text("Please open Settings and set location access to Always Allow so we can track your location in the background.")
        }
        .onLoad {
            //called when loaded
            checkMotionAndFitnessAuthorization()
            checkLocationAuthorization()
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
    
    private func getHealthKitData() {
        print("Requesting: HKManager.refreshWithNewRange")
        HKManager.refreshWithNewRange(days: 7)
        print("Requesting: HKManager.trialData. Len:\(HKManager.trialData.count)")
        for (index, point) in HKManager.trialData.enumerated(){
            let hkDataPointString = formatRawString(
                point,
                unixStartStr: String(Int(point.startDate.timeIntervalSince1970)),
                unixEndStr: String(Int(point.endDate.timeIntervalSince1970))
            )
            print("\(index) - \(hkDataPointString)")
        }
    }
    
    func formatRawString(_ p: HealthKitManager.RawDataPoint, unixStartStr: String, unixEndStr: String) -> String {
        let dateStr = p.startDate.formatted(.dateTime.month().day().hour().minute().second())
        let metaStr = p.metadata.map { "\($0.key):\($0.value)" }.joined(separator: "|")
        
        return "[\(dateStr)] TYPE:\(p.type) | VAL:\(p.value)\(p.unit) | UNIX_START:\(unixStartStr) | UNIX_END:\(unixEndStr) | DUR:\(Float(unixEndStr)!-Float(unixStartStr)!)ms | SRC:\(p.sourceName) | BID:\(p.bundleID) | DEV:\(p.deviceName ?? "NA") | MOD:\(p.deviceModel ?? "NA") | SW:\(p.softwareVer ?? "NA") | ID:\(p.id.uuidString) | META:{\(metaStr)}"
    }

    private var accelerometerView: some View {
        SensorCard(
            title: "Accelerometer",
            systemImage: "arrow.up.and.down.and.arrow.left.and.right"
        ) {
            if let d = motionManager.accelerometerData {
                valueRow("X", d.acceleration.x)
                valueRow("Y", d.acceleration.y)
                valueRow("Z", d.acceleration.z)
            } else {
                statusText("No motion detected", color: .illiniOrange)
            }
        }
    }

    
    private var gyroscopeView: some View {
        SensorCard(
            title: "Gyroscope",
            systemImage: "gyroscope"
        ) {
            if let g = motionManager.gyroscopeData {
                valueRow("X", g.rotationRate.x)
                valueRow("Y", g.rotationRate.y)
                valueRow("Z", g.rotationRate.z)
            } else {
                statusText("No gyro detected", color: .illiniOrange)
            }
        }
    }
    
    private func valueRow(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
                .fontWeight(.semibold)
                .foregroundColor(.illiniBlue)
            Spacer()
            Text(String(format: "%.3f", value))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }
    
    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(color)
    }
    

    private func fetchRecordedData() async {
        AcclerometerRecorder.shared.fetchRecordedData1Min()
    }
    
    
    private func checkLocationAuthorization(){
        let status = CLLocationManager().authorizationStatus
        
        if status == .denied ||
            status == .restricted {
            //SettingsLinkButton()
            showSettingsAlert = true
        }
        
        if status == .authorizedWhenInUse {
            //SettingsLinkButton()
            showSettingsAlert = true
        }

        // Show the request button only when not yet determined
        if status == .notDetermined {
            //            Button("Enable Location Tracking") {
            //                locationManager.requestPermission()
            //            }
            //            .buttonStyle(.borderedProminent)
            AdaptiveLocationManager.shared.requestPermission()
        }
        
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


//
//  DebugTabView.swift
//  SensingApp
//
//  Debug tab (DEBUG-only). Extracted from MainAppView.swift (was the DebugView property + its helpers).
//

import SwiftUI
import CoreMotion
import CoreLocation
import HealthKit

struct DebugTabView: View {

    var onLogout: () -> Void

    @State private var showDeniedAlert   = false
    @State private var showSettingsAlert = false
    @State private var showImportData    = false
    @StateObject var HKManager = HealthKitManager()
    @Environment(\.scenePhase) var scenePhase
    let motionActivityManager = CMMotionActivityManager()

    var body: some View {
        VStack {
            Text("Journey app")
                .font(.title2)
                .padding()
            
            // Load sensor values from a CSV instead of editing them in code.
            Button("Imported Data…") {
                showImportData = true
            }
            .padding(.top, 10)
            .sheet(isPresented: $showImportData) {
                ImportDataView()
            }

            Button("Ask for sensorkit permissions") {
                let sk = SensorKitManager()
                sk.askForAuthorization()
            }
            .padding(.top, 10)

            //            Button("Fetch Recorded Data") {
            //                Task { await fetchRecordedData() }
            //            }
            //            .padding(.top, 10)
            
            //            Button("Start Survey") {
            //                isSurveyPresented = true
            //            }
            //            .disabled(appState.isCompletedToday)
            //            .sheet(isPresented: $isSurveyPresented) {
            //                SurgerySurveyView(appState: appState, authManager: authManager)
            //            }
            
            //            Button("Fetch data") {
            //                Task { await self.fetchRecordedData() }
            //            }.padding(.top, 30)
            
            Button("Store Sensorkit Data") {
                Task {
                    print("SensorKit fetcher is called")
                    SensorKitAccelerometerFetcher.shared.fetchLatestData()
                    SensorKitGyroscopeFetcher.shared.fetchLatestData()
                }
            }.padding(.top, 20)
            
            Button("Insert 1hr Accel to sqlite/csv") {
                AcclerometerRecorder.shared.simulateAccelerometerDataStroage()
            }.padding(.top, 20)
            
            Button("Insert into SQLite db") {
                Task {
                    //Task will happen asynchronously
                    let N = 50
                    for i in 0..<N {
                        
                        let unixTime = Date().timeIntervalSince1970 * 1000
                        
                        // random size of 2-4 with random content
                        let size  = Int.random(in: 2...4)
                        let bytes = (0..<size).map { _ in UInt8.random(in: 0...255) }
                        
                        //database writes
                        SQLiteSaver.shared.addRow(
                            timestamp: unixTime,
                            dataType: DataType.dummy,
                            blob: bytes,
                            counter: i
                        )
                    }
                    
                    // For the demo we are forcing a new file.
                    // This does not work as the consumer is thread.
                    // This is called before consumer finishes processing,
                    // unless we wait 2 seconds.
                    //
                    // DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    //     SQLiteSaver.shared.flushDataToDb(forceNewFile: true)
                    // }
                }
            }.padding(.top, 20)
            Button("Flush and create new file") {
                Task {
                    SQLiteSaver.shared.flushDataToDb(forceNewFile: true)
                }
            }.padding(.top, 10)
            
            Button("Print schedule bg task") {
                Task { BackgroundScheduler.shared.printScheduledBackgroundTasks() }
            }.padding(.top, 20)
            
            Button("Upload All Files") {
                Task {
                    await Uploader.shared.uploadFolder()
                }
            }.padding(.top, 20)
            
            Button("Print log data") {
                Task { self.printCurrentLogFile() }
            }.padding(.top, 20)
            
            Button("Get HealthKit data") {
                Task {
                    HealthkitRecorder.shared.getHealthKitData()
                }
            }.padding(.top, 20)
            
            if CLLocationManager().authorizationStatus != .authorizedAlways {
                Button("Always allow location") {
                    Task { showSettingsAlert = true }
                }.padding(.top, 10)
            }
            
            if CLLocationManager().authorizationStatus == .authorizedAlways {
                Text("Always allow location granted")
                    .padding(.top, 10)
            }
            
            Button("Log Out") {
                onLogout()
            }.padding(.top, 20)
        }
        .padding()
        .alert("Motion Access Denied",
               isPresented: $showDeniedAlert,
               actions: {},
               message: { Text("Enable Motion & Fitness in Settings.") }
        )
        .alert("Location Access Required", isPresented: $showSettingsAlert) {
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("Please open Settings and set location access to Always Allow so we can track your location in the background.")
        }
        .onLoad {
            checkMotionAndFitnessAuthorization()
            checkLocationAuthorization()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                print("App moved to background")
                BackgroundScheduler.shared.scheduleAppRefresh()
                BackgroundScheduler.shared.scheduleBGProcessingTask()
                Logger.shared.append("App moved to background")
            } else if newPhase == .active {
                print("App moved to foreground")
                Logger.shared.append("App moved to foreground")
            } else if newPhase == .inactive {
                print("App is inactive")
                Logger.shared.append("App moved to inactive")
            }
        }
    }
    // ============================================================
    // MARK: - HealthKit
    // ============================================================

    private func getHealthKitData() {
        let daysRequested = 1
        //let metricsRequested: Set<SupportedMetric> = [.steps] // Empty = All
        let metricsRequested: Set<SupportedMetric> = [] // Empty = All
        
        print("Requesting \(daysRequested)-day historical refresh...")
        
        HKManager.refreshWithNewRange(days: 1, types:metricsRequested) { data in
            
            print("Success! Data received. Len: \(data.count), Days:\(daysRequested), Types:\(metricsRequested)")
                
                //here I need to open a file
                //This will create a file for the current day
                
                let hkDataLogger = HKDataLogger()
                let isFileOpenSuccesful = hkDataLogger.open()
                if isFileOpenSuccesful == true {
                    for (index, point) in data.enumerated() {
                        let hkDataPointString = formatRawString(
                            point,
                            unixStartStr: String(Int(point.startDate.timeIntervalSince1970)),
                            unixEndStr: String(Int(point.endDate.timeIntervalSince1970))
                        )
                        print("\(index) - \(hkDataPointString)")
                        print("")
                        
                        hkDataLogger.writeLine(hkDataPointString)
                    }
                    hkDataLogger.close()
                }
            
                    //close a file here
            
            }
        }
    
    func formatRawString(_ p: HealthKitManager.RawDataPoint, unixStartStr: String, unixEndStr: String) -> String {
        let dateStr      = p.startDate.formatted(.dateTime.month().day().hour().minute().second())
        let displayValue = p.value ?? 0.0
        let metaStr: String = {
            guard let md = p.metadata else { return "" }
            return md.map { key, value in
                "\(String(describing: key)):\(String(describing: value))"
            }
            .sorted()
            .joined(separator: "|")
        }()
        let durationMs = Int(p.duration * 1000)
        return "[\(dateStr)] |ID:\(p.id.uuidString)| TYPE:\(p.type) | VAL:\(displayValue) \(p.unit) | UNIX_START:\(unixStartStr) | UNIX_END:\(unixEndStr) | DUR:\(durationMs)ms | SRC:\(p.sourceName) | BID:\(p.bundleID) | DEV:\(p.deviceName ?? "NA") | MOD:\(p.deviceModel ?? "NA") | SW:\(p.softwareVer ?? "NA") | ID:\(p.id.uuidString) | META:{\(metaStr)}"
    }

    // ============================================================
    // MARK: - Helpers (preserved from GitHub)
    // ============================================================

    private func fetchRecordedData() async {
        AcclerometerRecorder.shared.fetchRecordedData1Min()
    }

    private func checkLocationAuthorization() {
        let status = CLLocationManager().authorizationStatus
        if status == .denied || status == .restricted {
            showSettingsAlert = true
        }
        if status == .authorizedWhenInUse {
            showSettingsAlert = true
        }
        if status == .notDetermined {
            AdaptiveLocationManager.shared.requestPermission()
        }
    }

    private func checkMotionAndFitnessAuthorization() {
        let status = CMMotionActivityManager.authorizationStatus()
        switch status {
        case .notDetermined:
            print("Motion & Fitness permission is not determined.")
            requestMotionPermission()
        case .authorized:
            print("Motion & Fitness permission is authorized. Started recording.")
            AcclerometerRecorder.shared.startRecording()
        case .denied:
            print("Motion & Fitness permission is denied.")
            showPermissionDeniedAlert()
        case .restricted:
            print("Motion & Fitness permission is restricted.")
        @unknown default:
            print("Unknown authorization status")
        }
    }

    func requestMotionPermission() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionActivityManager.queryActivityStarting(from: Date(), to: Date(), to: .main) { _, _ in
            print("Motion permission requested.")
            DispatchQueue.main.async {
                let status = CMMotionActivityManager.authorizationStatus()
                switch status {
                case .authorized:
                    print("Motion permission granted")
                    AcclerometerRecorder.shared.startRecording()
                case .denied, .restricted:
                    print("Motion permission denied/restricted")
                case .notDetermined:
                    print("Motion permission not determined yet")
                @unknown default:
                    print("Default")
                }
            }
        }
    }

    func showPermissionDeniedAlert() {
        showDeniedAlert = true
    }

    func printCurrentLogFile() {
        print("Current log file:", Logger.shared.currentLogFilePath())
        if let logs = Logger.shared.readAll() {
            print(logs)
        }
    }

    func startBackgroundRecordingTask() {
        if CMSensorRecorder.isAccelerometerRecordingAvailable() {
            BackgroundScheduler.shared.scheduleBGProcessingTask()
        } else {
            print("Accelerometer recording not available on this device.")
        }
    }
}

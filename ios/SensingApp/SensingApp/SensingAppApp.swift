//
//  SensingAppApp.swift
//  SensingApp
//

import SwiftUI
import CoreData
import BackgroundTasks
import UserNotifications
import FirebaseCore

@main
struct SensingAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    
    // This call starts location tracking after checking
    // authorization
    //
    //    App launches
    //      └─ SensingAppApp body evaluated
    //           └─ @StateObject var locationManager = AdaptiveLocationManager.shared
    //                └─ AdaptiveLocationManager.init()
    //                     └─ locationManager.delegate = self
    //                          └─ iOS calls locationManagerDidChangeAuthorization(_:)  ← automatic
    //                               ├─ .authorizedAlways   → startTracking()
    //                               ├─ .authorizedWhenInUse → startTracking()
    //                               ├─ .denied             → stopTracking()
    //                               └─ .notDetermined      → (wait for user)
    @StateObject private var locationManager = AdaptiveLocationManager.shared
    // @StateObject private var sensorKitManager = SensorKitManager()
    
    // Makes Authorization Pathway consistent for all data files/types
    @StateObject private var authManager = SecureAuthManager()
    
    init(){
        print("SensingApp init called")

        Logger.shared.append("")
        Logger.shared.append("=======================================================")
        Logger.shared.append("SensingApp init called")

        // Notification and SensorKit auth are requested by PermissionsFlowView.
        // Starting them here fires the iOS dialog before the onboarding cards appear.
        // SurveyNotificationManager.shared.requestPermission()
        // SensorKitAccelerometerFetcher.shared.startRecordingWithAuthorizationCheck()
        
        //        BackgroundScheduler.shared.registerBackgroundTasks()
        //        BackgroundScheduler.shared.scheduleBGProcessingTask()
        //
        //        BackgroundScheduler.shared.registerBackgroundAppRefreshTask()
        //        BackgroundScheduler.shared.scheduleAppRefresh()
        
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(locationManager)
                .environmentObject(authManager)
                .onAppear {
                    SurveyUploader.shared.configure(authManager: authManager)  // ← ADD THIS
                    SurveyNotificationManager.shared
                        .scheduleDailyReminder(
                            hour: 20,
                            minute: 0,
                            appState: appState
                        )
                }
        }
        // Using @StateObject instead of passing LocationManager.shared directly
        // into .environmentObject() ensures SwiftUI owns the lifecycle and
        // the singleton is initialised immediately when the app starts.
        
    }
}


class AppDelegate: NSObject, UIApplicationDelegate {
    /*
     This function is executed every time when we launch the app for the first
     or by "geo-fence" trick.
     
     The launch sequence from a killed state (by iOS) using geo-fence are the following:
     1. application(_:willFinishLaunchingWithOptions:) — if implemented in App​Delegate
     2. application(_:didFinishLaunchingWithOptions:) — we access AdaptiveLocationManager.shared
        unconditionally, which forces the singleton init() to run now (before scene connects).
     3. AdaptiveLocationManager.init() sets location​Manager​.delegate = self,
        causing iOS to immediately call...
     4. locationManagerDidChangeAuthorization — which calls start​Tracking() if already authorized
     5. didExitRegion — fires on the delegate
     Note: UIApplication.LaunchOptionsKey.location (previously used to detect location-triggered
     relaunches) is deprecated in iOS 26. The CLLocationManagerDelegate approach above is the
     Apple-recommended replacement and covers all launch types including background relaunches.

     Note on BFU (before first unlock)
     - After a phone restart, the geo-fence stays activated
       However, until the phone is unlocked by the user,
       the geo-fence is not delivered even if the user changes
       location under BFU. However, after phone lock, the
       geo-fence change is delivered. The only caveat is when
       the geo-fence exit happens, we lose that exact timestamp.
     
     Known bug:
     - Spine surgery patients may not move outside of home
       so if they do not leave the house, the geo-fence is never
       triggered after a restart.
     - We need to create a pulse from the app.
        - Either from silent notification
        - Or when a background task is triggered
        - Or when healthkit background delivery is triggered.
     
     */
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("App launched")
        
        

        // Detect geofence-triggered relaunch for logging purposes.
        // UIApplication.LaunchOptionsKey.location is deprecated in iOS 26 but there
        // is no direct replacement for detecting this at didFinishLaunching time.
        if launchOptions?[.location] != nil {
            print("Relaunched by geofence/location event")
            Logger.shared.append("Relaunched by geofence/location event")

            // Force AdaptiveLocationManager to initialize now, before the SwiftUI scene
            // connects. This is critical for geofence-triggered background relaunches:
            // setting delegate = self in init() causes iOS to call
            // locationManagerDidChangeAuthorization immediately, which calls startTracking()
            // if already authorized — well before the scene or any @StateObject exists.
            //
            // This call ensure after geo-fence relaunch that tracking starts.
            // with check if authorization exists
            //
            _ = AdaptiveLocationManager.shared

        } else {
            Logger.shared.append("didFinishLaunchingWithOptions — normal launch")
        }

        if let folderURL = createFolder(named: "logs") {
            print("Ready to use: \(folderURL)")
        }
        if let folderURL = createFolder(named: "to-be-processed") {
            print("Ready to use: \(folderURL)")
        }
        if let folderURL = createFolder(named: "processed") {
            print("Ready to use: \(folderURL)")
        }
        
        //forcing sqlite files to initialize
        //        _ = SQLiteSaver.shared
        
        // Use the Firebase library to configure APIs.
        FirebaseApp.configure()
        
        //Force sqlite saver allocation.
        //This one handles all the sensor data saving and threading
        SQLiteSaver.shared.configure(capacity: 10000, flushAfterThisCount: 3000)        
        _ = SQLiteSaver.shared   // now fully configured, consumer started
        
        //This will start recording the sensor data if
        //authorization is already available
        #if !targetEnvironment(simulator)
        // Issue #83: sensors still undecided are asked for by the SensorKit
        // permission card (PermissionAudit), not with a bare sheet at launch.
        SensorKitRegistry.startAllRecording(checkAuthorization: true)
        #endif
        
        registerForPushNotifications()
        // Start background location updates immediately
        // LocationManager.shared.start()
        // registering does not start the background process right away.
        BackgroundScheduler.shared.registerBackgroundTasks()
        BackgroundScheduler.shared.registerUploadBGTask()
        BackgroundScheduler.shared.registerBackgroundAppRefreshTask()
        BackgroundScheduler.shared.registerBackgroundSensorkitFetchTask()
        BackgroundScheduler.shared.registerHealthBackgroundTask()
        return true
    }

    func registerForPushNotifications() {
        // requestAuthorization is called by PermissionsFlowView's notification card.
        // Here we only register for silent/remote push so the device token is issued.
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenParts = deviceToken.map { String(format: "%02.2hhx", $0) }
        let token = tokenParts.joined()
        print("Device Token: \(token)")

        Task { @MainActor in
            let responseText = await UploadToServer.shared.uploadDeviceTokenToServer(deviceToken: token)
            print("responseText \(responseText)")
            Logger.shared.append("APNS registration successful")
            Logger.shared.append("Device Token: \(token)")
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("Failed to register: \(error.localizedDescription)")
    }
    
    
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("Received notification: \(userInfo)")

        if let data = userInfo["data"] as? [String: Any] {
            print("Silent notification received:", data)
            Logger.shared.append("Silent notification received")
            Logger.shared.append("Battery: " + Logger.shared.getBatteryStatus())
        }

        BackgroundScheduler.shared.printScheduledBackgroundTasks()
        //ToDo: Why scheduling only AppRefreshTask
        //Note all schedule background and app refresh does not
        //reschedule if there is an older one scheduled at a later time
        //so calling it multiple times does not affect anything
        BackgroundScheduler.shared.scheduleAppRefresh()
        BackgroundScheduler.shared.scheduleUploadBGTask()
        BackgroundScheduler.shared.scheduleBGProcessingTask()
        BackgroundScheduler.shared.scheduleBackgroundSensorkitFetch()
        BackgroundScheduler.shared.scheduleHealthResearchBGProcessingTask()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        print("App moved to background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        print("App returning to foreground")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        print("App is about to terminate")
    }

    func createFolder(
        named folderName: String,
        in directory: FileManager.SearchPathDirectory = .documentDirectory
    ) -> URL? {
        let fileManager = FileManager.default
        guard let baseURL = fileManager.urls(for: directory, in: .userDomainMask).first else {
            return nil
        }

        let folderURL = baseURL.appendingPathComponent(folderName)

        if !fileManager.fileExists(atPath: folderURL.path) {
            do {
                try fileManager.createDirectory(
                    at: folderURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                print("Folder created: \(folderURL.path)")
            } catch {
                print("Error creating folder: \(error)")
                return nil
            }
        }
        return folderURL
    }
}

extension Color {
    static let illiniBlue = Color(red: 0.07, green: 0.16, blue: 0.29)
    static let illiniOrange = Color(red: 0.91, green: 0.33, blue: 0.10)
}


//
//  SensingAppApp.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 10/16/25.
//

import SwiftUI
import CoreData
import BackgroundTasks
import Firebase

@main
struct SensingAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    //Singletons are lazily created so, we are forcing the location to trigger
    @StateObject private var locationManager = AdaptiveLocationManager.shared
    
    init(){
        print("SensingApp init called")
        
        Logger.shared.append("")
        Logger.shared.append("=======================================================")
        Logger.shared.append("SensingApp init called")
        
        SurveyNotificationManager.shared.requestPermission()
        
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
                .onAppear {
                    SurveyNotificationManager.shared
                        .scheduleDailyReminder(
                            hour: 20,
                            minute: 0,
                            appState: appState
                        )
                }
            // Using @StateObject instead of passing LocationManager.shared directly
            // into .environmentObject() ensures SwiftUI owns the lifecycle and
            // the singleton is initialised immediately when the app starts.
            
        }
    }
}



class AppDelegate: NSObject, UIApplicationDelegate {
    
    ///
    /// What does Application functions do?
    ///
    /// The system calls specific application(_:didSomething:) functions on your AppDelegate at key moments.
    /// Each one handles a particular system event.
    ///
    
    
    // Called when app launches
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        print("App launched")
        
        //create necessary folders
        // Usage
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
        _ = SQLiteSaver.shared
        
        // Use the Firebase library to configure APIs.
        FirebaseApp.configure()
        
        registerForPushNotifications()
        // Start background location updates immediately
        // LocationManager.shared.start()
        BackgroundScheduler.shared.registerBackgroundTasks()
        BackgroundScheduler.shared.registerBackgroundAppRefreshTask()
        return true
    }
    
    /// Request notification permission and register with APNs
    func registerForPushNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("Permission granted: \(granted)")
            
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
    
    /// Called when APNs registration succeeds — this gives you the DEVICE TOKEN
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data)  {
        let tokenParts = deviceToken.map { String(format: "%02.2hhx", $0) }
        let token = tokenParts.joined()
        print("✅ Device Token: \(token)")
        Task { @MainActor in
            let responseText = await UploadToServer.shared.uploadDeviceTokenToServer(deviceToken: token)
            print("responseText \(responseText)")
            Logger.shared.append("APNS registration successful")
            Logger.shared.append("Device Token: \(token)")
        }
    }
    

    /// Called if APNs registration fails
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register: \(error.localizedDescription)")
    }
    
    
    func application(_ application: UIApplication,
                         didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("Received notification: \(userInfo)")
        
        // Extract custom data from the silent notification
        if let data = userInfo["data"] as? [String: Any] {
            print("Silent notification received:", data)
            Logger.shared.append("Silent notification received")
            Logger.shared.append("Battery: " + Logger.shared.getBatteryStatus())
        }
        
        BackgroundScheduler.shared.printScheduledBackgroundTasks()
        BackgroundScheduler.shared.scheduleAppRefresh() //ToDo: Why scheduling only AppRefreshTask
    }
    
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("App moved to background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        print("App returning to foreground")
    }
    
    /// Application is about to terminate
    func applicationWillTerminate(_ application: UIApplication) {
        print("App is about to terminate")
    }
    
    
    func createFolder(named folderName: String, in directory: FileManager.SearchPathDirectory = .documentDirectory) -> URL? {
        let fileManager = FileManager.default
        guard let baseURL = fileManager.urls(for: directory, in: .userDomainMask).first else { return nil }
        
        let folderURL = baseURL.appendingPathComponent(folderName)
        
        if !fileManager.fileExists(atPath: folderURL.path) {
            do {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
                print("Folder created: \(folderURL.path)")
            } catch {
                print("Error creating folder: \(error)")
                return nil
            }
        }
        
        return folderURL
    }
}



//
// MARK: - UIUC Brand Colors
//
extension Color {
    static let illiniBlue   = Color(red: 0.07, green: 0.16, blue: 0.29)
    static let illiniOrange = Color(red: 0.91, green: 0.33, blue: 0.10)
}

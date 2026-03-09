//
//  SensingAppApp.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 10/16/25.
//

import SwiftUI
import CoreData
import BackgroundTasks


@main
struct SensingAppApp: App {

    @StateObject private var appState = AppState()

    init() {
        NotificationManager.shared.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    NotificationManager.shared
                        .scheduleDailyReminder(
                            hour: 20,
                            minute: 0,
                            appState: appState
                        )
                }
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
        }
        
        BackgroundScheduler.shared.printScheduledBackgroundTasks()
        BackgroundScheduler.shared.scheduleAppRefresh()
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
}

//
//  SensingAppApp.swift
//  SensingApp
//

import SwiftUI
import CoreData
import BackgroundTasks
import UserNotifications
//import FirebaseCore

@main
struct SensingAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var locationManager = AdaptiveLocationManager.shared

    init() {
        print("SensingApp init called")

        Logger.shared.append("")
        Logger.shared.append("=======================================================")
        Logger.shared.append("SensingApp init called")

        SurveyNotificationManager.shared.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(locationManager)
                .onAppear {
                    SurveyNotificationManager.shared.scheduleDailyReminder(
                        hour: 20,
                        minute: 0,
                        appState: appState
                    )
                }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("App launched")

        if let folderURL = createFolder(named: "logs") {
            print("Ready to use: \(folderURL)")
        }
        if let folderURL = createFolder(named: "to-be-processed") {
            print("Ready to use: \(folderURL)")
        }
        if let folderURL = createFolder(named: "processed") {
            print("Ready to use: \(folderURL)")
        }

        _ = SQLiteSaver.shared

        //FirebaseApp.configure()

        registerForPushNotifications()
        BackgroundScheduler.shared.registerBackgroundTasks()
        BackgroundScheduler.shared.registerBackgroundAppRefreshTask()

        return true
    }

    func registerForPushNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            print("Permission granted: \(granted)")
            guard granted else { return }

            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
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

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("❌ Failed to register: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("Received notification: \(userInfo)")

        if let data = userInfo["data"] as? [String: Any] {
            print("Silent notification received:", data)
            Logger.shared.append("Silent notification received")
            Logger.shared.append("Battery: " + Logger.shared.getBatteryStatus())
        }

        BackgroundScheduler.shared.printScheduledBackgroundTasks()
        BackgroundScheduler.shared.scheduleAppRefresh()
        completionHandler(.newData)
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

//
//  BackgroundScheduler.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 10/16/25.
//

import BackgroundTasks
import Network

class BackgroundScheduler {
    
    static let shared = BackgroundScheduler() //creates a singleton
    let APP_REFRESH_IDENTIFIER = "edu.uiuc.cs.hcesc.SensingApp.apprefresh"
    let BG_PROCESSING_IDENTIFIER = "edu.uiuc.cs.hcesc.SensingApp.bgProcessing"
    let UPLOAD_PROCESSING_IDENTIFIER = "edu.uiuc.cs.hcesc.SensingApp.fileUpload"
    
    private init() {}
    
    func startSensorRecordingAndScheduleNextTask() {
        var someSensorIsActive = false
        if(AcclerometerRecorder.shared.checkAccelerometerAuthorizationStatus() == true){
            // Restart motion recording
            AcclerometerRecorder.shared.startRecording()
            // Fetch new data
            AcclerometerRecorder.shared.fetchAndSaveRecordedAcclerometerData()
            someSensorIsActive = true
        }
        
        //check healthkit authorization
        HealthkitRecorder.shared.getHealthKitData()
        
        let now = Date()
        UserDefaults.standard.set(now, forKey: "lastSensorDateSaveTime")
        
        if someSensorIsActive {
            Logger.shared.append("SensingApp: Rescheduling background task again")
            rescheduleBackgroundRecordingAfterXhour(hour: 1)
        }
    }
    
    func printScheduledBackgroundTasks(){
        /*
         We are printing every background task that is
         scheduled now.
         */
        BGTaskScheduler.shared.getPendingTaskRequests{ requests in
            print("\(requests.count) BGTasks pending.")
            Logger.shared.append("\(requests.count) BGTasks pending.")
            for request in requests {
                let earliestBeginDateStr = AcclerometerRecorder.shared.dateToString(request.earliestBeginDate)
                print("\(request.identifier) \(earliestBeginDateStr)")
                Logger.shared.append("\(request.identifier) \(earliestBeginDateStr)")
            }
        }
    }
    
    //=============================================================
    //
    // App refresh background task (for lightweight task, less than 30 seconds)
    //
    //=============================================================
    func registerBackgroundAppRefreshTask() {
        print("SensingTrialAppApp:registerAppRefreshTask init called")
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: APP_REFRESH_IDENTIFIER,
            using: nil
        ) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    func scheduleAppRefresh() {
        
        BGTaskScheduler.shared.getPendingTaskRequests{ requests in
            print("Trying to schedule AppRefresh")
            Logger.shared.append("Trying to schedule AppRefresh")
            var alreadyScheduledButInThePast: Bool = false
            for request in requests {
                let earliestBeginDateStr = AcclerometerRecorder.shared.dateToString(request.earliestBeginDate)
                
                if request.identifier == self.APP_REFRESH_IDENTIFIER {
                    if (request.earliestBeginDate ?? Date()) < Date() {
                        //the scheduled time is earlier than now, so
                        //we will schedule a new one, and invalidate the earlier one.
                        alreadyScheduledButInThePast = true
                    }else{
                        print("\(request.identifier) already scheduled at \(earliestBeginDateStr)")
                        Logger.shared.append("\(request.identifier) already scheduled at  \(earliestBeginDateStr)")
                        return
                    }
                }
            }
            
            //we are canceling an scheduled background task from the past
            if alreadyScheduledButInThePast {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.APP_REFRESH_IDENTIFIER)
            }
            
            let request = BGAppRefreshTaskRequest(identifier: self.APP_REFRESH_IDENTIFIER)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // earliest 15 min
            do {
                try BGTaskScheduler.shared.submit(request)
                Logger.shared.append("SensingApp: BGAppRefreshTask scheduled")
                print("🕒 BGAppRefreshTask scheduled")
            } catch {
                print("❌ Could not schedule BGAppRefreshTask: \(error)")
            }
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        /*
         We try to schedule App Refresh every 15 minutes.
         Handle app grabs data if 60 minutes has passed since last recording.
         
         */
        print("🔄 ==BGAppRefreshTask== started")
        Logger.shared.append("==BGAppRefreshTask== started")
        
        // Reschedule next task
        // There should not be any more AppRefreshTask pending
        // as we are already in one.
        scheduleAppRefresh()
        
        // Expiration handler
        task.expirationHandler = {
            print("⏰ ==BGAppRefreshTask== expired")
            Logger.shared.append("==BGAppRefreshTask== expired before completion.")
        }

        // Execute work asynchronously
        Task {
            print("📡 Performing background fetch")
            // Do my tak here
            
            //We will do a recording of motion and reschedule a background task
            //again if bgProcessing has not trigger for the last 1 hour
            //(or we have not recorded anything for the last 1 hour).
            // let lastSensorDateSaveTime = (UserDefaults.standard.object(forKey: "lastSensorDateSaveTime") as? Date) ?? Date()
            if let lastSensorDateSaveTime = UserDefaults.standard.object(forKey: "lastSensorDateSaveTime") as? Date {
                let now  = Date()
                let differenceInMinutes = now.timeIntervalSince(lastSensorDateSaveTime) / 60  // seconds → minutes

                if differenceInMinutes >= 65 {
                    print("⏰ More than 60 minutes have passed.")
                    Logger.shared.append("More than 60 minutes have passed since last recording")
                    BackgroundScheduler.shared.startSensorRecordingAndScheduleNextTask()
                } else {
                    print("🕒 Only \(Int(differenceInMinutes)) minutes have passed.")
                    Logger.shared.append("Only \(Int(differenceInMinutes)) minutes since last recording")
                }
            } else {
                print("⚠️ No saved date found in UserDefaults.")
                Logger.shared.append("No lastSensorDateSaveTime. Recording...")
                //Note the following function will also create "lastSensorDateSaveTime"
                BackgroundScheduler.shared.startSensorRecordingAndScheduleNextTask()
            }
            
            
            task.setTaskCompleted(success: true)
            print("✅ BGAppRefreshTask completed")
            Logger.shared.append("==BGAppRefreshTask== sucessfully completed")
        }
    }
    
    
    
    
    
    //=============================================================
    //
    // Background processing task (this is a heavy work)
    //
    //=============================================================
    
    func registerBackgroundTasks() {
        // Make sure this identifier matches the one in Info.plist
        print("SensingTrialAppApp:registerBackgroundTasks init called")
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BG_PROCESSING_IDENTIFIER,
                                        using: nil) { task in
            self.handleBackgroundStartTask(task: task as! BGProcessingTask)
        }
    }
    // e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"edu.uiuc.cs.hcesc.SensingApp.bgProcessing"]

    
    private func handleBackgroundStartTask(task: BGProcessingTask) {
        print("SensingApp:handleRecordingTask init called")
        Logger.shared.append("SensingApp:handleRecordingTask init called")
        
        startSensorRecordingAndScheduleNextTask()
        
        // Complete the task
        //Todo complete the task handler.
        task.expirationHandler = {
            Logger.shared.append("SensingApp: Background task expired before completion.")
            task.setTaskCompleted(success: false)
        }
        task.setTaskCompleted(success: true)
        
        // Schedule the next one
        // if some sensor is active
        
        
    }
    
    //Calling this function starts the
    //background process immediately.
    func scheduleBGProcessingTask() {
        BGTaskScheduler.shared.getPendingTaskRequests{ requests in
            print("Trying to schedule BGProcessing")
            Logger.shared.append("Trying to schedule BGProcessing")
            var alreadyScheduledButInThePast: Bool = false
            for request in requests {
                let earliestBeginDateStr = AcclerometerRecorder.shared.dateToString(request.earliestBeginDate)
                
                if request.identifier == self.BG_PROCESSING_IDENTIFIER {
                    if (request.earliestBeginDate ?? Date()) < Date() {
                        //the scheduled time is earlier than now, so
                        //we will schedule a new one, and invalidate the earlier one.
                        alreadyScheduledButInThePast = true
                    }else{
                        print("\(request.identifier) already scheduled at \(earliestBeginDateStr)")
                        Logger.shared.append("\(request.identifier) already scheduled at  \(earliestBeginDateStr)")
                        return
                    }
                }
            }
            
            //we are canceling an scheduled background task from the past
            if alreadyScheduledButInThePast {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.BG_PROCESSING_IDENTIFIER)
            }
            
            let request = BGProcessingTaskRequest(identifier: self.BG_PROCESSING_IDENTIFIER)
            request.requiresNetworkConnectivity = false  // Set true if needed
            request.requiresExternalPower = false        // Set true if the task is power-hungry
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 15)
            do {
                try BGTaskScheduler.shared.submit(request)
                print("BGProcessingTask scheduled.")
                Logger.shared.append("Background recording scheduled (scheduleBGProcessingTask).")
            } catch {
                print("Failed to schedule BGProcessingTask: \(error)")
            }
        }
    }
    
    // e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"edu.uiuc.cs.hcesc.SensingApp.bgProcessing"]
    ///
    /// I do not need to keep this scheduler here. Ideally we want to do the rescheduling business where we do the recording.
    ///
    func rescheduleBackgroundRecordingAfterXhour(hour: Int) {
        
        BGTaskScheduler.shared.getPendingTaskRequests{ requests in
            print("Trying to schedule BGProcessing")
            Logger.shared.append("Trying to schedule BGProcessing")
            var alreadyScheduledButInThePast: Bool = false
            for request in requests {
                let earliestBeginDateStr = AcclerometerRecorder.shared.dateToString(request.earliestBeginDate)
                
                if request.identifier == self.BG_PROCESSING_IDENTIFIER {
                    print("\(request.identifier) already scheduled at \(earliestBeginDateStr)")
                    Logger.shared.append("\(request.identifier) already scheduled at  \(earliestBeginDateStr)")
                    
                    //If more than 60 minutes has passed since earliest time, then we are getting delayed
                    //we need to reschedule the bgProcessing again.
                    let now = Date()
                    let differenceInMinutes = now.timeIntervalSince(request.earliestBeginDate ?? now) / 60
                    if differenceInMinutes < 60 {
                        return
                    }else{
                        alreadyScheduledButInThePast = true
                    }
                }
            }
            
            //we are canceling an scheduled background task from the past
            //and scheduling a new one.
            if alreadyScheduledButInThePast {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.BG_PROCESSING_IDENTIFIER)
            }
            
            //this will add the background scheduling part with handleMotionTask.
            let request = BGProcessingTaskRequest(identifier: self.BG_PROCESSING_IDENTIFIER)
            request.requiresExternalPower = false
            request.requiresNetworkConnectivity = false
            request.earliestBeginDate = Date(timeIntervalSinceNow: Double(hour) * 60 * 60) // restart before 12h ends
            do {
                try BGTaskScheduler.shared.submit(request)
                print("Background recording scheduled.")
                Logger.shared.append("Background recording scheduled (rescheduleBackgroundRecordingAfterXhour).")
            } catch {
                print("Could not schedule background task: \(error)")
            }
        }
    }
    
    
    //=============================================================
    //
    // Background processing task for upload
    // only run when network connectivity is available and phone is charging
    //
    //=============================================================
    // Call this once at app launch (AppDelegate or @main App init)
    func registerUploadBGTask() {
        
        print("SensingTrialAppApp:registerUploadBGTask init called")
        BGTaskScheduler.shared.register(forTaskWithIdentifier: UPLOAD_PROCESSING_IDENTIFIER,
                                        using: nil) { task in
            self.handleUploadBGStartTask(task: task as! BGProcessingTask)
        }
    }
    
    // Call this to schedule the next run
    func scheduleUploadBGTask() {
        BGTaskScheduler.shared.getPendingTaskRequests{ requests in
            print("Trying to schedule Upload BGProcessing")
            Logger.shared.append("Trying to schedule BGProcessing")
            var alreadyScheduledButInThePast: Bool = false
            for request in requests {
                let earliestBeginDateStr = AcclerometerRecorder.shared.dateToString(request.earliestBeginDate)
                
                if request.identifier == self.UPLOAD_PROCESSING_IDENTIFIER {
                    
                    if (request.earliestBeginDate ?? Date()) < Date() {
                        //the scheduled time is earlier than now, so
                        //we will schedule a new one, and invalidate the earlier one.
                        alreadyScheduledButInThePast = true
                    }else{
                        print("\(request.identifier) already scheduled at \(earliestBeginDateStr)")
                        Logger.shared.append("\(request.identifier) already scheduled at  \(earliestBeginDateStr)")
                        return
                    }
                }
            }
            
            //we are canceling an scheduled background task from the past
            if alreadyScheduledButInThePast {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.UPLOAD_PROCESSING_IDENTIFIER)
            }
            
            let request = BGProcessingTaskRequest(identifier: self.UPLOAD_PROCESSING_IDENTIFIER)
            request.requiresNetworkConnectivity = true   // WiFi (or any network)
            request.requiresExternalPower = true         // Must be charging
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // not before 15 min from now
            do {
                try BGTaskScheduler.shared.submit(request)
                print("Upload BGProcessingTask scheduled.")
                Logger.shared.append("Background uploading scheduled (scheduleUploadBGTask).")
            } catch {
                print("Failed to schedule UploadBGTask: \(error)")
            }
        }
    }
    
    func handleUploadBGStartTask(task: BGProcessingTask) {
        // Reschedule immediately so the cycle continues
        print("SensingTrialAppApp:handleUploadBGStartTask is called")
        
        self.scheduleUploadBGTask()

        // Set expiration handler — iOS will call this if time runs out
        task.expirationHandler = {
            // Cancel any ongoing work here
            print("Task expired — clean up")
        }

        // Do your actual work
        performUpload { success in
            task.setTaskCompleted(success: success)
        }
    }
    
    func isOnWiFi() -> Bool {
        // Synchronous check — fine inside a background task
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        var onWiFi = false
        let sema = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            onWiFi = path.status == .satisfied
            sema.signal()
        }
        monitor.start(queue: DispatchQueue.global())
        sema.wait()
        monitor.cancel()
        return onWiFi
    }
    
    private func performUpload(completion: @escaping (Bool) -> Void) {
        // Your function goes here
        print("Running background work — Network connected, charging")
        Logger.shared.append("BGUploadProcessingTask: Running background work — WiFi connected, charging")
        // e.g. upload SQLite DB, sync data, etc.
        if self.isOnWiFi() {
            Logger.shared.append("BGUploadProcessingTask: On Wifi. Starting upload")
            Task {
                await Uploader.shared.uploadFolder()
            }
        }
        completion(true)
    }
    
    
}

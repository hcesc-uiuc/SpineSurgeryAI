//
//  BackgroundScheduler.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 10/16/25.
//

import BackgroundTasks


class BackgroundScheduler {
    
    static let shared = BackgroundScheduler() //creates a singleton
    let APP_REFRESH_IDENTIFIER = "edu.uiuc.cs.hcesc.SensingApp.apprefresh"
    let BG_PROCESSING_IDENTIFIER = "edu.uiuc.cs.hcesc.SensingApp.bgProcessing"
    
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
        
        let now = Date()
        UserDefaults.standard.set(now, forKey: "lastSensorDateSaveTime")
        
        if someSensorIsActive {
            Logger.shared.append("SensingApp: Rescheduling background task again")
            rescheduleBackgroundRecordingAfterXhour(hour: 1)
        }
    }
    
    func printScheduledBackgroundTasks(){
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
            for request in requests {
                let earliestBeginDateStr = AcclerometerRecorder.shared.dateToString(request.earliestBeginDate)
                
                if request.identifier == self.APP_REFRESH_IDENTIFIER {
                    print("\(request.identifier) already scheduled at \(earliestBeginDateStr)")
                    Logger.shared.append("\(request.identifier) already scheduled at  \(earliestBeginDateStr)")
                    return
                }
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
        print("🔄 ==BGAppRefreshTask== started")
        Logger.shared.append("==BGAppRefreshTask== started")
        
        // Reschedule next task
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
                let now = Date()
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
            for request in requests {
                let earliestBeginDateStr = AcclerometerRecorder.shared.dateToString(request.earliestBeginDate)
                
                if request.identifier == self.BG_PROCESSING_IDENTIFIER {
                    print("\(request.identifier) already scheduled at \(earliestBeginDateStr)")
                    Logger.shared.append("\(request.identifier) already scheduled at  \(earliestBeginDateStr)")
                    return
                }
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
                    }
                }
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
    
    
    
}

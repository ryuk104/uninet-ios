//
//  AppDelegate.swift
//  uninet-ios
//
//  Created by Alex Ma on 3/31/22.
//

import UIKit
import CoreData
import Foundation

@objc
enum LaunchFailure: UInt {
    case none
    case couldNotLoadDatabase
    case unknownDatabaseVersion
    case couldNotRestoreTransferredData
    case databaseUnrecoverablyCorrupted
    case lastAppLaunchCrashed
    case lowStorageSpaceAvailable
}



@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window: UIWindow?

    func application(_ application: UIApplication, 
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool, 
    didDiscardSceneSessions sceneSessions: Set<UISceneSession>, 
    configurationForConnecting connectingSceneSession: UISceneSession, 
    options: UIScene.ConnectionOptions) -> UISceneConfiguration,
    configurationForConnecting connectingSceneSession: UISceneSession, 
    options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        FirebaseApp.configure()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window = UIWindow()
        window?.makeKeyAndVisible()
        window?.backgroundColor = .white
        window?.rootViewController = MainTabBarController()
        if AuthManager.shared.isSignedIn {
            AuthManager.shared.refreshAccesTokenIfNeccessary(completion: nil)
            window.rootViewController = TabBarViewController()
        } else {
            window.rootViewController = UINavigationController(rootViewController: WelcomeViewController())
        }
        window.makeKeyAndVisible()
        self.window = window
        return true
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)

    }

    
    @UIApplicationMain
    class AppDelegate: UIResponder, UIApplicationDelegate {



        func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
            // Override point for customization after application launch.
            FirebaseApp.configure()
            return true
        }

        // MARK: UISceneSession Lifecycle

        func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
            // Called when a new scene session is being created.
            // Use this method to select a configuration to create the new scene with.
            return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        }

        func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
            // Called when the user discards a scene session.
            // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
            // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
        }


    }

    // MARK: - Core Data stack

    lazy var persistentContainer: NSPersistentContainer = {
        /*
         The persistent container for the application. This implementation
         creates and returns a container, having loaded the store for the
         application to it. This property is optional since there are legitimate
         error conditions that could cause the creation of the store to fail.
        */
        let container = NSPersistentContainer(name: "uninet_ios")
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                 
                /*
                 Typical reasons for an error here include:
                 * The parent directory does not exist, cannot be created, or disallows writing.
                 * The persistent store is not accessible, due to permissions or data protection when the device is locked.
                 * The device is out of space.
                 * The store could not be migrated to the current model version.
                 Check the error message to determine what the actual problem was.
                 */
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        return container
    }()

    // MARK: - Core Data Saving support

    func saveContext () {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                let nserror = error as NSError
                fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
            }
        }
    }

}

extension AppDelegate {
    @objc(checkSomeDiskSpaceAvailable)
    func checkSomeDiskSpaceAvailable() -> Bool {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .path
        let succeededCreatingDir = OWSFileSystem.ensureDirectoryExists(tempDir)

        // Best effort at deleting temp dir, which shouldn't ever fail
        if succeededCreatingDir && !OWSFileSystem.deleteFile(tempDir) {
            owsFailDebug("Failed to delete temp dir used for checking disk space!")
        }

        return succeededCreatingDir
    }

    @objc
    func setupNSEInteroperation() {
        Logger.info("")

        // We immediately post a notification letting the NSE know the main app has launched.
        // If it's running it should take this as a sign to terminate so we don't unintentionally
        // try and fetch messages from two processes at once.
        DarwinNotificationCenter.post(.mainAppLaunched)

        // We listen to this notification for the lifetime of the application, so we don't
        // record the returned observer token.
        DarwinNotificationCenter.addObserver(
            for: .nseDidReceiveNotification,
            queue: DispatchQueue.global(qos: .userInitiated)
        ) { token in
            Logger.debug("Handling NSE received notification")

            // Immediately let the NSE know we will handle this notification so that it
            // does not attempt to process messages while we are active.
            DarwinNotificationCenter.post(.mainAppHandledNotification)

            AppReadiness.runNowOrWhenAppDidBecomeReadySync {
                self.messageFetcherJob.run()
            }
        }
    }

    @objc
    func versionMigrationsDidComplete() {
        AssertIsOnMainThread()
        Logger.info("versionMigrationsDidComplete")
        areVersionMigrationsComplete = true
        checkIfAppIsReady()
    }

    @objc
    func checkIfAppIsReady() {
        AssertIsOnMainThread()

        // If launch failed, the app will never be ready.
        guard !didAppLaunchFail else { return }

        // App isn't ready until storage is ready AND all version migrations are complete.
        guard areVersionMigrationsComplete else { return }
        guard storageCoordinator.isStorageReady else { return }

        // Only mark the app as ready once.
        guard !AppReadiness.isAppReady else { return }

        // If launch jobs need to run, return and call checkIfAppIsReady again when they're complete.
        let launchJobsAreComplete = launchJobs.ensureLaunchJobs {
            self.checkIfAppIsReady()
        }
        guard launchJobsAreComplete else { return }

        Logger.info("checkIfAppIsReady")

        // Note that this does much more than set a flag;
        // it will also run all deferred blocks.
        AppReadiness.setAppIsReadyUIStillPending()

        guard !CurrentAppContext().isRunningTests else {
            Logger.verbose("Skipping post-launch logic in tests.")
            AppReadiness.setUIIsReady()
            return
        }

        // If user is missing profile name, redirect to onboarding flow.
        if !SSKEnvironment.shared.profileManager.hasProfileName {
            databaseStorage.write { transaction in
                self.tsAccountManager.setIsOnboarded(false, transaction: transaction)
            }
        }

        if tsAccountManager.isRegistered {
            databaseStorage.read { transaction in
                let localAddress = self.tsAccountManager.localAddress(with: transaction)
                let deviceId = self.tsAccountManager.storedDeviceId(with: transaction)
                let deviceCount = OWSDevice.anyCount(transaction: transaction)
                let linkedDeviceMessage = deviceCount > 1 ? "\(deviceCount) devices including the primary" : "no linked devices"
                Logger.info("localAddress: \(String(describing: localAddress)), deviceId: \(deviceId) (\(linkedDeviceMessage))")
            }

            // This should happen at any launch, background or foreground.
            SyncPushTokensJob.run()
        }

        DebugLogger.shared().postLaunchLogCleanup()
        AppVersion.shared().mainAppLaunchDidComplete()

        if !Environment.shared.preferences.hasGeneratedThumbnails() {
            databaseStorage.asyncRead(
                block: { transaction in
                    TSAttachment.anyEnumerate(transaction: transaction, batched: true) { (_, _) in
                        // no-op. It's sufficient to initWithCoder: each object.
                    }
                },
                completion: {
                    Environment.shared.preferences.setHasGeneratedThumbnails(true)
                }
            )
        }

        SignalApp.shared().ensureRootViewController(launchStartedAt)
    }

    @objc
    func enableBackgroundRefreshIfNecessary() {
        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            let interval: TimeInterval
            if
                OWS2FAManager.shared.isRegistrationLockEnabled,
                self.tsAccountManager.isRegisteredAndReady {
                // Ping server once a day to keep-alive reglock clients.
                interval = 24 * 60 * 60
            } else {
                interval = UIApplication.backgroundFetchIntervalNever
            }
            UIApplication.shared.setMinimumBackgroundFetchInterval(interval)
        }
    }

    // MARK: - Launch failures
    @objc(showUIForLaunchFailure:)
    func showUI(forLaunchFailure launchFailure: LaunchFailure) {
        Logger.info("launchFailure: \(Self.string(for: launchFailure))")

        // Disable normal functioning of app.
        didAppLaunchFail = true

        if launchFailure == .lowStorageSpaceAvailable {
            shouldKillAppWhenBackgrounded = true
        }

        // We perform a subset of the [application:didFinishLaunchingWithOptions:].
        let window: UIWindow
        if let existingWindow = self.window {
            window = existingWindow
        } else {
            window = OWSWindow()
            CurrentAppContext().mainWindow = window
            self.window = window
        }

        // Show the launch screen
        let storyboard = UIStoryboard(name: "Launch Screen", bundle: nil)
        guard let viewController = storyboard.instantiateInitialViewController() else {
            owsFail("No initial view controller")
        }

        window.rootViewController = viewController

        window.makeKeyAndVisible()

        let actionSheet = getActionSheet(for: launchFailure, from: viewController) {
            switch launchFailure {
            case .lastAppLaunchCrashed:
                // Pretend we didn't fail!
                self.didAppLaunchFail = false
                self.launchToHomeScreen(launchOptions: nil, instrumentsMonitorId: 0)
            default:
                owsFail("exiting after sharing debug logs.")
            }
        }

        viewController.presentActionSheet(actionSheet)
    }

    func getActionSheet(for launchFailure: LaunchFailure,
                        from viewController: UIViewController,
                        onContinue: @escaping () -> Void) -> ActionSheetController {
        let title: String
        var message: String = NSLocalizedString("APP_LAUNCH_FAILURE_ALERT_MESSAGE",
                                                comment: "Message for the 'app launch failed' alert.")
        switch launchFailure {
        case .databaseUnrecoverablyCorrupted, .couldNotLoadDatabase:
            title = NSLocalizedString("APP_LAUNCH_FAILURE_COULD_NOT_LOAD_DATABASE",
                                      comment: "Error indicating that the app could not launch because the database could not be loaded.")
        case .unknownDatabaseVersion:
            title = NSLocalizedString("APP_LAUNCH_FAILURE_INVALID_DATABASE_VERSION_TITLE",
                                      comment: "Error indicating that the app could not launch without reverting unknown database migrations.")
            message = NSLocalizedString("APP_LAUNCH_FAILURE_INVALID_DATABASE_VERSION_MESSAGE",
                                        comment: "Error indicating that the app could not launch without reverting unknown database migrations.")
        case .couldNotRestoreTransferredData:
            title = NSLocalizedString("APP_LAUNCH_FAILURE_RESTORE_FAILED_TITLE",
                                      comment: "Error indicating that the app could not restore transferred data.")
            message = NSLocalizedString("APP_LAUNCH_FAILURE_RESTORE_FAILED_MESSAGE",
                                        comment: "Error indicating that the app could not restore transferred data.")
        case .lastAppLaunchCrashed:
            title = NSLocalizedString("APP_LAUNCH_FAILURE_LAST_LAUNCH_CRASHED_TITLE",
                                      comment: "Error indicating that the app crashed during the previous launch.")
            message = NSLocalizedString("APP_LAUNCH_FAILURE_LAST_LAUNCH_CRASHED_MESSAGE",
                                        comment: "Error indicating that the app crashed during the previous launch.")
        case .lowStorageSpaceAvailable:
            title = NSLocalizedString("APP_LAUNCH_FAILURE_LOW_STORAGE_SPACE_AVAILABLE_TITLE",
                                      comment: "Error title indicating that the app crashed because there was low storage space available on the device.")
            message = NSLocalizedString("APP_LAUNCH_FAILURE_LOW_STORAGE_SPACE_AVAILABLE_MESSAGE",
                                        comment: "Error description indicating that the app crashed because there was low storage space available on the device.")
        case .none:
            owsFailDebug("Unknown launch failure.")
            title = NSLocalizedString("APP_LAUNCH_FAILURE_ALERT_TITLE", comment: "Title for the 'app launch failed' alert.")
        }

        let result = ActionSheetController(title: title, message: message)

        if DebugFlags.internalSettings {
            result.addAction(.init(title: "Export Database (internal)") { _ in
                SignalApp.showExportDatabaseUI(from: viewController) { [weak viewController] in
                    viewController?.presentActionSheet(result)
                }
            })
        }

        if launchFailure != .lowStorageSpaceAvailable {
            let title = NSLocalizedString("SETTINGS_ADVANCED_SUBMIT_DEBUGLOG", comment: "")
            result.addAction(.init(title: title) { _ in
                func submitDebugLogs() {
                    Pastelog.submitLogs(withSupportTag: Self.string(for: launchFailure),
                                        completion: onContinue)
                }

                if launchFailure == .databaseUnrecoverablyCorrupted {
                    SignalApp.showDatabaseIntegrityCheckUI(from: viewController,
                                                           completion: submitDebugLogs)
                } else {
                    submitDebugLogs()
                }
            })
        }

        if launchFailure == .lastAppLaunchCrashed {
            // Use a cancel-style button to draw attention.
            let title = NSLocalizedString("APP_LAUNCH_FAILURE_CONTINUE",
                                          comment: "Button to try launching the app even though the last launch failed")
            result.addAction(.init(title: title, style: .cancel) { _ in
                onContinue()
            })
        }

        return result
    }

    @objc(stringForLaunchFailure:)
    class func string(for launchFailure: LaunchFailure) -> String {
        switch launchFailure {
        case .none:
            return "LaunchFailure_None"
        case .couldNotLoadDatabase:
            return "LaunchFailure_CouldNotLoadDatabase"
        case .unknownDatabaseVersion:
            return "LaunchFailure_UnknownDatabaseVersion"
        case .couldNotRestoreTransferredData:
            return "LaunchFailure_CouldNotRestoreTransferredData"
        case .databaseUnrecoverablyCorrupted:
            return "LaunchFailure_DatabaseUnrecoverablyCorrupted"
        case .lastAppLaunchCrashed:
            return "LaunchFailure_LastAppLaunchCrashed"
        case .lowStorageSpaceAvailable:
            return "LaunchFailure_NoDiskSpaceAvailable"
        }
    }

    // MARK: - Remote notifications
    enum HandleSilentPushContentResult: UInt {
        case handled
        case notHandled
    }

    @objc
    func processRemoteNotification(_ remoteNotification: NSDictionary) {
        processRemoteNotification(remoteNotification) {}
    }

    @objc
    func processRemoteNotification(_ remoteNotification: NSDictionary, completion: @escaping () -> Void) {
        AssertIsOnMainThread()

        guard !didAppLaunchFail else {
            owsFailDebug("app launch failed")
            return
        }

        guard AppReadiness.isAppReady, tsAccountManager.isRegisteredAndReady else {
            Logger.info("Ignoring remote notification; app is not ready.")
            return
        }

        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            // TODO: NSE Lifecycle, is this invoked when the NSE wakes the main app?
            if
                let remoteNotification = remoteNotification as? [AnyHashable: Any],
                self.handleSilentPushContent(remoteNotification) == .notHandled {
                self.messageFetcherJob.run()
            }

            completion()
        }
    }

    func handleSilentPushContent(_ remoteNotification: [AnyHashable: Any]) -> HandleSilentPushContentResult {
        if let spamChallengeToken = remoteNotification["rateLimitChallenge"] as? String {
            spamChallengeResolver.handleIncomingPushChallengeToken(spamChallengeToken)
            return .handled
        }

        if let preAuthChallengeToken = remoteNotification["challenge"] as? String {
            pushRegistrationManager.didReceiveVanillaPreAuthChallengeToken(preAuthChallengeToken)
            return .handled
        }

        return .notHandled
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {
    // The method will be called on the delegate only if the application is in the foreground. If the method is not
    // implemented or the handler is not called in a timely manner then the notification will not be presented. The
    // application can choose to have the notification presented as a sound, badge, alert and/or in the notification list.
    // This decision should be based on whether the information in the notification is otherwise visible to the user.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Logger.info("")

        // Capture just userInfo; we don't want to retain notification.
        let remoteNotification = notification.request.content.userInfo
        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            let options: UNNotificationPresentationOptions
            switch self.handleSilentPushContent(remoteNotification) {
            case .handled:
                options = []
            case .notHandled:
                // We need to respect the in-app notification sound preference. This method, which is called
                // for modern UNUserNotification users, could be a place to do that, but since we'd still
                // need to handle this behavior for legacy UINotification users anyway, we "allow" all
                // notification options here, and rely on the shared logic in NotificationPresenter to
                // honor notification sound preferences for both modern and legacy users.
                options = [.alert, .badge, .sound]
            }
            completionHandler(options)
        }
    }

    // The method will be called on the delegate when the user responded to the notification by opening the application,
    // dismissing the notification or choosing a UNNotificationAction. The delegate must be set before the application
    // returns from application:didFinishLaunchingWithOptions:.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Logger.info("")
        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            NotificationActionHandler.handleNotificationResponse(response, completionHandler: completionHandler)
        }
    }


import Cocoa
import UserNotifications

enum Notifier {
    private static var didSurfaceFailure = false

    static var userWantsNotifications: Bool {
        UserDefaults.standard.bool(forKey: "notifyInputLost")
            || UserDefaults.standard.bool(forKey: "notifyInputRestored")
    }

    static func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if (!granted || error != nil) && userWantsNotifications {
                surfaceFailureOnce(
                    reason: error?.localizedDescription
                        ?? "Notifications are disabled in System Settings → Notifications → EFStatus."
                )
            }
        }
    }

    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                center.add(req) { error in
                    if let error, userWantsNotifications {
                        surfaceFailureOnce(reason: error.localizedDescription)
                    }
                }
            case .denied:
                if userWantsNotifications {
                    surfaceFailureOnce(
                        reason: "Notifications are disabled in System Settings → Notifications → EFStatus."
                    )
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if granted {
                        center.add(req) { addErr in
                            if let addErr, userWantsNotifications {
                                surfaceFailureOnce(reason: addErr.localizedDescription)
                            }
                        }
                    } else if userWantsNotifications {
                        surfaceFailureOnce(
                            reason: error?.localizedDescription
                                ?? "Notifications are disabled in System Settings → Notifications → EFStatus."
                        )
                    }
                }
            @unknown default:
                center.add(req)
            }
        }
    }

    static func authorizationDeniedMessage(_ completion: @escaping (String?) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .denied && userWantsNotifications {
                    completion("Notifications are disabled in System Settings → Notifications → EFStatus.")
                } else {
                    completion(nil)
                }
            }
        }
    }

    static func requestAndExplain(_ completion: @escaping (String?) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    completion(nil)
                } else {
                    completion(
                        error?.localizedDescription
                            ?? "Notifications are disabled in System Settings → Notifications → EFStatus."
                    )
                }
            }
        }
    }

    private static func surfaceFailureOnce(reason: String) {
        guard !didSurfaceFailure else { return }
        didSurfaceFailure = true
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "EFStatus notifications"
            alert.informativeText = reason
            alert.alertStyle = .informational
            alert.runModal()
        }
    }
}

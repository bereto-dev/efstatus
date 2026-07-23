import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // hide from Dock

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        controller = StatusBarController()
    }
}

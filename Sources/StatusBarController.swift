import Cocoa

class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var menu       = NSMenu()
    private var timer:     Timer?
    private var api:       EcoFlowAPI?
    private var setupWin:  SetupWindow?

    // notification state
    private var prevInputWas0  = false
    private var prevWasOffline = false

    // menu items updated on each poll
    private let itemBattery  = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private let itemTime     = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private let itemIn       = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private let itemOut      = NSMenuItem(title: "—", action: nil, keyEquivalent: "")

    override init() {
        super.init()

        if let button = statusItem.button {
            button.title = "⚡ —"
        }

        buildMenu()

        if let creds = CredentialsManager.load() {
            connect(creds)
        } else {
            showSetup()
        }
    }

    // MARK: – Menu

    private func buildMenu() {
        for item in [itemBattery, itemTime] {
            item.isEnabled = false
            item.attributedTitle = styledTitle(item.title, size: 13, bold: false, color: .labelColor)
        }
        for item in [itemIn, itemOut] {
            item.isEnabled = false
        }

        menu.addItem(itemBattery)
        menu.addItem(itemTime)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(itemIn)
        menu.addItem(itemOut)
        menu.addItem(NSMenuItem.separator())

        let prefItem = NSMenuItem(title: "Preferences…", action: #selector(showSetup), keyEquivalent: ",")
        prefItem.target = self
        menu.addItem(prefItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit EFStatus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func styledTitle(_ text: String, size: CGFloat, bold: Bool, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color
        ])
    }

    private func updateMenu(_ st: EFStatus) {
        DispatchQueue.main.async {
            // Bar icon
            self.statusItem.button?.title = "⚡ \(st.soc)%"

            // Battery row
            let bar   = self.battBar(soc: st.soc)
            let whStr = st.remainWh != nil ? "  \(st.remainWh!) Wh" : ""
            self.itemBattery.attributedTitle = self.styledTitle(
                "🔋  \(st.soc)%\(whStr)  \(bar)", size: 13, bold: true, color: .labelColor)

            // Time row
            self.itemTime.attributedTitle = self.styledTitle(
                "    \(st.timeLabel)", size: 12, bold: false, color: .secondaryLabelColor)

            // In / out
            self.itemIn.attributedTitle  = self.styledTitle(
                "↑  \(Int(st.inW)) W  entrada", size: 12, bold: false, color: NSColor(red: 0.3, green: 0.85, blue: 0.5, alpha: 1))
            self.itemOut.attributedTitle = self.styledTitle(
                "↓  \(Int(st.outW)) W  salida", size: 12, bold: false, color: NSColor(red: 0.97, green: 0.47, blue: 0.42, alpha: 1))
        }
    }

    private func battBar(soc: Int) -> String {
        let filled = soc / 10
        let empty  = 10 - filled
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: empty)
    }

    private func setOfflineUI() {
        DispatchQueue.main.async {
            self.statusItem.button?.title = "⚡ —"
            self.itemBattery.title = "No connection"
            self.itemTime.title    = ""
            self.itemIn.title      = ""
            self.itemOut.title     = ""
        }
    }

    // MARK: – Polling

    private func connect(_ creds: Credentials) {
        api = EcoFlowAPI(accessKey: creds.accessKey, secretKey: creds.secretKey, serial: creds.serial)
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let api else { return }
        Task {
            do {
                let st = try await api.fetchStatus()

                // Notify: input dropped to 0
                if st.inW == 0 && !self.prevInputWas0 {
                    Notifier.send(title: "EFStatus", body: "No input power — consuming \(Int(st.outW))W from battery")
                }
                self.prevInputWas0 = st.inW == 0

                // Notify: back online after offline
                if self.prevWasOffline {
                    Notifier.send(title: "EFStatus", body: "Device back online — \(st.soc)%")
                }
                self.prevWasOffline = false

                self.updateMenu(st)
            } catch {
                if !self.prevWasOffline {
                    Notifier.send(title: "EFStatus", body: "Lost connection to device")
                }
                self.prevWasOffline = true
                self.setOfflineUI()
            }
        }
    }

    // MARK: – Setup

    @objc func showSetup() {
        if setupWin == nil {
            setupWin = SetupWindow()
            setupWin?.onSave = { [weak self] creds in
                self?.timer?.invalidate()
                self?.timer = nil
                self?.connect(creds)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWin?.makeKeyAndOrderFront(nil)
    }
}

import Cocoa

class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var popup:    PopupPanel?
    private var timer:    Timer?
    private var api:      EcoFlowAPI?
    private var setupWin: SetupWindow?

    private var prevInputWas0  = false
    private var prevWasOffline = false

    override init() {
        super.init()

        if let btn = statusItem.button {
            btn.title  = "⚡ —"
            btn.action = #selector(togglePopup)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        if let creds = CredentialsManager.load() {
            connect(creds)
        } else {
            showSetup()
        }
    }

    // MARK: – Popup

    @objc private func togglePopup() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if let p = popup, p.isVisible {
            p.orderOut(nil)
            return
        }

        guard let btn = statusItem.button,
              let screen = btn.window?.screen ?? NSScreen.main else { return }

        if popup == nil { popup = PopupPanel() }

        // Position below the status bar item
        let btnFrame   = btn.window!.convertToScreen(btn.frame)
        let panelW: CGFloat = 280
        var x = btnFrame.midX - panelW / 2
        let y = btnFrame.minY - 8

        // Keep on screen
        x = min(x, screen.visibleFrame.maxX - panelW - 8)
        x = max(x, screen.visibleFrame.minX + 8)

        popup?.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        popup?.orderFrontRegardless()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSetup), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let help = NSMenuItem(title: "Help & Support", action: #selector(openRepo), keyEquivalent: "")
        help.target = self
        menu.addItem(help)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit EFStatus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/bereto-dev/efstatus")!)
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

                if st.inW == 0 && !self.prevInputWas0 {
                    Notifier.send(title: "EFStatus", body: "Sin entrada — consumiendo \(Int(st.outW))W de batería")
                }
                self.prevInputWas0 = st.inW == 0

                if self.prevWasOffline {
                    Notifier.send(title: "EFStatus", body: "Dispositivo en línea — \(st.soc)%")
                }
                self.prevWasOffline = false

                DispatchQueue.main.async {
                    self.statusItem.button?.title = "⚡ \(st.soc)%"
                    self.popup?.update(st)
                }
            } catch {
                if !self.prevWasOffline {
                    Notifier.send(title: "EFStatus", body: "Sin conexión al dispositivo")
                }
                self.prevWasOffline = true
                DispatchQueue.main.async {
                    self.statusItem.button?.title = "⚡ —"
                }
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

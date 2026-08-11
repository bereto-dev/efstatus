import Cocoa

class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var popup:    PopupPanel?
    private var setupWin: SetupWindow?
    private var aboutWin: AboutWindow?

    private var api:          EcoFlowAPI?
    private var mqttClient:   MQTTClient?
    private var mqttCreds:    MQTTCredentials?
    private var deviceState:  [String: Any] = [:]   // merged state: REST fills it, MQTT updates it

    private var pollTimer:    Timer?   // REST fallback when MQTT is down
    private var reconnTimer:  Timer?   // MQTT reconnect backoff
    private var reconnDelay:  TimeInterval = 5
    private var mqttLive      = false  // true once MQTT delivers at least one message

    private var prevInputWas0  = false
    private var prevWasOffline = false

    override init() {
        super.init()
        if let btn = statusItem.button {
            btn.title  = "EF⚡ —"
            btn.action = #selector(togglePopup)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if let creds = CredentialsManager.load() { connect(creds) } else { showSetup() }
    }

    // MARK: – Connection entry point

    private func connect(_ creds: Credentials) {
        api = EcoFlowAPI(accessKey: creds.accessKey, secretKey: creds.secretKey, serial: creds.serial)
        deviceState.removeAll()

        // 1. REST fetch — immediate display while MQTT connects
        restPoll()

        // 2. Get MQTT credentials and connect
        Task {
            do {
                let mc = try await api!.fetchMQTTCredentials()
                await MainActor.run { self.startMQTT(mc) }
            } catch {
                // MQTT credentials unavailable — fall back to REST polling
                await MainActor.run { self.startRestFallback() }
            }
        }
    }

    // MARK: – MQTT

    private func startMQTT(_ creds: MQTTCredentials) {
        mqttCreds = creds
        reconnDelay = 5

        let client = MQTTClient()
        mqttClient = client

        client.onConnect = { [weak self] in
            guard let self else { return }
            self.mqttLive = false
            client.subscribe(to: creds.topic)
            // Keep a REST poll as safety net in case MQTT is silent for >30s
            self.startMQTTWatchdog()
        }

        client.onMessage = { [weak self] _, json in
            self?.handleMQTTMessage(json)
        }

        client.onDisconnect = { [weak self] err in
            guard let self else { return }
            self.mqttLive = false
            self.stopWatchdog()
            if err != nil { self.startRestFallback() }
            self.scheduleReconnect()
        }

        client.connect(host: creds.url, port: creds.port,
                       username: creds.username, password: creds.password,
                       clientId: creds.clientId)
    }

    private func handleMQTTMessage(_ json: [String: Any]) {
        // EcoFlow sends params at the top level or nested under "params"
        let params = json["params"] as? [String: Any] ?? json

        // Filter: only accept numeric leaf values (same as REST quota structure)
        let numeric = params.filter { $0.value is NSNumber }
        guard !numeric.isEmpty else { return }

        // Merge into device state
        for (key, value) in numeric { deviceState[key] = value }

        mqttLive = true
        stopWatchdog()     // reset watchdog; real data arrived
        startMQTTWatchdog()
        stopRestFallback() // MQTT working — no need for REST polling

        updateUI(from: deviceState)
    }

    // MARK: – MQTT watchdog (REST backup if MQTT is silent > 30s)

    private var watchdogTimer: Timer?

    private func startMQTTWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, !self.mqttLive else { return }
            self.startRestFallback()
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: – MQTT reconnect (exponential backoff, max 60s)

    private func scheduleReconnect() {
        reconnTimer?.invalidate()
        reconnTimer = Timer.scheduledTimer(withTimeInterval: reconnDelay, repeats: false) { [weak self] _ in
            guard let self, let creds = self.mqttCreds else { return }
            self.mqttClient?.disconnect()
            self.startMQTT(creds)
        }
        reconnDelay = min(reconnDelay * 2, 60)
    }

    // MARK: – REST fallback polling (10s when MQTT is down)

    private func startRestFallback() {
        guard pollTimer == nil else { return }
        restPoll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.restPoll()
        }
    }

    private func stopRestFallback() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func restPoll() {
        guard let api else { return }
        Task {
            do {
                let (quota, _) = try await api.fetchStatus()
                await MainActor.run {
                    self.deviceState = quota   // full replacement from REST
                    self.updateUI(from: quota)
                    if self.prevWasOffline {
                        Notifier.send(title: "EFStatus", body: "Device back online")
                    }
                    self.prevWasOffline = false
                }
            } catch {
                await MainActor.run {
                    if !self.prevWasOffline {
                        Notifier.send(title: "EFStatus", body: "Lost connection to device")
                    }
                    self.prevWasOffline = true
                    self.statusItem.button?.title = "EF⚡ —"
                }
            }
        }
    }

    // MARK: – UI update

    private func updateUI(from state: [String: Any]) {
        let st = EcoFlowAPI.parseStatus(from: state)

        if st.inW == 0 && !prevInputWas0 {
            Notifier.send(title: "EFStatus", body: "No input power — drawing \(Int(st.outW))W from battery")
        }
        prevInputWas0 = st.inW == 0

        statusItem.button?.title = "EF⚡ \(st.soc)%"
        popup?.update(st)
    }

    // MARK: – Manual refresh (refresh button in popup)

    private func manualRefresh() {
        popup?.setRefreshing()
        restPoll()   // force a REST fetch regardless of MQTT state
    }

    // MARK: – Popup

    @objc private func togglePopup() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showContextMenu(); return }

        if let p = popup, p.isVisible { p.orderOut(nil); return }

        guard let btn = statusItem.button,
              let screen = btn.window?.screen ?? NSScreen.main else { return }

        if popup == nil {
            popup = PopupPanel()
            popup?.onRefresh = { [weak self] in self?.manualRefresh() }
            // Populate with current state if available
            if !deviceState.isEmpty { popup?.update(EcoFlowAPI.parseStatus(from: deviceState)) }
        }

        let btnFrame = btn.window!.convertToScreen(btn.frame)
        let panelW   = popup?.frame.width ?? 220
        var x = btnFrame.midX - panelW / 2
        let y = btnFrame.minY + 2

        x = min(x, screen.visibleFrame.maxX - panelW - 4)
        x = max(x, screen.visibleFrame.minX + 4)

        popup?.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        popup?.orderFrontRegardless()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSetup), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(openRepo), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        let diag = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)

        let help = NSMenuItem(title: "Help & Support", action: #selector(openRepo), keyEquivalent: "")
        help.target = self
        menu.addItem(help)

        let about = NSMenuItem(title: "About EFStatus", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit EFStatus",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: – Actions

    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/bereto-dev/efstatus")!)
    }

    @objc private func copyDiagnostics() {
        guard let api else { Notifier.send(title: "EFStatus", body: "No credentials configured."); return }
        Task {
            do {
                let output = try await api.fetchRawFields()
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                Notifier.send(title: "EFStatus", body: "Diagnostics copied to clipboard.")
            } catch {
                Notifier.send(title: "EFStatus", body: "Failed to fetch diagnostics.")
            }
        }
    }

    @objc private func showAbout() {
        if aboutWin == nil { aboutWin = AboutWindow() }
        NSApp.activate(ignoringOtherApps: true)
        aboutWin?.makeKeyAndOrderFront(nil)
    }

    @objc func showSetup() {
        if setupWin == nil {
            setupWin = SetupWindow()
            setupWin?.onSave = { [weak self] creds in
                guard let self else { return }
                self.mqttClient?.disconnect()
                self.mqttClient = nil
                self.stopRestFallback()
                self.stopWatchdog()
                self.reconnTimer?.invalidate()
                self.connect(creds)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWin?.makeKeyAndOrderFront(nil)
    }
}

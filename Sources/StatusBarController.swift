import Cocoa

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popup:    PopupPanel?
    private var setupWin: SetupWindow?
    private var aboutWin: AboutWindow?

    private var api:          EcoFlowAPI?
    private var mqttClient:   MQTTClient?
    private var deviceState:  [String: Any] = [:]   // merged state: REST fills it, MQTT updates it

    private var pollTimer:    Timer?   // REST fallback when MQTT is down or quiet
    private var reconnTimer:  Timer?   // MQTT reconnect backoff
    private var reconnDelay:  TimeInterval = 5
    private var mqttWanted    = false  // false while swapping credentials / tearing down
    private var mqttLive      = false  // true while MQTT is delivering data
    private var lastMQTTMessageAt: Date?
    private var lastMQTTPacketAt:  Date?
    private var connectGen    = 0

    private var inputLostTimer:     Timer?
    private var inputConfirmedLost = false
    private var prevWasOffline     = false
    private var outsideClickMonitor: Any?
    private var localClickMonitor:   Any?

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [
            "notifyInputLost":     true,
            "notifyInputRestored": true,
        ])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.action = #selector(togglePopup)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        setStatusTitle("—")

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.closePopup()
        }

        if let creds = CredentialsManager.load() { connect(creds) } else { showSetup() }
    }

    // MARK: – Connection entry point

    private func connect(_ creds: Credentials) {
        connectGen += 1
        let gen = connectGen
        api = EcoFlowAPI(accessKey: creds.accessKey, secretKey: creds.secretKey, serial: creds.serial)
        deviceState.removeAll()
        mqttWanted = true
        mqttLive = false
        lastMQTTMessageAt = nil
        lastMQTTPacketAt = nil
        inputLostTimer?.invalidate()
        inputLostTimer = nil
        inputConfirmedLost = false
        prevWasOffline = false

        // 1. REST fetch — immediate display while MQTT connects
        restPoll()

        // 2. Get MQTT credentials and connect
        Task {
            do {
                let mc = try await api!.fetchMQTTCredentials()
                await MainActor.run {
                    guard self.connectGen == gen, self.mqttWanted else { return }
                    self.startMQTT(mc)
                }
            } catch {
                await MainActor.run {
                    guard self.connectGen == gen, self.mqttWanted else { return }
                    self.startRestFallback()
                    self.scheduleReconnect()
                }
            }
        }
    }

    // MARK: – MQTT

    private func startMQTT(_ creds: MQTTCredentials) {
        stopMQTTClient()

        let client = MQTTClient()
        mqttClient = client

        client.onConnect = { [weak self] in
            guard let self, self.mqttWanted else { return }
            self.mqttLive = false
            self.lastMQTTPacketAt = Date()
            self.reconnDelay = 5
            client.subscribe(to: creds.topic)
            self.startMQTTWatchdog()
        }

        client.onActivity = { [weak self] in
            self?.lastMQTTPacketAt = Date()
        }

        client.onMessage = { [weak self] _, json in
            self?.handleMQTTMessage(json)
        }

        client.onDisconnect = { [weak self] _ in
            guard let self, self.mqttWanted else { return }
            self.mqttLive = false
            self.stopWatchdog()
            self.startRestFallback()
            self.scheduleReconnect()
        }

        client.connect(host: creds.url, port: creds.port,
                       username: creds.username, password: creds.password,
                       clientId: creds.clientId)
    }

    private func stopMQTTClient() {
        mqttClient?.onDisconnect = nil
        mqttClient?.onMessage = nil
        mqttClient?.onConnect = nil
        mqttClient?.onActivity = nil
        mqttClient?.disconnect()
        mqttClient = nil
    }

    private func handleMQTTMessage(_ json: [String: Any]) {
        // EcoFlow sends params at the top level or nested under "params"
        let params = json["params"] as? [String: Any] ?? json

        // Filter: only accept numeric leaf values (same as REST quota structure)
        let numeric = params.filter { $0.value is NSNumber }
        guard !numeric.isEmpty else { return }

        EcoFlowAPI.mergeMQTT(numeric, into: &deviceState)

        lastMQTTMessageAt = Date()
        lastMQTTPacketAt = Date()
        mqttLive = true
        startMQTTWatchdog()
        stopRestFallback()

        if prevWasOffline {
            Notifier.send(title: "EFStatus", body: "Device back online")
            prevWasOffline = false
        }

        updateUI(from: deviceState)
    }

    // MARK: – MQTT watchdog (REST backup if MQTT is silent > 30s)

    private var watchdogTimer: Timer?

    private func startMQTTWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.mqttWatchdogFired()
        }
    }

    private func mqttWatchdogFired() {
        let now = Date()
        let dataAge = lastMQTTMessageAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let packetAge = lastMQTTPacketAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        // No PUBLISH for 30s — resume REST so the menu bar cannot sit on stale MQTT data
        if dataAge >= 30 {
            mqttLive = false
            startRestFallback()
        }

        // Half-open socket: keepalive is 60s, pings every 30s. No inbound packet for 90s → reconnect.
        if packetAge >= 90 {
            recoverQuietMQTT()
        }
    }

    private func recoverQuietMQTT() {
        stopWatchdog()
        stopMQTTClient()
        mqttLive = false
        startRestFallback()
        scheduleReconnect()
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: – MQTT reconnect (refresh certification; exponential backoff, max 60s)

    private func scheduleReconnect() {
        guard mqttWanted else { return }
        reconnTimer?.invalidate()
        reconnTimer = Timer.scheduledTimer(withTimeInterval: reconnDelay, repeats: false) { [weak self] _ in
            self?.reconnectMQTT()
        }
        reconnDelay = min(reconnDelay * 2, 60)
    }

    private func reconnectMQTT() {
        guard mqttWanted, let api else { return }
        stopMQTTClient()
        let gen = connectGen
        Task {
            do {
                let mc = try await api.fetchMQTTCredentials()
                await MainActor.run {
                    guard self.connectGen == gen, self.mqttWanted else { return }
                    self.startMQTT(mc)
                }
            } catch {
                await MainActor.run {
                    guard self.connectGen == gen, self.mqttWanted else { return }
                    self.startRestFallback()
                    self.scheduleReconnect()
                }
            }
        }
    }

    // MARK: – REST fallback polling (10s when MQTT is down or quiet)

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

    private func restPoll(force: Bool = false) {
        guard let api else { return }
        let gen = connectGen
        Task {
            do {
                let (quota, _) = try await api.fetchStatus()
                await MainActor.run {
                    guard self.connectGen == gen else { return }
                    if self.mqttLive && !force { return }
                    self.deviceState = quota   // full replacement from REST
                    self.updateUI(from: quota)
                    if self.prevWasOffline {
                        Notifier.send(title: "EFStatus", body: "Device back online")
                    }
                    self.prevWasOffline = false
                }
            } catch {
                await MainActor.run {
                    guard self.connectGen == gen else { return }
                    if self.mqttLive && !force { return }
                    if !self.prevWasOffline {
                        Notifier.send(title: "EFStatus", body: "Lost connection to device")
                    }
                    self.prevWasOffline = true
                    self.setStatusTitle("—")
                    self.popup?.setOffline()
                }
            }
        }
    }

    // MARK: – UI update

    private func updateUI(from state: [String: Any]) {
        let st = EcoFlowAPI.parseStatus(from: state)

        if st.inW == 0 {
            if !inputConfirmedLost && inputLostTimer == nil {
                inputLostTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.inputLostTimer = nil
                    self.inputConfirmedLost = true
                    guard UserDefaults.standard.bool(forKey: "notifyInputLost") else { return }
                    let cur = EcoFlowAPI.parseStatus(from: self.deviceState)
                    Notifier.send(title: "EFStatus", body: "No input power — drawing \(Int(cur.outW)) W from battery")
                }
            }
        } else {
            inputLostTimer?.invalidate()
            inputLostTimer = nil
            if inputConfirmedLost {
                inputConfirmedLost = false
                if UserDefaults.standard.bool(forKey: "notifyInputRestored") {
                    Notifier.send(title: "EFStatus", body: "Input power restored — \(Int(st.inW)) W")
                }
            }
        }

        setStatusTitle(st.socLabel)
        popup?.update(st)
    }

    // MARK: – Manual refresh (refresh button in popup)

    private func manualRefresh() {
        popup?.setRefreshing()
        restPoll(force: true)   // force a REST fetch regardless of MQTT state
    }

    // MARK: – Popup

    @objc private func togglePopup() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showContextMenu(); return }

        if let p = popup, p.isVisible { closePopup(); return }

        guard let btn = statusItem.button,
              let screen = btn.window?.screen ?? NSScreen.main else { return }

        if popup == nil {
            popup = PopupPanel()
            popup?.onRefresh = { [weak self] in self?.manualRefresh() }
            if prevWasOffline {
                popup?.setOffline()
            } else if !deviceState.isEmpty {
                popup?.update(EcoFlowAPI.parseStatus(from: deviceState))
            }
        }

        let btnFrame = btn.window!.convertToScreen(btn.frame)
        let panelW   = popup?.frame.width ?? 220
        var x = btnFrame.midX - panelW / 2
        let y = btnFrame.minY + 2

        x = min(x, screen.visibleFrame.maxX - panelW - 4)
        x = max(x, screen.visibleFrame.minX + 4)

        popup?.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        popup?.orderFrontRegardless()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopup()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.popup && event.window !== self.statusItem.button?.window {
                self.closePopup()
            }
            return event
        }
    }

    private func closePopup() {
        popup?.orderOut(nil)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        if let m = localClickMonitor   { NSEvent.removeMonitor(m); localClickMonitor   = nil }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSetup), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(openUpdates), keyEquivalent: "")
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

    @objc private func openUpdates() {
        NSWorkspace.shared.open(URL(string: "https://bereto.gumroad.com/l/efstatus")!)
    }

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

    // MARK: – Status bar title helper

    private func setStatusTitle(_ value: String) {
        guard let btn = statusItem.button else { return }

        // Build a template image: "EF" text + bolt symbol side by side
        let font = NSFont.menuBarFont(ofSize: 12)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let label = "EF" as NSString
        let textSize = label.size(withAttributes: textAttrs)

        let symCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let boltBase = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symCfg)
        let boltSize = boltBase?.size ?? NSSize(width: 8, height: 13)

        let gap: CGFloat = 1
        let imgW = textSize.width + gap + boltSize.width
        let imgH: CGFloat = 16

        let composite = NSImage(size: NSSize(width: imgW, height: imgH), flipped: false) { _ in
            // Draw "EF" in white
            label.draw(at: NSPoint(x: 0, y: (imgH - textSize.height) / 2),
                       withAttributes: textAttrs)
            // Draw bolt in white
            if let bolt = boltBase {
                NSColor.white.set()
                bolt.draw(in: NSRect(x: textSize.width + gap,
                                     y: (imgH - boltSize.height) / 2,
                                     width: boltSize.width,
                                     height: boltSize.height))
            }
            return true
        }
        composite.isTemplate = true

        btn.image = composite
        btn.imagePosition = .imageLeft
        btn.title = value   // "89%" — uses button's default menu bar font
    }

    @objc func showSetup() {
        if setupWin == nil {
            setupWin = SetupWindow()
            setupWin?.onSave = { [weak self] creds in
                guard let self else { return }
                self.mqttWanted = false
                self.connectGen += 1
                self.stopMQTTClient()
                self.stopRestFallback()
                self.stopWatchdog()
                self.reconnTimer?.invalidate()
                self.reconnTimer = nil
                self.connect(creds)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWin?.makeKeyAndOrderFront(nil)
    }
}

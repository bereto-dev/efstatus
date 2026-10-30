import Cocoa
import os

private let connLog = Logger(subsystem: "com.efstatus.app", category: "connection")

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popup:    PopupPanel?
    private var setupWin: SetupWindow?
    private var aboutWin: AboutWindow?

    // Connection
    private var creds:       Credentials?
    private var api:         EcoFlowAPI?
    private var mqttClient:  MQTTClient?
    private var deviceState: [String: Any] = [:]   // REST seeds it, MQTT updates it
    private var pollKeys:    [String] = []         // relevant keys this device reports
    private var lastStatus:  EFStatus?
    private var connectGen   = 0
    private var mqttWanted   = false
    private var mqttLive     = false               // MQTT is delivering device data
    private var lastMQTTMessageAt: Date?
    private var lastMQTTPacketAt:  Date?           // any inbound packet, incl. PINGRESP
    private var restInFlight = false
    private var restFailures = 0
    private var isOffline    = false
    private var notifiedOffline = false
    private var isAsleep     = false
    private var quietUntil   = Date.distantPast    // no connection alerts during startup / wake
    private var mqttConnectedAt:  Date?            // CONNACK of the current MQTT session
    private var silentReconnects = 0               // reconnects since the feed last delivered data
    private var mqttRawMessages  = 0               // PUBLISH payloads this session
    private var mqttDataMessages = 0               // ...that carried device state

    // Timers
    private var pollTimer:     Timer?
    private var pollInterval:  TimeInterval = 0
    private var watchdogTimer: Timer?
    private var reconnTimer:   Timer?
    private var reconnDelay:   TimeInterval = 5

    // Notification state
    private var sawInput           = false
    private var zeroInputSince:    Date?
    private var inputConfirmedLost = false
    private var verifyingInput     = false
    private var lastSoc:           Int?
    private var lowNotified:       Set<Int> = []
    private var fullNotified       = false
    private var smoothedNet:       Double?
    private var smoothedAt:        Date?

    private var lastTitle = ""
    private var outsideClickMonitor: Any?
    private var localClickMonitor:   Any?

    private enum Tuning {
        static let pollWhenMQTTDown:   TimeInterval = 10
        static let pollWhenMQTTQuiet:  TimeInterval = 60
        static let watchdogInterval:   TimeInterval = 10
        static let mqttQuietAfter:     TimeInterval = 30
        static let mqttDeadAfter:      TimeInterval = 90
        static let mqttSilentAfter:    TimeInterval = 180    // connected, pings answered, no device data
        static let mqttSilentMax:      TimeInterval = 1800
        static let inputLostAfter:     TimeInterval = 10
        static let failuresForOffline  = 3
        static let connectionGrace:    TimeInterval = 30
        static let lowBatteryLevels    = [20, 10]
    }

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.action = #selector(togglePopup)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.image = Self.makeStatusImage()
            btn.imagePosition = .imageLeft
        }
        setStatusTitle("—")

        NotificationCenter.default.addObserver(self, selector: #selector(closePopup),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(didWake),   name: NSWorkspace.didWakeNotification,   object: nil)

        if let c = CredentialsManager.load() { connect(c) } else { showSetup() }
    }

    // MARK: – Connection lifecycle

    private func connect(_ c: Credentials) {
        teardown()
        creds = c
        api = EcoFlowAPI(accessKey: c.accessKey, secretKey: c.secretKey, serial: c.serial)
        deviceState.removeAll()
        pollKeys = []
        mqttWanted = true
        reconnDelay = 5
        restFailures = 0
        silentReconnects = 0
        connLog.notice("Connecting to EcoFlow")
        quietUntil = Date().addingTimeInterval(Tuning.connectionGrace)
        resetTracking()

        restPoll(full: true)
        startWatchdog()
        startMQTTSession()
    }

    private func teardown() {
        connectGen += 1
        mqttWanted = false
        stopMQTTClient()
        setPollInterval(0)
        watchdogTimer?.invalidate(); watchdogTimer = nil
        reconnTimer?.invalidate();   reconnTimer = nil
        restInFlight = false
    }

    private func resetTracking() {
        sawInput = false
        zeroInputSince = nil
        inputConfirmedLost = false
        verifyingInput = false
        lastSoc = nil
        lowNotified = []
        fullNotified = false
        smoothedNet = nil
        smoothedAt = nil
    }

    @objc private func willSleep() {
        connLog.notice("Sleep: closing connections")
        isAsleep = true
        teardown()
    }

    @objc private func didWake() {
        connLog.notice("Wake: reconnecting in 3 s")
        isAsleep = false
        // Give Wi-Fi a moment to come back before reconnecting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.isAsleep, let c = self.creds else { return }
            self.connect(c)
        }
    }

    // MARK: – MQTT

    private func startMQTTSession() {
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
                    self.updatePolling()
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func startMQTT(_ mc: MQTTCredentials) {
        let client = MQTTClient()
        mqttClient = client

        client.onConnect = { [weak self, weak client] in
            guard let self, self.mqttWanted else { return }
            self.lastMQTTPacketAt = Date()
            self.mqttConnectedAt = Date()
            self.mqttRawMessages = 0
            self.mqttDataMessages = 0
            self.reconnDelay = 5
            client?.subscribe(to: mc.topic)
            self.updatePolling()
        }
        client.onActivity = { [weak self] in
            self?.lastMQTTPacketAt = Date()
        }
        client.onMessage = { [weak self] _, json in
            self?.handleMQTTMessage(json)
        }
        client.onDisconnect = { [weak self] _ in
            guard let self, self.mqttWanted else { return }
            self.mqttClient = nil
            self.mqttLive = false
            self.lastMQTTPacketAt = nil
            self.updatePolling()
            self.scheduleReconnect()
        }

        client.connect(host: mc.url, port: mc.port,
                       username: mc.username, password: mc.password, clientId: mc.clientId)
    }

    private func stopMQTTClient() {
        guard let c = mqttClient else { return }
        c.onDisconnect = nil
        c.onMessage = nil
        c.onConnect = nil
        c.onActivity = nil
        c.disconnect()
        mqttClient = nil
        mqttLive = false
        lastMQTTPacketAt = nil
        mqttConnectedAt = nil
    }

    private func handleMQTTMessage(_ json: [String: Any]) {
        mqttRawMessages += 1
        guard let fields = EcoFlowAPI.normalizeMQTT(json) else { return }
        mqttDataMessages += 1
        silentReconnects = 0
        for (k, v) in fields { deviceState[k] = v }
        lastMQTTMessageAt = Date()
        if !mqttLive {
            mqttLive = true
            updatePolling()
        }
        markOnline()
        updateUI()
    }

    private func scheduleReconnect() {
        guard mqttWanted else { return }
        reconnTimer?.invalidate()
        reconnTimer = makeTimer(reconnDelay, repeats: false) { [weak self] in self?.startMQTTSession() }
        reconnDelay = min(reconnDelay * 2, 60)
    }

    // MARK: – Watchdog (one timer for the whole session)

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = makeTimer(Tuning.watchdogInterval, repeats: true) { [weak self] in self?.watchdogTick() }
    }

    private func watchdogTick() {
        guard !isAsleep else { return }
        let now = Date()
        if mqttLive, let t = lastMQTTMessageAt, now.timeIntervalSince(t) >= Tuning.mqttQuietAfter {
            mqttLive = false
        }
        // Half-open socket: pings go out every 30s, so 90s of silence means it's dead.
        if mqttClient != nil, let p = lastMQTTPacketAt, now.timeIntervalSince(p) >= Tuning.mqttDeadAfter {
            connLog.notice("Live feed half-open, no packets for \(Int(Tuning.mqttDeadAfter), privacy: .public) s; reconnecting")
            stopMQTTClient()
            scheduleReconnect()
        }
        // Connected and answering pings, yet no device data. Seen after a sleep/wake: the session
        // stayed up for hours delivering nothing while the app sat on the 60 s REST fallback.
        // Reconnect as a relaunch would, backing off so a genuinely idle device isn't hammered.
        if mqttClient != nil, let up = mqttConnectedAt,
           Self.feedIsSilent(now: now, connectedAt: up, lastDataAt: lastMQTTMessageAt, silentReconnects: silentReconnects) {
            connLog.notice("Live feed silent: \(self.mqttRawMessages, privacy: .public) messages, \(self.mqttDataMessages, privacy: .public) with device data this session; silent reconnect #\(self.silentReconnects + 1, privacy: .public)")
            silentReconnects += 1
            stopMQTTClient()
            scheduleReconnect()
        }
        updatePolling()
        evaluateInput()
    }

    /// True once a live-feed session has gone the silence limit without device data, measured from
    /// the later of connect and last data. The limit doubles per silent reconnect: 3, 6, 12, 24, then 30 min.
    static func feedIsSilent(now: Date, connectedAt: Date, lastDataAt: Date?, silentReconnects: Int) -> Bool {
        let limit = min(Tuning.mqttSilentAfter * pow(2, Double(min(silentReconnects, 8))), Tuning.mqttSilentMax)
        let since = max(connectedAt, lastDataAt ?? connectedAt)
        return now.timeIntervalSince(since) >= limit
    }

    // MARK: – REST polling (only when MQTT isn't delivering)

    private func updatePolling() {
        let want: TimeInterval
        if mqttLive                      { want = 0 }
        else if lastMQTTPacketAt != nil  { want = Tuning.pollWhenMQTTQuiet }   // connected, device idle
        else                             { want = Tuning.pollWhenMQTTDown }
        setPollInterval(want)
    }

    private func setPollInterval(_ want: TimeInterval) {
        guard want != pollInterval else { return }
        let wasPolling = pollInterval > 0
        pollTimer?.invalidate(); pollTimer = nil
        pollInterval = want
        guard want > 0 else { return }
        pollTimer = makeTimer(want, repeats: true) { [weak self] in self?.restPoll() }
        if !wasPolling { restPoll() }
    }

    private func restPoll(full: Bool = false, completion: ((EFStatus?) -> Void)? = nil) {
        guard let api, !isAsleep, !restInFlight else { completion?(nil); return }
        restInFlight = true
        let gen = connectGen
        let keys: [String]? = (full || pollKeys.isEmpty) ? nil : pollKeys
        Task {
            do {
                let q: [String: Any]
                if let keys { q = try await api.fetchQuota(keys: keys) } else { q = try await api.fetchAllQuota() }
                await MainActor.run {
                    guard self.connectGen == gen else { return }
                    self.restInFlight = false
                    if keys == nil {
                        self.deviceState = q
                        self.pollKeys = EcoFlowAPI.relevantKeys.filter { q[$0] != nil }
                    } else if q.isEmpty {
                        self.pollKeys = []   // selective query unsupported; fall back to full
                    } else {
                        for (k, v) in q { self.deviceState[k] = v }
                    }
                    self.restFailures = 0
                    self.markOnline()
                    completion?(self.updateUI())
                }
            } catch {
                await MainActor.run {
                    guard self.connectGen == gen else { return }
                    self.restInFlight = false
                    self.restFailures += 1
                    if self.restFailures >= Tuning.failuresForOffline && !self.mqttLive { self.markOffline() }
                    completion?(nil)
                }
            }
        }
    }

    // MARK: – Online / offline

    private func markOnline() {
        guard isOffline else { return }
        isOffline = false
        if notifiedOffline {
            notifiedOffline = false
            Notifier.send(.connection, "Connection to your EcoFlow restored")
        }
    }

    private func markOffline() {
        guard !isOffline else { return }
        isOffline = true
        zeroInputSince = nil
        setStatusTitle("—")
        popup?.setOffline()
        if Date() >= quietUntil {
            notifiedOffline = true
            Notifier.send(.connection, "Lost connection to your EcoFlow")
        }
    }

    // MARK: – UI + notifications

    @discardableResult
    private func updateUI() -> EFStatus {
        var st = EcoFlowAPI.parseStatus(from: deviceState)

        // ~60s time-based average of net watts for time estimates (MQTT can deliver
        // several readings a second); snap when the direction flips (plug/unplug).
        let raw = st.batteryW ?? (st.inW - st.outW)
        let now = Date()
        if let s = smoothedNet, let at = smoothedAt, (s > 0) == (raw > 0) {
            let alpha = 1 - exp(-now.timeIntervalSince(at) / 60)
            smoothedNet = s + alpha * (raw - s)
        } else {
            smoothedNet = raw
        }
        smoothedAt = now
        st.smoothedNetW = smoothedNet

        lastStatus = st
        evaluateInput(st)
        evaluateBattery(st)
        setStatusTitle(st.socLabel)
        if popup?.isVisible == true { popup?.update(st) }
        return st
    }

    // "No input power" needs: input seen earlier, ≥10s at 0 W, then a fresh full REST read
    // that still says 0 W. Single MQTT packets can't trigger it.
    private func evaluateInput(_ current: EFStatus? = nil) {
        guard let st = current ?? lastStatus, !isOffline else { return }
        if st.inW > 0 {
            sawInput = true
            zeroInputSince = nil
            if inputConfirmedLost {
                inputConfirmedLost = false
                if NotificationPref.inputRestored.isOn {
                    Notifier.send(.input, "Input power restored — \(Int(st.inW)) W")
                }
            }
            return
        }
        guard sawInput, !inputConfirmedLost, !verifyingInput else { return }
        let since = zeroInputSince ?? Date()
        zeroInputSince = since
        guard Date().timeIntervalSince(since) >= Tuning.inputLostAfter else { return }

        verifyingInput = true
        restPoll(full: true) { [weak self] verified in
            guard let self else { return }
            self.verifyingInput = false
            guard let v = verified, v.inW == 0, !self.inputConfirmedLost else { return }
            self.inputConfirmedLost = true
            if NotificationPref.inputLost.isOn {
                Notifier.send(.input, "No input power — drawing \(Int(v.outW)) W from battery")
            }
        }
    }

    private func evaluateBattery(_ st: EFStatus) {
        guard let soc = st.soc else { return }
        defer { lastSoc = soc }
        guard let prev = lastSoc else { return }

        for level in Tuning.lowBatteryLevels {
            if soc >= level + 5 { lowNotified.remove(level) }
            guard soc <= level, prev > level, !lowNotified.contains(level), st.inW < st.outW else { continue }
            lowNotified.insert(level)
            if NotificationPref.lowBattery.isOn {
                let left = st.timeToEmptyMin.map { " — about \(st.fmtTime($0)) left" } ?? ""
                Notifier.send(.battery, "Battery low: \(soc)%\(left)")
            }
        }

        if soc <= 95 { fullNotified = false }
        if soc >= 100, prev < 100, !fullNotified {
            fullNotified = true
            if NotificationPref.fullCharge.isOn { Notifier.send(.battery, "Fully charged — 100%") }
        }
    }

    private func manualRefresh() {
        popup?.setRefreshing()
        restPoll(full: true) { [weak self] st in
            guard let self, st == nil else { return }
            if let s = self.lastStatus, !self.isOffline { self.popup?.update(s) } else { self.popup?.setOffline() }
        }
    }

    // MARK: – Popup

    @objc private func togglePopup() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp { showContextMenu(); return }

        if let p = popup, p.isVisible { closePopup(); return }

        guard let btn = statusItem.button, let btnWindow = btn.window,
              let screen = btnWindow.screen ?? NSScreen.main else { return }

        if popup == nil {
            popup = PopupPanel()
            popup?.onRefresh = { [weak self] in self?.manualRefresh() }
        }
        if isOffline {
            popup?.setOffline()
        } else if let st = lastStatus {
            popup?.update(st)
        }

        let btnFrame = btnWindow.convertToScreen(btn.frame)
        let panelW   = popup?.frame.width ?? 220
        var x = btnFrame.midX - panelW / 2
        x = min(x, screen.visibleFrame.maxX - panelW - 4)
        x = max(x, screen.visibleFrame.minX + 4)

        popup?.setFrameTopLeftPoint(NSPoint(x: x, y: btnFrame.minY + 2))
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

    @objc private func closePopup() {
        popup?.orderOut(nil)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        if let m = localClickMonitor   { NSEvent.removeMonitor(m); localClickMonitor   = nil }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
        }
        item("Settings…", #selector(showSetup), ",")
        item("Check for Updates…", #selector(checkForUpdates))
        item("Copy Diagnostics", #selector(copyDiagnostics))
        item("Help & Support", #selector(openRepo))
        item("About EFStatus", #selector(showAbout))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EFStatus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: – Actions

    @objc private func checkForUpdates() {
        MainActor.assumeIsolated { Updater.shared.checkForUpdates() }
    }

    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/bereto-dev/efstatus")!)
    }

    @objc private func copyDiagnostics() {
        guard let api else { Notifier.send(.app, "No credentials configured."); return }
        Task {
            do {
                let output = try await api.fetchRawFields()
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                Notifier.send(.app, "Diagnostics copied to clipboard.")
            } catch {
                Notifier.send(.app, "Failed to fetch diagnostics.")
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
            setupWin?.onSave = { [weak self] creds in self?.connect(creds) }
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWin?.makeKeyAndOrderFront(nil)
    }

    // MARK: – Helpers

    private func setStatusTitle(_ value: String) {
        guard value != lastTitle else { return }
        lastTitle = value
        statusItem.button?.title = value
    }

    private func makeTimer(_ interval: TimeInterval, repeats: Bool, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: repeats) { _ in block() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private static func makeStatusImage() -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 12)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let label = "EF" as NSString
        let textSize = label.size(withAttributes: textAttrs)

        let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        let boltSize = bolt?.size ?? NSSize(width: 8, height: 13)

        let gap: CGFloat = 1
        let imgH: CGFloat = 16
        let image = NSImage(size: NSSize(width: textSize.width + gap + boltSize.width, height: imgH), flipped: false) { _ in
            label.draw(at: NSPoint(x: 0, y: (imgH - textSize.height) / 2), withAttributes: textAttrs)
            bolt?.draw(in: NSRect(x: textSize.width + gap, y: (imgH - boltSize.height) / 2,
                                  width: boltSize.width, height: boltSize.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}

import AppKit
import CryptoKit
import Security

final class Pin: NSObject, URLSessionDelegate, @unchecked Sendable {
    let fingerprint: String

    init(_ fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            Diagnostics.shared.record("tls certificate unavailable")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        guard hash == fingerprint else {
            Diagnostics.shared.record("tls fingerprint mismatch")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum Response {
    case http(Int)
    case failure(URLError.Code)

    var description: String {
        switch self {
        case .http(let status): return "HTTP \(status)"
        case .failure(let code): return "URLError \(code.rawValue)"
        }
    }
}

final class Connection {
    let url: URL
    let code: String
    let fingerprint: String
    let session: URLSession
    private var inFlight = false
    private var afterSend: (() -> Void)?

    init(url: URL, code: String, fingerprint: String) {
        self.url = url
        self.code = code
        self.fingerprint = fingerprint
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        session = URLSession(configuration: config, delegate: Pin(fingerprint), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ events: [Input], completion: @escaping (Response) -> Void) {
        perform(method: "POST", body: try? JSONEncoder().encode(events), timeout: events.isEmpty ? 3 : 1.5,
                completion: completion)
    }

    func perform(method: String, body: Data? = nil, timeout: Double = 3, completion: @escaping (Response) -> Void) {
        performData(method: method, body: body, timeout: timeout) { response, _ in completion(response) }
    }

    func performData(method: String, body: Data? = nil, timeout: Double = 3, endpoint: URL? = nil,
                     completion: @escaping (Response, Data?) -> Void) {
        var request = URLRequest(url: endpoint ?? url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if !code.isEmpty { request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        inFlight = true
        session.dataTask(with: request) { [self] data, response, error in
            let result: Response
            if let error {
                result = .failure((error as? URLError)?.code ?? .unknown)
            } else if let response = response as? HTTPURLResponse {
                result = .http(response.statusCode)
            } else {
                result = .failure(.badServerResponse)
            }
            DispatchQueue.main.async {
                self.inFlight = false
                let followUp = self.afterSend
                self.afterSend = nil
                completion(result, data)
                followUp?()
            }
        }.resume()
    }

    func releaseWhenIdle(completion: @escaping () -> Void) {
        let release = {
            self.send([Input(kind: "release")]) { result in
                Diagnostics.shared.record("disconnect release \(result.description)")
                completion()
            }
        }
        if inFlight {
            afterSend = release
        } else {
            release()
        }
    }
}

final class ConectorApp: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let status = NSMenuItem(title: "Отключено", action: nil, keyEquivalent: "")
    var connection: Connection?
    var channel: InputChannel?
    var captureID: UInt64 = 0
    var captureFrames = 0
    var capturePeakQueue = 0
    var capturePeakWrite: UInt64 = 0
    var reconnect: ConnectionWindow.Credentials?
    var retryAt: Date?
    var retryDelay: TimeInterval = 3
    var reconnectPaused = false
    let discovery = Discovery()
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var timer: Timer?
    var sending = false
    var ready = false
    var linked = false
    var releasing: Connection?
    var quitting = false
    var paused = false
    var window: ConnectionWindow!
    var pauseItem: NSMenuItem!
    var lockItem: NSMenuItem!
    var disconnectItem: NSMenuItem!
    var inputState: Bool?
    var attemptedTap = false
    var lastInputCheck = Date.distantPast
    var edgePush: Int32 = 0
    var lastEdgePush = Date.distantPast
    let log = Diagnostics.shared
    let profiles = Profiles()
    let controlSettings = ControlSettings()
    let cue = HandoffCue()
    var keyboard = RemoteKeyboard(commandIsControl: true)
    var pointer = PointerMotion(speed: 1)
    var scrollMotion = ScrollMotion(smoothness: 0.6)
    var swipeDetector = ThreeFingerSwipeDetector()
    var capturedBounds = CGRect.zero
    var lastWarp = Date.distantPast
    var lastActivateAttempt = Date.distantPast
    var captureAnchor: NSPanel?
    var handoffConfirmed = false
    var remote = false
    var previousApp: NSRunningApplication?
    var cursorHidden = false
    var cursorDetached = false
    var pending: [Input] = []
    var entry = CGPoint.zero
    var lastSend = Date.distantPast
    var localButtons: Set<UInt16> = []
    var localKeys: Set<Int64> = []
    var lastClipboardChangeCount = NSPasteboard.general.changeCount
    var lastClipboardCheck = Date.distantPast
    var lastSyncedClipboardHash: Data?
    var macLocked = false
    var lastSentAwake: Bool?
    var lockObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        log.record("startup version=\(version) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        installMainMenu()
        window = ConnectionWindow(owner: self)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let symbol = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Conector-M-W") {
            symbol.isTemplate = true
            item.button?.image = symbol
        } else {
            item.button?.title = "Conector-M-W"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(menuItem("Открыть Conector-M-W", action: #selector(showWindow)))
        pauseItem = menuItem("Приостановить управление", action: #selector(togglePause))
        lockItem = menuItem("Заблокировать Windows", action: #selector(lockWindows))
        disconnectItem = menuItem("Отключить Windows", action: #selector(disconnect))
        menu.addItem(pauseItem)
        menu.addItem(lockItem)
        menu.addItem(disconnectItem)
        menu.addItem(.separator())
        menu.addItem(updateItem)
        menu.addItem(menuItem("Скопировать журнал", action: #selector(copyDiagnostics)))
        menu.addItem(menuItem("Выйти из Conector-M-W", action: #selector(quit)))
        item.menu = menu

        timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        display(.idle)
        refreshPermissions()
        showWindow()
        window.updateProfiles(profiles.items, selected: profiles.last)
        discovery.didChange = { [weak self] peers in
            guard let self else { return }
            self.window.updateNearby(peers.count)
            if self.connection == nil, let reconnect = self.reconnect,
               peers.contains(where: { $0.fingerprint == reconnect.fingerprint }) {
                self.retryAt = Date()
            }
        }
        if let profile = profiles.last, selectProfile(profile), controlSettings.autoConnect {
            reconnect = window.credentials()
            retryAt = Date().addingTimeInterval(1.2)
        }
        discovery.start()
        window.model.updates.onChange = { [weak self] in self?.refreshUpdateItem() }
        window.model.updates.start()
        installLockObservers()
    }

    func installLockObservers() {
        let distributed = DistributedNotificationCenter.default()
        lockObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.handleMacLocked()
        })
        lockObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.handleMacUnlocked()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        lockObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMacLocked()
        })
        lockObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMacUnlocked()
        })
    }

    func handleMacLocked() {
        macLocked = true
        if remote { leave(reason: "Mac locked") }
        syncAwakeIfNeeded()
        if linked && controlSettings.lockWindowsOnMacLock {
            lockWindows()
        }
    }

    func handleMacUnlocked() {
        macLocked = false
        syncAwakeIfNeeded()
    }

    func syncAwakeIfNeeded() {
        guard linked, let channel, channel.ready else { return }
        let desired = !macLocked && controlSettings.keepWindowsAwake
        guard desired != lastSentAwake else { return }
        lastSentAwake = desired
        channel.sendAwake(desired)
    }

    @objc func lockWindows() {
        guard let active = connection,
              var components = URLComponents(url: active.url, resolvingAgainstBaseURL: false) else { return }
        components.path = "/power/lock"
        guard let lockURL = components.url else { return }
        if remote { leave(reason: "lock windows") }
        let powerConnection = Connection(url: lockURL, code: powerCode(accessCode: active.code), fingerprint: active.fingerprint)
        powerConnection.perform(method: "POST") { [weak self] result in
            self?.log.record("lock windows \(result.description)")
        }
    }

    lazy var updateItem: NSMenuItem = menuItem("Проверить обновления…", action: #selector(showUpdates))

    func refreshUpdateItem() {
        let available = window.model.updates.available
        updateItem.title = available.map { "Установить Conector-M-W \($0.version.description)…" } ?? "Проверить обновления…"
    }

    /// Opens the settings pane, where the update section lives, and checks if nothing is pending.
    @objc func showUpdates() {
        showWindow()
        window.model.pane = .settings
        if window.model.updates.available == nil { window.model.updates.check() }
    }

    /// Quits after an update was installed; the relaunch helper opens the new copy.
    func quitForUpdate() {
        NSApp.terminate(nil)
    }

    func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    func installMainMenu() {
        let bar = NSMenu()
        let appMenu = NSMenu(title: "Conector-M-W")
        appMenu.addItem(menuItem("Открыть Conector-M-W", action: #selector(showWindow), key: ","))
        appMenu.addItem(menuItem("Закрыть окно", action: #selector(closeWindow), key: "w"))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Выйти из Conector-M-W", action: #selector(quit), key: "q"))
        let appEntry = NSMenuItem()
        appEntry.submenu = appMenu
        bar.addItem(appEntry)

        let edit = NSMenu(title: "Правка")
        for (title, action, key) in [("Вырезать", #selector(NSText.cut(_:)), "x"),
                                     ("Копировать", #selector(NSText.copy(_:)), "c"),
                                     ("Вставить", #selector(NSText.paste(_:)), "v"),
                                     ("Выбрать всё", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editEntry = NSMenuItem()
        editEntry.submenu = edit
        bar.addItem(editEntry)
        NSApp.mainMenu = bar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    @objc func showWindow() {
        if remote { leave(reason: "window opened") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func closeWindow() { window.orderOut(nil) }

    @discardableResult
    func selectProfile(_ profile: PCProfile) -> Bool {
        cancelAutomaticConnection()
        var secrets: PCSecrets?
        do {
            secrets = try profiles.load(profile.id)
        } catch {
            log.record("keychain load failed code=\((error as NSError).code)")
        }
        window.loadProfile(profile, secrets: secrets)
        return secrets != nil
    }

    func forgetProfile(_ profile: PCProfile) -> Bool {
        do {
            try profiles.forget(profile.id)
            window.updateProfiles(profiles.items, selected: nil)
            log.record("profile forgotten")
            return true
        } catch {
            log.record("keychain delete failed code=\((error as NSError).code)")
            window.notice = "Не удалось удалить сохранённые данные из Связки ключей."
            return false
        }
    }

    @discardableResult
    func renameProfile(_ profile: PCProfile, to name: String) -> PCProfile? {
        do {
            guard let renamed = try profiles.rename(profile.id, to: name) else { return nil }
            let selected = profiles.items.first { $0.id == window.model.profileID }
            window.updateProfiles(profiles.items, selected: selected)
            if let saved = reconnect, saved.id == renamed.id {
                reconnect = ConnectionWindow.Credentials(id: saved.id, name: renamed.name, host: saved.host,
                                                         code: saved.code, fingerprint: saved.fingerprint)
            }
            log.record("profile renamed")
            return renamed
        } catch {
            window.notice = "Не удалось сохранить новое имя ПК."
            return nil
        }
    }

    func cancelAutomaticConnection() {
        reconnect = nil
        retryAt = nil
        retryDelay = 3
        reconnectPaused = false
    }

    @objc func connect() {
        guard connection == nil, releasing == nil else { return }
        cancelAutomaticConnection()
        guard let credentials = window.credentials() else {
            log.record("connect blocked invalid form")
            return
        }
        beginConnection(credentials)
    }

    func pair(_ peer: NearbyPC, code: PairingCode) {
        guard connection == nil, releasing == nil else { return }
        cancelAutomaticConnection()
        guard peer.fingerprint.hasPrefix(code.prefix) else {
            display(.error("Код не совпадает с выбранным ПК. Проверь имя ПК и код в окне Conector-M-W Receiver."))
            return
        }
        guard let endpoint = URL(string: "https://\(peer.host):43821/pair"),
              let body = try? JSONEncoder().encode(["pin": code.pin]) else { return }
        display(.connecting)
        let attempt = Connection(url: endpoint, code: "", fingerprint: peer.fingerprint)
        connection = attempt
        attempt.performData(method: "POST", body: body) { [weak self, weak attempt] result, body in
            guard let self, let attempt, self.connection === attempt else { return }
            self.log.record("pair result \(result.description)")
            self.connection = nil
            switch result {
            case .http(200):
                let values = body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                guard let token = values?["code"], token.utf8.count == 32,
                      token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    self.display(.error("Приёмник вернул некорректные данные сопряжения."))
                    return
                }
                let existing = self.profiles.items.first { $0.receiverID == peer.fingerprint }
                    ?? self.profiles.items.first {
                        $0.receiverID == nil && $0.host == peer.host &&
                            (try? self.profiles.load($0.id))?.fingerprint == peer.fingerprint
                    }
                let credentials = ConnectionWindow.Credentials(id: existing?.id,
                    name: existing?.name ?? String(peer.name.prefix(60)), host: peer.host,
                    code: token, fingerprint: peer.fingerprint)
                self.window.fillCredentials(credentials)
                self.beginConnection(credentials)
            case .http(401):
                self.display(.error("Код использован, истёк или введён неверно. Возьми новый код в меню Conector-M-W в трее Windows."))
            default:
                self.display(.error(self.connectionMessage(result)))
            }
        }
    }

    func beginConnection(_ saved: ConnectionWindow.Credentials) {
        guard connection == nil, releasing == nil else { return }
        let peer = discovery.computers.first { $0.fingerprint == saved.fingerprint }
        let credentials = saved.atHost(peer?.host ?? saved.host)
        guard let url = URL(string: "https://\(credentials.host):43821/input"),
              let device = URL(string: "https://\(credentials.host):43821/device") else { return }
        let attempt = Connection(url: url, code: credentials.code, fingerprint: credentials.fingerprint)
        connection = attempt
        display(.connecting)
        log.record("connect started")
        attempt.performData(method: "GET", endpoint: device) { [weak self, weak attempt] result, data in
            guard let self, let attempt, self.connection === attempt else { return }
            self.log.record("device probe \(result.description)")
            switch result {
            case .http(200):
                let capabilities = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                guard capabilities?["stream"] == "1", let stream = InputChannel(connection: attempt) else {
                    self.connectionFailed(.failure(.badServerResponse))
                    return
                }
                let wake = WakeTarget(mac: capabilities?["mac"] ?? "", broadcast: capabilities?["broadcast"] ?? "")
                self.channel = stream
                stream.onMessage = { [weak self, weak stream] event in
                    guard let self, let stream, self.channel === stream else { return }
                    if event.type == "ready", !self.linked {
                        self.finishConnection(credentials, wake: wake)
                    } else {
                        self.handleChannelMessage(event)
                    }
                }
                stream.onFailure = { [weak self, weak stream] result in
                    guard let self, let stream, self.channel === stream else { return }
                    self.connectionFailed(result)
                }
                stream.start()
            case .http(404):
                attempt.send([]) { [weak self, weak attempt] result in
                    guard let self, let attempt, self.connection === attempt else { return }
                    if case .http(204) = result {
                        self.finishConnection(credentials, wake: nil)
                    } else {
                        self.connectionFailed(result)
                    }
                }
            default:
                self.connectionFailed(result)
            }
        }
    }

    func finishConnection(_ credentials: ConnectionWindow.Credentials, wake: WakeTarget?) {
        log.record(channel == nil ? "connection ready legacy HTTPS" : "connection ready WebSocket")
        UserDefaults.standard.set(credentials.host, forKey: "address")
        linked = true
        paused = reconnectPaused
        reconnectPaused = false
        attemptedTap = false
        lastSend = Date()
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        lastSyncedClipboardHash = nil
        lastSentAwake = nil
        retryDelay = 3
        refreshPermissions()
        updateControlStatus()
        syncAwakeIfNeeded()
        do {
            let saved = try profiles.remember(name: credentials.name, host: credentials.host,
                                               id: credentials.id, secrets: PCSecrets(code: credentials.code,
                                               fingerprint: credentials.fingerprint), wake: wake)
            window.updateProfiles(profiles.items, selected: saved)
            window.updateAddress(saved.host)
            if controlSettings.autoConnect {
                reconnect = ConnectionWindow.Credentials(id: saved.id, name: saved.name, host: saved.host,
                    code: credentials.code, fingerprint: credentials.fingerprint)
            }
        } catch {
            log.record("keychain save failed code=\((error as NSError).code)")
            window.notice = "Подключение работает. Связка ключей не сохранила данные для следующего запуска."
        }
    }

    func connectionFailed(_ result: Response) {
        log.record("connection lost \(result.description)")
        let wasPaused = paused || reconnectPaused
        stop()
        switch result {
        case .failure(.serverCertificateUntrusted), .failure(.serverCertificateHasUnknownRoot),
             .failure(.secureConnectionFailed), .failure(.userCancelledAuthentication), .failure(.cancelled):
            if reconnect != nil && controlSettings.autoConnect {
                reconnectPaused = wasPaused
                retryAt = nil
                display(.error("Сохранённый адрес ответил с другой подписью. Ждём обнаружения твоего ПК по его отпечатку."))
                return
            }
        case .failure(.timedOut), .failure(.cannotConnectToHost), .failure(.notConnectedToInternet),
             .failure(.networkConnectionLost), .failure(.cannotFindHost), .http(409):
            if reconnect != nil && controlSettings.autoConnect {
                reconnectPaused = wasPaused
                retryAt = Date().addingTimeInterval(retryDelay)
                retryDelay = min(retryDelay * 2, 20)
                display(.error(connectionMessage(result) + " Conector-M-W попробует подключиться снова."))
                return
            }
        default: break
        }
        cancelAutomaticConnection()
        display(.error(connectionMessage(result)))
    }

    func handleChannelMessage(_ message: ChannelMessage) {
        switch message.type {
        case "entered" where remote && message.capture == captureID:
            handoffConfirmed = true
            if controlSettings.animate { cue.show(at: entry, entering: true) }
        case "returned" where remote && message.capture == captureID:
            leave(reason: "Windows edge")
        case "clipboard":
            if let text = message.text { applyRemoteClipboard(text) }
        case "clipboardImage":
            if let image = message.image { applyRemoteClipboardImage(image) }
        case "inputUnavailable": connectionFailed(.http(503))
        case "invalid": connectionFailed(.failure(.cannotParseResponse))
        default: break
        }
    }

    func connectionMessage(_ result: Response) -> String {
        switch result {
        case .http(401):
            return "Код доступа не подошёл. Скопируй его заново из пункта «Данные для ручного подключения…» в трее Windows."
        case .http(409):
            return "Другой Mac уже держит канал управления этим ПК. Отключи его и попробуй снова."
        case .http(503):
            return "Windows не смогла принять ввод. Проверь, что рабочий стол Windows разблокирован."
        case .failure(.serverCertificateUntrusted), .failure(.serverCertificateHasUnknownRoot),
             .failure(.secureConnectionFailed), .failure(.userCancelledAuthentication), .failure(.cancelled):
            return "Не удалось подтвердить сертификат. Сверь отпечаток с пунктом «Данные для ручного подключения…» в трее Windows."
        case .failure(.timedOut), .failure(.cannotConnectToHost), .failure(.notConnectedToInternet),
             .failure(.networkConnectionLost):
            return result.unreachableHint ?? "Приёмник не ответил. Проверь IP, локальную сеть и доступ Conector-M-W к ней в настройках macOS."
        default:
            return "Получен неожиданный ответ (\(result.description)). Проверь журнал приёмника в трее Windows и журнал Conector-M-W."
        }
    }

    @objc func openPrivacy() {
        openSettings("Privacy_Accessibility", name: "accessibility")
    }

    @objc func openInputMonitoring() {
        openSettings("Privacy_ListenEvent", name: "input monitoring")
    }

    func openSettings(_ pane: String, name: String) {
        log.record("settings requested \(name)")
        guard let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
              NSWorkspace.shared.open(settings) else {
            window.notice = "Открой вручную «Системные настройки → Конфиденциальность и безопасность»."
            return
        }
    }

    @objc func recheckPermissions() {
        log.record("permissions recheck requested")
        attemptedTap = false
        refreshPermissions()
        if linked { updateControlStatus() }
    }

    func refreshPermissions() {
        let allowed = AXIsProcessTrusted()
        let monitoring = CGPreflightListenEventAccess()
        let changed = inputState != allowed || window.inputMonitoring != monitoring
        if changed {
            log.record("permissions accessibility=\(allowed) inputMonitoring=\(monitoring)")
            inputState = allowed
            attemptedTap = false
            window.setPermissions(accessibility: allowed, monitoring: monitoring)
        }
        let wasReady = ready
        if !allowed {
            if ready { leave(reason: "accessibility revoked") }
            ready = false
            removeTap()
        } else if linked && !paused && tap == nil && !attemptedTap {
            attemptedTap = true
            ready = installTap()
            log.record("input tap installed=\(ready)")
        }
        if linked && (changed || wasReady != ready) { updateControlStatus() }
    }

    @objc func togglePause() {
        guard linked else { return }
        paused.toggle()
        log.record(paused ? "control paused" : "control resumed")
        if paused {
            leave(reason: "paused")
            ready = false
            removeTap()
            localKeys.removeAll()
            localButtons.removeAll()
        } else {
            attemptedTap = false
            refreshPermissions()
        }
        updateControlStatus()
    }

    @objc func copyDiagnostics() {
        let text = log.recent()
        guard !text.isEmpty else {
            window.notice = "Журнал пока недоступен. Попробуй после подключения."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        window.notice = "Последние записи журнала скопированы."
    }

    @objc func revealDiagnostics() {
        log.drain()
        NSWorkspace.shared.activateFileViewerSelecting([log.file])
    }

    func display(_ state: ConnectionWindow.State) {
        status.title = state.title
        pauseItem.isEnabled = linked
        pauseItem.title = paused ? "Возобновить управление" : "Приостановить управление"
        lockItem.isEnabled = linked
        disconnectItem.isEnabled = connection != nil
        window.render(state)
    }

    func updateControlStatus() {
        if remote {
            display(.remote)
        } else if paused {
            display(.paused)
        } else if ready {
            display(.ready)
        } else if inputState == true {
            display(.inputUnavailable)
        } else {
            display(.needsPermission)
        }
    }

    func tick() {
        let now = Date()
        if let retryAt, now >= retryAt, connection == nil, releasing == nil {
            self.retryAt = nil
            if let reconnect, controlSettings.autoConnect { beginConnection(reconnect) }
        }
        channel?.heartbeat(now: now, capturing: remote)
        if remote, (!cursorHidden || !cursorDetached), now.timeIntervalSince(lastActivateAttempt) >= 0.1 {
            lastActivateAttempt = now
            if !NSApp.isActive {
                showCaptureAnchor()
                NSApp.activate(ignoringOtherApps: true)
            }
            updateRemoteCursor()
        }
        if now.timeIntervalSince(lastInputCheck) >= 1 {
            lastInputCheck = now
            if window.isVisible || linked { refreshPermissions() }
            syncAwakeIfNeeded()
        }
        if linked, now.timeIntervalSince(lastClipboardCheck) >= 0.25 {
            lastClipboardCheck = now
            syncLocalClipboardIfNeeded()
        }
        flush()
    }

    func syncLocalClipboardIfNeeded() {
        guard linked, controlSettings.clipboardSync, let channel, channel.ready else { return }
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = count
        if let raw = pb.string(forType: .string) {
            let normalized = normalizeClipboardText(raw)
            guard !normalized.isEmpty, normalized.utf8.count <= maxClipboardBytes else { return }
            let digest = clipboardHash(kind: "text", payload: Data(normalized.utf8))
            guard digest != lastSyncedClipboardHash else { return }
            lastSyncedClipboardHash = digest
            channel.sendClipboard(normalized)
            return
        }
        let pngData: Data?
        if let png = pb.data(forType: .png) {
            pngData = png
        } else if let tiff = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff) {
            pngData = rep.representation(using: .png, properties: [:])
        } else {
            pngData = nil
        }
        guard let pngData, !pngData.isEmpty, pngData.count <= maxClipboardImageBytes else {
            lastSyncedClipboardHash = nil
            return
        }
        let digest = clipboardHash(kind: "image", payload: pngData)
        guard digest != lastSyncedClipboardHash else { return }
        lastSyncedClipboardHash = digest
        channel.sendClipboardImage(pngData)
    }

    func applyRemoteClipboard(_ text: String) {
        guard controlSettings.clipboardSync else { return }
        let normalized = normalizeClipboardText(text)
        guard !normalized.isEmpty, normalized.utf8.count <= maxClipboardBytes else { return }
        lastSyncedClipboardHash = clipboardHash(kind: "text", payload: Data(normalized.utf8))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(normalized, forType: .string)
        lastClipboardChangeCount = pb.changeCount
    }

    func applyRemoteClipboardImage(_ base64: String) {
        guard controlSettings.clipboardSync,
              let pngData = Data(base64Encoded: base64),
              !pngData.isEmpty, pngData.count <= maxClipboardImageBytes,
              let image = NSImage(data: pngData) else { return }
        lastSyncedClipboardHash = clipboardHash(kind: "image", payload: pngData)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        lastClipboardChangeCount = pb.changeCount
    }

    private func clipboardHash(kind: String, payload: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(kind.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: payload)
        return Data(hasher.finalize())
    }

    func installTap() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        var mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        mask |= CGEventMask(1) << 29 // NSEventTypeGesture (trackpad multi-finger touches)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<ConectorApp>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        tap = port
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func removeTap() {
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    func stop() {
        leave(reason: "disconnect")
        channel?.close()
        channel = nil
        connection = nil
        linked = false
        paused = false
        ready = false
        sending = false
        edgePush = 0
        lastSentAwake = nil
        pending.removeAll()
        localButtons.removeAll()
        localKeys.removeAll()
        removeTap()
    }

    func stopAndRelease() {
        let needsRelease = channel == nil && (remote || pending.first?.kind == "release" || (linked && sending))
        let lastConnection = connection
        stop()
        guard needsRelease, let lastConnection else {
            display(.idle)
            return
        }
        releasing = lastConnection
        display(.disconnecting)
        lastConnection.releaseWhenIdle { [weak self, weak lastConnection] in
            guard let self, let lastConnection, self.releasing === lastConnection else { return }
            self.releasing = nil
            self.display(.idle)
            self.finishQuit()
        }
    }

    @objc func disconnect() {
        guard releasing == nil else { return }
        log.record("disconnect requested")
        cancelAutomaticConnection()
        stopAndRelease()
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cancelAutomaticConnection()
        if releasing == nil { stopAndRelease() }
        guard releasing != nil else { return .terminateNow }
        quitting = true
        // The receiver's watchdog releases held keys if the last request cannot arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finishQuit() }
        return .terminateLater
    }

    func finishQuit() {
        guard quitting else { return }
        quitting = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stop()
        log.record("shutdown")
        log.drain()
    }

    func leave(reason: String) {
        guard remote else { return }
        remote = false
        edgePush = 0
        swipeDetector.reset()
        if handoffConfirmed && controlSettings.animate { cue.show(at: entry, entering: false) }
        handoffConfirmed = false
        pending = [Input(kind: "release")]
        captureAnchor?.orderOut(nil)
        if cursorDetached { CGAssociateMouseAndMouseCursorPosition(1) }
        if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()) }
        cursorDetached = false
        cursorHidden = false
        CGWarpMouseCursorPosition(CGPoint(x: entry.x, y: entry.y + 8))
        previousApp?.activate(options: [])
        previousApp = nil
        log.record("control returned to Mac reason=\(reason)")
        if channel != nil {
            log.record("stream capture frames=\(captureFrames) peakQueue=\(capturePeakQueue) peakWriteUs=\(capturePeakWrite / 1000)")
        }
        updateControlStatus()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window != nil { refreshPermissions() }
        updateRemoteCursor()
    }

    func showCaptureAnchor() {
        if captureAnchor == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.alphaValue = 0.01
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            captureAnchor = panel
        }
        if let main = NSScreen.screens.first {
            let origin = NSPoint(x: capturedBounds.midX, y: main.frame.maxY - capturedBounds.midY)
            captureAnchor?.setFrameOrigin(origin)
        }
        captureAnchor?.orderFrontRegardless()
    }

    func updateRemoteCursor() {
        guard remote else { return }
        if !cursorDetached {
            cursorDetached = CGAssociateMouseAndMouseCursorPosition(0) == .success
        }
        guard NSApp.isActive else { return }
        if !cursorHidden { cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success }
    }

    func warpForCapture() {
        CGWarpMouseCursorPosition(CGPoint(x: capturedBounds.midX, y: capturedBounds.midY))
        lastWarp = Date()
    }

    func enqueueMotion(x: Int32, y: Int32) {
        let movement = pointer.scale(x: x, y: y)
        guard movement.x != 0 || movement.y != 0 else { return }
        if let last = pending.indices.last, pending[last].kind == "move" {
            pending[last].x = min(10000, max(-10000, pending[last].x + movement.x))
            pending[last].y = min(10000, max(-10000, pending[last].y + movement.y))
        } else {
            pending.append(Input(kind: "move", x: movement.x, y: movement.y))
        }
    }

    func enqueueScroll(x: Double, y: Double, continuous: Bool) {
        let delta = scrollMotion.scale(x: x, y: y, continuous: continuous)
        guard delta.x != 0 || delta.y != 0 else { return }
        if let last = pending.indices.last, pending[last].kind == "scroll" {
            pending[last].x = min(10000, max(-10000, pending[last].x + delta.x))
            pending[last].y = min(10000, max(-10000, pending[last].y + delta.y))
        } else {
            pending.append(Input(kind: "scroll", x: delta.x, y: delta.y))
        }
    }

    func flush() {
        guard let connection, linked, !sending,
              !pending.isEmpty || Date().timeIntervalSince(lastSend) > (remote ? 0.4 : 5) else { return }
        if remote { capturePeakQueue = max(capturePeakQueue, pending.count) }
        let batch = Array(pending.prefix(128))
        pending.removeFirst(batch.count)
        lastSend = Date()
        sending = true
        if let channel {
            let writingCapture = remote ? captureID : 0
            let writeStart = DispatchTime.now().uptimeNanoseconds
            channel.send(batch, capture: captureID) { [weak self, weak channel] in
                guard let self, let channel, self.channel === channel else { return }
                if self.remote && self.captureID == writingCapture {
                    self.captureFrames += 1
                    self.capturePeakWrite = max(self.capturePeakWrite, DispatchTime.now().uptimeNanoseconds - writeStart)
                }
                self.sending = false
            }
            return
        }
        connection.send(batch) { [weak self, weak connection] result in
            guard let self, let connection, self.connection === connection else { return }
            self.sending = false
            switch result {
            case .http(204):
                if self.remote && batch.first?.kind == "enter" {
                    self.handoffConfirmed = true
                    if self.controlSettings.animate { self.cue.show(at: self.entry, entering: true) }
                }
            case .http(200):
                self.leave(reason: "Windows edge")
            default:
                self.connectionFailed(result)
            }
        }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let original = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.record("input tap disabled type=\(type.rawValue)")
            leave(reason: "input tap disabled")
            localKeys.removeAll()
            localButtons.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return original
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let dx = Int32(clamping: event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Int32(clamping: event.getIntegerValueField(.mouseEventDeltaY))
        let button = UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
        if !remote {
            if type.rawValue == 29 { return original }
            switch type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: localButtons.insert(button)
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: localButtons.remove(button)
            case .keyDown: localKeys.insert(key)
            case .keyUp: localKeys.remove(key)
            default: break
            }
            guard type == .mouseMoved else { return original }
            let heldModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
            guard ready, pending.isEmpty, dy < 0, abs(dx) <= -dy, localButtons.isEmpty, localKeys.isEmpty,
                  event.flags.intersection(heldModifiers).isEmpty else {
                edgePush = 0
                return original
            }
            let bounds = CGDisplayBounds(CGGetOnlineBuiltInDisplay())
            guard bounds.width > 0, event.location.y >= bounds.minY - 1, event.location.y <= bounds.minY + 1,
                  event.location.x >= bounds.minX, event.location.x < bounds.maxX else {
                edgePush = 0
                return original
            }
            let now = Date()
            if now.timeIntervalSince(lastEdgePush) > 0.25 { edgePush = 0 }
            lastEdgePush = now
            edgePush += max(-100, dy)
            guard edgePush <= -36 else { return original }
            edgePush = 0
            remote = true
            captureID &+= 1
            captureFrames = 0
            capturePeakQueue = 0
            capturePeakWrite = 0
            handoffConfirmed = false
            capturedBounds = bounds
            pointer = PointerMotion(speed: controlSettings.speed)
            scrollMotion = ScrollMotion(smoothness: controlSettings.scrollSmoothness)
            swipeDetector.reset()
            keyboard = RemoteKeyboard(commandIsControl: controlSettings.commandIsControl,
                                      commandSpaceSwitchesLanguage: controlSettings.commandSpaceSwitchesLanguage)
            lastWarp = .distantPast
            lastActivateAttempt = .distantPast
            entry = CGPoint(x: event.location.x, y: bounds.minY)
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
            // Keep the setup window from being raised while providing an invisible activation anchor.
            showCaptureAnchor()
            window.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
            updateRemoteCursor()
            warpForCapture()
            log.record("control entered Windows")
            updateControlStatus()
            syncLocalClipboardIfNeeded()
            pending.append(Input(kind: "enter", x: entryPosition(x: entry.x, in: bounds)))
            return nil
        }
        if type == .keyDown, key == 53, event.flags.contains([.maskControl, .maskAlternate]) {
            leave(reason: "escape shortcut")
            return nil
        }
        if type == .keyDown, key == 37, controlSettings.commandLLocksWindows,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           event.flags.contains(.maskCommand),
           event.flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty {
            lockWindows()
            return nil
        }
        if pending.count >= 512 {
            leave(reason: "input queue full")
            return nil
        }
        if type.rawValue == 29 {
            let touches = NSEvent(cgEvent: event)?.touches(matching: .touching, in: nil) ?? []
            let count = touches.count
            let avgX = count > 0 ? touches.reduce(0.0) { $0 + $1.normalizedPosition.x } / Double(count) : 0
            let avgY = count > 0 ? touches.reduce(0.0) { $0 + $1.normalizedPosition.y } / Double(count) : 0
            if let direction = swipeDetector.update(touchCount: count, x: avgX, y: avgY, now: Date().timeIntervalSinceReferenceDate) {
                let sequence = swipeKeySequence(direction: direction,
                                                horizontalAction: controlSettings.threeFingerSwipeAction,
                                                upEnabled: controlSettings.threeFingerSwipeUp)
                if !sequence.isEmpty { pending.append(contentsOf: sequence) }
            }
            return nil
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let recentWarp = Date().timeIntervalSince(lastWarp) < 0.045
            // Quartz may report the displacement of a recenter as a mouse delta.
            if !recentWarp || max(abs(Int64(dx)), abs(Int64(dy))) < 120 {
                enqueueMotion(x: dx, y: dy)
            }
            if !cursorDetached && !capturedBounds.insetBy(dx: 24, dy: 24).contains(event.location) && !recentWarp {
                warpForCapture()
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if button <= 2 {
                let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
                pending.append(Input(kind: "button", code: button, down: down))
            }
        case .scrollWheel:
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let rawX = continuous
                ? event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
                : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            let rawY = continuous
                ? event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            enqueueScroll(x: -rawX, y: rawY, continuous: continuous)
        case .keyDown, .keyUp, .flagsChanged:
            let down = type == .flagsChanged ? event.flags.rawValue & (modifierMasks[key] ?? 0) != 0 : type == .keyDown
            pending.append(contentsOf: keyboard.events(for: key, down: down, flagsChanged: type == .flagsChanged))
        default: break
        }
        return nil
    }
}

func CGGetOnlineBuiltInDisplay() -> CGDirectDisplayID {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    if CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
       let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }) {
        return builtIn
    }
    return CGMainDisplayID()
}

let app = NSApplication.shared
let delegate = ConectorApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

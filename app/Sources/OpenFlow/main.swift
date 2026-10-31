import AppKit
import Combine
import ServiceManagement
import UserNotifications

if CommandLine.arguments.contains("--selftest") {
    let fillers = FillerFilter.selfTest()
    let formatting = TextFormatter.selfTest()
    let echo = Transcriber.echoSelfTest()
    let vocabulary = VocabularyStore.selfTest()
    exit(fillers && formatting && echo && vocabulary ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    /// recording: key held (or locked hands-free). tapPending: a short tap that may become a double-tap.
    /// transcribing: transcription mode (double-tap); dictation is off until it stops.
    private enum State { case idle, recording(Date, locked: Bool), tapPending, finishing, transcribing }

    private let socketPath = NSHomeDirectory() + "/Library/Application Support/OpenFlow/asr.sock"
    private lazy var client = ASRClient(socketPath: socketPath)
    private lazy var sidecar = SidecarManager(
        asrDir: Bundle.main.object(forInfoDictionaryKey: "OpenFlowASRDir") as? String ?? "",
        socketPath: socketPath
    )
    private let hotkey = HotkeyMonitor()
    private let audio = AudioCapture()
    private let overlay = OverlayPanel()
    private lazy var transcriber = Transcriber(client: client, socketPath: socketPath, mic: audio)
    private lazy var transcriptPanel = TranscriptPanel(model: transcriber.model)
    private lazy var vocabulary = VocabularyStore()
    private lazy var sweeper = VaultSweeper(asrDir: sidecar.asrDir)
    private let appModel = AppModel()
    private lazy var mainWindow = MainWindow(model: appModel, store: vocabulary, sweeper: sweeper, actions: AppActions(
        toggleTranscription: { [weak self] in self?.toggleTranscription() },
        restartASR: { [weak self] in self?.restartASR() },
        openLog: { [weak self] in self?.openLog() },
        chooseTranscriptsFolder: { [weak self] in self?.chooseTranscriptsFolder() },
        openTranscripts: { [weak self] in self?.openTranscripts() },
        setMicrophone: { [weak self] uid in
            Settings.microphone = uid
            self?.audio.shutdown()  // reopen on the new device next time
        },
        setKeepMicWarm: { [weak self] on in
            Settings.keepMicWarm = on
            if !on, case .idle = self?.state { self?.audio.shutdown() }
        },
        applyShortcuts: { [weak self] in self?.applyShortcuts() },
        showSetupGuide: { [weak self] in self?.onboarding.show() },
        vocabulary: VocabularyActions(
            connect: { [weak self] in self?.connectVault($0) },
            chooseFolder: { [weak self] in self?.chooseVaultFolder() },
            disconnect: { [weak self] in self?.sweeper.disconnect() },
            rescan: { [weak self] in self?.sweeper.scan(requested: true) },
            setUseVocabulary: { [weak self] in self?.setUseVocabulary($0) }
        )
    ))
    private var scanWatch: AnyCancellable?
    private lazy var onboarding = OnboardingWindow(model: appModel) { [weak self] in self?.applyShortcuts() }

    /// A vault scan pauses whenever OpenFlow is listening, so it never slows recognition down.
    private var state = State.idle {
        didSet {
            if case .idle = state { sweeper.resume() } else { sweeper.pause() }
            if case .transcribing = state { appModel.transcribing = true } else { appModel.transcribing = false }
        }
    }
    private var lang: String?
    private var session = 0
    /// ASR session of the current dictation; events from older sessions are ignored.
    private var dictationSession = 0
    private var lastTranscribePress: Date?
    /// Keeps the mic open briefly after release: people let go while the last syllable is still trailing.
    private let releaseTail: TimeInterval = 0.3
    private var pendingTail: DispatchWorkItem?
    /// A tap shorter than this is not a dictation; a second press right after it locks hands-free mode.
    private let tapThreshold: TimeInterval = 0.25
    private let doubleTapWindow: TimeInterval = 0.35
    private var pendingTap: DispatchWorkItem?
    private var history: [String] = []
    private var statusText = "ASR: starting…"
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.registerDefaults()
        setUpMenu()
        setUpClient()
        if Settings.onboarded {
            AudioCapture.requestPermission { ok in if !ok { NSLog("OpenFlow: microphone permission denied") } }
            _ = TextInserter.hasAccessibility(prompt: true)
        } else {
            onboarding.show()  // asks for each permission in turn, with the reason
        }
        startHotkey()

        if !client.connect() { sidecar.start() }
        scheduleReconnect()

        UNUserNotificationCenter.current().delegate = self
        sweeper.isBusy = { [weak self] in
            guard let self else { return false }
            if case .idle = self.state { return false }
            return true
        }
        sweeper.onFinished = { [weak self] in self?.notifyScanned($0) }
        sweeper.start()
        // The menu bar icon shows a dot while a scan runs.
        scanWatch = sweeper.$running.receive(on: DispatchQueue.main).sink { [weak self] running in
            self?.statusItem.button?.image = Self.menuBarIcon(badge: running)
        }

        // Scripts and Shortcuts can toggle transcription mode (see README).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.openflow.toggleTranscription"), object: nil, queue: .main
        ) { [weak self] _ in self?.toggleTranscription() }
    }

    /// Opening OpenFlow again (Spotlight, Finder) while it runs shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    func applicationWillTerminate(_ note: Notification) {
        if case .transcribing = state {
            transcriber.stop()
            transcriber.finish()  // no time to wait for the last finals: save what's there
        }
        audio.shutdown()
        sidecar.stop()
    }

    // MARK: - Hotkey → audio → ASR

    private func startHotkey() {
        hotkey.onPress = { [weak self] in self?.keyPressed() }
        hotkey.onRelease = { [weak self] in self?.keyReleased() }
        hotkey.onChord = { [weak self] in self?.cancelDictation() }
        hotkey.onCancel = { [weak self] in self?.cancelDictation() }
        hotkey.cancelIsActive = { [weak self] in
            switch self?.state {
            case .recording, .tapPending: return true
            default: return false
            }
        }
        applyShortcuts()
        if hotkey.start() {
            appModel.hotkeyActive = true
        } else {
            // The setup guide asks for it with an explanation; later launches ask directly.
            if Settings.onboarded && !onboarding.isVisible { CGRequestListenEventAccess() }
            setStatus("Grant Accessibility and Input Monitoring to OpenFlow")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startHotkey() }
        }
    }

    /// Takes the shortcuts from Settings; called at launch and whenever they change.
    private func applyShortcuts() {
        hotkey.dictationKey = Settings.dictationKey
        hotkey.cancelKey = Settings.cancelShortcut
        var shortcuts: [(Shortcut, () -> Void)] = []
        if let s = Settings.transcriptionShortcut {
            shortcuts.append((s, { [weak self] in self?.transcriptionShortcut() }))
        }
        if let s = Settings.handsFreeShortcut {
            shortcuts.append((s, { [weak self] in self?.handsFreeShortcut() }))
        }
        hotkey.shortcuts = shortcuts
        appModel.shortcutsRevision += 1
    }

    /// Double-tapping the dictation key starts transcription, unless it has its own shortcut.
    private var doubleTapTranscribes: Bool { Settings.transcriptionShortcut == nil }

    private func transcriptionShortcut() {
        switch state {
        case .recording, .tapPending:
            cancelDictation()
            startTranscription()
        case .transcribing:
            stopTranscription()
        case .idle:
            startTranscription()
        case .finishing:
            break
        }
    }

    private func handsFreeShortcut() {
        switch state {
        case .recording(_, locked: true): endDictation()
        case .idle, .finishing: startHandsFree()
        default: break
        }
    }

    private func keyPressed() {
        switch state {
        case .tapPending:  // double-tap: drop the tap's dictation and start transcription mode
            cancelDictation()
            startTranscription()
        case .transcribing:  // double-tap again to stop
            guard doubleTapTranscribes else { return }
            if let last = lastTranscribePress, Date().timeIntervalSince(last) < doubleTapWindow {
                lastTranscribePress = nil
                stopTranscription()
            } else {
                lastTranscribePress = Date()
            }
        case .recording(_, locked: true):  // press again to finish hands-free mode
            endDictation()
        case .recording:
            break
        case .idle, .finishing:
            beginDictation()
        }
    }

    private func keyReleased() {
        guard case .recording(let started, locked: false) = state else { return }
        guard Date().timeIntervalSince(started) >= tapThreshold else {
            guard doubleTapTranscribes else { return cancelDictation() }  // a tap is not a dictation
            state = .tapPending  // keep recording until we know whether a second press follows
            let work = DispatchWorkItem { [weak self] in
                guard let self, case .tapPending = self.state else { return }
                self.cancelDictation()
            }
            pendingTap = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
            return
        }
        endDictation()
    }

    private func beginDictation() {
        guard client.isConnected else {
            setStatus("ASR not ready yet")
            return
        }
        flushTail()
        lang = nil
        session += 1
        dictationSession = client.start(language: Settings.language == "auto" ? "" : Settings.language)
        audio.onAudio = { [client] pcm in client.sendAudio(pcm) }
        audio.onLevel = { [overlay] level in
            DispatchQueue.main.async { overlay.model.level = 0.5 * overlay.model.level + 0.5 * level }  // smooth jitter
        }
        audio.warmSeconds = Settings.keepMicWarm ? 30 : 0
        do {
            try audio.begin(device: AudioDevices.resolve(Settings.microphone))
        } catch {
            NSLog("OpenFlow: audio start failed: %@", error.localizedDescription)
            client.cancel()
            return
        }
        state = .recording(Date(), locked: false)
        overlay.show()
        play("Tink")
    }

    private func endDictation() {
        state = .finishing
        overlay.model.finishing = true
        let tail = DispatchWorkItem { [weak self] in self?.flushTail() }
        pendingTail = tail
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseTail, execute: tail)
        let id = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in  // safety net
            guard let self, self.session == id, case .finishing = self.state else { return }
            self.state = .idle
            self.overlay.hide()
        }
    }

    private func startTranscription() {
        guard client.isConnected else {
            setStatus("ASR not ready yet")
            return
        }
        flushTail()
        do {
            try transcriber.start()
        } catch {
            NSLog("OpenFlow: transcription start failed: %@", error.localizedDescription)
            return
        }
        state = .transcribing
        lastTranscribePress = nil
        transcriptPanel.onStop = { [weak self] in self?.stopTranscription() }
        transcriptPanel.show()
        play("Morse")
    }

    private func stopTranscription() {
        guard case .transcribing = state else { return }
        transcriber.stop()
        state = .idle
        play("Pop")
    }

    /// Stops the post-release tail capture and asks the server for the final transcript.
    private func flushTail() {
        guard let tail = pendingTail else { return }
        tail.cancel()
        pendingTail = nil
        audio.finish()
        client.end()
    }

    private func cancelDictation() {
        switch state {
        case .recording, .tapPending: break
        default: return
        }
        pendingTap?.cancel()
        pendingTap = nil
        audio.finish()
        client.cancel()
        state = .idle
        overlay.hide()
    }

    private func setUpClient() {
        client.onEvent = { [weak self] event in
            guard let self else { return }
            if self.transcriber.handleMain(event) { return }
            switch event {
            case .ready:
                self.setStatus("ASR: ready")
            case .partial(let session, let text, let lang):
                guard session == self.dictationSession else { return }
                if case .idle = self.state { return }
                self.overlay.model.update(self.polish(text, lang: lang ?? self.lang))
                if let lang { self.overlay.model.lang = lang; self.lang = lang }
            case .final(let session, let text, let lang):
                guard session == self.dictationSession else { return }
                if case .finishing = self.state {
                    self.state = .idle
                    self.overlay.hide()
                }
                self.deliver(self.polish(text, lang: lang ?? self.lang))
            case .polished:
                break
            case .error(let message):
                NSLog("OpenFlow: ASR error: %@", message)
            case .disconnected:
                self.setStatus("ASR: reconnecting…")
                self.cancelDictation()
                self.flushTail()
                self.state = .idle
                self.overlay.hide()
            }
        }
    }

    /// Same cleanup for the live HUD and the paste, so what you see is what gets inserted.
    private func polish(_ text: String, lang: String?) -> String {
        TextFormatter.format(FillerFilter.clean(text, lang: lang))
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else { return }
        play("Pop")
        history.insert(text, at: 0)
        history = Array(history.prefix(10))
        paste(text)
    }

    private func paste(_ text: String) {
        let needsSpace = Settings.trailingSpace && !(text.last?.isWhitespace ?? true)
        TextInserter.insert(needsSpace ? text + " " : text)
    }

    private func play(_ name: String) {
        guard Settings.sounds, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }

    private func scheduleReconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if !self.client.isConnected, !self.client.connect() {
                self.setStatus("ASR: loading model…")
            }
            self.scheduleReconnect()
        }
    }

    // MARK: - Menu bar

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon(badge: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Quick actions only; settings and the vocabulary live in the OpenFlow window. Rebuilt on every
    /// open so history and status are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        // A scan or a pending review shows up here, not buried in a submenu.
        if sweeper.running, let vault = Settings.vault {
            var line = "Learning from \(VaultSweeper.name(of: vault))…"
            if case .reading(let done, let total) = sweeper.phase, total > 0 { line += " \(done)/\(total)" }
            menu.addItem(item(line, #selector(openVocabulary), symbol: "arrow.triangle.2.circlepath"))
        } else if !vocabulary.unreviewed.isEmpty {
            menu.addItem(item("\(vocabulary.unreviewed.count) new terms to review…", #selector(openVocabulary), symbol: "sparkles"))
        }
        menu.addItem(.separator())

        if case .transcribing = state {
            menu.addItem(item("Stop Transcription", #selector(toggleTranscription), symbol: "stop.circle"))
        } else {
            menu.addItem(item("Start Transcription", #selector(toggleTranscription), symbol: "text.bubble"))
            menu.addItem(item("Hands-Free Dictation", #selector(startHandsFree), symbol: "mic"))
        }
        menu.addItem(.separator())

        let last = item("Paste Last Dictation", #selector(pasteHistory(_:)), symbol: "doc.on.clipboard")
        last.tag = 0
        last.isEnabled = !history.isEmpty
        menu.addItem(last)
        if history.count > 1 {
            let recent = NSMenu()
            for (i, text) in history.enumerated() {
                let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
                let entry = item(flat.count > 60 ? String(flat.prefix(60)) + "…" : flat, #selector(pasteHistory(_:)))
                entry.tag = i
                entry.toolTip = text
                recent.addItem(entry)
            }
            menu.addItem(submenu("Recent Dictations", recent))
        }
        menu.addItem(.separator())

        menu.addItem(item("Vocabulary…", #selector(openVocabulary), symbol: "character.book.closed"))
        let settings = item("Settings…", #selector(openSettings), symbol: "gearshape")
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    /// Template version of the mark (three bars and a line); `badge` adds a dot (a scan is running).
    private static func menuBarIcon(badge: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let g = MarkGeometry.rects(in: rect.insetBy(dx: 1.5, dy: 3))
            NSColor.black.setFill()
            for r in g.bars + [g.line] {
                let radius = min(r.width, r.height) / 2
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            }
            if badge {
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badge ? "OpenFlow, learning vocabulary" : "OpenFlow"
        return image
    }

    private func setStatus(_ s: String) {
        statusText = s
        appModel.status = s
        statusItem.button?.appearsDisabled = !client.isConnected
    }

    @objc private func pasteHistory(_ sender: NSMenuItem) {
        guard history.indices.contains(sender.tag) else { return }
        let text = history[sender.tag]
        // let the menu close so focus is back in the target field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.paste(text) }
    }

    @objc private func toggleTranscription() {
        if case .transcribing = state {
            stopTranscription()
        } else if case .idle = state {
            startTranscription()
        }
    }

    /// Dictation without holding the key; a single press of the dictation key finishes it.
    @objc private func startHandsFree() {
        guard case .idle = state else { return }
        beginDictation()
        guard case .recording = state else { return }
        state = .recording(Date(), locked: true)
        overlay.model.locked = true
    }

    @objc private func openSettings() { mainWindow.show(.general) }

    private func openTranscripts() {
        try? FileManager.default.createDirectory(at: Settings.transcriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.transcriptsFolder)
    }

    private func chooseTranscriptsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Transcripts Folder"
        panel.message = "New transcripts are saved here as Markdown."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.transcriptsFolder
        NSApp.activate()  // a menu bar app's panel would otherwise open behind other windows
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.transcriptsFolder = url
        appModel.transcriptsFolder = url
    }

    private func restartASR() {
        setStatus("ASR: restarting…")
        sidecar.restart()
    }

    private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: sidecar.logPath))
    }

    // MARK: - Vocabulary

    @objc private func openVocabulary() {
        vocabulary.ensureFile()
        mainWindow.show(.vocabulary)
    }

    private func connectVault(_ url: URL) {
        vocabulary.ensureFile()
        sweeper.connect(url)
        mainWindow.show(.vocabulary)  // the scan's progress shows there
    }

    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.title = "Connect a Vault"
        panel.message = "Choose an Obsidian vault or any folder of Markdown notes. OpenFlow only reads it."
        panel.prompt = "Connect"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connectVault(url)
    }

    private func setUseVocabulary(_ on: Bool) {
        guard on != Settings.useVocabulary else { return }
        Settings.useVocabulary = on
        restartASR()  // the server takes the file as a launch argument
    }

    /// A scan you asked for always reports back; a background resync only when it found something.
    private func notifyScanned(_ r: VaultSweeper.Result) {
        guard let vault = Settings.vault, r.requested || r.added > 0 else { return }
        let name = VaultSweeper.name(of: vault)
        let content = UNMutableNotificationContent()
        if r.first {
            content.title = "Learned \(r.total) terms from \(name)"
        } else if r.added > 0 {
            content.title = "\(r.added) new terms from \(name)"
        } else {
            content.title = "Vocabulary up to date"
        }
        var body = ["\(r.total) terms"]
        if r.removed > 0 { body.append("\(r.removed) no longer in your notes") }
        body.append(vocabulary.unreviewed.isEmpty ? "OpenFlow listens for them." : "Click to review the new ones.")
        content.body = body.joined(separator: " · ")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "vocabulary", content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.openVocabulary() }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }
}

if CommandLine.arguments.contains("--mictest") {
    runMicTest()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--echotest"), i + 1 < CommandLine.arguments.count {
    runEchoTest(clip: CommandLine.arguments[i + 1])
    exit(0)
}

if CommandLine.arguments.contains("--systemaudiotest") {
    runSystemAudioTest()
    exit(0)
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--demo") {
    runOverlayDemo()
} else if CommandLine.arguments.contains("--transcript-demo") {
    runTranscriptDemo()
} else if let i = CommandLine.arguments.firstIndex(of: "--onboarding-demo") {
    runOnboardingDemo(step: CommandLine.arguments.dropFirst(i + 1).first.flatMap { Int($0) } ?? 0)
} else if let i = CommandLine.arguments.firstIndex(of: "--vocabulary-demo") {
    runVocabularyDemo(file: CommandLine.arguments.dropFirst(i + 1).first)
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
}
app.setActivationPolicy(.accessory)
app.run()

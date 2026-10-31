import AppKit
import ServiceManagement
import SwiftUI

/// State the OpenFlow window shows; the app delegate keeps it current.
final class AppModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", dictation = "Dictation", transcription = "Transcription", vocabulary = "Vocabulary"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .dictation: return "mic"
            case .transcription: return "text.bubble"
            case .vocabulary: return "character.book.closed"
            }
        }
    }

    @Published var page = Page.general
    @Published var status = "ASR: starting…"
    @Published var transcribing = false
    @Published var transcriptsFolder = Settings.transcriptsFolder
    /// The event tap is running (Input Monitoring granted and taking effect).
    @Published var hotkeyActive = false
    /// Bumped when shortcuts change, so hints redraw.
    @Published var shortcutsRevision = 0
}

/// What the window's pages can ask the app to do (settings with side effects go through here).
struct AppActions {
    var toggleTranscription: () -> Void
    var restartASR: () -> Void
    var openLog: () -> Void
    var chooseTranscriptsFolder: () -> Void
    var openTranscripts: () -> Void
    var setMicrophone: (String) -> Void
    var setKeepMicWarm: (Bool) -> Void
    var applyShortcuts: () -> Void
    var showSetupGuide: () -> Void
    var vocabulary: VocabularyActions
}

/// The OpenFlow window: settings and the vocabulary, one page each, in OpenFlow's own look (see
/// Theme.swift) inside a regular macOS window. While it's open OpenFlow is a regular app (Dock,
/// ⌘-Tab, an app menu, and with it ⌘C/⌘V in text fields); closed, it's back to the menu bar only.
final class MainWindow {
    let model: AppModel
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    init(model: AppModel, store: VocabularyStore, sweeper: VaultSweeper, actions: AppActions) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "OpenFlow"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Brand.nsCanvas
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 500)
        let host = NSHostingView(rootView: MainView(model: model, store: store, sweeper: sweeper, actions: actions))
        host.sizingOptions = []  // the window keeps its size (and minSize); long lists scroll
        window.contentView = host
        window.setContentSize(NSSize(width: 820, height: 640))
        if !window.setFrameUsingName("OpenFlowMain") { window.center() }
        window.setFrameAutosaveName("OpenFlowMain")
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [window] _ in
            // Back to the menu bar only, unless the setup guide is still open.
            if !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func show(_ page: AppModel.Page? = nil) {
        if let page { model.page = page }
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.appMenu() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()  // a menu bar app's window would otherwise stay behind
        window.makeKeyAndOrderFront(nil)
    }

    /// OpenFlow, Edit and Window menus: shown while the window is open. Without an Edit menu, text
    /// fields get no ⌘C/⌘V.
    private static func appMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        menu("OpenFlow", [
            item("Hide OpenFlow", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit OpenFlow", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }
}

extension AppModel.Page {
    var subtitle: String {
        switch self {
        case .general: return "How to talk to OpenFlow, and the app itself."
        case .dictation: return "Hold a key, talk, let go: the text lands where your cursor is."
        case .transcription: return "Meetings as Markdown, written while you talk: you and the other side."
        case .vocabulary: return "Names, acronyms and project words OpenFlow should get right."
        }
    }
}

extension AppModel {
    var recognizerReady: Bool { status.hasSuffix("ready") && !status.contains("not") }

    var recognizerBadge: StatusBadge {
        if recognizerReady { return StatusBadge(tone: .ok, text: "Ready") }
        let text = status.replacingOccurrences(of: "ASR: ", with: "").replacingOccurrences(of: "ASR ", with: "Speech model ")
        return StatusBadge(tone: status.hasPrefix("Grant") ? .warn : .busy, text: text.capitalizingFirst)
    }
}

private struct MainView: View {
    @ObservedObject var model: AppModel
    var store: VocabularyStore
    @ObservedObject var sweeper: VaultSweeper
    var actions: AppActions

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, sweeper: sweeper)
            Rectangle().fill(Brand.hairline).frame(width: 1)
            Group {
                switch model.page {
                case .general: PageScroll(page: .general) { GeneralPage(model: model, actions: actions) }
                case .dictation: PageScroll(page: .dictation) { DictationPage(actions: actions) }
                case .transcription: PageScroll(page: .transcription) { TranscriptionPage(model: model, actions: actions) }
                case .vocabulary: VocabularyPage(store: store, sweeper: sweeper, actions: actions.vocabulary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.canvas)
        }
        .ignoresSafeArea()
        .tint(Brand.ember)
    }
}

/// The wordmark, the pages (⌘1–⌘4), and at the bottom whether the speech model is ready.
private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sweeper: VaultSweeper
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(size: 19)
                .padding(.leading, 22)
                .padding(.top, 52)
                .padding(.bottom, 26)
            VStack(spacing: 2) {
                ForEach(Array(AppModel.Page.allCases.enumerated()), id: \.element) { i, page in
                    NavItem(page: page, selected: model.page == page, busy: page == .vocabulary && sweeper.running) {
                        model.page = page
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
            }
            .padding(.horizontal, 12)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                if model.transcribing { StatusBadge(tone: .warn, text: "Transcribing") }
                model.recognizerBadge
                Text("Runs on this Mac · \(version)")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .background(Brand.sidebar)
    }
}

private struct NavItem: View {
    let page: AppModel.Page
    let selected: Bool
    let busy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(Brand.ember) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                Text(page.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Brand.surface : hovering ? Brand.surface.opacity(0.45) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Brand.hairline : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A settings page: its headline, then groups, scrolling when the window is short.
private struct PageScroll<Content: View>: View {
    let page: AppModel.Page
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(title: page.rawValue, subtitle: page.subtitle)
                content
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 50)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var sounds = Settings.sounds
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HowToCard(model: model)
            ShortcutsGroup(model: model, actions: actions)
            SettingsGroup(title: "Speech model") {
                SettingRow(title: "Recognizer", detail: "NVIDIA Nemotron, on this Mac's GPU. Nothing goes to the cloud.") {
                    HStack(spacing: 8) {
                        model.recognizerBadge
                        Button("Restart", action: actions.restartASR).buttonStyle(.quietSmall)
                        Button("Log", action: actions.openLog).buttonStyle(.quietSmall)
                    }
                }
            }
            SettingsGroup(title: "App") {
                SettingRow(title: "Setup guide", detail: "Permissions, your dictation key and a field to try it.") {
                    Button("Show…", action: actions.showSetupGuide).buttonStyle(.quietSmall)
                }
                SettingRow(title: "Sounds", detail: "A short sound when dictation starts and ends.") {
                    Toggle("Sounds", isOn: $sounds).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: sounds) { Settings.sounds = sounds }
                }
                SettingRow(title: "Launch at login") {
                    Toggle("Launch at login", isOn: $login).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: login) {
                            do {
                                if login { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                NSLog("OpenFlow: launch at login failed: %@", error.localizedDescription)
                                login = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
            }
        }
    }
}

/// The three things to remember, on ink: dictate, transcribe, cancel, with the keys you chose.
private struct HowToCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let _ = model.shortcutsRevision
        let key = Settings.dictationKey.name
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                BrandMark(line: Brand.paper).frame(height: 12)
                Text("Talk instead of typing").font(.display(16)).foregroundStyle(Brand.paper)
                Spacer()
                if !model.hotkeyActive {
                    Text("Keys need permissions: see Setup guide")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Brand.ember)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                item(["Hold", key], "Dictate", "Talk, then let go. The text appears at your cursor.")
                divider
                if let s = Settings.transcriptionShortcut {
                    item([s.display], "Transcribe a meeting", "Press again to stop. Saved as Markdown.")
                } else {
                    item(["Double-tap", key], "Transcribe a meeting", "Double-tap again to stop. Saved as Markdown.")
                }
                divider
                item([Settings.cancelShortcut.display], "Cancel", "While dictating. Nothing is pasted.")
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.ink))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .environment(\.colorScheme, .dark)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(width: 1).padding(.horizontal, 14)
    }

    /// Words like "Hold" stay text; anything else is a key.
    private func item(_ keys: [String], _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(keys, id: \.self) { k in
                    if k == "Hold" || k == "Double-tap" {
                        Text(k).font(.system(size: 11.5)).foregroundStyle(Brand.paper.opacity(0.6))
                    } else {
                        KeyCap(text: k, dark: true)
                    }
                }
            }
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.paper)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Brand.paper.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutsGroup: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var key = Settings.dictationKey
    @State private var transcription = Settings.transcriptionShortcut
    @State private var handsFree = Settings.handsFreeShortcut
    @State private var cancel: Shortcut? = Settings.cancelShortcut == .escape ? nil : Settings.cancelShortcut

    var body: some View {
        SettingsGroup(
            title: "Shortcuts",
            footer: model.hotkeyActive ? "Click a shortcut, then press the keys. Combinations need ⌘, ⌥ or ⌃."
                : "Shortcuts don't work yet: allow Input Monitoring and Accessibility (Setup guide), then restart OpenFlow.",
            footerStyle: model.hotkeyActive ? nil : Brand.emberText
        ) {
            SettingRow(title: "Dictate", detail: "Hold this key while you talk.") {
                Picker("Dictate", selection: $key) {
                    ForEach(DictationKey.allCases) { Text($0.name.capitalizingFirst).tag($0) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: key) { Settings.dictationKey = key; actions.applyShortcuts() }
            }
            SettingRow(title: "Transcribe a meeting", detail: "Opens the transcript panel; the same keys stop it.") {
                ShortcutRecorder(shortcut: $transcription, placeholder: "Double-tap \(key.name)") {
                    Settings.transcriptionShortcut = transcription
                    actions.applyShortcuts()
                }
            }
            SettingRow(title: "Hands-free dictation", detail: "Dictate without holding a key; tap the key to finish.") {
                ShortcutRecorder(shortcut: $handsFree, placeholder: "Menu bar only") {
                    Settings.handsFreeShortcut = handsFree
                    actions.applyShortcuts()
                }
            }
            SettingRow(title: "Cancel a dictation", detail: "Nothing is pasted.") {
                ShortcutRecorder(shortcut: $cancel, placeholder: "Esc", requireModifier: false) {
                    Settings.cancelShortcut = cancel ?? .escape
                    actions.applyShortcuts()
                }
            }
        }
    }
}

private struct DictationPage: View {
    var actions: AppActions
    @State private var language = Settings.language
    @State private var microphone = Settings.microphone
    @State private var trailingSpace = Settings.trailingSpace
    @State private var keepMicWarm = Settings.keepMicWarm

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsGroup(
                title: "Input",
                footer: "A Bluetooth headset mic switches the headset to low-quality call audio, so Automatic uses the built-in mic instead."
            ) {
                SettingRow(title: "Language", detail: "German and English are detected per dictation.") {
                    Picker("Language", selection: $language) {
                        Text("Detect automatically").tag("auto")
                        Text("Deutsch").tag("de-DE")
                        Text("English").tag("en-US")
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: language) { Settings.language = language }
                }
                SettingRow(title: "Microphone") {
                    Picker("Microphone", selection: $microphone) {
                        Text("Automatic" + (AudioDevices.resolve("auto").map { " (\($0.name))" } ?? "")).tag("auto")
                        Text("System default").tag("default")
                        Divider()
                        ForEach(AudioDevices.inputs(), id: \.uid) { d in
                            Text(d.name + (d.isBluetooth ? " (Bluetooth)" : "")).tag(d.uid)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                    .onChange(of: microphone) { actions.setMicrophone(microphone) }
                }
            }
            SettingsGroup(
                title: "Text",
                footer: "With the mic kept ready, the next dictation starts instantly, but the orange mic indicator stays on a little longer."
            ) {
                SettingRow(title: "Add a space after the text", detail: "So the next dictation doesn't run into this one.") {
                    Toggle("Add a space", isOn: $trailingSpace).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: trailingSpace) { Settings.trailingSpace = trailingSpace }
                }
                SettingRow(title: "Keep the mic ready for 30 s", detail: "No clipped first word when you dictate in quick succession.") {
                    Toggle("Keep the mic ready", isOn: $keepMicWarm).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: keepMicWarm) { actions.setKeepMicWarm(keepMicWarm) }
                }
            }
        }
    }
}

private struct TranscriptionPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var cancelEcho = Settings.cancelEcho

    var body: some View {
        let _ = model.shortcutsRevision
        VStack(alignment: .leading, spacing: 26) {
            SettingsGroup(footer: "Always get consent when transcribing others.") {
                SettingRow(title: model.transcribing ? "Transcribing…" : "Meeting transcription",
                           detail: "\(ShortcutHints.transcribe) to start or stop. You: your mic. Them: what your Mac plays.") {
                    Button(model.transcribing ? "Stop" : "Start", action: actions.toggleTranscription)
                        .buttonStyle(.primary)
                }
                SettingRow(title: "Transcripts folder",
                           detail: model.transcriptsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    HStack(spacing: 8) {
                        Button("Change…", action: actions.chooseTranscriptsFolder).buttonStyle(.quietSmall)
                        Button("Open", action: actions.openTranscripts).buttonStyle(.quietSmall)
                    }
                }
            }
            SettingsGroup(
                title: "Audio",
                footer: "On speakers your mic also hears the other side. This removes what the speakers play from your mic. Not needed with headphones."
            ) {
                SettingRow(title: "Cancel speaker echo") {
                    Toggle("Cancel speaker echo", isOn: $cancelEcho).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: cancelEcho) { Settings.cancelEcho = cancelEcho }
                }
            }
        }
    }
}

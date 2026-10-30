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
            case .general: return "gearshape"
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
    var vocabulary: VocabularyActions
}

/// The OpenFlow window: settings and the vocabulary, one page each. A regular macOS window, so it
/// gets the system's corners, sidebar and glass. While it's open OpenFlow is a regular app (Dock,
/// ⌘-Tab, an app menu, and with it ⌘C/⌘V in text fields); closed, it's back to the menu bar only.
final class MainWindow {
    let model: AppModel
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    init(model: AppModel, store: VocabularyStore, sweeper: VaultSweeper, actions: AppActions) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "OpenFlow"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 460)
        let host = NSHostingView(rootView: MainView(model: model, store: store, sweeper: sweeper, actions: actions))
        host.sizingOptions = []  // the window keeps its size (and minSize); long lists scroll
        window.contentView = host
        window.setContentSize(NSSize(width: 780, height: 640))
        if !window.setFrameUsingName("OpenFlowMain") { window.center() }
        window.setFrameAutosaveName("OpenFlowMain")
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in NSApp.setActivationPolicy(.accessory) }
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

private struct MainView: View {
    @ObservedObject var model: AppModel
    var store: VocabularyStore
    @ObservedObject var sweeper: VaultSweeper
    var actions: AppActions

    var body: some View {
        NavigationSplitView {
            List(AppModel.Page.allCases, selection: Binding(get: { model.page }, set: { if let p = $0 { model.page = p } })) { page in
                Label {
                    HStack {
                        Text(page.rawValue)
                        if page == .vocabulary && sweeper.running {
                            Spacer()
                            ProgressView().controlSize(.mini)
                        }
                    }
                } icon: {
                    Image(systemName: page.symbol)
                }
                .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch model.page {
                case .general: GeneralPage(model: model, actions: actions)
                case .dictation: DictationPage(actions: actions)
                case .transcription: TranscriptionPage(model: model, actions: actions)
                case .vocabulary: VocabularyPage(store: store, sweeper: sweeper, actions: actions.vocabulary)
                }
            }
            .navigationTitle(model.page.rawValue)
        }
    }
}

private struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var sounds = Settings.sounds
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                LabeledContent("Recognizer") {
                    HStack {
                        Text(model.status).foregroundStyle(.secondary)
                        Button("Restart", action: actions.restartASR)
                        Button("Open Log", action: actions.openLog)
                    }
                }
            }
            Section("Shortcuts") {
                LabeledContent("Dictate", value: "Hold right ⌥")
                LabeledContent("Transcribe a meeting", value: "Double-tap right ⌥")
                LabeledContent("Cancel", value: "Esc")
                LabeledContent("Hands-free dictation", value: "Menu bar → Hands-Free Dictation")
            }
            Section {
                Toggle("Sounds", isOn: $sounds).onChange(of: sounds) { Settings.sounds = sounds }
                Toggle("Launch at login", isOn: $login).onChange(of: login) {
                    do {
                        if login { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("OpenFlow: launch at login failed: %@", error.localizedDescription)
                        login = SMAppService.mainApp.status == .enabled
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DictationPage: View {
    var actions: AppActions
    @State private var language = Settings.language
    @State private var microphone = Settings.microphone
    @State private var trailingSpace = Settings.trailingSpace
    @State private var keepMicWarm = Settings.keepMicWarm

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("Detect automatically").tag("auto")
                    Text("Deutsch").tag("de-DE")
                    Text("English").tag("en-US")
                }
                .onChange(of: language) { Settings.language = language }
                Picker("Microphone", selection: $microphone) {
                    Text("Automatic (avoid Bluetooth)" + (AudioDevices.resolve("auto").map { " – \($0.name)" } ?? "")).tag("auto")
                    Text("System default").tag("default")
                    Divider()
                    ForEach(AudioDevices.inputs(), id: \.uid) { d in
                        Text(d.name + (d.isBluetooth ? " (Bluetooth)" : "")).tag(d.uid)
                    }
                }
                .onChange(of: microphone) { actions.setMicrophone(microphone) }
            } footer: {
                Text("A Bluetooth headset mic switches the headset to low-quality call audio, so Automatic uses the built-in mic instead.")
            }
            Section {
                Toggle("Add a space after the text", isOn: $trailingSpace).onChange(of: trailingSpace) { Settings.trailingSpace = trailingSpace }
                Toggle("Keep the mic ready for 30 s", isOn: $keepMicWarm).onChange(of: keepMicWarm) { actions.setKeepMicWarm(keepMicWarm) }
            } footer: {
                Text("With the mic kept ready, the next dictation starts instantly, but the orange mic indicator stays on a little longer.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptionPage: View {
    @ObservedObject var model: AppModel
    var actions: AppActions
    @State private var cancelEcho = Settings.cancelEcho

    var body: some View {
        Form {
            Section {
                LabeledContent("Meeting transcription") {
                    Button(model.transcribing ? "Stop" : "Start", action: actions.toggleTranscription)
                }
                LabeledContent("Transcripts folder") {
                    HStack {
                        Text(model.transcriptsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Change…", action: actions.chooseTranscriptsFolder)
                        Button("Open", action: actions.openTranscripts)
                    }
                }
            } footer: {
                Text("Double-tap right ⌥ to start or stop. Always get consent when transcribing others.")
            }
            Section {
                Toggle("Cancel speaker echo", isOn: $cancelEcho).onChange(of: cancelEcho) { Settings.cancelEcho = cancelEcho }
            } footer: {
                Text("On speakers your mic also hears the other side. This removes what the speakers play from your mic. Not needed with headphones.")
            }
        }
        .formStyle(.grouped)
    }
}

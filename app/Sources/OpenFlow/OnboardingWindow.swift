import AppKit
import SwiftUI

/// The first-run guide: what OpenFlow does, the permissions it needs (one at a time, each with
/// the reason), the dictation key, optionally a vault to learn words from, and a field to try it.
/// Opens on first launch and from Settings → General → Setup Guide.
final class OnboardingWindow {
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    init(model: AppModel, step: Int = 0, applyShortcuts: @escaping () -> Void,
         connectVault: @escaping (URL) -> Void, pickVaultFolder: @escaping () -> URL?) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Welcome to OpenFlow"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Brand.nsCanvas
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OnboardingView(
            model: model, step: step, applyShortcuts: applyShortcuts, connectVault: connectVault,
            pickVaultFolder: pickVaultFolder, onDone: { [weak self] in self?.window.close() }
        ))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        // Closing it, done or not, counts: the guide doesn't come back on its own.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Settings.onboarded = true
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== self.window }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var applyShortcuts: () -> Void
    var connectVault: (URL) -> Void
    var pickVaultFolder: () -> URL?
    var onDone: () -> Void
    @State private var step: Int
    @State private var vault = Settings.vault

    init(model: AppModel, step: Int, applyShortcuts: @escaping () -> Void, connectVault: @escaping (URL) -> Void,
         pickVaultFolder: @escaping () -> URL?, onDone: @escaping () -> Void) {
        self.model = model
        self.applyShortcuts = applyShortcuts
        self.connectVault = connectVault
        self.pickVaultFolder = pickVaultFolder
        self.onDone = onDone
        _step = State(initialValue: step)
    }
    private let steps = ["Welcome", "Permissions", "Shortcut", "Your words", "Try it"]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: PermissionsStep(model: model)
                case 2: ShortcutStep(applyShortcuts: applyShortcuts)
                case 3: VaultStep(connected: $vault, connectVault: connectVault, pickVaultFolder: pickVaultFolder)
                default: TryStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, 48)
            Hairline()
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(steps.indices, id: \.self) { i in
                        Capsule().fill(i <= step ? Brand.ember : Brand.hairline)
                            .frame(width: i == step ? 20 : 7, height: 7)
                    }
                }
                .animation(.smooth, value: step)
                Text(steps[step]).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.quiet) }
                Button(step == steps.count - 1 ? "Done" : step == 0 ? "Get Started" : step == 3 && vault == nil ? "Skip" : "Continue") {
                    if step == steps.count - 1 { onDone() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Brand.sidebar.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // inside the title bar's safe area
        .background(Brand.canvas)
        .tint(Brand.ember)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
                .padding(.leading, -6)  // the icon's own margin
            Text("Talk instead of typing.").font(.display(34)).kerning(-0.5)
                .padding(.top, 18)
            Text("OpenFlow turns your voice into text in any app, in German and English. "
                + "Hold a key, talk, let go.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 16) {
                feature("mic.fill", "Dictate anywhere", "Release the key and the text appears where your cursor is.")
                feature("text.bubble.fill", "Transcribe meetings", "You and the others, saved as Markdown as you go.")
                feature("character.book.closed.fill", "Learns your words", "Names and acronyms from your notes, spelled right.")
                feature("lock.fill", "Stays on your Mac", "Speech recognition and cleanup run locally. No account, no cloud.")
            }
            .padding(.top, 30)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            IconBadge(symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StepTitle: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.display(26)).kerning(-0.3)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "A few permissions",
                      text: "macOS asks for each one. OpenFlow only uses them for what's written here.")
            // Polled: macOS doesn't announce when a permission is granted in System Settings.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 12) {
                    SettingsGroup {
                        ForEach(Permission.allCases) { PermissionRow(permission: $0) }
                    }
                    if Permission.inputMonitoring.granted == true && Permission.accessibility.granted == true
                        && !model.hotkeyActive {
                        HStack(spacing: 10) {
                            IconBadge(symbol: "arrow.clockwise", size: 28, tint: Brand.warn)
                            Text("macOS applies these permissions after a restart of OpenFlow.")
                                .font(.system(size: 12))
                            Spacer()
                            Button("Restart OpenFlow", action: relaunch).buttonStyle(.primary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.warn.opacity(0.1)))
                    }
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: permission.symbol, size: 32,
                      tint: permission.granted == true ? Brand.ok : Brand.ember)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.system(size: 13, weight: .semibold))
                    if !permission.required {
                        Text("optional").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Brand.well))
                    }
                }
                Text(permission.reason).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            switch permission.granted {
            case true?:
                Label("Allowed", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon).foregroundStyle(Brand.ok).font(.system(size: 12, weight: .semibold))
            case false?:
                Button("Allow…") { permission.request() }.buttonStyle(.quietSmall)
            case nil:
                Button("Open Settings") { permission.openSettings() }.buttonStyle(.quietSmall)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ShortcutStep: View {
    var applyShortcuts: () -> Void
    @State private var key = Settings.dictationKey

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Your dictation key",
                      text: "Hold it while you talk, release it to insert the text. Double-tap it to transcribe a meeting.")
            SettingsGroup {
                ForEach(DictationKey.allCases) { k in
                    Button { key = k } label: {
                        HStack(spacing: 12) {
                            Image(systemName: key == k ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 14))
                                .foregroundStyle(key == k ? AnyShapeStyle(Brand.ember) : AnyShapeStyle(.tertiary))
                            KeyCap(text: k.name)
                            if k == .rightOption {
                                Text("recommended").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(key == k ? Brand.ember.opacity(0.07) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onChange(of: key) {
                Settings.dictationKey = key
                applyShortcuts()
            }
            if key == .fn {
                Label("Set “Press 🌐 key to” to “Do Nothing” in System Settings → Keyboard, or macOS opens the emoji picker too.",
                      systemImage: "info.circle")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Text("You can change this and the other shortcuts any time in Settings → Shortcuts.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
    }
}

/// Optional: an Obsidian vault (or any Markdown folder) to learn names and acronyms from.
private struct VaultStep: View {
    @Binding var connected: URL?
    var connectVault: (URL) -> Void
    var pickVaultFolder: () -> URL?
    private let known = VaultSweeper.knownVaults()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Your words",
                      text: "Optional. Connect your Obsidian vault and OpenFlow learns the names, acronyms and project "
                        + "words in your notes, so it spells them right. The vault is only read; nothing leaves your Mac.")
            SettingsGroup {
                ForEach(known, id: \.self) { v in
                    row(v.name, symbol: connected == v.url ? "largecircle.fill.circle" : "circle",
                        selected: connected == v.url) { connect(v.url) }
                }
                row(known.isEmpty ? "Choose a folder…" : "Another folder…", symbol: "folder", selected: false) {
                    if let url = pickVaultFolder() { connect(url) }
                }
            }
            if let connected {
                Label("Connected to \(VaultSweeper.name(of: connected)). The first scan runs in the background and "
                      + "can take a few minutes; the terms show up in Settings → Vocabulary.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Text("No Obsidian? Skip this. Any folder of Markdown notes works too, now or later in Settings → Vocabulary.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
    }

    private func connect(_ url: URL) {
        guard url != connected else { return }
        connectVault(url)
        connected = url
    }

    private func row(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? AnyShapeStyle(Brand.ember) : AnyShapeStyle(.tertiary))
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(selected ? Brand.ember.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TryStep: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Try it",
                      text: "Click into the field, then \(ShortcutHints.dictate.lowercasedFirst) and say something.")
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.surface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Your words appear here.").font(.system(size: 15)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 17).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 6) {
                StatusBadge(tone: model.recognizerReady ? .ok : .busy,
                            text: model.recognizerReady ? "Speech recognition is ready."
                                : "Speech recognition is still starting. The first start takes a moment.")
            }
            if !Permission.allRequiredGranted {
                Label("Some permissions are still missing; go back one step to allow them.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Brand.emberText)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Good to know").font(.system(size: 11, weight: .semibold)).kerning(0.6).textCase(.uppercase)
                    .foregroundStyle(.secondary)
                tip(ShortcutHints.transcribe, "starts or stops a meeting transcription.")
                tip(ShortcutHints.cancel, "cancels a dictation; nothing is pasted.")
                tip(nil, "Settings and your vocabulary: menu bar icon → Settings…")
            }
            .padding(.top, 6)
        }
    }

    /// "Double-tap right ⌥" → the verb as text, the key as a keycap.
    private func tip(_ hint: String?, _ text: String) -> some View {
        let verb = ["Double-tap ", "Hold "].first { hint?.hasPrefix($0) == true }
        return HStack(spacing: 6) {
            if let verb { Text(verb).font(.system(size: 12)).foregroundStyle(.secondary) }
            if let hint { KeyCap(text: String(hint.dropFirst(verb?.count ?? 0))) }
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

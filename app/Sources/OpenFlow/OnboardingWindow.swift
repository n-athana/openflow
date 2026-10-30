import AppKit
import SwiftUI

/// The first-run guide: what OpenFlow does, the permissions it needs (one at a time, each with
/// the reason), the dictation key, and a field to try it. Opens on first launch and from
/// Settings → General → Setup Guide.
final class OnboardingWindow {
    private let window: NSWindow
    private var closeObserver: NSObjectProtocol?

    init(model: AppModel, step: Int = 0, applyShortcuts: @escaping () -> Void) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Welcome to OpenFlow"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OnboardingView(
            model: model, step: step, applyShortcuts: applyShortcuts, onDone: { [weak self] in self?.window.close() }
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
    var onDone: () -> Void
    @State private var step: Int

    init(model: AppModel, step: Int, applyShortcuts: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.model = model
        self.applyShortcuts = applyShortcuts
        self.onDone = onDone
        _step = State(initialValue: step)
    }
    private let steps = ["Welcome", "Permissions", "Shortcut", "Try it"]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: PermissionsStep(model: model)
                case 2: ShortcutStep(applyShortcuts: applyShortcuts)
                default: TryStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 24)
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { i in
                        Capsule().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 18 : 7, height: 7)
                    }
                }
                .animation(.smooth, value: step)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == steps.count - 1 ? "Done" : step == 0 ? "Get Started" : "Continue") {
                    if step == steps.count - 1 { onDone() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // inside the title bar's safe area
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            Text("Talk instead of typing").font(.system(size: 26, weight: .semibold))
            Text("OpenFlow turns your voice into text in any app, in German and English.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                feature("mic.fill", "Hold a key and talk", "Release it and the text appears where your cursor is.")
                feature("text.bubble.fill", "Transcribe meetings", "You and the others, saved as Markdown as you go.")
                feature("lock.fill", "Everything stays on your Mac", "Speech recognition and cleanup run locally. No account, no cloud.")
            }
            .padding(.top, 8)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(brand).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A few permissions").font(.system(size: 22, weight: .semibold))
            Text("macOS asks for each one. OpenFlow only uses them for what's written here.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            // Polled: macOS doesn't announce when a permission is granted in System Settings.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 10) {
                    ForEach(Permission.allCases) { PermissionRow(permission: $0) }
                    if Permission.inputMonitoring.granted == true && Permission.accessibility.granted == true
                        && !model.hotkeyActive {
                        HStack {
                            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                            Text("macOS applies these permissions after a restart of OpenFlow.")
                                .font(.system(size: 12))
                            Spacer()
                            Button("Restart OpenFlow", action: relaunch)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
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
            Image(systemName: permission.symbol)
                .font(.system(size: 15))
                .foregroundStyle(brand)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.quaternary.opacity(0.6)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.system(size: 13, weight: .semibold))
                    if !permission.required {
                        Text("optional").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(permission.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            switch permission.granted {
            case true?:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon).foregroundStyle(.green).font(.system(size: 12, weight: .medium))
            case false?:
                Button("Allow…") { permission.request() }
            case nil:
                Button("Open Settings") { permission.openSettings() }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

private struct ShortcutStep: View {
    var applyShortcuts: () -> Void
    @State private var key = Settings.dictationKey

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your dictation key").font(.system(size: 22, weight: .semibold))
            Text("Hold it while you talk, release it to insert the text. Double-tap it to transcribe a meeting.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(DictationKey.allCases) { k in
                    Button { key = k } label: {
                        HStack {
                            Image(systemName: key == k ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(key == k ? Color.accentColor : .secondary)
                            Text(k.name.capitalizingFirst).font(.system(size: 13))
                            if k == .rightOption { Text("recommended").font(.system(size: 10)).foregroundStyle(.secondary) }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(key == k ? Color.accentColor.opacity(0.1) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .onChange(of: key) {
                Settings.dictationKey = key
                applyShortcuts()
            }
            if key == .fn {
                Label("Set “Press 🌐 key to” to “Do Nothing” in System Settings → Keyboard, or macOS opens the emoji picker too.",
                      systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("You can change this and the other shortcuts any time in Settings → General.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

private struct TryStep: View {
    @ObservedObject var model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try it").font(.system(size: 22, weight: .semibold))
            Text("Click into the field, then \(ShortcutHints.dictate.lowercasedFirst) and say something.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack(spacing: 6) {
                Circle().fill(model.status.hasSuffix("ready") ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(model.status.hasSuffix("ready") ? "Speech recognition is ready."
                     : "Speech recognition is still starting. The first start takes a moment.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !Permission.allRequiredGranted {
                Label("Some permissions are still missing; go back one step to allow them.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Good to know").font(.system(size: 12, weight: .semibold))
                Text("• \(ShortcutHints.transcribe) starts or stops a meeting transcription.")
                Text("• \(ShortcutHints.cancel) cancels a dictation; nothing is pasted.")
                Text("• Settings and your vocabulary: menu bar icon → Settings…")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

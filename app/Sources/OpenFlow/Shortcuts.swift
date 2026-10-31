import AppKit
import CoreGraphics
import SwiftUI

/// The key you hold to dictate: a single modifier key, so it never collides with typing.
enum DictationKey: String, CaseIterable, Identifiable {
    case rightOption, leftOption, rightCommand, rightShift, rightControl, fn

    var id: String { rawValue }

    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .rightShift: return 60
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .rightOption, .leftOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightShift: return .maskShift
        case .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }

    var name: String {
        switch self {
        case .rightOption: return "right ⌥"
        case .leftOption: return "left ⌥"
        case .rightCommand: return "right ⌘"
        case .rightShift: return "right ⇧"
        case .rightControl: return "right ⌃"
        case .fn: return "fn 🌐"
        }
    }
}

/// A key combination like ⌃⌥T, recorded in the OpenFlow window.
struct Shortcut: Codable, Equatable {
    var keyCode: Int64
    var modifiers: UInt64  // CGEventFlags: only ⌘ ⌥ ⌃ ⇧
    var display: String

    static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    static let escape = Shortcut(keyCode: 53, modifiers: 0, display: "Esc")

    func matches(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == keyCode
            && event.flags.intersection(Self.relevant).rawValue == modifiers
    }

    var hasModifier: Bool { modifiers != 0 || Self.functionKeys.contains(keyCode) }

    init(keyCode: Int64, modifiers: UInt64, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    init(_ event: NSEvent) {
        var flags = CGEventFlags()
        var symbols = ""
        let m = event.modifierFlags
        if m.contains(.control) { flags.insert(.maskControl); symbols += "⌃" }
        if m.contains(.option) { flags.insert(.maskAlternate); symbols += "⌥" }
        if m.contains(.shift) { flags.insert(.maskShift); symbols += "⇧" }
        if m.contains(.command) { flags.insert(.maskCommand); symbols += "⌘" }
        let code = Int64(event.keyCode)
        let key = Self.names[code] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: code, modifiers: flags.rawValue, display: symbols + key)
    }

    private static let functionKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    private static let names: [Int64: String] = [
        53: "Esc", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12",
    ]
}

extension Settings {
    static var dictationKey: DictationKey {
        get { UserDefaults.standard.string(forKey: "dictationKey").flatMap(DictationKey.init(rawValue:)) ?? .rightOption }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dictationKey") }
    }

    /// nil: double-tap the dictation key.
    static var transcriptionShortcut: Shortcut? {
        get { shortcut("transcriptionShortcut") }
        set { setShortcut(newValue, "transcriptionShortcut") }
    }

    /// nil: only from the menu.
    static var handsFreeShortcut: Shortcut? {
        get { shortcut("handsFreeShortcut") }
        set { setShortcut(newValue, "handsFreeShortcut") }
    }

    static var cancelShortcut: Shortcut {
        get { shortcut("cancelShortcut") ?? .escape }
        set { setShortcut(newValue, "cancelShortcut") }
    }

    private static func shortcut(_ key: String) -> Shortcut? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    private static func setShortcut(_ s: Shortcut?, _ key: String) {
        if let s, let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// How the current shortcuts read in hints ("Hold right ⌥", "Double-tap right ⌥").
enum ShortcutHints {
    static var dictate: String { "Hold \(Settings.dictationKey.name)" }
    static var transcribe: String { Settings.transcriptionShortcut?.display ?? "Double-tap \(Settings.dictationKey.name)" }
    static var handsFree: String? { Settings.handsFreeShortcut?.display }
    static var cancel: String { Settings.cancelShortcut.display }
}

/// A button that records the next key combination. Delete clears it (where that's allowed).
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    var placeholder: String
    var requireModifier = true
    var onChange: () -> Void = {}
    @State private var recording = false
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        HStack(spacing: 6) {
            if let warning {
                Text(warning).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Brand.emberText)
            }
            Button(action: toggle) {
                let set = shortcut != nil && !recording
                Text(recording ? "Type the shortcut…" : shortcut?.display ?? placeholder)
                    .font(.system(size: 12, weight: set ? .semibold : .regular, design: set ? .rounded : .default))
                    .foregroundStyle(set ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 10)
                    .frame(minWidth: 130, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.well))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(recording ? Brand.ember : Brand.hairline, lineWidth: recording ? 1.5 : 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recording ? "Press the keys now. Delete removes the shortcut, Esc cancels."
                  : "Click, then press the key combination you want")
            if shortcut != nil && !recording {
                Button { set(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help("Back to: \(placeholder)")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        warning = nil
        HotkeyMonitor.paused = true  // the global tap would otherwise act on the keys being recorded
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let s = Shortcut(event)
            if s.keyCode == 51 && s.modifiers == 0 {  // Delete
                set(nil)
            } else if s.keyCode == 53 && s.modifiers == 0 && requireModifier {  // Esc: cancel
                stop()
            } else if requireModifier && !s.hasModifier {
                warning = "Add ⌘, ⌥ or ⌃"
            } else {
                set(s)
            }
            return nil
        }
    }

    private func set(_ s: Shortcut?) {
        shortcut = s
        stop()
        onChange()
    }

    private func stop() {
        recording = false
        HotkeyMonitor.paused = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

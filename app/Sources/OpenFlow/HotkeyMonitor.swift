import AppKit
import CoreGraphics

/// Global hotkeys via a CGEventTap: the dictation key (a modifier you hold, right ⌥ by default),
/// key combinations for other actions, and a cancel key.
/// Pressing any other key while the dictation key is held turns it into a normal modifier chord
/// (e.g. ⌥L for @ on German layouts) and reports `onChord` instead.
/// While `cancelIsActive()` returns true, the cancel key is swallowed and reported as `onCancel`.
final class HotkeyMonitor {
    /// While a shortcut is being recorded in the OpenFlow window, nothing fires.
    static var paused = false

    var dictationKey = DictationKey.rightOption
    var cancelKey = Shortcut.escape
    /// Combinations and what they do; matched on key down and swallowed.
    var shortcuts: [(Shortcut, () -> Void)] = []

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onChord: () -> Void = {}
    var onCancel: () -> Void = {}
    var cancelIsActive: () -> Bool = { false }

    private var tap: CFMachPort?
    private var isDown = false

    var isRunning: Bool { tap != nil }

    /// Returns false while Accessibility / Input Monitoring permission is missing.
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // not listen-only: needed to swallow shortcuts and the cancel key
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true to swallow the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if Self.paused {
            isDown = false
            return false
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if cancelKey.matches(event), cancelIsActive() {
                isDown = false
                onCancel()
                return true
            }
            if isDown {
                isDown = false
                onChord()
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               let action = shortcuts.first(where: { $0.0.matches(event) })?.1 {
                action()
                return true
            }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == dictationKey.keyCode else {
                // Another modifier joined (e.g. ⌥⇧): treat as a chord, not dictation.
                if isDown { isDown = false; onChord() }
                return false
            }
            let down = event.flags.contains(dictationKey.flag)
            if down && !isDown {
                isDown = true
                onPress()
            } else if !down && isDown {
                isDown = false
                onRelease()
            }
        default:
            break
        }
        return false
    }
}

import AppKit
import SwiftUI

/// Side panel for transcription mode: full height on the right edge of the screen with the mouse,
/// resizable from its edges (the width is remembered). It never activates OpenFlow (the meeting
/// app keeps focus) but takes clicks and scrolling.
final class TranscriptPanel {
    var onStop: () -> Void = {}
    private let model: TranscriptModel
    private let panel: NSPanel
    private static let widthKey = "transcriptPanelWidth"
    private static let margin: CGFloat = 12

    init(model: TranscriptModel) {
        self.model = model
        panel = ClickablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the glass draws its own
        let host = NSHostingView(rootView: TranscriptView(
            model: model,
            onStop: { [weak self] in self?.onStop() },
            onClose: { [weak self] in self?.hide() }
        ))
        host.sizingOptions = []
        panel.contentView = host
        panel.minSize = NSSize(width: 300, height: 320)
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main) { [panel] _ in
            UserDefaults.standard.set(Double(panel.frame.width), forKey: Self.widthKey)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let saved = CGFloat(UserDefaults.standard.double(forKey: Self.widthKey))
            let width = min(max(saved > 0 ? saved : 400, panel.minSize.width), f.width / 2)
            panel.setFrame(NSRect(x: f.maxX - width - Self.margin, y: f.minY + Self.margin,
                                  width: width, height: f.height - 2 * Self.margin), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in panel.orderOut(nil) })
    }
}

/// Borderless panels refuse key status by default; this one may take it for a click
/// (becomesKeyOnlyIfNeeded keeps it from stealing typing focus).
private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private let them = Brand.tide

private struct TranscriptView: View {
    @ObservedObject var model: TranscriptModel
    var onStop: () -> Void
    var onClose: () -> Void
    /// Offscreen rendering (README images): no scroll view, which ImageRenderer can't draw.
    var still = false
    @State private var following = true

    var body: some View {
        if still {
            // Glass can't be drawn offscreen; a light frosted surface stands in for it.
            panel
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.97).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.5)))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .environment(\.colorScheme, .light)
        } else {
            panel.glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            Divider().opacity(0.5)
            transcript
            Divider().opacity(0.5)
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.3), value: model.finishing)
        .animation(.smooth(duration: 0.3), value: model.ended)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            if model.ended != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Brand.ok)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved").font(.display(16))
                    if let url = model.fileURL {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                iconButton("doc.on.doc", help: "Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TranscriptStore.markdown(model), forType: .string)
                }
                iconButton("folder", help: "Show in Finder") {
                    if let url = model.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                iconButton("xmark", help: "Close", action: onClose)
            } else {
                RecordingDot(active: !model.finishing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.finishing ? "Finishing…" : "Transcribing")
                        .font(.display(16))
                    TimelineView(.periodic(from: model.started, by: 1)) { t in
                        Text(Self.elapsed(from: model.started, to: t.date))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                meter("You", level: model.level, fill: AnyShapeStyle(Brand.ember))
                    .help("Your microphone")
                meter("Them", level: model.themLevel, fill: AnyShapeStyle(them))
                    .help("What your Mac plays. Flat while nothing plays; if it stays flat while others talk, allow "
                        + "OpenFlow in System Settings → Privacy & Security → Screen & System Audio Recording.")
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Brand.ember))
                }
                .buttonStyle(.plain)
                .disabled(model.finishing)
                .opacity(model.finishing ? 0.4 : 1)
                .help("Stop (or \(ShortcutHints.transcribe.lowercasedFirst))")
            }
        }
    }

    private func meter(_ label: String, level: Float, fill: AnyShapeStyle) -> some View {
        VStack(spacing: 1) {
            LevelBars(level: level, finishing: model.finishing, fill: fill)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        let blocks = model.blocks(includeLive: true)
        if blocks.isEmpty {
            VStack(spacing: 6) {
                Text(model.ended == nil ? "Listening…" : "Nothing was said.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("You: your microphone · Them: what your Mac plays")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if still {
            VStack(alignment: .leading, spacing: 16) {
                Spacer(minLength: 0)
                ForEach(blocks) { BlockView(block: $0) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(blocks) { BlockView(block: $0) }
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .defaultScrollAnchor(.bottom)
                // Follow new text unless the reader scrolled up; scrolling back to the end resumes it.
                .onScrollPhaseChange { _, phase, context in
                    guard phase == .idle else { return }
                    let g = context.geometry
                    following = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 60
                }
                .onChange(of: Self.revision(of: blocks)) {
                    guard following else { return }
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
        }
    }

    private static let end = "end"

    /// Changes whenever text is added or replaced anywhere in the transcript.
    private static func revision(of blocks: [TranscriptModel.Block]) -> Int {
        blocks.reduce(blocks.count) { n, b in b.segments.reduce(n) { $0 &+ $1.text.count &+ $1.id &* 31 } }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.warn)
            }
            if model.cancellingEcho && model.ended == nil {
                Label("Speakers: removing their audio from your mic", systemImage: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Label("Always get consent when transcribing others.", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: TranscriptModel.Block

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(block.speaker.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(block.speaker == .you ? AnyShapeStyle(Brand.emberText) : AnyShapeStyle(them))
                Text(TranscriptStore.format(block.start, "HH:mm"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            // One flowing paragraph; text still being recognized is dimmed until the final decoder confirms it.
            block.segments.enumerated().reduce(Text("")) { text, item in
                let (i, s) = item
                return text + Text(verbatim: (i > 0 ? " " : "") + s.text)
                    .foregroundStyle(s.stage == .live ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            .font(.system(size: 14))
            .lineSpacing(2)
            .textSelection(.enabled)
            .contentTransition(.interpolate)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RecordingDot: View {
    var active: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(active ? Brand.ember : Color.secondary)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Brand.ember.opacity(active ? 0.5 : 0), lineWidth: 2).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
            .frame(width: 22, height: 22)
    }
}

/// `OpenFlow --render-panel out.png`: the panel in the middle of a meeting, rendered offscreen over
/// the demo backdrop for the README. Nothing is shown on screen and nothing is captured from it.
@MainActor func renderTranscriptPreview(to url: URL) {
    let model = TranscriptModel()
    let now = Date()
    model.started = now.addingTimeInterval(-754)
    model.level = 0.035
    model.themLevel = 0.0005
    let lines: [(Speaker, String, TranscriptSegment.Stage)] = [
        (.you, "Okay, lass uns kurz den Status zum Release durchgehen.", .polished),
        (.them, "Yes, so the pull request is merged and QA starts tomorrow at 9.", .polished),
        (.them, "We still need sign-off from security, though.", .polished),
        (.you, "Gut, dann schieben wir das Deployment auf Donnerstag um 10 Uhr.", .polished),
        (.them, "Works for me. Can you send the summary to the team after the call?", .final),
        (.you, "Mach ich, ich schicke sie euch direkt nach dem", .live),
    ]
    model.segments = lines.enumerated().map { i, line in
        TranscriptSegment(id: i + 1, speaker: line.0, start: now.addingTimeInterval(Double(i - lines.count) * 25),
                          text: line.1, stage: line.2)
    }
    let view = ZStack {
        DemoBackdrop()
        TranscriptView(model: model, onStop: {}, onClose: {}, still: true)
            .frame(width: 400, height: 640)
    }
    .frame(width: 560, height: 700)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        print("render failed"); return
    }
    try? png.write(to: url)
    print("wrote \(url.path)")
}

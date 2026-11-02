import Foundation

/// --transcribetest SOCKET YOU.wav [THEM.wav] [--no-parakeet]: transcription mode on WAV files
/// (16 kHz mono Int16) instead of the mic and the system audio, against a running server
/// (`uv run server.py --socket SOCKET`), at 4x real time. Prints the segments and the Markdown.
func runTranscribeTest(_ args: [String]) {
    Settings.registerDefaults()
    let files = args.dropFirst().filter { !$0.hasPrefix("--") }
    guard let socket = args.first, let youFile = files.first, let you = loadWAV(youFile) else {
        print("usage: --transcribetest SOCKET YOU.wav [THEM.wav] [--no-parakeet]")
        exit(2)
    }
    let them = files.dropFirst().first.flatMap(loadWAV)
    let client = ASRClient(socketPath: socket)
    guard client.connect() else {
        print("no server on \(socket)")
        exit(1)
    }
    let t = Transcriber(client: client, socketPath: socket, mic: AudioCapture())
    client.onEvent = { _ = t.handleMain($0) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("openflow-transcribetest.md")
    let started = Date()
    t.onFinished = {
        print(String(format: "finished %.1f s after the start", Date().timeIntervalSince(started)))
        for s in t.model.segments.sorted(by: { $0.start < $1.start }) {
            print(String(format: "%@ %6.1f–%6.1f s  %@  %@", s.speaker.rawValue, s.start.timeIntervalSince(t.model.started),
                         s.end.timeIntervalSince(t.model.started), "\(s.stage)", s.text))
        }
        print("\n" + TranscriptStore.markdown(t.model))
        exit(0)
    }
    let go = {
        t.startForFiles(them: them != nil, file: file)
        print("finals from \(t.liveOnly ? "Parakeet" : "the server's final decoder")")
        Thread {
            let tail = [Int16](repeating: 0, count: 32_000)  // 2 s of silence closes the last segment
            let a = you + tail, b = (them ?? []) + tail
            let step = 1_600
            for i in stride(from: 0, to: max(a.count, b.count), by: step) {
                t.feedFile(.you, chunk(a, i, step))
                if them != nil { t.feedFile(.them, chunk(b, i, step)) }
                Thread.sleep(forTimeInterval: 0.1 / 4)
            }
            DispatchQueue.main.async { t.stop() }
        }.start()
    }
    if args.contains("--no-parakeet") { go() } else { t.finalPass.prepare { _ in go() } }
    dispatchMain()
}

private func loadWAV(_ path: String) -> [Int16]? {
    guard let data = FileManager.default.contents(atPath: path), data.count > 44 else { return nil }
    return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

private func chunk(_ s: [Int16], _ i: Int, _ n: Int) -> Data {
    let part = i < s.count ? Array(s[i..<min(i + n, s.count)]) : []
    let padded = part + [Int16](repeating: 0, count: n - part.count)
    return padded.withUnsafeBufferPointer { Data(buffer: $0) }
}

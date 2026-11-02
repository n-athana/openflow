// swift run -c release parakeet-bench DIR [ultra|v3]
// Reads DIR/manifest.jsonl (asr/bench_wer.py prepare), appends DIR/hyp-parakeet-<version>.jsonl.
// "ms" is the transcribe call on a warm model: what a final pass would add after a segment ends.
import FluidAudio
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: parakeet-bench DIR [ultra|v3]\n".data(using: .utf8)!)
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
let name = args.count > 2 ? args[2] : "ultra"
let version: AsrModelVersion = name == "v3" ? .v3 : .ultra

struct Clip: Decodable { let id: String; let wav: String }
struct Hyp: Codable { let id: String; let text: String; let ms: Int }

let manifest = try String(contentsOf: dir.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
    .split(separator: "\n").map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
let out = dir.appendingPathComponent("hyp-parakeet-\(name).jsonl")
var done = Set<String>()
if let existing = try? String(contentsOf: out, encoding: .utf8) {
    for line in existing.split(separator: "\n") {
        if let h = try? JSONDecoder().decode(Hyp.self, from: Data(line.utf8)) { done.insert(h.id) }
    }
} else {
    FileManager.default.createFile(atPath: out.path, contents: nil)
}

@MainActor func run() async throws {
    let t0 = Date()
    let models = try await AsrModels.downloadAndLoad(version: version)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    let converter = AudioConverter()
    var warm = TdtDecoderState.make()
    _ = try await asr.transcribe([Float](repeating: 0, count: 16000), decoderState: &warm)
    print(String(format: "loaded %@ in %.1f s", name, Date().timeIntervalSince(t0)))

    let handle = try FileHandle(forWritingTo: out)
    handle.seekToEndOfFile()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    for clip in manifest where !done.contains(clip.id) {
        let samples = try converter.resampleAudioFile(dir.appendingPathComponent(clip.wav))
        var state = TdtDecoderState.make()
        let start = Date()
        let result = try await asr.transcribe(samples, decoderState: &state)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        handle.write(try encoder.encode(Hyp(id: clip.id, text: result.text, ms: ms)) + Data("\n".utf8))
        print("\(clip.id)  \(ms) ms  \(result.text.prefix(80))")
    }
    try handle.close()
}

try await run()

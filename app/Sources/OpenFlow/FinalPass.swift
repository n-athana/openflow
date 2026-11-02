import FluidAudio
import Foundation

/// Transcription mode's final text: Parakeet TDT 0.6B v3 "Ultra" (FluidAudio, Core ML on the Neural
/// Engine) transcribes every finished segment again. On FLEURS it makes half the streaming
/// decoder's errors (German 4.5 % vs. 10.7 % WER, English 5.2 % vs. 11.8 %; asr/bench_wer.py) at
/// ~0.1 s per segment, and leaves the GPU to the live text and the polish LLM. The model (~630 MB)
/// downloads on first use; until it's ready the streaming decoder's finals are used as before.
final class FinalPass {
    /// Loaded once before: later launches load it right away (from disk, 0.3 s).
    static var downloaded: Bool { Settings.parakeetFinals && UserDefaults.standard.bool(forKey: "parakeetDownloaded") }

    /// Main thread.
    private(set) var isReady = false
    private var loading = false
    private var waiting: [(Bool) -> Void] = []
    private var manager: AsrManager?

    /// Loads the model in the background (downloading it once); `done` on main.
    func prepare(_ done: @escaping (Bool) -> Void = { _ in }) {
        guard Settings.parakeetFinals, !isReady else { return done(isReady) }
        waiting.append(done)
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            var asr: AsrManager?
            do {
                let t = Date()
                let models = try await AsrModels.downloadAndLoad(version: .ultra)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                var state = TdtDecoderState.make()
                _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
                NSLog("OpenFlow: Parakeet ready (%.1f s)", Date().timeIntervalSince(t))
                asr = manager
            } catch {
                NSLog("OpenFlow: Parakeet unavailable, keeping the streaming finals: %@", error.localizedDescription)
            }
            let loaded = asr
            await MainActor.run {
                self.manager = loaded
                self.isReady = loaded != nil
                if loaded != nil { UserDefaults.standard.set(true, forKey: "parakeetDownloaded") }
                self.loading = false
                let callbacks = self.waiting
                self.waiting = []
                callbacks.forEach { $0(loaded != nil) }
            }
        }
    }

    /// Text for one segment of 16 kHz mono Int16 audio, nil if it failed; `done` on main.
    func transcribe(_ pcm: [Int16], _ done: @escaping (String?) -> Void) {
        guard let manager else { return done(nil) }
        // 0.3 s of silence around the audio keeps the first and last words; Parakeet wants ≥ 1 s.
        let pad = [Float](repeating: 0, count: 4_800)
        var samples = pad + pcm.map { Float($0) / 32_768 } + pad
        if samples.count < 16_000 { samples += [Float](repeating: 0, count: 16_000 - samples.count) }
        Task.detached(priority: .userInitiated) { [samples] in
            var state = TdtDecoderState.make()
            var text: String?
            do {
                text = try await manager.transcribe(samples, decoderState: &state).text
            } catch {
                NSLog("OpenFlow: Parakeet failed on a segment: %@", error.localizedDescription)
            }
            let result = text
            await MainActor.run { done(result) }
        }
    }
}

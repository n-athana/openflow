# Developing OpenFlow

The [README](../README.md) is for people using OpenFlow. This page is for building, changing and
understanding it.

## Build from source
`scripts/install.sh` runs these steps; run them by hand to see each one:
```bash
cd asr && uv sync                     # Python 3.12 env: torch, transformers, mlx-lm
uv run bench.py ../samples/*.wav      # downloads the speech model (~2.4 GB) once and benchmarks it
uv run polish.py                      # downloads the cleanup LLM (~3 GB) once
cd ..
scripts/make-cert.sh                  # once: stable code signature (see below)
scripts/build-app.sh && open build/OpenFlow.app
```
**Why make-cert?** macOS ties the three permissions to the app's code signature. Without a stable
signature, every rebuild is a "new" app and you have to grant everything again. `make-cert.sh`
creates a self-signed "OpenFlow Dev" identity in its own keychain
(`~/Library/Keychains/openflow-signing.keychain-db`, added to your keychain search list). It needs
no password prompt and no trust settings, and `build-app.sh` uses it automatically.
Remove it with `scripts/make-cert.sh --remove`.

## How it works
```
OpenFlow.app (Swift, menu bar)                    asr/server.py (Python sidecar)
 HotkeyMonitor  CGEventTap: right ⌥, Esc
 AudioCapture   AVAudioEngine → 16 kHz Int16 ──▶ Unix socket ──▶ Nemotron, live decoder (320 ms)
 AudioDevices   CoreAudio input selection                         + final decoder (1.12 s)
 OverlayPanel   SwiftUI + Liquid Glass        ◀── JSON partials/final + language tag
 FillerFilter   regex cleanup
 TextFormatter  lists + layout commands, live
 TextInserter   pasteboard swap + ⌘V
 SidecarManager spawns `uv run server.py`, restarts on crash
 Transcriber    transcription mode: segments,  ──▶ 2nd connection, 2nd decoder set ("Them")
                Markdown store                 ──▶ polish.py: Gemma 4 E2B via MLX
 SystemAudioCapture  Core Audio process tap
 TranscriptPanel     side panel
```
- **Two decoders, one pass each.** The HUD uses 320 ms chunks (`--lookahead 3`, ~20 ms compute per
  chunk on an M5 Pro). In parallel, a second instance with 1.12 s of right context (`--final-lookahead 13`)
  produces the text that gets pasted. NVIDIA reports lower error rates at the longer context
  (German FLEURS 8.9 → 8.2 % WER). Both run as streams, so the final text still arrives ~120 ms after the
  mic closes. `--final-lookahead 3` switches back to a single decoder.
- The model runs in fp16 (same transcripts as fp32 in our tests, ~25 % faster); `--fp32` to compare.
  The instances share the GPU chunk by chunk: generate() keeps streaming state on the model object,
  and Metal asserts when two threads use the GPU at once (that includes model loads and the MLX
  polish model). Each decoder serves one session at a time; a new session waits for the previous one
  to flush.
- Transcription mode's system audio runs concurrently with the mic, so it gets a second decoder set
  (loaded on first use, ~2.4 GB). With the polish model, transcription mode uses ~8 GB of GPU memory.
- `--vocabulary FILE` (the app passes `~/Documents/OpenFlow/Vocabulary.md`, or `""` when it's off) is
  re-read at the start of a session when it changed; `--no-boost` keeps only the spelling fixes and the
  glossary, `--boost-start`/`--boost-strength` tune the bonus (default 1 and 3 logits).
- `--language de-DE` pins the language for every session; the app's Language menu does the same per dictation.
- Output is limited to Latin script. In auto mode the language tag only arrives at the end of the first
  sentence, and until then the first words could come out in Devanagari, Hebrew or CJK (80 % of the
  vocabulary). `--no-latin-only` lifts the limit, for Greek, Russian and other scripts.
- The socket protocol is documented in `asr/server.py`; the app talks to
  `~/Library/Application Support/OpenFlow/asr.sock` and reuses a server you started by hand.
- The app starts the sidecar with `HF_HUB_OFFLINE=1`, so run `bench.py` once to cache the model.
  Sidecar log: `~/Library/Logs/OpenFlow-asr.log`.

## Vocabulary internals
How the vault scan works:
- **Connect once:** on the Vocabulary page, Connect Vault lists the vaults Obsidian knows; "Choose
  Folder…" takes any folder of Markdown notes. The polish LLM (Gemma 4 E2B) reads every note and lists
  the people, organizations, projects, products, acronyms and jargon in it (~1 s per note). Rules keep
  it honest: a name must appear in the note word for word, takes the note's spelling, and job titles,
  ticket keys, file names and words the recognizer already knows ("Python", "Inbox") are dropped.
  OpenFlow's own transcripts are skipped, so the recognizer's mistakes don't become vocabulary. The
  vault card shows the progress, and a notification says how many terms it learned.
- **One model for everything** (`asr/bench_llm.py`, October 2026): Gemma 4 E2B passed all 16 cleanup
  cases at ~130 ms, where Qwen 3.5 and larger Gemma/Nemotron models translated a segment or took 2–6×
  as long. For the vault scan Qwen 3.5 4B finds more names (86 % vs. 60 % on hand-labelled notes) but
  would be a second ~3 GB download; `sweep.py --model mlx-community/Qwen3.5-4B-MLX-4bit` uses it anyway.

How the list is used, at three points:
1. **While decoding**, the recognizer gets a small bonus for tokens that start a vocabulary term at a
   word start, and a larger one once a couple of letters match (shallow fusion with a character trie,
   so it doesn't matter how the model splits the word). This works in dictation too, adds no
   measurable time, and invented nothing in silence or noise in the benchmark.
2. **After decoding**, spellings are normalized: "data garage" and "Datagarage" become "Data
   Garage", "E T L" becomes "ETL", and "(heard as: …)" aliases are replaced. Terms that are ordinary
   words ("CoP" vs. "the cop") are left alone.
3. **In transcription mode**, the polish LLM gets the domain and the ~15 terms that resemble something
   in the segment.

On the benchmark (64 TTS clips in German and English, `asr/bench_vocab.py`), terms come out right
57 % of the time instead of 36 % (45 % with the spelling fixes alone), sentences without terms don't
get worse, and nothing is invented in silence or noise. With a few hundred terms from a real vault
loaded the gain is the same.
Why not retrain the model on the vocabulary? A vault has text, not audio of you saying the words; TTS
audio would teach the model TTS voices; retraining takes hours, would have to be redone whenever your
notes change, and can cost general accuracy. Biasing applies a change on the next dictation.

## Transcription internals
- Each stream is cut into segments at pauses. A segment appears dimmed while it's being recognized,
  turns solid when the 1.12 s decoder confirms it, then gets a cleanup pass by
  [Gemma 4 E2B](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit) (MLX, ~200 ms): punctuation,
  stutters, self-corrections, numbers as digits, misheard terms ("pool request" → "pull request").
  It never translates or answers what was said, and an output much shorter or longer than the input is
  discarded. It won a 14-case German/English benchmark against Qwen 3.5 2B/4B, Ministral 3 3B and
  LFM 2.5 1.2B.
- **On speakers** the mic also hears the other side. When the Mac plays through its speakers, a
  display, HDMI or AirPlay, the mic runs through macOS voice processing, which removes what the
  speakers play (any app's audio) and keeps your voice, also while you talk over someone. Other apps
  aren't turned down. As a second line of defense, runs of 3+ words under "You" that "Them" said
  within 20 s are cut, keeping your own words around them. With headphones neither is needed.
- The transcript is written to `YYYY-MM-DD HH-MM.md` in the transcripts folder
  (`~/Documents/OpenFlow/Transcripts` unless changed in Settings) after every finished segment (atomic
  rewrite), so a crash loses at most the segment being spoken. No audio is stored.
- Toggle from scripts or Shortcuts: post the distributed notification `dev.openflow.toggleTranscription`.

## Design
Everything visual comes from [Theme.swift](../app/Sources/OpenFlow/Theme.swift): the palette (ink,
paper, one ember accent, tide for "Them"), New York for headlines, and the shared pieces (cards,
setting rows, keycaps, buttons, the mark). The mark is three voice bars that end in a line of text;
its geometry (`MarkGeometry`) is shared by the in-app mark, the menu bar icon, `make-icon.swift` and
`make-banner.swift`. The HUD and the transcript panel use Liquid Glass on macOS 26 and a blur
material before.

README images come only from captures of OpenFlow's own window (`screencapture -l <window id>`) or
offscreen renders, never from a screen region, which can catch whatever else is on screen.

## Commands
| Command | What it does |
|---|---|
| `cd asr && uv run bench.py ../samples/*.wav` | Real-time factor, per-chunk compute, transcripts |
| `cd asr && uv run server.py --socket /tmp/t.sock`, then `uv run smoke.py ../samples/de.wav --socket /tmp/t.sock` | Stream a WAV through the server at speaking pace |
| `build/OpenFlow.app/Contents/MacOS/OpenFlow --selftest` | Filler-filter and formatter test cases |
| `open -n build/OpenFlow.app --args --mictest` | Capture 1 s from each input device, write chunk counts and start latency to `/tmp/openflow-mictest.txt` (runs with the app's mic permission) |
| `build/OpenFlow.app/Contents/MacOS/OpenFlow --demo` | Loop a fake dictation through the HUD (design work, no mic) |
| `build/OpenFlow.app/Contents/MacOS/OpenFlow --transcript-demo` | Loop a fake meeting through the transcription panel |
| `cd asr && uv run polish.py "so the the build is uh twenty percent faster"` | Run the polish LLM on a segment (with a sample glossary) |
| `cd asr && uv run sweep.py --vault ~/notes --out /tmp/Vocabulary.md` | Learn a vocabulary from a vault (`--no-llm`: rules only) |
| `cd asr && uv run bench_vocab.py [--vocabulary FILE] [--show]` | Term recall and damage to ordinary speech, boost off vs. on |
| `cd asr && uv run bench_llm.py mlx:<hf id> ollama:<tag> [--task sweep --vault … --gold …]` | Compare LLMs on transcript polish and vault extraction, with the production prompts |
| `build/OpenFlow.app/Contents/MacOS/OpenFlow --onboarding-demo [STEP]` | The setup guide, from step 0–4 |
| `build/OpenFlow.app/Contents/MacOS/OpenFlow --vocabulary-demo [FILE]` | The OpenFlow window on a copy of a vocabulary file (`OPENFLOW_DEMO_PAGE=General` for another page) |
| `swift scripts/make-icon.swift app/Resources/AppIcon.icns` | Regenerate the app icon |
| `swift scripts/make-banner.swift docs/images/banner.png` | Regenerate the README banner |
| `build/OpenFlow.app/Contents/MacOS/OpenFlow --render-panel out.png` | Render the transcript panel mid-meeting, offscreen, for the README (glass replaced by a frosted surface) |

`samples/` holds two clips made with macOS `say` (voices Anna and Samantha).

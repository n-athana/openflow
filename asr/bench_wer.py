"""Word error rate of the app's final decoder against other ASR models, on FLEURS German and English.

    uv run --with pyarrow --with jiwer bench_wer.py prepare /path/to/fleurs DIR   # de_de.parquet, en_us.parquet
    uv run bench_wer.py nemotron DIR [--language auto]                            # -> DIR/hyp-nemotron-*.jsonl
    (other models write the same JSONL: {"id": ..., "text": ..., "ms": ...}; see scripts/parakeet-bench)
    uv run --with jiwer bench_wer.py score DIR

`prepare` writes 16 kHz WAVs and a manifest: every test clip, plus "long" files of 12 different
sentences joined by 0.8 s of silence (~2.5 min each, like a stretch of meeting). WER on the long
files minus WER on the same clips one by one is what a model loses at window seams and over time.
Nemotron runs through server.Engine exactly as the app does (fp16, final lookahead 13, Latin only,
no vocabulary), with all audio pushed at once, so "ms" is throughput, not live latency.
"""

import argparse
import json
import re
import sys
import time
import unicodedata
import wave
from pathlib import Path

import numpy as np

SR = 16000
LANGS = {"de_de": "de", "en_us": "en"}
LONG_CLIPS, LONG_GAP, LONG_FILES = 12, 0.8, 10


def write_wav(path: Path, audio: np.ndarray):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())


def read_wav(path: str) -> np.ndarray:
    with wave.open(path, "rb") as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def prepare(src: Path, out: Path):
    import io

    import librosa
    import pyarrow.parquet as pq
    import soundfile as sf

    (out / "clips").mkdir(parents=True, exist_ok=True)
    manifest = []
    for name, lang in LANGS.items():
        table = pq.read_table(src / f"{name}.parquet", columns=["id", "audio", "transcription"]).to_pylist()
        clips = {}  # id -> (audio, text); FLEURS repeats a sentence with other speakers, keep one each for "long"
        for i, row in enumerate(table):
            audio, sr = sf.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32")
            if audio.ndim > 1:
                audio = audio.mean(axis=1)
            if sr != SR:
                audio = librosa.resample(audio, orig_sr=sr, target_sr=SR)
            key = f"{lang}-{i:04d}"
            write_wav(out / "clips" / f"{key}.wav", audio)
            manifest.append({"id": key, "lang": lang, "kind": "clip", "wav": f"clips/{key}.wav",
                             "ref": row["transcription"], "seconds": round(len(audio) / SR, 2)})
            clips.setdefault(row["id"], (key, audio, row["transcription"]))
        distinct = list(clips.values())
        gap = np.zeros(int(LONG_GAP * SR), dtype=np.float32)
        for n in range(LONG_FILES):
            group = distinct[n * LONG_CLIPS : (n + 1) * LONG_CLIPS]
            audio = np.concatenate([part for _, a, _ in group for part in (a, gap)])
            key = f"{lang}-long{n:02d}"
            write_wav(out / "clips" / f"{key}.wav", audio)
            manifest.append({"id": key, "lang": lang, "kind": "long", "wav": f"clips/{key}.wav",
                             "ref": " ".join(t for _, _, t in group), "parts": [k for k, _, _ in group],
                             "seconds": round(len(audio) / SR, 2)})
        print(f"{name}: {len(table)} clips, {LONG_FILES} long files")
    with open(out / "manifest.jsonl", "w") as f:
        for m in manifest:
            f.write(json.dumps(m, ensure_ascii=False) + "\n")


def load_manifest(out: Path) -> list[dict]:
    return [json.loads(line) for line in open(out / "manifest.jsonl")]


def nemotron(out: Path, language: str, lookahead: int):
    import torch

    from server import Engine, Session

    engine = Engine("mps", lookahead, lookahead, language, torch.float16, True, vocabulary="", boost=None)
    engine.warm_up()
    path = out / f"hyp-nemotron-la{lookahead}-{language}.jsonl"
    done = {json.loads(line)["id"] for line in open(path)} if path.exists() else set()

    with open(path, "a") as f:
        for m in load_manifest(out):
            if m["id"] in done:
                continue
            pcm = (np.clip(read_wav(str(out / m["wav"])), -1, 1) * 32767).astype("<i2").tobytes()
            result = {}
            t = time.perf_counter()
            s = Session(engine, language, lambda kind, text, lang, **_: result.update({kind: (text, lang)}))
            s.push(pcm)
            s.end()
            s.join()
            ms = (time.perf_counter() - t) * 1000
            text, lang = result.get("final", ("", None))
            f.write(json.dumps({"id": m["id"], "text": text, "lang": lang, "ms": round(ms)}, ensure_ascii=False) + "\n")
            f.flush()
            print(f"{m['id']}  {ms:6.0f} ms  {text[:80]}", flush=True)


def normalize(text: str) -> str:
    """Lowercase, no punctuation, one space: FLEURS' "transcription" field is already like that."""
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"[’'`´]", "", text)
    text = re.sub(r"[^\w\s]|_", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def score(out: Path):
    import jiwer

    manifest = {m["id"]: m for m in load_manifest(out)}
    print(f"{'model':<28} {'lang':<4} {'clips':>6} {'WER':>7} {'long':>7} {'same clips':>11} {'seam loss':>10} {'RTFx':>7}")
    for path in sorted(out.glob("hyp-*.jsonl")):
        hyps = {h["id"]: h for h in map(json.loads, open(path))}
        name = path.stem.removeprefix("hyp-")
        for lang in LANGS.values():
            def wer(ids):
                ids = [i for i in ids if i in hyps]
                if not ids:
                    return None, 0
                refs = [normalize(manifest[i]["ref"]) for i in ids]
                outs = [normalize(hyps[i]["text"]) for i in ids]
                return jiwer.wer(refs, outs), len(ids)

            clips = [i for i, m in manifest.items() if m["lang"] == lang and m["kind"] == "clip"]
            longs = [i for i, m in manifest.items() if m["lang"] == lang and m["kind"] == "long" and i in hyps]
            clip_wer, n = wer(clips)
            if clip_wer is None:
                continue
            long_wer, _ = wer(longs)
            same, _ = wer([p for i in longs for p in manifest[i]["parts"]])
            secs = sum(manifest[i]["seconds"] for i in clips if i in hyps)
            ms = sum(hyps[i]["ms"] for i in clips if i in hyps)
            fmt = lambda x: f"{x * 100:6.2f}%" if x is not None else "      -"
            print(f"{name:<28} {lang:<4} {n:>6} {fmt(clip_wer)} {fmt(long_wer)} {fmt(same):>11} "
                  f"{fmt(long_wer - same if long_wer is not None and same is not None else None):>10} "
                  f"{secs * 1000 / ms if ms else 0:6.0f}x")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("src", type=Path)
    p.add_argument("out", type=Path)
    p = sub.add_parser("nemotron")
    p.add_argument("out", type=Path)
    p.add_argument("--language", default="auto")
    p.add_argument("--lookahead", type=int, default=13)
    p = sub.add_parser("score")
    p.add_argument("out", type=Path)
    args = ap.parse_args()
    if args.cmd == "prepare":
        prepare(args.src, args.out)
    elif args.cmd == "nemotron":
        nemotron(args.out, args.language, args.lookahead)
    else:
        score(args.out)


if __name__ == "__main__":
    sys.exit(main())

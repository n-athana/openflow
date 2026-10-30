"""Does vocabulary biasing help? Term recall vs. damage to ordinary speech, per boost setting.

Synthesizes German and English sentences with macOS `say`: some contain vocabulary terms, the
controls contain none but have near-misses (Nicole, the top, a garage). Each clip runs through
the server's Engine in-process with boosting off and at a few strengths.

Usage: uv run bench_vocab.py                 (needs the cached Nemotron model)
       uv run bench_vocab.py --grid 1:3 2:5  (start:strength pairs)
"""

import argparse
import logging
import os
import re
import subprocess
import tempfile
import time

import numpy as np
import soundfile as sf
import torch

import server
import vocab

TERMS = ["ACME", "LUMAI", "ToP", "Nemotron", "Gemma", "OpenFlow", "Obsidian", "Data Garage", "Netvora",
         "Kubernetes", "Grafana", "MLX", "SRE", "ETL", "Northwind Logistics", "Malte Oetjen", "Katrin Ruppert",
         "Yannick Thiel"]

WITH_TERMS = {
    "de": [
        "Ich habe mit Malte Oetjen über die LUMAI Roadmap gesprochen.",
        "Die ToP trifft sich nächste Woche im Data Garage.",
        "Wir testen Nemotron und Gemma lokal mit MLX.",
        "Kannst du das OpenFlow Repo in Obsidian verlinken?",
        "Der SRE Fall bei Northwind Logistics hat die ETL Planung verschoben.",
        "Katrin Ruppert schickt das Grafana Dashboard für Kubernetes.",
        "Netvora baut die neue Seite für die ACME.",
        "Yannick Thiel übernimmt den Workshop im Data Garage.",
    ],
    "en": [
        "I talked to Malte Oetjen about the LUMAI roadmap.",
        "The ToP meets next week in the Data Garage.",
        "We run Nemotron and Gemma locally with MLX.",
        "Can you link the OpenFlow repo in Obsidian?",
        "The SRE case at Northwind Logistics delayed the ETL planning.",
        "Katrin Ruppert sends the Grafana dashboard for Kubernetes.",
        "Netvora builds the new site for ACME.",
        "Yannick Thiel takes over the workshop in the Data Garage.",
    ],
}
CONTROLS = {
    "de": [
        "Nicole hat das Paket gestern abgeholt.",
        "Wir gehen am Samstag in die Garage und dann zum Mittagessen.",
        "Die Gemeinde plant eine neue Schule im Norden.",
        "Kannst du mir das Rezept für den Kuchen schicken?",
        "Er hat den Termin um zehn Uhr verschoben.",
        "Das Netz ist heute sehr langsam.",
        "Malen macht ihr viel Spaß.",
        "Ob sie morgen kommt, ist noch offen.",
    ],
    "en": [
        "Nicole picked up the package yesterday.",
        "The open window let the cold air in.",
        "My grandma bakes the best cookies.",
        "Can you send me the report by Friday?",
        "The team met in the garage after lunch.",
        "He moved the meeting to ten o'clock.",
        "The net was full of fish.",
        "Obviously the top shelf was full.",
    ],
}
VOICES = {"de": ["Anna", "Flo (German (Germany))"], "en": ["Samantha", "Daniel"]}


def words(text: str) -> list[str]:
    return re.findall(r"\w+", text.lower())


def wer(ref: str, hyp: str) -> tuple[int, int]:
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
    return d[len(h)], len(r)


def has(term: str, text: str) -> bool:
    return re.search(rf"(?<!\w){re.escape(term)}(?!\w)", text) is not None


def synthesize(out_dir: str) -> list[tuple[str, str, bool, np.ndarray]]:
    clips = []
    for lang in ("de", "en"):
        for voice in VOICES[lang]:
            for is_term, sentences in ((True, WITH_TERMS[lang]), (False, CONTROLS[lang])):
                for i, text in enumerate(sentences):
                    path = os.path.join(out_dir, f"{lang}-{voice.split()[0]}-{int(is_term)}-{i}.wav")
                    subprocess.run(["say", "-v", voice, "-o", path, "--data-format=LEI16@16000", text], check=True)
                    audio, sr = sf.read(path, dtype="int16")
                    assert sr == 16000
                    clips.append((lang, text, is_term, np.concatenate([np.zeros(4000, np.int16), audio])))
    return clips


def transcribe(engine: server.Engine, audio: np.ndarray, lang: str) -> str:
    result = {}
    s = server.Session(engine, {"de": "de-DE", "en": "en-US"}[lang],
                       lambda kind, text, _lang: result.__setitem__(kind, text))
    s.push(audio.tobytes())
    s.end()
    s.join()
    return result.get("final", "")


def quiet_clips() -> list[np.ndarray]:
    """Silence, room noise and breathing-level noise: anything transcribed here is invented."""
    rng = np.random.default_rng(0)
    return [np.zeros(48000, np.int16)] + [(rng.normal(0, level, 48000)).astype(np.int16) for level in (30, 150, 600)]


def run(engine, clips, label, show):
    hits = total = false = 0
    invented = [transcribe(engine, audio, lang) for audio in quiet_clips() for lang in ("de", "en")]
    invented = [t for t in invented if t]
    errs = {True: [0, 0], False: [0, 0]}
    t = time.perf_counter()
    for lang, ref, is_term, audio in clips:
        hyp = transcribe(engine, audio, lang)
        e, n = wer(ref, hyp)
        errs[is_term][0] += e
        errs[is_term][1] += n
        expected = [term for term in TERMS if has(term, ref)]
        hits += sum(has(term, hyp) for term in expected)
        total += len(expected)
        wrong = [term for term in TERMS if has(term, hyp) and not has(term, ref)]
        false += len(wrong)
        if show and (hyp.rstrip(".?!") != ref.rstrip(".?!")):
            print(f"    {'T' if is_term else 'C'} {hyp}" + (f"   <- inserted {wrong}" if wrong else ""))
    secs = time.perf_counter() - t
    print(f"{label:>16}  terms {hits:>2}/{total} ({hits / total:4.0%})  "
          f"WER terms {errs[True][0] / errs[True][1]:5.1%}  WER controls {errs[False][0] / errs[False][1]:5.1%}  "
          f"false inserts {false}  invented in silence/noise {len(invented)}/8  {secs:5.1f} s", flush=True)
    if show and invented:
        print(f"    noise -> {invented}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grid", nargs="*", default=["1:3", "1.5:4", "2:5", "3:6"])
    ap.add_argument("--vocabulary", help="also load this vocabulary file's terms, e.g. a vault sweep, to test a "
                    "realistic list size")
    ap.add_argument("--show", action="store_true", help="print every transcript that differs from the reference")
    args = ap.parse_args()
    logging.basicConfig(level=logging.WARNING)

    with tempfile.TemporaryDirectory() as d:
        clips = synthesize(d)
        path = os.path.join(d, "Vocabulary.md")
        extra = [t.text for t in vocab.load(args.vocabulary).terms] if args.vocabulary else []
        vocab.write_atomic(path, "## Terms\n" + "".join(f"- {t}\n" for t in TERMS + extra))
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        engine = server.Engine(device, 3, 13, "auto", torch.float16 if device == "mps" else torch.float32, True,
                               path, None)
        print(f"{len(clips)} clips, {len(TERMS)} terms + {len(extra)} from {args.vocabulary}, device {device}")

        def setup(path, boost):
            engine.vocab_path, engine.boost, engine.vocab_mtime = path, boost, None
            engine.vocab, engine.booster = vocab.Vocabulary(), None

        setup("", None)
        run(engine, clips, "raw model", args.show)
        setup(path, None)
        run(engine, clips, "normalize", args.show)
        for pair in args.grid:
            start, strength = map(float, pair.split(":"))
            setup(path, {"start": start, "boost": strength})
            run(engine, clips, f"+ boost {start:g}:{strength:g}", args.show)


if __name__ == "__main__":
    main()

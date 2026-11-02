"""Transcription mode against a running server: one session, cut into segments (K frames).

Streams de.wav, a pause, en.wav, 35 s of silence (nothing playing on the "Them" side), de.wav
again, at real-time pace (--speed 2 = twice as fast), cutting in the middle of each pause the way
the app does: 0.7 s into it, at 0.35 s. Checks that each segment gets its own final with the right
words and audio times, and that the long silence loses nothing.

Usage: uv run server.py --socket /tmp/of-test.sock --vocabulary ""   (in another shell)
       uv run test_segments.py --socket /tmp/of-test.sock [--speed 2]
"""

import argparse
import json
import socket
import threading
import time
import wave

import numpy as np

from smoke import frame

SR = 16000


def load(path: str) -> np.ndarray:
    with wave.open(path, "rb") as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--speed", type=float, default=2.0)
    args = ap.parse_args()

    de, en = load("../samples/de.wav"), load("../samples/en.wav")
    silence = lambda s: np.zeros(int(s * SR), dtype="<i2")
    # (audio, cut 0.35 s into it after 0.7 s of it was sent)
    parts = [(de, False), (silence(1.2), True), (en, False), (silence(35), True), (de, False), (silence(1.0), False)]
    expect = [(0, len(de) / SR), (len(de) / SR + 1.2, len(de) / SR + 1.2 + len(en) / SR),
              (len(de) / SR + 1.2 + len(en) / SR + 35, len(de) / SR + 1.2 + len(en) / SR + 35 + len(de) / SR)]

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(args.socket)
    f = s.makefile("r", encoding="utf-8")
    print(json.loads(f.readline()))
    finals, partial_segments, done = {}, set(), threading.Event()
    t_end = [0.0]

    def reader():
        for line in f:
            msg = json.loads(line)
            if msg["type"] == "partial":
                partial_segments.add(msg["segment"])
            elif msg["type"] == "final":
                finals[msg["segment"]] = msg
                after = f" ({(time.perf_counter() - t_end[0]) * 1000:.0f} ms after the end)" if t_end[0] else ""
                print(f"  final {msg['segment']}{after}: {msg['start']}–{msg['end']} s  {msg['lang']}  {msg['text']}")
                if len(finals) == len(expect):
                    done.set()
                    return

    threading.Thread(target=reader, daemon=True).start()
    s.sendall(frame(b"S"))
    sent = 0
    step = 1600
    for audio, cut in parts:
        for i in range(0, len(audio), step):
            chunk = audio[i : i + step]
            s.sendall(frame(b"A", chunk.tobytes()))
            sent += len(chunk)
            if cut and i <= int(0.7 * SR) < i + step:
                s.sendall(frame(b"K", str(sent - int(0.35 * SR)).encode()))
            time.sleep(len(chunk) / SR / args.speed)
    t_end[0] = time.perf_counter()
    s.sendall(frame(b"E"))
    done.wait(30)
    s.close()

    ok = len(finals) == len(expect)
    for seg, (lo, hi) in enumerate(expect):
        m = finals.get(seg)
        good = bool(m and m["text"] and m["start"] is not None and lo - 0.5 <= m["start"] and m["end"] <= hi + 0.5)
        print(("PASS" if good else "FAIL"), f"segment {seg}: expected speech {lo:.1f}–{hi:.1f} s")
        ok = ok and good
    print("PASS" if partial_segments >= {0, 1, 2} else "FAIL", f"partials for segments {sorted(partial_segments)}")
    print("all good" if ok else "FAILED")


if __name__ == "__main__":
    main()

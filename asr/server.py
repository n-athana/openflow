"""OpenFlow ASR sidecar: streaming Nemotron 3.5 over a Unix socket.

Client -> server frames: 1 byte type + 4 byte big-endian length + payload
    b"C"  choose the decoder set for this connection (payload: b"0", b"1", ...; default 0). A second
          concurrent audio stream (transcription mode's system audio) needs its own models.
    b"S"  start session (payload: optional language, e.g. b"de-DE"; empty = server default; a suffix
          b";live" runs only the fast decoder, for a client that makes its own finals)
    b"A"  audio: 16 kHz mono int16 little-endian PCM
    b"K"  cut: start a new segment at this sample of the session (payload: ASCII sample index). The
          session, its encoder state and its detected language carry on; only the text is split.
    b"E"  end session: flush and emit the last final
    b"X"  cancel session: flush silently
    b"P"  polish a transcript segment with the local LLM (payload: JSON {"id": 7, "text": "...",
          "before": "previous segment, optional"}; empty text only loads the model)
    b"H"  health check: answered with a pong from the connection's thread
The vocabulary file (--vocabulary, see vocab.py) is re-read at the start of a session when it changed.
Server -> client: newline-delimited JSON. "session" counts the S frames on this connection from 1,
"segment" the K frames in the session from 0. "start"/"end": seconds of session audio from the
segment's first to last token (null when it's empty).
    {"type": "ready", "pid": 4711}   (the server process, so a hung one can be killed)
    {"type": "partial", "session": 3, "segment": 0, "text": "...", "lang": "de-DE"}
    {"type": "final", "session": 3, "segment": 0, "text": "...", "lang": "de-DE", "start": 0.4, "end": 2.1}
    {"type": "polished", "id": 7, "text": "..."}
    {"type": "pong"}
    {"type": "error", "session": 3, "message": "..."}
"""

import argparse
import json
import logging
import os
import queue
import re
import socket
import struct
import threading
import time
from collections import deque
from threading import Thread

import numpy as np
import torch
from transformers import AutoModelForRNNT, AutoProcessor
from transformers.generation.streamers import BaseStreamer

import vocab
from boost import Booster, attach
from polish import MODEL_ID as POLISH_MODEL, Polisher

MODEL_ID = "nvidia/nemotron-3.5-asr-streaming-0.6b"
DEFAULT_SOCKET = os.path.expanduser("~/Library/Application Support/OpenFlow/asr.sock")
LANG_TAG = re.compile(r"\s*<([a-z]{2,3}-[A-Z]{2})>")
# A letter outside Basic Latin, Latin-1, Latin Extended-A/B and Latin Extended Additional.
NON_LATIN = re.compile(r"[^\W\d_\u0000-\u024F\u1E00-\u1EFF]")

log = logging.getLogger("openflow-asr")


FRAME_SAMPLES = 1280  # one encoder frame: 80 ms at 16 kHz (10 ms mel hop x 8 subsampling)
# The recognizer writes a sentence's full stop (and in auto mode the language tag) a few frames after
# the last word, which can be past the cut: punctuation this soon after a cut, before any word, still
# ends the previous segment.
PUNCT_HOLD = 8  # frames (0.64 s)


class LiveStreamer(BaseStreamer):
    """Yields ("text", segment, raw) after every token, and ("cut", segment, raw, first, last) once the
    decoder is past a cut, then for the last segment at the end. first/last: encoder frames of the
    segment's first and last token.

    generate() hands over every decoder step, blanks included, and a blank moves on to the next 80 ms
    encoder frame: counting them times each token in session audio, which splits the text at cuts
    exactly. transformers' TextIteratorStreamer would also hold text back until the next space, so
    the word being spoken stayed invisible until the following word started.
    """

    def __init__(self, tokenizer, blank: int, cuts: list[int], boost=None):
        self.tokenizer = tokenizer
        self.blank = blank
        self.cuts = cuts  # cut frames, appended by the session as K frames arrive
        self.pending: list[tuple[int, int]] = []  # (frame, token) of the current segment
        self.frame = 0
        self.segment = 0
        self.prompt = True
        self.punct: dict[int, bool] = {}
        self.queue: queue.Queue = queue.Queue()
        self.boost = boost  # vocabulary match state, advanced before the next decoder step

    def put(self, value):
        if self.prompt:  # generate() first passes the decoder's start token
            self.prompt = False
            return
        changed = False
        for t in value.reshape(-1).tolist():
            if self.boost:
                self.boost.step(t)
            if t == self.blank:
                self.frame += 1
            else:
                self.pending.append((self.frame, t))
                changed = True
        if self._settle() or changed:
            self.queue.put(("text", self.segment, self._decode(self._visible())))

    def _is_punct(self, token: int) -> bool:
        if token not in self.punct:
            piece = LANG_TAG.sub("", self.tokenizer.decode([token], skip_special_tokens=False))
            self.punct[token] = not any(c.isalnum() for c in piece)
        return self.punct[token]

    def _split(self, at: int) -> int | None:
        """Index of the first word token at or after frame `at`, i.e. where the next segment starts."""
        return next((i for i, (f, t) in enumerate(self.pending) if f >= at and not self._is_punct(t)), None)

    def _visible(self):
        """The current segment's tokens: not the next segment's words while a cut waits for punctuation."""
        if self.segment < len(self.cuts) and (i := self._split(self.cuts[self.segment])) is not None:
            return self.pending[:i]
        return self.pending

    def _settle(self, force: bool = False) -> bool:
        """Ends segments whose cut the decoder is past: at the next word after the cut, or once
        PUNCT_HOLD frames passed without one. A cut can also arrive after the decoder passed it (the
        live decoder runs ~0.4 s behind the audio, the app cuts 0.35 s into a pause): tokens behind it
        still move on to the next segment."""
        moved = False
        while self.segment < len(self.cuts):
            at = self.cuts[self.segment]
            i = self._split(at)
            if i is None:
                if self.frame < at + PUNCT_HOLD and not force:
                    break
                i = len(self.pending)
            done, self.pending = self.pending[:i], self.pending[i:]
            self._emit_cut(done)
            self.segment += 1
            moved = True
        return moved

    def _emit_cut(self, done):
        words = [f for f, t in done if not self._is_punct(t)]  # a trailing "?" comes ~1 s late
        first, last = (words[0], words[-1]) if words else (None, None)
        self.queue.put(("cut", self.segment, self._decode(done), first, last))

    def _decode(self, pairs) -> str:
        return self.tokenizer.decode([t for _, t in pairs], skip_special_tokens=False)

    def end(self):
        self._settle(force=True)
        self._emit_cut(self.pending)
        self.pending = []
        self.queue.put(None)

    def __iter__(self):
        # No timeout: nothing is queued while nobody speaks (minutes, when nothing plays on the "Them"
        # side), and generate() always ends the stream, also when it fails.
        while (item := self.queue.get()) is not None:
            yield item


class AudioBuffer:
    """A session's audio as the list of pushed chunks: appending stays cheap for hours (one
    np.concatenate per push made long sessions quadratic), and audio every decoder is past goes."""

    def __init__(self):
        self.chunks: deque[np.ndarray] = deque()
        self.base = 0  # session sample index of chunks[0][0]
        self.size = 0  # samples pushed so far

    def append(self, samples: np.ndarray):
        if samples.size:
            self.chunks.append(samples)
            self.size += samples.size

    def read(self, start: int, end: int) -> np.ndarray:
        out, pos = [], self.base
        for c in self.chunks:
            if pos >= end:
                break
            if pos + c.size > start:
                out.append(c[max(0, start - pos) : end - pos])
            pos += c.size
        return np.concatenate(out) if out else np.zeros(0, np.float32)

    def trim(self, upto: int):
        while self.chunks and self.base + self.chunks[0].size <= upto:
            self.base += self.chunks.popleft().size


class Engine:
    """Two streaming decoders: a fast one for live partials and a slower, more accurate one whose
    result gets pasted. Each needs its own model instance: generate() keeps streaming state on the
    model object, so one instance can't serve two concurrent streams."""

    def __init__(
        self, device: str, lookahead: int, final_lookahead: int, language: str, dtype: torch.dtype, latin_only: bool,
        vocabulary: str = "", boost: dict | None = None,
    ):
        self.device = device
        self.language = language
        self.dtype = dtype
        self.latin_only = latin_only
        self.vocab_path, self.boost = vocabulary, boost  # boost: Booster settings, None = off
        self.vocab, self.booster, self.vocab_mtime = vocab.Vocabulary(), None, None
        self.on_vocabulary = []  # called with the new Vocabulary after a reload
        self.lookahead, self.final_lookahead = lookahead, final_lookahead
        # Metal asserts when two threads use the GPU at once (decoders, model loads, the polish LLM):
        # everything takes turns. Decoders hold it per chunk.
        self.gpu = threading.Lock()
        self.live = self._decoder(lookahead)
        self.final = self._decoder(final_lookahead) if final_lookahead != lookahead else None
        self.sets = [[self.live, self.final]]
        self.sets_lock = threading.Lock()
        fe = self.live.feature_extractor
        self.sr, self.hop, self.n_fft = fe.sampling_rate, fe.hop_length, fe.n_fft
        # Trailing silence that pushes the last chunk + right context of the slowest decoder through.
        slowest = self.final or self.live
        self.flush_seconds = slowest.num_samples_per_audio_chunk / self.sr + slowest.streaming_latency_ms / 1000 + 0.1
        log.info(
            "model loaded on %s (%s), live latency %d ms, final latency %s",
            device, dtype, self.live.streaming_latency_ms,
            f"{self.final.streaming_latency_ms} ms" if self.final else "same as live",
        )

    def _decoder(self, lookahead: int):
        p = AutoProcessor.from_pretrained(MODEL_ID)
        p.set_num_lookahead_tokens(lookahead)
        model = AutoModelForRNNT.from_pretrained(MODEL_ID, dtype=self.dtype)
        with self.gpu:
            p.model = model.to(self.device).eval()
            if self.latin_only:
                log.info("blocked %d non-Latin tokens", block_non_latin(p))
        attach(p)
        # A new session can start while the previous one's decoder is still flushing; a second
        # generate() on the same model would overwrite (and then delete) the first one's state.
        p.in_use = threading.Lock()
        return p

    def decoders(self, index: int, final: bool = True):
        """(live, final) decoders for decoder set `index`, each loaded on first use (~2 s, ~1.2 GB fp16).
        final=False: only the live one (final is None), e.g. when the app makes its own finals."""
        two = self.final_lookahead != self.lookahead
        if index < len(self.sets) and (self.sets[index][1] or not (final and two)):  # don't wait on a load
            live, fin = self.sets[index]
            return live, fin if final else None
        with self.sets_lock:
            while len(self.sets) <= index:
                self.sets.append([self._decoder(self.lookahead), None])
                log.info("loaded decoder set %d", len(self.sets) - 1)
            if final and two and not self.sets[index][1]:
                self.sets[index][1] = self._decoder(self.final_lookahead)
                log.info("loaded the final decoder of set %d", index)
            live, fin = self.sets[index]
            return live, fin if final else None

    def refresh_vocabulary(self):
        """Re-reads the vocabulary file if it changed since the last session (one stat)."""
        if not self.vocab_path:
            return
        try:
            mtime = os.stat(self.vocab_path).st_mtime
        except OSError:
            mtime = None
        if mtime == self.vocab_mtime:
            return
        self.vocab_mtime = mtime
        self.vocab = vocab.load(self.vocab_path)
        if self.boost is not None:
            t = time.perf_counter()
            cfg = self.live.model.config
            self.booster = Booster(
                self.live.tokenizer, [term.text for term in self.vocab.terms], cfg.vocab_size, cfg.blank_token_id,
                self.device, self.dtype, **self.boost,
            ) if self.vocab.terms else None
            log.info("vocabulary: %d terms, %d boosted (%.0f ms)", len(self.vocab.terms),
                     len(self.booster.terms) if self.booster else 0, (time.perf_counter() - t) * 1000)
        for listener in self.on_vocabulary:
            listener(self.vocab)

    def warm_up(self):
        s = Session(self, self.language, lambda *_, **__: None)
        s.push(np.zeros(self.sr, dtype=np.int16).tobytes())
        s.end()
        s.join()


class Session:
    """One push-to-talk utterance, or one stream of transcription mode cut into segments (K frames).
    Audio is pushed from the socket thread; each decoder pulls it."""

    def __init__(self, engine: Engine, language: str, emit, decoder_set: int = 0, live_only: bool = False):
        self.e = engine
        self.live, self.final = engine.decoders(decoder_set, final=not live_only)
        engine.refresh_vocabulary()
        self.vocab, self.booster = engine.vocab, engine.booster
        self.language = language
        self.emit = emit
        self.audio = AudioBuffer()
        self.cuts: list[int] = []  # encoder frames where segments end; both decoders' streamers read it
        self.read_from: dict[str, int] = {}  # per decoder: first sample it still needs
        self.cond = threading.Condition()
        self.done = False
        self.cancelled = False
        self.lang: str | None = None
        self.live_texts: dict[int, str] = {}  # segment -> live decoder's text, the final's fallback
        self.live_done = threading.Event()
        self.threads = [Thread(target=self._run_live, daemon=True)]
        if self.final:
            self.threads.append(Thread(target=self._run_final, daemon=True))
        for t in self.threads:
            t.start()

    def push(self, pcm: bytes):
        samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        with self.cond:
            self.audio.append(samples)
            self.cond.notify_all()

    def cut(self, sample: int):
        """Ends the current segment at `sample` (session audio)."""
        with self.cond:
            frame = max(sample // FRAME_SAMPLES, self.cuts[-1] + 1 if self.cuts else 1)
            self.cuts.append(frame)

    def end(self, cancel: bool = False):
        with self.cond:
            self.cancelled = cancel
            self.audio.append(np.zeros(int(self.e.flush_seconds * self.e.sr), np.float32))
            self.done = True
            self.cond.notify_all()

    def join(self):
        for t in self.threads:
            t.join()

    def _read(self, who: str, start: int, end: int) -> np.ndarray | None:
        """Blocks until audio[start:end] exists. None once the session ended without enough audio."""
        with self.cond:
            self.cond.wait_for(lambda: self.audio.size >= end or self.done)
            if self.audio.size < end:
                return None
            self.read_from[who] = start
            if len(self.read_from) == len(self.threads):
                self.audio.trim(min(self.read_from.values()))
            return self.audio.read(start, end)

    def _features(self, p, audio: np.ndarray, first: bool):
        return p(
            audio,
            sampling_rate=self.e.sr,
            is_streaming=True,
            is_first_audio_chunk=first,
            language=self.language,
            return_tensors="pt",
        ).to(self.e.device, dtype=self.e.dtype)

    def _feature_stream(self, who: str, p, first_features):
        """Runs inside generate(), which holds the GPU lock; it is released only while waiting for audio."""
        yield first_features
        mel_idx = p.num_mel_frames_first_audio_chunk
        while True:
            start = mel_idx * self.e.hop - self.e.n_fft // 2
            self.e.gpu.release()
            try:
                audio = self._read(who, start, start + p.num_samples_per_audio_chunk)
            finally:
                self.e.gpu.acquire()
            if audio is None or self.cancelled:  # free the decoder for the next session right away
                return
            yield self._features(p, audio, False).input_features
            mel_idx += p.num_mel_frames_per_audio_chunk

    def _decode(self, who: str, p, on_text, on_segment):
        """Runs one streaming decoder over the session audio: on_text(segment, text) after every
        token, on_segment(segment, text, start, end) once a segment is complete."""
        audio = self._read(who, 0, p.num_samples_first_audio_chunk)
        if audio is None or self.cancelled:
            on_segment(0, "", None, None)
            return
        with self.e.gpu:
            first = self._features(p, audio, True)
        first_features = first.input_features[:, : p.num_mel_frames_first_audio_chunk, :]
        boost = self.booster.state() if self.booster else None
        streamer = LiveStreamer(p.tokenizer, p.model.config.blank_token_id, self.cuts, boost=boost)
        errors = []

        def generate():
            try:
                with p.in_use, self.e.gpu, torch.inference_mode():  # in_use first: never wait on it holding the GPU
                    p.boost = boost  # only once in_use is ours: the previous session may still be flushing
                    try:
                        p.model.generate(
                            **{**first, "input_features": self._feature_stream(who, p, first_features),
                               "streamer": streamer}
                        )
                    finally:
                        p.boost = None
            except Exception as exc:  # surface to the client instead of hanging the streamer
                errors.append(exc)
                streamer.end()

        gen = Thread(target=generate, daemon=True)
        gen.start()
        for kind, segment, raw, *frames in streamer:
            tags = LANG_TAG.findall(raw)
            self.lang = tags[-1] if tags else self.lang
            text = self.vocab.normalize(clean(raw))
            if segment:  # whatever punctuation still slipped past the cut ended the previous one
                text = text.lstrip(".,;:!?… ")
            if kind == "text":
                on_text(segment, text)
            else:
                first_f, last_f = frames
                to_s = lambda f: None if f is None else round(f * FRAME_SAMPLES / self.e.sr, 2)
                on_segment(segment, text, to_s(first_f), to_s(last_f + 1 if last_f is not None else None))
        gen.join()
        if errors:
            raise errors[0]

    def _run_live(self):
        last = None

        def on_text(segment, text):
            nonlocal last
            if text and not self.cancelled and (segment, text, self.lang) != last:
                self.emit("partial", text, self.lang, segment=segment)
                last = (segment, text, self.lang)

        def on_segment(segment, text, start, end):
            self.live_texts[segment] = text
            if not self.final and not self.cancelled:
                self.emit("final", text, self.lang, segment=segment, start=start, end=end)

        try:
            self._decode("live", self.live, on_text, on_segment)
        except Exception as exc:
            log.exception("live decoder failed")
            self.emit("error", str(exc), None)
        finally:
            self.live_done.set()

    def _run_final(self):
        emitted = set()

        def on_segment(segment, text, start, end):
            if not text:  # nothing better than the live pass (wait for it only at the very end)
                if segment >= len(self.cuts):
                    self.live_done.wait()
                text = self.live_texts.get(segment, "")
            emitted.add(segment)
            if not self.cancelled:
                self.emit("final", text, self.lang, segment=segment, start=start, end=end)

        try:
            self._decode("final", self.final, lambda *_: None, on_segment)
        except Exception:
            log.exception("final decoder failed, falling back to live transcript")
            self.live_done.wait()
            for segment in range(len(self.cuts) + 1):
                if segment not in emitted and not self.cancelled:
                    self.emit("final", self.live_texts.get(segment, ""), self.lang, segment=segment,
                              start=None, end=None)


def block_non_latin(p) -> int:
    """With auto-detect the language tag only arrives at the end of the first sentence; before that,
    the first words can come out in another script ("हेलो टीम! Ich schicke…"). 80 % of the vocabulary
    is non-Latin, so it happens often enough to notice. A large negative output bias rules those
    tokens out for both the emitted token and the blank decision."""
    tok = p.tokenizer
    ids = [i for i in range(len(tok)) if NON_LATIN.search(tok.convert_ids_to_tokens(i))]
    with torch.no_grad():
        p.model.joint.head.bias[ids] -= 1e4
    return len(ids)


def clean(raw: str) -> str:
    return re.sub(r"\s+", " ", LANG_TAG.sub("", raw)).strip()


def recv_exact(conn: socket.socket, n: int) -> bytes | None:
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


def serve_client(engine: Engine, polisher: Polisher, conn: socket.socket):
    wlock = threading.Lock()

    def send(msg: dict):
        with wlock:
            try:
                conn.sendall((json.dumps(msg, ensure_ascii=False) + "\n").encode())
            except OSError:
                pass

    def emitter(sid: int):
        def emit(kind, text, lang, **extra):
            if kind == "error":
                send({"type": "error", "session": sid, "message": text})
            else:
                send({"type": kind, "session": sid, "text": text, "lang": lang, **extra})
        return emit

    send({"type": "ready", "pid": os.getpid()})
    session = None
    sessions = 0
    decoder_set = 0
    try:
        while (header := recv_exact(conn, 5)) is not None:
            kind, length = header[:1], struct.unpack(">I", header[1:])[0]
            payload = recv_exact(conn, length) if length else b""
            if payload is None:
                break
            if kind == b"C":
                decoder_set = int(payload or b"0")
                engine.decoders(decoder_set, final=False)  # load now, not when the first audio arrives
            elif kind == b"S":
                if session:
                    session.end(cancel=True)
                sessions += 1
                t = time.perf_counter()
                language, _, options = payload.decode().partition(";")
                session = Session(engine, language or engine.language, emitter(sessions), decoder_set,
                                  live_only=options == "live")
                log.info("session %d start on set %d%s (%.0f ms)", sessions, decoder_set,
                         ", live only" if options == "live" else "", (time.perf_counter() - t) * 1000)
            elif kind == b"P":
                job = json.loads(payload)
                # Also for finals the app made itself (Parakeet): they haven't seen the vocabulary yet.
                polisher.submit(engine.vocab.normalize(job["text"]), lambda out, i=job["id"]: send({"type": "polished", "id": i, "text": out}),
                                before=job.get("before", ""))
            elif kind == b"H":
                send({"type": "pong"})
            elif kind == b"A" and session:
                session.push(payload)
            elif kind == b"K" and session:
                session.cut(int(payload))
            elif kind in (b"E", b"X") and session:
                session.end(cancel=kind == b"X")
                session = None
    except Exception:
        log.exception("client connection failed")
    finally:  # an open session would hold its decoders forever
        if session:
            session.end(cancel=True)
        conn.close()
    log.info("client disconnected")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default=DEFAULT_SOCKET)
    ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
    ap.add_argument("--lookahead", type=int, default=3, help="live partials: 3 (320 ms), 6 (560 ms), 13 (1.12 s)")
    ap.add_argument("--final-lookahead", type=int, default=13,
                    help="pasted text: a second, more accurate decoder; same as --lookahead = single pass")
    ap.add_argument("--fp32", action="store_true", help="full precision (default fp16: same output, half memory)")
    ap.add_argument("--language", default="auto", help='"auto" or a locale like de-DE')
    ap.add_argument("--polish-model", default=POLISH_MODEL, help="MLX model that polishes transcription segments")
    ap.add_argument("--latin-only", action=argparse.BooleanOptionalAction, default=True,
                    help="only emit Latin-script text (default); --no-latin-only for Greek, Cyrillic, ...")
    ap.add_argument("--vocabulary", default=vocab.DEFAULT_PATH, help='vocabulary Markdown file; "" = none')
    ap.add_argument("--boost", action=argparse.BooleanOptionalAction, default=True,
                    help="bias the decoder toward vocabulary terms (default); --no-boost keeps aliases and glossary")
    ap.add_argument("--boost-start", type=float, default=1.0, help="logit bonus for a term's first characters")
    ap.add_argument("--boost-strength", type=float, default=3.0, help="logit bonus once a term is under way")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

    dtype = torch.float32 if args.fp32 or args.device == "cpu" else torch.float16
    boost = {"start": args.boost_start, "boost": args.boost_strength} if args.boost else None
    engine = Engine(args.device, args.lookahead, args.final_lookahead, args.language, dtype, args.latin_only,
                    args.vocabulary, boost)
    engine.warm_up()
    polisher = Polisher(engine.gpu, args.polish_model)
    polisher.set_vocabulary(engine.vocab)  # warm-up already loaded it
    engine.on_vocabulary.append(polisher.set_vocabulary)

    os.makedirs(os.path.dirname(args.socket), exist_ok=True)
    if os.path.exists(args.socket):
        os.unlink(args.socket)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(args.socket)
    srv.listen(4)
    log.info("listening on %s", args.socket)
    while True:
        conn, _ = srv.accept()
        log.info("client connected")
        Thread(target=serve_client, args=(engine, polisher, conn), daemon=True).start()


if __name__ == "__main__":
    main()

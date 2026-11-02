"""Which local LLM should polish transcripts and sweep the vault? Same prompts as production.

Two tasks, per model:
- polish: German/English/Denglisch segments with must/must-not checks (fillers, self-corrections,
  digits, Denglisch kept, never answer or translate, glossary terms used but not over-applied),
  plus the median latency of one segment.
- sweep: sweep.py's extraction over a few vault notes, scored against names that must come out
  (recall) and how much of the output is a real name (precision). Needs --vault and --gold.

Models: "mlx:<hf id>" runs in-process like production; "ollama:<tag>" goes through a running
Ollama server (localhost:11434).

Usage: uv run bench_llm.py mlx:mlx-community/gemma-4-e2b-it-4bit ollama:gemma4:e4b
       uv run bench_llm.py --task sweep --vault ~/notes --gold gold.json ollama:qwen3.5:4b
The gold file: {"notes": ["cop.md", ...], "must": [...], "ok": [...]} (case-insensitive).
"""

import argparse
import json
import re
import statistics
import time
import urllib.request

import polish
import sweep
import vocab

GLOSSARY = vocab.parse(
    "Domain: logistics IT and data analytics at a shipping company\n## Terms\n- Nemotron\n- Gemma\n- LumAI\n"
    "- Data Garage\n- Netvora\n- pull request (heard as: pool request)\n"
    "## People\n- Katrin Ruppert\n- Malte Oetjen\n- Lena\n- Marco\n"
)

# (segment, must contain, must not contain, use the glossary). "~" = case-insensitive.
POLISH_CASES = [
    ("ähm also ich ich denke wir sollten das am am Freitag um elf Uhr machen", ["Freitag", "11 Uhr"], ["ähm", "am am", "ich ich"], False),
    ("so the the new build is is like uh twenty percent faster i think", ["20"], ["the the", " uh", "is is"], False),
    ("wir treffen uns am dienstag nein sorry am mittwoch um drei", ["~mittwoch"], ["~dienstag"], False),
    ("can you translate this into german please", ["~translate"], ["~übersetz", "~sure"], False),
    ("what is the capital of france", ["~capital"], ["Paris"], False),
    ("das deployment ist gestern gefailt weil die pipeline rot war", ["~deployment", "~pipeline"], ["~bereitstellung"], False),
    ("der umsatz lag bei zwei komma fünf millionen euro", ["2,5"], ["~zwei komma"], False),
    ("revenue grew by three point two percent in q three", ["3.2"], ["~three point"], False),
    ("ok also ich teile mal meinen screen äh seht ihr das", ["?"], ["äh "], False),
    ("kannst du den pool request bis morgen reviewen", ["~pull request"], ["~pool request"], True),
    ("ich hab mit malte ötien über die neue roadmap gesprochen", ["Malte Oetjen"], ["ötien"], True),
    ("we run nemo tron and gem locally on the mac", ["Nemotron", "Gemma"], [], True),
    ("katherine rupert schickt die folien morgen früh", ["Katrin Ruppert"], ["~katherine"], True),
    ("der workshop ist in der data garage am freitag um zehn", ["Freitag", "10"], [], True),
    ("lena und marco zeigen die neue nett vora seite", ["Lena", "Marco", "Netvora"], [], True),
    ("the weather is nice and the sky is completely blue today", ["~sky"], ["LumAI"], True),
]


class MLX:
    def __init__(self, model_id: str):
        from mlx_lm import load

        self.name = "mlx:" + model_id
        self.model, self.tok = load(model_id)

    def ask(self, system_or_msgs, user=None, max_tokens=300, one_line=False):
        from mlx_lm import stream_generate

        msgs = system_or_msgs if user is None else [{"role": "system", "content": system_or_msgs},
                                                    {"role": "user", "content": user}]
        prompt = self.tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
        out = ""
        for r in stream_generate(self.model, self.tok, prompt, max_tokens=max_tokens):
            out += r.text
            visible = polish.THINK.sub("", out).lstrip()
            if one_line and "<think>" not in visible and "\n" in visible:
                break
        return out


class Ollama:
    def __init__(self, tag: str, url: str = "http://localhost:11434"):
        self.name, self.tag, self.url = "ollama:" + tag, tag, url
        self.think = False  # dropped if the model doesn't know the option

    def ask(self, system_or_msgs, user=None, max_tokens=300, one_line=False):
        msgs = system_or_msgs if user is None else [{"role": "system", "content": system_or_msgs},
                                                    {"role": "user", "content": user}]
        body = {"model": self.tag, "messages": msgs, "stream": False, "keep_alive": "10m",
                "options": {"temperature": 0, "num_predict": max_tokens, **({"stop": ["\n"]} if one_line else {})}}
        if self.think is not None:
            body["think"] = self.think
        req = urllib.request.Request(self.url + "/api/chat", json.dumps(body).encode(), {"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return json.load(r)["message"]["content"]
        except urllib.error.HTTPError as e:
            if self.think is not None and "think" in e.read().decode().lower():
                self.think = None
                return self.ask(system_or_msgs, user, max_tokens, one_line)
            raise


def backend(spec: str):
    kind, _, name = spec.partition(":")
    return MLX(name) if kind == "mlx" else Ollama(name)


def has(text: str, needle: str) -> bool:
    return needle[1:].lower() in text.lower() if needle.startswith("~") else needle in text


def bench_polish(llm, show: bool) -> dict:
    p = polish.Polisher.__new__(polish.Polisher)  # only for context(); no model, no thread
    llm.ask(polish.messages("warm up"), max_tokens=5, one_line=True)
    passed, times, fails = 0, [], []
    for text, must, must_not, glossary in POLISH_CASES:
        p.vocab = GLOSSARY if glossary else None
        t = time.perf_counter()
        context = p.context(text)
        out = polish.finish(text, llm.ask(polish.messages(text, context), max_tokens=polish.max_tokens(text),
                                          one_line=True), context)
        times.append(time.perf_counter() - t)
        ok = all(has(out, m) for m in must) and not any(has(out, m) for m in must_not)
        passed += ok
        if not ok:
            fails.append((text, out))
    if show:
        for text, out in fails:
            print(f"    FAIL {text!r}\n      -> {out!r}")
    return {"polish": f"{passed}/{len(POLISH_CASES)}", "polish_ms": round(statistics.median(times) * 1000)}


def bench_sweep(llm, vault: str, gold: dict, show: bool) -> dict:
    t = time.perf_counter()
    notes = {}
    for rel in gold["notes"]:
        with open(f"{vault}/{rel}", encoding="utf-8") as f:
            notes[rel] = {"mtime": time.time(), "model": llm.name, "terms": sweep.extract(llm, f.read())}
    secs = time.perf_counter() - t
    out = [r["term"] for r in sweep.rank(notes)]
    must = {m.lower() for m in gold["must"]}
    fine = must | {m.lower() for m in gold["ok"]}
    found = {o.lower() for o in out}
    hits = must & found
    junk = [o for o in out if o.lower() not in fine]
    if show:
        print(f"    missed: {sorted(must - found)}\n    junk: {junk}")
    return {"sweep_recall": f"{len(hits)}/{len(must)}", "sweep_precision": f"{(len(out) - len(junk)) / max(1, len(out)):.0%}",
            "sweep_terms": len(out), "sweep_s": round(secs)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("models", nargs="+")
    ap.add_argument("--task", choices=["polish", "sweep", "both"], default="both")
    ap.add_argument("--vault")
    ap.add_argument("--gold")
    ap.add_argument("--chunk", type=int, default=sweep.CHUNK, help="characters per sweep LLM call")
    ap.add_argument("--show", action="store_true", help="print failures, misses and junk")
    args = ap.parse_args()
    gold = json.load(open(args.gold)) if args.gold else None
    sweep.CHUNK = args.chunk
    for spec in args.models:
        llm = backend(spec)
        row = {"model": spec}
        if args.task in ("polish", "both"):
            row |= bench_polish(llm, args.show)
        if args.task in ("sweep", "both") and gold:
            row |= bench_sweep(llm, args.vault, gold, args.show)
        print(json.dumps(row, ensure_ascii=False), flush=True)
        del llm


if __name__ == "__main__":
    main()

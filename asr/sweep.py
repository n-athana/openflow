"""Learns the user's vocabulary from an Obsidian vault (or any folder of Markdown notes).

1. A local LLM (the polish model) reads every note, in chunks, and lists the names in it:
   people, organizations, projects, products, acronyms, jargon. It sees the whole context, so it
   knows "Lena" in "ToP lead: Lena" is a person.
2. Rules keep it honest: a name must appear in the note word for word, takes the note's spelling
   ("lumai" from a frontmatter slug becomes "LumAI"), and ticket keys, file names and ordinary
   phrases are dropped. A name from a single note must look like one (capitalized, or shaped like
   an acronym). Note aliases and [[link|alias]] texts always count.
3. Terms are ranked by how many notes mention them; the result replaces the vault block of the
   vocabulary file (see vocab.py). Your own sections and the Ignore list are never touched.

The vault is only read. Re-runs are incremental: only new or changed notes are read again
(cache in ~/Library/Application Support/OpenFlow). Without the LLM (--no-llm, or no model
downloaded) rules pick the candidates instead.

Usage: uv run sweep.py --vault ~/notes [--out ~/Documents/OpenFlow/Vocabulary.md] [--no-llm]
Prints "progress <done> <total>" per note, then "done added=<n> removed=<n> total=<n>" (the app
reads these lines).
"""

import argparse
import json
import math
import os
import re
import sys
import time
from collections import Counter
from datetime import date

import vocab

CACHE = os.path.expanduser("~/Library/Application Support/OpenFlow/sweep-cache.json")
CATEGORIES = ["People", "Organizations", "Projects", "Products", "Acronyms", "Terms"]
SKIP_DIRS = {"_templates", "templates", "_archive", "attachments", "node_modules"}
CACHE_VERSION = 5

FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
FENCE = re.compile(r"```.*?```|~~~.*?~~~", re.S)
INLINE_CODE = re.compile(r"`[^`\n]*`")
URL = re.compile(r"https?://\S+|www\.\S+")
MD_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
WIKILINK = re.compile(r"!?\[\[([^\]|#]*)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]")
HTML = re.compile(r"<[^>]+>")
HEADING = re.compile(r"^#{1,6}\s+(.*)$", re.M)
# Two or more capitals (ACME, ToP, OpenFlow, LumAI), or a capital followed by digits (M5, X200).
SHAPED = re.compile(r"(?<![\w/])(?=[\w.+&/-]*[A-ZÄÖÜ][\w.+&/-]*[A-ZÄÖÜ0-9])[A-ZÄÖÜa-z][\w+&/-]*[\w+](?![\w/])")
CAP = r"[A-ZÄÖÜ][a-zäöüß]+(?:-[A-ZÄÖÜ][a-zäöüß]+)?"
CONNECT = r"(?:of|for|the|de|der|die|das|für|von|van|du)"  # not "and": "Lena and Tomas" is two names
# Runs of capitalized words, maybe joined by "of", "für"...: "Data Garage", "Community of Practice".
PHRASE = re.compile(rf"(?<!\w)({CAP}(?:\s+(?:{CONNECT}\s+)?{CAP}){{1,3}})(?!\w)")
WORD = re.compile(rf"(?<![\w.]){CAP}(?!\w)")
SENTENCE_START = re.compile(r"(?:^|[.!?:;]\s+|^\s*[-*>]\s+|\*\*)$")
DATEISH = re.compile(r"^\d|^(?:Q[1-4]|KW|CW)\d", re.I)
TICKET = re.compile(r"^[A-Z]+-\d+$")  # JIRA keys: nobody says "PROJ-30092"
CODE = re.compile(r"^[A-Z]\d{1,2}$")  # labels like P1, B21, S25 (not M365, X200)
HEX = re.compile(r"^[0-9A-F]{6}$")  # colours: FFFFFF, A8B1B6
CALENDAR = {"mon", "tue", "wed", "thu", "fri", "sat", "sun", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
            "sept", "oct", "nov", "dec", "mo", "di", "mi", "do", "fr", "sa", "so", "okt", "dez", "mär"}


def emit(*parts):
    print(*parts, flush=True)


def around(term: str, line: str, width: int = 80) -> str:
    """The stretch of `line` around `term`, for the LLM to judge it by."""
    line = re.sub(r"[*_`|#>]+", " ", re.sub(r"\s+", " ", line)).strip()
    i = max(0, line.find(term) - width // 2)
    return line[i : i + width].strip()


def frontmatter_values(fm: str) -> tuple[list[str], list[str]]:
    """(aliases, other short string values) from simple YAML frontmatter."""
    aliases, values, key = [], [], None
    for line in fm.splitlines():
        if m := re.match(r"^([\w-]+):\s*(.*)$", line):
            key, rest = m.group(1).lower(), m.group(2).strip()
            items = [x.strip(" '\"") for x in rest.strip("[]").split(",")] if rest.startswith("[") else [rest.strip("'\"")]
        elif m := re.match(r"^\s+-\s+(.*)$", line):
            items = [m.group(1).strip(" '\"")]
        else:
            continue
        for item in filter(None, items):
            if "[[" in item:
                continue  # links are read from the body pattern below
            (aliases if key in ("aliases", "alias") else values).append(item)
    return aliases, values


def candidates(text: str, stem: str) -> dict[str, dict]:
    """term -> {"count", "kind", "snippet"} for one note."""
    found: dict[str, dict] = {}

    def add(term, kind, snippet=""):
        term = term.strip(" .,:;!?()[]*_\"'“”„")
        term = re.sub(r"\s+[Ll]og$", "", term)  # "ToP log": the log note of "ToP"
        if "/" in term and not re.fullmatch(r"[A-Z0-9/]+", term):  # "Marco/Lena", not "CI/CD"
            for part in term.split("/"):
                add(part, kind, snippet)
            return
        if len(term) < 2 or len(term) > 40 or DATEISH.match(term) or "_" in term or term.count(" ") > 4:
            return
        c = found.setdefault(term, {"count": 0, "kind": kind, "snippet": ""})
        c["count"] += 1
        if not c["snippet"] and snippet:
            c["snippet"] = around(term, snippet)

    body = text
    if m := FRONTMATTER.match(text):
        aliases, values = frontmatter_values(m.group(1))
        for a in aliases:
            add(a, "alias")
        for v in values:  # "org: acme" is a slug; "Report Wizard" or "ACME" in a value is a term
            for s in SHAPED.findall(v) + PHRASE.findall(v):
                add(s, "shaped")
        body = text[m.end():]
    for target, alias in WIKILINK.findall(body):
        if alias:
            add(alias, "alias")
        elif target and target != target.lower():  # "[[Jana Weber]]"; "[[lumai]]" is a slug
            add(target.split("/")[-1], "link")
    if stem != stem.lower() and not DATEISH.match(stem):
        add(stem, "title")
    body = HTML.sub(" ", URL.sub(" ", INLINE_CODE.sub(" ", FENCE.sub(" ", body))))
    body = MD_LINK.sub(r"\1", WIKILINK.sub(lambda m: m.group(2) or m.group(1), body))
    for line in body.splitlines():
        if not line.strip():
            continue
        heading = HEADING.match(line)
        if heading and line.startswith("# "):  # "# ToP: ACME Team of Practice"
            title = re.split(r"[:(–—|]", heading.group(1))[0]
            if title.strip():
                add(title, "title", line)
        for s in SHAPED.findall(line):
            add(s, "shaped", line)
        for s in PHRASE.findall(line):
            add(s, "phrase", line)
        for m in WORD.finditer(line):
            # A capitalized word mid-sentence, rare in both languages: names, products ("Lena",
            # "Nemotron"). German capitalizes every noun, so common words are dropped later.
            if not SENTENCE_START.search(line[: m.start()]):
                add(m.group(0), "word", line)
    return found


def keep_candidate(term: str, kind: str) -> bool:
    if TICKET.match(term) or HEX.match(term) or term.lower() in CALENDAR:
        return False
    if "-" in term and any(vocab.common(w) and w.islower() for w in term.split("-")):  # "API-based"
        return False
    if kind in ("alias", "title", "link"):  # the user named it
        return True
    words = vocab.SEP.split(term)
    if len(words) == 1:
        # "DONE", "WHY", "PROJECTS" are shouting, not acronyms; "ACME", "LumAI", "X200" are not words.
        return not vocab.common(term) or (not term.isupper() and sum(c.isupper() for c in term) >= 2)
    return not all(vocab.common(w) for w in words)


class LLM:
    def __init__(self, model_id: str):
        from mlx_lm import load

        self.model, self.tok = load(model_id)

    def ask(self, system: str, user: str, max_tokens: int) -> str:
        from mlx_lm import generate

        msgs = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        prompt = self.tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
        return generate(self.model, self.tok, prompt, max_tokens=max_tokens)


def guess_category(term: str) -> str:
    """Without the LLM: shape only."""
    letters = [c for c in term if c.isalpha()]
    if " " not in term and letters and sum(c.isupper() for c in letters) * 2 > len(letters):  # ACME, ToP, LumAI
        return "Acronyms"
    return "Terms"


def describe_domain(llm: "LLM | None", groups: dict[str, list[str]], notes: dict) -> str:
    if llm is None:
        return ""
    titles = [os.path.splitext(os.path.basename(p))[0] for p in list(notes)[:40]]
    user = "\n".join(f"{c}: {', '.join(terms[:15])}" for c, terms in groups.items() if terms)
    user += "\nNote titles: " + ", ".join(titles)
    line = llm.ask(DOMAIN, user, max_tokens=40).strip().splitlines()
    return line[0].strip(" .\"'") if line else ""


EXTRACT = """You read one note and list every name a speech recognizer might not know:
people, organizations, teams, projects, products and tools, acronyms, domain jargon.
Only names that are written in the note; copy them exactly as written. No ordinary words or
phrases, no headings, no dates, no ticket numbers, no file names. A person is a specific
individual's name, never a role or job title (not "Analyst", "Product Owner", "Speaker", "You").

Answer with one line per name: <category>: <name>
Categories: person, organization, project, product, acronym, term

Example note: "Workshop with Lena on the LumAI roadmap. Initech hands over the TaskBoard board."
Answer:
person: Lena
project: LumAI
organization: Initech
product: TaskBoard"""

DOMAIN = """Here are terms and note titles from one person's notes. Describe their professional domain
in at most 12 words, naming the industry and employer if they are obvious, e.g. "IT and data
analytics at a shipping company". Answer with the description only."""

CATEGORY = {"person": "People", "organization": "Organizations", "project": "Projects", "product": "Products",
            "acronym": "Acronyms", "term": "Terms"}
SLOT = re.compile(r"^\s*[-*]?\s*(person|organization|project|product|acronym|term)s?\s*:\s*(.+?)\s*$", re.I | re.M)
FILENAME = re.compile(r"_|\s[-–]\s|[:,;]|\.(md|pdf|pptx?|docx?|xlsx?|png|jpe?g|csv)$|\b[A-Z]+-\d+\b", re.I)
TRANSCRIPT = re.compile(r"\A# Transcript · ")  # TranscriptStore's Markdown
HONORIFIC = re.compile(r"^(?:Frau|Herr|Dr\.?|Prof\.?|Mr\.?|Mrs\.?|Ms\.?)\s+")
PRONOUNS = {"you", "them", "me", "we", "us", "they", "he", "she", "him", "her", "ich", "du", "wir", "ihr", "sie",
            "er", "mich", "dich", "mir", "dir", "uns", "euch", "ihn", "ihm", "ihnen"}
# The last word of a job title: "Product Owner", "Data Analyst", "Teamleiter".
ROLE = re.compile(r"(?:analyst|owner|manager|lead|engineer|developer|architect|designer|scientist|consultant|"
                  r"director|officer|supervisor|speaker|organizer|examiner|coach|admin|user|customer|member|"
                  r"leiter|berater|entwickler|betreuer|prüfer|gutachter|sprecher|kunde|nutzer|kollege|kollegin)s?$", re.I)
NAME_WORD = re.compile(r"^(?:[A-ZÄÖÜÉ][a-zäöüßéèáíóúñçã'’]+(?:-[A-ZÄÖÜ][a-zäöüßéèáíóúñçã'’]+)?|van|von|de|da|del|di|du|der|den)$")


def plain(text: str) -> tuple[str, list[str]]:
    """(note body as prose, the note's own aliases): no frontmatter, code or URLs; links become
    their text."""
    aliases = []
    if m := FRONTMATTER.match(text):
        aliases = frontmatter_values(m.group(1))[0]
        text = text[m.end():]
    aliases += [a for _, a in WIKILINK.findall(text) if a]
    text = HTML.sub(" ", URL.sub(" ", INLINE_CODE.sub(" ", FENCE.sub(" ", text))))
    text = MD_LINK.sub(r"\1", WIKILINK.sub(lambda m: m.group(2) or m.group(1).split("/")[-1], text))
    return text, aliases


CHUNK = 2000  # characters per LLM call


def chunks(text: str, size: int | None = None):
    """Paragraph-aligned pieces small enough for a small model to read closely."""
    size, cur = size or CHUNK, ""
    for para in text.split("\n\n"):
        if cur and len(cur) + len(para) > size:
            yield cur
            cur = ""
        cur += para + "\n\n"
    if cur.strip():
        yield cur


def spelling(term: str, text: str) -> str:
    """The note's most common spelling, preferring one with capitals: "lumai" -> "LumAI"."""
    forms = re.findall(rf"(?<!\w){re.escape(term)}(?!\w)", text, re.I)
    if not forms:
        return term
    cased = [f for f in forms if f != f.lower()] or forms
    return max(set(cased), key=cased.count)


def well_formed(term: str) -> bool:
    """Looks like a name: every word capitalized, or shaped like an acronym (ACME, LumAI, M365)."""
    return all(w[:1].isupper() or w[:1].isdigit() for w in vocab.SEP.split(term))


def known_word(word: str) -> bool:
    """Frequent enough in German or English that the recognizer spells it right on its own."""
    from wordfreq import zipf_frequency

    w = word.lower()
    return max(zipf_frequency(w, "de"), zipf_frequency(w, "en")) >= 3.0


NUMBERED = re.compile(r"^(\S+)\s+(?:\d+(?:\.\d+)*|[IVX]+|v\d+)$")  # "Level 1", "Stage 2", "Sprint II"
MONTH_DAY = re.compile(r"^(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d", re.I)


def zipf(word: str) -> float:
    from wordfreq import zipf_frequency

    w = word.lower()
    return max(zipf_frequency(w, "de"), zipf_frequency(w, "en"))


def plausible(term: str, category: str, lowercase_too: bool) -> bool:
    """A name worth knowing, not a status, a code or a phrase. `lowercase_too`: the note also writes
    it in lowercase (a role: "our product owner"; a name never is)."""
    if not 2 <= len(term) <= 40 or term.count(" ") > 3 or FILENAME.search(term) or DATEISH.match(term):
        return False
    if MONTH_DAY.match(term):  # "Oct 3"
        return False
    if TICKET.match(term) or CODE.match(term) or HEX.match(term) or term.isdigit() or term.lower() in PRONOUNS:
        return False
    if term.lower() in CALENDAR and category != "People":  # "May" is a person, "Thu" isn't
        return False
    if term == term.lower() and " " not in term:  # tags and slugs: "lumai", "top"
        return False
    words = vocab.SEP.split(term)
    if ROLE.search(term) and all(known_word(w) for w in words):  # "Product Owner", "Data Analyst"
        return False
    if category == "People":  # "May" is a name even though it's a word; "lunch break" is neither
        return not lowercase_too
    if term.isupper() and all(len(w) >= 4 and known_word(w) or zipf(w) >= 5 for w in words):
        return False  # shouting, not acronyms: "UNRESOLVED", "PENDING", "TO BE DELETED"
    if (m := NUMBERED.match(term)) and known_word(m.group(1)):
        return False  # "Level 1", "Stage 2", "Session 2"; "Expo 2026" stays
    if len(words) > 1 and all(w == w.lower() for w in words):
        return False  # "release notes", "test plan": names are capitalized
    if " " not in term and term[:1].isupper() and term[1:].islower() and known_word(term):
        return False  # "Python", "Inbox", "Milestone": the recognizer knows these
    if term.isupper() and " " not in term and len(term) <= 5:
        return True  # an acronym, even if it spells a word: "ACT", "PI"
    if len(words) > 1 and well_formed(term):
        # "Night Owl", "Data Garage" are names though every word is common; "In Progress",
        # "To Do", "Use Case" are phrases (a function word in them).
        return not all(vocab.common(w) for w in words) or max(zipf(w) for w in words) < 5.5
    return keep_candidate(term, "llm")  # drops "DONE", "draft notes", "Seniors"


def fix_category(term: str, category: str) -> str:
    letters = [c for c in term if c.isalpha()]
    acronym = " " not in term and letters and sum(c.isupper() for c in letters) * 2 > len(letters)
    if category == "People" and not all(NAME_WORD.match(w) for w in term.split()):
        return "Acronyms" if acronym else "Terms"  # "PowerPoint", "URLs", "UX Guild" aren't people
    if acronym and category != "People":
        return "Acronyms"  # "HR", "ETA"
    if category == "Acronyms":
        return "Terms"  # "Kubernetes", "Dev OS"
    return category


def extract(llm: "LLM", text: str) -> dict[str, dict]:
    """name -> {"category", "count", "alias", "lower"} for one note, as the LLM read it. Only
    checked against the note here; the filters run in rank(), so changing them needs no new LLM
    pass."""
    body, aliases = plain(text)
    found: dict[str, dict] = {}

    def add(raw, category, alias=False):
        for part in raw.split("/") if "/" in raw and not re.fullmatch(r"[A-Z0-9/]+", raw) else [raw]:
            term = part.strip(" .,:;!?()[]*_\"'“”„")
            term = HONORIFIC.sub("", re.sub(r"\s+[Ll]og$|['’]s$", "", term))  # "ToP log", "Marco's"
            if not term or term.lower() not in body.lower() and not alias:
                continue  # not in the note: the model made it up or changed it
            term = spelling(term, body)
            entry = found.setdefault(term, {"category": fix_category(term, category), "count": 0, "alias": alias,
                                            "lower": term != term.lower() and bool(
                                                re.search(rf"(?<!\w){re.escape(term.lower())}(?!\w)", body))})
            entry["count"] = max(1, len(re.findall(rf"(?<!\w){re.escape(term)}(?!\w)", body, re.I)))

    for chunk in chunks(body):
        answer = llm.ask(EXTRACT, "Note:\n" + chunk.strip() + "\nAnswer:", max_tokens=400)
        for cat, value in SLOT.findall(answer):
            if value.strip().lower() in chunk.lower():
                add(value, CATEGORY[cat.lower()])
    for a in aliases:  # the user named it: a person or a project, most likely, but who knows
        if a not in found:
            add(a, guess_category(a), alias=True)
    return found


def extract_rules(text: str, stem: str) -> dict[str, dict]:
    """Without the LLM: candidates by shape, minus common words."""
    found = {}
    for t, c in candidates(text, stem).items():
        alias = c["kind"] in ("alias", "title", "link")
        if keep_candidate(t, c["kind"]):
            found[t] = {"category": guess_category(t), "count": c["count"], "alias": alias, "lower": False}
    return found


def read_vault(vault: str, cache: dict, model: str | None, load_llm) -> dict[str, dict]:
    """rel path -> cached note entry. A note is read again when it changed, or when it was read by
    another model (or by rules only) than `model`. `load_llm()` gives the model (loaded once) or None."""
    paths = []
    for root, dirs, files in os.walk(vault):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d.lower() not in SKIP_DIRS]
        paths += [os.path.join(root, f) for f in files if f.endswith(".md")]
    old, notes = cache.get("notes", {}), {}
    for i, path in enumerate(sorted(paths), 1):
        rel = os.path.relpath(path, vault)
        mtime = os.stat(path).st_mtime
        entry = old.get(rel)
        if entry and entry["mtime"] == mtime and entry.get("model") == model:
            notes[rel] = entry
        else:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            llm = load_llm() if model else None
            if TRANSCRIPT.match(text):  # OpenFlow's own output: learning from it repeats its mistakes
                notes[rel] = {"mtime": mtime, "model": model if llm else None, "terms": {}}
            elif llm:
                notes[rel] = {"mtime": mtime, "model": model, "terms": extract(llm, text)}
            else:
                stem = os.path.splitext(os.path.basename(path))[0]
                notes[rel] = {"mtime": mtime, "model": None, "terms": extract_rules(text, stem)}
        emit("progress", i, len(paths))
    return notes


def rank(notes: dict[str, dict]) -> list[dict]:
    """One entry per term (spellings merged, the most frequent wins; the category by majority),
    best first. A term from a single note has to look like a name."""
    now = time.time()
    terms: dict[str, dict] = {}
    for note in notes.values():
        recency = math.exp(-max(0.0, now - note["mtime"]) / 86400 / 90)
        for term, e in note["terms"].items():
            if not (e["alias"] and well_formed(term) or plausible(term, e["category"], e.get("lower", False))):
                continue
            t = terms.setdefault(term.lower(), {"spellings": Counter(), "categories": Counter(), "notes": 0,
                                                "count": 0, "alias": False, "recency": 0.0})
            t["spellings"][term] += e["count"]
            t["categories"][e["category"]] += 1
            t["notes"] += 1
            t["count"] += e["count"]
            t["alias"] |= e["alias"]
            t["recency"] = max(t["recency"], recency)
    ranked = []
    for t in terms.values():
        t["term"] = t["spellings"].most_common(1)[0][0]
        if t["notes"] < 2 and not t["alias"] and not well_formed(t["term"]):
            continue
        t["category"] = t["categories"].most_common(1)[0][0]
        t["score"] = (1 + math.log(t["notes"])) * (1 + math.log(t["count"])) * (0.5 + t["recency"]) * (1.5 if t["alias"] else 1)
        ranked.append(t)
    ranked.sort(key=lambda t: -t["score"])
    return merge_variants(ranked)


def one_edit(a: str, b: str) -> bool:
    """a and b differ by one substituted, inserted or deleted letter."""
    if abs(len(a) - len(b)) > 1 or a == b:
        return False
    if len(a) > len(b):
        a, b = b, a
    i = next((k for k in range(len(a)) if a[k] != b[k]), len(a))
    return a[i + (len(a) == len(b)):] == b[i + 1:]


def merge_variants(ranked: list[dict]) -> list[dict]:
    """Drops a name one letter away from a much more frequent one of the same kind: "Tomaz" and
    "Tomes" are typos of "Tomas". Two real people ("Jona", "Jonas") both stay frequent."""
    kept: list[dict] = []
    for t in sorted(ranked, key=lambda t: -t["count"]):
        if len(t["term"]) >= 4 and any(
            k["category"] == t["category"] and k["count"] >= 3 * t["count"] and one_edit(k["term"].lower(), t["term"].lower())
            for k in kept
        ):
            continue
        kept.append(t)
    return sorted(kept, key=lambda t: -t["score"])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vault")
    ap.add_argument("--out", default=vocab.DEFAULT_PATH)
    ap.add_argument("--cache", default=CACHE)
    ap.add_argument("--limit", type=int, default=500, help="most terms written to the vocabulary")
    ap.add_argument("--no-llm", action="store_true", help="rules only")
    ap.add_argument("--model", default=None, help="MLX model (default: the polish model)")
    args = ap.parse_args()
    if not args.vault:
        ap.error("--vault is required")
    vault = os.path.abspath(os.path.expanduser(args.vault))
    if not os.path.isdir(vault):
        sys.exit(f"no such folder: {vault}")
    try:
        with open(args.cache, encoding="utf-8") as f:
            cache = json.load(f)
        if cache.get("version") != CACHE_VERSION or cache.get("vault") != vault:
            cache = {}
    except (OSError, ValueError):
        cache = {}

    # The polish model: one LLM download for the whole app. (Qwen 3.5 4B finds more names, 86 % vs.
    # 60 % on hand-labelled notes, asr/bench_llm.py, but would be a second ~3 GB download.) Offline,
    # as the app runs it, a model that isn't downloaded can't load: then rules only. A note is read
    # again when the model changes.
    from huggingface_hub import try_to_load_from_cache
    from polish import MODEL_ID

    model = None if args.no_llm else args.model or (
        MODEL_ID if isinstance(try_to_load_from_cache(MODEL_ID, "config.json"), str) else None)
    llm, tried = None, False

    def load_llm():
        """Loaded on the first note that needs it; None if it can't be (no MLX, broken download)."""
        nonlocal llm, tried
        if not tried:
            tried = True
            try:
                llm = LLM(model)
                print(f"sweep model: {model}", file=sys.stderr)
            except Exception as exc:
                print(f"can't load {model} ({exc}), using rules only", file=sys.stderr)
        return llm

    t0 = time.perf_counter()
    notes = read_vault(vault, cache, model, load_llm)
    current = vocab.load(args.out)
    mine = {t.text.lower() for t in current.terms if t.source == "manual"} | {i.lower() for i in current.ignore}
    kept = [t for t in rank(notes) if t["term"].lower() not in mine][: args.limit]
    groups = {c: [] for c in CATEGORIES}
    for t in kept:
        groups[t["category"]].append(t["term"])
    domain = ""
    if not current.domain and model and load_llm():
        domain = describe_domain(llm, groups, notes)
    before = {t.text.lower() for t in current.terms if t.source == "vault"}
    after = {t["term"].lower() for t in kept}
    name = os.path.basename(vault.rstrip("/")) or vault
    vocab.write_vault_block(args.out, groups, f"From vault: {name} ({date.today().isoformat()})", domain)

    os.makedirs(os.path.dirname(args.cache), exist_ok=True)
    vocab.write_atomic(args.cache, json.dumps({"version": CACHE_VERSION, "vault": vault, "notes": notes},
                                              ensure_ascii=False))
    emit(f"done added={len(after - before)} removed={len(before - after)} total={len(kept)} "
         f"seconds={time.perf_counter() - t0:.1f}")


if __name__ == "__main__":
    main()

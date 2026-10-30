"""The user's vocabulary: names, acronyms and jargon the recognizer should get right.

One Markdown file, edited by hand, by the app's Vocabulary window, and by sweep.py (which only
rewrites the block between the vault markers):

    Domain: logistics IT, AI tooling

    ## Terms
    - ACME
    - pull request (heard as: pool request)

    ## Ignore
    - Helper

    <!-- openflow:vault:start -->
    ## From vault: Notes (2026-10-30)
    ### People
    - Jana Weber
    <!-- openflow:vault:end -->

`## <Category>` sections hold your own terms, `### <Category>` inside the block the vault's.
Terms under Ignore are never added by the sweep. Lines that match none of this are kept as they are.
The app's VocabularyStore.swift parses the same format; keep the two in step.
"""

import os
import re
import tempfile
from dataclasses import dataclass, field

DEFAULT_PATH = os.path.expanduser("~/Documents/OpenFlow/Vocabulary.md")
START, END = "<!-- openflow:vault:start", "<!-- openflow:vault:end -->"
BULLET = re.compile(r"^\s*[-*]\s+(.+?)\s*$")
HEARD_AS = re.compile(r"\s*\(heard as:\s*(.*?)\)\s*$", re.I)
DOMAIN = re.compile(r"^Domain:\s*(.*?)\s*$", re.I)

TEMPLATE = """# OpenFlow Vocabulary

Domain:

Words OpenFlow should recognize: names, acronyms, product and project words, one per line.
Add what the recognizer writes instead as "(heard as: …)". Changes apply to the next dictation.

## Terms

## People

## Ignore
"""


@dataclass
class Term:
    text: str
    category: str
    source: str  # "manual" or "vault"
    aliases: list[str] = field(default_factory=list)


@dataclass
class Vocabulary:
    domain: str = ""
    terms: list[Term] = field(default_factory=list)  # manual first, then the vault's ranking
    ignore: list[str] = field(default_factory=list)

    def __post_init__(self):
        self._rules = None

    def normalize(self, text: str) -> str:
        """Writes terms the way the vocabulary does. "pool request" (an alias) becomes
        "pull request", and spelling variants of rare terms get fixed: "data garage" and
        "Datagarage" become "Data Garage", "Net vora" becomes "Netvora", "E T L"
        becomes "ETL". Common words are left alone: a term "ToP" doesn't touch "the top", and
        "OpenFlow" doesn't touch "an open flow"."""
        if self._rules is None:
            self._rules = _rules(self.terms)
        for pattern, replace in self._rules:
            text = pattern.sub(replace, text)
        return text


def common(word: str) -> bool:
    """A word you'd find in ordinary German or English text."""
    from wordfreq import zipf_frequency  # lazy: ~0.5 s to load

    w = word.lower()
    return max(zipf_frequency(w, "de"), zipf_frequency(w, "en")) >= 4.0


SEP = re.compile(r"[\s-]+")


def _alternation(keys) -> str:
    return "|".join(sorted(keys, key=len, reverse=True))  # longest first


def _rules(terms: list[Term]) -> list:
    rules = []
    aliases = {a.lower(): t.text for t in terms for a in t.aliases if a}
    if aliases:
        alts = _alternation(re.escape(a) for a in aliases)
        rules.append((re.compile(rf"(?<!\w)({alts})(?!\w)", re.I), lambda m: aliases[m.group(1).lower()]))

    spellings, patterns = {}, []
    for t in terms:
        parts = SEP.split(t.text.strip())
        if len(parts) == 1 and common(parts[0]):  # "CoP" must not rewrite "cop"
            continue
        key = re.sub(r"[\s-]", "", t.text.lower())
        if key in spellings or len(key) < 2:
            continue
        spellings[key] = (t.text, [p.lower() for p in parts])
        # Each character, optionally separated by a space or hyphen: "Data-Garage", "E T L".
        patterns.append(r"[\s-]?".join(re.escape(c) for c in key))
    if patterns:
        def fix(m):
            found = m.group(0)
            term, own = spellings[re.sub(r"[\s-]", "", found.lower())]
            words = [w.lower() for w in SEP.split(found)]
            if words != own and len(words) > 1:
                spelled = all(len(w) == 1 for w in words) and term.isupper()  # "E T L" -> "ETL"
                if not spelled and all(common(w) for w in words):  # "an open flow" stays
                    return found
            return term

        rules.append((re.compile(rf"(?<!\w)(?:{_alternation(patterns)})(?!\w)", re.I), fix))
    return rules


def parse(markdown: str) -> Vocabulary:
    vocab = Vocabulary()
    seen: set[str] = set()
    ignored: set[str] = set()
    in_block = False
    category = None
    for line in markdown.splitlines():
        s = line.strip()
        if s.startswith(START):
            in_block, category = True, None
            continue
        if s.startswith(END):
            in_block, category = False, None
            continue
        if (m := DOMAIN.match(s)) and not in_block and not vocab.domain:
            vocab.domain = m.group(1)
            continue
        if s.startswith("### ") and in_block:
            category = s[4:].strip()
            continue
        if s.startswith("## "):
            category = None if in_block else s[3:].strip()
            continue
        if s.startswith("#"):
            category = None if not in_block else category
            continue
        if not (m := BULLET.match(line)) or category is None:
            continue
        text, aliases = m.group(1), []
        if h := HEARD_AS.search(text):
            aliases = [a.strip() for a in h.group(1).split(",") if a.strip()]
            text = text[: h.start()].strip()
        if not text:
            continue
        key = text.lower()
        if category.lower() == "ignore" and not in_block:
            vocab.ignore.append(text)
            ignored.add(key)
        elif key not in seen:
            seen.add(key)
            vocab.terms.append(Term(text, category, "vault" if in_block else "manual", aliases))
    # Ignore only overrides the vault: a term you listed yourself stays.
    vocab.terms = [t for t in vocab.terms if t.source == "manual" or t.text.lower() not in ignored]
    return vocab


def load(path: str = DEFAULT_PATH) -> Vocabulary:
    try:
        with open(path, encoding="utf-8") as f:
            return parse(f.read())
    except FileNotFoundError:
        return Vocabulary()


def write_atomic(path: str, text: str):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".vocab-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def write_vault_block(path: str, groups: dict[str, list[str]], heading: str, domain: str = ""):
    """Rewrites only the vault block (appended if missing). `domain` fills an empty Domain line;
    once there is one, it's yours."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        text = TEMPLATE
    lines = [f"{START}  Regenerated by OpenFlow's vault scan. Move a line above to keep it. -->", f"## {heading}"]
    for category, terms in groups.items():
        if terms:
            lines += ["", f"### {category}", *(f"- {t}" for t in terms)]
    lines.append(END)
    block = "\n".join(lines)
    start, end = text.find(START), text.find(END)
    if start != -1 and end > start:
        text = text[:start] + block + text[end + len(END):]
    else:
        text = text.rstrip("\n") + "\n\n" + block + "\n"
    if domain:
        text = re.sub(r"(?m)^Domain:[ \t]*$", f"Domain: {domain}", text, count=1)
    write_atomic(path, text)


if __name__ == "__main__":
    sample = TEMPLATE.replace("## Terms\n", "## Terms\n- ACME\n- pull request (heard as: pool request, pul request)\n")
    sample = sample.replace("## Ignore\n", "## Ignore\n- Helper\n")
    sample += f"\n{START} x -->\n## From vault: Notes\n### People\n- Jana Weber\n- ACME\n### Terms\n- Helper\n{END}\n"
    v = parse(sample)
    assert [(t.text, t.source) for t in v.terms] == [("ACME", "manual"), ("pull request", "manual"), ("Jana Weber", "vault")], v.terms
    assert v.ignore == ["Helper"]
    assert v.normalize("the pool request and a Pool Request.") == "the pull request and a pull request."
    assert v.normalize("a whirlpool requester") == "a whirlpool requester"
    v = parse("## Terms\n- ToP\n- OpenFlow\n- Data Garage\n- Netvora\n- ETL\n- ACME\n")
    for raw, want in [
        ("the top shelf is full", "the top shelf is full"),
        ("an open flow of ideas, in Openflow", "an open flow of ideas, in OpenFlow"),
        ("im data garage und im Datagarage", "im Data Garage und im Data Garage"),
        ("Net vora baut für die acme", "Netvora baut für die ACME"),
        ("die E T L Planung", "die ETL Planung"),
    ]:
        assert v.normalize(raw) == want, (raw, v.normalize(raw))
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "Vocabulary.md")
        write_vault_block(p, {"People": ["Jana Weber"], "Acronyms": ["ToP"]}, "From vault: Notes", "logistics IT")
        write_vault_block(p, {"People": ["Max Muster"]}, "From vault: Notes", "something else")
        v = load(p)
        assert v.domain == "logistics IT" and [t.text for t in v.terms] == ["Max Muster"], v
    print("vocab ok")

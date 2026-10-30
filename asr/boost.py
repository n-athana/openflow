"""Vocabulary biasing for the RNN-T decoder: shallow fusion with a character trie.

While decoding, a bonus is added to the joint's logits for every token that starts a vocabulary
term at a word start, or continues one that is being emitted. Matching is by characters,
case-insensitive, so it doesn't matter how the model splits a word: "OpenFlow" counts whether it
comes out as ▁Open Flow or ▁O p en F lo w. The bonus stays small until a couple of letters match:
names start on very common tokens (▁N, ▁O), and boosting those hard would bend ordinary words
toward the vocabulary.

The bonus goes onto the joint network's output (a forward hook on `joint.head`), not through a
logits processor: transformers' RNN-T loop decides blank vs. token from the raw logits, so the
token choice and the frame advance both have to see the same biased scores.
"""

from collections import OrderedDict

import torch

SPACE = "▁"


class Node:
    __slots__ = ("children", "letters", "moves", "id")

    def __init__(self, letters: int, node_id: int):
        self.children: dict[str, Node] = {}
        self.letters = letters  # letters of the term matched so far
        self.moves: dict[int, Node] | None = None  # token -> node it leads to, filled on first use
        self.id = node_id


class Booster:
    """The term trie and its bonus vectors, shared by all decoders. `state()` gives one decode its
    own match state."""

    def __init__(self, tokenizer, terms: list[str], vocab_size: int, blank_id: int, device="cpu",
                 dtype=torch.float32, start: float = 1.0, boost: float = 3.0, min_letters: int = 2,
                 max_terms: int = 1000):
        self.vocab_size, self.blank_id = vocab_size, blank_id
        self.device, self.dtype = device, dtype
        self.start, self.boost, self.min_letters = start, boost, min_letters
        self.nodes = 0
        self.root = self._node(0)
        self.terms = [t for t in terms if t.strip()][:max_terms]
        for term in self.terms:
            node = self.root
            for c in SPACE + SPACE.join(term.lower().split()):
                if c not in node.children:
                    node.children[c] = self._node(node.letters + (c != SPACE))
                node = node.children[c]
        # Every token's text as a trie too: the tokens that fit a term from some point on are a
        # walk through both tries at once.
        self.pieces: dict = {}
        for i, piece in enumerate(tokenizer.convert_ids_to_tokens(list(range(vocab_size)))):
            if i == blank_id or not piece or (piece.startswith("<") and piece.endswith(">")):
                continue
            node = self.pieces
            for c in piece.lower():
                node = node.setdefault(c, {})
            node.setdefault(None, []).append(i)
        self.cache: OrderedDict[tuple, torch.Tensor] = OrderedDict()
        self.base = self._bias((self.root,))

    def _node(self, letters: int) -> Node:
        self.nodes += 1
        return Node(letters, self.nodes)

    def moves(self, node: Node) -> dict[int, Node]:
        if node.moves is None:
            node.moves = {}
            stack = [(node, self.pieces)]
            while stack:
                term_node, piece_node = stack.pop()
                for c, piece_child in piece_node.items():
                    if c is not None and (term_child := term_node.children.get(c)):
                        for token in piece_child.get(None, ()):
                            node.moves[token] = term_child
                        stack.append((term_child, piece_child))
        return node.moves

    def _bias(self, active: tuple) -> torch.Tensor:
        """Bonus per token: the best over every active node's next tokens."""
        key = tuple(n.id for n in active)
        if (hit := self.cache.get(key)) is not None:
            self.cache.move_to_end(key)
            return hit
        bias = torch.zeros(self.vocab_size)
        for node in active:
            if ids := list(self.moves(node)):
                bonus = self.boost if node.letters >= self.min_letters else self.start
                idx = torch.tensor(ids, dtype=torch.long)
                bias[idx] = torch.clamp(bias[idx], min=bonus)
        tensor = bias.to(self.device, self.dtype)
        self.cache[key] = tensor
        if len(self.cache) > 512:
            self.cache.popitem(last=False)
        return tensor

    def state(self) -> "BoostState":
        return BoostState(self)


class BoostState:
    """Which term prefixes the decode is in the middle of. A term can start at any word start,
    so the root is always active."""

    def __init__(self, booster: Booster):
        self.b = booster
        self.active: tuple[Node, ...] = ()
        self.bias = booster.base

    def step(self, token: int):
        b = self.b
        if token == b.blank_id or token >= b.vocab_size:  # blank only advances the audio frame
            return
        nxt = {n.id: n for a in (b.root, *self.active) if (n := b.moves(a).get(token)) and n.children}
        self.active = tuple(nxt.values())
        self.bias = b._bias((b.root, *self.active)) if self.active else b.base


def attach(processor):
    """Adds the active decode's bonus to the joint's logits. `processor.boost` is the BoostState
    of the decode running on this model, or None."""
    processor.boost = None

    def hook(_module, _inputs, output):
        state = processor.boost
        return output + state.bias if state is not None else None

    return processor.model.joint.head.register_forward_hook(hook)


if __name__ == "__main__":
    pieces = ["<blank>", "▁N", "i", "ko", "la", "s", "▁Ni", "ce", "▁", "Q", "D", "X", "▁the", "▁Open", "F", "low",
              "▁O", "p", "en", "Flow", "▁open", "▁flow"]

    class FakeTok:
        def convert_ids_to_tokens(self, ids):
            return [pieces[i] for i in ids]

    ix = {p: i for i, p in enumerate(pieces)}
    b = Booster(FakeTok(), ["Nikola", "QDX", "OpenFlow", "open flow"], vocab_size=len(pieces), blank_id=0)
    s = b.state()
    assert s.bias[ix["▁N"]] == 1.0 and s.bias[ix["▁Ni"]] == 1.0 and s.bias[ix["▁"]] == 1.0
    assert s.bias[ix["▁Open"]] == 1.0 and s.bias[ix["▁open"]] == 1.0 and s.bias[ix["i"]] == 0 and s.bias[0] == 0
    s.step(ix["▁N"])  # one letter: still the small bonus
    assert s.bias[ix["i"]] == 1.0
    s.step(0)  # blank keeps the match
    s.step(ix["i"])  # two letters: full bonus
    assert s.bias[ix["ko"]] == 3.0 and s.bias[ix["▁N"]] == 1.0  # a new word can still start
    s.step(ix["▁the"])  # breaks the match
    assert s.bias[ix["ko"]] == 0 and not s.active
    s.step(ix["▁Open"])  # any split works: ▁Open + Flow, ▁Open + F low, and "open ▁flow"
    assert s.bias[ix["Flow"]] == 3.0 and s.bias[ix["F"]] == 3.0 and s.bias[ix["▁flow"]] == 3.0
    s.step(ix["F"])
    assert s.bias[ix["low"]] == 3.0
    s.step(ix["low"])  # complete
    assert not s.active and s.bias is b.base
    for t in ["▁", "Q", "D"]:
        s.step(ix[t])
    assert s.bias[ix["X"]] == 3.0
    print("boost ok:", len(b.terms), "terms,", b.nodes, "nodes")

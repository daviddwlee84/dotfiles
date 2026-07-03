#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "numpy>=2",
# ]
# ///
"""semsearch — semantic search over local text via the Copilot proxy.

Engine behind the `semsearch` shell wrapper (dot_config/shell/44_copilot_embed.sh).
The wrapper resolves this file via `chezmoi source-path`, ensures the proxy is up,
and runs it with `uv run --script`. Two modes:

  semsearch index [PATH...]          build/refresh an embedding index
  semsearch <QUERY> [-k N] [--corpus PATH]
                                     rank the indexed chunks against QUERY

Default corpus (no PATH / no --corpus) = `<chezmoi source>/docs/tools`, so
"where did I document X?" becomes a natural-language query.

Design:
  - Chunk each file by blank-line paragraphs, remembering each chunk's start line.
  - Embed via POST /v1/embeddings on the local proxy. The proxy REQUIRES `input`
    to be an ARRAY (a scalar 400s — the fork's issue #100), so we always send a
    list and batch many chunks per request.
  - Cache one JSONL per corpus under $XDG_STATE_HOME/copilot-proxy/embeddings/;
    re-indexing only embeds chunks whose content hash is new (incremental).
  - Query = embed the text, cosine top-k over the cached matrix (numpy).

Config (env, set by the wrapper / the SSOT 04_ai_agents.sh):
  COPILOT_EMBED_BASE   proxy base URL     (fallback: http://localhost:$COPILOT_PROXY_PORT)
  COPILOT_PROXY_PORT   proxy port         (fallback: 4141)
  AICAP_EMBED_MODEL    embedding model    (fallback: text-embedding-3-small; empty → endpoint default)
"""
from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

import numpy as np

DEFAULT_GLOBS = ["*.md", "*.txt", "*.sh", "*.py"]
MAX_CHARS = 8000          # per-chunk cap (embeddings handle ~8k tokens)
BATCH = 64                # texts per /v1/embeddings request
TIMEOUT = 120


# --- config ---------------------------------------------------------------------

def proxy_base() -> str:
    base = os.environ.get("COPILOT_EMBED_BASE")
    if base:
        return base.rstrip("/")
    port = os.environ.get("COPILOT_PROXY_PORT", "4141")
    return f"http://localhost:{port}"


def embed_model() -> str:
    # Empty string is meaningful: omit the model so the endpoint default applies.
    return os.environ.get("AICAP_EMBED_MODEL", "text-embedding-3-small")


def cache_dir() -> str:
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    d = os.path.join(state, "copilot-proxy", "embeddings")
    os.makedirs(d, exist_ok=True)
    return d


def default_root() -> str | None:
    try:
        out = subprocess.run(
            ["chezmoi", "source-path"], capture_output=True, text=True, timeout=10
        )
        if out.returncode == 0 and out.stdout.strip():
            return os.path.join(out.stdout.strip(), "docs", "tools")
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def resolve_roots(paths: list[str]) -> list[str]:
    if paths:
        return sorted(os.path.abspath(os.path.expanduser(p)) for p in paths)
    root = default_root()
    return [root] if root else []


def corpus_id(roots: list[str]) -> str:
    return hashlib.sha1("\n".join(roots).encode()).hexdigest()[:16]


def cache_path(roots: list[str]) -> str:
    return os.path.join(cache_dir(), corpus_id(roots) + ".jsonl")


# --- embedding over the proxy ---------------------------------------------------

def embed_batch(texts: list[str]) -> list[list[float]]:
    """POST a list of texts to /v1/embeddings; return vectors in input order."""
    url = proxy_base() + "/v1/embeddings"
    payload: dict = {"input": texts}          # input MUST be an array (issue #100)
    model = embed_model()
    if model:
        payload["model"] = model
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        try:
            detail = json.loads(detail).get("error", {}).get("message", detail)
        except (ValueError, AttributeError):
            pass
        die(f"embeddings HTTP {e.code}: {detail.strip()}  (proxy up? array input?)")
    except urllib.error.URLError as e:
        die(f"cannot reach the proxy at {url}: {e.reason}  (copilot-proxy status)")
    data = sorted(body.get("data", []), key=lambda d: d.get("index", 0))
    if len(data) != len(texts):
        die(f"embeddings returned {len(data)} vectors for {len(texts)} inputs")
    return [d["embedding"] for d in data]


def embed_all(texts: list[str]) -> list[list[float]]:
    out: list[list[float]] = []
    for i in range(0, len(texts), BATCH):
        batch = texts[i : i + BATCH]
        out.extend(embed_batch(batch))
        eprint(f"  embedded {min(i + BATCH, len(texts))}/{len(texts)} chunks")
    return out


# --- chunking -------------------------------------------------------------------

def chunk_file(path: str) -> list[tuple[int, str]]:
    """Split a file into (start_line, text) blank-line-separated paragraphs."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
    except OSError:
        return []
    chunks: list[tuple[int, str]] = []
    buf: list[str] = []
    start = 1
    for i, line in enumerate(lines, 1):
        if line.strip() == "":
            if buf:
                text = "\n".join(buf).strip()
                if text:
                    chunks.append((start, text[:MAX_CHARS]))
                buf = []
        else:
            if not buf:
                start = i
            buf.append(line)
    if buf:
        text = "\n".join(buf).strip()
        if text:
            chunks.append((start, text[:MAX_CHARS]))
    return chunks


def iter_files(roots: list[str], globs: list[str]):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for fn in sorted(filenames):
                if any(fnmatch.fnmatch(fn, g) for g in globs):
                    yield os.path.join(dirpath, fn)


def chunk_hash(path: str, text: str) -> str:
    return hashlib.sha1(f"{path}\0{text}".encode()).hexdigest()


# --- cache io -------------------------------------------------------------------

def load_cache(path: str) -> dict[str, dict]:
    """hash -> record ({path, start_line, hash, text, embedding})."""
    cache: dict[str, dict] = {}
    if not os.path.exists(path):
        return cache
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
                cache[rec["hash"]] = rec
            except (ValueError, KeyError):
                continue
    return cache


def write_cache(path: str, records: list[dict]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


# --- modes ----------------------------------------------------------------------

def do_index(argv: list[str]) -> int:
    globs = DEFAULT_GLOBS
    rebuild = False
    paths: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--glob":
            globs = [g.strip() for g in argv[i + 1].split(",") if g.strip()]
            i += 2
        elif a == "--rebuild":
            rebuild = True
            i += 1
        elif a.startswith("-"):
            die(f"index: unknown flag '{a}'")
        else:
            paths.append(a)
            i += 1

    roots = resolve_roots(paths)
    if not roots:
        die("index: no PATH given and could not resolve default (chezmoi source-path)")
    for r in roots:
        if not os.path.exists(r):
            die(f"index: path does not exist: {r}")

    cpath = cache_path(roots)
    existing = {} if rebuild else load_cache(cpath)

    # Scan → current chunk set.
    scanned: list[tuple[str, int, str, str]] = []  # (path, start_line, text, hash)
    n_files = 0
    for fp in iter_files(roots, globs):
        n_files += 1
        for start, text in chunk_file(fp):
            scanned.append((fp, start, text, chunk_hash(fp, text)))

    to_embed = [s for s in scanned if s[3] not in existing]
    eprint(
        f"semsearch: {len(scanned)} chunks from {n_files} files "
        f"({len(to_embed)} new, {len(scanned) - len(to_embed)} reused) → {os.path.basename(cpath)}"
    )

    new_vecs: dict[str, list[float]] = {}
    if to_embed:
        vectors = embed_all([s[2] for s in to_embed])
        for s, v in zip(to_embed, vectors):
            new_vecs[s[3]] = v

    # Rebuild the record list = current scan (prunes deleted/changed chunks).
    records: list[dict] = []
    for path, start, text, h in scanned:
        emb = new_vecs.get(h) or existing.get(h, {}).get("embedding")
        if emb is None:
            continue
        records.append(
            {"path": path, "start_line": start, "hash": h, "text": text, "embedding": emb}
        )
    write_cache(cpath, records)
    eprint(f"semsearch: index ready — {len(records)} chunks cached")
    return 0


def do_query(argv: list[str]) -> int:
    k = 8
    corpus: str | None = None
    terms: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-k", "--top"):
            k = int(argv[i + 1])
            i += 2
        elif a == "--corpus":
            corpus = argv[i + 1]
            i += 2
        elif a == "--":
            terms.extend(argv[i + 1 :])
            break
        elif a.startswith("-") and a != "-":
            die(f"query: unknown flag '{a}'")
        else:
            terms.append(a)
            i += 1

    query = " ".join(terms).strip()
    if not query:
        die("query: empty query")

    roots = resolve_roots([corpus] if corpus else [])
    if not roots:
        die("query: could not resolve default corpus (chezmoi source-path); pass --corpus PATH")
    cpath = cache_path(roots)
    cache = load_cache(cpath)
    if not cache:
        die(f"query: no index for this corpus — run: semsearch index {corpus or ''}".rstrip())

    records = list(cache.values())
    mat = np.asarray([r["embedding"] for r in records], dtype=np.float32)
    mat /= np.linalg.norm(mat, axis=1, keepdims=True) + 1e-8

    qv = np.asarray(embed_batch([query])[0], dtype=np.float32)
    qv /= np.linalg.norm(qv) + 1e-8

    scores = mat @ qv
    top = np.argsort(-scores)[:k]

    tty = sys.stdout.isatty()
    for idx in top:
        rec = records[int(idx)]
        rel = os.path.relpath(rec["path"])
        if rel.startswith(".."):
            rel = rec["path"]
        snippet = " ".join(rec["text"].split())[:100]
        loc = f"{rel}:{rec['start_line']}"
        if tty:
            loc = f"\033[1;36m{loc}\033[0m"
        print(f"{scores[int(idx)]:.3f}  {loc}\n       {snippet}")
    return 0


# --- helpers --------------------------------------------------------------------

def eprint(*a) -> None:
    print(*a, file=sys.stderr)


def die(msg: str) -> None:
    eprint(f"semsearch: {msg}")
    sys.exit(1)


def main() -> int:
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        eprint(__doc__)
        return 0 if argv else 1
    if argv[0] == "index":
        return do_index(argv[1:])
    return do_query(argv)


if __name__ == "__main__":
    sys.exit(main())

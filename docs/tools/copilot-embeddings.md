# Copilot embeddings → semantic search

The [Copilot → Claude Code proxy](copilot-claude-proxy.md) (`copilot-api` on
`localhost:4141`) is OpenAI-compatible and also serves **`POST /v1/embeddings`**,
backed by the same GitHub Copilot subscription. Copilot exposes three **1536-dim**
embedding models — `text-embedding-3-small` (default), `text-embedding-ada-002`,
`text-embedding-3-small-inference`. This turns the proxy into a zero-extra-cost
**local semantic-search** backend.

- **Shell helpers**: `~/.config/shell/44_copilot_embed.sh` (`copilot-embed`, `semsearch`)
- **Search engine**: `scripts/semsearch.py` (run via `uv run --script`, resolved by
  `chezmoi source-path` — stays in the chezmoi source tree, not applied to `$HOME`)
- **Model pin (SSOT)**: `AICAP_EMBED_MODEL` in `~/.config/shell/04_ai_agents.sh`
- Requires the proxy to be running (`copilot-proxy start`); both helpers auto-start it.

!!! warning "Same Copilot ToS caveat as the proxy"
    Embeddings go through the same reverse-engineered proxy and Copilot
    subscription — see the [proxy doc's ToS warning](copilot-claude-proxy.md).
    Indexing a large corpus fires many requests and the fork has **no rate
    limiter**; index big trees deliberately.

## Quick start

```sh
copilot-embed "hello world" | jq 'length'     # → 1536 (a raw embedding vector)

semsearch index                                # index the default corpus (chezmoi docs/tools)
semsearch "how do I switch the copilot model"  # natural-language search → ranked hits
semsearch "trim a video clip" -k 5             # top-5
semsearch index ~/notes                        # index another directory
semsearch "quarterly goals" --corpus ~/notes   # query that corpus
```

## How it works

```
text ──▶ copilot-embed / semsearch.py ──POST /v1/embeddings──▶ copilot-api (localhost:4141)
                                                                 │ Authorization: Bearer <copilot token>
                                                                 ▼
                                                          api.githubcopilot.com  (your Copilot sub)
```

`semsearch` chunks files by blank-line paragraphs (tracking each chunk's start
line), embeds them in batches, caches the vectors, and ranks by cosine similarity
against your query embedding. Ranking is by **meaning**, not keywords — e.g.
`"trim a video clip"` surfaces `ffmpeg.md`'s *"Trim / cut"* section even though the
words differ.

!!! danger "The embeddings `input` MUST be an array (issue #100)"
    The proxy rejects a **scalar** `input` string with a generic `400 Bad Request`
    — this is the fork's
    [issue #100](https://github.com/caozhiyuan/copilot-api/issues/100)
    ("Can not call /v1/embeddings successful"). The fix is simply to send
    `"input": ["your text"]` (an array) — `{"input":"your text"}` 400s,
    `{"input":["your text"]}` returns a vector. Both helpers always send an array
    (`copilot-embed` wraps one text; `semsearch.py` batches up to 64 per request).

## Shell helpers

### `copilot-embed [--model M] [--json] [TEXT | -]`

Embeds `TEXT` (a positional arg) or **stdin** (`-` or piped) and prints the vector
as a JSON array on **stdout** (status/metadata go to **stderr**, so pipes stay clean).

```sh
copilot-embed "some text"           # vector as a JSON array
printf 'doc body' | copilot-embed   # embed from stdin
copilot-embed --json "hi" | jq '.usage'   # full API response (usage, index, …)
copilot-embed --model text-embedding-ada-002 "text"   # override the model
copilot-embed -l                    # list the embedding-model ids the proxy serves
```

| Flag / env | Default | Meaning |
|---|---|---|
| `--model M` / `AICAP_EMBED_MODEL` | `text-embedding-3-small` | embedding model (empty → endpoint default) |
| `--json` | off | print the full response instead of just the vector |
| `-l` / `--list` | — | list embedding models from `/v1/models` |

Auto-starts the proxy when it isn't answering (mirrors `copilot-run`). Requires
`curl` + `jq`.

### `semsearch index [PATH...]` / `semsearch <QUERY> [-k N] [--corpus PATH]`

Thin wrapper over `scripts/semsearch.py` (resolved via `chezmoi source-path`,
cached per-shell — same pattern as `aiblock`). Auto-starts the proxy, then runs the
engine with `uv`.

- **`index [PATH...]`** — walk each `PATH` for `*.md,*.txt,*.sh,*.py` (override with
  `--glob '*.md,*.py'`), chunk, batch-embed, cache. Default `PATH` (none given) =
  `<chezmoi source>/docs/tools`. **Incremental**: only chunks whose content hash is
  new get embedded; unchanged chunks are reused and deleted/changed ones pruned.
  `--rebuild` forces a full re-embed.
- **`<QUERY>`** — embed the query, print the top-`k` (default 8) chunks as
  `score  path:start_line` + a one-line snippet, best first. `--corpus PATH` selects
  which indexed corpus to search (default: the docs corpus).

Each corpus is keyed by a hash of its root path(s), so different trees don't
collide. Cache lives at:

```
$XDG_STATE_HOME/copilot-proxy/embeddings/<corpus-hash>.jsonl   # (~/.local/state/… by default)
```

One JSON line per chunk (`{path, start_line, hash, text, embedding}`) — inspectable,
and cheap to prune. (Vectors are stored as JSON floats, so the cache is large-ish:
~20 KB/chunk. Fine for docs-sized corpora; delete a `<hash>.jsonl` to reset one.)

## Config

| Env var | Default | Meaning |
|---|---|---|
| `AICAP_EMBED_MODEL` | `text-embedding-3-small` | embedding model (SSOT in `04_ai_agents.sh`; empty → endpoint default) |
| `COPILOT_EMBED_BASE` | `http://localhost:$COPILOT_PROXY_PORT` | proxy base URL (set by the `semsearch` wrapper) |
| `COPILOT_PROXY_PORT` | `4141` | proxy port (shared with `43_copilot_proxy.sh`) |
| `XDG_STATE_HOME` | `~/.local/state` | where the embedding cache lives |

## Verify

```sh
echo "hello world" | copilot-embed | jq 'length'    # → 1536
copilot-embed -l                                     # → the three embedding models
semsearch index && semsearch "how do I switch the copilot model"
#   → copilot-claude-proxy.md ranks at the top
semsearch index                                      # re-run → "0 new" (incremental cache hit)
```

## See also

- [Copilot → Claude Code proxy](copilot-claude-proxy.md) — the proxy that serves
  `/v1/embeddings` (auth, models, ToS, gotchas)
- [aicapture](aicapture.md) — the sibling AI shell tooling (`aifix`, `air`, the
  `http` agent) whose curl+jq pattern `copilot-embed` reuses
- [caozhiyuan/copilot-api#100](https://github.com/caozhiyuan/copilot-api/issues/100)
  — the array-`input` gotcha this doc resolves

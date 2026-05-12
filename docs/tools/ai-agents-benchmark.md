# AI Agent Benchmark — picking the fastest AICAP_AGENT

A snapshot benchmark of every agent the dotfiles AICAP layer supports
(`aifix` / `aiexplain` / `aiblock` / `aisuggest` / `tsum` all share the same
fallback chain). Re-runnable via [`scripts/bench_ai_agents.py`](https://github.com/daviddwlee84/dotfiles/blob/main/scripts/bench_ai_agents.py).

> **TL;DR — for an aifix-shape prompt (~700 chars in, ~500 chars out):**
>
> - **Fastest warm**: Ollama local (`llama3.2`: 2-3s, `qwen2.5-coder:3b`: 4-5s) — if you can run a local model.
> - **Fastest cloud (free)**: `openrouter/free` via the `http` agent (~2-10s, varies by routed sub-model).
> - **Most reliable cloud (paid)**: `opencode` with `github-copilot/claude-haiku-4.5` (~10-13s warm, low variance).
> - **Avoid**: `codex exec` is ~130s end-to-end for one-shot prompts due to its agent-mode harness — fine for multi-step tasks, terrible for single replies.

---

## Methodology

- **Prompt**: an aifix-shape "diagnose this git push error" prompt, 694 input chars.
- **Trials**: 1 cold + 2 warm per agent.
  - *Cold* = the first invocation in a fresh shell / cold model.
  - *Warm* = subsequent invocations (caches hot, model loaded).
- **Identical prompt** across all agents; identical environment variables; same machine.
- **Measured**: end-to-end wall time from `subprocess.run` start to exit (or `urllib.urlopen` end).

The harness lives at [`scripts/bench_ai_agents.py`](https://github.com/daviddwlee84/dotfiles/blob/main/scripts/bench_ai_agents.py). Each row in the table below was produced by exactly the same code path the AICAP wrappers use at runtime.

---

## Results

### 2026-05-12 — Mac Mini M4 / 16 GB / macOS 26.2

_Hardware: Apple M4 / 16 GB / macOS 26.2; prompt: 694 chars; 1 cold + 2 warm runs per agent._

| Agent | Cold | Warm median | Warm range | Avg reply | Status |
|---|---:|---:|---:|---:|---|
| http Ollama (llama3.2:latest, local) | 7.2s | **2.5s** | 2.4–2.7s | 484 ch | ✅ |
| http Ollama (qwen2.5-coder:3b, local) | 7.1s | **4.8s** | 4.2–5.4s | 739 ch | ✅ |
| http OpenRouter (`openrouter/free` auto-route) | 9.5s | **2.3s** | 2.1–2.5s | 602 ch | ✅ |
| opencode (`github-copilot/claude-haiku-4.5`) | 16.2s | **10.3s** | 8.3–12.4s | 633 ch | ✅ |
| http OpenRouter (`openai/gpt-oss-20b:free`) | 11.0s | **13.6s** | 13.0–14.3s | 830 ch | ✅ |
| claude (`haiku` alias) | 13.2s | **14.3s** | 12.9–15.7s | 525 ch | ✅ |
| cursor-agent (`composer-2-fast` default) | 21.7s | **16.5s** | 16.0–16.9s | 767 ch | ✅ |
| codex (account default) | 138.5s | **134.8s** | 128.5–141.2s | 458 ch | ✅ but slow |
| http OpenRouter (`google/gemma-4-26b-a4b-it:free`) | — | — | — | — | ⚠ HTTP 429 (rate-limited) |
| http OpenRouter (`qwen/qwen3-coder:free`) | — | — | — | — | ⚠ HTTP 429 (rate-limited) |

**Cold-start cost** is real and varies a lot:

- **Claude Code** (`claude -p`) pays ~5-10s of harness boot every cold invocation (loads MCP servers, hooks, tools, session state).
- **opencode** has the lightest cold start of the CLI agents.
- **cursor-agent** is verbose-by-default (longer replies → higher latency) but reliable.
- **Ollama** pays a one-time model-load (~5s) per Ollama process — subsequent calls use the resident model in VRAM.
- **OpenRouter** has effectively zero client-side cold start (urllib direct call); model-side cold start depends on the routed upstream.

---

## When to use which agent

### Local-first workflow (privacy + speed)

```sh
export AICAP_AGENT=http
export AICAP_HTTP_URL=http://localhost:11434/v1/chat/completions
export AICAP_HTTP_MODEL=qwen2.5-coder:3b   # or llama3.2:latest
# AICAP_HTTP_API_KEY not needed for Ollama
```

Pros: free, private, fast (2-5s warm). Cons: needs `ollama serve` running, model quality below Claude Haiku for ambiguous prompts.

### Cloud-first free workflow (default-resilient)

```sh
export AICAP_AGENT=http
# AICAP_HTTP_URL defaults to OpenRouter chat-completions
export AICAP_HTTP_MODEL=openrouter/free    # auto-route across free upstreams
export OPENROUTER_API_KEY=sk-or-…          # in ~/.shellrc.adhoc, NOT committed
```

Pros: free, no local resource cost, auto-falls-back when one model rate-limits or retires. Cons: free-tier rate limits hit on bursts (3+ calls per minute on the same model id); model routing changes day-to-day so quality varies.

### Paid-tier reliable cloud (default — what the dotfiles ship with)

The repo's [`dot_config/shell/04_ai_agents.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/04_ai_agents.sh) SSOT puts **opencode** first in the autodetect chain:

```sh
AICAP_AGENT_PRIORITY="opencode claude codex cursor-agent"
AICAP_OPENCODE_MODEL=github-copilot/claude-haiku-4.5
```

Result: every AICAP tool picks `opencode` if it's on PATH (cheap via GitHub Copilot subscription, ~10s warm, low variance, Haiku-quality replies).

### Multi-step / agentic workflow

For prompts that need tool-calling or multi-step reasoning, `codex exec` is the right hammer despite the ~130s wrapped wall time — the agent harness is the feature, not overhead. Don't use it for one-shot summarization (`tsum`) or one-shot fixes (`aifix`).

---

## Reproducing the benchmark

From the chezmoi source checkout:

```sh
set -a; source ~/.shellrc.adhoc; set +a   # exports OPENROUTER_API_KEY into env
uv run --script scripts/bench_ai_agents.py
```

Flags:

- `--warm-runs N` — number of warm trials after the single cold (default: 2).
- `--prompt-file PATH` — custom prompt (e.g. an aisuggest-shape NL→shell prompt).
- `--timeout SECONDS` — per-call hard timeout (default: 180).

The script auto-detects hardware (chip + RAM + OS) and prints the result table in markdown — copy-paste-ready into this doc.

---

## Caveats

### Free-tier rate limits

OpenRouter free-tier limits are aggressive — typically **3-5 requests per minute per model ID**. `openrouter/free` auto-routes across the full free pool so it dodges per-model limits most of the time, but a burst (e.g. `aifix` three times in a row) can still 429. The benchmark above ran with 8-second spacing for the HTTP rows; the two specific-model rows that 429'd hit limits even with spacing.

If you hit 429 repeatedly:
- Switch to a different specific model: `export AICAP_HTTP_MODEL=openai/gpt-oss-20b:free`
- Or fall back to a paid path: `unset AICAP_AGENT` (autodetect picks opencode)
- Or use Ollama locally: `export AICAP_HTTP_URL=http://localhost:11434/v1/chat/completions AICAP_HTTP_MODEL=llama3.2:latest`

### Model retirement

Free-tier model IDs churn quarterly. The previous default `google/gemini-2.0-flash-exp:free` retired between 2025-Q1 and 2026-Q2 — exactly the scenario the [conditional `-m`/`--model` design](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/04_ai_agents.sh) is built to survive. `openrouter/free` is the only ID that's effectively immortal because it doesn't pin to a specific upstream.

To see what's currently free:

```sh
curl -sS "https://openrouter.ai/api/v1/models" \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  | jq -r '.data[] | select(.id | endswith(":free")) | .id' | sort
```

### Ollama setup

The benchmark used pre-installed models. To replicate from scratch:

```sh
# macOS
brew install ollama
brew services start ollama

ollama pull llama3.2          # 2.0 GB, fast, generic
ollama pull qwen2.5-coder:3b  # 1.9 GB, code-tuned

# Verify
ollama list
curl -sS http://localhost:11434/api/tags | jq .
```

Ollama serves an OpenAI-compatible chat-completions endpoint at
`/v1/chat/completions`, so the `http` agent path needs no special-casing
beyond pointing `AICAP_HTTP_URL` at it.

### Cold vs warm gap

The cold column is what you feel on the **first** `aifix` of a new tmux session
or after `chezmoi apply`. Warm is what you feel on subsequent calls. If you
care about p50, the warm column is what matters; if you care about "snappy
first-impression", the cold column matters too.

The Claude Code harness in particular pays its boot cost every invocation
(it's not a long-running daemon), so `claude -p` calls don't really get a
"warm" benefit from the harness side — only the kernel filesystem cache
and Anthropic-side request routing get warm.

---

## See also

- [aicapture overview](aicapture.md) — what `aifix` / `aiexplain` / `aiblock` actually do
- [agent-overlays](agent-overlays.md) — how the per-tool agent configs are deployed
- [`dot_config/shell/04_ai_agents.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/04_ai_agents.sh) — the SSOT for AICAP_* defaults
- [`scripts/bench_ai_agents.py`](https://github.com/daviddwlee84/dotfiles/blob/main/scripts/bench_ai_agents.py) — the benchmark harness

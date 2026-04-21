# Read the Web as Markdown in the Terminal

Focus-mode reading (think Safari Reader / Firefox Reader View) but driven from a terminal: fetch a page, strip it down to the article body, render as markdown in a pager. Useful for offline reading, piping into LLMs, or just avoiding browser chrome when you already live in the shell.

This repo ships four interchangeable readers covering the common combinations of **remote vs local**, **article extraction vs full page**, and **different extractor strategies**. Pick the one that fits the page at hand.

## TL;DR

| Command | Extractor | Local / remote | Best for |
|---------|-----------|----------------|----------|
| `readurl <url>` | [Jina AI Reader](https://jina.ai/reader) (`r.jina.ai`) | remote | Default. Any page, zero local deps beyond `glow`. Fast. |
| `readlocal <url>` | [trafilatura](https://trafilatura.readthedocs.io/) | local (Python) | Privacy-sensitive or offline. Well-tuned for news/blog articles. |
| `readnode <url>` | [readability-cli](https://gitlab.com/gardenappl/readability-cli) (Mozilla Readability port) | local (Node) | Same algorithm as Firefox/Safari Reader View. Often the best article fidelity. |
| `readraw <url>` | `curl \| pandoc -f html -t gfm` | local | Escape hatch: docs / reference pages where article extraction strips too much. |

All four pipe into [`glow`](https://github.com/charmbracelet/glow) for rendering and paging, and all four wrap the fetch in `try_direct_then_proxy` so pages reachable without a proxy pay zero overhead.

Source: `dot_config/zsh/tools/55_web_reader.zsh` (readers) and `dot_config/zsh/tools/50_networking.zsh` (proxy helpers).

## The landscape — why four tools, not one

"Read a webpage as markdown" decomposes into three independent choices:

1. **Fetch** — `curl`, headless browser (for JS-heavy pages), or a remote service that fetches on your behalf.
2. **Extract** — strip navigation, ads, comments, footers; keep the article. Or don't, if you want the whole page.
3. **Render** — markdown into the terminal; `glow`, `mdcat`, or plain stdout.

No single tool owns the full pipeline well:

- [**Jina AI Reader**](https://jina.ai/reader) collapses fetch + extract into a single HTTP GET: `https://r.jina.ai/<url>` returns ready-to-read markdown. Zero install. Trade-offs: remote service (privacy / availability), and may itself be blocked from some networks — fall back through a proxy in that case.
- [**trafilatura**](https://trafilatura.readthedocs.io/) is a Python library + CLI focused on article extraction. Local, offline, battle-tested on news/blog corpora. Weakness: built-in fetcher is bare — sites with heavy anti-bot measures can trip it.
- [**readability-cli**](https://gitlab.com/gardenappl/readability-cli) (binary: `readable`) wraps Mozilla's Readability library — the exact algorithm behind Firefox / Safari Reader View. Excellent fidelity on article-shaped pages.
- [**pandoc**](https://pandoc.org/) does no extraction; it converts full HTML to GFM markdown. Handy when the "article body" is the whole page (e.g. a man-page-style spec, a GitHub README rendered HTML, a single-column docs page).

Other options considered but not wired up (install manually if you want them):

- [**monolith**](https://github.com/Y2Z/monolith) — saves a whole page (+ assets) as a single-file HTML. Good for archival, but doesn't help with focus reading.
- [**w3m / lynx / elinks -dump**](https://w3m.sourceforge.net/) — text-mode browsers that render to plaintext (not markdown). Useful when all else fails; no extraction.
- [**Postlight Parser**](https://github.com/postlight/parser) — older, less maintained than readability-cli, same family.
- [**single-file-cli**](https://github.com/gildas-lormeau/single-file-cli) — headless-Chrome based; overkill for reading, great for archival.
- [**mdcat**](https://github.com/swsnr/mdcat) — alternative markdown renderer (hyperlinked terminals); `glow -p` remains the default here because it pages.

## Usage

```bash
# jina.ai Reader — default, zero-install (beyond glow)
readurl nytimes.com/2024/.../some-article

# trafilatura — fully local, no third-party
readlocal example.com/some-article

# Mozilla Readability — best article fidelity
readnode example.com/some-article

# No extraction — full page HTML → GFM markdown
readraw docs.example.com/reference/api
```

URLs don't need a scheme — `_norm_url` prepends `https://` if missing.

### Recipes

**Save the extracted markdown to a file**

```bash
trafilatura -u "https://example.com/post" --markdown > post.md
readable "https://example.com/post" > post.md
curl -fsSL https://r.jina.ai/https://example.com/post > post.md
```

**Pipe into a chat / LLM CLI**

```bash
trafilatura -u "$url" --markdown | llm -s "Summarize in 5 bullets"
readable "$url" | claude -p "Extract the key claims"
```

**Render with color in the terminal but no pager (useful in pipes)**

```bash
readurl example.com | cat      # glow still formats; cat drops the pager
```

## Proxy behavior

Every reader wraps its fetch in `try_direct_then_proxy` (from `50_networking.zsh`). That means:

1. First attempt is direct — no proxy, no env mangling. Cheap.
2. On failure (non-zero exit), and only if a local proxy is detected, retry via `withproxy`.
3. If no proxy is available, the original exit code is preserved.

A note appears on stderr when the retry happens: `[retry via proxy http://127.0.0.1:7890]`.

### Detection priority

1. `$LOCAL_PROXY_URL` if exported (e.g. `http://127.0.0.1:7890`).
2. Otherwise, auto-probe loopback ports in this order: `7890 7891 1087 8118 8080`. First TCP-accepting port wins.
3. Otherwise, proxy is marked unavailable.

The result is cached per shell in `_ZSH_NET_PROXY_CACHE`. Call `proxy-refresh` after starting or stopping your local proxy to re-probe.

### Split HTTP / SOCKS5 ports (Clash `port:` + `socks-port:`)

Clash's mixed-port config (`mixed-port: 7890`) serves both HTTP and SOCKS5 on one port — the default behavior here Just Works.

If your config splits them (e.g. `port: 7890` for HTTP, `socks-port: 7891` for SOCKS5), set both explicitly:

```bash
export LOCAL_PROXY_URL="http://127.0.0.1:7890"           # HTTP/HTTPS
export LOCAL_PROXY_SOCKS_URL="socks5://127.0.0.1:7891"   # SOCKS5
```

`withproxy` and `proxy-on` then export:

| Env var | Uses |
|---|---|
| `http_proxy`, `https_proxy`, `HTTP_PROXY`, `HTTPS_PROXY` | `LOCAL_PROXY_URL` |
| `ALL_PROXY`, `all_proxy` | `LOCAL_PROXY_SOCKS_URL` (fallback: `LOCAL_PROXY_URL`) |

`proxy-status` shows both URLs when they differ.

### Auto-activate on shell startup

For machines that always route through the local proxy, auto-export the env vars at shell startup:

```bash
# e.g. in a machine-local zsh file, or ~/.zshenv
export LOCAL_PROXY_AUTO_ACTIVATE=1
```

When `50_networking.zsh` is sourced, it silently runs `proxy-on -q` if a proxy is detected. Nothing happens on machines without a proxy running.

Pairs naturally with `LOCAL_PROXY_URL` + `LOCAL_PROXY_SOCKS_URL` for deterministic behavior, or on its own to rely on port auto-probing.

## Proxy helper cheat sheet

| Helper | Scope | Notes |
|---|---|---|
| `withproxy <cmd…>` | one child process | `withproxy curl …`, `withproxy pip install …` |
| `try_direct_then_proxy <cmd…>` | one child, direct → proxy fallback | what the readers use internally |
| `proxy-on` / `proxy-on -q` | current shell, exports env vars | `-q` skips the success print |
| `proxy-off` | current shell, unsets env vars | also clears `ALL_PROXY`/`all_proxy`/`NO_PROXY` |
| `proxy-status` | read-only | reports **active** / **available** / **unavailable** + HTTP / SOCKS URLs |
| `proxy-refresh` | invalidate cache, re-probe | run after starting/stopping your proxy |

## Installation

| Tool | macOS | Debian/Ubuntu | Via ansible |
|---|---|---|---|
| `glow` | `brew install glow` | GitHub binary | `devtools` role |
| `pandoc` | `brew install pandoc` | `apt install pandoc` | `devtools` role |
| `trafilatura` | `uv tool install trafilatura` | `uv tool install trafilatura` | `python_uv_tools` role (enabled via `chezmoi init --force`) |
| `readable` (readability-cli) | `npm install -g readability-cli` | `npm install -g readability-cli` | user-opt-in (not auto-installed) |
| `curl`, `nc` | preinstalled | preinstalled | — |

Each reader checks its dependencies at call time and prints a one-line install hint if something is missing, so `readnode` on a fresh machine will tell you exactly what to run.

## Related

- `docs/zsh/aliases.md` — the single-line reference table for all shell shortcuts.
- `docs/tools/networking.md` — the broader networking-CLI doc (nmap, doggo, bandwhich, etc.).
- `dot_config/zsh/tools/50_networking.zsh` — proxy helper implementation.
- `dot_config/zsh/tools/55_web_reader.zsh` — reader function implementation.

# CLI Web Reader (article → markdown) + portable proxy helper

## Context

You drafted an ad-hoc zsh snippet that combines `r.jina.ai` + `glow` to read web pages as markdown in the terminal, plus a `withproxy` wrapper hardcoded to `127.0.0.1:7891`. Two problems to solve:

1. **No single extractor covers every case** — jina.ai is zero-install but remote/third-party; some pages need a local "reader mode" (trafilatura / Mozilla Readability); documentation pages sometimes read better as raw `pandoc` HTML→md without body-extraction stripping navigation.
2. **Hardcoded proxy port is wrong for a dotfiles repo** — Clash's port varies across machines, the proxy isn't always running, and most sites don't need it at all. The current `withproxy` forces proxy even when the target is reachable directly.

Goal: a self-contained set of zsh functions that (a) offer multiple extraction backends, (b) always try direct first and only touch the proxy as a fallback, (c) never hardcode a port — probe common Clash ports or honor a user-provided `LOCAL_PROXY_URL`.

## Design summary

- **Two files, clean separation of concerns**:
  - `dot_config/zsh/tools/50_networking.zsh` — **generic proxy helpers only** (one-shot, session toggle, status, probe). Reusable for any command, not tied to web-reading.
  - `dot_config/zsh/tools/55_web_reader.zsh` — **new file** holding every reader function. Loaded after 50 so it can rely on the proxy helpers. Keeping these separate means proxy logic stays small/reviewable and readers can be removed/added without touching the networking file.
- **Proxy helpers are general-purpose** — one-shot wrapper `withproxy <cmd…>`, auto-fallback `try_direct_then_proxy <cmd…>`, **and session-level toggles `proxy-on` / `proxy-off`** so the user can flip proxy env on for the whole shell (everything downstream inherits) and flip it off cleanly.
- **Four reader functions**, one per backend — user picks by function name, not flags, so each is memorable and Tab-completable:
  - `readurl <url>` — jina.ai Reader (default, zero local deps)
  - `readlocal <url>` — trafilatura (local Python, offline)
  - `readnode <url>` — readability-cli (Mozilla Readability via Node)
  - `readraw <url>` — `curl | pandoc -f html -t gfm` (full page, no extraction)
- **Every reader pipes into `glow -`** for consistent rendering/paging; each guards on missing binary with a one-line install hint.
- **Installation of the local extractors is opt-in** via existing ansible roles (trafilatura → `python_uv_tools`; pandoc → `devtools`; readability-cli → documented install one-liner — not auto-installed since the repo has no global-npm-tool role yet).

## Proxy design (portable, no hardcoded port)

### Detection priority (used by every helper)

1. `$LOCAL_PROXY_URL` if the user exported it (e.g. in a machine-local zsh file). Full URL like `http://127.0.0.1:7890`.
2. Otherwise auto-probe common loopback ports with `nc -z -w1`: `7890` (Clash default), `7891` (user's current), `1087` (ClashX legacy), `8118` (Privoxy), `8080` (generic). First one that accepts a TCP connection wins.
3. Otherwise mark proxy as unavailable — `withproxy` silently becomes a passthrough, `try_direct_then_proxy` just runs the direct attempt.

Detection result is cached in a shell-local variable (`_ZSH_NET_PROXY_CACHE`) so the probe runs at most once per shell. A `proxy-refresh` function clears the cache (use after starting/stopping Clash).

### Four usage modes (each solves a different problem)

| Helper | Scope | When to use |
|---|---|---|
| `withproxy <cmd…>` | single command, child process only | quick one-off that needs proxy, without polluting current shell |
| `try_direct_then_proxy <cmd…>` | single command, direct → proxy fallback | the default for readers — zero cost on non-GFW'd URLs |
| `proxy-on` | **current shell**, exports env vars | about to run many commands that need proxy (e.g. a batch of `pip install`, `npm i`, etc.); everything downstream inherits until you turn it off |
| `proxy-off` | **current shell**, unsets env vars | turn off shell-level proxy cleanly; also unsets `http_proxy`, `https_proxy`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`, `no_proxy` |

`proxy-status` reports three distinct states clearly:
- **active** (shell env currently exports proxy — i.e. `proxy-on` was called)
- **available** (detected but not exported — `withproxy`/`try_direct_then_proxy` will use it on demand)
- **unavailable** (nothing detected and no `$LOCAL_PROXY_URL`)

Reader default behavior: **direct first, proxy fallback only if the first attempt fails AND a proxy is available.** This matches your `readauto` intent and makes the common case (non-GFW'd URL) zero-cost. If the user has already run `proxy-on`, curl/glow pick up proxy env directly and `try_direct_then_proxy` will still succeed on the first try — no double-wrapping.

## Files to modify

### 1. `dot_config/zsh/tools/50_networking.zsh` — **proxy helpers only**

Append a new section "Proxy helpers (generic)" with:

- `__zsh_net_detect_proxy` (internal) — populates `_ZSH_NET_PROXY_CACHE` to either a URL or the literal `none`. Runs only if cache is empty.
- `withproxy <cmd…>` — export `http_proxy`/`https_proxy`/`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` for the child process only; passthrough if proxy unavailable. Replaces your existing ad-hoc `withproxy`.
- `try_direct_then_proxy <cmd…>` — run direct; on non-zero exit, print a one-line notice to stderr and retry via `withproxy`. Skip retry if proxy is unavailable.
- `proxy-on` — set proxy env vars in the **current shell** so all subsequent commands inherit them. Triggers detection if cache is empty. No-op + warning if unavailable.
- `proxy-off` — unset `http_proxy`, `https_proxy`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`, `no_proxy` from the current shell.
- `proxy-status` — report **active** / **available** / **unavailable** (see table above) plus the detected URL and source (env override vs probe result).
- `proxy-refresh` — clear cache + re-probe, then call `proxy-status`. Use after toggling Clash.

Sketch of the core helpers (final wording polished at implementation time):

```zsh
: "${_ZSH_NET_PROXY_CACHE:=}"
__ZSH_NET_PROXY_PROBE_PORTS=(7890 7891 1087 8118 8080)

__zsh_net_detect_proxy() {
  [[ -n "$_ZSH_NET_PROXY_CACHE" ]] && return 0
  if [[ -n "$LOCAL_PROXY_URL" ]]; then
    _ZSH_NET_PROXY_CACHE="$LOCAL_PROXY_URL"; return 0
  fi
  local port
  for port in "${__ZSH_NET_PROXY_PROBE_PORTS[@]}"; do
    if nc -z -w1 127.0.0.1 "$port" 2>/dev/null; then
      _ZSH_NET_PROXY_CACHE="http://127.0.0.1:$port"; return 0
    fi
  done
  _ZSH_NET_PROXY_CACHE="none"; return 1
}

withproxy() {
  __zsh_net_detect_proxy
  [[ "$_ZSH_NET_PROXY_CACHE" == "none" ]] && { "$@"; return; }
  http_proxy="$_ZSH_NET_PROXY_CACHE" https_proxy="$_ZSH_NET_PROXY_CACHE" \
    HTTP_PROXY="$_ZSH_NET_PROXY_CACHE" HTTPS_PROXY="$_ZSH_NET_PROXY_CACHE" \
    ALL_PROXY="$_ZSH_NET_PROXY_CACHE" "$@"
}

try_direct_then_proxy() {
  "$@" && return 0
  __zsh_net_detect_proxy
  [[ "$_ZSH_NET_PROXY_CACHE" == "none" ]] && return 1
  print -u2 "[retry via proxy $_ZSH_NET_PROXY_CACHE]"
  withproxy "$@"
}

proxy-on() {
  __zsh_net_detect_proxy
  if [[ "$_ZSH_NET_PROXY_CACHE" == "none" ]]; then
    print -u2 "proxy-on: no proxy detected (set \$LOCAL_PROXY_URL or start Clash)"; return 1
  fi
  export http_proxy="$_ZSH_NET_PROXY_CACHE" https_proxy="$_ZSH_NET_PROXY_CACHE" \
         HTTP_PROXY="$_ZSH_NET_PROXY_CACHE" HTTPS_PROXY="$_ZSH_NET_PROXY_CACHE" \
         ALL_PROXY="$_ZSH_NET_PROXY_CACHE"
  print "proxy ON  →  $_ZSH_NET_PROXY_CACHE"
}

proxy-off() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY no_proxy
  print "proxy OFF"
}
```

### 2. `dot_config/zsh/tools/55_web_reader.zsh` — **new file**, reader functions

Loaded after 50_networking.zsh by `load_zsh_dir`, so it can use `try_direct_then_proxy` directly.

Contents:

- `_norm_url <raw>` — prepend `https://` if scheme missing (lifted from your snippet). Local to this file.
- `__require_bin <name> <install-hint>` (internal, local) — single-line missing-binary guard used by all readers.
- `readurl <url>` — `try_direct_then_proxy glow -p "https://r.jina.ai/$(_norm_url "$1")"`. Keeps jina.ai as the convenient default. Requires `glow`.
- `readlocal <url>` — wraps trafilatura in `try_direct_then_proxy`; `trafilatura -u "…" --markdown | glow -`. Requires `trafilatura`.
- `readnode <url>` — `try_direct_then_proxy readable "…" | glow -` (readability-cli ships the `readable` binary). Requires `readable`.
- `readraw <url>` — `try_direct_then_proxy curl -fsSL "…" | pandoc -f html -t gfm | glow -`. Requires `curl` + `pandoc` + `glow`.
- Drop the old `pcurl` / `pglow` / `readcurl` / `readauto` / `rg` / `rcg` / `rag` aliases from your snippet — `readurl` already does the auto-fallback, and `rg` collides with ripgrep (which you use).

### 3. `dot_ansible/roles/python_uv_tools/defaults/main.yml` — add trafilatura

Add `trafilatura` to the `uv_tools` list (alongside `apprise`, `mlflow`, `sqlit-tui`, `tmuxp`, etc.). This is the opt-in path; users who don't enable `python_uv_tools` simply won't have `readlocal` working and the guard will tell them how to install it.

### 4. `dot_ansible/roles/devtools/tasks/main.yml` + `defaults/main.yml` — add pandoc

Install `pandoc` on both macOS (homebrew) and Linux (apt, with GitHub binary fallback for no-root / armv7l — check release availability). If cross-platform binary support is messy, make it macOS-only via a `when: ansible_os_family == 'Darwin'` guard and document the Linux install as `sudo apt install pandoc`. `readraw` guard will surface the missing-binary message on systems that skipped it.

### 5. `docs/zsh/aliases.md` — register every new shell entry

Add rows under the Networking section, with correct source file per function:

- From `dot_config/zsh/tools/50_networking.zsh`: `withproxy`, `try_direct_then_proxy`, `proxy-on`, `proxy-off`, `proxy-status`, `proxy-refresh`
- From `dot_config/zsh/tools/55_web_reader.zsh`: `readurl`, `readlocal`, `readnode`, `readraw`

Follow the existing table format: `| <cmd> | function | <relative path> | <one-line description> |`.

### 6. `README.md` — brief mention

One line under the appropriate "What You Get" subsection noting that a terminal web-reader is available (`readurl <url>`) with a pointer to `docs/zsh/aliases.md`. Keep it minimal per CLAUDE.md's "keep README concise" rule.

## What is NOT changing

- No chezmoi template prompt for proxy (the env-var + probe combo handles both static and dynamic cases).
- No changes to `.chezmoi.toml.tmpl`.
- `readability-cli` install is deliberately *not* added to ansible — npm globals are currently scattered and adding one more tool isn't worth a new role. The function's missing-binary guard will print `npm install -g readability-cli` if the user invokes `readnode` without it.

## Verification

After implementing, run these end-to-end (in a new shell so both zsh files are re-sourced):

1. **Proxy helpers, no proxy running**
   - `proxy-status` → "unavailable".
   - `withproxy curl -sS https://example.com > /dev/null; echo $?` → 0 (passthrough).
   - `proxy-on` → prints a warning, exits non-zero, env unchanged.
2. **Proxy helpers, Clash running on 7890 or 7891**
   - `proxy-refresh` → detects port, `proxy-status` reports "available".
   - `withproxy env | grep -i proxy` → shows the five proxy env vars exported **only for the child**.
   - After `proxy-on`: `env | grep -i proxy` in the current shell shows the five vars. `proxy-status` now reports "active".
   - `proxy-off`: `env | grep -i proxy` → empty. `proxy-status` returns to "available".
3. **Explicit override**
   - `LOCAL_PROXY_URL=http://127.0.0.1:7890 proxy-refresh && proxy-status` → honors the env override and labels source accordingly.
4. **Readers against a non-GFW'd page** (e.g. `https://example.com`, `https://blog.cloudflare.com/any-post`)
   - `readurl example.com` → renders via jina.ai, no proxy fallback expected.
   - `readlocal example.com` → renders via trafilatura (if installed).
   - `readnode example.com` → renders via readability-cli (if installed).
   - `readraw example.com` → full-page markdown (if pandoc installed).
5. **Readers against a GFW'd page** while Clash is running
   - Same commands should print the `[retry via proxy …]` notice on stderr and still render output.
6. **Syntax check**
   - `zsh -n dot_config/zsh/tools/50_networking.zsh`
   - `zsh -n dot_config/zsh/tools/55_web_reader.zsh`
7. **Ansible syntax check** (only if touching playbooks):
   - `ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml`
   - Same for `linux.yml`.

## Critical files referenced

- `dot_config/zsh/tools/50_networking.zsh` — extend with proxy helpers
- `dot_config/zsh/tools/55_web_reader.zsh` — **new file**, reader functions
- `dot_config/zsh/10_aliases.zsh` — style reference (aliases + functions patterns)
- `dot_ansible/roles/python_uv_tools/defaults/main.yml` — trafilatura entry
- `dot_ansible/roles/devtools/tasks/main.yml`, `defaults/main.yml` — pandoc install
- `docs/zsh/aliases.md` — update table (required per CLAUDE.md)
- `README.md` — one-line mention (required per CLAUDE.md when adding user-facing features)

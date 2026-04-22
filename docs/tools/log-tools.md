# Log Viewers — A Colorful Toolbelt for `.log` Files

Reading server/app logs in the terminal should be as pleasant as `bat` made reading source files. This repo ships four complementary tools — each solving a different part of the "read, follow, search, colorize" problem — plus zsh wrappers and a Television channel to tie them together.

All four are installed by the `devtools` Ansible role (see [`dot_ansible/roles/devtools/tasks/main.yml`](../../dot_ansible/roles/devtools/tasks/main.yml)). `tailspin`/`lnav`/`grc` install via Homebrew on macOS and apt on Debian/Ubuntu; `lnav` and `tailspin` also have user-level GitHub-release musl-binary fallbacks for Linux (including no-sudo shells). `ccze` is **Linux-only** — it has been removed from Homebrew core, so on macOS the `lessl` wrapper gracefully no-ops and you should reach for `tspin` instead.

## TL;DR

| Tool | Best for | Command shape | Notes |
|---|---|---|---|
| [`tailspin`](https://github.com/bensadeh/tailspin) (bin: `tspin`) | **One-shot colorizer** / `bat`-for-logs | `tspin file.log` (pager) · `… \| tspin --print` (pipe) | Zero config. Highlights dates, levels, IPs, URLs, numbers. Works on arbitrary text. |
| [`lnav`](https://lnav.org/) | **Interactive TUI** | `lnav file.log [file2.log …]` | Merges multi-file timelines, SQL queries on log data, built-in filters. The serious option. |
| [`grc`](https://github.com/garabik/grc) | **Custom regex rules** | `grc -es tail -f app.log` | Per-command coloring profiles in `~/.grc/conf.*`. Best when you control the log format. |
| [`ccze`](https://github.com/cornet/ccze) | **Lightweight pipe colorizer** | `ccze -A \| less -R` | Ancient but fast; the classic `tail -f \| ccze` pager idiom. **Linux-only** (removed from brew). |

Rule of thumb:

- **Just want colors right now?** → `tspin` (or the `catl` / `logtail` wrappers below).
- **Investigating an incident across multiple files or timestamps?** → `lnav`.
- **Have a custom log format + want colors every run?** → `grc` profile.
- **Already used to `ccze`, don't need more?** → `lessl` (our `ccze -A | less -R` wrapper).

## Zsh wrappers ([`dot_config/zsh/tools/29_log_tools.zsh`](../../dot_config/zsh/tools/29_log_tools.zsh))

Each wrapper is guarded on the underlying binary so it's safe on fresh machines:

| Command | Expands to | Use |
|---|---|---|
| `catl file.log` | `tspin --print file.log` | Colorful `cat` for logs. Stdout mode, composes with pipes (`catl app.log \| rg ERROR`). |
| `lessl file.log` | `ccze -A < file.log \| less -RSFX` | Classic pager with ANSI colors. Accepts stdin if no arg (`tail -f app.log \| lessl`). |
| `logtail file.log` | `tspin --follow file.log` (or `tail -F … \| tspin --print` on older tailspin) | Live follow with highlighting — the `tail -f` replacement. |

Registered in [`docs/zsh/aliases.md`](../zsh/aliases.md) under "Log Viewers".

## `tailspin` (`tspin`)

> "bat for logs." Zero-config regex-based highlighting that works on any text stream.

**What it colors automatically:** dates/times, log levels (`INFO`/`WARN`/`ERROR`/…), numbers, IP addresses, UUIDs, URLs, HTTP methods and status codes, file paths, quoted strings, key-value pairs, common identifiers.

**Usage modes:**

```bash
tspin app.log               # opens less(1) with colored output, supports search
tspin --follow app.log      # like tail -f, with live highlighting
tail -f app.log | tspin     # follow mode via stdin
rg ERROR app.log | tspin --print   # pipe-friendly stdout mode
```

Customize via `~/.config/tailspin/config.toml` (keywords / regex groups / disabled patterns); see `tspin --help` for flags like `--words` and `--no-builtin-keywords`.

**Integration example.** The `pueue` Television channel preview ([`dot_config/television/cable/pueue.toml`](../../dot_config/television/cable/pueue.toml)) pipes each task's log through `tspin --print` when available:

```toml
command = [
  "if command -v tspin >/dev/null 2>&1; then \
     pueue log '{split:\\t:0}' --lines 200 2>/dev/null | tspin --print; \
   else \
     pueue log '{split:\\t:0}' --lines 200 2>/dev/null; \
   fi || echo 'No log available for: {split:\\t:0}'",
]
```

The `if command -v …` guard means the channel still works on a fresh install before the `devtools` role runs.

## `lnav` — Logfile Navigator

The heavy-duty option. A terminal TUI that understands common log formats (syslog, Apache/nginx, systemd journal, JSON, generic timestamped lines), lets you merge multiple files into one timeline, and runs ad-hoc SQL queries over the parsed logs.

**Essentials:**

| Key / command | Action |
|---|---|
| `lnav file1.log file2.log …` | Open files (merged by timestamp) |
| `q` | Quit |
| `/pattern` | Forward search (regex) |
| `?pattern` | Reverse search |
| `n` / `N` | Next / previous search hit |
| `:filter-in <re>` / `:filter-out <re>` | Live filter |
| `;SELECT …` | SQL over parsed log records |
| `Shift+P` | Toggle pretty-print JSON |
| `t` | Time-view (histogram of log volume) |
| `:goto <time>` | Jump to a timestamp |

**Custom formats.** When Debian's apt version is older than what you need, or when your app writes a home-grown format, drop a JSON format file into `~/.lnav/formats/installed/` (see [lnav format docs](https://docs.lnav.org/en/latest/formats.html)). Our Linux fallback installs the latest musl build from GitHub releases into `~/.local/bin/lnav` so you get a current version even on older distros.

## `grc` — Generic Colouriser

A pipe-oriented colorizer with user-editable regex rulesets. Where `tailspin` gives you one opinionated default for all text, `grc` lets you define colors per command.

```bash
grc -es tail -f /var/log/nginx/access.log
grc -c /path/to/custom.conf kubectl logs -f my-pod
```

`-e` disables the default `stderr` merging; `-s` adds colors (as opposed to `-c` for a specific config).

**Configure your own profile.** Example for a Python / FastAPI stack:

```conf
# ~/.grc/conf.uvicorn
# colorize `uvicorn` + FastAPI access logs
regexp=(?<=^INFO:\s+)\S+
colour=cyan
count=more
-
regexp=(\s)(ERROR|CRITICAL)(\s)
colours=default,bold red,default
count=more
-
regexp=(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})
colour=dark gray
count=more
-
regexp=(\s)(4\d\d)(\s)
colours=default,yellow,default
count=more
-
regexp=(\s)(5\d\d)(\s)
colours=default,bold red,default
count=more
```

Then: `grc -c ~/.grc/conf.uvicorn uvicorn app:app`. System rulesets live in `/usr/share/grc/` — copy any of them into `~/.grc/` to override.

If you want your profile tracked in dotfiles, drop it under `dot_grc/conf.<name>` (new chezmoi source dir, not shipped yet — follow up when you have one you're happy with).

## `ccze` — Old-school Pipe Colorizer

Fast, minimal, written in C. Project upstream has been quiet for years; the package remains in Debian/Ubuntu apt repos but has been **removed from Homebrew core**, so on macOS it's effectively retired — prefer `tspin --print` there. On Linux it still works fine. Main idiom:

```bash
tail -f /var/log/syslog | ccze -A | less -R
# or via our wrapper
tail -f /var/log/syslog | lessl
```

The `-A` flag emits raw ANSI escapes (needed for `less -R`); without it `ccze` tries to take over the terminal itself. Good for simple syslog / Apache / sulog feeds; less smart than `tailspin` on modern structured/JSON logs.

## Why no Loguru / logger-internals wrapper?

One alternative considered: wrap Python's [Loguru](https://github.com/Delgan/loguru) or the stdlib `logging` module with a pretty handler, so Python scripts always emit colorized output. Rejected because:

1. **Wrong layer.** The viewer-side tools above work on any source — not just Python — so you don't need per-language buy-in.
2. **Invasive.** Every script or service would need to import the wrapper; operators don't have that luxury on someone else's code.
3. **Loguru already colorizes** when attached to a TTY. The hard cases (tail an existing `.log` file, journalctl output, nginx access logs) are all post-emission and want viewer-side tools.

Keep logging libraries boring. Put the color at the viewer.

## Television integration

Two touch points:

1. **New `logs` channel** — [`dot_config/television/cable/logs.toml`](../../dot_config/television/cable/logs.toml). `tv logs` fuzzy-browses `.log`/`.ndjson`/`.jsonl` files in `$PWD`, user/system log directories, and (on Linux) recent `journalctl` output. Preview cycles: tailspin-colored tail vs plain `bat`. Keybindings:
   - `Enter` → open in `lnav` (falls back to `ccze -A | less -R`, then plain `less`)
   - `Alt+T` → `tspin --follow` live tail
   - `Alt+E` → open in `$EDITOR`
   - `Ctrl+Y` → copy file path (OSC-52 over SSH)
2. **`pueue` channel preview retrofit** — task logs in [`pueue.toml`](../../dot_config/television/cable/pueue.toml) are now piped through `tspin --print` when available.

See [`docs/tools/tv.md`](tv.md) for the full list of Television channels.

## References

- [tailspin README](https://github.com/bensadeh/tailspin) — customization, keyword config
- [lnav user manual](https://docs.lnav.org/) — formats, SQL, keybindings
- [grc on GitHub](https://github.com/garabik/grc) — syntax for `conf.*` files
- [ccze on GitHub](https://github.com/cornet/ccze) — legacy but handy
- [Our aliases reference](../zsh/aliases.md#log-viewers) for `catl`/`lessl`/`logtail`

# Shell history (bash, zsh, atuin)

> **Audience**: anyone who wants to know where their shell history actually
> lives, what env vars / setopts shape it, how to inspect or clear it on a
> multi-user server, and where [atuin](../tools/atuin.md) fits in. For atuin
> setup and keybindings see [tools/atuin.md](../tools/atuin.md).

## TL;DR

| Question | Answer |
|---|---|
| Where does bash store history? | `~/.bash_history` (override with `$HISTFILE`). Writes happen on shell exit unless `shopt -s histappend` + a `PROMPT_COMMAND` flush. |
| Where does zsh store history? | `~/.zsh_history` (override with `$HISTFILE`). With `setopt share_history` (OMZ default), every command is appended immediately and re-read into other live sessions. |
| What sets our zsh history limits? | **Not us.** This repo sets zero zsh history options; everything comes from oh-my-zsh's [`lib/history.zsh`](https://github.com/ohmyzsh/ohmyzsh/blob/master/lib/history.zsh): `HISTSIZE=50000`, `SAVEHIST=10000`, plus `share_history` / `hist_ignore_dups` / `hist_ignore_space` / `hist_verify` / `extended_history` / `hist_expire_dups_first`. |
| What sets our bash history limits? | [`dot_config/bash/02_history.bash`](../../dot_config/bash/02_history.bash): `HISTSIZE=10000`, `HISTFILESIZE=20000`, `HISTCONTROL=ignoreboth`, `shopt -s histappend cmdhist`. |
| Can root read other users' history? | Usually yes (`/home/<user>/.{zsh,bash}_history`, mode `0600` by default), but it's **incomplete** — see [Multi-user audit](#multi-user-audit-on-a-server). atuin's SQLite is also readable but encrypted on the wire (not at rest by default). |
| What's the row cap on history files? | **No file-level cap, only count caps**: bash trims to `$HISTFILESIZE` lines on exit; zsh trims to `$SAVEHIST` entries on save. atuin has **no row cap** by default — the SQLite db grows forever (commands are tiny; ~1MB / 10k entries). |
| How do I really clear a command? | See [Clearing your own history](#clearing-your-own-history) — naive `history -d N` is not enough; you must also flush to disk, AND delete from atuin if installed. |

## Bash history

### Storage

- **File**: `$HISTFILE`, defaults to `~/.bash_history`. Permissions are
  whatever your `umask` produced when the file was first created — usually
  `0600` (owner read/write only). On systems with a hardened skel, sometimes
  `0644` — check with `stat -c %a ~/.bash_history` and `chmod 600` if it's
  group/world readable.
- **In-memory ring**: each interactive bash holds its own list of commands
  in RAM, capped at `$HISTSIZE` entries. `history` prints this ring; `fc -l`
  is the POSIX equivalent.
- **Disk file cap**: `$HISTFILESIZE` lines. On shell exit (or on each
  `history -a` / `history -w`), bash trims the file to this many lines.
- **No timestamps by default**. Set `HISTTIMEFORMAT='%F %T '` to get
  `2026-05-08 14:30:00 git status` style output from `history`. The format
  is stored as `#<unix-ts>` lines interleaved between commands in the file.

### Env vars (this repo's defaults in [`dot_config/bash/02_history.bash`](../../dot_config/bash/02_history.bash))

| Var | This repo | Bash default | Effect |
|---|---|---|---|
| `HISTSIZE` | `10000` | `500` | Max in-memory entries |
| `HISTFILESIZE` | `20000` | `500` | Max on-disk entries (file is trimmed on exit) |
| `HISTCONTROL` | `ignoreboth` | unset | `ignoredups`+`ignorespace`: dedupe consecutive, drop ` `-prefixed |
| `HISTIGNORE` | unset | unset | Colon-list of glob patterns to skip (e.g. `'ls:cd:exit:history'`) |
| `HISTTIMEFORMAT` | unset | unset | strftime format for `history` output |
| `HISTFILE` | unset (→ `~/.bash_history`) | `~/.bash_history` | File path |

### `shopt`s (this repo)

| Option | Effect |
|---|---|
| `histappend` | Append to `$HISTFILE` on exit instead of overwriting (essential for multi-session hosts) |
| `cmdhist` | Save multi-line commands as one history entry |
| `lithist` | (NOT set) — would save multi-line commands with embedded newlines instead of semicolons |
| `histverify` | (NOT set) — would require Enter twice on `!!` / `!N` expansions before running |

### Why your bash history feels lossy across sessions

Default bash only writes to disk **on shell exit**. If you have three tmux
panes, exit one cleanly, and the second pane crashes, the second's history
is lost. Two fixes (this repo uses neither — see ble.sh section below):

```bash
# Flush after every prompt
PROMPT_COMMAND='history -a'

# Sync in both directions every prompt (multi-pane "shared" feel like zsh's share_history)
PROMPT_COMMAND='history -a; history -c; history -r'
```

The full-sync version is intrusive (up-arrow becomes a global timeline
across panes, not your local one). On this repo we let ble.sh own the sync
behaviour instead.

## Zsh history

### Storage

- **File**: `$HISTFILE`, defaults to `~/.zsh_history`. Mode `0600` on first
  write.
- **Format**: with `setopt extended_history` (OMZ default) each entry is
  `: <unix-ts>:<elapsed>;<command>`. The leading `: ` is intentional — it's
  a no-op POSIX command that makes the file safely re-sourceable.
- **In-memory ring**: `$HISTSIZE` entries.
- **Disk file cap**: `$SAVEHIST` entries. With `setopt hist_expire_dups_first`
  (OMZ default), duplicates are evicted first when the cap is hit.
- **Sharing across sessions**: `setopt share_history` (OMZ default) makes
  every command appended to `$HISTFILE` immediately AND re-read into all
  other live zsh sessions on their next prompt. This is why up-arrow in pane
  B sees commands you just typed in pane A.

### This repo sets ZERO custom zsh history options

Surprising but true: `dot_zshrc.tmpl` and `dot_config/zsh/**/*.zsh` contain
no `HISTSIZE` / `SAVEHIST` / `HISTFILE` / `setopt hist_*` lines. Everything
comes from oh-my-zsh's [`lib/history.zsh`](https://github.com/ohmyzsh/ohmyzsh/blob/master/lib/history.zsh)
which loads automatically as part of `source $ZSH/oh-my-zsh.sh`.

OMZ's defaults (verbatim, as of 2026):

```zsh
[ -z "$HISTFILE" ] && HISTFILE="$HOME/.zsh_history"
[ "$HISTSIZE" -lt 50000 ] && HISTSIZE=50000
[ "$SAVEHIST" -lt 10000 ] && SAVEHIST=10000

setopt extended_history       # record timestamp of command in HISTFILE
setopt hist_expire_dups_first # delete duplicates first when HISTFILE size exceeds HISTSIZE
setopt hist_ignore_dups       # ignore duplicated commands history list
setopt hist_ignore_space      # ignore commands that start with space
setopt hist_verify            # show command with history expansion to user before running it
setopt share_history          # share command history data
```

Note the `[ … -lt … ]` guards: if you `export HISTSIZE=200000` in
`dot_config/shell/00_exports.sh.tmpl` (commented out today, line 149), OMZ
**won't shrink it**. Increase-only.

### To override OMZ defaults

Set the var **before** `source $ZSH/oh-my-zsh.sh` (line 62 of
`dot_zshrc.tmpl`). The shared `dot_config/shell/00_exports.sh.tmpl` is
sourced at line 21, well before OMZ — three commented examples are
already there:

```bash
# export HISTSIZE=10000
# export SAVEHIST=10000
# export HISTFILE="$XDG_DATA_HOME/zsh/history"
```

Setting `HISTFILE` to an XDG path requires creating the parent directory
yourself; zsh refuses to create missing intermediate dirs and silently
falls back to in-memory-only history if the path is unwritable. **No error
message** — you just notice up-arrow stops remembering anything across
sessions. Add the `mkdir -p "${HISTFILE%/*}"` line right next to the export.

### `omz_history` wrapper

OMZ aliases `history` to a wrapper that takes `-c` (clear, with confirmation
prompt) and timestamp-format flags driven by `$HIST_STAMPS`. Plain `fc -l`
still works and bypasses the wrapper.

## ble.sh and bash-preexec interaction

On bash this repo loads `ble.sh` (see [bash.md](bash.md) → init order). ble.sh
**takes ownership of the history sync** when it attaches:

- `ble-attach` reads `$HISTFILE` into ble.sh's own ring on attach.
- Each accepted command is appended to `$HISTFILE` immediately (no waiting
  for shell exit, no need for the `PROMPT_COMMAND` flush trick).
- ble.sh **owns the up-arrow keymap** for in-line history navigation. This
  is why atuin must be initialised with `--disable-up-arrow` on bash; see
  the `15_atuin.sh` invariant in [AGENTS.md](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md)
  → "Keyboard shortcuts (cross-tool conflict check)".
- `bash-preexec` (which ble.sh provides natively) is what lets atuin's
  `__atuin_history` widget capture the command for its SQLite store.

Practical consequence: on bash with ble.sh, history feels *almost* as live
as zsh's `share_history`, but it's not bidirectional by default — pane B
sees pane A's commands only after the next ble.sh history reload (e.g. on
`Ctrl+R` invocation, or after `history -n`).

## Multi-user audit on a server

> **Scope note**: this section covers the *practical sysadmin tier* — what a
> root user can see by reading shell history files and standard system logs.
> For compliance-grade auditing (every exec'd binary, every syscall, tamper
> detection) the answer is `auditd` — see the brief pointer at the end.

### What root can see directly

```bash
# All shell history files on the box
sudo ls -la /home/*/.{bash,zsh}_history /root/.{bash,zsh}_history 2>/dev/null

# Read one
sudo cat /home/alice/.zsh_history

# With timestamps decoded (zsh extended_history format)
sudo awk -F';' '/^: / { ts=substr($1,3,10); cmd=substr($0, index($0,";")+1); print strftime("%F %T", ts), cmd }' /home/alice/.zsh_history
```

### Why this is incomplete

Reading the file is **lossy**:

| Source of loss | Mechanism |
|---|---|
| Space-prefix evasion | Bash with `HISTCONTROL=ignorespace` (this repo's default) and zsh with `setopt hist_ignore_space` (OMZ default) drop any line starting with a space. `<space>curl https://example.com -H "Authorization: Bearer $TOKEN"` never hits the file. |
| Manual deletion | `history -d 42` (bash) or `fc -p; fc -P` shenanigans (zsh) — interactive removal of an entry from the in-memory ring. The user can then `history -w` to overwrite the file. |
| File truncation | `> ~/.bash_history` or `: > ~/.zsh_history` then exit. Or `unset HISTFILE` before the suspicious commands and the session never writes. |
| Shell choice | If the user runs `dash` / `fish` / `nu` / `xonsh` instead of bash/zsh, neither file gets touched. |
| atuin import | `atuin search` is a parallel store. A user might `atuin search --delete` from atuin without touching `~/.zsh_history` (or vice versa). See [How atuin changes the picture](#how-atuin-changes-the-picture) below. |
| Buffered write | Bash without `histappend` + a flush only writes on clean exit. `kill -9` the shell → in-memory history is gone, file unchanged. |

### Sudo logging (the actually-reliable layer)

Anything run via `sudo` is logged regardless of the user's shell history
config:

```bash
# Debian/Ubuntu — auth.log
sudo grep sudo /var/log/auth.log

# RHEL/CentOS/Rocky — secure log
sudo grep sudo /var/log/secure

# systemd-based (any modern distro) — journal
sudo journalctl -t sudo --since "1 hour ago"
sudo journalctl _COMM=sudo --since today

# Filter by user
sudo journalctl _COMM=sudo --grep 'USER=alice'
```

A sudo line looks like:

```
May 08 14:30:00 host sudo: alice : TTY=pts/3 ; PWD=/home/alice ; USER=root ; COMMAND=/bin/cat /etc/shadow
```

For session **replay** (full keystroke recording, including stdout) enable
`sudoreplay` by adding `Defaults log_input,log_output` to `/etc/sudoers.d/`.
Then:

```bash
sudo sudoreplay -l                  # list recorded sessions
sudo sudoreplay <session-id>         # replay in real time
```

Note: this records sudo'd commands only, not the user's plain shell.

### Account-level: who logged in, when, what they ran

```bash
# Login/logout history (from /var/log/wtmp)
last
last alice
last -F                              # full timestamps
last -i                              # IPs instead of hostnames

# Failed logins (from /var/log/btmp)
sudo lastb

# Currently logged in
who
w                                    # plus what they're running right now
```

For per-process accounting (every exec, by every user) install `acct`
(Debian/Ubuntu) or `psacct` (RHEL):

```bash
sudo apt install acct                # or: sudo dnf install psacct
sudo systemctl enable --now acct     # or: psacct

# Then:
sudo lastcomm alice                  # every command alice ran
sudo lastcomm --user alice --strict-match
sudo sa                              # summary by command
sudo ac alice                        # connect-time totals
```

`lastcomm` records the **process name only** (16 chars, no args, no cwd),
but it's tamper-resistant from the user's side because the kernel writes
`/var/log/account/pacct` directly. Useful for "did alice run `nmap` this
week?" — useless for "what did alice's `nmap` invocation actually scan?".

### When you need the real answer: auditd

For exec syscall arguments, file access, network connections, and
tamper-evident logs, the answer is the Linux audit framework:

```bash
sudo apt install auditd
sudo auditctl -a always,exit -F arch=b64 -S execve -k user_cmd
sudo ausearch -k user_cmd -ts today
sudo aureport --executable --summary
```

Out of scope for this doc — it's a security-tooling rabbit hole. Pointer
only. See `man auditctl` and the [Red Hat auditd guide](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/security_hardening/auditing-the-system_security-hardening).

## Clearing your own history

> **Threat model**: this section is about hiding accidental secret pastes
> from your *own* shell history file (defence against `cat ~/.bash_history`
> by you tomorrow, or by a well-meaning teammate who got root). It is **not**
> a defence against an adversary with sudo or kernel access — see
> [Sudo logging](#sudo-logging-the-actually-reliable-layer) and
> [auditd](#when-you-need-the-real-answer-auditd) above for why.

### One-shot: don't record this command at all

```bash
 export TOKEN=ghp_xxxxx                   # ← leading space, dropped by ignorespace
```

Both bash (`HISTCONTROL=ignoreboth`) and zsh (`setopt hist_ignore_space`,
OMZ default) honour this. Verify before relying on it:

```bash
echo "$HISTCONTROL"                       # bash: should contain ignorespace or ignoreboth
setopt | grep histignorespace             # zsh: should be 'on' (no 'no' prefix)
```

### Delete a specific entry from the current session

```bash
# bash
history                                   # find the line number, e.g. 142
history -d 142
history -w                                # flush in-memory ring to $HISTFILE

# zsh
fc -l -100                                # find the offset
# Then either restart the shell after editing $HISTFILE, OR:
LC_ALL=C sed -i.bak '/secret-pattern/d' "$HISTFILE"
fc -p "$HISTFILE"                         # re-read into the current session
```

zsh has no built-in `history -d N` equivalent — `fc` only edits in-memory,
and on `share_history` the entry is already on disk by the time you notice.
Edit the file, then `fc -p`.

### Nuke the whole history (current user)

```bash
# bash
history -c                                # clear in-memory ring
history -w                                # write empty ring to file
# OR just truncate:
: > ~/.bash_history

# zsh — OMZ provides a confirmation-gated wrapper
history -c                                # asks "Are you sure? [y/N]"
# OR raw:
: > "$HISTFILE"
fc -p "$HISTFILE"                         # re-attach the now-empty file
```

### Don't forget atuin

If atuin is installed (it is on this repo, see [tools/atuin.md](../tools/atuin.md)),
the steps above only clear the bash/zsh native file. Atuin's SQLite store
captured the same commands separately:

```bash
# Search and selectively delete
atuin search 'secret-pattern' --delete

# Or wipe everything (irreversible)
atuin search --before '1 day ago' --delete   # before some cutoff
# There is no `atuin wipe` — to truly nuke:
rm -rf ~/.local/share/atuin/history.db
atuin init zsh                                # re-init empty store
```

If you have `atuin login` configured (sync to a server), `atuin search
--delete` propagates the deletion to the server on the next `atuin sync`.
File-level wipes do NOT — the server still has the row. Use
`atuin account delete` if you need to scrub server-side, or run your own
self-hosted `atuin server` where you control the database.

### What still leaks

After all of the above, a determined inspector with sudo can still recover:

- Your `sudo` invocations (auth.log / journalctl / sudoreplay).
- Any process that ran long enough to be in `ps`/`top` snapshots.
- `acct`/`psacct` per-process records if enabled.
- auditd execve records if enabled.
- The terminal scrollback if you didn't `clear` and `reset`.
- tmux scrollback in `~/.tmux/resurrect/` if `tmux-resurrect` is installed.
- Editor swap files (`.swp`, `~`, `.~lock.*`) if you opened the file with
  the secret in it.
- Your shell's **operations log** if `sh -x` / `set -x` was active and
  redirected.

Threat model first; clear-history theatre second.

## How atuin changes the picture

[atuin](https://atuin.sh/) ([upstream](https://github.com/atuinsh/atuin))
is a parallel SQLite-backed history store with optional end-to-end-encrypted
sync. It does **not** replace `~/.{bash,zsh}_history` — it shadows it. Both
files keep growing.

| Aspect | Native bash/zsh history | atuin |
|---|---|---|
| Storage | Plain text (`~/.{bash,zsh}_history`) | SQLite (`~/.local/share/atuin/history.db`) |
| Per-command metadata | Bash: nothing. Zsh `extended_history`: timestamp + duration | Timestamp, duration, exit code, cwd, hostname, session id |
| Search | `Ctrl+R` linear `grep`-ish (or fzf-tab in this repo) | Fuzzy + filter by cwd / session / host / exit-status / time range |
| Sharing across hosts | Manual (`scp ~/.zsh_history`) | `atuin login` + `atuin sync` (E2E-encrypted, server can't read) |
| Default row cap | bash `$HISTFILESIZE=20000`, zsh `$SAVEHIST=10000` | **No cap.** SQLite grows forever (~100 bytes/row, so ~1MB / 10k rows). |
| Retention env vars | `HISTSIZE` / `HISTFILESIZE` / `SAVEHIST` / `HISTIGNORE` / `HISTCONTROL` | `~/.config/atuin/config.toml`: `history_filter` (regex array) is the closest equivalent — drops matching commands at *capture* time |
| Clearing | Edit/truncate the file | `atuin search ... --delete`, propagates via sync |
| Encryption at rest | None | None by default (the SQLite db is plaintext on disk; only the *sync wire* is E2E encrypted with the user's key) |

### atuin's "max rows" story

There isn't one. The closest knobs:

- `history_filter = ['^secret', '^export TOKEN']` — array of regexes; matches
  are silently dropped at capture time (like a stronger `HISTIGNORE`).
- `cwd_filter = ['^/tmp']` — drop commands run in matching directories.
- `inline_height = 0` and pager settings — UI only, don't affect storage.
- `sync.records_size_limit` — server-side per-record cap (default 1 MiB), not
  a row-count cap.

If you need a real cap, run a cron / systemd timer:

```bash
# Keep only last 90 days
sqlite3 ~/.local/share/atuin/history.db \
  "DELETE FROM history WHERE timestamp < strftime('%s', 'now', '-90 days') * 1000000000;"
atuin sync                                # propagate the deletes
```

This is intentional on atuin's side — the design assumes "your history is
small and you want all of it forever, fuzzy-searchable". Different
philosophy from bash's "ring buffer that forgets".

For setup, keybindings, and the bash↔zsh asymmetry on this repo, see
**[tools/atuin.md](../tools/atuin.md)**.

## Related docs

- [tools/atuin.md](../tools/atuin.md) — atuin setup, keybindings, sync,
  bash↔zsh asymmetry on this repo.
- [shells/bash.md](bash.md) — bash init order, ble.sh attach point.
- [shells/keybindings.md](keybindings.md) — `Ctrl+R` / `Alt+R` / atuin
  bindings on each shell.
- [shells/aliases.md](aliases.md) — sourced files registry.
- [`dot_config/bash/02_history.bash`](../../dot_config/bash/02_history.bash) —
  the only file in this repo that sets shell-history env vars.
- Upstream:
  [bash `HISTORY` man page section](https://www.gnu.org/software/bash/manual/html_node/Bash-History-Facilities.html),
  [zsh history options](https://zsh.sourceforge.io/Doc/Release/Options.html#History),
  [oh-my-zsh `lib/history.zsh`](https://github.com/ohmyzsh/ohmyzsh/blob/master/lib/history.zsh),
  [atuin docs](https://docs.atuin.sh/), [atuin GitHub](https://github.com/atuinsh/atuin).

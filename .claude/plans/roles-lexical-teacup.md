# Plan: ASCII Banner Tools + SSH-Aware MOTD

## Context

User wants to install the figlet family of ASCII-banner CLI tools (`figlet`, `toilet`, `lolcat`) and configure a `~/.zlogin` MOTD that prints a big hostname banner — primarily so SSH'ing across the fleet of machines (managed via `fleet-apply`) makes "which box am I on?" obvious.

The discussion already established three things:
- Tools are tiny (<1MB total), universally packaged on apt + brew, no GitHub-release fallback needed.
- MOTD's real benefit is **SSH-only fleet identification**; local terminals don't need it.
- `clean.py` ansible callback and chezmoi `run_*` scripts are explicitly **out of scope** — they already have well-tuned output.

The user asked whether a chezmoi init prompt is needed. **Decision: not needed** (justified below).

## Scope

**In:**
1. Install `figlet`, `toilet`, `lolcat` via `devtools` ansible role (macOS Homebrew + Linux apt).
2. Create `dot_zlogin.tmpl` — SSH+TTY-gated banner with chezmoi-baked profile metadata.
3. Light README mention; optional `docs/zsh/motd.md` page.

**Out:**
- `cowsay`, `boxes`, `fortune`, `fastfetch`, `neofetch` — keep scope tight.
- chezmoi init prompt — runtime gating already covers all needed cases.
- `clean.py`, run-scripts, Brewfile.
- bash equivalent — repo is zsh-first.

## Files to modify / create

| Path | Action |
|---|---|
| `dot_ansible/roles/devtools/tasks/main.yml` | modify — append 3 names to macOS list (line 55), add new apt task block at end of file, update tools comment on line 3 |
| `dot_zlogin.tmpl` | **create** new file at repo root |
| `README.md` | small touch — add 3 names + 1-paragraph "SSH MOTD" note |
| `docs/zsh/motd.md` + `mkdocs.yml` nav | optional but recommended — 1-page doc explaining trigger conditions and opt-out |

NOT touched: `.chezmoi.toml.tmpl`, `Dockerfile`, `scripts/init/dotfiles_init.py`, Brewfile, `clean.py`, any run-script.

## Implementation

### 1. `dot_ansible/roles/devtools/tasks/main.yml`

**1a. Append to macOS Homebrew list** — between line 55 (`- witr`) and line 56 (`state: present`):

```yaml
      - witr
      - figlet
      - toilet
      - lolcat
    state: present
```

**1b. Append new task block at the end of the file** (mirrors the `bats` apt pattern at lines 440-446 — simplest case, no user-level fallback needed since tools are not on critical path; `noRoot` hosts skip via `tags: [sudo]`):

```yaml
# =============================================================================
# Banner / MOTD CLI tools (figlet, toilet, lolcat)
# =============================================================================
# All three live in Ubuntu/Debian universe; no GitHub-release fallback needed.
# Used by the SSH-gated ~/.zlogin banner (see dot_zlogin.tmpl).
- name: Install banner CLI tools (Debian/Ubuntu)
  when: ansible_facts["os_family"] == "Debian"
  become: true
  tags: [sudo]
  ansible.builtin.apt:
    name:
      - figlet
      - toilet
      - lolcat
    state: present
```

**1c. Update tool list comment** on line 3 — append `, figlet, toilet, lolcat` to the end of the existing comma-separated list.

### 2. `dot_zlogin.tmpl` (new file, repo root)

```sh
# ~/.zlogin - login-shell hooks (managed by chezmoi)
# Prints an SSH-only MOTD banner. Local terminals get nothing.

# Gate 1: only on SSH login
[ -n "$SSH_CONNECTION" ] || return 0

# Gate 2: only if stdout is a TTY (filters `ssh host 'cmd'` and scp/rsync)
[ -t 1 ] || return 0

# Gate 3: don't repaint inside tmux (only the original SSH login shell prints)
[ -z "$TMUX" ] || return 0

# Gate 4: respect runtime opt-out from ~/.zshrc.adhoc
[ "${MOTD_DISABLE:-0}" = "1" ] && return 0

_motd_host="$(hostname -s 2>/dev/null || hostname)"
_motd_cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"

# Cyan banner. No lolcat dep at runtime — lolcat stays a user utility.
printf '\033[36m'
if command -v figlet >/dev/null 2>&1; then
    figlet -w "$_motd_cols" -f small -- "$_motd_host" 2>/dev/null \
        || figlet -w "$_motd_cols" -- "$_motd_host" 2>/dev/null \
        || printf '== %s ==\n' "$_motd_host"
else
    # Fallback for first-boot before ansible has installed figlet
    printf '== %s ==\n' "$_motd_host"
fi
printf '\033[0m'

# Metadata line — profile baked at chezmoi-apply time (zero runtime cost)
_motd_profile='{{ .profile }}'
_motd_os="$(uname -sr)"
_motd_up="$(uptime 2>/dev/null | sed -E 's/.*up *([^,]+),.*/\1/' | xargs)"
_motd_ip="$(echo "$SSH_CONNECTION" | awk '{print $3}')"  # server-side IP

printf '\033[2m'
printf 'profile=%s  os=%s  up=%s  via=%s\n' \
    "$_motd_profile" "$_motd_os" "${_motd_up:-?}" "${_motd_ip:-?}"
printf '\033[0m\n'

unset _motd_host _motd_cols _motd_profile _motd_os _motd_up _motd_ip
```

**Why each gate:**
- `SSH_CONNECTION` — the core trigger. Empty on console/local terminals.
- `[ -t 1 ]` — non-interactive SSH (e.g., `ssh host 'echo'`, scp, rsync, fleet-apply itself) returns false → silent. Also note: zsh `-c` non-interactive doesn't run `.zlogin` anyway, so this is belt-and-suspenders.
- `[ -z "$TMUX" ]` — handles the rare config where tmux spawns login shells; banner stays a once-per-SSH-session event.
- `MOTD_DISABLE=1` — taste-based opt-out via `~/.zshrc.adhoc` (auto-created by `dot_zshrc.tmpl` line 104-122; perfect home for personal toggles).

### 3. README.md — light touch

Append `figlet`, `toilet`, `lolcat` to the devtools tool list. Add one paragraph (location: near existing zsh/shell discussion):

> **SSH login banner**: a `~/.zlogin` hook prints `figlet $(hostname -s)` plus profile/OS/uptime/IP when you SSH into a host. Local terminals are silent. Set `MOTD_DISABLE=1` in `~/.zshrc.adhoc` to suppress.

### 4. `docs/zsh/motd.md` (recommended) + `mkdocs.yml` nav entry under "Zsh"

1-page doc covering: what triggers it, the 4 gates, opt-out, customization (`hostname -s` vs `-f`, picking a different figlet font), behavior before figlet is installed. Add nav entry alphabetically under existing `Zsh` section. Run `uv run mkdocs build --strict` to verify.

## Decision: no chezmoi init prompt

**Reasoning:**

1. **Tool size is trivial** — figlet+toilet+lolcat ≈ <1MB. The repo's `.chezmoi.toml.tmpl` already has 21 prompts; adding one for sub-MB tooling is gold-plating.
2. **MOTD self-gates at runtime** — only fires on SSH+TTY+non-tmux. Users who never SSH never see it; nothing to opt out of at install time.
3. **Runtime opt-out exists** — `MOTD_DISABLE=1` in `~/.zshrc.adhoc` covers "I SSH but hate banners" without polluting init UX.
4. **Consistency** — `bat`, `eza`, `glow`, `gum` etc. all install unconditionally via `devtools`. Banner tools belong in the same default-on bucket.
5. **No new profile values** — stays within `macos` / `ubuntu_desktop` / `ubuntu_server`.

If the user later wants the prompt, the 3-file mechanical change is clear: add `installBannerTools` (key) / `CHEZMOI_INSTALL_BANNER_TOOLS` (ARG) / `Prompt(...)` entry, and wrap the new ansible task in `when: installBannerTools | default(true)`. Easy to bolt on later.

## Verification

```bash
# Inspect the chezmoi diff before applying
chezmoi diff ~/.zlogin

# Apply the new dotfile
chezmoi apply ~/.zlogin

# Run the ansible devtools role to install the tools
cd ~/.local/share/chezmoi/dot_ansible
ansible-playbook --tags devtools site.yml --check --diff   # dry run
ansible-playbook --tags devtools site.yml                  # actual

# Manual test: local terminal → no banner
zsh -l -c 'true'   # silent

# SSH self-test → banner prints
ssh localhost      # exit immediately

# Non-interactive SSH → silent
ssh localhost 'echo ok'

# Inside tmux on a remote → silent on new panes
ssh localhost
# (banner prints once)
tmux new -s test
# (no banner in tmux pane)

# Opt-out test
MOTD_DISABLE=1 ssh localhost   # banner suppressed

# If docs page added — mkdocs strict build
cd ~/.local/share/chezmoi && uv run mkdocs build --strict
```

## Edge cases (all handled by the design)

| Edge case | Handling |
|---|---|
| First boot, figlet not yet installed | `command -v figlet` check → `printf '== %s =='` plain fallback |
| Long hostname overflowing terminal | `figlet -w "$_motd_cols"` honors current width |
| Non-interactive SSH (`ssh h 'cmd'`, scp, rsync, fleet-apply) | `[ -t 1 ]` → return 0, also `.zlogin` not sourced for `zsh -c` |
| tmux pane re-spawn | `[ -z "$TMUX" ]` → return 0 |
| Console/local TTY | `$SSH_CONNECTION` empty → return 0 |
| `noRoot` Linux host | `tags: [sudo]` task skipped, fallback `==hostname==` triggers |
| User wants no banner ever | `export MOTD_DISABLE=1` in `~/.zshrc.adhoc` |
| `hostname -s` unsupported | Fallback to plain `hostname` |
| Dumb terminal (no ANSI) | `[ -t 1 ]` filters most; ANSI escapes harmless on rest |

## Non-goals (explicit)

- NOT modifying `dot_ansible/callback_plugins/clean.py`.
- NOT adding banners to chezmoi `run_*` scripts.
- NOT installing `cowsay`/`boxes`/`fortune`/`fastfetch`/`neofetch`.
- NOT using `lolcat` inside the MOTD (kept as a user-facing utility only).
- NOT adding a chezmoi init prompt.
- NOT adding a bash `~/.bash_profile` equivalent.
- NOT printing the banner on local (non-SSH) shells.

## Critical files

- `/Users/daviddwlee84/.local/share/chezmoi/dot_ansible/roles/devtools/tasks/main.yml` (modify lines 3, 55-56, append at end)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_zlogin.tmpl` (NEW)
- `/Users/daviddwlee84/.local/share/chezmoi/README.md` (small mention)
- `/Users/daviddwlee84/.local/share/chezmoi/dot_zshrc.tmpl` (reference only — line 104-122 confirms `.zshrc.adhoc` is auto-created, perfect home for `MOTD_DISABLE=1`)
- `/Users/daviddwlee84/.local/share/chezmoi/.chezmoi.toml.tmpl` (reference only — `.profile` consumed by template)
- Optional: `/Users/daviddwlee84/.local/share/chezmoi/docs/zsh/motd.md` + `mkdocs.yml` nav

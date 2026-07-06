# chezmoi Source-State Prefixes

A practical reference for the filename prefixes (`dot_`, `private_`, `create_`, `modify_`, …) that chezmoi uses to encode target metadata in the source directory, with an opinionated "is it safe to `chezmoi add`?" decision table and a playbook tailored to this repo.

## Canonical references

- [Source state attributes](https://www.chezmoi.io/reference/source-state-attributes/) — full list of prefixes and suffixes, plus the allowed ordering per target type. This is the source of truth; skim it once and bookmark it.
- [Manage different types of file](https://www.chezmoi.io/user-guide/manage-different-types-of-file/) — practical recipes, including [Manage part, but not all, of a file](https://www.chezmoi.io/user-guide/manage-different-types-of-file/#manage-part-but-not-all-of-a-file) (the `modify_` pattern) and create-only seeding.
- [`chezmoi chattr`](https://www.chezmoi.io/reference/commands/chattr/) — toggle prefixes without manually renaming files (e.g. `chezmoi chattr +create,+private ~/.ssh/config`).

## `chezmoi add` safety decision table

When the live file diverges from the source and you want to resync, the first question is "which bucket does this prefix fall into?". **The prefix changes the semantics of `chezmoi add` / `re-add`** — the command is not a dumb copy.

| Bucket | Prefixes | What `chezmoi add <target>` does | Action |
|---|---|---|---|
| Green-light | `dot_`, `private_`, `executable_`, `readonly_`, `empty_` | Rewrites the source file with the live contents. Prefixes are preserved. | Use freely. |
| Add-safe but re-check semantics | `create_`, `exact_`, `literal_` | Works, but can **silently change the semantic contract** (see notes below). | Use, then `git diff` the source filename to confirm the prefix is still what you expect. |
| Do NOT treat as a normal tracked file | `modify_`, `encrypted_`, `remove_`, `symlink_`, scripts (`run_*`) | `chezmoi add` would strip the prefix or overwrite the script body with live data. | Edit the source file directly, or use `cp "$(chezmoi source-path <target>)"` / `chezmoi edit`. |

Notes on the middle bucket:

- `create_`: `chezmoi add` **strips** the `create_` prefix, silently promoting a seed-only file to a fully managed one. `chezmoi re-add` is a no-op for `create_` (by design — contents are not managed after initial create).
- `exact_` (dir-only): adding a file inside an `exact_` directory is fine, but remember the directory will prune anything not present in source on next apply.
- `literal_`: the whole point is to suppress attribute parsing. Adding a new file with the same base name re-parses the prefix — you may need to rename manually.

## Per-prefix reference

Each entry links to the relevant row in [Source state attributes](https://www.chezmoi.io/reference/source-state-attributes/).

### `dot_` — leading dot rename

- **Effect**: `dot_foo` in source becomes `.foo` in target. Purely a name mapping so dotfiles stay visible in `git ls-files`.
- **`chezmoi add`**: green-light.
- **Typical use**: `dot_zshrc`, `dot_gitconfig`, `dot_config/…`, `dot_ssh/…`.

### `private_` — tighten file mode to 0600 (dir: 0700)

- **Effect**: Removes group/world permissions on the target. Enforced on every `chezmoi apply`.
- **`chezmoi add`**: green-light. `chezmoi add` of a file that already has 0600 mode automatically encodes `private_` for you.
- **Risk**: This is only a permission bit — it does **not** encrypt the file. Committing a `private_` file with secrets still commits them in plaintext. For secrets, reach for `encrypted_` or a password-manager template function.
- **Typical use**: `private_dot_ssh/config`, `private_dot_netrc`, Claude Code config files that contain account hints.

### `executable_` — add +x bit

- **Effect**: Ensures the target has the executable bit on every apply.
- **`chezmoi add`**: green-light. Auto-detected when adding a file that already has +x.
- **Typical use**: personal scripts under `~/.dotfiles/bin/` (chezmoi-managed; see `dot_dotfiles/bin/executable_x`, `dot_dotfiles/bin/executable_sms`), helper wrappers, `~/.local/share/tmux-*` shims.

### `readonly_` — drop all write bits

- **Effect**: Strips write permissions from the target. Runs on every apply, so the file will be reset to read-only even if you `chmod +w` it.
- **`chezmoi add`**: green-light, but note that re-adding can be annoying because you must `chmod +w` locally first.
- **Typical use**: frozen baselines you do not want to edit by mistake. Rarely useful in a personal dotfiles repo.

### `create_` — seed once, then leave alone

- **Effect**: Writes the file **only if the target does not already exist**. After that, chezmoi never touches the contents again.
- **`chezmoi add`**: use with care — `chezmoi add` **strips** the `create_` prefix, which silently promotes the file to a regular managed file (losing the seed-only contract).
- **`chezmoi re-add`**: intentionally **skips** `create_` files.
- **Refresh recipe**: to update the baseline, copy the live file into the source path (preserves the prefix):

  ```bash
  cp ~/.config/nvim/lazy-lock.json "$(chezmoi source-path ~/.config/nvim/lazy-lock.json)"
  ```

- **Typical use**: LazyVim `lazy-lock.json` (see the [case study below](#dot_confignvimcreate_lazy-lockjson--seed-once-never-overwrite)), SSH `config` skeleton, first-run app baselines.

### `modify_` — content is a script, not a file

- **Effect**: The source file is an executable **script**. chezmoi pipes the current target contents into stdin; the script writes the new target contents to stdout. Lets you manage part of a file (e.g. via `jq`, `sed`, `awk`) while leaving the rest alone.
- **`chezmoi add`**: do **not** `chezmoi add` a `modify_` target — it would overwrite your script with the live file contents.
- **Alternative form**: put `chezmoi:modify-template` in the script body to switch it into template mode (the current contents arrive as `.chezmoi.stdin`). See [Manage part, but not all, of a file](https://www.chezmoi.io/user-guide/manage-different-types-of-file/#manage-part-but-not-all-of-a-file).
- **Typical use**: Claude Code `settings.json` (see the [case study below](#dot_claudemodify_settingsjson--partial-json-management-via-jq)), Docker `config.json` proxies, INI files with a mix of managed and runtime-written keys.

#### Bootstrap-order contract: `modify_` scripts MUST tolerate missing tools

`chezmoi apply` runs in three phases, in order:

1. `run_once_before_*` scripts → `run_once_before_00_bootstrap.sh.tmpl` installs **uv, mise, ansible-core**, plus Linuxbrew (rooted Linux) or Homebrew (macOS). It assumes `curl`, `git`, `bash`/`sh`, and basic POSIX are already on the box.
2. **File-application phase** — every `modify_*` script runs here.
3. `run_onchange_after_*` scripts → `20_ansible_roles.sh.tmpl` runs the `base` ansible role, which installs **`jq`, `ripgrep`, `fd`, `python3`, `git-lfs`, `just`, `tree`, …**.

So at the time a `modify_*` script executes, **only the bootstrap-set is guaranteed**. Anything from the ansible-set (`jq`, `python3`, `ripgrep`, `fd`, …) may not yet be installed on a fresh box. A bare `set -eu` script that hard-calls one of those tools will exit non-zero, and chezmoi will abort the entire apply — meaning the ansible role that *would have* installed the tool never runs, and the user is stuck.

**Rule**: any `modify_*` script that invokes a tool from the post-bootstrap set MUST `command -v`-guard it and pass-through the live content if missing. The pass-through preserves the live file unchanged (chezmoi sees `stdout == stdin` → no-op for that target → apply continues), and the next `chezmoi apply` (after ansible has installed the missing tool) does the real work.

Canonical guard, lifted from [`run_onchange_after_40_install_global_skills.sh.tmpl:32-35`](../../.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl):

```sh
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "modify_<file>: jq not found; passing live file through unchanged. Re-run \`chezmoi apply\` after the base ansible role installs jq." >&2
  printf '%s' "$base"
  exit 0
fi
```

For scripts needing a python3 (e.g. JSONC handling for VSCode/Cursor/Antigravity overlays), prefer the uv→system-python3 fallback chain — `uv` is bootstrap-guaranteed, so it's the cheap insurance against minimal Linux servers without `python3` pre-installed. See [`dot_codex/modify_config.toml.tmpl:47-55`](../../dot_codex/modify_config.toml.tmpl) and [`.chezmoitemplates/editor/modify.sh:48-66`](../../.chezmoitemplates/editor/modify.sh) for the pattern.

Reference implementations (good citizens worth copying):

- [`dot_codex/modify_config.toml.tmpl:47-55`](../../dot_codex/modify_config.toml.tmpl) — `uv` → `python3` → pass-through
- [`dot_config/docker/modify_daemon.json.tmpl:28-31`](../../dot_config/docker/modify_daemon.json.tmpl) — minimal `jq` guard
- [`dot_docker/modify_config.json.tmpl:19-21`](../../dot_docker/modify_config.json.tmpl) — minimal `jq` guard

Failure mode if the rule is forgotten: see [`pitfalls/modify-script-jq-bootstrap-cycle.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/modify-script-jq-bootstrap-cycle.md) — `chezmoi update --init` aborts with `jq: command not found` after `[SUCCESS] Bootstrap complete!` and the user is stuck in a cycle (apply fails before phase 3 → ansible never runs → `jq` never installs → next apply fails the same way).

### `exact_` — directory is canonical (prune extras)

- **Effect**: On apply, chezmoi **removes** any file inside the target directory that is not present in source. Directory-only prefix.
- **`chezmoi add`**: safe for individual files inside the directory, but be aware of the semantic trap — next apply will clean up anything that drifted in.
- **Risk**: Very easy to accidentally delete machine-local artifacts (caches, plugin installs) that happen to live inside the directory.
- **Typical use**: directories you truly own end-to-end and that are small / stable. Avoid for any directory that mixes managed config with runtime state.

### `literal_` — stop parsing attributes

- **Effect**: Tells chezmoi to stop interpreting the rest of the filename as attributes. Used when an actual filename starts with something like `create` or `run` and you want chezmoi to treat it literally.
- **`chezmoi add`**: green-light, but remember the prefix exists for a filename-level reason — blindly renaming it later can break the mapping.
- **Typical use**: uncommon. Corner cases like a literal `run_` or `dot_` in a filename.

### `remove_` — assert removal

- **Effect**: Declares that the target should be **absent**. On apply, chezmoi removes the file/symlink (or empty directory) if it exists. The source file's body is not a content source — it is a presence assertion.
- **`chezmoi add`**: does not apply (there is no live content to sync back).
- **Typical use**: cleaning up stale configs after migrating tools. Often combined with a template so it only fires on specific hosts.

### `encrypted_` — encrypt at rest

- **Effect**: The source file is stored encrypted (age or gpg, depending on `encryption` config). chezmoi decrypts on apply. The on-disk suffix is `.age` or `.asc` (stripped in the target).
- **`chezmoi add`**: supported (chezmoi re-encrypts), but this only makes sense if you have already committed to a secrets workflow (age keys, gpg setup).
- **Alternative**: use a template function (`onepassword`, `bitwarden`, `keyring`, `vault`, …) to fetch secrets at apply time instead of committing them encrypted.
- **Typical use**: small number of credential files you want to keep inside the repo history.

### `symlink_` — create a symlink, not a file

- **Effect**: Target is a symlink whose contents are the first line of the source file (often a template that expands to a path).
- **`chezmoi add`**: adding an existing symlink produces a `symlink_` source automatically.
- **Typical use**: point a dotfile at an externally-managed file (`~/.config/Code/User/settings.json` → `{{ .chezmoi.sourceDir }}/settings.json`, see the official recipe for handling externally-modified configs).

### `empty_` — allow empty files

- **Effect**: By default chezmoi removes zero-byte files; `empty_` says "this one is intentionally empty".
- **Typical use**: marker files, empty `.hushlogin`.

### `external_` — don't parse attributes of children

- **Effect**: Directory-only. Stops chezmoi from interpreting the attributes of files inside. Usually paired with `.chezmoiexternal.<format>` sources that deliver whole subtrees.
- **Typical use**: vendored plugin directories, `git-repo` externals.
- **Companion file**: `.chezmoiexternal.<format>` at the repo root (see [`.chezmoiexternal.toml.tmpl` in this repo](../../.chezmoiexternal.toml.tmpl) and the section below).

### Script family — `run_`, `once_`, `onchange_`, `before_`, `after_`

- **Effect**: Source file is a **script** that chezmoi executes at apply time. No target file is created. The modifiers compose:
  - `run_` — the base marker.
  - `once_` — run only once per script body (hash-keyed).
  - `onchange_` — run when the script body changes (filename-keyed; unlike `once_`, editing the script re-runs it).
  - `before_` / `after_` — run before / after applying target files.
- **`chezmoi add`**: does not apply — scripts have no file target.
- **Already in this repo**: `run_once_before_00_bootstrap.sh.tmpl`, `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`, `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl`. See [docs/this_repo/architecture.md → Auto-run scripts](../this_repo/architecture.md#auto-run-scripts).

## Allowed prefix ordering

When multiple prefixes apply, order matters. From [Source state attributes](https://www.chezmoi.io/reference/source-state-attributes/):

| Target type | Allowed prefixes (in order) | Allowed suffixes |
|---|---|---|
| Directory | `remove_`, `external_`, `exact_`, `private_`, `readonly_`, `dot_` | — |
| Regular file | `encrypted_`, `private_`, `readonly_`, `empty_`, `executable_`, `dot_` | `.tmpl` |
| Create file | `create_`, `encrypted_`, `private_`, `readonly_`, `empty_`, `executable_`, `dot_` | `.tmpl` |
| Modify file | `modify_`, `encrypted_`, `private_`, `readonly_`, `executable_`, `dot_` | `.tmpl` |
| Remove file | `remove_`, `dot_` | — |
| Script | `run_`, (`once_` or `onchange_`), (`before_` or `after_`) | `.tmpl` |
| Symlink | `symlink_`, `dot_` | `.tmpl` |

Worked examples:

- `private_executable_dot_ssh/private_readonly_id_ed25519` — directory is private, file is private+readonly. (In practice: don't check in private keys; shown for ordering only.)
- `create_private_dot_ssh/create_private_config` — create-once SSH config that is 0600 on creation.
- `modify_private_dot_claude/modify_settings.json` — the actual pattern used in this repo (see the [case study below](#dot_claudemodify_settingsjson--partial-json-management-via-jq)).

If you ever lose the stacking order, `chezmoi chattr` will normalize it for you:

```bash
chezmoi chattr +private,+readonly ~/.config/foo/bar
```

## Playbook: what to use where in this repo

### A. Everyday configs — `dot_` (+ `private_` if sensitive)

Track normally, `chezmoi add` freely, let `chezmoi re-add` pick up drift.

- `dot_zshrc`, `dot_gitconfig`, `dot_tmux.conf`, `dot_config/nvim/lua/*`, `dot_config/starship.toml`, `dot_config/tmux/*`, `dot_config/zsh/tools/*`, `dot_config/sesh/*`, `dot_config/zellij/*`, …
- Sensitive-ish (account hints, but not secrets): add `private_` (e.g. `private_dot_ssh/…`, `private_dot_claude/…`).

### B. Personal scripts — `executable_` (+ `dot_` where needed)

- `~/.dotfiles/bin/sms` → `dot_dotfiles/bin/executable_sms` in source.
- `~/.dotfiles/bin/x` → `dot_dotfiles/bin/executable_x` in source.
- Any helper shell script you want on PATH — drop it under `dot_dotfiles/bin/` with the `executable_` prefix.

### C. Seed-once baselines — `create_`

Files that an app rewrites in-place after first launch, and where you only care about the initial state.

- **`~/.config/nvim/lazy-lock.json`** → `create_lazy-lock.json`. See the [case study below](#dot_confignvimcreate_lazy-lockjson--seed-once-never-overwrite). Refresh baseline with `cp … "$(chezmoi source-path …)"`.
- **`~/.ssh/config`** → create-only template that `Include ~/.ssh/config.d/*` and ships conservative defaults. See the SSH notes in [README.md](../../README.md).
- First-run app JSONs where further changes are user-local (settings files that are a mix of state and preferences).

### D. Partial-content management — `modify_` via script

Files an app actively rewrites at runtime (adding keys, reordering, …), where you only want to enforce a subset of keys.

- **`~/.claude/settings.json`** → `dot_claude/modify_settings.json`, a `jq` script that deep-merges a managed overlay. See the [case study below](#dot_claudemodify_settingsjson--partial-json-management-via-jq).
- **`~/.docker/config.json`** → a modify-script that rewrites `proxies.default` while preserving `auths` / `credsStore`. See [docs/tools/containers.md](containers.md).
- **`~/.config/herdr/config.toml`** → `dot_config/herdr/modify_config.toml.tmpl` + managed body in `.chezmoitemplates/herdr/config.toml`, a tomlkit overlay that enforces the `[theme]`/`[ui]`/`[terminal]`/`[keys]` tables and pulls through everything herdr writes back at runtime (`onboarding`, `[session]`, `[remote]`, …). Was `create_` (seed-once), but that never propagated repo edits to already-seeded hosts. See [docs/tools/herdr.md → Config management](herdr.md#config-management-why-modify_).
- Rule of thumb: if an app owns the file and you only care about N keys, `modify_` beats a full managed template.

### E. Machine-local / runtime / cache — `.chezmoiignore`, not a prefix

Do **not** try to track these even with `create_`. They belong in `.chezmoiignore` or simply outside the source tree.

- Editor swap / shada / session files
- Plugin install artifacts (LazyVim plugin source, tmux TPM repos, …)
- Logs, caches, `lazy-install.log`, `.DS_Store`
- Per-host runtime state

### F. Secrets — prefer templating over `encrypted_`

Order of preference for secrets in this repo:

1. **Template function** that fetches at apply-time: `{{ bitwarden … }}`, `{{ onepassword … }}`, `{{ keyring … }}`, `{{ vault … }}`. Nothing secret hits git.
2. **`encrypted_`** with age or gpg, if you need the value in-repo (e.g. for an offline machine). Commit only after you have `encryption` set and a key workflow in place.
3. **Never** commit a plain `private_` file with a real token — `private_` is a permission bit, not encryption.

## Refresh / maintenance recipes

### `chezmoi re-add` vs `chezmoi add`

| Situation | Command |
|---|---|
| File already tracked, just pick up drift | `chezmoi re-add <target>` (preserves prefix, fails loudly on `modify_`, silently skips `create_`) |
| Adding a new file for the first time | `chezmoi add <target>` |
| Updating a `create_` baseline | `cp <target> "$(chezmoi source-path <target>)"` |
| Updating a `modify_` script | Edit the source script directly (`chezmoi edit <target>`) |
| Changing prefixes on an existing source file | `chezmoi chattr +create,+private <target>` (or `-executable`, etc.) |

### Preview before committing

```bash
chezmoi diff <target>           # See target diff
chezmoi apply --dry-run -v      # See what would happen on this machine
chezmoi status                  # Which files are in A/M/D state
```

### When `chezmoi add` seems to have "done the wrong thing"

Most often the prefix was silently stripped:

```bash
chezmoi source-path <target>    # Where does it live?
ls "$(dirname "$(chezmoi source-path <target>)")"  # Inspect neighbors — did the prefix disappear?
chezmoi chattr +create <target> # Put it back
```

For a `modify_` target, rewind the script from git:

```bash
git -C "$(chezmoi source-path)" checkout -- <relative/path/to/modify_file>
```

## Companion file: `.chezmoiexternal.<format>`

Not a prefix, but a repo-level companion mechanism: a single declarative file at the repo root that tells chezmoi to fetch upstream content (git repos, single files, archives) into the target tree. Reference: [Include files from elsewhere](https://www.chezmoi.io/user-guide/include-files-from-elsewhere/) and [`.chezmoiexternal.<format>` reference](https://www.chezmoi.io/reference/special-files-and-directories/chezmoiexternal-format/).

### In this repo: [`.chezmoiexternal.toml.tmpl`](../../.chezmoiexternal.toml.tmpl)

Source of truth for upstream clones that used to live in ansible roles. Entries today:

| Target | Type | URL | Previously in |
|---|---|---|---|
| `~/.oh-my-zsh` | `git-repo` | `ohmyzsh/ohmyzsh` | `dot_ansible/roles/zsh` |
| `~/.oh-my-zsh/custom/plugins/zsh-autosuggestions` | `git-repo` | `zsh-users/zsh-autosuggestions` | `dot_ansible/roles/zsh` |
| `~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting` | `git-repo` | `zsh-users/zsh-syntax-highlighting` | `dot_ansible/roles/zsh` |
| `~/.oh-my-zsh/custom/plugins/zsh-completions` | `git-repo` | `zsh-users/zsh-completions` | `dot_ansible/roles/zsh` |
| `~/.oh-my-zsh/custom/plugins/zsh-vi-mode` | `git-repo` | `jeffreytse/zsh-vi-mode` | `dot_ansible/roles/zsh` (gated on chezmoi `enableVimMode`, default true; see [vim-mode.md](../this_repo/vim-mode.md)) |
| `~/.tmux/plugins/tpm` | `git-repo` | `tmux-plugins/tpm` | `dot_ansible/roles/devtools` |
| `~/.fzf` (Linux only) | `git-repo` | `junegunn/fzf` | `dot_ansible/roles/lazyvim_deps` |
| `~/.local/share/toolkami/toolkami.rb` | `file` | `aperoc/toolkami/main/toolkami.rb` | `dot_ansible/roles/ruby_gem_tools` |

All `git-repo` entries use `--depth 1` and `--ff-only` on pull; all entries have `refreshPeriod = "168h"` (weekly auto-refresh).

### How updates propagate

```bash
chezmoi apply                 # normal cadence: checks refreshPeriod,
                              # pulls upstream only when older than 168h
chezmoi apply --refresh-externals   # force: pull every external now
```

Externals are evaluated **before** `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`, so by the time ansible runs, `~/.oh-my-zsh`, `~/.tmux/plugins/tpm`, `~/.fzf`, and `~/.local/share/toolkami/toolkami.rb` already exist. Ansible's remaining responsibilities for these tools:

- `zsh` role: install the `zsh` package + change login shell (sudo).
- `devtools` role: run `tpm/bin/install_plugins` once (sentinel at `~/.tmux/plugins/.ansible-installed`).
- `lazyvim_deps` role: run `~/.fzf/install --bin` (idempotent via `creates: ~/.fzf/bin/fzf`).

### Nested externals

`.oh-my-zsh` and `.oh-my-zsh/custom/plugins/<name>` are both declared as separate `git-repo` externals. chezmoi does `git pull` on refresh (not re-clone), so the subdirectories are preserved across refreshes — this is the standard oh-my-zsh install pattern.

### When to add an entry here vs. keep it in ansible

Good fit for `.chezmoiexternal`:

- Plain git clone or single-file download, no arch / OS logic other than `.chezmoi.os` conditional.
- No post-clone build step (or the build step is idempotent and lives in ansible).
- You want the upstream pulled automatically on a schedule.

Keep in ansible:

- Conditional arch / `noRoot` / `armv7l` skip logic (GitHub release binaries).
- Clones whose destination path contains a dynamic version (e.g. `claude-hud` uses `v<tag>` in path and writes `installed_plugins.json`).
- Anything that needs `become: true` after the clone.

### Editing workflow

1. Add / remove entries in `.chezmoiexternal.toml.tmpl`.
2. `chezmoi diff` — verify no unexpected target diffs (externals don't show per-file diff; you'll see the TOML change).
3. `chezmoi apply --refresh-externals` — fetch and apply.
4. If you removed an entry, chezmoi does **not** delete the destination directory (it's not managed anymore). Remove it manually if you want a clean state.

## Case studies in this repo

Three concrete walkthroughs of the `modify_` / `create_` patterns above, with the failure modes that bit us.

### `dot_claude/modify_settings.json` — partial JSON management via jq

Claude Code rewrites `~/.claude/settings.json` at runtime (adds `permissions`, `skipAutoPermissionPrompt`, reorders keys). A static managed file would produce diff on every apply.

`modify_` files are executable scripts: chezmoi pipes the current target contents into stdin and expects the new contents on stdout. The script uses `jq '. * $overlay'` to deep-merge a managed overlay over the live file:

- Keys in the overlay are enforced by chezmoi: `hooks`, `enabledPlugins`, `extraKnownMarketplaces`, `skipDangerousModePermissionPrompt`, `statusLine`.
- Any other keys Claude Code adds (model, permissions, `skipAutoPermissionPrompt`, etc.) are preserved verbatim.
- Arrays in the overlay replace their counterparts wholesale, so `hooks.Notification` won't accumulate duplicates.

To manage an additional key, add it to the `overlay` heredoc in `dot_claude/modify_settings.json`. Requires `jq` (installed by the `base` ansible role). The source file must have exec bit set (git mode `100755`).

**Failure mode**: if the live `~/.claude/settings.json` contains invalid JSON (e.g. Claude Code writes a stray trailing comma), `jq` aborts with a parse error and the script exits non-zero. chezmoi then logs `chezmoi: .claude/settings.json: exit status 5` and skips the file for that apply; the broken live file is left untouched for manual inspection. No partial / corrupt output is ever written. Fix or delete the live file and re-run `chezmoi apply`.

### `.chezmoitemplates/editor/*` — shared overlay for VSCode / Cursor / Antigravity

All three Electron editors read `settings.json` + `keybindings.json` from a per-editor `User/` directory (macOS `~/Library/Application Support/<Editor>/User/`, Linux `~/.config/<Editor>/User/`). Three concerns we manage cross-editor, cross-OS, without fighting each editor's own writes:

1. A tiny **universal baseline** (Hack Nerd Font Mono, relative line numbers, format on save, smart accept-suggestion, terminal font) — canonical in [`.chezmoitemplates/editor/overlay.json`](../../.chezmoitemplates/editor/overlay.json). Add a key here and it deploys to all six targets (3 editors × 2 OSes).
2. **Keybindings** that should seed on a fresh machine but never overwrite an editor's own additions (e.g. Cursor's `alt+cmd+s`) — canonical in [`.chezmoitemplates/editor/keybindings.json`](../../.chezmoitemplates/editor/keybindings.json).
3. The `modify_` / `create_` plumbing itself — the bash+python+jq merge script lives once in [`.chezmoitemplates/editor/modify.sh`](../../.chezmoitemplates/editor/modify.sh); each of the 6 per-editor wrappers is a 1-line `{{ template … }}` shim.

`modify_settings.json.tmpl` uses an inline Python JSONC normaliser (strip `//` and `/* */` comments + trailing commas) before piping into `jq '. * $overlay'`. This is the only place in the repo where live JSONC needs to be deep-merged in-place; **do not duplicate the script** — extend [`modify.sh`](../../.chezmoitemplates/editor/modify.sh) if you need a new overlay section (e.g. `[python]` block overrides).

`create_keybindings.json.tmpl` is seed-once. To push an updated baseline to an existing live file, copy the live file back into the source path (`cp ~/Library/Application\ Support/Code/User/keybindings.json "$(chezmoi source-path ...)"`) to fold in editor-added entries, then edit the template.

**Presence gating in [`.chezmoiignore.tmpl`](../../.chezmoiignore.tmpl).** It ignores both halves of the cross-OS tree on the wrong OS (`Library/**` on non-darwin, `.config/{Code,Cursor,Antigravity}/**` on non-linux), then per-editor `stat` gates ignore the whole subtree when the editor's config dir does not exist. Net effect: a fresh machine with only VSCode installed gets Code settings + skips Cursor/Antigravity entirely, no phantom directories. The `private_` prefix on `Library`, `Application Support`, and each editor dir preserves macOS's native `0700`/`0755` mode.

When adding a fourth editor (e.g. Zed if it ever adopts the same layout), drop it into the `range (list "Code" "Cursor" "Antigravity" "NewEditor")` list in `.chezmoiignore.tmpl` and mirror the 4 source files (`{modify_settings,create_keybindings}.json.tmpl` × macOS/Linux).

### `dot_config/nvim/create_lazy-lock.json` — seed-once, never overwrite

LazyVim rewrites `~/.config/nvim/lazy-lock.json` on every `:Lazy update` and the tracked plugin list differs across OSes. `create_` only writes when the target file does not yet exist (new-machine seed), so subsequent edits produce zero chezmoi diff.

**Refreshing the baseline after a deliberate plugin bump.** Neither `chezmoi re-add` nor `chezmoi add` is the right tool here:

- `chezmoi re-add` silently **skips** `create_` files (by design — `create_` means contents are not managed).
- `chezmoi add` would **strip** the `create_` prefix, promoting it to a plain managed file (defeating the whole point).

Instead, copy the live file directly into the source path (this preserves the prefix):

```bash
cp ~/.config/nvim/lazy-lock.json "$(chezmoi source-path ~/.config/nvim/lazy-lock.json)"
```

This is an explicit, opt-in step instead of constant apply noise.

## See also

- [docs/this_repo/cheatsheet.md → chezmoi](../this_repo/cheatsheet.md#chezmoi) — command-level quick reference.
- [chezmoi docs — Concepts](https://www.chezmoi.io/reference/concepts/) — source state vs destination state vs target state.
- [chezmoi docs — Include files from elsewhere](https://www.chezmoi.io/user-guide/include-files-from-elsewhere/) — `.chezmoiexternal.<format>` user guide.

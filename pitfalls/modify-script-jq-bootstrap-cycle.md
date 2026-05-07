# `modify_*` scripts crash with `jq: command not found` on a fresh-box first apply

**Symptoms** (grep this section): `jq: command not found`; `chezmoi: .agents/.skill-lock.json: exit status 127`; `chezmoi: .claude/settings.json: exit status 127`; `chezmoi: .config/opencode/opencode.json: exit status 127`; `chezmoi: .cursor/cli-config.json: exit status 127`; `/tmp/<random>..skill-lock.json: line NN: jq: command not found`; `chezmoi update --init` aborts immediately after `[SUCCESS] Bootstrap complete!`
**First seen**: 2026-05 (yzhang@idc-server104, `centos_server` profile, `noRoot=true` — first cold-start after the profile was added in commit `e8de50d`)
**Affects**: every fresh machine where `jq` is not pre-installed (CentOS 7 noRoot, minimal Ubuntu Server, fresh Linux containers, older macOS without `/usr/bin/jq`); macOS Sequoia 15+ ships `/usr/bin/jq` system-side and is *not* affected
**Status**: fixed — every `modify_*` script now `command -v` guards `jq` (and `python3` for editor overlays) and falls back to pass-through

## Symptom

On `chezmoi update --init` (or `chezmoi apply`) on a fresh box:

```
[yzhang@idc-server104 chezmoi]$ chezmoi update --init
Already up to date.
[INFO] useChineseMirror=true: using Aliyun (Homebrew) + TUNA (Rustup / mise) mirrors
[INFO] noRoot mode: Skipping Linuxbrew installation (requires sudo)
[INFO] uv is already installed
[INFO] Installing mise...
…
[INFO] ansible is already installed
[INFO] Installing ansible-galaxy collections...
…
[SUCCESS] Bootstrap complete!
/tmp/934409313..skill-lock.json: line 59: jq: command not found
chezmoi: .agents/.skill-lock.json: exit status 127
```

`chezmoi apply` halts with exit 127. Subsequent run-scripts (the ansible
roles in `run_onchange_after_20_ansible_roles.sh.tmpl`) never execute, so
`jq` never gets installed, so the next `chezmoi apply` fails the same way.
The user is stuck in a bootstrap cycle that requires manual intervention to
break.

## Root cause

`chezmoi apply` runs in three phases, in order:

1. `run_once_before_*` scripts → `00_bootstrap.sh.tmpl` installs **uv, mise, ansible-core, Linuxbrew (rooted Linux only), Homebrew (macOS)**. Bootstrap **does not install `jq`** (or `ripgrep`, `fd`, `python3` — those come from ansible).
2. **File-application phase** — chezmoi processes every `modify_*` script. `dot_agents/modify_dot_skill-lock.json.tmpl:58` (and several others) hard-call `jq` with `set -eu` and no `command -v` guard.
3. `run_onchange_after_*` scripts → `20_ansible_roles.sh.tmpl` runs the `base` ansible role, which installs `jq` (apt/yum/brew system path + a noRoot user-level GitHub-release fallback at `dot_ansible/roles/base/tasks/main.yml:248-275`).

On a fresh box, phase 2 needs `jq` but `jq` is only installed in phase 3 →
chicken-and-egg. The `set -eu` in the modify_ script + chezmoi's behaviour
of treating any non-zero exit from a modify_ script as a fatal apply error
means chezmoi aborts before phase 3 runs.

This was previously masked on personal Macs (Homebrew installs `jq` long
before the dotfiles run) and on Ubuntu desktop (jq usually comes pre-loaded
or via a base apt package the user already installed). It surfaced on
CentOS 7 noRoot — see [`pitfalls/centos7-noroot.md`](centos7-noroot.md),
which lists `jq` as one of the binaries missing on that profile but didn't
yet connect it to a bootstrap-order failure.

### Audit — `modify_*` scripts and their dependencies

| File | Calls | Cold-start safe? |
|---|---|---|
| `dot_agents/modify_dot_skill-lock.json.tmpl` | `jq` | ✅ guard added |
| `dot_claude/modify_keybindings.json` | `jq` | ✅ guard added |
| `dot_claude/modify_settings.json` | `jq` | ✅ guard added |
| `dot_config/opencode/modify_opencode.json.tmpl` | `jq` | ✅ guard added |
| `dot_config/opencode/modify_tui.json.tmpl` | `jq` | ✅ guard added |
| `dot_cursor/modify_cli-config.json.tmpl` | `jq` | ✅ guard added |
| `.chezmoitemplates/editor/modify.sh` (covers VSCode + Cursor + Antigravity × Linux + macOS = 6 wrappers) | `python3` + `jq` | ✅ both guarded; uv→python3 fallback chain |
| `dot_codex/modify_config.toml.tmpl` | `uv`/`python3` | ✅ already had guards (`:47-55`) |
| `dot_config/docker/modify_daemon.json.tmpl` | `jq` | ✅ already had guard (`:28-31`) |
| `dot_docker/modify_config.json.tmpl` | `jq` | ✅ already had guard (`:19-21`) |

## Workaround

If you're hit by an unfixed version of this repo (i.e. before the guard
commits landed), break the cycle by manually installing `jq` user-level —
same source the `base` ansible role uses (`base/tasks/main.yml:248-275`):

```sh
mkdir -p ~/.local/bin
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/;s/armv7l/armhf/')
curl -fsSL -o ~/.local/bin/jq \
  "https://github.com/jqlang/jq/releases/latest/download/jq-linux-${ARCH}"
chmod +x ~/.local/bin/jq
hash -r
chezmoi apply
```

After ansible's `base` role runs (during the next `chezmoi apply`), it will
overwrite `~/.local/bin/jq` with the same binary — idempotent.

On macOS pre-Sequoia, the equivalent is `brew install jq` (or download the
`jq-macos-arm64` / `jq-macos-amd64` binary from the same GitHub releases
page).

## Prevention

The guard pattern adopted in this repo, lifted from
[`run_onchange_after_40_install_global_skills.sh.tmpl:32-35`](../.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl):

```sh
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "modify_<file>: jq not found; passing live file through unchanged. Re-run \`chezmoi apply\` after the base ansible role installs jq." >&2
  printf '%s' "$base"
  exit 0
fi
```

The `printf '%s' "$base"` is the load-bearing line — chezmoi sees stdout
matching the live file → no-op for that target → apply continues.

For `editor/modify.sh` (which needs both `python3` and `jq`), the python3
side gets a uv→system-python3 fallback chain mirroring
[`dot_codex/modify_config.toml.tmpl:47-55`](../dot_codex/modify_config.toml.tmpl).
`uv` is bootstrap-guaranteed, so the chain almost always succeeds; if
neither is available, both pass through.

The contract for future `modify_*` scripts is documented in
[`docs/tools/chezmoi-prefixes.md`](../docs/tools/chezmoi-prefixes.md) →
"Bootstrap-order contract".

## Related

- [`pitfalls/centos7-noroot.md`](centos7-noroot.md) — sibling pitfall: lists `jq` (and others) as missing on noRoot CentOS but doesn't enumerate the bootstrap-cycle failure mode this doc covers
- [`docs/tools/chezmoi-prefixes.md`](../docs/tools/chezmoi-prefixes.md) → "Bootstrap-order contract" — design contract for `modify_*` scripts (must tolerate post-bootstrap-installed tools)
- [`docs/this_repo/upgrades.md`](../docs/this_repo/upgrades.md) — separate concern: install vs upgrade split, why `chezmoi apply` is install-only
- [`dot_ansible/roles/base/tasks/main.yml:248-275`](../dot_ansible/roles/base/tasks/main.yml) — the canonical user-level (noRoot) `jq` install path: download from GitHub releases into `~/.local/bin/jq`

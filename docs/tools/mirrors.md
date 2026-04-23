# GFW / China Mirrors — `useChineseMirror`

A single chezmoi prompt (`useChineseMirror`, answered at `chezmoi init`) drives
mirror configuration across every package ecosystem this repo touches. When
enabled, the mirror is wired up automatically on the next `chezmoi apply` —
no manual env-var editing needed.

Most mirrors point at [TUNA (清华大学开源软件镜像站)](https://mirrors.tuna.tsinghua.edu.cn/),
with a few exceptions where another mirror is the de-facto standard (npm →
npmmirror, Docker Hub → DaoCloud, Go modules → goproxy.cn, Ubuntu apt → Huawei Cloud).

## Quick toggle

```bash
# Check current value
chezmoi data | rg useChineseMirror

# Flip the flag (re-runs the init prompt)
chezmoi init --force        # will re-ask useChineseMirror

# Or edit ~/.config/chezmoi/chezmoi.toml directly:
#   useChineseMirror = true / false
# Then:
chezmoi apply
```

## Coverage matrix

| Ecosystem | Managed by | Mirror | TUNA doc |
|---|---|---|---|
| **PyPI** (`uv` / `pip`) | `~/.config/uv/uv.toml` | Aliyun → TUNA → USTC (multi-index fallback) | [pypi](https://mirrors.tuna.tsinghua.edu.cn/help/pypi/) |
| **npm** | `~/.npmrc` | `registry.npmmirror.com` | — |
| **Bun** | `~/.config/.bunfig.toml` | `registry.npmmirror.com` | — |
| **crates.io** (Cargo) | `~/.cargo/config.toml` | TUNA sparse index | [crates.io-index](https://mirrors.tuna.tsinghua.edu.cn/help/crates.io-index/) |
| **RubyGems** | `~/.gemrc` | `mirrors.tuna.tsinghua.edu.cn/rubygems/` | [rubygems](https://mirrors.tuna.tsinghua.edu.cn/help/rubygems/) |
| **Anaconda / Mamba** | `~/.condarc` | `mirrors.tuna.tsinghua.edu.cn/anaconda/{pkgs,cloud}` | [anaconda](https://mirrors.tuna.tsinghua.edu.cn/help/anaconda/) |
| **Homebrew** (bottles + brew.git + core.git) | `$HOMEBREW_*` env vars (`~/.config/zsh/00_exports.zsh` + 2 bootstrap scripts) | `mirrors.tuna.tsinghua.edu.cn/homebrew-*` | [homebrew](https://mirrors.tuna.tsinghua.edu.cn/help/homebrew/) |
| **Rustup** (dist + self-update) | `RUSTUP_DIST_SERVER` / `RUSTUP_UPDATE_ROOT` env vars | `mirrors.tuna.tsinghua.edu.cn/rustup` | [rustup](https://mirrors.tuna.tsinghua.edu.cn/help/rustup/) |
| **mise** Node.js prebuilt | `MISE_NODE_MIRROR_URL` / `NODE_BUILD_MIRROR_URL` env vars | `mirrors.tuna.tsinghua.edu.cn/nodejs-release/` | [nodejs-release](https://mirrors.tuna.tsinghua.edu.cn/help/nodejs-release/) |
| **Go modules** | `GOPROXY` env var | `goproxy.cn` (Qiniu; TUNA has no Go proxy) | — |
| **Docker Hub** (rootless Docker on Linux) | `~/.config/docker/daemon.json` via `modify_daemon.json.tmpl` | DaoCloud / USTC / NJU / ISCAS / Baidu / azk8s (fallback chain) | — |
| **Ubuntu apt** (Docker image only) | `Dockerfile` | Huawei Cloud | [ubuntu](https://mirrors.tuna.tsinghua.edu.cn/help/ubuntu/) |

## Where env vars are exported (three layers)

Env-var-driven mirrors (Homebrew, Rustup, mise, Go) are exported in three
places so every code path gets the mirror:

| Layer | File | Why |
|---|---|---|
| Interactive shells | `dot_config/zsh/00_exports.zsh.tmpl` | `brew install`, `rustup install`, `mise install`, `go install` from the terminal |
| First-run bootstrap | `run_once_before_00_bootstrap.sh.tmpl` | Installing Homebrew itself, first `brew install` + first `uv`/`ansible` setup (before `.zshrc` exists) |
| Ansible re-runs | `run_onchange_after_20_ansible_roles.sh.tmpl` | `community.general.homebrew`, `mise install`, etc. in ansible subprocesses — regardless of the shell that invoked `chezmoi apply` |

## What's NOT auto-mirrored (and why)

- **System `apt` on real Linux hosts** — modifying `/etc/apt/sources.list.d/`
  requires sudo and users typically pre-configure apt during OS install.
  Only the Docker image sets Huawei Cloud apt (see `Dockerfile`).
- **`git clone` of github.com** — global `git insteadOf` rewrites break gh CLI
  and private repos; too invasive.
- **GitHub Releases / `raw.githubusercontent.com`** — TUNA has `github-release`
  but the mapping is incomplete; rewriting release URLs across ansible
  roles would be fragile.
- **pre-commit hooks / oh-my-zsh / TPM** — these clone from github.com;
  same rewrite concerns as above.
- **System `pip`** — `uv.toml` already covers the primary path; system pip
  only fires as a fallback in `security_tools` role.

## npm postinstall scripts that download from GitHub Releases

The npm registry is mirrored (`registry.npmmirror.com`), but **a small set
of npm packages run a `postinstall` script that downloads a prebuilt
binary directly from GitHub Releases** — bypassing the npm tarball
mirror entirely. From China, `release-assets.githubusercontent.com`
(Azure blob CDN) is frequently slow or unreachable, and these scripts
typically have **no env-var override** for the download URL.

Symptom: `npm install -g <pkg>` hangs after printing
`Downloading https://github.com/.../releases/download/...` with no
further output. The npm tarball download itself succeeds (fast, from
npmmirror) — only the postinstall step hangs.

| Package | Postinstall downloads | Workaround in this repo |
|---|---|---|
| `tree-sitter-cli` | `tree-sitter-{platform}-{arch}.gz` | `dot_ansible/roles/lazyvim_deps/tasks/main.yml` wraps with `timeout 180` → cargo fallback (crates.io is TUNA-mirrored) |
| `node-gyp` (transitive, when building native modules) | platform headers / pre-builts | No managed install — only triggers if a downstream package needs native build |

When adding a new ansible task that runs `npm install -g <pkg>`:

1. **Check if the package has a postinstall binary download** —
   `npm view <pkg> scripts.postinstall` or read its `install.js`.
2. If yes, **wrap with `timeout 180`** and a sensible fallback (cargo,
   apt, manual binary download from a mirrored host).
3. **Don't `set ignore_errors: true`** alone — it doesn't catch hangs,
   only failures. Use `failed_when: false` + an explicit
   `treesitter_npm.rc | default(1) != 0` gate on the fallback task so
   `timeout` exit 124 properly fires the next step.

## Adding a new mirror

1. Identify the ecosystem (env var or config file driven?).
2. **Env-var driven**: add to all three layers (`00_exports.zsh.tmpl` +
   `run_once_before_00_bootstrap.sh.tmpl` +
   `run_onchange_after_20_ansible_roles.sh.tmpl`) inside the
   `{{ if .useChineseMirror -}} ... {{ end -}}` block.
3. **Config-file driven**: template the config under
   `dot_<tool>/<config>.tmpl` with `{{ if .useChineseMirror }} ... {{ else }} ... {{ end }}`.
   If the file is safe to always manage (eg. `uv.toml`, `.cargo/config.toml`), no ignore gate is needed.
   If it conflicts with user-managed files (eg. `.condarc`, `.gemrc`), also gate via
   `.chezmoiignore.tmpl`:

   ```go-template
   {{- if not .useChineseMirror }}
   .condarc
   .gemrc
   {{- end }}
   ```

4. Update the coverage matrix in this file and add a one-line entry to
   the `README.md` "Managed config files" section.
5. Test with `chezmoi execute-template --init --promptBool useChineseMirror=true < <template>` and
   `chezmoi diff`.

## Troubleshooting

### `curl: (18) Transferred a partial file` during brew install

See [infrastructure-as-code.md → Troubleshooting](./infrastructure-as-code.md#troubleshooting).

### Conda / Mamba: slow or failing channel refresh after toggling `useChineseMirror`

Conda caches channel metadata. Force a refresh:

```bash
conda clean -i    # invalidate index cache
mamba clean -i    # same for mamba
```

### Rust toolchain still slow after `useChineseMirror=true`

Rustup reads env vars at process start. If you enabled the flag but already
have a zsh session open, the old values are still exported. Open a new shell
or run `source ~/.zshrc && source ~/.config/zsh/00_exports.zsh`. Verify:

```bash
echo $RUSTUP_DIST_SERVER   # should be https://mirrors.tuna.tsinghua.edu.cn/rustup
```

### Go modules not using goproxy.cn

Same as Rustup — re-source. Also check that `GOPROXY` isn't being overridden
by `go env -w GOPROXY=...` which persists to `~/.config/go/env` and takes
precedence over the env var. To unset a persistent value:

```bash
go env -u GOPROXY
```

## Related

- [TUNA mirror site](https://mirrors.tuna.tsinghua.edu.cn/) — full list of what TUNA hosts
- [TUNA Homebrew guide](https://mirrors.tuna.tsinghua.edu.cn/help/homebrew/)
- [TUNA rustup guide](https://mirrors.tuna.tsinghua.edu.cn/help/rustup/)
- [TUNA anaconda guide](https://mirrors.tuna.tsinghua.edu.cn/help/anaconda/)
- [TUNA rubygems guide](https://mirrors.tuna.tsinghua.edu.cn/help/rubygems/)
- [goproxy.cn](https://goproxy.cn/) — Qiniu-hosted Go module proxy
- [npmmirror](https://npmmirror.com/) — Alibaba-hosted npm mirror

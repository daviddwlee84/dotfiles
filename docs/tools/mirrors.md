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
| **Homebrew** (bottles/API + brew.git; **no** core.git — see note) | `$HOMEBREW_*` env vars (`dot_config/shell/00_exports.sh.tmpl` + 2 bootstrap scripts) | **BFSU** `mirrors.bfsu.edu.cn/homebrew-*` (fastest, 2026-07 benchmark); switch live with `brew-mirror {bfsu\|ustc\|aliyun\|tuna}` | [bfsu](https://mirrors.bfsu.edu.cn/help/homebrew-bottles/) / [ustc](https://mirrors.ustc.edu.cn/help/brew.git.html) |
| **Rustup** (dist + self-update) | `RUSTUP_DIST_SERVER` / `RUSTUP_UPDATE_ROOT` env vars | `mirrors.tuna.tsinghua.edu.cn/rustup` | [rustup](https://mirrors.tuna.tsinghua.edu.cn/help/rustup/) |
| **mise** Node.js prebuilt | `MISE_NODE_MIRROR_URL` / `NODE_BUILD_MIRROR_URL` env vars | `mirrors.tuna.tsinghua.edu.cn/nodejs-release/` | [nodejs-release](https://mirrors.tuna.tsinghua.edu.cn/help/nodejs-release/) |
| **Go modules** | `GOPROXY` env var | `goproxy.cn` (Qiniu; TUNA has no Go proxy) | — |
| **Docker Hub** (rootless Docker on Linux) | `~/.config/docker/daemon.json` via `modify_daemon.json.tmpl` | DaoCloud / USTC / NJU / ISCAS / Baidu (fallback chain) | — |
| **Ubuntu apt** (Docker image only) | `Dockerfile` | Huawei Cloud | [ubuntu](https://mirrors.tuna.tsinghua.edu.cn/help/ubuntu/) |

## Security and trust model

Mirrors trade a trust boundary for speed. The one question that decides how much
you're trusting a mirror: **is package integrity verified independently of the
mirror, or does the mirror also supply the checksum it's checked against?**

- **If verification is independent**, a malicious or compromised mirror cannot
  tamper undetected — a changed artifact fails a checksum that the mirror did
  not provide.
- **If the mirror supplies both the artifact and its expected checksum/index**
  (the common case for a *fresh* install with no lockfile), you are trusting the
  operator. This is inherent to *any* mirror or proxy — a corporate Artifactory
  is the same — not something specific to Chinese mirrors.

Third-party network tampering (MITM) is a separate axis and is already closed:
**every mirror here is HTTPS** (no plaintext `http://`).

### Tier 1 — independent cryptographic verification (mirror cannot tamper)

| Ecosystem | Why it's safe |
|---|---|
| **Go modules** | `GOPROXY=goproxy.cn` serves modules, but `GOSUMDB=sum.golang.google.cn` (Google-operated mirror of the signed checksum database) verifies every module against `go.sum` independently. Even a malicious proxy is caught. This is the gold standard — keep `GOSUMDB` set, never disable it. |

### Tier 2 — checksum ships with the artifact from the same mirror on fresh install

For a *brand-new* install these mirrors are trusted; a **lockfile turns them into
Tier-1** for anything already pinned.

| Ecosystem | Mirror-supplied checksum source | Independent protection you have |
|---|---|---|
| **Cargo** | crates.io index (SHA256) | `Cargo.lock` catches tampering of already-pinned deps |
| **npm / Bun** | registry metadata | `package-lock.json` `integrity` (sha512) for pinned deps |
| **PyPI** (uv/pip) | `simple` index hashes | `uv.lock` or hash-pinned `requirements.txt` (`--require-hashes`) |
| **Homebrew** | formula JSON via `HOMEBREW_API_DOMAIN` (the API domain is *also* the bottle checksum source, so the mirror controls both) | operator reputation (BFSU = university) |
| **RubyGems / conda / Rustup / mise-node** | index / manifest / `SHASUMS256.txt` from the same mirror | operator reputation; conda/gem checksums in a lockfile |

Real-world protection for Tier 2 = **operator reputation + HTTPS + lockfiles**.
All operators here are high-reputation (TUNA=Tsinghua, USTC, BFSU, SJTU, ZJU,
NJU universities; Alibaba/Tencent/Huawei/Baidu/Qiniu major clouds) with strong
legal and reputational disincentives against injecting malware, and they are
bit-for-bit rsync copies of upstream. **Pin with a lockfile for anything
security-sensitive** and the trust drops to Tier 1.

### Tier 3 — resolution/metadata trust (the one to watch)

- **Docker Hub `registry-mirrors`**: a pull-through mirror resolves `tag→digest`,
  and Docker Content Trust is **off by default**, so the mirror decides which
  image a tag like `latest` maps to. Once you pull **by digest**
  (`repo@sha256:…`) it's content-addressed and safe. For sensitive images, pull
  by digest or enable Content Trust. `dockerhub.azk8s.cn` and `dockerproxy.com`
  were **removed** (2026-07): a dead/third-party mirror domain can lapse and be
  re-registered by an attacker into a malicious pull-through cache.

### Residual risks (true even with reputable mirrors)

- **Staleness** — a mirror can lag upstream, delaying a security fix or briefly
  serving a version that was yanked upstream.
- **Fresh-install trust** — Tier 2 without a lockfile trusts the operator; a
  breached mirror server is the realistic (not deliberate-vendor-malice) threat.
- **Dependency confusion** — only if you add a *private* index alongside the
  public PyPI mirrors in `uv.toml`; the `index-strategy = "unsafe-first-match"`
  there is safe *only* because all three indexes are public. See the warning in
  `dot_config/uv/uv.toml.tmpl`.

## Where env vars are exported (three layers)

Env-var-driven mirrors (Homebrew, Rustup, mise, Go) are exported in three
places so every code path gets the mirror:

| Layer | File | Why |
|---|---|---|
| Interactive shells | `dot_config/zsh/00_exports.zsh.tmpl` | `brew install`, `rustup install`, `mise install`, `go install` from the terminal |
| First-run bootstrap | `run_once_before_00_bootstrap.sh.tmpl` | Installing Homebrew itself, first `brew install` + first `uv`/`ansible` setup (before `.zshrc` exists) |
| Ansible re-runs | `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` | `community.general.homebrew`, `mise install`, etc. in ansible subprocesses — regardless of the shell that invoked `chezmoi apply` |

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
   `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`) inside the
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

### `brew update` / any `brew` command hangs for 60s+ then does nothing

The `HOMEBREW_BREW_GIT_REMOTE` git mirror's smart-HTTP `upload-pack` is broken:
`git ls-remote` (ref advertisement) succeeds so the mirror *looks* healthy, but the
actual packfile fetch stalls. **Aliyun's `brew.git` has this bug** — it was the
default baseline until 2026-07 and froze every `brew update` (and every
auto-update before `brew install`/`brew upgrade`) until `unset
HOMEBREW_BREW_GIT_REMOTE`.

Fix: switch to a working mirror. Benchmark (2026-07, CN network — `brew.git`
shallow fetch + ~30 MB bottle-index download):

| Mirror | brew.git fetch | bottle throughput | verdict |
|---|---|---|---|
| **BFSU** | 1.1s | 31 MB/s | fastest — **current baseline** |
| USTC | 1.0s | 11 MB/s | solid fallback |
| Aliyun | **FAIL** (upload-pack) | 17 MB/s | git broken, bottles fine |
| TUNA | **timeout 45s** | 6 MB/s | queueing, both slow |

Switch on-the-fly with `brew-mirror {bfsu|ustc|aliyun|tuna}` then `brew update`.
Baseline lives in `dot_config/shell/00_exports.sh.tmpl` (+ the two bootstrap
scripts). Full debug story: `pitfalls/homebrew-aliyun-brew-git-hang-core-clone-bloat.md`.

### `brew` disk usage ballooned / `brew update` got slow after being fast

Check `du -sh "$(brew --repo homebrew/core)/.git"`. If it's ~1 GB, homebrew/core
got converted from the API stub (~8 KB) into a full git clone — this happens
whenever `HOMEBREW_CORE_GIT_REMOTE` is **set** and `brew update` runs. Homebrew
4.x uses the JSON API (`HOMEBREW_API_DOMAIN`) as the source of truth, so
`HOMEBREW_CORE_GIT_REMOTE` should stay **unset**. Restore lean API mode:

```bash
brew untap homebrew/core     # removes the ~1 GB clone; formulae still resolve via the API
unset HOMEBREW_CORE_GIT_REMOTE
```

The `brew-mirror` helper unsets it and auto-untaps a stray >100 MB clone.

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

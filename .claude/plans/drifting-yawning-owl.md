# Harden GFW/China mirror config against supply-chain risk

## Context

A security review of the `useChineseMirror` mirror surface (single chezmoi prompt, default `false`) found the setup is **low-risk overall** — every mirror is HTTPS, points at high-reputation operators (TUNA/USTC/BFSU/SJTU/ZJU/NJU + Alibaba/Tencent/Huawei/Baidu/Qiniu), there is no global `git insteadOf` rewrite, real-host `apt` is untouched, and `GOSUMDB=sum.golang.google.cn` gives Go modules true independent verification.

Three gaps are worth closing:

1. **Docker `registry-mirrors` includes two low-trust endpoints** — `dockerhub.azk8s.cn` (deprecated Azure-China mirror) and `dockerproxy.com` (third-party, ToS-churned). Beyond the availability rot the docs already note, a **dead/third-party mirror domain is a supply-chain risk**: if the registration lapses and an attacker re-registers it, Docker (with Content Trust off by default) will trust that pull-through cache's `tag→digest` resolution and can be served a malicious image for a tag like `latest`.
2. **`uv.toml` uses `index-strategy = "unsafe-first-match"`** — currently safe (all three indexes are public PyPI mirrors) but an un-annotated future foot-gun: adding any private/internal index to that file turns it into a dependency-confusion vector.
3. **`docs/tools/mirrors.md` documents speed, not trust** — there is no written trust model explaining *why* these mirrors are acceptable and what the residual risks are.

Outcome: prune the two risky Docker endpoints, annotate the uv foot-gun, document the trust model (bilingual), and add a cross-file rule so the curated list + rationale can't silently drift again.

User decisions (confirmed):
- Docker list: **remove only `azk8s` + `dockerproxy`**; keep `daocloud` (primary) + `ustc` + `nju` + `iscas` + `baidu`.
- **Add** a CLAUDE.md cross-file rule to keep the list + trust-model in sync going forward.

## Changes

### 1. Prune Docker mirror list (canonical + all doc mirrors)

- **`dot_config/docker/modify_daemon.json.tmpl`** (canonical, lines 34–42): drop the `dockerhub.azk8s.cn` and `dockerproxy.com` array entries so the `jq` list becomes the 5-entry `daocloud / ustc / nju / iscas / baidu`. Add a short comment above the list: dead/third-party domains removed to avoid domain-takeover → malicious pull-through cache; for security-sensitive images pull by digest or enable Content Trust (the mirror controls `tag→digest`).
- **`docs/tools/containers.md`**: remove the two entries from the Strategy A JSON block (lines 175–183); in the per-mirror bullets (193–197) delete the azk8s (196) + dockerproxy (197) lines and add one bullet stating they were **removed** for the domain-takeover reason above. Docker-Desktop (225–231) and containerd (348–350) examples already omit both — leave them.
- **`docs/tools/containers.zh-TW.md`**: same edits, translated — JSON block (180–187), per-mirror bullets remove azk8s (201) + dockerproxy (202) + add the removed-for-security bullet.
- **`docs/tools/mirrors.md`** line 41 + **`docs/tools/mirrors.zh-TW.md`** line 41: change coverage-matrix Docker row `DaoCloud / USTC / NJU / ISCAS / Baidu / azk8s (fallback chain)` → `DaoCloud / USTC / NJU / ISCAS / Baidu (fallback chain)`.
- **`README.md`** line 201: already truncated (`DaoCloud / USTC / NJU / ...`) so it stays accurate — verify only, no edit.

### 2. Annotate the uv dependency-confusion foot-gun

- **`dot_config/uv/uv.toml.tmpl`** (lines 14–16, inside the `useChineseMirror` block): keep `index-strategy = "unsafe-first-match"` **unchanged**, but expand the comment: safe *today* because all three indexes are public PyPI mirrors that sync from upstream; **if you ever add a private/internal index to this file, switch back to `first-match` (or pin the internal package to its own index)** — `unsafe-first-match` + a public mirror listed first is a dependency-confusion path (a public package that shadows an internal name can be pulled first).

### 3. Add a "Security / trust model" section (bilingual)

- **`docs/tools/mirrors.md`**: new `## Security / trust model` section (insert after `## Coverage matrix`, before `## Where env vars are exported`). Content, kept tight:
  - Core question: *is package integrity verified independently of the mirror?* Frame the 3 tiers.
  - **Tier 1 — independent crypto verification**: Go modules (`GOSUMDB=sum.golang.google.cn`); mirror cannot tamper undetected.
  - **Tier 2 — checksum ships with the artifact from the same mirror on fresh install; lockfiles protect pinned deps**: Cargo / npm / Bun / PyPI / Homebrew (API domain = checksum source too) / RubyGems / conda / Rustup / mise-node. Real protection = operator reputation + HTTPS + lockfiles (`Cargo.lock`, `package-lock` `integrity`, `uv.lock`, hash-pinned requirements).
  - **Tier 3 — metadata/resolution + third-party**: Docker `tag→digest` is resolved by the mirror (Content Trust off by default) → pull by digest or enable DCT for sensitive images; note `azk8s`/`dockerproxy` were removed for domain-takeover risk.
  - **Mitigated**: transport MITM (all HTTPS), no global `git insteadOf`, real-host `apt` untouched.
  - **Residual risks**: staleness (delayed CVE sync), fresh-install trust in Tier 2, dependency-confusion if a private index is mixed into `uv.toml`.
- **`docs/tools/mirrors.zh-TW.md`**: same section translated, header following the page's zh-TW terminology admonition (L3) → `## 安全性 / 信任模型 (Security / trust model)`; body uses `中文 (English original)` on first use of key terms.
- Out of scope (note, don't fix here): `mirrors.zh-TW.md` already drifted from English (missing 2 brew-hang troubleshooting subsections + stale Homebrew matrix row). Not part of this security change; flag for a separate resync.

### 4. Governance — new CLAUDE.md cross-file rule

- **`CLAUDE.md`** "## Cross-file maintenance rules" table: add a row —
  - *Surface*: Docker `registry-mirrors` list in `dot_config/docker/modify_daemon.json.tmpl`
  - *Also update*: `docs/tools/containers.md` + `.zh-TW.md` (Strategy A JSON block + per-mirror bullets), `docs/tools/mirrors.md` + `.zh-TW.md` (coverage-matrix Docker row + Security/trust-model section)
  - *Reference*: when dropping a mirror, state the security reason (dead/third-party domain → takeover → malicious pull-through cache; mirror controls `tag→digest`). Keep the curated list + trust rationale in sync.
- Keep under the file's ~30k-char headroom rule (one row is negligible). `AGENTS.md`/`GEMINI.md` are symlinks — editing `CLAUDE.md` covers all three.

## Files touched

- `dot_config/docker/modify_daemon.json.tmpl` (canonical list)
- `dot_config/uv/uv.toml.tmpl` (comment only)
- `docs/tools/containers.md`, `docs/tools/containers.zh-TW.md`
- `docs/tools/mirrors.md`, `docs/tools/mirrors.zh-TW.md`
- `CLAUDE.md`
- (verify-only, likely no edit) `README.md`

## Verification

1. **Docker template renders + valid JSON**: `chezmoi execute-template --init --promptBool useChineseMirror=true < dot_config/docker/modify_daemon.json.tmpl` confirms no Go-template syntax error (note: on this macOS host `.chezmoi.os=darwin` takes the `else` branch, so also validate the Linux-branch `jq` array directly: `echo '{}' | jq '.["registry-mirrors"] = ["https://docker.m.daocloud.io","https://docker.mirrors.ustc.edu.cn","https://docker.nju.edu.cn","https://mirror.iscas.ac.cn","https://mirror.baidubce.com"]'` → must emit valid JSON with exactly 5 entries, no azk8s/dockerproxy).
2. **uv.toml still valid TOML**: `chezmoi execute-template --init --promptBool useChineseMirror=true < dot_config/uv/uv.toml.tmpl | python3 -c 'import tomllib,sys; tomllib.load(sys.stdin.buffer); print("ok")'`.
3. **Docs build clean** (required by CLAUDE.md docs rule): `uv run mkdocs build --strict` — catches broken anchors, the new section, and i18n pairing of the zh-TW counterpart. Do not tighten `validation.links.not_found` (known drift tracked in `backlog/mkdocs-anchor-drift.md`).
4. **No stray references left**: `grep -rn 'azk8s\|dockerproxy' dot_config/ docs/ README.md` returns nothing outside `.specstory/`/`.cursor/` history.
5. **Sanity-scan the new CLAUDE.md row** renders in the table (pipe count matches sibling rows).

# Context

`ytmv get` is currently failing on public YouTube videos with `Sign in to confirm you’re not a bot`. The attempted Chrome-cookie fallback also fails with `find-generic-password failed` / `cannot decrypt v10 cookies: no key found` and no macOS dialog. Read-only investigation found two separate issues:

1. The Chrome cookie database exists, but the exact Keychain item yt-dlp queries (`account=Chrome`, `service=Chrome Safe Storage`) is not addressable (status 44 / OSStatus `-25300`). Authorization is never reached, so no popup is expected; creating a replacement key cannot decrypt cookies encrypted with the missing original.
2. Both in-house YouTube CLIs embed bare yt-dlp without its packaged EJS challenge solver and without enabling the installed Node 24 runtime. Public videos should normally remain cookie-free, so the runtime stack must be fixed before asking the user to expose an account cookie.

The outcome should be: public `yth`/`ytmv` calls use packaged EJS + Node without cookies; `ytmv help` becomes a complete, import-free setup/troubleshooting guide; `doctor` distinguishes runtime/network failures from optional cookie issues; authenticated access remains explicit and safely documented. The previously built Lemon manifest came from workflow-agent web/oEmbed/cross-reference discovery, not `ytmv` search—`ytmv` deliberately consumes known URLs only.

# Implementation

## 1. Install the complete yt-dlp runtime everywhere

- Change both PEP 723 launchers to `yt-dlp[default]>=2026.7.4`:
  - `dot_dotfiles/bin/executable_yth`
  - `dot_dotfiles/bin/executable_ytmv`
- Change the standalone uv-tool declaration in `dot_ansible/roles/python_uv_tools/defaults/main.yml` to `yt-dlp[default]`, retaining `binary: yt-dlp`, and declare the environment name plus `yt-dlp-ejs` as a required installed distribution.
- Extend `dot_ansible/roles/python_uv_tools/tasks/main.yml` with a generic `required_distributions` probe, parallel to the existing `extra_binaries` guard. Resolve the uv tool dir, inspect the existing tool venv with `importlib.metadata`, force reinstall only when a required distribution is absent, re-probe/fail clearly, and remain idempotent/install-only on subsequent applies.
- Document the new defaults field in the role header. Do not independently pin `yt-dlp-ejs` or permit remote EJS downloads; yt-dlp’s `default` extra owns compatible solver versions.

## 2. Enable Node in every embedded YoutubeDL call

- Add a fresh-dict helper such as `yt_dlp_runtime_opts()` in `scripts/yth/__init__.py` returning `{"js_runtimes": {"node": {}}}`.
- Merge it into all yth call sites (`sync.py`, `enrich.py`, `fetch_subs.py`) and ytmv’s shared `_base_opts()` in `scripts/ytmv/get.py`; make playlist expansion reuse `_base_opts()` so it cannot drift.
- Remove `no_warnings=True` while retaining quiet/no-progress behavior. Runtime/EJS warnings are diagnostic and must not be hidden.
- Do not add Deno/Bun fallback. Node is the managed runtime; a missing Node becomes a doctor failure with `mise`/shell-reload remediation.

## 3. Make `ytmv help` the complete deployed guide

In `dot_dotfiles/bin/executable_ytmv`:

- Keep concise `USAGE` for bare invocation, `-h`/`--help`, and errors.
- Add an import-free static `GUIDE` printed only by literal `ytmv help`.
- Hoist the leaf map so normal dispatch and help delegation share one source:
  - `ytmv help` → full guide.
  - `ytmv help get|lyrics|tag|doctor` → that leaf’s Tyro `--help`.
  - unknown help topic → exit 2 with concise usage.
- Advertise `help [SUBCOMMAND]` without adding search or a `tv` channel.

Guide sections:

1. Install/enable media tools (`dotcfg --set installMediaTools=true --yes`), ensure Node/mise is visible, then run doctor.
2. Try public videos cookie-free first.
3. Diagnosis order: EJS/Node → clean residential IP (avoid VPN/cloud/datacenter) → wait/reduce rate/`--sleep` → cookies only for intrinsic authorization or last-resort bot checks → PO-token provider as advanced last resort.
4. Account warning: yt-dlp use can suspend an account; cookie files are bearer credentials.
5. Recommended authenticated setup: dedicated supported Firefox/Zen profile used only for YouTube.
6. Arc/Chromium fallback: isolated private session, only `youtube.com/robots.txt`, exact extension **Get cookies.txt LOCALLY** (warn about the similarly named former malicious extension), export only YouTube cookies, save `~/.config/yth/cookies.txt` mode `0600`, close the session, replace/delete expired copies.
7. Chrome macOS diagnosis using metadata-only `security find-generic-password -a Chrome -s 'Chrome Safe Storage'`—never `-w`; explain status 44/`-25300` and why no popup appears.
8. Config examples for `from_browser` / `cookiefile`, shared yth ownership, and `ytmv get URL --cookies` only when intentionally enabled.
9. State that `ytmv` accepts URLs and does not search; link the full docs site. Do not embed the one-off Lemon story in permanent help.

Also explicitly ignore target `.config/yth/cookies.txt` in `.chezmoiignore.tmpl` as defense-in-depth against accidental `chezmoi add`.

## 4. Upgrade doctor from presence checks to actionable diagnostics

Refactor `scripts/ytmv/doctor.py` around a small `Check` model (`id`, `status=ok|warn|fail|skip`, `detail`, `remediation`, `required`) and one exit-code function shared by table/JSON output.

Required checks:

- uv, yt-dlp, `yt-dlp-ejs`, Node/version, mutagen, httpx, ffmpeg, writable output dir.
- Cookie-free metadata extraction of a stable public yt-dlp test video unless `--offline`, using the exact shared runtime options as downloads.

Optional checks:

- libass (required only for `--burn-subs`), LRCLIB, and cookie source.
- `--offline` emits stable skipped YouTube/LRCLIB rows instead of omitting them.

Add explicit `doctor --cookies` (reject with `--offline`):

- Resolve cookie precedence exactly like `ytmv get` through a shared helper in `scripts/ytmv/__init__.py`.
- Validate without exposing contents: cookie file existence/nonempty/0600, Firefox/Zen profile + `cookies.sqlite`, unsupported Arc browser name, and macOS Chrome Keychain metadata lookup with captured/discarded output and status-44 explanation.
- Then perform a public metadata probe with the selected source to catch load/decryption errors. Label this as source loading/decryption—not proof that every private URL is authorized.
- Never inspect private history or print cookie/Keychain values.

## 5. Mirror the public surface and documentation

- Update both completions:
  - `dot_config/zsh/tools/60_ytmv_completion.zsh`
  - `dot_config/bash/60_ytmv_completion.bash`
  - Add `help`, leaf completion after `help`, and `doctor --cookies`; preserve dynamic profiles from `doctor --list-profiles`.
- Update existing docs/mirrors:
  - `docs/tools/ytmv.md`: EJS/Node stack, public-first ladder, safe cookie workflow, no-popup diagnosis, account/file risks, doctor semantics, no-search boundary.
  - `docs/tools/yth.md` + `docs/tools/yth.zh-TW.md`: shared cookie owner, isolated export, security/rotation, EJS/runtime distinction.
  - `docs/this_repo/tool-managers.md`: `yt-dlp[default]`, packaged `yt-dlp-ejs`, and `required_distributions` role field.
  - `docs/zsh/zsh-completions.md`, `docs/shells/aliases.md`, `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl`: `help`/doctor behavior and command inventory.
  - `README.md`: add the missing ytmv/yt-dlp runtime mention required when touching the ansible install surface.
  - `CLAUDE.md`: strengthen the yth/ytmv invariant so both PEP 723 launchers and `python_uv_tools` retain `[default]`/EJS coupling.
- No new docs page/nav entry and no ytmv zh-TW page; the existing MkDocs fallback remains.

## 6. Regression tests

Extend `tests/unit/ytmv.bats` (and add focused yth assertions there or in a small new yth test only if clearer) to cover:

- Concise import-free `--help` and bare-error paths.
- Full `ytmv help` headings, public-cookie-free guidance, safe Chrome command (and absence of secret-printing `-w`), credential hygiene, and no-search statement.
- `ytmv help get` delegation and unknown-topic exit 2.
- Bash/Zsh completion parity for `help`, help topics, and `doctor --cookies`.
- `[default]` in both launchers + uv-tool declaration; generic role probe for `yt-dlp-ejs`.
- Shared Node runtime options in every embedded YoutubeDL caller and no warning suppression.
- Offline doctor JSON’s stable statuses/required flags, consistent exit semantics, optional-warning behavior, and `--offline --cookies` rejection.
- Cookie-source validation with synthetic temp files/profiles only; never access real browser/Keychain/cookie data in tests.

# Verification and resume the original download task

1. Static/app checks:
   - plain-Python launcher help paths (`ytmv --help`, `ytmv help`, help topics)
   - `bash -n` / `zsh -n` completions
   - `bats tests/unit/ytmv.bats` (plus any yth-focused test)
   - `just ansible-syntax-check`, `just check`
   - `uv run mkdocs build --strict` (report known clean-HEAD baseline warnings separately)
   - `chezmoi diff`; leave unrelated live SpecStory churn untouched.
2. Apply/install validation:
   - apply the changed managed CLI/config surfaces and run the narrow python_uv_tools role path needed to refresh the standalone tool.
   - verify `yt-dlp-ejs` via the tool venv’s `importlib.metadata`, Node visibility, `ytmv doctor --offline --json`, then online `ytmv doctor`.
3. Real smoke test without cookies:
   - download the canonical public Lemon URL into `~/Music/ytmv/Lemon-versions/`.
   - validate ffprobe decoding, duration, ID3v2.3/TIT2/TPE1/APIC/USLT, and matching timed `.lrc` when available.
4. If public access still fails after EJS/Node and clean-IP checks, stop and ask the user to choose/configure a dedicated account/profile; do not default to their primary account.
5. Once smoke passes, download the curated distinct set (original, 哥布林版, TNT, Mandarin/Cantonese/English/female-Japanese/instrumental variants) one URL at a time with explicit metadata. Do not manually copy/transcribe lyrics; accept LRCLIB/YouTube-caption output when available and report missing lyrics as optional, then validate every MP3 as above.

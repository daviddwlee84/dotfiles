# Add `centos_server` profile (CentOS 7.9, no sudo)

## Context

User has a corporate CentOS Linux 7.9.2009 box (`yzhang@idc-server104`)
where `sudo -v` fails with PAM permission denied — i.e. no sudo at all.
Wants to run this dotfiles repo on it the same shape as `ubuntu_server`:
no GUI, headless, server-class. Today only three profiles are recognised
(`macos`, `ubuntu_desktop`, `ubuntu_server`); falling back to
`ubuntu_server` does not work because every Linux ansible role gates on
`ansible_facts["os_family"] == "Debian"` — including the **user-level
GitHub-release fallback blocks** that don't need sudo. So on a CentOS
box even the no-sudo install paths get skipped, and `chezmoi apply`
deploys configs that point at binaries that were never installed.

The big realization from the scope conversation: **on a noRoot CentOS
box, the load-bearing fix isn't adding yum branches — it's broadening
the `os_family == "Debian"` gates on the user-level fallback paths so
they fire on RedHat too.** The apt blocks are tagged `[sudo]` and
already skipped by `--skip-tags sudo` under noRoot mode; the GitHub
release / cargo / mise paths are user-level and don't need sudo, but
they're currently dead-coded for RedHat by an `os_family` predicate
that has no business being on the user-level path.

The migration target is unknown (the box may stay on CentOS 7 long-term
or get rebuilt as Rocky 8/9). Plan accordingly: any CentOS-7-specific
workaround (glibc 2.17 musl preference, EPEL repo bootstrap) gets a
clear comment so it can be ripped out cleanly if the box gets rebuilt.

## Confirmed scope (from clarifying questions)

- **Role port:** Foundational-only. Wire profile + targeted role tweaks.
  Don't comprehensively port `devtools` to yum.
- **Sudo:** None. `noRoot=true` is mandatory at the prompt; user must
  pass `noRoot=true` (or accept the default if the prompt has the right
  default for CentOS, which today it doesn't — see TODO at end).
- **Migration:** Unknown. Add CentOS-7-specific bits with comments so
  they're cheap to remove later.

## Files to modify

### A. Profile wiring — 4 lockstep files (REQUIRED)

| # | File | Edit |
|---|------|------|
| 1 | `.chezmoi.toml.tmpl` line 20 | Append `"centos_server"` to `$profileChoices`: `list "macos" "ubuntu_desktop" "ubuntu_server" "centos_server"` |
| 2 | `Dockerfile` line 125 (comment only) | Update comment to `(ubuntu_server\|ubuntu_desktop\|macos\|centos_server)`. ARG on line 8 stays as-is (just a default value). |
| 3 | `scripts/init/dotfiles_init.py` line 121 | Append `"centos_server"` to `choices=()` of the `Prompt("profile", …)` |
| 4 | `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` after line 133 | Add `{{ else if eq .profile "centos_server" -}}` branch. `PLAYBOOK="$ANSIBLE_DIR/playbooks/linux.yml"` (same as `ubuntu_server`). `TAGS="base,zsh,starship,neovim,lazyvim_deps,devtools,docker,security_tools,rust_cargo_tools,ruby_gem_tools"` (same as `ubuntu_server`). Comment line above it: "CentOS Server: same as Ubuntu Server; user-level fallbacks only on noRoot, see pitfalls/centos7-noroot.md" |

After these 4 edits:
- `uv run --script scripts/init/dotfiles_init.py doctor` must exit 0.
- `chezmoi execute-template < .chezmoi.toml.tmpl` (with profile=centos_server)
  must round-trip cleanly.

### B. Ansible: broaden Debian-only gates on user-level fallback paths

Pattern in `dot_ansible/roles/base/tasks/main.yml` (and applies similarly
elsewhere) — there are 16 hits of `os_family == "Debian"` in that role
alone. Two distinct kinds:

**Kind 1: sudo-tagged apt block** (lines ~19, 38, 219-220, 257-268, 340-349, 359-368, 384-385):
```yaml
- name: Install base packages (Debian/Ubuntu)
  when: ansible_facts["os_family"] == "Debian"
  become: true
  tags: [sudo]
  ansible.builtin.apt: ...
```
Leave alone OR add a parallel `RedHat` branch with `yum:` (tags: [sudo],
become: true) — won't fire on noRoot but useful future-proofing for any
other CentOS user with sudo. **Recommend: add parallel RedHat blocks
only for the trivial cases** (zsh, ruby_gem_tools libffi-devel /
libyaml-devel) and leave large ones (devtools, gui_apps_linux) alone.

**Kind 2: user-level fallback gate** (lines 49-50, 56-58, 132-133, 139-141, 219-220 → wait that's kind 1 — re-examine; the GitHub release blocks are at 56-129, 139-211, 258-281, 348-378, etc.):
```yaml
- name: Re-check if ripgrep is installed
  when: ansible_facts["os_family"] == "Debian"   # <-- BUG for CentOS
  ansible.builtin.shell: command -v rg
  ...

- name: Install ripgrep from GitHub releases (user-level, no sudo)
  when:
    - ansible_facts["os_family"] == "Debian"     # <-- BUG for CentOS
    - rg_recheck.rc != 0
  block: ...
```
**Fix: broaden these to** `ansible_facts["os_family"] in ["Debian", "RedHat"]`.
For CentOS 7 specifically, the existing musl preference for ripgrep / fd
already does the right thing (musl tarballs ignore glibc version, so
glibc 2.17 is fine).

Concrete files + line ranges to broaden (from the grep run during
exploration):

| Role | File | Lines to broaden |
|------|------|------------------|
| `base` | `dot_ansible/roles/base/tasks/main.yml` | 50, 58, 133, 141, 220, 228, 258, 268, 281, 341, 349, 360, 368, 385 — for each, identify whether it's a "command -v X recheck" or a GitHub-release `block:` (those are the user-level paths that need broadening). Do NOT broaden the apt-tasks (lines 20, 39, 219). |
| `zsh` | `dot_ansible/roles/zsh/tasks/main.yml` | Line 13 is the apt block — leave. The user-level `chsh` path (lines 41-66) already gates on `os_family != "Darwin"`, so it works on RedHat as-is. **Required precondition for noRoot CentOS: zsh must already be on `$PATH`** (corporate CentOS boxes typically ship zsh). Captured in pitfalls below. |
| `lazyvim_deps`, `neovim`, `starship`, `security_tools`, `rust_cargo_tools` | spot-check during implementation | Apply the same broadening rule: any user-level / non-sudo path gated on `Debian` should become `in ["Debian", "RedHat"]`. Stop at the first role where the audit becomes painful — note as TODO. |

**Implementation procedure:** open each file, walk top-to-bottom, for
each `os_family == "Debian"` predicate ask "is this on a sudo-tagged
task?" If yes, leave alone (or add parallel RedHat block for the
trivial ones). If no, broaden to `in ["Debian", "RedHat"]`.

### C. Add minimal yum branches (future-proofing only)

Trivial cases where adding a yum block is one-screen of yaml and unlocks
sudo-able CentOS boxes for future users / a future yzhang with sudo:

- `base` role: parallel `Install base packages (RedHat)` block —
  `yum:` install of `git, git-lfs, curl, wget, jq, tree, gcc, gcc-c++,
  make`. Skip ripgrep/fd from yum (they're EPEL-only on CentOS 7 and
  the GitHub-release path is more reliable). `become: true`, `tags:
  [sudo]`.
- `zsh` role: parallel `Install zsh (RedHat)` block. Trivial.
- `ruby_gem_tools` role: parallel block for `libffi-devel,
  libyaml-devel`. Trivial.

Skip yum porting for: `devtools` (huge), `neovim` (EPEL situation
fragile), `lazyvim_deps` (lazygit not in standard RedHat repos),
`security_tools` (already cross-distro). Document the skip in a TODO
entry per project-knowledge-harness pattern.

### D. Pitfalls + documentation

**New file: `pitfalls/centos7-noroot.md`** — cover symptom-first per
the project-knowledge-harness rule:

- **Symptom:** `chezmoi apply` on CentOS 7 with noRoot=true completes
  cleanly but `command -v rg` / `fd` / `nvim` returns nothing — the
  binaries were never installed.
- **Root cause:** Debian-only `when:` predicates on user-level
  fallback paths.
- **Fix:** broadening pattern (cite this commit).
- **CentOS-7-specific notes:** glibc 2.17 means prefer musl assets;
  upstream `fd` and `ripgrep` already ship musl. Tools that DO ship
  glibc-only binaries (some Go releases, some Rust releases without
  musl variants) will fail with `GLIBC_2.X not found` — symptom + the
  cargo-source-build workaround.
- **Required preconditions on a noRoot CentOS box:** `zsh` and `git`
  must already be system-installed (verified `which zsh git`); the
  ansible role can't install them without sudo.
- **Migration note:** if rebuilt as Rocky 8/9, glibc-2.17 caveats go
  away; the gate-broadening (B) is still correct on Rocky.

**`docs/this_repo/architecture.md` lines 129-136** — add row to the
profile table:
```markdown
| `centos_server` | CentOS 7+ (RedHat family) | Same as `ubuntu_server`. **noRoot recommended** — see `pitfalls/centos7-noroot.md`. |
```
Plus a one-paragraph note on why this is its own profile rather than
auto-detected via `.chezmoi.osRelease.id` (cite CLAUDE.md's "profile is
for user-role choices, but package-manager-family is load-bearing for
ansible role behaviour" carve-out — the chezmoi profile picks the
playbook + tags, ansible facts pick the package manager, separation is
clean).

**`mkdocs.yml`** — add nav entry for the new pitfalls page if pitfalls
are in the nav (verify; if `pitfalls/` is referenced via absolute
GitHub URL only, no nav change needed).

**`README.md`** — only update if there's a "Supported Platforms"
table; from exploration there isn't one explicitly, so no change
needed unless we want to add CentOS to the prose. Defer.

**`docs/tools/chezmoi-templating.md`** — if it has the predicate
table, add a row for "RedHat family detection: `eq
.chezmoi.osRelease.id "centos"` or similar" with a link to the
profile-vs-osRelease decision rationale. Verify file exists during
implementation.

### E. TODO + backlog entries (per project-knowledge-harness)

- **`TODO.md`** new entry: `P3 [M] — Comprehensive devtools yum port +
  EPEL bootstrap for centos_server with sudo` (only useful if a future
  CentOS user has sudo; design notes in backlog).
- **`backlog/centos-devtools-yum-port.md`** new file: design sketch of
  what a full devtools yum port would look like (EPEL repo
  pre-installation task, package name mapping, glibc-2.17 caveats per
  tool). Not for execution; just frozen state so future-me doesn't
  re-do the audit.

### F. NOT in scope (deliberately)

- `Dockerfile` doesn't need a `centos_server` build target — user wants
  real-machine support, not a Docker variant. Skip unless asked.
- `useChineseMirror` interaction with EPEL / yum mirrors. The
  `idc-server104` hostname might suggest a Chinese DC, but: (a) the
  trivial yum branches we're adding are gated by `[sudo]` and won't
  fire on the user's noRoot box; (b) if a future user with sudo hits
  it, document then. Mention in TODO, don't engineer up-front.
- `BUNDLES` preset for CentOS in `dotfiles_init.py`. The existing
  `server-linux` bundle is fine — bundles are feature flags, not
  profile-specific.
- `gui_apps_linux` — already excluded by `centos_server` tag set; no
  change to that role. The `bitwarden` role likewise stays Debian-only
  for its snap/.deb path; the npm fallback path already works
  cross-distro and noRoot.

## Verification

1. **Drift check:** `uv run --script scripts/init/dotfiles_init.py
   doctor` exits 0.
2. **Template build:** `uv run mkdocs build --strict` succeeds.
3. **Existing-host regression:** on macOS dev box, `chezmoi diff` shows
   zero changes (the new branch only adds, doesn't modify).
4. **Round-trip on a fresh non-CentOS Linux:** `chezmoi init …
   --promptString "Which profile=centos_server"` succeeds at the prompt
   stage and the ansible script picks `linux.yml` with the correct tag
   set. (Doesn't actually need to run on CentOS for this check — just
   verifies the wiring.)
5. **End-to-end on idc-server104:**
   - `chezmoi init --apply daviddwlee84` → answer `centos_server` at
     profile prompt + `noRoot=true`.
   - Verify ansible router script picks `linux.yml` with
     `ubuntu_server` tag set + `--skip-tags sudo`.
   - `command -v rg fd jq starship nvim` should mostly resolve to
     `~/.local/bin/*` (the user-level fallback paths now firing on
     RedHat).
   - Note in pitfalls anything that doesn't (glibc-2.17 casualties,
     missing GitHub release variants).
6. **chsh:** `getent passwd $USER | awk -F: '{print $7}'` returns a zsh
   path. (Requires zsh pre-installed and the box to allow `chsh`.)

## Critical files (reading list before implementing)

- `.chezmoi.toml.tmpl:15-26` — profile prompt block + the
  "Profile only encodes user-role choices" comment (the contract this
  plan extends).
- `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl:62-63,
  217-263` — `NEED_SUDO` template flag + noRoot tag-skip path
  (`--skip-tags sudo`).
- `dot_ansible/roles/base/tasks/main.yml` (whole file) — canonical
  "macOS / Debian apt / GitHub-release fallback" pattern. The
  broadening rule in section B applies here.
- `dot_ansible/roles/zsh/tasks/main.yml:41-66` — example of a
  user-level Linux path that's already gated correctly
  (`os_family != "Darwin"`); reference for what "broadened correctly"
  looks like.
- `scripts/init/dotfiles_init.py:108-125, 632-687` — `Prompt` schema +
  `doctor` parity check.
- `CLAUDE.md` "Chezmoi templating conventions" section — the
  profile-vs-osRelease rule. We're justifying a deliberate exception
  for package-manager family in the architecture.md entry.

## TODO surfaced during planning (capture but not blocking)

- The `$defaultProfile` selection in `.chezmoi.toml.tmpl` line 21-22
  could pick `centos_server` automatically when chezmoi sees a RedHat
  family in `.chezmoi.osRelease.id`. Today it falls through to
  `ubuntu_server` on every non-darwin OS. **Skip for this plan**
  (the user is going through `dotfiles_init` which prompts anyway), but
  worth a short follow-up commit. Captured in `TODO.md`.
- `installBitwarden`'s help text on `.chezmoi.toml.tmpl:37` mentions
  "ubuntu_desktop / macOS profile" — when this lands the text becomes
  accurate by omission, but if we ever add `centos_desktop` or similar
  it will need updating. Annotate or leave; user choice.

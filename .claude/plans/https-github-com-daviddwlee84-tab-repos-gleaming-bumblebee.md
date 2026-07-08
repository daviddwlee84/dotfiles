# Plan: Interactive GitHub/GitLab repo finder (`ghrepo` / `glrepo` + tv twins)

## Context

Finding one's own repos today means opening `github.com/daviddwlee84?tab=repositories`
and eyeballing name/description, or running `gh repo list` — which is **non-interactive
and caps at 30 rows** by default. The goal: fuzzy-search your repos by *name + description*,
preview the README in-terminal, then act — **clone (and `cd` in)**, **open in browser**, or
**copy the URL**. Same for GitLab. Raycast's GitHub extension is the UX target, but in the
terminal, reusing this repo's existing idioms.

**Research outcome (why this shape).** Both `gh` and `glab` are *already installed* (ansible
`devtools` role), so no new binaries are required. The decisive constraint: the workflow is
find → clone → **work in the repo**, and only code running in the interactive shell (a shell
function) can `cd` the parent shell into a freshly-cloned dir — a `gh` *extension* or a `tv`
*action* runs in a subprocess and cannot. Prebuilt options exist (`remcostoeten/gh-select`,
`benelan/gh-fzf`) but are GitHub-only and can't `cd`-after-clone. So the primary surface is a
pair of **shell functions**, with **`tv` channels as discoverable browse/open/copy twins** —
mirroring this repo's existing `mlf` ↔ `tv mlflow` twin pattern.

Decisions confirmed with the user:
- **Surfaces:** shell functions **+** tv channel twins.
- **Clone destination:** default = **current dir, then `cd <repo>`**; expose a `*_ROOT` env
  hook now so a "repo root" (e.g. `~/src`) can be wired later to pair with try-cli's `graduate`
  (`Ctrl-G` → `$TRY_PROJECTS`). See Follow-ups.
- **GitLab:** gitlab.com now (self-hosted via `GITLAB_HOST` is a documented follow-up).

## What already exists (reuse — do not reinvent)

| Thing | Path | Reuse for |
|---|---|---|
| GitHub shell-fn home | `dot_config/shell/41_github.sh` (`ghget`) | add `ghrepo` here (POSIX, bash+zsh) |
| GitLab shell-fn home | `dot_config/shell/42_gitlab.sh` (`glcreate`) | add `glrepo` here |
| tv channel template | `dot_config/television/cable/git-ops.toml` | copy `_clip()` action + `{split:\t:N}` + keybinding style |
| tv channel template | `dot_config/television/cable/fleet-hosts.toml` | house style: CLI source → TSV → `display`/`output` |
| gh doc | `docs/tools/gh-cli.md` | add a "Find & clone your repos" section |
| clone-dir convention | `dot_config/sesh/sesh.toml` wildcards (`/Volumes/Data/Program/*/*`, `~/repos/*`) | Follow-up repo-root target |
| try graduate | `dot_config/zsh/tools/32_try.zsh` (`TRY_PROJECTS`, `try-sesh`) | Follow-up integration |

Community `gh-prs.toml` / `git-repos.toml` exist only in the *live* cable dir (from
`tv update-channels`), unmanaged — cribbing references, not files to edit.

## Design

Two cross-platform shell functions + two tv channels. Both hosts symmetric (GitHub via `gh`,
GitLab via `glab`). The fzf/tv key mnemonics are aligned where the platform allows: **`ctrl-y`
= copy-URL** and **`alt-o` = open-in-browser** in both surfaces; clone is `enter` in the
functions (can `cd`) vs `alt-c` in the channels (subprocess, can't `cd`) — that divergence *is*
the cd-constraint story and gets a one-line doc note.

### 1. `ghrepo` — append to `dot_config/shell/41_github.sh`

POSIX/shared style matching `ghget` (`command -v` guards, `local`, no zsh-only constructs).
`cd` works in-place because a function does not spawn a subshell.

```sh
# Fuzzy-find your GitHub repos (name + description), preview README, then
# clone+cd / open in browser / copy URL. Needs: gh (authed) + fzf.
# Usage: ghrepo [owner] [extra `gh repo list` flags]
#   ghrepo                  # your repos (default owner = authed user)
#   ghrepo some-org --source
# Clone lands in ${GHREPO_ROOT:-$PWD}/<repo>, then cd's in.
ghrepo() {
  command -v gh  >/dev/null 2>&1 || { echo "ghrepo: gh not found"  >&2; return 1; }
  command -v fzf >/dev/null 2>&1 || { echo "ghrepo: fzf not found" >&2; return 1; }
  local sel repo dest
  sel=$(
    gh repo list "$@" --limit 4000 --no-archived \
       --json nameWithOwner,description,primaryLanguage,visibility \
       --jq '.[] | [.nameWithOwner, (.description // ""), (.primaryLanguage.name // ""), .visibility] | @tsv' \
    | fzf --ansi --delimiter='\t' --with-nth=1,2,3,4 \
          --preview 'gh repo view {1}' --preview-window='right,60%,wrap' \
          --header 'enter=clone+cd  alt-o=open  ctrl-y=copy-url' \
          --bind 'alt-o:execute-silent(gh repo view {1} --web)' \
          --bind 'ctrl-y:execute-silent(gh browse -R {1} -n | (pbcopy 2>/dev/null || wl-copy 2>/dev/null || xclip -selection clipboard 2>/dev/null))' \
    | cut -f1
  )
  [ -n "$sel" ] || return 0
  repo="${sel##*/}"; dest="${GHREPO_ROOT:-$PWD}"
  gh repo clone "$sel" "$dest/$repo" && cd "$dest/$repo"
}
```
Key points: `--limit 4000` (lists *all* repos, not 30); private repos included when authed;
name+description both fuzzy-searchable; `gh repo view {1}` renders the README as the preview.

### 2. `glrepo` — append to `dot_config/shell/42_gitlab.sh`

Mirror of `ghrepo` using `glab`. `web_url` is carried as a hidden TSV field for copy (glab has
no `browse -n`). gitlab.com by default; `glab` honors `GITLAB_HOST` natively for self-hosted.

```sh
# Fuzzy-find your GitLab repos, preview, clone+cd / open / copy URL.
# Needs: glab (authed) + fzf + jq. Usage: glrepo [extra `glab repo list` flags]
glrepo() {
  command -v glab >/dev/null 2>&1 || { echo "glrepo: glab not found" >&2; return 1; }
  command -v fzf  >/dev/null 2>&1 || { echo "glrepo: fzf not found"  >&2; return 1; }
  local sel repo dest
  sel=$(
    glab repo list --mine --per-page 100 "$@" -F json \
    | jq -r '.[] | [.path_with_namespace, (.description // ""), .visibility, .web_url] | @tsv' \
    | fzf --ansi --delimiter='\t' --with-nth=1,2,3 \
          --preview 'glab repo view {1}' --preview-window='right,60%,wrap' \
          --header 'enter=clone+cd  alt-o=open  ctrl-y=copy-url' \
          --bind 'alt-o:execute-silent(glab repo view {1} --web)' \
          --bind 'ctrl-y:execute-silent(printf %s {4} | (pbcopy 2>/dev/null || wl-copy 2>/dev/null || xclip -selection clipboard 2>/dev/null))' \
    | cut -f1
  )
  [ -n "$sel" ] || return 0
  repo="${sel##*/}"; dest="${GLREPO_ROOT:-$PWD}"
  glab repo clone "$sel" "$dest/$repo" && cd "$dest/$repo"
}
```
Note: `--per-page 100`; add `--all` in-line comment for users with >100 repos.

### 3. `dot_config/television/cable/github-repos.toml` (new, plain `.toml`)

`requirements = ["gh", "jq"]` auto-skips the channel where the binaries are absent (cleaner
than a `.tmpl` OS gate). `enter` stays tv's default `confirm_selection` (emits `nameWithOwner`
via `output`, so `sel=$(tv github-repos)` works); side-effects on Alt/Ctrl. `_clip()` body and
the `{split:\\t:N}` escaping are copied verbatim from `git-ops.toml`.

```toml
[metadata]
name = "github-repos"
description = "Fuzzy-find your GitHub repos: preview README, open, copy URL, clone"
requirements = ["gh", "jq"]

[source]
command = "gh repo list --limit 4000 --no-archived --json nameWithOwner,description,primaryLanguage,visibility --jq '.[] | [.nameWithOwner, (.description // \"\"), (.primaryLanguage.name // \"\"), .visibility] | @tsv'"
display = "{split:\\t:0}  {split:\\t:3}  {split:\\t:2}  │  {split:\\t:1}"
output = "{split:\\t:0}"

[ui]
layout = "portrait"
[ui.preview_panel]
size = 60

[preview]
command = "gh repo view '{split:\\t:0}'"

[keybindings]
alt-o = "actions:open"
ctrl-y = "actions:copy-url"
alt-c = "actions:clone"

[actions.open]
description = "Open repo in browser"
command = "gh repo view '{split:\\t:0}' --web"
mode = "fork"

[actions.copy-url]
description = "Copy repo URL to clipboard"
command = """_clip() { local d; d=$(cat); [ -z "$d" ] && return; if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$d" | pbcopy; elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$d" | wl-copy; elif command -v xclip >/dev/null 2>&1; then printf '%s' "$d" | xclip -selection clipboard; else printf '%b' "\\033]52;c;$(printf '%s' "$d" | base64)\\007" > /dev/tty; fi; }; gh browse -R '{split:\\t:0}' -n | _clip"""
mode = "fork"

[actions.clone]
description = "Clone repo into the current directory"
command = """repo='{split:\\t:0}'; printf '\\nCloning %s ...\\n' "$repo"; gh repo clone "$repo"; printf '\\n[Press Enter to close]'; read -r _"""
mode = "execute"
```

### 4. `dot_config/television/cable/gitlab-repos.toml` (new)

Same shape with `glab`, `requirements = ["glab", "jq"]`, source
`glab repo list --mine --per-page 100 -F json | jq -r '.[] | [.path_with_namespace, (.description // ""), .visibility, .web_url] | @tsv'`.
`copy-url` action pipes `printf '%s' '{split:\\t:3}'` (the `web_url`) into `_clip()`;
`open`/`clone` use `glab repo view --web` / `glab repo clone`.

## Mandatory cross-file updates (same commit — per CLAUDE.md)

- **`docs/shells/aliases.md`** — add rows for `ghrepo` and `glrepo` next to `ghget`/`glcreate`
  (columns: name | type=function | source file | scope | one-line). *(Hard rule: shell fn in
  `dot_config/{shell,zsh,bash}/` → aliases.md row.)*
- **`docs/tools/tv.md`** — add `github-repos` / `gitlab-repos` to the channel reference list.
- **`docs/tools/gh-cli.md`** — add a short "Finding & cloning your repos" section (`ghrepo`
  + `tv github-repos`, the `--limit 4000` vs default-30 note, the cd-constraint one-liner).
- If any edited doc has a `.zh-TW.md` twin, mirror the change; then `uv run mkdocs build --strict`
  (aware of the ~12 baseline warnings tracked in memory — not a regression from this change).

**Not required:** no completion files (these are shell *functions*, not `dot_dotfiles/bin`
CLIs, so the Section-F two-file rule doesn't apply); **no** `chezmoi-dotfiles` SKILL.md edit
(tv channels are auto-discovered; the skill is only edited for a new prompt key or a stable new
`executable_*` CLI); no `mkdocs.yml` nav change (extending existing docs, not adding pages);
no ansible/tool-managers change (`gh`/`glab` already installed).

## Verification (run the app, not just syntax — per Hard invariant)

1. `chezmoi diff` then `chezmoi apply`.
2. `gh auth status` (prereq). Reload: `exec zsh` (or `source ~/.config/shell/41_github.sh`).
3. **`ghrepo`** → fzf opens with **all** repos (confirm >30); type part of a name *or*
   description → filters; preview pane shows the README; `ctrl-y` copies URL (paste to check);
   `alt-o` opens the browser; `enter` clones into cwd and lands you inside `<repo>` (`pwd`).
4. **`tv github-repos`** → `tv list-channels | grep github-repos` lists it; channel opens,
   preview renders, `alt-o`/`ctrl-y`/`alt-c` actions fire (validates the TOML in the real app).
5. **`glrepo`** and **`tv gitlab-repos`** — same, after `glab auth status` (needs `glab auth login`).
6. Edge cases: ESC in fzf returns cleanly (no clone); a repo whose name != dir basename clones
   to the right folder; empty `GHREPO_ROOT` behaves as cwd.

## Follow-ups (documented, not built now)

1. **Repo-root + try graduate:** set `GHREPO_ROOT`/`GLREPO_ROOT` (e.g. to `$TRY_PROJECTS` =
   `~/src`) to clone into a permanent root, complementing try-cli's `Ctrl-G` graduate and
   `try-sesh`. Optionally add a `sesh connect "$dest/$repo"` variant to fire the tmuxp layout.
2. **Self-hosted GitLab:** document `GITLAB_HOST=git.company.com glrepo` (glab honors it natively).
3. **Zero-effort trial:** `gh extension install remcostoeten/gh-select` (Raycast-like TUI,
   GitHub-only) to compare UX — complementary, not a replacement.
4. **ZLE widget** (Alt-key) that pastes `gh repo clone <sel> && cd <repo>` into the buffer,
   giving the tv channel a cd-capable path (like git-ops' `Alt+I`) — needs a keymap-namespace check.

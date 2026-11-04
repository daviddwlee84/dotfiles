# gh-dash

[gh-dash](https://github.com/dlvhdr/gh-dash) (`gh dash`) is a terminal dashboard for GitHub **pull requests**, **issues** and **notifications**. This repo installs it as a `gh` extension through the `devtools` ansible role. The install is skipped until `gh auth status` passes, so run `gh auth login` first on a fresh box. Diffs open in [`diffnav`](git_diff_workflow.md#gh-dash--diffnav).

Keys below are for gh-dash **v4.26**. Press `?` inside gh-dash to see the keys for the current view. That screen always matches the installed version.

## Launching

| How | Opens on |
|---|---|
| `gh dash` | PRs view (uses a repo-local `.gh-dash.yml` if one exists) |
| `gh dash --config ~/.config/gh-dash/issues.yml` | Issues view |
| `gh dash --config ~/.config/gh-dash/notifications.yml` | Notifications view |
| Herdr `prefix + Alt + p` | PRs, temporary pane |
| Herdr `prefix + Alt + i` | Issues, temporary pane |
| Herdr `prefix + Alt + n` | Notifications, temporary pane |

The Herdr keys work like the lazygit key (`prefix + G`). They open a temporary pane in the focused pane's directory, and `q` closes it. Inside a git repo, gh-dash's **smart filtering** limits every section to that repo; press `t` to switch it off and see everything. These are `type = "pane"`, not popups, because popups are session-modal: a dashboard left open would block switching tabs.

## Views

There are exactly three views. **`s` cycles through them: PRs → Issues → Notifications → PRs.** Each view's sections run their queries the first time you visit it.

## Moving around (all views)

| Key | Action |
|---|---|
| `j` / `k` (↓/↑) | next / previous row |
| `g` / `G` | first / last row |
| `h` / `l` (←/→) | previous / next **section** (the tabs along the top) |
| `p` / `P` | toggle preview pane / toggle its position (right ↔ bottom) |
| `Ctrl+d` / `Ctrl+u` | scroll the preview down / up |
| `r` / `R` | refresh this section / every section in the view |
| `o` | open in browser |
| `y` / `Y` | copy number / copy URL |
| `?` | help for the current view |
| `q` | quit |

## Searching and filtering

- **`/`** focuses the search bar, which holds the current section's **GitHub search query**. Edit it and press Enter to re-run the section. The edit lasts for this session only and isn't saved to the config.
- **`t`** toggles smart filtering, the automatic `repo:<current repo>` scope.
- **`Ctrl+s`** enters section mode. Then `n` creates a new section and `x` removes one.

The query uses GitHub's normal search syntax:

| Goal | Query |
|---|---|
| PRs waiting on my review | `is:open review-requested:@me` |
| My open PRs | `is:open author:@me` |
| Issues assigned to me | `is:open assignee:@me` |
| Bugs in a repo | `repo:owner/name is:open label:bug` |
| Text search | `is:open "flaky test" in:title` |
| Recently updated | `is:open updated:>2026-10-01` |

Notification sections take a different filter set: `is:unread|read|all|done`, `reason:author|comment|mention|review-requested|assign|subscribed|team-mention|state-change|ci-activity|participating`, and `repo:owner/name`.

## Actions per view

**PRs**

| Key | Action | Key | Action |
|---|---|---|---|
| `d` | diff (in diffnav) | `C` / `Space` | checkout |
| `v` | approve | `c` | comment |
| `m` | merge | `u` | update from base branch |
| `w` | watch checks | `V` | approve all workflows |
| `W` | mark ready for review | `e` | expand description |
| `a` / `A` | assign / unassign | `L` | label |
| `x` / `X` | close / reopen | `[` / `]` | previous / next sidebar tab |

**Issues**

| Key | Action |
|---|---|
| `c` | comment |
| `C` | checkout |
| `a` / `A` | assign / unassign |
| `L` | label |
| `x` / `X` | close / reopen |

**Notifications**

| Key | Action |
|---|---|
| `Enter` / `Esc` | view the PR or issue inline / back to the list |
| `m` / `M` | mark read / mark all read |
| `D` / `Alt+d` | mark done / mark all done |
| `u` | unsubscribe |
| `b` | toggle bookmark |
| `S` | sort by repo |

## Discussions

gh-dash has **no Discussions view**. A discussion only shows up as a row in the Notifications view (for example under `reason:mention` or `reason:subscribed`), and `o` opens it in the browser. To browse discussions:

- `x open "$(gh browse -n)/discussions"` opens the current repo's discussions page in the browser (`gh browse` has no discussions flag)
- `gh api graphql` queries them from scripts

## Config

| File | Role |
|---|---|
| `~/.config/gh-dash/config.yml` | Global config, the SSOT. Currently only `pager.diff: diffnav`, so the default sections apply. |
| `~/.config/gh-dash/issues.yml` | `include: [./config.yml]` plus `defaults.view: issues` |
| `~/.config/gh-dash/notifications.yml` | `include: [./config.yml]` plus `defaults.view: notifications` |

All three come from `dot_config/gh-dash/` in this repo. gh-dash has no command-line flag for the start view, so the per-view files exist to set it. With `include`, the including file's keys win, keybindings are unioned, and sections come from whichever file defines them.

One caveat: `--config` takes priority over a repo-local `.gh-dash.yml`. Only plain `gh dash` (`prefix + Alt + p`) honours that file.

To add your own sections or keybindings, edit `dot_config/gh-dash/config.yml`. The two view files pick up the change automatically. Avoid custom keys that shadow built-ins (for example, `g` is "first row").

## References

- [gh-dash docs](https://www.gh-dash.dev/): configuration, keybindings, and the schema for IDE autocomplete
- [git diff workflow](git_diff_workflow.md): how `diffnav` / `delta` / lazygit fit together
- [Herdr keybindings](herdr.md#keybindings)

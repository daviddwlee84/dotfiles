# Shared repository navigation

`dev-projects` supplies local repo candidates from `dev repo list --json` to
Sidecar, Neovim and Television. It is a small dotfiles helper, not a subcommand
of the dev binary. Requires Python 3.11+, Git and dev; Sidecar/Neovim are needed
only for their selected actions. No background scanner or second catalog is
created.

The prototype targets macOS/Linux. Paths containing ASCII control characters
are refused because line-based pickers cannot represent them safely. Spaces,
quotes and Unicode names are supported; Sidecar import separately refuses
leading/trailing path whitespace that its native CLI would trim.

## Everyday use

```bash
dev-projects list --json
dev-projects open /absolute/repo --tool sidecar
dev-projects open /absolute/repo --tool nvim
```

The helper filters out bare repositories and unavailable directories, resolves
symlink duplicates, and keeps distinct clones even when their remote URLs or
names match. Opening rechecks the selected candidate and Git checkout, then
passes one path argument to the selected application. It does not register a
Sidecar project, initialize td, create a task, or choose an agent.

In Neovim, run `:DevRepositories`. The command loads candidates asynchronously;
run it again while loading to cancel. Select a repo to browse its files without
changing the editor cwd or restoring a session. Native Projects (`p` /
`<leader>fp`), recent files, project.nvim history and persistence remain native.
The implementation uses a custom Snacks picker, independently of the default
LazyVim picker. Nothing is queried during editor startup.

Television offers selection without an action:

```bash
repo_path="$(tv dev-repos)" && [ -n "$repo_path" ] &&
  dev-projects open "$repo_path" --tool sidecar
```

`dev repo list` is a full local inventory. Request it on demand rather than on
every keystroke. A failed source remains an error, not an empty successful list.
This helper never reads dev's private presentation cache.

## Optional Sidecar import

Sidecar can open an unregistered checkout with `--project`; its native `@`
switcher lists configured Projects. To add selected repos to that switcher:

```bash
dev-projects sidecar-import --repo /absolute/repo --json
# Review add/already_present/name_conflict/unavailable, then explicitly apply:
dev-projects sidecar-import --repo /absolute/repo --apply --yes --json
```

Omit `--repo` to preview all current candidates. Apply requires both flags and
does not prompt, so an agent can show the preview before requesting a write.
Matching canonical paths are no-ops even if the native name differs. A name
collision is reported instead of renaming or replacing an entry. Missing
source repos never delete destination projects. No `--switch` is sent.

This is add-only import, not full mirroring. No ownership ledger is needed for
repeat imports. Rename, move, removal, editor session state, td issues and
usage histories are outside this adapter.

The Sidecar 1.14 project API rewrites its configuration and has no cross-process
CAS/batch transaction. Import refuses unsupported per-project fields it cannot
preserve; it still must not run concurrently with another config writer. It
rechecks before each addition, verifies afterward and reports partial/unknown
outcomes without retrying or undoing successful additions. JSON formatting can
change through the native CLI.

Use an isolated config for the first trial:

```bash
trial_dir="$(mktemp -d)"
printf '{}\n' > "$trial_dir/config.json"
XDG_STATE_HOME="$trial_dir/state" dev-projects sidecar-import \
  --config "$trial_dir/config.json" --repo /absolute/repo --json
XDG_STATE_HOME="$trial_dir/state" dev-projects sidecar-import \
  --config "$trial_dir/config.json" --repo /absolute/repo --apply --yes --json
```

`DEV_PROJECTS_DEV` and `DEV_PROJECTS_SIDECAR` select an executable path for
testing; they are not shell command strings. All commands print structured JSON
where applicable and diagnostics on stderr. See `dev-projects --help` for exit codes.

## Other project-like tools on this host

| Tool | Source / owner | Integration boundary |
|---|---|---|
| dev REPOS | configured repo discovery and optional catalog metadata | local candidate source |
| Sidecar Projects | named native project configuration | explicit add-only import |
| LazyVim Projects | util.project history or selected native picker | separate Dev Repositories view |
| sesh | live tmux, named config, zoxide | pass a chosen path; optional generated `import` fragment is future work |
| Herdr / herdr-plus | live workspaces / project layout recipes | existing cwd launch; no catalog/session mirroring |
| Television herdr-sesh | live Herdr workspaces and zoxide | independent `dev-repos` candidate channel |
| zoxide / lazygit recents | actual usage history | do not periodically seed every repo |
| persistence / tmux restore / Zellij | saved editor or terminal state | restore only through the native tool |
| Worktrunk / Workmux | Git worktrees and launch/merge/remove flows | select one lifecycle owner per trial |
| Ruby try-cli | scratch directory lifecycle | keep separate from ordinary repo candidates |
| Yazi | file navigation; no configured project-bookmark plugin | open a selected directory |

The current LazyVim install has `util.project` enabled with the older fzf
default, while `projects.lua` configures the separate Snacks Projects finder.
Changing the latter does not necessarily change dashboard `p`. Confirm the
active keymap when changing either; this helper leaves both intact.

## Worktree trial and task tracking

The [dev-cli workflow trial](https://github.com/daviddwlee84/dev-cli/tree/main/contrib/worktree-trial)
creates independent Herdr/dev and Sidecar Go examples, isolated settings and a
manual feedback checklist. It tests navigation and cleanup without requiring
`dev work start`. PR-open branches remain active; cleanup follows main ancestry,
writer exit and reviewed residual files. A transcript filename is not a blanket
discard rule. Existing dev task commands are not deprecated by this prototype.

## Sources and validation

- [Sidecar project switching](https://github.com/marcus/sidecar/blob/v1.14.0/website/docs/project-switching.md)
- [Sidecar project CLI](https://github.com/marcus/sidecar/blob/v1.14.0/internal/cli/project.go)
- [LazyVim project extra](https://www.lazyvim.org/extras/util/project)
- [sesh 2.22 import support](https://github.com/joshmedeski/sesh/blob/v2.22.0/configurator/configurator.go)

Focused checks: `python3 -m unittest discover -s tests/unit -p test_dev_projects.py`;
the Neovim adapter has an isolated headless test under `tests/unit/`. Neither
check opens the user's editor session or imports into the real Sidecar config.

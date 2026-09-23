# Browser tools for agents

The `devtools` role offers **terminal-browser** and **Playwright CLI** on supported
desktop and server hosts. Their independent `installTerminalBrowser` and
`installPlaywrightCli` switches default to true; minimal/cloud-vm bundles and
Docker builds disable both. Neither depends on GUI or other JS/agent toggles.

**Chromium is downloaded on demand by default.** `preloadPlaywrightChromium=false`
keeps apply and npm upgrades from downloading browser engines. Before first use:

```bash
playwright-cli install-browser chromium
# Linux, if Chromium libraries are not already installed (may require sudo):
playwright-cli install-browser --with-deps chromium
```

Setting `preloadPlaywrightChromium=true` opts into automatic download, runtime
verification and cache repair on apply/upgrade. It only takes effect when
`installPlaywrightCli=true`. Disabling an install option preserves existing
binaries, skills and caches; it is not an uninstall command.

Installed sizes measured on this macOS arm64 host: terminal-browser 0.8.1 about
307 MB (engine included), Playwright CLI 0.1.21 about 18 MB, matching Chromium +
headless shell + FFmpeg about 559 MB. Old revisions and other projects can grow
the shared cache further. terminal-browser cannot separate its bundled engine.

Configure a host with `dotcfg`, for example:

```bash
dotcfg --set installTerminalBrowser=false installPlaywrightCli=true preloadPlaywrightChromium=false --yes
```

| Task | Use |
| --- | --- |
| Show a site beside the agent, share a visible page, inspect UI together | `terminal-browser` |
| Test independently, inspect console/network, save screenshots or traces | `playwright-cli` |
| Commit repeatable assertions and run regression tests in CI | The project's own Playwright Test dependency |

terminal-browser's `action` interface is **agent-browser compatible**. Playwright
CLI manages its own browser sessions and is headless by default; `--headed`
opens a normal visible browser. Both can click, fill and inspect pages, but
their sessions and element references are separate.

## Why an agent knows these commands

Both packages include **skills**. Agents discover their names/descriptions and
load full instructions when relevant. terminal-browser's own setup/first-use
creates skill symlinks, explaining how a manually installed copy can become
available without an explicit `skills add` command.

This repo links the complete skill directory from the **installed package**,
including references, into `~/.agents/skills/` and existing agent directories.
terminal-browser retains its specialized `~/.codex/skills/` variant. Playwright's
skill comes from the CLI's resolved `playwright-core` dependency, not a floating
GitHub branch. Herdr's skill is separate and does not teach browser commands.

The every-apply `run_after_43_refresh_browser_tools.sh.tmpl` repairs package-owned
symlinks after upgrades, and missing Chromium caches only when preloading is
enabled. Custom skill directories and
unrecognized symlinks are preserved with a message. These skills do not belong in
the npx skills lock. Full `terminal-browser setup` is not run during apply: it can
also modify editor settings. Upstream may still run its own setup on first use.

## Platform and terminal requirements

| Host | Automatic setup |
| --- | --- |
| macOS x64/arm64 | Homebrew cask for terminal-browser; mise npm for Playwright CLI; Chromium needs macOS 14+ |
| Ubuntu 22.04+ / Debian 12+, x64/arm64 | Selected CLI packages; system browser libraries when terminal-browser or Chromium preload is enabled |
| Server with no DISPLAY/Wayland | Same installation; terminal-browser uses headless rendering internally |
| noRoot | User packages/caches/skills; system libraries and AppArmor profile must already be available |
| Older Linux, EL, 32-bit userland | Automatic browser installation skipped with a reason |
| Windows | Outside this repo; terminal-browser currently publishes macOS/Linux builds, although Herdr supports Windows |

Future OS versions still need runtime validation; matching architecture alone
is insufficient. Opt-in preloading verifies Chromium can launch, not just that its
version directory exists. Freshness state lives under
`${XDG_STATE_HOME:-~/.local/state}/dotfiles/browser-tools/`.

**The outer terminal must support Kitty graphics** to display terminal-browser.
Ghostty, Kitty and cmux are suitable; Alacritty is not. Herdr provides pane
control and graphics forwarding, but cannot add graphics support to the outer
terminal. Playwright's headless operations do not require terminal graphics.

No desktop environment or Xvfb is installed on servers. Linux does need the
Electron/Chromium shared libraries. When Ubuntu restricts unprivileged user
namespaces, Ansible invokes the bundled AppArmor helper with `become`, granting
the specific executable access. It does not disable AppArmor globally or add
`--no-sandbox`. `--skip-tags sudo` skips those privileged changes.

## Local usage

Inside Ghostty + Herdr:

```bash
terminal-browser open http://localhost:3000 --split right
terminal-browser ls
terminal-browser action -- snapshot
# Use references returned by the snapshot; never guess an element ID.
terminal-browser action -- click @e14
terminal-browser action done
```

There is no required Herdr browser plugin or new keybinding. A local HTML path
also works: `terminal-browser open ./report.html --split right`.

For independent automation, install Chromium on demand as above, then explicitly select it:

```bash
playwright-cli -s=review open http://localhost:3000 --browser=chromium
playwright-cli -s=review snapshot
playwright-cli -s=review console
playwright-cli -s=review screenshot
playwright-cli -s=review close
```

Use an isolated session per task. Close only sessions you created. Firefox and
WebKit are optional downloads; project Playwright dependencies stay project-owned.

## Remote usage: two different arrangements

**Recommended for a human preview:** run the browser locally and proxy requests
through the remote host:

```bash
terminal-browser open --ssh my-server http://localhost:3000 --split right
```

Here `localhost:3000` refers to the remote host. Rendering stays local, reducing
latency and SSH bandwidth. The remote host does not need Electron for this mode.
The remote agent does **not** automatically gain control of that local browser;
run `action` locally or use its own remote automation session.

**Remote agent and browser in the same workspace:** SSH into the server or attach
to remote Herdr, then run terminal-browser there. It renders without a desktop,
but sends frames through SSH; the outer terminal and every multiplexer in the
path must support the graphics protocol. Remote Playwright CLI is usually better
for unattended tests because it does not stream a visible UI.

For an interactive preview from a remote Herdr session, run `terminal-browser`
on the **local** machine instead, using `--ssh my-server` as above. Running it
inside remote Herdr sends every rendered frame through Herdr and SSH, and sends
each input event back to the remote browser; this can feel very slow even when
the remote CPU is mostly idle. Keep remote Herdr for the agent and run the
preview locally. A remote agent's `terminal-browser action` does not control
that local browser; issue actions locally or use a separate remote automation
session.

## Install, refresh and upgrade

`chezmoi apply` installs selected missing packages and repairs package-owned skills;
Chromium download/cache repair is opt-in with `preloadPlaywrightChromium=true`.
Existing tools are not upgraded. A focused Ansible run can select
`--tags browser_tools` after Node has been provisioned by `lazyvim_deps`.

```bash
just upgrade-brew              # macOS terminal-browser
just upgrade-terminal-browser  # repo-managed Linux terminal-browser
just upgrade-npm               # Playwright CLI + skills; Chromium only if preload is on
```

Linux installation verifies the official manifest's SHA-256, stages and checks
the new executable, then atomically switches `~/.local/bin/terminal-browser`.
Versions live in `~/.local/share/terminal-browser/releases/`; the previous version
is retained for recovery. Existing manual or package-managed installs are not
migrated. The Linux upgrade skips while browser processes are running. Close
terminal-browser before a Homebrew cask upgrade as well.

If a refresh reports missing libraries or sandbox restrictions, resolve those
first and rerun the browser-tools tasks. A skipped/failed refresh does not mean
the browser is ready. In noRoot mode an administrator must provide the missing
system pieces; there is no automatic sandbox bypass.

## Validation

```bash
python3 -m unittest discover -s tests/unit -p test_browser_tools.py -v
```

Use a disposable local HTML form for runtime smoke tests: open it, snapshot,
fill and click, inspect the resulting text, save a screenshot, and close only
the test session. Repeat on Linux with DISPLAY/WAYLAND_DISPLAY unset and through
SSH before claiming those environments have been verified.

## Upstream references

- [terminal-browser README and SSH model](https://github.com/zenbu-labs/terminal-browser)
- [terminal-browser skill setup](https://github.com/zenbu-labs/terminal-browser/blob/main/cli/src/setup.ts)
- [Playwright CLI](https://github.com/microsoft/playwright-cli)
- [Playwright system requirements](https://playwright.dev/docs/intro#system-requirements)
- [Agent skills](agent-skills.md), [Herdr](herdr.md), [Ghostty](ghostty.md)

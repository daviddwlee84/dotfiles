# Vorssaint evaluation for Apple Silicon Macs

**Status**: P? / deferred
**Effort**: M
**Related**: `TODO.md` · `dot_config/homebrew/Brewfile.darwin.tmpl` · `docs/this_repo/tool-managers.md` · `/Users/david/src/tries/2026-07-09-windows-dotfiles/docs/tools.md`

## Context

2026-08-25 — evaluate [Vorssaint](https://vorssaint.com/) as a free,
open-source, PowerToys-style macOS utility. It includes an independent **Scroll
Direction** feature equivalent to the separately installed
[Scroll Reverser](https://pilotmoon.com/scrollreverser/), but also overlaps with
Raycast, AeroSpace, AltTab and Maccy.

The desired end state is stronger than merely installing the app: chezmoi should
be able to choose the feature set declaratively, so a new Mac needs at most the
macOS permission approvals and no repetitive Vorssaint GUI configuration.

## Investigation

### Current host and official support

- Current host: `MacBookPro16,2`, Intel Core i5 (`amd64`), macOS 26.3.1.
- Homebrew currently offers Vorssaint 3.3.2 and declares both `arch: arm64` and
  macOS 14+ requirements. The cask is not installed.
- Upstream [issue #523](https://github.com/vorssaintapp/vorssaint-utils/issues/523)
  for Intel support remains open. [PR #417](https://github.com/vorssaintapp/vorssaint-utils/pull/417)
  attempted Intel support but was closed without merging.
- This is a high-trust app whose optional features can request Accessibility,
  Screen Recording, System Audio Recording, Full Disk Access and administrator
  access. An unofficial Intel fork/build is therefore not an acceptable
  dotfiles default merely to bypass the cask guard.

Conclusion: the current Intel Mac keeps the supported Scroll Reverser cask.
Only an official Apple Silicon build should enter a future pilot.

### Raycast, Spotlight and launcher overlap

Local state at investigation time:

- Raycast is installed and running. Its saved global hotkey is `Command-49`
  (`Command+Space`).
- macOS Spotlight symbolic hotkey 64 is disabled, so Raycast exclusively owns
  `Command+Space`.
- Vorssaint's source defines Command Bar's default as `Option+Space`; its
  shortcut is off by default and Command Bar is not part of the first-run
  Essential preset.

There is no current key collision if Vorssaint Command Bar stays uninstalled.
There would be a direct collision if Raycast were reset to its usual
`Option+Space` default, and there is substantial behavioral overlap regardless
of shortcut: app/file/settings search, calculations, clipboard, snippets,
emoji, scripts, window actions and process actions.

Treat the Windows precedent as intentional policy: Raycast remains the one
launcher, just as PowerToys Run is disabled in
`/Users/david/src/tries/2026-07-09-windows-dotfiles/docs/tools.md` rather than
competing for `Alt+Space`.

### Scroll Reverser equivalence

Vorssaint does not bundle the Pilotmoon app or its source; it implements the
same outcome independently in `ScrollInverter.swift`:

- It modifies mouse-wheel events while deliberately leaving trackpad natural
  scrolling alone.
- Vertical and horizontal inversion are separate settings.
- Per-app exceptions are supported.
- Accessibility permission is required because it installs a CGEvent tap.

That matches the current Scroll Reverser preferences:

```text
InvertScrollingOn = 1
ReverseTrackpad = 0
```

Never enable both implementations at once. Both intercept scroll events, so
double inversion can cancel the desired behavior and two event taps add needless
complexity. On a future arm64 pilot, verify Vorssaint Scroll Direction first and
remove `scroll-reverser` only after behavior, exceptions and wake/relogin are
proven.

### Declarative/XDG configuration is not available yet

Current source uses `UserDefaults.standard` under bundle domain
`com.vorssaint.utils`, which macOS normally persists through CFPreferences at
`~/Library/Preferences/com.vorssaint.utils.plist`. There is no supported
`$XDG_CONFIG_HOME/vorssaint` file.

Feature state has two layers:

- Hub installation/availability: `featureAvailable.<feature-id>`.
- Feature-specific engagement/settings, for example
  `scrollInverterEnabled`, `scrollInverterHorizontalEnabled` and
  `commandBarShortcutEnabled`.

Pre-seeding only those keys is not reliable on a clean install. Before services
start, `FeaturePreset.prepareFirstRunAvailability()` overwrites every
`featureAvailable.*` key with the Essential preset whenever `hasOnboarded` is
false and `onboardingStep` is zero. Faking the onboarding markers would couple
the dotfiles to private implementation details and could skip useful permission
guidance.

Vorssaint 3.1.15+ can export and import an XML property-list backup containing a
validated settings envelope. This includes registered defaults, feature
availability, snippets and onboarding markers while intentionally excluding
machine-specific/live state. The shipped interface remains GUI-only:

- Export invokes `NSSavePanel`.
- Import invokes `NSOpenPanel`, replaces supported preferences and relaunches.
- `main.swift` exposes only `--selftest`, `--sensors` and `--uninstall`; there is
  no settings import/export/validate/reload command or URL scheme.

The 3.3.2 release note phrase “configuration from the command line” does not add
a declarative settings CLI in the current source. Do not interpret it as support
for headless backup import.

[Upstream issue #497](https://github.com/vorssaintapp/vorssaint-utils/issues/497)
tracks exactly this use case. It was reopened after the reporter clarified that
GUI backup is insufficient; the maintainer said an automated path is planned.
The latest proposal suggests a read-only/symlink-friendly
`~/.config/vorssaint/config.json` plus import, reload and validate commands. As of
2026-08-25 the issue is still open and no format is committed.

Directly deploying the preferences plist or running `defaults write` is rejected:

- The keys are internal and may change rapidly.
- `cfprefsd` caching and a running app can overwrite file-level changes.
- The first-run preset can overwrite availability keys.
- The plist is a foreign-writer surface, not a safe chezmoi-owned config file.
- It still cannot grant macOS privacy permissions.

### Zero-touch setup is bounded by macOS permissions

Even after #497 supplies a stable configuration interface, a normal personal
Mac cannot silently grant TCC permissions. The relevant feature remains inactive
until the user approves Accessibility, Screen Recording, System Audio Recording
or Full Disk Access in System Settings. An MDM PPPC profile could administer some
permissions, but that is outside this personal-dotfiles scope.

Launch at Login is also not a plain boolean. Vorssaint stores intent in
`launchAtLoginWanted` but registers through `SMAppService.mainApp`; macOS may put
the item in `requiresApproval`, which only the user can approve in System
Settings.

The realistic automation target is therefore: **install + restore the desired
feature settings declaratively, then show a short one-time permission checklist**.
It is not “no GUI interaction of any kind.”

### Recommended ownership split for a future arm64 pilot

| Capability | Owner / default | Reason |
|---|---|---|
| Launcher / search / scripts / emoji | Raycast; Vorssaint Command Bar off | Avoid duplicate index, UI and global shortcut |
| Reverse external mouse only | Scroll Reverser on Intel; test Vorssaint Scroll Direction on arm64 | Equivalent behavior; never run both event taps |
| Clipboard history / snippets | Existing Raycast/Maccy setup; Vorssaint off | Avoid duplicate histories and shortcut surfaces |
| Window switching / layouts | AeroSpace + AltTab/Raycast; Vorssaint off | Existing window ownership is already deliberate |
| Per-app volume/output | Evaluate Vorssaint | Complementary capability, with System Audio permission |
| Keep Awake / Quick Toggles / Shelf / Clean URL | Evaluate selectively | Mostly complementary and comparatively low risk |
| Side buttons / Middle Click / Smooth Scroll | Evaluate selectively | Useful mouse extensions; require Accessibility and conflict testing |
| Homebrew Manager / App Updates | Off | Conflicts with this repo's install-only vs `just upgrade-*` split |
| Cleaner / Uninstaller | Off | Destructive surface and may require Full Disk Access |
| Fan Control | Off during pilot | High-impact hardware control; no need in the initial evaluation |

Vorssaint's “extensions” are currently in-tree Feature Hub modules, not an
external Raycast-style plugin ecosystem. The proposed plugin system in
[issue #770](https://github.com/vorssaintapp/vorssaint-utils/issues/770) was
closed, so do not plan around third-party extension installation.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. Install the official cask on this Intel Mac | None beyond immediate experimentation | Homebrew blocks it; unsupported architecture |
| B. Build/install an unofficial Intel fork | Could test sooner | Signing/update provenance, sensors and high-permission feature risk; upstream PR not merged |
| C. Pilot the official app manually on an arm64 Mac | Validates real behavior and overlap | Repeats GUI setup; TCC approval still manual |
| D. Pilot official arm64 after #497 provides stable declarative config/CLI | Reproducible and compatible with chezmoi/XDG goals | Waiting on upstream and an arm64 host |
| E. Manage `defaults write` or the preferences plist now | Technically seeds some values | Unsupported schema, CFPreferences cache, first-run overwrite and no permission automation |

Option D is the target. Option C is acceptable only as a disposable exploratory
spike whose settings are not yet represented as managed state.

## Current blocker / open questions

- Need an official Apple Silicon host/build; the current host is Intel and
  upstream #523 remains open.
- Wait for #497 to define a stable file format or supported headless import,
  reload and validation contract.
- Re-check the stable release and permission behavior when #497 lands; do not
  build against beta-only behavior.
- Confirm which complementary features earn their permissions and idle cost on
  the actual arm64 pilot before replacing any existing app.

## Resume plan after blockers clear

1. Re-read #497 and confirm the interface is documented and present in a stable
   release. Prefer an XDG file; otherwise use the supported CLI import path.
2. Add the official cask only on `.chezmoi.arch == "arm64"`; retain
   `scroll-reverser` on `amd64`. Follow the repo's new-tool mirror requirements
   for README, tool index and upgrade documentation.
3. Encode the ownership matrix above, leaving Command Bar and other overlapping
   features unavailable/off rather than merely unbound.
4. Validate the rendered config with Vorssaint's own validate/import command and
   confirm a second apply is idempotent.
5. Manually approve only the permissions required by selected features, then
   test login, wake, external mouse/trackpad behavior and shortcut conflicts.
6. Remove Scroll Reverser on that arm64 host only after Vorssaint survives the
   pilot; do not create a period where both inverters launch together.

## Decision

2026-08-25 deferred — do not install Vorssaint on the current Intel Mac and do
not automate private UserDefaults keys. Keep Raycast on `Command+Space`, Spotlight
disabled, and Scroll Reverser as the mouse-only inversion owner. Revisit for an
official stable arm64 pilot when upstream #497 exposes a supported declarative
configuration path; TCC approvals remain an explicit one-time manual step.

## References

- [Vorssaint repository](https://github.com/vorssaintapp/vorssaint-utils)
- [Vorssaint releases](https://github.com/vorssaintapp/vorssaint-utils/releases)
- [Feature #497: Store settings in a folder](https://github.com/vorssaintapp/vorssaint-utils/issues/497)
- [Feature #523: Allowing Intel Mac use](https://github.com/vorssaintapp/vorssaint-utils/issues/523)
- [PR #417: Intel architecture support](https://github.com/vorssaintapp/vorssaint-utils/pull/417)
- [Feature #770: extension/plugin system](https://github.com/vorssaintapp/vorssaint-utils/issues/770)
- [Feature presets source](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/Core/FeaturePresets.swift)
- [Settings backup source](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/Services/SettingsBackup.swift)
- [Settings backup schema](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/Core/SettingsBackupSupport.swift)
- [Launch at Login source](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/Services/LaunchAtLogin.swift)
- [Scroll Direction implementation](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/Services/ScrollInverter.swift)
- [Scroll Reverser source](https://github.com/pilotmoon/scroll-reverser)
- [Raycast hotkey documentation](https://manual.raycast.com/hotkey)
- [Feature overview video supplied during evaluation](https://youtu.be/s8dzlv4WuNk?is=-enYAbI7jpgCHy9L)

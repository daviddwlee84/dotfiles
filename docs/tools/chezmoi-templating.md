# chezmoi templating conventions

A short guide to deciding which knob to branch on in a chezmoi template: `.profile` (a user role we prompt for at init), `.chezmoi.os` / `.chezmoi.arch` (auto-detected facts), `.chezmoi.hostname` (per-machine overrides), or an env var like `WORK_MACHINE` (per-session).

This doc exists because it's easy to encode OS/arch facts as new `.profile` values (we did this with `macos_intel`) and end up with conditionals like `or (eq .profile "macos") (eq .profile "macos_intel")` scattered across eight templates. The fix is: let auto-detectable facts come from `.chezmoi.*` and keep `.profile` for what the user genuinely has to tell us.

Upstream references:

- [Manage machine-to-machine differences](https://www.chezmoi.io/user-guide/manage-machine-to-machine-differences/) — overview and patterns
- [Template variables](https://www.chezmoi.io/reference/templates/variables/) — the full list of `.chezmoi.*` fields
- [Init functions → promptChoiceOnce](https://www.chezmoi.io/reference/templates/init-functions/promptChoiceOnce/) — validated one-shot prompt

## Decision table

Pick the **narrowest** knob that correctly expresses the predicate.

| Knob | What it answers | Where it comes from | Typical values | When to use |
|---|---|---|---|---|
| `.chezmoi.os` | What OS am I on? | Auto-detected (`runtime.GOOS`) | `darwin`, `linux`, `windows`, `freebsd`, … | OS-specific paths, package managers (brew vs apt), kernel-level features |
| `.chezmoi.arch` | What CPU arch? | Auto-detected (`runtime.GOARCH`) | `amd64`, `arm64`, `arm`, `386`, … | Binary availability (Apple Silicon-only casks, armv7l fallbacks) |
| `.chezmoi.kernel.osrelease` | Distro info on Linux | `/proc/sys/kernel/osrelease` | contains `microsoft` on WSL | Distinguishing WSL from native Linux |
| `.chezmoi.hostname` | Which machine? | `os.Hostname()` | `work-laptop`, `rpi5`, … | Per-machine overrides (a single misbehaving host) |
| `.profile` (this repo) | What **role** does the user want? | `promptChoiceOnce` at init | `macos`, `ubuntu_desktop`, `ubuntu_server` | Desktop vs server (GUI packages, nerdfonts, alacritty) — **not** auto-detectable |
| `env "WORK_MACHINE"` | Is this machine in work mode right now? | Shell env at `chezmoi apply` time | unset / `1` | Per-session toggles (skip gaming casks) |

## Rule

> If the predicate is **auto-detectable** (OS, CPU arch, kernel flavour, hostname), branch on the matching `.chezmoi.*` variable.
>
> Only introduce a new `.profile` value when the predicate is a **user preference** that cannot be auto-detected — for example, "this is a headless server, skip GUI tools".

Anti-pattern: adding a `.profile` value to encode a distinction chezmoi already knows. The historical example in this repo was `macos_intel` (= darwin + amd64), which forced every macOS-specific branch to become `or (eq .profile "macos") (eq .profile "macos_intel")` because most macOS logic is the same on both architectures. The fix is two cheap built-ins: `.chezmoi.os` for the OS-wide branches, `.chezmoi.arch` for the small number of arm64-only binaries.

## Cheat-sheet: common patterns

### macOS vs Linux (any macOS)

```go-template
{{ if eq .chezmoi.os "darwin" -}}
# macOS-only block
{{ else if eq .chezmoi.os "linux" -}}
# Linux-only block
{{ end -}}
```

### Apple Silicon only (not Intel Mac)

```go-template
{{ if and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "arm64") -}}
cask "chatgpt"  # arm64-only release
{{ end -}}
```

Inside a file that is only consumed on macOS anyway (e.g. `Brewfile.darwin`), the `.chezmoi.os` part is redundant — `eq .chezmoi.arch "arm64"` alone is enough.

### Intel macOS only

```go-template
{{ if and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "amd64") -}}
# Intel-Mac-specific fix
{{ end -}}
```

Or in the inverted early-exit form:

```go-template
{{ if or (ne .chezmoi.os "darwin") (ne .chezmoi.arch "amd64") -}}
exit 0  # Not Intel macOS — nothing to do
{{ end -}}
```

### Desktop vs server (user role — cannot auto-detect)

```go-template
{{ if or (eq .chezmoi.os "darwin") (eq .profile "ubuntu_desktop") -}}
# Install GUI dependencies (Bitwarden Desktop, etc.)
{{ end -}}
```

macOS is always a "desktop" from our point of view, so the OS check covers it; on Linux the user has to tell us via `ubuntu_desktop` vs `ubuntu_server`.

### WSL

```go-template
{{ if and (eq .chezmoi.os "linux") (contains "microsoft" (lower .chezmoi.kernel.osrelease)) -}}
# WSL-specific tweaks
{{ end -}}
```

## This repo's profile values

Kept deliberately small (3 values, user-role only):

| Profile | What it means | Auto-derived default at init |
|---|---|---|
| `macos` | macOS desktop (any architecture) | when `.chezmoi.os == "darwin"` |
| `ubuntu_desktop` | Ubuntu with GUI — wants `nerdfonts`, `alacritty`, etc. | — |
| `ubuntu_server` | Headless Ubuntu — skip GUI packages | when `.chezmoi.os == "linux"` |

The prompt lives in [`.chezmoi.toml.tmpl`](../../.chezmoi.toml.tmpl) and uses `promptChoiceOnce`, which validates the answer against the list above.

## Migrating from `macos_intel`

Before this refactor, Intel Macs were a fourth profile (`macos_intel`). Every OS-wide macOS branch had to be written as `or (eq .profile "macos") (eq .profile "macos_intel")`, and Intel-only code simply asked `eq .profile "macos_intel"`. After the refactor:

- OS-wide macOS branches → `eq .chezmoi.os "darwin"`
- Intel-only code → `and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "amd64")`
- Apple-Silicon-only code → `eq .chezmoi.arch "arm64"` (inside darwin-scoped files)

**If your existing `~/.config/chezmoi/chezmoi.toml` has `profile = "macos_intel"`**, do one of:

```bash
# Option A: edit in place
sed -i '' 's/"macos_intel"/"macos"/' ~/.config/chezmoi/chezmoi.toml
chezmoi apply

# Option B: re-run the init prompt
chezmoi init --force
```

After either option, `chezmoi apply --dry-run` should show no diff that depends on the old profile value.

## See also

- [chezmoi-prefixes.md](chezmoi-prefixes.md) — filename prefix reference (`dot_`, `private_`, `create_`, `modify_`, …) and the `chezmoi add` safety table
- [`.chezmoi.toml.tmpl`](../../.chezmoi.toml.tmpl) — the prompt definitions

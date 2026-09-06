# `"rg" is an app downloaded from the Internet. Are you sure you want to open it?`

**Symptom** — a macOS Gatekeeper dialog fires on essentially every `rg`
invocation, mid-agent-turn:

```
"rg" is an app downloaded from the Internet. Are you sure you want to open it?
Homebrew Cask downloaded this file today at 14:28. Apple checked it for
malicious software and none was detected.
                                                        [ Cancel ]  [ Open ]
```

The subtitle names **Homebrew Cask**, which sends you looking at the `ripgrep`
formula. That is the wrong `rg`.

## What is actually happening

The **`codex` cask** (the OpenAI Codex CLI) does not just install an app bundle.
Its payload contains a `codex-path/` directory of vendored CLIs, and Codex
**prepends that directory to `PATH`** inside the shell it runs commands in:

```
$ command -v rg
/usr/local/bin/rg                                   # Homebrew ripgrep, clean

$ ls /usr/local/Caskroom/codex/0.153.4/codex-path/
rg                                                  # ← the one that prompts

# inside a codex shell, PATH entry #1:
/usr/local/Caskroom/codex/0.153.4/codex-path
```

Every file Homebrew unpacks from a **cask** download carries
`com.apple.quarantine`; formulae (bottles) do not. So the vendored copy prompts
and the Homebrew one never does:

```
$ xattr -l /usr/local/Cellar/ripgrep/15.2.0/bin/rg
com.apple.provenance:

$ xattr -l /usr/local/Caskroom/codex/0.153.4/codex-path/rg
com.apple.provenance:
com.apple.quarantine: 03c1;6a9d0808;;84327DB6-EBF9-4275-80DC-4F15716D3077
```

Gatekeeper prompts on the **first exec of each quarantined binary**, so the
dialog reappears after every `brew upgrade --cask codex` — which is what
`just upgrade-brew` runs — and the timestamp in the dialog always matches that
upgrade, never the original install.

## Diagnosis

```bash
which -a rg                                   # is it even the formula?
xattr -r -p com.apple.quarantine "$(brew --prefix)/Caskroom/codex"
```

`xattr -r -p` **exits 1 whenever any walked file lacks the attribute**, so test
on stdout being non-empty, never on the exit code.

## Fix

Immediate:

```bash
xattr -dr com.apple.quarantine "$(brew --prefix)/Caskroom/codex"
```

Managed, in `dot_ansible/roles/coding_agents/tasks/main.yml`:

- the cask install carries `install_options: no-quarantine` and the repair path
  uses `brew reinstall --cask --no-quarantine codex` — this covers **fresh
  installs only**;
- a **"Strip Gatekeeper quarantine from the Codex cask payload"** task sweeps
  the Caskroom on every apply, because `--no-quarantine` cannot retroactively
  cover a payload that `brew upgrade --cask` has already re-quarantined.

Both are needed. `--no-quarantine` alone regresses at the next upgrade; the
sweep alone leaves a window between install and the next `chezmoi apply`.

## Generalisable

Any Homebrew **cask** that ships helper CLIs and puts them on `PATH` has this
shape. The tell is a Gatekeeper dialog naming a tool you are sure you installed
via a formula — check `which -a`, then the Caskroom, before touching the tool
you think it is complaining about.

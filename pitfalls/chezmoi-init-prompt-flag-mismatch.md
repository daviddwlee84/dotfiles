# `chezmoi init --prompt*` flag silently ignored when prompt text doesn't match

## Symptom

A `docker build` (or `chezmoi init --apply` over SSH / in any TTY-less
environment) fails at the very last step with:

```
chezmoi: template: chezmoi.toml:23:16: executing "chezmoi.toml" at
<promptChoiceOnce . "profile" "Which profile" $profileChoices $defaultProfile>:
error calling promptChoiceOnce: could not open a new TTY: open /dev/tty:
no such device or address
```

…even though the build script clearly passes a flag that *looks* like it
should pre-answer the prompt:

```dockerfile
RUN ~/.local/bin/chezmoi init --apply --source=/tmp/dotfiles-source \
    --promptString "profile (ubuntu_server|ubuntu_desktop|macos|centos_server)=centos_server" \
    ...
```

The bug is invisible when the value being passed happens to equal the
template's default (e.g. on Linux `$defaultProfile = "ubuntu_server"`
and the build also passes `ubuntu_server`). It fires only when the
override differs from the template default.

## Root cause

`chezmoi init`'s `--promptBool` / `--promptString` / `--promptChoice`
flags **match by the prompt text** (3rd argument to `promptXOnce` in
the template), not by the key name (2nd argument). They are also
**type-strict**: a `--promptString` flag will not satisfy a
`promptChoiceOnce` template call.

In our `.chezmoi.toml.tmpl`:

```
$profile := promptChoiceOnce . "profile" "Which profile" $profileChoices $defaultProfile
```

The matchable prompt text is **`Which profile`**, and the matching flag
type is **`--promptChoice`**. The pre-fix Dockerfile passed the wrong
flag type AND the wrong text:

```
--promptString "profile (ubuntu_server|ubuntu_desktop|macos|centos_server)=..."
```

Two failures stacked:

1. `--promptString` cannot answer a `promptChoiceOnce` call (type
   mismatch). chezmoi silently ignores the unmatched flag.
2. Even if the flag type were `--promptChoice`, the text
   `profile (ubuntu_server|...)` doesn't equal `Which profile` — still
   no match.

When no flag matches, chezmoi falls back to interactive prompting; in a
Docker `RUN` step there is no TTY, so it errors out.

**Why the Ubuntu Dockerfile appeared to work**: chezmoi's
`promptChoiceOnce` returns the template's default value when no
existing config file exists *and* no matching flag is supplied. The
default on Linux happens to be `ubuntu_server`, which also happens to
be the default value of `CHEZMOI_PROFILE` in the existing Dockerfile.
Coincidence kept the bug latent. The first `docker build` that
overrode `CHEZMOI_PROFILE=centos_server` (i.e. our Dockerfile.centos7
/ Dockerfile.rocky9) blew up immediately. The `desktop` compose
service that sets `CHEZMOI_PROFILE=ubuntu_desktop` was almost
certainly broken too — just nobody ran `just docker-desktop` often
enough to notice.

## Fix

Use `--promptChoice` (matching the template's `promptChoiceOnce` call
type) and quote the actual prompt text verbatim:

```dockerfile
--promptChoice "Which profile=${CHEZMOI_PROFILE}" \
```

`scripts/init/dotfiles_init.py` was already doing this correctly
(`argv += ["--promptChoice", f"{by_key['profile'].prompt_text}={...}"]`)
because its `Prompt` records carry both `key` and `prompt_text` and it
uses the latter for flag generation. The Dockerfile predates that
wrapper and was never updated when the prompt text in the template
diverged from the key.

## Why `dotfiles_init.py doctor` didn't catch this

The `doctor` subcommand only verifies that **ARG names** in the
`Dockerfile` match the prompt **keys** in `.chezmoi.toml.tmpl` and
`PROMPTS` in `dotfiles_init.py`. It doesn't parse the actual `--prompt*`
flag text used in the `RUN ~/.local/bin/chezmoi init …` block, so
flag-text drift is invisible to it.

A future enhancement would be: in `doctor_scan`, also regex-extract
`--prompt(String|Bool|Choice)\s+"([^=]+)=` from the Dockerfile's
`chezmoi init` invocation and assert that text matches the template's
prompt text for that key. Tracked in `TODO.md` as `[P2][S] doctor:
verify Dockerfile --prompt* flag text matches template`.

## Related

- `scripts/init/dotfiles_init.py` — wrapper that does it right; the
  comment above `_chezmoi_argv` explains the prompt-text rule
  ("Verified empirically against chezmoi 2.68.0 / 2.69.4 / 2.70.2 …").
- `Dockerfile` / `Dockerfile.centos7` / `Dockerfile.rocky9` — the
  three places where `chezmoi init --prompt*` is called from a
  `RUN` step. All three must use prompt-text form, not key-name form.
- `pitfalls/centos7-noroot.md` — sibling pitfall surfaced by the same
  CentOS install-test infrastructure that triggered this debug.
- `CLAUDE.md` → "Dockerfile + dotfiles_init wrapper" invariant —
  documents the parity requirement; this pitfall is the reason
  doctor's text-level check would be a worthwhile extension.

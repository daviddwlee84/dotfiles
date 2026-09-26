# Ansible fails with "unknown field `isolated`" from an old mise

## Symptoms

`chezmoi apply` stops in a role that shells out to mise (for example
`bitwarden : Install Bitwarden CLI via mise npm`):

```console
Error loading settings file: TOML parse error at line 11, column 8
11 | dotnet.isolated = true
   |        ^^^^^^^^
unknown field `isolated`, expected `package_flags` or `registry_url`
```

## Cause

`dot_config/mise/config.toml.tmpl` uses settings added in newer mise releases.
Bootstrap only checks that *a* mise exists, so a long-lived host keeps an old
Homebrew mise (seen: 2026.2.9) that cannot parse the managed config. Every
`mise exec` then fails.

## Fix

Upgrade mise through its current owner, then re-run the apply:

```sh
brew upgrade mise        # Homebrew-owned mise
mise self-update         # self-managed ~/.local/bin/mise
chezmoi apply
```

Prevention idea: have bootstrap compare `mise --version` with the minimum the
config needs and upgrade (or warn) before ansible runs.

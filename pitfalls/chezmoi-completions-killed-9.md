# chezmoi apply ends with generate_completions.sh: Killed: 9

**Symptoms**: `generate_completions.sh: line 83`, `Killed: 9`, `"$runner" $zargs`, `"$runner" $bargs`; Ansible and Brew report success first.
**First seen**: 2026-09
**Affects**: macOS arm64; observed with the old steipete/tap summarize 0.10.0 binary.
**Status**: local package repaired; invalid completion registration removed and generator diagnostics fixed.

## Symptom

```text
generate_completions.sh: line 83: 12248 Killed: 9                  "$runner" $zargs > "$zfile.tmp" 2> /dev/null
generate_completions.sh: line 83: 12251 Killed: 9                  "$runner" $bargs > "$bfile.tmp" 2> /dev/null
```

The line number points at `regen()`, not the inventory row. One invocation per
shell produces two failures. The old full-run `--quiet` path hid both the tool
name and the accumulated failure count.

## Root cause

On the affected host, only summarize had missing/stale completion files.
`~/Library/Logs/DiagnosticReports/summarize-*.ips` recorded:

```text
SIGKILL (Code Signature Invalid)
namespace: CODESIGNING
indicator: Invalid Page
```

`codesign --verify --verbose=2 /opt/homebrew/bin/summarize` independently reported
`invalid signature (code or signature have been modified)`. Its Homebrew receipt
identified a legacy steipete/tap 0.10.0 Mach-O release; the current homebrew/core
package uses Node. These observations establish a signature failure, not what
originally damaged the signature. There was no evidence of an OOM kill.

After replacing that package, summarize 0.22.0 started normally but revealed a
second error in the dotfiles inventory:

```text
error: too many arguments. Expected 1 argument but got 2: completion, zsh.
```

Its CLI does not provide `completion zsh` or `completion bash`. Reinstallation
alone therefore cannot fix the completion hook.

## Repair and verification

Repair the named package through its owner; do not disable macOS signature
checks or blindly re-sign an invalid binary. On this host:

```sh
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
  HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall --formula summarize
summarize --version
```

Homebrew installed 0.22.0 and updated its required dependencies (including Node
and FFmpeg). This is an explicit repair, not a new apply-time upgrade policy.
Then remove the unsupported summarize row from `scripts/generate_completions.sh`
and run the remaining inventory:

```sh
bash scripts/generate_completions.sh --quiet
```

An independent Brew warning about a `libtiff, webp` cycle came from the installed
WebP 1.6.0 receipt still listing libtiff while the newer libtiff depends on WebP.
Reinstalling WebP's current bottle refreshed its actual payload and receipt;
forcing both libraries out with `--ignore-dependencies` was unnecessary.

## Prevention

- Register only completion commands verified against the actual CLI.
- Keep failure warnings visible under `--quiet`, including tool, shell and exit
  status. Full runs remain best-effort; targeted runs return nonzero.
- Keep existing cache files on failure and remove partial output.
- Regression coverage: `tests/unit/generate_completions.bats` exercises real
  SIGKILL, normal command failure, empty output, continuation and cached success.

## Related

- [Completion architecture](../docs/zsh/zsh-completions.md)
- [summarize](../docs/tools/summarize.md)

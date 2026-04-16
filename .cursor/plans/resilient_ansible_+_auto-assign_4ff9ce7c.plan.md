---
name: Resilient ansible + auto-assign
overview: Add a `allowPartialFailure` chezmoi option that runs Ansible tags independently so one failing role doesn't block others, and auto-assign macOS-only options (like `installAiDesktopApps`) to `false` on non-macOS profiles so they aren't prompted during init.
todos:
  - id: add-chezmoi-option
    content: Add `allowPartialFailure` promptBoolOnce to `.chezmoi.toml.tmpl`
    status: completed
  - id: conditional-ai-apps
    content: Wrap `installAiDesktopApps` in macOS-only conditional in `.chezmoi.toml.tmpl`
    status: completed
  - id: modify-runner-script
    content: Add per-tag execution mode to `run_onchange_after_20_ansible_roles.sh.tmpl` when `allowPartialFailure` is true
    status: completed
  - id: update-dockerfile
    content: Add `CHEZMOI_ALLOW_PARTIAL_FAILURE` ARG and `--promptBool` to Dockerfile
    status: completed
  - id: syntax-check
    content: Run ansible syntax check and verify template rendering
    status: completed
isProject: false
---

# Resilient Ansible Execution + Auto-assign Platform-specific Options

## Problem

1. A single download timeout (e.g. `td` tarball) in one Ansible role causes the **entire** playbook to fail, preventing all subsequent roles from running.
2. Options like `installAiDesktopApps` (macOS Homebrew casks only) are prompted even on Linux profiles where they have no effect.

## Feature 1: Allow Partial Failures (`allowPartialFailure`)

### Approach: Per-tag execution in the shell script

Instead of modifying `ignore_errors` across dozens of download tasks in every Ansible role, we change the runner script ([`run_onchange_after_20_ansible_roles.sh.tmpl`](run_onchange_after_20_ansible_roles.sh.tmpl)) to run each tag **independently** when the option is enabled. If a tag fails, the script logs a warning and continues to the next one.

```bash
# When allowPartialFailure is true:
FAILED_TAGS=()
IFS=',' read -ra TAG_ARRAY <<< "$TAGS"
for tag in "${TAG_ARRAY[@]}"; do
    info "Running tag: $tag"
    ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --tags "$tag" \
        $BECOME_FLAGS "${EXTRA_VARS_ARGS[@]}" || {
        warn "Tag '$tag' had failures (continuing in best-effort mode)"
        FAILED_TAGS+=("$tag")
    }
done
if [[ ${#FAILED_TAGS[@]} -gt 0 ]]; then
    warn "Failed tags: ${FAILED_TAGS[*]}"
    warn "Retry: ansible-playbook ... --tags '$(IFS=,; echo "${FAILED_TAGS[*]}")'"
fi

# When allowPartialFailure is false (default): single call as today
ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --tags "$TAGS" ...
```

**Why per-tag instead of `ignore_errors` on tasks:**
- Only ONE file changes (the shell script), no Ansible role modifications
- Each role runs independently; a `coding_agents` timeout doesn't block `devtools`
- Ansible output still shows the full error for debugging
- The summary at the end shows exactly which tags failed and the command to retry them

### Changes

- [`.chezmoi.toml.tmpl`](.chezmoi.toml.tmpl) -- add `allowPartialFailure` prompt (default: `false`)
- [`run_onchange_after_20_ansible_roles.sh.tmpl`](run_onchange_after_20_ansible_roles.sh.tmpl) -- conditional per-tag execution logic
- [`Dockerfile`](Dockerfile) -- add `ARG CHEZMOI_ALLOW_PARTIAL_FAILURE=false` and corresponding `--promptBool` flag

## Feature 2: Auto-assign macOS-only Options by Profile

### Analysis of which options are platform-specific

- **`installAiDesktopApps`** -- **macOS-only**: only drives `Brewfile.darwin.tmpl` casks (Claude, ChatGPT, etc.). No Linux equivalent. Should be auto-assigned `false` on non-macOS profiles.
- **`installBrewApps`** -- **Cross-platform** (controls Homebrew Bundle on both macOS and Linux). Keep prompting on all profiles.
- **`installInputMethod`** -- **Cross-platform** (casks on macOS, `ibus-rime` via apt on Linux). Keep prompting.
- **`installBitwarden`** -- **Cross-platform** (CLI everywhere, desktop gated by profile in runner script). Keep prompting.

### Approach: Conditional prompts in chezmoi template

Use the already-set `.profile` value to gate prompts. Since `promptStringOnce` mutates the data store (`.`) in place, `.profile` is available for subsequent template expressions.

```
{{ if or (eq .profile "macos") (eq .profile "macos_intel") -}}
installAiDesktopApps = {{ promptBoolOnce . "installAiDesktopApps" "Install AI desktop apps via macOS Homebrew Brewfile ..." false }}
{{ else -}}
installAiDesktopApps = false
{{ end -}}
```

### Changes

- [`.chezmoi.toml.tmpl`](.chezmoi.toml.tmpl) -- wrap `installAiDesktopApps` in macOS-only conditional

## Files to Modify

- [`.chezmoi.toml.tmpl`](.chezmoi.toml.tmpl) (2 changes: add `allowPartialFailure`, conditionally prompt `installAiDesktopApps`)
- [`run_onchange_after_20_ansible_roles.sh.tmpl`](run_onchange_after_20_ansible_roles.sh.tmpl) (per-tag execution block)
- [`Dockerfile`](Dockerfile) (add new build ARG + `--promptBool`)

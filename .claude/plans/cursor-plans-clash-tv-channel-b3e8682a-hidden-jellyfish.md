# Context

The `tv clash` channel (commit `00dcc99`) is fully implemented: all five Ctrl+S sources, three Ctrl+F preview views, and all Alt+ actions exist and are committed. The YAML-parsing path (proxies/groups/rules/summary) always works. The API path reads `external-controller` **from the local Clash config YAML** — if the user's local Clash for Windows doesn't expose the API or the local config has no `external-controller`, the API mode silently falls back to "unreachable".

The user's situation:
- Local Clash for Windows (macOS): API unclear / may not be configured
- Remote controller: `192.168.222.207:9090` (Clash dashboard confirmed reachable)
- Want to use the remote controller for API-dependent features without editing the local config

## Decision: single channel + `CLASH_CONTROLLER` env var (no split)

Splitting into a "YAML-only" and "API-only" channel is unnecessary — the existing channel already degrades gracefully between the two modes. The gap is the missing **override** for the controller endpoint. Adding `CLASH_CONTROLLER` (and `CLASH_SECRET`) env vars is the minimal, backward-compatible fix.

Usage after this change:
```bash
CLASH_CONTROLLER=192.168.222.207:9090 tv clash          # no secret
CLASH_CONTROLLER=192.168.222.207:9090 CLASH_SECRET=xxx tv clash
```
Or set them permanently in `~/.config/zsh/` for the 207 context.

---

## Files to edit (3 files, small changes each)

### 1. `dot_config/television/executable_clash-parse.py`

**Function**: `cmd_controller()` (line 243)

Current:
```python
def cmd_controller(cfg: dict) -> tuple[str, str]:
    host = cfg.get("external-controller", "") or ""
    secret = cfg.get("secret", "") or ""
    return str(host), str(secret)
```

New (env var takes precedence):
```python
def cmd_controller(cfg: dict) -> tuple[str, str]:
    host = os.environ.get("CLASH_CONTROLLER", "").strip() or (cfg.get("external-controller", "") or "")
    secret = os.environ.get("CLASH_SECRET", "").strip() or (cfg.get("secret", "") or "")
    return str(host), str(secret)
```

All action scripts in `clash.toml` call `clash-parse.py controller` — this single change propagates to `actions.switch_proxy`, `actions.close_connections`, `actions.reload_config`, `actions.open_dashboard` automatically.

### 2. `dot_config/television/executable_clash-source.sh`

**Section**: `api)` block, lines 47–57 (controller resolution)

Add env var check before the `run_parse controller` call:
```bash
api)
    ctrl_host="${CLASH_CONTROLLER:-}"
    ctrl_secret="${CLASH_SECRET:-}"
    if [ -z "$ctrl_host" ]; then
      {
        read -r ctrl_host || true
        read -r ctrl_secret || true
      } < <(run_parse controller)
    fi
    # ... rest unchanged
```

### 3. `dot_config/television/executable_clash-preview.sh`

**Function**: `_controller()` (lines 50–60)

Add env var short-circuit before calling `$PARSE controller`:
```bash
_controller() {
  # CLASH_CONTROLLER env var overrides the config value
  if [ -n "${CLASH_CONTROLLER:-}" ]; then
    printf '%s\n%s\n' "$CLASH_CONTROLLER" "${CLASH_SECRET:-}"
    return 0
  fi
  if [ ! -x "$PARSE" ]; then
    printf '\n\n'
    return 0
  fi
  if ! command -v uv >/dev/null 2>&1; then
    printf '\n\n'
    return 0
  fi
  "$PARSE" controller 2>/dev/null || printf '\n\n'
}
```

---

## No changes needed

- `cable/clash.toml` — actions already call `clash-parse.py controller`; the parse script fix propagates. No inline `clash-source.sh` / `clash-preview.sh` changes to TOML needed.
- `.gitleaks.toml` — env var names (`CLASH_CONTROLLER`, `CLASH_SECRET`) don't contain secrets; no new rules needed.
- `docs/tools/tv.md` — add one paragraph under the existing clash section noting the two env var overrides.

---

## Verification

1. **Without env var** (no regression): `tv clash` continues to read `external-controller` from local config; graceful "unreachable" row if controller absent.
2. **With env var pointing at 207**:
   ```bash
   CLASH_CONTROLLER=192.168.222.207:9090 tv clash
   ```
   - API source row shows `healthy`, version info from 207 controller
   - Latency preview uses `/proxies/:name/delay` against 207
   - Alt+T, Alt+S, Alt+C, Alt+R all operate against 207
3. **Manual smoke** of each action: Alt+R should prompt before reload (uses the on-disk path from local YAML, even when controller is remote — this is correct behavior; the 207 machine loads its own config independently).

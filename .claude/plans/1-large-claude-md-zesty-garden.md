# Plan: Improve claude-hud Usage Display for Max Plan

## Context

The user has a Max plan subscription and wants claude-hud's status bar to show detailed usage similar to CodexBar — separate Session/Weekly windows with "% left" format and Sonnet-specific limits.

**Current state** (claude-hud v0.0.10 status bar):
```
[Sonnet 4.6 | Max] | chezmoi git:(main* ↑1 !3 ?1)
Context 0% | Usage △ Limit reached (resets 1d 10h)
```

**Desired state** (CodexBar-style):
```
Session: 56% left (resets 1h 34m)   Weekly: 0% left (resets 1d 10h)   Sonnet: 93% left (resets 1d 13h)
```

## Root Cause Analysis

From exploring the plugin at `~/.claude/plugins/cache/claude-hud/claude-hud/0.0.10/dist/`:

1. **API data available**: The plugin calls `https://api.anthropic.com/api/oauth/usage` and gets two windows:
   - `five_hour.utilization` → `fiveHour` (45% used in current cache)
   - `seven_day.utilization` → `sevenDay` (100% used in current cache)

2. **Display bug/limitation**: The rendering logic takes `Math.max(fiveHour, sevenDay)` and when sevenDay=100, it shows "Limit reached" — **hiding the still-available 5-hour window** (which is only at 45%). This is the main UX problem.

3. **Sonnet-specific data**: Unknown — may be an additional field in the API response not currently parsed, or a different endpoint. Needs investigation.

**Current cache** (`~/.claude/plugins/claude-hud/.usage-cache.json`):
```json
{"planName":"Max","fiveHour":45,"sevenDay":100,"fiveHourResetAt":"...","sevenDayResetAt":"..."}
```

## Approach

### Phase 1 — Probe the Raw API (read-only, ~5 min)

Call the same OAuth endpoint the plugin uses to see the full raw response:
```bash
# Get token from keychain
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('oauthToken',''))" 2>/dev/null)
curl -s -H "Authorization: Bearer $TOKEN" https://api.anthropic.com/api/oauth/usage | python3 -m json.tool
```

**Goal**: Determine if the API returns model-specific fields (e.g., `sonnet`) in addition to `five_hour` / `seven_day`. This tells us whether Sonnet-specific display is feasible without API-side changes.

### Phase 2 — Fix the "Limit reached hides Session" problem

The compiled plugin at `~/.claude/plugins/cache/claude-hud/claude-hud/0.0.10/dist/render/lines/usage.js` can be patched directly (it is plain JS, not minified), OR we can write a custom status line command that replaces or wraps the HUD output.

**Recommended**: Write a lightweight custom status-line script in `dot_claude/` that:
- Reads the existing `.usage-cache.json` (so no extra API calls — reuses the HUD's cached data)
- Shows BOTH windows independently: `Session: 55% left (1h 34m) | Weekly: 0% left (1d 10h)`
- Chains to the existing claude-hud for git/context/tools lines

**Alternative**: Patch `~/.claude/plugins/cache/claude-hud/claude-hud/0.0.10/dist/render/lines/usage.js` to always show both windows instead of taking max. Risk: overwritten on plugin update.

### Phase 3 — Add Sonnet-specific display (if API supports it)

Conditional on Phase 1 findings:
- **If the API returns Sonnet data**: parse it in the custom script and add a third segment
- **If not**: the custom script shows Session + Weekly only (already better than current)

## Files to Modify

| File | Action |
|------|--------|
| `dot_claude/modify_settings.json` | Potentially update `statusLine.command` if replacing with custom script |
| `dot_claude/plugins/claude-hud/config.json` | Add any newly supported usage config options |
| `dot_claude/executable_usage-status.sh` *(new)* | Custom usage display script (if Phase 2 goes custom route) |

## Verification

1. Run `claude` in any directory and check the status bar shows both Session and Weekly percentages
2. Verify the 5-hour window (Session) shows ~55% left (not hidden by "Limit reached")
3. Verify reset times match what CodexBar shows
4. Confirm Sonnet segment appears if API data is available
5. Confirm no extra API calls (cache at `.usage-cache.json` is reused)

## Open Question

The critical unknown is what the raw API response looks like. This determines whether Sonnet-specific limits are achievable without API-side changes. Phase 1 must run first.

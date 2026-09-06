# 45_copilot_raycast.sh - generate Raycast AI custom providers from the proxy
#   (shared bash + zsh). Sibling to 43_copilot_proxy.sh — loads AFTER it, so the
#   _copilot_base / _copilot_pinned_base / _copilot_alive helpers already exist.
#
# Raycast 1.102+ has a "Custom Providers" experiment (Settings → AI →
# Experiments) that reads ~/.config/raycast/ai/providers.yaml and routes those
# requests DIRECTLY from the Mac — so a localhost base_url works, and every
# Copilot model the proxy serves becomes a first-class Raycast AI model (Quick
# AI, AI Chat, AI Commands). This is NOT the "Custom API Keys" (BYOK) box: BYOK
# routes through Raycast's servers and only accepts a key, never an endpoint.
# Custom providers need no Raycast Pro. This file writes that YAML from the LIVE
# proxy catalogue, filtered by a probe (see the GOTCHA below).
#
# Public surface:
#   copilot-raycast [status]                  - config path, model count, drift
#   copilot-raycast generate [--dry-run] [--all]
#                                             - probe + (re)write providers.yaml
#                                               (--all also emits the rejected
#                                               models, commented out)
#   copilot-raycast diff                      - what generate would change
#   copilot-raycast probe [MODEL]             - classification table, one or all
#   copilot-raycast doctor                    - full diagnostic (house format)
#   copilot-raycast edit                      - $EDITOR the config, then validate
#
# GOTCHA (verified 2026-07): the free model-validation probe. POSTing
#   {"model":"<ID>","messages":[]} to /chat/completions is rejected during
#   request validation, BEFORE any inference, and moves no usage counter. Three
#   responses classify every model:
#     "messages must be non-empty"  -> usable via /chat/completions   (KEEP)
#     "model_not_supported"         -> not entitled / stale catalog   (DROP)
#     "unsupported_api_for_model"   -> exists, but only on /responses (DROP)
#   Probing is the ONLY truth: the static /v1/models metadata is wrong in BOTH
#   directions. gemini-2.5-pro and gemini-3-flash-preview advertise an EMPTY
#   supported_endpoints[] yet work; claude-opus-4-6/4-7/4-8, claude-sonnet-4-6,
#   claude-sonnet-4-5 and claude-haiku-4-5 all advertise "/chat/completions",
#   model_picker_enabled: true and policy.state "enabled" — and every one of
#   them returns model_not_supported. No field in /v1/models predicts this.
#
# GOTCHA (verified 2026-07): Raycast validates providers.yaml ALL-OR-NOTHING and
#   reports NOTHING on failure — one model missing `context` (or a quoted
#   `context: "128000"`, which is a type mismatch) silently removes EVERY custom
#   provider from the picker, including unrelated ones. So: generate to a temp
#   file, `yq`-validate it, and only then move it into place. Corollary: Raycast
#   makes zero network calls at config-load time, so an unusable model id looks
#   perfectly healthy in the picker and only 400s when you send a message —
#   which is exactly why the probe above is not optional.
#
# Verified 2026-07: `defaults read com.raycast.macos raycastAI_modelRouterModelInfo`
#   is a base64 JSON blob of what Raycast ACTUALLY loaded, keyed by provider id.
#   That is a zero-UI oracle for "did my file take?" — `status` and `doctor` read
#   it, so a silently-rejected config is visible instead of mysterious.
#
# Temperature heuristic (it cannot be probed): the messages check fires before
#   parameter validation, so {"messages":[],"temperature":0.7} still answers
#   "messages must be non-empty". Default: temperature unsupported for the
#   OpenAI reasoning family (gpt-*, *codex*, o1/o3/o4*) and Microsoft mai-*,
#   supported for everything else (Anthropic + Google take it fine here).
#   Override wholesale with COPILOT_RAYCAST_TEMP=on|off.
#
# Env (set in ~/.shellrc.adhoc or ~/.config/{zsh/secrets.zsh,bash/secrets.sh}):
#   COPILOT_RAYCAST_CONFIG default: $XDG_CONFIG_HOME/raycast/ai/providers.yaml
#                                             - the file Raycast watches
#   COPILOT_RAYCAST_ID     default: copilot   - providers[].id we own; every
#                                               OTHER id in the file is preserved
#   COPILOT_RAYCAST_LABEL  default: GitHub Copilot   - providers[].name
#   COPILOT_RAYCAST_SUFFIX default: " (Copilot)"     - appended to each model
#                                               name so typing "copilot" in the
#                                               Raycast picker finds them all
#   COPILOT_RAYCAST_TEMP   default: auto      - auto|on|off, see the heuristic
#   COPILOT_RAYCAST_JOBS   default: 6         - concurrent probes in the sweep
#   COPILOT_RAYCAST_PROBE_BASE default: $(_copilot_base)  - what the sweep POSTs
#                                               to; :4141 direct, NOT the shim
#   COPILOT_RAYCAST_KEEP   default: 10        - timestamped backups to retain

# Skip silently if already sourced (idempotent — safe to dot in sub-shells).
[ -n "${_COPILOT_RAYCAST_SOURCED:-}" ] && return 0
_COPILOT_RAYCAST_SOURCED=1

# Defensive load: if 43_copilot_proxy.sh wasn't sourced first (e.g. someone
# dot-sourced this file directly without running rc), pull it in so the shared
# _copilot_* helpers exist. Same pattern as 44_copilot_embed.sh.
if ! command -v _copilot_base >/dev/null 2>&1 \
   && [ -r "$HOME/.config/shell/43_copilot_proxy.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/shell/43_copilot_proxy.sh"
fi

# --- shared constants / helpers -------------------------------------------------

_copilot_raycast_config() { printf '%s' "${COPILOT_RAYCAST_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/raycast/ai/providers.yaml}"; }
_copilot_raycast_id()     { printf '%s' "${COPILOT_RAYCAST_ID:-copilot}"; }
_copilot_raycast_label()  { printf '%s' "${COPILOT_RAYCAST_LABEL:-GitHub Copilot}"; }
_copilot_raycast_suffix() { printf '%s' "${COPILOT_RAYCAST_SUFFIX:- (Copilot)}"; }
_copilot_raycast_jobs()   { printf '%s' "${COPILOT_RAYCAST_JOBS:-6}"; }
_copilot_raycast_keep()   { printf '%s' "${COPILOT_RAYCAST_KEEP:-10}"; }

# Backups are namespaced PER CONFIG. The KEEP rotation is a FIFO over one
# directory, so a single shared dir means one
#   COPILOT_RAYCAST_CONFIG=/tmp/scratch.yaml copilot-raycast generate
# evicts the real config's backups — which is exactly the history you want when
# a hand-added provider goes missing. The default path is unchanged so existing
# back-ups stay where they are.
_copilot_raycast_backups(){
  local base cfg
  base="${XDG_STATE_HOME:-$HOME/.local/state}/copilot-raycast/backups"
  cfg="$(_copilot_raycast_config)"
  if [ "$cfg" = "${XDG_CONFIG_HOME:-$HOME/.config}/raycast/ai/providers.yaml" ]; then
    printf '%s' "$base"
  else
    printf '%s/%s' "$base" \
      "$(printf '%s' "$cfg" | command sed 's|^/||; s|[^A-Za-z0-9._-]|_|g')"
  fi
}

# The banner we print above the preserved foreign providers. yq round-trips it
# back as a head comment on the first foreign node, so _copilot_raycast_others
# MUST strip it again or every generate appends one more copy — see the comment
# there. Single source of truth for both the writer and the stripper.
_copilot_raycast_others_banner() {
  printf '%s' "# --- other providers, preserved from the previous file ---"
}
_copilot_raycast_prefs()  { printf '%s' "$HOME/Library/Preferences/com.raycast.macos.plist"; }
_copilot_raycast_template(){ printf '%s' "$(command dirname "$(_copilot_raycast_config)")/providers.template.yaml"; }

# base_url written INTO providers.yaml: the shim when it's enabled. Same
# reasoning as _copilot_pinned_base (which this reuses) — the file outlives this
# shell, so it must not be gated on currently-alive. The shim matters more here
# than anywhere else: Raycast and Claude Code now share one Copilot backend, and
# the shim's semaphore + transparent 403/429 retry is what stops a burst of
# Quick-AI calls from making Claude Code see "Please run /login".
_copilot_raycast_base_url() { printf '%s/v1' "$(_copilot_pinned_base)"; }

# ...but the SWEEP deliberately POSTs to the fork directly (:4141). The probe is
# ~20 requests fired 6-wide; routing them through the shim would serialise them
# behind its 4-permit semaphore for no benefit, because a rejected-at-validation
# request never reaches the point the shim's retry logic protects. Override with
# COPILOT_RAYCAST_PROBE_BASE if you ever want the sweep throttled too.
_copilot_raycast_probe_base() { printf '%s' "${COPILOT_RAYCAST_PROBE_BASE:-$(_copilot_base)}"; }

# Sort key: bigger = earlier in providers.yaml. Mirrors _copilot_pick_best_model's
# vendor ranking (Claude > Codex > GPT > Gemini) but keeps ALL of them, and adds
# a within-family tier so opus lands above sonnet above haiku. Ties are broken by
# `sort -Vr` on the id, i.e. newest version first.
# $1 = model id, $2 = its model_picker_category (optional, unknown-vendor only).
_copilot_raycast_rank() {
  case "$1" in
    claude-fable-*)  printf '60' ;;
    claude-opus-*)   printf '59' ;;
    claude-sonnet-*) printf '58' ;;
    claude-haiku-*)  printf '57' ;;
    claude-*)        printf '56' ;;
    *codex*)         printf '45' ;;
    # gemini MUST be matched before any *mini* rule — "ge-mini" contains "mini",
    # and a naive `*mini*` arm silently demotes the entire Google family.
    gemini-*pro*)    printf '25' ;;
    gemini-*flash*)  printf '24' ;;
    gemini-*)        printf '23' ;;
    # GPT/o-series stay together as one vendor band, but the live category is
    # the within-band truth: a future gpt-6-luna (lightweight) must not sort
    # above an older Sol (powerful) merely because 6 > 5.6. Name heuristics are
    # only the category-missing fallback.
    gpt-*|o[0-9]*)
      case "${2:-}" in
        powerful)    printf '39' ;;
        versatile)   printf '37' ;;
        lightweight) printf '34' ;;
        *)
          case "$1" in *mini*) printf '34' ;; *) printf '35' ;; esac
          ;;
      esac ;;
    # xAI, between OpenAI and Google to match the main rankers' vendor order.
    grok-*)
      case "${2:-}" in
        powerful) printf '32' ;; lightweight) printf '29' ;; *) printf '30' ;;
      esac ;;
    # Unknown vendors stay in the fallback band below every known vendor, but
    # Copilot's tier still orders them relative to one another. $2 is the
    # catalog's model_picker_category when available.
    *)
      case "${2:-}" in
        powerful)    printf '16' ;;
        versatile)   printf '14' ;;
        lightweight) printf '12' ;;
        *)           printf '10' ;;
      esac ;;
  esac
}

# Heuristic only — see the header. Echoes "true"/"false".
_copilot_raycast_temp() {
  case "${COPILOT_RAYCAST_TEMP:-auto}" in
    1|on|true|yes)  printf 'true';  return 0 ;;
    0|off|false|no) printf 'false'; return 0 ;;
  esac
  case "$1" in
    # grok was checked and deliberately left on the `true` default — the `false`
    # arm is for reasoning-only endpoints, and grok accepts temperature.
    gpt-*|o[0-9]*|*codex*|mai-*) printf 'false' ;;
    *)                               printf 'true' ;;
  esac
}

# Escape a scalar for a YAML double-quoted string (backslash first, then quote).
_copilot_raycast_yesc() {
  printf '%s' "$1" | command sed 's/\\/\\\\/g; s/"/\\"/g'
}

# --- catalogue + zero-quota probe -----------------------------------------------

# Live chat models from the proxy, one TSV row each:
#   id \t name \t vendor \t context \t vision \t tools \t reasoning_effort
# Pre-filters on capabilities.type == "chat" (drops the three embedding models)
# and on the "[1m]" alias, which is Claude Code-only sugar the proxy rejects from
# a raw API client. Everything else is decided by the probe, never by metadata.
_copilot_raycast_catalog() {
  command -v jq >/dev/null 2>&1 || return 1
  command curl -fsS --max-time 10 "$(_copilot_base)/v1/models" 2>/dev/null \
    | jq -r '
        .data[]
        | select(.capabilities.type == "chat")
        | [ .id,
            # `//` only falls through on null/false, so an EMPTY name would ship
            # an empty TSV field — and IFS=<tab> is IFS-whitespace, which
            # collapses runs of separators, silently shifting every column right
            # of it (name<-vendor, context<-vision, …). Coerce empties too.
            (if (.name // "") == "" then
               (if (.display_name // "") == "" then .id else .display_name end)
             else .name end),
            (if (.vendor // "") == "" then "Other" else .vendor end),
            (.capabilities.limits.max_context_window_tokens // 0),
            (if .capabilities.supports.vision      == true then "1" else "0" end),
            (if .capabilities.supports.tool_calls  == true then "1" else "0" end),
            (if (.capabilities.supports.reasoning_effort | type) == "array"
                and (.capabilities.supports.reasoning_effort | length) > 0
             then "1" else "0" end),
            # 8th column. Added together with the `read` list in
            # _copilot_raycast_scan — see the IFS note above before
            # touching either of them.
            # The upstream tier taxonomy; only used to give an unknown vendor
            # a sensible band instead of dumping it below Gemini.
            (if (.model_picker_category // "") == "" then "unknown"
             else .model_picker_category end)
          ] | @tsv' 2>/dev/null \
    | command grep -v '\[1m\]'
}

# Classify ONE model id. Echoes one of:
#   ok | not_supported | responses_only | no_response | unknown
# Body is deliberately {"messages":[]} — see the header GOTCHA. One free retry
# covers a transient 429/502 from the burst, which would otherwise read as a
# permanent "unknown" and silently drop a good model from the file.
_copilot_raycast_probe_one() {
  local model="$1" body resp i=0
  body="$(printf '{"model":"%s","messages":[]}' "$model")"
  while [ "$i" -lt 2 ]; do
    resp="$(command curl -s --max-time 25 \
              -X POST "$(_copilot_raycast_probe_base)/v1/chat/completions" \
              -H 'content-type: application/json' -d "$body" 2>/dev/null)"
    case "$resp" in
      *'messages must be non-empty'*) printf 'ok';             return 0 ;;
      *model_not_supported*)          printf 'not_supported';  return 0 ;;
      *unsupported_api_for_model*)    printf 'responses_only'; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt 2 ] && sleep 1
  done
  case "$resp" in
    '') printf 'no_response' ;;
    *)  printf 'unknown' ;;
  esac
}

# Probe every id on stdin, at most $(_copilot_raycast_jobs) at a time, writing
# "$dir/<id>" per model. Always called as the RHS of a pipeline so it runs in a
# subshell: job control is off there, which is what keeps zsh from printing
# "[1] 12345" job notices all over an interactive run.
_copilot_raycast_sweep() {
  local dir="$1" max n=0 m
  max="$(_copilot_raycast_jobs)"
  # A non-numeric or zero COPILOT_RAYCAST_JOBS made `[ "$n" -ge "$max" ]` print
  # "integer expression expected" once per model (or serialise the whole sweep).
  case "$max" in ''|*[!0-9]*) max=6 ;; esac
  [ "$max" -ge 1 ] || max=6
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    _copilot_raycast_probe_one "$m" >"$dir/$m" 2>/dev/null &
    n=$((n + 1))
    if [ "$n" -ge "$max" ]; then wait; n=0; fi
  done
  wait
}

# Catalogue + verdicts, sorted for emission. One TSV row per chat model:
#   rank \t id \t name \t vendor \t context \t vision \t tools \t reasoning \t verdict
# This is the SINGLE SOURCE OF TRUTH consumed by generate, diff, status, probe
# and doctor — they must never disagree about which models are usable.
_copilot_raycast_scan() {
  local cat dir
  cat="$(_copilot_raycast_catalog)" || return 1
  [ -n "$cat" ] || return 1
  dir="$(command mktemp -d "${TMPDIR:-/tmp}/copilot-raycast.XXXXXX")" || return 1
  printf '%s\n' "$cat" | command cut -f1 | _copilot_raycast_sweep "$dir"
  local id name vendor ctx vis tools reff tier verdict
  printf '%s\n' "$cat" | while IFS="$(printf '\t')" read -r id name vendor ctx vis tools reff tier; do
    verdict="$(command head -n 1 "$dir/$id" 2>/dev/null)"
    [ -n "$verdict" ] || verdict='no_response'
    # Deliberately still NINE columns out — the tier is a ranking input, not
    # part of this function's wire format, so `awk -F'\t' '$9 == "ok"'` holds.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(_copilot_raycast_rank "$id" "$tier")" "$id" "$name" "$vendor" \
      "$ctx" "$vis" "$tools" "$reff" "$verdict"
  done | command sort -k1,1nr -k2,2Vr
  command rm -rf -- "$dir"
}

# --- providers.yaml rendering ---------------------------------------------------

# Foreign providers (every id that is not ours) as a YAML sequence, or empty.
# yq round-trips them including their comments; without yq we cannot safely
# rewrite a file that has any, and _copilot_raycast_render refuses instead.
_copilot_raycast_others() {
  local cfg; cfg="$(_copilot_raycast_config)"
  [ -f "$cfg" ] || return 0
  command -v yq >/dev/null 2>&1 || return 0
  local raw out
  # Two steps on purpose. `yq | awk` in one pipeline would hide yq's exit
  # status behind awk's, and "yq could not parse this file" MUST NOT read as
  # "there are no other providers" — that is the difference between preserving
  # a hand-added provider and silently deleting it. Verified 2026-07: a stray
  # tab in providers.yaml made the old one-pipeline version report success
  # while dropping a hand-added `myollama` block.
  raw="$(COPILOT_RC_ID="$(_copilot_raycast_id)" yq -o=yaml \
          '(.providers // []) | map(select(.id != strenv(COPILOT_RC_ID)))' \
          "$cfg" 2>/dev/null)" || return 2
  # Strip our own banner: yq round-trips it back as a head comment on the first
  # foreign node, so without this every generate appends one more copy — the
  # file grows without bound and `copilot-raycast diff` can never say "no
  # changes" once any foreign provider exists.
  out="$(printf '%s\n' "$raw" | command awk -v m="$(_copilot_raycast_others_banner)" \
           '{ t = $0; sub(/^[[:space:]]+/, "", t); if (t != m) print }')"
  case "$out" in
    ''|'[]'|'null') return 0 ;;
    *) printf '%s\n' "$out" ;;
  esac
}

# Two sorted id lists in, a human drift report out ('' when they agree). Uses
# comm(1) over temp files rather than diff <(…): process substitution is a
# bash/zsh extension and this file stays in the POSIX subset.
_copilot_raycast_drift() {
  local a b
  a="$(command mktemp "${TMPDIR:-/tmp}/copilot-raycast.XXXXXX")" || return 1
  b="$(command mktemp "${TMPDIR:-/tmp}/copilot-raycast.XXXXXX")" || return 1
  printf '%s\n' "$1" | command grep -v '^$' | command sort -u >"$a"
  printf '%s\n' "$2" | command grep -v '^$' | command sort -u >"$b"
  command comm -23 "$a" "$b" | command sed 's/^/    stale in file: /'
  command comm -13 "$a" "$b" | command sed 's/^/    missing      : /'
  command rm -f -- "$a" "$b"
}

# Render the COMPLETE providers.yaml to stdout from a scan TSV on stdin.
# $1 = 1 to also emit the probe-rejected models, commented out.
_copilot_raycast_render() {
  local want_all="${1:-0}" tsv cfg pid base others
  tsv="$(command cat)"
  cfg="$(_copilot_raycast_config)"
  pid="$(_copilot_raycast_id)"
  base="$(_copilot_raycast_base_url)"
  others="$(_copilot_raycast_others)" || {
    printf '%s\n' "copilot-raycast: $cfg is not valid YAML — refusing to rewrite it" >&2
    printf '%s\n' "  any provider you added by hand would be lost; inspect or move it aside:" >&2
    printf '%s\n' "  yq '.' $cfg" >&2
    return 1
  }

  if [ -f "$cfg" ] && ! command -v yq >/dev/null 2>&1; then
    # Rewriting an existing file blind would silently delete any provider the
    # user added by hand, and there is no cheap POSIX way to tell a provider
    # entry from a model entry in arbitrary YAML. Refuse instead.
    printf '%s\n' "copilot-raycast: yq is required to rewrite an existing $cfg (it preserves other providers)" >&2
    printf '%s\n' "  brew install yq   # or move the file aside and re-run" >&2
    return 1
  fi

  local n_ok n_all
  n_ok="$(printf '%s\n' "$tsv" | command awk -F'\t' '$9 == "ok"' | command grep -c . || true)"
  n_all="$(printf '%s\n' "$tsv" | command grep -c . || true)"

  printf '%s\n' "# Raycast AI custom providers — GENERATED by \`copilot-raycast generate\`."
  printf '%s\n' "# Hand edits are lost on the next run; back-ups live in"
  printf '%s\n' "#   $(_copilot_raycast_backups)"
  printf '%s\n' "#"
  printf '%s\n' "# Source: $(_copilot_base)/v1/models  ($n_all chat model(s), $n_ok usable)"
  printf '%s\n' "# Probed: $(command date '+%Y-%m-%d %H:%M:%S%z') via $(_copilot_raycast_probe_base)"
  printf '%s\n' "#"
  printf '%s\n' "# Each id was validated with a zero-quota probe — POST /chat/completions with"
  printf '%s\n' "# {\"model\":ID,\"messages\":[]} is rejected before inference, and the error"
  printf '%s\n' "# distinguishes usable models from ones the /v1/models catalogue only claims"
  printf '%s\n' "# to serve:  \"messages must be non-empty\" = keep, \"model_not_supported\" and"
  printf '%s\n' "# \"unsupported_api_for_model\" = drop.  Regenerate: copilot-raycast generate"
  printf '\n'
  printf '%s\n' "providers:"
  printf '  - id: %s\n' "$pid"
  printf '    name: "%s"\n' "$(_copilot_raycast_yesc "$(_copilot_raycast_label)")"
  printf '    base_url: %s\n' "$base"
  printf '%s\n' "    models:"

  local rank id name vendor ctx vis tools reff verdict vlast='' dname
  printf '%s\n' "$tsv" | while IFS="$(printf '\t')" read -r rank id name vendor ctx vis tools reff verdict; do
    [ -n "$id" ] || continue
    case "$verdict" in
      ok) ;;
      *) [ "$want_all" = "1" ] || continue ;;
    esac
    if [ "$vendor" != "$vlast" ]; then
      [ -n "$vlast" ] && printf '\n'
      printf '      # --- %s ---\n' "$vendor"
      vlast="$vendor"
    fi
    dname="$(_copilot_raycast_yesc "$name$(_copilot_raycast_suffix)")"
    # context MUST be a bare positive integer — a quoted or missing one is a
    # Swift type mismatch and takes the WHOLE file down, silently.
    case "$ctx" in ''|*[!0-9]*) ctx=128000 ;; esac
    [ "$ctx" -gt 0 ] || ctx=128000
    if [ "$verdict" != "ok" ]; then
      # Commented out on purpose: emitting these for real would 400 at inference
      # with nothing shown in the Raycast UI. Kept so a future run can be diffed
      # against them when GitHub changes an entitlement.
      printf '      # - id: "%s"   # %s\n' "$(_copilot_raycast_yesc "$id")" "$verdict"
      printf '      #   name: "%s"\n' "$dname"
      printf '      #   context: %s\n' "$ctx"
      continue
    fi
    printf '      - id: "%s"\n' "$(_copilot_raycast_yesc "$id")"
    printf '        name: "%s"\n' "$dname"
    printf '        context: %s\n' "$ctx"
    printf '%s\n' "        abilities:"
    printf '          temperature: { supported: %s }\n' "$(_copilot_raycast_temp "$id")"
    printf '          vision: { supported: %s }\n' "$([ "$vis" = 1 ] && printf 'true' || printf 'false')"
    # No /v1/models field describes system-message support; every Copilot chat
    # model accepts one, so this is a constant true.
    printf '%s\n' "          system_message: { supported: true }"
    printf '          tools: { supported: %s }\n' "$([ "$tools" = 1 ] && printf 'true' || printf 'false')"
    printf '          reasoning_effort: { supported: %s }\n' "$([ "$reff" = 1 ] && printf 'true' || printf 'false')"
  done

  if [ -n "$others" ]; then
    printf '\n'
    printf '%s\n' "  $(_copilot_raycast_others_banner)"
    printf '%s\n' "$others" | command sed 's/^\(.\)/  \1/'
  fi
}

# --- validation + atomic install ------------------------------------------------

# Raycast says nothing when it rejects a file, so this is the only gate. Checks
# the shape it actually hard-fails on: at least one provider, unique provider
# ids, and every model carrying a string id, a string name and an INTEGER
# context. Returns 0 (can't tell) when yq is missing — the caller warns.
_copilot_raycast_validate() {
  command -v yq >/dev/null 2>&1 || return 0
  yq -e '
    ((.providers | length) > 0)
    and (([.providers[].id] | unique | length) == (.providers | length))
    and (([.providers[].models[]
           | select((.id | tag) == "!!str"
                    and (.name | tag) == "!!str"
                    and (.context | tag) == "!!int")] | length)
         == ([.providers[].models[]] | length))
  ' "$1" >/dev/null 2>&1
}

# Install rendered YAML (stdin) at the config path: validate, back up, move.
# One single write — Raycast's file watcher coalesces rapid writes and can skip
# a reload entirely, so the back-up deliberately goes to a different directory
# rather than sitting next to the file as a second touch.
_copilot_raycast_install() {
  local cfg dir tmp bdir bk
  cfg="$(_copilot_raycast_config)"
  dir="$(command dirname "$cfg")"
  command mkdir -p "$dir"
  # The temp file MUST live next to the target, not in $TMPDIR: `mv` is only an
  # atomic rename(2) within one filesystem. Across filesystems it degrades to
  # copy-then-unlink, and an interrupted copy leaves a TRUNCATED providers.yaml
  # — the exact all-or-nothing failure this whole install path exists to avoid.
  # macOS puts $TMPDIR on the data volume with $HOME today, but nothing
  # guarantees that (a TMPDIR on an external disk or a RAM disk breaks it).
  tmp="$(command mktemp "$dir/.copilot-raycast.XXXXXX")" || {
    printf '%s\n' "copilot-raycast: cannot write a temp file in $dir; $cfg unchanged" >&2
    return 1
  }
  command cat >"$tmp"
  if [ ! -s "$tmp" ]; then
    command rm -f -- "$tmp"
    printf '%s\n' "copilot-raycast: rendered nothing; $cfg unchanged" >&2
    return 1
  fi
  if ! _copilot_raycast_validate "$tmp"; then
    command rm -f -- "$tmp"
    printf '%s\n' "copilot-raycast: generated YAML failed validation; $cfg unchanged" >&2
    printf '%s\n' "  a bad file would silently remove EVERY custom provider from Raycast" >&2
    return 1
  fi
  if [ -f "$cfg" ]; then
    bdir="$(_copilot_raycast_backups)"
    command mkdir -p "$bdir"
    bk="$bdir/providers-$(command date +%Y%m%d-%H%M%S).yaml"
    if ! command cp -- "$cfg" "$bk"; then
      command rm -f -- "$tmp"
      printf '%s\n' "copilot-raycast: backup to $bk failed; $cfg unchanged" >&2
      return 1
    fi
    # Keep the last N generations (same spirit as copilot-proxy's log rotation).
    # Restricted to our own providers-*.yaml: a bare `ls -1t "$bdir"` would
    # happily rm anything else the user parked in that directory.
    local _f
    command ls -1t "$bdir" 2>/dev/null \
      | command grep -E '^providers-[0-9]{8}-[0-9]{6}\.yaml$' \
      | command tail -n +"$(( $(_copilot_raycast_keep) + 1 ))" \
      | while IFS= read -r _f; do command rm -f -- "$bdir/$_f"; done
  fi
  command mv -- "$tmp" "$cfg" || {
    command rm -f -- "$tmp"
    printf '%s\n' "copilot-raycast: install failed; $cfg unchanged" >&2
    return 1
  }
  [ -n "$bk" ] && printf '%s\n' "copilot-raycast: backup $bk"
  return 0
}

# --- what Raycast actually loaded -----------------------------------------------

# Model ids Raycast currently has live for our provider id, newline separated.
# Reads raycastAI_modelRouterModelInfo (base64 JSON) from the prefs plist — the
# only observable that distinguishes "written" from "accepted".
_copilot_raycast_loaded() {
  local plist; plist="$(_copilot_raycast_prefs)"
  [ -f "$plist" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  command plutil -extract raycastAI_modelRouterModelInfo raw -o - "$plist" 2>/dev/null \
    | command base64 -d 2>/dev/null \
    | jq -r --arg id "$(_copilot_raycast_id)" '.[$id][]?.model // empty' 2>/dev/null
}

# --- public command -------------------------------------------------------------

# Generate ~/.config/raycast/ai/providers.yaml from the live proxy catalogue,
# keeping only the models a zero-quota probe proves are reachable over
# /chat/completions. Bare invocation is read-only (status).
# Example:
#   copilot-raycast                    # config path, model count, drift vs live
#   copilot-raycast probe              # classification table for every chat model
#   copilot-raycast generate --dry-run # render to stdout, touch nothing
#   copilot-raycast generate           # back up, validate, install
#   copilot-raycast diff               # what generate would change
copilot-raycast() {
  # ${ZSH_VERSION:-} not $ZSH_VERSION: a caller running under `set -u` would
  # otherwise get "ZSH_VERSION: unbound variable" and the function would never
  # run at all. (43_copilot_proxy.sh / 44_copilot_embed.sh have the same line.)
  if [ -n "${ZSH_VERSION:-}" ]; then
    emulate -L zsh
    setopt localoptions pipefail
  else
    set -o pipefail
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "copilot-raycast: curl is required" >&2; return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "copilot-raycast: jq is required" >&2; return 1
  fi

  local cfg pid action
  cfg="$(_copilot_raycast_config)"
  pid="$(_copilot_raycast_id)"
  action="${1:-status}"

  case "$action" in
    generate|gen)
      local dry=0 all=0
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -n|--dry-run) dry=1; shift ;;
          -a|--all)     all=1; shift ;;
          --)           shift; break ;;
          -*)
            printf '%s\n' "copilot-raycast: unknown flag '$1' (try --help)" >&2; return 1 ;;
          *)            break ;;
        esac
      done
      if ! _copilot_alive; then
        copilot-proxy start >&2 || return 1
      fi
      local scan
      scan="$(_copilot_raycast_scan)" || {
        printf '%s\n' "copilot-raycast: could not read the model catalogue from $(_copilot_base)" >&2
        return 1
      }
      local n_ok
      n_ok="$(printf '%s\n' "$scan" | command awk -F'\t' '$9 == "ok"' | command grep -c . || true)"
      if [ "$n_ok" -eq 0 ]; then
        printf '%s\n' "copilot-raycast: no model passed the probe — refusing to write $cfg" >&2
        printf '%s\n' "  copilot-proxy doctor    # entitlement or auth problem, not a config one" >&2
        return 1
      fi
      if [ "$dry" = "1" ]; then
        printf '%s\n' "$scan" | _copilot_raycast_render "$all"
        return $?
      fi
      printf '%s\n' "$scan" | _copilot_raycast_render "$all" | _copilot_raycast_install || return 1
      printf '%s\n' "copilot-raycast: wrote $n_ok model(s) → $cfg"
      printf '%s\n' "  base_url $(_copilot_raycast_base_url)   (Raycast reloads within ~5s)"
      printf '%s\n' "  copilot-raycast status   # confirm Raycast actually accepted it"
      ;;

    diff)
      if ! command -v diff >/dev/null 2>&1; then
        printf '%s\n' "copilot-raycast: diff(1) is required" >&2; return 1
      fi
      if ! _copilot_alive; then
        copilot-proxy start >&2 || return 1
      fi
      local scan tmp cur
      scan="$(_copilot_raycast_scan)" || {
        printf '%s\n' "copilot-raycast: could not read the model catalogue from $(_copilot_base)" >&2
        return 1
      }
      tmp="$(command mktemp "${TMPDIR:-/tmp}/copilot-raycast.XXXXXX")" || return 1
      cur="$(command mktemp "${TMPDIR:-/tmp}/copilot-raycast.XXXXXX")" || return 1
      # The `# Probed:` stamp changes on every run by construction, so normalise
      # it on BOTH sides — otherwise `diff` could never report "no changes" and
      # would be useless as a drift check.
      printf '%s\n' "$scan" | _copilot_raycast_render 0 \
        | command sed 's/^# Probed: .*/# Probed: <run timestamp>/' >"$tmp" || {
        command rm -f -- "$tmp" "$cur"; return 1
      }
      if [ ! -f "$cfg" ]; then
        printf '%s\n' "copilot-raycast: $cfg does not exist yet — generate would create it:"
        command cat "$tmp"
        command rm -f -- "$tmp" "$cur"
        return 0
      fi
      command sed 's/^# Probed: .*/# Probed: <run timestamp>/' "$cfg" >"$cur"
      if command diff -u "$cur" "$tmp" >/dev/null 2>&1; then
        printf '%s\n' "copilot-raycast: no changes ($cfg is current)"
        command rm -f -- "$tmp" "$cur"
        return 0
      fi
      command diff -u --label "$cfg" --label "generate" "$cur" "$tmp"
      command rm -f -- "$tmp" "$cur"
      ;;

    probe)
      if ! _copilot_alive; then
        copilot-proxy start >&2 || return 1
      fi
      if [ -n "${2:-}" ]; then
        printf '%s\n' "$(_copilot_raycast_probe_one "$2")"
        return 0
      fi
      local scan
      scan="$(_copilot_raycast_scan)" || {
        printf '%s\n' "copilot-raycast: could not read the model catalogue from $(_copilot_base)" >&2
        return 1
      }
      printf '\ncopilot-raycast probe   base %s   %s chat model(s)\n\n' \
        "$(_copilot_raycast_probe_base)" "$(printf '%s\n' "$scan" | command grep -c .)"
      local rank id name vendor ctx vis tools reff verdict flags label
      printf '%s\n' "$scan" | while IFS="$(printf '\t')" read -r rank id name vendor ctx vis tools reff verdict; do
        flags=''
        [ "$vis" = 1 ]   && flags="$flags vision"
        [ "$tools" = 1 ] && flags="$flags tools"
        [ "$reff" = 1 ]  && flags="$flags reasoning"
        case "$verdict" in
          ok)             label='OK' ;;
          not_supported)  label='NOT_SUPPORTED' ;;
          responses_only) label='RESPONSES_ONLY' ;;
          no_response)    label='NO_RESPONSE' ;;
          *)              label='UNKNOWN' ;;
        esac
        printf '  %-14s %-26s %9s %s\n' "$label" "$id" "$ctx" "${flags# }"
      done
      printf '\n'
      printf '%s\n' "  OK              usable via /chat/completions — emitted into providers.yaml"
      printf '%s\n' "  NOT_SUPPORTED   catalogue lists it, the account is not entitled to it"
      printf '%s\n' "  RESPONSES_ONLY  exists, but only on /responses — Raycast cannot reach it"
      printf '\n'
      ;;

    status)
      printf '\ncopilot-raycast   config %s\n\n' "$cfg"
      if [ -f "$cfg" ]; then
        local in_file n_file
        if command -v yq >/dev/null 2>&1; then
          in_file="$(COPILOT_RC_ID="$pid" yq -r \
            '.providers[] | select(.id == strenv(COPILOT_RC_ID)) | .models[].id' "$cfg" 2>/dev/null)"
        else
          # yq-less fallback. The old `grep -E '^[[:space:]]+- id:'` matched
          # EVERY indented `- id:` in the file — the provider entries and other
          # providers' models included — so with one hand-added provider it
          # reported 12 models instead of 9 and then fed those three phantom ids
          # to _copilot_raycast_drift, which told the user to regenerate a file
          # that was already correct (verified 2026-07). Track the provider we
          # are inside instead. Indentation-based, so it only understands the
          # shape this tool writes; that is why yq stays the accurate path.
          in_file="$(command awk -v pid="$pid" -v sq="'" '
            match($0, /^  - id:[[:space:]]*/) {
              v = substr($0, RLENGTH + 1)
              gsub(/"/, "", v); gsub(sq, "", v); sub(/[ \t]*$/, "", v)
              inp = (v == pid); next
            }
            inp && match($0, /^      - id:[[:space:]]*/) {
              v = substr($0, RLENGTH + 1)
              gsub(/"/, "", v); gsub(sq, "", v); sub(/[ \t]*$/, "", v)
              print v
            }
          ' "$cfg")"
        fi
        n_file="$(printf '%s\n' "$in_file" | command grep -c . || true)"
        printf '  %-16s %s\n' "file" "present, $n_file model(s) under provider '$pid'"
      else
        printf '  %-16s %s\n' "file" "absent"
        printf '  %-16s → %s\n' "" "copilot-raycast generate"
      fi
      local loaded n_loaded
      loaded="$(_copilot_raycast_loaded)"
      n_loaded="$(printf '%s\n' "$loaded" | command grep -c . || true)"
      if [ "$n_loaded" -gt 0 ]; then
        printf '  %-16s %s\n' "raycast" "$n_loaded model(s) live in the picker"
      else
        printf '  %-16s %s\n' "raycast" "no models loaded for '$pid' (rejected config, or Raycast never ran)"
      fi
      printf '  %-16s %s\n' "base_url" "$(_copilot_raycast_base_url)"
      if _copilot_shim_enabled; then
        printf '  %-16s %s\n' "shim" "on (:$(_copilot_shim_port))"
      else
        printf '  %-16s %s\n' "shim" "off — base_url points straight at the fork"
      fi
      if ! _copilot_alive; then
        printf '  %-16s %s\n' "proxy" "not running — cannot check drift"
        printf '  %-16s → %s\n' "" "copilot-proxy start"
        printf '\n'
        return 0
      fi
      local scan live drift n_live
      scan="$(_copilot_raycast_scan)" || { printf '\n'; return 0; }
      live="$(printf '%s\n' "$scan" | command awk -F'\t' '$9 == "ok" { print $2 }' | command sort)"
      n_live="$(printf '%s\n' "$live" | command grep -c . || true)"
      printf '  %-16s %s\n' "live usable" "$n_live model(s) pass the probe"
      if [ -f "$cfg" ]; then
        drift="$(_copilot_raycast_drift "${in_file:-}" "$live")"
        if [ -z "$drift" ]; then
          printf '  %-16s %s\n' "drift" "none — the file matches the live catalogue"
        else
          printf '  %-16s %s\n' "drift" "$(printf '%s\n' "$drift" | command grep -c .) difference(s)"
          printf '%s\n' "$drift"
          printf '  %-16s → %s\n' "" "copilot-raycast generate"
        fi
      fi
      printf '\n'
      ;;

    doctor|test)
      # Colour only when stdout is a terminal, so `copilot-raycast doctor | tee`
      # and CI capture stay readable. printf (not $'..') keeps this sh-portable.
      local _g='' _r_='' _y='' _z=''
      if [ -t 1 ]; then
        _g="$(printf '\033[32m')"; _r_="$(printf '\033[31m')"
        _y="$(printf '\033[33m')"; _z="$(printf '\033[0m')"
      fi

      local _fail=0 _warn=0
      _ok()   { printf '  %s✓%s %-16s %s\n' "$_g" "$_z" "$1" "$2"; }
      _bad()  { printf '  %s✗%s %-16s %s\n' "$_r_" "$_z" "$1" "$2"; _fail=$((_fail+1)); }
      _note() { printf '  %s!%s %-16s %s\n' "$_y" "$_z" "$1" "$2"; _warn=$((_warn+1)); }
      _skip() { printf '  · %-16s %s\n' "$1" "$2"; }
      _hint() { printf '    %-16s → %s\n' "" "$1"; }

      printf '\ncopilot-raycast doctor   base %s   config %s\n\n' \
        "$(_copilot_raycast_base_url)" "$cfg"

      printf '%s\n' "Prerequisites"
      local _tool
      for _tool in curl jq yq; do
        if command -v "$_tool" >/dev/null 2>&1; then _ok "$_tool" "$(command -v "$_tool")"
        elif [ "$_tool" = yq ]; then
          _note "$_tool" "not found — no YAML validation, and foreign providers can't be preserved"
          _hint "brew install yq"
        else _bad "$_tool" "not found"; fi
      done

      printf '\n%s\n' "Proxy"
      if _copilot_alive; then _ok "listening" "$(_copilot_base)"
      else
        _bad "listening" "nothing answering on port $(_copilot_port)"
        _hint "copilot-proxy start"
      fi
      if _copilot_shim_enabled; then
        if _copilot_shim_alive; then _ok "throttle shim" "$(_copilot_shim_base) — base_url points here"
        else
          _note "throttle shim" "enabled but not answering; base_url still names $(_copilot_shim_base)"
          _hint "copilot-proxy restart"
        fi
      else
        _skip "throttle shim" "off — base_url points straight at the fork"
        _hint "copilot-proxy shim on   # queue Raycast behind Claude Code instead of racing it"
      fi

      printf '\n%s\n' "Raycast"
      if [ -d /Applications/Raycast.app ]; then
        local _ver
        _ver="$(command defaults read /Applications/Raycast.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)"
        _ok "installed" "/Applications/Raycast.app${_ver:+  v$_ver}"
      else
        _bad "installed" "/Applications/Raycast.app not found"
      fi
      # Raycast writes providers.template.yaml out of its own bundle the first
      # time the Custom Providers experiment is switched on, and records the fact
      # in raycastAI_modelRouterInstalledTemplate. That pair is the closest thing
      # to an observable for the toggle — there is no public API for it.
      if [ -f "$(_copilot_raycast_template)" ]; then
        _ok "custom providers" "experiment has been enabled (template installed)"
      else
        _note "custom providers" "no providers.template.yaml — is the experiment on?"
        _hint "Raycast → Settings → AI → Experiments → Custom Providers"
      fi
      local _loaded _nl
      _loaded="$(_copilot_raycast_loaded)"
      _nl="$(printf '%s\n' "$_loaded" | command grep -c . || true)"
      if [ "$_nl" -gt 0 ]; then
        _ok "loaded models" "$_nl live in the picker for provider '$pid'"
      else
        _note "loaded models" "Raycast has no models for '$pid'"
        _hint "a rejected providers.yaml is SILENT — validate, then wait ~5s and re-run"
      fi

      printf '\n%s\n' "Config"
      if [ -f "$cfg" ]; then
        _ok "present" "$cfg"
        if ! command -v yq >/dev/null 2>&1; then
          _skip "parse" "yq missing — cannot verify"
        elif _copilot_raycast_validate "$cfg"; then
          _ok "parse" "valid (providers present, every model has id/name/int context)"
        else
          _bad "parse" "would be REJECTED by Raycast — all custom providers disappear"
          _hint "copilot-raycast generate"
        fi
        local _foreign
        _foreign="$(_copilot_raycast_others | command grep -cE '^- id:' || true)"
        if [ "${_foreign:-0}" -gt 0 ]; then
          _skip "other providers" "$_foreign will be preserved verbatim on regenerate"
        fi
      else
        _bad "present" "$cfg does not exist"
        _hint "copilot-raycast generate"
      fi

      printf '\n%s\n' "Models"
      if ! _copilot_alive; then
        _skip "skipped" "proxy is not running"
      else
        local _scan _live _infile _n_live _n_file _d
        _scan="$(_copilot_raycast_scan)"
        if [ -z "$_scan" ]; then
          _bad "catalogue" "no chat models returned by $(_copilot_base)/v1/models"
        else
          _live="$(printf '%s\n' "$_scan" | command awk -F'\t' '$9 == "ok" { print $2 }' | command sort)"
          _n_live="$(printf '%s\n' "$_live" | command grep -c . || true)"
          if [ "$_n_live" -gt 0 ]; then
            _ok "probe" "$_n_live of $(printf '%s\n' "$_scan" | command grep -c .) chat models usable"
          else
            _bad "probe" "no model passed the probe"
            _hint "copilot-proxy doctor   # this is an entitlement/auth fault, not a config one"
          fi
          if [ -f "$cfg" ] && command -v yq >/dev/null 2>&1; then
            _infile="$(COPILOT_RC_ID="$pid" yq -r \
              '.providers[] | select(.id == strenv(COPILOT_RC_ID)) | .models[].id' "$cfg" 2>/dev/null)"
            _n_file="$(printf '%s\n' "$_infile" | command grep -c . || true)"
            _d="$(_copilot_raycast_drift "$_infile" "$_live" | command grep -c . || true)"
            if [ "${_d:-0}" -eq 0 ]; then
              _ok "drift" "the $_n_file model(s) in the file match the live catalogue"
            else
              _note "drift" "$_d difference(s) between the file and the live catalogue"
              _hint "copilot-raycast diff   # then: copilot-raycast generate"
            fi
          fi
          # copilot-api caches /models ONCE per process, so a catalogue that
          # looks stale is a proxy-lifetime artefact, not a bug here.
          _skip "cache" "copilot-api caches /models at start — 'copilot-proxy restart' if stale"
        fi
      fi

      printf '\n'
      if [ "$_fail" -gt 0 ]; then
        printf '%s\n\n' "$_fail failed, $_warn warning(s)"
        unset -f _ok _bad _note _skip _hint 2>/dev/null
        return 1
      fi
      printf '%s\n\n' "all checks passed ($_warn warning(s))"
      unset -f _ok _bad _note _skip _hint 2>/dev/null
      ;;

    edit)
      if [ ! -f "$cfg" ]; then
        printf '%s\n' "copilot-raycast: $cfg does not exist (run 'copilot-raycast generate' first)" >&2
        return 1
      fi
      "${EDITOR:-vi}" "$cfg" || return 1
      if _copilot_raycast_validate "$cfg"; then
        printf '%s\n' "copilot-raycast: $cfg still validates (Raycast reloads within ~5s)"
      else
        printf '%s\n' "copilot-raycast: $cfg is now INVALID — Raycast will silently drop every custom provider" >&2
        printf '%s\n' "  copilot-raycast generate   # or restore from $(_copilot_raycast_backups)" >&2
        return 1
      fi
      ;;

    -h|--help|help)
      printf '%s\n' "Usage: copilot-raycast [status|generate [--dry-run] [--all]|diff|probe [MODEL]|doctor|edit]"
      printf '%s\n' "  status (default)      config path, model count, what Raycast loaded, drift"
      printf '%s\n' "  generate              probe every chat model, then back up + atomically rewrite"
      printf '%s\n' "                        providers.yaml. --dry-run prints instead; --all also emits"
      printf '%s\n' "                        the rejected models, commented out. Other providers in the"
      printf '%s\n' "                        file are preserved (needs yq)."
      printf '%s\n' "  probe [MODEL]         classify one/all models: OK / NOT_SUPPORTED /"
      printf '%s\n' "                        RESPONSES_ONLY. Costs zero quota — the request is"
      printf '%s\n' "                        rejected before inference."
      printf '%s\n' "  doctor                prereqs, proxy, shim, Raycast, config validity, drift"
      printf '%s\n' "  COPILOT_RAYCAST_TEMP  auto|on|off  (default auto — temperature is a heuristic,"
      printf '%s\n' "                        it cannot be probed)"
      printf '%s\n' "  COPILOT_RAYCAST_ID    default copilot — the providers[].id this tool owns"
      printf '%s\n' "  COPILOT_RAYCAST_JOBS  default 6 — concurrent probes in the sweep"
      ;;

    *)
      printf '%s\n' "copilot-raycast: unknown action '$action' (try --help)" >&2
      return 1
      ;;
  esac
}

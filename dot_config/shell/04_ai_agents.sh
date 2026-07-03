# ~/.config/shell/04_ai_agents.sh
# Source: dot_config/shell/04_ai_agents.sh (managed by chezmoi)
#
# SINGLE SOURCE OF TRUTH for the AI-agent autodetect priority and per-vendor
# lightweight model pins consumed by aifix / aiblock / aisuggest / tsum.
# POSIX-shared (no zsh/bash-only features), sourced by both ~/.zshrc and
# ~/.bashrc at shell init.
#
# Consumers — when you add a new agent, update each:
#   - dot_config/zsh/tools/04_ai_capture.zsh:
#       `_aiagent_autodetect` iterates $AICAP_AGENT_PRIORITY;
#       `_aiagent_invoke` reads AICAP_<AGENT>_MODEL.
#   - dot_config/zsh/tools/05_aisuggest.zsh:
#       piggybacks on the two above (no direct read of this file).
#   - dot_config/tmux/executable_tmux-session-summary.py:
#       `detect_agent` iterates $AICAP_AGENT_PRIORITY; `AGENT_CONFIG`
#       reads AICAP_<AGENT>_MODEL. Parses THIS file directly as a fallback
#       for tmux-popup / cron contexts where shell env isn't inherited.
#   - scripts/aiblock.py:
#       same env + same parse-fallback as tsum.
#   - dot_config/shell/44_copilot_embed.sh + scripts/semsearch.py:
#       read AICAP_EMBED_MODEL for the Copilot proxy's /v1/embeddings endpoint
#       (not an autodetect agent — a separate embeddings-model pin).
#
# Override pattern: drop matching `export AICAP_*=…` lines in
# ~/.shellrc.adhoc or ~/.config/zsh/secrets.zsh — they win against the
# `: "${VAR:=…}"` no-op below.

# Skip silently if already sourced (idempotent — safe to dot in sub-shells).
[ -n "${_AICAP_AGENT_CONFIG_SOURCED:-}" ] && return 0
_AICAP_AGENT_CONFIG_SOURCED=1

# Detection priority (space-separated, left = preferred). opencode-first per
# the 2026-05-12 benchmark — ~2-3x faster than alternatives for one-shot
# multi-session prompts. Override globally: `export AICAP_AGENT_PRIORITY=…`.
#
# `agyc` = Antigravity CLI (`agy -p`) reached via a collision-free `agyc` symlink
# (the Antigravity IDE squats the bare `agy`/`antigravity` names — see the ansible
# coding_agents role). It has NO `--model` flag (model is account/config-side), so
# there is intentionally no AICAP_AGYC_MODEL pin below.
: "${AICAP_AGENT_PRIORITY:=opencode claude codex agyc cursor-agent}"

# Per-agent lightweight model pins. Empty value → omit -m/--model at the
# call site so the agent CLI uses its OWN default. That's the robustness
# fallback: if a provider retires a pinned model ID, users unset the env
# var and the CLI's current default kicks in transparently.
: "${AICAP_CLAUDE_MODEL:=haiku}"               # "haiku" is a stable Anthropic alias
: "${AICAP_OPENCODE_MODEL:=github-copilot/claude-haiku-4.5}"
: "${AICAP_CODEX_MODEL:=}"                     # empty: ChatGPT-account auth rejects gpt-5-mini
: "${AICAP_CURSOR_MODEL:=}"                    # empty: cursor-agent picks composer-2-fast
: "${AICAP_OLLAMA_MODEL:=qwen2.5-coder:7b}"    # consumed ONLY by `olr` in 05_ai_run.sh
                                               # (shell-only sugar; not in autodetect, not parsed
                                               # by the Python consumers — see header note)

# HTTP fallback (opt-in only via AICAP_AGENT=http; never auto-detected).
# `openrouter/free` is an auto-router across OpenRouter's free tier — when
# one upstream is rate-limited or retired, it picks another transparently.
# More robust than pinning a specific free model ID (those churn quarterly:
# e.g. google/gemini-2.0-flash-exp:free was retired between 2025-Q1 and 2026-Q2).
: "${AICAP_HTTP_URL:=https://openrouter.ai/api/v1/chat/completions}"
: "${AICAP_HTTP_MODEL:=openrouter/free}"

# Embeddings model for the local Copilot proxy, consumed by copilot-embed /
# semsearch (44_copilot_embed.sh + scripts/semsearch.py — both POST to
# /v1/embeddings). Empty value → omit "model" so the endpoint default kicks in
# (same robustness idiom as the pins above). Copilot serves three 1536-dim
# models: text-embedding-3-small (default), -ada-002, -3-small-inference.
# GOTCHA (verified 2026-07): the proxy requires the request `input` to be an
# ARRAY — a scalar string 400s ("Bad Request"; this is the fork's issue #100).
: "${AICAP_EMBED_MODEL:=text-embedding-3-small}"

# Export so subprocess (Python tsum / aiblock / semsearch) inherits.
export AICAP_AGENT_PRIORITY \
       AICAP_CLAUDE_MODEL AICAP_OPENCODE_MODEL AICAP_CODEX_MODEL AICAP_CURSOR_MODEL \
       AICAP_OLLAMA_MODEL \
       AICAP_HTTP_URL AICAP_HTTP_MODEL \
       AICAP_EMBED_MODEL

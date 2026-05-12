# 42_gitlab.sh - GitLab helpers using glab CLI (shared bash + zsh).
# Moved from dot_config/zsh/tools/42_gitlab.zsh; the only zsh-ism was
# `emulate -L zsh` (gated below).

# ==============================================================================
# Method 1: Direct shell function (no AI agent needed)
# ==============================================================================

# Create a GitLab repo under a group from the current git repo, set origin, and push.
# Detects current folder name as repo name and current branch automatically.
#
# Usage:
#   glcreate <group> [description]
#
# Examples:
#   glcreate david_quick_tries
#   glcreate david_quick_tries "My awesome project"
#
# If no description is given, the repo is created without one.
# The repo is created as private by default.
glcreate() {
  [ -n "$ZSH_VERSION" ] && emulate -L zsh

  local group="${1:?Usage: glcreate <group> [description]}"
  local desc="${2:-}"
  local name
  name=$(basename "$(pwd)")
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")

  echo "Creating: ${group}/${name} (branch: ${branch})"

  glab repo create "${group}/${name}" \
    --private \
    --defaultBranch "$branch" \
    --skipGitInit \
    ${desc:+--description "$desc"} \
  && {
    # Add or update origin remote
    git remote add origin "git@gitlab.com:${group}/${name}.git" 2>/dev/null \
      || git remote set-url origin "git@gitlab.com:${group}/${name}.git"
  } \
  && git push -u origin "$branch"
}

# ==============================================================================
# Method 2: AI agent assisted (summarizes description from project content)
# ==============================================================================

# Create a GitLab repo using an AI coding agent to inspect the project,
# auto-generate a description, create the repo, set origin, and push.
#
# Supported agents: opencode (default), claude, codex, cursor-agent
# Set GLCREATE_AGENT to change the default agent.
# Set GLCREATE_LANG to change the default prompt language (zh or en, default: zh).
#
# Usage:
#   glcreate-ai <group> [description] [--agent <name>] [--lang zh|en]
#
# Examples:
#   glcreate-ai david_quick_tries
#   glcreate-ai david_quick_tries "Override description"
#   glcreate-ai david_quick_tries --agent claude
#   glcreate-ai david_quick_tries --lang en
#
# If no description is given, the agent will summarize one from the project content.
glcreate-ai() {
  [ -n "$ZSH_VERSION" ] && emulate -L zsh

  local group="" desc="" agent="${GLCREATE_AGENT:-opencode}" lang="${GLCREATE_LANG:-zh}"

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) agent="$2"; shift 2 ;;
      --lang)  lang="$2"; shift 2 ;;
      *) [ -z "$group" ] && group="$1" || desc="$1"; shift ;;
    esac
  done

  if [ -z "$group" ]; then
    echo "Usage: glcreate-ai <group> [description] [--agent opencode|claude|codex|cursor-agent] [--lang zh|en]"
    echo "  Set GLCREATE_AGENT env var to change default agent (default: opencode)"
    echo "  Set GLCREATE_LANG  env var to change default language (default: zh)"
    return 1
  fi

  local name
  name=$(basename "$(pwd)")
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
  local prompt

  case "$lang" in
    en)
      prompt="Use glab to create a private repo under gitlab.com/${group}, repo name: ${name}, default branch: ${branch}. Set the origin remote and push.${desc:+ Description: ${desc}.} If no description is provided, summarize one sentence from the project content."
      ;;
    zh|*)
      prompt="用 glab 把這個 repo 建到 gitlab.com/${group} 底下，repo name: ${name}，private，default branch: ${branch}，設定 origin remote 並 push。${desc:+Description: ${desc}。}如果沒給 description 就根據項目內容總結一句。"
      ;;
  esac

  echo "Agent: ${agent} | Lang: ${lang} | Repo: ${group}/${name} | Branch: ${branch}"

  case "$agent" in
    opencode)       opencode run "$prompt" ;;
    claude)         claude -p "$prompt" ;;
    codex)          codex exec "$prompt" ;;
    cursor-agent)   cursor-agent -p "$prompt" ;;
    *)              echo "Unknown agent: ${agent}"; return 1 ;;
  esac
}

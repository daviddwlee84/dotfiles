# mkdocs anchor drift: stale section links across existing docs

**Status**: P3 ready
**Effort**: S (maybe 30-60 min batch)
**Related**: [`mkdocs.yml`](../mkdocs.yml) `validation.links.anchors` · [`docs/`](../docs/) per-file fixes

## Context

**2026-04**: bootstrapped the mkdocs-material site. Strict build flagged ~20 stale in-page / cross-page `#anchor` links in existing docs. Most are pre-mkdocs: authors typed `#pre-commit--gitleaks` etc. on GitHub where automatic section-header slugification is lax, but MkDocs Material computes slugs differently (or the referenced section was renamed).

Temporarily set `validation.links.anchors: info` in `mkdocs.yml` so the first deploy passes. That masks future regressions; this backlog ensures we come back.

## Files with stale anchors (from strict-build output)

- `docs/tools/pre-commit.md` → `#pre-commit--gitleaks`, `#shellcheck--shfmt` in this_repo/*
- `docs/tools/sesh.md` → `#the-three-layer-navigation-sesh--wt--wtcd`
- `docs/tools/worktrunk.md` (self-links) → `#install--shell-integration-in-this-repo`, `#the-three-layer-navigation-sesh--wt--wtcd`, `#per-worktree-claude--opencode`, `#merge--cleanup-flow`, `#llm-commit-messages--when-to-bother`
- `docs/tools/tmux/README.md` → `./keybindings.md#popup-menu-prefix--space`
- `docs/zsh/aliases.md` → `#github--gitlab`, `#package-managers--runtime` (local ToC drift)
- `docs/tools/opencode.md` → `agent-overlays.md#opencode--agentsopencodeoverlayjson`
- `docs/this_repo/workflow.md` → `../tools/worktrunk.md#per-worktree-claude--opencode`
- `docs/this_repo/fleet-apply.md` → `#conflict-handling---force-vs---keep-going`
- `docs/this_repo/cheatsheet.md` → `#pre-commit--gitleaks`
- `docs/tools/chezmoi-prefixes.md` → `#dot_confignvimcreate_lazy-lockjson--seed-once-never-overwrite`, `#dot_claudemodify_settingsjson--partial-json-management-via-jq`
- `docs/tools/containers.md` → `#rootless-docker-linux--systemd---user-drop-in`
- `docs/linux-package-sources.md` → `this_repo/ansible_customization.md#glibc_2xx-...`
- `docs/infra/shared-storage.md` → `#moosefs--lizardfs`

## Options considered

| Option | Pros | Cons |
|---|---|---|
| Keep `anchors: info` forever | Zero-maintenance | Future anchor drift silently ships |
| Fix the ~20 current links | Clean, strict catches new drift | 30-60 min batch edit + possibly touches files other agents are editing |
| Add `pymdownx.slugs.slugify` config to match GitHub-flavor slugs | Could auto-resolve some | MkDocs Material already uses GitHub-flavor; most drift is genuine text-changed-but-link-didn't |

## Decision

**Defer** — ship first deploy with `anchors: info`. Open a dedicated cleanup session later (safer when fewer other agents are actively editing docs files). Once fixed, raise back to `warn` or `error` in `mkdocs.yml`.

## References

- MkDocs validation config: <https://www.mkdocs.org/user-guide/configuration/#validation>
- Current `mkdocs.yml` has inline TODO comment pointing here.

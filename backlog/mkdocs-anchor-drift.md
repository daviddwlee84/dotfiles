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
- `docs/playbooks/workflow.md` → `../tools/worktrunk.md#per-worktree-claude--opencode`
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

## 2026-04 update — zh-TW i18n added, cross-page anchor drift expanded

After translating all 82 docs pages to zh-TW (commit `38af46b`) and switching
the toc plugin to `pymdownx.slugs.slugify` for Unicode-friendly heading IDs,
in-page (TOC self-link) drifts in zh-TW pages were fixed automatically (e.g.,
`worktrunk.zh-TW.md` TOC anchors `#冷啟動消除`, `#合併與清理流程`, etc., now
resolve to the translated heading IDs).

The residual ~46 zh-TW INFO entries are **cross-page** links: a zh-TW page
links to another zh-TW page using the original *English* anchor name, but the
destination has translated headings whose Unicode-slugified IDs don't match.

Examples (sampled from `mkdocs build` output):

- `playbooks/workflow.zh-TW.md` → `tools/worktrunk.zh-TW.md#per-worktree-claude--opencode` (target: `#每個-worktree-一個-claudeopencode`)
- `infra/README.zh-TW.md` → `infra/virtualization.zh-TW.md#desktop-vm-managers` (target: `#桌面-vm-管理員` or similar)
- `infra/compute-scheduling.zh-TW.md` → `infra/virtualization.zh-TW.md#cloud-native-vms-on-top-of-kubernetes`
- `tools/agent-overlays.zh-TW.md` → `tools/opencode.zh-TW.md#claude-opus-stream-stall-on-github-copilot`
- `this_repo/fleet-apply.zh-TW.md` self-anchors `#conflict-handling---force-vs---keep-going`, `#per-machine-git-overrides-gitconfiglocal`
- `this_repo/upgrades.zh-TW.md` self-anchors `#run-order`, `#category-matrix`

**Two cleanup approaches** (decide at fix time):

1. **Update each linker** to use the Chinese anchor — preserves readable URLs
   but breaks any external bookmark someone may have made to the original
   English anchor (low risk: site is recent).
2. **Add explicit `{#english-anchor}` attribute to translated headings** via
   `attr_list` (already enabled) — preserves English deep-link compatibility.
   Example: `## 桌面 VM 管理員 {#desktop-vm-managers}`.

Approach (2) is more robust for a frequently-cited destination; (1) is fine
for one-off cross-references. Mix and match.

All 46 are INFO-level and tolerated by `validation.links.not_found: info`,
so no blocker — defer to a focused cleanup pass.

## References

- MkDocs validation config: <https://www.mkdocs.org/user-guide/configuration/#validation>
- Current `mkdocs.yml` has inline TODO comment pointing here.
- `pymdownx.slugs.slugify` configuration in `markdown_extensions.toc` (added 2026-04 with the zh-TW i18n).

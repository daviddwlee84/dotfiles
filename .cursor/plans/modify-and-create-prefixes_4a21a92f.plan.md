---
name: modify-and-create-prefixes
overview: \u5c07 `dot_claude/settings.json` \u6539\u6210 `modify_` + jq deep-merge overlay\uff08chezmoi \u53ea\u5f37\u5236\u7ba1\u8056 5 \u500b key\uff0c\u5176\u9918 runtime \u52a0\u7684\u6b04\u4f4d\u5168\u90e8\u4fdd\u7559\uff09\uff1b\u5c07 `dot_config/nvim/lazy-lock.json` \u6539\u6210 `create_` seed-only\uff0c\u65b0\u6a5f\u9996\u6b21\u5efa\u7acb\u5f8c\u5c31\u4e0d\u518d\u8986\u84cb\uff0c\u89e3\u6c7a\u300c\u6bcf\u6b21 chezmoi diff \u90fd\u6709\u96dc\u8a0a\u300d\u7684\u75db\u9ede\u3002
todos:
  - id: convert_claude_settings
    content: 將 dot_claude/settings.json git mv 成 dot_claude/modify_settings.json，改成 jq deep-merge overlay script，設 exec bit
    status: pending
  - id: convert_lazy_lock
    content: 將 dot_config/nvim/lazy-lock.json git mv 成 dot_config/nvim/create_lazy-lock.json（內容不變）
    status: pending
  - id: verify_no_diff
    content: 執行 chezmoi diff / apply --dry-run 驗證兩個檔案不再產生誤單
    status: pending
  - id: update_docs
    content: 在 CLAUDE.md 加 Selective 管理章節（說明 modify_/create_ 用法、強制管理哪些 key、更新 lock 時用 chezmoi re-add）
    status: pending
isProject: false
---

# \u8b93 Claude settings \u8ddf lazy-lock.json \u4e0d\u518d\u7522\u751f\u7121\u8b02 diff

## \u554f\u984c\u8ddf\u60f3\u6cd5

\u73fe\u72c0 `chezmoi diff ~/.claude/settings.json` \u6703\u770b\u5230\uff1a

- `+ "skipAutoPermissionPrompt": true` \u548c `+ "permissions": { "defaultMode": "auto" }` \u2014 Claude Code \u81ea\u5df1\u52a0\u7684 runtime \u6b04\u4f4d
- `statusLine` \u5728 JSON \u88e1\u7684\u4f4d\u7f6e\u88ab\u91cd\u65b0\u6392\u5e8f

`lazy-lock.json` \u5247\u662f\u6bcf\u6b21 `:Lazy update` \u6216\u8de8 OS \u958b\u6a5f\u90fd\u6703\u6574\u5168\u6539\u5beb\u3002

\u5169\u500b\u6a94\u524d\u7db4\u89e3\u6cd5\uff1a

- `dot_claude/modify_settings.json` \u2014 chezmoi \u628a\u73fe\u6709 target \u5f9e stdin \u9935\u9032\u4f86\uff0cscript \u8f38\u51fa\u65b0\u5167\u5bb9\u3002\u7528 `jq '. * $overlay'` \u505a deep-merge\uff0c\u53ea\u5f37\u5236 5 \u500b\u7ba1\u7406\u7684 key\uff0c\u5176\u9918 runtime \u6b04\u4f4d\u4e00\u5f8b\u4fdd\u7559\u3002
- `dot_config/nvim/create_lazy-lock.json` \u2014 `create_` \u53ea\u5728 target \u4e0d\u5b58\u5728\u6642\u5beb\u5165\uff08\u65b0\u6a5f seed baseline\uff09\uff0c\u5df2\u5b58\u5728\u5c31\u4e0d\u7ba1\u3002

## \u5be6\u4f5c\u6b65\u9a5f

### 1\uff09`dot_claude/settings.json` \u2192 `dot_claude/modify_settings.json`

\u5148 `git mv`\uff0c\u518d\u6539\u6210\u4e00\u500b shell script\uff08chezmoi \u6703\u628a `modify_` \u6a94\u7576 script \u57f7\u884c\uff0c\u9700\u8981\u6709 exec bit\uff09\u3002

[dot_claude/modify_settings.json](dot_claude/modify_settings.json) \u5167\u5bb9\uff1a

```sh
#!/bin/sh
# chezmoi modify_ script: deep-merge overlay into existing ~/.claude/settings.json
# Keys in overlay are enforced by chezmoi; any other keys that Claude Code adds
# at runtime (permissions, skipAutoPermissionPrompt, model, etc.) are preserved.
set -eu

overlay=$(cat <<'JSON'
{
  "hooks": {
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "~/.claude/hooks/notify.sh" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/notify.sh" } ] }
    ]
  },
  "enabledPlugins": {
    "pyright-lsp@claude-plugins-official": true,
    "claude-hud@claude-hud": true
  },
  "extraKnownMarketplaces": {
    "claude-hud": { "source": { "source": "github", "repo": "jarrodwatts/claude-hud" } }
  },
  "skipDangerousModePermissionPrompt": true,
  "statusLine": {
    "type": "command",
    "command": "bash -c 'plugin_dir=$(ls -d \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/claude-hud/claude-hud/*/ 2>/dev/null | sort -V | tail -1); runtime=$(command -v bun 2>/dev/null || command -v node 2>/dev/null); [ -z \"$runtime\" ] && exit 0; rt=\"${runtime##*/}\"; if [ \"$rt\" = \"bun\" ]; then exec \"$runtime\" --env-file /dev/null \"${plugin_dir}src/index.ts\"; else exec \"$runtime\" \"${plugin_dir}dist/index.js\"; fi'"
  }
}
JSON
)

base=$(cat)
[ -z "$base" ] && base='{}'

printf '%s' "$base" | jq --argjson overlay "$overlay" '. * $overlay'
```

\u5e7e\u500b\u95dc\u9375\u9ede\uff1a

- `jq '. * $overlay'` \u5c0d object \u9012\u8ff4 merge\uff0c\u5c0d array \u76f4\u63a5\u6574\u500b\u53d6\u4ee3 \u2192 `hooks.Notification` \u7684\u5167\u5bb9\u6703\u7528\u6211\u7684\u5beb\u6cd5\u8986\u8fc7\u53bb\uff0c\u4e0d\u6703\u7d2f\u7a4d\u8907\u88fd\u3002
- `base` \u7a7a\uff08\u65b0\u6a5f target \u4e0d\u5b58\u5728\uff09\u6642 fallback \u6210 `{}`\uff0c\u5c31\u7b49\u540c\u76f4\u63a5\u5beb\u5165 overlay\u3002
- chezmoi `modify_` \u6a94\u9700\u8981 exec bit\uff1a`chmod +x dot_claude/modify_settings.json` \u4e26\u78ba\u4fdd\u88ab\u5165 git index \u7684 mode\u3002
- jq \u5728\u6240\u6709 profile \u88e1\u90fd\u6709 \u2014 `base` role \u5df2\u7d93\u5b89\u88dd\uff08\u8ddf `ripgrep`/`fd` \u540c\u5c64\uff09\u3002

### 2\uff09`dot_config/nvim/lazy-lock.json` \u2192 `create_lazy-lock.json`

`git mv dot_config/nvim/lazy-lock.json dot_config/nvim/create_lazy-lock.json`\uff0c\u5167\u5bb9\u4e0d\u8b8a\u3002

- `create_` \u53ea\u5728 `~/.config/nvim/lazy-lock.json` **\u4e0d\u5b58\u5728** \u6642 seed\uff0c\u5df2\u5b58\u5728\u5c31\u6c38\u9060\u4e0d\u8986\u84cb \u2192 \u6b63\u5e38 `:Lazy update` \u4e0d\u518d\u7522 chezmoi diff\u3002
- \u65b0\u6a5f\u5b89\u88dd\u5019 `chezmoi apply` \u4ecd\u7136\u6703\u5e36\u4e00\u5957 baseline lockfile\uff0c\u7b2c\u4e00\u6b21\u958b\u770b Neovim \u7684 `:Lazy sync` \u5c31\u6703\u6309\u7167 repo \u7248\u672c reproducibility\u3002
- \u6703\u6709\u7684 trade-off\uff1a\u4ee5\u5f8c\u60f3\u300c\u95dc\u6a5f\u66f4\u65b0\u4e00\u4e0b\u6240\u6709\u6a5f\u5668\u7684 lock\u300d\u6642\u9700\u8981\u624b\u52d5 `chezmoi re-add ~/.config/nvim/lazy-lock.json`\uff08\u5c07 live \u5beb\u56de source\uff09\u3002\u9019\u500b\u662f\u6bd4\u300c\u6bcf\u6b21 apply \u90fd\u6709 diff\u300d\u597d\u5f88\u591a\u7684 trade-off\u3002

### 3\uff09\u6587\u4ef6\u66f4\u65b0

\u5728 [CLAUDE.md](CLAUDE.md) \u52a0\u4e00\u6bb5 \u300cSelective \u6a94\u6848\u7ba1\u7406\uff1amodify_ \u8ddf create_\u300d\uff0c\u5beb\u660e\uff1a

- `dot_claude/modify_settings.json`\uff1a\u54ea\u4e9b key \u6703\u88ab\u5f37\u5236 merge\uff08\u4ee5\u53ca\u5982\u4f55\u65b0\u589e\uff09\uff1b\u8cbc\u4e0a jq \u6307\u4ee4\u7684\u8aaa\u660e\u4ee5\u4fbf\u672a\u4f86\u8ffd\u52a0\u6b04\u4f4d\u3002
- `dot_config/nvim/create_lazy-lock.json`\uff1ablueprint\u3001\u66f4\u65b0\u7528 `chezmoi re-add` \u7684\u4f7f\u7528\u8aaa\u660e\u3002

## \u9a57\u8b49

```bash
# Claude settings: should show no diff even after Claude adds skipAutoPermissionPrompt
chezmoi diff ~/.claude/settings.json   # \u671f\u671b: \u7121\u8f38\u51fa
chezmoi apply --dry-run -v ~/.claude/settings.json
cat ~/.claude/settings.json | jq '.permissions, .skipAutoPermissionPrompt'  # \u671f\u671b: \u4ecd\u4fdd\u7559

# lazy-lock: ensure managed state change is clean
chezmoi diff ~/.config/nvim/lazy-lock.json   # \u671f\u671b: \u7121\u8f38\u51fa\uff08target \u5df2\u5b58\u5728 -> create_ \u8df3\u904e\uff09
# \u6a21\u64ec\u65b0\u6a5f seed:
mv ~/.config/nvim/lazy-lock.json /tmp/ && chezmoi apply ~/.config/nvim/lazy-lock.json
diff ~/.config/nvim/lazy-lock.json /tmp/lazy-lock.json   # \u671f\u671b: identical
```

## \u4e0d\u9069\u5408\u505a\u7684\u4e8b

- \u4e0d\u7528 `modify_` \u65b9\u5f0f\u505a lazy-lock.json\uff08\u6c92\u6709\u300c\u6df7\u5408\u7ba1\u7406\u300d\u7684 merge \u610f\u7fa9\uff0cROI \u4f4e\uff09
- \u4e0d\u52a8 `dot_claude/hooks/` \u548c `dot_claude/plugins/` \u2014 \u9019\u4e9b\u90fd\u662f\u6b63\u5e38\u7684\u975c\u614b\u6a94\uff0c\u6c92\u6709 drift \u554f\u984c

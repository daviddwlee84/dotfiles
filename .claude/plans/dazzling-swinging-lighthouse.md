# Context

The Windows Copilot proxy has the correct live `[1m]` model conversion, but it has drifted from the Unix reference in three operational contracts: its copied throttle shim predates Unix commit `ee5612c` (so it lacks SSE keepalives and stall watchdogs), its Claude selector ranks unknown future GPT IDs differently from both Codex selectors and Unix, and Claude `copilot-model --auto` does not apply the catalog eligibility policy already used by Codex. The existing shim parity test silently skips in a standalone Windows checkout, and the docs use “fallback” in ways that can be mistaken for request-time cross-model replay.

The intended result is a self-contained Windows checkout whose CI proves the reviewed Unix shim artifact is present, whose automatic selectors share one eligible-chat/OpenAI-tier policy while retaining Claude-first vs. Codex-first provider preference, and whose bilingual docs clearly state that cross-model request-time failover is **not** implemented. The Unix repo remains read-only in this change, and the unrelated modified SpecStory transcript in the Windows repo must remain untouched.

## Implementation

1. **Synchronize and pin the shared shim**
   - Verify the current Unix source `/Users/david/.local/share/chezmoi/dot_config/shell/copilot-throttle-shim.js` still matches source commit `ee5612c57278df5540ac80ad28ede91b57c3f09c` and SHA-256 `8fbada960e5a06e62f4b81cd873574db85129c2fb7c7156e96cd5bdce5f0e8ba`, then copy its bytes wholesale to `dot_config/powershell/copilot-throttle-shim.js`; do not merge, reformat, or add Windows-only code.
   - Add a narrow `.gitattributes` rule forcing LF for this shared JS file so `windows-latest` does not change the reviewed bytes through `core.autocrlf`.
   - Replace the sibling-path-dependent Pester assertion with an unconditional local artifact contract in `tests/Copilot.Tests.ps1`: record the full Unix source commit as the version/provenance and assert the Windows-local file’s SHA-256. No test may require `/Users/david/.local/share/chezmoi` or network access.
   - Add an `AGENTS.md` mirror rule requiring future updates to copy the Unix shim verbatim, update the recorded source commit/hash, and run the local shim tests.

2. **Share the selectable catalog policy for automatic decisions**
   - In `dot_config/powershell/modules/Copilot/Copilot.psm1`, add private `Get-CopilotSelectableModelIds($Catalog)` beside `Get-CopilotCatalogIds`.
   - Preserve the current permissive Codex policy: exclude only `policy.state == disabled`, `model_picker_enabled == false`, and `capabilities.type == embeddings`; missing optional metadata remains eligible; return unique nonempty raw IDs.
   - Keep `Get-CopilotCatalogIds` as the raw/manual/diagnostic view for `copilot-model -l`, fzf/manual matching, explicit model overrides, doctor inventory, and metadata/context lookup.
   - Use selectable IDs for Claude `copilot-model --auto`, Codex implicit auto-selection (replacing its inline filter), and automatically derived alternative role aliases in `Get-CopilotModelProfile`. An explicitly selected main remains authoritative if present in the raw catalog; if no eligible Terra/Luna/Claude-family role candidate exists, that role falls back to the selected main rather than a vetoed entry.

3. **Centralize OpenAI tier ordering without merging provider policies**
   - Add private `Select-CopilotBestOpenAIModel` and call it from both `Select-CopilotBestModel` and `Select-CopilotBestCodexModel`.
   - Encode one known order: `gpt-5.6-sol > gpt-5.6-terra > gpt-5.5 > gpt-5.4 > gpt-5.3-codex > gpt-5.6-luna > gpt-5.4-mini > gpt-5-mini`; only after all named tiers are absent consider unknown non-light GPT IDs, generic Codex IDs, then remaining GPT IDs. This makes Luna/mini beat an unknown future GPT, matching Unix and the current Codex picker.
   - Retain the intentional outer order: Claude Code uses Claude → shared OpenAI → Gemini → other; Codex uses shared OpenAI → Claude → Gemini → other.
   - Leave `ConvertTo-CopilotClaudeModel` metadata-driven and per-role. Do not expand this change into the separate manual-suffix, offline-hint, or explicit-Codex-limit issues.

4. **Add regression coverage in `tests/Copilot.Tests.ps1`**
   - Use one table of all-OpenAI vectors against the shared helper and both client selectors: complete named-tier ordering, Luna/mini versus an unknown future GPT, unknown GPT when no named tier exists, and `[1m]` input normalization. Keep separate mixed-provider assertions for Claude-first and Codex-first behavior.
   - Test selectable catalog filtering independently for each veto, absent-metadata eligibility, null/duplicate IDs, and an empty eligible result.
   - Add wiring tests showing Claude `--auto` skips vetoed higher-ranked entries and role-profile derivation does not assign disabled/hidden/embedding-only aliases; preserve the existing per-role `[1m]` threshold/profile tests.
   - Port the Unix Bun shim coverage into the existing Responses-shim context: zstd normalization, literal-only `stream: true` classification, slow-stream keepalives followed by real events, no keepalive for fast/non-streaming responses, preserved delayed non-streaming HTTP errors, and an SSE `error` event when an error arrives after early stream commitment. Bun skips remain allowed locally, but `windows-latest` installs Bun and must execute them.

5. **Document selection/retry boundaries and operational behavior**
   - Update both `docs/copilot-proxy.md` and `docs/copilot-proxy.zh-TW.md` together. State that automatic catalog selection happens before inference/launch, uses only selectable chat entries, and that “fallback order” means ranking candidates at that stage.
   - Separately describe same-model shim retries (the buffered request retains the same model), SSE keepalive/pre-header and mid-stream stall watchdog behavior, configurable timing knobs, and delayed-error stream semantics.
   - Define request-time cross-model failover as replaying a failed logical request on another model, then state explicitly that it is not implemented; doctor still performs one inference attempt and HTTP 402 billing errors remain nonretryable.
   - Update `.chezmoitemplates/dotfiles-windows-skill.md` (the agent-skill SSOT) with the selectable policy, Claude-first/Codex-first distinction, keepalive/stall behavior, and no-cross-model-replay boundary. Add the new shim env knobs to the module’s existing environment comments. Do not edit the renderer stubs, add docs pages, change `mkdocs.yml`, or change exports/module version.

## Verification

From `/Users/david/src/tries/2026-07-09-windows-dotfiles`:

1. Confirm the pinned raw artifact: `shasum -a 256 dot_config/powershell/copilot-throttle-shim.js` and `git check-attr eol -- dot_config/powershell/copilot-throttle-shim.js`.
2. Run the focused suite: `pwsh -NoProfile -Command "Invoke-Pester -CI -Path ./tests/Copilot.Tests.ps1 -Output Detailed"`.
3. Run all tests: `pwsh -NoProfile -Command "Invoke-Pester -CI -Path ./tests -Output Detailed"`.
4. Run PowerShell lint with `PSScriptAnalyzerSettings.psd1`; fail only on analyzer errors, matching CI.
5. Exercise the copied JS with Bun through the new normalization/stream tests (and a direct `wantsStream` import smoke if Pester cannot run in the macOS PowerShell provider).
6. Render/parse the changed skill template through the repo’s isolated chezmoi pattern where practical; rely on the existing `windows-latest` files-only apply as the target-platform config validator.
7. Run `just docs-build` for the strict bilingual MkDocs build.
8. Run `git diff --check` and inspect `git status`/`git diff` to ensure no Unix file or pre-existing `.specstory/history/2026-08-13_04-06-22Z-administrator-in-via-v3.md` change is included.
9. If a branch is pushed later, confirm the existing `windows` workflow passes PSScriptAnalyzer, template parsing, isolated apply, and all Pester/Bun-backed tests; no workflow edit is needed.

## Critical files

- `.gitattributes`
- `AGENTS.md` (`CLAUDE.md` is its symlink)
- `dot_config/powershell/copilot-throttle-shim.js`
- `dot_config/powershell/modules/Copilot/Copilot.psm1`
- `tests/Copilot.Tests.ps1`
- `docs/copilot-proxy.md`
- `docs/copilot-proxy.zh-TW.md`
- `.chezmoitemplates/dotfiles-windows-skill.md`

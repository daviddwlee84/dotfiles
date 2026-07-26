# `unknown --custom-status` — herdr 0.7.4 silently replaced custom-status with metadata tokens

## Symptoms

After upgrading herdr (0.7.3 → 0.7.4 or later), the review-pending ⭐ stops working:

```console
$ herdr pane report-metadata w1:p1 --source review --custom-status "⭐ REVIEW"
error: unexpected argument '--custom-status' found
```

Concretely, in this repo:

- `prefix + m` (toggle review flag) and `hmark` / `hunmark` die with the above.
- `tv herdr-review` / `prefix + i` opens **empty** — the channel's jq filter reads a
  `custom_status` field that no longer exists, so it matches nothing and reports no error.
- Any ⭐ set before the upgrade vanishes from the sidebar.

Distinguishing it from [the other herdr upgrade trap](herdr-brew-upgrade-strands-running-server.md):
this one fails during **client-side argument parsing**, so you get `unexpected argument`
rather than `protocol_mismatch`, and **restarting the server does not fix it**.

## Root cause

herdr 0.7.4 replaced the single free-text custom-status with a namespaced **metadata token
map**:

| | ≤ 0.7.3 | ≥ 0.7.4 |
|---|---|---|
| set | `--custom-status "⭐ REVIEW"` | `--token review="⭐ REVIEW"` |
| clear | `--clear-custom-status` | `--clear-token review` |
| read | `.result.pane.custom_status` (string) | `.result.pane.tokens` (`{name: value}` map, ≤ 32 entries, names `^[A-Za-z0-9_-]{1,32}$`) |
| render | automatic in the sidebar | **only** where a row layout names `$<token>` |

**The removal is not listed as a breaking change.** It is folded into a 0.7.4 *"### Added"*
bullet — *"configurable row layouts for expanded Space and Agent sidebar entries, including
built-in display tokens, per-agent overrides, custom metadata tokens, and pane/workspace
metadata reporting through the CLI and socket API"* — with no deprecation notice and no
mention of `custom_status` anywhere in the changelog. Nothing warns you before the CLI
rejects the flag.

## Fix

Three names must move together — that is the whole migration:

1. **`dot_config/herdr/executable_review-mark.sh`** — `TOKEN='review'`; `--token "$TOKEN=$status"`,
   `--clear-token "$TOKEN"`, and read with `jq -r --arg t "$TOKEN" '.result.pane.tokens[$t] // ""'`.
   Presence of the token is now the flag, so the old `MATCH='REVIEW'` substring test is gone.
2. **`dot_config/television/cable/herdr-review.toml`** — `select((.tokens.review? // "") != "")`
   and emit `.tokens.review`.
3. **`.chezmoitemplates/herdr/config.toml`** — the part that is easy to miss:

```toml
[ui.sidebar.agents]
rows = [
  ["state_icon", "workspace", "tab", "$review"],
  ["agent"],
]
```

Without step 3 the flag *works* (the API stores it, `prefix+i` lists it) but is **invisible in
the sidebar**, because tokens — unlike `custom_status` — are only rendered where a row layout
references them. herdr's own default is `[["state_icon", "workspace", "tab"], ["agent"]]`;
we append `$review` to the first row.

Validate before applying — `herdr config check` is client-local, so it works even while a
stale server is running:

```bash
chezmoi execute-template < .chezmoitemplates/herdr/config.toml > /tmp/h.toml
HERDR_CONFIG_PATH=/tmp/h.toml herdr config check     # => "config: ok"
```

It genuinely catches mistakes here — a misspelled key reports
`unknown config key ui.sidebar.agents.rowz; ignoring key`, and a bare (non-`$`) custom token
reports ``unknown sidebar token `foo`; custom tokens must start with `$` ``.

## Silver lining

`backlog/herdr-usage-status-driver.md` was blocked on `custom_status` being one value per
pane — the deferred usage driver and the review ⭐ would have fought over the same visible
label. Namespaced tokens dissolve that: a `usage` token and a `review` token coexist. The
only carry-over is that both must be listed in the same `[ui.sidebar.agents] rows` block.

## Pinning cost

Overriding `rows` means our managed `[ui]` table now pins herdr's sidebar layout — upstream
changes to the default rows will not reach us. Re-check the block against
`herdr --default-config` on herdr upgrades.

## See also

- [`herdr-brew-upgrade-strands-running-server`](herdr-brew-upgrade-strands-running-server.md) — the *other* breakage from the same upgrade (protocol mismatch)
- [`docs/tools/herdr.md`](../docs/tools/herdr.md) § Review-pending flag

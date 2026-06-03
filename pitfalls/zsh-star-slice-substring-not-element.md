# `svibe N opencode` first pane runs `o`: `command not found: o`

**Symptoms** (grep this section):
- `zsh:1: command not found: o`
- `[o exited — back in shell. Re-run with: o]` (svibe `--on-exit shell` hint, but the command is a single letter)
- Only the **first** agent pane of a `svibe` / multi-pane layout is broken; the
  rest run the real agent (`opencode`, `claude`, …) fine
- Agent name is truncated to its first character (`opencode` → `o`, `claude` → `c`)
- Reproduces in **zsh only**; bash runs the same function correctly

**First seen**: 2026-06
**Affects**: zsh (all versions); any code using `${array[*]:offset:length}` expecting array-element slicing
**Status**: fixed in `dot_config/shell/22_sesh.sh` (`${agents[*]:0:1}` → `${agents[@]:0:1}`)

## Symptom

```
❯ svibe 4 opencode
# pane 1 (top-left):
zsh:1: command not found: o
[o exited — back in shell. Re-run with: o]
# panes 2–4: opencode launches normally
```

The agent array was `agents=(opencode opencode opencode opencode)`. The first
pane was created from `${agents[*]:0:1}` and the remaining panes from
`${agents[@]:1}`. Only the first pane is wrong.

## Root cause

In zsh, `[*]` and `[@]` behave **differently** under the `:offset:length`
substring/slice operator — the opposite of what the C-like `:0:1` syntax
suggests:

```zsh
agents=(opencode opencode opencode opencode)
echo "${agents[*]:0:1}"   # → o          (substring of the JOINED string)
echo "${agents[@]:0:1}"   # → opencode   (first ARRAY ELEMENT)
echo "${agents[@]:1}"     # → opencode opencode opencode   (elements 2..N)
```

`${agents[*]:0:1}` first joins the whole array into one string with IFS
(`"opencode opencode opencode opencode"`), then applies a **string** offset/length
→ characters `[0,1)` → `o`. `${agents[@]:0:1}` instead does **array-element**
slicing → the first element → `opencode`.

bash masks the bug: there, both `${arr[*]:0:1}` and `${arr[@]:0:1}` return the
first element (`opencode`), so the function is correct under bash and only the
zsh path is broken. `22_sesh.sh` is a shared backend sourced by both shells, so
the bug hid in a "works in bash, broken in zsh" blind spot.

The buggy line (the comment directly above it even said `[@]`, the code had `[*]`):

```zsh
# `${agents[@]:0:1}` is bash-style array slicing (0-indexed); zsh
# supports the same syntax on `[@]`, sidestepping the bash-0/zsh-1 indexing fork.
local first_agent="${agents[*]:0:1}"   # ← BUG: [*] joins then substrings → "o"
```

## Workaround

Use `[@]`, not `[*]`, whenever the `:offset:length` is meant to slice **array
elements**:

```zsh
local first_agent="${agents[@]:0:1}"   # first element, both zsh and bash
```

Quick disambiguation test:

```zsh
zsh -fc 'a=(opencode x y); echo "[${a[*]:0:1}]"; echo "[${a[@]:0:1}]"'
# [o]
# [opencode]
```

## Prevention

- In zsh, reserve `${arr[*]}` for "join the whole array into one string"; reach
  for `${arr[@]}` for any element-wise operation, **especially** with
  `:offset:length`. The `[*]` + slice combination almost always means a bug.
- To take the first element portably across zsh/bash without the 1-vs-0 index
  fork, prefer `${arr[@]:0:1}` (array slice) over `${arr[1]}`/`${arr[0]}`.
- When a shared (`dot_config/shell/**`) helper "works in bash, breaks in zsh"
  (or vice-versa), suspect a construct whose semantics differ between the two
  shells: `[*]` vs `[@]` slicing, `read -a`/`-A`, `${=var}`, glob qualifiers.

Not serious enough to graduate to `AGENTS.md` (single-line fix once diagnosed,
no state corruption). Keep as a pitfall.

## Related

- `dot_config/shell/22_sesh.sh` — fixed `sesh-vibe` call site
- [`pitfalls/zsh-tied-array-path-shadowing.md`](zsh-tied-array-path-shadowing.md)
  — sibling zsh-only trap in the same `sesh` helper family
- [`pitfalls/opencode-concurrent-launch-wal-pragma-fails.md`](opencode-concurrent-launch-wal-pragma-fails.md)
  — the *other* error surfaced by the same `svibe 4 opencode` invocation (the
  WAL race), unrelated root cause
- `man zshexpn` → "Parameter Expansion" / "Subscript Flags" — `[*]` join vs
  `[@]` element semantics

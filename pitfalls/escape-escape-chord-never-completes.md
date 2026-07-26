# Binding `"escape escape"` kills the Esc key entirely (chord never completes)

## Symptoms

- Goal: stop accidentally interrupting Claude Code mid-turn by making Esc need
  **two** presses (the way Ctrl+C needs two presses to exit). The obvious fix —
  a chord binding in `~/.claude/keybindings.json`:

  ```json
  {
    "context": "Chat",
    "bindings": {
      "escape": null,
      "escape escape": "chat:cancel"
    }
  }
  ```

- Result: **Esc does nothing at all.** Not just "doesn't interrupt" — the
  `Esc again to clear` input-clear gesture and `Esc` on an empty prompt
  (rewind / go-up-a-few-messages selector) both stop working too.
- **No error anywhere.** No validation warning at load, `/doctor` clean, the
  JSON is valid, the action name and context name are both real. `--debug`
  logs `bindings loaded` with zero warnings. Nothing tells you the chord is
  unreachable.
- There is also **no settings key** for this — nothing under
  `escape`/`interrupt` in the bundle gates the behaviour.

Verified against the Claude Code **2.1.220** bundle (2026-07). Derived by
reading the shipped binary, not by keyboard-testing the broken config.

## Root cause

Escape is hardcoded as the *chord-cancel* key, so it can never be the **second**
key of a chord. Both chord resolvers open with the same guard (minified names
from the 2.1.220 bundle, for future re-grepping):

```js
function sut(e,t,r,n){ if(e.name==="escape"&&n!==null) return {type:"chord_cancelled"}; … }
function ePt(e,t,r,n){ if(e.name==="escape"&&n!==null) return {type:"chord_cancelled"}; … }
```

`n` is the pending chord prefix. So the trace for `"escape escape"` is:

1. **First Esc** — `n === null`, so the guard is skipped. A longer chord
   prefix-matches, so it returns `{type:"chord_started", pending:["escape"]}`.
   The dispatcher then consumes the event:

   ```js
   case"chord_started":{ q5o.current="legacy", Gae(oZs.pending), Cgn(); return }
   //                                                            ^^^^^
   // function J5o(e){ e.preventDefault(), e.stopImmediatePropagation() }
   ```

   That `Cgn()` is why the input-level gestures die: Esc never reaches the
   prompt component any more.
2. **Second Esc** — now `n !== null`, the guard fires first →
   `{type:"chord_cancelled"}`. The chord is discarded. `chat:cancel` is never
   dispatched.

Net effect: Esc is a dead prefix that waits `CHORD_TIMEOUT_MS` (`var lv,eAe,dZs,jbp=1000`)
and then cancels itself. The same reasoning rules out *any* chord ending in
Escape (`ctrl+x escape`, …), not just `escape escape`.

### What Esc actually does today (three separate code paths)

Useful context, because only the first one is a keybinding at all:

| When | Path | Behaviour |
|---|---|---|
| Claude is generating | `chat:cancel` keybinding, `Chat` context | **single press interrupts** |
| Idle, prompt has text | prompt component's own double-press helper | 1st press shows `Esc again to clear`, 2nd clears (800 ms window) |
| Idle, prompt empty | REPL `onKeyDown` handler | opens the rewind / message-selector |

```js
// the interrupt — the only one routed through the keybinding registry
Mn("chat:cancel",()=>D(!0),{context:"Chat",isActive:j});   // j = …&&(M||B||L)&&… i.e. in-flight or queued

// the clear gesture — Pee = useDoublePress, var dut,fpy=800
K=Pee((Pe)=>{ … text:"Esc again to clear" … }, ()=>{ … t(""),B(0),c?.() })

// the rewind — hasMessages:p, isLoading:a, so it's skipped while generating
if(hK(Wt),Wt.name==="escape"){ if(qm())return; if(hU()&&Te!=="NORMAL")return;
  if(!sV()){if(cr.some(P5)){GU();return}} if(p&&!te&&!a)EN() }
```

So the "press twice" pattern already exists in the product — it just isn't
applied to the interrupt, and can't be bolted on with a chord.

## Workaround

**Unbind Esc from the interrupt and interrupt with Ctrl+C instead.** In
`~/.claude/keybindings.json`:

```json
{ "context": "Chat", "bindings": { "escape": null } }
```

This is safe for the other two gestures because an unbound key is **not**
consumed — the `unbound` branch returns without calling `preventDefault`:

```js
case"unbound":{ if(Ybr(MBt,DBt,PBt,MLe)){Gae(null),Vte(null,!0);return} Gae(null),Vte(null,!1); return }
```

so the event still propagates to the prompt component and the REPL handler.
`Esc again to clear` and the empty-prompt rewind survive; only the interrupt
goes away. Ctrl+C then behaves exactly like the shape people expect: single
press interrupts a running turn, and when idle it clears the input on the first
press and exits only on a second within 800 ms.

**Alternative: turn on vim editor mode** (`/config` → Editor mode → vim).
Upstream documents that "The Escape key in vim mode switches INSERT to NORMAL
mode; it does not trigger `chat:cancel`", which effectively costs a stray Esc
one extra press. Caveat: only the INSERT-mode press is documented as inert —
whether the follow-up Esc in NORMAL mode reaches `chat:cancel` was not verified
here.

## Prevention

- Treat **Escape as unusable in chords, in any position but the first** — and
  as a bad chord *prefix* too, since starting a chord swallows the key from the
  components that implement Esc's real behaviour.
- Chord bindings fail **silently and unconditionally** when they're structurally
  unreachable. When a new binding "does nothing", check the resolver's hardcoded
  keys before assuming a typo: `strings`/`grep` the binary for
  `chord_cancelled`.
- In this repo, binding overrides go in the **live** `~/.claude/keybindings.json`,
  not the chezmoi source: `dot_claude/modify_keybindings.json` deliberately
  manages only `$schema`/`$docs` and leaves `.bindings` alone (a naive
  `jq '. * $overlay'` merge replaces arrays wholesale and would clobber every
  upstream default). See that file's header comment.

## Related

- [`docs/tools/claude-code-keybindings.md`](../docs/tools/claude-code-keybindings.md)
  — action namespaces, the `chat:cycleMode`-only mode-jump limitation.
- [`dot_claude/modify_keybindings.json`](../dot_claude/modify_keybindings.json)
  — why `.bindings` is unmanaged.
- [`pitfalls/claude-code-keybindings-empty-bindings-array.md`](claude-code-keybindings-empty-bindings-array.md)
  — the other silent-failure mode of this same file.
- Upstream docs: <https://code.claude.com/docs/en/keybindings> (documents chords
  and the reserved `ctrl+c`/`ctrl+d`/`ctrl+m` list, but **not** Escape's
  chord-cancel role).
